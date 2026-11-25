//// One pass over an account: every caller who is not already being
//// offered, in the account's one order, the strategy of their own queue
//// asked for whom to ring, and the offer sent.
////
//// Run after every message the dispatcher takes, because every message is
//// something that could have changed the answer.
////
//// The account is read once a pass and not once a caller: the queues'
//// settings, the order, and the agents (`view.snapshot`). The decisions are
//// `callcenter/dispatcher/plan`'s, made from that reading; this module sends
//// them, one at a time, and tells the plan what each one sent.

import callcenter/dispatcher/offers
import callcenter/dispatcher/plan
import callcenter/dispatcher/position
import callcenter/dispatcher/settings.{type QueueSettings}
import callcenter/dispatcher/state.{type State, type Wait}
import callcenter/dispatcher/timers
import callcenter/dispatcher/view
import callcenter/dispatcher/waiting
import callcenter/dispatcher/worked
import gleam/dict.{type Dict}
import gleam/list

/// Look at every caller waiting, offer whoever can be offered, and publish
/// what moved. Run after anything that could have changed the answer, which
/// is every message this actor takes.
///
/// The callers are taken in the account's order and not queue by queue: an
/// agent in two queues goes to whichever of their callers is first in it,
/// so a steady stream into one queue cannot keep the other's callers
/// waiting. Each caller is offered against their own queue's tiers, rules
/// and strategy.
pub fn run(state: State) -> State {
  let #(state, reading) = read(state)
  let #(state, snapshot) = case
    view.believed(state) && plan.anybody(reading.snapshot)
  {
    True -> offer_all(state, reading.snapshot, reading.order)
    // Nobody is offered yet, or nobody could be, and the callers wait: the
    // tick that anybody waiting keeps going looks again in a second.
    False -> #(state, reading.snapshot)
  }
  announce_all(state, snapshot, reading)
}

/// The offers a pass would make now, with nothing sent: every offer taken
/// as started, for a test or a profile to look at the decision on its own.
pub fn preview(state: State) -> List(plan.Planned) {
  let #(state, reading) = read(state)
  case view.believed(state) {
    False -> []
    True ->
      reading.order
      |> list.filter(fn(wait) {
        !dict.has_key(state.offers, wait.member.call_id)
      })
      |> plan.plan(reading.snapshot, _)
  }
}

/// What a pass reads, once.
type Reading {
  Reading(
    now: Int,
    /// Every queue with somebody waiting, and its settings.
    queues: List(#(String, QueueSettings)),
    /// Every caller, in the account's order.
    order: List(Wait),
    /// Queue id to its callers' call ids, in the same order.
    in_queue: Dict(String, List(String)),
    snapshot: plan.Snapshot,
  )
}

fn read(state: State) -> #(State, Reading) {
  let now = state.config.now()
  let state = view.read_activity(state)
  // A queue that has been deleted is found here as well as by the notice of
  // its deletion, because a notice is a broker message and can be lost: its
  // callers leave it (`offers.queue_deleted`), and it is neither offered from
  // nor announced. A caller whose ring is being called off stays until the
  // ring is over, with an offer, so the pass leaves them alone.
  let #(deleted, queues) =
    waiting.queues(state)
    |> list.map(fn(queue_id) {
      #(queue_id, settings.for_queue(state.config, queue_id))
    })
    |> list.partition(fn(queue) {
      let #(_queue_id, settings) = queue
      settings.deleted
    })
  let state =
    list.fold(deleted, state, fn(state, queue) {
      offers.queue_deleted(state, queue.0)
    })
  let by_id = dict.from_list(queues)
  let order =
    waiting.account(state, fn(queue_id) {
      case dict.get(by_id, queue_id) {
        Ok(settings) -> settings.time_base_system
        Error(Nil) -> True
      }
    })
  let in_queue = by_queue(order)
  let #(state, snapshot) =
    view.snapshot(state, list.map(queues, fn(queue) { queue.1 }), now)
  #(
    state,
    Reading(
      now: now,
      queues: queues,
      order: order,
      in_queue: in_queue,
      snapshot: snapshot,
    ),
  )
}

/// Every caller without an offer, in the account's order, offered what the
/// plan says: each offer is sent before the next caller is decided, because
/// one that could not be started leaves its agents for the next. A caller
/// handed over whose actor has not yet said where they stand is not
/// offered: their phones may be ringing already (`arrival.present`).
fn offer_all(
  state: State,
  snapshot: plan.Snapshot,
  order: List(Wait),
) -> #(State, plan.Snapshot) {
  list.fold(order, #(state, snapshot), fn(acc, wait) {
    let #(state, snapshot) = acc
    let call_id = wait.member.call_id
    let presenting = case dict.get(state.presenting, call_id) {
      Ok(until) -> until > snapshot.now
      Error(Nil) -> False
    }
    case dict.has_key(state.offers, call_id) || presenting {
      True -> acc
      False ->
        case plan.decide(snapshot, wait) {
          Error(Nil) -> acc
          Ok(planned) -> {
            let state =
              offers.send(
                state,
                planned.wait,
                planned.settings,
                planned.offer,
                snapshot.now,
              )
            case dict.get(state.offers, call_id) {
              // Being rung is the end of an agent's idle, answered or not:
              // an agent whose phone rings out is not still the one who has
              // waited longest.
              Ok(sent) -> #(
                worked.offered(state, sent.agents, snapshot.now),
                plan.commit(snapshot, wait.member.queue_id, sent.agents),
              )
              Error(Nil) -> #(state, snapshot)
            }
          }
        }
    }
  })
}

/// Positions and queue stats for every queue with somebody in it, queue
/// stats for every queue the last caller has left, and the next tick.
fn announce_all(
  state: State,
  snapshot: plan.Snapshot,
  reading: Reading,
) -> State {
  list.fold(reading.queues, state, fn(state, queue) {
    let #(queue_id, settings) = queue
    // The queue as the snapshot read it, which says whether an agent of it
    // could not be read (`settings.agents_unread`).
    let settings = case dict.get(snapshot.queues, queue_id) {
      Ok(read) -> read.settings
      Error(Nil) -> settings
    }
    position.announce(
      state,
      settings,
      callers(reading.in_queue, queue_id),
      plan.available(snapshot, queue_id),
      reading.now,
    )
  })
  |> position.emptied(
    list.map(reading.queues, fn(queue) { queue.0 }),
    reading.now,
  )
  |> timers.schedule
}

/// Queue id to the call ids of its callers, each queue in the account's
/// order, which is the queue's own: `waiting.in_queue` without sorting each
/// queue again.
fn by_queue(order: List(Wait)) -> Dict(String, List(String)) {
  list.fold(list.reverse(order), dict.new(), fn(queues, wait) {
    let queued = callers(queues, wait.member.queue_id)
    dict.insert(queues, wait.member.queue_id, [wait.member.call_id, ..queued])
  })
}

fn callers(
  in_queue: Dict(String, List(String)),
  queue_id: String,
) -> List(String) {
  case dict.get(in_queue, queue_id) {
    Ok(call_ids) -> call_ids
    Error(Nil) -> []
  }
}
