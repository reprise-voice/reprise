//// The attestation policy, rule by rule and setting by setting
//// (`doc/engineering/stir-shaken.md` §3.5). Pure: the facts are built by
//// hand and the settings start from the defaults `settings.load` answers
//// over an empty fake.

import gleam/list
import gleam/option.{None, Some}
import kazoo/testing/fake
import stir/attest.{Facts, Passthru, Sign, Skip}
import stir/settings.{A, B, C}

fn defaults() -> settings.Settings {
  settings.load(fake.kazoo(fake.new()))
}

/// A leg with nothing going for it: rule 5.
fn plain() -> attest.Facts {
  Facts(
    account_id: "a1",
    orig_tn: "14045550100",
    dest_tn: "14045550199",
    owned_by_account: False,
    owned_by_ancestor: False,
    verified_external: False,
    inception_offnet: False,
    forwarded_with_caller_id: False,
    inbound_carrier: False,
    inbound_caller: "",
    inbound_verdict: None,
    inbound_attest: None,
    anonymous: False,
    emergency: False,
  )
}

/// A leg that forwards an inbound carrier call, with everything rule 2
/// wants: the markers, the inbound hook's record that the call came from
/// a carrier, and that call's caller as the number being signed.
fn corroborated() -> attest.Facts {
  Facts(
    ..plain(),
    forwarded_with_caller_id: True,
    inbound_carrier: True,
    inbound_caller: plain().orig_tn,
    inbound_verdict: Some(attest.Passed),
    inbound_attest: Some(A),
  )
}

const levels = [A, B, C]

pub fn is_nanp_test() {
  assert attest.is_nanp("14045550100")
  assert attest.is_nanp("12125551212")
  // Ten digits, no country code.
  assert !attest.is_nanp("4045550100")
  // Twelve digits.
  assert !attest.is_nanp("140455501000")
  // Not ours.
  assert !attest.is_nanp("442071234567")
  assert !attest.is_nanp("24045550100")
  // NXX: the area code and the exchange start at 2.
  assert !attest.is_nanp("11045550100")
  assert !attest.is_nanp("10455501000")
  assert !attest.is_nanp("14040550100")
  assert !attest.is_nanp("14041550100")
  // Not digits.
  assert !attest.is_nanp("1404555010a")
  assert !attest.is_nanp("+14045550100")
  assert !attest.is_nanp("")
}

pub fn owned_number_test() {
  let owned = Facts(..plain(), owned_by_account: True)
  list.each(levels, fn(level) {
    let config = settings.Settings(..defaults(), attest_owned_number: level)
    assert attest.decide(owned, config) == Sign(level)
  })
  // The default is A.
  assert attest.decide(owned, defaults()) == Sign(A)
  // Ownership comes before every other rule: a transit call with our
  // number is A. A forward of an inbound carrier call whose caller id is
  // ours is held to what that call carried: one of our numbers arriving
  // from a carrier is what a spoof of it looks like.
  let forwarded =
    Facts(
      ..corroborated(),
      owned_by_account: True,
      inbound_verdict: Some(attest.Failed),
    )
  assert attest.decide(forwarded, defaults()) == Sign(C)
  assert attest.decide(
      Facts(..forwarded, inbound_verdict: Some(attest.Passed)),
      defaults(),
    )
    == Sign(A)
  assert attest.decide(
      Facts(
        ..forwarded,
        inbound_verdict: Some(attest.Passed),
        inbound_attest: Some(C),
      ),
      defaults(),
    )
    == Sign(C)
  assert attest.decide(Facts(..owned, inception_offnet: True), defaults())
    == Sign(A)
  assert attest.decide(Facts(..owned, verified_external: True), defaults())
    == Sign(A)
}

