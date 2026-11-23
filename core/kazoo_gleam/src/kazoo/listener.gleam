//// One AMQP listener, described in Gleam.
////
//// `gen_listener` is a behaviour and a behaviour is Erlang only, so every
//// Kazoo application that consumes AMQP has had to write one. There is one
//// here, `kazoo_gleam_listener`, and this is what parameterises it: bindings,
//// a queue, consume options, a prefetch, and closures for a delivery, for
//// everything else the process is sent, and for the consumer coming and
//// going.
////
//// ```gleam
//// listener.new()
//// |> listener.named(util.name("callcenter_member_listener"))
//// |> listener.binding("callcenter", [listener.restrict_to(["member_call"])])
//// |> listener.queue(
////   name: "callcenter.member." <> account_id,
////   durable: True,
////   exclusive: False,
////   auto_delete: False,
////   ttl: Infinity,
////   max_length: Infinity,
//// )
//// |> listener.consume(manual_ack: True, exclusive: False)
//// |> listener.prefetch(1)
//// |> listener.on_event(fn(event, delivery) {
////   let assert Ok(_) = queue_actor.handle(event)
////   listener.ack(delivery)
//// })
//// |> listener.supervised
//// ```
////
//// Two rules hold, and neither is checked for you:
////
//// - **A closure is quick.** All three run in the listener process itself, so
////   one that blocks stops this consumer and one that crashes takes the
////   listener down -- which is what should happen to a delivery that was never
////   acked, but not what should happen because a closure went to a database.
////   Hand the work to a named actor with a typed call and return.
//// - **`kapi` modules stay Erlang.** A binding name resolves to `kapi_<name>`,
////   so an application keeps a short, declarative Erlang module for its own
////   event family. This library does not replace that and does not want to.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import kazoo/doc.{type Value}
import kazoo/nodes

/// A listener, described but not started.
pub opaque type Listener {
  Listener(
    name: Option(Dynamic),
    bindings: List(Binding),
    queue: Queue,
    consume: Consume,
    prefetch: Int,
    on_event: Option(fn(Value, Delivery) -> Nil),
    on_info: Option(fn(Info) -> Nil),
    on_consuming: Option(fn(Bool) -> Nil),
    notify: List(NodeEvent),
  )
}

/// A listener that is running.
pub opaque type Server {
  Server(pid: Pid)
}

/// One delivery, waiting to be settled. Opaque, and only worth anything to
/// `ack` and `nack`: it carries the listener and what the broker sent with
/// the message.
pub type Delivery

/// One binding of the queue to an exchange, through the `kapi_<name>` module
/// that owns that event family.
pub opaque type Binding {
  Binding(name: String, props: List(Prop))
}

/// One property of a binding, as its `kapi` module reads it.
pub opaque type Prop {
  Prop(key: String, value: Term)
}

/// What a binding property can be. `kapi` modules take both -- an event name
/// is usually a binary and a kind of binding is usually an atom -- so the
/// distinction is yours to make and not a guess this makes for you.
///
/// `Atom` and the property keys become atoms, which are never collected:
/// write them as literals, the way `kazoo/util.name` says.
pub type Term {
  Text(String)
  Atom(String)
  Number(Int)
  Flag(Bool)
  Terms(List(Term))
}

/// A queue argument that can be turned off. `kz_amqp_util` gives every queue
/// an `x-message-ttl` of a minute and an `x-max-length` of a hundred unless
/// it is told otherwise, so a queue that has to hold work says `Infinity`.
pub type Limit {
  Infinity
  Limited(Int)
}

type Queue {
  Queue(
    name: String,
    durable: Bool,
    exclusive: Bool,
    auto_delete: Bool,
    ttl: Limit,
    max_length: Limit,
  )
}

type Consume {
  Consume(manual_ack: Bool, exclusive: Bool)
}

/// The `kz_nodes` notifications a listener can ask for. They are registered
/// from inside the listener process, because that is the process `kz_nodes`
/// remembers.
pub type NodeEvent {
  NodeUp
  NodeGone
  NodeBeat
}

