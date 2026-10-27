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
  Status.bad_request, Status.not_found
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

def Handlers.render_page (todos : List Todo) : IO Response := do {
  let version <- Persist.loader_version;
  return (Handlers.html_response (View.page_html version todos))
}

def Handlers.render : IO Response := do {
  let todos <- Persist.load;
  Handlers.render_page todos
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
      let todos <- Persist.load;
      match Handlers.find_by_id id todos {
        Option.some t => return (Handlers.html_response (View.edit_page_html version t)),
        Option.none => return (Handlers.html_response (View.edit_not_found_page_html version)),
      }
    },
    Option.none => Handlers.bad_request "invalid id",
  }
}

def Handlers.kanban_page (req : Request) : IO Response := do {
  let version <- Persist.loader_version;
  let todos <- Persist.load;
  return (Handlers.html_response (View.kanban_page_html version todos))
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

def Handlers.apply_and_save (action : Action) : IO (List Todo) := do {
  let todos <- Persist.load;
  let updated := Action.apply action todos;
  Persist.save updated;
  return updated
}

def Handlers.id_param (req : Request) : Option I64 :=
  match Router.param "id" req {
    Option.some s => Strings.parse_i64 s,
    Option.none => Option.none,
  }

// ── HTML (no-JS) routes ─────────────────────────────────────────────────

def Handlers.create_with (title : String) : IO Response := do {
  let updated <- Handlers.apply_and_save (Action.add title);
  Handlers.render_page updated
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
      let updated <- Handlers.apply_and_save (Action.toggle id);
      Handlers.render_page updated
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.delete (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.delete id);
      Handlers.render_page updated
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.edit (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.edit id
        (Form.value_or_empty "title" req) (Form.value_or_empty "notes" req)
        (Form.group_of req) (Form.tags_of req));
      Handlers.render_page updated
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.add_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => match Form.title_of req {
      Option.some title => do {
        let updated <- Handlers.apply_and_save (Action.add_subtask id title);
        Handlers.render_page updated
      },
      Option.none => Handlers.bad_request "expected a title field",
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.toggle_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.toggle_subtask id);
      Handlers.render_page updated
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.delete_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.delete_subtask id);
      Handlers.render_page updated
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.clear_completed (req : Request) : IO Response := do {
  let updated <- Handlers.apply_and_save Action.clear_completed;
  Handlers.render_page updated
}

/// Kanban move buttons: a plain form with no inputs, the destination
/// baked into `:status` in the URL (same "every parameter lives in the
/// path" precedent as toggle/delete) -- so there is no body to parse.
def Handlers.set_status (req : Request) : IO Response :=
  match Handlers.status_params req {
    Option.some pair => match pair {
      Pair.pair id status => do {
        let updated <- Handlers.apply_and_save (Action.set_status id status);
        Handlers.render_page updated
      },
    },
    Option.none => Handlers.bad_request "invalid id or status",
  }

// ── JSON API routes (the wasm shell) ────────────────────────────────────

def Handlers.api_list (req : Request) : IO Response := do {
  let todos <- Persist.load;
  return (Handlers.json_response (Codec.todos_to_json todos))
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
        let updated <- Handlers.apply_and_save action;
        return (Handlers.json_response (Codec.todos_to_json updated))
      },
      Option.none => Handlers.bad_request_json "invalid action",
    },
    err _ => Handlers.bad_request_json "invalid json",
  }

def Handlers.api_create (req : Request) : IO Response :=
  match Handlers.title_from_json (Handlers.request_body_text req) {
    Option.some title => do {
      let updated <- Handlers.apply_and_save (Action.add title);
      return (Handlers.json_response (Codec.todos_to_json updated))
    },
    Option.none => Handlers.bad_request_json "expected a title field",
  }

def Handlers.api_toggle (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.toggle id);
      return (Handlers.json_response (Codec.todos_to_json updated))
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_delete (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.delete id);
      return (Handlers.json_response (Codec.todos_to_json updated))
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_toggle_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.toggle_subtask id);
      return (Handlers.json_response (Codec.todos_to_json updated))
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_delete_subtask (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let updated <- Handlers.apply_and_save (Action.delete_subtask id);
      return (Handlers.json_response (Codec.todos_to_json updated))
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_clear_completed (req : Request) : IO Response := do {
  let updated <- Handlers.apply_and_save Action.clear_completed;
  return (Handlers.json_response (Codec.todos_to_json updated))
}

def Handlers.api_set_status (req : Request) : IO Response :=
  match Handlers.status_params req {
    Option.some pair => match pair {
      Pair.pair id status => do {
        let updated <- Handlers.apply_and_save (Action.set_status id status);
        return (Handlers.json_response (Codec.todos_to_json updated))
      },
    },
    Option.none => Handlers.bad_request_json "invalid id or status",
  }
