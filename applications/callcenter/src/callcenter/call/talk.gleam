//// A caller through to an agent: how the call ends, and what the switch's
//// words for an ended ring or an ended call mean to the queue.
////
//// Two readings live here. The first is of a ring that ended without an
//// answer -- whose miss it is, if anybody's (`miss`, `miss_reply`). The
//// second is of a call that was answered: the end of the agent's bridge,
//// which may be the call being over or the agent passing the caller on
//// (`heard`, `silence`). An agent transferring the caller from their phone
//// ends the bridge exactly as hanging up does, and the switch's transfer
//// events can arrive a moment after the bridge's end, so the end waits
//// `transfer_wait_ms` for a sign before it is read as the call being over.
////
//// Both are functions of an event and the time; nothing here touches the
//// switch or the dispatcher.

import callcenter/types.{type EndResult, type OfferReply}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/doc.{type Value}
import kazoo/events

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

/// The end of an answered bridge that may yet turn out to be a transfer:
/// what it is if it does not, when it happened (a calendar second), and
/// until when the offer waits to find out (a monotonic millisecond).
pub type Closing {
  Closing(result: types.EndResult, at: Int, until: Int)
}

/// The wait on an answered bridge's end, begun at `now` (a calendar second)
/// and `now_ms` (a monotonic millisecond). A takeover's watch waits the same.
pub fn closing(result: types.EndResult, now: Int, now_ms: Int) -> Closing {
  Closing(result: result, at: now, until: now_ms + transfer_wait_ms)
}

/// Whether an event says the call is being transferred.
///
/// The switch's own transfer events -- `CHANNEL_TRANSFEREE` on the channel
/// being passed on, `CHANNEL_TRANSFEROR` on the one passing it,
/// `CHANNEL_REPLACED` on a leg an attended transfer replaced -- for either
/// leg of this call, and the agent's leg going with a transfer as its cause,
/// which is how `mod_com_kazoo` reports a leg that sent a `REFER`.
/// `bridged_to` is the agent's leg, once there is one.
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

/// A bridge that ended cleanly after an answer is a completed call; one that
/// ended any other way dropped, which the dispatcher counts differently.
pub fn ended_as(event: Value) -> types.EndResult {
  case cause(event) {
    "SUCCESS" | "NORMAL_CLEARING" | "ANSWER" | "UNSPECIFIED" -> types.Completed
    _other -> types.FailedBridge
  }
}

/// The failure a ring called off from the caller's side is reported as.
pub const originator_cancel = "originator_cancel"

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

/// A caller through to an agent, as the call goes on.
pub type Talk {
  Talk(
    /// The caller's call id.
    caller: String,
    /// The agent's leg, when it is known.
    leg: Option(String),
    /// The bridge has ended, and the call is waiting to see whether it was a
    /// transfer.
    closing: Option(Closing),
  )
}

/// What one event, or the silence after it, does to a call that was
/// answered.
pub type Heard {
  /// The call goes on, or the end of its bridge is waiting to be read.
  Talking(Talk)
  /// The call is over, as of `at`, and the caller is left as they are: they
  /// hung up, or the agent passed them on.
  Over(result: EndResult, at: Int)
  /// The agent's bridge ended and it was not a transfer: the call is over,
  /// as of `at`, and the caller is hung up after the agent -- which is
  /// today's `hangup_after_bridge`.
  HangUp(result: EndResult, at: Int)
}

/// What one event means once the caller is through to an agent, at `now` on
/// the calendar and `now_ms` on the monotonic clock.
///
/// The end of the bridge -- the caller unbridged, the agent's leg gone, the
/// bridge command finished -- used to hang the caller up at once. An agent
/// transferring the caller from their phone produces exactly those events,
/// and the caller being put through to the transfer's target was hung up on
/// the way. So the end waits `transfer_wait_ms` for a sign that it was a
/// transfer, and a transfer ends the queue's part without touching the
/// caller.
pub fn heard(talk: Talk, event: Value, now: Int, now_ms: Int) -> Heard {
  let leg = events.call_id(event)
  let from_caller = leg == Some(talk.caller)
  let from_agent = option.is_some(leg) && leg == talk.leg
  case is_transfer_of(talk.caller, talk.leg, event), events.event_name(event) {
    True, _ -> transferred(talk, now)

    // The caller went: there is nobody left to hang up.
    False, Some("CHANNEL_DESTROY") if from_caller ->
      case talk.closing {
        Some(closing) -> Over(closing.result, closing.at)
        None -> Over(types.CallerHangup, now)
      }

    False, Some("CHANNEL_DESTROY") if from_agent ->
      bridge_ended(talk, types.Completed, now, now_ms)
    False, Some("CHANNEL_UNBRIDGE") if from_caller ->
      bridge_ended(talk, types.Completed, now, now_ms)
    False, Some("CHANNEL_EXECUTE_COMPLETE") if from_caller ->
      case is_bridge(event) {
        True -> bridge_ended(talk, ended_as(event), now, now_ms)
        False -> Talking(talk)
      }

    // The caller bridged again, to a leg that is not the agent's, after the
    // agent's bridge ended: an attended transfer putting them through to
    // its target.
    False, Some("CHANNEL_BRIDGE") if from_caller ->
      case talk.closing, events.other_leg_call_id(event) == talk.leg {
        Some(_closing), False -> transferred(talk, now)
        _, _ -> Talking(talk)
      }

    _, _ -> Talking(talk)
  }
}

/// Nothing was heard until the deadline (`deadline`): the end of a bridge
/// that nothing said was a transfer is the call being over, and the caller
/// goes with the agent. A call with no end waiting has run past the longest
/// a call is watched, and is given up on as `FailedBridge`, the result for
/// a call whose end nobody saw.
pub fn silence(talk: Talk, now: Int) -> Heard {
  case talk.closing {
    Some(closing) -> HangUp(closing.result, closing.at)
    None -> Over(types.FailedBridge, now)
  }
}

/// Until when a call that was answered waits for its next event, from
/// `now_ms`, both monotonic milliseconds: the end of a bridge waiting to be
/// read, or `longest_ms` after now.
pub fn deadline(talk: Talk, now_ms: Int, longest_ms: Int) -> Int {
  case talk.closing {
    Some(closing) -> closing.until
    None -> now_ms + longest_ms
  }
}

/// The answered bridge has ended; wait a moment to see whether it was a
/// transfer. The first end is the one that counts.
fn bridge_ended(talk: Talk, result: EndResult, now: Int, now_ms: Int) -> Heard {
  case talk.closing {
    Some(_already) -> Talking(talk)
    None -> Talking(Talk(..talk, closing: Some(closing(result, now, now_ms))))
  }
}

/// The agent passed the caller on. The queue's part is over, as of the
/// moment the agent's bridge ended, and the caller is left alone.
fn transferred(talk: Talk, now: Int) -> Heard {
  case talk.closing {
    Some(closing) -> Over(types.Transferred, closing.at)
    None -> Over(types.Transferred, now)
  }
}
