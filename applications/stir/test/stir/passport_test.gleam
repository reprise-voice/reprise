//// `stir/passport`: canonical JSON, the `Identity` header both ways, and
//// verification against the test certificate in `test/fixtures`.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import gleam/string
import kazoo/ffi
import stir/jws
import stir/passport.{Claims, Identity}

const x5u = "https://example.test/cert.pem"

const iat = 1_757_635_200

fn claims() -> passport.Claims {
  Claims(
    attest: "A",
    dest: ["12025550123"],
    iat: iat,
    orig: "12025550100",
    origid: "55f23c60-74cc-4b29-b2e3-3bac121f0c30",
  )
}

/// A signer over the fixed test key.
fn signer() -> jws.Signer {
  let key = fixture("test-key.pem")
  fn(input) { ecdsa_sign(key, input) }
}

pub fn canonical_json_test() {
  assert passport.header_json(x5u)
    == "{\"alg\":\"ES256\",\"ppt\":\"shaken\",\"typ\":\"passport\",\"x5u\":\"https://example.test/cert.pem\"}"
  assert passport.payload_json(claims())
    == "{\"attest\":\"A\",\"dest\":{\"tn\":[\"12025550123\"]},\"iat\":1757635200,\"orig\":{\"tn\":\"12025550100\"},\"origid\":\"55f23c60-74cc-4b29-b2e3-3bac121f0c30\"}"
  // Several destinations are sorted; a URL is escaped as JSON escapes it.
  assert passport.payload_json(Claims(..claims(), dest: ["2", "10", "1"]))
    == "{\"attest\":\"A\",\"dest\":{\"tn\":[\"1\",\"10\",\"2\"]},\"iat\":1757635200,\"orig\":{\"tn\":\"12025550100\"},\"origid\":\"55f23c60-74cc-4b29-b2e3-3bac121f0c30\"}"
  assert passport.header_json("https://a.test/\"x\"")
    == "{\"alg\":\"ES256\",\"ppt\":\"shaken\",\"typ\":\"passport\",\"x5u\":\"https://a.test/\\\"x\\\"\"}"
  // The signing input over these is the fixture signed by openssl.
  assert jws.encode(bit_array.from_string(passport.header_json(x5u)))
    <> "."
    <> jws.encode(bit_array.from_string(passport.payload_json(claims())))
    == fixture("test-message.txt")
}

pub fn build_and_verify_test() {
  let assert Ok(value) = passport.build(claims(), x5u, signer())
  assert string.ends_with(
    value,
    ";info=<https://example.test/cert.pem>;alg=ES256;ppt=shaken",
  )
  let assert Ok(identity) = passport.parse_identity(value)
  assert identity.x5u == x5u
  assert identity.alg == Some("ES256")
  assert identity.ppt == Some("shaken")
  let certificate = fixture("test-cert.pem")
  assert passport.verify(identity, certificate, iat, 60) == Ok(claims())
  assert passport.verify(identity, certificate, iat + 60, 60) == Ok(claims())
  assert passport.verify(identity, certificate, iat - 60, 60) == Ok(claims())
  // The public key alone verifies too.
  assert passport.verify(identity, fixture("test-key-pub.pem"), iat, 60)
    == Ok(claims())
}

pub fn stale_test() {
  let assert Ok(value) = passport.build(claims(), x5u, signer())
  let assert Ok(identity) = passport.parse_identity(value)
  let certificate = fixture("test-cert.pem")
  assert passport.verify(identity, certificate, iat + 61, 60)
    == Error(passport.Stale(age_s: 61))
  assert passport.verify(identity, certificate, iat - 61, 60)
    == Error(passport.Stale(age_s: -61))
}

pub fn signature_test() {
  let assert Ok(value) = passport.build(claims(), x5u, signer())
  let assert Ok(identity) = passport.parse_identity(value)
  // A certificate over another key.
  assert passport.verify(identity, fixture("example-999Y-chain.pem"), iat, 60)
    == Error(passport.Jws(jws.BadSignature))
  // A claim changed after signing.
  let assert Ok(forged) =
    passport.parse_identity(string.replace(
      value,
      jws.encode(bit_array.from_string(passport.payload_json(claims()))),
      jws.encode(
        bit_array.from_string(passport.payload_json(
          Claims(..claims(), attest: "B"),
        )),
      ),
    ))
  assert passport.verify(forged, fixture("test-cert.pem"), iat, 60)
    == Error(passport.Jws(jws.BadSignature))
}

pub fn x5u_mismatch_test() {
  let assert Ok(value) = passport.build(claims(), x5u, signer())
  let assert Ok(identity) = passport.parse_identity(value)
  let elsewhere = Identity(..identity, x5u: "https://example.test/other.pem")
  assert passport.verify(elsewhere, fixture("test-cert.pem"), iat, 60)
    == Error(passport.X5uMismatch)
}

