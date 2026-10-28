/// The single typed view definition: `Oak.Node Msg` / `Oak.Attr Msg` over
/// `xml_html` nodes.
///
/// The native backend serializes the SSR pages (`View.page`, `View.new_page`,
/// …) with `Html.to_string (Oak.to_html …)`; the SPA reuses the generic
/// `View.group_badge`/`View.tag_chip` builders and owns its interactive forms
/// and list. Keeping the markup here means the no-JS fallback and the SPA
/// cannot drift. `Html.to_string` escapes text and attribute values.
///
/// Raw form attributes (`method`, `action`, `enctype`) use oak's typed
/// `Html.attr`; the no-JS forms are handler-free, so they lower verbatim.
use lib::storage {Status, Storage.seed, Subtask, Todo}
use oak::elements {
  Html.a, Html.attr, Html.button, Html.checked, Html.class_, Html.data, Html.div, Html.document,
  Html.footer, Html.form, Html.fragment, Html.h1, Html.href, Html.input, Html.li, Html.main_,
  Html.meta, Html.name_, Html.nav, Html.node, Html.p, Html.placeholder, Html.required,
  Html.span, Html.style, Html.text, Html.textarea, Html.title, Html.type_,
  Html.ul, Html.value_
}
use oak::typed {Oak.Attr, Oak.Node, Oak.to_html}
use std::list {List.filter, List.intercalate, List.length}
use xml_html::html {Html.to_string}

// The loader hash is supplied by the backend, which reads it from the
// generated `web/boot.version` (see `todo-webgen`). The page builders take it
// so the script URL is `/web/boot.js?v=<hash of boot.js>`.

