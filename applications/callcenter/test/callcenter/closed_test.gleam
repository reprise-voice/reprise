//// A passage this node closed is closed once: the sweep finding its record
//// still open, because the end had not reached the document yet or never
//// did, does not close it a second time.

import callcenter/closed
import callcenter/reconcile
import callcenter/types.{Answered, CallerHangup, Completed, Ended}
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import kazoo/doc
import support/cluster

fn one_agent_queue() -> cluster.Cluster {
  let c =
    cluster.new(
      [
        #(
          "support",
          doc.object([
            #("pvt_type", doc.String("queue")),
            #("name", doc.String("Support")),
            #("strategy", doc.String("longest_idle")),
            #("agent_ring_timeout", doc.Int(20)),
            #("agent_wrapup_time", doc.Int(10)),
            #(
              "agents",
              doc.List([
                doc.object([
                  #("id", doc.String("ann")),
                  #("level", doc.Int(1)),
                  #("position", doc.Int(1)),
                ]),
              ]),
            ),
          ]),
        ),
      ],
      [
        #(
          "ann",
          doc.object([
            #("pvt_type", doc.String("user")),
            #("call_center", doc.object([])),
          ]),
        ),
      ],
    )
  cluster.agent_is(c, "ann", "available")
  c
}

/// What a close was is kept by passage: the same caller in another queue,
/// or joining again, is another passage and was not closed.
pub fn a_close_is_noted_by_passage_test() {
  closed.start()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  closed.note(member, Completed, cluster.start_of_time + 30)

  assert closed.find(member)
    == Ok(closed.Closed(Completed, cluster.start_of_time + 30))
  assert closed.find(cluster.member(
      "call-one",
      "sales",
      0,
      cluster.start_of_time,
    ))
    == Error(Nil)
  assert closed.find(cluster.member(
      "call-one",
      "support",
      0,
      cluster.start_of_time + 60,
    ))
    == Error(Nil)
  closed.stop()
}

/// The sweep forgets what is older than it keeps, and nothing newer.
pub fn old_closes_are_forgotten_test() {
  closed.start()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  closed.note(member, Completed, cluster.start_of_time + 30)

  assert closed.forget_old() == 0
  assert closed.find(member) != Error(Nil)
  // Everything noted before a second far in the future.
  assert closed.forget_before(999_999_999_999) == 1
  assert closed.find(member) == Error(Nil)
  closed.stop()
}

/// A node with no table owner has no table: a dispatcher's close notes
/// nothing and crashes over nothing, and nothing is found.
pub fn without_the_table_nothing_is_kept_test() {
  // The application's tree, which the test run starts, has one.
  closed.stop()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  closed.note(member, Completed, cluster.start_of_time + 30)
  assert closed.find(member) == Error(Nil)
  assert closed.again(member) == False
  assert closed.forget_old() == 0
}

/// The table was the sweep's own, made as it started,
/// and went with it. A sweep that crashed and was started again had nothing
/// to look a passage up in, and closed again a passage whose end write had
/// been dropped. The table has an owner of its own now, and the sweep's
/// restart keeps every note.
///
/// Against the application's own tree, which the test run starts: the
/// sweep crashes and its supervisor starts it again, as on a node.
pub fn a_sweep_started_again_keeps_the_notes_test() {
  // The table as the tree's owner makes it: whatever an earlier test left
  // is dropped, and the owner started again makes it anew.
  closed.stop()
  crash_and_wait(fn() { process.named(closed.owner_name()) })
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  closed.note(member, Completed, cluster.start_of_time + 30)

  crash_and_wait(fn() { process.named(reconcile.name()) })
  assert closed.find(member)
    == Ok(closed.Closed(Completed, cluster.start_of_time + 30))
  closed.stop()
}

/// Kill a registered process of the application's tree and wait until its
/// supervisor has started another under the same name.
fn crash_and_wait(running: fn() -> Result(process.Pid, Nil)) -> Nil {
  let assert Ok(pid) = running()
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
  restarted(running, pid, 250)
}

fn restarted(
  running: fn() -> Result(process.Pid, Nil),
  was: process.Pid,
  attempts: Int,
) -> Nil {
  case running() {
    Ok(now) if now != was -> Nil
    _not_yet if attempts > 0 -> {
      process.sleep(20)
      restarted(running, was, attempts - 1)
    }
    _ -> panic as "not started again"
  }
}

/// Ann's call ends and her dispatcher closes it: a
/// wrap-up to 40. The backstop sweep then reads the record before the end
/// has reached it, finds the caller on no switch and hands it over as an
/// orphan. Closing it again would put Ann back in a wrap-up she has already
/// done, and the next caller would find nobody to ring.
pub fn a_call_closed_here_is_not_closed_again_test() {
  closed.start()
  let c = one_agent_queue()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  cluster.reply(c, "call-one", Ended(CallerHangup, cluster.start_of_time + 30))
  assert cluster.all_ringing(c) == []

  cluster.at(c, 42)
  cluster.orphaned(
    c,
    "call-one",
    "support",
    "ann",
    0,
    Some(cluster.start_of_time + 42),
  )
  assert cluster.all_ringing(c) == []

  cluster.at(c, 43)
  cluster.tick(c)
  cluster.arrive(c, "call-two", "support", 0, 43)
  assert cluster.ringing(c, "call-two") == ["ann"]
  closed.stop()
}

/// Without the note -- a node whose sweep is not running -- the same orphan
/// is closed as the sweep always closed one, which is what the note is for.
pub fn without_the_note_the_orphan_is_closed_test() {
  let c = one_agent_queue()
  cluster.at(c, 42)
  cluster.orphaned(
    c,
    "call-one",
    "support",
    "ann",
    0,
    Some(cluster.start_of_time + 42),
  )
  cluster.at(c, 43)
  cluster.tick(c)
  cluster.arrive(c, "call-two", "support", 0, 43)
  // Ann is wrapping up the call the orphan was.
  assert cluster.ringing(c, "call-two") == []
  assert list.contains(cluster.waiting(c), "call-two")
}
