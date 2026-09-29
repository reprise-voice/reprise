//// The dispatcher's state machine, against a fake clock and a fake offer.

import callcenter/activity
import callcenter/dispatcher
import callcenter/dispatcher/arrival
import callcenter/dispatcher/offers
import callcenter/status_query
import callcenter/types.{
  Answered, Busy, CallerHangup, Completed, Ended, ExitKey, Failed, Hangup,
  OfferNoAnswer, OfferRinging, OnCall, Rejected, Timeout, Transferred,
}
import cf_callcenter
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo
import support/cluster
import support/fake_activity
import support/fake_calls
import support/fake_offer

// --- Queue and user documents ----------------------------------------------

fn queue(strategy: String, agents: List(#(String, Int, Int))) -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String(strategy)),
    #("agent_ring_timeout", doc.Int(20)),
    #("agent_wrapup_time", doc.Int(10)),
    #(
      "agents",
      doc.List(
        list.map(agents, fn(agent) {
          let #(id, level, position) = agent
          doc.object([
            #("id", doc.String(id)),
            #("level", doc.Int(level)),
            #("position", doc.Int(position)),
          ])
        }),
      ),
    ),
  ])
}

fn user(settings: List(#(String, doc.Value))) -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object(settings)),
  ])
}

fn two_agent_queue() -> cluster.Cluster {
  let cluster =
    cluster.new(
      [#("support", queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)]))],
      [#("ann", user([])), #("bob", user([]))],
    )
  cluster.agent_is(cluster, "ann", "available")
  cluster.agent_is(cluster, "bob", "available")
  cluster
}

// --- Arrival and the first offer -------------------------------------------

/// The first caller of an account starts everything: the member is held, the
/// strategy is asked, and an offer goes out.
pub fn a_caller_is_offered_to_an_agent_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.waiting(c) == ["call-one"]
  assert fake_offer.count(c.offers) == 1
  // longest_idle, and neither has taken a call: the tier order decides.
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// Nobody available is nobody offered, and the caller waits.
pub fn a_caller_with_no_agent_waits_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "on_break")
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.waiting(c) == ["call-one"]
  assert fake_offer.count(c.offers) == 0
}

/// Requirement 1.4: priority first, then age.
pub fn callers_are_ordered_by_priority_then_age_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "early", "support", 0, 0)
  cluster.arrive(c, "later", "support", 0, 30)
  cluster.arrive(c, "vip", "support", 10, 60)

  let statuses = cluster.status(c, Some("support"))
  let assert [support] = statuses
  let assert Ok(callers) = doc.get_list(support, ["Waiting"])
  let ids =
    list.filter_map(callers, fn(caller) { doc.get_string(caller, ["Call-ID"]) })
  assert ids == ["vip", "early", "later"]
}

/// An agent in two queues takes whoever has waited longest in either. The
/// caller of `zzz-support` has waited six minutes and the caller of
/// `aaa-sales` one second: queue ids are not an order, and a dispatcher that
/// served the queues alphabetically would hand ann the newcomer.
pub fn an_agent_in_two_queues_takes_the_longest_waiting_test() {
  let c =
    cluster.new(
      [
        #("aaa-sales", queue("longest_idle", [#("ann", 1, 1)])),
        #("zzz-support", queue("longest_idle", [#("ann", 1, 1)])),
      ],
      [#("ann", user([]))],
    )
  cluster.agent_is(c, "ann", "logged_out")
  cluster.arrive(c, "patient", "zzz-support", 0, 0)
  cluster.at(c, 359)
  cluster.arrive(c, "fresh", "aaa-sales", 0, 359)
  cluster.at(c, 360)
  cluster.agent_logs_in(c, "ann")

  assert cluster.ringing(c, "patient") == ["ann"]
  assert cluster.ringing(c, "fresh") == []
}

/// Priority is compared across the account too: a priority caller in the
/// other queue goes first, however long this one has waited.
pub fn priority_goes_first_across_queues_test() {
  let c =
    cluster.new(
      [
        #("aaa-sales", queue("longest_idle", [#("ann", 1, 1)])),
        #("zzz-support", queue("longest_idle", [#("ann", 1, 1)])),
      ],
      [#("ann", user([]))],
    )
  cluster.agent_is(c, "ann", "logged_out")
  cluster.arrive(c, "patient", "aaa-sales", 0, 0)
  cluster.at(c, 300)
  cluster.arrive(c, "vip", "zzz-support", 5, 300)
  cluster.agent_logs_in(c, "ann")

  assert cluster.ringing(c, "vip") == ["ann"]
  assert cluster.ringing(c, "patient") == []
}

/// The other reader of a `status_resp` is the callflow action, which asks the
/// two questions a caller arriving needs answered -- is the queue full, and
/// could anybody take me. `Waiting` is the list of callers, for a screen, and
/// the counts are named separately: read as numbers they are both nothing,
/// which lets a caller into a full queue and turns one away from a staffed
/// one.
pub fn the_status_is_what_a_caller_arriving_reads_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)

  let assert [support] = cluster.status(c, Some("support"))
  assert doc.get_int(support, ["Waiting-Count"]) == Ok(1)
  assert doc.get_int(support, ["Agents-Available"]) == Ok(0)

  let answered = doc.object([#("Queues", doc.List([support]))])
  let status = cf_callcenter.status_of("support", [answered])

  // One caller waiting is a full queue when the limit is one.
  assert cf_callcenter.entry(
      doc.object([#("max_queue_size", doc.Int(1))]),
      status,
    )
    == cf_callcenter.Full

  // Nobody logged in, and a queue that will not take a caller without one.
  assert cf_callcenter.entry(
      doc.object([#("enter_when_empty", doc.Bool(False))]),
      status,
    )
    == cf_callcenter.NoAgents
}

/// The live status leaves as a `status_resp` and reaches a client through
/// Crossbar's rendering, so what this actor writes and what that reads have
/// to be one spelling: the wire's, which `kapi.callcenter.status_resp` is
/// the statement of. A dispatcher answering `call_id` where the schema says
/// `Call-ID` renders as a row of nulls and an empty waiting list, which is
/// what this catches.
pub fn the_status_is_what_crossbar_renders_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)

  let assert [support] = cluster.status(c, Some("support"))
  let rendered = status_query.to_api(support)
  assert doc.get_string(rendered, ["queue_id"]) == Ok("support")

  let assert Ok([waiting]) = doc.get_list(rendered, ["waiting"])
  assert doc.get_string(waiting, ["call_id"]) == Ok("call-one")
  assert doc.get_int(waiting, ["position"]) == Ok(1)
  assert doc.get_int(waiting, ["joined_timestamp"]) != Error(Nil)

  let assert Ok(agents) = doc.get_list(rendered, ["agents"])
  assert list.filter_map(agents, fn(agent) {
      doc.get_string(agent, ["agent_id"])
    })
    == ["ann", "bob"]
  assert doc.get_string(waiting, ["offered_to"]) == Error(Nil)
  let assert [ann, ..] = agents
  assert doc.get_string(ann, ["availability"]) == Ok("logged_out")
  assert doc.get_string(ann, ["tier_state"]) == Ok("ready")
  assert doc.get_int(ann, ["tier_level"]) == Ok(1)
}

/// An agent's entry in the status names the caller they are being rung for
/// or talking to, so a supervisor who opens the live view mid-call can
/// listen in: the caller's row has left `Waiting` once the agent answers,
/// and the events that named the call went by before the page loaded.
pub fn the_status_names_the_call_an_agent_is_on_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  let ann = agent_status(c, "support", "ann")
  assert doc.get_string(ann, ["Call-ID"]) == Ok("call-one")
  assert doc.get_string(ann, ["Queue-ID"]) == Ok("support")
  assert doc.get_bool(ann, ["Connected"]) == Ok(False)
  // Nobody is ringing bob, and his entry says nothing of a call.
  let bob = agent_status(c, "support", "bob")
  assert doc.get(bob, ["Call-ID"]) == Error(Nil)
  assert doc.get(bob, ["Connected"]) == Error(Nil)

  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  let ann = agent_status(c, "support", "ann")
  // The caller's call, not the agent's leg: listening to it hears both.
  assert doc.get_string(ann, ["Call-ID"]) == Ok("call-one")
  assert doc.get_bool(ann, ["Connected"]) == Ok(True)

  let rendered = status_query.to_api(queue_status(c, "support"))
  let assert Ok(agents) = doc.get_list(rendered, ["agents"])
  let assert [ann_api, bob_api] = agents
  assert doc.get_string(ann_api, ["call_id"]) == Ok("call-one")
  assert doc.get_string(ann_api, ["queue_id"]) == Ok("support")
  assert doc.get_bool(ann_api, ["connected"]) == Ok(True)
  assert doc.get(bob_api, ["call_id"]) == Ok(doc.Null)

  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))
  let ann = agent_status(c, "support", "ann")
  assert doc.get(ann, ["Call-ID"]) == Error(Nil)
  assert doc.get(ann, ["Connected"]) == Error(Nil)
}

/// An agent in two queues on a call from one of them is on it in both
/// entries, and both say which queue the caller came in through: that is
/// the queue a supervisor's eavesdrop has to go through.
pub fn the_status_names_the_queue_of_the_call_test() {
  let c =
    cluster.new(
      [
        #("sales", queue("longest_idle", [#("ann", 1, 1)])),
        #("support", queue("longest_idle", [#("ann", 1, 1)])),
      ],
      [#("ann", user([]))],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )

  let in_sales = agent_status(c, "sales", "ann")
  assert doc.get_string(in_sales, ["Call-ID"]) == Ok("call-one")
  assert doc.get_string(in_sales, ["Queue-ID"]) == Ok("support")
  assert doc.get_bool(in_sales, ["Connected"]) == Ok(True)
}

fn queue_status(c: cluster.Cluster, queue_id: String) -> doc.Value {
  let assert [entry] = cluster.status(c, Some(queue_id))
  entry
}

fn agent_status(
  c: cluster.Cluster,
  queue_id: String,
  agent_id: String,
) -> doc.Value {
  let assert Ok(agents) = doc.get_list(queue_status(c, queue_id), ["Agents"])
  let assert Ok(agent) =
    list.find(agents, fn(agent) {
      doc.get_string(agent, ["Agent-ID"]) == Ok(agent_id)
    })
  agent
}

// --- An agent is never in two offers ---------------------------------------

/// The invariant the whole design turns on: one dispatcher per account, so
/// two queues cannot ring one agent, and two callers in one queue cannot
/// either.
pub fn an_agent_is_never_in_two_offers_test() {
  let c =
    cluster.new(
      [
        #("support", queue("longest_idle", [#("ann", 1, 1)])),
        #("sales", queue("longest_idle", [#("ann", 1, 1)])),
      ],
      [#("ann", user([]))],
    )
  cluster.agent_is(c, "ann", "available")

  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.arrive(c, "call-two", "sales", 0, 0)

  assert cluster.ringing(c, "call-one") == ["ann"]
  assert cluster.ringing(c, "call-two") == []
  assert cluster.all_ringing(c) == ["ann"]
  assert fake_offer.count(c.offers) == 1
}

/// And the second caller is offered as soon as the first offer resolves.
pub fn the_next_caller_is_offered_when_the_agent_is_free_test() {
  let c =
    cluster.new([#("support", queue("longest_idle", [#("ann", 1, 1)]))], [
      #("ann", user([])),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.arrive(c, "call-two", "support", 0, 10)
  assert cluster.all_ringing(c) == ["ann"]

  // The caller hangs up while ringing: the agent is free again at once.
  assert cluster.cancel(c, "call-one", Hangup)
  assert cluster.all_ringing(c) == ["ann"]
  assert cluster.ringing(c, "call-two") == ["ann"]
}

// --- Answering -------------------------------------------------------------

/// An answered caller is out of the queue, and their member is kept on the
/// broker until the call ends: a node that dies meanwhile leaves it for the
/// next holder, whose caller's actor takes the call over. Exactly one
/// settlement happens, at the end.
pub fn an_answered_call_is_settled_when_it_ends_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  assert cluster.settled(c) == []
  assert cluster.waiting(c) == []
  // The agent is still held until the call ends.
  assert cluster.all_ringing(c) == ["ann"]

  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))
  assert cluster.settled(c) == ["call-one"]
}

/// The caller delivered again while their phone rings -- the shard hands on
/// a redelivery of the same passage, and the one held before it is settled
/// there -- is settled at the end of the call by the delivery held at the
/// answer. The shard settles only the delivery it holds, so the one the
/// offer was made from would settle nothing, and the one held would come
/// back at the next failover as a call over long ago.
pub fn a_call_is_settled_by_the_delivery_held_at_the_answer_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  cluster.redelivered(c, "call-one", "support", 0, 0)
  // Still the one offer: the new delivery is the same caller, ringing.
  assert fake_offer.count(c.offers) == 1
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  assert cluster.settled_deliveries(c) == []
  assert cluster.waiting(c) == []
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))
  assert cluster.settled_deliveries(c) == ["call-one again"]
}

