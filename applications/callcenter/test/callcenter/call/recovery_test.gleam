//// Where a caller handed over stands, from the probe of their channel, the
//// switches' channels and their record: one case of `classify` at a time.

import callcenter/call/recovery.{
  Answered, Closed, Connected, Departed, Departing, Found, Gone, Moved, Parked,
  RecordRead, RecordUnreadable, Ringing, Survey, Talked, Unanswered, Unknown,
  Waiting,
}
import callcenter/records
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc.{type Value}
import kazoo/events
import kazoo/kazoo

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
    cancel_reason: None,
  ))
}

/// A passage nothing has happened to yet.
fn open_passage() -> records.Passage {
  records.Passage(
    offer: None,
    answered: None,
    agent_id: None,
    agent_call_id: None,
    picked_up: False,
    ended: None,
    cancelled: None,
    cancel_reason: None,
  )
}

/// A finding's name, for the tables.
fn name(finding: recovery.Finding) -> String {
  case finding {
    Gone -> "gone"
    recovery.Finished(..) -> "finished"
    Closed -> "closed"
    Departed(_) -> "departed"
    Moved -> "moved"
    Connected(..) -> "connected"
    Departing(_) -> "departing"
    Talked(..) -> "talked"
    Parked(..) -> "parked"
    Ringing(_) -> "ringing"
    Waiting -> "waiting"
    Unknown -> "unknown"
  }
}

/// The finding, the record read as `record`.
fn classify(
  probe: recovery.Probe,
  rows: List(events.Channel),
  complete: Bool,
  record: Option(records.Passage),
) -> #(recovery.Finding, List(String)) {
  classify_with(probe, rows, complete, RecordRead(record))
}

