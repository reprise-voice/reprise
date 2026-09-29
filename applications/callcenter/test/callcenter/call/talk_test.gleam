//// What the switch says became of a ring nobody answered, and whose
//// answer one event names.

import callcenter/call/talk
import callcenter/types
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc

const caller_leg = "9f8e7d6c-5b4a-3210"

const agent_leg = "1a2b3c4d-5e6f-7080"

fn event(members: List(#(String, doc.Value))) -> doc.Value {
  doc.object([#("Event-Category", doc.String("call_event")), ..members])
}

/// The caller leg's `CHANNEL_EXECUTE_COMPLETE` for the bridge, which is what
/// the switch says when a ring came to nothing.
fn bridge_completed(response: String) -> doc.Value {
  event([
    #("Event-Name", doc.String("CHANNEL_EXECUTE_COMPLETE")),
    #("Application-Name", doc.String("bridge")),
    #("Application-Response", doc.String(response)),
    #("Call-ID", doc.String(caller_leg)),
    #("Disposition", doc.String(response)),
  ])
}

pub fn cause_prefers_the_bridge_response_test() {
  assert talk.cause(bridge_completed("USER_BUSY")) == "USER_BUSY"
  assert talk.cause(
      event([
        #("Call-ID", doc.String(caller_leg)),
        #("Hangup-Cause", doc.String("normal_clearing")),
      ]),
    )
    == "NORMAL_CLEARING"
  assert talk.cause(event([#("Call-ID", doc.String(caller_leg))]))
    == "UNSPECIFIED"
}

pub fn a_busy_phone_test() {
  assert talk.miss(bridge_completed("USER_BUSY")) == talk.WasBusy
}

pub fn a_rejected_call_test() {
  assert talk.miss(bridge_completed("CALL_REJECTED")) == talk.WasRejected
}

pub fn nobody_picked_up_test() {
  assert talk.miss(bridge_completed("NO_ANSWER")) == talk.NotAnswered
  assert talk.miss(bridge_completed("NO_USER_RESPONSE")) == talk.NotAnswered
  assert talk.miss(bridge_completed("ALLOTTED_TIMEOUT")) == talk.NotAnswered
}

/// A ring cancelled from the caller's side is nobody's miss: the caller hung
/// up, or is leaving the queue some other way.
pub fn a_cancel_from_the_callers_side_is_not_a_miss_test() {
  assert talk.miss(bridge_completed("ORIGINATOR_CANCEL")) == talk.Cancelled
  assert talk.miss_reply(talk.Cancelled, ["agent-a"])
    == types.Failed(talk.originator_cancel)
}

/// A bridge that says nothing at all is a ring that ran out, not a fault.
pub fn an_unspecified_bridge_is_a_no_answer_test() {
  assert talk.miss(bridge_completed("UNSPECIFIED")) == talk.NotAnswered
}

pub fn anything_else_is_a_failure_test() {
  assert talk.miss(bridge_completed("UNALLOCATED_NUMBER"))
    == talk.Broke("UNALLOCATED_NUMBER")
}

pub fn one_agent_takes_the_blame_test() {
  assert talk.miss_reply(talk.WasBusy, ["agent-a"]) == types.Busy("agent-a")
  assert talk.miss_reply(talk.WasRejected, ["agent-a"])
    == types.Rejected("agent-a")
  assert talk.miss_reply(talk.NotAnswered, ["agent-a"])
    == types.OfferNoAnswer(["agent-a"])
}

/// A simultaneous ring gets one cause for every phone, so a busy cannot be
/// pinned on one of them: they are all reported as not having answered.
pub fn many_agents_share_a_miss_test() {
  let agents = ["agent-a", "agent-b"]
  assert talk.miss_reply(talk.WasBusy, agents) == types.OfferNoAnswer(agents)
  assert talk.miss_reply(talk.WasRejected, agents)
    == types.OfferNoAnswer(agents)
  assert talk.miss_reply(talk.NotAnswered, agents)
    == types.OfferNoAnswer(agents)
}

pub fn a_failure_carries_its_cause_test() {
  assert talk.miss_reply(talk.Broke("NO_ROUTE_DESTINATION"), ["agent-a"])
    == types.Failed("NO_ROUTE_DESTINATION")
}

pub fn a_bridge_that_ended_cleanly_completed_test() {
  assert talk.ended_as(bridge_completed("SUCCESS")) == types.Completed
  assert talk.ended_as(bridge_completed("NORMAL_CLEARING")) == types.Completed
  assert talk.ended_as(bridge_completed("MEDIA_TIMEOUT")) == types.FailedBridge
}

pub fn the_bridge_command_is_recognised_test() {
  assert talk.is_bridge(bridge_completed("SUCCESS")) == True
  assert talk.is_bridge(event([#("Application-Name", doc.String("play"))]))
    == False
  assert talk.is_bridge_error(
      doc.object([
        #("Event-Category", doc.String("error")),
        #("Application-Name", doc.String("bridge")),
      ]),
    )
    == True
  assert talk.is_bridge_error(bridge_completed("SUCCESS")) == False
}

/// The caller leg's bridge event says which channel answered, not whose it
/// is; with one agent rung there is no question.
pub fn one_agent_answered_test() {
  let bridged =
    event([
      #("Event-Name", doc.String("CHANNEL_BRIDGE")),
      #("Call-ID", doc.String(caller_leg)),
      #("Other-Leg-Call-ID", doc.String(agent_leg)),
    ])
  assert talk.answering_agent(["agent-a"], bridged) == Some("agent-a")
  assert talk.answering_agent(["agent-a", "agent-b"], bridged) == None
}

/// The agent's own leg carries the `Agent-ID` the endpoint was marked with.
pub fn the_agent_leg_says_whose_it_is_test() {
  let answered =
    event([
      #("Event-Name", doc.String("CHANNEL_ANSWER")),
      #("Call-ID", doc.String(agent_leg)),
      #("Other-Leg-Call-ID", doc.String(caller_leg)),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Agent-ID", doc.String("agent-b"))]),
      ),
    ])
  assert talk.agent_of(answered, ["agent-a", "agent-b"]) == Some("agent-b")
  assert talk.answering_agent(["agent-a", "agent-b"], answered)
    == Some("agent-b")
}

/// A device with no `Agent-ID` still names its owner, which is the agent.
pub fn the_owner_of_the_device_is_the_agent_test() {
  let answered =
    event([
      #("Call-ID", doc.String(agent_leg)),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Owner-ID", doc.String("agent-a"))]),
      ),
    ])
  assert talk.agent_of(answered, ["agent-a", "agent-b"]) == Some("agent-a")
}

/// A leg belonging to somebody who was not offered this caller is not an
/// answer: another call of theirs may be going on at the same time.
pub fn a_stranger_is_not_an_agent_test() {
  let answered =
    event([
      #("Call-ID", doc.String(agent_leg)),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Owner-ID", doc.String("somebody-else"))]),
      ),
    ])
  assert talk.agent_of(answered, ["agent-a", "agent-b"]) == None
}

// --- A call that was answered ----------------------------------------------

const now = 63_800_000_200

const now_ms = 5_000_000

const operator_leg = "0p3r4t0r-0000-0001"

fn talking() -> talk.Talk {
  talk.Talk(caller: caller_leg, leg: Some(agent_leg), closing: None)
}

fn closing_since(result: types.EndResult, at: Int) -> talk.Talk {
  talk.Talk(
    ..talking(),
    closing: Some(talk.Closing(
      result: result,
      at: at,
      until: now_ms + talk.transfer_wait_ms,
    )),
  )
}

fn on(call_id: String, name: String, more: List(#(String, doc.Value))) {
  event([
    #("Event-Name", doc.String(name)),
    #("Call-ID", doc.String(call_id)),
    ..more
  ])
}

/// One event, in a call that was answered, and what it does: a table of the
/// call's state before, the event, and the reading after. Every row is one
/// rule of `talk.heard`.
pub fn what_an_event_does_to_a_call_test() {
  let ended = closing_since(types.Completed, now - 1)
  let cases = [
    // The caller went: nobody is left to hang up, and a bridge already
    // ending is dated by its end.
    #(
      talking(),
      on(caller_leg, "CHANNEL_DESTROY", []),
      talk.Over(types.CallerHangup, now),
    ),
    #(
      ended,
      on(caller_leg, "CHANNEL_DESTROY", []),
      talk.Over(types.Completed, now - 1),
    ),
    // The bridge ended, three ways: wait to see whether it was a transfer.
    #(
      talking(),
      on(agent_leg, "CHANNEL_DESTROY", []),
      talk.Talking(closing_since(types.Completed, now)),
    ),
    #(
      talking(),
      on(caller_leg, "CHANNEL_UNBRIDGE", []),
      talk.Talking(closing_since(types.Completed, now)),
    ),
    #(
      talking(),
      bridge_completed("USER_BUSY"),
      talk.Talking(closing_since(types.FailedBridge, now)),
    ),
    // The first end is the one that counts.
    #(ended, on(agent_leg, "CHANNEL_DESTROY", []), talk.Talking(ended)),
    // A transfer, however it shows itself, ends the queue's part and
    // leaves the caller alone, as of the bridge's end when there was one.
    #(
      talking(),
      on(caller_leg, "CHANNEL_TRANSFEREE", []),
      talk.Over(types.Transferred, now),
    ),
    #(
      ended,
      on(agent_leg, "CHANNEL_TRANSFEROR", []),
      talk.Over(types.Transferred, now - 1),
    ),
    #(
      talking(),
      on(agent_leg, "CHANNEL_REPLACED", []),
      talk.Over(types.Transferred, now),
    ),
    #(
      talking(),
      on(agent_leg, "CHANNEL_DESTROY", [
        #("Hangup-Cause", doc.String("BLIND_TRANSFER")),
      ]),
      talk.Over(types.Transferred, now),
    ),
    #(
      ended,
      on(caller_leg, "CHANNEL_BRIDGE", [
        #("Other-Leg-Call-ID", doc.String(operator_leg)),
      ]),
      talk.Over(types.Transferred, now - 1),
    ),
    // The caller bridged to the agent again is not a transfer, and neither
    // is a bridge before the agent's ended.
    #(
      ended,
      on(caller_leg, "CHANNEL_BRIDGE", [
        #("Other-Leg-Call-ID", doc.String(agent_leg)),
      ]),
      talk.Talking(ended),
    ),
    #(
      talking(),
      on(caller_leg, "CHANNEL_BRIDGE", [
        #("Other-Leg-Call-ID", doc.String(operator_leg)),
      ]),
      talk.Talking(talking()),
    ),
    // Somebody else's call, or nothing that matters.
    #(
      talking(),
      on(operator_leg, "CHANNEL_DESTROY", []),
      talk.Talking(talking()),
    ),
    #(talking(), on(caller_leg, "DTMF", []), talk.Talking(talking())),
  ]
  list.each(cases, fn(case_) {
    let #(before, heard, after) = case_
    assert talk.heard(before, heard, now, now_ms) == after
  })
}

/// Nothing heard until the deadline: an end nothing said was a transfer is
/// the call over, and the caller goes with the agent; a call with no end in
/// sight ran past the longest a call is watched.
pub fn the_silence_after_a_call_test() {
  assert talk.silence(closing_since(types.Completed, now - 1), now)
    == talk.HangUp(types.Completed, now - 1)
  assert talk.silence(talking(), now) == talk.Over(types.FailedBridge, now)
}

/// The wait for an end to be read is `transfer_wait_ms`; otherwise the call
/// is watched for as long as a call may run.
pub fn how_long_a_call_waits_test() {
  assert talk.deadline(closing_since(types.Completed, now), now_ms, 60_000)
    == now_ms + talk.transfer_wait_ms
  assert talk.deadline(talking(), now_ms, 60_000) == now_ms + 60_000
}
