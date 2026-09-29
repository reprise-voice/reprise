//// The sweep's view of the cluster: a call answered on a node that died,
//// whose record nobody ever closed.

import callcenter/reconcile
import callcenter/records
import callcenter/shards
import callcenter/types.{Completed}
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import kazoo/amqp
import kazoo/doc
import kazoo/events
import kazoo/kazoo
import kazoo/testing/fake
import support/cluster

// --- What the switches said ------------------------------------------------

/// A switch not carrying the call answers all the same, with `terminated`.
fn terminated_status() -> doc.Value {
  doc.object([
    #("Call-ID", doc.String("call-one")),
    #("Status", doc.String("terminated")),
    #("Error-Msg", doc.String("no node found with channel")),
  ])
}

/// The switch carrying the call answers `active`.
fn active_status() -> doc.Value {
  doc.object([
    #("Call-ID", doc.String("call-one")),
    #("Status", doc.String("active")),
    #("Switch-Nodename", doc.String("freeswitch@one.example.test")),
  ])
}

/// A channel status query with no responders does not produce `Gone`.
///
/// A query sent while `ecallmgr` is rebinding its consumers after a broker
/// restart is heard by nobody, and the collection runs out of time with
/// nothing in it. This is the chain the sweep runs, minus the broker, and it
/// must end in nothing being done: the caller is still on the line, hearing
/// hold music, and will be asked about again next sweep.
pub fn a_query_nobody_answered_is_not_gone_test() {
  let answer = events.status([], finished: False)
  assert answer == Error(amqp.NoAnswer)
  assert reconcile.whereabouts(answer) == reconcile.Unanswered

  // Nor is a cluster with no switch for `kz_nodes` to count, whose
  // collection finishes at once with nothing in it, or a node with no
  // broker at all.
  assert reconcile.whereabouts(events.status([], finished: True))
    == reconcile.Unanswered
  assert reconcile.whereabouts(Error(amqp.Unavailable)) == reconcile.Unanswered
}

/// The switch carrying the caller is slower than the
/// query, the others say `terminated` in time, and the timeout ends the
/// collection. The sweep used to read that as the caller on no switch and
/// settle a caller who was still waiting. It is a question to ask again.
pub fn a_caller_only_some_switches_disowned_is_not_gone_test() {
  let answer =
    events.status([terminated_status(), terminated_status()], finished: False)
  assert reconcile.whereabouts(answer) == reconcile.Unanswered
}

/// Gone is the word of the switches: every one of them answered, and none
/// of them carries the call.
pub fn a_caller_every_switch_disowns_is_gone_test() {
  let answer =
    events.status([terminated_status(), terminated_status()], finished: True)
  assert reconcile.whereabouts(answer) == reconcile.Nowhere
}

/// One switch carrying the call is enough, whatever the others said and
/// whether or not the rest of them answered in time.
pub fn a_caller_a_switch_carries_is_not_gone_test() {
  let answer =
    events.status([terminated_status(), active_status()], finished: False)
  assert reconcile.whereabouts(answer) == reconcile.Carried
}

// --- The records nobody closed ---------------------------------------------

