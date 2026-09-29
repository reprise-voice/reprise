//// A supervisor's pickup, in the dispatcher: the caller rung through to the
//// supervisor's own phones by the dispatcher holding them, against a fake
//// clock and a fake offer.

import callcenter/activity
import callcenter/dispatcher
import callcenter/dispatcher/pickup.{
  type Answer, BeingOffered, NotWaiting, Request, Ringing, SupervisorBusy,
  TooLate,
}
import callcenter/pickup as wire
import callcenter/types.{
  Answered, Busy, Completed, Ended, ExitKey, Failed, Hangup, OfferNoAnswer,
  OfferRinging, Rejected, WrappingUp,
}
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc
import kazoo/listener
import support/cluster
import support/fake_offer

const supervisor = "sup"

const desk = "sup-desk"

fn queue(agents: List(String)) -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String("longest_idle")),
    #("agent_ring_timeout", doc.Int(20)),
    #("agent_wrapup_time", doc.Int(10)),
    #(
      "agents",
      doc.List(
        list.map(agents, fn(id) {
          doc.object([
            #("id", doc.String(id)),
            #("level", doc.Int(1)),
            #("position", doc.Int(1)),
          ])
        }),
      ),
    ),
  ])
}

fn user() -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object([])),
  ])
}

/// One queue whose only agent, ann, is on a break: a caller who arrives
/// waits, which is when a supervisor picks one up.
fn quiet_queue() -> cluster.Cluster {
  let c =
    cluster.new([#("support", queue(["ann"]))], [
      #("ann", user()),
      #(supervisor, doc.object([#("pvt_type", doc.String("user"))])),
    ])
  cluster.agent_is(c, "ann", "on_break")
  c
}

/// Ask the dispatcher for a pickup, and the subject its answer comes to.
fn ask(
  c: cluster.Cluster,
  call_id: String,
  queue_id: String,
  who: String,
  deadline_ms: Int,
) -> process.Subject(Answer) {
  let answer = process.new_subject()
  process.send(
    c.dispatcher,
    dispatcher.PickUp(
      Request(
        queue_id: queue_id,
        call_id: call_id,
        supervisor_id: who,
        target_type: "user",
        target_id: who,
        device_ids: [desk],
      ),
      deadline_ms,
      answer,
    ),
  )
  cluster.sync(c)
  answer
}

/// A pickup, answered: at once when nothing was started, and otherwise once
/// the offer it started says its bridge is out, as a working offer does.
fn pick_up_by(
  c: cluster.Cluster,
  call_id: String,
  queue_id: String,
  who: String,
  deadline_ms: Int,
) -> Answer {
  let offers = fake_offer.count(c.offers)
  let answer = ask(c, call_id, queue_id, who, deadline_ms)
  case process.receive(answer, 0) {
    Ok(answer) -> answer
    Error(Nil) -> {
      assert fake_offer.count(c.offers) == offers + 1
      cluster.reply(c, call_id, OfferRinging([who]))
      let assert Ok(answer) = process.receive(answer, 1000)
      answer
    }
  }
}

fn pick_up(c: cluster.Cluster, call_id: String) -> Answer {
  pick_up_by(c, call_id, "support", supervisor, later())
}

