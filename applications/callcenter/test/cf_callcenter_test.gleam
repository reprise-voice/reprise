//// The callflow action: which branch a caller takes, and what goes on the
//// member queue when they join.
////
//// There is no release under `gleam test`, so the default headers every
//// message carries are empty here and the payloads are exactly the fields
//// this module puts on them, which is what these check.

import callcenter/announce
import callcenter/caller
import callcenter/status as holder
import callcenter/types
import cf_callcenter
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
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

/// Every answer a shard holder of this release gives says its dispatchers
/// send to the controller queue -- the empty ones too, since a dispatcher
/// starts on the account's first caller -- and that is what the action
/// reads as needing no listener. A node that does not hold the shard gives
/// no answer.
pub fn a_holder_says_how_it_reaches_a_caller_test() {
  let assert Some(quiet) =
    holder.response(doc.object([]), "acct", 3, holder.Quiet)
  let assert Some(busy) =
    holder.response(doc.object([]), "acct", 3, holder.Busy)
  assert doc.get_string(quiet, ["Caller-Delivery"])
    == Ok(cf_callcenter.controller_delivery)
  assert cf_callcenter.delivery_of([quiet]) == cf_callcenter.ToController
  assert cf_callcenter.delivery_of([busy]) == cf_callcenter.ToController
  assert holder.response(doc.object([]), "acct", 3, holder.Elsewhere) == None
}

//
// --- The caller's media ----------------------------------------------------
//

fn an_event(name: String, fields: List(#(String, doc.Value))) -> doc.Value {
  doc.object([
    #("Event-Category", doc.String("call_event")),
    #("Event-Name", doc.String(name)),
    ..fields
  ])
}

/// Nothing is played until the switch says the channel is up, and the switch
/// says it two ways: `CHANNEL_ANSWER` on a channel that was ringing, and the
/// execute-complete for `answer` either way. A channel some earlier action
/// already answered sends only the second, so both count.
pub fn the_channel_is_up_test() {
  assert cf_callcenter.is_answered(an_event("CHANNEL_ANSWER", []))
  assert cf_callcenter.is_answered(
    an_event("CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("answer")),
      #("Channel-Answer-State", doc.String("answered")),
    ]),
  )

  // The end of the greeting is not the channel coming up.
  assert !cf_callcenter.is_answered(
    an_event("CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("noop")),
    ]),
  )
  assert !cf_callcenter.is_answered(an_event("CHANNEL_EXECUTE_COMPLETE", []))
  assert !cf_callcenter.is_answered(an_event("DTMF", []))
}

/// The loop may not sleep past the moment it gives up on an event the switch
/// never sent: a caller with no announcements and a long `max_wait_time` has
/// nothing else to wake it, and would wait the whole of it in silence.
pub fn the_loop_wakes_for_a_media_ceiling_test() {
  let a_long_wait = 600_000

  // Answering: five seconds from when the answer went out, and no longer.
  assert cf_callcenter.wake_ms(
      cf_callcenter.Answering(since: 100, greeting: None),
      a_long_wait,
      100,
    )
    == 5000
  assert cf_callcenter.wake_ms(
      cf_callcenter.Answering(since: 100, greeting: None),
      a_long_wait,
      103,
    )
    == 2000

  // Never zero, or a loop already past its ceiling spins.
  assert cf_callcenter.wake_ms(
      cf_callcenter.Answering(since: 100, greeting: None),
      a_long_wait,
      200,
    )
    == 10

  // A deadline of the caller's own that comes first still wins.
  assert cf_callcenter.wake_ms(
      cf_callcenter.Answering(since: 100, greeting: None),
      1500,
      100,
    )
    == 1500

  // On hold nothing is owed, so the caller's own deadline is the whole of it.
  assert cf_callcenter.wake_ms(cf_callcenter.Held, a_long_wait, 100)
    == a_long_wait
  assert cf_callcenter.wake_ms(cf_callcenter.Playing(since: 100), 90_000, 100)
    == 60_000
}

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
    )
  assert doc.get(message, ["Caller-ID-Name"]) == Error(Nil)
  assert doc.get(message, ["Caller-ID-Number"]) == Error(Nil)
  assert doc.get(message, ["Shard-Count"]) == Error(Nil)
}

