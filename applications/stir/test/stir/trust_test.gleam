//// `stir/trust`: a refresh over the fake transport into the fake store,
//// what it stores, what it refuses, an upload, and chain validation of
//// the example SHAKEN chain against the stored bundle with the staging
//// STI-PA's CRL.
////
//// The fake's clock is set inside the fixture CRL's window
//// (2026-09-11T15:40:44Z to 2026-09-12T15:40:44Z) and the test
//// certificate's validity, as `ffi_test` does.
////
//// The base is the staging STI-PA's own host: both follow-on fetches
//// are https on the host the answer came from, and the CRL fixture's AIA
//// names that host. It is also the one host the shipped staging root
//// pins, which is what lets the staging CRL's signer through.
////
//// The signer of the lists built here is `test-cert.pem`, which chains
//// to nothing this application ships, so every test that wants a refresh
//// to go through pins it first the way an operator would -- `upload_root`
//// with the role `StipaRoot`, which is also `POST /v2/stir/trust
//// {"kind":"ca","role":"stipa"}`. That is the point of
//// `refresh_needs_a_pinned_root_test`: there is no trust on first use. A
//// plain `upload(kz, Ca, ..)` is a call root, and anchors calls only.
////
//// A root upload is the root and nothing else: it does not write the
//// bundle, so `pem(kz, Ca)` answers what the last refresh stored and
//// `NotFound` on a store that has never refreshed.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo
import kazoo/modb
import kazoo/testing/fake
import stir/http
import stir/http_test.{der_of, drain, fake as fake_transport, fixture, ok}
import stir/stipa
import stir/stipa_test.{list_jwt}
import stir/trust
import support/mutate

const base = "https://authenticate-api-stg.iconectiv.com"

const production = "https://authenticate-api.iconectiv.com"

/// 2026-09-12T08:00:00Z.
const during_crl_window = 1_789_200_000

/// One second after the fixture CRL's `nextUpdate`.
const after_crl_window = 1_789_227_645

/// The fixture CRL's `thisUpdate`, 2026-09-11T15:40:44Z, and its
/// `cRLNumber`, 0x0A3C.
const crl_this_update = 1_789_141_244

const crl_number = 2620

/// The `exp` of every list `stipa_test` builds.
const list_expires = 1_800_000_000

const signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/certificate/ca-list.crt"

const crl_signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/external/certificate/crlCert_267913_20330824.crt"

const staging_list_signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/external/certificate/ca-listCert_267911_20330824.crt"

pub fn refresh_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  // The operator pins the root the test list's signer is under, which is
  // the signer itself; without it nothing is trusted on first use.
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  let transport = stipa_transport(calls, sequence: 42)

  let assert Ok([ca, crl]) = trust.refresh(kz, transport, base, 100)
  let fetched_at = modb.from_unix(during_crl_window)
  assert ca
    == trust.Status(
      kind: trust.Ca,
      fetched_at:,
      source: "stipa",
      detail: Some(42),
    )
  assert crl
    == trust.Status(
      kind: trust.Crl,
      fetched_at:,
      source: "stipa",
      detail: Some(1_789_227_644),
    )
  assert drain(calls)
    == [
      base <> stipa.ca_list_path,
      signer_url,
      base <> trust.crl_path,
      crl_signer_url,
    ]

  // The bundle is the list, one PEM file; the CRL is the CRL.
  let assert Ok(bundle) = trust.pem(kz, trust.Ca)
  assert bundle
    == fixture("example-shaken-intermediate.pem") <> fixture("test-cert.pem")
  assert trust.pem(kz, trust.Crl) == Ok(fixture("stipa-stg-crl.pem"))
  assert trust.status(kz) == Ok([ca, crl])

  // The documents carry what the status says, the host both came from,
  // and what the CRL said of itself once it was authenticated.
  let assert Ok(document) = fake.lookup(store, "stir", "trust-ca")
  assert doc.get_string(document, ["pvt_type"]) == Ok("stir_trust")
  assert doc.get_string(document, ["kind"]) == Ok("ca")
  assert doc.get_int(document, ["fetched_at"]) == Ok(fetched_at)
  assert doc.get_string(document, ["source"]) == Ok("stipa")
  assert doc.get_int(document, ["detail"]) == Ok(42)
  assert doc.get_string(document, [trust.stipa_host_field])
    == Ok(trust.staging_host)
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  assert doc.get_string(document, ["kind"]) == Ok("crl")
  assert doc.get_int(document, ["detail"]) == Ok(1_789_227_644)
  assert doc.get_string(document, [trust.stipa_host_field])
    == Ok(trust.staging_host)
  assert doc.get_int(document, [trust.this_update_field]) == Ok(crl_this_update)
  assert doc.get_int(document, [trust.crl_number_field]) == Ok(crl_number)

  // The example SHAKEN chain validates against the bundle, with the CRL and
  // its signer from the store; the test certificate is its own anchor.
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Ok(Nil)
  assert trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)
    == Ok(Nil)
  // The stored CRL is consulted while it lasts; past its window the
  // call is verified without the revocation check and says so, rather
  // than failing closed (a deliberate choice: an STI-PA outage must not
  // fail every inbound call).
  let assert Ok(checked) =
    trust.validate_chain_report(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
  assert checked.revocation_checked
  let assert Ok(unchecked) =
    trust.validate_chain_report(
      kz,
      fixture("example-999Y-chain.pem"),
      after_crl_window,
    )
  assert !unchecked.revocation_checked
  assert unchecked.crl_age_s == Some(after_crl_window - during_crl_window)
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      after_crl_window,
    )
    == Ok(Nil)
  // The two anchor sets are apart: a call's chain anchors in the stored
  // list alone, so the CRL's own signer -- which anchors in the pinned
  // roots, and does so inside the check above -- is not a chain this
  // node would verify a call against.
  let assert Error(_) =
    trust.validate_chain(
      kz,
      fixture("stipa-stg-crl-signer.pem"),
      during_crl_window,
    )

  // A second refresh with the same signer goes through, and updates the
  // document rather than conflicting with it. The same CRL again is not
  // an older one.
  let assert Ok([ca2, _crl2]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 43), base, 100)
  assert ca2.detail == Some(43)
  let assert Ok(document) = fake.lookup(store, "stir", "trust-ca")
  assert doc.get_string(document, ["_rev"]) == Ok("3-fake")
  assert fake.alerts(store) == []
}

