//// The agent login lamp: a BLF key that shows whether an agent is taking
//// calls and whether they are on one.
////
//// It is opt-in. Nothing here publishes on a user's own presence id, so a
//// user's ordinary line and presence keys are never touched: the lamp lights
//// only a key provisioned as `agent_login`, which whatever provisions the
//// phone points at the address below. Only agents are published for -- a
//// user with a `callcenter_agent-<user_id>` document. A document that
//// cannot be read publishes nothing.
////
//// ## Where
////
//// 1. The `presence_id` stored on the agent's `callcenter_agent-<user_id>`
////    document, which the `callcenter_agent` action writes from its node's
////    `presence_id` whenever the node that ran has one. A node without one
////    leaves the stored value alone, so every later change -- from Crossbar,
////    do-not-disturb, `max_no_answer`, anywhere -- publishes where the agent
////    last pointed it, as acdc did. A value with no `@` is qualified with the
////    account realm. A value that is the agent's own presence address is not
////    used, because that is their ordinary BLF.
//// 2. Otherwise `<prefix><user presence_id>@<account realm>`. The prefix is
////    `agent_presence_prefix` from the account's `configs_callcenter`
////    document, then `system_config/callcenter`, then `*22`; an empty prefix
////    is `*22` too, never "no prefix".
//// 3. A user with neither publishes nothing, and says so once per update at
////    info. The user id is never a fallback.
////
//// The dialog call id is `presence_call_id` of the address, so every update
//// for one address is one dialog.
////
//// ## What
////
//// `state/2` is the whole mapping. Logged out and on break are `terminated`;
//// available and available on demand are `confirmed`; on a queue call,
//// whatever the availability, is `early`. Wrap-up is not a call. Phones pick
//// the colours.
////
//// ## Who publishes
////
//// `availability.set` publishes on every change, with `on_queue_call` false:
//// it does not know. The node dispatching the account does, and it publishes
//// `early` when an offer is answered or an answered call is adopted, and the
//// availability's state when the call ends. It also hears every
//// `agent_availability` of its account, and for an agent it has on a
//// connected call it publishes `early` again, so a change made mid-call does
//// not leave the lamp saying otherwise. Between the two publishes the lamp
//// shows the new availability's state for a moment; that flicker is
//// accepted. `Lamps` is what the dispatcher remembers so that it publishes
//// only on a change.
////
//// Kamailio keeps none of this for an address nobody is subscribed to. A
//// phone that subscribes later is answered by `callcenter/lamp_probe`,
//// which works the address out with `address_of` like everything here.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/account_config
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/users

import callcenter/records
import callcenter/system
import callcenter/types.{
  type Availability, Available, AvailableOnDemand, LoggedOut, OnBreak,
}

/// One presence update, worked out but not yet published.
pub type Presence {
  Presence(id: String, state: String, call_id: String)
}

/// Available, not on a queue call.
pub const confirmed = "confirmed"

/// On a queue call.
pub const early = "early"

/// Logged out, or on break.
pub const terminated = "terminated"

/// The account configuration key, in `configs_callcenter` and in
/// `system_config/callcenter`.
pub const prefix_key = "agent_presence_prefix"

/// The prefix when nothing configures one, and when what is configured is
/// empty.
pub const default_prefix = "*22"

/// Why an agent's lamp has no address.
pub type NoAddress {
  /// The account has no realm to address anything in.
  NoRealm
  /// The user has no `callcenter_agent` document: not an agent. A document
  /// that could not be read is taken the same way, and logged.
  NotAnAgent
  /// Neither a stored override nor a presence id on the user.
  NoPresenceId
}

// --- The state --------------------------------------------------------------

/// The dialog state the lamp shows.
pub fn state(
  availability: Availability,
  on_queue_call on_queue_call: Bool,
) -> String {
  case on_queue_call, availability {
    True, _ -> early
    False, Available | False, AvailableOnDemand -> confirmed
    False, OnBreak | False, LoggedOut -> terminated
  }
}

