//// The agents' legs for one offer: which endpoints ring, what each is
//// called before it rings, and how the caller is presented on them.
////
//// An offer rings every device of every agent it names, all at once, and
//// names every leg before it rings -- the offer's own prefix and the leg's
//// place in the ring -- so that whatever answers is known by its call id the
//// moment its first event arrives. Each endpoint carries the `Agent-ID` it
//// rings, which comes back on its leg's events and its CDR.
////
//// Building an endpoint reads the account's documents (`kazoo/endpoints`);
//// everything done to the endpoints after that is a function of values.

import callcenter/types.{type OfferId, type OfferSettings}
import gleam/dict.{type Dict}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/call.{type Call}
import kazoo/doc.{type Value}
import kazoo/endpoints
import kazoo/kazoo

/// What this application calls itself to `kz_endpoint` and to `kapps_call`.
///
/// Two rules read it and both say the same thing about a queue call: it is
/// not a direct call. A device whose call forward is `direct_calls_only`
/// therefore does not forward one, which is right -- the queue picked this
/// agent because they are here, and a caller who is queued should not be
/// sent to somebody's mobile because their desk phone is on forward.
pub const source = "callcenter"

/// The key `kapps_call` keeps the name of whatever is placing the call
/// under. `cf_exe` sets it to the callflow module; the offer sets it here
/// because the call it rings from was rebuilt out of a member message and
/// has been through no `cf_exe`.
pub const source_key = "context-source"

/// All the endpoints of all the agents, each marked with whose it is and
/// given the call id its leg will have (`named_legs`).
///
/// An agent whose devices cannot be built is left out rather than failing
/// the offer: with a simultaneous ring the others should still ring, and the
/// dispatcher hears about the miss either way.
///
/// Every device of every agent is an endpoint of its own, and they all ring
/// at once (`strategy`). `devices` names the phones to ring instead of every
/// device each agent owns: only a supervisor's pickup names them.
pub fn endpoints(
  call caller: Value,
  account_id account_id: String,
  agents agents: List(String),
  devices devices: Option(List(String)),
  settings settings: OfferSettings,
  prefix prefix: String,
) -> List(Value) {
  let ringing =
    prefixed(caller, settings.cid_prefix)
    |> call.from_value
    |> sourced
  let account_db = kazoo.account_db(account_id)
  list.flat_map(agents, fn(agent_id) {
    case devices {
      None ->
        endpoints.build_for_owned_devices(
          ringing,
          account_db,
          agent_id,
          properties(),
        )
      // A supervisor's pickup: the phones they named, built one device at a
      // time as an agent's are, and a device that will not build left out.
      Some(device_ids) ->
        list.flat_map(device_ids, fn(device_id) {
          case endpoints.build_with(ringing, device_id, properties()) {
            Ok(built) -> built
            Error(_reason) -> []
          }
        })
    }
    |> list.map(decorate(_, agent_id, settings))
  })
  |> named_legs(prefix)
}

/// Give every endpoint the call id its leg will have: the prefix and its
/// place in the ring.
///
/// `Outbound-Call-ID`, which `ecallmgr` passes to the switch as the leg's
/// `origination_uuid`. The prefix is the offer's own, fresh for every offer,
/// so no two legs anywhere share one and the offer can pick its legs' events
/// out of the account's before any of them names the caller.
pub fn named_legs(endpoints: List(Value), prefix: String) -> List(Value) {
  list.index_map(endpoints, fn(endpoint, index) {
    doc.set(
      endpoint,
      ["Outbound-Call-ID"],
      doc.String(prefix <> "-" <> int.to_string(index + 1)),
    )
  })
}

/// Which agent each named leg rings, read back off the endpoints.
pub fn legs_of(endpoints: List(Value)) -> Dict(String, String) {
  list.fold(endpoints, dict.new(), fn(legs, endpoint) {
    case
      doc.get_string(endpoint, ["Outbound-Call-ID"]),
      doc.get_string(endpoint, ["Custom-Channel-Vars", "Agent-ID"])
    {
      Ok(leg), Ok(agent_id) -> dict.insert(legs, leg, agent_id)
      _, _ -> legs
    }
  })
}

