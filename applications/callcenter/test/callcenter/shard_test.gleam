//// The shard's tree, driven with no broker: a supervisor and its actor,
//// no member listener, a dispatcher that does what the test says, and an
//// ack that is counted instead of sent.
////
//// What is worth testing here is where it has gone wrong before:
//// that a member is settled exactly once whoever asks and in whatever
//// order, that a dispatcher going -- quietly, or crashing, or refusing to
//// stop -- never leaves the shard wrong or lets anything outlive it, and
//// that the tree comes back on its own when a part of it fails.

import callcenter/ask
import callcenter/dispatcher
import callcenter/member
import callcenter/shard
import callcenter/shards
import callcenter/types.{type Member}
import cf_callcenter
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/listener.{type Delivery}
import support/cluster

const account_id = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue_id = "9c9145aeceef7f9cdd9d1fdf40b2e074"

/// A delivery that never came off a broker.
@external(erlang, "callcenter_ffi", "unsettled_delivery")
fn delivery() -> Delivery

/// Another, distinguishable from the first: the same call, delivered again.
@external(erlang, "callcenter_ffi", "redelivered_delivery")
fn another_delivery() -> Delivery

/// The delivery every cancel here comes on, which no member does, so that
/// the settling of cancels is counted apart from the settling of members.
fn cancel_delivery() -> Delivery {
  as_delivery(#(
    atom.create("kazoo_gleam_delivery"),
    atom.create("undefined"),
    "a member_cancel",
  ))
}

