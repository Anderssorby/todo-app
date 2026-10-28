/// A user action, shared by the native handlers, the JSON API, and the
/// wasm kernel so all three apply exactly the same update.
use lib::storage {
  Status, Storage.add, Storage.add_subtask, Storage.clear_completed, Storage.delete,
  Storage.delete_subtask, Storage.edit, Storage.seed, Storage.set_status, Storage.toggle,
  Storage.toggle_subtask, Todo
}
use json::json {Json}
use lib::codec {
  Codec.group_to_json, Codec.json_string, Codec.status_to_json, Codec.tags_to_json
}
use std::map {BTreeMap}
use std::list {List.filter, List.filter_map, List.length}
use std::parse {Parse.i64}

pub type Action {
  add (title : String),
  toggle (id : I64),
  delete (id : I64),
  edit (id : I64) (title : String) (notes : String) (group : Option String) (tags : List String),
  add_subtask (id : I64) (title : String),
  toggle_subtask (id : I64),
  delete_subtask (id : I64),
  clear_completed,
  /// The kanban move buttons.
  set_status (id : I64) (status : Status),
  /// Apply nothing and re-render; the browser shell's initial paint.
  render
}

pub def Action.apply (a : Action) (todos : List Todo) : List Todo :=
  match a {
    add title => Storage.add title todos,
    toggle id => Storage.toggle id todos,
    delete id => Storage.delete id todos,
    edit id title notes group tags => Storage.edit id title notes group tags todos,
    add_subtask id title => Storage.add_subtask id title todos,
    toggle_subtask id => Storage.toggle_subtask id todos,
    delete_subtask id => Storage.delete_subtask id todos,
    clear_completed => Storage.clear_completed todos,
    set_status id status => Storage.set_status id status todos,
    render => todos,
  }

def Action.id_from (fields : BTreeMap String Json) : Option I64 :=
  match Json.object_get "id" fields {
    Option.some id_j => match Json.get_num_i64 (Json.get_num id_j) {
      ok id => Option.some id,
      err _ => Option.none,
    },
    Option.none => Option.none,
  }

def Action.string_field (name : String) (fields : BTreeMap String Json) : String :=
  match Json.object_get name fields {
    Option.some j => match Json.get_str j { ok s => s, err _ => "" },
    Option.none => "",
  }

def Action.tags_from (fields : BTreeMap String Json) : List String :=
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

def Action.group_from (fields : BTreeMap String Json) : Option String :=
  match Json.object_get "group" fields {
    Option.some j => match Json.get_str j { ok s => Option.some s, err _ => Option.none },
    Option.none => Option.none,
  }

def Action.from_kind (kind : String) (fields : BTreeMap String Json) : Option Action :=
  if String.beq kind "add" then
    match Json.object_get "title" fields {
      Option.some title_j => match Json.get_str title_j {
        ok title => Option.some (Action.add title),
        err _ => Option.none,
      },
      Option.none => Option.none,
    }
  else if String.beq kind "toggle" then
    match Action.id_from fields {
      Option.some id => Option.some (Action.toggle id),
      Option.none => Option.none,
    }
  else if String.beq kind "delete" then
    match Action.id_from fields {
      Option.some id => Option.some (Action.delete id),
      Option.none => Option.none,
    }
  else if String.beq kind "edit" then
    match Action.id_from fields {
      Option.some id => Option.some (Action.edit id
        (Action.string_field "title" fields) (Action.string_field "notes" fields)
        (Action.group_from fields) (Action.tags_from fields)),
      Option.none => Option.none,
    }
  else if String.beq kind "add_subtask" then
    match Action.id_from fields {
      Option.some id => match Json.object_get "title" fields {
        Option.some title_j => match Json.get_str title_j {
          ok title => Option.some (Action.add_subtask id title),
          err _ => Option.none,
        },
        Option.none => Option.none,
      },
      Option.none => Option.none,
    }
  else if String.beq kind "toggle_subtask" then
    match Action.id_from fields {
      Option.some id => Option.some (Action.toggle_subtask id),
      Option.none => Option.none,
    }
  else if String.beq kind "delete_subtask" then
    match Action.id_from fields {
      Option.some id => Option.some (Action.delete_subtask id),
      Option.none => Option.none,
    }
  else if String.beq kind "set_status" then
    match Action.id_from fields {
      Option.some id => match Json.object_get "status" fields {
        Option.some status_j => match Json.get_str status_j {
          ok status_str => match Status.from_string status_str {
            Option.some status => Option.some (Action.set_status id status),
            Option.none => Option.none,
          },
          err _ => Option.none,
        },
        Option.none => Option.none,
      },
      Option.none => Option.none,
    }
  else if String.beq kind "clear_completed" then Option.some Action.clear_completed
  else if String.beq kind "render" then Option.some Action.render
  else Option.none

