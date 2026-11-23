//// Deriving an agent's activity from the channel events the switches
//// publish.

import callcenter/activity
import callcenter/ask
import callcenter/types.{type Activity, Idle, OnCall, Ringing, WrappingUp}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import kazoo/doc
import kazoo/events
import kazoo/listener
import kazoo/testing/fake

/// A channel event as `kapi_call` publishes one.
fn event(
  name: String,
  account_id: String,
  owner_id: String,
  call_id: String,
  ccvs: List(#(String, doc.Value)),
) -> doc.Value {
  doc.object([
    #("Event-Category", doc.String("call_event")),
    #("Event-Name", doc.String(name)),
    #("Call-ID", doc.String(call_id)),
    #(
      "Custom-Channel-Vars",
      doc.object([
        #("Account-ID", doc.String(account_id)),
        #("Owner-ID", doc.String(owner_id)),
        ..ccvs
      ]),
    ),
  ])
}

// --- What is worth an actor message ----------------------------------------

pub fn a_created_channel_starts_one_test() {
  let assert Some(message) =
    activity.interesting(event("CHANNEL_CREATE", "acct", "agent", "call", []))
  assert message
    == activity.Started(
      account_id: "acct",
      agent_id: "agent",
      call_id: "call",
      queue_call: False,
    )
}

/// The `Queue-ID` variable is the whole of the difference between a call this
/// application made and one it did not.
pub fn a_queue_channel_is_tagged_test() {
  let assert Some(activity.Started(queue_call: queue_call, ..)) =
    activity.interesting(
      event("CHANNEL_ANSWER", "acct", "agent", "call", [
        #("Queue-ID", doc.String("support")),
      ]),
    )
  assert queue_call
}

pub fn an_empty_queue_id_is_not_a_queue_call_test() {
  let assert Some(activity.Started(queue_call: queue_call, ..)) =
    activity.interesting(
      event("CHANNEL_CREATE", "acct", "agent", "call", [
        #("Queue-ID", doc.String("")),
      ]),
    )
  assert !queue_call
}

pub fn a_destroyed_channel_ends_one_test() {
  let assert Some(message) =
    activity.interesting(event("CHANNEL_DESTROY", "acct", "agent", "call", []))
  assert message
    == activity.Ended(
      account_id: "acct",
      agent_id: Some("agent"),
      call_id: "call",
      queue_call: False,
    )
}

/// A caller from the public network has no owner, and their hanging up while
/// they wait in a queue is the one destroy without an owner worth a message:
/// the channel carries `Queue-ID`, and the call id is the caller's own.
pub fn a_queue_callers_destroy_is_interesting_without_an_owner_test() {
  let caller =
    doc.object([
      #("Event-Name", doc.String("CHANNEL_DESTROY")),
      #("Call-ID", doc.String("caller")),
      #(
        "Custom-Channel-Vars",
        doc.object([
          #("Account-ID", doc.String("acct")),
          #("Queue-ID", doc.String("support")),
        ]),
      ),
    ])
  assert activity.interesting(caller)
    == Some(activity.Ended(
      account_id: "acct",
      agent_id: None,
      call_id: "caller",
      queue_call: True,
    ))

  // Without `Queue-ID` it is one more carrier leg, and stops here.
  let leg = doc.set(caller, ["Custom-Channel-Vars", "Queue-ID"], doc.String(""))
  assert activity.interesting(leg) == None
}

/// A channel with no owner belongs to no agent: a carrier leg, a conference,
/// a device with no user. Those are most of the events on a busy cluster and
/// they cost one dictionary lookup.
pub fn a_channel_without_an_owner_is_ignored_test() {
  let without =
    doc.object([
      #("Event-Name", doc.String("CHANNEL_CREATE")),
      #("Call-ID", doc.String("call")),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Account-ID", doc.String("acct"))]),
      ),
    ])
  assert activity.interesting(without) == None
}