// --- The address ------------------------------------------------------------

/// The address, from what the documents say. `override` is the agent
/// document's `presence_id`, `presence_id` the user's own.
pub fn address_of(
  override override: Option(String),
  presence_id presence_id: Option(String),
  prefix prefix: String,
  realm realm: String,
) -> Result(String, NoAddress) {
  let presence_id = non_empty(presence_id)
  // The user's ordinary BLF address, which an override may not take over.
  let own = option.map(presence_id, fn(id) { id <> "@" <> realm })
  let override = case option.map(non_empty(override), qualify(_, realm)) {
    Some(address) ->
      case Some(address) == own {
        True -> None
        False -> Some(address)
      }
    None -> None
  }
  case realm, override, presence_id {
    "", _, _ -> Error(NoRealm)
    _, Some(address), _ -> Ok(address)
    _, None, Some(id) -> Ok(effective_prefix(prefix) <> id <> "@" <> realm)
    _, None, None -> Error(NoPresenceId)
  }
}

/// The prefix in force: what is configured, or `*22` when that is empty.
pub fn effective_prefix(configured: String) -> String {
  case string.trim(configured) {
    "" -> default_prefix
    prefix -> prefix
  }
}

/// The account's prefix, `kapps_account_config:get_global` style.
pub fn prefix(kz: Kazoo, account_id: String) -> String {
  account_config.get_string(
    kz,
    account_id,
    system.category,
    prefix_key,
    default_prefix,
  )
  |> effective_prefix
}

/// The agent's lamp address, read from the datastore.
pub fn address(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(String, NoAddress) {
  use realm <- result.try(realm(kz, account_id) |> option.to_result(NoRealm))
  use agent <- result.try(
    case
      kz.datamgr.open_cache_doc(
        kazoo.account_db(account_id),
        records.agent_document_id(agent_id),
      )
    {
      Ok(agent) -> Ok(agent)
      Error(kazoo.NotFound) -> Error(NotAnAgent)
      // No lamp rather than one on an address that may be wrong: the next
      // change publishes again.
      Error(error) -> {
        system.log_error(
          records.agent_document_id(agent_id)
          <> " of "
          <> account_id
          <> " could not be read ("
          <> kazoo.error_to_string(error)
          <> "): no login lamp published",
        )
        Error(NotAnAgent)
      }
    },
  )
  let presence_id = case users.fetch(kz, account_id, agent_id) {
    Ok(user) -> users.presence_id(user)
    Error(_) -> None
  }
  // Always the account's prefix: an override naming the agent's own address
  // is set aside inside `address_of`, which then needs the prefix in force,
  // not the default. It is account configuration, and cached.
  address_of(
    override: stored(agent),
    presence_id: presence_id,
    prefix: prefix(kz, account_id),
    realm: realm,
  )
}

/// The override an agent document holds.
pub fn stored(agent: Value) -> Option(String) {
  doc.get_string(agent, ["presence_id"]) |> option.from_result |> non_empty
}

fn qualify(id: String, realm: String) -> String {
  case string.contains(id, "@") {
    True -> id
    False -> id <> "@" <> realm
  }
}

fn non_empty(value: Option(String)) -> Option(String) {
  case value {
    Some("") -> None
    other -> other
  }
}

/// The account's realm, from the account document.
pub fn realm(kz: Kazoo, account_id: String) -> Option(String) {
  case kz.datamgr.open_cache_doc(kazoo.account_db(account_id), account_id) {
    Error(_) -> None
    Ok(account) ->
      case doc.get_string(account, ["realm"]) {
        Ok("") -> None
        Ok(realm) -> Some(realm)
        Error(_) -> None
      }
  }
}

// --- Publishing -------------------------------------------------------------

/// Show `state` on the agent's lamp. Answers the update that went out, or
/// why there was none; whether the broker took it is not asked.
pub fn publish(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  state: String,
) -> Result(Presence, NoAddress) {
  case address(kz, account_id, agent_id) {
    Error(NoPresenceId) -> {
      system.log(
        "agent "
        <> agent_id
        <> " of "
        <> account_id
        <> " has no presence_id: no login lamp published",
      )
      Error(NoPresenceId)
    }
    Error(reason) -> Error(reason)
    Ok(id) -> Ok(send(update(id, state)))
  }
}

/// The update for one address.
pub fn update(id: String, state: String) -> Presence {
  Presence(id, state, call_id(id))
}

/// Publish one update as it stands.
pub fn send(presence: Presence) -> Presence {
  let _ =
    amqp.publish(
      module: "presence",
      function: "update",
      payload: message(presence),
    )
  presence
}

/// A stable call id for the dialog, so that repeated updates for one address
/// are one dialog rather than a new one each time: the one
/// `kapps_call_command:presence/2` makes up from the presence id.
@external(erlang, "callcenter_ffi", "presence_call_id")
pub fn call_id(presence_id: String) -> String

/// The `kapi_presence:update` payload. Both ends of the dialog are the
/// address itself, which is what a state-only update looks like.
pub fn message(presence: Presence) -> Value {
  let #(user, realm) = split(presence.id)
  let uri = "sip:" <> presence.id
  doc.merge(
    amqp.default_headers(system.category, "presence", "update"),
    doc.object([
      #("Presence-ID", doc.String(presence.id)),
      #("From", doc.String(uri)),
      #("From-User", doc.String(user)),
      #("From-Realm", doc.String(realm)),
      #("To", doc.String(uri)),
      #("To-User", doc.String(user)),
      #("To-Realm", doc.String(realm)),
      #("State", doc.String(presence.state)),
      #("Call-ID", doc.String(presence.call_id)),
    ]),
  )
}

fn split(presence_id: String) -> #(String, String) {
  case string.split_once(presence_id, "@") {
    Ok(halves) -> halves
    Error(Nil) -> #(presence_id, "")
  }
}

