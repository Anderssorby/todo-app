// The SPA component library root.
//
// The bin (`src/main.mo`) composes components under `src/components/` via
// `use lib::components::…`. This root deliberately declares nothing: the
// component modules are the API, and a re-export here would decide it
// before the composition exists (the same convention as `motes/serde`'s
// empty `lib.mo`).
