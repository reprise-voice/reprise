//// A dispatcher with no broker, no switch and no clock of its own.
////
//// Everything a dispatcher talks to is a value it was given: the datastore
//// is `kazoo/testing/fake`, the clock is that fake's, the callers' actors
//// are `test/support/fake_calls` and the offers they ring
//// `test/support/fake_offer`, and settling a caller is a function that
//// counts instead of acking a message that never came off a broker. What is
//// left is the actor itself, which is the part worth testing.

import callcenter/activity
import callcenter/ask
import callcenter/dispatcher
import callcenter/dispatcher/config as dispatcher_config
import callcenter/dispatcher/settings
import callcenter/queue_doc
import callcenter/records
import callcenter/types.{type Member, Member}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/listener.{type Delivery}
import kazoo/modb
import kazoo/testing/fake
import kazoo/util
import support/fake_activity.{type Fake as Activities}
import support/fake_calls.{type Fake as Calls}
import support/fake_offer.{type Fake as Offers}

pub const account_id = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

/// Gregorian seconds, somewhere in 2026, so that the arithmetic in a failure
/// message is readable.
pub const start_of_time = 63_800_000_000

pub type Cluster {
  Cluster(
    fake: fake.Fake,
    kz: Kazoo,
    offers: Offers,
    /// What the dispatcher told the callers' actors.
    calls: Calls,
    dispatcher: Subject(dispatcher.Message),
    settled: Subject(Settled),
    lamps: Subject(Lit),
    /// What the agents' phones are doing, as the dispatcher reads it.
    activity: Activities,
    /// Every delivery settled, as the call id and which delivery it was.
    deliveries: Subject(Settled),
  )
}

// --- The lamp recorder -----------------------------------------------------

