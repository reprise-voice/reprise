//// The shards: how many there are, what they are called, and which one an
//// account lands in.

import callcenter/shards
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/set
import kazoo/doc
import kazoo/testing/fake

pub fn queue_names_test() {
  assert shards.member_queue(0) == "callcenter.member.0"
  assert shards.member_queue(63) == "callcenter.member.63"
}

/// Zero shards is no dispatch at all and a negative count is not a number of
/// anything: both are one shard, which still works.
pub fn clamp_test() {
  assert shards.clamp(64) == 64
  assert shards.clamp(1) == 1
  assert shards.clamp(0) == 1
  assert shards.clamp(-8) == 1
}

pub fn all_test() {
  assert shards.all(4) == [0, 1, 2, 3]
  assert shards.all(1) == [0]
  assert shards.all(0) == []
  assert list.length(shards.all(shards.default_count)) == 64
}

/// Every account lands in a shard that exists, and lands in the same one
/// every time. Both are what the addressing depends on: the node that
/// publishes and the node that holds the lease compute this separately.
pub fn of_account_is_in_range_test() {
  list.each(account_ids(200), fn(account_id) {
    let shard = shards.of_account(account_id, 64)
    assert shard >= 0
    assert shard < 64
    assert shards.of_account(account_id, 64) == shard
  })
}

/// Two hundred accounts over sixty-four shards should not pile into a
/// handful. This is not a test of the hash, it is a test that the count is
/// actually being used.
pub fn of_account_spreads_test() {
  let used =
    account_ids(200)
    |> list.map(shards.of_account(_, 64))
    |> set.from_list
  assert set.size(used) > 32
}

/// One shard is the degenerate case the clamp produces, and everything has
/// to land in it rather than in shard one of one.
pub fn of_account_with_one_shard_test() {
  list.each(account_ids(20), fn(account_id) {
    assert shards.of_account(account_id, 1) == 0
    assert shards.of_account(account_id, 0) == 0
  })
}

/// Off a node there is no broker to declare anything on, and that is an
/// answer rather than a crash: the application's start counts the queue as
/// not declared, and an owner's look finds nothing to take.
pub fn declare_without_a_release_test() {
  assert shards.declare("callcenter.member.0") == Error("unavailable")
}

fn account_ids(count: Int) -> List(String) {
  list.map(shards.all(count), fn(n) {
    "4b1f0c2d7e8a9b0c1d2e3f40516273" <> int.to_string(100 + n)
  })
}

// --- The node's count ------------------------------------------------------

/// The count is read once per node and kept. The callflow asks on every
/// call, and a change to the configuration since the node settled on its
/// count is not taken up: a node that changed count mid-flight would put
/// members where nobody consumes them. Only the application's start reads
/// the configuration again.
pub fn a_node_keeps_the_count_it_settled_on_test() {
  let f = fake.new()
  fake.put_config(f, "shards", doc.Int(8))
  let kz = fake.kazoo(f)
  assert shards.settle_count(kz) == 8
  fake.put_config(f, "shards", doc.Int(16))
  assert shards.configured(kz) == 16
  assert shards.count(kz) == 8
  assert shards.node_count() == Some(8)
  assert shards.settle_count(kz) == 16
  assert shards.count(kz) == 16
}

/// Without a broker nothing is known about the cluster's count, which
/// neither stops the owners nor turns a caller away.
pub fn no_broker_is_no_verdict_on_the_count_test() {
  assert shards.agreement(64) == shards.Unknown
  assert shards.known_agreement(64) == shards.Unknown
}
