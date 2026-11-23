//// PASSporT (RFC 8225) with the SHAKEN extension (RFC 8588, ATIS-1000074),
//// and the `Identity` header that carries it (RFC 8224).
////
//// Building: the header is `{"alg":"ES256","ppt":"shaken","typ":"passport","x5u":"<url>"}`,
//// the payload `{"attest":"A","dest":{"tn":["..."]},"iat":<unix>,"orig":{"tn":"..."},"origid":"<uuid>"}`,
//// both serialised canonically: members in lexicographic order, no
//// whitespace (RFC 8225 §9). Numbers are digits only, no `+`.
////
//// Verifying: parse the header value, check the JWS against the
//// certificate the caller fetched from the `x5u`, then the claims:
//// freshness, the algorithm and extension names, and the numbers.
////
//// Pure apart from the signer closure.

import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import stir/jws

/// The SHAKEN claims.
pub type Claims {
  Claims(
    /// `A`, `B` or `C`.
    attest: String,
    /// Destination numbers, digits only, at least one.
    dest: List(String),
    /// Unix seconds.
    iat: Int,
    /// Origination number, digits only.
    orig: String,
    /// An opaque UUID.
    origid: String,
  )
}

/// An `Identity` header value, taken apart.
pub type Identity {
  Identity(
    /// The compact JWS.
    compact: String,
    /// The `info=<...>` parameter: where the certificate is.
    x5u: String,
    /// The `alg=` parameter, when present.
    alg: Option(String),
    /// The `ppt=` parameter, when present.
    ppt: Option(String),
  )
}

pub type VerifyError {
  /// The header value is not `jws;info=<url>;...`.
  MalformedHeader
  /// Something wrong with the JWS itself.
  Jws(jws.Error)
  /// `ppt` is not `shaken` or `typ` is not `passport`.
  NotShaken
  /// The header's `x5u` and the `info` parameter disagree.
  X5uMismatch
  /// `iat` is further from now than the window allows.
  Stale(age_s: Int)
  /// A required claim is missing or malformed.
  MissingClaim(String)
}

/// The JWS `typ` of a PASSporT (RFC 8225 §4.1).
pub const typ = "passport"

/// The PASSporT extension SHAKEN defines (RFC 8588 §4).
pub const ppt = "shaken"

/// Build the header value: `<jws>;info=<x5u>;alg=ES256;ppt=shaken`.
pub fn build(
  claims: Claims,
  x5u: String,
  signer: jws.Signer,
) -> Result(String, jws.Error) {
  use compact <- result.try(jws.sign(
    header_json(x5u),
    payload_json(claims),
    signer,
  ))
  Ok(compact <> ";info=<" <> x5u <> ">;alg=" <> jws.alg <> ";ppt=" <> ppt)
}

/// The canonical JSON of the JWS header for `x5u`.
pub fn header_json(x5u: String) -> String {
  "{\"alg\":"
  <> json_string(jws.alg)
  <> ",\"ppt\":"
  <> json_string(ppt)
  <> ",\"typ\":"
  <> json_string(typ)
  <> ",\"x5u\":"
  <> json_string(x5u)
  <> "}"
}

/// The canonical JSON of the claims. The destination numbers are sorted,
/// as RFC 8225 §5.2.1 asks of the `dest` arrays.
pub fn payload_json(claims: Claims) -> String {
  let dest =
    claims.dest
    |> list.sort(string.compare)
    |> list.map(json_string)
    |> string.join(",")
  "{\"attest\":"
  <> json_string(claims.attest)
  <> ",\"dest\":{\"tn\":["
  <> dest
  <> "]},\"iat\":"
  <> int.to_string(claims.iat)
  <> ",\"orig\":{\"tn\":"
  <> json_string(claims.orig)
  <> "},\"origid\":"
  <> json_string(claims.origid)
  <> "}"
}

