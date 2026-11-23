//// The agent login lamp: the state it shows, the address it is published
//// on, and when there is nothing to publish at all.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake

import callcenter/availability
import callcenter/presence
import callcenter/records
import callcenter/types.{Available, AvailableOnDemand, LoggedOut, OnBreak}

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const agent = "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91"

const realm = "one.example.test"

// --- The state --------------------------------------------------------------

/// The whole mapping, every row of it.
pub fn state_test() {
  assert presence.state(LoggedOut, on_queue_call: False) == "terminated"
  assert presence.state(OnBreak, on_queue_call: False) == "terminated"
  assert presence.state(Available, on_queue_call: False) == "confirmed"
  assert presence.state(AvailableOnDemand, on_queue_call: False) == "confirmed"

  // On a queue call the call decides, whatever the availability says: a
  // change made mid-call does not put the lamp out under a talking agent.
  assert presence.state(Available, on_queue_call: True) == "early"
  assert presence.state(AvailableOnDemand, on_queue_call: True) == "early"
  assert presence.state(OnBreak, on_queue_call: True) == "early"
  assert presence.state(LoggedOut, on_queue_call: True) == "early"
}

// --- The address, from what the documents say -------------------------------

/// Without an override the prefix goes in front of the user's presence id.
pub fn the_default_address_test() {
  assert presence.address_of(
      override: None,
      presence_id: Some("101"),
      prefix: "*22",
      realm: realm,
    )
    == Ok("*22101@" <> realm)
  assert presence.address_of(
      override: None,
      presence_id: Some("101"),
      prefix: "*77",
      realm: realm,
    )
    == Ok("*77101@" <> realm)
}

/// An empty prefix is the default one, never "no prefix", because no prefix
/// would be the user's ordinary BLF.
pub fn an_empty_prefix_is_the_default_test() {
  assert presence.effective_prefix("") == "*22"
  assert presence.effective_prefix("  ") == "*22"
  assert presence.effective_prefix("*9") == "*9"
  assert presence.address_of(
      override: None,
      presence_id: Some("101"),
      prefix: "",
      realm: realm,
    )
    == Ok("*22101@" <> realm)
}

/// The override wins, qualified with the realm unless it carries its own.
pub fn the_override_test() {
  assert presence.address_of(
      override: Some("agents-login"),
      presence_id: Some("101"),
      prefix: "*22",
      realm: realm,
    )
    == Ok("agents-login@" <> realm)
  assert presence.address_of(
      override: Some("lamp@" <> realm),
      presence_id: None,
      prefix: "*22",
      realm: realm,
    )
    == Ok("lamp@" <> realm)
  // An empty override is none.
  assert presence.address_of(
      override: Some(""),
      presence_id: Some("101"),
      prefix: "*22",
      realm: realm,
    )
    == Ok("*22101@" <> realm)
}

/// Nothing to address: no realm, or nothing on the user to address them by.
/// The user id is never a fallback.
pub fn no_address_test() {
  assert presence.address_of(
      override: None,
      presence_id: None,
      prefix: "*22",
      realm: realm,
    )
    == Error(presence.NoPresenceId)
  assert presence.address_of(
      override: None,
      presence_id: Some(""),
      prefix: "*22",
      realm: realm,
    )
    == Error(presence.NoPresenceId)
  assert presence.address_of(
      override: None,
      presence_id: Some("101"),
      prefix: "*22",
      realm: "",
    )
    == Error(presence.NoRealm)
}

/// The lamp never lands on the user's own presence address, which is their
/// ordinary line or presence BLF: not with any prefix, not with an empty
/// one, and not with an override that names it.
pub fn never_the_users_own_address_test() {
  let own = "101@" <> realm
  let prefixes = ["", " ", "*22", "*9", "#", "1"]
  let overrides = [None, Some(""), Some("101"), Some(own), Some("elsewhere")]
  list.each(prefixes, fn(prefix) {
    list.each(overrides, fn(override) {
      let address =
        presence.address_of(
          override: override,
          presence_id: Some("101"),
          prefix: prefix,
          realm: realm,
        )
      assert address != Ok(own)
      assert address != Ok("101")
    })
  })
  // An override naming the user's own address is set aside for the default.
  assert presence.address_of(
      override: Some("101"),
      presence_id: Some("101"),
      prefix: "*22",
      realm: realm,
    )
    == Ok("*22101@" <> realm)
}

// --- The address, from the datastore ----------------------------------------

