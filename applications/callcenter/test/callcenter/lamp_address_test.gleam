//// The address of an agent's login lamp, which this application works out in
//// `presence.address_of`. Whatever provisions an `agent_login` key has to
//// point it at the same address, so these cases are the rule to copy: a
//// change here that the provisioning side does not follow is a lamp and a
//// key that no longer meet.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

import callcenter/presence

const realm = "one.example.test"

/// `#(override, presence_id, prefix, realm, address)`: the address, or
/// `Error(Nil)` for none.
fn cases() -> List(
  #(Option(String), Option(String), String, String, Result(String, Nil)),
) {
  [
    // Without an override: the prefix in front of the presence id, an
    // empty or blank prefix being `*22`.
    #(None, Some("101"), "*22", realm, Ok("*22101@" <> realm)),
    #(None, Some("101"), "*77", realm, Ok("*77101@" <> realm)),
    #(None, Some("101"), "", realm, Ok("*22101@" <> realm)),
    #(None, Some("101"), "  ", realm, Ok("*22101@" <> realm)),
    // The override wins, qualified with the realm unless it has its own.
    #(
      Some("agents-login"),
      Some("101"),
      "*22",
      realm,
      Ok("agents-login@" <> realm),
    ),
    #(Some("lamp@" <> realm), None, "*22", realm, Ok("lamp@" <> realm)),
    #(
      Some("lamp@elsewhere.test"),
      Some("101"),
      "*9",
      realm,
      Ok("lamp@elsewhere.test"),
    ),
    // An empty override is none.
    #(Some(""), Some("101"), "*22", realm, Ok("*22101@" <> realm)),
    // An override naming the user's own address is set aside.
    #(Some("101"), Some("101"), "*22", realm, Ok("*22101@" <> realm)),
    #(Some("101@" <> realm), Some("101"), "*9", realm, Ok("*9101@" <> realm)),
    // Nothing to address.
    #(None, None, "*22", realm, Error(Nil)),
    #(None, Some(""), "*22", realm, Error(Nil)),
    #(Some(""), None, "*22", realm, Error(Nil)),
    #(None, Some("101"), "*22", "", Error(Nil)),
    #(Some("lamp"), None, "*22", "", Error(Nil)),
  ]
}

pub fn the_address_cases_test() {
  list.each(cases(), fn(case_) {
    let #(override, presence_id, prefix, realm, address) = case_
    assert presence.address_of(
        override: override,
        presence_id: presence_id,
        prefix: prefix,
        realm: realm,
      )
      |> result.replace_error(Nil)
      == address
  })
}
