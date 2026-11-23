//// One offer: an agent's phones ringing for one waiting caller.
////
//// The dispatcher decides who is rung; this rings them. `start` spawns one
//// process per offer, which rebuilds the caller's call from the
//// member message, builds the agents' endpoints on it, bridges from the
//// caller's own control queue -- so the agent leg originates on the caller's
//// media server, whichever node this is -- and reports what happened on the
//// dispatcher's subject.
////
//// **The caller's media.** While the phones ring the offer owns it. The
//// caller is on hold music the callflow action put there, and hold never
//// finishes on its own: a bridge queued behind it would wait until the
//// caller left and be thrown away with the rest of the queue. So the bridge
//// interrupts -- `Insert-At: flush` -- and carries the queue's hold music as
//// its ringback, which is what the caller keeps hearing until an agent
//// answers or the ring runs out. The action never interrupts in return: its
//// holds are queued, so one that arrives while the bridge rings waits behind
//// it and puts the caller back on hold the moment the ring comes to
//// nothing. Which of the two lands first therefore no longer matters.
////
//// It never acks the member, never publishes an event and never writes a
//// document. Everything it knows leaves through the reply, and the
//// dispatcher does the rest: that is what keeps one caller's state in one
//// place while the ringing happens somewhere else.
////
//// The process sees the call's events because it subscribes to the account's
//// through `kazoo/events` and relays the ones for this call into its own
//// mailbox, which is the shape `kazoo/call.receive_event` reads. The agents'
//// legs are in that set from the moment they exist: each carries a call id
//// the offer gave it, and their events carry the caller as their other leg.
////
//// What the events mean is decided in `step` and `timed_out`, which are
//// functions from a state and an event to the next state and a list of
//// `Effect`s. Nothing in them touches the switch or the dispatcher; the
//// process performs the effects afterwards. That is what makes the order of
//// an answer -- the channel variables, the recording, the reply, and the
//// `Ended` that follows -- something a test can read.
////
//// **Naming the agent.** With several phones ringing, the bridge event
//// belongs to the caller and says only which channel answered, not whose it
//// is. So every endpoint is given its leg's call id before it rings --
//// `Outbound-Call-ID`, which the switch takes as the leg's `origination_uuid`
//// -- and the offer keeps which agent each id belongs to: the bridge's
//// `Other-Leg-Call-ID` names the agent the moment it arrives.
////
//// A leg the offer did not name -- a device that forwarded somewhere and
//// bridged through a channel of its own -- is named by its own events, as the
//// `Agent-ID` its endpoint was marked with, and the two can come in either
//// order. Such an answer is held for up to `identify_wait_ms` while the offer
//// keeps reading events, and goes out complete the moment the agent's leg
//// says who answered -- with the timestamp of the original answer, not of
//// the identification.
////
//// If that wait runs out, or the call ends inside it, the answer goes out
//// all the same, naming `unknown`. It is not reported as a failure: the
//// caller is through to somebody and talking to them, and a `Failed` after a
//// bridge leaves the dispatcher with a caller it still believes is waiting,
//// whose member message was never settled and who is offered again while the
//// conversation is going on -- with nothing left to hang either leg up. An
//// `unknown` answer instead keeps the call up, settles the member, and puts
//// a name in the CDR and on the agent's status that says exactly what was
//// not known. The log line that goes with it names the queue, the call, the
//// answering leg and every agent rung, which is how the missing `Agent-ID`
//// is chased down afterwards.
////
//// It is not free: the dispatcher frees every agent who is not named on the
//// answer, so the one who is really on the call goes available again with no
//// answered count, no talk time and no wrapup, and the queue shows an offer
//// connected to `unknown` until the call ends. That is the price of never
//// stranding a caller who is already talking to somebody.
////
//// **A ring called off.** The dispatcher calls a ring off when the caller
//// leaves the queue, the agent is released or the queue is deleted, and the
//// unbridge that goes with it parks the caller wherever the ring has got to.
//// An agent answering a moment before it lands is not an answer: the park
//// cuts the bridge. So from the moment the offer hears the call-off no answer
//// is reported, and one it had already reported is taken back (`overtaken`);
//// it never hangs the caller up after a call-off, and the caller is left to
//// their callflow or to the dispatcher.

