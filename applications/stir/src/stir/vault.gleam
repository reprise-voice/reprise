//// The key-encryption key, and sealing under it.
////
//// `STIR_KEK` in the environment is base64 of 32 random bytes. A private key
//// or a credential is sealed with AES-256-GCM: a fresh 12-byte nonce, the
//// document id as associated data, and the blob stored is
//// `nonce || tag || ciphertext`. The KEK is read once and held in this
//// opaque value, behind a closure so that a `Vault` that reaches
//// `string.inspect` or a crash report renders a function rather than the
//// key; it is never logged, stored, or answered to a caller.
////
//// Without a KEK the application runs but cannot create or open keys, and
//// `status` says so. `STIR_KEK_NEXT` is the successor during a rotation.

import gleam/bit_array
import gleam/result
import gleam/string
import stir/secret.{type Secret}
import stir/system

pub opaque type Vault {
  Vault(kek: fn() -> BitArray, id: String)
}

pub type Error {
  /// The variable is not set.
  Missing(variable: String)
  /// Set, but not base64 of exactly 32 bytes.
  Malformed(variable: String)
}

/// The vault from `STIR_KEK`.
pub fn load() -> Result(Vault, Error) {
  from_variable(system.kek_variable)
}

/// The vault from `STIR_KEK_NEXT`, for a rotation.
///
/// A value that is the same key as `STIR_KEK` is not a rotation, it is a
/// leftover: it answers `Missing`, so that nothing tries to re-seal a
/// store onto the key it is already under and the signer does not open
/// every blob twice under one key.
pub fn load_next() -> Result(Vault, Error) {
  case from_variable(system.kek_next_variable) {
    Error(error) -> Error(error)
    Ok(next) ->
      case load() {
        Ok(current) if current.id == next.id ->
          Error(Missing(system.kek_next_variable))
        _ -> Ok(next)
      }
  }
}

/// A vault over given bytes, for a test. Anything but 32 bytes is
/// `Malformed`, named after the variable a real one comes from.
pub fn from_bytes(kek: BitArray) -> Result(Vault, Error) {
  from_bytes_of(system.kek_variable, kek)
}

/// The first eight hex characters of the SHA-256 of the KEK: enough to
/// tell two KEKs apart on a key document, useless for recovering either.
pub fn id(vault: Vault) -> String {
  vault.id
}

/// Seal a secret for storage under `aad` (the document id).
pub fn seal(vault: Vault, aad: String, secret: Secret) -> BitArray {
  use bytes <- secret.with(secret)
  aes_gcm_seal(vault.kek(), bit_array.from_string(aad), bytes)
}

/// Open a stored blob. `Error(Nil)` for a blob sealed under another KEK,
/// tampered with, or sealed for another document.
pub fn open(
  vault: Vault,
  aad: String,
  label: String,
  blob: BitArray,
) -> Result(Secret, Nil) {
  aes_gcm_open(vault.kek(), bit_array.from_string(aad), blob)
  |> result.map(secret.new(label, _))
}

/// What re-sealing a stored blob from `old` under `new` found.
pub type Resealing {
  /// It opened under `old` and is sealed under `new` now: the new blob.
  Resealed(BitArray)
  /// It is sealed under `new` already: nothing to write.
  UnderNew
  /// It opens under neither key-encryption key.
  OpensUnderNeither
}

/// Open `blob` under `old` and seal it under `new`, or say why not. The
/// secret never leaves this function, and the one protocol that tells a
/// hand-edited marker from a lost blob lives here rather than in every
/// store that rotates one.
pub fn reseal(
  old: Vault,
  new: Vault,
  aad: String,
  label: String,
  blob: BitArray,
) -> Resealing {
  case open(old, aad, label, blob) {
    Ok(secret) -> Resealed(seal(new, aad, secret))
    Error(Nil) ->
      case open(new, aad, label, blob) {
        Ok(_) -> UnderNew
        Error(Nil) -> OpensUnderNeither
      }
  }
}

/// What an `Error` means, for a status line or a log line. Names the
/// variable, never a value.
pub fn describe_error(error: Error) -> String {
  case error {
    Missing(variable) -> variable <> " is not set"
    Malformed(variable) -> variable <> " is not base64 of 32 bytes"
  }
}

fn from_variable(variable: String) -> Result(Vault, Error) {
  case getenv(variable) {
    Error(Nil) -> Error(Missing(variable))
    Ok(text) ->
      case bit_array.base64_decode(string.trim(text)) {
        Ok(bytes) -> from_bytes_of(variable, bytes)
        Error(Nil) -> Error(Malformed(variable))
      }
  }
}

fn from_bytes_of(variable: String, kek: BitArray) -> Result(Vault, Error) {
  case bit_array.byte_size(kek) {
    32 -> Ok(Vault(kek: fn() { kek }, id: string.slice(sha256_hex(kek), 0, 8)))
    _ -> Error(Malformed(variable))
  }
}

@external(erlang, "stir_ffi", "getenv")
fn getenv(variable: String) -> Result(String, Nil)

@external(erlang, "stir_ffi", "sha256_hex")
fn sha256_hex(bytes: BitArray) -> String

@external(erlang, "stir_ffi", "aes_gcm_seal")
fn aes_gcm_seal(key: BitArray, aad: BitArray, plain: BitArray) -> BitArray

@external(erlang, "stir_ffi", "aes_gcm_open")
fn aes_gcm_open(
  key: BitArray,
  aad: BitArray,
  blob: BitArray,
) -> Result(BitArray, Nil)
