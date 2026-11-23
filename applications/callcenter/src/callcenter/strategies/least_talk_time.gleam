//// Offer the caller to whoever has spent least time on queue calls this
//// login.
////
//// The same even share as fewest calls, measured in seconds instead of
//// calls, which is the fairer of the two wherever the calls are not all the
//// same length: an agent who took one half-hour case has done more of the
//// shift than one who took six enquiries, and counting calls would send them
//// the next five. The counter is `counters.talk_time_s` on the agent's
//// `callcenter_agent` document, added to as each call ends and reset at
//// login, so it is the same number on whichever node dispatches. The
//// document lags the call a little, so the dispatcher shows the larger of it
//// and its own count of the seconds on calls it ended for the agent this
//// login (`dispatcher/worked`): the call that ended a moment ago counts at
//// once.
////
//// Level comes first: the least talk time of the lowest level that has
//// anybody free, and only then the level above. Ties -- two agents fresh
//// from logging in, both on nothing -- fall back to position, so the
//// supervisor's order decides what the counters cannot.

import callcenter/strategies/tier_order
import callcenter/types.{
  type AgentView, type Choice, type Offer, type OfferResult, Sequential,
}
import gleam/int
import gleam/list
import gleam/order
import kazoo/doc.{type Value}

pub const name = "least_talk_time"

/// Lowest level first, then least talk time, offered one after another.
pub fn candidates(choice: Choice, _now: Int) -> Offer {
  choice.selectable
  |> list.sort(by_talk_time)
  |> list.map(fn(view: AgentView) { view.agent_id })
  |> Sequential
}

/// Nothing is remembered between callers: the counter on the agent's
/// document is the whole of this strategy's state, and the dispatcher writes
/// it as each call ends.
pub fn on_result(
  memo: Value,
  _agent_id: String,
  _result: OfferResult,
) -> Value {
  memo
}

fn by_talk_time(a: AgentView, b: AgentView) -> order.Order {
  tier_order.by_level_then(a, b, fn(a: AgentView, b: AgentView) {
    int.compare(a.talk_time_s, b.talk_time_s)
  })
}
