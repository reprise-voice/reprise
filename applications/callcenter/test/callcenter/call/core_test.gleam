//// One queued call's state machine, rule by rule: each test is a short
//// script of inputs, and what the call does and becomes after each.

import callcenter/announce
import callcenter/call/core.{type Call, Positioned, Tick}
import callcenter/call/media
import callcenter/call/talk
import callcenter/caller
import callcenter/types
import gleam/list
import gleam/option.{None, Some}
import kazoo/call as kcall
import kazoo/doc
import support/call_script.{
  answer_marking, answer_marks, at, at_ms, bridged_to, call_id, departure_marked,
  event, fresh, gone, handoff, joining, key, last, leg_of, marks_ran, noop_done,
  offer, originate_error, originate_success, parked, phase_name, ring, script,
  settings, t0, waiting,
}

// --- Joining -----------------------------------------------------------------

/// A caller joins: the queue's greeting plays, and hold follows it once the
/// switch says it has finished. A queue with no greeting holds at once.
pub fn a_caller_joins_to_the_greeting_then_hold_test() {
  let #(call, done) =
    script(fresh(), [
      #(joining("h1", settings()), at(0)),
      #(
        event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
          #("Application-Name", doc.String("noop")),
        ]),
        at(3),
      ),
    ])
  assert done == [[core.Play("welcome")], [core.Hold(Some("support-hold"))]]
  assert phase_name(call) == "waiting"

  let #(call, done) =
    script(fresh(), [
      #(joining("h1", core.Settings(..settings(), greeting: None)), at(0)),
    ])
  assert done == [[core.Hold(Some("support-hold"))]]
  assert phase_name(call) == "waiting"
}

/// A call a node that died had connected is taken on as it stands: nothing
/// is sent, and the end of its bridge is heard like any other's.
pub fn an_adopted_call_is_watched_to_its_end_test() {
  let #(id, _endpoints) = offer(["ann"])
  let adoption =
    core.Adopt(core.Adoption(
      joining: core.Joining(
        queue_id: call_script.queue_id,
        joined: t0,
        handoff: handoff("h1"),
        settings: settings(),
      ),
      offer: id,
      agent_id: "ann",
      leg: "ann-leg",
      answered_at: t0 + 20,
    ))
  let #(call, done) =
    script(fresh(), [
      #(adoption, at(60)),
      #(gone(call_id, "NORMAL_CLEARING"), at(90)),
    ])
  assert list.first(done) == Ok([])
  assert phase_name(call) == "done"
  assert last(done)
    == [
      core.HangUpLegs(["ann-leg"]),
      core.Tell(id, types.Ended(types.CallerHangup, t0 + 90)),
    ]

  // An actor already running a passage is not taken over by an adoption.
  let #(call, done) = script(waiting(), [#(adoption, at(60))])
  assert done == [[]]
  assert phase_name(call) == "waiting"
}

/// The same member delivered again changes nothing.
pub fn the_same_passage_joined_twice_test() {
  let #(_call, done) = script(waiting(), [#(joining("h1", settings()), at(5))])
  assert done == [[]]
}

// --- Ringing -----------------------------------------------------------------

/// A ring is one originate, and the dispatcher hears the ring is out. The
/// caller's media is not touched.
pub fn a_ring_is_one_originate_test() {
  let #(id, endpoints) = offer(["ann", "bob"])
  let #(call, done) =
    script(waiting(), [#(ring(id, ["ann", "bob"], endpoints, False), at(10))])
  assert done
    == [
      [
        core.Originate(id, endpoints, 15),
        core.Tell(id, types.OfferRinging(["ann", "bob"])),
      ],
    ]
  assert phase_name(call) == "ringing"
}

/// A caller who is not waiting is not rung, and one with nothing to ring
/// neither: the dispatcher hears a failure at once.
pub fn a_ring_that_cannot_go_out_test() {
  let #(id, _endpoints) = offer(["ann"])
  let #(_, done) = script(waiting(), [#(ring(id, ["ann"], [], False), at(10))])
  assert done == [[core.Tell(id, types.Failed(core.no_endpoints))]]

  let #(id, endpoints) = offer(["ann"])
  let #(_, done) =
    script(fresh(), [#(ring(id, ["ann"], endpoints, False), at(1))])
  assert done == [[core.Tell(id, types.Failed(core.not_waiting))]]
}

/// A leg answers: the caller is bridged to it, and once their own channel
/// says so the call is connected, and the dispatcher hears the answer,
/// dated by the leg's. The caller is marked as the leg answers, while still
/// on hold, with a `noop` sent at once behind the marks, and is bridged
/// once that `noop` has completed and the leg's originate has parked it,
/// in either order. A leg bridged sooner is taken back out of the bridge by
/// that `park`, and marks not yet run are thrown away by the bridge's
/// flush.
pub fn an_answer_connects_test() {
  let #(id, endpoints) = offer(["ann", "bob"])
  let leg = leg_of(id, 2)
  let cases = [
    #("marks, then park", [marks_ran(leg), parked(leg)]),
    #("park, then marks", [parked(leg), marks_ran(leg)]),
  ]
  list.each(cases, fn(case_) {
    let #(name, heard) = case_
    let #(call, done) =
      script(
        waiting(),
        list.flatten([
          [
            #(ring(id, ["ann", "bob"], endpoints, True), at(10)),
            #(event(leg, "CHANNEL_ANSWER", []), at(14)),
          ],
          list.map(heard, fn(input) { #(input, at(14)) }),
          [#(bridged_to(leg), at(15))],
        ]),
      )
    assert done
      == [
        [
          core.Originate(id, endpoints, 15),
          core.Tell(id, types.OfferRinging(["ann", "bob"])),
        ],
        answer_marking("bob", t0 + 14, leg),
        [],
        [core.Bridge(leg)],
        [
          core.Record("bob", t0 + 14),
          core.Tell(id, types.Answered("bob", leg, t0 + 14)),
        ],
      ]
      as name
    assert phase_name(call) == "connected" as name
  })
}

/// A leg whose `park` is never heard is taken to be parked after
/// `park_wait_ms`, once its marks have run; and a `park` heard before the
/// answer is the answer: the caller is marked, the leg's answer after it
/// changes nothing, and the caller is bridged once the marks have run.
pub fn a_leg_parked_unheard_or_early_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at_ms(12_000)),
      #(marks_ran(leg), at_ms(12_020)),
      #(core.Tick, at_ms(12_000 + core.park_wait_ms - 1)),
      #(core.Tick, at_ms(12_000 + core.park_wait_ms)),
    ])
  assert list.drop(done, 2) == [[], [], [core.Bridge(leg)]]
  assert phase_name(call) == "connecting"

  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(parked(leg), at(12)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(marks_ran(leg), at(12)),
    ])
  assert list.drop(done, 1)
    == [answer_marking("ann", t0 + 12, leg), [], [core.Bridge(leg)]]
  assert phase_name(call) == "connecting"
}

/// ecallmgr's `originate_resp` naming the leg is the answer when it comes
/// before the leg's own event: the caller is marked, the leg's event after
/// it changes nothing, and the caller is bridged once the marks have run.
pub fn the_originate_says_who_answered_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(originate_success(id, leg), at(12)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(marks_ran(leg), at(12)),
    ])
  assert list.drop(done, 1)
    == [answer_marking("ann", t0 + 12, leg), [], [core.Bridge(leg)]]
  assert phase_name(call) == "connecting"
}

