//// A caller reaching the dispatcher: a first delivery off the member queue,
//// a redelivery of one the node that was dispatching for them did not live
//// to finish, or an answered call the sweep found nobody holding.
////
//// Not to be confused with `callcenter/takeover`, which is the process that
//// watches such a call once this module has decided to watch rather than
//// ring: this module decides, from the caller's own `queue_call` document,
//// and `config.start_watch` starts the watcher.

import callcenter/activity
import callcenter/closed
import callcenter/dispatcher/offers
import callcenter/dispatcher/pickup
import callcenter/dispatcher/settings.{type QueueSettings}
import callcenter/dispatcher/state.{
  type Offer, type State, type Wait, Offer, State, Wait,
}
import callcenter/presence
import callcenter/records
import callcenter/system
import callcenter/takeover
import callcenter/types.{
  type Member, type OfferId, Completed, Ended, Member, OfferId, Transfer,
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
import kazoo/call
import kazoo/listener
import kazoo/nodes

// --- Arrivals --------------------------------------------------------------

/// A caller came off the member queue.
pub fn arrived(state: State, member: Member) -> State {
  recovering(state, member, False)
}

/// A caller came off the member queue, or was handed on from a dispatcher of
/// this node that ended without being asked to (`recovered`). The second is
/// a caller whose offer may still be ringing on the switch, with nothing on
/// the delivery to say so, and their record is read as a redelivery's is.
pub fn recovering(state: State, member: Member, recovered: Bool) -> State {
  case dict.get(state.waiting, member.call_id) {
    // A redelivery of somebody already here, or the same caller entering
    // the same queue again -- their callflow run again after its node died:
    // keep the place, take the new delivery, and do not count the arrival
    // twice. The place is the older of the two joins, so that a re-entry
    // does not put the caller behind everybody who came after them, and
    // with the older join the re-entry stays the passage it continues: its
    // document goes on being the one written to. A caller now in another
    // queue is a new passage, and so is one a timeout or exit branch sent
    // straight back into this one (`kept_place`).
    Ok(wait) -> {
      let kept = kept_place(wait, member)
      let state = superseded(state, wait.member, kept)
      // The rerun asked for has happened once a member with a later join
      // arrives (`rerun_arrived`), and the arrivals after it are judged as
      // anybody's are.
      let rerun = wait.rerun && !rerun_arrived(wait, member)
      let wait = case records.same_passage(wait.member, kept) {
        True -> Wait(..wait, member: kept, rerun: rerun)
        // The action of a new passage has heard nothing from this
        // dispatcher yet -- it takes only what is about its own passage --
        // and is told where it stands on the next pass, whether or not the
        // number is the one the passage before it was told.
        False ->
          Wait(..wait, member: kept, position: 0, announced_at: 0, rerun: rerun)
      }
      State(..state, waiting: dict.insert(state.waiting, member.call_id, wait))
    }
    Error(_) -> {
      records.joined(member)
      let state =
        State(
          ..state,
          waiting: dict.insert(
            state.waiting,
            member.call_id,
            Wait(
              member: member,
              position: 0,
              announced_at: 0,
              rerun: False,
              tried: [],
            ),
          ),
        )
      recover(state, member.call_id) |> take_over(member, recovered)
    }
  }
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
/// A mark that the passage replaced was being taken out of its queue
/// (`offers.queue_deleted`) goes with it: the caller has left that queue
/// already, and the new passage is not the one being taken out.
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
      State(..state, leaving: dict.delete(state.leaving, member.call_id))
    }
  }
}

/// The new member of a caller already waiting, with the older join when it
/// is the same passage going on. A different queue is a different place in
/// line, and its join is the new one; `time_base_score: system` still keeps
/// the caller's age there, through the channel's `Queue-System-Joined`.
///
/// The same queue is the same passage going on when the callflow was run
/// again (plan 4.4): the action that sent the new member runs on another
/// node, or the rerun was this dispatcher's asking, and it takes whatever
/// this dispatcher says about the caller in the queue (`cf_callcenter`'s
/// `FirstHere`). It is not when a timeout or exit branch sent the caller
/// straight back into the queue and the new member got here before the
/// cancel of the passage they left: the same executor -- the same callflow
/// node -- sent it, joined later, and its action hears only messages about
/// its own join (`Again`). Given the older one, it heard nothing more from
/// this dispatcher, offers included. That caller is a new passage and
/// keeps the new join; the cancel still to come is about the passage
/// before, and the shard holding the new member drops it as such
/// (`shard.later_passage`).
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
/// passage held: joined later, from the same callflow node, and not the
/// rerun this dispatcher asked for. A node that says nothing is not taken
/// for the same one.
///
/// Nor is a redelivery: a message the broker has handed out before is one
/// this dispatcher has had already, and a loop-back is a member its action
/// has just published. It matters after a rerun, whose member is held under
/// the older join it continues: the same member delivered again carries
/// its own later join, from the node now holding the caller, and is still
/// that passage.
fn looped_back(held: Wait, arriving: Member) -> Bool {
  !held.rerun
  && !listener.redelivered(arriving.delivery)
  && arriving.callflow_node != ""
  && arriving.callflow_node == held.member.callflow_node
  && arriving.joined > held.member.joined
}