fn cluster() -> fake.Fake {
  let f = fake.new()
  fake.put_account(f, account, realm, [])
  user(f, agent, Some("101"))
  f
}

fn user(f: fake.Fake, user_id: String, presence_id: option.Option(String)) {
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object_some([
      #("_id", Some(doc.String(user_id))),
      #("pvt_type", Some(doc.String("user"))),
      #("first_name", Some(doc.String("Jane"))),
      #("presence_id", option.map(presence_id, doc.String)),
    ]),
  )
}

fn an_agent(f: fake.Fake, fields: List(#(String, doc.Value))) {
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(records.agent_document_id(agent))),
      #("pvt_type", doc.String(records.agent_type)),
      #("agent_id", doc.String(agent)),
      #("availability", doc.String("available")),
      ..fields
    ]),
  )
}

fn configs(f: fake.Fake, prefix: String) {
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String("configs_callcenter")),
      #("agent_presence_prefix", doc.String(prefix)),
    ]),
  )
}

/// The prefix: the account's `configs_callcenter`, then `system_config`,
/// then `*22`; empty anywhere is `*22`.
pub fn the_prefix_test() {
  let f = cluster()
  let kz = fake.kazoo(f)
  assert presence.prefix(kz, account) == "*22"

  fake.put_config(f, "callcenter.agent_presence_prefix", doc.String("*77"))
  assert presence.prefix(kz, account) == "*77"

  configs(f, "*88")
  assert presence.prefix(kz, account) == "*88"

  configs(f, "")
  assert presence.prefix(kz, account) == "*22"
}

/// A user without a `callcenter_agent` document is not an agent, and nothing
/// is published for them however they are set up.
pub fn only_agents_have_a_lamp_test() {
  let kz = fake.kazoo(cluster())
  assert presence.address(kz, account, agent) == Error(presence.NotAnAgent)
  assert presence.publish(kz, account, agent, presence.confirmed)
    == Error(presence.NotAnAgent)
}

/// An agent document that cannot be read publishes nothing -- not the
/// prefixed default, which would drop an override it may hold.
pub fn an_unreadable_agent_has_no_lamp_test() {
  let f = cluster()
  an_agent(f, [#("presence_id", doc.String("sales-agents"))])
  let kz = fake.kazoo(f)
  let failing =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, open_cache_doc: fn(db, id) {
        case id == records.agent_document_id(agent) {
          True -> Error(kazoo.Unavailable)
          False -> kz.datamgr.open_cache_doc(db, id)
        }
      }),
    )
  assert presence.address(failing, account, agent) == Error(presence.NotAnAgent)
  assert presence.publish(failing, account, agent, presence.confirmed)
    == Error(presence.NotAnAgent)
  // Read again, it is the override.
  assert presence.address(kz, account, agent) == Ok("sales-agents@" <> realm)
}

pub fn an_agent_is_addressed_by_the_prefix_test() {
  let f = cluster()
  an_agent(f, [])
  let kz = fake.kazoo(f)
  assert presence.address(kz, account, agent) == Ok("*22101@" <> realm)

  configs(f, "*88")
  assert presence.address(kz, account, agent) == Ok("*88101@" <> realm)
}

