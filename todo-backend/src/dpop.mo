/// Per-session P-256 keys and ES256 DPoP proofs (RFC 9449), app-local.
///
/// This module is the temporary seam that unblocks AT Protocol sign-in
/// (see `atproto.mo`): the pinned `crypto` mote VERIFIES ES256 but cannot
/// generate a P-256 key or sign, and ATproto requires a DPoP proof on every
/// authorization-server and PDS request. The upstream capability is planned
/// as Phase 4 of `monad-plans/library-ideas/crypto-primitives.md`
/// (`atproto-dpop-needs-es256-signing`); when it lands, this module shrinks
/// to the JWK/thumbprint/proof JSON assembly over the mote's key type and
/// the FFI declarations here are deleted.
///
/// The FFI follows `motes/crypto/src/ffi.mo` and `motes/tls/src/ffi.mo`:
/// declarative `#[extern "c"]]`, symbols bind by name at link time, and
/// `-lcrypto` is declared by this app's own `todo-backend/mote.toml`
/// `[link]` table (nothing here may `use` a `crypto::` module — the
/// symbol-partitioning note above the externs explains why).
/// Borrowed-pointer reads (`EC_KEY_get0_*`, `EVP_sha256`) keep their raw
/// types; everything that allocates, mutates or frees is `RawIO` and is
/// bound with `IO.mk`. The `Ptr` handles never escape this module.
///
/// Memory-safety boundary (the crypto mote's AGENTS.md rule): every byte
/// argument is a `ByteBuf.ptr` with that buffer's own `ByteBuf.length`; no
/// `I64 -> Ptr`, no pointer arithmetic, no generic load/store.
///
/// Known deviations from the upstream plan, both deliberate:
/// - No low-S normalization. RFC 7518 accepts either s form, DPoP verifiers
///   (RFC 9449) validate through standard JOSE, and the atproto reference
///   provider does not require it. The upstream mote wants low-S anyway;
///   when the code moves there it gains the BN arithmetic.
/// - No zeroization of the freed private-scalar buffers (`OPENSSL_cleanse`
///   is Phase 1 of the upstream plan). `ByteBuf.free` returns the pages to
///   the allocator; the scalar also lives in the `oauth_states` row for the
///   lifetime of the login attempt, so process memory is not the shortest
///   path to it.
///
/// Compiled-backend only: every keygen/sign path reaches a C symbol, and
/// `ByteBuf.ptr` has no Rust-host implementation, so the FFI tests below
/// only run on the native test driver (the same shape as `db.mo`'s real
/// SQLite connection tests).

use std::base64 {B64Url.encode, B64Url.decode, B64Error.to_string}
use std::list {List.all, List.length}
use std::bytebuf {
  ByteBuf, ByteBuf.alloc, ByteBuf.free, ByteBuf.length, ByteBuf.of_list,
  ByteBuf.ptr, ByteBuf.take_ptr, ByteBuf.to_list
}
use std::sha256 {Sha256.hash_bytes}

// ── the OpenSSL symbols ─────────────────────────────────────────────────
//
// One C symbol may be `declare`d at most once per binary: monad lowers
// every `#[extern "c"]` def to a raw LLVM `declare` keyed by its link
// name and does not dedup them across modules, so two modules that both
// declare e.g. `EC_KEY_free` cannot be linked into the same test binary
// or app (`llc: invalid redefinition`). The pinned `crypto` mote's
// private `ffi.mo` declares fifteen of these names (`BN_bin2bn`,
// `BN_free`, `EC_KEY_free`, `EC_KEY_get0_group`,
// `EC_KEY_new_by_curve_name`, `EC_KEY_set_public_key`, `EC_POINT_free`,
// `EC_POINT_new`, `EC_POINT_oct2point`, `EVP_MD_CTX_free`,
// `EVP_MD_CTX_new`, `EVP_PKEY_free`, `EVP_PKEY_new`,
// `EVP_PKEY_set1_EC_KEY`, `EVP_sha256`), so while this module exists
// nothing in the backend may `use` a `crypto::` module: that would drag
// `crypto::ffi` into the same binary as these declarations. The
// `-lcrypto` link flag cannot arrive through a `use` of a `crypto::`
// module (see above), so `todo-backend/mote.toml` declares it directly
// in its own `[link]` table (`libs = ["crypto"]` with
// `pkg-config = ["openssl"]`): the linker needs the symbols even though
// no crypto module is in the compile closure. The `tls` and `sqlite`
// motes coexist here because their FFI surfaces (`SSL_*`/`TLS_*`,
// `sqlite3_*`) partition a different part of the symbol space.

