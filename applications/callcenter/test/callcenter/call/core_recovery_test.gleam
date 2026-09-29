//// A caller handed to an actor that does not know where they stand: the
//// probe and the survey, what is heard meanwhile, and the call as it is
//// found. `recovery_test` has every way of reading what is found; these are
//// what the call does about each.

import callcenter/call/core.{type Input}
import callcenter/call/recovery
import callcenter/records
import callcenter/types
import gleam/erlang/reference
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc.{type Value}
import kazoo/events
import support/call_script.{
  at, at_ms, bridged_to, call_id, event, fresh, gone, handoff, key, last,
  noop_done, offer, phase_name, ring, script, settings, t0, waiting,
}

const prefix = "0a1b2c3d4e5f6a7b8c9d0e1f"

fn found_as() -> types.OfferId {
  types.OfferId(call_id: call_id, serial: reference.new())
}

fn joining(id: String) -> core.Joining {
  core.Joining(
    queue_id: call_script.queue_id,
    joined: t0,
    handoff: handoff(id),
    settings: settings(),
  )
}

fn rejoin(id: String, as_offer: types.OfferId) -> Input {
  core.Rejoined(joining(id), as_offer)
}

fn probe_done(attempt: Int, vars: List(#(String, String))) -> Input {
  event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
    #("Application-Name", doc.String("noop")),
    #("Application-Response", doc.String(recovery.probe_id("h1", attempt))),
    #(
      "Custom-Channel-Vars",
      doc.object(list.map(vars, fn(var) { #(var.0, doc.String(var.1)) })),
    ),
  ])
}

fn row(
  call: String,
  other_leg: Option(String),
  answered: Bool,
  vars: List(#(String, Value)),
) -> events.Channel {
  events.channel(
    doc.object_some([
      #("uuid", Some(doc.String(call))),
      #("other_leg", option.map(other_leg, doc.String)),
      #("answered", Some(doc.Bool(answered))),
      #("custom_channel_vars", Some(doc.object(vars))),
    ]),
  )
}

fn caller_row(other_leg: Option(String)) -> events.Channel {
  row(call_id, other_leg, True, [])
}

fn leg_row(
  n: String,
  agent: String,
  answered: Bool,
  other_leg: Option(String),
) -> events.Channel {
  row(prefix <> "-" <> n, other_leg, answered, [
    #("Queue-Call-ID", doc.String(call_id)),
    #("Queue-Offer-ID", doc.String(prefix)),
    // Twelve seconds of ring left at `at(1)`.
    #("Queue-Offer-Deadline", doc.Int(t0 + 13)),
    #("Agent-ID", doc.String(agent)),
  ])
}

fn leg(n: String) -> String {
  prefix <> "-" <> n
}

fn surveyed(
  rows: List(events.Channel),
  record: Option(records.Passage),
) -> Input {
  core.Surveyed(recovery.Survey(
    channels: Some(events.Channels(channels: rows, complete: True)),
    record: record,
  ))
}

fn answered_record(at: Int) -> Option(records.Passage) {
  Some(records.Passage(
    offer: None,
    answered: Some(at),
    agent_id: Some("ann"),
    agent_call_id: None,
    picked_up: False,
    ended: None,
    cancelled: None,
  ))
}

/// Recover a new actor's caller: the rejoin at 0, the survey at 1, the
/// probe's answer at 1.
fn recovered(
  rows: List(events.Channel),
  record: Option(records.Passage),
  vars: List(#(String, String)),
) -> #(core.Call, List(List(core.Effect)), types.OfferId) {
  let id = found_as()
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", id), at(0)),
      #(surveyed(rows, record), at(1)),
      #(probe_done(1, vars), at(1)),
    ])
  #(call, done, id)
}

// --- Finding out ---------------------------------------------------------------

/// A caller handed to an actor that has just started is found out about
/// before anything is sent them: the probe, run at once, and the survey.
pub fn a_rejoin_to_a_new_actor_finds_out_test() {
  let #(call, done) = script(fresh(), [#(rejoin("h1", found_as()), at(0))])
  assert done == [[core.Probe(recovery.probe_id("h1", 1)), core.Survey]]
  assert phase_name(call) == "recovering"
}

/// Waiting, with nothing going on: held again, and the dispatcher told.
pub fn a_caller_found_waiting_test() {
  let #(call, done, _id) = recovered([caller_row(None)], None, [])
  assert last(done)
    == [
      core.Hold(Some("support-hold")),
      core.Present(None, types.PresentWaiting),
    ]
  assert phase_name(call) == "waiting"
}

/// What arrives while the call is found out about is heard once it is, in
/// order: an exit key pressed meanwhile takes the caller out.
pub fn what_arrives_meanwhile_is_heard_after_test() {
  let id = found_as()
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", id), at(0)),
      #(key("#"), at(0)),
      #(surveyed([caller_row(None)], None), at(1)),
      #(probe_done(1, []), at(1)),
    ])
  assert list.take(done, 3)
    == [[core.Probe(recovery.probe_id("h1", 1)), core.Survey], [], []]
  let found = last(done)
  assert list.take(found, 2)
    == [
      core.Hold(Some("support-hold")),
      core.Present(None, types.PresentWaiting),
    ]
  assert list.contains(found, core.Left(types.ExitKey))
  assert phase_name(call) == "leaving"
}

