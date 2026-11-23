//// Offer the caller to whoever has answered fewest queue calls this login.
////
//// The counter is `counters.answered` on the agent's `callcenter_agent`
//// document and it is reset at login, so this is an even share across a
//// shift rather than a lifetime ranking: an agent starting at noon does not
//// spend the afternoon catching up with one who has been on since eight.
//// Reading it from the document rather than keeping a tally here is also
//// what makes the order the same on whichever node dispatches, and what
//// makes it survive losing one. The document lags the call a little, so the
//// dispatcher shows the larger of it and its own count of the calls it
//// connected for the agent this login (`dispatcher/worked`): the call
//// answered a moment ago counts at once.
////
//// Level comes first: the fewest calls of the lowest level that has anybody
//// free, and only then the level above. Every agent begins a login on
//// nothing, so most of the early decisions are ties; they fall back to
//// position, which means a fresh queue rings in the order the supervisor set
//// rather than in whatever order the view happened to return.

import callcenter/strategies/tier_order
import callcenter/types.{
  type AgentView, type Choice, type Offer, type OfferResult, Sequential,
}
import gleam/int
import gleam/list
import gleam/order
import kazoo/doc.{type Value}

pub const name = "fewest_calls"

/// Lowest level first, then fewest answered, offered one after another.
pub fn candidates(choice: Choice, _now: Int) -> Offer {
  choice.selectable
  |> list.sort(by_answered)
  |> list.map(fn(view: AgentView) { view.agent_id })
  |> Sequential
}

/// Nothing is remembered between callers: the counter on the agent's
/// document is the whole of this strategy's state, and the dispatcher writes
/// it as each call is answered.
pub fn on_result(
  memo: Value,
  _agent_id: String,
  _result: OfferResult,
) -> Value {
  memo
}

fn by_answered(a: AgentView, b: AgentView) -> order.Order {
  tier_order.by_level_then(a, b, fn(a: AgentView, b: AgentView) {
    int.compare(a.answered, b.answered)
  })
}
