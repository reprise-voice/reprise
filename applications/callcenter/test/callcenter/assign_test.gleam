//// Who each shard is assigned to (`shards.assign`): the same answer on every
//// node that sees the same members, as even as it can be, and as little
//// moved as it can be when a member comes or goes.

import callcenter/shards
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const apps_0 = "kazoo_apps@reprise-apps-0.reprise-hs.reprise.svc.cluster.local"

const apps_1 = "kazoo_apps@reprise-apps-1.reprise-hs.reprise.svc.cluster.local"

const apps_2 = "kazoo_apps@reprise-apps-2.reprise-hs.reprise.svc.cluster.local"

fn loads(assigned: Dict(Int, String)) -> Dict(String, Int) {
  dict.fold(assigned, dict.new(), fn(loads, _shard, member) {
    dict.upsert(loads, member, fn(load) {
      case load {
        None -> 1
        Some(load) -> load + 1
      }
    })
  })
}

fn load_of(assigned: Dict(Int, String), member: String) -> Int {
  case dict.get(loads(assigned), member) {
    Ok(load) -> load
    Error(Nil) -> 0
  }
}

/// Two nodes hold exactly half each.
pub fn two_members_hold_half_each_test() {
  let assigned = shards.assign(64, [apps_0, apps_1])
  assert dict.size(assigned) == 64
  assert load_of(assigned, apps_0) == 32
  assert load_of(assigned, apps_1) == 32
}

pub fn one_member_holds_everything_test() {
  let assigned = shards.assign(64, [apps_0])
  assert load_of(assigned, apps_0) == 64
}

pub fn no_members_is_no_assignment_test() {
  assert shards.assign(64, []) == dict.new()
}

/// Every node computes it alone, from the members it sees, in whatever order
/// `kz_nodes` lists them.
pub fn the_order_and_repetition_of_members_do_not_matter_test() {
  let assigned = shards.assign(64, [apps_0, apps_1, apps_2])
  assert shards.assign(64, [apps_2, apps_0, apps_1]) == assigned
  assert shards.assign(64, [apps_1, apps_2, apps_1, apps_0]) == assigned
}

/// No member is given more than `ceil(shards / members)`, for any number of
/// members and shards.
pub fn no_member_is_given_more_than_its_share_test() {
  list.each([1, 2, 3, 4, 5, 7, 16, 64, 100], fn(size) {
    let members =
      int.range(from: 1, to: size + 1, with: [], run: fn(names, n) {
        ["node-" <> int.to_string(n), ..names]
      })
    list.each([1, 7, 64, 256], fn(count) {
      let assigned = shards.assign(count, members)
      assert dict.size(assigned) == count
      let cap = { count + size - 1 } / size
      dict.each(loads(assigned), fn(_member, load) {
        assert load <= cap
      })
    })
  })
}

/// A member leaving moves its own shards, and hardly anything else: the
/// shards that were somewhere else stay where they were, give or take the
/// few the bounded loads push along.
pub fn a_member_leaving_moves_its_own_shards_test() {
  let before = shards.assign(64, [apps_0, apps_1, apps_2])
  let after = shards.assign(64, [apps_0, apps_1])
  let moved =
    dict.fold(before, 0, fn(moved, shard, member) {
      case member == apps_2, dict.get(after, shard) == Ok(member) {
        True, _ -> moved
        False, True -> moved
        False, False -> moved + 1
      }
    })
  assert moved <= 6
}

/// A member joining takes about its share, and the rest stay.
pub fn a_member_joining_takes_its_share_test() {
  let before = shards.assign(64, [apps_0, apps_1])
  let after = shards.assign(64, [apps_0, apps_1, apps_2])
  let moved =
    dict.fold(after, 0, fn(moved, shard, member) {
      case dict.get(before, shard) == Ok(member) {
        True -> moved
        False -> moved + 1
      }
    })
  let joined = load_of(after, apps_2)
  assert joined >= 20
  assert moved <= joined + 6
}

/// The ranking a shard's assignment is dealt from: every member once,
/// highest first, and the same whatever order they are given in.
pub fn a_ranking_names_every_member_once_test() {
  let ranking = shards.ranking(9, [apps_0, apps_1, apps_2])
  assert list.length(ranking) == 3
  assert list.sort(ranking, string.compare) == [apps_0, apps_1, apps_2]
  assert shards.ranking(9, [apps_2, apps_1, apps_0]) == ranking
}
