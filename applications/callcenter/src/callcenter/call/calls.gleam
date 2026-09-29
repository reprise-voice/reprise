//// Every call actor of one shard, and how to reach one.
////
//// A shard's callers are commanded by one actor each
//// (`callcenter/call/actor`), and there must never be two for one call: two
//// would both send the caller commands. So an actor is only ever started
//// here, by the shard's registry, which is one process and hands out the
//// actor of a call -- starting it the first time a caller joins -- and
//// forgets it when it ends. The dispatchers reach their callers' actors
//// through it and nothing else.
////
//// The actors run under a factory supervisor beside the registry, and the
//// two are one child of the shard's tree: the last one, so that everything
//// that tells an actor something is up before it, and one that goes with
//// the shard. A shard that is lost or given up takes its actors with it,
//// and the calls they held are the next holder's, who hears them again from
//// the broker. An actor that crashes is not started again here: the
//// dispatcher watching it joins the caller to a new one, which finds out
//// from the switch where they stand (`callcenter/call/recovery`).
////
//// **Quarantine.** A call whose actors keep crashing is a call something
//// about which this code cannot get past, and starting another the same
//// way would crash it the same way, for as long as the caller waited. So
//// the registry counts each call's crashes over `strike_window_ms`: from
//// `actor.quarantine_after` on, the actor it starts is quarantined, and
//// hands the caller back on `no_agents` without trying anything else; from
//// `refuse_after` on -- the quarantine itself crashing -- it starts none,
//// and the dispatcher is left with a caller nothing commands.
////
//// The registry and the factory stand or fall together: a registry started
//// again with actors still running would know none of them, and start a
//// second actor for the next caller of theirs to join.

import callcenter/ask
import callcenter/call/actor.{type Message as ActorMessage}
import callcenter/types.{type Member, type OfferId, type OfferReply}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import kazoo/util

/// What the registry is asked.
pub type Message {
  /// The actor of a call of an account, started when there is none and
  /// `start` says one may be.
  Get(
    account_id: String,
    call_id: String,
    start: Bool,
    done: Subject(Result(Subject(ActorMessage), String)),
  )
  /// How many actors are running.
  Count(done: Subject(Int))
  /// Every actor running.
  Actors(done: Subject(List(Subject(ActorMessage))))
  /// An actor ended.
  Down(process.Down)
}

/// How the registry starts an actor for a call of an account, given how
/// often the call's actors have crashed lately.
pub type Start =
  fn(String, String, Int) -> Result(otp.Started(Subject(ActorMessage)), String)

/// How long a call's actor crashing counts against it.
pub const strike_window_ms = 600_000

/// How many crashes of a call's actors in `strike_window_ms` before the
/// registry starts it none at all.
pub const refuse_after = 6

