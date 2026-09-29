//// A caller reaching the dispatcher: a first delivery off the member queue,
//// a redelivery of one the node that was dispatching for them did not live
//// to finish, or an answered call the sweep found nobody holding.
////
//// Every caller taken in is told to their actor (`config.calls.join`), the
//// one process that commands them. A caller this dispatcher did not see
//// join -- the broker handed them out before, their actor ended, or the
//// dispatcher before this one did -- joins it `resumed`, and nobody is rung
//// for them until the actor has found out where they stand and said so
//// (`present`): waiting, phones already ringing for them, already through
//// to an agent, or not the queue's any more. What the actor finds going on
//// is taken on here as an offer like any other, under the id it names. An
//// answered call the sweep found nobody holding is adopted by the caller's
//// actor instead (`config.calls.adopt`), which watches it to its end.

import callcenter/activity
import callcenter/call/talk
import callcenter/closed
import callcenter/dispatcher/offers
import callcenter/dispatcher/pickup
import callcenter/dispatcher/state.{
  type Offer, type State, type Wait, Offer, State, Wait,
}
import callcenter/presence
import callcenter/records
import callcenter/system
import callcenter/types.{
  type Member, type OfferId, type Presence, Completed, Ended, Member, OfferId,
  Transfer,
}
import gleam/bool
import gleam/dict
import gleam/erlang/process.{type Pid}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/listener

// --- Arrivals --------------------------------------------------------------

/// A caller came off the member queue.
pub fn arrived(state: State, member: Member) -> State {
  recovering(state, member, False)
}

/// A caller came off the member queue, or was handed on from a dispatcher of
/// this node that ended without being asked to (`recovered`). Either kind
/// that this dispatcher did not see join -- the second, or a redelivery --
/// joins their actor `resumed`: whatever was going on for them is still
/// going on, and the actor finds out what before anybody is rung.
pub fn recovering(state: State, member: Member, recovered: Bool) -> State {
  let resumed = recovered || listener.redelivered(member.delivery)
  case dict.get(state.waiting, member.call_id) {
    // A redelivery of somebody already here, or the same caller entering
    // the same queue again -- their callflow run again elsewhere: keep the
    // place, take the new delivery, and do not count the arrival twice. The
    // place is the older of the two joins, so that a re-entry does not put
    // the caller behind everybody who came after them, and with the older
    // join the re-entry stays the passage it continues: its document goes
    // on being the one written to. A caller now in another queue is a new
    // passage, and so is one a timeout or exit branch sent straight back
    // into this one (`kept_place`).
    Ok(wait) -> {
      let kept = kept_place(wait, member)
      let state = superseded(state, wait.member, kept)
      let wait = case records.same_passage(wait.member, kept) {
        True -> Wait(..wait, member: kept)
        // A new passage has been told nothing of where it stands yet, and
        // is told on the next pass whether or not the number is the one the
        // passage before it was told.
        False -> Wait(..wait, member: kept, position: 0, announced_at: 0)
      }
      State(..state, waiting: dict.insert(state.waiting, member.call_id, wait))
      |> join(kept, resumed)
    }
    Error(_) -> {
      records.joined(member)
      State(
        ..state,
        waiting: dict.insert(
          state.waiting,
          member.call_id,
          Wait(member: member, position: 0, announced_at: 0, tried: []),
        ),
      )
      |> join(member, resumed)
    }
  }
}

/// How long a caller handed over waits for their actor to say where they
/// stand before they are rung like anybody else: the actor gives its survey
/// eight seconds, and asks six times (`core.recover_attempts`).
pub const present_wait_s = 60

/// Tell the caller's actor they joined, and watch it while they wait. An
/// actor that cannot be started is a caller nothing commands: logged, and
/// left waiting here, where their offers fail until one can be.
///
/// A caller handed over is rung for by nobody until the actor says where
/// they stand, unless this dispatcher holds an offer for them already: the
/// same member delivered again, whose actor says what this dispatcher
/// knows.
fn join(state: State, member: Member, resumed: Bool) -> State {
  case state.config.calls.join(member, resumed, state.replies) {
    Ok(pid) -> {
      let _monitor = process.monitor(pid)
      let state =
        State(..state, actors: dict.insert(state.actors, member.call_id, pid))
      case resumed && !dict.has_key(state.offers, member.call_id) {
        False -> state
        True ->
          State(
            ..state,
            presenting: dict.insert(
              state.presenting,
              member.call_id,
              state.config.now() + present_wait_s,
            ),
          )
      }
    }
    Error(reason) -> {
      system.log_error(
        "call "
        <> member.call_id
        <> " joined queue "
        <> member.queue_id
        <> " with nothing to command it: "
        <> reason,
      )
      state
    }
  }
}

