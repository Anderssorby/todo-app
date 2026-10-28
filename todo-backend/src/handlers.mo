/// Request handlers.
///
/// Each mutation loads the current list from todos.json, applies the
/// shared pure `Action`, saves it back, then renders -- the file-backed
/// workaround for the missing mutable-state primitive. HTML routes keep
/// the no-JS fallback working; `/api/*` routes return JSON for the wasm
/// shell.

use todo_core::action {Action}
use todo_core::codec {Codec.json_string, Codec.todos_to_json}
use todo_core::storage {Status, Todo}
use todo_core::view {
  View.edit_not_found_page_html, View.edit_page_html, View.kanban_page_html,
  View.new_page_html, View.page_html
}
use lib::form {Form.group_of, Form.tags_of, Form.title_of, Form.value_or_empty}
use lib::persist {Persist.load, Persist.loader_version, Persist.save}
use lib::logging {App.logger}
use log::logger {Logger.warn}
use http::types {
  Body, Headers, HttpVersion, Request, Response, Response.ok_text,
  Status.bad_request, Status.internal_server_error, Status.not_found
}
use http::body {Body.to_bytes_pure}
use http::strings {Strings.parse_i64}
use moon::router {Router.param}
use json::json {Json}
use std::list {List.filter}

def Handlers.text_response (content_type : String) (body : String) : Response :=
  let r := Response.ok_text body in
  { r with headers := Headers.set "Content-Type" content_type r.headers }

def Handlers.html_response (body : String) : Response :=
  Handlers.text_response "text/html; charset=utf-8" body

def Handlers.json_response (body : String) : Response :=
  Handlers.text_response "application/json; charset=utf-8" body

pub def Handlers.not_found : Response :=
  { status := Status.not_found,
    headers := Headers.set "Content-Type" "text/plain; charset=utf-8" Headers.empty,
    version := HttpVersion.http1_1,
    body := Body.text "not found" }

/// A mutation that could not be persisted must not be reported as success.
def Handlers.server_error (content_type : String) (msg : String) : IO Response := do {
  let _ <- Logger.warn App.logger ("server error: " ++ msg);
  return { status := Status.internal_server_error,
    headers := Headers.set "Content-Type" content_type Headers.empty,
    version := HttpVersion.http1_1,
    body := Body.text msg }
}

def Handlers.render_page (todos : List Todo) : IO Response := do {
  let version <- Persist.loader_version;
  return (Handlers.html_response (View.page_html version todos))
}

def Handlers.render : IO Response := do {
  let r <- Persist.load;
  Handlers.todos_html r
}

def Handlers.index (req : Request) : IO Response := Handlers.render

def Handlers.find_by_id (id : I64) (todos : List Todo) : Option Todo :=
  List.first (List.filter (fn (t : Todo) => t.id == id) todos)

def Handlers.new_task_page (req : Request) : IO Response := do {
  let version <- Persist.loader_version;
  return (Handlers.html_response (View.new_page_html version))
}

def Handlers.edit_task_page (req : Request) : IO Response := do {
  let version <- Persist.loader_version;
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Persist.load;
      match r {
        Result.ok todos => match Handlers.find_by_id id todos {
          Option.some t => return (Handlers.html_response (View.edit_page_html version t)),
          Option.none => return (Handlers.html_response (View.edit_not_found_page_html version)),
        },
        Result.err msg => Handlers.server_error "text/plain; charset=utf-8" msg,
      }
    },
    Option.none => Handlers.bad_request "invalid id",
  }
}

def Handlers.kanban_page (req : Request) : IO Response := do {
  let version <- Persist.loader_version;
  let r <- Persist.load;
  match r {
    Result.ok todos => return (Handlers.html_response (View.kanban_page_html version todos)),
    Result.err msg => Handlers.server_error "text/plain; charset=utf-8" msg,
  }
}

def Handlers.status_params (req : Request) : Option (Pair I64 Status) :=
  match Handlers.id_param req {
    Option.some id => match Router.param "status" req {
      Option.some s => match Status.from_string s {
        Option.some status => Option.some (Pair.pair id status),
        Option.none => Option.none,
      },
      Option.none => Option.none,
    },
    Option.none => Option.none,
  }

def Handlers.request_body_text (req : Request) : String :=
  String.from_list (Body.to_bytes_pure req.body)

def Handlers.title_from_json (body : String) : Option String :=
  match Json.parse body {
    ok j => match Json.get_object j {
      ok fields => match Json.object_get "title" fields {
        Option.some title_json => match Json.get_str title_json {
          ok title => Option.some title,
          err _ => Option.none,
        },
        Option.none => Option.none,
      },
      err _ => Option.none,
    },
    err _ => Option.none,
  }

def Handlers.bad_request (msg : String) : IO Response := do {
  let _ <- Logger.warn App.logger ("bad request: " ++ msg);
  let r := Response.ok_text msg;
  return { r with status := Status.bad_request }
}

def Handlers.bad_request_json (msg : String) : IO Response := do {
  let _ <- Logger.warn App.logger ("bad request: " ++ msg);
  let r := Handlers.json_response
    (String.concat "{\"error\":" (String.concat (Codec.json_string msg) "}"));
  return { r with status := Status.bad_request }
}

