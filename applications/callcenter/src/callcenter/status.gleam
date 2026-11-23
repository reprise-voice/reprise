//// Answering "what is happening in this account right now".
////
//// A `status_req` goes out on `callcenter.status.<account>`, so every node
//// running the application sees it. Exactly one of them holds the account's
//// shard, and that one answers; the rest say nothing at all. The requester
//// collects with `call_collect` and a count of one, so it gets the one real
//// answer and stops (14.6).
////
//// Holding the shard is the test, and not running a dispatcher for the
//// account. A dispatcher exists only once somebody has waited, so the node
//// that answers is often a node with nothing to report -- and an empty
//// answer given at once is the whole point: it is what keeps the first
//// caller of the day, and every live view on a quiet account, from waiting
//// out the collection's timeout for an answer nobody was going to send.
////
//// The answer goes back to the requester's own queue rather than on the
//// account's status key, because it is an answer to one question and not an
//// event: broadcasting it would hand every other subscriber a reply to
//// something they did not ask.
////
//// The work is done in a process of its own. The rule for a listener closure
//// is that it is quick, and this one would otherwise wait on a shard actor,
//// a dispatcher and a datastore read per agent while the node's whole status
//// feed stopped behind it.
////
//// The holder gives its dispatcher `holder_timeout_ms` and no more, which is
//// well under the requester's `status_query.timeout_ms`. A dispatcher busy
//// past that is answered for with what the holder knows -- the account is
//// here, and nothing about its queues -- rather than with silence, which cost
//// every caller entering the queue the requester's whole timeout for
//// nothing. An answer naming no queue is "not said" on the call path, never
//// zero (`cf_callcenter.status_of`), so a caller is never turned away by it.

import callcenter/ask
import callcenter/dispatcher
import callcenter/fields
import callcenter/shard
import callcenter/shards
import callcenter/status_query
import callcenter/system
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/result
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/listener.{Limited}

/// How long the node holding the shard waits for its dispatcher, for both
/// of its questions together. A third of the requester's timeout, so that
/// the answer, busy or not, is there before the requester gives up.
pub const holder_timeout_ms = 1000

/// The listener as a supervised child.
pub fn supervised(count: Int) -> supervision.ChildSpecification(Nil) {
  responder(count)
  |> listener.supervised
  |> supervision.map_data(fn(_server) { Nil })
}

/// The listener itself, described and not started.
///
/// A transient queue named by the broker: a status question that arrived
/// while this node was down has no answer worth giving late.
pub fn responder(count: Int) -> listener.Listener {
  listener.new()
  |> listener.binding("callcenter", [
    listener.restrict_to(["status"]),
  ])
  |> listener.queue(
    name: "",
    durable: False,
    exclusive: False,
    auto_delete: True,
    ttl: Limited(60_000),
    max_length: Limited(1000),
  )
  |> listener.on_event(fn(request, _delivery) { asked(request, count) })
}

/// A question arrived. Answer it if this node is the one dispatching for the
/// account, and say nothing if it is not.
pub fn asked(request: Value, count: Int) -> Nil {
  case account_of(request), reply_to(request) {
    Some(account_id), Some(server_id) -> {
      system.log(
        "status_req for account " <> account_id <> " from " <> server_id,
      )
      let _ =
        process.spawn_unlinked(fn() {
          answer(request, account_id, server_id, count)
        })
      Nil
    }
    _incomplete, _ -> Nil
  }
}

/// What this node has to say about an account, or nothing when it is not the
/// node that would know.
///
/// Holding the shard is what makes a node the one that knows, and that is
/// not the same as running a dispatcher: a dispatcher starts on an account's
/// first waiting caller since the shard was taken, so an account nobody has
/// called yet has none. Answering only when there is one
/// leaves every first caller and every live view on a quiet account waiting
/// out the collection's whole timeout for an answer that was never coming --
/// three seconds on the way into a queue that was ready for them.
///
/// So a shard holder with no dispatcher answers as well, with the empty list
/// that says exactly what it knows: nobody is waiting here.
pub type View {
  /// This node holds the shard; here is what is happening in it, and who is
  /// on a queue call, which is what a login lamp probe answered elsewhere
  /// asks for.
  Dispatching(queues: List(Value), on_queue_call: List(String))
  /// This node holds the shard and nobody is waiting in the account at all.
  Quiet
  /// This node holds the shard, and its dispatcher did not answer within
  /// `holder_timeout_ms`. What is waiting is not known, and the answer says
  /// nothing about any queue: not said, which is not zero.
  Busy
  /// Some other node holds the shard. Nothing to say.
  Elsewhere
}

/// The `Queues` an answer carries, or nothing when there is no answer to
/// give.
pub fn queues_of(view: View) -> Option(List(Value)) {
  case view {
    Dispatching(queues, _) -> Some(queues)
    Quiet | Busy -> Some([])
    Elsewhere -> None
  }
}

