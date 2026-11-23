//// The key store over the fake: creating, importing, the certificate,
//// the status transitions, listing, selection, opening, and a rotation.
////
//// `test-key.pem` and `test-cert.pem` are a P-256 key generated for the
//// tests and a self-signed certificate over it with a TNAuthList for
//// `TEST`; `example-999Y-chain.pem` is a certificate over another key.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo
import kazoo/modb
import kazoo/testing/fake
import stir/credentials
import stir/key
import stir/keys
import stir/secret
import stir/system
import stir/vault

const gregorian = 62_167_219_200

/// The fake's clock, as Gregorian seconds.
const now = 63_924_619_200

const base = "https://api.example/v2/stir/certs"

/// The application's own views, as `priv/couchdb/views/stir.json` emits
/// them.
fn views() -> List(fake.View) {
  [key_view(), credential_view()]
}

/// `keys_by_scope` as the design document emits it: the key is
/// `[scope, status]`, the value the metadata `key.from_doc` needs and
/// never the material. Shared with every test that lists keys.
pub fn key_view() -> fake.View {
  fake.Valued(
    name: keys.view,
    doc_type: key.doc_type,
    key: fn(document) {
      case
        doc.get_string(document, ["scope"]),
        doc.get_string(document, ["status"])
      {
        Ok(scope), Ok(status) ->
          Ok(doc.List([doc.String(scope), doc.String(status)]))
        _, _ -> Error(Nil)
      }
    },
    value: fn(document) { picked(document, key_value_fields) },
  )
}

/// The members `keys_by_scope` emits, in the design document's order.
const key_value_fields = [
  "scope", "status", "spc", "alg", "x5u", "not_before", "not_after", "source",
  "fingerprint", "kek", "history",
]

/// The members `credentials_by_name` emits.
const credential_value_fields = ["name", "set_at", "by", "kek"]

/// `credentials_by_name` as the design document emits it.
pub fn credential_view() -> fake.View {
  fake.Valued(
    name: credentials.view,
    doc_type: credentials.doc_type,
    key: fn(document) {
      doc.get_string(document, ["name"]) |> result.map(doc.String)
    },
    value: fn(document) { picked(document, credential_value_fields) },
  )
}

/// The fake's view values are the design document's: the names each map
/// function in `priv/couchdb/views/stir.json` emits are the names the
/// fake picks, so a field added to one and not the other fails here
/// rather than as a listing that quietly lacks it.
pub fn the_fake_emits_what_the_design_document_emits_test() {
  let assert Ok(bytes) = read_file("priv/couchdb/views/stir.json")
  let assert Ok(text) = bit_array.to_string(bytes)
  let assert Ok(design) = doc.parse(text)
  assert emitted(design, "keys_by_scope") == key_value_fields
  assert emitted(design, "credentials_by_name") == credential_value_fields
}

/// The members a view's map function emits: the single-quoted name on
/// each `'name': doc.name` line of it.
fn emitted(design: doc.Value, view: String) -> List(String) {
  doc.strings(design, ["views", view, "map"])
  |> list.filter_map(fn(line) {
    case string.contains(line, "': doc.") {
      True ->
        case string.split(line, "'") {
          [_, name, ..] -> Ok(name)
          _ -> Error(Nil)
        }
      False -> Error(Nil)
    }
  })
}

