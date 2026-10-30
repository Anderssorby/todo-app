/// A non-blocking accept loop around moon's connection server.
///
/// `moon::server::Server.serve_concurrent` accepts up to `max_in_flight`
/// connections and then `await`s EVERY fiber it forked before accepting
/// another. A connection fiber lives for the whole keep-alive socket --
/// `Server.serve_connection` has no idle timeout -- so that bound counts
/// open browser sockets, not in-flight requests. A browser holds its idle
/// keep-alive sockets for its keep-alive timeout and opens up to six per
/// tab, so a few page loads (or one tab plus a reload) fill every slot: the
/// accept loop then parks until the browser drops a socket, and a request
/// on a new connection -- typically the SPA's `app.wasm` fetch -- waits
/// unaccepted and dies in the browser as
///
///     todo-spa: failed to mount TypeError: NetworkError when attempting to
///     fetch resource.
///
/// Reproduced 2026-10-30 against the pinned moon (16 `max_in_flight`, 16
/// idle keep-alive connections, then a 17th request that never answers).
/// It is intermittent by nature: it needs enough idle sockets, so it shows
/// up after some reloads, never on a cold start.
///
/// This loop never waits for a live connection. Before every accept it
/// reaps the fibers that have already stopped (`pollFiber`, non-blocking),
/// so `tcp_accept` blocks only when the kernel backlog is empty -- the
/// behaviour a server wants. An idle keep-alive socket costs one parked
/// fiber, which is what a fiber-per-connection server is for. `max_live`
/// bounds those threads (each fiber reserves a stack): at the cap the loop
/// waits for a connection to finish rather than accepting more, which is
/// genuine overload, not the normal case.
use std::concurrent::fiber {
  Fiber, FiberError, FiberError.message, await_fiber, forkIO, pollFiber
}
use std::io {IO.tcp_accept, IO.tcp_listen_on}
use std::list {List.length}
use std::stream {FdStream, Stream}
use http::types {Request, Response}
use log::logger {Logger.error, Logger.warn}
use moon::server {Server.serve_connection}
use lib::logging {App.logger}

/// The most connections served at once. Each is one fiber/thread, so this
/// is a thread bound as much as a connection bound; browsers stay far below
/// it (six sockets per host per tab) unless they are already misbehaving.
pub def Serve.max_live : I64 := 256i64

/// Keep only the fibers that are still running. `pollFiber` is the
/// non-blocking sibling of `await_fiber`: `none` while the connection is
/// open, `some` once it has stopped (a connection that ended, served its
/// request and closed, or never started).
#[terminating]
def Serve.reap (pending : List (Fiber Unit)) : IO (List (Fiber Unit)) :=
  match pending {
    List.empty => IO.pure List.empty,
    List.cons f rest => do {
      let answer <- pollFiber f;
      let kept <- Serve.reap rest;
      match answer {
        Option.some _ => IO.pure kept,
        Option.none => IO.pure (List.cons f kept),
      }
    },
  }

/// Fork one connection fiber. `Option.none` means the fiber has already
/// stopped: it either served the connection (and closed it) or the runtime
/// could not create a thread, in which case nothing has touched the socket
/// and this closes it. `Option.some` is a live connection to keep tracking.
def Serve.fork_connection (handler : Request -> IO Response) (sock : FdStream)
    : IO (Option (Fiber Unit)) := do {
  let fiber <- forkIO (fn _ => Server.serve_connection handler sock List.empty 1);
  let answer <- pollFiber fiber;
  match answer {
    Option.none => return (Option.some fiber),
    Option.some r =>
      match r {
        Result.ok _ => return Option.none,
        Result.err e => do {
          let _ <- Logger.error App.logger
            ("connection dropped: " ++ FiberError.message e);
          Stream.close sock;
          return Option.none
        }
      },
  }
}

/// Wait for one connection to finish, so the fiber count comes back under
/// `max_live`. Only reached at the cap: the alternative (accepting anyway)
/// would grow threads without bound.
def Serve.wait_for_room (pending : List (Fiber Unit)) : IO (List (Fiber Unit)) :=
  match pending {
    List.empty => IO.pure List.empty,
    List.cons f rest => do {
      let _ <- Logger.warn App.logger
        ("live connection limit reached (" ++ I64.to_string Serve.max_live
          ++ "); waiting for one to finish");
      let _ <- await_fiber f;
      return rest
    },
  }

def Serve.ensure_room (pending : List (Fiber Unit)) : IO (List (Fiber Unit)) :=
  if I64.gt (List.length pending) Serve.max_live
  then Serve.wait_for_room pending
  else IO.pure pending

/// Await every live connection (the shutdown path: `tcp_accept` failed
/// because the listener was closed). Their handlers close their own sockets,
/// so returning while they run would race the process exit.
#[terminating]
def Serve.drain (pending : List (Fiber Unit)) : IO Unit :=
  match pending {
    List.empty => return unit,
    List.cons f rest => do {
      let _ <- await_fiber f;
      Serve.drain rest
    },
  }

#[terminating]
def Serve.loop (handler : Request -> IO Response) (listener : FdStream)
    (pending : List (Fiber Unit)) : IO Unit := do {
  let reaped <- Serve.reap pending;
  let live <- Serve.ensure_room reaped;
  let accept_res <- IO.tcp_accept listener;
  match accept_res {
    Result.err _ => do {
      Serve.drain live;
      Stream.close listener
    },
    Result.ok sock => do {
      let forked <- Serve.fork_connection handler sock;
      match forked {
        Option.some f => Serve.loop handler listener (List.cons f live),
        Option.none => Serve.loop handler listener live,
      }
    },
  }
}

/// Listen on `host:port` and serve connections forever, forking one fiber
/// per connection and never parking the loop on a live keep-alive socket.
/// Returns only when the listener fails; `Err` carries the bind error so the
/// caller can report a busy port.
#[terminating]
pub def Serve.run (host : String) (port : U16) (handler : Request -> IO Response)
    : IO (Result String Unit) := do {
  let listen_res <- IO.tcp_listen_on host port;
  match listen_res {
    Result.err e => return (Result.err e.message),
    Result.ok listener => do {
      Serve.loop handler listener List.empty;
      return (Result.ok unit)
    },
  }
}
