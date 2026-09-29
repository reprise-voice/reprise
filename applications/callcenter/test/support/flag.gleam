//// A value a test changes while the processes it drives read it: whether
//// the node has stood still, say, which a fence asks from a process of its
//// own.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub opaque type Flag(value) {
  Flag(subject: Subject(Message(value)))
}

type Message(value) {
  Set(value: value, done: Subject(Nil))
  Get(done: Subject(value))
}

/// A flag holding `value`, linked to the test's process.
pub fn new(value: value) -> Flag(value) {
  let assert Ok(started) =
    actor.new(value)
    |> actor.on_message(fn(held, message) {
      case message {
        Set(value, done) -> {
          process.send(done, Nil)
          actor.continue(value)
        }
        Get(done) -> {
          process.send(done, held)
          actor.continue(held)
        }
      }
    })
    |> actor.start
  Flag(subject: started.data)
}

/// Hold `value` from now on: whoever reads the flag after this returns
/// reads it.
pub fn set(flag: Flag(value), value: value) -> Nil {
  process.call(flag.subject, 1000, Set(value, _))
}

pub fn get(flag: Flag(value)) -> value {
  process.call(flag.subject, 1000, Get)
}
