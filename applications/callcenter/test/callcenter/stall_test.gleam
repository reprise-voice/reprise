//// The node's stall watch: what a stall is, which processes it fences, and
//// the watch noting the time and telling the node of a stall.

import callcenter/stall
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

/// A gap of more than `stall_ms` between two notes is a stall, and one of
/// `stall_ms` exactly is not.
pub fn a_stall_is_a_gap_longer_than_the_bound_test() {
  let cases = [
    #("the next tick", 1000, False),
    #("a node busy for two ticks", 2000, False),
    #("the bound itself", stall.stall_ms, False),
    #("just past the bound", stall.stall_ms + 1, True),
    #("a freeze the broker dropped", 16_000, True),
  ]
  list.each(cases, fn(case_) {
    let #(name, gap, stood_still) = case_
    assert stall.stood_still(1_000_000, 1_000_000 + gap) == stood_still as name
  })
}

/// A process is fenced when it started before the last stall, or while the
/// watch has not noted the time for longer than a stall: the node is moving
/// again and the watch has not yet run.
pub fn what_a_stall_fences_test() {
  let stalled = 50_000
  let last = 60_000
  let cases = [
    #("started after the last stall", 55_000, last + 500, True),
    #("started before it", 45_000, last + 500, False),
    #("started as the stall was noted", stalled, last + 500, False),
    #("started just after it", stalled + 1, last + 500, True),
    #("the watch quiet for the bound", 55_000, last + stall.stall_ms, True),
    #("the watch quiet past it", 55_000, last + stall.stall_ms + 1, False),
  ]
  list.each(cases, fn(case_) {
    let #(name, since, now, fresh) = case_
    assert stall.fresh_at(since, now, last, stalled) == fresh as name
  })
}

/// With no watch running -- the test suite, a node with no broker -- nothing
/// is ever fenced.
pub fn no_watch_fences_nothing_test() {
  assert stall.fresh(stall.now_ms() - 1_000_000)
}

type Clock {
  Set(Int)
  Get(Subject(Int))
}

type Heard {
  Noted(at: Int, stalled: Bool)
  StoodStill(gap: Int)
}

/// The watch notes the time on every tick; a gap longer than the bound is
/// noted as a stall and told to the node, with how long it was.
pub fn the_watch_notes_the_time_and_tells_of_a_stall_test() {
  let assert Ok(clock) =
    actor.new(0)
    |> actor.on_message(fn(now, message) {
      case message {
        Set(to) -> actor.continue(to)
        Get(done) -> {
          process.send(done, now)
          actor.continue(now)
        }
      }
    })
    |> actor.start
  let clock = clock.data
  let set = fn(at) { process.send(clock, Set(at)) }
  let heard = process.new_subject()
  set(10_000)
  let assert Ok(watch) =
    stall.start(stall.Io(
      now_ms: fn() { process.call(clock, 1000, Get) },
      note: fn(at, stalled) { process.send(heard, Noted(at, stalled)) },
      stood_still: fn(gap) { process.send(heard, StoodStill(gap)) },
      // The test ticks it by hand.
      tick_ms: 3_600_000,
    ))
  let hear = fn() {
    let assert Ok(one) = process.receive(heard, 1000)
    one
  }
  // Each tick is heard before the clock moves again: the watch reads the
  // clock when it gets to the tick, not when it is sent.
  let first = hear()
  let tick = fn(at, notes) {
    set(at)
    process.send(watch.data, stall.Tick)
    list.map(list.repeat(Nil, notes), fn(_) { hear() })
  }
  let ticks =
    list.flatten([
      [first],
      tick(11_000, 1),
      tick(18_000, 2),
      tick(19_000, 1),
    ])
  process.unlink(watch.pid)
  process.kill(watch.pid)
  assert ticks
    == [
      Noted(10_000, False),
      Noted(11_000, False),
      Noted(18_000, True),
      StoodStill(7000),
      Noted(19_000, False),
    ]
}
