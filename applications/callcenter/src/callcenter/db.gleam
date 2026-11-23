//// The call center's own database.
////
//// One system database named after the application. Nothing is written to it
//// yet -- the queue and agent documents live in the account databases, and
//// the statistics in the account MODBs -- but it is the database
//// `mark_kazoo_app` classified as this application's, so it is created
//// here: an application is installed by adding it to the applications list
//// and nothing else.
////
//// Idempotent and best effort. A node that cannot see the datastore starts
//// anyway and asks after shards anyway.

import callcenter/system
import kazoo/kazoo.{type Kazoo}

pub type Ready {
  /// It was there already.
  Ready
  Created
  Unreachable
}

pub fn ensure(kz: Kazoo) -> Ready {
  case kz.datamgr.db_exists(system.category) {
    True -> Ready
    False ->
      case kz.datamgr.db_create(system.category) {
        True -> {
          system.log("created the " <> system.category <> " database")
          Created
        }
        False -> Unreachable
      }
  }
}