/// The staging STI-PA's own answer, signed by `CN=STI-PA CA List` under
/// the root shipped in `priv/stipa-roots.pem`: it refreshes with nothing
/// uploaded and nothing stored, which is the whole point of pinning, and
/// the genuine staging CRL is authenticated and stored.
pub fn refresh_against_the_pinned_root_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let calls = process.new_subject()
  let assert Ok([ca, crl]) =
    trust.refresh(kz, staging_transport(calls), base, 100)
  assert ca.detail == Some(2621)
  assert crl.detail == Some(1_789_227_644)
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  assert doc.get_int(document, [trust.this_update_field]) == Ok(crl_this_update)
  assert fake.alerts(store) == []
}

/// Nothing is trusted on first use: a list signer no pinned root anchors
/// is refused with an empty store, and the store stays empty. A call
/// root is not a pin, so uploading the signer as one changes nothing.
pub fn refresh_needs_a_pinned_root_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let calls = process.new_subject()
  let assert Error(trust.Stipa(stipa.Untrusted(why))) =
    trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
  assert why == "no trust anchor for the chain"
  assert trust.status(kz) == Ok([])
  // Nothing past the list was fetched.
  assert drain(calls) == [base <> stipa.ca_list_path, signer_url]

  let assert Ok(_) = trust.upload(kz, trust.Ca, fixture("test-cert.pem"), "sup")
  let assert Error(trust.Stipa(stipa.Untrusted(why))) =
    trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
  assert why == "no trust anchor for the chain"

  // The operator pins the signer's root, and the refresh goes through.
  pin(kz, fixture("test-cert.pem"))
  let assert Ok(_) =
    trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
  // The CA list has replaced the bundle by now; the pinned root is kept
  // apart from it, so the next refresh still has something to check
  // against.
  let assert Ok(_) =
    trust.refresh(kz, stipa_transport(calls, sequence: 43), base, 100)
}

/// A list whose signer does not chain to what is pinned is refused, and
/// what is stored stays.
pub fn refresh_refuses_a_new_signer_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let assert Ok(uploaded) =
    trust.upload_root(
      kz,
      trust.StipaRoot,
      fixture("example-shaken-intermediate.pem"),
      "sup",
    )
  assert uploaded.source == "upload"
  assert uploaded.detail == None
  let calls = process.new_subject()
  let assert Error(trust.Stipa(stipa.Untrusted(why))) =
    trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
  assert why == "no trust anchor for the chain"
  // The upload pinned a root; it did not write a bundle, and the
  // refusal wrote nothing either.
  assert trust.pem(kz, trust.Ca) == Error(trust.NotFound)
  assert trust.pem(kz, trust.Crl) == Error(trust.NotFound)
  // Nothing past the list was fetched.
  assert drain(calls) == [base <> stipa.ca_list_path, signer_url]
  // No master account on a test node, so no alert could be filed; the
  // refusal is logged instead.
  assert fake.alerts(store) == []
}

/// A list whose `exp` has passed is not stored: at best the STI-PA is
/// serving something stale, at worst someone is replaying it.
pub fn refresh_refuses_an_expired_list_test() {
  let store = fake.new()
  fake.set_now(store, list_expires + 1)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  assert trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
    == Error(
      trust.Stipa(stipa.Untrusted(
        "the CA list expired at " <> kazoo.iso8601(list_expires),
      )),
    )
  // Nothing past the list was fetched, and nothing was stored.
  assert drain(calls) == [base <> stipa.ca_list_path, signer_url]
  assert trust.pem(kz, trust.Ca) == Error(trust.NotFound)
}

/// A list played back at a lower sequence is how a revoked certificate
/// comes back. It is refused and the stored one stays.
pub fn refresh_refuses_a_rollback_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  let assert Ok([ca, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 43), base, 100)
  assert ca.detail == Some(43)
  assert trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
    == Error(
      trust.Stipa(stipa.Untrusted(
        "the CA list sequence 42 is below the stored 43",
      )),
    )
  let assert Ok([stored, _]) = trust.status(kz)
  assert stored.detail == Some(43)
  // The same sequence again is not a rollback: the STI-PA reissues
  // without bumping it.
  let assert Ok(_) =
    trust.refresh(kz, stipa_transport(calls, sequence: 43), base, 100)
}

pub fn refresh_failures_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  // The STI-PA is down.
  let transport =
    fake_transport(
      [#(base <> stipa.ca_list_path, Error(http.Transport("econnrefused")))],
      calls,
      timeouts: [],
    )
  assert trust.refresh(kz, transport, base, 100)
    == Error(trust.Stipa(stipa.Fetch(http.Transport("econnrefused"))))
  let assert Ok([ca]) = trust.status(kz)
  assert ca.source == "upload"
  // The list came, the CRL did not: the list is stored and the answer
  // says so by carrying the CA's status alone.
  let assert Ok([ca]) =
    trust.refresh(kz, without_crl(calls, sequence: 9), base, 100)
  assert ca.detail == Some(9)
  assert trust.pem(kz, trust.Crl) == Error(trust.NotFound)
  // Without a CRL, chains still validate against the bundle.
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Ok(Nil)
}

