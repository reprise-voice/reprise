//// One queued call, as the one process that commands it decides what to do.
////
//// A caller waiting in an account's queues is one actor on the node holding
//// the account's shard, and this is the whole of what that actor decides:
//// `step` takes the call as it stands, one input and the time, and answers
//// the call as it stands after, with the effects the actor performs in
//// order. Nothing here sends a command, reads a document or looks at a clock
//// of its own, so every rule below is something a test reads without a
//// switch -- and the one process that performs the effects is the only
//// thing that ever commands the caller's channel, through the one
//// publisher its call is given (`call/publishers`), in the order decided
//// here.
////
//// **The call model.** The caller stays on hold on their own channel from
//// the moment they join until they leave, and nothing ever parks or
//// unbridges them:
////
//// - an offer rings the agents' phones on legs of their own, one
////   `originate_req` for the whole offer, every device at once, each leg
////   named in advance (`<offer>-N`) and born with the queue's variables;
////   the caller hears their hold music throughout;
//// - the first leg to answer decides the call. The caller's channel is
////   marked with the agent and the second, and the actor bridges the caller
////   to the leg once its originate has parked it and the switch has shown
////   the marks ran: a flush of the hold, and `connect_leg` run at once with
////   both channels set to park -- not hang up -- when the other goes, so
////   that the actor and not the order of two channels' events says how the
////   call ended (the labs of 2026-09-27, `e2e-260927-spike1` and
////   `e2e-260927-cca2`: a leg bridged before its originate had finished with
////   it was taken back out of the bridge by the originate's own `park`).
////   The flush throws away whatever the caller's channel has been sent and
////   not yet run, which is why the marks are seen to run first (`Confirm`);
//// - an offer called off -- the caller leaving, the agent released, the
////   queue deleted -- has its legs hung up by name, which never touches the
////   caller, and any of its legs that turns up later is hung up as it does.
////
//// **One message at a time decides.** An answer, a key, a clock running out
//// and a call-off can all be in flight at once, and whichever the actor
//// handles first stands: a leg that answered first is bridged, and an exit
//// that came first hangs every leg up, one that has just answered included.
////
//// **Phases, not flags.** The call is always in exactly one of `Phase`'s
//// states, and what it may send the caller follows from that alone (see
//// `allowed`): media only while it waits, the bridge only as it connects,
//// the answer's marks as a leg answers, the recording only while
//// connected, the last hang-up only once a leg has answered, and the
//// departure's marks and barrier only as it leaves.
////
//// **Leaving.** A caller who leaves the queue on a branch is handed back to
//// the callflow that sent them, which is on some other node and blocked in
//// the queue's callflow action: the legs are hung up, the channel is marked
//// `Queue-Departing`, and a `noop` with a known `Msg-ID` flushes the hold.
//// Its completion proves `ecallmgr` has run every command the actor sent
//// before it, and only then does `member_continue` go out, repeated until
//// the action says `member_continuing`. An action that never answers is on
//// a node that has gone, and the caller is resumed at the branch on any
//// callflow node instead, and watched until the resumed flow marks their
//// channel as its own. The actor publishes a resume nobody takes again,
//// and hangs up a caller no resume reaches rather than leave them in
//// silence.
////
//// Instants are of two clocks, both in `Clock`: the calendar's Gregorian
//// seconds, which is what the caller's own waits (`callcenter/caller`) and
//// everything reported are counted in, and the VM's monotonic milliseconds,
//// which is what every short wait here is counted on.

import callcenter/announce
import callcenter/call/media.{type Media}
import callcenter/call/originate
import callcenter/call/recovery
import callcenter/call/talk
import callcenter/caller
import callcenter/fields
import callcenter/types.{
  type CancelReason, type OfferId, type OfferReply, type Presence,
}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import kazoo/call.{type MacroItem}
import kazoo/doc.{type Value}
import kazoo/events

// --- Waits ---------------------------------------------------------------------

/// How long an answered leg is given to be parked by its originate, and the
/// answer's marks to be seen to run on the caller's channel, before the
/// caller is bridged to it all the same. The switch runs the originate's
/// `park` within about 40 ms of the answer (the labs of 2026-09-27); neither
/// the park's own event nor `ecallmgr`'s answer to the originate comes that
/// soon, the second taking half a second. The marks are seen to run by a
/// `noop` sent at once behind them, and a `noop` sent at once completed in
/// 19 ms on the lab (`probe_ms`). Every moment of the wait is a moment the
/// agent's leg is on its own, where the switch refuses the agent's blind
/// transfer and the agent hears nothing.
pub const park_wait_ms = 150

/// How long the bridge to an answered leg has to show on the caller's
/// channel. `connect_leg` bridges in under 100 ms on the lab; a bridge that
/// has not shown in this long is not coming, and the leg is hung up.
pub const connect_ms = 5000

/// How long a ring called off because its caller hung up waits, at most,
/// before the call is decided (`Desertion`): an agent's answer that came
/// before the hang-up is heard in this long, the legs being hung up at once
/// and their ends following in a few hundred milliseconds.
pub const desertion_ms = 2000

/// How long the departure's barrier has to complete before the callflow is
/// told to go on regardless: the completion proves the earlier commands ran,
/// and one that never comes -- `ecallmgr` gone with the caller's control
/// process -- must not keep the caller in silence.
pub const barrier_ms = 5000

/// How long the actor waits for `member_continuing` before asking again.
pub const continue_ack_ms = 2000

/// How many times `member_continue` is asked before the callflow's node is
/// taken to be gone and the caller resumed at the branch elsewhere.
pub const continue_attempts = 3

/// How long the probe of a caller this actor was handed without knowing
/// them is waited for once the survey is in. The lab's probe completed in
/// 19 ms; one that has not in this long is a channel that is not there, or
/// whose control process is not.
pub const probe_ms = 3000

/// How long the actor waits for a resume to show it was taken before it
/// probes the caller's channel. The resumed flow's first action,
/// `callcenter_departed`, marks the channel `Queue-Departed` for the
/// passage, and every event of the channel after that carries the mark. A
/// callflow node that takes the resume first asks the switches whether the
/// channel is up (`cf_route_resume`), which waits two seconds at most, and
/// checking out an AMQP worker to ask with can take two more. A resume that
/// was taken has marked the channel well inside eight. The wait is long on
/// purpose. A resume published again while the first is still starting
/// would run the branch's flow twice on one channel, and that is worse than
/// a few more seconds of silence.
pub const resume_ack_ms = 8000

/// How many times the actor resumes a caller before it hangs them up. Each
/// try takes `resume_ack_ms`, and `probe_ms` more when the actor has to ask
/// the channel, so the tries span about half a minute. A caller nobody
/// takes is in silence, since the departure's barrier flushed their hold.
/// The shard settled their member as they left and their callflow is gone,
/// so nothing else will ever drive them. A caller who is hung up can call
/// back.
pub const resume_attempts = 3

/// How long a caller handed over is given to be found out about before
/// they are classified with whatever has come in: the survey's channel
/// query gives the switches two seconds, and the record is one read.
pub const recover_ms = 8000

/// How many times a caller nothing could be found out about is asked about
/// before they are taken to be waiting. Each try takes `recover_ms`, so the
/// tries span 48 seconds. That outlasts the 15 to 40 seconds a node that
/// has just started takes to hear of the switches it asks
/// (`recovery.standing`), and a caller with an agent ringing is not taken
/// to be waiting before it could have heard.
///
/// A caller whose record could not be read is asked about the same way,
/// and a datastore that comes back within the tries decides them as it
/// would have at once. One that does not is taken, on the last try, for no
/// record at all (`recovery.unread_as_none`): the caller is where the probe
/// and the switches put them, and only a caller they cannot place either is
/// taken to be waiting.
pub const recover_attempts = 6

/// How often a waiting, ringing or connected call asks the switches whether
/// its caller -- and the agent's leg, once connected -- is still there. An
/// event lost on the way is a caller nobody would ever hear go, and a
/// connected agent held busy for `longest_call_ms`.
pub const audit_ms = 30_000

/// The longest a call is watched once it is connected. Long enough that no
/// real call reaches it; short enough that an actor whose events stopped
/// does not live for ever.
pub const longest_call_ms = 14_400_000

/// The longest the actor sleeps whatever its deadlines say, and the
/// shortest.
const longest_wait_ms = 30_000

const shortest_wait_ms = 1

// --- The call --------------------------------------------------------------------

/// The two clocks every step is taken at.
pub type Clock {
  Clock(
    /// Gregorian seconds, the calendar's.
    now: Int,
    /// The VM's monotonic milliseconds.
    now_ms: Int,
  )
}

/// What a queue asks of the caller while they wait in it.
pub type Settings {
  Settings(
    limits: caller.Limits,
    announcement: announce.Settings,
    exit_keys: List(String),
    /// The queue's hold music, or the account's when `None`.
    moh: Option(String),
    greeting: Option(String),
    language: String,
  )
}

/// What a queue document asks of a caller waiting in it, read as the
/// callflow action read it: the clocks, the announcements, the exit keys,
/// the hold music and the greeting. `language` is the caller's own.
pub fn settings(queue: Value, language: String) -> Settings {
  let announcement = announce.settings(queue)
  Settings(
    limits: caller.limits(queue)
      |> caller.with_announce_interval(announcement.interval_s),
    announcement: announcement,
    exit_keys: caller.exit_keys(queue),
    moh: fields.some_string(queue, ["moh"]),
    greeting: fields.some_string(queue, ["greeting"]),
    language: language,
  )
}

/// Where the callflow that sent the caller waits for them back.
pub type Handoff {
  Handoff(
    /// The passage's own id, which the action waits for and every
    /// `member_continue` of it carries.
    id: String,
    /// The action's Controller-Queue, where `member_continue` goes.
    reply_to: String,
    /// The flows the callflow might continue into, by branch name: what a
    /// resume runs when the action's node is gone.
    branches: Value,
  )
}

/// A caller joining one of the account's queues: what the dispatcher tells
/// the actor as the member arrives.
pub type Joining {
  Joining(queue_id: String, joined: Int, handoff: Handoff, settings: Settings)
}

/// A call a node that died had already connected, taken on so that its end
/// is heard: the caller's passage, the offer the dispatcher now holds it
/// under, and who answered on which leg when.
pub type Adoption {
  Adoption(
    joining: Joining,
    offer: OfferId,
    agent_id: String,
    leg: String,
    answered_at: Int,
  )
}

/// One passage of the caller through one queue.
pub type Passage {
  Passage(
    queue_id: String,
    joined: Int,
    handoff: Handoff,
    settings: Settings,
    /// The caller's own clocks and counts.
    caller: caller.Caller,
  )
}

/// The dispatcher asking for agents to be rung for the caller: the
/// endpoints already built, decorated and named (`call/originate`).
pub type RingRequest {
  RingRequest(
    offer: OfferId,
    agents: List(String),
    endpoints: List(Value),
    ring_timeout_s: Int,
    /// How much longer than the ring timeout the ring is waited for.
    grace_s: Int,
    record: Bool,
    /// A supervisor's pickup rather than an agent's offer.
    pickup: Bool,
  )
}

/// One offer the actor has rung.
pub type Offer {
  Offer(
    id: OfferId,
    agents: List(String),
    /// Every leg the offer named, to the agent it rings.
    legs: Dict(String, String),
    /// The legs the switch has said exist.
    seen: Set(String),
    /// The legs the switch has said have gone.
    gone: Set(String),
    /// The monotonic millisecond past which the ring is given up on.
    until_ms: Int,
    record: Bool,
    /// A supervisor's pickup rather than an agent's offer.
    pickup: Bool,
  )
}

/// Where an offer's ring has got to.
pub type Ring {
  /// The phones are ringing and the caller still hears their media.
  Ringing(media: Media)
  /// A leg answered, and the call is its agent's: no key, clock or
  /// call-off takes the caller away now. The caller, who still hears their
  /// media, has been marked with the agent and the second, and is bridged
  /// to the leg once two things are so, or at `until_ms` whatever is:
  ///
  /// - the leg is `parked`: its originate has finished with it, and the leg
  ///   has run `park`. A leg bridged sooner is taken back out of the bridge
  ///   by that `park`;
  /// - the caller is `marked`: the `noop` sent at once behind the marks has
  ///   completed (`Confirm`), so the marks have run. The bridge's flush
  ///   throws away whatever the caller's channel has not yet run, and marks
  ///   thrown away leave the caller's CDR without the agent.
  Parking(
    leg: String,
    agent_id: String,
    answered_at: Int,
    parked: Bool,
    marked: Bool,
    until_ms: Int,
  )
  /// A leg answered and the caller is being bridged to it: the media has
  /// been flushed, and nothing else is sent the caller until the bridge
  /// shows or does not.
  Connecting(leg: String, agent_id: String, answered_at: Int, until_ms: Int)
}