/// The same for a caller whose member for another queue reached this node
/// while the first queue's phones rang for them: the end settles the
/// member held for them at the answer, which is the second queue's.
pub fn a_call_is_settled_by_a_superseding_member_test() {
  let c =
    cluster.new(
      [
        #("support", queue("longest_idle", [#("ann", 1, 1)])),
        #("sales", queue("longest_idle", [#("bob", 1, 1)])),
      ],
      [#("ann", user([])), #("bob", user([]))],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  cluster.at(c, 30)
  cluster.redelivered(c, "call-one", "sales", 0, 30)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time + 31),
  )
  assert cluster.waiting(c) == []
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 90))
  assert cluster.settled_deliveries(c) == ["call-one again"]
}

/// Ring-all: the losers go free the moment somebody answers, and only the
/// winner is held.
pub fn the_losers_of_a_ring_all_go_free_test() {
  let c =
    cluster.new(
      [#("support", queue("ring_all", [#("ann", 1, 1), #("bob", 1, 2)]))],
      [
        #("ann", user([])),
        #("bob", user([])),
      ],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]

  cluster.reply(
    c,
    "call-one",
    Answered("bob", "agent-leg", cluster.start_of_time),
  )
  assert cluster.all_ringing(c) == ["bob"]
}

/// A ring of everybody is everybody every time. cal comes off their break
/// while ann and bob's phones are ringing out; once their delays have passed
/// the retry rings all three, not just the one who has not rung yet.
pub fn a_ring_all_retry_rings_everybody_again_test() {
  let agents = [#("ann", 1, 1), #("bob", 1, 2), #("cal", 1, 3)]
  let c =
    cluster.new([#("support", queue("ring_all", agents))], [
      #("ann", user([])),
      #("bob", user([])),
      #("cal", user([])),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  cluster.agent_is(c, "cal", "on_break")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]

  cluster.reply(c, "call-one", OfferNoAnswer(["ann", "bob"]))
  cluster.agent_is(c, "cal", "available")
  quiet_at(c, 1)
  assert cluster.ringing(c, "call-one") == ["ann", "bob", "cal"]
}

/// A queue moved to ring_all in the middle of a caller's passage rings
/// everybody who is free, not everybody who has not rung yet. ann has had
/// the caller under sequential and her delay has passed; bob is still
/// ringing when the strategy changes.
pub fn a_move_to_ring_all_forgets_who_has_rung_test() {
  let agents = [#("ann", 1, 1), #("bob", 1, 2), #("cal", 1, 3)]
  let c =
    cluster.new([#("support", queue("sequential", agents))], [
      #("ann", user([])),
      #("bob", user([])),
      #("cal", user([])),
    ])
  list.each(["ann", "bob", "cal"], fn(agent_id) {
    cluster.agent_is(c, agent_id, "available")
  })
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.ringing(c, "call-one") == ["bob"]
  cluster.at(c, 5)
  cluster.tick(c)

  cluster.put_queue(c, "support", queue("ring_all", agents))
  cluster.reply(c, "call-one", OfferNoAnswer(["bob"]))
  assert cluster.ringing(c, "call-one") == ["ann", "cal"]
}

/// The end of the call puts the agent in wrap-up for the queue's seconds,
/// and the wrap-up ends on the timer and not before.
pub fn a_call_ending_starts_the_wrapup_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))

  // A new caller does not get the agent who is wrapping up.
  fake_offer.clear(c.offers)
  cluster.at(c, 61)
  cluster.arrive(c, "call-two", "support", 0, 61)
  assert cluster.ringing(c, "call-two") == ["bob"]

  // Past the wrap-up the agent is free again.
  cluster.at(c, 75)
  cluster.tick(c)
  let agents = cluster.report(c).agents
  assert list.contains(list.map(agents, fn(agent) { agent.0 }), "ann")
}

/// An agent who passes the caller on has finished with them: the call is
/// over for the queue, recorded as transferred, and the agent goes into
/// wrap-up like after any other call.
pub fn a_transfer_ends_the_queue_call_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  cluster.reply(c, "call-one", Ended(Transferred, cluster.start_of_time + 60))
  assert cluster.settled(c) == ["call-one"]

  // Ann is wrapping up, so the next caller goes to bob.
  fake_offer.clear(c.offers)
  cluster.at(c, 61)
  cluster.arrive(c, "call-two", "support", 0, 61)
  assert cluster.ringing(c, "call-two") == ["bob"]

  // Nobody is left waiting behind this test for a later one to trip over.
  assert cluster.cancel(c, "call-two", Hangup)
}

// --- The login lamp ----------------------------------------------------------

/// An answered offer shows `early` on the agent's lamp, and the end of the
/// call shows the availability they are in then: wrap-up is not a call.
/// Ringing and missing show nothing.
pub fn the_lamp_follows_the_queue_call_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.lamps(c) == []

  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  assert cluster.lamps(c) == [#("ann", "early")]

  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))
  assert cluster.lamps(c) == [#("ann", "early"), #("ann", "confirmed")]
}

/// A missed offer is not a call, and the lamp is left to `availability.set`.
pub fn a_miss_leaves_the_lamp_alone_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.lamps(c) == []
}

/// A change of availability mid-call -- which `availability.set` has just
/// published as its own state -- is answered with `early` again, and the end
/// of the call shows the new availability.
pub fn an_availability_change_mid_call_keeps_the_lamp_early_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )

  cluster.agent_is(c, "ann", "on_break")
  cluster.agent_changed(c, "ann")
  assert cluster.lamps(c) == [#("ann", "early"), #("ann", "early")]

  // Somebody not on a call is left to `availability.set`.
  cluster.agent_changed(c, "bob")
  assert cluster.lamps(c) == [#("ann", "early"), #("ann", "early")]

  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))
  assert cluster.lamps(c)
    == [#("ann", "early"), #("ann", "early"), #("ann", "terminated")]
}

