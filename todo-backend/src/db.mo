/// SQLite persistence, users, sessions and OAuth state.
///
/// The workspace is shared: todos have no per-user ownership, only
/// `created_by`/`updated_by` attribution. Every mutation is one
/// `BEGIN IMMEDIATE` transaction that loads the whole list, applies the
/// shared `Action`, stamps attribution/timestamps, and rewrites the rows.
/// That keeps `Action.apply` as the single mutation semantics and makes
/// concurrent handler fibers serialize instead of losing updates.
///
/// The `sqlite` driver is `#[extern "c"]`/compiled-backend-only, so this
/// module lives in the backend and never in `todo-core` (which is also
/// compiled for wasm).
use todo_core::storage {Status, Subtask, Todo}
use todo_core::action {Action}
use todo_core::user {OauthState, OidcIdentity, User, UserRef}
use sql::value {ResultSet, Row, SqlError, SqlResult.and_then, Value}
use sql::migrations {Migration, Migrations.migration}
use sqlite::conn {SqliteConn, Sqlite.close, Sqlite.connect}
use sqlite::backend {Sqlite.exec_io, Sqlite.exec_script_io, Sqlite.query_io}
use sqlite::monad {SqliteM, SqliteM.run, Sqlite.exec, Sqlite.query, Sqlite.transaction}
use sqlite::migrations {Sqlite.migrate}
use std::path {Path}
use std::list {List.filter, List.length}

pub struct Store {
  db_path : String
}

// ─── Schema ─────────────────────────────────────────────────────────────

def Db.schema_sql : String := String.concat_list [
  "CREATE TABLE users (",
    "id INTEGER PRIMARY KEY, issuer TEXT NOT NULL, subject TEXT NOT NULL,",
    "email TEXT, name TEXT NOT NULL DEFAULT '', picture TEXT,",
    "timezone TEXT NOT NULL DEFAULT 'UTC',",
    "created_at TEXT NOT NULL, updated_at TEXT NOT NULL,",
    "UNIQUE (issuer, subject)); ",
  "CREATE TABLE sessions (",
    "id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,",
    "csrf_token TEXT NOT NULL, created_at TEXT NOT NULL, expires_at TEXT NOT NULL); ",
  "CREATE INDEX idx_sessions_user ON sessions(user_id); ",
  "CREATE TABLE oauth_states (",
    "state TEXT PRIMARY KEY, nonce TEXT NOT NULL, code_verifier TEXT NOT NULL,",
    "redirect_to TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL); ",
  "CREATE TABLE todos (",
    "id INTEGER PRIMARY KEY, position INTEGER NOT NULL,",
    "title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0,1)),",
    "notes TEXT NOT NULL DEFAULT '', group_name TEXT,",
    "status TEXT NOT NULL DEFAULT 'todo' CHECK (status IN ('todo','doing','done')),",
    "due_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,",
    "created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,",
    "updated_by INTEGER REFERENCES users(id) ON DELETE SET NULL); ",
  "CREATE INDEX idx_todos_position ON todos(position); ",
  "CREATE TABLE subtasks (",
    "id INTEGER PRIMARY KEY, todo_id INTEGER NOT NULL REFERENCES todos(id) ON DELETE CASCADE,",
    "position INTEGER NOT NULL, title TEXT NOT NULL,",
    "done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0,1))); ",
  "CREATE INDEX idx_subtasks_todo ON subtasks(todo_id, position); ",
  "CREATE TABLE tags (name TEXT PRIMARY KEY); ",
  "CREATE TABLE todo_tags (",
    "todo_id INTEGER NOT NULL REFERENCES todos(id) ON DELETE CASCADE,",
    "tag TEXT NOT NULL REFERENCES tags(name) ON DELETE CASCADE,",
    "position INTEGER NOT NULL, PRIMARY KEY (todo_id, position)); ",
  "CREATE INDEX idx_todo_tags_todo ON todo_tags(todo_id, position); ",
  "CREATE INDEX idx_todo_tags_tag ON todo_tags(tag);"
]

