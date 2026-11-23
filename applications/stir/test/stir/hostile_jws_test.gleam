//// `stir/jws` over a mutated compact serialisation.
////
//// The token under `stir/passport`'s parameters is the part an attacker
//// most wants a decoder to be generous about: three base64url fields,
//// two of which are JSON the verifier reads before the signature has
//// said anything. So a valid token is signed here with `test-key.pem`
//// and then cut, changed, padded out and pasted over, and `parse`,
//// `decode` and `verify` are run on every result.
////
//// `verify` answering `Ok` is allowed for exactly one class of
//// mutation: the last character of a base64url part carries bits no
//// decoder reads, so several spellings of it decode to the same bytes.
//// Every such acceptance is held to the signed bytes and the signature
//// being byte-identical to the ones that were signed -- not "the same
//// claims", which a second signer could arrange, but the same bytes.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import stir/jws
import support/mutate

const header_json = "{\"alg\":\"ES256\",\"typ\":\"passport\"}"

const payload_json = "{\"attest\":\"A\",\"iat\":1757635200}"

/// A second, valid token, for the mutations that paste one message into
/// another.
const other_payload_json = "{\"attest\":\"C\",\"iat\":1757635200}"

fn signer() -> jws.Signer {
  let key = fixture("test-key.pem")
  fn(input) { ecdsa_sign(key, input) }
}

fn token(payload: String) -> String {
  let assert Ok(compact) = jws.sign(header_json, payload, signer())
  compact
}

fn certificate() -> String {
  fixture("test-cert.pem")
}

fn corpus(valid: String) -> List(String) {
  let seed = mutate.seed(8_588_722)
  let #(inserted, seed) = mutate.text_insertions(valid, 150, seed)
  let bytes = bit_array.from_string(valid)
  let #(duplicated, seed) = mutate.duplications(bytes, 100, seed)
  let #(spliced, _seed) =
    mutate.splices(
      bytes,
      bit_array.from_string(token(other_payload_json)),
      150,
      seed,
    )
  list.flatten([
    mutate.text_truncations(valid, 1),
    mutate.ascii_flips(valid, 1),
    inserted,
    list.map(duplicated, mutate.unsafe_string),
    list.map(spliced, mutate.unsafe_string),
    mutate.base64_swaps(valid),
    mutate.oddities(),
    dot_shapes(valid),
  ])
}

/// The token with the wrong number of parts, and with the separator
/// where a part should be.
fn dot_shapes(valid: String) -> List(String) {
  let assert [header, payload, signature] = string.split(valid, ".")
  [
    header,
    header <> "." <> payload,
    valid <> "." <> signature,
    valid <> ".",
    "." <> valid,
    "..",
    "...",
    header <> ".." <> signature,
    "." <> payload <> "." <> signature,
    header <> "." <> payload <> ".",
    header <> "." <> signature <> "." <> payload,
    payload <> "." <> header <> "." <> signature,
    string.replace(valid, ".", ""),
  ]
}

/// Nothing raises, and nothing verifies but the bytes that were signed.
pub fn mutated_tokens_never_verify_test() {
  let valid = token(payload_json)
  let assert Ok(original) = jws.parse(valid)
  let mutations = corpus(valid)
  assert list.length(mutations) > 700

  list.each(mutations, fn(mutation) {
    case jws.parse(mutation) {
      Error(_refused) -> Nil
      Ok(parsed) -> {
        // The parts of anything that parses are an object and a
        // signature of some length; `verify` is what judges them.
        case jws.verify(parsed, certificate()) {
          Error(_refused) -> Nil
          Ok(Nil) -> {
            assert parsed.signing_input == original.signing_input
              as about(mutation)
            assert parsed.signature == original.signature as about(mutation)
          }
        }
        // The same token against a certificate over another key is never
        // anything but a refusal.
        let assert Error(_) =
          jws.verify(parsed, fixture("example-999Y-chain.pem"))
          as about(mutation)
        Nil
      }
    }
  })
}

/// `decode` is the base64url reader on its own: no padding is accepted,
/// nothing raises, and what comes back re-encodes to what went in.
pub fn decode_is_strict_test() {
  let valid = token(payload_json)
  let assert [header, payload, signature] = string.split(valid, ".")
  let parts =
    list.flatten([
      [header, payload, signature],
      mutate.ascii_flips(signature, 1),
      mutate.text_truncations(signature, 1),
      mutate.base64_swaps(payload),
      mutate.oddities(),
      [
        "AA==",
        "=",
        "==",
        "A=A",
        "QQ",
        "QQ=",
        "QQ==",
        "\u{0}QQ",
        "QQ\u{0}",
        "Q Q",
        "Q\nQ",
        "Q+Q",
        "Q/Q",
        "Q-_",
        string.repeat("A", 100_000),
      ],
    ])
  list.each(parts, fn(part) {
    case jws.decode(part) {
      None -> Nil
      Some(bytes) -> {
        // Padding is never accepted, whatever else is.
        assert !string.contains(part, "=") as about(part)
        // And the bytes are the text's: base64url of them is the text
        // again, but for the unread bits of a last character.
        assert bit_array.byte_size(bytes) <= string.byte_size(part)
          as about(part)
      }
    }
  })
  assert jws.decode("AA==") == None
  assert jws.decode("") == Some(<<>>)
}

