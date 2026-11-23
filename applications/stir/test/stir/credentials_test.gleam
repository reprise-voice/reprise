//// The credential store over the fake: set, status, get, delete, and a
//// rotation. Values go in as a `Secret` and come out as one; a document
//// never carries one.
////
//// Everything is found through `credentials_by_name`, so the fake is
//// given that view exactly as `priv/couchdb/views/stir.json` emits it.

import gleam/bit_array
import gleam/list
import gleam/string
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake
import stir/credentials
import stir/keys_test
import stir/secret
import stir/system
import stir/vault

fn views() -> List(fake.View) {
  [keys_test.credential_view()]
}

fn new() -> fake.Fake {
  fake.new_with_views(views())
}

fn kek() -> vault.Vault {
  let assert Ok(loaded) = vault.from_bytes(random_bytes(32))
  loaded
}

fn text(s: secret.Secret) -> String {
  let assert Ok(t) = secret.with(s, bit_array.to_string)
  t
}

pub fn set_status_get_delete_test() {
  let f = new()
  let kz = fake.kazoo(f)
  let sealer = kek()

  assert credentials.status(kz) == Ok([])
  assert credentials.get(kz, sealer, credentials.stipa_user)
    == Error(credentials.NotFound)
  assert credentials.delete(kz, credentials.stipa_user, "m/u")
    == Error(credentials.NotFound)

  let assert Ok(status) =
    credentials.set(
      kz,
      sealer,
      credentials.stipa_user,
      secret.new("stipa_user", <<"alice">>),
      "m/u",
    )
  assert status
    == credentials.Status(name: "stipa_user", set_at: 63_924_619_200, by: "m/u")
  let assert Ok(_) =
    credentials.set(
      kz,
      sealer,
      credentials.stipa_password,
      secret.new("stipa_password", <<"hunter2">>),
      "m/u",
    )

  // Listed by name, sorted; never a value.
  let assert Ok(listed) = credentials.status(kz)
  assert list.map(listed, fn(s) { s.name }) == ["stipa_password", "stipa_user"]

  let assert Ok(stored) =
    fake.lookup(f, system.category, "credential-stipa_user")
  assert doc.get_string(stored, ["pvt_type"]) == Ok("stir_credentials")
  assert doc.get_string(stored, ["kek"]) == Ok(vault.id(sealer))
  assert doc.get_string(stored, ["by"]) == Ok("m/u")
  assert !string.contains(doc.to_string(stored), "alice")

  // Opened under the same vault, not under another.
  let assert Ok(opened) = credentials.get(kz, sealer, credentials.stipa_user)
  assert secret.label(opened) == "stipa_user"
  assert text(opened) == "alice"
  assert credentials.get(kz, kek(), credentials.stipa_user)
    == Error(credentials.Unsealable)

  // Setting again replaces the value and the record.
  let assert Ok(_) =
    credentials.set(
      kz,
      sealer,
      credentials.stipa_user,
      secret.new("stipa_user", <<"bob">>),
      "m/u2",
    )
  let assert Ok(again) = credentials.get(kz, sealer, credentials.stipa_user)
  assert text(again) == "bob"
  let assert Ok(listed) = credentials.status(kz)
  assert list.map(listed, fn(s) { s.name }) == ["stipa_password", "stipa_user"]
  let assert Ok(user) = list.find(listed, fn(s) { s.name == "stipa_user" })
  assert user.by == "m/u2"

  assert credentials.delete(kz, credentials.stipa_user, "m/u") == Ok(Nil)
  assert credentials.get(kz, sealer, credentials.stipa_user)
    == Error(credentials.NotFound)
  let assert Ok(listed) = credentials.status(kz)
  assert list.map(listed, fn(s) { s.name }) == ["stipa_password"]
  assert fake.lookup(f, system.category, "credential-stipa_user")
    == Error(kazoo.NotFound)
}

pub fn name_test() {
  assert credentials.valid_name("stipa_user")
  assert credentials.valid_name("acme_eab_hmac")
  assert credentials.valid_name("x")
  assert !credentials.valid_name("")
  assert !credentials.valid_name("Stipa")
  assert !credentials.valid_name("stipa-user")
  assert !credentials.valid_name("stipa user")
  assert !credentials.valid_name("stipa1")
  assert !credentials.valid_name("../etc")

  let kz = new() |> fake.kazoo
  let assert Error(credentials.Datastore(kazoo.Invalid(_))) =
    credentials.set(kz, kek(), "Nope", secret.new("n", <<"v">>), "m/u")
  let assert Error(credentials.Datastore(kazoo.Invalid(_))) =
    credentials.get(kz, kek(), "no-pe")
  let assert Error(credentials.Datastore(kazoo.Invalid(_))) =
    credentials.delete(kz, "", "m/u")
}

