//// Reading one field off a document or an event, the way the whole
//// application reads them: a string that is empty is a string that is not
//// there, and a field that is missing or of the wrong type is its default.
////
//// Documents are edited by hand and events come from every release on the
//// bus, so none of these fails.
////
//// The account a document change belongs to is here as well, because two
//// listeners -- do-not-disturb and the queue documents -- read it off the
//// same event.

import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo

/// The string at `path`, or `default` when it is missing or empty.
pub fn string_at(value: Value, path: List(String), default: String) -> String {
  case doc.get_string(value, path) {
    Ok("") -> default
    Ok(found) -> found
    Error(_) -> default
  }
}

/// The string at `path`, or nothing when it is missing or empty.
pub fn some_string(value: Value, path: List(String)) -> Option(String) {
  case doc.get_string(value, path) {
    Ok("") -> None
    Ok(found) -> Some(found)
    Error(_) -> None
  }
}

/// The integer at `path`, or `default`.
pub fn int_at(value: Value, path: List(String), default: Int) -> Int {
  doc.get_int(value, path) |> result.unwrap(default)
}

/// The integer at `path`, or nothing.
pub fn some_int(value: Value, path: List(String)) -> Option(Int) {
  doc.get_int(value, path) |> option.from_result
}

/// The boolean at `path`, or `default`.
pub fn bool_at(value: Value, path: List(String), default: Bool) -> Bool {
  doc.get_bool(value, path) |> result.unwrap(default)
}

/// The account a document change belongs to: the event says so, and where it
/// does not the database name does.
pub fn account_of_change(event: Value) -> Option(String) {
  case doc.get_string(event, ["Account-ID"]) {
    Ok("") | Error(Nil) ->
      doc.get_string(event, ["Database"])
      |> result.map(account_of_db)
      |> result.try(fn(id) {
        case kazoo.is_id(id) {
          True -> Ok(id)
          False -> Error(Nil)
        }
      })
      |> option.from_result
    Ok(account_id) -> Some(account_id)
  }
}

/// An encoded account database back to the account id: `account%2Fab%2Fcd%2F`
/// and the rest, with the separators and the prefix taken out.
pub fn account_of_db(database: String) -> String {
  database
  |> string.replace("%2F", "")
  |> string.replace("%2f", "")
  |> string.replace("/", "")
  |> drop_prefix("account")
}

fn drop_prefix(text: String, prefix: String) -> String {
  case string.starts_with(text, prefix) {
    True -> string.drop_start(text, string.length(prefix))
    False -> text
  }
}