/// Marks not seen to run are waited for until `park_wait_ms`, and no longer:
/// the agent's leg is on its own until the bridge. The caller is bridged
/// then all the same, and the operator told the marks may be lost. The
/// completion of any other `noop` -- a play's end, the bridge's own flush,
/// the marks of another leg -- is not theirs, and one that comes after the
/// bridge changes nothing.
pub fn marks_never_seen_to_run_test() {
  let #(id, endpoints) = offer(["ann", "bob"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann", "bob"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at_ms(12_000)),
      #(parked(leg), at_ms(12_040)),
      #(
        event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
          #("Application-Name", doc.String("noop")),
        ]),
        at_ms(12_050),
      ),
      #(noop_done("callcenter-flush-" <> leg), at_ms(12_060)),
      #(marks_ran(leg_of(id, 2)), at_ms(12_070)),
      #(core.Tick, at_ms(12_000 + core.park_wait_ms - 1)),
      #(core.Tick, at_ms(12_000 + core.park_wait_ms)),
      #(marks_ran(leg), at_ms(12_200)),
    ])
  assert list.drop(done, 2) |> list.take(5) == [[], [], [], [], []]
  let assert [core.Log(_), core.Bridge(bridged)] =
    list.drop(done, 7) |> list.first |> result_or([])
  assert bridged == leg
  assert last(done) == []
  assert phase_name(call) == "connecting"
}

/// However the answer is first heard -- the leg's `CHANNEL_ANSWER`, its
/// `park`, or its originate's success -- and in whatever order the rest
/// comes, the caller is marked with the agent and the second exactly once,
/// with the `noop` that shows the marks ran right behind them; the bridge
/// goes out only in a later step, once that `noop` has completed; and the
/// dispatcher hears the answer on the second of the marks. The marks are on
/// the caller's CDR, and they are what a node taking the call over dates
/// the answer by.
pub fn every_answer_is_marked_before_the_bridge_test() {
  let #(id, endpoints) = offer(["ann", "bob"])
  let leg = leg_of(id, 2)
  let answer = event(leg, "CHANNEL_ANSWER", [])
  let originated = originate_success(id, leg)
  let park = parked(leg)
  let marks = marks_ran(leg)
  let cases = [
    #("answer, marks, park", [answer, marks, park]),
    #("answer, park, marks", [answer, park, marks]),
    #("answer, marks, originate", [answer, marks, originated]),
    #("answer, originate, marks", [answer, originated, marks]),
    #("answer, marks, nothing", [answer, marks, Tick]),
    #("park, marks, answer", [park, marks, answer]),
    #("park, answer, marks", [park, answer, marks]),
    #("park, originate, marks", [park, originated, marks]),
    #("originate, marks, park", [originated, marks, park]),
    #("originate, answer, marks", [originated, answer, marks]),
    #("originate, park, marks", [originated, park, marks]),
  ]
  list.each(cases, fn(case_) {
    let #(name, heard) = case_
    // Ten milliseconds apart, well inside the wait; the tick, past it.
    let steps =
      list.index_map(heard, fn(input, n) {
        case input {
          Tick -> #(input, at_ms(14_000 + core.park_wait_ms + n * 10))
          _ -> #(input, at_ms(14_000 + n * 10))
        }
      })
    let #(call, done) =
      script(
        waiting(),
        list.flatten([
          [#(ring(id, ["ann", "bob"], endpoints, False), at(10))],
          steps,
          [#(bridged_to(leg), at(15))],
        ]),
      )
    let done = list.drop(done, 1)
    let marked =
      step_of(done, fn(effects) { list.any(effects, is_answer_mark) })
    let bridged =
      step_of(done, fn(effects) { list.contains(effects, core.Bridge(leg)) })
    let ran =
      step_of(list.map(heard, fn(input) { [input] }), list.contains(_, marks))
    assert list.filter(list.flatten(done), is_answer_mark)
      == [answer_marks("bob", t0 + 14)]
      as name
    assert list.drop(done, marked) |> list.first
      == Ok(answer_marking("bob", t0 + 14, leg))
      as name
    assert marked < ran && ran <= bridged as name
    assert list.contains(
      list.flatten(done),
      core.Tell(id, types.Answered("bob", leg, t0 + 14)),
    )
      as name
    assert phase_name(call) == "connected" as name
  })
}

fn is_answer_mark(effect: core.Effect) -> Bool {
  case effect {
    core.Mark(vars) -> list.any(vars, fn(var) { var.0 == "Agent-ID" })
    _ -> False
  }
}

/// The index of the first step whose effects are so, or -1.
fn step_of(done: List(List(a)), so: fn(List(a)) -> Bool) -> Int {
  list.index_fold(done, -1, fn(found, effects, n) {
    case found < 0 && so(effects) {
      True -> n
      False -> found
    }
  })
}

/// The race is decided by whichever the actor handles first. An answer
/// first stands: the exit key after it does nothing.
pub fn an_answer_before_the_exit_key_stands_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(key("#"), at(12)),
      #(core.CallOff(id), at(12)),
      #(parked(leg), at(12)),
      #(key("#"), at(12)),
      #(marks_ran(leg), at(12)),
      #(key("#"), at(12)),
      #(bridged_to(leg), at(12)),
    ])
  assert list.drop(done, 1) |> list.take(7)
    == [
      answer_marking("ann", t0 + 12, leg),
      [],
      [],
      [],
      [],
      [core.Bridge(leg)],
      [],
    ]
  assert phase_name(call) == "connected"
}