/// A call answered on a node that died is this node's to show once adopted.
pub fn an_adopted_call_lights_the_lamp_test() {
  let c = two_agent_queue()
  cluster.orphaned(c, "call-one", "support", "ann", 0, None)
  assert cluster.lamps(c) == [#("ann", "early")]

  cluster.watch_reply(
    c,
    "call-one",
    Ended(Completed, cluster.start_of_time + 30),
  )
  assert cluster.lamps(c) == [#("ann", "early"), #("ann", "confirmed")]
}

// --- Missing ---------------------------------------------------------------

/// A miss moves on to the next agent, and the caller keeps waiting.
pub fn a_miss_moves_to_the_next_agent_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.ringing(c, "call-one") == ["bob"]
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.settled(c) == []
}

/// The per-agent delay in requirement 1.6 keeps them out of the next offer
/// until it has passed.
pub fn a_delay_keeps_an_agent_out_test() {
  let c =
    cluster.new([#("support", queue("longest_idle", [#("ann", 1, 1)]))], [
      #("ann", user([#("no_answer_delay", doc.Int(30))])),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))

  // Still the only agent, but not for another thirty seconds.
  assert cluster.ringing(c, "call-one") == []
  cluster.at(c, 31)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

pub fn busy_and_rejected_are_misses_too_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", Busy("ann"))
  assert cluster.ringing(c, "call-one") == ["bob"]
  cluster.reply(c, "call-one", Rejected("bob"))
  assert cluster.ringing(c, "call-one") == []
  assert cluster.waiting(c) == ["call-one"]
}

/// An offer that could not even be started is not a miss: nothing rang.
pub fn an_offer_that_failed_to_start_is_not_a_miss_test() {
  let c = two_agent_queue()
  fake_offer.failing(c.offers, "no channel")
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.all_ringing(c) == []
  assert cluster.waiting(c) == ["call-one"]

  fake_offer.working(c.offers)
  cluster.changed(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// A failure once the offer is running releases the agent and the caller is
/// offered again, to the next agent: a failure is not a miss, but an
/// endpoint that could not ring just now will not ring on the next pass
/// either, so the agent is left alone for a moment and the caller moves on.
/// Once everybody has failed, the list starts again when the moment passes.
pub fn a_failed_offer_releases_the_agent_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", Failed("bridge died"))
  assert cluster.ringing(c, "call-one") == ["bob"]

  cluster.reply(c, "call-one", Failed("bridge died"))
  assert cluster.ringing(c, "call-one") == []
  assert cluster.waiting(c) == ["call-one"]

  quiet_at(c, 6)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// The caller hung up while ann's phone rang. That is the caller leaving,
/// not ann missing them: she is not put on a delay, and the caller who has
/// gone is not offered to bob in the same breath.
pub fn a_caller_who_hangs_up_during_the_ring_leaves_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.left(c, "call-one", Hangup)

  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert cluster.all_ringing(c) == []
  assert fake_offer.count(c.offers) == 1

  // Ann is free at once, not after a delay.
  cluster.arrive(c, "call-two", "support", 0, 0)
  assert cluster.ringing(c, "call-two") == ["ann"]

  // A second word of the caller leaving has nothing left to settle.
  assert !cluster.cancel(c, "call-one", Hangup)
  assert cluster.settled(c) == ["call-one"]

  // Nobody is left waiting behind this test for a later one to trip over.
  assert cluster.cancel(c, "call-two", Hangup)
}

/// A caller works down the list before starting over. With no delay after a
/// miss, ann's delay is over by the time bob's phone rings out; a dispatcher
/// deciding each pass from the delays alone would ring ann again and cal
/// never.
pub fn a_caller_works_down_the_list_before_starting_over_test() {
  let agents = [#("ann", 1, 1), #("bob", 1, 2), #("cal", 1, 3)]
  let c =
    cluster.new([#("support", queue("sequential", agents))], [
      #("ann", user([])),
      #("bob", user([])),
      #("cal", user([])),
    ])
  list.each(["ann", "bob", "cal"], fn(agent_id) {
    cluster.agent_is(c, agent_id, "available")
  })
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.ringing(c, "call-one") == ["bob"]
  cluster.at(c, 10)
  cluster.tick(c)
  cluster.reply(c, "call-one", OfferNoAnswer(["bob"]))
  assert cluster.ringing(c, "call-one") == ["cal"]
  cluster.at(c, 20)
  cluster.tick(c)
  cluster.reply(c, "call-one", OfferNoAnswer(["cal"]))
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// Requirement 0.6: an offer that never comes back has a ceiling, and past
/// it the agent is released.
pub fn an_offer_has_a_ceiling_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  // Twenty seconds of ring timeout plus five of grace.
  cluster.at(c, 24)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]

  // The offer went without a word. Its monitor says so at once, and the
  // offer is closed as one that failed, so the next agent has it now.
  fake_offer.died(c.offers)
  cluster.at(c, 26)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// The other half of the ceiling: an offer whose caller's actor is still
/// there has not finished at its ceiling -- the actor gives up on a ring at
/// the same ceiling, and its word may be on its way -- and is given a
/// minute more. Past that the actor has lost it: the offer is taken back as
/// a failure, nobody's miss, and a word that comes after names an offer
/// this dispatcher no longer holds.
pub fn an_offer_still_running_is_given_a_minute_past_its_ceiling_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.at(c, 60)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert fake_offer.count(c.offers) == 1

  cluster.at(c, 600)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["bob"]
  // Ann's ring's word, late, is not about Bob's.
  let assert Ok(first) = fake_offer.requests(c.offers) |> list.first
  fake_offer.reply(first, OfferNoAnswer(["ann"]))
  cluster.sync(c)
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// An offer's process is not linked to the dispatcher, so its crash is not
/// the dispatcher's: the monitor hears it, and an offer that ended before
/// anybody answered is a failure. Nobody missed the caller -- the agent is
/// left alone for a moment and not counted -- and the caller is offered
/// again.
pub fn an_offer_that_crashes_before_an_answer_fails_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  fake_offer.died(c.offers)
  cluster.sync(c)
  assert cluster.alive(c)
  assert cluster.ringing(c, "call-one") == []
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.settled(c) == []
  // Not a miss: one would have stood her down.
  assert cluster.availability_becomes(c, "ann", "logged_out") == "available"

  // Offered again once the moment a failure leaves her alone is over.
  cluster.at(c, 5)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert fake_offer.count(c.offers) == 2
}

/// After an answer the caller's actor is what watches the call, and one
/// that ends without saying the call did leaves nothing to say it. The call
/// is closed here, as a call whose end was lost, and settled, and the agent
/// goes to their wrap-up like after any other call instead of staying busy
/// for ever.
pub fn an_offer_that_crashes_after_an_answer_is_ended_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "ann-leg", cluster.start_of_time + 2),
  )
  assert cluster.settled(c) == []
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.at(c, 60)
  fake_offer.died(c.offers)
  cluster.sync(c)
  assert cluster.alive(c)
  assert cluster.report(c).offers == []
  // Settled once, at the end, and not again.
  assert cluster.settled(c) == ["call-one"]

  // Free once the queue's ten seconds of wrap-up are over.
  cluster.at(c, 71)
  cluster.tick(c)
  cluster.arrive(c, "call-two", "support", 0, 71)
  assert cluster.ringing(c, "call-two") != []
}

// --- Activity --------------------------------------------------------------

/// What the agents' phones are doing comes from the activity actor, and an
/// agent it says is on a call of their own is not rung for a queue caller.
pub fn an_agent_on_a_call_is_passed_over_test() {
  let c = two_agent_queue()
  fake_activity.agents(c.activity, [#("ann", OnCall(queue_call: False))])
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// An activity actor that does not answer is not a node's worth of idle
/// agents: nobody is rung until it answers again, the dispatcher is still
/// there, and the caller waits.
pub fn an_activity_that_does_not_answer_offers_nobody_test() {
  let c = two_agent_queue()
  fake_activity.silent(c.activity, "it did not answer in time")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.alive(c)
  assert cluster.waiting(c) == ["call-one"]
  assert fake_offer.count(c.offers) == 0
  // Nor is it nobody: how many is not said (`agents_available_test`).
  let assert [support] = cluster.status(c, Some("support"))
  assert doc.get_int(support, ["Agents-Available"]) == Error(Nil)

  fake_activity.agents(c.activity, [])
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// The activity is read once a pass, whoever is waiting and however many
/// agents there are: a pass over three callers and two agents is one
/// question to the node's one activity actor, not six.
pub fn the_activity_is_read_once_a_pass_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.arrive(c, "call-two", "support", 0, 1)
  cluster.arrive(c, "call-three", "support", 0, 2)

  let before = fake_activity.reads(c.activity)
  cluster.tell(c, dispatcher.Changed)
  cluster.sync(c)
  // One for the pass and one for the report `sync` waits on, and at most
  // one more for a tick that happened to land in between. Asked per agent
  // per caller it would have been at least six.
  let reads = fake_activity.reads(c.activity) - before
  assert reads >= 2 && reads <= 3
}

/// A dispatcher that has just taken its account has an activity table the
/// switches have not answered for yet, in which an agent on a personal call
/// looks idle. Nobody is offered until they answer: the redelivered caller
/// waits, and then goes to whoever the answer says is free.
pub fn nobody_is_offered_before_the_switches_answer_test() {
  let c = two_agent_queue()
  fake_activity.unsynced(c.activity, [])
  cluster.redelivered(c, "call-one", "support", 0, 0)
  assert cluster.waiting(c) == ["call-one"]
  assert fake_offer.count(c.offers) == 0

  cluster.at(c, 2)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 0

  // The answer: Ann has been on a call of her own all along.
  fake_activity.agents(c.activity, [#("ann", OnCall(queue_call: False))])
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// An answer that never comes is not a caller waiting for ever: past five
/// seconds the dispatcher offers on the channel events it has.
pub fn the_wait_for_the_switches_has_a_ceiling_test() {
  let c = two_agent_queue()
  fake_activity.unsynced(c.activity, [])
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.at(c, 4)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 0

  cluster.at(c, 5)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// The review's finding: the node's activity actor restarts under its
/// supervisor, and the new one watches nothing -- no channel events for the
/// account, an empty table, every agent idle. A dispatcher that was synced
/// used to go on believing it, and offered Ann while she was on a call of
/// her own. The reading says the account is not watched: the dispatcher
/// watches it again in the node's actor and offers nobody until the
/// switches answer the new one.
pub fn an_activity_restart_is_noticed_test() {
  let c = two_agent_queue()
  cluster.tick(c)
  // The restart: the node's actor forgets the account, and the reading says
  // so.
  activity.forget(cluster.account_id)
  let _barrier = activity.of(cluster.account_id, "")
  assert !activity_watches(cluster.account_id)
  fake_activity.restarted(c.activity)

  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.waiting(c) == ["call-one"]
  assert fake_offer.count(c.offers) == 0
  assert activity_watches(cluster.account_id)

  // Still unwatched: watched again, and still nobody offered.
  cluster.at(c, 10)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 0

  // The new actor's answer: Ann has been on a call of her own all along.
  fake_activity.agents(c.activity, [#("ann", OnCall(queue_call: False))])
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// Watched again but the switches never answer the new actor: the same
/// five-second ceiling as a dispatcher's start, counted from the watch.
pub fn the_wait_after_a_restart_has_the_same_ceiling_test() {
  let c = two_agent_queue()
  cluster.tick(c)
  fake_activity.restarted(c.activity)
  cluster.at(c, 20)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert fake_offer.count(c.offers) == 0

  fake_activity.unsynced(c.activity, [])
  cluster.at(c, 24)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 0

  cluster.at(c, 25)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// A reading that is watched but not synced, once the dispatcher is synced,
/// is the ceiling having passed on a query that failed: nothing changes.
pub fn an_unsynced_reading_after_the_ceiling_changes_nothing_test() {
  let c = two_agent_queue()
  fake_activity.unsynced(c.activity, [])
  cluster.at(c, 5)
  cluster.tick(c)
  cluster.at(c, 6)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

fn activity_watches(account_id: String) -> Bool {
  process.call(process.named_subject(activity.name()), 1000, activity.Accounts)
  |> list.contains(account_id)
}

// --- Idle ------------------------------------------------------------------

fn three_agent_queue(strategy: String) -> cluster.Cluster {
  let c =
    cluster.new(
      [
        #(
          "support",
          queue(strategy, [#("ann", 1, 1), #("bob", 1, 2), #("cal", 1, 3)]),
        ),
      ],
      [#("ann", user([])), #("bob", user([])), #("cal", user([]))],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  cluster.agent_is(c, "cal", "available")
  c
}

/// An agent whose phone rang out is no longer the one who has waited
/// longest. ann misses the first caller and bob takes them; the next caller
/// goes to cal, who has not been rung at all, and not back to ann -- who,
/// with no delay after a miss and no queue call on her document, would
/// otherwise stay at the top and cost every caller a full ring timeout.
pub fn a_missed_offer_ends_the_idle_test() {
  let c = three_agent_queue("longest_idle")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.at(c, 20)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.ringing(c, "call-one") == ["bob"]
  answered_and_done(c, "call-one", "bob", 22)

  quiet_at(c, 45)
  cluster.arrive(c, "call-two", "support", 0, 45)
  assert cluster.ringing(c, "call-two") == ["cal"]
  cluster.arrive(c, "call-three", "support", 0, 45)
  assert cluster.ringing(c, "call-three") == ["ann"]
}

/// A fresh login is idle from the login, not for ever: an agent who has
/// been free since an early call goes before one who has just logged in,
/// and an agent back from a break is idle from the end of the break.
pub fn a_login_or_a_break_is_not_idle_test() {
  let c = three_agent_queue("longest_idle")
  cluster.agent_since(c, "ann", "available", 200)
  cluster.agent_last_call(c, "bob", cluster.start_of_time + 100)
  cluster.agent_since(c, "cal", "available", 150)
  cluster.agent_last_call(c, "cal", cluster.start_of_time + 50)
  cluster.at(c, 300)
  cluster.arrive(c, "call-one", "support", 0, 300)
  assert cluster.ringing(c, "call-one") == ["bob"]
  cluster.arrive(c, "call-two", "support", 0, 300)
  assert cluster.ringing(c, "call-two") == ["cal"]
  cluster.arrive(c, "call-three", "support", 0, 300)
  assert cluster.ringing(c, "call-three") == ["ann"]
}

/// The call that ended a moment ago counts before the agent's document says
/// so: the counters are written by another process and read back through a
/// cache, and here they are never written at all. ann's call ends and her
/// wrap-up with it; bob, idle since before it, is next.
pub fn a_call_just_ended_counts_before_the_document_test() {
  let c = two_agent_queue()
  cluster.agent_last_call(c, "bob", cluster.start_of_time + 5)
  cluster.at(c, 10)
  cluster.arrive(c, "call-one", "support", 0, 10)
  // Neither has been rung and ann's document has no last call, so she has
  // been free since her login at 0, which is before bob's call ended.
  assert cluster.ringing(c, "call-one") == ["ann"]
  answered_and_done(c, "call-one", "ann", 10)

  quiet_at(c, 40)
  cluster.arrive(c, "call-two", "support", 0, 40)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// The same for the counts: the answered call and its seconds are counted
/// here as they happen, so `fewest_calls` and `least_talk_time` do not send
/// the next caller to the agent who has just finished one because the
/// document has not caught up.
pub fn a_call_just_ended_is_counted_at_once_test() {
  list.each(["fewest_calls", "least_talk_time"], fn(strategy) {
    let c =
      cluster.new(
        [#("support", queue(strategy, [#("ann", 1, 1), #("bob", 1, 2)]))],
        [#("ann", user([])), #("bob", user([]))],
      )
    cluster.agent_is(c, "ann", "available")
    cluster.agent_is(c, "bob", "available")
    cluster.arrive(c, "call-one", "support", 0, 0)
    assert cluster.ringing(c, "call-one") == ["ann"]
    cluster.reply(
      c,
      "call-one",
      Answered("ann", "call-one-agent", cluster.start_of_time),
    )
    cluster.at(c, 60)
    cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))

    quiet_at(c, 90)
    cluster.arrive(c, "call-two", "support", 0, 90)
    assert cluster.ringing(c, "call-two") == ["bob"]
  })
}

// --- The strategy the queue names ------------------------------------------

fn round_robin_queue() -> cluster.Cluster {
  let c =
    cluster.new(
      [#("support", queue("round_robin", [#("ann", 1, 1), #("bob", 1, 2)]))],
      [#("ann", user([])), #("bob", user([]))],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  c
}

/// An agent takes the caller and the call ends five seconds later.
fn answered_and_done(
  c: cluster.Cluster,
  call_id: String,
  agent_id: String,
  at: Int,
) -> Nil {
  cluster.reply(
    c,
    call_id,
    Answered(agent_id, call_id <> "-agent", cluster.start_of_time + at),
  )
  cluster.reply(c, call_id, Ended(Completed, cluster.start_of_time + at + 5))
}

/// Past every wrap-up and delay, with nobody waiting.
fn quiet_at(c: cluster.Cluster, seconds: Int) -> Nil {
  cluster.at(c, seconds)
  cluster.tick(c)
}

/// The memo, end to end: the dispatcher hands the strategy back the state it
/// last answered with, so a round-robin queue alternates instead of starting
/// at the top of the tier for every caller. Nothing else in the dispatcher
/// writes `state.memo`, so this is the test that the plumbing exists at all.
pub fn round_robin_alternates_test() {
  let c = round_robin_queue()

  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  answered_and_done(c, "call-one", "ann", 0)

  quiet_at(c, 30)
  cluster.arrive(c, "call-two", "support", 0, 30)
  assert cluster.ringing(c, "call-two") == ["bob"]
  answered_and_done(c, "call-two", "bob", 30)

  quiet_at(c, 60)
  cluster.arrive(c, "call-three", "support", 0, 60)
  assert cluster.ringing(c, "call-three") == ["ann"]
}

/// A miss is a turn like any other. bob is logged out while ann's phone rings
/// out, so her miss is the only thing that could have moved the cursor: a
/// dispatcher that told the strategy only about answers would start the next
/// caller at ann again.
pub fn a_miss_advances_the_round_robin_cursor_test() {
  let c = round_robin_queue()
  cluster.agent_is(c, "bob", "logged_out")

  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.all_ringing(c) == []
  assert cluster.cancel(c, "call-one", Hangup)

  cluster.agent_logs_in(c, "bob")
  quiet_at(c, 30)
  cluster.arrive(c, "call-two", "support", 0, 30)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// A queue whose strategy is changed starts the new one clean. The memo is
/// one slot per queue and the strategy that wrote it is stamped on it, so a
/// cursor from a shift under another strategy is not read as this one's.
pub fn a_changed_strategy_starts_with_an_empty_memo_test() {
  let agents = [#("ann", 1, 1), #("bob", 1, 2)]
  let c = round_robin_queue()

  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  answered_and_done(c, "call-one", "ann", 0)

  // Ring-all keeps no cursor of its own, so the value in the queue's one
  // memo slot is still round robin's -- what changes is the name stamped on
  // it, which is what makes it unreadable afterwards.
  cluster.put_queue(c, "support", queue("ring_all", agents))
  quiet_at(c, 30)
  cluster.arrive(c, "call-two", "support", 0, 30)
  assert cluster.ringing(c, "call-two") == ["ann", "bob"]
  answered_and_done(c, "call-two", "ann", 30)

  // Back to round robin: the top of the tier, not the agent after the one
  // the old memo still names.
  cluster.put_queue(c, "support", queue("round_robin", agents))
  quiet_at(c, 60)
  cluster.arrive(c, "call-three", "support", 0, 60)
  assert cluster.ringing(c, "call-three") == ["ann"]
}

fn queue_ringing(simultaneously: Int) -> cluster.Cluster {
  let document =
    doc.set(
      queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)]),
      ["ring_simultaneously"],
      doc.Int(simultaneously),
    )
  let c =
    cluster.new([#("support", document)], [
      #("ann", user([])),
      #("bob", user([])),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  c
}

/// `ring_simultaneously` takes the first few of a sequential list and rings
/// them on one offer, so that the losers are cancelled by the platform rather
/// than raced. The answer frees the rest at once.
pub fn ring_simultaneously_rings_the_first_few_test() {
  let c = queue_ringing(2)
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.ringing(c, "call-one") == ["ann", "bob"]
  assert fake_offer.count(c.offers) == 1

  cluster.reply(
    c,
    "call-one",
    Answered("bob", "agent-leg", cluster.start_of_time),
  )
  assert cluster.all_ringing(c) == ["bob"]
}

/// More than the strategy offered is everybody the strategy offered.
pub fn ring_simultaneously_past_the_end_of_the_list_test() {
  let c = queue_ringing(5)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]
}

/// The default is one, which is what sequential has always meant here, and a
/// document that says nobody rings one all the same.
pub fn ring_simultaneously_defaults_to_one_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  let none = queue_ringing(0)
  cluster.arrive(none, "call-two", "support", 0, 0)
  assert cluster.ringing(none, "call-two") == ["ann"]
}

/// A ring of several is a miss for each of them: every phone that rang out
/// takes its delay, so the next pass finds nobody until the delays pass.
pub fn ring_simultaneously_misses_are_per_agent_test() {
  let document =
    doc.set(
      queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)]),
      ["ring_simultaneously"],
      doc.Int(2),
    )
  let delayed = user([#("no_answer_delay", doc.Int(30))])
  let c =
    cluster.new([#("support", document)], [
      #("ann", delayed),
      #("bob", delayed),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]

  cluster.reply(c, "call-one", OfferNoAnswer(["ann", "bob"]))
  assert cluster.ringing(c, "call-one") == []
  assert cluster.waiting(c) == ["call-one"]

  cluster.at(c, 31)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]
}

/// Ann and Bob, each one miss from being stood down, in a queue that rings
/// them together: `ring_all`, or a sequential strategy two at a time.
fn rung_together(strategy: String, simultaneously: Int) -> cluster.Cluster {
  let document =
    queue(strategy, [#("ann", 1, 1), #("bob", 1, 2)])
    |> doc.set(["ring_simultaneously"], doc.Int(simultaneously))
    |> doc.set(["agent_no_answer_status"], doc.String("logged_out"))
  let strict = user([#("max_no_answer", doc.Int(1))])
  let c =
    cluster.new([#("support", document)], [#("ann", strict), #("bob", strict)])
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  c
}

/// An unanswered ring of everybody is a miss for every agent it rang, not
/// one miss shared between them: each phone rang out on somebody who was
/// there to take the caller. With `max_no_answer` at one, both are stood
/// down by the one ring.
pub fn an_unanswered_ring_all_is_a_miss_for_everybody_rung_test() {
  let c = rung_together("ring_all", 1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]

  cluster.reply(c, "call-one", OfferNoAnswer(["ann", "bob"]))
  assert cluster.availability_becomes(c, "ann", "logged_out") == "logged_out"
  assert cluster.availability_becomes(c, "bob", "logged_out") == "logged_out"
}

/// The same for `ring_simultaneously` above one: every agent of the ring.
pub fn an_unanswered_ring_of_several_is_a_miss_for_each_test() {
  let c = rung_together("longest_idle", 2)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]

  cluster.reply(c, "call-one", OfferNoAnswer(["ann", "bob"]))
  assert cluster.availability_becomes(c, "ann", "logged_out") == "logged_out"
  assert cluster.availability_becomes(c, "bob", "logged_out") == "logged_out"
}

/// The losers of a ring of several have had their turn too. With four
/// agents rung two at a time, the caller after ann's answer goes to the two
/// who have not rung yet; a cursor left on the answerer would ring bob, who
/// has just lost the race, first.
pub fn the_losers_of_a_ring_advance_the_round_robin_cursor_test() {
  let agents = [#("ann", 1, 1), #("bob", 1, 2), #("cal", 1, 3), #("dee", 1, 4)]
  let document =
    doc.set(queue("round_robin", agents), ["ring_simultaneously"], doc.Int(2))
  let c =
    cluster.new([#("support", document)], [
      #("ann", user([])),
      #("bob", user([])),
      #("cal", user([])),
      #("dee", user([])),
    ])
  list.each(["ann", "bob", "cal", "dee"], fn(agent_id) {
    cluster.agent_is(c, agent_id, "available")
  })

  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann", "bob"]
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )

  cluster.arrive(c, "call-two", "support", 0, 1)
  assert cluster.ringing(c, "call-two") == ["cal", "dee"]
}

/// An offer that could not even ring has used the agent's turn: the caller
/// is offered again at once, and a cursor that had not moved would put them
/// on the same broken endpoint for as long as it stays broken.
pub fn a_failed_offer_advances_the_round_robin_cursor_test() {
  let c = round_robin_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.reply(c, "call-one", Failed("no channel"))
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// Two offers out at once end in whichever order the phones answer. The
/// cursor was moved as each was sent, so bob's caller ending before ann has
/// answered, and ann's answer arriving last, leave it on bob: the next
/// caller is cal's, who has not rung yet.
pub fn results_out_of_order_do_not_rewind_the_round_robin_cursor_test() {
  let agents = [#("ann", 1, 1), #("bob", 1, 2), #("cal", 1, 3)]
  let c =
    cluster.new([#("support", queue("round_robin", agents))], [
      #("ann", user([])),
      #("bob", user([])),
      #("cal", user([])),
    ])
  list.each(["ann", "bob", "cal"], fn(agent_id) {
    cluster.agent_is(c, agent_id, "available")
  })
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.arrive(c, "call-two", "support", 0, 1)
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert cluster.ringing(c, "call-two") == ["bob"]

  answered_and_done(c, "call-two", "bob", 2)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "call-one-agent", cluster.start_of_time + 8),
  )

  // Past bob's wrap-up, so that it is the cursor and not his wrap-up that
  // keeps the third caller off him.
  quiet_at(c, 20)
  cluster.arrive(c, "call-three", "support", 0, 20)
  assert cluster.ringing(c, "call-three") == ["cal"]
}

/// A caller who hangs up while the phone is ringing has still used the
/// agent's turn: nobody will ever know how that offer would have gone, and
/// starting the next caller at the same agent is how one agent takes every
/// caller of a queue whose callers give up.
pub fn an_abandoned_offer_advances_the_round_robin_cursor_test() {
  let c = round_robin_queue()

  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert cluster.cancel(c, "call-one", Hangup)

  cluster.arrive(c, "call-two", "support", 0, 10)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

// --- Leaving ---------------------------------------------------------------

pub fn a_cancel_settles_the_caller_once_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.cancel(c, "call-one", ExitKey)
  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == []

  // A cancel for somebody who has already gone is not a second settlement.
  assert !cluster.cancel(c, "call-one", Timeout)
  assert cluster.settled(c) == ["call-one"]
}

/// A caller whose channel is gone leaves at once. acdc's ghost call, which
/// requirement 0.6 says must not be possible here.
pub fn a_dead_channel_leaves_the_queue_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.channel_gone(c, "call-one")

  assert cluster.waiting(c) == []
  assert cluster.settled(c) == ["call-one"]
  assert cluster.all_ringing(c) == []
}

/// The activity actor tells the dispatcher of every queue channel of the
/// account that goes -- agents' legs, callers already through -- and only a
/// caller waiting here is anything to it. The rest cost no pass: with
/// nobody waiting there is no tick either, so the one read of the activity
/// is the report that waits for the message to be handled.
pub fn a_channel_that_is_not_a_waiting_caller_is_nothing_test() {
  let c = two_agent_queue()
  let before = fake_activity.reads(c.activity)
  cluster.channel_gone(c, "an-agents-leg")
  assert fake_activity.reads(c.activity) - before == 1
  assert cluster.settled(c) == []
}

// --- Every caller is settled exactly once ----------------------------------

/// Arrivals, replies and cancels interleaved: whatever the order, no agent is
/// ever in two offers and no caller is ever settled twice.
pub fn interleavings_settle_every_caller_once_test() {
  list.each(orderings(), fn(steps) {
    let c =
      cluster.new(
        [#("support", queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)]))],
        [#("ann", user([])), #("bob", user([]))],
      )
    cluster.agent_is(c, "ann", "available")
    cluster.agent_is(c, "bob", "available")

    list.each(steps, fn(step) { run(c, step) })

    // One offer per agent at most, always.
    let ringing = cluster.all_ringing(c)
    assert list.length(list.unique(ringing)) == list.length(ringing)

    // Every caller settled at most once, and nobody is both waiting and
    // settled.
    let settled = cluster.settled(c)
    assert list.length(list.unique(settled)) == list.length(settled)
    list.each(cluster.waiting(c), fn(call_id) {
      assert !list.contains(settled, call_id)
    })
  })
}

type Step {
  Arrive(String, Int)
  Answer(String)
  Miss(String)
  Leave(String)
  Time(Int)
}

fn run(c: cluster.Cluster, step: Step) -> Nil {
  case step {
    Arrive(call_id, at) -> {
      cluster.at(c, at)
      cluster.arrive(c, call_id, "support", 0, at)
    }
    Answer(call_id) ->
      case cluster.ringing(c, call_id) {
        [agent_id, ..] ->
          cluster.reply(
            c,
            call_id,
            Answered(agent_id, call_id <> "-agent", cluster.start_of_time),
          )
        [] -> Nil
      }
    Miss(call_id) ->
      case cluster.ringing(c, call_id) {
        [] -> Nil
        agents -> cluster.reply(c, call_id, OfferNoAnswer(agents))
      }
    Leave(call_id) -> {
      let _ = cluster.cancel(c, call_id, Hangup)
      Nil
    }
    Time(at) -> {
      cluster.at(c, at)
      cluster.tick(c)
    }
  }
}

/// A handful of orders that between them cover every transition, written out
/// rather than generated so that a failure names the one that broke.
fn orderings() -> List(List(Step)) {
  [
    [Arrive("a", 0), Answer("a"), Arrive("b", 5), Answer("b")],
    [Arrive("a", 0), Arrive("b", 1), Miss("a"), Answer("a"), Leave("b")],
    [Arrive("a", 0), Arrive("b", 1), Leave("a"), Answer("b")],
    [Arrive("a", 0), Miss("a"), Miss("a"), Time(30), Leave("a")],
    [
      Arrive("a", 0),
      Arrive("b", 1),
      Arrive("c", 2),
      Answer("a"),
      Answer("b"),
      Leave("c"),
    ],
    [Arrive("a", 0), Answer("a"), Leave("a"), Miss("a")],
    [Arrive("a", 0), Time(30), Time(60), Answer("a")],
    [
      Arrive("a", 0),
      Arrive("b", 0),
      Miss("a"),
      Miss("b"),
      Time(90),
      Answer("a"),
    ],
  ]
}

// --- The position announcement ---------------------------------------------

/// A caller is told where they stand when they move, and again on the
/// interval when they have not, so that silence never means the queue has
/// forgotten them.
pub fn a_position_is_announced_on_change_test() {
  // A caller who has just arrived has never been told.
  assert dispatcher.announcement_due(
    position: 1,
    announced: 0,
    now: 100,
    announced_at: 0,
    interval_s: 30,
  )

  // Moved from third to second.
  assert dispatcher.announcement_due(
    position: 2,
    announced: 3,
    now: 100,
    announced_at: 99,
    interval_s: 30,
  )

  // Not moved, and told a second ago.
  assert !dispatcher.announcement_due(
    position: 2,
    announced: 2,
    now: 100,
    announced_at: 99,
    interval_s: 30,
  )
}

pub fn a_position_is_announced_on_the_interval_test() {
  // Not moved, told twenty-nine seconds ago: not yet.
  assert !dispatcher.announcement_due(
    position: 2,
    announced: 2,
    now: 129,
    announced_at: 100,
    interval_s: 30,
  )
  // Thirty seconds ago: now.
  assert dispatcher.announcement_due(
    position: 2,
    announced: 2,
    now: 130,
    announced_at: 100,
    interval_s: 30,
  )
}

/// A configured interval of zero would announce every second the dispatcher
/// ticks, which is a caller being shouted at.
pub fn the_announcement_interval_has_a_floor_test() {
  assert !dispatcher.announcement_due(
    position: 1,
    announced: 1,
    now: 100,
    announced_at: 100,
    interval_s: 0,
  )
  assert dispatcher.announcement_due(
    position: 1,
    announced: 1,
    now: 101,
    announced_at: 100,
    interval_s: 0,
  )
}

// --- The queue document ----------------------------------------------------

pub fn settings_take_the_schema_defaults_test() {
  let settings = dispatcher.settings("support", doc.object([]), 30, "on_break")
  assert settings.id == "support"
  assert settings.name == "support"
  assert settings.strategy.name == "longest_idle"
  assert settings.ring_timeout_s == 15
  assert settings.wrapup_s == 0
  assert settings.skip_external_calls
  assert settings.time_base_system
  assert settings.announce_interval_s == 30
  assert settings.cid_prefix == None
  assert settings.hold_media == None
  assert settings.tiers == []
}

pub fn settings_read_the_document_test() {
  let document =
    doc.object([
      #("name", doc.String("Support")),
      #("strategy", doc.String("ring_all")),
      #("agent_ring_timeout", doc.Int(25)),
      #("agent_wrapup_time", doc.Int(15)),
      #("cid_prefix", doc.String("Support: ")),
      #("record", doc.Bool(True)),
      #("skip_agents_with_external_calls", doc.Bool(False)),
      #("time_base_score", doc.String("queue")),
      #("announce", doc.object([#("interval", doc.Int(45))])),
      #("agent_no_answer_status", doc.String("logged_out")),
      #("moh", doc.String("support-hold")),
      #(
        "outbound_caller_id",
        doc.object([
          #("name", doc.String("Support")),
          #("number", doc.String("5550100")),
        ]),
      ),
    ])
  let settings = dispatcher.settings("support", document, 30, "on_break")
  assert settings.name == "Support"
  assert settings.strategy.name == "ring_all"
  assert settings.ring_timeout_s == 25
  assert settings.wrapup_s == 15
  assert settings.cid_prefix == Some("Support: ")
  assert settings.record
  assert !settings.skip_external_calls
  assert !settings.time_base_system
  assert settings.announce_interval_s == 45
  assert settings.agent_no_answer_status == types.LoggedOut
  assert settings.outbound_caller_id_number == Some("5550100")
  assert settings.hold_media == Some("support-hold")
}

pub fn agent_settings_take_the_schema_defaults_test() {
  let settings = dispatcher.agent_settings_of(doc.object([]))
  assert settings == dispatcher.no_agent_settings()
}

pub fn agent_settings_read_the_user_test() {
  let settings =
    dispatcher.agent_settings_of(
      user([
        #("ring_timeout", doc.Int(12)),
        #("wrapup_time", doc.Int(20)),
        #("max_no_answer", doc.Int(3)),
        #("reject_delay", doc.Int(5)),
        #("busy_delay", doc.Int(7)),
        #("no_answer_delay", doc.Int(9)),
        #("record", doc.Bool(True)),
      ]),
    )
  assert settings.ring_timeout_s == Some(12)
  assert settings.wrapup_s == Some(20)
  assert settings.max_no_answer == 3
  assert settings.reject_delay_s == 5
  assert settings.busy_delay_s == 7
  assert settings.no_answer_delay_s == 9
  assert settings.record
}

// --- The time base ---------------------------------------------------------

/// `system` counts from when the caller entered the system, so a caller
/// re-entering a queue keeps their place; `queue` counts from this queue.
pub fn the_time_base_decides_the_age_test() {
  let member = cluster.member("call-one", "support", 0, 1000)
  assert dispatcher.score_base(member, False) == 1000
  // A channel the action never stamped counts from when they joined.
  assert dispatcher.score_base(member, True) == 1000

  let earlier = cluster.with_call_var(member, "Queue-System-Joined", 400)
  assert dispatcher.score_base(earlier, True) == 400
  assert dispatcher.score_base(earlier, False) == 1000
}

/// The order a queue's callers are in, as its status lists them.
fn waiting_in(c: cluster.Cluster, queue_id: String) -> List(String) {
  let assert [queue] = cluster.status(c, Some(queue_id))
  let assert Ok(callers) = doc.get_list(queue, ["Waiting"])
  list.filter_map(callers, fn(caller) { doc.get_string(caller, ["Call-ID"]) })
}

/// A caller moved here from another queue -- the overflow, a transfer --
/// carries the stamp of the first queue they entered, and on the default
/// `system` time base waits ahead of a caller who entered after them.
pub fn a_caller_from_another_queue_keeps_their_age_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "local", "support", 0, 50)
  cluster.arrive_as(
    c,
    cluster.member("moved", "support", 0, cluster.start_of_time + 100)
      |> cluster.with_call_var("Queue-System-Joined", cluster.start_of_time),
  )

  assert waiting_in(c, "support") == ["moved", "local"]
}

/// The same caller entering the same queue again -- their callflow run
/// again after its node died -- keeps the older of the two joins, and with
/// it their place, on either time base.
pub fn a_reentry_keeps_the_older_join_test() {
  let c = two_agent_queue()
  cluster.put_queue(
    c,
    "support",
    doc.set(
      queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)]),
      ["time_base_score"],
      doc.String("queue"),
    ),
  )
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "first", "support", 0, 0)
  cluster.arrive(c, "second", "support", 0, 10)
  cluster.arrive(c, "first", "support", 0, 20)

  assert waiting_in(c, "support") == ["first", "second"]
}

// --- Redelivery ------------------------------------------------------------

/// A member redelivered after a failover is the same caller, not a new one:
/// they keep their place and are not counted twice.
pub fn a_redelivery_is_not_a_new_caller_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.waiting(c) == ["call-one"]
  let assert [support] = cluster.status(c, Some("support"))
  assert doc.get_list(support, ["Waiting"]) |> result.map(list.length) == Ok(1)
}

// --- Taking a caller over --------------------------------------------------

/// A caller the broker has handed out before joins their actor resumed, and
/// nobody is rung for them until the actor says where they stand: phones
/// may be ringing for them already, on a switch that outlived the node
/// which rang them. Past `present_wait_s` without a word they are rung like
/// anybody else.
pub fn a_redelivered_caller_waits_for_their_actors_word_test() {
  let c = two_agent_queue()
  fake_calls.will_say_nothing(c.calls, "call-one")
  cluster.redelivered(c, "call-one", "support", 0, 0)

  assert cluster.joined(c) == [#("call-one", True)]
  assert fake_offer.count(c.offers) == 0
  assert cluster.waiting(c) == ["call-one"]

  cluster.at(c, arrival.present_wait_s - 1)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 0
  cluster.at(c, arrival.present_wait_s)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 1
}

/// Found waiting: rung at once.
pub fn a_caller_found_waiting_is_rung_test() {
  let c = two_agent_queue()
  cluster.redelivered(c, "call-one", "support", 0, 0)

  assert fake_offer.count(c.offers) == 1
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// A first delivery is a caller nobody has done anything about yet: their
/// actor greets them and they are rung at once, nothing asked.
pub fn a_first_delivery_is_not_found_out_about_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.joined(c) == [#("call-one", False)]
  assert fake_calls.presented(c.calls) == []
  assert fake_offer.count(c.offers) == 1
}

/// Found with a phone ringing: its agent is held under the actor's offer,
/// nobody is rung over it, and nobody else is offered the agent.
pub fn a_ring_found_holds_its_agent_test() {
  let c = two_agent_queue()
  cluster.presents(
    c,
    "call-one",
    types.PresentRinging(["ann"], cluster.start_of_time + 25, False),
  )
  cluster.redelivered(c, "call-one", "support", 0, 0)

  assert fake_offer.count(c.offers) == 0
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert cluster.waiting(c) == ["call-one"]

  cluster.arrive(c, "call-two", "support", 0, 1)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// The ring found goes on to end as any ring does, told by the actor under
/// its offer: a no-answer is the agent's miss, and the caller is offered
/// again.
pub fn a_ring_found_ends_as_any_ring_test() {
  let c = two_agent_queue()
  cluster.presents(
    c,
    "call-one",
    types.PresentRinging(["ann"], cluster.start_of_time + 25, False),
  )
  cluster.redelivered(c, "call-one", "support", 0, 0)
  cluster.present_reply(c, "call-one", OfferNoAnswer(["ann"]))

  assert fake_offer.count(c.offers) == 1
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// The caller hangs up while that phone is ringing: out of the queue, and
/// the agent let go.
pub fn a_caller_found_ringing_who_hangs_up_test() {
  let c = two_agent_queue()
  cluster.presents(
    c,
    "call-one",
    types.PresentRinging(["ann"], cluster.start_of_time + 25, False),
  )
  cluster.redelivered(c, "call-one", "support", 0, 0)
  assert cluster.cancel(c, "call-one", Hangup)

  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert cluster.all_ringing(c) == []
}

/// Found talking to an agent, whose member stays on the broker until the
/// call ends: nobody rings over them, the agent is held, and the end the
/// actor tells settles them.
pub fn a_caller_found_talking_test() {
  let c = two_agent_queue()
  cluster.presents(
    c,
    "call-one",
    types.PresentConnected("ann", "agent-leg", cluster.start_of_time + 3, False),
  )
  cluster.redelivered(c, "call-one", "support", 0, 0)

  assert fake_offer.count(c.offers) == 0
  assert cluster.settled(c) == []
  assert cluster.waiting(c) == []
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.present_reply(
    c,
    "call-one",
    Ended(Completed, cluster.start_of_time + 9),
  )
  assert cluster.settled(c) == ["call-one"]
}

/// Found after the queue was done with them -- their passage closed, or on
/// their way out -- they are settled and not rung.
pub fn a_caller_found_over_is_settled_test() {
  let c = two_agent_queue()
  cluster.presents(c, "call-one", types.PresentOver)
  cluster.redelivered(c, "call-one", "support", 0, 0)

  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert fake_offer.count(c.offers) == 0
}

/// A word about a caller the dispatcher already knows the state of -- the
/// same member delivered again while its offer is out -- changes nothing.
pub fn a_word_about_a_caller_already_known_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.presents(
    c,
    "call-one",
    types.PresentRinging(["bob"], cluster.start_of_time + 25, False),
  )
  cluster.redelivered(c, "call-one", "support", 0, 0)

  assert cluster.ringing(c, "call-one") == ["ann"]
  assert fake_offer.count(c.offers) == 1
}

// --- Calls the sweep found open --------------------------------------------

/// A call answered on a node that died settled its own member message, so
/// nothing brings it to another node but the sweep reading its record. The
/// caller's channel is gone, so it is closed here: the wrap-up starts, and
/// nothing rings the agent while it lasts.
pub fn an_orphaned_call_whose_caller_has_gone_test() {
  let c = two_agent_queue()
  cluster.orphaned(
    c,
    "call-one",
    "support",
    "ann",
    3,
    Some(cluster.start_of_time + 90),
  )

  // Nothing is waiting and nothing is ringing: the call is over.
  assert cluster.waiting(c) == []
  assert cluster.all_ringing(c) == []
  assert cluster.watching(c, "call-one") == []

  // `ann` is wrapping up, so the next caller goes to `bob`.
  cluster.at(c, 91)
  cluster.arrive(c, "call-two", "support", 0, 91)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

/// One whose caller is still talking is adopted instead: the agent is held,
/// and a watcher says when it ends.
pub fn an_orphaned_call_still_going_on_test() {
  let c = two_agent_queue()
  cluster.orphaned(c, "call-one", "support", "ann", 3, None)

  assert cluster.watching(c, "call-one") == ["ann"]
  assert cluster.ringing(c, "call-one") == ["ann"]
  // The member message was settled by the node that answered it; there is
  // nothing here to settle.
  assert cluster.settled(c) == []

  cluster.watch_reply(
    c,
    "call-one",
    Ended(Completed, cluster.start_of_time + 90),
  )
  assert cluster.all_ringing(c) == []
}

/// A sweep that comes round again while the call is still going on changes
/// nothing: it is adopted already, and its watcher owns the end.
pub fn an_orphaned_call_is_adopted_once_test() {
  let c = two_agent_queue()
  cluster.orphaned(c, "call-one", "support", "ann", 3, None)
  cluster.orphaned(c, "call-one", "support", "ann", 3, None)

  assert list.length(fake_calls.adoptions(c.calls)) == 1
}

// --- The end of an account -------------------------------------------------

/// A dispatcher with nothing waiting, nothing ringing and nobody wrapping up
/// stays: it used to stop itself, and its going was what a caller's cancel
/// could race. It costs a process, which is nothing, and answers the next
/// caller at once.
pub fn a_quiet_account_keeps_its_dispatcher_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.cancel(c, "call-one", Hangup)
  assert cluster.alive(c)

  cluster.at(c, 1)
  cluster.tick(c)
  cluster.at(c, 60)
  cluster.tick(c)
  assert cluster.alive(c)

  cluster.arrive(c, "call-two", "support", 0, 60)
  assert cluster.waiting(c) == ["call-two"]
}

/// A caller still in wrap-up keeps the dispatcher, because the wrap-up is a
/// timer this process owns and nothing else would fire it.
pub fn a_wrapping_up_agent_keeps_the_dispatcher_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  cluster.reply(c, "call-one", Ended(CallerHangup, cluster.start_of_time + 30))

  cluster.at(c, 31)
  cluster.tick(c)
  assert cluster.alive(c)
}

// --- Releasing an agent by hand --------------------------------------------

fn release(c: cluster.Cluster, agent_id: String) -> Bool {
  let known =
    process.call(c.dispatcher, 5000, dispatcher.ReleaseAgent(agent_id, _))
  cluster.sync(c)
  known
}

/// An agent released while their phone rings has the ring called off, on the
/// caller's channel, and stays in the offer until it says the ring is over.
/// Freed at once, their phone rang on, and an answer was dropped as stale
/// while the caller, talking to them, was offered to somebody else.
pub fn releasing_a_ringing_agent_calls_off_the_ring_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))

  assert release(c, "ann")
  assert cluster.called_off(c) == ["call-one"]
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert fake_offer.count(c.offers) == 1

  // The switch cancelled the bridge. Nobody missed anybody and nobody is
  // left alone for a moment: Ann is offered the caller again at once.
  cluster.reply(c, "call-one", Failed("originator_cancel"))
  assert cluster.waiting(c) == ["call-one"]
  assert fake_offer.count(c.offers) == 2
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// An answer the caller's actor handled before the call-off stands: it
/// bridged the caller to the agent, and the call-off found nothing ringing.
/// The caller is connected, out of the queue, and settled when the call
/// ends. One the call-off came before ends the ring with nobody's answer,
/// no miss, and the caller is offered again.
pub fn an_answer_before_the_call_off_stands_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert release(c, "ann")

  cluster.reply(
    c,
    "call-one",
    Answered("ann", "ann-leg", cluster.start_of_time + 1),
  )
  assert cluster.waiting(c) == []
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 40))
  assert cluster.settled(c) == ["call-one"]

  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert release(c, "ann")
  cluster.reply(c, "call-one", Failed("called_off"))
  assert cluster.settled(c) == []
  assert cluster.waiting(c) == ["call-one"]
  assert fake_offer.count(c.offers) == 2
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// A ring released before the actor said it was out is called off at once:
/// the actor handles the ring first, since the two were sent in that order,
/// and nothing more is sent when it says the ring is out.
pub fn a_ring_released_before_it_went_out_is_called_off_at_once_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert release(c, "ann")
  assert cluster.called_off(c) == ["call-one"]

  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert cluster.called_off(c) == ["call-one"]
}

/// A ring is called off once however often the agent is released. The
/// second unbridge lands on a channel whose bridge has already ended, and
/// there it parks the caller who is still waiting and stops their hold
/// music.
pub fn releasing_an_agent_twice_calls_the_ring_off_once_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))

  assert release(c, "ann")
  assert release(c, "ann")
  assert cluster.called_off(c) == ["call-one"]

  // The same before the ring is out: once, when it goes out.
  cluster.reply(c, "call-one", Failed("originator_cancel"))
  assert fake_offer.count(c.offers) == 2
  assert release(c, "ann")
  assert release(c, "ann")
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert cluster.called_off(c) == ["call-one", "call-one"]
}

/// An agent released after their caller's queue was deleted: the deletion
/// let the caller and the agent go, and nothing more is sent.
pub fn releasing_after_a_queue_delete_calls_nothing_off_again_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  assert cluster.called_off(c) == ["call-one"]

  assert !release(c, "ann")
  assert cluster.called_off(c) == ["call-one"]

  // And the other way round.
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert release(c, "ann")
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  assert cluster.called_off(c) == ["call-one"]
}

/// A caller's actor that crashed while its offer rang left the legs to
/// their own ring timeout and `park_timeout`: there is nothing left to call
/// off, and the offer fails, nobody's miss, and the caller is offered again.
pub fn a_crashed_actors_offer_fails_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  fake_offer.died(c.offers)
  cluster.sync(c)
  assert cluster.called_off(c) == []

  // Offered again, to Bob, whose ring goes out before its actor goes.
  assert cluster.ringing(c, "call-one") == ["bob"]
  cluster.reply(c, "call-one", OfferRinging(["bob"]))
  fake_offer.died(c.offers)
  cluster.sync(c)
  assert cluster.called_off(c) == []
}

/// Every call-off goes to the caller's actor, which is the one process that
/// can hang its legs up: a release, one before the ring was out, and a
/// caller leaving for a reason the actor did not decide itself. A caller
/// whose channel went has no ring left to call off.
pub fn a_call_off_goes_to_the_callers_actor_test() {
  // Released while ringing.
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert release(c, "ann")
  assert cluster.called_off(c) == ["call-one"]

  // Released before the ring was out: the actor calls it off as it goes
  // out, and nothing more is sent when it does.
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert release(c, "ann")
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert cluster.called_off(c) == ["call-one"]

  // The caller taken out while it rings.
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  let _held = cluster.cancel(c, "call-one", ExitKey)
  assert cluster.called_off(c) == ["call-one"]

  // The caller hanging up while it rings.
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  let _held = cluster.cancel(c, "call-one", Hangup)
  assert cluster.called_off(c) == []
}

// --- A call adopted from a node that died ----------------------------------

/// A call answered on a node that died is adopted by the caller's actor,
/// which watches it to its end, and its agent is held on it meanwhile.
pub fn an_adopted_call_is_watched_by_the_callers_actor_test() {
  let c = two_agent_queue()
  cluster.orphaned(c, "talking", "support", "ann", 0, None)
  assert cluster.watching(c, "talking") == ["ann"]
  assert cluster.ringing(c, "talking") == ["ann"]
}

/// A call nothing can watch is a call nothing will say the end of, and its
/// agent was held busy until the sweep's backstop, ten minutes on. It is
/// closed at once instead, as its record says it was answered: the agent
/// has their wrap-up and is free after it.
pub fn an_adopted_call_nothing_can_watch_is_closed_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  fake_calls.failing(c.calls, "no actors")
  cluster.orphaned(c, "talking", "support", "ann", 0, None)
  assert cluster.report(c).offers == []

  cluster.at(c, 11)
  cluster.tick(c)
  cluster.arrive(c, "next", "support", 0, 11)
  assert cluster.ringing(c, "next") == ["ann"]
}

/// The watch of an adopted call ending without a word is the end of a call
/// nobody is watching any more: closed, and the agent let go after their
/// wrap-up, rather than held until the sweep comes round.
pub fn an_adopted_call_whose_watch_died_is_closed_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.orphaned(c, "talking", "support", "ann", 0, None)
  assert cluster.ringing(c, "talking") == ["ann"]

  fake_calls.died(c.calls)
  cluster.sync(c)
  assert cluster.report(c).offers == []
  cluster.at(c, 11)
  cluster.tick(c)
  cluster.arrive(c, "next", "support", 0, 11)
  assert cluster.ringing(c, "next") == ["ann"]
}

// --- Misses since login ----------------------------------------------------
//
// `max_no_answer` counts the misses of one login, not of an agent. Two
// decisions live here: a miss belongs to the login it happened in and a
// login starts the count again, and an offer that rang out after the agent
// stepped away is not their miss at all. The counter, the record written and
// this rule all follow the one decision, so standing an agent down is what
// these tests read it through.

/// One agent who is stood down after `max_no_answer` misses, into a status
/// that is different from every status the tests put her in, so that "was
/// she stood down" is a question the document answers.
fn strict_queue(max_no_answer: Int) -> cluster.Cluster {
  let c =
    cluster.new(
      [
        #(
          "support",
          doc.set(
            queue("longest_idle", [#("ann", 1, 1)]),
            ["agent_no_answer_status"],
            doc.String("logged_out"),
          ),
        ),
      ],
      [#("ann", user([#("max_no_answer", doc.Int(max_no_answer))]))],
    )
  cluster.agent_is(c, "ann", "available")
  c
}

/// Offer the waiting caller to the agent again. The miss before it delayed
/// her, and the delay is a timer.
fn offer_again(c: cluster.Cluster, call_id: String) -> Nil {
  cluster.tick(c)
  assert cluster.ringing(c, call_id) == ["ann"]
}

/// The rule as it stands: an agent who was there and did not answer is
/// counted, and the count reaching `max_no_answer` moves her to the queue's
/// no-answer status.
pub fn a_miss_while_available_counts_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))

  assert cluster.availability_becomes(c, "ann", "logged_out") == "logged_out"
}

/// And the decision: an agent who was already on a break when the offer came
/// back did not miss the caller. Nothing is counted against her, so the rule
/// that would have stood her down never fires and her break is left as she
/// set it.
pub fn a_miss_while_on_break_does_not_count_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  // She steps away while her phone is still ringing.
  cluster.agent_is(c, "ann", "on_break")
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))

  assert cluster.availability_becomes(c, "ann", "logged_out") == "on_break"
}

/// The same for an agent who logged out while it rang: a busy or a reject
/// from a phone whose agent has gone is not a miss either.
pub fn a_miss_while_logged_out_does_not_count_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.agent_is(c, "ann", "logged_out")
  cluster.reply(c, "call-one", Rejected("ann"))

  assert cluster.availability_becomes(c, "ann", "available") == "logged_out"
}

/// And it is not a miss: an agent one miss from being stood down is still
/// available after a caller hung up on her ringing phone.
pub fn a_caller_hanging_up_is_not_a_miss_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.left(c, "call-one", Hangup)

  assert cluster.availability_becomes(c, "ann", "logged_out") == "available"
}

/// A break is a pause in a login, not the end of one, so the misses of the
/// morning are still there in the afternoon: the second miss after a break
/// and a resume is the one that stands her down.
pub fn a_break_and_a_resume_keep_the_count_test() {
  let c = strict_queue(2)
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))

  cluster.agent_is(c, "ann", "on_break")
  cluster.changed(c)
  cluster.agent_is(c, "ann", "available")
  cluster.changed(c)

  offer_again(c, "call-one")
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))

  assert cluster.availability_becomes(c, "ann", "logged_out") == "logged_out"
}

