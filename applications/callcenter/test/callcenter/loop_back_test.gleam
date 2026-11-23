//// A member for the queue a caller is already waiting in, reaching the
//// dispatcher before the cancel of the passage they are in.
////
//// Their callflow run again (plan 4.4) continues the passage held: the
//// dispatcher keeps the older join, and with it the caller's place, and the
//// new action -- on another node, with nothing noted -- hears whatever the
//// dispatcher says about the caller in the queue. A timeout or exit branch
//// sending them straight back into the queue is a new passage: the same
//// executor sent the new member, and its action takes only messages that
//// carry its own join, so the dispatcher holds the new one.
////
//// The arrival is run on a dispatcher state built here rather than through
//// the actor, because a first arrival naming a callflow node asks for the
//// dialplan to be run again when that node is not up, and in a test no
//// node is.

import callcenter/activity
import callcenter/dispatcher/arrival
import callcenter/dispatcher/config
import callcenter/dispatcher/pass
import callcenter/dispatcher/state.{type State, type Wait, State, Wait}
import callcenter/presence
import callcenter/queue_doc
import callcenter/types.{type Member, Member}
import gleam/dict
import gleam/erlang/process
import gleam/option.{None}
import kazoo/doc
import kazoo/kazoo
import kazoo/listener
import kazoo/testing/fake
import support/cluster
import support/fake_activity
import support/fake_offer

const call_id = "looping"

const here = "kazoo_apps@one"

/// A caller who joined support at 0 from `node`, told they are first.
fn held(node: String, rerun: Bool) -> Wait {
  Wait(
    member: at(node, 0),
    position: 1,
    announced_at: cluster.start_of_time,
    rerun: rerun,
    tried: [],
  )
}

fn at(node: String, joined: Int) -> Member {
  Member(
    ..cluster.member(call_id, "support", 0, cluster.start_of_time + joined),
    callflow_node: node,
  )
}

