//// Watching a caller the node that was dispatching for them did not live to
//// finish: what the switch's events mean when nothing rang from here.

import callcenter/member
import callcenter/offer
import callcenter/takeover
import callcenter/types
import gleam/erlang/process
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/doc
import kazoo/events
import kazoo/listener
import support/cluster
import support/fake_watch

const caller_leg = "9f8e7d6c-5b4a-3210"

const agent_leg = "1a2b3c4d-5e6f-7080"

const offered_at = 63_800_000_100

/// The offer on the record began at `offered_at` and had twenty seconds and
/// a grace of five to run.
const deadline = 63_800_000_125

fn watching(agents: List(String)) -> takeover.Request {
  takeover.Request(
    member: cluster.member(caller_leg, "support", 0, offered_at - 30),
    agents: agents,
    offered_at: offered_at,
    deadline: deadline,
    record: False,
    answered: None,
    leg_prefix: None,
    id: types.OfferId(call_id: caller_leg, serial: reference.new()),
    reply_to: process.new_subject(),
  )
}

/// The same, in a queue that records its calls.
fn recorded(agents: List(String)) -> takeover.Request {
  takeover.Request(..watching(agents), record: True)
}

fn adopted() -> takeover.Request {
  takeover.Request(
    ..watching(["ann"]),
    answered: Some(takeover.Answer(
      agent_id: "ann",
      agent_call_id: agent_leg,
      at: offered_at,
    )),
  )
}

fn event(members: List(#(String, doc.Value))) -> doc.Value {
  doc.object([#("Event-Category", doc.String("call_event")), ..members])
}

/// The caller's own bridge event, which says which leg took them and not
/// whose leg it is.
fn bridged() -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_BRIDGE")),
    #("Call-ID", doc.String(caller_leg)),
    #("Other-Leg-Call-ID", doc.String(agent_leg)),
  ])
}

/// The same, on a channel the offer that died had already marked: both
/// variables, in one `set`, the second as the switch hands it back.
fn bridged_and_marked(agent_id: String) -> doc.Value {
  marked_at(bridged(), agent_id, offered_at + 2)
}

fn marked_at(event: doc.Value, agent_id: String, at: Int) -> doc.Value {
  event
  |> doc.set(["Custom-Channel-Vars", "Agent-ID"], doc.String(agent_id))
  |> doc.set(
    ["Custom-Channel-Vars", "Queue-Answered-Timestamp"],
    doc.String(int.to_string(at)),
  )
}

fn destroyed(call_id: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_DESTROY")),
    #("Call-ID", doc.String(call_id)),
  ])
}

/// An agent leg answering and naming itself, which is what the endpoint's
/// `Agent-ID` is for.
fn agent_answered(agent_id: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_ANSWER")),
    #("Call-ID", doc.String(agent_leg)),
    #("Other-Leg-Call-ID", doc.String(caller_leg)),
    #("Custom-Channel-Vars", doc.object([#("Agent-ID", doc.String(agent_id))])),
  ])
}

// --- Playing a script of events --------------------------------------------

type Beat {
  Heard(at: Int, event: doc.Value)
  Silence(at: Int)
}

fn played(
  request: takeover.Request,
  beats: List(Beat),
) -> List(takeover.Effect) {
  playing(request, takeover.beginning_for(request), beats, [])
}

fn playing(
  request: takeover.Request,
  state: takeover.State,
  beats: List(Beat),
  done: List(takeover.Effect),
) -> List(takeover.Effect) {
  case beats {
    [] -> done
    [beat, ..rest] -> {
      let move = case beat {
        Heard(at, event) -> takeover.step(request, state, event, at)
        Silence(at) -> takeover.timed_out(request, state, at)
      }
      let done = list.append(done, move.effects)
      case move.over {
        True -> done
        False -> playing(request, move.state, rest, done)
      }
    }
  }
}

// --- The answer ------------------------------------------------------------

/// One agent rung is one agent answering, and the channel is marked with the
/// two variables the offer that died never got to set.
pub fn a_bridge_is_the_answer_test() {
  assert played(watching(["ann"]), [Heard(offered_at + 3, bridged())])
    == [
      takeover.Attribute("ann", offered_at + 3),
      takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3)),
    ]
}

