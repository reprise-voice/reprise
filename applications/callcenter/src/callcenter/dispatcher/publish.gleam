//// The events a dispatcher publishes, as payloads: `agent_offer`,
//// `agent_answered`, `agent_wrapup`, `member_offer`, `member_connected`,
//// `member_result`, `member_position` and `queue_stats`.
////
//// Every one describes a transition the dispatcher made, and every one goes
//// out through `system.publish`, with the headers `kz_api` requires of it.
//// Nothing here reads or changes the dispatcher's state: the account is all
//// a payload needs of it.
////
//// The four about one caller go out on the exchange, under
//// `callcenter.call.<account>.<call>`, for whoever watches: webhooks,
//// blackhole's sockets, the wallboard. The caller hears nothing of them:
//// what they need, their actor is told directly (`callcenter/call/actor`),
//// and the callflow action waits only for the caller to be handed back.

import callcenter/system
import callcenter/types.{type Member}
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc.{type Value}

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
/// `member_connected` or `member_result`, on the exchange.
///
/// Every one says which passage it is about, as `Joined-Timestamp`: a caller
/// sent from a queue straight back into it is the same call in the same
/// queue, and whoever watches tells one passage from the next by the join.
pub fn call(
  account_id: String,
  event_name: String,
  member: Member,
  fields: List(#(String, Value)),
) -> Nil {
  system.publish(
    event_name,
    doc.merge(
      doc.object([
        #("Account-ID", doc.String(account_id)),
        #("Queue-ID", doc.String(member.queue_id)),
        #("Call-ID", doc.String(member.call_id)),
        #("Joined-Timestamp", doc.Int(member.joined)),
      ]),
      doc.object(fields),
    ),
  )
}

/// `member_position`: where one caller stands in their queue, and whether
/// an offer is in flight for them (`position.ringing_for`).
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