/// Everything else the listener process is sent: the lifecycle casts
/// `gen_listener` makes, the `kz_nodes` notifications, and any message a
/// process sent it directly.
///
/// `Consuming` also reaches `on_consuming`, which is there so that the common
/// case does not have to match on this at all. `Consuming(False)` is the
/// consumer gone however it went: the channel lost, the consumer refused, a
/// pause, or the broker cancelling it because its queue was deleted or lost
/// -- which `gen_listener` itself does not notice, and would otherwise leave
/// a listener believing it consumes a queue that no longer feeds it.
pub type Info {
  Consuming(Bool)
  FederatorsConsuming(Bool)
  QueueCreated(String)
  NodeNew(Node)
  NodeExpire(Node)
  NodeHeartbeat(Node)
  Other(Dynamic)
}

/// A node on the cluster: `kazoo/nodes.Node`, which is the same node the
/// queries there answer with.
pub type Node =
  nodes.Node

// --- The builder -----------------------------------------------------------

/// A listener with nothing said about it: no bindings, a queue the broker
/// names and deletes with the connection, and deliveries acked as they are
/// sent.
pub fn new() -> Listener {
  Listener(
    name: None,
    bindings: [],
    queue: Queue(
      name: "",
      durable: False,
      exclusive: False,
      auto_delete: True,
      ttl: Limited(60_000),
      max_length: Limited(100),
    ),
    consume: Consume(manual_ack: False, exclusive: False),
    prefetch: 0,
    on_event: None,
    on_info: None,
    on_consuming: None,
    notify: [],
  )
}

/// Register the listener under a name, so that anything holding the name can
/// find it. Build the name with `kazoo/util.name`, from a literal.
pub fn named(listener: Listener, name: Name(message)) -> Listener {
  Listener(..listener, name: Some(as_term(name)))
}

/// Bind the queue through `kapi_<name>`. Called more than once, the bindings
/// add up, in the order they were given.
pub fn binding(
  listener: Listener,
  name: String,
  props: List(Prop),
) -> Listener {
  Listener(
    ..listener,
    bindings: list.append(listener.bindings, [
      Binding(name: name, props: props),
    ]),
  )
}

/// `{restrict_to, [...]}`, the property almost every `kapi` module takes to
/// narrow a binding to some of its events. These are the event names; for a
/// module whose `restrict_to` is a list of atoms, say
/// `prop("restrict_to", Terms([Atom("discovery")]))`.
pub fn restrict_to(names: List(String)) -> Prop {
  Prop(key: "restrict_to", value: Terms(list.map(names, Text)))
}

/// `{federate, true}`: also bind on the other zones' brokers.
pub fn federate() -> Prop {
  Prop(key: "federate", value: Flag(True))
}

/// Any other property the binding's `kapi` module reads.
pub fn prop(key: String, value: Term) -> Prop {
  Prop(key: key, value: value)
}

/// The queue itself. An empty name asks the broker for one, which is what a
/// listener that only has to hear what happens while it is up wants; a
/// durable queue with a name and no expiry is what work that has to survive
/// the node goes on.
pub fn queue(
  listener: Listener,
  name name: String,
  durable durable: Bool,
  exclusive exclusive: Bool,
  auto_delete auto_delete: Bool,
  ttl ttl: Limit,
  max_length max_length: Limit,
) -> Listener {
  Listener(
    ..listener,
    queue: Queue(
      name: name,
      durable: durable,
      exclusive: exclusive,
      auto_delete: auto_delete,
      ttl: ttl,
      max_length: max_length,
    ),
  )
}

/// How the queue is consumed. `manual_ack` is the one that matters: without
/// it the broker considers a message delivered the moment it sends it, and a
/// node that dies mid-message takes the message with it.
pub fn consume(
  listener: Listener,
  manual_ack manual_ack: Bool,
  exclusive exclusive: Bool,
) -> Listener {
  Listener(
    ..listener,
    consume: Consume(manual_ack: manual_ack, exclusive: exclusive),
  )
}

/// How many unacked messages the broker will hand this consumer. One, with
/// `manual_ack`, is how a node takes no more work than it is doing.
pub fn prefetch(listener: Listener, messages: Int) -> Listener {
  Listener(..listener, prefetch: messages)
}

