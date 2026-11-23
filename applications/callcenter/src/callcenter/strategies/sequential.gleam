//// Start at the top of the tier order for every caller.
////
//// The supervisor's order is the whole of it: level, then position, and
//// nothing kept between callers. The agent at the top takes every caller
//// while they are free, and the ones below them are the overflow -- which is
//// what a queue with a senior agent and a backstop behind them is for, and
//// exactly what round robin is not.
////
//// A pass reaches the second agent because the first is no longer
//// selectable, not because this module skipped them: a miss puts that agent
//// in the queue's delayed set, so the next pass sorts the same list and the
//// top of it is now the next one down. That is why "from the top every time"
//// and "one after another down the list" are one strategy here, and why
//// mod_callcenter's `top-down` and `sequentially-by-agent-order` are one
//// name.

import callcenter/strategies/tier_order
import callcenter/types.{
  type AgentView, type Choice, type Offer, type OfferResult, Sequential,
}
import gleam/list
import kazoo/doc.{type Value}

pub const name = "sequential"

/// The tier order, top first.
pub fn candidates(choice: Choice, _now: Int) -> Offer {
  choice.selectable
  |> tier_order.sorted
  |> list.map(fn(view: AgentView) { view.agent_id })
  |> Sequential
}

/// Nothing is remembered: the point of this strategy is that every caller
/// starts where the last one did.
pub fn on_result(
  memo: Value,
  _agent_id: String,
  _result: OfferResult,
) -> Value {
  memo
}
