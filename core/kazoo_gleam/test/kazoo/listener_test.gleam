//// The listener, on a node with no release around it: the spec the builder
//// produces, which is the whole contract with `kazoo_gleam_listener`, and the
//// decoding of what that listener hands back.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import kazoo/listener
import kazoo/nodes
import kazoo/util

/// A dynamic map with the string keys Erlang sees as binaries, which is what
/// both halves of the listener speak.
fn map(entries: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    list.map(entries, fn(entry) { #(dynamic.string(entry.0), entry.1) }),
  )
}

/// The identity the listener's spec carries a name and a closure through.
@external(erlang, "kazoo_gleam_listener", "as_term")
fn as_term(value: anything) -> Dynamic

fn field(spec: dict.Dict(String, Dynamic), key: String) -> Dynamic {
  let assert Ok(value) = dict.get(spec, key)
  value
}

fn at(value: Dynamic, path: List(String), of: decode.Decoder(a)) -> a {
  let assert Ok(decoded) = decode.run(value, decode.at(path, of))
  decoded
}

fn decoded(value: Dynamic, of: decode.Decoder(a)) -> a {
  let assert Ok(decoded) = decode.run(value, of)
  decoded
}

/// A listener nobody said anything about: a queue the broker names and
/// deletes, the arguments `kz_amqp_util` would have injected anyway, and no
/// prefetch.
pub fn default_spec_test() {
  let spec = listener.new() |> listener.to_spec

  assert dict.get(spec, "name") == Error(Nil)
  assert dict.get(spec, "on_event") == Error(Nil)
  assert dict.get(spec, "on_info") == Error(Nil)
  assert dict.get(spec, "on_consuming") == Error(Nil)

  assert decoded(field(spec, "bindings"), decode.list(decode.dynamic)) == []
  assert decoded(field(spec, "notify"), decode.list(decode.string)) == []
  assert decoded(field(spec, "prefetch"), decode.int) == 0

  let queue = field(spec, "queue")
  assert at(queue, ["name"], decode.string) == ""
  assert at(queue, ["durable"], decode.bool) == False
  assert at(queue, ["exclusive"], decode.bool) == False
  assert at(queue, ["auto_delete"], decode.bool) == True
  assert at(queue, ["ttl"], decode.int) == 60_000
  assert at(queue, ["max_length"], decode.int) == 100

  let consume = field(spec, "consume")
  assert at(consume, ["manual_ack"], decode.bool) == False
  assert at(consume, ["exclusive"], decode.bool) == False
}

/// The queue work goes on: named, durable, and with the arguments turned off
/// so that the broker holds the messages rather than dropping them.
pub fn durable_queue_spec_test() {
  let spec =
    listener.new()
    |> listener.named(util.name("kazoo_gleam_test_listener"))
    |> listener.queue(
      name: "callcenter.member.acct",
      durable: True,
      exclusive: False,
      auto_delete: False,
      ttl: listener.Infinity,
      max_length: listener.Infinity,
    )
    |> listener.consume(manual_ack: True, exclusive: False)
    |> listener.prefetch(1)
    |> listener.to_spec

  let queue = field(spec, "queue")
  assert at(queue, ["name"], decode.string) == "callcenter.member.acct"
  assert at(queue, ["durable"], decode.bool) == True
  assert at(queue, ["auto_delete"], decode.bool) == False
  assert at(queue, ["ttl"], decode.string) == "infinity"
  assert at(queue, ["max_length"], decode.string) == "infinity"

  assert at(field(spec, "consume"), ["manual_ack"], decode.bool) == True
  assert decoded(field(spec, "prefetch"), decode.int) == 1

  // The name is the atom `gen_listener` registers under, so it arrives as
  // the atom itself and not as a string.
  assert field(spec, "name") == as_term(util.name("kazoo_gleam_test_listener"))
}

/// Bindings keep their order, and every property says what kind of term it
/// is, because a `kapi` module reads some of them as binaries and some as
/// atoms.
pub fn bindings_spec_test() {
  let spec =
    listener.new()
    |> listener.binding("callcenter", [
      listener.restrict_to(["member_call"]),
      listener.federate(),
    ])
    |> listener.binding("conference", [
      listener.prop("restrict_to", listener.Terms([listener.Atom("discovery")])),
      listener.prop("profile", listener.Text("default")),
      listener.prop("attempts", listener.Number(3)),
      listener.prop("pooled", listener.Flag(False)),
    ])
    |> listener.to_spec

  let bindings = decoded(field(spec, "bindings"), decode.list(decode.dynamic))
  let assert [callcenter, conference] = bindings

  assert at(callcenter, ["binding"], decode.string) == "callcenter"
  let assert [restrict_to, federate] =
    at(callcenter, ["props"], decode.list(decode.dynamic))
  assert at(restrict_to, ["key"], decode.string) == "restrict_to"
  assert at(restrict_to, ["value", "kind"], decode.string) == "list"
  let assert [member_call] =
    at(restrict_to, ["value", "value"], decode.list(decode.dynamic))
  assert at(member_call, ["kind"], decode.string) == "text"
  assert at(member_call, ["value"], decode.string) == "member_call"
  assert at(federate, ["key"], decode.string) == "federate"
  assert at(federate, ["value", "kind"], decode.string) == "bool"
  assert at(federate, ["value", "value"], decode.bool) == True

  assert at(conference, ["binding"], decode.string) == "conference"
  let assert [kinds, profile, attempts, pooled] =
    at(conference, ["props"], decode.list(decode.dynamic))
  let assert [discovery] =
    at(kinds, ["value", "value"], decode.list(decode.dynamic))
  assert at(discovery, ["kind"], decode.string) == "atom"
  assert at(discovery, ["value"], decode.string) == "discovery"
  assert at(profile, ["value", "kind"], decode.string) == "text"
  assert at(attempts, ["value", "value"], decode.int) == 3
  assert at(pooled, ["value", "value"], decode.bool) == False
}

/// The closures are in the spec once they are asked for, and the node
/// notifications are the names `kz_nodes` knows.
pub fn closures_spec_test() {
  let spec =
    listener.new()
    |> listener.on_event(fn(_event, _delivery) { Nil })
    |> listener.on_info(fn(_info) { Nil })
    |> listener.on_consuming(fn(_is_consuming) { Nil })
    |> listener.notify_nodes(of: [listener.NodeUp, listener.NodeGone])
    |> listener.to_spec

  assert dict.get(spec, "on_event") != Error(Nil)
  assert dict.get(spec, "on_info") != Error(Nil)
  assert dict.get(spec, "on_consuming") != Error(Nil)
  assert decoded(field(spec, "notify"), decode.list(decode.string))
    == ["new", "expire"]
}

/// The lifecycle casts, as the listener converts them.
pub fn decode_lifecycle_info_test() {
  assert listener.decode_info(
      map([
        #("kind", dynamic.string("consuming")),
        #("value", dynamic.bool(True)),
      ]),
    )
    == listener.Consuming(True)

  assert listener.decode_info(
      map([
        #("kind", dynamic.string("federators_consuming")),
        #("value", dynamic.bool(False)),
      ]),
    )
    == listener.FederatorsConsuming(False)

  assert listener.decode_info(
      map([
        #("kind", dynamic.string("queue_created")),
        #("queue", dynamic.string("callcenter.member.acct")),
      ]),
    )
    == listener.QueueCreated("callcenter.member.acct")
}

/// A `kz_nodes` notification, as `kz_node:to_json/1` describes the node.
pub fn decode_node_info_test() {
  let node =
    map([
      #("node", dynamic.string("kazoo_apps@one.example.test")),
      #("zone", dynamic.string("local")),
      #(
        "kapps",
        dynamic.list([dynamic.string("ecallmgr"), dynamic.string("callcenter")]),
      ),
      #("media_servers", dynamic.list([dynamic.string("freeswitch@one")])),
      #("version", dynamic.string("5.4.0")),
    ])
  let expected =
    nodes.Node(
      name: "kazoo_apps@one.example.test",
      zone: "local",
      kapps: ["ecallmgr", "callcenter"],
      media_servers: ["freeswitch@one"],
    )

  assert listener.decode_info(
      map([#("kind", dynamic.string("node_expire")), #("node", node)]),
    )
    == listener.NodeExpire(expected)
  assert listener.decode_info(
      map([#("kind", dynamic.string("node_new")), #("node", node)]),
    )
    == listener.NodeNew(expected)
  assert listener.decode_info(
      map([#("kind", dynamic.string("node_heartbeat")), #("node", node)]),
    )
    == listener.NodeHeartbeat(expected)
}

/// Anything else the process is sent arrives whole, rather than as a crash in
/// a listener that was only ever monitoring something.
pub fn decode_other_info_test() {
  let down = dynamic.string("DOWN")
  assert listener.decode_info(down) == listener.Other(down)

  let unknown = map([#("kind", dynamic.string("something_new"))])
  assert listener.decode_info(unknown) == listener.Other(unknown)
}

/// There is no `gen_listener` outside the release, and that is an error and
/// not a crash: it is how an application's tests get to run.
pub fn start_without_a_release_test() {
  assert listener.start(listener.new()) == Error("unavailable")
}

// --- The broker cancelling the consumer ------------------------------------

@external(erlang, "kazoo_gleam_listener", "init")
fn init(args: List(dict.Dict(String, Dynamic))) -> Result(Dynamic, Nil)

@external(erlang, "kazoo_gleam_listener", "handle_info")
fn handle_info(info: anything, state: Dynamic) -> #(Dynamic, Dynamic)

/// The broker cancels a consumer whose queue was deleted or lost, and says
/// so with a `basic.cancel` of its own. `gen_listener` has no clause for it
/// and hands it to the callback module, which is where this listener is:
/// both closures hear the consumer go, exactly as they hear a lost channel,
/// so a listener that ends on losing its consumer ends on this too. Before,
/// it reached `on_info` as an `Other` nobody read, and a shard went on
/// believing it held a queue that fed it nothing.
pub fn a_consumer_the_broker_cancelled_is_not_consuming_test() {
  let infos = process.new_subject()
  let consuming = process.new_subject()
  let spec =
    listener.new()
    |> listener.on_info(fn(info) { process.send(infos, info) })
    |> listener.on_consuming(fn(is) { process.send(consuming, is) })
    |> listener.to_spec
  let assert Ok(state) = init([spec])

  let cancel = #(atom.create("basic.cancel"), "amq.ctag-member-7", False)
  let #(reply, _state) = handle_info(cancel, state)
  assert reply == atom.to_dynamic(atom.create("noreply"))
  assert process.receive(infos, 100) == Ok(listener.Consuming(False))
  assert process.receive(consuming, 100) == Ok(False)
}

/// Anything else still reaches `on_info` whole.
pub fn other_info_still_reaches_on_info_test() {
  let infos = process.new_subject()
  let spec =
    listener.new()
    |> listener.on_info(fn(info) { process.send(infos, info) })
    |> listener.to_spec
  let assert Ok(state) = init([spec])
  let _ = handle_info("hello", state)
  assert process.receive(infos, 100)
    == Ok(listener.Other(dynamic.string("hello")))
}
