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
  answer_marking, at, at_ms, barrier_done, bridged_to, call_id, departing,
  departure_marked, event, fresh, gone, handoff, key, last, marks_ran, noop_done,
  offer, parked, phase_name, ring, script, settings, t0, waiting,
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
  surveyed_as(rows, recovery.RecordRead(record))
}

fn surveyed_as(rows: List(events.Channel), record: recovery.Recorded) -> Input {
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
    cancel_reason: None,
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
  assert list.contains(found, core.Departing("h1", types.ExitKey))
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
  let ticks =
    list.repeat(Nil, core.recover_attempts)
    |> list.index_map(fn(_, n) {
      #(core.Tick, at_ms({ n + 1 } * core.recover_ms))
    })
  let #(call, done) =
    script(fresh(), [#(rejoin("h1", found_as()), at(0)), ..ticks])
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

/// A node that has just started asks its switches nothing and hears back
/// at once, while the caller's own channel answers the probe. With an
/// agent ringing on the record, that is not taken to be waiting: the next
/// try waits out this one's time, so that the tries span what the node
/// takes to hear of its switches, and the listing that comes in then
/// finds the ring.
pub fn a_listing_nobody_answered_is_asked_again_in_time_test() {
  let record =
    Some(records.Passage(
      offer: Some(records.Offered(
        agents: ["ann"],
        at: t0,
        leg_prefix: Some(prefix),
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
  let nobody =
    core.Surveyed(recovery.Survey(
      channels: None,
      record: recovery.RecordRead(record),
    ))
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", found_as()), at(0)),
      #(nobody, at_ms(100)),
      #(probe_done(1, []), at_ms(100)),
      #(core.Tick, at_ms(core.recover_ms - 1)),
      #(core.Tick, at_ms(core.recover_ms)),
      #(
        surveyed([caller_row(None), leg_row("1", "ann", False, None)], record),
        at_ms(core.recover_ms + 100),
      ),
      #(probe_done(2, []), at_ms(core.recover_ms + 100)),
    ])
  // Nothing before the attempt's time is up.
  assert nth(done, 1) == Ok([])
  assert nth(done, 2) == Ok([])
  assert nth(done, 3) == Ok([])
  assert nth(done, 4)
    == Ok([core.Probe(recovery.probe_id("h1", 2)), core.Survey])
  // The ring is found and taken on, and nobody is rung again.
  assert phase_name(call) == "ringing"
  assert !list.any(list.flatten(done), fn(effect) {
    case effect {
      core.Originate(..) -> True
      _ -> False
    }
  })
}

// --- A record that could not be read -------------------------------------------

/// A caller gone, whose record the datastore did not answer for, is asked
/// about again rather than settled as a hang-up. The record read on the
/// next try has an answer nothing closed, and the call is closed as the
/// call it was: the dispatcher hears its answer and its end.
pub fn a_record_not_read_is_asked_again_test() {
  let id = found_as()
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", id), at(0)),
      #(surveyed_as([], recovery.RecordUnreadable("timeout")), at(1)),
      #(core.Tick, at_ms(1000 + core.probe_ms)),
      #(core.Tick, at_ms(core.recover_ms)),
      #(surveyed([], answered_record(t0 - 30)), at_ms(core.recover_ms + 100)),
      #(core.Tick, at_ms(core.recover_ms + 100 + core.probe_ms)),
    ])
  // Nothing concluded on the first try, and the next is at its end.
  assert nth(done, 1) == Ok([])
  assert nth(done, 2) == Ok([])
  assert nth(done, 3)
    == Ok([core.Probe(recovery.probe_id("h1", 2)), core.Survey])
  let assert [present, ended, core.Log(_)] = last(done)
  assert present
    == core.Present(Some(id), types.PresentConnected("ann", "", t0 - 30, False))
  assert ended == core.Tell(id, types.Ended(types.CallerHangup, t0 + 11))
  assert !list.contains(list.flatten(done), core.Left(types.Hangup))
  assert core.finished(call)
}

/// Every try's survey lists `rows` and could not read the record, and the
/// probe is answered with `vars`, or never. Each try runs out its time
/// before the next; the last is classified as soon as it can be.
fn never_read(
  rows: List(events.Channel),
  vars: Option(List(#(String, String))),
) -> #(core.Call, List(List(core.Effect)), types.OfferId) {
  let id = found_as()
  let tries =
    list.repeat(Nil, core.recover_attempts)
    |> list.index_map(fn(_, n) {
      let start = n * core.recover_ms
      let survey = [
        #(
          surveyed_as(rows, recovery.RecordUnreadable("timeout")),
          at_ms(start + 100),
        ),
      ]
      let probe = case vars {
        Some(vars) -> [#(probe_done(n + 1, vars), at_ms(start + 100))]
        None -> []
      }
      let tick = case vars, n + 1 == core.recover_attempts {
        Some(_), True -> []
        _, _ -> [#(core.Tick, at_ms(start + core.recover_ms))]
      }
      list.flatten([survey, probe, tick])
    })
    |> list.flatten
  let #(call, done) = script(fresh(), [#(rejoin("h1", id), at(0)), ..tries])
  #(call, done, id)
}

/// A record no try could read is taken, on the last try, for no record,
/// and the caller is where the probe and the switches alone put them:
/// taking them all to be waiting would put a caller in a conversation on
/// hold, offer one who has gone, and keep one the callflow has back. Only
/// a caller the switches cannot place either is taken to be waiting.
pub fn a_record_never_read_is_taken_as_the_switches_find_it_test() {
  let bridged = [
    caller_row(Some(leg("1"))),
    leg_row("1", "ann", True, Some(call_id)),
  ]
  let departed = [
    #(recovery.departed_var, "h1"),
    #(recovery.departing_branch_var, "timeout"),
  ]
  // The last try is classified at 40.1 seconds.
  let cases = [
    #(bridged, Some([]), "connected", fn(id) {
      [
        core.Present(
          Some(id),
          types.PresentConnected("ann", leg("1"), t0 + 40, False),
        ),
      ]
    }),
    #([], None, "done", fn(_id) { [core.Left(types.Hangup)] }),
    #([caller_row(None)], Some(departed), "done", fn(_id) {
      [core.Left(types.Timeout)]
    }),
    #([caller_row(None)], Some([]), "waiting", fn(_id) {
      [
        core.Hold(Some("support-hold")),
        core.Present(None, types.PresentWaiting),
      ]
    }),
  ]
  list.each(cases, fn(case_) {
    let #(rows, vars, phase, expected) = case_
    let #(call, done, id) = never_read(rows, vars)
    let assert [core.Log(_), ..found] = last(done)
    assert found == expected(id)
    assert phase_name(call) == phase
    // Before it, every try only asked.
    let asked =
      done
      |> list.take(list.length(done) - 1)
      |> list.flatten
    assert list.all(asked, fn(effect) {
      case effect {
        core.Probe(_) | core.Survey -> True
        _ -> False
      }
    })
    assert list.count(asked, fn(effect) { effect == core.Survey })
      == core.recover_attempts
  })
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

