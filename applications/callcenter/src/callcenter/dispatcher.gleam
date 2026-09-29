//// One account's dispatch: who is waiting, who is free, and which of them
//// is offered to whom.
////
//// One actor per account, on whichever node holds the account's shard. That
//// is what makes an agent in two queues safe: every offer in the account is
//// decided by this one process, in order, so two queues cannot ring the same
//// agent for two callers and the strategies never see half a change.
////
//// It owns four things and nothing else does:
////
//// - The waiting lists. A caller is a `member_call` message the broker is
////   holding unacked, and the delivery is acked here and nowhere else, when
////   the caller has been connected or has left. Losing this node redelivers
////   every waiting caller to whoever takes the shard next, in the order
////   their arrival times give.
//// - The offers in flight. An agent is in at most one at a time, which is
////   held in one dictionary and checked before every offer.
//// - The timers: the wrap-up after a call, the per-agent delay after a
////   miss, the ceiling on an offer that never came back, and the
////   announcement interval.
//// - The events. `agent_offer`, `agent_answered`, `member_connected`,
////   `agent_wrapup`, `member_result`, `member_position` and `queue_stats`
////   are all published from here, because they all describe a transition
////   this process made.
//// - The queue-call half of the agents' login lamps: `early` when an offer
////   is answered or an answered call adopted, the availability's state when
////   it ends, and `early` again when an availability change is heard for an
////   agent still on the call (`callcenter/presence`).
////
//// The ringing itself is not here. The dispatcher asks for an offer through
//// a function it was started with, which asks the caller's actor
//// (`callcenter/call/actor`) on a node and is a fake in the tests, and hears
//// the result back as a message. That is the whole of the boundary: this
//// module chooses, the caller's actor dials.
////
//// The actor is this module: what it is started with, the messages it takes
//// and the loop that takes them. What it does with each message is in the
//// modules under `callcenter/dispatcher/`:
////
//// - `arrival`: a caller reaching it, including one a node that died left
////   behind.
//// - `offers`: an offer from sent to settled, and a caller leaving.
//// - `pass`: one pass over the account, deciding who is rung.
//// - `pickup`: a waiting caller rung through to a supervisor's own phone.
//// - `waiting`: the account's one order of waiting callers.
//// - `view`: an agent as a strategy sees them.
//// - `memo`: what a strategy keeps between callers.
//// - `worked`: when each agent last became free, and the calls it counted
////   for them before their document shows them.
//// - `timers`: the delays, the wrap-ups, the offer ceilings and the tick.
//// - `position`: `member_position` and `queue_stats`.
//// - `publish`: the payloads of every event it publishes.
//// - `status`: the `status_resp` answer and the `sup` snapshot.
//// - `settings`: what it reads out of a queue document and a user.
//// - `config` and `state`: what it is started with, and what it holds.

import callcenter/activity
import callcenter/availability.{type Source, NoAnswerRule}
import callcenter/dispatcher/arrival
import callcenter/dispatcher/config
import callcenter/dispatcher/offers
import callcenter/dispatcher/pass
import callcenter/dispatcher/pickup
import callcenter/dispatcher/position
import callcenter/dispatcher/settings
import callcenter/dispatcher/state.{type State, State}
import callcenter/dispatcher/status
import callcenter/dispatcher/timers
import callcenter/dispatcher/view
import callcenter/dispatcher/waiting
import callcenter/dispatcher/worked
import callcenter/presence
import callcenter/system
import callcenter/types.{
  type CancelReason, type Member, type OfferId, type OfferReply,
  type OfferRequest, Hangup,
}
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/listener

/// What the dispatcher is started with. See `callcenter/dispatcher/config`.
pub type Config =
  config.Config

/// The configuration a node runs with.
pub fn config(kz: Kazoo, account_id: String) -> Config {
  config.live(kz, account_id)
}

