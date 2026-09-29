//// A shard's call registry: one actor per call, started only by it, and
//// never one that has ended handed out.

import callcenter/call/actor
import callcenter/call/calls
import callcenter/call/core
import callcenter/call/recovery
import callcenter/types
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{None}
import kazoo/doc
import support/cluster

fn io() -> actor.Io {
  actor.Io(
    now: fn() { cluster.start_of_time },
    monotonic_ms: monotonic_ms,
    queue: fn(_account_id, _queue_id) { Ok(doc.object([])) },
    endpoints: fn(_request, _prefix) { [] },
    grace_s: 5,
    bind: fn(_call) { Nil },
    survey: fn(_member) { recovery.nothing() },
    audit: fn(_call_ids) { [] },
    address: fn() { None },
    perform: fn(_context, _effect: core.Effect) { Nil },
  )
}

/// A registry whose actors are started from it and unlinked, as the
/// shard's factory -- their parent on a node -- leaves them: an actor's end
/// is not the registry's. Every start's count of crashes goes to `strikes`.
fn registry_telling(
  strikes: process.Subject(Int),
) -> process.Subject(calls.Message) {
  let assert Ok(started) =
    calls.start_registry(None, fn(account_id, call_id, count) {
      process.send(strikes, count)
      case actor.start(io(), account_id, call_id, count) {
        Ok(started) -> {
          process.unlink(started.pid)
          Ok(started)
        }
        Error(_) -> Error("could not start")
      }
    })
  started.data
}

fn registry() -> process.Subject(calls.Message) {
  registry_telling(process.new_subject())
}

/// A caller joining twice -- delivered again -- is the one actor.
pub fn one_actor_per_call_test() {
  let calls = registry()
  let replies = process.new_subject()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let assert Ok(first) = calls.join(calls, member, False, replies)
  let assert Ok(again) = calls.join(calls, member, True, replies)
  assert first == again
  assert calls.count(calls) == 1

  let other = cluster.member("call-two", "support", 0, cluster.start_of_time)
  let assert Ok(second) = calls.join(calls, other, False, replies)
  assert second != first
  assert calls.count(calls) == 2
}

/// Only a caller who joined has an actor to ring for them.
pub fn a_ring_needs_a_caller_who_joined_test() {
  let calls = registry()
  let request =
    types.OfferRequest(
      member: cluster.member("nobody", "support", 0, cluster.start_of_time),
      id: types.OfferId(call_id: "nobody", serial: reference.new()),
      agents: ["ann"],
      settings: types.OfferSettings(
        ring_timeout_s: 15,
        cid_prefix: None,
        record: False,
        outbound_caller_id_name: None,
        outbound_caller_id_number: None,
        hold_media: None,
      ),
      reply_to: process.new_subject(),
      devices: None,
    )
  let assert Error(_) = calls.ring(calls, request)
  assert calls.count(calls) == 0
}

/// An actor that ends is forgotten, and the next caller of that call gets a
/// new one -- even when its end has not reached the registry yet.
pub fn an_ended_actor_is_never_handed_out_test() {
  let calls = registry()
  let replies = process.new_subject()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let assert Ok(first) = calls.join(calls, member, False, replies)
  process.kill(first)
  let assert Ok(second) = calls.join(calls, member, False, replies)
  assert second != first
  assert process.is_alive(second)
}

/// The call's new actor after the old one's end reached the registry late
/// is not forgotten when it does: the second caller's join finds it.
pub fn a_late_end_does_not_forget_the_new_actor_test() {
  let calls = registry()
  let replies = process.new_subject()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let assert Ok(first) = calls.join(calls, member, False, replies)
  process.kill(first)
  let assert Ok(second) = calls.join(calls, member, True, replies)
  let assert Ok(third) = calls.join(calls, member, True, replies)
  assert second == third
  assert calls.count(calls) == 1
}

/// Every crash of a call's actor counts against the call: the next actor
/// is started knowing how many, and so quarantined from
/// `actor.quarantine_after` on. From `refuse_after` on none is started.
pub fn a_call_that_keeps_crashing_its_actor_test() {
  let strikes = process.new_subject()
  let calls = registry_telling(strikes)
  let replies = process.new_subject()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let started =
    list.map(list.repeat(Nil, calls.refuse_after), fn(_) {
      let assert Ok(pid) = calls.join(calls, member, True, replies)
      let assert Ok(count) = process.receive(strikes, 1000)
      process.kill(pid)
      // The end reaches the registry before the next join: a kill is a
      // signal, and the registry's monitor hears it on its own time.
      process.sleep(20)
      let _ = calls.count(calls)
      count
    })
  assert started == [0, 1, 2, 3, 4, 5]
  let assert Error(_) = calls.join(calls, member, True, replies)

  // Another call of the account is nothing to do with it.
  let other = cluster.member("call-two", "support", 0, cluster.start_of_time)
  let assert Ok(_) = calls.join(calls, other, False, replies)
  assert process.receive(strikes, 1000) == Ok(0)
}

/// An actor that ends of its own accord is no crash.
pub fn an_actor_that_ends_is_no_strike_test() {
  let strikes = process.new_subject()
  let calls = registry_telling(strikes)
  let replies = process.new_subject()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let assert Ok(pid) = calls.join(calls, member, False, replies)
  let assert Ok(0) = process.receive(strikes, 1000)
  // A caller who hangs up while waiting ends their actor.
  calls.tell(
    calls,
    member,
    actor.Heard(
      doc.object([
        #("Event-Category", doc.String("call_event")),
        #("Event-Name", doc.String("CHANNEL_DESTROY")),
        #("Call-ID", doc.String("call-one")),
      ]),
    ),
  )
  process.sleep(50)
  assert !process.is_alive(pid)
  let _ = calls.count(calls)
  let assert Ok(_) = calls.join(calls, member, False, replies)
  assert process.receive(strikes, 1000) == Ok(0)
}

/// A shard handed over waits for its calls to be steady: callers who are
/// only waiting are, at once.
pub fn waiting_callers_are_steady_at_once_test() {
  let calls = registry()
  let replies = process.new_subject()
  let one = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let two = cluster.member("call-two", "support", 0, cluster.start_of_time)
  let assert Ok(_) = calls.join(calls, one, False, replies)
  let assert Ok(_) = calls.join(calls, two, False, replies)
  assert calls.quiesce_of(calls, 1000) == 0
  // A shard with no registry running has nothing to wait for.
  assert calls.quiesce(9999, 1000) == 0
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