/// Gone after an answer nothing closed: the dispatcher hears the call and
/// its end, so that the record is closed as the call it was and the agent
/// gets their wrap-up, not as a caller who left.
pub fn a_caller_found_gone_after_an_answer_test() {
  let id = found_as()
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", id), at(0)),
      #(surveyed([], answered_record(t0 - 30)), at(1)),
      #(core.Tick, at_ms(1000 + core.probe_ms)),
    ])
  let assert [present, ended, core.Log(_)] = last(done)
  assert present
    == core.Present(Some(id), types.PresentConnected("ann", "", t0 - 30, False))
  assert ended == core.Tell(id, types.Ended(types.CallerHangup, t0 + 4))
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
      #(parked(leg("1")), at(4)),
      #(marks_ran(leg("1")), at(4)),
      #(bridged_to(leg("1")), at(4)),
    ])
  assert list.take(done, 3)
    == [answer_marking("ann", t0 + 4, leg("1")), [], [core.Bridge(leg("1"))]]
  assert list.contains(
    last(done),
    core.Tell(id, types.Answered("ann", leg("1"), t0 + 4)),
  )
  assert phase_name(call) == "connected"
}

/// A leg found answered is long parked. The caller is marked at once, on
/// the second the last actor's marks say it answered, or now when they say
/// nothing of its agent, and bridged once the marks are seen to run: the
/// last actor's may not have, and marks that did are only written again.
/// The dispatcher hears the answer on that same second.
pub fn a_parked_leg_found_is_marked_then_bridged_test() {
  let rows = [caller_row(None), leg_row("1", "ann", True, Some(leg("1")))]
  let cases = [
    #("unmarked", [], t0 + 1),
    #(
      "marked by its agent",
      [#("Agent-ID", "ann"), #("Queue-Answered-Timestamp", "63799999998")],
      t0 - 2,
    ),
    #(
      "marked by another agent",
      [#("Agent-ID", "bob"), #("Queue-Answered-Timestamp", "63799999998")],
      t0 + 1,
    ),
  ]
  list.each(cases, fn(case_) {
    let #(name, marks, answered) = case_
    let #(call, done, id) = recovered(rows, None, marks)
    assert last(done)
      == [
        core.Present(Some(id), types.PresentRinging(["ann"], t0 + 13, False)),
        ..answer_marking("ann", answered, leg("1"))
      ]
      as name
    assert phase_name(call) == "parking" as name

    let #(call, done) =
      script(call, [
        #(marks_ran(leg("1")), at(1)),
        #(bridged_to(leg("1")), at(2)),
      ])
    assert list.first(done) == Ok([core.Bridge(leg("1"))]) as name
    assert list.contains(
      last(done),
      core.Tell(id, types.Answered("ann", leg("1"), answered)),
    )
      as name
    assert phase_name(call) == "connected" as name
  })
}

