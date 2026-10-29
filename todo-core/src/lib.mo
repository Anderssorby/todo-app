// The shared core's library root. Consumers import the modules directly
// (`use todo_core::storage {Todo}`, `use todo_core::view {View.fragment_html}`),
// so this hub is mostly for bare `use todo_core` resolution and one-name
// re-exports.

pub use lib::user {*}
pub use lib::storage {*}
pub use lib::action {*}
pub use lib::view {*}

// `codec` (native serde derive) and `kernel` are deliberately not
// re-exported: loading them through the SPA's dependency graph triggers the
// derive-reflection gap, and nothing imports the crate root. Consumers use
// `todo_core::codec` (backend), `todo_core::codec_web` (wasm) or
// `todo_core::json_text` directly.