pub fn owned_by_ancestor_test() {
  let by_parent = Facts(..plain(), owned_by_ancestor: True)
  // The default scope is the account itself: a parent's number is not
  // ours, and the leg falls through to rule 5.
  assert defaults().attest_owned_scope == "account"
  assert attest.decide(by_parent, defaults()) == Sign(B)
  let tree = settings.Settings(..defaults(), attest_owned_scope: "tree")
  assert attest.decide(by_parent, tree) == Sign(A)
  list.each(levels, fn(level) {
    let config = settings.Settings(..tree, attest_owned_number: level)
    assert attest.decide(by_parent, config) == Sign(level)
  })
  // With the scope back to `account` the setting for owned numbers does
  // not reach a parent's number.
  let account = settings.Settings(..defaults(), attest_owned_number: C)
  assert attest.decide(by_parent, account) == Sign(B)
}

pub fn forwarded_test() {
  let forwarded = corroborated()
  // Defaults: B on an inbound call that verified (the caller's number
  // is not ours, so A is an operator's choice), and C when it failed or
  // nobody validated it -- a forward is capped at the level the inbound
  // call carried, and a call that did not verify carried none.
  assert defaults().attest_forwarded == B
  assert attest.decide(forwarded, defaults()) == Sign(B)
  assert attest.decide(
      Facts(..forwarded, inbound_verdict: Some(attest.Failed)),
      defaults(),
    )
    == Sign(C)
  assert attest.decide(
      Facts(..forwarded, inbound_verdict: Some(attest.NoValidation)),
      defaults(),
    )
    == Sign(C)
  assert attest.decide(Facts(..forwarded, inbound_verdict: None), defaults())
    == Sign(C)

  // Every value of `attest_forwarded` applies to the inbound call that
  // verified, and to no other.
  let failed = Facts(..forwarded, inbound_verdict: Some(attest.Failed))
  let unvalidated =
    Facts(..forwarded, inbound_verdict: Some(attest.NoValidation))
  list.each(levels, fn(level) {
    let config = settings.Settings(..defaults(), attest_forwarded: level)
    assert attest.decide(forwarded, config) == Sign(level)
    assert attest.decide(failed, config) == Sign(C)
    assert attest.decide(unvalidated, config) == Sign(C)
  })

  // A failed or unvalidated inbound call is capped at C whatever its own
  // setting says: less evidence never earns a higher level than a call
  // that verified at C.
  list.each(levels, fn(level) {
    let failed_config =
      settings.Settings(
        ..defaults(),
        attest_forwarded_when_inbound_failed: level,
      )
    assert attest.decide(failed, failed_config) == Sign(C)
    assert attest.decide(forwarded, failed_config) == Sign(B)
    let unverified_config =
      settings.Settings(..defaults(), attest_unverified: level)
    assert attest.decide(unvalidated, unverified_config) == Sign(C)
    assert attest.decide(
        Facts(..forwarded, inbound_verdict: None),
        unverified_config,
      )
      == Sign(C)
    assert attest.decide(forwarded, unverified_config) == Sign(B)
  })

  // `passthru` on either forwarded setting carries the header through,
  // and only in the case that setting governs.
  let passthru =
    settings.Settings(..defaults(), attest_forwarded: settings.Passthru)
  assert attest.decide(forwarded, passthru) == Passthru
  assert attest.decide(failed, passthru) == Sign(C)
  assert attest.decide(unvalidated, passthru) == Sign(C)
  let passthru_failed =
    settings.Settings(
      ..defaults(),
      attest_forwarded_when_inbound_failed: settings.Passthru,
    )
  assert attest.decide(failed, passthru_failed) == Passthru
  assert attest.decide(forwarded, passthru_failed) == Sign(B)

  // Forwarding comes before the verified external number and the transit
  // rules.
  assert attest.decide(Facts(..forwarded, verified_external: True), passthru)
    == Passthru
  assert attest.decide(
      Facts(..forwarded, inception_offnet: True, verified_external: True),
      settings.Settings(..defaults(), attest_verified_external_number: C),
    )
    == Sign(B)
}

