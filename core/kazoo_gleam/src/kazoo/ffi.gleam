//// The external declarations for `kazoo_gleam_ffi`.
////
//// `kazoo/kazoo` turns these into the typed `Kazoo` record an application is
//// given; almost nothing else should need them directly. Documents arrive as
//// `kz_json:to_map/1` output and leave as JSON text, which the shim hands to
//// `kz_json:from_map/1`.

import gleam/dynamic.{type Dynamic}

@external(erlang, "kazoo_gleam_ffi", "open_cache_doc")
pub fn open_cache_doc(db: String, doc_id: String) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_ffi", "open_doc")
pub fn open_doc(db: String, doc_id: String) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_ffi", "open_revision")
pub fn open_revision(
  db: String,
  doc_id: String,
  rev: String,
) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_ffi", "flush_cache_doc")
pub fn flush_cache_doc(db: String, doc_id: String) -> Nil

@external(erlang, "kazoo_gleam_ffi", "save_doc")
pub fn save_doc(db: String, json: String) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_ffi", "del_doc")
pub fn del_doc(db: String, doc_id: String) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_ffi", "get_results")
pub fn get_results(
  db: String,
  view: String,
  options_json: String,
) -> Result(List(Dynamic), String)

@external(erlang, "kazoo_gleam_ffi", "db_exists")
pub fn db_exists(db: String) -> Bool

@external(erlang, "kazoo_gleam_ffi", "db_create")
pub fn db_create(db: String) -> Bool

@external(erlang, "kazoo_gleam_ffi", "account_ids")
pub fn account_ids() -> Result(List(String), String)

@external(erlang, "kazoo_gleam_ffi", "config_get_integer")
pub fn config_get_integer(category: String, key: String, default: Int) -> Int

@external(erlang, "kazoo_gleam_ffi", "config_get_string")
pub fn config_get_string(
  category: String,
  key: String,
  default: String,
) -> String

@external(erlang, "kazoo_gleam_ffi", "config_get_json")
pub fn config_get_json(category: String, key: String) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_ffi", "config_set_default")
pub fn config_set_default(
  category: String,
  key: String,
  json: String,
) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_ffi", "validate_token")
pub fn validate_token(token: String) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_ffi", "create_token")
pub fn create_token(claims_json: String) -> Result(String, String)

@external(erlang, "kazoo_gleam_ffi", "alert")
pub fn alert(
  category: String,
  title: String,
  message: String,
  account_id: String,
  owner_id: String,
  reseller_id: String,
  metadata_json: String,
) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_ffi", "publish_check_sync")
pub fn publish_check_sync(
  app: String,
  event: String,
  realm: String,
  username: String,
) -> Result(Nil, String)

/// One line in the Kazoo log at error level, for what an operator has to see.
@external(erlang, "kazoo_gleam_ffi", "log_error")
pub fn log_error(message: String) -> Nil

/// One line in the Kazoo log at info level, for what an operator reads back.
@external(erlang, "kazoo_gleam_ffi", "log_info")
pub fn log_info(message: String) -> Nil

/// Set `is_kazoo_app` on the application and, when `system_db` is not empty,
/// register that database as a system database with the data layer. See
/// `kazoo/app`, which is what an application calls.
@external(erlang, "kazoo_gleam_ffi", "mark_kazoo_app")
pub fn mark_kazoo_app(app: String, system_db: String) -> Nil

@external(erlang, "kazoo_gleam_ffi", "node_name")
pub fn node_name() -> String

@external(erlang, "kazoo_gleam_ffi", "app_version")
pub fn app_version(app: String) -> String

@external(erlang, "kazoo_gleam_ffi", "request_id")
pub fn request_id() -> String

@external(erlang, "kazoo_gleam_ffi", "now_s")
pub fn now_s() -> Int

@external(erlang, "kazoo_gleam_ffi", "iso8601")
pub fn iso8601(unix_seconds: Int) -> String

@external(erlang, "kazoo_gleam_ffi", "random_string")
pub fn random_string(length: Int) -> String

@external(erlang, "kazoo_gleam_ffi", "priv_dir")
pub fn priv_dir(app: String) -> String
