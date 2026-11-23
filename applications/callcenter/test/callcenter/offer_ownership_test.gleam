//// An agent is held by the offer they are in, and only that offer's end
//// lets them go: an agent in two things at once -- a ring a node that died
//// left going, watched here, and another -- stays busy until both are over.

import callcenter/types.{OfferNoAnswer}
import gleam/list
import gleam/option.{None}
import gleam/string
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

/// One queue with Ann alone in it, available.
fn ann_alone() -> cluster.Cluster {
  let c = cluster.new([#("support", queue(["ann"]))], [#("ann", user())])
  cluster.agent_is(c, "ann", "available")
  c
}

/// A caller whose record says the node that died was ringing Ann for them.
fn rung_elsewhere(c: cluster.Cluster, call_id: String, joined: Int) -> Nil {
  cluster.put_record(
    c,
    joined,
    cluster.record(call_id, "support", joined, [#("ann", joined, None)], None),
  )
  cluster.redelivered(c, call_id, "support", 0, joined)
}

/// Two callers taken over from a node that died, each with a ring to Ann
/// still going: both are watched, and both hold her. The first ring runs out
/// and its caller waits again, but Ann is still in the second one's, so
/// nobody rings her for the first caller until that one is over too.
pub fn an_agent_in_two_watches_stays_busy_until_both_end_test() {
  let c = ann_alone()
  rung_elsewhere(c, "call-one", 0)
  rung_elsewhere(c, "call-two", 1)
  assert cluster.watching(c, "call-one") == ["ann"]
  assert cluster.watching(c, "call-two") == ["ann"]

  cluster.watch_reply(c, "call-one", OfferNoAnswer(["ann"]))
  // A miss holds Ann back until the next tick: her no-answer delay is none.
  cluster.tick(c)
  assert list.sort(cluster.waiting(c), string.compare)
    == ["call-one", "call-two"]
  assert fake_offer.count(c.offers) == 0
  assert cluster.ringing(c, "call-one") == []

  cluster.watch_reply(c, "call-two", OfferNoAnswer(["ann"]))
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 1
  assert cluster.ringing(c, "call-one") == ["ann"]
}

/// Ann is ringing here for one caller when another is taken over whose
/// record says a node that died was ringing her too. The watch is the newer
/// and holds her; when it ends she goes back to the ring still going here,
/// and is free only once that one is over as well.
pub fn an_agent_goes_back_to_the_offer_they_are_still_in_test() {
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  rung_elsewhere(c, "call-two", 1)
  assert cluster.watching(c, "call-two") == ["ann"]

  cluster.watch_reply(c, "call-two", OfferNoAnswer(["ann"]))
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 1
  assert cluster.ringing(c, "call-two") == []

  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 2
  let assert Ok(last) = fake_offer.last(c.offers)
  assert last.agents == ["ann"]
}
