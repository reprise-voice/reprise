//// The order the supervisor put a queue's agents in.
////
//// Level, then position, then the agent id. Every strategy falls back to it
//// -- for the agents it cannot tell apart, or, in ring-all's case, for all of
//// them -- so it is one module rather than a copy in each: two copies that
//// disagree are two queues that ring in different orders for no reason a
//// supervisor could see.
////
//// Level is more than a tie-break. Every ordered strategy sorts on it first
//// and only then on its own measure (`by_level_then`), so a level 1 agent
//// who could take the caller is always offered before a level 2 one, whether
//// or not the queue's `tier_rules` hold the higher levels back: without that,
//// level would mean nothing to any strategy but `sequential`.
////
//// The agent id is the last key so that the order is total. Two agents at the
//// same level and position are a queue somebody built by hand, and an order
//// that depends on whichever row the view returned first would make the same
//// queue ring differently on two nodes.

import callcenter/types.{type AgentView}
import gleam/int
import gleam/list
import gleam/order
import gleam/string

/// Level, then position, then agent id.
pub fn by_tier(a: AgentView, b: AgentView) -> order.Order {
  case int.compare(a.level, b.level) {
    order.Eq ->
      case int.compare(a.position, b.position) {
        order.Eq -> string.compare(a.agent_id, b.agent_id)
        other -> other
      }
    other -> other
  }
}

/// Level, then the strategy's own measure, then position and agent id.
pub fn by_level_then(
  a: AgentView,
  b: AgentView,
  measure: fn(AgentView, AgentView) -> order.Order,
) -> order.Order {
  int.compare(a.level, b.level)
  |> order.lazy_break_tie(fn() { measure(a, b) })
  |> order.lazy_break_tie(fn() { by_tier(a, b) })
}

/// The views in that order.
pub fn sorted(views: List(AgentView)) -> List(AgentView) {
  list.sort(views, by_tier)
}

/// The views in that order, one list per level, lowest level first.
pub fn by_level(views: List(AgentView)) -> List(List(AgentView)) {
  sorted(views)
  |> list.chunk(fn(view: AgentView) { view.level })
}