/// An exit key first stands: every leg is hung up, the answer that follows
/// it included, and the caller leaves on `exit_key`.
pub fn the_exit_key_before_an_answer_stands_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(key("#"), at(12)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
    ])
  assert list.drop(done, 1)
    == [
      [
        core.HangUpLegs([leg]),
        core.Departing("h1", types.ExitKey),
        departing("h1", "exit_key"),
        core.Confirm(core.departure_marks_id(handoff("h1"))),
      ],
      [core.HangUpLegs([leg])],
    ]
  assert phase_name(call) == "leaving"
}

/// A key that is not an exit key does nothing.
pub fn another_key_test() {
  let #(call, done) = script(waiting(), [#(key("5"), at(10))])
  assert done == [[]]
  assert phase_name(call) == "waiting"
}

// --- A ring's end --------------------------------------------------------------

/// The originate ends in an error: the ring is over, and whose miss it is
/// comes from the cause. The caller goes back to waiting untouched.
pub fn a_ring_that_nobody_answered_test() {
  let cases = [
    #("NO_ANSWER", ["ann", "bob"], types.OfferNoAnswer(["ann", "bob"])),
    #("-ERR USER_BUSY", ["ann"], types.Busy("ann")),
    #("CALL_REJECTED", ["ann"], types.Rejected("ann")),
    #("USER_BUSY", ["ann", "bob"], types.OfferNoAnswer(["ann", "bob"])),
    #("UNALLOCATED_NUMBER", ["ann"], types.Failed("UNALLOCATED_NUMBER")),
  ]
  list.each(cases, fn(case_) {
    let #(cause, agents, reply) = case_
    let #(id, endpoints) = offer(agents)
    let #(call, done) =
      script(waiting(), [
        #(ring(id, agents, endpoints, False), at(10)),
        #(originate_error(id, cause), at(25)),
      ])
    assert last(done) == [core.Tell(id, reply)]
    assert phase_name(call) == "waiting"
  })
}

/// Every leg the offer named has gone without an answer: the ring is over,
/// as the last leg says, whether or not the originate's word comes.
pub fn every_leg_gone_test() {
  let #(id, endpoints) = offer(["ann", "bob"])
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann", "bob"], endpoints, False), at(10)),
      #(gone(leg_of(id, 1), "NO_ANSWER"), at(25)),
      #(gone(leg_of(id, 2), "NO_ANSWER"), at(25)),
      #(originate_error(id, "NO_ANSWER"), at(25)),
    ])
  assert list.drop(done, 1)
    == [[], [core.Tell(id, types.OfferNoAnswer(["ann", "bob"]))], []]
  assert phase_name(call) == "waiting"
}

/// A ring the switch never ends is given up at its deadline: its legs are
/// hung up, and it is a miss only if one of them was seen.
pub fn a_ring_nothing_ended_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(_, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_CREATE", []), at(10)),
      #(Tick, at(30)),
    ])
  assert last(done)
    == [core.HangUpLegs([leg]), core.Tell(id, types.OfferNoAnswer(["ann"]))]

  let #(id, endpoints) = offer(["ann"])
  let #(_, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(Tick, at(30)),
    ])
  assert last(done)
    == [
      core.HangUpLegs([leg_of(id, 1)]),
      core.Tell(id, types.Failed(core.nothing_rang)),
    ]
}

// --- Calling off -------------------------------------------------------------

/// The dispatcher calls a ring off: its legs are hung up, the caller goes
/// on waiting, and the dispatcher hears `called_off` when the originate
/// says the ring is over -- a leg that turns up before then is hung up too.
pub fn a_ring_called_off_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(core.CallOff(id), at(11)),
      #(event(leg, "CHANNEL_CREATE", []), at(11)),
      #(gone(leg, "ORIGINATOR_CANCEL"), at(11)),
      #(originate_error(id, "ORIGINATOR_CANCEL"), at(11)),
    ])
  assert list.drop(done, 1)
    == [
      [core.HangUpLegs([leg])],
      [core.HangUpLegs([leg])],
      [],
      [core.Tell(id, types.Failed(core.called_off_reason))],
    ]
  assert phase_name(call) == "waiting"
  assert call.recalls == []
}

/// A call-off that comes after the answer does nothing: the answer stands.
pub fn a_call_off_after_the_answer_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(core.CallOff(id), at(12)),
    ])
  assert last(done) == []
  assert phase_name(call) == "parking"
}

/// A queue deleted while a ring goes: the caller leaves on `no_agents` with
/// no word to the shard -- the dispatcher did it -- and the dispatcher hears
/// the ring's end as `called_off` once the originate says so.
pub fn a_queue_deleted_while_ringing_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(core.QueueGone, at(11)),
      #(originate_error(id, "ORIGINATOR_CANCEL"), at(11)),
    ])
  assert list.drop(done, 1)
    == [
      [
        core.HangUpLegs([leg]),
        departing("h1", "no_agents"),
        core.Confirm(core.departure_marks_id(handoff("h1"))),
      ],
      [core.Tell(id, types.Failed(core.called_off_reason))],
    ]
  assert phase_name(call) == "leaving"
}

// --- Connecting ------------------------------------------------------------------

