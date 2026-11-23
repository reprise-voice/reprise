//// An account's own configuration: the `configs_<category>` document in the
//// account database, which Crossbar's `/v2/accounts/{id}/configs/<category>`
//// reads and writes.
////
//// `get_string` is `kapps_account_config:get_global/4`: the account's
//// document when it has one, else its reseller's, and the key read from
//// whichever was found; a key that document does not set, or no document at
//// all, is `system_config/<category>`'s value, and then the default. An
//// account document that exists but leaves the key out is not looked past to
//// the reseller -- `get_global` does not either.
////
//// A decoder over `datamgr` and `config`, so `kazoo/testing/fake` serves it
//// with no fake of its own: `fake.put_doc` for the documents and
//// `fake.put_config("<category>.<key>", ...)` for the system value.

import gleam/option.{None, Some}
import kazoo/accounts
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}

/// The id of an account's configuration document for a category:
/// `kapps_config_util:account_doc_id/1`.
pub fn doc_id(category: String) -> String {
  "configs_" <> category
}

/// The account's own document for a category, when it has one.
pub fn document(
  kz: Kazoo,
  account_id: String,
  category: String,
) -> Result(Value, Error) {
  kz.datamgr.open_cache_doc(kazoo.account_db(account_id), doc_id(category))
}

/// A string setting as `kapps_account_config:get_global/4` reads it.
pub fn get_string(
  kz: Kazoo,
  account_id: String,
  category: String,
  key: String,
  default: String,
) -> String {
  let found = case document(kz, account_id, category) {
    Ok(own) -> Some(own)
    Error(_) ->
      case accounts.reseller_id(kz, account_id) {
        Some(reseller_id) if reseller_id != account_id ->
          document(kz, reseller_id, category) |> option.from_result
        _ -> None
      }
  }
  case found {
    Some(configured) ->
      case doc.get_string(configured, [key]) {
        Ok(value) -> value
        Error(Nil) -> system(kz, category, key, default)
      }
    None -> system(kz, category, key, default)
  }
}

fn system(kz: Kazoo, category: String, key: String, default: String) -> String {
  kz.config.get_string_in(category, key, default)
}
