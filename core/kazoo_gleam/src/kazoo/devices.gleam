//// Device documents: the MAC, the SIP credentials and everything under
//// `provision`.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/accounts.{type Account}
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}
import kazoo/users.{type User}

/// The view every account database has over its devices, and the only place
/// a MAC address can be looked up inside an account.
pub const listing_by_macaddress = "devices/listing_by_macaddress"

pub type Device {
  Device(
    id: String,
    name: Option(String),
    mac: Option(String),
    enabled: Bool,
    owner_id: Option(String),
    presence_id: Option(String),
    timezone: Option(String),
    sip_username: Option(String),
    sip_password: Option(String),
    sip_realm: Option(String),
    sip_expire_seconds: Option(Int),
    codecs: List(String),
    encryption_methods: List(String),
    brand: Option(String),
    family: Option(String),
    model: Option(String),
    doc: Value,
  )
}

pub fn fetch(
  kz: Kazoo,
  account_id: String,
  device_id: String,
) -> Result(Device, Error) {
  use value <- result.try(kz.datamgr.open_cache_doc(
    kazoo.account_db(account_id),
    device_id,
  ))
  Ok(from_doc(device_id, value))
}

/// The account's device with this MAC, through the view every account
/// database has. Used where only a MAC is known: a `provisioner_v5` push, for
/// one, carries no device id.
///
/// The view emits `mac_address` as the document stores it, and Kazoo stores
/// it cleansed (`kzd_devices:set_mac_address/2`), so the key is the cleansed
/// form. A document written by something else, with separators in the MAC,
/// is not found by this and has to be matched by scanning.
pub fn find_by_mac(
  kz: Kazoo,
  account_id: String,
  mac: String,
) -> Result(Device, Error) {
  use mac <- result.try(valid_mac(mac) |> result.replace_error(kazoo.NotFound))
  use rows <- result.try(kz.datamgr.get_results(
    kazoo.account_db(account_id),
    listing_by_macaddress,
    kazoo.view_options() |> kazoo.with_key(doc.String(mac)) |> kazoo.with_docs,
  ))
  case rows {
    [] -> Error(kazoo.NotFound)
    [row, ..] ->
      case doc.get(row, ["doc"]) {
        Ok(document) ->
          Ok(from_doc(
            doc.get_string(document, ["_id"]) |> result.unwrap(""),
            document,
          ))
        Error(_) -> Error(kazoo.NotFound)
      }
  }
}

pub fn from_doc(device_id: String, value: Value) -> Device {
  Device(
    id: device_id,
    name: string_at(value, ["name"]),
    mac: doc.get_string(value, ["mac_address"])
      |> result.try(cleanse_mac)
      |> option.from_result,
    enabled: doc.get_bool(value, ["enabled"]) |> result.unwrap(True),
    owner_id: string_at(value, ["owner_id"]),
    presence_id: string_at(value, ["presence_id"]),
    timezone: string_at(value, ["timezone"]),
    sip_username: string_at(value, ["sip", "username"]),
    sip_password: string_at(value, ["sip", "password"]),
    sip_realm: string_at(value, ["sip", "realm"]),
    sip_expire_seconds: doc.get_int(value, ["sip", "expire_seconds"])
      |> option.from_result,
    codecs: doc.strings(value, ["media", "audio", "codecs"]),
    encryption_methods: doc.strings(value, ["media", "encryption", "methods"]),
    brand: string_at(value, ["provision", "endpoint_brand"]),
    family: family(value),
    model: string_at(value, ["provision", "endpoint_model"])
      |> option.map(string.lowercase),
    doc: value,
  )
}

fn string_at(value: Value, path: List(String)) -> Option(String) {
  case doc.get_string(value, path) {
    Ok("") -> None
    Ok(text) -> Some(text)
    Error(_) -> None
  }
}