/// The agent's leg goes between the answer and the bridge. The answer
/// decided the call, so it is an answered call the agent ended: the
/// dispatcher hears the answer and its end, and the caller is hung up, as a
/// connected caller is when the agent hangs up on them. The same whether
/// the bridge had gone out or was still waiting for the leg's `park`, the
/// marks' `noop`, or both.
pub fn the_agent_leaves_before_the_bridge_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let ended = [
    core.HangUpCaller,
    core.Tell(id, types.Answered("ann", leg, t0 + 12)),
    core.Tell(id, types.Ended(types.AgentHangup, t0 + 12)),
  ]
  let cases = [
    #("bridging", [parked(leg), marks_ran(leg)]),
    #("parked, marks not run", [parked(leg)]),
    #("marks run, not parked", [marks_ran(leg)]),
    #("answered", []),
  ]
  list.each(cases, fn(case_) {
    let #(name, heard) = case_
    let #(call, done) =
      script(
        waiting(),
        list.flatten([
          [
            #(ring(id, ["ann"], endpoints, False), at(10)),
            #(event(leg, "CHANNEL_ANSWER", []), at(12)),
          ],
          list.map(heard, fn(input) { #(input, at(12)) }),
          [#(gone(leg, "NORMAL_CLEARING"), at(12))],
        ]),
      )
    assert last(done) == ended as name
    assert core.finished(call) as name
  })
}

/// The caller hangs up after the answer and before the bridge: an answered
/// call the caller ended, and the agent's leg is hung up. Nothing is said
/// to the shard: the dispatcher settles the member at the end, as it does
/// every answered call's.
pub fn the_caller_leaves_before_the_bridge_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let ended = [
    core.HangUpLegs([leg]),
    core.Tell(id, types.Answered("ann", leg, t0 + 12)),
    core.Tell(id, types.Ended(types.CallerHangup, t0 + 13)),
  ]
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(gone(call_id, "NORMAL_CLEARING"), at(13)),
    ])
  assert last(done) == ended
  assert core.finished(call)

  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(parked(leg), at(12)),
      #(marks_ran(leg), at(12)),
      #(gone(call_id, "NORMAL_CLEARING"), at(13)),
    ])
  assert last(done) == ended
  assert core.finished(call)
}

/// A bridge that never shows is given up at `connect_ms`.
pub fn a_bridge_that_never_shows_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(marks_ran(leg), at(12)),
      #(parked(leg), at(12)),
      #(Tick, at_ms(12_000 + core.connect_ms - 1)),
      #(Tick, at_ms(12_000 + core.connect_ms)),
    ])
  assert list.drop(done, 4)
    == [
      [],
      [
        core.HangUpLegs([leg]),
        core.Tell(id, types.Failed(core.bridge_failed)),
        core.Hold(Some("support-hold")),
      ],
    ]
  assert phase_name(call) == "waiting"
}

/// The caller bridged to somebody this queue did not ring is somebody
/// else's now: a ring going is called off, and the shard is told the caller
/// left, as a transfer.
pub fn the_caller_taken_by_another_bridge_test() {
  let #(id, endpoints) = offer(["ann"])
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(bridged_to("somebody-else"), at(11)),
    ])
  assert case last(done) {
    [core.HangUpLegs(_), core.Left(types.Transfer), core.Log(_)] -> True
    _ -> False
  }
  assert call.phase == core.Done
}

// --- Connected -------------------------------------------------------------------

fn connected() -> #(Call, types.OfferId, String) {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, _) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(marks_ran(leg), at(12)),
      #(parked(leg), at(12)),
      #(bridged_to(leg), at(12)),
    ])
  #(call, id, leg)
}

/// The agent hangs up: the caller parks, the call waits `transfer_wait_ms`
/// for a sign it was a transfer, and with none the caller is hung up and the
/// call is over, dated by the bridge's end.
pub fn the_agent_hangs_up_test() {
  let #(call, id, leg) = connected()
  let #(call, done) =
    script(call, [
      #(gone(leg, "NORMAL_CLEARING"), at(100)),
      #(event(call_id, "CHANNEL_UNBRIDGE", []), at(100)),
      #(Tick, at_ms(100_000 + talk.transfer_wait_ms)),
    ])
  assert done
    == [
      [],
      [],
      [
        core.HangUpLegs([leg]),
        core.HangUpCaller,
        core.Tell(id, types.Ended(types.Completed, t0 + 100)),
      ],
    ]
  assert core.finished(call)
}

/// The caller hangs up: the call is over, and the agent's leg is hung up in
/// case the switch left it.
pub fn the_caller_hangs_up_on_the_agent_test() {
  let #(call, id, leg) = connected()
  let #(call, done) =
    script(call, [#(gone(call_id, "NORMAL_CLEARING"), at(100))])
  assert done
    == [
      [
        core.HangUpLegs([leg]),
        core.Tell(id, types.Ended(types.CallerHangup, t0 + 100)),
      ],
    ]
  assert core.finished(call)
}

/// The agent passes the caller on: the call is over as a transfer, and the
/// caller is left alone.
pub fn the_agent_transfers_the_caller_test() {
  let #(call, id, leg) = connected()
  let #(_call, done) =
    script(call, [
      #(gone(leg, "NORMAL_CLEARING"), at(100)),
      #(event(call_id, "CHANNEL_TRANSFEREE", []), at(100)),
    ])
  assert last(done)
    == [
      core.HangUpLegs([leg]),
      core.Tell(id, types.Ended(types.Transferred, t0 + 100)),
    ]
}

/// A blind transfer from the agent's phone leaves the agent's leg parked:
/// the bridge put `park_after_bridge` on it. The leg is hung up with the
/// call's end, and the caller, on their way to the target, is left alone.
pub fn the_agent_is_released_after_a_blind_transfer_test() {
  let #(call, id, leg) = connected()
  let #(call, done) =
    script(call, [
      #(event(call_id, "CHANNEL_UNBRIDGE", []), at(100)),
      #(event(leg, "CHANNEL_TRANSFEROR", []), at(100)),
    ])
  assert done
    == [
      [],
      [
        core.HangUpLegs([leg]),
        core.Tell(id, types.Ended(types.Transferred, t0 + 100)),
      ],
    ]
  assert !list.contains(list.flatten(done), core.HangUpCaller)
  assert core.finished(call)
}

/// A transfer that moves the agent's leg itself -- its `CHANNEL_TRANSFEREE`
/// -- leaves it alone: the transfer is carrying it somewhere.
pub fn a_leg_being_transferred_is_left_alone_test() {
  let #(call, id, leg) = connected()
  let #(_call, done) =
    script(call, [#(event(leg, "CHANNEL_TRANSFEREE", []), at(100))])
  assert last(done) == [core.Tell(id, types.Ended(types.Transferred, t0 + 100))]
}

// --- Leaving -------------------------------------------------------------------

/// Leaving: the shard told the caller is leaving, the marks and the `noop`
/// that shows they ran, and the barrier only once it has -- the barrier's
/// flush would throw away marks not yet run, and they are what a node taking
/// the caller over on their way out finds them by. The callflow is told to
/// go on only once the barrier completes, and the call is done once it says
/// it has the caller: the shard settles the member it kept then.
pub fn leaving_through_the_barrier_test() {
  let barrier = core.barrier_id(handoff("h1"))
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(noop_done(barrier), at(10)),
      #(departure_marked("h1"), at(10)),
      #(noop_done("something-else"), at(10)),
      #(noop_done(barrier), at(10)),
      #(core.Continuing("h1"), at(10)),
    ])
  assert done
    == [
      [
        core.Departing("h1", types.ExitKey),
        departing("h1", "exit_key"),
        core.Confirm(core.departure_marks_id(handoff("h1"))),
      ],
      [],
      [core.Barrier(barrier)],
      [],
      [core.Continue(handoff("h1"), "exit_key")],
      [core.HandedBack("h1")],
    ]
  assert core.finished(call)
}

/// Marks not seen to run in `marks_wait_ms` do not keep the caller: the
/// barrier goes out all the same, and that is logged.
pub fn departure_marks_never_seen_to_run_test() {
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(Tick, at_ms(10_000 + core.marks_wait_ms - 1)),
      #(Tick, at_ms(10_000 + core.marks_wait_ms)),
    ])
  assert list.drop(done, 1)
    == [
      [],
      [
        core.Log(
          "call "
          <> call_id
          <> ": the departure's marks were not seen to run; barring anyway",
        ),
        core.Barrier(core.barrier_id(handoff("h1"))),
      ],
    ]
  assert phase_name(call) == "leaving"
}