/// A deadline nobody reaches.
fn later() -> Int {
  monotonic_ms() + 60_000
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// The caller waiting and a pickup ringing for them.
fn ringing_supervisor() -> cluster.Cluster {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert fake_offer.count(c.offers) == 0
  assert pick_up(c, "call-one") == Ringing(pickup.ring_timeout_s)
  c
}

// --- The ring ----------------------------------------------------------------

/// The pickup is an offer to the supervisor, ringing the phones named and
/// marked with who answers, from the caller's own channel: the same offer
/// an agent is rung with, which is what makes the caller hear the queue's
/// music and not a konami intercept.
pub fn a_pickup_rings_the_supervisors_phones_test() {
  let c = ringing_supervisor()
  let assert Ok(request) = fake_offer.last(c.offers)
  assert request.agents == [supervisor]
  assert request.devices == Some([desk])
  assert request.member.call_id == "call-one"
  assert request.settings.ring_timeout_s == pickup.ring_timeout_s
  assert cluster.ringing(c, "call-one") == [supervisor]
  // Still waiting, and not settled: the caller leaves only on an answer.
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.settled(c) == []
}

/// While the supervisor's phone rings nobody else is rung for the caller,
/// however many agents come free.
pub fn no_agent_is_rung_while_the_supervisor_is_test() {
  let c = ringing_supervisor()
  cluster.agent_is(c, "ann", "available")
  cluster.changed(c)
  assert fake_offer.count(c.offers) == 1
  assert cluster.ringing(c, "call-one") == [supervisor]
}

/// The finding: a supervisor who does not answer used to leave the caller
/// settled and offered to nobody. Now the caller is waiting as they were,
/// and the next agent free is rung for them. Nobody missed anything.
pub fn an_unanswered_pickup_leaves_the_caller_waiting_test() {
  list.each(
    [
      OfferNoAnswer([supervisor]),
      Busy(supervisor),
      Rejected(supervisor),
      Failed("no_endpoints"),
    ],
    fn(reply) {
      let c = ringing_supervisor()
      cluster.reply(c, "call-one", reply)
      assert cluster.waiting(c) == ["call-one"]
      assert cluster.settled(c) == []
      assert cluster.ringing(c, "call-one") == []

      // Dispatchable: ann comes back and is rung at once.
      cluster.agent_is(c, "ann", "available")
      cluster.changed(c)
      assert cluster.ringing(c, "call-one") == ["ann"]
    },
  )
}

/// A supervisor who did not answer may be asked again, and is: nothing is
/// left holding them.
pub fn a_supervisor_may_try_again_test() {
  let c = ringing_supervisor()
  cluster.reply(c, "call-one", OfferNoAnswer([supervisor]))
  assert pick_up(c, "call-one") == Ringing(pickup.ring_timeout_s)
  assert fake_offer.count(c.offers) == 2
}

/// The supervisor answers: the caller is waiting no more, and the end of
/// the call closes the pickup and settles the caller, once.
pub fn an_answered_pickup_settles_the_caller_once_test() {
  let c = ringing_supervisor()
  cluster.reply(
    c,
    "call-one",
    Answered(supervisor, "sup-leg", cluster.start_of_time + 5),
  )
  assert cluster.settled(c) == []
  assert cluster.waiting(c) == []
  // Held until the call ends, so nobody else can ring them meanwhile.
  assert cluster.all_ringing(c) == [supervisor]

  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 65))
  assert cluster.settled(c) == ["call-one"]
  assert cluster.all_ringing(c) == []
  // A cancel arriving late settles nothing more.
  assert !cluster.cancel(c, "call-one", Hangup)
  assert cluster.settled(c) == ["call-one"]
}

