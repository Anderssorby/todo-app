/// File-backed JSON persistence: read-mutate-write per request, since
/// Monad's std has no mutable-state primitive (no IORef/MVar/Cell) to
/// share a list across requests in memory.
///
/// The codec lives in `todo_core` and is shared with the wasm frontend;
/// it hand-writes the encoder because `Json.to_string` cannot be built
/// for the web profile (filed as the `json-to-string-web-gate` plan).

use todo_core::codec {Codec.todos_from_json, Codec.todos_to_json}
use todo_core::storage {Storage.seed, Todo}
use lib::logging {App.logger}
use log::logger {Logger.warn}
use std::stream {StreamError, StreamError.is_not_found}
open IO {write_file, read_file}

def Persist.file : String := "todos.json"

/// The hash of the generated `web/boot.js`, written by `todo-webgen`. The
/// SSR shell turns it into `/web/boot.js?v=<hash>`; a missing file (e.g.
/// `monad test` without a build) falls back to `"dev"`.
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

/// The write's `Result StreamError Unit` is discarded by the handler type
/// (it has no error channel), but it is no longer SILENT: a failure is
/// logged so a stuck/read-only todos.json shows up in the server log.
def Persist.save (todos : List Todo) : IO Unit :=
  match Path.of Persist.file {
    Result.ok p => do {
      let r : Result StreamError Unit <- write_file p (Codec.todos_to_json todos);
      match r {
        Result.ok _ => return unit,
        Result.err e => Logger.warn App.logger ("todos.json write failed: " ++ e.message),
      }
    },
    Result.err _ => return unit,
  }

/// A missing file falls back to the seed list silently -- the expected
/// first-run case. An unreadable or malformed file also falls back, but is
/// now logged: that case means real data could be lost.
def Persist.load : IO (List Todo) :=
  match Path.of Persist.file {
    Result.err _ => return Storage.seed,
    Result.ok p => do {
      let content : Result StreamError String <- read_file p;
      match content {
        Result.ok text => match Codec.todos_from_json text {
          Option.some todos => return todos,
          Option.none => do {
            let _ <- Logger.warn App.logger "todos.json is not valid JSON; falling back to the seed list";
            return Storage.seed
          },
        },
        Result.err e => do {
          let _ <-
            if StreamError.is_not_found e
            then return unit
            else Logger.warn App.logger ("todos.json read failed: " ++ e.message);
          return Storage.seed
        },
      }
    },
  }