pub def Action.from_json (j : Json) : Option Action :=
  match Json.get_object j {
    ok fields => match Json.object_get "type" fields {
      Option.some type_j => match Json.get_str type_j {
        ok kind => Action.from_kind kind fields,
        err _ => Option.none,
      },
      Option.none => Option.none,
    },
    err _ => Option.none,
  }

// ═══ Encoding (the wasm SPA's action POST) ═══════════════════════════════
//
// `Action.from_json` is the shared decoder; the browser SPA needs the exact
// inverse so it can post any action to `POST /api/actions` instead of
// encoding each parameter in a route path.

pub def Action.to_json (a : Action) : String :=
  match a {
    add title => String.concat_list [
      "{\"type\":\"add\",\"title\":", Codec.json_string title, "}"
    ],
    toggle id => String.concat_list [
      "{\"type\":\"toggle\",\"id\":", I64.to_string id, "}"
    ],
    delete id => String.concat_list [
      "{\"type\":\"delete\",\"id\":", I64.to_string id, "}"
    ],
    edit id title notes group tags => String.concat_list [
      "{\"type\":\"edit\",\"id\":", I64.to_string id,
      ",\"title\":", Codec.json_string title,
      ",\"notes\":", Codec.json_string notes,
      ",\"group\":", Codec.group_to_json group,
      ",\"tags\":", Codec.tags_to_json tags,
      "}"
    ],
    add_subtask id title => String.concat_list [
      "{\"type\":\"add_subtask\",\"id\":", I64.to_string id,
      ",\"title\":", Codec.json_string title, "}"
    ],
    toggle_subtask id => String.concat_list [
      "{\"type\":\"toggle_subtask\",\"id\":", I64.to_string id, "}"
    ],
    delete_subtask id => String.concat_list [
      "{\"type\":\"delete_subtask\",\"id\":", I64.to_string id, "}"
    ],
    clear_completed => "{\"type\":\"clear_completed\"}",
    set_status id status => String.concat_list [
      "{\"type\":\"set_status\",\"id\":", I64.to_string id,
      ",\"status\":", Codec.status_to_json status, "}"
    ],
    render => "{\"type\":\"render\"}",
  }

// ═══ Text parsing for the SPA's forms and drag payload ═════════════════
//
// Both live here because `todo-core` is the wasm-portable layer: the
// backend's `http::strings`/`Form.parse_tags` are native-only, and the SPA
// cannot depend on `http`.

/// A todo id as carried by the kanban drag payload (`text/plain`).
///
/// `Parse.i64` rejects overflow instead of wrapping (I64 arithmetic wraps
/// silently), so dragging arbitrary text such as "18446744073709551617"
/// cannot alias an existing id. Ids are non-negative, so a sign is
/// rejected too.
pub def Action.parse_id (raw : String) : Option I64 :=
  match Parse.i64 (String.trim raw) {
    Option.some n => if I64.lt n 0i64 then Option.none else Option.some n,
    Option.none => Option.none,
  }

#[terminating]
def Action.split_commas_go (input : List U8) (acc : List U8) (out : List String) : List String :=
  match input {
    List.empty =>
      List.reverse (List.cons (String.from_list (List.reverse acc)) out),
    List.cons b rest =>
      if U8.beq b 44u8
      then Action.split_commas_go rest List.empty
        (List.cons (String.from_list (List.reverse acc)) out)
      else Action.split_commas_go rest (List.cons b acc) out,
  }

/// A comma-separated tags field: split, trim each, drop blanks (the same
/// contract as the backend's `Form.parse_tags`, so both entry points agree).
pub def Action.tags_of_text (raw : String) : List String :=
  let parts := Action.split_commas_go (String.to_list raw) List.empty List.empty in
  List.filter (fn (s : String) => Bool.not (String.beq s "")) (List.map String.trim parts)

/// A free-text group field: blank means "no group".
pub def Action.group_of_text (raw : String) : Option String :=
  let trimmed := String.trim raw in
  if String.beq trimmed "" then Option.none else Option.some trimmed

#[test]
def test_add_action_appends : Bool :=
  match Action.from_json (Json.make_object_pairs [
    Pair.pair "type" (Json.make_str "add"),
    Pair.pair "title" (Json.make_str "from json")
  ]) {
    Option.some a =>
      let todos := Action.apply a Storage.seed in
      match List.last todos {
        Option.some t => t.title == "from json",
        Option.none => false
      },
    Option.none => false
  }

#[test]
def test_toggle_action_needs_numeric_id : Bool :=
  match Action.from_json (Json.make_object_pairs [
    Pair.pair "type" (Json.make_str "toggle"),
    Pair.pair "id" (Json.make_str "1")
  ]) {
    Option.some _ => false,
    Option.none => true
  }

#[test]
def test_render_leaves_state_unchanged : Bool :=
  match Action.from_json (Json.make_object_pairs [
    Pair.pair "type" (Json.make_str "render")
  ]) {
    Option.some a => List.length (Action.apply a Storage.seed) == List.length Storage.seed,
    Option.none => false
  }

