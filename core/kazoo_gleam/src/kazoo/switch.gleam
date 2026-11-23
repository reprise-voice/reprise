//// Telling a handset to fetch its configuration again.
////
//// The message is the one `provisioner_util:send_check_sync/5` publishes: a
//// `kapi_switch` notify carrying `Event`, `Realm` and `Username`, which
//// `ecallmgr_fs_notify` turns into a SIP NOTIFY to the device's registration.
//// Nothing reaches a handset that is not registered, and that is not an
//// error: the response says so.

import gleam/option.{type Option, None, Some}
import kazoo/accounts.{type Account}
import kazoo/devices.{type Device}
import kazoo/kazoo.{type Error, type Kazoo}

/// Crossbar's own category and key for the event name, so a cluster that has
/// changed it changes it for this application too.
const crossbar_devices = "crossbar.devices"

const check_sync_event = "check_sync_event"

const default_event = "check-sync"

pub type Sync {
  Sync(event: String, realm: String, username: String)
}

/// Publish a check-sync for one device. `reboot` chooses the `reboot=true` or
/// `reboot=false` suffix; `None` sends the bare event.
pub fn resync(
  kz: Kazoo,
  device: Device,
  account: Account,
  reboot: Option(Bool),
) -> Result(Sync, Error) {
  let configured =
    kz.config.get_string_in(crossbar_devices, check_sync_event, default_event)
  let event = devices.check_sync_event(Some(device), reboot, configured)
  case device.sip_username, devices.realm(device, account) {
    Some(username), Some(realm) -> {
      let sync = Sync(event: event, realm: realm, username: username)
      case kz.switch.check_sync(event, realm, username) {
        Ok(Nil) -> Ok(sync)
        Error(error) -> Error(error)
      }
    }
    None, _ -> Error(kazoo.Invalid("no_sip_username"))
    _, None -> Error(kazoo.Invalid("no_realm"))
  }
}
