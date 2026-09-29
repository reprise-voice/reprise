//// The offers in flight, from the moment one is asked for to the moment its
//// caller is settled: sent, rung, answered, missed, ended, or abandoned
//// because the caller left.
////
//// An agent is in at most one offer at a time, which `State.busy` holds and
//// every offer checks. The reply from the caller's actor --
//// `callcenter/call/actor` on a node, a fake in the tests -- is matched to
//// its offer here and only here, by the `OfferId` made when the offer was
//// asked for: the caller's call id says which offer the dispatcher holds for
//// them now, and the reference says whether that is the offer replying.
////
//// The actor decides the ring: whichever of an answer, the caller leaving
//// and a call-off it handles first stands, and this module takes what it
//// says. So an answer to a ring this dispatcher has called off is an
//// answer, and a caller who left is told here by the shard, once the actor
//// has decided they did.

import callcenter/activity
import callcenter/availability.{NoAnswerRule}
import callcenter/call/talk
import callcenter/closed
import callcenter/dispatcher/memo
import callcenter/dispatcher/publish
import callcenter/dispatcher/settings.{type AgentSettings, type QueueSettings}
import callcenter/dispatcher/state.{
  type Offer, type State, type Wait, Offer, State, Wait, held_offer,
  is_pickup_offer, offer_of as holding,
}
import callcenter/dispatcher/view
import callcenter/presence
import callcenter/records
import callcenter/system
import callcenter/types.{
  type CancelReason, type EndResult, type Member, type OfferId, type OfferReply,
  Answered, Busy, Completed, Ended, Failed, FailedBridge, Hangup, Member,
  OfferId, OfferNoAnswer, OfferRequest, OfferRinging, OfferSettings,
  QueueDeleted, Rejected, Sequential, Simultaneous, Transfer,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/erlang/reference
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo

/// How long an agent whose offer could not even ring is left alone. Not a
/// miss and not their delay: an endpoint with nothing registered fails at
/// once, and a queue whose every agent is like that would otherwise offer,
/// fail and offer again as fast as the replies come back.
const failed_offer_delay_s = 5

/// The failure an offer whose process ended before it said how its ring
/// went is closed with. See `down`.
pub const offer_crashed = "offer_crashed"

/// How long an agent `max_no_answer` stood down is held back while the
/// write that stands them down lands, if its `agent_availability` is never
/// heard. See `stand_down`.
pub const stand_down_hold_s = 30

// --- Sending ---------------------------------------------------------------

/// Ask for the offer, and believe it has begun until told otherwise.
///
/// The agents are marked busy and ringing before the caller's actor has said
/// anything, which is the point: the next caller's pass in this same message
/// must not pick the same agent. A request that could not even be started
/// undoes that at once.
pub fn send(
  state: State,
  wait: Wait,
  queue: QueueSettings,
  offer: types.Offer,
  now: Int,
) -> State {
  let ringing = settings.ringing(offer, queue)
  let ring_timeout = settings.ring_timeout(state.config, ringing, queue)
  let id = OfferId(call_id: wait.member.call_id, serial: reference.new())
  let request =
    OfferRequest(
      member: wait.member,
      id: id,
      agents: ringing,
      settings: OfferSettings(
        ring_timeout_s: ring_timeout,
        cid_prefix: queue.cid_prefix,
        record: queue.record
          || settings.any_agent_records(state.config, ringing),
        outbound_caller_id_name: queue.outbound_caller_id_name,
        outbound_caller_id_number: queue.outbound_caller_id_number,
        hold_media: queue.hold_media,
      ),
      reply_to: state.replies,
      devices: None,
    )
  case state.start_offer(request) |> result.map(monitored) {
    Error(reason) -> {
      system.log_error(
        "could not offer call "
        <> wait.member.call_id
        <> " to "
        <> string.join(ringing, ", ")
        <> ": "
        <> reason,
      )
      state
    }
    Ok(pid) -> {
      // The caller's action is not told yet: `member_offer` waits for the
      // offer to say its bridge went out (`replied`, `OfferRinging`).
      list.each(ringing, fn(agent_id) {
        activity.set_offering(
          state.config.account_id,
          agent_id,
          ring_timeout + state.config.offer_grace_s,
        )
        records.offered(wait.member, agent_id, now, id)
        publish.agent(state.config.account_id, "agent_offer", agent_id, [
          #("Queue-ID", doc.String(wait.member.queue_id)),
          #("Call-ID", doc.String(wait.member.call_id)),
          #("Offer-Timeout", doc.Int(ring_timeout)),
        ])
      })
      State(
        ..state,
        offers: dict.insert(
          state.offers,
          wait.member.call_id,
          Offer(
            id: id,
            queue_id: queue.id,
            member: wait.member,
            agents: ringing,
            ringing: ringing,
            started_at: now,
            ceiling: now + ring_timeout + state.config.offer_grace_s,
            connected: None,
            pid: Some(pid),
            rung: False,
            called_off: False,
          ),
        ),
        busy: hold(state, id, ringing),
        // Only an ordered offer is a turn down a list. A ring of everybody
        // asks for everybody every time, so it keeps no list and clears one
        // a strategy the queue was moved off left behind.
        waiting: dict.insert(
          state.waiting,
          wait.member.call_id,
          Wait(..wait, tried: case offer {
            Sequential(_) -> list.append(wait.tried, ringing)
            Simultaneous(_) -> []
          }),
        ),
      )
      // The turn is taken as the phones start ringing, in ring order, and
      // not as they stop: the outcomes come back in whichever order the
      // phones answer.
      |> memo.remember(queue, memo.each(ringing, types.Offered))
    }
  }
}

// --- Departures ------------------------------------------------------------

/// A caller has left without an agent: settle the message, close the
/// document, and call off a ring going on for them (`abandon_offer`).
///
/// Every reason but one is the caller's own doing, and their actor already
/// knows: it decided it. `QueueDeleted` is this dispatcher's, and the actor
/// is told as the queue goes (`queue_deleted`); whoever watches the call
/// hears it as a `member_result` whose result is the reason.
pub fn leave(state: State, call_id: String, reason: CancelReason) -> State {
  case dict.get(state.waiting, call_id) {
    Error(_) -> state
    Ok(wait) -> {
      let now = state.config.now()
      state.config.settle(wait.member)
      records.cancelled(wait.member, reason, now)
      case reason {
        QueueDeleted ->
          publish.call(state.config.account_id, "member_result", wait.member, [
            #("Result", doc.String(records.reason_to_string(reason))),
            #("Ended-Timestamp", doc.Int(now)),
          ])
        _callers_own -> Nil
      }
      // The offer is abandoned while the caller is still waiting, so that
      // its end can tell whether it was for the passage they are leaving or
      // for one they had already left (`close_if_superseded`).
      let state = abandon_offer(state, call_id, reason)
      State(
        ..state,
        waiting: dict.delete(state.waiting, call_id),
        actors: dict.delete(state.actors, call_id),
        presenting: dict.delete(state.presenting, call_id),
      )
    }
  }
}

/// A queue has been deleted: every caller waiting in it leaves it, now, on
/// `QueueDeleted`, and their actor takes them out of it on `no_agents`.
///
/// The actor sequences the departure itself -- a ring going on for them
/// called off, their legs hung up, the channel's commands run out before
/// the callflow is told to go on -- so the dispatcher lets them go at once
/// and frees whoever was being rung for them. An agent who answered before
/// the actor heard of the deletion has the caller: the actor bridges them,
/// and the call goes on outside the queue that no longer exists.
pub fn queue_deleted(state: State, queue_id: String) -> State {
  let callers =
    dict.values(state.waiting)
    |> list.filter(fn(wait) { wait.member.queue_id == queue_id })
    |> list.map(fn(wait) { wait.member })
  case callers {
    [] -> Nil
    _ ->
      system.log(
        "queue "
        <> queue_id
        <> " of account "
        <> state.config.account_id
        <> " was deleted: taking "
        <> string.join(list.map(callers, fn(member) { member.call_id }), ", ")
        <> " out of it",
      )
  }
  list.fold(callers, state, fn(state, member) {
    state.config.calls.queue_gone(member)
    leave(state, member.call_id, QueueDeleted)
  })
}

/// Call off an offer's ring and keep the offer until it replies: the one
/// way any ring is called off, and once per offer however many ask.
///
/// The caller's actor hangs the offer's legs up by name, and any of them
/// that turns up later, and says `Failed(called_off)` once the ring is over.
/// Nothing is sent the caller: they stay on hold, as they were. An agent
/// who answered before the call-off reached the actor has the caller, and
/// the actor's `Answered` says so.
///
/// Sent through the member held for the caller now (`held`), which names
/// the passage their actor is running.
///
/// A supervisor's pickup is called off the same way (`pickup.release`).
pub fn call_off_once(state: State, offer: Offer) -> State {
  case offer.called_off {
    True -> state
    False -> {
      state.config.calls.call_off(held(state, offer.member), offer.id)
      State(
        ..state,
        offers: dict.insert(
          state.offers,
          offer.member.call_id,
          Offer(..offer, called_off: True),
        ),
      )
    }
  }
}

/// The offer for a caller who has left: its ring is called off, and the
/// agents go free at once.
///
/// A caller who left on their own -- a key, a clock, hanging up -- left
/// because their actor said so, and it called their ring off as it did.
/// One taken out by somebody else -- by hand, or seen gone by the activity
/// actor before the actor said anything -- has the call-off sent here as
/// well, which an actor that has already let the ring go takes as nothing.
/// A caller whose channel has gone (`Hangup`) has no ring left to call off,
/// and an offer already called off has been told.
///
/// The offer is not held until the actor replies, as a released agent's
/// is: the dispatcher holds one offer a caller, and a caller timing out of
/// one queue into an overflow queue of the same account would wait on it
/// for the overflow's first ring. The actor owns what is left of the
/// call-off, and its reply is dropped when it comes.
fn abandon_offer(state: State, call_id: String, reason: CancelReason) -> State {
  case dict.get(state.offers, call_id) {
    Error(_) -> state
    Ok(offer) -> {
      case offer.connected, reason, offer.called_off {
        None, Hangup, _ | None, _, True | Some(_), _, _ -> Nil
        None, _, False ->
          state.config.calls.call_off(held(state, offer.member), offer.id)
      }
      give_up(state, offer)
    }
  }
}

/// Drop an offer and free its agents, with no miss and no delay: its caller
/// left, or its ring was called off.
///
/// A supervisor's pickup is dropped the same way and moves nothing of an
/// agent's (`dispatcher/pickup`): the supervisor's activity is left as it
/// is and the queue's strategy hears nothing. The pickup itself is
/// forgotten by `pickup.prune`, which tells whoever still waits on it that
/// the caller is not waiting.
pub fn give_up(state: State, offer: Offer) -> State {
  // The agents whose activity is cleared, and those whose phones were still
  // ringing, which have had their turn.
  let #(agents, ringing) = case is_pickup_offer(state, offer.id) {
    True -> #([], [])
    False -> #(offer.agents, offer.ringing)
  }
  list.each(agents, fn(agent_id) {
    activity.clear(state.config.account_id, agent_id)
  })
  list.each(offer.agents, fn(agent_id) {
    records.offer_outcome(offer.member, agent_id, "cancelled")
  })
  close_if_superseded(state, offer, answered: False)
  State(
    ..state,
    offers: dict.delete(state.offers, offer.member.call_id),
    busy: release(state, offer.id, offer.agents),
  )
  // The agents whose phones were still ringing have had their turn, even
  // though nobody will ever know how it would have gone.
  |> memo.remember(
    settings.for_queue(state.config, offer.queue_id),
    memo.each(ringing, types.Abandoned),
  )
  |> retell(offer)
}

