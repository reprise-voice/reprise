//// `stir/vault` over mutated sealed blobs.
////
//// A sealed blob is `nonce || tag || ciphertext` under AES-256-GCM,
//// with the document id as associated data. What a database dump
//// holds is exactly those bytes, and what §3.2 of the threat model
//// claims is that changing any of them, or moving a blob to another
//// document, opens nothing. So every byte of a blob is flipped in
//// turn, every prefix of it is offered, bytes are pushed in and
//// sections repeated and spliced with another blob's, the associated
//// data is mutated the same way, and the answer is always `Error(Nil)`.
////
//// There is no acceptance to allow here and no shape to make an
//// exception for: GCM authenticates the whole of what it is given.

import gleam/bit_array
import gleam/list
import gleam/string
import stir/secret
import stir/system
import stir/vault
import support/mutate

const aad = "0123456789abcdef"

const plain = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEG\n"

fn sealer() -> vault.Vault {
  let assert Ok(loaded) = vault.from_bytes(random_bytes(32))
  loaded
}

fn sealed(vault_: vault.Vault, of: String) -> BitArray {
  vault.seal(vault_, aad, secret.new("a key", bit_array.from_string(of)))
}

/// Cut short, flipped, padded out, repeated, spliced with the blob of
/// another secret under another key: none of it opens.
pub fn mutated_blobs_never_open_test() {
  let opener = sealer()
  let blob = sealed(opener, plain)
  let assert Ok(_) = vault.open(opener, aad, "a key", blob)

  let other = sealed(sealer(), "another secret entirely")
  let seed = mutate.seed(256_256)
  let #(inserted, seed) = mutate.insertions(blob, 100, seed)
  let #(duplicated, seed) = mutate.duplications(blob, 100, seed)
  let #(spliced, _seed) = mutate.splices(blob, other, 100, seed)
  let mutations =
    list.flatten([
      // Every byte of the nonce, the tag and the ciphertext.
      mutate.flips(blob, 1),
      mutate.truncations(blob, 1),
      inserted,
      duplicated,
      spliced,
      [<<>>, <<0>>, blob, bit_array.append(blob, <<0>>)],
    ])
  assert list.length(mutations) > 400

  list.each(mutations, fn(mutation) {
    case mutation == blob {
      True -> Nil
      False -> {
        assert vault.open(opener, aad, "a key", mutation) == Error(Nil)
          as about(mutation)
      }
    }
  })
}

/// The associated data is the document id, and a blob opens under its
/// own id and no other: every mutation of the id is a refusal.
pub fn mutated_associated_data_never_opens_test() {
  let opener = sealer()
  let blob = sealed(opener, plain)
  let seed = mutate.seed(770_711)
  let #(inserted, _seed) = mutate.text_insertions(aad, 60, seed)
  let ids =
    list.flatten([
      mutate.ascii_flips(aad, 1),
      mutate.text_truncations(aad, 1),
      inserted,
      mutate.oddities(),
      [
        string.uppercase(aad),
        aad <> " ",
        " " <> aad,
        aad <> "\n",
        aad <> "\u{0}",
        string.repeat(aad, 2),
        mutate.huge("a"),
      ],
    ])
  list.each(ids, fn(id) {
    case id == aad {
      True -> Nil
      False -> {
        assert vault.open(opener, id, "a key", blob) == Error(Nil)
          as { "associated data: " <> mutate.preview(id, 48) }
      }
    }
  })
  // And under its own, still.
  let assert Ok(_) = vault.open(opener, aad, "a key", blob)
  Nil
}

/// A blob sealed under one key-encryption key opens under no other,
/// however close: every byte of the key is flipped in turn.
pub fn mutated_key_never_opens_test() {
  let bytes = random_bytes(32)
  let assert Ok(opener) = vault.from_bytes(bytes)
  let blob = sealed(opener, plain)
  list.each(mutate.flips(bytes, 1), fn(mutation) {
    let assert Ok(other) = vault.from_bytes(mutation)
    assert vault.open(other, aad, "a key", blob) == Error(Nil)
      as { "key: " <> mutate.preview(mutate.unsafe_string(mutation), 32) }
    // Two different keys are two different discriminators.
    assert vault.id(other) != vault.id(opener)
  })
}

/// A key that is not 32 bytes is not a key, at every length from
/// nothing to twice too long.
pub fn key_lengths_test() {
  list.each(mutate.upto(80), fn(length) {
    let loaded = vault.from_bytes(random_bytes(length))
    case length {
      32 -> {
        let assert Ok(_) = loaded
        Nil
      }
      _ -> {
        assert loaded == Error(vault.Malformed(system.kek_variable))
          as { "length " <> string.inspect(length) }
      }
    }
  })
}

/// Blobs nobody sealed: nothing, a mebibyte, a blob of exactly the
/// nonce, of the nonce and tag, and of random bytes at every plausible
/// length.
pub fn blobs_nobody_sealed_test() {
  let opener = sealer()
  let #(random, _seed) =
    list.fold(mutate.upto(60), #([], mutate.seed(28_012)), fn(state, index) {
      let #(so_far, seed) = state
      let #(bytes, seed) = mutate.bytes(seed, index)
      #([bytes, ..so_far], seed)
    })
  let blobs =
    list.flatten([
      random,
      [
        <<>>,
        <<0:96>>,
        <<0:96, 0:128>>,
        <<0:96, 0:128, 0:8>>,
        bit_array.from_string(mutate.huge("A")),
        bit_array.from_string(plain),
      ],
    ])
  list.each(blobs, fn(blob) {
    assert vault.open(opener, aad, "a key", blob) == Error(Nil)
      as { "blob of " <> string.inspect(bit_array.byte_size(blob)) <> " bytes" }
  })
}

/// Whatever is sealed, what comes back out is what went in: a secret
/// of every length from nothing to a kibibyte, and one of a mebibyte.
pub fn round_trip_survives_every_length_test() {
  let opener = sealer()
  list.each([0, 1, 15, 16, 17, 31, 32, 33, 1023, 1024, 1_048_576], fn(length) {
    let text = string.repeat("z", length)
    let blob = sealed(opener, text)
    let assert Ok(opened) = vault.open(opener, aad, "a key", blob)
    assert secret.with(opened, fn(bytes) { bytes })
      == bit_array.from_string(text)
      as { "length " <> string.inspect(length) }
    // Sealing is not rendering: neither the blob nor the secret shows
    // a byte of the plaintext.
    assert !string.contains(string.inspect(opened), "z")
      as { "length " <> string.inspect(length) }
  })
}

fn about(bytes: BitArray) -> String {
  "blob ("
  <> string.inspect(bit_array.byte_size(bytes))
  <> " bytes): "
  <> mutate.preview(mutate.unsafe_string(bytes), 32)
}

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray
