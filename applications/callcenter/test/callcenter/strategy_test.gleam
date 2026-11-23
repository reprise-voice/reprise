//// The strategy registry, the exclusions every strategy shares, and the
//// strategies themselves.

import callcenter/strategies/tier_order
import callcenter/strategy
import callcenter/types.{
  type AgentView, ActiveInbound, AgentView, Available, AvailableOnDemand, Idle,
  LoggedOut, NoAnswer, OnBreak, OnCall, Ready, Ringing, Sequential, Simultaneous,
  Standby, WrappingUp,
}
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc

fn view(id: String) -> AgentView {
  AgentView(
    agent_id: id,
    availability: Available,
    activity: Idle,
    level: 1,
    position: 1,
    tier_state: Ready,
    last_call_end: None,
    free_since: 0,
    answered: 0,
    talk_time_s: 0,
    missed: 0,
  )
}

fn state() -> strategy.QueueState {
  strategy.new_state("acct", "support")
}

// --- The registry ----------------------------------------------------------

pub fn for_name_test() {
  let assert Ok(ring_all) = strategy.for_name("ring_all")
  assert ring_all.name == "ring_all"
  let assert Ok(longest) = strategy.for_name("longest_idle")
  assert longest.name == "longest_idle"
  let assert Ok(robin) = strategy.for_name("round_robin")
  assert robin.name == "round_robin"
  let assert Ok(seq) = strategy.for_name("sequential")
  assert seq.name == "sequential"
  let assert Ok(fewest) = strategy.for_name("fewest_calls")
  assert fewest.name == "fewest_calls"
  let assert Ok(talk) = strategy.for_name("least_talk_time")
  assert talk.name == "least_talk_time"
  // `top_down` was decided to be `sequential` under another name and left the
  // schema; a queue still naming it is a queue naming nothing.
  assert strategy.for_name("top_down") == Error(Nil)
  assert strategy.for_name("") == Error(Nil)
}

/// acdc's name for longest idle is kept by the queue schema as an alias.
pub fn most_idle_is_longest_idle_test() {
  let assert Ok(strategy) = strategy.for_name("most_idle")
  assert strategy.name == "longest_idle"
}

/// A queue naming a strategy this release does not have still dispatches.
pub fn resolve_falls_back_test() {
  assert strategy.resolve("top_down").name == "longest_idle"
  assert strategy.resolve("ring_all").name == "ring_all"
}

pub fn names_test() {
  assert strategy.names()
    == [
      "ring_all", "longest_idle", "round_robin", "sequential", "fewest_calls",
      "least_talk_time",
    ]
}

/// Every strategy offers only agents who could take the caller, and nobody
/// when nobody could: the dispatcher relies on it to offer a queue with no
/// such agent nobody without asking its strategy about each caller.
pub fn every_strategy_offers_only_the_selectable_test() {
  let views = [
    AgentView(..view("ready"), position: 3),
    AgentView(..view("busy"), position: 1, tier_state: types.Offering),
    AgentView(..view("away"), position: 2, availability: OnBreak),
    AgentView(..view("talking"), activity: OnCall(queue_call: True)),
  ]
  let nobody = list.filter(views, fn(view) { view.agent_id != "ready" })
  list.each(strategy.names(), fn(name) {
    let assert Ok(strategy) = strategy.for_name(name)
    let offered = case strategy.candidates(state(), views, 100) {
      Sequential(agents) -> agents
      Simultaneous(agents) -> agents
    }
    assert offered == ["ready"]
    let offered = case strategy.candidates(state(), nobody, 100) {
      Sequential(agents) -> agents
      Simultaneous(agents) -> agents
    }
    assert offered == []
  })
}

// --- Tier order ------------------------------------------------------------

