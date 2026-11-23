//// `stir/passport` over a mutated `Identity` header.
////
//// The header value is the most hostile input the application has: it
//// arrives on an inbound call from a carrier peer who writes every byte
//// of it, and what it carries -- a token, a URL to fetch, and the
//// parameters that describe them -- is read before anything has been
//// authenticated. So a valid header is built here with `test-key.pem`
//// and then taken apart every way `support/mutate` knows: cut short at
//// every position, one character changed at every position, characters
//// pushed in, a section repeated, a section overwritten with a second
//// valid header's, the base64 alphabet swapped, the parameters rewritten
//// by hand, and the sizes nobody sends on purpose.
////
//// Two things are asserted of every mutation. Nothing raises: a
//// `function_clause` in a call-setup worker is an outage, not a
//// refusal. And `verify` never answers `Ok` with claims other than the
//// ones that were signed -- the interesting half, since the mutation is
//// free to rewrite the `x5u`, the algorithm, the extension or the
//// claims themselves. An `Ok` is allowed only when the mutation left
//// the signed bytes and the signature byte-identical, which the last
//// character of a base64 part permits: it carries bits no decoder
//// reads, so four spellings of it decode to one signature.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import stir/jws
import stir/passport.{type Claims, Claims}
import support/mutate

const x5u = "https://example.test/cert.pem"

const iat = 1_757_635_200

fn claims() -> Claims {
  Claims(
    attest: "A",
    dest: ["12025550123"],
    iat: iat,
    orig: "12025550100",
    origid: "55f23c60-74cc-4b29-b2e3-3bac121f0c30",
  )
}

/// A second, valid header over other claims, for the mutations that
/// paste one message into another.
fn other_claims() -> Claims {
  Claims(..claims(), attest: "C", orig: "13105550199")
}

fn signer() -> jws.Signer {
  let key = fixture("test-key.pem")
  fn(input) { ecdsa_sign(key, input) }
}

fn header(of: Claims) -> String {
  let assert Ok(value) = passport.build(of, x5u, signer())
  value
}

fn certificate() -> String {
  fixture("test-cert.pem")
}

/// The compact JWS of a header value.
fn token(value: String) -> String {
  let assert [compact, ..] = string.split(value, ";")
  compact
}

/// Every mutation of a valid header: around 1400 of them, since the
/// header is some 460 characters and the per-position strategies each
/// answer one mutation per character.
fn corpus(valid: String) -> List(String) {
  let seed = mutate.seed(20_260_911)
  let #(inserted, seed) = mutate.text_insertions(valid, 150, seed)
  let bytes = bit_array.from_string(valid)
  let #(duplicated, seed) = mutate.duplications(bytes, 100, seed)
  let #(spliced, _seed) =
    mutate.splices(
      bytes,
      bit_array.from_string(header(other_claims())),
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
  ])
}

/// Cut short, changed, padded out, pasted over: the header still either
/// fails to parse, fails to verify, or answers exactly the claims that
/// were signed.
pub fn mutated_headers_never_verify_test() {
  let valid = header(claims())
  let assert Ok(original) = jws.parse(token(valid))
  let mutations = corpus(valid)
  // The corpus is what the doc comment says it is; a strategy that
  // silently answered nothing would make every assertion below vacuous.
  assert list.length(mutations) > 1200

  list.each(mutations, fn(mutation) {
    case passport.parse_identity(mutation) {
      Error(_refused) -> Nil
      Ok(identity) ->
        case passport.verify(identity, certificate(), iat, 60) {
          Error(_refused) -> Nil
          Ok(verified) -> {
            assert verified == claims() as about(mutation)
            // Accepted, so the signed bytes and the signature are the
            // ones that were signed, and the URL is the one in them.
            let assert Ok(parsed) = jws.parse(identity.compact)
            assert parsed.signing_input == original.signing_input
              as about(mutation)
            assert parsed.signature == original.signature as about(mutation)
            assert identity.x5u == x5u as about(mutation)
          }
        }
    }
  })
}

/// The same corpus against the public key rather than the certificate,
/// and against a certificate over another key: a mutation must not make
/// the second one verify.
pub fn mutated_headers_never_verify_under_another_key_test() {
  let valid = header(claims())
  let elsewhere = fixture("example-999Y-chain.pem")
  list.each(corpus(valid), fn(mutation) {
    case passport.parse_identity(mutation) {
      Error(_refused) -> Nil
      Ok(identity) -> {
        let assert Error(_) = passport.verify(identity, elsewhere, iat, 60)
          as about(mutation)
        Nil
      }
    }
  })
}

