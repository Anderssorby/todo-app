#!/bin/sh
# The image bakes /app/todos.json -> /state/todos.json. State lives on the
# mounted /state volume; the backend serves its built-in seed while the file
# is absent and creates it on the first mutation. Fail fast if the mount or
# its permissions are wrong, rather than surfacing a 500 on the first write.
set -eu

cd /app

[ -d /state ] || { echo "todo-app: /state is not mounted" >&2; exit 1; }
[ -w /state ] || {
    echo "todo-app: /state is not writable (check the volume and fsGroup)" >&2
    exit 1
}
if [ -e /state/todos.json ] && [ ! -w /state/todos.json ]; then
    echo "todo-app: /state/todos.json is not writable (check ownership/fsGroup)" >&2
    exit 1
fi

exec /app/bin/todo-backend "$@"
