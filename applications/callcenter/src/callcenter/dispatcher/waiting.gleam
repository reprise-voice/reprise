//// Who is waiting, and in what order they are offered.
////
//// One order for the whole account, not one per queue: an agent in two
//// queues is one agent, and the caller who has waited longest for them is
//// the one they take next, whichever queue that caller is in. Priority
//// first, then age -- each caller's age counted the way their own queue's
//// `time_base_score` says -- then the queue id and the call id, so that the
//// order is total and the same on every node. This is the one place the
//// order is decided; a queue's own list is this order with the other queues
//// left out.

import callcenter/dispatcher/settings.{type QueueSettings}
import callcenter/dispatcher/state.{type State, type Wait}
import callcenter/member as member_message
import callcenter/types.{type Member}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/order
import gleam/string

/// The queues with somebody waiting, in a stable order.
pub fn queues(state: State) -> List(String) {
  dict.values(state.waiting)
  |> list.map(fn(wait) { wait.member.queue_id })
  |> list.unique
  |> list.sort(string.compare)
}

/// Every caller of the account, in the order they are offered.
///
/// `system_base` answers, for a queue id, whether that queue counts a
/// caller's age from when they entered the system: see `score_base`.
pub fn account(state: State, system_base: fn(String) -> Bool) -> List(Wait) {
  order(dict.values(state.waiting), system_base)
}

/// The callers of one queue, in the order they will be offered: the account
/// order with everybody else left out.
pub fn in_queue(
  state: State,
  queue_id: String,
  settings: QueueSettings,
) -> List(Wait) {
  dict.values(state.waiting)
  |> list.filter(fn(wait) { wait.member.queue_id == queue_id })
  |> order(fn(_queue_id) { settings.time_base_system })
}

/// Callers in the order they are offered: priority, highest first; then
/// age, oldest first, each counted from the base their own queue names; then
/// queue id and call id, so that two callers who arrived in the same second
/// are always in the same order.
///
/// Priority is compared across queues as it stands. A queue whose callers
/// should go ahead of another's gives them a higher priority, in the
/// action's data or on the channel.
pub fn order(waits: List(Wait), system_base: fn(String) -> Bool) -> List(Wait) {
  waits
  |> list.map(fn(wait) {
    #(score_base(wait.member, system_base(wait.member.queue_id)), wait)
  })
  |> list.sort(fn(left, right) {
    let #(left_base, a) = left
    let #(right_base, b) = right
    int.compare(b.member.priority, a.member.priority)
    |> order.lazy_break_tie(fn() { int.compare(left_base, right_base) })
    |> order.lazy_break_tie(fn() {
      string.compare(a.member.queue_id, b.member.queue_id)
    })
    |> order.lazy_break_tie(fn() {
      string.compare(a.member.call_id, b.member.call_id)
    })
  })
  |> list.map(fn(scored) { scored.1 })
}

/// When a caller's age counts from.
///
/// `queue` is when they joined this queue. `system`, the default, is when
/// they first entered any queue on this channel: the `Queue-System-Joined`
/// channel variable the callflow action sets the first time and keeps after
/// that (`callcenter/member.system_joined`), so a caller moved to an overflow
/// queue, transferred to another, or whose callflow was run again keeps
/// their place. A channel that was never stamped -- a caller put in the
/// queue by a node of an older release -- counts from when they joined this
/// queue, and so does one whose stamp is somehow later than that.
pub fn score_base(member: Member, system_time_base: Bool) -> Int {
  case system_time_base, member_message.system_joined(member.call) {
    True, Some(entered) -> int.min(entered, member.joined)
    _queue, _unstamped -> member.joined
  }
}