/// A login does end one. The number an agent is stood down by is "misses
/// since login", so the miss that happened before they logged out is not
/// half of the two that stand them down after they logged back in.
pub fn a_login_starts_the_count_again_test() {
  let c = strict_queue(2)
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))

  cluster.agent_is(c, "ann", "logged_out")
  cluster.changed(c)
  cluster.agent_logs_in(c, "ann")

  offer_again(c, "call-one")
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  // The first miss of the new login, and she is still working.
  assert cluster.availability_becomes(c, "ann", "logged_out") == "available"

  // The second is the one that stands her down, which is what says the
  // counter was counting and not merely off.
  offer_again(c, "call-one")
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.availability_becomes(c, "ann", "logged_out") == "logged_out"
}

/// `max_no_answer` stands an agent down in a write of its own, and until its
/// `agent_availability` is heard the document may still say she is taking
/// calls. The dispatcher holds her back itself in the meantime: the next
/// tick used to read the old availability and ring her once more.
pub fn a_stood_down_agent_is_not_rung_before_the_write_is_heard_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.availability_becomes(c, "ann", "logged_out") == "logged_out"

  // The document as a cache that has not caught up would still show it.
  cluster.agent_is(c, "ann", "available")
  cluster.at(c, 10)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == []

  // The write's event: from now on the document is the word.
  cluster.agent_changed(c, "ann")
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// A stand-down whose event is never heard does not hold the agent back for
/// ever: past thirty seconds the document is the word again.
pub fn a_stand_down_nobody_heard_lapses_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.availability_becomes(c, "ann", "logged_out") == "logged_out"
  cluster.agent_is(c, "ann", "available")

  cluster.at(c, 29)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == []
  cluster.at(c, 30)
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// The review's finding: the miss is counted from the availability read
/// when the offer comes back, and the stand-down is written after, from a
/// process of its own. An agent who logged out in between used to be
/// written to the no-answer status all the same -- a break by default,
/// which nothing ever ends. The write decides again from the document it
/// goes over: a logged-out agent stays logged out, one who took a break
/// keeps their break, and only one still taking calls is stood down.
pub fn a_stand_down_leaves_an_agent_who_left_as_they_left_test() {
  let c = strict_queue(1)

  cluster.agent_is(c, "ann", "logged_out")
  assert offers.stand_down_if_taking_calls(
      c.kz,
      cluster.account_id,
      "ann",
      types.OnBreak,
    )
    == Ok(None)
  assert cluster.availability(c, "ann") == "logged_out"

  cluster.agent_is(c, "ann", "on_break")
  assert offers.stand_down_if_taking_calls(
      c.kz,
      cluster.account_id,
      "ann",
      types.LoggedOut,
    )
    == Ok(None)
  assert cluster.availability(c, "ann") == "on_break"

  cluster.agent_is(c, "ann", "available_on_demand")
  let assert Ok(Some(_stood_down)) =
    offers.stand_down_if_taking_calls(
      c.kz,
      cluster.account_id,
      "ann",
      types.OnBreak,
    )
  assert cluster.availability(c, "ann") == "on_break"
}

