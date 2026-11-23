//// Tiers: which agents of a queue a given caller may be offered to yet.
////
//// A tier links an agent to a queue with a level and a position. Agents at
//// lower levels are offered a caller first; higher levels are added as the
//// caller waits. Position orders agents inside a level and is the tie-break
//// every strategy falls back to, the whole of the order for `sequential` and
//// the ring `round_robin` walks.
////
//// The rules are the queue document's `tier_rules` object and they mean what
//// mod_callcenter's mean:
////
//// - `apply` off is no tiering at all: every level is eligible from the
////   first second, which is the default and what a queue with one level
////   wants.
//// - `wait_seconds` is how long a caller waits before the next level joins
////   the set. Without `wait_multiply_level` that one threshold applies to
////   every level above the lowest, so they all join at once; with it, level
////   `n` joins at `wait_seconds * n`, so each level waits longer than the
////   last.
//// - `no_agent_no_wait` skips the wait when no agent in the levels admitted
////   so far could answer. A caller does not sit through the whole ladder
////   because the only level-one agent is on a break.
////
//// Nothing here reads availability or activity: "could answer" arrives as a
//// function, because the dispatcher is what knows.

import callcenter/fields
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import kazoo/doc.{type Value}

/// The queue document's `tier_rules`.
pub type Rules {
  Rules(
    apply: Bool,
    wait_seconds: Int,
    wait_multiply_level: Bool,
    no_agent_no_wait: Bool,
  )
}

/// One agent's place in one queue.
pub type Tier {
  Tier(agent_id: String, level: Int, position: Int)
}

/// The rules of a queue that says nothing about them: no tiering.
pub fn default_rules() -> Rules {
  Rules(
    apply: False,
    wait_seconds: 0,
    wait_multiply_level: False,
    no_agent_no_wait: True,
  )
}

/// The `tier_rules` of a queue document, with the schema's defaults for
/// anything it leaves out.
pub fn rules(queue: Value) -> Rules {
  let defaults = default_rules()
  Rules(
    apply: fields.bool_at(queue, ["tier_rules", "apply"], defaults.apply),
    wait_seconds: fields.int_at(
      queue,
      ["tier_rules", "wait_seconds"],
      defaults.wait_seconds,
    ),
    wait_multiply_level: fields.bool_at(
      queue,
      ["tier_rules", "wait_multiply_level"],
      defaults.wait_multiply_level,
    ),
    no_agent_no_wait: fields.bool_at(
      queue,
      ["tier_rules", "no_agent_no_wait"],
      defaults.no_agent_no_wait,
    ),
  )
}

/// The queue document's `agents`, ordered by level then position then id, so
/// that two nodes reading the same document build the same list.
///
/// An entry without an id is not an agent and is dropped; a level or
/// position the document leaves out is the schema's 1.
pub fn of(queue: Value) -> List(Tier) {
  doc.get_list(queue, ["agents"])
  |> result.unwrap([])
  |> list.filter_map(tier)
  |> list.sort(by_level_then_position)
}

fn tier(entry: Value) -> Result(Tier, Nil) {
  case doc.get_string(entry, ["id"]) {
    Ok("") -> Error(Nil)
    Ok(id) ->
      Ok(Tier(
        agent_id: id,
        level: doc.get_int(entry, ["level"]) |> result.unwrap(1),
        position: doc.get_int(entry, ["position"]) |> result.unwrap(1),
      ))
    Error(_) -> Error(Nil)
  }
}

fn by_level_then_position(a: Tier, b: Tier) -> order.Order {
  case int.compare(a.level, b.level) {
    order.Eq ->
      case int.compare(a.position, b.position) {
        order.Eq -> string.compare(a.agent_id, b.agent_id)
        other -> other
      }
    other -> other
  }
}

/// The distinct levels of a tier list, ascending.
pub fn levels(tiers: List(Tier)) -> List(Int) {
  levels_by(tiers, fn(tier: Tier) { tier.level })
}

fn levels_by(items: List(a), level: fn(a) -> Int) -> List(Int) {
  items
  |> list.map(level)
  |> list.unique
  |> list.sort(int.compare)
}

/// How long a caller waits before `level` joins the set, given that `lowest`
/// is the lowest level this queue has. The lowest level is never waited for.
pub fn threshold(rules: Rules, level: Int, lowest: Int) -> Int {
  case level <= lowest {
    True -> 0
    False ->
      case rules.wait_multiply_level {
        True -> rules.wait_seconds * level
        False -> rules.wait_seconds
      }
  }
}

/// The tiers a caller who has waited `waited_s` seconds may be offered to.
///
/// `answerable` says whether an agent could take a caller right now. It is
/// only asked about agents already admitted, and only when `no_agent_no_wait`
/// is on and the level would otherwise be waited for, so a queue that does
/// not use the rule never pays for it.
pub fn eligible(
  rules: Rules,
  tiers: List(Tier),
  waited_s: Int,
  answerable: fn(String) -> Bool,
) -> List(Tier) {
  eligible_by(rules, tiers, fn(tier: Tier) { tier.level }, waited_s, fn(tier) {
    answerable(tier.agent_id)
  })
}

/// The same over anything that carries a tier's level, in the order given:
/// the dispatcher asks it of the agents' views, one per tier, so that it
/// does not have to find each tier's view again afterwards.
pub fn eligible_by(
  rules: Rules,
  items: List(a),
  level: fn(a) -> Int,
  waited_s: Int,
  answerable: fn(a) -> Bool,
) -> List(a) {
  case rules.apply {
    False -> items
    True ->
      case levels_by(items, level) {
        [] -> []
        [lowest, ..] as levels ->
          admit(rules, items, level, levels, lowest, waited_s, answerable, [])
      }
  }
}

fn admit(
  rules: Rules,
  items: List(a),
  level_of: fn(a) -> Int,
  remaining: List(Int),
  lowest: Int,
  waited_s: Int,
  answerable: fn(a) -> Bool,
  admitted: List(Int),
) -> List(a) {
  case remaining {
    [] -> at_levels(items, level_of, admitted)
    [level, ..rest] ->
      case
        level <= lowest
        || waited_s >= threshold(rules, level, lowest)
        // Nobody admitted so far could answer: the rule skips the wait.
        || {
          rules.no_agent_no_wait
          && !list.any(at_levels(items, level_of, admitted), answerable)
        }
      {
        True ->
          admit(rules, items, level_of, rest, lowest, waited_s, answerable, [
            level,
            ..admitted
          ])
        // Levels are ascending and thresholds do not fall, so the first
        // level that is too early ends the set.
        False -> at_levels(items, level_of, admitted)
      }
  }
}

fn at_levels(
  items: List(a),
  level_of: fn(a) -> Int,
  levels: List(Int),
) -> List(a) {
  list.filter(items, fn(item) { list.contains(levels, level_of(item)) })
}
