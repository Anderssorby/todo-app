# Deploying the todo app

The flake builds a non-root `linux/amd64` OCI image containing the native
`todo-backend`, the generated wasm SPA under `/app/web`, a POSIX entrypoint,
and only the glibc closure needed to run the binary. The Monad compiler, LLVM,
clang and wasi-sdk are build inputs and are not in the image.

## Build and load

```bash
nix build --accept-flake-config .#image   # uses the Monad Cachix for the compiler
docker load < result       # result is a gzipped docker-archive tarball
docker image inspect todo-app:latest
```

The flake takes the compiler and source tree from the Monad flake input at
the same revision as the mote git dependencies; `--accept-flake-config` is
what lets Nix use that flake's `nixConfig` substituters (the Monad CI cache).
Without it the self-hosted compiler may be built from source. Later builds
are cached.

The image is `linux/amd64`; build it on x86_64-linux (or use an emulated
builder). On Apple Silicon `kind`, create the cluster with an amd64 node/VM.

## Registry or kind

```bash
# Registry (deploy/kubernetes.yaml references this image with
# imagePullPolicy: Always, so it must exist in the registry):
docker tag todo-app:latest ghcr.io/anderssorby/todo-app:latest
docker push ghcr.io/anderssorby/todo-app:latest

# kind / minikube: with Always the node pulls the tag, so push first. For a
# purely local test without a registry, change the manifest to
# imagePullPolicy: IfNotPresent and load the image as below.
kind create cluster
kind load docker-image ghcr.io/anderssorby/todo-app:latest

# minikube (docker driver):
minikube image load ghcr.io/anderssorby/todo-app:latest
```

Because the manifest uses the mutable `latest` tag with `Always`, every pod
start re-resolves it at the registry; `kind load`/`minikube image load` alone
does not satisfy `Always`. Push the image, or pin a version tag/digest for
immutable rollouts. If the GHCR package is private, add an `imagePullSecrets`
entry to the pod.

## Deploy

```bash
kubectl apply -f deploy/kubernetes.yaml
kubectl -n todo rollout status deploy/todo-app
kubectl -n todo get pods,pvc,svc
kubectl -n todo port-forward svc/todo-app 8095:80
# open http://localhost:8095/
```

The Deployment mounts a 1Gi `ReadWriteOnce` PVC at `/state` and an
`emptyDir` at `/tmp`; the container runs read-only with UID/GID 10001.
Probes are:

- readiness: `GET /web/boot.js` (loader asset present),
- liveness/startup: `GET /login` (public; `/api/todos` is 401 in production
  while sign-in is deferred, so it cannot be a 2xx probe).

The app has no dedicated health endpoint and binds `0.0.0.0:8095` (IPv4 only).

## State

State is a SQLite database on the volume: the entrypoint runs
`/app/bin/todo-backend --db "${TODO_DB:-/state/todos.db}"`, so writes go to
`/state/todos.db` plus its `-wal` and `-shm` side files. The entrypoint fails
fast if `/state` is missing or not writable (including an existing database or
WAL file that is not writable).

- A fresh database runs migrations 1 and 2 and starts with an **empty**
  shared workspace (there is no seed and `todos.json` is never imported).
- The first sign-in/mutation creates the user/todo rows; SQLite creates the
  database file and WAL on the first write.
- Migrations are checksum-tracked. A database whose migration 1 checksum was
  edited is refused rather than silently rewritten.
- Deleting the pod preserves state; deleting the PVC resets it.
- The Deployment does not own or delete the PVC.
- SQLite with WAL uses three files. Back up with the pod stopped (or after a
  checkpoint) so the database and WAL are consistent.

Back up the PVC before upgrades if the data matters.

## Why one replica

SQLite is a local file: the database and its WAL cannot be shared safely by
two pods, even on a filesystem that pretends to support RWX. Therefore:

- `replicas: 1`;
- `strategy: Recreate` (never two pods during a rollout);
- a `ReadWriteOnce` PVC (no RWX/multi-pod);
- no HPA, no rolling updates, no shared state between pods.

