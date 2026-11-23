//// `stir/stipa`'s CRL walk over a mutated revocation list.
////
//// The CRL is read by walking its DER rather than by decoding it,
//// precisely so that a list an attacker wrote cannot raise on the way
//// through (`stir/stipa`, the module doc). This suite is that claim
//// under mutation: the staging CRL is cut short, flipped, padded out,
//// repeated and spliced, served both as the PEM the STI-PA answers and
//// as raw DER, and `stipa.crl` is asked for each.
////
//// What may come back is an `Error` or a `Crl`, and a `Crl` must carry
//// a `next_update` a clock would recognise. A CRL that parses is not
//// thereby trusted: `stir/trust` hands it to `stir_ffi:validate_chain`,
//// which checks its signature against a signer that must chain to a
//// pinned root, and `hostile_pem_test` covers that side; before it
//// stores one it hands it to `stir_ffi:authenticate_crl`, which the
//// last test here holds to the same rule.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import stir/http.{type Transport}
import stir/http_test.{fake, fixture, ok}
import stir/stipa
import support/mutate

/// The staging CRL's URL, and the signer its AIA names: both fixed,
/// since the AIA must be https on the host the CRL came from.
const crl_url = "https://authenticate-api-stg.iconectiv.com/download/v1/crl"

const signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/external/certificate/crlCert_267913_20330824.crt"

/// 2026-09-12T15:40:44Z, the fixture CRL's own `nextUpdate`.
const crl_next_update = 1_789_227_644

/// A `next_update` a clock would recognise: 2020 to 2100. The module
/// answers the fetch time plus a day for a CRL that names none, so
/// anything outside this is a date read out of the attacker's bytes.
const earliest = 1_577_836_800

const latest = 4_102_444_800

fn transport(body: String, calls: Subject(String)) -> Transport {
  fake(
    [
      #(crl_url, ok(200, body)),
      #(signer_url, ok(200, fixture("stipa-stg-crl-signer.pem"))),
    ],
    calls,
    timeouts: [],
  )
}

/// Ask for the CRL with `body` as the answer, and say what came back.
fn fetch(body: String) -> Result(stipa.Crl, stipa.Error) {
  stipa.crl(transport(body, process.new_subject()), crl_url, 100)
}

/// The fixture, and the mutations of it that are still text: a
/// character changed, the PEM cut short, base64 confusions, characters
/// pushed in. The bytes that are not text are `der_mutations`, since a
/// PEM answer is text by construction and a DER answer is not.
fn pem_mutations(pem: String) -> List(String) {
  let seed = mutate.seed(5_280_711)
  let #(inserted, _seed) = mutate.text_insertions(pem, 120, seed)
  list.flatten([
    mutate.ascii_flips(pem, 23),
    mutate.text_truncations(pem, 29),
    mutate.base64_swaps(pem),
    inserted,
    mutate.oddities(),
  ])
}

fn der_mutations(der: String) -> List(String) {
  let bytes = bit_array.from_string(der)
  let seed = mutate.seed(9_119_711)
  let #(inserted, seed) = mutate.insertions(bytes, 100, seed)
  let #(duplicated, seed) = mutate.duplications(bytes, 80, seed)
  let #(spliced, _seed) =
    mutate.splices(
      bytes,
      bit_array.from_string(
        http_test.der_of(fixture("stipa-stg-crl-signer.pem")),
      ),
      80,
      seed,
    )
  list.flatten([
    mutate.truncations(bytes, 31),
    mutate.flips(bytes, 17),
    inserted,
    duplicated,
    spliced,
  ])
  |> list.map(mutate.unsafe_string)
}