pub fn a_member_cancel_test() {
  let message =
    cf_callcenter.member_cancel(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      reason: types.ExitKey,
      joined: 63_900_000_002,
      cancelled_at: 63_900_000_042,
    )
  assert doc.get_int(message, ["Joined-Timestamp"]) == Ok(63_900_000_002)
  assert doc.get_int(message, ["Cancelled-Timestamp"]) == Ok(63_900_000_042)
  assert doc.get_string(message, ["Account-ID"]) == Ok(account_id)
  assert doc.get_string(message, ["Queue-ID"]) == Ok(queue_id)
  assert doc.get_string(message, ["Call-ID"]) == Ok(call_id)
  assert doc.get_string(message, ["Reason"]) == Ok("exit_key")
}

/// The reasons are the enum `kapi_callcenter` validates `member_cancel`
/// against; a name that is not in it is a message the broker side rejects.
pub fn every_cancel_reason_test() {
  assert cf_callcenter.reason_name(types.Hangup) == "hangup"
  assert cf_callcenter.reason_name(types.Timeout) == "timeout"
  assert cf_callcenter.reason_name(types.NoAgentTimeout) == "no_agent_timeout"
  assert cf_callcenter.reason_name(types.ExitKey) == "exit_key"
  assert cf_callcenter.reason_name(types.QueueFull) == "queue_full"
  assert cf_callcenter.reason_name(types.Transfer) == "transfer"
  assert cf_callcenter.reason_name(types.QueueDeleted) == "queue_deleted"
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

/// A caller carrying these channel variables, as a call record built from
/// their channel does.
fn carrying(ccvs: List(#(String, doc.Value))) -> call.Call {
  call.from_value(
    doc.object([
      #("Call-ID", doc.String(call_id)),
      #("Custom-Channel-Vars", doc.object(ccvs)),
    ]),
  )
}

/// A queue with exit keys asks a ring from the caller's channel to read their
/// keys, which is what publishes a key pressed while an agent rings. A queue
/// without them asks nothing, and a channel that already asks -- the mark
/// comes back from the switch as text, or is on the record as it was set --
/// is never asked again: a ring running on it has kept the value it read.
pub fn only_the_first_queue_with_exit_keys_asks_the_ring_to_read_keys_test() {
  assert cf_callcenter.asks_ring_to_read_keys(["#"], carrying([]))
  assert cf_callcenter.asks_ring_to_read_keys(["1", "#"], carrying([]))
  assert !cf_callcenter.asks_ring_to_read_keys([], carrying([]))
  list.each([doc.String("true"), doc.Bool(True)], fn(mark) {
    let marked = carrying([#("Queue-Ring-Reads-Keys", mark)])
    assert !cf_callcenter.asks_ring_to_read_keys(["#"], marked)
  })
}

/// The cancel key is one no keypad sends. The switch compares a key with the
/// first character of it, and a cancel key a keypad could send would end the
/// ring in the switch as `NO_ANSWER`, which the offer counts as the agents'
/// miss.
pub fn the_rings_cancel_key_is_no_key_test() {
  let keys = string.to_graphemes("0123456789*#ABCDabcdWwFf")
  let assert Ok(first) = string.first(cf_callcenter.no_keypad_key)
  assert list.contains(keys, first) == False
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

fn relayed(fields: List(#(String, doc.Value))) -> doc.Value {
  doc.object([#("Call-ID", doc.String(call_id)), ..fields])
}

/// The executor relays everything about the call; the dispatcher's messages
/// are this caller's only when they are about this queue too.
pub fn whose_event_it_is_test() {
  let channel = relayed([#("Event-Category", doc.String("call_event"))])
  assert cf_callcenter.is_own(
    call_id,
    queue_id,
    cf_callcenter.FirstHere,
    channel,
  )
  assert !cf_callcenter.is_own(
    "another-call",
    queue_id,
    cf_callcenter.FirstHere,
    channel,
  )

  let this_queue =
    relayed([
      #("Event-Category", doc.String("callcenter")),
      #("Event-Name", doc.String("member_offer")),
      #("Queue-ID", doc.String(queue_id)),
    ])
  assert cf_callcenter.is_own(
    call_id,
    queue_id,
    cf_callcenter.FirstHere,
    this_queue,
  )

  // The last offer of a queue the caller timed out of, landing in the next.
  let earlier_queue =
    relayed([
      #("Event-Category", doc.String("callcenter")),
      #("Event-Name", doc.String("member_offer")),
      #("Queue-ID", doc.String("earlier-queue")),
    ])
  assert !cf_callcenter.is_own(
    call_id,
    queue_id,
    cf_callcenter.FirstHere,
    earlier_queue,
  )

  let no_queue =
    relayed([
      #("Event-Category", doc.String("callcenter")),
      #("Event-Name", doc.String("member_position")),
    ])
  assert !cf_callcenter.is_own(
    call_id,
    queue_id,
    cf_callcenter.FirstHere,
    no_queue,
  )
}

fn offer_joined(joined: option.Option(Int)) -> doc.Value {
  relayed([
    #("Event-Category", doc.String("callcenter")),
    #("Event-Name", doc.String("member_offer")),
    #("Queue-ID", doc.String(queue_id)),
    ..case joined {
      Some(joined) -> [#("Joined-Timestamp", doc.Int(joined))]
      None -> []
    }
  ])
}

/// A caller back in a queue this executor has had them in -- a timeout or
/// exit branch leading straight back -- hears only what is about the
/// passage it is running now. The first time here, whatever the dispatcher
/// says about the caller in the queue counts: a rerun on another node is
/// continuing the passage the dispatcher holds, under its older join. A
/// dispatcher that does not say is heard as it always was.
pub fn which_passage_a_message_is_about_test() {
  let first = cf_callcenter.FirstHere
  let again = cf_callcenter.Again(joined: 200)
  let own = fn(passage, event) {
    cf_callcenter.is_own(call_id, queue_id, passage, event)
  }
  assert own(first, offer_joined(Some(100)))
  assert own(first, offer_joined(Some(200)))
  assert own(first, offer_joined(None))
  assert own(again, offer_joined(Some(200)))
  assert !own(again, offer_joined(Some(100)))
  assert own(again, offer_joined(None))

  // The channel's own events are not the dispatcher's and name no passage.
  assert own(again, relayed([#("Event-Category", doc.String("call_event"))]))
}

/// What says which it is: a note on the call's key-value store, made by
/// each passage as it starts, per queue.
pub fn a_passage_notes_itself_on_the_call_test() {
  let fresh = call.from_value(doc.object([#("Call-ID", doc.String(call_id))]))
  assert cf_callcenter.passage_of(fresh, queue_id, 100)
    == cf_callcenter.FirstHere
  let ran = cf_callcenter.ran_here(fresh, queue_id, 100)
  assert cf_callcenter.passage_of(ran, queue_id, 200)
    == cf_callcenter.Again(joined: 200)
  assert cf_callcenter.passage_of(ran, "another-queue", 200)
    == cf_callcenter.FirstHere
}

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
// --- The dispatcher's position ---------------------------------------------
//

pub fn a_position_event_test() {
  assert cf_callcenter.position_of(
      doc.object([
        #("Event-Category", doc.String("callcenter")),
        #("Event-Name", doc.String("member_position")),
        #("Position", doc.Int(2)),
        #("Waiting", doc.Int(5)),
        #("Agents-Available", doc.Int(0)),
      ]),
    )
    == cf_callcenter.Position(
      position: Some(2),
      waiting: Some(5),
      agents_available: Some(0),
      offered: None,
    )
}

fn position(available: Int, offered: Bool) -> doc.Value {
  doc.object([
    #("Event-Category", doc.String("callcenter")),
    #("Event-Name", doc.String("member_position")),
    #("Position", doc.Int(1)),
    #("Waiting", doc.Int(1)),
    #("Agents-Available", doc.Int(available)),
    #("Offered", doc.Bool(offered)),
  ])
}

/// A position that says no offer is in flight ends the ring the caller was
/// told of -- a bridge sent and never run shows no end on the channel -- and
/// the no-agent clock starts from its count. One that says an offer is in
/// flight changes nothing, and never starts a ring nobody told of.
pub fn a_position_with_no_offer_out_ends_the_ring_test() {
  let ringing = caller.offered(caller.new(100), until: 125)
  assert caller.is_offered(ringing, at: 110)

  let over = cf_callcenter.position_heard(ringing, position(0, False), 110)
  assert caller.is_offered(over, at: 110) == False
  assert over.no_agents_since == Some(110)

  let still = cf_callcenter.position_heard(ringing, position(0, True), 110)
  assert caller.is_offered(still, at: 110)
  assert still.no_agents_since == None

  let waiting =
    cf_callcenter.position_heard(caller.new(100), position(0, True), 110)
  assert caller.is_offered(waiting, at: 110) == False
  assert waiting.no_agents_since == Some(110)
}

/// A position event that leaves a count out says nothing about it, which is
/// not the same as saying zero.
pub fn a_position_event_with_nothing_in_it_test() {
  assert cf_callcenter.position_of(doc.object([]))
    == cf_callcenter.Position(
      position: None,
      waiting: None,
      agents_available: None,
      offered: None,
    )
}

/// The status answer that let the caller in already counted the agents. With
/// none, the no-agent clock starts at the join and not at the first position
/// event, which a caller can miss: they would wait
/// out the whole `max_wait_time` of thirty seconds in a queue configured to
/// give up on them after ten with nobody there.
pub fn the_no_agent_clock_starts_from_the_status_that_let_the_caller_in_test() {
  let joined = 63_900_000_000
  let limits =
    caller.limits(
      doc.object([
        #("max_wait_time", doc.Int(30)),
        #("max_wait_time_with_no_agent", doc.Int(10)),
      ]),
    )

  let nobody =
    cf_callcenter.arriving(
      joined,
      Some(cf_callcenter.Status(waiting: Some(0), agents_available: Some(0))),
    )
  assert caller.expired(nobody, limits, now: joined + 9) == None
  assert caller.expired(nobody, limits, now: joined + 10)
    == Some(caller.NoAgentTooLong)

  // Somebody could take them: only the whole wait applies.
  let somebody =
    cf_callcenter.arriving(
      joined,
      Some(cf_callcenter.Status(waiting: Some(0), agents_available: Some(1))),
    )
  assert caller.expired(somebody, limits, now: joined + 10) == None
  assert caller.expired(somebody, limits, now: joined + 30)
    == Some(caller.WaitedTooLong)

  // Nobody answered, which an account with no dispatcher does: nothing is
  // known yet, and the first position event says the rest.
  let unknown = cf_callcenter.arriving(joined, None)
  assert unknown == caller.new(joined)
  assert caller.expired(unknown, limits, now: joined + 10) == None
}

//
// --- The offer and the hold ------------------------------------------------
//
// The dispatcher's offer bridges the agents' phones from the caller's own
// channel, interrupting the hold; the action never interrupts in return, so
// its holds queue behind a ringing bridge and run if the ring comes to
// nothing. These are the action's half: what it sends after each of the
// channel's events, in both orders the two commands can land in.
//

const greeting = "queue-welcome"

fn answered() -> doc.Value {
  an_event("CHANNEL_ANSWER", [])
}

/// The switch has finished the greeting or an announcement.
fn play_over() -> doc.Value {
  an_event("CHANNEL_EXECUTE_COMPLETE", [
    #("Application-Name", doc.String("noop")),
  ])
}

/// The offer's bridge on the caller's channel came to nothing.
fn offer_over() -> doc.Value {
  an_event("CHANNEL_EXECUTE_COMPLETE", [
    #("Application-Name", doc.String("bridge")),
    #("Application-Response", doc.String("NO_ANSWER")),
  ])
}

/// What the media does for a script of events: every cue in order, and
/// where it ends up.
fn cued(
  media: cf_callcenter.Media,
  script: List(#(Int, doc.Value)),
) -> #(cf_callcenter.Media, List(cf_callcenter.Cue)) {
  cueing(media, script, [])
}

fn cueing(
  media: cf_callcenter.Media,
  script: List(#(Int, doc.Value)),
  done: List(cf_callcenter.Cue),
) -> #(cf_callcenter.Media, List(cf_callcenter.Cue)) {
  case script {
    [] -> #(media, list.reverse(done))
    [#(at, event), ..rest] -> {
      let #(media, cue) = cf_callcenter.on_event(media, event, at)
      cueing(media, rest, [cue, ..done])
    }
  }
}

/// The hold landed first and the bridge broke it, which is the order that
/// used to fail: the caller was on hold, the offer's bridge interrupted
/// it, and nobody answered. The bridge threw the queue away, so the caller
/// is silent until this puts them back on hold.
pub fn hold_then_bridge_test() {
  assert cued(cf_callcenter.Held, [#(120, offer_over())])
    == #(cf_callcenter.Held, [cf_callcenter.Hold])
}

/// The bridge landed first, while the channel was still being answered. The
/// answer's own event queues the hold behind the ringing bridge, where it
/// waits and runs when the ring comes to nothing; the hold queued at the
/// end of the ring is behind that one and never runs, which is harmless
/// where a caller left in silence is not.
pub fn bridge_then_hold_test() {
  assert cued(cf_callcenter.Answering(since: 100, greeting: None), [
      #(100, answered()),
      #(112, offer_over()),
    ])
    == #(cf_callcenter.Held, [cf_callcenter.Hold, cf_callcenter.Hold])
}

/// The bridge cut the greeting short. The greeting's end never comes -- the
/// bridge threw it away -- so the end of the ring is what puts the caller
/// on hold, and a late end-of-play is not a second hold.
pub fn the_bridge_cuts_the_greeting_test() {
  assert cued(cf_callcenter.Answering(since: 100, greeting: Some(greeting)), [
      #(100, answered()),
      #(103, offer_over()),
      #(104, play_over()),
    ])
    == #(cf_callcenter.Held, [
      cf_callcenter.PlayGreeting(greeting),
      cf_callcenter.Hold,
      cf_callcenter.Nothing,
    ])
}

/// The bridge came and went before the switch had said the channel was up.
/// Nothing is owed until it does: the answer brings the greeting or the
/// hold with it.
pub fn a_ring_over_before_the_channel_is_up_test() {
  assert cued(cf_callcenter.Answering(since: 100, greeting: None), [
      #(101, offer_over()),
      #(102, answered()),
    ])
    == #(cf_callcenter.Held, [cf_callcenter.Nothing, cf_callcenter.Hold])
}

/// The greeting plays to its end and hold follows it, as it always did; an
/// announcement ends the same way.
pub fn hold_follows_the_greeting_test() {
  assert cued(cf_callcenter.Answering(since: 100, greeting: Some(greeting)), [
      #(100, answered()),
      #(108, play_over()),
    ])
    == #(cf_callcenter.Held, [
      cf_callcenter.PlayGreeting(greeting),
      cf_callcenter.Hold,
    ])
  assert cued(cf_callcenter.Playing(since: 130), [#(140, play_over())])
    == #(cf_callcenter.Held, [cf_callcenter.Hold])
}

/// The end of an offer is the end of a `bridge` on the caller's channel and
/// nothing else: not the greeting's end, not the answer, and not the bridge
/// beginning.
pub fn the_end_of_an_offer_test() {
  assert cf_callcenter.is_offer_over(offer_over())
  assert !cf_callcenter.is_offer_over(play_over())
  assert !cf_callcenter.is_offer_over(
    an_event("CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("answer")),
      #("Channel-Answer-State", doc.String("answered")),
    ]),
  )
  assert !cf_callcenter.is_offer_over(
    an_event("CHANNEL_BRIDGE", [#("Application-Name", doc.String("bridge"))]),
  )
}

/// Missing answer confirmation never starts media; only playback has a fallback.
pub fn only_playback_timeout_ends_in_hold_test() {
  assert cf_callcenter.overdue_cue(
      cf_callcenter.Answering(since: 100, greeting: None),
      104,
    )
    == #(
      cf_callcenter.Answering(since: 100, greeting: None),
      cf_callcenter.Nothing,
    )
  assert cf_callcenter.overdue_cue(
      cf_callcenter.Answering(since: 100, greeting: Some(greeting)),
      105,
    )
    == #(
      cf_callcenter.Answering(since: 100, greeting: Some(greeting)),
      cf_callcenter.Nothing,
    )
  assert cf_callcenter.overdue_cue(cf_callcenter.Playing(since: 100), 160)
    == #(cf_callcenter.Held, cf_callcenter.Hold)
  assert cf_callcenter.overdue_cue(cf_callcenter.Held, 10_000)
    == #(cf_callcenter.Held, cf_callcenter.Nothing)
}

/// How long the dispatcher's offer can still be ringing: the ring timeout
/// it said, and the same grace the dispatcher gives the offer itself.
pub fn how_long_an_offer_can_ring_test() {
  let offer =
    doc.object([
      #("Event-Category", doc.String("callcenter")),
      #("Event-Name", doc.String("member_offer")),
      #("Agent-IDs", doc.List([doc.String("agent-a")])),
      #("Offer-Timeout", doc.Int(15)),
    ])
  assert cf_callcenter.offer_ceiling(offer, 1000) == 1020
  assert cf_callcenter.offer_ceiling(doc.object([]), 1000) == 1005
}

//
// --- The announcement ------------------------------------------------------
//

/// A queue that says where the caller is, and nothing else.
fn position_only() -> announce.Settings {
  announce.Settings(
    media: None,
    interval_s: 30,
    position: True,
    prompts: announce.prompts(doc.object([])),
  )
}

fn the_announcement() -> List(call.MacroItem) {
  announce.items(position_only(), Some(3), "en-us")
}

/// On hold, the announcement is played in place of the hold and the media
/// is playing until its end. Anywhere else nothing is said: the interval is
/// spent, which `speak` decides, and the caller goes on hearing what they
/// were hearing.
pub fn an_announcement_interrupts_the_hold_and_nothing_else_test() {
  assert cf_callcenter.announcement_cue(
      cf_callcenter.Held,
      position_only(),
      Some(3),
      "en-us",
      130,
    )
    == #(
      cf_callcenter.Playing(since: 130),
      cf_callcenter.Announce(the_announcement()),
    )
  assert cf_callcenter.announcement_cue(
      cf_callcenter.Playing(since: 120),
      position_only(),
      Some(3),
      "en-us",
      130,
    )
    == #(cf_callcenter.Playing(since: 120), cf_callcenter.Nothing)
  assert cf_callcenter.announcement_cue(
      cf_callcenter.Answering(since: 129, greeting: None),
      position_only(),
      Some(3),
      "en-us",
      130,
    )
    == #(
      cf_callcenter.Answering(since: 129, greeting: None),
      cf_callcenter.Nothing,
    )
}

/// A queue with nothing to say leaves the caller on hold rather than
/// interrupting it with silence.
pub fn nothing_to_announce_leaves_the_hold_alone_test() {
  assert cf_callcenter.announcement_cue(
      cf_callcenter.Held,
      position_only(),
      None,
      "en-us",
      130,
    )
    == #(cf_callcenter.Held, cf_callcenter.Nothing)
}

/// The announcement plays to its end and hold follows it.
pub fn hold_follows_the_announcement_test() {
  let #(media, _cue) =
    cf_callcenter.announcement_cue(
      cf_callcenter.Held,
      position_only(),
      Some(3),
      "en-us",
      130,
    )
  assert cued(media, [#(138, play_over())])
    == #(cf_callcenter.Held, [cf_callcenter.Hold])
}

/// The offer's bridge cut the announcement short. Its end never comes, so
/// the end of the ring is what puts the caller back on hold, and a late
/// end-of-play is not a second hold. The next announcement falls due at
/// once, which `caller` decides.
pub fn the_bridge_cuts_the_announcement_test() {
  let #(media, _cue) =
    cf_callcenter.announcement_cue(
      cf_callcenter.Held,
      position_only(),
      Some(3),
      "en-us",
      130,
    )
  assert cued(media, [#(145, offer_over()), #(146, play_over())])
    == #(cf_callcenter.Held, [cf_callcenter.Hold, cf_callcenter.Nothing])
}
