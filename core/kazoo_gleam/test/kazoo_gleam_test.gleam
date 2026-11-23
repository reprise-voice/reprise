//// The names Kazoo gives things, and what the live record does on a node
//// with no Kazoo release around it.

import gleam/option.{None, Some}
import gleam/string
import gleeunit
import kazoo/devices
import kazoo/doc
import kazoo/kazoo

pub fn main() -> Nil {
  gleeunit.main()
}

/// The same string `kzs_util:format_account_db/1` builds.
pub fn account_db_test() {
  assert kazoo.account_db("4b1f0c2d7e8a9b0c1d2e3f4051627384")
    == "account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384"
  // Anything that is not an id is a database name already.
  assert kazoo.account_db("accounts") == "accounts"
  assert kazoo.account_db("") == ""
}

pub fn is_id_test() {
  assert kazoo.is_id("4b1f0c2d7e8a9b0c1d2e3f4051627384")
  assert !kazoo.is_id("search")
  assert !kazoo.is_id("4B1F0C2D7E8A9B0C1D2E3F4051627384")
  // Thirty-one and thirty-three characters are not ids either.
  assert !kazoo.is_id("4b1f0c2d7e8a9b0c1d2e3f405162738")
  assert !kazoo.is_id("4b1f0c2d7e8a9b0c1d2e3f40516273844")
}

pub fn error_to_string_test() {
  assert kazoo.error_to_string(kazoo.NotFound) == "not_found"
  assert kazoo.error_to_string(kazoo.Conflict) == "conflict"
  assert kazoo.error_to_string(kazoo.Unavailable) == "unavailable"
  assert kazoo.error_to_string(kazoo.Invalid("no_realm")) == "no_realm"
}

/// `kz_network_utils:cleanse_mac_address/1`: strip everything that is not
/// hexadecimal, lowercase the rest.
pub fn cleanse_mac_test() {
  assert devices.cleanse_mac("80:5E:C0:04:B3:D7") == Ok("805ec004b3d7")
  assert devices.cleanse_mac("80-5e-c0-04-b3-d7") == Ok("805ec004b3d7")
  assert devices.cleanse_mac("zz") == Error(Nil)
  assert devices.valid_mac("805ec004b3") == Error(Nil)
  assert devices.valid_mac("805ec004b3d7") == Ok("805ec004b3d7")
}

/// The version and the priv directory are read per application, and neither
/// exists in a test run: the fallbacks are what a node without the release
/// around it gets.
pub fn application_facts_test() {
  assert kazoo.version("no_such_application") == "unknown"
  assert kazoo.priv_dir("no_such_application") == "priv"
  assert kazoo.node_name() != ""
  assert string.length(kazoo.request_id()) == 32
}

/// Every call degrades rather than crashing when there is no datastore,
/// which is what lets an application start and answer on a node that cannot
/// see CouchDB.
pub fn no_datastore_test() {
  let kz = kazoo.live("no_such_application")
  assert kz.datamgr.open_doc("accounts", "whatever") == Error(kazoo.Unavailable)
  assert kz.datamgr.open_cache_doc("accounts", "whatever")
    == Error(kazoo.Unavailable)
  assert kz.datamgr.get_results(
      "accounts",
      "accounts/listing_by_realm",
      kazoo.view_options(),
    )
    == Error(kazoo.Unavailable)
  assert !kz.datamgr.db_exists("accounts")
  assert !kz.datamgr.db_create("accounts")
  assert kz.cluster.account_ids() == Error(kazoo.Unavailable)
  assert kz.auth.validate_token("nope") == Error(kazoo.Unavailable)
  // Configuration falls back to what the caller asked for.
  assert kz.config.get_int("port", 8100) == 8100
  assert kz.config.get_string("mode", "amqp") == "amqp"
  assert kz.config.get_json("key") == Error(kazoo.Unavailable)
}

/// Characters of the generated-password alphabet, which is URL safe and
/// typeable on a handset keypad.
pub fn random_string_test() {
  let kz = kazoo.live("no_such_application")
  let generated = kz.random(32)
  assert string.length(generated) == 32
  assert generated != kz.random(32)
  assert kz.random(0) == ""
}

pub fn iso8601_test() {
  assert kazoo.iso8601(1_757_400_000) == "2025-09-09T06:40:00Z"
}

/// A view option nobody set is not sent at all, so the driver's own default
/// stands.
pub fn view_options_test() {
  let options = kazoo.view_options()
  assert options.key == None
  assert options.start_key == None
  assert options.limit == None
  assert !options.include_docs
  assert !options.descending

  let ranged =
    options
    |> kazoo.with_range(doc.String("a"), doc.String("b"))
    |> kazoo.with_limit(10)
    |> kazoo.with_docs
  assert ranged.start_key == Some(doc.String("a"))
  assert ranged.end_key == Some(doc.String("b"))
  assert ranged.limit == Some(10)
  assert ranged.include_docs

  let exact = kazoo.view_options() |> kazoo.with_key(doc.String("acme"))
  assert exact.key == Some(doc.String("acme"))

  let from = kazoo.view_options() |> kazoo.with_start_key(doc.Int(3))
  assert from.start_key == Some(doc.Int(3))
  assert from.end_key == None
}
