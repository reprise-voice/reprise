//// A supervisor's pickup: a waiting caller rung through to the supervisor's
//// own phone, from inside the dispatcher that holds the caller.
////
//// It is an offer like an agent's, made with the same machinery -- the
//// caller's own control queue, the bridge that interrupts the hold music and
//// keeps it playing as the ringback, the legs named before they ring -- and
//// held in `State.offers` like one, which is what keeps every agent off the
//// caller while the supervisor's phone rings: the pass offers nobody a
//// caller who has an offer. `State.pickups` says which offers are a
//// supervisor's, and their replies come here instead of to `offers`.
////
//// What is different is what the replies mean, because the supervisor is
//// not an agent of the queue, or is one who did not take this caller from
//// it:
////
//// - The caller is settled on the answer and nowhere else, as for an agent,
////   and `member_connected` goes to the caller's action and the exchange.
////   The record's `agent_id` is whoever answered and `picked_up` says it was
////   a pickup. No agent counter moves, no `agent_answered` or
////   `agent_wrapup` is published, no wrap-up starts, the login lamp is left
////   alone and no strategy is told anything.
//// - A supervisor who does not answer, is busy, rejects, or whose ring could
////   not start has missed nothing: no miss, no delay. The offer is dropped
////   and the caller is back to waiting, offered to the next agent free on
////   the pass that follows.
//// - A caller who hangs up while the supervisor's phone rings leaves, as
////   they do from an agent's ring.
////
//// The ring is not started unless the caller is waiting in the queue the
//// request named, is not being rung for already, and the supervisor is not
//// already ringing for or talking to a caller of this account. Every one of
//// those is answered to Crossbar, so that a `202` means the phone is ringing
//// and nothing else does.
////
//// A ring that starts is answered for only once the offer says what came of
//// it: `OfferRinging`, its bridge out on the caller's channel, is `Ringing`;
//// a `Failed` before that is `NotStarted` with the offer's reason -- the
//// phones built to no endpoint on the caller's call (`no_endpoints`: on
//// do not disturb, disabled, `exclude_from_queues`, or the caller's own),
//// the bridge not sent, the call's events not had. An offer process that
//// ends without a word is `NotStarted` too, and a caller who leaves first
//// is `NotWaiting`. A bridge that goes out after the deadline the question
//// came with has nobody to tell: its ring is called off at once, which
//// leaves the caller waiting as a supervisor who did not answer does.

import callcenter/closed
import callcenter/dispatcher/offers
import callcenter/dispatcher/publish
import callcenter/dispatcher/settings
import callcenter/dispatcher/state.{
  type Offer, type State, type Wait, Offer, Pickup, State, is_pickup_offer,
}
import callcenter/records
import callcenter/system
import callcenter/types.{
  type EndResult, type OfferId, type OfferReply, Answered, Busy, CallerGone,
  Completed, Ended, Failed, FailedBridge, Hangup, OfferId, OfferNoAnswer,
  OfferRequest, OfferRinging, OfferSettings, Rejected,
}
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/erlang/reference
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kazoo/doc

/// How long the supervisor's phones ring before the caller goes back to
/// waiting for an agent.
pub const ring_timeout_s = 30

/// What Crossbar asks the dispatcher: ring these phones of the supervisor
/// for this caller.
pub type Request {
  Request(
    queue_id: String,
    call_id: String,
    /// Who answers: the supervisor's user id, or the owner of the device
    /// they named, or the device itself when nobody owns it. It is the
    /// `Agent-ID` the phones are rung with and the record's `agent_id`.
    supervisor_id: String,
    /// What the request named, `device` or `user`, and its id.
    target_type: String,
    target_id: String,
    /// The phones to ring: the device named, or every device the user
    /// owns that Crossbar found would ring.
    device_ids: List(String),
  )
}

/// What the dispatcher did about it.
pub type Answer {
  /// The supervisor's phones are ringing for the caller, for this long.
  Ringing(ring_timeout_s: Int)
  /// Nobody with that call id is waiting in that queue here.
  NotWaiting
  /// The caller is being rung for already: an agent's phone, or another
  /// supervisor's.
  BeingOffered
  /// The supervisor is ringing for, or talking to, another caller of the
  /// account already.
  SupervisorBusy
  /// The ring could not be started.
  NotStarted(reason: String)
  /// The question arrived after whoever asked had stopped waiting for the
  /// answer, and nothing was done.
  TooLate
}