/// Why a caller leaves a queue without an agent.
pub type Exit {
  /// One of the queue's exit keys.
  ExitKey
  /// `max_wait_time`.
  WaitedTooLong
  /// `max_wait_time_with_no_agent`.
  NobodyTooLong
  /// The queue was deleted while they waited.
  QueueDeleted
  /// The actors before this one kept crashing on the call
  /// (`callcenter/call/calls`), and this one hands the caller back rather
  /// than try again.
  Quarantined
}

/// Which state the call is in.
pub type Phase {
  /// The actor exists and no passage has begun.
  Idle
  /// Waiting in a queue, nobody being rung.
  Waiting(passage: Passage, media: Media)
  /// Waiting in a queue, with an offer out.
  Offering(passage: Passage, offer: Offer, ring: Ring)
  /// Through to an agent.
  Connected(
    passage: Passage,
    offer: Offer,
    agent_id: String,
    answered_at: Int,
    talk: talk.Talk,
    /// The monotonic millisecond past which the call is no longer watched.
    until_ms: Int,
  )
  /// Leaving the queue: the departure's barrier is out.
  Leaving(passage: Passage, exit: Exit, barrier: String, until_ms: Int)
  /// Handed back: `member_continue` is out, waiting to be acknowledged.
  Departed(passage: Passage, exit: Exit, attempts: Int, until_ms: Int)
  /// Never acknowledged: before the caller is resumed on another callflow
  /// node, their channel is asked whether the action took them after all
  /// and only its answer was lost -- `Queue-Departed` of this passage.
  Resuming(passage: Passage, exit: Exit, probe: String, until_ms: Int)
  /// Resumed on another callflow node, and watched until the resume shows
  /// it was taken. `callcenter_departed`, the resumed flow's first action,
  /// marks the channel `Queue-Departed` for this passage. Any event of the
  /// channel that carries the mark, a probe's completion among them, says a
  /// flow has the caller. So do the channel's end, the caller joining a
  /// queue again, and the action's own `member_continuing` come late.
  /// `attempt` counts the resumes published. `probe` is the probe out once
  /// `resume_ack_ms` has gone by with no word. Its completion without the
  /// mark, or no completion in `probe_ms`, means nobody took the resume.
  Resumed(
    passage: Passage,
    exit: Exit,
    attempt: Int,
    probe: Option(String),
    until_ms: Int,
  )
  /// Handed to this actor without it knowing where the caller stands --
  /// the node holding them died, or the actor before this one ended -- and
  /// finding out (`callcenter/call/recovery`): the probe and the survey are
  /// out, and everything else that arrives waits in `held` until the call
  /// has been classified.
  Recovering(
    joining: Joining,
    /// What anything found going on for the caller is held under.
    offer: OfferId,
    attempt: Int,
    probe: Option(recovery.Probe),
    survey: Option(recovery.Survey),
    /// What arrived meanwhile, newest first.
    held: List(Input),
    /// The monotonic millisecond past which a probe not yet answered, with
    /// the survey in, is taken as unanswered.
    probe_until_ms: Int,
    /// The monotonic millisecond past which the call is classified with
    /// whatever has come in.
    until_ms: Int,
  )
  /// Nothing more is sent the caller.
  Done
}

/// An offer that was called off while its legs might still ring: any of
/// them that turns up is hung up, until the originate says it is over or
/// the ring's own deadline passes. `tell` is what the dispatcher is told
/// then, if anything, and `deserted` is set when the call-off was the
/// caller hanging up.
pub type Recall {
  Recall(
    offer: Offer,
    tell: Option(OfferReply),
    heard: Bool,
    deserted: Option(Desertion),
  )
}

/// The caller hung up while the offer rang (`caller_gone`), and the ring was
/// called off, but whether they left before anybody answered or hung up on
/// an agent who just had is not known yet. The caller's end and a leg's
/// answer are events of two channels, and nothing orders the two: the lab
/// of 2026-09-27 (e2e-260927-cca5) had an agent answer and the caller hang
/// up straight after, the actor heard the hang-up first, and the answer was
/// never counted. So the call-off decides once its ring is over, or after
/// `desertion_ms`. A leg that answered before the caller's end, by the
/// switch's own clock, makes it an answered call that the caller ended.
/// Otherwise the caller left the queue.
pub type Desertion {
  Desertion(
    /// When the switch says the caller hung up (`Event-Timestamp`, in
    /// microseconds), if it said.
    at_us: Option(Int),
    /// When the caller hung up, a calendar second.
    at: Int,
    /// The leg that answered before the caller hung up: the leg, its agent
    /// and the second.
    answer: Option(#(String, String, Int)),
    /// The monotonic millisecond by which the call is decided, whatever has
    /// been heard.
    until_ms: Int,
  )
}

pub type Call {
  Call(
    account_id: String,
    call_id: String,
    phase: Phase,
    recalls: List(Recall),
    /// The monotonic millisecond of the next audit, while the call is in a
    /// phase that has one.
    audit_due_ms: Option(Int),
  )
}

/// A call whose actor has just started, before its first passage.
pub fn new(account_id: String, call_id: String) -> Call {
  Call(
    account_id: account_id,
    call_id: call_id,
    phase: Idle,
    recalls: [],
    audit_due_ms: None,
  )
}

/// Whether there is nothing left for the actor to do.
pub fn finished(call: Call) -> Bool {
  call.phase == Done && call.recalls == []
}

// --- Inputs and effects -------------------------------------------------------

pub type Input {
  /// The dispatcher: a caller joining one of the account's queues.
  Joined(Joining)
  /// The dispatcher: a caller it was handed without seeing them join -- the
  /// broker handed them out again, their actor was replaced, or the
  /// dispatcher itself was -- whom it rings nobody for until told where
  /// they stand (`Present`). `offer` is what anything found going on for
  /// them is held under.
  Rejoined(joining: Joining, offer: OfferId)
  /// What the survey of a caller being recovered found.
  Surveyed(recovery.Survey)
  /// The dispatcher, to an actor started after the ones before it crashed
  /// on the call `quarantine_after` times: whatever it joined for, the
  /// caller is handed back on `no_agents` at once, with nothing found out
  /// about them, since that may be what crashed.
  Quarantine(Joining)
  /// The dispatcher: a call already connected, to watch to its end.
  Adopt(Adoption)
  /// The dispatcher: ring these agents for the caller.
  Ring(RingRequest)
  /// The dispatcher: call this offer off.
  CallOff(OfferId)
  /// The dispatcher: the caller's queue has been deleted.
  QueueGone
  /// The dispatcher: where the caller stands in the queue.
  Positioned(
    position: Option(Int),
    waiting: Option(Int),
    agents_available: Option(Int),
  )
  /// An event of the caller's channel or of one of the offer's legs, as the
  /// switch published it.
  Event(Value)
  /// What `ecallmgr` said of an offer's originate: `originate_resp`, or an
  /// error naming the cause.
  Originated(offer: OfferId, reply: Value)
  /// The callflow action: it has the caller back.
  Continuing(handoff_id: String)
  /// The switches' answer to an audit: the call ids of those asked about
  /// that every switch said it does not carry.
  Audited(gone: List(String))
  /// The actor's own wake-up, at `wait_ms`.
  Tick
}

pub type Effect {
  /// Play the queue's greeting to the caller.
  Play(media: String)
  /// Play an announcement in place of the hold.
  Announce(items: List(MacroItem))
  /// Put the caller on hold.
  Hold(moh: Option(String))
  /// Bridge the caller to a parked leg: flush the hold, `connect_leg` at
  /// once, and mark the caller to park when the leg goes.
  Bridge(leg: String)
  /// Set channel variables on the caller, at once.
  Mark(vars: List(#(String, Value)))
  /// Show that what was sent the caller at once before it has run: a `noop`
  /// run at once, with this `Msg-ID`. A command sent at once is not run as
  /// `ecallmgr` takes it: the switch queues it on the caller's channel, which
  /// runs what is queued so in the order it came, the next time it looks.
  /// So the `noop`'s completion is the proof that everything ahead of it
  /// ran. Until then a flush -- the `uuid_break all` of a `noop` sent with
  /// `Insert-At: flush`, as the bridge's is -- would throw away what had not.
  Confirm(msg_id: String)
  /// Start the queue's recording on the caller's channel.
  Record(agent_id: String, at: Int)
  /// Hang the caller up.
  HangUpCaller
  /// The departure's barrier: a `noop` that flushes, with this `Msg-ID`.
  Barrier(msg_id: String)
  /// Ring an offer's endpoints: one originate.
  Originate(offer: OfferId, endpoints: List(Value), ring_timeout_s: Int)
  /// Hang these legs up by name.
  HangUpLegs(legs: List(String))
  /// Tell the dispatcher how an offer went.
  Tell(offer: OfferId, reply: OfferReply)
  /// Tell the shard the caller has left the queue: settle them.
  Left(reason: CancelReason)
  /// Hand the caller back to the callflow action, on a branch.
  Continue(handoff: Handoff, branch: String)
  /// The callflow action's node is gone: resume the caller at the branch on
  /// any callflow node.
  Resume(handoff: Handoff, branch: String)
  /// Ask the caller's channel how it stands: a `noop` run at once, with
  /// this `Msg-ID`, whose completion carries the channel's variables.
  Probe(msg_id: String)
  /// Survey a caller being recovered: their record, and the account's
  /// channels. Its answer is `Surveyed`.
  Survey
  /// Tell the dispatcher where a caller it was handed stands, under this
  /// offer, or under a fresh id when it is not about one.
  Present(offer: Option(OfferId), presence: Presence)
  /// Ask every switch whether these call ids are still up. Its answer is
  /// `Audited`.
  Audit(call_ids: List(String))
  /// Something an operator should read.
  Log(message: String)
  /// Something an operator has to act on: logged as an error.
  LogError(message: String)
}

// --- Stepping -----------------------------------------------------------------

/// One input, at one time: the call after it, and what to do about it, in
/// order.
pub fn step(call: Call, input: Input, clock: Clock) -> #(Call, List(Effect)) {
  let #(call, recalled) = recalling(call, input, clock)
  let #(call, effects) = case recalled {
    True -> #(call, [])
    False -> phase_step(call, input, clock)
  }
  let #(call, settled) = settle_recalls(call, clock)
  let #(call, audit) = audit(call, clock)
  #(call, list.flatten([effects, settled, audit]))
}

/// The audit, while the call is waiting, ringing or connected: due
/// `audit_ms` after the call came into one of those, and every `audit_ms`
/// after that. It asks about the caller, and about the agent's leg once
/// they are through to it.
fn audit(call: Call, clock: Clock) -> #(Call, List(Effect)) {
  let asked = case call.phase {
    Waiting(..) | Offering(..) -> Some([call.call_id])
    Connected(talk: talk.Talk(leg: Some(leg), ..), ..) ->
      Some([call.call_id, leg])
    Connected(..) -> Some([call.call_id])
    _ -> None
  }
  case asked, call.audit_due_ms {
    None, _ -> #(Call(..call, audit_due_ms: None), [])
    Some(_), None -> #(
      Call(..call, audit_due_ms: Some(clock.now_ms + audit_ms)),
      [],
    )
    Some(ids), Some(due) if clock.now_ms >= due -> #(
      Call(..call, audit_due_ms: Some(clock.now_ms + audit_ms)),
      [Audit(ids)],
    )
    Some(_), Some(_) -> #(call, [])
  }
}

/// What the switches said to an audit: each call id they all say is gone
/// is heard as its channel's end, the caller's last.
fn audited(
  call: Call,
  gone: List(String),
  clock: Clock,
) -> #(Call, List(Effect)) {
  let #(legs, caller) = list.partition(gone, fn(id) { id != call.call_id })
  list.fold(list.append(legs, caller), #(call, []), fn(acc, id) {
    let #(call, effects) = acc
    let destroy =
      doc.object([
        #("Event-Category", doc.String("call_event")),
        #("Event-Name", doc.String("CHANNEL_DESTROY")),
        #("Call-ID", doc.String(id)),
        #("Hangup-Cause", doc.String("NORMAL_CLEARING")),
      ])
    let #(after, more) = heard(call, destroy, clock)
    let noted = case more == [] && after == call {
      True -> []
      False -> [
        Log(
          "call "
          <> call.call_id
          <> ": "
          <> id
          <> " is on no switch and its end was never heard; taking it as gone",
        ),
      ]
    }
    #(after, list.flatten([effects, noted, more]))
  })
}

