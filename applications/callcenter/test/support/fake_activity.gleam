//// The activity actor as a dispatcher reads it, with nothing behind it.
////
//// `callcenter/activity` derives what the agents' phones are doing from a
//// node's channel events and asks the switches for the rest, and neither is
//// there in a test. The dispatcher reads it through one function it was
//// started with, which is this fake's: it answers whatever the test last
//// told it to, which is every agent idle until it says otherwise, and counts
//// how many times it was asked.

import callcenter/activity.{type Reading, Reading}
import callcenter/types.{type Activity}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub opaque type Fake {
  Fake(subject: Subject(Message))
}

type Answer =
  Result(Reading, String)

pub opaque type Message {
  Set(reading: Answer, done: Subject(Nil))
  Get(done: Subject(Answer))
  Reads(done: Subject(Int))
}

type State {
  State(reading: Answer, reads: Int)
}

/// Every agent idle, and the switches have answered.
pub fn new() -> Fake {
  let assert Ok(started) =
    actor.new(State(reading: Ok(synced(dict.new())), reads: 0))
    |> actor.on_message(fn(state: State, message) {
      case message {
        Set(reading, done) -> {
          process.send(done, Nil)
          actor.continue(State(..state, reading: reading))
        }
        Get(done) -> {
          process.send(done, state.reading)
          actor.continue(State(..state, reads: state.reads + 1))
        }
        Reads(done) -> {
          process.send(done, state.reads)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Fake(subject: started.data)
}

/// The function the dispatcher is started with.
pub fn reader(fake: Fake) -> fn() -> Answer {
  fn() { process.call(fake.subject, 5000, Get) }
}

/// From now on these agents are doing this, and everybody else is idle.
pub fn agents(fake: Fake, activities: List(#(String, Activity))) -> Nil {
  process.call(fake.subject, 5000, Set(
    Ok(synced(dict.from_list(activities))),
    _,
  ))
}

/// From now on the switches have not answered yet: these agents are doing
/// this as far as the channel events since the account was watched say.
pub fn unsynced(fake: Fake, activities: List(#(String, Activity))) -> Nil {
  process.call(fake.subject, 5000, Set(
    Ok(Reading(
      synced: False,
      watched: True,
      activities: dict.from_list(activities),
    )),
    _,
  ))
}

/// From now on the node's activity actor has restarted and watches nothing:
/// nobody on a call, as far as it knows, and not the account at all.
pub fn restarted(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, Set(
    Ok(Reading(synced: False, watched: False, activities: dict.new())),
    _,
  ))
}

fn synced(activities: Dict(String, Activity)) -> Reading {
  Reading(synced: True, watched: True, activities: activities)
}

/// From now on the actor does not answer.
pub fn silent(fake: Fake, reason: String) -> Nil {
  process.call(fake.subject, 5000, Set(Error(reason), _))
}

/// How many times the dispatcher has read it.
pub fn reads(fake: Fake) -> Int {
  process.call(fake.subject, 5000, Reads)
}
