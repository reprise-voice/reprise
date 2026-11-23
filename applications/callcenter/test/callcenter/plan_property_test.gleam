//// The dispatch plan against random accounts.
////
//// `dispatcher/plan` decides a whole pass from one reading and nothing else,
//// which is what makes this possible: a few hundred accounts -- queues with
//// every strategy, tiers at several levels and positions, tier rules on and
//// off, agents in every availability and activity and some of them held by
//// the dispatcher (offering, wrapping up, delayed after a miss), callers of
//// every priority and age, some with a system-joined stamp and some who
//// have already been rung for -- each read the way `view.snapshot` reads a
//// real one, planned, and the plan checked against what a pass promises:
////
//// - no agent is rung twice in one pass;
//// - only an agent who could take that caller is rung: ready in the queue,
////   taking calls, not rung already this pass, and at a level the queue's
////   tier rules admit after the caller's wait;
//// - a caller nobody is offered to had nobody to be offered, so no caller
////   is passed over for a later one -- of their queue or another -- who then
////   takes an agent they could have had;
//// - an ordered strategy rings the lowest level first, and offers exactly
////   the agents that could take the caller, those who have already had them
////   left out until everybody has;
//// - ring-all rings every agent who could take the caller, at once.
////
//// The accounts come from a seeded generator, the 48-bit linear
//// congruential one `java.util.Random` uses, so a failure names a seed and
//// the seed reproduces it. The rules above are restated here from their
//// statements, not called: the tier rules included.

import callcenter/availability
import callcenter/dispatcher/plan
import callcenter/dispatcher/settings.{type QueueSettings}
import callcenter/dispatcher/state.{type Wait, Wait}
import callcenter/dispatcher/waiting
import callcenter/strategy
import callcenter/tiers
import callcenter/types.{
  type Activity, type AgentView, type Availability, type TierState,
  ActiveInbound, AgentView, Available, AvailableOnDemand, Idle, LoggedOut,
  NoAnswer, OnBreak, OnCall, Ready, Ringing, Sequential, Simultaneous, Standby,
  WrappingUp,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import kazoo/doc
import support/cluster

const cases = 300

const now = 63_800_001_000

// --- The generator -----------------------------------------------------------

type Rng {
  Rng(state: Int)
}

const multiplier = 0x5DEECE66D

const mask = 0xFFFFFFFFFFFF

fn seeded(seed: Int) -> Rng {
  Rng(int.bitwise_and(int.bitwise_exclusive_or(seed, multiplier), mask))
}

fn next(rng: Rng) -> #(Int, Rng) {
  let state = int.bitwise_and(rng.state * multiplier + 0xB, mask)
  #(int.bitwise_shift_right(state, 17), Rng(state))
}

/// 0 to `n - 1`.
fn below(rng: Rng, n: Int) -> #(Int, Rng) {
  let #(x, rng) = next(rng)
  #(x % n, rng)
}

fn chance(rng: Rng, percent: Int) -> #(Bool, Rng) {
  let #(x, rng) = below(rng, 100)
  #(x < percent, rng)
}

fn pick(rng: Rng, items: List(a)) -> #(a, Rng) {
  let #(index, rng) = below(rng, list.length(items))
  let assert Ok(item) = list.first(list.drop(items, index))
  #(item, rng)
}

/// `count` of something, each made from the generator as it stands.
fn many(
  rng: Rng,
  count: Int,
  make: fn(Rng, Int) -> #(a, Rng),
) -> #(List(a), Rng) {
  let #(made, rng) =
    upto(count)
    |> list.fold(#([], rng), fn(acc, index) {
      let #(made, rng) = acc
      let #(item, rng) = make(rng, index)
      #([item, ..made], rng)
    })
  #(list.reverse(made), rng)
}

/// 0 to `count - 1`.
fn upto(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index })
}

/// Some of `items`, in a shuffled order.
fn some_of(rng: Rng, items: List(a), percent: Int) -> #(List(a), Rng) {
  let #(kept, rng) =
    list.fold(items, #([], rng), fn(acc, item) {
      let #(kept, rng) = acc
      let #(keep, rng) = chance(rng, percent)
      let #(key, rng) = next(rng)
      case keep {
        True -> #([#(key, item), ..kept], rng)
        False -> #(kept, rng)
      }
    })
  #(
    list.sort(kept, fn(a, b) { int.compare(a.0, b.0) })
      |> list.map(fn(pair) { pair.1 }),
    rng,
  )
}

// --- An account ----------------------------------------------------------------

