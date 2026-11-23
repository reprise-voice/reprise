//// Account documents.
////
//// The account document lives in the account's own database under its own id,
//// which is where `kzd_accounts:fetch/1` reads it from, so this is a decoder
//// over `datamgr` rather than another external call.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}

pub type Account {
  Account(
    id: String,
    name: Option(String),
    realm: Option(String),
    /// `pvt_tree`: every ancestor, root first, this account excluded.
    tree: List(String),
    enabled: Bool,
    superduper: Bool,
    reseller_id: Option(String),
    timezone: Option(String),
    doc: Value,
  )
}

pub fn fetch(kz: Kazoo, account_id: String) -> Result(Account, Error) {
  use value <- result.try(kz.datamgr.open_cache_doc(
    kazoo.account_db(account_id),
    account_id,
  ))
  Ok(from_doc(account_id, value))
}

pub fn from_doc(account_id: String, value: Value) -> Account {
  Account(
    id: account_id,
    name: doc.get_string(value, ["name"]) |> option.from_result,
    realm: doc.get_string(value, ["realm"]) |> option.from_result,
    tree: doc.strings(value, ["pvt_tree"]),
    // Kazoo's own default: an account is enabled unless pvt_enabled says no.
    enabled: doc.get_bool(value, ["pvt_enabled"]) |> result.unwrap(True),
    superduper: doc.get_bool(value, ["pvt_superduper_admin"])
      |> result.unwrap(False),
    reseller_id: doc.get_string(value, ["pvt_reseller_id"])
      |> option.from_result,
    timezone: doc.get_string(value, ["timezone"]) |> option.from_result,
    doc: value,
  )
}

/// `kzd_accounts:tree/1`: the ancestors, root first.
pub fn tree(kz: Kazoo, account_id: String) -> Result(List(String), Error) {
  fetch(kz, account_id) |> result.map(fn(account) { account.tree })
}

/// The account and its ancestors, root first: the order the settings layers
/// are applied in.
pub fn chain(kz: Kazoo, account_id: String) -> Result(List(String), Error) {
  tree(kz, account_id)
  |> result.map(fn(ancestors) { list.append(ancestors, [account_id]) })
}

/// The aggregate `accounts` database, and the view that turns a realm into an
/// account. Kazoo keeps realms unique across the cluster, so a realm names one
/// account and can stand in for its id.
pub const aggregate_db = "accounts"

pub const listing_by_realm = "accounts/listing_by_realm"

/// The view that lists every account under an ancestor: one row per
/// ancestor in `pvt_tree`, keyed `[ancestor, name]`, so a range from
/// `[id]` to `[id, {}]` is the whole subtree.
pub const listing_by_descendants = "accounts/listing_by_descendants"

/// The account with this realm, or `NotFound`. The realm is matched in lower
/// case, as the view emits it.
pub fn id_for_realm(kz: Kazoo, realm: String) -> Result(String, Error) {
  let options =
    kazoo.view_options()
    |> kazoo.with_key(doc.String(string.lowercase(realm)))
  use rows <- result.try(kz.datamgr.get_results(
    aggregate_db,
    listing_by_realm,
    options,
  ))
  rows
  |> list.filter_map(account_id_of)
  |> list.first
  |> result.replace_error(kazoo.NotFound)
}

/// The account a view row names. The realm listing emits the id as the row
/// key's document id; older clusters put the account database in the value.
fn account_id_of(row: Value) -> Result(String, Nil) {
  case doc.get_string(row, ["id"]) {
    Ok(id) -> Ok(id)
    Error(Nil) ->
      case doc.get_string(row, ["value", "account_id"]) {
        Ok(id) -> Ok(id)
        Error(Nil) -> Error(Nil)
      }
  }
}

/// `kzd_accounts:fetch_realm/1`.
pub fn realm(kz: Kazoo, account_id: String) -> Result(String, Error) {
  use account <- result.try(fetch(kz, account_id))
  case account.realm {
    Some(realm) -> Ok(realm)
    None -> Error(kazoo.NotFound)
  }
}

pub fn is_enabled(kz: Kazoo, account_id: String) -> Bool {
  case fetch(kz, account_id) {
    Ok(account) -> account.enabled
    Error(_) -> False
  }
}

pub fn reseller_id(kz: Kazoo, account_id: String) -> Option(String) {
  case fetch(kz, account_id) {
    Ok(account) -> account.reseller_id
    Error(_) -> None
  }
}

pub fn is_superduper_admin(kz: Kazoo, account_id: String) -> Bool {
  case fetch(kz, account_id) {
    Ok(account) -> account.superduper
    Error(_) -> False
  }
}

/// The account immediately above this one, if any.
pub fn parent(kz: Kazoo, account_id: String) -> Option(String) {
  case fetch(kz, account_id) {
    Ok(account) -> account.tree |> list.last |> option.from_result
    Error(_) -> None
  }
}

/// Every account on the cluster.
pub fn all_ids(kz: Kazoo) -> Result(List(String), Error) {
  kz.cluster.account_ids()
}
