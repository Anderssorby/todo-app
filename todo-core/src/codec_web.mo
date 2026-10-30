/// The hand-written Todo JSON codec, shared by the wasm SPA and the native
/// backend.
///
/// It builds/reads the wire shape with `Json.make_*`/`Json.parse` and prints
/// through `JsonText`, so it never reaches the web-gated `Json.to_string`.
/// This used to be only the wasm fallback while `codec.mo` used serde's
/// derive macros; the derives were removed after the pinned checker started
/// exhausting memory on any test binary that included a derived module, so
/// this is now the single implementation (`codec.mo` wraps it).
use lib::storage {Status, Subtask, Todo}
use lib::user {UserRef}
use lib::json_text {JsonText.json_to_string}
use json::json {Json}
use std::list {List.filter_map}
use std::map {BTreeMap}

// ─── Encoding ───────────────────────────────────────────────────────────

def CodecWeb.json_option_string (o : Option String) : Json :=
  match o {
    Option.some s => Json.make_str s,
    Option.none => Json.make_null,
  }

def CodecWeb.subtask_to_json (s : Subtask) : Json :=
  Json.make_object_pairs [
    Pair.pair "id" (Json.make_num_int s.id),
    Pair.pair "title" (Json.make_str s.title),
    Pair.pair "done" (Json.make_bool s.done)
  ]

def CodecWeb.option_user_ref_to_json (o : Option UserRef) : Json :=
  match o {
    Option.some r =>
      Json.make_object_pairs [
        Pair.pair "id" (Json.make_num_int r.id),
        Pair.pair "name" (Json.make_str r.name)
      ],
    Option.none => Json.make_null,
  }

pub def CodecWeb.todo_to_json (t : Todo) : Json :=
  Json.make_object_pairs [
    Pair.pair "id" (Json.make_num_int t.id),
    Pair.pair "title" (Json.make_str t.title),
    Pair.pair "done" (Json.make_bool t.done),
    Pair.pair "notes" (Json.make_str t.notes),
    Pair.pair "tags"
      (Json.make_array (List.map (fn (tag : String) => Json.make_str tag) t.tags)),
    Pair.pair "group" (CodecWeb.json_option_string t.group),
    Pair.pair "subtasks"
      (Json.make_array (List.map CodecWeb.subtask_to_json t.subtasks)),
    Pair.pair "status" (Json.make_str (Status.to_string t.status)),
    Pair.pair "due_at" (CodecWeb.json_option_string t.due_at),
    Pair.pair "created_at" (CodecWeb.json_option_string t.created_at),
    Pair.pair "updated_at" (CodecWeb.json_option_string t.updated_at),
    Pair.pair "created_by" (CodecWeb.option_user_ref_to_json t.created_by),
    Pair.pair "updated_by" (CodecWeb.option_user_ref_to_json t.updated_by)
  ]

pub def CodecWeb.todos_to_json (todos : List Todo) : String :=
  JsonText.json_to_string
    (Json.make_array (List.map CodecWeb.todo_to_json todos))

// ─── Decoding ───────────────────────────────────────────────────────────

def CodecWeb.option_string_from_fields (name : String) (fields : BTreeMap String Json)
    : Option String :=
  match Json.object_get name fields {
    Option.some j => match Json.get_str j { ok s => Option.some s, err _ => Option.none },
    Option.none => Option.none,
  }

