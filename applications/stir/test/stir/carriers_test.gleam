//// `stir/carriers`: a token to its resource's policy, over the fake
//// store with a resource in an account database and one in `offnet`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake
import stir/carriers.{Carrier}

const account = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

const master = "0123456789abcdef0123456789abcdef"

const local_id = "carrier00000000000000000000local"

const global_id = "carrier0000000000000000000global"

pub fn a_local_resource_is_read_from_the_account_test() {
  carriers.forget_cached()
  let store = fake.new()
  fake.put_doc(
    store,
    kazoo.account_db(account),
    resource(local_id, Some("verify")),
  )
  let kz = fake.kazoo(store)
  assert carriers.policy(kz, local_id <> "@" <> account)
    == Ok(Carrier(
      resource_id: local_id,
      account_id: account,
      policy: carriers.Verify,
    ))
}

pub fn a_global_resource_is_read_from_offnet_test() {
  carriers.forget_cached()
  let store = fake.new()
  fake.put_doc(store, carriers.offnet_db, resource(global_id, Some("ignore")))
  let kz = fake.kazoo(store)
  assert carriers.policy(kz, global_id <> "@" <> master)
    == Ok(Carrier(
      resource_id: global_id,
      account_id: master,
      policy: carriers.Ignore,
    ))
}

/// The account's own document wins over one of the same id in `offnet`.
pub fn the_account_database_is_read_first_test() {
  carriers.forget_cached()
  let store = fake.new()
  fake.put_doc(
    store,
    kazoo.account_db(account),
    resource(local_id, Some("verify")),
  )
  fake.put_doc(store, carriers.offnet_db, resource(local_id, Some("ignore")))
  let kz = fake.kazoo(store)
  let assert Ok(carrier) = carriers.policy(kz, local_id <> "@" <> account)
  assert carrier.policy == carriers.Verify
}

/// No `stir` object, and a value that is none of the three, both mean
/// the default.
pub fn the_default_is_trust_upstream_test() {
  carriers.forget_cached()
  let store = fake.new()
  fake.put_doc(store, carriers.offnet_db, resource(global_id, None))
  fake.put_doc(store, carriers.offnet_db, resource(local_id, Some("maybe")))
  let kz = fake.kazoo(store)
  let assert Ok(plain) = carriers.policy(kz, global_id <> "@" <> master)
  assert plain.policy == carriers.TrustUpstream
  let assert Ok(odd) = carriers.policy(kz, local_id <> "@" <> master)
  assert odd.policy == carriers.TrustUpstream
}

pub fn no_resource_is_not_found_test() {
  carriers.forget_cached()
  let store = fake.new()
  // A document of another type under the id, and a deleted resource,
  // are no resource either.
  fake.put_doc(
    store,
    carriers.offnet_db,
    doc.object([
      #("_id", doc.String("not-a-resource")),
      #("pvt_type", doc.String("device")),
    ]),
  )
  fake.put_doc(
    store,
    carriers.offnet_db,
    doc.set(resource("gone", None), ["pvt_deleted"], doc.Bool(True)),
  )
  let kz = fake.kazoo(store)
  assert carriers.policy(kz, "missing@" <> master) == Error(carriers.NotFound)
  assert carriers.policy(kz, "not-a-resource@" <> master)
    == Error(carriers.NotFound)
  assert carriers.policy(kz, "gone@" <> master) == Error(carriers.NotFound)
}

pub fn a_token_that_is_not_resource_at_account_is_refused_test() {
  let kz = fake.kazoo(fake.new())
  assert carriers.policy(kz, "") == Error(carriers.BadToken)
  assert carriers.policy(kz, "nope") == Error(carriers.BadToken)
  assert carriers.policy(kz, "@" <> account) == Error(carriers.BadToken)
  assert carriers.policy(kz, local_id <> "@") == Error(carriers.BadToken)
  assert carriers.policy(kz, "a@b@c") == Error(carriers.BadToken)
  assert carriers.parse_token(local_id <> "@" <> account)
    == Ok(#(local_id, account))
}

/// The answer is held for a minute: a change to the document is not
/// seen until the cache is forgotten.
pub fn the_policy_is_cached_test() {
  carriers.forget_cached()
  let store = fake.new()
  fake.put_doc(store, carriers.offnet_db, resource(global_id, Some("verify")))
  let kz = fake.kazoo(store)
  let token = global_id <> "@" <> master
  let assert Ok(before) = carriers.policy(kz, token)
  assert before.policy == carriers.Verify
  fake.put_doc(store, carriers.offnet_db, resource(global_id, Some("ignore")))
  let assert Ok(cached) = carriers.policy(kz, token)
  assert cached.policy == carriers.Verify
  carriers.forget_cached()
  let assert Ok(after) = carriers.policy(kz, token)
  assert after.policy == carriers.Ignore
  // Not found is remembered too, so a token for a deleted resource does
  // not read the datastore on every call.
  assert carriers.policy(kz, "missing@" <> master) == Error(carriers.NotFound)
  fake.put_doc(store, carriers.offnet_db, resource("missing", None))
  assert carriers.policy(kz, "missing@" <> master) == Error(carriers.NotFound)
}

/// A resource document with the given `stir.verify`, or no `stir` at all.
pub fn resource(id: String, verify: Option(String)) -> doc.Value {
  let base = [
    #("_id", doc.String(id)),
    #("pvt_type", doc.String("resource")),
    #("name", doc.String("Carrier " <> id)),
  ]
  case verify {
    None -> doc.object(base)
    Some(value) ->
      doc.object([
        #("stir", doc.object([#("verify", doc.String(value))])),
        ..base
      ])
  }
}

/// The table is bounded: a token is a header off the wire, so past
/// `max_entries` the oldest goes and the row count says so. A sweep of a
/// table inside its bound with nothing stale in it drops nothing, which
/// is what the monitor calls every pass.
pub fn the_cache_is_bounded_test() {
  carriers.forget_cached()
  let store = fake.new()
  fake.put_doc(store, carriers.offnet_db, resource(global_id, Some("verify")))
  let kz = fake.kazoo(store)
  down_from(carriers.max_entries + 8)
  |> list.each(fn(n) {
    let assert Ok(_carrier) =
      carriers.policy(kz, global_id <> "@account" <> int.to_string(n))
  })
  assert carriers.size() <= carriers.max_entries
  assert carriers.sweep() == 0
  carriers.forget_cached()
  assert carriers.size() == 0
}

/// `n` down to 1; `gleam/list` has no `range`.
fn down_from(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> [n, ..down_from(n - 1)]
  }
}
