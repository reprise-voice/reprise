//// A reply is about the offer that sent it, not about whatever offer holds
//// the caller when it arrives.

import callcenter/dispatcher
import callcenter/types.{Answered, Failed, OfferNoAnswer, OfferRinging, Timeout}
import gleam/erlang/process
import gleam/list
import kazoo/doc
import support/cluster
import support/fake_offer

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
        list.index_map(agents, fn(id, position) {
          doc.object([
            #("id", doc.String(id)),
            #("level", doc.Int(1)),
            #("position", doc.Int(position + 1)),
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

/// The offer at `index` among everything asked for, oldest first.
fn request(c: cluster.Cluster, index: Int) -> types.OfferRequest {
  let assert Ok(request) =
    fake_offer.requests(c.offers) |> list.drop(index) |> list.first
  request
}

/// A caller times out of one queue into an overflow queue in the same
/// account while the first queue's offer is still resolving. Its reply, when
/// it comes, names the same call as the overflow's offer and is about none
/// of it: the overflow's agent keeps ringing, and is not offered a second
/// time.
pub fn a_late_reply_from_the_queue_a_caller_left_is_dropped_test() {
  let c =
    cluster.new([#("support", queue(["ann"])), #("overflow", queue(["bob"]))], [
      #("ann", user()),
      #("bob", user()),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")

  cluster.arrive(c, "overflowing", "support", 0, 0)
  assert cluster.ringing(c, "overflowing") == ["ann"]
  let first = request(c, 0)

  let assert True = cluster.cancel(c, "overflowing", Timeout)
  cluster.arrive(c, "overflowing", "overflow", 0, 30)
  assert cluster.ringing(c, "overflowing") == ["bob"]
  let second = request(c, 1)
  assert first.id != second.id

  fake_offer.reply(first, OfferNoAnswer(["ann"]))
  cluster.sync(c)

  // Bob is still being rung, by the offer that is still running, and nobody
  // asked for a second one.
  assert cluster.ringing(c, "overflowing") == ["bob"]
  assert fake_offer.count(c.offers) == 2

  // Bob is still held: another caller in the overflow waits for him.
  cluster.arrive(c, "behind", "overflow", 0, 40)
  assert fake_offer.count(c.offers) == 2
  assert cluster.ringing(c, "behind") == []

  // The overflow's own answer is the one that counts. The first settlement
  // is the support queue's member, when the caller timed out of it.
  assert cluster.settled(c) == ["overflowing"]
  fake_offer.reply(second, Answered("bob", "bob-leg", cluster.start_of_time))
  cluster.sync(c)
  assert cluster.settled(c) == ["overflowing", "overflowing"]
}

/// `release_agent` calls off the ring the agent is in, and the offer's reply
/// that the ring is over lets the agent go. The caller stays and is offered
/// again, and anything the released offer says after that is about an offer
/// that no longer exists: it neither ends the new one nor frees the agent it
/// is ringing.
pub fn a_late_reply_after_release_agent_is_dropped_test() {
  let c = cluster.new([#("support", queue(["ann"]))], [#("ann", user())])
  cluster.agent_is(c, "ann", "available")

  cluster.arrive(c, "released", "support", 0, 0)
  assert cluster.ringing(c, "released") == ["ann"]
  let first = request(c, 0)
  fake_offer.reply(first, OfferRinging(["ann"]))

  assert process.call(c.dispatcher, 5000, dispatcher.ReleaseAgent("ann", _))
  cluster.sync(c)
  assert cluster.called_off(c) == ["released"]
  fake_offer.reply(first, Failed("originator_cancel"))
  cluster.sync(c)

  // Still waiting, and offered again: to Ann, the only agent there is.
  assert cluster.waiting(c) == ["released"]
  assert fake_offer.count(c.offers) == 2
  let second = request(c, 1)
  assert second.agents == ["ann"]

  fake_offer.reply(first, OfferNoAnswer(["ann"]))
  cluster.sync(c)
  assert cluster.ringing(c, "released") == ["ann"]
  assert fake_offer.count(c.offers) == 2

  // Nor does an answer from the released offer connect anybody.
  fake_offer.reply(first, Answered("ann", "ann-leg", cluster.start_of_time))
  cluster.sync(c)
  assert cluster.settled(c) == []
  assert cluster.waiting(c) == ["released"]

  fake_offer.reply(second, Answered("ann", "ann-leg", cluster.start_of_time))
  cluster.sync(c)
  assert cluster.settled(c) == ["released"]
}

/// An agent released by hand while talking has their call ended here: the
/// record is closed and nothing the call's process says afterwards is heard.
pub fn release_agent_ends_an_answered_offer_test() {
  let c = cluster.new([#("support", queue(["ann"]))], [#("ann", user())])
  cluster.agent_is(c, "ann", "available")

  cluster.arrive(c, "talking", "support", 0, 0)
  let first = request(c, 0)
  fake_offer.reply(first, Answered("ann", "ann-leg", cluster.start_of_time))
  cluster.sync(c)
  assert cluster.settled(c) == ["talking"]

  assert process.call(c.dispatcher, 5000, dispatcher.ReleaseAgent("ann", _))
  cluster.sync(c)
  assert cluster.report(c).offers == []

  // Free, and offered the next caller at once.
  cluster.arrive(c, "next", "support", 0, 10)
  assert cluster.ringing(c, "next") == ["ann"]

  // The first call's end, arriving late, does not free Ann from the second.
  fake_offer.reply(first, types.Ended(types.Completed, cluster.start_of_time))
  cluster.sync(c)
  assert cluster.ringing(c, "next") == ["ann"]
}
