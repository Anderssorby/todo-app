/// The browser SPA: a real oak typed-event `Program` (mount/dispatch/tick,
/// diff/patch over the DOM) with pure handlers and no numeric decoder.
///
/// Every interaction is a typed `Html.on` attribute: clicks bind a constant
/// message, Enter in the single-line inputs submits, and kanban drag-and-drop
/// uses declarative `draggable`/`drag_payload`/`drop_effect` attributes with
/// `Html.on "dragstart"`/`"dragover"`/`"drop"` handlers. The SPA renders no
/// `<form>` at all: the add/edit/subtask controls are divs whose buttons are
/// `type="button"`, so nothing can submit or navigate.
///
/// All mutations post one JSON `Action` to `/api/actions`; the response is the
/// authoritative todo list. The initial load and the two-phase fetch poll are
/// driven by an animation-frame subscription, which the loader dispatches
/// immediately before `oak_tick` (there is no synthetic poll dispatch here).
///
/// Diagnostics go straight to `web_wasm::console.Console.log`, not the `log`
/// mote: `Logger.log`'s `json_lines` arm reaches `Json.to_string` ->
/// `F64.to_string`, which the web profile gates off, so linking `log` at all
/// breaks this target regardless of which format is actually used.
use todo_core::storage {Status, Subtask, Todo}
use todo_core::action {Action}
use todo_core::codec {Codec.todos_from_json, Codec.todos_to_json}
use todo_core::view {View.css, View.group_badge, View.tag_chip}
use oak::typed {Oak.Attr, Oak.Node}
use oak::elements {
  Html.attr, Html.button, Html.class_, Html.div, Html.draggable, Html.footer,
  Html.h1, Html.input, Html.key, Html.li, Html.name_, Html.nav, Html.node, Html.p,
  Html.placeholder, Html.required, Html.span, Html.text, Html.textarea, Html.type_,
  Html.ul, Html.value_
}
use oak::events {
  Html.drag_effect, Html.drag_payload, Html.drop_effect, Html.on, Html.on_change,
  Html.on_input, Subscription
}
use oak::app {Command, Host, Program}
use oak_wasm::program {Runtime.dispatch, Runtime.mount, Runtime.tick}
use web_event::event {HandlerResult, ListenerFlags, WebEvent}
use web_wasm::dom {Dom.append, Dom.create, Dom.query, Dom.set_text}
use web_wasm::fetch {Fetch.begin, Fetch.poll, Fetch.read}
use web_wasm::storage {Storage.get, Storage.set}
use web_wasm::console {Console.log}
use web_wasm::types {RequestId}
use std::list {
  List.contains_by, List.filter, List.filter_map, List.intercalate, List.length, List.sort_by
}
use xml_html::html {Html.Node}

// ── model / messages / effects ──────────────────────────────────────────

type Tab { tasks, kanban, settings, new_task, edit_task (id : I64) }

/// Which control's response a pending `Msg.loaded` belongs to. The load
/// clears only that control's draft (and, for add/edit, returns to the task
/// list).
type PendingForm {
  pending_add,
  pending_edit (id : I64),
  pending_subtask (id : I64),
}

struct Model {
  todos : List Todo,
  pending : Option RequestId,
  loaded : Bool,
  page : Tab,
  dark_mode : Bool,
  hide_completed : Bool,
  filter_group : Option String,
  filter_tag : Option String,
  new_title : String,
  edit_title : String,
  edit_notes : String,
  edit_group : String,
  edit_tags : String,
  subtask_drafts : List (Pair I64 String),
  subtask_generation : I64,
  pending_form : Option PendingForm,
  drag_id : Option I64,
  drag_over : Option Status
}

def Model.empty : Model :=
  { todos := List.empty, pending := Option.none, loaded := false,
    page := Tab.tasks, dark_mode := false, hide_completed := false,
    filter_group := Option.none, filter_tag := Option.none,
    new_title := "", edit_title := "", edit_notes := "", edit_group := "",
    edit_tags := "", subtask_drafts := List.empty, subtask_generation := 0i64,
    pending_form := Option.none, drag_id := Option.none, drag_over := Option.none }

