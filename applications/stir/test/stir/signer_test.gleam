//// The signer: one named actor per node, started here once with a vault
//// read from `STIR_KEK`, which the test sets to a known value and unsets
//// again. A named process cannot be started twice, so every check runs in
//// the one test below.
////
//// `gleam test` starts the `stir` application before the suite, and its
//// tree now carries a signer over the live `Kazoo` record, which has no
//// datastore here. The test stops the application first, runs a signer of
//// its own over the fake, and starts the application again at the end.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import kazoo/cache
import kazoo/kazoo
import kazoo/testing/fake
import stir/jws
import stir/key
import stir/keys
import stir/keys_test
import stir/passport
import stir/secret
import stir/signer
import stir/system
import stir/vault

const base = "https://api.example/v2/stir/certs"

fn views() -> List(fake.View) {
  [
    keys_test.key_view(),
  ]
}

/// One more copy of the test key in the store, sealed under `sealer`.
fn import_test_key(kz: kazoo.Kazoo, sealer: vault.Vault) -> key.Key {
  let assert Ok(imported) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      secret.new("test key", bit_array.from_string(fixture("test-key.pem"))),
      fixture("test-cert.pem"),
      "TEST",
      base,
      "sup",
    )
  imported
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

pub fn signer_test() {
  let _ = application_stop(atom.create("stir"))
  assert process.named(signer.name()) == Error(Nil)

  // Before it runs.
  assert signer.sign("k", "m") == Error(signer.Unavailable)
  assert signer.loaded() == []
  assert signer.refresh() == Nil
  assert signer.stats() == Error(signer.Unavailable)
  assert signer.for_key("k")("m")
    == Error("the signer is not running on this node")

  // A name whose process is gone. `gleam_erlang` asserts that a named
  // subject resolves before it sends, so a signer that died between the
  // caller's look and its send would raise in the caller -- which is a
  // call on its way out. The send goes through the FFI instead, and
  // every one of these answers rather than raises.
  let ghost = process.spawn_unlinked(fn() { process.sleep(50) })
  let assert Ok(Nil) = process.register(ghost, signer.name())
  process.kill(ghost)
  unregistered()
  assert signer.sign("k", "m") == Error(signer.Unavailable)
  assert signer.stats() == Error(signer.Unavailable)
  assert signer.loaded() == []
  assert signer.refresh() == Nil

  let f = fake.new_with_views(views())
  let kz = fake.kazoo(f)
  let kek = random_bytes(32)
  let assert Ok(sealer) = vault.from_bytes(kek)
  let assert Ok(imported) =
    keys.import_key(
      kz,
      sealer,
      key.System,
      secret.new("test key", bit_array.from_string(fixture("test-key.pem"))),
      fixture("test-cert.pem"),
      "TEST",
      base,
      "sup",
    )

  putenv(system.kek_variable, bit_array.base64_encode(kek, True))
  // The signer reads through a record whose reads can be made to fail
  // and are counted; nothing else in the test does.
  clear_faults()
  let assert Ok(started) = signer.start(watched(kz))
  unsetenv(system.kek_variable)
  assert process.named(signer.name()) == Ok(started.pid)
  assert signer.loaded() == []

  // A signature the certificate over the key accepts.
  let assert Ok(signature) = signer.sign(imported.kid, "the message")
  assert bit_array.byte_size(signature) == 64
  assert ecdsa_verify(fixture("test-cert.pem"), "the message", signature)
  assert !ecdsa_verify(fixture("test-cert.pem"), "another", signature)
  assert signer.loaded() == [imported.kid]

  // Unknown keys and the wrong vault.
  assert signer.sign("0000000000000000", "m") == Error(signer.UnknownKey)
  let assert Ok(other_vault) = vault.from_bytes(random_bytes(32))
  let assert Ok(foreign) =
    keys.import_key(
      kz,
      other_vault,
      key.System,
      secret.new("test key", bit_array.from_string(fixture("test-key.pem"))),
      fixture("test-cert.pem"),
      "TEST",
      base,
      "sup",
    )
  assert signer.sign(foreign.kid, "m") == Error(signer.Unsealable)
  assert signer.loaded() == [imported.kid]

  // A `jws.Signer` that `passport.build` can use.
  let claims =
    passport.Claims(
      attest: "A",
      dest: ["14045550100"],
      iat: kz.now(),
      orig: "14045550199",
      origid: "7d2b7e2c-1a7a-4a1b-9b7e-2f0a0c9c1d11",
    )
  let assert Ok(identity) =
    passport.build(claims, imported.x5u, signer.for_key(imported.kid))
  let assert Ok(parsed) = passport.parse_identity(identity)
  assert parsed.x5u == imported.x5u
  assert passport.verify(parsed, fixture("test-cert.pem"), kz.now(), 60)
    == Ok(claims)
  let assert Ok(compact) = jws.parse(parsed.compact)
  assert jws.verify(compact, fixture("test-cert.pem")) == Ok(Nil)
  assert jws.verify(compact, fixture("example-999Y-chain.pem"))
    == Error(jws.BadSignature)
  assert signer.for_key(foreign.kid)("m")
    == Error("the key is sealed under another key-encryption key")

  // `refresh` forgets the opened keys and reads the vault again: with no
  // `STIR_KEK` in the environment now, nothing can be signed.
  signer.refresh()
  assert signer.loaded() == []
  assert signer.sign(imported.kid, "m") == Error(signer.NoVault)
  assert signer.for_key(imported.kid)("m")
    == Error("this node has no key-encryption key")

  // And with it back, signing resumes.
  putenv(system.kek_variable, bit_array.base64_encode(kek, True))
  signer.refresh()
  unsetenv(system.kek_variable)
  let assert Ok(again) = signer.sign(imported.kid, "the message")
  assert ecdsa_verify(fixture("test-cert.pem"), "the message", again)
  assert signer.loaded() == [imported.kid]

  // An opened key is held for five minutes and then read again. The
  // clock moves past that, and the key is not the active one of its
  // scope, so the signature is answered and the key is dropped rather
  // than held for another five minutes.
  fake.set_now(f, kz.now() + 301)
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert signer.loaded() == []

  // Activate it, and the re-read after the next five minutes holds it.
  let assert Ok(_) = keys.activate(kz, imported.kid, "m/u")
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert signer.loaded() == [imported.kid]
  fake.set_now(f, kz.now() + 301)
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert signer.loaded() == [imported.kid]

  // And a key that is retired elsewhere is gone from this node on the
  // first signature after its five minutes are up.
  let assert Ok(_) = keys.retire(kz, imported.kid, "m/u")
  assert signer.loaded() == [imported.kid]
  fake.set_now(f, kz.now() + 301)
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert signer.loaded() == []

  // --- the store goes away ---------------------------------------------
  //
  // A key this node has open goes on signing for as long as the
  // datastore is unreachable. A call with no Identity header is worse
  // than one signed by a key that may have been retired somewhere else,
  // and there is no deadline on that: only a key this node has never
  // opened is unavailable during an outage.
  let assert Ok(_) = keys.activate(kz, imported.kid, "m/u")
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert signer.loaded() == [imported.kid]

  fault("open_doc")
  fake.set_now(f, kz.now() + 301)
  let before = reads()
  let assert Ok(stale) = signer.sign(imported.kid, "the message")
  assert ecdsa_verify(fixture("test-cert.pem"), "the message", stale)
  assert signer.loaded() == [imported.kid]
  assert reads() == before + 1

  // And it is not asked again for five seconds: a kid whose read is
  // failing costs one read every five seconds, not one per signature.
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert reads() == before + 1
  fake.set_now(f, kz.now() + 6)
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert reads() == before + 2

  // Two hours in, still signing.
  fake.set_now(f, kz.now() + 7200)
  let assert Ok(long_outage) = signer.sign(imported.kid, "the message")
  assert ecdsa_verify(fixture("test-cert.pem"), "the message", long_outage)
  assert signer.loaded() == [imported.kid]

  // A key this node never opened cannot be signed with while the store
  // is away.
  let never_opened = import_test_key(kz, sealer)
  assert signer.sign(never_opened.kid, "m")
    == Error(signer.Crypto("datastore: unavailable"))

  // What the status shows: the vault, the counts, the kid being signed
  // from memory and since when, and the last failure and why.
  let assert Ok(stats) = signer.stats()
  assert stats.vault == Some(vault.id(sealer))
  assert stats.next_vault == option.None
  assert stats.opened == [imported.kid]
  assert stats.signed > 0
  assert list.key_find(stats.refused, "crypto") == Ok(1)
  assert list.key_find(stats.last_open, imported.kid) |> result.is_ok
  let assert Ok(failure) = list.key_find(stats.last_failure, imported.kid)
  assert failure.why == "datastore: unavailable"
  let assert Ok(since) = list.key_find(stats.stale, imported.kid)
  assert since < kz.now()

  // The store answers again: the usual re-read decides, the key is
  // still the active one of its scope, and nothing is stale any more.
  clear_faults()
  fake.set_now(f, kz.now() + 6)
  let assert Ok(_) = signer.sign(imported.kid, "the message")
  assert signer.loaded() == [imported.kid]
  let assert Ok(recovered) = signer.stats()
  assert recovered.stale == []

  // --- a rotation --------------------------------------------------------
  //
  // The store is re-sealed under the next key-encryption key while this
  // node still holds the old one. Signing stops only until the node has
  // `STIR_KEK_NEXT` in its environment, and nothing has to tell the
  // signer: it reads the successor on every re-read.
  let next = random_bytes(32)
  let assert Ok(next_sealer) = vault.from_bytes(next)
  let assert Ok(_) = keys.rekey(kz, sealer, next_sealer)
  putenv(system.kek_variable, bit_array.base64_encode(kek, True))
  signer.refresh()
  unsetenv(system.kek_variable)
  assert signer.sign(imported.kid, "m") == Error(signer.Unsealable)

  putenv(system.kek_next_variable, bit_array.base64_encode(next, True))
  fake.set_now(f, kz.now() + 6)
  let assert Ok(rotated) = signer.sign(imported.kid, "the message")
  assert ecdsa_verify(fixture("test-cert.pem"), "the message", rotated)
  let assert Ok(rotating) = signer.stats()
  assert rotating.next_vault == Some(vault.id(next_sealer))
  unsetenv(system.kek_next_variable)

  // The document records which vault, never what was opened: the
  // rotation above moved it to the next one.
  let assert Ok(stored) = keys.get(kz, imported.kid)
  assert stored.kek == Some(vault.id(next_sealer))
  assert list.all([stored.kid, stored.x5u, stored.spc], fn(field) {
    !string.contains(field, "PRIVATE")
  })

  // Leave the node as it was found: no signer of ours, the application up.
  // The actor is linked to this process, so unlink before the kill.
  process.unlink(started.pid)
  process.kill(started.pid)
  let _ = application_ensure_all_started(atom.create("stir"))
  Nil
}

