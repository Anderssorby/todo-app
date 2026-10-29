/// Todo domain type and pure list operations.
///
/// No mutable-state primitive exists anywhere in Monad's std (no
/// IORef/MVar/Cell — the missing-mutable-state gap is recorded in the
/// todo-app plan log),
/// so these are pure List->List transforms. The backend threads the actual
/// state through file-backed JSON; the wasm frontend threads it through
/// the JSON kernel. Both use these same operations.

use std::list {List.filter, List.length}
use lib::user {UserRef}

pub struct Subtask {
  id : I64,
  title : String,
  done : Bool
}

pub def Subtask.toggle (s : Subtask) : Subtask := { s with done := Bool.not s.done }

/// The kanban board's three columns. Independent of `Todo.done` (which
/// drives the plain task list's checkbox/hide-completed/clear-completed
/// behavior) but kept in sync with it by `Storage.toggle`/`Storage.set_status`
/// so the two views never visibly disagree.
pub type Status { todo, doing, done }

pub def Status.to_string (s : Status) : String :=
  match s { Status.todo => "todo", Status.doing => "doing", Status.done => "done" }

pub def Status.from_string (s : String) : Option Status :=
  if String.beq s "todo" then Option.some Status.todo
  else if String.beq s "doing" then Option.some Status.doing
  else if String.beq s "done" then Option.some Status.done
  else Option.none

pub def Status.eq (a : Status) (b : Status) : Bool :=
  String.beq (Status.to_string a) (Status.to_string b)

/// Clamped at `done`: the last column has no "forward" move.
pub def Status.next (s : Status) : Status :=
  match s { Status.todo => Status.doing, Status.doing => Status.done, Status.done => Status.done }

/// Clamped at `todo`: the first column has no "back" move.
pub def Status.prev (s : Status) : Status :=
  match s { Status.todo => Status.todo, Status.doing => Status.todo, Status.done => Status.doing }

pub struct Todo {
  id : I64,
  title : String,
  done : Bool,
  notes : String,
  tags : List String,
  group : Option String,
  subtasks : List Subtask,
  status : Status,
  /// A date or UTC ISO-8601 string; `None` means no due date.
  due_at : Option String,
  /// Server-owned audit fields (UTC ISO-8601 / display names).
  created_at : Option String,
  updated_at : Option String,
  created_by : Option UserRef,
  updated_by : Option UserRef
}

pub def Todo.toggle (t : Todo) : Todo :=
  let flipped := Bool.not t.done in
  { t with done := flipped, status := if flipped then Status.done else Status.todo }

pub def Storage.seed : List Todo :=
  List.cons ({ id := 1i64, title := "Learn Monad", done := false,
               notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
               status := Status.todo, due_at := Option.none,
               created_at := Option.none, updated_at := Option.none,
               created_by := Option.none, updated_by := Option.none } : Todo)
  (List.cons ({ id := 2i64, title := "Build a todo app", done := false,
                notes := "", tags := List.empty, group := Option.none, subtasks := List.empty,
                status := Status.todo, due_at := Option.none,
                created_at := Option.none, updated_at := Option.none,
                created_by := Option.none, updated_by := Option.none } : Todo)
  List.empty)

// Foldable.foldl (init/src/foldable.mo) is unresolvable from outside its
// own file (the foldable-traversable plan is only 50% done —
// no usage of it anywhere in the monad repo either), so this is plain
// recursion instead, matching List.sum's own style (std/src/list.mo).
def Storage.max_id (todos : List Todo) : I64 :=
  match todos {
    empty => 0i64,
    cons t rest => let m := Storage.max_id rest in if I64.gt t.id m then t.id else m,
  }

// Subtask ids are allocated from a single counter shared across every
// todo's subtasks (not per-parent): dispatch only ever carries a bare
// subtask id, never its parent todo id, so toggle/delete must find the
// match by scanning every todo's subtasks, which requires global
// uniqueness.
def Storage.max_subtask_id_in (subs : List Subtask) : I64 :=
  match subs {
    empty => 0i64,
    cons s rest => let m := Storage.max_subtask_id_in rest in if I64.gt s.id m then s.id else m,
  }

def Storage.max_subtask_id (todos : List Todo) : I64 :=
  match todos {
    empty => 0i64,
    cons t rest =>
      let m := Storage.max_subtask_id rest in
      let tm := Storage.max_subtask_id_in t.subtasks in
      if I64.gt tm m then tm else m,
  }

