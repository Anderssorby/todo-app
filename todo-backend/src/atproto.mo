/// The AT Protocol OAuth client: public client, identity-only `atproto`
/// scope, PKCE S256, PAR and DPoP (RFC 9449).
///
/// This is the app-local half the pinned `oauth` mote deliberately does not
/// own: its OIDC `Discovery`/`Login`/bearer validation assume an OIDC IdP,
/// while ATproto has no ID tokens, a per-user authorization server reached
/// through the PDS, PAR (Phase 7 upstream) and DPoP-bound opaque access
/// tokens. What the mote DOES own and this module reuses is the transport
/// seam (`OauthHttp`, scriptable by `OauthHttp.fake` so the whole flow is
/// testable with no socket), PKCE (`Pkce.verifier`/`Pkce.challenge`) and
/// `OauthError`. The ES256 DPoP proofs come from the app-local `Dpop`
/// seam (`dpop.mo`).
///
/// Flow (the 2026-10-31 PLAN design, now implemented):
///
///   handle -> DID -> DID document -> #atproto_pds
///   -> PDS /.well-known/oauth-protected-resource  -> AS issuer
///   -> AS  /.well-known/oauth-authorization-server (ES256 + PAR required)
///   -> PAR (PKCE S256, dpop_jkt, DPoP proof, one `use_dpop_nonce` retry)
///   -> 302 authorization_endpoint?client_id&request_uri
///   -> callback: token exchange (DPoP proof, one nonce retry)
///   -> check token_type=DPoP, sub DID, scope, iss
///   -> com.atproto.server.getSession on the PDS (Authorization: DPoP, ath)
///   -> the caller creates the server-side session cookie
///
/// Security notes:
///
/// - Every cross-service URL is derived from the resolved identity chain,
///   never from user input directly; the AS metadata's `issuer` must equal
///   the origin it was fetched from (RFC 8414 3.3), and the PDS endpoint
///   must be https (or an explicit dev http origin).
/// - The token response is checked before any session exists: `sub` must
///   equal the DID resolved at login time (an authorization server cannot
///   hand the app a different identity than the one the user asked to
///   sign in as), `token_type` must be `DPoP`, and the `atproto` scope
///   must survive the grant.
/// - Access tokens never reach the browser: only the app's own session
///   cookie does. The DPoP key is kept in the `oauth_states` row for the
///   lifetime of the login attempt and dropped with it.
///
/// Compiled-backend only at the call sites that sign proofs; the pure
/// parsing/validation helpers run everywhere.

use http::types {Headers, Headers.get, Headers.set, Headers.empty, Response, Uri}
use http::body {Body.from_text, Body.to_bytes_pure}
use http::uri {Uri.parse, Uri.percent_encode, Uri.format_query, Uri.percent_decode_or}
use http::strings {Strings.split_on}
use json::json {
  Json, Json.get_array, Json.get_num, Json.get_num_i64, Json.get_object,
  Json.get_str, Json.object_get, Json.parse
}
use oauth::http_client {
  OauthHttp, OauthHttp.send_get, OauthHttp.send_post, ScriptedExchange
}
use oauth::pkce {Pkce.challenge, Pkce.method}
use oauth::errors {OauthError, OauthError.to_string}
use std::base64 {B64Url.encode}
use std::sha256 {Sha256.hash_bytes}
use std::list {List.any}
use lib::dpop {DpopKey, Dpop.proof, Dpop.generate, Dpop.jkt}
use todo_core::codec {Codec.json_string}

// ── shapes ──────────────────────────────────────────────────────────────

/// One resolved login identity: the DID, the PDS origin and (when known)
/// the handle for display.
pub struct AtprotoIdentity {
  did : String,
  pds : String,
  handle : Option String
}

/// The authorization-server metadata the flow needs (RFC 8414), after the
/// shape checks in `Atproto.authorization_server`.
pub struct AtprotoServer {
  issuer : String,
  authorization_endpoint : String,
  token_endpoint : String,
  par_endpoint : String
}

/// The DPoP-bound token set. ATproto access tokens are opaque; the refresh
/// token is optional in the response but always granted by the reference
/// provider. `nonce` is the AS's latest `DPoP-Nonce`, carried to the PDS
/// confirmation.
pub struct AtprotoTokens {
  access_token : String,
  sub : String,
  scope : String,
  expires_in : I64,
  refresh_token : Option String,
  nonce : Option String
}

/// `com.atproto.server.getSession` on the PDS.
pub struct AtprotoSessionInfo {
  did : String,
  handle : String,
  email : Option String
}

/// Configuration: the transport, the OAuth client identity and the
/// resolver bases. `resolver_base` and `plc_base` exist so tests and
/// self-hosted deployments can point resolution at a stub or mirror.
pub struct AtprotoConfig {
  http : OauthHttp,
  client_id : String,
  redirect_uri : String,
  scope : String,
  resolver_base : String,
  plc_base : String
}

pub def Atproto.default_resolver_base : String := "https://bsky.social"
pub def Atproto.default_plc_base : String := "https://plc.directory"

def Atproto.form_content_type : Headers :=
  Headers.set "Content-Type" "application/x-www-form-urlencoded" Headers.empty

// ── transport helpers ───────────────────────────────────────────────────

def Atproto.body_text (res : Response) : String :=
  String.from_list (Body.to_bytes_pure res.body)

/// 200..=299.
def Atproto.ok_status (res : Response) : Bool :=
  Bool.not (U16.gt 200u16 res.status) && Bool.not (U16.gt res.status 299u16)

def Atproto.get (http : OauthHttp) (url : String) (headers : Headers)
  : IO (Result String Response) :=
  match Uri.parse url {
    Result.err e => IO.pure (Result.err ("atproto: invalid url: " ++ e)),
    Result.ok u => do {
      let r <- OauthHttp.send_get http u headers;
      match r {
        Result.err e =>
          return (Result.err ("atproto: transport: " ++ OauthError.to_string e)),
        Result.ok res => return (Result.ok res),
      }
    }
  }

