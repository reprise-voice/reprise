//// The cluster, seen from a node that is not in one.

import gleam/dynamic.{type Dynamic}
import gleam/list
import kazoo/nodes

fn map(entries: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    list.map(entries, fn(entry) { #(dynamic.string(entry.0), entry.1) }),
  )
}

/// Nothing is up, nobody is running anything, and the lists are empty. An
/// application that asks about the cluster while it is being tested gets an
/// answer rather than an exception.
pub fn without_a_release_test() {
  assert nodes.is_up("kazoo_apps@one.example.test") == False
  assert nodes.nodes() == []
  assert nodes.whapp_count("callcenter") == 0
  assert nodes.with_role("dispatcher") == []
}

/// A node as `kz_node:to_json/1` describes it, with the fields this does not
/// name left where they are.
pub fn from_dynamic_test() {
  let node =
    map([
      #("node", dynamic.string("kazoo_apps@one.example.test")),
      #("zone", dynamic.string("local")),
      #(
        "kapps",
        dynamic.list([dynamic.string("ecallmgr"), dynamic.string("callcenter")]),
      ),
      #("media_servers", dynamic.list([dynamic.string("freeswitch@one")])),
      #("channels", dynamic.int(12)),
    ])

  assert nodes.from_dynamic(node)
    == nodes.Node(
      name: "kazoo_apps@one.example.test",
      zone: "local",
      kapps: ["ecallmgr", "callcenter"],
      media_servers: ["freeswitch@one"],
    )
}

/// A node that describes itself oddly is an empty node, not a crash in
/// whoever asked.
pub fn from_nothing_test() {
  assert nodes.from_dynamic(dynamic.string("kazoo_apps@one.example.test"))
    == nodes.Node(name: "", zone: "", kapps: [], media_servers: [])
  assert nodes.from_dynamic(map([]))
    == nodes.Node(name: "", zone: "", kapps: [], media_servers: [])
}