// --- A passage the caller has moved on from --------------------------------

/// Close, as a `transfer`, the passage an offer's end leaves open with
/// nothing else to close it (`superseded_passage`).
pub fn close_if_superseded(
  state: State,
  offer: Offer,
  answered answered: Bool,
) -> Nil {
  let waiting =
    dict.get(state.waiting, offer.member.call_id)
    |> result.map(fn(wait) { wait.member })
  case superseded_passage(offer.member, waiting, answered: answered) {
    None -> Nil
    Some(passage) -> {
      system.log(
        "call "
        <> passage.call_id
        <> " has moved on from its passage in queue "
        <> passage.queue_id
        <> ": closing it as a transfer",
      )
      records.cancelled(passage, Transfer, state.config.now())
    }
  }
}

/// Of the passage an offer was made for and the passage its caller is
/// waiting in now, the one that the end of the offer leaves open with
/// nothing else to close it, if they are not the same.
///
/// A caller who moves on to another queue while an offer of the first is in
/// flight has a passage of each: the new one is opened as they arrive in the
/// second queue, and the one they left is not closed then, so that the
/// offer's outcome goes on being written to it (`arrival.superseded`).
///
/// - An offer that ends unanswered -- missed, failed, given up on -- has
///   written its outcome to its own passage, which the caller has left:
///   that one is closed. The caller waits on in the new one.
/// - An answer is the answer of the passage the agent was rung for, which
///   is the offer's: its record gets the agent, the answer and later the
///   end, as any answered passage does. The caller never reached an agent
///   through the new queue, and nothing will ever end that passage, so it
///   is the one closed.
///
/// A caller not waiting, or waiting in the offer's own passage, leaves
/// nothing to close.
@internal
pub fn superseded_passage(
  offered: Member,
  waiting: Result(Member, Nil),
  answered answered: Bool,
) -> Option(Member) {
  case waiting {
    Error(Nil) -> None
    Ok(current) ->
      case records.same_passage(offered, current), answered {
        True, _ -> None
        False, False -> Some(offered)
        False, True -> Some(current)
      }
  }
}