fn classify_with(
  probe: recovery.Probe,
  rows: List(events.Channel),
  complete: Bool,
  record: recovery.Recorded,
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

/// A caller gone whose record has an answer nothing closed: the call ended
/// while nothing watched it, and is closed as a call.
pub fn a_caller_gone_after_an_answer_finished_test() {
  assert classify(Unanswered, [], True, record(Some(now - 30), None, None))
    == #(recovery.Finished("ann", now - 30, False), [])
  // Closed already: only gone.
  assert classify(Unanswered, [], True, record(Some(now - 30), Some(now), None))
    == #(Gone, [])
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

/// The probe reached the caller, but their own switch did not answer: the
/// legs start on the caller's switch, so the listing says nothing of their
/// ring or their conversation. A record with an offer out or an answer is
/// `Unknown`, since a ring nobody can see must not be rung again over
/// itself, nor a conversation nobody can see be closed. A record with
/// nothing going on is waiting, and what the record or the marks say alone
/// still stands. A node that has just started asks nobody (the lab of
/// 2026-09-28).
pub fn a_caller_whose_switch_did_not_answer_test() {
  let ringing =
    Some(records.Passage(
      offer: Some(records.Offered(
        agents: ["ann"],
        at: now - 5,
        leg_prefix: Some(offer),
        pickup: False,
      )),
      answered: None,
      agent_id: None,
      agent_call_id: None,
      picked_up: False,
      ended: None,
      cancelled: None,
      cancel_reason: None,
    ))
  let cases = [
    #(ringing, Unknown),
    #(record(Some(now - 30), None, None), Unknown),
    #(record(None, None, None), Waiting),
    #(None, Waiting),
    #(record(Some(now - 30), Some(now - 1), None), Closed),
  ]
  list.each(cases, fn(case_) {
    let #(record, finding) = case_
    assert classify(quiet(), [], False, record) == #(finding, [])
    // Nobody answering at all is the same.
    assert recovery.classify(Found(
        call_id: caller,
        handoff_id: handoff,
        joined: joined,
        probe: quiet(),
        survey: Survey(channels: None, record: RecordRead(record)),
        now: now,
      ))
      == #(finding, [])
  })
  // Every switch answered: nothing is ringing, whatever the record says.
  assert classify(quiet(), [], True, ringing) == #(Waiting, [])
  // The caller's own switch answered: its listing stands.
  let assert #(Ringing([leg]), []) =
    classify(quiet(), [caller_row(None), ringing_leg()], False, ringing)
  assert leg.agent_id == "ann"
}

/// A channel the switches list is up, whether or not the probe was
/// answered: its control process may be what has gone.
pub fn a_listed_caller_is_up_without_the_probe_test() {
  assert classify(Unanswered, [caller_row(None)], True, None) == #(Waiting, [])
}

// --- A record that could not be read ---------------------------------------------

/// What `records.read` answered, as the survey carries it: a passage with no
/// document is a record read and empty, and anything else the datastore
/// said is a record not read.
pub fn a_read_is_a_record_or_not_test() {
  let passage = records.Passage(..open_passage(), answered: Some(now - 30))
  let cases = [
    #(Ok(Some(passage)), RecordRead(Some(passage))),
    #(Ok(None), RecordRead(None)),
    #(Error(kazoo.Unavailable), RecordUnreadable("unavailable")),
    #(Error(kazoo.Invalid("timeout")), RecordUnreadable("timeout")),
    #(Error(kazoo.Invalid("econnrefused")), RecordUnreadable("econnrefused")),
  ]
  list.each(cases, fn(case_) {
    let #(read, record) = case_
    assert recovery.record(read) == record
  })
}

/// Wherever the record decides where the caller stands, a record that could
/// not be read is `Unknown`, and nothing is hung up on it: the actor asks
/// again. Taken for no record, as the last try takes it (`unread_as_none`),
/// it is what the probe and the switches alone say.
///
/// Each case is the probe, the rows, whether every switch answered, the
/// record as it would read, and what is found with it and with none.
pub fn an_unreadable_record_is_unknown_test() {
  let answered = record(Some(now - 30), None, None)
  let over = record(Some(now - 30), Some(now - 1), None)
  let cancelled = record(None, None, Some(now - 1))
  let ringing =
    Some(
      records.Passage(
        ..open_passage(),
        offer: Some(records.Offered(
          agents: ["ann"],
          at: now - 5,
          leg_prefix: Some(offer),
          pickup: False,
        )),
      ),
    )
  let departed = probe([#(recovery.departed_var, handoff)])
  let parked = leg(offer, "1", "ann", True, now + 5)
  let through = bridged_leg(offer, "2", "bob", True, now + 5, Some(caller))
  let cases = [
    // Gone: an answer nothing closed is a call that ended.
    #(Unanswered, [ringing_leg()], True, answered, "finished", "gone"),
    #(Unanswered, [ringing_leg()], True, over, "gone", "gone"),
    // Over for the queue, whatever the switch still has.
    #(
      quiet(),
      [caller_row(None), ringing_leg()],
      True,
      cancelled,
      "closed",
      "ringing",
    ),
    #(departed, [caller_row(None)], True, cancelled, "closed", "departed"),
    // Answered, and through to nobody: not bridged again, not offered.
    #(quiet(), [caller_row(None), parked], True, answered, "talked", "parked"),
    #(quiet(), [caller_row(None)], True, answered, "talked", "waiting"),
    // The caller's own switch did not answer: busy or not is the record's.
    #(quiet(), [], False, ringing, "unknown", "waiting"),
    #(quiet(), [], False, record(None, None, None), "waiting", "waiting"),
    // What the switch alone decides still waits on the record's word.
    #(
      quiet(),
      [caller_row(Some(offer <> "-2")), through],
      True,
      answered,
      "connected",
      "connected",
    ),
    #(quiet(), [caller_row(None)], True, None, "waiting", "waiting"),
  ]
  list.each(cases, fn(case_) {
    let #(probe, rows, complete, read, with_record, with_none) = case_
    assert name(classify(probe, rows, complete, read).0) == with_record
    assert classify_with(probe, rows, complete, RecordUnreadable("timeout"))
      == #(Unknown, [])
    let unread =
      Found(
        call_id: caller,
        handoff_id: handoff,
        joined: joined,
        probe: probe,
        survey: Survey(
          channels: Some(events.Channels(channels: rows, complete: complete)),
          record: RecordUnreadable("timeout"),
        ),
        now: now,
      )
    let taken =
      recovery.classify(
        Found(..unread, survey: recovery.unread_as_none(unread.survey)),
      )
    assert taken == classify(probe, rows, complete, None)
    assert name(taken.0) == with_none
  })
}

/// A record read stays as it was read when unread ones are taken for none.
pub fn a_read_record_is_not_taken_for_none_test() {
  let read =
    Survey(channels: None, record: RecordRead(record(Some(now), None, None)))
  assert recovery.unread_as_none(read) == read
}

/// A survey that did not come in in time read no record either: the probe
/// alone, answered with no marks, is not a caller waiting.
pub fn no_survey_is_no_record_read_test() {
  let assert RecordUnreadable(_) = recovery.nothing().record
  assert recovery.classify(Found(
      call_id: caller,
      handoff_id: handoff,
      joined: joined,
      probe: quiet(),
      survey: recovery.nothing(),
      now: now,
    ))
    == #(Unknown, [])
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

/// A passage the record says was cancelled as the caller left on a branch,
/// with the caller up, in no bridge and reached by the probe, is a
/// departure the last actor did not finish: the shard kept their member
/// until they were handed back, which is how this actor has it, and it
/// hands them back. The branch is the departure's mark when it ran and
/// names this passage -- the barrier may have gone before it -- and the
/// record's reason when not. It is not a departure when the callflow has
/// them back, when they are through to somebody, when the passage was over
/// for another reason, when the channel has joined a later passage since,
/// or when the probe did not reach them: some other flow may have them by
/// then, and a branch run over the top of it is worse than a settle.
pub fn a_caller_found_leaving_by_their_record_test() {
  let cancelled = fn(reason) {
    Some(
      records.Passage(
        ..open_passage(),
        cancelled: Some(now - 2),
        cancel_reason: reason,
      ),
    )
  }
  let listed = [caller_row(None)]
  let marks = fn(passage, branch) {
    probe([
      #(recovery.departing_var, passage),
      #(recovery.departing_branch_var, branch),
    ])
  }
  let through = [
    caller_row(Some("somebody")),
    row("somebody", Some(caller), True, []),
  ]
  let cases = [
    #("exit key", quiet(), listed, cancelled(Some("exit_key")), "exit_key"),
    #("timeout", quiet(), listed, cancelled(Some("timeout")), "timeout"),
    #(
      "no agent",
      quiet(),
      listed,
      cancelled(Some("no_agent_timeout")),
      "no_agent_timeout",
    ),
    #(
      "queue deleted",
      quiet(),
      listed,
      cancelled(Some("queue_deleted")),
      "no_agents",
    ),
    #(
      "quarantined",
      quiet(),
      listed,
      cancelled(Some("quarantined")),
      "no_agents",
    ),
    #(
      "this passage's marks",
      marks(handoff, "exit_key"),
      listed,
      cancelled(Some("timeout")),
      "exit_key",
    ),
    #(
      "an earlier passage's marks",
      marks("handoff-0", "exit_key"),
      listed,
      cancelled(Some("timeout")),
      "timeout",
    ),
    #(
      "handed back",
      probe([#(recovery.departed_var, handoff)]),
      listed,
      cancelled(Some("exit_key")),
      "closed",
    ),
    #("a hang-up", quiet(), listed, cancelled(Some("hangup")), "closed"),
    #("a transfer", quiet(), listed, cancelled(Some("transfer")), "closed"),
    #("no reason", quiet(), listed, cancelled(None), "closed"),
    #(
      "an answered call ended",
      quiet(),
      listed,
      record(Some(now - 60), Some(now), None),
      "closed",
    ),
    #("through", quiet(), through, cancelled(Some("exit_key")), "closed"),
    #(
      "this passage's join",
      probe([#(recovery.joined_var, "63800000000")]),
      listed,
      cancelled(Some("exit_key")),
      "exit_key",
    ),
    #(
      "a later passage's join",
      probe([#(recovery.joined_var, "63800000030")]),
      listed,
      cancelled(Some("exit_key")),
      "closed",
    ),
    #(
      "this passage's marks, and a later join: the same queue entered again",
      probe([
        #(recovery.departing_var, handoff),
        #(recovery.departing_branch_var, "exit_key"),
        #(recovery.joined_var, "63800000030"),
      ]),
      listed,
      cancelled(Some("exit_key")),
      "exit_key",
    ),
    #("unreached", Unanswered, listed, cancelled(Some("exit_key")), "closed"),
  ]
  list.each(cases, fn(case_) {
    let #(label, probe, rows, record, expected) = case_
    let found = case classify(probe, rows, True, record) {
      #(Departing(Some(branch)), []) -> branch
      #(Closed, []) -> "closed"
      other -> "unexpected " <> name(other.0)
    }
    assert found == expected as label
  })
}