/// A `;` inside the `x5u` is where the parameters are split, so the URL
/// the `info` parameter yields is cut short at it. This pins that the cut
/// is a refusal and never a pass: the truncated URL disagrees with the
/// `x5u` the signed header carries, so verification stops at
/// `X5uMismatch` before any certificate is fetched. RFC 8224 §4 does not
/// let a `;` stand unquoted in the parameter anyway, so nothing that
/// should verify is being refused here.
pub fn x5u_with_semicolon_fails_closed_test() {
  let awkward = "https://example.test/cert.pem?a=1;b=2"
  let assert Ok(value) = passport.build(claims(), awkward, signer())
  let assert Ok(identity) = passport.parse_identity(value)
  // Cut at the `;`, and the signed header still says the whole URL. The
  // opening `<` survives the cut, since the `>` that would have paired
  // with it is in the fragment after the `;`.
  assert identity.x5u == "<https://example.test/cert.pem?a=1"
  assert passport.verify(identity, fixture("test-cert.pem"), iat, 60)
    == Error(passport.X5uMismatch)
  // Nothing else about the header is wrong: the truncation alone is what
  // refuses it.
  let whole = Identity(..identity, x5u: awkward)
  assert passport.verify(whole, fixture("test-cert.pem"), iat, 60)
    == Ok(claims())
}

pub fn not_shaken_test() {
  let certificate = fixture("test-cert.pem")
  let payload = passport.payload_json(claims())
  let with_header = fn(header: String) {
    let assert Ok(compact) = jws.sign(header, payload, signer())
    Identity(compact:, x5u:, alg: None, ppt: None)
  }
  // The wrong extension, the wrong type, no extension.
  assert passport.verify(
      with_header(
        "{\"alg\":\"ES256\",\"ppt\":\"div\",\"typ\":\"passport\",\"x5u\":\""
        <> x5u
        <> "\"}",
      ),
      certificate,
      iat,
      60,
    )
    == Error(passport.NotShaken)
  assert passport.verify(
      with_header(
        "{\"alg\":\"ES256\",\"ppt\":\"shaken\",\"typ\":\"JWT\",\"x5u\":\""
        <> x5u
        <> "\"}",
      ),
      certificate,
      iat,
      60,
    )
    == Error(passport.NotShaken)
  assert passport.verify(
      with_header(
        "{\"alg\":\"ES256\",\"typ\":\"passport\",\"x5u\":\"" <> x5u <> "\"}",
      ),
      certificate,
      iat,
      60,
    )
    == Error(passport.NotShaken)
  // The header is right but the `Identity` parameters say otherwise.
  let good = with_header(passport.header_json(x5u))
  assert passport.verify(
      Identity(..good, ppt: Some("div")),
      certificate,
      iat,
      60,
    )
    == Error(passport.NotShaken)
  assert passport.verify(
      Identity(..good, alg: Some("RS256")),
      certificate,
      iat,
      60,
    )
    == Error(passport.Jws(jws.UnsupportedAlg))
  // Another algorithm in the header is refused before the signature.
  assert passport.verify(
      with_header(
        "{\"alg\":\"RS256\",\"ppt\":\"shaken\",\"typ\":\"passport\",\"x5u\":\""
        <> x5u
        <> "\"}",
      ),
      certificate,
      iat,
      60,
    )
    == Error(passport.Jws(jws.UnsupportedAlg))
}

pub fn missing_claim_test() {
  let certificate = fixture("test-cert.pem")
  let with_payload = fn(payload: String) {
    let assert Ok(compact) =
      jws.sign(passport.header_json(x5u), payload, signer())
    passport.verify(
      Identity(compact:, x5u:, alg: None, ppt: None),
      certificate,
      iat,
      60,
    )
  }
  assert with_payload(
      "{\"attest\":\"D\",\"dest\":{\"tn\":[\"1\"]},\"iat\":1757635200,\"orig\":{\"tn\":\"2\"},\"origid\":\"x\"}",
    )
    == Error(passport.MissingClaim("attest"))
  assert with_payload(
      "{\"attest\":\"A\",\"dest\":{\"tn\":[]},\"iat\":1757635200,\"orig\":{\"tn\":\"2\"},\"origid\":\"x\"}",
    )
    == Error(passport.MissingClaim("dest"))
  assert with_payload(
      "{\"attest\":\"A\",\"dest\":{\"uri\":[\"sip:a@b\"]},\"iat\":1757635200,\"orig\":{\"tn\":\"2\"},\"origid\":\"x\"}",
    )
    == Error(passport.MissingClaim("dest"))
  assert with_payload(
      "{\"attest\":\"A\",\"dest\":{\"tn\":[\"1\"]},\"iat\":\"soon\",\"orig\":{\"tn\":\"2\"},\"origid\":\"x\"}",
    )
    == Error(passport.MissingClaim("iat"))
  assert with_payload(
      "{\"attest\":\"A\",\"dest\":{\"tn\":[\"1\"]},\"iat\":1757635200,\"orig\":{},\"origid\":\"x\"}",
    )
    == Error(passport.MissingClaim("orig"))
  assert with_payload(
      "{\"attest\":\"A\",\"dest\":{\"tn\":[\"1\"]},\"iat\":1757635200,\"orig\":{\"tn\":\"2\"}}",
    )
    == Error(passport.MissingClaim("origid"))
}