/// What the dispatcher holds an agent in, apart from their phones.
type Held {
  NotHeld
  InAnOffer
  InWrapup
  DelayedAfterAMiss
}

type Agent {
  Agent(
    id: String,
    availability: Availability,
    activity: Activity,
    held: Held,
    free_since: Int,
    answered: Int,
    talk_time_s: Int,
    missed: Int,
    last_call_end: Option(Int),
  )
}

type Account {
  Account(
    seed: Int,
    agents: Dict(String, Agent),
    queues: List(#(QueueSettings, doc.Value)),
    callers: List(Wait),
  )
}

fn account(seed: Int) -> Account {
  let rng = seeded(seed)
  let #(agent_count, rng) = below(rng, 10)
  let #(agents, rng) = many(rng, agent_count + 1, agent)
  let #(queue_count, rng) = below(rng, 3)
  let #(queues, rng) =
    many(rng, queue_count + 1, fn(rng, index) { queue(rng, index, agents) })
  let #(caller_count, rng) = below(rng, 12)
  let #(callers, _rng) =
    many(rng, caller_count, fn(rng, index) { caller(rng, index, queues) })
  Account(
    seed: seed,
    agents: dict.from_list(list.map(agents, fn(agent) { #(agent.id, agent) })),
    queues: queues,
    callers: callers,
  )
}

fn agent(rng: Rng, index: Int) -> #(Agent, Rng) {
  let #(availability, rng) =
    pick(rng, [Available, Available, AvailableOnDemand, OnBreak, LoggedOut])
  let #(activity, rng) =
    pick(rng, [
      Idle,
      Idle,
      Idle,
      Ringing,
      OnCall(queue_call: True),
      OnCall(queue_call: False),
      WrappingUp,
    ])
  let #(held, rng) =
    pick(rng, [
      NotHeld,
      NotHeld,
      NotHeld,
      NotHeld,
      InAnOffer,
      InWrapup,
      DelayedAfterAMiss,
    ])
  let #(idle_for, rng) = below(rng, 600)
  let #(answered, rng) = below(rng, 8)
  let #(talk_time_s, rng) = below(rng, 3600)
  let #(missed, rng) = below(rng, 3)
  let #(ended, rng) = chance(rng, 50)
  #(
    Agent(
      id: "agent" <> string.pad_start(int.to_string(index), 2, "0"),
      availability: availability,
      activity: activity,
      held: held,
      free_since: now - idle_for,
      answered: answered,
      talk_time_s: talk_time_s,
      missed: missed,
      last_call_end: case ended {
        True -> Some(now - idle_for)
        False -> None
      },
    ),
    rng,
  )
}

fn queue(
  rng: Rng,
  index: Int,
  agents: List(Agent),
) -> #(#(QueueSettings, doc.Value), Rng) {
  let id = "queue" <> int.to_string(index)
  let #(strategy_name, rng) = pick(rng, strategy.names())
  let #(ring_simultaneously, rng) = below(rng, 3)
  let #(skip_external, rng) = chance(rng, 50)
  let #(apply, rng) = chance(rng, 60)
  let #(wait_seconds, rng) = below(rng, 90)
  let #(multiply, rng) = chance(rng, 30)
  let #(no_agent_no_wait, rng) = chance(rng, 50)
  let #(system_base, rng) = chance(rng, 50)
  let #(members, rng) = some_of(rng, agents, 70)
  let #(entries, rng) =
    list.fold(members, #([], rng), fn(acc, agent) {
      let #(entries, rng) = acc
      let #(level, rng) = below(rng, 3)
      let #(position, rng) = below(rng, 5)
      #(
        [
          doc.object([
            #("id", doc.String(agent.id)),
            #("level", doc.Int(level + 1)),
            #("position", doc.Int(position + 1)),
          ]),
          ..entries
        ],
        rng,
      )
    })
  let document =
    doc.object([
      #("name", doc.String(id)),
      #("strategy", doc.String(strategy_name)),
      #("ring_simultaneously", doc.Int(ring_simultaneously + 1)),
      #("skip_agents_with_external_calls", doc.Bool(skip_external)),
      #(
        "time_base_score",
        doc.String(case system_base {
          True -> "system"
          False -> "queue"
        }),
      ),
      #(
        "tier_rules",
        doc.object([
          #("apply", doc.Bool(apply)),
          #("wait_seconds", doc.Int(wait_seconds)),
          #("wait_multiply_level", doc.Bool(multiply)),
          #("no_agent_no_wait", doc.Bool(no_agent_no_wait)),
        ]),
      ),
      #("agents", doc.List(entries)),
    ])
  let settings = settings.queue(id, document, 30, "on_break")
  // Round robin's cursor, as earlier passes left it.
  let #(recent, rng) = some_of(rng, members, 50)
  let memo = case strategy_name {
    "round_robin" ->
      doc.object([
        #(
          "recent",
          doc.List(list.map(recent, fn(agent) { doc.String(agent.id) })),
        ),
      ])
    _ -> doc.object([])
  }
  #(#(settings, memo), rng)
}