/// What the dispatcher makes of the events its listener hears. A login is
/// the one that resets the misses; every other named change is still named,
/// because the agent's lamp may need putting back to `early`.
pub fn a_login_event_is_the_one_that_resets_test() {
  assert dispatcher.availability_event(event(
      "ann",
      "available",
      Some("logged_out"),
    ))
    == dispatcher.LoggedIn("ann")
  assert dispatcher.availability_event(event(
      "ann",
      "available_on_demand",
      Some("logged_out"),
    ))
    == dispatcher.LoggedIn("ann")

  // A break, a resume and a logout are not logins.
  assert dispatcher.availability_event(event(
      "ann",
      "on_break",
      Some("available"),
    ))
    == dispatcher.AgentChanged("ann")
  assert dispatcher.availability_event(event(
      "ann",
      "available",
      Some("on_break"),
    ))
    == dispatcher.AgentChanged("ann")
  assert dispatcher.availability_event(event(
      "ann",
      "logged_out",
      Some("available"),
    ))
    == dispatcher.AgentChanged("ann")

  // The first change an agent ever has carries no previous value, and
  // logged out is what they were before it.
  assert dispatcher.availability_event(event("ann", "available", None))
    == dispatcher.LoggedIn("ann")

  // An event this release cannot read still asks for a pass: a caller must
  // not be left waiting next to a free agent by a field nobody recognised.
  assert dispatcher.availability_event(doc.object([])) == dispatcher.Changed
  assert dispatcher.availability_event(event(
      "",
      "available",
      Some("logged_out"),
    ))
    == dispatcher.Changed
}