// --- Starting --------------------------------------------------------------

/// Ring the supervisor for the caller, if the caller can be rung for, and
/// tell `done` what came of it: at once when nothing was started, and when
/// the offer has said so otherwise. `answer_by` is the monotonic millisecond
/// past which nobody is waiting for the answer.
pub fn start(
  state: State,
  request: Request,
  now: Int,
  answer_by: Int,
  done: Subject(Answer),
) -> State {
  let call_id = request.call_id
  let refuse = fn(answer) {
    process.send(done, answer)
    state
  }
  case dict.get(state.waiting, call_id) {
    Ok(wait) if wait.member.queue_id == request.queue_id ->
      case
        dict.has_key(state.leaving, call_id),
        dict.has_key(state.offers, call_id),
        offers.in_offer(state, request.supervisor_id),
        request.device_ids
      {
        // Being taken out of the queue: as good as gone.
        True, _, _, _ -> refuse(NotWaiting)
        _, True, _, _ -> refuse(BeingOffered)
        _, _, True, _ -> refuse(SupervisorBusy)
        _, _, _, [] -> refuse(NotStarted("no_devices"))
        False, False, False, _devices ->
          ring(state, wait, request, now, answer_by, done)
      }
    _elsewhere -> refuse(NotWaiting)
  }
}

/// What `done` is told, from what the offer said: `Ok` with the ring's
/// timeout is ringing; `Error` is why not, and a caller who left is not
/// waiting.
fn teller(done: Subject(Answer)) -> fn(Result(Int, String)) -> Nil {
  fn(result) {
    process.send(done, case result {
      Ok(ring_timeout_s) -> Ringing(ring_timeout_s)
      Error(reason) if reason == not_waiting -> NotWaiting
      Error(reason) -> NotStarted(reason)
    })
  }
}

/// Why nothing rang, when the caller left before the ring was out.
const not_waiting = "not_waiting"

/// Why nothing rang, when the offer's process ended without a word.
pub const offer_down = "offer_down"

fn ring(
  state: State,
  wait: Wait,
  request: Request,
  now: Int,
  answer_by: Int,
  done: Subject(Answer),
) -> State {
  let member = wait.member
  let queue = settings.for_queue(state.config, member.queue_id)
  let id = OfferId(call_id: member.call_id, serial: reference.new())
  let asked =
    OfferRequest(
      member: member,
      id: id,
      agents: [request.supervisor_id],
      settings: OfferSettings(
        ring_timeout_s: ring_timeout_s,
        cid_prefix: queue.cid_prefix,
        record: queue.record,
        outbound_caller_id_name: queue.outbound_caller_id_name,
        outbound_caller_id_number: queue.outbound_caller_id_number,
        hold_media: queue.hold_media,
      ),
      reply_to: state.replies,
      devices: Some(request.device_ids),
    )
  case state.start_offer(asked) |> result.map(offers.monitored) {
    Error(reason) -> {
      system.log_error(
        "could not ring supervisor "
        <> request.supervisor_id
        <> " for call "
        <> member.call_id
        <> ": "
        <> reason,
      )
      process.send(done, NotStarted(reason))
      state
    }
    Ok(pid) -> {
      system.log(
        "ringing supervisor "
        <> request.supervisor_id
        <> " ("
        <> request.target_type
        <> " "
        <> request.target_id
        <> ") for call "
        <> member.call_id
        <> " in queue "
        <> member.queue_id,
      )
      records.pickup_offered(member, request.supervisor_id, now, id)
      let offer =
        Offer(
          id: id,
          queue_id: member.queue_id,
          member: member,
          agents: [request.supervisor_id],
          ringing: [request.supervisor_id],
          started_at: now,
          ceiling: now + ring_timeout_s + state.config.offer_grace_s,
          connected: None,
          pid: Some(pid),
          rung: False,
          called_off: False,
        )
      State(
        ..state,
        offers: dict.insert(state.offers, member.call_id, offer),
        busy: offers.hold(state, id, [request.supervisor_id]),
        pickups: dict.insert(
          state.pickups,
          member.call_id,
          Pickup(
            id: id,
            target_type: request.target_type,
            target_id: request.target_id,
            tell: Some(teller(done)),
            answer_by: answer_by,
          ),
        ),
      )
    }
  }
}