/// A channel the offer marked before it died is left alone: the answer it
/// carries is the one the CDR will, and writing a second one would move the
/// second the call was answered.
pub fn a_marked_channel_is_not_marked_again_test() {
  assert played(watching(["ann"]), [
      Heard(offered_at + 3, bridged_and_marked("ann")),
    ])
    == [takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3))]
}

/// A caller `ann` answered in another queue and transferred into this one
/// carries her `Agent-ID` and answer second from that passage, written
/// before this offer began -- by an action of the release before, which did
/// not clear them on joining. That is not this offer's mark: `bob`, who
/// answered, is marked and recorded.
pub fn an_earlier_passages_mark_is_not_this_offers_test() {
  let earlier = marked_at(bridged(), "ann", offered_at - 600)
  assert played(recorded(["bob"]), [Heard(offered_at + 3, earlier)])
    == [
      takeover.Attribute("bob", offered_at + 3),
      takeover.Record("bob", offered_at + 3),
      takeover.Tell(types.Answered("bob", agent_leg, offered_at + 3)),
    ]

  // An `Agent-ID` with no second at all is nobody's mark either.
  let unmarked =
    doc.set(bridged(), ["Custom-Channel-Vars", "Agent-ID"], doc.String("ann"))
  assert takeover.marked_agent(watching(["bob"]), unmarked) == None
  // The mark this offer made, as a number or as the switch's text.
  assert takeover.marked_agent(
      watching(["bob"]),
      marked_at(bridged(), "bob", offered_at),
    )
    == Some("bob")
}

/// The same on the switches' first answer: the channel's earlier mark
/// neither names the agent nor dates the answer.
pub fn an_earlier_passages_mark_on_the_switch_test() {
  let channel =
    channel(caller_leg, [
      #("Other-Leg-Call-ID", doc.String(agent_leg)),
      #(
        "Custom-Channel-Vars",
        doc.object([
          #("Agent-ID", doc.String("ann")),
          #("Queue-Answered-Timestamp", doc.Int(offered_at - 600)),
        ]),
      ),
    ])
  assert takeover.answered_at(channel, offered_at, offered_at + 40)
    == offered_at
  assert takeover.looked(
      recorded(["bob"]),
      takeover.beginning(),
      [channel],
      offered_at + 40,
    ).effects
    == [
      takeover.Attribute("bob", offered_at),
      takeover.Record("bob", offered_at),
      takeover.Tell(types.Answered("bob", agent_leg, offered_at)),
    ]
}

/// With several phones ringing the caller's bridge names no agent, and the
/// leg's own event does. Either order answers.
pub fn the_agents_leg_names_the_answer_test() {
  assert played(watching(["ann", "bob"]), [
      Heard(offered_at + 2, agent_answered("bob")),
    ])
    == [
      takeover.Attribute("bob", offered_at + 2),
      takeover.Tell(types.Answered("bob", agent_leg, offered_at + 2)),
    ]

  assert played(watching(["ann", "bob"]), [
      Heard(offered_at + 1, agent_answered("bob")),
      Heard(offered_at + 2, bridged()),
    ])
    == [
      takeover.Attribute("bob", offered_at + 1),
      takeover.Tell(types.Answered("bob", agent_leg, offered_at + 1)),
    ]
}

/// A bridge nothing can pin on one of several phones still answers, named
/// the way an offer names one it cannot: the caller is talking to somebody
/// and the call is not thrown away over a missing name.
pub fn an_answer_nobody_named_test() {
  let assert [takeover.Complain(message), ..rest] =
    played(watching(["ann", "bob"]), [Heard(offered_at + 3, bridged())])
  assert string.contains(message, caller_leg)
  assert string.contains(message, agent_leg)
  assert string.contains(message, "ann, bob")
  assert rest
    == [
      takeover.Attribute("unknown", offered_at + 3),
      takeover.Tell(types.Answered("unknown", agent_leg, offered_at + 3)),
    ]
}

// --- The end ---------------------------------------------------------------

