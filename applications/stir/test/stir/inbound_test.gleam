//// `stir/inbound`: the carrier's verdict taken on the strength of its
//// resource, our own verification of an `Identity` header built here
//// and served from the fake transport, the deadline, and the Erlang
//// entry point over anything at all.
////
//// The trust material is the test certificate, uploaded as a root the
//// way an operator would (`POST /v2/stir/trust`), which is also what the
//// `x5u` serves and what `test-key.pem` signs under. There is no CRL, so
//// every verdict this node reaches itself is `unchecked` for
//// revocation. The clock is held at a second inside the certificate's
//// validity, and every PASSporT is issued at that second.

import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import kazoo/testing/fake.{type Fake}
import stir/carriers
import stir/carriers_test.{resource}
import stir/http
import stir/http_test.{drain, fake as fake_transport, fixture, ok}
import stir/inbound.{type Facts, Facts, Verdict}
import stir/jws
import stir/passport.{Claims}
import stir/trust
import stir/x5u
import support/mutate

/// 2027-01-15T08:00:00Z, inside `test-cert.pem`'s validity.
const now = 1_800_000_000

const account = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

const resource_id = "carrier00000000000000000000telnyx"

const x5u_url = "https://carrier.test/cert.pem"

const caller = "+12025550100"

const dialed = "+12025550123"

const origid = "55f23c60-74cc-4b29-b2e3-3bac121f0c30"

/// The verdict of a decision that reached one. `decide` answers `Error`
/// only for the two "leave the call alone" cases, which have tests of
/// their own.
fn decided(
  kz: Kazoo,
  transport: http.Transport,
  facts: Facts,
) -> inbound.Verdict {
  let assert Ok(verdict) = inbound.decide(kz, transport, facts)
  verdict
}

// ---------------------------------------------------------------------------
// The carrier's verdict
// ---------------------------------------------------------------------------

/// With the default policy the carrier's verdict is taken as stamped,
/// and nothing is fetched.
pub fn the_carriers_verdict_is_taken_test() {
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      verstat: Some("TN-Validation-Passed"),
      origination_id: Some("orig-1"),
      identity: Some(identity()),
    )
  assert decided(kz, transport(calls), facts)
    == Verdict(
      verstat: inbound.Passed,
      attest: None,
      origid: Some("orig-1"),
      identity_present: True,
      source: "carrier",
      revocation: "n/a",
      reason: None,
    )
  assert drain(calls) == []
}

/// The level comes from the `-B`/`-C` suffix first, then from the
/// attestation indicator, and is not stated at all for a plain pass: a
/// level the carrier did not give is not one a forward may be signed at.
pub fn the_carriers_attestation_is_read_test() {
  let stamped = fn(verstat: String, indicator: Option(String)) {
    inbound.carrier_verdict(
      Facts(
        ..carrier_facts(),
        verstat: Some(verstat),
        attest_indicator: indicator,
      ),
    )
  }
  let assert Some(b) = stamped("TN-Validation-Passed-B", None)
  assert b.attest == Some("B")
  let assert Some(c) = stamped("TN-Validation-Passed-C", Some("A"))
  assert c.attest == Some("C")
  let assert Some(indicated) = stamped("TN-Validation-Passed", Some("b"))
  assert indicated.attest == Some("B")
  let assert Some(plain) = stamped("TN-Validation-Passed", Some("X"))
  assert plain.attest == None
  let assert Some(bare) = stamped("TN-Validation-Passed", None)
  assert bare.attest == None
  let assert Some(failed) = stamped("TN-Validation-Failed", Some("C"))
  assert failed.verstat == inbound.Failed
  assert failed.attest == Some("C")
  assert failed.source == "carrier"
  assert failed.reason == Some("the carrier reported TN-Validation-Failed")
  let assert Some(none) = stamped("no-tn-validation", None)
  assert none.verstat == inbound.NoValidation
  assert none.attest == None
  assert stamped("TN-Validation-Maybe", None) == None
  assert stamped(mutate.unsafe_string(<<0xff, 0xfe>>), None) == None
  assert inbound.carrier_verdict(carrier_facts()) == None
}

