//// What a bridge can be pointed at.
////
//// An endpoint is the object the switch is given to ring one device: its
//// SIP route, its codecs, its timeouts and the channel variables that follow
//// the leg. Building one is not a database read: `build` applies call
//// forwarding, do-not-disturb, the hotdesk, the device's own settings and
//// the account's, and answers one object per device that will actually ring.
////
//// The call matters to the result. A call carrying the `Queue-ID` channel
//// variable has the devices that opted out of queue calls left out, which is
//// how a call center agent keeps one of their devices off the queue.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/result
import kazoo/call.{type Call}
import kazoo/doc.{type Value}

/// Why there is nothing to ring.
pub type Error {
  /// No such device or user.
  NotFound
  /// The endpoint is there and will not take the call: disabled, on do not
  /// disturb, or the caller's own device.
  Refused(String)
  /// The datastore could not be reached, or there is no release here.
  Unavailable
}

fn to_error(reason: String) -> Error {
  case reason {
    "not_found" | "invalid_endpoint_id" | "endpoint_id_undefined" -> NotFound
    "db_not_reachable" | "unavailable" | "timeout" -> Unavailable
    other -> Refused(other)
  }
}

/// Every endpoint that rings for `id`, which may be a device or a user.
pub fn build(call: Call, id: String) -> Result(List(Value), Error) {
  ffi_build(call, id) |> to_result
}

/// The devices a user owns, each as an endpoint. One user can ring several
/// devices at once; each answers separately.
pub fn build_for_user(
  call: Call,
  user_id: String,
) -> Result(List(Value), Error) {
  build(call, user_id)
}

/// One device as an endpoint. Answers a list for the same reason `build`
/// does: a device with call forwarding on can ring in two places.
pub fn build_for_device(
  call: Call,
  device_id: String,
) -> Result(List(Value), Error) {
  build(call, device_id)
}

/// The same as `build`, with the properties that override what the endpoint
/// asks for: `can_call_self`, `suppress_clid`, `source`, the codecs.
pub fn build_with(
  call: Call,
  id: String,
  properties: Value,
) -> Result(List(Value), Error) {
  ffi_build_with(call, id, doc.to_string(properties)) |> to_result
}

/// Every endpoint owned by a user, with the devices that failed to build
/// dropped rather than failing the lot.
///
/// What that means depends on which `kz_endpoint` the cluster runs: v4
/// builds the devices one at a time, v5 answers the user as one endpoint.
/// Anything that depends on a *device's* own settings wants
/// `build_for_owned_devices` instead, which does the same thing on both.
pub fn by_owner(call: Call, owner_id: String) -> Result(List(Value), Error) {
  ffi_by_owner(call, owner_id) |> to_result
}

/// Every device a user owns, each built as an endpoint of its own.
///
/// Neither `build_for_user` nor `by_owner` does this under `kz_endpoint`
/// v5: a user is an endpoint in its own right there, `Invite-Format:
/// endpoint` with the URI `<user>@<account>`, which the switch expands to
/// whatever that user has registered. One object comes back, so every rule
/// that belongs to a *device* is read off the user's document instead --
/// and `exclude_from_queues`, which is how an agent keeps one phone out of
/// the queues, is exactly such a rule. Built a device at a time the
/// device's own settings decide, which is what a queue needs and what v4
/// did all along.
///
/// A device that will not build is left out rather than failing the rest:
/// one phone on do-not-disturb must not stop the agent's others ringing.
///
/// `properties` are `kz_endpoint:build/3`'s. `source` is the one that
/// matters here: it names the application ringing, and a call forward set
/// to `direct_calls_only` refuses everything that is not a direct call.
pub fn build_for_owned_devices(
  call: Call,
  account_db: String,
  owner_id: String,
  properties: Value,
) -> List(Value) {
  owned_by(account_db, owner_id, "device")
  |> list.flat_map(fn(device_id) {
    case build_with(call, device_id, properties) {
      Ok(built) -> built
      Error(_reason) -> []
    }
  })
}

/// The ids of everything of one kind a user owns: `device`, `vmbox`,
/// `callflow`. A database read, with no call and no endpoint building.
@external(erlang, "kazoo_gleam_endpoint_ffi", "owned_by")
pub fn owned_by(
  account_db: String,
  owner_id: String,
  kind: String,
) -> List(String)

fn to_result(
  answer: Result(List(Dynamic), String),
) -> Result(List(Value), Error) {
  answer
  |> result.map(list.map(_, doc.from_dynamic))
  |> result.map_error(to_error)
}

@external(erlang, "kazoo_gleam_endpoint_ffi", "build")
fn ffi_build(call: Call, id: String) -> Result(List(Dynamic), String)

@external(erlang, "kazoo_gleam_endpoint_ffi", "build_with")
fn ffi_build_with(
  call: Call,
  id: String,
  properties_json: String,
) -> Result(List(Dynamic), String)

@external(erlang, "kazoo_gleam_endpoint_ffi", "by_owner")
fn ffi_by_owner(call: Call, owner_id: String) -> Result(List(Dynamic), String)