/// A CRL that did not come leaves the stored one alone, and the CA
/// document is still stamped so the list itself is up to date. The old
/// behaviour stored an empty CRL slot; what it must not do is lose the
/// CRL that still works.
pub fn refresh_keeps_the_old_crl_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  let assert Ok([_, crl]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 10), base, 100)
  assert crl.detail == Some(1_789_227_644)

  let assert Ok([ca]) =
    trust.refresh(kz, without_crl(calls, sequence: 11), base, 100)
  assert ca.detail == Some(11)
  // The CRL and its signer are the ones that came down before.
  assert trust.pem(kz, trust.Crl) == Ok(fixture("stipa-stg-crl.pem"))
  let assert Ok([_, stored_crl]) = trust.status(kz)
  assert stored_crl.detail == Some(1_789_227_644)
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Ok(Nil)
}

// ---------------------------------------------------------------------------
// A fetched CRL is authenticated before it is stored
// ---------------------------------------------------------------------------

/// A CRL whose signature does not verify is not stored: the list half of
/// the refresh goes ahead, and the CRL that was there stays. With nothing
/// stored before, nothing is stored after.
pub fn refresh_refuses_a_crl_with_a_bad_signature_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  let tampered = tampered_crl()
  // The walk still reads it: the tampering is in the signature.
  let assert Ok(_) = stipa.crl_next_update(tampered)

  let assert Ok([ca]) =
    trust.refresh(kz, serving_crl(calls, 1, tampered), base, 100)
  assert ca.detail == Some(1)
  assert trust.pem(kz, trust.Crl) == Error(trust.NotFound)

  let assert Ok([_, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 2), base, 100)
  let assert Ok(before) = fake.lookup(store, "stir", "trust-crl")
  let assert Ok([ca]) =
    trust.refresh(kz, serving_crl(calls, 3, tampered), base, 100)
  assert ca.detail == Some(3)
  assert fake.lookup(store, "stir", "trust-crl") == Ok(before)
  assert trust.pem(kz, trust.Crl) == Ok(fixture("stipa-stg-crl.pem"))
}

/// A CRL past its `nextUpdate` is not stored either: storing it would
/// have turned revocation off until the next refresh. The stored CRL
/// stays -- expired too, here, and verification says so on every call
/// rather than trusting a CRL nobody checked.
pub fn refresh_refuses_an_expired_crl_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  let assert Ok([_, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)
  let assert Ok(before) = fake.lookup(store, "stir", "trust-crl")
  fake.set_now(store, after_crl_window)
  let assert Ok([ca]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 2), base, 100)
  assert ca.detail == Some(2)
  assert fake.lookup(store, "stir", "trust-crl") == Ok(before)
}

/// A genuine CRL older than the stored one -- still inside its window,
/// played back -- is how a certificate revoked since verifies as
/// checked. An earlier `thisUpdate` refuses it, and so does a lower
/// `cRLNumber` when both carry one; the same CRL again is taken.
pub fn refresh_refuses_an_older_crl_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  let assert Ok([_, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)

  // The stored CRL was issued a second after the one the STI-PA answers.
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  let newer =
    doc.set(document, [trust.this_update_field], doc.Int(crl_this_update + 1))
  fake.put_doc(store, "stir", newer)
  let assert Ok(before) = fake.lookup(store, "stir", "trust-crl")
  let assert Ok([_ca]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 2), base, 100)
  assert fake.lookup(store, "stir", "trust-crl") == Ok(before)

  // Issued at the same time, with a higher number.
  let renumbered =
    before
    |> doc.set([trust.this_update_field], doc.Int(crl_this_update))
    |> doc.set([trust.crl_number_field], doc.Int(crl_number + 1))
  fake.put_doc(store, "stir", renumbered)
  let assert Ok(before) = fake.lookup(store, "stir", "trust-crl")
  let assert Ok([_ca]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 3), base, 100)
  assert fake.lookup(store, "stir", "trust-crl") == Ok(before)

  // A document from before the facts were recorded: the stored CRL's own
  // `thisUpdate` is read out of it, and the same CRL is not older.
  let legacy =
    before
    |> doc.delete([trust.this_update_field])
    |> doc.delete([trust.crl_number_field])
  fake.put_doc(store, "stir", legacy)
  let assert Ok([_, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 4), base, 100)
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  assert doc.get_int(document, [trust.crl_number_field]) == Ok(crl_number)
}

/// An uploaded CRL is held to the signer already stored, and its signer
/// to the pins of the STI-PA host the cluster is set to plus the uploaded
/// STI-PA roots: here the default production host, which ships no pins,
/// so the staging CRL needs the staging root uploaded with the role
/// stipa. Refused, the stored CRL stays as the refresh left it.
pub fn an_uploaded_crl_is_authenticated_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let calls = process.new_subject()
  let assert Ok([_, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)
  let assert Ok(before) = fake.lookup(store, "stir", "trust-crl")
  assert trust.upload(kz, trust.Crl, fixture("stipa-stg-crl.pem"), "sup")
    == Error(
      trust.Stipa(stipa.Untrusted(
        "CRL signer does not chain to the trust bundle",
      )),
    )
  assert fake.lookup(store, "stir", "trust-crl") == Ok(before)

  // With the staging root uploaded as an STI-PA root it is taken, as
  // from the configured host, and marked authenticated.
  pin(kz, fixture("test-cert.pem") <> fixture("stipa-stg-root.pem"))
  let assert Ok(_) =
    trust.upload(kz, trust.Crl, fixture("stipa-stg-crl.pem"), "sup")
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  assert doc.get_string(document, [trust.stipa_host_field])
    == Ok("authenticate-api.iconectiv.com")
  assert doc.get_bool(document, [trust.authenticated_field]) == Ok(True)
  assert doc.get_int(document, [trust.this_update_field]) == Ok(crl_this_update)
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Ok(Nil)
}

