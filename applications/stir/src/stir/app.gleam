//// The OTP application callbacks.
////
//// `gleam.toml` names this module as `application_start_module`, so the
//// generated stir.app carries `{mod, {stir@app, []}}` and
//// `application:ensure_all_started(stir)` -- which is what
//// `kapps_controller:start_app/1` calls -- lands here.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import kazoo/app as kazoo_app
import kazoo/crossbar
import kazoo/kazoo.{type Kazoo}
import stir
import stir/db
import stir/system
import stir/views

pub fn start(
  _start_type: Dynamic,
  _start_args: Dynamic,
) -> Result(Pid, String) {
  system.mark_kazoo_app()
  // The API first: `crossbar.start_module` binds `cb_stir` on this node and
  // adds it to the modules Crossbar autoloads, so the certificate URL
  // answers as soon as the application is up. A node without Crossbar
  // skips it.
  crossbar.start_module(api_module)
  let kz = system.live()
  case kazoo_app.start_tree(fn() { stir.start(kz) }) {
    Ok(root) -> {
      prepare(kz)
      Ok(root)
    }
    Error(reason) -> Error(reason)
  }
}

/// The Crossbar module this application serves `/v2/stir` with.
pub const api_module = "cb_stir"

pub fn stop(_state: Dynamic) -> Nil {
  Nil
}

/// The work a fresh node does beside the tree rather than inside its start:
/// create the application's database and register its views. Beside,
/// because a node that cannot reach the datastore still starts.
fn prepare(kz: Kazoo) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      let _ = db.ensure(kz)
      views.register()
    })
  Nil
}
