//// Who this application is, as far as Kazoo is concerned.
////
//// One name: the OTP application, the `system_config` category, the alert
//// category, the application name on the messages it publishes, and its own
//// system database. Everything else about talking to Kazoo is in
//// `kazoo_gleam`, which takes that name as an argument; this is where `stir`
//// supplies it.

import gleam/option.{Some}
import kazoo/app
import kazoo/kazoo.{type Kazoo}

/// The `system_config` category, and the name of the application's own
/// system database, where the signing keys, the trust material and the
/// credentials live.
pub const category = "stir"

/// The `Kazoo` record that talks to the node this is running on.
pub fn live() -> Kazoo {
  kazoo.live(category)
}

/// Set `is_kazoo_app` on the application, which is how `kapps_controller`
/// recognises one of its own, and register the `stir` database as a system
/// database with the data layer.
pub fn mark_kazoo_app() -> Nil {
  app.mark_kazoo_app(category, Some(category))
}

/// The application version, taken from gleam.toml through the .app file.
pub fn version() -> String {
  kazoo.version(category)
}

pub fn node_name() -> String {
  kazoo.node_name()
}

/// One line in the Kazoo log, prefixed so that everything this application
/// does can be read out of a node's log with `stir:` and nothing else. No
/// key material ever goes through here; the `Key` type renders as its id.
pub fn log(message: String) -> Nil {
  kazoo.log_info("stir: " <> message)
}

/// The same at error level, for what an operator has to act on.
pub fn log_error(message: String) -> Nil {
  kazoo.log_error("stir: " <> message)
}

/// The environment variable the key-encryption key is read from, and its
/// successor during a rotation. Names, not values: the values are read once
/// by `stir/vault` and never logged, stored or answered.
pub const kek_variable = "STIR_KEK"

pub const kek_next_variable = "STIR_KEK_NEXT"
