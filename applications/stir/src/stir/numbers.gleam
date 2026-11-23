//// The ownership questions the attestation needs, answered from the
//// number manager and from the account's verified external numbers, with
//// a short node-local cache so the outbound path does one lookup per
//// number per minute at most.
////
//// The FFI `lookup_number/1` (in `stir_ffi.erl`) wraps
//// `knm_numbers:lookup_account/1`, which has a cache of its own; the one
//// here is what keeps a node with no number manager (a test node) and a
//// number nobody owns from being asked again on every call.
////
//// `owner_with` and `owned_with` take the lookup as an argument, which is
//// how a test drives the number manager's answers; `owner` and `owned`
//// are the same over the FFI.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/accounts
import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}

/// Who a number is assigned to, in service.
pub type Ownership {
  /// Assigned to this account.
  Account(id: String)
  /// Not assigned, not in service, or not a number the platform knows.
  Nobody
}

/// The number manager's answer for one number: the account it is
/// assigned to, in service and not pending a port, or why not.
pub type Lookup =
  fn(String) -> Result(String, String)

/// The node-local cache of both questions, one minute per entry. The name
/// is public so a test can see what the monitor's sweep is sweeping.
pub const table = "stir_numbers"

pub const ttl_ms = 60_000

/// How many answers the table holds. One entry per number per minute is
/// a slow way to fill it, but a flood of calls from numbers nobody owns
/// is a way all the same, so the table is bounded: whoever writes past
/// the bound trims it, and the monitor sweeps it every pass.
pub const max_entries = 4096

/// The view every account database carries that lists an
/// `external_number` document under `[pvt_type, number]`.
pub const external_numbers_view = "crossbar_listings/by_type_number"

pub const external_number_type = "external_number"

/// The account a number is assigned to, if any (cached 60 s).
pub fn owner(kz: Kazoo, tn: String) -> Ownership {
  owner_with(kz, tn, lookup_number)
}

/// The same, asking `lookup` rather than the number manager.
pub fn owner_with(_kz: Kazoo, tn: String, lookup: Lookup) -> Ownership {
  let name = "owner:" <> tn
  case cache.get_fresh(table, name, ttl_ms) {
    Ok(known) -> known
    Error(Nil) -> {
      let answer = case lookup(tn) {
        Ok(account_id) -> Account(account_id)
        Error(_why) -> Nobody
      }
      cache.put_fresh(table, name, answer)
      bound()
      answer
    }
  }
}

/// Whether the account, or an ancestor when `tree`, owns the number.
pub fn owned(
  kz: Kazoo,
  account_id: String,
  tn: String,
  scope: String,
) -> #(Bool, Bool) {
  owned_with(kz, account_id, tn, scope, lookup_number)
}

/// The same, asking `lookup` rather than the number manager. The answer
/// is `#(by the account itself, by an ancestor)`; the second is only ever
/// asked, and only ever true, when the scope is `tree`.
pub fn owned_with(
  kz: Kazoo,
  account_id: String,
  tn: String,
  scope: String,
  lookup: Lookup,
) -> #(Bool, Bool) {
  case owner_with(kz, tn, lookup) {
    Nobody -> #(False, False)
    Account(id) if id == account_id -> #(True, False)
    Account(id) ->
      case scope {
        "tree" ->
          case ancestors(kz, account_id) {
            Some(chain) -> #(False, list.contains(chain, id))
            None -> #(False, False)
          }
        _ -> #(False, False)
      }
  }
}

/// The master account is every account's ancestor, so a `tree` scope that
/// counted it would make every number on the platform owned by every
/// account. It is dropped from the chain; a node that cannot say which
/// account is the master keeps the chain as it is, since inventing an
/// exclusion would be worse than the one it cannot make.
fn without_master(chain: List(String)) -> List(String) {
  excluding(chain, master_account_id())
}

/// The chain without the given account, when there is one to leave out.
/// Split from `ancestors` so that the rule can be read and tested
/// without a release around it to say which account is the master.
pub fn excluding(
  chain: List(String),
  master: Result(String, Nil),
) -> List(String) {
  case master {
    Ok(master) -> list.filter(chain, fn(id) { id != master })
    Error(Nil) -> chain
  }
}

