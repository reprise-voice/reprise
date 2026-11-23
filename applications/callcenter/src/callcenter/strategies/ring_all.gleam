//// Ring every agent who could take the caller, at once.
////
//// One bridge with every endpoint on it rather than one offer each: the
//// platform cancels the losers when the first one answers, which is both
//// fewer moving parts than racing offers and the only version where two
//// agents cannot both answer.
////
//// The order still matters even though they all ring together, because it
//// is the order the endpoints go on the bridge in and therefore the order
//// the switch dials them: level, then position, which is the order a
//// supervisor put them in.

import callcenter/strategies/tier_order
import callcenter/types.{
  type AgentView, type Choice, type Offer, type OfferResult, Simultaneous,
}
import gleam/list
import kazoo/doc.{type Value}

pub const name = "ring_all"

/// Everyone, together.
pub fn candidates(choice: Choice, _now: Int) -> Offer {
  choice.selectable
  |> tier_order.sorted
  |> list.map(fn(view: AgentView) { view.agent_id })
  |> Simultaneous
}

/// Ring-all keeps nothing between callers: every decision is made from the
/// agents that are free at that moment.
pub fn on_result(
  memo: Value,
  _agent_id: String,
  _result: OfferResult,
) -> Value {
  memo
}