/// The CRL as the STI-PA answers it, mutated: every answer is a
/// refusal or a CRL whose `next_update` is a date.
pub fn mutated_crl_pem_test() {
  let real = fixture("stipa-stg-crl.pem")
  let assert Ok(crl) = fetch(real)
  assert crl.next_update == crl_next_update

  let mutations = pem_mutations(real)
  assert list.length(mutations) > 400
  list.each(mutations, fn(mutation) {
    case fetch(mutation) {
      Error(_refused) -> Nil
      Ok(answered) -> {
        assert answered.next_update >= earliest as about(mutation)
        assert answered.next_update <= latest as about(mutation)
        // The signer is the one the AIA named and the transport
        // answered, never something the CRL's own bytes carried.
        assert answered.signer == fixture("stipa-stg-crl-signer.pem")
          as about(mutation)
      }
    }
  })
}

/// The same over raw DER, which is what a server that ignores the
/// STI-PA's content type answers, and what the walk actually reads.
pub fn mutated_crl_der_test() {
  let der = http_test.der_of(fixture("stipa-stg-crl.pem"))
  let assert Ok(crl) = fetch(der)
  assert crl.next_update == crl_next_update

  let mutations = der_mutations(der)
  assert list.length(mutations) > 400
  list.each(mutations, fn(mutation) {
    case fetch(mutation) {
      Error(_refused) -> Nil
      Ok(answered) -> {
        assert answered.next_update >= earliest as about(mutation)
        assert answered.next_update <= latest as about(mutation)
      }
    }
  })
}

/// The dates the walk reads out of the DER are the part that has to be
/// range-checked, since `calendar:datetime_to_gregorian_seconds` raises
/// on a month 13. Every byte of the `nextUpdate` field is flipped here,
/// one at a time, and the field is replaced with each of the shapes a
/// time field is not.
pub fn hostile_next_update_test() {
  let der = http_test.der_of(fixture("stipa-stg-crl.pem"))
  // `260912154044Z` as the fixture carries it, the 13 bytes of a
  // UTCTime; the walk reads whatever stands in its place.
  let real = "260912154044Z"
  assert string.contains(der, real)
  let stand_ins =
    list.flatten([
      mutate.ascii_flips(real, 1),
      [
        "991332235959Z",
        "000000000000Z",
        "999999999999Z",
        "26091215404!Z",
        "2609121540447",
        "\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}",
        "260912154060Z",
        "260912156044Z",
        "260912254044Z",
        "260932154044Z",
        "261312154044Z",
        "-60912154044Z",
        "260912154044 ",
        "260229154044Z",
        "240229154044Z",
      ],
    ])
  list.each(stand_ins, fn(stand_in) {
    // The replacement is the same length, so every other field of the
    // DER still stands where its length says it does.
    case string.length(stand_in) == string.length(real) {
      False -> Nil
      True ->
        case fetch(mutate.replace_bytes(der, real, stand_in)) {
          Error(_refused) -> Nil
          Ok(answered) -> {
            assert answered.next_update >= earliest as about(stand_in)
            assert answered.next_update <= latest as about(stand_in)
          }
        }
    }
  })
}

/// Bodies that are not a mutation of a CRL at all: nothing, a
/// mebibyte, deeply nested DER, a certificate where a CRL should be, a
/// CRL glued to another CRL.
pub fn hostile_crl_bodies_test() {
  let real = fixture("stipa-stg-crl.pem")
  let der = http_test.der_of(fixture("stipa-stg-crl.pem"))
  let bodies =
    list.flatten([
      mutate.oddities(),
      [
        mutate.huge("A"),
        "-----BEGIN X509 CRL-----\n"
          <> mutate.huge("A")
          <> "\n-----END X509 CRL-----\n",
        "-----BEGIN X509 CRL-----\n-----END X509 CRL-----\n",
        "-----BEGIN X509 CRL-----",
        "-----END X509 CRL-----\n-----BEGIN X509 CRL-----",
        real <> real,
        real <> fixture("test-cert.pem"),
        fixture("test-cert.pem") <> real,
        fixture("test-cert.pem"),
        der <> der,
        // A DER length header that promises far more than it carries.
        mutate.unsafe_string(<<0x30, 0x84, 0xff, 0xff, 0xff, 0xff>>),
        mutate.unsafe_string(<<0x30, 0x80, 0x30, 0x80, 0x30, 0x80>>),
        mutate.unsafe_string(<<0x30, 0x03, 0x30, 0x01>>),
        mutate.unsafe_string(<<0x30>>),
        // Nested sequences, a thousand deep.
        mutate.unsafe_string(nested_der(1000)),
      ],
    ])
  list.each(bodies, fn(body) {
    case fetch(body) {
      Error(_refused) -> Nil
      Ok(answered) -> {
        assert answered.next_update >= earliest as about(body)
        assert answered.next_update <= latest as about(body)
      }
    }
  })
}