/// A barrier that never completes does not keep the caller: the callflow is
/// told to go on at `barrier_ms`.
pub fn a_barrier_that_never_completes_test() {
  let #(_call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(departure_marked("h1"), at(10)),
      #(Tick, at_ms(10_000 + core.barrier_ms)),
    ])
  assert case last(done) {
    [core.Log(_), core.Continue(h, "exit_key")] -> h == handoff("h1")
    _ -> False
  }
}

/// The callflow is asked again while it does not answer, and after
/// `continue_attempts` the caller's channel is asked whether the action took
/// them after all; with no word from it in `probe_ms`, the caller is resumed
/// at the branch elsewhere, and watched until the resume is seen taken.
pub fn a_callflow_that_never_answers_test() {
  let barrier = core.barrier_id(handoff("h1"))
  let probe = core.resume_probe_id(handoff("h1"))
  let asked = 10_000 + 3 * core.continue_ack_ms
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(departure_marked("h1"), at(10)),
      #(noop_done(barrier), at(10)),
      #(Tick, at_ms(10_000 + core.continue_ack_ms)),
      #(Tick, at_ms(10_000 + 2 * core.continue_ack_ms)),
      #(Tick, at_ms(asked)),
      #(Tick, at_ms(asked + core.probe_ms - 1)),
      #(Tick, at_ms(asked + core.probe_ms)),
    ])
  assert list.drop(done, 2) |> list.take(5)
    == [
      [core.Continue(handoff("h1"), "exit_key")],
      [core.Continue(handoff("h1"), "exit_key")],
      [core.Continue(handoff("h1"), "exit_key")],
      [core.Probe(probe)],
      [],
    ]
  assert case last(done) {
    [core.Resume(h, "exit_key"), core.Log(_)] -> h == handoff("h1")
    _ -> False
  }
  assert phase_name(call) == "resumed"
  assert !core.finished(call)
}

/// Before a resume, the caller's channel says whether the action took them
/// and only its word was lost: the action's mark of this passage is that,
/// and nothing is resumed. A channel without it is resumed at once.
pub fn a_callflow_whose_word_was_lost_test() {
  let barrier = core.barrier_id(handoff("h1"))
  let probe = core.resume_probe_id(handoff("h1"))
  let asked = 10_000 + 3 * core.continue_ack_ms
  let departing = [
    #(key("#"), at(10)),
    #(departure_marked("h1"), at(10)),
    #(noop_done(barrier), at(10)),
    #(Tick, at_ms(10_000 + core.continue_ack_ms)),
    #(Tick, at_ms(10_000 + 2 * core.continue_ack_ms)),
    #(Tick, at_ms(asked)),
  ]
  let answer = fn(marks: List(#(String, doc.Value))) {
    event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("noop")),
      #("Application-Response", doc.String(probe)),
      #("Custom-Channel-Vars", doc.object(marks)),
    ])
  }

  let #(call, done) =
    script(
      waiting(),
      list.append(departing, [
        #(answer([#("Queue-Departed", doc.String("h1"))]), at_ms(asked + 20)),
      ]),
    )
  let assert [core.Log(_), core.HandedBack("h1")] = last(done)
  assert core.finished(call)

  let #(call, done) =
    script(
      waiting(),
      list.append(departing, [#(answer([]), at_ms(asked + 20))]),
    )
  let assert [core.Resume(_, "exit_key"), core.Log(_)] = last(done)
  assert phase_name(call) == "resumed"
}

// --- Resumed -------------------------------------------------------------------

/// A caller resumed at `exit_key` after the action never answered, and the
/// monotonic millisecond the resume went out at.
fn resumed() -> #(Call, Int) {
  let barrier = core.barrier_id(handoff("h1"))
  let asked = 10_000 + 3 * core.continue_ack_ms
  let resumed_at = asked + core.probe_ms
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(departure_marked("h1"), at(10)),
      #(noop_done(barrier), at(10)),
      #(Tick, at_ms(10_000 + core.continue_ack_ms)),
      #(Tick, at_ms(10_000 + 2 * core.continue_ack_ms)),
      #(Tick, at_ms(asked)),
      #(Tick, at_ms(resumed_at)),
    ])
  let assert [core.Resume(_, "exit_key"), core.Log(_)] = last(done)
  #(call, resumed_at)
}