/// The parameters are not a way in. RFC 8224 lets a sender name `alg`
/// and `ppt` beside the token; a verifier that took either of them for
/// the token's own header would verify a PASSporT the certificate never
/// signed, and one that took `info` for the signed `x5u` would fetch a
/// certificate of the sender's choosing.
pub fn hostile_parameters_test() {
  let valid = header(claims())
  let compact = token(valid)
  let hostile = [
    // The algorithm and the extension, claimed against what was signed.
    compact <> ";info=<" <> x5u <> ">;alg=none;ppt=shaken",
    compact <> ";info=<" <> x5u <> ">;alg=RS256;ppt=shaken",
    compact <> ";info=<" <> x5u <> ">;alg=HS256;ppt=shaken",
    compact <> ";info=<" <> x5u <> ">;alg=ES256;ppt=div",
    compact <> ";info=<" <> x5u <> ">;alg=es256;ppt=shaken",
    compact <> ";info=<" <> x5u <> ">;alg=ES256 ;ppt=shaken",
    // A second `info`, before and after the signed one.
    compact <> ";info=<https://attacker.test/c.pem>;info=<" <> x5u <> ">",
    compact <> ";info=<" <> x5u <> ">;info=<https://attacker.test/c.pem>",
    // The URL rewritten under the parameter's many spellings.
    compact <> ";INFO=<https://attacker.test/c.pem>",
    compact <> ";Info=\"https://attacker.test/c.pem\"",
    compact <> ";info=https://attacker.test/c.pem",
    compact <> ";info=<" <> x5u <> "/../../attacker>",
    compact <> ";info=<" <> x5u <> "#>",
    compact <> ";info=<" <> string.uppercase(x5u) <> ">",
    // Separators where a parser might lose its place.
    compact <> ";;info=<" <> x5u <> ">",
    compact <> ";info=<" <> x5u <> ">;;",
    compact <> "\r\n;info=<" <> x5u <> ">",
    compact <> ";info=<" <> x5u <> ">\r\nIdentity: nonsense",
    compact <> ";info=<" <> x5u <> ">;ppt=shaken;ppt=div",
    compact <> ";info=<" <> x5u <> ">;=;alg=ES256",
    " " <> compact <> " ; info = < " <> x5u <> " > ",
  ]
  list.each(hostile, fn(value) {
    case passport.parse_identity(value) {
      Error(_refused) -> Nil
      Ok(identity) ->
        case passport.verify(identity, certificate(), iat, 60) {
          Error(_refused) -> Nil
          Ok(verified) -> {
            // Accepted: then it is the signed claims, at the signed URL.
            assert verified == claims() as about(value)
            assert identity.x5u == x5u as about(value)
          }
        }
    }
  })

  // Two of these are worth naming, since they are the attack rather than
  // the noise. An `alg` parameter that disagrees with the token is a
  // refusal, not a hint; and the first `info` wins, so a second one
  // pointing elsewhere cannot move the fetch.
  let assert Ok(claimed_alg) =
    passport.parse_identity(compact <> ";info=<" <> x5u <> ">;alg=RS256")
  assert passport.verify(claimed_alg, certificate(), iat, 60)
    == Error(passport.Jws(jws.UnsupportedAlg))
  let assert Ok(two) =
    passport.parse_identity(
      compact <> ";info=<https://attacker.test/c.pem>;info=<" <> x5u <> ">",
    )
  assert two.x5u == "https://attacker.test/c.pem"
  assert passport.verify(two, certificate(), iat, 60)
    == Error(passport.X5uMismatch)
}