def Atproto.post (http : OauthHttp) (url : String) (headers : Headers) (body : String)
  : IO (Result String Response) :=
  match Uri.parse url {
    Result.err e => IO.pure (Result.err ("atproto: invalid url: " ++ e)),
    Result.ok u => do {
      let r <- OauthHttp.send_post http u headers (Body.from_text body);
      match r {
        Result.err e =>
          return (Result.err ("atproto: transport: " ++ OauthError.to_string e)),
        Result.ok res => return (Result.ok res),
      }
    }
  }

/// Parse a JSON object out of a response body.
def Atproto.json_of (res : Response) : Result String Json :=
  match Json.parse (Atproto.body_text res) {
    Result.err _ => Result.err "atproto: invalid json response",
    Result.ok j => Result.ok j,
  }

/// A required string member of a JSON object.
def Atproto.str_field (obj : Json) (name : String) : Result String String :=
  match Json.get_object obj {
    Result.err e => Result.err ("atproto: not an object: " ++ e),
    Result.ok o => match Json.object_get name o {
      Option.none => Result.err ("atproto: missing " ++ name),
      Option.some v => match Json.get_str v {
        Result.err e => Result.err ("atproto: bad " ++ name ++ ": " ++ e),
        Result.ok s => Result.ok s,
      },
    },
  }

/// An optional string member (`none` when absent or not a string).
def Atproto.opt_str_field (obj : Json) (name : String) : Option String :=
  match Json.get_object obj {
    Result.err _ => Option.none,
    Result.ok o => match Json.object_get name o {
      Option.none => Option.none,
      Option.some v => match Json.get_str v {
        Result.err _ => Option.none,
        Result.ok s => Option.some s,
      },
    },
  }

// ── input normalization ────────────────────────────────────────────────

/// The login input: a handle (`user.bsky.social`, `@user.bsky.social`) or a
/// DID (`did:plc:...`, `did:web:...`). Handles are lowercased (DNS names);
/// DIDs are case-sensitive and pass through.
pub def Atproto.normalize_input (raw : String) : Result String String :=
  let trimmed := String.trim raw in
  let without_at :=
    if String.starts_with "@" trimmed
    then String.drop 1 trimmed
    else trimmed in
  if String.is_empty without_at
  then Result.err "enter a handle or DID"
  else if String.starts_with "did:" without_at
  then Result.ok without_at
  else do {
    let handle := String.to_lowercase without_at;
    if String.is_empty handle
    then Result.err "enter a handle or DID"
    else if String.contains handle " "
    then Result.err "a handle contains no spaces"
    else Result.ok handle
  }

// ── identity resolution ────────────────────────────────────────────────

/// Handle -> DID: the account's own `/.well-known/atproto-did`, then the
/// public appview's `com.atproto.identity.resolveHandle` as fallback (the
/// same order the reference client's resolvers use; DNS TXT records are not
/// reachable from Monad and are the resolver's business, not the app's).
pub def Atproto.resolve_handle (cfg : AtprotoConfig) (handle : String)
  : IO (Result String String) := do {
  let well_known_r <- Atproto.get cfg.http
    ("https://" ++ handle ++ "/.well-known/atproto-did") Headers.empty;
  let from_well_known :=
    match well_known_r {
      Result.err _ => Option.none,
      Result.ok res =>
        if Bool.not (Atproto.ok_status res)
        then Option.none
        else
          let did := String.trim (Atproto.body_text res) in
          if String.starts_with "did:" did
          then Option.some did
          else Option.none,
    };
  match from_well_known {
    Option.some did => return (Result.ok did),
    Option.none => do {
      let url := String.concat_list [
        cfg.resolver_base, "/xrpc/com.atproto.identity.resolveHandle?handle=",
        Uri.percent_encode handle
      ];
      let api_r <- Atproto.get cfg.http url Headers.empty;
      match api_r {
        Result.err e => return (Result.err e),
        Result.ok res =>
          if Bool.not (Atproto.ok_status res)
          then return (Result.err
            ("could not resolve handle " ++ handle))
          else match Atproto.json_of res {
            Result.err e => return (Result.err e),
            Result.ok j => match Atproto.str_field j "did" {
              Result.err e => return (Result.err e),
              Result.ok did =>
                if String.starts_with "did:" did
                then return (Result.ok did)
                else return (Result.err ("resolver returned a non-DID: " ++ did)),
            },
          },
      }
    }
  }
}

/// The DID document's `#atproto_pds` service endpoint, plus the doc's own
/// `alsoKnownAs` handles for display.
def Atproto.pds_of_document (did : String) (doc : Json)
  : Result String (Pair String (Option String)) :=
  match Atproto.str_field doc "id" {
    Result.err e => Result.err e,
    Result.ok doc_id =>
      if Bool.not (String.beq doc_id did)
      then Result.err "the DID document names a different id"
      else match Json.get_object doc {
        Result.err _ => Result.err "the DID document is not an object",
        Result.ok o => match Json.object_get "service" o {
          Option.none => Result.err "the DID document has no service array",
          Option.some arr => match Json.get_array arr {
            Result.err _ => Result.err "the DID document's service is not an array",
            Result.ok entries =>
              match Atproto.find_pds entries {
                Result.err e => Result.err e,
                Result.ok pds =>
                  let handle :=
                    Atproto.first_handle
                      (Json.get_array
                        (match (Json.object_get "alsoKnownAs" o) {
                          Option.none => Json.make_null,
                          Option.some v => v,
                        })) in
                  Result.ok (Pair.pair pds handle),
              },
          },
        },
      },
  }

#[partial]
def Atproto.find_pds (entries : List Json) : Result String String :=
  match entries {
    List.empty => Result.err "the DID document has no #atproto_pds service",
    List.cons entry rest =>
      let id := Atproto.opt_str_field entry "id" in
      match id {
        Option.some service_id =>
          if String.contains service_id "#atproto_pds"
          then match Atproto.opt_str_field entry "serviceEndpoint" {
            // A service endpoint may carry a trailing slash; the origin is
            // stored without one so URL joins never produce `//`.
            Option.none => Atproto.find_pds rest,
            Option.some endpoint => Result.ok (Atproto.trim_slash endpoint),
          }
          else Atproto.find_pds rest,
        Option.none => Atproto.find_pds rest,
      },
  }

