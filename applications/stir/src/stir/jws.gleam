//// JSON Web Signature, compact serialisation, ES256 only.
////
//// What a PASSporT is on the wire: `base64url(header).base64url(payload).base64url(signature)`
//// with the signature the raw 64-byte `R||S` of ECDSA P-256 over SHA-256
//// (RFC 7515 §3, RFC 7518 §3.4). The signing itself is a function the
//// caller supplies, so the private key never comes through this module:
//// the signer holds it and answers signatures.
////
//// Every function here is pure apart from the signing
//// closure and the FFI verify.

import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/doc.{type Value}

pub type Error {
  /// Not three dot-separated base64url parts.
  BadFormat
  /// The header names an algorithm other than ES256.
  UnsupportedAlg
  /// A part is not valid base64url or not JSON.
  BadEncoding
  /// The signature does not verify against the key given.
  BadSignature
  /// The signer answered an error.
  SignerFailed(String)
}

/// A parsed compact JWS: the two JSON parts, and what the signature covers.
pub type Parsed {
  Parsed(
    header: Value,
    payload: Value,
    /// `base64url(header).base64url(payload)`, the bytes that were signed.
    signing_input: String,
    /// The raw signature bytes (64 for ES256).
    signature: BitArray,
  )
}

/// A signer answers the raw `R||S` signature of the signing input, or why
/// it could not.
pub type Signer =
  fn(String) -> Result(BitArray, String)

/// The one algorithm SHAKEN uses (ATIS-1000074 §5.3.1).
pub const alg = "ES256"

/// Sign `header` and `payload` (already canonical JSON text) and answer the
/// compact serialisation.
pub fn sign(
  header: String,
  payload: String,
  signer: Signer,
) -> Result(String, Error) {
  let signing_input = signing_input(header, payload)
  case signer(signing_input) {
    Ok(signature) -> Ok(signing_input <> "." <> encode(signature))
    Error(reason) -> Error(SignerFailed(reason))
  }
}

/// Split a compact JWS into its parts without verifying anything.
///
/// The token arrives in an `Identity` header, which is a binary and is
/// not promised to be text, while Gleam's `String` says it is: the
/// standard library is written to that promise and raises on bytes that
/// are not UTF-8 (`bit_array.base64_url_decode` rewrites the alphabet
/// with `string.replace`, whose result it matches against a binary).
/// A compact JWS is base64url and separators and so is ASCII by
/// construction; anything else is refused here rather than left to
/// raise in a call-setup worker.
pub fn parse(compact: String) -> Result(Parsed, Error) {
  use <- text_or(compact, Error(BadEncoding))
  case string.split(compact, ".") {
    [header_part, payload_part, signature_part] ->
      case
        decode_json(header_part),
        decode_json(payload_part),
        decode(signature_part)
      {
        Some(header), Some(payload), Some(signature) ->
          Ok(Parsed(
            header:,
            payload:,
            signing_input: header_part <> "." <> payload_part,
            signature:,
          ))
        _, _, _ -> Error(BadEncoding)
      }
    _ -> Error(BadFormat)
  }
}

/// Verify a parsed JWS against a public key (a PEM public key or a PEM
/// certificate, either is accepted). Checks the algorithm is ES256 first.
///
/// A PEM holding both is a certificate: if it carries a certificate at
/// all, the first one's key is what verifies and every `PUBLIC KEY` block
/// in it is ignored, wherever it sits. That is what keeps a signer's
/// `x5u` honest, since the same PEM is validated as a chain and chain
/// validation reads only the certificates.
pub fn verify(parsed: Parsed, public_key_pem: String) -> Result(Nil, Error) {
  case doc.get_string(parsed.header, ["alg"]) {
    Ok(named) if named == alg ->
      case bit_array.byte_size(parsed.signature) == 64 {
        True ->
          case
            ecdsa_verify(public_key_pem, parsed.signing_input, parsed.signature)
          {
            True -> Ok(Nil)
            False -> Error(BadSignature)
          }
        False -> Error(BadSignature)
      }
    _ -> Error(UnsupportedAlg)
  }
}

/// base64url without padding, as JWS uses it.
pub fn encode(bytes: BitArray) -> String {
  bit_array.base64_url_encode(bytes, False)
}

pub fn decode(text: String) -> Option(BitArray) {
  // A padded input is not what JWS carries, and `=` inside a part is one of
  // the ways a header is smuggled past a parser: refuse it. Bytes that are
  // not UTF-8 are refused before the decoder, which raises on them.
  use <- text_or(text, None)
  case string.contains(text, "=") {
    True -> None
    False -> option.from_result(bit_array.base64_url_decode(text))
  }
}

/// Run `next` when `value` really is text, and answer `refusal` when its
/// bytes are not.
fn text_or(value: String, refusal: a, next: fn() -> a) -> a {
  case bit_array.is_utf8(bit_array.from_string(value)) {
    True -> next()
    False -> refusal
  }
}

fn signing_input(header: String, payload: String) -> String {
  encode(bit_array.from_string(header))
  <> "."
  <> encode(bit_array.from_string(payload))
}

fn decode_json(part: String) -> Option(Value) {
  case decode(part) {
    Some(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(text) ->
          case doc.parse(text) {
            Ok(value) ->
              case doc.is_object(value) {
                True -> Some(value)
                False -> None
              }
            Error(Nil) -> None
          }
        Error(Nil) -> None
      }
    None -> None
  }
}

@external(erlang, "stir_ffi", "ecdsa_verify")
fn ecdsa_verify(
  public_or_certificate_pem: String,
  message: String,
  signature: BitArray,
) -> Bool