/// `release_agent`: take the agent out of the offer they are in.
///
/// An offer still ringing has its ring called off (`call_off_once`) and is
/// held until the caller's actor says the ring is over, as any other is.
/// Dropping it at once freed the agent while their phone rang on: if they
/// then picked up, the answer was dropped as stale and the caller, talking
/// to them, could be offered to somebody else. The reply that ends the ring
/// frees everybody it rang without a miss or a delay, and the caller stays
/// in the queue for the next pass. An agent who answered before the
/// call-off reached the actor has the caller, and the answer stands. An
/// offer whose actor is gone has nothing left to reply, and is given up on
/// at once.
///
/// An answered one is ended here, now, as the sweep ends a call whose
/// caller has gone, so that its record is closed and the agent's counters
/// have the call. The wrap-up that starts goes with everything else the
/// release clears.
pub fn release_agent(state: State, agent_id: String) -> State {
  case offer_of(state, agent_id) {
    Error(Nil) -> state
    Ok(offer) -> {
      system.log(
        "agent "
        <> agent_id
        <> " released by hand from the offer of call "
        <> offer.member.call_id
        <> " to "
        <> string.join(offer.agents, ", "),
      )
      case offer.connected, running(offer) {
        None, True -> call_off_once(state, offer)
        None, False -> give_up(state, offer)
        Some(_), _ -> ended(state, offer, Completed, state.config.now())
      }
    }
  }
}

