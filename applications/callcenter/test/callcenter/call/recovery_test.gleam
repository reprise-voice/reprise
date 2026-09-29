//// Where a caller handed over stands, from the probe of their channel, the
//// switches' channels and their record: one case of `classify` at a time.

import callcenter/call/recovery.{
  Answered, Closed, Connected, Departed, Departing, Found, Gone, Moved, Parked,
  Ringing, Survey, Talked, Unanswered, Unknown, Waiting,
}
import callcenter/records
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc.{type Value}
import kazoo/events

const caller = "caller-leg"

const handoff = "handoff-1"

const now = 63_800_000_100

const joined = 63_800_000_000

const offer = "0a1b2c3d4e5f6a7b8c9d0e1f"

const older = "ffeeddccbbaa998877665544"

// --- The switches' rows ------------------------------------------------------

/// A row as a channel query lists it, in `ecallmgr_fs_channel:to_json/1`'s
/// snake case.
fn row(
  call_id: String,
  other_leg: Option(String),
  answered: Bool,
  vars: List(#(String, Value)),
) -> events.Channel {
  events.channel(
    doc.object_some([
      #("uuid", Some(doc.String(call_id))),
      #("other_leg", option.map(other_leg, doc.String)),
      #("answered", Some(doc.Bool(answered))),
      #("custom_channel_vars", Some(doc.object(vars))),
    ]),
  )
}

fn caller_row(other_leg: Option(String)) -> events.Channel {
  row(caller, other_leg, True, [#("Account-ID", doc.String("account-one"))])
}

/// Leg `n` of an offer, ringing `agent`, given up on at `deadline`. An
/// unbridged leg names itself as its other leg.
fn leg(
  of: String,
  n: String,
  agent: String,
  answered: Bool,
  deadline: Int,
) -> events.Channel {
  bridged_leg(of, n, agent, answered, deadline, Some(of <> "-" <> n))
}

fn bridged_leg(
  of: String,
  n: String,
  agent: String,
  answered: Bool,
  deadline: Int,
  other_leg: Option(String),
) -> events.Channel {
  row(of <> "-" <> n, other_leg, answered, [
    #("Account-ID", doc.String("account-one")),
    #("Queue-Call-ID", doc.String(caller)),
    #("Queue-Offer-ID", doc.String(of)),
    #("Queue-Offer-Deadline", doc.Int(deadline)),
    #("Queue-Pickup", doc.Bool(False)),
    #("Agent-ID", doc.String(agent)),
  ])
}

// --- The probe and the record -----------------------------------------------

/// The probe's completion, carrying the caller's channel variables.
fn probe(vars: List(#(String, String))) -> recovery.Probe {
  Answered(
    doc.object([
      #("Event-Name", doc.String("CHANNEL_EXECUTE_COMPLETE")),
      #("Call-ID", doc.String(caller)),
      #(
        "Custom-Channel-Vars",
        doc.object(list.map(vars, fn(var) { #(var.0, doc.String(var.1)) })),
      ),
    ]),
  )
}

fn quiet() -> recovery.Probe {
  probe([])
}

fn record(
  answered: Option(Int),
  ended: Option(Int),
  cancelled: Option(Int),
) -> Option(records.Passage) {
  Some(records.Passage(
    offer: None,
    answered: answered,
    agent_id: option.map(answered, fn(_) { "ann" }),
    agent_call_id: None,
    picked_up: False,
    ended: ended,
    cancelled: cancelled,
  ))
}

fn classify(
  probe: recovery.Probe,
  rows: List(events.Channel),
  complete: Bool,
  record: Option(records.Passage),
) -> #(recovery.Finding, List(String)) {
  recovery.classify(Found(
    call_id: caller,
    handoff_id: handoff,
    joined: joined,
    probe: probe,
    survey: Survey(
      channels: Some(events.Channels(channels: rows, complete: complete)),
      record: record,
    ),
    now: now,
  ))
}

fn ringing_leg() -> events.Channel {
  leg(offer, "1", "ann", False, now + 12)
}

// --- Gone, or not known ------------------------------------------------------

/// Only every switch answering without the channel, with the probe not
/// answered either, is a caller who has gone; their legs are hung up.
pub fn a_caller_on_no_switch_is_gone_test() {
  assert classify(Unanswered, [ringing_leg()], True, None)
    == #(Gone, [offer <> "-1"])
}

/// A switch that did not answer may be the one carrying the caller: nothing
/// is concluded, and nothing hung up on a guess.
pub fn a_caller_not_found_on_a_partial_answer_is_unknown_test() {
  assert classify(Unanswered, [ringing_leg()], False, None) == #(Unknown, [])
  assert recovery.classify(Found(
      call_id: caller,
      handoff_id: handoff,
      joined: joined,
      probe: Unanswered,
      survey: recovery.nothing(),
      now: now,
    ))
    == #(Unknown, [])
}

/// A channel the switches list is up, whether or not the probe was
/// answered: its control process may be what has gone.
pub fn a_listed_caller_is_up_without_the_probe_test() {
  assert classify(Unanswered, [caller_row(None)], True, None) == #(Waiting, [])
}

// --- Over for the queue ----------------------------------------------------------

/// A passage the record says is over is the queue's no more, whatever the
/// switch still has of it.
pub fn a_closed_record_is_closed_test() {
  let rows = [caller_row(None), ringing_leg()]
  assert classify(quiet(), rows, True, record(Some(now - 60), Some(now), None))
    == #(Closed, [offer <> "-1"])
  assert classify(quiet(), rows, True, record(None, None, Some(now)))
    == #(Closed, [offer <> "-1"])
}

/// The action's mark of this passage is the callflow having the caller
/// back; another passage's mark is not.
pub fn the_actions_mark_is_departed_test() {
  let marks = [
    #(recovery.departing_var, handoff),
    #(recovery.departing_branch_var, "exit_key"),
    #(recovery.departed_var, handoff),
  ]
  assert classify(probe(marks), [caller_row(None)], True, None)
    == #(Departed(Some("exit_key")), [])

  let earlier = [#(recovery.departed_var, "handoff-0")]
  assert classify(probe(earlier), [caller_row(None)], True, None)
    == #(Waiting, [])
}

/// Two channels naming each other that are not one of the queue's legs: the
/// caller is somebody else's.
pub fn a_caller_through_to_somebody_else_has_moved_test() {
  let rows = [
    caller_row(Some("somebody")),
    row("somebody", Some(caller), True, []),
    ringing_leg(),
  ]
  assert classify(quiet(), rows, True, None) == #(Moved, [offer <> "-1"])
}

/// The caller's own row keeps the other leg of a bridge that has ended: a
/// channel that is not there, or that names somebody else, is no bridge.
pub fn a_bridge_that_ended_is_no_bridge_test() {
  assert classify(quiet(), [caller_row(Some("gone-leg"))], True, None)
    == #(Waiting, [])
  let rows = [
    caller_row(Some("somebody")),
    row("somebody", Some("somebody-else"), True, []),
  ]
  assert classify(quiet(), rows, True, None) == #(Waiting, [])
}

// --- Through to an agent ------------------------------------------------------------

/// The caller through to one of the queue's legs is connected, answered at
/// the second the last actor marked for that agent, the rest of the legs
/// hung up.
pub fn a_caller_through_to_a_leg_is_connected_test() {
  let through = bridged_leg(offer, "2", "bob", True, now + 5, Some(caller))
  let rows = [caller_row(Some(offer <> "-2")), through, ringing_leg()]
  let marks = [
    #("Agent-ID", "bob"),
    #("Queue-Answered-Timestamp", "63800000090"),
  ]
  let assert #(Connected(found, at), stale) =
    classify(probe(marks), rows, True, None)
  assert found.call_id == offer <> "-2"
  assert found.agent_id == "bob"
  assert at == 63_800_000_090
  assert stale == [offer <> "-1"]

  // A mark of another agent is an earlier passage's: the record's answer,
  // and failing that, now.
  let other = [#("Agent-ID", "ann"), #("Queue-Answered-Timestamp", "1")]
  let assert #(Connected(_, at), _) =
    classify(probe(other), rows, True, record(Some(now - 7), None, None))
  assert at == now - 7
  let assert #(Connected(_, at), _) = classify(quiet(), rows, True, None)
  assert at == now
}

// --- Leaving ---------------------------------------------------------------------

/// The last actor's departure mark of this passage: the caller is handed
/// back, and a leg that answered meanwhile is hung up, not bridged.
pub fn a_departing_caller_is_handed_back_test() {
  let marks = [
    #(recovery.departing_var, handoff),
    #(recovery.departing_branch_var, "timeout"),
  ]
  let rows = [caller_row(None), leg(offer, "1", "ann", True, now + 5)]
  assert classify(probe(marks), rows, True, None)
    == #(Departing(Some("timeout")), [offer <> "-1"])
}

// --- Still in the queue -------------------------------------------------------------

/// An answer the record has, and the caller through to nobody: the call
/// ended while nothing watched it. An answered leg then is not bridged.
pub fn an_answer_through_to_nobody_has_talked_test() {
  let rows = [caller_row(None), leg(offer, "1", "ann", True, now + 5)]
  assert classify(quiet(), rows, True, record(Some(now - 30), None, None))
    == #(Talked("ann", now - 30, False), [offer <> "-1"])
}

/// A leg that answered and parks, the caller not through to it: bridged,
/// with the rest of its offer kept and any other offer's legs hung up.
pub fn an_answered_leg_is_parked_test() {
  let answered = leg(offer, "1", "ann", True, now + 5)
  let rows = [
    caller_row(None),
    answered,
    leg(offer, "2", "bob", False, now + 5),
    leg(older, "1", "cat", False, now + 1),
  ]
  let assert #(Parked(found, ring), stale) = classify(quiet(), rows, True, None)
  assert found.call_id == offer <> "-1"
  assert list.map(ring, fn(leg) { leg.call_id }) == [offer <> "-2"]
  assert stale == [older <> "-1"]
}

/// Phones ringing with time left: the newest offer's are taken on, and the
/// older offer's hung up. With too little left, all of them are hung up and
/// the caller is waiting.
pub fn a_ring_with_time_left_is_taken_on_test() {
  let rows = [
    caller_row(None),
    leg(offer, "1", "ann", False, now + recovery.least_ring_s),
    leg(offer, "2", "bob", False, now + recovery.least_ring_s),
    leg(older, "1", "cat", False, now + 1),
  ]
  let assert #(Ringing(ring), stale) = classify(quiet(), rows, True, None)
  assert list.map(ring, fn(leg) { leg.agent_id }) == ["ann", "bob"]
  assert stale == [older <> "-1"]

  let late = [
    caller_row(None),
    leg(offer, "1", "ann", False, now + recovery.least_ring_s - 1),
  ]
  assert classify(quiet(), late, True, None) == #(Waiting, [offer <> "-1"])
}

// --- Reading the rows -------------------------------------------------------------

/// A forwarded device's loopback carries the caller's `Queue-Call-ID` on its
/// far side, under a name of its own: not a leg the queue rang. A channel
/// every `ecallmgr` lists is one channel.
pub fn only_named_legs_count_once_test() {
  let far_side =
    row("loopback-b", Some("loopback-b"), False, [
      #("Queue-Call-ID", doc.String(caller)),
      #("Queue-Offer-ID", doc.String(offer)),
    ])
  let rows = [caller_row(None), ringing_leg(), ringing_leg(), far_side]
  let assert #(Ringing(ring), stale) = classify(quiet(), rows, True, None)
  assert list.map(ring, fn(leg) { leg.call_id }) == [offer <> "-1"]
  assert stale == []
  assert recovery.leg_ids(
      Survey(
        channels: Some(events.Channels(channels: rows, complete: True)),
        record: None,
      ),
      caller,
    )
    == [offer <> "-1"]
}

/// A supervisor's pickup says so on its legs.
pub fn a_pickups_legs_say_so_test() {
  let pickup =
    row(offer <> "-1", Some(offer <> "-1"), False, [
      #("Queue-Call-ID", doc.String(caller)),
      #("Queue-Offer-ID", doc.String(offer)),
      #("Queue-Offer-Deadline", doc.String("63800000150")),
      #("Queue-Pickup", doc.String("true")),
      #("Agent-ID", doc.String("sue")),
    ])
  let assert #(Ringing([found]), _) =
    classify(quiet(), [caller_row(None), pickup], True, None)
  assert found.pickup
  assert found.deadline == 63_800_000_150
}

/// A probe is the completion of the `noop` with its own `Msg-ID`.
pub fn a_probes_completion_test() {
  let done =
    doc.object([
      #("Event-Name", doc.String("CHANNEL_EXECUTE_COMPLETE")),
      #("Application-Name", doc.String("noop")),
      #("Application-Response", doc.String(recovery.probe_id(handoff, 1))),
    ])
  assert recovery.probe_of(done, recovery.probe_id(handoff, 1))
    == Some(Answered(done))
  assert recovery.probe_of(done, recovery.probe_id(handoff, 2)) == None
}

/// A leg rung for an earlier passage of the caller -- a queue they have
/// since left -- is only ever hung up.
pub fn an_earlier_passages_leg_is_hung_up_test() {
  let earlier =
    row(older <> "-1", Some(older <> "-1"), True, [
      #("Queue-Call-ID", doc.String(caller)),
      #("Queue-Offer-ID", doc.String(older)),
      #("Queue-Offer-Deadline", doc.Int(now + 10)),
      #("Queue-Joined-Timestamp", doc.Int(joined - 60)),
      #("Agent-ID", doc.String("cat")),
    ])
  let this =
    row(offer <> "-1", Some(offer <> "-1"), False, [
      #("Queue-Call-ID", doc.String(caller)),
      #("Queue-Offer-ID", doc.String(offer)),
      #("Queue-Offer-Deadline", doc.Int(now + 10)),
      #("Queue-Joined-Timestamp", doc.Int(joined)),
      #("Agent-ID", doc.String("ann")),
    ])
  let assert #(Ringing([found]), stale) =
    classify(quiet(), [caller_row(None), earlier, this], True, None)
  assert found.agent_id == "ann"
  assert stale == [older <> "-1"]
}