/// An event of the caller's channel, carrying these channel variables.
fn marked(
  name: String,
  more: List(#(String, doc.Value)),
  marks: List(#(String, doc.Value)),
) -> core.Input {
  event(
    call_id,
    name,
    list.append(more, [#("Custom-Channel-Vars", doc.object(marks))]),
  )
}

/// The completion of the probe with this `Msg-ID`, carrying these channel
/// variables.
fn probe_done(msg_id: String, marks: List(#(String, doc.Value))) -> core.Input {
  marked(
    "CHANNEL_EXECUTE_COMPLETE",
    [
      #("Application-Name", doc.String("noop")),
      #("Application-Response", doc.String(msg_id)),
    ],
    marks,
  )
}

fn departed_mark(handoff_id: String) -> List(#(String, doc.Value)) {
  [#("Queue-Departed", doc.String(handoff_id))]
}

fn is_resume(effect: core.Effect) -> Bool {
  case effect {
    core.Resume(..) -> True
    _ -> False
  }
}

/// A resume is taken when a flow has the caller: any event of their
/// channel carrying `Queue-Departed` of this passage -- the resumed flow's
/// `callcenter_departed` writes it first, and everything the flow does
/// after carries it -- ends the watch, and so do the channel's end, the
/// action's own word come late, and the caller joining a queue again. A
/// mark of another passage, an unmarked event, another passage's word and
/// the completion of a probe not out yet say nothing.
pub fn a_resume_seen_taken_ends_the_watch_test() {
  let #(call, t) = resumed()
  let probe = core.resumed_probe_id(handoff("h1"), 1)
  [
    #(
      "the mark written",
      [
        marked(
          "CHANNEL_EXECUTE_COMPLETE",
          [#("Application-Name", doc.String("set"))],
          departed_mark("h1"),
        ),
      ],
      "done",
    ),
    #(
      "the flow going on",
      [
        marked(
          "CHANNEL_EXECUTE",
          [#("Application-Name", doc.String("playback"))],
          departed_mark("h1"),
        ),
      ],
      "done",
    ),
    #(
      "the probe finding it",
      [Tick, probe_done(probe, departed_mark("h1"))],
      "done",
    ),
    #("the channel gone", [gone(call_id, "NORMAL_CLEARING")], "done"),
    #("the action's word late", [core.Continuing("h1")], "done"),
    #("the next queue", [joining("h2", settings())], "waiting"),
    #(
      "another passage's mark",
      [marked("CHANNEL_EXECUTE", [], departed_mark("h0"))],
      "resumed",
    ),
    #("no mark", [marked("CHANNEL_EXECUTE", [], [])], "resumed"),
    #("another passage's word", [core.Continuing("h0")], "resumed"),
    #("a probe not out", [probe_done(probe, [])], "resumed"),
  ]
  |> list.each(fn(row) {
    let #(what, inputs, phase) = row
    // A tick goes at `resume_ack_ms`, when the probe is due; the rest just
    // after it.
    let #(after, done) =
      script(
        call,
        list.index_map(inputs, fn(input, n) {
          #(input, at_ms(t + core.resume_ack_ms + n * 20))
        }),
      )
    let effects = list.flatten(done)
    assert #(what, phase_name(after)) == #(what, phase)
    assert #(what, list.any(effects, is_resume)) == #(what, False)
    assert #(what, list.contains(effects, core.HangUpCaller)) == #(what, False)
  })
}

/// A resume not seen taken -- its channel answering the probe without the
/// mark, or not answering it -- is published again, `resume_attempts` times
/// in all, each given `resume_ack_ms` before the probe; after the last the
/// caller is hung up rather than left in silence, and the error logged.
pub fn a_resume_nobody_takes_test() {
  let h = handoff("h1")
  let #(call, t) = resumed()
  let #(call, _t, outcomes) =
    list.fold(one_to(core.resume_attempts), #(call, t, []), fn(acc, attempt) {
      let #(call, t, outcomes) = acc
      let due = t + core.resume_ack_ms
      let probe = core.resumed_probe_id(h, attempt)
      // Odd tries find a channel with no mark; even ones, no answer at all.
      let #(no, no_at) = case attempt % 2 {
        1 -> #(probe_done(probe, []), due + 20)
        _ -> #(Tick, due + core.probe_ms)
      }
      let #(call, done) =
        script(call, [
          #(Tick, at_ms(due - 1)),
          #(Tick, at_ms(due)),
          #(no, at_ms(no_at)),
        ])
      let assert [[], [core.Probe(asked)], outcome] = done
      assert asked == probe
      #(call, no_at, list.append(outcomes, [outcome]))
    })
  let #(again, last_try) = list.split(outcomes, core.resume_attempts - 1)
  list.each(again, fn(outcome) {
    let assert [core.Resume(resumed, "exit_key"), core.Log(_)] = outcome
    assert resumed == h
  })
  let assert [[core.HangUpCaller, core.LogError(_), core.HandedBack("h1")]] =
    last_try
  assert core.finished(call)
}

/// 1 to `count`.
fn one_to(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, n) { n + 1 })
}

/// The watch sleeps until its next deadline: the probe at `resume_ack_ms`,
/// then the probe's answer at `probe_ms`.
pub fn a_resumed_call_sleeps_to_its_deadline_test() {
  let #(call, t) = resumed()
  assert core.wait_ms(call, at_ms(t)) == core.resume_ack_ms
  let #(call, _) = script(call, [#(Tick, at_ms(t + core.resume_ack_ms))])
  assert core.wait_ms(call, at_ms(t + core.resume_ack_ms)) == core.probe_ms
}

/// Only a call already resumed asks its channel whether the resume was
/// taken -- the step that publishes a resume does not -- and only one whose
/// last resume nobody took hangs its caller up with no agent, as it gives
/// the caller up.
pub fn what_a_resumed_call_may_send_test() {
  let #(call, _) = resumed()
  let assert core.Resumed(passage: passage, ..) = call.phase
  let departed = core.Departed(passage, core.ExitKey, 1, 0)
  let resuming = core.Resuming(passage, core.ExitKey, "probe", 0)
  let watching = core.Resumed(passage, core.ExitKey, 1, None, 0)
  let probing = core.Resumed(passage, core.ExitKey, 1, Some("probe"), 0)
  [
    #(departed, resuming, core.Probe("probe"), True),
    #(watching, probing, core.Probe("probe"), True),
    #(resuming, watching, core.Probe("probe"), False),
    #(departed, watching, core.Probe("probe"), False),
    #(probing, core.Done, core.HangUpCaller, True),
    #(probing, probing, core.HangUpCaller, False),
    #(resuming, core.Done, core.HangUpCaller, False),
    #(departed, core.Done, core.HangUpCaller, False),
    #(watching, watching, core.Hold(None), False),
    #(watching, watching, core.Mark([]), False),
  ]
  |> list.each(fn(row) {
    let #(before, after, effect, allowed) = row
    assert #(before, after, effect, core.allowed(before, after, effect))
      == #(before, after, effect, allowed)
  })
}