// --- Still in the queue -------------------------------------------------------------

/// An answer the record has, and the caller through to nobody: the call
/// ended while nothing watched it. An answered leg then is not bridged.
///
/// Whether the caller is parked is the probe. One it reached is on the
/// control process that took them into the queue, in no bridge: parked
/// where the agent's end left them, whatever marks their channel carries
/// and whatever their row says of a bridge that has ended. One it did not
/// reach -- a transfer's callflow has the channel, and the process the
/// probe went to has stopped -- is not parked, listed on a partial answer
/// or a whole one.
pub fn an_answer_through_to_nobody_has_talked_test() {
  let answered_leg = leg(offer, "1", "ann", True, now + 5)
  let marks =
    probe([
      #("Agent-ID", "ann"),
      #("Queue-Answered-Timestamp", "63800000070"),
    ])
  let picked_up =
    Some(records.Passage(
      offer: None,
      answered: Some(now - 30),
      agent_id: Some("sue"),
      agent_call_id: None,
      picked_up: True,
      ended: None,
      cancelled: None,
      cancel_reason: None,
    ))
  let answered = record(Some(now - 30), None, None)
  let cases = [
    // probe, caller's row, the rest, whole listing, record: finding, stale
    #(
      quiet(),
      caller_row(None),
      [answered_leg],
      True,
      answered,
      Talked("ann", now - 30, False, parked: True),
      [offer <> "-1"],
    ),
    #(
      marks,
      caller_row(None),
      [],
      True,
      answered,
      Talked("ann", now - 30, False, parked: True),
      [],
    ),
    #(
      quiet(),
      caller_row(Some(offer <> "-1")),
      [],
      True,
      answered,
      Talked("ann", now - 30, False, parked: True),
      [],
    ),
    #(
      quiet(),
      caller_row(None),
      [],
      False,
      answered,
      Talked("ann", now - 30, False, parked: True),
      [],
    ),
    #(
      quiet(),
      caller_row(None),
      [],
      True,
      picked_up,
      Talked("sue", now - 30, True, parked: True),
      [],
    ),
    #(
      Unanswered,
      caller_row(None),
      [answered_leg],
      True,
      answered,
      Talked("ann", now - 30, False, parked: False),
      [offer <> "-1"],
    ),
    #(
      Unanswered,
      caller_row(Some(offer <> "-1")),
      [],
      True,
      answered,
      Talked("ann", now - 30, False, parked: False),
      [],
    ),
    #(
      Unanswered,
      caller_row(None),
      [],
      False,
      answered,
      Talked("ann", now - 30, False, parked: False),
      [],
    ),
    #(
      Unanswered,
      caller_row(None),
      [],
      True,
      picked_up,
      Talked("sue", now - 30, True, parked: False),
      [],
    ),
  ]
  list.each(cases, fn(case_) {
    let #(probe, caller, others, complete, record, finding, stale) = case_
    assert classify(probe, [caller, ..others], complete, record)
      == #(finding, stale)
  })
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
  let assert #(Parked(found, at, ring), stale) =
    classify(quiet(), rows, True, None)
  assert found.call_id == offer <> "-1"
  assert at == now
  assert list.map(ring, fn(leg) { leg.call_id }) == [offer <> "-2"]
  assert stale == [older <> "-1"]
}

/// A parked leg is dated as a connected one is: by the last actor's marks,
/// which went on the caller's channel as the leg answered, when they name
/// its agent, and by now when they name nobody or somebody else.
pub fn a_parked_leg_is_dated_by_its_marks_test() {
  let rows = [caller_row(None), leg(offer, "1", "ann", True, now + 5)]
  let cases = [
    #("marked by its agent", [#("Agent-ID", "ann")], now - 4),
    #("marked by another agent", [#("Agent-ID", "bob")], now),
    #("not marked", [], now),
  ]
  list.each(cases, fn(case_) {
    let #(name, agent, dated) = case_
    let marks =
      list.append(agent, [#("Queue-Answered-Timestamp", "63800000096")])
    let assert #(Parked(_, at, _), _) = classify(probe(marks), rows, True, None)
      as name
    assert at == dated as name
  })
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
        record: RecordRead(None),
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