/// How long the actor may sleep before it has to look at the call again.
pub fn wait_ms(call: Call, clock: Clock) -> Int {
  let phase_wait = case call.phase {
    Idle | Done -> None
    Waiting(passage, media) ->
      Some(media.wake_ms(
        media,
        caller.next_wake_ms(passage.caller, passage.settings.limits, clock.now),
        clock.now,
      ))
    Offering(passage, offer, Ringing(media)) ->
      Some(int.min(
        media.wake_ms(
          media,
          caller.next_wake_ms(
            passage.caller,
            passage.settings.limits,
            clock.now,
          ),
          clock.now,
        ),
        offer.until_ms - clock.now_ms,
      ))
    Offering(_, _, Connecting(until_ms: until, ..))
    | Offering(_, _, Parking(until_ms: until, ..)) -> Some(until - clock.now_ms)
    Connected(talk: talking, until_ms: until, ..) ->
      case talking.closing {
        Some(closing) -> Some(closing.until - clock.now_ms)
        None -> Some(until - clock.now_ms)
      }
    Leaving(until_ms: until, ..)
    | Departed(until_ms: until, ..)
    | Resuming(until_ms: until, ..)
    | Resumed(until_ms: until, ..) -> Some(until - clock.now_ms)
    Recovering(probe: probe, survey: survey, probe_until_ms: probe_until, ..) as recovering ->
      case probe, survey {
        None, Some(_) -> Some(int.min(probe_until, recovering.until_ms))
        _, _ -> Some(recovering.until_ms)
      }
      |> option.map(fn(until) { until - clock.now_ms })
  }
  let recall_wait =
    list.flat_map(call.recalls, fn(recall) {
      case recall.deserted {
        Some(desertion) -> [recall.offer.until_ms, desertion.until_ms]
        None -> [recall.offer.until_ms]
      }
      |> list.map(fn(until) { until - clock.now_ms })
    })
  let audit_wait = option.map(call.audit_due_ms, fn(due) { due - clock.now_ms })
  [phase_wait, audit_wait, ..list.map(recall_wait, Some)]
  |> option.values
  |> list.fold(longest_wait_ms, int.min)
  |> int.max(shortest_wait_ms)
}

fn phase_step(call: Call, input: Input, clock: Clock) -> #(Call, List(Effect)) {
  case call.phase, input {
    Recovering(..), Rejoined(..) -> settled_step(call, input, clock)
    Recovering(..) as recovering, _ ->
      recovering_step(call, recovering, input, clock)
    _, _ -> settled_step(call, input, clock)
  }
}

fn settled_step(
  call: Call,
  input: Input,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case input {
    Joined(joining) -> joined(call, joining, clock)
    Rejoined(joining, offer) -> rejoined(call, joining, offer, clock)
    // A survey nobody is waiting for: a caller recovered already.
    Surveyed(_) -> stay(call)
    Audited(gone) -> audited(call, gone, clock)
    Quarantine(joining) -> quarantined(call, joining, clock)
    Adopt(adoption) -> adopted(call, adoption, clock)
    Ring(request) -> rung(call, request, clock)
    CallOff(offer) -> called_off(call, offer, clock)
    QueueGone -> queue_gone(call, clock)
    Positioned(position, waiting, available) ->
      positioned(call, position, waiting, available, clock)
    Event(event) -> heard(call, event, clock)
    Originated(offer, reply) -> originated(call, offer, reply, clock)
    Continuing(handoff_id) -> continuing(call, handoff_id)
    Tick -> ticked(call, clock)
  }
}

fn stay(call: Call) -> #(Call, List(Effect)) {
  #(call, [])
}

fn into(
  call: Call,
  phase: Phase,
  effects: List(Effect),
) -> #(Call, List(Effect)) {
  #(Call(..call, phase: phase), effects)
}

// --- Joining ------------------------------------------------------------------

/// A caller joining a queue. A new passage starts with the queue's greeting,
/// or its hold music when it has none.
///
/// A join for the passage already running is the same member delivered
/// again, and changes nothing. A join while the call is on its way out of a
/// queue -- or already out -- is the callflow having taken the caller on to
/// the next queue: the handback was heard, and the new passage begins.
fn joined(call: Call, joining: Joining, clock: Clock) -> #(Call, List(Effect)) {
  case call.phase {
    Waiting(passage, _)
      | Offering(passage, _, _)
      | Connected(passage: passage, ..)
      if passage.handoff.id == joining.handoff.id
    -> stay(call)
    Waiting(passage, media) ->
      into(call, Waiting(renewed(passage, joining), media), [
        Log(ran_again(call, joining)),
      ])
    Offering(passage, offer, ring) ->
      into(call, Offering(renewed(passage, joining), offer, ring), [
        Log(ran_again(call, joining)),
      ])
    Connected(passage: passage, offer: offer, talk: talking, ..) -> {
      // The caller joined a queue while connected: the agent passed them on
      // into one, and the call the queue connected is over as of now.
      let at = case talking.closing {
        Some(closing) -> closing.at
        None -> clock.now
      }
      let #(call, effects) = begin(call, joining, True, clock)
      #(call, [
        Tell(offer.id, types.Ended(types.Transferred, at)),
        ..list.append([Log(transferred_in(passage, joining))], effects)
      ])
    }
    Idle | Leaving(..) | Departed(..) | Resuming(..) | Resumed(..) | Done ->
      begin(call, joining, True, clock)
    // A caller joining while the actor finds out about them: the callflow
    // took them on while the last actor was going. Heard once they are
    // classified.
    Recovering(held: held, ..) as recovering ->
      into(call, Recovering(..recovering, held: [Joined(joining), ..held]), [])
  }
}

/// A new passage. A caller who joins is greeted, or put on hold when the
/// queue has no greeting; one handed over (`greet` false) has whatever the
/// node that last held them sent still playing, and a hold is queued behind
/// it -- nothing while a hold is already running, and the hold after a
/// greeting that was cut short.
fn begin(
  call: Call,
  joining: Joining,
  greet: Bool,
  clock: Clock,
) -> #(Call, List(Effect)) {
  let passage = passage_of(joining, caller.new(joining.joined))
  let #(now_playing, cue) = case greet {
    False -> #(media.Held, media.Hold)
    True ->
      media.up(media.Answering(clock.now, joining.settings.greeting), clock.now)
  }
  into(call, Waiting(passage, now_playing), cued(passage, cue))
}

fn passage_of(joining: Joining, caller: caller.Caller) -> Passage {
  Passage(
    queue_id: joining.queue_id,
    joined: joining.joined,
    handoff: joining.handoff,
    settings: joining.settings,
    caller: caller,
  )
}

/// A call connected on a node that died, taken on as it stands: nothing is
/// sent the caller, and the end of the bridge is heard as any connected
/// call's is. Only a call that is doing nothing else here is taken on; one
/// this actor is already running is its own.
fn adopted(
  call: Call,
  adoption: Adoption,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case call.phase {
    Idle | Done -> {
      let joining = adoption.joining
      let offer =
        Offer(
          id: adoption.offer,
          agents: [adoption.agent_id],
          legs: dict.from_list([#(adoption.leg, adoption.agent_id)]),
          seen: set.from_list([adoption.leg]),
          gone: set.new(),
          until_ms: clock.now_ms,
          record: False,
          pickup: False,
        )
      let passage =
        passage_of(joining, caller.connect(caller.new(joining.joined)))
      into(
        call,
        Connected(
          passage: passage,
          offer: offer,
          agent_id: adoption.agent_id,
          answered_at: adoption.answered_at,
          talk: talk.Talk(
            caller: call.call_id,
            leg: case adoption.leg {
              "" -> None
              leg -> Some(leg)
            },
            closing: None,
          ),
          until_ms: clock.now_ms + longest_call_ms,
        ),
        [],
      )
    }
    _ -> stay(call)
  }
}

fn renewed(passage: Passage, joining: Joining) -> Passage {
  Passage(
    ..passage,
    queue_id: joining.queue_id,
    handoff: joining.handoff,
    settings: joining.settings,
  )
}

fn ran_again(call: Call, joining: Joining) -> String {
  "call "
  <> call.call_id
  <> " joined queue "
  <> joining.queue_id
  <> " again while waiting: its callflow ran again"
}

fn transferred_in(passage: Passage, joining: Joining) -> String {
  "call in queue "
  <> passage.queue_id
  <> " was passed on by its agent into queue "
  <> joining.queue_id
}

/// What a media cue is as an effect.
fn cued(passage: Passage, cue: media.Cue) -> List(Effect) {
  case cue {
    media.PlayGreeting(greeting) -> [Play(greeting)]
    media.Announce(items) -> [Announce(items)]
    media.Hold -> [Hold(passage.settings.moh)]
    media.Nothing -> []
  }
}

// --- Taking a caller over -----------------------------------------------------

/// A caller the dispatcher was handed without seeing them join. It rings
/// nobody for them until it is told where they stand, and exactly one
/// `Present` -- or a `Left`, which takes them out of its queue -- answers
/// every rejoin.
///
/// An actor that has just started knows nothing, and finds out: the probe
/// and the survey go out, and the call is `Recovering` until they are in.
/// One that is running the caller's passage knows, and says so at once:
/// the dispatcher is the one that is new. One that is running another
/// passage -- the callflow took the caller on while the member of the old
/// one was on its way -- starts the new one as a caller handed over, with
/// no greeting.
fn rejoined(
  call: Call,
  joining: Joining,
  offer: OfferId,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case call.phase {
    Idle | Done -> recover(call, joining, offer, 1, [], clock)
    Recovering(joining: recovering, held: held, ..) as phase ->
      case recovering.handoff.id == joining.handoff.id {
        True -> stay(call)
        False ->
          into(
            call,
            Recovering(..phase, held: [Rejoined(joining, offer), ..held]),
            [],
          )
      }
    Waiting(passage: passage, ..)
      | Offering(passage: passage, ..)
      | Connected(passage: passage, ..)
      | Leaving(passage: passage, ..)
      | Departed(passage: passage, ..)
      | Resuming(passage: passage, ..)
      | Resumed(passage: passage, ..)
      if passage.handoff.id == joining.handoff.id
    -> #(call, [present(call.phase, clock)])
    Waiting(passage, media) ->
      into(call, Waiting(renewed(passage, joining), media), [
        Log(rejoined_log(call, joining)),
        Present(None, types.PresentWaiting),
      ])
    Offering(passage, offer, ring) -> {
      let phase = Offering(renewed(passage, joining), offer, ring)
      into(call, phase, [
        Log(rejoined_log(call, joining)),
        present(phase, clock),
      ])
    }
    Connected(passage: passage, offer: offer, talk: talking, ..) -> {
      let at = case talking.closing {
        Some(closing) -> closing.at
        None -> clock.now
      }
      let #(call, effects) = begin(call, joining, False, clock)
      #(
        call,
        list.flatten([
          [
            Tell(offer.id, types.Ended(types.Transferred, at)),
            Log(transferred_in(passage, joining)),
          ],
          effects,
          [Present(None, types.PresentWaiting)],
        ]),
      )
    }
    Leaving(..) | Departed(..) | Resuming(..) | Resumed(..) -> {
      let #(call, effects) = begin(call, joining, False, clock)
      #(call, list.append(effects, [Present(None, types.PresentWaiting)]))
    }
  }
}

/// A caller whose actors kept crashing is handed back on `no_agents`
/// through the usual departure, and the shard told they left, quarantined.
/// Nothing is asked of the switch first. Any legs the crashed actors left
/// ringing ring out, and one answered hangs itself up after its
/// `park_timeout`.
fn quarantined(
  call: Call,
  joining: Joining,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case call.phase {
    Idle | Done -> {
      let passage = passage_of(joining, caller.new(joining.joined))
      let #(call, effects) = leave(call, passage, None, Quarantined, clock)
      #(call, [
        Log(
          "QUARANTINED: call "
          <> call.call_id
          <> " in queue "
          <> joining.queue_id
          <> " crashed its actor too often; handing it back on no_agents",
        ),
        ..effects
      ])
    }
    _ -> stay(call)
  }
}

/// Where a call this actor is running stands, as the dispatcher is told it.
fn present(phase: Phase, clock: Clock) -> Effect {
  case phase {
    Offering(offer: offer, ..) ->
      Present(
        Some(offer.id),
        types.PresentRinging(
          offer.agents,
          clock.now + { offer.until_ms - clock.now_ms } / 1000,
          offer.pickup,
        ),
      )
    Connected(offer: offer, agent_id: agent_id, answered_at: at, talk: t, ..) ->
      Present(
        Some(offer.id),
        types.PresentConnected(
          agent_id,
          option.unwrap(t.leg, ""),
          at,
          offer.pickup,
        ),
      )
    Leaving(..) | Departed(..) | Resuming(..) | Resumed(..) | Done ->
      Present(None, types.PresentOver)
    Waiting(..) | Idle | Recovering(..) -> Present(None, types.PresentWaiting)
  }
}

