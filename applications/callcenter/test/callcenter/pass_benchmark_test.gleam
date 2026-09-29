//// What one dispatch pass costs on a large account: 500 agents across five
//// queues whose tiers overlap, and 200 callers waiting, with every agent
//// busy, ten of them free, and all of them free. Then two accounts of one
//// queue each: 500 agents of a round robin queue, nearly all of them free,
//// for 200 callers; and 200 agents who never logged in, with their phones
//// idle, and five callers waiting after hours, where what is counted is the
//// datastore reads a pass makes.
////
//// The pass is run directly on a dispatcher state built here, against the
//// fake datastore and the fake activity and offer processes, and timed. The
//// callers have already been told where they stand, by a pass with every
//// agent busy, so what is timed is the pass the one-second tick and every
//// message run and not the first one, whose `member_position` for every
//// caller costs the same however the pass decides. The timings are printed
//// and only a generous bound is asserted, so a slow machine does not fail
//// the suite; what is asserted exactly is what the pass decided, which must
//// not depend on how it is computed.

import callcenter/activity
import callcenter/dispatcher/config
import callcenter/dispatcher/pass
import callcenter/dispatcher/plan
import callcenter/dispatcher/settings
import callcenter/dispatcher/state.{type State, State, Wait}
import callcenter/presence
import callcenter/queue_doc
import callcenter/types.{type Activity, Member, OnCall}
import gleam/dict
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/string
import kazoo/doc
import kazoo/kazoo.{type Kazoo, Kazoo}
import kazoo/testing/fake
import support/cluster
import support/fake_activity
import support/fake_calls
import support/fake_offer

const agents = 500

const queues = 5

const callers = 200

/// An account of its own: the activity actor is one per node, and the offers
/// this sends mark agents offering in it.
const account_id = "be7c4a3d2e1f00112233445566778899"

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

fn microseconds() -> Int {
  monotonic_time(atom.create("microsecond"))
}

fn agent_id(index: Int) -> String {
  "agent" <> string.pad_start(int.to_string(index), 3, "0")
}

fn queue_id(index: Int) -> String {
  "queue" <> int.to_string(index)
}

// --- The accounts ----------------------------------------------------------

/// The account a mix runs on.
type Account {
  Account(
    agents: Int,
    queues: List(doc.Value),
    callers: Int,
    /// The queue caller `n` waits in.
    queue_of: fn(Int) -> String,
    /// Whether the agents have an availability document. One who never
    /// logged in has none.
    logged_in: Bool,
  )
}

/// Five queues whose tiers overlap.
fn overlapping() -> Account {
  Account(
    agents: agents,
    queues: upto(queues) |> list.map(queue_document),
    callers: callers,
    queue_of: fn(caller) { queue_id(caller % queues) },
    logged_in: True,
  )
}

/// One queue with every agent of the account in it, over three levels.
fn one_queue(agents: Int, strategy: String, logged_in: Bool) -> Account {
  Account(
    agents: agents,
    queues: [
      queue_with(
        "only",
        strategy,
        doc.object([]),
        upto(agents) |> list.map(fn(agent) { tier(agent, 1 + agent % 3) }),
      ),
    ],
    callers: callers,
    queue_of: fn(_caller) { "only" },
    logged_in: logged_in,
  )
}

/// Each agent is in two neighbouring queues, a level 1 tier in one and a
/// level 2 tier in the next, so every queue has 200 agents and every agent
/// is wanted by two queues.
fn tiers_of(queue: Int) -> List(doc.Value) {
  upto(agents)
  |> list.filter_map(fn(agent) {
    let home = agent % queues
    let next = { agent + 1 } % queues
    case queue == home, queue == next {
      True, _ -> Ok(tier(agent, 1))
      _, True -> Ok(tier(agent, 2))
      _, _ -> Error(Nil)
    }
  })
}

fn tier(agent: Int, level: Int) -> doc.Value {
  doc.object([
    #("id", doc.String(agent_id(agent))),
    #("level", doc.Int(level)),
    #("position", doc.Int(agent % 17)),
  ])
}

