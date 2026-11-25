//// Scripts of one queued call's inputs, for the state machine's tests: the
//// call and its world, the events the switch sends, and a runner that
//// takes a script a step at a time.

import callcenter/announce
import callcenter/call/core.{type Call, type Effect, type Input, Clock, Joined}
import callcenter/call/originate
import callcenter/caller
import callcenter/types
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc

pub const account_id = "account-one"

pub const call_id = "caller-leg"

pub const queue_id = "queue-support"

/// The calendar second and the monotonic millisecond every script starts at.
pub const t0 = 63_800_000_000

pub const ms0 = 1_000_000

pub fn at(seconds: Int) -> core.Clock {
  Clock(now: t0 + seconds, now_ms: ms0 + seconds * 1000)
}

pub fn at_ms(ms: Int) -> core.Clock {
  Clock(now: t0 + ms / 1000, now_ms: ms0 + ms)
}

pub fn settings() -> core.Settings {
  core.Settings(
    limits: caller.Limits(
      max_wait_s: 300,
      max_wait_with_no_agent_s: 60,
      no_agent_after_s: 0,
      announce_interval_s: 0,
    ),
    announcement: announce.Settings(
      media: None,
      interval_s: 30,
      position: False,
      prompts: announce.Prompts(
        you_are_at_position: announce.default_position_prompt,
        in_the_queue: announce.default_in_the_queue_prompt,
      ),
    ),
    exit_keys: ["#"],
    moh: Some("support-hold"),
    greeting: Some("welcome"),
    language: "en-us",
  )
}

pub fn handoff(id: String) -> core.Handoff {
  core.Handoff(
    id: id,
    reply_to: "pid://<0.1.0>/callflow_route_1",
    branches: doc.object([]),
  )
}

/// What a caller leaving passage `id` on `branch` for `reason` is sent as
/// they leave: the shard told, the departure's marks, and the `noop` that
/// shows they ran.
pub fn departing(
  id: String,
  branch: String,
  reason: types.CancelReason,
) -> List(Effect) {
  [
    core.Departing(id, reason),
    departure_marks(id, branch),
    core.Confirm(core.departure_marks_id(handoff(id))),
  ]
}

/// The marks of a caller leaving passage `id` on `branch`.
pub fn departure_marks(id: String, branch: String) -> Effect {
  core.Mark([
    #(core.departing_var, doc.String(id)),
    #(core.departing_branch_var, doc.String(branch)),
  ])
}

/// The `noop` behind passage `id`'s departure marks completed: the marks
/// ran, and the barrier goes out.
pub fn departure_marked(id: String) -> Input {
  noop_done(core.departure_marks_id(handoff(id)))
}

/// The barrier of passage `id` completed.
pub fn barrier_done(id: String) -> Input {
  noop_done(core.barrier_id(handoff(id)))
}

pub fn joining(id: String, with: core.Settings) -> Input {
  Joined(core.Joining(
    queue_id: queue_id,
    joined: t0,
    handoff: handoff(id),
    settings: with,
  ))
}

pub fn fresh() -> Call {
  core.new(account_id, call_id)
}

