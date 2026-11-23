//// Start after the agent this queue tried last, and wrap around.
////
//// The even share: the queue keeps a cursor rather than reading a counter,
//// so an agent who has just been rung is the last one rung again whether
//// they answered, missed, lost the caller or never rang. That is the memo
//// -- `{"last": "<agent_id>", "recent": ["<agent_id>", ...]}` -- and this is
//// the only strategy that keeps one.
////
//// The cursor is moved over the full tier list and not over the agents who
//// happen to be free, so an agent who was busy or delayed when their turn
//// came is passed rather than queued up: the next caller starts after them,
//// not at them. The alternative -- rotating the free list -- hands the same
//// agent two callers in a row whenever the one before them is on a call.
////
//// The rotation is within a level, and the levels stay in order: every free
//// agent of level 1 is offered before any of level 2, and the turn moves
//// round the level it is in. Rotating the whole list instead would put the
//// level 2 agents ahead of the level 1 agents who come before the cursor.
////
//// Each level has its own cursor: the agent of that level rung most
//// recently. `recent` is the agents rung, newest first, each once, and a
//// level's cursor is the first of them the level has. A caller whose tier
//// rules let them reach level 2 moves level 2's cursor and leaves level 1's
//// where it was, so the next caller, who may only reach level 1, carries on
//// round level 1 instead of starting at its top again; and an agent taken
//// off the queue hands the turn to whoever of their level was rung before
//// them, not back to the top.
////
//// The memo lives in the dispatcher's memory, so a node taking the account
//// over starts from the top of the list again. Over a shift that is one
//// caller's worth of unevenness, which is cheaper than a document write per
//// offer.

import callcenter/strategies/tier_order
import callcenter/types.{
  type AgentView, type Choice, type Offer, type OfferResult, Offered, Sequential,
}
import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import gleam/set
import kazoo/doc.{type Value}

pub const name = "round_robin"

/// How many agents `recent` remembers. A level loses its cursor only once
/// this many other agents have been rung since anybody of that level was,
/// and then it starts at its top.
const remembered = 256

/// The tier order level by level, each level rotated to start after the
/// agent of that level tried last.
pub fn candidates(choice: Choice, _now: Int) -> Offer {
  // A set, because the filter below asks it of every agent of the queue,
  // once a caller: a 500-agent queue with most of them free was a quarter
  // of a million comparisons a caller as a list.
  let free =
    list.map(choice.selectable, fn(view: AgentView) { view.agent_id })
    |> set.from_list
  let recency =
    recent(choice.memo)
    |> list.index_map(fn(agent_id, rank) { #(agent_id, rank) })
    |> dict.from_list
  choice.agents
  |> tier_order.by_level
  |> list.flat_map(fn(level) {
    let agents = list.map(level, fn(view: AgentView) { view.agent_id })
    rotate_past(agents, cursor(agents, recency))
  })
  |> list.filter(set.contains(free, _))
  |> Sequential
}

/// The cursor moves as an agent is rung, not as their offer ends. Outcomes
/// come back in whatever order the phones answer, and an older offer ending
/// after a newer one must not rewind the cursor onto an agent whose turn is
/// over; and however it ends, the agent has had their turn.
pub fn on_result(memo: Value, agent_id: String, result: OfferResult) -> Value {
  case result {
    Offered ->
      memo
      |> doc.set(["last"], doc.String(agent_id))
      |> doc.set(
        ["recent"],
        [agent_id, ..list.filter(recent(memo), fn(other) { other != agent_id })]
          |> list.take(remembered)
          |> list.map(doc.String)
          |> doc.List,
      )
    _outcome -> memo
  }
}

/// The agents rung, newest first. A memo from before `recent` was kept has
/// only `last`.
fn recent(memo: Value) -> List(String) {
  case doc.get(memo, ["recent"]) {
    Ok(_list) -> doc.strings(memo, ["recent"])
    Error(Nil) ->
      case doc.get_string(memo, ["last"]) {
        Ok(last) -> [last]
        Error(Nil) -> []
      }
  }
}

/// The agent of this level rung most recently, or nobody.
fn cursor(agents: List(String), recency: dict.Dict(String, Int)) -> String {
  let rung =
    list.filter_map(agents, fn(agent_id) {
      dict.get(recency, agent_id)
      |> result.map(fn(rank) { #(rank, agent_id) })
    })
  case list.sort(rung, fn(a, b) { int.compare(a.0, b.0) }) {
    [#(_rank, newest), ..] -> newest
    [] -> ""
  }
}

/// The list starting at the agent after `last`, with `last` at the end. An
/// unset or departed `last` leaves the list as it is, which starts at the top.
fn rotate_past(agents: List(String), last: String) -> List(String) {
  case list.split_while(agents, fn(agent_id) { agent_id != last }) {
    #(_all, []) -> agents
    #(before, [tried, ..after]) -> list.flatten([after, before, [tried]])
  }
}
