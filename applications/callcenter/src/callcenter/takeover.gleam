//// Watching a call the node that was dispatching for it did not live to
//// finish.
////
//// A caller is a member message the broker holds unacked, and a node that
//// dies gives every one of its members back. The node that takes the shard
//// next therefore meets callers whose phones may already be ringing, and
//// whose conversations may already be going on, because the only thing this
//// application ever put on a broker about them was "somebody is waiting".
//// What actually happened to them is in their `queue_call` document, and
//// what is happening to them now is on the switch.
////
//// So a redelivered caller whose record shows an offer that has not run out
//// is not rung again. One of these processes is started instead of an
//// offer: it rings nobody, watches the caller's channel, and answers on the
//// same subject an offer answers on, with the same replies. The dispatcher
//// cannot tell the two apart and does not have to -- an `Answered` settles
//// the member, writes the record and publishes the events exactly as it
//// always did, and a deadline with nothing on it is an `OfferNoAnswer`,
//// which puts the caller back in the queue to be offered properly.
////
//// It does four things an offer does, because no offer is left to do them:
////
//// - it names the agent and marks the caller's channel with the `Agent-ID`
////   and `Queue-Answered-Timestamp` the dead offer would have set, unless
////   that offer got far enough to set them itself;
//// - it starts the queue's recording, which that offer starts in the same
////   breath and so did not start either;
//// - it hangs the caller up when the agent's leg goes, which is today's
////   `hangup_after_bridge` -- unless the agent was passing the caller on:
////   the end of the bridge waits `talk.transfer_wait_ms` for a sign of a
////   transfer, read by the offer's own `talk.is_transfer_of`, exactly as an
////   offer does, and a transfer ends the watch without touching the caller.
////   A ring the dispatcher calls off is never answered, and its caller never
////   hung up, from then on (`overtaken`);
//// - it asks the switches once, before it starts listening, what the caller
////   is doing. A bridge that happened while the shard was moving leaves no
////   event for a new watcher to hear, and a caller who is talking must not
////   be offered to anybody; a call that ended in the same window leaves the
////   agent held busy until something says otherwise, and this is it.
////
//// What an event means is decided in `step` and `timed_out`, which are
//// functions from a state and an event to the next state and a list of
//// effects, as in `callcenter/offer` and for the same reason: the order of
//// an answer is something a test reads directly, without a switch
//// underneath it.

import callcenter/call/recovery
import callcenter/call/talk
import callcenter/offer
import callcenter/recording
import callcenter/system
import callcenter/types.{type Member, type OfferId, type OfferReply}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/call.{type Call}
import kazoo/doc.{type Value}
import kazoo/events
import kazoo/modb

/// How long a call that is up is watched before the watcher gives up on it.
/// The same ceiling an offer puts on a bridged call.
const longest_call_ms = 14_400_000

/// An answer that has already happened somewhere else.
pub type Answer {
  Answer(agent_id: String, agent_call_id: String, at: Int)
}

