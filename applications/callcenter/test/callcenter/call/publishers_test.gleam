//// The node's call publishers: every call's work runs on the one publisher
//// its call id hashes to, in the order it was handed over, and a pool holds
//// one channel per publisher however many calls publish through it.
////
//// The work handed over here is a fake publish -- a function that says
//// which call, which message and which process ran it -- and the pool's
//// `Io` records who asks for a channel instead of asking a broker.

import callcenter/call/publishers
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/set
import kazoo/doc
import kazoo/testing/fake

/// A pool of `count` under a prefix of the test's own, whose publishers
/// tell `channels` when they ask for their channel.
fn pool(
  label: String,
  count: Int,
  channels: Subject(Pid),
) -> #(publishers.Pool, actor.Started(supervisor.Supervisor)) {
  let pool =
    publishers.Pool(
      prefix: "callcenter_test_publishers_" <> label <> "_",
      count: count,
    )
  let assert Ok(started) =
    publishers.start(
      pool,
      publishers.Io(channel: fn() {
        process.send(channels, process.self())
        True
      }),
    )
  #(pool, started)
}

/// The pool's supervisor and every publisher under it gone, without the
/// test going with them.
fn stop(started: actor.Started(supervisor.Supervisor)) -> Nil {
  process.unlink(started.pid)
  process.kill(started.pid)
}

fn publisher_pids(pool: publishers.Pool) -> List(Pid) {
  int.range(from: 0, to: pool.count, with: [], run: fn(pids, index) {
    let assert Ok(pid) = process.named(publishers.name(pool, index))
    [pid, ..pids]
  })
  |> list.reverse
}

fn call_ids(count: Int) -> List(String) {
  int.range(from: 0, to: count, with: [], run: fn(ids, n) {
    ["call-" <> int.to_string(n), ..ids]
  })
  |> list.reverse
}