/// Find out where a caller stands: probe their channel and survey the rest.
fn recover(
  call: Call,
  joining: Joining,
  offer: OfferId,
  attempt: Int,
  held: List(Input),
  clock: Clock,
) -> #(Call, List(Effect)) {
  into(
    call,
    Recovering(
      joining: joining,
      offer: offer,
      attempt: attempt,
      probe: None,
      survey: None,
      held: held,
      probe_until_ms: clock.now_ms + recover_ms,
      until_ms: clock.now_ms + recover_ms,
    ),
    [Probe(recovery.probe_id(joining.handoff.id, attempt)), Survey],
  )
}

/// One input while the call is being found out about. The probe's
/// completion and the survey are what it waits for; a ring is refused,
/// because nobody should have asked for one yet; the rest waits until the
/// call has been classified, and is heard then, in the order it came.
fn recovering_step(
  call: Call,
  phase: Phase,
  input: Input,
  clock: Clock,
) -> #(Call, List(Effect)) {
  let assert Recovering(joining: joining, attempt: attempt, held: held, ..) =
    phase
  let hold = fn() { into(call, Recovering(..phase, held: [input, ..held]), []) }
  case input {
    Surveyed(survey) ->
      found(
        call,
        Recovering(
          ..phase,
          survey: Some(survey),
          probe_until_ms: clock.now_ms + probe_ms,
        ),
        clock,
      )
    Event(event) ->
      case
        events.call_id(event) == Some(call.call_id),
        recovery.probe_of(event, recovery.probe_id(joining.handoff.id, attempt))
      {
        True, Some(probe) ->
          found(call, Recovering(..phase, probe: Some(probe)), clock)
        _, _ -> hold()
      }
    Tick -> found(call, phase, clock)
    Joined(other) if other.handoff.id == joining.handoff.id -> stay(call)
    Joined(_) | QueueGone | Positioned(..) -> hold()
    Ring(request) -> #(call, [Tell(request.offer, types.Failed(not_waiting))])
    // Nothing this actor has done yet can be answered, and nothing the
    // dispatcher holds for the caller has been told it yet.
    Rejoined(..)
    | Adopt(_)
    | CallOff(_)
    | Originated(..)
    | Continuing(_)
    | Audited(_)
    | Quarantine(_) -> stay(call)
  }
}

/// Classify the call once the probe and the survey are in, or once their
/// time is up.
fn found(call: Call, phase: Phase, clock: Clock) -> #(Call, List(Effect)) {
  let assert Recovering(
    joining: joining,
    offer: offer,
    attempt: attempt,
    probe: probe,
    survey: survey,
    held: held,
    probe_until_ms: probe_until,
    until_ms: until,
  ) = phase
  let due = case probe, survey {
    Some(_), Some(_) -> True
    None, Some(_) -> clock.now_ms >= probe_until || clock.now_ms >= until
    _, None -> clock.now_ms >= until
  }
  case due {
    False -> into(call, phase, [])
    True -> {
      let found =
        recovery.Found(
          call_id: call.call_id,
          handoff_id: joining.handoff.id,
          joined: joining.joined,
          probe: option.unwrap(probe, recovery.Unanswered),
          survey: option.unwrap(survey, recovery.nothing()),
          now: clock.now,
        )
      let #(finding, stale) = recovery.classify(found)
      case finding, attempt < recover_attempts {
        // What came in cannot say yet. The next try is at the end of this
        // one's time and not at once: a node that asks nobody answers at
        // once, and would spend every try in the same second.
        recovery.Unknown, True ->
          case clock.now_ms >= until {
            True -> recover(call, joining, offer, attempt + 1, held, clock)
            False -> into(call, phase, [])
          }
        recovery.Unknown, False -> {
          let #(call, effects) =
            given_up(call, joining, offer, found, attempt, clock)
          replay(call, effects, held, clock)
        }
        _, _ -> {
          let #(call, effects) =
            rehydrate(call, joining, offer, finding, stale, clock)
          replay(call, effects, held, clock)
        }
      }
    }
  }
}

/// The last try, and still nothing known.
///
/// A record that was not read is taken to be no record, and the caller is
/// where the probe and the switches alone put them (`recovery.unread_as_none`
/// says why that, and not waiting). A caller they cannot place either --
/// and one whose record was read, and it was the switches that could not
/// say -- is taken to be waiting: nothing is hung up on a guess.
fn given_up(
  call: Call,
  joining: Joining,
  offer: OfferId,
  found: recovery.Found,
  attempt: Int,
  clock: Clock,
) -> #(Call, List(Effect)) {
  let tries = int.to_string(attempt)
  let #(finding, stale, why) = case found.survey.record {
    recovery.RecordUnreadable(reason) -> {
      let #(finding, stale) =
        recovery.classify(
          recovery.Found(..found, survey: recovery.unread_as_none(found.survey)),
        )
      #(
        finding,
        stale,
        " could not have its record read in "
          <> tries
          <> " tries ("
          <> reason
          <> ")",
      )
    }
    recovery.RecordRead(_) -> #(
      recovery.Unknown,
      [],
      " could not be found out about after " <> tries <> " tries",
    )
  }
  let #(taken, finding, stale) = case finding {
    recovery.Unknown -> #("taking it to be waiting", recovery.Waiting, [])
    _ -> #("taking it as the switches find it, with no record", finding, stale)
  }
  let log = Log("call " <> call.call_id <> why <> ": " <> taken)
  let #(call, effects) = rehydrate(call, joining, offer, finding, stale, clock)
  #(call, [log, ..effects])
}

/// What arrived while the call was being found out about, heard now, oldest
/// first.
fn replay(
  call: Call,
  effects: List(Effect),
  held: List(Input),
  clock: Clock,
) -> #(Call, List(Effect)) {
  list.fold(list.reverse(held), #(call, effects), fn(acc, input) {
    let #(call, effects) = acc
    let #(call, more) = step(call, input, clock)
    #(call, list.append(effects, more))
  })
}

/// The call as it was found. Whatever the last actor left undone that it
/// would have done is done: the legs the finding does not keep are hung up,
/// a leg that answered is bridged, a departure is taken up again at its
/// barrier, a caller parked alone after their agent's end is hung up. What
/// the queue does not have any more -- a caller gone, handed back, through
/// to somebody else -- is let go.
fn rehydrate(
  call: Call,
  joining: Joining,
  id: OfferId,
  finding: recovery.Finding,
  stale: List(String),
  clock: Clock,
) -> #(Call, List(Effect)) {
  let hang_up = case stale {
    [] -> []
    legs -> [HangUpLegs(legs)]
  }
  let passage = passage_of(joining, caller.new(joining.joined))
  let settle = fn(effects: List(Effect)) {
    into(call, Done, list.append(hang_up, effects))
  }
  case finding {
    recovery.Gone -> settle([Left(types.Hangup)])
    recovery.Finished(agent_id, at, pickup) ->
      settle([
        Present(Some(id), types.PresentConnected(agent_id, "", at, pickup)),
        Tell(id, types.Ended(types.CallerHangup, clock.now)),
        Log(
          "call "
          <> call.call_id
          <> " was answered by "
          <> agent_id
          <> " and its caller is gone: its end went unwatched",
        ),
      ])
    recovery.Closed -> settle([Present(None, types.PresentOver)])
    recovery.Departed(branch) -> settle([Left(cancel_reason(exit_of(branch)))])
    recovery.Moved -> settle([Left(types.Transfer)])
    // A caller the probe reached is parked where the agent's end left them,
    // and is hung up, as the actor that watched the end would have done
    // (`talk.silence`). One it did not reach may be in the callflow a
    // transfer took them to, and is left as they are. Either way the call's
    // end is told now, as the agent's.
    recovery.Talked(agent_id, at, pickup, parked) -> {
      let #(ending, standing) = case parked {
        True -> #([HangUpCaller], "is parked alone now: hanging them up")
        False -> #([], "is through to nobody now")
      }
      settle(
        list.append(ending, [
          Present(Some(id), types.PresentConnected(agent_id, "", at, pickup)),
          Tell(id, types.Ended(types.AgentHangup, clock.now)),
          Log(
            "call "
            <> call.call_id
            <> " was answered by "
            <> agent_id
            <> " and "
            <> standing
            <> "; its end went unwatched",
          ),
        ]),
      )
    }
    recovery.Connected(leg, at) -> {
      let offer = found_offer(id, [leg], clock)
      into(
        call,
        Connected(
          passage: Passage(..passage, caller: caller.connect(passage.caller)),
          offer: offer,
          agent_id: leg.agent_id,
          answered_at: at,
          talk: talk.Talk(
            caller: call.call_id,
            leg: Some(leg.call_id),
            closing: None,
          ),
          until_ms: clock.now_ms + longest_call_ms,
        ),
        list.append(hang_up, [
          // No marks: the last actor marked the caller before it bridged
          // them, and a command sent to a caller in a bridge runs inside
          // the bridge, if at all, holding the agent while it does.
          Present(
            Some(id),
            types.PresentConnected(leg.agent_id, leg.call_id, at, leg.pickup),
          ),
        ]),
      )
    }
    recovery.Departing(branch) -> {
      let exit = exit_of(branch)
      let told = case exit {
        // A deleted queue's departure is the dispatcher's to tell; this one
        // is a dispatcher that has not heard of the caller.
        QueueDeleted -> [Left(types.QueueDeleted)]
        _ -> left(exit)
      }
      let #(call, effects) = leave_with(call, passage, None, exit, told, clock)
      #(call, list.append(hang_up, effects))
    }
    recovery.Parked(leg, at, ring) -> {
      let offer = found_offer(id, [leg, ..ring], clock)
      let passage =
        Passage(
          ..passage,
          caller: caller.offered(
            passage.caller,
            until: ceiling_of(offer, clock),
          ),
        )
      // Long parked, and marked again, on the second the last actor's marks
      // say it answered: the last actor's marks may not have run, and marks
      // that did are only written again. The caller is bridged once the
      // marks are seen to run (`answered`).
      let #(call, marking) =
        answered(call, passage, offer, leg.call_id, True, at, clock)
      #(call, list.flatten([hang_up, [present_ring(offer, clock)], marking]))
    }
    recovery.Ringing(ring) -> {
      let offer = found_offer(id, ring, clock)
      let passage =
        Passage(
          ..passage,
          caller: caller.offered(
            passage.caller,
            until: ceiling_of(offer, clock),
          ),
        )
      into(
        call,
        Offering(passage, offer, Ringing(media.Held)),
        list.append(hang_up, [
          Hold(passage.settings.moh),
          present_ring(offer, clock),
        ]),
      )
    }
    recovery.Waiting | recovery.Unknown ->
      into(
        call,
        Waiting(passage, media.Held),
        list.append(hang_up, [
          Hold(passage.settings.moh),
          Present(None, types.PresentWaiting),
        ]),
      )
  }
}