def Handlers.apply_and_save (action : Action) : IO (Result String (List Todo)) := do {
  let loaded <- Persist.load;
  match loaded {
    Result.err e => return (Result.err e),
    Result.ok todos => do {
      let updated := Action.apply action todos;
      let saved <- Persist.save updated;
      match saved {
        Result.ok _ => return (Result.ok updated),
        Result.err e => return (Result.err e),
      }
    },
  }
}

/// Render the main page for a loaded or saved list, or a 500 when the
/// state could not be read/written.
def Handlers.todos_html (r : Result String (List Todo)) : IO Response :=
  match r {
    Result.ok todos => Handlers.render_page todos,
    Result.err msg => Handlers.server_error "text/plain; charset=utf-8" msg,
  }

/// The JSON twin, for the SPA's `/api/*` routes.
def Handlers.todos_json (r : Result String (List Todo)) : IO Response :=
  match r {
    Result.ok todos => IO.pure (Handlers.json_response (Codec.todos_to_json todos)),
    Result.err msg => Handlers.server_error "application/json; charset=utf-8"
      (Codec.json_string msg),
  }

def Handlers.id_param (req : Request) : Option I64 :=
  match Router.param "id" req {
    Option.some s => Strings.parse_i64 s,
    Option.none => Option.none,
  }

// ── HTML (no-JS) routes ─────────────────────────────────────────────────

def Handlers.create_with (title : String) : IO Response := do {
  let r <- Handlers.apply_and_save (Action.add title);
  Handlers.todos_html r
}

def Handlers.create (req : Request) : IO Response :=
  match Form.title_of req {
    Option.some title => Handlers.create_with title,
    Option.none => match Handlers.title_from_json (Handlers.request_body_text req) {
      Option.some title => Handlers.create_with title,
      Option.none => Handlers.bad_request "expected a title field",
    },
  }

def Handlers.toggle (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.toggle id);
      Handlers.todos_html r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.delete (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.delete id);
      Handlers.todos_html r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.edit (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.edit id
        (Form.value_or_empty "title" req) (Form.value_or_empty "notes" req)
        (Form.group_of req) (Form.tags_of req));
      Handlers.todos_html r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.add_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => match Form.title_of req {
      Option.some title => do {
        let r <- Handlers.apply_and_save (Action.add_subtask id title);
        Handlers.todos_html r
      },
      Option.none => Handlers.bad_request "expected a title field",
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.toggle_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.toggle_subtask id);
      Handlers.todos_html r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.delete_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.delete_subtask id);
      Handlers.todos_html r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.clear_completed (req : Request) : IO Response := do {
  let r <- Handlers.apply_and_save Action.clear_completed;
  Handlers.todos_html r
}

/// Kanban move buttons: a plain form with no inputs, the destination
/// baked into `:status` in the URL (same "every parameter lives in the
/// path" precedent as toggle/delete) -- so there is no body to parse.
def Handlers.set_status (req : Request) : IO Response :=
  match Handlers.status_params req {
    Option.some pair => match pair {
      Pair.pair id status => do {
        let r <- Handlers.apply_and_save (Action.set_status id status);
        Handlers.todos_html r
      },
    },
    Option.none => Handlers.bad_request "invalid id or status",
  }

// ── JSON API routes (the wasm shell) ────────────────────────────────────

def Handlers.api_list (req : Request) : IO Response := do {
  let r <- Persist.load;
  Handlers.todos_json r
}

/// One JSON action for every SPA mutation. The typed-event SPA applies the
/// click actions locally and posts the same `Action`; add/edit/subtask-add
/// post it without a local apply (the server owns id allocation). Reuses
/// `Action.from_json`, the single decoder shared with the path-shaped API
/// twins and the no-JS routes.
def Handlers.api_action (req : Request) : IO Response :=
  match Json.parse (Handlers.request_body_text req) {
    ok j => match Action.from_json j {
      Option.some action => do {
        let r <- Handlers.apply_and_save action;
        Handlers.todos_json r
      },
      Option.none => Handlers.bad_request_json "invalid action",
    },
    err _ => Handlers.bad_request_json "invalid json",
  }

def Handlers.api_create (req : Request) : IO Response :=
  match Handlers.title_from_json (Handlers.request_body_text req) {
    Option.some title => do {
      let r <- Handlers.apply_and_save (Action.add title);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "expected a title field",
  }

def Handlers.api_toggle (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.toggle id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_delete (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.delete id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_toggle_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.toggle_subtask id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_delete_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save (Action.delete_subtask id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_clear_completed (req : Request) : IO Response := do {
  let r <- Handlers.apply_and_save Action.clear_completed;
  Handlers.todos_json r
}

def Handlers.api_set_status (req : Request) : IO Response :=
  match Handlers.status_params req {
    Option.some pair => match pair {
      Pair.pair id status => do {
        let r <- Handlers.apply_and_save (Action.set_status id status);
        Handlers.todos_json r
      },
    },
    Option.none => Handlers.bad_request_json "invalid id or status",
  }