pub type Message {
  /// A caller came off the member queue. Answered at once: the shard's
  /// listener is waiting on it and must not be held up by a dispatch pass.
  Arrived(member: Member, done: Subject(Nil))
  /// A caller handed over by the shard, told and not asked: the shard never
  /// waits on a dispatcher. `digesting` is called as the dispatcher starts
  /// on the caller and `digested` once they are taken in, before the pass
  /// after, so that a crash taking them in -- and only that -- is laid at
  /// their door (`callcenter/shard`). `recovered` is a caller handed on from
  /// a dispatcher that ended without being asked to: its offer may still be
  /// ringing on the switch, so the caller's record is read before anybody is
  /// rung, as for a redelivery.
  HandedOver(
    member: Member,
    recovered: Bool,
    digesting: fn() -> Nil,
    digested: fn() -> Nil,
  )
  /// The caller left. Answers whether this dispatcher was holding them.
  Cancelled(call_id: String, reason: CancelReason, done: Subject(Bool))
  /// The caller left, told and not asked: the shard has already settled
  /// their member and wants nothing back. What is left to do is this
  /// dispatcher's own -- take them out of the queue, release whoever was
  /// being rung for them, close their record.
  Left(call_id: String, reason: CancelReason)
  /// The caller is leaving on a branch their actor hands them back on, told
  /// and not asked: taken out of the queue as a caller who left is, but
  /// their member kept until the actor has handed them back
  /// (`offers.depart`).
  Departing(call_id: String, reason: CancelReason)
  /// The caller's actor's answer, naming the offer it is about.
  Reply(offer: OfferId, reply: OfferReply)
  /// A caller's actor this dispatcher monitors has ended. See `offers.down`.
  OfferDown(down: process.Down)
  /// A caller's channel is gone, seen by the activity actor or the sweep.
  /// The activity actor says it of every queue channel of the account that
  /// goes, agents' legs and callers already through included; only a caller
  /// still waiting here, with nobody being rung for them, is anything to
  /// this dispatcher.
  ///
  /// A caller being rung for is their actor's to close. It hears the same
  /// end, and it alone knows whether an agent answered first: an answer and
  /// the caller's end are two channels' events, and the actor dates them
  /// (`call/core`'s `Desertion`). In the lab of 2026-09-28
  /// (e2e-260927-cca6), the dispatcher closed a caller as gone on this word.
  /// The actor's `Answered` and `Ended` then found no offer, and an agent's
  /// answered call was never counted. An actor that misses the end has its
  /// own audit, and an actor that dies has its offer closed (`OfferDown`),
  /// after which this word closes the caller.
  ChannelGone(call_id: String)
  /// A call answered on a node that died, whose `queue_call` record the
  /// sweep found still open. A connected call's member is held until the
  /// call ends, and usually comes back with the shard as well: a caller of
  /// the passage held here is their actor's, and is left to it
  /// (`arrival.orphaned`). One whose member was settled -- an earlier
  /// release's, or one the broker lost -- reaches this node no other way.
  ///
  /// `ended` is the second the caller's channel went, when the switches say
  /// it has gone. `None` is a conversation still going on: the call is
  /// adopted and watched, so that its end is published and written here.
  /// `picked_up` is a supervisor's pickup, adopted and closed as one.
  Orphaned(
    member: Member,
    agent_id: String,
    agent_call_id: String,
    answered_at: Int,
    picked_up: Bool,
    ended: Option(Int),
  )
  /// A queue of the account was deleted, as the document change that says
  /// so was heard on this node: everybody waiting in it leaves it now
  /// (`offers.queue_deleted`). The pass notices a deleted queue on its own,
  /// from the document it reads every pass and from the database every
  /// `queue_refresh_s`; this is only sooner.
  QueueDeleted(queue_id: String)
  /// An agent's availability or activity moved: look again.
  Changed
  /// An agent logged in. Look again, and forget the misses counted against
  /// them: they belong to the shift they ended.
  LoggedIn(agent_id: String)
  /// Any other availability change of a named agent. Look again, and put
  /// their login lamp back to `early` if they are on a queue call here.
  AgentChanged(agent_id: String)
  /// The timers.
  Tick
  /// The reconcile sweep wants the call ids of everybody waiting, so it can
  /// ask the switches whether their channels are still there.
  Waiting(done: Subject(List(String)))
  /// The live status of the account, or of one queue, for `status_resp`.
  Status(queue_id: Option(String), done: Subject(List(Value)))
  /// What this dispatcher is doing, for `sup`.
  Report(done: Subject(Snapshot))
  /// The agents on a queue call here right now: an offer they answered that
  /// has not ended. What a login lamp probe needs to tell `early` from the
  /// availability's own state.
  OnQueueCall(done: Subject(List(String)))
  /// Take an agent out of whatever this dispatcher believes about them,
  /// the offer they are in included: see `offers.release_agent`.
  ReleaseAgent(agent_id: String, done: Subject(Bool))
  /// A supervisor asks for a waiting caller to be rung through to their own
  /// phones: see `dispatcher/pickup`. `deadline_ms` is the monotonic
  /// millisecond past which whoever asked has stopped waiting, and a
  /// question that arrives after it starts nothing: the answer would reach
  /// nobody, and a phone would ring that the supervisor was told did not.
  /// `done` is answered once the offer's bridge is out, or once it is known
  /// that nothing rang; a bridge out only after the deadline is called off.
  PickUp(
    request: pickup.Request,
    deadline_ms: Int,
    done: Subject(pickup.Answer),
  )
  Stop(done: Subject(Nil))
}

