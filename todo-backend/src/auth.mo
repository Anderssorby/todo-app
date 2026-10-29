/// Authentication context and the development-only sign-in stub.
///
/// Production sign-in is generic OAuth2/OIDC through the upcoming `oauth`
/// mote (see the workspace plan). That mote is not in the pinned Monad
/// revision, so this module currently provides the request context and a
/// clearly gated dev path: `TODO_DEV_AUTH=1` (or `--dev-auth`) resolves a
/// local `dev` user and no session cookie. The dev path is never enabled in
/// the image/Kubernetes manifest, and it is removed when the OIDC flow
/// lands.
///
/// The workspace is shared; `Context.user` is the actor used for
/// attribution, not an ownership filter.
use todo_core::user {OidcIdentity, User}
use lib::db {Db.find_or_create_user, Store}
use http::types {
  Body, Headers, HttpVersion, Request, Response, Response.ok_text, Response.redirect,
  Status.found, Status.internal_server_error, Status.unauthorized
}

pub struct Context {
  store : Store,
  user : User,
  csrf : String
}

pub struct Config {
  store : Store,
  dev_auth : Bool
}

pub def Auth.dev_identity : OidcIdentity :=
  let i : OidcIdentity := {
    issuer := "dev", subject := "dev", email := Option.none,
    name := "Dev User", picture := Option.none
  } in i

pub def Auth.dev_csrf : String := "dev-csrf"

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

/// Resolve the request's actor. Dev mode authenticates every request as the
/// local dev user; without a real session the request is rejected (JSON
/// 401, HTML redirect to /login).
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
  } else if String.starts_with "/api/" req.uri.path then
    return Auth.json_unauthorized
  else
    return Auth.redirect_login
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
