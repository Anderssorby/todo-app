#!/usr/bin/env bash
# Rebuild the browser SPA and run the backend. Run inside `devenv shell`
# (needs llc/clang/wasi-sdk/Boehm GC on PATH, same as every other build in
# this repo -- see README.md).
#
# Monad motes are pinned to the public monad git repository; the per-mote
# mote.lock files are committed. The one-time network step is
# scripts/fetch-deps.sh; nothing here fetches.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for m in todo-core todo-backend todo-spa todo-webgen; do
  if [ ! -f "$m/mote.lock" ]; then
    echo "error: $m/mote.lock is missing; run: monad fetch $m" >&2
    exit 1
  fi
done

echo "==> building todo-spa (wasm32-unknown-unknown)"
# A relative -o lands under target/debug/ when building a mote, so the
# asset path must be absolute (see PLAN.md).
monad build --locked --target wasm32-unknown-unknown todo-spa -o "$PWD/web/app.wasm"

echo "==> generating the hash-pinned loader (todo-webgen)"
monad build --locked todo-webgen
./target/debug/todo-webgen

echo "==> building todo-backend"
monad build --locked todo-backend

echo "==> starting todo-backend (http://localhost:8095/)"
exec ./target/debug/todo-backend
