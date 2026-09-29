//// What is on the member queue.
////
//// Two messages. `member_call` is a caller who has entered a queue: the
//// account, the queue, the call, when the caller arrived and which node ran
//// the callflow that put them there. `member_cancel` is that caller taken
//// out again from outside their actor -- an operator settling them by hand
//// through `sup`, or the callflow action of an older release, which said
//// an abandon, a timeout or an exit key this way -- and it settles the
//// `member_call` the shard is holding unacked. A caller's actor says their
//// leaving to the shard directly (`CallerLeft`).
////
//// The decoder is total and takes what it recognises. A message this
//// release does not understand is not a crash in a listener: it is a member
//// with empty fields, which the shard settles and logs rather than holds,
//// because nothing will ever dispatch it or name it in a cancel. The
//// field names are the ones `kapi_callcenter` validates; nothing here
//// validates anything, because the contract is that module's and not this
//// one's.

import callcenter/fields
import callcenter/types
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/doc.{type Value}
import kazoo/listener.{type Delivery}

/// Which of the two messages this is.
pub type Kind {
  Call
  Cancel
  Unknown(String)
}

pub fn kind_to_string(kind: Kind) -> String {
  case kind {
    Call -> "member_call"
    Cancel -> "member_cancel"
    Unknown(name) -> name
  }
}

pub fn kind_from_string(name: String) -> Kind {
  case name {
    "member_call" -> Call
    "member_cancel" -> Cancel
    other -> Unknown(other)
  }
}

/// One message on a member queue, as much of it as the dispatcher needs to
/// know before it does anything with the caller.
pub type Member {
  Member(
    kind: Kind,
    account_id: String,
    queue_id: String,
    call_id: String,
    /// The kazoo node that ran the caller's callflow, so that a dispatcher
    /// can tell that the caller's continuation is gone. Empty when the
    /// message did not say.
    node: Option(String),
    /// Gregorian seconds the caller entered the queue, which is the order
    /// the waiting list is rebuilt in after a failover.
    joined_at: Int,
    /// A cancel's Gregorian second the caller left the queue. `None` from a
    /// node of a release that did not send one, and on a `member_call`.
    cancelled_at: Option(Int),
    priority: Int,
    /// The caller's own `kapps_call`, which is what a node that never saw
    /// the call bridges an agent to.
    call: Value,
    caller_id_name: Option(String),
    caller_id_number: Option(String),
    /// The passage's own id (`Handoff-ID`), empty when the message did not
    /// say.
    handoff_id: String,
    /// The flows the callflow goes on into when the caller leaves
    /// (`Branches`), an empty object when the message did not say.
    branches: Value,
  )
}

/// The message as a `Member`. Total: what is missing is empty.
pub fn decode(value: Value) -> Member {
  Member(
    kind: kind_from_string(fields.string_at(value, ["Event-Name"], "")),
    account_id: fields.string_at(value, ["Account-ID"], ""),
    queue_id: fields.string_at(value, ["Queue-ID"], ""),
    call_id: fields.string_at(value, ["Call-ID"], ""),
    node: fields.some_string(value, ["Callflow-Node"]),
    joined_at: fields.int_at(value, ["Joined-Timestamp"], 0),
    cancelled_at: fields.some_int(value, ["Cancelled-Timestamp"]),
    priority: fields.int_at(value, ["Priority"], 0),
    call: doc.get(value, ["Call"]) |> result.unwrap(doc.object([])),
    caller_id_name: fields.some_string(value, ["Caller-ID-Name"]),
    caller_id_number: fields.some_string(value, ["Caller-ID-Number"]),
    handoff_id: fields.string_at(value, ["Handoff-ID"], ""),
    branches: doc.get(value, ["Branches"]) |> result.unwrap(doc.object([])),
  )
}

/// A `member_call` as the dispatcher's `types.Member`, with the delivery it
/// arrived on.
///
/// The delivery goes no further than the dispatcher: it is the only thing
/// that acks it, and only when the caller has been connected or has left.
/// Anything that is not a `member_call`, or that names no call, is not a
/// caller and answers `None`.
pub fn arrival(value: Value, delivery: Delivery) -> Option(types.Member) {
  let arrival = decode(value)
  case arrival.kind, arrival.call_id, arrival.account_id {
    Call, "", _ -> None
    Call, _, "" -> None
    Call, _, _ ->
      Some(types.Member(
        account_id: arrival.account_id,
        queue_id: arrival.queue_id,
        call_id: arrival.call_id,
        call: arrival.call,
        priority: arrival.priority,
        joined: arrival.joined_at,
        callflow_node: option.unwrap(arrival.node, ""),
        caller_id_name: arrival.caller_id_name,
        caller_id_number: arrival.caller_id_number,
        handoff_id: case arrival.handoff_id {
          "" -> handoff_of(arrival.call_id, arrival.joined_at)
          id -> id
        },
        branches: arrival.branches,
        delivery: delivery,
      ))
    _not_a_caller, _, _ -> None
  }
}