/// Level, then position, then agent id: the three keys every strategy falls
/// back to, and the id last so that two agents a supervisor gave the same
/// place still have an order that is the same on every node.
pub fn tier_order_test() {
  let views = [
    AgentView(..view("zoe"), level: 1, position: 2),
    AgentView(..view("abe"), level: 2, position: 1),
    AgentView(..view("bea"), level: 1, position: 2),
    AgentView(..view("cal"), level: 1, position: 1),
  ]
  assert ids(tier_order.sorted(views)) == ["cal", "bea", "zoe", "abe"]
}

// --- Exclusions ------------------------------------------------------------

/// Availability says the agent is working; on demand counts because this is
/// only ever asked while somebody is waiting.
pub fn selectable_by_availability_test() {
  let views = [
    AgentView(..view("working"), availability: Available),
    AgentView(..view("on_demand"), availability: AvailableOnDemand),
    AgentView(..view("out"), availability: LoggedOut),
    AgentView(..view("break"), availability: OnBreak),
  ]
  assert ids(strategy.selectable(state(), views)) == ["working", "on_demand"]
}

/// Activity says the phones are free. Ringing and wrapping up are not.
pub fn selectable_by_activity_test() {
  let views = [
    AgentView(..view("idle"), activity: Idle),
    AgentView(..view("ringing"), activity: Ringing),
    AgentView(..view("wrapup"), activity: WrappingUp),
    AgentView(..view("queue_call"), activity: OnCall(queue_call: True)),
    AgentView(..view("other_call"), activity: OnCall(queue_call: False)),
  ]
  assert ids(strategy.selectable(state(), views)) == ["idle"]
}

/// skip_agents_with_external_calls off lets an agent on a call that did not
/// come from a queue be offered one; a queue call still never does.
pub fn selectable_with_external_calls_allowed_test() {
  let state = strategy.QueueState(..state(), skip_external_calls: False)
  let views = [
    AgentView(..view("idle"), activity: Idle),
    AgentView(..view("other_call"), activity: OnCall(queue_call: False)),
    AgentView(..view("queue_call"), activity: OnCall(queue_call: True)),
  ]
  assert ids(strategy.selectable(state, views)) == ["idle", "other_call"]
}

/// The tier state is this queue's own view of the agent: only Ready is free.
pub fn selectable_by_tier_state_test() {
  let views = [
    AgentView(..view("ready"), tier_state: Ready),
    AgentView(..view("offering"), tier_state: types.Offering),
    AgentView(..view("inbound"), tier_state: ActiveInbound),
    AgentView(..view("standby"), tier_state: Standby),
    AgentView(..view("no_answer"), tier_state: NoAnswer),
  ]
  assert ids(strategy.selectable(state(), views)) == ["ready"]
}

// --- ring_all --------------------------------------------------------------

pub fn ring_all_rings_everyone_test() {
  let assert Ok(ring_all) = strategy.for_name("ring_all")
  let views = [
    AgentView(..view("c"), level: 2, position: 1),
    AgentView(..view("a"), level: 1, position: 1),
    AgentView(..view("b"), level: 1, position: 2),
  ]
  let offer = ring_all.candidates(state(), views, 100)
  assert offer == Simultaneous(["a", "b", "c"])
}

pub fn ring_all_excludes_test() {
  let assert Ok(ring_all) = strategy.for_name("ring_all")
  let views = [view("free"), AgentView(..view("busy"), activity: Ringing)]
  assert ring_all.candidates(state(), views, 100) == Simultaneous(["free"])
}

pub fn ring_all_with_nobody_test() {
  let assert Ok(ring_all) = strategy.for_name("ring_all")
  assert ring_all.candidates(state(), [], 100) == Simultaneous([])
}

// --- longest_idle ----------------------------------------------------------

/// Free since is the whole ordering: whoever has been free longest goes
/// first. An agent whose document shows no last call is not idle for ever:
/// the dispatcher folds their login into `free_since`.
pub fn longest_idle_orders_by_free_since_test() {
  let assert Ok(longest) = strategy.for_name("longest_idle")
  let views = [
    AgentView(..view("recent"), free_since: 500, last_call_end: Some(500)),
    AgentView(..view("older"), free_since: 100, last_call_end: Some(100)),
    AgentView(..view("fresh_login"), free_since: 900, last_call_end: None),
  ]
  assert longest.candidates(state(), views, 1000)
    == Sequential(["older", "recent", "fresh_login"])
}

/// Ties fall back to the order the supervisor set.
pub fn longest_idle_ties_go_by_tier_test() {
  let assert Ok(longest) = strategy.for_name("longest_idle")
  let views = [
    AgentView(..view("second"), level: 1, position: 2, free_since: 100),
    AgentView(..view("first"), level: 1, position: 1, free_since: 100),
    AgentView(..view("late"), level: 1, position: 4, free_since: 50),
    AgentView(..view("early"), level: 1, position: 3, free_since: 50),
  ]
  assert longest.candidates(state(), views, 1000)
    == Sequential(["early", "late", "first", "second"])
}

/// Level before idle: the level 2 agent who has waited all morning is still
/// behind a level 1 agent who has just come free.
pub fn longest_idle_goes_by_level_first_test() {
  let assert Ok(longest) = strategy.for_name("longest_idle")
  let views = [
    AgentView(..view("backstop"), level: 2, position: 1, free_since: 10),
    AgentView(..view("just_free"), level: 1, position: 1, free_since: 990),
    AgentView(..view("waiting"), level: 1, position: 2, free_since: 500),
  ]
  assert longest.candidates(state(), views, 1000)
    == Sequential(["waiting", "just_free", "backstop"])
}

pub fn longest_idle_excludes_test() {
  let assert Ok(longest) = strategy.for_name("longest_idle")
  let views = [
    AgentView(..view("free"), free_since: 500),
    AgentView(..view("gone"), availability: LoggedOut, free_since: 1),
  ]
  assert longest.candidates(state(), views, 1000) == Sequential(["free"])
}

// --- round_robin -----------------------------------------------------------

fn round_robin() -> strategy.Strategy {
  let assert Ok(robin) = strategy.for_name("round_robin")
  robin
}

/// Three agents whose tier order is ann, bea, cal, given out of order so that
/// a test that passes by accident cannot be reading the view's order.
fn three_agents() -> List(AgentView) {
  [
    AgentView(..view("bea"), level: 1, position: 2),
    AgentView(..view("cal"), level: 1, position: 3),
    AgentView(..view("ann"), level: 1, position: 1),
  ]
}

/// A queue that has never rung anybody starts where the supervisor's order
/// starts.
pub fn round_robin_starts_at_the_top_test() {
  let robin = round_robin()
  assert robin.candidates(state(), three_agents(), 100)
    == Sequential(["ann", "bea", "cal"])
}

pub fn round_robin_starts_after_the_last_agent_test() {
  let robin = round_robin()
  let after_ann = robin.on_result(state(), "ann", types.Offered)
  assert robin.candidates(after_ann, three_agents(), 100)
    == Sequential(["bea", "cal", "ann"])
}

/// Past the end of the list is the top of it again.
pub fn round_robin_wraps_round_test() {
  let robin = round_robin()
  let after_cal = robin.on_result(state(), "cal", types.Offered)
  assert robin.candidates(after_cal, three_agents(), 100)
    == Sequential(["ann", "bea", "cal"])
}

/// The cursor is moved over the whole tier, not over the agents who are free,
/// so an agent who was busy when their turn came is passed and not queued up:
/// the next caller starts after them.
pub fn round_robin_advances_past_a_busy_agent_test() {
  let robin = round_robin()
  let after_bea = robin.on_result(state(), "bea", types.Offered)
  let views = [
    AgentView(..view("bea"), level: 1, position: 2, activity: Ringing),
    AgentView(..view("cal"), level: 1, position: 3),
    AgentView(..view("ann"), level: 1, position: 1),
  ]
  assert robin.candidates(after_bea, views, 100) == Sequential(["cal", "ann"])
}

