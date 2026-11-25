//// The ceiling on an offer against the monitor on its process: an offer
//// whose process crashed is closed as a crash whichever the dispatcher
//// hears first.

import callcenter/dispatcher
import callcenter/types.{OfferRinging}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import kazoo/doc
import support/cluster
import support/fake_offer

/// Ann alone, stood down after one miss into `logged_out`, so that "was she
/// charged a miss" is a question her document answers.
fn strict() -> cluster.Cluster {
  let c =
    cluster.new(
      [
        #(
          "support",
          doc.object([
            #("pvt_type", doc.String("queue")),
            #("name", doc.String("Support")),
            #("strategy", doc.String("longest_idle")),
            #("agent_ring_timeout", doc.Int(20)),
            #("agent_no_answer_status", doc.String("logged_out")),
            #("agents", doc.List([doc.object([#("id", doc.String("ann"))])])),
          ]),
        ),
      ],
      [
        #(
          "ann",
          doc.object([
            #("pvt_type", doc.String("user")),
            #("call_center", doc.object([#("max_no_answer", doc.Int(1))])),
          ]),
        ),
      ],
    )
  cluster.agent_is(c, "ann", "available")
  c
}

/// The caller's actor crashes with its ring out, past its ceiling, and the
/// tick is handled before the monitor's word for it. The tick closes it as
/// the monitor would: a failure, and Ann is not charged a miss for it. There
/// is no actor left to call the ring off. The monitor's word, heard after,
/// finds nothing to do.
pub fn a_crashed_offer_past_its_ceiling_is_a_crash_and_not_a_miss_test() {
  let c = strict()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  // Twenty seconds of ring timeout plus five of grace.
  cluster.at(c, 26)

  let assert Ok(pid) = process.subject_owner(c.dispatcher)
  let _ = suspend(pid)
  process.send(c.dispatcher, dispatcher.Tick)
  // Dead now, and its `Down` is queued behind the tick.
  fake_offer.died(c.offers)
  let _ = resume(pid)
  cluster.sync(c)

  assert cluster.called_off(c) == []
  assert cluster.availability_becomes(c, "ann", "logged_out") == "available"
  assert cluster.waiting(c) == ["call-one"]
  assert cluster.alive(c)
}

@external(erlang, "sys", "suspend")
fn suspend(pid: Pid) -> Dynamic

@external(erlang, "sys", "resume")
fn resume(pid: Pid) -> Dynamic