/// A call answered and never ended, as the node that died left it.
fn answered() -> doc.Value {
  cluster.record(
    "call-one",
    "support",
    0,
    [#("ann", 0, Some("answered"))],
    Some(#("ann", "agent-leg", 3)),
  )
}

/// A caller answered on a node that died settled their own member message
/// when they were answered, so no broker will ever mention them again. The
/// view is what is left: answered, no end, no cancel.
pub fn an_answered_record_with_no_end_is_open_test() {
  let c = cluster.new([], [])
  cluster.put_record(c, 0, answered())

  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  assert call.call_id == "call-one"
  assert call.queue_id == "support"
  assert call.agent_id == "ann"
  assert call.agent_call_id == "agent-leg"
  assert call.answered == cluster.start_of_time + 3
  assert call.joined == cluster.start_of_time
}

/// A caller still waiting has nothing to close: nobody answered them, and
/// the member message they are still on is what a new holder finds them by.
pub fn a_caller_nobody_answered_is_not_open_test() {
  let c = cluster.new([], [])
  cluster.put_record(
    c,
    0,
    cluster.record("call-one", "support", 0, [#("ann", 0, None)], None),
  )
  assert reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == []
}

/// A record with an end, or a cancel, is a passage that finished.
pub fn a_closed_record_is_not_open_test() {
  let c = cluster.new([], [])
  cluster.put_record(
    c,
    0,
    answered() |> doc.set(["ended"], doc.Int(cluster.start_of_time + 90)),
  )
  assert reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == []

  cluster.put_record(
    c,
    0,
    answered() |> doc.set(["cancelled"], doc.Int(cluster.start_of_time + 90)),
  )
  assert reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == []
}

/// One record is closed once, however many sweeps find it.
///
/// Two things say so and both are needed. The end is written by the records
/// actor, which is a cast, so a sweep that came round before it landed would
/// see the record open again: the calls this node has asked about are
/// remembered, which is the first. And once the write has landed the view
/// stops naming the record at all, which is the second and is what keeps
/// that memory from growing for ever.
pub fn a_record_is_closed_once_across_two_sweeps_test() {
  let c = cluster.new([], [])
  cluster.put_record(c, 0, answered())

  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  assert reconcile.already_asked(dict.new(), call) == False
  let asked = reconcile.asking(dict.new(), call, cluster.start_of_time)

  // The next sweep, before the write has landed: the record is still there
  // and is left alone.
  let assert [again] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  assert reconcile.already_asked(asked, again) == True

  // And once it has landed -- the same change the dispatcher's own end makes
  // -- the view does not name it.
  cluster.put_record(
    c,
    0,
    records.closed(answered(), Completed, cluster.start_of_time + 90),
  )
  assert reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == []
  // Which is what the scan tells the sweep, and the sweep forgets it.
  assert reconcile.named(asked, cluster.account_id, []) == dict.new()
}

/// What `closing` held was never pruned, although the
/// comment and the README said the view's own filter did it. A scan now says
/// which passages the view named for each account it read, and what the
/// sweep remembers of that account and the view no longer names is gone.
/// Another account's records are not that scan's to judge.
pub fn a_scan_forgets_what_the_view_no_longer_names_test() {
  let one = call_in("account-one", "call-one")
  let two = call_in("account-one", "call-two")
  let elsewhere = call_in("account-two", "call-three")
  let asked =
    dict.new()
    |> reconcile.asking(one, 100)
    |> reconcile.asking(two, 100)
    |> reconcile.asking(elsewhere, 100)

  let left =
    reconcile.named(asked, "account-one", [reconcile.passage(two), "other"])
  assert reconcile.already_asked(left, one) == False
  assert reconcile.already_asked(left, two) == True
  assert reconcile.already_asked(left, elsewhere) == True
}

/// A record whose close never landed -- its dispatcher stopped first, the
/// write was dropped -- is asked about again once `retry_s` has gone by,
/// rather than never again on this node.
pub fn a_record_still_named_is_asked_again_later_test() {
  let one = call_in("account-one", "call-one")
  let asked = reconcile.asking(dict.new(), one, 100)
  assert reconcile.already_asked(
      reconcile.expired(asked, 100 + reconcile.retry_s - 1),
      one,
    )
    == True
  assert reconcile.already_asked(
      reconcile.expired(asked, 100 + reconcile.retry_s),
      one,
    )
    == False
}

/// A view the datastore did not answer is not a month with nothing open in
/// it: only the second may make the sweep forget what it asked about.
pub fn a_view_nobody_answered_is_not_an_empty_one_test() {
  let c = cluster.new([], [])
  assert reconcile.read_open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == Ok([])

  let down =
    kazoo.Kazoo(
      ..c.kz,
      datamgr: kazoo.Datamgr(..c.kz.datamgr, get_results: fn(_db, _view, _o) {
        Error(kazoo.Unavailable)
      }),
    )
  assert reconcile.read_open_calls(
      down,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == Error(Nil)
  let missing =
    kazoo.Kazoo(
      ..c.kz,
      datamgr: kazoo.Datamgr(..c.kz.datamgr, get_results: fn(_db, _view, _o) {
        Error(kazoo.NotFound)
      }),
    )
  assert reconcile.read_open_calls(
      missing,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == Ok([])
}

// --- What a scan costs -----------------------------------------------------

fn channel_of(call_id: String) -> events.Channel {
  events.channel(doc.object([#("uuid", doc.String(call_id))]))
}

/// The switches are asked once for the account's channels, not once per
/// record. A record whose caller is in the answer is up, whoever was late.
pub fn a_call_in_the_accounts_channels_is_carried_test() {
  let answer =
    Ok(events.Channels(
      channels: [channel_of("call-two"), channel_of("call-one")],
      complete: False,
    ))
  assert reconcile.located(answer, "call-one") == reconcile.Carried
}

/// Missing from an answer every switch gave is on no switch; missing from
/// one the timeout ended is nothing known, because the slow switch may be
/// the one carrying it. The same rule as a single call's status.
pub fn a_call_missing_from_a_partial_answer_is_not_gone_test() {
  let complete =
    Ok(events.Channels(channels: [channel_of("call-two")], complete: True))
  assert reconcile.located(complete, "call-one") == reconcile.Nowhere

  let partial =
    Ok(events.Channels(channels: [channel_of("call-two")], complete: False))
  assert reconcile.located(partial, "call-one") == reconcile.Unanswered

  assert reconcile.located(Error(amqp.NoAnswer), "call-one")
    == reconcile.Unanswered
  // What the query makes of what the switches said, end to end: nobody
  // answering in time is not an answer.
  assert reconcile.located(
      events.account_channels([], finished: False),
      "call-one",
    )
    == reconcile.Unanswered
}

fn with_queue_listing() -> #(kazoo.Kazoo, fake.Fake) {
  let f =
    fake.new_with_views([
      fake.View(name: reconcile.queues_view, doc_type: "queue", key: fn(d) {
        doc.get_string(d, ["_id"]) |> result.map(doc.String)
      }),
    ])
  #(fake.kazoo(f), f)
}

/// Only an account with queues has queue calls, so only its month database
/// is read. One row of its queue listing says so.
pub fn only_an_account_with_queues_is_read_test() {
  let #(kz, f) = with_queue_listing()
  assert reconcile.has_queues(kz, cluster.account_id) == Ok(False)

  fake.put_doc(
    f,
    kazoo.account_db(cluster.account_id),
    doc.object([
      #("_id", doc.String("support")),
      #("pvt_type", doc.String("queue")),
    ]),
  )
  assert reconcile.has_queues(kz, cluster.account_id) == Ok(True)

  // A listing that could not be read says nothing, and the scan reads the
  // account all the same.
  let down =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, get_results: fn(_db, _view, _o) {
        Error(kazoo.Unavailable)
      }),
    )
  assert reconcile.has_queues(down, cluster.account_id) == Error(Nil)
}

/// A scan still running when the next sweep comes is left to finish, and no
/// second one is started beside it.
pub fn a_scan_still_running_is_not_joined_by_another_test() {
  assert reconcile.scan_running(None) == False

  let busy = process.spawn_unlinked(fn() { process.sleep_forever() })
  assert reconcile.scan_running(Some(busy)) == True
  process.kill(busy)
  let done = process.spawn_unlinked(fn() { Nil })
  process.sleep(20)
  assert reconcile.scan_running(Some(done)) == False
  assert reconcile.scan_running(Some(busy)) == False
}

fn call_in(account_id: String, call_id: String) -> reconcile.OpenCall {
  reconcile.OpenCall(
    account_id: account_id,
    queue_id: "support",
    call_id: call_id,
    joined: cluster.start_of_time,
    agent_id: "ann",
    agent_call_id: "agent-leg",
    answered: cluster.start_of_time + 3,
    picked_up: False,
    handoff_id: None,
    control_queue: None,
  )
}

/// A caller rebuilt out of their record can be watched and written about.
/// The `kapps_call` the callflow published went with the node that died, so
/// the call on them is an identifier and no more.
pub fn a_caller_is_rebuilt_from_the_record_test() {
  let c = cluster.new([], [])
  cluster.put_record(c, 0, answered())
  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )

  let member = reconcile.rebuilt(call)
  assert member.account_id == cluster.account_id
  assert member.queue_id == "support"
  assert member.call_id == "call-one"
  assert member.joined == cluster.start_of_time
  assert doc.get_string(member.call, ["Call-ID"]) == Ok("call-one")
  // A record an earlier release wrote names no handoff and no control
  // queue: the passage is the call and the second, and the caller cannot
  // be commanded.
  assert member.handoff_id
    == "call-one-" <> int.to_string(cluster.start_of_time)
  assert doc.get_string(member.call, ["Control-Queue"]) |> result.is_error
}

/// A record names the passage's handoff id and the caller's control queue
/// (`records.reached_by`), and the caller rebuilt out of it has both: the
/// passage is the one the caller's actor knows, and the actor watching the
/// call can hang up a caller the agent's end left parked.
pub fn a_caller_rebuilt_is_reached_as_the_record_says_test() {
  let c = cluster.new([], [])
  cluster.put_record(
    c,
    0,
    answered()
      |> doc.set(["handoff_id"], doc.String("a-handoff"))
      |> doc.set(["control_queue"], doc.String("pid://<0.4.0>/control")),
  )
  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  let member = reconcile.rebuilt(call)
  assert member.handoff_id == "a-handoff"
  assert doc.get_string(member.call, ["Control-Queue"])
    == Ok("pid://<0.4.0>/control")
  assert doc.get_string(member.call, ["Account-ID"]) == Ok(cluster.account_id)
}

/// A supervisor's pickup is open in the view like an agent's call -- it has
/// an answer and an `agent_id` -- and says it is a pickup, so that the
/// dispatcher it goes to closes it as one.
pub fn an_open_pickup_says_it_is_one_test() {
  let c = cluster.new([], [])
  cluster.put_record(
    c,
    0,
    answered()
      |> doc.set(["agent_id"], doc.String("sup"))
      |> doc.set(["picked_up"], doc.Bool(True)),
  )
  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  assert call.picked_up
  assert call.agent_id == "sup"

  let c = cluster.new([], [])
  cluster.put_record(c, 0, answered())
  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  assert !call.picked_up
}

/// A row naming no agent is a record nothing can be done about: there is
/// nobody to wrap up and nobody to count it against.
pub fn a_record_with_no_agent_is_left_test() {
  assert reconcile.open_call(
      doc.object([
        #("call_id", doc.String("call-one")),
        #("answered", doc.Int(cluster.start_of_time)),
      ]),
      cluster.account_id,
    )
    == Error(Nil)
}

/// An account nothing has happened in has no month database, which is the
/// same thing as no open records.
pub fn an_account_with_no_month_test() {
  let c = cluster.new([], [])
  assert reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
    == []
}

// --- When a scan runs ------------------------------------------------------

/// The accounts a scan reads are the ones belonging to the shards it was
/// given, and no others: a scan of a shard this account does not hash into
/// reads nothing of theirs.
pub fn only_the_accounts_of_those_shards_test() {
  let shard = shards.of_account(cluster.account_id, 64)
  assert reconcile.accounts_of([cluster.account_id], [shard], 64)
    == [cluster.account_id]
  assert reconcile.accounts_of([cluster.account_id], [], 64) == []
  assert reconcile.accounts_of([cluster.account_id], [other_than(shard)], 64)
    == []
}

fn other_than(shard: Int) -> Int {
  case shard {
    0 -> 1
    _ -> shard - 1
  }
}

/// An orphan appears when a node dies, and a node dying is a lease arriving
/// here. A shard held now and not before is the whole of the trigger; one
/// held all along has nothing new in it, because the records of a node that
/// is alive are closed by that node.
pub fn a_lease_that_moved_is_what_is_scanned_test() {
  assert reconcile.taken(set.from_list([1, 2, 3]), set.from_list([1, 2]))
    == set.from_list([3])
  assert reconcile.taken(set.from_list([1, 2]), set.from_list([1, 2]))
    == set.new()
  // A shard given away is not a shard to scan either.
  assert reconcile.taken(set.from_list([1]), set.from_list([1, 2])) == set.new()
}

/// Behind that, a scan of everything held every `backstop_sweeps` sweeps,
/// for what an acquisition cannot cover: a datastore that was down when the
/// scan ran, or a record this node lost track of while it held the shard.
pub fn the_backstop_comes_round_every_nth_sweep_test() {
  assert reconcile.due_for_backstop(0) == False
  assert reconcile.due_for_backstop(reconcile.backstop_sweeps - 2) == False
  assert reconcile.due_for_backstop(reconcile.backstop_sweeps - 1) == True
}

/// The document is read again just before a record is closed, because the
/// view the scan read is behind it: a dispatcher that closed the call since
/// has written its end, and a second close would be a second wrap-up. A
/// document that cannot be read is not closed on a guess.
pub fn a_record_closed_since_the_scan_is_left_test() {
  assert reconcile.still_open(Some(records.passage(answered()))) == True
  assert reconcile.still_open(
      Some(
        records.passage(records.closed(
          answered(),
          Completed,
          cluster.start_of_time + 90,
        )),
      ),
    )
    == False
  assert reconcile.still_open(
      Some(records.passage(
        answered() |> doc.set(["cancelled"], doc.Int(cluster.start_of_time)),
      )),
    )
    == False
  assert reconcile.still_open(None) == False
}
