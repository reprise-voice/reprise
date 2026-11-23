//// What a dispatcher is started with.
////
//// Its own module, below `callcenter/dispatcher`, because every part of the
//// dispatcher reads it and none of them may import the actor itself.
//// `dispatcher.Config` is this type under its public name, and
//// `dispatcher.config` is `live`.

import callcenter/activity
import callcenter/offer
import callcenter/presence
import callcenter/queue_doc
import callcenter/takeover
import callcenter/types.{type Member}
import gleam/erlang/process.{type Pid}
import kazoo/call
import kazoo/kazoo.{type Kazoo}
import kazoo/listener
import kazoo/modb

/// What the dispatcher is, and the two things it is given rather than
/// finding for itself: the clock, so a test can hold time still, and the
/// function that rings an agent, so this module does not depend on the one
/// that does.
pub type Config {
  Config(
    kz: Kazoo,
    account_id: String,
    /// `system_config/callcenter.announce_default_interval_s`.
    announce_interval_s: Int,
    /// `system_config/callcenter.offer_grace_s`.
    offer_grace_s: Int,
    /// `system_config/callcenter.default_agent_no_answer_status`.
    default_no_answer_status: String,
    /// `system_config/callcenter.queue_refresh_s`: how often a queue
    /// document is read from the database rather than the cache.
    queue_refresh_s: Int,
    /// Gregorian seconds.
    now: fn() -> Int,
    /// Watch a caller whose offer, or whose conversation, was left behind by
    /// a node that died, instead of ringing over it.
    ///
    /// `takeover.start` on a node and a fake in the tests, for the same
    /// reason the offer is a function: what this actor does with the replies
    /// is the part worth testing, and neither a switch nor a broker is there
    /// to produce them.
    start_watch: fn(takeover.Request) -> Result(Pid, String),
    /// Settle a caller's member message: the broker may forget them.
    ///
    /// It is `listener.ack` on a node and nothing else, and it is here as a
    /// function because "every caller is settled exactly once" is the one
    /// property of this actor that matters most and a test cannot see an ack
    /// go out to a broker that is not there.
    settle: fn(Member) -> Nil,
    /// Show a state on an agent's login lamp: agent id, then the dialog
    /// state. `presence.publish` in a process of its own on a node, because
    /// finding the address reads documents; a recorder in the tests.
    lamp: fn(String, String) -> Nil,
    /// What the account's agents' phones are doing, every agent in one
    /// answer, read once at the start of every pass: `activity.snapshot` on
    /// a node, whatever a test says in the tests. An `Error` is an activity
    /// actor that did not answer, and nobody is offered on it.
    activity: fn() -> Result(activity.Reading, String),
    /// Call off the ring an offer has going on a caller's channel:
    /// `kazoo/call.unbridge` on the call the member carries, on a node; a
    /// recorder in the tests. The caller stays: the bridge ends with
    /// `ORIGINATOR_CANCEL`, the offer replies, and the callflow action puts
    /// them back on hold.
    call_off: fn(Member) -> Nil,
    /// Tell an offer's process its ring has been called off, whether the
    /// dispatcher unbridges it, and the member held for the caller now,
    /// whose call names the control queue an unbridge of the offer's own
    /// goes to: `offer.call_off` on a node, a recorder in the tests. See
    /// `offers.stop`.
    stop_offer: fn(Pid, Bool, Member) -> Nil,
  )
}

/// The configuration a node runs with.
pub fn live(kz: Kazoo, account_id: String) -> Config {
  Config(
    kz: kz,
    account_id: account_id,
    announce_interval_s: kz.config.get_int("announce_default_interval_s", 30),
    offer_grace_s: kz.config.get_int("offer_grace_s", 5),
    default_no_answer_status: kz.config.get_string(
      "default_agent_no_answer_status",
      "on_break",
    ),
    queue_refresh_s: case
      kz.config.get_int("queue_refresh_s", queue_doc.default_refresh_s)
    {
      seconds if seconds > 0 -> seconds
      _invalid -> queue_doc.default_refresh_s
    },
    now: modb.now,
    start_watch: takeover.start,
    settle: fn(member: Member) { listener.ack(member.delivery) },
    lamp: fn(agent_id, state) {
      let _ =
        process.spawn_unlinked(fn() {
          let _ = presence.publish(kz, account_id, agent_id, state)
          Nil
        })
      Nil
    },
    activity: fn() { activity.snapshot(account_id) },
    call_off: fn(member: Member) { call.unbridge(call.from_value(member.call)) },
    stop_offer: offer.call_off,
  )
}
