/// Web asset metadata, not state.
///
/// The todo list moved to SQLite (`lib/db.mo`); the only thing still read
/// from disk here is the generated `web/boot.version`, which the SSR shell
/// turns into `/web/boot.js?v=<hash>`.
use std::stream {StreamError}
open IO {read_file}

/// The hash of the generated `web/boot.js`, written by `todo-webgen`. A
/// missing file (e.g. `monad test` without a build) falls back to `"dev"`.
def Persist.loader_version : IO String :=
  match Path.of "web/boot.version" {
    Result.err _ => return "dev",
    Result.ok p => do {
      let content : Result StreamError String <- read_file p;
      match content {
        Result.ok text => return (String.trim text),
        Result.err _ => return "dev",
      }
    },
  }