fn caller(
  rng: Rng,
  index: Int,
  queues: List(#(QueueSettings, doc.Value)),
) -> #(Wait, Rng) {
  let #(#(settings, _memo), rng) = pick(rng, queues)
  let #(priority, rng) = below(rng, 3)
  let #(waited, rng) = below(rng, 240)
  let #(stamped, rng) = chance(rng, 30)
  let #(earlier, rng) = below(rng, 120)
  let #(tried_some, rng) = chance(rng, 25)
  let #(tried, rng) =
    some_of(rng, list.map(settings.tiers, fn(tier) { tier.agent_id }), 50)
  let member =
    cluster.member(
      "call" <> string.pad_start(int.to_string(index), 2, "0"),
      settings.id,
      priority,
      now - waited,
    )
  let member = case stamped {
    True ->
      cluster.with_call_var(
        member,
        "Queue-System-Joined",
        now - waited - earlier,
      )
    False -> member
  }
  #(
    Wait(
      member: member,
      position: 0,
      announced_at: 0,
      rerun: False,
      tried: case tried_some {
        True -> tried
        False -> []
      },
    ),
    rng,
  )
}

// --- Reading it, as `view.snapshot` does ----------------------------------------

/// This queue's view of an agent, as `view.tier_state` derives it.
fn tier_state(agent: Agent, settings: QueueSettings) -> TierState {
  case agent.held {
    InAnOffer -> types.Offering
    InWrapup -> Standby
    DelayedAfterAMiss -> NoAnswer
    NotHeld ->
      case agent.activity {
        OnCall(queue_call: True) -> ActiveInbound
        OnCall(queue_call: False) ->
          case settings.skip_external_calls {
            True -> ActiveInbound
            False -> Ready
          }
        Ringing -> types.Offering
        WrappingUp -> Standby
        Idle -> Ready
      }
  }
}

fn snapshot(account: Account) -> plan.Snapshot {
  let waiting_in = fn(queue_id) {
    list.count(account.callers, fn(wait) { wait.member.queue_id == queue_id })
  }
  let queues =
    account.queues
    |> list.filter(fn(queue) { waiting_in({ queue.0 }.id) > 0 })
    |> list.map(fn(queue) {
      let #(settings, memo) = queue
      let states =
        list.map(settings.tiers, fn(tier) {
          let assert Ok(agent) = dict.get(account.agents, tier.agent_id)
          #(tier, agent, tier_state(agent, settings))
        })
      let ready =
        list.filter_map(states, fn(entry) {
          let #(tier, agent, state) = entry
          case state == Ready && availability.taking_calls(agent.availability) {
            True -> Ok(tier.agent_id)
            False -> Error(Nil)
          }
        })
      let views = case ready {
        [] -> []
        _ ->
          list.map(states, fn(entry) {
            let #(tier, agent, state) = entry
            AgentView(
              agent_id: agent.id,
              availability: agent.availability,
              activity: agent.activity,
              level: tier.level,
              position: tier.position,
              tier_state: state,
              last_call_end: agent.last_call_end,
              free_since: agent.free_since,
              answered: agent.answered,
              talk_time_s: agent.talk_time_s,
              missed: agent.missed,
            )
          })
      }
      let selectable = set.from_list(ready)
      #(
        settings.id,
        plan.Queue(
          settings: settings,
          shown: strategy.QueueState(
            account_id: cluster.account_id,
            queue_id: settings.id,
            strategy: settings.strategy.name,
            skip_external_calls: settings.skip_external_calls,
            ring_simultaneously: settings.ring_simultaneously,
            memo: memo,
          ),
          views: views,
          ready: ready,
          selectable: selectable,
          free: set.size(selectable),
        ),
      )
    })
  plan.Snapshot(now: now, queues: dict.from_list(queues), offered: set.new())
}

