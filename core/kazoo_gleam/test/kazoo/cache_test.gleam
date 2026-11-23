//// The node-local caches. Each test uses a table of its own, because a
//// table outlives the test that created it.

import kazoo/cache

pub fn get_put_delete_test() {
  let table = "kazoo_gleam_test_plain"
  cache.clear(table)

  assert cache.get(table, "missing") == Error(Nil)

  cache.put(table, "a", "one")
  assert cache.get(table, "a") == Ok("one")

  // A second write replaces the first.
  cache.put(table, "a", "two")
  assert cache.get(table, "a") == Ok("two")

  cache.delete(table, "a")
  assert cache.get(table, "a") == Error(Nil)
  // Deleting what is not there is not an error.
  cache.delete(table, "a")
}

/// What is stored is whatever was stored: the table is untyped underneath
/// and typed by the caller keeping one type per table.
pub fn stores_any_value_test() {
  let table = "kazoo_gleam_test_values"
  cache.clear(table)

  cache.put(table, "tuple", #(1, "two", [3.0]))
  assert cache.get(table, "tuple") == Ok(#(1, "two", [3.0]))
}

pub fn clear_test() {
  let table = "kazoo_gleam_test_clear"
  cache.put(table, "a", 1)
  cache.put(table, "b", 2)

  cache.clear(table)
  assert cache.get(table, "a") == Error(Nil)
  assert cache.get(table, "b") == Error(Nil)
  // The table itself is still there and still writable.
  cache.put(table, "a", 3)
  assert cache.get(table, "a") == Ok(3)
}

/// An entry read back inside its time to live is there; one read back with a
/// time to live of nothing is not.
pub fn fresh_test() {
  let table = "kazoo_gleam_test_fresh"
  cache.clear(table)

  assert cache.get_fresh(table, "realm", 300_000) == Error(Nil)

  cache.put_fresh(table, "realm", "4b1f0c2d")
  assert cache.get_fresh(table, "realm", 300_000) == Ok("4b1f0c2d")
  assert cache.get_fresh(table, "realm", 0) == Error(Nil)
}

/// The throttle: the first caller in each interval gets `True`, every other
/// one gets `False`, and the clock is the caller's own.
pub fn first_in_test() {
  let table = "kazoo_gleam_test_throttle"
  cache.clear(table)

  assert cache.first_in(table, "mac", 1000, 300)
  assert !cache.first_in(table, "mac", 1000, 300)
  assert !cache.first_in(table, "mac", 1299, 300)
  assert cache.first_in(table, "mac", 1300, 300)
  // Keys are independent.
  assert cache.first_in(table, "other", 1300, 300)
}

/// A bounded cache: stale entries go, then the oldest beyond the cap.
pub fn sweep_test() {
  cache.clear("sweep_test_table")
  cache.put_fresh("sweep_test_table", "a", 1)
  cache.put_fresh("sweep_test_table", "b", 2)
  cache.put_fresh("sweep_test_table", "c", 3)
  assert cache.size("sweep_test_table") == 3
  // Nothing is older than an hour; nothing beyond a cap of three.
  assert cache.sweep("sweep_test_table", 3_600_000, 3) == 0
  // A cap of one keeps the newest.
  assert cache.sweep("sweep_test_table", 3_600_000, 1) == 2
  assert cache.size("sweep_test_table") == 1
  assert cache.get_fresh("sweep_test_table", "c", 3_600_000) == Ok(3)
  // A ttl of zero expires everything.
  assert cache.sweep("sweep_test_table", 0, 10) == 1
  assert cache.size("sweep_test_table") == 0
}