/// The agent hangs up first: the caller goes with them, which is the
/// `hangup_after_bridge` the offer that died owned -- once the moment a
/// transfer would have shown itself in has gone by with nothing in it.
pub fn the_agent_hanging_up_takes_the_caller_test() {
  assert played(watching(["ann"]), [
      Heard(offered_at + 3, bridged()),
      Heard(offered_at + 63, destroyed(agent_leg)),
      Silence(offered_at + 64),
    ])
    == [
      takeover.Attribute("ann", offered_at + 3),
      takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3)),
      takeover.HangUp,
      takeover.Tell(types.Ended(types.Completed, offered_at + 63)),
    ]
}

/// The caller hangs up first: there is nothing left to hang up.
pub fn the_caller_hanging_up_ends_it_test() {
  assert played(watching(["ann"]), [
      Heard(offered_at + 3, bridged()),
      Heard(offered_at + 63, destroyed(caller_leg)),
    ])
    == [
      takeover.Attribute("ann", offered_at + 3),
      takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3)),
      takeover.Tell(types.Ended(types.CallerHangup, offered_at + 63)),
    ]
}

/// A call adopted from the record -- answered on the node that died, never
/// closed -- is not answered again. Only its end is waited for.
pub fn an_adopted_call_only_ends_test() {
  assert played(adopted(), [
      Heard(offered_at + 63, destroyed(agent_leg)),
      Silence(offered_at + 64),
    ])
    == [
      takeover.HangUp,
      takeover.Tell(types.Ended(types.Completed, offered_at + 63)),
    ]
}

// --- A transfer ------------------------------------------------------------

fn unbridged() -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_UNBRIDGE")),
    #("Call-ID", doc.String(caller_leg)),
    #("Other-Leg-Call-ID", doc.String(agent_leg)),
  ])
}

fn agent_left_by(cause: String) -> doc.Value {
  doc.set(destroyed(agent_leg), ["Hangup-Cause"], doc.String(cause))
}

/// An adopted call whose agent passed the caller on
/// was hung up by the watcher, because the agent's leg going looked like the
/// agent hanging up. `mod_reprise` gives a leg that sent a `REFER` a
/// transfer as its cause, and the caller is left alone.
pub fn an_adopted_call_the_agent_transferred_test() {
  assert played(adopted(), [
      Heard(offered_at + 63, agent_left_by("BLIND_TRANSFER")),
    ])
    == [takeover.Tell(types.Ended(types.Transferred, offered_at + 63))]
}

/// The switch's own transfer event arriving a moment after the unbridge is
/// the same answer, dated by the unbridge.
pub fn a_transfer_event_after_the_unbridge_test() {
  let transferee =
    event([
      #("Event-Name", doc.String("CHANNEL_TRANSFEREE")),
      #("Call-ID", doc.String(caller_leg)),
    ])
  assert played(adopted(), [
      Heard(offered_at + 63, unbridged()),
      Heard(offered_at + 63, destroyed(agent_leg)),
      Heard(offered_at + 64, transferee),
    ])
    == [takeover.Tell(types.Ended(types.Transferred, offered_at + 63))]
}

/// An attended transfer: after the agent's bridge ends, the caller is
/// bridged to a leg that is not the agent's.
pub fn the_caller_bridged_onward_test() {
  let onward =
    event([
      #("Event-Name", doc.String("CHANNEL_BRIDGE")),
      #("Call-ID", doc.String(caller_leg)),
      #("Other-Leg-Call-ID", doc.String("5e6f7080-9a0b")),
    ])
  assert played(watching(["ann"]), [
      Heard(offered_at + 3, bridged()),
      Heard(offered_at + 63, unbridged()),
      Heard(offered_at + 63, onward),
    ])
    == [
      takeover.Attribute("ann", offered_at + 3),
      takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3)),
      takeover.Tell(types.Ended(types.Transferred, offered_at + 63)),
    ]
}

/// The caller hanging up while the watch waits for a sign of a transfer is
/// the call ending when the bridge did, with nobody left to hang up.
pub fn the_caller_going_while_the_watch_waits_test() {
  assert played(adopted(), [
      Heard(offered_at + 63, unbridged()),
      Heard(offered_at + 63, destroyed(caller_leg)),
    ])
    == [takeover.Tell(types.Ended(types.Completed, offered_at + 63))]
}