def Db.down_sql : String := String.concat_list [
  "DROP TABLE IF EXISTS todo_tags; ",
  "DROP TABLE IF EXISTS subtasks; ",
  "DROP TABLE IF EXISTS todos; ",
  "DROP TABLE IF EXISTS tags; ",
  "DROP TABLE IF EXISTS oauth_states; ",
  "DROP TABLE IF EXISTS sessions; ",
  "DROP TABLE IF EXISTS users;"
]

pub def Db.migration : Migration :=
  Migrations.migration 1i64 "initial_schema" Db.schema_sql (Option.some Db.down_sql)

pub def Db.migrations : List Migration := List.cons Db.migration List.empty

// ─── Queries ────────────────────────────────────────────────────────────

def Db.todos_sql : String :=
  "SELECT t.id AS id, t.title AS title, t.done AS done, t.notes AS notes, " ++
  "t.group_name AS group_name, t.status AS status, t.due_at AS due_at, " ++
  "t.created_at AS created_at, t.updated_at AS updated_at, " ++
  "t.created_by AS created_by, cu.name AS created_by_name, " ++
  "t.updated_by AS updated_by, uu.name AS updated_by_name " ++
  "FROM todos t LEFT JOIN users cu ON cu.id = t.created_by " ++
  "LEFT JOIN users uu ON uu.id = t.updated_by " ++
  "ORDER BY t.position ASC, t.id ASC"

def Db.subtasks_sql : String :=
  "SELECT todo_id AS todo_id, id AS id, title AS title, done AS done " ++
  "FROM subtasks ORDER BY todo_id ASC, position ASC"

def Db.tags_sql : String :=
  "SELECT todo_id AS todo_id, tag AS tag FROM todo_tags ORDER BY todo_id ASC, position ASC"

def Db.insert_todo_sql : String :=
  "INSERT INTO todos (id, position, title, done, notes, group_name, status, " ++
  "due_at, created_at, updated_at, created_by, updated_by) " ++
  "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

def Db.insert_subtask_sql : String :=
  "INSERT INTO subtasks (id, todo_id, position, title, done) VALUES (?, ?, ?, ?, ?)"

def Db.insert_tag_sql : String := "INSERT OR IGNORE INTO tags (name) VALUES (?)"

def Db.insert_todo_tag_sql : String :=
  "INSERT INTO todo_tags (todo_id, tag, position) VALUES (?, ?, ?)"

// ─── Value helpers ──────────────────────────────────────────────────────

def Db.opt_text_value (o : Option String) : Value :=
  match o { Option.some s => Value.text s, Option.none => Value.null }

def Db.opt_ref_value (o : Option UserRef) : Value :=
  match o { Option.some r => Value.integer r.id, Option.none => Value.null }

def Db.optional_text (row : Row) (name : String) : Result SqlError (Option String) :=
  match Row.get row name {
    Option.none => Result.ok Option.none,
    Option.some v => match v {
      Value.null => Result.ok Option.none,
      Value.text s => Result.ok (Option.some s),
      _ => Result.err (SqlError.type_mismatch ("expected text or null: " ++ name)),
    },
  }

def Db.optional_i64 (row : Row) (name : String) : Result SqlError (Option I64) :=
  match Row.get row name {
    Option.none => Result.ok Option.none,
    Option.some v => match v {
      Value.null => Result.ok Option.none,
      Value.integer i => Result.ok (Option.some i),
      _ => Result.err (SqlError.type_mismatch ("expected integer or null: " ++ name)),
    },
  }

def Db.user_ref_of_optional (id : Option I64) (name : Option String) : Option UserRef :=
  match id {
    Option.some i =>
      let n : String := Option.get_or_default "" name in
      let r : UserRef := { id := i, name := n } in
      Option.some r,
    Option.none => Option.none,
  }

def Db.status_of (raw : String) (done : Bool) : Status :=
  match Status.from_string raw {
    Option.some s => s,
    Option.none => if done then Status.done else Status.todo,
  }

// ─── Row decoding ───────────────────────────────────────────────────────