pub fn parse_identity_test() {
  let expected =
    Identity(
      compact: "a.b.c",
      x5u: x5u,
      alg: Some("ES256"),
      ppt: Some("shaken"),
    )
  assert passport.parse_identity(
      "a.b.c;info=<https://example.test/cert.pem>;alg=ES256;ppt=shaken",
    )
    == Ok(expected)
  // Any order, no brackets, spaces, upper-case names, quotes.
  assert passport.parse_identity(
      "a.b.c; ppt=shaken; ALG=ES256; info=https://example.test/cert.pem",
    )
    == Ok(expected)
  assert passport.parse_identity(
      "a.b.c;info=\"<https://example.test/cert.pem>\"",
    )
    == Ok(Identity(compact: "a.b.c", x5u: x5u, alg: None, ppt: None))
  // No `info`, no token.
  assert passport.parse_identity("a.b.c;alg=ES256")
    == Error(passport.MalformedHeader)
  assert passport.parse_identity("a.b.c") == Error(passport.MalformedHeader)
  assert passport.parse_identity(";info=<https://example.test/cert.pem>")
    == Error(passport.MalformedHeader)
  assert passport.parse_identity("") == Error(passport.MalformedHeader)
  // A token that is not a JWS is the JWS layer's error, not this one's.
  let assert Ok(not_a_jws) =
    passport.parse_identity("nope;info=<https://example.test/cert.pem>")
  assert passport.verify(not_a_jws, fixture("test-cert.pem"), iat, 60)
    == Error(passport.Jws(jws.BadFormat))
}

pub fn canonical_tn_test() {
  assert passport.canonical_tn("+1 (202) 555-0100") == Some("12025550100")
  assert passport.canonical_tn("12025550100") == Some("12025550100")
  assert passport.canonical_tn("+44.20.7946.0958") == Some("442079460958")
  assert passport.canonical_tn("") == None
  assert passport.canonical_tn("+ ( ) - .") == None
  assert passport.canonical_tn("anonymous") == None
  assert passport.canonical_tn("+1 202 555 0100 x12") == None
}

/// The header value is a binary off the wire and its bytes are not
/// promised to be UTF-8, where Gleam's `String` says they are:
/// `string.trim` and `string.lowercase` raise on bytes that are not.
/// A header is refused, never raised on; and a parameter whose value
/// carries such bytes is read as what it is, which is not the `x5u`
/// that was signed.
pub fn non_utf8_header_test() {
  let not_text = unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
  assert passport.parse_identity(not_text) == Error(passport.MalformedHeader)
  assert passport.parse_identity(not_text <> ";info=<" <> x5u <> ">")
    == Error(passport.MalformedHeader)
  assert passport.parse_identity("a.b.c;" <> not_text <> "=1")
    == Error(passport.MalformedHeader)
  let assert Ok(identity) =
    passport.parse_identity("a.b.c;info=<" <> not_text <> ">")
  assert identity.x5u != x5u
  assert passport.verify(identity, fixture("test-cert.pem"), iat, 60)
    == Error(passport.Jws(jws.BadEncoding))
  // A number is digits or it is nothing, whatever the bytes are.
  assert passport.canonical_tn(not_text) == None
  assert passport.canonical_tn("1202" <> not_text) == None
}

/// A header nobody sends on purpose is answered, not chewed on: ten
/// thousand parameters and a mebibyte of value, each read once.
///
/// The parser splits on `;` and reads each part on its own, so the work
/// is linear in the value; a parser that rebuilt the value as it went
/// would be quadratic here, and a call-setup worker would sit in it.
pub fn huge_header_is_linear_test() {
  let many = string.repeat(";a=b", 10_000)
  let mebibyte = string.repeat("a", 1_048_576)
  let started = ffi.now_s()
  let assert Ok(identity) =
    passport.parse_identity("a.b.c;info=<" <> x5u <> ">" <> many)
  assert identity.x5u == x5u
  let assert Ok(long) =
    passport.parse_identity("a.b.c;info=<https://a.test/" <> mebibyte <> ">")
  assert string.byte_size(long.x5u) > 1_048_576
  let assert Ok(_) =
    passport.parse_identity("a.b.c;info=<" <> x5u <> ">;alg=" <> mebibyte)
  // Generous: the three of them together are milliseconds on any
  // machine that can run the suite at all, and a quadratic parser takes
  // minutes over ten thousand parameters.
  assert ffi.now_s() - started < 5
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  string.trim_end(text)
}

/// A binary as a `String` without checking that it is text: what a SIP
/// header actually carries.
@external(erlang, "erlang", "iolist_to_binary")
fn unsafe_string(bytes: BitArray) -> String

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: String,
  message: String,
) -> Result(BitArray, String)
