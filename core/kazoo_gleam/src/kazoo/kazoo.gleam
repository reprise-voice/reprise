//// The calls that leave Gleam: the VM, and Kazoo's own APIs.
////
//// Everything an application does to Kazoo goes through one `Kazoo` value, a
//// record of functions built by `live/1`. The application takes it as an
//// argument, so a test builds one over an in-memory store instead (see
//// `kazoo/testing/fake`) and no test needs a database, a broker or a token.
////
//// The typed views of the documents themselves -- accounts, users, devices --
//// are in `kazoo/accounts`, `.../users` and `.../devices`; they are decoders
//// over this record's `datamgr` and need nothing else faked.
////
//// One string parameterises the whole module: the application's name. It is
//// the OTP application the version and the `priv` directory are read from,
//// the `system_config` category the configuration is read from, the alert
//// category, and the application name on the AMQP messages this publishes.
//// An application that wants those to differ calls `kazoo/ffi` directly.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import kazoo/ffi

/// What can go wrong on the way to the datastore. `Unavailable` is also what
/// a node with no datastore at all reports, which is how an application can
/// start and answer a health check on a node that cannot see CouchDB.
pub type Error {
  NotFound
  Conflict
  Unavailable
  Invalid(String)
}

pub fn error_to_string(error: Error) -> String {
  case error {
    NotFound -> "not_found"
    Conflict -> "conflict"
    Unavailable -> "unavailable"
    Invalid(reason) -> reason
  }
}

/// The `Error` a reason from the Erlang side stands for. Every binding that
/// answers `{'error', Reason}` goes through this, so one spelling of a
/// failure means one `Error` everywhere.
pub fn error_from_string(reason: String) -> Error {
  to_error(reason)
}

fn to_error(reason: String) -> Error {
  case reason {
    "not_found" -> NotFound
    "conflict" -> Conflict
    "unavailable" | "timeout" | "db_not_reachable" -> Unavailable
    other -> Invalid(other)
  }
}

/// The view options this library supports. Anything else a view can take is
/// deliberately absent: this is the whole surface the fake has to honour.
pub type ViewOptions {
  ViewOptions(
    key: Option(Value),
    start_key: Option(Value),
    end_key: Option(Value),
    limit: Option(Int),
    skip: Option(Int),
    include_docs: Bool,
    descending: Bool,
  )
}

pub fn view_options() -> ViewOptions {
  ViewOptions(
    key: None,
    start_key: None,
    end_key: None,
    limit: None,
    skip: None,
    include_docs: False,
    descending: False,
  )
}

pub fn with_key(options: ViewOptions, key: Value) -> ViewOptions {
  ViewOptions(..options, key: Some(key))
}

pub fn with_range(options: ViewOptions, from: Value, to: Value) -> ViewOptions {
  ViewOptions(..options, start_key: Some(from), end_key: Some(to))
}

pub fn with_start_key(options: ViewOptions, key: Value) -> ViewOptions {
  ViewOptions(..options, start_key: Some(key))
}

pub fn with_limit(options: ViewOptions, limit: Int) -> ViewOptions {
  ViewOptions(..options, limit: Some(limit))
}

pub fn with_docs(options: ViewOptions) -> ViewOptions {
  ViewOptions(..options, include_docs: True)
}

/// View options as the JSON object the Erlang side reads them from. The
/// bindings that run their own views -- `kazoo/modb` -- take this rather
/// than repeat the translation.
pub fn view_options_to_json(options: ViewOptions) -> String {
  options_to_json(options)
}

fn options_to_json(options: ViewOptions) -> String {
  doc.object_some([
    #("key", options.key),
    #("startkey", options.start_key),
    #("endkey", options.end_key),
    #("limit", option.map(options.limit, doc.Int)),
    #("skip", option.map(options.skip, doc.Int)),
    #("include_docs", case options.include_docs {
      True -> Some(doc.Bool(True))
      False -> None
    }),
    #("descending", case options.descending {
      True -> Some(doc.Bool(True))
      False -> None
    }),
  ])
  |> doc.to_string
}

/// Documents and views.
pub type Datamgr {
  Datamgr(
    open_cache_doc: fn(String, String) -> Result(Value, Error),
    open_doc: fn(String, String) -> Result(Value, Error),
    /// One revision of a document, deleted or not, with `_revisions` naming
    /// it and its ancestors (`?rev=<rev>&revs=true`). A superseded revision
    /// whose body compaction has discarded is `NotFound`. See `last_body`.
    open_revision: fn(String, String, String) -> Result(Value, Error),
    /// Forget the cached copy of one document, so that the next
    /// `open_cache_doc` reads it from the database.
    flush_cache_doc: fn(String, String) -> Nil,
    save_doc: fn(String, Value) -> Result(Value, Error),
    del_doc: fn(String, String) -> Result(Value, Error),
    get_results: fn(String, String, ViewOptions) -> Result(List(Value), Error),
    db_exists: fn(String) -> Bool,
    db_create: fn(String) -> Bool,
  )
}