pub def View.css : String :=
  String.concat_list [
    ":root{",
      "--bg:#fafafa;--surface:#ffffff;--fg:#1a1a1a;--muted:#6b7280;",
      "--border:#e5e7eb;--accent:#4f46e5;--accent-fg:#ffffff;",
      "--done-opacity:.55;--radius:.75rem;--shadow:0 1px 2px rgba(0,0,0,.06)",
    "}",
    "@media (prefers-color-scheme:dark){:root{",
      "--bg:#0f1115;--surface:#1a1d23;--fg:#e5e7eb;--muted:#9ca3af;",
      "--border:#2a2d35;--accent:#818cf8;--accent-fg:#0f1115",
    "}}",
    ".todo-app[data-theme=\"dark\"]{",
      "--bg:#0f1115;--surface:#1a1d23;--fg:#e5e7eb;--muted:#9ca3af;",
      "--border:#2a2d35;--accent:#818cf8;--accent-fg:#0f1115",
    "}",
    ".todo-app[data-theme=\"light\"]{",
      "--bg:#fafafa;--surface:#ffffff;--fg:#1a1a1a;--muted:#6b7280;",
      "--border:#e5e7eb;--accent:#4f46e5;--accent-fg:#ffffff",
    "}",
    "body{background:var(--bg);color:var(--fg);font-family:system-ui,sans-serif;margin:0}",
    ".todo-app{max-width:38rem;margin:2rem auto;padding:0 1rem}",
    "nav.tabs{display:flex;gap:.5rem;border-bottom:1px solid var(--border);margin-bottom:1rem}",
    "nav.tabs .tab,nav.tabs a{background:none;border:none;padding:.5rem 1rem;color:var(--muted);",
      "cursor:pointer;font:inherit;text-decoration:none}",
    "nav.tabs .tab.active,nav.tabs a.active{color:var(--accent);border-bottom:2px solid var(--accent)}",
    "nav.tabs .nav-new{margin-left:auto;color:var(--accent)}",
    ".back-link{display:inline-block;margin-bottom:1rem;color:var(--muted)}",
    ".not-found{color:var(--muted)}",
    ".add-form{display:flex;gap:.5rem;margin-bottom:1rem}",
    ".add-form input{flex:1;padding:.5rem;border:1px solid var(--border);border-radius:.4rem;background:var(--surface);color:var(--fg)}",
    ".add-form button,.subtask-add-form button{",
      "background:var(--accent);color:var(--accent-fg);border:none;border-radius:.4rem;padding:.5rem 1rem;cursor:pointer",
    "}",
    "ul.todos{list-style:none;padding:0;margin:0;display:flex;flex-direction:column;gap:.5rem}",
    "ul.todos li.todo{",
      "background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);",
      "box-shadow:var(--shadow);padding:.75rem 1rem}",
    "ul.todos li form{margin:0}",
    ".todo-main{display:flex;align-items:center;gap:.5rem}",
    ".toggle-form{display:flex;align-items:center;gap:.5rem;flex:1}",
    ".title{flex:1;text-align:left;background:none;border:none;font:inherit;padding:0;cursor:pointer;color:var(--fg)}",
    "li.done .title{text-decoration:line-through;opacity:var(--done-opacity)}",
    ".delete-form button{background:none;border:none;color:var(--muted);cursor:pointer;font-size:1rem}",
    ".todo-meta{display:flex;gap:.4rem;flex-wrap:wrap;margin-top:.4rem}",
    ".group{background:var(--accent);color:var(--accent-fg);border-radius:.4rem;padding:.1rem .5rem;font-size:.75rem}",
    ".tag{border:1px solid var(--border);border-radius:.4rem;padding:.1rem .5rem;font-size:.75rem;color:var(--muted)}",
    ".notes-preview{color:var(--muted);font-size:.875rem;margin:.4rem 0 0;white-space:pre-wrap}",
    ".subtasks{margin-top:.5rem;border-top:1px solid var(--border);padding-top:.4rem}",
    ".subtask-list{list-style:none;padding:0;margin:0;display:flex;flex-direction:column;gap:.2rem}",
    ".subtask-list li{display:flex}",
    ".subtask-row{display:flex;align-items:center;gap:.4rem;flex:1}",
    ".subtask-row.done .subtask-title{text-decoration:line-through;opacity:var(--done-opacity)}",
    ".subtask-title{flex:1;text-align:left;background:none;border:none;font:inherit;padding:0;cursor:pointer;color:var(--fg)}",
    ".subtask-delete-form button{background:none;border:none;color:var(--muted);cursor:pointer}",
    ".subtask-add-form{display:flex;gap:.4rem;margin-top:.4rem}",
    ".subtask-add-form input{flex:1;padding:.3rem;border:1px solid var(--border);border-radius:.4rem;background:var(--surface);color:var(--fg)}",
    ".edit-form{margin-top:.5rem;border-top:1px solid var(--border);padding-top:.5rem;display:flex;flex-direction:column;gap:.4rem}",
    ".edit-form input,.edit-form textarea{padding:.4rem;border:1px solid var(--border);border-radius:.4rem;background:var(--surface);color:var(--fg);font:inherit}",
    ".edit-form button{align-self:flex-start;background:var(--accent);color:var(--accent-fg);border:none;border-radius:.4rem;padding:.4rem 1rem;cursor:pointer}",
    ".error-banner{display:flex;justify-content:space-between;align-items:center;gap:.75rem;padding:.6rem .8rem;margin-bottom:1rem;border:1px solid #fca5a5;border-radius:.4rem;background:#fef2f2;color:#991b1b;font-size:.875rem}",
    ".error-banner.hidden{display:none}",
    ".error-banner button{border:1px solid currentColor;border-radius:.4rem;padding:.25rem .8rem;background:none;color:inherit;cursor:pointer}",
    ".app-footer{display:flex;justify-content:space-between;align-items:center;margin-top:1rem;color:var(--muted);font-size:.875rem}",
    ".app-footer button{background:none;border:1px solid var(--border);border-radius:.4rem;padding:.3rem .8rem;color:var(--fg);cursor:pointer}",
    ".settings-tab .setting-row{display:flex;justify-content:space-between;align-items:center;padding:.75rem 0;border-bottom:1px solid var(--border)}",
    ".settings-tab .switch{border:1px solid var(--border);border-radius:1rem;padding:.25rem .9rem;background:var(--surface);color:var(--fg);cursor:pointer}",
    ".filter-bar{display:flex;gap:.4rem;flex-wrap:wrap;margin-bottom:1rem}",
    ".filter-chip{border:1px solid var(--border);border-radius:1rem;padding:.2rem .7rem;",
      "font-size:.8rem;background:var(--surface);color:var(--muted);cursor:pointer}",
    ".filter-chip.active{background:var(--accent);color:var(--accent-fg);border-color:var(--accent)}",
    ".kanban-board{display:flex;gap:1rem;align-items:flex-start}",
    ".kanban-column{flex:1;background:var(--surface);border:1px solid var(--border);",
      "border-radius:var(--radius);padding:.75rem;min-width:0}",
    ".kanban-column h2{font-size:.9rem;color:var(--muted);margin:0 0 .5rem}",
    ".kanban-card{background:var(--bg);border:1px solid var(--border);border-radius:.5rem;",
      "padding:.5rem .6rem;margin-bottom:.5rem}",
    ".kanban-card .kanban-title{display:block;margin-bottom:.3rem}",
    ".kanban-column.drag-over{border-color:var(--accent);box-shadow:0 0 0 2px var(--accent) inset}",
    ".kanban-card.dragging{opacity:.45}",
    ".kanban-move{display:flex;gap:.3rem;margin-top:.3rem}",
    ".kanban-move button,.kanban-move form button{",
      "background:none;border:1px solid var(--border);border-radius:.3rem;",
      "padding:.1rem .5rem;color:var(--fg);cursor:pointer;font-size:.8rem}",
    ".kanban-move form{margin:0}"
  ]