type State {
  State(
    start: Start,
    /// Account and call to the actor.
    actors: Dict(#(String, String), #(Pid, Subject(ActorMessage))),
    /// Pid back to its account and call, for the actor's end.
    owners: Dict(Pid, #(String, String)),
    /// Account and call to when its actors crashed, newest first.
    strikes: Dict(#(String, String), List(Int)),
  )
}

/// The shard's registry, as its dispatchers reach it.
pub fn of_shard(shard: Int) -> Subject(Message) {
  process.named_subject(registry_name(shard))
}

fn registry_name(shard: Int) -> Name(Message) {
  util.name("callcenter_calls_" <> int.to_string(shard))
}

fn factory_name(
  shard: Int,
) -> Name(factory.Message(#(String, String, Int), Subject(ActorMessage))) {
  util.name("callcenter_call_actors_" <> int.to_string(shard))
}

/// The shard's calls: the factory the actors run under, then the registry
/// that starts them there, one failure boundary.
pub fn supervised(shard: Int, io: actor.Io) -> ChildSpecification(Nil) {
  let actors = factory_name(shard)
  supervision.supervisor(fn() {
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(
      factory.worker_child(fn(call: #(String, String, Int)) {
        actor.start(io, call.0, call.1, call.2)
      })
      |> factory.restart_strategy(supervision.Temporary)
      |> factory.named(actors)
      |> factory.supervised,
    )
    |> supervisor.add(
      supervision.worker(fn() {
        start_registry(
          Some(registry_name(shard)),
          fn(account_id, call_id, strikes) {
            factory.get_by_name(actors)
            |> factory.start_child(#(account_id, call_id, strikes))
            |> result.map_error(string.inspect)
          },
        )
      }),
    )
    |> supervisor.start
  })
  |> supervision.map_data(fn(_supervisor) { Nil })
}

/// Start a registry that starts its actors with `start`: the shard's
/// factory on a node, an actor with a test's `Io` in the tests.
pub fn start_registry(
  name: Option(Name(Message)),
  start: Start,
) -> Result(otp.Started(Subject(Message)), otp.StartError) {
  let builder =
    otp.new_with_initialiser(5000, fn(self) {
      otp.initialised(State(
        start: start,
        actors: dict.new(),
        owners: dict.new(),
        strikes: dict.new(),
      ))
      |> otp.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(Down),
      )
      |> otp.returning(self)
      |> Ok
    })
    |> otp.on_message(handle)
  case name {
    Some(name) -> otp.named(builder, name)
    None -> builder
  }
  |> otp.start
}

fn handle(state: State, message: Message) -> otp.Next(State, Message) {
  case message {
    Get(account_id, call_id, start, done) -> {
      let key = #(account_id, call_id)
      // An actor that has ended and whose end is still on its way here is
      // not handed out: whatever was sent it would be lost.
      let found = case dict.get(state.actors, key) {
        Ok(#(pid, _to) as actor) ->
          case process.is_alive(pid) {
            True -> Ok(actor)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
      case found, start {
        Ok(#(_pid, to)), _ -> {
          process.send(done, Ok(to))
          otp.continue(state)
        }
        Error(Nil), False -> {
          process.send(done, Error("call " <> call_id <> " has no actor"))
          otp.continue(state)
        }
        Error(Nil), True ->
          case strikes(state, key) {
            count if count >= refuse_after -> {
              process.send(
                done,
                Error(
                  "call "
                  <> call_id
                  <> " crashed its actor "
                  <> int.to_string(count)
                  <> " times, quarantined too: none is started again",
                ),
              )
              otp.continue(state)
            }
            count -> started(state, key, count, done)
          }
      }
    }

    Count(done) -> {
      process.send(done, dict.size(state.actors))
      otp.continue(state)
    }
    Actors(done) -> {
      process.send(
        done,
        dict.values(state.actors) |> list.map(fn(actor) { actor.1 }),
      )
      otp.continue(state)
    }
    Down(process.ProcessDown(pid: pid, reason: reason, ..)) ->
      case dict.get(state.owners, pid) {
        Ok(key) -> {
          let strikes = case reason {
            process.Normal -> state.strikes
            _crashed ->
              dict.insert(state.strikes, key, [
                monotonic_ms(),
                ..recent(state.strikes, key)
              ])
          }
          // The call may have a new actor already, started while this
          // one's end was on its way: that one is not forgotten.
          let actors = case dict.get(state.actors, key) {
            Ok(#(current, _to)) if current == pid ->
              dict.delete(state.actors, key)
            _ -> state.actors
          }
          otp.continue(
            State(
              ..state,
              actors: actors,
              owners: dict.delete(state.owners, pid),
              strikes: strikes,
            ),
          )
        }
        Error(Nil) -> otp.continue(state)
      }
    Down(process.PortDown(..)) -> otp.continue(state)
  }
}

/// Start a call's actor, and watch it.
fn started(
  state: State,
  key: #(String, String),
  strikes: Int,
  done: Subject(Result(Subject(ActorMessage), String)),
) -> otp.Next(State, Message) {
  case state.start(key.0, key.1, strikes) {
    Error(reason) -> {
      process.send(done, Error(reason))
      otp.continue(state)
    }
    Ok(started) -> {
      let _monitor = process.monitor(started.pid)
      process.send(done, Ok(started.data))
      otp.continue(
        State(
          ..state,
          actors: dict.insert(state.actors, key, #(started.pid, started.data)),
          owners: dict.insert(state.owners, started.pid, key),
        ),
      )
    }
  }
}

/// How often a call's actors have crashed within `strike_window_ms`.
fn strikes(state: State, key: #(String, String)) -> Int {
  list.length(recent(state.strikes, key))
}

fn recent(strikes: Dict(#(String, String), List(Int)), key) -> List(Int) {
  let since = monotonic_ms() - strike_window_ms
  dict.get(strikes, key)
  |> result.unwrap([])
  |> list.filter(fn(at) { at > since })
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

// --- Reaching a caller's actor ---------------------------------------------

/// How long the registry is given to hand an actor over, starting it if it
/// has to: an actor's start reads nothing and waits on nothing.
const get_timeout_ms = 5000

fn get(
  calls: Subject(Message),
  account_id: String,
  call_id: String,
  start: Bool,
) -> Result(Subject(ActorMessage), String) {
  case ask.call(calls, get_timeout_ms, Get(account_id, call_id, start, _)) {
    Ok(found) -> found
    Error(ask.Exited(reason)) -> Error("the call registry is gone: " <> reason)
    Error(ask.NoReply) -> Error("the call registry did not answer")
  }
}

/// Tell the caller's actor they joined a queue, starting the actor if the
/// call has none. Answers the actor's pid.
pub fn join(
  calls: Subject(Message),
  member: Member,
  resumed: Bool,
  reply_to: Subject(#(OfferId, OfferReply)),
) -> Result(Pid, String) {
  use to <- result.try(get(calls, member.account_id, member.call_id, True))
  process.send(to, actor.Join(member, resumed, reply_to))
  owner(to)
}

/// Tell the caller's actor to watch a call a node that died connected,
/// starting the actor if the call has none.
pub fn adopt(
  calls: Subject(Message),
  member: Member,
  offer: OfferId,
  agent_id: String,
  leg: String,
  answered_at: Int,
  reply_to: Subject(#(OfferId, OfferReply)),
) -> Result(Pid, String) {
  use to <- result.try(get(calls, member.account_id, member.call_id, True))
  process.send(
    to,
    actor.Adopt(member, offer, agent_id, leg, answered_at, reply_to),
  )
  owner(to)
}

/// Ask the caller's actor to ring an offer. Only a caller who has joined
/// has an actor to ask; the pid is the actor's, which the dispatcher
/// watches for as long as the offer is in flight.
pub fn ring(
  calls: Subject(Message),
  request: types.OfferRequest,
) -> Result(Pid, String) {
  use to <- result.try(get(
    calls,
    request.member.account_id,
    request.member.call_id,
    False,
  ))
  process.send(to, actor.Ring(request))
  owner(to)
}

/// Tell the caller's actor something, if the call has one.
pub fn tell(
  calls: Subject(Message),
  member: Member,
  message: ActorMessage,
) -> Nil {
  case get(calls, member.account_id, member.call_id, False) {
    Ok(to) -> process.send(to, message)
    Error(_) -> Nil
  }
}

/// Wait, for at most `within_ms`, for every call of a shard to be steady
/// before the shard is handed over (`core.steady`), and answer how many
/// were not. A shard with no calls -- or none running -- has none.
pub fn quiesce(shard: Int, within_ms: Int) -> Int {
  case process.named(registry_name(shard)) {
    Error(Nil) -> 0
    Ok(_pid) -> quiesce_of(of_shard(shard), within_ms)
  }
}

/// The same, for the calls of one registry.
pub fn quiesce_of(calls: Subject(Message), within_ms: Int) -> Int {
  case ask.call(calls, get_timeout_ms, Actors) {
    Error(_) -> 0
    Ok(actors) -> {
      let steady = process.new_subject()
      list.each(actors, process.send(_, actor.Steady(steady)))
      waiting(steady, list.length(actors), monotonic_ms() + within_ms)
    }
  }
}

fn waiting(steady: Subject(Nil), left: Int, deadline: Int) -> Int {
  case left {
    0 -> 0
    _ ->
      case process.receive(steady, int.max(deadline - monotonic_ms(), 0)) {
        Ok(Nil) -> waiting(steady, left - 1, deadline)
        Error(Nil) -> left
      }
  }
}

/// How many call actors the registry has running.
pub fn count(calls: Subject(Message)) -> Int {
  ask.call(calls, get_timeout_ms, Count) |> result.unwrap(0)
}

fn owner(to: Subject(ActorMessage)) -> Result(Pid, String) {
  process.subject_owner(to)
  |> result.replace_error("the call's actor has no process")
}
