//// The types the call center's parts agree on.
////
//// One module, imported by all of them and owned by none: the dispatcher
//// decides who is offered a caller, the caller's actor rings them, the agent
//// control writes availability, and the three only meet here. Nothing in
//// this module does anything -- there are no functions -- so that changing
//// behaviour never means changing this file.

import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/option.{type Option}
import kazoo/doc.{type Value}
import kazoo/listener.{type Delivery}

/// One caller waiting in a queue, as it came off the member queue.
pub type Member {
  Member(
    account_id: String,
    queue_id: String,
    call_id: String,
    /// The kapps_call JSON from member_call, verbatim.
    call: Value,
    priority: Int,
    /// Gregorian seconds.
    joined: Int,
    callflow_node: String,
    caller_id_name: Option(String),
    caller_id_number: Option(String),
    /// The passage's own id, which the callflow action waits for back in
    /// `member_continue`: the member's `Handoff-ID`, or the call id and
    /// the join from a sender that did not say.
    handoff_id: String,
    /// The flows the callflow goes on into when the caller leaves, by
    /// branch: the member's `Branches`, an empty object when it has none.
    branches: Value,
    /// Acked by the dispatcher only.
    delivery: Delivery,
  )
}

pub type Availability {
  LoggedOut
  Available
  AvailableOnDemand
  OnBreak
}

pub type Activity {
  Idle
  Ringing
  OnCall(queue_call: Bool)
  WrappingUp
}

pub type TierState {
  Ready
  Offering
  ActiveInbound
  Standby
  NoAnswer
}

/// What a strategy sees about one agent of one queue.
pub type AgentView {
  AgentView(
    agent_id: String,
    availability: Availability,
    activity: Activity,
    level: Int,
    position: Int,
    tier_state: TierState,
    last_call_end: Option(Int),
    /// Gregorian seconds since which the agent has been free to take a
    /// caller: the latest of their last offer, the end of their last queue
    /// call or wrap-up, and their login or return from a break. What
    /// `longest_idle` orders by.
    free_since: Int,
    answered: Int,
    talk_time_s: Int,
    missed: Int,
  )
}

/// What a strategy is handed for one decision.
pub type Choice {
  Choice(
    /// The strategy's own state, from the last `on_result`.
    memo: Value,
    /// Every agent the tier rules allow for this caller, whatever state they
    /// are in, in the order the view returned them.
    agents: List(AgentView),
    /// The subset of `agents` who could take the caller now.
    selectable: List(AgentView),
  )
}

/// What a strategy answers: whom to ring, and how.
pub type Offer {
  Sequential(List(String))
  Simultaneous(List(String))
}

/// One agent's part in one offer, as much of it as a strategy needs.
///
/// `Offered` is sent as the offer starts, in ring order, and is the one a
/// cursor moves on: the outcomes come back in whatever order the phones
/// answer, so a cursor moved on outcomes is rewound whenever an older offer
/// finishes after a newer one.
pub type OfferResult {
  /// The agent's phone is about to ring.
  Offered
  /// The agent answered.
  Taken
  /// No answer, busy or rejected.
  Missed
  /// The caller left before the offer finished.
  Abandoned
  /// Another agent on the same offer answered first.
  Lost
}

/// What the queue document says that an offer needs.
pub type OfferSettings {
  OfferSettings(
    ring_timeout_s: Int,
    cid_prefix: Option(String),
    record: Bool,
    outbound_caller_id_name: Option(String),
    outbound_caller_id_number: Option(String),
    /// The queue's `moh`: what the caller was hearing while they waited,
    /// and so what the offer keeps playing to them while the phones ring.
    /// `None` is the account's hold music.
    hold_media: Option(String),
  )
}

