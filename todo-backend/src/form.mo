/// Form-field access for the no-JS routes.
///
/// The `http` mote decodes both form encodings: `Request.form_fields`
/// (`Body.parse_form`) for `application/x-www-form-urlencoded`, which the
/// server-rendered forms use, and `Request.multipart` for
/// `multipart/form-data`, kept for clients still posting the old enctype.
/// This module only names the fields the todo forms use; the earlier local
/// boundary scanner duplicated the mote's parser and skipped its media-type
/// and error handling.
use http::body {MultipartPart}
use http::request {Request.form_fields, Request.multipart, Request.param}
use http::strings {Strings.split_on}
use http::types {Body, Headers, Method, Request, Uri}
use std::list {List.any, List.filter, List.filter_map, List.length}

def Form.part_field (p : MultipartPart) : Pair String String :=
  Pair.pair (MultipartPart.field_name p) (String.from_list (MultipartPart.bytes p))

/// The request's form fields, whichever encoding it used.
def Form.fields_of (req : Request) : Option (List (Pair String String)) :=
  match Request.form_fields req {
    Result.ok fields => Option.some fields,
    Result.err _ => match Request.multipart req {
      Result.ok parts => Option.some (List.map Form.part_field parts),
      Result.err _ => Option.none,
    },
  }

/// The first value of a named field, or none if absent / not a form body.
pub def Form.value_of (name : String) (req : Request) : Option String :=
  match Form.fields_of req {
    Option.some fields => Request.param name fields,
    Option.none => Option.none,
  }

/// Every value of a named field, in document order. A native
/// `<select multiple name="tags">` submits one repeated field per selected
/// option; `Request.param` only returns the first, so multi-select parsing
/// needs this.
pub def Form.values_of (name : String) (req : Request) : List String :=
  match Form.fields_of req {
    Option.some fields =>
      List.filter_map (fn (p : Pair String String) => match p {
        Pair.pair k v => if String.beq k name then Option.some v else Option.none,
      }) fields,
    Option.none => List.empty,
  }

pub def Form.value_or_empty (name : String) (req : Request) : String :=
  Option.get_or_default "" (Form.value_of name req)

pub def Form.csrf_of (req : Request) : Option String := Form.value_of "csrf" req

/// The `title` of a form create post, or none when the request is not a
/// form (the JSON path handles that).
pub def Form.title_of (req : Request) : Option String := Form.value_of "title" req

/// One comma-separated value: the legacy single `tags` field and the
/// `new_tags` inline-creation field both use this. Blank entries from stray
/// commas are dropped.
def Form.parse_tags (raw : String) : List String :=
  if String.beq raw "" then List.empty
  else List.filter (fn (s : String) => Bool.not (String.beq s ""))
    (List.map String.trim (Strings.split_on "," raw))

#[terminating]
def Form.member (x : String) (xs : List String) : Bool :=
  match xs {
    List.empty => false,
    List.cons y rest => if String.beq x y then true else Form.member x rest,
  }

#[terminating]
def Form.dedupe_go (xs : List String) (seen : List String) (acc : List String) : List String :=
  match xs {
    List.empty => List.reverse acc,
    List.cons x rest =>
      if Form.member x seen
      then Form.dedupe_go rest seen acc
      else Form.dedupe_go rest (List.cons x seen) (List.cons x acc),
  }

/// Keep the first occurrence of each tag, preserving document order.
pub def Form.dedupe (xs : List String) : List String :=
  Form.dedupe_go xs List.empty List.empty

/// `tags` accepts all three shapes: repeated fields from a native
/// multi-select, the legacy single comma-separated field, and the
/// `new_tags` inline-creation field. The result is trimmed, blank-free and
/// deduplicated in first-seen order.
pub def Form.tags_of (req : Request) : List String :=
  let selected :=
    List.flatten (List.map Form.parse_tags (Form.values_of "tags" req)) in
  let created := Form.parse_tags (Form.value_or_empty "new_tags" req) in
  Form.dedupe (List.append selected created)

