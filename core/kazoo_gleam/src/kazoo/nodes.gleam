//// The cluster, from this node.
////
//// `kz_nodes` is the table every node's heartbeat writes to, and this is the
//// part of it an application needs to make a decision: is that node still
//// there, how many of us are running, who else has this role. A listener
//// that asked for `notify_nodes` hears about the changes as they happen; this
//// is the same picture, asked for.
////
//// A node with no release around it has no cluster: nothing is up, nobody is
//// running anything, and the lists are empty.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list

/// A node on the cluster, as `kz_node:to_json/1` describes it.
pub type Node {
  Node(
    name: String,
    zone: String,
    /// The applications running on it: `ecallmgr`, `callcenter`, and so on.
    kapps: List(String),
    /// The media servers it is talking to.
    media_servers: List(String),
  )
}

/// Whether that node is heartbeating.
@external(erlang, "kazoo_gleam_nodes_ffi", "is_up")
pub fn is_up(node: String) -> Bool

/// The zone this node is in, as a `Node`'s `zone` spells it: empty where
/// there is no cluster.
@external(erlang, "kazoo_gleam_nodes_ffi", "local_zone")
pub fn local_zone() -> String

/// How many nodes are running that application.
@external(erlang, "kazoo_gleam_nodes_ffi", "whapp_count")
pub fn whapp_count(app: String) -> Int

/// Every node on the cluster.
pub fn nodes() -> List(Node) {
  do_nodes() |> list.map(from_dynamic)
}

/// Every node that has claimed that role.
pub fn with_role(role: String) -> List(Node) {
  do_with_role(role) |> list.map(from_dynamic)
}

/// A node as it arrives from Erlang. Total: a field that is not there is
/// empty, because a node describing itself oddly is not worth a crash in
/// whoever asked.
pub fn from_dynamic(value: Dynamic) -> Node {
  case decode.run(value, decoder()) {
    Ok(node) -> node
    Error(_) -> Node(name: "", zone: "", kapps: [], media_servers: [])
  }
}

pub fn decoder() -> Decoder(Node) {
  use name <- decode.optional_field("node", "", decode.string)
  use zone <- decode.optional_field("zone", "", decode.string)
  use kapps <- decode.optional_field("kapps", [], decode.list(decode.string))
  use media_servers <- decode.optional_field(
    "media_servers",
    [],
    decode.list(decode.string),
  )
  decode.success(Node(
    name: name,
    zone: zone,
    kapps: kapps,
    media_servers: media_servers,
  ))
}

@external(erlang, "kazoo_gleam_nodes_ffi", "nodes")
fn do_nodes() -> List(Dynamic)

@external(erlang, "kazoo_gleam_nodes_ffi", "with_role")
fn do_with_role(role: String) -> List(Dynamic)
