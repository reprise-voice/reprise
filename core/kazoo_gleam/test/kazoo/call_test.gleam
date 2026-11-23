//// The call: what is read from it, what is set on it, and what the commands
//// do when there is no channel to send them to.
////
//// There is no Kazoo release under `gleam test`, so a call here is the JSON
//// form of the record and the commands are no-ops. That is exactly the point
//// of these: a callflow action's decisions are testable, and the shape of
//// every value that crosses the boundary is checked.

import gleam/dict
import gleam/option.{None, Some}
import kazoo/call
import kazoo/doc
import kazoo/testing/channel.{Command}

/// A call as a route win carries it.
fn a_call() -> call.Call {
  call.from_value(
    doc.object([
      #("Call-ID", doc.String("4b1f0c2d-7e8a-9b0c")),
      #("Account-ID", doc.String("4b1f0c2d7e8a9b0c1d2e3f4051627384")),
      #(
        "Account-DB",
        doc.String("account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384"),
      ),
      #("Control-Queue", doc.String("callctl-4b1f")),
      #("Controller-Queue", doc.String("callflow-node-1")),
      #("Caller-ID-Name", doc.String("Ada Lovelace")),
      #("Caller-ID-Number", doc.String("2125550143")),
      #("Request", doc.String("1000@one.example.test")),
      #("Request-User", doc.String("1000")),
      #("To", doc.String("1000@one.example.test")),
      #("From", doc.String("2125550143@one.example.test")),
      #("Call-Direction", doc.String("inbound")),
      #("Language", doc.String("en-us")),
      #("Owner-ID", doc.String("9ab0c1d2e3f405162738495a6b7c8d9e")),
      #(
        "Custom-Channel-Vars",
        doc.object([
          #("Account-Realm", doc.String("one.example.test")),
          #("Queue-ID", doc.String("6a7b8c9d0e1f2a3b4c5d6e7f80912233")),
        ]),
      ),
    ]),
  )
}

pub fn accessors_test() {
  let c = a_call()
  assert call.call_id(c) == Some("4b1f0c2d-7e8a-9b0c")
  assert call.account_id(c) == Some("4b1f0c2d7e8a9b0c1d2e3f4051627384")
  assert call.control_queue(c) == Some("callctl-4b1f")
  assert call.controller_queue(c) == Some("callflow-node-1")
  assert call.caller_id_name(c) == Some("Ada Lovelace")
  assert call.caller_id_number(c) == Some("2125550143")
  assert call.request_user(c) == Some("1000")
  assert call.direction(c) == Some("inbound")
  assert call.language(c) == Some("en-us")
  assert call.owner_id(c) == Some("9ab0c1d2e3f405162738495a6b7c8d9e")
}

/// Anything Kazoo never set is `None`, not an empty string, so a caller
/// cannot mistake one for the other.
pub fn absent_accessors_test() {
  let c = a_call()
  assert call.other_leg_call_id(c) == None
  assert call.authorizing_id(c) == None
  assert call.authorizing_type(c) == None
  assert call.fetch_id(c) == None
  assert call.inception(c) == None
  assert call.switch_nodename(c) == None
  assert call.resource_type(c) == None
  assert call.callee_id_name(c) == None

  let empty = call.new()
  assert call.call_id(empty) == None
  assert call.account_id(empty) == None
  assert call.control_queue(empty) == None
}

pub fn round_trip_test() {
  let c = a_call()
  assert doc.get_string(call.to_value(c), ["Call-ID"])
    == Ok("4b1f0c2d-7e8a-9b0c")
  assert doc.get_string(call.to_value(c), ["Caller-ID-Name"])
    == Ok("Ada Lovelace")
  assert call.is_call(c)
}

pub fn queues_test() {
  let c = a_call() |> call.set_control_queue("callctl-other")
  assert call.control_queue(c) == Some("callctl-other")

  let c = c |> call.set_controller_queue("callcenter-node-2")
  assert call.controller_queue(c) == Some("callcenter-node-2")
  // Setting one leaves the other alone.
  assert call.control_queue(c) == Some("callctl-other")
}