/// A signature of the wrong length is refused before the key is asked,
/// and a header that names another algorithm is refused before the
/// signature is looked at. Both are the shapes an attacker sends first.
pub fn algorithm_and_length_test() {
  let valid = token(payload_json)
  let assert Ok(original) = jws.parse(valid)
  let assert [_, payload, signature] = string.split(valid, ".")
  let algorithms = [
    "none", "None", "NONE", "ES256 ", "es256", "ES384", "ES512", "RS256",
    "HS256", "PS256", "EdDSA", "", "ES256\u{0}",
  ]
  list.each(algorithms, fn(alg) {
    let header =
      jws.encode(bit_array.from_string(
        "{\"alg\":\"" <> alg <> "\",\"typ\":\"passport\"}",
      ))
    // A raw control character is not JSON, so some of these do not get
    // as far as a header; those that do are refused for the algorithm.
    case jws.parse(header <> "." <> payload <> "." <> signature) {
      Error(error) -> {
        assert error == jws.BadEncoding as about(alg)
      }
      Ok(parsed) -> {
        assert jws.verify(parsed, certificate()) == Error(jws.UnsupportedAlg)
          as about(alg)
      }
    }
  })
  // A header that is not an object at all does not parse.
  assert jws.parse(
      jws.encode(bit_array.from_string("\"ES256\""))
      <> "."
      <> payload
      <> "."
      <> signature,
    )
    == Error(jws.BadEncoding)

  // Signatures of every length but 64 are refused; 64 bytes of the wrong
  // value are refused by the curve.
  list.each([0, 1, 32, 63, 65, 96, 128], fn(length) {
    let wrong = jws.Parsed(..original, signature: <<0:size(length)-unit(8)>>)
    assert jws.verify(wrong, certificate()) == Error(jws.BadSignature)
      as about(int.to_string(length))
  })
  assert jws.verify(jws.Parsed(..original, signature: <<0:512>>), certificate())
    == Error(jws.BadSignature)
}

/// Parts far larger than anything a PASSporT carries: a mebibyte of
/// base64, a mebibyte of separators, deeply nested JSON in a part.
pub fn huge_tokens_test() {
  let valid = token(payload_json)
  let assert [header, payload, _signature] = string.split(valid, ".")
  let mebibyte = mutate.huge("A")
  let huge = [
    mebibyte,
    mebibyte <> "." <> payload <> ".AAAA",
    header <> "." <> mebibyte <> ".AAAA",
    header <> "." <> payload <> "." <> mebibyte,
    string.repeat(".", 100_000),
    header
      <> "."
      <> jws.encode(bit_array.from_string(mutate.nested("[", "]", 10_000)))
      <> ".AAAA",
    header
      <> "."
      <> jws.encode(bit_array.from_string(
      "{\"a\":" <> mutate.nested("[", "]", 2000) <> "}",
    ))
      <> ".AAAA",
  ]
  list.each(huge, fn(text) {
    case jws.parse(text) {
      Error(_refused) -> Nil
      Ok(parsed) -> {
        let assert Error(_) = jws.verify(parsed, certificate())
          as "a huge token verified"
        Nil
      }
    }
  })
}

/// FINDING (open): a token whose bytes are not UTF-8 raises rather than
/// answering `Error(BadEncoding)`.
///
/// `decode` asks `string.contains` and then `bit_array.base64_url_decode`
/// (`stir/jws.gleam`), and the standard library's base64url decoder
/// rewrites the alphabet with `string.replace`, which is written to
/// Gleam's promise that a `String` is UTF-8 and raises a `badmatch` when
/// it is not. The bytes reach here from an `Identity` header, which is a
/// binary and is not promised to be text. Failing on purpose.
pub fn non_utf8_token_raises_test() {
  let not_text = mutate.unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
  assert jws.decode(not_text) == None
  assert jws.parse(not_text <> "." <> not_text <> "." <> not_text)
    == Error(jws.BadEncoding)
}

fn about(value: String) -> String {
  "mutation ("
  <> int.to_string(string.byte_size(value))
  <> " bytes): "
  <> string.slice(value, 0, 160)
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  string.trim_end(text)
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: String,
  message: String,
) -> Result(BitArray, String)
