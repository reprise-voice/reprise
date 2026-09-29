//// The account's channels, asked of the switches once for many callers.
////
//// A node taking a shard over meets every caller of it at once, and each
//// caller's actor wants the account's channels to find its legs
//// (`callcenter/call/recovery`). Asked by each, that is every `ecallmgr`
//// listing every channel of the account once per caller, all in the same
//// second. So the node's actors ask here instead: one question per account
//// is in flight at a time, everybody who asks while it is gets its answer,
//// and an answer is handed out again for `fresh_ms` after it was asked for.
//// A snapshot that old still finds every leg that was ringing when the
//// node that died went: legs ring for tens of seconds.

import callcenter/ask
import callcenter/system
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import kazoo/events
import kazoo/util

/// How long an answer is handed out again after it was asked for.
pub const fresh_ms = 2000

/// How long an actor waits here for an answer: the question gives the
/// switches two seconds, and it may be queued behind one already asked.
const wait_ms = 6000

pub type Message {
  /// The account's channels: `None` when no switch answered.
  Channels(account_id: String, done: Subject(Option(events.Channels)))
  /// A question asked at `asked_ms` came back.
  Answered(account_id: String, asked_ms: Int, answer: Option(events.Channels))
}

type State {
  State(
    self: Subject(Message),
    query: fn(String) -> Option(events.Channels),
    now_ms: fn() -> Int,
    /// Account to everybody waiting for the question in flight.
    waiting: Dict(String, List(Subject(Option(events.Channels)))),
    /// Account to the last answer and when it was asked for.
    last: Dict(String, #(Int, Option(events.Channels))),
  )
}

fn name() -> Name(Message) {
  util.name("callcenter_call_snapshots")
}

/// The node's snapshots, asking the switches.
pub fn supervised() -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(Some(name()), query, monotonic_ms) })
}

fn query(account_id: String) -> Option(events.Channels) {
  events.query_account_channels(app: system.category, account_id: account_id)
  |> option.from_result
}

/// Start one: named on a node, anonymous with a test's `query` and clock.
pub fn start(
  name: Option(Name(Message)),
  query: fn(String) -> Option(events.Channels),
  now_ms: fn() -> Int,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  let builder =
    actor.new_with_initialiser(1000, fn(self) {
      actor.initialised(State(
        self: self,
        query: query,
        now_ms: now_ms,
        waiting: dict.new(),
        last: dict.new(),
      ))
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Channels(account_id, done) -> {
      let now = state.now_ms()
      case
        dict.get(state.last, account_id),
        dict.get(state.waiting, account_id)
      {
        Ok(#(asked, answer)), _ if now - asked < fresh_ms -> {
          process.send(done, answer)
          actor.continue(state)
        }
        _, Ok(waiting) ->
          actor.continue(
            State(
              ..state,
              waiting: dict.insert(state.waiting, account_id, [done, ..waiting]),
            ),
          )
        _, Error(Nil) -> {
          let self = state.self
          let query = state.query
          let _ =
            process.spawn_unlinked(fn() {
              process.send(self, Answered(account_id, now, query(account_id)))
            })
          actor.continue(
            State(
              ..state,
              waiting: dict.insert(state.waiting, account_id, [done]),
            ),
          )
        }
      }
    }
    Answered(account_id, asked, answer) -> {
      dict.get(state.waiting, account_id)
      |> result.unwrap([])
      |> list.each(fn(done) { process.send(done, answer) })
      actor.continue(
        State(
          ..state,
          waiting: dict.delete(state.waiting, account_id),
          last: dict.insert(state.last, account_id, #(asked, answer)),
        ),
      )
    }
  }
}

/// The account's channels, through the node's snapshots: `None` when no
/// switch answered, or there are no snapshots to ask.
pub fn channels(account_id: String) -> Option(events.Channels) {
  channels_of(process.named_subject(name()), account_id)
}

/// The account's channels, through these snapshots.
pub fn channels_of(
  snapshots: Subject(Message),
  account_id: String,
) -> Option(events.Channels) {
  ask.call(snapshots, wait_ms, Channels(account_id, _))
  |> result.unwrap(None)
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