def Db.decode_todo_row (row : Row) : Result SqlError Todo :=
  SqlResult.and_then (Row.get_i64 row "id") (fn (id : I64) =>
    SqlResult.and_then (Row.get_text row "title") (fn (title : String) =>
      SqlResult.and_then (Row.get_bool row "done") (fn (done : Bool) =>
        SqlResult.and_then (Row.get_text row "notes") (fn (notes : String) =>
          SqlResult.and_then (Row.get_text row "status") (fn (status : String) =>
            SqlResult.and_then (Db.optional_text row "group_name") (fn (group : Option String) =>
              SqlResult.and_then (Db.optional_text row "due_at") (fn (due : Option String) =>
                SqlResult.and_then (Db.optional_text row "created_at") (fn (created : Option String) =>
                  SqlResult.and_then (Db.optional_text row "updated_at") (fn (updated : Option String) =>
                    SqlResult.and_then (Db.optional_i64 row "created_by") (fn (cid : Option I64) =>
                      SqlResult.and_then (Db.optional_text row "created_by_name") (fn (cname : Option String) =>
                        SqlResult.and_then (Db.optional_i64 row "updated_by") (fn (uid : Option I64) =>
                          SqlResult.and_then (Db.optional_text row "updated_by_name") (fn (uname : Option String) =>
                            Result.ok ({
                              id := id, title := title, done := done, notes := notes,
                              tags := List.empty, group := group, subtasks := List.empty,
                              status := Db.status_of status done, due_at := due,
                              created_at := created, updated_at := updated,
                              created_by := Db.user_ref_of_optional cid cname,
                              updated_by := Db.user_ref_of_optional uid uname
                            } : Todo))))))))))))))

def Db.decode_subtask_row (row : Row) : Result SqlError (Pair I64 Subtask) :=
  SqlResult.and_then (Row.get_i64 row "todo_id") (fn (tid : I64) =>
    SqlResult.and_then (Row.get_i64 row "id") (fn (id : I64) =>
      SqlResult.and_then (Row.get_text row "title") (fn (title : String) =>
        SqlResult.and_then (Row.get_bool row "done") (fn (done : Bool) =>
          let s : Subtask := { id := id, title := title, done := done } in
          Result.ok (Pair.pair tid s)))))

def Db.decode_tag_row (row : Row) : Result SqlError (Pair I64 String) :=
  SqlResult.and_then (Row.get_i64 row "todo_id") (fn (tid : I64) =>
    SqlResult.and_then (Row.get_text row "tag") (fn (tag : String) =>
      Result.ok (Pair.pair tid tag)))

def Db.decode_user_row (row : Row) : Result SqlError User :=
  SqlResult.and_then (Row.get_i64 row "id") (fn (id : I64) =>
    SqlResult.and_then (Row.get_text row "issuer") (fn (issuer : String) =>
      SqlResult.and_then (Row.get_text row "subject") (fn (subject : String) =>
        SqlResult.and_then (Db.optional_text row "email") (fn (email : Option String) =>
          SqlResult.and_then (Row.get_text row "name") (fn (name : String) =>
            SqlResult.and_then (Db.optional_text row "picture") (fn (picture : Option String) =>
              SqlResult.and_then (Row.get_text row "timezone") (fn (timezone : String) =>
                SqlResult.and_then (Row.get_text row "created_at") (fn (created : String) =>
                  SqlResult.and_then (Row.get_text row "updated_at") (fn (updated : String) =>
                    Result.ok ({
                      id := id, issuer := issuer, subject := subject, email := email,
                      name := name, picture := picture, timezone := timezone,
                      created_at := created, updated_at := updated
                    } : User))))))))))

#[terminating]
def Db.decode_list {A : Type} (f : Row -> Result SqlError A) (rows : List Row)
    : Result SqlError (List A) :=
  match rows {
    List.empty => Result.ok List.empty,
    List.cons row rest =>
      match f row {
        Result.err e => Result.err e,
        Result.ok a => match Db.decode_list f rest {
          Result.err e => Result.err e,
          Result.ok xs => Result.ok (List.cons a xs),
        },
      },
  }