/// An offer a caller was found in, held under `id`: its legs, every one
/// already seen, and its ring's own deadline.
fn found_offer(id: OfferId, legs: List(recovery.Leg), clock: Clock) -> Offer {
  let deadline =
    list.fold(legs, clock.now, fn(latest, leg) { int.max(latest, leg.deadline) })
  Offer(
    id: id,
    agents: legs |> list.map(fn(leg) { leg.agent_id }) |> list.unique,
    legs: legs
      |> list.map(fn(leg) { #(leg.call_id, leg.agent_id) })
      |> dict.from_list,
    seen: legs |> list.map(fn(leg) { leg.call_id }) |> set.from_list,
    gone: set.new(),
    until_ms: clock.now_ms + { deadline - clock.now } * 1000,
    record: False,
    pickup: list.any(legs, fn(leg) { leg.pickup }),
  )
}

/// The Gregorian second an offer is given up at.
fn ceiling_of(offer: Offer, clock: Clock) -> Int {
  clock.now + { offer.until_ms - clock.now_ms } / 1000
}

fn present_ring(offer: Offer, clock: Clock) -> Effect {
  Present(
    Some(offer.id),
    types.PresentRinging(offer.agents, ceiling_of(offer, clock), offer.pickup),
  )
}

/// The way of leaving a departure's branch names. A mark written before the
/// branch was written beside it names none, and is taken as a timeout.
pub fn exit_of(branch: Option(String)) -> Exit {
  case branch {
    Some("exit_key") -> ExitKey
    Some("no_agent_timeout") -> NobodyTooLong
    Some("no_agents") -> QueueDeleted
    Some(_) | None -> WaitedTooLong
  }
}

/// What the shard is told of each way of leaving.
fn cancel_reason(exit: Exit) -> CancelReason {
  case exit {
    ExitKey -> types.ExitKey
    WaitedTooLong -> types.Timeout
    NobodyTooLong -> types.NoAgentTimeout
    QueueDeleted -> types.QueueDeleted
    Quarantined -> types.Quarantined
  }
}

fn rejoined_log(call: Call, joining: Joining) -> String {
  "call "
  <> call.call_id
  <> " was handed over in queue "
  <> joining.queue_id
  <> " while this actor ran another passage of it"
}

// --- Ringing ------------------------------------------------------------------

/// The dispatcher asks for agents to be rung. Only a caller who is waiting,
/// with nothing ringing, is rung: anything else is answered at once with a
/// failure, which is nobody's miss.
fn rung(
  call: Call,
  request: RingRequest,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case call.phase, request.endpoints {
    Waiting(passage, media), [_, ..] -> {
      let offer =
        Offer(
          id: request.offer,
          agents: request.agents,
          legs: originate.legs_of(request.endpoints),
          seen: set.new(),
          gone: set.new(),
          until_ms: clock.now_ms
            + { request.ring_timeout_s + request.grace_s }
            * 1000,
          record: request.record,
          pickup: request.pickup,
        )
      let passage =
        Passage(
          ..passage,
          caller: caller.offered(
            passage.caller,
            until: clock.now + request.ring_timeout_s + request.grace_s,
          ),
        )
      into(call, Offering(passage, offer, Ringing(media)), [
        Originate(request.offer, request.endpoints, request.ring_timeout_s),
        Tell(request.offer, types.OfferRinging(request.agents)),
      ])
    }
    Waiting(..), [] -> #(call, [Tell(request.offer, types.Failed(no_endpoints))])
    _, _ -> #(call, [Tell(request.offer, types.Failed(not_waiting))])
  }
}

/// The failure an offer with nothing to ring is answered with.
pub const no_endpoints = "no_endpoints"

/// The failure an offer for a caller who is not waiting is answered with.
pub const not_waiting = "not_waiting"

/// The failure an offer called off before anybody answered ends in.
pub const called_off_reason = "called_off"

/// The failure an offer whose ring ran out with none of its legs seen ends
/// in.
pub const nothing_rang = "nothing_rang"

/// The failure an offer whose answered leg never showed bridged ends in.
pub const bridge_failed = "bridge_failed"

/// The ring is over without an answer: the dispatcher is told how, and the
/// caller goes back to waiting as they were, their media untouched.
fn ring_over(
  call: Call,
  passage: Passage,
  offer: Offer,
  media: Media,
  reply: OfferReply,
  clock: Clock,
) -> #(Call, List(Effect)) {
  into(
    call,
    Waiting(
      Passage(..passage, caller: caller.offer_over(passage.caller, clock.now)),
      media,
    ),
    [Tell(offer.id, reply)],
  )
}

/// A leg answered while the phones rang, and nothing had decided the call
/// before: it is that agent's, and from here no key, clock or call-off
/// takes the caller away. The answer is heard first in one of three ways:
/// the leg's `CHANNEL_ANSWER`; its `park`, which only an answered leg runs,
/// since one channel's events can come out of order; or `ecallmgr`'s word
/// that its originate succeeded, which comes by another road. A node taking
/// the caller over may also find the leg long parked. All but the first
/// are a leg already `parked`. The answer is dated `answered_at`: the
/// second it is heard, or for a leg found parked, the second the last
/// actor's marks give (`recovery.Parked`).
///
/// Whichever it is, the caller's channel is marked with the agent and the
/// second while they are still on hold: the marks are on the caller's CDR,
/// and they are what a node taking the call over dates the answer by. A
/// `set` sent with `Insert-At: now` is not run as `ecallmgr` takes it,
/// though. The switch queues it on the caller's channel, which runs it the
/// next time it looks, within a frame of its media, and the bridge's flush
/// empties that queue (`uuid_break <caller> all`). Marks sent in the same
/// breath as the bridge were lost whenever the flush got there first. So a
/// `noop` goes at once behind the marks (`Confirm`): the channel runs what
/// is queued so in the order it came, and the completion of the `noop` says
/// the marks have run. The caller is bridged once that completion and the
/// leg's `park` have both come, or at `park_wait_ms`, whatever has
/// (`Parking`).
fn answered(
  call: Call,
  passage: Passage,
  offer: Offer,
  leg: String,
  parked: Bool,
  answered_at: Int,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case dict.get(offer.legs, leg) {
    Error(Nil) -> stay(call)
    Ok(agent_id) ->
      into(
        call,
        Offering(
          passage,
          Offer(..offer, seen: set.insert(offer.seen, leg)),
          Parking(
            leg: leg,
            agent_id: agent_id,
            answered_at: answered_at,
            parked: parked,
            marked: False,
            until_ms: clock.now_ms + park_wait_ms,
          ),
        ),
        [answer_marks(agent_id, answered_at), Confirm(marks_id(leg))],
      )
  }
}

/// The `Msg-ID` of the `noop` that shows an answer's marks have run: one
/// per leg, which only ever answers once.
pub fn marks_id(leg: String) -> String {
  "callcenter-marked-" <> leg
}

/// One of the two things `Parking` waits for has come, and `ring` says so:
/// the caller is bridged once both have, and waits on until then.
fn waited_for(
  call: Call,
  passage: Passage,
  offer: Offer,
  ring: Ring,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case ring {
    Parking(leg: leg, answered_at: at, parked: True, marked: True, ..) ->
      bridge(call, passage, offer, leg, at, clock)
    _ -> into(call, Offering(passage, offer, ring), [])
  }
}

/// Bridge the caller to a leg that answered at `answered_at` and is parked.
/// Only ever out of `Parking`: the answer's marks went out in an earlier
/// step, and this one's flush cannot be what throws them away.
fn bridge(
  call: Call,
  passage: Passage,
  offer: Offer,
  leg: String,
  answered_at: Int,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case dict.get(offer.legs, leg) {
    Error(Nil) -> stay(call)
    Ok(agent_id) ->
      into(
        call,
        Offering(
          passage,
          Offer(..offer, seen: set.insert(offer.seen, leg)),
          Connecting(
            leg: leg,
            agent_id: agent_id,
            answered_at: answered_at,
            until_ms: clock.now_ms + connect_ms,
          ),
        ),
        [Bridge(leg)],
      )
  }
}

/// The marks of an answer on the caller's channel: who, and when. They are
/// on the caller's CDR, and they are what a node taking the call over dates
/// the answer by.
fn answer_marks(agent_id: String, at: Int) -> Effect {
  Mark([
    #(agent_var, doc.String(agent_id)),
    #(answered_var, doc.Int(at)),
  ])
}

const agent_var = "Agent-ID"

const answered_var = "Queue-Answered-Timestamp"

/// The marks of an answer, by name, in the order they are sent.
const answer_vars = [agent_var, answered_var]

/// Whether an event is a leg starting `park`: its originate is done with
/// it, and a bridge now stays.
fn is_parked(event: Value) -> Bool {
  events.event_name(event) == Some("CHANNEL_EXECUTE")
  && doc.get_string(event, ["Application-Name"]) == Ok("park")
}

/// The agent's answered leg went before the caller was through to it. The
/// answer decided the call, so it is an answered call that the agent ended:
/// the dispatcher hears the answer and its end, and the caller is hung up,
/// as a connected caller is when the agent hangs up on them.
fn agent_hung_up(
  call: Call,
  offer: Offer,
  leg: String,
  agent_id: String,
  answered_at: Int,
  clock: Clock,
) -> #(Call, List(Effect)) {
  into(call, Done, [
    HangUpCaller,
    Tell(offer.id, types.Answered(agent_id, leg, answered_at)),
    Tell(offer.id, types.Ended(types.AgentHangup, clock.now)),
  ])
}

/// The caller hung up after an agent answered them and before they were
/// through: an answered call that the caller ended. The agent's leg is
/// hung up.
fn caller_hung_up(
  call: Call,
  offer: Offer,
  leg: String,
  agent_id: String,
  answered_at: Int,
  clock: Clock,
) -> #(Call, List(Effect)) {
  into(call, Done, [
    HangUpLegs([leg]),
    Tell(offer.id, types.Answered(agent_id, leg, answered_at)),
    Tell(offer.id, types.Ended(types.CallerHangup, clock.now)),
  ])
}

/// The caller's own channel says it is through to the leg: the call is
/// connected, and the queue's part of it -- the recording, the dispatcher's
/// answer -- follows. The marks went on at the answer.
fn connected(
  call: Call,
  passage: Passage,
  offer: Offer,
  leg: String,
  agent_id: String,
  answered_at: Int,
  clock: Clock,
) -> #(Call, List(Effect)) {
  let recording = case offer.record {
    True -> [Record(agent_id, answered_at)]
    False -> []
  }
  into(
    call,
    Connected(
      passage: Passage(..passage, caller: caller.connect(passage.caller)),
      offer: offer,
      agent_id: agent_id,
      answered_at: answered_at,
      talk: talk.Talk(caller: call.call_id, leg: Some(leg), closing: None),
      until_ms: clock.now_ms + longest_call_ms,
    ),
    list.append(recording, [
      Tell(offer.id, types.Answered(agent_id, leg, answered_at)),
    ]),
  )
}

/// The answered leg did not become the caller's: it went, or the bridge
/// never showed. The leg is hung up, the dispatcher is told, and the caller
/// -- whose hold the bridge flushed -- is put back on it.
fn not_connected(
  call: Call,
  passage: Passage,
  offer: Offer,
  leg: String,
  reason: String,
  clock: Clock,
) -> #(Call, List(Effect)) {
  into(
    call,
    Waiting(
      Passage(..passage, caller: caller.offer_over(passage.caller, clock.now)),
      media.Held,
    ),
    [
      HangUpLegs([leg]),
      Tell(offer.id, types.Failed(reason)),
      Hold(passage.settings.moh),
    ],
  )
}

// --- Leaving --------------------------------------------------------------------

/// The branch a callflow continues on for each way of leaving.
pub fn branch(exit: Exit) -> String {
  case exit {
    ExitKey -> "exit_key"
    WaitedTooLong -> "timeout"
    NobodyTooLong -> "no_agent_timeout"
    QueueDeleted | Quarantined -> "no_agents"
  }
}

/// What the shard is told for each way of leaving, when it is the caller's
/// to tell: a deleted queue is the dispatcher's own doing.
fn left(exit: Exit) -> List(Effect) {
  case exit {
    ExitKey -> [Left(types.ExitKey)]
    WaitedTooLong -> [Left(types.Timeout)]
    NobodyTooLong -> [Left(types.NoAgentTimeout)]
    QueueDeleted -> []
    Quarantined -> [Left(types.Quarantined)]
  }
}

/// The `Msg-ID` of a passage's barrier.
pub fn barrier_id(handoff: Handoff) -> String {
  "callcenter-departure-" <> handoff.id
}

/// The mark a departing caller's channel carries: the passage's id.
pub const departing_var = recovery.departing_var

/// The branch a departing caller leaves on, marked beside it, so that a
/// node that takes the caller over half way out hands them back on it.
pub const departing_branch_var = recovery.departing_branch_var

/// The caller leaves the queue on a branch. A ring still going is called
/// off -- every leg hung up, and any that turns up later too -- and the
/// departure begins: the mark, then the barrier.
fn leave(
  call: Call,
  passage: Passage,
  ringing: Option(Offer),
  exit: Exit,
  clock: Clock,
) -> #(Call, List(Effect)) {
  leave_with(call, passage, ringing, exit, left(exit), clock)
}

/// A departure, with what the shard is told of it.
fn leave_with(
  call: Call,
  passage: Passage,
  ringing: Option(Offer),
  exit: Exit,
  told: List(Effect),
  clock: Clock,
) -> #(Call, List(Effect)) {
  let #(call, calling_off) = case ringing {
    None -> #(call, [])
    Some(offer) -> {
      // The shard's settle tells the dispatcher of a caller leaving; only a
      // deleted queue's ring is the dispatcher's to hear the end of.
      let tell = case exit {
        QueueDeleted -> Some(types.Failed(called_off_reason))
        _ -> None
      }
      recall(call, offer, tell)
    }
  }
  let barrier = barrier_id(passage.handoff)
  into(
    call,
    Leaving(
      passage: passage,
      exit: exit,
      barrier: barrier,
      until_ms: clock.now_ms + barrier_ms,
    ),
    list.flatten([
      calling_off,
      told,
      [
        Mark([
          #(departing_var, doc.String(passage.handoff.id)),
          #(departing_branch_var, doc.String(branch(exit))),
        ]),
        Barrier(barrier),
      ],
    ]),
  )
}