/// A verstat on a call the SBC did not stamp as a carrier's is a header
/// the peer wrote, and is never believed. Neither is an `Identity` on
/// such a call: a device that can send a header can send a PASSporT it
/// bought, so nothing is fetched and the verdict says why.
pub fn a_verstat_without_a_token_is_not_believed_test() {
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  let forged =
    Facts(..carrier_facts(), token: None, verstat: Some("TN-Validation-Passed"))
  assert decided(kz, transport(calls), forged) == nothing(False)
  let with_identity = Facts(..forged, identity: Some(identity()))
  assert decided(kz, transport(calls), with_identity)
    == Verdict(..nothing(True), reason: Some("not a carrier call"))
  assert drain(calls) == []
}

/// A token that names no resource is not a carrier either.
pub fn a_token_with_no_resource_is_not_believed_test() {
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      token: Some("nobody@" <> account),
      verstat: Some("TN-Validation-Passed"),
    )
  assert decided(kz, transport(calls), facts) == nothing(False)
  // The counter is keyed by the token's account, so one account's
  // resources going missing does not hide another's.
  assert inbound.failures("no-resource:" <> account) == 1
  assert inbound.failures("no-resource") == 0
}

/// Both stamps have to say carrier. A trusted type that says the call is
/// from a registered endpoint, one this node does not know, and no type
/// at all are each not a carrier call, whatever the token says.
pub fn only_a_carrier_trusted_type_is_a_carrier_test() {
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), verstat: Some("TN-Validation-Passed"))
  list.each(
    [Some("endpoint"), Some("trusted_source"), Some("unknown"), Some(""), None],
    fn(type_) {
      assert decided(kz, transport(calls), Facts(..facts, trusted_type: type_))
        == nothing(False)
    },
  )
  // A global carrier is, in either case, and its stamp is taken.
  list.each([Some("global_carrier"), Some("Global_Carrier")], fn(type_) {
    let assert Verdict(verstat: inbound.Passed, source: "carrier", ..) =
      decided(kz, transport(calls), Facts(..facts, trusted_type: type_))
  })
  // So is a local carrier, though its own stamp is not taken: with no
  // Identity to verify here there is nothing to say about the call. The
  // test below is what shows it was classified as a carrier at all.
  assert decided(
      kz,
      transport(calls),
      Facts(..facts, trusted_type: Some("local_carrier")),
    )
    == nothing(False)
  assert drain(calls) == []
}

/// A `local_carrier` is a customer's own trunk, and what its upstream
/// does is that customer's provider's business, so `trust_upstream` on
/// one reads as `verify`: the carrier's stamp is not taken and the
/// Identity is verified here.
pub fn a_local_carrier_is_not_trusted_upstream_test() {
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      trusted_type: Some("local_carrier"),
      verstat: Some("TN-Validation-Failed"),
      identity: Some(identity()),
    )
  let verdict = decided(kz, transport(calls), facts)
  assert verdict.verstat == inbound.Passed
  assert verdict.source == "kazoo"
  assert drain(calls) == [x5u_url]
  // The same resource stamped as a global carrier is trusted for its
  // verdict, which is what the policy says on that call.
  x5u.clear()
  let global =
    decided(
      kz,
      transport(calls),
      Facts(..facts, trusted_type: Some("global_carrier")),
    )
  assert global.verstat == inbound.Failed
  assert global.source == "carrier"
  assert drain(calls) == []
}

/// A token whose account is neither the call's nor the master account is
/// not this call's carrier, whatever resource it names.
pub fn a_carrier_of_another_account_is_refused_test() {
  let #(store, kz) = setup(None)
  let other = "ffffffffffffffffffffffffffffffff"
  fake.put_doc(store, carriers.offnet_db, resource("roaming", None))
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      token: Some("roaming@" <> other),
      verstat: Some("TN-Validation-Passed"),
      identity: Some(identity()),
    )
  assert decided(kz, transport(calls), facts)
    == Verdict(..nothing(True), reason: Some("not a carrier call"))
  assert inbound.failures("foreign-carrier:" <> other) == 1
  assert drain(calls) == []
}

/// `ignore` is not a verdict of "nothing known": it is an answer of
/// `Error`, so the Erlang side leaves the call alone and writes no
/// `STIR-*` variable at all.
pub fn the_ignore_policy_records_nothing_test() {
  let #(_store, kz) = setup(Some("ignore"))
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      verstat: Some("TN-Validation-Passed"),
      identity: Some(identity()),
    )
  assert inbound.decide(kz, transport(calls), facts) == Error("ignore")
  assert drain(calls) == []
}