pub type Lit {
  Light(agent_id: String, state: String)
  Lights(done: Subject(List(#(String, String))))
}

fn lamp_recorder() -> Subject(Lit) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(state: List(#(String, String)), message: Lit) {
      case message {
        Light(agent_id, lit) ->
          actor.continue(list.append(state, [#(agent_id, lit)]))
        Lights(done) -> {
          process.send(done, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  started.data
}

/// Every login lamp state the dispatcher published, in order, as
/// `#(agent_id, dialog state)`.
pub fn lamps(cluster: Cluster) -> List(#(String, String)) {
  process.call(cluster.lamps, 5000, Lights)
}

// --- The settlement counter ------------------------------------------------

pub type Settled {
  Settle(call_id: String)
  Settlements(done: Subject(List(String)))
}

fn settlements() -> Subject(Settled) {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(state: List(String), message: Settled) {
      case message {
        Settle(call_id) -> actor.continue(list.append(state, [call_id]))
        Settlements(done) -> {
          process.send(done, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  started.data
}

/// Every caller settled, in the order they were, so that "exactly once" is a
/// statement about this list and not about a broker.
pub fn settled(cluster: Cluster) -> List(String) {
  process.call(cluster.settled, 5000, Settlements)
}

/// The same, naming the delivery each settlement was of: `<call> first` for
/// the delivery a caller arrived on, `<call> again` for one the broker had
/// handed out before. The shard settles only the delivery it holds, so a
/// settlement of the wrong one is no settlement at all.
pub fn settled_deliveries(cluster: Cluster) -> List(String) {
  process.call(cluster.deliveries, 5000, Settlements)
}

fn delivery_name(member: Member) -> String {
  case listener.redelivered(member.delivery) {
    True -> member.call_id <> " again"
    False -> member.call_id <> " first"
  }
}

// --- The dispatchers of earlier tests --------------------------------------

type Kept {
  /// Keep these dispatchers, and hand back the ones kept before.
  Swap(
    next: List(Subject(dispatcher.Message)),
    done: Subject(List(Subject(dispatcher.Message))),
  )
}

/// A test's dispatcher is not stopped when the test ends: there is nothing
/// to stop it. One with a caller left waiting ticks for the rest of the run,
/// reading the queue documents of an account every test here shares, and a
/// read at the wrong moment is another test's cache hit (the known
/// cross-test leak). So each cluster stops the one before it, first thing,
/// and only the last cluster of the run is left.
fn swap(next: List(Subject(dispatcher.Message))) -> Nil {
  let name = util.name("callcenter_test_dispatchers")
  let kept = case process.named(name) {
    Ok(_pid) -> process.named_subject(name)
    Error(Nil) -> {
      let assert Ok(started) =
        actor.new([])
        |> actor.on_message(fn(kept, message: Kept) {
          process.send(message.done, kept)
          actor.continue(message.next)
        })
        |> actor.named(name)
        |> actor.start
      started.data
    }
  }
  process.call(kept, 5000, Swap(next, _))
  |> list.each(fn(earlier) {
    let _ = ask.call(earlier, 1000, dispatcher.Stop)
    Nil
  })
}

// --- Building one ----------------------------------------------------------

/// A cluster with one account, the queue document given, and the agents
/// given as users with a `call_center` object.
pub fn new(
  queues: List(#(String, Value)),
  users: List(#(String, Value)),
) -> Cluster {
  new_with(queues, users, fn(kz) { kz })
}

/// The same, the dispatcher's data layer being the fake's as `through`
/// changes it: one that fails some reads, say. `Cluster.kz` is the fake's
/// own.
pub fn new_with(
  queues: List(#(String, Value)),
  users: List(#(String, Value)),
  through: fn(Kazoo) -> Kazoo,
) -> Cluster {
  build(queues, users, through, fn() { True })
}

/// The same, the dispatcher asking `fresh` whether it may still act for
/// its shard (`callcenter/stall`).
pub fn new_fenced(
  queues: List(#(String, Value)),
  users: List(#(String, Value)),
  fresh: fn() -> Bool,
) -> Cluster {
  build(queues, users, fn(kz) { kz }, fresh)
}

fn build(
  queues: List(#(String, Value)),
  users: List(#(String, Value)),
  through: fn(Kazoo) -> Kazoo,
  fresh: fn() -> Bool,
) -> Cluster {
  swap([])
  let fake = fake.new_with_views(views())
  fake.put_account(fake, account_id, "queues.example.com", [])
  fake.set_now(fake, start_of_time)
  list.each(queues, fn(entry) {
    fake.put_doc(
      fake,
      kazoo.account_db(account_id),
      doc.set(entry.1, ["_id"], doc.String(entry.0)),
    )
  })
  list.each(users, fn(entry) {
    fake.put_doc(
      fake,
      kazoo.account_db(account_id),
      doc.set(entry.1, ["_id"], doc.String(entry.0)),
    )
  })
  let kz = fake.kazoo(fake)
  // Every cluster starts its clock over, and the last database read of each
  // queue is remembered per node: forgotten here, or a queue read by the
  // previous test would be taken as read by this one. So is the last copy
  // of each queue kept for when the database does not answer.
  queue_doc.reset()
  settings.forget_kept()
  // The activity actor is one per node and this suite runs many dispatchers
  // through one node, so the account is forgotten before the next test's
  // dispatcher watches it again. The `of` call after it is a barrier: it is
  // a call from this process, so it cannot be answered until the forget it
  // follows has been handled.
  activity.forget(account_id)
  let _ = activity.of(account_id, "")
  let offers = fake_offer.new()
  let calls = fake_calls.new()
  let settled = settlements()
  let lamps = lamp_recorder()
  let activities = fake_activity.new()
  let deliveries = settlements()
  let assert Ok(started) =
    dispatcher.start(
      dispatcher_config.Config(
        kz: through(kz),
        account_id: account_id,
        announce_interval_s: 30,
        offer_grace_s: 5,
        default_no_answer_status: "on_break",
        queue_refresh_s: queue_doc.default_refresh_s,
        now: kz.now,
        settle: fn(member: Member) {
          process.send(settled, Settle(member.call_id))
          process.send(deliveries, Settle(delivery_name(member)))
        },
        lamp: fn(agent_id, state) {
          process.send(lamps, Light(agent_id, state))
        },
        activity: fake_activity.reader(activities),
        calls: fake_calls.calls(calls),
        fresh: fresh,
      ),
      start_offer: fake_offer.start_offer(offers),
    )
  swap([started.data])
  Cluster(
    fake: fake,
    kz: kz,
    offers: offers,
    calls: calls,
    dispatcher: started.data,
    settled: settled,
    lamps: lamps,
    activity: activities,
    deliveries: deliveries,
  )
}

/// Every caller whose ring the dispatcher called off, in order.
pub fn called_off(cluster: Cluster) -> List(String) {
  fake_calls.called_off(cluster.calls)
}

/// Every caller the dispatcher told their actor had joined, in order, and
/// whether they were resumed.
pub fn joined(cluster: Cluster) -> List(#(String, Bool)) {
  fake_calls.joined(cluster.calls)
}

/// Every caller taken out of a deleted queue, in order.
pub fn queue_gone(cluster: Cluster) -> List(String) {
  fake_calls.queue_gone(cluster.calls)
}

/// A member whose call names the control queue of the callflow holding it,
/// which is where a command for the call is sent.
pub fn with_control_queue(member: Member, control_queue: String) -> Member {
  Member(
    ..member,
    call: doc.set(member.call, ["Control-Queue"], doc.String(control_queue)),
  )
}

/// Replace a queue document, as a supervisor editing the queue does. The
/// dispatcher reads the queue again on every pass and the fake has no cache
/// -- the change notice an edit publishes has nothing to empty -- so the
/// change is in force for the next caller, as it is on a node that heard
/// the notice.
pub fn put_queue(cluster: Cluster, queue_id: String, document: Value) -> Nil {
  fake.put_doc(
    cluster.fake,
    kazoo.account_db(account_id),
    doc.set(document, ["_id"], doc.String(queue_id)),
  )
}

/// Move the clock.
pub fn at(cluster: Cluster, seconds: Int) -> Nil {
  fake.set_now(cluster.fake, start_of_time + seconds)
}

/// Set an agent's availability, without going through the datastore write
/// that `availability.set` does, because a test is about the dispatcher.
pub fn agent_is(
  cluster: Cluster,
  agent_id: String,
  availability: String,
) -> Nil {
  agent_since(cluster, agent_id, availability, 0)
}

/// The same, with the availability changed `seconds` into the test: a
/// login, or the end of a break, at that second.
pub fn agent_since(
  cluster: Cluster,
  agent_id: String,
  availability: String,
  seconds: Int,
) -> Nil {
  fake.put_doc(
    cluster.fake,
    kazoo.account_db(account_id),
    doc.object([
      #("_id", doc.String("callcenter_agent-" <> agent_id)),
      #("pvt_type", doc.String("callcenter_agent")),
      #("agent_id", doc.String(agent_id)),
      #("availability", doc.String(availability)),
      #("timestamp", doc.Int(start_of_time + seconds)),
      #("source", doc.String("ui")),
    ]),
  )
}

/// The availability the datastore holds for an agent, which is where
/// anything the dispatcher did to it lands.
pub fn availability(cluster: Cluster, agent_id: String) -> String {
  case
    fake.lookup(
      cluster.fake,
      kazoo.account_db(account_id),
      "callcenter_agent-" <> agent_id,
    )
  {
    Ok(document) ->
      doc.get_string(document, ["availability"]) |> result.unwrap("logged_out")
    Error(_) -> "logged_out"
  }
}

/// The same, waited for: the automatic no-answer rule writes from a process
/// of its own, so the write lands a moment after the reply that caused it.
/// Answers what it saw last, so a test that expects no change reads the
/// availability that stood after the waiting was over.
pub fn availability_becomes(
  cluster: Cluster,
  agent_id: String,
  expected: String,
) -> String {
  wait_for_availability(cluster, agent_id, expected, 60)
}

fn wait_for_availability(
  cluster: Cluster,
  agent_id: String,
  expected: String,
  tries: Int,
) -> String {
  let current = availability(cluster, agent_id)
  case current == expected, tries {
    True, _ -> current
    False, 0 -> current
    False, _ -> {
      process.sleep(10)
      wait_for_availability(cluster, agent_id, expected, tries - 1)
    }
  }
}

/// An agent logs in, as the `agent_availability` event says they did: the
/// document they are read from, and the message the dispatcher's listener
/// relays.
pub fn agent_logs_in(cluster: Cluster, agent_id: String) -> Nil {
  agent_is(cluster, agent_id, "available")
  process.send(cluster.dispatcher, dispatcher.LoggedIn(agent_id))
  sync(cluster)
}

/// The agent's `counters.last_call_end`, which is what `longest_idle` reads.
pub fn agent_last_call(cluster: Cluster, agent_id: String, at: Int) -> Nil {
  let assert Ok(document) =
    fake.lookup(
      cluster.fake,
      kazoo.account_db(account_id),
      "callcenter_agent-" <> agent_id,
    )
  fake.put_doc(
    cluster.fake,
    kazoo.account_db(account_id),
    doc.set(document, ["counters", "last_call_end"], doc.Int(at)),
  )
}

// --- The application's own views --------------------------------------------

/// The views of `priv/couchdb/views/callcenter.json`, as the fake datastore
/// runs them: the same emit rule the design document's map function carries,
/// so that a test reads the rows a cluster would give.
pub fn views() -> List(fake.View) {
  [
    fake.View(
      name: "callcenter/queue_calls_open",
      doc_type: records.queue_call_type,
      key: fn(document) {
        case
          doc.get_int(document, ["answered"]),
          doc.get_int(document, ["ended"]),
          doc.get_int(document, ["cancelled"])
        {
          Ok(_answered), Error(Nil), Error(Nil) ->
            doc.get_string(document, ["pvt_account_id"])
            |> result.map(doc.String)
          _closed_or_never_answered, _, _ -> Error(Nil)
        }
      },
    ),
  ]
}

/// The month database a caller's `queue_call` document lives in.
pub fn month(joined: Int) -> String {
  modb.db_name(account_id, at: Some(start_of_time + joined))
}

/// Put a caller's `queue_call` document where the dispatcher and the sweep
/// read it, with the private fields the data layer puts on a MODB document.
pub fn put_record(cluster: Cluster, joined: Int, document: Value) -> Nil {
  fake.put_doc(
    cluster.fake,
    month(joined),
    document
      |> doc.set(["pvt_type"], doc.String(records.queue_call_type))
      |> doc.set(["pvt_account_id"], doc.String(account_id)),
  )
}

/// A `queue_call` document as a dispatcher would have left it, under its
/// passage's id.
pub fn record(
  call_id: String,
  queue_id: String,
  joined: Int,
  offered: List(#(String, Int, Option(String))),
  answered: Option(#(String, String, Int)),
) -> Value {
  doc.object_some([
    #(
      "_id",
      Some(
        doc.String(
          records.passage_id(member(
            call_id,
            queue_id,
            0,
            start_of_time + joined,
          )),
        ),
      ),
    ),
    #("call_id", Some(doc.String(call_id))),
    #("queue_id", Some(doc.String(queue_id))),
    #("joined", Some(doc.Int(start_of_time + joined))),
    #(
      "offered_to",
      Some(
        doc.List(
          list.map(offered, fn(offer) {
            let #(agent_id, at, outcome) = offer
            doc.object_some([
              #("agent_id", Some(doc.String(agent_id))),
              #("at", Some(doc.Int(start_of_time + at))),
              #("outcome", option.map(outcome, doc.String)),
            ])
          }),
        ),
      ),
    ),
    #("agent_id", option.map(answered, fn(answer) { doc.String(answer.0) })),
    #(
      "agent_call_id",
      option.map(answered, fn(answer) { doc.String(answer.1) }),
    ),
    #(
      "answered",
      option.map(answered, fn(answer) { doc.Int(start_of_time + answer.2) }),
    ),
  ])
}

/// The same, as a release that keyed the document by the call id alone
/// left it.
pub fn legacy_record(
  call_id: String,
  queue_id: String,
  joined: Int,
  offered: List(#(String, Int, Option(String))),
  answered: Option(#(String, String, Int)),
) -> Value {
  record(call_id, queue_id, joined, offered, answered)
  |> doc.set(["_id"], doc.String(call_id))
}

/// A caller's `queue_call` document as the datastore holds it now, by id,
/// in the month of `joined` (seconds after `start_of_time`).
pub fn stored_record(
  cluster: Cluster,
  joined: Int,
  doc_id: String,
) -> Result(Value, Nil) {
  fake.lookup(cluster.fake, month(joined), doc_id)
  |> result.replace_error(Nil)
}

/// Run `body` with the node's record writer writing to this cluster's
/// datastore, and wait for everything it asked to be written.
///
/// A dispatcher's record writes go to the writer registered on the node,
/// and are dropped when none is (`records.send`): most of this suite runs
/// with none, and reads what it put in the datastore itself. A writer
/// something earlier in the run left registered is set aside for as long
/// as `body` runs, and given its name back once this one has gone.
pub fn writing_records(cluster: Cluster, body: fn() -> a) -> a {
  let name = records.name()
  let set_aside = process.named(name)
  case set_aside {
    Ok(_pid) -> {
      let _ = process.unregister(name)
      Nil
    }
    Error(Nil) -> Nil
  }
  let assert Ok(writer) =
    records.start_with(Some(name), store(cluster), "t-", fn() { 0 })
  let result = body()
  records.flush()
  let monitor = process.monitor(writer.pid)
  let _ = process.call(writer.data, 1000, records.Stop)
  let assert Ok(_down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  case set_aside {
    Ok(pid) -> {
      let _ = process.register(pid, name)
      Nil
    }
    Error(Nil) -> Nil
  }
  result
}

/// The records writer's datastore, over this cluster's: a node writes a
/// caller's document through `modb`, which is the node's and not the fake.
fn store(cluster: Cluster) -> records.Store {
  let db = fn(where) {
    case where {
      records.Account(account) -> kazoo.account_db(account)
      records.Month(account, at) -> modb.db_name(account, at: Some(at))
    }
  }
  records.Store(
    read: fn(where, doc_id) { cluster.kz.datamgr.open_doc(db(where), doc_id) },
    save: fn(where, _doc_id, kind, document) {
      let account = case where {
        records.Account(account) | records.Month(account, _) -> account
      }
      cluster.kz.datamgr.save_doc(
        db(where),
        document
          |> doc.set(["pvt_type"], doc.String(kind))
          |> doc.set(["pvt_account_id"], doc.String(account)),
      )
      |> result.replace(Nil)
    },
  )
}

// --- Talking to it ---------------------------------------------------------

/// A caller enters a queue.
pub fn arrive(
  cluster: Cluster,
  call_id: String,
  queue_id: String,
  priority: Int,
  joined: Int,
) -> Nil {
  // The dispatcher answers an arrival before it runs the pass the arrival
  // causes, so that the shard's listener is not held up. A test wants both
  // to have happened.
  process.call(cluster.dispatcher, 5000, dispatcher.Arrived(
    member(call_id, queue_id, priority, start_of_time + joined),
    _,
  ))
  sync(cluster)
}

/// A caller enters a queue, as the member given.
pub fn arrive_as(cluster: Cluster, member: Member) -> Nil {
  process.call(cluster.dispatcher, 5000, dispatcher.Arrived(member, _))
  sync(cluster)
}

/// The same caller, on a message the broker has handed out before: what a
/// node taking a shard over meets.
pub fn redelivered(
  cluster: Cluster,
  call_id: String,
  queue_id: String,
  priority: Int,
  joined: Int,
) -> Nil {
  let arrival = member(call_id, queue_id, priority, start_of_time + joined)
  process.call(cluster.dispatcher, 5000, dispatcher.Arrived(
    Member(..arrival, delivery: again()),
    _,
  ))
  // The dispatcher answers the arrival before it takes the caller in, and
  // the actor's word on a caller handed over is sent as it does: the first
  // sync can overtake it, and the second cannot.
  sync(cluster)
  sync(cluster)
}

pub fn member(
  call_id: String,
  queue_id: String,
  priority: Int,
  joined: Int,
) -> Member {
  Member(
    account_id: account_id,
    queue_id: queue_id,
    call_id: call_id,
    call: doc.object([
      #("Call-ID", doc.String(call_id)),
      #("Request", doc.String("600@queues.example.com")),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Queue-ID", doc.String(queue_id))]),
      ),
    ]),
    priority: priority,
    joined: joined,
    callflow_node: "",
    caller_id_name: Some("A Caller"),
    caller_id_number: Some("5551234"),
    handoff_id: call_id <> "-" <> int.to_string(joined),
    branches: doc.object([]),
    delivery: delivery(),
  )
}

/// A member whose call carries a custom channel variable, as the callflow
/// action sets them on the channel.
pub fn with_call_var(member: Member, name: String, value: Int) -> Member {
  Member(
    ..member,
    call: doc.set(member.call, ["Custom-Channel-Vars", name], doc.Int(value)),
  )
}

@external(erlang, "callcenter_ffi", "unsettled_delivery")
fn delivery() -> Delivery

@external(erlang, "callcenter_ffi", "redelivered_delivery")
fn again() -> Delivery

pub fn cancel(
  cluster: Cluster,
  call_id: String,
  reason: types.CancelReason,
) -> Bool {
  let held =
    process.call(cluster.dispatcher, 5000, dispatcher.Cancelled(
      call_id,
      reason,
      _,
    ))
  sync(cluster)
  held
}

/// The sweep found a call answered on a node that died, with its record
/// still open. `ended` is the second the caller's channel went, or nothing
/// when the switches say it is still up.
pub fn orphaned(
  cluster: Cluster,
  call_id: String,
  queue_id: String,
  agent_id: String,
  answered: Int,
  ended: Option(Int),
) -> Nil {
  orphaned_as(cluster, call_id, queue_id, agent_id, answered, False, ended)
}

/// The same, for a record that says whether a supervisor picked the caller
/// up (`picked_up`).
pub fn orphaned_as(
  cluster: Cluster,
  call_id: String,
  queue_id: String,
  agent_id: String,
  answered: Int,
  picked_up: Bool,
  ended: Option(Int),
) -> Nil {
  process.send(
    cluster.dispatcher,
    dispatcher.Orphaned(
      member: member(call_id, queue_id, 0, start_of_time),
      agent_id: agent_id,
      agent_call_id: call_id <> "-agent",
      answered_at: start_of_time + answered,
      picked_up: picked_up,
      ended: ended,
    ),
  )
  sync(cluster)
}

pub fn channel_gone(cluster: Cluster, call_id: String) -> Nil {
  process.send(cluster.dispatcher, dispatcher.ChannelGone(call_id))
  sync(cluster)
}

/// Answer the offer for one caller.
pub fn reply(
  cluster: Cluster,
  call_id: String,
  answer: types.OfferReply,
) -> Nil {
  case
    list.filter(fake_offer.requests(cluster.offers), fn(request) {
      request.member.call_id == call_id
    })
    |> list.last
  {
    Ok(request) -> fake_offer.reply(request, answer)
    Error(_) -> Nil
  }
  sync(cluster)
}

/// Answer the call a caller's actor is watching -- one it adopted, or one it
/// found going on when the caller was handed over -- as that actor would.
pub fn watch_reply(
  cluster: Cluster,
  call_id: String,
  answer: types.OfferReply,
) -> Nil {
  let presented =
    list.filter(fake_calls.presented(cluster.calls), fn(presented) {
      presented.call_id == call_id && presented.presence != types.PresentWaiting
    })
    |> list.last
  let adopted =
    list.filter(fake_calls.adoptions(cluster.calls), fn(adoption) {
      adoption.member.call_id == call_id
    })
    |> list.last
  case presented, adopted {
    Ok(presented), _ -> fake_calls.reply_presented(presented, answer)
    Error(Nil), Ok(adoption) -> fake_calls.reply(adoption, answer)
    Error(Nil), Error(Nil) -> Nil
  }
  sync(cluster)
}

/// The agent a caller's call is being watched with: one adopted, or one
/// their actor found them talking to when they were handed over.
pub fn watching(cluster: Cluster, call_id: String) -> List(String) {
  let presented =
    list.filter_map(fake_calls.presented(cluster.calls), fn(presented) {
      case presented.presence {
        types.PresentConnected(agent_id: agent_id, ..)
          if presented.call_id == call_id
        -> Ok(agent_id)
        _ -> Error(Nil)
      }
    })
    |> list.last
  let adopted =
    list.filter(fake_calls.adoptions(cluster.calls), fn(adoption) {
      adoption.member.call_id == call_id
    })
    |> list.last
  case presented, adopted {
    Ok(agent_id), _ -> [agent_id]
    Error(Nil), Ok(adoption) -> [adoption.agent_id]
    Error(Nil), Error(Nil) -> []
  }
}

/// What the actor of a caller handed over will say of them.
pub fn presents(
  cluster: Cluster,
  call_id: String,
  presence: types.Presence,
) -> Nil {
  fake_calls.will_present(cluster.calls, call_id, presence)
}

/// Answer the offer a caller's actor said was going on for them, as that
/// actor would.
pub fn present_reply(
  cluster: Cluster,
  call_id: String,
  answer: types.OfferReply,
) -> Nil {
  watch_reply(cluster, call_id, answer)
}

/// Make the dispatcher look again, as an agent state change does.
pub fn changed(cluster: Cluster) -> Nil {
  process.send(cluster.dispatcher, dispatcher.Changed)
  sync(cluster)
}

/// An agent's availability changed somewhere else, as the `agent_availability`
/// event for anything but a login says.
pub fn agent_changed(cluster: Cluster, agent_id: String) -> Nil {
  process.send(cluster.dispatcher, dispatcher.AgentChanged(agent_id))
  sync(cluster)
}

/// Run the timers once.
pub fn tick(cluster: Cluster) -> Nil {
  process.send(cluster.dispatcher, dispatcher.Tick)
  sync(cluster)
}

/// Wait until everything sent so far has been handled, which is what makes a
/// test that sends rather than calls deterministic.
pub fn sync(cluster: Cluster) -> Nil {
  let _ = report(cluster)
  Nil
}

pub fn report(cluster: Cluster) -> dispatcher.Snapshot {
  process.call(cluster.dispatcher, 5000, dispatcher.Report)
}

pub fn waiting(cluster: Cluster) -> List(String) {
  process.call(cluster.dispatcher, 5000, dispatcher.Waiting)
}

pub fn status(cluster: Cluster, queue_id: Option(String)) -> List(Value) {
  process.call(cluster.dispatcher, 5000, dispatcher.Status(queue_id, _))
}

/// The agents the offer for a caller is ringing, or nothing if there is no
/// offer for them.
pub fn ringing(cluster: Cluster, call_id: String) -> List(String) {
  case list.filter(report(cluster).offers, fn(offer) { offer.0 == call_id }) {
    [#(_call_id, agents)] -> agents
    _none -> []
  }
}

/// Every agent in an offer right now. Two offers may never share one.
pub fn all_ringing(cluster: Cluster) -> List(String) {
  report(cluster).offers |> list.flat_map(fn(offer) { offer.1 })
}

/// Whether the dispatcher is still running.
pub fn alive(cluster: Cluster) -> Bool {
  case process.subject_owner(cluster.dispatcher) {
    Ok(pid) -> process.is_alive(pid)
    Error(_) -> False
  }
}

/// Send a message without waiting for the dispatcher to answer, for the one
/// case where it is about to stop.
/// The caller left of their own accord -- hung up, pressed an exit key,
/// ran out of time -- as their actor tells it through the shard, which has
/// settled them already.
pub fn left(
  cluster: Cluster,
  call_id: String,
  reason: types.CancelReason,
) -> Nil {
  process.send(cluster.dispatcher, dispatcher.Left(call_id, reason))
  sync(cluster)
}

pub fn tell(cluster: Cluster, message: dispatcher.Message) -> Nil {
  process.send(cluster.dispatcher, message)
}

pub fn none_option() -> Option(String) {
  None
}
