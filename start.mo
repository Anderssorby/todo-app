#![mote { name := "start", deps := [init, std] }]

// Rebuild the browser SPA and the hash-pinned loader, build the backend, and
// run it. This replaces the old `start.sh`; run it from the repository root:
//
//   monad run start.mo
//   monad run start.mo -- --port 3000
//
// It needs the same toolchain as any other build (llc/clang/wasi-sdk/Boehm GC
// on PATH -- see README.md). Every step runs with `exec_cmd`, which inherits
// this process's stdio and process group: build output streams live, and the
// server keeps the terminal. A failed step stops the script with its exit
// status; the final server's status is what `monad run` returns.
//
// The server is started under `setpriv --pdeathsig TERM` when available, so
// the kernel terminates it if this script dies unexpectedly -- the listener
// and its port are released rather than left to an orphan. Without setpriv
// the shell execs the server directly; Ctrl-C (or killing the process group)
// still stops both. Killing only the `monad run` parent is outside the
// script's control; kill the group in that case.

use std::io {
  IO.file_exists, IO.flush_stdout, IO.get_env, IO.write_stderr, IO.write_stdout
}
use std::path {Path}
use std::process {exec_cmd}
use init::shared {Shared}

struct Step {
  label : String,
  cmd : String,
  args : List String
}

/// The motes whose `mote.lock` must resolve before a `--locked` build. Each
/// is a committed symlink to the workspace root's one `mote.lock`; keeping
/// them makes the per-member verify path (which still reads `<member>/
/// mote.lock`) use the workspace resolution.
def Start.members : List String :=
  ["todo-core", "todo-backend", "todo-spa", "todo-webgen"]

def Start.say (msg : String) : IO Unit := do {
  IO.write_stdout (msg ++ "\n");
  IO.flush_stdout
}

def Start.fail (msg : String) : IO Unit :=
  IO.write_stderr (msg ++ "\n")

#[terminating]
def Start.missing_lock (root : String) (members : List String) : IO (Option String) := do {
  match members {
    List.empty => return Option.none,
    List.cons m rest => do {
      let lock : String :=
        Clone.clone (Shared.of root) ++ "/" ++ Clone.clone (Shared.of m) ++ "/mote.lock";
      let present <- IO.file_exists (Path.path lock);
      if present then Start.missing_lock root rest
      else return (Option.some m)
    }
  }
}

def Start.run_step (s : Step) : IO (Result I64 Unit) :=
  match s {
    { label, cmd, args } => do {
      Start.say ("==> " ++ label);
      let code <- exec_cmd cmd args;
      if code == 0
      then return (Result.ok unit)
      else do {
        Start.fail ("error: build step failed (exit " ++ I64.to_string code ++ ")");
        return (Result.err code)
      }
    }
  }

#[terminating]
def Start.run_steps (steps : List Step) : IO (Result I64 Unit) := do {
  match steps {
    List.empty => return (Result.ok unit),
    List.cons s rest => do {
      let r <- Start.run_step s;
      match r {
        Result.err code => return (Result.err code),
        Result.ok _ => Start.run_steps rest
      }
    }
  }
}

/// A relative `-o` lands under the target directory when building a mote, so
/// the wasm asset path must be absolute (`$PWD/web/app.wasm`).
def Start.steps (root : String) : List Step := [
  {
    label := "building todo-spa (wasm32-unknown-unknown)",
    cmd := "monad",
    args := ["build", "--locked", "--target", "wasm32-unknown-unknown",
             "todo-spa", "-o", root ++ "/web/app.wasm"]
  },
  {
    label := "building todo-webgen",
    cmd := "monad",
    args := ["build", "--locked", "todo-webgen"]
  },
  {
    label := "generating the hash-pinned loader (todo-webgen)",
    cmd := "./target/debug/todo-webgen",
    args := List.empty
  },
  {
    label := "building todo-backend",
    cmd := "monad",
    args := ["build", "--locked", "todo-backend"]
  }
]

/// Start the server. `setpriv --pdeathsig TERM` arms PR_SET_PDEATHSIG in the
/// child before exec, so a script that dies by signal still takes the server
/// (and its listening socket) with it. The fallback keeps the script usable
/// where util-linux is absent; `sh -c` then `exec`s the server either way.
def Start.serve (args : List String) : IO I64 := do {
  Start.say "==> starting todo-backend (Ctrl-C to stop)";
  let script : String :=
    "if command -v setpriv >/dev/null 2>&1; then " ++
    "exec setpriv --pdeathsig TERM -- ./target/debug/todo-backend \"$@\"; " ++
    "else exec ./target/debug/todo-backend \"$@\"; fi";
  exec_cmd "sh" (List.append ["-c", script, "sh"] args)
}

def main (args : List String) : IO I64 := do {
  let pwd <- IO.get_env "PWD";
  match pwd {
    Option.none => do {
      Start.fail "error: PWD is not set; run this from the repository root";
      return 1
    },
    Option.some root => do {
      let absolute : Bool :=
        String.starts_with "/" (Clone.clone (Shared.of root));
      if Bool.not absolute then do {
        Start.fail "error: PWD is not absolute; run this from the repository root";
        return 1
      } else do {
        let missing <- Start.missing_lock (Clone.clone (Shared.of root)) Start.members;
        match missing {
          Option.some m => do {
            Start.fail
              ("error: " ++ m ++ "/mote.lock is missing; run: scripts/fetch-deps.sh");
            return 1
          },
          Option.none => do {
            let built <- Start.run_steps (Start.steps root);
            match built {
              Result.err code => return code,
              Result.ok _ => Start.serve args
            }
          }
        }
      }
    }
  }
}