/// The members of `document` under `names`, those it has.
fn picked(document: doc.Value, names: List(String)) -> doc.Value {
  names
  |> list.filter_map(fn(name) {
    doc.get(document, [name]) |> result.map(fn(value) { #(name, value) })
  })
  |> doc.object
}

fn new() -> #(fake.Fake, kazoo.Kazoo) {
  let f = fake.new_with_views(views())
  // The design document itself, which is how the store tells a store with
  // no keys from a database whose views were never registered.
  fake.put_doc(
    f,
    system.category,
    doc.object([#("_id", doc.String(keys.design_document))]),
  )
  #(f, fake.kazoo(f))
}

/// A record whose saves of one document fail, for the leg of an
/// activation that is allowed to fail.
fn save_fails_for(kz: kazoo.Kazoo, kid: String) -> kazoo.Kazoo {
  kazoo.Kazoo(
    ..kz,
    datamgr: kazoo.Datamgr(..kz.datamgr, save_doc: fn(db, document) {
      case doc.get_string(document, ["_id"]) == Ok(kid) {
        True -> Error(kazoo.Unavailable)
        False -> kz.datamgr.save_doc(db, document)
      }
    }),
  )
}

fn kek() -> vault.Vault {
  let assert Ok(loaded) = vault.from_bytes(random_bytes(32))
  loaded
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn test_key() -> secret.Secret {
  secret.new("test key", bit_array.from_string(fixture("test-key.pem")))
}

fn import_test_key(kz: kazoo.Kazoo, sealer: vault.Vault) -> key.Key {
  let assert Ok(imported) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      test_key(),
      fixture("test-cert.pem"),
      "TEST",
      base,
      "sup",
    )
  imported
}

fn text(s: secret.Secret) -> String {
  let assert Ok(t) = secret.with(s, bit_array.to_string)
  t
}

pub fn create_test() {
  let #(f, kz) = new()
  let sealer = kek()
  let assert Ok(#(created, csr)) =
    keys.create(
      kz,
      sealer,
      key.System,
      "999Y",
      "Example Telecom",
      base <> "/",
      "m/u",
    )

  assert string.length(created.kid) == 16
  assert string.lowercase(created.kid) == created.kid
  assert created.scope == key.System
  assert created.status == key.Csr
  assert created.source == key.Issued
  assert created.spc == "999Y"
  assert created.alg == "ES256"
  assert created.x5u == base <> "/" <> created.kid <> ".pem"
  assert created.not_before == None
  assert created.not_after == None
  assert created.fingerprint == None
  assert created.kek == Some(vault.id(sealer))
  assert created.history == [key.Event(at: now, what: "created", by: "m/u")]

  assert string.starts_with(csr, "-----BEGIN CERTIFICATE REQUEST-----\n")
  assert string.ends_with(csr, "-----END CERTIFICATE REQUEST-----\n")
  assert keys.csr_pem(kz, created.kid) == Ok(csr)
  // No certificate yet.
  assert keys.certificate_pem(kz, created.kid) == Error(keys.NotFound)

  // The document: a key, with its public key and no private one.
  let assert Ok(stored) = fake.lookup(f, system.category, created.kid)
  assert key.from_doc(stored) == Ok(created)
  let assert Ok(public_key) = doc.get_string(stored, ["public_key"])
  assert string.starts_with(public_key, "-----BEGIN PUBLIC KEY-----\n")
  assert !contains(doc.to_string(stored), "PRIVATE")

  assert keys.get(kz, created.kid) == Ok(created)
  assert keys.list(kz) == Ok([created])
  assert keys.get(kz, "nope") == Error(keys.NotFound)

  // The private key opens under the vault that sealed it and no other.
  let assert Ok(opened) = keys.unseal(kz, sealer, created.kid)
  assert string.starts_with(text(opened), "-----BEGIN PRIVATE KEY-----\n")
  assert keys.unseal(kz, kek(), created.kid) == Error(keys.Unsealable)
  assert keys.unseal(kz, sealer, "nope") == Error(keys.NotFound)

  // Two keys differ.
  let assert Ok(#(other, _)) =
    keys.create(
      kz,
      sealer,
      key.Account("a1"),
      "999Y",
      "Example Telecom",
      base,
      "m/u",
    )
  assert other.kid != created.kid
  assert other.scope == key.Account("a1")

  // An SPC the CSR cannot carry.
  let assert Error(keys.Crypto(_)) =
    keys.create(kz, sealer, key.System, "", "Example Telecom", base, "m/u")
  // No organization: there is no default to fall back on.
  assert keys.create(kz, sealer, key.System, "999Y", "  ", base, "m/u")
    == Error(keys.Crypto("organization is empty"))
  assert keys.list(kz) |> result.map(list.length) == Ok(2)
}

/// A key file and its chain in one file is a common way to hold them, and
/// `import_key bundle.pem bundle.pem ...` is how an operator would pass
/// it. The chain is served at a public URL, so only its certificates are
/// stored, and a document written before that rule serves only its
/// certificates too.
pub fn only_the_certificates_are_stored_and_served_test() {
  let #(f, kz) = new()
  let sealer = kek()
  let bundle = fixture("test-key.pem") <> fixture("test-cert.pem")
  let assert Ok(imported) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      test_key(),
      bundle,
      "TEST",
      base,
      "sup",
    )
  let assert Ok(stored) = fake.lookup(f, system.category, imported.kid)
  assert !contains(doc.to_string(stored), "PRIVATE")
  assert doc.get_string(stored, [key.certificate_field])
    == Ok(fixture("test-cert.pem"))
  assert keys.certificate_pem(kz, imported.kid) == Ok(fixture("test-cert.pem"))

  // A document that already holds more than certificates.
  fake.put_doc(
    f,
    system.category,
    doc.set(stored, [key.certificate_field], doc.String(bundle)),
  )
  let assert Ok(served) = keys.certificate_pem(kz, imported.kid)
  assert served == fixture("test-cert.pem")
  assert !contains(served, "PRIVATE")
}

pub fn attach_certificate_test() {
  let #(_, kz) = new()
  let sealer = kek()
  let assert Ok(#(created, _)) =
    keys.create(kz, sealer, key.System, "TEST", "Example Telecom", base, "m/u")

  // A certificate over another key.
  let assert Error(keys.CertificateMismatch(why)) =
    keys.attach_certificate(
      kz,
      created.kid,
      fixture("example-999Y-chain.pem"),
      "m/u",
    )
  // The example SHAKEN certificate is for 999Y, not TEST: the SPC is what fails
  // first for it.
  assert string.contains(why, "SPC")
  // Not a certificate at all.
  let assert Error(keys.CertificateMismatch(_)) =
    keys.attach_certificate(kz, created.kid, "hello", "m/u")
  assert keys.attach_certificate(kz, "nope", fixture("test-cert.pem"), "m/u")
    == Error(keys.NotFound)

  // The right SPC over the wrong key.
  let assert Ok(#(other, _)) =
    keys.create(kz, sealer, key.System, "TEST", "Example Telecom", base, "m/u")
  let assert Error(keys.CertificateMismatch(why)) =
    keys.attach_certificate(kz, other.kid, fixture("test-cert.pem"), "m/u")
  assert why == "the certificate does not belong to the key"
  let assert Ok(still) = keys.get(kz, other.kid)
  assert still.status == key.Csr

  // The fixture certificate is over the fixture key, so the matching case
  // goes through `import_key`; a generated key's certificate would need a
  // CA. The status rule is checked on an imported (pending) key.
  let imported = import_test_key(kz, sealer)
  assert keys.attach_certificate(
      kz,
      imported.kid,
      fixture("test-cert.pem"),
      "m/u",
    )
    == Error(keys.InvalidTransition)
}

pub fn import_key_test() {
  let #(f, kz) = new()
  let sealer = kek()
  let imported = import_test_key(kz, sealer)

  assert imported.status == key.Pending
  assert imported.source == key.Imported
  assert imported.scope == key.System
  assert imported.spc == "TEST"
  assert imported.x5u == base <> "/" <> imported.kid <> ".pem"
  assert imported.kek == Some(vault.id(sealer))
  assert imported.history == [key.Event(at: now, what: "imported", by: "sup")]
  let assert Some(fingerprint) = imported.fingerprint
  assert string.starts_with(fingerprint, "sha256:")
  assert string.length(fingerprint) == 7 + 64
  let assert Some(not_before) = imported.not_before
  let assert Some(not_after) = imported.not_after
  assert not_before > gregorian
  assert not_after > not_before
  let assert Some(days) = key.days_left(imported, now)
  assert days > 0

  // The certificate is served; the private key is the file's bytes.
  assert keys.certificate_pem(kz, imported.kid) == Ok(fixture("test-cert.pem"))
  assert keys.csr_pem(kz, imported.kid) == Error(keys.NotFound)
  let assert Ok(opened) = keys.unseal(kz, sealer, imported.kid)
  assert text(opened) == fixture("test-key.pem")
  assert secret.label(opened) == "private key " <> imported.kid

  let assert Ok(stored) = fake.lookup(f, system.category, imported.kid)
  assert !contains(doc.to_string(stored), "PRIVATE")
  assert doc.get_string(stored, ["public_key"])
    == Ok(fixture("test-key-pub.pem"))

  // A chain that is not over the key, the wrong SPC, no certificate.
  let assert Error(keys.CertificateMismatch(_)) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      test_key(),
      fixture("example-999Y-chain.pem"),
      "999Y",
      base,
      "sup",
    )
  let assert Error(keys.CertificateMismatch(why)) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      test_key(),
      fixture("test-cert.pem"),
      "999Y",
      base,
      "sup",
    )
  assert why == "the certificate is not for SPC 999Y (it carries TEST)"
  let assert Error(keys.CertificateMismatch(_)) =
    keys.import_key(kz, sealer, key.System, test_key(), "", "TEST", base, "sup")
  let assert Error(keys.CertificateMismatch(_)) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      secret.new("nope", <<"nope">>),
      fixture("test-cert.pem"),
      "TEST",
      base,
      "sup",
    )
}

pub fn activate_retire_delete_test() {
  let #(f, kz) = new()
  let sealer = kek()
  let first = import_test_key(kz, sealer)
  let second = import_test_key(kz, sealer)
  let assert Ok(#(unsigned, _)) =
    keys.create(kz, sealer, key.System, "TEST", "Example Telecom", base, "m/u")

  // Only pending (or retired) keys activate.
  assert keys.activate(kz, unsigned.kid, "m/u") == Error(keys.InvalidTransition)
  assert keys.activate(kz, "nope", "m/u") == Error(keys.NotFound)
  assert keys.retire(kz, first.kid, "m/u") == Error(keys.InvalidTransition)
  assert keys.active(kz, key.System) == Ok(None)

  let assert Ok(activated) = keys.activate(kz, first.kid, "m/u")
  assert activated.status == key.Active
  assert list.map(activated.history, fn(e) { e.what })
    == ["imported", "activated"]
  assert keys.active(kz, key.System) == Ok(Some(activated))
  assert keys.activate(kz, first.kid, "m/u") == Error(keys.InvalidTransition)

  // Activating another key of the scope retires the first.
  let assert Ok(promoted) = keys.activate(kz, second.kid, "m/u2")
  assert promoted.status == key.Active
  let assert Ok(demoted) = keys.get(kz, first.kid)
  assert demoted.status == key.Retired
  assert list.map(demoted.history, fn(e) { e.what })
    == ["imported", "activated", "retired, superseded by " <> second.kid]
  let assert Ok(key.Event(by: "m/u2", ..)) = list.last(demoted.history)
  assert keys.active(kz, key.System) == Ok(Some(promoted))

  // A retired key can be brought back, which retires the current one.
  let assert Ok(restored) = keys.activate(kz, first.kid, "m/u")
  assert restored.status == key.Active
  let assert Ok(second_now) = keys.get(kz, second.kid)
  assert second_now.status == key.Retired

  // Retire.
  let assert Ok(retired) = keys.retire(kz, first.kid, "m/u")
  assert retired.status == key.Retired
  assert keys.active(kz, key.System) == Ok(None)
  let assert Ok(key.Event(what: "retired", by: "m/u", ..)) =
    list.last(retired.history)

  // Delete: anything but active.
  let assert Ok(_) = keys.activate(kz, second.kid, "m/u")
  assert keys.delete(kz, second.kid, "m/u") == Error(keys.InvalidTransition)
  assert keys.delete(kz, "nope", "m/u") == Error(keys.NotFound)
  assert keys.delete(kz, first.kid, "m/u") == Ok(Nil)
  assert keys.get(kz, first.kid) == Error(keys.NotFound)
  assert fake.lookup(f, system.category, first.kid) == Error(kazoo.NotFound)
  assert keys.unseal(kz, sealer, first.kid) == Error(keys.NotFound)
  assert keys.delete(kz, unsigned.kid, "m/u") == Ok(Nil)
  assert keys.csr_pem(kz, unsigned.kid) == Error(keys.NotFound)
  let assert Ok(remaining) = keys.list(kz)
  assert list.map(remaining, fn(k) { k.kid }) == [second.kid]
}

/// Activation is per scope: an account's key does not retire the system's.
pub fn scopes_are_independent_test() {
  let #(_, kz) = new()
  let sealer = kek()
  let system_key = import_test_key(kz, sealer)
  let assert Ok(_) = keys.activate(kz, system_key.kid, "m/u")
  // No import into an account scope exists, so promote a created key by
  // writing its certificate state the way the store would: through the
  // document, as the monitor's ACME path will. Here: import, then move.
  let #(f2, kz2) = new()
  let account_key = import_test_key(kz2, sealer)
  let assert Ok(stored) = fake.lookup(f2, system.category, account_key.kid)
  fake.put_doc(
    f2,
    system.category,
    doc.set(stored, ["scope"], doc.String("a1")),
  )
  let system_key2 = import_test_key(kz2, sealer)
  let assert Ok(_) = keys.activate(kz2, system_key2.kid, "m/u")
  let assert Ok(_) = keys.activate(kz2, account_key.kid, "m/u")
  let assert Ok(Some(still)) = keys.active(kz2, key.System)
  assert still.kid == system_key2.kid
  let assert Ok(Some(account_active)) = keys.active(kz2, key.Account("a1"))
  assert account_active.kid == account_key.kid
  let assert Ok(all) = keys.list(kz2)
  assert list.length(all) == 2
}

pub fn select_test() {
  // The cache is the node's, not the fake's: another test's system key
  // must not answer this one's.
  keys.forget_selection()
  let #(f, kz) = new()
  let sealer = kek()
  // master > r1 > a1; a2 is under master directly; a9 does not exist.
  fake.put_account(f, "master", "master.example", [])
  fake.put_account(f, "r1", "r1.example", ["master"])
  fake.put_account(f, "a1", "a1.example", ["master", "r1"])
  fake.put_account(f, "a2", "a2.example", ["master"])

  // No key anywhere.
  assert selected(kz, "a1") == Ok(None)

  // The system key, once active, is everyone's. `select` is cached for
  // 30 s, so the answers are read with the cache cleared by the
  // activation itself.
  let system_key = import_test_key(kz, sealer)
  let assert Ok(active_system) = keys.activate(kz, system_key.kid, "m/u")
  assert selected(kz, "a1") == Ok(Some(active_system.kid))
  assert selected(kz, "a2") == Ok(Some(active_system.kid))
  assert selected(kz, "a9") == Ok(Some(active_system.kid))

  let reseller_key = import_test_key(kz, sealer)
  let assert Ok(stored) = fake.lookup(f, system.category, reseller_key.kid)
  fake.put_doc(f, system.category, doc.set(stored, ["scope"], doc.String("r1")))
  let assert Ok(active_reseller) = keys.activate(kz, reseller_key.kid, "m/u")
  assert active_reseller.scope == key.Account("r1")

  // With `allow_account_keys` off -- the default -- an account key is
  // not looked for at all: every account signs under the system key,
  // and the chain is not walked for a key that may not be created.
  assert selected(kz, "a1") == Ok(Some(active_system.kid))
  assert selected(kz, "r1") == Ok(Some(active_system.kid))

  // With account keys allowed, a reseller's key covers its subtree and
  // nothing else.
  fake.put_config(f, "allow_account_keys", doc.String("true"))
  keys.forget_selection()
  assert selected(kz, "a1") == Ok(Some(active_reseller.kid))
  assert selected(kz, "r1") == Ok(Some(active_reseller.kid))
  assert selected(kz, "a2") == Ok(Some(active_system.kid))
  assert selected(kz, "master") == Ok(Some(active_system.kid))

  // The account's own key wins over the reseller's.
  let account_key = import_test_key(kz, sealer)
  let assert Ok(stored) = fake.lookup(f, system.category, account_key.kid)
  fake.put_doc(f, system.category, doc.set(stored, ["scope"], doc.String("a1")))
  let assert Ok(active_account) = keys.activate(kz, account_key.kid, "m/u")
  assert selected(kz, "a1") == Ok(Some(active_account.kid))
  assert selected(kz, "r1") == Ok(Some(active_reseller.kid))

  // Retiring invalidates the cache.
  let assert Ok(_) = keys.retire(kz, account_key.kid, "m/u")
  assert selected(kz, "a1") == Ok(Some(active_reseller.kid))
  let assert Ok(_) = keys.retire(kz, reseller_key.kid, "m/u")
  assert selected(kz, "a1") == Ok(Some(active_system.kid))
  // And so does deleting.
  let assert Ok(_) = keys.retire(kz, system_key.kid, "m/u")
  assert selected(kz, "a1") == Ok(None)
}

pub fn rekey_test() {
  let #(_, kz) = new()
  let old = kek()
  let new = kek()
  let first = import_test_key(kz, old)
  let assert Ok(#(second, _)) =
    keys.create(kz, old, key.System, "TEST", "Example Telecom", base, "m/u")
  let third = import_test_key(kz, new)
  let assert Ok(_) =
    credentials.set(kz, old, "rekey_keys_user", secret.new("u", <<"u">>), "m/u")

  // Two keys and one credential were under `old`.
  assert keys.rekey(kz, old, new) == Ok(3)

  list.each([first.kid, second.kid, third.kid], fn(kid) {
    let assert Ok(resealed) = keys.get(kz, kid)
    assert resealed.kek == Some(vault.id(new))
    let assert Ok(_) = keys.unseal(kz, new, kid)
    assert keys.unseal(kz, old, kid) == Error(keys.Unsealable)
  })
  let assert Ok(opened) = keys.unseal(kz, new, first.kid)
  assert text(opened) == fixture("test-key.pem")
  let assert Ok(resealed) = keys.get(kz, first.kid)
  let assert Ok(key.Event(what: "re-sealed", by: "rekey", ..)) =
    list.last(resealed.history)
  // The one already under `new` was left alone.
  let assert Ok(untouched) = keys.get(kz, third.kid)
  assert untouched.history == third.history
  let assert Ok(_) = credentials.get(kz, new, "rekey_keys_user")

  // Nothing left to do.
  assert keys.rekey(kz, old, new) == Ok(0)

  // A vault that never sealed anything re-seals nothing, and says so key
  // by key rather than stopping at the first one.
  let #(answer, failures) = keys.rekey_report(kz, kek(), old)
  assert answer == Ok(0)
  assert list.length(failures) == 4
  assert list.all(failures, fn(line) {
    string.contains(line, "opens under neither key-encryption key")
  })
  assert list.any(failures, fn(line) { string.contains(line, first.kid) })
  assert list.any(failures, fn(line) {
    string.contains(line, "credential rekey_keys_user")
  })
  // Nothing was written: every key still opens under `new`.
  let assert Ok(_) = keys.unseal(kz, new, first.kid)
}

/// One key that cannot be opened does not stop the keys after it.
pub fn rekey_goes_on_past_a_failure_test() {
  let #(f, kz) = new()
  let old = kek()
  let new = kek()
  let stranger = kek()
  let good = import_test_key(kz, old)
  let bad = import_test_key(kz, stranger)
  // The bad key claims to be under `old`, as a key re-sealed by a pass
  // that was interrupted between the two writes would.
  let assert Ok(stored) = fake.lookup(f, system.category, bad.kid)
  fake.put_doc(
    f,
    system.category,
    doc.set(stored, ["kek"], doc.String(vault.id(old))),
  )

  let #(answer, failures) = keys.rekey_report(kz, old, new)
  assert answer == Ok(1)
  assert list.length(failures) == 1
  let assert [line] = failures
  assert string.contains(line, bad.kid)
  let assert Ok(resealed) = keys.get(kz, good.kid)
  assert resealed.kek == Some(vault.id(new))
  let assert Ok(_) = keys.unseal(kz, new, good.kid)
  // The bad one is left exactly as it was, still openable by whoever
  // holds the key it was sealed under.
  let assert Ok(_) = keys.unseal(kz, stranger, bad.kid)
}

/// A document whose marker says `old` while its private key is sealed
/// under `new` is one somebody edited by hand: the blob and the marker
/// are written in one save, so no pass leaves that behind. It is
/// reported and left alone, not quietly repaired.
pub fn rekey_reports_a_stale_marker_test() {
  let #(f, kz) = new()
  let old = kek()
  let new = kek()
  let already = import_test_key(kz, new)
  let assert Ok(stored) = fake.lookup(f, system.category, already.kid)
  fake.put_doc(
    f,
    system.category,
    doc.set(stored, ["kek"], doc.String(vault.id(old))),
  )

  let #(answer, failures) = keys.rekey_report(kz, old, new)
  assert answer == Ok(0)
  let assert [line] = failures
  assert contains(line, already.kid)
  assert contains(line, "sealed under " <> vault.id(new) <> " already")
  let assert Ok(untouched) = keys.get(kz, already.kid)
  assert untouched.kek == Some(vault.id(old))
  let assert Ok(_) = keys.unseal(kz, new, already.kid)
}

/// A rotation that lists nothing because the design document is not
/// registered must not report that it re-sealed everything.
pub fn rekey_refuses_without_the_view_test() {
  let f = fake.new_with_views(views())
  let kz = fake.kazoo(f)
  // No design document, and so no way to tell an empty store from a
  // database whose views were never registered.
  assert keys.rekey(kz, kek(), kek()) == Error(keys.ViewMissing)

  // With it, an empty store is an empty store.
  fake.put_doc(
    f,
    system.category,
    doc.object([#("_id", doc.String(keys.design_document))]),
  )
  assert keys.rekey(kz, kek(), kek()) == Ok(0)
}

pub fn x5u_of_test() {
  assert keys.x5u_of("https://a/certs", "k") == "https://a/certs/k.pem"
  assert keys.x5u_of("https://a/certs/", "k") == "https://a/certs/k.pem"
}

/// A view that answers no rows is a store with no keys; a view the
/// cluster does not have is `ViewMissing`, so that a status, a listing
/// and a rotation say so instead of reporting an empty store.
pub fn list_without_view_test() {
  let kz = fake.new() |> fake.kazoo
  assert keys.list(kz) == Ok([])
  assert keys.active(kz, key.System) == Ok(None)

  let #(_, kz) = new()
  let missing =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(
        ..kz.datamgr,
        get_results: fn(_db, _view, _options) { Error(kazoo.NotFound) },
      ),
    )
  assert keys.list(missing) == Error(keys.ViewMissing)
  assert keys.active(missing, key.System) == Error(keys.ViewMissing)
  // `select` answers from a node-local cache another test filled, so
  // it is cleared first; the view is what it cannot read.
  keys.forget_selection()
  assert keys.select(missing, "no-view-account") == Error(keys.ViewMissing)
  assert keys.rekey(missing, kek(), kek()) == Error(keys.ViewMissing)
}

/// An activation is refused for a key that cannot sign: one whose
/// certificate has expired, and one whose sealed private key is gone.
pub fn activate_refuses_a_key_that_cannot_sign_test() {
  let #(f, kz) = new()
  let sealer = kek()

  let gone = import_test_key(kz, sealer)
  let assert Ok(stored) = fake.lookup(f, system.category, gone.kid)
  fake.put_doc(
    f,
    system.category,
    doc.delete(stored, [key.sealed_private_key_field]),
  )
  assert keys.activate(kz, gone.kid, "m/u") == Error(keys.NoPrivateKey)
  let assert Ok(still) = keys.get(kz, gone.kid)
  assert still.status == key.Pending

  // The clock moves past the certificate's `not_after`.
  let expired = import_test_key(kz, sealer)
  let assert Some(not_after) = expired.not_after
  fake.set_now(f, modb.to_unix(not_after) + 1)
  assert keys.activate(kz, expired.kid, "m/u") == Error(keys.InvalidTransition)
  let assert Ok(untouched) = keys.get(kz, expired.kid)
  assert untouched.status == key.Pending
  assert keys.active(kz, key.System) == Ok(None)
}

/// The new key is written before the old one is retired, so a failure in
/// between leaves the scope signing: the activation stands and the scope
/// is left with two active keys rather than none.
pub fn activate_writes_the_new_key_first_test() {
  let #(_, kz) = new()
  let sealer = kek()
  let first = import_test_key(kz, sealer)
  let second = import_test_key(kz, sealer)
  let assert Ok(_) = keys.activate(kz, first.kid, "m/u")

  let assert Ok(promoted) =
    keys.activate(save_fails_for(kz, first.kid), second.kid, "m/u")
  assert promoted.status == key.Active
  let assert Ok(not_retired) = keys.get(kz, first.kid)
  assert not_retired.status == key.Active
  // And the retirement can still be made by hand afterwards.
  let assert Ok(retired) = keys.retire(kz, first.kid, "m/u")
  assert retired.status == key.Retired
}

/// Two nodes that activate at the same moment leave a scope with two
/// active keys: `active` answers the first the view gives, `actives`
/// answers both, and that is what a report warns about.
pub fn actives_test() {
  let #(f, kz) = new()
  let sealer = kek()
  let first = import_test_key(kz, sealer)
  let second = import_test_key(kz, sealer)
  let assert Ok(_) = keys.activate(kz, first.kid, "m/u")
  assert keys.actives(kz, key.System) |> result.map(list.length) == Ok(1)

  // The second is made active behind the store's back, which is what
  // the activation of another node looks like from here.
  let assert Ok(stored) = fake.lookup(f, system.category, second.kid)
  fake.put_doc(
    f,
    system.category,
    doc.set(stored, ["status"], doc.String("active")),
  )
  let assert Ok(both) = keys.actives(kz, key.System)
  assert list.map(both, fn(k) { k.kid }) |> list.sort(string.compare)
    == list.sort([first.kid, second.kid], string.compare)
  // `active` still answers one of them, and says nothing about the rest.
  let assert Ok(Some(one)) = keys.active(kz, key.System)
  assert list.contains([first.kid, second.kid], one.kid)

  // A scope with no key at all.
  assert keys.actives(kz, key.Account("nobody")) == Ok([])
}

/// A change another node wrote first is a `Conflict` the caller can act
/// on -- run it again -- and not a datastore failure it cannot tell
/// apart from an outage.
pub fn conflict_is_its_own_error_test() {
  let #(_, kz) = new()
  let sealer = kek()
  let imported = import_test_key(kz, sealer)
  let contended =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, save_doc: fn(_db, _document) {
        Error(kazoo.Conflict)
      }),
    )
  assert keys.activate(contended, imported.kid, "m/u") == Error(keys.Conflict)
  // And the key is untouched by the activation that did not happen.
  let assert Ok(untouched) = keys.get(kz, imported.kid)
  assert untouched.status == key.Pending

  let assert Ok(_) = keys.activate(kz, imported.kid, "m/u")
  assert keys.retire(contended, imported.kid, "m/u") == Error(keys.Conflict)
  let assert Ok(still) = keys.get(kz, imported.kid)
  assert still.status == key.Active
}

/// A key's material is on its document: the sealed private key, the CSR
/// and, once issued, the certificate are fields written with the
/// document, so a key is never on record without its private key and a
/// read is one document. None of it is in the key's own fields or its
/// public shape, and the sealed field is not the PEM.
pub fn the_document_carries_the_material_test() {
  let #(f, kz) = new()
  let sealer = kek()
  let assert Ok(#(created, csr)) =
    keys.create(kz, sealer, key.System, "999Y", "Example Telecom", base, "m/u")

  let assert Ok(stored) = fake.lookup(f, system.category, created.kid)
  assert doc.get_string(stored, [key.csr_field]) == Ok(csr)
  assert doc.get(stored, [key.certificate_field]) == Error(Nil)
  let assert Ok(sealed) = doc.get_string(stored, [key.sealed_private_key_field])
  let assert Ok(bytes) = bit_array.base64_decode(sealed)
  assert bit_array.byte_size(bytes) > 0
  assert !contains(doc.to_string(stored), "PRIVATE KEY")
  let assert Ok(_) = keys.unseal(kz, sealer, created.kid)

  let own = key.to_doc(created)
  let public = key.to_public(created)
  assert doc.get(own, [key.sealed_private_key_field]) == Error(Nil)
  assert doc.get(own, [key.csr_field]) == Error(Nil)
  assert doc.get(public, [key.sealed_private_key_field]) == Error(Nil)
  assert doc.get(public, [key.csr_field]) == Error(Nil)
  assert doc.get(public, [key.certificate_field]) == Error(Nil)

  // A document whose sealed private key is gone is a key that cannot be
  // opened, whatever else it says; one whose sealed private key is not
  // a blob at all is unsealable, which is what an operator is told.
  fake.put_doc(
    f,
    system.category,
    doc.set(stored, [key.sealed_private_key_field], doc.String("not base64!")),
  )
  assert keys.unseal(kz, sealer, created.kid) == Error(keys.Damaged)
  fake.put_doc(
    f,
    system.category,
    doc.delete(stored, [key.sealed_private_key_field]),
  )
  assert keys.unseal(kz, sealer, created.kid) == Error(keys.NoPrivateKey)
}

/// A save that fails leaves nothing behind. The key and its private key
/// are one document, so there is no half-written key to roll back, and
/// the caller gets the datastore's answer.
pub fn create_that_cannot_save_stores_nothing_test() {
  let #(f, kz) = new()
  let sealer = kek()
  let before = list.length(fake.all_docs(f, system.category))
  let unavailable =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, save_doc: fn(_db, _document) {
        Error(kazoo.Unavailable)
      }),
    )

  assert keys.create(
      unavailable,
      sealer,
      key.System,
      "999Y",
      "Example Telecom",
      base,
      "m/u",
    )
    == Error(keys.Datastore(kazoo.Unavailable))
  assert keys.list(kz) == Ok([])
  assert list.length(fake.all_docs(f, system.category)) == before

  // And with the store working again, the same call works.
  let assert Ok(#(created, _csr)) =
    keys.create(kz, sealer, key.System, "999Y", "Example Telecom", base, "m/u")
  let assert Ok(_) = keys.unseal(kz, sealer, created.kid)
}

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

/// The kid `select` answers: the cached key carries no history, so the
/// key itself is not compared.
fn selected(
  kz: kazoo.Kazoo,
  account: String,
) -> Result(option.Option(String), keys.Error) {
  keys.select(kz, account) |> result.map(option.map(_, fn(k) { k.kid }))
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray
