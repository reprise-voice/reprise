//// `stir_ffi`'s certificate functions over mutated PEM.
////
//// These five functions are the only place where bytes an attacker
//// chose meet OTP's ASN.1 decoders, and the module's rule is that none
//// of them may raise: `certificate_info`, `validate_chain` and
//// `public_key_pem` answer `{error, Reason}`, `certificate_matches_key`
//// and `ecdsa_verify` answer `false`. A raise here would leave a
//// stacktrace holding the input -- a private key, in two of the five --
//// and would take the calling worker down, so a raise in this suite is
//// a failure of the suite.
////
//// The corpus is the four PEMs the application actually meets: the
//// SHAKEN chain (`example-999Y-chain.pem`), the test certificate,
//// the STI-PA's CRL and its signer, each cut short, flipped, padded
//// out, repeated and spliced into the others.
////
//// Some acceptances are allowed, and are pinned rather than
//// forbidden, because a mutation is free to produce a PEM that
//// genuinely carries something real. In each case what is asserted is
//// that the key involved is one that was genuinely certified:
////
////  - `validate_chain` may answer `Ok`: cutting the chain after its
////    leaf leaves a leaf the trust bundle still completes, a splice
////    can move the CRL signer (which chains to the pinned STI-PA
////    root) to the front, and OTP's PEM reader skips bytes outside
////    the base64 alphabet and ignores what follows a certificate, so
////    junk can be pushed into a body or appended to a structure
////    without changing what was decoded.
////  - `certificate_matches_key` and `ecdsa_verify` may answer `True`:
////    a splice can move the test certificate to the front of the
////    SHAKEN chain.
////
//// What `certificate_info` says about an SPC is not evidence of
//// anything on its own: it reads the leaf's TNAuthList without checking
//// a signature, and what stops a forged SPC is `validate_chain`. What
//// is asserted here is narrower and is what the extractor owes its
//// callers: no mutation of the 999Y chain ever names an SPC that is not
//// 999Y.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/string
import kazoo/doc
import support/mutate

/// 2026-09-12T08:00:00Z, inside every fixture's validity and the
/// fixture CRL's window, as `ffi_test` uses it.
const during_crl_window = 1_789_200_000

/// A corpus over one fixture: cut short and flipped at intervals across
/// the whole file, then pushed at, repeated and spliced with the other
/// fixtures. Some 700 mutations per fixture.
fn corpus(source: BitArray, others: List(BitArray), from: Int) -> List(String) {
  let seed = mutate.seed(from)
  let #(inserted, seed) = mutate.insertions(source, 100, seed)
  let #(duplicated, seed) = mutate.duplications(source, 100, seed)
  let #(spliced, _seed) =
    list.fold(others, #([], seed), fn(state, other) {
      let #(so_far, seed) = state
      let #(more, seed) = mutate.splices(source, other, 80, seed)
      #(list.append(so_far, more), seed)
    })
  list.flatten([
    mutate.truncations(source, 7),
    mutate.flips(source, 5),
    inserted,
    duplicated,
    spliced,
  ])
  |> list.map(mutate.unsafe_string)
}

fn chain() -> String {
  fixture("example-999Y-chain.pem")
}

fn bundle() -> String {
  fixture("example-shaken-intermediate.pem") <> fixture("stipa-stg-root.pem")
}

