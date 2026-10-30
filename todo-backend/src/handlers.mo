/// Request handlers.
///
/// Protected handlers take the authenticated `Auth.Context`; each mutation
/// goes through `Db.apply_and_save`, which loads the shared list, applies
/// the pure `Action`, stamps attribution and writes transactionally. HTML
/// routes keep the no-JS fallback working; `/api/*` routes return JSON for
/// the wasm shell. Public auth routes (`/login`, `/auth/*`, `/api/me`) take
/// an `Auth.Config` instead.

use todo_core::action {Action}
use todo_core::codec {Codec.json_string, Codec.todos_to_json, Codec.user_to_json}
use todo_core::storage {Status, Todo}
use todo_core::user {User}
use todo_core::stamp {Stamp.validate_offset}
use todo_core::view {
  View.edit_not_found_page_html, View.edit_page_html, View.kanban_page_html,
  View.new_page_html, View.page_html
}
use lib::form {Form.due_of, Form.group_of, Form.tags_of, Form.title_of, Form.value_or_empty}
use lib::auth {Auth.dev_csrf, Auth.dev_user, Config, Context}
use lib::db {Db.apply_and_save, Db.load, Db.update_utc_offset}
use lib::persist {Persist.loader_version}
use lib::logging {App.logger}
use log::logger {Logger.warn}
use http::types {
  Body, Headers, HttpVersion, Request, Response, Response.ok_text,
  Response.redirect, Status.bad_request, Status.found, Status.internal_server_error,
  Status.not_found, Status.service_unavailable, Status.unauthorized
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

def Handlers.render_page (offset_minutes : I64) (todos : List Todo) : IO Response := do {
  let version <- Persist.loader_version;
  return (Handlers.html_response (View.page_html version offset_minutes todos))
}

def Handlers.render (ctx : Context) : IO Response := do {
  let r <- Db.load ctx.store;
  Handlers.todos_html ctx.user.utc_offset_minutes r
}

def Handlers.index (ctx : Context) (req : Request) : IO Response := Handlers.render ctx

def Handlers.find_by_id (id : I64) (todos : List Todo) : Option Todo :=
  List.first (List.filter (fn (t : Todo) => t.id == id) todos)

def Handlers.new_task_page (ctx : Context) (req : Request) : IO Response := do {
  let version <- Persist.loader_version;
  return (Handlers.html_response (View.new_page_html version))
}

def Handlers.edit_task_page (ctx : Context) (req : Request) : IO Response := do {
  let version <- Persist.loader_version;
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Db.load ctx.store;
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

def Handlers.kanban_page (ctx : Context) (req : Request) : IO Response := do {
  let version <- Persist.loader_version;
  let r <- Db.load ctx.store;
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

/// The `POST /api/todos` create body: the same field set as an `add`
/// action, without the `"type"` tag. `Action.add_from_fields` requires only
/// `title` and defaults notes/group/tags/due for old clients.
def Handlers.add_from_json_body (body : String) : Option Action :=
  match Json.parse body {
    ok j => match Json.get_object j {
      ok fields => Action.add_from_fields fields,
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

def Handlers.apply_and_save (ctx : Context) (action : Action)
    : IO (Result String (List Todo)) :=
  Db.apply_and_save ctx.store ctx.user action

/// Render the main page for a loaded or saved list, or a 500 when the
/// state could not be read/written.
def Handlers.todos_html (offset_minutes : I64) (r : Result String (List Todo)) : IO Response :=
  match r {
    Result.ok todos => Handlers.render_page offset_minutes todos,
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

def Handlers.create_with (ctx : Context) (title : String) (notes : String) (group : Option String)
    (tags : List String) (due_at : Option String) : IO Response :=
  match Action.validate_due due_at {
    Result.err msg => Handlers.bad_request msg,
    Result.ok _ => do {
      let r <- Handlers.apply_and_save ctx (Action.add title notes group tags due_at);
      Handlers.todos_html ctx.user.utc_offset_minutes r
    },
  }

def Handlers.create (ctx : Context) (req : Request) : IO Response :=
  match Form.title_of req {
    Option.some title =>
      Handlers.create_with ctx title (Form.value_or_empty "notes" req)
        (Form.group_of req) (Form.tags_of req) (Form.due_of req),
    Option.none => match Handlers.add_from_json_body (Handlers.request_body_text req) {
      Option.some action =>
        if Action.due_valid action
        then do {
          let r <- Handlers.apply_and_save ctx action;
          Handlers.todos_html ctx.user.utc_offset_minutes r
        }
        else Handlers.bad_request "due_at must be a valid YYYY-MM-DD date",
      Option.none => Handlers.bad_request "expected a title field",
    },
  }

def Handlers.toggle (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.toggle id);
      Handlers.todos_html ctx.user.utc_offset_minutes r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.delete (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.delete id);
      Handlers.todos_html ctx.user.utc_offset_minutes r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.edit (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id =>
      match Action.validate_due (Form.due_of req) {
        Result.err msg => Handlers.bad_request msg,
        Result.ok _ => do {
          let r <- Handlers.apply_and_save ctx (Action.edit id
            (Form.value_or_empty "title" req) (Form.value_or_empty "notes" req)
            (Form.group_of req) (Form.tags_of req) (Form.due_of req));
          Handlers.todos_html ctx.user.utc_offset_minutes r
        },
      },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.add_subtask (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => match Form.title_of req {
      Option.some title => do {
        let r <- Handlers.apply_and_save ctx (Action.add_subtask id title);
        Handlers.todos_html ctx.user.utc_offset_minutes r
      },
      Option.none => Handlers.bad_request "expected a title field",
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.toggle_subtask (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.toggle_subtask id);
      Handlers.todos_html ctx.user.utc_offset_minutes r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.delete_subtask (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.delete_subtask id);
      Handlers.todos_html ctx.user.utc_offset_minutes r
    },
    Option.none => Handlers.bad_request "invalid id",
  }

def Handlers.clear_completed (ctx : Context) (req : Request) : IO Response := do {
  let r <- Handlers.apply_and_save ctx Action.clear_completed;
  Handlers.todos_html ctx.user.utc_offset_minutes r
}

/// Kanban move buttons: a plain form with no inputs, the destination
/// baked into `:status` in the URL (same "every parameter lives in the
/// path" precedent as toggle/delete) -- so there is no body to parse.
def Handlers.set_status (ctx : Context) (req : Request) : IO Response :=
  match Handlers.status_params req {
    Option.some pair => match pair {
      Pair.pair id status => do {
        let r <- Handlers.apply_and_save ctx (Action.set_status id status);
        Handlers.todos_html ctx.user.utc_offset_minutes r
      },
    },
    Option.none => Handlers.bad_request "invalid id or status",
  }

// ── JSON API routes (the wasm shell) ────────────────────────────────────

def Handlers.api_list (ctx : Context) (req : Request) : IO Response := do {
  let r <- Db.load ctx.store;
  Handlers.todos_json r
}

/// One JSON action for every SPA mutation. The typed-event SPA applies the
/// click actions locally and posts the same `Action`; add/edit/subtask-add
/// post it without a local apply (the server owns id allocation). Reuses
/// `Action.from_json`, the single decoder shared with the path-shaped API
/// twins and the no-JS routes.
def Handlers.api_action (ctx : Context) (req : Request) : IO Response :=
  match Json.parse (Handlers.request_body_text req) {
    ok j => match Action.from_json j {
      Option.some action => Handlers.apply_checked ctx action,
      Option.none => Handlers.bad_request_json "invalid action",
    },
    err _ => Handlers.bad_request_json "invalid json",
  }

/// Validate the due date before writing: the domain stores the string
/// verbatim, so a malformed date from a hand-written client is a 400 rather
/// than a row the view cannot render.
pub def Handlers.apply_checked (ctx : Context) (action : Action) : IO Response :=
  if Action.due_valid action
  then do {
    let r <- Handlers.apply_and_save ctx action;
    Handlers.todos_json r
  }
  else Handlers.bad_request_json "due_at must be a valid YYYY-MM-DD date"

def Handlers.api_create (ctx : Context) (req : Request) : IO Response :=
  match Handlers.add_from_json_body (Handlers.request_body_text req) {
    Option.some action => Handlers.apply_checked ctx action,
    Option.none => Handlers.bad_request_json "expected a title field",
  }

def Handlers.api_toggle (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.toggle id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_delete (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.delete id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_toggle_subtask (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.toggle_subtask id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_delete_subtask (ctx : Context) (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let r <- Handlers.apply_and_save ctx (Action.delete_subtask id);
      Handlers.todos_json r
    },
    Option.none => Handlers.bad_request_json "invalid id",
  }

def Handlers.api_clear_completed (ctx : Context) (req : Request) : IO Response := do {
  let r <- Handlers.apply_and_save ctx Action.clear_completed;
  Handlers.todos_json r
}

def Handlers.api_set_status (ctx : Context) (req : Request) : IO Response :=
  match Handlers.status_params req {
    Option.some pair => match pair {
      Pair.pair id status => do {
        let r <- Handlers.apply_and_save ctx (Action.set_status id status);
        Handlers.todos_json r
      },
    },
    Option.none => Handlers.bad_request_json "invalid id or status",
  }

// ── Public auth routes ─────────────────────────────────────────────────

pub def Handlers.unauthorized_json : Response :=
  let r := Handlers.json_response "{\"error\":\"unauthorized\"}" in
  { r with status := Status.unauthorized }

pub def Handlers.login_page (config : Config) (req : Request) : IO Response := do {
  let html :=
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>todo-app</title>" ++
    "</head><body><h1>todo-app</h1>" ++
    "<p>Sign-in is disabled in this build: the pinned oauth mote cannot yet " ++
    "validate an ID token. For local use, start the server with " ++
    "<code>TODO_DEV_AUTH=1</code>.</p>" ++
    "<p><a href=\"/auth/login\">Sign in with SSO</a></p>" ++
    "</body></html>";
  return (Handlers.html_response html)
}

/// A 503 that says why sign-in is unavailable, rather than pretending the
/// route does not exist. The `oauth` mote is present at the pinned revision,
/// but it is Phase 0-1: it has no JWT/JWKS parser and no signature
/// verification, so accepting an ID token would authenticate nothing.
def Handlers.sign_in_unavailable : IO Response := do {
  let _ <- Logger.warn App.logger
    ("OAuth sign-in is disabled: the pinned oauth mote has no ID-token validation");
  let r := Response.ok_text
    ("OAuth sign-in is not enabled in this build. The pinned oauth mote " ++
     "implements the authorization-code + PKCE client flow but cannot " ++
     "validate an ID token yet (no JWT/JWKS/signature verification), so " ++
     "production sign-in is deferred. Use TODO_DEV_AUTH=1 for local sign-in.");
  return { r with status := Status.service_unavailable,
    headers := Headers.set "Content-Type" "text/plain; charset=utf-8" Headers.empty }
}

pub def Handlers.auth_login (config : Config) (req : Request) : IO Response :=
  if config.dev_auth
  then return (Response.redirect Status.found "/")
  else Handlers.sign_in_unavailable

pub def Handlers.auth_callback (config : Config) (req : Request) : IO Response :=
  Handlers.sign_in_unavailable

pub def Handlers.auth_logout (config : Config) (req : Request) : IO Response :=
  return (Response.redirect Status.found "/login")

/// The `{"csrf":…,"user":…}` envelope shared by `GET /api/me` and the
/// offset update.
def Handlers.me_json (user : User) (csrf : String) : String :=
  String.concat "{\"csrf\":"
    (String.concat (Codec.json_string csrf)
      (String.concat ",\"user\":"
        (String.concat (Codec.user_to_json user) "}")))

pub def Handlers.api_me (config : Config) (req : Request) : IO Response := do {
  let user_opt <- Auth.dev_user config;
  match user_opt {
    Option.some user =>
      return (Handlers.json_response (Handlers.me_json user Auth.dev_csrf)),
    Option.none => return Handlers.unauthorized_json,
  }
}

/// `POST /api/me {"utc_offset_minutes":n}` — the per-user display offset.
/// Protected like every other mutation; authentication is currently the
/// dev-only stub, so there is no session/CSRF token to check yet.
pub def Handlers.api_update_me (ctx : Context) (req : Request) : IO Response :=
  match Json.parse (Handlers.request_body_text req) {
    ok j => match Json.get_object j {
      ok fields => match Json.object_get "utc_offset_minutes" fields {
        Option.some n_j => match Json.get_num_i64 (Json.get_num n_j) {
          ok minutes => match Stamp.validate_offset minutes {
            Result.err msg => Handlers.bad_request_json msg,
            Result.ok value => do {
              let updated <- Db.update_utc_offset ctx.store ctx.user.id value;
              match updated {
                Result.err msg => Handlers.server_error "application/json; charset=utf-8"
                  (Codec.json_string msg),
                Result.ok _ =>
                  return (Handlers.json_response
                    (Handlers.me_json { ctx.user with utc_offset_minutes := value } ctx.csrf)),
              }
            },
          },
          err _ => Handlers.bad_request_json
            "utc_offset_minutes must be an integer",
        },
        Option.none => Handlers.bad_request_json
          "expected utc_offset_minutes",
      },
      err _ => Handlers.bad_request_json "expected a JSON object",
    },
    err _ => Handlers.bad_request_json "invalid json",
  }
