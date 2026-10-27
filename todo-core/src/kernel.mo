/// The browser state kernel: one JSON line in, one JSON line out.
///
/// The web wasm ABI exposes only `monad_main` plus the four stdio/time
/// imports, so the shell feeds the action through `read_stdin` and reads
/// the new state + rendered fragment back from `write_stdout`. Keeping the
/// whole transition here means the native, wasi, and web targets all run
/// exactly the same code.
use lib::action {Action}
use lib::codec {Codec.envelope_to_json, Codec.json_string, Codec.todos_from_json_values}
use lib::storage {Todo}
use lib::view {View.fragment_html}
use json::json {Json}
use std::map {BTreeMap}
use std::list {List.length}

pub def Kernel.error (msg : String) : String :=
  String.concat "{\"error\":" (String.concat (Codec.json_string msg) "}")

def Kernel.state_of (fields : BTreeMap String Json) : Option (List Todo) :=
  match Json.object_get "state" fields {
    Option.some state_j => match Json.get_array state_j {
      ok items => Option.some (Codec.todos_from_json_values items),
      err _ => Option.none,
    },
    Option.none => Option.none,
  }

def Kernel.action_of (fields : BTreeMap String Json) : Option Action :=
  match Json.object_get "action" fields {
    Option.some action_j => Action.from_json action_j,
    Option.none => Option.none,
  }

pub def Kernel.handle (input : String) : String :=
  match Json.parse input {
    ok j => match Json.get_object j {
      ok fields => match Kernel.state_of fields {
        Option.some todos => match Kernel.action_of fields {
          Option.some action =>
            let updated := Action.apply action todos in
            Codec.envelope_to_json updated (View.fragment_html updated),
          Option.none => Kernel.error "expected an action object",
        },
        Option.none => Kernel.error "expected a state array",
      },
      err _ => Kernel.error "expected a JSON object",
    },
    err _ => Kernel.error "invalid JSON",
  }

#[test]
def test_render_envelope_contains_html : Bool :=
  let input := "{\"state\":[{\"id\":1,\"title\":\"x\",\"done\":false}],\"action\":{\"type\":\"render\"}}" in
  match Json.parse (Kernel.handle input) {
    ok j => match Json.get_object j {
      ok fields => match Json.object_get "html" fields {
        Option.some h => match Json.get_str h {
          ok s => String.contains s "<li",
          err _ => false,
        },
        Option.none => false,
      },
      err _ => false,
    },
    err _ => false,
  }

#[test]
def test_add_updates_state : Bool :=
  let input := "{\"state\":[],\"action\":{\"type\":\"add\",\"title\":\"new\"}}" in
  match Json.parse (Kernel.handle input) {
    ok j => match Json.get_object j {
      ok fields => match Json.object_get "state" fields {
        Option.some s => match Json.get_array s {
          ok items => List.length items == 1i64,
          err _ => false,
        },
        Option.none => false,
      },
      err _ => false,
    },
    err _ => false,
  }

#[test]
def test_invalid_json_is_an_error_envelope : Bool :=
  String.contains (Kernel.handle "not json") "error"
