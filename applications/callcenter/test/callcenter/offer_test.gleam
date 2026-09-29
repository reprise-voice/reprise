//// What the switch's events say became of an offer, and what the agents'
//// phones are given to ring.

import callcenter/call/talk
import callcenter/offer
import callcenter/types
import gleam/dict
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/call
import kazoo/doc
import kazoo/events

const caller_leg = "9f8e7d6c-5b4a-3210"

const agent_leg = "1a2b3c4d-5e6f-7080"

fn event(members: List(#(String, doc.Value))) -> doc.Value {
  doc.object([#("Event-Category", doc.String("call_event")), ..members])
}

/// The caller leg's `CHANNEL_EXECUTE_COMPLETE` for the bridge, which is what
/// the switch says when a ring came to nothing.
fn bridge_completed(response: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_EXECUTE_COMPLETE")),
    #("Application-Name", doc.String("bridge")),
    #("Application-Response", doc.String(response)),
    #("Call-ID", doc.String(caller_leg)),
    #("Disposition", doc.String(response)),
  ])
}

//
// --- Which leg, and whose ---------------------------------------------------
//

//
// --- What the phones are given ---------------------------------------------
//

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

/// The queue's `moh`, with nothing else set.
fn holding(media: option.Option(String)) -> types.OfferSettings {
  types.OfferSettings(..settings(None, None, None), hold_media: media)
}

/// The caller was on hold music when the offer came, and goes on hearing it
/// while the phones ring: the queue's own when it has some, the account's
/// otherwise, which is the same choice the callflow action made when it held
/// them. Never a ringback tone.
pub fn the_caller_keeps_hearing_hold_music_while_the_phones_ring_test() {
  assert offer.ringback(holding(None)) == call.HoldMusic
  assert offer.ringback(holding(Some(""))) == call.HoldMusic
  assert offer.ringback(holding(Some("support-hold")))
    == call.Music("support-hold")
}

//
// --- Answering -------------------------------------------------------------
//

const queue_id = "queue-support"

/// Gregorian seconds, somewhere in 2026: the second the caller was bridged.
const answered_at = 63_800_000_100

fn ring(agents: List(String), record: Bool) -> offer.Ring {
  offer.Ring(
    account_id: "4b1f0c2d7e8a9b0c1d2e3f4051627384",
    queue_id: queue_id,
    call_id: caller_leg,
    call: doc.object([
      #("Call-ID", doc.String(caller_leg)),
      #("Control-Queue", doc.String("control.queue")),
    ]),
    agents: agents,
    settings: types.OfferSettings(
      ring_timeout_s: 15,
      cid_prefix: None,
      record: record,
      outbound_caller_id_name: None,
      outbound_caller_id_number: None,
      hold_media: None,
    ),
    id: types.OfferId(call_id: caller_leg, serial: reference.new()),
    reply_to: process.new_subject(),
    devices: None,
  )
}

/// The caller leg's bridge: which channel took them, and nothing about whose
/// channel it is.
fn bridged() -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_BRIDGE")),
    #("Call-ID", doc.String(caller_leg)),
    #("Other-Leg-Call-ID", doc.String(agent_leg)),
  ])
}

/// The agent leg's own answer, carrying the `Agent-ID` its endpoint was
/// marked with.
fn agent_answered(agent_id: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_ANSWER")),
    #("Call-ID", doc.String(agent_leg)),
    #("Other-Leg-Call-ID", doc.String(caller_leg)),
    #("Custom-Channel-Vars", doc.object([#("Agent-ID", doc.String(agent_id))])),
  ])
}

/// A phone that was rung and did not get the caller: its own cancellation,
/// carrying the `Agent-ID` its endpoint was marked with.
fn lost_the_race(agent_id: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_DESTROY")),
    #("Call-ID", doc.String("0f0e0d0c-0b0a-0908")),
    #("Other-Leg-Call-ID", doc.String(caller_leg)),
    #("Custom-Channel-Vars", doc.object([#("Agent-ID", doc.String(agent_id))])),
  ])
}

fn destroyed(call_id: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_DESTROY")),
    #("Call-ID", doc.String(call_id)),
  ])
}

/// One thing that reaches a running offer: an event at a moment, or the
/// silence that outlasted the deadline it was waiting on.
type Beat {
  Heard(at: Int, event: doc.Value)
  Silence(at: Int)
}

/// Everything an offer does for a script of events, in order: the loop in
/// `offer.run` without a mailbox or a switch underneath it.
fn played(ring: offer.Ring, beats: List(Beat)) -> List(offer.Effect) {
  playing(ring, offer.beginning(), beats, [])
}

fn playing(
  ring: offer.Ring,
  state: offer.State,
  beats: List(Beat),
  done: List(offer.Effect),
) -> List(offer.Effect) {
  case beats {
    [] -> done
    [beat, ..rest] -> {
      let move = case beat {
        Heard(at, event) -> offer.step(ring, state, event, at)
        Silence(at) -> offer.timed_out(ring, state, at)
      }
      let done = list.append(done, move.effects)
      case move.over {
        True -> done
        False -> playing(ring, move.state, rest, done)
      }
    }
  }
}

/// With several phones ringing, the caller's bridge names no agent: the
/// answer is held until the agent's own leg arrives, and then carries the
/// second the bridge happened, not the second the name turned up.
pub fn the_answer_waits_for_the_agents_leg_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], False), [
      Heard(answered_at, bridged()),
      Heard(answered_at + 1, agent_answered("agent-b")),
    ])
  assert effects
    == [
      offer.Attribute("agent-b", answered_at),
      offer.Tell(types.Answered("agent-b", agent_leg, answered_at)),
    ]
}

/// The agent's leg arriving first is the other order of the same race, and
/// answers at once.
pub fn the_agents_leg_can_arrive_first_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], False), [
      Heard(answered_at - 1, agent_answered("agent-b")),
      Heard(answered_at, bridged()),
    ])
  assert effects
    == [
      offer.Attribute("agent-b", answered_at),
      offer.Tell(types.Answered("agent-b", agent_leg, answered_at)),
    ]
}

/// One agent rung is one agent answering: there is nothing to wait for.
pub fn one_agent_answers_on_the_bridge_test() {
  let effects =
    played(ring(["agent-a"], False), [Heard(answered_at, bridged())])
  assert effects
    == [
      offer.Attribute("agent-a", answered_at),
      offer.Tell(types.Answered("agent-a", agent_leg, answered_at)),
    ]
}