/// The fingerprint and the public key of a PEM's leaf, when it has one.
fn leaf(pem: String) -> Result(#(String, String), Nil) {
  case certificate_info(pem) {
    Error(_why) -> Error(Nil)
    Ok(text) ->
      case doc.parse(text) {
        Error(Nil) -> Error(Nil)
        Ok(info) ->
          case
            doc.get_string(info, ["fingerprint"]),
            doc.get_string(info, ["public_key_pem"])
          {
            Ok(fingerprint), Ok(key) -> Ok(#(fingerprint, key))
            _, _ -> Error(Nil)
          }
      }
  }
}

/// Every certificate of a PEM, as its own PEM block.
fn certificates_in(pem: String) -> List(String) {
  string.split(pem, "-----END CERTIFICATE-----")
  |> list.filter_map(fn(part) {
    case string.contains(part, "-----BEGIN CERTIFICATE-----") {
      True ->
        Ok(
          string.crop(part, "-----BEGIN CERTIFICATE-----")
          <> "-----END CERTIFICATE-----\n",
        )
      False -> Error(Nil)
    }
  })
}

/// The public key of every certificate in a PEM.
fn public_keys(pem: String) -> List(String) {
  certificates_in(pem)
  |> list.filter_map(fn(certificate) {
    case leaf(certificate) {
      Ok(#(_fingerprint, key)) -> Ok(key)
      Error(Nil) -> Error(Nil)
    }
  })
}

/// The base64 a PEM decoder actually reads: the data characters of the
/// text, byte by byte rather than through `string`, since a mutation's
/// bytes need not be UTF-8.
fn base64_stream(pem: String) -> String {
  mutate.alphabet_only(pem)
}

/// Nothing raises, nothing reports an SPC the fixture does not carry,
/// and what `certificate_info` answers is always readable JSON.
pub fn certificate_info_never_raises_test() {
  let real = chain()
  let assert Ok(#(_fingerprint, _key)) = leaf(real)
  let mutations =
    corpus(
      bit_array.from_string(real),
      [
        bit_array.from_string(fixture("test-cert.pem")),
        bit_array.from_string(fixture("stipa-stg-crl.pem")),
      ],
      11_071_971,
    )
  assert list.length(mutations) > 600

  list.each(mutations, fn(mutation) {
    case certificate_info(mutation) {
      Error(_why) -> Nil
      Ok(text) -> {
        let assert Ok(info) = doc.parse(text) as about(mutation)
        // Whatever parsed, it answered the shape the callers read.
        let assert Ok(_) = doc.get_string(info, ["fingerprint"])
          as about(mutation)
        let assert Ok(_) = doc.get_string(info, ["public_key_pem"])
          as about(mutation)
        let assert Ok(length) = doc.get_int(info, ["chain_length"])
          as about(mutation)
        assert length >= 1 as about(mutation)
        // And it never named an SPC that is not the chain's own.
        list.each(doc.strings(info, ["spcs"]), fn(spc) {
          assert spc == "999Y" as about(mutation)
        })
      }
    }
  })
}

/// A mutated chain never validates under a key nobody certified.
///
/// Not "the leaf is unchanged": a splice can move the CRL signer, which
/// chains to the pinned STI-PA root in the bundle, to the front of the
/// chain, and that PEM really does validate. Not "the leaf's bytes are
/// one of the genuine ones" either, for two reasons that are OTP's PEM
/// reader rather than this application's: `base64:mime_decode` skips
/// every byte outside the alphabet, so junk inserted in a body decodes
/// away, and `pkix_decode_cert` reads the first structure and ignores
/// what follows it, so a certificate with bytes appended is still that
/// certificate -- with a different `fingerprint`, since that is the
/// SHA-256 of what arrived. Nothing decides anything on a fingerprint
/// (`stir_maintenance` compares one to warn), so what is pinned here is
/// the property verification rests on: whatever validates, the key it
/// validates under is a key that was genuinely certified.
pub fn mutated_chains_never_validate_test() {
  let real = chain()
  let genuine =
    list.flatten([
      public_keys(real),
      public_keys(bundle()),
      public_keys(fixture("test-cert.pem")),
      public_keys(fixture("stipa-stg-crl-signer.pem")),
    ])
  assert validate_chain(real, bundle(), "", "", during_crl_window) == Ok(Nil)

  let mutations =
    corpus(
      bit_array.from_string(real),
      [
        bit_array.from_string(fixture("test-cert.pem")),
        bit_array.from_string(fixture("stipa-stg-crl-signer.pem")),
      ],
      3_141_592,
    )
  list.each(mutations, fn(mutation) {
    case validate_chain(mutation, bundle(), "", "", during_crl_window) {
      Error(_why) -> Nil
      Ok(Nil) -> {
        let assert Ok(#(_fingerprint, key)) = leaf(mutation) as about(mutation)
        assert list.contains(genuine, key) as about(mutation)
      }
    }
  })
}

/// The same, with the STI-PA's CRL and its signer mutated instead: a
/// tampered CRL or a tampered signer never leaves the chain validating.
pub fn mutated_crls_never_validate_test() {
  let real = chain()
  let crl = fixture("stipa-stg-crl.pem")
  let signer = fixture("stipa-stg-crl-signer.pem")
  assert validate_chain(real, bundle(), crl, signer, during_crl_window)
    == Ok(Nil)

  let seed = mutate.seed(271_828)
  let #(crl_inserted, seed) =
    mutate.insertions(bit_array.from_string(crl), 60, seed)
  let #(signer_spliced, _seed) =
    mutate.splices(
      bit_array.from_string(signer),
      bit_array.from_string(fixture("test-cert.pem")),
      60,
      seed,
    )
  let crls =
    list.flatten([
      mutate.truncations(bit_array.from_string(crl), 251),
      mutate.flips(bit_array.from_string(crl), 149),
      crl_inserted,
    ])
    |> list.map(mutate.unsafe_string)
  let signers =
    list.flatten([
      mutate.truncations(bit_array.from_string(signer), 79),
      mutate.flips(bit_array.from_string(signer), 61),
      signer_spliced,
    ])
    |> list.map(mutate.unsafe_string)

  // A mutated CRL beside the real signer: a refusal, unless the
  // mutation emptied the argument -- which is the documented "no CRL to
  // check against" and not an acceptance of a tampered one -- or left
  // the bytes the decoder reads exactly as they were. Those are the
  // base64 data characters and no others: `base64:mime_decode` skips
  // everything else, padding included, so junk pushed in between them
  // decodes away.
  let body = base64_stream(crl)
  list.each(crls, fn(mutation) {
    case validate_chain(real, bundle(), mutation, signer, during_crl_window) {
      Error(_why) -> Nil
      Ok(Nil) -> {
        assert mutation == "" || base64_stream(mutation) == body
          as about(mutation)
      }
    }
  })

  // A mutated signer beside the real CRL: a refusal unless the
  // mutation left a genuine certificate to be the signer, which
  // cutting the file after its first certificate does -- the signer
  // alone still chains to the pinned root in the bundle. A signer
  // whose own bytes were edited never gets that far: it has to be the
  // CRL's issuer, carry `cRLSign`, verify the CRL's signature and
  // chain to an anchor.
  let genuine = list.flatten([public_keys(signer), public_keys(bundle())])
  list.each(signers, fn(mutation) {
    case validate_chain(real, bundle(), crl, mutation, during_crl_window) {
      Error(_why) -> Nil
      Ok(Nil) -> {
        let assert Ok(#(_fingerprint, key)) = leaf(mutation) as about(mutation)
        assert list.contains(genuine, key) as about(mutation)
      }
    }
  })
}

/// `certificate_matches_key` and `ecdsa_verify` answer for the leaf's
/// key and for no other: a mutation that makes either answer yes is one
/// that put the matching key in the leaf.
pub fn key_agreement_survives_mutation_test() {
  let key = fixture("test-key.pem")
  let public = fixture("test-key-pub.pem")
  let message = fixture("test-message.txt")
  let assert Ok(signature) = ecdsa_sign(key, message)

  let mutations =
    corpus(
      bit_array.from_string(chain()),
      [bit_array.from_string(fixture("test-cert.pem"))],
      1_618_033,
    )
  list.each(mutations, fn(mutation) {
    case certificate_matches_key(mutation, key) {
      False -> Nil
      True -> {
        let assert Ok(#(_fingerprint, leaf_key)) = leaf(mutation)
          as about(mutation)
        assert leaf_key == public as about(mutation)
      }
    }
    case ecdsa_verify(mutation, message, signature) {
      False -> Nil
      True -> {
        let assert Ok(#(_fingerprint, leaf_key)) = leaf(mutation)
          as about(mutation)
        assert leaf_key == public as about(mutation)
      }
    }
    // A signature of the wrong length is never anything but a refusal,
    // whatever the PEM holds.
    assert !ecdsa_verify(mutation, message, <<>>) as about(mutation)
    assert !ecdsa_verify(mutation, message, <<0:520>>) as about(mutation)
  })
}

/// A mutated private key PEM: `public_key_pem` answers a well-formed
/// public key or an error, never a raise and never the bytes of the key
/// in its reason.
pub fn mutated_private_keys_test() {
  let key = fixture("test-key.pem")
  let mutations =
    corpus(
      bit_array.from_string(key),
      [bit_array.from_string(fixture("test-key-pub.pem"))],
      2_718_281,
    )
  list.each(mutations, fn(mutation) {
    case public_key_pem(mutation) {
      Error(why) -> {
        // The reason names what went wrong and carries no key bytes.
        assert !string.contains(why, "BEGIN") as about(mutation)
        assert string.byte_size(why) < 200 as about(mutation)
      }
      Ok(answered) -> {
        assert string.starts_with(answered, "-----BEGIN PUBLIC KEY-----")
          as about(mutation)
        assert string.ends_with(
          string.trim_end(answered),
          "-----END PUBLIC KEY-----",
        )
          as about(mutation)
      }
    }
    // Signing with a mutated key is an error or a signature, never a
    // raise and never a leak.
    case ecdsa_sign(mutation, "the message") {
      Error(why) -> {
        assert !string.contains(why, "BEGIN") as about(mutation)
        Nil
      }
      Ok(signature) -> {
        assert bit_array.byte_size(signature) == 64 as about(mutation)
        Nil
      }
    }
  })
}

/// The shapes that are not a mutation of anything: nothing at all, a
/// mebibyte, a PEM header with a mebibyte inside it, a thousand
/// certificates, deeply nested brackets, control characters.
pub fn hostile_shapes_test() {
  let mebibyte = mutate.huge("A")
  let shapes =
    list.flatten([
      mutate.oddities(),
      [
        mebibyte,
        "-----BEGIN CERTIFICATE-----\n"
          <> mebibyte
          <> "\n-----END CERTIFICATE-----\n",
        "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n",
        "-----BEGIN CERTIFICATE-----",
        "-----END CERTIFICATE-----",
        string.repeat("-----BEGIN CERTIFICATE-----\n", 1000),
        string.repeat(fixture("test-cert.pem") <> "\n", 200),
        fixture("garbage-cert.pem"),
        string.repeat(fixture("garbage-cert.pem") <> "\n", 100),
        fixture("test-key.pem") <> fixture("test-cert.pem"),
        fixture("test-cert.pem") <> fixture("test-key.pem"),
        "-----BEGIN CERTIFICATE-----\n"
          <> mutate.nested("[", "]", 1000)
          <> "\n-----END CERTIFICATE-----\n",
      ],
    ])
  list.each(shapes, fn(shape) {
    // Every one of the five answers, and none of them raises.
    let _ = certificate_info(shape)
    let _ = public_key_pem(shape)
    let _ = certificate_matches_key(shape, fixture("test-key.pem"))
    let _ = ecdsa_verify(shape, "the message", <<0:512>>)
    let assert Error(_) =
      validate_chain(shape, bundle(), "", "", during_crl_window)
      as about(shape)
    // And an empty bundle is always a refusal, whatever the chain is.
    let assert Error(_) =
      validate_chain(chain(), shape, "", "", during_crl_window)
      as about(shape)
    Nil
  })
}

fn about(value: String) -> String {
  "mutation ("
  <> int.to_string(string.byte_size(value))
  <> " bytes): "
  <> mutate.preview(value, 48)
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "certificate_info")
fn certificate_info(chain_pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "validate_chain")
fn validate_chain(
  chain_pem: String,
  trust_pem: String,
  crl_pem: String,
  crl_signer_pem: String,
  now_unix: Int,
) -> Result(Nil, String)

@external(erlang, "stir_ffi", "certificate_matches_key")
fn certificate_matches_key(chain_pem: String, private_key_pem: String) -> Bool

@external(erlang, "stir_ffi", "public_key_pem")
fn public_key_pem(private_key_pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: String,
  message: String,
) -> Result(BitArray, String)

@external(erlang, "stir_ffi", "ecdsa_verify")
fn ecdsa_verify(
  public_or_certificate_pem: String,
  message: String,
  signature: BitArray,
) -> Bool