/// The account's callers in the order a pass takes them.
fn ordered(account: Account) -> List(Wait) {
  let system_base =
    dict.from_list(
      list.map(account.queues, fn(queue) {
        #({ queue.0 }.id, { queue.0 }.time_base_system)
      }),
    )
  waiting.order(account.callers, fn(queue_id) {
    dict.get(system_base, queue_id) |> result_or(True)
  })
}

fn result_or(result: Result(a, Nil), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

// --- What a pass promises, restated -----------------------------------------

/// Whether an agent could take a caller of this queue now: ready in it as
/// the pass began, taking calls, and not rung by this pass yet.
fn could_take(queue: plan.Queue, rung: Set(String), view: AgentView) -> Bool {
  set.contains(queue.selectable, view.agent_id)
  && !set.contains(rung, view.agent_id)
  && {
    view.availability == Available || view.availability == AvailableOnDemand
  }
  && view.tier_state == Ready
}

/// The levels a caller who has waited `waited` seconds is offered to: every
/// level from the lowest up, each once its wait is over, or at once when
/// nobody at the levels already admitted could take them and the queue says
/// not to wait for nobody; stopping at the first level that is neither.
fn admitted_levels(
  rules: tiers.Rules,
  views: List(AgentView),
  waited: Int,
  could: fn(AgentView) -> Bool,
) -> List(Int) {
  let levels =
    list.map(views, fn(view) { view.level })
    |> list.unique
    |> list.sort(int.compare)
  case rules.apply, levels {
    False, _ -> levels
    True, [] -> []
    True, [lowest, ..] ->
      list.fold_until(levels, [], fn(admitted, level) {
        let wait = case level <= lowest, rules.wait_multiply_level {
          True, _ -> 0
          False, True -> rules.wait_seconds * level
          False, False -> rules.wait_seconds
        }
        let nobody_so_far =
          !list.any(views, fn(view) {
            list.contains(admitted, view.level) && could(view)
          })
        case waited >= wait || { rules.no_agent_no_wait && nobody_so_far } {
          True -> list.Continue([level, ..admitted])
          False -> list.Stop(admitted)
        }
      })
  }
}

/// Everybody who could take this caller at this point in the pass.
fn candidates(
  queue: plan.Queue,
  rung: Set(String),
  wait: Wait,
) -> List(AgentView) {
  let waited =
    now - waiting.score_base(wait.member, queue.settings.time_base_system)
  let could = fn(view) { could_take(queue, rung, view) }
  let levels = admitted_levels(queue.settings.rules, queue.views, waited, could)
  list.filter(queue.views, fn(view) {
    list.contains(levels, view.level) && could(view)
  })
}

fn ids(views: List(AgentView)) -> List(String) {
  list.map(views, fn(view) { view.agent_id }) |> list.unique
}

fn same_set(left: List(String), right: List(String)) -> Bool {
  list.sort(list.unique(left), string.compare)
  == list.sort(list.unique(right), string.compare)
}

fn fail(account: Account, what: String) -> a {
  panic as { "seed " <> int.to_string(account.seed) <> ": " <> what }
}

/// Plan the account and hold the plan to every promise.
/// How many offers, agents rung and callers passed over.
fn check(account: Account) -> #(Int, Int, Int) {
  let snapshot = snapshot(account)
  let callers = ordered(account)
  let planned = plan.plan(snapshot, callers)
  let by_call =
    dict.from_list(
      list.map(planned, fn(p: plan.Planned) { #(p.wait.member.call_id, p) }),
    )

  // The plan is in the pass's order.
  let planned_order = list.map(planned, fn(p) { p.wait.member.call_id })
  let caller_order =
    list.filter_map(callers, fn(wait) {
      case dict.has_key(by_call, wait.member.call_id) {
        True -> Ok(wait.member.call_id)
        False -> Error(Nil)
      }
    })
  case planned_order == caller_order {
    True -> Nil
    False -> fail(account, "the plan is out of the callers' order")
  }

  let #(rung, passed_over) =
    list.fold(callers, #(set.new(), []), fn(acc, wait) {
      let #(rung, passed_over) = acc
      let call_id = wait.member.call_id
      let assert Ok(queue) = dict.get(snapshot.queues, wait.member.queue_id)
      let could = candidates(queue, rung, wait)
      case dict.get(by_call, call_id) {
        Error(Nil) -> {
          // Nobody offered: nobody could have been.
          case could {
            [] -> Nil
            _ ->
              fail(
                account,
                call_id
                  <> " was passed over with "
                  <> string.join(ids(could), ",")
                  <> " free for them",
              )
          }
          #(rung, [#(call_id, queue.settings.id, could), ..passed_over])
        }
        Ok(offer) -> {
          let ringing = settings.ringing(offer.offer, offer.settings)
          let untried =
            list.filter(could, fn(view) {
              !list.contains(wait.tried, view.agent_id)
            })
          case ringing, list.unique(ringing) == ringing {
            [], _ -> fail(account, call_id <> " was offered to nobody")
            _, False -> fail(account, call_id <> " rings an agent twice")
            _, True -> Nil
          }
          list.each(ringing, fn(agent_id) {
            case set.contains(rung, agent_id) {
              True ->
                fail(
                  account,
                  agent_id <> " is rung twice, again for " <> call_id,
                )
              False -> Nil
            }
            case list.contains(ids(could), agent_id) {
              True -> Nil
              False ->
                fail(
                  account,
                  agent_id
                    <> " is rung for "
                    <> call_id
                    <> " and could not take them",
                )
            }
          })
          case offer.offer, queue.settings.strategy.name {
            Simultaneous(all), "ring_all" ->
              case same_set(all, ids(could)) {
                True -> Nil
                False ->
                  fail(
                    account,
                    call_id <> ": ring-all did not ring everybody free",
                  )
              }
            Sequential(order), name if name != "ring_all" -> {
              let expected = case untried {
                [] -> could
                _ -> untried
              }
              case same_set(order, ids(expected)) {
                True -> Nil
                False ->
                  fail(
                    account,
                    call_id
                      <> ": "
                      <> name
                      <> " offered "
                      <> string.join(order, ",")
                      <> " for "
                      <> string.join(ids(expected), ","),
                  )
              }
              let levels =
                list.map(order, fn(agent_id) { level_of(queue, agent_id) })
              case levels == list.sort(levels, int.compare) {
                True -> Nil
                False ->
                  fail(
                    account,
                    call_id <> ": " <> name <> " is not level first",
                  )
              }
            }
            _, name ->
              fail(account, call_id <> ": the wrong kind of offer for " <> name)
          }
          #(list.fold(ringing, rung, set.insert), passed_over)
        }
      }
    })

  // The same promise from the other side, as the queue sees it: a caller of
  // a queue left unoffered could have taken none of the agents a later
  // caller of that queue was rung.
  list.each(planned, fn(p: plan.Planned) {
    let ringing = settings.ringing(p.offer, p.settings)
    list.each(passed_over, fn(passed) {
      let #(_call_id, queue_id, could) = passed
      case queue_id == p.wait.member.queue_id {
        False -> Nil
        True ->
          case list.any(ringing, list.contains(ids(could), _)) {
            False -> Nil
            True ->
              fail(
                account,
                "a later caller took an agent an earlier one could have had",
              )
          }
      }
    })
  })

  #(list.length(planned), set.size(rung), list.length(passed_over))
}

fn level_of(queue: plan.Queue, agent_id: String) -> Int {
  let assert Ok(view) =
    list.find(queue.views, fn(view: AgentView) { view.agent_id == agent_id })
  view.level
}

// --- The cases -----------------------------------------------------------------

pub fn random_accounts_keep_every_promise_test() {
  let #(offers, rung, passed_over) =
    upto(cases)
    |> list.map(fn(index) { index + 1 })
    |> list.fold(#(0, 0, 0), fn(totals, seed) {
      let #(offers, rung, passed_over) = check(account(seed))
      #(totals.0 + offers, totals.1 + rung, totals.2 + passed_over)
    })
  // The accounts both offer and pass callers over, often, or the promises
  // above hold for want of anything to hold them to.
  assert offers > cases / 2
  assert passed_over > cases / 2
  assert rung > offers
}

/// Every strategy is exercised, with somebody to offer, over the seeds.
pub fn every_strategy_is_planned_test() {
  let planned =
    upto(cases)
    |> list.map(fn(index) { index + 1 })
    |> list.flat_map(fn(seed) {
      let account = account(seed)
      plan.plan(snapshot(account), ordered(account))
      |> list.map(fn(p: plan.Planned) { p.settings.strategy.name })
    })
    |> list.unique
  assert same_set(planned, strategy.names())
}

/// The generator is the generator: the same seed is the same account.
pub fn a_seed_is_one_account_test() {
  assert check(account(42)) == check(account(42))
  let first = account(7)
  let again = account(7)
  assert list.map(first.callers, fn(wait) { wait.member.call_id })
    == list.map(again.callers, fn(wait) { wait.member.call_id })
}