/// Whether the offer's actor is still there to reply.
fn running(offer: Offer) -> Bool {
  case offer.pid {
    Some(pid) -> process.is_alive(pid)
    None -> False
  }
}

/// Whether the agent is in an offer this dispatcher still holds: one whose
/// ring is being called off keeps them until it replies.
pub fn in_offer(state: State, agent_id: String) -> Bool {
  result.is_ok(offer_of(state, agent_id))
}

// --- Who is in which offer -------------------------------------------------

/// The offer an agent is in: `state.offer_of`, which the view shares.
pub fn offer_of(state: State, agent_id: String) -> Result(Offer, Nil) {
  holding(state, agent_id)
}

/// `State.busy` with these agents in the offer `id`.
///
/// An agent already in another offer this dispatcher holds is in two things
/// at once: a ring a node that died left going, held until its ceiling, or
/// a call adopted for an agent this node has since rung. That is logged, and
/// the newer offer takes them; the older one's end does not free them
/// (`release`).
pub fn hold(
  state: State,
  id: OfferId,
  agents: List(String),
) -> Dict(String, OfferId) {
  hold_in(state.busy, state, id, agents)
}

fn hold_in(
  busy: Dict(String, OfferId),
  state: State,
  id: OfferId,
  agents: List(String),
) -> Dict(String, OfferId) {
  list.fold(agents, busy, fn(busy, agent_id) {
    case dict.get(busy, agent_id) {
      Ok(owner) if owner != id ->
        case held_offer(state, owner) {
          Ok(other) ->
            system.log(
              "agent "
              <> agent_id
              <> " is in the offer of call "
              <> other.member.call_id
              <> " and now in the offer of call "
              <> id.call_id
              <> " as well: held by the newer",
            )
          Error(Nil) -> Nil
        }
      _free_or_own -> Nil
    }
    dict.insert(busy, agent_id, id)
  })
}

/// `State.busy` with these agents let go by the offer `id`, which is ending
/// or has lost them.
///
/// Only an entry the offer owns is touched: an agent another offer took
/// since (`hold`) stays in it. An agent the offer owns who is also in
/// another offer still held goes back to that one rather than free, since
/// they are still in it.
pub fn release(
  state: State,
  id: OfferId,
  agents: List(String),
) -> Dict(String, OfferId) {
  list.fold(agents, state.busy, fn(busy, agent_id) {
    case dict.get(busy, agent_id) {
      Ok(owner) if owner == id ->
        case
          dict.values(state.offers)
          |> list.find(fn(other) {
            other.id != id && list.contains(other.agents, agent_id)
          })
        {
          Ok(other) -> dict.insert(busy, agent_id, other.id)
          Error(Nil) -> dict.delete(busy, agent_id)
        }
      _anothers_or_free -> busy
    }
  })
}

// --- A caller's actor ending ----------------------------------------------

/// Watch the caller's actor for as long as an offer of theirs is held.
///
/// Monitored and not linked: the actor runs under its shard's calls, so its
/// crash is not this dispatcher's, and a monitor is what tells this
/// dispatcher it happened. The `Down` comes back to the dispatcher as
/// `dispatcher.OfferDown` and goes to `down`.
pub fn monitored(pid: Pid) -> Pid {
  let _monitor = process.monitor(pid)
  pid
}

/// A caller's actor has ended.
///
/// Nearly always after its last reply about any offer, which it sent before
/// it exited and which therefore reached this dispatcher first: the offer
/// has been settled and is not held any more, and there is nothing to do
/// (`Error(Nil)`, and no pass).
///
/// An offer still held under that actor ended without its last word: the
/// actor crashed, or it was killed. Before an answer that is `Failed` -- nobody
/// missed anything, the agents are left alone for a moment, and the caller
/// is offered again. After one it is the end of a call nobody is watching
/// any more, closed as `FailedBridge`, the result for a call whose end was
/// lost; the agent's channels, which the activity actor still sees, keep
/// them out of the next offer for as long as they really are talking.
pub fn down(state: State, pid: Pid, reason: String) -> Result(State, Nil) {
  case
    dict.values(state.offers)
    |> list.find(fn(offer) { offer.pid == Some(pid) })
  {
    Error(Nil) -> Error(Nil)
    Ok(offer) -> Ok(lost(state, offer, reason))
  }
}

