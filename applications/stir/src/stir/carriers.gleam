//// The carrier an inbound call came from, and what its resource says
//// about verifying it.
////
//// The SBC stamps a trusted carrier call with `X-AUTH-Token`, which is
//// `<resource_id>@<account_id>` out of Kamailio's trusted table: the
//// account is the master account for a global resource and the owning
//// account for a local one. The resource document is what carries the
//// policy (`stir.verify`: `trust_upstream`, `verify` or `ignore`), so the
//// verdict a carrier stamps on a call is believed on the strength of its
//// resource and never of a header. A global resource lives in the
//// `offnet` database and a local one in the account's; the account
//// database is read first and `offnet` second, since the token does not
//// say which kind it names.
////
//// The answer is cached per token for a minute in a node-local table, so
//// the call path does one datastore read per carrier per minute and not
//// one per call. Nothing is cached for a datastore that could not be
//// reached, so the next call asks again.

import gleam/option.{None, Some}
import gleam/string
import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import stir/system

/// What the resource asks of an inbound call.
pub type Policy {
  /// Take the carrier's own verdict when it stamped one; verify the
  /// `Identity` header ourselves when it did not. The default.
  TrustUpstream
  /// Ignore any upstream verdict and verify the `Identity` ourselves.
  Verify
  /// Record nothing.
  Ignore
}

/// The resource a token resolved to.
pub type Carrier {
  Carrier(resource_id: String, account_id: String, policy: Policy)
}

pub type Error {
  /// Not `<resource_id>@<account_id>`.
  BadToken
  /// No resource of that id in the account's database or in `offnet`.
  NotFound
  /// The datastore refused or could not be reached.
  Datastore(kazoo.Error)
}

/// The node-local table the answers live in. The name is public so a
/// test can see what the monitor's sweep is sweeping.
pub const table = "stir_carriers"

pub const ttl_ms = 60_000

/// How many tokens the table holds. A token is a header off the wire, so
/// a peer that varies it varies the key; the table is bounded the way the
/// certificate cache is, by whoever writes past the bound and by the
/// monitor every pass.
pub const max_entries = 4096

/// The database global resources live in.
pub const offnet_db = "offnet"

/// The resource the SBC's token names, and its policy.
pub fn policy(kz: Kazoo, token: String) -> Result(Carrier, Error) {
  case parse_token(token) {
    Error(Nil) -> Error(BadToken)
    Ok(#(resource_id, account_id)) ->
      case cache.get_fresh(table, token, ttl_ms) {
        Ok(answer) -> answer
        Error(Nil) -> {
          let answer = lookup(kz, resource_id, account_id)
          case answer {
            Ok(_carrier) | Error(NotFound) -> {
              cache.put_fresh(table, token, answer)
              bound()
            }
            Error(_not_reached) -> Nil
          }
          answer
        }
      }
  }
}

/// `<resource_id>@<account_id>`, both non-empty. The token is a header
/// the SBC wrote, but it reaches this as bytes off the wire all the
/// same, so the split is byte-wise and nothing here reads it as text.
pub fn parse_token(token: String) -> Result(#(String, String), Nil) {
  case string.split_once(token, "@") {
    Ok(#("", _account)) -> Error(Nil)
    Ok(#(_resource, "")) -> Error(Nil)
    Ok(#(resource_id, account_id)) ->
      case string.contains(account_id, "@") {
        True -> Error(Nil)
        False -> Ok(#(resource_id, account_id))
      }
    Error(Nil) -> Error(Nil)
  }
}

/// Forget every cached answer on this node.
pub fn forget_cached() -> Nil {
  cache.clear(table)
}

/// How many tokens the table holds, fresh or stale.
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

pub fn policy_to_string(policy: Policy) -> String {
  case policy {
    TrustUpstream -> "trust_upstream"
    Verify -> "verify"
    Ignore -> "ignore"
  }
}

fn lookup(
  kz: Kazoo,
  resource_id: String,
  account_id: String,
) -> Result(Carrier, Error) {
  case resource(kz, kazoo.account_db(account_id), resource_id) {
    Ok(document) -> Ok(carrier(document, resource_id, account_id))
    Error(NotFound) ->
      case resource(kz, offnet_db, resource_id) {
        Ok(document) -> Ok(carrier(document, resource_id, account_id))
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

/// The document, when it is a resource that has not been deleted.
fn resource(
  kz: Kazoo,
  db: String,
  resource_id: String,
) -> Result(Value, Error) {
  case kz.datamgr.open_cache_doc(db, resource_id) {
    Ok(document) ->
      case
        doc.get_string(document, ["pvt_type"]),
        doc.get_bool(document, ["pvt_deleted"])
      {
        Ok("resource"), Ok(True) -> Error(NotFound)
        Ok("resource"), _ -> Ok(document)
        _, _ -> Error(NotFound)
      }
    Error(kazoo.NotFound) -> Error(NotFound)
    Error(error) -> Error(Datastore(error))
  }
}

fn carrier(
  document: Value,
  resource_id: String,
  account_id: String,
) -> Carrier {
  let policy = case doc.get_string(document, ["stir", "verify"]) {
    Ok("trust_upstream") -> Some(TrustUpstream)
    Ok("verify") -> Some(Verify)
    Ok("ignore") -> Some(Ignore)
    Ok(other) -> {
      system.log_error(
        "carriers: resource "
        <> resource_id
        <> " has stir.verify "
        <> other
        <> ", which is not trust_upstream, verify or ignore; trusting upstream",
      )
      None
    }
    Error(Nil) -> None
  }
  Carrier(
    resource_id:,
    account_id:,
    policy: option.unwrap(policy, TrustUpstream),
  )
}