def View.done_attrs (t : Todo) : List (Oak.Attr Unit) :=
  if t.done then List.cons Html.checked List.empty else List.empty

def View.item_classes (t : Todo) : List String :=
  if t.done then ["todo", "done"] else ["todo"]

def View.todo_path (t : Todo) (op : String) : String :=
  String.concat "/todos/" (String.concat (I64.to_string t.id) (String.concat "/" op))

/// Toggle is a form so it works without JS (the title button submits);
/// the checkbox and the title also carry `data-op` for the shell.
def View.toggle_form (t : Todo) : Oak.Node Unit :=
  let id_str := I64.to_string t.id in
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" (View.todo_path t "toggle"),
      Html.class_ ["toggle-form"] ]
    [ Html.input (List.append
        [ Html.type_ "checkbox",
          Html.data "op" "toggle",
          Html.data "id" id_str ]
        (View.done_attrs t)),
      Html.button
        [ Html.type_ "submit",
          Html.class_ ["title"],
          Html.data "op" "toggle",
          Html.data "id" id_str ]
        [Html.text t.title] ]

def View.delete_form (t : Todo) : Oak.Node Unit :=
  let id_str := I64.to_string t.id in
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" (View.todo_path t "delete") ]
    [ Html.button
        [ Html.type_ "submit",
          Html.data "op" "delete",
          Html.data "id" id_str ]
        [Html.text "x"] ]

pub def View.group_badge {Msg : Type} (group : Option String) : Oak.Node Msg :=
  match group {
    Option.some g => Html.span [Html.class_ ["group"]] [Html.text g],
    Option.none => Html.fragment List.empty,
  }

pub def View.tag_chip {Msg : Type} (tag : String) : Oak.Node Msg :=
  Html.span [Html.class_ ["tag"]] [Html.text tag]

def View.notes_preview (t : Todo) : Oak.Node Unit :=
  if String.beq t.notes "" then Html.fragment List.empty
  else Html.p [Html.class_ ["notes-preview"]] [Html.text t.notes]

def View.subtask_path (sid : I64) (op : String) : String :=
  String.concat "/subtasks/" (String.concat (I64.to_string sid) (String.concat "/" op))

