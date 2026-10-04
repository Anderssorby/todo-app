/// Request handlers. M3: each handler loads the current list from
/// todos.json, applies a pure transform, saves it back, then re-renders
/// -- the file-backed workaround for the missing mutable-state primitive
/// (see storage.mo's header comment).

use lib::storage {Storage.add, Storage.delete, Storage.toggle}
use lib::persist {Persist.load, Persist.save}
use lib::html {Html.page}
use http::types {Headers, Request, Response, Response.ok_text}
use http::body {Body.to_bytes_pure}
use http::strings {Strings.parse_i64}
use moon::router {Router.param}
use lang::json {Json}

def Handlers.html_response (body : String) : Response :=
  let r := Response.ok_text body in
  { r with headers := Headers.set "Content-Type" "text/html; charset=utf-8" r.headers }

def Handlers.render : IO Response := do {
  let todos <- Persist.load;
  return (Handlers.html_response (Html.page todos))
}

def Handlers.index (req : Request) : IO Response := Handlers.render

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

def Handlers.bad_request (msg : String) : Response :=
  let r := Response.ok_text msg in
  { r with status := 400u16 }

def Handlers.create (req : Request) : IO Response :=
  match Handlers.title_from_json (Handlers.request_body_text req) {
    Option.some title => do {
      let todos <- Persist.load;
      let updated := Storage.add title todos;
      Persist.save updated;
      return (Handlers.html_response (Html.page updated))
    },
    Option.none => return (Handlers.bad_request "bad request: expected a title field"),
  }

def Handlers.id_param (req : Request) : Option I64 :=
  match Router.param "id" req {
    Option.some s => Strings.parse_i64 s,
    Option.none => Option.none,
  }

def Handlers.toggle (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let todos <- Persist.load;
      let updated := Storage.toggle id todos;
      Persist.save updated;
      return (Handlers.html_response (Html.page updated))
    },
    Option.none => return (Handlers.bad_request "bad request: invalid id"),
  }

def Handlers.delete (req : Request) : IO Response :=
  match Handlers.id_param req {
    Option.some id => do {
      let todos <- Persist.load;
      let updated := Storage.delete id todos;
      Persist.save updated;
      return (Handlers.html_response (Html.page updated))
    },
    Option.none => return (Handlers.bad_request "bad request: invalid id"),
  }