/// The `On-Queue-Call` an answer carries: nobody, unless a dispatcher here
/// has somebody on a call.
pub fn on_queue_call_of(view: View) -> List(String) {
  case view {
    Dispatching(_, on_queue_call) -> on_queue_call
    Quiet | Busy | Elsewhere -> []
  }
}

fn view(request: Value, account_id: String, shard_id: Int) -> View {
  case shard.dispatcher(shard_id, account_id) {
    Ok(to) -> ask_dispatcher(to, queue_of(request), holder_timeout_ms)
    Error(Nil) ->
      case shard.held(shard_id) {
        Some(_held) -> Quiet
        None -> Elsewhere
      }
  }
}

/// What a dispatcher of this node's says, within `budget_ms` for both
/// questions. One that ended between being found and being asked has
/// nobody waiting, which is an answer; one that is still there and did not
/// answer in time is `Busy`. Who is on a queue call is asked with what is
/// left of the budget, and nobody when nothing is.
pub fn ask_dispatcher(
  to: Subject(dispatcher.Message),
  queue_id: Option(String),
  budget_ms: Int,
) -> View {
  let started = monotonic_ms()
  case ask.call(to, budget_ms, dispatcher.Status(queue_id, _)) {
    Ok(queues) -> {
      let left = budget_ms - { monotonic_ms() - started }
      Dispatching(queues, case left > 0 {
        True -> ask.call(to, left, dispatcher.OnQueueCall) |> result.unwrap([])
        False -> []
      })
    }
    Error(ask.Exited(_)) -> Quiet
    Error(ask.NoReply) -> {
      system.log_error(
        "the dispatcher did not answer a status_req within "
        <> int.to_string(budget_ms)
        <> " ms: answering that nothing is known",
      )
      Busy
    }
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

fn answer(
  request: Value,
  account_id: String,
  server_id: String,
  count: Int,
) -> Nil {
  let shard_id = shards.of_account(account_id, count)
  let view = view(request, account_id, shard_id)
  case response(request, account_id, shard_id, view) {
    None -> Nil
    Some(payload) -> {
      let _ =
        amqp.publish_to(
          target: server_id,
          module: "callcenter",
          function: "status_resp",
          payload: payload,
        )
      Nil
    }
  }
}

/// The answer a view is, or nothing when there is no answer to give.
pub fn response(
  request: Value,
  account_id: String,
  shard_id: Int,
  view: View,
) -> Option(Value) {
  use queues <- option.map(queues_of(view))
  doc.merge(
    amqp.default_headers(system.category, "callcenter", "status_resp"),
    doc.object_some([
      #("Account-ID", Some(doc.String(account_id))),
      #("Node", Some(doc.String(system.node_name()))),
      #("Shard", Some(doc.Int(shard_id))),
      #("Queues", Some(doc.List(queues))),
      #(
        "On-Queue-Call",
        Some(doc.List(list.map(on_queue_call_of(view), doc.String))),
      ),
      // This node's dispatchers send a waiting caller's messages to the
      // caller's controller queue. An action reading an answer without it
      // -- from a node of the release before, whose dispatcher publishes
      // only on the exchange -- listens on the exchange as it used to
      // (`cf_callcenter.Delivery`). Every answer says it, the empty ones
      // too: a dispatcher starts on the account's first caller.
      #("Caller-Delivery", Some(doc.String(caller_delivery))),
      // The request's own identifier, echoed. `kz_amqp_worker`
      // collects only the answers whose `Msg-ID` is the one it asked
      // with; without this the answer arrives on the requester's
      // queue and is dropped, and every live view times out empty.
      #("Msg-ID", option.map(msg_id(request), doc.String)),
    ]),
  )
}

/// How this release's dispatchers deliver to a waiting caller:
/// `cf_callcenter.controller_delivery`, which reads it.
pub const caller_delivery = "controller"

fn msg_id(request: Value) -> Option(String) {
  fields.some_string(request, ["Msg-ID"])
}

fn account_of(request: Value) -> Option(String) {
  fields.some_string(request, ["Account-ID"])
}

fn queue_of(request: Value) -> Option(String) {
  fields.some_string(request, ["Queue-ID"])
}

fn reply_to(request: Value) -> Option(String) {
  fields.some_string(request, ["Server-ID"])
}

/// Ask the cluster about an account, for `sup` and for anything that is not
/// Crossbar.
///
/// One answer is expected, because one node is dispatching. A cluster where
/// nobody holds the account's shard answers nothing, which the timeout turns
/// into an empty list rather than an error.
pub fn ask(account_id: String, queue_id: Option(String)) -> List(Value) {
  status_query.ask(account_id, queue_id)
  |> result.unwrap([])
  |> status_query.queues
}
