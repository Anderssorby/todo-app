/// Authentication: the session-cookie path, the ATproto OAuth login
/// orchestration, and the development-only sign-in stub.
///
/// Production sign-in is AT Protocol OAuth as a public client with the
/// identity-only `atproto` scope: handle -> DID -> DID document -> PDS ->
/// authorization server, then PAR with PKCE S256 and DPoP, a 302 to the
/// authorization endpoint, and on the callback a token exchange whose
/// `sub` must equal the DID resolved at login time. The ES256 DPoP proofs
/// come from the app-local seam in `dpop.mo` (the pinned crypto mote
/// verifies but cannot generate or sign; see PLAN.md's gap list). The flow
/// itself lives in `atproto.mo`; this module owns what surrounds it:
/// the `oauth_states` row, the server-side session, and the cookie.
///
/// The browser never sees an ATproto token. The callback exchanges the
/// code, confirms the session against the PDS, upserts the user, and
/// issues the app's own session cookie: a raw CSPRNG URL-safe token whose
/// SHA-256 hex digest is the `sessions.id` primary key (the raw value is
/// never stored). `TODO_DEV_AUTH=1` (or `--dev-auth`) short-circuits all
/// of this for local use and is never enabled in the image/Kubernetes
/// manifest.
///
/// The workspace is shared; `Context.user` is the actor used for
/// attribution, not an ownership filter.
use todo_core::codec {Codec.json_string}
use todo_core::user {OauthState, OidcIdentity, User}
use lib::atproto {
  AtprotoConfig, Atproto.authorize_url, Atproto.authorization_server,
  Atproto.authorization_server_of, Atproto.exchange_code, Atproto.get_session,
  Atproto.normalize_input, Atproto.par, Atproto.resolve_identity
}
use lib::dpop {DpopKey, Dpop.jkt, Dpop.generate}
use lib::db {
  Db.create_session, Db.delete_session, Db.epoch_now, Db.find_or_create_user,
  Db.find_session, Db.iso_timestamp_in, Db.put_oauth_state, Db.take_oauth_state,
  Store
}
use lib::logging {App.logger}
use log::logger {Logger.warn}
use oauth::pkce {Pkce.verifier}
use http::cookie {
  CookieAttrs, CookieAttrs.default, Cookie.clear, Cookie.lookup,
  Cookie.parse_headers, Cookie.set_cookie
}
use http::types {
  Headers, Headers.add, Request, Response, Response.ok_text, Response.redirect,
  Status.bad_request, Status.found, Status.internal_server_error,
  Status.unauthorized
}
use http::uri {Uri.parse_query}
use std::sha256 {Sha256.hash}

pub struct Context {
  store : Store,
  user : User,
  csrf : String
}

pub struct Config {
  store : Store,
  dev_auth : Bool,
  atproto : AtprotoConfig
}

pub def Auth.dev_identity : OidcIdentity :=
  let i : OidcIdentity := {
    issuer := "dev", subject := "dev", email := Option.none,
    name := "Dev User", picture := Option.none
  } in i

pub def Auth.dev_csrf : String := "dev-csrf"

// ─── responses ──────────────────────────────────────────────────────────

def Auth.server_error (msg : String) : Response :=
  let r := Response.ok_text msg in
  { r with status := Status.internal_server_error,
    headers := Headers.set "Content-Type" "text/plain; charset=utf-8" Headers.empty }

def Auth.json_unauthorized : Response :=
  let r := Response.ok_text "{\"error\":\"unauthorized\"}" in
  { r with status := Status.unauthorized,
    headers := Headers.set "Content-Type" "application/json; charset=utf-8" Headers.empty }

def Auth.redirect_login : Response :=
  Response.redirect Status.found "/login"

/// The error page shown when a login cannot proceed. The detail goes to
/// the log, not the page: error strings can carry text from remote
/// servers and must not be reflected into HTML unescaped.
def Auth.login_error_page (msg : String) : Response :=
  let r := Response.ok_text
    ("<!doctype html><html><head><meta charset=\"utf-8\">"
     ++ "<title>Sign in</title></head><body><h1>todo-app</h1>"
     ++ "<p>Sign-in failed: " ++ msg ++ "</p>"
     ++ "<p><a href=\"/login\">Try again</a></p></body></html>") in
  { r with status := Status.bad_request,
    headers := Headers.set "Content-Type" "text/html; charset=utf-8" Headers.empty }

/// Log the remote detail and show a generic page instead.
def Auth.login_failed_logged (detail : String) : IO Response := do {
  let _ <- Logger.warn App.logger ("oauth login failed: " ++ detail);
  return (Auth.login_error_page
    "the sign-in could not be completed. Check the handle and try again.")
}