def CodecWeb.user_ref_from_json (j : Json) : Option UserRef :=
  match Json.get_object j {
    ok fields => match Json.object_get "id" fields {
      Option.some id_j => match Json.get_num_i64 (Json.get_num id_j) {
        ok id => match Json.object_get "name" fields {
          Option.some name_j => match Json.get_str name_j {
            ok name => Option.some ({ id := id, name := name } : UserRef),
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

def CodecWeb.user_ref_from_fields (name : String) (fields : BTreeMap String Json)
    : Option UserRef :=
  match Json.object_get name fields {
    Option.some j => CodecWeb.user_ref_from_json j,
    Option.none => Option.none,
  }

def CodecWeb.subtask_from_json (j : Json) : Option Subtask :=
  match Json.get_object j {
    ok fields => match Json.object_get "id" fields {
      Option.some id_j => match Json.get_num_i64 (Json.get_num id_j) {
        ok id => match Json.object_get "title" fields {
          Option.some title_j => match Json.get_str title_j {
            ok title => match Json.object_get "done" fields {
              Option.some done_j => match Json.get_bool done_j {
                ok done => Option.some ({ id := id, title := title, done := done } : Subtask),
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

def CodecWeb.notes_from_fields (fields : BTreeMap String Json) : String :=
  match Json.object_get "notes" fields {
    Option.some j => match Json.get_str j { ok s => s, err _ => "" },
    Option.none => "",
  }

def CodecWeb.tags_from_fields (fields : BTreeMap String Json) : List String :=
  match Json.object_get "tags" fields {
    Option.some j => match Json.get_array j {
      ok items => List.filter_map (fn (item : Json) => match Json.get_str item {
        ok s => Option.some s,
        err _ => Option.none,
      }) items,
      err _ => List.empty,
    },
    Option.none => List.empty,
  }

def CodecWeb.group_from_fields (fields : BTreeMap String Json) : Option String :=
  match Json.object_get "group" fields {
    Option.some j => match Json.get_str j { ok s => Option.some s, err _ => Option.none },
    Option.none => Option.none,
  }

def CodecWeb.subtasks_from_fields (fields : BTreeMap String Json) : List Subtask :=
  match Json.object_get "subtasks" fields {
    Option.some j => match Json.get_array j {
      ok items => List.filter_map CodecWeb.subtask_from_json items,
      err _ => List.empty,
    },
    Option.none => List.empty,
  }

def CodecWeb.status_from_fields (fields : BTreeMap String Json) (done : Bool) : Status :=
  match Json.object_get "status" fields {
    Option.some j => match Json.get_str j {
      ok s => match Status.from_string s {
        Option.some status => status,
        Option.none => if done then Status.done else Status.todo,
      },
      err _ => if done then Status.done else Status.todo,
    },
    Option.none => if done then Status.done else Status.todo,
  }

pub def CodecWeb.todo_from_json (j : Json) : Option Todo :=
  match Json.get_object j {
    ok fields => match Json.object_get "id" fields {
      Option.some id_j => match Json.get_num_i64 (Json.get_num id_j) {
        ok id => match Json.object_get "title" fields {
          Option.some title_j => match Json.get_str title_j {
            ok title => match Json.object_get "done" fields {
              Option.some done_j => match Json.get_bool done_j {
                ok done => Option.some ({
                  id := id, title := title, done := done,
                  notes := CodecWeb.notes_from_fields fields,
                  tags := CodecWeb.tags_from_fields fields,
                  group := CodecWeb.group_from_fields fields,
                  subtasks := CodecWeb.subtasks_from_fields fields,
                  status := CodecWeb.status_from_fields fields done,
                  due_at := CodecWeb.option_string_from_fields "due_at" fields,
                  created_at := CodecWeb.option_string_from_fields "created_at" fields,
                  updated_at := CodecWeb.option_string_from_fields "updated_at" fields,
                  created_by := CodecWeb.user_ref_from_fields "created_by" fields,
                  updated_by := CodecWeb.user_ref_from_fields "updated_by" fields
                } : Todo),
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

pub def CodecWeb.todos_from_json_values (items : List Json) : List Todo :=
  List.filter_map CodecWeb.todo_from_json items

pub def CodecWeb.todos_from_json (text : String) : Option (List Todo) :=
  match Json.parse text {
    ok j => match Json.get_array j {
      ok items => Option.some (CodecWeb.todos_from_json_values items),
      err _ => Option.none,
    },
    err _ => Option.none,
  }

/// The display offset from a `/api/me` envelope (`{"csrf":…,"user":{…}}`).
/// A missing `utc_offset_minutes` (an older server) means UTC.
pub def CodecWeb.me_offset_from_json (text : String) : Option I64 :=
  match Json.parse text {
    ok j => match Json.get_object j {
      ok envelope => match Json.object_get "user" envelope {
        Option.some user_j => match Json.get_object user_j {
          ok fields => match Json.object_get "utc_offset_minutes" fields {
            Option.none => Option.some 0i64,
            Option.some n_j =>
              match Json.get_num_i64 (Json.get_num n_j) {
                ok n => Option.some n,
                err _ => Option.none,
              },
          },
          err _ => Option.none,
        },
        Option.none => Option.none,
      },
      err _ => Option.none,
    },
    err _ => Option.none,
  }

#[test]
def test_codec_web_round_trips_due_and_audit : Bool :=
  let todos := List.cons ({ id := 1i64, title := "x", done := false,
    notes := "n", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.todo, due_at := Option.some "2026-11-01",
    created_at := Option.some "2026-01-01", updated_at := Option.some "2026-01-02",
    created_by := Option.none, updated_by := Option.none } : Todo) List.empty in
  match CodecWeb.todos_from_json (CodecWeb.todos_to_json todos) {
    Option.some back => match List.first back {
      Option.some t =>
        t.title == "x"
        && (match t.due_at { Option.some d => d == "2026-11-01", Option.none => false }),
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_me_offset_defaults_to_utc : Bool :=
  let with_offset := "{\"csrf\":\"c\",\"user\":{\"id\":1,\"utc_offset_minutes\":120}}"
  in
  let without := "{\"csrf\":\"c\",\"user\":{\"id\":1}}" in
  (match CodecWeb.me_offset_from_json with_offset {
    Option.some n => n == 120i64,
    Option.none => false,
  })
  && (match CodecWeb.me_offset_from_json without {
    Option.some n => n == 0i64,
    Option.none => false,
  })
  && (match CodecWeb.me_offset_from_json "not json" {
    Option.some _ => false,
    Option.none => true,
  })