/// The wait is the offer's own, and only once the bridge has ended.
pub fn the_watch_waits_a_moment_after_the_bridge_ends_test() {
  let move =
    takeover.step(
      adopted(),
      takeover.adopted(takeover.Answer("ann", agent_leg, offered_at)),
      unbridged(),
      offered_at + 63,
    )
  assert move.over == False
  assert move.effects == []
  assert takeover.deadline_for(move.state, deadline, { offered_at + 63 } * 1000)
    == { offered_at + 63 } * 1000 + offer.transfer_wait_ms

  // Counted in milliseconds from the end, whichever calendar second it fell
  // in: an end 900 ms into a second still waits the whole second.
  let ended_ms = { offered_at + 63 } * 1000 + 900
  let ended =
    takeover.step_at(
      adopted(),
      takeover.adopted(takeover.Answer("ann", agent_leg, offered_at)),
      unbridged(),
      offered_at + 63,
      ended_ms,
    )
  let ceiling = takeover.deadline_for(ended.state, deadline, ended_ms + 200)
  assert ceiling == ended_ms + 1000
  assert offer.remaining_ms(ceiling, ended_ms + 200) == 800
}

/// The request's deadline is a calendar second; the watch waits on what is
/// left of it, in monotonic milliseconds.
pub fn the_watch_waits_out_what_is_left_of_the_offer_test() {
  assert takeover.deadline_ms(deadline, offered_at, 5000) == 5000 + 25_000
  // A deadline already past is now.
  assert takeover.deadline_ms(deadline, deadline + 3, 5000) == 5000
}

// --- Nobody answered -------------------------------------------------------

/// The caller hung up while the phone that is not this node's was ringing.
/// The callflow action that would publish the cancel is on a node this one
/// cannot hear from, so the destroy is the whole of what there is to go on.
pub fn the_caller_going_before_the_answer_test() {
  assert played(watching(["ann"]), [
      Heard(offered_at + 8, destroyed(caller_leg)),
    ])
    == [takeover.Tell(types.CallerGone)]
}

/// The offer ran out with nothing on it: everybody it rang missed, and the
/// caller is offered again from here.
pub fn the_offer_running_out_is_a_miss_test() {
  assert played(watching(["ann", "bob"]), [Silence(deadline)])
    == [takeover.Tell(types.OfferNoAnswer(["ann", "bob"]))]
}

/// A call whose events stopped arriving is closed the way an offer whose
/// bridge said nothing is.
pub fn a_watched_call_that_went_quiet_test() {
  assert played(adopted(), [Silence(offered_at + 14_400)])
    == [takeover.Tell(types.Ended(types.FailedBridge, offered_at + 14_400))]
}

// --- The deadline ----------------------------------------------------------

/// The offer's deadline stops applying the moment the caller is through:
/// from then on the only limit is how long a call may run.
pub fn the_deadline_moves_at_the_answer_test() {
  assert takeover.deadline_for(takeover.beginning(), deadline, offered_at)
    == deadline
  assert takeover.deadline_for(
      takeover.adopted(takeover.Answer("ann", agent_leg, offered_at)),
      deadline,
      offered_at * 1000,
    )
    == offered_at * 1000 + 14_400_000
}

// --- Asking the switches first ---------------------------------------------

