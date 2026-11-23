//// Tier rules: which levels a caller of a given age may be offered to.

import callcenter/tiers
import gleam/list
import kazoo/doc

/// A queue document with three agents on three levels.
fn queue(rules: List(#(String, doc.Value))) -> doc.Value {
  doc.object([
    #("name", doc.String("support")),
    #("tier_rules", doc.object(rules)),
    #(
      "agents",
      doc.List([
        agent("first", 1, 1),
        agent("second", 1, 2),
        agent("third", 2, 1),
        agent("fourth", 3, 1),
      ]),
    ),
  ])
}

fn agent(id: String, level: Int, position: Int) -> doc.Value {
  doc.object([
    #("id", doc.String(id)),
    #("level", doc.Int(level)),
    #("position", doc.Int(position)),
  ])
}

fn ids(tiers: List(tiers.Tier)) -> List(String) {
  list.map(tiers, fn(tier) { tier.agent_id })
}

fn anybody(_agent_id: String) -> Bool {
  True
}

fn nobody(_agent_id: String) -> Bool {
  False
}

pub fn rules_defaults_test() {
  let rules = tiers.rules(doc.object([]))
  assert rules == tiers.default_rules()
  assert rules.apply == False
  assert rules.no_agent_no_wait == True
}

pub fn rules_read_test() {
  let rules =
    tiers.rules(
      queue([
        #("apply", doc.Bool(True)),
        #("wait_seconds", doc.Int(20)),
        #("wait_multiply_level", doc.Bool(True)),
        #("no_agent_no_wait", doc.Bool(False)),
      ]),
    )
  assert rules.apply
  assert rules.wait_seconds == 20
  assert rules.wait_multiply_level
  assert !rules.no_agent_no_wait
}

/// Level then position, whatever order the document lists them in, because
/// two nodes reading the same document have to build the same list.
pub fn tiers_are_ordered_test() {
  let unordered =
    doc.object([
      #(
        "agents",
        doc.List([
          agent("third", 2, 1),
          agent("second", 1, 2),
          agent("first", 1, 1),
        ]),
      ),
    ])
  assert ids(tiers.of(unordered)) == ["first", "second", "third"]
}

pub fn tiers_take_the_schema_defaults_test() {
  let sparse =
    doc.object([
      #("agents", doc.List([doc.object([#("id", doc.String("only"))])])),
    ])
  assert tiers.of(sparse)
    == [tiers.Tier(agent_id: "only", level: 1, position: 1)]
}

/// An entry with no id is not an agent.
pub fn tiers_drop_entries_without_an_id_test() {
  let broken =
    doc.object([
      #(
        "agents",
        doc.List([doc.object([#("level", doc.Int(1))]), agent("real", 1, 1)]),
      ),
    ])
  assert ids(tiers.of(broken)) == ["real"]
}

/// Rules off: every level from the first second.
pub fn eligible_without_rules_test() {
  let queue = queue([])
  let all = tiers.of(queue)
  assert ids(tiers.eligible(tiers.rules(queue), all, 0, anybody))
    == ["first", "second", "third", "fourth"]
}

/// Rules on: the lowest level right away, the rest after the wait.
pub fn eligible_adds_levels_after_the_wait_test() {
  let queue =
    queue([#("apply", doc.Bool(True)), #("wait_seconds", doc.Int(10))])
  let rules = tiers.rules(queue)
  let all = tiers.of(queue)
  assert ids(tiers.eligible(rules, all, 0, anybody)) == ["first", "second"]
  assert ids(tiers.eligible(rules, all, 9, anybody)) == ["first", "second"]
  // Without wait_multiply_level one threshold covers every level above the
  // lowest, so both of them join at once.
  assert ids(tiers.eligible(rules, all, 10, anybody))
    == ["first", "second", "third", "fourth"]
}

/// With wait_multiply_level each level waits longer than the last.
pub fn eligible_multiplies_by_level_test() {
  let queue =
    queue([
      #("apply", doc.Bool(True)),
      #("wait_seconds", doc.Int(10)),
      #("wait_multiply_level", doc.Bool(True)),
    ])
  let rules = tiers.rules(queue)
  let all = tiers.of(queue)
  assert tiers.threshold(rules, 1, 1) == 0
  assert tiers.threshold(rules, 2, 1) == 20
  assert tiers.threshold(rules, 3, 1) == 30
  assert ids(tiers.eligible(rules, all, 0, anybody)) == ["first", "second"]
  assert ids(tiers.eligible(rules, all, 20, anybody))
    == ["first", "second", "third"]
  assert ids(tiers.eligible(rules, all, 30, anybody))
    == ["first", "second", "third", "fourth"]
}

/// no_agent_no_wait: a caller does not sit through the ladder when the
/// levels admitted so far hold nobody who could answer.
pub fn eligible_skips_the_wait_with_no_agent_test() {
  let queue =
    queue([
      #("apply", doc.Bool(True)),
      #("wait_seconds", doc.Int(600)),
      #("no_agent_no_wait", doc.Bool(True)),
    ])
  let rules = tiers.rules(queue)
  let all = tiers.of(queue)
  assert ids(tiers.eligible(rules, all, 0, nobody))
    == ["first", "second", "third", "fourth"]

  // Somebody on level one could answer, so the wait applies again.
  let only_first = fn(agent_id) { agent_id == "first" }
  assert ids(tiers.eligible(rules, all, 0, only_first)) == ["first", "second"]
}

/// With the rule off the caller waits however long the ladder says, even
/// when nobody can take them.
pub fn eligible_waits_without_the_rule_test() {
  let queue =
    queue([
      #("apply", doc.Bool(True)),
      #("wait_seconds", doc.Int(600)),
      #("no_agent_no_wait", doc.Bool(False)),
    ])
  let rules = tiers.rules(queue)
  assert ids(tiers.eligible(rules, tiers.of(queue), 0, nobody))
    == ["first", "second"]
}

pub fn eligible_of_nothing_test() {
  let rules =
    tiers.rules(
      doc.object([#("tier_rules", doc.object([#("apply", doc.Bool(True))]))]),
    )
  assert tiers.eligible(rules, [], 100, anybody) == []
}

pub fn levels_test() {
  assert tiers.levels(tiers.of(queue([]))) == [1, 2, 3]
  assert tiers.levels([]) == []
}