/// What to do with a delivery. The event is the message as a document value,
/// converted from `kz_json` on the way; the delivery is what settles it.
pub fn on_event(
  listener: Listener,
  handler: fn(Value, Delivery) -> Nil,
) -> Listener {
  Listener(..listener, on_event: Some(handler))
}

/// What to do with everything else the process is sent.
pub fn on_info(listener: Listener, handler: fn(Info) -> Nil) -> Listener {
  Listener(..listener, on_info: Some(handler))
}

/// What to do when the consumer starts, and when it stops. A listener that
/// has work to do when its queue is live -- a sweep, a resynchronisation --
/// does it here.
pub fn on_consuming(listener: Listener, handler: fn(Bool) -> Nil) -> Listener {
  Listener(..listener, on_consuming: Some(handler))
}

/// Ask for the `kz_nodes` notifications, which then arrive at `on_info` as
/// `NodeNew`, `NodeExpire` and `NodeHeartbeat`. An expiry is how a cluster
/// hears that a node it was sharing work with is gone.
pub fn notify_nodes(
  listener: Listener,
  of events: List(NodeEvent),
) -> Listener {
  Listener(..listener, notify: list.append(listener.notify, events))
}

// --- Starting --------------------------------------------------------------

/// Start the listener. `Error` on a node with no release around it, which is
/// how a test suite and `gleam run` get to run the rest of an application.
pub fn start(listener: Listener) -> Result(Server, String) {
  case start_link(to_spec(listener)) {
    Ok(pid) -> Ok(Server(pid: pid))
    Error(reason) -> Error(reason)
  }
}

/// The listener as a child of a Gleam supervisor.
pub fn supervised(
  listener: Listener,
) -> supervision.ChildSpecification(Server) {
  supervision.worker(fn() {
    case start(listener) {
      Ok(server) -> Ok(actor.Started(pid: server.pid, data: server))
      Error(reason) -> Error(actor.InitFailed(reason))
    }
  })
}

/// The process the listener is running as, for a supervisor or a monitor.
pub fn pid(server: Server) -> Pid {
  server.pid
}

/// The queue the listener is consuming; empty until the broker has named one.
pub fn queue_name(server: Server) -> String {
  do_queue_name(server.pid)
}

/// Bind the queue to one more thing, now that it exists.
pub fn add_binding(server: Server, name: String, props: List(Prop)) -> Nil {
  do_add_binding(server.pid, binding_spec(Binding(name: name, props: props)))
}

/// Take one binding away again. The properties have to be the ones it was
/// added with.
pub fn rm_binding(server: Server, name: String, props: List(Prop)) -> Nil {
  do_rm_binding(server.pid, binding_spec(Binding(name: name, props: props)))
}

/// Ask a running listener for a `kz_nodes` notification it did not start
/// with.
pub fn notify(server: Server, of event: NodeEvent) -> Nil {
  case event {
    NodeUp -> do_notify_new(server.pid)
    NodeGone -> do_notify_expire(server.pid)
    NodeBeat -> do_notify_heartbeat(server.pid)
  }
}

/// Stop the listener. Its channel goes with it, so anything it was holding
/// unacked goes back on the queue.
pub fn stop(server: Server) -> Nil {
  do_stop(server.pid)
}

/// Settle a delivery: this one is done with, the broker can forget it.
///
/// Only a listener that asked for `manual_ack` has deliveries to settle.
/// Without it the broker counted the message as delivered when it sent it,
/// and settling it again is an error that closes the consumer's channel.
@external(erlang, "kazoo_gleam_listener", "ack")
pub fn ack(delivery: Delivery) -> Nil

/// Refuse a delivery and put it back on the queue for whoever is next. The
/// same `manual_ack` rule as `ack`.
///
/// "Whoever is next" is the broker's choice and it is not always somebody
/// else: LavinMQ hands a requeued message straight back to the consumer that
/// refused it while that consumer is still on the queue. A refusal that has
/// to reach another consumer is `pause`, then this, then `resume` after a
/// hold-off.
@external(erlang, "kazoo_gleam_listener", "nack")
pub fn nack(delivery: Delivery) -> Nil

