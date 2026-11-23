//// `stir/stipa`: the CA list over a JWT built here and over the staging
//// STI-PA's real answer, and the CRL over the staging fixtures.
////
//// Fixtures: `stipa-stg-ca-list.json` is `GET
//// https://authenticate-api-stg.iconectiv.com/api/v1/ca-list` as fetched
//// on 2026-09-11 and `stipa-stg-ca-list-signer.pem` what the `x5u` in its
//// JWT header answered (the list signer and its root, PEM under a DER
//// content type); `stipa-stg-crl.pem` and `stipa-stg-crl-signer.pem` are
//// worker A's, the CRL and what its AIA URL answers.
//// `stipa-stg-crl-bad-next-update.pem` is that CRL with its `nextUpdate`
//// bytes overwritten with `991332235959Z`, a month 13 on a day 32. The
//// other lists are signed here with `test-key.pem`, whose certificate
//// `test-cert.pem` is served as the `x5u`.
////
//// Both follow-on fetches are https on the host the answer came from, so
//// every list here names its `x5u` under its own base, and the CRL is
//// served from the host its fixture's AIA points at.

import gleam/erlang/process
import gleam/list
import gleam/string
import kazoo/doc
import kazoo/ffi
import stir/http
import stir/http_test.{der_of, drain, fake, fixture, ok}
import stir/jws
import stir/stipa

const base = "https://stipa.test"

/// Where a CA list's JWT header points at its signer, under the base the
/// list came from. Exported so a suite that moves the base moves the
/// `x5u` with it.
pub const signer_path = "/download/v1/certificate/ca-list.crt"

const signer_url = "https://stipa.test/download/v1/certificate/ca-list.crt"

const staging = "https://authenticate-api-stg.iconectiv.com"

/// The staging CRL, on the host its AIA names.
const crl_url = "https://authenticate-api-stg.iconectiv.com/download/v1/crl"

const staging_signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/external/certificate/ca-listCert_267911_20330824.crt"

const staging_crl_signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/external/certificate/crlCert_267913_20330824.crt"

/// 2026-09-12T15:40:44Z, the fixture CRL's `nextUpdate`.
const crl_next_update = 1_789_227_644

/// What a CRL with no readable `nextUpdate` is taken to last.
const crl_lifetime_s = 86_400

pub fn ca_list_test() {
  let calls = process.new_subject()
  let transport = one_list(calls, sequence: 42)
  let assert Ok(ca_list) = stipa.ca_list(transport, base, [], 100)
  assert ca_list.version == "1.0"
  assert ca_list.sequence == 42
  assert ca_list.expires == 1_800_000_000
  assert ca_list.certificates
    == [
      fixture("example-shaken-intermediate.pem"),
      fixture("test-cert.pem"),
    ]
  assert ca_list.signer == fixture("test-cert.pem")
  assert drain(calls) == [base <> stipa.ca_list_path, signer_url]
}

/// A signer served as DER is wrapped into PEM.
pub fn ca_list_der_signer_test() {
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #(
          base <> stipa.ca_list_path,
          ok(200, envelope(list_jwt(base:, sequence: 1))),
        ),
        #(signer_url, ok(200, der_of(fixture("test-cert.pem")))),
      ],
      calls,
      timeouts: [],
    )
  let assert Ok(ca_list) = stipa.ca_list(transport, base, [], 100)
  assert ca_list.signer == fixture("test-cert.pem")
}

pub fn ca_list_tampered_test() {
  let assert [header, _payload, signature] =
    string.split(list_jwt(base:, sequence: 42), ".")
  let forged =
    header
    <> "."
    <> jws.encode(<<
      "{\"version\":\"1.0\",\"sequence\":43,\"exp\":1,\"trustList\":[]}",
    >>)
    <> "."
    <> signature
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #(base <> stipa.ca_list_path, ok(200, envelope(forged))),
        #(signer_url, ok(200, fixture("test-cert.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.ca_list(transport, base, [], 100)
    == Error(stipa.Untrusted("the caList signature: does not verify"))
}