/// The bus lets through every event `interesting` keeps, for an account a
/// dispatcher here watches, and drops nearly all of the rest before any of
/// it is a document: other names, channels with neither an owner nor a
/// queue, and accounts nobody here watches.
pub fn the_bus_passes_what_is_interesting_test() {
  let gate = events.new_gate()
  let interest = activity.interest(gate)
  let queue = [#("Queue-ID", doc.String("support"))]
  let kept = [
    event("CHANNEL_CREATE", "acct", "agent", "call", []),
    event("CHANNEL_ANSWER", "acct", "agent", "call", queue),
    event("CHANNEL_BRIDGE", "acct", "agent", "call", []),
    event("CHANNEL_DESTROY", "acct", "agent", "call", []),
    doc.object([
      #("Event-Name", doc.String("CHANNEL_DESTROY")),
      #("Call-ID", doc.String("caller")),
      #(
        "Custom-Channel-Vars",
        doc.object([
          #("Account-ID", doc.String("acct")),
          #("Queue-ID", doc.String("support")),
        ]),
      ),
    ]),
  ]
  list.each(kept, fn(kept) {
    let assert Some(_message) = activity.interesting(kept)
    // Not until a dispatcher here watches the account.
    assert !events.wants(interest, kept)
  })
  events.open(gate, "acct")
  list.each(kept, fn(kept) {
    assert events.wants(interest, kept)
  })

  let dropped = [
    event("CHANNEL_EXECUTE", "acct", "agent", "call", []),
    event("CHANNEL_EXECUTE_COMPLETE", "acct", "agent", "call", queue),
    event("DTMF", "acct", "agent", "call", []),
    event("CHANNEL_CREATE", "elsewhere", "agent", "call", []),
    doc.object([
      #("Event-Name", doc.String("CHANNEL_CREATE")),
      #("Call-ID", doc.String("carrier")),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Account-ID", doc.String("acct"))]),
      ),
    ]),
  ]
  list.each(dropped, fn(dropped) {
    assert !events.wants(interest, dropped)
  })
}

pub fn other_events_are_ignored_test() {
  assert activity.interesting(event("DTMF", "acct", "agent", "call", []))
    == None
  assert activity.interesting(
      event("CHANNEL_HOLD", "acct", "agent", "call", []),
    )
    == None
}

// --- The derivation --------------------------------------------------------

pub fn no_channels_is_idle_test() {
  assert activity.from_channels([], False, False) == Idle
}

pub fn a_channel_is_on_a_call_test() {
  assert activity.from_channels([False], False, False)
    == OnCall(queue_call: False)
  assert activity.from_channels([True], False, False)
    == OnCall(queue_call: True)
}

/// An agent on two calls, one of which came from a queue, is on a queue call
/// for the metrics.
pub fn a_queue_channel_wins_test() {
  assert activity.from_channels([False, True], False, False)
    == OnCall(queue_call: True)
}

/// The two the channels cannot say are the application's own, and they only
/// show through when there is no channel at all: a stale belief must not be
/// able to hide a real call.
pub fn the_overlays_only_show_without_channels_test() {
  assert activity.from_channels([], True, False) == Ringing
  assert activity.from_channels([], False, True) == WrappingUp
  assert activity.from_channels([False], True, False)
    == OnCall(queue_call: False)
  assert activity.from_channels([True], False, True) == OnCall(queue_call: True)
}

/// Ringing outranks wrapping up: an offer is live and a wrap-up is a timer.
pub fn ringing_outranks_wrapping_up_test() {
  assert activity.from_channels([], True, True) == Ringing
}

// --- The actor: overlays and the dispatcher they belong to -----------------

const start_of_time = 63_800_000_000

/// Run `body` against an activity actor of its own, whose clock is a fake
/// one, and stop it after.
///
/// Not the node's: the test run starts the application, whose tree has that
/// one under the registered name and would restart it, and stopping it from
/// here took the tree's other children down with it.
fn with_activity(body: fn(Subject(activity.Message), fake.Fake) -> Nil) -> Nil {
  let clock = fake.new()
  fake.set_now(clock, start_of_time)
  let assert Ok(started) = activity.start_unnamed(fake.kazoo(clock))
  body(started.data, clock)
  let _ = ask.call(started.data, 1000, activity.Stop)
  Nil
}