/// `cRLSign` is what lets a certificate sign a CRL, and an uploaded pair
/// is checked whichever half comes second: a CRL stored with no signer
/// yet is held to the signer when it arrives, and a signer without the
/// key usage is refused then, leaving the CRL it could not vouch for
/// unauthenticated and the signer unstored. The other order is checked
/// on the CRL.
pub fn a_signer_without_crl_sign_is_refused_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("gen-root.pem"))
  let assert Ok(_) =
    trust.upload(kz, trust.Crl, fixture("gen-crl-no-keyusage.pem"), "sup")
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  assert doc.get_int(document, [trust.this_update_field]) == Error(Nil)
  let assert Error(trust.Stipa(stipa.Untrusted(why))) =
    trust.upload(
      kz,
      trust.Crl,
      fixture("gen-crl-signer-no-keyusage.pem"),
      "sup",
    )
  assert why == "CRL signer has no cRLSign key usage"
  assert fake.lookup(store, "stir", "trust-crl") == Ok(document)

  // The other order: the signer first, then the CRL.
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("gen-root.pem"))
  let assert Ok(_) =
    trust.upload(
      kz,
      trust.Crl,
      fixture("gen-crl-signer-no-keyusage.pem"),
      "sup",
    )
  let assert Error(trust.Stipa(stipa.Untrusted(why))) =
    trust.upload(kz, trust.Crl, fixture("gen-crl-no-keyusage.pem"), "sup")
  assert why == "CRL signer has no cRLSign key usage"
  assert trust.pem(kz, trust.Crl) == Error(trust.NotFound)

  // A signer with `cRLSign` under the pinned root is taken, and what the
  // CRL says of itself is recorded once it is.
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("gen-root.pem"))
  let assert Ok(_) =
    trust.upload(kz, trust.Crl, fixture("gen-spaced-crl.pem"), "sup")
  let assert Ok(_) =
    trust.upload(kz, trust.Crl, fixture("gen-spaced-crl-signer.pem"), "sup")
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  assert doc.get_int(document, [trust.crl_number_field]) == Ok(4096)
}

// ---------------------------------------------------------------------------
// The two roles, and the host a shipped pin belongs to
// ---------------------------------------------------------------------------

/// A call root never pins the STI-PA: not the CA list's signer, and not
/// the CRL's. The staging root uploaded as a call root anchors nothing
/// the STI-PA signs.
pub fn a_call_root_never_anchors_an_stipa_signer_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let calls = process.new_subject()
  let assert Ok(_) =
    trust.upload(
      kz,
      trust.Ca,
      fixture("test-cert.pem") <> fixture("stipa-stg-root.pem"),
      "sup",
    )
  let assert Error(trust.Stipa(stipa.Untrusted(why))) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)
  assert why == "no trust anchor for the chain"

  // An uploaded CRL and its signer, which the staging root issued: with
  // the root a call root, the CRL does not authenticate.
  let assert Ok(_) =
    trust.upload(kz, trust.Crl, fixture("stipa-stg-crl-signer.pem"), "sup")
  assert trust.upload(kz, trust.Crl, fixture("stipa-stg-crl.pem"), "sup")
    == Error(
      trust.Stipa(stipa.Untrusted(
        "CRL signer does not chain to the trust bundle",
      )),
    )
  // Nor at verification: a CRL stored with no host has its signer held
  // to the uploaded STI-PA roots alone, and there are none.
  fake.put_doc(store, "stir", crl_doc(None))
  assert trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)
    == Error("CRL signer does not chain to the trust bundle")

  // The same root with the role stipa is what anchors it.
  pin(kz, fixture("stipa-stg-root.pem"))
  assert trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)
    == Ok(Nil)
}

/// An STI-PA root never anchors a call, uploaded alone or beside a CA
/// list that does not hold it.
pub fn an_stipa_root_never_anchors_a_call_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  assert trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)
    == Error(
      "no trust material stored: refresh the CA list, or upload a root with POST /v2/stir/trust",
    )
  let calls = process.new_subject()
  let assert Ok(_) = trust.refresh(kz, staging_transport(calls), base, 100)
  assert trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)
    == Error("no trust anchor for the chain")
}

/// The shipped staging root pins the staging host and no other: pointed
/// at production, a refresh has nothing shipped to check the list's
/// signer against, and a CRL recorded as fetched from production does
/// not have its signer anchored by the staging root either.
pub fn the_staging_root_pins_only_the_staging_host_test() {
  assert string.contains(
    trust.shipped_pins(trust.staging_host),
    "-----BEGIN CERTIFICATE-----",
  )
  assert trust.shipped_pins(string.uppercase(trust.staging_host))
    == trust.shipped_pins(trust.staging_host)
  assert trust.shipped_pins("authenticate-api.iconectiv.com") == ""

  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let calls = process.new_subject()
  let at_production =
    fake_transport(
      [
        #(
          production <> stipa.ca_list_path,
          ok(200, envelope(list_jwt(base: production, sequence: 1))),
        ),
        #(
          production <> "/download/v1/certificate/ca-list.crt",
          ok(200, fixture("test-cert.pem")),
        ),
      ],
      calls,
      timeouts: [],
    )
  assert trust.refresh(kz, at_production, production, 100)
    == Error(
      trust.Stipa(stipa.Untrusted(
        "no pinned STI-PA root to check the CA list's signer against",
      )),
    )

  // Verification: the staging CRL, recorded as fetched from staging,
  // checks; the same document saying production does not.
  pin(kz, fixture("test-cert.pem"))
  let assert Ok([_, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)
  assert trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)
    == Ok(Nil)
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  fake.put_doc(
    store,
    "stir",
    doc.set(
      document,
      [trust.stipa_host_field],
      doc.String("authenticate-api.iconectiv.com"),
    ),
  )
  assert trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)
    == Error("CRL signer does not chain to the trust bundle")
}

