/// JSON text helpers shared by the native derive codec and the wasm-safe
/// codec.
///
/// This module has no derive/macro dependency, so the SPA can load it
/// without pulling in `codec.mo`'s `reflect_type_info!` expansion. It also
/// avoids `Json.to_string`: that serializer's number arm reaches the
/// web-gated `F64.to_string`, while the parser only ever produces
/// `Json.Number.int`, so `json_to_string` renders integers and maps a
/// manually constructed float to `null`.
use todo_core::storage {Status}
use json::json {Json}
use std::list {List.intercalate}
use std::map {BTreeMap, BTreeMap.to_list}

def JsonText.hex_digit_char (n : U8) : U8 :=
  if U8.lt n 10u8 then U8.add n 48u8 else U8.add n 87u8

def JsonText.control_escape (b : U8) : String :=
  let hi : U8 := U8.div b 16u8 in
  let lo : U8 := U8.sub b (U8.mul hi 16u8) in
  String.concat "\\u00"
    (String.from_list [JsonText.hex_digit_char hi, JsonText.hex_digit_char lo])

pub def JsonText.escape_char (b : U8) : String :=
  if U8.beq b 34u8 then "\\\""
  else if U8.beq b 92u8 then "\\\\"
  else if U8.beq b 8u8 then "\\b"
  else if U8.beq b 12u8 then "\\f"
  else if U8.beq b 10u8 then "\\n"
  else if U8.beq b 13u8 then "\\r"
  else if U8.beq b 9u8 then "\\t"
  else if U8.lt b 32u8 then JsonText.control_escape b
  else String.from_list (List.cons b List.empty)

pub def JsonText.escape_json_string (s : String) : String :=
  String.concat_list (List.map JsonText.escape_char (String.to_list s))

pub def JsonText.json_string (s : String) : String :=
  String.concat "\"" (String.concat (JsonText.escape_json_string s) "\"")

def JsonText.json_pair_to_string (p : Pair String Json) : String :=
  match p {
    Pair.pair k v =>
      String.concat (JsonText.json_string k)
        (String.concat ":" (JsonText.json_to_string v))
  }

pub def JsonText.json_to_string (j : Json) : String :=
  match j {
    Json.null => "null",
    Json.bool b => if b then "true" else "false",
    Json.num n => match n {
      Json.Number.int i => I64.to_string i,
      Json.Number.float _ => "null",
    },
    Json.str s => JsonText.json_string s,
    Json.array xs =>
      String.concat "["
        (String.concat (List.intercalate "," (List.map JsonText.json_to_string xs)) "]"),
    Json.object o =>
      String.concat "{"
        (String.concat
          (List.intercalate "," (List.map JsonText.json_pair_to_string (BTreeMap.to_list o)))
          "}"),
  }

pub def JsonText.option_string_to_json (o : Option String) : String :=
  match o {
    Option.some s => JsonText.json_string s,
    Option.none => "null",
  }

pub def JsonText.group_to_json (group : Option String) : String :=
  JsonText.option_string_to_json group

pub def JsonText.status_to_json (s : Status) : String :=
  JsonText.json_string (Status.to_string s)

pub def JsonText.tags_to_json (tags : List String) : String :=
  JsonText.json_to_string
    (Json.make_array (List.map (fn (t : String) => Json.make_str t) tags))