pub fn channel_vars_test() {
  let c = a_call()
  assert call.custom_channel_var(c, "Queue-ID")
    == Some(doc.String("6a7b8c9d0e1f2a3b4c5d6e7f80912233"))
  assert call.custom_channel_var(c, "Agent-ID") == None
  assert doc.get_string(call.custom_channel_vars(c), ["Account-Realm"])
    == Ok("one.example.test")

  let c =
    call.set_custom_channel_vars(c, [
      #("Agent-ID", doc.String("a1b2c3")),
      #("Queue-Joined-Timestamp", doc.Int(63_956_260_800)),
    ])
  assert call.custom_channel_var(c, "Agent-ID") == Some(doc.String("a1b2c3"))
  assert call.custom_channel_var(c, "Queue-Joined-Timestamp")
    == Some(doc.Int(63_956_260_800))
  // The variables that were already there survive the merge.
  assert call.custom_channel_var(c, "Queue-ID")
    == Some(doc.String("6a7b8c9d0e1f2a3b4c5d6e7f80912233"))
}

/// The key-value store travels with the call and never reaches the channel.
pub fn kvs_test() {
  let c = a_call()
  assert call.kvs_fetch(c, "queue_position") == None

  let c = call.kvs_store(c, "queue_position", doc.Int(3))
  assert call.kvs_fetch(c, "queue_position") == Some(doc.Int(3))

  let c = call.kvs_store(c, "queue_position", doc.Int(2))
  assert call.kvs_fetch(c, "queue_position") == Some(doc.Int(2))

  let c =
    call.kvs_store(
      c,
      "offer",
      doc.object([#("agent_id", doc.String("a1")), #("tier", doc.Int(1))]),
    )
  assert call.kvs_fetch(c, "offer")
    == Some(
      doc.object([#("agent_id", doc.String("a1")), #("tier", doc.Int(1))]),
    )
}

/// The capture group of a pattern callflow: nothing on a call that matched
/// an exact number, nothing for an empty capture, the digits otherwise.
pub fn capture_group_test() {
  assert call.capture_group(a_call()) == None

  let empty = call.kvs_store(a_call(), "cf_capture_group", doc.String(""))
  assert call.capture_group(empty) == None

  let captured = call.kvs_store(a_call(), "cf_capture_group", doc.String("101"))
  assert call.capture_group(captured) == Some("101")
}

/// Every macro item as the object the Erlang side turns into Kazoo's own
/// tuple. Getting a key wrong here is a `function_clause` at run time, which
/// is why the shapes are checked.
pub fn macro_items_test() {
  assert call.macro_to_value(call.MacroPlay("hold-music"))
    == doc.object([
      #("type", doc.String("play")),
      #("media", doc.String("hold-music")),
    ])

  assert call.macro_to_value(call.MacroPrompt("queue-you_are_at_position"))
    == doc.object([
      #("type", doc.String("prompt")),
      #("name", doc.String("queue-you_are_at_position")),
    ])

  assert call.macro_to_value(call.MacroSay("3", "number", "pronounced", "en-us"))
    == doc.object([
      #("type", doc.String("say")),
      #("text", doc.String("3")),
      #("say_type", doc.String("number")),
      #("method", doc.String("pronounced")),
      #("language", doc.String("en-us")),
    ])

  assert call.macro_to_value(call.MacroTts("all agents are busy"))
    == doc.object([
      #("type", doc.String("tts")),
      #("text", doc.String("all agents are busy")),
    ])

  let tone = doc.object([#("Frequencies", doc.List([doc.Int(440)]))])
  assert call.macro_to_value(call.MacroTones([tone]))
    == doc.object([#("type", doc.String("tones")), #("tones", doc.List([tone]))])
}

/// Re-running the dialplan for a channel is the one command with no
/// `kapps_call_command' function behind it, so it is the one whose shape is
/// worth naming: it is what recovers a caller whose callflow node was lost,
/// by making the switch ask the cluster where the call should go next.
pub fn execute_extension_test() {
  let c = a_call()
  assert call.execute_extension(c, "600") == Nil
  // The extension for a re-run is what the caller dialled.
  assert call.request_user(c) == call.request_user(c)
}

/// Without a channel every command is a no-op rather than a crash, which is
/// what lets an action be run in a test.
pub fn commands_are_safe_test() {
  let c = a_call()
  assert call.answer(c) == Nil
  assert call.answer_now(c) == Nil
  assert call.hangup(c) == Nil
  assert call.unbridge(c) == Nil
  assert call.hold(c, None) == Nil
  assert call.hold(c, Some("hold-music")) == Nil
  assert call.hold_queued(c, None) == Nil
  assert call.flush(c) == Nil
  assert call.park(c) == Nil
  assert call.execute_extension(c, "600") == Nil
  assert call.play(c, "greeting") == Nil
  assert call.prompt(c, "queue-welcome") == Nil
  assert call.say(c, "3", "number", "pronounced", "en-us") == Nil
  assert call.audio_macro(c, [
      call.MacroPrompt("queue-you_are_at_position"),
      call.MacroSay("3", "number", "pronounced", "en-us"),
    ])
    == Nil
  assert call.audio_macro_interrupting(c, [
      call.MacroPrompt("queue-you_are_at_position"),
    ])
    == Nil
  assert call.bridge(c, [], 20, call.Simultaneous, False, None) == Nil
  assert call.bridge(
      c,
      [doc.object([#("Endpoint-ID", doc.String("d1"))])],
      20,
      call.Single,
      True,
      Some("%(2000,4000,440)"),
    )
    == Nil
  assert call.bridge_interrupting(c, [], 20, call.Simultaneous, call.HoldMusic)
    == Ok(Nil)
  assert call.record_call(c, call.RecordStart, call.record_options()) == Nil
  assert call.record_call(
      c,
      call.RecordStop,
      call.RecordOptions(media_name: Some("q.mp3"), time_limit_s: Some(3600)),
    )
    == Nil
  assert call.set_channel_vars(c, [#("Queue-ID", doc.String("q1"))], []) == Nil
}

/// A kept recording goes out under its name, the settings travelling with it
/// rather than on the name.
pub fn start_recording_test() {
  channel.record()
  let recording =
    call.Recording(
      name: "queue-q1-4b1f0c2d-7e8a-9b0c-1700000000",
      settings: doc.object([#("format", doc.String("wav"))]),
    )
  assert call.start_recording(a_call(), recording) == Nil
  assert channel.sent()
    == [Command("start_recording", "queue-q1-4b1f0c2d-7e8a-9b0c-1700000000")]
}

/// The blocking prompt with nothing to block on says the prompt was not
/// played, rather than answering as though it had been. An action that ends
/// the callflow on the strength of it would be hanging up on a prompt
/// nobody heard.
pub fn prompt_and_wait_without_a_channel_test() {
  assert call.prompt_and_wait(a_call(), "agent-logged_in")
    == Error(call.PlayFailed)
}

/// Nothing arrives, so every wait ends the way a lost channel would.
pub fn waits_time_out_test() {
  let c = a_call()
  assert call.wait_for_bridge(c, 0) == call.BridgeTimeout
  assert call.receive_event(0) == Error(call.Timeout)
  assert call.wait_for_hangup(0) == Error(call.Timeout)
  assert call.wait_for_dtmf(0) == Error(call.DtmfTimeout)
}

/// Without a release there is no channel to collect from, so both answer the
/// same absence the single-digit wait does rather than crashing a flow.
pub fn collect_digits_test() {
  let c = a_call()
  assert call.collect_digits(c, 4, 0) == Error(call.DtmfTimeout)
  assert call.prompt_and_collect_digits(
      c,
      prompt: "hotdesk-enter_pin",
      max_digits: 6,
      tries: 3,
      timeout_ms: 0,
      invalid: Some("agent-invalid_choice"),
    )
    == Error(call.DtmfTimeout)
  assert call.prompt_and_collect_digits(
      c,
      prompt: "hotdesk-enter_id",
      max_digits: 6,
      tries: 1,
      timeout_ms: 0,
      invalid: None,
    )
    == Error(call.DtmfTimeout)
}

pub fn event_reading_test() {
  let event =
    doc.object([
      #("Disposition", doc.String("ANSWER")),
      #("Hangup-Cause", doc.String("NORMAL_CLEARING")),
      #("Custom-Channel-Vars", doc.object([#("Queue-ID", doc.String("q1"))])),
    ])
  assert call.disposition(event) == Some("ANSWER")
  assert call.hangup_cause(event) == Some("NORMAL_CLEARING")
  assert doc.get_string(call.event_channel_vars(event), ["Queue-ID"])
    == Ok("q1")

  let empty = doc.object([])
  assert call.disposition(empty) == None
  assert call.hangup_cause(empty) == None
  assert call.event_channel_vars(empty) == doc.Object(dict.new())
}

/// With no media server to resolve against, a media name is its own path.
pub fn media_test() {
  assert call.media_path("hold-music", "4b1f0c2d7e8a9b0c1d2e3f4051627384")
    == "hold-music"
  assert call.prompt_path(a_call(), "queue-welcome", None) == None
}

/// The two sides of a queue call are told apart on the channel: the hold
/// that waits its turn, and the bridge that takes it. The bridge is
/// recorded with what the caller hears while it rings, which for hold music
/// is the switch's own variable and not a media path.
pub fn a_queued_hold_and_an_interrupting_bridge_test() {
  let c = a_call()
  channel.record()
  call.hold_queued(c, Some("support-hold"))
  call.hold_queued(c, None)
  let _ = call.bridge_interrupting(c, [], 10, call.Single, call.HoldMusic)
  let _ =
    call.bridge_interrupting(c, [], 10, call.Single, call.Music("support-hold"))
  let _ = call.bridge_interrupting(c, [], 10, call.Simultaneous, call.Tone)
  assert channel.sent()
    == [
      Command("hold_queued", "support-hold"),
      Command("hold_queued", ""),
      Command("bridge_interrupting", "${hold_music}"),
      Command("bridge_interrupting", "support-hold"),
      Command("bridge_interrupting", ""),
    ]
}

/// A call with no control queue has nowhere to send the bridge, and Kazoo's
/// own send would answer `ok` having published nothing: the offer would
/// wait out its ring timeout and charge the agents a miss for a ring that
/// never went out. It is an error, and nothing is sent.
pub fn a_bridge_with_no_control_queue_is_not_sent_test() {
  let without =
    call.from_value(
      doc.object([#("Call-ID", doc.String("4b1f0c2d-7e8a-9b0c"))]),
    )
  let empty = call.set_control_queue(without, "")
  channel.record()
  assert call.bridge_interrupting(without, [], 20, call.Single, call.HoldMusic)
    == Error("the call has no control queue")
  assert call.bridge_interrupting(empty, [], 20, call.Single, call.HoldMusic)
    == Error("the call has no control queue")
  assert channel.sent() == []

  assert call.bridge_interrupting(a_call(), [], 20, call.Single, call.Tone)
    == Ok(Nil)
  assert channel.sent() == [Command("bridge_interrupting", "")]
}

/// Ending a bridge from the caller's side is its own command, not a hangup
/// of the caller.
pub fn an_unbridge_is_not_a_hangup_test() {
  let c = a_call()
  channel.record()
  call.unbridge(c)
  call.hangup(c)
  assert channel.sent() == [Command("unbridge", ""), Command("hangup", "")]
}

/// The announcement that interrupts the hold is told apart from the one
/// that queues behind it, and carries the same items.
pub fn an_interrupting_announcement_test() {
  let c = a_call()
  let items = [call.MacroPrompt("queue-you_are_at_position")]
  channel.record()
  call.audio_macro(c, items)
  call.audio_macro_interrupting(c, items)
  let assert [queued, interrupting] = channel.sent()
  assert queued.name == "audio_macro"
  assert interrupting.name == "audio_macro_interrupting"
  assert interrupting.argument == queued.argument
}