/// The first `at://handle` in `alsoKnownAs`.
def Atproto.first_handle (aka : Result String (List Json)) : Option String :=
  match aka {
    Result.err _ => Option.none,
    Result.ok entries => Atproto.first_handle_go entries,
  }

#[partial]
def Atproto.first_handle_go (entries : List Json) : Option String :=
  match entries {
    List.empty => Option.none,
    List.cons v rest =>
      match Json.get_str v {
        Result.err _ => Atproto.first_handle_go rest,
        Result.ok s =>
          if String.starts_with "at://" s
          then Option.some (String.drop 5 s)
          else Atproto.first_handle_go rest,
      },
  }

def Atproto.trim_slash (s : String) : String :=
  if String.ends_with s "/"
  then String.slice s 0 (I64.sub (String.length s) 1)
  else s

/// input (handle or DID) -> identity (DID + PDS + display handle).
pub def Atproto.resolve_identity (cfg : AtprotoConfig) (input : String)
  : IO (Result String AtprotoIdentity) := do {
  let did_r <- (if String.starts_with "did:" input
    then IO.pure (Result.ok input)
    else Atproto.resolve_handle cfg input);
  match did_r {
    Result.err e => return (Result.err e),
    Result.ok did => do {
      let doc_url :=
        if String.starts_with "did:plc:" did
        then String.concat_list [cfg.plc_base, "/", did]
        else if String.starts_with "did:web:" did
        then
          let host := String.drop 8 did in
          String.concat_list [
            "https://", Atproto.decode_web_host host, "/.well-known/did.json"
          ]
        else "";
      if String.is_empty doc_url
      then return (Result.err "unsupported DID method (plc and web only)")
      else do {
        let doc_r <- Atproto.get cfg.http doc_url Headers.empty;
        match doc_r {
          Result.err e => return (Result.err e),
          Result.ok res =>
            if Bool.not (Atproto.ok_status res)
            then return (Result.err ("could not fetch the DID document for " ++ did))
            else match Atproto.json_of res {
              Result.err e => return (Result.err e),
              Result.ok doc =>
                match Atproto.pds_of_document did doc {
                  Result.err e => return (Result.err e),
                  Result.ok pds_handle =>
                    match pds_handle {
                      Pair.pair pds doc_handle =>
                        let handle : Option String :=
                          if String.starts_with "did:" input
                          then doc_handle
                          else Option.some input in
                        return (Result.ok {
                          did := did, pds := pds, handle := handle
                        }),
                    },
                },
            },
        }
      }
    }
  }
}

/// `did:web:example.com%3A8443` -> `example.com:8443`: the DID method-specific
/// id is percent-encoded, so the whole host decodes in one pass.
def Atproto.decode_web_host (host : String) : String :=
  Uri.percent_decode_or host host

// ── server metadata ─────────────────────────────────────────────────────

/// The PDS's protected-resource metadata names its authorization servers;
/// ATproto uses exactly one.
pub def Atproto.authorization_server_of (cfg : AtprotoConfig) (pds : String)
  : IO (Result String String) := do {
  let res_r <- Atproto.get cfg.http
    (String.concat_list [pds, "/.well-known/oauth-protected-resource"]) Headers.empty;
  match res_r {
    Result.err e => return (Result.err e),
    Result.ok res =>
      if Bool.not (Atproto.ok_status res)
      then return (Result.err "the PDS publishes no oauth-protected-resource metadata")
      else match Atproto.json_of res {
        Result.err e => return (Result.err e),
        Result.ok j => match Json.get_object j {
          Result.err e => return (Result.err e),
          Result.ok o => match Json.object_get "authorization_servers" o {
            Option.none => return (Result.err "the PDS metadata lists no authorization server"),
            Option.some arr => match Json.get_array arr {
              Result.err _ => return (Result.err "authorization_servers is not an array"),
              Result.ok servers =>
                match servers {
                  List.empty => return (Result.err "authorization_servers is empty"),
                  List.cons first _ => match Json.get_str first {
                    Result.err e => return (Result.err e),
                    Result.ok issuer => return (Result.ok (Atproto.trim_slash issuer)),
                  },
                },
            },
          },
        },
      },
  }
}

/// The AS metadata (RFC 8414) with the ATproto-required shape: an issuer
/// matching the fetch origin, an https (or explicit dev http) origin, both
/// endpoints, a PAR endpoint and ES256 among the DPoP algorithms.
pub def Atproto.authorization_server (cfg : AtprotoConfig) (issuer : String)
  : IO (Result String AtprotoServer) := do {
  let res_r <- Atproto.get cfg.http
    (String.concat_list [issuer, "/.well-known/oauth-authorization-server"])
    Headers.empty;
  match res_r {
    Result.err e => return (Result.err e),
    Result.ok res =>
      if Bool.not (Atproto.ok_status res)
      then return (Result.err "could not fetch the authorization-server metadata")
      else match Atproto.json_of res {
        Result.err e => return (Result.err e),
        Result.ok j =>
          match Atproto.str_field j "issuer" {
            Result.err e => return (Result.err e),
            Result.ok doc_issuer =>
              if Bool.not (String.beq (Atproto.trim_slash doc_issuer) issuer)
              then return (Result.err "the AS metadata issuer does not match its origin")
              else if Bool.not (Atproto.origin_allowed issuer)
              then return (Result.err "the AS origin must be https (or a dev http origin)")
              else match Atproto.str_field j "authorization_endpoint" {
                Result.err e => return (Result.err e),
                Result.ok authorization_endpoint =>
                  match Atproto.str_field j "token_endpoint" {
                    Result.err e => return (Result.err e),
                    Result.ok token_endpoint =>
                      match (Atproto.str_field j
                        "pushed_authorization_request_endpoint") {
                        Result.err e =>
                          return (Result.err "the AS publishes no PAR endpoint"),
                        Result.ok par_endpoint =>
                          if Bool.not (Atproto.supports_es256 j)
                          then return (Result.err "the AS does not support ES256 DPoP")
                          else return (Result.ok {
                            issuer := issuer,
                            authorization_endpoint := authorization_endpoint,
                            token_endpoint := token_endpoint,
                            par_endpoint := par_endpoint
                          }),
                      },
                  },
              },
          },
      },
  }
}

