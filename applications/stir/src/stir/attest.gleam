//// The attestation decision: what level a call is signed at, from facts
//// the outbound path already has. Pure: no datastore, no clock beyond the
//// facts given; `stir/numbers` answers the ownership questions and hands
//// the answers in.
////
//// The rules (`doc/engineering/stir-shaken.md` §3.5), in order:
//// 1. the orig TN is assigned to the account, or to an ancestor when the
////    scope is `tree`: `attest_owned_number` (A);
//// 2. the leg forwards an inbound carrier call with that call's caller id
////    kept: `attest_forwarded` (B) when the inbound call verified,
////    `attest_forwarded_when_inbound_failed` when its Identity failed
////    verification, and `attest_unverified` when there was no verdict at
////    all, each capped at the inbound call's own level (below), which
////    makes the last two C; `passthru` means carry the original Identity
////    instead of signing;
//// 3. the orig TN is a verified external number of the account:
////    `attest_verified_external_number` (B);
//// 4. any other call that came in from a carrier and goes back out:
////    `attest_transit` (C);
//// 5. otherwise `attest_unverified` (B).
////
//// **A on a forward requires the inbound call to have been a verified
//// carrier call.** `Call-Forward` and `Retain-CID` are channel variables,
//// and a registered device can put a channel variable on a call of its
//// own by sending `X-ecallmgr_*` SIP headers, so those two are a claim
//// and not evidence. The corroboration is what only the inbound hook
//// writes: `inbound_carrier`, true when the call this leg forwards was
//// classified by the SBC as coming from a carrier, and `inbound_caller`,
//// the canonical digits of that call's caller. `cf_stir` clears the
//// `STIR-*` variables on every call it sees before it writes its own, so
//// nothing a peer sent survives under those names. Rule 2 applies only
//// when the forward markers, `inbound_carrier` and
//// `orig_tn == inbound_caller` all hold; a leg claiming to be a forward
//// without them falls through to rules 3 to 5, which never answer A for
//// a number the account does not hold.
////
//// **A forward is never signed above the call it forwards.** A spoof its
//// originating provider signed C, which the terminating carrier verified
//// (the signature is good; C says nothing about the caller), would
//// otherwise leave here at `attest_forwarded` under our certificate: any
//// DID set to forward with the caller id kept would turn C into A. On a
//// corroborated forward the level any rule gives, ownership included, is
//// capped at the inbound call's: its `STIR-Attest` (the carrier's
//// indicator or suffix, or the PASSporT's `attest`) or the `-B`/`-C`
//// suffix of its verstat, whichever is lower, when it verified; C when it
//// failed, was not validated, or nothing stated a level.
//// An orig TN outside NANP is not signed unless `sign_non_nanp_origin`;
//// privacy does not change the orig TN (`sign_anonymous`).

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import stir/settings.{type Attestation, type Settings}

/// What is known about the call when the carrier leg is built.
pub type Facts {
  Facts(
    account_id: String,
    /// Digits only, as the PASSporT carries it; the caller id that will
    /// be on the leg, before any privacy masking.
    orig_tn: String,
    /// Digits only.
    dest_tn: String,
    /// The number is assigned in service to the account itself.
    owned_by_account: Bool,
    /// ...or to an ancestor of the account.
    owned_by_ancestor: Bool,
    /// A verified `external_numbers` document of the account names it.
    verified_external: Bool,
    /// The call came in from a carrier (`Inception` offnet).
    inception_offnet: Bool,
    /// The leg claims to be a forward of an inbound call (`Call-Forward`)
    /// that keeps the caller id (`Retain-CID`). A claim: both are channel
    /// variables a device can ask for, so on its own it is never A.
    forwarded_with_caller_id: Bool,
    /// The call this leg forwards was an inbound carrier call
    /// (`STIR-Inbound-Carrier`, written only by the inbound hook).
    inbound_carrier: Bool,
    /// The canonical digits of that inbound call's caller
    /// (`STIR-Inbound-Caller`, written only by the inbound hook); empty
    /// when the inbound hook wrote none.
    inbound_caller: String,
    /// The inbound leg's own verdict, when there was one.
    inbound_verdict: Option(InboundVerdict),
    /// The level the inbound call was attested at, as the inbound hook
    /// recorded it; `None` when nothing said.
    inbound_attest: Option(Attestation),
    /// Privacy hides the caller id on this leg.
    anonymous: Bool,
    emergency: Bool,
  )
}

pub type InboundVerdict {
  Passed
  Failed
  NoValidation
}

/// What to do with the leg.
pub type Decision {
  /// Sign with this level.
  Sign(attest: Attestation)
  /// Carry the inbound leg's Identity header through unsigned.
  Passthru
  /// Neither: leave the leg alone, with the reason for the log.
  Skip(reason: String)
}