#[terminating]
def Db.attach_one (t : Todo) (subs : List (Pair I64 Subtask))
    (tags : List (Pair I64 String)) : Todo :=
  let my_subs :=
    List.map (fn (p : Pair I64 Subtask) => match p { Pair.pair _ s => s })
      (List.filter (fn (p : Pair I64 Subtask) =>
        match p { Pair.pair tid _ => tid == t.id }) subs) in
  let my_tags :=
    List.map (fn (p : Pair I64 String) => match p { Pair.pair _ tag => tag })
      (List.filter (fn (p : Pair I64 String) =>
        match p { Pair.pair tid _ => tid == t.id }) tags) in
  { t with subtasks := my_subs, tags := my_tags }

def Db.decode_all (todo_rows : List Row) (sub_rows : List Row) (tag_rows : List Row)
    : Result SqlError (List Todo) :=
  SqlResult.and_then (Db.decode_list Db.decode_todo_row todo_rows)
    (fn (todos : List Todo) =>
      SqlResult.and_then (Db.decode_list Db.decode_subtask_row sub_rows)
        (fn (subs : List (Pair I64 Subtask)) =>
          SqlResult.and_then (Db.decode_list Db.decode_tag_row tag_rows)
            (fn (tags : List (Pair I64 String)) =>
              Result.ok (List.map (fn (t : Todo) => Db.attach_one t subs tags) todos))))

pub def Db.load_m : SqliteM (Result String (List Todo)) := do {
  let trs <- Sqlite.query Db.todos_sql List.empty;
  let srs <- Sqlite.query Db.subtasks_sql List.empty;
  let grs <- Sqlite.query Db.tags_sql List.empty;
  match Db.decode_all trs.rows srs.rows grs.rows {
    Result.err e => return (Result.err (SqlError.message e)),
    Result.ok todos => return (Result.ok todos),
  }
}

pub def Db.now_m : SqliteM (Result String String) := do {
  let rs <- Sqlite.query "SELECT datetime('now') AS now" List.empty;
  match rs.rows {
    List.empty => return (Result.err "database clock query returned no row"),
    List.cons row _ => match Row.get_text row "now" {
      Result.ok now => return (Result.ok now),
      Result.err e => return (Result.err (SqlError.message e)),
    },
  }
}

// ─── Persistence ────────────────────────────────────────────────────────

#[terminating]
def Db.insert_subtasks (todo_id : I64) (position : I64) (subs : List Subtask)
    : SqliteM Unit :=
  match subs {
    List.empty => return Unit.unit,
    List.cons s rest => do {
      let _ <- Sqlite.exec Db.insert_subtask_sql [
        Value.integer s.id, Value.integer todo_id, Value.integer position,
        Value.text s.title, Value.integer (if s.done then 1i64 else 0i64)];
      Db.insert_subtasks todo_id (position + 1i64) rest;
    },
  }

#[terminating]
def Db.insert_tags (todo_id : I64) (position : I64) (tags : List String) : SqliteM Unit :=
  match tags {
    List.empty => return Unit.unit,
    List.cons tag rest => do {
      let _ <- Sqlite.exec Db.insert_tag_sql [Value.text tag];
      let _ <- Sqlite.exec Db.insert_todo_tag_sql [
        Value.integer todo_id, Value.text tag, Value.integer position];
      Db.insert_tags todo_id (position + 1i64) rest;
    },
  }

#[terminating]
def Db.insert_todos (position : I64) (todos : List Todo) : SqliteM Unit :=
  match todos {
    List.empty => return Unit.unit,
    List.cons t rest => do {
      let _ <- Sqlite.exec Db.insert_todo_sql [
        Value.integer t.id, Value.integer position, Value.text t.title,
        Value.integer (if t.done then 1i64 else 0i64), Value.text t.notes,
        Db.opt_text_value t.group, Value.text (Status.to_string t.status),
        Db.opt_text_value t.due_at, Db.opt_text_value t.created_at,
        Db.opt_text_value t.updated_at, Db.opt_ref_value t.created_by,
        Db.opt_ref_value t.updated_by];
      let _ <- Db.insert_subtasks t.id 0i64 t.subtasks;
      let _ <- Db.insert_tags t.id 0i64 t.tags;
      Db.insert_todos (position + 1i64) rest;
    },
  }

pub def Db.write_all_m (todos : List Todo) : SqliteM Unit := do {
  let _ <- Sqlite.exec "DELETE FROM todo_tags" List.empty;
  let _ <- Sqlite.exec "DELETE FROM subtasks" List.empty;
  let _ <- Sqlite.exec "DELETE FROM todos" List.empty;
  Db.insert_todos 0i64 todos;
}