/// https origins are always allowed; plain http only for loopback/localhost
/// (development clients and test stubs). The loopback host may carry any
/// port (`http://localhost:8080` is the dev redirect's own origin).
def Atproto.origin_allowed (origin : String) : Bool :=
  if String.starts_with "https://" origin
  then true
  else if String.starts_with "http://" origin
  then
    let host := Atproto.host_of origin in
    String.beq host "localhost"
      || String.starts_with "localhost:" host
      || String.starts_with "127.0.0.1:" host
      || String.beq host "127.0.0.1"
  else false

/// The authority of an origin string (`scheme://host[:port]` -> `host[:port]`).
def Atproto.host_of (origin : String) : String :=
  match Strings.split_on "://" origin {
    List.cons _ rest =>
      match rest {
        List.empty => origin,
        List.cons authority _ => authority,
      },
    List.empty => origin,
  }

/// `dpop_signing_alg_values_supported` must exist and include ES256.
def Atproto.supports_es256 (metadata : Json) : Bool :=
  match Json.get_object metadata {
    Result.err _ => false,
    Result.ok o => match Json.object_get "dpop_signing_alg_values_supported" o {
      Option.none => false,
      Option.some arr => match Json.get_array arr {
        Result.err _ => false,
        Result.ok algs => List.any
          (fn (v : Json) =>
            match Json.get_str v {
              Result.err _ => false,
              Result.ok s => String.beq s "ES256",
            })
          algs,
      },
    },
  }

// ── DPoP request plumbing ───────────────────────────────────────────────

/// The `DPoP` header for one request. `htu` is the URI without query or
/// fragment; `ath` is set when the request carries an access token.
def Atproto.dpop_headers (key : DpopKey) (iss : String) (htm : String)
    (htu : String) (now : I64) (jti : String) (nonce : Option String)
    (ath : Option String) : IO (Result String Headers) := do {
  let proof_r <- Dpop.proof key Codec.json_string iss htm htu now jti nonce ath;
  match proof_r {
    Result.err e => return (Result.err e),
    Result.ok proof => return (Result.ok
      (Headers.set "DPoP" proof Atproto.form_content_type)),
  }
}

/// The response's `DPoP-Nonce`, when the server sent one.
def Atproto.nonce_of (res : Response) : Option String :=
  Headers.get "DPoP-Nonce" res.headers

/// The `use_dpop_nonce` signal: a 400 with `error=use_dpop_nonce` (the
/// authorization-server form) or a 401 with
/// `WWW-Authenticate: DPoP ... error="use_dpop_nonce"` (the resource-server
/// form).
def Atproto.use_dpop_nonce (res : Response) : Bool :=
  if U16.beq res.status 400u16
  then
    match Json.parse (Atproto.body_text res) {
      Result.err _ => false,
      Result.ok j => match Json.get_object j {
        Result.err _ => false,
        Result.ok o => match Json.object_get "error" o {
          Option.none => false,
          Option.some v => match Json.get_str v {
            Result.err _ => false,
            Result.ok s => String.beq s "use_dpop_nonce",
          },
        },
      },
    }
  else if U16.beq res.status 401u16
  then
    match Headers.get "WWW-Authenticate" res.headers {
      Option.none => false,
      Option.some v =>
        String.starts_with "DPoP" v && String.contains v "use_dpop_nonce",
    }
  else false

/// One DPoP-protected POST, retrying once when the server demands a nonce.
/// Returns the final response together with the server's current nonce.
def Atproto.dpop_post (cfg : AtprotoConfig) (url : String) (body : String)
    (key : DpopKey) (iss : String) (nonce : Option String) (ath : Option String)
    (now : I64) (jti : String)
  : IO (Result String (Pair Response (Option String))) := do {
  let hdrs_r <- Atproto.dpop_headers key iss "POST" url now jti nonce ath;
  match hdrs_r {
    Result.err e => return (Result.err e),
    Result.ok hdrs => do {
      let res_r <- Atproto.post cfg.http url hdrs body;
      match res_r {
        Result.err e => return (Result.err e),
        Result.ok res =>
          let fresh := Atproto.nonce_of res in
          if Atproto.use_dpop_nonce res
          then match fresh {
            Option.none => return (Result.ok (Pair.pair res Option.none)),
            Option.some n => do {
              let retry_hdrs_r <- Atproto.dpop_headers key iss "POST" url now jti
                (Option.some n) ath;
              match retry_hdrs_r {
                Result.err e => return (Result.err e),
                Result.ok retry_hdrs => do {
                  let retry_r <- Atproto.post cfg.http url retry_hdrs body;
                  match retry_r {
                    Result.err e => return (Result.err e),
                    Result.ok retry_res =>
                      return (Result.ok
                        (Pair.pair retry_res (Atproto.nonce_of retry_res))),
                  }
                },
              }
            },
          }
          else return (Result.ok (Pair.pair res fresh)),
      }
    }
  }
}

/// One DPoP-protected GET (the PDS session confirmation), with the same
/// one-retry nonce handling.
def Atproto.dpop_get (cfg : AtprotoConfig) (url : String)
    (key : DpopKey) (iss : String) (access_token : String)
    (nonce : Option String) (now : I64) (jti : String)
  : IO (Result String (Pair Response (Option String))) := do {
  let ath : Option String := Option.some
    (B64Url.encode (Sha256.hash_bytes (String.to_list access_token)));
  let hdrs_r <- Atproto.dpop_headers key iss "GET" url now jti nonce ath;
  match hdrs_r {
    Result.err e => return (Result.err e),
    Result.ok dpop_only => do {
      let hdrs := Headers.set "Authorization"
        (String.concat "DPoP " access_token) dpop_only;
      let res_r <- Atproto.get cfg.http url hdrs;
      match res_r {
        Result.err e => return (Result.err e),
        Result.ok res =>
          let fresh := Atproto.nonce_of res in
          if Atproto.use_dpop_nonce res
          then match fresh {
            Option.none => return (Result.ok (Pair.pair res Option.none)),
            Option.some n => do {
              let retry_hdrs_r <- Atproto.dpop_headers key iss "GET" url now jti
                (Option.some n) ath;
              match retry_hdrs_r {
                Result.err e => return (Result.err e),
                Result.ok retry_dpop => do {
                  let retry_hdrs := Headers.set "Authorization"
                    (String.concat "DPoP " access_token) retry_dpop;
                  let retry_r <- Atproto.get cfg.http url retry_hdrs;
                  match retry_r {
                    Result.err e => return (Result.err e),
                    Result.ok retry_res =>
                      return (Result.ok
                        (Pair.pair retry_res (Atproto.nonce_of retry_res))),
                  }
                },
              }
            },
          }
          else return (Result.ok (Pair.pair res fresh)),
      }
    }
  }
}

