//// The node's call publishers: what every call actor publishes goes out
//// through one of these, and none of it from the actor.
////
//// **Why not the actor.** `kz_amqp_assignments` gives every process that
//// publishes an AMQP channel of its own, and the process keeps it for the
//// rest of its life. An actor that published its caller's commands itself
//// held a channel for as long as its call lasted, so a node's channels grew
//// one for one with the calls queued on it, towards the broker's
//// `channel_max` for the connection (2047 on RabbitMQ). Past it the broker
//// refuses `channel.open` with `out_of_channel_numbers`, and no actor on the
//// node can ring an agent or command a caller any more.
////
//// **Why this keeps the order.** A node runs `call_publishers` of these
//// (`system_config/callcenter`, 16, at most 256), each asking for its
//// channel once as it starts. A call's actor hands everything it would publish to the one
//// publisher its call id hashes to -- `erlang:phash2(call_id, count)` -- as a
//// message, in the order `callcenter/call/core` decided it. One sender, one
//// receiver, one channel: Erlang keeps the order of the messages between two
//// processes, the publisher runs them one at a time, and the broker keeps the
//// order of what one channel carries. So the commands to the caller's
//// control queue, the offer's `originate_req`, its legs' hangups,
//// `member_continue` and `callflow.resume` go out in the order they were
//// decided, and on the one channel -- which the actor publishing through
//// `kazoo/amqp` never promised for the last four: that goes through the
//// node's worker pool, a channel per worker, whichever worker is free. They
//// are published from here with `publish` and `publish_to` instead, from
//// the publisher's own process.
////
//// **What stays with the actor.** Only what is published comes here. A
//// dispatcher's reply, the shard's word that a caller left and the record's
//// write are sent to processes by the actor itself: the dispatcher watches
//// the actor, and a reply sent from any other process could reach it after
//// the actor's own end. The answers to what the actor asks still come to
//// the actor, at its own address (`pid://<actor>/<queue>`, which is worked
//// out in the actor and carried in the message); nothing is ever addressed
//// to a publisher.
////
//// **What a publisher runs.** A function, run from the publisher's process
//// so that whatever it publishes is on the publisher's channel. Anything it
//// throws is caught and logged against the call: the calls queued behind it
//// on the same publisher must not go with its mailbox. What it cannot say
//// is logged where it is decided, as it was in the actor. `kz_amqp_assignments`
//// also tells the publisher about its channel, and the broker hands it back
//// a mandatory message nobody could route; the publisher reads and drops
//// both, as `kz_amqp_worker` does. The actor also sends its answer to a
//// shard asking whether the call is steady through here, behind what it
//// handed over, so that a shard is never handed over with a call's work
//// still waiting to go out.
////
//// **What it costs.** A publisher whose channel is lost waits for the next
//// one, as any process that publishes does, and the calls on it wait with
//// it: a `call_publishers`th of the node's calls, where each call's actor
//// used to wait for its own. The work itself is small -- a document encoded
//// and a publish -- and whatever reads a document (the account's recording
//// settings) is read by the actor before it hands the rest over.
////
//// A node that runs no pool -- no broker, the test suite -- has nothing to
//// publish on, and the functions an actor hands over are run where they are
//// handed over instead (`of_call`).

import callcenter/stall
import callcenter/system
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/util

/// What a publisher is sent.
pub type Message {
  /// Run `run` from the publisher's process, after everything sent to it
  /// before, for the call `call_id`, handed over by an actor that started
  /// at `since`, the VM's monotonic milliseconds.
  Run(call_id: String, since: Int, run: fn() -> Nil)
  /// Ask for the publisher's channel: sent to itself as it starts.
  Connect
  /// Anything else in its mailbox: `kz_amqp_assignments`' word about its
  /// channel, a message the broker returned.
  Ignored
}

/// A pool: the prefix its publishers are registered under, and how many
/// there are.
pub type Pool {
  Pool(prefix: String, count: Int)
}