def View.subtask_toggle_form (s : Subtask) : Oak.Node Unit :=
  let id_str := I64.to_string s.id in
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" (View.subtask_path s.id "toggle"),
      Html.class_ ["subtask-row"] ]
    [ Html.button
        [ Html.type_ "submit", Html.class_ ["subtask-title"],
          Html.data "op" "toggle_subtask", Html.data "id" id_str ]
        [Html.text s.title] ]

def View.subtask_delete_form (s : Subtask) : Oak.Node Unit :=
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" (View.subtask_path s.id "delete"),
      Html.class_ ["subtask-delete-form"] ]
    [ Html.button
        [ Html.type_ "submit",
          Html.data "op" "delete_subtask", Html.data "id" (I64.to_string s.id) ]
        [Html.text "x"] ]

def View.subtask_row (s : Subtask) : Oak.Node Unit :=
  Html.li [Html.class_ (if s.done then ["subtask-row", "done"] else ["subtask-row"])]
    [ View.subtask_toggle_form s, View.subtask_delete_form s ]

pub def View.subtask_add_form (t : Todo) : Oak.Node Unit :=
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" (View.todo_path t "subtasks"),
      Html.attr "enctype" "application/x-www-form-urlencoded",
      Html.class_ ["subtask-add-form"] ]
    [ Html.input [Html.name_ "title", Html.placeholder "Add a subtask", Html.required, Html.type_ "text"],
      Html.button [Html.type_ "submit"] [Html.text "+"] ]

def View.subtasks_block (t : Todo) : Oak.Node Unit :=
  if List.length t.subtasks == 0i64 then View.subtask_add_form t
  else
    Html.div [Html.class_ ["subtasks"]]
      [ Html.ul [Html.class_ ["subtask-list"]] (List.map View.subtask_row t.subtasks),
        View.subtask_add_form t ]

/// A form that edits an existing task's title/notes/group/tags. Prefilled
/// from the current values, since populating a `value`/text-content
/// attribute needs no DOM-value-read (only *reading one back* does, which
/// is what the wasm shell can never do -- see the module doc).
pub def View.edit_form (t : Todo) : Oak.Node Unit :=
  let tags_str := List.intercalate ", " t.tags in
  let group_str := match t.group { Option.some g => g, Option.none => "" } in
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" (View.todo_path t "edit"),
      Html.attr "enctype" "application/x-www-form-urlencoded",
      Html.class_ ["edit-form"] ]
    [ Html.input [Html.name_ "title", Html.value_ t.title, Html.required, Html.type_ "text", Html.placeholder "Title"],
      Html.textarea [Html.name_ "notes", Html.placeholder "Notes"] [Html.text t.notes],
      Html.input [Html.name_ "group", Html.value_ group_str, Html.type_ "text", Html.placeholder "Group"],
      Html.input [Html.name_ "tags", Html.value_ tags_str, Html.type_ "text", Html.placeholder "Tags (comma separated)"],
      Html.button [Html.type_ "submit"] [Html.text "Save"] ]

def View.edit_link (t : Todo) : Oak.Node Unit :=
  Html.a [Html.href (View.todo_path t "edit")] [Html.text "Edit"]

pub def View.item (t : Todo) : Oak.Node Unit :=
  Html.li [Html.class_ (View.item_classes t)]
    [ Html.div [Html.class_ ["todo-main"]] [ View.toggle_form t, View.delete_form t, View.edit_link t ],
      Html.div [Html.class_ ["todo-meta"]]
        (List.append (List.cons (View.group_badge t.group) List.empty) (List.map View.tag_chip t.tags)),
      View.notes_preview t,
      View.subtasks_block t ]

/// The no-JS create form. The backend parses this as urlencoded; without
/// JavaScript the submit is a real navigation. The SPA renders its own
/// controlled form (posting `/api/actions`) and never uses this one.
pub def View.add_form : Oak.Node Unit :=
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" "/todos",
      Html.attr "enctype" "application/x-www-form-urlencoded",
      Html.class_ ["add-form"] ]
    [ Html.input [Html.name_ "title", Html.placeholder "New todo", Html.required, Html.type_ "text"],
      Html.button [Html.type_ "submit"] [Html.text "Add"] ]

