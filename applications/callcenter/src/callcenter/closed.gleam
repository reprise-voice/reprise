//// The passages this node's dispatchers have closed lately, and how.
////
//// A dispatcher closes an answered call by casting the end to the records
//// writer, and the view of open records stops naming the passage only once
//// that write has landed -- or never, when the write was dropped: a 409, a
//// datastore that was down. The sweep reads that view. Without this it takes
//// a passage this node finished a moment ago for one a dead node left behind
//// and closes it again: a second `member_result`, a second `agent_wrapup`,
//// the talk time counted twice and a second wrap-up for the agent.
////
//// So every close is noted here, by passage, in one table the whole node
//// shares -- a dispatcher that stopped or crashed since takes nothing with
//// it -- and an orphan the sweep hands a dispatcher is looked up before it
//// is adopted or closed. One found is not closed again. Its end is written
//// again, with the result and the second the close had, and nothing else is
//// done: that write changes nothing on a document that already has an end
//// (`records.closed`), and it is what finally closes one whose first write
//// was lost.
////
//// Entries are kept `keep_s`. The sweep forgets older ones on every pass,
//// so the table's size is the calls this node closes in that long.
////
//// The table is owned by a process of its own (`supervised`), started
//// before the sweep and the dispatchers and doing nothing else, and not by
//// the sweep: an ETS table goes with its owner, and a sweep that crashed
//// took every note with it. Started again, it scanned every shard held
//// with nothing to look a passage up in, and a passage whose end write had
//// been dropped was closed a second time.
////
//// What it cannot see is another node's close. A shard handed over in the
//// moment between a dispatcher's close and its write is what the sweep's
//// read of the document just before a close is for.

import callcenter/records
import callcenter/system
import callcenter/types.{type EndResult, type Member}
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision
import kazoo/modb
import kazoo/util

/// How long a close is remembered: several backstop scans, so that a
/// record whose end was never written is found here every time the sweep
/// comes back to it until the end is written.
pub const keep_s = 3600

/// How a passage was closed.
pub type Closed {
  Closed(result: EndResult, at: Int)
}

/// The table's owner, under the application's supervisor and ahead of the
/// sweep and the dispatchers that use the table.
pub fn supervised() -> supervision.ChildSpecification(Nil) {
  supervision.worker(start_owner)
  |> supervision.map_data(fn(_owner) { Nil })
}

/// Start a process that makes the table and owns it, and does nothing else:
/// nothing is sent to it, so nothing it does can take the notes down. A
/// node with no owner notes nothing and finds nothing.
pub fn start_owner() -> Result(actor.Started(Subject(Nil)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    create()
    actor.initialised(Nil)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, _nothing) { actor.continue(state) })
  |> actor.named(owner_name())
  |> actor.start
}

/// The table owner's registered name, one per node.
pub fn owner_name() -> Name(Nil) {
  util.name("callcenter_closed_passages")
}

/// Make the table, owned by the calling process, for a test.
pub fn start() -> Nil {
  create()
}

/// Drop the table, for a test that made one.
pub fn stop() -> Nil {
  delete()
}

/// A dispatcher closed a passage.
pub fn note(member: Member, result: EndResult, at: Int) -> Nil {
  put(records.passage_id(member), Closed(result: result, at: at), modb.now())
}

/// How a passage was closed here, if it was within `keep_s`.
pub fn find(member: Member) -> Result(Closed, Nil) {
  lookup(records.passage_id(member))
}

/// Whether an orphan the sweep found is a passage this node already closed.
/// When it is, its end is written again, and that is all.
pub fn again(member: Member) -> Bool {
  case find(member) {
    Error(Nil) -> False
    Ok(closed) -> {
      system.log(
        "call "
        <> member.call_id
        <> " in queue "
        <> member.queue_id
        <> " was closed here already: writing its end again and nothing else",
      )
      records.ended(member, closed.result, closed.at)
      True
    }
  }
}

/// Forget what was noted more than `keep_s` ago.
pub fn forget_old() -> Int {
  forget_before(modb.now() - keep_s)
}

@external(erlang, "callcenter_closed_ffi", "create")
fn create() -> Nil

@external(erlang, "callcenter_closed_ffi", "delete")
fn delete() -> Nil

@external(erlang, "callcenter_closed_ffi", "put")
fn put(id: String, closed: Closed, at: Int) -> Nil

@external(erlang, "callcenter_closed_ffi", "find")
fn lookup(id: String) -> Result(Closed, Nil)

@external(erlang, "callcenter_closed_ffi", "forget_before")
pub fn forget_before(second: Int) -> Int
