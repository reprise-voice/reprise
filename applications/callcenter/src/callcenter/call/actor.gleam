//// The one process that commands a queued caller.
////
//// One actor per call of an account, on the node holding the account's
//// shard, started by the shard's `calls` (`callcenter/call/calls`) when the
//// dispatcher first says the caller has joined, and ended when there is
//// nothing left to do for the call. It covers every passage of the call
//// through the account's queues: a caller sent from one queue into another
//// is the same actor.
////
//// Every decision is `callcenter/call/core`'s, a pure step from the call
//// and one input to the call after and a list of effects. This is the
//// shell around it: it turns what arrives -- the dispatcher's messages,
//// the switch's events, `ecallmgr`'s and the callflow action's answers --
//// into inputs, takes the step, performs the effects in order from this
//// one process, and sleeps until the next input or the call's next
//// deadline, whichever is first. So the caller's channel is sent commands
//// by one process only, one message at a time, in the order they were
//// decided, and the first message handled of an answer, a key and a
//// call-off is the one that stands.
////
//// **What it hears.** The caller's events and each of its offers' legs'
//// arrive through `kz_events:bind_call_id`, bound from here, in this
//// process's mailbox as `{kapi, Msg}`. The answers to what it asks come to
//// its own address, `pid://<actor>/<queue>` on the node's reply listener
//// (`callcenter/call/replies`), in the same shape. The dispatcher's
//// messages come on its subject.
////
//// **The effects' reach.** Everything outside the process goes through
//// `Io`, which is the node on a node and a recorder in the tests: the
//// clocks, the queue document, the agents' endpoints, the bindings, and
//// `perform`, which carries out one of `core`'s effects.

import callcenter/announce
import callcenter/call/core
import callcenter/call/originate
import callcenter/call/recovery
import callcenter/call/snapshots
import callcenter/member as member_message
import callcenter/recording
import callcenter/records
import callcenter/system
import callcenter/types.{
  type CancelReason, type Member, type OfferId, type OfferReply,
  type OfferRequest,
}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import kazoo/amqp
import kazoo/call.{type Call}
import kazoo/doc.{type Value}
import kazoo/events
import kazoo/kazoo.{type Kazoo}
import kazoo/modb