/// A spoof its originating provider signed C verifies at the terminating
/// carrier (the signature is good; C says nothing about the caller). A
/// forward of it must not leave under our certificate above C, whatever
/// `attest_forwarded` says: a DID that forwards with the caller id kept
/// would otherwise turn C into A.
pub fn a_forward_is_never_signed_above_the_call_it_forwards_test() {
  let generous = settings.Settings(..defaults(), attest_forwarded: A)
  let at = fn(level) { Facts(..corroborated(), inbound_attest: level) }
  assert attest.decide(at(Some(A)), generous) == Sign(A)
  assert attest.decide(at(Some(B)), generous) == Sign(B)
  assert attest.decide(at(Some(C)), generous) == Sign(C)
  // Nothing said what the inbound call was attested at: C.
  assert attest.decide(at(None), generous) == Sign(C)
  // The cap lowers and never raises.
  let strict = settings.Settings(..defaults(), attest_forwarded: C)
  assert attest.decide(at(Some(A)), strict) == Sign(C)
  // `passthru` carries the inbound call's own signature, at its own level.
  let passthru =
    settings.Settings(..defaults(), attest_forwarded: settings.Passthru)
  assert attest.decide(at(Some(C)), passthru) == Passthru
  // The level decides nothing when the forward is not corroborated.
  assert attest.decide(
      Facts(..at(Some(A)), inbound_carrier: False, inception_offnet: True),
      generous,
    )
    == Sign(C)
}

pub fn lowest_test() {
  assert attest.lowest(A, B) == B
  assert attest.lowest(B, A) == B
  assert attest.lowest(C, A) == C
  assert attest.lowest(A, A) == A
  // `passthru` has no level of its own: any level is the lower.
  assert attest.lowest(settings.Passthru, C) == C
  assert attest.lowest(A, settings.Passthru) == A
}

/// Rule 2 needs all of: the markers, the inbound carrier fact, and the
/// inbound caller being the number about to be signed. A leg missing any
/// of them is decided by the later rules, which is B for a call with
/// nothing else going for it and never A.
pub fn a_forward_without_the_corroborating_facts_is_not_one_test() {
  let forwarded = corroborated()
  let cases = [
    #("no markers", Facts(..forwarded, forwarded_with_caller_id: False)),
    #("not from a carrier", Facts(..forwarded, inbound_carrier: False)),
    #("no inbound caller", Facts(..forwarded, inbound_caller: "")),
    #("another caller", Facts(..forwarded, inbound_caller: "14045550111")),
    #(
      "the inbound caller is not the orig tn",
      Facts(..forwarded, orig_tn: "14045550111"),
    ),
  ]
  list.each(cases, fn(one) {
    let #(_why, facts) = one
    assert attest.decide(facts, defaults()) == Sign(B)
    // Not even with `passthru` configured: a claim is not a forward.
    let passthru =
      settings.Settings(..defaults(), attest_forwarded: settings.Passthru)
    assert attest.decide(facts, passthru) == Sign(B)
    // The later rules do decide it: in from a carrier and back out is C.
    assert attest.decide(Facts(..facts, inception_offnet: True), defaults())
      == Sign(C)
    // ... and a verified external number of the account takes rule 3's
    // level rather than the forward's.
    let external =
      settings.Settings(..defaults(), attest_verified_external_number: A)
    assert attest.decide(Facts(..facts, verified_external: True), external)
      == Sign(A)
  })
}

pub fn verified_external_number_test() {
  let verified = Facts(..plain(), verified_external: True)
  // B by default: how a number came to be verified is outside this
  // application, and not every way shows the account holds it.
  assert defaults().attest_verified_external_number == B
  assert attest.decide(verified, defaults()) == Sign(B)
  list.each(levels, fn(level) {
    let config =
      settings.Settings(..defaults(), attest_verified_external_number: level)
    assert attest.decide(verified, config) == Sign(level)
  })
  // Before transit.
  let external =
    settings.Settings(..defaults(), attest_verified_external_number: A)
  assert attest.decide(Facts(..verified, inception_offnet: True), external)
    == Sign(A)
}

pub fn transit_test() {
  let transit = Facts(..plain(), inception_offnet: True)
  assert attest.decide(transit, defaults()) == Sign(C)
  list.each(levels, fn(level) {
    let config = settings.Settings(..defaults(), attest_transit: level)
    assert attest.decide(transit, config) == Sign(level)
  })
}