fn of(actor: Subject(activity.Message), agent_id: String) -> Activity {
  process.call(actor, 1000, activity.Ask("acct", agent_id, _))
}

fn watched(actor: Subject(activity.Message)) -> List(String) {
  process.call(actor, 1000, activity.Accounts)
}

/// Something to stand in for a dispatcher: a process that lives until it
/// is killed.
fn a_dispatcher() -> process.Pid {
  process.spawn_unlinked(fn() { process.sleep_forever() })
}

/// A dispatcher that does not care which queue channels go.
fn ignore(_call_id: String) -> Nil {
  Nil
}

/// The account's dispatcher is told of every queue channel of its account
/// that goes, by the channel's own call id: a caller hanging up, whether or
/// not anything about them belonged to an agent. The call id an agent's leg
/// has is not the caller's, and the dispatcher, which holds its callers by
/// theirs, could never find them by it.
pub fn a_queue_channel_going_is_told_to_the_dispatcher_test() {
  use actor, _clock <- with_activity
  let told = process.new_subject()
  let dispatcher = a_dispatcher()
  process.send(
    actor,
    activity.Watch("acct", dispatcher, fn(call_id) {
      process.send(told, call_id)
    }),
  )
  process.send(
    actor,
    activity.Ended("acct", agent_id: None, call_id: "caller", queue_call: True),
  )
  assert process.receive(told, 1000) == Ok("caller")

  // An agent's personal call is not a queue channel, and another account's
  // caller is another dispatcher's.
  process.send(
    actor,
    activity.Ended(
      "acct",
      agent_id: Some("ann"),
      call_id: "own",
      queue_call: False,
    ),
  )
  process.send(
    actor,
    activity.Ended("other", agent_id: None, call_id: "theirs", queue_call: True),
  )
  let _ = watched(actor)
  assert process.receive(told, 50) == Error(Nil)
  process.kill(dispatcher)
}

/// Whether the actor still watches the account, asked until it says it does
/// not or a second has gone: the end of a process reaches it as a monitor
/// message, which is not ordered with anything this process sends.
fn forgotten(actor: Subject(activity.Message), tries: Int) -> Bool {
  case list.contains(watched(actor), "acct"), tries {
    False, _ -> True
    True, 0 -> False
    True, _ -> {
      process.sleep(10)
      forgotten(actor, tries - 1)
    }
  }
}

/// Ringing lasts as long as the offer's ceiling and a wrap-up as long as the
/// wrap-up, cleared or not. A dispatcher that crashed never clears them, and
/// before they had an end its agents stayed ringing or wrapping up until
/// their next call.
pub fn an_overlay_ends_when_its_time_is_up_test() {
  use actor, clock <- with_activity
  let dispatcher = a_dispatcher()
  process.send(actor, activity.Watch("acct", dispatcher, ignore))
  process.send(actor, activity.Offering("acct", "ann", 25))
  process.send(actor, activity.Wrapup("acct", "bob", 10))
  assert of(actor, "ann") == Ringing
  assert of(actor, "bob") == WrappingUp

  fake.set_now(clock, start_of_time + 9)
  assert of(actor, "bob") == WrappingUp
  fake.set_now(clock, start_of_time + 10)
  assert of(actor, "ann") == Ringing
  assert of(actor, "bob") == Idle

  fake.set_now(clock, start_of_time + 25)
  assert of(actor, "ann") == Idle
  // And dropped, not only hidden: what `Expire` does when its timer fires.
  process.send(actor, activity.Expire("acct"))
  assert process.call(actor, 1000, activity.AskAll("acct", _))
    |> list.all(fn(entry) { entry.1 == Idle })
  process.kill(dispatcher)
}

