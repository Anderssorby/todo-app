/// Server-rendered HTML via plain string concatenation — no templating
/// mote exists for Monad yet (see todo-app/PLAN.md). The add/toggle/
/// delete controls submit JSON via `fetch()` rather than a native HTML
/// form POST, since the `http` mote has no incoming
/// application/x-www-form-urlencoded decoder.

use lib::storage {Todo}

def Html.item (t : Todo) : String :=
  // `if t.done then ...` directly (field index 2 of 3, not index 0)
  // segfaults -- plans-monad/implementations/
  // 2026-10-04-struct-field-access-as-if-cond-segfaults-nonzero-index.md.
  // Routing through Bool.not twice forces the working indirect path.
  let is_done := Bool.not (Bool.not t.done) in
  let checked := if is_done then "checked" else "" in
  let style := if is_done then " style=\"text-decoration:line-through\"" else "" in
  let id_str := I64.to_string t.id in
  String.concat_list [
    "<li><input type=\"checkbox\" ", checked, " onclick=\"toggleTodo(", id_str, ")\">",
    "<span", style, ">", t.title, "</span> ",
    "<button onclick=\"deleteTodo(", id_str, ")\">x</button></li>"
  ]

def Html.items (todos : List Todo) : String :=
  String.concat_list (List.map Html.item todos)

def Html.script : String :=
  "<script>\nfunction refresh(){location.reload();}\nfunction toggleTodo(id){fetch('/todos/'+id+'/toggle',{method:'POST'}).then(refresh);}\nfunction deleteTodo(id){fetch('/todos/'+id+'/delete',{method:'POST'}).then(refresh);}\ndocument.getElementById('add-form').addEventListener('submit',function(e){\n  e.preventDefault();\n  var title=document.getElementById('title').value;\n  fetch('/todos',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({title:title})}).then(refresh);\n});\n</script>"

def Html.page (todos : List Todo) : String :=
  String.concat_list [
    "<!doctype html><html><head><meta charset=\"utf-8\">",
    "<title>todo-app</title><style>body{font-family:sans-serif;max-width:32rem;margin:2rem auto}</style>",
    "</head><body><h1>todo-app</h1>",
    "<form id=\"add-form\"><input id=\"title\" placeholder=\"New todo\"><button type=\"submit\">Add</button></form>",
    "<ul id=\"list\">", Html.items todos, "</ul>",
    Html.script,
    "</body></html>"
  ]