type Msg {
  toggle (id : I64),
  delete (id : I64),
  toggle_subtask (id : I64),
  delete_subtask (id : I64),
  clear_completed,
  switch_tab (tab : Tab),
  toggle_dark_mode,
  toggle_hide_completed,
  move_status_prev (id : I64),
  move_status_next (id : I64),
  toggle_group_filter (idx : I64),
  toggle_tag_filter (idx : I64),
  clear_group_filter,
  clear_tag_filter,
  // Typing controls.
  set_new_title (text : String),
  submit_new,
  set_edit_title (text : String),
  set_edit_notes (text : String),
  set_edit_group (text : String),
  set_edit_tags (text : String),
  submit_edit (id : I64),
  set_subtask_title (id : I64) (text : String),
  submit_subtask (id : I64),
  // Drag-and-drop. `drag_start`/`drag_over_on` exist partly for the loader's
  // declarative `data-oak-drag`/drop-effect attributes (they are applied
  // inside a listener wrapper) and partly for the visual state: the dragged
  // card is dimmed and the hovered column is outlined.
  drag_start (id : I64),
  drag_over_on (status : Status),
  drag_end,
  drop_todo (status : Status) (raw : String),
  // Fetch lifecycle.
  poll,
  began (rid : RequestId),
  loaded (todos : List Todo),
  failed (reason : String)
}

type Effect {
  load,
  sync (action : Action),
  check (rid : RequestId),
  cache (todos : List Todo),
  save_prefs (dark : Bool) (hide : Bool)
}

def Spa.cache_key : String := "todo-app-state"
def Spa.dark_mode_key : String := "todo-app-dark-mode"
def Spa.hide_completed_key : String := "todo-app-hide-completed"

// ── view helpers ────────────────────────────────────────────────────────

def Spa.tab_class (active : Bool) : List String :=
  if active then ["tab", "active"] else ["tab"]

def Spa.is_page (page : Tab) (which : String) : Bool :=
  match page {
    Tab.tasks => String.beq which "tasks",
    Tab.kanban => String.beq which "kanban",
    Tab.settings => String.beq which "settings",
    Tab.new_task => false,
    Tab.edit_task _ => false,
  }

def Spa.nav (model : Model) : Oak.Node Msg :=
  Html.nav [Html.class_ ["tabs"]]
    [ Html.button
        [Spa.on_click (Msg.switch_tab Tab.tasks),
         Html.class_ (Spa.tab_class (Spa.is_page model.page "tasks"))]
        [Html.text "Tasks"],
      Html.button
        [Spa.on_click (Msg.switch_tab Tab.kanban),
         Html.class_ (Spa.tab_class (Spa.is_page model.page "kanban"))]
        [Html.text "Kanban"],
      Html.button
        [Spa.on_click (Msg.switch_tab Tab.settings),
         Html.class_ (Spa.tab_class (Spa.is_page model.page "settings"))]
        [Html.text "Settings"],
      Html.button
        [Spa.on_click (Msg.switch_tab Tab.new_task),
         Html.class_ ["tab", "nav-new"]]
        [Html.text "+ New"] ]

// ── typing-control state helpers ───────────────────────────────────────

def Spa.group_text (group : Option String) : String :=
  match group { Option.some g => g, Option.none => "" }

def Spa.tags_text (tags : List String) : String := List.intercalate ", " tags

// ── generic event attributes ────────────────────────────────────────────
//
// Every non-input interaction goes through `Html.on`. Buttons bind a
// constant message; Enter in a single-line input submits; dragover/drop ask
// for preventDefault because the browser decides whether a drop is allowed
// while the event is still dispatching.

def Spa.prevent_flags : ListenerFlags := { prevent_default := true }

def Spa.on_click (msg : Msg) : Oak.Attr Msg :=
  Html.on "click" ListenerFlags.none (fn (_e : WebEvent) => HandlerResult.msg msg)

def Spa.on_enter (msg : Msg) : Oak.Attr Msg :=
  Html.on "keydown" ListenerFlags.none (fn (e : WebEvent) =>
    if String.beq e.key "Enter" then HandlerResult.prevent msg else HandlerResult.ignore)

def Spa.subtask_draft (id : I64) (drafts : List (Pair I64 String)) : String :=
  match drafts {
    List.empty => "",
    List.cons entry rest =>
      match entry {
        Pair.pair key text => if key == id then text else Spa.subtask_draft id rest,
      },
  }

def Spa.set_subtask_draft (id : I64) (text : String)
    (drafts : List (Pair I64 String)) : List (Pair I64 String) :=
  match drafts {
    List.empty => List.cons (Pair.pair id text) List.empty,
    List.cons entry rest =>
      match entry {
        Pair.pair key existing =>
          if key == id
          then List.cons (Pair.pair id text) rest
          else List.cons (Pair.pair key existing) (Spa.set_subtask_draft id text rest),
      },
  }

def Spa.clear_subtask_draft (id : I64)
    (drafts : List (Pair I64 String)) : List (Pair I64 String) :=
  List.filter (fn (entry : Pair I64 String) =>
    match entry { Pair.pair key _text => Bool.not (key == id) }) drafts

