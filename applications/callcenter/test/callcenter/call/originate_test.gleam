//// The endpoints an offer rings: named before they ring, marked with the
//// agent, and presenting the caller as the queue wants.

import callcenter/call/originate
import callcenter/types
import gleam/dict
import gleam/erlang/reference
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/call
import kazoo/doc
import support/rng

const caller_leg = "9f8e7d6c-5b4a-3210"

fn settings(
  prefix: option.Option(String),
  name: option.Option(String),
  number: option.Option(String),
) -> types.OfferSettings {
  types.OfferSettings(
    ring_timeout_s: 15,
    cid_prefix: prefix,
    record: False,
    outbound_caller_id_name: name,
    outbound_caller_id_number: number,
    hold_media: None,
  )
}

pub fn the_prefix_goes_in_front_of_the_name_test() {
  let call =
    doc.object([
      #("Call-ID", doc.String(caller_leg)),
      #("Caller-ID-Name", doc.String("Ada Lovelace")),
    ])
  assert doc.get_string(originate.prefixed(call, Some("Support: ")), [
      "Caller-ID-Name",
    ])
    == Ok("Support: Ada Lovelace")
  assert originate.prefixed(call, None) == call
  assert originate.prefixed(call, Some("")) == call
}

/// A caller with no name at all still shows the queue they came from.
pub fn a_prefix_with_no_name_test() {
  let call = doc.object([#("Call-ID", doc.String(caller_leg))])
  assert doc.get_string(originate.prefixed(call, Some("Support")), [
      "Caller-ID-Name",
    ])
    == Ok("Support")
}

fn device_endpoint() -> doc.Value {
  doc.object([
    #("Invite-Format", doc.String("endpoint")),
    #("Endpoint-ID", doc.String("device-one")),
    #("Outbound-Caller-ID-Name", doc.String("Support: Ada Lovelace")),
  ])
}

fn forwarded_endpoint() -> doc.Value {
  doc.object([
    #("Invite-Format", doc.String("loopback")),
    #("Route", doc.String("+15555550123")),
    #("To-DID", doc.String("+15555550123")),
    #("Outbound-Caller-ID-Name", doc.String("Support: Ada Lovelace")),
  ])
}

pub fn a_device_is_not_external_test() {
  assert originate.is_external(device_endpoint()) == False
  assert originate.is_external(forwarded_endpoint()) == True
}

/// Every endpoint carries the agent it rings, so the answer can be pinned on
/// somebody whichever of them takes it.
pub fn every_endpoint_carries_its_agent_test() {
  let decorated =
    originate.decorate(device_endpoint(), "agent-a", settings(None, None, None))
  assert doc.get_string(decorated, ["Custom-Channel-Vars", "Agent-ID"])
    == Ok("agent-a")
}

/// The queue's outbound caller ID is for the legs that leave the account;
/// an agent's own desk phone keeps the caller's identity.
pub fn the_outbound_caller_id_is_for_external_legs_test() {
  let of = settings(None, Some("Vonix Support"), Some("+15555550100"))

  let device = originate.decorate(device_endpoint(), "agent-a", of)
  assert doc.get_string(device, ["Outbound-Caller-ID-Name"])
    == Ok("Support: Ada Lovelace")

  let forwarded = originate.decorate(forwarded_endpoint(), "agent-a", of)
  assert doc.get_string(forwarded, ["Outbound-Caller-ID-Name"])
    == Ok("Vonix Support")
  assert doc.get_string(forwarded, ["Outbound-Caller-ID-Number"])
    == Ok("+15555550100")
}

/// A queue with no outbound caller ID leaves the endpoint's own alone.
pub fn no_outbound_caller_id_changes_nothing_test() {
  let forwarded =
    originate.decorate(
      forwarded_endpoint(),
      "agent-a",
      settings(None, None, None),
    )
  assert doc.get_string(forwarded, ["Outbound-Caller-ID-Name"])
    == Ok("Support: Ada Lovelace")
}

/// One endpoint rings alone; more than one ring together, and that includes
/// one agent's desk phone and softphone. Rung `single`, the second device
/// would only ever have been tried after the first had rung out.
pub fn every_endpoint_rings_at_once_test() {
  let desk =
    originate.decorate(device_endpoint(), "agent-a", settings(None, None, None))
  let softphone =
    originate.decorate(
      forwarded_endpoint(),
      "agent-a",
      settings(None, None, None),
    )
  let other =
    originate.decorate(device_endpoint(), "agent-b", settings(None, None, None))
  assert originate.strategy([desk]) == call.Single
  assert originate.strategy([desk, softphone]) == call.Simultaneous
  assert originate.strategy([desk, other]) == call.Simultaneous
}

/// The two halves of "this is a queue call, not somebody dialling": what
/// `kz_endpoint` is told when it builds the endpoint, and what `kapps_call`
/// is told about the call the bridge goes out on. Both have to say
/// `callcenter`, because both are read against the same list of modules
/// whose calls are not direct -- and that is what makes a device forwarding
/// on `direct_calls_only` refuse a caller who is in a queue.
pub fn the_offer_says_which_application_is_ringing_test() {
  assert doc.get_string(originate.properties(), ["source"]) == Ok("callcenter")
  let sourced =
    call.from_value(doc.object([#("Call-ID", doc.String(caller_leg))]))
    |> originate.sourced
  assert call.kvs_fetch(sourced, "context-source")
    == Some(doc.String("callcenter"))
}

/// Every endpoint is given its leg's call id, the offer's prefix and its
/// place in the ring, and the offer can read back whose each one is.
pub fn every_leg_is_named_before_it_rings_test() {
  let desk =
    originate.decorate(device_endpoint(), "agent-a", settings(None, None, None))
  let mobile =
    originate.decorate(
      forwarded_endpoint(),
      "agent-a",
      settings(None, None, None),
    )
  let other =
    originate.decorate(device_endpoint(), "agent-b", settings(None, None, None))
  let named = originate.named_legs([desk, mobile, other], "c0ffee")
  assert list.map(named, doc.get_string(_, ["Outbound-Call-ID"]))
    == [Ok("c0ffee-1"), Ok("c0ffee-2"), Ok("c0ffee-3")]
  assert originate.legs_of(named)
    == dict.from_list([
      #("c0ffee-1", "agent-a"),
      #("c0ffee-2", "agent-a"),
      #("c0ffee-3", "agent-b"),
    ])
}

/// The prefix is the offer's own and nobody else's, and the same whoever
/// works it out: the offer ringing, or the dispatcher writing the record a
/// takeover reads.
pub fn the_leg_prefix_is_the_offers_test() {
  let id = types.OfferId(call_id: caller_leg, serial: reference.new())
  let other = types.OfferId(call_id: caller_leg, serial: reference.new())
  assert originate.leg_prefix(id) == originate.leg_prefix(id)
  assert originate.leg_prefix(id) != originate.leg_prefix(other)
  assert string.length(originate.leg_prefix(id)) == 24
}

// --- Every device of every agent, at once ------------------------------------

/// How many random offers the property below is checked against.
const offers = 300

/// Every endpoint an offer builds rings at the same time as the others: one
/// agent's desk phone and softphone, and every agent a strategy rings
/// together. A lone endpoint rings alone, which is the same thing. `single`
/// with more than one endpoint is the `|` failover, which rang an agent's
/// first device for the whole ring and their second never, and is never
/// what an offer asks for.
///
/// And every leg is named before it rings, uniquely, under the offer's
/// prefix, and the names say whose each leg is: that is how an answer is
/// pinned on the agent whose phone took it.
pub fn every_device_of_every_agent_rings_at_once_test() {
  rng.upto(offers)
  |> list.each(fn(seed) {
    let #(built, _rng) = an_offer(rng.seeded(seed))
    let prefix = "offer-" <> string.inspect(seed)
    let named = originate.named_legs(built, prefix)
    let endpoints = list.length(named)
    case endpoints {
      1 -> {
        assert originate.strategy(named) == call.Single
      }
      _ -> {
        assert originate.strategy(named) == call.Simultaneous
      }
    }
    let legs =
      list.filter_map(named, fn(endpoint) {
        doc.get_string(endpoint, ["Outbound-Call-ID"])
      })
    assert list.length(legs) == endpoints
    assert list.length(list.unique(legs)) == endpoints
    assert list.all(legs, string.starts_with(_, prefix <> "-"))
    let whose = originate.legs_of(named)
    assert dict.size(whose) == endpoints
    list.each(named, fn(endpoint) {
      let assert Ok(leg) = doc.get_string(endpoint, ["Outbound-Call-ID"])
      let assert Ok(agent) =
        doc.get_string(endpoint, ["Custom-Channel-Vars", "Agent-ID"])
      assert dict.get(whose, leg) == Ok(agent)
    })
  })
}

/// One to four agents, each with one to three devices -- a desk phone, or a
/// forward that leaves the account -- decorated as an offer decorates them.
fn an_offer(rng: rng.Rng) -> #(List(doc.Value), rng.Rng) {
  let #(agents, rng) = rng.below(rng, 4)
  rng.many(rng, agents + 1, fn(rng, index) {
    let #(devices, rng) = rng.below(rng, 3)
    rng.many(rng, devices + 1, fn(rng, _device) {
      let #(forwarded, rng) = rng.chance(rng, 30)
      let endpoint = case forwarded {
        True -> forwarded_endpoint()
        False -> device_endpoint()
      }
      #(
        originate.decorate(
          endpoint,
          "agent-" <> string.inspect(index),
          settings(None, Some("Support"), Some("+15555550100")),
        ),
        rng,
      )
    })
  })
  |> fn(made) { #(list.flatten(made.0), made.1) }
}

// --- The originate -------------------------------------------------------------

fn ring(
  switch: option.Option(String),
  name: option.Option(String),
) -> originate.Ring {
  originate.Ring(
    account_id: "acct",
    queue_id: "support",
    call_id: caller_leg,
    switch: switch,
    joined: 63_800_000_000,
    prefix: "0123456789abcdef01234567",
    ring_timeout_s: 15,
    deadline: 63_800_000_020,
    owner: "kazoo_apps@one",
    pickup: False,
    caller_id_name: name,
    caller_id_number: Some("5551234"),
    cid_prefix: Some("Support: "),
    server_id: Some("pid://<0.1.0>/call_replies"),
  )
}

/// One originate for the offer: its legs on the caller's switch, parked on
/// answer with no control process, every device at once, the caller as the
/// queue presents them, the prefix naming the request, and the answer sent
/// to the actor.
pub fn the_originate_rings_every_leg_beside_the_caller_test() {
  let endpoints = [
    doc.object([#("Outbound-Call-ID", doc.String("p-1"))]),
    doc.object([#("Outbound-Call-ID", doc.String("p-2"))]),
  ]
  let request =
    originate.request(ring(Some("freeswitch@fs1"), Some("Ada")), endpoints)
  assert doc.get_string(request, ["Application-Name"]) == Ok("park")
  assert doc.get_string(request, ["Existing-Call-ID"]) == Ok(caller_leg)
  assert doc.get_string(request, ["Switch-Nodename"]) == Ok("freeswitch@fs1")
  assert doc.get_bool(request, ["Start-Control-Process"]) == Ok(False)
  assert doc.get_bool(request, ["Ignore-Early-Media"]) == Ok(True)
  assert doc.get_string(request, ["Dial-Endpoint-Method"]) == Ok("simultaneous")
  assert doc.get_int(request, ["Timeout"]) == Ok(15)
  assert doc.get_string(request, ["Caller-ID-Name"]) == Ok("Support: Ada")
  assert doc.get_string(request, ["Caller-ID-Number"]) == Ok("5551234")
  assert doc.get_string(request, ["Msg-ID"]) == Ok("0123456789abcdef01234567")
  assert doc.get_string(request, ["Server-ID"])
    == Ok("pid://<0.1.0>/call_replies")
  assert doc.get_list(request, ["Endpoints"]) == Ok(endpoints)

  // A lone endpoint rings alone, and a switch nobody knows is not said.
  let lone =
    originate.request(ring(None, None), [
      doc.object([#("Outbound-Call-ID", doc.String("p-1"))]),
    ])
  assert doc.get_string(lone, ["Dial-Endpoint-Method"]) == Ok("single")
  assert doc.get(lone, ["Switch-Nodename"]) == Error(Nil)
  assert doc.get_string(lone, ["Caller-ID-Name"]) == Ok("Support: ")
}

/// Every leg is born with the queue's variables, which come back on its
/// events and in the channel table, and exported so the switch keeps them;
/// and with a `park_timeout`, written raw, so an answered leg nobody bridges
/// hangs itself up.
pub fn every_leg_carries_the_queue_and_a_park_timeout_test() {
  let request = originate.request(ring(Some("freeswitch@fs1"), None), [])
  assert doc.get_string(request, ["Custom-Channel-Vars", "Queue-Call-ID"])
    == Ok(caller_leg)
  assert doc.get_string(request, ["Custom-Channel-Vars", "Queue-Offer-ID"])
    == Ok("0123456789abcdef01234567")
  assert doc.get_bool(request, ["Custom-Channel-Vars", "Queue-Pickup"])
    == Ok(False)
  assert doc.get_string(request, [
      "Custom-Channel-Vars", "Media-Control", "park_timeout",
    ])
    == Ok("10")
  let exported = doc.strings(request, ["Export-Custom-Channel-Vars"])
  assert list.contains(exported, "Queue-Call-ID")
  assert list.contains(exported, "Queue-Offer-ID")
  assert !list.contains(exported, "Media-Control")
}
