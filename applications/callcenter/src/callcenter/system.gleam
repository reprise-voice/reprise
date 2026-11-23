//// Who this application is, as far as Kazoo is concerned.
////
//// One name: the OTP application, the `system_config` category, the alert
//// category, the application name on the messages it publishes, and its own
//// system database. Everything else about talking to Kazoo is in
//// `kazoo_gleam`, which takes that name as an argument; this is where the
//// call center supplies it.

import gleam/option.{Some}
import kazoo/amqp
import kazoo/app
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}

/// The `system_config` category, and the name of the call center's own
/// system database.
pub const category = "callcenter"

/// The `Kazoo` record that talks to the node this is running on.
pub fn live() -> Kazoo {
  kazoo.live(category)
}

/// Set `is_kazoo_app` on the application, which is how `kapps_controller`
/// recognises one of its own, and register the call center's database as a
/// system database with the data layer.
pub fn mark_kazoo_app() -> Nil {
  app.mark_kazoo_app(category, Some(category))
}

/// The application version, taken from gleam.toml through the .app file.
pub fn version() -> String {
  kazoo.version(category)
}

/// The Erlang node this is running on, which is what the logs and the member
/// messages name.
pub fn node_name() -> String {
  kazoo.node_name()
}

/// Whether there is a `gen_listener` in this VM at all.
///
/// False under `gleam run` and the test suite, which have the application
/// but not the release around it. Everything in the tree that consumes AMQP
/// is skipped there, so the rest can still be started and tested.
@external(erlang, "callcenter_ffi", "broker_available")
pub fn broker_available() -> Bool

/// Publish one of the application's own events through
/// `kapi_callcenter:publish_<event>/1`, with the headers `kz_api` requires of
/// it, and do not wait.
///
/// Without them `kapi_definition:build_message/2` refuses the payload and
/// the publish fails silently in `kz_amqp_worker`, which is a wallboard that
/// never updates and no sign of why.
pub fn publish(event: String, payload: Value) -> Nil {
  let _ =
    amqp.publish(
      module: "callcenter",
      function: event,
      payload: doc.merge(
        amqp.default_headers(category, "callcenter", event),
        payload,
      ),
    )
  Nil
}

/// One line in the Kazoo log, prefixed so that the whole of this
/// application's lifecycle can be read out of a node's log with `callcenter:`
/// and nothing else.
pub fn log(message: String) -> Nil {
  kazoo.log_info("callcenter: " <> message)
}

/// The same at error level, for what an operator has to act on.
pub fn log_error(message: String) -> Nil {
  kazoo.log_error("callcenter: " <> message)
}

/// The same at debug level, for what is only worth reading while chasing
/// something.
pub fn log_debug(message: String) -> Nil {
  debug("callcenter: " <> message)
}

@external(erlang, "callcenter_ffi", "log_debug")
fn debug(message: String) -> Nil
