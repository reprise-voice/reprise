//// `stir/jws`: base64url, the compact serialisation, and ES256 verification
//// against a known answer (RFC 7515 Appendix A.3) and a fresh key.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import gleam/string
import kazoo/doc
import stir/jws

/// RFC 7515 Appendix A.3: the ES256 example, with its public key turned
/// into `test/fixtures/rfc7515-a3-pub.pem` by openssl from the JWK.
const rfc7515_a3 = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"

pub fn base64url_test() {
  assert jws.encode(<<"hi">>) == "aGk"
  assert jws.encode(<<"hi!">>) == "aGkh"
  // `+` and `/` become `-` and `_`.
  assert jws.encode(<<0xfb, 0xff>>) == "-_8"
  assert jws.decode("aGk") == Some(<<"hi">>)
  assert jws.decode("-_8") == Some(<<0xfb, 0xff>>)
  assert jws.decode("") == Some(<<>>)
  // Padding is not part of the serialisation.
  assert jws.decode("aGk=") == None
  assert jws.decode("not base64!") == None
}

pub fn sign_test() {
  let signer = fn(input: String) {
    assert input == "eyJhbGciOiJFUzI1NiJ9.e30"
    Ok(<<1, 2, 3>>)
  }
  assert jws.sign("{\"alg\":\"ES256\"}", "{}", signer)
    == Ok("eyJhbGciOiJFUzI1NiJ9.e30.AQID")
  assert jws.sign("{}", "{}", fn(_) { Error("no key") })
    == Error(jws.SignerFailed("no key"))
}

pub fn parse_test() {
  let assert Ok(parsed) = jws.parse(rfc7515_a3)
  assert doc.get_string(parsed.header, ["alg"]) == Ok("ES256")
  assert doc.get_string(parsed.payload, ["iss"]) == Ok("joe")
  assert doc.get_int(parsed.payload, ["exp"]) == Ok(1_300_819_380)
  assert bit_array.byte_size(parsed.signature) == 64
  assert parsed.signing_input
    == "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ"

  assert jws.parse("") == Error(jws.BadFormat)
  assert jws.parse("a.b") == Error(jws.BadFormat)
  assert jws.parse("a.b.c.d") == Error(jws.BadFormat)
  // Valid base64url that is not JSON, JSON that is not an object, and
  // something that is not base64url at all.
  assert jws.parse("aGk.e30.AQID") == Error(jws.BadEncoding)
  assert jws.parse("WzFd.e30.AQID") == Error(jws.BadEncoding)
  assert jws.parse("e30.e30.***") == Error(jws.BadEncoding)
}

pub fn known_answer_test() {
  let public_key = fixture("rfc7515-a3-pub.pem")
  let assert Ok(parsed) = jws.parse(rfc7515_a3)
  assert jws.verify(parsed, public_key) == Ok(Nil)

  // A changed payload, and a changed signature.
  let assert [header, _, signature] = string.split(rfc7515_a3, ".")
  let assert Ok(tampered) =
    jws.parse(
      header <> "." <> jws.encode(<<"{\"iss\":\"jim\"}">>) <> "." <> signature,
    )
  assert jws.verify(tampered, public_key) == Error(jws.BadSignature)
  let assert Ok(forged) =
    jws.parse(string.replace(rfc7515_a3, "DtEhU3lj", "DtEhU3lk"))
  assert jws.verify(forged, public_key) == Error(jws.BadSignature)

  // Another key.
  assert jws.verify(parsed, fixture("test-key-pub.pem"))
    == Error(jws.BadSignature)
}

/// The algorithm is checked before the signature is looked at: a token
/// naming another algorithm is refused even when its bytes would verify.
pub fn algorithm_before_signature_test() {
  let assert Ok(parsed) = jws.parse(rfc7515_a3)
  let renamed =
    jws.Parsed(..parsed, header: doc.object([#("alg", doc.String("RS256"))]))
  assert jws.verify(renamed, fixture("rfc7515-a3-pub.pem"))
    == Error(jws.UnsupportedAlg)
  let unnamed = jws.Parsed(..parsed, header: doc.object([]))
  assert jws.verify(unnamed, fixture("rfc7515-a3-pub.pem"))
    == Error(jws.UnsupportedAlg)
  // A signature of the wrong length never reaches the key.
  let short = jws.Parsed(..parsed, signature: <<1, 2, 3>>)
  assert jws.verify(short, fixture("rfc7515-a3-pub.pem"))
    == Error(jws.BadSignature)
}

/// Sign with a key generated here, verify with its public key and with a
/// certificate over the same key.
pub fn round_trip_test() {
  let private_key = generate_ec_key()
  let assert Ok(public_key) = public_key_pem(private_key)
  let signer = fn(input) { ecdsa_sign(private_key, input) }
  let assert Ok(compact) = jws.sign("{\"alg\":\"ES256\"}", "{\"a\":1}", signer)
  let assert Ok(parsed) = jws.parse(compact)
  assert jws.verify(parsed, public_key) == Ok(Nil)
  // A certificate over another key does not verify it.
  assert jws.verify(parsed, fixture("test-cert.pem")) == Error(jws.BadSignature)

  let test_key = fixture("test-key.pem")
  let assert Ok(signed) =
    jws.sign("{\"alg\":\"ES256\"}", "{\"a\":1}", fn(input) {
      ecdsa_sign(test_key, input)
    })
  let assert Ok(parsed) = jws.parse(signed)
  assert jws.verify(parsed, fixture("test-cert.pem")) == Ok(Nil)
  assert jws.verify(parsed, fixture("test-key-pub.pem")) == Ok(Nil)
}

/// A token arrives as the bytes of a SIP header, and a binary is not
/// promised to be text where Gleam's `String` says it is: the standard
/// library's base64url decoder rewrites the alphabet with
/// `string.replace` and matches the result against a binary, which is a
/// `badmatch` for bytes that are not UTF-8. A refusal, not a raise: a
/// `function_clause` in a call-setup worker is an outage.
pub fn non_utf8_is_refused_test() {
  let not_text = unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
  assert jws.decode(not_text) == None
  assert jws.parse(not_text) == Error(jws.BadEncoding)
  assert jws.parse(not_text <> "." <> not_text <> "." <> not_text)
    == Error(jws.BadEncoding)
  // One part of three is enough.
  let assert [header, payload, signature] = string.split(rfc7515_a3, ".")
  assert jws.parse(not_text <> "." <> payload <> "." <> signature)
    == Error(jws.BadEncoding)
  assert jws.parse(header <> "." <> payload <> "." <> not_text)
    == Error(jws.BadEncoding)
  // And the text that is text still reads.
  let assert Ok(_) = jws.parse(rfc7515_a3)
  Nil
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

/// A binary as a `String` without checking that it is text: what a SIP
/// header actually carries.
@external(erlang, "erlang", "iolist_to_binary")
fn unsafe_string(bytes: BitArray) -> String

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "stir_ffi", "generate_ec_key")
fn generate_ec_key() -> String

@external(erlang, "stir_ffi", "public_key_pem")
fn public_key_pem(private_key_pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: String,
  message: String,
) -> Result(BitArray, String)