/// What the caller's action and whoever watches hear: the phones ringing,
/// the supervisor connected, and the end -- and nothing about an agent,
/// because the supervisor did not take a queue call as one.
pub fn a_pickup_tells_the_caller_and_no_agent_test() {
  let platform = platform_start()
  let c = ringing_supervisor()
  cluster.reply(
    c,
    "call-one",
    Answered(supervisor, "sup-leg", cluster.start_of_time + 5),
  )
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 65))
  let published = published_events()
  let connected = published_values("member_connected", "Agent-ID")
  let ended = published_values("member_result", "Agent-ID")
  let rejected = rejected()
  platform_stop(platform)

  assert rejected == []
  assert list.contains(published, #("exchange", "member_offer"))
  assert connected == [#("exchange", supervisor)]
  assert ended == [#("exchange", supervisor)]
  assert !list.contains(published, #("exchange", "agent_offer"))
  assert !list.contains(published, #("exchange", "agent_answered"))
  assert !list.contains(published, #("exchange", "agent_wrapup"))
}

/// A supervisor who is also an agent of the queue takes no wrap-up after a
/// pickup: it was not a queue call they took as an agent, so the next
/// caller can have them at once.
pub fn a_pickup_starts_no_wrapup_test() {
  let c = cluster.new([#("support", queue(["bob"]))], [#("bob", user())])
  cluster.agent_is(c, "bob", "on_break")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert pick_up_by(c, "call-one", "support", "bob", later())
    == Ringing(pickup.ring_timeout_s)
  cluster.reply(
    c,
    "call-one",
    Answered("bob", "bob-leg", cluster.start_of_time),
  )
  cluster.at(c, 60)
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))

  cluster.agent_is(c, "bob", "available")
  cluster.arrive(c, "call-two", "support", 0, 60)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// A caller who hangs up while the supervisor's phone rings has left, as
/// from an agent's ring, and is settled once.
pub fn a_caller_who_hangs_up_during_a_pickup_leaves_test() {
  let c = ringing_supervisor()
  cluster.left(c, "call-one", Hangup)
  assert cluster.waiting(c) == []
  assert cluster.settled(c) == ["call-one"]
  assert cluster.all_ringing(c) == []
}

/// A caller who leaves the queue another way while it rings -- an exit
/// key, a timeout -- is settled by their cancel and the ring is let go.
pub fn a_caller_who_leaves_during_a_pickup_is_settled_once_test() {
  let c = ringing_supervisor()
  assert cluster.cancel(c, "call-one", ExitKey)
  assert cluster.settled(c) == ["call-one"]
  assert cluster.all_ringing(c) == []
  // The ring's own end, when it comes, is about a pickup that is gone.
  cluster.reply(c, "call-one", OfferNoAnswer([supervisor]))
  assert cluster.settled(c) == ["call-one"]
}

/// A pickup whose actor dies without a word leaves the caller waiting and
/// offered to the next agent free. Nothing is left to call the ring off:
/// its legs end on their own ring timeout.
pub fn a_pickup_that_dies_leaves_the_caller_waiting_test() {
  let c = ringing_supervisor()
  fake_offer.died(c.offers)
  cluster.sync(c)
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.settled(c) == []
  assert cluster.called_off(c) == []
  assert cluster.ringing(c, "call-one") == []
}

// --- Calling a pickup off ----------------------------------------------------

fn release(c: cluster.Cluster, agent_id: String) -> Bool {
  let known =
    process.call(c.dispatcher, 5000, dispatcher.ReleaseAgent(agent_id, _))
  cluster.sync(c)
  known
}

/// Releasing a supervisor calls their pickup's ring off as an agent's is:
/// the caller's actor is told, once.
pub fn a_released_pickup_is_called_off_test() {
  let c = ringing_supervisor()
  assert release(c, supervisor)
  assert cluster.called_off(c) == ["call-one"]
  // Once: a second release sends nothing more.
  assert release(c, supervisor)
  assert cluster.called_off(c) == ["call-one"]
}

/// Released before the ring is out, the call-off goes at once, and nothing
/// more when the ring is out: the actor handles the ring before the
/// call-off, since they were sent in that order.
pub fn a_pickup_released_before_its_ring_is_out_is_called_off_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let _answer = ask(c, "call-one", "support", supervisor, later())
  assert release(c, supervisor)
  assert cluster.called_off(c) == ["call-one"]
  cluster.reply(c, "call-one", OfferRinging([supervisor]))
  assert cluster.called_off(c) == ["call-one"]
}

/// An answer that reached the actor before the call-off stands: the
/// supervisor has the caller, who is not offered again, and is settled when
/// the call ends. A call-off that came first ends the ring with nobody's
/// answer, and the caller waits on.
pub fn an_answer_before_a_pickups_call_off_stands_test() {
  let c = ringing_supervisor()
  assert release(c, supervisor)
  cluster.reply(
    c,
    "call-one",
    Answered(supervisor, "sup-leg", cluster.start_of_time),
  )
  assert cluster.waiting(c) == []
  assert cluster.settled(c) == []
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 30))
  assert cluster.settled(c) == ["call-one"]
  assert cluster.all_ringing(c) == []

  let c = ringing_supervisor()
  assert release(c, supervisor)
  cluster.reply(c, "call-one", Failed("called_off"))
  assert cluster.settled(c) == []
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.all_ringing(c) == []
}

/// A ring out after its requester stopped waiting is called off the same
/// way.
pub fn a_late_pickup_is_called_off_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let _answer = ask(c, "call-one", "support", supervisor, monotonic_ms() + 30)
  process.sleep(60)
  cluster.reply(c, "call-one", OfferRinging([supervisor]))
  assert cluster.called_off(c) == ["call-one"]
}

/// A caller taken out of the queue while the pickup rings has it called
/// off, and so does a queue deleted while it does, which takes the caller
/// out at once: their actor sequences the departure.
pub fn leaving_a_pickup_calls_it_off_test() {
  let c = ringing_supervisor()
  assert cluster.cancel(c, "call-one", ExitKey)
  assert cluster.called_off(c) == ["call-one"]
  assert cluster.waiting(c) == []

  let c = ringing_supervisor()
  cluster.tell(c, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  assert cluster.queue_gone(c) == ["call-one"]
  assert cluster.called_off(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert cluster.all_ringing(c) == []
}

// --- Refusals ------------------------------------------------------------------

/// Nothing is rung for a caller the dispatcher does not hold in that queue.
pub fn only_a_waiting_caller_is_picked_up_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert pick_up(c, "call-two") == NotWaiting
  assert pick_up_by(c, "call-one", "elsewhere", supervisor, later())
    == NotWaiting
  assert fake_offer.count(c.offers) == 0

  // Answered already: not waiting.
  let c = ringing_supervisor()
  cluster.reply(c, "call-one", Answered(supervisor, "sup-leg", 0))
  assert pick_up_by(c, "call-one", "support", "another", later()) == NotWaiting
}

/// A caller an agent's phone is ringing for is a conflict, and so is a
/// supervisor already ringing for another caller.
pub fn a_ring_already_going_is_refused_test() {
  let c = cluster.new([#("support", queue(["ann"]))], [#("ann", user())])
  cluster.agent_is(c, "ann", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert pick_up(c, "call-one") == BeingOffered
  assert fake_offer.count(c.offers) == 1

  let c = ringing_supervisor()
  assert pick_up(c, "call-one") == BeingOffered
  cluster.arrive(c, "call-two", "support", 0, 1)
  assert pick_up(c, "call-two") == SupervisorBusy
  assert fake_offer.count(c.offers) == 1
}

/// A question that arrives after the asker stopped waiting starts nothing.
pub fn a_late_question_starts_nothing_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert pick_up_by(c, "call-one", "support", supervisor, monotonic_ms() - 1)
    == TooLate
  assert fake_offer.count(c.offers) == 0
  assert cluster.ringing(c, "call-one") == []
}

// --- A pickup a node that died left behind -----------------------------------

/// Bob is an agent of the queue and the supervisor who picked the caller
/// up, so anything counted as a queue call of his shows: a wrap-up would
/// keep the next caller off him, and his counters would move.
fn bob_the_supervisor() -> cluster.Cluster {
  let c = cluster.new([#("support", queue(["bob"]))], [#("bob", user())])
  cluster.agent_is(c, "bob", "available")
  c
}

/// The sweep found a pickup still open whose caller is gone: it is closed
/// as a pickup, with `member_result` and nothing an agent's call does -- no
/// `agent_wrapup` (the counters are written beside it), no wrap-up, no lamp.
pub fn an_orphaned_pickup_is_closed_as_one_test() {
  let platform = platform_start()
  let c = bob_the_supervisor()
  cluster.orphaned_as(
    c,
    "call-one",
    "support",
    "bob",
    3,
    True,
    Some(cluster.start_of_time + 60),
  )
  let published = published_events()
  let ended = published_values("member_result", "Agent-ID")
  platform_stop(platform)

  assert cluster.report(c).offers == []
  assert ended == [#("exchange", "bob")]
  assert !list.contains(published, #("exchange", "agent_wrapup"))
  assert cluster.lamps(c) == []

  cluster.at(c, 60)
  cluster.arrive(c, "call-two", "support", 0, 60)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// One whose caller is still talking is adopted as a pickup: the
/// supervisor is held and watched for, and the end is the pickup's.
pub fn an_orphaned_pickup_still_going_on_is_adopted_as_one_test() {
  let platform = platform_start()
  let c = bob_the_supervisor()
  cluster.orphaned_as(c, "call-one", "support", "bob", 3, True, None)
  let watched = cluster.watching(c, "call-one")
  let held = cluster.ringing(c, "call-one")
  cluster.at(c, 60)
  cluster.watch_reply(
    c,
    "call-one",
    Ended(Completed, cluster.start_of_time + 60),
  )
  let published = published_events()
  let ended = published_values("member_result", "Agent-ID")
  platform_stop(platform)

  assert watched == ["bob"]
  assert held == ["bob"]
  assert ended == [#("exchange", "bob")]
  assert !list.contains(published, #("exchange", "agent_wrapup"))
  assert cluster.lamps(c) == []

  cluster.arrive(c, "call-two", "support", 0, 60)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// The same pickup handed to a node taking the shard over, whose actor
/// found the supervisor talking to the caller: the call is watched, and its
/// end is the pickup's.
pub fn a_redelivered_caller_a_supervisor_is_talking_to_test() {
  let platform = platform_start()
  let c = bob_the_supervisor()
  cluster.presents(
    c,
    "call-one",
    types.PresentConnected("bob", "bob-leg", cluster.start_of_time, True),
  )
  cluster.redelivered(c, "call-one", "support", 0, 0)
  let waiting = cluster.waiting(c)
  let watched = cluster.watching(c, "call-one")
  cluster.at(c, 60)
  cluster.watch_reply(
    c,
    "call-one",
    Ended(Completed, cluster.start_of_time + 60),
  )
  let published = published_events()
  let ended = published_values("member_result", "Agent-ID")
  platform_stop(platform)

  assert cluster.settled(c) == ["call-one"]
  assert waiting == []
  assert watched == ["bob"]
  assert ended == [#("exchange", "bob")]
  assert !list.contains(published, #("exchange", "agent_wrapup"))
  assert cluster.lamps(c) == []
  cluster.arrive(c, "call-two", "support", 0, 60)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// A supervisor's phone the node that died left ringing, found by the
/// caller's actor, is held as the pickup it is, and a ring that runs out is
/// nobody's miss: the caller waits on, and the next pass rings Bob, with no
/// delay and no stand-down.
pub fn a_redelivered_caller_a_supervisor_is_ringing_for_test() {
  let c = bob_the_supervisor()
  cluster.agent_is(c, "bob", "on_break")
  cluster.presents(
    c,
    "call-one",
    types.PresentRinging(
      ["bob"],
      cluster.start_of_time + pickup.ring_timeout_s,
      True,
    ),
  )
  cluster.redelivered(c, "call-one", "support", 0, 0)
  assert fake_offer.count(c.offers) == 0
  assert cluster.ringing(c, "call-one") == ["bob"]

  cluster.at(c, pickup.ring_timeout_s)
  cluster.watch_reply(c, "call-one", OfferNoAnswer(["bob"]))
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.ringing(c, "call-one") == []
  assert cluster.availability(c, "bob") == "on_break"
  cluster.agent_is(c, "bob", "available")
  cluster.changed(c)
  assert cluster.ringing(c, "call-one") == ["bob"]
}

// --- Nothing of an agent's moves -------------------------------------------

/// Ann and Bob take the queue's callers, and Bob is a supervisor as well.
/// Both are on a break, so a caller who arrives waits for Bob's pickup.
fn bob_on_a_break() -> cluster.Cluster {
  let c =
    cluster.new([#("support", queue(["ann", "bob"]))], [
      #("ann", user()),
      #("bob", user()),
    ])
  cluster.agent_is(c, "ann", "on_break")
  cluster.agent_is(c, "bob", "on_break")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert pick_up_by(c, "call-one", "support", "bob", later())
    == Ringing(pickup.ring_timeout_s)
  c
}

/// The finding: a caller who left while the pickup rang was given up on as
/// an agent's ring is -- Bob's activity cleared, a wrap-up he was in
/// included, and his turn taken. His activity is left as it was.
pub fn a_caller_leaving_a_pickup_leaves_the_supervisors_activity_test() {
  list.each(
    [
      fn(c) { cluster.cancel(c, "call-one", ExitKey) },
      fn(c) {
        cluster.tell(c, dispatcher.Left("call-one", ExitKey))
        True
      },
      fn(c) {
        cluster.channel_gone(c, "call-one")
        True
      },
    ],
    fn(leave) {
      let c = bob_on_a_break()
      // Bob's wrap-up after a call of his own, as the node's activity holds
      // it.
      activity.set_wrapup(cluster.account_id, "bob", 60)
      assert activity.of(cluster.account_id, "bob") == WrappingUp
      assert leave(c)
      cluster.sync(c)
      assert cluster.waiting(c) == []
      assert cluster.all_ringing(c) == []
      assert activity.of(cluster.account_id, "bob") == WrappingUp
      activity.clear(cluster.account_id, "bob")
    },
  )
}

/// The finding: the same caller leaving made Bob free from that second, as
/// a ring he let go would, so the longest idle agent was no longer him. Bob
/// has been free since his break ended, before Ann's did, and he is rung
/// first.
pub fn a_caller_leaving_a_pickup_moves_no_idle_time_test() {
  let c = bob_on_a_break()
  cluster.at(c, 20)
  assert cluster.cancel(c, "call-one", ExitKey)

  cluster.agent_since(c, "bob", "available", 5)
  cluster.agent_since(c, "ann", "available", 10)
  cluster.at(c, 30)
  cluster.arrive(c, "call-two", "support", 0, 30)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// The finding: a supervisor on a pickup was taken to be on a queue call, so
/// an availability change heard while it went on lit their login lamp
/// `early`, and the pickup's end never put it back. The lamp is left alone,
/// and the lamp probe is not told they are on a queue call.
pub fn a_pickup_lights_no_lamp_test() {
  let c = bob_on_a_break()
  cluster.reply(
    c,
    "call-one",
    Answered("bob", "bob-leg", cluster.start_of_time),
  )
  cluster.agent_is(c, "bob", "available")
  cluster.agent_changed(c, "bob")
  assert cluster.lamps(c) == []
  assert process.call(c.dispatcher, 5000, dispatcher.OnQueueCall) == []

  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))
  assert cluster.lamps(c) == []
}

// --- The wire --------------------------------------------------------------

/// The request and every answer survive the bus both ways.
pub fn the_wire_reads_what_it_writes_test() {
  let request =
    Request(
      queue_id: "support",
      call_id: "call-one",
      supervisor_id: supervisor,
      target_type: "device",
      target_id: desk,
      device_ids: [desk],
    )
  assert wire.request_of(wire.request_to_value(cluster.account_id, request))
    == Ok(request)
  list.each(
    [
      Ringing(30),
      NotWaiting,
      BeingOffered,
      SupervisorBusy,
      pickup.NotStarted("no_control_queue"),
      TooLate,
    ],
    fn(answer) {
      assert wire.answer_of(doc.object(wire.answer_to_value(answer)))
        == Ok(answer)
    },
  )
  assert wire.answer_of(doc.object([#("Result", doc.String("what"))]))
    == Error(Nil)
}

// --- Answered once the ring is out --------------------------------------------

/// A started offer is not yet a phone ringing: the answer waits for the
/// offer to say its bridge is out.
pub fn the_answer_waits_for_the_bridge_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let answer = ask(c, "call-one", "support", supervisor, later())
  assert fake_offer.count(c.offers) == 1
  assert process.receive(answer, 0) == Error(Nil)
  cluster.reply(c, "call-one", OfferRinging([supervisor]))
  assert process.receive(answer, 1000) == Ok(Ringing(pickup.ring_timeout_s))
}

/// An offer that fails before its bridge is out rang nothing, and says why:
/// the phones built to no endpoint on the caller's call. The caller waits
/// on, and the supervisor may be asked for again.
pub fn a_ring_that_never_went_out_is_not_started_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let answer = ask(c, "call-one", "support", supervisor, later())
  cluster.reply(c, "call-one", Failed("no_endpoints"))
  assert process.receive(answer, 1000) == Ok(pickup.NotStarted("no_endpoints"))
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.settled(c) == []
  assert cluster.ringing(c, "call-one") == []
  assert pick_up(c, "call-one") == Ringing(pickup.ring_timeout_s)
}

/// An offer whose process ends before its bridge is out rang nothing.
pub fn a_ring_whose_process_died_is_not_started_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let answer = ask(c, "call-one", "support", supervisor, later())
  fake_offer.died(c.offers)
  cluster.sync(c)
  assert process.receive(answer, 1000)
    == Ok(pickup.NotStarted(pickup.offer_down))
  assert cluster.waiting(c) == ["call-one"]
}

/// A caller who leaves before the ring is out was not waiting after all.
pub fn a_caller_gone_before_the_ring_is_not_waiting_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let answer = ask(c, "call-one", "support", supervisor, later())
  assert cluster.cancel(c, "call-one", ExitKey)
  assert process.receive(answer, 1000) == Ok(NotWaiting)

  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let answer = ask(c, "call-one", "support", supervisor, later())
  cluster.left(c, "call-one", Hangup)
  assert process.receive(answer, 1000) == Ok(NotWaiting)
}

/// A bridge out only after the requester stopped waiting has nobody to
/// tell, and Crossbar has said nothing rang: the ring is called off at
/// once, and the caller waits on as for a supervisor who did not answer.
pub fn a_ring_out_after_the_deadline_is_called_off_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let answer = ask(c, "call-one", "support", supervisor, monotonic_ms() + 30)
  process.sleep(60)
  cluster.reply(c, "call-one", OfferRinging([supervisor]))
  assert process.receive(answer, 100) == Error(Nil)
  assert cluster.called_off(c) == ["call-one"]

  // The ring ends as the call-off makes it end.
  cluster.reply(c, "call-one", Failed("called_off"))
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.settled(c) == []
  assert cluster.ringing(c, "call-one") == []
  assert process.receive(answer, 0) == Error(Nil)
}

// --- The requester's deadline ---------------------------------------------------

/// The deadline travels with the request, and a request without one -- from
/// a node of the release before -- reads as it did.
pub fn the_deadline_travels_with_the_request_test() {
  let request =
    Request(
      queue_id: "support",
      call_id: "call-one",
      supervisor_id: supervisor,
      target_type: "device",
      target_id: desk,
      device_ids: [desk],
    )
  let value = wire.request_to_value(cluster.account_id, request)
  assert wire.deadline_of(value) == None
  let value = wire.with_deadline(value, 1_790_000_003_000)
  assert wire.deadline_of(value) == Some(1_790_000_003_000)
  assert wire.request_of(value) == Ok(request)
}

/// The holder gives its dispatcher its own wait when the request is fresh,
/// and no more than what is left of the requester's otherwise, less the
/// time the answer needs to get back.
pub fn the_holder_gives_no_more_than_the_requester_has_left_test() {
  let now = 1_790_000_000_000
  assert wire.budget_ms(None, now) == wire.holder_timeout_ms
  // Read at once: the holder's own two seconds.
  assert wire.budget_ms(Some(now + wire.timeout_ms), now)
    == wire.holder_timeout_ms
  // Read two seconds late: what is left of the three.
  assert wire.budget_ms(Some(now + 1000), now) == 750
  // Read after the requester gave up.
  assert wire.budget_ms(Some(now - 5), now) < 0
}

/// A request read with no time left for an answer to get back is not put
/// to the dispatcher at all: nothing rings, whatever the dispatcher would
/// have said.
pub fn a_request_read_too_late_rings_nothing_test() {
  let c = quiet_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let request =
    Request(
      queue_id: "support",
      call_id: "call-one",
      supervisor_id: supervisor,
      target_type: "user",
      target_id: supervisor,
      device_ids: [desk],
    )
  assert wire.ask_dispatcher(c.dispatcher, request, 0) == TooLate
  assert wire.ask_dispatcher(c.dispatcher, request, -40) == TooLate
  cluster.sync(c)
  assert fake_offer.count(c.offers) == 0
  assert cluster.ringing(c, "call-one") == []
}

/// The broker drops a request that has waited in the holder's queue as long
/// as its requester waits for the answer.
pub fn the_pickup_queue_drops_what_nobody_waits_for_test() {
  let spec = listener.to_spec(wire.responder(64))
  let assert Ok(queue) = dict.get(spec, "queue")
  assert decode.run(queue, decode.at(["ttl"], decode.int))
    == Ok(wire.timeout_ms)
}

// --- The fake broker -------------------------------------------------------

type Platform

@external(erlang, "platform_fakes", "start")
fn platform_start() -> Platform

@external(erlang, "platform_fakes", "stop")
fn platform_stop(platform: Platform) -> Nil

@external(erlang, "kapi_contract_ffi", "published_events")
fn published_events() -> List(#(String, String))

@external(erlang, "kapi_contract_ffi", "published_values")
fn published_values(event: String, header: String) -> List(#(String, String))

@external(erlang, "kapi_contract_ffi", "rejected")
fn rejected() -> List(String)
