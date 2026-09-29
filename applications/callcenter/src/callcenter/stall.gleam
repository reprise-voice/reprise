//// Whether this node has stood still, and so whether what one of its shards
//// started before that may still act for the shard.
////
//// **What a stall costs.** A node whose VM stops -- frozen, or starved of
//// the CPU by its host -- loses its shards once the broker has gone long
//// enough without a frame from it. LavinMQ drops a client after 15 seconds
//// of nothing, and an idle connection sends a frame only about every 10
//// (`heartbeat` is 10 seconds, and the sender skips a beat after its own),
//// so that can be as little as five seconds into the stop; the lab of
//// 2026-09-28, `e2e-260927-cca10`, saw a frozen node dropped after 15 to 16.
//// The broker hands every member the node held unacked to the next
//// consumer, and another node takes the shards over and every caller in
//// them. When the node moves again, nothing it runs knows that yet. Its
//// socket still holds what the broker sent before it gave up -- the
//// callers' events among it -- and the connection reads all of that before
//// it reads that it is closed. So for a moment every process of every
//// shard the node held goes on as the holder. In that lab a call actor
//// thawed after its agent's blind transfer took the caller for transferred,
//// and its dispatcher wrote the passage's record and published
//// `member_result` for a call the next holder had already closed.
////
//// **The watch.** One process notes the time every `tick_ms`, at high
//// priority, so that it is among the first to run when the node moves
//// again. A gap of more than `stall_ms` between two notes is a stall, and
//// the note that saw it is the node's last stall. A process of a shard is
//// fenced (`fresh` is `False`) when it started before the last stall: it
//// may not act for the shard any more, and drops whatever it is handed
//// until its tree ends. So is every process while the last note is more
//// than `stall_ms` old: the node is moving again and the watch has not run
//// yet, which is a stall it has not noted. When it notes one it tells the
//// node (`stood_still`) and then logs it, and every shard's tree ends and
//// is started again, fresh: its listener takes the shard back if it is
//// still this node's, and every caller in it is found out about again; or
//// it finds the shard somebody else's, and ends.
////
//// **What it catches.** Only the whole VM standing still. A VM that runs
//// but is too busy to answer the broker -- its normal work backed up behind
//// something -- starves the heartbeat and the socket's reader and not this
//// watch, which runs ahead of them, and it can lose its shards with no
//// stall noted. A VM its host pauses may show no gap either: a guest's
//// monotonic clock can be held across the pause. The lab's freeze stops
//// the VM's process, whose clock runs on.
////
//// **What a stall costs when nothing was lost.** A stall shorter than the
//// broker's patience, or a watch kept waiting by the node itself, restarts
//// every shard all the same: every member goes back to the broker and is
//// handed out again, every caller is found out about again (their record
//// read, the switches asked, their channel probed), the next sweep scans
//// every account for orphans as it does for a shard newly taken, and each
//// shard's end is a crash report. A caller half way out of the queue is
//// handed back by the actor that finds them, since their member is only
//// settled once they are. A node that runs no watch -- no broker, the test
//// suite -- is never fenced, and nor is one whose watch has ended and not
//// been started again, which would otherwise fence every shard for good.
////
//// **What it does not stop.** A message a process was handling when the VM
//// stopped is finished when it moves again. What was already handed on --
//// to the record writer, or to the node's AMQP workers by a dispatcher --
//// goes out: it was decided while the node held the shard.

import callcenter/system
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import kazoo/util

/// How often the watch notes the time.
pub const tick_ms = 1000

/// The longest gap between two notes that is not a stall: three ticks.
///
/// The broker's patience is shorter than the heartbeat suggests. LavinMQ
/// drops a client it has heard nothing from for 15 seconds, and an idle
/// connection sends a frame only about every 10: the heartbeat sender looks
/// every half heartbeat and skips a beat when its own last one is what it
/// sees. So a node that stops just before a frame was due can be dropped
/// about five seconds in, and three leaves room for the backlog a node
/// works through as it moves again. A watch at high priority kept waiting
/// three seconds is itself a node in trouble.
pub const stall_ms = 3000

/// What the watch is sent: time to note the time.
pub type Message {
  Tick
}

/// What the watch reaches outside itself.
pub type Io {
  Io(
    /// The VM's monotonic milliseconds.
    now_ms: fn() -> Int,
    /// Keep a note: the time, and whether it is the end of a stall.
    note: fn(Int, Bool) -> Nil,
    /// Told a stall has ended, with how long it was, after it is noted.
    stood_still: fn(Int) -> Nil,
    /// How often to note the time: `tick_ms` on a node.
    tick_ms: Int,
  )
}

type State {
  State(io: Io, self: Subject(Message), last: Int)
}

/// The node's watch, for its supervision tree, telling `stood_still` of a
/// stall once it is noted.
pub fn supervised(stood_still: fn(Int) -> Nil) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    start(Io(
      now_ms: now_ms,
      note: note,
      stood_still: stood_still,
      tick_ms: tick_ms,
    ))
  })
  |> supervision.map_data(fn(_subject) { Nil })
}

/// Start a watch: the node's, registered, or a test's with its own `Io`.
pub fn start(
  io: Io,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    high_priority()
    let now = io.now_ms()
    // The first note is not the end of a stall, whenever the last one was:
    // a watch started again after a crash has not been standing still.
    io.note(now, False)
    process.send_after(self, io.tick_ms, Tick)
    actor.initialised(State(io: io, self: self, last: now))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.named(util.name("callcenter_stall"))
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> {
      let now = state.io.now_ms()
      let gap = now - state.last
      let stalled = stood_still(state.last, now)
      state.io.note(now, stalled)
      case stalled {
        // The shards are told before anything is logged: on a node that has
        // just moved again the logger may be busy, and waiting on it would
        // keep the shards acting in the meantime.
        True -> {
          state.io.stood_still(gap)
          system.log(
            "this node stood still for "
            <> int.to_string(gap)
            <> " ms: its shards are fenced and start again",
          )
        }
        False -> Nil
      }
      process.send_after(state.self, state.io.tick_ms, Tick)
      actor.continue(State(..state, last: now))
    }
  }
}

/// Whether the gap between a note at `last` and one at `now` is a stall.
pub fn stood_still(last: Int, now: Int) -> Bool {
  now - last > stall_ms
}

/// Whether a process of a shard started at `since`, the VM's monotonic
/// milliseconds, may still act for the shard: no stall has been noted since
/// it started, and the watch has noted the time lately. Always, on a node
/// with no watch running.
pub fn fresh(since: Int) -> Bool {
  case watch() {
    Error(Nil) -> True
    Ok(#(last, stalled)) -> fresh_at(since, now_ms(), last, stalled)
  }
}

/// `fresh`, given the time, the watch's last note and its last stall.
pub fn fresh_at(since: Int, now: Int, last: Int, stalled: Int) -> Bool {
  !stood_still(last, now) && since > stalled
}

/// The VM's monotonic milliseconds, which `since` and the notes are in.
@external(erlang, "callcenter_ffi", "monotonic_ms")
pub fn now_ms() -> Int

@external(erlang, "callcenter_ffi", "stall_note")
fn note(now: Int, stalled: Bool) -> Nil

/// The watch's last note and last stall, while it runs.
@external(erlang, "callcenter_ffi", "stall_watch")
fn watch() -> Result(#(Int, Int), Nil)

@external(erlang, "callcenter_ffi", "high_priority")
fn high_priority() -> Nil