@external(erlang, "gleam_stdlib", "identity")
fn as_delivery(term: #(atom.Atom, atom.Atom, String)) -> Delivery

// --- The fake dispatcher ---------------------------------------------------

/// What the fake does when a caller arrives.
type OnArrival {
  /// Hold the caller, and say it has digested them.
  Takes
  /// Stop without a word: the tick found nothing waiting a moment before
  /// the caller reached it.
  VanishesOnArrival
  /// Take its time over every caller, as a dispatcher reading records off
  /// a slow datastore does, and then hold them.
  Slow
  /// Take the caller in, say so, and crash in the pass after: a bug in
  /// dispatching that is no caller's own.
  PassCrashes
  /// Never start at all.
  NeverStarts
  /// Hold the caller, as a dispatcher ringing an agent for them does.
  Rings
}

/// What the fake does when told a caller has left.
type OnLeft {
  /// Ask the shard to settle the caller, as `leave` does.
  Settles
  /// Nothing at all.
  Ignores
  /// Stop, normally: the account went quiet.
  StopsQuietly
  /// Die.
  Crashes
}

/// What the fake does when told to stop.
type OnStop {
  Stops
  /// Neither answers nor stops: wedged.
  IgnoresStop
}

type Fake {
  Fake(
    on_arrival: OnArrival,
    on_left: OnLeft,
    on_stop: OnStop,
    settle: fn(Member) -> Nil,
    /// Called with the call id of every `Left` this dispatcher is told.
    told: fn(String) -> Nil,
    /// Called with every caller it digests, as `handed:<call>`, and every
    /// `Left` it is told, as `left:<call>`, in the order it saw them.
    seen: fn(String) -> Nil,
    /// The calls it crashes on whenever it is handed them.
    poison: List(String),
    members: Dict(String, Member),
  )
}

fn fake_dispatcher(fake: Fake) -> Result(Subject(dispatcher.Message), String) {
  actor.new(fake)
  |> actor.on_message(fn(state: Fake, message: dispatcher.Message) {
    case message {
      dispatcher.HandedOver(caller, recovered, digesting, digested) -> {
        digesting()
        case list.contains(state.poison, caller.call_id), state.on_arrival {
          True, _ -> panic as "the dispatcher could not digest the caller"
          False, VanishesOnArrival -> actor.stop()
          False, _takes -> {
            case state.on_arrival {
              Slow -> process.sleep(1500)
              _ -> Nil
            }
            state.seen("handed:" <> caller.call_id)
            case recovered {
              True -> state.seen("recovered:" <> caller.call_id)
              False -> Nil
            }
            digested()
            case state.on_arrival {
              PassCrashes -> panic as "the pass tripped over an agent"
              _ -> Nil
            }
            actor.continue(
              Fake(
                ..state,
                members: dict.insert(state.members, caller.call_id, caller),
              ),
            )
          }
        }
      }
      // What no dispatcher is ever sent here: a way to crash one with no
      // caller to blame.
      dispatcher.Changed -> panic as "the dispatcher tripped over nothing"
      dispatcher.Left(call_id, _reason) -> {
        state.told(call_id)
        state.seen("left:" <> call_id)
        case state.on_left, dict.get(state.members, call_id) {
          Settles, Ok(caller) -> {
            state.settle(caller)
            actor.continue(
              Fake(..state, members: dict.delete(state.members, call_id)),
            )
          }
          StopsQuietly, _ -> actor.stop()
          Crashes, _ -> panic as "the dispatcher could not digest the cancel"
          _, _ -> actor.continue(state)
        }
      }
      dispatcher.Stop(done) ->
        case state.on_stop {
          IgnoresStop -> actor.continue(state)
          Stops -> {
            process.send(done, Nil)
            actor.stop()
          }
        }
      _other -> actor.continue(state)
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(string.inspect)
}

/// The behaviour of each dispatcher started, in order; `Takes` once the
/// list runs out. An actor, because the shard starts dispatchers from its
/// own process and a closure cannot count.
type Script {
  Next(done: Subject(OnArrival))
}

fn script(arrivals: List(OnArrival)) -> Subject(Script) {
  let assert Ok(started) =
    actor.new(arrivals)
    |> actor.on_message(fn(left, message) {
      case message {
        Next(done) ->
          case left {
            [] -> {
              process.send(done, Takes)
              actor.continue([])
            }
            [next, ..rest] -> {
              process.send(done, next)
              actor.continue(rest)
            }
          }
      }
    })
    |> actor.start
  started.data
}

// --- The harness -----------------------------------------------------------

type Harness {
  Harness(
    shard: Int,
    /// The shard's supervisor.
    tree: Pid,
    to: Subject(shard.Message),
    /// One message per member delivery settled, by anybody.
    acks: Subject(Nil),
    /// One message per cancel settled.
    cancel_acks: Subject(Nil),
    /// One message per dispatcher started.
    starts: Subject(String),
    /// One message per `Left` a dispatcher was told: its account, and the
    /// call.
    lefts: Subject(#(String, String)),
    /// What every dispatcher saw, in order: `<account>:handed:<call>` and
    /// `<account>:left:<call>`.
    seen: Subject(String),
  )
}

fn take(
  shard_id: Int,
  arrivals: List(OnArrival),
  on_left: OnLeft,
  on_stop: OnStop,
) -> Harness {
  take_counting(shard_id, arrivals, on_left, on_stop, None)
}

fn take_counting(
  shard_id: Int,
  arrivals: List(OnArrival),
  on_left: OnLeft,
  on_stop: OnStop,
  count: option.Option(Int),
) -> Harness {
  take_poisoned(shard_id, arrivals, on_left, on_stop, count, [])
}

fn take_poisoned(
  shard_id: Int,
  arrivals: List(OnArrival),
  on_left: OnLeft,
  on_stop: OnStop,
  count: option.Option(Int),
  poison: List(String),
) -> Harness {
  let acks = process.new_subject()
  let cancel_acks = process.new_subject()
  let starts = process.new_subject()
  let lefts = process.new_subject()
  let seen = process.new_subject()
  let arrivals = script(arrivals)
  let hooks =
    shard.Hooks(
      start_offer: shard.no_offers,
      calls: shard.no_calls,
      start_dispatcher: fn(account_id, settle) {
        process.send(starts, account_id)
        case process.call(arrivals, 1000, Next) {
          NeverStarts -> Error("not today")
          on_arrival ->
            fake_dispatcher(Fake(
              on_arrival: on_arrival,
              on_left: on_left,
              on_stop: on_stop,
              settle: settle,
              told: fn(call_id) { process.send(lefts, #(account_id, call_id)) },
              seen: fn(what) { process.send(seen, account_id <> ":" <> what) },
              poison: poison,
              members: dict.new(),
            ))
        }
      },
      consumer: fn(_shard, _to) { None },
      settle: fn(delivery) {
        case delivery == cancel_delivery() {
          True -> process.send(cancel_acks, Nil)
          False -> process.send(acks, Nil)
        }
      },
      count: count,
    )
  let assert Ok(tree) = shard.take_using(shard_id, hooks)
  // The tree is linked to whoever took it, which on a node is the owner,
  // which watches it with a monitor. Here it is eunit's process, and the
  // `shutdown` the tree ends with on release would end the run.
  process.unlink(tree)
  Harness(
    shard: shard_id,
    tree: tree,
    to: process.named_subject(shard.name(shard_id)),
    acks: acks,
    cancel_acks: cancel_acks,
    starts: starts,
    lefts: lefts,
    seen: seen,
  )
}

/// A `member_call` as it comes off the member queue: the callflow's message
/// under the headers the bus put on it.
fn arrive(harness: Harness, call_id: String) -> Nil {
  arrive_on(harness, call_id, delivery())
}

fn arrive_on(harness: Harness, call_id: String, delivery: Delivery) -> Nil {
  arrive_for(harness, account_id, call_id, delivery)
}

fn arrive_for(
  harness: Harness,
  account_id: String,
  call_id: String,
  delivery: Delivery,
) -> Nil {
  arrive_joined(harness, account_id, call_id, delivery, 63_900_000_000)
}

fn arrive_joined(
  harness: Harness,
  account_id: String,
  call_id: String,
  delivery: Delivery,
  joined: Int,
) -> Nil {
  let message =
    doc.merge(
      doc.object([
        #("Event-Category", doc.String("callcenter")),
        #("Event-Name", doc.String("member_call")),
      ]),
      cf_callcenter.member_call(
        account_id: account_id,
        queue_id: queue_id,
        call_id: call_id,
        call: doc.object([#("Call-ID", doc.String(call_id))]),
        node: "kazoo_apps@one",
        joined: joined,
        priority: 0,
        caller_id_name: None,
        caller_id_number: None,
        shards: None,
        handoff_id: "handoff-1",
        branches: doc.object([]),
      ),
    )
  arrive_message(harness, message, delivery)
}

fn arrive_message(harness: Harness, message: doc.Value, delivery: Delivery) {
  process.call(harness.to, 5000, shard.Arrived(
    member.decode(message),
    message,
    delivery,
    _,
  ))
}

fn cancel(harness: Harness, call_id: String) -> Bool {
  cancel_for(harness, account_id, call_id)
}

fn cancel_for(harness: Harness, account_id: String, call_id: String) -> Bool {
  cancel_at(harness, account_id, call_id, queue_id, Some(63_900_000_010))
}

/// A cancel as a node of a release that did not say when the caller joined
/// sends it.
fn cancel_at(
  harness: Harness,
  account_id: String,
  call_id: String,
  queue_id: String,
  cancelled_at: option.Option(Int),
) -> Bool {
  cancel_passage(harness, account_id, call_id, queue_id, None, cancelled_at)
}

fn cancel_passage(
  harness: Harness,
  account_id: String,
  call_id: String,
  queue_id: String,
  joined: option.Option(Int),
  cancelled_at: option.Option(Int),
) -> Bool {
  process.call(harness.to, 5000, shard.Cancelled(
    account_id,
    call_id,
    queue_id,
    "timeout",
    joined,
    cancelled_at,
    cancel_delivery(),
    _,
  ))
}

fn drain(subject: Subject(a)) -> List(a) {
  case process.receive(subject, 50) {
    Ok(item) -> [item, ..drain(subject)]
    Error(Nil) -> []
  }
}

fn holding(harness: Harness) -> List(String) {
  let assert Some(held) = shard.held(harness.shard)
  held.call_ids
}

fn actor_pid(harness: Harness) -> Pid {
  let assert Ok(pid) = process.named(shard.name(harness.shard))
  pid
}

fn dispatcher_pid(harness: Harness) -> Pid {
  let assert Ok(to) = shard.dispatcher(harness.shard, account_id)
  let assert Ok(pid) = process.subject_owner(to)
  pid
}

/// Wait for the shard's actor to be a different process from `was`, as it
/// is once the supervisor has restarted it.
fn restarted(harness: Harness, was: Pid, attempts: Int) -> Pid {
  case process.named(shard.name(harness.shard)) {
    Ok(now) if now != was -> now
    _not_yet if attempts > 0 -> {
      process.sleep(20)
      restarted(harness, was, attempts - 1)
    }
    _ -> panic as "the shard actor was not restarted"
  }
}

fn finish(harness: Harness) -> Nil {
  shard.release(harness.shard)
  assert shard.holds(harness.shard) == False
  assert process.is_alive(harness.tree) == False
}

// --- The tests -------------------------------------------------------------

/// What the take answers is the shard's supervisor, so that whoever started
/// it can match its exit signal to it; the actor under it is registered.
pub fn the_take_answers_the_tree_test() {
  let h = take(40, [], Settles, Stops)
  assert process.is_alive(h.tree) == True
  assert process.is_alive(actor_pid(h)) == True
  assert shard.held(40) == Some(shard.Held(40, shards.member_queue(40), []))
  finish(h)
}

/// The cancel used to be a question put to the
/// dispatcher, and the dispatcher stopped itself while being asked. Now the
/// dispatcher is told and not waited for. It stops itself on the news and
/// the shard neither notices nor cares; the member is settled once, here.
pub fn a_cancel_is_settled_by_the_shard_whatever_the_dispatcher_does_test() {
  let h = take(41, [], StopsQuietly, Stops)
  arrive(h, "call-one")
  assert drain(h.starts) == [account_id]
  assert holding(h) == ["call-one"]

  assert cancel(h, "call-one") == True
  assert holding(h) == []
  assert list.length(drain(h.acks)) == 1

  // The dispatcher is gone, and the same cancel again is nobody's.
  assert cancel(h, "call-one") == False
  assert drain(h.acks) == []
  assert shard.holds(41) == True
  finish(h)
}

/// The dispatcher asks for the caller to be settled, and a cancel for the
/// same caller comes straight after, with the caller's
/// channel going a moment before the cancel. Once, in either order.
pub fn a_member_is_settled_once_whoever_asks_first_test() {
  let h = take(42, [], Ignores, Stops)
  arrive(h, "call-one")
  arrive(h, "call-two")

  // The dispatcher first, as `leave` does it, then the cancel.
  process.send(h.to, shard.Settle(account_id, "call-one", delivery()))
  assert cancel(h, "call-one") == False
  assert list.length(drain(h.acks)) == 1

  // The cancel first, then the dispatcher, late.
  assert cancel(h, "call-two") == True
  process.send(h.to, shard.Settle(account_id, "call-two", delivery()))
  assert holding(h) == []
  assert list.length(drain(h.acks)) == 1
  finish(h)
}

/// A caller who left and came back is a new delivery under the same call
/// id. A settlement that names the old delivery -- an offer for the first
/// passage answering late -- settles nothing; one that names the new one
/// settles it.
pub fn a_late_settlement_does_not_settle_the_callers_next_passage_test() {
  let h = take(50, [], Ignores, Stops)
  arrive_on(h, "call-one", delivery())
  arrive_on(h, "call-one", another_delivery())
  assert holding(h) == ["call-one"]
  // The delivery replaced is settled as it is replaced.
  assert list.length(drain(h.acks)) == 1

  process.send(h.to, shard.Settle(account_id, "call-one", delivery()))
  assert holding(h) == ["call-one"]
  assert drain(h.acks) == []

  process.send(h.to, shard.Settle(account_id, "call-one", another_delivery()))
  assert holding(h) == []
  assert list.length(drain(h.acks)) == 1
  finish(h)
}

/// A dispatcher killed from outside -- nothing was being asked of it -- is
/// started again, and handed its callers, who are still held here; the
/// shard actor, and the tree, are the same.
pub fn a_dispatcher_killed_out_of_the_blue_is_started_again_test() {
  let h = take(51, [], Ignores, Stops)
  arrive(h, "call-one")
  let actor = actor_pid(h)
  let killed = dispatcher_pid(h)
  assert next(h.seen, 1000) == account_id <> ":handed:call-one"
  process.kill(killed)
  assert next(h.seen, 1000) == account_id <> ":handed:call-one"
  assert actor_pid(h) == actor
  assert dispatcher_pid(h) != killed
  assert drain(h.starts) == [account_id, account_id]
  assert holding(h) == ["call-one"]
  assert drain(h.acks) == []
  finish(h)
}

/// A tree whose listener has not yet been given the queue holds nothing:
/// another node may have it, and this tree may be about to find out. Only
/// the listener's word makes the shard this node's -- and the actor itself
/// refuses to start a dispatcher before then, whatever the asker checked:
/// the asker may have checked an actor this one has since replaced.
pub fn a_shard_is_not_held_until_its_listener_consumes_test() {
  let acks = process.new_subject()
  let asked = process.new_subject()
  let hooks =
    shard.Hooks(
      start_offer: shard.no_offers,
      calls: shard.no_calls,
      start_dispatcher: fn(_account_id, _settle) {
        process.send(asked, Nil)
        Error("not in this test")
      },
      // A listener that is up and has not said a word.
      consumer: fn(_shard, _to) {
        Some(
          supervision.worker(fn() {
            let pid = process.spawn(fn() { process.sleep_forever() })
            Ok(actor.Started(pid: pid, data: Nil))
          }),
        )
      },
      settle: fn(_delivery) { process.send(acks, Nil) },
      count: None,
    )
  let assert Ok(tree) = shard.take_using(52, hooks)
  process.unlink(tree)

  assert shard.holds(52) == False
  assert shard.held(52) == None
  assert shard.dispatcher(52, account_id) == Error(Nil)
  assert shard.tree(52) == Ok(tree)

  // Asked directly, as an asker that checked the previous actor would: the
  // actor answers for itself.
  let to = process.named_subject(shard.name(52))
  assert process.call(to, 1000, shard.Dispatcher(account_id, True, _)) == None
  assert process.call(to, 1000, shard.Dispatchers) == []
  assert process.call(to, 1000, shard.Report) == None
  assert drain(asked) == []

  // The listener speaks.
  process.send(to, shard.Consuming)
  assert shard.holds(52) == True
  assert shard.held(52) == Some(shard.Held(52, shards.member_queue(52), []))
  assert process.call(to, 1000, shard.Report)
    == Some(shard.Held(52, shards.member_queue(52), []))
  assert process.call(to, 1000, shard.Dispatcher(account_id, True, _)) == None
  assert drain(asked) == [Nil]

  shard.release(52)
  assert shard.tree(52) == Error(Nil)
}

/// A dispatcher that settles the caller it was told had left asks the shard,
/// which has already done it: one ack, not two.
pub fn a_dispatcher_settling_a_cancelled_caller_is_nothing_test() {
  let h = take(43, [], Settles, Stops)
  arrive(h, "call-one")

  assert cancel(h, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  finish(h)
}

/// The member listener acked a cancel whatever the
/// shard actor answered, and an actor that had gone had settled nothing and
/// noted nothing -- the cancel was gone, and the caller's `member_call` came
/// back at the failover with nothing behind it. The cancel is settled by the
/// actor, once it has dealt with it: whether it settled a member or was
/// only noted for the member behind it.
pub fn a_cancel_is_settled_by_the_shard_once_it_is_dealt_with_test() {
  let h = take(77, [], Ignores, Stops)
  arrive(h, "call-one")
  assert cancel(h, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  assert list.length(drain(h.cancel_acks)) == 1

  // Nothing held: noted, and settled all the same.
  assert cancel(h, "call-two") == False
  assert drain(h.acks) == []
  assert list.length(drain(h.cancel_acks)) == 1
  finish(h)
}

/// A cancel that reaches a shard actor which goes before dealing with it is
/// settled by nobody: it goes back to the broker with the channel, for the
/// next holder, beside the member it cancels.
pub fn a_cancel_the_shard_never_dealt_with_is_not_settled_test() {
  let h = take(78, [], Ignores, Stops)
  arrive(h, "call-one")
  let actor = actor_pid(h)
  // Busy, as far as the cancel is concerned: it waits in the mailbox.
  let _ = suspend(actor)
  process.send(
    h.to,
    shard.Cancelled(
      account_id,
      "call-one",
      queue_id,
      "hangup",
      None,
      Some(63_900_000_010),
      cancel_delivery(),
      process.new_subject(),
    ),
  )
  process.kill(actor)
  let _ = restarted(h, actor, 100)
  assert drain(h.cancel_acks) == []
  assert drain(h.acks) == []
  finish(h)
}

@external(erlang, "sys", "suspend")
fn suspend(pid: Pid) -> Dynamic

/// A caller no dispatcher took -- none would start -- is held all the same,
/// and settled by the cancel; a cancel for a caller who was never here is
/// nobody's.
pub fn a_caller_nobody_took_is_settled_all_the_same_test() {
  let h = take(44, [NeverStarts], Settles, Stops)
  arrive(h, "call-one")
  assert drain(h.starts) == [account_id]
  assert holding(h) == ["call-one"]
  assert drain(h.acks) == []

  assert cancel(h, "call-one") == True
  assert list.length(drain(h.acks)) == 1

  assert cancel(h, "call-nine") == False
  assert drain(h.acks) == []
  finish(h)
}

/// A dispatcher that stops as a caller is handed to it is replaced, and the
/// caller is handed to the replacement: a caller nobody is dispatching is a
/// caller who waits until they give up. Handed as recovered, because nothing
/// here knows what the one that went had started for them.
pub fn a_dispatcher_that_stops_as_a_caller_arrives_is_replaced_test() {
  let h = take(45, [VanishesOnArrival], Settles, Stops)
  arrive(h, "call-one")
  assert drain(h.starts) == [account_id, account_id]
  assert drain(h.seen)
    == [
      account_id <> ":handed:call-one",
      account_id <> ":recovered:call-one",
    ]
  assert holding(h) == ["call-one"]
  assert process.is_alive(dispatcher_pid(h)) == True
  finish(h)
}

/// An account whose dispatcher would not start has its callers held, and
/// the dispatcher its next caller starts is handed every one of them.
pub fn a_dispatcher_started_late_is_handed_every_caller_held_test() {
  let h = take(65, [NeverStarts], Settles, Stops)
  arrive(h, "call-one")
  arrive(h, "call-two")
  assert drain(h.starts) == [account_id, account_id]
  assert drain(h.seen)
    == [account_id <> ":handed:call-one", account_id <> ":handed:call-two"]
  finish(h)
}

/// A dispatcher crashes with an agent being rung for
/// its caller, and the one its end starts cannot start. The sweep then asks
/// for one, and it used to be handed the caller as if nothing had gone
/// before: their record went unread, and a second agent was rung while the
/// first one's bridge was up. Every start asks the same question now.
pub fn a_dispatcher_the_sweep_starts_after_a_failed_restart_recovers_test() {
  let h = take(76, [Takes, NeverStarts], Ignores, Stops)
  arrive(h, "call-one")
  assert next(h.seen, 1000) == account_id <> ":handed:call-one"
  process.kill(dispatcher_pid(h))
  // The end's own restart, which fails.
  assert next(h.starts, 1000) == account_id
  assert next(h.starts, 1000) == account_id
  assert shard.dispatcher(76, account_id) == Error(Nil)

  let assert Ok(_to) = shard.start_dispatcher(76, account_id)
  assert drain(h.seen)
    == [
      account_id <> ":handed:call-one",
      account_id <> ":recovered:call-one",
    ]
  assert holding(h) == ["call-one"]
  finish(h)
}

// --- A slow dispatcher -----------------------------------------------------

/// The shard used to wait up to thirty seconds for a
/// dispatcher to take each caller, and a dispatcher reading records off a
/// slow datastore after a failover held every other account's arrivals and
/// cancels behind it, and the owner's `IsHeld` timed out so the node took
/// more shards. Callers are handed over now, not asked about: with one
/// account's dispatcher busy for seconds, another account's caller arrives,
/// is cancelled and settled, and the shard answers for itself, at once.
pub fn a_slow_dispatcher_holds_up_no_other_account_test() {
  let h = take(66, [Slow], Settles, Stops)
  arrive_for(h, account_id, "call-a1", delivery())
  arrive_for(h, account_id, "call-a2", delivery())
  let started = monotonic_ms()
  arrive_for(h, other_account, "call-b1", delivery())
  assert cancel_for(h, other_account, "call-b1") == True
  assert shard.holds(66) == True
  assert list.sort(holding(h), string.compare) == ["call-a1", "call-a2"]
  assert monotonic_ms() - started < 500
  assert next(h.seen, 1000) == other_account <> ":handed:call-b1"
  assert next(h.seen, 1000) == other_account <> ":left:call-b1"
  finish(h)
}

/// Handing over by message keeps the order: a cancel that follows a caller
/// into a busy dispatcher's mailbox reaches it after the caller, however
/// long the dispatcher takes over the caller.
pub fn a_cancel_reaches_a_busy_dispatcher_after_its_caller_test() {
  let h = take(67, [Slow], Settles, Stops)
  arrive(h, "call-one")
  assert cancel(h, "call-one") == True
  assert next(h.seen, 3000) == account_id <> ":handed:call-one"
  assert next(h.seen, 1000) == account_id <> ":left:call-one"
  assert list.length(drain(h.acks)) == 1
  finish(h)
}

fn next(subject: Subject(a), within_ms: Int) -> a {
  let assert Ok(item) = process.receive(subject, within_ms)
  item
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// An operator releasing a member by hand -- `release_member`, or
/// `ack_member`, its older name -- does what the caller's cancel would:
/// the member is settled, once, and the account's dispatcher is told the
/// caller left, so that it stops offering them, frees whoever it was ringing
/// for them and closes their record. Settled and not told, as `ack_member`
/// used to leave it, the caller went on being offered with nothing on the
/// broker behind them.
pub fn a_member_released_by_hand_is_told_to_the_dispatcher_test() {
  let h = take(46, [], Ignores, Stops)
  arrive(h, "call-one")
  assert shard.release_member(46, account_id, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  assert drain(h.lefts) == [#(account_id, "call-one")]
  assert holding(h) == []

  // Once: a second release finds nothing held, and tells nobody.
  assert shard.release_member(46, account_id, "call-one") == False
  assert drain(h.acks) == []
  assert drain(h.lefts) == []
  finish(h)
}

/// The dispatcher's own settle, when it drops the caller it was told of,
/// finds the member already released and settles nothing a second time.
pub fn a_member_released_by_hand_is_settled_once_test() {
  let h = take(74, [], Settles, Stops)
  arrive(h, "call-one")
  assert shard.release_member(74, account_id, "call-one") == True
  assert next(h.seen, 1000) == account_id <> ":handed:call-one"
  assert next(h.seen, 1000) == account_id <> ":left:call-one"
  assert shard.holds(74)
  assert list.length(drain(h.acks)) == 1
  finish(h)
}

/// A dispatcher that does not answer `Stop`
/// used to outlive the shard. The supervisor's shutdown reaches the actor
/// as a message, the actor asks, waits, and kills; nothing is left.
pub fn release_ends_a_dispatcher_that_will_not_stop_test() {
  let h = take(47, [], Settles, IgnoresStop)
  arrive(h, "call-one")
  let wedged = dispatcher_pid(h)
  let actor = actor_pid(h)

  finish(h)

  assert process.is_alive(wedged) == False
  assert process.is_alive(actor) == False
}

/// And one that stops when asked is waited for, not killed.
pub fn release_stops_its_dispatchers_test() {
  let h = take(48, [], Settles, Stops)
  arrive(h, "call-one")
  let willing = dispatcher_pid(h)

  finish(h)

  assert process.is_alive(willing) == False
}

/// A dispatcher that crashes with none of its account's callers left to
/// hand over is forgotten, and not started again until the account's next
/// caller. The shard actor is the same one.
pub fn a_crashed_dispatcher_with_nobody_waiting_is_just_forgotten_test() {
  let h = take(49, [], Crashes, Stops)
  arrive(h, "call-one")
  let before = actor_pid(h)

  // The cancel settles the member here, and the dispatcher dies of the
  // news.
  assert cancel(h, "call-one") == True
  process.sleep(50)
  assert actor_pid(h) == before
  assert holding(h) == []
  assert shard.dispatcher(49, account_id) == Error(Nil)
  assert drain(h.starts) == [account_id]

  arrive(h, "call-two")
  assert drain(h.starts) == [account_id]
  finish(h)
}

// --- A dispatcher crashing -------------------------------------------------

/// A dispatcher crash ended the shard actor, which
/// killed every other account's dispatcher -- and their offers -- and
/// redelivered every member on the shard. Now it is that account's alone:
/// the other account's dispatcher is the same process, holding the same
/// caller, and the shard actor never went.
pub fn one_accounts_crash_leaves_the_other_accounts_alone_test() {
  let h = take(68, [], Ignores, Stops)
  arrive_for(h, other_account, "call-b", delivery())
  arrive_for(h, account_id, "call-a", delivery())
  let assert Ok(theirs) = shard.dispatcher(68, other_account)
  let ours = dispatcher_pid(h)
  let actor = actor_pid(h)
  assert list.length(drain(h.seen)) == 2

  process.send_abnormal_exit(ours, "the dispatcher tripped")
  assert next(h.seen, 1000) == account_id <> ":handed:call-a"
  // Handed on as recovered: the dispatcher that went may have left an offer
  // ringing for them, so the new one reads their record before ringing.
  assert next(h.seen, 1000) == account_id <> ":recovered:call-a"
  assert shard.dispatcher(68, other_account) == Ok(theirs)
  assert dispatcher_pid(h) != ours
  assert actor_pid(h) == actor
  assert drain(h.starts) == [other_account, account_id, account_id]
  assert list.sort(holding(h), string.compare) == ["call-a", "call-b"]
  assert drain(h.acks) == []
  finish(h)
}

/// A caller who crashes every dispatcher they are handed to used to bounce
/// the whole shard six times a minute, for as long as they waited, and
/// move it from node to node. They are laid at their own door: three
/// crashes while digesting them and their member is settled and handed to
/// nobody again. The account's other caller is handed over each time and
/// is still held, dispatched by a fourth dispatcher that lives.
pub fn a_caller_who_crashes_every_dispatcher_is_quarantined_test() {
  let h = take_poisoned(69, [], Ignores, Stops, None, ["call-poison"])
  let actor = actor_pid(h)
  arrive(h, "call-one")
  arrive_on(h, "call-poison", another_delivery())

  assert next(h.acks, 3000) == Nil
  process.sleep(50)
  assert holding(h) == ["call-one"]
  assert drain(h.acks) == []
  assert drain(h.starts) == [account_id, account_id, account_id, account_id]
  assert list.count(drain(h.seen), fn(seen) {
      seen == account_id <> ":handed:call-one"
    })
    == 4
  assert actor_pid(h) == actor
  assert process.is_alive(dispatcher_pid(h)) == True

  // Their cancel, when it comes, settles nothing.
  assert cancel(h, "call-poison") == False
  assert drain(h.acks) == []
  finish(h)
}

/// A dispatcher that keeps crashing with no caller to blame -- here on a
/// message that is not an arrival -- is started again ten times in a
/// minute, and the eleventh ends the shard actor as a crash used to: the
/// tree starts it again, and the broker hands the members back.
pub fn a_dispatcher_that_keeps_crashing_restarts_the_shard_test() {
  let h = take(70, [], Ignores, Stops)
  arrive(h, "call-one")
  let actor = actor_pid(h)
  crash_times(h, 10)
  assert actor_pid(h) == actor
  assert holding(h) == ["call-one"]
  assert drain(h.acks) == []

  process.send(dispatcher_subject(h), dispatcher.Changed)
  let after = restarted(h, actor, 50)
  assert after != actor
  assert holding(h) == []
  finish(h)
}

/// A crash in the pass after an arrival
/// was laid at that arrival's door, and after a restart that arrival is
/// always the account's longest waiting caller, so a bug in the pass that
/// an agent or a queue sets off quarantined the three oldest callers one
/// after another before the shard gave up. A crash after the dispatcher
/// has taken a caller in is nobody's: nobody is settled, the caller handed
/// over next is not blamed either, and ten ends a minute end the shard.
pub fn a_crash_in_the_pass_quarantines_nobody_test() {
  let h = take(71, [Takes, ..list.repeat(PassCrashes, 10)], Ignores, Stops)
  arrive(h, "call-one")
  arrive(h, "call-two")
  arrive(h, "call-three")
  let actor = actor_pid(h)
  assert list.length(drain(h.seen)) == 3

  // The first end is on no arrival at all; each after it is the pass after
  // call-one, handed first to every new dispatcher.
  process.send(dispatcher_subject(h), dispatcher.Changed)
  let after = restarted(h, actor, 100)
  assert after != actor
  assert drain(h.acks) == []
  assert list.count(drain(h.seen), fn(seen) {
      seen == account_id <> ":handed:call-one"
    })
    == 10
  finish(h)
}

fn crash_times(h: Harness, times: Int) -> Nil {
  case times {
    0 -> Nil
    _ -> {
      let was = dispatcher_pid(h)
      process.send(dispatcher_subject(h), dispatcher.Changed)
      replaced(h, was, 50)
      crash_times(h, times - 1)
    }
  }
}

fn dispatcher_subject(h: Harness) -> Subject(dispatcher.Message) {
  let assert Ok(to) = shard.dispatcher(h.shard, account_id)
  to
}

/// Wait for the account's dispatcher to be another process than `was`.
fn replaced(h: Harness, was: Pid, attempts: Int) -> Nil {
  case shard.dispatcher(h.shard, account_id) {
    Ok(to) if attempts > 0 ->
      case process.subject_owner(to) {
        Ok(now) if now != was -> Nil
        _ -> {
          process.sleep(10)
          replaced(h, was, attempts - 1)
        }
      }
    _ if attempts > 0 -> {
      process.sleep(10)
      replaced(h, was, attempts - 1)
    }
    _ -> panic as "the dispatcher was not started again"
  }
}

/// Another account that hashes to the same shard.
const other_account = "8e2a4c6b0d1f3e5a7c9b1d3f5e7a9c0b"

/// Accounts share a shard, and a call id is only what somebody sent. A
/// cancel from one account that names another account's call settles
/// nothing, and the other account's dispatcher hears nothing of it; the
/// cancel from the call's own account settles it, once, and tells only that
/// account's dispatcher.
pub fn a_cancel_settles_only_its_own_accounts_call_test() {
  let h = take(53, [], Settles, Stops)
  arrive_for(h, other_account, "call-b", delivery())
  arrive(h, "call-a")
  assert drain(h.starts) == [other_account, account_id]

  assert cancel_for(h, account_id, "call-b") == False
  assert drain(h.acks) == []
  assert drain(h.lefts) == [#(account_id, "call-b")]
  assert list.sort(holding(h), string.compare) == ["call-a", "call-b"]

  // By hand, the same: the account named is the account settled.
  assert shard.release_member(53, account_id, "call-b") == False
  assert drain(h.acks) == []

  assert cancel_for(h, other_account, "call-b") == True
  assert list.length(drain(h.acks)) == 1
  assert drain(h.lefts) == [#(other_account, "call-b")]
  assert holding(h) == ["call-a"]
  finish(h)
}

/// The same call id under two accounts is two members. One arriving does
/// not replace the other, and settling one leaves the other held.
pub fn the_same_call_id_in_two_accounts_is_two_members_test() {
  let h = take(54, [], Ignores, Stops)
  arrive_for(h, other_account, "call-one", delivery())
  arrive(h, "call-one")
  assert holding(h) == ["call-one", "call-one"]

  process.send(h.to, shard.Settle(account_id, "call-one", delivery()))
  assert holding(h) == ["call-one"]
  assert list.length(drain(h.acks)) == 1

  assert cancel_for(h, other_account, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  finish(h)
}

// --- The broker cancelling the member consumer -----------------------------

@external(erlang, "kazoo_gleam_listener", "init")
fn listener_init(args: List(Dict(String, Dynamic))) -> Result(Dynamic, Nil)

@external(erlang, "kazoo_gleam_listener", "handle_info")
fn listener_info(info: anything, state: Dynamic) -> #(Dynamic, Dynamic)

/// The broker cancels the member consumer -- the queue
/// was deleted, or lost -- and `gen_listener` does not notice. The shard's
/// listener used to ignore it and go on holding a queue that fed it nothing
/// while another node declared it again, found it unowned and took it. Now
/// it is the consumer lost, and the listener ends, as it does on a lost
/// channel, and the tree with it (`a_listener_that_ends_ends_the_tree`).
///
/// Here the listener's own callbacks are run in a process of their own, as
/// `gen_listener` runs them; on a node `gen_listener` catches the exit and
/// stops with it.
pub fn a_member_consumer_the_broker_cancelled_ends_the_listener_test() {
  let to = process.new_subject()
  let spec = listener.to_spec(shard.member_listener(60, to))
  let pid =
    process.spawn_unlinked(fn() {
      let assert Ok(state) = listener_init([spec])
      let _ =
        listener_info(
          #(atom.create("basic.cancel"), "amq.ctag-member-60", False),
          state,
        )
      process.sleep_forever()
    })
  let monitor = process.monitor(pid)
  let assert Ok(process.ProcessDown(reason: reason, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  assert reason == process.Normal
}

/// A listener that ends -- its channel lost, its consumer refused or
/// cancelled -- ends the tree, once, and nothing is started again under it:
/// whoever looks at the shard next takes it on a fresh channel. It used to
/// restart the tree, and a broker restart was five refusals in a row, a
/// tree that gave up, and a node that took nothing back.
pub fn a_listener_that_ends_ends_the_tree_test() {
  let listeners = process.new_subject()
  let hooks =
    shard.Hooks(
      start_offer: shard.no_offers,
      calls: shard.no_calls,
      start_dispatcher: fn(_account_id, _settle) { Error("not in this test") },
      consumer: fn(_shard, _to) {
        Some(
          supervision.worker(fn() {
            // Consumes for a moment, then loses its channel.
            let pid = process.spawn(fn() { process.sleep(100) })
            process.send(listeners, pid)
            Ok(actor.Started(pid: pid, data: Nil))
          }),
        )
      },
      settle: fn(_delivery) { Nil },
      count: None,
    )
  let assert Ok(tree) = shard.take_using(54, hooks)
  process.unlink(tree)
  let assert Ok(_listener) = process.receive(listeners, 1000)
  assert gone_within(tree, 50) == True
  assert shard.tree(54) == Error(Nil)
  assert process.receive(listeners, 200) == Error(Nil)
}

// --- A member arriving for a call already held -----------------------------

/// A member arriving for a call the shard already
/// holds replaced the delivery held without settling it, and the old one sat
/// unacked on the channel until the next failover handed it to another node
/// as a caller nobody was waiting for. It is settled as it is replaced, once:
/// a settlement naming it afterwards is nothing, and the cancel settles the
/// one that replaced it.
pub fn a_member_delivered_again_settles_the_one_it_replaces_test() {
  let h = take(55, [], Ignores, Stops)
  arrive_on(h, "call-one", delivery())
  assert drain(h.acks) == []
  arrive_on(h, "call-one", another_delivery())
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == ["call-one"]

  process.send(h.to, shard.Settle(account_id, "call-one", delivery()))
  assert drain(h.acks) == []
  assert cancel(h, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  finish(h)
}

/// A member of an earlier passage arriving after the caller's next one --
/// the caller left and came back, and the old message was the slower -- is
/// the one settled, and the passage held stays held and dispatched.
pub fn an_older_passage_arriving_late_is_settled_test() {
  let h = take(56, [], Ignores, Stops)
  arrive_joined(h, account_id, "call-one", another_delivery(), 63_900_000_100)
  assert drain(h.starts) == [account_id]
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == ["call-one"]

  // The one held is the later passage's.
  process.send(h.to, shard.Settle(account_id, "call-one", another_delivery()))
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  finish(h)
}

/// A member with no call id, or no account, or that is not a `member_call`
/// at all, is nothing a dispatcher could offer and nothing a cancel could
/// name. It used to be held for as long as the shard was, and redelivered on
/// every failover; it is settled on arrival, and no dispatcher is started
/// for it.
pub fn a_message_that_is_not_a_caller_is_settled_test() {
  let h = take(57, [], Ignores, Stops)
  arrive_message(
    h,
    doc.object([
      #("Event-Name", doc.String("member_call")),
      #("Account-ID", doc.String(account_id)),
      #("Queue-ID", doc.String(queue_id)),
    ]),
    delivery(),
  )
  arrive_message(
    h,
    doc.object([
      #("Event-Name", doc.String("member_call")),
      #("Call-ID", doc.String("call-one")),
    ]),
    delivery(),
  )
  arrive_message(
    h,
    doc.object([
      #("Event-Name", doc.String("member_something")),
      #("Account-ID", doc.String(account_id)),
      #("Call-ID", doc.String("call-one")),
    ]),
    delivery(),
  )
  assert list.length(drain(h.acks)) == 3
  assert holding(h) == []
  assert drain(h.starts) == []
  finish(h)
}

// --- A cancel that arrives before its member -------------------------------

/// `gen_listener` hands each delivery to a process of
/// its own, so a caller's `member_call` and `member_cancel` can reach the
/// shard in either order. A cancel that came first found nothing held and
/// was forgotten, and the `member_call` behind it became a caller who had
/// already left, dispatched: the offer's bridge broke into whatever their
/// callflow was doing next. Now the cancel is remembered, and the member
/// that joined before it is settled on arrival and never handed to a
/// dispatcher.
pub fn a_cancel_before_its_member_settles_the_member_on_arrival_test() {
  let h = take(58, [], Ignores, Stops)
  assert cancel_at(h, account_id, "call-one", queue_id, Some(63_900_000_010))
    == False
  assert drain(h.acks) == []

  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  assert drain(h.starts) == []
  finish(h)
}

/// The other order is the ordinary one, and unchanged: held, then settled
/// by the cancel, once.
pub fn a_member_before_its_cancel_is_settled_by_the_cancel_test() {
  let h = take(59, [], Ignores, Stops)
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert drain(h.starts) == [account_id]
  assert cancel_at(h, account_id, "call-one", queue_id, Some(63_900_000_010))
    == True
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  finish(h)
}

/// A caller who left and came back to the same queue with the same call id
/// joined after they left, and is dispatched like anybody else however
/// recently their cancel went by.
pub fn a_caller_back_in_the_queue_after_their_cancel_is_dispatched_test() {
  let h = take(61, [], Ignores, Stops)
  assert cancel_at(h, account_id, "call-one", queue_id, Some(63_900_000_010))
    == False
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_011)
  assert drain(h.acks) == []
  assert holding(h) == ["call-one"]
  assert drain(h.starts) == [account_id]
  finish(h)
}

/// Another queue is another passage: a cancel for the queue the caller left
/// does not bury their member in the queue they went to next.
pub fn a_cancel_buries_only_its_own_queues_member_test() {
  let h = take(62, [], Ignores, Stops)
  assert cancel_at(
      h,
      account_id,
      "call-one",
      "other-queue",
      Some(63_900_000_010),
    )
    == False
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert drain(h.acks) == []
  assert holding(h) == ["call-one"]
  finish(h)
}

/// A node of an older release sends no `Cancelled-Timestamp`. Its cancel is
/// taken to have been made as it reached the shard -- it can be no younger
/// than that -- so the member of the passage it cancelled, joined before
/// it, is still buried.
pub fn a_cancel_without_a_time_is_taken_as_made_on_arrival_test() {
  let h = take(63, [], Ignores, Stops)
  assert cancel_at(h, account_id, "call-one", queue_id, None) == False
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  assert drain(h.starts) == []
  finish(h)
}

/// A late cancel for the caller's earlier passage, arriving while their
/// next one is held, settles nothing and tells the dispatcher nothing: the
/// caller it would take out of the queue is in it again. The same for a
/// cancel naming the queue they left when they are held in another.
pub fn a_cancel_for_an_earlier_passage_leaves_the_later_one_test() {
  let h = take(64, [], Settles, Stops)
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_100)
  assert cancel_at(h, account_id, "call-one", queue_id, Some(63_900_000_050))
    == False
  assert cancel_at(
      h,
      account_id,
      "call-one",
      "other-queue",
      Some(63_900_000_200),
    )
    == False
  assert drain(h.acks) == []
  assert drain(h.lefts) == []
  assert holding(h) == ["call-one"]

  assert cancel_at(h, account_id, "call-one", queue_id, Some(63_900_000_200))
    == True
  assert list.length(drain(h.acks)) == 1
  finish(h)
}

/// A cancel went on burying for its whole minute, and
/// buried every passage of the call through the queue that joined by the
/// second the caller left. A caller whose callflow sent them straight back
/// into the queue, in that second, was settled on arrival and never
/// dispatched. A cancel buries one passage now, and is used up doing it.
pub fn a_cancel_buries_one_passage_and_no_more_test() {
  let h = take(79, [], Ignores, Stops)
  assert cancel_at(h, account_id, "call-one", queue_id, Some(63_900_000_010))
    == False
  // The member it cancelled, late: buried, once.
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert list.length(drain(h.acks)) == 1
  assert drain(h.starts) == []
  // Back in the queue in the second they left it.
  arrive_joined(h, account_id, "call-one", another_delivery(), 63_900_000_010)
  assert drain(h.acks) == []
  assert holding(h) == ["call-one"]
  assert drain(h.starts) == [account_id]
  finish(h)
}

/// A cancel that says when the caller joined (`Joined-Timestamp`) buries the
/// member of that passage and no other, whichever of the two comes first:
/// the caller's next passage, joined in the second they left, arriving
/// ahead of the cancelled one, is dispatched, and the cancelled one behind
/// it is not.
pub fn a_cancel_that_says_when_the_caller_joined_buries_that_passage_test() {
  let h = take(80, [], Ignores, Stops)
  assert cancel_passage(
      h,
      account_id,
      "call-one",
      queue_id,
      Some(63_900_000_000),
      Some(63_900_000_010),
    )
    == False
  arrive_joined(h, account_id, "call-one", another_delivery(), 63_900_000_010)
  assert drain(h.acks) == []
  assert holding(h) == ["call-one"]
  assert drain(h.starts) == [account_id]
  // The cancelled passage, late: settled, and the one held is kept.
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == ["call-one"]
  finish(h)
}

/// A cancel that says when the caller joined leaves a later passage held,
/// joined in the very second the caller left the first. The cancel of a
/// later passage than the one held settles the one held, which the caller
/// has left as well, and waits for its own.
pub fn a_cancel_that_says_when_the_caller_joined_settles_only_its_passage_test() {
  let h = take(81, [], Settles, Stops)
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_010)
  assert cancel_passage(
      h,
      account_id,
      "call-one",
      queue_id,
      Some(63_900_000_000),
      Some(63_900_000_010),
    )
    == False
  assert drain(h.acks) == []
  assert holding(h) == ["call-one"]

  // The cancel of the passage joined at ..020, ahead of its member.
  assert cancel_passage(
      h,
      account_id,
      "call-one",
      queue_id,
      Some(63_900_000_020),
      Some(63_900_000_030),
    )
    == True
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  arrive_joined(h, account_id, "call-one", another_delivery(), 63_900_000_020)
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  finish(h)
}

/// A caller a timeout branch sent straight back into the queue, whose new
/// member overtook the cancel of the passage they left: the new member is
/// held and handed on in place of the old one, and the cancel, about the
/// passage before it, settles nothing and tells the dispatcher nothing.
/// The dispatcher keeps the new join (`arrival.kept_place`), so the cancel
/// of the new passage, when it comes, is the one that takes the caller out.
pub fn a_loop_back_member_ahead_of_its_cancel_is_the_passage_held_test() {
  let h = take(83, [], Settles, Stops)
  arrive_joined(h, account_id, "call-one", delivery(), 63_900_000_000)
  assert drain(h.starts) == [account_id]
  arrive_joined(h, account_id, "call-one", another_delivery(), 63_900_000_040)
  // The first passage's delivery, replaced.
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == ["call-one"]

  assert cancel_passage(
      h,
      account_id,
      "call-one",
      queue_id,
      Some(63_900_000_000),
      Some(63_900_000_040),
    )
    == False
  assert drain(h.acks) == []
  assert drain(h.lefts) == []
  assert holding(h) == ["call-one"]

  assert cancel_passage(
      h,
      account_id,
      "call-one",
      queue_id,
      Some(63_900_000_040),
      Some(63_900_000_070),
    )
    == True
  assert list.length(drain(h.acks)) == 1
  assert holding(h) == []
  finish(h)
}

// --- A member in a shard its account is not in -----------------------------

/// The callflow works the shard out with its own
/// count, and a node that counts differently puts a member on a queue whose
/// holder does not dispatch its account. The holder checks. A member whose
/// account is not in this shard under this node's count is held -- the
/// caller's cancel comes to the same queue and settles it, once -- and never
/// handed to a dispatcher, which could be ringing agents beside the node
/// that really dispatches the account.
pub fn a_member_of_another_shard_is_held_and_not_dispatched_test() {
  let ours = shards.of_account(account_id, 64)
  let theirs = { ours + 1 } % 64
  let h = take_counting(theirs, [], Ignores, Stops, Some(64))
  arrive(h, "call-one")
  assert drain(h.starts) == []
  assert drain(h.acks) == []
  assert holding(h) == ["call-one"]
  assert cancel(h, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  finish(h)

  // The account's own shard dispatches it.
  let h = take_counting(ours, [], Ignores, Stops, Some(64))
  arrive(h, "call-two")
  assert drain(h.starts) == [account_id]
  finish(h)
}

// --- Giving a shard up -----------------------------------------------------

/// A shard that agrees to be given up ends its own tree: it does not rely on
/// whoever asked to come back and release it.
pub fn a_shard_given_up_ends_its_own_tree_test() {
  let h = take(71, [], Ignores, Stops)
  arrive(h, "call-one")
  let ours = dispatcher_pid(h)
  // Gone again, so that nobody is waiting: the account's dispatcher stays.
  assert cancel(h, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  assert process.call(h.to, 5000, shard.GiveUp) == True
  assert gone_within(h.tree, 50) == True
  assert process.is_alive(ours) == False
  assert shard.holds(71) == False
  // Nothing more was settled by the give-up.
  assert drain(h.acks) == []
}

/// What a shard given up holds and does not dispatch -- a member whose
/// account is another shard's under this node's count -- goes back with
/// the channel unsettled, for the node that takes the shard next.
pub fn a_shard_given_up_settles_nothing_it_holds_test() {
  let ours = shards.of_account(account_id, 64)
  let theirs = { ours + 1 } % 64
  let h = take_counting(theirs, [], Ignores, Stops, Some(64))
  arrive(h, "call-one")
  assert holding(h) == ["call-one"]
  assert process.call(h.to, 5000, shard.GiveUp) == True
  assert gone_within(h.tree, 50) == True
  assert shard.holds(theirs) == False
  assert drain(h.acks) == []
}

/// The owner gave up waiting for the answer and read
/// it as a refusal, the actor answered later anyway, stopped every
/// dispatcher -- and nobody released the tree, so the shard stayed held
/// here with nobody dispatching it, and the next caller started a
/// dispatcher again. Here nobody waits for the answer at all, and a caller
/// arrives behind the question: the shard hands them to nobody, holds them,
/// and ends its tree by itself.
pub fn a_shard_given_up_with_nobody_listening_still_goes_test() {
  let h = take(72, [], Ignores, Stops)
  arrive(h, "call-one")
  assert drain(h.starts) == [account_id]
  // Gone again, so that nobody is waiting: the account's dispatcher stays.
  assert cancel(h, "call-one") == True
  assert list.length(drain(h.acks)) == 1
  process.send(h.to, shard.GiveUp(process.new_subject()))
  let message = member_call(other_account, "call-two")
  let _ =
    ask.call(h.to, 1000, shard.Arrived(
      member.decode(message),
      message,
      delivery(),
      _,
    ))
  assert gone_within(h.tree, 50) == True
  assert drain(h.starts) == []
  assert drain(h.acks) == []
}

/// Through the placement's door: `give_up` answers, and the tree is gone
/// when it does.
pub fn give_up_leaves_nothing_behind_test() {
  let h = take(73, [], Ignores, Stops)
  arrive(h, "call-one")
  assert cancel(h, "call-one") == True
  assert shard.give_up(73) == True
  assert process.is_alive(h.tree) == False
  assert shard.tree(73) == Error(Nil)
}

/// A caller who is only waiting moves with the shard: their member goes
/// back to the broker unsettled, and the node the shard is handed to has
/// them redelivered and reads their record. Holding the shard for them used
/// to mean a busy shard never moved at all.
pub fn a_shard_with_a_caller_waiting_is_given_up_test() {
  let h = take(82, [], Ignores, Stops)
  arrive(h, "call-one")
  assert shard.give_up(82) == True
  assert process.is_alive(h.tree) == False
  assert drain(h.acks) == []
}

/// An agent being rung no longer keeps a shard where it is: the node taking
/// it finds the ring on the switch and takes it on, so the shard goes with
/// the caller's member unsettled, as a waiting caller's does.
pub fn a_shard_with_an_agent_ringing_is_given_up_test() {
  let h = take(83, [Rings], Settles, Stops)
  arrive(h, "call-one")
  assert shard.give_up(83) == True
  assert process.is_alive(h.tree) == False
  assert drain(h.acks) == []
}

fn member_call(account_id: String, call_id: String) -> doc.Value {
  doc.merge(
    doc.object([
      #("Event-Category", doc.String("callcenter")),
      #("Event-Name", doc.String("member_call")),
    ]),
    cf_callcenter.member_call(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      call: doc.object([#("Call-ID", doc.String(call_id))]),
      node: "kazoo_apps@one",
      joined: 63_900_000_000,
      priority: 0,
      caller_id_name: None,
      caller_id_number: None,
      shards: None,
      handoff_id: "handoff-1",
      branches: doc.object([]),
    ),
  )
}

/// Whether the process is gone within that many looks, twenty ms apart.
fn gone_within(pid: Pid, attempts: Int) -> Bool {
  case process.is_alive(pid), attempts {
    False, _ -> True
    True, 0 -> False
    True, _ -> {
      process.sleep(20)
      gone_within(pid, attempts - 1)
    }
  }
}

// --- A caller's actor saying they left -------------------------------------

/// A caller's actor says the caller left a queue: the shard settles their
/// member as their cancel did, and tells their dispatcher, once. A word for
/// a passage earlier than the one held settles nothing.
pub fn a_caller_who_left_is_settled_by_the_shard_test() {
  let h = take(88, [], Settles, Stops)
  arrive(h, "call-one")
  let _ = drain(h.starts)

  let left =
    types.Member(
      ..cluster.member("call-one", queue_id, 0, 63_900_000_000),
      account_id: account_id,
    )
  process.send(h.to, shard.CallerLeft(left, types.ExitKey))
  assert list.length(drain(h.acks)) == 1
  assert drain(h.lefts) == [#(account_id, "call-one")]
  assert holding(h) == []

  // The member of a later passage is not settled by a word about an
  // earlier one.
  arrive_joined(h, account_id, "call-two", delivery(), 63_900_000_100)
  let earlier =
    types.Member(
      ..cluster.member("call-two", queue_id, 0, 63_900_000_000),
      account_id: account_id,
    )
  process.send(h.to, shard.CallerLeft(earlier, types.Timeout))
  assert drain(h.acks) == []
  assert holding(h) == ["call-two"]
  finish(h)
}