/// An agent taken off the queue takes the cursor with them, and the next
/// caller starts at the top rather than nowhere.
pub fn round_robin_forgets_an_agent_off_the_tier_test() {
  let robin = round_robin()
  let after_dan = robin.on_result(state(), "dan", types.Offered)
  assert robin.candidates(after_dan, three_agents(), 100)
    == Sequential(["ann", "bea", "cal"])
}

/// The agent rung last is not in this caller's list -- a level 2 agent, rung
/// for a caller who had waited long enough to reach level 2, and this caller
/// may only reach level 1. Level 1 carries on after bea, the level 1 agent
/// rung last, rather than starting at its top again.
pub fn round_robin_keeps_a_level_turn_when_another_level_rang_test() {
  let robin = round_robin()
  let memo =
    state()
    |> robin.on_result("bea", types.Offered)
    |> robin.on_result("dan", types.Offered)
  assert robin.candidates(memo, three_agents(), 100)
    == Sequential(["cal", "ann", "bea"])

  // And level 2 carries on after dan, below level 1.
  let with_level_two = [
    AgentView(..view("dan"), level: 2, position: 1),
    AgentView(..view("eve"), level: 2, position: 2),
    ..three_agents()
  ]
  assert robin.candidates(memo, with_level_two, 100)
    == Sequential(["cal", "ann", "bea", "eve", "dan"])
}

/// An agent taken off the queue after their turn hands it to whoever of
/// their level was rung before them, not back to the top.
pub fn round_robin_passes_the_turn_of_a_departed_agent_test() {
  let robin = round_robin()
  let memo =
    state()
    |> robin.on_result("ann", types.Offered)
    |> robin.on_result("bea", types.Offered)
    |> robin.on_result("zed", types.Offered)
  assert robin.candidates(memo, three_agents(), 100)
    == Sequential(["cal", "ann", "bea"])
}

/// Each agent is in the list of who was rung once, newest first, so a turn
/// taken again moves them to the front rather than leaving a stale entry.
pub fn round_robin_remembers_each_agent_once_test() {
  let robin = round_robin()
  let memo =
    state()
    |> robin.on_result("ann", types.Offered)
    |> robin.on_result("bea", types.Offered)
    |> robin.on_result("ann", types.Offered)
  assert doc.strings(memo.memo, ["recent"]) == ["ann", "bea"]
  assert robin.candidates(memo, three_agents(), 100)
    == Sequential(["bea", "cal", "ann"])
}

/// The cursor moves as the agent is rung and not as their offer ends: the
/// outcomes come back in whatever order the phones answer, and an older
/// offer ending after a newer one must not rewind the cursor.
pub fn round_robin_moves_on_the_ring_and_not_on_the_outcome_test() {
  let robin = round_robin()
  let after_ann = robin.on_result(state(), "ann", types.Offered)
  let outcomes = [types.Taken, types.Missed, types.Abandoned, types.Lost]
  list.each(outcomes, fn(outcome) {
    let stale = robin.on_result(after_ann, "cal", outcome)
    assert robin.candidates(stale, three_agents(), 100)
      == Sequential(["bea", "cal", "ann"])
  })
}

/// Round robin rotates within a level and keeps the levels in order. With
/// the cursor on ann, a rotation of the whole list would offer the level 2
/// agent before ann; within the level, level 1 comes round to ann first.
pub fn round_robin_goes_by_level_first_test() {
  let robin = round_robin()
  let views = [
    AgentView(..view("backstop"), level: 2, position: 1),
    AgentView(..view("ann"), level: 1, position: 1),
    AgentView(..view("bea"), level: 1, position: 2),
  ]
  let after_bea = robin.on_result(state(), "bea", types.Offered)
  assert robin.candidates(after_bea, views, 100)
    == Sequential(["ann", "bea", "backstop"])
  let after_ann = robin.on_result(state(), "ann", types.Offered)
  assert robin.candidates(after_ann, views, 100)
    == Sequential(["bea", "ann", "backstop"])
}

/// How many of them ring at once is the dispatcher's business, not the
/// strategy's: the whole ordered list comes back either way.
pub fn round_robin_answers_the_whole_list_test() {
  let robin = round_robin()
  let state = strategy.QueueState(..state(), ring_simultaneously: 2)
  assert robin.candidates(state, three_agents(), 100)
    == Sequential(["ann", "bea", "cal"])
}

// --- sequential ------------------------------------------------------------

fn sequential() -> strategy.Strategy {
  let assert Ok(seq) = strategy.for_name("sequential")
  seq
}

/// Level, then position, then agent id: the supervisor's order and nothing
/// else.
pub fn sequential_follows_the_tier_order_test() {
  let views = [
    AgentView(..view("zoe"), level: 1, position: 2),
    AgentView(..view("abe"), level: 2, position: 1),
    AgentView(..view("bea"), level: 1, position: 2),
    AgentView(..view("cal"), level: 1, position: 1),
  ]
  assert sequential().candidates(state(), views, 100)
    == Sequential(["cal", "bea", "zoe", "abe"])
}

/// Every caller starts at the top, so the counters that move the other
/// strategies move nothing here.
pub fn sequential_starts_at_the_top_every_time_test() {
  let views = [
    AgentView(..view("ann"), level: 1, position: 1, answered: 9),
    AgentView(..view("bea"), level: 1, position: 2, answered: 0),
  ]
  let after_ann = sequential().on_result(state(), "ann", types.Offered)
  assert sequential().candidates(after_ann, views, 100)
    == Sequential(["ann", "bea"])
}

/// The agent a pass cannot ring is the agent the next one starts at: the top
/// of the list is whoever is left.
pub fn sequential_excludes_test() {
  let views = [
    AgentView(..view("ann"), level: 1, position: 1, activity: Ringing),
    AgentView(..view("bea"), level: 1, position: 2, tier_state: NoAnswer),
    AgentView(..view("cal"), level: 1, position: 3),
  ]
  assert sequential().candidates(state(), views, 100) == Sequential(["cal"])
}

// --- fewest_calls ----------------------------------------------------------

fn fewest_calls() -> strategy.Strategy {
  let assert Ok(fewest) = strategy.for_name("fewest_calls")
  fewest
}

pub fn fewest_calls_orders_by_answered_test() {
  let views = [
    AgentView(..view("busy"), answered: 7),
    AgentView(..view("some"), answered: 3),
    AgentView(..view("one"), answered: 1),
  ]
  assert fewest_calls().candidates(state(), views, 100)
    == Sequential(["one", "some", "busy"])
}

/// The counters reset at login, so an agent who has just come on is on
/// nothing and goes first.
pub fn fewest_calls_puts_a_fresh_login_first_test() {
  let views = [
    AgentView(..view("here_since_eight"), level: 1, position: 1, answered: 12),
    AgentView(..view("just_on"), level: 1, position: 2, answered: 0),
  ]
  assert fewest_calls().candidates(state(), views, 100)
    == Sequential(["just_on", "here_since_eight"])
}

/// Everybody starts a login tied, so most of the early decisions are the
/// supervisor's order.
pub fn fewest_calls_ties_go_by_tier_test() {
  let views = [
    AgentView(..view("second"), level: 1, position: 2, answered: 2),
    AgentView(..view("first"), level: 1, position: 1, answered: 2),
    AgentView(..view("early"), level: 1, position: 3, answered: 0),
  ]
  assert fewest_calls().candidates(state(), views, 100)
    == Sequential(["early", "first", "second"])
}

/// Level before the count: a level 2 agent on nothing waits behind every
/// free level 1 agent, however busy they have been.
pub fn fewest_calls_goes_by_level_first_test() {
  let views = [
    AgentView(..view("backstop"), level: 2, position: 1, answered: 0),
    AgentView(..view("busy"), level: 1, position: 1, answered: 9),
    AgentView(..view("busier"), level: 1, position: 2, answered: 12),
    AgentView(..view("backstop_busy"), level: 2, position: 2, answered: 4),
  ]
  assert fewest_calls().candidates(state(), views, 100)
    == Sequential(["busy", "busier", "backstop", "backstop_busy"])
}

