//// The typed views of the Kazoo documents, and the check-sync notify.

import gleam/option.{None, Some}
import kazoo/accounts
import kazoo/devices
import kazoo/doc
import kazoo/kazoo
import kazoo/switch
import kazoo/testing/fake.{type Fake}
import kazoo/users

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const parent = "1a2b3c4d5e6f708192a3b4c5d6e7f809"

const device = "9a8b7c6d5e4f30211f2e3d4c5b6a7988"

const owner = "00000000000000000000000000000001"

fn setup() -> #(Fake, kazoo.Kazoo) {
  let fake = fake.new()
  fake.put_account(fake, parent, "reseller.example.com", [])
  fake.put_account(fake, account, "acme.example.com", [parent])
  #(fake, fake.kazoo(fake))
}

pub fn account_view_test() {
  let #(fake, kz) = setup()

  let assert Ok(found) = accounts.fetch(kz, account)
  assert found.realm == Some("acme.example.com")
  assert found.tree == [parent]
  assert found.enabled
  assert !found.superduper

  assert accounts.realm(kz, account) == Ok("acme.example.com")
  assert accounts.tree(kz, account) == Ok([parent])
  // The chain the settings layers are applied in: ancestors root first, then
  // the account itself.
  assert accounts.chain(kz, account) == Ok([parent, account])
  assert accounts.parent(kz, account) == Some(parent)
  assert accounts.parent(kz, parent) == None
  assert !accounts.is_superduper_admin(kz, account)

  fake.make_superduper(fake, account)
  assert accounts.is_superduper_admin(kz, account)
}

pub fn device_view_test() {
  let #(fake, kz) = setup()
  fake.put_device(fake, account, device, "805ec004b3d7", [
    #("name", doc.String("Reception")),
    #("owner_id", doc.String(owner)),
    #(
      "sip",
      doc.object([
        #("username", doc.String("5f3a1c")),
        #("password", doc.String("7Hq2xM9pLw")),
        #("expire_seconds", doc.Int(360)),
      ]),
    ),
    #(
      "media",
      doc.object([
        #(
          "audio",
          doc.object([
            #("codecs", doc.List([doc.String("PCMU"), doc.String("G722")])),
          ]),
        ),
        #(
          "encryption",
          doc.object([#("methods", doc.List([doc.String("zrtp")]))]),
        ),
      ]),
    ),
    #(
      "provision",
      doc.object([
        #("endpoint_brand", doc.String("yealink")),
        #("endpoint_family", doc.String("ft4")),
        #("endpoint_model", doc.String("T46S")),
      ]),
    ),
  ])

  let assert Ok(found) = devices.fetch(kz, account, device)
  assert found.mac == Some("805ec004b3d7")
  // A document written by something other than Kazoo may carry separators.
  assert devices.from_doc(
      device,
      doc.object([#("mac_address", doc.String("80:5E:C0:04:B3:D7"))]),
    ).mac
    == Some("805ec004b3d7")
  assert found.owner_id == Some(owner)
  assert found.sip_username == Some("5f3a1c")
  assert found.sip_expire_seconds == Some(360)
  assert found.codecs == ["PCMU", "G722"]
  assert found.encryption_methods == ["zrtp"]
  assert found.brand == Some("yealink")
  assert found.family == Some("t4")
  assert found.model == Some("t46s")

  // The account's own view answers when only a MAC is known.
  let assert Ok(by_mac) = devices.find_by_mac(kz, account, "805ec004b3d7")
  assert by_mac.id == device
  assert devices.find_by_mac(kz, account, "000000000000")
    == Error(kazoo.NotFound)
}

/// A device is provisioned only when the device, its owner and its account
/// are all enabled, and the display name falls back device to owner to
/// account.
pub fn enabled_and_display_name_test() {
  let #(fake, kz) = setup()
  fake.put_device(fake, account, device, "805ec004b3d7", [])
  fake.put_doc(
    fake,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(owner)),
      #("pvt_type", doc.String("user")),
      #("first_name", doc.String("Jane")),
      #("last_name", doc.String("Doe")),
      #("presence_id", doc.String("1001")),
    ]),
  )

  let assert Ok(found) = devices.fetch(kz, account, device)
  let assert Ok(user) = users.fetch(kz, account, owner)
  let assert Ok(acct) = accounts.fetch(kz, account)

  assert users.name(user) == Some("Jane Doe")
  assert users.presence_id(user) == Some("1001")

  // No name on the device: the owner's name is used.
  assert devices.display_name(found, Some(user), acct) == Some("Jane Doe")
  // No owner either: the account's.
  assert devices.display_name(found, None, acct) == Some("Account " <> account)

  assert devices.is_enabled(found, Some(user), acct)

  let disabled = devices.Device(..found, enabled: False)
  assert !devices.is_enabled(disabled, Some(user), acct)

  let disabled_owner = users.User(..user, enabled: False)
  assert !devices.is_enabled(found, Some(disabled_owner), acct)
}

/// The check-sync notify, with the reboot and reload suffixes
/// `provisioner_util:check_sync_event/2` appends.
pub fn resync_test() {
  let #(fake, kz) = setup()
  fake.put_device(fake, account, device, "805ec004b3d7", [
    #("sip", doc.object([#("username", doc.String("5f3a1c"))])),
  ])
  let assert Ok(found) = devices.fetch(kz, account, device)
  let assert Ok(acct) = accounts.fetch(kz, account)

  let assert Ok(sync) = switch.resync(kz, found, acct, Some(True))
  assert sync.event == "check-sync;reboot=true"
  assert sync.realm == "acme.example.com"
  assert sync.username == "5f3a1c"

  let assert Ok(sync) = switch.resync(kz, found, acct, Some(False))
  assert sync.event == "check-sync;reboot=false"

  let assert Ok(sync) = switch.resync(kz, found, acct, None)
  assert sync.event == "check-sync"

  assert fake.notifies(fake)
    == [
      fake.Notify(
        event: "check-sync;reboot=true",
        realm: "acme.example.com",
        username: "5f3a1c",
      ),
      fake.Notify(
        event: "check-sync;reboot=false",
        realm: "acme.example.com",
        username: "5f3a1c",
      ),
      fake.Notify(
        event: "check-sync",
        realm: "acme.example.com",
        username: "5f3a1c",
      ),
    ]

  // A device with its own event and suffixes overrides the defaults.
  fake.put_device(fake, account, device, "805ec004b3d7", [
    #("sip", doc.object([#("username", doc.String("5f3a1c"))])),
    #(
      "provision",
      doc.object([
        #("check_sync_event", doc.String("resync")),
        #("check_sync_reboot", doc.String("reboot=1")),
      ]),
    ),
  ])
  let assert Ok(found) = devices.fetch(kz, account, device)
  let assert Ok(sync) = switch.resync(kz, found, acct, Some(True))
  assert sync.event == "resync;reboot=1"

  // A device with no SIP username has nothing to notify.
  let nameless = devices.Device(..found, sip_username: None)
  assert switch.resync(kz, nameless, acct, None)
    == Error(kazoo.Invalid("no_sip_username"))
}
