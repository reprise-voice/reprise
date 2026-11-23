//// Registering the WebSocket and webhook modules with the applications that
//// host them.

import gleam/erlang/atom.{type Atom}

/// The application's start callback calls this. Off a node -- and on a node
/// whose release carries neither blackhole nor webhooks -- it has to return
/// rather than raise, or the application does not start at all.
pub fn start_without_the_platform_test() {
  assert start() == atom.create("ok")
}

/// Both edges, and the maintenance function on each host that loads them.
pub fn integrations_test() {
  assert integrations()
    == [
      #(
        atom.create("bh_callcenter"),
        atom.create("blackhole_maintenance"),
        atom.create("start_module"),
      ),
      #(
        atom.create("webhooks_callcenter"),
        atom.create("webhooks_maintenance"),
        atom.create("start_module"),
      ),
    ]
}

@external(erlang, "callcenter_edges", "start")
fn start() -> Atom

@external(erlang, "callcenter_edges", "integrations")
fn integrations() -> List(#(Atom, Atom, Atom))