/// An offer held whose actor has ended without its last word, closed as
/// `down` closes it. The monitor's word is one way here; the other is the
/// tick finding an offer past its ceiling whose actor is already gone
/// while that word is still on its way (`timers.expire_offers`). Whichever
/// comes first closes the offer, and the other finds nothing held under
/// that actor.
pub fn lost(state: State, offer: Offer, reason: String) -> State {
  system.log_error(
    "offer for call "
    <> offer.member.call_id
    <> " to "
    <> string.join(offer.agents, ", ")
    <> " ended without a reply: "
    <> reason,
  )
  // A ring whose actor is gone has nobody left to hear an answer, and its
  // legs park until their `park_timeout` hangs them up.
  let told = case offer.connected {
    None -> Failed(offer_crashed)
    Some(_answered) -> Ended(FailedBridge, state.config.now())
  }
  replied(state, offer.id, told)
}

// --- Replies ---------------------------------------------------------------

/// What the caller's actor said about one offer.
pub fn replied(state: State, id: OfferId, reply: OfferReply) -> State {
  let call_id = id.call_id
  case dict.get(state.offers, call_id) {
    // An answer about a caller who has gone, or about an offer that was
    // already given up on. The agents were released with the offer.
    Error(_) -> state
    // An answer from an offer that is not the one held for this caller now:
    // one given up on or released by hand, or the ring of a queue the caller
    // has since left for another. What it says is about agents this
    // dispatcher has already let go, some of whom may be ringing for the
    // offer that took its place.
    Ok(offer) if offer.id != id -> {
      system.log_debug(
        "dropping a reply to an earlier offer of call "
        <> call_id
        <> ": "
        <> string.inspect(reply),
      )
      state
    }
    Ok(offer) ->
      case reply {
        OfferRinging(agents) -> {
          case offer.called_off || offer.rung {
            False -> tell_offered(state, offer, agents)
            True -> Nil
          }
          State(
            ..state,
            offers: dict.insert(
              state.offers,
              call_id,
              Offer(..offer, ringing: agents, rung: True),
            ),
          )
        }

        // An answer to a ring this dispatcher has called off is an answer
        // all the same: the actor had bridged the caller before the call-off
        // reached it, and the caller is talking to the agent.
        Answered(agent_id, agent_call_id, at) ->
          answered(state, offer, agent_id, agent_call_id, at)

        // A ring that was called off ends in whatever the actor says a
        // cancelled ring ends in, and none of it is anybody's miss. The end
        // of a call answered before the call-off is the end of a call.
        OfferNoAnswer(_)
          | Busy(_)
          | Rejected(_)
          | Failed(_)
          if offer.called_off
        -> give_up(state, offer)
        Ended(_, _) if offer.called_off && offer.connected == None ->
          give_up(state, offer)

        OfferNoAnswer(agents) -> missed(state, offer, agents, "no_answer")
        Busy(agent_id) -> missed(state, offer, [agent_id], "busy")
        Rejected(agent_id) -> missed(state, offer, [agent_id], "reject")

        Failed(reason) -> {
          system.log_error(
            "offer for call " <> call_id <> " failed: " <> reason,
          )
          // Not a miss: nothing rang, so nobody missed anything, and the
          // caller is offered again on the next pass. The agents are left
          // alone for a moment all the same, since whatever could not ring
          // just now will not ring on the next pass either.
          list.each(offer.agents, fn(agent_id) {
            activity.clear(state.config.account_id, agent_id)
          })
          close_if_superseded(state, offer, answered: False)
          let until = state.config.now() + failed_offer_delay_s
          State(
            ..state,
            offers: dict.delete(state.offers, call_id),
            busy: release(state, offer.id, offer.agents),
            delayed: list.fold(
              offer.agents,
              state.delayed,
              fn(delayed, agent_id) { dict.insert(delayed, agent_id, until) },
            ),
          )
          |> memo.remember(
            settings.for_queue(state.config, offer.queue_id),
            memo.each(offer.agents, types.Abandoned),
          )
          |> retell(offer)
        }

        Ended(result, at) -> ended(state, offer, result, at)

        // The dispatcher routes a presence to `arrival.present` before any
        // offer's reply is looked at.
        types.Present(_) -> state
      }
  }
}