/// Take an `Identity` header value apart. Accepts the parameters in any
/// order and with or without the angle brackets around the URL.
///
/// The value is a SIP header written by a carrier peer: a binary, with
/// no promise that its bytes are UTF-8, where Gleam's `String` says
/// they are. `string.trim` and `string.lowercase` are written to that
/// promise and raise on bytes that are not (a `badarg` out of
/// `string:lowercase_bin/3`, a `function_clause` out of the trimmer),
/// and a raise here is a call that fails rather than a header that is
/// refused. So every step that reads the *shape* of the value works on
/// bytes -- splitting, prefixes, comparison -- and the steps that read
/// it as text are asked only of the parts that are text. A part that is
/// not is carried through as it came: it will not match the signed
/// `x5u`, and the token will not parse. The token itself is the
/// exception: a compact JWS is base64url and two dots, so it is ASCII
/// by construction, and bytes that are not text are not a token.
pub fn parse_identity(value: String) -> Result(Identity, VerifyError) {
  case split_bytes(value, ";") {
    [first, ..rest] -> {
      let compact = trim(first)
      use <- text_or(compact, Error(MalformedHeader))
      let params = list.filter_map(rest, parameter)
      case compact, list.key_find(params, "info") {
        "", _ -> Error(MalformedHeader)
        _, Error(Nil) -> Error(MalformedHeader)
        _, Ok(info) ->
          Ok(Identity(
            compact:,
            x5u: unbracket(info),
            alg: option.from_result(list.key_find(params, "alg")),
            ppt: option.from_result(list.key_find(params, "ppt")),
          ))
      }
    }
    [] -> Error(MalformedHeader)
  }
}

/// The claims of an `Identity` header, verified against the certificate
/// fetched from its `x5u`: signature, `ppt`/`typ`, `x5u` agreement,
/// freshness (`iat` within `max_age_s` of `now`, unix seconds, in either
/// direction), and the claims' shape. Number matching against the call is
/// the caller's, since it knows what the call carried.
pub fn verify(
  identity: Identity,
  certificate_pem: String,
  now: Int,
  max_age_s: Int,
) -> Result(Claims, VerifyError) {
  use parsed <- result.try(jws.parse(identity.compact) |> result.map_error(Jws))
  use _ <- result.try(check_shaken(parsed.header, identity))
  use _ <- result.try(check_x5u(parsed.header, identity))
  use _ <- result.try(
    jws.verify(parsed, certificate_pem) |> result.map_error(Jws),
  )
  use claims <- result.try(claims(parsed.payload))
  let age = now - claims.iat
  case int.absolute_value(age) > max_age_s {
    True -> Error(Stale(age_s: age))
    False -> Ok(claims)
  }
}

/// A telephone number as a PASSporT carries it: digits only, no `+`, no
/// visual separators. `None` when nothing is left, or when what is left
/// is not a number.
pub fn canonical_tn(number: String) -> Option(String) {
  use <- text_or(number, None)
  let kept =
    number
    |> string.to_graphemes
    |> list.filter(fn(c) { !list.contains(separators, c) })
  case kept, list.all(kept, is_digit) {
    [], _ -> None
    _, False -> None
    _, True -> Some(string.concat(kept))
  }
}

const separators = ["+", " ", "-", ".", "(", ")"]

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn json_string(text: String) -> String {
  json.to_string(json.string(text))
}

