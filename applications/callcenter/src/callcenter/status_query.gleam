//// Asking the cluster what is happening right now.
////
//// Waiting callers and the agents being tried are not in a database: they
//// are in the node that holds the account's shard. `status_req` asks, and
//// only that node answers -- every other node answers nothing at all -- so
//// one answer is the whole picture and the collection stops at the first.
////
//// The answer comes back in the wire's own spelling, `Queue-ID` and
//// `Joined-Timestamp`, because that is what the schema and the WebSocket
//// carry. Crossbar answers in the API's, so the rendering here is the
//// translation and the only place it happens.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/amqp
import kazoo/doc.{type Value}

/// How long Crossbar waits for the node that holds the shard. One node
/// answers; the rest are silent, so this is a round trip and not a sweep.
pub const timeout_ms = 3000

/// Ask about an account, or about one of its queues.
pub fn ask(
  account_id: String,
  queue_id: Option(String),
) -> Result(List(Value), amqp.Error) {
  amqp.call_collect(
    module: "callcenter",
    function: "status_req",
    payload: request(account_id, queue_id),
    until: amqp.Count(1),
    timeout: timeout_ms,
  )
}

/// The request, as `kapi.callcenter.status_req` validates it.
pub fn request(account_id: String, queue_id: Option(String)) -> Value {
  doc.merge(
    amqp.default_headers("callcenter", "callcenter", "status_req"),
    doc.object_some([
      #("Account-ID", Some(doc.String(account_id))),
      #("Queue-ID", option.map(queue_id, doc.String)),
    ]),
  )
}

/// Every queue any answer described. A node that does not hold the shard
/// answers nothing and a holder with no dispatcher for the account answers
/// an empty list, so this is a flatten and not a merge.
pub fn queues(answers: List(Value)) -> List(Value) {
  list.flat_map(answers, fn(answer) {
    doc.get_list(answer, ["Queues"]) |> result.unwrap([])
  })
}

/// One queue's live state, or nothing when nobody is dispatching it.
pub fn queue(answers: List(Value), queue_id: String) -> Option(Value) {
  queues(answers)
  |> list.filter(fn(entry) {
    doc.get_string(entry, ["Queue-ID"]) == Ok(queue_id)
  })
  |> list.first
  |> option.from_result
}

/// The call ids of the callers waiting in one queue, as the node dispatching
/// it listed them. A queue nobody described has nobody waiting in it.
pub fn waiting_calls(answers: List(Value), queue_id: String) -> List(String) {
  case queue(answers, queue_id) {
    None -> []
    Some(entry) ->
      doc.get_list(entry, ["Waiting"])
      |> result.unwrap([])
      |> list.filter_map(fn(waiting) { doc.get_string(waiting, ["Call-ID"]) })
  }
}

/// What each agent is doing, across every queue in the answers. Activity is
/// per user and not per queue, so the first mention of an agent is as good
/// as any other.
pub fn activities(answers: List(Value)) -> Dict(String, String) {
  queues(answers)
  |> list.flat_map(fn(entry) {
    doc.get_list(entry, ["Agents"]) |> result.unwrap([])
  })
  |> list.fold(dict.new(), fn(seen, agent) {
    case
      doc.get_string(agent, ["Agent-ID"]),
      doc.get_string(agent, ["Activity"])
    {
      Ok(agent_id), Ok(activity) -> dict.insert(seen, agent_id, activity)
      _, _ -> seen
    }
  })
}

/// The agents the answering node has on a queue call: answered, and not yet
/// ended. Nobody when nobody answered, which is what a cluster where nobody
/// holds the account's shard says.
pub fn on_queue_call(answers: List(Value)) -> List(String) {
  answers
  |> list.flat_map(fn(answer) { doc.strings(answer, ["On-Queue-Call"]) })
  |> list.unique
}

/// One queue's live state as the API answers it: the wire's capitals and
/// hyphens become the API's own names.
pub fn to_api(entry: Value) -> Value {
  doc.object([
    #("queue_id", doc.get(entry, ["Queue-ID"]) |> result.unwrap(doc.Null)),
    #(
      "waiting",
      doc.List(
        doc.get_list(entry, ["Waiting"])
        |> result.unwrap([])
        |> list.map(waiting_to_api),
      ),
    ),
    #(
      "agents",
      doc.List(
        doc.get_list(entry, ["Agents"])
        |> result.unwrap([])
        |> list.map(agent_to_api),
      ),
    ),
  ])
}

/// An account with no dispatcher answers the shape and not an error: nobody
/// is waiting, because nobody could be.
pub fn empty(queue_id: String) -> Value {
  doc.object([
    #("queue_id", doc.String(queue_id)),
    #("waiting", doc.List([])),
    #("agents", doc.List([])),
  ])
}

fn waiting_to_api(waiting: Value) -> Value {
  renamed(waiting, [
    #("Call-ID", "call_id"),
    #("Caller-ID-Name", "caller_id_name"),
    #("Caller-ID-Number", "caller_id_number"),
    #("Joined-Timestamp", "joined_timestamp"),
    #("Media-Node", "media_node"),
    #("Offered-To", "offered_to"),
    #("Position", "position"),
  ])
}

fn agent_to_api(agent: Value) -> Value {
  renamed(agent, [
    #("Activity", "activity"),
    #("Agent-ID", "agent_id"),
    #("Answered", "answered"),
    #("Availability", "availability"),
    #("Call-ID", "call_id"),
    #("Connected", "connected"),
    #("Last-Call-End", "last_call_end"),
    #("Missed", "missed"),
    #("Queue-ID", "queue_id"),
    #("Tier-Level", "tier_level"),
    #("Tier-Position", "tier_position"),
    #("Tier-State", "tier_state"),
  ])
}

/// The named fields, under their API names, with a `null` for the ones the
/// answer left out so that a client sees the same shape every time.
fn renamed(value: Value, names: List(#(String, String))) -> Value {
  doc.object(
    list.map(names, fn(pair) {
      let #(from, to) = pair
      #(to, doc.get(value, [from]) |> result.unwrap(doc.Null))
    }),
  )
}
