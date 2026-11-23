//// The STI-PA (iconectiv) as a client sees it without logging in: the
//// trusted CA list and the CRL.
////
//// `GET <base>/api/v1/ca-list` answers `{"caList": "<JWT>"}`: an ES256 JWT
//// whose header carries an `x5u` to the list-signing certificate and whose
//// payload is `{version, sequence, exp, trustList: [PEM, ...]}`. The CRL at
//// the URL every SHAKEN certificate names is an indirect CRL signed by
//// `CN=STI-PA CRL`, with an AIA extension pointing at its signer.
////
//// The CRL is read here rather than through `public_key`: its `nextUpdate`
//// and the AIA `caIssuers` URL are two fields a few levels into the DER,
//// and a walk over the DER's tag-length-value elements (`element`) reaches
//// both without decoding the thousands of revoked entries between them,
//// and without a call that raises on bad input. What the walk does not
//// find is answered conservatively: no `nextUpdate` means the fetch time
//// plus a day, the CRL's own lifetime, and so does a `nextUpdate` whose
//// fields are out of range: a CRL is not a trusted document, and a date
//// nobody can read must not take the call down with it.
////
//// Both follow-on fetches -- the list signer's `x5u` and the CRL
//// signer's AIA URL -- are `https` on the host *and port* the answer
//// they came in came from. They are URLs a document names, not URLs an
//// operator configured, so a tampered or mis-issued answer cannot walk
//// this node onto a server of its choosing, nor onto another port of
//// the one it is talking to.
////
//// Every body here is bytes a server chose, and a `String` on the BEAM
//// is a binary whether or not it holds text: each one is checked to be
//// UTF-8 before any `gleam/string` call touches it, since those raise on
//// bytes that are not. A body that is not text is not a PEM; it is
//// either DER, which is read as bytes, or a refusal.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import kazoo/doc.{type Value}
import kazoo/ffi
import stir/http.{type Transport}
import stir/jws

pub type Error {
  Fetch(http.Error)
  /// Not the shape described above.
  Malformed(String)
  /// The list's signature does not verify against its signer, or the
  /// signer does not chain to a trusted root.
  Untrusted(String)
}

pub type CaList {
  CaList(
    version: String,
    sequence: Int,
    /// Unix seconds.
    expires: Int,
    /// Every certificate in the list, PEM.
    certificates: List(String),
    /// The certificate that signed the list, PEM, fetched from the JWT's
    /// `x5u`.
    signer: String,
  )
}

pub type Crl {
  Crl(
    /// The CRL, PEM.
    pem: String,
    /// Its signer's certificate, PEM, fetched from the CRL's AIA.
    signer: String,
    /// Next update, unix seconds.
    next_update: Int,
  )
}

pub const ca_list_path = "/api/v1/ca-list"

const certificate_marker = "-----BEGIN CERTIFICATE-----"

const crl_begin = "-----BEGIN X509 CRL-----"

const crl_end = "-----END X509 CRL-----"

/// A CRL that names no `nextUpdate` is taken to last this long.
const crl_lifetime_s = 86_400

/// Fetch and parse the CA list. `trusted_roots` are PEMs the list's signer
/// must chain to; empty means the signer is accepted as found (first run)
/// and the caller decides whether to trust it.
///
/// The chain check is at the wall clock, the one time a client with no
/// `Kazoo` record has; a caller that holds time still for a test checks
/// the signer itself with `trusted_roots` empty.
pub fn ca_list(
  transport: Transport,
  base_url: String,
  trusted_roots: List(String),
  timeout_ms: Int,
) -> Result(CaList, Error) {
  use body <- result.try(get(transport, base_url <> ca_list_path, timeout_ms))
  use _ <- result.try(case utf8(body) {
    True -> Ok(Nil)
    False -> Error(Malformed("the CA list is not text"))
  })
  use envelope <- result.try(
    doc.parse(body)
    |> result.replace_error(Malformed("the CA list is not JSON")),
  )
  use compact <- result.try(
    doc.get_string(envelope, ["caList"])
    |> result.replace_error(Malformed("no caList in the answer")),
  )
  use parsed <- result.try(
    jws.parse(compact)
    |> result.map_error(fn(error) {
      Malformed("caList is not a JWS: " <> jws_error(error))
    }),
  )
  use x5u <- result.try(
    doc.get_string(parsed.header, ["x5u"])
    |> result.replace_error(Malformed("no x5u in the caList header")),
  )
  use _ <- result.try(follow_on(base_url, x5u, "the caList x5u"))
  use signer <- result.try(certificate(transport, x5u, timeout_ms))
  use _ <- result.try(
    jws.verify(parsed, signer)
    |> result.map_error(fn(error) {
      Untrusted("the caList signature: " <> jws_error(error))
    }),
  )
  use _ <- result.try(chains(signer, trusted_roots))
  use version <- result.try(version(parsed.payload))
  use sequence <- result.try(
    doc.get_int(parsed.payload, ["sequence"])
    |> result.replace_error(Malformed("no sequence in the caList")),
  )
  use expires <- result.try(
    doc.get_int(parsed.payload, ["exp"])
    |> result.replace_error(Malformed("no exp in the caList")),
  )
  use certificates <- result.try(trust_list(parsed.payload))
  Ok(CaList(version:, sequence:, expires:, certificates:, signer:))
}