/// What a caller's actor says to the dispatcher, naming the offer it is
/// about: for each offer, `OfferRinging` once the ring is out, then at
/// most one of `Answered`, `OfferNoAnswer`, `Busy`, `Rejected` and
/// `Failed`, then `Ended` if `Answered` was sent -- or `Failed` with
/// `called_off`, when the dispatcher called the ring off before anybody
/// answered. A caller who leaves of their own accord is not said here: the
/// actor tells the shard (`CallerLeft`), which settles them and tells the
/// dispatcher. `Present` is about no offer the dispatcher made: see
/// `Presence`.
///
/// `OfferRinging` and `OfferNoAnswer` carry the `Offer` prefix because a
/// Gleam module has one namespace for constructors, and `Activity` and
/// `TierState` above already have a `Ringing` and a `NoAnswer`. The offer
/// side takes the prefix, not the agent side, because an offer reply is
/// written in one module and read in one, where `Activity` reaches the agent
/// API, the maintenance output and the event payloads.
pub type OfferReply {
  OfferRinging(agents: List(String))
  Answered(agent_id: String, agent_call_id: String, at: Int)
  OfferNoAnswer(agents: List(String))
  Busy(agent_id: String)
  Rejected(agent_id: String)
  Failed(reason: String)
  Ended(result: EndResult, at: Int)
  /// Not about an offer the dispatcher made: where a caller it did not see
  /// join stands. See `Presence`.
  Present(presence: Presence)
}

/// What a caller's actor says of a caller the dispatcher was handed without
/// seeing them join: one the broker handed out again because the node
/// holding them died, one whose actor ended and was replaced, one whose
/// dispatcher ended. The actor finds out where they stand
/// (`callcenter/call/recovery`), and until it says, nobody is rung for
/// them. The offer the reply names is the one anything found going on for
/// the caller is held under from now on.
pub type Presence {
  /// Waiting, nobody being rung.
  PresentWaiting
  /// Phones ringing for them until the Gregorian second `ceiling`: a
  /// supervisor's when `pickup`.
  PresentRinging(agents: List(String), ceiling: Int, pickup: Bool)
  /// Through to `agent_id` on `leg` since `answered_at`: a supervisor who
  /// picked them up when `pickup`.
  PresentConnected(
    agent_id: String,
    leg: String,
    answered_at: Int,
    pickup: Bool,
  )
  /// The queue is done with them -- their passage was closed, or they were
  /// on their way out -- and their member is settled.
  PresentOver
}

pub type EndResult {
  Completed
  AgentHangup
  CallerHangup
  FailedBridge
  /// The agent passed the caller on, blind or attended: the queue's part in
  /// the call is over and the caller is talking to somebody else.
  Transferred
}

/// Which offer a reply is about: the caller it rings for, and a reference
/// made when the dispatcher asked for it.
///
/// The call id alone does not say. A caller who times out of one queue into
/// another in the same account is the same call id with a second offer, and
/// the first offer may still be resolving when the second starts; an agent
/// taken out of an offer by hand leaves its ring to end as it ends. Either
/// one's reply, read by call id, would be applied to whatever offer holds the
/// caller now. Every reply carries this instead, and the dispatcher drops one
/// that does not name the offer it is holding.
pub type OfferId {
  OfferId(call_id: String, serial: Reference)
}

/// The dispatcher's request for an offer: ring these agents for this member.
pub type OfferRequest {
  OfferRequest(
    member: Member,
    /// This offer, as its replies name it.
    id: OfferId,
    /// User ids; one for `Sequential`, many for `Simultaneous`.
    agents: List(String),
    settings: OfferSettings,
    /// Where the replies go, each with the offer's `id`.
    reply_to: Subject(#(OfferId, OfferReply)),
    /// The devices to ring, when they are not every device each of `agents`
    /// owns: a supervisor's pickup rings the phones the supervisor named,
    /// marked with the one id in `agents`. `None` for an agent's offer.
    devices: Option(List(String)),
  )
}

/// Reasons a member leaves without an agent (the member_cancel enum).
pub type CancelReason {
  Hangup
  Timeout
  NoAgentTimeout
  ExitKey
  QueueFull
  Transfer
  /// The queue was deleted while the caller waited in it. The only reason
  /// the dispatcher gives rather than the caller's action: the dispatcher
  /// takes them out and tells the action, which leaves on `no_agents`.
  QueueDeleted
  /// The caller's actor kept crashing on this call, and the one after it
  /// handed the caller back on `no_agents` rather than try again
  /// (`callcenter/call/calls`).
  Quarantined
}