/// `provisioner_v5:get_family/1` strips a leading `f`, a hangover from older
/// monster-ui documents.
fn family(value: Value) -> Option(String) {
  case string_at(value, ["provision", "endpoint_family"]) {
    Some(family) ->
      case string.starts_with(family, "f") {
        True -> Some(string.drop_start(family, 1))
        False -> Some(family)
      }
    None -> None
  }
}

/// `provision.combo_keys` and `provision.feature_keys` as stored.
pub fn combo_keys(device: Device) -> Value {
  doc.get(device.doc, ["provision", "combo_keys"])
  |> result.unwrap(doc.object([]))
}

pub fn feature_keys(device: Device) -> Value {
  doc.get(device.doc, ["provision", "feature_keys"])
  |> result.unwrap(doc.object([]))
}

/// A MAC address as Kazoo stores it: lowercase hex, no separators. The same
/// transformation `kz_network_utils:cleanse_mac_address/1` applies.
pub fn cleanse_mac(mac: String) -> Result(String, Nil) {
  let hex =
    mac
    |> string.lowercase
    |> string.to_graphemes
    |> list.filter(is_hex_character)
    |> string.concat
  case hex {
    "" -> Error(Nil)
    _ -> Ok(hex)
  }
}

/// A MAC that can identify a handset: twelve hex characters, as the contract
/// and the index require.
pub fn valid_mac(mac: String) -> Result(String, Nil) {
  case cleanse_mac(mac) {
    Ok(hex) ->
      case string.length(hex) {
        12 -> Ok(hex)
        _ -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn is_hex_character(character: String) -> Bool {
  case character {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    "a" | "b" | "c" | "d" | "e" | "f" -> True
    _ -> False
  }
}

/// A device is provisioned only when the device, its owner and its account
/// are all enabled, exactly as `provisioner_v5:is_device_enabled/3` decides.
pub fn is_enabled(
  device: Device,
  owner: Option(User),
  account: Account,
) -> Bool {
  let owner_enabled = case owner {
    Some(user) -> user.enabled
    None -> True
  }
  device.enabled && owner_enabled && account.enabled
}

/// Display name: the device's, else the owner's, else the account's, as
/// `provisioner_v5:device_display_name/3` picks it.
pub fn display_name(
  device: Device,
  owner: Option(User),
  account: Account,
) -> Option(String) {
  let candidates = [
    device.name,
    option.then(owner, users.name),
    account.name,
  ]
  candidates
  |> list.filter_map(fn(candidate) {
    case candidate {
      Some(name) ->
        case string.trim(name) {
          "" -> Error(Nil)
          trimmed -> Ok(trimmed)
        }
      None -> Error(Nil)
    }
  })
  |> list.first
  |> option.from_result
}

/// The realm the handset registers into: the device's `sip.realm`, else the
/// document's own `realm`, else the account's.
pub fn realm(device: Device, account: Account) -> Option(String) {
  case device.sip_realm {
    Some(realm) -> Some(realm)
    None ->
      case string_at(device.doc, ["realm"]) {
        Some(realm) -> Some(realm)
        None -> account.realm
      }
  }
}

/// The `Event` of the check-sync NOTIFY, with the reboot or reload suffix,
/// the way `provisioner_util:check_sync_event/2` builds it.
pub fn check_sync_event(
  device: Option(Device),
  reboot: Option(Bool),
  configured_event: String,
) -> String {
  case device {
    None -> configured_event
    Some(device) -> {
      let event =
        string_at(device.doc, ["provision", "check_sync_event"])
        |> option.unwrap(configured_event)
      case reboot {
        None -> event
        Some(True) ->
          event
          <> ";"
          <> option.unwrap(
            string_at(device.doc, ["provision", "check_sync_reboot"]),
            "reboot=true",
          )
        Some(False) ->
          event
          <> ";"
          <> option.unwrap(
            string_at(device.doc, ["provision", "check_sync_reload"]),
            "reboot=false",
          )
      }
    }
  }
}