// ── todo list ───────────────────────────────────────────────────────────

def Spa.subtask_row (s : Subtask) : Oak.Node Msg :=
  Html.li [Html.class_ (if s.done then ["subtask-row", "done"] else ["subtask-row"])]
    [ Html.button
        [Spa.on_click (Msg.toggle_subtask s.id), Html.class_ ["subtask-title"]]
        [Html.text s.title],
      Html.button
        [Spa.on_click (Msg.delete_subtask s.id), Html.class_ ["subtask-delete-form"]]
        [Html.text "x"] ]

/// The inline subtask controls are keyed by `subtask_generation`: a
/// controlled input's live value survives an attribute-only update once the
/// user has typed, so a successful submit bumps the generation to make the
/// keyed diff recreate the input (clearing it). The ul and the controls are
/// the wrapper's only children, so both carry a key.
def Spa.subtasks_block (model : Model) (t : Todo) : Oak.Node Msg :=
  let generation := model.subtask_generation in
  let controls := Html.div
    [ Html.key (String.concat "controls-" (I64.to_string generation)),
      Html.class_ ["subtask-add-form"] ]
    [ Html.input
        [ Html.name_ "title", Html.placeholder "Add a subtask",
          Html.required, Html.type_ "text",
          Html.value_ (Spa.subtask_draft t.id model.subtask_drafts),
          Html.on_input (fn (text : String) => Msg.set_subtask_title t.id text),
          Spa.on_enter (Msg.submit_subtask t.id) ],
      Html.button
        [Html.type_ "button", Spa.on_click (Msg.submit_subtask t.id)]
        [Html.text "+"] ] in
  if List.length t.subtasks == 0i64
  then Html.div List.empty (List.cons controls List.empty)
  else Html.div [Html.class_ ["subtasks"]]
    [ Html.ul [Html.key "list", Html.class_ ["subtask-list"]]
        (List.map Spa.subtask_row t.subtasks),
      controls ]

def Spa.item (model : Model) (t : Todo) : Oak.Node Msg :=
  let badge : Oak.Node Msg := View.group_badge t.group in
  let chips : List (Oak.Node Msg) := List.map (fn (tag : String) => View.tag_chip tag) t.tags in
  Html.li [Html.class_ (if t.done then ["todo", "done"] else ["todo"])]
    [ Html.div [Html.class_ ["todo-main"]]
        [ Html.button
            [Spa.on_click (Msg.toggle t.id), Html.class_ ["title"]]
            [Html.text t.title],
          Html.button [Spa.on_click (Msg.delete t.id)] [Html.text "x"],
          Html.button
            [Spa.on_click (Msg.switch_tab (Tab.edit_task t.id))]
            [Html.text "Edit"] ],
      Html.div [Html.class_ ["todo-meta"]] (List.append (List.cons badge List.empty) chips),
      Spa.subtasks_block model t ]

def Spa.matches_group (filter : Option String) (t : Todo) : Bool :=
  match filter {
    Option.some g => match t.group { Option.some tg => String.beq tg g, Option.none => false },
    Option.none => true,
  }

def Spa.matches_tag (filter : Option String) (t : Todo) : Bool :=
  match filter {
    Option.some tag => List.contains_by String.beq tag t.tags,
    Option.none => true,
  }

def Spa.visible_todos (model : Model) : List Todo :=
  let by_done := if model.hide_completed
    then List.filter (fn (t : Todo) => Bool.not t.done) model.todos
    else model.todos in
  let by_group := List.filter (Spa.matches_group model.filter_group) by_done in
  List.filter (Spa.matches_tag model.filter_tag) by_group

// ── tag/group filter bar ─────────────────────────────────────────────

def Spa.dedupe_sorted (xs : List String) : List String :=
  match xs {
    List.empty => List.empty,
    List.cons x rest => match rest {
      List.empty => List.cons x List.empty,
      List.cons y _ => if String.beq x y then Spa.dedupe_sorted rest else List.cons x (Spa.dedupe_sorted rest),
    },
  }

def Spa.distinct_groups (todos : List Todo) : List String :=
  Spa.dedupe_sorted (List.sort_by String.lt (List.filter_map (fn (t : Todo) => t.group) todos))

def Spa.distinct_tags (todos : List Todo) : List String :=
  Spa.dedupe_sorted (List.sort_by String.lt (List.flatten (List.map (fn (t : Todo) => t.tags) todos)))

def Spa.filter_chip (label : String) (active : Bool) (msg : Msg) : Oak.Node Msg :=
  Html.button
    [Spa.on_click msg,
     Html.class_ (if active then ["filter-chip", "active"] else ["filter-chip"])]
    [Html.text label]