/// What a publisher reaches outside itself.
pub type Io {
  Io(
    /// Ask for this process's own AMQP channel, and say whether it has one
    /// yet.
    channel: fn() -> Bool,
    /// Whether work handed over by an actor started at this monotonic
    /// millisecond may still go out: `stall.fresh` on a node.
    fresh: fn(Int) -> Bool,
  )
}

/// `system_config/callcenter.call_publishers` when it is not set.
pub const default_count = 16

/// The most a node runs, whatever the configuration says: every publisher
/// is a registered name, which is an atom for good.
pub const most = 256

/// The node term the node's pool is described under while it runs.
const pool_term = "call_publishers"

/// The prefix the node's publishers are registered under.
const node_prefix = "callcenter_call_publisher_"

/// How many publishers the node runs: `call_publishers`, from one to
/// `most`.
pub fn count(kz: Kazoo) -> Int {
  kz.config.get_int("call_publishers", default_count)
  |> int.clamp(min: 1, max: most)
}

/// The node's publishers, for its supervision tree: `count` of them under
/// a supervisor of their own, one for one, so that a publisher that ends is
/// started again on its own. The pool is described in a node term as it
/// starts, which is how the actors find it (`of_call`); a count changed in
/// the configuration is read when the pool is started again.
pub fn supervised(kz: Kazoo) -> ChildSpecification(Nil) {
  supervision.supervisor(fn() {
    let pool = Pool(prefix: node_prefix, count: count(kz))
    put_node_term(pool_term, pool.count)
    start(pool, Io(channel: ensure_channel, fresh: stall.fresh))
  })
  |> supervision.map_data(fn(_supervisor) { Nil })
}

/// Start a pool's publishers under a supervisor: the node's, or a test's
/// with its own prefix and `Io`.
pub fn start(
  pool: Pool,
  io: Io,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  int.range(
    from: 0,
    to: pool.count,
    with: supervisor.new(supervisor.OneForOne),
    run: fn(tree, index) {
      supervisor.add(
        tree,
        supervision.worker(fn() { start_publisher(name(pool, index), io) }),
      )
    },
  )
  |> supervisor.start
}

/// The publisher a call's work goes to: the same one for every message of
/// the call, for as long as the pool runs.
pub fn index(call_id: String, count: Int) -> Int {
  phash2(call_id, int.max(count, 1))
}

/// The registered name of a pool's publisher.
pub fn name(pool: Pool, index: Int) -> Name(Message) {
  util.name(pool.prefix <> int.to_string(index))
}

/// Hand `run` to the call's publisher, behind everything handed to it
/// before, from an actor that started at `since`. A publisher that is not
/// running -- its supervisor is starting it again -- drops it, and that is
/// logged: it is sent to the process found under the name and not to the
/// name, so a publisher that goes between the two is never the crash of the
/// actor sending.
pub fn send(pool: Pool, call_id: String, since: Int, run: fn() -> Nil) -> Nil {
  let index = index(call_id, pool.count)
  let name = name(pool, index)
  case process.named(name) {
    Ok(pid) ->
      process.send(
        process.unsafely_create_subject(pid, name_tag(name)),
        Run(call_id, since, run),
      )
    Error(Nil) ->
      system.log_error(
        "call "
        <> call_id
        <> ": call publisher "
        <> int.to_string(index)
        <> " is not running: what the call sent now is lost",
      )
  }
}

/// The node's pool, while it runs one.
pub fn node_pool() -> Option(Pool) {
  case node_term(pool_term) {
    Ok(count) if count > 0 -> Some(Pool(prefix: node_prefix, count: count))
    _ -> None
  }
}

/// How a call's actor on this node publishes: through the call's publisher
/// in the node's pool, or at once, in the actor's own process, on a node
/// that runs none -- where there is no broker to publish to, and every
/// publish is `Unavailable` wherever it is made.
pub fn of_call(call_id: String, since: Int) -> fn(fn() -> Nil) -> Nil {
  case node_pool() {
    Some(pool) -> send(pool, call_id, since, _)
    None -> fn(run) { run() }
  }
}