/// One call's actor, as far as the pool can tell: a process of its own that
/// hands its call's work over in order, a fake publish each.
fn actor_publishing(
  pool: publishers.Pool,
  call_id: String,
  messages: Int,
  published: Subject(#(String, Int, Pid)),
  actors: Subject(Pid),
) -> Nil {
  let _ =
    process.spawn(fn() {
      process.send(actors, process.self())
      int.range(from: 0, to: messages, with: Nil, run: fn(_, n) {
        publishers.send(pool, call_id, fn() {
          process.send(published, #(call_id, n, process.self()))
        })
      })
    })
  Nil
}

fn receive_all(subject: Subject(a), count: Int, acc: List(a)) -> List(a) {
  case count {
    0 -> list.reverse(acc)
    _ -> {
      let assert Ok(one) = process.receive(subject, 2000)
      receive_all(subject, count - 1, [one, ..acc])
    }
  }
}

fn drain(subject: Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(one) -> drain(subject, [one, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

// --- Order ---------------------------------------------------------------------

/// Thirty calls publishing at once through four publishers: each call's
/// messages run in the order its actor handed them over, all of them on the
/// one publisher its call id hashes to.
pub fn every_call_is_published_in_the_order_it_was_decided_test() {
  let channels = process.new_subject()
  let #(pool, started) = pool("order", 4, channels)
  let published = process.new_subject()
  let actors = process.new_subject()
  let calls = call_ids(30)
  list.each(calls, actor_publishing(pool, _, 20, published, actors))
  let records = receive_all(published, 30 * 20, [])
  let pids = publisher_pids(pool)

  list.each(calls, fn(call_id) {
    let own = list.filter(records, fn(record) { record.0 == call_id })
    assert list.map(own, fn(record) { record.1 })
      == int.range(from: 19, to: -1, with: [], run: list.prepend)
    let assert Ok(publisher) =
      list_at(pids, publishers.index(call_id, pool.count))
    assert list.all(own, fn(record) { record.2 == publisher })
  })
  stop(started)
}

// --- Channels ------------------------------------------------------------------

/// Two hundred calls through four publishers ask for four channels, one by
/// each publisher as it starts, and none by a call's actor: what the calls
/// published ran on the publishers and nowhere else.
pub fn a_pool_holds_one_channel_per_publisher_however_many_calls_test() {
  let channels = process.new_subject()
  let #(pool, started) = pool("channels", 4, channels)
  let published = process.new_subject()
  let actors = process.new_subject()
  list.each(call_ids(200), actor_publishing(pool, _, 3, published, actors))
  let records = receive_all(published, 200 * 3, [])
  let pids = set.from_list(publisher_pids(pool))
  let actor_pids = set.from_list(receive_all(actors, 200, []))

  let asked = drain(channels, [])
  assert list.length(asked) == 4
  assert set.from_list(asked) == pids
  assert set.is_disjoint(set.from_list(asked), actor_pids)
  assert set.from_list(list.map(records, fn(record) { record.2 })) == pids
  stop(started)
}

// --- What goes wrong -----------------------------------------------------------

/// A call's work that crashes is logged against the call, and the publisher
/// goes on to the work behind it, of the same call and of others, as the
/// same process.
pub fn a_crash_in_one_calls_work_loses_nothing_behind_it_test() {
  let channels = process.new_subject()
  let #(pool, started) = pool("crash", 1, channels)
  let published = process.new_subject()
  let assert [publisher] = publisher_pids(pool)
  publishers.send(pool, "call-a", fn() { panic as "a publish that throws" })
  publishers.send(pool, "call-a", fn() {
    process.send(published, #("call-a", process.self()))
  })
  publishers.send(pool, "call-b", fn() {
    process.send(published, #("call-b", process.self()))
  })
  assert receive_all(published, 2, [])
    == [#("call-a", publisher), #("call-b", publisher)]
  assert process.named(publishers.name(pool, 0)) == Ok(publisher)
  stop(started)
}

/// Work for a publisher that is not running is dropped and logged, and the
/// actor handing it over goes on.
pub fn a_publisher_not_running_drops_the_work_test() {
  let pool =
    publishers.Pool(prefix: "callcenter_test_publishers_absent_", count: 2)
  let published = process.new_subject()
  publishers.send(pool, "call-a", fn() { process.send(published, Nil) })
  assert process.receive(published, 100) == Error(Nil)
}

/// Without a pool on the node -- no broker, this suite -- an actor's work
/// is run where it is handed over.
pub fn a_node_without_a_pool_runs_the_work_in_place_test() {
  assert publishers.node_pool() == None
  let here = process.self()
  let ran = process.new_subject()
  publishers.of_call("call-a")(fn() { process.send(ran, process.self()) })
  assert process.receive(ran, 0) == Ok(here)
}

// --- The pool's shape ----------------------------------------------------------

/// A call's publisher is the same for every message of the call, and one of
/// the pool's, whatever its size; a thousand calls use every publisher of
/// sixteen.
pub fn a_call_always_hashes_to_one_publisher_of_the_pool_test() {
  let calls = call_ids(1000)
  int.range(from: 1, to: 33, with: Nil, run: fn(_, count) {
    list.each(calls, fn(call_id) {
      let index = publishers.index(call_id, count)
      assert index >= 0 && index < count
      assert publishers.index(call_id, count) == index
    })
  })
  let used =
    list.map(calls, publishers.index(_, 16))
    |> set.from_list
  assert set.size(used) == 16
}

/// `call_publishers` is read from one to `most`: none set is the default,
/// nothing below one, nothing past the bound on registered names.
pub fn how_many_publishers_a_node_runs_test() {
  let cases = [
    #(None, publishers.default_count),
    #(Some(4), 4),
    #(Some(1), 1),
    #(Some(0), 1),
    #(Some(-3), 1),
    #(Some(publishers.most), publishers.most),
    #(Some(10_000), publishers.most),
  ]
  list.each(cases, fn(case_) {
    let #(configured, expected) = case_
    let f = fake.new()
    case configured {
      Some(count) -> fake.put_config(f, "call_publishers", doc.Int(count))
      None -> Nil
    }
    assert publishers.count(fake.kazoo(f)) == expected
  })
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  items |> list.drop(index) |> list.first
}