fn state_with(wait: Wait, offers: fake_offer.Fake) -> State {
  let datastore = fake.new_with_views(cluster.views())
  fake.put_account(datastore, cluster.account_id, "queues.example.com", [])
  fake.set_now(datastore, cluster.start_of_time + 40)
  let db = kazoo.account_db(cluster.account_id)
  fake.put_doc(
    datastore,
    db,
    doc.object([
      #("_id", doc.String("support")),
      #("pvt_type", doc.String("queue")),
      #("name", doc.String("Support")),
      #("strategy", doc.String("longest_idle")),
      #("agents", doc.List([doc.object([#("id", doc.String("ann"))])])),
    ]),
  )
  fake.put_doc(
    datastore,
    db,
    doc.object([
      #("_id", doc.String("ann")),
      #("pvt_type", doc.String("user")),
      #("call_center", doc.object([])),
    ]),
  )
  fake.put_doc(
    datastore,
    db,
    doc.object([
      #("_id", doc.String("callcenter_agent-ann")),
      #("pvt_type", doc.String("callcenter_agent")),
      #("agent_id", doc.String("ann")),
      #("availability", doc.String("available")),
      #("timestamp", doc.Int(cluster.start_of_time)),
      #("source", doc.String("ui")),
    ]),
  )
  queue_doc.reset()
  activity.forget(cluster.account_id)
  let kz = fake.kazoo(datastore)
  State(
    config: config.Config(
      kz: kz,
      account_id: cluster.account_id,
      announce_interval_s: 30,
      offer_grace_s: 5,
      default_no_answer_status: "on_break",
      queue_refresh_s: queue_doc.default_refresh_s,
      now: kz.now,
      start_watch: fn(_request) { Error("no watches here") },
      settle: fn(_member) { Nil },
      lamp: fn(_agent_id, _state) { Nil },
      activity: fake_activity.reader(fake_activity.new()),
      call_off: fn(_member) { Nil },
      stop_offer: fn(_pid, _unbridged, _member) { Nil },
    ),
    ticks: process.new_subject(),
    replies: process.new_subject(),
    start_offer: fake_offer.start_offer(offers),
    waiting: dict.from_list([#(call_id, wait)]),
    offers: dict.new(),
    pickups: dict.new(),
    leaving: dict.new(),
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
    ticking: False,
    listening: None,
    activities: state.Read(dict.new()),
    sync: state.Synced,
    watch_activity: fn() { Nil },
  )
}

/// The caller as the dispatcher holds them once `member` has arrived.
fn after(wait: Wait, member: Member) -> Wait {
  let state = arrival.arrived(state_with(wait, fake_offer.new()), member)
  let assert Ok(wait) = dict.get(state.waiting, call_id)
  wait
}

/// Sent back into support by their own timeout branch, on the same node,
/// 40 seconds on: a new passage, with its own join and nothing told yet.
pub fn a_caller_sent_back_into_the_queue_is_a_new_passage_test() {
  let wait = after(held(here, False), at(here, 40))
  assert wait.member.joined == cluster.start_of_time + 40
  assert wait.position == 0
  assert wait.announced_at == 0
}

/// And what the dispatcher sends about it carries that join: the offer the
/// next pass makes is for the new passage, which is the one its action
/// hears.
pub fn the_new_passage_is_offered_under_its_own_join_test() {
  let offers = fake_offer.new()
  let state =
    state_with(held(here, False), offers)
    |> arrival.arrived(at(here, 40))
    |> pass.run
  let assert Ok(offer) = fake_offer.last(offers)
  assert offer.member.joined == cluster.start_of_time + 40
  let assert Ok(sent) = dict.get(state.offers, call_id)
  assert sent.member.joined == cluster.start_of_time + 40
  activity.forget(cluster.account_id)
}

/// Their callflow run again on another node continues the passage held.
pub fn a_rerun_on_another_node_keeps_the_older_join_test() {
  let wait = after(held(here, False), at("kazoo_apps@two", 40))
  assert wait.member.joined == cluster.start_of_time
  assert wait.member.callflow_node == "kazoo_apps@two"
  assert wait.position == 1
}

/// So does a rerun this dispatcher asked for, even should the route request
/// land on a node of the same name: one restarted since.
pub fn a_rerun_asked_for_keeps_the_older_join_test() {
  let wait = after(held(here, True), at(here, 40))
  assert wait.member.joined == cluster.start_of_time
  assert wait.position == 1
}

/// The rerun asked for is one member. Once it is here the flag is spent, and
/// the rerun's callflow sending the caller back into the queue later -- a
/// timeout branch on the node that answered the route request -- is a new
/// passage with its own join, as it would be without a rerun. Before, the
/// flag stayed for the rest of the wait, the loop-back kept the first join,
/// and its action, which takes only its own, heard nothing.
pub fn a_loop_back_after_a_rerun_is_a_new_passage_test() {
  let rerun = after(held(here, True), at("kazoo_apps@two", 40))
  assert rerun.member.joined == cluster.start_of_time
  assert !rerun.rerun

  let looped = after(rerun, at("kazoo_apps@two", 80))
  assert looped.member.joined == cluster.start_of_time + 80
  assert looped.position == 0

  // The same when the route request landed on a node of the dead one's
  // name, restarted since.
  let rerun = after(held(here, True), at(here, 40))
  assert rerun.member.joined == cluster.start_of_time
  assert !rerun.rerun
  let looped = after(rerun, at(here, 80))
  assert looped.member.joined == cluster.start_of_time + 80
}

/// The rerun's own member delivered again -- a channel bounce hands every
/// unacked member back -- carries its own later join from the node holding
/// the caller now, and is still the passage it continued, whether or not a
/// rerun was asked for here.
pub fn the_reruns_member_delivered_again_keeps_the_older_join_test() {
  let rerun = after(held(here, True), at("kazoo_apps@two", 40))
  let redelivered =
    after(rerun, Member(..at("kazoo_apps@two", 40), delivery: again()))
  assert redelivered.member.joined == cluster.start_of_time
  assert redelivered.position == 1

  let rerun = after(held(here, False), at("kazoo_apps@two", 40))
  let redelivered =
    after(rerun, Member(..at("kazoo_apps@two", 40), delivery: again()))
  assert redelivered.member.joined == cluster.start_of_time
}

/// The passage held delivered again before the rerun's member is here
/// leaves the rerun expected.
pub fn a_redelivery_before_the_rerun_leaves_it_expected_test() {
  let wait = after(held(here, True), Member(..at(here, 0), delivery: again()))
  assert wait.rerun
  let rerun = after(wait, at(here, 40))
  assert rerun.member.joined == cluster.start_of_time
}

@external(erlang, "callcenter_ffi", "redelivered_delivery")
fn again() -> listener.Delivery

/// The same passage delivered again is the same passage.
pub fn the_same_member_again_keeps_its_place_test() {
  let wait = after(held(here, False), at(here, 0))
  assert wait.member.joined == cluster.start_of_time
  assert wait.position == 1
  assert wait.announced_at == cluster.start_of_time
}

/// A member that names no node cannot be told from a rerun, and is taken
/// as one, as it always was.
pub fn a_member_naming_no_node_keeps_the_older_join_test() {
  let wait = after(held("", False), at("", 40))
  assert wait.member.joined == cluster.start_of_time
}