/// The completion of the last actor's `noop` behind its marks, heard while
/// the caller was being found out about, is the proof that those marks ran,
/// and they name the same agent: the caller is bridged in the step that
/// finds the leg parked, and the marks sent again then may be thrown away
/// by the bridge's flush without the CDR losing the agent.
pub fn marks_seen_to_run_while_finding_out_test() {
  let rows = [caller_row(None), leg_row("1", "ann", True, Some(leg("1")))]
  let id = found_as()
  let #(call, done) =
    script(fresh(), [
      #(rejoin("h1", id), at(0)),
      #(marks_ran(leg("1")), at(0)),
      #(surveyed(rows, None), at(1)),
      #(probe_done(1, []), at(1)),
    ])
  assert last(done)
    == list.flatten([
      [core.Present(Some(id), types.PresentRinging(["ann"], t0 + 13, False))],
      answer_marking("ann", t0 + 1, leg("1")),
      [core.Bridge(leg("1"))],
    ])
  assert phase_name(call) == "connecting"
}

/// A caller found parked whom the last actor had in fact bridged -- it sent
/// the bridge and died before the survey listed it -- is through to their
/// agent once their own bridge to the leg is heard, held while finding out
/// or heard after: nothing but the queue bridges a caller to their own leg.
/// The leg is not hung up, and the dispatcher hears the answer. A bridge to
/// anybody else's channel is still something else taking the caller.
pub fn a_caller_found_parked_and_bridged_to_the_leg_test() {
  let rows = [caller_row(None), leg_row("1", "ann", True, Some(leg("1")))]
  let cases = [
    #("to the leg, held while finding out", True, leg("1"), "connected"),
    #("to the leg, heard after", False, leg("1"), "connected"),
    #("to another channel, held while finding out", True, "pickup", "done"),
    #("to another channel, heard after", False, "pickup", "done"),
  ]
  list.each(cases, fn(case_) {
    let #(name, held, other, ends) = case_
    let id = found_as()
    let #(call, done) = case held {
      True ->
        script(fresh(), [
          #(rejoin("h1", id), at(0)),
          #(bridged_to(other), at(0)),
          #(surveyed(rows, None), at(1)),
          #(probe_done(1, []), at(1)),
        ])
      False ->
        script(fresh(), [
          #(rejoin("h1", id), at(0)),
          #(surveyed(rows, None), at(1)),
          #(probe_done(1, []), at(1)),
          #(bridged_to(other), at(1)),
        ])
    }
    let effects = list.flatten(done)
    assert phase_name(call) == ends as name
    let answered = core.Tell(id, types.Answered("ann", leg("1"), t0 + 1))
    let took = core.Left(types.Transfer)
    assert #(list.contains(effects, answered), list.contains(effects, took))
      == case ends {
        "connected" -> #(True, False)
        _ -> #(False, True)
      }
      as name
    assert !list.contains(effects, core.Bridge(leg("1"))) as name
    assert list.contains(effects, core.HangUpLegs([leg("1")]))
      == { ends == "done" }
      as name
  })
}