def View.count_label (todos : List Todo) : String :=
  let remaining := List.length (List.filter (fn (t : Todo) => Bool.not t.done) todos) in
  String.concat (I64.to_string remaining) " left"

pub def View.footer (todos : List Todo) : Oak.Node Unit :=
  Html.footer [Html.class_ ["app-footer"]]
    [ Html.span List.empty [Html.text (View.count_label todos)],
      Html.form
        [ Html.attr "method" "post", Html.attr "action" "/todos/clear-completed" ]
        [ Html.button [Html.type_ "submit", Html.data "op" "clear_completed"] [Html.text "Clear completed"] ] ]

/// Shared no-JS chrome: real `<a>` links, so every page below works
/// without JS. No Settings link -- that page has no server route (its
/// only state, dark mode/hide-completed, is pure client/localStorage
/// state with nothing to server-render).
pub def View.nav : Oak.Node Unit :=
  Html.nav [Html.class_ ["tabs"]]
    [ Html.a [Html.href "/"] [Html.text "Tasks"],
      Html.a [Html.href "/kanban"] [Html.text "Kanban"],
      Html.a [Html.href "/todos/new", Html.class_ ["nav-new"]] [Html.text "+ New"] ]

pub def View.fragment (todos : List Todo) : Oak.Node Unit :=
  Html.div [Html.class_ ["todo-app"]]
    [ Html.h1 List.empty [Html.text "todo-app"],
      View.nav,
      Html.ul [Html.class_ ["todos"]] (List.map View.item todos),
      View.footer todos ]

pub def View.fragment_html (todos : List Todo) : String :=
  Html.to_string (Oak.to_html (View.fragment todos))

/// The HTML-document boilerplate shared by every page (index, kanban,
/// new-task, edit-task): head/style/script chrome around whatever the
/// caller mounts into `#app`.
def View.shell (version : String) (inner : Oak.Node Unit) : Oak.Node Unit :=
  Html.document
    [ Html.meta [Html.attr "charset" "utf-8"],
      Html.title List.empty [Html.text "todo-app"],
      Html.style List.empty View.css ]
    [ Html.main_ [Html.class_ ["app-root"]]
        [ Html.div [Html.attr "id" "app"] [inner] ],
      Html.node "script"
        [Html.attr "src" (String.concat "/web/boot.js?v=" version),
         Html.attr "type" "module"]
        List.empty ]

def View.back_link : Oak.Node Unit :=
  Html.a [Html.href "/", Html.class_ ["back-link"]] [Html.text "< Back to tasks"]

pub def View.page (version : String) (todos : List Todo) : Oak.Node Unit :=
  View.shell version (View.fragment todos)

pub def View.page_html (version : String) (todos : List Todo) : String :=
  Html.to_string (Oak.to_html (View.page version todos))

/// The dedicated new-task page: `View.add_form` no longer renders inline
/// above the list, only here.
pub def View.new_page (version : String) : Oak.Node Unit :=
  View.shell version (Html.div [Html.class_ ["todo-app"]]
    [ Html.h1 List.empty [Html.text "todo-app"],
      View.nav,
      View.back_link,
      View.add_form ])

pub def View.new_page_html (version : String) : String :=
  Html.to_string (Oak.to_html (View.new_page version))

/// The dedicated edit-task page: `View.edit_form` no longer renders
/// inline per item, only here.
pub def View.edit_page (version : String) (t : Todo) : Oak.Node Unit :=
  View.shell version (Html.div [Html.class_ ["todo-app"]]
    [ Html.h1 List.empty [Html.text "todo-app"],
      View.nav,
      View.back_link,
      View.edit_form t ])

pub def View.edit_page_html (version : String) (t : Todo) : String :=
  Html.to_string (Oak.to_html (View.edit_page version t))

pub def View.edit_not_found_page (version : String) : Oak.Node Unit :=
  View.shell version (Html.div [Html.class_ ["todo-app"]]
    [ Html.h1 List.empty [Html.text "todo-app"],
      View.nav,
      Html.p [Html.class_ ["not-found"]] [Html.text "That task was not found."],
      View.back_link ])

