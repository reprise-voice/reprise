//// Node-local caches.
////
//// A cache is a name and a value type. Nothing here is distributed and
//// nothing here is durable: this is for what a node can recompute -- a
//// parsed file, a client it has already built, a lookup it has already made.
////
//// The table is untyped underneath, so one name means one type. Wrap each
//// cache in a function of its own, the way `template_cache` below is written
//// in a doc comment, rather than reading a table under two types:
////
//// ```gleam
//// fn cached_template(path: String) -> Result(Template, Nil) {
////   cache.get("my_app_templates", path)
//// }
//// ```
////
//// The table is created on first use and owned by a process of its own, so
//// no caller has to start anything and nothing is lost when a request ends.
//// Table names must be literals: each distinct one is an atom, for good.

/// What is stored under `key`, if anything is.
@external(erlang, "kazoo_gleam_cache_ffi", "get")
pub fn get(table: String, key: String) -> Result(value, Nil)

@external(erlang, "kazoo_gleam_cache_ffi", "put")
pub fn put(table: String, key: String, value: value) -> Nil

@external(erlang, "kazoo_gleam_cache_ffi", "delete")
pub fn delete(table: String, key: String) -> Nil

/// Forget everything in the cache.
@external(erlang, "kazoo_gleam_cache_ffi", "clear")
pub fn clear(table: String) -> Nil

/// What is stored under `key`, if it was stored less than `ttl_ms` ago. Read
/// only what was written with `put_fresh`.
@external(erlang, "kazoo_gleam_cache_ffi", "get_fresh")
pub fn get_fresh(table: String, key: String, ttl_ms: Int) -> Result(value, Nil)

@external(erlang, "kazoo_gleam_cache_ffi", "put_fresh")
pub fn put_fresh(table: String, key: String, value: value) -> Nil

/// Whether `key` has not been seen in the last `interval_seconds`,
/// remembering that it has been seen at `now`. A throttle: the first caller
/// in each interval gets `True` and every other one gets `False`.
///
/// `now` is the caller's own clock, so a test that holds time still holds
/// this still too.
@external(erlang, "kazoo_gleam_cache_ffi", "first_in")
pub fn first_in(
  table: String,
  key: String,
  now: Int,
  interval_seconds: Int,
) -> Bool

/// How many entries the cache holds, fresh or stale.
@external(erlang, "kazoo_gleam_cache_ffi", "size")
pub fn size(table: String) -> Int

/// Drop every `put_fresh` entry older than `ttl_ms`, then the oldest
/// entries beyond `keep`. Atomic per pass and safe from any process, so a
/// bound on a cache can be enforced by whoever notices it is over, not by
/// a bookkeeping list that racing inserts would corrupt. Answers how many
/// entries went.
@external(erlang, "kazoo_gleam_cache_ffi", "sweep")
pub fn sweep(table: String, ttl_ms: Int, keep: Int) -> Int
