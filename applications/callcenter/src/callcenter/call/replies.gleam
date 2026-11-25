//// Where the answers to a call actor come back: one listener per node.
////
//// A call actor asks two things that are answered to an address rather
//// than published: `ecallmgr` answers an `originate_req` at its
//// `Server-ID`, and the callflow action answers a `member_continue` at its
//// `Reply-To`. Neither is worth a queue of its own per call. So every
//// node runs one listener whose queue is bound to the `targeted` exchange
//// under its own name (`kapi_self`), and a call actor's address is
//// `pid://<actor>/<that queue>` (`callcenter_ffi:reply_address/0`). A
//// message published there carries a `Deliver-To-PID` header, and
//// `gen_listener` hands it straight to that pid as `{kapi, Msg}` before any
//// callback of this listener sees it: the actor reads it from its own
//// mailbox beside the call's events, which arrive in the same shape.
////
//// The queue is the broker's own -- named by it, deleted with the
//// connection -- because an answer is only any use to the actor that asked,
//// and that actor is on this node. A listener that loses its channel comes
//// back with a new queue and says so (`QueueCreated`); an actor that asked
//// before then hears nothing back and goes by its own deadlines, which is
//// what every ask it makes is bounded by anyway.

import callcenter/system
import kazoo/doc
import kazoo/listener

/// The node term the queue's name is kept under, which
/// `callcenter_ffi:reply_address/0` reads.
pub const queue_term = "call_replies_queue"

/// The listener, described and not started, because the description is the
/// contract with the broker and is worth asserting on without one.
pub fn listener() -> listener.Listener {
  listener.new()
  |> listener.binding("self", [])
  // Answers are handed on the moment they arrive, so the queue never holds
  // more than a burst; a limit on it would only ever drop an answer.
  |> listener.queue(
    name: "",
    durable: False,
    exclusive: True,
    auto_delete: True,
    ttl: listener.Limited(60_000),
    max_length: listener.Infinity,
  )
  // Nothing addressed to an actor reaches this: `gen_listener` hands it to
  // the actor first. What does is a message somebody sent to the queue
  // without an actor's address on it, which nobody is waiting for.
  |> listener.on_event(fn(event, _delivery) {
    system.log_debug(
      "a message reached the call reply queue with no actor to hand it to: "
      <> doc.to_string(event),
    )
  })
  |> listener.on_info(fn(info) {
    case info {
      listener.QueueCreated(queue) -> {
        put_node_term(queue_term, queue)
        system.log("call replies come back on " <> queue)
      }
      _other -> Nil
    }
  })
}

@external(erlang, "callcenter_ffi", "put_node_term")
fn put_node_term(name: String, value: String) -> Nil
