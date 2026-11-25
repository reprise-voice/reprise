//// The account's one order of waiting callers, as a pure function.

import callcenter/dispatcher/state.{type Wait, Wait}
import callcenter/dispatcher/waiting
import gleam/list
import support/cluster

fn wait(call_id: String, queue_id: String, priority: Int, joined: Int) -> Wait {
  Wait(
    member: cluster.member(call_id, queue_id, priority, joined),
    position: 0,
    announced_at: 0,
    tried: [],
  )
}

fn ids(waits: List(Wait)) -> List(String) {
  list.map(waits, fn(wait) { wait.member.call_id })
}

fn system(_queue_id: String) -> Bool {
  True
}

/// Two queues sharing an agent: the caller who has waited six minutes in
/// the queue whose id sorts last goes before the one who has waited a
/// second in the queue whose id sorts first. Queue ids are not an order.
pub fn age_beats_the_queue_id_test() {
  let order =
    waiting.order(
      [wait("fresh", "aaa-sales", 0, 359), wait("patient", "zzz-support", 0, 0)],
      system,
    )
  assert ids(order) == ["patient", "fresh"]
}

/// Priority first, across queues: the higher priority goes first however
/// long the other has waited.
pub fn priority_beats_age_across_queues_test() {
  let order =
    waiting.order(
      [
        wait("old", "aaa-sales", 0, 0),
        wait("vip", "zzz-support", 5, 300),
        wait("older", "zzz-support", 0, -60),
      ],
      system,
    )
  assert ids(order) == ["vip", "older", "old"]
}

/// Callers of different queues who arrived in the same second are ordered by
/// queue id and then call id, so the order is the same on every node and in
/// every pass.
pub fn ties_are_broken_by_queue_then_call_test() {
  let order =
    waiting.order(
      [
        wait("b-call", "zzz-support", 0, 10),
        wait("z-call", "aaa-sales", 0, 10),
        wait("a-call", "zzz-support", 0, 10),
      ],
      system,
    )
  assert ids(order) == ["z-call", "a-call", "b-call"]
}

/// Each caller's age is counted from the base of their own queue: a queue on
/// `time_base_score: queue` counts from when the caller joined it even if
/// the other queue counts from the system.
pub fn each_caller_uses_their_own_queues_time_base_test() {
  let transferred =
    wait("transferred", "queue-base", 0, 100)
    |> with_system_joined(1)
  let waiting_since_50 = wait("since-50", "system-base", 0, 50)
  let order =
    waiting.order([transferred, waiting_since_50], fn(queue_id) {
      queue_id == "system-base"
    })
  // `transferred` entered the system at 1 but their queue counts from 100.
  assert ids(order) == ["since-50", "transferred"]

  let order = waiting.order([transferred, waiting_since_50], system)
  assert ids(order) == ["transferred", "since-50"]
}

fn with_system_joined(wait: Wait, at: Int) -> Wait {
  Wait(
    ..wait,
    member: cluster.with_call_var(wait.member, "Queue-System-Joined", at),
  )
}