/// A CRL fetched before the host was recorded cannot say which pins its
/// signer answers to. Until the next refresh replaces it, a call is
/// verified and marked unchecked, as with a stale CRL, and not refused:
/// the upgrade must not be an outage.
pub fn a_crl_from_before_hosts_were_recorded_leaves_calls_unchecked_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let assert Ok([_, _]) =
    trust.refresh(
      kz,
      stipa_transport(process.new_subject(), sequence: 1),
      base,
      100,
    )
  fake.put_doc(
    store,
    "stir",
    crl_doc(None)
      |> doc.set(["source"], doc.String("stipa"))
      |> doc.delete([trust.authenticated_field]),
  )
  let assert Ok(trust.Validation(revocation_checked: False, crl_age_s: _)) =
    trust.validate_chain_report(kz, fixture("test-cert.pem"), during_crl_window)
  // With the host recorded, the revocation check runs again.
  fake.put_doc(
    store,
    "stir",
    crl_doc(Some("authenticate-api-stg.iconectiv.com")),
  )
  let assert Ok(trust.Validation(revocation_checked: True, crl_age_s: _)) =
    trust.validate_chain_report(kz, fixture("test-cert.pem"), during_crl_window)
}

/// `thisUpdate` and `cRLNumber` order one issuer's CRLs. A CRL stored
/// from another STI-PA host says nothing about the order of this host's,
/// so it does not hold a refresh back; one from the same host does.
pub fn only_a_crl_from_the_same_host_is_compared_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let later =
    crl_doc(Some("authenticate-api.iconectiv.com"))
    |> doc.set([trust.this_update_field], doc.Int(crl_this_update + 86_400))
    |> doc.set([trust.crl_number_field], doc.Int(crl_number + 1000))
  fake.put_doc(store, "stir", later)
  let assert Ok([_, _]) =
    trust.refresh(
      kz,
      stipa_transport(process.new_subject(), sequence: 1),
      base,
      100,
    )
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  assert doc.get_string(document, [trust.stipa_host_field])
    == Ok("authenticate-api-stg.iconectiv.com")

  // The same later CRL recorded from staging itself holds it back.
  fake.put_doc(
    store,
    "stir",
    doc.set(
      document,
      [trust.this_update_field],
      doc.Int(crl_this_update + 86_400),
    ),
  )
  let assert Ok([_]) =
    trust.refresh(
      kz,
      stipa_transport(process.new_subject(), sequence: 1),
      base,
      100,
    )

  // A higher number stored for the same moment holds it back too; for an
  // earlier moment it does not decide anything.
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  fake.put_doc(
    store,
    "stir",
    document
      |> doc.set([trust.this_update_field], doc.Int(crl_this_update))
      |> doc.set([trust.crl_number_field], doc.Int(crl_number + 1)),
  )
  let assert Ok([_]) =
    trust.refresh(
      kz,
      stipa_transport(process.new_subject(), sequence: 1),
      base,
      100,
    )
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  fake.put_doc(
    store,
    "stir",
    document
      |> doc.set([trust.this_update_field], doc.Int(crl_this_update - 60))
      |> doc.set([trust.crl_number_field], doc.Int(crl_number + 1)),
  )
  let assert Ok([_, _]) =
    trust.refresh(
      kz,
      stipa_transport(process.new_subject(), sequence: 1),
      base,
      100,
    )
}

/// When the STI-PA rotates its CRL signer, neither half can be checked
/// against the other one stored. A file holding both replaces both, the
/// CRL checked against the signer beside it; only the CRL block is kept
/// as the bundle.
pub fn a_crl_and_its_signer_uploaded_together_replace_both_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem") <> fixture("stipa-stg-root.pem"))
  fake.put_doc(
    store,
    "stir",
    crl_doc(None)
      |> doc.set([trust.signer_field], doc.String(fixture("test-cert.pem"))),
  )
  let assert Error(_) =
    trust.upload(kz, trust.Crl, fixture("stipa-stg-crl.pem"), "sup")
  let assert Ok(_) =
    trust.upload(
      kz,
      trust.Crl,
      fixture("stipa-stg-crl.pem") <> fixture("stipa-stg-crl-signer.pem"),
      "sup",
    )
  let assert Ok(document) = fake.lookup(store, "stir", "trust-crl")
  let assert Ok(bundle) = doc.get_string(document, [trust.bundle_field])
  assert !string.contains(bundle, "CERTIFICATE")
  let assert Ok(signer) = doc.get_string(document, [trust.signer_field])
  assert string.contains(signer, "BEGIN CERTIFICATE")
  assert doc.get_bool(document, [trust.authenticated_field]) == Ok(True)
}

/// A CRL uploaded before its signer, or stored before CRLs were
/// authenticated, is not used for the revocation check and not a reason
/// to refuse a call: calls are verified and marked unchecked. Only a
/// refreshed one makes the monitor refetch early.
pub fn an_unauthenticated_crl_leaves_calls_unchecked_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  pin(kz, fixture("test-cert.pem"))
  let assert Ok([_, _]) =
    trust.refresh(
      kz,
      stipa_transport(process.new_subject(), sequence: 1),
      base,
      100,
    )
  assert trust.crl_authenticated(kz)
  fake.put_doc(
    store,
    "stir",
    crl_doc(None) |> doc.delete([trust.authenticated_field]),
  )
  let assert Ok(trust.Validation(revocation_checked: False, crl_age_s: _)) =
    trust.validate_chain_report(kz, fixture("test-cert.pem"), during_crl_window)
  // An upload waiting for its signer is the operator's to finish.
  assert trust.crl_authenticated(kz)
}

/// What `GET /v2/stir/trust` reports on the `ca` row: each role's roots,
/// and the roots from before the roles as `legacy`.
pub fn root_sets_test() {
  let store = fake.new()
  let kz = fake.kazoo(store)
  assert trust.root_sets(kz) == []
  pin(kz, fixture("test-cert.pem") <> fixture("stipa-stg-root.pem"))
  let assert Ok(_) =
    trust.upload_root(kz, trust.CallRoot, fixture("test-cert.pem"), "a/u")
  let assert [stipa_set, calls_set] = trust.root_sets(kz)
  assert stipa_set.role == "stipa"
  assert stipa_set.count == 2
  assert stipa_set.by == Some("sup")
  assert calls_set.role == "calls"
  assert calls_set.count == 1
  assert calls_set.by == Some("a/u")
  let assert Ok(document) = fake.lookup(store, "stir", "trust-ca")
  fake.put_doc(
    store,
    "stir",
    doc.set(
      document,
      [trust.legacy_roots_field],
      doc.String(fixture("test-cert.pem")),
    ),
  )
  let assert [_, _, legacy] = trust.root_sets(kz)
  assert legacy.role == "legacy"
  assert legacy.by == None
}