/// A signer that is not the key: the example SHAKEN chain served at the x5u.
pub fn ca_list_wrong_signer_test() {
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #(
          base <> stipa.ca_list_path,
          ok(200, envelope(list_jwt(base:, sequence: 42))),
        ),
        #(signer_url, ok(200, fixture("example-999Y-chain.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.ca_list(transport, base, [], 100)
    == Error(stipa.Untrusted("the caList signature: does not verify"))
}

/// An `x5u` off the host the list came from, or on plain http, is not
/// followed: it is a URL the document names, and the document is what is
/// being authenticated.
pub fn ca_list_x5u_must_be_same_origin_test() {
  let calls = process.new_subject()
  let elsewhere = "https://attacker.test/ca-list.crt"
  let plain = "http://stipa.test/download/v1/certificate/ca-list.crt"
  let transport =
    fake(
      [
        #(
          base <> stipa.ca_list_path,
          ok(200, envelope(with_x5u(elsewhere, sequence: 42))),
        ),
        #(
          "https://plain.test" <> stipa.ca_list_path,
          ok(200, envelope(with_x5u(plain, sequence: 42))),
        ),
        #(
          "https://relative.test" <> stipa.ca_list_path,
          ok(200, envelope(with_x5u("/ca-list.crt", sequence: 42))),
        ),
        #(elsewhere, ok(200, fixture("test-cert.pem"))),
        #(plain, ok(200, fixture("test-cert.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.ca_list(transport, base, [], 100)
    == Error(stipa.Untrusted(
      "the caList x5u " <> elsewhere <> " is not https on stipa.test:443",
    ))
  assert stipa.ca_list(transport, "https://plain.test", [], 100)
    == Error(stipa.Untrusted(
      "the caList x5u " <> plain <> " is not https on plain.test:443",
    ))
  assert stipa.ca_list(transport, "https://relative.test", [], 100)
    == Error(stipa.Untrusted(
      "the caList x5u /ca-list.crt is not https on relative.test:443",
    ))
  // Each list was read, and nothing past it was fetched.
  assert drain(calls)
    == [
      base <> stipa.ca_list_path,
      "https://plain.test" <> stipa.ca_list_path,
      "https://relative.test" <> stipa.ca_list_path,
    ]
}

/// The port is part of the origin. A list served from `:8443` that
/// names a signer on the same host's `:443` is naming another server,
/// and one served from 443 that names `:8443` likewise.
pub fn ca_list_x5u_must_be_the_same_port_test() {
  let calls = process.new_subject()
  let other_port = "https://stipa.test:8443/download/v1/certificate/ca-list.crt"
  let transport =
    fake(
      [
        #(
          base <> stipa.ca_list_path,
          ok(200, envelope(with_x5u(other_port, sequence: 42))),
        ),
        #(other_port, ok(200, fixture("test-cert.pem"))),
        #(
          "https://stipa.test:8443" <> stipa.ca_list_path,
          ok(200, envelope(with_x5u(base <> signer_path, sequence: 42))),
        ),
        #(base <> signer_path, ok(200, fixture("test-cert.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.ca_list(transport, base, [], 100)
    == Error(stipa.Untrusted(
      "the caList x5u " <> other_port <> " is not https on stipa.test:443",
    ))
  assert stipa.ca_list(transport, "https://stipa.test:8443", [], 100)
    == Error(stipa.Untrusted(
      "the caList x5u "
      <> base
      <> signer_path
      <> " is not https on stipa.test:8443",
    ))
  // Neither signer was fetched.
  assert drain(calls)
    == [
      base <> stipa.ca_list_path,
      "https://stipa.test:8443" <> stipa.ca_list_path,
    ]
}

/// With roots the signer must chain to, an unrelated root refuses the
/// list; the signer itself, or a bundle holding it, accepts it.
pub fn ca_list_trusted_roots_test() {
  let calls = process.new_subject()
  let transport = one_list(calls, sequence: 42)
  let assert Error(stipa.Untrusted(why)) =
    stipa.ca_list(
      transport,
      base,
      [fixture("example-shaken-intermediate.pem")],
      100,
    )
  assert string.starts_with(
    why,
    "the caList signer does not chain to a trusted root: ",
  )
  let assert Ok(_) =
    stipa.ca_list(transport, base, [fixture("test-cert.pem")], 100)
  let assert Ok(_) =
    stipa.ca_list(
      transport,
      base,
      [fixture("example-shaken-intermediate.pem"), fixture("test-cert.pem")],
      100,
    )
}