fn event(
  agent_id: String,
  availability: String,
  previous: Option(String),
) -> doc.Value {
  doc.object_some([
    #("Event-Category", Some(doc.String("callcenter"))),
    #("Event-Name", Some(doc.String("agent_availability"))),
    #("Account-ID", Some(doc.String(cluster.account_id))),
    #("Agent-ID", Some(doc.String(agent_id))),
    #("Availability", Some(doc.String(availability))),
    #("Previous", option.map(previous, doc.String)),
  ])
}

// --- A queue deleted --------------------------------------------------------

fn deleted(document: doc.Value) -> doc.Value {
  doc.set(document, ["pvt_deleted"], doc.Bool(True))
}

/// Deleting a queue lets everybody waiting in it go, now: settled, and out
/// of the dispatcher's waiting list. Crossbar's delete leaves the document
/// behind marked `pvt_deleted`, and the pass that reads it -- the next tick,
/// or the next message -- is enough, whether or not the notice of the
/// deletion reached this node. Before, the dispatcher went on reading the
/// deleted document, and the callers waited with nobody offered them until
/// their own clocks ran out, which by default they never do. (What their
/// records say is `records.cancellation`'s, in `records_test`.)
pub fn a_deleted_queue_lets_its_callers_go_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.arrive(c, "call-two", "support", 0, 1)
  assert list.length(cluster.waiting(c)) == 2

  cluster.put_queue(
    c,
    "support",
    deleted(queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)])),
  )
  cluster.tick(c)

  assert cluster.waiting(c) == []
  assert list.sort(cluster.settled(c), string.compare)
    == ["call-one", "call-two"]
  assert fake_offer.count(c.offers) == 0
}