fn channel(
  call_id: String,
  other_leg: List(#(String, doc.Value)),
) -> events.Channel {
  events.channel(doc.object([#("Call-ID", doc.String(call_id)), ..other_leg]))
}

/// A channel the offer that died marked before it went.
fn marked_channel(answered_at: Int) -> events.Channel {
  channel(caller_leg, [
    #("Other-Leg-Call-ID", doc.String(agent_leg)),
    #(
      "Custom-Channel-Vars",
      doc.object([
        #("Agent-ID", doc.String("ann")),
        #("Queue-Answered-Timestamp", doc.Int(answered_at)),
      ]),
    ),
  ])
}

/// A bridge that happened while the shard was moving leaves no event for a
/// new watcher to hear, so the caller's channel is asked about once. One
/// bridged to another leg is a caller who is already talking.
pub fn a_channel_already_bridged_test() {
  assert takeover.already_through([marked_channel(offered_at + 2)], caller_leg)
    == Some(#(agent_leg, Some("ann")))
}

/// One that is still on its own is a caller nobody has taken.
pub fn a_channel_on_its_own_test() {
  assert takeover.already_through([channel(caller_leg, [])], caller_leg) == None
  assert takeover.already_through([], caller_leg) == None
}

/// Somebody else's channel is not this caller's.
pub fn another_callers_channel_test() {
  assert takeover.already_through(
      [
        channel("somebody-else", [#("Other-Leg-Call-ID", doc.String(agent_leg))]),
      ],
      caller_leg,
    )
    == None
}

/// The answer the offer that died never reported, taken off the channel: it
/// carries the second the offer wrote when it answered, so the record, the
/// CDR and the reply keep agreeing.
pub fn a_bridge_found_on_the_switch_test() {
  assert takeover.looked(
      watching(["ann"]),
      takeover.beginning(),
      [marked_channel(offered_at + 2)],
      offered_at + 40,
    ).effects
    == [takeover.Tell(types.Answered("ann", agent_leg, offered_at + 2))]
}

/// One the offer never got as far as marking is dated by the second that
/// offer began, which is on the record. Not by the second this node looked,
/// which is a failover later and would be counted as talk nobody talked.
pub fn a_bridge_nothing_dated_test() {
  let channel =
    channel(caller_leg, [#("Other-Leg-Call-ID", doc.String(agent_leg))])
  assert takeover.answered_at(channel, offered_at, offered_at + 40)
    == offered_at

  assert takeover.looked(
      recorded(["ann"]),
      takeover.beginning(),
      [channel],
      offered_at + 40,
    ).effects
    == [
      takeover.Attribute("ann", offered_at),
      takeover.Record("ann", offered_at),
      takeover.Tell(types.Answered("ann", agent_leg, offered_at)),
    ]
}

/// A caller on no switch, with nobody yet named, went before anybody took
/// them, and this node is all that is left to say so.
pub fn a_caller_already_gone_test() {
  let move =
    takeover.looked(watching(["ann"]), takeover.beginning(), [], offered_at + 8)
  assert move.over
  let assert [takeover.Complain(_), takeover.Tell(reply)] = move.effects
  assert reply == types.CallerGone
}

/// A call the record said was answered, whose channel has already gone,
/// ended while the lease was moving. Without this the agent is held busy for
/// the whole of `longest_call_ms`.
pub fn an_adopted_call_already_over_test() {
  let move =
    takeover.looked(
      adopted(),
      takeover.beginning_for(adopted()),
      [],
      offered_at + 40,
    )
  assert move.over
  let assert [takeover.Complain(_), takeover.Tell(reply)] = move.effects
  assert reply == types.Ended(types.Completed, offered_at + 40)
}

/// A caller who is up and not yet bridged is watched as before: the offer on
/// the record is still ringing somewhere.
pub fn a_caller_still_being_rung_test() {
  let move =
    takeover.looked(
      watching(["ann"]),
      takeover.beginning(),
      [channel(caller_leg, [])],
      offered_at + 2,
    )
  assert move.effects == []
  assert move.over == False
}

// --- The recording ---------------------------------------------------------

/// The offer that died would have started the queue's recording on the
/// answer, so a takeover that answers starts it too.
pub fn a_recorded_queue_starts_recording_test() {
  assert played(recorded(["ann"]), [Heard(offered_at + 3, bridged())])
    == [
      takeover.Attribute("ann", offered_at + 3),
      takeover.Record("ann", offered_at + 3),
      takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3)),
    ]
}

/// A channel the offer already marked is one whose recording it already
/// started: the two happen in the same breath, so one having happened means
/// both did, and a second recording would be a second file.
pub fn a_marked_channel_is_already_recording_test() {
  assert played(recorded(["ann"]), [
      Heard(offered_at + 3, bridged_and_marked("ann")),
    ])
    == [takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3))]
}

/// A queue that does not record does not start one.
pub fn a_queue_that_does_not_record_test() {
  assert played(watching(["ann"]), [Heard(offered_at + 3, bridged())])
    == [
      takeover.Attribute("ann", offered_at + 3),
      takeover.Tell(types.Answered("ann", agent_leg, offered_at + 3)),
    ]
}

// --- The flag the broker sets ----------------------------------------------

/// A takeover begins with a redelivery and nothing else does, so the flag on
/// the delivery is what the whole of this turns on.
pub fn a_first_delivery_is_not_a_redelivery_test() {
  assert listener.redelivered(member.no_delivery()) == False
  assert listener.redelivered(redelivered_delivery()) == True
}

@external(erlang, "callcenter_ffi", "redelivered_delivery")
fn redelivered_delivery() -> listener.Delivery

// --- What the bus relays -----------------------------------------------------

/// The caller's own events and those of a leg bridged to the caller, of any
/// name, and nothing else of the account's.
pub fn a_takeover_is_relayed_its_call_test() {
  let interest = takeover.interest("acct", caller_leg)
  let of = fn(call_id, other) {
    event([
      #("Event-Name", doc.String("CHANNEL_DESTROY")),
      #("Call-ID", doc.String(call_id)),
      #("Other-Leg-Call-ID", doc.String(other)),
    ])
  }
  assert events.wants(interest, bridged())
  assert events.wants(interest, of(agent_leg, caller_leg))
  assert !events.wants(interest, of(agent_leg, "somebody"))
  assert !events.wants(interest, of("somebody", ""))
  assert interest.account == "acct"
  assert interest.events == []
}

// --- Only the offer's own legs answer ----------------------------------------

/// The prefix of the legs the offer on the record rang.
const prefix = "c0ffee"

const named_leg = "c0ffee-1"

const operator_leg = "0p3r4t0r-0000-0001"

/// The same watch, over an offer whose record says how its legs are named.
fn named(agents: List(String)) -> takeover.Request {
  takeover.Request(..recorded(agents), leg_prefix: Some(prefix))
}

fn bridged_to(leg: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_BRIDGE")),
    #("Call-ID", doc.String(caller_leg)),
    #("Other-Leg-Call-ID", doc.String(leg)),
  ])
}

fn ring_ended(cause: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_EXECUTE_COMPLETE")),
    #("Call-ID", doc.String(caller_leg)),
    #("Application-Name", doc.String("bridge")),
    #("Application-Response", doc.String(cause)),
  ])
}