/// The curve: `NID_X9_62_prime256v1`.
#[extern "c"]
def EC_KEY_new_by_curve_name (nid : I32) : RawIO Ptr

#[extern "c"]
def EC_KEY_free (key : Ptr) : RawIO Unit

/// Borrowed: the group lives inside the EC_KEY.
#[extern "c"]
def EC_KEY_get0_group (key : Ptr) : Ptr

/// Generates the public/private pair on `key`. Consumes the RNG.
#[extern "c"]
def EC_KEY_generate_key (key : Ptr) : RawIO I32

/// Borrowed: the point lives inside the EC_KEY.
#[extern "c"]
def EC_KEY_get0_public_key (key : Ptr) : Ptr

/// Borrowed: the scalar lives inside the EC_KEY.
#[extern "c"]
def EC_KEY_get0_private_key (key : Ptr) : Ptr

#[extern "c"]
def EC_KEY_set_private_key (key : Ptr) (prv : Ptr) : RawIO I32

#[extern "c"]
def EC_KEY_set_public_key (key : Ptr) (point : Ptr) : RawIO I32

#[extern "c"]
def EC_POINT_new (group : Ptr) : RawIO Ptr

#[extern "c"]
def EC_POINT_free (point : Ptr) : RawIO Unit

/// Decode one uncompressed point (`0x04 || x || y`). `ctx` is NULL.
#[extern "c"]
def EC_POINT_oct2point
  (group : Ptr) (point : Ptr) (buf : Ptr) (len : I64) (ctx : Ptr) : RawIO I32

/// Encode `point` to `form` bytes. `ctx` is NULL. Returns the bytes written.
#[extern "c"]
def EC_POINT_point2oct
  (group : Ptr) (point : Ptr) (form : I32) (buf : Ptr) (len : I64) (ctx : Ptr)
  : RawIO I64

/// Read `len` big-endian bytes into a fresh BIGNUM. `ret` is NULL (unused).
#[extern "c"]
def BN_bin2bn (buf : Ptr) (len : I32) (ret : Ptr) : RawIO Ptr

/// Write `bn` big-endian into `buf`, zero-padded to exactly `len` bytes.
/// Returns `len`, or -1 when the number does not fit.
#[extern "c"]
def BN_bn2binpad (bn : Ptr) (buf : Ptr) (len : I32) : RawIO I32

#[extern "c"]
def BN_free (bn : Ptr) : RawIO Unit

#[extern "c"]
def EVP_PKEY_new : RawIO Ptr

#[extern "c"]
def EVP_PKEY_free (pkey : Ptr) : RawIO Unit

#[extern "c"]
def EVP_PKEY_set1_EC_KEY (pkey : Ptr) (ec : Ptr) : RawIO I32

#[extern "c"]
def EVP_MD_CTX_new : RawIO Ptr

#[extern "c"]
def EVP_MD_CTX_free (ctx : Ptr) : RawIO Unit

/// SHA-256 for ES256.
#[extern "c"]
def EVP_sha256 : Ptr

/// `pctx` and `engine` are NULL.
#[extern "c"]
def EVP_DigestSignInit
  (ctx : Ptr) (pctx : Ptr) (md : Ptr) (engine : Ptr) (pkey : Ptr) : RawIO I32

/// One-shot sign into `sigret`. `siglen` is a `size_t*` IN/OUT slot: it
/// carries the buffer size in (the pre-loaded `Dpop.len_slot` bytebuf)
/// and the written DER length back out, read little-endian by
/// `Dpop.slot_len`.
#[extern "c"]
def EVP_DigestSign
  (ctx : Ptr) (sigret : Ptr) (siglen : Ptr) (tbs : Ptr) (tbslen : I64)
  : RawIO I32

/// The verify side of `ECDSA_do_sign`, used by the roundtrip test below.
/// Takes the digest (not the message).
#[extern "c"]
def ECDSA_do_verify
  (digest : Ptr) (digest_len : I32) (sig : Ptr) (key : Ptr) : RawIO I32

/// A signature container holding two borrowed-then-owned BIGNUMs.
#[extern "c"]
def ECDSA_SIG_new : RawIO Ptr

/// `sig` takes ownership of `r` and `s`; on success they must not be freed.
#[extern "c"]
def ECDSA_SIG_set0 (sig : Ptr) (r : Ptr) (s : Ptr) : RawIO I32

#[extern "c"]
def ECDSA_SIG_free (sig : Ptr) : RawIO Unit

// ── the key ──────────────────────────────────────────────────────────────

