use moon::server {Server.serve_concurrent, ServerConfig.on}
use moon::router {Route, Router.get, Router.post, Router.route}
use moon::static_files {StaticConfig, StaticConfig.default, Static.handler}
use moon::handler {Handler.try}
use lib::handlers {
  Handlers.add_subtask, Handlers.api_action, Handlers.api_clear_completed, Handlers.api_create,
  Handlers.api_delete, Handlers.api_delete_subtask, Handlers.api_list,
  Handlers.api_set_status, Handlers.api_toggle, Handlers.api_toggle_subtask,
  Handlers.clear_completed, Handlers.create, Handlers.delete, Handlers.delete_subtask,
  Handlers.edit, Handlers.edit_task_page, Handlers.index, Handlers.kanban_page,
  Handlers.new_task_page, Handlers.not_found, Handlers.set_status, Handlers.toggle,
  Handlers.toggle_subtask
}
use lib::logging {App.logger, App.request_logging}
use log::logger {Logger.error, Logger.info}
use clap::spec {
  Cli.CommandSpec, Cli.Parsed, Cli.command, Cli.option_i64_default, Cli.option_value_i64, Cli.with_args
}
use clap::parse {Cli.run}
use std::stream {FdStream, Stream, StreamError}
open IO {flush_stdout, tcp_listen_on}

// `root := "."`: the route keeps the full `/web/...` path, so the static
// handler maps it the same way the old `Assets.read_bytes "web/app.wasm"`
// workaround did -- relative to the server's cwd. moon's static handler
// now reads bytes exactly, sets MIME by extension, and guards traversal
// (the `moon-static-no-mime-or-binary` gap this used to route around).
/// Static assets are deliberately uncacheable: the loader (`web.js`,
/// `web_runtime.js`, `float_format.js`) and `app.wasm` are re-vendored and
/// rebuilt together, and a browser holding a stale module (or a cached
/// failed module fetch from a server restart) cannot mount the SPA.
def static_config : StaticConfig :=
  let cfg := StaticConfig.default "." in
  { cfg with cache_control := "no-store" }

def static_assets : Route :=
  Router.get "/web/*" (Handler.try Handlers.not_found (Static.handler static_config))

def routes : List Route :=
  [
    Router.get "/" Handlers.index,
    Router.get "/todos/new" Handlers.new_task_page,
    Router.get "/todos/:id/edit" Handlers.edit_task_page,
    Router.get "/kanban" Handlers.kanban_page,
    Router.post "/todos" Handlers.create,
    Router.post "/todos/:id/toggle" Handlers.toggle,
    Router.post "/todos/:id/delete" Handlers.delete,
    Router.post "/todos/:id/edit" Handlers.edit,
    Router.post "/todos/:id/subtasks" Handlers.add_subtask,
    Router.post "/todos/:id/status/:status" Handlers.set_status,
    Router.post "/subtasks/:id/toggle" Handlers.toggle_subtask,
    Router.post "/subtasks/:id/delete" Handlers.delete_subtask,
    Router.post "/todos/clear-completed" Handlers.clear_completed,
    Router.get "/api/todos" Handlers.api_list,
    Router.post "/api/actions" Handlers.api_action,
    Router.post "/api/todos" Handlers.api_create,
    Router.post "/api/todos/:id/toggle" Handlers.api_toggle,
    Router.post "/api/todos/:id/delete" Handlers.api_delete,
    Router.post "/api/todos/:id/status/:status" Handlers.api_set_status,
    Router.post "/api/subtasks/:id/toggle" Handlers.api_toggle_subtask,
    Router.post "/api/subtasks/:id/delete" Handlers.api_delete_subtask,
    Router.post "/api/todos/clear-completed" Handlers.api_clear_completed,
    static_assets
  ]

// `Server.serve_concurrent` (fiber-per-connection) rather than the
// sequential `Server.run`: the latter serves one kept-alive connection at a
// time, so a browser's parallel module fetches can stall behind the page
// connection and the SPA never mounts. `ServerConfig.on` keeps the 0.0.0.0
// host and port; the explicit `tcp_listen_on` probe in `App.run_server`
// preserves the busy-port error that `Server.run` used to report.
def App.listen_address (host : String) (port : U16) : String :=
  host ++ ":" ++ U16.to_string port

def App.default_port : String := "8095"

def App.cli_spec : Cli.CommandSpec :=
  Cli.with_args
    [Cli.option_i64_default "port" "p" "PORT" App.default_port "the TCP port to listen on"]
    (Cli.command "todo-backend" "A todo list web app server")

def App.port_in_range (n : I64) : Bool :=
  Bool.not (I64.lt n 0i64) && Bool.not (I64.gt n 65535i64)

// `clap` validates `--port`/`-p` is a well-formed integer at parse time
// (`arg_i64`); the only thing left to check here is that it actually
// fits in the `U16` `ServerConfig` needs.
def App.decode_cli (p : Cli.Parsed) : Result String I64 :=
  let port := match Cli.option_value_i64 "port" p { Option.some n => n, Option.none => 8095i64 } in
  if App.port_in_range port then Result.ok port
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
// the `U16` digit by digit the same way `Cli.parse_i64_unsigned` builds
// an `I64` -- safe from the lack of an overflow check only because
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

def App.run_server (port_i64 : I64) : IO I64 := do {
  let port := match App.parse_port (I64.to_string port_i64) { Option.some p => p, Option.none => 8095u16 };
  let config := ServerConfig.on port;
  let _ <- Logger.info App.logger
    ("listening on " ++ App.listen_address config.host config.port
      ++ " (http://localhost:" ++ U16.to_string config.port ++ "/)");
  // `Logger.stdout`'s sink (`IO.write_stdout`) does not auto-flush the way
  // `IO.write_stderr` does (log/src/logger.mo), so an unflushed startup
  // line can sit in the buffer indefinitely while the server blocks.
  let _ <- flush_stdout;
  // Probe the bind first so a busy port is still reported, then hand the
  // port to the fiber-per-connection loop. The sequential `Server.run`
  // serves one kept-alive connection at a time; a browser's parallel module
  // fetches then stall behind the page connection, which showed up as a
  // module that "failed to load" while the SPA never mounted.
  let probe : Result StreamError FdStream <- tcp_listen_on config.host config.port;
  match probe {
    Result.err e => do {
      let _ <- Logger.error App.logger ("server exited: " ++ e.message);
      return 1i64
    },
    Result.ok listener => do {
      let _ <- Stream.close listener;
      Server.serve_concurrent (App.request_logging (Router.route routes)) config.port 16i64;
      return 0i64
    },
  }
}

def main (args : List String) : IO I64 :=
  Cli.run App.cli_spec args App.decode_cli App.run_server

#[test]
def test_toolchain_sanity : Bool := true
