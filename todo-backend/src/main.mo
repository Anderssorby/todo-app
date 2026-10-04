use moon::server {Server.serve}
use moon::router {Route, Router.get, Router.post, Router.route}
use moon::middleware {Middleware.logging}
use lib::handlers {Handlers.create, Handlers.delete, Handlers.index, Handlers.toggle}

def routes : List Route :=
  [
    Router.get "/" Handlers.index,
    Router.post "/todos" Handlers.create,
    Router.post "/todos/:id/toggle" Handlers.toggle,
    Router.post "/todos/:id/delete" Handlers.delete
  ]

def main (args : List String) : IO Unit :=
  Server.serve (Middleware.logging (Router.route routes)) 8095u16

#[test]
def test_toolchain_sanity : Bool := true