/// An agent picked up. The passage answered is the offer's own, the one the
/// agent was rung for; a caller who had moved on to another queue while it
/// rang has that newer passage closed as a `transfer`
/// (`superseded_passage`).
fn answered(
  state: State,
  offer: Offer,
  agent_id: String,
  agent_call_id: String,
  at: Int,
) -> State {
  let member = offer.member
  // The member message is not settled yet: the call is the queue's until it
  // ends, and a node that dies meanwhile leaves it on the broker for the
  // next holder to take the call over. The delivery kept is the one held for
  // the caller now, which need not be the one the offer was made from
  // (`held`), and it is settled when the call ends (`ended`).
  let delivery = held(state, member).delivery
  records.answered(member, agent_id, agent_call_id, at)
  records.offer_outcome(member, agent_id, "answered")
  close_if_superseded(state, offer, answered: True)
  records.agent_answered(state.config.account_id, agent_id)
  publish.agent(state.config.account_id, "agent_answered", agent_id, [
    #("Queue-ID", doc.String(member.queue_id)),
    #("Call-ID", doc.String(member.call_id)),
    #("Agent-Call-ID", doc.String(agent_call_id)),
    #("Answered-Timestamp", doc.Int(at)),
  ])
  publish.call(state.config.account_id, "member_connected", member, [
    #("Agent-ID", doc.String(agent_id)),
    #("Agent-Call-ID", doc.String(agent_call_id)),
    #("Answered-Timestamp", doc.Int(at)),
  ])

  // Everybody else the offer was ringing has lost the race and goes free.
  let losers = list.filter(offer.agents, fn(other) { other != agent_id })
  list.each(losers, fn(other) { activity.clear(state.config.account_id, other) })

  State(
    ..state,
    waiting: dict.delete(state.waiting, member.call_id),
    offers: dict.insert(
      state.offers,
      member.call_id,
      Offer(
        ..offer,
        member: Member(..member, delivery: delivery),
        agents: [agent_id],
        ringing: [],
        connected: Some(#(agent_id, agent_call_id, at)),
      ),
    ),
    busy: release(state, offer.id, losers)
      |> hold_in(state, offer.id, [agent_id]),
    misses: dict.delete(state.misses, agent_id),
    lamps: presence.connected(state.lamps, agent_id, state.config.lamp),
  )
  // Every agent the offer rang has had their turn, the losers included, and
  // in the order they were rung: a cursor that stopped at the answerer would
  // ring the agent after them next, who may just have lost this race.
  |> memo.remember(
    settings.for_queue(state.config, offer.queue_id),
    list.map(offer.agents, fn(rung) {
      case rung == agent_id {
        True -> #(rung, types.Taken)
        False -> #(rung, types.Lost)
      }
    }),
  )
}

/// `member_offer`: the caller's action hears that phones are ringing for
/// them and for how long, so that no clock counts them as having nobody
/// and a ring still going is called off if they leave.
///
/// Only once the offer has said its bridge went out. Told when the offer
/// was only asked for, the action believed in a ring that an offer failing
/// before its bridge -- no endpoint to ring, no events to watch, a bridge
/// that could not be sent -- never started, for the whole of the ring
/// timeout and the grace; and an agent whose every device was disabled was
/// offered again on every pass, so the caller was "being offered" for as
/// long as they waited, their no-agent clock never ran, and an exit waited
/// five seconds in silence for the end of a ring that was not there.
fn tell_offered(state: State, offer: Offer, agents: List(String)) -> Nil {
  publish.call(state.config.account_id, "member_offer", offer.member, [
    #("Agent-IDs", doc.List(list.map(agents, doc.String))),
    #(
      "Offer-Timeout",
      doc.Int(offer.ceiling - offer.started_at - state.config.offer_grace_s),
    ),
  ])
}

/// A ring the caller's action may have been told of has ended without an
/// answer: their position is published again on the pass this message
/// runs, and says no ring is out (`position.announce`). The action's own
/// word for the end is the bridge finishing on its channel; this is the
/// dispatcher's, for a ring whose end the channel never showed.
fn retell(state: State, offer: Offer) -> State {
  case offer.rung, dict.get(state.waiting, offer.member.call_id) {
    True, Ok(wait) ->
      State(
        ..state,
        waiting: dict.insert(
          state.waiting,
          offer.member.call_id,
          Wait(..wait, position: 0),
        ),
      )
    _, _ -> state
  }
}

/// The member held for an offer's caller now: the one waiting, or the
/// offer's own when they are not.
///
/// An offer keeps the member it was made from, and its outcome is written
/// to that member's passage. The delivery is another matter. A caller can
/// be delivered again while their phones ring -- the shard handing over a
/// redelivery of the same passage, the callflow run again after its node
/// died, a second queue's member reaching this node before the first
/// queue's cancel -- and each time the waiting caller takes the new
/// delivery and the shard settles the old one and holds the new. The shard
/// settles only the delivery it holds, so settling the offer's own would
/// settle nothing: the one held would stay on the channel, come back at the
/// next failover and ring a second agent for a caller already talking.
pub fn held(state: State, member: Member) -> Member {
  case dict.get(state.waiting, member.call_id) {
    Ok(wait) -> wait.member
    Error(Nil) -> member
  }
}