// ── PAR and the authorization redirect ──────────────────────────────────

/// `application/x-www-form-urlencoded` body from ordered pairs. The uri
/// mote's query formatter is exactly the encoder OAuth needs (RFC 3986
/// unreserved kept, everything else percent-encoded).
def Atproto.form_body (pairs : List (Pair String String)) : String :=
  Uri.format_query pairs

/// The result of a successful PAR: the AS's `request_uri` plus its latest
/// `DPoP-Nonce` for the requests that follow.
pub struct AtprotoPar {
  request_uri : String,
  nonce : Option String
}

/// Pushed Authorization Request (RFC 9126) with the ATproto additions:
/// PKCE S256, the client's DPoP JKT (so the AS can bind the eventual tokens
/// to this login attempt's key) and a DPoP proof over the PAR request
/// itself. One `use_dpop_nonce` retry is handled inside.
pub def Atproto.par (cfg : AtprotoConfig) (server : AtprotoServer)
    (login_hint : String) (state : String) (verifier : String)
    (jkt : String) (key : DpopKey) (nonce : Option String) (now : I64) (jti : String)
  : IO (Result String AtprotoPar) := do {
  let body := Atproto.form_body [
    Pair.pair "response_type" "code",
    Pair.pair "client_id" cfg.client_id,
    Pair.pair "redirect_uri" cfg.redirect_uri,
    Pair.pair "scope" cfg.scope,
    Pair.pair "state" state,
    Pair.pair "code_challenge" (Pkce.challenge verifier),
    Pair.pair "code_challenge_method" Pkce.method,
    Pair.pair "login_hint" login_hint,
    Pair.pair "dpop_jkt" jkt
  ];
  let res_r <- Atproto.dpop_post cfg server.par_endpoint body key
    server.issuer nonce Option.none now jti;
  match res_r {
    Result.err e => return (Result.err e),
    Result.ok res_fresh =>
      match res_fresh {
        Pair.pair res fresh =>
          if Bool.not (Atproto.ok_status res)
          then return (Result.err ("the authorization server rejected the PAR: "
            ++ Atproto.body_text res))
          else match Atproto.json_of res {
            Result.err e => return (Result.err e),
            Result.ok j => match Atproto.str_field j "request_uri" {
              Result.err e => return (Result.err e),
              Result.ok request_uri =>
                let out : AtprotoPar :=
                  { request_uri := request_uri, nonce := fresh } in
                return (Result.ok out),
            },
          },
      },
  }
}

/// The 302 target: authorization endpoint + client_id + request_uri.
pub def Atproto.authorize_url (cfg : AtprotoConfig) (server : AtprotoServer)
    (par : AtprotoPar) : String :=
  String.concat_list [
    server.authorization_endpoint, "?",
    "client_id=", Uri.percent_encode cfg.client_id,
    "&request_uri=", Uri.percent_encode par.request_uri
  ]

/// The token exchange on the callback. The code came in on our redirect,
/// the verifier is ours, the DPoP key is the one the JKT committed to, and
/// the AS's `sub` must be the DID we resolved before the redirect. The
/// `atproto` scope must survive the grant, and `token_type` must be DPoP.
pub def Atproto.exchange_code (cfg : AtprotoConfig) (server : AtprotoServer)
    (code : String) (verifier : String) (did : String) (key : DpopKey)
    (nonce : Option String) (now : I64) (jti : String)
  : IO (Result String AtprotoTokens) := do {
  let body := Atproto.form_body [
    Pair.pair "grant_type" "authorization_code",
    Pair.pair "code" code,
    Pair.pair "redirect_uri" cfg.redirect_uri,
    Pair.pair "client_id" cfg.client_id,
    Pair.pair "code_verifier" verifier
  ];
  let res_r <- Atproto.dpop_post cfg server.token_endpoint body key
    server.issuer nonce Option.none now jti;
  match res_r {
    Result.err e => return (Result.err e),
    Result.ok res_fresh =>
      match res_fresh {
        Pair.pair res fresh =>
          if Bool.not (Atproto.ok_status res)
          then return (Result.err ("the token exchange failed: "
            ++ Atproto.body_text res))
          else match Atproto.json_of res {
        Result.err e => return (Result.err e),
        Result.ok j =>
          match Atproto.str_field j "token_type" {
            Result.err e => return (Result.err e),
            Result.ok token_type =>
              if Bool.not (String.beq token_type "DPoP")
              then return (Result.err "the AS did not issue a DPoP token")
              else match Atproto.str_field j "access_token" {
                Result.err e => return (Result.err e),
                Result.ok access_token =>
                  match Atproto.str_field j "sub" {
                    Result.err e => return (Result.err e),
                    Result.ok sub =>
                      if Bool.not (String.beq sub did)
                      then return (Result.err "the AS issued tokens for a different identity")
                      else match Atproto.str_field j "scope" {
                        Result.err e => return (Result.err e),
                        Result.ok scope =>
                          if Bool.not (Atproto.scope_has_atproto scope)
                          then return (Result.err "the grant lost the atproto scope")
                          else match Atproto.opt_str_field j "iss" {
                            Option.some iss =>
                              if Bool.not (String.beq
                                  (Atproto.trim_slash iss) server.issuer)
                              then return (Result.err "the token issuer does not match the AS")
                              else return (Atproto.tokens_of j access_token sub scope fresh),
                            Option.none =>
                              return (Atproto.tokens_of j access_token sub scope fresh),
                          },
                      },
                  },
              },
          },
        },
      },
  }
}