/// A bridge to one of the offer's legs is its answer.
pub fn a_bridge_to_one_of_the_offers_legs_is_the_answer_test() {
  assert played(named(["ann"]), [Heard(offered_at + 3, bridged_to(named_leg))])
    == [
      takeover.Attribute("ann", offered_at + 3),
      takeover.Record("ann", offered_at + 3),
      takeover.Tell(types.Answered("ann", named_leg, offered_at + 3)),
    ]
}

/// A bridge to a leg the offer did not ring is not its answer: nothing is
/// marked on the caller's channel, nothing recorded and nothing told, and
/// the watch goes on.
pub fn a_bridge_to_somebody_else_is_not_the_answer_test() {
  let move =
    takeover.step(
      named(["ann"]),
      takeover.beginning(),
      bridged_to(operator_leg),
      offered_at + 3,
    )
  assert move.effects == []
  assert move.over == False

  // Nor is a leg of somebody else's answering with the caller as its other
  // leg.
  let answered =
    event([
      #("Event-Name", doc.String("CHANNEL_ANSWER")),
      #("Call-ID", doc.String(operator_leg)),
      #("Other-Leg-Call-ID", doc.String(caller_leg)),
    ])
  assert takeover.step(named(["ann"]), takeover.beginning(), answered, 0).effects
    == []
}

/// The caller pressed 0 for an operator: their action left the queue, the
/// dispatcher called the ring off, and the operator answered. The watch
/// ends on the operator's bridge, which is nobody's miss, and the queue's
/// agent is not marked on the caller's channel or recorded with the
/// operator.
pub fn a_caller_gone_to_an_operator_is_not_answered_by_the_queue_test() {
  assert played(named(["ann"]), [
      Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      Heard(offered_at + 4, bridged_to(operator_leg)),
    ])
    == [takeover.Tell(types.Failed(offer.called_off))]

  // A record of the release before names no legs: after a call-off no
  // bridge is the answer either.
  assert played(recorded(["ann"]), [
      Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      Heard(offered_at + 4, bridged()),
    ])
    == [takeover.Tell(types.Failed(offer.called_off))]
}