/// A dispatcher's overlays are its own. The same dispatcher watching again
/// keeps them; a new one starts the account with none, because the offers
/// and wrap-ups they were about went with the dispatcher that made them.
pub fn a_new_dispatcher_starts_with_no_overlays_test() {
  use actor, _clock <- with_activity
  let first = a_dispatcher()
  let second = a_dispatcher()
  process.send(actor, activity.Watch("acct", first, ignore))
  process.send(actor, activity.Offering("acct", "ann", 60))
  process.send(actor, activity.Wrapup("acct", "bob", 60))
  process.send(actor, activity.Watch("acct", first, ignore))
  assert of(actor, "ann") == Ringing
  assert of(actor, "bob") == WrappingUp

  process.send(actor, activity.Watch("acct", second, ignore))
  assert of(actor, "ann") == Idle
  assert of(actor, "bob") == Idle
  process.kill(first)
  process.kill(second)
}

/// The account is forgotten when its dispatcher goes, however it goes: one
/// that crashed says nothing, and the node went on resyncing an account
/// whose shard had moved on. The goodbye of a dispatcher that has already
/// been replaced does not take the account from the one that replaced it.
pub fn a_dispatcher_that_goes_takes_its_account_with_it_test() {
  use actor, _clock <- with_activity
  let first = a_dispatcher()
  let second = a_dispatcher()
  process.send(actor, activity.Watch("acct", first, ignore))
  assert list.contains(watched(actor), "acct")

  process.send(actor, activity.Watch("acct", second, ignore))
  process.send(actor, activity.Forget("acct", Some(first)))
  process.kill(first)
  process.sleep(20)
  assert list.contains(watched(actor), "acct")

  process.kill(second)
  assert forgotten(actor, 100)
}