/// The record the signer reads through: every document read is counted,
/// and can be made to fail the way an unreachable datastore does.
fn watched(kz: kazoo.Kazoo) -> kazoo.Kazoo {
  kazoo.Kazoo(
    ..kz,
    datamgr: kazoo.Datamgr(..kz.datamgr, open_doc: fn(db, id) {
      cache.put(reads_table, "reads", reads() + 1)
      case cache.get(faults_table, "open_doc") {
        Ok(True) -> Error(kazoo.Unavailable)
        _ -> kz.datamgr.open_doc(db, id)
      }
    }),
  )
}

const faults_table = "stir_test_faults"

const reads_table = "stir_signer_test_reads"

fn fault(call: String) -> Nil {
  cache.put(faults_table, call, True)
}

fn clear_faults() -> Nil {
  cache.clear(faults_table)
}

fn reads() -> Int {
  cache.get(reads_table, "reads") |> result.unwrap(0)
}

/// The name is free again: a registered name goes with the process that
/// held it, which takes a moment after the kill.
fn unregistered() -> Nil {
  case process.named(signer.name()) {
    Error(Nil) -> Nil
    Ok(_) -> {
      process.sleep(5)
      unregistered()
    }
  }
}

fn putenv(name: String, value: String) -> Nil {
  let _ = os_putenv(charlist.from_string(name), charlist.from_string(value))
  Nil
}

fn unsetenv(name: String) -> Nil {
  let _ = os_unsetenv(charlist.from_string(name))
  Nil
}

@external(erlang, "application", "stop")
fn application_stop(app: Atom) -> Dynamic

@external(erlang, "application", "ensure_all_started")
fn application_ensure_all_started(app: Atom) -> Dynamic

@external(erlang, "os", "putenv")
fn os_putenv(name: Charlist, value: Charlist) -> Bool

@external(erlang, "os", "unsetenv")
fn os_unsetenv(name: Charlist) -> Bool

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray

@external(erlang, "stir_ffi", "ecdsa_verify")
fn ecdsa_verify(pem: String, message: String, signature: BitArray) -> Bool
