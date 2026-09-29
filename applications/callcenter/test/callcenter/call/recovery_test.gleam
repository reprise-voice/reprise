//// What the switches say about a caller taken over: already through, and
//// to whom, or not.

import callcenter/call/recovery
import gleam/option.{None, Some}
import kazoo/doc
import kazoo/events

const caller_leg = "9f8e7d6c-5b4a-3210"

const agent_leg = "1a2b3c4d-5e6f-7080"

const offered_at = 63_800_000_100

fn channel(
  call_id: String,
  other_leg: List(#(String, doc.Value)),
) -> events.Channel {
  events.channel(doc.object([#("Call-ID", doc.String(call_id)), ..other_leg]))
}

/// A channel the offer that died marked before it went.
fn marked_channel(answered_at: Int) -> events.Channel {
  channel(caller_leg, [
    #("Other-Leg-Call-ID", doc.String(agent_leg)),
    #(
      "Custom-Channel-Vars",
      doc.object([
        #("Agent-ID", doc.String("ann")),
        #("Queue-Answered-Timestamp", doc.Int(answered_at)),
      ]),
    ),
  ])
}

/// A bridge that happened while the shard was moving leaves no event for a
/// new watcher to hear, so the caller's channel is asked about once. One
/// bridged to another leg is a caller who is already talking.
pub fn a_channel_already_bridged_test() {
  assert recovery.already_through([marked_channel(offered_at + 2)], caller_leg)
    == Some(#(agent_leg, Some("ann")))
}

/// One that is still on its own is a caller nobody has taken.
pub fn a_channel_on_its_own_test() {
  assert recovery.already_through([channel(caller_leg, [])], caller_leg) == None
  assert recovery.already_through([], caller_leg) == None
}

/// Somebody else's channel is not this caller's.
pub fn another_callers_channel_test() {
  assert recovery.already_through(
      [
        channel("somebody-else", [#("Other-Leg-Call-ID", doc.String(agent_leg))]),
      ],
      caller_leg,
    )
    == None
}