/// Fetch the CRL at `url` and its signer.
pub fn crl(
  transport: Transport,
  url: String,
  timeout_ms: Int,
) -> Result(Crl, Error) {
  use body <- result.try(get(transport, url, timeout_ms))
  use #(pem, der) <- result.try(crl_pem_and_der(body))
  use fields <- result.try(
    crl_fields(der)
    |> result.replace_error(Malformed("the CRL's DER could not be read")),
  )
  use aia <- result.try(option.to_result(
    fields.ca_issuers,
    Malformed("the CRL names no signer: no AIA caIssuers URL"),
  ))
  use _ <- result.try(follow_on(url, aia, "the CRL's AIA caIssuers URL"))
  use signer <- result.try(certificate(transport, aia, timeout_ms))
  let next_update = case fields.next_update {
    Some(at) -> at
    None -> ffi.now_s() + crl_lifetime_s
  }
  Ok(Crl(pem:, signer:, next_update:))
}

// ---------------------------------------------------------------------------
// Fetching
// ---------------------------------------------------------------------------

/// Whether a URL one of the STI-PA's own answers names may be followed:
/// `https`, on the host *and the port* the answer itself came from. The
/// port counts: `https://host:8443/...` is a different server from
/// `https://host/...`, and a document that names one when the answer came
/// from the other is walking this node somewhere it did not ask to go. An
/// absent port is 443, which is what a URL with no port means. `what`
/// names the URL in the refusal.
fn follow_on(source: String, url: String, what: String) -> Result(Nil, Error) {
  let expected = case origin(source) {
    Ok(#(_scheme, host, port)) -> #(host, port)
    Error(Nil) -> #("", 0)
  }
  let #(expected_host, expected_port) = expected
  case origin(url) {
    Ok(#("https", host, port))
      if expected_host != "" && host == expected_host && port == expected_port
    -> Ok(Nil)
    _ ->
      Error(Untrusted(
        what
        <> " "
        <> url
        <> " is not https on "
        <> expected_host
        <> ":"
        <> int.to_string(expected_port),
      ))
  }
}

/// A URL's scheme and host, both lowercased, and its port, 443 when it
/// names none.
fn origin(url: String) -> Result(#(String, String, Int), Nil) {
  case utf8(url) {
    False -> Error(Nil)
    True ->
      case uri.parse(url) {
        Error(Nil) -> Error(Nil)
        Ok(parsed) ->
          case parsed.scheme, parsed.host {
            Some(scheme), Some(host) if host != "" ->
              Ok(#(
                string.lowercase(scheme),
                string.lowercase(host),
                option.unwrap(parsed.port, 443),
              ))
            _, _ -> Error(Nil)
          }
      }
  }
}

/// Whether the text is what a `String` promises to be. Every body here
/// is bytes a server chose, and `gleam/string` raises on bytes that are
/// not UTF-8.
fn utf8(text: String) -> Bool {
  case bit_array.to_string(bit_array.from_string(text)) {
    Ok(_text) -> True
    Error(Nil) -> False
  }
}

/// The body of a 200, or why not: an answer the transport could not get
/// is `Fetch`; one that came back with another status is `Malformed`.
fn get(
  transport: Transport,
  url: String,
  timeout_ms: Int,
) -> Result(String, Error) {
  case http.get(transport, url, timeout_ms) {
    Error(error) -> Error(Fetch(error))
    Ok(response) ->
      case response.status {
        200 -> Ok(response.body)
        status ->
          Error(Malformed("HTTP " <> int.to_string(status) <> " from " <> url))
      }
  }
}

/// A certificate (or chain) at `url` as PEM. The STI-PA answers PEM under
/// a DER content type; a server that answers DER gets it wrapped.
fn certificate(
  transport: Transport,
  url: String,
  timeout_ms: Int,
) -> Result(String, Error) {
  use body <- result.try(get(transport, url, timeout_ms))
  case string.contains(body, certificate_marker) && utf8(body) {
    True -> Ok(body)
    False ->
      case bit_array.from_string(body) {
        <<0x30, _:bits>> as der -> Ok(to_pem("CERTIFICATE", der))
        _ -> Error(Malformed("no certificate at " <> url))
      }
  }
}

/// The `nextUpdate` of a CRL, PEM or DER, in unix seconds -- what the
/// walk below reads, for a caller that has the CRL already and wants to
/// know how long it is good for. `Error(Nil)` when the bytes are not a
/// CRL, or name no date a clock would recognise.
pub fn crl_next_update(body: String) -> Result(Int, Nil) {
  case crl_pem_and_der(body) {
    Error(_why) -> Error(Nil)
    Ok(#(_pem, der)) ->
      case crl_fields(der) {
        Ok(fields) -> option.to_result(fields.next_update, Nil)
        Error(Nil) -> Error(Nil)
      }
  }
}

/// The `thisUpdate` of a CRL, PEM or DER, in unix seconds, read the same
/// way and just as unauthenticated: for a stored CRL written before its
/// `thisUpdate` was recorded beside it, which a refresh still has to
/// hold the next CRL's date against.
pub fn crl_this_update(body: String) -> Result(Int, Nil) {
  case crl_pem_and_der(body) {
    Error(_why) -> Error(Nil)
    Ok(#(_pem, der)) ->
      case crl_fields(der) {
        Ok(fields) -> option.to_result(fields.this_update, Nil)
        Error(Nil) -> Error(Nil)
      }
  }
}

/// The CRL of a body, and nothing else, as PEM: what an upload stores
/// and the public route serves, whatever else the file held.
pub fn crl_only(body: String) -> Result(String, Nil) {
  case crl_pem_and_der(body) {
    Ok(#(_pem, der)) -> Ok(to_pem("X509 CRL", der))
    Error(_why) -> Error(Nil)
  }
}

/// The CRL body as PEM and as DER, whichever the server answered. A body
/// whose bytes are not UTF-8 is not the PEM it may carry the markers of:
/// the text handling below would raise on it, and the DER branch is
/// where bytes belong.
fn crl_pem_and_der(body: String) -> Result(#(String, BitArray), Error) {
  case string.contains(body, crl_begin) && utf8(body) {
    True -> {
      let base64 =
        body
        |> string.crop(before: crl_begin)
        |> string.drop_start(string.length(crl_begin))
        |> string.split(crl_end)
        |> list.first
        |> result.unwrap("")
        |> string.replace("\n", "")
        |> string.replace("\r", "")
        |> string.replace(" ", "")
      case bit_array.base64_decode(base64) {
        Ok(der) -> Ok(#(body, der))
        Error(Nil) -> Error(Malformed("the CRL's PEM is not base64"))
      }
    }
    False ->
      case bit_array.from_string(body) {
        <<0x30, _:bits>> as der -> Ok(#(to_pem("X509 CRL", der), der))
        _ -> Error(Malformed("the CRL is neither PEM nor DER"))
      }
  }
}

/// DER bytes as a PEM block of the named type, 64 characters to a line.
fn to_pem(label: String, der: BitArray) -> String {
  let lines =
    bit_array.base64_encode(der, True)
    |> string.to_graphemes
    |> list.sized_chunk(64)
    |> list.map(string.concat)
    |> string.join("\n")
  "-----BEGIN "
  <> label
  <> "-----\n"
  <> lines
  <> "\n-----END "
  <> label
  <> "-----\n"
}

// ---------------------------------------------------------------------------
// The CA list's payload
// ---------------------------------------------------------------------------

fn chains(signer: String, trusted_roots: List(String)) -> Result(Nil, Error) {
  case trusted_roots {
    [] -> Ok(Nil)
    roots ->
      validate_chain(signer, string.join(roots, "\n"), "", "", ffi.now_s())
      |> result.map_error(fn(why) {
        Untrusted("the caList signer does not chain to a trusted root: " <> why)
      })
  }
}

/// `version` as a string, whether the STI-PA sent `"1.0"` or `1`.
fn version(payload: Value) -> Result(String, Error) {
  case doc.get(payload, ["version"]) {
    Ok(doc.String(text)) -> Ok(text)
    Ok(doc.Int(n)) -> Ok(int.to_string(n))
    Ok(doc.Float(f)) -> Ok(float.to_string(f))
    _ -> Error(Malformed("no version in the caList"))
  }
}

/// The `trustList` entries that are certificates, each ending in one
/// newline so the bundle they are joined into is one PEM file.
fn trust_list(payload: Value) -> Result(List(String), Error) {
  case doc.get_list(payload, ["trustList"]) {
    Error(Nil) -> Error(Malformed("no trustList in the caList"))
    Ok(entries) ->
      case
        list.filter_map(entries, fn(entry) {
          case entry {
            doc.String(pem) ->
              case string.contains(pem, certificate_marker) {
                True -> Ok(string.trim(pem) <> "\n")
                False -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        })
      {
        [] -> Error(Malformed("the trustList holds no certificate"))
        certificates -> Ok(certificates)
      }
  }
}

fn jws_error(error: jws.Error) -> String {
  case error {
    jws.BadFormat -> "not three parts"
    jws.UnsupportedAlg -> "not ES256"
    jws.BadEncoding -> "not base64url JSON"
    jws.BadSignature -> "does not verify"
    jws.SignerFailed(why) -> why
  }
}

// ---------------------------------------------------------------------------
// The CRL's DER
// ---------------------------------------------------------------------------

type CrlFields {
  CrlFields(
    this_update: Option(Int),
    next_update: Option(Int),
    ca_issuers: Option(String),
  )
}

/// id-pe-authorityInfoAccess, 1.3.6.1.5.5.7.1.1.
const aia_oid = <<0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x01, 0x01>>

/// id-ad-caIssuers, 1.3.6.1.5.5.7.48.2.
const ca_issuers_oid = <<0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x02>>

/// `CertificateList ::= SEQUENCE { tbsCertList, signatureAlgorithm,
/// signature }`; `TBSCertList ::= SEQUENCE { version INTEGER OPTIONAL,
/// signature, issuer, thisUpdate, nextUpdate OPTIONAL, revokedCertificates
/// OPTIONAL, [0] crlExtensions OPTIONAL }` (RFC 5280 §5.1).
fn crl_fields(der: BitArray) -> Result(CrlFields, Nil) {
  case element(der) {
    Ok(#(0x30, certificate_list, _)) ->
      case element(certificate_list) {
        Ok(#(0x30, tbs, _)) -> tbs_fields(elements(tbs))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn tbs_fields(members: List(#(Int, BitArray))) -> Result(CrlFields, Nil) {
  // The version is optional and, when present, first.
  let members = case members {
    [#(0x02, _), ..rest] -> rest
    _ -> members
  }
  case members {
    [#(0x30, _algorithm), #(0x30, _issuer), #(this_tag, this), ..rest]
      if this_tag == 0x17 || this_tag == 0x18
    -> {
      let #(next_update, rest) = case rest {
        [#(tag, when), ..rest] if tag == 0x17 || tag == 0x18 -> #(
          time(tag, when),
          rest,
        )
        _ -> #(None, rest)
      }
      let extensions = case rest {
        [#(0x30, _revoked), #(0xa0, wrapped)] | [#(0xa0, wrapped)] ->
          case element(wrapped) {
            Ok(#(0x30, extensions, _)) -> elements(extensions)
            _ -> []
          }
        _ -> []
      }
      Ok(CrlFields(
        this_update: time(this_tag, this),
        next_update:,
        ca_issuers: ca_issuers(extensions),
      ))
    }
    _ -> Error(Nil)
  }
}

/// The `caIssuers` URL of the AIA extension: `Extension ::= SEQUENCE {
/// extnID OID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }`
/// wrapping `SEQUENCE OF AccessDescription { accessMethod OID,
/// accessLocation GeneralName }`, the name a `[6] IA5String` URI.
fn ca_issuers(extensions: List(#(Int, BitArray))) -> Option(String) {
  list.find_map(extensions, fn(extension) {
    case extension {
      #(0x30, body) ->
        case elements(body) {
          [#(0x06, oid), #(0x04, value)]
            | [#(0x06, oid), #(0x01, _), #(0x04, value)]
            if oid == aia_oid
          -> access_location(value)
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn access_location(value: BitArray) -> Result(String, Nil) {
  case element(value) {
    Ok(#(0x30, descriptions, _)) ->
      list.find_map(elements(descriptions), fn(description) {
        case description {
          #(0x30, body) ->
            case elements(body) {
              [#(0x06, method), #(0x86, uri)] if method == ca_issuers_oid ->
                bit_array.to_string(uri)
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

/// A `UTCTime` (`YYMMDDHHMMSSZ`, years 50 to 99 being 1950 to 1999) or a
/// `GeneralizedTime` (`YYYYMMDDHHMMSSZ`) as unix seconds.
///
/// Every field is range-checked first. `calendar:datetime_to_gregorian_seconds`
/// raises on anything it cannot make a date of -- `991332235959Z` is a
/// month 13 and a day 32 -- and this reads bytes an attacker who can
/// answer for the CRL's URL chose, so `None` and the caller's fallback
/// is the answer to a date that does not exist.
fn time(tag: Int, value: BitArray) -> Option(Int) {
  use text <- option.then(option.from_result(bit_array.to_string(value)))
  let digits = case tag {
    0x17 ->
      case string.slice(text, 0, 2) |> int.parse {
        Ok(yy) if yy < 50 -> Some("20" <> text)
        Ok(_) -> Some("19" <> text)
        Error(Nil) -> None
      }
    _ -> Some(text)
  }
  use digits <- option.then(digits)
  let field = fn(from, length) {
    option.from_result(int.parse(string.slice(digits, from, length)))
  }
  case
    field(0, 4),
    field(4, 2),
    field(6, 2),
    field(8, 2),
    field(10, 2),
    field(12, 2)
  {
    Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(s) ->
      case
        y >= 1970 && y <= 9999 && valid_date(#(y, mo, d)),
        h >= 0 && h <= 23,
        mi >= 0 && mi <= 59,
        s >= 0 && s <= 59
      {
        True, True, True, True ->
          Some(gregorian_seconds(#(#(y, mo, d), #(h, mi, s))) - 62_167_219_200)
        _, _, _, _ -> None
      }
    _, _, _, _, _, _ -> None
  }
}

/// One DER element: its tag, its contents, and what follows it. Lengths
/// are the short form or the long form with up to four length bytes; a
/// tag above 30 needs more than one byte and does not occur in a CRL.
fn element(bytes: BitArray) -> Result(#(Int, BitArray, BitArray), Nil) {
  case bytes {
    <<tag:8, 0:1, length:7, value:bytes-size(length), rest:bytes>> ->
      Ok(#(tag, value, rest))
    <<
      tag:8,
      1:1,
      n:7,
      length:size(n)-unit(8),
      value:bytes-size(length),
      rest:bytes,
    >>
      if n >= 1 && n <= 4
    -> Ok(#(tag, value, rest))
    _ -> Error(Nil)
  }
}

/// Every element of a sequence's contents, in order; a malformed tail is
/// simply the end.
fn elements(bytes: BitArray) -> List(#(Int, BitArray)) {
  case element(bytes) {
    Ok(#(tag, value, rest)) -> [#(tag, value), ..elements(rest)]
    Error(Nil) -> []
  }
}

@external(erlang, "calendar", "datetime_to_gregorian_seconds")
fn gregorian_seconds(datetime: #(#(Int, Int, Int), #(Int, Int, Int))) -> Int

@external(erlang, "calendar", "valid_date")
fn valid_date(date: #(Int, Int, Int)) -> Bool

@external(erlang, "stir_ffi", "validate_chain")
fn validate_chain(
  chain_pem: String,
  trust_pem: String,
  crl_pem: String,
  crl_signer_pem: String,
  now_unix: Int,
) -> Result(Nil, String)
