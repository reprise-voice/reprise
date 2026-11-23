//// A call that survives its callee.
////
//// `process.call` panics when the process it asked exits before answering,
//// and a panic in an actor's message handler is that actor's crash. That is
//// the right thing between a caller and a callee that are meant to live and
//// die together, and the wrong thing between a shard and its dispatchers: a
//// dispatcher stops itself the moment its account goes quiet, and the shard
//// finds out by asking it something. It has happened: a cancel reached a
//// shard a few milliseconds after the account's only dispatcher
//// had ticked, found nothing waiting and stopped, and the shard actor died
//// of the answer it did not get.
////
//// This is the same monitor-send-select as `process.call`, with the two ways
//// of not getting an answer handed back as values.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string

/// Why there was no answer.
pub type Failure {
  /// The callee exited before it answered, or was already gone.
  Exited(reason: String)
  /// The callee is still there and did not answer in time.
  NoReply
}

/// Send a request and wait for the reply, for at most `timeout` ms.
pub fn call(
  subject: Subject(message),
  timeout: Int,
  make_request: fn(Subject(reply)) -> message,
) -> Result(reply, Failure) {
  send(subject, make_request) |> wait(timeout)
}

/// Ask several callees the same question at once, and wait for them
/// together: every request goes out before any answer is waited for, and
/// the whole wait is at most `timeout` ms however many are asked. What a
/// process that must not stall behind one slow callee after another uses.
/// The answers are in the order the callees were given.
pub fn call_all(
  subjects: List(Subject(message)),
  timeout: Int,
  make_request: fn(Subject(reply)) -> message,
) -> List(Result(reply, Failure)) {
  let deadline = monotonic_ms() + timeout
  subjects
  |> list.map(send(_, make_request))
  |> list.map(fn(asked) { wait(asked, int.max(0, deadline - monotonic_ms())) })
}

/// A request sent, or the callee known to be gone before it could be.
type Asked(reply) {
  Asked(reply: Subject(reply), monitor: process.Monitor)
  Gone
}

fn send(
  subject: Subject(message),
  make_request: fn(Subject(reply)) -> message,
) -> Asked(reply) {
  case process.subject_owner(subject) {
    Error(Nil) -> Gone
    Ok(callee) -> {
      let reply = process.new_subject()
      // Monitored before the request goes out, so that an exit at any point
      // after it is a message and not a wait for the timeout. A callee that
      // is already gone answers the monitor at once with `noproc`.
      let monitor = process.monitor(callee)
      process.send(subject, make_request(reply))
      Asked(reply, monitor)
    }
  }
}

fn wait(asked: Asked(reply), timeout: Int) -> Result(reply, Failure) {
  case asked {
    Gone -> Error(Exited("no process"))
    Asked(reply, monitor) -> {
      let outcome =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(down) {
          Error(Exited(string.inspect(down.reason)))
        })
        |> process.selector_receive(timeout)
      process.demonitor_process(monitor)
      case outcome {
        Ok(answered) -> answered
        Error(Nil) -> Error(NoReply)
      }
    }
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// The failure as a line in the log.
pub fn describe(failure: Failure) -> String {
  case failure {
    Exited(reason) -> "it exited: " <> reason
    NoReply -> "it did not answer in time"
  }
}
