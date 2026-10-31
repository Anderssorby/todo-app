# A TODO app in Monad

An example web app to demonstrate and test the capabilities of the Monad
language. The app is deliberately small; the point is to exercise Monad's
compiler, stdlib, and motes as an external consumer and to file every gap
found (see [`PLAN.md`](PLAN.md) and the Monad plans repo).

## Layout

- `todo-core/` — pure, wasm-portable domain: `Todo`, actions, the JSON
  codec, timestamp/due formatting through the `time` mote (`stamp.mo`), and
  the typed oak view (shared by the SSR page and the SPA; the server lowers it
  to HTML with `Oak.to_html`, which drops event bindings). Notes are rendered
  with the `markdown` mote, with its safe defaults.
- `todo-backend/` — native `moon` HTTP server with SQLite state through the
  `sql`/`sqlite` motes (`--db`/`-d`, default `todos.db`; migrations, users,
  sessions and OAuth-state tables, transactional load → apply → rewrite), a
  `clap` CLI (`--port`/`-p`, `--db`/`-d`, `--help`), logging through the
  `log` mote, and byte-exact static assets through moon's `Static.handler`.
- `todo-spa/` — the browser shell: a real typed-event `oak_wasm` `Program`
  (mount, dispatch, tick; a genuine DOM diff/patch, not an `innerHTML` swap),
  web-only (`wasm32-unknown-unknown`). Typed handlers replace the old numeric
  handler ids; an animation-frame subscription drives the initial load and
  fetch polling; the add/edit/subtask controls are SPA-owned inputs with
  `type="button"` actions (no `<form>` elements); kanban cards are real drag
  sources with a drop payload.
- `todo-webgen/` — native build tool (uses the `jsgen` mote): reads the
  vendored loader and the built `web/app.wasm`, then writes the generated
  loader entry with every module/fetch URL pinned to that file's SHA-256
  (`web/boot.js`, `web/web.gen.js`, `web/web_runtime.gen.js`,
  `web/boot.version`).
- `web/` — the static shell: `index.html`, the vendored loader sources
  (`web.js`, `web_runtime.js`, `float_format.js`), the generated loader
  entry and hashes (`boot.js`, `web.gen.js`, `web_runtime.gen.js`,
  `boot.version`), `smoke.mjs`, `app.wasm`.
- `flake.nix`, `nix/` — the hermetic Nix build (pinned Monad toolchain and
  git dependencies) and the OCI image.
- `deploy/` — the container entrypoint, Kubernetes manifests, and deployment
  notes.
- `start.mo` — a `[[script]]` in the root `mote.toml`; it rebuilds the SPA,
  the hash-pinned loader and the backend, then runs the backend with
  forwarded argv (`monad script start`).
- `scripts/fetch-deps.sh` — the one-time network step that resolves the
  pinned Monad git dependencies and writes the workspace's root `mote.lock`.

## Dependencies

The Monad motes are pinned to the public
`https://github.com/monad-lang/monad.git` repository at
`632d1825dd65f8250c56a2228285c99fa3ff7b13` (Monad `main`, 2026-10-31) in the
root `mote.toml`; every member inherits those sources with
`workspace = true`. `monad fetch` writes one root `mote.lock` for the whole
workspace. The four member `mote.lock` files are committed symlinks to it,
because the per-member `--locked` verify path still reads `<member>/mote.lock`
instead of the workspace root's (see `PLAN.md`,
`workspace-member-lock-lookup`). After cloning or changing a manifest, run
the only network step:

```bash
scripts/fetch-deps.sh
```

Every build, check and test then runs `--locked` and never uses the network.

**The toolchain must be the same revision as the motes.** The compiler's
runtime implements the `#[native]` functions the pinned `std` declares, and
that ABI changes between revisions. A mismatch is not diagnosed by
`monad check`: the binary links and then misbehaves at runtime. On
2026-10-29 a compiler from nightly `a9d9a81` with motes pinned to
`12b74e92` made `ByteBuf.alloc` return a buffer whose payload pointer was
NULL, so `todo-backend` segfaulted inside `sqlite3_open_v2` and
`todo-webgen` read an empty `app.wasm` and pinned the empty-string hash
(`e3b0c44…`) in the loader. The flake pins the toolchain, so the image is
unaffected; a local `monad` from `monadup default` may not be.