/// A per-login-attempt P-256 key, stored as two unpadded base64url
/// strings: the 32-byte private scalar and the 65-byte uncompressed public
/// point (`0x04 || x || y`). The login attempt keeps them in the
/// `oauth_states` row; after the session exists the DPoP key is never
/// needed again (ATproto access tokens stay server-side only for the
/// identity confirmation, and the app's own cookie session carries the
/// user afterwards).
pub struct DpopKey {
  priv_b64 : String,
  pub_b64 : String
}

def Dpop.one : I32 := 1i32

/// `NID_X9_62_prime256v1`, the P-256 curve (the crypto mote's value).
def Dpop.nid_p256 : I32 := 415i32

/// `POINT_CONVERSION_UNCOMPRESSED`.
def Dpop.point_uncompressed : I32 := 4i32

/// One P-256 coordinate, or the private scalar.
def Dpop.scalar_bytes : I64 := 32i64

/// The uncompressed point encoding: `0x04 || x || y`.
def Dpop.point_bytes : I64 := 65i64

/// The maximum DER length of an ECDSA-SHA-256 signature: P-256 r and s are
/// at most 33 bytes each as DER integers (32 plus a possible sign byte),
/// plus 2 x 2 header bytes and the 2-byte SEQUENCE header.
def Dpop.der_max_bytes : I64 := 72i64

/// The `size_t*` slot size.
def Dpop.slot_bytes : I64 := 8i64

// ── list helpers (std has no List.take/List.drop) ────────────────────────

#[partial]
def Dpop.take_bytes (n : I64) (xs : List U8) : List U8 :=
  if I64.lt n 1i64 then List.empty
  else match xs {
    List.empty => List.empty,
    List.cons x rest => List.cons x (Dpop.take_bytes (I64.sub n 1i64) rest),
  }

#[partial]
def Dpop.drop_bytes (n : I64) (xs : List U8) : List U8 :=
  if I64.lt n 1i64 then xs
  else match xs {
    List.empty => List.empty,
    List.cons _ rest => Dpop.drop_bytes (I64.sub n 1i64) rest,
  }

#[partial]
def Dpop.zero_bytes (n : I64) : List U8 :=
  if I64.lt n 1i64 then List.empty
  else List.cons 0u8 (Dpop.zero_bytes (I64.sub n 1i64))

/// Drop the DER sign byte and any leading zero octets.
#[partial]
def Dpop.strip_zeros (xs : List U8) : List U8 :=
  match xs {
    List.empty => List.empty,
    List.cons x rest =>
      if U8.beq x 0u8 then Dpop.strip_zeros rest else List.cons x rest,
  }

/// Left-pad to exactly 32 bytes (JOSE ES256's fixed-width r and s).
def Dpop.pad32 (xs : List U8) : Result String (List U8) :=
  let n := List.length xs in
  if I64.gt n Dpop.scalar_bytes then Result.err "dpop: integer exceeds 32 bytes"
  else Result.ok (List.append (Dpop.zero_bytes (I64.sub Dpop.scalar_bytes n)) xs)

// ── key generation ───────────────────────────────────────────────────────

/// Generate a fresh P-256 key pair, exported as the base64url scalar and
/// point. One OpenSSL call sequence, freed on every path.
pub def Dpop.generate : IO (Result String DpopKey) := do {
  let ec <- IO.mk (EC_KEY_new_by_curve_name Dpop.nid_p256);
  let generated <- IO.mk (EC_KEY_generate_key ec);
  if Bool.not (I32.beq generated Dpop.one)
  then do {
    let _ <- IO.mk (EC_KEY_free ec);
    return (Result.err "dpop: P-256 key generation failed")
  }
  else do {
    let group := EC_KEY_get0_group ec;
    let point := EC_KEY_get0_public_key ec;
    let point_buf <- ByteBuf.alloc Dpop.point_bytes;
    let written <- IO.mk
      (EC_POINT_point2oct group point Dpop.point_uncompressed
        (ByteBuf.ptr point_buf) (ByteBuf.length point_buf) Ptr.null);
    if I64.beq written 0i64
    then do {
      let _ <- ByteBuf.free point_buf;
      let _ <- IO.mk (EC_KEY_free ec);
      return (Result.err "dpop: could not export the public point")
    }
    else do {
      let point_bytes <- ByteBuf.to_list point_buf Dpop.point_bytes;
      let _ <- ByteBuf.free point_buf;
      let priv_bn := EC_KEY_get0_private_key ec;
      let priv_buf <- ByteBuf.alloc Dpop.scalar_bytes;
      let priv_len <- IO.mk
        (BN_bn2binpad priv_bn (ByteBuf.ptr priv_buf)
          (I64.to_i32 Dpop.scalar_bytes));
      if Bool.not (I32.beq priv_len (I64.to_i32 Dpop.scalar_bytes))
      then do {
        let _ <- ByteBuf.free priv_buf;
        let _ <- IO.mk (EC_KEY_free ec);
        return (Result.err "dpop: could not export the private scalar")
      }
      else do {
        let priv_bytes <- ByteBuf.to_list priv_buf Dpop.scalar_bytes;
        let _ <- ByteBuf.free priv_buf;
        let _ <- IO.mk (EC_KEY_free ec);
        let key : DpopKey := {
          priv_b64 := B64Url.encode priv_bytes,
          pub_b64 := B64Url.encode point_bytes
        };
        return (Result.ok key)
      }
    }
  }
}

