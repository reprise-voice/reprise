//// A supervisor's pickup, on the bus: Crossbar's question and the answer of
//// the node dispatching the account.
////
//// The caller being picked up is held by one dispatcher, on whichever node
//// holds the account's shard, and only that dispatcher can ring anybody for
//// them without an agent's ring racing it. So Crossbar asks, as it asks for
//// the live status: a `pickup_req` on `callcenter.pickup.<account>`, which
//// every node running the application binds and only the holder answers,
//// with a `pickup_resp` to the requester's own queue. The rest say nothing.
//// What the dispatcher does with it is `callcenter/dispatcher/pickup`.
////
//// The key is not the status key, although the same node answers both: a
//// node of the release before this one would take a pickup on the status
//// key for a status request, answer it as one, and the requester would read
//// that as the answer to its pickup.
////
//// Crossbar answers the supervisor only once this answer is in, so a `202`
//// means the phones are ringing. A holder whose dispatcher does not answer
//// in time answers `too_late`, and the dispatcher, told how long it was
//// given, starts nothing once that time has passed: a phone never rings
//// that the supervisor was told did not.
////
//// **The requester's deadline travels with the request.** A request can sit
//// in the holder's queue -- a holder busy, a broker slow to deliver -- and
//// the holder's own clock starts only when it reads it. So the request
//// carries `Deadline-Ms`, the system time in Unix milliseconds at which
//// Crossbar stops waiting, and the holder gives its dispatcher no more than
//// what is left of that, less the time its answer needs to get back; with
//// nothing left it asks nothing and answers `too_late`. The queue's message
//// TTL is the requester's whole wait, so the broker drops a request nobody
//// is waiting for before any holder sees it. A request from a node that
//// sends no deadline is given the holder's own wait, as before. The clocks
//// of two nodes are compared here, so a skew between them moves the cut-off
//// by that much: NTP keeps it to milliseconds against a budget of seconds.

import callcenter/ask
import callcenter/dispatcher
import callcenter/dispatcher/pickup.{
  type Answer, type Request, BeingOffered, NotStarted, NotWaiting, Request,
  Ringing, SupervisorBusy, TooLate,
}
import callcenter/fields
import callcenter/shard
import callcenter/shards
import callcenter/system
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/result
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/listener.{Limited}

/// How long Crossbar waits for the holder's answer.
pub const timeout_ms = 3000

/// How long the holder waits for its dispatcher: well inside the
/// requester's wait, so that a busy dispatcher is answered for rather than
/// left to the requester's timeout.
pub const holder_timeout_ms = 2000

/// How much of the holder's wait the dispatcher is not given, so that an
/// answer it sends at the last moment still reaches a holder that is
/// listening.
const reply_margin_ms = 250

// --- Crossbar's side ---------------------------------------------------------

/// Ask the node dispatching the account to ring the supervisor for the
/// caller. `NoAnswer` is nobody answering within `timeout_ms`: a holder too
/// slow, or no node holding the account's shard. Neither says the caller is
/// not waiting, and neither leaves a phone ringing -- the deadline the
/// request carries is past by then.
pub fn ask_holder(
  account_id: String,
  request: Request,
) -> Result(Answer, amqp.Error) {
  amqp.call(
    module: "callcenter",
    function: "pickup_req",
    payload: request_to_value(account_id, request)
      |> with_deadline(system_ms() + timeout_ms),
    timeout: timeout_ms,
  )
  |> result.try(fn(answer) {
    answer_of(answer)
    |> result.replace_error(amqp.Failed("unreadable pickup_resp"))
  })
}

/// The request, as `kapi.callcenter.pickup_req` validates it.
pub fn request_to_value(account_id: String, request: Request) -> Value {
  doc.merge(
    amqp.default_headers("callcenter", "callcenter", "pickup_req"),
    doc.object([
      #("Account-ID", doc.String(account_id)),
      #("Queue-ID", doc.String(request.queue_id)),
      #("Call-ID", doc.String(request.call_id)),
      #("Supervisor-ID", doc.String(request.supervisor_id)),
      #("Target-Type", doc.String(request.target_type)),
      #("Target-ID", doc.String(request.target_id)),
      #("Device-IDs", doc.List(list.map(request.device_ids, doc.String))),
    ]),
  )
}

