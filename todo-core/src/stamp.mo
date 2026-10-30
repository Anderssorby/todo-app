/// Timestamp and due-date formatting for the shared view.
///
/// The `time` mote supplies parsing and calendar conversion; this module adds
/// the app's policy on top of it:
///
///   * storage is UTC ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`), and a legacy SQLite
///     `datetime('now')` value (`YYYY-MM-DD HH:MM:SS`) is accepted and
///     normalised on read;
///   * a user's display offset is a fixed number of minutes (`-720..840`,
///     multiple of 15). There is no IANA database or DST rule at this pinned
///     Monad revision, so the offset is what the settings control stores;
///   * due dates are calendar dates (`YYYY-MM-DD`) and are never offset-shifted.
///
/// No wall clock lives here: `Instant.now` is `CLOCK_MONOTONIC` on compiled
/// native binaries, so the backend takes "now" from SQLite's `strftime`.
use time::types {Date, DateTime}
use time::date {Date.to_iso}
use time::datetime {DateTime.of_instant, DateTime.to_instant}
use time::iso8601 {Date.parse_iso, DateTime.parse}
use parsec::core {ParseResult}
open ParseResult {fail, success}
use lib::storage {Todo}
use lib::user {UserRef}

pub def Stamp.pad2 (n : I64) : String :=
  if I64.lt n 10i64 then String.concat "0" (I64.to_string n) else I64.to_string n

/// The largest real-world offset is UTC+14:00 and the smallest UTC-12:00.
pub def Stamp.valid_offset (minutes : I64) : Bool :=
  let in_range :=
    Bool.not (I64.lt minutes (-720i64)) && Bool.not (I64.gt minutes 840i64) in
  let rem := I64.sub minutes (I64.mul (I64.div minutes 15i64) 15i64) in
  Bool.and in_range (I64.beq rem 0i64)

pub def Stamp.validate_offset (minutes : I64) : Result String I64 :=
  if Stamp.valid_offset minutes
  then Result.ok minutes
  else Result.err "utc_offset_minutes must be a multiple of 15 between -720 and 840"

/// `UTC`, `UTC+02:00`, `UTC-03:30`.
pub def Stamp.offset_label (minutes : I64) : String :=
  if I64.beq minutes 0i64 then "UTC"
  else
    let negative := I64.lt minutes 0i64 in
    let magnitude := if negative then I64.neg minutes else minutes in
    let hours := I64.div magnitude 60i64 in
    let mins := I64.sub magnitude (I64.mul hours 60i64) in
    String.concat (if negative then "UTC-" else "UTC+")
      (String.concat (Stamp.pad2 hours) (String.concat ":" (Stamp.pad2 mins)))

/// Every half-hour offset from UTC-12:00 to UTC+14:00, ascending. The
/// settings control renders one `<option>` per pair.
#[partial]
def Stamp.offset_choices_go (minutes : I64) (acc : List (Pair I64 String))
    : List (Pair I64 String) :=
  if I64.lt minutes (-720i64) then acc
  else Stamp.offset_choices_go (I64.sub minutes 30i64)
    (List.cons (Pair.pair minutes (Stamp.offset_label minutes)) acc)

pub def Stamp.offset_choices : List (Pair I64 String) :=
  Stamp.offset_choices_go 840i64 List.empty

/// A strict `YYYY-MM-DD` date (the whole input must be consumed).
pub def Stamp.parse_date (s : String) : Option Date :=
  match Date.parse_iso s {
    success rest date => if String.is_empty rest then Option.some date else Option.none,
    fail _ => Option.none,
  }

/// A stored timestamp, accepting both the ISO form and the legacy SQLite
/// `datetime('now')` shape (`YYYY-MM-DD HH:MM:SS`, interpreted as UTC).
pub def Stamp.parse (raw : String) : Option DateTime :=
  match DateTime.parse raw {
    Result.ok dt => Option.some dt,
    Result.err _ => Stamp.parse_legacy raw,
  }

def Stamp.parse_legacy (raw : String) : Option DateTime :=
  if I64.beq (String.length raw) 19i64
  then
    if String.beq (String.slice raw 10 1) " "
    then
      let iso := String.concat (String.slice raw 0 10)
        (String.concat "T" (String.concat (String.slice raw 11 8) "Z")) in
      match DateTime.parse iso {
        Result.ok dt => Option.some dt,
        Result.err _ => Option.none,
      }
    else Option.none
  else Option.none

/// `YYYY-MM-DD HH:MM` at the given display offset.
pub def Stamp.format_local (offset_minutes : I64) (raw : String) : Option String :=
  match Stamp.parse raw {
    Option.none => Option.none,
    Option.some dt =>
      let local := DateTime.of_instant (DateTime.to_instant dt) offset_minutes in
      Option.some (Stamp.fields_text local),
  }

def Stamp.fields_text (dt : DateTime) : String :=
  match dt {
    mk date time _offset =>
      match date {
        mk year month day =>
          match time {
            mk hour minute _second _nanos =>
              String.concat (I64.to_string year)
                (String.concat "-" (String.concat (Stamp.pad2 month)
                  (String.concat "-" (String.concat (Stamp.pad2 day)
                    (String.concat " " (String.concat (Stamp.pad2 hour)
                      (String.concat ":" (Stamp.pad2 minute)))))))),
          },
      },
  }

/// Canonicalise a due-date field: blanks become `None`, a valid date is
/// rewritten as `YYYY-MM-DD`, anything else is an error the caller returns as
/// a 400 rather than storing.
pub def Stamp.canonical_due (raw : String) : Result String (Option String) :=
  let trimmed := String.trim raw in
  if String.is_empty trimmed then Result.ok Option.none
  else
    match Stamp.parse_date trimmed {
      Option.some date => Result.ok (Option.some (Date.to_iso date)),
      Option.none => Result.err "due_at must be a valid YYYY-MM-DD date",
    }

/// A due-date label. Date-only values are not offset-shifted; a full
/// timestamp (an older payload) is rendered at the display offset.
pub def Stamp.due_label (offset_minutes : I64) (due : Option String) : Option String :=
  match due {
    Option.none => Option.none,
    Option.some raw =>
      match Stamp.parse_date raw {
        Option.some date => Option.some (String.concat "Due " (Date.to_iso date)),
        Option.none =>
          match Stamp.format_local offset_minutes raw {
            Option.some text => Option.some (String.concat "Due " text),
            Option.none => Option.none,
          },
      },
  }

pub def Stamp.created_line (offset_minutes : I64) (t : Todo) : Option String :=
  match t.created_at {
    Option.none => Option.none,
    Option.some raw => Stamp.audit_line "Created" offset_minutes raw t.created_by,
  }

pub def Stamp.updated_line (offset_minutes : I64) (t : Todo) : Option String :=
  match t.updated_at {
    Option.none => Option.none,
    Option.some raw =>
      if String.beq raw (Option.get_or_default "" t.created_at)
      then Option.none
      else Stamp.audit_line "Updated" offset_minutes raw t.updated_by,
  }

def Stamp.audit_line (verb : String) (offset_minutes : I64) (raw : String)
    (actor : Option UserRef) : Option String :=
  match Stamp.format_local offset_minutes raw {
    Option.none => Option.none,
    Option.some text =>
      let line := String.concat verb (String.concat " " text) in
      Option.some (match actor {
        Option.some u => String.concat line (String.concat " by " u.name),
        Option.none => line,
      }),
  }