/// Nobody named the leg before the wait ran out. The answer goes out anyway,
/// named `unknown`: the caller is talking to somebody and neither the call
/// nor the dispatcher's record of it is thrown away over a missing name. The
/// log line carries what is needed to find the leg that had none.
pub fn an_answer_nobody_named_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], False), [
      Heard(answered_at, bridged()),
      Silence(answered_at + 2),
      Heard(answered_at + 30, destroyed(caller_leg)),
    ])
  let assert [offer.Complain(message), ..rest] = effects
  assert string.contains(message, queue_id)
  assert string.contains(message, caller_leg)
  assert string.contains(message, agent_leg)
  assert string.contains(message, "agent-a, agent-b")
  assert rest
    == [
      offer.Attribute("unknown", answered_at),
      offer.Tell(types.Answered("unknown", agent_leg, answered_at)),
      offer.Tell(types.Ended(types.CallerHangup, answered_at + 30)),
    ]
  // The caller is bridged and talking: nothing hung them up on the way.
  assert list.contains(effects, offer.HangUp) == False
}

/// The call ending inside the wait does not lose the answer either: it is
/// sent first, and the end after it. Nothing is set or recorded on the way,
/// because the channel those commands would go to is the one that has just
/// gone away.
pub fn a_call_that_ends_inside_the_wait_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], True), [
      Heard(answered_at, bridged()),
      Heard(answered_at + 1, destroyed(agent_leg)),
      Silence(answered_at + 2),
    ])
  let assert [offer.Complain(_), ..rest] = effects
  assert rest
    == [
      offer.Tell(types.Answered("unknown", agent_leg, answered_at)),
      offer.HangUp,
      offer.Tell(types.Ended(types.Completed, answered_at + 1)),
    ]
}

/// Every phone that was rung carries an `Agent-ID`, so the one that lost the
/// race names an agent too when it is cancelled. Once the caller is through
/// to a leg, only that leg says who answered.
pub fn a_losing_phone_does_not_name_the_answer_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], False), [
      Heard(answered_at, bridged()),
      Heard(answered_at, lost_the_race("agent-a")),
      Heard(answered_at + 1, agent_answered("agent-b")),
    ])
  assert effects
    == [
      offer.Attribute("agent-b", answered_at),
      offer.Tell(types.Answered("agent-b", agent_leg, answered_at)),
    ]
}

/// A name learned from a leg the caller is then not bridged to is dropped at
/// the bridge: it belonged to a phone that lost the race a moment earlier.
pub fn a_name_from_another_leg_is_dropped_at_the_bridge_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], False), [
      Heard(answered_at - 1, lost_the_race("agent-a")),
      Heard(answered_at, bridged()),
      Heard(answered_at + 1, agent_answered("agent-b")),
    ])
  assert effects
    == [
      offer.Attribute("agent-b", answered_at),
      offer.Tell(types.Answered("agent-b", agent_leg, answered_at)),
    ]
}

/// The agent's leg turning up after the wait was given up on changes
/// nothing: the answer has gone, and there is only ever one of them.
pub fn a_name_that_came_too_late_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], False), [
      Heard(answered_at, bridged()),
      Silence(answered_at + 2),
      Heard(answered_at + 3, agent_answered("agent-b")),
      Heard(answered_at + 40, destroyed(agent_leg)),
      Silence(answered_at + 41),
    ])
  let assert [offer.Complain(_), ..rest] = effects
  assert rest
    == [
      offer.Attribute("unknown", answered_at),
      offer.Tell(types.Answered("unknown", agent_leg, answered_at)),
      offer.HangUp,
      offer.Tell(types.Ended(types.Completed, answered_at + 40)),
    ]
}

/// A second bridge for a caller who is already through is not a second
/// answer, and does not push the wait's ceiling out either.
pub fn a_second_bridge_does_not_restart_the_wait_test() {
  let ring = ring(["agent-a", "agent-b"], False)
  let waiting = offer.step(ring, offer.beginning(), bridged(), answered_at)
  let again = offer.step(ring, waiting.state, bridged(), answered_at + 1)
  assert again.effects == []
  assert again.state.pending == waiting.state.pending
}

//
// --- What the offer waits on -----------------------------------------------
//

/// A ring nobody has answered waits on the ring timeout; an answer waiting
/// for a name waits its own two seconds; a call that has been answered is
/// watched for as long as a call may run.
pub fn the_wait_for_a_name_has_its_own_ceiling_test() {
  let ring = ring(["agent-a", "agent-b"], False)
  let deadline = ms(answered_at + 15)
  assert offer.deadline_for(offer.beginning(), deadline, ms(answered_at))
    == deadline

  let waiting = offer.step(ring, offer.beginning(), bridged(), answered_at)
  let ceiling = offer.deadline_for(waiting.state, deadline, ms(answered_at))
  assert ceiling == ms(answered_at) + 2000
  assert offer.remaining_ms(ceiling, ms(answered_at)) == 2000
  assert offer.remaining_ms(ceiling, ms(answered_at) + 1500) == 500
  assert offer.remaining_ms(ceiling, ms(answered_at + 2)) == 0
  assert offer.remaining_ms(ceiling, ms(answered_at + 3)) == 0

  let answered =
    offer.step(ring, waiting.state, agent_answered("agent-b"), answered_at + 1)
  // Four hours: the longest a bridged call is watched.
  assert offer.deadline_for(answered.state, deadline, ms(answered_at + 1))
    == ms(answered_at + 1) + 14_400_000
}

/// A calendar second as the monotonic millisecond `offer.step` takes it for.
fn ms(seconds: Int) -> Int {
  seconds * 1000
}