// ─── Attribution stamping ───────────────────────────────────────────────

def Db.user_ref_of (u : User) : UserRef :=
  let r : UserRef := { id := u.id, name := u.name } in r

#[terminating]
def Db.contains_id (id : I64) (todos : List Todo) : Bool :=
  match todos {
    List.empty => false,
    List.cons t rest => if t.id == id then true else Db.contains_id id rest,
  }

#[terminating]
def Db.find_new_id (old : List Todo) (updated : List Todo) : Option I64 :=
  match updated {
    List.empty => Option.none,
    List.cons t rest =>
      if Db.contains_id t.id old
      then Db.find_new_id old rest
      else Option.some t.id,
  }

#[terminating]
def Db.has_subtask (sid : I64) (subs : List Subtask) : Bool :=
  match subs {
    List.empty => false,
    List.cons s rest => if s.id == sid then true else Db.has_subtask sid rest,
  }

#[terminating]
def Db.subtask_parent (sid : I64) (todos : List Todo) : Option I64 :=
  match todos {
    List.empty => Option.none,
    List.cons t rest =>
      if Db.has_subtask sid t.subtasks
      then Option.some t.id
      else Db.subtask_parent sid rest,
  }

def Db.stamp_todo (actor : UserRef) (now : String) (create : Bool) (t : Todo) : Todo :=
  if create
  then { t with created_at := Option.some now, updated_at := Option.some now,
                created_by := Option.some actor, updated_by := Option.some actor }
  else { t with updated_at := Option.some now, updated_by := Option.some actor }

def Db.stamp_one (actor : UserRef) (now : String) (create : Bool) (id : I64)
    (todos : List Todo) : List Todo :=
  List.map (fn (t : Todo) =>
    if t.id == id then Db.stamp_todo actor now create t else t) todos

pub def Db.stamp_action (actor : User) (now : String) (old : List Todo)
    (updated : List Todo) (action : Action) : List Todo :=
  let actor_ref := Db.user_ref_of actor in
  match action {
    Action.add _title _notes _group _tags _due =>
      match Db.find_new_id old updated {
        Option.some id => Db.stamp_one actor_ref now true id updated,
        Option.none => updated,
      },
    Action.edit id _title _notes _group _tags _due =>
      Db.stamp_one actor_ref now false id updated,
    Action.toggle id => Db.stamp_one actor_ref now false id updated,
    Action.delete _id => updated,
    Action.add_subtask id _title => Db.stamp_one actor_ref now false id updated,
    Action.toggle_subtask sid =>
      match Db.subtask_parent sid old {
        Option.some id => Db.stamp_one actor_ref now false id updated,
        Option.none => updated,
      },
    Action.delete_subtask sid =>
      match Db.subtask_parent sid old {
        Option.some id => Db.stamp_one actor_ref now false id updated,
        Option.none => updated,
      },
    Action.clear_completed => updated,
    Action.set_status id _ => Db.stamp_one actor_ref now false id updated,
    Action.render => updated,
  }

def Db.write_stamped_m (actor : User) (action : Action) (old : List Todo)
    (updated : List Todo) : SqliteM (Result String (List Todo)) := do {
  let now_r <- Db.now_m;
  match now_r {
    Result.err e => return (Result.err e),
    Result.ok now => do {
      let stamped := Db.stamp_action actor now old updated action;
      let _ <- Db.write_all_m stamped;
      return (Result.ok stamped);
    },
  }
}

def Db.apply_loaded_m (actor : User) (action : Action) (old : List Todo)
    : SqliteM (Result String (List Todo)) := do {
  let updated := Action.apply action old;
  match action {
    Action.render => return (Result.ok updated),
    _ => Db.write_stamped_m actor action old updated,
  }
}

pub def Db.load_apply_write_m (actor : User) (action : Action)
    : SqliteM (Result String (List Todo)) := do {
  let loaded <- Db.load_m;
  match loaded {
    Result.err e => return (Result.err e),
    Result.ok old => Db.apply_loaded_m actor action old,
  }
}

