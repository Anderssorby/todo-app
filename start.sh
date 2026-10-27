#!/usr/bin/env bash
# Rebuild the browser SPA and run the backend. Run inside `devenv shell`
# (needs llc/clang/wasi-sdk/Boehm GC on PATH, same as every other build in
# this repo -- see README.md).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> building todo-spa (wasm32-unknown-unknown)"
# A relative -o lands under target/debug/ when building a mote, so the
# asset path must be absolute (see PLAN.md).
monad build --target wasm32-unknown-unknown todo-spa -o "$PWD/web/app.wasm"

echo "==> generating the hash-pinned loader (todo-webgen)"
monad build todo-webgen
./target/debug/todo-webgen

echo "==> building todo-backend"
monad build todo-backend

echo "==> starting todo-backend (http://localhost:8095/)"
exec ./target/debug/todo-backend