/// The short waits are counted in milliseconds from the event that began
/// them, not in calendar seconds. Counted in seconds, the end of a bridge at
/// 900 ms into a second waited until the next second began: the first event
/// after it, 200 ms on, cut the wait to nothing, and an attended transfer's
/// caller was hung up before the re-bridge that said it was a transfer.
pub fn a_short_wait_is_as_long_whenever_it_began_test() {
  let one = ring(["agent-a"], False)
  let answered =
    offer.step_at(
      one,
      offer.beginning(),
      bridged(),
      answered_at,
      ms(answered_at) + 100,
    )
  let ended_ms = ms(answered_at + 60) + 900
  let ended =
    offer.step_at(one, answered.state, unbridged(), answered_at + 60, ended_ms)
  assert ended.effects == []

  // An event of the call's 200 ms later, in the next calendar second, is
  // not the end of the wait.
  let later =
    offer.step_at(
      one,
      ended.state,
      from(caller_leg, "CHANNEL_HOLD", []),
      answered_at + 61,
      ended_ms + 200,
    )
  assert later.over == False
  let ceiling = offer.deadline_for(later.state, 0, ended_ms + 200)
  assert ceiling == ended_ms + 1000
  assert offer.remaining_ms(ceiling, ended_ms + 200) == 800

  // The caller bridged onward 600 ms after the end: a transfer, dated at the
  // end of the agent's bridge.
  let onward =
    offer.step_at(
      one,
      later.state,
      from(caller_leg, "CHANNEL_BRIDGE", [
        #("Other-Leg-Call-ID", doc.String("transfer-target")),
      ]),
      answered_at + 61,
      ended_ms + 600,
    )
  assert onward.effects
    == [offer.Tell(types.Ended(types.Transferred, answered_at + 60))]

  // The wait for a name, and for a cancelled ring's caller to go, are the
  // same: whole waits from the moment they began.
  let bridged_ms = ms(answered_at) + 999
  let naming =
    offer.step_at(
      ring(["agent-a", "agent-b"], False),
      offer.beginning(),
      bridged(),
      answered_at,
      bridged_ms,
    )
  assert offer.deadline_for(naming.state, 0, bridged_ms + 1)
    == bridged_ms + 2000
  let cancelled =
    offer.step_at(
      one,
      offer.beginning(),
      bridge_completed("ORIGINATOR_CANCEL"),
      answered_at,
      bridged_ms,
    )
  assert offer.deadline_for(cancelled.state, 0, bridged_ms + 1)
    == bridged_ms + 2000
}

//
// --- Rings that came to nothing --------------------------------------------
//

/// A busy phone, a refused call, a ring that ran out and a bridge the switch
/// would not run at all: each ends the offer, and none of them is an answer.
pub fn what_the_switch_says_went_wrong_test() {
  let one = ring(["agent-a"], False)
  assert played(one, [Heard(answered_at, bridge_completed("USER_BUSY"))])
    == [offer.Tell(types.Busy("agent-a"))]
  assert played(one, [Heard(answered_at, bridge_completed("CALL_REJECTED"))])
    == [offer.Tell(types.Rejected("agent-a"))]
  assert played(one, [Heard(answered_at, bridge_completed("NO_ANSWER"))])
    == [offer.Tell(types.OfferNoAnswer(["agent-a"]))]

  let refused =
    doc.object([
      #("Event-Category", doc.String("error")),
      #("Application-Name", doc.String("bridge")),
      #("Call-ID", doc.String(caller_leg)),
      #("Hangup-Cause", doc.String("NO_ROUTE_DESTINATION")),
    ])
  assert played(one, [Heard(answered_at, refused)])
    == [offer.Tell(types.Failed("NO_ROUTE_DESTINATION"))]
}

/// However long the name takes, the channel is marked once and the recording
/// started once, and `Ended` follows the one `Answered`.
pub fn a_queue_call_is_recorded_once_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], True), [
      Heard(answered_at, bridged()),
      Heard(answered_at + 1, agent_answered("agent-a")),
      Heard(answered_at + 2, agent_answered("agent-a")),
      Heard(answered_at + 90, destroyed(agent_leg)),
      Silence(answered_at + 91),
    ])
  assert effects
    == [
      offer.Attribute("agent-a", answered_at),
      offer.Record("agent-a", answered_at),
      offer.Tell(types.Answered("agent-a", agent_leg, answered_at)),
      offer.HangUp,
      offer.Tell(types.Ended(types.Completed, answered_at + 90)),
    ]
}

/// One of the offer's legs appearing: the agent's phone ringing, carrying
/// the `Agent-ID` its endpoint was marked with.
fn leg_created(call_id: String, agent_id: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_CREATE")),
    #("Call-ID", doc.String(call_id)),
    #("Other-Leg-Call-ID", doc.String(caller_leg)),
    #("Custom-Channel-Vars", doc.object([#("Agent-ID", doc.String(agent_id))])),
  ])
}

/// A ring that ran out without the switch saying so is the agents' miss when
/// their phones were seen ringing: no answer was held, so the silence is the
/// end of the offer.
pub fn a_ring_that_ran_out_is_a_no_answer_test() {
  let agents = ["agent-a", "agent-b"]
  let effects =
    played(ring(agents, False), [
      Heard(answered_at, leg_created(agent_leg, "agent-a")),
      Heard(answered_at, leg_created("0f0e0d0c-0b0a-0908", "agent-b")),
      Silence(answered_at + 20),
    ])
  assert effects == [offer.Tell(types.OfferNoAnswer(agents))]
}

/// The same silence with no leg of the offer ever seen is not a miss: there
/// is no evidence anything rang, so nobody is charged for not answering.
/// It is a failure, which leaves the agents alone for a moment and offers the
/// caller again.
pub fn a_ring_nobody_saw_is_not_a_miss_test() {
  let agents = ["agent-a", "agent-b"]
  assert played(ring(agents, False), [Silence(answered_at + 20)])
    == [offer.Tell(types.Failed(offer.nothing_rang))]

  // A channel of somebody who was not offered this caller is not one of the
  // offer's legs.
  let stranger =
    event([
      #("Event-Name", doc.String("CHANNEL_CREATE")),
      #("Call-ID", doc.String(agent_leg)),
      #("Other-Leg-Call-ID", doc.String(caller_leg)),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Owner-ID", doc.String("somebody-else"))]),
      ),
    ])
  assert played(ring(agents, False), [
      Heard(answered_at, stranger),
      Silence(answered_at + 20),
    ])
    == [offer.Tell(types.Failed(offer.nothing_rang))]
}