/// The part every call id this offer gives its legs starts with: a function
/// of the offer's own reference, so fresh for every offer, and one the
/// dispatcher can write on the caller's record for a takeover to read
/// (`records.offered`). A leg bridged to the caller whose id does not start
/// with it is not one of this offer's.
pub fn leg_prefix(id: OfferId) -> String {
  prefix_of(id.serial)
}

@external(erlang, "callcenter_ffi", "leg_prefix")
fn prefix_of(serial: Reference) -> String

/// The call as the thing placing it: a queue, not a person dialling.
///
/// `kapps_call` reads this key to decide the routing context, and every
/// name in `non_direct_modules` -- of which `callcenter` is one -- makes the
/// call a `non_direct_call`. A call rebuilt from a member message has been
/// through no `cf_exe`, so nothing has said it yet.
pub fn sourced(call: Call) -> Call {
  call.kvs_store(call, source_key, doc.String(source))
}

/// What `kz_endpoint:build/3` is told about the call it is building for.
///
/// Only `source`, and only so that a device forwarding on
/// `direct_calls_only` refuses a queue call the way it refuses a ring
/// group's. Everything else about the endpoint is the device's own.
pub fn properties() -> Value {
  doc.object([#("source", doc.String(source))])
}

/// Every endpoint rings at once, whether they are one agent's desk phone and
/// softphone or several agents' phones: the offer is one ring, bounded by one
/// timeout. A lone endpoint rings alone. `single` and `simultaneous` are the
/// switch's own words for it.
///
/// It is decided by the endpoints and not by the agents. `ecallmgr` turns
/// `single` into the `|` failover separator, so an agent with two devices
/// rung `single` had the first for the whole ring timeout and the second
/// never.
pub fn strategy(endpoints: List(Value)) -> call.Strategy {
  case endpoints {
    [_one] -> call.Single
    _many -> call.Simultaneous
  }
}

/// The call the agents' phones see: the queue's prefix in front of the
/// caller's name, so an agent knows which queue rang before they answer.
pub fn prefixed(call: Value, prefix: Option(String)) -> Value {
  case prefix {
    None -> call
    Some("") -> call
    Some(prefix) -> {
      let name = doc.get_string(call, ["Caller-ID-Name"]) |> unwrap_string
      doc.set(call, ["Caller-ID-Name"], doc.String(prefix <> name))
    }
  }
}

fn unwrap_string(read: Result(String, Nil)) -> String {
  case read {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

/// One endpoint, marked with the agent it rings and with the queue's own
/// outbound caller ID when it leaves the account.
///
/// The `Agent-ID` is what makes an answer attributable: it travels with the
/// agent's leg and comes back on that leg's events and on its CDR.
pub fn decorate(
  endpoint: Value,
  agent_id: String,
  settings: OfferSettings,
) -> Value {
  endpoint
  |> doc.set(["Custom-Channel-Vars", "Agent-ID"], doc.String(agent_id))
  |> outbound_caller_id(settings)
}

fn outbound_caller_id(endpoint: Value, settings: OfferSettings) -> Value {
  case is_external(endpoint) {
    False -> endpoint
    True ->
      endpoint
      |> set_some(["Outbound-Caller-ID-Name"], settings.outbound_caller_id_name)
      |> set_some(
        ["Outbound-Caller-ID-Number"],
        settings.outbound_caller_id_number,
      )
  }
}

fn set_some(value: Value, path: List(String), to: Option(String)) -> Value {
  case to {
    Some("") | None -> value
    Some(text) -> doc.set(value, path, doc.String(text))
  }
}

/// Whether an endpoint leaves the account.
///
/// `kz_endpoint` builds a device on this account with `Invite-Format`
/// `endpoint`; a call forward to a number outside it is a `loopback` or a
/// `route` carrying a `To-DID`. The queue's outbound caller ID is for the
/// second kind, where the contact is somebody else's.
pub fn is_external(endpoint: Value) -> Bool {
  doc.get_string(endpoint, ["Invite-Format"]) != Ok("endpoint")
}