/// A document from before the roles has one `roots` field. It is read
/// as call roots and never as a pin: the refresh it used to let through
/// is refused until the STI-PA root is uploaded again with the role
/// stipa, and a call-root upload replaces it.
pub fn legacy_roots_are_call_roots_only_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  fake.put_doc(
    store,
    "stir",
    doc.object([
      #("_id", doc.String("trust-ca")),
      #("pvt_type", doc.String(trust.doc_type)),
      #("kind", doc.String("ca")),
      #("fetched_at", doc.Int(0)),
      #("source", doc.String("upload")),
      #(trust.legacy_roots_field, doc.String(fixture("test-cert.pem"))),
    ]),
  )
  let assert Ok(report) =
    trust.validate_chain_report(kz, fixture("test-cert.pem"), during_crl_window)
  assert !report.revocation_checked
  let calls = process.new_subject()
  let assert Error(trust.Stipa(stipa.Untrusted(why))) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)
  assert why == "no trust anchor for the chain"

  let assert Ok(_) =
    trust.upload(
      kz,
      trust.Ca,
      fixture("example-shaken-intermediate.pem"),
      "sup",
    )
  let assert Ok(document) = fake.lookup(store, "stir", "trust-ca")
  assert doc.get_string(document, [trust.legacy_roots_field]) == Error(Nil)
  let assert Error(_) =
    trust.validate_chain(kz, fixture("test-cert.pem"), during_crl_window)

  pin(kz, fixture("test-cert.pem"))
  let assert Ok(_) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)
}

/// A root upload keeps its `CERTIFICATE` blocks and nothing else, checks
/// every one of them, and writes only its own role's field.
pub fn a_root_upload_keeps_only_its_certificates_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let assert Ok(_) =
    trust.upload_root(
      kz,
      trust.StipaRoot,
      fixture("test-key.pem") <> fixture("stipa-stg-root.pem"),
      "acct/user",
    )
  let assert Ok(document) = fake.lookup(store, "stir", "trust-ca")
  let assert Ok(pinned) = doc.get_string(document, [trust.stipa_roots_field])
  assert !string.contains(pinned, "PRIVATE KEY")
  assert string.starts_with(pinned, "-----BEGIN CERTIFICATE-----\n")
  assert doc.get_string(document, ["stipa_roots_by"]) == Ok("acct/user")
  assert doc.get_int(document, ["stipa_roots_at"])
    == Ok(modb.from_unix(during_crl_window))
  assert doc.get_string(document, [trust.call_roots_field]) == Error(Nil)

  // The second certificate is checked as well as the first.
  let assert Error(trust.Stipa(stipa.Malformed(why))) =
    trust.upload_root(
      kz,
      trust.CallRoot,
      fixture("test-cert.pem") <> leaf_of(fixture("example-999Y-chain.pem")),
      "sup",
    )
  assert string.starts_with(
    why,
    "the upload is neither a CA certificate nor a self-signed one",
  )
  // A call-root upload leaves the STI-PA roots alone.
  let assert Ok(_) = trust.upload(kz, trust.Ca, fixture("test-cert.pem"), "sup")
  let assert Ok(document) = fake.lookup(store, "stir", "trust-ca")
  assert doc.get_string(document, [trust.stipa_roots_field]) == Ok(pinned)
  assert doc.get_string(document, ["call_roots_by"]) == Ok("sup")
}

pub fn empty_store_test() {
  let store = fake.new()
  let kz = fake.kazoo(store)
  assert trust.status(kz) == Ok([])
  assert trust.pem(kz, trust.Ca) == Error(trust.NotFound)
  assert trust.pem(kz, trust.Crl) == Error(trust.NotFound)
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Error(
      "no trust material stored: refresh the CA list, or upload a root with POST /v2/stir/trust",
    )
}