/// One `name=value` parameter, its name lowercased.
fn parameter(text: String) -> Result(#(String, String), Nil) {
  // `string:split/2` matches bytes, so the split itself is safe on any
  // value; the trimming and the lowercasing are not.
  case string.split_once(trim(text), "=") {
    Ok(#(name, value)) -> Ok(#(lowercase(trim(name)), trim(value)))
    Error(Nil) -> Error(Nil)
  }
}

/// The URL inside `<...>`, and inside `"..."` for a sender that quoted it.
fn unbracket(info: String) -> String {
  use <- text_or(info, info)
  info
  |> strip("\"", "\"")
  |> strip("<", ">")
}

/// Split on a separator, byte by byte.
///
/// `string.split` is not that: it goes through a `StringTree`, whose
/// `to_string` is `unicode:characters_to_binary/1` matched against a
/// binary, and for bytes that are not UTF-8 that function answers a
/// three-tuple and the match is a crash. `string.split_once` is the
/// byte-level one -- `string:split/2`, whose pieces come back as they
/// went in -- so the walk is written on top of it.
fn split_bytes(value: String, on separator: String) -> List(String) {
  split_loop(value, separator, []) |> list.reverse
}

fn split_loop(
  value: String,
  separator: String,
  so_far: List(String),
) -> List(String) {
  case string.split_once(value, separator) {
    Ok(#(first, rest)) -> split_loop(rest, separator, [first, ..so_far])
    Error(Nil) -> [value, ..so_far]
  }
}

/// Whitespace off both ends, of a value that is text.
fn trim(value: String) -> String {
  use <- text_or(value, value)
  string.trim(value)
}

/// A parameter name folded, when it is text. A name whose bytes are not
/// is left as it came: it is not `info`, `alg` or `ppt` either way.
fn lowercase(value: String) -> String {
  use <- text_or(value, value)
  string.lowercase(value)
}

/// Run `next` when `value` really is text, and answer `refusal` when its
/// bytes are not.
fn text_or(value: String, refusal: a, next: fn() -> a) -> a {
  case bit_array.is_utf8(bit_array.from_string(value)) {
    True -> next()
    False -> refusal
  }
}

fn strip(text: String, open: String, close: String) -> String {
  case string.starts_with(text, open) && string.ends_with(text, close) {
    True ->
      text
      |> string.drop_start(string.length(open))
      |> string.drop_end(string.length(close))
    False -> text
  }
}

/// The header says PASSporT with the SHAKEN extension, and so do the
/// `Identity` parameters when they are present at all.
fn check_shaken(header: Value, identity: Identity) -> Result(Nil, VerifyError) {
  let named_typ = doc.get_string(header, ["typ"])
  let named_ppt = doc.get_string(header, ["ppt"])
  let parameter_ppt = case identity.ppt {
    Some(named) -> named == ppt
    None -> True
  }
  case named_typ == Ok(typ) && named_ppt == Ok(ppt) && parameter_ppt {
    True ->
      case identity.alg {
        Some(named) if named != jws.alg -> Error(Jws(jws.UnsupportedAlg))
        _ -> Ok(Nil)
      }
    False -> Error(NotShaken)
  }
}

fn check_x5u(header: Value, identity: Identity) -> Result(Nil, VerifyError) {
  case doc.get_string(header, ["x5u"]) {
    Ok(named) if named == identity.x5u -> Ok(Nil)
    _ -> Error(X5uMismatch)
  }
}

fn claims(payload: Value) -> Result(Claims, VerifyError) {
  use attest <- result.try(case doc.get_string(payload, ["attest"]) {
    Ok("A") -> Ok("A")
    Ok("B") -> Ok("B")
    Ok("C") -> Ok("C")
    _ -> Error(MissingClaim("attest"))
  })
  use dest <- result.try(case doc.get(payload, ["dest", "tn"]) {
    Ok(doc.List([_, ..] as numbers)) ->
      case list.try_map(numbers, number) {
        Ok(dest) -> Ok(dest)
        Error(Nil) -> Error(MissingClaim("dest"))
      }
    _ -> Error(MissingClaim("dest"))
  })
  use iat <- result.try(
    doc.get_int(payload, ["iat"]) |> result.replace_error(MissingClaim("iat")),
  )
  use orig <- result.try(
    doc.get(payload, ["orig", "tn"])
    |> result.try(number)
    |> result.replace_error(MissingClaim("orig")),
  )
  use origid <- result.try(case doc.get_string(payload, ["origid"]) {
    Ok("") -> Error(MissingClaim("origid"))
    Ok(origid) -> Ok(origid)
    Error(Nil) -> Error(MissingClaim("origid"))
  })
  Ok(Claims(attest:, dest:, iat:, orig:, origid:))
}

/// A `tn` value: a non-empty string. Whether it is the number the call
/// carried is the caller's to decide.
fn number(value: Value) -> Result(String, Nil) {
  case value {
    doc.String("") -> Error(Nil)
    doc.String(tn) -> Ok(tn)
    _ -> Error(Nil)
  }
}