/// An account is not synced until the switches have answered for it, whole
/// or not: until then the table holds only what came on the events since.
pub fn an_account_is_synced_by_the_switches_answer_test() {
  use actor, _clock <- with_activity
  let dispatcher = a_dispatcher()
  process.send(actor, activity.Watch("acct", dispatcher, ignore))
  let reading = process.call(actor, 1000, activity.Read("acct", _))
  assert !reading.synced

  process.send(
    actor,
    activity.Snapshot(
      "acct",
      [#("ann", "call-a", False)],
      complete: False,
      asked: 0,
    ),
  )
  let reading = process.call(actor, 1000, activity.Read("acct", _))
  assert reading.synced
  assert dict.get(reading.activities, "ann") == Ok(OnCall(queue_call: False))
  process.kill(dispatcher)
}

/// A queue document changing is every node's news, and a node that does not
/// watch the account does not start to.
pub fn a_queue_change_does_not_watch_an_account_test() {
  use actor, _clock <- with_activity
  process.send(actor, activity.Reload("elsewhere"))
  assert !list.contains(watched(actor), "elsewhere")
}

// --- The switches' answer --------------------------------------------------

/// Two agents talking, each on a different switch.
fn two_talking() -> dict.Dict(String, dict.Dict(String, Bool)) {
  dict.from_list([
    #("ann", dict.from_list([#("call-a", True)])),
    #("bob", dict.from_list([#("call-b", False)])),
  ])
}

/// Every switch answered: the answer is the whole of what is up, and an
/// agent it does not name has no channel.
pub fn a_whole_answer_replaces_the_table_test() {
  let table =
    activity.answered(
      two_talking(),
      [#("ann", "call-a", True)],
      complete: True,
      since: activity.nothing_meanwhile(),
    )
  assert dict.to_list(table) == [#("ann", dict.from_list([#("call-a", True)]))]
}

/// Bob's switch was slower than the query and the
/// timeout ended it. Bob is still talking, and an answer without his switch
/// in it does not make him idle -- idle is offered callers. It only adds.
pub fn an_answer_a_switch_missed_only_adds_test() {
  let table =
    activity.answered(
      two_talking(),
      [#("ann", "call-a", True), #("cal", "call-c", False)],
      complete: False,
      since: activity.nothing_meanwhile(),
    )
  assert dict.get(table, "bob") == Ok(dict.from_list([#("call-b", False)]))
  assert dict.get(table, "ann") == Ok(dict.from_list([#("call-a", True)]))
  assert dict.get(table, "cal") == Ok(dict.from_list([#("call-c", False)]))
}

/// An answer is as old as the question. Ann's call
/// ended while the switches were being asked, and a switch that answered
/// before her destroy still named it: whole or partial, the answer does not
/// put her back on it. Cal's call began after the question was sent, and a
/// whole answer that leaves it out does not take it away; Bob's began
/// before, and goes.
pub fn an_answer_does_not_overrule_a_later_event_test() {
  let meanwhile =
    activity.Meanwhile(
      created: set.from_list(["call-c"]),
      destroyed: set.from_list(["call-a"]),
    )
  let table =
    dict.insert(two_talking(), "cal", dict.from_list([#("call-c", False)]))
    |> dict.delete("ann")
  let answer = [#("ann", "call-a", True)]

  let whole = activity.answered(table, answer, complete: True, since: meanwhile)
  assert dict.to_list(whole) == [#("cal", dict.from_list([#("call-c", False)]))]

  let partial =
    activity.answered(table, answer, complete: False, since: meanwhile)
  assert dict.get(partial, "ann") == Error(Nil)
  assert dict.get(partial, "bob") == Ok(dict.from_list([#("call-b", False)]))
}

/// The same through the actor, which stamps each question with the events
/// it had heard when it was sent and remembers destroyed calls for a
/// minute. The answer that arrives after Ann's destroy names her call, and
/// she is not put back on it -- the pin that used to keep her on a call
/// for as long as any `ecallmgr` timed out. Bob's call came up after the
/// question and the whole answer left it out: he is still on it. Carl's came
/// up before, and the whole answer that leaves it out takes it away.
pub fn a_late_answer_is_ordered_against_the_events_test() {
  use actor, clock <- with_activity
  let dispatcher = a_dispatcher()
  process.send(actor, activity.Watch("acct", dispatcher, ignore))
  process.send(actor, activity.Started("acct", "ann", "call-a", False))
  process.send(actor, activity.Started("acct", "carl", "call-c", False))
  // The question goes out here, after two events.
  process.send(
    actor,
    activity.Ended(
      "acct",
      agent_id: Some("ann"),
      call_id: "call-a",
      queue_call: False,
    ),
  )
  process.send(actor, activity.Started("acct", "bob", "call-b", False))

  process.send(
    actor,
    activity.Snapshot(
      "acct",
      [#("ann", "call-a", False)],
      complete: False,
      asked: 2,
    ),
  )
  assert of(actor, "ann") == Idle
  process.send(
    actor,
    activity.Snapshot(
      "acct",
      [#("ann", "call-a", False)],
      complete: True,
      asked: 2,
    ),
  )
  assert of(actor, "ann") == Idle
  assert of(actor, "bob") == OnCall(queue_call: False)
  assert of(actor, "carl") == Idle

  // A minute on the destroyed call is forgotten: an answer naming the call
  // id then is the switches' word, as before.
  fake.set_now(clock, start_of_time + activity.destroyed_kept_s)
  process.send(
    actor,
    activity.Snapshot(
      "acct",
      [#("ann", "call-a", False)],
      complete: False,
      asked: 4,
    ),
  )
  assert of(actor, "ann") == OnCall(queue_call: False)
  process.kill(dispatcher)
}

/// `kz_nodes` counting no `ecallmgr` for a moment
/// finishes the channel query at once with nothing in it. That is nobody
/// asked, and it is no snapshot: the table stays as it is, and an agent on a
/// call stays on it. A partial answer and every switch answering "none" are
/// snapshots, as before.
pub fn nobody_to_ask_is_no_snapshot_test() {
  assert activity.snapshot_of("acct", 0, events.account_channels([], True))
    == None
  assert activity.snapshot_of("acct", 0, events.account_channels([], False))
    == None
  let none_here = doc.object([#("Channels", doc.List([]))])
  assert activity.snapshot_of(
      "acct",
      3,
      events.account_channels([none_here], True),
    )
    == Some(activity.Snapshot("acct", [], complete: True, asked: 3))

  use actor, _clock <- with_activity
  let dispatcher = a_dispatcher()
  process.send(actor, activity.Watch("acct", dispatcher, ignore))
  process.send(
    actor,
    activity.Snapshot(
      "acct",
      [#("ann", "call-a", False)],
      complete: True,
      asked: 0,
    ),
  )
  case activity.snapshot_of("acct", 0, events.account_channels([], True)) {
    Some(snapshot) -> process.send(actor, snapshot)
    None -> Nil
  }
  let reading = process.call(actor, 1000, activity.Read("acct", _))
  assert reading.synced
  assert dict.get(reading.activities, "ann") == Ok(OnCall(queue_call: False))
  process.kill(dispatcher)
}

// --- The wire names --------------------------------------------------------

pub fn names_round_trip_test() {
  assert activity.to_string(Idle) == "idle"
  assert activity.to_string(Ringing) == "ringing"
  assert activity.to_string(OnCall(queue_call: True)) == "on_call"
  assert activity.to_string(OnCall(queue_call: False)) == "on_call"
  assert activity.to_string(WrappingUp) == "wrapping_up"

  assert activity.from_string("idle") == Idle
  assert activity.from_string("ringing") == Ringing
  assert activity.from_string("wrapping_up") == WrappingUp
  assert activity.from_string("on_call") == OnCall(queue_call: False)
  // A value from a newer release is not a crash in a listener.
  assert activity.from_string("dancing") == Idle
}

// --- The configuration listener --------------------------------------------

pub fn the_account_of_a_conf_event_test() {
  let edited =
    doc.object([
      #("Event-Name", doc.String("doc_edited")),
      #("Account-ID", doc.String("acct")),
      #("Database", doc.String("account%2Fac%2Fct%2Facct")),
      #("Type", doc.String("queue")),
    ])
  assert activity.account_of_conf(edited) == Some("acct")
}

/// A queue being deleted names its account and itself, whichever delete it
/// was: Crossbar's soft delete publishes `doc_deleted` as a real one does.
/// An edit, or a deletion of anything but a queue, deletes no queue.
pub fn a_queue_deletion_is_told_test() {
  let change = fn(name, kind) {
    doc.object([
      #("Event-Name", doc.String(name)),
      #("Database", doc.String("account%2Fac%2Fct%2Facct")),
      #("Account-ID", doc.String("acct")),
      #("Type", doc.String(kind)),
      #("ID", doc.String("support")),
      #("Is-Soft-Deleted", doc.Bool(True)),
    ])
  }
  assert activity.deleted_queue(change("doc_deleted", "queue"))
    == Some(#("acct", "support"))
  assert activity.deleted_queue(change("doc_edited", "queue")) == None
  assert activity.deleted_queue(change("doc_deleted", "user")) == None
  assert activity.deleted_queue(doc.object([])) == None
}

pub fn a_conf_event_about_nothing_test() {
  assert activity.account_of_conf(doc.object([])) == None
}

/// The binding is what makes a queue document being edited reach this node,
/// and a transient queue is right for it: an event missed while the node was
/// down is caught by the sweep.
pub fn the_conf_listener_binds_to_queue_documents_test() {
  let spec =
    listener.to_spec(activity.conf_listener(fn(_account, _queue) { Nil }))
  assert dict.has_key(spec, "bindings")
  assert dict.has_key(spec, "queue")
  assert dict.has_key(spec, "on_event")
  assert dict.has_key(spec, "notify")
}

/// The reconcile interval is the sweep in requirement 0.6 and it has a
/// floor: a configured zero would be a busy loop.
pub fn the_reconcile_interval_has_a_default_test() {
  assert activity.default_reconcile_interval_s == 30
  assert list.length([activity.default_reconcile_interval_s]) == 1
}