/// The clocks: `max_wait_time` leaves on `timeout`, the no-agent wait on
/// `no_agent_timeout`, both telling the shard.
pub fn the_clocks_run_out_test() {
  let #(call, done) = script(waiting(), [#(Tick, at(300))])
  assert case last(done) {
    [core.Departing("h1", types.Timeout), core.Mark(_), core.Confirm(_)] -> True
    _ -> False
  }
  assert phase_name(call) == "leaving"

  let #(call, done) =
    script(waiting(), [
      #(Positioned(Some(1), Some(1), Some(0)), at(5)),
      #(Tick, at(65)),
    ])
  assert case last(done) {
    [core.Departing("h1", types.NoAgentTimeout), core.Mark(_), core.Confirm(_)] ->
      True
    _ -> False
  }
  assert phase_name(call) == "leaving"
}

/// A queue deleted with nobody ringing: out on `no_agents`, no word to the
/// shard.
pub fn a_queue_deleted_while_waiting_test() {
  let #(_call, done) = script(waiting(), [#(core.QueueGone, at(10))])
  assert done
    == [
      [
        departing("h1", "no_agents"),
        core.Confirm(core.departure_marks_id(handoff("h1"))),
      ],
    ]
}

/// The caller hangs up while they wait: the shard is told. A ring going is
/// called off, and followed until its originate is over, and the shard is
/// told then: an agent may have answered first (`Desertion`).
pub fn the_caller_hangs_up_while_waiting_test() {
  let #(call, done) =
    script(waiting(), [#(gone(call_id, "NORMAL_CLEARING"), at(10))])
  assert done == [[core.Left(types.Hangup)]]
  assert core.finished(call)

  let #(id, endpoints) = offer(["ann"])
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(gone(call_id, "NORMAL_CLEARING"), at(11)),
    ])
  assert last(done) == [core.HangUpLegs([leg_of(id, 1)])]
  assert !core.finished(call)
  let #(call, done) =
    script(call, [#(originate_error(id, "ORIGINATOR_CANCEL"), at(11))])
  assert done == [[core.Left(types.Hangup)]]
  assert core.finished(call)
}

fn stamped(input: core.Input, us: Int) -> core.Input {
  case input {
    core.Event(event) ->
      core.Event(doc.set(event, ["Event-Timestamp"], doc.Int(us)))
    other -> other
  }
}

/// The agent answers and the caller hangs up straight after, and the
/// actor hears the hang-up first: the two are events of two channels, and
/// nothing orders them. The switch dates the answer first, so it is an
/// answered call that the caller ended, and the agent's leg is hung up.
pub fn the_caller_hangs_up_as_the_agent_answers_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(stamped(gone(call_id, "NORMAL_CLEARING"), 5_000_100), at(12)),
      #(stamped(event(leg, "CHANNEL_ANSWER", []), 5_000_040), at(12)),
      #(originate_error(id, "ORIGINATOR_CANCEL"), at(12)),
      #(gone(leg, "NORMAL_CLEARING"), at(12)),
    ])
  assert list.drop(done, 1)
    == [
      [core.HangUpLegs([leg])],
      // Answered and up: hung up again, as a leg of a ring called off is.
      [core.HangUpLegs([leg])],
      // The originate is over, and so is the ring.
      [
        core.Log(
          "call "
          <> call_id
          <> ": the caller hung up as ann answered; an answered call the caller ended",
        ),
        core.Tell(id, types.Answered("ann", leg, t0 + 12)),
        core.Tell(id, types.Ended(types.CallerHangup, t0 + 12)),
      ],
      [],
    ]
  assert core.finished(call)
}

/// An agent who picks up after the caller hung up -- the call-off still on
/// its way to the phone -- took no call: the caller left the queue.
pub fn an_answer_after_the_caller_left_is_no_call_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(stamped(gone(call_id, "NORMAL_CLEARING"), 5_000_100), at(12)),
      #(stamped(event(leg, "CHANNEL_ANSWER", []), 5_000_300), at(12)),
      #(gone(leg, "NORMAL_CLEARING"), at(12)),
      #(originate_error(id, "ORIGINATOR_CANCEL"), at(12)),
    ])
  assert last(done) == [core.Left(types.Hangup)]
  assert !list.any(list.flatten(done), fn(effect) {
    case effect {
      core.Tell(_, types.Answered(..)) -> True
      _ -> False
    }
  })
  assert core.finished(call)
}

/// A deserted ring whose originate never says it is over is decided at
/// `desertion_ms` all the same, and its legs are still followed.
pub fn a_deserted_ring_is_decided_in_time_test() {
  let #(id, endpoints) = offer(["ann"])
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(gone(call_id, "NORMAL_CLEARING"), at(11)),
      #(Tick, at_ms(11_000 + core.desertion_ms - 1)),
      #(Tick, at_ms(11_000 + core.desertion_ms)),
    ])
  assert list.drop(done, 2) == [[], [core.Left(types.Hangup)]]
  assert !core.finished(call)
  assert core.wait_ms(call, at_ms(11_000 + core.desertion_ms)) >= 1
}

/// The next queue: a caller the callflow takes on into another queue of
/// the account joins it while their last passage's handback is out, and
/// the new passage begins with its own greeting.
pub fn the_next_queue_test() {
  let barrier = core.barrier_id(handoff("h1"))
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(departure_marked("h1"), at(10)),
      #(noop_done(barrier), at(10)),
      #(joining("h2", settings()), at(11)),
    ])
  // The passage left is handed back: the callflow has the caller again.
  assert last(done) == [core.Play("welcome"), core.HandedBack("h1")]
  assert case call.phase {
    core.Waiting(passage, media.Playing(_)) -> passage.handoff.id == "h2"
    _ -> False
  }
}