pub def View.edit_not_found_page_html (version : String) : String :=
  Html.to_string (Oak.to_html (View.edit_not_found_page version))

// ── kanban board ─────────────────────────────────────────────────────

def View.todo_status_path (t : Todo) (target : Status) : String :=
  View.todo_path t (String.concat "status/" (Status.to_string target))

/// Move buttons omit the direction that would be a no-op: no "back"
/// button in the first column, no "forward" button in the last.
def View.kanban_move_form (t : Todo) (target : Status) (label : String) : Oak.Node Unit :=
  Html.form
    [ Html.attr "method" "post",
      Html.attr "action" (View.todo_status_path t target) ]
    [ Html.button [Html.type_ "submit"] [Html.text label] ]

def View.kanban_moves (t : Todo) : Oak.Node Unit :=
  let backward :=
    match t.status { Status.todo => List.empty,
      _ => List.cons (View.kanban_move_form t (Status.prev t.status) "<") List.empty } in
  let forward :=
    match t.status { Status.done => List.empty,
      _ => List.cons (View.kanban_move_form t (Status.next t.status) ">") List.empty } in
  Html.div [Html.class_ ["kanban-move"]] (List.append backward forward)

def View.kanban_card (t : Todo) : Oak.Node Unit :=
  Html.div [Html.class_ ["kanban-card"]]
    [ Html.span [Html.class_ ["kanban-title"]] [Html.text t.title],
      Html.div [Html.class_ ["todo-meta"]]
        (List.append (List.cons (View.group_badge t.group) List.empty) (List.map View.tag_chip t.tags)),
      View.kanban_moves t ]

def View.kanban_column (status : Status) (label : String) (todos : List Todo) : Oak.Node Unit :=
  Html.div [Html.class_ ["kanban-column"]]
    [ Html.node "h2" List.empty [Html.text label],
      Html.div List.empty
        (List.map View.kanban_card (List.filter (fn (t : Todo) => Status.eq t.status status) todos)) ]

pub def View.kanban_board (todos : List Todo) : Oak.Node Unit :=
  Html.div [Html.class_ ["kanban-board"]]
    [ View.kanban_column Status.todo "To do" todos,
      View.kanban_column Status.doing "Doing" todos,
      View.kanban_column Status.done "Done" todos ]

pub def View.kanban_page (version : String) (todos : List Todo) : Oak.Node Unit :=
  View.shell version (Html.div [Html.class_ ["todo-app"]]
    [ Html.h1 List.empty [Html.text "todo-app"],
      View.nav,
      View.kanban_board todos ])

pub def View.kanban_page_html (version : String) (todos : List Todo) : String :=
  Html.to_string (Oak.to_html (View.kanban_page version todos))

#[test]
def test_item_escapes_title : Bool :=
  let todos := List.cons ({ id := 1i64, title := "<script>&\"", done := false,
    notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.todo } : Todo) List.empty in
  let html := View.fragment_html todos in
  String.contains html "&lt;script&gt;&amp;" && Bool.not (String.contains html "<script>&")

#[test]
def test_done_item_renders_checked_and_class : Bool :=
  let todos := List.cons ({ id := 7i64, title := "x", done := true,
    notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.done } : Todo) List.empty in
  let html := View.fragment_html todos in
  String.contains html "checked" && String.contains html "class=\"todo done\""

#[test]
def test_page_loads_the_module_script : Bool :=
  String.contains (View.page_html "testhash" Storage.seed) "/web/boot.js?v=testhash"

#[test]
def test_item_renders_group_badge : Bool :=
  let todos := List.cons ({ id := 1i64, title := "x", done := false,
    notes := "", tags := List.empty, group := Option.some "Work", subtasks := List.empty,
    status := Status.todo } : Todo) List.empty in
  String.contains (View.fragment_html todos) "<span class=\"group\">Work</span>"