/// A single free-text group value; blank means "no group".
def Form.parse_group (raw : String) : Option String :=
  let trimmed := String.trim raw in
  if String.beq trimmed "" then Option.none else Option.some trimmed

/// The inline `new_group` field wins over the `group` select value.
pub def Form.group_of (req : Request) : Option String :=
  match Form.parse_group (Form.value_or_empty "new_group" req) {
    Option.some g => Option.some g,
    Option.none => Form.parse_group (Form.value_or_empty "group" req),
  }

/// The due-date field (`<input type="date">` sends `YYYY-MM-DD`); a blank
/// value means no due date.
pub def Form.due_of (req : Request) : Option String :=
  match Form.value_of "due_at" req {
    Option.some raw =>
      let trimmed := String.trim raw in
      if String.beq trimmed "" then Option.none else Option.some trimmed,
    Option.none => Option.none,
  }

#[test]
def test_title_of_reads_urlencoded_field : Bool :=
  let hs := Headers.set "Content-Type" "application/x-www-form-urlencoded" Headers.empty in
  let base := Request.get (Uri.uri "" Option.none "" Option.none "/todos/new" Option.none Option.none) in
  let req : Request := { base with method := Method.POST, headers := hs, body := Body.text "title=hello+world" } in
  match Form.title_of req {
    Option.some v => String.beq v "hello world",
    Option.none => false,
  }

#[test]
def test_title_of_reads_multipart_field : Bool :=
  let raw := "--BOUND\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhi\r\n--BOUND--\r\n" in
  let hs := Headers.set "Content-Type" "multipart/form-data; boundary=BOUND" Headers.empty in
  let base := Request.get (Uri.uri "" Option.none "" Option.none "/todos" Option.none Option.none) in
  let req : Request :=
    { base with method := Method.POST, headers := hs, body := Body.bytes (String.to_list raw) } in
  match Form.title_of req {
    Option.some v => String.beq v "hi",
    Option.none => false,
  }

#[test]
def test_tags_of_splits_and_trims_commas : Bool :=
  let tags := Form.parse_tags " work, urgent " in
  List.length tags == 2i64

#[test]
def test_tags_of_empty_field_is_empty_list : Bool :=
  List.length (Form.parse_tags "") == 0i64

#[test]
def test_group_of_blank_is_none : Bool :=
  match Form.parse_group "   " {
    Option.none => true,
    Option.some _ => false,
  }

def Form.test_request (body : String) : Request :=
  let hs := Headers.set "Content-Type" "application/x-www-form-urlencoded" Headers.empty in
  let base := Request.get (Uri.uri "" Option.none "" Option.none "/todos" Option.none Option.none) in
  { base with method := Method.POST, headers := hs, body := Body.text body }

#[test]
def test_tags_of_reads_repeated_fields_and_new_tags : Bool :=
  let tags := Form.tags_of (Form.test_request "tags=a&tags=b&new_tags=c") in
  List.length tags == 3i64

#[test]
def test_tags_of_dedupes_preserving_first_order : Bool :=
  let tags := Form.tags_of (Form.test_request "tags=a&tags=b&tags=a") in
  match List.first tags {
    Option.some first => String.beq first "a" && List.length tags == 2i64,
    Option.none => false,
  }

#[test]
def test_group_of_prefers_new_group : Bool :=
  match Form.group_of (Form.test_request "group=Work&new_group=Urgent") {
    Option.some g => String.beq g "Urgent",
    Option.none => false,
  }

#[test]
def test_due_of_reads_value_and_blank_is_none : Bool :=
  (match Form.due_of (Form.test_request "due_at=2026-11-01") {
    Option.some d => String.beq d "2026-11-01",
    Option.none => false,
  })
  && (match Form.due_of (Form.test_request "due_at=++") {
    Option.none => true,
    Option.some _ => false,
  })