/// With `trust_upstream_verstat` off, the carrier's stamp is ignored
/// everywhere and the Identity is verified here.
pub fn trust_upstream_verstat_off_verifies_here_test() {
  let #(store, kz) = setup(None)
  fake.put_config(store, "trust_upstream_verstat", doc.String("false"))
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      verstat: Some("TN-Validation-Failed"),
      identity: Some(identity()),
    )
  let verdict = decided(kz, transport(calls), facts)
  assert verdict.verstat == inbound.Passed
  assert verdict.source == "kazoo"
}

// ---------------------------------------------------------------------------
// Our own verification
// ---------------------------------------------------------------------------

/// The `verify` policy ignores what the carrier stamped and verifies
/// the Identity against the uploaded root.
pub fn the_verify_policy_runs_our_own_path_test() {
  let #(_store, kz) = setup(Some("verify"))
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      verstat: Some("TN-Validation-Failed"),
      identity: Some(identity()),
    )
  assert decided(kz, transport(calls), facts)
    == Verdict(
      verstat: inbound.Passed,
      attest: Some("A"),
      origid: Some(origid),
      identity_present: True,
      source: "kazoo",
      revocation: "unchecked",
      reason: None,
    )
  assert drain(calls) == [x5u_url]
  // The certificate is cached: a second call fetches nothing.
  let assert Verdict(verstat: inbound.Passed, ..) =
    decided(kz, transport(calls), facts)
  assert drain(calls) == []
}

/// Trusting upstream with nothing stamped falls through to our own
/// verification.
pub fn a_silent_carrier_falls_through_to_our_own_path_test() {
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), identity: Some(identity()))
  let verdict = decided(kz, transport(calls), facts)
  assert verdict.verstat == inbound.Passed
  assert verdict.source == "kazoo"
  assert drain(calls) == [x5u_url]
}

pub fn a_tampered_token_fails_test() {
  let #(_store, kz) = setup(Some("verify"))
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), identity: Some(tampered(identity())))
  let verdict = decided(kz, transport(calls), facts)
  assert verdict.verstat == inbound.Failed
  assert verdict.source == "kazoo"
  assert verdict.attest == None
  assert verdict.reason
    == Some(
      "the signature does not verify against the certificate the x5u serves",
    )
  assert inbound.failures("bad-signature") == 1
  // Bytes that are not a header at all are refused, not raised on.
  let garbage = Facts(..facts, identity: Some(mutate.unsafe_string(<<0xff>>)))
  let assert Verdict(verstat: inbound.Failed, reason: Some(_), ..) =
    decided(kz, transport(calls), garbage)
}

pub fn a_number_mismatch_fails_test() {
  let #(_store, kz) = setup(Some("verify"))
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), identity: Some(identity()))
  let wrong_caller =
    decided(
      kz,
      transport(calls),
      Facts(..facts, caller_number: Some("+12025559999")),
    )
  assert wrong_caller.verstat == inbound.Failed
  let assert Some(why) = wrong_caller.reason
  assert string.contains(why, "orig")
  let wrong_dialed =
    decided(
      kz,
      transport(calls),
      Facts(..facts, dialed_number: Some("+12025559999")),
    )
  assert wrong_dialed.verstat == inbound.Failed
  let assert Some(why) = wrong_dialed.reason
  assert string.contains(why, "dest")
  // A caller that is not a number, or no caller at all, leaves the
  // PASSporT's orig with nothing to match: the verdict cannot be a pass,
  // and nobody did anything wrong, so it is No-TN-Validation.
  list.each([Some("anonymous"), None], fn(caller) {
    let unmatched =
      decided(kz, transport(calls), Facts(..facts, caller_number: caller))
    assert unmatched.verstat == inbound.NoValidation
    assert unmatched.source == "kazoo"
    assert unmatched.reason == Some("no caller number to match")
  })
  // A national form matches its E.164 form.
  let national =
    decided(
      kz,
      transport(calls),
      Facts(..facts, caller_number: Some("(202) 555-0100")),
    )
  assert national.verstat == inbound.Passed
}

pub fn a_stale_passport_fails_test() {
  let #(_store, kz) = setup(Some("verify"))
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), identity: Some(identity_at(now - 120)))
  let verdict = decided(kz, transport(calls), facts)
  assert verdict.verstat == inbound.Failed
  assert verdict.reason == Some("the PASSporT's iat is 120 s from now")
}

