//// What is on a member queue, and what comes back off it.

import callcenter/member
import gleam/option.{None, Some}
import kazoo/doc

pub fn call_message_round_trip_test() {
  let message =
    member.call_message(
      account_id: "4b1f0c2d7e8a9b0c1d2e3f4051627384",
      queue_id: "support",
      call_id: "call-one",
      node: "kazoo_apps@127.0.0.1",
      joined_at: 1_757_500_000,
      priority: 0,
      call: member.stub_call("call-one", "kazoo_apps@127.0.0.1"),
    )

  let decoded = member.decode(message)
  assert decoded.kind == member.Call
  assert decoded.account_id == "4b1f0c2d7e8a9b0c1d2e3f4051627384"
  assert decoded.queue_id == "support"
  assert decoded.call_id == "call-one"
  assert decoded.node == Some("kazoo_apps@127.0.0.1")
  assert decoded.joined_at == 1_757_500_000
  assert decoded.priority == 0
  assert decoded.caller_id_name == None

  // The call the message carries is what a dispatcher rebuilds `kapps_call`
  // from, so it has to survive the round trip whole.
  assert doc.get_string(message, ["Call", "Call-ID"]) == Ok("call-one")
}

pub fn cancel_message_round_trip_test() {
  let message =
    member.cancel_message(
      account_id: "4b1f0c2d7e8a9b0c1d2e3f4051627384",
      queue_id: "support",
      call_id: "call-one",
      node: "kazoo_apps@127.0.0.2",
      reason: "abandoned",
      cancelled_at: 1_757_500_060,
    )
  let decoded = member.decode(message)

  assert decoded.kind == member.Cancel
  assert decoded.call_id == "call-one"
  assert decoded.cancelled_at == Some(1_757_500_060)
  assert doc.get_string(message, ["Reason"]) == Ok("abandoned")
}

/// A message this release does not know is a member with empty fields, not a
/// crash in the listener that received it.
pub fn decode_is_total_test() {
  let empty = member.decode(doc.object([]))
  assert empty.kind == member.Unknown("")
  assert empty.account_id == ""
  assert empty.call_id == ""
  assert empty.node == None
  assert empty.joined_at == 0
  // A cancel from a node that did not say when the caller left.
  assert empty.cancelled_at == None
  assert empty.priority == 0
  assert empty.call == doc.object([])

  let later =
    doc.object([
      #("Event-Name", doc.String("member_reprioritise")),
      #("Call-ID", doc.String("call-two")),
    ])
  let decoded = member.decode(later)
  assert decoded.kind == member.Unknown("member_reprioritise")
  assert decoded.call_id == "call-two"
}

pub fn kind_names_test() {
  assert member.kind_to_string(member.Call) == "member_call"
  assert member.kind_to_string(member.Cancel) == "member_cancel"
  assert member.kind_from_string("member_call") == member.Call
  assert member.kind_from_string("member_cancel") == member.Cancel
}

/// When the caller entered the system is the channel variable the callflow
/// action stamps: a number as the action passes the call on, the text of one
/// as the switch hands the channel's variables back, nothing when unstamped.
pub fn system_joined_test() {
  let call = fn(value) {
    doc.object([
      #("Custom-Channel-Vars", doc.object([#("Queue-System-Joined", value)])),
    ])
  }
  assert member.system_joined(call(doc.Int(63_800_000_100)))
    == Some(63_800_000_100)
  assert member.system_joined(call(doc.String("63800000100")))
    == Some(63_800_000_100)
  assert member.system_joined(call(doc.String("soon"))) == None
  assert member.system_joined(call(doc.Int(0))) == None
  assert member.system_joined(doc.object([])) == None
}