/// A queue document that is gone altogether -- deleted by hand, or purged --
/// is a deleted queue too. The notice of a deletion goes to the dispatcher
/// straight away (`QueueDeleted`), and only that queue's callers leave.
pub fn a_queue_gone_altogether_is_deleted_test() {
  let c =
    cluster.new(
      [
        #("support", queue("longest_idle", [#("ann", 1, 1)])),
        #("sales", queue("longest_idle", [#("ann", 1, 1)])),
      ],
      [#("ann", user([]))],
    )
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.arrive(c, "call-two", "sales", 0, 1)

  let assert Ok(_) =
    c.kz.datamgr.del_doc(kazoo.account_db(cluster.account_id), "support")
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)

  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == ["call-two"]
}

/// A caller being rung for when their queue is deleted is taken out of it
/// at once: their actor is told, calls the ring off and leaves on
/// `no_agents` once its commands are through, which is the actor's to
/// sequence. The agent is freed without a miss -- Ann, one miss from being
/// stood down, is still available -- and a late word of the ring is about
/// an offer this dispatcher no longer holds.
pub fn a_deleted_queue_takes_its_callers_out_at_once_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))

  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  assert cluster.queue_gone(c) == ["call-one"]
  assert cluster.called_off(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert cluster.all_ringing(c) == []
  assert cluster.settled(c) == ["call-one"]

  cluster.reply(c, "call-one", Failed("called_off"))
  assert fake_offer.count(c.offers) == 1
  assert cluster.availability_becomes(c, "ann", "logged_out") == "available"
}

