/// The shared JSON codec.
///
/// This module used to build/read the wire shape through `motes/serde`'s
/// derive macros. At the pinned Monad revision (`6a59e090`) the checker
/// exhausts memory (≈18 GB) when a test binary includes a serde-derived
/// module, so the derive path is gone: `codec_web.mo`'s hand-written encoder —
/// already the wasm-safe implementation — is the single codec, and the
/// native backend delegates to it. That also removes the old wasm-derive gap
/// and several thousand affine warnings from every build.
///
/// `Json.to_string` is still not used: its number arm reaches the web-gated
/// `F64.to_string`. `Codec.json_to_string` prints the integer-only `Json`
/// values this app produces, so the same code is valid on wasm.
use lib::codec_web {
  CodecWeb.todo_from_json, CodecWeb.todo_to_json, CodecWeb.todos_from_json,
  CodecWeb.todos_from_json_values, CodecWeb.todos_to_json
}
use lib::storage {
  Status, Storage.add_subtask, Storage.edit, Storage.seed, Storage.set_status,
  Subtask, Todo
}
use lib::user {User, UserRef}
use json::json {Json}
use lib::json_text {
  JsonText.escape_char, JsonText.escape_json_string, JsonText.group_to_json,
  JsonText.json_string, JsonText.json_to_string, JsonText.option_string_to_json,
  JsonText.status_to_json, JsonText.tags_to_json
}
use std::map {BTreeMap}
use std::list {List.filter, List.length}

// ─── Text helpers ───────────────────────────────────────────────────────
//
// The implementation lives in `json_text.mo`, which has no derive/macro
// dependency. These wrappers keep the public `Codec.*` names the backend
// and tests already use.

pub def Codec.escape_char (b : U8) : String := JsonText.escape_char b

pub def Codec.escape_json_string (s : String) : String :=
  JsonText.escape_json_string s

pub def Codec.json_string (s : String) : String := JsonText.json_string s

pub def Codec.json_to_string (j : Json) : String := JsonText.json_to_string j

pub def Codec.option_string_to_json (o : Option String) : String :=
  JsonText.option_string_to_json o

pub def Codec.group_to_json (group : Option String) : String :=
  JsonText.group_to_json group

pub def Codec.status_to_json (s : Status) : String :=
  JsonText.status_to_json s

pub def Codec.tags_to_json (tags : List String) : String :=
  JsonText.tags_to_json tags

// ─── Subtask / todo ─────────────────────────────────────────────────────

pub def Codec.subtask_to_json (s : Subtask) : String :=
  Codec.json_to_string (Json.make_object_pairs [
    Pair.pair "id" (Json.make_num_int s.id),
    Pair.pair "title" (Json.make_str s.title),
    Pair.pair "done" (Json.make_bool s.done)
  ])

pub def Codec.subtasks_to_json (subs : List Subtask) : String :=
  Codec.json_to_string
    (Json.make_array
      (List.map (fn (s : Subtask) => Json.make_object_pairs [
        Pair.pair "id" (Json.make_num_int s.id),
        Pair.pair "title" (Json.make_str s.title),
        Pair.pair "done" (Json.make_bool s.done)
      ]) subs))

pub def Codec.todo_to_json (t : Todo) : String :=
  Codec.json_to_string (CodecWeb.todo_to_json t)

pub def Codec.todos_to_json (todos : List Todo) : String :=
  CodecWeb.todos_to_json todos

pub def Codec.todos_from_json_values (items : List Json) : List Todo :=
  CodecWeb.todos_from_json_values items

pub def Codec.todo_from_json (j : Json) : Option Todo :=
  CodecWeb.todo_from_json j

pub def Codec.todos_from_json (text : String) : Option (List Todo) :=
  CodecWeb.todos_from_json text

/// `{"state":[…],"html":"…"}` — the kernel's response envelope.
pub def Codec.envelope_to_json (todos : List Todo) (html : String) : String :=
  String.concat "{\"state\":"
    (String.concat (Codec.todos_to_json todos)
      (String.concat ",\"html\":" (String.concat (Codec.json_string html) "}")))

