//// The dispatcher's state: one account's waiting callers, offers in flight
//// and timers, as the actor holds them between messages.
////
//// Internal to `callcenter/dispatcher` and the modules under it. It is its
//// own module only because Gleam has no mutual imports: the arrivals, the
//// offers, the timers and the pass each transform this record, and they
//// cannot see a type the actor defines. Nothing outside the dispatcher reads
//// or builds one.

import callcenter/dispatcher/config.{type Config}
import callcenter/presence
import callcenter/strategy
import callcenter/types.{
  type Activity, type CancelReason, type Member, type OfferId, type OfferReply,
  type OfferRequest,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option}
import kazoo/listener

/// What one waiting caller is, beyond the member message itself.
@internal
pub type Wait {
  Wait(
    member: Member,
    /// The position last published, so that a change is what publishes one.
    position: Int,
    /// When a position was last published, for the announcement interval.
    announced_at: Int,
    /// Whether the callflow re-run of plan 4.4 has already been asked for.
    rerun: Bool,
    /// Everybody this passage has rung so far. A caller works down the
    /// list: an agent who has already had them is passed over until
    /// everybody who could take them has, and only then does the list start
    /// again. Without it a zero delay would put a caller back on the agent
    /// who just missed them while the one after was still ringing.
    tried: List(String),
  )
}