pub fn ca_list_malformed_test() {
  let calls = process.new_subject()
  let jwt_without_x5u =
    sign("{\"alg\":\"ES256\",\"typ\":\"JWT\"}", payload(sequence: 1))
  let numeric_version =
    sign(
      header("https://numeric.test"),
      "{\"version\":2,\"sequence\":7,\"exp\":5,\"trustList\":[\""
        <> escape(fixture("test-cert.pem"))
        <> "\"]}",
    )
  let no_list =
    sign(
      header("https://nolist2.test"),
      "{\"version\":\"1.0\",\"sequence\":7,\"exp\":5}",
    )
  let empty_list =
    sign(
      header("https://empty.test"),
      "{\"version\":\"1.0\",\"sequence\":7,\"exp\":5,\"trustList\":[\"nope\"]}",
    )
  let certificate = ok(200, fixture("test-cert.pem"))
  let transport =
    fake(
      [
        #(signer_url, certificate),
        #("https://numeric.test" <> signer_path, certificate),
        #("https://nolist2.test" <> signer_path, certificate),
        #("https://empty.test" <> signer_path, certificate),
        #("https://json.test" <> stipa.ca_list_path, ok(200, "not json")),
        #(
          "https://nolist.test" <> stipa.ca_list_path,
          ok(200, "{\"status\":\"ok\"}"),
        ),
        #("https://notjws.test" <> stipa.ca_list_path, ok(200, envelope("a.b"))),
        #(
          "https://nox5u.test" <> stipa.ca_list_path,
          ok(200, envelope(jwt_without_x5u)),
        ),
        #(
          "https://numeric.test" <> stipa.ca_list_path,
          ok(200, envelope(numeric_version)),
        ),
        #(
          "https://nolist2.test" <> stipa.ca_list_path,
          ok(200, envelope(no_list)),
        ),
        #(
          "https://empty.test" <> stipa.ca_list_path,
          ok(200, envelope(empty_list)),
        ),
        #("https://error.test" <> stipa.ca_list_path, ok(503, "later")),
        #(
          "https://down.test" <> stipa.ca_list_path,
          Error(http.Transport("econnrefused")),
        ),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.ca_list(transport, "https://json.test", [], 100)
    == Error(stipa.Malformed("the CA list is not JSON"))
  assert stipa.ca_list(transport, "https://nolist.test", [], 100)
    == Error(stipa.Malformed("no caList in the answer"))
  assert stipa.ca_list(transport, "https://notjws.test", [], 100)
    == Error(stipa.Malformed("caList is not a JWS: not three parts"))
  assert stipa.ca_list(transport, "https://nox5u.test", [], 100)
    == Error(stipa.Malformed("no x5u in the caList header"))
  let assert Ok(numeric) =
    stipa.ca_list(transport, "https://numeric.test", [], 100)
  assert numeric.version == "2"
  assert numeric.sequence == 7
  assert numeric.expires == 5
  assert stipa.ca_list(transport, "https://nolist2.test", [], 100)
    == Error(stipa.Malformed("no trustList in the caList"))
  assert stipa.ca_list(transport, "https://empty.test", [], 100)
    == Error(stipa.Malformed("the trustList holds no certificate"))
  assert stipa.ca_list(transport, "https://error.test", [], 100)
    == Error(stipa.Malformed("HTTP 503 from https://error.test/api/v1/ca-list"))
  assert stipa.ca_list(transport, "https://down.test", [], 100)
    == Error(stipa.Fetch(http.Transport("econnrefused")))
  // A signer URL that answers nothing usable.
  let transport =
    fake(
      [
        #(
          base <> stipa.ca_list_path,
          ok(200, envelope(list_jwt(base:, sequence: 1))),
        ),
        #(signer_url, ok(200, "<html>")),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.ca_list(transport, base, [], 100)
    == Error(stipa.Malformed("no certificate at " <> signer_url))
}

