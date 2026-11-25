//// The callflow action: which branch a caller takes, and what goes on the
//// member queue when they join.
////
//// There is no release under `gleam test`, so the default headers every
//// message carries are empty here and the payloads are exactly the fields
//// this module puts on them, which is what these check.

import cf_callcenter
import gleam/option.{None, Some}
import gleam/result
import kazoo/call
import kazoo/doc
import kazoo/kazoo

const account_id = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue_id = "6a7b8c9d0e1f2a3b4c5d6e7f80912233"

const call_id = "9f8e7d6c-5b4a-3210"

fn queue(members: List(#(String, doc.Value))) -> doc.Value {
  doc.object([#("name", doc.String("Support")), ..members])
}

/// A status from a node that said both numbers.
fn status(
  waiting waiting: Int,
  agents_available agents_available: Int,
) -> cf_callcenter.Status {
  cf_callcenter.Status(
    waiting: Some(waiting),
    agents_available: Some(agents_available),
  )
}

//
// --- Getting in ------------------------------------------------------------
//

/// Nobody holding the account's shard is not a refusal: the caller joins and
/// the member message waits on the durable queue for whoever takes it.
pub fn no_answer_lets_the_caller_in_test() {
  assert cf_callcenter.entry(queue([]), None) == cf_callcenter.Enter
}

pub fn a_queue_with_room_takes_the_caller_test() {
  assert cf_callcenter.entry(
      queue([#("max_queue_size", doc.Int(5))]),
      Some(status(waiting: 4, agents_available: 1)),
    )
    == cf_callcenter.Enter
}

pub fn a_full_queue_test() {
  assert cf_callcenter.entry(
      queue([#("max_queue_size", doc.Int(5))]),
      Some(status(waiting: 5, agents_available: 1)),
    )
    == cf_callcenter.Full
}

/// `max_queue_size` zero is no limit, which is what `queues.json` defaults
/// to.
pub fn no_size_limit_test() {
  assert cf_callcenter.entry(
      queue([#("max_queue_size", doc.Int(0))]),
      Some(status(waiting: 900, agents_available: 1)),
    )
    == cf_callcenter.Enter
}

/// `enter_when_empty` defaults to true, so a queue that says nothing takes
/// callers with no agents logged in.
pub fn an_empty_queue_takes_callers_by_default_test() {
  assert cf_callcenter.entry(
      queue([]),
      Some(status(waiting: 0, agents_available: 0)),
    )
    == cf_callcenter.Enter
}

pub fn an_empty_queue_that_refuses_test() {
  assert cf_callcenter.entry(
      queue([#("enter_when_empty", doc.Bool(False))]),
      Some(status(waiting: 0, agents_available: 0)),
    )
    == cf_callcenter.NoAgents
  assert cf_callcenter.entry(
      queue([#("enter_when_empty", doc.Bool(False))]),
      Some(status(waiting: 0, agents_available: 2)),
    )
    == cf_callcenter.Enter
}

/// A full queue is full whether or not anybody is logged in.
pub fn full_beats_empty_test() {
  assert cf_callcenter.entry(
      queue([
        #("max_queue_size", doc.Int(1)),
        #("enter_when_empty", doc.Bool(False)),
      ]),
      Some(status(waiting: 3, agents_available: 0)),
    )
    == cf_callcenter.Full
}

/// A node that answered without saying how many agents it has has not said
/// there are none. Zero turns a caller away; "did not say" must not.
pub fn numbers_nobody_gave_are_not_a_refusal_test() {
  assert cf_callcenter.entry(
      queue([#("enter_when_empty", doc.Bool(False))]),
      Some(cf_callcenter.Status(waiting: None, agents_available: None)),
    )
    == cf_callcenter.Enter

  // And a queue with a size limit is not full because nobody counted.
  assert cf_callcenter.entry(
      queue([#("max_queue_size", doc.Int(1))]),
      Some(cf_callcenter.Status(waiting: None, agents_available: Some(1))),
    )
    == cf_callcenter.Enter
}

pub fn branches_test() {
  assert cf_callcenter.branch_of(cf_callcenter.Full) == "queue_full"
  assert cf_callcenter.branch_of(cf_callcenter.NoAgents) == "no_agents"
  assert cf_callcenter.branch_of(cf_callcenter.Enter) == "_"
}

/// A caller whose member message could not go out has not joined anything:
/// nobody has been told about them and nobody will be. They leave on the
/// branch a queue with nobody to take them already has, which every callflow
/// with a queue in it is wired for -- rather than waiting out `max_wait_time`
/// in silence for an agent nobody was ever asked for.
pub fn a_caller_who_could_not_join_leaves_at_once_test() {
  assert cf_callcenter.unjoined_branch() == "no_agents"
}

//
// --- What the cluster answered ---------------------------------------------
//

fn answer(queues: List(doc.Value)) -> doc.Value {
  doc.object([
    #("Account-ID", doc.String(account_id)),
    #("Queues", doc.List(queues)),
  ])
}

/// One queue in an answer, spelled as `dispatcher/status` spells it: the
/// lists for a screen, and the counts beside them for a caller arriving.
fn queue_status(id: String, waiting: Int, agents: Int) -> doc.Value {
  doc.object([
    #("Queue-ID", doc.String(id)),
    #("Waiting", doc.List([])),
    #("Waiting-Count", doc.Int(waiting)),
    #("Agents-Available", doc.Int(agents)),
    #("Agents", doc.List([])),
  ])
}

pub fn the_queue_is_found_in_the_answer_test() {
  assert cf_callcenter.status_of(queue_id, [
      answer([queue_status("another", 9, 9), queue_status(queue_id, 3, 2)]),
    ])
    == Some(status(waiting: 3, agents_available: 2))
}

/// A node that is not dispatching the account says nothing about the queue,
/// which is not the same as saying it is empty.
pub fn a_node_with_nothing_to_say_is_skipped_test() {
  assert cf_callcenter.status_of(queue_id, [answer([])]) == None
  assert cf_callcenter.status_of(queue_id, [
      answer([]),
      answer([queue_status(queue_id, 1, 1)]),
    ])
    == Some(status(waiting: 1, agents_available: 1))
  assert cf_callcenter.status_of(queue_id, []) == None
}

//
// --- The caller's media ----------------------------------------------------
//

//
// --- The member messages ---------------------------------------------------
//

fn a_call() -> doc.Value {
  doc.object([
    #("Call-ID", doc.String(call_id)),
    #("Account-ID", doc.String(account_id)),
    #("Control-Queue", doc.String("callctl-4b1f")),
    #("Resource-Type", doc.String("audio")),
  ])
}

pub fn a_member_call_test() {
  let message =
    cf_callcenter.member_call(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      call: a_call(),
      node: "kazoo_apps@one",
      joined: 63_900_000_000,
      priority: 0,
      caller_id_name: Some("Ada Lovelace"),
      caller_id_number: Some("2125550143"),
      shards: Some(64),
      handoff_id: "handoff-1",
      branches: doc.object([]),
    )
  assert doc.get_string(message, ["Account-ID"]) == Ok(account_id)
  assert doc.get_string(message, ["Queue-ID"]) == Ok(queue_id)
  assert doc.get_string(message, ["Call-ID"]) == Ok(call_id)
  assert doc.get_string(message, ["Callflow-Node"]) == Ok("kazoo_apps@one")
  assert doc.get_int(message, ["Joined-Timestamp"]) == Ok(63_900_000_000)
  assert doc.get_int(message, ["Priority"]) == Ok(0)
  assert doc.get_string(message, ["Caller-ID-Name"]) == Ok("Ada Lovelace")
  assert doc.get_string(message, ["Caller-ID-Number"]) == Ok("2125550143")
  assert doc.get(message, ["Call"]) == Ok(a_call())
  assert doc.get_int(message, ["Shard-Count"]) == Ok(64)
}

/// The whole call goes on the message, `Resource-Type` and the control queue
/// included: a node that rebuilds it after a failover has nothing else to
/// build an agent's endpoints from.
pub fn the_member_call_carries_the_whole_call_test() {
  let message =
    cf_callcenter.member_call(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      call: a_call(),
      node: "kazoo_apps@one",
      joined: 1,
      priority: 0,
      caller_id_name: None,
      caller_id_number: None,
      shards: None,
      handoff_id: "handoff-1",
      branches: doc.object([]),
    )
  assert doc.get_string(message, ["Call", "Resource-Type"]) == Ok("audio")
  assert doc.get_string(message, ["Call", "Control-Queue"])
    == Ok("callctl-4b1f")
}

/// A caller with no name on the channel leaves the field off rather than
/// sending an empty one, which `kapi_callcenter` types as a binary.
pub fn a_member_call_without_a_caller_id_test() {
  let message =
    cf_callcenter.member_call(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      call: a_call(),
      node: "kazoo_apps@one",
      joined: 1,
      priority: 0,
      caller_id_name: None,
      caller_id_number: None,
      shards: None,
      handoff_id: "handoff-1",
      branches: doc.object([]),
    )
  assert doc.get(message, ["Caller-ID-Name"]) == Error(Nil)
  assert doc.get(message, ["Caller-ID-Number"]) == Error(Nil)
  assert doc.get(message, ["Shard-Count"]) == Error(Nil)
}

/// A callflow naming a queue that is not there -- never was, was deleted, or
/// could not be read -- has no queue to put the caller in, and says why: the
/// caller takes `no_agents` rather than continuing past the queue as if they
/// had been in it, or waiting in a deleted one nobody is offered from.
pub fn a_queue_that_is_not_there_is_not_joined_test() {
  let live = doc.object([#("name", doc.String("Support"))])
  assert cf_callcenter.usable(Ok(live)) == Ok(live)
  assert cf_callcenter.usable(
      Ok(doc.set(live, ["pvt_deleted"], doc.Bool(False))),
    )
    |> result.is_ok
  assert cf_callcenter.usable(
      Ok(doc.set(live, ["pvt_deleted"], doc.Bool(True))),
    )
    == Error("was deleted")
  assert cf_callcenter.usable(Error(kazoo.NotFound)) == Error("does not exist")
  assert cf_callcenter.usable(Error(kazoo.Unavailable))
    == Error("could not be read: unavailable")
}

//
// --- The channel -----------------------------------------------------------
//

/// Joining a queue starts a passage nobody has answered yet: the agent and
/// the answer second an earlier passage left on the channel are unset in
/// the same `set` -- an empty value, which is how the switch unsets one --
/// so a caller transferred in by one queue's agent and then abandoning this
/// one does not end with a CDR saying that agent answered here.
pub fn the_channel_variables_a_queue_call_carries_test() {
  assert cf_callcenter.channel_vars(queue_id, queue([]), 63_900_000_000)
    == [
      #("Queue-ID", doc.String(queue_id)),
      #("Queue-Name", doc.String("Support")),
      #("Queue-Joined-Timestamp", doc.Int(63_900_000_000)),
      #("Agent-ID", doc.String("")),
      #("Queue-Answered-Timestamp", doc.String("")),
    ]
}

/// A queue with no name is still identifiable on the CDR.
pub fn a_queue_with_no_name_test() {
  assert cf_callcenter.channel_vars(queue_id, doc.object([]), 1)
    == [
      #("Queue-ID", doc.String(queue_id)),
      #("Queue-Name", doc.String(queue_id)),
      #("Queue-Joined-Timestamp", doc.Int(1)),
      #("Agent-ID", doc.String("")),
      #("Queue-Answered-Timestamp", doc.String("")),
    ]
}

pub fn priority_comes_from_the_action_first_test() {
  let plain = call.from_value(a_call())
  assert cf_callcenter.priority(doc.object([#("priority", doc.Int(7))]), plain)
    == 7
}

/// A caller who arrived with a priority on the channel keeps it, which is
/// how one queue hands a caller to another without losing their place.
pub fn priority_falls_back_to_the_channel_test() {
  let prioritised =
    call.from_value(
      doc.object([
        #("Call-ID", doc.String(call_id)),
        #("Custom-Channel-Vars", doc.object([#("Call-Priority", doc.Int(3))])),
      ]),
    )
  assert cf_callcenter.priority(doc.object([]), prioritised) == 3
  assert cf_callcenter.priority(doc.object([]), call.from_value(a_call())) == 0
}

/// The first queue a channel enters stamps it with when it did, and every
/// queue after keeps that stamp: the overflow, the transfer, the callflow
/// run again all count the caller's age from the first.
pub fn the_first_queue_stamps_the_channel_test() {
  let fresh = call.from_value(a_call())
  assert cf_callcenter.system_joined(fresh, 63_900_000_500) == 63_900_000_500

  let stamped =
    call.from_value(doc.set(
      a_call(),
      ["Custom-Channel-Vars", "Queue-System-Joined"],
      doc.Int(63_900_000_000),
    ))
  assert cf_callcenter.system_joined(stamped, 63_900_000_500) == 63_900_000_000

  // Back from the switch on a new route request, the variable is text.
  let rerun =
    call.from_value(doc.set(
      a_call(),
      ["Custom-Channel-Vars", "Queue-System-Joined"],
      doc.String("63900000000"),
    ))
  assert cf_callcenter.system_joined(rerun, 63_900_000_500) == 63_900_000_000
}

//
// --- The dispatcher's messages ---------------------------------------------
//

const executor = "<0.311.0>"

fn never() -> option.Option(String) {
  panic as "a callflow the route win started needs no listener looked up"
}

/// A callflow a route request started is reached where the route win was:
/// its controller queue names this executor.
pub fn a_routed_callflow_keeps_its_controller_queue_test() {
  let own = "pid://" <> executor <> "/callflow_route_5d1c"
  assert cf_callcenter.reachable_at(Some(own), Some(executor), never)
    == Some(own)
}

/// A resumed callflow carries the controller queue of whatever held the call
/// before, and is given one made from this executor and this node's
/// callflow listener.
pub fn a_resumed_callflow_is_given_its_own_address_test() {
  let node_queue = fn() { Some("callflow_route_77aa") }
  let own = Some("pid://" <> executor <> "/callflow_route_77aa")
  // An executor that has ended.
  assert cf_callcenter.reachable_at(
      Some("pid://<0.99.0>/callflow_route_5d1c"),
      Some(executor),
      node_queue,
    )
    == own
  // A conference participant's queue.
  assert cf_callcenter.reachable_at(
      Some("conference-participant-q"),
      Some(executor),
      node_queue,
    )
    == own
  assert cf_callcenter.reachable_at(None, Some(executor), node_queue) == own
}

/// With nothing better to offer, what the call says stands.
pub fn without_an_executor_or_a_listener_the_call_says_test() {
  let stale = Some("pid://<0.99.0>/callflow_route_5d1c")
  assert cf_callcenter.reachable_at(stale, None, never) == stale
  assert cf_callcenter.reachable_at(stale, Some(executor), fn() { None })
    == stale
  assert cf_callcenter.reachable_at(None, None, never) == None
}
//
// --- The announcement ------------------------------------------------------
//