/// An offer ringing `agents`, one device each, its legs named.
pub fn offer(agents: List(String)) -> #(types.OfferId, List(doc.Value)) {
  let id = types.OfferId(call_id: call_id, serial: reference.new())
  let endpoints =
    agents
    |> list.map(fn(agent) {
      doc.object([#("Invite-Format", doc.String("endpoint"))])
      |> originate.decorate(
        agent,
        types.OfferSettings(
          ring_timeout_s: 15,
          cid_prefix: None,
          record: False,
          outbound_caller_id_name: None,
          outbound_caller_id_number: None,
          hold_media: None,
        ),
      )
    })
    |> originate.named_legs(originate.leg_prefix(id))
  #(id, endpoints)
}

pub fn ring(
  id: types.OfferId,
  agents: List(String),
  endpoints: List(doc.Value),
  record: Bool,
) -> Input {
  core.Ring(core.RingRequest(
    offer: id,
    agents: agents,
    endpoints: endpoints,
    ring_timeout_s: 15,
    grace_s: 5,
    record: record,
    pickup: False,
  ))
}

pub fn leg_of(id: types.OfferId, n: Int) -> String {
  originate.leg_prefix(id) <> "-" <> int.to_string(n)
}

pub fn event(call: String, name: String, more: List(#(String, doc.Value))) {
  core.Event(
    doc.object([
      #("Event-Category", doc.String("call_event")),
      #("Event-Name", doc.String(name)),
      #("Call-ID", doc.String(call)),
      ..more
    ]),
  )
}

pub fn key(digit: String) -> Input {
  event(call_id, "DTMF", [#("DTMF-Digit", doc.String(digit))])
}

pub fn gone(call: String, cause: String) -> Input {
  event(call, "CHANNEL_DESTROY", [#("Hangup-Cause", doc.String(cause))])
}

/// A leg's originate done with it: the leg runs `park`.
pub fn parked(leg: String) -> Input {
  event(leg, "CHANNEL_EXECUTE", [#("Application-Name", doc.String("park"))])
}

/// The marks an answer puts on the caller's channel.
pub fn answer_marks(agent_id: String, at: Int) -> core.Effect {
  core.Mark([
    #("Agent-ID", doc.String(agent_id)),
    #("Queue-Answered-Timestamp", doc.Int(at)),
  ])
}

/// What an answer on `leg` sends the caller: the marks, then the `noop`
/// whose completion shows they ran.
pub fn answer_marking(agent_id: String, at: Int, leg: String) -> List(Effect) {
  [answer_marks(agent_id, at), core.Confirm(core.marks_id(leg))]
}

/// The `noop` behind the marks of an answer on `leg` completed: the marks
/// have run.
pub fn marks_ran(leg: String) -> Input {
  noop_done(core.marks_id(leg))
}

pub fn bridged_to(leg: String) -> Input {
  event(call_id, "CHANNEL_BRIDGE", [#("Other-Leg-Call-ID", doc.String(leg))])
}

pub fn noop_done(msg_id: String) -> Input {
  event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
    #("Application-Name", doc.String("noop")),
    #("Application-Response", doc.String(msg_id)),
  ])
}

pub fn originate_error(id: types.OfferId, cause: String) -> Input {
  core.Originated(
    id,
    doc.object([
      #("Event-Category", doc.String("error")),
      #("Event-Name", doc.String("originate_resp")),
      #("Error-Message", doc.String(cause)),
    ]),
  )
}

pub fn originate_success(id: types.OfferId, leg: String) -> Input {
  core.Originated(
    id,
    doc.object([
      #("Event-Category", doc.String("resource")),
      #("Event-Name", doc.String("originate_resp")),
      #("Application-Response", doc.String("SUCCESS")),
      #("Call-ID", doc.String(leg)),
    ]),
  )
}

/// Take a script of inputs, each at its clock; answer the call at the end
/// and what each step did. The audits a step falls due for are left out:
/// they are every thirty seconds whatever else happens, and `audited`
/// keeps them.
pub fn script(
  call: Call,
  steps: List(#(Input, core.Clock)),
) -> #(Call, List(List(Effect))) {
  let #(call, done) = audited(call, steps)
  #(
    call,
    list.map(done, fn(effects) {
      list.filter(effects, fn(effect) {
        case effect {
          core.Audit(_) -> False
          _ -> True
        }
      })
    }),
  )
}

/// A script, audits and all.
pub fn audited(
  call: Call,
  steps: List(#(Input, core.Clock)),
) -> #(Call, List(List(Effect))) {
  let #(call, done) =
    list.fold(steps, #(call, []), fn(acc, step) {
      let #(call, done) = acc
      let #(call, effects) = core.step(call, step.0, step.1)
      #(call, [effects, ..done])
    })
  #(call, list.reverse(done))
}

pub fn last(effects: List(List(Effect))) -> List(Effect) {
  case list.last(effects) {
    Ok(last) -> last
    Error(Nil) -> []
  }
}

/// A caller waiting in the queue, on hold, the greeting over.
pub fn waiting() -> Call {
  let #(call, _) =
    script(fresh(), [
      #(joining("h1", settings()), at(0)),
      #(
        event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
          #("Application-Name", doc.String("noop")),
        ]),
        at(3),
      ),
    ])
  call
}

/// A short name for the phase a call is in.
pub fn phase_name(call: Call) -> String {
  case call.phase {
    core.Idle -> "idle"
    core.Waiting(..) -> "waiting"
    core.Offering(ring: core.Ringing(_), ..) -> "ringing"
    core.Offering(ring: core.Parking(..), ..) -> "parking"
    core.Offering(ring: core.Connecting(..), ..) -> "connecting"
    core.Connected(..) -> "connected"
    core.Leaving(..) -> "leaving"
    core.Departed(..) -> "departed"
    core.Resuming(..) -> "resuming"
    core.Resumed(..) -> "resumed"
    core.Recovering(..) -> "recovering"
    core.Done -> "done"
  }
}
