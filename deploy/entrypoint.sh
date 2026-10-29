#!/bin/sh
# State is a SQLite database under the mounted /state volume. SQLite creates
# the database and its -wal/-shm side files beside it, so the directory (not
# just one file) must be writable. Fail fast rather than surfacing a 500 on
# the first write.
set -eu

cd /app

[ -d /state ] || { echo "todo-app: /state is not mounted" >&2; exit 1; }
[ -w /state ] || {
    echo "todo-app: /state is not writable (check the volume and fsGroup)" >&2
    exit 1
}
for f in todos.db todos.db-wal todos.db-shm; do
    if [ -e "/state/$f" ] && [ ! -w "/state/$f" ]; then
        echo "todo-app: /state/$f is not writable (check ownership/fsGroup)" >&2
        exit 1
    fi
done

exec /app/bin/todo-backend --db "${TODO_DB:-/state/todos.db}" "$@"
