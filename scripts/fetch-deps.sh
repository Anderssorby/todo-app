#!/usr/bin/env bash
# One-time (per manifest change) network step: resolve the pinned Monad git
# dependencies into $MONAD_HOME/cache/git and write each member's mote.lock.
#
# The workspace root is virtual (no [mote]), so there is no root lock; each
# member owns the lock for its direct dependencies. `monad fetch` keeps a
# commit every existing lock already names, and the offline pass proves the
# cache is complete before builds (which never use the network).
set -euo pipefail
cd "$(dirname "$0")/.."

for m in todo-core todo-backend todo-spa todo-webgen; do
  echo "==> monad fetch $m"
  monad fetch "$m"
  monad fetch --offline "$m"
done
