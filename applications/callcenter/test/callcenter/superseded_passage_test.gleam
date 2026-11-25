//// A caller who moves on to another queue while an offer of the queue they
//// left is still in flight: the new passage is theirs from then on, and
//// what the old offer does when it ends is about the old passage only.

import callcenter/dispatcher
import callcenter/dispatcher/offers
import callcenter/records
import callcenter/types.{
  Answered, Completed, Ended, Failed, OfferNoAnswer, OfferRinging, Transfer,
}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc
import support/cluster
import support/fake_offer

fn queue(agents: List(String)) -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String("longest_idle")),
    #("agent_ring_timeout", doc.Int(20)),
    #(
      "agents",
      doc.List(
        list.map(agents, fn(id) { doc.object([#("id", doc.String(id))]) }),
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

/// Support has Ann and the overflow has Bob, both free.
fn two_queues() -> cluster.Cluster {
  let c =
    cluster.new([#("support", queue(["ann"])), #("overflow", queue(["bob"]))], [
      #("ann", user()),
      #("bob", user()),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  c
}

// --- A queue deleted under a caller who has moved on ------------------------

/// Support is deleted while Ann rings for the caller: the ring is called off
/// and the caller leaves support at once, their actor handing them back on
/// `no_agents`. Their callflow sends them on to the overflow, a passage of
/// its own, offered to Bob; the support ring's late word is about an offer
/// this dispatcher no longer holds.
pub fn a_deletion_does_not_follow_the_caller_into_the_next_queue_test() {
  let c = two_queues()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  assert cluster.called_off(c) == ["call-one"]
  assert cluster.waiting(c) == []
  assert cluster.settled(c) == ["call-one"]

  cluster.reply(c, "call-one", Failed("called_off"))
  cluster.arrive(c, "call-one", "overflow", 0, 30)

  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.ringing(c, "call-one") == ["bob"]
  let assert Ok(last) = fake_offer.last(c.offers)
  assert last.member.queue_id == "overflow"
}

/// The same deletion with nowhere else for the caller to go: they are out
/// of the queue at once, settled once.
pub fn a_deletion_takes_out_the_passage_it_was_for_test() {
  let c = two_queues()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  process.send(c.dispatcher, dispatcher.QueueDeleted("support"))
  cluster.sync(c)
  cluster.reply(c, "call-one", Failed("called_off"))

  assert cluster.settled(c) == ["call-one"]
  assert cluster.waiting(c) == []
}

// --- Which passage the end of an offer closes ------------------------------

fn in_support() -> types.Member {
  cluster.member("call-one", "support", 0, cluster.start_of_time)
}

fn in_overflow() -> types.Member {
  cluster.member("call-one", "overflow", 0, cluster.start_of_time + 30)
}

/// Unanswered, the offer's own passage is the one left over: the caller has
/// moved on from it, and waits on in the new one.
pub fn an_unanswered_offer_closes_the_passage_it_was_for_test() {
  assert offers.superseded_passage(
      in_support(),
      Ok(in_overflow()),
      answered: False,
    )
    == Some(in_support())
}

/// Answered, the answer is the passage the agent was rung for, and the one
/// the caller had moved on to is the one nothing will ever end.
pub fn an_answer_closes_the_passage_the_caller_moved_on_to_test() {
  assert offers.superseded_passage(
      in_support(),
      Ok(in_overflow()),
      answered: True,
    )
    == Some(in_overflow())
}

/// A caller still in the offer's own passage -- a redelivery, the same
/// queue joined again -- or no longer waiting leaves nothing to close.
pub fn the_same_passage_closes_nothing_test() {
  let again = cluster.member("call-one", "support", 3, cluster.start_of_time)
  assert offers.superseded_passage(in_support(), Ok(again), answered: False)
    == None
  assert offers.superseded_passage(in_support(), Ok(again), answered: True)
    == None
  assert offers.superseded_passage(in_support(), Error(Nil), answered: False)
    == None
}

/// What the passage closed is left saying: cancelled, as a transfer.
pub fn a_superseded_passage_is_closed_as_a_transfer_test() {
  let closed =
    cluster.record("call-one", "support", 0, [#("ann", 0, None)], None)
    |> records.cancellation(Transfer, cluster.start_of_time + 40)
  assert doc.get_string(closed, ["cancel_reason"]) == Ok("transfer")
  assert doc.get_int(closed, ["cancelled"]) == Ok(cluster.start_of_time + 40)
}

/// Ann misses the support caller after they moved on to the overflow: the
/// caller waits on in the overflow, unsettled, and is offered there.
pub fn a_miss_after_the_caller_moved_on_leaves_them_waiting_test() {
  let c = two_queues()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  cluster.arrive(c, "call-one", "overflow", 0, 30)
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))

  assert cluster.settled(c) == []
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// Ann answers the support caller after they moved on to the overflow: the
/// caller waits no more, and is settled once, when the call ends, on the
/// delivery held at the answer.
pub fn an_answer_after_the_caller_moved_on_connects_them_test() {
  let c = two_queues()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  cluster.arrive(c, "call-one", "overflow", 0, 30)
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "ann-leg", cluster.start_of_time + 31),
  )

  assert cluster.settled(c) == []
  assert cluster.waiting(c) == []
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 90))
  assert cluster.settled(c) == ["call-one"]
}
