//// The events a dispatcher publishes, as payloads: `agent_offer`,
//// `agent_answered`, `agent_wrapup`, `member_offer`, `member_connected`,
//// `member_result`, `member_position` and `queue_stats`.
////
//// Every one describes a transition the dispatcher made, and every one goes
//// out through `system.publish`, with the headers `kz_api` requires of it.
//// Nothing here reads or changes the dispatcher's state: the account is all
//// a payload needs of it.
////
//// The four about one caller go out twice. Once on the exchange, under
//// `callcenter.call.<account>.<call>`, for whoever watches: webhooks,
//// blackhole's sockets, the wallboard. And once to the callflow holding the
//// caller, at the `Controller-Queue` their call carries, which is how the
//// callflow action hears them: it binds nothing of its own.

import callcenter/member as member_message
import callcenter/system
import callcenter/types.{type Member}
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/amqp
import kazoo/doc.{type Value}

/// Where an event about one caller goes.
pub type Target {
  /// The `callcenter` exchange, under the call's routing key.
  Exchange
  /// The callflow holding the caller, through the queue it was routed on.
  Caller(queue: String)
}

/// An event about one agent, on the agent's routing key.
pub fn agent(
  account_id: String,
  event_name: String,
  agent_id: String,
  fields: List(#(String, Value)),
) -> Nil {
  system.publish(
    event_name,
    doc.merge(
      doc.object([
        #("Account-ID", doc.String(account_id)),
        #("Agent-ID", doc.String(agent_id)),
      ]),
      doc.object(fields),
    ),
  )
}

/// An event about one waiting caller: `member_offer`, `member_position`,
/// `member_connected` or `member_result`, to each of `call_targets`.
///
/// Every one says which passage it is about, as `Joined-Timestamp`: a caller
/// sent from a queue straight back into it is the same call in the same
/// queue, and the action tells the passage it is running from the one it
/// left by the join.
pub fn call(
  account_id: String,
  event_name: String,
  member: Member,
  fields: List(#(String, Value)),
) -> Nil {
  let payload =
    doc.merge(
      doc.object([
        #("Account-ID", doc.String(account_id)),
        #("Queue-ID", doc.String(member.queue_id)),
        #("Call-ID", doc.String(member.call_id)),
        #("Joined-Timestamp", doc.Int(member.joined)),
      ]),
      doc.object(fields),
    )
  list.each(call_targets(member), fn(target) {
    case target {
      Exchange -> system.publish(event_name, payload)
      Caller(queue) -> to_caller(queue, event_name, payload)
    }
  })
}

/// Where the events about one caller go: always the exchange, and the
/// caller's own callflow when their call says where that is.
///
/// All four go to both. `member_position`, `member_connected` and
/// `member_result` are what webhooks and the wallboard read. `member_offer`
/// is read by nobody but the action, but blackhole relays everything under
/// the call's key to a socket subscribed to it, and a node of the release
/// before this one runs an action that hears the dispatcher only on the
/// exchange: an offer it did not hear lets the no-agent clock run while the
/// phones ring. One more publish per offer is what that costs.
///
/// A call with no `Controller-Queue` -- a stub, or a caller rebuilt from
/// their record after a failover -- is not a callflow anybody can reach.
pub fn call_targets(member: Member) -> List(Target) {
  case member_message.controller_queue(member.call) {
    Some(queue) -> [Exchange, Caller(queue)]
    None -> [Exchange]
  }
}

/// One event to the callflow holding the caller, through
/// `kapi_callcenter:publish_caller_event/2`.
///
/// Not `mandatory`, and nothing is waited for: a callflow node that has gone
/// took its queue with it, and the broker drops what nobody can route, which
/// is right, since the caller went with the node. The publish is on a pooled
/// channel like every other event here.
fn to_caller(queue: String, event_name: String, payload: Value) -> Nil {
  let _ =
    amqp.publish_to(
      target: queue,
      module: system.category,
      function: "caller_event",
      payload: doc.merge(
        amqp.default_headers(system.category, system.category, event_name),
        payload,
      ),
    )
  Nil
}

/// `member_position`: where one caller stands in their queue, and whether
/// an offer is in flight for them (`position.ringing_for`). `Offered` false
/// is what ends an action's belief in a ring whose end its channel never
/// showed: the dispatcher holds no offer for the caller any more.
/// `Agents-Available` is left out when `available` is `None`: a count the
/// dispatcher cannot vouch for is not said, rather than said as zero.
pub fn position(
  account_id: String,
  member: Member,
  position: Int,
  waiting: Int,
  available: Option(Int),
  offered: Bool,
  now: Int,
) -> Nil {
  let available = case available {
    Some(count) -> [#("Agents-Available", doc.Int(count))]
    None -> []
  }
  call(account_id, "member_position", member, [
    #("Position", doc.Int(position)),
    #("Waiting", doc.Int(waiting)),
    #("Offered", doc.Bool(offered)),
    #("Timestamp", doc.Int(now)),
    // Who the caller is and where they are, so a screen watching the queue
    // can name them without a lookup and without having seen them arrive.
    // Every one of these is optional on the wire: the caller who withheld
    // their number simply has none.
    ..list.append(available, name_and_place(member))
  ])
}

fn name_and_place(member: Member) -> List(#(String, Value)) {
  [
    #("Caller-ID-Name", option.map(member.caller_id_name, doc.String)),
    #("Caller-ID-Number", option.map(member.caller_id_number, doc.String)),
    #("Joined-Timestamp", Some(doc.Int(member.joined))),
    #("Media-Node", media_node(member)),
  ]
  |> list.filter_map(fn(pair) {
    case pair.1 {
      Some(value) -> Ok(#(pair.0, value))
      None -> Error(Nil)
    }
  })
}

/// `queue_stats`: callers waiting, the longest wait, and agents free.
pub fn stats(
  account_id: String,
  queue_id: String,
  stats: #(Int, Int, Int),
  now: Int,
) -> Nil {
  let #(waiting, longest, available) = stats
  let _ =
    system.publish(
      "queue_stats",
      doc.object([
        #("Account-ID", doc.String(account_id)),
        #("Queue-ID", doc.String(queue_id)),
        #("Waiting", doc.Int(waiting)),
        #("Longest-Wait", doc.Int(longest)),
        #("Agents-Available", doc.Int(available)),
        #("Timestamp", doc.Int(now)),
      ]),
    )
  Nil
}

/// The media server the caller's channel is on, which is on the caller's own
/// call and not on the member message around it: a member is a pointer to a
/// channel that lives on a switch, and this is which switch.
pub fn media_node(member: Member) -> Option(Value) {
  case doc.get_string(member.call, ["Switch-Nodename"]) {
    Ok("") | Error(Nil) -> None
    Ok(node) -> Some(doc.String(node))
  }
}
