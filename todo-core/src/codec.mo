/// The shared JSON codec.
///
/// Struct-shaped data (`Todo`, `Subtask`, `User`, `UserRef`, the response
/// envelope) is encoded/decoded through `motes/serde`'s derive macros:
/// `derive_json_serialize!`/`derive_json_deserialize!` generate
/// `Type.serialize_json`/`Type.deserialize_json` for single-constructor
/// structs. The multi-constructor domain types (`Status`, `Action`) keep
/// their small hand-written tagged codecs, which serde's derive explicitly
/// does not build (one match arm per constructor is unsupported there).
///
/// `Json.to_string` is not used: its number arm reaches the web-gated
/// `F64.to_string`. `Codec.json_to_string` is a small generic printer that
/// handles the integer-only `Json` values this app produces (the parser
/// only ever yields `Json.Number.int`), so the SPA's wasm build stays
/// valid. Parsing uses the web-safe `Json.parse` + derived decoders.
use lib::storage {
  Status, Storage.add_subtask, Storage.edit, Storage.seed, Storage.set_status,
  Subtask, Todo
}
use lib::user {User, UserRef}
use json::json {Json}
use json::serde_backend {derive_json_deserialize, derive_json_serialize}
use std::list {List.filter, List.filter_map, List.intercalate, List.length}
use std::map {BTreeMap, BTreeMap.to_list}

// ─── Derived wire structs ───────────────────────────────────────────────
//
// These mirror the domain types with a string `status` (an enum cannot be
// derived) and are the only types the derive macros see. The mapping to
// the domain lives below.
//
// Field defaults keep the legacy decoder's tolerance: an old
// `id`/`title`/`done`-only document still decodes with empty notes/tags,
// no group/subtasks/audit, and a status inferred from `done`.

struct SubtaskDto {
  id : I64,
  title : String,
  done : Bool
}

derive_json_serialize! SubtaskDto
derive_json_deserialize! SubtaskDto

struct UserRefDto {
  id : I64,
  name : String
}

derive_json_serialize! UserRefDto
derive_json_deserialize! UserRefDto

struct TodoDto {
  id : I64,
  title : String,
  done : Bool,
  notes : String := "",
  tags : List String := List.empty,
  group : Option String := Option.none,
  subtasks : List SubtaskDto := List.empty,
  status : String := "",
  due_at : Option String := Option.none,
  created_at : Option String := Option.none,
  updated_at : Option String := Option.none,
  created_by : Option UserRefDto := Option.none,
  updated_by : Option UserRefDto := Option.none
}

derive_json_serialize! TodoDto
derive_json_deserialize! TodoDto

struct UserDto {
  id : I64,
  issuer : String := "",
  subject : String := "",
  email : Option String := Option.none,
  name : String := "",
  picture : Option String := Option.none,
  timezone : String := "UTC",
  created_at : String := "",
  updated_at : String := ""
}

derive_json_serialize! UserDto
derive_json_deserialize! UserDto

struct EnvelopeDto {
  state : List TodoDto,
  html : String
}

derive_json_serialize! EnvelopeDto
derive_json_deserialize! EnvelopeDto

// ─── Domain <-> wire mapping ────────────────────────────────────────────

def Codec.subtask_to_dto (s : Subtask) : SubtaskDto :=
  let d : SubtaskDto := { id := s.id, title := s.title, done := s.done } in d

def Codec.subtask_from_dto (d : SubtaskDto) : Subtask :=
  let s : Subtask := { id := d.id, title := d.title, done := d.done } in s

def Codec.user_ref_to_dto (u : UserRef) : UserRefDto :=
  let d : UserRefDto := { id := u.id, name := u.name } in d

def Codec.user_ref_from_dto (d : UserRefDto) : UserRef :=
  let u : UserRef := { id := d.id, name := d.name } in u

def Codec.option_user_ref_to_dto (u : Option UserRef) : Option UserRefDto :=
  match u {
    Option.some r => Option.some (Codec.user_ref_to_dto r),
    Option.none => Option.none,
  }

def Codec.option_user_ref_from_dto (d : Option UserRefDto) : Option UserRef :=
  match d {
    Option.some r => Option.some (Codec.user_ref_from_dto r),
    Option.none => Option.none,
  }

def Codec.todo_to_dto (t : Todo) : TodoDto :=
  let d : TodoDto := {
    id := t.id, title := t.title, done := t.done, notes := t.notes,
    tags := t.tags, group := t.group,
    subtasks := List.map Codec.subtask_to_dto t.subtasks,
    status := Status.to_string t.status, due_at := t.due_at,
    created_at := t.created_at, updated_at := t.updated_at,
    created_by := Codec.option_user_ref_to_dto t.created_by,
    updated_by := Codec.option_user_ref_to_dto t.updated_by
  } in d

def Codec.todo_from_dto (d : TodoDto) : Todo :=
  let status : Status :=
    match Status.from_string d.status {
      Option.some s => s,
      Option.none => if d.done then Status.done else Status.todo,
    } in
  let t : Todo := {
    id := d.id, title := d.title, done := d.done, notes := d.notes,
    tags := d.tags, group := d.group,
    subtasks := List.map Codec.subtask_from_dto d.subtasks,
    status := status, due_at := d.due_at,
    created_at := d.created_at, updated_at := d.updated_at,
    created_by := Codec.option_user_ref_from_dto d.created_by,
    updated_by := Codec.option_user_ref_from_dto d.updated_by
  } in t

def Codec.user_to_dto (u : User) : UserDto :=
  let d : UserDto := {
    id := u.id, issuer := u.issuer, subject := u.subject, email := u.email,
    name := u.name, picture := u.picture, timezone := u.timezone,
    created_at := u.created_at, updated_at := u.updated_at
  } in d