#[test]
def test_item_renders_tag_chips : Bool :=
  let tags := List.cons "urgent" (List.cons "later" List.empty) in
  let todos := List.cons ({ id := 1i64, title := "x", done := false,
    notes := "", tags := tags, group := Option.none, subtasks := List.empty,
    status := Status.todo } : Todo) List.empty in
  let html := View.fragment_html todos in
  String.contains html "<span class=\"tag\">urgent</span>" && String.contains html "<span class=\"tag\">later</span>"

#[test]
def test_item_renders_notes_preview_when_present : Bool :=
  let todos := List.cons ({ id := 1i64, title := "x", done := false,
    notes := "remember this", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.todo } : Todo) List.empty in
  String.contains (View.fragment_html todos) "remember this"

#[test]
def test_item_omits_notes_preview_when_empty : Bool :=
  let todos := List.cons ({ id := 1i64, title := "x", done := false,
    notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.todo } : Todo) List.empty in
  Bool.not (String.contains (View.fragment_html todos) "notes-preview")

#[test]
def test_item_renders_subtask_rows : Bool :=
  let subs := List.cons ({ id := 1i64, title := "step one", done := false } : Subtask) List.empty in
  let todos := List.cons ({ id := 1i64, title := "x", done := false,
    notes := "", tags := List.empty, group := Option.none, subtasks := subs,
    status := Status.todo } : Todo) List.empty in
  let html := View.fragment_html todos in
  String.contains html "step one" && String.contains html "action=\"/subtasks/1/toggle\""

#[test]
def test_item_renders_edit_link_not_inline_form : Bool :=
  let todos := List.cons ({ id := 1i64, title := "x", done := false,
    notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.todo } : Todo) List.empty in
  let html := View.fragment_html todos in
  String.contains html "href=\"/todos/1/edit\"" && Bool.not (String.contains html "class=\"edit-form\"")

#[test]
def test_fragment_has_no_inline_add_form : Bool :=
  Bool.not (String.contains (View.fragment_html Storage.seed) "class=\"add-form\"")

#[test]
def test_new_page_renders_add_form : Bool :=
  String.contains (View.new_page_html "testhash") "class=\"add-form\""

#[test]
def test_edit_page_prefills_existing_values : Bool :=
  let tags := List.cons "a" List.empty in
  let t := ({ id := 1i64, title := "my title", done := false,
    notes := "my notes", tags := tags, group := Option.some "Work", subtasks := List.empty,
    status := Status.todo } : Todo) in
  let html := View.edit_page_html "testhash" t in
  String.contains html "value=\"my title\"" && String.contains html "value=\"Work\""
  && String.contains html "action=\"/todos/1/edit\""

#[test]
def test_edit_not_found_page_mentions_not_found : Bool :=
  String.contains (View.edit_not_found_page_html "testhash") "not found"

#[test]
def test_kanban_page_places_cards_in_their_status_column : Bool :=
  let t := ({ id := 1i64, title := "doing task", done := false,
    notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.doing } : Todo) in
  let html := View.kanban_page_html "testhash" (List.cons t List.empty) in
  String.contains html "doing task" && String.contains html "action=\"/todos/1/status/todo\""
  && String.contains html "action=\"/todos/1/status/done\""

#[test]
def test_kanban_card_omits_move_buttons_at_the_ends : Bool :=
  let todo_t := ({ id := 1i64, title := "a", done := false,
    notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.todo } : Todo) in
  let done_t := ({ id := 2i64, title := "b", done := true,
    notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
    status := Status.done } : Todo) in
  let html := View.kanban_page_html "testhash" (List.cons todo_t (List.cons done_t List.empty)) in
  Bool.not (String.contains html "action=\"/todos/1/status/todo\"")
  && Bool.not (String.contains html "action=\"/todos/2/status/done\"")

#[test]
def test_footer_renders_counts_and_clear_completed_form : Bool :=
  let html := View.fragment_html Storage.seed in
  String.contains html "left" && String.contains html "action=\"/todos/clear-completed\""