/// Every strategy but one, and tier rules on two queues.
fn queue_document(queue: Int) -> doc.Value {
  let strategy = case queue {
    0 -> "longest_idle"
    1 -> "round_robin"
    2 -> "ring_all"
    3 -> "sequential"
    _ -> "fewest_calls"
  }
  let rules = case queue {
    0 | 3 ->
      doc.object([
        #("apply", doc.Bool(True)),
        #("wait_seconds", doc.Int(60)),
        #("no_agent_no_wait", doc.Bool(True)),
      ])
    _ -> doc.object([])
  }
  queue_with(queue_id(queue), strategy, rules, tiers_of(queue))
}

fn queue_with(
  id: String,
  strategy: String,
  rules: doc.Value,
  tiers: List(doc.Value),
) -> doc.Value {
  doc.object([
    #("_id", doc.String(id)),
    #("name", doc.String(id)),
    #("strategy", doc.String(strategy)),
    #("tier_rules", rules),
    #("agents", doc.List(tiers)),
  ])
}

/// The user behind each tier: a free agent is read to see that they are
/// still there and enabled, as a pass on a node reads them.
fn user_document(agent: Int) -> doc.Value {
  doc.object([
    #("_id", doc.String(agent_id(agent))),
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object([#("max_no_answer", doc.Int(0))])),
  ])
}

fn agent_document(agent: Int) -> doc.Value {
  doc.object([
    #("_id", doc.String("callcenter_agent-" <> agent_id(agent))),
    #("pvt_type", doc.String("callcenter_agent")),
    #("agent_id", doc.String(agent_id(agent))),
    #("availability", doc.String("available")),
    #("timestamp", doc.Int(cluster.start_of_time + { agent * 7 } % 500)),
    #("source", doc.String("ui")),
    #(
      "counters",
      doc.object([
        #("calls_answered", doc.Int(agent % 11)),
        #("talk_time_s", doc.Int(agent * 13 % 900)),
      ]),
    ),
  ])
}

// --- Counting reads --------------------------------------------------------

type Counters

@external(erlang, "counters", "new")
fn counters_new(size: Int, options: List(Atom)) -> Counters

@external(erlang, "counters", "add")
fn counters_add(counters: Counters, index: Int, increment: Int) -> Atom

@external(erlang, "counters", "get")
fn counters_get(counters: Counters, index: Int) -> Int

@external(erlang, "counters", "put")
fn counters_put(counters: Counters, index: Int, value: Int) -> Atom

/// Every datastore read the dispatcher makes, and of them the reads of an
/// availability document. The fake has no cache, so each is a read a node
/// makes too: of its document cache, or of the database for a document the
/// cache does not hold -- which is every one that does not exist.
type Reads {
  Reads(counters: Counters)
}

fn new_reads() -> Reads {
  Reads(counters_new(2, []))
}

fn counted(kz: Kazoo, reads: Reads) -> Kazoo {
  let datamgr = kz.datamgr
  let read = fn(id: String) {
    counters_add(reads.counters, 1, 1)
    case string.starts_with(id, "callcenter_agent-") {
      True -> counters_add(reads.counters, 2, 1)
      False -> atom.create("ok")
    }
  }
  Kazoo(
    ..kz,
    datamgr: kazoo.Datamgr(
      ..datamgr,
      open_cache_doc: fn(db, id) {
        read(id)
        datamgr.open_cache_doc(db, id)
      },
      open_doc: fn(db, id) {
        read(id)
        datamgr.open_doc(db, id)
      },
      get_results: fn(db, view, options) {
        read("")
        datamgr.get_results(db, view, options)
      },
    ),
  )
}

/// Every read since the count last started, and the availability documents
/// among them; and the count starts again.
fn taken(reads: Reads) -> #(Int, Int) {
  let all = counters_get(reads.counters, 1)
  let availability = counters_get(reads.counters, 2)
  counters_put(reads.counters, 1, 0)
  counters_put(reads.counters, 2, 0)
  #(all, availability)
}

// --- The dispatcher --------------------------------------------------------

fn setup(free: Int) -> State {
  setup_on(overlapping(), busy_from(agents, free), new_reads())
}