/// A ring that runs out while it is being called off is no miss either.
pub fn a_ring_that_runs_out_as_its_queue_goes_is_no_miss_test() {
  let c = strict_queue(1)
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)

  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.settled(c) == ["call-one"]
  assert cluster.availability_becomes(c, "ann", "logged_out") == "available"
}

/// An agent who picked up before the caller's actor heard of the deletion
/// has the caller: the actor bridged them, and the call goes on outside the
/// queue that is gone. The dispatcher, which let the caller go with the
/// queue, takes nothing of it.
pub fn an_answer_before_a_deletion_goes_on_outside_the_queue_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == []

  cluster.reply(
    c,
    "call-one",
    Answered("ann", "ann-leg", cluster.start_of_time + 1),
  )
  assert cluster.waiting(c) == []
  assert cluster.all_ringing(c) == []
  assert cluster.settled(c) == ["call-one"]
}

/// A ring not yet out when the queue went is called off with the rest: the
/// actor handles the ring first, and the caller has left at once.
pub fn a_ring_not_yet_out_is_called_off_with_the_queue_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  assert cluster.called_off(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert cluster.settled(c) == ["call-one"]

  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  cluster.reply(c, "call-one", Failed("called_off"))
  assert cluster.settled(c) == ["call-one"]
  assert cluster.all_ringing(c) == []
}

/// A caller who arrives in a queue already deleted -- the member published
/// before the deletion, or redelivered after it -- leaves on the pass their
/// arrival runs, and nobody is rung for them.
pub fn a_caller_arriving_in_a_deleted_queue_leaves_at_once_test() {
  let c = two_agent_queue()
  cluster.put_queue(
    c,
    "support",
    deleted(queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)])),
  )
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert fake_offer.count(c.offers) == 0
}

// --- A user who is no longer there -----------------------------------------

/// Ann and Bob in one queue, both available, with Ann's user document as
/// given.
fn ann_as(ann: doc.Value) -> cluster.Cluster {
  let c =
    cluster.new(
      [#("support", queue("longest_idle", [#("ann", 1, 1), #("bob", 1, 2)]))],
      [#("ann", ann), #("bob", user([]))],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "logged_out")
  c
}

fn agents_available(c: cluster.Cluster) -> Result(Int, Nil) {
  let assert [support] = cluster.status(c, Some("support"))
  doc.get_int(support, ["Agents-Available"])
}

/// A disabled user is never offered a caller and never counted available,
/// whatever their availability document still says: the listener that logs
/// them out is another process, off an event that can be lost. Enabled
/// again, and still available, they are offered on the next look.
pub fn a_disabled_agent_is_never_offered_test() {
  let c = ann_as(doc.set(user([]), ["enabled"], doc.Bool(False)))
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert fake_offer.count(c.offers) == 0
  assert agents_available(c) == Ok(0)

  // `put_queue` puts any document of the account; this one is Ann's user.
  cluster.put_queue(c, "ann", doc.set(user([]), ["enabled"], doc.Bool(True)))
  cluster.changed(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// Nor is a user on do-not-disturb, whose phones refuse the call, while
/// their availability document still says available: the listener that
/// logs them out is another process, and every ring until it has would
/// time out and count as a miss.
pub fn an_agent_on_do_not_disturb_is_never_offered_test() {
  let c =
    ann_as(doc.set(
      user([]),
      ["do_not_disturb"],
      doc.object([#("enabled", doc.Bool(True))]),
    ))
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert fake_offer.count(c.offers) == 0
  assert agents_available(c) == Ok(0)
}

/// A deleted user -- Crossbar's soft delete, which leaves the document
/// marked -- is not offered either, and neither is one whose document has
/// gone: a tier naming nobody rings nobody.
pub fn a_deleted_agent_is_never_offered_test() {
  let deleted_ann = ann_as(doc.set(user([]), ["pvt_deleted"], doc.Bool(True)))
  cluster.arrive(deleted_ann, "call-one", "support", 0, 0)
  assert fake_offer.count(deleted_ann.offers) == 0
  assert agents_available(deleted_ann) == Ok(0)

  let gone = ann_as(user([]))
  let assert Ok(_) =
    gone.kz.datamgr.del_doc(kazoo.account_db(cluster.account_id), "ann")
  cluster.arrive(gone, "call-one", "support", 0, 0)
  assert fake_offer.count(gone.offers) == 0
  assert agents_available(gone) == Ok(0)
}

/// An agent disabled while their phone rings for a caller: the ring that
/// comes back unanswered is not their miss -- they are logged out as far as
/// the dispatcher is concerned -- and they are not offered the caller again.
pub fn an_agent_disabled_mid_ring_is_not_charged_a_miss_test() {
  let c = ann_as(user([#("max_no_answer", doc.Int(1))]))
  cluster.agent_is(c, "bob", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  cluster.put_queue(
    c,
    "ann",
    user([#("max_no_answer", doc.Int(1))])
      |> doc.set(["enabled"], doc.Bool(False)),
  )
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  assert cluster.availability_becomes(c, "ann", "on_break") == "available"
  assert cluster.ringing(c, "call-one") == ["bob"]
}

// --- A caller's actor ending while they wait ------------------------------

/// A caller joins their actor on arrival, and one delivered again joins it
/// again, resumed.
pub fn a_caller_joins_their_actor_test() {
  let c = two_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.redelivered(c, "call-one", "support", 0, 0)
  assert cluster.joined(c) == [#("call-one", False), #("call-one", True)]
}

/// The actor of a waiting caller ends -- it crashed, or finished the passage
/// before just as this one's member reached it -- and the caller is joined
/// to a new one, resumed, so that something commands them.
pub fn a_waiting_callers_lost_actor_is_replaced_test() {
  let c = two_agent_queue()
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.joined(c) == [#("call-one", False)]

  fake_calls.actor_died(c.calls)
  cluster.sync(c)
  assert cluster.joined(c) == [#("call-one", False), #("call-one", True)]

  // Nobody waiting any more: nothing to replace.
  assert cluster.cancel(c, "call-one", Hangup)
  fake_calls.actor_died(c.calls)
  cluster.sync(c)
  assert list.length(cluster.joined(c)) == 2
}
