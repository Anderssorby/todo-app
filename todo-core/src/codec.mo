/// The JSON codec shared by the backend (file + API) and the wasm kernel.
///
/// Encoding is hand-written, not `Json.to_string`: that serializer's
/// number arm reaches `F64.to_string`, which is gated off on the
/// `wasm32-unknown-unknown` profile, so a reachable `Json.to_string`
/// fails the web build even for integer/string documents. Filed as the
/// `json-to-string-web-gate` plan.
///
/// Decoding uses the `json` mote's `Json.parse` + accessors (the parse
/// side is web-safe; it only ever produces integer numbers).
use lib::storage {Status, Storage.add_subtask, Storage.edit, Storage.seed, Storage.set_status, Subtask, Todo}
use json::json {Json}
use std::list {List.filter, List.filter_map, List.intercalate, List.length}
use std::map {BTreeMap}

/// One hex digit (0-15) as a character.
def Codec.hex_digit_char (n : U8) : U8 :=
  if U8.lt n 10u8 then U8.add n 48u8 else U8.add n 87u8

/// A raw control byte as `\u00XX`. JSON forbids unescaped characters below
/// 0x20, so a control byte in a title/notes (or a crafted request body)
/// would otherwise produce a file and API responses that standards-
/// compliant parsers reject.
def Codec.control_escape (b : U8) : String :=
  let hi : U8 := U8.div b 16u8 in
  let lo : U8 := U8.sub b (U8.mul hi 16u8) in
  String.concat "\\u00" (String.from_list [Codec.hex_digit_char hi, Codec.hex_digit_char lo])

/// Escape one byte for a JSON string literal. Walking bytes (through
/// `String.to_list`) keeps multi-byte UTF-8 intact without needing
/// `parsec`'s width probe.
pub def Codec.escape_char (b : U8) : String :=
  if U8.beq b 34u8 then "\\\""
  else if U8.beq b 92u8 then "\\\\"
  else if U8.beq b 8u8 then "\\b"
  else if U8.beq b 12u8 then "\\f"
  else if U8.beq b 10u8 then "\\n"
  else if U8.beq b 13u8 then "\\r"
  else if U8.beq b 9u8 then "\\t"
  else if U8.lt b 32u8 then Codec.control_escape b
  else String.from_list (List.cons b List.empty)

pub def Codec.escape_json_string (s : String) : String :=
  String.concat_list (List.map Codec.escape_char (String.to_list s))

pub def Codec.json_string (s : String) : String :=
  String.concat "\"" (String.concat (Codec.escape_json_string s) "\"")

pub def Codec.subtask_to_json (s : Subtask) : String :=
  String.concat_list [
    "{\"id\":", I64.to_string s.id,
    ",\"title\":", Codec.json_string s.title,
    ",\"done\":", (if s.done then "true" else "false"),
    "}"
  ]

pub def Codec.subtasks_to_json (subs : List Subtask) : String :=
  String.concat_list ["[", List.intercalate "," (List.map Codec.subtask_to_json subs), "]"]

pub def Codec.tags_to_json (tags : List String) : String :=
  String.concat_list ["[", List.intercalate "," (List.map Codec.json_string tags), "]"]

pub def Codec.group_to_json (group : Option String) : String :=
  match group {
    Option.some g => Codec.json_string g,
    Option.none => "null",
  }

pub def Codec.status_to_json (s : Status) : String := Codec.json_string (Status.to_string s)

pub def Codec.todo_to_json (t : Todo) : String :=
  String.concat_list [
    "{\"id\":", I64.to_string t.id,
    ",\"title\":", Codec.json_string t.title,
    ",\"done\":", (if t.done then "true" else "false"),
    ",\"notes\":", Codec.json_string t.notes,
    ",\"tags\":", Codec.tags_to_json t.tags,
    ",\"group\":", Codec.group_to_json t.group,
    ",\"subtasks\":", Codec.subtasks_to_json t.subtasks,
    ",\"status\":", Codec.status_to_json t.status,
    "}"
  ]

pub def Codec.todos_to_json (todos : List Todo) : String :=
  String.concat_list ["[", List.intercalate "," (List.map Codec.todo_to_json todos), "]"]

/// The wasm kernel's one-line reply: the new state plus the rendered
/// `#app` fragment, with the HTML JSON-escaped.
pub def Codec.envelope_to_json (todos : List Todo) (html : String) : String :=
  String.concat_list [
    "{\"state\":", Codec.todos_to_json todos,
    ",\"html\":", Codec.json_string html,
    "}"
  ]

def Codec.subtask_from_json (j : Json) : Option Subtask :=
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

/// Each of these defaults on a *missing* key, not just a malformed one --
/// this is what lets the pre-existing `id`/`title`/`done`-only `todos.json`
/// decode cleanly with no migration step.
def Codec.notes_from_fields (fields : BTreeMap String Json) : String :=
  match Json.object_get "notes" fields {
    Option.some j => match Json.get_str j { ok s => s, err _ => "" },
    Option.none => "",
  }

def Codec.tags_from_fields (fields : BTreeMap String Json) : List String :=
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