/// What the actor is sent.
pub type Message {
  /// The dispatcher: the caller joined one of the account's queues.
  /// `resumed` is a caller it was handed without seeing them join -- the
  /// broker handed them out again, their last actor ended, or the
  /// dispatcher is new -- and waits to be told where they stand.
  Join(member: Member, resumed: Bool, reply_to: Subject(#(OfferId, OfferReply)))
  /// The dispatcher: a call a node that died had connected, to be watched
  /// to its end under the offer `offer`.
  Adopt(
    member: Member,
    offer: OfferId,
    agent_id: String,
    leg: String,
    answered_at: Int,
    reply_to: Subject(#(OfferId, OfferReply)),
  )
  /// The dispatcher: ring these agents for the caller.
  Ring(request: OfferRequest)
  /// The dispatcher: call this offer off.
  CallOff(offer: OfferId)
  /// The dispatcher: the caller's queue has been deleted.
  QueueGone
  /// The dispatcher: where the caller stands.
  Positioned(
    position: Option(Int),
    waiting: Option(Int),
    agents_available: Option(Int),
  )
  /// Anything that came in as `{kapi, Msg}`: an event of the caller or of
  /// a leg, `ecallmgr`'s answer to an originate or a command, the callflow
  /// action's answer to a hand-back.
  Heard(Value)
  /// What the survey of a caller being recovered found.
  Surveyed(survey: recovery.Survey)
  /// The call ids an audit found on no switch.
  Audited(gone: List(String))
  /// The call's own deadline, of the generation that set it.
  Wake(generation: Int)
  /// A `{kapi, Msg}` this actor could not read.
  Unreadable
  /// Stop now, without touching the call: the shard is going.
  Stop(done: Subject(Nil))
  /// The shard is being handed over: answer once the call is steady
  /// (`core.steady`), which may be at once.
  Steady(done: Subject(Nil))
}

/// What the effects of one step are performed with: the call as the actor
/// knows it at the moment.
pub type Context {
  Context(
    account_id: String,
    call_id: String,
    /// The member of the passage the caller is in, or was in last.
    member: Option(Member),
    /// The caller's call, which commands go to.
    caller: Option(Call),
    /// Where the dispatcher hears about offers.
    reply_to: Option(Subject(#(OfferId, OfferReply))),
    /// This actor's own address, for the answers to what it asks.
    address: Option(String),
    /// The dispatcher's request the step is answering, if it is one.
    request: Option(OfferRequest),
    /// How much longer than its ring timeout a ring is waited for.
    grace_s: Int,
    now: Int,
  )
}

/// Everything the actor reaches outside itself.
pub type Io {
  Io(
    /// Gregorian seconds.
    now: fn() -> Int,
    /// The VM's monotonic milliseconds.
    monotonic_ms: fn() -> Int,
    /// A queue's document, for what a caller waiting in it is asked.
    queue: fn(String, String) -> Result(Value, String),
    /// The endpoints an offer rings, named with the prefix given.
    endpoints: fn(OfferRequest, String) -> List(Value),
    /// `offer_grace_s`: how much longer than its ring timeout a ring is
    /// waited for.
    grace_s: Int,
    /// Hear a call id's events from now on.
    bind: fn(String) -> Nil,
    /// A caller's record and the account's channels, for finding out where
    /// a caller handed over stands. Run in a process of its own.
    survey: fn(Member) -> recovery.Survey,
    /// Which of these call ids every switch says it does not carry. Run in
    /// a process of its own.
    audit: fn(List(String)) -> List(String),
    /// This actor's address, when the node's reply listener has one.
    address: fn() -> Option(String),
    /// Carry out one effect.
    perform: fn(Context, core.Effect) -> Nil,
  )
}

type State {
  State(
    call: core.Call,
    io: Io,
    self: Subject(Message),
    member: Option(Member),
    caller: Option(Call),
    reply_to: Option(Subject(#(OfferId, OfferReply))),
    /// The offers this actor has originated, by the prefix their
    /// `originate_req` was sent under, which its answer echoes.
    originates: Dict(String, OfferId),
    /// The call ids this actor hears.
    bound: Set(String),
    /// The generation of the one wake-up that counts.
    generation: Int,
    timer: Option(process.Timer),
    /// Whether this process has asked for an AMQP channel of its own yet.
    channel: Bool,
    /// Started after the call's actors crashed `quarantine_after` times:
    /// whatever the caller joins for, they are handed back.
    quarantined: Bool,
    /// Whoever is waiting for the call to be steady.
    steadying: List(Subject(Nil)),
  )
}

/// How many crashes of a call's actors before the next is quarantined
/// (`callcenter/call/calls`).
pub const quarantine_after = 3

// --- Starting --------------------------------------------------------------

/// Start the actor for one call of an account, whose actors have crashed
/// `strikes` times lately.
pub fn start(
  io: Io,
  account_id: String,
  call_id: String,
  strikes: Int,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    let state =
      State(
        call: core.new(account_id, call_id),
        io: io,
        self: self,
        member: None,
        caller: None,
        reply_to: None,
        originates: dict.new(),
        bound: set.new(),
        generation: 0,
        timer: None,
        channel: False,
        quarantined: strikes >= quarantine_after,
        steadying: [],
      )
      |> bind(call_id)
    actor.initialised(state)
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_record(atom.create("kapi"), 1, fn(message) {
        case kapi_payload(message) {
          Ok(payload) -> Heard(doc.from_dynamic(payload))
          Error(Nil) -> Unreadable
        }
      }),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

// --- The loop --------------------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Stop(done) -> {
      process.send(done, Nil)
      actor.stop()
    }
    Unreadable -> actor.continue(state)
    Steady(done) ->
      actor.continue(steadied(
        State(..state, steadying: [done, ..state.steadying]),
      ))
    Wake(generation) if generation != state.generation -> actor.continue(state)
    _ -> {
      // Asked on the first message and not in the initialiser, which the
      // registry waits on: everything this process publishes goes out on
      // one channel, in the order it was sent.
      let state = case state.channel {
        True -> state
        False -> {
          let _ = ensure_channel()
          State(..state, channel: True)
        }
      }
      let now = state.io.now()
      let clock = core.Clock(now: now, now_ms: state.io.monotonic_ms())
      let #(state, input, request) = input_of(state, message)
      case input {
        None -> actor.continue(state)
        Some(input) -> {
          let #(call, effects) = core.step(state.call, input, clock)
          let state = State(..state, call: call)
          let context = context(state, request, now)
          list.each(effects, carry_out(state, context, _))
          let state = steadied(state)
          case core.finished(call) {
            True -> actor.stop()
            False -> actor.continue(sleep(state, clock))
          }
        }
      }
    }
  }
}

/// Tell whoever is waiting for the call to be steady that it is, if it is.
fn steadied(state: State) -> State {
  case state.steadying, core.steady(state.call) {
    [], _ | _, False -> state
    waiting, True -> {
      list.each(waiting, process.send(_, Nil))
      State(..state, steadying: [])
    }
  }
}

/// What a message is to the call: the input, the state it leaves the shell
/// in, and the request the step answers when it is one.
fn input_of(
  state: State,
  message: Message,
) -> #(State, Option(core.Input), Option(OfferRequest)) {
  case message {
    Join(member, resumed, reply_to) -> {
      let state = joined(state, member, reply_to)
      let joining = joining(state, member)
      let input = case state.quarantined, resumed {
        True, _ -> core.Quarantine(joining)
        False, False -> core.Joined(joining)
        False, True ->
          core.Rejoined(
            joining,
            types.OfferId(call_id: member.call_id, serial: reference.new()),
          )
      }
      #(state, Some(input), None)
    }
    Adopt(member, offer, agent_id, leg, answered_at, reply_to) -> {
      let state = joined(state, member, reply_to)
      let state = case leg {
        "" -> state
        leg -> bind(state, leg)
      }
      #(
        state,
        Some(
          core.Adopt(core.Adoption(
            joining: joining(state, member),
            offer: offer,
            agent_id: agent_id,
            leg: leg,
            answered_at: answered_at,
          )),
        ),
        None,
      )
    }
    Ring(request) -> {
      let prefix = originate.leg_prefix(request.id)
      let endpoints = state.io.endpoints(request, prefix)
      let state =
        list.fold(dict.keys(originate.legs_of(endpoints)), state, bind)
      let state =
        State(
          ..state,
          reply_to: Some(request.reply_to),
          originates: dict.insert(state.originates, prefix, request.id),
        )
      #(
        state,
        Some(
          core.Ring(core.RingRequest(
            offer: request.id,
            agents: request.agents,
            endpoints: endpoints,
            ring_timeout_s: request.settings.ring_timeout_s,
            grace_s: state.io.grace_s,
            record: request.settings.record,
            pickup: option.is_some(request.devices),
          )),
        ),
        Some(request),
      )
    }
    CallOff(offer) -> #(state, Some(core.CallOff(offer)), None)
    QueueGone -> #(state, Some(core.QueueGone), None)
    Positioned(position, waiting, available) -> #(
      state,
      Some(core.Positioned(position, waiting, available)),
      None,
    )
    Heard(value) -> heard(state, value)
    Surveyed(survey) -> {
      // Every leg found is heard from before the call looks at it.
      let state =
        list.fold(recovery.leg_ids(survey, state.call.call_id), state, bind)
      #(state, Some(core.Surveyed(survey)), None)
    }
    Audited(gone) -> #(state, Some(core.Audited(gone)), None)
    Wake(_) -> #(state, Some(core.Tick), None)
    Unreadable | Stop(_) | Steady(_) -> #(state, None, None)
  }
}

/// What something heard is: an originate's answer for one of this actor's
/// offers, the callflow's answer to a hand-back, a switch's answer to a
/// command -- which says nothing to the call, and is only logged when it is
/// a refusal -- or an event.
fn heard(
  state: State,
  value: Value,
) -> #(State, Option(core.Input), Option(OfferRequest)) {
  case kind_of(value) {
    OriginateAnswer(prefix) ->
      case dict.get(state.originates, prefix) {
        Ok(offer) -> #(
          State(..state, originates: dict.delete(state.originates, prefix)),
          Some(core.Originated(offer, value)),
          None,
        )
        Error(Nil) -> #(state, None, None)
      }
    ContinuingAnswer(handoff_id) -> #(
      state,
      Some(core.Continuing(handoff_id)),
      None,
    )
    CommandAnswer -> {
      case doc.get_string(value, ["Error-Message"]) {
        Ok(error) ->
          system.log_error(
            "call "
            <> state.call.call_id
            <> ": the switch refused a command: "
            <> error,
          )
        Error(Nil) -> Nil
      }
      #(state, None, None)
    }
    CallEvent -> #(state, Some(core.Event(value)), None)
  }
}