import callcenter/recording
import callcenter/system
import callcenter/types.{
  type Member, type OfferId, type OfferReply, type OfferRequest,
  type OfferSettings,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/call.{type Call}
import kazoo/doc.{type Value}
import kazoo/endpoints
import kazoo/events
import kazoo/kazoo
import kazoo/modb

/// How much longer than the ring timeout the offer waits for the switch to
/// say something before it gives up on its own.
///
/// The same `offer_grace_s` the dispatcher's ceiling is built from, read
/// here so that the two deadlines are one number: the offer answers for
/// itself first and the ceiling is only ever the backstop for an offer that
/// is not there any more.
fn grace_s() -> Int {
  system.live().config.get_int("offer_grace_s", 5)
}

/// How long a bridged call may run before the offer stops watching it. Long
/// enough that no real call reaches it; short enough that a process whose
/// events stopped arriving does not sit there for ever.
const longest_call_ms = 14_400_000

/// How long an answer waits for the agent's leg to say whose it is.
///
/// The two events are the caller's bridge and the agent leg's own, and they
/// race: the leg is already up when the bridge happens, so its event is at
/// most a switch's round trip behind. Long enough to cover that, short
/// enough that nobody is left watching a live call for a name.
///
/// This and the other short waits below are counted on the VM's monotonic
/// clock in milliseconds (`monotonic_ms`), from the moment of the event that
/// started them. The seconds the offer reports -- when the caller was
/// answered, when the call ended -- are the calendar's (`modb.now`), which
/// is what the records and the CDR hold. A wait counted in whole calendar
/// seconds was anything from nothing to a second short: a transfer's wait
/// begun at 12.9 s ran out at the first event after 13.0 s.
const identify_wait_ms = 2000

/// How long a ring that the switch says the originator cancelled waits for
/// the caller's channel to go.
///
/// `ORIGINATOR_CANCEL` is what the caller's bridge ends with both when the
/// caller hung up -- the destroy follows within milliseconds -- and when the
/// callflow action called the ring off because the caller is leaving the
/// queue another way. The first is the caller leaving; the second has
/// already been told to the dispatcher by the action's `member_cancel`.
/// Neither is an agent's miss.
pub const cancel_wait_ms = 2000

/// How long the end of an answered bridge waits to see whether it was a
/// transfer before the caller is hung up.
///
/// An agent passing the caller on from their phone ends the bridge too: the
/// caller is unbridged and the agent's leg goes. The switch fires its
/// transfer events before it moves the caller, but they are published for
/// other channels and can reach the offer a moment after the unbridge, so
/// the offer waits this long for one before deciding the call is simply
/// over. The caller of an agent who just hung up hears this much silence
/// more before they are hung up themselves.
pub const transfer_wait_ms = 1000

/// The agent on an answer nobody could name.
///
/// It is a name and not an empty string on purpose: `kz_api` strips empty
/// values, so an empty `Agent-ID` makes the `agent_answered` event fail
/// validation and disappear, and leaves the caller's own CCV and the CDR with
/// no agent at all. This says the same thing out loud, and everything
/// downstream keeps working.
pub const unknown_agent = "unknown"

/// One offer as it runs: an `OfferRequest` without the member's delivery,
/// which stays with the dispatcher.
///
/// It exists so the ringing can be started from something that is not a
/// delivery -- a maintenance command, a node check -- without a second
/// version of what an offer does.
pub type Ring {
  Ring(
    account_id: String,
    queue_id: String,
    call_id: String,
    call: Value,
    agents: List(String),
    settings: OfferSettings,
    /// The offer this is, which every reply names: the dispatcher's own
    /// `OfferRequest.id`, whose call id is `call_id`.
    id: OfferId,
    reply_to: Subject(#(OfferId, OfferReply)),
    /// The devices to ring instead of every device each agent owns: the
    /// request's own `devices`, which only a supervisor's pickup names.
    devices: Option(List(String)),
  )
}

/// Ring the agents in `request` for its member.
///
/// The process is not linked to the dispatcher that asked for it. An offer
/// lives for the whole of the conversation it connects, and a link would
/// make one offer's crash the end of the dispatcher and, through the shard,
/// of every other offer in flight -- whose bridges would ring on with nobody
/// listening. The dispatcher monitors it instead, and an offer that ends
/// without its last word is one it closes itself
/// (`callcenter/dispatcher/offers.down`). The other way round, the offer
/// watches its dispatcher (`guard_dispatcher`) and, if the dispatcher goes
/// first, ends without touching the call, which is then the business of
/// whoever takes the caller over.
pub fn start(request: OfferRequest) -> Result(Pid, String) {
  start_ring(of_request(request))
}

/// The offer a dispatcher's request is.
pub fn of_request(request: OfferRequest) -> Ring {
  Ring(
    account_id: request.member.account_id,
    queue_id: request.member.queue_id,
    call_id: request.member.call_id,
    call: request.member.call,
    agents: request.agents,
    settings: request.settings,
    id: request.id,
    reply_to: request.reply_to,
    devices: request.devices,
  )
}

/// The same, from an offer built by hand.
pub fn start_ring(ring: Ring) -> Result(Pid, String) {
  case ring.agents, control_queue(ring.call) {
    [], _ -> Error("no_agents")
    _, None -> Error("no_control_queue")
    _, Some(_queue) -> Ok(process.spawn_unlinked(fn() { run(ring) }))
  }
}

fn control_queue(call: Value) -> Option(String) {
  case doc.get_string(call, ["Control-Queue"]) {
    Ok("") -> None
    Ok(queue) -> Some(queue)
    Error(Nil) -> None
  }
}

//
// --- What the offer does ---------------------------------------------------
//

/// What the offer knows about its call, between one event and the next.
pub type State {
  State(
    /// The agent leg, once the caller is bridged to it.
    bridged_to: Option(String),
    /// Which agent that leg belongs to, learned from the leg's own channel
    /// variables as soon as one of its events arrives.
    agent_id: Option(String),
    /// Whether `Answered` has gone to the dispatcher.
    answered: Bool,
    /// An answer that has happened and has not been sent, because nothing
    /// has named the agent yet.
    pending: Option(Pending),
    /// The ring was cancelled from the caller's side, and the offer is
    /// waiting until then -- a monotonic millisecond -- to see the caller's
    /// channel go.
    cancelled: Option(Int),
    /// The answered bridge has ended, and the offer is waiting a moment to
    /// see whether it was a transfer.
    closing: Option(Closing),
    /// Whether any leg this offer rang has been seen: an event from a
    /// channel that is not the caller's and carries one of the agents'
    /// `Agent-ID`, or is one of `legs`. A ring that runs out without one rang
    /// nobody.
    rang: Bool,
    /// The call id each endpoint was given, and the agent it rings.
    legs: Dict(String, String),
    /// The dispatcher called the ring off before any leg of it was seen,
    /// and from this monotonic millisecond a leg still ringing means the
    /// unbridge missed the bridge: see `recall_ms`.
    recall: Option(Int),
    /// The dispatcher called the ring off. From then on no bridge of the
    /// caller's is an answer: one to a leg this offer did not name is the
    /// caller gone on to whatever their callflow does next, and one to a leg
    /// it did name is about to be cut by the unbridge (`overtaken`).
    called_off: Bool,
    /// The second the caller's channel was marked with the answer, and the
    /// queue's recording of it started when the queue records: what a
    /// call-off that overtook the answer takes back.
    marked: Option(Int),
  )
}

/// The end of an answered bridge that may yet turn out to be a transfer:
/// what it is if it does not, when it happened (a calendar second), and
/// until when the offer waits to find out (a monotonic millisecond).
pub type Closing {
  Closing(result: types.EndResult, at: Int, until: Int)
}

/// An answer waiting for a name: the leg that took the caller, when it took
/// them (a calendar second), and until when the offer will wait to find out
/// whose leg it is (a monotonic millisecond).
pub type Pending {
  Pending(agent_call_id: String, at: Int, until: Int)
}

/// The offer before anything has happened.
pub fn beginning() -> State {
  State(
    bridged_to: None,
    agent_id: None,
    answered: False,
    pending: None,
    cancelled: None,
    closing: None,
    rang: False,
    legs: dict.new(),
    recall: None,
    called_off: False,
    marked: None,
  )
}

/// The offer as its bridge goes out: the legs it gave its endpoints, and
/// whose each one is.
pub fn ringing(legs: Dict(String, String)) -> State {
  State(..beginning(), legs: legs)
}

fn run(ring: Ring) -> Nil {
  case guard_dispatcher(ring.reply_to) {
    // Its dispatcher went before it began: nothing is rung for a caller
    // whoever takes over will offer afresh.
    False -> Nil
    True -> run_guarded(ring)
  }
}

fn run_guarded(ring: Ring) -> Nil {
  // Sourced here as well as in `ringable`: this is the call the bridge
  // command is built from, and `kapps_call` puts the routing context on it.
  // Without it the command goes out flagged `direct_call`, which is not what
  // a caller sitting in a queue is.
  let caller = call.from_value(ring.call) |> sourced
  let prefix = leg_prefix(ring.id)
  case watch(ring, prefix) {
    // Without the call's events the offer cannot tell an answer from a ring
    // that ran out, and would report whichever it guessed at the end of the
    // ring timeout. Nothing is rung: the dispatcher hears a failure at once,
    // which is not a miss.
    None -> reply(ring, types.Failed(no_events))
    Some(watching) -> {
      ring_with(ring, caller, prefix)
      unwatch(watching)
    }
  }
}

fn ring_with(ring: Ring, caller: Call, prefix: String) -> Nil {
  case ringable(ring, prefix) {
    [] -> {
      system.log(
        "offer for call " <> ring.call_id <> ": nobody has an endpoint to ring",
      )
      reply(ring, types.Failed("no_endpoints"))
    }
    endpoints ->
      // Called off while it was being set up -- the caller left, the agent
      // was released, the queue went -- and a bridge sent now would ring
      // into whatever the caller's callflow does next.
      case called_off_pending() {
        True -> {
          system.log(
            "offer for call "
            <> ring.call_id
            <> " was called off before its bridge went out",
          )
          reply(ring, types.Failed(called_off))
        }
        False -> bridge(ring, caller, endpoints)
      }
  }
}

fn bridge(ring: Ring, caller: Call, endpoints: List(Value)) -> Nil {
  case
    call.bridge_interrupting(
      caller,
      endpoints,
      ring.settings.ring_timeout_s,
      strategy(endpoints),
      ringback(ring.settings),
    )
  {
    Error(reason) -> {
      system.log_error(
        "offer for call "
        <> ring.call_id
        <> " could not send its bridge: "
        <> reason,
      )
      reply(ring, types.Failed(bridge_not_sent))
    }
    Ok(Nil) -> {
      reply(ring, types.OfferRinging(ring.agents))
      waiting(
        ring,
        caller,
        ringing(legs_of(endpoints)),
        monotonic_ms() + { ring.settings.ring_timeout_s + grace_s() } * 1000,
      )
    }
  }
}

/// The failure an offer called off before its bridge went out reports. The
/// dispatcher, which called it off, reads it as no miss.
pub const called_off = "called_off"

/// Whether the dispatcher's call-off (`called_off_event`) is waiting in this
/// process's mailbox, which is left as it was: the loop that reads the
/// call's events reads it again once the bridge is out.
fn called_off_pending() -> Bool {
  mailbox_has_event(called_off_name)
}

@external(erlang, "callcenter_ffi", "mailbox_has_event")
fn mailbox_has_event(event_name: String) -> Bool

/// The failure an offer that could not watch its call's events reports.
pub const no_events = "no_events"

/// The failure an offer whose bridge command did not go out reports.
pub const bridge_not_sent = "bridge_not_sent"

/// The failure an offer reports when its ring ran out and none of the legs
/// it rang was ever seen.
pub const nothing_rang = "nothing_rang"

/// What this application calls itself to `kz_endpoint` and to `kapps_call`.
///
/// Two rules read it and both say the same thing about a queue call: it is
/// not a direct call. A device whose call forward is `direct_calls_only`
/// therefore does not forward one, which is right -- the queue picked this
/// agent because they are here, and a caller who is queued should not be
/// sent to somebody's mobile because their desk phone is on forward.
const source = "callcenter"

/// The key `kapps_call` keeps the name of whatever is placing the call
/// under. `cf_exe` sets it to the callflow module; the offer sets it here
/// because the call it rings from was rebuilt out of a member message and
/// has been through no `cf_exe`.
const source_key = "context-source"

/// All the endpoints of all the agents, each marked with whose it is.
///
/// An agent whose devices cannot be built is left out rather than failing
/// the offer: with a simultaneous ring the others should still ring, and the
/// dispatcher hears about the miss either way.
fn ringable(ring: Ring, prefix: String) -> List(Value) {
  let ringing =
    prefixed(ring.call, ring.settings.cid_prefix)
    |> call.from_value
    |> sourced
  let account_db = kazoo.account_db(ring.account_id)
  list.flat_map(ring.agents, fn(agent_id) {
    case ring.devices {
      None ->
        endpoints.build_for_owned_devices(
          ringing,
          account_db,
          agent_id,
          properties(),
        )
      // A supervisor's pickup: the phones they named, built one device at a
      // time as an agent's are, and a device that will not build left out.
      Some(device_ids) ->
        list.flat_map(device_ids, fn(device_id) {
          case endpoints.build_with(ringing, device_id, properties()) {
            Ok(built) -> built
            Error(_reason) -> []
          }
        })
    }
    |> list.map(decorate(_, agent_id, ring.settings))
  })
  |> named_legs(prefix)
}

/// Give every endpoint the call id its leg will have: the prefix and its
/// place in the ring.
///
/// `Outbound-Call-ID`, which `ecallmgr` passes to the switch as the leg's
/// `origination_uuid`. The prefix is the offer's own, fresh for every offer,
/// so no two legs anywhere share one and the offer can pick its legs' events
/// out of the account's before any of them names the caller.
pub fn named_legs(endpoints: List(Value), prefix: String) -> List(Value) {
  list.index_map(endpoints, fn(endpoint, index) {
    doc.set(
      endpoint,
      ["Outbound-Call-ID"],
      doc.String(prefix <> "-" <> int.to_string(index + 1)),
    )
  })
}

/// Which agent each named leg rings, read back off the endpoints.
pub fn legs_of(endpoints: List(Value)) -> Dict(String, String) {
  list.fold(endpoints, dict.new(), fn(legs, endpoint) {
    case
      doc.get_string(endpoint, ["Outbound-Call-ID"]),
      doc.get_string(endpoint, ["Custom-Channel-Vars", "Agent-ID"])
    {
      Ok(leg), Ok(agent_id) -> dict.insert(legs, leg, agent_id)
      _, _ -> legs
    }
  })
}

/// The part every call id this offer gives its legs starts with: a function
/// of the offer's own reference, so fresh for every offer, and one the
/// dispatcher can write on the caller's record for a takeover to read
/// (`records.offered`). A leg bridged to the caller whose id does not start
/// with it is not one of this offer's.
pub fn leg_prefix(id: OfferId) -> String {
  prefix_of(id.serial)
}

@external(erlang, "callcenter_ffi", "leg_prefix")
fn prefix_of(serial: Reference) -> String

/// The call as the thing placing it: a queue, not a person dialling.
///
/// `kapps_call` reads this key to decide the routing context, and every
/// name in `non_direct_modules` -- of which `callcenter` is one -- makes the
/// call a `non_direct_call`. A call rebuilt from a member message has been
/// through no `cf_exe`, so nothing has said it yet.
pub fn sourced(call: Call) -> Call {
  call.kvs_store(call, source_key, doc.String(source))
}

/// What `kz_endpoint:build/3` is told about the call it is building for.
///
/// Only `source`, and only so that a device forwarding on
/// `direct_calls_only` refuses a queue call the way it refuses a ring
/// group's. Everything else about the endpoint is the device's own.
pub fn properties() -> Value {
  doc.object([#("source", doc.String(source))])
}

/// What the caller hears while the phones ring: the hold music they were
/// already hearing, which is the queue's own when it has one and the
/// account's otherwise -- the same choice the callflow action makes when it
/// holds them. Never a ringback tone: a caller who has been listening to
/// music for a minute and suddenly hears ringing believes the queue has
/// given up on them, and one who hears it stop hears silence.
pub fn ringback(settings: OfferSettings) -> call.Ringback {
  case settings.hold_media {
    None -> call.HoldMusic
    Some("") -> call.HoldMusic
    Some(media) -> call.Music(media)
  }
}

/// Every endpoint rings at once, whether they are one agent's desk phone and
/// softphone or several agents' phones: the offer is one ring, bounded by one
/// timeout. A lone endpoint rings alone. `single` and `simultaneous` are the
/// switch's own words for it.
///
/// It is decided by the endpoints and not by the agents. `ecallmgr` turns
/// `single` into the `|` failover separator, so an agent with two devices
/// rung `single` had the first for the whole ring timeout and the second
/// never.
pub fn strategy(endpoints: List(Value)) -> call.Strategy {
  case endpoints {
    [_one] -> call.Single
    _many -> call.Simultaneous
  }
}

//
// --- The events ------------------------------------------------------------
//

/// The offer's loop. `deadline` is a monotonic millisecond: see
/// `identify_wait_ms`.
fn waiting(ring: Ring, caller: Call, state: State, deadline: Int) -> Nil {
  let until = deadline_for(state, deadline, monotonic_ms())
  let #(caller, move) = case
    call.receive_event(remaining_ms(until, monotonic_ms()))
  {
    Error(call.Timeout) -> #(
      caller,
      silence(ring, state, deadline, modb.now(), monotonic_ms()),
    )
    Ok(event) -> #(
      caller_now(caller, event),
      step_at(ring, state, event, modb.now(), monotonic_ms()),
    )
  }
  list.each(move.effects, perform(ring, caller, _))
  case move.over {
    True -> Nil
    // The ring's own deadline is carried as it was set: every shorter wait
    // is worked out from the state again (`deadline_for`).
    False -> waiting(ring, caller, move.state, deadline)
  }
}

/// The VM's monotonic clock, in milliseconds: what the short waits count on.
@external(erlang, "callcenter_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int

/// What one event, or one silence, does to an offer: where it leaves it, what
/// the process has to do about it, and whether there is anything left to wait
/// for.
pub type Move {
  Move(state: State, effects: List(Effect), over: Bool)
}

/// One thing an offer does to the world. Deciding them and doing them are
/// kept apart so that the order they happen in can be read off a test.
pub type Effect {
  /// Mark the caller's channel with who took them and when.
  Attribute(agent_id: String, at: Int)
  /// Start the queue's recording on the caller's channel, named for the
  /// agent who answered and the second they did. See `callcenter/recording`.
  Record(agent_id: String, at: Int)
  /// Take `Attribute` back: the caller's channel says nobody answered.
  Unmark
  /// Stop the recording `Record` started for the answer at `at`.
  StopRecording(at: Int)
  /// Hang the caller up.
  HangUp
  /// Call the ring off on the caller's channel, as the dispatcher does
  /// (`kazoo/call.unbridge`): the dispatcher left that to the offer, or its
  /// unbridge missed the bridge.
  Unbridge
  /// Tell the dispatcher.
  Tell(reply: OfferReply)
  /// Say in the log what an operator has to know about.
  Complain(message: String)
}

fn perform(ring: Ring, caller: Call, effect: Effect) -> Nil {
  case effect {
    Attribute(agent_id, at) ->
      call.set_channel_vars(
        caller,
        [
          #("Agent-ID", doc.String(agent_id)),
          #("Queue-Answered-Timestamp", doc.Int(at)),
        ],
        [],
      )
    Record(agent_id, at) ->
      recording.start(
        caller,
        ring.account_id,
        ring.queue_id,
        ring.call_id,
        agent_id,
        at,
      )
    Unmark -> call.set_channel_vars(caller, unmarked, [])
    StopRecording(at) ->
      recording.stop(caller, ring.account_id, ring.queue_id, ring.call_id, at)
    HangUp -> call.hangup(caller)
    Unbridge -> {
      system.log(
        "offer for call "
        <> ring.call_id
        <> ": its ring was called off and is still going; unbridging it",
      )
      call.unbridge(caller)
    }
    Tell(told) -> reply(ring, told)
    Complain(message) -> system.log_error(message)
  }
}

/// What `Unmark` writes: the values the callflow action sets as a caller
/// joins, which say nobody has answered this passage.
pub const unmarked = [
  #("Agent-ID", doc.String("")),
  #("Queue-Answered-Timestamp", doc.String("")),
]

fn going(state: State) -> Move {
  Move(state: state, effects: [], over: False)
}

fn over(state: State, effects: List(Effect)) -> Move {
  Move(state: state, effects: effects, over: True)
}

/// Until when the offer waits for the next event, from a moment: both
/// monotonic milliseconds.
///
/// The ring timeout stops applying the moment the caller is bridged: from
/// then on the only limit is how long a call may run. An answer waiting for
/// a name has its own, much shorter, deadline in between.
pub fn deadline_for(state: State, deadline: Int, now_ms: Int) -> Int {
  case state.answered, state.pending, state.cancelled {
    True, _, _ ->
      case state.closing {
        Some(closing) -> closing.until
        None -> now_ms + longest_call_ms
      }
    False, Some(pending), _ -> pending.until
    False, None, Some(until) -> until
    False, None, None ->
      case state.recall {
        Some(at) if at > now_ms -> int.min(at, deadline)
        _ -> deadline
      }
  }
}

/// A deadline as the timeout of one receive, never negative: both in
/// monotonic milliseconds, so that a wait of one second is a second
/// whenever it began.
pub fn remaining_ms(deadline: Int, now_ms: Int) -> Int {
  int.max(deadline - now_ms, 0)
}

/// What an event that came from the agent's leg says about whose leg it is.
fn learn(state: State, ring: Ring, event: Value) -> State {
  case events.call_id(event) {
    Some(call_id) if call_id != ring.call_id -> {
      let agent =
        option.or(
          option.from_result(dict.get(state.legs, call_id)),
          agent_of(event, ring.agents),
        )
      let state = State(..state, rang: state.rang || option.is_some(agent))
      case answering_leg(state, call_id), agent {
        True, Some(agent_id) ->
          State(..state, agent_id: Some(agent_id), bridged_to: Some(call_id))
        _, _ -> state
      }
    }
    _ -> state
  }
}

/// Whether a leg is one that can name the answer.
///
/// Before the bridge any leg the offer rang can: the one that answers is the
/// one whose events arrive. Once the caller is through to a particular leg,
/// only that leg can -- every other phone was rung carrying an `Agent-ID`
/// too, and the cancellation of a phone that lost the race arrives with that
/// name on it, which is not who took the call. A bridge that named no leg at
/// all has nothing better to go on and keeps the first rule.
fn answering_leg(state: State, call_id: String) -> Bool {
  case state.pending {
    None -> True
    Some(pending) ->
      case pending.agent_call_id {
        "" -> True
        answering -> answering == call_id
      }
  }
}

/// What one event does to an offer, at `now` on the calendar and `now_ms`
/// on the monotonic clock: the first dates what the offer reports, the
/// second times the waits it starts.
///
/// Three things in order: what the event says about whose leg it came from,
/// whether it settles an answer that was waiting for a name, and what it
/// means for the call.
pub fn step_at(
  ring: Ring,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  case is_dispatcher_gone(event), is_called_off(event) {
    True, _ -> orphaned(ring, state)
    False, True -> heard_called_off(ring, state, event, now_ms)
    False, False -> {
      let state = learn(state, ring, event)
      let #(state, settled) = settling(ring, state, event)
      let move = acted(ring, state, event, now, now_ms)
      Move(..move, effects: list.append(settled, move.effects))
      |> recalled(now_ms)
    }
  }
}

/// Nothing was heard until the loop's deadline: the recall's, or whatever
/// `timed_out` answers for. `deadline` is the ring's own.
pub fn silence(
  ring: Ring,
  state: State,
  deadline: Int,
  now: Int,
  now_ms: Int,
) -> Move {
  case recall_due(state, now_ms) && now_ms < deadline {
    True ->
      case state.rang {
        True -> recall(state, [])
        // Nothing of the ring seen yet: the first leg that is, is (`recalled`).
        False -> going(state)
      }
    False -> timed_out(ring, state, now)
  }
}

/// `step_at` on a clock whose milliseconds are its seconds', for a reading
/// that only cares about the seconds.
pub fn step(ring: Ring, state: State, event: Value, now: Int) -> Move {
  step_at(ring, state, event, now, now * 1000)
}

/// The dispatcher that asked for this offer has gone, and the offer goes
/// with it, touching nothing: no hang-up, no call-off, no reply.
///
/// Whoever takes the caller over reads their record and, for a ring still in
/// its time or a call already answered, watches the call with a takeover of
/// its own (`callcenter/dispatcher/arrival`). An offer that went on acting
/// would do it twice: two hang-ups at the end of the bridge, or a reply into
/// a dispatcher that is not there. The bridge on the switch carries on as it
/// was, and the takeover owns it from here.
fn orphaned(ring: Ring, state: State) -> Move {
  over(state, [
    Complain(
      "offer for call "
      <> ring.call_id
      <> ": the dispatcher that asked for it has gone; leaving the call to "
      <> "whoever takes the caller over",
    ),
  ])
}

//
// --- A ring called off -----------------------------------------------------
//

/// What the dispatcher tells an offer whose ring it has called off: the
/// caller left, the agent was released, the queue went. An event in the
/// call's own mailbox, as `dispatcher_gone` is, so that the loop reading the
/// call's events reads it too.
const called_off_name = "callcenter_offer_called_off"

/// The event itself. `unbridged` says whether the dispatcher unbridges the
/// ring -- now, or when the offer says it is out -- or leaves that to the
/// offer.
pub fn called_off_event(unbridged unbridged: Bool) -> Value {
  called_off_through(unbridged: unbridged, control_queue: None)
}

/// The same, naming the control queue of the caller's callflow now, which
/// is where an unbridge of the offer's own goes from then on (`caller_now`).
pub fn called_off_through(
  unbridged unbridged: Bool,
  control_queue control_queue: Option(String),
) -> Value {
  doc.object_some([
    #("Event-Category", Some(doc.String(system.category))),
    #("Event-Name", Some(doc.String(called_off_name))),
    #("Unbridged", Some(doc.Bool(unbridged))),
    #("Control-Queue", option.map(control_queue, doc.String)),
  ])
}

/// The caller as the offer sends commands to it after `event`: on the
/// control queue a call-off names, when it names one.
///
/// The offer was started with the caller's call as the dispatcher held it
/// then, and a command goes to the `Control-Queue` in it. A callflow run
/// again while the phones rang (plan 4.4) has a new one, and the old one
/// is gone with the callflow that died: an unbridge sent there reaches
/// nobody and the ring goes on. The dispatcher sends its own unbridges
/// through the caller it holds now (`offers.unbridge`), and a call-off
/// hands the offer the control queue that caller names, for the unbridge
/// the offer sends itself -- when the call-off leaves it to the offer, or
/// when the dispatcher's missed the bridge (`recall_ms`).
pub fn caller_now(caller: Call, event: Value) -> Call {
  case is_called_off(event), doc.get_string(event, ["Control-Queue"]) {
    True, Ok(queue) if queue != "" -> call.set_control_queue(caller, queue)
    _, _ -> caller
  }
}

/// Whether an event is the dispatcher calling the ring off.
pub fn is_called_off(event: Value) -> Bool {
  doc.get_string(event, ["Event-Category"]) == Ok(system.category)
  && events.event_name(event) == Some(called_off_name)
}

/// Tell a running offer its ring has been called off: before its bridge is
/// out it sends none (`ring_with`), and after, it unbridges the ring itself
/// unless the dispatcher does, and checks that the unbridge took
/// (`recall_ms`).
///
/// `member` is the caller as the dispatcher holds them now, whose call names
/// the control queue that unbridge goes to (`caller_now`).
pub fn call_off(offer: Pid, unbridged: Bool, member: Member) -> Nil {
  call.relay_event(
    to: offer,
    event: called_off_through(
      unbridged: unbridged,
      control_queue: control_queue(member.call),
    ),
  )
}

/// How long after a call-off the offer gives the dispatcher's unbridge to
/// end a ring none of whose legs had been seen when it was called off.
///
/// The unbridge parks the caller's channel, which ends a bridge that is
/// running. A bridge that is sent and not yet running -- `ecallmgr` runs the
/// offer's flushing bridge on its next turn, and the unbridge goes out with
/// `Insert-At: now` -- is not ended by it: the park lands on a channel with
/// no bridge, and then the bridge runs and the agents' phones ring for a
/// caller who has left. The legs are the offer's own and it sees them from
/// their `CHANNEL_CREATE` on; a leg still ringing this long after the
/// call-off, with the bridge not ended, is a ring the unbridge missed, and
/// the offer unbridges it once more. A ring whose legs were already seen
/// was running when it was called off, and is left to the dispatcher's
/// unbridge.
pub const recall_ms = 1000

/// The dispatcher's call-off, read once the bridge is out. A ring that has
/// already ended has nothing to call off; one still ringing is unbridged,
/// by the offer when the dispatcher leaves that to it; and one already
/// answered is `overtaken`.
fn heard_called_off(
  ring: Ring,
  state: State,
  event: Value,
  now_ms: Int,
) -> Move {
  let ours = doc.get_bool(event, ["Unbridged"]) == Ok(False)
  case state.answered || option.is_some(state.pending) {
    True -> overtaken(ring, state, unbridge: ours)
    False -> {
      let ringing = option.is_none(state.cancelled)
      let unbridge = case ringing && ours {
        True -> [Unbridge]
        False -> []
      }
      let recall = case ringing, state.rang, state.recall {
        True, False, None -> Some(now_ms + recall_ms)
        _, _, recall -> recall
      }
      Move(
        state: State(..state, recall: recall, called_off: True),
        effects: unbridge,
        over: False,
      )
    }
  }
}

/// A call-off that found the ring answered: the caller bridged to one of the
/// agents a moment before the unbridge reached their channel.
///
/// The call-off wins. The unbridge that goes with it -- the dispatcher's, or
/// the caller's own action's on the way out of the queue -- is already on
/// its way, and it parks the caller in the middle of the conversation. The
/// bridge ends and the switch hangs the agent's leg up behind it: a leg a
/// bridge originated is hung up with `NORMAL_CLEARING` when its bridge ends,
/// unless that leg was itself parked or transferred, and the park is the
/// caller's. The caller is left to whoever has them now: the action carrying
/// on with its callflow, or the dispatcher, which still has them waiting and
/// offers them again. An answer that stood was reported, recorded and then
/// read as a completed call at the park, and the offer hung up a caller who
/// had moved on.
///
/// So nothing more is done for the answer. Whatever the offer did to the
/// caller's channel for it is taken back -- the `Agent-ID` and the second,
/// and the recording, which would otherwise run through the rest of their
/// call -- and the offer ends with `Failed(called_off)`, which the
/// dispatcher, having called the ring off, reads as nobody's miss and which
/// is its word on an `Answered` it has not taken (`offers.replied`). An
/// answer still waiting for a name was never reported and goes the same way.
/// When the call-off left the unbridge to the offer, the offer sends it: an
/// answered bridge nobody ends is a caller talking to an agent the queue has
/// let go, while their callflow goes on.
fn overtaken(ring: Ring, state: State, unbridge unbridge: Bool) -> Move {
  let unbridge = case unbridge && option.is_none(state.closing) {
    True -> [Unbridge]
    False -> []
  }
  let taken_back = case state.marked, ring.settings.record {
    None, _ -> []
    Some(_at), False -> [Unmark]
    Some(at), True -> [Unmark, StopRecording(at)]
  }
  over(
    State(..state, called_off: True),
    list.flatten([
      unbridge,
      taken_back,
      [
        Complain(
          "offer for call "
          <> ring.call_id
          <> ": its ring was called off as leg "
          <> option.unwrap(state.bridged_to, "?")
          <> " answered; the call-off stands and the answer does not",
        ),
        Tell(types.Failed(called_off)),
      ],
    ]),
  )
}

/// Whether the check on a call-off has come round, with the ring neither
/// answered nor over.
fn recall_due(state: State, now_ms: Int) -> Bool {
  case state.recall, state.answered, state.pending, state.cancelled {
    Some(at), False, None, None -> at <= now_ms
    _, _, _, _ -> False
  }
}

/// After an event: a leg of a ring that was called off before it was seen,
/// still ringing once the check has come round.
fn recalled(move: Move, now_ms: Int) -> Move {
  case move.over, recall_due(move.state, now_ms) && move.state.rang {
    False, True -> recall(move.state, move.effects)
    _, _ -> move
  }
}

fn recall(state: State, effects: List(Effect)) -> Move {
  Move(
    state: State(..state, recall: None),
    effects: list.append(effects, [Unbridge]),
    over: False,
  )
}

//
// --- The dispatcher behind the offer ---------------------------------------
//

/// What an offer's process is told when its dispatcher has gone: an event,
/// in the call's own mailbox, because that mailbox is read by
/// `kazoo/call.receive_event`, which passes over everything that is not one.
/// A monitor's `Down` would be read and thrown away there.
const dispatcher_gone = "callcenter_dispatcher_gone"

/// The event itself.
pub fn dispatcher_gone_event() -> Value {
  doc.object([
    #("Event-Category", doc.String(system.category)),
    #("Event-Name", doc.String(dispatcher_gone)),
  ])
}

/// Whether an event is the one that says the dispatcher has gone.
pub fn is_dispatcher_gone(event: Value) -> Bool {
  doc.get_string(event, ["Event-Category"]) == Ok(system.category)
  && events.event_name(event) == Some(dispatcher_gone)
}

/// Watch the dispatcher behind `reply_to` on behalf of the calling process --
/// an offer's, or a takeover's -- and put `dispatcher_gone_event` in its
/// mailbox if the dispatcher goes first. `False` when the dispatcher has
/// already gone, and the caller should do nothing at all; the event is in
/// its mailbox all the same, for a caller that reads it rather than asks.
///
/// The offer is not linked to its dispatcher, so that its crash is not the
/// dispatcher's; this is the other half, so that the dispatcher's end is the
/// offer's. A subject nobody owns has no dispatcher to watch, and the offer
/// runs unguarded, as it always did.
pub fn guard_dispatcher(reply_to: Subject(reply)) -> Bool {
  case process.subject_owner(reply_to) {
    Error(Nil) -> True
    Ok(dispatcher) -> {
      let me = process.self()
      let tell = fn() {
        call.relay_event(to: me, event: dispatcher_gone_event())
      }
      case process.is_alive(dispatcher) {
        False -> {
          tell()
          False
        }
        True -> {
          let _guard = guard(dispatcher, me, tell)
          True
        }
      }
    }
  }
}

/// A process of its own that monitors both `dispatcher` and `offer`, calls
/// `tell` if the dispatcher goes first, and ends when either does. Not
/// linked to either, and never outliving the offer.
pub fn guard(dispatcher: Pid, offer: Pid, tell: fn() -> Nil) -> Pid {
  process.spawn_unlinked(fn() {
    let on_dispatcher = process.monitor(dispatcher)
    let on_offer = process.monitor(offer)
    let dispatcher_went =
      process.new_selector()
      |> process.select_specific_monitor(on_dispatcher, fn(_down) { True })
      |> process.select_specific_monitor(on_offer, fn(_down) { False })
      |> process.selector_receive_forever
    case dispatcher_went {
      True -> tell()
      False -> Nil
    }
  })
}

/// An answer held for want of a name goes out as soon as the agent's leg
/// gives one -- and goes out anyway, named `unknown`, if the call is ending
/// first. Nothing else is worth reporting about a caller who is already
/// through.
fn settling(ring: Ring, state: State, event: Value) -> #(State, List(Effect)) {
  case state.pending {
    None -> #(state, [])
    Some(pending) -> {
      // An answer settled by the end of the call has no channel left to mark
      // or to record: only the dispatcher still wants to hear about it.
      let ended = ending(state, ring, event)
      let still_up = case ended {
        True -> Dead
        False -> Live
      }
      case state.agent_id, ended {
        Some(agent_id), _ ->
          settled(ring, state, pending, Some(agent_id), still_up)
        None, True -> settled(ring, state, pending, None, Dead)
        None, False -> #(state, [])
      }
    }
  }
}

/// Whether the caller's channel is still there to be commanded when the
/// answer is settled.
type Channel {
  Live
  Dead
}

/// Whether an event is the end of the bridge, or of one of its legs: after
/// it there is nothing left to learn the agent's name from.
fn ending(state: State, ring: Ring, event: Value) -> Bool {
  let leg = events.call_id(event)
  let from_caller = leg == Some(ring.call_id)
  let from_agent = option.is_some(leg) && state.bridged_to == leg
  case events.event_name(event) {
    Some("CHANNEL_DESTROY") -> from_caller || from_agent
    Some("CHANNEL_UNBRIDGE") -> from_caller
    Some("CHANNEL_EXECUTE_COMPLETE") -> from_caller && is_bridge(event)
    _ -> from_caller && is_bridge_error(event)
  }
}

fn acted(
  ring: Ring,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  case state.answered {
    True -> after_answer(ring, state, event, now, now_ms)
    False -> before_answer(ring, state, event, now, now_ms)
  }
}

fn before_answer(
  ring: Ring,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  let from_caller = events.call_id(event) == Some(ring.call_id)
  case events.event_name(event), from_caller, state.answered {
    // A second bridge for a caller who is already through is not a second
    // answer: the one being waited on keeps its leg, its second and its
    // ceiling.
    Some("CHANNEL_BRIDGE"), True, False ->
      case state.pending, state.called_off, is_own_bridge(state, event) {
        Some(_waiting), _, _ -> going(state)
        None, True, _ -> bridged_after_call_off(state, event)
        None, False, True -> answer(ring, state, event, now, now_ms)
        None, False, False -> bridged_elsewhere(state)
      }

    // The caller went before anybody took them: they have left the queue,
    // which is not an agent's miss and not a failure to ring. A failure
    // would put the agents on a delay and offer the caller who has gone to
    // somebody else in the same pass.
    Some("CHANNEL_DESTROY"), True, False ->
      over(state, [Tell(types.CallerGone)])

    Some("CHANNEL_EXECUTE_COMPLETE"), True, _ ->
      case is_bridge(event) {
        False -> going(state)
        True -> unanswered(ring, state, event, now_ms)
      }

    _, _, answered ->
      case answered, is_bridge_error(event) && from_caller {
        False, True -> unanswered(ring, state, event, now_ms)
        _, _ -> going(state)
      }
  }
}

/// What one event means once the caller is through to an agent.
///
/// The end of the bridge -- the caller unbridged, the agent's leg gone, the
/// bridge command finished -- used to hang the caller up at once, which is
/// today's `hangup_after_bridge`. An agent transferring the caller from
/// their phone produces exactly those events, and the caller being put
/// through to the transfer's target was hung up on the way. So the end
/// waits `transfer_wait_ms` for a sign that it was a transfer, and a transfer
/// ends the offer's part without touching the caller.
fn after_answer(
  ring: Ring,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  let leg = events.call_id(event)
  let from_caller = leg == Some(ring.call_id)
  let from_agent = option.is_some(leg) && leg == state.bridged_to
  case is_transfer(ring, state, event), events.event_name(event) {
    True, _ -> transferred(state, now)

    // The caller went: there is nobody left to hang up.
    False, Some("CHANNEL_DESTROY") if from_caller ->
      case state.closing {
        Some(closing) ->
          over(state, [Tell(types.Ended(closing.result, closing.at))])
        None -> over(state, [Tell(types.Ended(types.CallerHangup, now))])
      }

    False, Some("CHANNEL_DESTROY") if from_agent ->
      bridge_ended(state, types.Completed, now, now_ms)
    False, Some("CHANNEL_UNBRIDGE") if from_caller ->
      bridge_ended(state, types.Completed, now, now_ms)
    False, Some("CHANNEL_EXECUTE_COMPLETE") if from_caller ->
      case is_bridge(event) {
        True -> bridge_ended(state, ended_as(event), now, now_ms)
        False -> going(state)
      }

    // The caller bridged again, to a leg that is not the agent's, after the
    // agent's bridge ended: an attended transfer putting them through to
    // its target.
    False, Some("CHANNEL_BRIDGE") if from_caller ->
      case state.closing, events.other_leg_call_id(event) == state.bridged_to {
        Some(_closing), False -> transferred(state, now)
        _, _ -> going(state)
      }

    _, _ -> going(state)
  }
}

/// The answered bridge has ended; wait a moment to see whether it was a
/// transfer. The first end is the one that counts.
fn bridge_ended(
  state: State,
  result: types.EndResult,
  now: Int,
  now_ms: Int,
) -> Move {
  case state.closing {
    Some(_already) -> going(state)
    None -> going(State(..state, closing: Some(closing(result, now, now_ms))))
  }
}

/// The wait on an answered bridge's end, begun at `now` (a calendar second)
/// and `now_ms` (a monotonic millisecond). A takeover's watch waits the same.
pub fn closing(result: types.EndResult, now: Int, now_ms: Int) -> Closing {
  Closing(result: result, at: now, until: now_ms + transfer_wait_ms)
}

/// The agent passed the caller on. The offer's part is over, as of the
/// moment the agent's bridge ended, and the caller is left alone.
fn transferred(state: State, now: Int) -> Move {
  let at = case state.closing {
    Some(closing) -> closing.at
    None -> now
  }
  over(state, [Tell(types.Ended(types.Transferred, at))])
}

/// Whether an event says the call is being transferred.
///
/// The switch's own transfer events -- `CHANNEL_TRANSFEREE` on the channel
/// being passed on, `CHANNEL_TRANSFEROR` on the one passing it,
/// `CHANNEL_REPLACED` on a leg an attended transfer replaced -- for either
/// leg of this call, and the agent's leg going with a transfer as its cause,
/// which is how `mod_reprise` reports a leg that sent a `REFER`.
pub fn is_transfer(ring: Ring, state: State, event: Value) -> Bool {
  is_transfer_of(ring.call_id, state.bridged_to, event)
}

/// The same, for whatever watches a caller: `callcenter/takeover` too.
pub fn is_transfer_of(
  call_id: String,
  bridged_to: Option(String),
  event: Value,
) -> Bool {
  let leg = events.call_id(event)
  let from_agent = option.is_some(leg) && leg == bridged_to
  let ours =
    leg == Some(call_id)
    || from_agent
    || events.other_leg_call_id(event) == Some(call_id)
  case events.event_name(event) {
    Some("CHANNEL_TRANSFEREE")
    | Some("CHANNEL_TRANSFEROR")
    | Some("CHANNEL_REPLACED") -> ours
    Some("CHANNEL_DESTROY") -> from_agent && ended_by_transfer(event)
    _ -> False
  }
}

/// Whether a leg's end says it was transferred away.
fn ended_by_transfer(event: Value) -> Bool {
  list.any(["Hangup-Cause", "Endpoint-Disposition", "Disposition"], fn(field) {
    case doc.get_string(event, [field]) {
      Ok(cause) ->
        case string.uppercase(cause) {
          "BLIND_TRANSFER" | "ATTENDED_TRANSFER" -> True
          _ -> False
        }
      Error(Nil) -> False
    }
  })
}

/// Whether the caller's bridge is this offer's answer, for a ring that has
/// not been called off: after a call-off none is (`bridged_after_call_off`).
///
/// A leg the offer named always is. Any other leg is only while the offer's
/// own bridge is what the caller's channel is running: its ring not called
/// off and not ended. That leaves a device that forwarded and bridged the
/// caller through a channel of its own to be named the old way. Once the
/// ring has been called off or has ended, the caller bridged to a leg this
/// offer did not name has gone on to whatever their callflow does next -- an
/// operator, a ring group -- and whoever answered there is nobody this offer
/// rang: taken for its answer, the lone agent it rang was marked on the
/// caller's channel, a queue recording of the operator's call was started,
/// and the dispatcher heard an answer for that agent.
pub fn is_own_bridge(state: State, event: Value) -> Bool {
  case events.other_leg_call_id(event) {
    Some(leg) -> dict.has_key(state.legs, leg) || still_ringing_here(state)
    None -> still_ringing_here(state)
  }
}

fn still_ringing_here(state: State) -> Bool {
  !state.called_off && option.is_none(state.cancelled)
}

/// The caller bridged after the ring was called off. To a leg this offer did
/// not name, that is `bridged_elsewhere`. To one it did, the answer came too
/// late: the unbridge on its way cuts it (`overtaken`), and nothing is done
/// for it -- except when none of the ring had been seen when it was called
/// off, which is the unbridge having landed before the bridge ran
/// (`recall_ms`): nothing is on its way to end this one, and the offer
/// unbridges it itself.
fn bridged_after_call_off(state: State, event: Value) -> Move {
  let named = case events.other_leg_call_id(event) {
    Some(leg) -> dict.has_key(state.legs, leg)
    None -> False
  }
  case named, state.recall {
    True, Some(_check) ->
      over(State(..state, recall: None), [
        Unbridge,
        Tell(types.Failed(called_off)),
      ])
    _, _ -> bridged_elsewhere(state)
  }
}

/// The caller is through to somebody this offer did not ring, its own ring
/// having been called off or ended, or to one it did too late: the offer is
/// over, and nothing is done to the caller's channel.
fn bridged_elsewhere(state: State) -> Move {
  let reason = case state.cancelled {
    Some(_ended) -> originator_cancel
    None -> called_off
  }
  over(state, [Tell(types.Failed(reason))])
}

/// A ring that ended without an answer. What the switch said decides whose
/// it is, except for a cancel from the caller's side, which waits a moment to
/// see whether the caller's channel goes: the caller hanging up sends the
/// bridge's end before the destroy.
fn unanswered(ring: Ring, state: State, event: Value, now_ms: Int) -> Move {
  case miss(event) {
    Cancelled -> going(State(..state, cancelled: Some(now_ms + cancel_wait_ms)))
    missed -> over(state, [Tell(miss_reply(missed, ring.agents))])
  }
}

/// A bridge that ended cleanly after an answer is a completed call; one that
/// ended any other way dropped, which the dispatcher counts differently.
pub fn ended_as(event: Value) -> types.EndResult {
  case cause(event) {
    "SUCCESS" | "NORMAL_CLEARING" | "ANSWER" | "UNSPECIFIED" -> types.Completed
    _other -> types.FailedBridge
  }
}

/// The caller is through to somebody.
///
/// The answer is sent from here when this event or an earlier one names the
/// agent, and is held otherwise: `settling` sends it when the agent's leg
/// arrives, and `timed_out` when the wait for it runs out.
fn answer(
  ring: Ring,
  state: State,
  event: Value,
  now: Int,
  now_ms: Int,
) -> Move {
  let agent_call_id =
    option.unwrap(
      option.or(events.other_leg_call_id(event), state.bridged_to),
      "",
    )
  let pending =
    Pending(
      agent_call_id: agent_call_id,
      at: now,
      until: now_ms + identify_wait_ms,
    )
  // A leg the offer named is whose the offer says it is. Otherwise a name
  // learned from some other leg is not this answer's: a phone that was rung
  // and lost carries an `Agent-ID` of its own.
  let named = case dict.get(state.legs, agent_call_id) {
    Ok(agent_id) -> Some(agent_id)
    Error(Nil) ->
      case state.bridged_to == Some(agent_call_id) || agent_call_id == "" {
        True -> state.agent_id
        False -> None
      }
  }
  let state =
    State(
      ..state,
      agent_id: named,
      pending: Some(pending),
      bridged_to: leg(agent_call_id, state.bridged_to),
    )
  case option.or(named, answering_agent(ring.agents, event)) {
    None -> going(state)
    Some(agent_id) -> {
      let #(state, effects) =
        settled(ring, state, pending, Some(agent_id), Live)
      Move(state: state, effects: effects, over: False)
    }
  }
}

/// The answer, now that there is a name to put on it.
///
/// The timestamp is the one the bridge happened at, whenever the name turned
/// up, so that the caller's channel, the reply, the CDR and the dispatcher's
/// record all say the same second.
fn settled(
  ring: Ring,
  state: State,
  pending: Pending,
  named: Option(String),
  channel: Channel,
) -> #(State, List(Effect)) {
  let agent_call_id = case pending.agent_call_id {
    "" -> option.unwrap(state.bridged_to, "")
    known -> known
  }
  let #(agent_id, complaint) = case named {
    Some(agent_id) -> #(agent_id, [])
    None -> #(unknown_agent, [Complain(unnamed(ring, agent_call_id))])
  }
  let recording = case ring.settings.record {
    True -> [Record(agent_id, pending.at)]
    False -> []
  }
  let #(commands, marked) = case channel {
    Live -> #(
      list.append([Attribute(agent_id, pending.at)], recording),
      Some(pending.at),
    )
    Dead -> #([], state.marked)
  }
  #(
    State(
      ..state,
      bridged_to: leg(agent_call_id, state.bridged_to),
      agent_id: Some(agent_id),
      answered: True,
      pending: None,
      marked: marked,
    ),
    list.flatten([
      complaint,
      commands,
      [Tell(types.Answered(agent_id, agent_call_id, pending.at))],
    ]),
  )
}