// ── the public JWK and its thumbprint ───────────────────────────────────

/// Split the stored point into the 32-byte x and y coordinates.
def Dpop.coords (key : DpopKey) : Result String (Pair (List U8) (List U8)) :=
  match B64Url.decode key.pub_b64 {
    Result.err e =>
      Result.err ("dpop: bad public point encoding: " ++ B64Error.to_string e),
    Result.ok bs =>
      let n := List.length bs in
      if Bool.not (I64.beq n Dpop.point_bytes)
      then Result.err "dpop: public point is not 65 bytes"
      else match bs {
        List.empty => Result.err "dpop: empty public point",
        List.cons tag rest =>
          if Bool.not (U8.beq tag 4u8)
          then Result.err "dpop: public point is not uncompressed"
          else Result.ok (Pair.pair
            (Dpop.take_bytes Dpop.scalar_bytes rest)
            (Dpop.drop_bytes Dpop.scalar_bytes rest)),
      },
  }

/// The public JWK (RFC 7517), the `dpop+jwt` header's `jwk` member.
pub def Dpop.jwk (key : DpopKey) : Result String String :=
  match Dpop.coords key {
    Result.err e => Result.err e,
    Result.ok xy =>
      match xy {
        Pair.pair x y =>
          Result.ok (String.concat_list [
            "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"", B64Url.encode x,
            "\",\"y\":\"", B64Url.encode y, "\"}"
          ]),
      },
  }

/// The RFC 7638 thumbprint: base64url(SHA-256(canonical JWK)). The
/// canonical form keeps only the required members in lexicographic order
/// (`crv`, `kty`, `x`, `y`). This is the PAR `dpop_jkt` value.
pub def Dpop.jkt (key : DpopKey) : Result String String :=
  match Dpop.coords key {
    Result.err e => Result.err e,
    Result.ok xy =>
      match xy {
        Pair.pair x y =>
          let canonical : String := String.concat_list [
            "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"", B64Url.encode x,
            "\",\"y\":\"", B64Url.encode y, "\"}"
          ] in
          Result.ok (B64Url.encode (Sha256.hash_bytes (String.to_list canonical))),
      },
  }

// ── ES256 signing ────────────────────────────────────────────────────────

/// DER `ECDSA-Signature` to the JWS raw `r || s`. The DER form is
/// `SEQUENCE { INTEGER r, INTEGER s }` with at most one sign byte per
/// integer (the whole signature fits the short-form length), and the raw
/// form is exactly two zero-padded 32-byte halves.
def Dpop.der_int (der : List U8) (at : I64) : Result String (Pair (List U8) I64) :=
  match List.get at der {
    Option.none => Result.err "dpop: truncated DER",
    Option.some tag =>
      if Bool.not (U8.beq tag 2u8)
      then Result.err "dpop: expected a DER INTEGER"
      else match List.get (I64.add at 1i64) der {
        Option.none => Result.err "dpop: truncated DER length",
        Option.some len_b =>
          let len := U8.to_i64 len_b in
          if I64.gt len (I64.add Dpop.scalar_bytes 1i64)
          then Result.err "dpop: DER integer too long"
          else
            let body := Dpop.take_bytes len (Dpop.drop_bytes (I64.add at 2i64) der) in
            Result.ok (Pair.pair body (I64.add (I64.add at 2i64) len)),
      },
  }

