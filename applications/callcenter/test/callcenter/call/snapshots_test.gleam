//// The account's channels asked of the switches once for many callers: a
//// question in flight is shared, and an answer is handed out again while
//// it is fresh.

import callcenter/call/snapshots
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import kazoo/events

type Clock {
  Now(done: Subject(Int))
  Set(ms: Int)
}

fn clock() -> Subject(Clock) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(now, message) {
      case message {
        Now(done) -> {
          process.send(done, now)
          actor.continue(now)
        }
        Set(ms) -> actor.continue(ms)
      }
    })
    |> actor.start
  started.data
}

/// Snapshots whose every question is recorded, and answered after `slow_ms`.
fn snapshots(
  asked: Subject(String),
  at: Subject(Clock),
  slow_ms: Int,
) -> Subject(snapshots.Message) {
  let assert Ok(started) =
    snapshots.start(
      None,
      fn(account_id) {
        process.send(asked, account_id)
        process.sleep(slow_ms)
        Some(events.Channels(channels: [], complete: True))
      },
      fn() { process.call(at, 1000, Now) },
    )
  started.data
}

fn questions(asked: Subject(String)) -> List(String) {
  drain(asked, [])
}

fn drain(asked: Subject(String), acc: List(String)) -> List(String) {
  case process.receive(asked, 0) {
    Ok(account_id) -> drain(asked, [account_id, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// Everybody who asks while a question is in flight gets its answer, and
/// only one question goes to the switches.
pub fn a_question_in_flight_is_shared_test() {
  let asked = process.new_subject()
  let at = clock()
  let to = snapshots(asked, at, 100)
  let answers = process.new_subject()
  list.each([1, 2, 3], fn(_) {
    process.spawn(fn() {
      process.send(answers, snapshots.channels_of(to, "account-one"))
    })
  })
  let got =
    list.map([1, 2, 3], fn(_) {
      let assert Ok(answer) = process.receive(answers, 2000)
      answer
    })
  assert list.all(got, fn(answer) { answer != None })
  assert questions(asked) == ["account-one"]
}

/// An answer is handed out again for `fresh_ms` after it was asked for,
/// and asked again after that. Another account is its own question.
pub fn an_answer_is_reused_while_fresh_test() {
  let asked = process.new_subject()
  let at = clock()
  let to = snapshots(asked, at, 0)
  let _ = snapshots.channels_of(to, "account-one")
  process.send(at, Set(snapshots.fresh_ms - 1))
  let _ = snapshots.channels_of(to, "account-one")
  assert questions(asked) == ["account-one"]

  process.send(at, Set(snapshots.fresh_ms))
  let _ = snapshots.channels_of(to, "account-one")
  let _ = snapshots.channels_of(to, "account-two")
  assert questions(asked) == ["account-one", "account-two"]
}