// --- Announcements -----------------------------------------------------------------

/// An announcement falls due on hold and plays in its place; while a ring
/// goes it waits for the ring to be over.
pub fn announcements_test() {
  let with =
    core.Settings(
      ..settings(),
      greeting: None,
      limits: caller.Limits(..settings().limits, announce_interval_s: 30),
      announcement: announce.Settings(
        ..settings().announcement,
        media: Some("please-hold"),
      ),
    )
  let #(_call, done) =
    script(fresh(), [#(joining("h1", with), at(0)), #(Tick, at(30))])
  assert last(done) == [core.Announce([kcall.MacroPlay("please-hold")])]

  let #(id, endpoints) = offer(["ann"])
  let #(_call, done) =
    script(fresh(), [
      #(joining("h1", with), at(0)),
      #(ring(id, ["ann"], endpoints, False), at(25)),
      #(Tick, at(30)),
    ])
  assert last(done) == []
}

/// The actor never sleeps past a deadline, nor for less than a millisecond
/// or more than thirty seconds.
pub fn how_long_the_actor_sleeps_test() {
  assert core.wait_ms(fresh(), at(0)) == 30_000
  let #(id, endpoints) = offer(["ann"])
  let #(call, _) =
    script(waiting(), [#(ring(id, ["ann"], endpoints, False), at(10))])
  assert core.wait_ms(call, at(10)) == 20_000
  assert core.wait_ms(call, at(40)) == 1
}

/// The departure's marks: the passage, and the branch it leaves on.
fn departing(handoff_id: String, branch: String) -> core.Effect {
  core.Mark([
    #(core.departing_var, doc.String(handoff_id)),
    #(core.departing_branch_var, doc.String(branch)),
  ])
}

// --- The audit -------------------------------------------------------------------

/// A waiting caller is asked about every `audit_ms`; one every switch says
/// is gone has gone, whatever the events said.
pub fn a_waiting_caller_is_audited_test() {
  // Due `audit_ms` after the caller joined, at 0.
  let #(call, done) =
    call_script.audited(waiting(), [
      #(Tick, at_ms(core.audit_ms - 1)),
      #(Tick, at_ms(core.audit_ms)),
      #(core.Audited([]), at_ms(core.audit_ms + 10)),
      #(Tick, at_ms(2 * core.audit_ms)),
    ])
  assert list.map(done, list.filter(_, is_audit))
    == [[], [core.Audit([call_id])], [], [core.Audit([call_id])]]
  assert phase_name(call) == "waiting"

  let #(call, done) =
    script(call, [#(core.Audited([call_id]), at_ms(2 * core.audit_ms + 10))])
  let assert [core.Log(_), core.Left(types.Hangup)] = last(done)
  assert core.finished(call)
}

/// A connected call asks about the agent's leg too: one gone without a
/// word is the agent hanging up, and the caller is hung up after the
/// transfer wait.
pub fn a_connected_call_is_audited_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, _) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(marks_ran(leg), at(12)),
      #(parked(leg), at(12)),
      #(bridged_to(leg), at(12)),
    ])
  let #(call, done) =
    call_script.audited(call, [#(Tick, at_ms(12_000 + core.audit_ms))])
  assert list.filter(last(done), is_audit) == [core.Audit([call_id, leg])]

  let #(call, done) =
    script(call, [
      #(core.Audited([leg]), at_ms(12_000 + core.audit_ms + 10)),
      #(Tick, at_ms(12_000 + core.audit_ms + 10 + 1000)),
    ])
  let assert [core.Log(_)] = list.first(done) |> result_or([])
  assert list.contains(last(done), core.HangUpCaller)
  assert core.finished(call)
}

/// Nothing is audited while the call is on its way out, or done.
pub fn a_departing_call_is_not_audited_test() {
  let #(_call, done) =
    call_script.audited(waiting(), [
      #(key("#"), at(10)),
      #(Tick, at_ms(10_000 + core.audit_ms)),
    ])
  assert list.flat_map(done, list.filter(_, is_audit)) == []
}

fn is_audit(effect: core.Effect) -> Bool {
  case effect {
    core.Audit(_) -> True
    _ -> False
  }
}

fn result_or(result: Result(a, Nil), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

// --- Steady ----------------------------------------------------------------------

/// A call is steady -- fit to be left to the next node to hold its shard --
/// unless an originate has legs that have not shown, a bridge is on its
/// way, or a ring is being called off.
pub fn what_is_steady_test() {
  assert core.steady(fresh())
  assert core.steady(waiting())

  let #(id, endpoints) = offer(["ann", "bob"])
  let #(ringing, _) =
    script(waiting(), [#(ring(id, ["ann", "bob"], endpoints, False), at(10))])
  assert !core.steady(ringing)
  let #(one_seen, _) =
    script(ringing, [#(event(leg_of(id, 1), "CHANNEL_CREATE", []), at(10))])
  assert !core.steady(one_seen)
  let #(both_seen, _) =
    script(one_seen, [#(event(leg_of(id, 2), "CHANNEL_CREATE", []), at(10))])
  assert core.steady(both_seen)

  let #(parking, _) =
    script(both_seen, [#(event(leg_of(id, 1), "CHANNEL_ANSWER", []), at(12))])
  assert !core.steady(parking)
  let #(unmarked, _) = script(parking, [#(parked(leg_of(id, 1)), at(12))])
  assert !core.steady(unmarked)
  let #(connecting, _) = script(unmarked, [#(marks_ran(leg_of(id, 1)), at(12))])
  assert phase_name(connecting) == "connecting"
  assert !core.steady(connecting)
  let #(connected, _) =
    script(connecting, [#(bridged_to(leg_of(id, 1)), at(12))])
  assert core.steady(connected)

  // A ring called off is being called off until its originate says so.
  let #(called_off, _) = script(both_seen, [#(core.CallOff(id), at(11))])
  assert !core.steady(called_off)
  let #(over, _) =
    script(called_off, [#(originate_error(id, "ORIGINATOR_CANCEL"), at(11))])
  assert core.steady(over)
}