/// The staging STI-PA's real list, served from the fixtures: 27 entries,
/// two of them PEM with blank lines inside (which `public_key` reads all
/// the same), signed by `CN=STI-PA CA List` under the STI-PA's test root,
/// which the list itself does not carry.
pub fn staging_ca_list_test() {
  let calls = process.new_subject()
  let signer = fixture("stipa-stg-ca-list-signer.pem")
  let transport =
    fake(
      [
        #(
          staging <> stipa.ca_list_path,
          ok(200, fixture("stipa-stg-ca-list.json")),
        ),
        #(staging_signer_url, ok(200, signer)),
      ],
      calls,
      timeouts: [],
    )
  let assert Ok(ca_list) = stipa.ca_list(transport, staging, [], 100)
  assert ca_list.version == "1.0"
  assert ca_list.sequence == 2621
  assert ca_list.expires == 1_789_209_642
  assert list.length(ca_list.certificates) == 27
  assert list.all(ca_list.certificates, fn(pem) {
    string.starts_with(pem, "-----BEGIN CERTIFICATE-----")
    && string.ends_with(pem, "-----END CERTIFICATE-----\n")
  })
  assert ca_list.signer == signer
  assert drain(calls) == [staging <> stipa.ca_list_path, staging_signer_url]
  // The real list's `x5u` is on the STI-PA's own host, which is what the
  // follow-on rule asks of it.
  assert string.starts_with(staging_signer_url, staging <> "/")
  // The signer chains to its own recorded chain (its root is in it) and
  // to nothing in the list; the check runs at the wall clock, and the
  // signer is valid from 2026-06-23 to 2030-06-23.
  let assert Ok(_) = stipa.ca_list(transport, staging, [signer], 100)
  let assert Error(stipa.Untrusted(_)) =
    stipa.ca_list(transport, staging, ca_list.certificates, 100)
}

pub fn crl_test() {
  let calls = process.new_subject()
  let transport = staging_crl(calls, fixture("stipa-stg-crl.pem"))
  let assert Ok(crl) = stipa.crl(transport, crl_url, 100)
  assert crl.pem == fixture("stipa-stg-crl.pem")
  assert crl.signer == fixture("stipa-stg-crl-signer.pem")
  assert crl.next_update == crl_next_update
  assert drain(calls) == [crl_url, staging_crl_signer_url]
}

/// A CRL served as DER is wrapped into the same PEM openssl writes, and a
/// DER signer is wrapped too.
pub fn crl_der_test() {
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #(crl_url, ok(200, der_of(fixture("stipa-stg-crl.pem")))),
        #(
          staging_crl_signer_url,
          ok(200, der_of(fixture("stipa-stg-crl-signer.pem"))),
        ),
      ],
      calls,
      timeouts: [],
    )
  let assert Ok(crl) = stipa.crl(transport, crl_url, 100)
  // The fixture file has no newline after its last line; a wrapped PEM
  // ends in one, as openssl writes it.
  assert crl.pem == fixture("stipa-stg-crl.pem") <> "\n"
  assert crl.next_update == crl_next_update
  // Only the first certificate of the signer's chain survives a DER
  // answer; the STI-PA answers PEM, so the root comes along there.
  assert string.starts_with(crl.signer, "-----BEGIN CERTIFICATE-----\n")
  assert string.starts_with(fixture("stipa-stg-crl-signer.pem"), crl.signer)
}

/// A `nextUpdate` of `991332235959Z` -- month 13 on day 32 -- used to
/// reach `calendar:datetime_to_gregorian_seconds`, which raises, and took
/// the call down with it. It answers the fallback instead: the fetch time
/// plus the CRL's own lifetime.
pub fn crl_unreadable_next_update_test() {
  let calls = process.new_subject()
  let transport =
    staging_crl(calls, fixture("stipa-stg-crl-bad-next-update.pem"))
  let before = ffi.now_s()
  let assert Ok(crl) = stipa.crl(transport, crl_url, 100)
  let after = ffi.now_s()
  assert crl.next_update >= before + crl_lifetime_s
  assert crl.next_update <= after + crl_lifetime_s
  assert crl.signer == fixture("stipa-stg-crl-signer.pem")
}

/// The AIA is a URL the CRL names, so it gets the rule the `x5u` gets:
/// https, on the host the CRL came from.
pub fn crl_aia_must_be_same_origin_test() {
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #("https://elsewhere.test/crl", ok(200, fixture("stipa-stg-crl.pem"))),
        #(staging_crl_signer_url, ok(200, fixture("stipa-stg-crl-signer.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.crl(transport, "https://elsewhere.test/crl", 100)
    == Error(stipa.Untrusted(
      "the CRL's AIA caIssuers URL "
      <> staging_crl_signer_url
      <> " is not https on elsewhere.test:443",
    ))
  assert drain(calls) == ["https://elsewhere.test/crl"]
}

