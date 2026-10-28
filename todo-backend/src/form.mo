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
use std::list {List.filter, List.length}

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

pub def Form.value_or_empty (name : String) (req : Request) : String :=
  Option.get_or_default "" (Form.value_of name req)

/// The `title` of a form create post, or none when the request is not a
/// form (the JSON path handles that).
pub def Form.title_of (req : Request) : Option String := Form.value_of "title" req

/// `tags` is a single comma-separated field (not N repeated inputs --
/// a static HTML form has a fixed input count, so a single field has no
/// hardcoded tag limit). Blank entries from stray commas are dropped.
def Form.parse_tags (raw : String) : List String :=
  if String.beq raw "" then List.empty
  else List.filter (fn (s : String) => Bool.not (String.beq s "")) (List.map String.trim (Strings.split_on "," raw))

pub def Form.tags_of (req : Request) : List String := Form.parse_tags (Form.value_or_empty "tags" req)

/// `group` is a single free-text field; a blank value means "no group".
def Form.parse_group (raw : String) : Option String :=
  let trimmed := String.trim raw in
  if String.beq trimmed "" then Option.none else Option.some trimmed

pub def Form.group_of (req : Request) : Option String := Form.parse_group (Form.value_or_empty "group" req)

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
