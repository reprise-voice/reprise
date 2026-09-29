//// The callers' actors, as the dispatcher sees them, with no call behind
//// them.
////
//// `callcenter/call/actor` commands a caller's channel and rings their
//// agents, which needs a switch. The dispatcher only ever tells an actor
//// things -- a caller joined, a call to adopt, a ring to call off, a queue
//// gone, a position -- and hears offers' replies back on its own subject.
//// This records what it was told, and answers an adoption as the actor
//// would, on the subject the adoption carried, whenever the test says. A
//// caller joined `resumed` is answered at once with where they stand
//// (`Present`): waiting, unless the test said otherwise (`will_present`).
//// Offers are rung through `test/support/fake_offer`, as they are through
//// the actor's `Ring` on a node.

import callcenter/dispatcher/config
import callcenter/types.{
  type Member, type OfferId, type OfferReply, type Presence,
}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/erlang/reference
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub opaque type Fake {
  Fake(subject: Subject(Message))
}

/// One call adopted: a call a node that died connected, now watched by the
/// caller's actor.
pub type Adoption {
  Adoption(
    member: Member,
    offer: OfferId,
    agent_id: String,
    leg: String,
    answered_at: Int,
    reply_to: Subject(#(OfferId, OfferReply)),
  )
}

/// A caller handed over, and what their actor said of them.
pub type Presented {
  Presented(
    call_id: String,
    offer: OfferId,
    presence: Presence,
    reply_to: Subject(#(OfferId, OfferReply)),
  )
}

/// Everything the dispatcher told the actors, in order.
pub type Told {
  Joined(call_id: String, resumed: Bool)
  Adopted(call_id: String, agent_id: String)
  CalledOff(call_id: String)
  QueueGone(call_id: String)
  Positioned(call_id: String, position: Int, waiting: Int)
}

pub opaque type Message {
  Join(
    told: Told,
    reply_to: Subject(#(OfferId, OfferReply)),
    done: Subject(Pid),
  )
  WillPresent(call_id: String, presence: Option(Presence), done: Subject(Nil))
  Presentations(done: Subject(List(Presented)))
  ActorDied(done: Subject(Nil))
  ActorEnded(done: Subject(Nil))
  Tell(told: Told)
  Adopt(adoption: Adoption, done: Subject(Result(Pid, String)))
  Told(done: Subject(List(Told)))
  Adoptions(done: Subject(List(Adoption)))
  Fail(reason: String, once: Bool, done: Subject(Nil))
  Died(done: Subject(Nil))
}

type State {
  State(
    told: List(Told),
    adoptions: List(Adoption),
    failure: Result(Nil, String),
    /// Whether the failure is for the next adoption only.
    once: Bool,
    /// One process per adoption, newest first: the actor watching it. The
    /// dispatcher's ceiling looks at whether it is still there.
    processes: List(Pid),
    /// The one process standing for every waiting caller's actor, which the
    /// dispatcher watches while they wait, and what ends it as an actor
    /// that is done ends.
    actor: Pid,
    actor_end: Subject(Nil),
    /// Call id to what a resumed join of it is answered with: nothing at
    /// all for `None`.
    presences: Dict(String, Option(Presence)),
    /// Every presence told, oldest first.
    presented: List(Presented),
  )
}

pub fn new() -> Fake {
  let stand_in = ender()
  let assert Ok(started) =
    actor.new(
      State(
        told: [],
        adoptions: [],
        failure: Ok(Nil),
        once: False,
        processes: [],
        actor: stand_in.0,
        actor_end: stand_in.1,
        presences: dict.new(),
        presented: [],
      ),
    )
    |> actor.on_message(handle)
    |> actor.start
  Fake(subject: started.data)
}

/// What to start the dispatcher with.
pub fn calls(fake: Fake) -> config.Calls {
  config.Calls(
    join: fn(member: Member, resumed, reply_to) {
      Ok(
        process.call(fake.subject, 5000, Join(
          Joined(member.call_id, resumed),
          reply_to,
          _,
        )),
      )
    },
    adopt: fn(member, offer, agent_id, leg, answered_at, reply_to) {
      process.call(fake.subject, 5000, Adopt(
        Adoption(member, offer, agent_id, leg, answered_at, reply_to),
        _,
      ))
    },
    call_off: fn(member: Member, _offer) {
      process.send(fake.subject, Tell(CalledOff(member.call_id)))
    },
    queue_gone: fn(member: Member) {
      process.send(fake.subject, Tell(QueueGone(member.call_id)))
    },
    positioned: fn(member: Member, position, waiting, _available: Option(Int)) {
      process.send(
        fake.subject,
        Tell(Positioned(member.call_id, position, waiting)),
      )
    },
  )
}

/// What the actor of `call_id` answers a resumed join with from now on.
pub fn will_present(fake: Fake, call_id: String, presence: Presence) -> Nil {
  process.call(fake.subject, 5000, WillPresent(call_id, Some(presence), _))
}

/// The actor of `call_id` never says where the caller stands.
pub fn will_say_nothing(fake: Fake, call_id: String) -> Nil {
  process.call(fake.subject, 5000, WillPresent(call_id, None, _))
}

/// Every presence the actors told, oldest first.
pub fn presented(fake: Fake) -> List(Presented) {
  process.call(fake.subject, 5000, Presentations)
}

/// Answer the offer a presence was told under, as the actor would.
pub fn reply_presented(presented: Presented, reply: OfferReply) -> Nil {
  process.send(presented.reply_to, #(presented.offer, reply))
}

/// Everything the actors were told, oldest first.
pub fn told(fake: Fake) -> List(Told) {
  process.call(fake.subject, 5000, Told)
}

/// Every caller whose ring was called off, in order.
pub fn called_off(fake: Fake) -> List(String) {
  told(fake)
  |> list.filter_map(fn(told) {
    case told {
      CalledOff(call_id) -> Ok(call_id)
      _ -> Error(Nil)
    }
  })
}

/// Every caller told they joined, in order, and whether they were resumed.
pub fn joined(fake: Fake) -> List(#(String, Bool)) {
  told(fake)
  |> list.filter_map(fn(told) {
    case told {
      Joined(call_id, resumed) -> Ok(#(call_id, resumed))
      _ -> Error(Nil)
    }
  })
}

/// Every caller taken out of a deleted queue, in order.
pub fn queue_gone(fake: Fake) -> List(String) {
  told(fake)
  |> list.filter_map(fn(told) {
    case told {
      QueueGone(call_id) -> Ok(call_id)
      _ -> Error(Nil)
    }
  })
}

/// Every call adopted, oldest first.
pub fn adoptions(fake: Fake) -> List(Adoption) {
  process.call(fake.subject, 5000, Adoptions)
}

/// From now on, refuse every adoption: no actor can be had.
pub fn failing(fake: Fake, reason: String) -> Nil {
  process.call(fake.subject, 5000, Fail(reason, False, _))
}

/// Refuse the next adoption, and accept the ones after it.
pub fn failing_once(fake: Fake, reason: String) -> Nil {
  process.call(fake.subject, 5000, Fail(reason, True, _))
}

/// The most recent adopting actor has ended without replying.
pub fn died(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, Died)
  // The kill is a signal, and `is_alive` is only false once it has landed.
  process.sleep(20)
}

/// The waiting callers' actors end without a word: every caller waiting is
/// joined to a new one.
pub fn actor_died(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, ActorDied)
  process.sleep(20)
}

/// The waiting callers' actors end as an actor that is done ends:
/// normally.
pub fn actor_ended(fake: Fake) -> Nil {
  process.call(fake.subject, 5000, ActorEnded)
  process.sleep(20)
}

/// A process that waits until it is told to end, and then ends normally.
fn ender() -> #(Pid, Subject(Nil)) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      process.send(reply, stop)
      let _ = process.receive_forever(stop)
      Nil
    })
  let assert Ok(stop) = process.receive(reply, 1000)
  #(pid, stop)
}