def Dpop.der_to_raw (der : List U8) : Result String (List U8) :=
  let total := List.length der in
  if I64.lt total 8i64
  then Result.err "dpop: DER signature too short"
  else match List.get 0i64 der {
    Option.none => Result.err "dpop: empty DER",
    Option.some seq =>
      if Bool.not (U8.beq seq 48u8)
      then Result.err "dpop: expected a DER SEQUENCE"
      else match List.get 1i64 der {
        Option.none => Result.err "dpop: truncated DER length",
        Option.some body_len_b =>
          let body_len := U8.to_i64 body_len_b in
          // A P-256 signature always fits the short length form, and the
          // declared body length must match the buffer exactly.
          if Bool.not (I64.beq body_len (I64.sub total 2i64))
          then Result.err "dpop: DER length mismatch"
          else match Dpop.der_int der 2i64 {
            Result.err e => Result.err e,
            Result.ok r_after =>
              match r_after {
                Pair.pair r_bytes after_r =>
                  match Dpop.der_int der after_r {
                    Result.err e => Result.err e,
                    Result.ok s_after =>
                      match s_after {
                        Pair.pair s_bytes after_s =>
                          if Bool.not (I64.beq after_s total)
                          then Result.err "dpop: trailing bytes after the DER signature"
                          else match Dpop.pad32 (Dpop.strip_zeros r_bytes) {
                            Result.err e => Result.err e,
                            Result.ok r => match Dpop.pad32 (Dpop.strip_zeros s_bytes) {
                              Result.err e => Result.err e,
                              Result.ok s => Result.ok (List.append r s),
                            },
                          },
                      },
                  },
              },
          },
      },
  }

/// One-shot `EVP_DigestSign` reads `*siglen` as the buffer size on INPUT
/// and writes the signature length back on output, so the slot must be
/// pre-loaded with the buffer size: a zero-filled slot is a zero-size
/// buffer and every sign fails. A P-256 DER signature always fits one
/// little-endian byte, so the remaining seven are zero.
def Dpop.len_slot (n : I64) : List U8 :=
  List.cons (U32.to_u8 (I64.to_u32 n)) (Dpop.zero_bytes 7i64)

/// Big-endian accumulator fold; the caller feeds it the REVERSED bytes
/// (see `Dpop.slot_len`).
#[partial]
def Dpop.slot_len_go (bs : List U8) (acc : I64) : I64 :=
  match bs {
    List.empty => acc,
    List.cons b rest => Dpop.slot_len_go rest
      (I64.add (I64.mul acc 256i64) (U8.to_i64 b)),
  }

def Dpop.slot_len (slot : ByteBuf) : IO I64 := do {
  let bs <- ByteBuf.to_list slot Dpop.slot_bytes;
  // `size_t` is little-endian on this ABI: the FIRST byte is the least
  // significant, so the big-endian accumulator folds the reversed bytes.
  return (Dpop.slot_len_go (List.reverse bs) 0i64)
}

/// Rebuild the EC_KEY from the stored halves, ready for EVP_DigestSign.
/// Returns the EVP_PKEY (the EC_KEY is consumed by the `set1` call).
def Dpop.evp_pkey_of (key : DpopKey) : IO (Result String Ptr) := do {
  let priv_bytes :=
    match B64Url.decode key.priv_b64 {
      Result.err _ => List.empty,
      Result.ok bs => bs,
    };
  let pub_bytes :=
    match B64Url.decode key.pub_b64 {
      Result.err _ => List.empty,
      Result.ok bs => bs,
    };
  if Bool.not (I64.beq (List.length priv_bytes) Dpop.scalar_bytes)
    || Bool.not (I64.beq (List.length pub_bytes) Dpop.point_bytes)
  then return (Result.err "dpop: stored key is not a P-256 pair")
  else do {
    let priv_buf <- ByteBuf.of_list priv_bytes;
    let pub_buf <- ByteBuf.of_list pub_bytes;
    let ec <- IO.mk (EC_KEY_new_by_curve_name Dpop.nid_p256);
    let priv_bn <- IO.mk
      (BN_bin2bn (ByteBuf.ptr priv_buf)
        (I64.to_i32 (ByteBuf.length priv_buf)) Ptr.null);
    let _ <- ByteBuf.free priv_buf;
    let priv_set <- IO.mk (EC_KEY_set_private_key ec priv_bn);
    let _ <- IO.mk (BN_free priv_bn);
    let group := EC_KEY_get0_group ec;
    let point <- IO.mk (EC_POINT_new group);
    let decoded <- IO.mk
      (EC_POINT_oct2point group point (ByteBuf.ptr pub_buf)
        (ByteBuf.length pub_buf) Ptr.null);
    let _ <- ByteBuf.free pub_buf;
    if Bool.not (I32.beq priv_set Dpop.one)
      || Bool.not (I32.beq decoded Dpop.one)
    then do {
      let _ <- IO.mk (EC_POINT_free point);
      let _ <- IO.mk (EC_KEY_free ec);
      return (Result.err "dpop: could not rebuild the P-256 key")
    }
    else do {
      let pub_set <- IO.mk (EC_KEY_set_public_key ec point);
      let _ <- IO.mk (EC_POINT_free point);
      let pkey <- IO.mk EVP_PKEY_new;
      let assigned <- IO.mk (EVP_PKEY_set1_EC_KEY pkey ec);
      let _ <- IO.mk (EC_KEY_free ec);
      if Bool.not (I32.beq pub_set Dpop.one) || Bool.not (I32.beq assigned Dpop.one)
      then do {
        let _ <- IO.mk (EVP_PKEY_free pkey);
        return (Result.err "dpop: could not attach the P-256 key")
      }
      else return (Result.ok pkey)
    }
  }
}