/// The barrier has completed, or will not: the callflow is told to go on.
fn depart(
  call: Call,
  passage: Passage,
  exit: Exit,
  clock: Clock,
) -> #(Call, List(Effect)) {
  into(
    call,
    Departed(
      passage: passage,
      exit: exit,
      attempts: 1,
      until_ms: clock.now_ms + continue_ack_ms,
    ),
    [Continue(passage.handoff, branch(exit))],
  )
}

/// The action has the caller back. Heard after a resume, it is the action
/// whose word was only slow: the caller is its, and is not resumed again.
fn continuing(call: Call, handoff_id: String) -> #(Call, List(Effect)) {
  case call.phase {
    Departed(passage: passage, ..)
      | Resuming(passage: passage, ..)
      | Resumed(passage: passage, ..)
      if passage.handoff.id == handoff_id
    -> into(call, Done, [])
    _ -> stay(call)
  }
}

// --- Calling off ----------------------------------------------------------------

/// Hang an offer's legs up and keep watching for any of them that turns up
/// late: an originate asked for before the hang-up can create a leg after
/// it.
fn recall(
  call: Call,
  offer: Offer,
  tell: Option(OfferReply),
) -> #(Call, List(Effect)) {
  recall_deserted(call, offer, tell, None)
}

fn recall_deserted(
  call: Call,
  offer: Offer,
  tell: Option(OfferReply),
  deserted: Option(Desertion),
) -> #(Call, List(Effect)) {
  // Every leg is hung up now, so only one seen after this is late.
  let offer = Offer(..offer, seen: offer.gone)
  #(
    Call(..call, recalls: [
      Recall(offer, tell, heard: False, deserted: deserted),
      ..call.recalls
    ]),
    [HangUpLegs(dict.keys(offer.legs) |> list.sort(string.compare))],
  )
}

/// The dispatcher calls an offer off: the agent was released, a pickup let
/// go. A ring is called off, and the dispatcher hears `called_off` once it
/// is over; an answer already taken stands.
fn called_off(
  call: Call,
  offer_id: OfferId,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case call.phase {
    Offering(passage, offer, Ringing(media)) if offer.id == offer_id -> {
      let #(call, effects) =
        recall(call, offer, Some(types.Failed(called_off_reason)))
      let passage =
        Passage(..passage, caller: caller.offer_over(passage.caller, clock.now))
      into(call, Waiting(passage, media), effects)
    }
    _ -> stay(call)
  }
}

/// The caller's queue was deleted: they leave it on `no_agents`, a ring
/// going for them called off. A connected call goes on.
fn queue_gone(call: Call, clock: Clock) -> #(Call, List(Effect)) {
  case call.phase {
    Waiting(passage, _) -> leave(call, passage, None, QueueDeleted, clock)
    Offering(passage, offer, Ringing(_)) ->
      leave(call, passage, Some(offer), QueueDeleted, clock)
    _ -> stay(call)
  }
}

/// What an input does to the offers being called off, before the call's own
/// phase sees it: a late leg of one of them is hung up as it appears, and
/// the originate's word is noted. `True` when the input was theirs.
fn recalling(call: Call, input: Input, clock: Clock) -> #(Call, Bool) {
  case input {
    Event(event) ->
      case events.call_id(event) {
        Some(leg) ->
          case find_recall(call.recalls, leg) {
            Some(_) -> #(recall_event(call, leg, event, clock), True)
            None -> #(call, False)
          }
        None -> #(call, False)
      }
    Originated(offer_id, _reply) ->
      case list.any(call.recalls, fn(recall) { recall.offer.id == offer_id }) {
        True -> #(
          Call(
            ..call,
            recalls: list.map(call.recalls, fn(recall) {
              case recall.offer.id == offer_id {
                True -> Recall(..recall, heard: True)
                False -> recall
              }
            }),
          ),
          True,
        )
        False -> #(call, False)
      }
    _ -> #(call, False)
  }
}

fn find_recall(recalls: List(Recall), leg: String) -> Option(Recall) {
  list.find(recalls, fn(recall) { dict.has_key(recall.offer.legs, leg) })
  |> option.from_result
}

/// One event of a leg of an offer being called off.
fn recall_event(call: Call, leg: String, event: Value, clock: Clock) -> Call {
  let update = fn(recall: Recall) {
    case dict.get(recall.offer.legs, leg) {
      Error(Nil) -> recall
      Ok(agent_id) -> {
        let offer = recall.offer
        let offer = case events.event_name(event) {
          Some("CHANNEL_DESTROY") ->
            Offer(..offer, gone: set.insert(offer.gone, leg))
          _ -> Offer(..offer, seen: set.insert(offer.seen, leg))
        }
        Recall(
          ..recall,
          offer: offer,
          deserted: option.map(recall.deserted, answered_first(
            _,
            leg,
            agent_id,
            event,
            clock,
          )),
        )
      }
    }
  }
  Call(..call, recalls: list.map(call.recalls, update))
}

/// A leg of a ring its caller deserted answering. The first answer that
/// came before the caller's end is the call's: the switch dates both, on
/// the one clock of the caller's switch, where the legs start. An answer
/// either event does not date is taken to have come first: the legs were
/// hung up the moment the caller's end was heard, so it came within the
/// time that took.
fn answered_first(
  desertion: Desertion,
  leg: String,
  agent_id: String,
  event: Value,
  clock: Clock,
) -> Desertion {
  case desertion.answer, is_answer(event) {
    None, True ->
      case event_us(event), desertion.at_us {
        Some(answered), Some(left) if answered > left -> desertion
        _, _ ->
          Desertion(
            ..desertion,
            answer: Some(#(leg, agent_id, int.min(clock.now, desertion.at))),
          )
      }
    _, _ -> desertion
  }
}

/// Whether a leg's event says it answered: its answer, or the `park` its
/// originate runs on an answered leg.
fn is_answer(event: Value) -> Bool {
  events.event_name(event) == Some("CHANNEL_ANSWER") || is_parked(event)
}

/// When the switch says an event happened: `Event-Timestamp`, microseconds
/// on the switch's clock, which `mod_com_kazoo` puts on every event.
fn event_us(event: Value) -> Option(Int) {
  case doc.get(event, ["Event-Timestamp"]) {
    Ok(doc.Int(us)) -> Some(us)
    Ok(doc.Float(us)) -> Some(float.truncate(us))
    _ -> None
  }
}

/// What the dispatcher and the shard are told once a deserted ring is
/// decided: an answered call the caller ended, or a caller who left.
fn desertion_decided(offer: Offer, desertion: Desertion) -> List(Effect) {
  case desertion.answer {
    Some(#(leg, agent_id, at)) -> [
      Log(
        "call "
        <> offer.id.call_id
        <> ": the caller hung up as "
        <> agent_id
        <> " answered; an answered call the caller ended",
      ),
      Tell(offer.id, types.Answered(agent_id, leg, at)),
      Tell(offer.id, types.Ended(types.CallerHangup, desertion.at)),
    ]
    None -> [Left(types.Hangup)]
  }
}

/// The late legs that have to be hung up, and the offers whose recall is
/// over: the originate has said so and no leg of theirs is up, or their
/// ring's deadline has passed.
fn settle_recalls(call: Call, clock: Clock) -> #(Call, List(Effect)) {
  let #(kept, effects) =
    list.fold(call.recalls, #([], []), fn(acc, recall) {
      let #(kept, effects) = acc
      let offer = recall.offer
      let up = set.difference(offer.seen, offer.gone) |> set.to_list
      let over = { recall.heard && up == [] } || clock.now_ms >= offer.until_ms
      // A ring its caller deserted is decided once it is over, or once it
      // has waited `desertion_ms`, and its legs are still hung up as they
      // turn up after that.
      let #(recall, decided) = case recall.deserted {
        Some(desertion) if over || clock.now_ms >= desertion.until_ms -> #(
          Recall(..recall, deserted: None),
          desertion_decided(offer, desertion),
        )
        _ -> #(recall, [])
      }
      case over {
        True -> {
          let told = case recall.tell {
            Some(reply) -> [Tell(offer.id, reply)]
            None -> []
          }
          #(kept, list.flatten([effects, decided, told]))
        }
        False -> {
          // Every leg seen up since the hang-up went out is hung up again:
          // `uuid_kill` of a leg that has gone does nothing.
          let late = case up {
            [] -> []
            legs -> [HangUpLegs(list.sort(legs, string.compare))]
          }
          #(
            [Recall(..recall, offer: Offer(..offer, seen: offer.gone)), ..kept],
            list.flatten([effects, decided, late]),
          )
        }
      }
    })
  #(Call(..call, recalls: list.reverse(kept)), effects)
}

// --- Positions -----------------------------------------------------------------

fn positioned(
  call: Call,
  position: Option(Int),
  waiting: Option(Int),
  available: Option(Int),
  clock: Clock,
) -> #(Call, List(Effect)) {
  let place = fn(passage: Passage) {
    Passage(
      ..passage,
      caller: caller.positioned(
        passage.caller,
        position: position,
        waiting: waiting,
        agents_available: available,
        at: clock.now,
      ),
    )
  }
  case call.phase {
    Waiting(passage, media) -> into(call, Waiting(place(passage), media), [])
    Offering(passage, offer, ring) ->
      into(call, Offering(place(passage), offer, ring), [])
    _ -> stay(call)
  }
}

// --- Events -------------------------------------------------------------------------

/// Whose event it is.
type From {
  FromCaller
  FromLeg(leg: String)
  FromNobody
}

fn from(call: Call, event: Value) -> From {
  case events.call_id(event) {
    Some(id) if id == call.call_id -> FromCaller
    Some(id) ->
      case call.phase {
        Offering(offer: offer, ..) | Connected(offer: offer, ..) ->
          case dict.has_key(offer.legs, id) {
            True -> FromLeg(id)
            False -> FromNobody
          }
        _ -> FromNobody
      }
    None -> FromNobody
  }
}

fn heard(call: Call, event: Value, clock: Clock) -> #(Call, List(Effect)) {
  let name = events.event_name(event)
  case call.phase, from(call, event), name {
    // The caller's channel is gone, whatever the call was doing.
    Connected(..), _, _ -> talking(call, event, clock)
    _, FromCaller, Some("CHANNEL_DESTROY") ->
      caller_gone(call, event_us(event), clock)

    Waiting(passage, media), FromCaller, _ ->
      waiting_event(call, passage, media, None, event, clock)
    Offering(passage, offer, Ringing(media)), FromCaller, _ ->
      waiting_event(call, passage, media, Some(offer), event, clock)
    Offering(passage, offer, Ringing(media)), FromLeg(leg), _ ->
      leg_event(call, passage, offer, media, leg, event, clock)

    Offering(passage, offer, Parking(..) as parking), FromLeg(other), _
      if other == parking.leg
    ->
      case events.event_name(event), is_parked(event) {
        _, True ->
          waited_for(
            call,
            passage,
            offer,
            Parking(..parking, parked: True),
            clock,
          )
        Some("CHANNEL_DESTROY"), _ ->
          agent_hung_up(
            call,
            offer,
            parking.leg,
            parking.agent_id,
            parking.answered_at,
            clock,
          )
        _, _ -> stay(call)
      }
    // The `noop` behind the answer's marks has completed: they have run.
    Offering(passage, offer, Parking(..) as parking),
      FromCaller,
      Some("CHANNEL_EXECUTE_COMPLETE")
    ->
      case is_noop_done(event, marks_id(parking.leg)) {
        True ->
          waited_for(
            call,
            passage,
            offer,
            Parking(..parking, marked: True),
            clock,
          )
        False -> stay(call)
      }
    // The caller bridged while their agent's leg is being parked: to that
    // leg, they are through. Only a call found parked sees this -- the
    // last actor bridged them, and died before the new actor's survey
    // listed it -- since nothing else bridges a caller to their own leg.
    // It marked them before it bridged them, and the marks this actor sent
    // meanwhile are not waited for. To anybody else's, something that is
    // not this queue took the caller while their agent's leg was parked.
    Offering(passage, offer, Parking(..) as parking),
      FromCaller,
      Some("CHANNEL_BRIDGE")
    ->
      case events.other_leg_call_id(event) {
        Some(other) if other == parking.leg ->
          connected(
            call,
            passage,
            offer,
            parking.leg,
            parking.agent_id,
            parking.answered_at,
            clock,
          )
        _ -> moved(call, Some(offer))
      }

    Offering(passage, offer, Connecting(leg, agent_id, answered_at, _)),
      FromCaller,
      Some("CHANNEL_BRIDGE")
    ->
      case events.other_leg_call_id(event) {
        Some(other) if other == leg ->
          connected(call, passage, offer, leg, agent_id, answered_at, clock)
        // Somebody else's leg: the caller was taken away by something that
        // is not this queue.
        _ -> moved(call, Some(offer))
      }
    Offering(
      _,
      offer,
      Connecting(leg: leg, agent_id: agent, answered_at: at, ..),
    ),
      FromLeg(other),
      Some("CHANNEL_DESTROY")
      if other == leg
    -> agent_hung_up(call, offer, leg, agent, at, clock)

    Leaving(passage, exit, barrier, _), FromCaller, _ ->
      case is_noop_done(event, barrier) {
        True -> depart(call, passage, exit, clock)
        False -> stay(call)
      }

    Resuming(passage, exit, probe, _), FromCaller, _ ->
      case recovery.probe_of(event, probe) {
        Some(recovery.Answered(marks)) ->
          case handed_back(marks, passage) {
            True ->
              into(call, Done, [
                Log(
                  "call "
                  <> call.call_id
                  <> ": its callflow took it back, and only the word was lost",
                ),
              ])
            False -> resume(call, passage, exit, clock)
          }
        _ -> stay(call)
      }

    Resumed(passage, exit, attempt, probe, _), FromCaller, _ ->
      case handed_back(event, passage), probe {
        True, _ ->
          into(call, Done, [
            Log(
              "call "
              <> call.call_id
              <> ": its resume at "
              <> branch(exit)
              <> " was taken",
            ),
          ])
        False, Some(probe) ->
          case recovery.probe_of(event, probe) {
            Some(_) ->
              not_taken(
                call,
                passage,
                exit,
                attempt,
                "its channel carries no mark of it",
                clock,
              )
            None -> stay(call)
          }
        False, None -> stay(call)
      }

    _, _, _ -> stay(call)
  }
}

