//// What the switches say about a caller whose dispatcher did not live to
//// see how their call went.
////
//// A node taking over a shard meets callers whose phones may already be
//// ringing and whose conversations may already be going on: what happened
//// to them is on their record, and what is happening to them now is on the
//// switch. These read the switch's side -- the caller's channel, what it is
//// bridged to, and what the channel's variables say about an answer -- as
//// functions of the channels and the record's numbers, so that what a
//// takeover concludes is something a test reads without a cluster.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc.{type Value}
import kazoo/events

/// The caller's own channel, when a switch is carrying it.
pub fn carried(
  channels: List(events.Channel),
  call_id: String,
) -> Option(events.Channel) {
  channels
  |> list.filter(fn(channel) { channel.call_id == call_id })
  |> list.first
  |> option.from_result
}

/// The leg a channel is bridged to, when it is bridged to one.
pub fn bridged(channel: events.Channel) -> Option(String) {
  case channel.other_leg {
    Some("") | None -> None
    Some(other_leg) -> Some(other_leg)
  }
}

/// Whether the switches say the caller is already through, and to which leg.
pub fn already_through(
  channels: List(events.Channel),
  call_id: String,
) -> Option(#(String, Option(String))) {
  case carried(channels, call_id) {
    None -> None
    Some(channel) ->
      case bridged(channel) {
        None -> None
        Some(other_leg) -> Some(#(other_leg, channel_agent(channel)))
      }
  }
}

/// When a bridge that left no event to read happened.
///
/// The offer that died wrote `Queue-Answered-Timestamp` on the caller's
/// channel the moment it answered, so a channel carrying one says the second
/// the caller was through and the CDR, the record and the reply all keep
/// agreeing. A channel without one was bridged by an offer that did not get
/// that far, and the nearest thing left is the second that offer began --
/// which is on the record. Either is better than the second this node
/// happened to look, which is a failover later and would be counted as talk
/// time nobody talked. A timestamp from before that offer began is an earlier
/// passage's answer, left by an action of the release before this one, which
/// did not clear it when the caller joined.
pub fn answered_at(channel: events.Channel, offered_at: Int, now: Int) -> Int {
  case answered_var(channel.doc) {
    Some(at) if at > 0 && at >= offered_at -> at
    _unmarked ->
      case offered_at > 0 {
        True -> offered_at
        False -> now
      }
  }
}

/// The agent the offer that died marked the caller's channel with -- on a
/// channel's status or on one of the caller's events -- when it was that
/// offer, in this passage, that marked it.
///
/// `Agent-ID` alone does not say. An action of the release before this one
/// left the `Agent-ID` and `Queue-Answered-Timestamp` of an earlier passage's
/// answer on the channel when the caller joined another queue: a caller the
/// first queue's agent transferred into a second one carries that agent's
/// name into the second queue. Read as this offer's mark, the takeover
/// skipped the attribution and the recording for the agent who really
/// answered and dated the answer by the first agent's second. The offer
/// sets both variables in one `set`, so the mark is this offer's when its
/// timestamp is no earlier than the second the offer began -- the record's,
/// written on the node whose clock the offer answered by -- or, with no
/// such second, than the second the caller joined.
pub fn marked_agent(
  offered_at offered_at: Int,
  joined joined: Int,
  carrier carrier: Value,
) -> Option(String) {
  let since = case offered_at > 0 {
    True -> offered_at
    False -> joined
  }
  case
    doc.get_string(carrier, ["Custom-Channel-Vars", "Agent-ID"]),
    answered_var(carrier)
  {
    Ok(""), _ | Error(Nil), _ -> None
    Ok(agent_id), Some(at) if at >= since -> Some(agent_id)
    Ok(_earlier), _ -> None
  }
}

/// The `Queue-Answered-Timestamp` on a channel or an event: a number where
/// this application wrote it, and the switch's text of one where the switch
/// hands it back.
fn answered_var(carrier: Value) -> Option(Int) {
  let path = ["Custom-Channel-Vars", "Queue-Answered-Timestamp"]
  case doc.get_int(carrier, path), doc.get_string(carrier, path) {
    Ok(at), _ -> Some(at)
    _, Ok(text) -> option.from_result(int.parse(text))
    _, _ -> None
  }
}

pub fn channel_agent(channel: events.Channel) -> Option(String) {
  case doc.get_string(channel.doc, ["Custom-Channel-Vars", "Agent-ID"]) {
    Ok("") | Error(Nil) -> None
    Ok(agent_id) -> Some(agent_id)
  }
}