pub def Storage.add (title : String) (notes : String) (group : Option String)
    (tags : List String) (due_at : Option String) (todos : List Todo) : List Todo :=
  let next_id := I64.add (Storage.max_id todos) 1i64 in
  List.append todos (List.cons
    ({ id := next_id, title := title, done := false,
       notes := notes, tags := tags, group := group, subtasks := List.empty,
       status := Status.todo, due_at := due_at,
       created_at := Option.none, updated_at := Option.none,
       created_by := Option.none, updated_by := Option.none } : Todo)
    List.empty)

pub def Storage.toggle (id : I64) (todos : List Todo) : List Todo :=
  List.map (fn (t : Todo) => if t.id == id then Todo.toggle t else t) todos

/// The kanban move buttons. Keeps `done` in sync (moving a card to/from
/// "Done" should also check/uncheck it in the plain task list) the same
/// direction `Storage.toggle` already keeps `status` in sync.
pub def Storage.set_status (id : I64) (new_status : Status) (todos : List Todo) : List Todo :=
  List.map (fn (t : Todo) =>
    if t.id == id
    then { t with status := new_status, done := Status.eq new_status Status.done }
    else t) todos

pub def Storage.delete (id : I64) (todos : List Todo) : List Todo :=
  List.filter (fn (t : Todo) => Bool.not (t.id == id)) todos

pub def Storage.edit (id : I64) (title : String) (notes : String) (group : Option String)
    (tags : List String) (due_at : Option String) (todos : List Todo) : List Todo :=
  List.map (fn (t : Todo) =>
    if t.id == id
    then { t with title := title, notes := notes, group := group, tags := tags,
                  due_at := due_at }
    else t) todos

pub def Storage.add_subtask (todo_id : I64) (title : String) (todos : List Todo) : List Todo :=
  let next_id := I64.add (Storage.max_subtask_id todos) 1i64 in
  List.map (fn (t : Todo) =>
    if t.id == todo_id
    then { t with subtasks := List.append t.subtasks
      (List.cons ({ id := next_id, title := title, done := false } : Subtask) List.empty) }
    else t) todos

pub def Storage.toggle_subtask (sid : I64) (todos : List Todo) : List Todo :=
  List.map (fn (t : Todo) =>
    { t with subtasks := List.map (fn (s : Subtask) => if s.id == sid then Subtask.toggle s else s) t.subtasks })
    todos

pub def Storage.delete_subtask (sid : I64) (todos : List Todo) : List Todo :=
  List.map (fn (t : Todo) =>
    { t with subtasks := List.filter (fn (s : Subtask) => Bool.not (s.id == sid)) t.subtasks })
    todos

pub def Storage.clear_completed (todos : List Todo) : List Todo :=
  List.filter (fn (t : Todo) => Bool.not t.done) todos

#[test]
def test_add_assigns_incrementing_id : Bool :=
  let todos := Storage.add "first" "" Option.none List.empty Option.none List.empty in
  match List.first todos {
    Option.some t => t.id == 1i64 && t.title == "first" && Bool.not t.done,
    Option.none => false
  }

#[test]
def test_toggle_flips_done_for_matching_id : Bool :=
  let todos := Storage.toggle 1i64 Storage.seed in
  match List.first todos {
    Option.some t => t.id == 1i64 && t.done,
    Option.none => false
  }

#[test]
def test_delete_removes_matching_id : Bool :=
  let todos := Storage.delete 1i64 Storage.seed in
  List.length todos == 1i64

#[test]
def test_add_defaults_new_fields_empty : Bool :=
  let todos := Storage.add "first" "" Option.none List.empty Option.none List.empty in
  match List.first todos {
    Option.some t =>
      t.notes == "" && List.length t.tags == 0i64
      && (match t.group { Option.none => true, Option.some _ => false })
      && List.length t.subtasks == 0i64
      && (match t.due_at { Option.none => true, Option.some _ => false })
      && (match t.created_at { Option.none => true, Option.some _ => false })
      && (match t.created_by { Option.none => true, Option.some _ => false }),
    Option.none => false
  }

#[test]
def test_add_stores_due_and_form_fields : Bool :=
  let todos := Storage.add "first" "note" (Option.some "Work")
    (List.cons "a" List.empty) (Option.some "2026-11-01") List.empty in
  match List.first todos {
    Option.some t =>
      t.notes == "note" && List.length t.tags == 1i64
      && (match t.group { Option.some g => g == "Work", Option.none => false })
      && (match t.due_at { Option.some d => d == "2026-11-01", Option.none => false }),
    Option.none => false
  }