def Codec.user_from_dto (d : UserDto) : User :=
  let u : User := {
    id := d.id, issuer := d.issuer, subject := d.subject, email := d.email,
    name := d.name, picture := d.picture, timezone := d.timezone,
    created_at := d.created_at, updated_at := d.updated_at
  } in u

// ─── Generic Json printer (web-safe) ────────────────────────────────────

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

def Codec.json_pair_to_string (p : Pair String Json) : String :=
  match p {
    Pair.pair k v =>
      String.concat (Codec.json_string k)
        (String.concat ":" (Codec.json_to_string v))
  }

/// A web-safe `Json -> String` printer. The parser only produces
/// `Json.Number.int`; a manually constructed float is rendered as `null`
/// rather than reaching the web-gated `F64.to_string`.
pub def Codec.json_to_string (j : Json) : String :=
  match j {
    Json.null => "null",
    Json.bool b => if b then "true" else "false",
    Json.num n => match n {
      Json.Number.int i => I64.to_string i,
      Json.Number.float _ => "null",
    },
    Json.str s => Codec.json_string s,
    Json.array xs =>
      String.concat "["
        (String.concat (List.intercalate "," (List.map Codec.json_to_string xs)) "]"),
    Json.object o =>
      String.concat "{"
        (String.concat
          (List.intercalate "," (List.map Codec.json_pair_to_string (BTreeMap.to_list o)))
          "}"),
  }

// ─── Optional / small value encoders ────────────────────────────────────

pub def Codec.option_string_to_json (o : Option String) : String :=
  match o {
    Option.some s => Codec.json_string s,
    Option.none => "null",
  }

pub def Codec.group_to_json (group : Option String) : String :=
  Codec.option_string_to_json group

pub def Codec.status_to_json (s : Status) : String :=
  Codec.json_string (Status.to_string s)

pub def Codec.tags_to_json (tags : List String) : String :=
  Codec.json_to_string
    (Json.make_array (List.map (fn (t : String) => Json.make_str t) tags))

// ─── Subtask / todo / envelope ──────────────────────────────────────────

pub def Codec.subtask_to_json (s : Subtask) : String :=
  Codec.json_to_string (SubtaskDto.serialize_json (Codec.subtask_to_dto s))

pub def Codec.subtasks_to_json (subs : List Subtask) : String :=
  Codec.json_to_string
    (Json.make_array
      (List.map (fn (s : Subtask) => SubtaskDto.serialize_json (Codec.subtask_to_dto s)) subs))

pub def Codec.todo_to_json (t : Todo) : String :=
  Codec.json_to_string (TodoDto.serialize_json (Codec.todo_to_dto t))

pub def Codec.todos_to_json (todos : List Todo) : String :=
  Codec.json_to_string
    (Json.make_array
      (List.map (fn (t : Todo) => TodoDto.serialize_json (Codec.todo_to_dto t)) todos))

pub def Codec.todos_from_json_values (items : List Json) : List Todo :=
  List.filter_map
    (fn (item : Json) =>
      match TodoDto.deserialize_json item {
        Result.ok dto => Option.some (Codec.todo_from_dto dto),
        Result.err _ => Option.none,
      })
    items

pub def Codec.todo_from_json (j : Json) : Option Todo :=
  match TodoDto.deserialize_json j {
    Result.ok dto => Option.some (Codec.todo_from_dto dto),
    Result.err _ => Option.none,
  }

pub def Codec.todos_from_json (text : String) : Option (List Todo) :=
  match Json.parse text {
    ok j => match Json.get_array j {
      ok items => Option.some (Codec.todos_from_json_values items),
      err _ => Option.none,
    },
    err _ => Option.none,
  }

pub def Codec.envelope_to_json (todos : List Todo) (html : String) : String :=
  let dto : EnvelopeDto := {
    state := List.map Codec.todo_to_dto todos,
    html := html
  } in
  Codec.json_to_string (EnvelopeDto.serialize_json dto)

// ─── User / attribution ─────────────────────────────────────────────────

pub def Codec.user_ref_to_json (u : UserRef) : String :=
  Codec.json_to_string (UserRefDto.serialize_json (Codec.user_ref_to_dto u))

pub def Codec.user_ref_option_to_json (u : Option UserRef) : String :=
  match u {
    Option.some r => Codec.user_ref_to_json r,
    Option.none => "null",
  }

pub def Codec.user_ref_from_json (j : Json) : Option UserRef :=
  match UserRefDto.deserialize_json j {
    Result.ok dto => Option.some (Codec.user_ref_from_dto dto),
    Result.err _ => Option.none,
  }

pub def Codec.user_to_json (u : User) : String :=
  Codec.json_to_string (UserDto.serialize_json (Codec.user_to_dto u))

pub def Codec.user_from_json (j : Json) : Option User :=
  match UserDto.deserialize_json j {
    Result.ok dto => Option.some (Codec.user_from_dto dto),
    Result.err _ => Option.none,
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
def test_user_round_trips_through_json : Bool :=
  let u : User := {
    id := 7i64, issuer := "https://idp.example", subject := "abc",
    email := Option.some "a@example.com", name := "Ada",
    picture := Option.none, timezone := "Europe/Oslo",
    created_at := "2026-01-01", updated_at := "2026-01-02"
  } in
  match Json.parse (Codec.user_to_json u) {
    ok j => match Codec.user_from_json j {
      Option.some u2 =>
        u2.id == 7i64 && String.beq u2.name "Ada"
        && String.beq u2.timezone "Europe/Oslo"
        && (match u2.email { Option.some e => e == "a@example.com", Option.none => false }),
      Option.none => false,
    },
    err _ => false,
  }