/// A caller's actor has ended. A caller still waiting is joined to a new
/// one, as a caller handed out again is: the one that ended may have
/// finished the passage before just as the member of this one reached it,
/// or crashed, and either way nothing commands the caller now.
pub fn actor_down(state: State, pid: Pid) -> State {
  let gone =
    dict.to_list(state.actors)
    |> list.filter(fn(entry) { entry.1 == pid })
    |> list.map(fn(entry) { entry.0 })
  let state = State(..state, actors: dict.drop(state.actors, gone))
  list.fold(gone, state, fn(state, call_id) {
    case dict.get(state.waiting, call_id) {
      Ok(wait) -> {
        system.log(
          "the actor of call "
          <> call_id
          <> " ended while the caller waits: joining them to a new one",
        )
        join(state, wait.member, True)
      }
      Error(Nil) -> state
    }
  })
}

/// A member for a caller already waiting here that is not the same passage:
/// they moved on to another queue before the cancel of the first reached
/// this node, which the shard then drops as being about an earlier passage.
/// A caller who joined the same queue anew -- the callflow run again, plan
/// 4.4 -- is not one of these: `kept_place` gives them the older join, which
/// is the passage they are continuing. The new passage gets a document of
/// its own, and the one it
/// replaces is closed as a transfer so that it does not stay open for ever
/// -- unless an offer made for it is still in flight, in which case that
/// offer's outcome is written to it as usual and the offer's end closes
/// whichever of the two passages is left over: the old one if nobody
/// answered, the new one if an agent did (`offers.superseded_passage`).
///
fn superseded(state: State, was: Member, member: Member) -> State {
  case records.same_passage(was, member) {
    True -> state
    False -> {
      records.joined(member)
      // Only an offer of the passage being replaced writes to it and closes
      // it when it ends (`offers.close_if_superseded`). One of a passage
      // before that has its own to close, and this one would be left open.
      let in_flight = case dict.get(state.offers, member.call_id) {
        Ok(offer) -> records.same_passage(offer.member, was)
        Error(Nil) -> False
      }
      case in_flight {
        True -> Nil
        False -> records.cancelled(was, Transfer, state.config.now())
      }
      state
    }
  }
}

/// The new member of a caller already waiting, with the older join when it
/// is the same passage going on. A different queue is a different place in
/// line, and its join is the new one; `time_base_score: system` still keeps
/// the caller's age there, through the channel's `Queue-System-Joined`.
///
/// The same queue is the same passage going on when the callflow was run
/// again somewhere else: a caller resumed on another callflow node after
/// theirs died, which routes them into the queue they were in. It is not
/// when a timeout or exit branch sent the caller straight back into the
/// queue and the new member got here before the caller's actor said they
/// left the passage before: the same callflow node sent it, joined later.
/// That caller is a new passage and keeps the new join.
fn kept_place(held: Wait, arriving: Member) -> Member {
  case
    held.member.queue_id == arriving.queue_id && !looped_back(held, arriving)
  {
    True ->
      Member(..arriving, joined: int.min(held.member.joined, arriving.joined))
    False -> arriving
  }
}

/// Whether a member for the queue a caller is already waiting in is them
/// sent back into it by their own callflow, on the node that ran the
/// passage held: joined later, from the same callflow node. A node that
/// says nothing is not taken for the same one.
///
/// Nor is a redelivery: a message the broker has handed out before is one
/// this dispatcher has had already, and a loop-back is a member its action
/// has just published.
fn looped_back(held: Wait, arriving: Member) -> Bool {
  !listener.redelivered(arriving.delivery)
  && arriving.callflow_node != ""
  && arriving.callflow_node == held.member.callflow_node
  && arriving.joined > held.member.joined
}

// --- Where a caller handed over stands --------------------------------------

/// The caller's actor says where a caller this dispatcher was handed
/// without seeing them join stands, and the offer `id` is what anything it
/// found going on is held under from now on.
///
/// Only a caller still waiting for that word is anything to it: one who
/// has left, or whom this dispatcher already knows the state of, is left as
/// it is. What it says is taken on as the dispatcher that died would have
/// held it:
///
/// - **waiting**: the caller is rung like anybody else from now on;
/// - **ringing**: the agents are held until the ring's ceiling, under the
///   actor's offer, which says how the ring went as any offer's does; a
///   supervisor's pickup is held as the pickup it is;
/// - **connected**: the call is adopted, as a call the sweep found is
///   (`adopt`), and its end is heard from the actor;
/// - **over**: the passage was closed, or the caller was on their way out,
///   and all that is left is to settle their member.
///
/// Nothing is written and nothing is published for a ring or a call taken
/// on: the node that made them wrote and published them.
pub fn present(state: State, id: OfferId, presence: Presence) -> State {
  let call_id = id.call_id
  case
    dict.get(state.presenting, call_id),
    dict.get(state.waiting, call_id),
    dict.get(state.actors, call_id)
  {
    Ok(_), Ok(wait), Ok(pid) -> {
      let state =
        State(..state, presenting: dict.delete(state.presenting, call_id))
      presented(state, wait.member, id, pid, presence)
    }
    _, _, _ -> state
  }
}

