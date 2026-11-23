//// The application's own database: `stir`.
////
//// It holds the signing keys (`stir_key`), the trust material
//// (`stir_trust`) and the credentials (`stir_credentials`). It is the
//// database `mark_kazoo_app` classified as this application's, so it is
//// created here: an application is installed by adding it to the
//// applications list and nothing else.
////
//// Idempotent and best effort. A node that cannot see the datastore starts
//// anyway; it cannot sign, and says so.

import kazoo/kazoo.{type Kazoo}
import stir/system

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
