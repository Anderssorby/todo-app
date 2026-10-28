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

/// Reports a write failure to the caller so the handler can answer 500:
/// otherwise every mutation returned 200 with the updated list even when
/// the file was never stored (read-only PVC, full disk), and the client
/// believed work that disappears on the next load had been persisted.
def Persist.save (todos : List Todo) : IO (Result String Unit) :=
  match Path.of Persist.file {
    Result.ok p => do {
      let r : Result StreamError Unit <- write_file p (Codec.todos_to_json todos);
      match r {
        Result.ok _ => return (Result.ok unit),
        Result.err e => do {
          let msg := "todos.json write failed: " ++ e.message;
          let _ <- Logger.warn App.logger msg;
          return (Result.err msg)
        },
      }
    },
    Result.err _ => return (Result.err "invalid todos.json path"),
  }

/// A missing file falls back to the seed list -- the expected first-run
/// case. A file that exists but cannot be read or parsed is an ERROR: the
/// writes truncate in place, so a read racing a write can see a partial
/// document, and returning the seed there made the next mutation persist
/// seed-derived state over the real list. Handlers turn this into a 500 and
/// leave the file alone.
def Persist.load : IO (Result String (List Todo)) :=
  match Path.of Persist.file {
    Result.err _ => return (Result.err "invalid todos.json path"),
    Result.ok p => do {
      let content : Result StreamError String <- read_file p;
      match content {
        Result.ok text => match Codec.todos_from_json text {
          Option.some todos => return (Result.ok todos),
          Option.none => do {
            let msg := "todos.json is not valid JSON";
            let _ <- Logger.warn App.logger (msg ++ "; refusing to replace it");
            return (Result.err msg)
          },
        },
        Result.err e => do {
          if StreamError.is_not_found e
          then return (Result.ok Storage.seed)
          else do {
            let msg := "todos.json read failed: " ++ e.message;
            let _ <- Logger.warn App.logger msg;
            return (Result.err msg)
          }
        },
      }
    },
  }