// --- What the dispatcher remembers ------------------------------------------

/// Agent id to the state the dispatcher last showed on their lamp.
pub opaque type Lamps {
  Lamps(shown: Dict(String, String))
}

pub fn lamps() -> Lamps {
  Lamps(dict.new())
}

/// What the dispatcher last showed an agent, if it has shown anything since
/// it last heard somebody else change their availability.
pub fn shown(lamps: Lamps, agent_id: String) -> Option(String) {
  dict.get(lamps.shown, agent_id) |> option.from_result
}

/// Show `state` through `publish`, unless it is what was last shown.
pub fn show(
  lamps: Lamps,
  agent_id: String,
  state: String,
  publish: fn(String, String) -> Nil,
) -> Lamps {
  case dict.get(lamps.shown, agent_id) {
    Ok(already) if already == state -> lamps
    _ -> {
      publish(agent_id, state)
      Lamps(dict.insert(lamps.shown, agent_id, state))
    }
  }
}

/// An offer answered, or an answered call adopted.
pub fn connected(
  lamps: Lamps,
  agent_id: String,
  publish: fn(String, String) -> Nil,
) -> Lamps {
  show(lamps, agent_id, early, publish)
}

/// A queue call over: the availability the agent is in now decides.
pub fn ended(
  lamps: Lamps,
  agent_id: String,
  availability: Availability,
  publish: fn(String, String) -> Nil,
) -> Lamps {
  show(lamps, agent_id, state(availability, on_queue_call: False), publish)
}

/// An `agent_availability` heard. `availability.set` has just published the
/// new availability's state, so what was remembered no longer holds; an
/// agent on a queue call is put back to `early`.
pub fn heard(
  lamps: Lamps,
  agent_id: String,
  on_queue_call: Bool,
  publish: fn(String, String) -> Nil,
) -> Lamps {
  let forgotten = Lamps(dict.delete(lamps.shown, agent_id))
  case on_queue_call {
    True -> show(forgotten, agent_id, early, publish)
    False -> forgotten
  }
}