fn presented(
  state: State,
  member: Member,
  id: OfferId,
  pid: Pid,
  presence: Presence,
) -> State {
  case presence {
    types.PresentWaiting -> state
    types.PresentRinging(agents, ceiling, is_pickup) ->
      ringing_elsewhere(state, member, id, pid, agents, ceiling, is_pickup)
    types.PresentConnected(agent_id, leg, at, is_pickup) ->
      watched(state, member, id, agent_id, leg, at, pid, is_pickup)
    types.PresentOver -> {
      system.log(
        "call "
        <> member.call_id
        <> " in queue "
        <> member.queue_id
        <> " was handed over after the queue was done with it: settling it",
      )
      state.config.settle(member)
      State(
        ..state,
        waiting: dict.delete(state.waiting, member.call_id),
        actors: dict.delete(state.actors, member.call_id),
      )
    }
  }
}

/// A ring the caller's actor found going on, taken on as this dispatcher's
/// offer: its agents are held until its ceiling, as the offer that rang
/// them would have held them, and nobody else is offered them meanwhile.
fn ringing_elsewhere(
  state: State,
  member: Member,
  id: OfferId,
  pid: Pid,
  agents: List(String),
  ceiling: Int,
  is_pickup: Bool,
) -> State {
  let now = state.config.now()
  system.log(
    "call "
    <> member.call_id
    <> " was being offered to "
    <> string.join(agents, ", ")
    <> " when it was handed over: holding them until "
    <> int.to_string(ceiling)
    <> " and hearing the ring out",
  )
  case is_pickup {
    True -> Nil
    False ->
      list.each(agents, fn(agent_id) {
        activity.set_offering(
          state.config.account_id,
          agent_id,
          int.max(ceiling - now, 1),
        )
      })
  }
  let offer =
    Offer(
      id: id,
      queue_id: member.queue_id,
      member: member,
      agents: agents,
      ringing: agents,
      started_at: now,
      ceiling: ceiling,
      connected: None,
      pid: Some(pid),
      rung: True,
      called_off: False,
    )
  State(
    ..state,
    offers: dict.insert(state.offers, member.call_id, offer),
    busy: offers.hold(state, id, agents),
  )
  |> as_pickup(offer, is_pickup)
}

/// A call the caller's actor found connected, taken on as this dispatcher's:
/// the offer that answered it is the actor's, and so is the word of its
/// end. The agent's login lamp is this node's to keep now.
fn watched(
  state: State,
  member: Member,
  id: OfferId,
  agent_id: String,
  leg: String,
  at: Int,
  pid: Pid,
  is_pickup: Bool,
) -> State {
  system.log(
    "call "
    <> member.call_id
    <> case is_pickup {
      True -> " was picked up by "
      False -> " was answered by "
    }
    <> agent_id
    <> " when it was handed over: waiting for the end",
  )
  let state =
    connected(state, id, member, agent_id, leg, at, Some(pid), is_pickup)
  case agent_id == talk.unknown_agent || agent_id == "" || is_pickup {
    True -> state
    False ->
      State(
        ..state,
        lamps: presence.connected(state.lamps, agent_id, state.config.lamp),
      )
  }
}

/// A call somebody else answered, taken on here so that its end is heard.
///
/// No event is published: the node that answered published `agent_answered`
/// and `member_connected` when it did, and a second pair would be counted
/// twice by everything watching. What is left is the end, which nothing has
/// reported and nobody else will -- and the agent's login lamp, which is
/// shown `early` again because this node now answers for it.
///
/// The caller's actor adopts the call (`config.calls.adopt`) and says when
/// it ends, as it says the end of a call it connected. A call nothing
/// watches is one nothing will ever say the end of, and its agent would be
/// held busy until the sweep's backstop, ten minutes later. So an actor
/// that cannot be had closes the call here and now, as a call its record
/// says was answered: the agent gets their wrap-up and their counters, and
/// their own channels keep them out of the next offer for as long as they
/// really are talking.
///
/// A supervisor's pickup (`picked_up`) is adopted as the pickup it is: its
/// replies are `dispatcher/pickup`'s, and its end closes the record and
/// publishes `member_result` with no counters, no wrap-up, no agent event
/// and no lamp. The lamp is not lit here either.
fn adopt(
  state: State,
  member: Member,
  agent_id: String,
  agent_call_id: String,
  at: Int,
  picked_up: Bool,
) -> State {
  let id = new_id(member)
  let watching =
    state.config.calls.adopt(
      member,
      id,
      agent_id,
      agent_call_id,
      at,
      state.replies,
    )
    |> result.map(offers.monitored)
  case watching {
    Error(reason) -> {
      system.log_error(
        "could not watch call "
        <> member.call_id
        <> ", answered by "
        <> agent_id
        <> " on the node that was dispatching for it: "
        <> reason
        <> "; closing it now",
      )
      connected(state, id, member, agent_id, agent_call_id, at, None, picked_up)
      |> close(member.call_id, state.config.now())
    }
    Ok(pid) -> {
      system.log(
        "call "
        <> member.call_id
        <> case picked_up {
          True -> " was picked up by "
          False -> " was answered by "
        }
        <> agent_id
        <> " on the node that was dispatching for it: waiting for the end",
      )
      let state =
        connected(
          state,
          id,
          member,
          agent_id,
          agent_call_id,
          at,
          Some(pid),
          picked_up,
        )
      // The lamp is this node's to keep now, and the node that lit it is
      // gone.
      case agent_id == talk.unknown_agent || picked_up {
        True -> state
        False ->
          State(
            ..state,
            lamps: presence.connected(state.lamps, agent_id, state.config.lamp),
          )
      }
    }
  }
}

