//// Which nodes take shards: the members.
////
//// A member is a node running the application that the broker can see. Each
//// node consumes a queue of its own, `callcenter.node.<node>`, for as long as
//// it is able to take shards -- its placement is running and its shard count
//// is the cluster's -- and any node can ask the broker whether that queue
//// has a consumer. That is the broker's own view, from the same connection
//// the node's member queue consumers are on: a node the broker has dropped
//// has lost its shards and its membership in the same instant, whether it
//// died, froze or was cut off, and every other node sees both at once.
////
//// `kz_nodes` only says which names to ask about, with the members at the
//// last look. It hears of a node dying 12 to 45 seconds late and of a node
//// starting 15 to 40 seconds late, which is too slow to decide anything
//// with: a count of nodes read from it is what used to leave a node that
//// had just died with a share of the shards nobody took, and a node that
//// had just come back with none.
////
//// The same queue is the node's inbox. A node that is assigned a shard
//// somebody else is consuming asks every other member for it (`want`), and
//// whichever holds it hears it here.

import callcenter/shards
import gleam/list
import gleam/result
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/listener.{type Listener, Limited}
import kazoo/nodes

/// The queue a node consumes while it is a member.
pub fn queue(node: String) -> String {
  "callcenter.node." <> node
}

/// How a node's queue is declared, by its listener and by whoever asks after
/// it: two declarations that differ are refused by the broker.
///
/// Not durable and deleted with its last consumer, so that a node that has
/// gone leaves nothing behind but, at most, the empty queue a peer's question
/// made, which the next broker restart takes away. A want is only worth
/// anything while its sender is waiting for an answer, so they expire and
/// never pile up.
pub fn declared(listener: Listener, queue: String) -> Listener {
  listener.queue(
    listener,
    name: queue,
    durable: False,
    exclusive: False,
    auto_delete: True,
    ttl: Limited(want_ttl_ms),
    max_length: Limited(wants_kept),
  )
}

/// A want asks for a shard at the time it is sent: older than this, it is
/// dropped, and its sender will have sent another.
const want_ttl_ms = 15_000

/// Each member sends each other one want a tick at most.
const wants_kept = 64

/// This node's listener: consuming its queue is being a member, and what
/// arrives on it is other members asking for shards, handed to `wanted` as
/// the asker and the shards it asked for.
pub fn listener(
  node: String,
  wanted: fn(String, List(Int)) -> Nil,
) -> Listener {
  listener.new()
  |> declared(queue(node))
  |> listener.consume(manual_ack: False, exclusive: False)
  |> listener.on_event(fn(value, _delivery) {
    case decode_want(value) {
      Ok(#(from, asked)) -> wanted(from, asked)
      Error(Nil) -> Nil
    }
  })
}

/// Ask a member for shards this node is assigned and somebody else is
/// consuming. Whoever holds one gives it up if it agrees the shard is this
/// node's (`callcenter/placement`).
pub fn want(
  to node: String,
  from self: String,
  shards asked: List(Int),
) -> Nil {
  let _ = amqp.publish_to_queue(queue(node), want_message(self, asked))
  Nil
}

/// A want as it is published.
pub fn want_message(from: String, asked: List(Int)) -> Value {
  doc.merge(
    amqp.default_headers(
      app: "callcenter",
      category: "callcenter",
      name: "shard_want",
    ),
    doc.object([
      #("Node", doc.String(from)),
      #("Shards", doc.List(list.map(asked, doc.Int))),
    ]),
  )
}

/// A want as it arrives: who asked, and for which shards. `Error` for
/// anything else.
pub fn decode_want(value: Value) -> Result(#(String, List(Int)), Nil) {
  use from <- result.try(doc.get_string(value, ["Node"]))
  use asked <- result.try(doc.get_list(value, ["Shards"]))
  let asked =
    list.filter_map(asked, fn(shard) {
      case shard {
        doc.Int(shard) -> Ok(shard)
        _other -> Error(Nil)
      }
    })
  case from {
    "" -> Error(Nil)
    _ -> Ok(#(from, asked))
  }
}

/// The nodes `kz_nodes` names: every node in this zone that it has heard
/// running the application, and this one, which `kz_nodes` only lists
/// fifteen seconds after it starts.
pub fn candidates(self: String) -> List(String) {
  let zone = nodes.local_zone()
  nodes.nodes()
  |> list.filter(fn(node) {
    list.contains(node.kapps, "callcenter")
    && { zone == "" || node.zone == zone }
  })
  |> list.map(fn(node) { node.name })
  |> list.prepend(self)
  |> list.unique
}

/// Those of `names` whose queue has a consumer, asked of the broker one by
/// one. `Error` when the broker could not be asked: nobody can be said to be
/// a member, or not, then.
pub fn present(names: List(String)) -> Result(List(String), String) {
  list.try_fold(names, [], fn(present, name) {
    case shards.declare_described(declared(listener.new(), queue(name))) {
      Ok(#(_waiting, consumers)) if consumers > 0 -> Ok([name, ..present])
      Ok(_nobody) -> Ok(present)
      Error(reason) ->
        Error("could not ask after " <> queue(name) <> ": " <> reason)
    }
  })
  |> result.map(list.reverse)
}

/// The names worth asking the broker about: those `kz_nodes` names, and
/// every member at the last look (`known`).
///
/// The members are kept on because `kz_nodes` can forget a node that is
/// there. A node that restarts is one name with two lives. `kz_nodes`
/// drops the name when the first life's heartbeats run out, 12 to 45 s
/// after it stopped, and takes it back when it hears the second, 15 to 40 s
/// after it started. When the second life's queue is consumed before the
/// first's entry runs out, the name drops out of the ones asked about in
/// between, and every other node sees a member leave and come back. In the
/// lab of 2026-09-28 (e2e-260927-cca6), a returned node was out for 6 and
/// 11 seconds, and its shards went back to the node that had given them up
/// before they came to it. A name the broker says is a member stays worth
/// asking about until the broker says its queue has no consumer.
pub fn worth_asking(
  candidates: List(String),
  known: List(String),
) -> List(String) {
  list.unique(list.append(candidates, known))
}

/// The members right now, `known` being the members at the last look.
pub fn now(self: String, known: List(String)) -> Result(List(String), String) {
  present(worth_asking(candidates(self), known))
}