/// FINDING (open): a CRL body that looks like PEM but whose bytes are
/// not UTF-8 raises rather than answering `Malformed`.
///
/// `crl_pem_and_der` takes the PEM branch on `string.contains`, which
/// is byte-safe, and then strips the newlines out of the body with
/// `string.replace` (`crl_pem_and_der` in `stir/stipa.gleam`), which
/// is not: given bytes
/// that are not UTF-8 it raises. The body is whatever the server at the
/// CRL's URL answered, which the module doc treats as attacker-chosen,
/// and the walk below it was written to read that DER without raising.
/// Failing on purpose.
pub fn non_utf8_crl_pem_raises_test() {
  let body =
    "-----BEGIN X509 CRL-----\n"
    <> mutate.unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
    <> "\n-----END X509 CRL-----\n"
  let assert Error(_) = fetch(body)
  Nil
}

/// `stir_ffi:authenticate_crl`, which `stir/trust` runs on every CRL
/// before it stores one, over the same mutations and bodies: it answers
/// and never raises, and what it accepts says of itself exactly what
/// the real CRL does -- OTP's PEM reader skips what is not base64, so a
/// mutation can decode to the same bytes, and nothing else passes the
/// signature.
pub fn authenticate_crl_never_raises_test() {
  let real = fixture("stipa-stg-crl.pem")
  let signer = fixture("stipa-stg-crl-signer.pem")
  let root = fixture("stipa-stg-root.pem")
  let now = crl_next_update - 3600
  let assert Ok(facts) = authenticate_crl(real, signer, root, now)
  assert facts == #(crl_next_update - 86_400, Some(crl_next_update), Some(2620))
  assert authenticate_crl("", signer, root, now) == Error("no CRL in PEM")
  let bodies =
    list.flatten([
      pem_mutations(real),
      mutate.oddities(),
      [real <> real, fixture("test-cert.pem"), real <> fixture("test-cert.pem")],
    ])
  list.each(bodies, fn(body) {
    case authenticate_crl(body, signer, root, now) {
      Error(_refused) -> Nil
      Ok(answered) -> {
        assert answered == facts as about(body)
      }
    }
    // The signer and the anchors are bytes too.
    let assert Error(_) = authenticate_crl(real, body, root, now)
    case authenticate_crl(real, signer, body, now) {
      Error(_refused) -> Nil
      Ok(answered) -> {
        assert answered == facts as about(body)
      }
    }
  })
}

/// `SEQUENCE` inside `SEQUENCE`, `depth` deep, each one holding the
/// next: what a decoder that recurses without a bound is fed.
fn nested_der(depth: Int) -> BitArray {
  list.fold(mutate.upto(depth), <<0x05, 0x00>>, fn(inner, _index) {
    let size = bit_array.byte_size(inner)
    case size < 128 {
      True -> <<0x30, size:8, inner:bits>>
      False -> <<0x30, 0x82, size:16, inner:bits>>
    }
  })
}

fn about(value: String) -> String {
  "mutation: " <> mutate.preview(value, 48)
}

@external(erlang, "stir_ffi", "authenticate_crl")
fn authenticate_crl(
  crl_pem: String,
  signer_pem: String,
  anchors_pem: String,
  now_unix: Int,
) -> Result(#(Int, Option(Int), Option(Int)), String)
