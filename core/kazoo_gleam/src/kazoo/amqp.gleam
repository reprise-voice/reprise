//// Publishing, and asking the cluster something.
////
//// Every message on the bus belongs to a `kapi` module, which says what its
//// fields are, validates them and knows the routing key. Those modules are
//// declarative and stay in Erlang by design; this calls one by name:
////
//// ```gleam
//// amqp.publish("switch", "notify", payload)
//// // -> kapi_switch:publish_notify/1
//// ```
////
//// A request is the same publish with an answer waited for: `call` for the
//// one answer a request has, `call_collect` for the answers every node has.
//// Both take the payload as a document value and give the answers back as
//// document values; `kz_json` does not enter Gleam.
////
//// Nothing here needs a broker to be called. Without a release -- in a test,
//// under `gleam run` -- every one of them is `Error(Unavailable)`, so an
//// application can be exercised end to end without one.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import kazoo/doc.{type Value}

/// What can go wrong on the way to the broker.
pub type Error {
  /// No release, no broker, or no `kapi` function of that name: the message
  /// did not go out.
  Unavailable
  /// It went out, and nothing answered before the timeout.
  NoAnswer
  /// The broker returned it, or a worker refused it.
  Failed(String)
}

pub fn error_to_string(error: Error) -> String {
  case error {
    Unavailable -> "unavailable"
    NoAnswer -> "no_answer"
    Failed(reason) -> reason
  }
}

fn to_error(reason: String) -> Error {
  case reason {
    "unavailable" -> Unavailable
    "no_answer" -> NoAnswer
    other -> Failed(other)
  }
}

/// When a collection is finished.
pub type Until {
  /// Every `ecallmgr` on the cluster has answered. This is the one the
  /// channel queries use.
  Ecallmgr
  /// Every node running that application has answered, federated zones
  /// included.
  Whapp(String)
  /// That many answers are in.
  Count(Int)
  /// Whatever arrived before the timeout.
  Deadline
}

/// Publish through `kapi_<module>:publish_<function>/1` and do not wait.
pub fn publish(
  module module: String,
  function function: String,
  payload payload: Value,
) -> Result(Nil, Error) {
  do_publish(module, function, doc.to_string(payload))
  |> result.map_error(to_error)
}

/// Publish through `kapi_<module>:publish_<function>/2` at one queue.
///
/// Every answer on the bus goes out this way: a request carried a `Server-ID`,
/// and that is the queue its answer is published at.
pub fn publish_to(
  target target: String,
  module module: String,
  function function: String,
  payload payload: Value,
) -> Result(Nil, Error) {
  do_publish_to(target, module, function, doc.to_string(payload))
  |> result.map_error(to_error)
}

/// Publish through `kapi_<module>:publish_<function>/2` at one queue, and
/// wait for the broker to say it has the message.
///
/// On a channel in confirm mode whose process is the channel's return
/// handler, so that a message the `kapi` function publishes `mandatory` and
/// the broker cannot route is heard of: `Failed("returned")`. The broker
/// refusing it is `Failed("nacked")`. No confirmation within the timeout is
/// `NoAnswer`, and the message may well have arrived -- as it is when the
/// channel is lost while the message waits; no broker is `Unavailable`, and
/// it did not go out.
///
/// The channel is the node's `confirming_publisher` when the application
/// runs one, its channel is ready and the `kapi` module builds the message
/// without sending it (`prepare_<function>/2`), and otherwise one taken for
/// this message and closed after it.
///
/// For the one message a caller cannot afford to lose silently. Everything
/// else is `publish_to`, which costs no channel of its own.
pub fn publish_to_confirmed(
  target target: String,
  module module: String,
  function function: String,
  payload payload: Value,
  timeout timeout_ms: Int,
) -> Result(Nil, Error) {
  do_publish_to_confirmed(
    target,
    module,
    function,
    doc.to_string(payload),
    timeout_ms,
  )
  |> result.map_error(to_error)
}