/// `system_config/<application>`.
pub type Config {
  Config(
    get_int: fn(String, Int) -> Int,
    get_string: fn(String, String) -> String,
    /// The same read against another category, for the handful of values
    /// Crossbar owns (`crossbar.devices.check_sync_event`).
    get_string_in: fn(String, String, String) -> String,
    get_json: fn(String) -> Result(Value, Error),
    set_default: fn(String, Value) -> Result(Nil, Error),
  )
}

/// `kz_auth`. The claims are returned as they come, for the caller to read
/// `account_id`, `owner_id` and `exp` from; a token is minted from the claims
/// the caller names -- `account_id`, `owner_id`, `method`, `exp` in unix
/// seconds -- and comes back as the signed JWT Crossbar accepts.
pub type Auth {
  Auth(
    validate_token: fn(String) -> Result(Value, Error),
    create_token: fn(List(#(String, Value))) -> Result(String, Error),
  )
}

/// One Kazoo alert, in the shape `provisioner_v5` raises on a failed push.
/// The category it is filed under is the application's own name.
pub type Alert {
  Alert(
    title: String,
    message: String,
    account_id: String,
    owner_id: Option(String),
    reseller_id: Option(String),
    metadata: Value,
  )
}

pub type Alerts {
  Alerts(create: fn(Alert) -> Result(Nil, Error))
}

/// `kapi_switch`: the check-sync NOTIFY, published for one registration.
pub type Switch {
  Switch(check_sync: fn(String, String, String) -> Result(Nil, Error))
}

/// What the cluster knows about itself.
pub type Cluster {
  Cluster(account_ids: fn() -> Result(List(String), Error))
}

pub type Kazoo {
  Kazoo(
    datamgr: Datamgr,
    config: Config,
    auth: Auth,
    alerts: Alerts,
    switch: Switch,
    cluster: Cluster,
    /// Unix seconds. Injected so a test can hold time still.
    now: fn() -> Int,
    /// `n` characters of the generated-password alphabet.
    random: fn(Int) -> String,
  )
}

/// The record that talks to the node this is running on. `app` is the OTP
/// application's name, which is also its `system_config` category.
pub fn live(app: String) -> Kazoo {
  Kazoo(
    datamgr: Datamgr(
      open_cache_doc: fn(db, doc_id) {
        ffi.open_cache_doc(db, doc_id) |> decoded
      },
      open_doc: fn(db, doc_id) { ffi.open_doc(db, doc_id) |> decoded },
      open_revision: fn(db, doc_id, rev) {
        ffi.open_revision(db, doc_id, rev) |> decoded
      },
      flush_cache_doc: ffi.flush_cache_doc,
      save_doc: fn(db, value) {
        ffi.save_doc(db, doc.to_string(value)) |> decoded
      },
      del_doc: fn(db, doc_id) { ffi.del_doc(db, doc_id) |> decoded },
      get_results: fn(db, view, options) {
        ffi.get_results(db, view, options_to_json(options))
        |> result.map_error(to_error)
        |> result.map(fn(rows) { list_decoded(rows) })
      },
      db_exists: ffi.db_exists,
      db_create: ffi.db_create,
    ),
    config: Config(
      get_int: fn(key, default) { ffi.config_get_integer(app, key, default) },
      get_string: fn(key, default) { ffi.config_get_string(app, key, default) },
      get_string_in: ffi.config_get_string,
      get_json: fn(key) { ffi.config_get_json(app, key) |> decoded },
      set_default: fn(key, value) {
        ffi.config_set_default(app, key, doc.to_string(value))
        |> result.map_error(to_error)
      },
    ),
    auth: Auth(
      validate_token: fn(token) { ffi.validate_token(token) |> decoded },
      create_token: fn(claims) {
        ffi.create_token(doc.to_string(doc.object(claims)))
        |> result.map_error(to_error)
      },
    ),
    alerts: Alerts(create: fn(alert: Alert) {
      ffi.alert(
        app,
        alert.title,
        alert.message,
        alert.account_id,
        option.unwrap(alert.owner_id, ""),
        option.unwrap(alert.reseller_id, ""),
        doc.to_string(alert.metadata),
      )
      |> result.map_error(to_error)
    }),
    switch: Switch(check_sync: fn(event, realm, username) {
      ffi.publish_check_sync(app, event, realm, username)
      |> result.map_error(to_error)
    }),
    cluster: Cluster(account_ids: fn() {
      ffi.account_ids() |> result.map_error(to_error)
    }),
    now: ffi.now_s,
    random: ffi.random_string,
  )
}

/// The last body a document had, from the revision `rev` names and the
/// history CouchDB keeps behind it. `rev` is what a `doc_deleted` event
/// carries: a soft delete's revision still holds the body, so it is the
/// answer; a hard delete's is a bare tombstone, so the answer is its parent.
///
/// This is how a document that is already gone is read back, and it only
/// works while the database still holds the parent's body: compaction
/// discards the bodies of superseded revisions, after which it is
/// `NotFound`.
pub fn last_body(
  kz: Kazoo,
  db: String,
  doc_id: String,
  rev: String,
) -> Result(Value, Error) {
  use at <- result.try(kz.datamgr.open_revision(db, doc_id, rev))
  case doc.get_bool(at, ["_deleted"]) {
    Ok(True) -> {
      use parent <- result.try(
        parent_revision(at) |> result.replace_error(NotFound),
      )
      kz.datamgr.open_revision(db, doc_id, parent)
      |> result.map(doc.delete(_, ["_revisions"]))
    }
    _ -> Ok(doc.delete(at, ["_revisions"]))
  }
}

/// The revision before the one `_revisions` starts at: `ids` runs newest
/// first, and `start` is the newest one's generation.
fn parent_revision(at: Value) -> Result(String, Nil) {
  use start <- result.try(doc.get_int(at, ["_revisions", "start"]))
  case doc.strings(at, ["_revisions", "ids"]) {
    [_, parent, ..] -> Ok(int.to_string(start - 1) <> "-" <> parent)
    _ -> Error(Nil)
  }
}

fn decoded(result: Result(Dynamic, String)) -> Result(Value, Error) {
  result |> result.map(doc.from_dynamic) |> result.map_error(to_error)
}

fn list_decoded(rows: List(Dynamic)) -> List(Value) {
  case rows {
    [] -> []
    [row, ..rest] -> [doc.from_dynamic(row), ..list_decoded(rest)]
  }
}

/// The account database of an account id, in the encoded form Kazoo stores it
/// under; the same string `kzs_util:format_account_db/1` builds.
pub fn account_db(account_id: String) -> String {
  case string.length(account_id) {
    32 ->
      "account%2F"
      <> string.slice(account_id, 0, 2)
      <> "%2F"
      <> string.slice(account_id, 2, 2)
      <> "%2F"
      <> string.slice(account_id, 4, 28)
    _ -> account_id
  }
}

/// Whether a string is a Kazoo id: 32 lowercase hex characters.
pub fn is_id(value: String) -> Bool {
  string.length(value) == 32 && is_hex(string.to_graphemes(value))
}

fn is_hex(characters: List(String)) -> Bool {
  case characters {
    [] -> True
    [character, ..rest] ->
      case character {
        "0"
        | "1"
        | "2"
        | "3"
        | "4"
        | "5"
        | "6"
        | "7"
        | "8"
        | "9"
        | "a"
        | "b"
        | "c"
        | "d"
        | "e"
        | "f" -> is_hex(rest)
        _ -> False
      }
  }
}

/// `system_config/<app>.<key>`, or `default` when the datastore cannot be
/// reached.
pub fn config_int(app: String, key: String, default: Int) -> Int {
  ffi.config_get_integer(app, key, default)
}

/// `system_config/<app>.<key>` as a string.
pub fn config_string(app: String, key: String, default: String) -> String {
  ffi.config_get_string(app, key, default)
}

/// One line in the Kazoo log at error level, for what an operator has to
/// see. Everything else an application logs is its own business; this is the
/// one that has to reach lager.
pub fn log_error(message: String) -> Nil {
  ffi.log_error(message)
}

/// One line in the Kazoo log at info level: a lifecycle transition, a piece
/// of work taken up or handed on. What an operator reads back afterwards
/// rather than acts on now, which is `log_error`.
pub fn log_info(message: String) -> Nil {
  ffi.log_info(message)
}

/// The Erlang node this is running on.
pub fn node_name() -> String {
  ffi.node_name()
}

/// The application version, taken from gleam.toml through the .app file.
pub fn version(app: String) -> String {
  ffi.app_version(app)
}

/// A random identifier for a response envelope.
pub fn request_id() -> String {
  ffi.request_id()
}

/// Unix seconds as the RFC 3339 instant Kazoo's APIs use.
pub fn iso8601(unix_seconds: Int) -> String {
  ffi.iso8601(unix_seconds)
}

/// The application's priv directory: its schemas, its contract, its data
/// files. Falls back to the relative `priv` so a checkout without a built
/// release reads the same files.
pub fn priv_dir(app: String) -> String {
  ffi.priv_dir(app)
}