pub def Codec.envelope_from_json (text : String)
    : Option (Pair (List Todo) String) :=
  match Json.parse text {
    ok j => match Json.get_object j {
      ok fields => match Json.object_get "state" fields {
        Option.some state => match Json.get_array state {
          ok items => match Json.object_get "html" fields {
            Option.some h => match Json.get_str h {
              ok html => Option.some
                (Pair.pair (CodecWeb.todos_from_json_values items) html),
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
    err _ => Option.none,
  }

// ─── User / attribution ─────────────────────────────────────────────────

def Codec.option_string_value (o : Option String) : Json :=
  match o {
    Option.some s => Json.make_str s,
    Option.none => Json.make_null,
  }

def Codec.user_ref_value (u : UserRef) : Json :=
  Json.make_object_pairs [
    Pair.pair "id" (Json.make_num_int u.id),
    Pair.pair "name" (Json.make_str u.name)
  ]

pub def Codec.user_ref_to_json (u : UserRef) : String :=
  Codec.json_to_string (Codec.user_ref_value u)

pub def Codec.user_ref_option_to_json (u : Option UserRef) : String :=
  match u {
    Option.some r => Codec.user_ref_to_json r,
    Option.none => "null",
  }

pub def Codec.user_ref_from_json (j : Json) : Option UserRef :=
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

pub def Codec.user_to_json (u : User) : String :=
  Codec.json_to_string (Json.make_object_pairs [
    Pair.pair "id" (Json.make_num_int u.id),
    Pair.pair "issuer" (Json.make_str u.issuer),
    Pair.pair "subject" (Json.make_str u.subject),
    Pair.pair "email" (Codec.option_string_value u.email),
    Pair.pair "name" (Json.make_str u.name),
    Pair.pair "picture" (Codec.option_string_value u.picture),
    Pair.pair "utc_offset_minutes" (Json.make_num_int u.utc_offset_minutes),
    Pair.pair "created_at" (Json.make_str u.created_at),
    Pair.pair "updated_at" (Json.make_str u.updated_at)
  ])

def Codec.string_field (name : String) (fields : BTreeMap String Json) : String :=
  match Json.object_get name fields {
    Option.some j => match Json.get_str j { ok s => s, err _ => "" },
    Option.none => "",
  }

def Codec.int_field (name : String) (fields : BTreeMap String Json) : I64 :=
  match Json.object_get name fields {
    Option.some j => match Json.get_num_i64 (Json.get_num j) { ok n => n, err _ => 0i64 },
    Option.none => 0i64,
  }

def Codec.optional_string_field (name : String) (fields : BTreeMap String Json)
    : Option String :=
  match Json.object_get name fields {
    Option.some j => match Json.get_str j { ok s => Option.some s, err _ => Option.none },
    Option.none => Option.none,
  }

/// Missing fields default exactly as the old DTO did, so a payload from an
/// older client (or the pre-offset backend) still decodes.
pub def Codec.user_from_json (j : Json) : Option User :=
  match Json.get_object j {
    ok fields => Option.some ({
      id := Codec.int_field "id" fields,
      issuer := Codec.string_field "issuer" fields,
      subject := Codec.string_field "subject" fields,
      email := Codec.optional_string_field "email" fields,
      name := Codec.string_field "name" fields,
      picture := Codec.optional_string_field "picture" fields,
      utc_offset_minutes := Codec.int_field "utc_offset_minutes" fields,
      created_at := Codec.string_field "created_at" fields,
      updated_at := Codec.string_field "updated_at" fields
    } : User),
    err _ => Option.none,
  }

// ─── Tests ──────────────────────────────────────────────────────────────

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
        && List.length t.subtasks == 0i64
        && (match t.due_at { Option.none => true, Option.some _ => false }),
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_todo_to_json_round_trips_new_fields : Bool :=
  let tags := List.cons "work" (List.cons "urgent" List.empty) in
  let with_subtask := Storage.add_subtask 1i64 "step" Storage.seed in
  let edited := Storage.edit 1i64 "edited" "notes here" (Option.some "Work") tags
    (Option.some "2026-11-01") with_subtask in
  match Codec.todos_from_json (Codec.todos_to_json edited) {
    Option.some todos => match List.first todos {
      Option.some t =>
        t.notes == "notes here" && List.length t.tags == 2i64
        && (match t.group { Option.some g => g == "Work", Option.none => false })
        && List.length t.subtasks == 1i64
        && (match t.due_at { Option.some d => d == "2026-11-01", Option.none => false }),
      Option.none => false,
    },
    Option.none => false,
  }

#[test]
def test_decode_defaults_status_from_done_when_missing : Bool :=
  match Codec.todos_from_json
      "[{\"id\":1,\"title\":\"legacy\",\"done\":true},{\"id\":2,\"title\":\"x\",\"done\":false}]" {
    Option.some todos => match List.first todos {
      Option.some done_t => match List.first (List.filter (fn (t : Todo) => t.id == 2i64) todos) {
        Option.some not_done_t =>
          Status.eq done_t.status Status.done && Status.eq not_done_t.status Status.todo,
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

#[test]
def test_envelope_round_trips_state_and_html : Bool :=
  match Codec.envelope_from_json (Codec.envelope_to_json Storage.seed "<p>x</p>") {
    Option.some pair => match pair {
      Pair.pair todos html => List.length todos == 2i64 && String.beq html "<p>x</p>",
    },
    Option.none => false,
  }

#[test]
def test_user_round_trips_through_json : Bool :=
  let u : User := {
    id := 7i64, issuer := "https://idp.example", subject := "abc",
    email := Option.some "a@example.com", name := "Ada",
    picture := Option.none, utc_offset_minutes := 120i64,
    created_at := "2026-01-01", updated_at := "2026-01-02"
  } in
  match Json.parse (Codec.user_to_json u) {
    ok j => match Codec.user_from_json j {
      Option.some u2 =>
        u2.id == 7i64 && String.beq u2.name "Ada"
        && u2.utc_offset_minutes == 120i64
        && (match u2.email { Option.some e => e == "a@example.com", Option.none => false }),
      Option.none => false,
    },
    err _ => false,
  }

/// A payload written before the offset existed (or a client that omits it)
/// decodes as UTC, not as a decode failure.
#[test]
def test_user_json_defaults_missing_offset : Bool :=
  match Json.parse
    ("{\"id\":7,\"issuer\":\"i\",\"subject\":\"s\",\"name\":\"n\"," ++
     "\"created_at\":\"\",\"updated_at\":\"\"}") {
    ok j => match Codec.user_from_json j {
      Option.some u2 => u2.utc_offset_minutes == 0i64 && String.beq u2.name "n",
      Option.none => false,
    },
    err _ => false,
  }