pub fn crl_malformed_test() {
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #("https://text.test/crl", ok(200, "garbage")),
        #("https://cert.test/crl", ok(200, fixture("test-cert.pem"))),
        #("https://der.test/crl", ok(200, der_of(fixture("test-cert.pem")))),
        #("https://gone.test/crl", ok(404, "")),
        #("https://down.test/crl", Error(http.Transport("timeout"))),
        #(crl_url, ok(200, fixture("stipa-stg-crl.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert stipa.crl(transport, "https://text.test/crl", 100)
    == Error(stipa.Malformed("the CRL is neither PEM nor DER"))
  assert stipa.crl(transport, "https://cert.test/crl", 100)
    == Error(stipa.Malformed("the CRL is neither PEM nor DER"))
  // A certificate's DER walks like a CRL's until the fields disagree.
  assert stipa.crl(transport, "https://der.test/crl", 100)
    == Error(stipa.Malformed("the CRL's DER could not be read"))
  assert stipa.crl(transport, "https://gone.test/crl", 100)
    == Error(stipa.Malformed("HTTP 404 from https://gone.test/crl"))
  assert stipa.crl(transport, "https://down.test/crl", 100)
    == Error(stipa.Fetch(http.Transport("timeout")))
  // The AIA URL is same-origin here and answers a 404.
  assert stipa.crl(transport, crl_url, 100)
    == Error(stipa.Malformed("HTTP 404 from " <> staging_crl_signer_url))
}

// ---------------------------------------------------------------------------
// Arranging
// ---------------------------------------------------------------------------

fn one_list(
  calls: process.Subject(String),
  sequence sequence: Int,
) -> http.Transport {
  fake(
    [
      #(
        base <> stipa.ca_list_path,
        ok(200, envelope(list_jwt(base:, sequence:))),
      ),
      #(signer_url, ok(200, fixture("test-cert.pem"))),
    ],
    calls,
    timeouts: [],
  )
}

fn staging_crl(
  calls: process.Subject(String),
  crl_pem: String,
) -> http.Transport {
  fake(
    [
      #(crl_url, ok(200, crl_pem)),
      #(staging_crl_signer_url, ok(200, fixture("stipa-stg-crl-signer.pem"))),
    ],
    calls,
    timeouts: [],
  )
}

fn envelope(jwt: String) -> String {
  doc.to_string(
    doc.object([
      #("status", doc.String("success")),
      #("caList", doc.String(jwt)),
    ]),
  )
}

/// A list of the example SHAKEN intermediate and the test certificate, signed
/// with the test key, its `x5u` under `base`.
pub fn list_jwt(base base: String, sequence sequence: Int) -> String {
  sign(header(base), payload(sequence))
}

fn with_x5u(x5u: String, sequence sequence: Int) -> String {
  sign(
    "{\"alg\":\"ES256\",\"typ\":\"JWT\",\"x5u\":\"" <> x5u <> "\"}",
    payload(sequence),
  )
}

fn header(base: String) -> String {
  "{\"alg\":\"ES256\",\"typ\":\"JWT\",\"x5u\":\""
  <> base
  <> signer_path
  <> "\"}"
}

fn payload(sequence sequence: Int) -> String {
  doc.to_string(
    doc.object([
      #("version", doc.String("1.0")),
      #("sequence", doc.Int(sequence)),
      #("exp", doc.Int(1_800_000_000)),
      #(
        "trustList",
        doc.List([
          doc.String(fixture("example-shaken-intermediate.pem")),
          doc.String(fixture("test-cert.pem")),
        ]),
      ),
    ]),
  )
}

fn sign(header: String, payload: String) -> String {
  let key = fixture("test-key.pem")
  let assert Ok(compact) =
    jws.sign(header, payload, fn(input) { ecdsa_sign(key, input) })
  compact
}

fn escape(text: String) -> String {
  string.replace(text, "\n", "\\n")
}

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: String,
  message: String,
) -> Result(BitArray, String)