// ─── sessions and cookies ────────────────────────────────────────────────

pub def Auth.session_cookie_name : String := "todo_session"

/// The `sessions.id` key: the raw cookie token is never stored, only its
/// SHA-256 hex digest.
def Auth.token_hash (token : String) : String := Sha256.hash token

/// Cookie attributes shared by the set and clear paths. `Secure` follows
/// the deployment's own callback origin.
def Auth.cookie_attrs (config : Config) : CookieAttrs :=
  { CookieAttrs.default with
    secure := String.starts_with "https://" config.atproto.redirect_uri }

/// The signed-in user for a request, when the session cookie is valid.
/// Returns the user and the row's CSRF token.
pub def Auth.session_of_request (config : Config) (req : Request)
  : IO (Option (Pair User String)) := do {
  let token :=
    Cookie.lookup Auth.session_cookie_name (Cookie.parse_headers req.headers);
  match token {
    Option.none => return Option.none,
    Option.some token =>
      if String.is_empty token
      then return Option.none
      else do {
        let found <- Db.find_session config.store (Auth.token_hash token);
        match found {
          Result.err _ => return Option.none,
          Result.ok session => return session,
        }
      },
  }
}

/// Resolve the request's actor. Dev mode authenticates every request as
/// the local dev user; otherwise a valid session cookie is required
/// (JSON 401 for `/api/*`, a redirect to `/login` for pages).
pub def Auth.require (config : Config)
    (handler : Context -> Request -> IO Response) (req : Request) : IO Response := do {
  if config.dev_auth then do {
    let r <- Db.find_or_create_user config.store Auth.dev_identity;
    match r {
      Result.err msg => return (Auth.server_error msg),
      Result.ok user =>
        let ctx : Context := { store := config.store, user := user,
                               csrf := Auth.dev_csrf } in
        handler ctx req,
    }
  } else do {
    let session <- Auth.session_of_request config req;
    match session {
      Option.some user_csrf =>
        match user_csrf {
          Pair.pair user csrf =>
            let ctx : Context := { store := config.store, user := user,
                                   csrf := csrf } in
            handler ctx req,
        },
      Option.none =>
        if String.starts_with "/api/" req.uri.path
        then return Auth.json_unauthorized
        else return Auth.redirect_login,
    }
  }
}

/// The dev mode's current user, for public routes (`/api/me`, the login
/// page). Returns none when dev auth is off.
pub def Auth.dev_user (config : Config) : IO (Option User) := do {
  if config.dev_auth then do {
    let r <- Db.find_or_create_user config.store Auth.dev_identity;
    match r {
      Result.err _ => return Option.none,
      Result.ok user => return (Option.some user),
    }
  } else
    return Option.none
}

// ─── the ATproto login flow ──────────────────────────────────────────────

