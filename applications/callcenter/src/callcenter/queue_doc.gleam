//// The queue document, as the dispatcher reads it.
////
//// It is read through the data layer's document cache, which `kz_cache`
//// keeps and empties when the document's `doc_edited` arrives, so an edit
//// is normally in force on the next pass and no pass costs a database
//// read. That notice is a message on the broker, and a broker restart can
//// lose it: the node that took the edit publishes before its own channel
//// is back and the publish is dropped, after which the cache would serve
//// the old queue for its full fifteen minutes and a caller would wait on a
//// list of agents that no longer holds. So, at most once every
//// `queue_refresh_s` per queue, the document is read from the database
//// instead and the cached copy is dropped behind it: the next pass caches
//// the fresh one, and nothing in between reads the database.
////
//// A database that cannot be reached is not a reason to forget the queue.
//// The refresh then reads nothing, the cached copy stands for as long as the
//// cache keeps it, and the next refresh tries again. Dispatch through a
//// database outage is best effort, and this is the effort.

import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo, NotFound}

/// When each queue was last read from the database. Keyed by database and
/// document, stamped with the dispatcher's own clock.
const refreshes = "callcenter_queue_refreshes"

/// `system_config/callcenter.queue_refresh_s`.
pub const default_refresh_s = 10

/// The queue document: from the database if it has not been read from there
/// in the last `refresh_s` seconds, from the cache otherwise.
pub fn read(
  kz: Kazoo,
  db: String,
  id: String,
  now: Int,
  refresh_s: Int,
) -> Result(Value, Error) {
  case cache.first_in(refreshes, db <> "/" <> id, now, refresh_s) {
    False -> kz.datamgr.open_cache_doc(db, id)
    True -> refresh(kz, db, id)
  }
}

fn refresh(kz: Kazoo, db: String, id: String) -> Result(Value, Error) {
  case kz.datamgr.open_doc(db, id) {
    Ok(document) -> {
      kz.datamgr.flush_cache_doc(db, id)
      Ok(document)
    }
    // The database answered: the queue is gone, and so is its cached copy.
    Error(NotFound) -> {
      kz.datamgr.flush_cache_doc(db, id)
      Error(NotFound)
    }
    // The database did not answer: whatever the cache holds stands.
    Error(_unreachable) -> kz.datamgr.open_cache_doc(db, id)
  }
}

/// Forget when every queue was last read from the database. For a test
/// suite whose clock starts over with every dispatcher.
pub fn reset() -> Nil {
  cache.clear(refreshes)
}
