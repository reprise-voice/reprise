//// The recorded channel: what an action sent, in the order it sent it, and
//// what the caller typed back.

import gleam/erlang/process
import gleam/option.{Some}
import kazoo/call
import kazoo/callflow
import kazoo/doc
import kazoo/testing/channel.{Command}

fn a_call() -> call.Call {
  call.from_value(
    doc.object([
      #("Call-ID", doc.String("4b1f0c2d-7e8a-9b0c")),
      #("Account-ID", doc.String("4b1f0c2d7e8a9b0c1d2e3f4051627384")),
    ]),
  )
}

/// The recorder is one process's own, and off until that process asks: a
/// process that never called `record` keeps nothing, and cannot see the
/// channel of one that did.
pub fn the_recorder_is_per_process_test() {
  let c = a_call()
  channel.record()
  call.answer(c)

  let elsewhere = process.new_subject()
  process.spawn(fn() {
    call.prompt(c, "queue-welcome")
    process.send(elsewhere, channel.sent())
  })

  assert process.receive(elsewhere, 1000) == Ok([])
  assert channel.sent() == [Command("answer", "")]
}

/// Recording again is the whole reset: what was recorded is forgotten, and
/// so is an answer scripted for a collection that never happened.
pub fn recording_again_forgets_the_script_test() {
  let c = a_call()
  channel.record()
  channel.collect_answers([channel.Typed("1001")])
  channel.play_results([channel.Heard])

  channel.record()
  assert collect(c, "hotdesk-enter_id") == Error(call.DtmfTimeout)
  assert call.prompt_and_wait(c, "agent-logged_in") == Error(call.PlayFailed)
  assert channel.sent()
    == [
      Command("prompt_and_collect_digits", "hotdesk-enter_id"),
      Command("prompt_and_wait", "agent-logged_in"),
    ]
}

/// A prompt the action waits for answers what the test scripted, in order,
/// and the one past the end of the script is the not-played a prompt with no
/// channel has always been.
pub fn the_prompts_answer_the_script_test() {
  let c = a_call()
  channel.record()
  channel.play_results([
    channel.Heard,
    channel.GoneBeforeTheEnd,
    channel.NotPlayed,
  ])

  assert call.prompt_and_wait(c, "agent-logged_in") == Ok(Nil)
  assert call.prompt_and_wait(c, "agent-logged_out") == Error(call.PlayHungup)
  assert call.prompt_and_wait(c, "agent-on_break") == Error(call.PlayFailed)
  assert call.prompt_and_wait(c, "agent-invalid_choice")
    == Error(call.PlayFailed)
}

/// Commands and endings land in one list, in order.
pub fn commands_are_recorded_in_order_test() {
  let c = a_call()
  channel.record()
  call.answer(c)
  call.play(c, "greeting")
  let _ = call.prompt_and_wait(c, "agent-logged_in")
  callflow.stop(c)

  assert channel.sent()
    == [
      Command("answer", ""),
      Command("play", "greeting"),
      Command("prompt_and_wait", "agent-logged_in"),
      Command("stop", ""),
    ]
}

/// Which commands the action waited for the end of, and which ended the
/// flow. A prompt that was not waited for is the whole of the defect these
/// answer: the ending behind it hangs the channel up.
pub fn blocking_and_endings_test() {
  assert channel.waits_for_the_channel(Command("prompt_and_wait", "x"))
  assert channel.waits_for_the_channel(Command("prompt_and_collect_digits", "x"))
  assert channel.waits_for_the_channel(Command("collect_digits", ""))
  assert !channel.waits_for_the_channel(Command("prompt", "x"))
  assert !channel.waits_for_the_channel(Command("play", "x"))

  assert channel.is_an_ending(Command("stop", ""))
  assert channel.is_an_ending(Command("continue", ""))
  assert channel.is_an_ending(Command("transfer", ""))
  assert !channel.is_an_ending(Command("answer", ""))
}

/// The caller answers what the test scripted, in order, and the collection
/// past the end of the script gets the nothing it gets today.
pub fn the_caller_answers_the_script_test() {
  let c = a_call()
  channel.record()
  channel.collect_answers([
    channel.Typed("1001"),
    channel.Typed("4321"),
    channel.CallerHungUp,
  ])

  assert collect(c, "hotdesk-enter_id") == Ok("1001")
  assert collect(c, "hotdesk-enter_pin") == Ok("4321")
  assert collect(c, "hotdesk-enter_pin") == Error(call.Hungup)
  assert collect(c, "hotdesk-enter_pin") == Error(call.DtmfTimeout)

  assert channel.sent()
    == [
      Command("prompt_and_collect_digits", "hotdesk-enter_id"),
      Command("prompt_and_collect_digits", "hotdesk-enter_pin"),
      Command("prompt_and_collect_digits", "hotdesk-enter_pin"),
      Command("prompt_and_collect_digits", "hotdesk-enter_pin"),
    ]
}

/// A caller who is there and types nothing is not a caller who hung up, and
/// the two reach the action as the two different answers.
pub fn nothing_typed_is_not_a_hangup_test() {
  let c = a_call()
  channel.record()
  channel.collect_answers([channel.NothingTyped])
  assert collect(c, "hotdesk-enter_id") == Error(call.DtmfTimeout)
}

/// A script says nothing about the plain digit collection's prompt, but it
/// answers it too.
pub fn collect_digits_takes_the_script_test() {
  let c = a_call()
  channel.record()
  channel.collect_answers([channel.Typed("7")])
  assert call.collect_digits(c, 1, 0) == Ok("7")
  assert channel.sent() == [Command("collect_digits", "")]
}

fn collect(c: call.Call, prompt: String) -> Result(String, call.DtmfError) {
  call.prompt_and_collect_digits(
    c,
    prompt: prompt,
    max_digits: 6,
    tries: 3,
    timeout_ms: 0,
    invalid: Some("agent-invalid_choice"),
  )
}