/// Whether the broker has handed this message out before: it went to a
/// consumer that never settled it, and is now here instead.
///
/// It is the broker's own flag and not a guess, which is what makes it worth
/// acting on: a first delivery is work nobody has started, and a redelivery
/// is work that may already be half done somewhere that is no longer there.
@external(erlang, "kazoo_gleam_listener", "redelivered")
pub fn redelivered(delivery: Delivery) -> Bool

/// The listener a delivery arrived at, for a closure that was handed the
/// delivery and nothing else.
pub fn delivered_by(delivery: Delivery) -> Server {
  Server(pid: do_delivery_listener(delivery))
}

/// Stop consuming, keeping the channel and everything unsettled on it: a
/// `basic.cancel` on the listener's consumer, and nothing else.
///
/// A listener with no consumer is offered nothing, which is what makes a
/// refusal reach another node on a broker that would otherwise redeliver to
/// this one. Anything already delivered and unsettled stays this listener's
/// to settle.
pub fn pause(server: Server) -> Nil {
  do_pause(server.pid)
}

/// Consume again, on the queue the listener already has.
///
/// A listener that is still consuming is left alone, so this is safe to
/// repeat -- and worth repeating: a `pause` is answered by the broker, and a
/// resume that arrives before that answer has nothing to undo.
pub fn resume(server: Server) -> Nil {
  do_resume(server.pid)
}

/// Whether the listener has a consumer on its queue right now.
pub fn consuming(server: Server) -> Bool {
  do_consuming(server.pid)
}

@external(erlang, "kazoo_gleam_listener", "delivery_listener")
fn do_delivery_listener(delivery: Delivery) -> Pid

@external(erlang, "kazoo_gleam_listener", "pause")
fn do_pause(pid: Pid) -> Nil

@external(erlang, "kazoo_gleam_listener", "resume")
fn do_resume(pid: Pid) -> Nil

@external(erlang, "kazoo_gleam_listener", "consuming")
fn do_consuming(pid: Pid) -> Bool

// --- The spec --------------------------------------------------------------

/// The listener as the map `kazoo_gleam_listener` reads. Public because it is
/// the whole contract between the two halves, and what a test asserts on.
pub fn to_spec(listener: Listener) -> Dict(String, Dynamic) {
  let spec =
    dict.from_list([
      #(
        "bindings",
        dynamic.list(
          list.map(listener.bindings, fn(bound) { as_term(binding_spec(bound)) }),
        ),
      ),
      #("queue", as_term(queue_spec(listener.queue))),
      #("consume", as_term(consume_spec(listener.consume))),
      #("prefetch", dynamic.int(listener.prefetch)),
      #(
        "notify",
        dynamic.list(
          list.map(listener.notify, fn(event) {
            dynamic.string(node_event_name(event))
          }),
        ),
      ),
    ])
  spec
  |> insert_some("name", listener.name)
  |> insert_some("on_event", option.map(listener.on_event, event_closure))
  |> insert_some("on_info", option.map(listener.on_info, info_closure))
  |> insert_some("on_consuming", option.map(listener.on_consuming, as_term))
}

fn insert_some(
  spec: Dict(String, Dynamic),
  key: String,
  value: Option(Dynamic),
) -> Dict(String, Dynamic) {
  case value {
    Some(value) -> dict.insert(spec, key, value)
    None -> spec
  }
}

/// The event closure the Erlang side calls, with the map it is handed decoded
/// into a document value first.
fn event_closure(handler: fn(Value, Delivery) -> Nil) -> Dynamic {
  as_term(fn(event: Dynamic, delivery: Delivery) {
    handler(doc.from_dynamic(event), delivery)
  })
}

/// The info closure, with the term the listener was sent decoded first.
fn info_closure(handler: fn(Info) -> Nil) -> Dynamic {
  as_term(fn(info: Dynamic) { handler(decode_info(info)) })
}

fn binding_spec(bound: Binding) -> Dict(String, Dynamic) {
  dict.from_list([
    #("binding", dynamic.string(bound.name)),
    #(
      "props",
      dynamic.list(
        list.map(bound.props, fn(property) {
          as_term(
            dict.from_list([
              #("key", dynamic.string(property.key)),
              #("value", term_spec(property.value)),
            ]),
          )
        }),
      ),
    ),
  ])
}

