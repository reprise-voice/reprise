//// A supervisor's pickup moves no agent state (`dispatcher/pickup`): what the
//// functions that end or look at an offer do to the dispatcher's memory of
//// a supervisor who is also an agent, taken one at a time.

import callcenter/dispatcher/offers
import callcenter/dispatcher/state.{type State, Offer, State}
import callcenter/dispatcher/worked
import callcenter/types.{ExitKey}
import gleam/dict
import gleam/option.{Some}
import support/bare_state
import support/cluster

/// The offer gone, and nothing of it left: what a pickup's end leaves.
fn gone(state: State, call_id: String) -> State {
  State(
    ..state,
    offers: dict.delete(state.offers, call_id),
    pickups: dict.delete(state.pickups, call_id),
    busy: dict.new(),
  )
}

/// A caller who leaves while the pickup rings is given up on with no turn
/// remembered for the supervisor: the queue's strategy hears nothing. An
/// agent's ring given up the same way is the strategy's to hear of.
pub fn a_caller_leaving_a_pickup_tells_no_strategy_test() {
  let ring = bare_state.offer("call-one", ["bob"])
  let caller = bare_state.new() |> bare_state.waiting("call-one")

  let left =
    caller
    |> bare_state.picked_up(ring)
    |> offers.leave("call-one", ExitKey)
  assert left.memo == dict.new()
  assert left.offers == dict.new()
  assert state.offer_of(left, "bob") == Error(Nil)

  let left =
    caller
    |> bare_state.held(ring)
    |> offers.leave("call-one", ExitKey)
  assert dict.size(left.memo) == 1
}

/// Neither a pickup's ring nor its call moves the supervisor's idle time or
/// counts, however it ends; an agent's ring and call do.
pub fn a_pickup_moves_no_idle_time_or_talk_time_test() {
  let ring = bare_state.offer("call-one", ["bob"])
  let call =
    Offer(
      ..ring,
      connected: Some(#("bob", "bob-leg", cluster.start_of_time - 60)),
    )

  let before = bare_state.new() |> bare_state.picked_up(ring)
  assert worked.observe(before, gone(before, "call-one")).worked == dict.new()
  let before = bare_state.new() |> bare_state.picked_up(call)
  assert worked.observe(before, gone(before, "call-one")).worked == dict.new()

  let before = bare_state.new() |> bare_state.held(ring)
  let seen = worked.observe(before, gone(before, "call-one"))
  assert worked.of(seen, "bob").free_since == cluster.start_of_time
  let before = bare_state.new() |> bare_state.held(call)
  let seen = worked.observe(before, gone(before, "call-one"))
  assert worked.of(seen, "bob").talk_time_s == 60
}
