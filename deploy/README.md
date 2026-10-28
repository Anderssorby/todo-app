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
- liveness/startup: `GET /api/todos` (cheap, side-effect free).

The app has no dedicated health endpoint and binds `0.0.0.0:8095` (IPv4 only).

## State

The image contains `/app/todos.json -> /state/todos.json`; the backend always
opens `todos.json` relative to its working directory (`/app`), so writes go to
the volume. The entrypoint fails fast if `/state` is missing or not writable
(including an existing `todos.json` that is not writable).

- No file: the backend serves its built-in two-item seed in memory.
- First mutation creates `/state/todos.json`.
- A file that exists but cannot be read or parsed is a **500**, not a reset:
  the backend refuses to overwrite it, so a torn read or a hand-broken file
  cannot silently replace the list with the seed. Restore a backup, or
  delete the file to start over from the seed.
- Deleting the pod preserves state; deleting the PVC resets it.
- The Deployment does not own or delete the PVC.

Back up the PVC before upgrades if the data matters.

## Why one replica

`todo-backend` writes the whole JSON file with
`open(O_WRONLY|O_CREAT|O_TRUNC)` -- no locking, no fsync, no temp-file rename
(`todo-backend/src/persist.mo`), and `Server.serve_concurrent` runs up to 16
handlers. Concurrent writes can lose updates, and a reader can observe a
truncated file and fall back to the seed. Therefore:

- `replicas: 1`;
- `strategy: Recreate` (never two pods during a rollout);
- a `ReadWriteOnce` PVC (no RWX/multi-pod);
- no HPA, no rolling updates, no shared state between pods.

A production-grade multi-replica deployment needs a database and real
transaction/locking semantics; that is a backend change, not a manifest
change.

Note that `replicas: 1` only rules out *cross-pod* writers. Inside the one
pod `Server.serve_concurrent` still runs up to 16 handlers, and each mutation
is a non-transactional `load -> apply -> save` of the whole file, so two
mutations racing in one process can lose one update (last save wins; a read
that lands mid-write now returns 500 instead of the seed). This is adequate
for the single-user demo; serializing or moving state to a database is the
fix if it matters.

## Known SPA limits

- The wasm shell has one request slot (`Model.pending`). Starting a second
  mutation before the first response arrives leaves the first response
  unread; the server still receives both, and the file store's last-write
  wins. Clicking a few controls quickly is fine in practice, but a queue is
  the real fix.
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