/// The offer this dispatcher did not make, for a call somebody else
/// answered: a pickup's when a supervisor picked the caller up.
fn connected(
  state: State,
  id: OfferId,
  member: Member,
  agent_id: String,
  agent_call_id: String,
  at: Int,
  pid: Option(Pid),
  picked_up: Bool,
) -> State {
  let offer =
    Offer(
      id: id,
      queue_id: member.queue_id,
      member: member,
      agents: [agent_id],
      ringing: [],
      started_at: at,
      ceiling: at,
      connected: Some(#(agent_id, agent_call_id, at)),
      pid: pid,
      rung: True,
      called_off: False,
    )
  State(
    ..state,
    waiting: dict.delete(state.waiting, member.call_id),
    offers: dict.insert(state.offers, member.call_id, offer),
    busy: offers.hold(state, id, [agent_id]),
  )
  |> as_pickup(offer, picked_up)
}

/// The offer as a supervisor's pickup, when it is one.
fn as_pickup(state: State, offer: Offer, is_pickup: Bool) -> State {
  case is_pickup {
    True -> pickup.adopt(state, offer)
    False -> state
  }
}

/// The sweep found an answered call this node never heard of.
///
/// Held already means an offer for the same passage. One for another passage
/// of the same caller -- they were passed on to a second queue after the
/// answer, and the node that answered died before it closed the first -- is
/// left alone, and so is the orphan: the offer dictionary holds one offer a
/// caller, and the one in flight is the caller's present. The sweep comes
/// back to the orphan once it is over.
///
/// A record `picked_up` is a supervisor's pickup, adopted or closed as one:
/// see `adopt`.
pub fn orphaned(
  state: State,
  member: Member,
  agent_id: String,
  agent_call_id: String,
  answered_at: Int,
  picked_up: Bool,
  end: Option(Int),
) -> State {
  // Closed here already, its end still on its way to the document.
  use <- bool.guard(closed.again(member), state)
  case dict.get(state.offers, member.call_id), end {
    Ok(offer), _ ->
      case records.same_passage(offer.member, member), end {
        // Adopted already, and its actor will say when it ends.
        True, None -> state
        True, Some(at) -> close(state, member.call_id, at)
        False, _ -> {
          system.log(
            "call "
            <> member.call_id
            <> " has an open record in queue "
            <> member.queue_id
            <> " while an offer of another passage is in flight: left for now",
          )
          state
        }
      }
    Error(Nil), None ->
      adopt(state, member, agent_id, agent_call_id, answered_at, picked_up)
    // Nothing watches it, so nothing will reply to this id.
    Error(Nil), Some(at) ->
      connected(
        state,
        new_id(member),
        member,
        agent_id,
        agent_call_id,
        answered_at,
        None,
        picked_up,
      )
      |> close(member.call_id, at)
  }
}

/// End a call this dispatcher is holding, exactly as the reply that says it
/// ended would: the record, the counters, the events and the wrap-up -- or,
/// for a supervisor's pickup, the record and `member_result` alone, through
/// `dispatcher/pickup` as its own end would be.
fn close(state: State, call_id: String, at: Int) -> State {
  case dict.get(state.offers, call_id) {
    Error(_) -> state
    Ok(offer) ->
      case pickup.is_pickup(state, offer) {
        True -> pickup.replied(state, offer.id, Ended(Completed, at))
        False -> offers.ended(state, offer, Completed, at)
      }
  }
}

/// The id of an offer this dispatcher holds for a caller, which the replies
/// of whatever stands in for its process carry.
fn new_id(member: Member) -> OfferId {
  OfferId(call_id: member.call_id, serial: reference.new())
}