/// What `sup` prints for one dispatcher. See `callcenter/dispatcher/status`.
pub type Snapshot =
  status.Snapshot

// --- Starting --------------------------------------------------------------

/// Start a dispatcher for an account.
///
/// `start_offer` is the only thing this module knows about ringing an agent.
/// On a node it hands the request to the caller's actor; in a test it is a
/// fake that answers whatever the test wants. Taking it as an argument rather than calling the
/// module directly is what lets the two halves of the dispatcher be built
/// and tested apart.
pub fn start(
  config: Config,
  start_offer start_offer: fn(OfferRequest) -> Result(Pid, String),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(30_000, fn(self) {
    let replies = process.new_subject()
    let ticks = process.new_subject()
    // Told of every queue channel of the account that goes, which is how a
    // caller hanging up is heard at once: see `ChannelGone`. Again whenever
    // the activity actor restarts and forgets it (`view.read_activity`).
    let me = process.self()
    let watch_activity = fn() {
      activity.watch(config.account_id, me, fn(call_id) {
        process.send(self, ChannelGone(call_id))
      })
    }
    watch_activity()
    let listening = listen(config.account_id, self, process.self())
    actor.initialised(State(
      config: config,
      ticks: ticks,
      replies: replies,
      start_offer: start_offer,
      waiting: dict.new(),
      offers: dict.new(),
      actors: dict.new(),
      presenting: dict.new(),
      departing: dict.new(),
      pickups: dict.new(),
      busy: dict.new(),
      delayed: dict.new(),
      wrapup: dict.new(),
      stood_down: dict.new(),
      no_document: dict.new(),
      misses: dict.new(),
      memo: dict.new(),
      worked: dict.new(),
      stats: dict.new(),
      lamps: presence.lamps(),
      ticking: False,
      listening: listening,
      activities: state.Read(dict.new()),
      sync: state.Syncing(until: config.now() + view.sync_ceiling_s),
      watch_activity: watch_activity,
    ))
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_map(replies, fn(answer) { Reply(answer.0, answer.1) })
      |> process.select_map(ticks, fn(_tick) { Tick })
      |> process.select_monitors(OfferDown),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

// --- The loop --------------------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message, state.config.fresh() {
    Stop(_), _ | _, True -> act(state, message)
    // The node stood still since this dispatcher started, and the shard it
    // dispatches for may be another node's now (`callcenter/stall`): what
    // it is handed is dropped, and nothing more is written, published or
    // settled from here. The shard's tree is ending, this dispatcher with
    // it.
    _, False -> actor.continue(state)
  }
}

/// What the dispatcher does with a message while it may still act for its
/// shard.
fn act(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Arrived(member, done) -> {
      process.send(done, Nil)
      actor.continue(arrival.arrived(state, member) |> pass.run)
    }

    HandedOver(member, recovered, digesting, digested) -> {
      digesting()
      let state = arrival.recovering(state, member, recovered)
      digested()
      actor.continue(pass.run(state))
    }

    Cancelled(call_id, reason, done) -> {
      let held = dict.has_key(state.waiting, call_id)
      process.send(done, held)
      step(state, offers.leave(state, call_id, reason))
    }

    Left(call_id, reason) -> step(state, offers.leave(state, call_id, reason))

    Departing(call_id, reason) ->
      step(state, offers.depart(state, call_id, reason))

    ChannelGone(call_id) ->
      case
        dict.has_key(state.waiting, call_id),
        dict.has_key(state.offers, call_id)
      {
        // A caller whose channel is gone is an abandon, whatever the queue
        // believed. Requirement 0.6: no ghost calls.
        True, False -> step(state, offers.leave(state, call_id, Hangup))
        // Being rung for: their actor says how it ends.
        True, True -> actor.continue(state)
        // Nobody of ours: no pass for it.
        False, _ -> actor.continue(state)
      }

    Orphaned(member, agent_id, agent_call_id, answered_at, picked_up, ended) -> {
      let after =
        arrival.orphaned(
          state,
          member,
          agent_id,
          agent_call_id,
          answered_at,
          picked_up,
          ended,
        )
      // A pickup moves nobody's idle time, as its replies do not.
      case picked_up {
        True -> actor.continue(pickup.prune(after) |> pass.run)
        False -> step(state, after)
      }
    }

    // A supervisor's pickup is an offer whose replies mean something else:
    // no agent's counters or idle time move on them, so they skip `step`.
    // Where a caller handed over stands: not about an offer this
    // dispatcher made, and the start of one when it says one is going on.
    Reply(offer, types.Present(presence)) ->
      step(state, arrival.present(state, offer, presence))

    Reply(offer, reply) ->
      case pickup.holds(state, offer) {
        True -> actor.continue(pickup.replied(state, offer, reply) |> pass.run)
        False -> step(state, offers.replied(state, offer, reply))
      }

    // An actor its supervisor shut down went with its shard's calls, which
    // only ever end with the shard's whole tree (`calls.supervised`), this
    // dispatcher next. Its call goes on, and the actor of the tree that
    // takes the shard next finds it where it stands and says so
    // (*Takeover*). So its offer is let go of with nothing written or
    // published: closed here, an answered call was closed twice, once by
    // each holder (the lab of 2026-09-28, `e2e-260927-cca10`).
    OfferDown(process.ProcessDown(pid: pid, reason: reason, ..)) ->
      case shut_down(reason) {
        True ->
          step(
            state,
            offers.let_go(state, pid) |> arrival.actor_down(pid, False),
          )
        False -> actor_ended(state, pid, reason)
      }

    OfferDown(process.PortDown(..)) -> actor.continue(state)

    QueueDeleted(queue_id) -> step(state, offers.queue_deleted(state, queue_id))

    Changed -> actor.continue(view.heard_somebody(state) |> pass.run)

    // Either is the event a stand-down's write publishes, so the mark that
    // held the agent back while it was written has done its job.
    LoggedIn(agent_id) ->
      actor.continue(
        State(
          ..state,
          misses: dict.delete(state.misses, agent_id),
          stood_down: dict.delete(state.stood_down, agent_id),
        )
        |> worked.logged_in(agent_id)
        |> view.heard(agent_id)
        |> relight(agent_id)
        |> pass.run,
      )

    AgentChanged(agent_id) ->
      actor.continue(
        State(..state, stood_down: dict.delete(state.stood_down, agent_id))
        |> view.heard(agent_id)
        |> relight(agent_id)
        |> pass.run,
      )

    Tick -> step(state, State(..state, ticking: False) |> timers.tick)

    Waiting(done) -> {
      process.send(done, dict.keys(state.waiting))
      actor.continue(state)
    }

    // Both read the activity again first: they can come long after the last
    // pass, and the callflow action decides whether a caller enters the
    // queue on what `Status` says.
    Status(queue_id, done) -> {
      let state = view.read_activity(state)
      process.send(done, status.queues(state, queue_id))
      actor.continue(state)
    }

    Report(done) -> {
      let state = view.read_activity(state)
      process.send(done, status.snapshot(state))
      actor.continue(state)
    }

    OnQueueCall(done) -> {
      process.send(done, on_queue_call(state))
      actor.continue(state)
    }

    ReleaseAgent(agent_id, done) -> {
      process.send(done, knows(state, agent_id))
      let state = case pickup.release(state, agent_id) {
        Ok(state) -> state
        Error(Nil) -> offers.release_agent(state, agent_id)
      }
      activity.clear(state.config.account_id, agent_id)
      actor.continue(
        State(
          ..state,
          // An agent whose ring is being called off stays in its offer
          // until the offer says the ring is over: see
          // `offers.release_agent`.
          busy: case offers.in_offer(state, agent_id) {
            True -> state.busy
            False -> dict.delete(state.busy, agent_id)
          },
          wrapup: dict.delete(state.wrapup, agent_id),
          delayed: dict.delete(state.delayed, agent_id),
          stood_down: dict.delete(state.stood_down, agent_id),
          misses: dict.delete(state.misses, agent_id),
        )
        |> pass.run,
      )
    }

    PickUp(request, deadline_ms, done) ->
      case monotonic_ms() > deadline_ms {
        True -> {
          process.send(done, pickup.TooLate)
          actor.continue(state)
        }
        // Answered when the ring is out or could not be, which may be a
        // reply of the offer's later: see `dispatcher/pickup`.
        False ->
          pickup.start(state, request, state.config.now(), deadline_ms, done)
          |> pass.run
          |> actor.continue
      }

    Stop(done) -> {
      activity.release(state.config.account_id, process.self())
      deafen(state.listening)
      process.send(done, Nil)
      actor.stop()
    }
  }
}