// ─── Connection + public API ────────────────────────────────────────────

def Db.with_path {A : Type} (p : Path) (f : SqliteConn -> IO (Result String A))
    : IO (Result String A) := do {
  let opened <- Sqlite.connect p;
  match opened {
    Result.err e =>
      return (Result.err ("database open failed: " ++ SqlError.message e)),
    Result.ok conn => do {
      let r <- f conn;
      let _ <- Sqlite.close conn;
      return r;
    },
  }
}

def Db.with_conn {A : Type} (path : String) (f : SqliteConn -> IO (Result String A))
    : IO (Result String A) := do {
  match Path.of path {
    Result.err e => return (Result.err ("invalid database path: " ++ e)),
    Result.ok p => Db.with_path p f,
  }
}

pub def Db.prepare (store : Store) : IO (Result String Unit) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) => do {
    let migrated <- Sqlite.migrate conn Db.migrations;
    match migrated {
      Result.err e =>
        return (Result.err ("database migration failed: " ++ SqlError.message e)),
      Result.ok _ => return (Result.ok Unit.unit),
    }
  })

pub def Db.load (store : Store) : IO (Result String (List Todo)) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) => do {
    let r <- SqliteM.run (Sqlite.transaction Db.load_m) conn;
    match r {
      Result.err e => return (Result.err ("database load failed: " ++ SqlError.message e)),
      Result.ok inner => return inner,
    }
  })

pub def Db.apply_and_save (store : Store) (actor : User) (action : Action)
    : IO (Result String (List Todo)) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) => do {
    let r <- SqliteM.run (Sqlite.transaction (Db.load_apply_write_m actor action)) conn;
    match r {
      Result.err e => return (Result.err ("database write failed: " ++ SqlError.message e)),
      Result.ok inner => return inner,
    }
  })

// ─── Users / sessions / OAuth state ─────────────────────────────────────

def Db.exec_unit (conn : SqliteConn) (sql : String) (params : List Value)
    (label : String) : IO (Result String Unit) := do {
  let r <- Sqlite.exec_io conn sql params;
  match r {
    Result.err e => return (Result.err (label ++ ": " ++ SqlError.message e)),
    Result.ok _ => return (Result.ok Unit.unit),
  }
}

def Db.read_user_io (conn : SqliteConn) (identity : OidcIdentity)
    : IO (Result String User) := do {
  let rs <- Sqlite.query_io conn
    ("SELECT id, issuer, subject, email, name, picture, timezone, " ++
     "created_at, updated_at FROM users WHERE issuer = ? AND subject = ?")
    [Value.text identity.issuer, Value.text identity.subject];
  match rs {
    Result.err e => return (Result.err ("user read failed: " ++ SqlError.message e)),
    Result.ok result_set => match result_set.rows {
      List.empty => return (Result.err "user not found after upsert"),
      List.cons row _ => match Db.decode_user_row row {
        Result.ok u => return (Result.ok u),
        Result.err e => return (Result.err (SqlError.message e)),
      },
    },
  }
}

pub def Db.find_or_create_user (store : Store) (identity : OidcIdentity)
    : IO (Result String User) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) => do {
    let upsert <- Sqlite.exec_io conn
      ("INSERT INTO users (issuer, subject, email, name, picture, timezone, " ++
       "created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'UTC', " ++
       "datetime('now'), datetime('now')) " ++
       "ON CONFLICT(issuer, subject) DO UPDATE SET email = excluded.email, " ++
       "name = excluded.name, picture = excluded.picture, " ++
       "updated_at = datetime('now')")
      [Value.text identity.issuer, Value.text identity.subject,
       Db.opt_text_value identity.email, Value.text identity.name,
       Db.opt_text_value identity.picture];
    match upsert {
      Result.err e => return (Result.err ("user upsert failed: " ++ SqlError.message e)),
      Result.ok _ => Db.read_user_io conn identity,
    }
  })