/// What this node could not do is `No-TN-Validation` with the reason,
/// not a failure pinned on the peer.
pub fn what_this_node_cannot_do_is_no_validation_test() {
  let #(_store, kz) = setup(Some("verify"))
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), identity: Some(identity()))
  let down =
    fake_transport(
      [#(x5u_url, Error(http.Transport("econnrefused")))],
      calls,
      timeouts: [],
    )
  let unreachable = decided(kz, down, facts)
  assert unreachable.verstat == inbound.NoValidation
  assert unreachable.source == "kazoo"
  assert unreachable.identity_present == True
  assert unreachable.reason
    == Some("the certificate could not be fetched: econnrefused")
  assert inbound.failures("fetch") == 1
  // A server that answers, but not with a certificate, is the peer's.
  x5u.clear()
  let junk = fake_transport([#(x5u_url, ok(200, "hello"))], calls, timeouts: [])
  let not_a_certificate = decided(kz, junk, facts)
  assert not_a_certificate.verstat == inbound.Failed
  assert not_a_certificate.reason
    == Some("the x5u answered 200 and no certificate")
  // An x5u this node will not fetch at all.
  let plain =
    Facts(
      ..facts,
      identity: Some(identity_with_x5u("http://carrier.test/cert.pem")),
    )
  let refused = decided(kz, transport(calls), plain)
  assert refused.verstat == inbound.Failed
  assert refused.reason
    == Some("the x5u is not an https URL this node will fetch")
}

pub fn no_trust_material_is_no_validation_test() {
  let #(_store, kz) = setup_without_root(Some("verify"))
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), identity: Some(identity()))
  let verdict = decided(kz, transport(calls), facts)
  assert verdict.verstat == inbound.NoValidation
  assert verdict.source == "kazoo"
  let assert Some(why) = verdict.reason
  assert string.starts_with(why, "no trust material stored")
}

pub fn no_token_and_no_identity_is_no_validation_test() {
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  let facts = Facts(..carrier_facts(), token: None, trusted_type: None)
  assert decided(kz, transport(calls), facts) == nothing(False)
  assert drain(calls) == []
}

/// With `verify_enabled` off there is no verdict to write and nothing to
/// clear on the Erlang side's behalf: `Error`, and the call is left as
/// it is.
pub fn verification_disabled_takes_no_verdict_test() {
  let #(store, kz) = setup(None)
  fake.put_config(store, "verify_enabled", doc.String("false"))
  let calls = process.new_subject()
  let facts =
    Facts(
      ..carrier_facts(),
      verstat: Some("TN-Validation-Passed"),
      identity: Some(identity()),
    )
  assert inbound.decide(kz, transport(calls), facts) == Error("disabled")
  assert drain(calls) == []
}

/// The whole of our own path runs under one deadline: a transport that
/// never comes back is a `No-TN-Validation` with the reason, inside the
/// budget and not the transport's own time.
pub fn a_slow_fetch_is_a_timeout_test() {
  let #(store, kz) = setup(Some("verify"))
  fake.put_config(store, "verify_timeout_ms", doc.String("100"))
  let slow = fn(_req, _timeout_ms) {
    process.sleep(3000)
    ok(200, fixture("test-cert.pem"))
  }
  let facts = Facts(..carrier_facts(), identity: Some(identity()))
  let started = monotonic_ms()
  let verdict = decided(kz, slow, facts)
  let elapsed = monotonic_ms() - started
  assert verdict.verstat == inbound.NoValidation
  assert verdict.source == "kazoo"
  assert verdict.reason == Some("the verification did not finish within 500 ms")
  assert elapsed < 2000
  assert inbound.failures("timeout") == 1
}

// ---------------------------------------------------------------------------
// The CCVs and the Erlang entry point
// ---------------------------------------------------------------------------

