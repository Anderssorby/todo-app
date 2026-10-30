# TODO Web App in Monad — Dogfooding Plan

## Context

This repo exercises Monad (the custom language in the Monad repo, alpha,
using the installed `monad` binary) as a real external consumer would:
write a small but genuine web app, hit real friction, and register every
gap/bug/missing-feature in the sibling Monad plans repo using its existing
conventions. The TODO app itself is not the
deliverable — the gap reports are. The app will keep evolving as Monad's
tooling and "motes" (Monad's package format) mature.

Research confirmed, against the actual source (not docs claims):

- **Toolchain**: `monad build|run|check|test` all work against native
  binaries. `monad eval` (interpreter) is too immature to use. The
  self-hosted CLI is the shipped compiler; `monad version` reports the
  snapshot in `~/.monad/downloads/`.
- **WASM is now a measured capability, not a promise.** Monad has two wasm
  profiles:
  - **wasi** — `monad build --target wasm32-unknown-wasip1`, run under
    `wasmtime`. `fixtures/wasm/fib.mo` is differential-tested against the
    native build in `scripts/check-wasm-target.sh`.
  - **web** — `monad build --target wasm32-unknown-unknown`, a
    freestanding module loaded with a direct `WebAssembly.instantiate`.
    Its ABI is fixed: imports `write_stdout`, `write_stderr`,
    `read_stdin`, `now_ms` from module `monad`; exports `monad_main`,
    `memory`, `monad_alloc`, `monad_string_length`,
    `monad_i64_to_string`. Only `monad_main(0n)` is callable from JS —
    there is still **no source-level `#[export "c"]`** (wasm-target
    Phase 3 is blocked), so arbitrary Monad functions cannot be exported.
    `examples/oak_page.mo` has rendered in headless Firefox through the
    loader (`?autorun=1&render=1`, 2026-10-19).
  - The wasm runtime has **no GC**: wasi uses a leaky `malloc`, web a bump
    allocator over `__heap_base`. Codegen never emits `monad_release`.
    One-shot programs, or reload-by-reinstantiating sessions, are the
    supported shape. Files, sockets, threads, processes, and `get_env`
    are compile-time target errors (`stream_open`, `file_exists`, `tcp_*`,
    `fork_io`). `f64_to_string`/`f64_of_string` are additionally gated
    off on the web profile.
  - `--target` takes a separate argument (`--target=x` does not parse).
    `monad run` and `monad test` are native-only, so wasm verification is
    `wasmtime`, Node, or the browser loader.
  - **`Json.to_string` is not web-safe**: its number arm calls
    `F64.to_string`, which reaches the gated `f64_to_string` native, so a
    reachable `Json.to_string` fails the web profile even for an
    integer/string document. The shared codec must hand-write its
    encoder (see M4/M8 and the filed gap).
- **`oak` + `xml_html` are the HTML layer.** `motes/xml_html` owns
  `Html.Attr`/`Html.Node` and a serializer that escapes text and attribute
  values. `motes/oak` adds Elm-shaped builders (`Html.div [attrs]
  [children]`, `Html.text`, `Html.document`, `Html.navbar`, `Html.card`,
  form/table/void elements) and re-exports the types' helpers. Missing
  curated builders matter here: `method`, `action`, `enctype`, and other
  raw-text attributes go through `Html.Attr.attr` / `Html.node`. Oak's
  `HtmlT`/`PageM`/`Program`/`Host` stack exists and its 52 tests pass on
  the Rust host, but **compiled use is blocked** by
  `dict-capturing-closure-segfault`:
  every `HtmlT` op stores a Monad-dictionary-capturing closure in a
  constructor, which traps (`null function or function signature
  mismatch`) from wasm and segfaults natively (plan
  `dict-capturing-closure-segfault`). Compiled code uses the pure builder
  API only, exactly as `examples/oak_page.mo` does.
- **`oak_wasm` landed 2026-10-23** (M15): a real DOM diff/patch SPA
  runtime over `oak::app`'s `Program`/`Command`/`Host` -- `Patch.diff`/
  `Patch.apply` (positional, v1: attrs by name, children by count, else
  replace) plus `Runtime.mount`/`.dispatch`/`.tick`, exposed by an app
  through three `#[export "c"]` thunks. This **corrects this plan's own
  earlier claim** that "there is still no source-level `#[export
  \"c\"]`" -- that was true of the wasm-target Phase 3 work generally, but
  `oak_wasm`'s own exports (and `fixtures/wasm/oak_spa.mo`, driven by
  `wasm/web/spa_smoke.mjs`) are a real, working counterexample. It sidesteps
  the `dict-capturing-closure-segfault` class by writing its batch fold
  monomorphically over `IO` rather than instantiating `Program.run_batch
  [Monad N]` -- the shape to keep watching if a future `Command.perform`/
  `Host` handler here starts trapping. `web_wasm` (also landed around the
  same time) is the much richer browser ABI this runs on: DOM
  create/append/replace/set_attr/set_text/listeners, two-phase `fetch`,
  `localStorage`, `console.log`, and one opaque `Keep` state slot --
  superseding the old "four imports" description of the web profile's ABI
  for anything that links `web_wasm` (`todo-frontend` stays on the plain
  four-import `monad_main` entry point; it never adopted this).
  `todo-app`'s browser shell (`todo-spa`, M15) is a real external consumer
  of this surface.
- **`moon` mote** gives an HTTP/1.1 server: `Server.serve` (sequential,
  keep-alive) and `Server.serve_concurrent` (fiber-per-request, bounded
  in-flight); **`router.mo`**: `Router.get/post/put/delete/patch`,
  `Router.route`, `Router.mount`, `Router.param`; **`middleware.mo`**:
  `Middleware.logging`, `.cors`, `.content_type`, `.auth_basic/.auth_bearer`,
  and a documented no-op `Middleware.recover` (Monad IO has no exception
  catching). `Server.serve` swallows a bind failure as a silent `unit`;
  `Server.run (ServerConfig.on port) handler` reports it as a `Result`
  instead, which M14's logging now surfaces -- `todo-backend` moved to
  `Server.run` for exactly that reason.
  **`static_files.mo` was rewritten** (M13, superseding the two v1
  limitations below): `Static.handler`/`StaticConfig` now read bytes
  exactly (`IO.read_file_bytes`, no decoding), set MIME by extension,
  answer `ETag`/`If-None-Match`/`Range`, and guard path traversal
  (percent-decode, reject `..`/control bytes/a leading-slash escape).
  `todo-backend` adopted it, retiring the `Assets.read_bytes` workaround
  and the `moon-static-no-mime-or-binary` gap below it used to route
  around: ~~`Server.static (root)` is native-only and has two v1
  limitations the app must work around: it sets no Content-Type, reads
  through `IO.read_file` (a `String`, so binary assets including `.wasm`
  are corrupted/truncated), and has no path-traversal guard~~ (resolved
  upstream by commits `74fbc58b`/`bb1c08fc`).
- **`http` mote** gives `Request`/`Response`/`Method`/`Status.*`/`Headers`,
  a `Transport` sum type over `FdStream`/TLS closures, `Wire`
  framing/parsing, `Uri`, and body handling. Incoming
  `multipart/form-data` is parseable (`Body.parse_multipart`, RFC 7578);
  **no incoming `application/x-www-form-urlencoded` decoder exists**, so
  a plain form post without the multipart enctype still cannot be parsed.
- **`json` mote** (new home of JSON, extracted from the compiler) is a
  pure `parsec`/`serde` implementation: `Json.parse` plus the accessors
  (`get_str`, `get_bool`, `get_array`, `get_object`, `object_get`,
  `get_num_i64`) and `make_*` builders. `lang::json` no longer exists.
  There is no derive for this app's types, so encode/decode stay
  hand-written.
- **`std::io` moved to streams/`Result`**: `IO.read_file : Path -> IO
  (Result StreamError String)`, `IO.write_file : Path -> String -> IO
  (Result StreamError Unit)`, `StreamError.is_not_found`; byte-exact file
  reads need `FdStream.open_file` + `Stream.read` + `ByteBuf`. `IO.read_line`,
  `IO.write_stdout`, and `IO.flush_stdout` work on both wasm profiles.
- **`moose`/`tls` are outbound-only.** `moose` is the HTTP/1.1 client;
  `Client.connect` returns a `Connection`, and HTTPS rides `Transport.secure`
  over `tls`'s fail-closed OpenSSL client (`Tls.connect`, `Tls.read`/`write`
  over `ByteBuf`). **`moon` has no server-side TLS** — the app can make
  HTTPS calls but cannot serve HTTPS. `tls`'s tests are env-gated
  (`MONAD_TLS_NETWORK_TESTS=1`), the precedent the app's network tests
  follow.
- **`init/` vs `std/` is the browser constraint for a *kernel*, not for
  every browser mote.** `init/` is pure and wasm-portable; `std/` holds
  the OS effects. `todo-frontend`'s one-shot kernel still stays at
  `init/`-level purity with the JS shell owning every effect (fetch,
  localStorage, the DOM) -- but `web_wasm` (M15) is itself a `std`-level
  mote that owns the DOM/fetch/storage/console effects AS Monad `IO`
  actions on the web target, and `todo-spa` is a real `std`-depending,
  effectful program compiled for `wasm32-unknown-unknown`. This plan's
  older framing ("the JS shell owns every effect") was true of the
  four-import `monad_main` ABI `todo-frontend` still uses; it is no longer
  true of the web profile in general.
