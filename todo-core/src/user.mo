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
  /// Fixed display offset east of UTC, in minutes (e.g. 120 for UTC+02:00).
  /// Storage is UTC; there is no IANA/DST database at the pinned Monad
  /// revision, so this offset is what the user selects. See `lib::stamp`.
  utc_offset_minutes : I64,
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

/// The short-lived login-flow row. The first five fields are the generic
/// OAuth2/OIDC shape; the ATproto fields carry what the callback needs to
/// finish a DPoP login: the authorization-server `issuer`, the account's
/// PDS origin, the DID the user is signing in as, the display handle, and
/// the halves of the per-login P-256 DPoP key (base64url, dropped with the
/// row). `nonce` holds the AS's latest `DPoP-Nonce` in the ATproto flow.
pub struct OauthState {
  state : String,
  nonce : String,
  code_verifier : String,
  redirect_to : Option String,
  expires_at : String,
  issuer : String := "",
  pds : String := "",
  did : String := "",
  handle : Option String := Option.none,
  dpop_priv : String := "",
  dpop_pub : String := ""
}
