//// Document values.
////
//// Everything that crosses the data boundary is one of these: a document read
//// from CouchDB (`kz_json:to_map/1` output, decoded here), a settings layer, a
//// request body. Keeping one type for all of them is what makes the settings
//// resolver, the validator and the API envelopes work on the same values.
////
//// Objects are dictionaries, so a merge is a merge and key order is not
//// meaningful; rendering to JSON sorts the keys, which keeps responses and
//// stored documents byte-stable.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Value {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  List(List(Value))
  Object(Dict(String, Value))
}

/// An object from a list of members, last one wins.
pub fn object(members: List(#(String, Value))) -> Value {
  Object(dict.from_list(members))
}

/// An object with the members whose value is `Some`.
pub fn object_some(members: List(#(String, Option(Value)))) -> Value {
  members
  |> list.filter_map(fn(member) {
    case member.1 {
      Some(value) -> Ok(#(member.0, value))
      None -> Error(Nil)
    }
  })
  |> object
}

pub fn is_object(value: Value) -> Bool {
  case value {
    Object(_) -> True
    _ -> False
  }
}

/// The members of an object, sorted by key. Anything else has none.
pub fn members(value: Value) -> List(#(String, Value)) {
  case value {
    Object(fields) ->
      fields
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    _ -> []
  }
}

/// The value at a path, `Error(Nil)` when any segment is missing or the value
/// on the way is not an object. A stored `null` is a value, not a miss.
pub fn get(value: Value, path: List(String)) -> Result(Value, Nil) {
  case path {
    [] -> Ok(value)
    [key, ..rest] ->
      case value {
        Object(fields) ->
          dict.get(fields, key) |> result.try(fn(v) { get(v, rest) })
        _ -> Error(Nil)
      }
  }
}

pub fn get_string(value: Value, path: List(String)) -> Result(String, Nil) {
  case get(value, path) {
    Ok(String(text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

pub fn get_int(value: Value, path: List(String)) -> Result(Int, Nil) {
  case get(value, path) {
    Ok(Int(number)) -> Ok(number)
    _ -> Error(Nil)
  }
}

pub fn get_bool(value: Value, path: List(String)) -> Result(Bool, Nil) {
  case get(value, path) {
    Ok(Bool(bool)) -> Ok(bool)
    _ -> Error(Nil)
  }
}

pub fn get_list(value: Value, path: List(String)) -> Result(List(Value), Nil) {
  case get(value, path) {
    Ok(List(items)) -> Ok(items)
    _ -> Error(Nil)
  }
}

/// The strings of a list of strings, skipping anything else.
pub fn strings(value: Value, path: List(String)) -> List(String) {
  case get(value, path) {
    Ok(List(items)) ->
      list.filter_map(items, fn(item) {
        case item {
          String(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Set a path, creating the objects on the way. A non-object on the path is
/// replaced.
pub fn set(value: Value, path: List(String), to: Value) -> Value {
  case path {
    [] -> to
    [key, ..rest] -> {
      let fields = case value {
        Object(fields) -> fields
        _ -> dict.new()
      }
      let child = dict.get(fields, key) |> result.unwrap(Object(dict.new()))
      Object(dict.insert(fields, key, set(child, rest, to)))
    }
  }
}

/// Remove a path. Missing paths are left alone.
pub fn delete(value: Value, path: List(String)) -> Value {
  case path, value {
    [], _ -> value
    [key], Object(fields) -> Object(dict.delete(fields, key))
    [key, ..rest], Object(fields) ->
      case dict.get(fields, key) {
        Ok(child) -> Object(dict.insert(fields, key, delete(child, rest)))
        Error(_) -> value
      }
    _, _ -> value
  }
}

/// Deep merge: `over` wins key by key, objects merge, everything else
/// replaces. This is how one settings layer sits on the one below it.
pub fn merge(base: Value, over: Value) -> Value {
  case base, over {
    Object(base_fields), Object(over_fields) ->
      Object(
        dict.fold(over_fields, base_fields, fn(acc, key, value) {
          case dict.get(acc, key) {
            Ok(existing) -> dict.insert(acc, key, merge(existing, value))
            Error(_) -> dict.insert(acc, key, value)
          }
        }),
      )
    _, _ -> over
  }
}

/// Deep merge in which an explicit `null` removes the key, which is what
/// Crossbar's PATCH does.
pub fn patch(base: Value, over: Value) -> Value {
  case base, over {
    Object(base_fields), Object(over_fields) ->
      Object(
        dict.fold(over_fields, base_fields, fn(acc, key, value) {
          case value, dict.get(acc, key) {
            Null, _ -> dict.delete(acc, key)
            _, Ok(existing) -> dict.insert(acc, key, patch(existing, value))
            _, Error(_) -> dict.insert(acc, key, value)
          }
        }),
      )
    _, _ -> over
  }
}

/// Every leaf as a dotted path, sorted. A leaf is anything that is not an
/// object: a scalar, a list, or an empty object.
pub fn flatten(value: Value) -> List(#(String, Value)) {
  flatten_prefixed(value, "")
}

fn flatten_prefixed(value: Value, prefix: String) -> List(#(String, Value)) {
  case value {
    Object(fields) ->
      case dict.is_empty(fields) {
        True -> leaf(value, prefix)
        False ->
          members(value)
          |> list.flat_map(fn(member) {
            let path = case prefix {
              "" -> member.0
              _ -> prefix <> "." <> member.0
            }
            flatten_prefixed(member.1, path)
          })
      }
    _ -> leaf(value, prefix)
  }
}

fn leaf(value: Value, prefix: String) -> List(#(String, Value)) {
  case prefix {
    "" -> []
    _ -> [#(prefix, value)]
  }
}

/// A dotted path back into its segments.
pub fn path(dotted: String) -> List(String) {
  string.split(dotted, ".")
}

pub fn to_json(value: Value) -> Json {
  case value {
    Null -> json.null()
    Bool(bool) -> json.bool(bool)
    Int(number) -> json.int(number)
    Float(number) -> json.float(number)
    String(text) -> json.string(text)
    List(items) -> json.preprocessed_array(list.map(items, to_json))
    Object(_) ->
      json.object(list.map(members(value), fn(m) { #(m.0, to_json(m.1)) }))
  }
}

pub fn to_string(value: Value) -> String {
  value |> to_json |> json.to_string
}

/// A value as the string a template or a vendor file wants. Objects and lists
/// have no scalar form and render empty.
pub fn to_text(value: Value) -> String {
  case value {
    String(text) -> text
    Int(number) -> int.to_string(number)
    Float(number) -> float.to_string(number)
    Bool(True) -> "true"
    Bool(False) -> "false"
    _ -> ""
  }
}

pub fn parse(text: String) -> Result(Value, Nil) {
  json.parse(text, decoder()) |> result.replace_error(Nil)
}

/// Decodes both shapes the boundary produces: `kz_json:to_map/1` output and
/// parsed JSON. They agree on everything but their origin.
///
/// An atom is a string, both as a key and as a value, because that is what it
/// is on the wire: `kz_json` holds atoms happily -- `kapps_call:to_json/1`
/// hands back a `Key-Value-Store` keyed by `owner_id` and `context-source`,
/// and every `kvs_store` with an atom key puts one there -- and `kz_json`'s
/// own encoder writes an atom out as its name. `true`, `false` and
/// `undefined` are taken by the decoders above this one, so they keep the
/// meaning they have everywhere else.
///
/// Without this a single atom anywhere in a document makes the whole decode
/// fail, and `from_dynamic` answers `Null` for all of it: a call that went
/// out on the bus as `"Call": null`, and a `kapi` validator refusing the
/// message with no sign of which field was wrong.
pub fn decoder() -> Decoder(Value) {
  use <- decode.recursive
  decode.one_of(decode.string |> decode.map(String), [
    decode.bool |> decode.map(Bool),
    decode.int |> decode.map(Int),
    decode.float |> decode.map(Float),
    decode.list(decoder()) |> decode.map(List),
    decode.dict(key_decoder(), decoder()) |> decode.map(Object),
    null_decoder(),
    atom_decoder() |> decode.map(String),
  ])
}

/// An object's keys: a string, or an atom read as its name.
fn key_decoder() -> Decoder(String) {
  decode.one_of(decode.string, [atom_decoder()])
}

fn atom_decoder() -> Decoder(String) {
  atom.decoder() |> decode.map(atom.to_string)
}

fn null_decoder() -> Decoder(Value) {
  decode.new_primitive_decoder("Null", fn(data) {
    case decode.run(data, decode.optional(decode.dynamic)) {
      Ok(option.None) -> Ok(Null)
      _ -> Error(Null)
    }
  })
}

/// Decode a document that came from the data layer. Anything that is not a
/// value at all decodes as `null` rather than failing: a document the
/// application did not write is data, not a crash.
pub fn from_dynamic(data: Dynamic) -> Value {
  case decode.run(data, decoder()) {
    Ok(value) -> value
    Error(_) -> Null
  }
}
