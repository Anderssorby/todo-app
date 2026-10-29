use moon::server {Server.serve_concurrent, ServerConfig, ServerConfig.on}
use moon::router {Route, Router.get, Router.post, Router.route}
use moon::static_files {StaticConfig, StaticConfig.default, Static.handler}
use moon::handler {Handler.try}
use lib::handlers {
  Handlers.add_subtask, Handlers.api_action, Handlers.api_clear_completed,
  Handlers.api_create, Handlers.api_delete, Handlers.api_delete_subtask,
  Handlers.api_list, Handlers.api_me, Handlers.api_set_status,
  Handlers.api_toggle, Handlers.api_toggle_subtask, Handlers.auth_callback,
  Handlers.auth_login, Handlers.auth_logout, Handlers.clear_completed,
  Handlers.create, Handlers.delete, Handlers.delete_subtask, Handlers.edit,
  Handlers.edit_task_page, Handlers.index, Handlers.kanban_page,
  Handlers.login_page, Handlers.new_task_page, Handlers.not_found,
  Handlers.set_status, Handlers.toggle, Handlers.toggle_subtask
}
use lib::auth {Auth.require, Config, Context}
use lib::db {Db.prepare, Store}
use lib::logging {App.logger, App.request_logging}
use log::logger {Logger.error, Logger.info}
use clap::spec {
  Cli.CommandSpec, Cli.Parsed, Cli.command, Cli.flag, Cli.flag_set,
  Cli.option_default, Cli.option_i64_default, Cli.option_value,
  Cli.option_value_i64, Cli.with_args
}
use clap::parse {Cli.run}
use http::types {Request, Response}
use std::path {Path}
use std::stream {FdStream, Stream, StreamError}
open IO {flush_stdout, tcp_listen_on}

// `root := "."`: the route keeps the full `/web/...` path, so the static
// handler maps it the same way the old `Assets.read_bytes "web/app.wasm"`
// workaround did -- relative to the server's cwd. moon's static handler
// reads bytes exactly, sets MIME by extension, and guards traversal.
/// Static assets are deliberately uncacheable: the loader and `app.wasm`
/// are re-vendored and rebuilt together, and a browser holding a stale
/// module cannot mount the SPA.
def static_config : StaticConfig :=
  let cfg := StaticConfig.default "." in
  { cfg with cache_control := "no-store" }

def static_assets : Route :=
  Router.get "/web/*" (Handler.try Handlers.not_found (Static.handler static_config))

/// Wrap a protected handler with session/dev resolution. `moon` handlers
/// are plain `Request -> IO Response` values, so the path is captured here
/// when the route table is built.
def App.protected (auth : Config) (handler : Context -> Request -> IO Response)
    : Request -> IO Response :=
  fn (req : Request) => Auth.require auth handler req

def App.routes (auth : Config) : List Route :=
  [
    Router.get "/login" (fn (req : Request) => Handlers.login_page auth req),
    Router.get "/auth/login" (fn (req : Request) => Handlers.auth_login auth req),
    Router.get "/auth/callback" (fn (req : Request) => Handlers.auth_callback auth req),
    Router.post "/auth/logout" (fn (req : Request) => Handlers.auth_logout auth req),
    Router.get "/api/me" (fn (req : Request) => Handlers.api_me auth req),
    Router.get "/" (App.protected auth Handlers.index),
    Router.get "/todos/new" (App.protected auth Handlers.new_task_page),
    Router.get "/todos/:id/edit" (App.protected auth Handlers.edit_task_page),
    Router.get "/kanban" (App.protected auth Handlers.kanban_page),
    Router.post "/todos" (App.protected auth Handlers.create),
    Router.post "/todos/:id/toggle" (App.protected auth Handlers.toggle),
    Router.post "/todos/:id/delete" (App.protected auth Handlers.delete),
    Router.post "/todos/:id/edit" (App.protected auth Handlers.edit),
    Router.post "/todos/:id/subtasks" (App.protected auth Handlers.add_subtask),
    Router.post "/todos/:id/status/:status" (App.protected auth Handlers.set_status),
    Router.post "/subtasks/:id/toggle" (App.protected auth Handlers.toggle_subtask),
    Router.post "/subtasks/:id/delete" (App.protected auth Handlers.delete_subtask),
    Router.post "/todos/clear-completed" (App.protected auth Handlers.clear_completed),
    Router.get "/api/todos" (App.protected auth Handlers.api_list),
    Router.post "/api/actions" (App.protected auth Handlers.api_action),
    Router.post "/api/todos" (App.protected auth Handlers.api_create),
    Router.post "/api/todos/:id/toggle" (App.protected auth Handlers.api_toggle),
    Router.post "/api/todos/:id/delete" (App.protected auth Handlers.api_delete),
    Router.post "/api/todos/:id/status/:status" (App.protected auth Handlers.api_set_status),
    Router.post "/api/subtasks/:id/toggle" (App.protected auth Handlers.api_toggle_subtask),
    Router.post "/api/subtasks/:id/delete" (App.protected auth Handlers.api_delete_subtask),
    Router.post "/api/todos/clear-completed" (App.protected auth Handlers.api_clear_completed),
    static_assets
  ]

// `Server.serve_concurrent` (fiber-per-connection) rather than the
// sequential `Server.run`: the latter serves one kept-alive connection at a
// time, so a browser's parallel module fetches can stall behind the page
// connection and the SPA never mounts. `ServerConfig.on` keeps the 0.0.0.0
// host and port; the explicit `tcp_listen_on` probe preserves the busy-port
// error.
def App.listen_address (host : String) (port : U16) : String :=
  host ++ ":" ++ U16.to_string port