pub fn unverified_test() {
  assert attest.decide(plain(), defaults()) == Sign(B)
  list.each(levels, fn(level) {
    let config = settings.Settings(..defaults(), attest_unverified: level)
    assert attest.decide(plain(), config) == Sign(level)
  })
}

/// `settings.load` never answers `passthru` for a rule that is not a
/// forward; a `Settings` built by hand that does is signed at B rather
/// than told to carry a header the leg does not have.
pub fn passthru_outside_the_forwarded_rules_test() {
  let config =
    settings.Settings(
      ..defaults(),
      attest_owned_number: settings.Passthru,
      attest_verified_external_number: settings.Passthru,
      attest_transit: settings.Passthru,
      attest_unverified: settings.Passthru,
    )
  assert attest.decide(Facts(..plain(), owned_by_account: True), config)
    == Sign(B)
  assert attest.decide(Facts(..plain(), verified_external: True), config)
    == Sign(B)
  assert attest.decide(Facts(..plain(), inception_offnet: True), config)
    == Sign(B)
  assert attest.decide(plain(), config) == Sign(B)
}

/// Every rule, as a leg each would sign, for the skips below.
fn one_of_each() -> List(attest.Facts) {
  [
    Facts(..plain(), owned_by_account: True),
    corroborated(),
    Facts(..corroborated(), inbound_verdict: Some(attest.Failed)),
    Facts(..plain(), forwarded_with_caller_id: True),
    Facts(..plain(), verified_external: True),
    Facts(..plain(), inception_offnet: True),
    plain(),
  ]
}

/// The same leg with another caller id. A corroborated forward is
/// corroborated about one number, so the inbound caller moves with it.
fn with_orig(facts: attest.Facts, tn: String) -> attest.Facts {
  case facts.inbound_caller {
    "" -> Facts(..facts, orig_tn: tn)
    _ -> Facts(..facts, orig_tn: tn, inbound_caller: tn)
  }
}

pub fn emergency_test() {
  // Never signed in this release, whatever else is true of the leg and
  // whatever the settings say.
  let permissive =
    settings.Settings(
      ..defaults(),
      sign_anonymous: True,
      sign_non_nanp_origin: True,
      attest_forwarded: settings.Passthru,
    )
  list.each(one_of_each(), fn(facts) {
    assert attest.decide(Facts(..facts, emergency: True), defaults())
      == Skip("emergency")
    assert attest.decide(Facts(..facts, emergency: True), permissive)
      == Skip("emergency")
    assert attest.decide(
        Facts(
          ..facts,
          emergency: True,
          anonymous: True,
          orig_tn: "442071234567",
        ),
        permissive,
      )
      == Skip("emergency")
  })
}

pub fn non_nanp_origin_test() {
  assert defaults().sign_non_nanp_origin == False
  let allowed = settings.Settings(..defaults(), sign_non_nanp_origin: True)
  list.each(one_of_each(), fn(facts) {
    let abroad = with_orig(facts, "442071234567")
    assert attest.decide(abroad, defaults()) == Skip("orig tn outside NANP")
    // With the setting on the rules apply as they would to a NANP number.
    assert attest.decide(abroad, allowed) == attest.decide(facts, allowed)
    // A NANP number is signed either way.
    assert attest.decide(facts, defaults()) == attest.decide(facts, allowed)
  })
  // A number that is not a number at all is outside NANP too.
  assert attest.decide(Facts(..plain(), orig_tn: ""), defaults())
    == Skip("orig tn outside NANP")
}

pub fn anonymous_test() {
  assert defaults().sign_anonymous == True
  let refused = settings.Settings(..defaults(), sign_anonymous: False)
  list.each(one_of_each(), fn(facts) {
    let hidden = Facts(..facts, anonymous: True)
    // Privacy does not change the orig TN: signed as the leg would be.
    assert attest.decide(hidden, defaults()) == attest.decide(facts, defaults())
    assert attest.decide(hidden, refused) == Skip("anonymous")
    assert attest.decide(facts, refused) == attest.decide(facts, defaults())
  })
}
