//// An offer process that rings nobody.
////
//// `callcenter/offer` builds endpoints and bridges, which needs a switch, a
//// channel and a caller. This is the same contract with none of that: it
//// records the requests it was given and answers whatever the test tells it
//// to, on the subject the request carries. Everything the dispatcher does
//// with a reply -- acking the member, counting the miss, starting the
//// wrap-up, publishing the events -- runs against it exactly as it does
//// against the real one.
////
//// It is also the shape of the seam: the dispatcher is started with a
//// function of `OfferRequest`, so nothing in the tree depends on the module
//// that dials.

import callcenter/types.{type OfferReply, type OfferRequest}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/actor

pub opaque type Fake {
  Fake(subject: Subject(Message))
}

pub opaque type Message {
  Offered(request: OfferRequest, done: Subject(Result(Pid, String)))
  Requests(done: Subject(List(OfferRequest)))
  Fail(reason: String, done: Subject(Nil))
  Succeed(done: Subject(Nil))
  Clear(done: Subject(Nil))
  Died(done: Subject(Nil))
  CallOf(pid: Pid, done: Subject(Result(String, Nil)))
}

type State {
  State(
    requests: List(OfferRequest),
    failure: Result(Nil, String),
    /// One process per offer, newest first. A real offer is a process and
    /// the dispatcher watches whether it is still there, so a fake that
    /// hands back a process which never ends is a fake whose offers are
    /// never over.
    processes: List(Pid),
    /// Every process started, with the call it rings for.
    owners: List(#(Pid, String)),
  )
}

/// A fake that accepts every offer.
pub fn new() -> Fake {
  let assert Ok(started) =
    actor.new(State(requests: [], failure: Ok(Nil), processes: [], owners: []))
    |> actor.on_message(handle)
    |> actor.start
  Fake(subject: started.data)
}

/// The function to start the dispatcher with.
pub fn start_offer(fake: Fake) -> fn(OfferRequest) -> Result(Pid, String) {
  fn(request) { process.call(fake.subject, 5000, Offered(request, _)) }
}

/// Every offer asked for, oldest first.
pub fn requests(fake: Fake) -> List(OfferRequest) {
  process.call(fake.subject, 5000, Requests)
}

/// The most recent offer's process has ended without replying: the switch
/// took it with it, or it crashed. Until a test says so an offer is still
/// running, which is what the dispatcher's ceiling looks at.
pub fn died(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, Died)
  // The kill is a signal, and `is_alive` is only false once it has landed.
  process.sleep(20)
}

/// The call an offer's process was started for.
pub fn call_of(fake: Fake, pid: Pid) -> Result(String, Nil) {
  process.call(fake.subject, 5000, CallOf(pid, _))
}

/// The most recent offer, or nothing.
pub fn last(fake: Fake) -> Result(OfferRequest, Nil) {
  requests(fake) |> list.last
}

/// The agents the most recent offer was asked to ring.
pub fn ringing(fake: Fake) -> List(String) {
  case last(fake) {
    Ok(request) -> request.agents
    Error(_) -> []
  }
}

/// How many offers have been asked for.
pub fn count(fake: Fake) -> Int {
  requests(fake) |> list.length
}

/// From now on, refuse every offer: what a node with no channel to the
/// switch does.
pub fn failing(fake: Fake, reason: String) -> Nil {
  process.call(fake.subject, 5000, Fail(reason, _))
}

/// Accept them again.
pub fn working(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, Succeed)
}

/// Forget the offers so far.
pub fn clear(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, Clear)
}

/// Answer one offer, as the offer process would.
pub fn reply(request: OfferRequest, reply: OfferReply) -> Nil {
  process.send(request.reply_to, #(request.id, reply))
}

/// Answer the most recent offer.
pub fn reply_last(fake: Fake, reply: OfferReply) -> Nil {
  case last(fake) {
    Ok(request) -> reply_it(request, reply)
    Error(_) -> Nil
  }
}

fn reply_it(request: OfferRequest, answer: OfferReply) -> Nil {
  reply(request, answer)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Offered(request, done) -> {
      case state.failure {
        Error(reason) -> {
          process.send(done, Error(reason))
          actor.continue(state)
        }
        Ok(Nil) -> {
          // A real offer is a process, and one that is still alive has not
          // finished: `died` is how a test says it has.
          let pid = process.spawn_unlinked(fn() { process.sleep_forever() })
          process.send(done, Ok(pid))
          actor.continue(
            State(
              ..state,
              requests: list.append(state.requests, [request]),
              processes: [pid, ..state.processes],
              owners: [#(pid, request.member.call_id), ..state.owners],
            ),
          )
        }
      }
    }
    Requests(done) -> {
      process.send(done, state.requests)
      actor.continue(state)
    }
    Fail(reason, done) -> {
      process.send(done, Nil)
      actor.continue(State(..state, failure: Error(reason)))
    }
    Succeed(done) -> {
      process.send(done, Nil)
      actor.continue(State(..state, failure: Ok(Nil)))
    }
    Clear(done) -> {
      process.send(done, Nil)
      actor.continue(State(..state, requests: []))
    }
    CallOf(pid, done) -> {
      process.send(done, list.key_find(state.owners, pid))
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