/// Sizes nobody sends on purpose: ten thousand parameters, a mebibyte of
/// separators, a mebibyte of token, a mebibyte of URL. Every one of them
/// is answered rather than waited on -- the suite as a whole is held to
/// seconds, so a parser that went quadratic here would show up as a
/// timeout.
pub fn huge_inputs_test() {
  let valid = header(claims())
  let many = string.repeat(";a=b", 10_000)
  let mebibyte = mutate.huge("a")
  let huge = [
    token(valid) <> ";info=<" <> x5u <> ">" <> many,
    token(valid) <> many <> ";info=<" <> x5u <> ">",
    string.repeat(";", 10_000) <> "info=<" <> x5u <> ">",
    mebibyte,
    mebibyte <> ";info=<" <> x5u <> ">",
    token(valid) <> ";info=<https://a.test/" <> mebibyte <> ">",
    token(valid) <> ";info=<" <> x5u <> ">;alg=" <> mebibyte,
    mutate.nested("<", ">", 4096) <> ";info=<" <> x5u <> ">",
  ]
  list.each(huge, fn(value) {
    case passport.parse_identity(value) {
      Error(_refused) -> Nil
      Ok(identity) ->
        case passport.verify(identity, certificate(), iat, 60) {
          Error(_refused) -> Nil
          Ok(verified) -> {
            assert verified == claims() as about(value)
            Nil
          }
        }
    }
  })

  // Ten thousand parameters beside a valid token is still that token:
  // the parameters are read, the signed bytes are not touched, and the
  // answer is the claims. Nothing about the size changes the verdict.
  let assert Ok(identity) =
    passport.parse_identity(token(valid) <> ";info=<" <> x5u <> ">" <> many)
  assert identity.x5u == x5u
  assert passport.verify(identity, certificate(), iat, 60) == Ok(claims())
}

/// Control characters, a byte order mark, a right-to-left override, an
/// astral character, CRLF for LF, deep nesting and a mebibyte, as the
/// whole value and as each part of one.
pub fn oddities_test() {
  let valid = header(claims())
  let values =
    list.flatten([
      mutate.oddities(),
      list.map(mutate.oddities(), fn(odd) { odd <> ";info=<" <> x5u <> ">" }),
      list.map(mutate.oddities(), fn(odd) {
        token(valid) <> ";info=<" <> odd <> ">"
      }),
      list.map(mutate.oddities(), fn(odd) {
        token(valid) <> ";info=<" <> x5u <> ">;alg=" <> odd
      }),
    ])
  list.each(values, fn(value) {
    case passport.parse_identity(value) {
      Error(_refused) -> Nil
      Ok(identity) ->
        case passport.verify(identity, certificate(), iat, 60) {
          Error(_refused) -> Nil
          Ok(verified) -> {
            assert verified == claims() as about(value)
            Nil
          }
        }
    }
  })
}

/// `canonical_tn` over the same shapes: a number is digits or it is
/// nothing, whatever the separators and the scripts say.
pub fn canonical_tn_is_digits_or_nothing_test() {
  let numbers =
    list.flatten([
      mutate.oddities(),
      [
        "+1 (202) 555-0100",
        "١٢٣٤",
        "1٢3",
        "12025550100\u{0}",
        "\u{202e}12025550100",
        "１２０２",
        "1-2-0-2",
        "+++",
        string.repeat("1", 1024),
        "12025550100\n",
        "12025550100\r\n",
      ],
    ])
  list.each(numbers, fn(number) {
    case passport.canonical_tn(number) {
      None -> Nil
      Some(digits) -> {
        // Whatever came in, what comes out is digits, and nothing else.
        assert string.length(digits) > 0 as about(number)
        list.each(string.to_graphemes(digits), fn(character) {
          assert list.contains(
            ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
            character,
          )
            as about(number)
        })
      }
    }
  })
  assert passport.canonical_tn(string.repeat("1", 1024))
    == Some(string.repeat("1", 1024))
  assert passport.canonical_tn("١٢٣٤") == None
}

/// FINDING (open): a header value whose bytes are not UTF-8 raises
/// rather than answering `Error(MalformedHeader)`.
///
/// `parse_identity` trims the token and `parameter` lowercases each
/// parameter name (`stir/passport.gleam`), and both
/// `string.trim` and `string.lowercase` are written to Gleam's promise
/// that a `String` is UTF-8: given bytes that are not, they raise
/// `function_clause` and `badarg` respectively. The value arrives as a
/// binary from a SIP header (`stir_maintenance.verify/1` and the
/// inbound hook), and a binary is not promised to be text, so
/// the module's own boundary -- every malformed header is `Error` -- is
/// not held at the byte level. Failing on purpose: the fix belongs in
/// the code, not in this expectation.
pub fn non_utf8_header_value_raises_test() {
  let not_text = mutate.unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
  assert passport.parse_identity(not_text) == Error(passport.MalformedHeader)
  assert passport.parse_identity(not_text <> ";info=<" <> x5u <> ">")
    == Error(passport.MalformedHeader)
  let assert Ok(identity) =
    passport.parse_identity(
      token(header(claims())) <> ";info=<" <> not_text <> ">",
    )
  assert passport.verify(identity, certificate(), iat, 60)
    == Error(passport.X5uMismatch)
}

/// A mutation, short enough to read in a failure message.
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