fn leg(call_id: String, known: Option(String)) -> Option(String) {
  case call_id {
    "" -> known
    call_id -> Some(call_id)
  }
}

/// What the log says about an answer nobody could name: enough to find the
/// leg that carried no `Agent-ID` and the agents it could have belonged to.
fn unnamed(ring: Ring, agent_call_id: String) -> String {
  "offer for call "
  <> ring.call_id
  <> " in queue "
  <> ring.queue_id
  <> " was answered by leg "
  <> agent_call_id
  <> ", which named no agent of "
  <> string.join(ring.agents, ", ")
  <> "; answering as "
  <> unknown_agent
}

/// Nothing was said for as long as the offer was willing to wait.
///
/// An answer still waiting for a name goes out named `unknown` and the offer
/// keeps watching the call, which is up whether or not anything ever said
/// whose it is. Everything else is the end of the offer.
///
/// A ring cancelled from the caller's side whose caller is still there after
/// `cancel_wait_ms` was called off by the callflow action, which has told the
/// dispatcher the caller is leaving: nobody missed anything, and the reply is
/// a failure, which the dispatcher has most likely already stopped listening
/// for.
pub fn timed_out(ring: Ring, state: State, now: Int) -> Move {
  case state.pending, state.answered, state.cancelled {
    Some(pending), _, _ -> {
      let #(state, effects) = settled(ring, state, pending, None, Live)
      Move(state: state, effects: effects, over: False)
    }
    // The answered bridge ended and nothing said it was a transfer: the call
    // is over, and the caller goes with the agent.
    None, True, _ ->
      case state.closing {
        Some(closing) ->
          over(state, [HangUp, Tell(types.Ended(closing.result, closing.at))])
        None -> over(state, [Tell(types.Ended(types.FailedBridge, now))])
      }
    None, False, Some(_until) ->
      over(state, [Tell(types.Failed(originator_cancel))])
    // The ring ran out and the switch never said so. It is the agents' miss
    // only if one of their phones was seen ringing; otherwise nothing rang,
    // and a miss would count against somebody whose phone never rang.
    None, False, None ->
      case state.rang {
        True -> over(state, [Tell(types.OfferNoAnswer(ring.agents))])
        False -> over(state, [Tell(types.Failed(nothing_rang))])
      }
  }
}