/// `expires_in` is optional in the shape checks above but the ATproto
/// reference always sends it; a missing one becomes a conservative 15 min.
def Atproto.tokens_of (j : Json) (access_token : String) (sub : String)
    (scope : String) (nonce : Option String) : Result String AtprotoTokens :=
  let expires_in : I64 :=
    match Json.get_object j {
      Result.err _ => 900i64,
      Result.ok o =>
        match Json.object_get "expires_in" o {
          Option.none => 900i64,
          Option.some v =>
            match Json.get_num_i64 (Json.get_num v) {
              Result.ok n => n,
              Result.err _ => 900i64,
            },
        },
    } in
  let out : AtprotoTokens := {
    access_token := access_token,
    sub := sub,
    scope := scope,
    expires_in := expires_in,
    refresh_token := Atproto.opt_str_field j "refresh_token",
    nonce := nonce
  } in
  Result.ok out

/// `scope` is a space-separated list; ATproto requires `atproto` to survive.
def Atproto.scope_has_atproto (scope : String) : Bool :=
  List.any (fn (s : String) => String.beq (String.trim s) "atproto")
    (Strings.split_on " " scope)

/// `com.atproto.server.getSession` on the PDS, through the DPoP-bound
/// access token. The PDS is a resource server: `Authorization: DPoP` with
/// the `ath` claim, and its own `DPoP-Nonce` if it demands one.
pub def Atproto.get_session (cfg : AtprotoConfig) (pds : String)
    (key : DpopKey) (iss : String) (access_token : String)
    (nonce : Option String) (now : I64) (jti : String)
  : IO (Result String AtprotoSessionInfo) := do {
  let url := String.concat_list [
    pds, "/xrpc/com.atproto.server.getSession"
  ];
  let res_r <- Atproto.dpop_get cfg url key iss access_token nonce now jti;
  match res_r {
    Result.err e => return (Result.err e),
    Result.ok res_nonce =>
      match res_nonce {
        Pair.pair res _ =>
          if Bool.not (Atproto.ok_status res)
          then return (Result.err ("the PDS rejected the session request: "
            ++ Atproto.body_text res))
          else match Atproto.json_of res {
            Result.err e => return (Result.err e),
            Result.ok j =>
              match Atproto.str_field j "did" {
                Result.err e => return (Result.err e),
                Result.ok session_did => match Atproto.str_field j "handle" {
                  Result.err e => return (Result.err e),
                  Result.ok handle =>
                    let out : AtprotoSessionInfo := {
                      did := session_did,
                      handle := handle,
                      email := Atproto.opt_str_field j "email"
                    } in
                    return (Result.ok out),
                },
              },
          },
      },
  }
}

// ── tests ───────────────────────────────────────────────────────────────
//
// No socket: the whole flow runs against `OauthHttp.fake`, the oauth mote's
// scriptable transport. The DPoP keys are real FFI-generated P-256 pairs,
// so the proofs here are the same bytes a production server sees.

/// Struct literals in list position are not inferred by both hosts, so
/// every fixture goes through an annotated constructor.
def atp_ex (path : String) (status : U16) (body : String) : ScriptedExchange :=
  let ex : ScriptedExchange := {
    path := path,
    status := status,
    body := body,
    headers := Headers.empty,
    body_contains := ""
  } in
  ex

/// A scripted entry that carries a `DPoP-Nonce` response header.
def atp_ex_nonce (path : String) (status : U16) (body : String) (nonce : String)
  : ScriptedExchange :=
  let ex : ScriptedExchange := {
    path := path,
    status := status,
    body := body,
    headers := Headers.set "DPoP-Nonce" nonce Headers.empty,
    body_contains := ""
  } in
  ex

def atp_did_doc : String :=
  "{\"@context\":[\"https://www.w3.org/ns/did/v1\"],\"id\":\"did:plc:abc123\",\"alsoKnownAs\":[\"at://alice.test\"],\"service\":[{\"id\":\"#atproto_pds\",\"type\":\"AtprotoPersonalDataServer\",\"serviceEndpoint\":\"https://pds.test/\"}]}"

def atp_protected_doc : String :=
  "{\"registration_endpoint\":\"https://as.test/client-metadata.json\",\"authorization_servers\":[\"https://as.test\"]}"

def atp_as_doc : String :=
  "{\"issuer\":\"https://as.test\",\"authorization_endpoint\":\"https://as.test/authorize\",\"token_endpoint\":\"https://as.test/token\",\"pushed_authorization_request_endpoint\":\"https://as.test/par\",\"dpop_signing_alg_values_supported\":[\"ES256\",\"EdDSA\"],\"response_types_supported\":[\"code\"],\"code_challenge_methods_supported\":[\"S256\"]}"

def atp_resolve_doc : String := "{\"did\":\"did:plc:abc123\"}"

def atp_session_doc : String :=
  "{\"did\":\"did:plc:abc123\",\"handle\":\"alice.test\",\"email\":\"alice@example.test\"}"

def atp_par_doc : String :=
  "{\"request_uri\":\"urn:ietf:params:oauth:request_uri:abc\"}"

def atp_nonce_err_doc : String := "{\"error\":\"use_dpop_nonce\"}"

def atp_token_doc : String :=
  "{\"access_token\":\"at_123\",\"token_type\":\"DPoP\",\"sub\":\"did:plc:abc123\",\"scope\":\"atproto offline_access\",\"expires_in\":3600,\"refresh_token\":\"rt_123\",\"iss\":\"https://as.test\"}"

def atp_config_of (http : OauthHttp) : AtprotoConfig :=
  let cfg : AtprotoConfig := {
    http := http,
    client_id :=
      "http://localhost?redirect_uri=http%3A%2F%2Flocalhost%3A8080%2Fauth%2Fcallback&scope=atproto",
    redirect_uri := "http://localhost:8080/auth/callback",
    scope := "atproto",
    resolver_base := "https://resolver.test",
    plc_base := "https://plc.test"
  } in
  cfg