pub def Db.find_session (store : Store) (token_hash : String)
    : IO (Result String (Option (Pair User String))) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) => do {
    let rs <- Sqlite.query_io conn
      ("SELECT s.csrf_token AS csrf_token, u.id AS id, u.issuer AS issuer, " ++
       "u.subject AS subject, u.email AS email, u.name AS name, " ++
       "u.picture AS picture, u.timezone AS timezone, " ++
       "u.created_at AS created_at, u.updated_at AS updated_at " ++
       "FROM sessions s JOIN users u ON u.id = s.user_id " ++
       "WHERE s.id = ? AND s.expires_at > datetime('now')")
      [Value.text token_hash];
    match rs {
      Result.err e => return (Result.err ("session read failed: " ++ SqlError.message e)),
      Result.ok result_set => match result_set.rows {
        List.empty => return (Result.ok Option.none),
        List.cons row _ =>
          match Row.get_text row "csrf_token" {
            Result.err e => return (Result.err (SqlError.message e)),
            Result.ok csrf => match Db.decode_user_row row {
              Result.ok u => return (Result.ok (Option.some (Pair.pair u csrf))),
              Result.err e => return (Result.err (SqlError.message e)),
            },
          },
      },
    }
  })

pub def Db.create_session (store : Store) (user_id : I64) (token_hash : String)
    (csrf : String) (expires_at : String) : IO (Result String Unit) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) =>
    Db.exec_unit conn
      ("INSERT INTO sessions (id, user_id, csrf_token, created_at, expires_at) " ++
       "VALUES (?, ?, ?, datetime('now'), ?)")
      [Value.text token_hash, Value.integer user_id, Value.text csrf,
       Value.text expires_at]
      "session insert failed")

pub def Db.delete_session (store : Store) (token_hash : String) : IO (Result String Unit) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) =>
    Db.exec_unit conn "DELETE FROM sessions WHERE id = ?" [Value.text token_hash]
      "session delete failed")

pub def Db.put_oauth_state (store : Store) (state : OauthState)
    : IO (Result String Unit) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) =>
    Db.exec_unit conn
      ("INSERT OR REPLACE INTO oauth_states " ++
       "(state, nonce, code_verifier, redirect_to, created_at, expires_at) " ++
       "VALUES (?, ?, ?, ?, datetime('now'), ?)")
      [Value.text state.state, Value.text state.nonce,
       Value.text state.code_verifier, Db.opt_text_value state.redirect_to,
       Value.text state.expires_at]
      "oauth state insert failed")

def Db.decode_oauth_state_row (row : Row) : Result SqlError OauthState :=
  SqlResult.and_then (Row.get_text row "state") (fn (state : String) =>
    SqlResult.and_then (Row.get_text row "nonce") (fn (nonce : String) =>
      SqlResult.and_then (Row.get_text row "code_verifier") (fn (verifier : String) =>
        SqlResult.and_then (Db.optional_text row "redirect_to") (fn (redirect : Option String) =>
          SqlResult.and_then (Row.get_text row "expires_at") (fn (expires : String) =>
            Result.ok ({
              state := state, nonce := nonce, code_verifier := verifier,
              redirect_to := redirect, expires_at := expires
            } : OauthState))))))

pub def Db.take_oauth_state (store : Store) (state : String)
    : IO (Result String (Option OauthState)) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) => do {
    let rs <- Sqlite.query_io conn
      ("DELETE FROM oauth_states WHERE state = ? AND expires_at > datetime('now') " ++
       "RETURNING state, nonce, code_verifier, redirect_to, expires_at")
      [Value.text state];
    match rs {
      Result.err e => return (Result.err ("oauth state read failed: " ++ SqlError.message e)),
      Result.ok result_set => match result_set.rows {
        List.empty => return (Result.ok Option.none),
        List.cons row _ =>
          match Db.decode_oauth_state_row row {
            Result.ok st => return (Result.ok (Option.some st)),
            Result.err e => return (Result.err (SqlError.message e)),
          },
      },
    }
  })

pub def Db.update_timezone (store : Store) (user_id : I64) (tz : String)
    : IO (Result String Unit) :=
  Db.with_conn store.db_path (fn (conn : SqliteConn) =>
    Db.exec_unit conn
      "UPDATE users SET timezone = ?, updated_at = datetime('now') WHERE id = ?"
      [Value.text tz, Value.integer user_id]
      "timezone update failed")