/// Everything a watch does but say in the log.
fn done(effects: List(takeover.Effect)) -> List(takeover.Effect) {
  list.filter(effects, fn(effect) {
    case effect {
      takeover.Complain(_) -> False
      _ -> True
    }
  })
}

/// An agent picking up after the ring was called off does not have the
/// caller, even on one of the offer's own legs: the dispatcher's unbridge
/// cuts the bridge. Nothing is marked or recorded, no answer is told, and
/// the caller is never hung up.
pub fn an_answer_after_the_call_off_is_not_taken_test() {
  assert played(named(["ann"]), [
      Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      Heard(offered_at + 3, bridged_to(named_leg)),
    ])
    == [takeover.Tell(types.Failed(offer.called_off))]

  // Nor the leg's own answer, where the caller's bridge went missing.
  let leg_answered =
    event([
      #("Event-Name", doc.String("CHANNEL_ANSWER")),
      #("Call-ID", doc.String(named_leg)),
      #("Other-Leg-Call-ID", doc.String(caller_leg)),
    ])
  assert played(named(["ann"]), [
      Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      Heard(offered_at + 3, leg_answered),
    ])
    == [takeover.Tell(types.Failed(offer.called_off))]
}

/// The other order: the watch had the answer, marked and recorded it and
/// told the dispatcher, and then heard the call-off. The call-off wins: the
/// mark and the recording are taken back, the watch ends with
/// `Failed(called_off)`, and the park that ends the bridge is not read as
/// the end of a call -- nothing hangs the caller up.
pub fn a_call_off_after_the_answer_takes_it_back_test() {
  let answering = [
    takeover.Attribute("ann", offered_at + 3),
    takeover.Record("ann", offered_at + 3),
    takeover.Tell(types.Answered("ann", named_leg, offered_at + 3)),
  ]
  let unbridged =
    event([
      #("Event-Name", doc.String("CHANNEL_UNBRIDGE")),
      #("Call-ID", doc.String(caller_leg)),
      #("Other-Leg-Call-ID", doc.String(named_leg)),
    ])
  let effects =
    played(named(["ann"]), [
      Heard(offered_at + 3, bridged_to(named_leg)),
      Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      Heard(offered_at + 3, unbridged),
      Heard(offered_at + 3, destroyed(named_leg)),
      Silence(offered_at + 5),
    ])
  assert done(effects)
    == list.append(answering, [
      takeover.Unmark,
      takeover.StopRecording(offered_at + 3),
      takeover.Tell(types.Failed(offer.called_off)),
    ])
  assert list.contains(effects, takeover.HangUp) == False

  // Read after the park had already ended the bridge, the same.
  let late =
    played(named(["ann"]), [
      Heard(offered_at + 3, bridged_to(named_leg)),
      Heard(offered_at + 3, unbridged),
      Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      Silence(offered_at + 5),
    ])
  assert done(late) == done(effects)

  // An answer the offer that died had marked is not taken back by a watch
  // that did not mark it.
  assert done(
      played(named(["ann"]), [
        Heard(
          offered_at + 3,
          marked_at(bridged_to(named_leg), "ann", offered_at + 2),
        ),
        Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      ]),
    )
    == [
      takeover.Tell(types.Answered("ann", named_leg, offered_at + 3)),
      takeover.Tell(types.Failed(offer.called_off)),
    ]
}

/// A call-off ends the watch with the ring's end, or a moment after it when
/// the ring's end is not heard -- it may have ended before this node took
/// over -- and not at the offer's deadline.
pub fn a_ring_called_off_ends_the_watch_test() {
  assert played(named(["ann"]), [
      Heard(offered_at + 3, offer.called_off_event(unbridged: True)),
      Heard(offered_at + 3, ring_ended("ORIGINATOR_CANCEL")),
    ])
    == [takeover.Tell(types.Failed(offer.called_off))]

  let stopped =
    takeover.step_at(
      named(["ann"]),
      takeover.beginning(),
      offer.called_off_event(unbridged: True),
      offered_at + 3,
      1000,
    )
  assert takeover.deadline_for(stopped.state, 20_000, 1000)
    == 1000 + offer.cancel_wait_ms
  assert takeover.timed_out(named(["ann"]), stopped.state, offered_at + 5).effects
    == [takeover.Tell(types.Failed(offer.called_off))]
}