#[test]
def test_atproto_normalizes_login_input : Bool :=
  (match Atproto.normalize_input "  @Alice.Test " {
    Result.ok h => h == "alice.test",
    Result.err _ => false,
  })
  && (match Atproto.normalize_input "did:plc:AbC-123" {
    Result.ok d => d == "did:plc:AbC-123",
    Result.err _ => false,
  })
  && (match Atproto.normalize_input "did:web:example.com" {
    Result.ok d => d == "did:web:example.com",
    Result.err _ => false,
  })
  && (match Atproto.normalize_input "   " {
    Result.ok _ => false,
    Result.err _ => true,
  })
  && Bool.not (Atproto.origin_allowed "http://as.example")
  && Atproto.origin_allowed "http://localhost:8080"
  && Atproto.origin_allowed "https://as.example"
  && Atproto.scope_has_atproto "atproto offline_access"
  && Bool.not (Atproto.scope_has_atproto "profile")

/// The login handler's first seam (`Auth.begin_login`): normalize the raw
/// input, then resolve. The flow test drives this, so it covers the exact
/// production path from form input to identity.
def atp_resolve (cfg : AtprotoConfig) (raw : String)
  : IO (Result String AtprotoIdentity) := do {
  let input_r := Atproto.normalize_input raw;
  match input_r {
    Result.err e => IO.pure (Result.err e),
    Result.ok input => Atproto.resolve_identity cfg input,
  }
}

#[test]
def test_atproto_end_to_end : IO Bool := do {
  // The raw form input is normalized first (atp_resolve); the handle's own
  // atproto-did record is missing here, so the flow has to fall back to
  // the resolver's resolveHandle endpoint.
  let gets : List ScriptedExchange := [
    atp_ex "/.well-known/atproto-did" 404u16 "not found",
    atp_ex "/xrpc/com.atproto.identity.resolveHandle" 200u16 atp_resolve_doc,
    atp_ex "/did:plc:abc123" 200u16 atp_did_doc,
    atp_ex "/.well-known/oauth-protected-resource" 200u16 atp_protected_doc,
    atp_ex "/.well-known/oauth-authorization-server" 200u16 atp_as_doc,
    atp_ex "/xrpc/com.atproto.server.getSession" 200u16 atp_session_doc
  ];
  // The first PAR is rejected with `use_dpop_nonce`; the retry must carry
  // the server's nonce and the second script entry answers it.
  let posts : List ScriptedExchange := [
    atp_ex_nonce "/par" 400u16 atp_nonce_err_doc "n1",
    atp_ex_nonce "/par" 200u16 atp_par_doc "n2",
    atp_ex_nonce "/token" 200u16 atp_token_doc "n3"
  ];
  let http <- OauthHttp.fake gets posts;
  let cfg : AtprotoConfig := atp_config_of http;
  let identity_r <- atp_resolve cfg "Alice.Test ";
  match identity_r {
    Result.err e => do {
      let _ <- IO.write_stderr ("atproto flow: identity: " ++ e ++ "\n");
      return false
    },
    Result.ok identity => do {
      let issuer_r <- Atproto.authorization_server_of cfg identity.pds;
      match issuer_r {
        Result.err e => do {
          let _ <- IO.write_stderr ("atproto flow: protected resource: " ++ e ++ "\n");
          return false
        },
        Result.ok issuer => do {
          let server_r <- Atproto.authorization_server cfg issuer;
          match server_r {
            Result.err e => do {
              let _ <- IO.write_stderr ("atproto flow: AS metadata: " ++ e ++ "\n");
              return false
            },
            Result.ok server => do {
              let key_r <- Dpop.generate;
              match key_r {
                Result.err e => do {
                  let _ <- IO.write_stderr ("atproto flow: keygen: " ++ e ++ "\n");
                  return false
                },
                Result.ok key => match Dpop.jkt key {
                  Result.err e => do {
                    let _ <- IO.write_stderr ("atproto flow: jkt: " ++ e ++ "\n");
                    return false
                  },
                  Result.ok jkt => do {
                    let par_r <- Atproto.par cfg server "alice.test"
                      "state-1" "verifier-1" jkt key Option.none 1000i64 "jti-1";
                    match par_r {
                      Result.err e => do {
                        let _ <- IO.write_stderr ("atproto flow: par: " ++ e ++ "\n");
                        return false
                      },
                      Result.ok par => do {
                        let tokens_r <- Atproto.exchange_code cfg server
                          "code-1" "verifier-1" identity.did key par.nonce
                          1000i64 "jti-2";
                        match tokens_r {
                          Result.err e => do {
                            let _ <- IO.write_stderr ("atproto flow: token: " ++ e ++ "\n");
                            return false
                          },
                          Result.ok tokens => do {
                            let session_r <- Atproto.get_session cfg identity.pds
                              key server.issuer tokens.access_token tokens.nonce
                              1000i64 "jti-3";
                            match session_r {
                              Result.err e => do {
                                let _ <- IO.write_stderr ("atproto flow: session: " ++ e ++ "\n");
                                return false
                              },
                              Result.ok session => do {
                                // Each conjunct gets a name so a failure
                                // prints exactly which leg broke. Do-block
                                // lets are statements (`;`), not `let..in`.
                                let c_did : Bool :=
                                  identity.did == "did:plc:abc123";
                                let c_pds : Bool :=
                                  identity.pds == "https://pds.test";
                                let c_handle : Bool := match identity.handle {
                                  Option.some h => h == "alice.test",
                                  Option.none => false,
                                };
                                let c_issuer : Bool :=
                                  server.issuer == "https://as.test";
                                let c_par_ep : Bool :=
                                  server.par_endpoint == "https://as.test/par";
                                let c_req_uri : Bool :=
                                  par.request_uri
                                    == "urn:ietf:params:oauth:request_uri:abc";
                                let c_par_nonce : Bool := match par.nonce {
                                  Option.some n => n == "n2",
                                  Option.none => false,
                                };
                                let c_auth_url : Bool := String.contains
                                  (Atproto.authorize_url cfg server par)
                                  "request_uri=urn%3Aietf";
                                let c_access : Bool :=
                                  tokens.access_token == "at_123";
                                let c_sub : Bool :=
                                  tokens.sub == "did:plc:abc123";
                                let c_scope : Bool :=
                                  Atproto.scope_has_atproto tokens.scope;
                                let c_expires : Bool :=
                                  tokens.expires_in == 3600i64;
                                let c_refresh : Bool :=
                                  match tokens.refresh_token {
                                    Option.some r => r == "rt_123",
                                    Option.none => false,
                                  };
                                let c_sess_did : Bool :=
                                  session.did == "did:plc:abc123";
                                let c_sess_handle : Bool :=
                                  session.handle == "alice.test";
                                let c_sess_email : Bool :=
                                  match session.email {
                                    Option.some e => e == "alice@example.test",
                                    Option.none => false,
                                  };
                                let ok_all : Bool := c_did && c_pds && c_handle
                                  && c_issuer && c_par_ep && c_req_uri
                                  && c_par_nonce && c_auth_url && c_access
                                  && c_sub && c_scope && c_expires && c_refresh
                                  && c_sess_did && c_sess_handle && c_sess_email;
                                if Bool.not ok_all
                                then do {
                                  let _ <- IO.write_stderr (String.concat_list [
                                    "atproto e2e failed:",
                                    (if Bool.not c_did then " did" else ""),
                                    (if Bool.not c_pds then " pds" else ""),
                                    (if Bool.not c_handle then " handle" else ""),
                                    (if Bool.not c_issuer then " issuer" else ""),
                                    (if Bool.not c_par_ep then " par_ep" else ""),
                                    (if Bool.not c_req_uri then " req_uri" else ""),
                                    (if Bool.not c_par_nonce then " par_nonce" else ""),
                                    (if Bool.not c_auth_url then " auth_url" else ""),
                                    (if Bool.not c_access then " access" else ""),
                                    (if Bool.not c_sub then " sub" else ""),
                                    (if Bool.not c_scope then " scope" else ""),
                                    (if Bool.not c_expires then " expires" else ""),
                                    (if Bool.not c_refresh then " refresh" else ""),
                                    (if Bool.not c_sess_did then " sess_did" else ""),
                                    (if Bool.not c_sess_handle then " sess_handle" else ""),
                                    (if Bool.not c_sess_email then " sess_email" else ""),
                                    "\n"
                                  ]);
                                  return false
                                }
                                else return true
                              },
                            }
                          },
                        }
                      },
                    }
                  },
                },
              }
            },
          }
        },
      }
    },
  }
}