/// The decision for one leg. The three skips come first: an emergency
/// leg is never signed in this release (its caller id is decided after
/// this point, so the signed number could differ), an orig TN outside
/// NANP only when `sign_non_nanp_origin`, and a leg whose caller id is
/// hidden only when `sign_anonymous`. Then the rules of §3.5, in order.
pub fn decide(facts: Facts, config: Settings) -> Decision {
  case facts.emergency {
    True -> Skip("emergency")
    False ->
      case is_nanp(facts.orig_tn), config.sign_non_nanp_origin {
        False, False -> Skip("orig tn outside NANP")
        _, _ ->
          case facts.anonymous, config.sign_anonymous {
            True, False -> Skip("anonymous")
            _, _ -> rule(facts, config)
          }
      }
  }
}

/// The rules, and then the cap on a forward: a leg that forwards an
/// inbound carrier call is never signed above the level that call carried,
/// whichever rule decided it -- ownership included, since a caller id that
/// is one of our numbers arriving from a carrier is exactly what a spoof of
/// it looks like.
fn rule(facts: Facts, config: Settings) -> Decision {
  case corroborated(facts), by_rule(facts, config) {
    True, Sign(attestation) -> Sign(lowest(attestation, inbound_level(facts)))
    _, decision -> decision
  }
}

/// The level the forwarded call itself carried: what it was attested at
/// when it verified, and C -- gateway, the least a signature can say --
/// when it failed, was not validated, or nothing said.
fn inbound_level(facts: Facts) -> Attestation {
  case facts.inbound_verdict {
    Some(Passed) -> option.unwrap(facts.inbound_attest, settings.C)
    Some(Failed) | Some(NoValidation) | None -> settings.C
  }
}

fn by_rule(facts: Facts, config: Settings) -> Decision {
  let owned =
    facts.owned_by_account
    || { facts.owned_by_ancestor && config.attest_owned_scope == "tree" }
  case owned {
    // 1. One of our own numbers, by the number manager. This comes
    // before the forwarding rule; on a forward the cap in `rule` still
    // holds it to the level the inbound call carried.
    True -> level(config.attest_owned_number)
    False ->
      // 2. A forward of an inbound carrier call, with that call's caller
      // id kept. Without the corroborating facts the claim decides
      // nothing and the later rules do.
      case forward(facts, config) {
        Some(decision) -> decision
        None ->
          case facts.verified_external, facts.inception_offnet {
            // 3. A verified external number of the account.
            True, _ -> level(config.attest_verified_external_number)
            // 4. In from a carrier and back out.
            False, True -> level(config.attest_transit)
            // 5. Everything else.
            False, False -> level(config.attest_unverified)
          }
      }
  }
}

/// Rule 2, when the leg is a corroborated forward: the inbound call's own
/// verdict decides the setting. A pass is `attest_forwarded` (B by
/// default), a failure `attest_forwarded_when_inbound_failed` (B), and an
/// inbound call nobody validated is `attest_unverified` (B) -- an
/// unvalidated caller id is not evidence of who is calling, whoever
/// forwarded it. `rule` then caps the level at the inbound call's own,
/// which for a failure or no verdict is C.
fn forward(facts: Facts, config: Settings) -> Option(Decision) {
  case corroborated(facts) {
    False -> None
    True ->
      Some(case facts.inbound_verdict {
        Some(Passed) -> forwarded(config.attest_forwarded)
        Some(Failed) -> forwarded(config.attest_forwarded_when_inbound_failed)
        Some(NoValidation) | None -> level(config.attest_unverified)
      })
  }
}

/// The lower of two levels: A above B above C. `passthru` carries no level
/// of its own and ranks above A, so it is never the lower of a pair that
/// holds a level.
pub fn lowest(one: Attestation, other: Attestation) -> Attestation {
  case rank(one) <= rank(other) {
    True -> one
    False -> other
  }
}

fn rank(attestation: Attestation) -> Int {
  case attestation {
    settings.C -> 0
    settings.B -> 1
    settings.A -> 2
    settings.Passthru -> 3
  }
}

/// Whether the forward markers are backed by what only the inbound hook
/// writes: the call this leg forwards came from a carrier, and its caller
/// is the number this leg is about to sign.
fn corroborated(facts: Facts) -> Bool {
  facts.forwarded_with_caller_id
  && facts.inbound_carrier
  && facts.inbound_caller != ""
  && facts.inbound_caller == facts.orig_tn
}

/// A forwarded rule's setting: a level, or `passthru`.
fn forwarded(attestation: Attestation) -> Decision {
  case attestation {
    settings.Passthru -> Passthru
    other -> Sign(other)
  }
}

/// Any other rule's setting. `settings.load` never answers `passthru`
/// for these (it is a way to forward, not a way to attest); a `Settings`
/// built by hand that does is treated as the lowest level rather than
/// as an instruction to carry a header the leg does not have.
fn level(attestation: Attestation) -> Decision {
  case attestation {
    settings.Passthru -> Sign(settings.B)
    other -> Sign(other)
  }
}

/// Whether a digits-only number is a North American one (11 digits
/// starting with 1, NXX NXX XXXX).
pub fn is_nanp(tn: String) -> Bool {
  let digits = string.to_graphemes(tn)
  case digits {
    ["1", n1, _, _, n2, _, _, _, _, _, _] ->
      list.all(digits, is_digit) && is_n(n1) && is_n(n2)
    _ -> False
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// `N` in the NANP number plan: 2 to 9.
fn is_n(c: String) -> Bool {
  case c {
    "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