/// One offer in flight.
@internal
pub type Offer {
  Offer(
    /// What this offer's replies carry. A reply naming anything else is
    /// about an offer that has since been replaced or given up on.
    id: OfferId,
    queue_id: String,
    member: Member,
    /// Everybody the offer was asked to ring.
    agents: List(String),
    /// Everybody it is still ringing, narrowed by `OfferRinging`.
    ringing: List(String),
    started_at: Int,
    /// When the offer is given up on: the ring timeout plus the grace.
    ceiling: Int,
    /// Set when the offer has been answered, so the reply after it is an
    /// end and not a miss.
    connected: Option(#(String, String, Int)),
    /// The process doing the ringing, while it is doing it.
    ///
    /// The ceiling does not take back an offer whose process is still alive:
    /// its phones may still be ringing, and a reply that would have been
    /// its own is dropped once the offer is gone.
    pid: Option(Pid),
    /// Whether the ring is out on the switch: the offer said `OfferRinging`,
    /// or it is a ring a node that died left going. Before it there is no
    /// bridge on the caller's channel to call off.
    rung: Bool,
    /// Whether the ring has been called off, because the agent was released
    /// by hand while it rang. The offer is held until it replies, as any
    /// other is, but whatever it says short of an answer is nobody's miss.
    called_off: Bool,
  )
}

/// A waiting caller this dispatcher is taking out of the queue, once the
/// ring going on for them is over.
///
/// The mark is the passage's and not the caller's: a caller who moves on to
/// another queue while the ring is called off -- a timeout into an overflow,
/// the member of which overtook the deletion -- is a new passage, and it is
/// not the one being taken out. See `offers.leave_if_leaving`.
@internal
pub type Leaving {
  Leaving(
    /// The passage the mark was set for (`records.passage_id`).
    passage: String,
    reason: CancelReason,
  )
}

/// A supervisor's pickup in flight: an offer in `State.offers` like any
/// other, which this says is ringing a supervisor and not an agent. See
/// `dispatcher/pickup`.
@internal
pub type Pickup {
  Pickup(
    /// The offer this is. An offer under the same call id with another id
    /// is somebody else's.
    id: OfferId,
    /// What the request named: `device` or `user`, and its id.
    target_type: String,
    target_id: String,
    /// Whoever asked, waiting for what came of it until the offer says its
    /// bridge is out -- `Ok` with the ring's timeout -- or that nothing
    /// rang -- `Error` with why. Told once, and `None` after.
    tell: Option(fn(Result(Int, String)) -> Nil),
    /// The monotonic millisecond past which nobody is waiting for that.
    answer_by: Int,
  )
}

/// What this node's activity actor said about the account's agents when it
/// was last asked, which is at the start of every pass.
@internal
pub type Activities {
  /// Its answer: agent id to activity, and `Idle` for an agent it does not
  /// name.
  Read(Dict(String, Activity))
  /// It did not answer. Nobody is ready until it does: an agent whose
  /// phones nobody could look at may be talking.
  Unread
}

/// Whether the account's activity can be believed yet.
@internal
pub type Sync {
  /// The switches have not answered since the account was watched: an agent
  /// on a call that began before looks idle. Nobody is offered until they
  /// answer, or until `until`, whichever is first.
  Syncing(until: Int)
  Synced
}

/// One agent as this dispatcher has seen them, in its own memory: when they
/// last became free to take a caller, and the queue calls it connected and
/// ended for them this login.
@internal
pub type Worked {
  Worked(free_since: Int, answered: Int, talk_time_s: Int)
}

@internal
pub type State {
  State(
    config: Config,
    /// Where the next `Tick` is sent. The actor maps it into its own
    /// mailbox, so that a tick is heard in order with everything else.
    ticks: Subject(Nil),
    replies: Subject(#(OfferId, OfferReply)),
    start_offer: fn(OfferRequest) -> Result(Pid, String),
    /// Call id to the caller waiting.
    waiting: Dict(String, Wait),
    /// Call id to the offer in flight for that caller.
    offers: Dict(String, Offer),
    /// Call id to the supervisor's pickup among `offers`, for the offers
    /// that are one. Its replies are `dispatcher/pickup`'s, not `offers`'.
    pickups: Dict(String, Pickup),
    /// Call id to why a waiting caller is being taken out of the queue by
    /// this dispatcher, while the ring going on for them is called off. They
    /// leave when the offer says the ring is over, unless it says an agent
    /// answered first: see `offers.queue_deleted`.
    leaving: Dict(String, Leaving),
    /// Agent id to the offer they are in. One at a time, always: this is the
    /// dictionary that makes that true. The entry is the offer's own, and
    /// only that offer's end lets the agent go (`offers.hold`,
    /// `offers.release`).
    busy: Dict(String, OfferId),
    /// Agent id to the second before which they are not offered another
    /// caller, from the per-agent reject, busy and no-answer delays.
    delayed: Dict(String, Int),
    /// Agent id to when their wrap-up ends.
    wrapup: Dict(String, Int),
    /// Agent id to the second until which they are held back because
    /// `max_no_answer` stood them down, while the availability that says so
    /// is still being written. The write is a process of its own, and until
    /// its `agent_availability` event is heard the document may still say
    /// they are taking calls.
    stood_down: Dict(String, Int),
    /// Agent id to the second until which the agent is taken to have no
    /// availability document -- they never logged in -- without reading it
    /// again. See `view.no_document_s`.
    no_document: Dict(String, Int),
    /// Agent id to consecutive misses since they logged in, for
    /// `max_no_answer`. An answer clears it, and so does a login: the misses
    /// of a shift the agent has ended do not stand them down in the next.
    misses: Dict(String, Int),
    /// Queue id to the strategy's own state.
    memo: Dict(String, strategy.QueueState),
    /// Agent id to what this dispatcher has itself seen them do. See
    /// `callcenter/dispatcher/worked`.
    worked: Dict(String, Worked),
    /// Queue id to the shape the last `queue_stats` reported -- callers
    /// waiting and agents free -- so that only a change publishes one.
    stats: Dict(String, #(Int, Int)),
    /// What this dispatcher last showed on each agent's login lamp, so that
    /// only a change publishes.
    lamps: presence.Lamps,
    ticking: Bool,
    /// The account's agent events, so that a login is heard rather than
    /// waited for. `None` off a node, where there is no broker.
    listening: Option(listener.Server),
    /// The account's activity, read once a pass. See `dispatcher/view`.
    activities: Activities,
    sync: Sync,
    /// Watch the account in the node's activity actor for this dispatcher,
    /// as its start does: again when a reading says the actor no longer
    /// watches it, because the actor restarted (`view.read_activity`).
    watch_activity: fn() -> Nil,
  )
}

// --- Who is in which offer -------------------------------------------------

/// The offer an agent is in: the one `State.busy` names for them, if this
/// dispatcher still holds it. An entry naming an offer that has since been
/// replaced is nobody's, so an agent it names is free.
pub fn offer_of(state: State, agent_id: String) -> Result(Offer, Nil) {
  case dict.get(state.busy, agent_id) {
    Ok(id) -> held_offer(state, id)
    Error(Nil) -> Error(Nil)
  }
}

/// Whether the offer `id` is a supervisor's pickup (`dispatcher/pickup`),
/// which moves no agent state.
pub fn is_pickup_offer(state: State, id: OfferId) -> Bool {
  case dict.get(state.pickups, id.call_id) {
    Ok(pickup) -> pickup.id == id
    Error(Nil) -> False
  }
}

/// The offer `id` names, if it is still the one this dispatcher holds for
/// its caller.
pub fn held_offer(state: State, id: OfferId) -> Result(Offer, Nil) {
  case dict.get(state.offers, id.call_id) {
    Ok(offer) if offer.id == id -> Ok(offer)
    _replaced_or_gone -> Error(Nil)
  }
}
