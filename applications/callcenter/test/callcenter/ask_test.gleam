//// A call that hands back the two ways of getting no answer, instead of
//// crashing the asker.

import callcenter/ask
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

/// What the callee under test is told to do with a question.
type Message {
  /// Answer.
  Answer(done: Subject(Int))
  /// Stop, normally, without answering: what a dispatcher does when its
  /// account goes quiet on the tick before the question reaches it.
  Vanish(done: Subject(Int))
  /// Say nothing and carry on.
  Ignore(done: Subject(Int))
}

fn callee() -> Subject(Message) {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(_state, message) {
      case message {
        Answer(done) -> {
          process.send(done, 42)
          actor.continue(Nil)
        }
        Vanish(_done) -> actor.stop()
        Ignore(_done) -> actor.continue(Nil)
      }
    })
    |> actor.start
  started.data
}

pub fn an_answer_is_an_answer_test() {
  assert ask.call(callee(), 1000, Answer) == Ok(42)
}

/// The race the shard used to lose: the callee is alive when asked and
/// gone before it answers.
pub fn a_callee_that_exits_while_asked_is_a_failure_and_not_a_crash_test() {
  let to = callee()
  let assert Error(ask.Exited(reason)) = ask.call(to, 1000, Vanish)
  assert reason == "Normal"
  let assert Ok(pid) = process.subject_owner(to)
  assert process.is_alive(pid) == False
}

/// A callee that was already gone is the same failure, at once rather than
/// after the timeout.
pub fn a_dead_callee_is_a_failure_test() {
  let to = callee()
  let _ = ask.call(to, 1000, Vanish)
  let assert Error(ask.Exited(_)) = ask.call(to, 5000, Answer)
}

pub fn a_silent_callee_is_a_timeout_test() {
  assert ask.call(callee(), 50, Ignore) == Error(ask.NoReply)
}

/// The failure of a callee that was named and never started.
pub fn a_name_nobody_registered_is_a_failure_test() {
  let subject: Subject(Message) =
    process.named_subject(process.new_name("callcenter_ask_test_nobody"))
  let assert Error(ask.Exited(_)) = ask.call(subject, 1000, Answer)
}

/// Several asked at once share one wait: two silent callees and a dead one
/// among them cost the timeout once, not once each, and the others answer.
pub fn asking_several_waits_once_for_all_of_them_test() {
  let gone = callee()
  let _ = ask.call(gone, 1000, Vanish)
  let silent = mute()
  let started = monotonic_ms()
  let assert [
    Ok(42),
    Error(ask.NoReply),
    Error(ask.Exited(_)),
    Error(ask.NoReply),
    Ok(42),
  ] = ask.call_all([callee(), silent, gone, silent, callee()], 200, Answer)
  assert monotonic_ms() - started < 350
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// A callee that never answers anything.
fn mute() -> Subject(Message) {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(_state, _message) { actor.continue(Nil) })
    |> actor.start
  started.data
}
