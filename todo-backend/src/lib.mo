// The todo-app mote's library root -- lets main.mo (and other files in
// this mote) reach storage.mo/html.mo/handlers.mo via `use lib::<name>`.

pub use lib::storage {*}
pub use lib::html {*}
pub use lib::persist {*}
pub use lib::handlers {*}
