//// The shards, and the queues that carry them.
////
//// Accounts hash into a fixed number of shards. Each shard has one durable
//// queue on the broker, `callcenter.member.<shard>`, which holds the callers
//// waiting in that shard's queues; whoever consumes it, exclusively,
//// dispatches for the shard. It is declared by every node as it starts, so a
//// member published before any node has taken the shard is held rather than
//// dropped.
////
//// The count is read once per node: when the application starts, or, on a
//// node where the callflow action runs without it, on the first call. A
//// running node never changes it. Changing it means restarting the
//// application on every node at once: two nodes with different counts hash
//// the same account into different shards and both think they own it.
////
//// So a disagreement is made loud. The broker holds the cluster's count on a
//// queue of its own, `callcenter.shards`, declared by every node with the
//// count it uses; the first declaration sets it, and a node whose count
//// differs is refused the declaration (`agreement`). Such a node takes no
//// shard and lets no caller join.

import callcenter/system
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import kazoo/kazoo.{type Kazoo}
import kazoo/listener.{type Listener, Infinity}

/// `system_config/callcenter.shards`, when nothing says otherwise.
pub const default_count = 64

/// How many shards this node works with: the count it settled on when the
/// application started, or, where it has not started, the first time it was
/// asked. Read from the configuration once and never again.
pub fn count(kz: Kazoo) -> Int {
  case node_count() {
    Some(count) -> count
    None -> settle_count(kz)
  }
}

/// Read the configured count and make it this node's, whatever it was
/// before. What the application's start does, and nothing else.
pub fn settle_count(kz: Kazoo) -> Int {
  let count = configured(kz)
  put_node_term(count_key, count)
  count
}

/// The count this node settled on, if it has.
pub fn node_count() -> Option(Int) {
  case node_term(count_key) {
    Ok(count) -> Some(count)
    Error(Nil) -> None
  }
}

/// The count the configuration says, now.
pub fn configured(kz: Kazoo) -> Int {
  clamp(kz.config.get_int("shards", default_count))
}

const count_key = "shards"

/// A configured count that could be used. Zero shards is no dispatch at all
/// and a negative count is not a number of anything, so both read as one.
pub fn clamp(configured: Int) -> Int {
  case configured < 1 {
    True -> 1
    False -> configured
  }
}

/// Every shard, in order.
pub fn all(count: Int) -> List(Int) {
  ascending(count - 1, [])
}

fn ascending(shard: Int, sorted: List(Int)) -> List(Int) {
  case shard < 0 {
    True -> sorted
    False -> ascending(shard - 1, [shard, ..sorted])
  }
}

/// The shard an account belongs to.
///
/// `erlang:phash2(AccountId, Shards)`, applied by the callflow action to
/// address a member and by the node holding the shard to know that the
/// message is its own. This is the one place it is computed, and a count
/// that could not be used is read as `clamp` reads it.
pub fn of_account(account_id: String, count: Int) -> Int {
  shard_for(account_id, clamp(count))
}

/// Which member dispatches each shard: rendezvous hashing with bounded loads.
///
/// Every member ranks every shard by `erlang:phash2({Member, Shard})`, and
/// the shards are dealt in order, each to the highest ranked member that has
/// fewer than `ceil(shards / members)` already. It is a function of the
/// count and the set of members and nothing else, so every node that sees
/// the same members computes the same answer without asking anybody, and
/// no member has more than its share: 32 and 32 of 64 on two nodes, and no
/// more than 22 each on three.
///
/// A member leaving moves its own shards, each to the next member in that
/// shard's ranking, and little else; a member joining takes about its share
/// from the others. Dealing by position in a sorted list instead would move
/// most shards between members that never changed.
///
/// No members is no assignment. The order the members are given in does not
/// matter, and neither does a name given twice.
pub fn assign(count: Int, members: List(String)) -> Dict(Int, String) {
  let members = members |> list.unique |> list.sort(string.compare)
  case list.length(members) {
    0 -> dict.new()
    size -> {
      let count = clamp(count)
      let cap = { count + size - 1 } / size
      let #(owners, _loads) =
        list.fold(all(count), #(dict.new(), dict.new()), fn(dealt, shard) {
          let #(owners, loads) = dealt
          let owner =
            ranking(shard, members)
            |> list.find(fn(member) { load(loads, member) < cap })
            // Unreachable: the caps add up to at least the count.
            |> result.unwrap(first_member(members))
          #(
            dict.insert(owners, shard, owner),
            dict.insert(loads, owner, load(loads, owner) + 1),
          )
        })
      owners
    }
  }
}

