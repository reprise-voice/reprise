//// What this dispatcher has itself seen each agent do: when they last
//// became free to take a caller, and the queue calls it connected and ended
//// for them this login.
////
//// The agent's `callcenter_agent` document has counters too, and they are
//// what survives a node loss, but they are written by another process and
//// read back through the document cache: the agent who hung up a moment ago
//// can still look, on the document, as if their last call ended an hour
//// ago, and a strategy reading only that would hand them the next caller.
//// So the strategies are shown both, the document and this, and the later
//// time or the larger count wins. On a dispatcher that has just taken the
//// account over this is empty and the document is the whole answer, which is
//// what it was before.
////
//// Everything here is in the actor's memory and nothing is written.

import callcenter/availability.{type AgentAvailability}
import callcenter/dispatcher/state.{
  type State, type Worked, Offer, State, Worked, is_pickup_offer,
}
import callcenter/records.{type Counters}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result

/// What this dispatcher has seen of an agent; nothing, for one it has not.
pub fn of(state: State, agent_id: String) -> Worked {
  dict.get(state.worked, agent_id)
  |> result.unwrap(Worked(free_since: 0, answered: 0, talk_time_s: 0))
}

/// When an agent last became free to take a caller: the latest of their
/// last offer or the end of their last queue call and its wrap-up, as this
/// dispatcher saw them; the end of their last queue call, as their document
/// has it; and their last change of availability, which for an agent who can
/// be offered anything at all is their login or the end of their break.
///
/// So a fresh login is idle from the login and not from the beginning of
/// time, a break is not idle, an agent whose phone just rang out is no
/// longer the one who has waited longest, and the call that ended a moment
/// ago counts before the document says so.
pub fn free_since(
  worked: Worked,
  current: AgentAvailability,
  counters: Counters,
) -> Int {
  worked.free_since
  |> int.max(option.unwrap(counters.last_call_end, 0))
  |> int.max(current.timestamp)
}

/// The answered calls a strategy is shown: the document's, or this
/// dispatcher's own count if that is larger.
///
/// The document counts every queue call of the login, wherever it was
/// answered, and lags; this counts the ones answered here, at once. Taking
/// the larger is exact whenever this dispatcher has seen the whole login,
/// never less than the document, and never counts a call twice.
pub fn answered(worked: Worked, counters: Counters) -> Int {
  int.max(counters.calls_answered, worked.answered)
}

/// The seconds on queue calls a strategy is shown, by the same rule.
pub fn talk_time_s(worked: Worked, counters: Counters) -> Int {
  int.max(counters.talk_time_s, worked.talk_time_s)
}

/// These agents are being rung for a caller, from `at`.
pub fn offered(state: State, agents: List(String), at: Int) -> State {
  list.fold(agents, state, fn(state, agent_id) {
    free_from(state, agent_id, at)
  })
}

/// A new login: the calls counted belong to the shift that ended. The time
/// they became free is the login's, which their availability says.
pub fn logged_in(state: State, agent_id: String) -> State {
  State(..state, worked: dict.delete(state.worked, agent_id))
}

/// What one message did to the offers, as the agents in them see it.
///
/// Compared before and after, so that it is the same whichever reply,
/// cancel, timer or takeover did it:
///
/// - an offer answered: the answerer has a call more, and everybody else it
///   was ringing lost the race and is free from now;
/// - an answered offer gone: the call is over, its seconds are counted, and
///   the agent is free from the end of their wrap-up, or from now if they
///   have none;
/// - an unanswered offer gone -- missed, failed, called off, abandoned by
///   the caller, past its ceiling: everybody it was ringing is free from now.
///
/// A supervisor's pickup is none of these: it moves no agent's idle time and
/// no agent's counts (`dispatcher/pickup`), however it ends.
pub fn observe(before: State, after: State) -> State {
  let now = after.config.now()
  dict.fold(before.offers, after, fn(state, call_id, offer) {
    use <- bool.guard(is_pickup_offer(before, offer.id), state)
    case offer.connected, dict.get(after.offers, call_id) {
      None, Ok(Offer(connected: Some(#(answerer, _, _)), ..)) ->
        list.filter(offer.agents, fn(agent_id) { agent_id != answerer })
        |> list.fold(state, fn(state, loser) { free_from(state, loser, now) })
        |> update(answerer, fn(worked) {
          Worked(..worked, answered: worked.answered + 1)
        })
      Some(#(agent_id, _, answered_at)), Error(Nil) -> {
        let until = dict.get(after.wrapup, agent_id) |> result.unwrap(now)
        update(state, agent_id, fn(worked) {
          Worked(
            free_since: int.max(worked.free_since, int.max(until, now)),
            answered: worked.answered,
            talk_time_s: worked.talk_time_s + int.max(0, now - answered_at),
          )
        })
      }
      None, Error(Nil) ->
        list.fold(offer.agents, state, fn(state, agent_id) {
          free_from(state, agent_id, now)
        })
      _still, _going -> state
    }
  })
}

fn free_from(state: State, agent_id: String, at: Int) -> State {
  update(state, agent_id, fn(worked) {
    Worked(..worked, free_since: int.max(worked.free_since, at))
  })
}

fn update(
  state: State,
  agent_id: String,
  change: fn(Worked) -> Worked,
) -> State {
  State(
    ..state,
    worked: dict.insert(state.worked, agent_id, change(of(state, agent_id))),
  )
}
