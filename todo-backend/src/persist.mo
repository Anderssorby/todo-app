/// File-backed JSON persistence: read-mutate-write per request, since
/// Monad's std has no mutable-state primitive (no IORef/MVar/Cell) to
/// share a list across requests in memory. Hand-written JSON encode
/// (plain string concat, matching html.mo's style) and decode (via
/// lang::json's Json.parse + accessors) since there is no derive.

use lib::storage {Storage.seed, Todo}
use lang::json {Json}
use std::list {List.filter_map, List.intercalate}
open IO {write_file, read_file, file_exists}

def Persist.file : String := "todos.json"

def Persist.todo_to_json (t : Todo) : String :=
  // t.done is field index 2 of 3 -- `if t.done then ...` directly
  // segfaults, see plans-monad/implementations/
  // 2026-10-04-struct-field-access-as-if-cond-segfaults-nonzero-index.md.
  let is_done := Bool.not (Bool.not t.done) in
  String.concat_list [
    "{\"id\":", I64.to_string t.id,
    ",\"title\":", Json.to_string (Json.make_str t.title),
    ",\"done\":", (if is_done then "true" else "false"),
    "}"
  ]

def Persist.todos_to_json (todos : List Todo) : String :=
  String.concat_list ["[", List.intercalate "," (List.map Persist.todo_to_json todos), "]"]

def Persist.todo_from_json (j : Json) : Option Todo :=
  match Json.get_object j {
    ok fields => match Json.object_get "id" fields {
      Option.some id_j => match Json.get_num_i64 (Json.get_num id_j) {
        ok id => match Json.object_get "title" fields {
          Option.some title_j => match Json.get_str title_j {
            ok title => match Json.object_get "done" fields {
              Option.some done_j => match Json.get_bool done_j {
                ok done => Option.some ({ id := id, title := title, done := done } : Todo),
                err _ => Option.none,
              },
              Option.none => Option.none,
            },
            err _ => Option.none,
          },
          Option.none => Option.none,
        },
        err _ => Option.none,
      },
      Option.none => Option.none,
    },
    err _ => Option.none,
  }

def Persist.todos_from_json (text : String) : Option (List Todo) :=
  match Json.parse text {
    ok j => match Json.get_array j {
      ok items => Option.some (List.filter_map Persist.todo_from_json items),
      err _ => Option.none,
    },
    err _ => Option.none,
  }

def Persist.save (todos : List Todo) : IO Unit :=
  match Path.of Persist.file {
    ok p => write_file p (Persist.todos_to_json todos),
    err _ => return unit,
  }

def Persist.load : IO (List Todo) :=
  match Path.of Persist.file {
    err _ => return Storage.seed,
    ok p => do {
      let exists <- file_exists p;
      if exists
      then do {
        let content <- read_file p;
        match Persist.todos_from_json content {
          Option.some todos => return todos,
          Option.none => return Storage.seed,
        }
      }
      else return Storage.seed
    },
  }