/// A dispatcher over the account with its callers waiting, every one of
/// them told where they stand by a pass with every agent busy, and then the
/// agents doing `activities`.
fn setup_on(
  account: Account,
  activities: List(#(String, Activity)),
  reads: Reads,
) -> State {
  let datastore = fake.new_with_views(cluster.views())
  fake.put_account(datastore, account_id, "queues.example.com", [])
  fake.set_now(datastore, cluster.start_of_time + 600)
  let db = kazoo.account_db(account_id)
  list.each(account.queues, fn(queue) { fake.put_doc(datastore, db, queue) })
  upto(account.agents)
  |> list.each(fn(agent) {
    case account.logged_in {
      True -> fake.put_doc(datastore, db, agent_document(agent))
      False -> Nil
    }
    fake.put_doc(datastore, db, user_document(agent))
  })
  queue_doc.reset()
  let kz = counted(fake.kazoo(datastore), reads)
  let fake_activities = fake_activity.new()
  fake_activity.agents(fake_activities, busy_from(account.agents, 0))
  let offers = fake_offer.new()
  let waiting =
    upto(account.callers)
    |> list.map(fn(caller) {
      let member =
        Member(
          ..cluster.member(
            "call" <> string.pad_start(int.to_string(caller), 3, "0"),
            account.queue_of(caller),
            caller % 3,
            cluster.start_of_time + caller * 2,
          ),
          account_id: account_id,
        )
      #(
        member.call_id,
        Wait(member: member, position: 0, announced_at: 0, tried: []),
      )
    })
    |> dict.from_list
  let state =
    State(
      config: config.Config(
        kz: kz,
        account_id: account_id,
        announce_interval_s: 30,
        offer_grace_s: 5,
        default_no_answer_status: "on_break",
        queue_refresh_s: queue_doc.default_refresh_s,
        now: kz.now,
        settle: fn(_member) { Nil },
        lamp: fn(_agent_id, _state) { Nil },
        activity: fake_activity.reader(fake_activities),
        calls: fake_calls.nothing(),
        fresh: fn() { True },
      ),
      ticks: process.new_subject(),
      replies: process.new_subject(),
      start_offer: fake_offer.start_offer(offers),
      waiting: waiting,
      offers: dict.new(),
      actors: dict.new(),
      presenting: dict.new(),
      departing: dict.new(),
      pickups: dict.new(),
      busy: dict.new(),
      delayed: dict.new(),
      wrapup: dict.new(),
      stood_down: dict.new(),
      no_document: dict.new(),
      misses: dict.new(),
      memo: dict.new(),
      worked: dict.new(),
      stats: dict.new(),
      lamps: presence.lamps(),
      ticking: True,
      listening: None,
      activities: state.Read(dict.new()),
      sync: state.Synced,
      watch_activity: fn() { Nil },
    )
  // Every caller told where they stand, and then the agents as the mix has
  // them.
  let state = pass.run(state)
  fake_activity.agents(fake_activities, activities)
  state
}

/// Every one of `count` agents from `free` on is on a queue call.
fn busy_from(count: Int, free: Int) -> List(#(String, Activity)) {
  upto(count)
  |> list.filter_map(fn(agent) {
    case agent < free {
      True -> Error(Nil)
      False -> Ok(#(agent_id(agent), on_call()))
    }
  })
}

fn on_call() -> Activity {
  OnCall(queue_call: True)
}

/// What a pass decided: every offer, by caller, with who it rings.
fn decided(state: State) -> List(String) {
  dict.to_list(state.offers)
  |> list.map(fn(entry) {
    let #(call_id, offer) = entry
    call_id <> ":" <> string.join(offer.agents, ",")
  })
  |> list.sort(string.compare)
}

/// Time the pass, best of `runs`: the state is a value, so each run starts
/// from the same one.
fn timed(name: String, free: Int, runs: Int) -> State {
  timed_on(name, agents, callers, setup(free), runs)
}

fn timed_on(
  name: String,
  agents: Int,
  callers: Int,
  before: State,
  runs: Int,
) -> State {
  let #(best, after) = best_of(runs, fn() { pass.run(before) })
  io.println(
    "\npass over "
    <> int.to_string(agents)
    <> " agents and "
    <> int.to_string(callers)
    <> " callers, "
    <> name
    <> ": "
    <> milliseconds(best)
    <> " ms, "
    <> int.to_string(dict.size(after.offers))
    <> " offers, digest "
    <> int.to_string(digest(decided(after))),
  )
  // Generous, so that a loaded machine does not fail the suite. Most of a
  // pass that offers is the offers, whose events and records cost what they
  // cost against the fakes; the decision is bounded on its own below.
  assert best < 5_000_000
  // One pass never offers the same agent twice.
  let rung =
    list.flat_map(dict.values(after.offers), fn(offer) { offer.agents })
  assert list.length(rung) == list.length(list.unique(rung))
  // The decision on its own, from the same reading and with nothing sent,
  // is what the pass sent.
  let #(best, planned) = best_of(3, fn() { pass.preview(before) })
  io.println("  reading and planning alone: " <> milliseconds(best) <> " ms")
  // Tens of milliseconds at most on a development machine, and a shared CI
  // runner takes several times that, so this bound is generous too. The
  // printed figure is the one to watch: reading and viewing every agent
  // again for every caller multiplies it.
  assert best < 1_000_000
  assert list.map(planned, fn(planned: plan.Planned) {
      planned.wait.member.call_id
      <> ":"
      <> string.join(settings.ringing(planned.offer, planned.settings), ",")
    })
    |> list.sort(string.compare)
    == decided(after)
  activity.forget(account_id)
  after
}

/// The quickest of `runs` runs, in microseconds, and what the first gave.
fn best_of(runs: Int, run: fn() -> a) -> #(Int, a) {
  let assert [first, ..rest] =
    upto(runs)
    |> list.map(fn(_run) {
      let started = microseconds()
      let result = run()
      #(microseconds() - started, result)
    })
  #(list.fold(rest, first.0, fn(best, run) { int.min(best, run.0) }), first.1)
}