// --- Misses ----------------------------------------------------------------

/// An offer that came back unanswered by these agents, with `outcome` the
/// way it did: `no_answer`, `busy` or `reject`.
pub fn missed(
  state: State,
  offer: Offer,
  agents: List(String),
  outcome: String,
) -> State {
  let queue = settings.for_queue(state.config, offer.queue_id)
  let state =
    list.fold(agents, state, fn(state, agent_id) {
      let agent = settings.for_agent(state.config, agent_id)
      // The caller's own record says what each offer did whoever it rang:
      // this is the passage of a call, not a mark against an agent.
      records.offer_outcome(offer.member, agent_id, outcome)
      activity.clear(state.config.account_id, agent_id)
      // The delay stands either way. It is about the phone -- one that has
      // just rejected or rung out is not the one to try first -- and an
      // agent who is not being offered anything anyway does not feel it.
      let state =
        State(
          ..state,
          delayed: dict.insert(
            state.delayed,
            agent_id,
            state.config.now() + delay_for(agent, outcome),
          ),
        )
      case counts_as_a_miss(state, agent_id) {
        False -> state
        True -> count_the_miss(state, agent_id, agent, queue)
      }
    })
  close_if_superseded(state, offer, answered: False)
  State(
    ..state,
    offers: dict.delete(state.offers, offer.member.call_id),
    busy: release(state, offer.id, offer.agents),
  )
  |> memo.remember(queue, memo.each(agents, types.Missed))
  |> retell(offer)
}

/// Whether an unanswered offer is this agent's miss.
///
/// Only if they were still taking callers when it came back. An agent who
/// took a break, or logged out, while their phone was ringing had already
/// said they were not there: counting that ring would follow them into their
/// next login and could stand them down for a status they chose themselves.
/// So it is not counted, no record of it is written, and `max_no_answer`
/// never sees it -- the three follow one decision, which is this one.
///
/// The availability is the one the account's documents hold, read through
/// the data layer's document cache, which the data layer itself keeps
/// current from the database's change feed: a change made anywhere in the
/// cluster is written before it is published, so by the time this dispatcher
/// hears an offer's reply the break the agent took is already there to read.
/// A change published while this node had no broker, or whose notice was
/// dropped on the way out, reached nobody; for the queue document that is
/// bounded by `queue_doc`, which reads it from the database again every
/// `queue_refresh_s`.
fn counts_as_a_miss(state: State, agent_id: String) -> Bool {
  let #(current, _counters) = view.agent_state(state, agent_id)
  availability.taking_calls(current.availability)
}

fn count_the_miss(
  state: State,
  agent_id: String,
  agent: AgentSettings,
  settings: QueueSettings,
) -> State {
  records.agent_missed(state.config.account_id, agent_id)
  let missed = { dict.get(state.misses, agent_id) |> result.unwrap(0) } + 1
  let state =
    State(..state, misses: dict.insert(state.misses, agent_id, missed))
  case agent.max_no_answer > 0 && missed >= agent.max_no_answer {
    False -> state
    True -> {
      stand_down(state, agent_id, settings)
      State(
        ..state,
        misses: dict.delete(state.misses, agent_id),
        stood_down: dict.insert(
          state.stood_down,
          agent_id,
          state.config.now() + stand_down_hold_s,
        ),
      )
    }
  }
}

/// The automatic no-answer rule in requirement 1.6: after `max_no_answer`
/// missed offers the agent is moved to the queue's `agent_no_answer_status`.
///
/// Spawned, because setting availability writes two documents and publishes
/// twice, and this actor is on the path of every other caller in the
/// account. So the agent is also marked stood down here, in
/// `State.stood_down`, and held back by the mark until the write's
/// `agent_availability` is heard: without it the next tick could read the
/// document before the write had landed and ring them once more.
///
/// The write is `stand_down_if_taking_calls`: an agent who logged out or
/// took a break after the miss was counted keeps what they chose.
fn stand_down(state: State, agent_id: String, settings: QueueSettings) -> Nil {
  let kz = state.config.kz
  let account_id = state.config.account_id
  let to = settings.agent_no_answer_status
  system.log(
    "agent "
    <> agent_id
    <> " missed too many offers in queue "
    <> settings.id
    <> ": moving to "
    <> availability.to_string(to),
  )
  let _ =
    process.spawn_unlinked(fn() {
      let _ = stand_down_if_taking_calls(kz, account_id, agent_id, to)
      Nil
    })
  Nil
}