pub fn ccvs_test() {
  assert inbound.ccvs(Verdict(
      verstat: inbound.Passed,
      attest: Some("A"),
      origid: Some("o"),
      identity_present: True,
      source: "kazoo",
      revocation: "checked",
      reason: None,
    ))
    == [
      #("STIR-Verstat", "TN-Validation-Passed"),
      #("STIR-Identity", "present"),
      #("STIR-Verdict-Source", "kazoo"),
      #("STIR-Revocation", "checked"),
      #("STIR-Attest", "A"),
      #("STIR-Orig-ID", "o"),
    ]
  assert inbound.ccvs(Verdict(
      verstat: inbound.Failed,
      attest: None,
      origid: None,
      identity_present: True,
      source: "kazoo",
      revocation: "n/a",
      reason: Some("why"),
    ))
    == [
      #("STIR-Verstat", "TN-Validation-Failed"),
      #("STIR-Identity", "present"),
      #("STIR-Verdict-Source", "kazoo"),
      #("STIR-Revocation", "n/a"),
      #("STIR-Reason", "why"),
    ]
  assert inbound.ccvs(nothing(False))
    == [
      #("STIR-Verstat", "No-TN-Validation"),
      #("STIR-Identity", "absent"),
      #("STIR-Verdict-Source", "none"),
      #("STIR-Revocation", "n/a"),
    ]
}

/// `verify/1` over the map Erlang sends answers an Erlang map of the
/// CCVs. On a test node verification is off, so the verdict is
/// `No-TN-Validation`; what is held to is the shape and that nothing
/// raises.
/// `verify/1` over the map Erlang sends answers an Erlang map of the
/// CCVs: the carrier's verdict here, over the fake.
pub fn verify_over_an_erlang_map_test() {
  let #(store, kz) = setup(None)
  let calls = process.new_subject()
  let facts =
    dynamic.properties([
      #(dynamic.string("account_id"), dynamic.string(account)),
      #(dynamic.string("trusted_type"), dynamic.string("global_carrier")),
      #(dynamic.string("token"), dynamic.string(token())),
      #(dynamic.string("verstat"), dynamic.string("TN-Validation-Passed")),
      #(dynamic.string("origination_id"), dynamic.string(origid)),
      #(dynamic.string("identity"), dynamic.string(identity())),
    ])
  let assert Ok(answer) = inbound.verify_with(kz, transport(calls), facts)
  let ccvs = doc.from_dynamic(answer)
  assert doc.get_string(ccvs, ["STIR-Verstat"]) == Ok("TN-Validation-Passed")
  assert doc.get_string(ccvs, ["STIR-Identity"]) == Ok("present")
  assert doc.get_string(ccvs, ["STIR-Verdict-Source"]) == Ok("carrier")
  assert doc.get_string(ccvs, ["STIR-Revocation"]) == Ok("n/a")
  // A plain pass states no level, so none is recorded.
  assert doc.get_string(ccvs, ["STIR-Attest"]) == Error(Nil)
  assert doc.get_string(ccvs, ["STIR-Orig-ID"]) == Ok(origid)
  assert drain(calls) == []

  // A call the node takes no verdict from at all is the reason, not a
  // map: the Erlang side leaves such a call alone.
  fake.put_config(store, "verify_enabled", doc.String("false"))
  assert inbound.verify_with(kz, transport(calls), facts) == Error("disabled")

  // And on this node, where nothing is configured, `verify/1` itself
  // answers the same rather than raising.
  assert inbound.verify(facts) == Error("disabled")
}

pub fn verify_never_raises_test() {
  let shapes = [
    dynamic.nil(),
    dynamic.int(1),
    dynamic.string("x"),
    dynamic.list([dynamic.string("identity")]),
    dynamic.properties([#(dynamic.int(1), dynamic.int(2))]),
    dynamic.properties([
      #(dynamic.string("identity"), dynamic.int(7)),
      #(dynamic.string("token"), dynamic.nil()),
    ]),
    dynamic.properties([
      #(
        dynamic.string("identity"),
        dynamic.string(mutate.unsafe_string(<<0xff, 0xfe, 0x00>>)),
      ),
      #(
        dynamic.string("verstat"),
        dynamic.string(mutate.unsafe_string(<<0xc3>>)),
      ),
      #(
        dynamic.string("token"),
        dynamic.string(mutate.unsafe_string(<<0xff, "@", 0xfe>>)),
      ),
    ]),
    dynamic.properties([
      #(dynamic.string("identity"), dynamic.string(mutate.huge("a"))),
    ]),
  ]
  // Verification is off on a test node, so every shape is the same
  // answer; what is held to is that each is an answer and never a raise.
  list.each(shapes, fn(shape) {
    assert inbound.verify(shape) == Error("disabled")
  })
  // With it on, over the fake, the same shapes still answer.
  let #(_store, kz) = setup(None)
  let calls = process.new_subject()
  list.each(shapes, fn(shape) {
    let answered = case inbound.verify_with(kz, transport(calls), shape) {
      Ok(_ccvs) -> True
      Error(_reason) -> True
    }
    assert answered
  })
}