/// Nobody should ask for a ring before the dispatcher is told where the
/// caller stands; one that is asked for is refused at once.
pub fn a_ring_while_finding_out_is_refused_test() {
  let #(id, endpoints) = offer(["ann"])
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", found_as()), at(0)),
      #(ring(id, ["ann"], endpoints, False), at(0)),
    ])
  assert last(done) == [core.Tell(id, types.Failed(core.not_waiting))]
  assert phase_name(call) == "recovering"
}

/// A probe nobody answers is given `probe_ms` once the survey is in; a
/// channel the switches list is up all the same.
pub fn an_unanswered_probe_times_out_test() {
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", found_as()), at(0)),
      #(surveyed([caller_row(None)], None), at(1)),
      #(core.Tick, at_ms(1000 + core.probe_ms - 1)),
      #(core.Tick, at_ms(1000 + core.probe_ms)),
    ])
  assert nth(done, 2) == Ok([])
  assert last(done)
    == [
      core.Hold(Some("support-hold")),
      core.Present(None, types.PresentWaiting),
    ]
  assert phase_name(call) == "waiting"
}

/// Nothing found out -- no survey, no probe -- is asked again, and after
/// `recover_attempts` the caller is taken to be waiting.
pub fn nothing_found_out_is_asked_again_test() {
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", found_as()), at(0)),
      #(core.Tick, at_ms(core.recover_ms)),
      #(core.Tick, at_ms(2 * core.recover_ms)),
      #(core.Tick, at_ms(3 * core.recover_ms)),
    ])
  assert nth(done, 1)
    == Ok([core.Probe(recovery.probe_id("h1", 2)), core.Survey])
  assert nth(done, 2)
    == Ok([core.Probe(recovery.probe_id("h1", 3)), core.Survey])
  let assert [
    core.Log(_),
    core.Hold(_),
    core.Present(None, types.PresentWaiting),
  ] = last(done)
  assert phase_name(call) == "waiting"
}

// --- The call as it is found --------------------------------------------------

/// Gone: settled as a hang-up, its legs hung up.
pub fn a_caller_found_gone_test() {
  let id = found_as()
  let rows = [leg_row("1", "ann", False, Some(leg("1")))]
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", id), at(0)),
      #(surveyed(rows, None), at(1)),
      #(core.Tick, at_ms(1000 + core.probe_ms)),
    ])
  assert last(done) == [core.HangUpLegs([leg("1")]), core.Left(types.Hangup)]
  assert core.finished(call)
}

/// A ring with time left is taken on: the dispatcher holds its agents under
/// the offer it is told, and the ring goes on to be answered and bridged
/// like any other.
pub fn a_ring_found_is_taken_on_test() {
  let rows = [caller_row(None), leg_row("1", "ann", False, Some(leg("1")))]
  let #(call, done, id) = recovered(rows, None, [])
  assert last(done)
    == [
      core.Hold(Some("support-hold")),
      core.Present(Some(id), types.PresentRinging(["ann"], t0 + 13, False)),
    ]
  assert phase_name(call) == "ringing"

  let #(call, done) =
    script(call, [
      #(event(leg("1"), "CHANNEL_ANSWER", []), at(4)),
      #(bridged_to(leg("1")), at(4)),
    ])
  assert list.first(done) == Ok([core.Bridge(leg("1"))])
  assert list.contains(
    last(done),
    core.Tell(id, types.Answered("ann", leg("1"), t0 + 4)),
  )
  assert phase_name(call) == "connected"
}

/// A leg found answered and parked is bridged at once.
pub fn a_parked_leg_found_is_bridged_test() {
  let rows = [caller_row(None), leg_row("1", "ann", True, Some(leg("1")))]
  let #(call, done, id) = recovered(rows, None, [])
  assert last(done)
    == [
      core.Present(Some(id), types.PresentRinging(["ann"], t0 + 13, False)),
      core.Bridge(leg("1")),
    ]
  assert phase_name(call) == "connecting"
}