- **No mutable-state primitive exists anywhere in `std`** — no
  `IORef`/`MVar`/`Cell`. `Array.set_in_place`/`Array.freeze` on an
  `ArrayBuilder` is the only in-place mutation, and server handlers are
  plain `Request -> IO Response` with no app state threaded through.
  **File-backed JSON state (read → mutate → write per request) remains the
  workaround**, and is the single most interesting gap this app surfaces.
  `Server.serve_concurrent` plus this shape is a lost-update race;
  `Server.serve` stays sequential for correctness.
- **Monad transformers exist now**: `init::transformers` has `StateT`,
  `ResultT`, and `OptionT` (`IdentityT`/`ReaderT`/`WriterT` still
  unwritten). `StateT`'s `bind` half has an executing test
  (`test_statet_bind`) after the checker's dictionary-resolution gap was
  fixed, so the old `MatchTraversalMismatch` note in this plan is stale.
  `prelude` has the `MonadState` class. Do-notation is IO-only in
  practice; transformer handlers use explicit `Monad.bind`/`>>=` chains.
  The filed dict-capturing-closure bug is the shape to watch if compiled
  `StateT` use starts trapping.
- **`moon`/`http` expose no stable public API yet**: both `src/lib.mo`
  files are deliberately empty and their defs are package-private.
  Cross-mote use works today with a warning that is documented to become
  an error. This app is a real external consumer of exactly that surface.
- **`log` (M14)** gives a `Logger` (min level, sink `String -> IO Unit`,
  structured fields, `plain_text`/`json_lines` format) and a `LogT` reader
  transformer. `todo-backend` uses it for request logging
  (`App.request_logging`, replacing moon's unleveled
  `Middleware.logging`) and for the two error paths `persist.mo` used to
  swallow silently. **It is not web-wasm-safe**: `Logger.log`'s
  `json_lines` match arm calls `Json.to_string`, which reaches the
  web-gated `F64.to_string` native -- since a `match` on a non-constant
  `LogFormat` must codegen both arms, this makes `Json.to_string`
  reachable (and the whole mote unbuildable for
  `wasm32-unknown-unknown`) even when only `plain_text`/`Logger.stdout`
  is ever used. Filed as a candidate gap, `log-mote-not-web-safe`.
  `todo-spa` calls `web_wasm::console.Console.log` directly instead.
- **`web_wasm`'s DOM API has no extern to read an element's live value**
  (only create/set_attr/set_text/append/replace/remove/listeners -- no
  `Dom.value`). A text-entry message (e.g. "add" with a typed title)
  cannot be driven through `oak_wasm`'s dispatch in this v1 API; only
  actions whose payload is already known at render time (toggle/delete by
  id) can. `todo-spa` (M15) keeps "add" on the existing no-JS multipart
  form for this reason. Filed as a candidate gap,
  `web-wasm-no-dom-value-read`.
- **Toolchain drift since M4/M5/M9 last compiled cleanly**: `monad check`
  now rejects several same-mote and cross-mote references this plan's own
  code previously relied on going unflagged -- `List.length`/
  `List.filter_map` used in `#[test]` bodies without a `use std::list
  {...}` line (`todo-core/src/action.mo`, `codec.mo`, `kernel.mo`,
  `todo-backend/src/form.mo`), and a same-mote `Storage.seed` reference
  without a `use lib::storage {Storage.seed}` line
  (`todo-core/src/action.mo`). All were one-line import fixes; no logic
  changed. Also hit: a `let x <- expr;` bind in a `do` block, immediately
  followed by a multi-case `match x {...}` as that arm's tail expression,
  failed to infer `x`'s type (`FieldPatternUnresolvedScrutinee` /
  "cannot resolve `{ .. }`: the matched value's type isn't known here")
  even though the binding's source (`IO.write_file`/`IO.read_file`) has a
  fully concrete `Result` type -- worked around with an explicit `let x :
  Result StreamError T <- expr;` annotation in `persist.mo`'s
  `Persist.save`/`Persist.load`. Neither has been filed upstream yet.
- Manifests require **sub-table** `[dependencies.x]` headers, not inline
  `{ path = "..." }` tables — the self-hosted TOML reader cannot parse
  inline tables and silently disables the dep check instead of erroring.
- `plans-monad` has a formal **Bug Discovery Protocol** (`AGENTS.md`):
  file a plan entry named `<slug>` (frontmatter `status: needs-fix`,
  `priority`, `code_area`, `completion: 0`; body Symptom / Reproduction /
  Worktree/Branch / Root Cause / Workaround / Affected Plans), add a
  `🐛 Bug` row to `PLANS.md`, and a `DEPS.md` edge if it blocks a plan.
  Separately, `todo-app-architecture` is the precedent for a
  "product built on Monad" doc outside the `PLANS.md`/`DEPS.md` indexes;
  it keeps this app's running "Gaps Discovered" log.

## Environment Setup

