//// What a queue's strategy is shown, and what it keeps between callers.
////
//// The memo is the strategy's own state per queue -- only round robin keeps
//// anything in it, a cursor -- and it is held in the dispatcher's memory,
//// not on a document. Every outcome of every offer reaches the strategy
//// through `remember`.

import callcenter/dispatcher/settings.{type QueueSettings, Unreadable}
import callcenter/dispatcher/state.{type State, State}
import callcenter/strategy
import callcenter/types
import gleam/dict
import gleam/list
import gleam/result

/// The queue as its strategy is shown it for one pass.
pub fn queue_state(
  state: State,
  settings: QueueSettings,
) -> strategy.QueueState {
  strategy.QueueState(
    ..memo_base(state, settings),
    skip_external_calls: settings.skip_external_calls,
    ring_simultaneously: settings.ring_simultaneously,
  )
}

/// The state the queue's strategy last handed back, stamped with the
/// strategy's name.
///
/// A memo another strategy left is not this one's to read: a queue moved
/// from round robin to something else and back starts the cursor again
/// rather than resuming a shift that is over.
fn memo_base(state: State, settings: QueueSettings) -> strategy.QueueState {
  let base =
    dict.get(state.memo, settings.id)
    |> result.try(fn(stored: strategy.QueueState) {
      case stored.strategy == settings.strategy.name {
        True -> Ok(stored)
        False -> Error(Nil)
      }
    })
    |> result.unwrap(strategy.new_state(state.config.account_id, settings.id))
  strategy.QueueState(..base, strategy: settings.strategy.name)
}

/// Tell the queue's strategy how an offer turned out, and keep what it says.
///
/// Every outcome of an offer comes through here, in the order the agents were
/// rung, because a strategy that keeps a cursor has to hear about the agents
/// it rung whether they answered, missed or lost the caller -- hearing only
/// about answers would leave the cursor on an agent whose phone nobody picks
/// up.
pub fn remember(
  state: State,
  settings: QueueSettings,
  outcomes: List(#(String, types.OfferResult)),
) -> State {
  case outcomes, settings.found {
    [], _ -> state
    // Read as nothing, the queue's strategy is the default, and its memo
    // would be replaced by a new one of that: a round robin's cursor lost
    // to one unanswered read.
    _some, Unreadable -> state
    _some, _found -> {
      let carried =
        list.fold(outcomes, memo_base(state, settings), fn(memo, outcome) {
          settings.strategy.on_result(memo, outcome.0, outcome.1)
        })
      State(..state, memo: dict.insert(state.memo, settings.id, carried))
    }
  }
}

/// The same outcome for every agent of an offer.
pub fn each(
  agents: List(String),
  outcome: types.OfferResult,
) -> List(#(String, types.OfferResult)) {
  list.map(agents, fn(agent_id) { #(agent_id, outcome) })
}