/// A call found connected is watched to its end, and the dispatcher told
/// who is talking. The caller is not marked again: the last actor marked
/// them before it bridged them, and a command sent to a caller in a bridge
/// would run inside it, if at all, holding the agent while it did.
pub fn a_call_found_connected_test() {
  let rows = [
    caller_row(Some(leg("1"))),
    leg_row("1", "ann", True, Some(call_id)),
  ]
  let #(call, done, id) = recovered(rows, answered_record(t0 - 30), [])
  assert last(done)
    == [
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
  assert last(done) == departing("h1", "exit_key", types.ExitKey)
  let #(call, done) =
    script(call, [
      #(departure_marked("h1"), at(2)),
      #(barrier_done("h1"), at(2)),
      #(core.Continuing("h1"), at(2)),
    ])
  assert done
    == [
      [core.Barrier(core.barrier_id(handoff("h1")))],
      [core.Continue(handoff("h1"), "exit_key")],
      [core.HandedBack("h1")],
    ]
  assert core.finished(call)
}

/// A caller whose record says they left on a branch, found still in the
/// queue's hands with no marks of it -- the last actor went before its
/// marks ran -- is handed back on the branch the record names, and the
/// member the shard kept for them is settled once they are.
pub fn a_departure_found_by_its_record_is_finished_test() {
  let record =
    Some(records.Passage(
      offer: None,
      answered: None,
      agent_id: None,
      agent_call_id: None,
      picked_up: False,
      ended: None,
      cancelled: Some(t0 - 1),
      cancel_reason: Some("timeout"),
    ))
  let #(call, done, _id) = recovered([caller_row(None)], record, [])
  assert last(done) == departing("h1", "timeout", types.Timeout)
  let #(call, done) =
    script(call, [
      #(departure_marked("h1"), at(2)),
      #(barrier_done("h1"), at(2)),
      #(core.Continuing("h1"), at(2)),
    ])
  assert done
    == [
      [core.Barrier(core.barrier_id(handoff("h1")))],
      [core.Continue(handoff("h1"), "timeout")],
      [core.HandedBack("h1")],
    ]
  assert core.finished(call)
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

/// A passage the record closed is over for the queue: the dispatcher is
/// told, and the member settled by the actor as well -- a dispatcher that
/// joined the caller to this actor to finish a departure takes no
/// `Present`, and the shard settles a member once whoever asks.
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
      cancel_reason: None,
    ))
  let #(call, done, _id) = recovered([caller_row(None)], closed, [])
  assert last(done)
    == [core.Present(None, types.PresentOver), core.HandedBack("h1")]
  assert core.finished(call)
}

/// A passage answered and through to nobody ended while nothing watched
/// it, and its end is told now, as the agent's.
///
/// A caller the probe reached is parked alone, on the control process that
/// took them into the queue, where the agent's end left them -- the bridge
/// parks the caller rather than hanging them up -- and nothing else will
/// hang them up: they are hung up, with any leg of theirs left over. A
/// caller the probe never reached may be in the callflow a transfer took
/// them to, and only their legs are hung up.
pub fn a_passage_found_ended_unwatched_test() {
  let left_over = leg_row("1", "ann", True, Some(leg("1")))
  let cases = [
    // the rows, whether the probe answers: what is hung up, and when the
    // call is taken to have ended
    #([caller_row(None)], True, [core.HangUpCaller], t0 + 1),
    #(
      [caller_row(None), left_over],
      True,
      [core.HangUpLegs([leg("1")]), core.HangUpCaller],
      t0 + 1,
    ),
    #([caller_row(None)], False, [], t0 + 4),
    #(
      [caller_row(None), left_over],
      False,
      [core.HangUpLegs([leg("1")])],
      t0 + 4,
    ),
  ]
  list.each(cases, fn(case_) {
    let #(rows, answers, hung_up, ended) = case_
    let id = found_as()
    let probe = case answers {
      True -> #(probe_done(1, []), at(1))
      False -> #(core.Tick, at_ms(1000 + core.probe_ms))
    }
    let #(call, done) =
      script(fresh(), [
        #(rejoin("h1", id), at(0)),
        #(surveyed(rows, answered_record(t0 - 30)), at(1)),
        probe,
      ])
    let assert [core.Log(_), ..told] = list.reverse(last(done))
    assert list.reverse(told)
      == list.append(hung_up, [
        core.Present(
          Some(id),
          types.PresentConnected("ann", "", t0 - 30, False),
        ),
        core.Tell(id, types.Ended(types.AgentHangup, ended)),
      ])
    assert core.finished(call)
  })
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
  let assert [core.Log(_), ..leaving] = last(done)
  assert leaving == departing("h1", "no_agents", types.Quarantined)
  assert phase_name(call) == "leaving"

  let #(_call, done) =
    script(call, [
      #(departure_marked("h1"), at(1)),
      #(barrier_done("h1"), at(1)),
    ])
  assert last(done) == [core.Continue(handoff("h1"), "no_agents")]
}