/// What a message in from the bus is.
pub type Kind {
  /// `ecallmgr`'s answer to an `originate_req` sent under this prefix.
  OriginateAnswer(prefix: String)
  /// The callflow action has the caller back.
  ContinuingAnswer(handoff_id: String)
  /// `ecallmgr`'s answer to a command sent through a switch's node.
  CommandAnswer
  /// Anything else: an event of a call this actor hears.
  CallEvent
}

pub fn kind_of(value: Value) -> Kind {
  case
    doc.get_string(value, ["Event-Category"]),
    doc.get_string(value, ["Event-Name"])
  {
    _, Ok("originate_resp") ->
      OriginateAnswer(doc.get_string(value, ["Msg-ID"]) |> result.unwrap(""))
    Ok("callcenter"), Ok("member_continuing") ->
      ContinuingAnswer(
        doc.get_string(value, ["Handoff-ID"]) |> result.unwrap(""),
      )
    Ok("switch_event"), _ | Ok("switch"), _ -> CommandAnswer
    _, _ -> CallEvent
  }
}

/// The caller as the dispatcher last described them.
fn joined(
  state: State,
  member: Member,
  reply_to: Subject(#(OfferId, OfferReply)),
) -> State {
  State(
    ..state,
    member: Some(member),
    caller: Some(call.from_value(member.call)),
    reply_to: Some(reply_to),
  )
}

/// A passage as the call's core takes it: the queue's settings read now,
/// and where the callflow waits for the caller back.
fn joining(state: State, member: Member) -> core.Joining {
  let language =
    doc.get_string(member.call, ["Language"]) |> result.unwrap("en-us")
  let queue = case state.io.queue(member.account_id, member.queue_id) {
    Ok(queue) -> queue
    Error(reason) -> {
      system.log_error(
        "call "
        <> member.call_id
        <> ": queue "
        <> member.queue_id
        <> " could not be read ("
        <> reason
        <> "): waiting with the defaults",
      )
      doc.object([])
    }
  }
  core.Joining(
    queue_id: member.queue_id,
    joined: member.joined,
    handoff: handoff(member),
    settings: core.settings(queue, language),
  )
}

/// Where the callflow that sent a member waits for the caller back.
pub fn handoff(member: Member) -> core.Handoff {
  core.Handoff(
    id: member.handoff_id,
    reply_to: member_message.controller_queue(member.call) |> option.unwrap(""),
    branches: member.branches,
  )
}

/// Carry out one effect. The survey and the audit are this process's own
/// to start: each runs beside the actor, which goes on hearing the caller
/// meanwhile, and its answer comes back here as a message.
fn carry_out(state: State, context: Context, effect: core.Effect) -> Nil {
  case effect, state.member {
    core.Survey, Some(member) -> {
      let io = state.io
      let self = state.self
      let _ =
        process.spawn_unlinked(fn() {
          process.send(self, Surveyed(io.survey(member)))
        })
      Nil
    }
    core.Survey, None -> process.send(state.self, Surveyed(recovery.nothing()))
    core.Audit(call_ids), _ -> {
      let io = state.io
      let self = state.self
      let _ =
        process.spawn_unlinked(fn() {
          process.send(self, Audited(io.audit(call_ids)))
        })
      Nil
    }
    _, _ -> state.io.perform(context, effect)
  }
}

fn bind(state: State, call_id: String) -> State {
  case set.contains(state.bound, call_id) {
    True -> state
    False -> {
      state.io.bind(call_id)
      State(..state, bound: set.insert(state.bound, call_id))
    }
  }
}

fn context(state: State, request: Option(OfferRequest), now: Int) -> Context {
  Context(
    account_id: state.call.account_id,
    call_id: state.call.call_id,
    member: state.member,
    caller: state.caller,
    reply_to: state.reply_to,
    address: state.io.address(),
    request: request,
    grace_s: state.io.grace_s,
    now: now,
  )
}

/// Sleep until the call's next deadline: one timer, and a wake-up of an
/// older generation is ignored when it lands anyway.
fn sleep(state: State, clock: core.Clock) -> State {
  case state.timer {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
  let generation = state.generation + 1
  let timer =
    process.send_after(
      state.self,
      core.wait_ms(state.call, clock),
      Wake(generation),
    )
  State(..state, generation: generation, timer: Some(timer))
}

// --- The node ----------------------------------------------------------------

/// The actor's reach on a node. `left` is the shard's: a caller who left a
/// queue is settled there and the dispatcher told.
pub fn live(kz: Kazoo, left: fn(Member, CancelReason) -> Nil) -> Io {
  Io(
    now: modb.now,
    monotonic_ms: monotonic_ms,
    queue: fn(account_id, queue_id) {
      kz.datamgr.open_cache_doc(kazoo.account_db(account_id), queue_id)
      |> result.map_error(kazoo.error_to_string)
    },
    endpoints: fn(request, prefix) {
      originate.endpoints(
        call: request.member.call,
        account_id: request.member.account_id,
        agents: request.agents,
        devices: request.devices,
        settings: request.settings,
        prefix: prefix,
      )
    },
    grace_s: kz.config.get_int("offer_grace_s", 5),
    bind: bind_call,
    survey: fn(member: Member) {
      recovery.Survey(
        channels: snapshots.channels(member.account_id),
        record: records.read(kz, member) |> recovery.record,
      )
    },
    audit: fn(call_ids) {
      list.filter(call_ids, fn(call_id) {
        events.channel_status(app: system.category, call_id: call_id) == Ok([])
      })
    },
    address: fn() { reply_address() |> option.from_result },
    perform: fn(context, effect) { perform(context, effect, left) },
  )
}

/// Carry out one effect on a node.
pub fn perform(
  context: Context,
  effect: core.Effect,
  left: fn(Member, CancelReason) -> Nil,
) -> Nil {
  case effect, context.caller {
    core.Play(media), Some(caller) -> call.play(caller, media)
    core.Announce(items), Some(caller) -> announce.play(caller, items)
    core.Hold(moh), Some(caller) -> announce.resume_hold(caller, moh)
    core.Bridge(leg), Some(caller) -> bridge(context, caller, leg)
    core.Mark(vars), Some(caller) -> command(context, caller, set_now(vars))
    core.Confirm(msg_id), Some(caller) ->
      command(context, caller, noop(msg_id, "now"))
    core.Record(agent_id, at), Some(caller) ->
      case context.member {
        Some(member) -> {
          recording.start(
            caller,
            member.account_id,
            member.queue_id,
            member.call_id,
            agent_id,
            at,
          )
          // The passage's record names the recording, which is what finds
          // media_mgr's `call_recording` document of it again.
          records.recorded(
            member,
            recording.name(member.queue_id, member.call_id, at),
          )
        }
        None -> Nil
      }
    core.HangUpCaller, Some(caller) -> call.hangup(caller)
    core.Barrier(msg_id), Some(caller) ->
      command(context, caller, noop(msg_id, "flush"))
    core.Probe(msg_id), Some(caller) ->
      command(context, caller, noop(msg_id, "now"))
    core.Originate(_offer, endpoints, _ring_timeout_s), _ ->
      originate_legs(context, endpoints)
    core.HangUpLegs(legs), _ -> list.each(legs, hang_up_leg(context, _))
    core.Tell(offer, reply), _ ->
      case context.reply_to {
        Some(reply_to) -> process.send(reply_to, #(offer, reply))
        None -> Nil
      }
    core.Present(offer, presence), _ ->
      case context.reply_to {
        Some(reply_to) ->
          process.send(reply_to, #(
            option.lazy_unwrap(offer, fn() {
              types.OfferId(call_id: context.call_id, serial: reference.new())
            }),
            types.Present(presence),
          ))
        None -> Nil
      }
    // The actor starts the survey and the audit itself (`carry_out`).
    core.Survey, _ | core.Audit(_), _ -> Nil
    core.Left(reason), _ ->
      case context.member {
        Some(member) -> left(member, reason)
        None -> Nil
      }
    core.Continue(handoff, branch), _ -> continue(context, handoff, branch)
    core.Resume(handoff, branch), _ -> resume(context, handoff, branch)
    core.Log(message), _ -> system.log(message)
    core.LogError(message), _ -> system.log_error(message)
    // A command for a caller this actor never had the call of: nothing to
    // send it to.
    _, None -> Nil
  }
}

/// Bridge the caller to a leg that answered and is parked, on the caller's
/// control queue: flush what the caller hears, then `connect_leg` run at
/// once, so that it does not wait behind anything and nothing waits behind
/// it.
///
/// `Park-After-Pickup` is what makes the caller park -- not hang up -- when
/// the agent's leg goes, so that the actor says how the call ended. It is
/// set by `ecallmgr` on both channels through the switch's API before the
/// bridge, which is the only time it can be: a `set` of the caller's
/// variable sent after the bridge is an application, and a channel in a
/// bridge runs none (the lab of 2026-09-27, `e2e-260927-cca2`). The agent's
/// leg parks too when the caller hangs up, and the actor hangs it up then,
/// as it does at the end of every call.
fn bridge(context: Context, caller: Call, leg: String) -> Nil {
  command(context, caller, noop("callcenter-flush-" <> leg, "flush"))
  command(
    context,
    caller,
    doc.object([
      #("Application-Name", doc.String("connect_leg")),
      #("Target-Call-ID", doc.String(leg)),
      #("Insert-At", doc.String("now")),
      #("Continue-On-Fail", doc.Bool(True)),
      #("Continue-On-Cancel", doc.Bool(True)),
      #("Park-After-Pickup", doc.Bool(True)),
      #("Hangup-After-Pickup", doc.Bool(False)),
      #("Publish-Usurp", doc.Bool(False)),
    ]),
  )
}

/// A `noop` with a known `Msg-ID`: its completion names it.
fn noop(msg_id: String, insert_at: String) -> Value {
  doc.object([
    #("Application-Name", doc.String("noop")),
    #("Msg-ID", doc.String(msg_id)),
    #("Insert-At", doc.String(insert_at)),
  ])
}

/// A `set` of the caller's variables, run at once rather than queued: a
/// mark that waits behind the hold would be thrown away by the next flush.
/// "At once" is the switch's next look at the channel, not `ecallmgr`
/// taking it, and a flush before then throws it away all the same, so a
/// mark that has to survive one is followed by `core.Confirm`.
fn set_now(vars: List(#(String, Value))) -> Value {
  doc.object([
    #("Application-Name", doc.String("set")),
    #("Custom-Channel-Vars", doc.object(vars)),
    #("Custom-Call-Vars", doc.object([])),
    #("Export-All", doc.Bool(False)),
    #("Insert-At", doc.String("now")),
  ])
}

fn command(context: Context, caller: Call, command: Value) -> Nil {
  case send_command(caller, doc.to_string(command)) {
    Ok(Nil) -> Nil
    Error(reason) ->
      system.log_error(
        "call "
        <> context.call_id
        <> ": could not send "
        <> doc.get_string(command, ["Application-Name"]) |> result.unwrap("")
        <> ": "
        <> reason,
      )
  }
}

/// One `originate_req` for the offer being rung.
fn originate_legs(context: Context, endpoints: List(Value)) -> Nil {
  case context.request {
    None -> Nil
    Some(request) -> {
      let member = request.member
      let ring =
        originate.Ring(
          account_id: member.account_id,
          queue_id: member.queue_id,
          call_id: member.call_id,
          switch: switch_of(member),
          joined: member.joined,
          prefix: originate.leg_prefix(request.id),
          ring_timeout_s: request.settings.ring_timeout_s,
          deadline: context.now
            + request.settings.ring_timeout_s
            + context.grace_s,
          owner: system.node_name(),
          pickup: option.is_some(request.devices),
          caller_id_name: member.caller_id_name,
          caller_id_number: member.caller_id_number,
          cid_prefix: request.settings.cid_prefix,
          server_id: context.address,
        )
      let payload =
        doc.merge(
          amqp.default_headers(
            app: system.category,
            category: "resource",
            name: "originate_req",
          ),
          originate.request(ring, endpoints),
        )
      case
        amqp.publish(module: "resource", function: "originate_req", payload:)
      {
        Ok(Nil) -> Nil
        Error(reason) ->
          system.log_error(
            "call "
            <> member.call_id
            <> ": could not ring "
            <> int.to_string(list.length(endpoints))
            <> " endpoint(s): "
            <> amqp.error_to_string(reason),
          )
      }
    }
  }
}

/// Hang one leg up by name on the caller's switch: `call_command` hangup,
/// which `ecallmgr` runs as `uuid_kill` when
/// `node_call_command_allowed_applications.callcenter.hangup` lets it. A leg
/// that has gone already is nothing to it.
fn hang_up_leg(context: Context, leg: String) -> Nil {
  let node = case context.member {
    Some(member) -> switch_of(member)
    None -> None
  }
  let payload =
    doc.merge(
      amqp.default_headers(
        app: system.category,
        category: "switch_event",
        name: "command",
      ),
      doc.object_some([
        #("Command", Some(doc.String("call_command"))),
        #(
          "Args",
          Some(
            doc.object([
              #("Application-Name", doc.String("hangup")),
              #("Call-ID", doc.String(leg)),
              #("Hangup-Cause", doc.String("ORIGINATOR_CANCEL")),
            ]),
          ),
        ),
        #("Call-ID", Some(doc.String(leg))),
        #("FreeSWITCH-Node", option.map(node, doc.String)),
        // `kz_api` refuses a command with no `Server-ID`, and a node that
        // is shutting down may have no address left: the hangup goes all the
        // same, and its answer nowhere.
        #(
          "Server-ID",
          Some(
            doc.String(option.unwrap(context.address, "callcenter-no-reply")),
          ),
        ),
      ]),
    )
  case amqp.publish(module: "switch", function: "fs_command", payload:) {
    Ok(Nil) -> Nil
    Error(reason) ->
      system.log_error(
        "call "
        <> context.call_id
        <> ": could not hang up leg "
        <> leg
        <> ": "
        <> amqp.error_to_string(reason),
      )
  }
}

fn switch_of(member: Member) -> Option(String) {
  case doc.get_string(member.call, ["Switch-Nodename"]) {
    Ok("") | Error(Nil) -> None
    Ok(node) -> Some(node)
  }
}

/// Hand the caller back to the callflow action: `member_continue` at its
/// Controller-Queue, answered at this actor's address.
fn continue(context: Context, handoff: core.Handoff, branch: String) -> Nil {
  case handoff.reply_to, context.member {
    "", _ | _, None ->
      system.log_error(
        "call "
        <> context.call_id
        <> ": no callflow to hand back to on "
        <> branch,
      )
    reply_to, Some(member) -> {
      let payload =
        doc.merge(
          amqp.default_headers(
            app: system.category,
            category: system.category,
            name: "member_continue",
          ),
          doc.object_some([
            #("Account-ID", Some(doc.String(member.account_id))),
            #("Queue-ID", Some(doc.String(member.queue_id))),
            #("Call-ID", Some(doc.String(member.call_id))),
            #("Handoff-ID", Some(doc.String(handoff.id))),
            #("Branch", Some(doc.String(branch))),
            #("Reply-To", option.map(context.address, doc.String)),
          ]),
        )
      case
        amqp.publish_to(
          target: reply_to,
          module: system.category,
          function: "member_continue",
          payload: payload,
        )
      {
        Ok(Nil) -> Nil
        Error(reason) ->
          system.log_error(
            "call "
            <> member.call_id
            <> ": could not hand it back on "
            <> branch
            <> ": "
            <> amqp.error_to_string(reason),
          )
      }
    }
  }
}

/// The flow a caller is resumed at on a branch: the branch's own, or the
/// callflow's default child, which is where the action would have gone on
/// a branch it has no child for.
pub fn resume_flow(branches: Value, branch: String) -> Option(Value) {
  case doc.get(branches, [branch]), doc.get(branches, ["_"]) {
    Ok(flow), _ -> Some(flow)
    Error(Nil), Ok(flow) -> Some(flow)
    Error(Nil), Error(Nil) -> None
  }
}

/// What a caller is resumed with: the `callcenter_departed` action, which
/// marks the channel `Queue-Departed` for the passage as the queue's action
/// would have -- so that a node taking the caller over later finds them
/// handed back already, and does not hand them back twice, and so that this
/// actor, watching the channel (`core.Resumed`), sees the resume was taken
/// -- and goes on to its one child, the branch's flow. `None` when the
/// branch has nowhere to go.
pub fn resumed_flow(handoff: core.Handoff, branch: String) -> Option(Value) {
  resume_flow(handoff.branches, branch)
  |> option.map(fn(flow) {
    doc.object([
      #("module", doc.String("callcenter_departed")),
      #("data", doc.object([#("handoff_id", doc.String(handoff.id))])),
      #("children", doc.object([#("_", flow)])),
    ])
  })
}

/// The callflow action's node is gone: the caller goes on at the branch on
/// whichever callflow node takes the resume. A branch with nowhere to go is
/// the end of the callflow, which hangs up. The core publishes this again
/// while it does not see the resume taken; the hang-up here ends the watch
/// with the channel.
fn resume(context: Context, handoff: core.Handoff, branch: String) -> Nil {
  case context.member, resumed_flow(handoff, branch) {
    None, _ -> Nil
    Some(member), None -> {
      system.log(
        "call "
        <> member.call_id
        <> " has nowhere to go on "
        <> branch
        <> ": hanging up",
      )
      case context.caller {
        Some(caller) -> call.hangup(caller)
        None -> Nil
      }
    }
    Some(member), Some(flow) -> {
      let payload =
        doc.merge(
          amqp.default_headers(
            app: system.category,
            category: "callflow",
            name: "resume",
          ),
          doc.object([
            #("Call", member.call),
            #("Flow", flow),
            #("Call-ID", doc.String(member.call_id)),
          ]),
        )
      case amqp.publish(module: "callflow", function: "resume", payload:) {
        Ok(Nil) -> Nil
        Error(reason) ->
          system.log_error(
            "call "
            <> member.call_id
            <> ": could not resume it on "
            <> branch
            <> ": "
            <> amqp.error_to_string(reason),
          )
      }
    }
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

@external(erlang, "callcenter_ffi", "bind_call")
fn bind_call(call_id: String) -> Nil

@external(erlang, "callcenter_ffi", "kapi_payload")
fn kapi_payload(message: Dynamic) -> Result(Dynamic, Nil)

@external(erlang, "callcenter_ffi", "reply_address")
fn reply_address() -> Result(String, Nil)

@external(erlang, "callcenter_ffi", "send_command")
fn send_command(caller: Call, json: String) -> Result(Nil, String)

@external(erlang, "callcenter_ffi", "ensure_channel")
fn ensure_channel() -> Bool