/// A call found connected is watched to its end, marked again, and the
/// dispatcher told who is talking.
pub fn a_call_found_connected_test() {
  let rows = [
    caller_row(Some(leg("1"))),
    leg_row("1", "ann", True, Some(call_id)),
  ]
  let #(call, done, id) = recovered(rows, answered_record(t0 - 30), [])
  assert last(done)
    == [
      core.Mark([
        #("Agent-ID", doc.String("ann")),
        #("Queue-Answered-Timestamp", doc.Int(t0 - 30)),
      ]),
      core.Present(
        Some(id),
        types.PresentConnected("ann", leg("1"), t0 - 30, False),
      ),
    ]
  assert phase_name(call) == "connected"

  let #(call, done) =
    script(call, [#(gone(call_id, "NORMAL_CLEARING"), at(60))])
  assert last(done)
    == [
      core.HangUpLegs([leg("1")]),
      core.Tell(id, types.Ended(types.CallerHangup, t0 + 60)),
    ]
  assert core.finished(call)
}

/// A departure found half done is taken up again at its barrier, on the
/// branch its mark names, and the shard told the caller left.
pub fn a_departure_found_is_finished_test() {
  let marks = [
    #(recovery.departing_var, "h1"),
    #(recovery.departing_branch_var, "exit_key"),
  ]
  let #(call, done, _id) = recovered([caller_row(None)], None, marks)
  assert last(done)
    == [
      core.Left(types.ExitKey),
      core.Mark([
        #(core.departing_var, doc.String("h1")),
        #(core.departing_branch_var, doc.String("exit_key")),
      ]),
      core.Barrier(core.barrier_id(handoff("h1"))),
    ]
  let #(_call, done) =
    script(call, [#(noop_done(core.barrier_id(handoff("h1"))), at(2))])
  assert last(done) == [core.Continue(handoff("h1"), "exit_key")]
}

/// Handed back already, or through to somebody else: let go and settled.
pub fn a_caller_found_elsewhere_is_let_go_test() {
  let #(call, done, _id) =
    recovered([caller_row(None)], None, [
      #(recovery.departed_var, "h1"),
      #(recovery.departing_branch_var, "timeout"),
    ])
  assert last(done) == [core.Left(types.Timeout)]
  assert core.finished(call)

  let rows = [
    caller_row(Some("pickup")),
    row("pickup", Some(call_id), True, []),
  ]
  let #(call, done, _id) = recovered(rows, None, [])
  assert last(done) == [core.Left(types.Transfer)]
  assert core.finished(call)
}

/// A passage the record closed is over for the queue; one answered and
/// through to nobody ended unwatched, and its end is told now.
pub fn a_passage_found_over_test() {
  let closed =
    Some(records.Passage(
      offer: None,
      answered: None,
      agent_id: None,
      agent_call_id: None,
      picked_up: False,
      ended: None,
      cancelled: Some(t0 - 5),
    ))
  let #(call, done, _id) = recovered([caller_row(None)], closed, [])
  assert last(done) == [core.Present(None, types.PresentOver)]
  assert core.finished(call)

  let #(call, done, id) =
    recovered([caller_row(None)], answered_record(t0 - 30), [])
  let assert [present, told, core.Log(_)] = last(done)
  assert present
    == core.Present(Some(id), types.PresentConnected("ann", "", t0 - 30, False))
  assert told == core.Tell(id, types.Ended(types.AgentHangup, t0 + 1))
  assert core.finished(call)
}

// --- A rejoin to an actor that knows -----------------------------------------

/// The actor running the caller's passage says where they stand at once:
/// it is the dispatcher that is new.
pub fn a_rejoin_to_a_running_actor_says_so_test() {
  let #(_call, done) = script(waiting(), [#(rejoin("h1", found_as()), at(5))])
  assert done == [[core.Present(None, types.PresentWaiting)]]

  let #(id, endpoints) = offer(["ann"])
  let #(ringing, _) =
    script(waiting(), [#(ring(id, ["ann"], endpoints, False), at(10))])
  let #(_call, done) = script(ringing, [#(rejoin("h1", found_as()), at(11))])
  assert done
    == [[core.Present(Some(id), types.PresentRinging(["ann"], t0 + 30, False))]]
}

/// A member of the passage a connected caller is in, delivered again, is
/// not the caller passed on into a queue: nothing ends.
pub fn a_connected_callers_own_member_again_test() {
  let rows = [
    caller_row(Some(leg("1"))),
    leg_row("1", "ann", True, Some(call_id)),
  ]
  let #(call, _done, _id) = recovered(rows, None, [])
  let #(call, done) = script(call, [#(core.Joined(joining("h1")), at(20))])
  assert done == [[]]
  assert phase_name(call) == "connected"
}

fn nth(items: List(a), n: Int) -> Result(a, Nil) {
  items |> list.drop(n) |> list.first
}

// --- Quarantine ------------------------------------------------------------------

/// An actor started after the call's actors kept crashing hands the caller
/// back on `no_agents` at once, through the usual barrier, finding nothing
/// out first, and tells the shard they left quarantined.
pub fn a_quarantined_caller_is_handed_back_test() {
  let #(call, done) =
    script(fresh(), [#(core.Quarantine(joining("h1")), at(0))])
  let assert [
    core.Log(_),
    core.Left(types.Quarantined),
    core.Mark(marks),
    core.Barrier(barrier),
  ] = last(done)
  assert marks
    == [
      #(core.departing_var, doc.String("h1")),
      #(core.departing_branch_var, doc.String("no_agents")),
    ]
  assert barrier == core.barrier_id(handoff("h1"))
  assert phase_name(call) == "leaving"

  let #(_call, done) = script(call, [#(noop_done(barrier), at(1))])
  assert last(done) == [core.Continue(handoff("h1"), "no_agents")]
}