pub fn fewest_calls_excludes_test() {
  let views = [
    AgentView(..view("free"), answered: 5),
    AgentView(..view("gone"), availability: LoggedOut, answered: 0),
  ]
  assert fewest_calls().candidates(state(), views, 100) == Sequential(["free"])
}

// --- least_talk_time -------------------------------------------------------

fn least_talk_time() -> strategy.Strategy {
  let assert Ok(talk) = strategy.for_name("least_talk_time")
  talk
}

/// Seconds, not calls: one long case is more of the shift than several short
/// ones, which is the whole reason this is not fewest_calls.
pub fn least_talk_time_orders_by_seconds_test() {
  let views = [
    AgentView(..view("long_case"), answered: 1, talk_time_s: 1800),
    AgentView(..view("six_quick_ones"), answered: 6, talk_time_s: 420),
  ]
  assert least_talk_time().candidates(state(), views, 100)
    == Sequential(["six_quick_ones", "long_case"])
}

pub fn least_talk_time_puts_a_fresh_login_first_test() {
  let views = [
    AgentView(..view("talking_all_day"), level: 1, position: 1, talk_time_s: 90),
    AgentView(..view("just_on"), level: 1, position: 2, talk_time_s: 0),
  ]
  assert least_talk_time().candidates(state(), views, 100)
    == Sequential(["just_on", "talking_all_day"])
}

pub fn least_talk_time_ties_go_by_tier_test() {
  let views = [
    AgentView(..view("second"), level: 1, position: 2, talk_time_s: 60),
    AgentView(..view("first"), level: 1, position: 1, talk_time_s: 60),
    AgentView(..view("early"), level: 1, position: 3, talk_time_s: 0),
  ]
  assert least_talk_time().candidates(state(), views, 100)
    == Sequential(["early", "first", "second"])
}

/// Level before the seconds.
pub fn least_talk_time_goes_by_level_first_test() {
  let views = [
    AgentView(..view("backstop"), level: 2, position: 1, talk_time_s: 0),
    AgentView(..view("talker"), level: 1, position: 1, talk_time_s: 3600),
    AgentView(..view("quiet"), level: 1, position: 2, talk_time_s: 600),
  ]
  assert least_talk_time().candidates(state(), views, 100)
    == Sequential(["quiet", "talker", "backstop"])
}

pub fn least_talk_time_excludes_test() {
  let views = [
    AgentView(..view("free"), talk_time_s: 300),
    AgentView(
      ..view("busy"),
      activity: OnCall(queue_call: True),
      talk_time_s: 0,
    ),
  ]
  assert least_talk_time().candidates(state(), views, 100)
    == Sequential(["free"])
}

// --- The memo --------------------------------------------------------------

/// Round robin is the only strategy that keeps state between callers; for
/// the other five a result changes nothing. The call is still made on every
/// result, because a strategy that does keep state is only that function.
pub fn on_result_keeps_the_state_test() {
  let assert Ok(ring_all) = strategy.for_name("ring_all")
  let assert Ok(longest) = strategy.for_name("longest_idle")
  let state = state()
  let results = [
    types.Offered,
    types.Taken,
    types.Missed,
    types.Abandoned,
    types.Lost,
  ]
  let memoless = [
    ring_all,
    longest,
    sequential(),
    fewest_calls(),
    least_talk_time(),
  ]
  list.each(memoless, fn(impl: strategy.Strategy) {
    list.each(results, fn(result) {
      assert impl.on_result(state, "agent", result) == state
    })
  })
}

fn ids(views: List(AgentView)) -> List(String) {
  case views {
    [] -> []
    [view, ..rest] -> [view.agent_id, ..ids(rest)]
  }
}
