//// How a queue picks which agent to offer a caller to.
////
//// The dispatcher owns every state machine and every timer; a strategy owns
//// one decision. It is handed a `Choice` -- its own memo, the agents the tier
//// rules allow for this caller, which of them could take it now, and the time
//// -- and it answers an ordered `Sequential` or a `Simultaneous` set. Each
//// of the six is a module under `strategies/`, two lines here, and an enum
//// value in `queues.json`; a seventh would be the same three things, and
//// nothing in the dispatcher would change.
////
//// The strategy modules themselves import `callcenter/types` and nothing
//// else, so they are pure functions of the view they are given and the
//// registry below is the only place that knows they exist. That is also why
//// exclusions are applied here, in `selectable`, rather than in each of
//// them: whether an agent could take a caller at all is the same question
//// for every strategy, and answering it twice is how the two would drift.
//// Both lists are handed over, because a strategy that keeps a cursor has to
//// move it over agents it cannot ring as well as ones it can. What it offers
//// is always drawn from `selectable`, and the dispatcher counts on that: a
//// queue with nobody selectable is offered nobody without its strategy being
//// asked (`callcenter/dispatcher/plan`).

import callcenter/strategies/fewest_calls
import callcenter/strategies/least_talk_time
import callcenter/strategies/longest_idle
import callcenter/strategies/ring_all
import callcenter/strategies/round_robin
import callcenter/strategies/sequential
import callcenter/system
import callcenter/types.{
  type Activity, type AgentView, type Choice, type Offer, type OfferResult,
  Available, AvailableOnDemand, Choice, Idle, OnCall, Ready,
}
import gleam/list
import kazoo/doc.{type Value}

/// Gregorian seconds, as everything the call center stamps is.
pub type Now =
  Int

/// What a strategy knows about the queue it is choosing for.
///
/// `memo` is the strategy's own state, carried in the dispatcher and given
/// back through `on_result`. Only round robin keeps any, which is why the
/// name of the strategy it belongs to is carried beside it: a queue whose
/// strategy was changed must not carry on from the cursor the old one left.
pub type QueueState {
  QueueState(
    account_id: String,
    queue_id: String,
    /// The strategy whose memo this is. Empty until one has been asked.
    strategy: String,
    /// The queue's `skip_agents_with_external_calls`. Off means an agent on
    /// a call that did not come from a queue may still be offered one.
    skip_external_calls: Bool,
    /// The queue's `ring_simultaneously`.
    ring_simultaneously: Int,
    memo: Value,
  )
}

pub type Strategy {
  Strategy(
    name: String,
    candidates: fn(QueueState, List(AgentView), Now) -> Offer,
    on_result: fn(QueueState, String, OfferResult) -> QueueState,
  )
}

/// The strategy `queues.json` names, or nothing.
pub fn for_name(name: String) -> Result(Strategy, Nil) {
  case name {
    "ring_all" ->
      Ok(wrap(ring_all.name, ring_all.candidates, ring_all.on_result))
    // `most_idle` is the same strategy under acdc's name for it, kept as an
    // alias by the queue schema.
    "longest_idle" | "most_idle" ->
      Ok(wrap(
        longest_idle.name,
        longest_idle.candidates,
        longest_idle.on_result,
      ))
    "round_robin" ->
      Ok(wrap(round_robin.name, round_robin.candidates, round_robin.on_result))
    "sequential" ->
      Ok(wrap(sequential.name, sequential.candidates, sequential.on_result))
    "fewest_calls" ->
      Ok(wrap(
        fewest_calls.name,
        fewest_calls.candidates,
        fewest_calls.on_result,
      ))
    "least_talk_time" ->
      Ok(wrap(
        least_talk_time.name,
        least_talk_time.candidates,
        least_talk_time.on_result,
      ))
    _unknown -> Error(Nil)
  }
}

/// The strategy a queue document names, whatever it says.
///
/// A queue naming a strategy this release does not have, or a name from a
/// newer one, still dispatches: it falls back to the default and says so once
/// per call rather than leaving callers waiting for a strategy that does not
/// exist.
pub fn resolve(name: String) -> Strategy {
  case for_name(name) {
    Ok(strategy) -> strategy
    Error(_) -> {
      system.log_error(
        "queue strategy " <> name <> " is not implemented; using longest_idle",
      )
      let assert Ok(strategy) = for_name("longest_idle")
      strategy
    }
  }
}

/// Every strategy this release has, for `sup` and the API to list.
pub fn names() -> List(String) {
  [
    "ring_all", "longest_idle", "round_robin", "sequential", "fewest_calls",
    "least_talk_time",
  ]
}

fn wrap(
  name: String,
  candidates: fn(Choice, Now) -> Offer,
  on_result: fn(Value, String, OfferResult) -> Value,
) -> Strategy {
  Strategy(
    name: name,
    candidates: fn(state: QueueState, views: List(AgentView), now: Now) {
      candidates(
        Choice(
          memo: state.memo,
          agents: views,
          selectable: selectable(state, views),
        ),
        now,
      )
    },
    on_result: fn(state: QueueState, agent_id: String, result: OfferResult) {
      QueueState(..state, memo: on_result(state.memo, agent_id, result))
    },
  )
}

/// The agents of a candidate list who could take a caller right now.
///
/// Requirement 1.2a, in one place: chosen availability says the agent is
/// working, derived activity says their phones are free, and the tier state
/// says this queue is not already busy with them. `AvailableOnDemand` counts
/// because this is only ever asked while somebody is waiting.
pub fn selectable(
  state: QueueState,
  views: List(AgentView),
) -> List(AgentView) {
  list.filter(views, fn(view) {
    let available = case view.availability {
      Available | AvailableOnDemand -> True
      _ -> False
    }
    available && view.tier_state == Ready && free(view.activity, state)
  })
}

fn free(activity: Activity, state: QueueState) -> Bool {
  case activity {
    Idle -> True
    // A queue with `skip_agents_with_external_calls` off treats an agent on
    // a call that did not come from a queue as available, which is
    // mod_callcenter's switch of the same name.
    OnCall(queue_call: False) -> !state.skip_external_calls
    _ -> False
  }
}

/// A queue state with nothing in it, for a queue whose strategy keeps no
/// memo and for the tests.
pub fn new_state(account_id: String, queue_id: String) -> QueueState {
  QueueState(
    account_id: account_id,
    queue_id: queue_id,
    strategy: "",
    skip_external_calls: True,
    ring_simultaneously: 1,
    memo: doc.object([]),
  )
}
