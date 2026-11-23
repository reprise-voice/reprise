//// Sealing and opening under a key-encryption key, and reading one from
//// the environment. The environment is `STIR_KEK_NEXT` here, set and
//// unset around each check, so that nothing else in the suite sees it.

import gleam/bit_array
import gleam/erlang/charlist.{type Charlist}
import gleam/string
import stir/secret
import stir/system
import stir/vault

fn kek() -> vault.Vault {
  let assert Ok(loaded) = vault.from_bytes(random_bytes(32))
  loaded
}

pub fn round_trip_test() {
  let sealer = kek()
  let plain = secret.new("a key", <<"-----BEGIN PRIVATE KEY-----">>)
  let blob = vault.seal(sealer, "0123456789abcdef", plain)
  // Nonce, tag, and the ciphertext.
  assert bit_array.byte_size(blob) == 12 + 16 + 27
  let assert Ok(opened) = vault.open(sealer, "0123456789abcdef", "a key", blob)
  assert secret.label(opened) == "a key"
  assert secret.with(opened, fn(bytes) { bytes })
    == <<"-----BEGIN PRIVATE KEY-----">>
  // A fresh nonce each time.
  assert vault.seal(sealer, "0123456789abcdef", plain) != blob
}

pub fn wrong_kek_test() {
  let blob = vault.seal(kek(), "kid", secret.new("s", <<"x">>))
  assert vault.open(kek(), "kid", "s", blob) == Error(Nil)
}

/// A blob moves from one key-encryption key to the next, and says so
/// when it is already there or was never under either.
pub fn reseal_test() {
  let old = kek()
  let new = kek()
  let blob = vault.seal(old, "kid", secret.new("s", <<"x">>))
  let assert vault.Resealed(moved) = vault.reseal(old, new, "kid", "s", blob)
  let assert Ok(opened) = vault.open(new, "kid", "s", moved)
  assert secret.with(opened, fn(bytes) { bytes }) == <<"x">>
  assert vault.reseal(old, new, "kid", "s", moved) == vault.UnderNew
  assert vault.reseal(kek(), new, "kid", "s", blob) == vault.OpensUnderNeither
}

pub fn tamper_test() {
  let sealer = kek()
  let blob = vault.seal(sealer, "kid", secret.new("s", <<"secret">>))
  let assert Ok(prefix) = bit_array.slice(blob, 0, 33)
  let tampered = bit_array.append(prefix, <<0>>)
  assert vault.open(sealer, "kid", "s", tampered) == Error(Nil)
  assert vault.open(sealer, "kid", "s", <<>>) == Error(Nil)
  assert vault.open(sealer, "kid", "s", bit_array.append(blob, <<0>>))
    == Error(Nil)
}

/// A blob sealed for one document does not open as another's.
pub fn wrong_aad_test() {
  let sealer = kek()
  let blob = vault.seal(sealer, "kid-a", secret.new("s", <<"secret">>))
  assert vault.open(sealer, "kid-b", "s", blob) == Error(Nil)
  let assert Ok(_) = vault.open(sealer, "kid-a", "s", blob)
}

pub fn id_test() {
  let sealer = kek()
  assert string.length(vault.id(sealer)) == 8
  assert string.lowercase(vault.id(sealer)) == vault.id(sealer)
  assert vault.id(kek()) != vault.id(sealer)
  // The id is a function of the bytes.
  let bytes = random_bytes(32)
  let assert Ok(one) = vault.from_bytes(bytes)
  let assert Ok(two) = vault.from_bytes(bytes)
  assert vault.id(one) == vault.id(two)
}

pub fn from_bytes_length_test() {
  assert vault.from_bytes(random_bytes(31))
    == Error(vault.Malformed(system.kek_variable))
  assert vault.from_bytes(random_bytes(33))
    == Error(vault.Malformed(system.kek_variable))
  assert vault.from_bytes(<<>>) == Error(vault.Malformed(system.kek_variable))
}