pub fn upload_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let fetched_at = modb.from_unix(during_crl_window)
  assert trust.upload(kz, trust.Ca, "not a certificate", "sup")
    == Error(
      trust.Stipa(stipa.Malformed(
        "the upload holds no -----BEGIN CERTIFICATE----- block",
      )),
    )
  assert trust.upload(kz, trust.Crl, "neither one nor the other", "sup")
    == Error(
      trust.Stipa(stipa.Malformed(
        "the upload holds no -----BEGIN X509 CRL----- block",
      )),
    )
  // A certificate nothing can anchor to is refused rather than pinned:
  // the example SHAKEN leaf is an end-entity certificate issued by the
  // intermediate, so pinning it would anchor nothing.
  let assert Error(trust.Stipa(stipa.Malformed(why))) =
    trust.upload(
      kz,
      trust.Ca,
      leaf_of(fixture("example-999Y-chain.pem")),
      "sup",
    )
  assert string.starts_with(
    why,
    "the upload is neither a CA certificate nor a self-signed one",
  )
  // And a block that holds no certificate at all.
  let assert Error(trust.Stipa(stipa.Malformed(unreadable))) =
    trust.upload(kz, trust.Ca, fixture("garbage-cert.pem"), "sup")
  assert string.starts_with(
    unreadable,
    "the upload is not a certificate this can read",
  )

  // A CA upload is a call root: no bundle, no source of its own, no
  // fetch time. The document it creates has never fetched anything.
  assert trust.upload(
      kz,
      trust.Ca,
      fixture("example-shaken-intermediate.pem"),
      "acct/user",
    )
    == Ok(trust.Status(
      kind: trust.Ca,
      fetched_at: 0,
      source: "upload",
      detail: None,
    ))
  assert trust.pem(kz, trust.Ca) == Error(trust.NotFound)
  let assert Ok(document) = fake.lookup(store, "stir", "trust-ca")
  assert doc.get_string(document, ["call_roots_by"]) == Ok("acct/user")
  assert doc.get_int(document, ["call_roots_at"]) == Ok(fetched_at)

  // A CRL upload is the CRL, and its own `nextUpdate` becomes the
  // detail: a hand-uploaded CRL that cleared it made every pass refetch.
  // No signer is stored yet, so it is stored as it came.
  assert trust.upload(kz, trust.Crl, fixture("stipa-stg-crl.pem"), "acct/user")
    == Ok(trust.Status(
      kind: trust.Crl,
      fetched_at:,
      source: "upload",
      detail: Some(1_789_227_644),
    ))
  // An uploaded CRL has no signer with it, and the checker says so --
  // once there is a bundle to check a chain against at all. The refresh
  // below stores one, so it is dropped again to model a store where
  // only uploads have ever happened. The staging root is pinned beside
  // the list's signer, since an uploaded CRL came from no host and the
  // shipped staging root does not apply to it.
  let calls = process.new_subject()
  pin(kz, fixture("test-cert.pem") <> fixture("stipa-stg-root.pem"))
  let assert Ok(_) =
    trust.refresh(kz, stipa_transport(calls, sequence: 1), base, 100)
  let assert Ok(_) =
    trust.upload(kz, trust.Crl, fixture("stipa-stg-crl.pem"), "acct/user")
  let assert Ok(crl_document) = fake.lookup(store, "stir", "trust-crl")
  fake.put_doc(store, "stir", doc.delete(crl_document, [trust.signer_field]))
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Error("CRL signer certificate missing")
  // A certificate under the CRL kind is that missing signer. The CRL
  // itself, and its next update, stay where they are.
  let assert Ok(signer) =
    trust.upload(
      kz,
      trust.Crl,
      fixture("stipa-stg-crl-signer.pem"),
      "acct/user",
    )
  assert signer.kind == trust.Crl
  assert signer.detail == Some(1_789_227_644)
  // An upload is normalised to one trailing newline; the fixture file
  // has none.
  assert trust.pem(kz, trust.Crl) == Ok(fixture("stipa-stg-crl.pem") <> "\n")
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Ok(Nil)
}

/// A root pinned after a refresh leaves the CA list exactly as it was:
/// the bundle, the source, the sequence and the fetch time. The old
/// behaviour replaced the bundle with the uploaded root, which left
/// every inbound call failing "no trust anchor" until the next refresh.
pub fn ca_upload_keeps_the_bundle_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let calls = process.new_subject()
  pin(kz, fixture("test-cert.pem"))
  let assert Ok([before, _]) =
    trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
  let bundle = trust.pem(kz, trust.Ca)

  let assert Ok(after) =
    trust.upload(
      kz,
      trust.Ca,
      fixture("example-shaken-intermediate.pem"),
      "sup",
    )
  assert after == before
  assert trust.pem(kz, trust.Ca) == bundle
  // And a call still verifies against it, at once rather than after the
  // next refresh.
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Ok(Nil)
}

/// The rollback check reads a member no upload writes over. Pinning a
/// root used to clear `detail`, and the next replayed list was taken.
pub fn a_root_upload_does_not_reset_the_rollback_check_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let calls = process.new_subject()
  pin(kz, fixture("test-cert.pem"))
  let assert Ok(_) =
    trust.refresh(kz, stipa_transport(calls, sequence: 43), base, 100)
  // An operator pins another root in between, as they would when the
  // STI-PA announces one.
  pin(kz, fixture("test-cert.pem") <> fixture("stipa-stg-root.pem"))
  assert trust.refresh(kz, stipa_transport(calls, sequence: 42), base, 100)
    == Error(
      trust.Stipa(stipa.Untrusted(
        "the CA list sequence 42 is below the stored 43",
      )),
    )
}

/// A CRL that is missing, or past its next update, is not a closed
/// door: the chain is validated without the revocation check and the
/// answer says the check did not happen.
pub fn a_missing_crl_is_unchecked_not_closed_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let calls = process.new_subject()
  pin(kz, fixture("test-cert.pem"))
  // The list came, the CRL never did.
  let assert Ok([_ca]) =
    trust.refresh(kz, without_crl(calls, sequence: 9), base, 100)
  let assert Ok(report) =
    trust.validate_chain_report(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
  assert report == trust.Validation(revocation_checked: False, crl_age_s: None)
}

/// The two anchor sets are separate: the CA list and the call roots
/// anchor calls, and the STI-PA pins anchor the STI-PA's own
/// certificates. Here the staging root is in the CA list itself -- the
/// real list carries the STI-PA's own root -- and the CRL its CRL signer
/// signed is stored with no host: the list does not vouch for the CRL,
/// so the check refuses it for the reason under test, the signer's
/// anchor, and not for a name or a signature. Pinned, the same CRL
/// checks.
pub fn the_crl_signer_anchors_in_the_pinned_roots_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  fake.put_doc(
    store,
    "stir",
    doc.object([
      #("_id", doc.String("trust-ca")),
      #("pvt_type", doc.String(trust.doc_type)),
      #("kind", doc.String("ca")),
      #("fetched_at", doc.Int(modb.from_unix(during_crl_window))),
      #("source", doc.String("stipa")),
      #(
        trust.bundle_field,
        doc.String(
          fixture("example-shaken-intermediate.pem")
          <> fixture("stipa-stg-root.pem"),
        ),
      ),
    ]),
  )
  fake.put_doc(store, "stir", crl_doc(None))
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Error("CRL signer does not chain to the trust bundle")
  // A call root is no better than the list.
  let assert Ok(_) =
    trust.upload(kz, trust.Ca, fixture("stipa-stg-root.pem"), "sup")
  assert trust.validate_chain(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
    == Error("CRL signer does not chain to the trust bundle")
  // Recorded as fetched from staging, the shipped root pins it.
  fake.put_doc(store, "stir", crl_doc(Some(trust.staging_host)))
  let assert Ok(report) =
    trust.validate_chain_report(
      kz,
      fixture("example-999Y-chain.pem"),
      during_crl_window,
    )
  assert report.revocation_checked
}

