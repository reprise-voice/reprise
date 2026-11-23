//// User documents, for the owner of a device: the presence id and the name
//// that presence and personal-parking keys are labelled with.

import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}

pub type User {
  User(
    id: String,
    first_name: Option(String),
    last_name: Option(String),
    presence_id: Option(String),
    enabled: Bool,
    timezone: Option(String),
    doc: Value,
  )
}

pub fn fetch(
  kz: Kazoo,
  account_id: String,
  user_id: String,
) -> Result(User, Error) {
  use value <- result.try(kz.datamgr.open_cache_doc(
    kazoo.account_db(account_id),
    user_id,
  ))
  Ok(from_doc(user_id, value))
}

pub fn from_doc(user_id: String, value: Value) -> User {
  User(
    id: user_id,
    first_name: doc.get_string(value, ["first_name"]) |> option.from_result,
    last_name: doc.get_string(value, ["last_name"]) |> option.from_result,
    presence_id: doc.get_string(value, ["presence_id"]) |> option.from_result,
    enabled: doc.get_bool(value, ["enabled"]) |> result.unwrap(True),
    timezone: doc.get_string(value, ["timezone"]) |> option.from_result,
    doc: value,
  )
}

/// The label a key gets: `kzd_users:name/1`, which is first and last name
/// joined by a space, then the document's own `name`, then nothing.
pub fn name(user: User) -> Option(String) {
  let joined =
    string.trim(
      option.unwrap(user.first_name, "")
      <> " "
      <> option.unwrap(user.last_name, ""),
    )
  case joined {
    "" -> doc.get_string(user.doc, ["name"]) |> option.from_result
    _ -> Some(joined)
  }
}

pub fn presence_id(user: User) -> Option(String) {
  case user.presence_id {
    Some("") -> None
    other -> other
  }
}