pub fn rekey_test() {
  let kz = new() |> fake.kazoo
  let old = kek()
  let new = kek()
  let assert Ok(_) =
    credentials.set(kz, old, "rekey_one", secret.new("one", <<"1">>), "m/u")
  let assert Ok(_) =
    credentials.set(kz, old, "rekey_two", secret.new("two", <<"2">>), "m/u")
  // One is under `new` already.
  let assert Ok(_) =
    credentials.set(kz, new, "rekey_three", secret.new("three", <<"3">>), "m/u")

  assert credentials.rekey(kz, old, new) == Ok(2)

  let assert Ok(one) = credentials.get(kz, new, "rekey_one")
  assert text(one) == "1"
  let assert Ok(two) = credentials.get(kz, new, "rekey_two")
  assert text(two) == "2"
  let assert Ok(three) = credentials.get(kz, new, "rekey_three")
  assert text(three) == "3"
  assert credentials.get(kz, old, "rekey_one") == Error(credentials.Unsealable)

  // Nothing left to do.
  assert credentials.rekey(kz, old, new) == Ok(0)

  // Nothing opens under a vault that never sealed anything: every
  // credential is a line of its own and the pass still ends.
  let #(answer, failures) = credentials.rekey_report(kz, kek(), old)
  assert answer == Ok(0)
  assert list.length(failures) == 3
  assert list.all(failures, fn(line) {
    string.contains(line, "opens under neither key-encryption key")
  })
  let assert Ok(_) = credentials.get(kz, new, "rekey_one")
}

/// A value already sealed under `new` whose document still says `old` is
/// a hand edit, since the two are written in one save: reported, and
/// left alone.
pub fn rekey_reports_a_stale_marker_test() {
  let f = new()
  let kz = fake.kazoo(f)
  let old = kek()
  let new = kek()
  let assert Ok(_) =
    credentials.set(kz, new, "rekey_marked", secret.new("m", <<"m">>), "m/u")
  let assert Ok(stored) =
    fake.lookup(f, system.category, credentials.doc_id("rekey_marked"))
  fake.put_doc(
    f,
    system.category,
    doc.set(stored, ["kek"], doc.String(vault.id(old))),
  )

  let #(answer, failures) = credentials.rekey_report(kz, old, new)
  assert answer == Ok(0)
  let assert [line] = failures
  assert string.contains(line, "credential rekey_marked")
  assert string.contains(line, "sealed under " <> vault.id(new) <> " already")
  let assert Ok(untouched) =
    fake.lookup(f, system.category, credentials.doc_id("rekey_marked"))
  assert doc.get_string(untouched, ["kek"]) == Ok(vault.id(old))
  let assert Ok(value) = credentials.get(kz, new, "rekey_marked")
  assert text(value) == "m"
}

/// Without the view nothing can be listed, and saying so is the point:
/// an empty listing would let a rotation report that it had re-sealed
/// every credential.
pub fn without_the_view_test() {
  let kz = fake.new() |> fake.kazoo
  let missing =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(
        ..kz.datamgr,
        get_results: fn(_db, _view, _options) { Error(kazoo.NotFound) },
      ),
    )
  assert credentials.status(missing) == Error(credentials.ViewMissing)
  assert credentials.rekey(missing, kek(), kek())
    == Error(credentials.ViewMissing)
}

/// The sealed value is a field of the credential's document, written
/// with it: never the plaintext, and a document that lost the field is a
/// credential that is not there.
pub fn the_document_carries_the_sealed_value_test() {
  let f = new()
  let kz = fake.kazoo(f)
  let sealer = kek()
  let assert Ok(_) =
    credentials.set(
      kz,
      sealer,
      credentials.stipa_user,
      secret.new("stipa_user", <<"alice">>),
      "m/u",
    )

  let assert Ok(stored) =
    fake.lookup(f, system.category, credentials.doc_id("stipa_user"))
  let assert Ok(sealed) =
    doc.get_string(stored, [credentials.sealed_value_field])
  let assert Ok(_) = bit_array.base64_decode(sealed)
  assert !string.contains(doc.to_string(stored), "alice")

  fake.put_doc(
    f,
    system.category,
    doc.delete(stored, [credentials.sealed_value_field]),
  )
  assert credentials.get(kz, sealer, credentials.stipa_user)
    == Error(credentials.NotFound)
}

/// A save that fails changes nothing: the value and the document are one
/// write, so a credential that could not be set is not on record, and one
/// that was already set keeps the value it had.
pub fn set_that_cannot_save_changes_nothing_test() {
  let f = new()
  let kz = fake.kazoo(f)
  let sealer = kek()
  let unavailable =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(..kz.datamgr, save_doc: fn(_db, _document) {
        Error(kazoo.Unavailable)
      }),
    )

  assert credentials.set(
      unavailable,
      sealer,
      credentials.stipa_user,
      secret.new("stipa_user", <<"alice">>),
      "m/u",
    )
    == Error(credentials.Datastore(kazoo.Unavailable))
  assert credentials.status(kz) == Ok([])
  assert fake.lookup(f, system.category, credentials.doc_id("stipa_user"))
    == Error(kazoo.NotFound)

  let assert Ok(_) =
    credentials.set(
      kz,
      sealer,
      credentials.stipa_user,
      secret.new("stipa_user", <<"alice">>),
      "m/u",
    )
  assert credentials.set(
      unavailable,
      sealer,
      credentials.stipa_user,
      secret.new("stipa_user", <<"bob">>),
      "someone else",
    )
    == Error(credentials.Datastore(kazoo.Unavailable))

  let assert Ok(kept) = credentials.get(kz, sealer, credentials.stipa_user)
  assert text(kept) == "alice"
  let assert Ok([listed]) = credentials.status(kz)
  assert listed.by == "m/u"
}

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray
