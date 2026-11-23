//// The root an application's tree starts under.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/string
import kazoo/app

/// The root records when it started, in gregorian seconds, on itself: that
/// is the process `kz_nodes` will ask.
pub fn start_tree_records_when_it_started_test() {
  let assert Ok(root) =
    app.start_tree(fn() {
      supervisor.new(supervisor.OneForOne) |> supervisor.start
    })
  assert process.is_alive(root)
  let assert Some(started) = app.started_at(root)
  // 2026 is around 63.9e9 gregorian seconds; anything in the epoch's units
  // (1.7e9) would be the wrong clock.
  assert started > 63_000_000_000
  assert app.started_at(process.self()) == None
}

/// A tree that does not start is reported, not swallowed: the reason is in
/// the text the application hands back to OTP. The root exits with that
/// reason as well, at whoever started it; in the release that is the
/// application master, which traps exits, and here it is the test.
pub fn start_tree_reports_a_tree_that_did_not_start_test() {
  process.trap_exits(True)
  let assert Error(reason) =
    app.start_tree(fn() { Error(actor.InitFailed("no broker in reach")) })
  process.trap_exits(False)
  assert string.contains(reason, "no broker in reach")
}