/// `GET /auth/login`'s work: resolve the identity, discover the
/// authorization server, push the request (PAR), persist the one-time
/// state row, and answer with the 302 to the authorization endpoint.
/// The page the browser came from is preserved in `redirect_to`.
pub def Auth.begin_login (config : Config) (raw_input : String)
    (redirect_to : Option String) : IO Response := do {
  let input_r := Atproto.normalize_input raw_input;
  match input_r {
    Result.err e => return (Auth.login_error_page e),
    Result.ok input => do {
      let identity_r <- Atproto.resolve_identity config.atproto input;
      match identity_r {
        Result.err e => Auth.login_failed_logged ("identity: " ++ e),
        Result.ok identity => do {
          let issuer_r <- Atproto.authorization_server_of config.atproto identity.pds;
          match issuer_r {
            Result.err e => Auth.login_failed_logged ("protected resource: " ++ e),
            Result.ok issuer => do {
              let server_r <- Atproto.authorization_server config.atproto issuer;
              match server_r {
                Result.err e => Auth.login_failed_logged ("AS metadata: " ++ e),
                Result.ok server => do {
                  let verifier_r <- Pkce.verifier;
                  match verifier_r {
                    Result.err _ =>
                      return (Auth.server_error "no randomness source available"),
                    Result.ok verifier => do {
                      let key_r <- Dpop.generate;
                      match key_r {
                        Result.err e => return (Auth.server_error ("keygen: " ++ e)),
                        Result.ok key => do {
                          match Dpop.jkt key {
                            Result.err e => return (Auth.server_error ("jkt: " ++ e)),
                            Result.ok jkt => do {
                              let state_r <- Pkce.verifier;
                              match state_r {
                                Result.err _ =>
                                  return (Auth.server_error "no randomness source available"),
                                Result.ok state => do {
                                  let now_r <- Db.epoch_now config.store;
                                  match now_r {
                                    Result.err e => return (Auth.server_error e),
                                    Result.ok now => do {
                                      let jti_r <- Pkce.verifier;
                                      match jti_r {
                                        Result.err _ =>
                                          return (Auth.server_error "no randomness source available"),
                                        Result.ok jti => do {
                                          let par_r <- (Atproto.par config.atproto server
                                            input state verifier jkt key Option.none
                                            now jti);
                                          match par_r {
                                            Result.err e =>
                                              Auth.login_failed_logged ("par: " ++ e),
                                            Result.ok par => do {
                                              let expires_r <-
                                                Db.iso_timestamp_in config.store 10i64;
                                              match expires_r {
                                                Result.err e => return (Auth.server_error e),
                                                Result.ok expires_at => do {
                                                  let row : OauthState := {
                                                    state := state,
                                                    nonce := (match par.nonce {
                                                      Option.some n => n,
                                                      Option.none => "",
                                                    }),
                                                    code_verifier := verifier,
                                                    redirect_to := redirect_to,
                                                    expires_at := expires_at,
                                                    issuer := server.issuer,
                                                    pds := identity.pds,
                                                    did := identity.did,
                                                    handle := identity.handle,
                                                    dpop_priv := key.priv_b64,
                                                    dpop_pub := key.pub_b64
                                                  };
                                                  let saved <- Db.put_oauth_state config.store row;
                                                  match saved {
                                                    Result.err e => return (Auth.server_error e),
                                                    Result.ok _ =>
                                                      return (Response.redirect Status.found
                                                        (Atproto.authorize_url config.atproto server par)),
                                                  }
                                                }
                                              }
                                            }
                                          }
                                        }
                                      }
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    },
                  }
                },
              }
            },
          }
        },
      }
    },
  }
}

def Auth.query_value (name : String) (req : Request) : Option String :=
  let query : String :=
    match req.uri.query {
      Option.some q => q,
      Option.none => "",
    } in
  Auth.query_value_scan name (Uri.parse_query query) Option.none

/// First match for `name` in a parsed query list.
#[partial]
def Auth.query_value_scan (name : String) (pairs : List (Pair String String))
    (acc : Option String) : Option String :=
  match pairs {
    List.empty => acc,
    List.cons kv rest =>
      match kv {
        Pair.pair k v =>
          if String.beq k name
          then Option.some v
          else Auth.query_value_scan name rest acc,
      },
  }

/// `GET /auth/callback`: exchange the code for DPoP-bound tokens, confirm
/// the session against the PDS, upsert the user, and set the app session
/// cookie. Every step after the state row is taken re-validates what the
pub def Auth.finish_login (config : Config) (req : Request) : IO Response := do {
  match Auth.query_value "error" req {
    Option.some e => Auth.login_failed_logged ("authorization error: " ++ e),
    Option.none =>
      match Auth.query_value "state" req {
        Option.none =>
          return (Auth.login_error_page "the sign-in link is incomplete; start again"),
        Option.some state =>
          match Auth.query_value "code" req {
            Option.none =>
              return (Auth.login_error_page "the sign-in link is incomplete; start again"),
            Option.some code => do {
              let row_r <- Db.take_oauth_state config.store state;
              match row_r {
                Result.err e => return (Auth.server_error e),
                Result.ok row_opt => do {
                  match row_opt {
                    Option.none =>
                      return (Auth.login_error_page "the sign-in link expired; start again"),
                    Option.some row => do {
                      let key : DpopKey :=
                        { priv_b64 := row.dpop_priv, pub_b64 := row.dpop_pub };
                      let server_r <- Atproto.authorization_server config.atproto row.issuer;
                      match server_r {
                        Result.err e => Auth.login_failed_logged ("AS metadata: " ++ e),
                        Result.ok server => do {
                          let now_r <- Db.epoch_now config.store;
                          match now_r {
                            Result.err e => return (Auth.server_error e),
                            Result.ok now => do {
                              let jti_r <- Pkce.verifier;
                              match jti_r {
                                Result.err _ =>
                                  return (Auth.server_error "no randomness source available"),
                                Result.ok jti => do {
                                  let as_nonce : Option String :=
                                    if String.is_empty row.nonce
                                    then Option.none
                                    else Option.some row.nonce;
                                  let tokens_r <- (Atproto.exchange_code config.atproto server
                                    code row.code_verifier row.did key as_nonce now jti);
                                  match tokens_r {
                                    Result.err e =>
                                      Auth.login_failed_logged ("token: " ++ e),
                                    Result.ok tokens => do {
                                      let session_jti_r <- Pkce.verifier;
                                      match session_jti_r {
                                        Result.err _ =>
                                          return (Auth.server_error "no randomness source available"),
                                        Result.ok session_jti => do {
                                          let confirmed_r <- (Atproto.get_session config.atproto
                                            row.pds key server.issuer
                                            tokens.access_token tokens.nonce now session_jti);
                                          match confirmed_r {
                                            Result.err e =>
                                              Auth.login_failed_logged ("session: " ++ e),
                                            Result.ok confirmed =>
                                              if Bool.not (String.beq confirmed.did row.did)
                                              then Auth.login_failed_logged "the PDS session names a different DID"
                                              else do {
                                                let display : String :=
                                                  match row.handle {
                                                    Option.some h => h,
                                                    Option.none => confirmed.handle,
                                                  };
                                                let identity : OidcIdentity := {
                                                  issuer := server.issuer,
                                                  subject := row.did,
                                                  email := confirmed.email,
                                                  name := display,
                                                  picture := Option.none
                                                };
                                                let user_r <- Db.find_or_create_user config.store identity;
                                                match user_r {
                                                  Result.err e => return (Auth.server_error e),
                                                  Result.ok user => do {
                                                    let token_r <- Pkce.verifier;
                                                    match token_r {
                                                      Result.err _ =>
                                                        return (Auth.server_error "no randomness source available"),
                                                      Result.ok token => do {
                                                        let csrf_r <- Pkce.verifier;
                                                        match csrf_r {
                                                          Result.err _ =>
                                                            return (Auth.server_error "no randomness source available"),
                                                          Result.ok csrf => do {
                                                            let expires_r <-
                                                              Db.iso_timestamp_in config.store 43200i64;
                                                            match expires_r {
                                                              Result.err e => return (Auth.server_error e),
                                                              Result.ok expires => do {
                                                                let created <- (Db.create_session config.store
                                                                  user.id (Auth.token_hash token) csrf expires);
                                                                match created {
                                                                  Result.err e => return (Auth.server_error e),
                                                                  Result.ok _ =>
                                                                    return (Auth.session_redirect config row.redirect_to token),
                                                                }
                                                              }
                                                            }
                                                          }
                                                        }
                                                      }
                                                    }
                                                  }
                                                }
                                              }
                                          }
                                        }
                                      }
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            },
          },
      },
  }
}

/// The post-login 302 with the session cookie attached.
def Auth.session_redirect (config : Config) (redirect_to : Option String)
    (token : String) : Response :=
  let target : String :=
    match redirect_to {
      Option.some r => r,
      Option.none => "/",
    } in
  let base := Response.redirect Status.found target in
  let attrs : CookieAttrs :=
    { (Auth.cookie_attrs config) with
      max_age := Option.some 2592000i64 } in
  match Cookie.set_cookie Auth.session_cookie_name token attrs {
    Pair.pair header value =>
      { base with headers := Headers.add header value base.headers }
  }

/// `POST /auth/logout`: delete the server-side session and clear the
/// cookie. Signed-in callers hold the CSRF token, but the cookie is
/// HttpOnly and this handler only destroys state.
pub def Auth.logout (config : Config) (req : Request) : IO Response := do {
  let token :=
    Cookie.lookup Auth.session_cookie_name (Cookie.parse_headers req.headers);
  match token {
    Option.some token => do {
      let _ <- Db.delete_session config.store (Auth.token_hash token);
      return (Auth.logout_response config)
    },
    Option.none => return (Auth.logout_response config),
  }
}

def Auth.logout_response (config : Config) : Response :=
  let base := Response.redirect Status.found "/login" in
  match Cookie.clear Auth.session_cookie_name (Auth.cookie_attrs config) {
    Pair.pair header value =>
      { base with headers := Headers.add header value base.headers }
  }

/// `GET /client-metadata.json`: the client document an ATproto
/// authorization server fetches. CORS-open because the AS, not the
/// browser, is the fetcher. `dpop_bound_access_tokens` is what tells the
/// AS to issue DPoP-bound tokens; `token_endpoint_auth_method=none` is
/// the public-client shape (no secret exists).
pub def Auth.client_metadata_json (config : Config) : String :=
  String.concat_list [
    "{\"client_id\":", Codec.json_string config.atproto.client_id,
    ",\"client_name\":\"todo-app\",",
    "\"redirect_uris\":[", Codec.json_string config.atproto.redirect_uri, "],",
    "\"scope\":", Codec.json_string config.atproto.scope, ",",
    "\"grant_types\":[\"authorization_code\",\"refresh_token\"],",
    "\"response_types\":[\"code\"],",
    "\"token_endpoint_auth_method\":\"none\",",
    "\"application_type\":\"web\",",
    "\"dpop_bound_access_tokens\":true}"
  ]
