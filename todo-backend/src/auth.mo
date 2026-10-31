/// Authentication context and the development-only sign-in stub.
///
/// Production sign-in is AT Protocol OAuth (public client, identity-only
/// `atproto` scope). The pinned Monad now ships `jsonwebtoken` and an `oauth`
/// client that validates tokens, and Monad main also has a resource-server
/// bearer guard, so the old "cannot validate an ID token" blocker is closed.
/// ATproto's remaining requirement is DPoP (RFC 9449): each session must
/// generate a P-256 key and sign an ES256 proof for every authorization-server
/// and PDS request. Monad's `crypto` mote currently only verifies ES256; it
/// cannot generate a key or sign, so production sign-in is deliberately
/// deferred and this module provides only the request context plus a clearly
/// gated dev path: `TODO_DEV_AUTH=1` (or `--dev-auth`) resolves a local `dev`
/// user and no session cookie. The dev path is never enabled in the
/// image/Kubernetes manifest, and it is removed when the ATproto DPoP flow
/// lands. The missing crypto capability is tracked in
/// `monad-plans/library-ideas/crypto-primitives.md`.
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