pub fn kind_to_string_test() {
  assert trust.kind_to_string(trust.Ca) == "ca"
  assert trust.kind_to_string(trust.Crl) == "crl"
  assert trust.role_to_string(trust.StipaRoot) == "stipa"
  assert trust.role_to_string(trust.CallRoot) == "calls"
}

/// Pin roots the way an operator does before the first refresh: an
/// upload with the role `stipa`.
fn pin(kz: kazoo.Kazoo, pem: String) -> Nil {
  let assert Ok(_) = trust.upload_root(kz, trust.StipaRoot, pem, "sup")
  Nil
}

/// A `trust-crl` holding the staging CRL and its signer, authenticated,
/// fetched from `host`, or uploaded when there is none.
fn crl_doc(host: option.Option(String)) -> doc.Value {
  doc.object_some([
    #("_id", Some(doc.String("trust-crl"))),
    #("pvt_type", Some(doc.String(trust.doc_type))),
    #("kind", Some(doc.String("crl"))),
    #("fetched_at", Some(doc.Int(modb.from_unix(during_crl_window)))),
    #(
      "source",
      Some(
        doc.String(case host {
          Some(_) -> "stipa"
          None -> "upload"
        }),
      ),
    ),
    #("detail", Some(doc.Int(1_789_227_644))),
    #(trust.bundle_field, Some(doc.String(fixture("stipa-stg-crl.pem")))),
    #(trust.signer_field, Some(doc.String(fixture("stipa-stg-crl-signer.pem")))),
    #(trust.stipa_host_field, option.map(host, doc.String)),
    #(trust.authenticated_field, Some(doc.Bool(True))),
  ])
}

/// The staging CRL as DER with the last byte of its signature changed:
/// it still parses, and no longer verifies.
fn tampered_crl() -> String {
  let der = bit_array.from_string(der_of(fixture("stipa-stg-crl.pem")))
  let size = bit_array.byte_size(der)
  let assert Ok(head) = bit_array.slice(der, 0, size - 1)
  let assert Ok(<<last>>) = bit_array.slice(der, size - 1, 1)
  mutate.unsafe_string(
    bit_array.concat([head, <<int.bitwise_exclusive_or(last, 1)>>]),
  )
}

/// The STI-PA at `base`: the list signed by the test key with the test
/// certificate at its `x5u`, the staging CRL and its signer.
fn stipa_transport(
  calls: process.Subject(String),
  sequence sequence: Int,
) -> http.Transport {
  serving_crl(calls, sequence, fixture("stipa-stg-crl.pem"))
}

/// The same, with `crl` at the CRL's URL.
fn serving_crl(
  calls: process.Subject(String),
  sequence: Int,
  crl: String,
) -> http.Transport {
  fake_transport(
    [
      #(
        base <> stipa.ca_list_path,
        ok(200, envelope(list_jwt(base:, sequence:))),
      ),
      #(signer_url, ok(200, fixture("test-cert.pem"))),
      #(base <> trust.crl_path, ok(200, crl)),
      #(crl_signer_url, ok(200, fixture("stipa-stg-crl-signer.pem"))),
    ],
    calls,
    timeouts: [],
  )
}

/// The staging STI-PA's own answers, as fetched.
fn staging_transport(calls: process.Subject(String)) -> http.Transport {
  fake_transport(
    [
      #(base <> stipa.ca_list_path, ok(200, fixture("stipa-stg-ca-list.json"))),
      #(
        staging_list_signer_url,
        ok(200, fixture("stipa-stg-ca-list-signer.pem")),
      ),
      #(base <> trust.crl_path, ok(200, fixture("stipa-stg-crl.pem"))),
      #(crl_signer_url, ok(200, fixture("stipa-stg-crl-signer.pem"))),
    ],
    calls,
    timeouts: [],
  )
}

/// The same, with nothing at the CRL's URL.
fn without_crl(
  calls: process.Subject(String),
  sequence sequence: Int,
) -> http.Transport {
  fake_transport(
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

fn envelope(jwt: String) -> String {
  doc.to_string(doc.object([#("caList", doc.String(jwt))]))
}

/// The first certificate of a chain: an end-entity certificate, which
/// is what an operator pinning the wrong half of their chain uploads.
fn leaf_of(chain: String) -> String {
  let end = "-----END CERTIFICATE-----\n"
  { string.split(chain, end) |> list.first |> result.unwrap("") } <> end
}

/// A root an operator uploaded anchors call chains on its own, with no
/// CA list stored: what a lab with a private CA needs, and what the
/// bootstrap of a production cluster leaves in place until the first
/// refresh. The shipped STI-PA pins do not anchor calls.
pub fn an_uploaded_root_anchors_calls_test() {
  let store = fake.new()
  fake.set_now(store, during_crl_window)
  let kz = fake.kazoo(store)
  let assert Error(_) = trust.validate_chain(kz, fixture("test-cert.pem"), 1)
  let assert Ok(_) = trust.upload(kz, trust.Ca, fixture("test-cert.pem"), "sup")
  let assert Ok(report) =
    trust.validate_chain_report(kz, fixture("test-cert.pem"), 1_800_000_000)
  assert report.revocation_checked == False
  // The example SHAKEN chain does not chain to the test root.
  let assert Error(_) =
    trust.validate_chain(kz, fixture("example-999Y-chain.pem"), 1_800_000_000)
}