def Spa.group_chip (filter : Option String) (indexed : Pair I64 String) : Oak.Node Msg :=
  match indexed {
    Pair.pair idx g =>
      let active := match filter { Option.some f => String.beq f g, Option.none => false } in
      Spa.filter_chip g active
        (if active then Msg.clear_group_filter else Msg.toggle_group_filter idx),
  }

def Spa.tag_chip_filter (filter : Option String) (indexed : Pair I64 String) : Oak.Node Msg :=
  match indexed {
    Pair.pair idx tag =>
      let active := match filter { Option.some f => String.beq f tag, Option.none => false } in
      Spa.filter_chip tag active
        (if active then Msg.clear_tag_filter else Msg.toggle_tag_filter idx),
  }

def Spa.indexed (xs : List String) : List (Pair I64 String) := Spa.indexed_go 0i64 xs

def Spa.indexed_go (i : I64) (xs : List String) : List (Pair I64 String) :=
  match xs {
    List.empty => List.empty,
    List.cons x rest => List.cons (Pair.pair i x) (Spa.indexed_go (i + 1i64) rest),
  }

def Spa.filter_bar (model : Model) : Oak.Node Msg :=
  let groups := Spa.distinct_groups model.todos in
  let tags := Spa.distinct_tags model.todos in
  Html.div [Html.class_ ["filter-bar"]]
    (List.append
      (List.map (Spa.group_chip model.filter_group) (Spa.indexed groups))
      (List.map (Spa.tag_chip_filter model.filter_tag) (Spa.indexed tags)))

def Spa.footer (model : Model) : Oak.Node Msg :=
  let remaining := List.length (List.filter (fn (t : Todo) => Bool.not t.done) model.todos) in
  Html.footer [Html.class_ ["app-footer"]]
    [ Html.span List.empty [Html.text (String.concat (I64.to_string remaining) " left")],
      Html.button
        [Spa.on_click Msg.clear_completed]
        [Html.text "Clear completed"] ]

def Spa.setting_row (label : String) (on : Bool) (msg : Msg) : Oak.Node Msg :=
  Html.div [Html.class_ ["setting-row"]]
    [ Html.span List.empty [Html.text label],
      Html.button [Spa.on_click msg, Html.class_ ["switch"]]
        [Html.text (if on then "On" else "Off")] ]

def Spa.settings_view (model : Model) : Oak.Node Msg :=
  Html.div [Html.class_ ["settings-tab"]]
    [ Spa.setting_row "Dark mode" model.dark_mode Msg.toggle_dark_mode,
      Spa.setting_row "Hide completed" model.hide_completed Msg.toggle_hide_completed ]

def Spa.tasks_view (model : Model) : Oak.Node Msg :=
  Html.div List.empty
    [ Spa.filter_bar model,
      Html.ul [Html.class_ ["todos"]] (List.map (Spa.item model) (Spa.visible_todos model)),
      Spa.footer model ]

// ── typing controls ─────────────────────────────────────────────────────

def Spa.add_controls (model : Model) : Oak.Node Msg :=
  Html.div [Html.class_ ["add-form"]]
    [ Html.input
        [ Html.name_ "title", Html.placeholder "New todo", Html.required,
          Html.type_ "text", Html.value_ model.new_title,
          Html.on_input (fn (text : String) => Msg.set_new_title text),
          Spa.on_enter Msg.submit_new ],
      Html.button
        [Html.type_ "button", Spa.on_click Msg.submit_new]
        [Html.text "Add"] ]

def Spa.new_task_view (model : Model) : Oak.Node Msg :=
  Html.div List.empty
    [ Html.button
        [Spa.on_click (Msg.switch_tab Tab.tasks), Html.class_ ["back-link"]]
        [Html.text "< Back to tasks"],
      Spa.add_controls model ]

def Spa.edit_controls (model : Model) (t : Todo) : Oak.Node Msg :=
  Html.div [Html.class_ ["edit-form"]]
    [ Html.input
        [ Html.name_ "title", Html.value_ model.edit_title, Html.required,
          Html.type_ "text", Html.placeholder "Title",
          Html.on_input (fn (text : String) => Msg.set_edit_title text),
          Spa.on_enter (Msg.submit_edit t.id) ],
      Html.textarea
        [ Html.name_ "notes", Html.placeholder "Notes",
          // `change`, not `input`: a textarea's value is its text content,
          // and re-rendering text content on every keystroke would reset the
          // caret. Clicking Save blurs it first, so the change message is
          // folded before the button's click message.
          Html.on_change (fn (text : String) => Msg.set_edit_notes text) ]
        [Html.text model.edit_notes],
      Html.input
        [ Html.name_ "group", Html.value_ model.edit_group, Html.type_ "text",
          Html.placeholder "Group",
          Html.on_input (fn (text : String) => Msg.set_edit_group text),
          Spa.on_enter (Msg.submit_edit t.id) ],
      Html.input
        [ Html.name_ "tags", Html.value_ model.edit_tags, Html.type_ "text",
          Html.placeholder "Tags (comma separated)",
          Html.on_input (fn (text : String) => Msg.set_edit_tags text),
          Spa.on_enter (Msg.submit_edit t.id) ],
      Html.button
        [Html.type_ "button", Spa.on_click (Msg.submit_edit t.id)]
        [Html.text "Save"] ]