/// Whether an event of the caller's channel carries the mark of this
/// passage handed back, `Queue-Departed` naming it. The queue's action
/// writes it as it takes the caller back, and `callcenter_departed` writes
/// it first thing in a resumed flow. Every event `mod_com_kazoo` publishes
/// carries the channel's variables as they are then, so the first event
/// after the mark shows it, whether a probe's completion or anything the
/// flow does.
fn handed_back(event: Value, passage: Passage) -> Bool {
  events.custom_channel_var(event, recovery.departed_var)
  == Some(passage.handoff.id)
}

/// Whether an event is the completion of the `noop` with this `Msg-ID`.
pub fn is_noop_done(event: Value, msg_id: String) -> Bool {
  events.event_name(event) == Some("CHANNEL_EXECUTE_COMPLETE")
  && doc.get_string(event, ["Application-Name"]) == Ok("noop")
  && doc.get_string(event, ["Application-Response"]) == Ok(msg_id)
}

/// One of the caller's own events while they wait, with or without a ring
/// going: their keys, their media, and anything that says they are
/// somebody else's now.
fn waiting_event(
  call: Call,
  passage: Passage,
  media: Media,
  ringing: Option(Offer),
  event: Value,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case events.event_name(event) {
    Some("DTMF") ->
      case doc.get_string(event, ["DTMF-Digit"]) {
        Ok(digit) ->
          case list.contains(passage.settings.exit_keys, digit) {
            True -> leave(call, passage, ringing, ExitKey, clock)
            False -> stay(call)
          }
        Error(Nil) -> stay(call)
      }
    Some("CHANNEL_BRIDGE") -> moved(call, ringing)
    _ -> {
      let #(now_playing, cue) = media.on_event(media, event, clock.now)
      let phase = case ringing {
        None -> Waiting(passage, now_playing)
        Some(offer) -> Offering(passage, offer, Ringing(now_playing))
      }
      into(call, phase, cued(passage, cue))
    }
  }
}

/// One event of one of the ringing offer's legs.
fn leg_event(
  call: Call,
  passage: Passage,
  offer: Offer,
  media: Media,
  leg: String,
  event: Value,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case events.event_name(event), is_parked(event) {
    // Parked before its answer was heard -- one channel's events can come
    // out of order -- and `park` only ever runs on an answered leg.
    _, True -> answered(call, passage, offer, leg, True, clock.now, clock)
    Some("CHANNEL_ANSWER"), _ ->
      answered(call, passage, offer, leg, False, clock.now, clock)
    Some("CHANNEL_DESTROY"), _ -> {
      let offer =
        Offer(
          ..offer,
          seen: set.insert(offer.seen, leg),
          gone: set.insert(offer.gone, leg),
        )
      case set.size(offer.gone) == dict.size(offer.legs) {
        // Every leg the offer named has gone and none answered: the ring is
        // over, as the last of them says.
        True ->
          ring_over(
            call,
            passage,
            offer,
            media,
            talk.miss_reply(talk.miss(event), offer.agents),
            clock,
          )
        False -> into(call, Offering(passage, offer, Ringing(media)), [])
      }
    }
    _, _ ->
      into(
        call,
        Offering(
          passage,
          Offer(..offer, seen: set.insert(offer.seen, leg)),
          Ringing(media),
        ),
        [],
      )
  }
}

/// `ecallmgr`'s word on the ringing offer's originate: success names the leg
/// that answered, which is the answer if its own event has not come yet; an
/// error is the end of the ring, and names the cause.
fn originated(
  call: Call,
  offer_id: OfferId,
  reply: Value,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case call.phase {
    // The originate has finished with its leg, which is parked.
    Offering(passage, offer, Parking(..) as parking) if offer.id == offer_id ->
      case originate_answered(reply) {
        Some(answered) if answered == parking.leg ->
          waited_for(
            call,
            passage,
            offer,
            Parking(..parking, parked: True),
            clock,
          )
        _ -> stay(call)
      }
    Offering(passage, offer, Ringing(media)) if offer.id == offer_id ->
      case originate_answered(reply) {
        // The leg's answer is not heard yet, and its originate is done with
        // it: it answered, and is parked.
        Some(leg) -> answered(call, passage, offer, leg, True, clock.now, clock)
        None ->
          ring_over(
            call,
            passage,
            offer,
            media,
            talk.miss_reply(talk.miss_of(originate_cause(reply)), offer.agents),
            clock,
          )
      }
    _ -> stay(call)
  }
}

/// The leg an `originate_resp` says answered.
fn originate_answered(reply: Value) -> Option(String) {
  case
    doc.get_string(reply, ["Event-Category"]),
    doc.get_string(reply, ["Application-Response"]),
    doc.get_string(reply, ["Call-ID"])
  {
    Ok("error"), _, _ -> None
    _, Ok("SUCCESS"), Ok(leg) -> Some(leg)
    _, _, _ -> None
  }
}

/// The cause an originate's error names: its `Error-Message`, without the
/// `-ERR ` the switch puts in front of it.
fn originate_cause(reply: Value) -> String {
  case doc.get_string(reply, ["Error-Message"]) {
    Ok("-ERR " <> cause) -> string.trim(cause)
    Ok(cause) -> string.trim(cause)
    Error(Nil) -> "UNSPECIFIED"
  }
}

/// The caller's channel went, at `at_us` on the switch's clock when its
/// event said. A ring going for them is called off, and nothing more is
/// sent. The shard is told they left -- unless the call was already on its
/// way out, and told it then -- at once when nobody was rung, and once the
/// ring called off is decided when somebody was (`Desertion`): an agent may
/// have answered them just before. After an answer the call is the
/// agent's, and its end is an answered call's (`caller_hung_up`).
fn caller_gone(
  call: Call,
  at_us: Option(Int),
  clock: Clock,
) -> #(Call, List(Effect)) {
  case call.phase {
    Waiting(..) -> into(call, Done, [Left(types.Hangup)])
    Offering(_, offer, Ringing(_)) -> {
      let #(call, effects) =
        recall_deserted(
          call,
          offer,
          None,
          Some(Desertion(
            at_us: at_us,
            at: clock.now,
            answer: None,
            until_ms: clock.now_ms + desertion_ms,
          )),
        )
      into(call, Done, effects)
    }
    Offering(
      _,
      offer,
      Connecting(leg: leg, agent_id: agent, answered_at: at, ..),
    )
    | Offering(
        _,
        offer,
        Parking(leg: leg, agent_id: agent, answered_at: at, ..),
      ) -> caller_hung_up(call, offer, leg, agent, at, clock)
    _ -> into(call, Done, [])
  }
}

/// The caller is through to somebody this queue did not ring -- a pickup,
/// an attended transfer -- and is theirs now: the queue lets them go and
/// sends nothing more.
fn moved(call: Call, ringing: Option(Offer)) -> #(Call, List(Effect)) {
  let #(call, calling_off) = case ringing {
    Some(offer) -> recall(call, offer, None)
    None -> #(call, [])
  }
  into(
    call,
    Done,
    list.append(calling_off, [
      Left(types.Transfer),
      Log("call " <> call.call_id <> " was taken out of the queue by a bridge"),
    ]),
  )
}

/// One event of a connected call: `call/talk` reads the end of the bridge,
/// and whether it was a transfer.
fn talking(call: Call, event: Value, clock: Clock) -> #(Call, List(Effect)) {
  case call.phase {
    Connected(offer: offer, talk: conversation, ..) as connection ->
      case talk.heard(conversation, event, clock.now, clock.now_ms) {
        talk.Talking(conversation) ->
          into(call, Connected(..connection, talk: conversation), [])
        outcome ->
          talked(
            call,
            offer,
            conversation,
            outcome,
            leg_moved(conversation, event),
          )
      }
    _ -> stay(call)
  }
}

/// Whether an event says the agent's leg itself is being transferred: the
/// transfer's `CHANNEL_TRANSFEREE` on the leg, rather than on the caller.
fn leg_moved(conversation: talk.Talk, event: Value) -> Bool {
  events.event_name(event) == Some("CHANNEL_TRANSFEREE")
  && option.is_some(conversation.leg)
  && events.call_id(event) == conversation.leg
}

/// A connected call is over. The agent's leg is hung up, which does nothing
/// to a leg that has gone and makes sure of one the switch left, and the
/// caller only when the agent's leg went and nothing said it was a
/// transfer.
///
/// A transfer's leg is hung up too. The agent passed the caller on, and
/// their leg has nothing more to do, but the switch does not end it: the
/// bridge put `park_after_bridge` on both channels (`Park-After-Pickup`),
/// so a leg whose caller was transferred away parks. The lab of 2026-09-27
/// (e2e-260927-cca5) had an agent's leg parked for 45 minutes after a
/// blind transfer, and the agent's phone busy with it. The hang-up cannot
/// cut the caller off on the way to the transfer's target: the caller parks
/// too when their bridge ends, and a transfer takes a channel from park as
/// from anywhere. Only a leg the transfer is moving (`leg_moved`) is left
/// alone.
fn talked(
  call: Call,
  offer: Offer,
  conversation: talk.Talk,
  outcome: talk.Heard,
  moved: Bool,
) -> #(Call, List(Effect)) {
  let legs = case conversation.leg, outcome, moved {
    Some(_), talk.Over(types.Transferred, _), True -> []
    Some(leg), _, _ -> [HangUpLegs([leg])]
    None, _, _ -> []
  }
  case outcome {
    talk.Talking(_) -> stay(call)
    talk.Over(result, at) ->
      into(
        call,
        Done,
        list.append(legs, [Tell(offer.id, types.Ended(result, at))]),
      )
    talk.HangUp(result, at) ->
      into(
        call,
        Done,
        list.flatten([
          legs,
          [HangUpCaller, Tell(offer.id, types.Ended(result, at))],
        ]),
      )
  }
}

// --- The clock ----------------------------------------------------------------------