pub fn facts_from_dynamic_test() {
  let facts =
    inbound.facts_from_dynamic(
      dynamic.properties([
        #(dynamic.string("account_id"), dynamic.string(account)),
        #(dynamic.string("token"), dynamic.string("")),
        #(dynamic.string("verstat"), dynamic.int(1)),
        #(dynamic.string("caller_number"), dynamic.string(caller)),
      ]),
    )
  assert facts
    == Facts(
      account_id: account,
      trusted_type: None,
      token: None,
      verstat: None,
      attest_indicator: None,
      origination_id: None,
      identity: None,
      caller_number: Some(caller),
      dialed_number: None,
    )
  assert inbound.facts_from_dynamic(dynamic.nil()).account_id == ""
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// A store with the clock held, verification on, the carrier resource
/// under the account with the given policy, and the test certificate
/// uploaded as a root.
fn setup(policy: Option(String)) -> #(Fake, Kazoo) {
  let #(store, kz) = setup_without_root(policy)
  let assert Ok(_) = trust.upload(kz, trust.Ca, fixture("test-cert.pem"), "sup")
  #(store, kz)
}

fn setup_without_root(policy: Option(String)) -> #(Fake, Kazoo) {
  reset()
  let store = fake.new()
  fake.set_now(store, now)
  fake.put_config(store, "verify_enabled", doc.String("true"))
  fake.put_doc(store, kazoo.account_db(account), resource(resource_id, policy))
  #(store, fake.kazoo(store))
}

/// Forget what an earlier test left on the node: counters, the carrier
/// and certificate caches. The trust material is on its documents, in
/// this test's own fake store.
fn reset() -> Nil {
  inbound.reset()
  carriers.forget_cached()
  x5u.clear()
}

fn token() -> String {
  resource_id <> "@" <> account
}

/// A call the SBC stamped as the carrier's, with nothing else on it.
fn carrier_facts() -> Facts {
  Facts(
    account_id: account,
    trusted_type: Some("global_carrier"),
    token: Some(token()),
    verstat: None,
    attest_indicator: None,
    origination_id: None,
    identity: None,
    caller_number: Some(caller),
    dialed_number: Some(dialed),
  )
}

fn nothing(present: Bool) -> inbound.Verdict {
  Verdict(
    verstat: inbound.NoValidation,
    attest: None,
    origid: None,
    identity_present: present,
    source: "none",
    revocation: "n/a",
    reason: None,
  )
}

fn transport(calls: process.Subject(String)) -> http.Transport {
  fake_transport(
    [#(x5u_url, ok(200, fixture("test-cert.pem")))],
    calls,
    timeouts: [],
  )
}

/// An Identity header for the call, signed with the test key.
fn identity() -> String {
  identity_at(now)
}

fn identity_at(iat: Int) -> String {
  build(claims(iat), x5u_url)
}

fn identity_with_x5u(x5u: String) -> String {
  build(claims(now), x5u)
}

fn build(claims: passport.Claims, x5u: String) -> String {
  let assert Ok(value) = passport.build(claims, x5u, signer())
  value
}

fn claims(iat: Int) -> passport.Claims {
  Claims(attest: "A", dest: ["12025550123"], iat:, orig: "12025550100", origid:)
}

/// The header with its payload swapped for another set of claims, so
/// the signature no longer covers it.
fn tampered(value: String) -> String {
  let assert Ok(#(compact, params)) = string.split_once(value, ";")
  let assert [header, _payload, signature] = string.split(compact, ".")
  let payload =
    passport.payload_json(Claims(..claims(now), orig: "12025559999"))
  let forged = jws.encode(<<payload:utf8>>)
  header <> "." <> forged <> "." <> signature <> ";" <> params
}

fn signer() -> jws.Signer {
  let key = fixture("test-key.pem")
  fn(input) { ecdsa_sign(key, input) }
}

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: String,
  message: String,
) -> Result(BitArray, String)

type Unit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Unit) -> Int

fn monotonic_ms() -> Int {
  monotonic_time(Millisecond)
}
