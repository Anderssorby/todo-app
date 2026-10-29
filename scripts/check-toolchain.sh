#!/usr/bin/env bash
# Fail early when the `monad` on PATH is not the revision the motes are pinned
# to. This is a guard, not a formality: the compiler's runtime implements the
# `#[native]` APIs the pinned `std` declares, so a mismatch compiles and then
# misbehaves at runtime. On 2026-10-29 a compiler from a newer nightly produced
# a NULL `ByteBuf` out-parameter, and `sqlite3_open_v2` wrote the handle to
# address 0 -- SIGSEGV before the backend's first log line -- while
# `monad check`, `monad test` and `monad build` all passed. See PLAN.md,
# `compiler-mote-revision-skew-is-not-diagnosed`.
#
# The Nix build is immune by construction: the flake pins the compiler package
# itself. This guards the `monadup` path used for local builds and CI.
set -euo pipefail
cd "$(dirname "$0")/.."

# Every member pins the same revision; assert that before comparing.
pins="$(grep -h '^rev = "' todo-core/mote.toml todo-backend/mote.toml todo-spa/mote.toml todo-webgen/mote.toml | sed 's/^rev = "\(.*\)"$/\1/' | sort -u)"
count="$(printf '%s\n' "$pins" | wc -l | tr -d ' ')"
if [ "$count" != 1 ]; then
  echo "manifests disagree on the Monad revision:" >&2
  printf '  %s\n' "$pins" >&2
  exit 1
fi
pin="$pins"

if ! command -v monad >/dev/null 2>&1; then
  echo "monad is not on PATH; install a nightly matching the pin ($pin)" >&2
  exit 1
fi

version="$(monad version | head -1 | awk '{print $1}')"
case "$pin" in
  "$version"*) exit 0 ;;
esac

echo "toolchain mismatch: 'monad' is $version, the motes are pinned to $pin" >&2
echo "the compiler's runtime must match the pinned std/runtime, or the build" >&2
echo "can link and then crash at runtime (the checker does not diagnose it)." >&2
if command -v monadup >/dev/null 2>&1; then
  # `monadup list` prints "[* ]<tag>  <short-rev>"; match the pin's short form.
  tag="$(monadup list 2>/dev/null | awk -v p="$pin" '
    { short = $NF; tag = $1; if (tag == "*") tag = $2
      if (short == substr(p, 1, 7)) { print tag; exit } }')"
  if [ -n "$tag" ]; then
    echo "switch to the pinned toolchain with: monadup use $tag" >&2
  fi
  echo "installed toolchains: monadup list" >&2
fi
exit 1