#[test]
def test_atproto_rejects_mismatched_sub : IO Bool := do {
  let gets : List ScriptedExchange := [
    atp_ex "/did:plc:abc123" 200u16 atp_did_doc,
    atp_ex "/.well-known/oauth-protected-resource" 200u16 atp_protected_doc,
    atp_ex "/.well-known/oauth-authorization-server" 200u16 atp_as_doc
  ];
  let posts : List ScriptedExchange := [
    atp_ex_nonce "/par" 200u16 atp_par_doc "n1",
    atp_ex_nonce "/token" 200u16
      "{\"access_token\":\"at_123\",\"token_type\":\"DPoP\",\"sub\":\"did:plc:other\",\"scope\":\"atproto\",\"expires_in\":3600}"
      "n2"
  ];
  let http <- OauthHttp.fake gets posts;
  let cfg : AtprotoConfig := atp_config_of http;
  let identity_r <- Atproto.resolve_identity cfg "did:plc:abc123";
  match identity_r {
    Result.err e => do {
      let _ <- IO.write_stderr ("mismatched sub: identity: " ++ e ++ "\n");
      return false
    },
    Result.ok identity => do {
      let issuer_r <- Atproto.authorization_server_of cfg identity.pds;
      match issuer_r {
        Result.err e => do {
          let _ <- IO.write_stderr ("mismatched sub: AS of: " ++ e ++ "\n");
          return false
        },
        Result.ok issuer => do {
          let server_r <- Atproto.authorization_server cfg issuer;
          match server_r {
            Result.err e => do {
              let _ <- IO.write_stderr ("mismatched sub: AS: " ++ e ++ "\n");
              return false
            },
            Result.ok server => do {
              let key_r <- Dpop.generate;
              match key_r {
                Result.err e => do {
                  let _ <- IO.write_stderr ("mismatched sub: keygen: " ++ e ++ "\n");
                  return false
                },
                Result.ok key => match Dpop.jkt key {
                  Result.err e => do {
                    let _ <- IO.write_stderr ("mismatched sub: jkt: " ++ e ++ "\n");
                    return false
                  },
                  Result.ok jkt => do {
                    let par_r <- Atproto.par cfg server "did:plc:abc123"
                      "state-1" "verifier-1" jkt key Option.none 1000i64 "jti-1";
                    match par_r {
                      Result.err e => do {
                        let _ <- IO.write_stderr ("mismatched sub: par: " ++ e ++ "\n");
                        return false
                      },
                      Result.ok par => do {
                        let tokens_r <- Atproto.exchange_code cfg server
                          "code-1" "verifier-1" identity.did key par.nonce
                          1000i64 "jti-2";
                        return (match tokens_r {
                          Result.ok _ => false,
                          Result.err e => String.contains e "different identity",
                        })
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
}

#[test]
def test_atproto_rejects_issuer_mismatch : IO Bool := do {
  let gets : List ScriptedExchange := [
    atp_ex "/.well-known/oauth-authorization-server" 200u16
      "{\"issuer\":\"https://evil.test\",\"authorization_endpoint\":\"https://evil.test/authorize\",\"token_endpoint\":\"https://evil.test/token\",\"pushed_authorization_request_endpoint\":\"https://evil.test/par\",\"dpop_signing_alg_values_supported\":[\"ES256\"]}"
  ];
  let http <- OauthHttp.fake gets List.empty;
  let cfg : AtprotoConfig := atp_config_of http;
  let r <- Atproto.authorization_server cfg "https://as.test";
  return (match r {
    Result.ok _ => false,
    Result.err e => String.contains e "does not match",
  })
}
