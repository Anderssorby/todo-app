# TODO Web App in Monad — Dogfooding Plan

## Context

This repo exercises Monad (the custom language at `../monad`, alpha,
`monad` binary installed at `~/.monad/bin/monad`) as a real external
consumer would: write a small but genuine web app, hit real friction, and
register every gap/bug/missing-feature in the sibling `../plans-monad`
repo using its existing conventions. The TODO app itself is not the
deliverable — the gap reports are. The app will keep evolving as Monad's
tooling and "motes" (Monad's package format) mature.

Research confirmed, against the actual source (not docs claims):

- **Toolchain**: `monad build|run|check|test` all work against native
  binaries. `monad eval` (interpreter) is too immature to use.
- **`moon` mote** (`monad/motes/moon/`) gives an HTTP server: `Server.serve`,
  `Server.serve_concurrent`, `Server.static`; **`router.mo`**:
  `Router.get/post/put/delete/patch`, `Router.route`, `Router.mount`,
  `Router.param`; **`middleware.mo`**: `Middleware.logging`, `.cors`,
  `.content_type`, `.auth_basic/.auth_bearer`, and a **documented no-op**
  `Middleware.recover` (Monad IO has no exception catching yet).
- **`http` mote** gives `Request`/`Response`/`Method`/`Status.*`/`Headers`.
  `Body.from_form` only *builds outgoing* urlencoded bodies — there is
  **no incoming `application/x-www-form-urlencoded` decoder**, so a plain
  HTML `<form method=post>` can't be parsed server-side today.
- **No mutable-state primitive exists anywhere in `std`** — no
  `IORef`/`MVar`/`Cell`. The only in-place mutation is
  `Array.set_in_place`/`Array.freeze` on an `ArrayBuilder`, not a general
  ref. `Server.serve`/`Router.route` handlers are plain `Request -> IO
  Response` with no app-state threaded through. **File-backed JSON state
  (read → mutate → write per request) is the only workaround**, and is
  itself the single most interesting gap this app surfaces.
- **No templating/HTML-rendering mote** exists — pages are rendered via
  plain `String.concat`.
- `Json` (via `lang::json`) has `Json.parse`/`Json.to_string`/
  `Json.make_object`/`Json.object_get`/`Json.get_str`/etc., but no derive
  — `Todo` encode/decode must be hand-written.
- `moon`/`http` predate the `src/lib.mo`/`src/main.mo` convention other
  motes use and are workspace members of `monad`'s own
  `[workspace] members = [..., "motes/*"]`. **Whether `use moon::server
  {...}` resolves at all for `todo-app`, a mote that lives in a sibling
  repo and is *not* a member of that workspace, was the biggest open risk
  going in** — resolved at M1 (see below: it works).
- Manifests require **sub-table** `[dependencies.x]` headers, not inline
  `{ path = "..." }` tables — the self-hosted TOML reader can't parse
  inline tables and silently disables the dep-check instead of erroring.
- `plans-monad` has a formal **Bug Discovery Protocol** (`AGENTS.md`):
  file `implementations/<slug>.md` (frontmatter: `status: needs-fix`,
  `priority`, `code_area`, `completion: 0`; body: Symptom, Reproduction,
  Root Cause, Workaround, Affected Plans), add a `🐛 Bug` row to
  `PLANS.md`, add a `DEPS.md` edge if it blocks something. Separately,
  `products/norwayledger-architecture.md` is the precedent for a
  "product built on Monad" doc that lives **outside** `PLANS.md`/
  `DEPS.md` indexing — `products/todo-app-architecture.md` follows that
  exact pattern and keeps a running "Gaps Discovered" log.

## Environment Setup

`monad build`'s native pipeline shells out to **`llc`** for codegen and
**`lld`**/**`clang`** for linking, and the generated runtime
(`runtime.c`) links against `-lgc` (Boehm GC) via clang's search path —
mirrors `monad/devenv.nix`. `devenv.nix`/`devenv.yaml` in this repo
declare `llvm`, `lld`, `clang`, `boehmgc`. Run `devenv shell` before any
`monad` command.

## Repo / Mote Layout

`todo-app` is a **workspace** (root `mote.toml` has no `[mote]` of its
own, just `[workspace] members`), mirroring `../monad`'s own
workspace-root pattern — set up this way so a future second mote (e.g.
a `todo-frontend`) can be added as another member. `todo-backend` is the
one member today, holding everything that was previously at the repo
root. Still a standalone repo, not folded into `monad/motes/` or added
to `monad`'s own workspace; `moon`/`http`/`std`/`lang` are cross-repo
path deps, one level deeper now that the mote itself is nested:

```toml
# todo-backend/mote.toml
[dependencies.moon]
path = "../../monad/motes/moon"

[dependencies.http]
path = "../../monad/motes/http"
```

```
todo-app/
  mote.toml           # [workspace] members = ["todo-backend"]
  devenv.nix, devenv.yaml
  README.md
  PLAN.md
  todo-backend/
    mote.toml
    src/
      main.mo       # routes + Middleware.logging + Server.serve
      storage.mo    # Todo struct, pure list ops + #[test]s
      persist.mo    # JSON codec + file load/save (todos.json)
      handlers.mo   # Request -> IO Response handlers
      html.mo       # String.concat page/form/item rendering
  todos.json          # runtime state, file-backed (M3+), relative to cwd
```

Build/check/test from the workspace root by passing the mote directory
(`monad build todo-backend`, `monad check todo-backend`, `monad test
todo-backend/src/storage.mo`) — confirmed working, no gap found.

## Milestones

- **M0 — Standalone hello world.** ✅ Done. `monad check`/`build`/`run`/
  `test` all work from this standalone repo. (Filed:
  [main-unit-return-exits-garbage-code](../plans-monad/implementations/2026-10-04-main-unit-return-exits-garbage-code.md)
  — moot here since `Server.serve` never returns.)
- **M1 — `moon`/`http` path deps resolve; minimal server.** ✅ Done.
  Cross-repo path deps resolved cleanly — no gap. `curl` confirmed a
  real 200 response end-to-end.
- **M2 — In-memory routing + HTML, no persistence yet.** ✅ Done. All
  four routes (`GET /`, `POST /todos`, `POST /todos/:id/toggle`,
  `POST /todos/:id/delete`) verified via curl. Form submits JSON via
  `fetch()` (no incoming form decoder exists). Explicit
  `Content-Type: text/html` on responses. Filed three gaps while
  building this:
  [struct-update-paren-base-fails-to-parse](../plans-monad/implementations/2026-10-04-struct-update-paren-base-fails-to-parse.md),
  [struct-field-access-as-if-cond-segfaults-nonzero-index](../plans-monad/implementations/2026-10-04-struct-field-access-as-if-cond-segfaults-nonzero-index.md)
  (a real segfault — see the workaround comment in `src/html.mo` and
  `src/persist.mo`), and
  [monad-test-no-path-globs-unrelated-dot-mo-files](../plans-monad/implementations/2026-10-04-monad-test-no-path-globs-unrelated-dot-mo-files.md).
- **M3 — File-backed JSON persistence.** ✅ Done. `src/persist.mo`:
  `Persist.load`/`Persist.save` against `todos.json`, hand-written JSON
  codec via `lang::json`. Verified end-to-end: create/toggle/delete each
  persist correctly and a fresh `GET /` after all three reflects the
  right final state.
- **M4 — Toggle/delete end-to-end + minimal styling.** Toggle/delete are
  already verified via curl (M3). Minimal inline `<style>` is in place.
  **Not done: an actual browser click-through** — no GUI browser was
  available in the session that built this; do this manually next.
- **M5 — Polish (not started).** `GET /todos` JSON endpoint; explicit
  400/404 error responses (already partially in place via
  `Handlers.bad_request`); optionally provoke/document the
  `Server.serve_concurrent` lost-update race on `todos.json`.

## Gap-Logging Workflow (continuous, not deferred)

After every `monad check`/`build`/`test` and every curl check: did it
crash, panic, give a wrong/confusing error, or silently diverge from
documented behavior? If yes — stop, minimize a repro, file
`../plans-monad/implementations/<slug>.md` per the protocol, add a row
to `../plans-monad/PLANS.md`, implement the workaround here with a
comment linking to the filed entry, update
`../plans-monad/products/todo-app-architecture.md`'s gap log.

## Verification

- Every milestone: `monad check` → `monad build` → re-run all prior
  milestones' curl/test checks → new checks.
- curl `GET /`, `GET /todos`, `POST /todos`, `POST /todos/:id/toggle`,
  `POST /todos/:id/delete`; inspect `todos.json` after each call.
- `monad test src/storage.mo` for pure list-op and JSON round-trip tests.
- Manual browser click-through from M4 onward.
