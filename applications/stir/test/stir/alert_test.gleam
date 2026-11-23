//// `stir/alert`: the throttle, which is the part with state in it.
////
//// A test node has no master account -- `kapps_util` is not loaded --
//// so `raise` cannot record anything and answers `Discarded`. What is
//// worth holding to is what happens around that: a discarded alert
//// spends no throttle slot, and the slot itself is the cluster's rather
//// than the node's, kept in one document in the `stir` database.
////
//// `claim` is the throttle without the alert, which is how both halves
//// are tested here: the first caller in an interval gets it, and the
//// second does not even from another node -- modelled by forgetting the
//// node-local table, which is all another node would differ by.

import kazoo/doc
import kazoo/testing/fake
import stir/alert

const now = 1_789_200_000

pub fn a_discarded_alert_spends_no_slot_test() {
  alert.reset("spends-nothing")
  let store = fake.new()
  let kz = fake.kazoo(store)
  // No master account on a test node, so nothing can be addressed.
  assert alert.raise(
      kz,
      "spends-nothing",
      "a title",
      "a message",
      doc.object([]),
      now,
      alert.default_interval_s,
    )
    == alert.Discarded
  assert fake.alerts(store) == []
  // Nothing was written, and the day's one chance is still there.
  assert fake.lookup(store, "stir", alert.throttle_id) |> is_error
  assert alert.claim(kz, "spends-nothing", now, alert.default_interval_s)
}

/// The throttle is one document for the cluster. The node-local table
/// in front of it is a cache and a fallback, not the throttle itself:
/// forget it, which is all another node would differ by, and the
/// document still says the slot is taken.
pub fn the_throttle_is_the_clusters_test() {
  let store = fake.new()
  let kz = fake.kazoo(store)
  alert.reset_for(kz, "cluster-wide")

  assert alert.claim(kz, "cluster-wide", now, alert.hourly_interval_s)
  // The same node, inside the interval: no.
  assert !alert.claim(kz, "cluster-wide", now + 60, alert.hourly_interval_s)
  // Another node -- one that has never seen this condition -- asks the
  // document and is told the same.
  alert.reset("cluster-wide")
  assert !alert.claim(kz, "cluster-wide", now + 120, alert.hourly_interval_s)

  // What the document holds: the last-raised time, under the dedupe.
  let assert Ok(document) = fake.lookup(store, "stir", alert.throttle_id)
  assert doc.get_int(document, ["raised", "cluster-wide"]) == Ok(now)
  assert doc.get_string(document, ["pvt_type"]) == Ok("stir_alerts")

  // Past the interval it comes round again.
  alert.reset("cluster-wide")
  assert alert.claim(
    kz,
    "cluster-wide",
    now + alert.hourly_interval_s,
    alert.hourly_interval_s,
  )
  // And another condition is its own slot, not this one's.
  assert alert.claim(kz, "another", now, alert.hourly_interval_s)
}

/// A dedupe key carries a `:` -- `expired:<kid>`, `two-active:<scope>`
/// -- which must not read as a path into the document.
pub fn a_dedupe_with_a_colon_is_one_member_test() {
  let store = fake.new()
  let kz = fake.kazoo(store)
  alert.reset_for(kz, "expired:abc123")
  assert alert.claim(kz, "expired:abc123", now, alert.default_interval_s)
  alert.reset("expired:abc123")
  assert !alert.claim(kz, "expired:abc123", now, alert.default_interval_s)
  let assert Ok(document) = fake.lookup(store, "stir", alert.throttle_id)
  assert doc.get_int(document, ["raised", "expired-abc123"]) == Ok(now)
}

/// With no datastore to claim in, the node's own table is the throttle:
/// an alert is still raised once per interval per node rather than not
/// at all.
pub fn without_a_datastore_the_node_throttles_test() {
  let kz = fake.kazoo(fake.new())
  alert.reset("no-store")
  // `fake.kazoo` over a store with no such database still answers, so
  // this is the same shape as the cluster case; what it holds to is
  // that a claim is answered at all and only once.
  assert alert.claim(kz, "no-store", now, alert.hourly_interval_s)
  assert !alert.claim(kz, "no-store", now + 1, alert.hourly_interval_s)
}

pub fn describe_test() {
  assert alert.describe(alert.Raised, "a thing") == "alerted: a thing"
  assert alert.describe(alert.Throttled, "a thing")
    == "already alerted: a thing"
  assert alert.describe(alert.Discarded, "a thing")
    == "no master account to alert: a thing"
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