The repo pins `632d1825` (Monad `main` on 2026-10-31), which is newer than the
latest published nightly. Until a nightly carries it, build the pinned
compiler from the same flake input the image uses (the Cachix cache may
already hold it; otherwise Nix bootstraps it once):

```bash
monad_bin="$(nix build --accept-flake-config --no-link --print-out-paths \
  'github:monad-lang/monad/632d1825dd65f8250c56a2228285c99fa3ff7b13#monad')"
# The package's bin/monad is wrapped with the flake's own clang/llvm/GC (the
# image uses exactly that). In a devshell from a different nixpkgs, that
# wrapper's glibc and the devshell's sqlite disagree at link time, so run the
# unwrapped binary and let the devshell supply one consistent toolchain:
export PATH="$monad_bin/share/monad:$PATH"
# Where the bare compiler finds init/std/llvm/runtime:
export MONAD_ROOT="$(nix flake prefetch --json \
  'github:monad-lang/monad/632d1825dd65f8250c56a2228285c99fa3ff7b13' \
  | jq -r .storePath)"
```

Once a nightly carries the pin, `monadup use <that tag>` replaces the block
above (and `monadup list` shows the installed tags). `scripts/check-toolchain.sh` compares `monad version`
with the pinned revision and fails with the matching `monadup use` command, or
with the Nix fallback when no installed nightly has it;
the nightly workflow runs the same selection before fetching or building. Filed as
`compiler-mote-revision-skew-is-not-diagnosed` in [`PLAN.md`](PLAN.md); the
checker should reject a compiler whose revision differs from the pinned
`std`/`runtime`, and the `db::test_db_migrates_and_round_trips` test plus
the CI server smoke fail loudly in the meantime.

## Build and run

Run `devenv shell` first (the dev shell provides `llc`/`clang`/Boehm GC,
wasi-sdk, `wasmtime`, and Node).

Build the SPA and generate its hash-pinned loader first (the WASM block
below), then the backend:

```bash
scripts/fetch-deps.sh
monad check --workspace --locked
monad build --locked todo-backend
./target/debug/todo-backend          # serves http://localhost:8095/
./target/debug/todo-backend --port 3000   # or -p 3000
./target/debug/todo-backend --help
monad test --workspace --locked
```

Or rebuild everything and run it in one command, from the repository root:

```bash
monad script start                  # builds SPA + loader + backend, then serves
monad script start -- --port 3000   # flag-like program args need `--`
monad s start                       # the short spelling
```

`start.mo` is a `[[script]]` declared in the root `mote.toml`, not a shell
script and no longer a self-describing `#![mote { … }]` module: it uses only
`init` and `std`, which the compiler resolves from its toolchain. It runs the
three builds with inherited stdio, then the backend, and returns its exit
status. The server runs under `setpriv --pdeathsig TERM` when util-linux is
available, so terminating the script also terminates the server and releases
the listening port; without `setpriv`, Ctrl-C (or killing the process group)
stops both.

WASM:

```bash
# todo-spa: the actual browser shell. Relative -o paths land under
# the target directory when building a mote, so give the asset an
# absolute path.
monad build --locked --target wasm32-unknown-unknown todo-spa -o "$PWD/web/app.wasm"

# Hash-pin the loader graph from the vendored sources + that wasm.
monad build --locked todo-webgen
./target/debug/todo-webgen

node web/boot_url.test.mjs
node web/runtime_args.test.mjs
node web/smoke.mjs "$PWD/web/app.wasm"
```

`--target` takes a separate argument (`--target=x` does not parse).