/// The node's confirming publisher, for an application's supervision tree:
/// one channel in confirm mode that every `publish_to_confirmed` on the node
/// goes out on, instead of a channel of its own each. It asks
/// `kz_amqp_assignments` for its channel, puts every channel it is given in
/// confirm mode, and answers every message waiting on a channel that is
/// lost with `NoAnswer`.
///
/// One per node, registered: a second one does not start. An application
/// that publishes confirmed messages and runs where there is a broker adds
/// it.
pub fn confirming_publisher() -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    case start_confirming_publisher() {
      Ok(pid) -> Ok(actor.Started(pid: pid, data: Nil))
      Error(reason) -> Error(actor.InitFailed(reason))
    }
  })
}

/// What the confirming publisher answers over a run of events on its
/// channel: `#(published, tag, msg_id, expiry)` for a message going out,
/// whose time runs out with `#(expire, expiry)` -- `#(published, tag,
/// msg_id)` when that is `#(expire, tag)` -- and otherwise the broker's
/// messages, or `lost_channel`. The answers, in the order they are given,
/// by delivery tag. For the tests.
pub fn confirmations(
  script: List(Dynamic),
) -> List(#(Int, Result(Nil, Error))) {
  do_confirmations(script)
  |> list.map(fn(answer) { #(answer.0, result.map_error(answer.1, to_error)) })
}

/// What a confirming publisher makes of the broker's messages, in order:
/// what `publish_to_confirmed` waits for, over a list. For the tests.
pub fn confirmed(
  returned: Bool,
  messages: List(Dynamic),
) -> Result(Nil, Error) {
  do_confirmed(returned, messages) |> result.map_error(to_error)
}

/// Publish one message straight at a queue, through the default exchange.
///
/// Every queue is bound to the default exchange under its own name, so this
/// is how a plain work queue is fed: no exchange, no binding, no `kapi`
/// module, and the queue's name as the routing key. It is the other half of
/// a `kazoo/listener` with a queue and no bindings.
///
/// The message is persistent, which with a durable queue is what makes it
/// outlast the broker.
pub fn publish_to_queue(
  queue queue: String,
  payload payload: Value,
) -> Result(Nil, Error) {
  do_publish_to_queue(queue, doc.to_string(payload))
  |> result.map_error(to_error)
}

/// Publish the same way and wait for one answer.
pub fn call(
  module module: String,
  function function: String,
  payload payload: Value,
  timeout timeout_ms: Int,
) -> Result(Value, Error) {
  do_call(module, function, doc.to_string(payload), timeout_ms)
  |> result.map(doc.from_dynamic)
  |> result.map_error(to_error)
}

/// Publish the same way and collect what the cluster answers.
///
/// A collection that ran out of time with some answers in is not an error:
/// the answers that did arrive are the result, which is what a query of
/// every node has to live with -- one that is restarting answers nothing.
/// One with no answer at all -- the timeout ended it, or there was nobody to
/// ask -- is `NoAnswer`, as `collected` says. A question whose answer can be "nobody has it" is not
/// asked this way: `call_collect_all`.
pub fn call_collect(
  module module: String,
  function function: String,
  payload payload: Value,
  until until: Until,
  timeout timeout_ms: Int,
) -> Result(List(Value), Error) {
  call_collect_all(
    module: module,
    function: function,
    payload: payload,
    until: until,
    timeout: timeout_ms,
  )
  |> result.try(fn(collection) {
    collected(collection.answers, finished: collection.finished)
  })
}

/// A collection as it ended: the answers that arrived, and whether every
/// node asked had answered by then.
pub type Collection {
  Collection(answers: List(Value), finished: Bool)
}

/// Publish the same way and collect, keeping whether the collection
/// finished.
///
/// What `call_collect` gives up for convenience: a collection the timeout
/// ended with some answers in it is a list there, the same list a cluster
/// where every node answered would have given. A question whose answer is
/// "nobody has it" cannot be asked that way -- a node that did not answer is
/// a node that may have it -- so it is asked this way, and whoever asked
/// reads `finished`. A collection that ran out of time with nothing in it is
/// `Collection([], False)` here, not an error, and one that `kz_nodes` found
/// nobody to ask is `Collection([], True)`: whoever reads an empty
/// collection as "nobody has it" reads neither of them so (`collected`).
pub fn call_collect_all(
  module module: String,
  function function: String,
  payload payload: Value,
  until until: Until,
  timeout timeout_ms: Int,
) -> Result(Collection, Error) {
  let #(kind, argument) = case until {
    Ecallmgr -> #("whapp", "ecallmgr")
    Whapp(app) -> #("whapp", app)
    Count(answers) -> #("count", int.to_string(answers))
    Deadline -> #("deadline", "")
  }
  do_call_collect(
    module,
    function,
    doc.to_string(payload),
    kind,
    argument,
    timeout_ms,
  )
  |> result.map_error(to_error)
  |> result.map(fn(outcome) {
    let #(finished, answers) = outcome
    Collection(answers: list.map(answers, doc.from_dynamic), finished: finished)
  })
}

/// What a collection is once it is over: the answers, or `NoAnswer`.
///
/// `finished` is whether the collection ended on its own terms -- every node
/// asked had answered, the count was reached -- or on the timeout. The
/// timeout ending a collection that has answers in it is the ordinary case
/// of a node that was restarting; the timeout ending one with nothing in it
/// is a request nobody heard. A consumer that is still being rebound after
/// the broker came back, or a cluster with nobody listening, leaves the same
/// empty list as a cluster that answered "nothing" from every node, and the
/// two must not be one value: a caller asked about is not gone because the
/// question was lost.
///
/// An empty collection that finished is `NoAnswer` too. `kz_amqp_worker`
/// finishes a collection at once, with nothing in it and nothing published,
/// when `kz_nodes` counts no node of the application it is to be collected
/// from: an `ecallmgr` restarting, a zone that does not match, a node list
/// not yet heard. That is nobody having been asked, not every node saying
/// "nothing" -- a node with nothing to say still answers, with an empty
/// list of its own -- and a caller reading it as "no channels" wipes what
/// it knows about calls that are up. A count or a deadline never finishes
/// empty, so this is only ever that.
pub fn collected(
  answers: List(a),
  finished _finished: Bool,
) -> Result(List(a), Error) {
  case answers {
    [] -> Error(NoAnswer)
    answers -> Ok(answers)
  }
}

/// The headers every message on the bus carries: the application, its
/// version, the node, and what the message is.
///
/// Merge them under the message's own fields:
///
/// ```gleam
/// doc.merge(amqp.default_headers("callcenter", "callcenter", "member_call"), body)
/// ```
///
/// `Server-ID` and `Msg-ID` are not among them. `kz_amqp_worker` sets those
/// itself for a request it is going to wait on, and a publish that waits for
/// nothing has no use for them.
pub fn default_headers(
  app app: String,
  category category: String,
  name name: String,
) -> Value {
  doc.from_dynamic(do_default_headers(app, category, name))
}

@external(erlang, "kazoo_gleam_amqp_ffi", "publish")
fn do_publish(
  module: String,
  function: String,
  payload: String,
) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_amqp_ffi", "publish_to")
fn do_publish_to(
  target: String,
  module: String,
  function: String,
  payload: String,
) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_amqp_ffi", "publish_to_confirmed")
fn do_publish_to_confirmed(
  target: String,
  module: String,
  function: String,
  payload: String,
  timeout_ms: Int,
) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_amqp_ffi", "confirmed")
fn do_confirmed(returned: Bool, messages: List(Dynamic)) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_amqp_ffi", "start_confirming_publisher")
fn start_confirming_publisher() -> Result(Pid, String)

@external(erlang, "kazoo_gleam_amqp_ffi", "confirmations")
fn do_confirmations(script: List(Dynamic)) -> List(#(Int, Result(Nil, String)))

@external(erlang, "kazoo_gleam_amqp_ffi", "publish_to_queue")
fn do_publish_to_queue(queue: String, payload: String) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_amqp_ffi", "call")
fn do_call(
  module: String,
  function: String,
  payload: String,
  timeout_ms: Int,
) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_amqp_ffi", "call_collect")
fn do_call_collect(
  module: String,
  function: String,
  payload: String,
  kind: String,
  argument: String,
  timeout_ms: Int,
) -> Result(#(Bool, List(Dynamic)), String)

@external(erlang, "kazoo_gleam_amqp_ffi", "default_headers")
fn do_default_headers(app: String, category: String, name: String) -> Dynamic