/// The failure a ring called off from the caller's side is reported as.
pub const originator_cancel = "originator_cancel"

fn reply(ring: Ring, told: OfferReply) -> Nil {
  process.send(ring.reply_to, #(ring.id, told))
}

//
// --- Reading an event ------------------------------------------------------
//

/// Why an offer produced no answer.
pub type Miss {
  /// Nobody picked up, or the ring ran out.
  NotAnswered
  /// A phone said it was busy.
  WasBusy
  /// A phone refused the call.
  WasRejected
  /// The ring was called off from the caller's side: the caller hung up, or
  /// the callflow action ended the ring because they are leaving the queue.
  Cancelled
  /// Anything else: no route, no endpoint, an execution error.
  Broke(reason: String)
}

/// The switch's word for how a bridge ended, in upper case.
///
/// `Application-Response` is what the bridge itself answered and is the
/// specific one; `Hangup-Cause` is what the channel ended with. Neither is
/// always there, and a bridge that says nothing at all is `UNSPECIFIED`,
/// which is what `kapps_call_command` calls it too.
pub fn cause(event: Value) -> String {
  first_string(event, [
    ["Application-Response"],
    ["Hangup-Cause"],
    ["Disposition"],
  ])
  |> option.unwrap("UNSPECIFIED")
  |> string.uppercase
}

/// What an unanswered bridge's event says went wrong.
pub fn miss(event: Value) -> Miss {
  case cause(event) {
    "USER_BUSY" | "BUSY" -> WasBusy
    "CALL_REJECTED" | "REJECTED" -> WasRejected
    "ORIGINATOR_CANCEL" -> Cancelled
    "NO_ANSWER"
    | "NO_USER_RESPONSE"
    | "ALLOTTED_TIMEOUT"
    | "PROGRESS_TIMEOUT"
    | "RECOVERY_ON_TIMER_EXPIRE"
    | "UNSPECIFIED" -> NotAnswered
    other -> Broke(other)
  }
}

/// The reply a miss is.
///
/// A busy or a rejection belongs to one agent, and with a simultaneous ring
/// the switch gives one cause for all of them: there is no telling which
/// phone said it, so every agent rung is reported as not having answered and
/// the dispatcher counts a miss for each, which is what happened.
pub fn miss_reply(miss: Miss, agents: List(String)) -> OfferReply {
  case miss, agents {
    NotAnswered, _ -> types.OfferNoAnswer(agents)
    WasBusy, [agent] -> types.Busy(agent)
    WasRejected, [agent] -> types.Rejected(agent)
    WasBusy, _many -> types.OfferNoAnswer(agents)
    WasRejected, _many -> types.OfferNoAnswer(agents)
    Cancelled, _ -> types.Failed(originator_cancel)
    Broke(reason), _ -> types.Failed(reason)
  }
}

/// Whether an event is the end of a `bridge` command.
pub fn is_bridge(event: Value) -> Bool {
  doc.get_string(event, ["Application-Name"]) == Ok("bridge")
}

/// Whether an event is the switch refusing a `bridge` outright, which is an
/// `error` and not a call event at all.
pub fn is_bridge_error(event: Value) -> Bool {
  doc.get_string(event, ["Event-Category"]) == Ok("error") && is_bridge(event)
}

/// Which of the agents rung answered, as far as one event can say.
///
/// One agent rung is one agent answering. With several the bridge event
/// belongs to the caller, so the answer is the `Agent-ID` the endpoint put on
/// the agent's leg, which reaches here on that leg's own events.
pub fn answering_agent(agents: List(String), event: Value) -> Option(String) {
  case agents {
    [one] -> Some(one)
    _many -> agent_of(event, agents)
  }
}

/// The agent an event's channel belongs to: the `Agent-ID` this application
/// put on the leg, or the user who owns the device that authorised it.
pub fn agent_of(event: Value, agents: List(String)) -> Option(String) {
  first_string(event, [
    ["Custom-Channel-Vars", "Agent-ID"],
    ["Custom-Channel-Vars", "Owner-ID"],
  ])
  |> option.then(fn(agent_id) {
    case list.contains(agents, agent_id) {
      True -> Some(agent_id)
      False -> None
    }
  })
}

fn first_string(value: Value, paths: List(List(String))) -> Option(String) {
  case paths {
    [] -> None
    [path, ..rest] ->
      case doc.get_string(value, path) {
        Ok("") -> first_string(value, rest)
        Ok(text) -> Some(text)
        Error(Nil) -> first_string(value, rest)
      }
  }
}

//
// --- The caller's identity, and the agents' endpoints ----------------------
//

/// The call the agents' phones see: the queue's prefix in front of the
/// caller's name, so an agent knows which queue rang before they answer.
pub fn prefixed(call: Value, prefix: Option(String)) -> Value {
  case prefix {
    None -> call
    Some("") -> call
    Some(prefix) -> {
      let name = doc.get_string(call, ["Caller-ID-Name"]) |> unwrap_string
      doc.set(call, ["Caller-ID-Name"], doc.String(prefix <> name))
    }
  }
}

fn unwrap_string(read: Result(String, Nil)) -> String {
  case read {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

/// One endpoint, marked with the agent it rings and with the queue's own
/// outbound caller ID when it leaves the account.
///
/// The `Agent-ID` is what makes an answer attributable: it travels with the
/// agent's leg and comes back on that leg's events and on its CDR.
pub fn decorate(
  endpoint: Value,
  agent_id: String,
  settings: OfferSettings,
) -> Value {
  endpoint
  |> doc.set(["Custom-Channel-Vars", "Agent-ID"], doc.String(agent_id))
  |> outbound_caller_id(settings)
}

fn outbound_caller_id(endpoint: Value, settings: OfferSettings) -> Value {
  case is_external(endpoint) {
    False -> endpoint
    True ->
      endpoint
      |> set_some(["Outbound-Caller-ID-Name"], settings.outbound_caller_id_name)
      |> set_some(
        ["Outbound-Caller-ID-Number"],
        settings.outbound_caller_id_number,
      )
  }
}

fn set_some(value: Value, path: List(String), to: Option(String)) -> Value {
  case to {
    Some("") | None -> value
    Some(text) -> doc.set(value, path, doc.String(text))
  }
}

/// Whether an endpoint leaves the account.
///
/// `kz_endpoint` builds a device on this account with `Invite-Format`
/// `endpoint`; a call forward to a number outside it is a `loopback` or a
/// `route` carrying a `To-DID`. The queue's outbound caller ID is for the
/// second kind, where the contact is somebody else's.
pub fn is_external(endpoint: Value) -> Bool {
  doc.get_string(endpoint, ["Invite-Format"]) != Ok("endpoint")
}

//
// --- The call's events -----------------------------------------------------
//

/// Have this call's events relayed into this process, which is the mailbox
/// `kazoo/call.receive_event` reads.
///
/// The agent's leg is in the set once it is bridged: its events carry the
/// caller as their other leg, which is how the offer sees the agent hang up.
/// The rest of the account's events are dropped on the bus, and the ones
/// relayed go as they arrived, never made into a document on the way.
fn watch(ring: Ring, prefix: String) -> Option(events.Subscription) {
  let call_id = ring.call_id
  case
    events.relay(interest(ring.account_id, call_id, prefix), to: process.self())
  {
    Ok(subscription) -> Some(subscription)
    Error(reason) -> {
      system.log_error(
        "offer for call " <> call_id <> " has no events: " <> reason,
      )
      None
    }
  }
}

/// What the offer subscribes with: the account's events that `relays`
/// keeps, decided on the bus.
pub fn interest(
  account_id: String,
  call_id: String,
  prefix: String,
) -> events.Interest {
  events.Interest(..events.account(account_id), carrying: [
    events.CallId(call_id),
    events.OtherLeg(call_id),
    events.CallIdPrefix(prefix <> "-"),
  ])
}

/// Whether an event of the account's is one of this offer's: the caller's
/// own, one naming the caller as its other leg, or one of the legs the offer
/// named, from the moment the leg exists.
pub fn relays(call_id: String, prefix: String, event: Value) -> Bool {
  case events.call_id(event) {
    Some(leg) if leg == call_id -> True
    Some(leg) ->
      events.other_leg_call_id(event) == Some(call_id)
      || string.starts_with(leg, prefix <> "-")
    None -> events.other_leg_call_id(event) == Some(call_id)
  }
}

fn unwatch(watching: events.Subscription) -> Nil {
  events.off(watching)
}
