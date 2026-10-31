#!/usr/bin/env bash
# One-time (per manifest change) network step: resolve the pinned Monad git
# dependencies into $MONAD_HOME/cache/git and write the workspace's one
# root mote.lock.
#
# Every member inherits `[workspace.dependencies]` with `workspace = true`,
# so the root owns the lock for the whole workspace (the per-member locks are
# gone). `monad fetch` keeps a commit every existing lock already names, and
# the offline pass proves the cache is complete before the `--locked` builds
# (which never use the network).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> monad fetch (workspace root)"
monad fetch
echo "==> monad fetch --offline (workspace root)"
monad fetch --offline

# The one root lock is the workspace's resolution. The per-member verify path
# (`monad build`/`check`/`test` on a member) still reads `<member>/mote.lock`
# rather than the workspace root's, so each member carries a committed symlink
# to the root lock. Recreate any that are missing.
for m in todo-core todo-backend todo-spa todo-webgen; do
  if [ ! -e "$m/mote.lock" ]; then
    ln -s ../mote.lock "$m/mote.lock"
  fi
done