/// Sign with ES256: SHA-256 over the JWS signing input, P-256 ECDSA, the
/// raw `r || s` the JWS signature encoding needs. The empty-list decode
/// fallbacks above make a malformed stored key fail the length check
/// before any OpenSSL handle exists.
pub def Dpop.sign (key : DpopKey) (data : List U8) : IO (Result String (List U8)) := do {
  let pkey_r <- Dpop.evp_pkey_of key;
  match pkey_r {
    Result.err e => return (Result.err e),
    Result.ok pkey => do {
      let ctx <- IO.mk EVP_MD_CTX_new;
      let inited <- IO.mk (EVP_DigestSignInit ctx Ptr.null EVP_sha256 Ptr.null pkey);
      if Bool.not (I32.beq inited Dpop.one)
      then do {
        let _ <- IO.mk (EVP_MD_CTX_free ctx);
        let _ <- IO.mk (EVP_PKEY_free pkey);
        return (Result.err "dpop: EVP_DigestSignInit failed")
      }
      else do {
        let data_buf <- ByteBuf.of_list data;
        let sig_buf <- ByteBuf.alloc Dpop.der_max_bytes;
        let slot <- ByteBuf.of_list (Dpop.len_slot Dpop.der_max_bytes);
        let signed <- IO.mk
          (EVP_DigestSign ctx (ByteBuf.ptr sig_buf) (ByteBuf.ptr slot)
            (ByteBuf.ptr data_buf) (ByteBuf.length data_buf));
        let _ <- ByteBuf.free data_buf;
        if Bool.not (I32.beq signed Dpop.one)
        then do {
          let _ <- ByteBuf.free sig_buf;
          let _ <- ByteBuf.free slot;
          let _ <- IO.mk (EVP_MD_CTX_free ctx);
          let _ <- IO.mk (EVP_PKEY_free pkey);
          return (Result.err "dpop: ES256 signing failed")
        }
        else do {
          let len <- Dpop.slot_len slot;
          let _ <- ByteBuf.free slot;
          if I64.gt len Dpop.der_max_bytes
          then do {
            let _ <- ByteBuf.free sig_buf;
            let _ <- IO.mk (EVP_MD_CTX_free ctx);
            let _ <- IO.mk (EVP_PKEY_free pkey);
            return (Result.err "dpop: DER signature longer than expected")
          }
          else do {
            let der <- ByteBuf.to_list sig_buf len;
            let _ <- ByteBuf.free sig_buf;
            let _ <- IO.mk (EVP_MD_CTX_free ctx);
            let _ <- IO.mk (EVP_PKEY_free pkey);
            return (Dpop.der_to_raw der)
          }
        }
      }
    }
  }
}

