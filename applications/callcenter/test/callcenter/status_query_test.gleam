//// The live status query: the request it sends, and the translation from
//// the wire's spelling to the API's.

import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import kazoo/doc

import callcenter/dispatcher
import callcenter/status
import callcenter/status_query
import cf_callcenter
import support/cluster

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue = "37139638ff5b68f155d8445178524df1"

fn an_answer() -> doc.Value {
  doc.object([
    #("Account-ID", doc.String(account)),
    #("Node", doc.String("kazoo_apps@127.0.0.1")),
    #("Shard", doc.Int(3)),
    #(
      "Queues",
      doc.List([
        doc.object([
          #("Queue-ID", doc.String(queue)),
          #(
            "Waiting",
            doc.List([
              doc.object([
                #("Call-ID", doc.String("5c7a1d2e-3f40")),
                #("Caller-ID-Number", doc.String("+15551234567")),
                #("Joined-Timestamp", doc.Int(63_929_305_001)),
                #("Media-Node", doc.String("freeswitch@fs1.example.test")),
                #("Position", doc.Int(1)),
              ]),
            ]),
          ),
          #(
            "Agents",
            doc.List([
              doc.object([
                #("Agent-ID", doc.String("jane")),
                #("Activity", doc.String("on_call")),
                #("Availability", doc.String("available")),
                #("Answered", doc.Int(12)),
                #("Missed", doc.Int(1)),
                #("Tier-Level", doc.Int(1)),
                #("Tier-Position", doc.Int(1)),
                #("Tier-State", doc.String("active_inbound")),
                #("Last-Call-End", doc.Int(63_929_304_822)),
                #("Call-ID", doc.String("5c7a1d2e-3f40")),
                #("Queue-ID", doc.String(queue)),
                #("Connected", doc.Bool(True)),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

pub fn request_test() {
  let all = status_query.request(account, None)
  assert doc.get_string(all, ["Account-ID"]) == Ok(account)
  assert doc.get(all, ["Queue-ID"]) == Error(Nil)

  let one = status_query.request(account, Some(queue))
  assert doc.get_string(one, ["Queue-ID"]) == Ok(queue)
}

/// Every node answers; only the one holding the shard has anything in it, so
/// picking a queue out is a flatten and not a merge.
pub fn queue_test() {
  let silent = doc.object([#("Queues", doc.List([]))])
  let assert Some(entry) = status_query.queue([silent, an_answer()], queue)
  assert doc.get_string(entry, ["Queue-ID"]) == Ok(queue)

  assert status_query.queue([silent], queue) == None
  assert status_query.queue([an_answer()], "another") == None
}

/// Activity is per user, so it is read out of whichever queue mentions the
/// agent.
pub fn activities_test() {
  let activities = status_query.activities([an_answer()])
  assert dict.get(activities, "jane") == Ok("on_call")
  assert dict.get(activities, "john") == Error(Nil)
  assert dict.size(status_query.activities([])) == 0
}

/// The API's own names, with a null for whatever the answer left out, so a
/// client sees one shape.
pub fn to_api_test() {
  let assert Some(entry) = status_query.queue([an_answer()], queue)
  let rendered = status_query.to_api(entry)

  assert doc.get_string(rendered, ["queue_id"]) == Ok(queue)

  let assert Ok([waiting]) = doc.get_list(rendered, ["waiting"])
  assert doc.get_string(waiting, ["call_id"]) == Ok("5c7a1d2e-3f40")
  assert doc.get_int(waiting, ["joined_timestamp"]) == Ok(63_929_305_001)
  assert doc.get_string(waiting, ["media_node"])
    == Ok("freeswitch@fs1.example.test")
  assert doc.get_int(waiting, ["position"]) == Ok(1)
  // Nobody is being tried, and the field is there saying so.
  assert doc.get(waiting, ["offered_to"]) == Ok(doc.Null)
  assert doc.get(waiting, ["caller_id_name"]) == Ok(doc.Null)

  let assert Ok([agent]) = doc.get_list(rendered, ["agents"])
  assert doc.get_string(agent, ["agent_id"]) == Ok("jane")
  assert doc.get_string(agent, ["activity"]) == Ok("on_call")
  assert doc.get_string(agent, ["availability"]) == Ok("available")
  assert doc.get_string(agent, ["tier_state"]) == Ok("active_inbound")
  assert doc.get_int(agent, ["tier_level"]) == Ok(1)
  assert doc.get_int(agent, ["answered"]) == Ok(12)
  assert doc.get_int(agent, ["last_call_end"]) == Ok(63_929_304_822)
  // The call the agent is on, for a supervisor to listen in on.
  assert doc.get_string(agent, ["call_id"]) == Ok("5c7a1d2e-3f40")
  assert doc.get_string(agent, ["queue_id"]) == Ok(queue)
  assert doc.get_bool(agent, ["connected"]) == Ok(True)
}

/// A queue nobody is dispatching answers the shape, not an error: nobody can
/// be waiting in it.
pub fn empty_test() {
  let empty = status_query.empty(queue)
  assert doc.get_string(empty, ["queue_id"]) == Ok(queue)
  assert doc.get_list(empty, ["waiting"]) == Ok([])
  assert doc.get_list(empty, ["agents"]) == Ok([])
}

/// Without a broker there is nothing to ask, and the caller falls back to
/// the empty answer rather than failing the request.
pub fn ask_without_a_broker_test() {
  assert status_query.ask(account, Some(queue)) |> is_error
}

fn is_error(answer: Result(a, b)) -> Bool {
  case answer {
    Error(_) -> True
    Ok(_) -> False
  }
}

//
// --- Who answers ------------------------------------------------------------
//

/// A node answers when it holds the account's shard, and a dispatcher is not
/// what makes it the node that knows.
///
/// One starts on an account's first waiting caller and stops when the account
/// goes quiet, so the queue a caller is about to enter usually has none.
/// Answering only when there is one leaves that caller -- and every live view
/// on a quiet account -- waiting out the collection's whole timeout for an
/// answer that was never coming.
pub fn a_shard_holder_with_no_dispatcher_still_answers_test() {
  let queues = [doc.object([#("Queue-ID", doc.String(queue))])]

  assert status.queues_of(status.Dispatching(queues, [])) == Some(queues)
  // Held here, nobody waiting: the empty list is the answer, and it is an
  // answer.
  assert status.queues_of(status.Quiet) == Some([])
  // Somebody else holds the shard. Saying nothing is what makes the
  // collection stop at the one node that does.
  assert status.queues_of(status.Elsewhere) == None
}

/// The answer names who is on a queue call, which a login lamp probe
/// answered on a node that does not hold the shard asks for. Only a
/// dispatcher knows of anybody.
pub fn the_answer_says_who_is_on_a_queue_call_test() {
  assert status.on_queue_call_of(status.Dispatching([], ["ann"])) == ["ann"]
  assert status.on_queue_call_of(status.Quiet) == []
  assert status.on_queue_call_of(status.Elsewhere) == []

  let answer =
    doc.set(an_answer(), ["On-Queue-Call"], doc.List([doc.String("jane")]))
  assert status_query.on_queue_call([answer]) == ["jane"]
  // An answer from before the field existed, and no answer at all: nobody.
  assert status_query.on_queue_call([an_answer()]) == []
  assert status_query.on_queue_call([]) == []
}

/// Who is waiting in a queue, by call id. A queue nobody described has
/// nobody in it.
pub fn waiting_calls_test() {
  assert status_query.waiting_calls([an_answer()], queue) == ["5c7a1d2e-3f40"]
  assert status_query.waiting_calls([an_answer()], "another-queue") == []
  assert status_query.waiting_calls([], queue) == []
}

// --- A busy dispatcher -----------------------------------------------------

/// The holder asked its dispatcher with five seconds
/// and the requester gave up after three, so a busy dispatcher cost every
/// caller entering the queue three seconds for nothing. The holder's wait is
/// now well inside the requester's.
pub fn the_holder_answers_before_the_requester_gives_up_test() {
  assert status.holder_timeout_ms * 2 <= status_query.timeout_ms
}

/// A dispatcher that is still there and does not answer in time is `Busy`,
/// within the budget, and the answer given for it names no queue.
pub fn a_busy_dispatcher_is_answered_for_test() {
  let owner = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let never_answers: process.Subject(dispatcher.Message) =
        process.new_subject()
      process.send(owner, never_answers)
      process.sleep_forever()
    })
  let assert Ok(never_answers) = process.receive(owner, 1000)

  let started = monotonic_ms()
  assert status.ask_dispatcher(never_answers, Some(queue), 200) == status.Busy
  assert monotonic_ms() - started < 1000

  assert status.queues_of(status.Busy) == Some([])
  assert status.on_queue_call_of(status.Busy) == []
}

/// What the call path makes of that answer: the queue is not in it, which
/// is not said and not zero, so the caller joins. A queue that turns callers
/// away with no agents does not turn this one away over a busy dispatcher.
pub fn a_busy_answer_turns_nobody_away_test() {
  let answer =
    doc.object([
      #("Account-ID", doc.String(account)),
      #("Queues", doc.List([])),
      #("On-Queue-Call", doc.List([])),
    ])
  assert cf_callcenter.status_of(queue, [answer]) == None
  let strict =
    doc.object([
      #("enter_when_empty", doc.Bool(False)),
      #("max_queue_size", doc.Int(1)),
    ])
  assert cf_callcenter.entry(strict, cf_callcenter.status_of(queue, [answer]))
    == cf_callcenter.Enter
}

/// A dispatcher that answers is what it says, both questions inside the
/// budget.
pub fn a_dispatcher_that_answers_test() {
  let c = cluster.new([], [])
  let assert status.Dispatching(_queues, []) =
    status.ask_dispatcher(c.dispatcher, None, status.holder_timeout_ms)
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
