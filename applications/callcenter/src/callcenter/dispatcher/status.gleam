//// What a dispatcher says it is doing: the `Queues` of a `status_resp`, and
//// the `Snapshot` that `sup` prints.
////
//// Rendering only. `callcenter/status` is what asks a dispatcher for this
//// and answers the `status_req` with it.

import callcenter/activity
import callcenter/availability
import callcenter/dispatcher/publish
import callcenter/dispatcher/settings.{type QueueSettings}
import callcenter/dispatcher/state.{type State, type Wait, offer_of}
import callcenter/dispatcher/view
import callcenter/dispatcher/waiting
import callcenter/types.{ActiveInbound, NoAnswer, Offering, Ready, Standby}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc.{type Value}

/// What `sup` prints for one dispatcher.
pub type Snapshot {
  Snapshot(
    account_id: String,
    /// Queue id, callers waiting.
    queues: List(#(String, Int)),
    /// Call id, queue id, seconds waited.
    waiting: List(#(String, String, Int)),
    /// Agent id, availability, activity.
    agents: List(#(String, String, String)),
    /// Call id, the agents being rung for it.
    offers: List(#(String, List(String))),
  )
}

/// The `Queues` of a `status_resp`: what is waiting and who could take it.
///
/// The wire's own spelling, `Queue-ID` and `Joined-Timestamp`, because this
/// goes out as a `status_resp` and `kapi.callcenter.status_resp` is what
/// says what that looks like. Crossbar translates to the API's names on the
/// far side; `sup` prints it as it stands.
pub fn queues(state: State, queue_id: Option(String)) -> List(Value) {
  let now = state.config.now()
  waiting.queues(state)
  |> list.append(case queue_id {
    Some(queue_id) -> [queue_id]
    None -> []
  })
  |> list.unique
  |> list.filter(fn(id) {
    case queue_id {
      Some(wanted) -> id == wanted
      None -> True
    }
  })
  |> list.map(fn(id) {
    let settings = settings.for_queue(state.config, id)
    let queued = waiting.in_queue(state, id, settings)
    doc.object_some([
      #("Queue-ID", Some(doc.String(id))),
      #("Waiting", Some(doc.List(waiting_status(state, queued, now)))),
      // The two numbers the callflow action decides on: whether the queue is
      // full, and whether anybody could take the caller. It asks how many and
      // not who, and the lists beside them are for a screen -- so a node that
      // can count without a dispatcher can still answer a caller. A count
      // the dispatcher cannot vouch for is left out (`view.vouched_for`: the
      // activity unread, the queue's document or an agent who could be
      // ready unreadable): the action reads a number not said as unknown,
      // and lets the caller in.
      #("Waiting-Count", Some(doc.Int(list.length(queued)))),
      #(
        "Agents-Available",
        view.available_count(state, settings) |> option.map(doc.Int),
      ),
      #("Agents", Some(doc.List(agents_status(state, settings)))),
    ])
  })
}

fn waiting_status(state: State, queued: List(Wait), now: Int) -> List(Value) {
  list.index_map(queued, fn(wait, index) {
    doc.object_some([
      #("Call-ID", Some(doc.String(wait.member.call_id))),
      #("Caller-ID-Name", option.map(wait.member.caller_id_name, doc.String)),
      #(
        "Caller-ID-Number",
        option.map(wait.member.caller_id_number, doc.String),
      ),
      #("Joined-Timestamp", Some(doc.Int(wait.member.joined))),
      #("Waited", Some(doc.Int(now - wait.member.joined))),
      #("Priority", Some(doc.Int(wait.member.priority))),
      #("Media-Node", publish.media_node(wait.member)),
      #("Offered-To", offered_to(state, wait.member.call_id)),
      #("Position", Some(doc.Int(index + 1))),
    ])
  })
}

/// The agent a caller is ringing at right now, if any. One name and not the
/// list, because a simultaneous ring names the first: a live view wants
/// "somebody is being tried", and the offers themselves are in the events.
fn offered_to(state: State, call_id: String) -> Option(Value) {
  case dict.get(state.offers, call_id) {
    Ok(offer) ->
      case offer.agents {
        [agent_id, ..] -> Some(doc.String(agent_id))
        [] -> None
      }
    Error(Nil) -> None
  }
}

fn agents_status(state: State, settings: QueueSettings) -> List(Value) {
  list.map(settings.tiers, fn(tier) {
    let #(current, counters) = view.agent_state(state, tier.agent_id)
    let call = call_of(state, tier.agent_id)
    doc.object_some([
      #("Agent-ID", Some(doc.String(tier.agent_id))),
      #(
        "Availability",
        Some(doc.String(availability.to_string(current.availability))),
      ),
      #(
        "Activity",
        Some(
          doc.String(
            activity.to_string(view.activity_shown(state, tier.agent_id)),
          ),
        ),
      ),
      #("Answered", Some(doc.Int(counters.calls_answered))),
      #("Missed", Some(doc.Int(counters.missed))),
      #("Last-Call-End", option.map(counters.last_call_end, doc.Int)),
      #("Tier-Level", Some(doc.Int(tier.level))),
      #("Tier-Position", Some(doc.Int(tier.position))),
      #(
        "Tier-State",
        Some(
          doc.String(
            tier_state_to_string(view.tier_state(state, tier.agent_id, settings)),
          ),
        ),
      ),
      #("Call-ID", option.map(call, fn(call) { doc.String(call.call_id) })),
      #("Queue-ID", option.map(call, fn(call) { doc.String(call.queue_id) })),
      #("Connected", option.map(call, fn(call) { doc.Bool(call.connected) })),
    ])
  })
}