pub fn load_from_environment_test() {
  let variable = system.kek_next_variable
  unsetenv(variable)
  assert vault.load_next() == Error(vault.Missing(variable))

  putenv(variable, "")
  assert vault.load_next() == Error(vault.Missing(variable))

  // Short.
  putenv(variable, bit_array.base64_encode(random_bytes(16), True))
  assert vault.load_next() == Error(vault.Malformed(variable))

  // Not base64.
  putenv(variable, "this is not base64!")
  assert vault.load_next() == Error(vault.Malformed(variable))

  // Right, padded and with a trailing newline a secret file might carry.
  let bytes = random_bytes(32)
  putenv(variable, bit_array.base64_encode(bytes, True) <> "\n")
  let assert Ok(loaded) = vault.load_next()
  let assert Ok(same) = vault.from_bytes(bytes)
  assert vault.id(loaded) == vault.id(same)
  let blob = vault.seal(same, "kid", secret.new("s", <<"secret">>))
  let assert Ok(opened) = vault.open(loaded, "kid", "s", blob)
  assert secret.with(opened, fn(b) { b }) == <<"secret">>

  unsetenv(variable)
  assert vault.load_next() == Error(vault.Missing(variable))
}

/// `STIR_KEK_NEXT` holding the same key as `STIR_KEK` is not a
/// rotation, it is a leftover: it answers as if it were not set, so
/// that `rekey` does not re-seal a store onto the key it is already
/// under and the signer does not try every blob twice under one key.
pub fn a_next_key_that_is_the_current_one_is_not_set_test() {
  let bytes = random_bytes(32)
  let encoded = bit_array.base64_encode(bytes, True)
  putenv(system.kek_variable, encoded)
  putenv(system.kek_next_variable, encoded)
  let assert Ok(current) = vault.load()
  assert vault.load_next() == Error(vault.Missing(system.kek_next_variable))

  // A different one is a rotation.
  let assert Ok(other) = vault.from_bytes(random_bytes(32))
  putenv(
    system.kek_next_variable,
    bit_array.base64_encode(random_bytes(32), True),
  )
  let assert Ok(next) = vault.load_next()
  assert vault.id(next) != vault.id(current)
  assert vault.id(other) != vault.id(current)

  // And with no current key at all, whatever is set is the next one.
  unsetenv(system.kek_variable)
  let assert Ok(_) = vault.load_next()
  unsetenv(system.kek_next_variable)
}

/// Neither a secret nor a vault renders its bytes. The label is all a
/// crash report, a log line or an `io.debug` can pick up; the bytes are
/// behind a function, and a function inspects as a function.
pub fn nothing_renders_the_bytes_test() {
  let plain = secret.new("private key 0123456789abcdef", <<"the bytes">>)
  let rendered = string.inspect(plain)
  assert string.contains(rendered, "private key 0123456789abcdef")
  assert !string.contains(rendered, "the bytes")
  assert !string.contains(rendered, "116")

  let bytes = random_bytes(32)
  let assert Ok(sealer) = vault.from_bytes(bytes)
  let rendered = string.inspect(sealer)
  assert string.contains(rendered, vault.id(sealer))
  assert !string.contains(rendered, string.inspect(bytes))
  assert !string.contains(rendered, bit_array.base16_encode(bytes))
}

pub fn describe_error_test() {
  assert vault.describe_error(vault.Missing("STIR_KEK"))
    == "STIR_KEK is not set"
  assert vault.describe_error(vault.Malformed("STIR_KEK"))
    == "STIR_KEK is not base64 of 32 bytes"
}

fn putenv(name: String, value: String) -> Nil {
  let _ = os_putenv(charlist.from_string(name), charlist.from_string(value))
  Nil
}

fn unsetenv(name: String) -> Nil {
  let _ = os_unsetenv(charlist.from_string(name))
  Nil
}

@external(erlang, "os", "putenv")
fn os_putenv(name: Charlist, value: Charlist) -> Bool

@external(erlang, "os", "unsetenv")
fn os_unsetenv(name: Charlist) -> Bool

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray
