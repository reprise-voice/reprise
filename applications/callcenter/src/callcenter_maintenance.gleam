//// `sup callcenter_maintenance ...`
////
//// `sup` calls a module by its literal name with binary arguments, and a
//// Gleam module at the top of `src` compiles to exactly its own name, so
//// these are the operator commands and there is no Erlang wrapper between
//// them and the work.
////
//// Each one prints its report and answers `no_return`, which is what stops
//// `sup` printing the return value underneath it.

import callcenter/activity
import callcenter/agent_state
import callcenter/agents
import callcenter/ask
import callcenter/availability
import callcenter/dispatcher
import callcenter/member
import callcenter/placement
import callcenter/reconcile
import callcenter/records
import callcenter/shard
import callcenter/shards
import callcenter/status
import callcenter/system
import callcenter/types
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/kazoo
import kazoo/modb

/// What `sup` reads as "printed already".
pub type Done

@external(erlang, "callcenter_ffi", "no_return")
fn done() -> Done

//
// --- status ----------------------------------------------------------------
//

/// Which shards this node is dispatching for, and what each is holding.
///
/// This node's answer only. A shard missing here is held by another node, or
/// by nobody; `rabbitmqctl list_consumers` is the cluster-wide view.
pub fn status() -> Done {
  let kz = system.live()
  let count = shards.count(kz)
  let held =
    shards.all(count)
    |> list.filter_map(fn(shard_id) {
      case shard.held(shard_id) {
        Some(held) -> Ok(held)
        None -> Error(Nil)
      }
    })
  let members =
    list.fold(held, 0, fn(total, held) { total + list.length(held.call_ids) })

  report([
    "node: " <> system.node_name(),
    "shards configured: " <> int.to_string(count),
    "shard count: "
      <> case shards.known_agreement(count) {
      shards.Agreed -> "the cluster's, as " <> shards.marker_queue <> " holds"
      shards.Disagreed(reason) -> "NOT the cluster's: " <> reason
      shards.Unknown -> "not yet agreed with the broker"
    },
    "shards held here: " <> int.to_string(list.length(held)),
    ..list.append(placement_lines(count), [
      "members held here: " <> int.to_string(members),
      "dispatchers here: " <> int.to_string(reconcile.count(count)),
      ..list.append(
        list.flat_map(snapshots(count), dispatcher_lines),
        list.map(held, fn(held) {
          "  shard "
          <> int.to_string(held.shard)
          <> " ("
          <> held.queue
          <> "): "
          <> case held.call_ids {
            [] -> "no members"
            call_ids -> string.join(call_ids, ", ")
          }
        }),
      )
    ])
  ])
}

/// Who this node counts as members, and how many shards they assign it.
fn placement_lines(count: Int) -> List(String) {
  case placement.seen() {
    None -> [
      "cluster members: not known: the placement is not running here, or"
      <> " did not answer",
    ]
    Some(seen) -> [
      "cluster members: "
        <> case seen.members {
        [] -> "none seen yet"
        members -> string.join(members, ", ")
      },
      "assigned here: "
        <> int.to_string(list.length(seen.assigned))
        <> " of "
        <> int.to_string(count),
    ]
  }
}

/// Every dispatcher this node is running, newest information first.
fn snapshots(count: Int) -> List(dispatcher.Snapshot) {
  shards.all(count)
  |> list.filter(shard.holds)
  |> list.flat_map(shard.dispatchers)
  // One that stopped between the listing and the asking has nothing to
  // report: its account went quiet.
  |> list.filter_map(fn(entry) {
    ask.call(entry.1, 5000, dispatcher.Report) |> result.replace_error(Nil)
  })
}

fn dispatcher_lines(snapshot: dispatcher.Snapshot) -> List(String) {
  [
    "  account " <> snapshot.account_id,
    ..list.append(
      list.append(
        list.map(snapshot.queues, fn(queue) {
          "    queue "
          <> queue.0
          <> ": "
          <> int.to_string(queue.1)
          <> " waiting"
        }),
        list.map(snapshot.waiting, fn(waiting) {
          "    caller "
          <> waiting.0
          <> " in "
          <> waiting.1
          <> " for "
          <> int.to_string(waiting.2)
          <> "s"
        }),
      ),
      list.append(
        list.map(snapshot.offers, fn(offer) {
          "    offering " <> offer.0 <> " to " <> string.join(offer.1, ", ")
        }),
        list.map(snapshot.agents, fn(agent) {
          "    agent " <> agent.0 <> ": " <> agent.1 <> ", " <> agent.2
        }),
      ),
    )
  ]
}

//
// --- agents ----------------------------------------------------------------
//