def Spa.find_todo (id : I64) (todos : List Todo) : Option Todo :=
  List.first (List.filter (fn (t : Todo) => t.id == id) todos)

def Spa.edit_task_view (model : Model) (id : I64) : Oak.Node Msg :=
  let back := Html.button
    [Spa.on_click (Msg.switch_tab Tab.tasks), Html.class_ ["back-link"]]
    [Html.text "< Back to tasks"] in
  match Spa.find_todo id model.todos {
    Option.some t => Html.div List.empty [back, Spa.edit_controls model t],
    Option.none =>
      Html.div List.empty
        [back, Html.p [Html.class_ ["not-found"]] [Html.text "That task was not found."]],
  }

// ── kanban board ─────────────────────────────────────────────────────

def Spa.dragging_card (id : I64) (dragged : Option I64) : Bool :=
  match dragged { Option.some d => d == id, Option.none => false }

def Spa.drag_over_column (status : Status) (hovered : Option Status) : Bool :=
  match hovered { Option.some s => Status.eq s status, Option.none => false }

def Spa.kanban_moves (t : Todo) : Oak.Node Msg :=
  let backward := match t.status { Status.todo => List.empty,
    _ => List.cons
      (Html.button
        [Html.type_ "button", Spa.on_click (Msg.move_status_prev t.id)]
        [Html.text "<"])
      List.empty } in
  let forward := match t.status { Status.done => List.empty,
    _ => List.cons
      (Html.button
        [Html.type_ "button", Spa.on_click (Msg.move_status_next t.id)]
        [Html.text ">"])
      List.empty } in
  Html.div [Html.class_ ["kanban-move"]] (List.append backward forward)

/// A card is a drag source: `drag_payload` carries the todo id, which the
/// column's drop handler parses with `Action.parse_id`. The card is dimmed
/// while it is the one being dragged.
def Spa.kanban_card (model : Model) (t : Todo) : Oak.Node Msg :=
  let badge : Oak.Node Msg := View.group_badge t.group in
  let chips : List (Oak.Node Msg) := List.map (fn (tag : String) => View.tag_chip tag) t.tags in
  Html.div
    [ Html.class_ (if Spa.dragging_card t.id model.drag_id
        then ["kanban-card", "dragging"] else ["kanban-card"]),
      Html.draggable true,
      Html.drag_payload "text/plain" (I64.to_string t.id),
      Html.drag_effect "move",
      Html.on "dragstart" ListenerFlags.none
        (fn (_e : WebEvent) => HandlerResult.msg (Msg.drag_start t.id)),
      Html.on "dragend" ListenerFlags.none
        (fn (_e : WebEvent) => HandlerResult.msg Msg.drag_end) ]
    [ Html.span [Html.class_ ["kanban-title"]] [Html.text t.title],
      Html.div [Html.class_ ["todo-meta"]] (List.append (List.cons badge List.empty) chips),
      Spa.kanban_moves t ]

/// A column is a drop target; `dragover` both enables the drop and marks the
/// column the cursor is over, which the view renders as a highlighted border.
def Spa.kanban_column (model : Model) (status : Status) (label : String)
    (todos : List Todo) : Oak.Node Msg :=
  Html.div
    [ Html.class_ (if Spa.drag_over_column status model.drag_over
        then ["kanban-column", "drag-over"] else ["kanban-column"]),
      Html.on "dragover" Spa.prevent_flags
        (fn (_e : WebEvent) => HandlerResult.prevent (Msg.drag_over_on status)),
      Html.drop_effect "move",
      Html.on "drop" Spa.prevent_flags
        (fn (e : WebEvent) => HandlerResult.prevent (Msg.drop_todo status e.data)) ]
    [ Html.node "h2" List.empty [Html.text label],
      Html.div List.empty
        (List.map (Spa.kanban_card model)
          (List.filter (fn (t : Todo) => Status.eq t.status status) todos)) ]

