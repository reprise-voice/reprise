//// What a Gleam application has to tell the release about itself.
////
//// Three things an Erlang application gets from its `.app.src` and its top
//// supervisor, and a Gleam one cannot: that it is a Kazoo application, what
//// kind of database its own system database is, and when it started. Call
//// `mark_kazoo_app` first thing in the application's `start`, and return
//// what `start_tree` returns from it.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string
import kazoo/ffi

/// Tell `kapps_controller` this is one of its applications, the way every
/// Erlang application's `.app.src` does with `{is_kazoo_app, true}`, and
/// register `system_db` with the data layer as a system database.
///
/// The Gleam compiler owns the generated `.app` file and has no way to put an
/// `env` entry in it, so the application sets it on itself while starting,
/// before `kapps_controller:start_app/1` reads it back.
///
/// `system_db` is the application's own database, named after it by
/// convention. `None` for an application that has none.
pub fn mark_kazoo_app(app: String, system_db: Option(String)) -> Nil {
  ffi.mark_kazoo_app(app, option.unwrap(system_db, ""))
}

/// Start the application's supervision tree under a root that records when
/// it started, and return that root: it is what the application's `start`
/// should return.
///
/// `kz_nodes` reads an application's start time -- the `Run Time` column of
/// `kz_nodes status`, and what `whapp_oldest_node` ranks by -- from the
/// process `start` returned. An Erlang application's top supervisor writes
/// it in its `init`; a Gleam supervisor's `init` is the library's and writes
/// nothing, so the tree goes under this root instead. The root restarts
/// nothing: when the tree gives up, so does the application, as before.
///
/// `start` is what starts the tree, `callcenter.start(kz, count)` say, and
/// its error comes back rendered, the way `start` reports it to OTP.
pub fn start_tree(
  start: fn() -> Result(actor.Started(data), actor.StartError),
) -> Result(Pid, String) {
  case do_start_tree(start) {
    Ok(root) -> Ok(root)
    Error(reason) -> Error(string.inspect(reason))
  }
}

@external(erlang, "kazoo_gleam_root_sup", "start_link")
fn do_start_tree(
  start: fn() -> Result(actor.Started(data), actor.StartError),
) -> Result(Pid, Dynamic)

/// When the tree under that root started, in the gregorian seconds
/// `kz_nodes` counts in. `None` for a process that is not a root
/// `start_tree` made.
@external(erlang, "kazoo_gleam_root_sup", "started_at")
pub fn started_at(root: Pid) -> Option(Int)