/// The queue call an agent is on or being rung for: what a supervisor
/// listens in on. The caller's call and not the agent's leg, because
/// eavesdropping on the caller hears both of them, and it is the one the
/// events name as well.
type AgentCall {
  AgentCall(call_id: String, queue_id: String, connected: Bool)
}

/// The caller of the offer that holds an agent, the queue they came in
/// through -- an agent in two queues can be on a call from the other one --
/// and whether it is the agent who answered. An offer somebody else answered,
/// a supervisor's pickup, is not the agent's call.
fn call_of(state: State, agent_id: String) -> Option(AgentCall) {
  case offer_of(state, agent_id) {
    Ok(offer) ->
      case offer.connected {
        None -> Some(AgentCall(offer.member.call_id, offer.queue_id, False))
        Some(#(answerer, _, _)) if answerer == agent_id ->
          Some(AgentCall(offer.member.call_id, offer.queue_id, True))
        Some(_answered_by_another) -> None
      }
    Error(Nil) -> None
  }
}

/// A tier state as the schema spells it.
pub fn tier_state_to_string(state: types.TierState) -> String {
  case state {
    Ready -> "ready"
    Offering -> "offering"
    ActiveInbound -> "active_inbound"
    Standby -> "standby"
    NoAnswer -> "no_answer"
  }
}

/// What this dispatcher is doing, for `sup`.
pub fn snapshot(state: State) -> Snapshot {
  let now = state.config.now()
  Snapshot(
    account_id: state.config.account_id,
    queues: list.map(waiting.queues(state), fn(queue_id) {
      #(
        queue_id,
        list.count(dict.values(state.waiting), fn(wait) {
          wait.member.queue_id == queue_id
        }),
      )
    }),
    waiting: list.map(dict.values(state.waiting), fn(wait) {
      #(wait.member.call_id, wait.member.queue_id, now - wait.member.joined)
    }),
    agents: list.map(known_agents(state), fn(agent_id) {
      let #(current, _counters) = view.agent_state(state, agent_id)
      #(
        agent_id,
        availability.to_string(current.availability),
        activity.to_string(view.activity_shown(state, agent_id)),
      )
    }),
    offers: list.map(dict.values(state.offers), fn(offer) {
      #(offer.member.call_id, offer.agents)
    }),
  )
}

/// The agents of the queues with callers in them, and whoever else this
/// dispatcher has in an offer or a wrap-up. An entry in `busy` naming an
/// offer that has been replaced holds nobody (`state.offer_of`).
@internal
pub fn known_agents(state: State) -> List(String) {
  waiting.queues(state)
  |> list.flat_map(fn(queue_id) {
    list.map(settings.for_queue(state.config, queue_id).tiers, fn(tier) {
      tier.agent_id
    })
  })
  |> list.append(
    dict.keys(state.busy)
    |> list.filter(fn(agent_id) { result.is_ok(offer_of(state, agent_id)) }),
  )
  |> list.append(dict.keys(state.wrapup))
  |> list.unique
  |> list.sort(string.compare)
}