/// Whether a member is the one the rerun this dispatcher asked for sent:
/// any with a later join than the passage held. The node the passage held
/// came from is gone, which is why the rerun was asked for, so nothing but
/// the callflow the rerun started can send the caller in again -- to this
/// queue, from whichever node answered the route request, a restarted one
/// of the same name included, or on to another. The rerun marks one
/// expected member, and once it is here the next one from that callflow is
/// a loop-back like any other (`looped_back`). A redelivery of the passage
/// held has its join, and leaves the rerun still to come.
fn rerun_arrived(held: Wait, arriving: Member) -> Bool {
  arriving.joined > held.member.joined
}

/// Plan 4.4: a caller whose callflow node is gone has nobody to continue
/// their callflow when they time out or press the exit key. The switch is
/// asked to run its dialplan for the channel again, which produces a fresh
/// route request that a live node answers; the caller keeps their place
/// because the queue orders by the time they entered the system.
fn recover(state: State, call_id: String) -> State {
  case dict.get(state.waiting, call_id) {
    Error(_) -> state
    Ok(wait) ->
      case wait.rerun || wait.member.callflow_node == "" {
        True -> state
        False ->
          case nodes.is_up(wait.member.callflow_node) {
            True -> state
            False -> {
              let caller = call.from_value(wait.member.call)
              let extension =
                call.request_user(caller)
                |> option.unwrap(wait.member.queue_id)
              system.log(
                "callflow node "
                <> wait.member.callflow_node
                <> " is gone for call "
                <> call_id
                <> ": running the dialplan again on "
                <> extension,
              )
              call.execute_extension(caller, extension)
              State(
                ..state,
                waiting: dict.insert(
                  state.waiting,
                  call_id,
                  Wait(..wait, rerun: True),
                ),
              )
            }
          }
      }
  }
}

// --- Taking a caller over from a node that died ----------------------------

/// A caller the broker has handed out before may already have a phone
/// ringing for them, or somebody talking to them, because the node that was
/// dispatching for them died with an offer in flight. The only thing about
/// them that outlived that node is the `queue_call` document of this
/// passage, so it is read -- here and nowhere else -- before anybody is rung
/// a second time. The passage is the member's own (`records.passage_id`): a
/// caller who left another queue for this one is not read as that queue's
/// closed record.
///
/// A first delivery is a caller nobody has done anything about yet, and its
/// document is asked nothing: the read is the price of a failover and not of
/// a call. A caller handed on after this node's own dispatcher for the
/// account ended is read too: that dispatcher may have left an offer ringing,
/// and the delivery, never given back to the broker, does not say so.
fn take_over(state: State, member: Member, recovered: Bool) -> State {
  case recovered || listener.redelivered(member.delivery) {
    False -> state
    True ->
      case records.read(state.config.kz, member) {
        None -> state
        Some(passage) -> taken(state, member, passage)
      }
  }
}

fn taken(state: State, member: Member, passage: records.Passage) -> State {
  case passage.ended, passage.cancelled, passage.answered, passage.offer {
    // A closed record belongs to a passage that finished, whose member came
    // round again all the same, and the caller is offered from the beginning
    // like anybody else. A caller who came back -- a transfer, a callflow
    // run again -- joined at another second, which is another passage and
    // is not this record.
    Some(_), _, _, _ | _, Some(_), _, _ -> state

    // Answered and never closed: somebody is talking to this caller on a
    // switch that outlived the node which connected them. The member message
    // is settled, because the answer that should have settled it did not
    // reach the broker, and the call is watched for its end. A supervisor
    // who picked the caller up is talking to them as a supervisor, and the
    // call is watched as the pickup it is.
    _, _, Some(at), _ -> {
      state.config.settle(member)
      adopt(
        state,
        member,
        option.unwrap(passage.agent_id, takeover.unknown_agent()),
        option.unwrap(passage.agent_call_id, ""),
        at,
        passage.picked_up,
      )
    }

    _, _, None, Some(offered) -> offered_elsewhere(state, member, offered)
    _, _, None, None -> state
  }
}