/// An offer that cannot watch its call's events rings nobody and says so at
/// once: it could not tell an answer from a ring that ran out, and would
/// otherwise report a guess at the end of the ring timeout. Outside a release
/// there are no call events to watch, which is this case.
pub fn an_offer_that_cannot_watch_fails_at_once_test() {
  let subject = process.new_subject()
  let ring = offer.Ring(..ring(["agent-a"], False), reply_to: subject)
  let assert Ok(_pid) = offer.start_ring(ring)
  assert process.receive(subject, 1000)
    == Ok(#(ring.id, types.Failed(offer.no_events)))
  assert process.receive(subject, 100) == Error(Nil)
}

// --- The dispatcher behind the offer -----------------------------------------

/// The dispatcher that asked for an offer has gone, and whoever takes the
/// caller over watches the call with a takeover of its own. The offer goes
/// without touching it -- no hang-up, no reply, nothing on the channel --
/// whether it was ringing, talking, or waiting to see a transfer.
pub fn an_offer_whose_dispatcher_has_gone_leaves_the_call_alone_test() {
  let one = ring(["agent-a"], False)
  let talking = offer.step(one, offer.beginning(), bridged(), answered_at)
  let closing =
    offer.step(one, talking.state, unbridged(), answered_at + 60).state
  list.each([offer.beginning(), talking.state, closing], fn(state) {
    let move =
      offer.step(one, state, offer.dispatcher_gone_event(), answered_at + 61)
    assert move.over
    assert list.all(move.effects, fn(effect) {
      case effect {
        offer.Complain(_) -> True
        _touches_the_call_or_replies -> False
      }
    })
  })
}

fn a_process() -> process.Pid {
  process.spawn_unlinked(fn() { process.sleep_forever() })
}

/// The guard tells the offer when its dispatcher goes.
pub fn the_guard_tells_the_offer_its_dispatcher_went_test() {
  let told = process.new_subject()
  let dispatcher = a_process()
  let an_offer = a_process()
  let _guard =
    offer.guard(dispatcher, an_offer, fn() { process.send(told, Nil) })
  process.kill(dispatcher)
  assert process.receive(told, 1000) == Ok(Nil)
  process.kill(an_offer)
}

/// And goes with the offer, telling nobody: one guard per offer, never
/// outliving it.
pub fn the_guard_goes_with_its_offer_test() {
  let told = process.new_subject()
  let dispatcher = a_process()
  let an_offer = a_process()
  let guard =
    offer.guard(dispatcher, an_offer, fn() { process.send(told, Nil) })
  process.kill(an_offer)
  assert gone(guard, 100)
  assert process.receive(told, 50) == Error(Nil)
  process.kill(dispatcher)
}

/// A dispatcher already gone is said at once, and nothing is started.
pub fn a_dispatcher_already_gone_is_no_dispatcher_test() {
  let owner = process.new_subject()
  let _dispatcher =
    process.spawn_unlinked(fn() { process.send(owner, process.new_subject()) })
  let assert Ok(reply_to) = process.receive(owner, 1000)
  let assert Ok(pid) = process.subject_owner(reply_to)
  assert gone(pid, 100)
  assert !offer.guard_dispatcher(reply_to)
  // The offer's own subject has a live owner: this process.
  assert offer.guard_dispatcher(process.new_subject())
}

fn gone(pid: process.Pid, tries: Int) -> Bool {
  case process.is_alive(pid), tries {
    False, _ -> True
    True, 0 -> False
    True, _ -> {
      process.sleep(10)
      gone(pid, tries - 1)
    }
  }
}

/// A caller who hangs up while the phones are ringing is not an answer, and
/// not a failure either: they have left the queue.
pub fn a_caller_who_left_before_the_bridge_test() {
  let effects =
    played(ring(["agent-a", "agent-b"], False), [
      Heard(answered_at, destroyed(caller_leg)),
    ])
  assert effects == [offer.Tell(types.CallerGone)]
}

/// The switch ends the caller's bridge with `ORIGINATOR_CANCEL` before the
/// caller's destroy arrives. The two together are the caller leaving, and
/// neither is the agents' miss.
pub fn a_caller_hanging_up_during_the_ring_is_not_a_miss_test() {
  let one = ring(["agent-a"], False)
  let effects =
    played(one, [
      Heard(answered_at, bridge_completed("ORIGINATOR_CANCEL")),
      Heard(answered_at, destroyed(caller_leg)),
    ])
  assert effects == [offer.Tell(types.CallerGone)]

  // And while it waits for the destroy, it waits a moment and no longer.
  let cancelled =
    offer.step(
      one,
      offer.beginning(),
      bridge_completed("ORIGINATOR_CANCEL"),
      answered_at,
    )
  assert cancelled.effects == []
  assert cancelled.over == False
  assert offer.deadline_for(
      cancelled.state,
      ms(answered_at + 20),
      ms(answered_at),
    )
    == ms(answered_at + 2)
}

/// The ring was called off and the caller is still there: the callflow
/// action cancelled it because the caller is leaving on an exit key or a
/// timeout, and has told the dispatcher so. Nobody missed anything.
pub fn a_ring_called_off_by_the_action_is_not_a_miss_test() {
  let effects =
    played(ring(["agent-a"], False), [
      Heard(answered_at, bridge_completed("ORIGINATOR_CANCEL")),
      Silence(answered_at + 2),
    ])
  assert effects == [offer.Tell(types.Failed(talk.originator_cancel))]
}

//
// --- The end of an answered call, and transfers ------------------------------
//

/// An answered call, one agent: the effects of getting there.
fn answered_call() -> List(Beat) {
  [Heard(answered_at, bridged())]
}

fn answering_effects() -> List(offer.Effect) {
  [
    offer.Attribute("agent-a", answered_at),
    offer.Tell(types.Answered("agent-a", agent_leg, answered_at)),
  ]
}

fn from(call_id: String, name: String, more: List(#(String, doc.Value))) {
  event([
    #("Event-Name", doc.String(name)),
    #("Call-ID", doc.String(call_id)),
    ..more
  ])
}

fn unbridged() -> doc.Value {
  from(caller_leg, "CHANNEL_UNBRIDGE", [
    #("Other-Leg-Call-ID", doc.String(agent_leg)),
  ])
}

/// The agent hangs up: the caller is unbridged, the agent's leg goes, and
/// nothing says it was a transfer. The caller is hung up once the moment
/// allowed for a transfer has passed, and the call ended when the bridge
/// did.
pub fn an_agent_hanging_up_ends_the_call_test() {
  let one = ring(["agent-a"], False)
  let effects =
    played(
      one,
      list.append(answered_call(), [
        Heard(answered_at + 60, unbridged()),
        Heard(answered_at + 60, destroyed(agent_leg)),
        Silence(answered_at + 61),
      ]),
    )
  assert effects
    == list.append(answering_effects(), [
      offer.HangUp,
      offer.Tell(types.Ended(types.Completed, answered_at + 60)),
    ])

  // The moment is one second from the end of the bridge.
  let answered = offer.step(one, offer.beginning(), bridged(), answered_at)
  let ended = offer.step(one, answered.state, unbridged(), answered_at + 60)
  assert ended.effects == []
  assert offer.deadline_for(
      ended.state,
      ms(answered_at + 15),
      ms(answered_at + 60),
    )
    == ms(answered_at + 61)
}

/// A blind transfer from the agent's phone: the switch says so on both
/// legs, and the caller -- on their way to the transfer's target -- is not
/// hung up. The offer's part is over.
pub fn a_blind_transfer_does_not_hang_the_caller_up_test() {
  let effects =
    played(
      ring(["agent-a"], False),
      list.append(answered_call(), [
        Heard(
          answered_at + 60,
          from(agent_leg, "CHANNEL_TRANSFEROR", [
            #("Other-Leg-Call-ID", doc.String(caller_leg)),
            #("Transfer-Type", doc.String("blind")),
          ]),
        ),
        Heard(answered_at + 60, from(caller_leg, "CHANNEL_TRANSFEREE", [])),
        Heard(answered_at + 60, unbridged()),
      ]),
    )
  assert effects
    == list.append(answering_effects(), [
      offer.Tell(types.Ended(types.Transferred, answered_at + 60)),
    ])
}

/// The transfer events can arrive after the unbridge they come before on the
/// switch: the unbridge waits for them.
pub fn a_transfer_heard_after_the_unbridge_test() {
  let effects =
    played(
      ring(["agent-a"], False),
      list.append(answered_call(), [
        Heard(answered_at + 60, unbridged()),
        Heard(answered_at + 60, from(caller_leg, "CHANNEL_TRANSFEREE", [])),
      ]),
    )
  assert effects
    == list.append(answering_effects(), [
      offer.Tell(types.Ended(types.Transferred, answered_at + 60)),
    ])
}

/// The agent's leg going with a transfer as its cause is a transfer on its
/// own: `mod_com_kazoo` reports a leg that sent a `REFER` that way.
pub fn a_leg_that_ended_by_transferring_test() {
  list.each(["BLIND_TRANSFER", "ATTENDED_TRANSFER"], fn(cause) {
    let effects =
      played(
        ring(["agent-a"], False),
        list.append(answered_call(), [
          Heard(answered_at + 60, unbridged()),
          Heard(
            answered_at + 60,
            from(agent_leg, "CHANNEL_DESTROY", [
              #("Hangup-Cause", doc.String(cause)),
            ]),
          ),
        ]),
      )
    assert effects
      == list.append(answering_effects(), [
        offer.Tell(types.Ended(types.Transferred, answered_at + 60)),
      ])
  })
}

/// An attended transfer puts the caller through to its target: the caller
/// is bridged again, to a leg that is not the agent's.
pub fn the_caller_bridged_to_somebody_else_is_a_transfer_test() {
  let effects =
    played(
      ring(["agent-a"], False),
      list.append(answered_call(), [
        Heard(answered_at + 60, unbridged()),
        Heard(
          answered_at + 60,
          from(caller_leg, "CHANNEL_BRIDGE", [
            #("Other-Leg-Call-ID", doc.String("5e5e5e5e-target")),
          ]),
        ),
      ]),
    )
  assert effects
    == list.append(answering_effects(), [
      offer.Tell(types.Ended(types.Transferred, answered_at + 60)),
    ])
}

/// The caller hanging up while the offer waits to see whether it was a
/// transfer: nobody is left to hang up, and the call ended when the bridge
/// did.
pub fn a_caller_gone_while_the_end_is_read_test() {
  let effects =
    played(
      ring(["agent-a"], False),
      list.append(answered_call(), [
        Heard(answered_at + 60, unbridged()),
        Heard(answered_at + 60, destroyed(caller_leg)),
      ]),
    )
  assert effects
    == list.append(answering_effects(), [
      offer.Tell(types.Ended(types.Completed, answered_at + 60)),
    ])
}

//
// --- The legs the offer names -------------------------------------------------
//

/// The caller's bridge names a leg the offer named, so it names the agent:
/// the answer goes out at once, with nothing to wait for.
pub fn the_bridge_names_the_agent_at_once_test() {
  let one = ring(["agent-a", "agent-b"], False)
  let legs = dict.from_list([#("c0ffee-1", "agent-a"), #(agent_leg, "agent-b")])
  let move = offer.step(one, offer.ringing(legs), bridged(), answered_at)
  assert move.effects
    == [
      offer.Attribute("agent-b", answered_at),
      offer.Tell(types.Answered("agent-b", agent_leg, answered_at)),
    ]
  assert move.state.pending == None
  // And the loser's cancellation, carrying its own name, changes nothing.
  let after = offer.step(one, move.state, lost_the_race("agent-a"), answered_at)
  assert after.effects == []
}

/// A leg the offer did not name -- a forwarded device bridging through a
/// channel of its own -- still waits for its own events to say whose it is.
pub fn a_leg_nobody_named_still_waits_for_its_name_test() {
  let one = ring(["agent-a", "agent-b"], False)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let waiting = offer.step(one, offer.ringing(legs), bridged(), answered_at)
  assert waiting.effects == []
  let named =
    offer.step(one, waiting.state, agent_answered("agent-b"), answered_at + 1)
  assert named.effects
    == [
      offer.Attribute("agent-b", answered_at),
      offer.Tell(types.Answered("agent-b", agent_leg, answered_at)),
    ]
}

/// A named leg ringing is a leg seen, whatever its events carry.
pub fn a_named_leg_is_a_ring_seen_test() {
  let one = ring(["agent-a"], False)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let created =
    event([
      #("Event-Name", doc.String("CHANNEL_CREATE")),
      #("Call-ID", doc.String("c0ffee-1")),
    ])
  let seen = offer.step(one, offer.ringing(legs), created, answered_at)
  assert offer.timed_out(one, seen.state, answered_at + 20).effects
    == [offer.Tell(types.OfferNoAnswer(["agent-a"]))]
}

/// What the offer relays out of the account's events: the caller's, those
/// naming the caller as their other leg, and its own named legs' from the
/// start -- and nothing of anybody else's.
pub fn the_offer_hears_its_own_legs_test() {
  let of = fn(call_id, other) {
    event([
      #("Call-ID", doc.String(call_id)),
      #("Other-Leg-Call-ID", doc.String(other)),
    ])
  }
  assert offer.relays(caller_leg, "c0ffee", of(caller_leg, ""))
  assert offer.relays(caller_leg, "c0ffee", of(agent_leg, caller_leg))
  assert offer.relays(caller_leg, "c0ffee", of("c0ffee-2", ""))
  assert !offer.relays(caller_leg, "c0ffee", of("c0ffee2-1", ""))
  assert !offer.relays(caller_leg, "c0ffee", of(agent_leg, "somebody"))
}

/// The bus relays exactly what `relays` keeps: the offer's interest is the
/// same rule, decided before the event is made into anything.
pub fn the_bus_relays_what_the_offer_keeps_test() {
  let interest = offer.interest("acct", caller_leg, "c0ffee")
  let cases = [
    #(caller_leg, ""),
    #(agent_leg, caller_leg),
    #("c0ffee-2", ""),
    #("c0ffee2-1", ""),
    #(agent_leg, "somebody"),
    #("", caller_leg),
    #("", ""),
  ]
  list.each(cases, fn(leg) {
    let event =
      event([
        #("Event-Name", doc.String("CHANNEL_BRIDGE")),
        #("Call-ID", doc.String(leg.0)),
        #("Other-Leg-Call-ID", doc.String(leg.1)),
      ])
    assert events.wants(interest, event)
      == offer.relays(caller_leg, "c0ffee", event)
  })
  // Every name: an offer learns whose leg rang from any of its events.
  assert interest.events == []
  assert interest.account == "acct"
}

//
// --- A ring called off ------------------------------------------------------
//

/// The dispatcher called the ring off after the bridge went out, and left
/// the unbridge to the offer: the caller left before the dispatcher knew the
/// ring was out. The offer unbridges at once.
pub fn a_ring_called_off_is_unbridged_by_the_offer_test() {
  let one = ring(["agent-a"], False)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let at = ms(answered_at)
  let stopped =
    offer.step_at(
      one,
      offer.ringing(legs),
      offer.called_off_event(unbridged: False),
      answered_at,
      at,
    )
  assert stopped.effects == [offer.Unbridge]
  assert stopped.over == False

  // The unbridge took: the bridge ends with the originator's cancel, and
  // nothing more is sent however late its legs are heard of.
  let ended =
    offer.step_at(
      one,
      stopped.state,
      bridge_completed("ORIGINATOR_CANCEL"),
      answered_at,
      at + 200,
    )
  let late =
    offer.step_at(
      one,
      ended.state,
      leg_created("c0ffee-1", "agent-a"),
      answered_at + 2,
      at + 1500,
    )
  assert ended.effects == []
  assert late.effects == []
}

/// The unbridge landed before the bridge ran -- it parked a channel with no
/// bridge on it -- and then the bridge rang. The offer, which had seen none
/// of its legs when the ring was called off, sees one ringing a second
/// later with the bridge not ended, and unbridges once more; once.
pub fn a_call_off_that_missed_the_bridge_is_sent_again_test() {
  let one = ring(["agent-a"], False)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let at = ms(answered_at)
  let stopped =
    offer.step_at(
      one,
      offer.ringing(legs),
      offer.called_off_event(unbridged: True),
      answered_at,
      at,
    )
  // The dispatcher unbridges this one: nothing from the offer yet, but the
  // check is due in a second.
  assert stopped.effects == []
  assert offer.deadline_for(stopped.state, at + 20_000, at) == at + 1000

  // A leg is heard of inside the second: not yet.
  let early =
    offer.step_at(
      one,
      stopped.state,
      leg_created("c0ffee-1", "agent-a"),
      answered_at,
      at + 300,
    )
  assert early.effects == []

  // The second is up and the bridge has not ended: called off again.
  let again =
    offer.silence(one, early.state, at + 20_000, answered_at + 1, at + 1000)
  assert again.effects == [offer.Unbridge]
  assert again.over == False
  // And only once.
  let later =
    offer.step_at(
      one,
      again.state,
      leg_created("c0ffee-1", "agent-a"),
      answered_at + 2,
      at + 2000,
    )
  assert later.effects == []
  assert offer.deadline_for(again.state, at + 20_000, at + 1000) == at + 20_000
}

/// A leg first heard of after the second is up is the same ring the
/// unbridge missed, called off on the event itself. Before any leg is heard
/// of there is nothing to call off, and the offer goes on waiting for the
/// ring's own end.
pub fn a_leg_heard_after_the_check_is_called_off_test() {
  let one = ring(["agent-a"], False)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let at = ms(answered_at)
  let stopped =
    offer.step_at(
      one,
      offer.ringing(legs),
      offer.called_off_event(unbridged: True),
      answered_at,
      at,
    )
  let quiet =
    offer.silence(one, stopped.state, at + 20_000, answered_at + 1, at + 1000)
  assert quiet.effects == []
  assert quiet.over == False
  assert offer.deadline_for(quiet.state, at + 20_000, at + 1000) == at + 20_000

  let rung =
    offer.step_at(
      one,
      quiet.state,
      leg_created("c0ffee-1", "agent-a"),
      answered_at + 1,
      at + 1200,
    )
  assert rung.effects == [offer.Unbridge]

  // The ring's own deadline is still the end of the offer.
  let out =
    offer.silence(one, rung.state, at + 20_000, answered_at + 20, at + 20_000)
  assert out.over
}

/// A ring whose legs were already ringing when it was called off was running
/// when the unbridge went out, and the unbridge ends it: no check follows.
pub fn a_running_ring_is_left_to_the_unbridge_test() {
  let one = ring(["agent-a"], False)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let at = ms(answered_at)
  let seen =
    offer.step_at(
      one,
      offer.ringing(legs),
      leg_created("c0ffee-1", "agent-a"),
      answered_at,
      at,
    )
  let stopped =
    offer.step_at(
      one,
      seen.state,
      offer.called_off_event(unbridged: True),
      answered_at,
      at + 100,
    )
  let later =
    offer.step_at(
      one,
      stopped.state,
      leg_created("c0ffee-1", "agent-a"),
      answered_at + 2,
      at + 2000,
    )
  assert stopped.effects == []
  assert later.effects == []
}

//
// --- Only the offer's own legs answer ----------------------------------------
//

/// A leg of whatever the caller's callflow did next: an operator, a ring
/// group.
const operator_leg = "0p3r4t0r-0000-0001"

fn bridged_to(leg: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_BRIDGE")),
    #("Call-ID", doc.String(caller_leg)),
    #("Other-Leg-Call-ID", doc.String(leg)),
  ])
}

/// The caller pressed 0 while the phones rang: the action called the ring
/// off, which ends with `ORIGINATOR_CANCEL`, and within the two seconds the
/// offer waits for the caller's destroy the operator answered. That bridge
/// is not the queue's answer: the lone agent rung is not marked on the
/// caller's channel, no queue recording of the operator's call is started,
/// and the dispatcher hears the ring was called off, not answered.
pub fn the_callers_next_bridge_is_not_the_answer_test() {
  let one = ring(["agent-a"], True)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let cancelled =
    offer.step(
      one,
      offer.ringing(legs),
      bridge_completed("ORIGINATOR_CANCEL"),
      answered_at,
    )
  let next = offer.step(one, cancelled.state, bridged_to(operator_leg), 0)
  assert next.effects == [offer.Tell(types.Failed(talk.originator_cancel))]
  assert next.over
}

/// The dispatcher called the ring off -- the caller left the queue -- and
/// the caller is then put through to somebody the offer did not ring: not
/// its answer. Nor is one of its own legs answering after the call-off: the
/// unbridge on its way cuts it. When none of the ring had been seen as it
/// was called off, the unbridge landed before the bridge ran and nothing is
/// on its way to end this one, and the offer unbridges it itself.
pub fn a_ring_called_off_is_answered_by_no_leg_test() {
  let one = ring(["agent-a"], True)
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  let stopped =
    offer.step(
      one,
      offer.ringing(legs),
      offer.called_off_event(unbridged: True),
      answered_at,
    )
  let elsewhere =
    offer.step(one, stopped.state, bridged_to(operator_leg), answered_at)
  assert elsewhere.effects == [offer.Tell(types.Failed(offer.called_off))]
  assert elsewhere.over

  let ours = offer.step(one, stopped.state, bridged_to("c0ffee-1"), answered_at)
  assert ours.effects
    == [offer.Unbridge, offer.Tell(types.Failed(offer.called_off))]
  assert ours.over

  // A ring already seen when it was called off was running, and the
  // unbridge sent with the call-off ends it.
  let stopped =
    offer.step(
      one,
      rung(one),
      offer.called_off_event(unbridged: True),
      answered_at,
    )
  let ours = offer.step(one, stopped.state, bridged_to("c0ffee-1"), answered_at)
  assert ours.effects == [offer.Tell(types.Failed(offer.called_off))]
  assert ours.over
}

//
// --- An answer the call-off crosses ------------------------------------------
//

/// Everything an offer does but say in the log.
fn done(effects: List(offer.Effect)) -> List(offer.Effect) {
  list.filter(effects, fn(effect) {
    case effect {
      offer.Complain(_) -> False
      _ -> True
    }
  })
}

/// `played` from a state of the offer's.
fn played_from(
  ring: offer.Ring,
  state: offer.State,
  beats: List(Beat),
) -> List(offer.Effect) {
  playing(ring, state, beats, [])
}

/// A ring out and seen: the state a call-off finds it in when the caller
/// presses an exit key, the agent is released or the queue is deleted.
fn rung(one: offer.Ring) -> offer.State {
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  offer.step(one, offer.ringing(legs), leg_created("c0ffee-1", "agent-a"), 0).state
}

fn caller_event(name: String) -> doc.Value {
  from(caller_leg, name, [#("Other-Leg-Call-ID", doc.String("c0ffee-1"))])
}

/// What the switch says once the unbridge has parked the caller in the
/// middle of an answered bridge: the caller is unbridged, the agent's leg
/// is hung up behind it with `NORMAL_CLEARING`, and the bridge command
/// completes. Then nothing, for longer than any wait the offer keeps.
fn parked(at: Int) -> List(Beat) {
  [
    Heard(at, caller_event("CHANNEL_UNBRIDGE")),
    Heard(
      at,
      from("c0ffee-1", "CHANNEL_DESTROY", [
        #("Other-Leg-Call-ID", doc.String(caller_leg)),
        #("Hangup-Cause", doc.String("NORMAL_CLEARING")),
      ]),
    ),
    Heard(at, bridge_completed("SUCCESS")),
    Silence(at + 1),
    Silence(at + 2),
  ]
}

fn unbridge_if_ours(unbridged: Bool) -> List(offer.Effect) {
  case unbridged {
    True -> []
    False -> [offer.Unbridge]
  }
}

/// The call-off first, the answer after it. The dispatcher unbridges
/// (`Unbridged: true`) for a released agent or a deleted queue, and for a
/// caller leaving -- exit, timeout -- whose ring it knew was out; it leaves
/// the unbridge to the offer (`false`) for a caller who left before it knew.
/// Either way the answer is not one: nothing is marked, recorded or told,
/// and the park that follows is not read as the end of a call -- the caller
/// is never hung up.
pub fn an_answer_after_the_call_off_is_not_taken_test() {
  let one = ring(["agent-a"], True)
  list.each([True, False], fn(unbridged) {
    let effects =
      played_from(
        one,
        rung(one),
        list.append(
          [
            Heard(answered_at, offer.called_off_event(unbridged: unbridged)),
            Heard(answered_at, bridged_to("c0ffee-1")),
          ],
          parked(answered_at),
        ),
      )
    assert done(effects)
      == list.append(unbridge_if_ours(unbridged), [
        offer.Tell(types.Failed(offer.called_off)),
      ])
    assert list.contains(effects, offer.HangUp) == False
  })
}

/// The answer first, the call-off after it: the offer had marked the
/// caller's channel, started the recording and told the dispatcher, and the
/// dispatcher's or the action's unbridge was already on its way. The
/// call-off wins. The mark and the recording are taken back, the offer ends
/// with `Failed(called_off)` -- which the dispatcher reads as the answer not
/// standing -- and nothing it does afterwards touches the caller: the park
/// that ends the bridge is not a completed call, and there is no `HangUp`
/// and no `Ended`.
pub fn a_call_off_after_the_answer_takes_it_back_test() {
  let one = ring(["agent-a"], True)
  let answering = [
    offer.Attribute("agent-a", answered_at),
    offer.Record("agent-a", answered_at),
    offer.Tell(types.Answered("agent-a", "c0ffee-1", answered_at)),
  ]
  let taken_back = [
    offer.Unmark,
    offer.StopRecording(answered_at),
    offer.Tell(types.Failed(offer.called_off)),
  ]
  list.each([True, False], fn(unbridged) {
    let effects =
      played_from(
        one,
        rung(one),
        list.append(
          [
            Heard(answered_at, bridged_to("c0ffee-1")),
            Heard(answered_at + 1, offer.called_off_event(unbridged: unbridged)),
          ],
          parked(answered_at + 1),
        ),
      )
    // Left to the offer, the unbridge is the offer's to send: an answered
    // bridge nobody ends is a caller talking to an agent the queue let go.
    assert done(effects)
      == list.flatten([answering, unbridge_if_ours(unbridged), taken_back])
    assert list.contains(effects, offer.HangUp) == False
  })

  // The park read before the call-off: the bridge is over already, so
  // nothing is unbridged whoever was to, and the caller is not hung up.
  list.each([True, False], fn(unbridged) {
    let effects =
      played_from(one, rung(one), [
        Heard(answered_at, bridged_to("c0ffee-1")),
        Heard(answered_at + 1, caller_event("CHANNEL_UNBRIDGE")),
        Heard(answered_at + 1, offer.called_off_event(unbridged: unbridged)),
        Silence(answered_at + 2),
      ])
    assert done(effects) == list.append(answering, taken_back)
  })

  // A queue that does not record has no recording to stop.
  let unrecorded = ring(["agent-a"], False)
  assert done(
      played_from(unrecorded, rung(unrecorded), [
        Heard(answered_at, bridged_to("c0ffee-1")),
        Heard(answered_at + 1, offer.called_off_event(unbridged: True)),
      ]),
    )
    == [
      offer.Attribute("agent-a", answered_at),
      offer.Tell(types.Answered("agent-a", "c0ffee-1", answered_at)),
      offer.Unmark,
      offer.Tell(types.Failed(offer.called_off)),
    ]
}

/// An answer still waiting for its agent's name when the call-off comes was
/// never told, and goes with the ring: no mark, no recording, no answer --
/// only the unbridge, when it is the offer's to send.
pub fn an_answer_waiting_for_a_name_goes_with_the_call_off_test() {
  let two = ring(["agent-a", "agent-b"], True)
  list.each([True, False], fn(unbridged) {
    let effects =
      played(
        two,
        list.append(
          [
            Heard(answered_at, bridged()),
            Heard(answered_at, offer.called_off_event(unbridged: unbridged)),
            Heard(answered_at, agent_answered("agent-b")),
          ],
          parked(answered_at),
        ),
      )
    assert done(effects)
      == list.append(unbridge_if_ours(unbridged), [
        offer.Tell(types.Failed(offer.called_off)),
      ])
  })
}

/// With no call-off the end of an answered bridge is still the end of the
/// call, and the caller goes with the agent.
pub fn without_a_call_off_the_end_of_the_bridge_hangs_up_test() {
  let one = ring(["agent-a"], False)
  let effects =
    played_from(
      one,
      rung(one),
      list.append(
        [Heard(answered_at, bridged_to("c0ffee-1"))],
        parked(answered_at + 60),
      ),
    )
  assert effects
    == [
      offer.Attribute("agent-a", answered_at),
      offer.Tell(types.Answered("agent-a", "c0ffee-1", answered_at)),
      offer.HangUp,
      offer.Tell(types.Ended(types.Completed, answered_at + 60)),
    ]
}

/// While its own ring is the thing the caller's channel is running, a leg
/// the offer did not name is still its forwarded device's, named the old
/// way: that is unchanged.
pub fn a_running_ring_still_takes_a_leg_it_did_not_name_test() {
  let legs = dict.from_list([#("c0ffee-1", "agent-a")])
  assert offer.is_own_bridge(offer.ringing(legs), bridged_to(agent_leg))
  assert offer.is_own_bridge(offer.ringing(legs), bridged_to("c0ffee-1"))
}

// --- A ring called off, and where the offer's own unbridge goes -------------

fn caller_on(control_queue: String) -> call.Call {
  call.from_value(
    doc.object([
      #("Call-ID", doc.String(caller_leg)),
      #("Control-Queue", doc.String(control_queue)),
    ]),
  )
}

/// A call-off names the control queue of the caller's callflow now, and the
/// offer's own unbridge goes there from then on: the one its request named
/// may be of a callflow that died and was run again while the phones rang.
pub fn a_call_off_moves_the_offers_commands_to_the_callers_control_queue_test() {
  let caller =
    offer.caller_now(
      caller_on("cq-dead"),
      offer.called_off_through(unbridged: False, control_queue: Some("cq-now")),
    )
  assert call.control_queue(caller) == Some("cq-now")
}

/// A call-off that names none, and any other event, leave it where it was.
pub fn only_a_call_off_naming_a_control_queue_moves_it_test() {
  let caller = caller_on("cq-first")
  assert offer.caller_now(caller, offer.called_off_event(unbridged: False))
    |> call.control_queue
    == Some("cq-first")
  assert offer.caller_now(
      caller,
      doc.object([
        #("Call-ID", doc.String(caller_leg)),
        #("Control-Queue", doc.String("cq-other")),
      ]),
    )
    |> call.control_queue
    == Some("cq-first")
}

/// A call-off naming a control queue is still a call-off, and the unbridge
/// it leaves to the offer is still asked for.
pub fn a_call_off_naming_a_control_queue_is_a_call_off_test() {
  let event =
    offer.called_off_through(unbridged: False, control_queue: Some("cq-now"))
  assert offer.is_called_off(event)
  let move = offer.step(ring(["agent-a"], False), offer.beginning(), event, 100)
  assert move.effects == [offer.Unbridge]
}
