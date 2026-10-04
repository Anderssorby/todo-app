/// Todo domain type and pure list operations.
///
/// No mutable-state primitive exists anywhere in Monad's std (no
/// IORef/MVar/Cell — see plans-monad/implementations for the filed gap),
/// so these are pure List->List transforms; main.mo threads the actual
/// state through file-backed JSON (added at M3).

use std::list {List.filter, List.length}

struct Todo {
  id : I64,
  title : String,
  done : Bool
}

def Todo.toggle (t : Todo) : Todo := { t with done := Bool.not t.done }

def Storage.seed : List Todo :=
  List.cons ({ id := 1i64, title := "Learn Monad", done := false } : Todo)
  (List.cons ({ id := 2i64, title := "Build a todo app", done := false } : Todo)
  List.empty)

// Foldable.foldl (init/src/foldable.mo) is unresolvable from outside its
// own file (plans-monad's foldable-traversable plan is only 50% done —
// no usage of it anywhere in the monad repo either), so this is plain
// recursion instead, matching List.sum's own style (std/src/list.mo).
def Storage.max_id (todos : List Todo) : I64 :=
  match todos {
    empty => 0i64,
    cons t rest => let m := Storage.max_id rest in if I64.gt t.id m then t.id else m,
  }

def Storage.add (title : String) (todos : List Todo) : List Todo :=
  let next_id := I64.add (Storage.max_id todos) 1i64 in
  List.append todos (List.cons ({ id := next_id, title := title, done := false } : Todo) List.empty)

def Storage.toggle (id : I64) (todos : List Todo) : List Todo :=
  List.map (fn (t : Todo) => if t.id == id then Todo.toggle t else t) todos

def Storage.delete (id : I64) (todos : List Todo) : List Todo :=
  List.filter (fn (t : Todo) => Bool.not (t.id == id)) todos

#[test]
def test_add_assigns_incrementing_id : Bool :=
  let todos := Storage.add "first" List.empty in
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
