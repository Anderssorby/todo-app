/// Request logging through the `log` mote, replacing moon's unleveled
/// `Middleware.logging` (a plain `IO.println req.uri.path`).
use log::level {LogLevel}
use log::logger {Logger, Logger.stdout, Logger.with_field, Logger.info, Logger.warn, Logger.error}
use http::types {Request, Response}
use http::wire {Wire.method_str}

pub def App.logger : Logger := Logger.with_field (Logger.stdout LogLevel.info) "app" "todo-backend"

def App.request_line (req : Request) : String :=
  Wire.method_str req.method ++ " " ++ req.uri.path

def App.log_status (line : String) (status : U16) : IO Unit :=
  let msg := line ++ " " ++ U16.to_string status in
  if U16.gt status 499u16 then Logger.error App.logger msg
  else if U16.gt status 399u16 then Logger.warn App.logger msg
  else Logger.info App.logger msg

/// Log the request line, run the handler, then log the response status at
/// a level that follows the status class (2xx/3xx info, 4xx warn, 5xx error).
pub def App.request_logging (handler : Request -> IO Response) (req : Request) : IO Response := do {
  let line := App.request_line req;
  let _ <- Logger.info App.logger line;
  let res <- handler req;
  let _ <- App.log_status line res.status;
  return res
}
