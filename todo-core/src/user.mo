/// Shared user/identity types.
///
/// These are pure data, used by the native backend (SQLite rows and auth),
/// the shared codec, and the wasm SPA (`/api/me`, attribution, timezone).
/// JSON encoding/decoding lives in `lib::codec` so this module stays a leaf.
///
/// The workspace is shared: a `UserRef` is attribution for a todo, not an
/// ownership key. `User` is the current signed-in profile; `OidcIdentity` is
/// the normalized result of a generic OAuth2/OIDC callback; `OauthState` is
/// the short-lived login-flow row (state, nonce, PKCE verifier).
pub struct UserRef {
  id : I64,
  name : String
}

pub struct User {
  id : I64,
  issuer : String,
  subject : String,
  email : Option String,
  name : String,
  picture : Option String,
  /// IANA timezone name used only for display; storage is UTC.
  timezone : String,
  created_at : String,
  updated_at : String
}

pub struct OidcIdentity {
  issuer : String,
  subject : String,
  email : Option String,
  name : String,
  picture : Option String
}

pub struct OauthState {
  state : String,
  nonce : String,
  code_verifier : String,
  redirect_to : Option String,
  expires_at : String
}