/// The passage id of a member whose sender gave none: the call and the
/// second it joined, which is what tells one passage from another anywhere
/// else in the application.
pub fn handoff_of(call_id: String, joined: Int) -> String {
  call_id <> "-" <> int.to_string(joined)
}

// --- When the caller entered the system ------------------------------------

/// The channel variable the callflow action stamps a caller with the first
/// time they enter a queue, in Gregorian seconds, and never again.
///
/// It is what `time_base_score: system` counts from. Nothing the platform
/// already sends says when a channel was created -- the `kapps_call` a
/// member carries has no time in it, and the channel's creation time is a
/// header on call events the action is not asked for -- so the action sets
/// its own. A custom channel variable lives on the channel, so it is still
/// there when the same channel enters another queue: an overflow branch, a
/// transfer, or the callflow run again after the node running it died.
pub const system_joined_var = "Queue-System-Joined"

/// When the caller entered the system, off the `kapps_call` a member
/// carries: the `Queue-System-Joined` channel variable, which is a number
/// when the action that set it passes the call on and the text of one when
/// the switch hands it back on a new route request. Nothing, when the
/// channel was never stamped.
pub fn system_joined(call: Value) -> Option(Int) {
  doc.get(call, ["Custom-Channel-Vars", system_joined_var])
  |> option.from_result
  |> option.then(system_joined_value)
}

/// The variable's own value as a time, whichever way it was spelled.
pub fn system_joined_value(value: Value) -> Option(Int) {
  case value {
    doc.Int(at) if at > 0 -> Some(at)
    doc.String(text) ->
      case int.parse(text) {
        Ok(at) if at > 0 -> Some(at)
        _not_a_time -> None
      }
    _other -> None
  }
}

/// A delivery that settles nothing.
///
/// What a caller rebuilt from their own `queue_call` document carries
/// (`reconcile.rebuilt`). Settling it is a no-op rather than an error: the
/// member it stands for is gone -- settled by an earlier release as the
/// call was answered, or lost -- or still on its way to the shard, and
/// takes the adopted call's place as it arrives.
@external(erlang, "callcenter_ffi", "unsettled_delivery")
pub fn no_delivery() -> Delivery

/// A `member_call` for a shard to dispatch.
///
/// `Call` is the caller's `kapps_call` as JSON, with its control queue: it is
/// what lets a node that never saw the call bridge an agent to it. A stub
/// dispatcher does not read it and `callcenter_maintenance:publish_member/3`
/// sends the minimum that is still a call.
pub fn call_message(
  account_id account_id: String,
  queue_id queue_id: String,
  call_id call_id: String,
  node node: String,
  joined_at joined_at: Int,
  priority priority: Int,
  call call: Value,
) -> Value {
  doc.object([
    #("Event-Category", doc.String("callcenter")),
    #("Event-Name", doc.String("member_call")),
    #("Account-ID", doc.String(account_id)),
    #("Queue-ID", doc.String(queue_id)),
    #("Call-ID", doc.String(call_id)),
    #("Callflow-Node", doc.String(node)),
    #("Joined-Timestamp", doc.Int(joined_at)),
    #("Priority", doc.Int(priority)),
    #("Call", call),
  ])
}

/// A `member_cancel` for a caller who has left, at `cancelled_at`,
/// Gregorian seconds.
pub fn cancel_message(
  account_id account_id: String,
  queue_id queue_id: String,
  call_id call_id: String,
  node node: String,
  reason reason: String,
  cancelled_at cancelled_at: Int,
) -> Value {
  doc.object([
    #("Event-Category", doc.String("callcenter")),
    #("Event-Name", doc.String("member_cancel")),
    #("Account-ID", doc.String(account_id)),
    #("Queue-ID", doc.String(queue_id)),
    #("Call-ID", doc.String(call_id)),
    #("Callflow-Node", doc.String(node)),
    #("Reason", doc.String(reason)),
    #("Cancelled-Timestamp", doc.Int(cancelled_at)),
  ])
}

/// Where the callflow holding a caller hears the dispatcher: the
/// `Controller-Queue` on the caller's own `kapps_call`, which is
/// `pid://<cf_exe>/<queue>` -- the queue of the callflow listener on the node
/// running the call, and the executor it hands a message for the call to.
/// Nothing, on a call that does not say, which a stub call and a caller
/// rebuilt from their record do not.
pub fn controller_queue(call: Value) -> Option(String) {
  case doc.get_string(call, ["Controller-Queue"]) {
    Ok("") | Error(Nil) -> None
    Ok(queue) -> Some(queue)
  }
}

/// The least that is still a call: an id and the queue commands go to. A
/// real caller's `Call` is the whole `kapps_call` the callflow action had.
pub fn stub_call(call_id: String, node: String) -> Value {
  doc.object([
    #("Call-ID", doc.String(call_id)),
    #("Control-Queue", doc.String("")),
    #("Switch-Nodename", doc.String(node)),
  ])
}