/// Tell whoever asked for a pickup what came of it, once: nothing when they
/// have been told already, or the pickup is gone.
fn tell(state: State, id: OfferId, result: Result(Int, String)) -> State {
  case dict.get(state.pickups, id.call_id) {
    Ok(Pickup(tell: Some(tell), ..) as pickup) if pickup.id == id -> {
      tell(result)
      State(
        ..state,
        pickups: dict.insert(
          state.pickups,
          id.call_id,
          Pickup(..pickup, tell: None),
        ),
      )
    }
    _told_or_gone -> state
  }
}

/// The offer says its bridge is out. Whoever asked is told the phones are
/// ringing -- unless the deadline they asked with has passed, when nobody is
/// listening and Crossbar has answered that nothing rang. That is the
/// `True`: the ring is to be called off, and ends as a supervisor's who did
/// not answer.
fn out(state: State, offer: Offer) -> #(State, Bool) {
  case dict.get(state.pickups, offer.member.call_id) {
    Ok(Pickup(tell: Some(_), answer_by: answer_by, ..) as pickup)
      if pickup.id == offer.id
    ->
      case monotonic_ms() > answer_by {
        False -> #(tell(state, offer.id, Ok(ring_timeout_s)), False)
        True -> {
          system.log_error(
            "the pickup of call "
            <> offer.member.call_id
            <> " was out after its requester stopped waiting: calling it off",
          )
          #(tell_nobody(state, offer.id), True)
        }
      }
    _told_or_gone -> #(state, False)
  }
}