Within the one pod, every connection is served on its own fiber by the accept
loop in `todo-backend/src/serve.mo` (moon's `Server.serve_concurrent` is not
used: it drains its whole batch before accepting again, so idle keep-alive
sockets park it). Every mutation is a single `BEGIN IMMEDIATE` transaction
that loads, applies the shared `Action`, and rewrites the rows
(`todo-backend/src/db.mo`), so concurrent writers serialize (bounded by the
driver's 5 s busy timeout) instead of losing an update. A multi-replica
deployment needs a client/server database and sessions external to the pod;
that is a backend change, not a manifest change.

## Known SPA limits

- The wasm shell has one request slot (`Model.pending`). Starting a second
  mutation before the first response arrives leaves the first response
  unread; both still reach the server and are applied transactionally, but
  the first response is dropped. Clicking a few controls quickly is fine in
  practice, but a queue is the real fix.
- The shell starts with `GET /api/me`: a 401 shows a sign-in view and clears
  the cached list, so a production deployment without OAuth enabled is a
  closed app (see below).
- Every re-render parses Markdown for every note, and the wasm bump allocator
  never frees. Hundreds of long notes can exhaust the browser heap; keep
  notes/lists modest until the renderer is cached or the runtime reclaims
  memory.
- Deep links are server-side only: `/kanban`, `/todos/new` and
  `/todos/:id/edit` render the no-JS page, then the SPA mounts on the Tasks
  tab (the wasm runtime has no location API). The no-JS fallback works.
- A failed fetch (network, HTTP 500, unparseable body) shows a banner with a
  **Retry** control; the frame pump stops after a failure, so this is the
  recovery path.

## Security / runtime

- Non-root UID/GID 10001, `runAsNonRoot`, dropped capabilities, seccomp
  `RuntimeDefault`, `readOnlyRootFilesystem: true`.
- `/app` and the web assets are read-only; only `/state` (PVC) and `/tmp`
  (emptyDir) are writable.
- Image contents: app, glibc, `/bin/sh` (bash) and coreutils. The entrypoint
  uses shell builtins; coreutils is there for debugging and for the
  documented initContainer fallback (`chown`/`chmod`). Verify with
  `docker run --rm --entrypoint /bin/sh todo-app:latest -c id`.
- **Sign-in is deferred in this build.** The pinned `oauth` mote implements
  the authorization-code + PKCE client flow but cannot validate an ID token
  (no JWT/JWKS/signature verification), so `/auth/login` and
  `/auth/callback` return 503 and `GET /api/me` is 401 for every request.
  `TODO_DEV_AUTH`/`--dev-auth` is a **local development stub**: it must never
  be set in this manifest or the image. The production login flow and its
  OAuth env/Secret come back when the mote can verify tokens.
- **There are no sessions or CSRF tokens yet.** Authentication is the dev
  stub only, so the workspace is effectively closed in production. Treat the
  deployed app as read-only-until-configured, and do not expose the dev stub.
- Time display is a per-user fixed UTC offset (no IANA/DST); notes are
  Markdown rendered with escaped raw HTML and safe URL schemes.

## Logs

The server logs to stdout, but only the startup line is explicitly flushed;
request logs are block-buffered when stdout is a pipe. `kubectl logs` may show
the startup line immediately and request lines in delayed batches. Use the
probes, not log output, as the health signal.

## Troubleshooting

- **PVC Pending**: the cluster has no default StorageClass; set
  `storageClassName` in `deploy/kubernetes.yaml`.
- **CrashLoopBackOff with “/state is not writable”**: the CSI driver did not
  honour `fsGroup`. Add an initContainer that runs as root with the state
  volume mounted at `/state` and runs
  `chown -R 10001:10001 /state && chmod 0770 /state`, or configure the
  StorageClass/fsGroup correctly.
- **Probes failing / no response**: the app listens on IPv4 `0.0.0.0:8095`
  only; an IPv6-only cluster cannot reach it.
- **State looks reset**: a missing `todos.json` serves the seed and the first
  mutation creates the file. A file that exists but does not parse is not
  reset -- the server answers 500 ("todos.json is not valid JSON") and leaves
  it alone. Restore the PVC backup, or delete the file to reset to the seed.

## Local container check

```bash
docker volume create todo-state
docker run --rm --name todo-app -p 8095:8095 -v todo-state:/state todo-app:latest
curl -fsS http://localhost:8095/api/todos
curl -fsSI http://localhost:8095/web/boot.js
# add a todo, stop/start the container with the same volume, re-check
docker run --rm --read-only --user 10001:10001 \
  -v todo-state:/state -p 8095:8095 todo-app:latest
```

`--read-only` is safe because all writes go through `/state` (and `/tmp` if
needed); mount both when testing that mode.
