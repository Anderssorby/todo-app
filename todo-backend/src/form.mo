/// The one piece `http` does not provide: extracting the multipart
/// boundary from a Content-Type header and pulling the `title` field out
/// of the parsed parts. A plain `application/x-www-form-urlencoded` post
/// still has no decoder anywhere, so the no-JS form uses the multipart
/// enctype.
use http::body {Body.parse_multipart, Body.to_bytes_pure, MultipartPart}
use http::strings {Strings.split_on}
use http::types {Headers, Headers.empty, Request}
use std::list {List.filter, List.filter_map, List.length}

def Form.starts_with_bytes (needle : List U8) (bytes : List U8) : Bool :=
  match needle {
    List.empty => true,
    List.cons n rest_n => match bytes {
      List.cons b rest_b => U8.beq n b && Form.starts_with_bytes rest_n rest_b,
      List.empty => false,
    },
  }

def Form.drop_prefix (needle : List U8) (bytes : List U8) : List U8 :=
  match needle {
    List.empty => bytes,
    List.cons _ rest_n => match bytes {
      List.cons _ rest_b => Form.drop_prefix rest_n rest_b,
      List.empty => List.empty,
    },
  }

def Form.take_until (stop : U8) (bytes : List U8) : List U8 :=
  match bytes {
    List.empty => List.empty,
    List.cons b rest =>
      if U8.beq b stop then List.empty else List.cons b (Form.take_until stop rest),
  }

/// A quoted boundary (`boundary="abc"`) ends at the closing quote; an
/// unquoted one ends at `;` or end of header.
def Form.boundary_value (bytes : List U8) : List U8 :=
  match bytes {
    List.empty => List.empty,
    List.cons b rest =>
      if U8.beq b 34u8 then Form.take_until 34u8 rest
      else Form.take_until 59u8 bytes,
  }

#[terminating]
def Form.find_boundary_go (marker : List U8) (bytes : List U8) : Option String :=
  match bytes {
    List.empty => Option.none,
    List.cons _ rest =>
      if Form.starts_with_bytes marker bytes
      then Option.some (String.from_list (Form.boundary_value (Form.drop_prefix marker bytes)))
      else Form.find_boundary_go marker rest,
  }

pub def Form.boundary_of (content_type : String) : Option String :=
  Form.find_boundary_go (String.to_list "boundary=") (String.to_list content_type)

def Form.field (name : String) (part : MultipartPart) : Option String :=
  match part {
    MultipartPart.part part_name _filename _headers data =>
      if String.beq part_name name then Option.some (String.from_list data) else Option.none
  }

/// The parsed multipart parts of a request, or none when it isn't
/// multipart (the JSON path handles that).
pub def Form.parts_of (req : Request) : Option (List MultipartPart) :=
  match Headers.get "content-type" req.headers {
    Option.some ct =>
      if String.starts_with "multipart/form-data" ct then
        match Form.boundary_of ct {
          Option.some boundary => match Body.parse_multipart boundary (Body.to_bytes_pure req.body) {
            ok parts => Option.some parts,
            err _ => Option.none,
          },
          Option.none => Option.none,
        }
      else Option.none,
    Option.none => Option.none,
  }

/// The first value of a named multipart field, or none if absent / the
/// request isn't multipart.
pub def Form.value_of (name : String) (req : Request) : Option String :=
  match Form.parts_of req {
    Option.some parts => List.first (List.filter_map (Form.field name) parts),
    Option.none => Option.none,
  }

pub def Form.value_or_empty (name : String) (req : Request) : String :=
  Option.get_or_default "" (Form.value_of name req)

/// The `title` of a multipart create post, or none when the request is not
/// multipart (the JSON path handles that).
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
def test_boundary_unquoted : Bool :=
  match Form.boundary_of "multipart/form-data; boundary=abc123" {
    Option.some b => String.beq b "abc123",
    Option.none => false,
  }

#[test]
def test_boundary_quoted : Bool :=
  match Form.boundary_of "multipart/form-data; boundary=\"a b c\"; charset=utf-8" {
    Option.some b => String.beq b "a b c",
    Option.none => false,
  }

#[test]
def test_boundary_missing : Bool :=
  match Form.boundary_of "multipart/form-data" {
    Option.some _ => false,
    Option.none => true,
  }

#[test]
def test_value_of_reads_named_field : Bool :=
  let part := MultipartPart.part "notes" Option.none Headers.empty (String.to_list "hello") in
  match Form.field "notes" part {
    Option.some v => String.beq v "hello",
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