#[test]
def test_edit_updates_title_notes_group_tags : Bool :=
  let tags := List.cons "work" (List.cons "urgent" List.empty) in
  let todos := Storage.edit 1i64 "new title" "some notes" (Option.some "Work") tags
    (Option.some "2026-11-01") Storage.seed in
  match List.first todos {
    Option.some t =>
      t.title == "new title" && t.notes == "some notes"
      && (match t.group { Option.some g => g == "Work", Option.none => false })
      && List.length t.tags == 2i64
      && (match t.due_at { Option.some d => d == "2026-11-01", Option.none => false }),
    Option.none => false
  }

#[test]
def test_add_subtask_allocates_incrementing_id : Bool :=
  let todos := Storage.add_subtask 1i64 "step one" Storage.seed in
  match List.first todos {
    Option.some t => match List.first t.subtasks {
      Option.some s => s.id == 1i64 && s.title == "step one" && Bool.not s.done,
      Option.none => false
    },
    Option.none => false
  }

#[test]
def test_add_subtask_ids_stay_unique_across_different_parents : Bool :=
  let todos := Storage.add_subtask 2i64 "second parent's first subtask"
    (Storage.add_subtask 1i64 "first parent's first subtask" Storage.seed) in
  match List.first todos {
    Option.some first => match List.first (Storage.delete 1i64 todos) {
      Option.some second => match List.first first.subtasks {
        Option.some s1 => match List.first second.subtasks {
          Option.some s2 => Bool.not (s1.id == s2.id),
          Option.none => false
        },
        Option.none => false
      },
      Option.none => false
    },
    Option.none => false
  }

#[test]
def test_toggle_subtask_flips_done_regardless_of_parent : Bool :=
  let todos := Storage.toggle_subtask 1i64 (Storage.add_subtask 1i64 "step one" Storage.seed) in
  match List.first todos {
    Option.some t => match List.first t.subtasks {
      Option.some s => s.done,
      Option.none => false
    },
    Option.none => false
  }

#[test]
def test_delete_subtask_removes_matching_id_only : Bool :=
  let with_two := Storage.add_subtask 1i64 "two" (Storage.add_subtask 1i64 "one" Storage.seed) in
  let todos := Storage.delete_subtask 1i64 with_two in
  match List.first todos {
    Option.some t => List.length t.subtasks == 1i64,
    Option.none => false
  }

#[test]
def test_clear_completed_keeps_only_undone : Bool :=
  let todos := Storage.clear_completed (Storage.toggle 1i64 Storage.seed) in
  List.length todos == 1i64

#[test]
def test_status_round_trips_through_string : Bool :=
  (match Status.from_string "doing" { Option.some s => Status.eq s Status.doing, Option.none => false })
  && Status.to_string Status.done == "done"
  && (match Status.from_string "bogus" { Option.some _ => false, Option.none => true })

#[test]
def test_status_next_and_prev_clamp_at_the_ends : Bool :=
  Status.eq (Status.next Status.done) Status.done
  && Status.eq (Status.prev Status.todo) Status.todo
  && Status.eq (Status.next Status.todo) Status.doing
  && Status.eq (Status.prev Status.done) Status.doing

#[test]
def test_toggle_syncs_status_with_done : Bool :=
  let toggled_on := Storage.toggle 1i64 Storage.seed in
  let toggled_off := Storage.toggle 1i64 toggled_on in
  match List.first toggled_on {
    Option.some on_t => match List.first toggled_off {
      Option.some off_t => Status.eq on_t.status Status.done && Status.eq off_t.status Status.todo,
      Option.none => false
    },
    Option.none => false
  }

#[test]
def test_set_status_updates_status_and_syncs_done : Bool :=
  let todos := Storage.set_status 1i64 Status.done Storage.seed in
  match List.first todos {
    Option.some t => Status.eq t.status Status.done && t.done,
    Option.none => false
  }

#[test]
def test_set_status_to_non_done_clears_done : Bool :=
  let todos := Storage.set_status 1i64 Status.doing (Storage.set_status 1i64 Status.done Storage.seed) in
  match List.first todos {
    Option.some t => Status.eq t.status Status.doing && Bool.not t.done,
    Option.none => false
  }