fn milliseconds(microseconds: Int) -> String {
  int.to_string(microseconds / 1000)
  <> "."
  <> int.to_string(microseconds % 1000 / 100)
}

@external(erlang, "erlang", "phash2")
fn digest(term: a) -> Int

pub fn all_agents_busy_pass_test() {
  let after = timed("all agents busy", 0, 3)
  assert dict.size(after.offers) == 0
}

pub fn ten_agents_free_pass_test() {
  let after = timed("ten agents free", 10, 3)
  assert decided(after)
    == [
      "call002:agent002,agent007,agent001,agent006", "call005:agent000",
      "call008:agent003", "call011:agent005", "call014:agent004",
      "call020:agent009", "call023:agent008",
    ]
}

/// What the pass decided before it was planned, as `digest` has it: a
/// change here is a change in who is offered to whom.
pub fn all_agents_free_pass_test() {
  let after = timed("all agents free", agents, 1)
  assert dict.size(after.offers) == 161
  assert digest(decided(after)) == 43_162_496
}

/// A round robin queue of 500 agents, all but every tenth of them free, and
/// 200 callers: the strategy is asked once a caller, over every agent of
/// the queue each time.
pub fn round_robin_mostly_free_pass_test() {
  let before =
    setup_on(
      one_queue(agents, "round_robin", True),
      upto(agents)
        |> list.filter(fn(agent) { agent % 10 == 0 })
        |> list.map(fn(agent) { #(agent_id(agent), on_call()) }),
      new_reads(),
    )
  let after =
    timed_on("round robin, nearly all free", agents, callers, before, 1)
  assert dict.size(after.offers) == callers
  assert digest(decided(after)) == 23_280_569
}

/// 200 agents who never logged in, whose phones are idle, and five callers
/// waiting after hours. A pass runs at least once a second while anybody
/// waits, so what a pass reads it reads every second: an agent with no
/// document is read from the database, the data layer caching no answer for
/// a document that does not exist. The dispatcher remembers the answer
/// instead, and the passes after the first read none of them.
pub fn agents_never_logged_in_pass_test() {
  let reads = new_reads()
  let account = Account(..one_queue(200, "longest_idle", False), callers: 5)
  let before = setup_on(account, [], reads)
  let _setup = taken(reads)
  // The first pass that finds their phones idle reads them.
  let first = pass.run(before)
  let #(all, availability) = taken(reads)
  io.println(
    "\n200 agents never logged in, 5 callers, the first pass: "
    <> int.to_string(all)
    <> " reads, "
    <> int.to_string(availability)
    <> " of them availability documents",
  )
  assert availability == 200
  let #(best, after) = best_of(3, fn() { pass.run(first) })
  let #(all, availability) = taken(reads)
  io.println(
    "  each pass after it: "
    <> int.to_string(all / 3)
    <> " reads, "
    <> int.to_string(availability / 3)
    <> " of them availability documents, "
    <> milliseconds(best)
    <> " ms",
  )
  assert dict.size(after.offers) == 0
  assert availability == 0
  activity.forget(account_id)
}

/// 0 to `count - 1`.
fn upto(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index })
}
