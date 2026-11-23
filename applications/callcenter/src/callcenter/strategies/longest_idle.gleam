//// Offer the caller to the agent who has been free to take one longest, one
//// at a time.
////
//// Free since is `AgentView.free_since`: the latest of their last offer,
//// answered or not; the end of their last queue call, or of its wrap-up;
//// and their login or return from a break. So an agent fresh from logging
//// in is idle from the login rather than for ever, a break is not idle, and
//// an agent whose phone has just rung out goes to the back rather than
//// staying first and costing every caller a full ring timeout. The
//// dispatcher works it out from what it saw itself and from the agent's
//// document (`callcenter/dispatcher/worked`), so a call that ended a moment
//// ago counts before the document says so, and a node that has just taken
//// the account over still has the document's `last_call_end` and the
//// availability's timestamp to go on.
////
//// Level comes first: the longest idle of the lowest level that has anybody
//// free, and only then the level above. Ties -- two agents who logged in in
//// the same second -- fall back to position, so the order is the one the
//// supervisor set rather than whatever the view happened to return. This is the platform's default
//// strategy and acdc's `most_idle` under a clearer name.

import callcenter/strategies/tier_order
import callcenter/types.{
  type AgentView, type Choice, type Offer, type OfferResult, Sequential,
}
import gleam/int
import gleam/list
import gleam/order
import kazoo/doc.{type Value}

pub const name = "longest_idle"

/// Lowest level first, then longest idle, offered one after another.
pub fn candidates(choice: Choice, _now: Int) -> Offer {
  choice.selectable
  |> list.sort(by_idle)
  |> list.map(fn(view: AgentView) { view.agent_id })
  |> Sequential
}

/// Nothing is remembered between callers here: the dispatcher keeps when
/// each agent became free, and hands it over in the view.
pub fn on_result(
  memo: Value,
  _agent_id: String,
  _result: OfferResult,
) -> Value {
  memo
}

fn by_idle(a: AgentView, b: AgentView) -> order.Order {
  tier_order.by_level_then(a, b, fn(a: AgentView, b: AgentView) {
    int.compare(a.free_since, b.free_since)
  })
}
