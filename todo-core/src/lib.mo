// The shared core's library root. Consumers import the modules directly
// (`use todo_core::storage {Todo}`, `use todo_core::view {View.fragment_html}`),
// so this hub is mostly for bare `use todo_core` resolution and one-name
// re-exports.

pub use lib::storage {*}
pub use lib::action {*}
pub use lib::codec {*}
pub use lib::view {*}
pub use lib::kernel {*}