def Spa.kanban_view (model : Model) : Oak.Node Msg :=
  Html.div [Html.class_ ["kanban-board"]]
    [ Spa.kanban_column model Status.todo "To do" model.todos,
      Spa.kanban_column model Status.doing "Doing" model.todos,
      Spa.kanban_column model Status.done "Done" model.todos ]

def Spa.view (model : Model) : Oak.Node Msg :=
  Html.div
    [ Html.class_ ["todo-app"],
      Html.attr "data-theme" (if model.dark_mode then "dark" else "light") ]
    [ Html.h1 List.empty [Html.text "todo-app"],
      Spa.nav model,
      match model.page {
        Tab.tasks => Spa.tasks_view model,
        Tab.kanban => Spa.kanban_view model,
        Tab.settings => Spa.settings_view model,
        Tab.new_task => Spa.new_task_view model,
        Tab.edit_task id => Spa.edit_task_view model id,
      } ]

// ── update ───────────────────────────────────────────────────────────

def Spa.update (model : Model) (msg : Msg) : Pair Model (Command Effect Msg) :=
  match msg {
    Msg.toggle id =>
      let next := { model with todos := Action.apply (Action.toggle id) model.todos } in
      Pair.pair next (Command.perform (Effect.sync (Action.toggle id))),
    Msg.delete id =>
      let next := { model with todos := Action.apply (Action.delete id) model.todos } in
      Pair.pair next (Command.perform (Effect.sync (Action.delete id))),
    Msg.toggle_subtask id =>
      let next := { model with todos := Action.apply (Action.toggle_subtask id) model.todos } in
      Pair.pair next (Command.perform (Effect.sync (Action.toggle_subtask id))),
    Msg.delete_subtask id =>
      let next := { model with todos := Action.apply (Action.delete_subtask id) model.todos } in
      Pair.pair next (Command.perform (Effect.sync (Action.delete_subtask id))),
    Msg.clear_completed =>
      let next := { model with todos := Action.apply Action.clear_completed model.todos } in
      Pair.pair next (Command.perform (Effect.sync Action.clear_completed)),
    Msg.switch_tab tab =>
      match tab {
        Tab.edit_task id =>
          match Spa.find_todo id model.todos {
            Option.some t =>
              Pair.pair { model with page := Tab.edit_task id,
                edit_title := t.title, edit_notes := t.notes,
                edit_group := Spa.group_text t.group, edit_tags := Spa.tags_text t.tags }
                Command.none,
            Option.none =>
              Pair.pair { model with page := Tab.edit_task id,
                edit_title := "", edit_notes := "", edit_group := "", edit_tags := "" }
                Command.none,
          },
        Tab.new_task =>
          Pair.pair { model with page := Tab.new_task, new_title := "" } Command.none,
        Tab.tasks => Pair.pair { model with page := Tab.tasks } Command.none,
        Tab.kanban => Pair.pair { model with page := Tab.kanban } Command.none,
        Tab.settings => Pair.pair { model with page := Tab.settings } Command.none,
      },
    Msg.toggle_dark_mode =>
      let next := { model with dark_mode := Bool.not model.dark_mode } in
      Pair.pair next (Command.perform (Effect.save_prefs next.dark_mode next.hide_completed)),
    Msg.toggle_hide_completed =>
      let next := { model with hide_completed := Bool.not model.hide_completed } in
      Pair.pair next (Command.perform (Effect.save_prefs next.dark_mode next.hide_completed)),
    Msg.move_status_prev id =>
      match Spa.find_todo id model.todos {
        Option.some t =>
          let target := Status.prev t.status in
          let next := { model with todos := Action.apply (Action.set_status id target) model.todos } in
          Pair.pair next (Command.perform (Effect.sync (Action.set_status id target))),
        Option.none => Pair.pair model Command.none,
      },
    Msg.move_status_next id =>
      match Spa.find_todo id model.todos {
        Option.some t =>
          let target := Status.next t.status in
          let next := { model with todos := Action.apply (Action.set_status id target) model.todos } in
          Pair.pair next (Command.perform (Effect.sync (Action.set_status id target))),
        Option.none => Pair.pair model Command.none,
      },
    Msg.toggle_group_filter idx =>
      match Spa.nth (Spa.distinct_groups model.todos) idx {
        Option.some g =>
          let already_active := match model.filter_group {
            Option.some f => String.beq f g, Option.none => false } in
          Pair.pair { model with filter_group := if already_active then Option.none else Option.some g }
            Command.none,
        Option.none => Pair.pair model Command.none,
      },
    Msg.toggle_tag_filter idx =>
      match Spa.nth (Spa.distinct_tags model.todos) idx {
        Option.some tag =>
          let already_active := match model.filter_tag {
            Option.some f => String.beq f tag, Option.none => false } in
          Pair.pair { model with filter_tag := if already_active then Option.none else Option.some tag }
            Command.none,
        Option.none => Pair.pair model Command.none,
      },
    Msg.clear_group_filter => Pair.pair { model with filter_group := Option.none } Command.none,
    Msg.clear_tag_filter => Pair.pair { model with filter_tag := Option.none } Command.none,
    Msg.set_new_title text =>
      Pair.pair { model with new_title := text } Command.none,
    Msg.submit_new =>
      if String.beq (String.trim model.new_title) ""
      then Pair.pair model Command.none
      else Pair.pair { model with pending_form := Option.some PendingForm.pending_add }
        (Command.perform (Effect.sync (Action.add model.new_title))),
    Msg.set_edit_title text =>
      Pair.pair { model with edit_title := text } Command.none,
    Msg.set_edit_notes text =>
      Pair.pair { model with edit_notes := text } Command.none,
    Msg.set_edit_group text =>
      Pair.pair { model with edit_group := text } Command.none,
    Msg.set_edit_tags text =>
      Pair.pair { model with edit_tags := text } Command.none,
    Msg.submit_edit id =>
      if String.beq (String.trim model.edit_title) ""
      then Pair.pair model Command.none
      else Pair.pair { model with pending_form := Option.some (PendingForm.pending_edit id) }
        (Command.perform (Effect.sync
          (Action.edit id model.edit_title model.edit_notes
            (Action.group_of_text model.edit_group) (Action.tags_of_text model.edit_tags)))),
    Msg.set_subtask_title id text =>
      Pair.pair { model with
        subtask_drafts := Spa.set_subtask_draft id text model.subtask_drafts } Command.none,
    Msg.submit_subtask id =>
      let draft := Spa.subtask_draft id model.subtask_drafts in
      if String.beq (String.trim draft) ""
      then Pair.pair model Command.none
      else Pair.pair { model with pending_form := Option.some (PendingForm.pending_subtask id) }
        (Command.perform (Effect.sync (Action.add_subtask id draft))),
    Msg.drag_start id =>
      Pair.pair { model with drag_id := Option.some id, drag_over := Option.none } Command.none,
    Msg.drag_over_on status =>
      Pair.pair { model with drag_over := Option.some status } Command.none,
    Msg.drag_end =>
      Pair.pair { model with drag_id := Option.none, drag_over := Option.none } Command.none,
    Msg.drop_todo status raw =>
      match Action.parse_id raw {
        Option.some id =>
          let next := { model with
            todos := Action.apply (Action.set_status id status) model.todos,
            drag_id := Option.none, drag_over := Option.none } in
          Pair.pair next (Command.perform (Effect.sync (Action.set_status id status))),
        Option.none =>
          Pair.pair { model with drag_id := Option.none, drag_over := Option.none } Command.none,
      },
    Msg.poll =>
      match model.pending {
        Option.some rid => Pair.pair model (Command.perform (Effect.check rid)),
        Option.none =>
          if model.loaded
          then Pair.pair model Command.none
          else Pair.pair { model with loaded := true } (Command.perform Effect.load),
      },
    Msg.began rid =>
      Pair.pair { model with pending := Option.some rid } Command.none,
    Msg.loaded todos =>
      let base := { model with todos := todos, pending := Option.none } in
      match model.pending_form {
        Option.some form => match form {
          PendingForm.pending_add =>
            Pair.pair { base with new_title := "", pending_form := Option.none,
              page := Tab.tasks } (Command.perform (Effect.cache todos)),
          PendingForm.pending_edit _id =>
            Pair.pair { base with edit_title := "", edit_notes := "", edit_group := "",
              edit_tags := "", pending_form := Option.none, page := Tab.tasks }
              (Command.perform (Effect.cache todos)),
          PendingForm.pending_subtask id =>
            Pair.pair { base with
              subtask_drafts := Spa.clear_subtask_draft id base.subtask_drafts,
              subtask_generation := base.subtask_generation + 1i64,
              pending_form := Option.none } (Command.perform (Effect.cache todos)),
        },
        Option.none =>
          Pair.pair base (Command.perform (Effect.cache todos)),
      },
    Msg.failed _reason =>
      Pair.pair { model with pending := Option.none, pending_form := Option.none } Command.none,
  }

