//// What an action did to a channel, without a channel.
////
//// A command in `kazoo/call` is a no-op without a Kazoo release, and a
//// callflow ending in `kazoo/callflow` is a no-op without `cf_exe`, which is
//// what makes a callflow action runnable under `gleam test` -- and what
//// makes it say nothing about the order it did things in. This turns those
//// no-ops into a record: while a process is recording, every command and
//// every ending is kept in the order it was sent, and a digit collection
//// answers what the test scripted for it.
////
//// It is the second half of `kazoo/testing/fake`. The fake is the datastore
//// an action reads and writes; this is the caller it talks to.
////
//// ```gleam
//// channel.record()
//// channel.collect_answers([channel.Typed("1001"), channel.CallerHungUp])
//// cf_something.run(fake.kazoo(f), data, call)
//// assert channel.sent() == [...]
//// ```
////
//// All of it is per-process, so one test cannot see another's channel, and
//// nothing is recording until `record` is called -- on a node, nothing ever
//// is. `record` is also the whole reset: it forgets what was recorded and
//// any answer still scripted, so a script cannot outlive the test that
//// wrote it. Call it first in every test that reads the channel.
////
//// This lives in `src` rather than in `test` because Gleam has no test-only
//// exports and every application's suite wants it. No production code should
//// import it.

import gleam/list

/// One thing the action sent, in the spelling `kazoo/call` and
/// `kazoo/callflow` send it under: `answer`, `play`, `prompt`,
/// `prompt_and_wait`, `prompt_and_collect_digits`, `hangup`, `stop`,
/// `continue` and the rest. `argument` is the one that identifies it -- the
/// media, the prompt -- and is empty for a command that has none.
pub type Command {
  Command(name: String, argument: String)
}

/// What a caller does when they are asked for digits.
pub type Collected {
  /// They typed this and it was taken.
  Typed(digits: String)
  /// They hung up in the middle of the exchange.
  CallerHungUp
  /// They were there and typed nothing until it timed out.
  NothingTyped
}

/// What becomes of a prompt the action waits for.
pub type Played {
  /// The caller heard it to the end.
  Heard
  /// The channel went away before it finished.
  GoneBeforeTheEnd
  /// The switch never played it: no channel, an execution error, or a wait
  /// that ran out.
  NotPlayed
}

/// Start recording this process's channel, forgetting anything recorded
/// before and any answers still scripted.
@external(erlang, "kazoo_gleam_call_ffi", "record")
pub fn record() -> Nil

/// What has been sent since, oldest first.
pub fn sent() -> List(Command) {
  list.map(ffi_sent(), fn(pair) { Command(name: pair.0, argument: pair.1) })
}

/// Answer this process's next digit collections with these, in order. A
/// collection past the end of the list gets nothing typed.
pub fn collect_answers(answers: List(Collected)) -> Nil {
  ffi_collect_answers(list.map(answers, collected))
}

fn collected(answer: Collected) -> Result(String, String) {
  case answer {
    Typed(digits) -> Ok(digits)
    CallerHungUp -> Error("hungup")
    NothingTyped -> Error("timeout")
  }
}

/// Answer this process's next waited-for prompts with these, in order. One
/// past the end of the list is not played, which is what a prompt with no
/// channel answers anyway.
pub fn play_results(results: List(Played)) -> Nil {
  ffi_play_results(list.map(results, play_result))
}

fn play_result(result: Played) -> Result(String, String) {
  case result {
    Heard -> Ok("")
    GoneBeforeTheEnd -> Error("hungup")
    NotPlayed -> Error("unavailable")
  }
}

/// Whether the action waited for the switch to finish this one before it did
/// anything else.
///
/// This is the question a test asks about the last thing an action says: a
/// prompt the action did not wait for is a prompt the caller does not hear,
/// because the ending behind it hangs the channel up.
pub fn waits_for_the_channel(command: Command) -> Bool {
  case command.name {
    "prompt_and_wait" -> True
    "prompt_and_collect_digits" -> True
    "collect_digits" -> True
    _ -> False
  }
}

/// Whether this one ends the callflow, which is every `kazoo/callflow`
/// ending.
pub fn is_an_ending(command: Command) -> Bool {
  case command.name {
    "continue" -> True
    "continue_branch" -> True
    "continue_with_flow" -> True
    "branch" -> True
    "stop" -> True
    "stop_with_cause" -> True
    "transfer" -> True
    "control_usurped" -> True
    _ -> False
  }
}

@external(erlang, "kazoo_gleam_call_ffi", "sent")
fn ffi_sent() -> List(#(String, String))

@external(erlang, "kazoo_gleam_call_ffi", "collect_answers")
fn ffi_collect_answers(answers: List(Result(String, String))) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "play_results")
fn ffi_play_results(results: List(Result(String, String))) -> Nil
