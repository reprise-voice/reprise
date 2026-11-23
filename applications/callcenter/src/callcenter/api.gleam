//// What the call center puts on the HTTP API, and the views it reads.
////
//// Crossbar modules are not started by being loaded: a module claims its
//// noun when `crossbar_maintenance:start_module/1` runs its `init/0`, which
//// also adds it to the modules the node autoloads after a restart. The
//// application does that for its own nouns while it starts, as `skel` does.
////
//// The views are registered here too, for the same reason and at the same
//// moment: `kapps_maintenance refresh` writes them into every account
//// database, and it can only write the ones an application has registered.

import callcenter/system

/// The nouns this application claims.
pub const modules = ["cb_queues", "cb_agents"]

/// Claim the nouns and register the views. Called once, while the
/// application starts, after `mark_kazoo_app`.
pub fn start() -> Nil {
  start_modules(modules)
  register_views()
  system.log("registered the queues and agents API")
}

fn start_modules(modules: List(String)) -> Nil {
  case modules {
    [] -> Nil
    [module, ..rest] -> {
      start_module(module)
      start_modules(rest)
    }
  }
}

@external(erlang, "kazoo_gleam_crossbar_ffi", "start_module")
fn start_module(module: String) -> Nil

/// Register every design document in `priv/couchdb/views`, and bind so that
/// a later `kapps_maintenance refresh` registers them again.
@external(erlang, "callcenter_api_ffi", "register_views")
fn register_views() -> Nil