/// The members in the order they would have the shard, highest first.
pub fn ranking(shard: Int, members: List(String)) -> List(String) {
  members
  |> list.map(fn(member) { #(rendezvous_weight(member, shard), member) })
  |> list.sort(fn(a, b) {
    case int.compare(b.0, a.0) {
      order.Eq -> string.compare(a.1, b.1)
      other -> other
    }
  })
  |> list.map(fn(weighed) { weighed.1 })
}

fn load(loads: Dict(String, Int), member: String) -> Int {
  dict.get(loads, member) |> result.unwrap(0)
}

fn first_member(members: List(String)) -> String {
  list.first(members) |> result.unwrap("")
}

@external(erlang, "callcenter_ffi", "rendezvous_weight")
fn rendezvous_weight(member: String, shard: Int) -> Int

/// The queue holding the shard's waiting callers, as `kapi_callcenter`
/// spells it for the member it publishes there.
@external(erlang, "kapi_callcenter", "member_queue")
pub fn member_queue(shard: Int) -> String

/// How a member queue is declared, by the listener that consumes it and by
/// every node that declares it at start: durable, shared, and with neither
/// of the limits `kz_amqp_util` would otherwise give it, because a hundredth
/// waiting caller must not be dropped. Two declarations that differ are
/// refused by the broker with `PRECONDITION_FAILED`, so there is one.
pub fn declared(listener: Listener, queue: String) -> Listener {
  listener.queue(
    listener,
    name: queue,
    durable: True,
    exclusive: False,
    auto_delete: False,
    ttl: Infinity,
    max_length: Infinity,
  )
}

@external(erlang, "callcenter_ffi", "shard_for")
fn shard_for(account_id: String, count: Int) -> Int

/// Declare one queue on the broker and answer what is on it: the number of
/// messages waiting and the number of consumers.
///
/// A message that has been delivered and not acked is on neither count, so a
/// message count of zero only means the queue is unclaimed when the consumer
/// count is zero too.
pub fn declare(queue: String) -> Result(#(Int, Int), String) {
  declare_described(declared(listener.new(), queue))
}

/// Declare the queue a listener describes, exactly as the listener would, and
/// answer the same two counts. A declaration that differs from the one the
/// queue was made with is refused, so whoever asks after a queue asks with
/// its consumer's own description.
pub fn declare_described(described: Listener) -> Result(#(Int, Int), String) {
  case dict.get(listener.to_spec(described), "queue") {
    Ok(spec) -> declare_queue(spec)
    Error(Nil) -> Error("no queue in the listener spec")
  }
}

@external(erlang, "callcenter_ffi", "declare_queue")
fn declare_queue(spec: Dynamic) -> Result(#(Int, Int), String)

// --- The cluster's count ----------------------------------------------------

/// The queue that carries the cluster's shard count.
pub const marker_queue = "callcenter.shards"

/// What the broker said about this node's count.
pub type Agreement {
  /// The count this node uses is the one the cluster's queue was declared
  /// with.
  Agreed
  /// It is not: the broker refused the declaration. The reason is the
  /// broker's.
  Disagreed(reason: String)
  /// Nothing is known yet: no broker, or not asked.
  Unknown
}

/// Whether this node's count is the cluster's.
///
/// Asked of the broker once and remembered for the life of the node when it
/// agrees. A disagreement is asked again at most once a minute, so that the
/// operator's fix -- the queue deleted and the nodes restarted -- is seen,
/// and so that a placement asking every tick is one refusal a minute and one
/// error in the log, not one every five seconds. An answer
/// the broker did not give is asked again next time.
pub fn agreement(count: Int) -> Agreement {
  case node_term(agreement_key) {
    Ok(Verdict(of: of, agreed: True, ..)) if of == count -> Agreed
    Ok(Verdict(of: of, agreed: False, at: at, reason: reason)) if of == count ->
      case monotonic_ms() - at < recheck_ms {
        True -> Disagreed(reason)
        False -> ask_broker(count)
      }
    _unknown -> ask_broker(count)
  }
}

/// What this node knows about its count without asking anybody: what
/// `agreement` last found.
pub fn known_agreement(count: Int) -> Agreement {
  case node_term(agreement_key) {
    Ok(Verdict(of: of, agreed: True, ..)) if of == count -> Agreed
    Ok(Verdict(of: of, agreed: False, reason: reason, ..)) if of == count ->
      Disagreed(reason)
    _unknown -> Unknown
  }
}

/// What the broker last said about a count, and when.
type Verdict {
  Verdict(of: Int, agreed: Bool, at: Int, reason: String)
}

fn ask_broker(count: Int) -> Agreement {
  case declare_marker(marker_queue, count) {
    Ok(Nil) -> {
      put_node_term(
        agreement_key,
        Verdict(of: count, agreed: True, at: monotonic_ms(), reason: ""),
      )
      Agreed
    }
    Error(#(Mismatch, refusal)) -> {
      let reason =
        "this node counts "
        <> int.to_string(count)
        <> " shards and the broker's "
        <> marker_queue
        <> " was declared with another count: "
        // One line: `sup callcenter_maintenance status` prints it after
        // `shard count:`, and the broker's refusal is a term printed over
        // several.
        <> one_line(refusal)
      put_node_term(
        agreement_key,
        Verdict(of: count, agreed: False, at: monotonic_ms(), reason: reason),
      )
      system.log_error(
        reason
        <> ": this node takes no shard and lets no caller join until every"
        <> " node counts the same",
      )
      Disagreed(reason)
    }
    Error(#(Unreachable, _reason)) -> Unknown
  }
}

fn one_line(text: String) -> String {
  text
  |> string.replace("\r", " ")
  |> string.replace("\n", " ")
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
  |> string.join(" ")
}

const agreement_key = "shards_agreed"

const recheck_ms = 60_000

/// Why the broker refused the declaration, as the FFI spells it.
pub type MarkerFailure {
  Mismatch
  Unreachable
}

@external(erlang, "callcenter_ffi", "declare_marker")
fn declare_marker(
  queue: String,
  count: Int,
) -> Result(Nil, #(MarkerFailure, String))

@external(erlang, "callcenter_ffi", "node_term")
fn node_term(name: String) -> Result(a, Nil)

@external(erlang, "callcenter_ffi", "put_node_term")
fn put_node_term(name: String, value: a) -> Nil

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