With the backend running, open `http://localhost:8095/` in a browser:
the oak-rendered page loads and `boot.js` mounts the typed-event
`oak_wasm` SPA over it. Clicks (toggle/delete/edit/tabs/filters) are typed
`Html.on "click"` handlers; the add/edit/subtask controls are controlled SPA
inputs (`Html.on_input`/`on_change`) whose `type="button"` actions post one
JSON `Action` to `POST /api/actions` (the SPA renders no `<form>`, so nothing
navigates; Enter submits through `Html.on "keydown"`); and kanban cards are
real drag sources whose `text/plain` payload is parsed by the column's
`Html.on "drop"`. Every mutation returns the authoritative todo list; the
animation-frame subscription advances the pending fetch, and is installed
only while a request is outstanding (`Spa.subs`); the loader likewise calls
`oak_tick` only after a dispatch. That matters: the wasm runtime's bump
allocator never frees, and `Runtime.tick` re-renders on every dispatched
frame message, so an always-on frame subscription grew memory continuously
(~12 MB/s idle) until strings above 2 GiB hit the loader's sign-extended
pointers and threw `RangeError: invalid or out-of-range index`. The loader
now reads pointer/length words as unsigned and logs (rather than throws) if
one is genuinely outside memory. Responses are drained in 64 KiB reads (the
loader's scratch-buffer cap), so a list larger than that is parsed in full; a
failed fetch renders a banner with a Retry control, and a group/tag filter
whose last todo is deleted is dropped instead of hiding the rest of the
list. The no-JS fallback still works: the server-rendered (urlencoded) forms
post to the ordinary `/todos/...` routes.

The server half of that mount path is guarded by a script that needs a
running backend:

```bash
node web/keepalive.test.mjs http://127.0.0.1:8095
```

It holds a batch of idle keep-alive sockets and then requires a new
connection to fetch `/web/app.wasm`. It exists because moon's
`Server.serve_concurrent` awaited its whole batch of connection fibers before
accepting again, and a fiber lives for the keep-alive socket: a few page
loads' worth of idle browser sockets parked the accept loop, and the SPA's
mount fetch died as `todo-spa: failed to mount TypeError: NetworkError when
attempting to fetch resource` (intermittently, only after the server had been
used for a while). `todo-backend/src/serve.mo` replaces that loop; see
PLAN.md, `moon-serve-concurrent-parks-accept-loop`.

The SPA half is exercised automatically over a stub DOM:

```bash
node web/smoke.mjs "$PWD/web/app.wasm"
```

It covers mount, initial load, toggle, tabs/settings/theme, subtasks,
hide/clear completed, SPA add/edit/subtask-add, kanban move and
drag-and-drop, filters, and delete.

The boot URL is unit-tested separately, because the DOM harness instantiates
the wasm directly and cannot catch a bad boot path (a document-relative
`./app.wasm` 404s on `/` and `/kanban`; the browser reports that 404 HTML page
as a wrong MIME type):

```bash
node web/boot_url.test.mjs
node web/runtime_args.test.mjs
```

`runtime_args.test.mjs` pins the other half of that boundary: wasm32
pointer/length words are read as unsigned, so an address above 2 GiB (which
`web_str_ptr` sign-extends) is not mistaken for a negative array index.

`/web/*` is served with `Cache-Control: no-store`, since the loader modules
and `app.wasm` are rebuilt together. If a browser cached a failed loader
module from an earlier server restart, hard-reload once; the generated
`boot.js` logs `todo-spa: failed to mount ...` with the failing URL/status.

The loader graph is generated and hash-pinned by `todo-webgen` using the
`jsgen` mote: `web/web_runtime.gen.js` imports `float_format.js` at its
SHA-256, `web/web.gen.js` imports that copy at its SHA-256, and `boot.js`
imports both plus `app.wasm` at their hashes. `web/boot.version` is the
SHA-256 of `boot.js`; the backend reads it (`Persist.loader_version`) and
emits `/web/boot.js?v=<hash>` in the SSR shell, while `web/index.html`
fetches the same file. `node web/boot_url.test.mjs` recomputes every hash.
Run `todo-webgen` after building the SPA wasm and before starting the
backend; `monad script start` does both. This forces fresh URLs, so a
browser's cached failed module cannot poison the page.

## Users, time and notes

**Sign-in is deferred on ATproto's DPoP requirement.** The pinned Monad now
ships `jsonwebtoken` and an `oauth` client that validates tokens (and, on
main but not yet in this nightly, a resource-server bearer guard), so the old
"cannot validate an ID token" blocker is closed. This app targets AT Protocol
OAuth as a public client with the identity-only `atproto` scope. ATproto
requires DPoP (RFC 9449): each session must generate a P-256 key and sign an
ES256 proof for every authorization-server and PDS request. Monad's `crypto`
mote currently only verifies ES256; it cannot generate a key or sign. So
`/auth/login` and `/auth/callback` return 503 with that explanation. The
capability is planned in
`monad-plans/library-ideas/crypto-primitives.md`. The only sign-in is the
gated local stub: start the server with `TODO_DEV_AUTH=1` (or `--dev-auth`)
to resolve a local `dev` user. It is off by default and never enabled in the
image or Kubernetes manifest. `GET /api/me` returns 401 in production and
the SPA then shows its login view (it uses a real link, because the wasm
runtime has no location API).

**Time is stored in UTC and displayed at a fixed offset.** Timestamps are
ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`); migration 2 added
`users.utc_offset_minutes` and rewrote existing SQLite `datetime('now')`
values to that shape. The user picks an offset from UTC-12:00 to UTC+14:00
in the SPA's Settings tab, which posts `POST /api/me
{"utc_offset_minutes":120}`. The `time` mote parses/formats the values
(`todo-core/src/stamp.mo`); it has no IANA database or DST rules, so a fixed
offset is the honest limit. `Instant.now` is deliberately unused: on compiled
native binaries it is `CLOCK_MONOTONIC`, not a wall clock, and SQLite's
`strftime` supplies "now".

**Notes are Markdown.** The `markdown` mote renders them in both the SSR item
and the SPA with `default_options` + `default_html_options`: raw HTML is
escaped and `javascript:`/`vbscript:`/`file:` URLs are dropped. `data:image/`
(including SVG) passes the mote's URL filter and is rendered as an `<img>`,
which browsers do not script. The edit textarea always shows the raw source.
The renderer lives in `todo-core/src/notes.mo`, deliberately isolated from
`view.mo`: at this Monad revision, having the markdown call inside the large
view module miscompiled `View.fragment_html` into a segfault (see `PLAN.md`).

**JSON.** The native backend uses the same hand-written, wasm-safe codec as
the SPA (`codec_web.mo`); `codec.mo` only re-exports/wraps it. The
serde-derived DTOs were removed because the compiler at `6a59e090` exhausted
memory (≈18 GB) when a test binary included a serde-derived module, which
made `monad test` and CI impossible (see `PLAN.md`).

**Known browser limit.** The SPA re-renders the whole list on every tick, and
the wasm bump allocator never reclaims memory. Rendering Markdown for
hundreds of long notes on every render can exhaust that heap (the smoke
harness's 64 KiB response test therefore uses long plain titles and a
separate small Markdown note). Keep notes short or the list small until the
renderer is cached or the runtime reclaims memory.

## Container image

`flake.nix` uses the pinned Monad flake (the compiler and the same revision as
the mote git dependencies) and the Monad Cachix cache; `--accept-flake-config`
lets Nix apply the flake's substituter settings. It builds the SPA, the
hash-pinned loader and the backend, and assembles a non-root `linux/amd64`
image. No sibling Monad checkout or local toolchain is needed for the build.

```bash
nix build --accept-flake-config .#image
docker load < result
docker run --rm -p 8095:8095 -v todo-state:/state todo-app:latest
```

The image runs the server with `WORKDIR=/app` and keeps state in the mounted
`/state` volume: `/app/entrypoint.sh` passes `--db /state/todos.db`, so the
SQLite database and its WAL/SHM files live there. See
[`deploy/README.md`](deploy/README.md) for registry/kind loading, the
Kubernetes manifests, probes, and the single-replica and file-state caveats.