/// Move an agent the no-answer rule stood down to `to`, if they are still
/// taking calls as the document stands now -- and only over that revision
/// of it.
///
/// The miss was counted from the availability read when the offer came
/// back, and the write comes after, from a process of its own. An agent who
/// logged out in between has left: set to the no-answer status, which is a
/// break by default, they were logged back in on a break that nothing ever
/// ends. So the decision is taken again from the document the write goes
/// over (`availability.set_if`), and a change that lands between that read
/// and the write is a conflict, after which it is taken once more. `Ok(None)`
/// is an agent who is no longer there to stand down, or already is `to`.
@internal
pub fn stand_down_if_taking_calls(
  kz: kazoo.Kazoo,
  account_id: String,
  agent_id: String,
  to: types.Availability,
) -> Result(Option(availability.AgentAvailability), kazoo.Error) {
  let attempt = fn() {
    availability.set_if(
      kz,
      account_id,
      agent_id,
      source: NoAnswerRule,
      decide: fn(current) {
        case availability.taking_calls(current.availability) {
          True -> Ok(to)
          False -> Error(Nil)
        }
      },
    )
  }
  case attempt() {
    Error(kazoo.Conflict) -> attempt()
    answered -> answered
  }
}

fn delay_for(agent: AgentSettings, outcome: String) -> Int {
  case outcome {
    "busy" -> agent.busy_delay_s
    "reject" -> agent.reject_delay_s
    _no_answer -> agent.no_answer_delay_s
  }
}

// --- The end ---------------------------------------------------------------

/// The end of an offer that was answered, or of one that never was: the
/// record, the counters, the events and the wrap-up.
pub fn ended(state: State, offer: Offer, result: EndResult, at: Int) -> State {
  let member = offer.member
  // The call is over, and the broker may forget it: the delivery the answer
  // kept on the offer. A caller the agent passed on into another queue has
  // been delivered again since, and the shard settles that one only when
  // it is the one it holds.
  state.config.settle(member)
  let queue = settings.for_queue(state.config, offer.queue_id)
  let #(agent_id, talk_time) = case offer.connected {
    Some(#(agent_id, _call_id, answered_at)) -> #(agent_id, at - answered_at)
    None -> #("", 0)
  }
  records.ended(member, result, at)
  closed.note(member, result, at)
  publish.call(state.config.account_id, "member_result", member, [
    #("Result", doc.String(records.result_to_string(result))),
    #("Ended-Timestamp", doc.Int(at)),
    #("Agent-ID", doc.String(agent_id)),
  ])
  case agent_id {
    "" ->
      State(
        ..state,
        offers: dict.delete(state.offers, member.call_id),
        busy: release(state, offer.id, offer.agents),
      )
    _ -> {
      let agent = settings.for_agent(state.config, agent_id)
      let wrapup_s = option.unwrap(agent.wrapup_s, queue.wrapup_s)
      records.agent_call_ended(state.config.account_id, agent_id, talk_time, at)
      publish.agent(state.config.account_id, "agent_wrapup", agent_id, [
        #("Queue-ID", doc.String(member.queue_id)),
        #("Call-ID", doc.String(member.call_id)),
        #("Wrapup-Ends", doc.Int(at + wrapup_s)),
        #("Timestamp", doc.Int(at)),
      ])
      case wrapup_s > 0 {
        True -> activity.set_wrapup(state.config.account_id, agent_id, wrapup_s)
        False -> activity.clear(state.config.account_id, agent_id)
      }
      State(
        ..state,
        offers: dict.delete(state.offers, member.call_id),
        busy: release(state, offer.id, offer.agents),
        wrapup: case wrapup_s > 0 {
          True -> dict.insert(state.wrapup, agent_id, at + wrapup_s)
          False -> state.wrapup
        },
      )
      |> lamp_after_call(agent_id)
    }
  }
}

/// The lamp of an agent whose queue call is over: wrap-up is not a call, so
/// it shows the availability they are in now. An adopted call whose agent
/// nobody could name has no lamp to change.
fn lamp_after_call(state: State, agent_id: String) -> State {
  case agent_id == talk.unknown_agent {
    True -> state
    False -> {
      let #(current, _counters) = view.agent_state(state, agent_id)
      State(
        ..state,
        lamps: presence.ended(
          state.lamps,
          agent_id,
          current.availability,
          state.config.lamp,
        ),
      )
    }
  }
}

/// Whether the agent is talking to a caller this dispatcher connected or
/// adopted: answered, and not yet ended. A supervisor who picked a caller up
/// is not on a queue call, and their login lamp is not theirs to light
/// (`dispatcher/pickup`).
pub fn on_queue_call(state: State, agent_id: String) -> Bool {
  case offer_of(state, agent_id) {
    Ok(Offer(connected: Some(#(answerer, _, _)), ..) as offer) ->
      answerer == agent_id && !is_pickup_offer(state, offer.id)
    _ -> False
  }
}
