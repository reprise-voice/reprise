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
  at, at_ms, bridged_to, call_id, event, fresh, gone, handoff, joining, key,
  last, leg_of, noop_done, offer, originate_error, originate_success, phase_name,
  ring, script, settings, t0, waiting,
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
/// says so the call is connected, marked, and the dispatcher hears the
/// answer, dated by the leg's.
pub fn an_answer_connects_test() {
  let #(id, endpoints) = offer(["ann", "bob"])
  let leg = leg_of(id, 2)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann", "bob"], endpoints, True), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(14)),
      #(bridged_to(leg), at(15)),
    ])
  assert done
    == [
      [
        core.Originate(id, endpoints, 15),
        core.Tell(id, types.OfferRinging(["ann", "bob"])),
      ],
      [core.Bridge(leg)],
      [
        core.Mark([
          #("Agent-ID", doc.String("bob")),
          #("Queue-Answered-Timestamp", doc.Int(t0 + 14)),
        ]),
        core.Record("bob", t0 + 14),
        core.Tell(id, types.Answered("bob", leg, t0 + 14)),
      ],
    ]
  assert phase_name(call) == "connected"
}

/// ecallmgr's `originate_resp` naming the leg is the answer when it comes
/// before the leg's own event; the leg's event after it changes nothing.
pub fn the_originate_says_who_answered_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(originate_success(id, leg), at(12)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
    ])
  assert list.drop(done, 1) == [[core.Bridge(leg)], []]
  assert phase_name(call) == "connecting"
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
      #(bridged_to(leg), at(12)),
    ])
  assert list.drop(done, 1) |> list.take(3) == [[core.Bridge(leg)], [], []]
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
        core.Left(types.ExitKey),
        departing("h1", "exit_key"),
        core.Barrier(core.barrier_id(handoff("h1"))),
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
  assert phase_name(call) == "connecting"
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
        core.Barrier(core.barrier_id(handoff("h1"))),
      ],
      [core.Tell(id, types.Failed(core.called_off_reason))],
    ]
  assert phase_name(call) == "leaving"
}

// --- Connecting ------------------------------------------------------------------

/// The agent's leg goes between the answer and the bridge: it is hung up
/// anyway, the dispatcher hears `agent_left`, and the caller -- whose hold
/// the bridge flushed -- is put back on it.
pub fn the_agent_leaves_before_the_bridge_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(gone(leg, "NORMAL_CLEARING"), at(12)),
    ])
  assert last(done)
    == [
      core.HangUpLegs([leg]),
      core.Tell(id, types.Failed(core.agent_left)),
      core.Hold(Some("support-hold")),
    ]
  assert phase_name(call) == "waiting"
}

/// A bridge that never shows is given up at `connect_ms`.
pub fn a_bridge_that_never_shows_test() {
  let #(id, endpoints) = offer(["ann"])
  let leg = leg_of(id, 1)
  let #(call, done) =
    script(waiting(), [
      #(ring(id, ["ann"], endpoints, False), at(10)),
      #(event(leg, "CHANNEL_ANSWER", []), at(12)),
      #(Tick, at_ms(12_000 + core.connect_ms - 1)),
      #(Tick, at_ms(12_000 + core.connect_ms)),
    ])
  assert list.drop(done, 2)
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
  assert last(done) == [core.Tell(id, types.Ended(types.Transferred, t0 + 100))]
}

// --- Leaving -------------------------------------------------------------------

/// Leaving: the mark and the barrier; the callflow is told to go on only
/// once the barrier completes, and the call is done once it says it has the
/// caller.
pub fn leaving_through_the_barrier_test() {
  let barrier = core.barrier_id(handoff("h1"))
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(noop_done("something-else"), at(10)),
      #(noop_done(barrier), at(10)),
      #(core.Continuing("h1"), at(10)),
    ])
  assert done
    == [
      [
        core.Left(types.ExitKey),
        departing("h1", "exit_key"),
        core.Barrier(barrier),
      ],
      [],
      [core.Continue(handoff("h1"), "exit_key")],
      [],
    ]
  assert core.finished(call)
}

/// A barrier that never completes does not keep the caller: the callflow is
/// told to go on at `barrier_ms`.
pub fn a_barrier_that_never_completes_test() {
  let #(_call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
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
/// at the branch elsewhere.
pub fn a_callflow_that_never_answers_test() {
  let barrier = core.barrier_id(handoff("h1"))
  let probe = core.resume_probe_id(handoff("h1"))
  let asked = 10_000 + 3 * core.continue_ack_ms
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(noop_done(barrier), at(10)),
      #(Tick, at_ms(10_000 + core.continue_ack_ms)),
      #(Tick, at_ms(10_000 + 2 * core.continue_ack_ms)),
      #(Tick, at_ms(asked)),
      #(Tick, at_ms(asked + core.probe_ms - 1)),
      #(Tick, at_ms(asked + core.probe_ms)),
    ])
  assert list.drop(done, 1) |> list.take(5)
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
  assert core.finished(call)
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
  let assert [core.Log(_)] = last(done)
  assert core.finished(call)

  let #(call, done) =
    script(
      waiting(),
      list.append(departing, [#(answer([]), at_ms(asked + 20))]),
    )
  let assert [core.Resume(_, "exit_key"), core.Log(_)] = last(done)
  assert core.finished(call)
}

/// The clocks: `max_wait_time` leaves on `timeout`, the no-agent wait on
/// `no_agent_timeout`, both telling the shard.
pub fn the_clocks_run_out_test() {
  let #(call, done) = script(waiting(), [#(Tick, at(300))])
  assert case last(done) {
    [core.Left(types.Timeout), core.Mark(_), core.Barrier(_)] -> True
    _ -> False
  }
  assert phase_name(call) == "leaving"

  let #(call, done) =
    script(waiting(), [
      #(Positioned(Some(1), Some(1), Some(0)), at(5)),
      #(Tick, at(65)),
    ])
  assert case last(done) {
    [core.Left(types.NoAgentTimeout), core.Mark(_), core.Barrier(_)] -> True
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
        core.Barrier(core.barrier_id(handoff("h1"))),
      ],
    ]
}

/// The caller hangs up while they wait: the shard is told, and a ring going
/// is called off -- and followed until its originate is over.
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
  assert last(done)
    == [core.HangUpLegs([leg_of(id, 1)]), core.Left(types.Hangup)]
  assert !core.finished(call)
  let #(call, _) =
    script(call, [#(originate_error(id, "ORIGINATOR_CANCEL"), at(11))])
  assert core.finished(call)
}

/// The next queue: a caller the callflow takes on into another queue of
/// the account joins it while their last passage's handback is out, and
/// the new passage begins with its own greeting.
pub fn the_next_queue_test() {
  let barrier = core.barrier_id(handoff("h1"))
  let #(call, done) =
    script(waiting(), [
      #(key("#"), at(10)),
      #(noop_done(barrier), at(10)),
      #(joining("h2", settings()), at(11)),
    ])
  assert last(done) == [core.Play("welcome")]
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

  let #(connecting, _) =
    script(both_seen, [#(event(leg_of(id, 1), "CHANNEL_ANSWER", []), at(12))])
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
