//// A queue call's recording: what it is called and what it carries to the
//// `media_mgr` that stores it.

import callcenter/recording
import kazoo/call
import kazoo/doc

const queue_id = "5e1a7c0b3d9f4e2a8b6c1d0e9f8a7b6c"

const caller_leg = "caller-leg-1"

const answered_at = 63_900_000_000

/// An account whose own inbound recordings are on for both networks, with
/// settings that differ between them.
fn account() -> doc.Value {
  doc.object([
    #(
      "call_recording",
      doc.object([
        #(
          "account",
          doc.object([
            #(
              "inbound",
              doc.object([
                #(
                  "offnet",
                  doc.object([
                    #("enabled", doc.Bool(True)),
                    #("record_on_answer", doc.Bool(True)),
                    #("record_on_bridge", doc.Bool(False)),
                    #("should_record_feature_calls", doc.Bool(False)),
                    #("format", doc.String("wav")),
                    #("time_limit", doc.Int(7200)),
                    #("url", doc.String("https://store.example.test/rec")),
                  ]),
                ),
                #("onnet", doc.object([#("format", doc.String("mp3"))])),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

fn settings(account: doc.Value, network: String) -> doc.Value {
  recording.of_call(
    account,
    network,
    queue_id,
    caller_leg,
    "agent-a",
    answered_at,
  ).settings
}

pub fn a_recording_is_named_for_the_queue_the_call_and_the_answer_test() {
  let recorded =
    recording.of_call(
      doc.object([]),
      "offnet",
      queue_id,
      caller_leg,
      "agent-a",
      answered_at,
    )
  assert recorded.name
    == "queue-" <> queue_id <> "-" <> caller_leg <> "-63900000000"
}

/// Two answers of the same caller are two files: a second recording under
/// the first one's name would be appended to it.
pub fn a_caller_answered_twice_is_two_recordings_test() {
  assert recording.name(queue_id, caller_leg, answered_at)
    != recording.name(queue_id, caller_leg, answered_at + 300)
}

/// What finds the recording again is on the document it becomes.
pub fn a_recording_says_whose_it_is_test() {
  let carried = settings(doc.object([]), "offnet")
  assert doc.get_string(carried, ["origin"])
    == Ok("callcenter : queue " <> queue_id)
  assert doc.get_string(carried, ["recording_vars", "queue_id"]) == Ok(queue_id)
  assert doc.get_string(carried, ["recording_vars", "call_id"])
    == Ok(caller_leg)
  assert doc.get_string(carried, ["recording_vars", "agent_id"])
    == Ok("agent-a")
  assert doc.get_int(carried, ["recording_vars", "answered_at"])
    == Ok(answered_at)
}

/// An account with no settings of its own leaves the format, the time limit
/// and the storage to the system: nothing else is sent.
pub fn an_account_without_settings_leaves_them_to_the_system_test() {
  let carried = settings(doc.object([]), "offnet")
  assert doc.get(carried, ["format"]) == Error(Nil)
  assert doc.get(carried, ["time_limit"]) == Error(Nil)
  assert doc.get(carried, ["url"]) == Error(Nil)
}

/// The account's own settings for the caller's network say how the file is
/// made and where it goes.
pub fn the_account_says_how_and_where_test() {
  let carried = settings(account(), "offnet")
  assert doc.get_string(carried, ["format"]) == Ok("wav")
  assert doc.get_int(carried, ["time_limit"]) == Ok(7200)
  assert doc.get_string(carried, ["url"])
    == Ok("https://store.example.test/rec")
  assert doc.get_string(settings(account(), "onnet"), ["format"]) == Ok("mp3")
}

/// Whether and when to record is the queue's: the account's switches for its
/// own recording are not carried, or `record_on_answer` would turn the start
/// into an action waiting for an answer that has already happened.
pub fn the_account_does_not_decide_whether_or_when_test() {
  let carried = settings(account(), "offnet")
  assert doc.get(carried, ["enabled"]) == Error(Nil)
  assert doc.get(carried, ["record_on_answer"]) == Error(Nil)
  assert doc.get(carried, ["record_on_bridge"]) == Error(Nil)
  assert doc.get(carried, ["should_record_feature_calls"]) == Error(Nil)
}

pub fn settings_that_are_not_an_object_are_none_test() {
  let broken =
    doc.set(
      doc.object([]),
      ["call_recording", "account", "inbound", "offnet"],
      doc.String("yes"),
    )
  assert recording.account_settings(broken, "offnet") == doc.object([])
}

/// A caller with an inception came in from outside, as `kapps_call` has it.
pub fn the_callers_network_test() {
  let outside =
    call.from_value(
      doc.object([
        #("Call-ID", doc.String(caller_leg)),
        #("Inception", doc.String("+12125550143@carrier.example.test")),
      ]),
    )
  let inside =
    call.from_value(doc.object([#("Call-ID", doc.String(caller_leg))]))
  assert recording.network(outside) == "offnet"
  assert recording.network(inside) == "onnet"
}
