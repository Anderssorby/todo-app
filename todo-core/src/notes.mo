/// Markdown rendering, isolated from the large view module.
///
/// The `markdown` mote is pure and wasm-portable, so the SSR and the browser
/// shell share this renderer. Isolating it keeps the markdown code in its own
/// compilation unit; embedding the call in `view.mo` next to the page builders
/// triggered a codegen segfault at the pinned revision (see `PLAN.md`,
/// `markdown-in-view-mislowers-oak-render`).
use markdown::parse {Markdown.parse_with}
use markdown::html {Markdown.to_html_with}
use markdown::options {Markdown.default_html_options, Markdown.default_options}
use oak::typed {Oak.Node, Oak.of_html}
use oak::elements {Html.class_, Html.div, Html.fragment}

/// Raw HTML is escaped and `javascript:`/`vbscript:`/`file:` URLs are dropped
/// (`default_html_options`). `data:image/…` passes the mote's filter; it is
/// rendered as an `<img src>`, which browsers do not script.
pub def Notes.markdown {Msg : Type} (source : String) : Oak.Node Msg :=
  if String.beq source ""
  then Html.fragment List.empty
  else
    Oak.of_html
      (Markdown.to_html_with Markdown.default_html_options
        (Markdown.parse_with Markdown.default_options source))

/// A notes preview: a `div` (markdown emits block elements) omitted when the
/// source is empty.
pub def Notes.preview {Msg : Type} (source : String) : Oak.Node Msg :=
  if String.beq source ""
  then Html.fragment List.empty
  else Html.div [Html.class_ ["notes-preview", "markdown"]]
    [Notes.markdown source]