/// What the dispatcher asks for: this caller, these agents, and how long the
/// offer the record describes still has to run.
pub type Request {
  Request(
    member: Member,
    /// Everybody the caller's record says was rung.
    agents: List(String),
    /// The second that offer began, which is the second the record carries.
    /// It is what an answer nothing else can date is dated by.
    offered_at: Int,
    /// The second the offer runs out: `offered_at` plus the ring timeout and
    /// the grace. Past it nobody answered.
    deadline: Int,
    /// Whether the queue, or one of the agents, asks for the call to be
    /// recorded. The offer that died starts the recording on the answer, so
    /// an answer it never reported is one that was never started.
    record: Bool,
    /// Set when the record already says an agent answered. The call is
    /// adopted rather than offered and only its end is waited for.
    answered: Option(Answer),
    /// What the call ids of the legs the offer that died rang start with, as
    /// its record says (`records.Offered`): a bridge to a leg without it is
    /// not that offer's answer. Nothing for a record the release before this
    /// one wrote, and for a call adopted after its answer.
    leg_prefix: Option(String),
    /// The offer this watch stands in for, as its replies name it.
    id: OfferId,
    /// The dispatcher's own offer subject.
    reply_to: Subject(#(OfferId, OfferReply)),
  )
}

/// What the watcher knows about the call between one event and the next.
pub type State {
  State(
    /// The agent leg, once the caller is bridged to one.
    bridged_to: Option(String),
    /// Whose leg that is, learned from the leg's own channel variables.
    agent_id: Option(String),
    /// Whether the caller is through to somebody.
    answered: Bool,
    /// The answered bridge has ended, and the watch is waiting a moment to
    /// see whether it was a transfer. The offer's own.
    closing: Option(talk.Closing),
    /// Before an answer: the ring is over, or being called off, and the
    /// watch is only waiting to see how.
    ending: Option(Ending),
    /// The second this watch marked the caller's channel with the answer,
    /// and started the recording when the queue records: what a call-off
    /// that overtook the answer takes back. Nothing when the offer that died
    /// had marked it, or nothing was marked.
    marked: Option(Int),
  )
}

/// A ring the watch knows is over or going, before anybody answered: the
/// dispatcher called it off because the caller is leaving the queue or the
/// agent was released (`offer.called_off`), or the caller's bridge ended
/// with `ORIGINATOR_CANCEL` (`talk.originator_cancel`). Until `until`, a
/// monotonic millisecond, the caller's destroy is still `CallerGone`; after
/// it the watch ends with `Failed(reason)`, which is nobody's miss. An
/// answer counts only from one of the offer's own legs, and after a
/// call-off from none: the unbridge that goes with it cuts the bridge, as it
/// does an offer's (`offer.overtaken`).
pub type Ending {
  Ending(reason: String, until: Int)
}

/// A watch over a caller who was being rung.
pub fn beginning() -> State {
  State(
    bridged_to: None,
    agent_id: None,
    answered: False,
    closing: None,
    ending: None,
    marked: None,
  )
}

/// A watch over a caller who was already connected.
pub fn adopted(answer: Answer) -> State {
  State(
    bridged_to: leg(answer.agent_call_id, None),
    agent_id: Some(answer.agent_id),
    answered: True,
    closing: None,
    ending: None,
    marked: None,
  )
}

/// The watch a request begins in.
pub fn beginning_for(request: Request) -> State {
  case request.answered {
    Some(answer) -> adopted(answer)
    None -> beginning()
  }
}

/// The agent on an answer nobody could name, which is the offer's own.
pub fn unknown_agent() -> String {
  talk.unknown_agent
}

/// One thing a watcher does to the world. Deciding them and doing them are
/// kept apart so that the order they happen in can be read off a test.
pub type Effect {
  /// Mark the caller's channel with who took them and when, which the offer
  /// that died did only if it got that far.
  Attribute(agent_id: String, at: Int)
  /// Start the queue's recording on the caller's channel, which that offer
  /// started in the same breath and so did not start either.
  Record(agent_id: String, at: Int)
  /// Take `Attribute` back: the caller's channel says nobody answered.
  Unmark
  /// Stop the recording `Record` started for the answer at `at`.
  StopRecording(at: Int)
  /// Hang the caller up, the agent having gone first.
  HangUp
  /// Tell the dispatcher.
  Tell(reply: OfferReply)
  /// Say in the log what an operator has to know about.
  Complain(message: String)
}

/// Where one event leaves the watch, what it has to do about it, and whether
/// there is anything left to wait for.
pub type Move {
  Move(state: State, effects: List(Effect), over: Bool)
}

// --- Starting --------------------------------------------------------------

/// Watch the caller in `request`.
///
/// Unlinked, as an offer is not: the dispatcher treats this process exactly
/// as it treats an offer's, and a watcher that crashes must leave the
/// dispatcher standing -- the caller it was watching is then given up on at
/// the ceiling and offered again, which is the whole point of the ceiling.
pub fn start(request: Request) -> Result(Pid, String) {
  Ok(process.spawn_unlinked(fn() { run(request) }))
}

fn run(request: Request) -> Nil {
  // Ends quietly, as an offer does, if the dispatcher goes first.
  let _guarded = offer.guard_dispatcher(request.reply_to)
  let watching = watch(request)
  let caller = call.from_value(request.member.call)
  let move = first_look(request, beginning_for(request), now())
  list.each(move.effects, perform(request, caller, _))
  case move.over {
    True -> Nil
    False ->
      waiting(
        request,
        caller,
        move.state,
        deadline_for(
          move.state,
          deadline_ms(request.deadline, now(), offer.monotonic_ms()),
          offer.monotonic_ms(),
        ),
      )
  }
  unwatch(watching)
}

/// The one question asked of the switches, before any event is waited for.
///
/// Two windows it closes, both small and both real. The offer was ringing
/// when the node holding the shard died and the agent picked up while the
/// shard was moving, so the bridge event went to nobody: without this the
/// watcher hears nothing, gives up at the ceiling, and a caller in the
/// middle of a conversation is offered to the next agent. Or the call the
/// record says was answered had already finished, and the end event went the
/// same way: without this the agent is held busy for the whole of
/// `longest_call_ms`.
fn first_look(request: Request, state: State, now: Int) -> Move {
  case events.channel_status(system.category, request.member.call_id) {
    // The cluster did not answer, or not all of it did and none of it
    // carries the call, which is not the same as a call that has gone.
    // Nothing is assumed from a silence.
    Error(_no_answer) -> going(state)
    Ok(channels) -> looked(request, state, channels, now)
  }
}

/// What the switches' first answer means. Pure, because it decides whether a
/// caller is talking, gone, or still being rung for.
pub fn looked(
  request: Request,
  state: State,
  channels: List(events.Channel),
  now: Int,
) -> Move {
  case recovery.carried(channels, request.member.call_id), state.answered {
    // On no switch. Whatever was going to happen to this caller has already
    // happened, and this node is the only thing left to say so.
    None, True ->
      over(state, [
        Complain(gone(request, "had already ended")),
        Tell(types.Ended(types.Completed, now)),
      ])
    None, False ->
      over(state, [
        Complain(gone(request, "was already gone")),
        Tell(types.CallerGone),
      ])

    // Up and already through to somebody: the answer the offer that died
    // never reported -- if that somebody is on one of its legs, or the offer
    // got as far as marking the channel. A caller through to anybody else
    // left the queue while the shard was moving, and their cancel is on its
    // way.
    Some(channel), False ->
      case recovery.bridged(channel) {
        None -> going(state)
        Some(agent_call_id) -> {
          let marked = marked_agent(request, channel.doc)
          case
            is_offers_leg(request, state, agent_call_id)
            || option.is_some(marked)
          {
            False -> going(state)
            True ->
              took(
                request,
                state,
                agent_call_id,
                agent_of(marked, request.agents),
                option.is_some(marked),
                recovery.answered_at(channel, request.offered_at, now),
              )
          }
        }
      }

    // Up, and the record already said who has it.
    Some(_channel), True -> going(state)
  }
}

fn gone(request: Request, what: String) -> String {
  "the call taken over for "
  <> request.member.call_id
  <> " is on no switch: it "
  <> what
  <> " when this node took the shard"
}

/// The agent the offer that died marked the caller's channel with, when it
/// was that offer, in this passage, that marked it: see
/// `recovery.marked_agent`.
pub fn marked_agent(request: Request, carrier: Value) -> Option(String) {
  recovery.marked_agent(
    offered_at: request.offered_at,
    joined: request.member.joined,
    carrier: carrier,
  )
}

/// One of the agents the record named, or nobody. A name from somewhere else
/// belongs to some other call and is not this answer's.
fn agent_of(named: Option(String), agents: List(String)) -> Option(String) {
  option.then(named, fn(agent_id) {
    case list.contains(agents, agent_id) {
      True -> Some(agent_id)
      False -> None
    }
  })
}

// --- The loop --------------------------------------------------------------

/// The watch's loop. `deadline` is a monotonic millisecond, as an offer's
/// is: see `offer.identify_wait_ms`.
fn waiting(request: Request, caller: Call, state: State, deadline: Int) -> Nil {
  let move = case
    call.receive_event(offer.remaining_ms(deadline, offer.monotonic_ms()))
  {
    Error(call.Timeout) -> timed_out(request, state, now())
    Ok(event) ->
      case offer.is_dispatcher_gone(event) {
        True -> over(state, [])
        False -> step_at(request, state, event, now(), offer.monotonic_ms())
      }
  }
  list.each(move.effects, perform(request, caller, _))
  case move.over {
    True -> Nil
    False ->
      waiting(
        request,
        caller,
        move.state,
        deadline_for(move.state, deadline, offer.monotonic_ms()),
      )
  }
}

/// The request's deadline, a calendar second, as a monotonic millisecond:
/// what is left of it from now.
pub fn deadline_ms(deadline: Int, now: Int, now_ms: Int) -> Int {
  now_ms + int.max(deadline - now, 0) * 1000
}

/// Until when the watcher waits for the next event, from a moment: both
/// monotonic milliseconds.
///
/// The offer's deadline stops applying the moment the caller is through:
/// from then on the only limit is how long a call may run, until the bridge
/// ends and the watch waits a moment to see whether it was a transfer. A
/// ring known to be over or going ends the watch sooner.
pub fn deadline_for(state: State, deadline: Int, now_ms: Int) -> Int {
  case state.answered, state.closing, state.ending {
    True, Some(closing), _ -> closing.until
    True, None, _ -> now_ms + longest_call_ms
    False, _, Some(ending) -> int.min(ending.until, deadline)
    False, _, None -> deadline
  }
}

fn perform(request: Request, caller: Call, effect: Effect) -> Nil {
  case effect {
    Attribute(agent_id, at) ->
      call.set_channel_vars(
        caller,
        [
          #("Agent-ID", doc.String(agent_id)),
          #("Queue-Answered-Timestamp", doc.Int(at)),
        ],
        [],
      )
    Record(agent_id, at) ->
      recording.start(
        caller,
        request.member.account_id,
        request.member.queue_id,
        request.member.call_id,
        agent_id,
        at,
      )
    Unmark -> call.set_channel_vars(caller, offer.unmarked, [])
    StopRecording(at) ->
      recording.stop(
        caller,
        request.member.account_id,
        request.member.queue_id,
        request.member.call_id,
        at,
      )
    HangUp -> call.hangup(caller)
    Tell(told) -> process.send(request.reply_to, #(request.id, told))
    Complain(message) -> system.log_error(message)
  }
}

// --- What an event means ---------------------------------------------------

/// What one event does to a watch, at `now` on the calendar and `now_ms` on
/// the monotonic clock, as for an offer (`offer.step_at`).
pub fn step_at(
  request: Request,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  case offer.is_called_off(event), state.answered {
    True, True -> overtaken(request, state)
    True, False -> called_off(state, now_ms)
    False, _ -> {
      let state = learn(request, state, event)
      case state.answered {
        True -> after_answer(request, state, event, now, now_ms)
        False -> before_answer(request, state, event, now, now_ms)
      }
    }
  }
}

/// `step_at` on a clock whose milliseconds are its seconds'.
pub fn step(request: Request, state: State, event: Value, now: Int) -> Move {
  step_at(request, state, event, now, now * 1000)
}

/// What one event means before anybody answered.
///
/// An answer is a bridge to one of the legs the offer that died rang, and
/// nothing else. The watch used to take any bridge of the caller's, and any
/// leg answering with the caller as its other leg, for the answer until the
/// offer's deadline, so a caller who pressed 0 for an operator and was put
/// through had the queue's agent marked on their channel, a queue recording
/// of the operator's call started, and an answer for that agent sent to the
/// dispatcher. So the watch ends with the ring: when the caller's bridge
/// finishes, or the dispatcher calls it off because the caller left the
/// queue.
fn before_answer(
  request: Request,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  let from_caller = events.call_id(event) == Some(request.member.call_id)
  case events.event_name(event), from_caller {
    // The caller is through to somebody.
    Some("CHANNEL_BRIDGE"), True ->
      case
        !is_called_off(state)
        && is_offers_leg(
          request,
          state,
          option.unwrap(events.other_leg_call_id(event), ""),
        )
      {
        True -> answer(request, state, event, now)
        False -> not_the_answer(state)
      }

    // The other half of the same fact, for the case where the caller's own
    // bridge event was the one that went missing: a leg the offer rang has
    // answered and names the caller as its other leg.
    Some("CHANNEL_ANSWER"), False ->
      case
        bridged_to_caller(request, event),
        is_called_off(state),
        is_offers_leg(request, state, option.unwrap(events.call_id(event), ""))
      {
        True, True, _ -> not_the_answer(state)
        True, False, True -> answer(request, state, event, now)
        _, _, _ -> going(state)
      }

    // Nobody took them, and this node is all that is left to say so.
    Some("CHANNEL_DESTROY"), True -> over(state, [Tell(types.CallerGone)])

    // The ring is over.
    Some("CHANNEL_EXECUTE_COMPLETE"), True ->
      case talk.is_bridge(event) {
        True -> ring_ended(request, state, event, now_ms)
        False -> going(state)
      }
    _other, True ->
      case talk.is_bridge_error(event) {
        True -> ring_ended(request, state, event, now_ms)
        False -> going(state)
      }

    _other, False -> going(state)
  }
}

/// Whether a leg bridged to the caller is one the offer that died rang.
///
/// A leg whose call id starts with the offer's prefix is. So is one whose
/// own events named one of the agents while the ring was still going: a
/// device that forwarded and bridged the caller through a channel of its
/// own. A record that says no prefix -- written by the release before this
/// one -- leaves nothing to tell legs apart by, and any leg is the offer's
/// while its ring is not known to be over.
pub fn is_offers_leg(request: Request, state: State, leg: String) -> Bool {
  let ringing = option.is_none(state.ending)
  case request.leg_prefix {
    Some(prefix) ->
      string.starts_with(leg, prefix <> "-")
      || { ringing && learned(state, leg) }
    None -> ringing
  }
}

fn learned(state: State, leg: String) -> Bool {
  leg != "" && state.bridged_to == Some(leg) && option.is_some(state.agent_id)
}

/// Whether the dispatcher has called the ring off.
fn is_called_off(state: State) -> Bool {
  case state.ending {
    Some(ending) -> ending.reason == offer.called_off
    None -> False
  }
}

/// The caller bridged to a leg the offer did not ring, or to one it did after
/// the ring was called off. Once its ring is known to be over that is the
/// caller gone on to whatever their callflow does next, or an answer the
/// unbridge cuts, and the watch ends; before, it is nothing this watch can
/// read and it waits on.
fn not_the_answer(state: State) -> Move {
  case state.ending {
    Some(ending) -> over(state, [Tell(types.Failed(ending.reason))])
    None -> going(state)
  }
}

/// The dispatcher called the ring off: the caller is leaving the queue, the
/// agent was released, or the queue went, and the dispatcher unbridged the
/// ring. No bridge after it is an answer, the offer's own legs' included.
fn called_off(state: State, now_ms: Int) -> Move {
  case state.ending {
    Some(_already) -> going(state)
    None ->
      going(
        State(
          ..state,
          ending: Some(Ending(
            reason: offer.called_off,
            until: now_ms + offer.cancel_wait_ms,
          )),
        ),
      )
  }
}

/// The dispatcher called the ring off after this watch had the caller
/// through: an agent answered a moment before the dispatcher's unbridge
/// reached the caller's channel, and the unbridge parks the caller in the
/// middle of it. The call-off wins, as it does for an offer
/// (`offer.overtaken`): what this watch did to the caller's channel for the
/// answer is taken back, the caller is never hung up, and the watch ends
/// with `Failed(called_off)`, which is how the dispatcher hears of an
/// `Answered` it has not taken.
fn overtaken(request: Request, state: State) -> Move {
  let taken_back = case state.marked, request.record {
    None, _ -> []
    Some(_at), False -> [Unmark]
    Some(at), True -> [Unmark, StopRecording(at)]
  }
  over(
    state,
    list.append(taken_back, [
      Complain(
        "the call taken over for "
        <> request.member.call_id
        <> ": its ring was called off as leg "
        <> option.unwrap(state.bridged_to, "?")
        <> " answered; the call-off stands and the answer does not",
      ),
      Tell(types.Failed(offer.called_off)),
    ]),
  )
}

/// The caller's bridge ended with nobody through, which is the offer's ring
/// over. What the switch said decides whose it was, as for an offer
/// (`talk.miss`), and a cancel from the caller's side waits a moment for
/// the caller's destroy, which is the caller leaving.
fn ring_ended(
  request: Request,
  state: State,
  event: Value,
  now_ms: Int,
) -> Move {
  case state.ending, talk.miss(event) {
    // The end of the ring the dispatcher called off.
    Some(ending), _ ->
      case ending.reason == offer.called_off {
        True -> over(state, [Tell(types.Failed(ending.reason))])
        False -> going(state)
      }
    None, talk.Cancelled ->
      going(
        State(
          ..state,
          ending: Some(Ending(
            reason: talk.originator_cancel,
            until: now_ms + offer.cancel_wait_ms,
          )),
        ),
      )
    None, missed -> over(state, [Tell(talk.miss_reply(missed, request.agents))])
  }
}

/// What one event means once the caller is through, which is what an offer
/// makes of it (`offer.after_answer`) and for the same reason.
///
/// The end of the bridge -- the caller unbridged, or the agent's leg gone --
/// hangs the caller up, which is today's `hangup_after_bridge`. An agent
/// passing the caller on from their phone produces exactly those events, and
/// a watcher that hung up at once hung up a caller on their way to the
/// transfer's target. So the end waits `talk.transfer_wait_ms` for a sign of
/// a transfer: the switch's transfer events for either leg, the agent's leg
/// going with a transfer as its cause, or the caller bridged again to a leg
/// that is not the agent's. A transfer ends the watch without touching the
/// caller.
fn after_answer(
  request: Request,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  let caller = request.member.call_id
  let leg = events.call_id(event)
  let from_caller = leg == Some(caller)
  let from_agent = option.is_some(leg) && leg == state.bridged_to
  case
    talk.is_transfer_of(caller, state.bridged_to, event),
    events.event_name(event)
  {
    True, _ -> transferred(state, now)

    // The caller went: there is nobody left to hang up.
    False, Some("CHANNEL_DESTROY") if from_caller ->
      case state.closing {
        Some(closing) ->
          over(state, [Tell(types.Ended(closing.result, closing.at))])
        None -> over(state, [Tell(types.Ended(types.CallerHangup, now))])
      }

    False, Some("CHANNEL_DESTROY") if from_agent ->
      bridge_ended(state, now, now_ms)
    False, Some("CHANNEL_UNBRIDGE") if from_caller ->
      bridge_ended(state, now, now_ms)

    // The caller bridged again, to a leg that is not the agent's, after the
    // agent's bridge ended: an attended transfer putting them through.
    False, Some("CHANNEL_BRIDGE") if from_caller ->
      case state.closing, events.other_leg_call_id(event) == state.bridged_to {
        Some(_closing), False -> transferred(state, now)
        _, _ -> going(state)
      }

    _, _ -> going(state)
  }
}

/// The answered bridge has ended: wait a moment to see whether it was a
/// transfer. The first end is the one that counts.
fn bridge_ended(state: State, now: Int, now_ms: Int) -> Move {
  case state.closing {
    Some(_already) -> going(state)
    None ->
      going(
        State(
          ..state,
          closing: Some(talk.closing(types.Completed, now, now_ms)),
        ),
      )
  }
}

/// The agent passed the caller on: the watch is over as of the moment the
/// agent's bridge ended, and the caller is left alone.
fn transferred(state: State, now: Int) -> Move {
  let at = case state.closing {
    Some(closing) -> closing.at
    None -> now
  }
  over(state, [Tell(types.Ended(types.Transferred, at))])
}

/// Nothing was said for as long as the watch was willing to wait.
///
/// Before an answer that is the offer running out, which is a miss for
/// everybody it rang and a caller to be offered again -- unless the ring was
/// already known to be over or called off, which is nobody's. After one whose
/// bridge ended, nothing said it was a transfer: the caller goes with the
/// agent. After one that is still up, it is a call whose events stopped
/// arriving, which the dispatcher closes the way it closes an offer whose
/// bridge said nothing.
pub fn timed_out(request: Request, state: State, now: Int) -> Move {
  case state.answered, state.closing {
    True, Some(closing) ->
      over(state, [HangUp, Tell(types.Ended(closing.result, closing.at))])
    True, None -> over(state, [Tell(types.Ended(types.FailedBridge, now))])
    False, _ ->
      case state.ending {
        Some(ending) -> over(state, [Tell(types.Failed(ending.reason))])
        None -> over(state, [Tell(types.OfferNoAnswer(request.agents))])
      }
  }
}

/// What an event from the agent's leg says about whose leg it is.
fn learn(request: Request, state: State, event: Value) -> State {
  case events.call_id(event) {
    Some(call_id) if call_id != request.member.call_id ->
      case
        state.bridged_to == None || state.bridged_to == Some(call_id),
        talk.agent_of(event, request.agents)
      {
        True, Some(agent_id) ->
          State(..state, agent_id: Some(agent_id), bridged_to: Some(call_id))
        _, _ -> state
      }
    _not_another_leg -> state
  }
}

fn bridged_to_caller(request: Request, event: Value) -> Bool {
  events.other_leg_call_id(event) == Some(request.member.call_id)
}

fn answer(request: Request, state: State, event: Value, now: Int) -> Move {
  let from_caller = events.call_id(event) == Some(request.member.call_id)
  let agent_call_id = case from_caller {
    // The caller's own bridge names the leg it went to.
    True ->
      option.unwrap(
        option.or(events.other_leg_call_id(event), state.bridged_to),
        "",
      )
    // A leg's own answer names itself.
    False -> option.unwrap(events.call_id(event), "")
  }
  took(
    request,
    state,
    agent_call_id,
    option.or(state.agent_id, talk.answering_agent(request.agents, event)),
    from_caller && attributed(request, event),
    now,
  )
}

/// Whether the offer that died got as far as marking the caller's channel.
///
/// Only the caller's own events say: every agent's leg was rung carrying an
/// `Agent-ID` of its own, which says who that phone belongs to and nothing
/// about what has been written on the caller. And only a mark of this
/// passage's: see `marked_agent`.
fn attributed(request: Request, event: Value) -> Bool {
  option.is_some(marked_agent(request, event))
}

/// The caller is through: what the offer would have done, minus whatever it
/// managed to do before it died.
fn took(
  request: Request,
  state: State,
  agent_call_id: String,
  named: Option(String),
  attributed: Bool,
  now: Int,
) -> Move {
  // One agent rung is one agent answering. With several and nothing to tell
  // them apart the answer is reported the way an offer reports one it cannot
  // name, which keeps the call up and says so out loud.
  let #(agent_id, complaint) = case option.or(named, state.agent_id) {
    Some(agent_id) -> #(agent_id, [])
    None ->
      case request.agents {
        [one] -> #(one, [])
        _many -> #(talk.unknown_agent, [
          Complain(unnamed(request, agent_call_id)),
        ])
      }
  }
  // The offer that died marked the channel and started the recording in one
  // breath, so one having happened means both did. Neither is done twice: a
  // second `Queue-Answered-Timestamp` would move the second the call was
  // answered, and a second recording would be a second file.
  let #(commands, marked) = case attributed {
    True -> #([], None)
    False ->
      case request.record {
        True -> #([Attribute(agent_id, now), Record(agent_id, now)], Some(now))
        False -> #([Attribute(agent_id, now)], Some(now))
      }
  }
  Move(
    state: State(
      ..state,
      bridged_to: leg(agent_call_id, state.bridged_to),
      agent_id: Some(agent_id),
      answered: True,
      marked: marked,
    ),
    effects: list.flatten([
      complaint,
      commands,
      [Tell(types.Answered(agent_id, agent_call_id, now))],
    ]),
    over: False,
  )
}