// ── effects ──────────────────────────────────────────────────────────

def Spa.nth (xs : List String) (idx : I64) : Option String :=
  match xs {
    List.empty => Option.none,
    List.cons x rest => if idx == 0i64 then Option.some x else Spa.nth rest (idx - 1i64),
  }

def Spa.resolve (rid : RequestId) : IO (Option Msg) := do {
  let state <- Fetch.poll rid;
  if state == 0i64
  then return Option.none
  else if state == 1i64
  then do {
    let body <- Fetch.read rid 1000000i64;
    match Codec.todos_from_json body {
      Option.some todos => return (Option.some (Msg.loaded todos)),
      Option.none => do {
        let _ <- Console.log ("todo-spa WARN unparseable response: " ++ body);
        return (Option.some (Msg.failed "unparseable response"))
      },
    }
  }
  else do {
    let _ <- Console.log "todo-spa WARN fetch failed";
    return (Option.some (Msg.failed "fetch failed"))
  }
}

def Spa.run_effect (effect : Effect) : IO (Option Msg) :=
  match effect {
    Effect.load => do {
      let rid <- Fetch.begin "/api/todos" 0i64 "";
      return (Option.some (Msg.began rid))
    },
    Effect.sync action => do {
      let rid <- Fetch.begin "/api/actions" 1i64 (Action.to_json action);
      return (Option.some (Msg.began rid))
    },
    Effect.check rid => Spa.resolve rid,
    Effect.cache todos => do {
      let _ <- Storage.set Spa.cache_key (Codec.todos_to_json todos);
      return Option.none
    },
    Effect.save_prefs dark hide => do {
      let _ <- Storage.set Spa.dark_mode_key (if dark then "1" else "0");
      let _ <- Storage.set Spa.hide_completed_key (if hide then "1" else "0");
      return Option.none
    },
  }