fn term_spec(term: Term) -> Dynamic {
  let #(kind, value) = case term {
    Text(text) -> #("text", dynamic.string(text))
    Atom(name) -> #("atom", dynamic.string(name))
    Number(number) -> #("int", dynamic.int(number))
    Flag(flag) -> #("bool", dynamic.bool(flag))
    Terms(terms) -> #("list", dynamic.list(list.map(terms, term_spec)))
  }
  as_term(dict.from_list([#("kind", dynamic.string(kind)), #("value", value)]))
}

fn queue_spec(queue: Queue) -> Dict(String, Dynamic) {
  dict.from_list([
    #("name", dynamic.string(queue.name)),
    #("durable", dynamic.bool(queue.durable)),
    #("exclusive", dynamic.bool(queue.exclusive)),
    #("auto_delete", dynamic.bool(queue.auto_delete)),
    #("ttl", limit_spec(queue.ttl)),
    #("max_length", limit_spec(queue.max_length)),
  ])
}

fn limit_spec(limit: Limit) -> Dynamic {
  case limit {
    Infinity -> dynamic.string("infinity")
    Limited(value) -> dynamic.int(value)
  }
}

fn consume_spec(consume: Consume) -> Dict(String, Dynamic) {
  dict.from_list([
    #("manual_ack", dynamic.bool(consume.manual_ack)),
    #("exclusive", dynamic.bool(consume.exclusive)),
  ])
}

fn node_event_name(event: NodeEvent) -> String {
  case event {
    NodeUp -> "new"
    NodeGone -> "expire"
    NodeBeat -> "heartbeat"
  }
}

// --- Decoding what the listener is sent ------------------------------------

/// The term the info closure was handed, as an `Info`. Total: a message this
/// does not know is an `Other`, not a crash in a listener.
pub fn decode_info(info: Dynamic) -> Info {
  case decode.run(info, info_decoder()) {
    Ok(info) -> info
    Error(_) -> Other(info)
  }
}

fn info_decoder() -> decode.Decoder(Info) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "consuming" -> {
      use value <- decode.field("value", decode.bool)
      decode.success(Consuming(value))
    }
    "federators_consuming" -> {
      use value <- decode.field("value", decode.bool)
      decode.success(FederatorsConsuming(value))
    }
    "queue_created" -> {
      use queue <- decode.field("queue", decode.string)
      decode.success(QueueCreated(queue))
    }
    "node_new" -> decode.map(node_field(), NodeNew)
    "node_expire" -> decode.map(node_field(), NodeExpire)
    "node_heartbeat" -> decode.map(node_field(), NodeHeartbeat)
    _ -> decode.failure(Other(dynamic.nil()), "Info")
  }
}

fn node_field() -> decode.Decoder(Node) {
  decode.at(["node"], nodes.decoder())
}

// --- The Erlang half -------------------------------------------------------

@external(erlang, "kazoo_gleam_listener", "as_term")
fn as_term(value: anything) -> Dynamic

@external(erlang, "kazoo_gleam_listener", "start_link_result")
fn start_link(spec: Dict(String, Dynamic)) -> Result(Pid, String)

@external(erlang, "kazoo_gleam_listener", "queue_name")
fn do_queue_name(server: Pid) -> String

@external(erlang, "kazoo_gleam_listener", "add_binding")
fn do_add_binding(server: Pid, binding: Dict(String, Dynamic)) -> Nil

@external(erlang, "kazoo_gleam_listener", "rm_binding")
fn do_rm_binding(server: Pid, binding: Dict(String, Dynamic)) -> Nil

@external(erlang, "kazoo_gleam_listener", "notify_new")
fn do_notify_new(server: Pid) -> Nil

@external(erlang, "kazoo_gleam_listener", "notify_expire")
fn do_notify_expire(server: Pid) -> Nil

@external(erlang, "kazoo_gleam_listener", "notify_heartbeat")
fn do_notify_heartbeat(server: Pid) -> Nil

@external(erlang, "kazoo_gleam_listener", "stop")
fn do_stop(server: Pid) -> Nil