/// Every agent of an account, with the availability they chose and the
/// activity this node derives.
///
/// Availability comes from the documents and is the same on every node.
/// Activity is this node's own view, which is only complete for an account
/// this node is dispatching for; run it on the node `status` shows the
/// account on.
pub fn agents(account_id: String) -> Done {
  let kz = system.live()
  let derived = activity.agents(account_id)
  case availability.all(kz, account_id) {
    Error(reason) ->
      report([
        "could not read the agents of "
        <> account_id
        <> ": "
        <> kazoo_error(reason),
      ])
    Ok([]) -> report(["no agents in account " <> account_id])
    Ok(agents) ->
      report([
        "agents of account " <> account_id,
        ..list.map(agents, fn(entry) {
          let #(agent_id, current) = entry
          "  "
          <> agent_id
          <> ": "
          <> availability.to_string(current.availability)
          <> " ("
          <> availability.source_to_string(current.source)
          <> "), "
          <> case list.key_find(derived, agent_id) {
            Ok(what) -> activity.to_string(what)
            Error(_) -> "idle"
          }
        })
      ])
  }
}

//
// --- set_agent -------------------------------------------------------------
//

/// Set an agent's availability, as a supervisor would.
///
/// `logged_out`, `available`, `available_on_demand` or `on_break`. Every
/// write goes the same way as the phone codes and the API: the document, the
/// status log, the `agent_availability` event and the presence update. And
/// it is refused the same way: anything but `logged_out` for a user who is
/// disabled, deleted or not there is refused and nothing is written.
pub fn set_agent(account_id: String, agent_id: String, to: String) -> Done {
  report(set_agent_lines(system.live(), account_id, agent_id, to))
}

/// What `set_agent` does and prints, against the datastore it is given.
pub fn set_agent_lines(
  kz: kazoo.Kazoo,
  account_id: String,
  agent_id: String,
  to: String,
) -> List(String) {
  let wanted = availability.from_string(to)
  case availability.to_string(wanted) == to {
    False -> [
      to
      <> " is not an availability; one of logged_out, available, "
      <> "available_on_demand, on_break",
    ]
    True ->
      case
        agent_state.change(
          kz,
          account_id,
          agent_id,
          to: wanted,
          source: agent_state.supervisor,
          break_s: 0,
        )
      {
        Error(agent_state.Unfit(unfit)) -> [
          "refused: "
          <> agent_id
          <> " cannot be "
          <> to
          <> ", "
          <> agents.unfit_to_string(unfit)
          <> "; only logged_out is allowed",
        ]
        Error(agent_state.Failed(reason)) -> [
          "could not set " <> agent_id <> ": " <> kazoo_error(reason),
        ]
        Error(agent_state.NotLoggedIn) -> [
          "refused: "
          <> agent_id
          <> " cannot be "
          <> to
          <> ", "
          <> agent_state.refused_to_string(agent_state.NotLoggedIn),
        ]
        Ok(changed) -> [
          agent_id
          <> " is now "
          <> availability.to_string(changed.availability)
          <> " (was "
          <> case changed.previous {
            Some(previous) -> availability.to_string(previous)
            None -> "unknown"
          }
          <> ")",
        ]
      }
  }
}

//
// --- release_agent ---------------------------------------------------------
//

/// Take an agent out of whatever this node's dispatcher believes about them:
/// the offer they are in, the wrap-up they are serving, the delay after a
/// miss. The offer is dropped whole and its process is no longer heard: a
/// caller it was ringing for is offered again, and an answered call is ended.
///
/// The escape hatch requirement 0.7 asks for, for the cases the reconciler
/// misses. It does not change their availability.
pub fn release_agent(account_id: String, agent_id: String) -> Done {
  let count = shards.count(system.live())
  case shard.dispatcher(shards.of_account(account_id, count), account_id) {
    Error(_) ->
      report([
        "account " <> account_id <> " is not dispatched from this node",
      ])
    Ok(to) ->
      case ask.call(to, 5000, dispatcher.ReleaseAgent(agent_id, _)) {
        Ok(True) -> report([agent_id <> " released"])
        Ok(False) ->
          report([
            agent_id <> " was not held by the dispatcher for " <> account_id,
          ])
        Error(failure) ->
          report([
            "the dispatcher for "
            <> account_id
            <> " did not answer: "
            <> ask.describe(failure),
          ])
      }
  }
}

//
// --- release_member --------------------------------------------------------
//

/// Take a caller out of the queue as their cancel would: the account's shard
/// settles their member message and tells the account's dispatcher they
/// left, which drops them, frees whoever was being rung for them and closes
/// their record as a `hangup` (`shard.release`). Only on the node holding
/// the account's shard, which `status` shows.
///
/// The other half of `release_agent`, and the one to reach for when a caller
/// is stuck in a queue after their channel has gone, or a member was left
/// behind by a test or by a cancel that was lost.
pub fn release_member(account_id: String, call_id: String) -> Done {
  let shard_id = shards.of_account(account_id, shards.count(system.live()))
  case shard.holds(shard_id) {
    False ->
      report([
        "account "
        <> account_id
        <> " is not dispatched from this node: shard "
        <> int.to_string(shard_id)
        <> " is held elsewhere, or by nobody",
      ])
    True ->
      case shard.release_member(shard_id, account_id, call_id) {
        True ->
          report([
            call_id
            <> " released: settled on shard "
            <> int.to_string(shard_id)
            <> " and taken out of the queue",
          ])
        False -> report([call_id <> " was not waiting in " <> account_id])
      }
  }
}

