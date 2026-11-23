//// The OTP application callbacks.
////
//// `gleam.toml` names this module as `application_start_module`, so the
//// generated callcenter.app carries `{mod, {callcenter@app, []}}` and
//// `application:ensure_all_started(callcenter)` -- which is what
//// `kapps_controller:start_app/1` calls -- lands here.

import callcenter
import callcenter/api
import callcenter/db
import callcenter/shards
import callcenter/system
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import kazoo/app as kazoo_app
import kazoo/kazoo.{type Kazoo}

pub fn start(
  _start_type: Dynamic,
  _start_args: Dynamic,
) -> Result(Pid, String) {
  system.mark_kazoo_app()
  api.start()
  let _ = start_edges()
  let kz = system.live()
  // Read once, here, and kept as the node's for the callflow action too: two
  // nodes with different shard counts hash the same account into different
  // shards and both believe they own it. Changing the count is a restart of
  // the application everywhere.
  let count = shards.settle_count(kz)
  case kazoo_app.start_tree(fn() { callcenter.start(kz, count) }) {
    Ok(root) -> {
      prepare(kz, count)
      Ok(root)
    }
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "callcenter_ffi", "register_views")
fn register_views() -> Nil

pub fn stop(_state: Dynamic) -> Nil {
  Nil
}

/// The work a fresh node does beside the tree rather than inside its start:
/// create the application's database, and declare every shard's queues so
/// that a member published before any node has taken the shard is held by
/// the broker rather than dropped.
///
/// Beside, because both talk to something that may not be there. A node that
/// cannot reach the datastore or the broker still starts, and still takes up
/// shards when the broker comes back.
fn prepare(kz: Kazoo, count: Int) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      db.ensure(kz)
      // The application's CouchDB views, and a binding so that they are put
      // back on every refresh. `kapps_maintenance` is what creates a
      // database, so a view registered here reaches an account database that
      // does not exist yet as well as one that does.
      register_views()
      declare(count)
      agree(count)
    })
  Nil
}

/// Declare every shard's member queue, and say so once.
fn declare(count: Int) -> Nil {
  let wanted = list.map(shards.all(count), shards.member_queue)
  let declared = list.count(wanted, fn(queue) { is_declared(queue) })
  system.log(
    "declared "
    <> int.to_string(declared)
    <> " of "
    <> int.to_string(list.length(wanted))
    <> " shard queues",
  )
}

/// Ask the broker whether this node's count is the cluster's, and say what it
/// said. A disagreement is logged where it is found.
fn agree(count: Int) -> Nil {
  case shards.agreement(count) {
    shards.Agreed ->
      system.log(
        "this node's "
        <> int.to_string(count)
        <> " shards are the count "
        <> shards.marker_queue
        <> " holds",
      )
    shards.Disagreed(_reason) -> Nil
    shards.Unknown ->
      system.log(
        "could not ask the broker for the cluster's shard count yet: the"
        <> " placement asks again as it looks",
      )
  }
}

fn is_declared(queue: String) -> Bool {
  case shards.declare(queue) {
    Ok(_counts) -> True
    Error(_reason) -> False
  }
}

/// Register the blackhole and webhooks modules that relay this application's
/// events; skips hosts that are not in the release and returns at once.
@external(erlang, "callcenter_edges", "start")
fn start_edges() -> Dynamic