fn unnamed(request: Request, agent_call_id: String) -> String {
  "the call taken over for "
  <> request.member.call_id
  <> " in queue "
  <> request.member.queue_id
  <> " was answered by leg "
  <> agent_call_id
  <> ", which named no agent of "
  <> string.join(request.agents, ", ")
  <> "; answering as "
  <> talk.unknown_agent
}

fn leg(call_id: String, known: Option(String)) -> Option(String) {
  case call_id {
    "" -> known
    call_id -> Some(call_id)
  }
}

fn going(state: State) -> Move {
  Move(state: state, effects: [], over: False)
}

fn over(state: State, effects: List(Effect)) -> Move {
  Move(state: state, effects: effects, over: True)
}

fn now() -> Int {
  modb.now()
}

// --- The call's events -----------------------------------------------------

/// Have this call's events relayed into this process, exactly as an offer
/// does: the agent's leg is in the set once it is bridged, because its
/// events carry the caller as their other leg.
fn watch(request: Request) -> Option(events.Subscription) {
  let call_id = request.member.call_id
  case
    events.relay(
      interest(request.member.account_id, call_id),
      to: process.self(),
    )
  {
    Ok(subscription) -> Some(subscription)
    Error(reason) -> {
      system.log_error(
        "the call taken over for " <> call_id <> " has no events: " <> reason,
      )
      None
    }
  }
}

/// What a takeover subscribes with: the caller's own events, and those of a
/// leg bridged to the caller.
pub fn interest(account_id: String, call_id: String) -> events.Interest {
  events.Interest(..events.account(account_id), carrying: [
    events.CallId(call_id),
    events.OtherLeg(call_id),
  ])
}

fn unwatch(watching: Option(events.Subscription)) -> Nil {
  case watching {
    Some(subscription) -> events.off(subscription)
    None -> Nil
  }
}