/// The request with the moment its requester stops waiting: system time,
/// Unix milliseconds.
pub fn with_deadline(request: Value, deadline_ms: Int) -> Value {
  doc.set(request, ["Deadline-Ms"], doc.Int(deadline_ms))
}

/// The requester's deadline, when the request carries one.
pub fn deadline_of(request: Value) -> Option(Int) {
  doc.get_int(request, ["Deadline-Ms"]) |> option.from_result
}

/// How long the holder gives its dispatcher, at system time `now_ms`: its
/// own wait, cut to what is left before the requester's deadline less the
/// time the answer needs to get back.
pub fn budget_ms(deadline: Option(Int), now_ms: Int) -> Int {
  case deadline {
    None -> holder_timeout_ms
    Some(deadline) ->
      int.min(holder_timeout_ms, deadline - now_ms - reply_margin_ms)
  }
}

/// The request back out of a `pickup_req`.
pub fn request_of(value: Value) -> Result(Request, Nil) {
  use queue_id <- result.try(non_empty(value, "Queue-ID"))
  use call_id <- result.try(non_empty(value, "Call-ID"))
  use supervisor_id <- result.try(non_empty(value, "Supervisor-ID"))
  use target_type <- result.try(non_empty(value, "Target-Type"))
  use target_id <- result.try(non_empty(value, "Target-ID"))
  Ok(Request(
    queue_id: queue_id,
    call_id: call_id,
    supervisor_id: supervisor_id,
    target_type: target_type,
    target_id: target_id,
    device_ids: doc.strings(value, ["Device-IDs"]),
  ))
}

fn non_empty(value: Value, key: String) -> Result(String, Nil) {
  case doc.get_string(value, [key]) {
    Ok("") | Error(Nil) -> Error(Nil)
    Ok(found) -> Ok(found)
  }
}