/// An offer that was in flight on the node that died. If it still has time
/// to run, this caller is not rung: the outcome of the ringing that is
/// already happening is watched for instead. A supervisor's pickup rings
/// for `pickup.ring_timeout_s`, whatever the queue says.
fn offered_elsewhere(
  state: State,
  member: Member,
  offered: records.Offered,
) -> State {
  let queue = settings.for_queue(state.config, member.queue_id)
  let ring_timeout = case offered.pickup {
    True -> pickup.ring_timeout_s
    False -> settings.ring_timeout(state.config, offered.agents, queue)
  }
  let ceiling = offered.at + ring_timeout + state.config.offer_grace_s
  case ceiling > state.config.now() {
    // The offer ran out before this node ever saw the caller. Whatever was
    // ringing has stopped, and they are offered again from here.
    False -> state
    True -> watch_offer(state, member, queue, offered, ceiling)
  }
}

fn watch_offer(
  state: State,
  member: Member,
  queue: QueueSettings,
  offered: records.Offered,
  ceiling: Int,
) -> State {
  let id = new_id(member)
  let request =
    takeover.Request(
      member: member,
      agents: offered.agents,
      offered_at: offered.at,
      deadline: ceiling,
      // The same rule `offers.send` applies, because the offer that died
      // applied it and then died before it could start anything: the queue's
      // setting, or any of the agents' own. A pickup's is the queue's alone
      // (`dispatcher/pickup`).
      record: queue.record
        || {
        !offered.pickup
        && settings.any_agent_records(state.config, offered.agents)
      },
      answered: None,
      leg_prefix: offered.leg_prefix,
      id: id,
      reply_to: state.replies,
    )
  case state.config.start_watch(request) |> result.map(offers.monitored) {
    Error(reason) -> {
      system.log_error(
        "could not watch the offer of call "
        <> member.call_id
        <> " to "
        <> string.join(offered.agents, ", ")
        <> ": "
        <> reason,
      )
      state
    }
    Ok(pid) -> {
      system.log(
        "call "
        <> member.call_id
        <> " was offered to "
        <> string.join(offered.agents, ", ")
        <> " on the node that was dispatching for it: watching for the "
        <> "outcome rather than ringing again",
      )
      // Nothing is written and nothing is published: the offer on the record
      // is the one the dead node made and already said it had. The agents
      // are held here all the same, because their phones are ringing and no
      // other caller may be sent to them. A supervisor's pickup is held the
      // same way, as `dispatcher/pickup` holds its own, and its replies go
      // there: nobody misses it and nobody's queue call it becomes.
      case offered.pickup {
        True -> Nil
        False ->
          list.each(offered.agents, fn(agent_id) {
            activity.set_offering(
              state.config.account_id,
              agent_id,
              ceiling - state.config.now(),
            )
          })
      }
      let offer =
        Offer(
          id: id,
          queue_id: queue.id,
          member: member,
          agents: offered.agents,
          ringing: offered.agents,
          started_at: offered.at,
          ceiling: ceiling,
          connected: None,
          pid: Some(pid),
          // The dead node's ring is out there already.
          rung: True,
          called_off: False,
        )
      State(
        ..state,
        offers: dict.insert(state.offers, member.call_id, offer),
        busy: offers.hold(state, id, offered.agents),
      )
      |> as_pickup(offer, offered.pickup)
    }
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
/// A call nothing watches is one nothing will ever say the end of, and its
/// agent would be held busy until the sweep's backstop, ten minutes later.
/// So a watch that cannot be started is tried once more, and a second
/// failure closes the call here and now, as a call its record says was
/// answered: the agent gets their wrap-up and their counters, and their own
/// channels keep them out of the next offer for as long as they really are
/// talking.
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
  let request =
    takeover.Request(
      member: member,
      agents: [agent_id],
      offered_at: at,
      deadline: at,
      // A record that says answered is one written by an offer that reached
      // its answer, and an offer that reaches its answer starts the
      // recording there. There is nothing left to start.
      record: False,
      answered: Some(takeover.Answer(
        agent_id: agent_id,
        agent_call_id: agent_call_id,
        at: at,
      )),
      leg_prefix: None,
      id: id,
      reply_to: state.replies,
    )
  let watching =
    case state.config.start_watch(request) {
      Ok(pid) -> Ok(pid)
      Error(reason) -> {
        system.log_error(
          "could not watch call "
          <> member.call_id
          <> ", answered by "
          <> agent_id
          <> ": "
          <> reason
          <> "; trying once more",
        )
        state.config.start_watch(request)
      }
    }
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
      case agent_id == takeover.unknown_agent() || picked_up {
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
        // Adopted already, and its watcher will say when it ends.
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