// ── wiring ───────────────────────────────────────────────────────────

/// The animation-frame subscription is the fetch pump, not a heartbeat: the
/// loader dispatches `Msg.poll` once per frame before `oak_tick`, which is
/// what advances a two-phase fetch (and starts the initial load).
///
/// Install it ONLY while there is work for it. `Runtime.tick` re-renders and
/// diffs the whole view for any dispatched message, and the web runtime's
/// bump allocator never reclaims: an always-on frame subscription therefore
/// rebuilt the tree every animation frame, growing linear memory by ~12 MB/s
/// while the page sat idle. Past 2 GiB the loader's sign-extended string
/// pointers surfaced as `RangeError: invalid or out-of-range index` in the
/// middle of a patch. With no outstanding request the queue stays empty,
/// `oak_tick` is a comparison, and the heap is flat.
def Spa.subs (m : Model) : List (Subscription Msg) :=
  match m.pending {
    Option.some _ => [ Subscription.animation_frame_msg Msg.poll ],
    Option.none =>
      if m.loaded
      then List.empty
      else [ Subscription.animation_frame_msg Msg.poll ],
  }

def Spa.program (init : Model) : Program Model Msg Effect :=
  Program.with_subs init Spa.update Spa.view Spa.subs

def app : Program Model Msg Effect := Spa.program Model.empty

def host : Host IO Effect Msg := Host.host Spa.run_effect

def Spa.model_from_cache (cached : Option String) : Model :=
  match cached {
    Option.some text => match Codec.todos_from_json text {
      Option.some todos => { Model.empty with todos := todos },
      Option.none => Model.empty,
    },
    Option.none => Model.empty,
  }

def Spa.flag_is_set (raw : Option String) : Bool :=
  match raw { Option.some v => String.beq v "1", Option.none => false }

#[export "c"]
def oak_mount : IO Unit := do {
  let cached <- Storage.get Spa.cache_key;
  let dark_raw <- Storage.get Spa.dark_mode_key;
  let hide_raw <- Storage.get Spa.hide_completed_key;
  let from_cache := Spa.model_from_cache cached;
  let initial := { from_cache with
    dark_mode := Spa.flag_is_set dark_raw,
    hide_completed := Spa.flag_is_set hide_raw };
  // `web/index.html`'s own <style> is a tiny stub; the real themed CSS is
  // `View.css`, defined once in todo-core and otherwise only embedded in
  // the no-JS page's <style> tag. Inject it here so the live SPA is
  // styled identically, rather than duplicating the string.
  let head <- Dom.query "head";
  let style_node <- Dom.create "style";
  let _ <- Dom.set_text style_node View.css;
  let _ <- Dom.append head style_node;
  let _ <- Console.log "todo-spa INFO mounted";
  Runtime.mount (Spa.program initial)
}

#[export "c"]
def oak_dispatch_event (handler : I64) : IO Unit := Runtime.dispatch handler

#[export "c"]
def oak_tick : IO Unit := Runtime.tick app host

def main : IO Unit := IO.pure unit