/// The answer as the wire spells it.
pub fn answer_to_value(answer: Answer) -> List(#(String, Value)) {
  [
    #("Result", doc.String(result_name(answer))),
    ..case answer {
      Ringing(ring_timeout_s) -> [#("Offer-Timeout", doc.Int(ring_timeout_s))]
      NotStarted(reason) -> [#("Reason", doc.String(reason))]
      NotWaiting | BeingOffered | SupervisorBusy | TooLate -> []
    }
  ]
}

/// The `Result` an answer is on the wire.
pub fn result_name(answer: Answer) -> String {
  case answer {
    Ringing(_) -> "ringing"
    NotWaiting -> "not_waiting"
    BeingOffered -> "being_offered"
    SupervisorBusy -> "supervisor_busy"
    NotStarted(_) -> "not_started"
    TooLate -> "too_late"
  }
}

/// The answer back out of a `pickup_resp`.
pub fn answer_of(value: Value) -> Result(Answer, Nil) {
  case doc.get_string(value, ["Result"]) {
    Ok("ringing") ->
      Ok(
        Ringing(fields.int_at(value, ["Offer-Timeout"], pickup.ring_timeout_s)),
      )
    Ok("not_waiting") -> Ok(NotWaiting)
    Ok("being_offered") -> Ok(BeingOffered)
    Ok("supervisor_busy") -> Ok(SupervisorBusy)
    Ok("not_started") ->
      Ok(NotStarted(fields.string_at(value, ["Reason"], "unknown")))
    Ok("too_late") -> Ok(TooLate)
    _unknown -> Error(Nil)
  }
}

// --- The holder's side -------------------------------------------------------

/// The listener as a supervised child.
pub fn supervised(count: Int) -> supervision.ChildSpecification(Nil) {
  responder(count)
  |> listener.supervised
  |> supervision.map_data(fn(_server) { Nil })
}

/// The listener itself, described and not started: a transient queue named
/// by the broker, as the status responder's is. A pickup asked for while
/// this node was down has nobody waiting for its answer, and one that has
/// waited in the queue for as long as its requester waits for an answer is
/// dropped by the broker.
pub fn responder(count: Int) -> listener.Listener {
  listener.new()
  |> listener.binding("callcenter", [listener.restrict_to(["pickup"])])
  |> listener.queue(
    name: "",
    durable: False,
    exclusive: False,
    auto_delete: True,
    ttl: Limited(timeout_ms),
    max_length: Limited(1000),
  )
  |> listener.on_event(fn(request, _delivery) { asked(request, count) })
}

/// A request arrived. Answered from a process of its own, because it waits
/// on the shard and a dispatcher and the listener must not.
pub fn asked(request: Value, count: Int) -> Nil {
  case
    doc.get_string(request, ["Event-Name"]),
    fields.some_string(request, ["Account-ID"]),
    fields.some_string(request, ["Server-ID"])
  {
    Ok("pickup_req"), Some(account_id), Some(server_id) -> {
      let _ =
        process.spawn_unlinked(fn() {
          answer(request, account_id, server_id, count)
        })
      Nil
    }
    _other, _, _ -> Nil
  }
}

fn answer(
  value: Value,
  account_id: String,
  server_id: String,
  count: Int,
) -> Nil {
  let shard_id = shards.of_account(account_id, count)
  case request_of(value) {
    Error(Nil) ->
      system.log_error(
        "a pickup_req for account " <> account_id <> " named nobody to ring",
      )
    Ok(request) ->
      case
        decide(
          shard_id,
          account_id,
          request,
          budget_ms(deadline_of(value), system_ms()),
        )
      {
        None -> Nil
        Some(answer) -> {
          system.log(
            "pickup_req for call "
            <> request.call_id
            <> " of account "
            <> account_id
            <> ": "
            <> result_name(answer),
          )
          let _ =
            amqp.publish_to(
              target: server_id,
              module: "callcenter",
              function: "pickup_resp",
              payload: doc.merge(
                amqp.default_headers(
                  system.category,
                  "callcenter",
                  "pickup_resp",
                ),
                doc.object_some([
                  #("Account-ID", Some(doc.String(account_id))),
                  #("Call-ID", Some(doc.String(request.call_id))),
                  #("Node", Some(doc.String(system.node_name()))),
                  // The request's own identifier, which is how
                  // `kz_amqp_worker` knows this answer is the one it waits
                  // for: see `status`.
                  #(
                    "Msg-ID",
                    option.map(
                      fields.some_string(value, ["Msg-ID"]),
                      doc.String,
                    ),
                  ),
                  ..list.map(answer_to_value(answer), fn(field) {
                    #(field.0, Some(field.1))
                  })
                ]),
              ),
            )
          Nil
        }
      }
  }
}

/// What this node says: the dispatcher's answer when it holds the shard and
/// has a dispatcher for the account, `not_waiting` when it holds the shard
/// and has none -- a dispatcher exists while somebody is waiting -- and
/// nothing at all when another node holds the shard.
fn decide(
  shard_id: Int,
  account_id: String,
  request: Request,
  budget_ms: Int,
) -> Option(Answer) {
  case shard.dispatcher(shard_id, account_id) {
    Ok(to) -> Some(ask_dispatcher(to, request, budget_ms))
    Error(Nil) ->
      case shard.held(shard_id) {
        Some(_held) -> Some(NotWaiting)
        None -> None
      }
  }
}

/// The dispatcher's answer, within `budget_ms`. One that ended before it
/// answered, or did not answer in time, started nothing -- it is told the
/// moment past which it must not -- and the supervisor may ask again. A
/// budget that leaves the dispatcher no time at all is not asked: the
/// requester has stopped waiting, or will have before an answer is back.
pub fn ask_dispatcher(
  to: Subject(dispatcher.Message),
  request: Request,
  budget_ms: Int,
) -> Answer {
  case budget_ms > reply_margin_ms {
    False -> {
      system.log_error(
        "a pickup_req for call "
        <> request.call_id
        <> " arrived after its requester stopped waiting: nothing rung",
      )
      TooLate
    }
    True -> {
      let deadline = monotonic_ms() + budget_ms - reply_margin_ms
      case ask.call(to, budget_ms, dispatcher.PickUp(request, deadline, _)) {
        Ok(answer) -> answer
        Error(failure) -> {
          system.log_error(
            "the dispatcher did not answer a pickup_req for call "
            <> request.call_id
            <> ": "
            <> ask.describe(failure),
          )
          TooLate
        }
      }
    }
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// The system clock in Unix milliseconds: the one clock two nodes share.
fn system_ms() -> Int {
  system_time(atom.create("millisecond"))
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: atom.Atom) -> Int