def Codec.group_from_fields (fields : BTreeMap String Json) : Option String :=
  match Json.object_get "group" fields {
    Option.some j => match Json.get_str j { ok s => Option.some s, err _ => Option.none },
    Option.none => Option.none,
  }

def Codec.subtasks_from_fields (fields : BTreeMap String Json) : List Subtask :=
  match Json.object_get "subtasks" fields {
    Option.some j => match Json.get_array j {
      ok items => List.filter_map Codec.subtask_from_json items,
      err _ => List.empty,
    },
    Option.none => List.empty,
  }

/// A missing (or unrecognized) `status` key defaults from the pre-existing
/// `done` field rather than failing -- this is what lets every `todos.json`
/// written before the kanban board existed (including ones without `done`
/// itself defaulted elsewhere) keep decoding with no migration step.
def Codec.status_from_fields (fields : BTreeMap String Json) (done : Bool) : Status :=
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

pub def Codec.todo_from_json (j : Json) : Option Todo :=
  match Json.get_object j {
    ok fields => match Json.object_get "id" fields {
      Option.some id_j => match Json.get_num_i64 (Json.get_num id_j) {
        ok id => match Json.object_get "title" fields {
          Option.some title_j => match Json.get_str title_j {
            ok title => match Json.object_get "done" fields {
              Option.some done_j => match Json.get_bool done_j {
                ok done => Option.some ({
                  id := id, title := title, done := done,
                  notes := Codec.notes_from_fields fields,
                  tags := Codec.tags_from_fields fields,
                  group := Codec.group_from_fields fields,
                  subtasks := Codec.subtasks_from_fields fields,
                  status := Codec.status_from_fields fields done
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

pub def Codec.todos_from_json_values (items : List Json) : List Todo :=
  List.filter_map Codec.todo_from_json items

pub def Codec.todos_from_json (text : String) : Option (List Todo) :=
  match Json.parse text {
    ok j => match Json.get_array j {
      ok items => Option.some (Codec.todos_from_json_values items),
      err _ => Option.none,
    },
    err _ => Option.none,
  }

#[test]
def test_escape_quotes_and_backslash : Bool :=
  String.beq (Codec.json_string "a\"b\\c") "\"a\\\"b\\\\c\""

#[test]
def test_escape_control_bytes : Bool :=
  String.beq (Codec.escape_json_string (String.from_list [97u8, 1u8, 27u8, 98u8]))
    "a\\u0001\\u001bb"

#[test]
def test_utf8_titles_round_trip : Bool :=
  match Codec.todos_from_json (Codec.todos_to_json Storage.seed) {
    Option.some todos => match List.first todos {
      Option.some t => String.beq t.title "Learn Monad" && List.length todos == 2i64,
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_decode_defaults_missing_new_fields_from_legacy_json : Bool :=
  match Codec.todos_from_json "[{\"id\":1,\"title\":\"legacy\",\"done\":false}]" {
    Option.some todos => match List.first todos {
      Option.some t =>
        t.notes == "" && List.length t.tags == 0i64
        && (match t.group { Option.none => true, Option.some _ => false })
        && List.length t.subtasks == 0i64,
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_todo_to_json_round_trips_new_fields : Bool :=
  let tags := List.cons "work" (List.cons "urgent" List.empty) in
  let with_subtask := Storage.add_subtask 1i64 "step" Storage.seed in
  let edited := Storage.edit 1i64 "edited" "notes here" (Option.some "Work") tags with_subtask in
  match Codec.todos_from_json (Codec.todos_to_json edited) {
    Option.some todos => match List.first todos {
      Option.some t =>
        t.notes == "notes here" && List.length t.tags == 2i64
        && (match t.group { Option.some g => g == "Work", Option.none => false })
        && List.length t.subtasks == 1i64,
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_decode_defaults_status_from_done_when_missing : Bool :=
  match Codec.todos_from_json "[{\"id\":1,\"title\":\"legacy\",\"done\":true},{\"id\":2,\"title\":\"x\",\"done\":false}]" {
    Option.some todos => match List.first todos {
      Option.some done_t => match List.first (List.filter (fn (t : Todo) => t.id == 2i64) todos) {
        Option.some not_done_t => Status.eq done_t.status Status.done && Status.eq not_done_t.status Status.todo,
        Option.none => false,
      },
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_status_round_trips_through_json : Bool :=
  let moved := Storage.set_status 1i64 Status.doing Storage.seed in
  match Codec.todos_from_json (Codec.todos_to_json moved) {
    Option.some todos => match List.first todos {
      Option.some t => Status.eq t.status Status.doing,
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_envelope_round_trips_html : Bool :=
  match Json.parse (Codec.envelope_to_json Storage.seed "<b>\"x\"</b>") {
    ok j => match Json.get_object j {
      ok fields => match Json.object_get "html" fields {
        Option.some h => match Json.get_str h {
          ok s => String.beq s "<b>\"x\"</b>",
          err _ => false,
        },
        Option.none => false,
      },
      err _ => false,
    },
    err _ => false,
  }