/// Whether the account holds a verified `external_numbers` document for
/// the number (cached 60 s).
///
/// The document stores the number as `knm_converters:normalize/1` writes
/// it, with the `+`, and the PASSporT carries digits only, so the view is
/// read under the E.164 spelling first and the bare digits second. A
/// datastore that cannot be read is `False` for this call and is not
/// cached: the next call asks again.
pub fn verified_external(kz: Kazoo, account_id: String, tn: String) -> Bool {
  let name = "external:" <> account_id <> ":" <> tn
  case cache.get_fresh(table, name, ttl_ms) {
    Ok(known) -> known
    Error(Nil) ->
      case verified_in_store(kz, account_id, tn) {
        Ok(answer) -> {
          cache.put_fresh(table, name, answer)
          bound()
          answer
        }
        Error(Nil) -> False
      }
  }
}

fn verified_in_store(
  kz: Kazoo,
  account_id: String,
  tn: String,
) -> Result(Bool, Nil) {
  use plus <- result.try(rows_verified(kz, account_id, "+" <> tn))
  case plus {
    True -> Ok(True)
    False -> rows_verified(kz, account_id, tn)
  }
}

/// Whether any row of the view for `number` is a verified document. The
/// view's value carries `verified`; the document itself carries
/// `pvt_verified`, and is asked for so that a store whose rows carry no
/// value (the test fake) answers the same.
fn rows_verified(
  kz: Kazoo,
  account_id: String,
  number: String,
) -> Result(Bool, Nil) {
  let options =
    kazoo.view_options()
    |> kazoo.with_key(
      doc.List([doc.String(external_number_type), doc.String(number)]),
    )
    |> kazoo.with_docs()
  case
    kz.datamgr.get_results(
      kazoo.account_db(account_id),
      external_numbers_view,
      options,
    )
  {
    Ok(rows) -> Ok(list.any(rows, row_verified))
    Error(_error) -> Error(Nil)
  }
}

/// An adopted number (`pvt_adopted`) is not a verified one, whatever
/// `pvt_verified` says: `sup kapps_maintenance gather_external_numbers`
/// writes both as true for every caller id anyone ever typed into an
/// account, user or device, and nothing about that shows the account
/// holds the number.
fn row_verified(row: Value) -> Bool {
  let adopted =
    doc.get_bool(row, ["doc", "pvt_adopted"])
    |> result.lazy_or(fn() { doc.get_bool(row, ["value", "adopted"]) })
    |> result.unwrap(False)
  case adopted, doc.get_bool(row, ["doc", "pvt_verified"]) {
    True, _ -> False
    False, Ok(verified) -> verified
    False, Error(Nil) ->
      doc.get_bool(row, ["value", "verified"]) |> result.unwrap(False)
  }
}

/// The chain of accounts an ancestor check walks, root first, the
/// account itself last, without the master account. `None` when the
/// account cannot be read.
pub fn ancestors(kz: Kazoo, account_id: String) -> Option(List(String)) {
  accounts.chain(kz, account_id)
  |> option.from_result
  |> option.map(without_master)
}

/// Forget every cached answer on this node, for a test.
pub fn forget() -> Nil {
  cache.clear(table)
}

/// How many answers the table holds, fresh or stale.
pub fn size() -> Int {
  cache.size(table)
}

/// Drop what has gone stale and trim the table back to `max_entries`,
/// oldest first; how many rows went. The monitor calls this every pass,
/// and a lookup that wrote past the bound calls it for itself.
pub fn sweep() -> Int {
  cache.sweep(table, ttl_ms, max_entries)
}

fn bound() -> Nil {
  case cache.size(table) > max_entries {
    False -> Nil
    True -> {
      let _dropped = sweep()
      Nil
    }
  }
}

@external(erlang, "stir_ffi", "lookup_number")
fn lookup_number(tn: String) -> Result(String, String)

@external(erlang, "stir_ffi", "master_account_id")
fn master_account_id() -> Result(String, Nil)