/// Publish through `kapi_<module>:publish_<function>/1` from this process,
/// on its own channel, where `amqp.publish` would hand the message to the
/// node's worker pool.
pub fn publish(
  module module: String,
  function function: String,
  payload payload: Value,
) -> Result(Nil, amqp.Error) {
  publish_here(module, function, doc.to_string(payload))
  |> result.map_error(to_error)
}

/// The same at one queue, through `kapi_<module>:publish_<function>/2`,
/// where `amqp.publish_to` would.
pub fn publish_to(
  target target: String,
  module module: String,
  function function: String,
  payload payload: Value,
) -> Result(Nil, amqp.Error) {
  publish_here_to(target, module, function, doc.to_string(payload))
  |> result.map_error(to_error)
}

fn to_error(reason: String) -> amqp.Error {
  case reason {
    "unavailable" -> amqp.Unavailable
    other -> amqp.Failed(other)
  }
}

// --- A publisher -------------------------------------------------------------

fn start_publisher(
  name: Name(Message),
  io: Io,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    // The channel is asked for in a message to itself and not here, which
    // the supervisor waits on: with the broker away every publisher would
    // hold the node's start-up for the whole of the wait. A call's work that
    // gets in first is no harm: publishing asks for the channel too.
    process.send(self, Connect)
    actor.initialised(Publisher(io: io, dropping: None))
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_other(fn(_anything) { Ignored }),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// A publisher: its reach, and the call whose work it last dropped, so that
/// a call's work dropped in a run is logged once.
type Publisher {
  Publisher(io: Io, dropping: Option(String))
}

fn handle(
  publisher: Publisher,
  message: Message,
) -> actor.Next(Publisher, Message) {
  let io = publisher.io
  case message {
    Connect -> {
      let _ = io.channel()
      actor.continue(publisher)
    }
    Run(call_id, since, run) ->
      case io.fresh(since) {
        True -> {
          case run_guarded(run) {
            Ok(Nil) -> Nil
            Error(reason) ->
              system.log_error(
                "call " <> call_id <> ": publishing crashed: " <> reason,
              )
          }
          actor.continue(Publisher(..publisher, dropping: None))
        }
        // From an actor started before the node stood still, of a shard the
        // broker may have given another node meanwhile: dropped, since
        // whatever it commands is that node's to command now
        // (`callcenter/stall`). Whether it was handed over before the stall
        // or after, by an actor that had got past its own fence before the
        // node stopped and went on after.
        False -> {
          case publisher.dropping == Some(call_id) {
            True -> Nil
            False ->
              system.log(
                "call "
                <> call_id
                <> ": dropping what its actor sent before this node stood still",
              )
          }
          actor.continue(Publisher(..publisher, dropping: Some(call_id)))
        }
      }
    Ignored -> actor.continue(publisher)
  }
}

@external(erlang, "erlang", "phash2")
fn phash2(term: String, range: Int) -> Int

@external(erlang, "gleam_stdlib", "identity")
fn name_tag(name: Name(Message)) -> Dynamic

@external(erlang, "callcenter_ffi", "ensure_channel")
fn ensure_channel() -> Bool

@external(erlang, "callcenter_ffi", "run_guarded")
fn run_guarded(run: fn() -> Nil) -> Result(Nil, String)

@external(erlang, "callcenter_ffi", "publish_here")
fn publish_here(
  module: String,
  function: String,
  json: String,
) -> Result(Nil, String)

@external(erlang, "callcenter_ffi", "publish_here_to")
fn publish_here_to(
  target: String,
  module: String,
  function: String,
  json: String,
) -> Result(Nil, String)

@external(erlang, "callcenter_ffi", "put_node_term")
fn put_node_term(name: String, value: Int) -> Nil

@external(erlang, "callcenter_ffi", "node_term")
fn node_term(name: String) -> Result(Int, Nil)