fn ticked(call: Call, clock: Clock) -> #(Call, List(Effect)) {
  case call.phase {
    Waiting(passage, media) -> waited(call, passage, media, None, clock)
    Offering(passage, offer, Ringing(media)) ->
      case clock.now_ms >= offer.until_ms {
        True -> {
          // The ring ran out and the switch never said so: the legs are hung
          // up, and it is the agents' miss only if one of their phones was
          // seen ringing.
          let reply = case set.is_empty(offer.seen) {
            True -> types.Failed(nothing_rang)
            False -> types.OfferNoAnswer(offer.agents)
          }
          let #(call, effects) =
            ring_over(call, passage, offer, media, reply, clock)
          #(call, [
            HangUpLegs(dict.keys(offer.legs) |> list.sort(string.compare)),
            ..effects
          ])
        }
        False -> waited(call, passage, media, Some(offer), clock)
      }
    Offering(passage, offer, Connecting(leg: leg, until_ms: until, ..)) ->
      case clock.now_ms >= until {
        True -> not_connected(call, passage, offer, leg, bridge_failed, clock)
        False -> stay(call)
      }
    Offering(passage, offer, Parking(..) as parking) ->
      case clock.now_ms >= parking.until_ms {
        // Parked by now, whether or not its `park` was heard. Marks not
        // seen to run by now are waited for no longer: the agent's leg is
        // on its own until the bridge. The bridge's flush may throw them
        // away, and the caller's CDR be without the agent.
        True -> {
          let #(call, bridging) =
            bridge(
              call,
              passage,
              offer,
              parking.leg,
              parking.answered_at,
              clock,
            )
          case parking.marked {
            True -> #(call, bridging)
            False -> #(call, [
              Log(
                "call "
                <> call.call_id
                <> ": the answer's marks were not seen to run in "
                <> int.to_string(park_wait_ms)
                <> " ms; bridging to "
                <> parking.leg
                <> " all the same",
              ),
              ..bridging
            ])
          }
        }
        False -> stay(call)
      }
    Connected(offer: offer, talk: conversation, until_ms: until, ..) -> {
      // The end of the bridge waited a moment to see whether it was a
      // transfer, and nothing said it was; or the call ran past the longest
      // a call is watched.
      let due = case conversation.closing {
        Some(closing) -> clock.now_ms >= closing.until
        None -> clock.now_ms >= until
      }
      case due {
        True ->
          talked(
            call,
            offer,
            conversation,
            talk.silence(conversation, clock.now),
            False,
          )
        False -> stay(call)
      }
    }
    Leaving(passage, exit, _, until) ->
      case clock.now_ms >= until {
        True -> {
          let #(call, effects) = depart(call, passage, exit, clock)
          #(call, [
            Log(
              "call "
              <> call.call_id
              <> ": the departure's barrier never completed; going on anyway",
            ),
            ..effects
          ])
        }
        False -> stay(call)
      }
    Departed(passage, exit, attempts, until) ->
      case clock.now_ms >= until, attempts < continue_attempts {
        False, _ -> stay(call)
        True, True ->
          into(
            call,
            Departed(
              passage,
              exit,
              attempts + 1,
              clock.now_ms + continue_ack_ms,
            ),
            [Continue(passage.handoff, branch(exit))],
          )
        True, False -> {
          let probe = resume_probe_id(passage.handoff)
          into(call, Resuming(passage, exit, probe, clock.now_ms + probe_ms), [
            Probe(probe),
          ])
        }
      }
    // The channel did not say in time: it is resumed all the same, since a
    // caller nobody takes back is a caller in silence.
    Resuming(passage, exit, _, until) ->
      case clock.now_ms >= until {
        True -> resume(call, passage, exit, clock)
        False -> stay(call)
      }
    Resumed(passage, exit, attempt, probe, until) ->
      case clock.now_ms >= until, probe {
        False, _ -> stay(call)
        // Nothing of the resume seen in `resume_ack_ms`: the channel is
        // asked, and its completion carries the mark if a flow has them.
        True, None -> {
          let probe = resumed_probe_id(passage.handoff, attempt)
          into(
            call,
            Resumed(
              passage,
              exit,
              attempt,
              Some(probe),
              clock.now_ms + probe_ms,
            ),
            [Probe(probe)],
          )
        }
        True, Some(_) ->
          not_taken(
            call,
            passage,
            exit,
            attempt,
            "its channel did not answer",
            clock,
          )
      }
    Idle | Done | Recovering(..) -> stay(call)
  }
}

/// The callflow never took the caller back: they go on at the branch on
/// whichever callflow node takes the resume, and are watched until one has
/// (`Resumed`).
///
/// Nothing on the bus says whether anybody took a resume. The callflow node
/// that takes it asks the switches whether the channel is up before it runs
/// anything, and when that fails it drops the resume without a word
/// (`cf_route_resume:handle_if_up`, whose executor then ends). Or no node
/// takes it at all. Either way nothing would drive the caller any more. The
/// shard settled their member as they left, the action that sent them is
/// gone, and they would sit in the silence the departure's barrier left
/// until they hung up. So the actor stays, and publishes the resume again
/// when it does not see it taken.
fn resume(
  call: Call,
  passage: Passage,
  exit: Exit,
  clock: Clock,
) -> #(Call, List(Effect)) {
  into(call, Resumed(passage, exit, 1, None, clock.now_ms + resume_ack_ms), [
    Resume(passage.handoff, branch(exit)),
    Log(
      "call "
      <> call.call_id
      <> ": its callflow never took it back; resuming it at "
      <> branch(exit),
    ),
  ])
}

/// A resume nobody took. The channel answered the probe without the mark,
/// or did not answer. The actor publishes the resume again, up to
/// `resume_attempts` times in all, and gives each `resume_ack_ms` to show.
///
/// After the last one the actor hangs the caller up and logs an error.
/// Nobody asked for that, but nothing else ends the call. The queue has let
/// the caller go, no callflow has them, and the queue has no hold to put
/// them back on. A caller who is hung up can call back. One left in silence
/// waits until they give up.
fn not_taken(
  call: Call,
  passage: Passage,
  exit: Exit,
  attempt: Int,
  why: String,
  clock: Clock,
) -> #(Call, List(Effect)) {
  case attempt < resume_attempts {
    True ->
      into(
        call,
        Resumed(passage, exit, attempt + 1, None, clock.now_ms + resume_ack_ms),
        [
          Resume(passage.handoff, branch(exit)),
          Log(
            "call "
            <> call.call_id
            <> ": its resume at "
            <> branch(exit)
            <> " was not taken ("
            <> why
            <> "); resuming it again, try "
            <> int.to_string(attempt + 1)
            <> " of "
            <> int.to_string(resume_attempts),
          ),
        ],
      )
    False ->
      into(call, Done, [
        HangUpCaller,
        LogError(
          "call "
          <> call.call_id
          <> " was resumed at "
          <> branch(exit)
          <> " "
          <> int.to_string(resume_attempts)
          <> " times and no callflow took it ("
          <> why
          <> "): hanging it up rather than leave it in silence",
        ),
      ])
  }
}

/// The `Msg-ID` of the probe before a resume.
pub fn resume_probe_id(handoff: Handoff) -> String {
  "callcenter-resume-" <> handoff.id
}

/// The `Msg-ID` of the probe asking whether a resume was taken, one per
/// resume published: only the completion of the probe of the resume now
/// out says that one was not.
pub fn resumed_probe_id(handoff: Handoff, attempt: Int) -> String {
  "callcenter-resumed-" <> handoff.id <> "-" <> int.to_string(attempt)
}

/// A waiting caller's clocks and media, at a tick: a wait that has run out
/// takes them out of the queue; a play whose end was never heard is ended;
/// an announcement that has fallen due is made.
fn waited(
  call: Call,
  passage: Passage,
  now_playing: Media,
  ringing: Option(Offer),
  clock: Clock,
) -> #(Call, List(Effect)) {
  case caller.expired(passage.caller, passage.settings.limits, clock.now) {
    Some(caller.WaitedTooLong) ->
      leave(call, passage, ringing, WaitedTooLong, clock)
    Some(caller.NoAgentTooLong) ->
      leave(call, passage, ringing, NobodyTooLong, clock)
    None -> {
      let #(now_playing, overdue) = media.overdue_cue(now_playing, clock.now)
      let #(passage, now_playing, announced) = case
        caller.announcement_due(
          passage.caller,
          passage.settings.limits,
          clock.now,
        )
      {
        False -> #(passage, now_playing, media.Nothing)
        True -> {
          let #(now_playing, cue) =
            media.announcement_cue(
              now_playing,
              passage.settings.announcement,
              passage.caller.position,
              passage.settings.language,
              clock.now,
            )
          #(
            Passage(
              ..passage,
              caller: caller.announced(passage.caller, at: clock.now),
            ),
            now_playing,
            cue,
          )
        }
      }
      let phase = case ringing {
        None -> Waiting(passage, now_playing)
        Some(offer) -> Offering(passage, offer, Ringing(now_playing))
      }
      into(
        call,
        phase,
        list.append(cued(passage, overdue), cued(passage, announced)),
      )
    }
  }
}

// --- Handing the call over ----------------------------------------------------

/// Whether the call can be left to whichever node takes the shard next,
/// which finds out about it from the switch (`call/recovery`): nothing
/// whose loss it could not see. An originate some of whose legs have not
/// shown yet would leave phones ringing that no snapshot lists; a bridge on
/// its way would leave a caller half through; a ring being called off
/// would leave legs the next node might take for a ring to take on.
pub fn steady(call: Call) -> Bool {
  call.recalls == []
  && case call.phase {
    Offering(offer: offer, ring: Ringing(_), ..) ->
      set.size(offer.seen) >= dict.size(offer.legs)
    Offering(ring: Connecting(..), ..) | Offering(ring: Parking(..), ..) ->
      False
    _ -> True
  }
}

// --- What the caller may be sent -------------------------------------------------

/// Which commands to the caller's channel a step from one phase to another
/// may carry. The actor is the only sender, and this is what it sends:
///
/// - media -- the greeting, an announcement, hold -- only to a caller who is
///   waiting, with or without a ring going, or back to waiting after an
///   answer came to nothing;
/// - the answer's marks -- the agent and the second, nothing else -- and
///   the `noop` that shows they ran, only as a leg answers, from ringing
///   into `Parking`;
/// - the bridge only out of `Parking` into `Connecting`, and so never in
///   the step that sent the marks, whose flush would throw away marks not
///   yet run;
/// - the recording only while connected, and the last hang-up once a leg
///   has answered -- or as a caller no resume reached is let go, the one
///   hang-up with no agent;
/// - the departure's marks and barrier only as a call starts leaving;
/// - the probe only while a call handed over is being found out about, or
///   one never taken back is asked whether it was before it is resumed, or
///   one resumed is asked, while it stays resumed, whether the resume was
///   taken;
/// - nothing to a call that has departed or is done.
///
/// The step that ends the finding out is the one exception: the call is put
/// in the phase it was found in, and what arrived meanwhile is heard in the
/// same step, so it may carry what any of the phases it passes through
/// allow. Each of those is the same rule as a step out of that phase, and
/// is held to it there.
pub fn allowed(before: Phase, after: Phase, effect: Effect) -> Bool {
  case before, effect {
    Recovering(..), Probe(_) ->
      case after {
        Recovering(..) -> True
        _ -> False
      }
    Recovering(..), _ -> True
    _, _ -> allowed_from(before, after, effect)
  }
}

fn allowed_from(before: Phase, after: Phase, effect: Effect) -> Bool {
  case effect {
    Play(_) | Announce(_) | Hold(_) ->
      case after {
        Waiting(..) -> True
        Offering(ring: Ringing(_), ..) -> True
        _ -> False
      }
    Bridge(_) ->
      case before, after {
        Offering(ring: Parking(..), ..), Offering(ring: Connecting(..), ..) ->
          True
        _, _ -> False
      }
    Mark(vars) ->
      case before, after {
        Offering(ring: Ringing(_), ..), Offering(ring: Parking(..), ..) ->
          list.map(vars, fn(var) { var.0 }) == answer_vars
        _, Leaving(..) ->
          vars
          |> list.all(fn(var) {
            var.0 == departing_var || var.0 == departing_branch_var
          })
        _, _ -> False
      }
    Confirm(_) ->
      case before, after {
        Offering(ring: Ringing(_), ..), Offering(ring: Parking(..), ..) -> True
        _, _ -> False
      }
    Probe(_) ->
      case before, after {
        _, Recovering(..) | _, Resuming(..) -> True
        // Only a call already resumed asks whether the resume was taken:
        // the step that publishes a resume does not probe with it.
        Resumed(..), Resumed(..) -> True
        _, _ -> False
      }
    Record(..) ->
      case after {
        Connected(..) -> True
        _ -> False
      }
    HangUpCaller ->
      case before, after {
        Connected(..), _
        | Offering(ring: Parking(..), ..), _
        | Offering(ring: Connecting(..), ..), _
        -> True
        // A caller no resume reached, as the watch gives them up.
        Resumed(..), Done -> True
        _, _ -> False
      }
    Barrier(_) ->
      case after {
        Leaving(..) -> True
        _ -> False
      }
    Originate(..)
    | HangUpLegs(_)
    | Tell(..)
    | Left(_)
    | Continue(..)
    | Resume(..)
    | Survey
    | Present(..)
    | Audit(_)
    | Log(_)
    | LogError(_) -> True
  }
}

/// Whether an effect is a command to the caller's own channel.
pub fn commands_caller(effect: Effect) -> Bool {
  case effect {
    Play(_)
    | Announce(_)
    | Hold(_)
    | Bridge(_)
    | Mark(_)
    | Confirm(_)
    | Record(..)
    | HangUpCaller
    | Barrier(_)
    | Probe(_) -> True
    Originate(..)
    | HangUpLegs(_)
    | Tell(..)
    | Left(_)
    | Continue(..)
    | Resume(..)
    | Survey
    | Present(..)
    | Audit(_)
    | Log(_)
    | LogError(_) -> False
  }
}