def App.default_port : String := "8095"
def App.default_db : String := "todos.db"

def App.cli_spec : Cli.CommandSpec :=
  Cli.with_args
    [ Cli.option_i64_default "port" "p" "PORT" App.default_port
        "the TCP port to listen on",
      Cli.option_default "db" "d" "PATH" App.default_db
        "the SQLite database file",
      Cli.flag "dev-auth" "" "enable the development-only sign-in stub" ]
    (Cli.command "todo-backend" "A todo list web app server")

def App.port_in_range (n : I64) : Bool :=
  Bool.not (I64.lt n 0i64) && Bool.not (I64.gt n 65535i64)

struct App.Options {
  port : I64,
  db : String,
  dev_auth : Bool
}

// `clap` validates `--port`/`-p` is a well-formed integer at parse time
// (`arg_i64`); the only thing left to check here is that it actually fits
// in the `U16` `ServerConfig` needs.
def App.decode_cli (env_dev : Bool) (p : Cli.Parsed) : Result String App.Options :=
  let port :=
    match Cli.option_value_i64 "port" p {
      Option.some n => n,
      Option.none => 8095i64,
    } in
  if App.port_in_range port then
    let db : String := Option.get_or_default App.default_db (Cli.option_value "db" p) in
    match Path.of db {
      Result.err e => Result.err ("invalid database path: " ++ e),
      Result.ok _ =>
        let dev : Bool := env_dev || Cli.flag_set "dev-auth" p in
        let opts : App.Options := { port := port, db := db, dev_auth := dev } in
        Result.ok opts,
    }
  else Result.err "port must be between 0 and 65535"

def App.u16_digit (c : String) : Option U16 :=
  if String.beq c "0" then Option.some 0u16
  else if String.beq c "1" then Option.some 1u16
  else if String.beq c "2" then Option.some 2u16
  else if String.beq c "3" then Option.some 3u16
  else if String.beq c "4" then Option.some 4u16
  else if String.beq c "5" then Option.some 5u16
  else if String.beq c "6" then Option.some 6u16
  else if String.beq c "7" then Option.some 7u16
  else if String.beq c "8" then Option.some 8u16
  else if String.beq c "9" then Option.some 9u16
  else Option.none

// No `I64 -> U16` conversion exists anywhere in std/init, so this builds
// the `U16` digit by digit the same way `Cli.parse_i64_unsigned` builds an
// `I64` -- safe from the lack of an overflow check only because
// `App.decode_cli` already range-checked the `I64` first.
#[partial]
def App.parse_port_go (s : String) (acc : U16) : Option U16 :=
  if String.is_empty s then Option.some acc
  else match App.u16_digit (String.slice s 0 1) {
    Option.some d => App.parse_port_go (String.drop 1 s) (U16.add (U16.mul acc 10u16) d),
    Option.none => Option.none,
  }

def App.parse_port (s : String) : Option U16 :=
  if String.is_empty s then Option.none else App.parse_port_go s 0u16

def App.serve (config : ServerConfig) (auth : Config) : IO I64 := do {
  let _ <- Logger.info App.logger
    ("listening on " ++ App.listen_address config.host config.port
      ++ " (http://localhost:" ++ U16.to_string config.port ++ "/)");
  // `Logger.stdout`'s sink (`IO.write_stdout`) does not auto-flush the way
  // `IO.write_stderr` does, so an unflushed startup line can sit in the
  // buffer indefinitely while the server blocks.
  let _ <- flush_stdout;
  // Probe the bind first so a busy port is still reported, then hand the
  // port to the fiber-per-connection loop.
  let probe : Result StreamError FdStream <- tcp_listen_on config.host config.port;
  match probe {
    Result.err e => do {
      let _ <- Logger.error App.logger ("server exited: " ++ e.message);
      return 1i64
    },
    Result.ok listener => do {
      let _ <- Stream.close listener;
      Server.serve_concurrent
        (App.request_logging (Router.route (App.routes auth))) config.port 16i64;
      return 0i64
    },
  }
}

def App.start (config : ServerConfig) (opts : App.Options) (store : Store) : IO I64 := do {
  let _ <- Logger.info App.logger ("database ready: " ++ opts.db);
  let auth : Config := { store := store, dev_auth := opts.dev_auth };
  App.serve config auth
}

def App.run_server (opts : App.Options) : IO I64 := do {
  let port :=
    match App.parse_port (I64.to_string opts.port) {
      Option.some p => p,
      Option.none => 8095u16,
    };
  let config := ServerConfig.on port;
  let store : Store := { db_path := opts.db };
  let prepared <- Db.prepare store;
  match prepared {
    Result.err msg => do {
      let _ <- Logger.error App.logger ("database unavailable: " ++ msg);
      return 1i64
    },
    Result.ok _ => App.start config opts store,
  }
}

def main (args : List String) : IO I64 := do {
  let env_dev <- IO.get_env "TODO_DEV_AUTH";
  let dev :=
    match env_dev {
      Option.some v => String.beq v "1",
      Option.none => false,
    };
  Cli.run App.cli_spec args
    (fn (p : Cli.Parsed) => App.decode_cli dev p)
    App.run_server
}

#[test]
def test_toolchain_sanity : Bool := true