/// Forget whoever asked without telling them: they stopped waiting.
fn tell_nobody(state: State, id: OfferId) -> State {
  case dict.get(state.pickups, id.call_id) {
    Ok(pickup) if pickup.id == id ->
      State(
        ..state,
        pickups: dict.insert(
          state.pickups,
          id.call_id,
          Pickup(..pickup, tell: None),
        ),
      )
    _gone -> state
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

// --- Which offers are pickups -----------------------------------------------

/// Whether a reply naming this offer is a pickup's.
pub fn holds(state: State, id: OfferId) -> Bool {
  is_pickup_offer(state, id)
}

/// Whether an offer this dispatcher holds is a pickup.
pub fn is_pickup(state: State, offer: Offer) -> Bool {
  holds(state, offer.id)
}

/// Make an offer this dispatcher holds a pickup: one that a node that died
/// left ringing or answered, which `dispatcher/arrival` took over from the
/// caller's record. Its replies come here from now on, so it ends as a
/// pickup and not as an agent's queue call. Who asked for it went with that
/// node, so the target is only the supervisor it names.
pub fn adopt(state: State, offer: Offer) -> State {
  State(
    ..state,
    pickups: dict.insert(
      state.pickups,
      offer.member.call_id,
      // Nobody here asked for it, so nobody waits to be told how it went
      // and no deadline applies to its ring.
      Pickup(
        id: offer.id,
        target_type: "",
        target_id: supervisor_of(offer),
        tell: None,
        answer_by: 0,
      ),
    ),
  )
}

/// Forget the pickups whose offer has gone some other way: the caller left
/// and `offers` gave the ring up, or the queue was deleted. Whoever is still
/// waiting to hear about one hears that the caller is not waiting.
pub fn prune(state: State) -> State {
  let #(kept, gone) =
    dict.to_list(state.pickups)
    |> list.partition(fn(entry) {
      let #(call_id, pickup) = entry
      case dict.get(state.offers, call_id) {
        Ok(offer) -> offer.id == pickup.id
        Error(Nil) -> False
      }
    })
  list.each(gone, fn(entry) {
    case entry.1.tell {
      Some(tell) -> tell(Error(not_waiting))
      None -> Nil
    }
  })
  State(..state, pickups: dict.from_list(kept))
}

// --- Replies ---------------------------------------------------------------

/// What the offer process said about a pickup. A reply to a pickup this
/// dispatcher no longer holds is dropped, as `offers.replied` drops one.
pub fn replied(state: State, id: OfferId, reply: OfferReply) -> State {
  case dict.get(state.offers, id.call_id) {
    Ok(offer) if offer.id == id ->
      case reply {
        OfferRinging(_supervisor) -> {
          let #(state, late) = out(state, offer)
          rung(state, offer, late)
        }
        // An answer to a ring this dispatcher has called off is not one, as
        // for an agent's (`offers.replied`): the unbridge parks the caller
        // and cuts the bridge, the offer takes the answer back once it hears
        // the call-off, and its last word gives the ring up below.
        Answered(named, _agent_call_id, _at) if offer.called_off -> {
          system.log(
            "call "
            <> id.call_id
            <> " was picked up by "
            <> named
            <> " as the ring was called off: not an answer",
          )
          state
        }
        Answered(_named, agent_call_id, at) ->
          tell(state, id, Ok(ring_timeout_s))
          |> answered(offer, agent_call_id, at)
        // A ring called off ends in whatever the switch says a cancelled
        // bridge ends in, an end included when it crossed an answer.
        Ended(_result, _at) if offer.called_off && offer.connected == None ->
          unanswered(state, offer, "cancelled")
        OfferNoAnswer(_) ->
          tell(state, id, Error("no_answer"))
          |> unanswered(offer, "no_answer")
        Busy(_) -> tell(state, id, Error("busy")) |> unanswered(offer, "busy")
        Rejected(_) ->
          tell(state, id, Error("reject")) |> unanswered(offer, "reject")
        Failed(reason) -> {
          system.log_error(
            "the pickup of call " <> id.call_id <> " failed: " <> reason,
          )
          tell(state, id, Error(reason)) |> unanswered(offer, "cancelled")
        }
        Ended(result, at) -> ended(state, offer, result, at)
        // The caller hung up while the supervisor's phone rang.
        CallerGone -> {
          offers.close_if_superseded(state, offer, answered: False)
          tell(state, id, Error(not_waiting))
          |> forget(offer)
          |> offers.leave(id.call_id, Hangup)
        }
      }
    _gone -> {
      system.log_debug(
        "dropping a reply to a pickup of call "
        <> id.call_id
        <> " that is not held: "
        <> string.inspect(reply),
      )
      state
    }
  }
}

/// The bridge is out on the caller's channel. The caller's action hears
/// that somebody is ringing for them, as it does for an agent, which stops
/// its no-agent clock and makes leaving call the ring off. A ring called off
/// before it was out is unbridged now, the other half of
/// `offers.call_off_once`; one out after its requester stopped waiting
/// (`late`) is called off now, as a release calls one off.
fn rung(state: State, offer: Offer, late: Bool) -> State {
  let ringing = Offer(..offer, rung: True)
  let state =
    State(
      ..state,
      offers: dict.insert(state.offers, offer.member.call_id, ringing),
    )
  case offer.called_off, offer.rung, late {
    True, False, _ -> {
      offers.unbridge(state, offer)
      state
    }
    True, True, _ -> state
    False, _, True -> offers.call_off_once(state, ringing)
    False, _, False -> {
      publish.call(state.config.account_id, "member_offer", offer.member, [
        #("Agent-IDs", doc.List(list.map(offer.agents, doc.String))),
        #("Offer-Timeout", doc.Int(ring_timeout_s)),
      ])
      state
    }
  }
}

/// The supervisor has the caller. The member is settled here, as an agent's
/// answer settles it, and nothing an agent's answer counts is counted.
fn answered(
  state: State,
  offer: Offer,
  agent_call_id: String,
  at: Int,
) -> State {
  let member = offer.member
  let supervisor = supervisor_of(offer)
  // The delivery the shard holds now, which a caller delivered again while
  // the supervisor's phone rang has replaced; the records stay the offer's.
  state.config.settle(offers.held(state, member))
  records.picked_up(member, supervisor, agent_call_id, at)
  records.offer_outcome(member, supervisor, "answered")
  offers.close_if_superseded(state, offer, answered: True)
  publish.call(state.config.account_id, "member_connected", member, [
    #("Agent-ID", doc.String(supervisor)),
    #("Agent-Call-ID", doc.String(agent_call_id)),
    #("Answered-Timestamp", doc.Int(at)),
  ])
  system.log(
    "supervisor " <> supervisor <> " picked up call " <> member.call_id,
  )
  State(
    ..state,
    waiting: dict.delete(state.waiting, member.call_id),
    leaving: dict.delete(state.leaving, member.call_id),
    offers: dict.insert(
      state.offers,
      member.call_id,
      Offer(
        ..offer,
        ringing: [],
        connected: Some(#(supervisor, agent_call_id, at)),
      ),
    ),
  )
}

/// The supervisor's phone came back without them: the caller is waiting as
/// they were, and nobody missed anything. A caller whose queue was deleted
/// while it rang leaves now that the ring is over, unless they have moved on
/// to another queue since (`offers.leave_if_leaving`).
fn unanswered(state: State, offer: Offer, outcome: String) -> State {
  records.offer_outcome(offer.member, supervisor_of(offer), outcome)
  offers.close_if_superseded(state, offer, answered: False)
  forget(state, offer)
  |> offers.leave_if_leaving(offer.member.call_id)
}

/// The picked-up call is over: the record closed and `member_result`
/// published, with no agent counters and no wrap-up.
fn ended(state: State, offer: Offer, result: EndResult, at: Int) -> State {
  let member = offer.member
  records.ended(member, result, at)
  closed.note(member, result, at)
  publish.call(state.config.account_id, "member_result", member, [
    #("Result", doc.String(records.result_to_string(result))),
    #("Ended-Timestamp", doc.Int(at)),
    #("Agent-ID", doc.String(supervisor_of(offer))),
  ])
  forget(state, offer)
}

/// The pickup is over, one way or another: out of the offers, the
/// supervisor free, and not a pickup any more.
fn forget(state: State, offer: Offer) -> State {
  let call_id = offer.member.call_id
  let supervisor = supervisor_of(offer)
  // Whoever asked has been told by now on every way here but a ring the
  // supervisor's release let go before it was out.
  let state = tell(state, offer.id, Error("called_off"))
  State(
    ..state,
    offers: dict.delete(state.offers, call_id),
    busy: offers.release(state, offer.id, [supervisor]),
    pickups: dict.delete(state.pickups, call_id),
  )
}

fn supervisor_of(offer: Offer) -> String {
  case offer.agents {
    [supervisor, ..] -> supervisor
    [] -> ""
  }
}

// --- A pickup nobody is answering for --------------------------------------

/// A pickup's process has ended. Nothing when the process was not a
/// pickup's, which is for `offers.down`.
pub fn down(state: State, pid: Pid, reason: String) -> Result(State, Nil) {
  case
    dict.values(state.offers)
    |> list.find(fn(offer) { offer.pid == Some(pid) && is_pickup(state, offer) })
  {
    Error(Nil) -> Error(Nil)
    Ok(offer) -> {
      system.log_error(
        "the pickup of call "
        <> offer.member.call_id
        <> " by "
        <> supervisor_of(offer)
        <> " ended without a reply: "
        <> reason,
      )
      tell(state, offer.id, Error(offer_down))
      |> closed_unwatched(offer, state.config.now())
      |> Ok
    }
  }
}

/// A pickup whose process is gone without its last word, found by the tick
/// past its ceiling: what `down` does, for the one whose monitor was lost.
pub fn expired(state: State, offer: Offer, now: Int) -> State {
  system.log_error(
    "the pickup of call "
    <> offer.member.call_id
    <> " by "
    <> supervisor_of(offer)
    <> " has nothing watching it: closing it",
  )
  tell(state, offer.id, Error(offer_down))
  |> closed_unwatched(offer, now)
}

/// Before an answer the ring still going is called off, once, and the
/// caller waits on; after one the call is closed as one whose end was lost.
fn closed_unwatched(state: State, offer: Offer, now: Int) -> State {
  case offer.connected {
    None -> {
      offers.unbridge_once(state, offer)
      unanswered(state, offer, "cancelled")
    }
    Some(_answered) -> ended(state, offer, FailedBridge, now)
  }
}

/// `release_agent` for a supervisor whose pickup this dispatcher holds: a
/// ring still going is called off as an agent's is (`offers.call_off_once`:
/// unbridged once, and its process told, so that an answer the call-off
/// crosses is not taken) and held until it says it is over, one with
/// nothing left to say is dropped, and a call is ended. Nothing when the
/// agent is in no pickup, which is for `offers.release_agent`.
pub fn release(state: State, agent_id: String) -> Result(State, Nil) {
  case offers.offer_of(state, agent_id) {
    Ok(offer) ->
      case is_pickup(state, offer) {
        False -> Error(Nil)
        True ->
          Ok(case offer.connected, running(offer) {
            None, True -> offers.call_off_once(state, offer)
            None, False -> unanswered(state, offer, "cancelled")
            Some(_), _ -> ended(state, offer, Completed, state.config.now())
          })
      }
    Error(Nil) -> Error(Nil)
  }
}

fn running(offer: Offer) -> Bool {
  case offer.pid {
    Some(pid) -> process.is_alive(pid)
    None -> False
  }
}