#[test]
def test_edit_action_from_json_round_trips_all_fields : Bool :=
  match Action.from_json (Json.make_object_pairs [
    Pair.pair "type" (Json.make_str "edit"),
    Pair.pair "id" (Json.make_num_int 1i64),
    Pair.pair "title" (Json.make_str "new title"),
    Pair.pair "notes" (Json.make_str "some notes"),
    Pair.pair "group" (Json.make_str "Work"),
    Pair.pair "tags" (Json.make_array [Json.make_str "a", Json.make_str "b"])
  ]) {
    Option.some a =>
      let todos := Action.apply a Storage.seed in
      match List.first todos {
        Option.some t =>
          t.title == "new title" && t.notes == "some notes"
          && (match t.group { Option.some g => g == "Work", Option.none => false })
          && List.length t.tags == 2i64,
        Option.none => false,
      },
    Option.none => false
  }

#[test]
def test_add_subtask_action_needs_title : Bool :=
  match Action.from_json (Json.make_object_pairs [
    Pair.pair "type" (Json.make_str "add_subtask"),
    Pair.pair "id" (Json.make_num_int 1i64)
  ]) {
    Option.some _ => false,
    Option.none => true
  }

#[test]
def test_set_status_action_from_json : Bool :=
  match Action.from_json (Json.make_object_pairs [
    Pair.pair "type" (Json.make_str "set_status"),
    Pair.pair "id" (Json.make_num_int 1i64),
    Pair.pair "status" (Json.make_str "doing")
  ]) {
    Option.some a =>
      let todos := Action.apply a Storage.seed in
      match List.first todos {
        Option.some t => Status.eq t.status Status.doing,
        Option.none => false,
      },
    Option.none => false
  }

#[test]
def test_clear_completed_action_from_json : Bool :=
  match Action.from_json (Json.make_object_pairs [
    Pair.pair "type" (Json.make_str "clear_completed")
  ]) {
    Option.some a =>
      let todos := Action.apply a (Action.apply (Action.toggle 1i64) Storage.seed) in
      List.length todos == 1i64,
    Option.none => false
  }

// ─── Action.to_json / text parsers ──────────────────────────────────────

#[test]
def test_to_json_round_trips_edit : Bool :=
  let a := Action.edit 1i64 "new title" "some notes" (Option.some "Work")
    (List.cons "a" (List.cons "b" List.empty)) in
  match Json.parse (Action.to_json a) {
    ok j => match Action.from_json j {
      Option.some b =>
        let todos := Action.apply b Storage.seed in
        match List.first todos {
          Option.some t =>
            t.title == "new title" && t.notes == "some notes"
            && (match t.group { Option.some g => g == "Work", Option.none => false })
            && List.length t.tags == 2i64,
          Option.none => false,
        },
      Option.none => false,
    },
    err _ => false,
  }

#[test]
def test_to_json_escapes_strings : Bool :=
  let json := Action.to_json (Action.add "a\"b\\c") in
  String.contains json "\\\"" && String.contains json "\\\\"

#[test]
def test_to_json_round_trips_set_status : Bool :=
  match Json.parse (Action.to_json (Action.set_status 2i64 Status.doing)) {
    ok j => match Action.from_json j {
      Option.some a => match a {
        Action.set_status id status => I64.beq id 2i64 && Status.eq status Status.doing,
        _ => false,
      },
      Option.none => false,
    },
    err _ => false,
  }

#[test]
def test_to_json_round_trips_clear_completed : Bool :=
  match Json.parse (Action.to_json Action.clear_completed) {
    ok j => match Action.from_json j {
      Option.some a => match a { Action.clear_completed => true, _ => false },
      Option.none => false,
    },
    err _ => false,
  }

#[test]
def test_parse_id_accepts_digits : Bool :=
  match Action.parse_id "  42 " {
    Option.some id => I64.beq id 42i64,
    Option.none => false,
  }

#[test]
def test_parse_id_rejects_non_digits : Bool :=
  match Action.parse_id "4x" {
    Option.some _ => false,
    Option.none => true,
  }

#[test]
def test_parse_id_rejects_empty : Bool :=
  match Action.parse_id "   " {
    Option.some _ => false,
    Option.none => true,
  }

#[test]
def test_parse_id_rejects_overflow : Bool :=
  match Action.parse_id "18446744073709551617" {
    Option.some _ => false,
    Option.none => true,
  }

#[test]
def test_tags_of_text_splits_and_trims : Bool :=
  let tags := Action.tags_of_text " work, urgent ,, " in
  List.length tags == 2i64

#[test]
def test_group_of_text_blank_is_none : Bool :=
  match Action.group_of_text "   " {
    Option.none => true,
    Option.some _ => false,
  }
