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
- **State looks reset**: invalid or truncated JSON falls back to the seed
  (`Persist.load`), and the next mutation then persists seed-derived data.
  Restore the PVC backup.

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