/// The ring ended with nobody through: what the switch said is the outcome
/// at once, as for an offer, rather than a watch kept up to the deadline
/// taking the caller's next bridge for an answer.
pub fn the_end_of_the_ring_ends_the_watch_test() {
  assert played(named(["ann"]), [
      Heard(offered_at + 20, ring_ended("NO_ANSWER")),
    ])
    == [takeover.Tell(types.OfferNoAnswer(["ann"]))]

  // Cancelled from the caller's side: the caller's destroy is the caller
  // leaving, and anything else a moment later is the action having called
  // the ring off -- including the caller's next bridge.
  assert played(named(["ann"]), [
      Heard(offered_at + 5, ring_ended("ORIGINATOR_CANCEL")),
      Heard(offered_at + 5, destroyed(caller_leg)),
    ])
    == [takeover.Tell(types.CallerGone)]
  assert played(named(["ann"]), [
      Heard(offered_at + 5, ring_ended("ORIGINATOR_CANCEL")),
      Heard(offered_at + 6, bridged_to(operator_leg)),
    ])
    == [takeover.Tell(types.Failed(offer.originator_cancel))]
  assert played(named(["ann"]), [
      Heard(offered_at + 5, ring_ended("ORIGINATOR_CANCEL")),
      Silence(offered_at + 7),
    ])
    == [takeover.Tell(types.Failed(offer.originator_cancel))]
}

/// The switches' first answer: a caller already through to one of the
/// offer's legs is its answer; one through to somebody else, with nothing
/// the offer wrote on the channel, is not, and is left to the call-off on
/// its way.
pub fn a_bridge_found_on_the_switch_is_the_offers_only_if_its_leg_test() {
  let ours =
    channel(caller_leg, [#("Other-Leg-Call-ID", doc.String(named_leg))])
  assert takeover.looked(named(["ann"]), takeover.beginning(), [ours], 0).effects
    == [
      takeover.Attribute("ann", offered_at),
      takeover.Record("ann", offered_at),
      takeover.Tell(types.Answered("ann", named_leg, offered_at)),
    ]

  let theirs =
    channel(caller_leg, [#("Other-Leg-Call-ID", doc.String(operator_leg))])
  let move = takeover.looked(named(["ann"]), takeover.beginning(), [theirs], 0)
  assert move.effects == []
  assert move.over == False
}

/// The dispatcher taking a caller over hands the watch the prefix the dead
/// offer's record carries.
pub fn a_taken_over_offer_says_how_its_legs_are_named_test() {
  let support =
    doc.object([
      #("pvt_type", doc.String("queue")),
      #("name", doc.String("Support")),
      #("strategy", doc.String("longest_idle")),
      #("agent_ring_timeout", doc.Int(20)),
      #(
        "agents",
        doc.List([
          doc.object([
            #("id", doc.String("ann")),
            #("level", doc.Int(1)),
            #("position", doc.Int(1)),
          ]),
        ]),
      ),
    ])
  let ann =
    doc.object([
      #("pvt_type", doc.String("user")),
      #("call_center", doc.object([])),
    ])
  let c = cluster.new([#("support", support)], [#("ann", ann)])
  cluster.agent_is(c, "ann", "available")
  let record =
    cluster.record("call-one", "support", 0, [#("ann", 0, None)], None)
  let assert Ok([entry]) = doc.get_list(record, ["offered_to"])
  let entry = doc.set(entry, ["leg_prefix"], doc.String(prefix))
  cluster.put_record(c, 0, doc.set(record, ["offered_to"], doc.List([entry])))
  cluster.redelivered(c, "call-one", "support", 0, 0)

  let assert Ok(request) = fake_watch.last(c.watches)
  assert request.leg_prefix == Some(prefix)
}