/// Answer an adoption, as the actor watching it would.
pub fn reply(adoption: Adoption, reply: OfferReply) -> Nil {
  process.send(adoption.reply_to, #(adoption.offer, reply))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Join(told, reply_to, done) -> {
      let state = State(..state, told: list.append(state.told, [told]))
      // The presence goes before the answer to the join, so that it is in
      // the dispatcher's mailbox before the dispatcher goes on.
      let next = case told {
        Joined(call_id, True) ->
          case
            dict.get(state.presences, call_id)
            |> result.unwrap(Some(types.PresentWaiting))
          {
            None -> state
            Some(presence) -> {
              let offer =
                types.OfferId(call_id: call_id, serial: reference.new())
              process.send(reply_to, #(offer, types.Present(presence)))
              State(
                ..state,
                presented: list.append(state.presented, [
                  Presented(call_id, offer, presence, reply_to),
                ]),
              )
            }
          }
        _ -> state
      }
      process.send(done, state.actor)
      actor.continue(next)
    }
    WillPresent(call_id, presence, done) -> {
      process.send(done, Nil)
      actor.continue(
        State(
          ..state,
          presences: dict.insert(state.presences, call_id, presence),
        ),
      )
    }
    Presentations(done) -> {
      process.send(done, state.presented)
      actor.continue(state)
    }
    ActorDied(done) -> {
      process.kill(state.actor)
      process.send(done, Nil)
      let #(pid, end) = ender()
      actor.continue(State(..state, actor: pid, actor_end: end))
    }
    ActorEnded(done) -> {
      process.send(state.actor_end, Nil)
      process.send(done, Nil)
      let #(pid, end) = ender()
      actor.continue(State(..state, actor: pid, actor_end: end))
    }
    Tell(told) ->
      actor.continue(State(..state, told: list.append(state.told, [told])))
    Adopt(adoption, done) ->
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
              told: list.append(state.told, [
                Adopted(adoption.member.call_id, adoption.agent_id),
              ]),
              adoptions: list.append(state.adoptions, [adoption]),
              processes: [pid, ..state.processes],
            ),
          )
        }
      }
    Told(done) -> {
      process.send(done, state.told)
      actor.continue(state)
    }
    Adoptions(done) -> {
      process.send(done, state.adoptions)
      actor.continue(state)
    }
    Fail(reason, once, done) -> {
      process.send(done, Nil)
      actor.continue(State(..state, failure: Error(reason), once: once))
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

/// Actors that are told everything and do nothing with it: for a
/// dispatcher's state built by hand, which never tells them anything a test
/// reads.
pub fn nothing() -> config.Calls {
  config.Calls(
    join: fn(_member, _resumed, _reply_to) { Error("no actors here") },
    adopt: fn(_member, _offer, _agent_id, _leg, _at, _reply_to) {
      Error("no actors here")
    },
    call_off: fn(_member, _offer) { Nil },
    queue_gone: fn(_member) { Nil },
    positioned: fn(_member, _position, _waiting, _available) { Nil },
  )
}