/// An override naming the agent's own presence address is their ordinary
/// BLF, so it is set aside for the account's prefix -- the one configured,
/// not `*22`.
pub fn an_override_of_the_own_address_takes_the_account_prefix_test() {
  let f = cluster()
  configs(f, "*9")
  let kz = fake.kazoo(f)

  an_agent(f, [#("presence_id", doc.String("101"))])
  assert presence.address(kz, account, agent) == Ok("*9101@" <> realm)

  an_agent(f, [#("presence_id", doc.String("101@" <> realm))])
  assert presence.address(kz, account, agent) == Ok("*9101@" <> realm)
  let assert Ok(published) =
    presence.publish(kz, account, agent, presence.confirmed)
  assert published.id == "*9101@" <> realm

  // Any other override still wins over the prefix.
  an_agent(f, [#("presence_id", doc.String("sales-agents"))])
  assert presence.address(kz, account, agent) == Ok("sales-agents@" <> realm)
}

/// An agent with no presence id and no override publishes nothing.
pub fn an_agent_without_a_presence_id_test() {
  let f = cluster()
  user(f, agent, None)
  an_agent(f, [])
  let kz = fake.kazoo(f)
  assert presence.address(kz, account, agent) == Error(presence.NoPresenceId)
  assert presence.publish(kz, account, agent, presence.confirmed)
    == Error(presence.NoPresenceId)
}

/// The override a feature code's node stored is where every later change
/// publishes, whoever makes it.
pub fn the_stored_override_is_reused_test() {
  let f = cluster()
  let kz = fake.kazoo(f)
  let assert Ok(_) =
    availability.set(kz, account, agent, Available, availability.Ui)
  assert presence.address(kz, account, agent) == Ok("*22101@" <> realm)

  assert availability.set_presence_id(kz, account, agent, "sales-agents")
    == Ok(True)
  assert presence.address(kz, account, agent) == Ok("sales-agents@" <> realm)
  // Storing it again is not a move.
  assert availability.set_presence_id(kz, account, agent, "sales-agents")
    == Ok(False)

  // A change from anywhere else still publishes there, and the availability
  // survived the write.
  let assert Ok(_) =
    availability.set(kz, account, agent, OnBreak, availability.Supervisor)
  let assert Ok(published) =
    presence.publish(kz, account, agent, presence.terminated)
  assert published.id == "sales-agents@" <> realm
  let assert Ok(now) = availability.get(kz, account, agent)
  assert now.availability == OnBreak
}

/// One address is one dialog: the call id is a function of the address.
pub fn one_dialog_per_address_test() {
  let first = presence.update("*22101@" <> realm, presence.confirmed)
  let again = presence.update("*22101@" <> realm, presence.early)
  assert first.call_id == again.call_id
  assert presence.update("*22102@" <> realm, presence.early).call_id
    != first.call_id
}

/// An account with no realm answers why rather than crashing the
/// availability write that called it.
pub fn a_realm_is_needed_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  assert presence.address(kz, account, agent) == Error(presence.NoRealm)
}

/// The payload is a state-only dialog with the address at both ends, which
/// is what `kapi_presence:update` validates and omnipresence relays.
pub fn message_test() {
  let message =
    presence.message(presence.Presence(
      "*222001@one.example.test",
      "confirmed",
      "callcenter-abcd1234",
    ))
  assert doc.get_string(message, ["Presence-ID"])
    == Ok("*222001@one.example.test")
  assert doc.get_string(message, ["From"]) == Ok("sip:*222001@one.example.test")
  assert doc.get_string(message, ["To"]) == Ok("sip:*222001@one.example.test")
  assert doc.get_string(message, ["From-User"]) == Ok("*222001")
  assert doc.get_string(message, ["From-Realm"]) == Ok("one.example.test")
  assert doc.get_string(message, ["To-User"]) == Ok("*222001")
  assert doc.get_string(message, ["To-Realm"]) == Ok("one.example.test")
  assert doc.get_string(message, ["State"]) == Ok("confirmed")
  assert doc.get_string(message, ["Call-ID"]) == Ok("callcenter-abcd1234")
}

// --- What the dispatcher remembers -------------------------------------------

/// A publish function that says what it was asked to publish.
fn recorder() -> #(
  process.Subject(#(String, String)),
  fn(String, String) -> Nil,
) {
  let published = process.new_subject()
  #(published, fn(agent_id, state) {
    process.send(published, #(agent_id, state))
  })
}

fn drain(subject: process.Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(one) -> drain(subject, [one, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// Only a change publishes.
pub fn the_lamps_publish_on_change_test() {
  let #(published, publish) = recorder()
  let lamps =
    presence.lamps()
    |> presence.connected("ann", publish)
    |> presence.connected("ann", publish)
    |> presence.ended("ann", Available, publish)
    |> presence.ended("ann", Available, publish)
  assert drain(published, [])
    == [#("ann", presence.early), #("ann", presence.confirmed)]
  assert presence.shown(lamps, "ann") == Some(presence.confirmed)
}

/// An availability heard mid-call puts the lamp back to `early`, even though
/// `early` is what was last shown: somebody else has published since.
pub fn an_availability_heard_mid_call_test() {
  let #(published, publish) = recorder()
  let lamps =
    presence.lamps()
    |> presence.connected("ann", publish)
    |> presence.heard("ann", True, publish)
  assert drain(published, [])
    == [#("ann", presence.early), #("ann", presence.early)]
  assert presence.shown(lamps, "ann") == Some(presence.early)

  // Off a call, hearing one only forgets: `availability.set` published.
  let lamps = presence.heard(lamps, "bob", False, publish)
  assert drain(published, []) == []
  assert presence.shown(lamps, "bob") == None
}
