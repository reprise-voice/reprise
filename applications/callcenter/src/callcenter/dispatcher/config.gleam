//// What a dispatcher is started with.
////
//// Its own module, below `callcenter/dispatcher`, because every part of the
//// dispatcher reads it and none of them may import the actor itself.
//// `dispatcher.Config` is this type under its public name, and
//// `dispatcher.config` is `live`.

import callcenter/activity
import callcenter/call/actor
import callcenter/call/calls
import callcenter/presence
import callcenter/queue_doc
import callcenter/shards
import callcenter/stall
import callcenter/types.{type Member, type OfferId, type OfferReply}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, Some}
import kazoo/kazoo.{type Kazoo}
import kazoo/listener
import kazoo/modb

/// What the dispatcher is, and the things it is given rather than finding
/// for itself: the clock, so a test can hold time still, and its callers'
/// actors, so this module does not depend on the ones that command them.
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
    /// The callers' actors (`callcenter/call/actor`), each the one process
    /// commanding one caller: the shard's own on a node, recorders in the
    /// tests.
    calls: Calls,
    /// Whether this dispatcher may still act for its shard: no stall of the
    /// node since it was started (`callcenter/stall`). Always, in the
    /// tests that are not about a stall.
    fresh: fn() -> Bool,
  )
}

/// What the dispatcher tells its callers' actors. Every one names the
/// caller by their member; the offers are rung through the function the
/// dispatcher is started with, which is the same actors'.
pub type Calls {
  Calls(
    /// A caller joined, or was delivered again: `True` when this dispatcher
    /// did not see them join, and the actor is to say where they stand
    /// (`Present`, on the subject given). Starts the caller's actor if they
    /// have none, and answers its pid.
    join: fn(Member, Bool, Subject(#(OfferId, OfferReply))) ->
      Result(Pid, String),
    /// A call a node that died connected, to be watched to its end under
    /// the offer given: the agent, the agent's leg, when it was answered.
    adopt: fn(
      Member,
      OfferId,
      String,
      String,
      Int,
      Subject(#(OfferId, OfferReply)),
    ) -> Result(Pid, String),
    /// Call an offer's ring off. The actor hangs its legs up, and says
    /// `Failed(called_off)` once the ring is over -- or `Answered`, when an
    /// agent picked up before the call-off reached it.
    call_off: fn(Member, OfferId) -> Nil,
    /// The caller's queue was deleted: they leave it on `no_agents`.
    queue_gone: fn(Member) -> Nil,
    /// Where the caller stands: position, callers waiting, agents free when
    /// the dispatcher can say.
    positioned: fn(Member, Int, Int, Option(Int)) -> Nil,
  )
}

/// The actors of one shard's calls, reached through its registry.
pub fn calls_of(registry: Subject(calls.Message)) -> Calls {
  Calls(
    join: fn(member, resumed, reply_to) {
      calls.join(registry, member, resumed, reply_to)
    },
    adopt: fn(member, offer, agent_id, leg, at, reply_to) {
      calls.adopt(registry, member, offer, agent_id, leg, at, reply_to)
    },
    call_off: fn(member, offer) {
      calls.tell(registry, member, actor.CallOff(offer))
    },
    queue_gone: fn(member) { calls.tell(registry, member, actor.QueueGone) },
    positioned: fn(member, position, waiting, available) {
      calls.tell(
        registry,
        member,
        actor.Positioned(Some(position), Some(waiting), available),
      )
    },
  )
}

/// The configuration a node runs with.
pub fn live(kz: Kazoo, account_id: String) -> Config {
  // Built as the dispatcher is started, so this is when it started.
  let since = stall.now_ms()
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
    calls: calls_of(
      calls.of_shard(shards.of_account(account_id, shards.count(kz))),
    ),
    fresh: fn() { stall.fresh(since) },
  )
}