/// Verify an ES256 raw `r || s` signature over `data` with the key's
/// public half: the roundtrip test checks the app's EVP sign path and the
/// DER-to-raw conversion against OpenSSL's own ECDSA verify. The crypto
/// mote's verifier is off-limits here (its FFI declares fifteen of the
/// same C symbols; see the extern comment above), so the public EC_KEY is
/// rebuilt the same way `Dpop.evp_pkey_of` rebuilds the pair, and the raw
/// signature is reassembled into an `ECDSA_SIG` for `ECDSA_do_verify`.
def Dpop.verify (key : DpopKey) (data : List U8) (sig : List U8)
  : IO (Result String Bool) := do {
  let pub_bytes :=
    match B64Url.decode key.pub_b64 {
      Result.err _ => List.empty,
      Result.ok bs => bs,
    };
  if Bool.not (I64.beq (List.length pub_bytes) Dpop.point_bytes)
    || Bool.not (I64.beq (List.length sig) (I64.mul Dpop.scalar_bytes 2i64))
  then return (Result.err "dpop: verify input is not a P-256 signature")
  else do {
    let digest_buf <- ByteBuf.of_list (Sha256.hash_bytes data);
    let r_buf <- ByteBuf.of_list (Dpop.take_bytes Dpop.scalar_bytes sig);
    let s_buf <- ByteBuf.of_list (Dpop.drop_bytes Dpop.scalar_bytes sig);
    let r_bn <- IO.mk
      (BN_bin2bn (ByteBuf.ptr r_buf) (I64.to_i32 Dpop.scalar_bytes) Ptr.null);
    let s_bn <- IO.mk
      (BN_bin2bn (ByteBuf.ptr s_buf) (I64.to_i32 Dpop.scalar_bytes) Ptr.null);
    let _ <- ByteBuf.free r_buf;
    let _ <- ByteBuf.free s_buf;
    let ec_sig <- IO.mk ECDSA_SIG_new;
    let set0 <- IO.mk (ECDSA_SIG_set0 ec_sig r_bn s_bn);
    if Bool.not (I32.beq set0 Dpop.one)
    then do {
      // set0 refused ownership, so the BIGNUMs are still ours.
      let _ <- IO.mk (BN_free r_bn);
      let _ <- IO.mk (BN_free s_bn);
      let _ <- IO.mk (ECDSA_SIG_free ec_sig);
      let _ <- ByteBuf.free digest_buf;
      return (Result.err "dpop: could not assemble the ECDSA signature")
    }
    else do {
      let ec <- IO.mk (EC_KEY_new_by_curve_name Dpop.nid_p256);
      let pub_buf <- ByteBuf.of_list pub_bytes;
      let group := EC_KEY_get0_group ec;
      let point <- IO.mk (EC_POINT_new group);
      let decoded <- IO.mk
        (EC_POINT_oct2point group point (ByteBuf.ptr pub_buf)
          (ByteBuf.length pub_buf) Ptr.null);
      let _ <- ByteBuf.free pub_buf;
      let pub_set <- IO.mk (EC_KEY_set_public_key ec point);
      let _ <- IO.mk (EC_POINT_free point);
      if Bool.not (I32.beq decoded Dpop.one) || Bool.not (I32.beq pub_set Dpop.one)
      then do {
        let _ <- IO.mk (ECDSA_SIG_free ec_sig);
        let _ <- IO.mk (EC_KEY_free ec);
        let _ <- ByteBuf.free digest_buf;
        return (Result.err "dpop: could not rebuild the P-256 public key")
      }
      else do {
        let v <- IO.mk
          (ECDSA_do_verify (ByteBuf.ptr digest_buf)
            (I64.to_i32 (ByteBuf.length digest_buf)) ec_sig ec);
        let _ <- ByteBuf.free digest_buf;
        let _ <- IO.mk (ECDSA_SIG_free ec_sig);
        let _ <- IO.mk (EC_KEY_free ec);
        return (Result.ok (I32.beq v Dpop.one))
      }
    }
  }
}

// ── the proof ────────────────────────────────────────────────────────────

/// One `dpop+jwt` proof (RFC 9449 §4.2, with the atproto `iss` payload
/// member): `base64url(header) . base64url(payload) . base64url(sig)`.
///
/// `htm`/`htu` identify the request (`htu` is scheme, host, port and path
/// only); `iat` is wall-clock seconds; `jti` is a fresh CSPRNG value;
/// `nonce` carries the server's `DPoP-Nonce`; `ath` is
/// `base64url(SHA-256(access_token))` when the request carries one. Every
/// string claim goes through `esc` (the shared JSON escaper), so a
/// hostile issuer or nonce cannot break out of the payload.
pub def Dpop.proof
    (key : DpopKey) (esc : String -> String)
    (iss : String) (htm : String) (htu : String) (iat : I64) (jti : String)
    (nonce : Option String) (ath : Option String)
    : IO (Result String String) := do {
  match Dpop.jwk key {
    Result.err e => return (Result.err e),
    Result.ok j => do {
      let header : String := String.concat_list [
        "{\"typ\":\"dpop+jwt\",\"alg\":\"ES256\",\"jwk\":", j, "}"
      ];
      let nonce_json : String :=
        match nonce {
          Option.none => "null",
          Option.some n => esc n,
        };
      let ath_json : String :=
        match ath {
          Option.none => "null",
          Option.some a => esc a,
        };
      let payload : String := String.concat_list [
        "{\"iss\":", esc iss,
        ",\"iat\":", I64.to_string iat,
        ",\"jti\":", esc jti,
        ",\"htm\":", esc htm,
        ",\"htu\":", esc htu,
        ",\"nonce\":", nonce_json,
        ",\"ath\":", ath_json,
        "}"
      ];
      let signing_input : String :=
        String.concat_list [B64Url.encode (String.to_list header), ".",
          B64Url.encode (String.to_list payload)];
      let sig_r <- Dpop.sign key (String.to_list signing_input);
      match sig_r {
        Result.err e => return (Result.err e),
        Result.ok sig =>
          return (Result.ok
            (String.concat_list [signing_input, ".", B64Url.encode sig])),
      }
    }
  }
}