/// The end of a message that may have answered or ended offers: what the
/// agents in them now are to the strategies (`dispatcher/worked`), then the
/// pass.
fn step(before: State, after: State) -> actor.Next(State, Message) {
  actor.continue(worked.observe(before, after) |> pickup.prune |> pass.run)
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// Whether there is anything to release of an agent here: an offer they are
/// in, a wrap-up or a delay. An entry in `busy` naming an offer that has
/// been replaced holds nobody (`offers.in_offer`), and the release drops it.
@internal
pub fn knows(state: State, agent_id: String) -> Bool {
  offers.in_offer(state, agent_id)
  || dict.has_key(state.wrapup, agent_id)
  || dict.has_key(state.delayed, agent_id)
}

/// Every agent this dispatcher has on a connected queue call.
fn on_queue_call(state: State) -> List(String) {
  dict.keys(state.busy)
  |> list.filter(offers.on_queue_call(state, _))
}

// --- Hearing an agent change -----------------------------------------------

/// The login lamp of an agent whose availability somebody else just
/// changed: `availability.set` published the new availability's state,
/// which is wrong for an agent on a queue call here.
fn relight(state: State, agent_id: String) -> State {
  State(
    ..state,
    lamps: presence.heard(
      state.lamps,
      agent_id,
      offers.on_queue_call(state, agent_id),
      state.config.lamp,
    ),
  )
}

/// The account's agent events, relayed into this actor as `Changed`.
///
/// Without it an agent who logs in waits out the tick before anybody rings
/// them, which is up to a second of silence for a caller who is already
/// there and an agent who is already free. The tick is still the fallback
/// and still the only thing that moves the timers: this only says "look
/// again, sooner".
///
/// The queue is the broker's own -- unnamed, auto-deleting, a minute's
/// expiry -- because nothing here has to survive this process. Losing it
/// costs the promptness and nothing else.
fn listen(
  account_id: String,
  to: Subject(Message),
  owner: Pid,
) -> Option(listener.Server) {
  case listener.start(availability_listener(account_id, to, owner)) {
    Ok(server) -> Some(server)
    Error(reason) -> {
      system.log(
        "dispatcher for account "
        <> account_id
        <> " has no agent events, the tick is on its own: "
        <> reason,
      )
      None
    }
  }
}

/// The listener, described and not started, because the description is the
/// contract with the broker and is worth asserting on without one.
pub fn availability_listener(
  account_id: String,
  to: Subject(Message),
  owner: Pid,
) -> listener.Listener {
  listener.new()
  |> listener.binding("callcenter", [
    listener.restrict_to(["agent"]),
    listener.prop("account_id", listener.Text(account_id)),
  ])
  |> listener.on_event(fn(event, _delivery) {
    case doc.get_string(event, ["Event-Name"]) {
      // Only the chosen availability: the activity, the offers and the
      // wrap-ups on this binding are this dispatcher's own doing and it
      // acted on them when it did them.
      Ok("agent_availability") -> process.send(to, availability_event(event))
      _other -> Nil
    }
  })
  |> listener.on_info(fn(info) {
    // `gen_listener` traps exits, so a dispatcher that ended would otherwise
    // leave this consuming for an account it no longer dispatches.
    case is_owner_exit(info, owner) {
      True -> stop_normally()
      False -> Nil
    }
  })
}

/// What one `agent_availability` event means to this actor.
///
/// A login -- logged out before, taking calls or on a break now -- is
/// `LoggedIn`, because it is the one that ends the misses counted against
/// the agent. Every other change of a named agent is `AgentChanged`: look
/// again, and mind their lamp if they are on a call.
///
/// An event with no agent on it, or none this dispatcher can read, is still
/// worth a pass: a dispatcher that stopped looking because a field it did
/// not recognise arrived is a caller left waiting next to a free agent.
pub fn availability_event(event: Value) -> Message {
  let to = availability_on(event, ["Availability"])
  let from = availability_on(event, ["Previous"])
  case doc.get_string(event, ["Agent-ID"]) {
    Ok(agent_id) if agent_id != "" ->
      case availability.logged_in(to), availability.logged_in(from) {
        True, False -> LoggedIn(agent_id)
        _, _ -> AgentChanged(agent_id)
      }
    _nameless -> Changed
  }
}

/// One availability off an event, logged out when the field is missing. The
/// publisher always sends `Previous`, logged out for an agent's first change;
/// the default only says what an event that lost the field must mean.
fn availability_on(event: Value, path: List(String)) -> types.Availability {
  availability.from_string(
    doc.get_string(event, path) |> result.unwrap("logged_out"),
  )
}

fn deafen(listening: Option(listener.Server)) -> Nil {
  case listening {
    Some(server) -> listener.stop(server)
    None -> Nil
  }
}

fn is_owner_exit(info: listener.Info, owner: Pid) -> Bool {
  case info {
    listener.Other(term) -> exit_from(term, owner)
    _other -> False
  }
}

@external(erlang, "callcenter_ffi", "is_exit_from")
fn exit_from(term: Dynamic, pid: Pid) -> Bool

/// End this process normally, from inside the callback it is running in.
@external(erlang, "callcenter_ffi", "stop_normally")
fn stop_normally() -> Nil

// --- What the rest of the node asks ----------------------------------------

/// What the dispatcher reads out of a queue document.
pub type QueueSettings =
  settings.QueueSettings

/// A queue document as the dispatcher reads it, with the schema's defaults
/// for everything it leaves out.
pub fn settings(
  queue_id: String,
  document: Value,
  default_announce_interval_s: Int,
  default_no_answer_status: String,
) -> QueueSettings {
  settings.queue(
    queue_id,
    document,
    default_announce_interval_s,
    default_no_answer_status,
  )
}

/// What the dispatcher reads out of a user's `call_center` object.
pub type AgentSettings =
  settings.AgentSettings

pub fn no_agent_settings() -> AgentSettings {
  settings.no_agent()
}

/// A user document's `call_center` object.
pub fn agent_settings_of(user: Value) -> AgentSettings {
  settings.agent(user)
}

/// When a caller's age counts from.
pub fn score_base(member: Member, system_time_base: Bool) -> Int {
  waiting.score_base(member, system_time_base)
}

/// Whether a caller is told where they stand. See
/// `callcenter/dispatcher/position`.
pub fn announcement_due(
  position position: Int,
  announced announced: Int,
  now now: Int,
  announced_at announced_at: Int,
  interval_s interval_s: Int,
) -> Bool {
  position.announcement_due(
    position: position,
    announced: announced,
    now: now,
    announced_at: announced_at,
    interval_s: interval_s,
  )
}

/// A tier state as the schema spells it.
pub fn tier_state_to_string(state: types.TierState) -> String {
  status.tier_state_to_string(state)
}

/// The account this dispatcher is for, from the outside.
pub fn account_of(config: Config) -> String {
  config.account_id
}

/// Unused today, kept because `Source` is what `availability.set` takes and
/// the dispatcher is the only thing that passes `NoAnswerRule`.
pub fn no_answer_source() -> Source {
  NoAnswerRule
}

/// A caller's actor that ended any other way than by its supervisor's
/// shutdown. The offer the actor held is closed first, and only then is a
/// caller still waiting joined to a new actor: the new one finds out
/// whatever the old one left ringing and says so, and a dispatcher still
/// holding the old offer would take that for an offer it already has.
fn actor_ended(
  state: State,
  pid: Pid,
  reason: process.ExitReason,
) -> actor.Next(State, Message) {
  let crashed = reason != process.Normal
  case pickup.down(state, pid, string.inspect(reason)) {
    Ok(after) ->
      actor.continue(arrival.actor_down(after, pid, crashed) |> pass.run)
    Error(Nil) ->
      case offers.down(state, pid, string.inspect(reason)) {
        Ok(after) -> step(state, arrival.actor_down(after, pid, crashed))
        // Settled already: nearly every offer's end is this.
        Error(Nil) -> step(state, arrival.actor_down(state, pid, crashed))
      }
  }
}

/// Whether a process ended because its supervisor shut it down.
fn shut_down(reason: process.ExitReason) -> Bool {
  case reason {
    process.Abnormal(reason) -> is_shutdown(reason)
    process.Normal | process.Killed -> False
  }
}

@external(erlang, "callcenter_ffi", "is_shutdown")
fn is_shutdown(reason: Dynamic) -> Bool