`monad build`'s native pipeline shells out to **`llc`** for codegen and
**`lld`**/**`clang`** for linking, and the generated runtime links against
**`-lgc`** (Boehm GC) via clang's search path — mirrors
`monad/devenv.nix`. `devenv.nix` here declares `llvm`, `lld`, `clang`, and
`(boehmgc.override { enableStatic = true; })` (the static `libgc.a` is
required because the link line passes `-Wl,-Bstatic -lgc`).

WASM builds add a second toolchain:

- **wasi-sdk 34.0** is pinned from the official tarball in `devenv.nix`
  (mirroring `monad/nix/packages.nix`); `env.WASI_SDK_PATH` points at it on
  x86_64-linux. Its `bin/clang` stays off `PATH` — it would shadow the
  native clang and default every build to wasm32.
- **`wasmtime`** runs the wasi profile; **`nodejs`** runs the web profile's
  smoke harness.
- `monad run`/`monad test` have no `--target`; wasm execution is external.

Run `devenv shell` before any `monad` command. `devenv.lock` is kept
refreshed with the pinned nixpkgs input.

## Repo / Mote Layout

`todo-app` is a **workspace** (root `mote.toml` has no `[mote]` of its
own, just `[workspace] members`), mirroring `../monad`'s workspace-root
pattern. A mote reached from another mote needs an identifier-safe name
(`todo_core`); a binary such as `todo-backend` keeps its hyphen. Still a
standalone repo, not folded into `monad/motes/`; `moon`/`http`/`json`/
`oak`/`xml_html` are cross-repo path deps:

> **Superseded 2026-10-27.** These sibling `../../monad` path dependencies
> are now git dependencies pinned to
> `https://github.com/monad-lang/monad.git` at `12b74e92`; see
> [Dependency migration and packaging](#dependency-migration-and-packaging-2026-10-27).
> The snippets below record the original layout.

```toml
# todo-core/mote.toml -- pure, wasm-portable shared core
[mote]
name = "todo_core"
version = "0.1.0"
edition = "2026"

[lib]
path = "src/lib.mo"

[dependencies.init]
path = "../../monad/init"

[dependencies.std]
path = "../../monad/std"

[dependencies.json]
path = "../../monad/motes/json"

[dependencies.oak]
path = "../../monad/motes/oak"

[dependencies.xml_html]
path = "../../monad/motes/xml_html"
```

```toml
# todo-backend/mote.toml
[lib]
path = "src/lib.mo"

[bin]
name = "todo-backend"
path = "src/main.mo"

# `lang` is gone; JSON lives in its own mote.
[dependencies.json]
path = "../../monad/motes/json"

[dependencies.oak]
path = "../../monad/motes/oak"

[dependencies.xml_html]
path = "../../monad/motes/xml_html"

[dependencies.moon]
path = "../../monad/motes/moon"

[dependencies.http]
path = "../../monad/motes/http"

[dependencies.todo_core]
path = "../todo-core"

[dependencies.log]
path = "../../monad/motes/log"
```

```toml
# todo-spa/mote.toml -- the browser SPA, web-only
[mote]
name = "todo_spa"
targets = ["web"]

[bin]
name = "todo-spa"
path = "src/main.mo"

[dependencies.todo_core]
path = "../todo-core"

[dependencies.oak]
path = "../../monad/motes/oak"

[dependencies.oak_wasm]
path = "../../monad/motes/oak_wasm"

[dependencies.web_wasm]
path = "../../monad/motes/web_wasm"
# NOT log: see the `log-mote-not-web-safe` gap above.
```

```
todo-app/
  mote.toml           # [workspace] members = [todo-core, todo-backend, todo-spa]
  devenv.nix          # native toolchain + wasi-sdk/node/wasmtime
  README.md
  PLAN.md
  todo-core/          # pure: domain, actions, JSON codec, oak view, wasm kernel
    mote.toml
    src/
      lib.mo          # re-exports storage/action/codec/view/kernel
      storage.mo      # Todo struct, pure list ops + #[test]s
      action.mo       # Action sum type + pure Action.apply
      codec.mo        # hand-written JSON encode/decode (wasm-safe)
      view.mo         # oak builders -> Html.Node / fragment_html / page_html
      kernel.mo       # Kernel.handle : JSON line -> JSON line (no longer
                       # consumed by any mote now that todo-frontend is gone,
                       # M18 -- kept for its own #[test]s over the shared core)
  todo-backend/       # native: moon server + file-backed persistence
    mote.toml
    src/
      main.mo         # routes + CLI (clap: --port/-p, --help) + Server.run
      handlers.mo     # Request -> IO Response (HTML + JSON API)
      persist.mo      # JSON file load/save via todo_core's codec
      logging.mo      # App.logger + App.request_logging (the log mote)
  todo-spa/           # wasm (web-only): the real typed-event oak_wasm SPA
    mote.toml         # + [dependencies.runtime] pinning the checkout's C ABI
    src/main.mo       # Model/Msg/Effect, typed handlers, forms, DnD,
                      # oak_mount/oak_dispatch_event/oak_tick
  todo-webgen/        # native: hash-pin the browser loader with jsgen
    mote.toml
    src/main.mo       # reads web/{web,web_runtime,float_format}.js + app.wasm
  web/                # static shell served through moon's Static.handler
    index.html
    boot.js           # generated by todo-webgen: hash-pinned loader entry
    web.gen.js        # generated: web.js with a hash-pinned runtime import
    web_runtime.gen.js# generated: web_runtime.js with a hash-pinned float import
    boot.version      # generated: SHA-256 of boot.js (read by the SSR shell)
    web.js            # monad's generated oak_wasm loader, vendored verbatim
    web_runtime.js    # monad's hand-written browser host, vendored verbatim
    float_format.js   # monad's shared F64 formatter (imported by web_runtime.js)
    smoke.mjs         # Node harness: mount/dispatch/tick over a stub DOM + fetch
    app.wasm          # build artifact (gitignored), built from todo-spa
  todos.json          # runtime state, file-backed, relative to cwd
```

Build/check/test from the workspace root by passing the mote directory:
`monad check --workspace`, `monad build todo-backend`,
`monad test todo-backend/src` (a directory argument, because the no-path
form only follows manifest target roots). The browser shell is
`monad build --target wasm32-unknown-unknown todo-spa -o "$PWD/web/app.wasm"`,
then `monad build todo-webgen && ./target/debug/todo-webgen` to hash-pin the
loader graph, then `monad build todo-backend` and run it.
`todo-frontend` (the wasi native/wasi differential baseline for
`todo_core`) was removed in M18 once `todo-spa` had fully taken over as
the browser frontend; `todo_core::kernel` it exercised has no remaining
consumer but keeps its own `#[test]`s.

## Milestones

- **M0 — Standalone hello world.** ✅ Done. `monad check`/`build`/`run`/
  `test` work from this standalone repo. (Filed:
  `main-unit-return-exits-garbage-code`.)
- **M1 — `moon`/`http` path deps resolve; minimal server.** ✅ Done.
  Cross-repo path deps resolved cleanly; `curl` confirmed a real 200.
- **M2 — In-memory routing + HTML, no persistence yet.** ✅ Done. Four
  routes (`GET /`, `POST /todos`, `POST /todos/:id/toggle`,
  `POST /todos/:id/delete`). Filed:
  `struct-update-paren-base-fails-to-parse`,
  `struct-field-access-as-if-cond-segfaults-nonzero-index`
  (the segfault workaround has since been removed in M4), and
  `monad-test-no-path-globs-unrelated-dot-mo-files`.
- **M3 — File-backed JSON persistence.** ✅ Done at the time, but its
  source predated three breaking changes (`lang::json` extraction,
  `Result`-returning file I/O, the stream refactor). M4 rebases it.
- **M4 — Rebase onto current Monad.** ✅ Done 2026-10-20. `mote.toml`
  drops `lang` and adds `json`/`oak`/`xml_html`; `handlers.mo` and
  `persist.mo` use `json::json`; `Persist.load` consumes `read_file`'s
  `Result StreamError` (missing/unreadable/malformed → seed);
  `Persist.save` discards the write error (the handler type has no error
  channel — a limitation for M6 to improve); the hand-written encoder
  uses a local byte-wise `escape_json_string` and never calls
  `Json.to_string`; the now-fixed `Bool.not (Bool.not t.done)` workaround
  was removed; `devenv.nix` gained the static Boehm GC, wasi-sdk,
  `WASI_SDK_PATH`, `wasmtime`, and `nodejs`. `monad check --workspace`,
  `monad build todo-backend`, `monad test todo-backend/src`, and the four
  curl routes are green. The `Json.to_string` web-profile gate is filed
  as `json-to-string-web-gate` and confirmed by the M8 probe.
- **M5 — `todo-core` + oak views.** ✅ Done 2026-10-20. Add `todo-core` as the second
  workspace member: move `Todo`/`Storage.*` there, add `Action` (`add`,
  `toggle`, `delete`, `render`) with a pure `Action.apply`, a hand-written
  wasm-safe JSON codec (`todos_to_json`, `todos_from_json`,
  `envelope_to_json`), and an oak `View` (`fragment_html`, `page_html`)
  with `data-op`/`data-id` attributes and a multipart no-JS form built
  through `Html.Attr.attr`. The backend deletes `html.mo`, keeps only
  `handlers.mo` + `persist.mo`, and renders through `Html.to_string`
  (which also escapes titles — the old string concat did not, a latent
  XSS gap). Tests: the moved storage tests, codec round-trip/escaping, and
  a golden HTML assertion. Log any oak API friction (missing `method`/
  `action`/`enctype` builders; raw-text attributes) rather than hiding it.
- **M6 — JSON API + no-JS fallback + assets.** ✅ Done 2026-10-20. `GET /api/todos` and
  JSON-returning mutation routes for the wasm shell; `POST /todos` (and
  toggle/delete) remain the no-JS HTML path, with create parsed through
  `Body.parse_multipart` (extract `boundary=` from `Content-Type`; no
  urlencoded decoder exists). Serve `web/main.js` and `web/app.wasm`
  through **explicit routes**: `Assets.read_bytes` uses
  `FdStream.open_file` + `Stream.read` + `ByteBuf.to_list`, the wasm is a
  `Body.from_bytes` response with `Content-Type: application/wasm`, and
  the module script gets `text/javascript`. Do not use `Server.static`
  for either (text-only, no MIME, no traversal guard) — the gap is filed
  as `moon-static-no-mime-or-binary`.
- **M7 — Browser click-through + styling.** ✅ Done 2026-10-20 (headless
  Firefox `?selftest=1`, synchronous XHR/wasm proof: add/toggle/delete
  through the shell, server state clean). Complete the standard M4 set:
  open the oak page in a real browser, create/toggle/delete, inspect
  `todos.json`. Add minimal inline `<style>` through oak's `Html.style`.
  The old plain-`fetch()` JSON workaround is retired by the no-JS
  multipart form while the wasm shell uses the JSON API.
- **M8 — WASM baseline record.** ✅ Done 2026-10-20 (the probe reproduced
  the `Json.to_string` web gate at `compile_loaded_modules_to_ir`). No
  feature work: record exactly what the
  two profiles deliver (above), and run the `Json.to_string` web-gate
  probe to turn the expectation into verified evidence (it is already
  filed). Keep the "record the exact stage that fails" discipline if a
  build regresses.
- **M9 — `todo-frontend` wasm mote.** ✅ Done 2026-10-20; **removed M18
  (2026-10-25)** once `todo-spa` had fully taken over as the browser
  frontend and this differential baseline had no further role. A tiny
  `main.mo` (`IO.read_line` →
  `Kernel.handle` → `IO.write_stdout` + `IO.flush_stdout`) over
  `todo-core` only. The kernel takes one JSON line
  `{"state":[...],"action":{...}}` and returns one JSON line
  `{"state":[...],"html":"..."}`; the output encoder is hand-written so
  the web build never reaches `Json.to_string`. Verify three ways:
  native (`monad run` with piped stdin), wasi (`wasmtime` with piped
  stdin; a differential against native), and web (a Node harness that
  implements `read_stdin`/`write_stdout`). No `HtmlT`/`Program` until the
  dict-capturing-closure bug is fixed.
- **M10 — `web/` shell.** ✅ Done 2026-10-20. `web/main.js` caches the wasm bytes and
  instantiates a **fresh module per action** (one-shot, leaky by design),
  supplies the action JSON through `read_stdin`, captures `write_stdout`,
  and replaces the `#app` fragment. It owns fetch to `/api/todos`,
  localStorage caching, and event delegation (`data-op`/`data-id`); the
  fixed four-import ABI is sufficient because the shell owns every
  effect. `GET /` keeps the oak server-rendered fallback and loads the
  module script; the wasm SPA is the primary UI. Verify with a real
  browser against the running backend (M7's standard applies again).
- **M11 — `StateT` handler probe.** With `ResultT`/`OptionT` landed and
  `test_statet_bind` green, try refactoring the read-mutate-write dance
  into `StateT (List Todo) IO` with `MonadState`, file load/save through
  `StateT.lift`, and `StateT.eval` only at the request boundary. If
  compiled use reproduces the dict-capturing-closure trap, minimize it
  outside `init` and attach the repro to the filed entry rather than
  filing a near-duplicate. Keep the pure `Storage`/`Action` tests in
  `todo-core` as the non-transformer baseline.
- **M12 — Outbound moose/tls sync.** Last, after the wasm path: a
  `POST /todos/import` route that `Client.get`s a remote JSON list over
  HTTPS (moose → `Transport.secure` → `Tls.connect`'s fail-closed
  handshake) and merges it, built on the M11 layer if it landed; plus one
  direct `Tls.connect` probe (a raw HTTP/1.1 GET over `Tls.write`/
  `Tls.read`) so `tls` is exercised directly. Network verification stays
  env-gated (`TODO_APP_NETWORK_TESTS=1`, mirroring
  `MONAD_TLS_NETWORK_TESTS=1`) with bounded retries. Expected limitations
  to log when hit: no timeouts (a hung remote blocks the whole sequential
  server), no server-side TLS in moon, and the still-missing urlencoded
  decoder.
- **M13 — Adopt moon's fixed static serving.** ✅ Done 2026-10-23. Deleted
  `todo-backend/src/assets.mo` and the explicit `/web/main.js`/
  `/web/app.wasm` routes; one wildcard route,
  `Router.get "/web/*" (Handler.try Handlers.not_found (Static.handler
  (StaticConfig.default ".")))`, now serves everything under `web/` with
  correct MIME/ETag/Range and a traversal guard. `moon-static-no-mime-or-binary`
  is resolved upstream (`74fbc58b`/`bb1c08fc`) and retired below.
- **M14 — Structured logging via the `log` mote.** ✅ Done 2026-10-23
  for the backend; blocked for the wasm frontend (see
  `log-mote-not-web-safe` above). `todo-backend/src/logging.mo` adds
  `App.logger`/`App.request_logging`, replacing moon's unleveled
  `Middleware.logging` and wired through `Server.run` (which, unlike
  `Server.serve`, reports a bind failure instead of swallowing it --
  `App.logger` now logs that too). `persist.mo`'s two previously-silent
  error paths (a failed write, a read failure that isn't "not found") log
  at `warn`. `todo-spa` calls `web_wasm::console.Console.log` directly
  instead of the `log` mote, for the reason filed above.
- **M15 — Migrate the browser shell to `oak_wasm`.** ✅ Done 2026-10-23.
  New mote `todo-spa` (web-only): `Model {todos, pending, loaded}`,
  `Msg {toggle, delete, poll, began, loaded, failed}`,
  `Effect {load, sync, check, cache}`, a monomorphic `Host IO Effect Msg`,
  and the three `#[export "c"]` thunks. `oak_tick` enqueues a synthetic
  poll message (`Runtime.dispatch decode 0i64`) before every
  `Runtime.tick`, which is what drives a pending `web_wasm::fetch`'s
  two-phase `begin`/`poll`/`read` across animation frames without any
  change to the vendored `web.js`/`web_runtime.js` loader. Reuses
  `todo_core::view::View.add_form` for "add" (see the DOM-value-read gap
  above) and a new `Spa.item`/`Spa.view` for the toggle/delete list, with
  real `data-oak-on-click` dispatch (handler id `id*2` for toggle,
  `id*2+1` for delete -- cheap since every todo id is a positive `I64`).
  `web/main.js` (161 lines: per-action reinstantiate, hand-rolled ABI,
  manual event delegation) is gone, replaced by a thin `web/boot.js`
  (start the module, install the form intercept) over the vendored generic
  loader; the intercept itself is `web/fetch_intercept.js`, added with M16.
  Verified with an adapted
  `web/smoke.mjs` (mount, initial load, toggle, delete, all through a
  stubbed `fetch` and `localStorage` over a stub DOM -- see
  Verification). `todo-frontend` is untouched and kept as the native/wasi
  differential baseline for `todo_core`.
- **M16 — Visual redesign: tags/groups/notes/subtasks/edit/menu/settings/footer.**
  ✅ Done 2026-10-25 (resumed after the upstream `oak_wasm` fix landed; see
  below). `todo-core`/`todo-backend` done and verified:
  `storage.mo` gained `Subtask {id, title, done}` and extended `Todo` with
  `notes : String`, `tags : List String`, `group : Option String`,
  `subtasks : List Subtask` (all defaulting on creation; subtask ids a
  single counter shared across every todo, not per-parent, since dispatch
  only ever carries a bare subtask id); `Storage.edit`/`add_subtask`/
  `toggle_subtask`/`delete_subtask`/`clear_completed` (10 new tests).
  `action.mo` gained matching `Action` variants + JSON decode (6 new
  tests). `codec.mo`'s hand-written encode/decode covers every new field,
  decoding a *missing* key as the empty/none/default rather than failing
  -- the pre-existing 4-item `todos.json` (bare `id`/`title`/`done`)
  decodes cleanly with no migration step, verified against the actual
  file, not just a synthetic one (5 new tests, 2 new golden-HTML tests
  after fixing the two pre-existing 3-field `Todo` test literals -- see
  the filed gap below). `view.mo` gained `View.edit_form`/
  `subtask_add_form`/`subtask_toggle_form`/`delete_form`/`group_badge`/
  `tag_chip`/`footer`, a `data-theme`-aware CSS-variable theme (light/dark,
  OS-preference fallback), and `data-fetch-intercept` tagging on every
  typing-based form (7 new golden tests). `todo-backend` gained
  `/todos/:id/edit`, `/todos/:id/subtasks`, `/subtasks/:id/(toggle|delete)`,
  `/todos/clear-completed` plus `/api/*` JSON twins for the three
  click-only ones (`edit`/`add_subtask` never need a JSON twin -- the SPA
  can never construct them itself, see M9's note); `form.mo`'s
  `Form.title_of` generalized into `Form.value_of`/`tags_of` (single
  comma-separated field, no urlencoded decoder exists)/`group_of` (4 new
  tests). Full curl pass against the *live* server with the real
  (legacy-shaped) `todos.json`: migration, edit, add/toggle/delete
  subtask, clear-completed, and the no-JS `GET /` page all verified by
  hand, not just by test suite. `monad check --workspace` 0 errors;
  `monad test todo-core/src` 34/34; `monad test todo-backend/src` 8/8;
  the `todo-frontend` wasi differential baseline re-verified unaffected.
  **`todo-spa` is implemented (`Model` gained `page : Tab`/`dark_mode`/
  `hide_completed`; a handler-id encoding extended into negative space for
  tab-switch/settings/clear-completed/a new `refresh` sentinel that
  `boot.js` calls after an intercepted form POST, plus a
  `-(1,000,000+sid*2[+1])` range for subtask toggle/delete) and compiles
  clean.** It was blocked live by an `oak_wasm` bug: nesting the task
  list behind the new nav/tab wrapper (needed for M16's menu/settings
  requirement) hit `Patch.drop_last`'s wrong-parent path, so the live DOM
  never showed the task list past depth 2 (filed as
  `2026-10-25-oak-wasm-patch-drop-last-corrupts-nested-paths`). **Fixed
  upstream 2026-10-25 and RE-VERIFIED LIVE**: rebuilt against the fixed
  `oak_wasm`, the whole `web/smoke.mjs` suite passes -- initial load,
  toggle, tabs, settings, theme, hide/clear completed, nested task list,
  depth-4 subtasks, delete, refresh. `boot.js`'s fetch-intercept is
  `web/fetch_intercept.js` (unit test: `node
  web/fetch_intercept.test.mjs`): intercepted multipart forms are posted
  with `fetch`, then `oak_dispatch_event(-6n)` reloads the model; create
  forms clear on success and keep their text on failure, edit forms keep
  their values, and a per-form in-flight guard drops double submits.
  `web/` re-vendors monad's loader (`web.js`, `web_runtime.js`,
  `float_format.js`) for the new DOM-read externs. The new
  `/todos/:id/edit` and `/todos/:id/subtasks` routes were also
  curl-verified directly against the running server (edit, add/toggle/
  delete subtask, clear-completed all confirmed in `todos.json`, then
  restored). **Not verified**: an actual real-browser click-through of
  `fetch_intercept.js`'s delegated `submit` listener -- this sandbox's
  headless Firefox cannot render at all (`RenderCompositorSWGL failed
  mapping default framebuffer`, no Xvfb/geckodriver/puppeteer/jsdom
  available as a substitute), so `node web/fetch_intercept.test.mjs` (a
  real DOM-less unit test of the same logic, injectable `fetch`/
  `document`) is the closest available proof; a manual pass in an
  environment with a working browser is still the open item.
- **M17 — Menu, tag/group filtering, dedicated new/edit pages, kanban
  board.** ✅ Done 2026-10-25. Fixed a real pre-existing gap first: the
  live SPA mounted over `web/index.html`'s tiny inline `<style>` stub and
  never actually applied `View.css` -- every M16 visual (cards, chips,
  theming) was unstyled in the one place that mattered. Fixed by making
  `View.css` `pub` and injecting it into `<head>` from `oak_mount` via
  `Dom.query`/`Dom.create`/`Dom.set_text`/`Dom.append` (confirmed in
  `web/smoke.mjs`: the injected `<style>` node exists and contains
  `View.css`'s content).
  `storage.mo` gained `Status {todo, doing, done}` (independent of
  `done`, synced both ways by `Storage.toggle`/`Storage.set_status`) and
  `Todo.status`; `codec.mo`/`action.mo` extended to match (a missing
  `status` key defaults from `done`, so the pre-existing `todos.json`
  keeps decoding with no migration step). `todo-backend` gained
  `GET /todos/new`, `GET /todos/:id/edit`, `GET /kanban`, and
  `POST (/api)/todos/:id/status/:status` (the kanban move buttons --
  the destination is a path segment, not a body field, since
  `Spa.sync_path` only ever posts an empty body). `view.mo` gained a
  shared no-JS `View.nav` (real `<a>` links), `View.new_page`/
  `View.edit_page`/`View.edit_not_found_page`, and the kanban board
  builders; `View.item`'s always-inline edit form became a link to the
  new dedicated edit page, and `View.fragment`'s always-inline add form
  moved to the new dedicated new-task page. `todo-spa` mirrors all of
  this with click-dispatch instead of forms/links (same duplication
  precedent as toggle/delete): `Tab` gained `kanban`/`new_task`/
  `edit_task(id)`; the handler-id table added four new magnitude bands
  (edit/move-prev/move-next/group-filter/tag-filter, each a distinct
  multiple of 1,000,000, bounded on both ends) plus four new fixed
  sentinels (kanban/new-task tabs, clear group/tag filter) -- `-1..-6`
  were deliberately left unrenumbered, since `web/fetch_intercept.js`
  hardcodes `REFRESH_HANDLER = -6n` and silently breaks if that shifts.
  The tag/group filter bar dispatches the *position* of a value in a
  freshly-sorted/deduped list (never the value itself -- no dropdown can
  be read back); `Spa.update` recomputes the identical list to resolve
  the index. After an intercepted add/edit form's refresh lands, `Tab.
  new_task`/`edit_task` switch back to `Tab.tasks` automatically (`Msg.
  loaded`'s arm), with no `boot.js` changes. `monad check --workspace` 0
  errors; `monad test todo-core/src` 48/48; `monad test todo-backend/src`
  8/8; `node web/fetch_intercept.test.mjs` and the extended
  `web/smoke.mjs` (now covering the new-task page, the edit page's
  prefill and stale-id-safe lookup, kanban move-and-sync, and the filter
  chip's toggle-on/toggle-off) both pass. Full curl sweep against the
  live server (new routes, status moves, no-JS edit submit, nav links)
  verified by hand against the real `todos.json`, then restored. Same
  open item as M16: a real-browser click-through is not possible in this
  sandbox (no working headless browser).
- **M18 — `todo-backend` CLI (`clap`) and `todo-frontend` removal.** ✅
  Done 2026-10-25. `todo-backend` gained a real CLI: `--port`/`-p PORT`
  (default `8095`, validated both as an integer at parse time by
  `motes/clap` itself and in-range for `U16` by `App.decode_cli`) and an
  auto-generated `--help`/`-h` (`clap` adds both unless the spec declares
  either spelling itself, so neither needed any code here). `main`
  changed from `IO Unit` to `IO I64` to carry `Cli.run`'s exit code
  (0/2 for help-or-ok/usage-error, matching every other `clap`
  consumer in the monad repo -- `motes/monadup`, `weaver`, `shuttle`).
  No `I64 -> U16` conversion exists anywhere in `std`/`init`, so the
  validated port is rebuilt digit-by-digit as a `U16` (`App.parse_port`),
  the same way `Cli.parse_i64_unsigned` builds an `I64`. Verified:
  `--help` prints full usage including the default; `--port`/`-p` both
  bind the given port (curl-confirmed); the default still binds `8095`;
  out-of-range (`99999999`), non-numeric (`abc`), and unknown-flag
  (`--bogus`) inputs all exit 2 with a `clap`-style error + usage.
  Removed `todo-frontend` (the wasi native/wasi differential baseline
  from M9) now that `todo-spa` has fully taken over as the browser
  frontend: dropped from `mote.toml`'s `[workspace] members`, its
  directory deleted. `todo_core::kernel` (the pure JSON-line handler it
  exercised) has no remaining consumer but keeps its own `#[test]`s, so
  it was left in place rather than deleted along with it. `monad check
  --workspace` 0 errors; `monad test todo-core/src` 48/48; `monad test
  todo-backend/src` 8/8.
- **M19 — Migrate to oak's typed web event system; SPA-owned forms and
  kanban DnD.** ✅ Done 2026-10-26. The monad checkout that this app
  path-depends on moved to `953102e2` (*oak: typed web events,
  drag-and-drop, clipboard and subscriptions*), replacing the
  numeric-handler-id boundary with typed `Oak.Node Msg`/`Oak.Attr Msg`
  views, pure `WebEvent -> HandlerResult Msg` handlers, and
  `Program.with_subs`. This supersedes M15/M16's `data-oak-on-click`
  id bands, `Spa.decode`, the synthetic poll in `oak_tick`, and the `-6`
  refresh sentinel.
  - `todo-core/src/view.mo`: SSR-only views are `Oak.Node Unit`; the shared
    `group_badge`/`tag_chip` are generic in `Msg`; every raw
    `Html.Attr.attr` became oak's typed `Html.attr`; `*_html` serialize
    through `Html.to_string (Oak.to_html …)`. `data-fetch-intercept` is
    gone.
  - `Action` gained `to_json` (the inverse of `from_json`), `parse_id`,
    `tags_of_text`, `group_of_text` (wasm-safe; the backend's
    `http::strings`/`Form.parse_tags` are native-only) + 9 tests.
  - `todo-spa/src/main.mo`: all numeric handler ids, `Spa.decode`, the
    offset bands and the `-6` refresh sentinel are deleted. Clicks are typed
    `Html.on_click`; an `animation_frame` subscription replaces the
    synthetic poll in `oak_tick`; `Runtime.mount` takes the `Program` (built
    from the localStorage model) and `Runtime.dispatch` takes the raw id.
    Add/edit/subtask controls are controlled SPA inputs (`on_input`/
    `on_change`) with `type="button"` actions handled by `Html.on "click"`
    (the SPA renders no `<form>`; Enter submits through
    `Html.on "keydown"`); they post one JSON `Action` to `POST /api/actions`.
    `Msg.loaded` clears the pending control. Kanban cards are drag sources
    (`draggable`, `drag_payload`) and columns drop targets (`Html.on
    "dragover"`, `drop_effect`, `Html.on "drop"`); the handler parses the
    payload with
    `Action.parse_id` and applies `set_status`. The subtask input is keyed by
    a generation counter so a successful submit recreates it (a dirty
    controlled input ignores an attribute-only clear).
  - `todo-backend`: new `POST /api/actions` (`Json.parse` ->
    `Action.from_json` -> apply/persist -> todo JSON). Existing HTML and
    `/api` routes stay; the no-JS fallback is unchanged.
  - `web/`: `web.js`/`web_runtime.js` re-vendored from `953102e2`;
    `todo-webgen` (native, uses `jsgen`) reads those plus the built
    `web/app.wasm` and writes the hash-pinned entry (`boot.js`,
    `web.gen.js`, `web_runtime.gen.js`, `boot.version`); every import/fetch
    URL carries its target's SHA-256. The SSR shell reads `boot.version`
    (`Persist.loader_version`) for `/web/boot.js?v=<hash>`, and
    `web/index.html` fetches the same file. `fetch_intercept.js` and its test
    are deleted; `smoke.mjs` pumps a fake `requestAnimationFrame` (the loader
    only dispatches frame subscriptions in `start_ticks`), drives the real
    typed handlers with synthetic events, and covers SPA
    add/edit/subtask-add and kanban DnD.
  - Toolchain note: the installed nightly (`e8af85e2`) predates the event
    ABI, so `todo-spa/mote.toml` declares a `runtime` dependency (now pinned
    to the same Monad git revision `12b74e92` as the other motes) — the
    compiler's manifest tier then links that
    `runtime/src/platform_web.c` (which includes the new
    `web_event_*`/`dom_*_global` wrappers). Without it the wasm link fails on
    those undefined symbols.
  Verified: `monad check --workspace` 0 errors; `monad test todo-core/src`
  57/57; `monad test todo-backend/src` 8/8; `monad test todo-webgen/src`
  6/6; the SPA wasm builds, `todo-webgen` writes the hash-pinned loader, and
  `node web/smoke.mjs` passes mount/load/toggle/tabs/settings/subtasks/add/
  edit/subtask-add/kanban-move/DnD/filters/clear/delete; `node
  web/boot_url.test.mjs` recomputes every SHA-256; `POST /api/actions` was
  curl-verified for add/edit/add_subtask/set_status/toggle (and 400 for
  bad JSON/action), alongside the multipart no-JS route, against a live
  server with a fresh `todos.json`.
  Follow-up (2026-10-26): the browser never mounted the SPA. `boot.js`
  passed a document-relative `./app.wasm` to the generated `start`, which on
  `/` and `/kanban` resolved to `/app.wasm` (a 404 HTML page); the browser
  reported that response as "Incorrect response MIME type. Expected
  'application/wasm'". `boot.js` now resolves `app.wasm` from
  `import.meta.url` and uses `WebAssembly.instantiate` over an ArrayBuffer
  instead of `instantiateStreaming`, so it does not depend on the server's
  Content-Type and reports `HTTP 404` clearly. The SPA's kanban move buttons
  are explicit `type="button"`; the SSR `<form>` moves remain only as the
  no-JS fallback. `node web/boot_url.test.mjs` guards the URL.
  Follow-up (2026-10-26, second): the SPA no longer renders any `<form>`.
  The add/edit/subtask controls are divs whose buttons are `type="button"`,
  and every button click, Enter-to-submit, and dragstart/dragover/drop
  handler uses the generic `Html.on` with `HandlerResult` (preventDefault on
  dragover/drop). `web/smoke.mjs` asserts zero `<form>` elements on the
  tasks, new-task, edit, and kanban views.
  Follow-up (2026-10-26, third): a browser reported `Loading failed for the
  module .../web_runtime.js` even though the server returned 200
  `text/javascript` with the full 23,780 bytes -- a stale/failed module
  fetch from a server restart. `/web/*` now serves `Cache-Control:
  no-store`. The loader is generated by `todo-webgen` using the `jsgen`
  mote: it SHA-256-hashes the vendored loader files and `app.wasm`, writes
  `web_runtime.gen.js` (float import pinned), `web.gen.js` (runtime-copy
  import pinned), `boot.js` (both imports + `app.wasm` pinned; module-
  relative URL and non-streaming instantiate), and `boot.version` (the hash
  of `boot.js`). `Persist.loader_version` reads `boot.version`, the page
  builders take it and emit `/web/boot.js?v=<hash>`, and `web/index.html`
  fetches the same file. `web/boot_url.test.mjs` recomputes every SHA-256;
  `todo-webgen` has 6 tests. `start.sh` builds the SPA, runs webgen, then
  builds/starts the backend. The SPA's kanban cards are asserted
  `draggable="true"` with dragstart/dragend listeners in `web/smoke.mjs`;
  the cards are not draggable until the SPA mounts, which is why a module
  failure also looks like "starting the card drag does not work" (the SSR
  cards remain).
  Follow-up (2026-10-27, fourth): the SPA could still fail to mount after the
  server had been running: `moon`'s `Server.run` is sequential and serves one
  kept-alive connection at a time, so when the browser opened a second
  connection for a module fetch it waited behind the page connection --
  `web_runtime.gen.js` "failed to load" and the SPA never mounted.
  `todo-backend` now probes `tcp_listen_on` (preserving the busy-port error)
  and runs `Server.serve_concurrent` with `max_in_flight = 16`. Verified in
  Chromium against `./start.sh`: six fresh loads all mounted; a native
  `dragTo` moved "Learn Monad" from To do to Doing; a synthetic DragEvent
  moved "Build a todo app" from To do to Done, with the API and DOM agreeing
  and no non-favicon console errors.
  Follow-up (2026-10-27, fifth): an occasional `RangeError: invalid or
  out-of-range index` from `web_runtime.gen.js`'s `str` during
  `dom_set_attr` was traced to unbounded wasm memory growth, not bad markup.
  `Spa.subs` installed `Subscription.animation_frame_msg Msg.poll`
  unconditionally; the loader dispatches `Msg.poll` every animation frame,
  and `Runtime.tick` re-renders/diffs the whole view for any dispatched
  message. The web profile's bump allocator never reclaims, so an idle page
  grew linear memory by ~12 MB/s (measured: 8.7 MB after mount, 22.7 MB more
  in 3 idle seconds). Past 2 GiB every string address has bit 31 set, and
  `platform_web.c`'s `web_str_ptr` (`(int64_t)(intptr_t)p`,
  `i64.extend_i32_s`) sign-extends it into a negative i64 at the JS boundary;
  `new Uint8Array(memory.buffer, negative, len)` then throws (Firefox words
  it exactly that way), aborting the patch that was mid-flight. Three fixes:
  `Spa.subs` now installs the frame subscription only while a load or action
  fetch is outstanding; the loader's frame loop calls `oak_tick` only when an
  event (or a frame poll) queued a message instead of on every idle frame;
  and the vendored `web_runtime.js` recovers the unsigned 32-bit word for
  pointer/length arguments (`word32`), so an address above 2 GiB still
  indexes correctly and a genuinely out-of-range argument logs `oak: string
  argument outside wasm memory` instead of throwing out of an animation
  frame. Measured in Chromium: linear memory went from 8.7 MB after mount to
  31.5 MB after 3 idle seconds before the fix (and on to gigabytes), and is
  flat (0 bytes over 3 s; 2.49 MB after mount) after it; 10 tab clicks add
  ~2 MB. Firefox verification with the real loader mounted, toggled after an
  idle wait, saved an edit, added a subtask, and moved a card To do -> Done
  by native drag with the API agreeing and no console errors. `node
  web/runtime_args.test.mjs` pins the unsigned-word recovery. The upstream
  `web_str_ptr` sign-extension is a runtime bug worth reporting; the loader
  fix is the local guard.

## Dependency migration and packaging (2026-10-27)

The app now consumes the Monad motes as git dependencies pinned to
`https://github.com/monad-lang/monad.git` at
`12b74e927bed6e149b9f2668f62bbf5e856d031c`, replacing every sibling
`../../monad` path dependency. The root workspace is virtual (no `[mote]`), so
there is no root lock: `todo-core`, `todo-backend`, `todo-spa` and
`todo-webgen` each carry a committed `mote.lock` (5/9/9/3 entries).
`scripts/fetch-deps.sh` is the one-time network step (`monad fetch` per
member, then an offline pass); every build/check/test uses `--locked` and
never fetches. The loader ABI is unchanged between the vendored loader's
commit `953102e2` and `12b74e92`, so `web/web.js`,
`web/web_runtime.js` and `web/float_format.js` are untouched (including the
local `word32`/idle-tick changes in `web_runtime.js`).

`flake.nix` takes the compiler and the source tree from the Monad flake input
pinned to the same revision (`12b74e92`), with the flake's nixpkgs following
the Monad input's pin so the compiler's cached derivation and the image use
one llvm/clang/glibc closure. It declares the Monad CI Cachix substituter, so
`nix build --accept-flake-config .#image` reuses the prebuilt compiler; the
git-checkout cache is seeded from the input's source tree, `MONAD_ROOT`
points at it for the ambient toolchain sources, and the same `--locked` build
steps produce the backend, SPA and hash-pinned loader. `dockerTools` then
assembles the non-root `linux/amd64` image (glibc only, `/bin/sh` + coreutils,
entrypoint). The image runs with `WORKDIR=/app`, bakes
`/app/todos.json -> /state/todos.json`, and seeds state in memory when the
file is absent. `deploy/kubernetes.yaml` targets one replica with `Recreate`
and a ReadWriteOnce PVC at `/state`; the backend's in-place, unlocked file
writes are not safe for multiple writers. See `deploy/README.md` for the
probes, persistence semantics, and deployment caveats.

## Review hardening (2026-10-28)

A review pass over the PR found and fixed:

- `web_runtime.js` started its animation-frame loop twice (upstream starts it
  once), so every frame dispatched the frame subscription twice and ran
  `oak_tick` twice while a request was outstanding. Removed; the hash-pinned
  loader was regenerated.
- `Persist.save` errors were logged but the handler still returned 200, so a
  client believed an unstored mutation had succeeded. `save` now reports the
  failure and handlers answer 500 (JSON text for `/api/*`, plain text for the
  no-JS routes).
- `Persist.load` treated an unreadable or malformed file as "no data" and
  returned the seed, so a read racing the in-place truncating write could be
  persisted over the real list. It now returns an error; handlers answer 500
  and leave the file untouched. A missing file still means the seed.
- The SPA read the response once with `Fetch.read rid 1000000`, but
  `web_fetch_read` caps every call at its 64 KiB scratch buffer, so any
  response larger than that was truncated into invalid JSON. It now drains in
  64 KiB chunks; `web/smoke.mjs` covers a 214 KB response.
- `Msg.failed` left the frame pump stopped with no way back. A failed fetch
  now renders a banner with a Retry control, and a non-2xx response is
  reported as `HTTP <status>` instead of "unparseable response".
- A group/tag filter whose last todo disappeared stayed active with no chip
  to clear it, leaving the list permanently empty. Filters are pruned when
  the authoritative list arrives.
- `Action.parse_id` accumulated digits with unchecked `I64` arithmetic, so a
  long drag payload could wrap onto an existing id. It uses `Parse.i64`,
  which rejects overflow (and negatives).
- `Codec.escape_char` passed control bytes below 0x20 (other than
  \b\f\n\r\t) through, producing JSON that RFC 8259 parsers reject. They are
  now `\u00XX`.
- `form.mo` reimplemented the multipart boundary/field parser on the false
  premise that the `http` mote had no form decoder. It now uses
  `Request.form_fields`/`Request.multipart`, and the no-JS forms post
  `application/x-www-form-urlencoded` (multipart is still accepted).

Known limits (documented in `deploy/README.md`): a mutation is a
non-transactional `load -> apply -> save`, so two mutations racing inside the
one pod can lose an update; the SPA has a single pending-request slot, so a
second mutation started before the first response leaves that response
unread; and the wasm shell always mounts on the Tasks tab, so `/kanban` and
the other SSR URLs are not deep links when JS is enabled.

## Toolchain bump: time + markdown motes, OAuth deferred (2026-10-30)

The public Monad HEAD moved to `6a59e090` (nightly 2026-10-30), which is the
first revision shipping `motes/time`, `motes/oauth` and `motes/markdown`.
Every manifest, `flake.nix` and `flake.lock` was bumped together (the
revision-skew guard still applies) and the four `mote.lock`s regenerated.

Decisions:

- **OAuth sign-in stays deferred.** The `oauth` mote at this revision is
  Phase 0-1 (authorization-code + PKCE, discovery, token exchange/refresh).
  It has no JWT/JWKS parser and never validates an ID token — no `iss`,
  `aud`, `exp`, `nonce` or signature check (`crypto::Pubkey.verify` is a later
  phase), and `OauthTokenSet.id_token` is carried as an opaque string.
  Accepting that token would authenticate nothing, so `/auth/login` and
  `/auth/callback` return 503 with that explanation and the gated
  `TODO_DEV_AUTH` stub remains the only sign-in. No `oauth` dependency is
  added to any manifest.
- **Time is a fixed offset.** The `time` mote has ISO-8601 parsing/printing,
  calendar conversion and a `TimeZone` class that is an empty seam for a
  future tz-database mote; there is no IANA or DST support. `users.timezone`
  (an unused IANA string) is replaced in the domain by
  `utc_offset_minutes` and migration 2 adds the column with a
  `-720..840`/multiple-of-15 check. `Instant.now` is **not** used as a wall
  clock: on compiled native binaries it is `CLOCK_MONOTONIC`, so SQLite
  `strftime('%Y-%m-%dT%H:%M:%SZ','now')` supplies "now".
- **Markdown renders with the mote's safe defaults.** `todo-core/src/view.mo`
  gained `View.markdown_notes`, shared by the SSR item and the SPA;
  `default_html_options` escapes raw HTML and drops
  `javascript:`/`vbscript:`/`file:` URLs. The one caveat is that
  `data:image/` — including SVG — passes the URL filter; it is rendered as an
  `<img src>`, which browsers do not script.

Changes:

- Migration 2 (`utc_offset_minutes_and_iso_timestamps`) adds
  `users.utc_offset_minutes` and rewrites every stored timestamp from SQLite's
  `YYYY-MM-DD HH:MM:SS` to ISO-8601 `...Z`, so lexicographic comparison and
  the shared parser agree. Migration 1 is untouched (checksums are frozen).
  All `datetime('now')` call sites (user upsert, sessions, OAuth state,
  `Db.now_m`) use the ISO `strftime`, and `Db.update_utc_offset` replaces the
  unused `update_timezone`.
- `todo-core/src/stamp.mo` formats created/updated timestamps and due dates at
  the user's offset, validates `YYYY-MM-DD` (`Date.parse_iso`, full
  consumption) and builds the offset labels/choices. `Action.validate_due` /
  `Action.due_valid` reject a malformed due date at every HTTP/form boundary
  (400) instead of storing it.
- The SPA now starts with `GET /api/me`: a 401 renders a login view and clears
  the cache; otherwise it stores the offset, loads `/api/todos`, renders
  Markdown notes, due chips and audit lines, and posts the Settings offset to
  `POST /api/me {"utc_offset_minutes":n}`. The add form carries
  notes/group/tags/due and the edit form carries due as well.
- `web/smoke.mjs` stubs `/api/me` (recording the offset POST), renders seeded
  audit/Markdown fields, checks the shifted timestamps, and has a
  `SMOKE_UNAUTH=1` mode for the 401 login view.

Two compiler defects found while integrating the motes:

- `serde-derived-module-ooms-the-test-checker` (found 2026-10-30 at
  `6a59e090`): `monad test todo-core/src/codec.mo` (and any test binary
  importing a serde-derived module, e.g. `kernel.mo`) grows to ≈18 GB and is
  OOM-killed; `monad check` of the same files and `monad build todo-backend`
  both succeed (the build took 242 s). A minimal one-DTO spike test compiles.
  Workaround for this app: drop the derive DTOs and use the hand-written
  wasm-safe codec for the native backend too (`codec.mo` now delegates to
  `codec_web.mo`). This removed ~8k affine warnings, cut the core check from
  ~68 s (codec alone) to seconds, and made `monad test todo-core/src` pass
  75/75.
- `markdown-in-view-mislowers-oak-render` (found 2026-10-30 at `6a59e090`):
  defining `View.markdown_notes` in `todo-core/src/view.mo` and calling it
  from `View.notes_preview` made `View.fragment_html`/`View.page_html`
  segfault at runtime even when the note was empty (the untaken markdown
  branch still corrupted the emitted code). Moving the renderer to
  `todo-core/src/notes.mo` (`Notes.markdown`/`Notes.preview`) fixes it;
  fragment and page spikes then rendered (1222 B / 8395 B) and the view suite
  passed 24/24. `markdown` itself is fine: a standalone `monad run` spike
  rendered `<p><strong>bold</strong></p>`.

Re-tested gaps:

- `2026-10-23-todo-core-view-page-html-tag-corruption-segfault` **no longer
  reproduces** at `6a59e090`: `View.page_html` renders (the spike above) and
  `view.mo`'s `test_page_loads_the_module_script` passes in the 24/24 run.
- The old serde derive-reflection failure in the SPA graph is moot for this
  app (serde is gone). The `time` mote's `#[derive BEq BOrd]` types do compile
  and run in the wasm SPA, so std's structural derives are fine at this pin.
- `workspace = true` **was re-tested at `6a59e090`** in a throwaway copy of
  the repo. A path dependency no longer makes `monad check` hang (the old
  failure), but the consumer still cannot load its submodules: with
  `[dependencies.todo_core] workspace = true` the SPA check reports `Todo`,
  `Status` and `Stamp.*` as unknown, so the root is resolved and the modules
  are not. A git dependency is inherited even less: `monad fetch`/`monad
  update` write an **empty** `mote.lock` (0 entries), and the subsequent
  workspace check then fails 226 errors. Full inheritance remains unusable;
  the members keep explicit path/git sources.

Gaps recorded:

- `oauth-mote-present-but-no-id-token-validation` — available at
  `6a59e090`, unusable for production sign-in until the JWT/JWKS and
  `Pubkey.verify` phases land.
- `spa-markdown-preview-memory-cost` — the SPA renders Markdown for every
  note on every full re-render, and the wasm bump allocator never frees. A
  smoke run with 700 notes of 200 characters exhausted the heap and crashed
  in oak's lowering (`null function or function signature mismatch`); the
  64 KiB response test now pads titles instead. Keep note lists small until
  the renderer is cached or the runtime reclaims memory.
- `time-mote-instant-now-monotonic-native` — `Instant.now` returns a
  `CLOCK_MONOTONIC` value on compiled POSIX/WASI binaries, not a Unix
  timestamp; the mote has no native wall-clock source.
- `time-mote-no-iana-timezones` — fixed offsets only; the `TimeZone` class has
  no implementation or tz database.
- `markdown-safe-urls-allows-data-image-svg` — the URL filter permits
  `data:image/` (including SVG); inert as an `<img>`, but a sanitiser is
  required before allowing raw HTML.

## Gap-Logging Workflow (continuous, not deferred)

After every `monad check`/`build`/`test`, wasm build/run, and curl check:
did it crash, panic, give a wrong/confusing error, or silently diverge
from documented behavior? If yes — stop, minimize a repro, file a plan
entry named `<slug>` per the protocol, add a `🐛 Bug` row to `PLANS.md`,
add a `DEPS.md` edge if it blocks a listed plan, implement the workaround
here with a comment naming the filed entry, and update the
`todo-app-architecture` gap log.

Current gap entries from this app:
`main-unit-return-exits-garbage-code`,
`struct-update-paren-base-fails-to-parse`,
`struct-field-access-as-if-cond-segfaults-nonzero-index`,
`monad-test-no-path-globs-unrelated-dot-mo-files`,
`json-to-string-web-gate`,
and `compiler-mote-revision-skew-is-not-diagnosed`.

**Found 2026-10-29, cause known** —
`compiler-mote-revision-skew-is-not-diagnosed`: a compiler built from
Monad nightly `a9d9a811` compiling motes pinned to `12b74e92` passes
`monad check` and then produces a binary that segfaults. `std`'s
`ByteBuf.alloc` changed between those revisions from a `#[native]`
declared as returning `IO ByteBuf` to a `RawIO` native wrapped in
`IO.mk`; against the newer runtime the old declaration yields a buffer
whose `ByteBuf.ptr` is NULL, `Sqlite.connect` passes that as
`sqlite3_open_v2`'s out-parameter, and SQLite writes the handle to
address 0 inside `openDatabase` — SIGSEGV before the backend's first log
line. The same skew made `IO.read_file` return an empty string, so
`todo-webgen` hashed an empty `app.wasm` and pinned `e3b0c44…` (the
empty-string SHA-256) as the loader's cache-buster. Minimal repro: a
15-line mote calling `Sqlite.connect` on `:memory:` (crashes with the
newer compiler, prints `opened ok` with the matching one). Diagnosis is
a `gdb` backtrace plus `info registers` (`rsi = 0` at `openDatabase`'s
`movq $0x0,(%rsi)`). Workaround: the toolchain must be the same revision
as the motes (the flake pins it; a local `monadup default` may not), and
the repo now pins `a9d9a811`, and `scripts/check-toolchain.sh` compares
`monad version` with the pin before anything is fetched or built (the
nightly workflow runs it). Regression cover added:
`todo-backend/src/db.mo`'s `test_db_migrates_and_round_trips` opens a
real connection and migrates in `monad test`, and the nightly workflow
boots the built server (production 401/302, then the dev stub, an empty
workspace, an add and a reload). Upstream fix: the checker must compare
the compiler's revision with the pinned `std`/`runtime` and reject the
build with a clear diagnostic — a native-ABI mismatch must never reach
codegen, and `monad test`/`monad build` must not emit a binary that
crashes on the first `ByteBuf` use.
The oak `HtmlT`/`Program` block is tracked under the existing
`dict-capturing-closure-segfault` entry.
**`moon-static-no-mime-or-binary` is resolved** (M13, upstream commits
`74fbc58b`/`bb1c08fc`) and no longer an open gap.

**Filed**: `2026-10-23-todo-core-view-page-html-tag-corruption-segfault`
(`plans-monad/implementations/`) — `View.page_html` (`GET /` and every
no-JS POST route) segfaults on every call: `monad_get_tag` dereferences
the raw integer `1` instead of a `List Html.Node` pointer. Confirmed
pre-existing (reproduces against the untouched pre-session code) and NOT
sandbox-specific -- a two-mote clean-room repro built to mirror
`todo-core`'s shape (oak builders + a struct + a sum type + `json`) does
**not** reproduce it, only the real `todo-core` mote's own
`View.page`/`View.page_html` does. This is what makes `todo-core/src/view.mo`'s
own `test_page_loads_the_module_script` report `driver exited -1` under
`monad test`, and it blocks `GET /` for `todo-backend` entirely --
`/api/*` JSON routes are unaffected, and so is `todo-spa`'s own wasm
build (a different codegen target). No workaround found; see the filed
entry for the full isolation log before attempting another one.

**Filed and fixed**: `2026-10-25-oak-wasm-patch-drop-last-corrupts-nested-paths`
(`plans-monad/implementations/`) -- `oak_wasm`'s `Patch.drop_last` resolved
the wrong parent node for any patch path of length >= 3 (its two-at-a-time
walk only happened to give the right answer at length <= 2), so any
wholesale `Patch.replace` nested past "direct child of the mount root"
silently landed nowhere: a dynamically-sized list sitting behind even one
wrapper element never updated in the live DOM, with no error. Isolated via
a 6-variant bisection against `todo-spa` (ruled out footer/nav/tabs/
settings/subtask-count and every affine-reuse warning; confirmed the pure
`Spa.view` function itself rendered correctly, only the live
`Runtime.tick`-driven DOM diverged) down to the exact function and traced
by hand for path lengths 1-4. Blocked M16's SPA half: the nav/tabs wrapper
needed for the menu/settings requirement, and any live subtask list inside
a task item, both need depth >= 3. **Fixed upstream 2026-10-25** (`monad`
commit `0f9089af`, `reverse . tail . reverse`) and **re-verified from this
repo** the same day: rebuilt `todo-spa` against the fixed `oak_wasm`,
re-vendored `web/web.js`/`web_runtime.js`/`float_format.js` (the ABI had
also grown hydration externs since the last vendor), and the full
`web/smoke.mjs` suite passes, including the nav/tabs wrapper and nested
subtask lists.

Candidate gaps found in M13-M15, not yet filed in `plans-monad` (todo-app
scope only; filing there is a follow-up): `log-mote-not-web-safe` (the
`log` mote reaches the web-gated `Json.to_string`/`F64.to_string` through
`Logger.log`'s `json_lines` arm regardless of the format actually used --
see Context), `web-wasm-no-dom-value-read` (**resolved 2026-10-26**: oak's
typed `WebEvent.value` now carries form values; see M19), a
toolchain-drift import-strictness regression (`List.length`/
`List.filter_map`/`Storage.seed` used without the `use` line that
declares them, across four files that previously checked clean --
one-line fixes, logic unchanged), and a `let x <- expr; match x {...}`
type-inference gap in `persist.mo` worked around with an explicit
annotation (see Context).

## Verification

- Every milestone: `monad check --workspace` → `monad build todo-backend`
  → re-run all prior milestones' curl/test checks → new checks.
- curl `GET /`, `POST /todos`, `POST /todos/:id/toggle`,
  `POST /todos/:id/delete`; inspect `todos.json` after each call. From M6,
  the same through `/api/todos` with JSON bodies. From M13, also `GET
  /web/web.js`/`/web/app.wasm` and check `Content-Type`/`ETag` come from
  `Static.handler`.
- Tests: `monad test todo-backend/src` and, from M5,
  `monad test todo-core/src`; instance/transformer tests must EXECUTE
  (`monad test`, not `check`), because instance resolution is a runtime
  step. A directory argument is used deliberately: the no-path and
  `--workspace` forms only follow manifest target roots.
- Wasm: `monad print-targets`; the M8 probe
  `monad build --target wasm32-unknown-unknown <probe>` for the
  `Json.to_string` gate; from M9 through M17, `monad build --target
  wasm32-unknown-wasip1 todo-frontend -o /tmp/todo-frontend.wasm` then
  `echo '{...}' | wasmtime …` (the native/wasi differential baseline for
  `todo_core`) -- **removed in M18** once `todo-spa` had fully taken over
  as the browser frontend; `todo_core::kernel` it exercised keeps its own
  `#[test]`s but has no remaining consumer. From M15
  `monad build --target wasm32-unknown-unknown todo-spa -o
  "$PWD/web/app.wasm"` then `node web/smoke.mjs` (mount, initial load,
  toggle, delete, driven over a stub DOM with a stubbed `fetch`/
  `localStorage`, in the style of monad's own `wasm/web/spa_smoke.mjs`)
  and a real-browser click-through. A relative `-o` lands under
  `target/debug/` when building a mote, so the asset path must be
  absolute. Record the exact stage (IR, llc, runtime compile, link,
  instantiate, trap) whenever one fails.
- From M15: browser click-through of the SPA against the running
  todo-backend (toggle/delete through real DOM dispatch; add through the
  no-JS form, per the `web-wasm-no-dom-value-read` gap), including a
  no-JS reload (the oak fallback must still work). The old `?selftest=1`
  synchronous-XHR technique is retired (see M15) -- `web/smoke.mjs` is
  the automated equivalent now. From M19 the SPA owns add/edit/subtask-add
  too, so the click-through covers those forms directly.
- From M19: `POST /api/actions` with `{"type":"add"|…}` bodies (add, edit,
  add_subtask, set_status, toggle) plus malformed-JSON/invalid-action 400s,
  and the no-JS multipart `POST /todos -F title=…`, against a live server.
  The SPA wasm must link the git-pinned `runtime` mote (rev `12b74e92`; the
  manifest-tier dependency in `todo-spa/mote.toml`); if the link reports
  undefined `web_event_*`/`web_dom_*_global`, the runtime C resolution fell
  back to the stale installed nightly.
- Boot path: `node web/boot_url.test.mjs`; on the live server
  `GET /web/app.wasm` must be 200 `application/wasm` and `GET /app.wasm` 404
  (the document-relative path that used to make `instantiateStreaming`
  report a wrong MIME type). In a browser, confirm the console mounts the
  SPA and the kanban move buttons are `type="button"` outside any form.
- From M12, with `TODO_APP_NETWORK_TESTS=1`: the import route against a
  real HTTPS host plus the direct `Tls.connect` probe; without the env
  var the network tests pass trivially, keeping offline sweeps green.
- After every manifest/devenv change: `devenv shell` → `monad check
  <mote>` → `monad build <mote>` from the workspace root.
- `curl GET /` currently segfaults the server -- this is the filed
  `2026-10-23-todo-core-view-page-html-tag-corruption-segfault`, not a
  sandbox artifact (confirmed via `coredumpctl`/`gdb` backtraces and
  reproduced against the untouched pre-session code). `curl GET
  /api/todos` and the other JSON routes are unaffected. `monad check
  --workspace`, both test suites (modulo `view.mo`'s own
  `test_page_loads_the_module_script`, which hits the same bug), the
  native build, and both wasm builds + their Node smoke tests all ran
  successfully in-session.