// ── Tests ────────────────────────────────────────────────────────────────
//
// The pure tests run everywhere; the FFI tests (generate/sign) only run on
// the compiled native driver, like `db.mo`'s SQLite tests. The roundtrip
// verifies through OpenSSL's own ECDSA verify on a key rebuilt from the
// stored halves; the independent-implementation check -- a Node.js
// authorization server verifying real DPoP proofs from the built
// backend -- lives in `web/auth-smoke.mjs`.

#[test]
def test_der_to_raw_accepts_a_minimal_pair : Bool :=
  // 30 06 02 01 01 02 01 02  =>  r=1, s=2
  match Dpop.der_to_raw [48u8, 6u8, 2u8, 1u8, 1u8, 2u8, 1u8, 2u8] {
    Result.ok raw =>
      I64.beq (List.length raw) 64i64
        && U8.beq (Option.get_or_default 0u8 (List.get 31i64 raw)) 1u8
        && U8.beq (Option.get_or_default 0u8 (List.get 63i64 raw)) 2u8,
    Result.err _ => false,
  }

#[test]
def test_der_to_raw_strips_the_sign_byte : Bool :=
  // r = 0x00 0x80 (one sign byte), s = 0xff
  match Dpop.der_to_raw
    [48u8, 7u8, 2u8, 2u8, 0u8, 128u8, 2u8, 1u8, 255u8] {
    Result.ok raw =>
      U8.beq (Option.get_or_default 0u8 (List.get 31i64 raw)) 128u8
        && U8.beq (Option.get_or_default 0u8 (List.get 32i64 raw)) 0u8
        && U8.beq (Option.get_or_default 0u8 (List.get 63i64 raw)) 255u8,
    Result.err _ => false,
  }

#[test]
def test_der_to_raw_rejects_a_bad_sequence : Bool :=
  match Dpop.der_to_raw [49u8, 6u8, 2u8, 1u8, 1u8, 2u8, 1u8, 2u8] {
    Result.ok _ => false,
    Result.err _ => true,
  }

#[test]
def test_der_to_raw_rejects_trailing_bytes : Bool :=
  match Dpop.der_to_raw [48u8, 6u8, 2u8, 1u8, 1u8, 2u8, 1u8, 2u8, 0u8] {
    Result.ok _ => false,
    Result.err _ => true,
  }

#[test]
def test_jkt_shape_matches_the_canonical_jwk : Bool :=
  // The thumbprint input is the exact RFC 7638 member order and shape.
  let key : DpopKey := {
    priv_b64 := "",
    pub_b64 := B64Url.encode
      (List.cons 4u8 (Dpop.zero_bytes 64i64))
  } in
  match Dpop.jkt key {
    Result.ok t =>
      // sha256 of {"crv":"P-256","kty":"EC","x":"AAAA...","y":"AAAA..."} with
      // 43-char unpadded base64url output.
      I64.beq (String.length t) 43i64
        && Bool.not (String.contains t "="),
    Result.err _ => false,
  }

#[test]
def test_coords_rejects_a_short_point : Bool :=
  let key : DpopKey := { priv_b64 := "", pub_b64 := B64Url.encode (Dpop.zero_bytes 10i64) } in
  match Dpop.coords key {
    Result.ok _ => false,
    Result.err _ => true,
  }

#[test]
def test_generate_signs_and_verifies : IO Bool := do {
  let key_r <- Dpop.generate;
  match key_r {
    Result.err e => do {
      let _ <- IO.write_stderr ("dpop roundtrip: keygen: " ++ e ++ "\n");
      return false
    },
    Result.ok key => do {
      let sig_r <- Dpop.sign key (String.to_list "dpop test message");
      match sig_r {
        Result.err e => do {
          let _ <- IO.write_stderr ("dpop roundtrip: sign: " ++ e ++ "\n");
          return false
        },
        Result.ok sig => do {
          let v_r <- Dpop.verify key (String.to_list "dpop test message") sig;
          match v_r {
            Result.err e => do {
              let _ <- IO.write_stderr ("dpop roundtrip: verify: " ++ e ++ "\n");
              return false
            },
            Result.ok ok => return ok,
          }
        },
      }
    },
  }
}

#[test]
def test_generate_key_shape : IO Bool := do {
  let key_r <- Dpop.generate;
  match key_r {
    Result.err _ => return false,
    Result.ok key =>
      match B64Url.decode key.priv_b64 {
        Result.err _ => return false,
        Result.ok priv_bytes =>
          match B64Url.decode key.pub_b64 {
            Result.err _ => return false,
            Result.ok pub_bytes =>
              return (I64.beq (List.length priv_bytes) Dpop.scalar_bytes
                && I64.beq (List.length pub_bytes) Dpop.point_bytes
                && Bool.not (List.all (fn (b : U8) => U8.beq b 0u8) priv_bytes)),
          },
      },
  }
}
