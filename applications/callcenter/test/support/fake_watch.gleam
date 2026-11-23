//// A takeover watcher that watches nothing.
////
//// `callcenter/takeover` subscribes to an account's call events and reads a
//// caller's channel off a switch, which needs both. This is the same
//// contract with neither: it records what it was asked to watch and answers
//// whatever the test tells it to, on the subject the request carries.
//// Everything the dispatcher does with a reply -- settling the member,
//// counting the miss, closing the record, publishing the events -- runs
//// against it exactly as it does against the real one.

import callcenter/takeover.{type Request}
import callcenter/types.{type OfferReply}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/actor

pub opaque type Fake {
  Fake(subject: Subject(Message))
}

pub opaque type Message {
  Watched(request: Request, done: Subject(Result(Pid, String)))
  Requests(done: Subject(List(Request)))
  Fail(reason: String, once: Bool, done: Subject(Nil))
  Died(done: Subject(Nil))
  Attempts(done: Subject(Int))
}

type State {
  State(
    requests: List(Request),
    failure: Result(Nil, String),
    /// Whether the failure is for the next watch only.
    once: Bool,
    /// Every watch asked for, refused ones included.
    attempts: Int,
    /// One process per watch, newest first. A real watcher is a process and
    /// the dispatcher's ceiling looks at whether it is still there.
    processes: List(Pid),
  )
}

pub fn new() -> Fake {
  let assert Ok(started) =
    actor.new(
      State(
        requests: [],
        failure: Ok(Nil),
        once: False,
        attempts: 0,
        processes: [],
      ),
    )
    |> actor.on_message(handle)
    |> actor.start
  Fake(subject: started.data)
}

/// The function to start the dispatcher with.
pub fn start_watch(fake: Fake) -> fn(Request) -> Result(Pid, String) {
  fn(request) { process.call(fake.subject, 5000, Watched(request, _)) }
}

/// Every watch asked for, oldest first.
pub fn requests(fake: Fake) -> List(Request) {
  process.call(fake.subject, 5000, Requests)
}

pub fn count(fake: Fake) -> Int {
  requests(fake) |> list.length
}

pub fn last(fake: Fake) -> Result(Request, Nil) {
  requests(fake) |> list.last
}

/// The agents the most recent watch was asked about.
pub fn watching(fake: Fake) -> List(String) {
  case last(fake) {
    Ok(request) -> request.agents
    Error(_) -> []
  }
}

/// From now on, refuse every watch.
pub fn failing(fake: Fake, reason: String) -> Nil {
  process.call(fake.subject, 5000, Fail(reason, False, _))
}

/// Refuse the next watch, and accept the ones after it.
pub fn failing_once(fake: Fake, reason: String) -> Nil {
  process.call(fake.subject, 5000, Fail(reason, True, _))
}

/// How many watches were asked for, refused ones included.
pub fn attempts(fake: Fake) -> Int {
  process.call(fake.subject, 5000, Attempts)
}

/// The most recent watcher's process has ended without replying.
pub fn died(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, Died)
  // The kill is a signal, and `is_alive` is only false once it has landed.
  process.sleep(20)
}

/// Answer one watch, as the watcher would.
pub fn reply(request: Request, reply: OfferReply) -> Nil {
  process.send(request.reply_to, #(request.id, reply))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Watched(request, done) -> {
      let state = State(..state, attempts: state.attempts + 1)
      case state.failure {
        Error(reason) -> {
          process.send(done, Error(reason))
          actor.continue(case state.once {
            True -> State(..state, failure: Ok(Nil), once: False)
            False -> state
          })
        }
        Ok(Nil) -> {
          let pid = process.spawn_unlinked(fn() { process.sleep_forever() })
          process.send(done, Ok(pid))
          actor.continue(
            State(
              ..state,
              requests: list.append(state.requests, [request]),
              processes: [pid, ..state.processes],
            ),
          )
        }
      }
    }
    Requests(done) -> {
      process.send(done, state.requests)
      actor.continue(state)
    }
    Fail(reason, once, done) -> {
      process.send(done, Nil)
      actor.continue(State(..state, failure: Error(reason), once: once))
    }
    Attempts(done) -> {
      process.send(done, state.attempts)
      actor.continue(state)
    }
    Died(done) -> {
      case state.processes {
        [pid, ..rest] -> {
          process.kill(pid)
          process.send(done, Nil)
          actor.continue(State(..state, processes: rest))
        }
        [] -> {
          process.send(done, Nil)
          actor.continue(state)
        }
      }
    }
  }
}