//
// --- rebalance -------------------------------------------------------------
//

/// Look at every shard now rather than at the next tick, and say where this
/// node stands.
///
/// The placement looks every few seconds on its own; this is for an operator
/// who would rather not wait. It hands nothing over by itself: a shard moves
/// when the member it is assigned to asks for it.
pub fn rebalance() -> Done {
  placement.look_now()
  case placement.seen() {
    None ->
      report([
        "the placement is not running on this node, or did not answer",
      ])
    Some(seen) ->
      report([
        "assigned here: "
        <> int.to_string(list.length(seen.assigned))
        <> ", held here: "
        <> int.to_string(list.length(seen.held))
        <> ", members: "
        <> string.join(seen.members, ", "),
      ])
  }
}

//
// --- reconcile -------------------------------------------------------------
//

/// Run the sweep now rather than waiting for the timer.
pub fn reconcile() -> Done {
  reconcile.now()
  report(["sweeping every waiting caller on " <> system.node_name()])
}

//
// --- queue_status ----------------------------------------------------------
//

/// Ask the cluster what is happening in an account, whichever node is
/// dispatching for it. An empty queue id is every queue.
pub fn queue_status(account_id: String, queue_id: String) -> Done {
  live_status(account_id, case queue_id {
    "" -> None
    queue_id -> Some(queue_id)
  })
}

fn live_status(account_id: String, queue_id: Option(String)) -> Done {
  case status.ask(account_id, queue_id) {
    [] ->
      report([
        "nothing is dispatching for account " <> account_id,
      ])
    queues ->
      report([
        "account " <> account_id,
        ..list.map(queues, fn(queue) { "  " <> doc.to_string(queue) })
      ])
  }
}

fn kazoo_error(reason: kazoo.Error) -> String {
  kazoo.error_to_string(reason)
}

//
// --- ack_member ------------------------------------------------------------
//

/// `release_member` under its older name.
///
/// It used to settle the member on the shard and stop there: the dispatcher
/// was never told, so the caller went on being offered with no message on
/// the broker behind them, and an answer would have settled a delivery that
/// was already gone. Settling a member and taking the caller out of the
/// queue are one thing, and this is now that thing.
pub fn ack_member(account_id: String, call_id: String) -> Done {
  release_member(account_id, call_id)
}

//
// --- publish_member --------------------------------------------------------
//

/// Publish a test member into the shard the account hashes to.
///
/// The call it carries is the least that is still a call: enough for the
/// shard that receives it to log it, not enough to bridge anything. It is
/// the way to see, from the outside, which node holds a shard and how long a
/// failover takes to move it.
pub fn publish_member(
  account_id: String,
  queue_id: String,
  call_id: String,
) -> Done {
  let kz = system.live()
  let count = shards.count(kz)
  let shard_id = shards.of_account(account_id, count)
  let node = system.node_name()
  let message =
    member.call_message(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      node: node,
      // Gregorian, which is what `Joined-Timestamp` is and what decides the
      // month database the caller's record is written to. `kz.now()` is unix
      // seconds and would put the record in 1970.
      joined_at: modb.now(),
      priority: 0,
      call: member.stub_call(call_id, node),
    )
  publish(shard_id, message, "member", call_id)
}

/// Publish a cancel for a member, which is what settles the delivery the
/// shard is holding for it. The other half of `publish_member`, and the only
/// way to exercise the path a caller hanging up takes.
pub fn cancel_member(account_id: String, call_id: String) -> Done {
  let kz = system.live()
  let count = shards.count(kz)
  let shard_id = shards.of_account(account_id, count)
  let message =
    cancel_member_message(account_id, call_id, system.node_name(), modb.now())
  publish(shard_id, message, "cancel", call_id)
}

/// The cancel `cancel_member` sends: a caller hanging up, which is the path
/// it exercises and a `Reason` `kapi_callcenter` allows. It went out as
/// `maintenance` once, which no definition allows and the shard read as a
/// hang-up anyway.
pub fn cancel_member_message(
  account_id: String,
  call_id: String,
  node: String,
  at: Int,
) -> Value {
  member.cancel_message(
    account_id: account_id,
    queue_id: "",
    call_id: call_id,
    node: node,
    reason: records.reason_to_string(types.Hangup),
    cancelled_at: at,
  )
}

fn publish(
  shard_id: Int,
  message: Value,
  what: String,
  call_id: String,
) -> Done {
  let queue = shards.member_queue(shard_id)
  case amqp.publish_to_queue(queue, message) {
    Ok(Nil) ->
      report([
        "published "
        <> what
        <> " "
        <> call_id
        <> " to "
        <> queue
        <> " (shard "
        <> int.to_string(shard_id)
        <> ")",
      ])
    Error(error) ->
      report([
        what
        <> " "
        <> call_id
        <> " not published to "
        <> queue
        <> ": "
        <> amqp.error_to_string(error),
      ])
  }
}

fn report(lines: List(String)) -> Done {
  io.println(string.join(lines, "\n"))
  done()
}
