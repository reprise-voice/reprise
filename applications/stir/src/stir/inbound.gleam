//// The inbound entry point: what callflow (and trunkstore) call when the
//// winning node starts a call that came in from a carrier.
////
//// Erlang calls `'stir@inbound':verify(Facts)` with a map of binaries and
//// gets `{ok, Ccvs}` (a map of the `STIR-*` channel variables to set) or
//// `{error, Reason}`. The rules (`doc/engineering/stir-shaken.md` §3.5a):
//// the carrier's own verdict is taken first when its resource's policy is
//// `trust_upstream` and the SBC classified the call as a carrier call;
//// otherwise, or when the carrier said nothing, our own verification of
//// the Identity header runs under one deadline (`verify_timeout_ms`);
//// with neither, `No-TN-Validation`. A stale or missing CRL makes the
//// verdict `unchecked` for revocation, never a failure.
////
//// **Two answers are not verdicts at all.** `{error, <<"disabled">>}`
//// when `verify_enabled` is off and `{error, <<"ignore">>}` when the
//// resource's policy is `ignore`: the Erlang side leaves the call alone
//// on either, and writes no `STIR-*` variable of its own beyond the
//// clearing it does for every call. `{error, <<"crash">>}` is the same
//// for the caller. Every other answer is a verdict, and a verdict always
//// carries the whole set of keys (`ccvs`), so nothing of an earlier call
//// or of a peer's own headers is left half-overwritten.
////
//// Where the facts come from. Kamailio classifies the source and, for a
//// trusted carrier, stamps `X-AUTH-*` headers that it strips from every
//// untrusted request, so they cannot be forged: `X-AUTH-Token`
//// (`<resource_id>@<account_id>` from the trusted table), `X-AUTH-Trusted-Type`
//// (`global_carrier` | `local_carrier` | ...), and
//// `X-AUTH-Verstat` (the `verstat` parameter of the P-Asserted-Identity or
//// From URI), `X-AUTH-Attest` (`P-Attestation-Indicator`) and
//// `X-AUTH-Orig-ID` (`P-Origination-ID`). ecallmgr collects them as
//// `Custom-AUTH-Headers`; the `Identity` header arrives in
//// `Custom-SIP-Headers.identity`. Nothing else is trusted: a `P-` header
//// that reaches Kazoo as a plain custom SIP header is ignored.
////
//// **A carrier call is one the SBC classified as a carrier's.** Both
//// stamps must say so: `X-AUTH-Trusted-Type` is positively
//// `global_carrier` or `local_carrier` -- absent, `unknown`, `endpoint`,
//// `trusted_source` or anything else is not a carrier -- and
//// `X-AUTH-Token` resolves to a resource whose account is the call's
//// account or the master account. Anything else is not a carrier call:
//// no verdict is taken from it, and its `Identity` header is not
//// verified either, since a device that can send a header can send a
//// PASSporT it bought and the verdict would say nothing about the call.
//// Such a call is `No-TN-Validation` with the reason `not a carrier
//// call`, and nothing is fetched.
////
//// **Only a global carrier's own verdict is trusted.** `trust_upstream`
//// on a `local_carrier` resource -- a customer's own trunk, whose
//// upstream is whatever that customer's provider does -- is read as
//// `verify` instead, with one info line per token saying so. A
//// `global_carrier` is Telnyx or Bandwidth in Kamailio's trusted table,
//// and that is what §3.5a's default is about.
////
//// **Our own verification** is parse, fetch, verify, match, chain: the
//// `Identity` header taken apart, the certificate fetched from its `x5u`
//// (cached a day), the signature and the claims checked, `orig.tn`
//// against the caller number and `dest.tn` against the dialled number
//// when the call carries them, and the chain validated against the trust
//// material. What the peer got wrong is `TN-Validation-Failed` with the
//// reason; what this node could not do -- fetch the certificate, reach
//// its trust material, finish in time -- is `No-TN-Validation` with the
//// reason, since a verdict that blames the peer for this node's outage
//// would be wrong on the CDR. The whole of it runs in a process of its
//// own under one deadline, `verify_timeout_ms` plus a small allowance for
//// the work around the fetch; past that the process is killed and the
//// verdict is `No-TN-Validation` with the reason `timeout`.
////
//// Nothing here raises. `verify` is wrapped so that a crash anywhere
//// under it is `{error, <<"crash">>}` and a log line; the caller treats
//// that as no verdict.
////
//// Every failure is counted per reason in a node-local table, logged at
//// error level at most once a minute per reason, and alerted hourly
//// (`inbound:<reason>`) when a reason passes ten in five minutes. What
//// is neither a failure of the peer's nor an outage of ours -- a token
//// naming a resource that is gone, a local carrier's verdict not taken,
//// a call with no caller number -- is counted the same way and said at
//// info level, and never alerted.
////
//// Facts map keys (binaries; absent means unknown): "account_id",
//// "trusted_type", "token", "verstat", "attest_indicator",
//// "origination_id", "identity", "caller_number", "dialed_number".
////
//// Answer CCVs: "STIR-Verstat" (TN-Validation-Passed | -Failed |
//// No-TN-Validation), "STIR-Attest" (A|B|C when known), "STIR-Orig-ID",
//// "STIR-Identity" ("present"|"absent"), "STIR-Verdict-Source"
//// ("carrier"|"kazoo"|"none"), "STIR-Revocation" ("checked"|"unchecked"|
//// "n/a"), "STIR-Reason" (why a failure failed).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import stir/alert
import stir/carriers
import stir/http.{type Transport}
import stir/jws
import stir/passport.{type Claims}
import stir/settings.{type Settings}
import stir/system
import stir/trust
import stir/x5u

pub type Verstat {
  Passed
  Failed
  NoValidation
}

pub type Verdict {
  Verdict(
    verstat: Verstat,
    attest: Option(String),
    origid: Option(String),
    identity_present: Bool,
    /// `carrier`, `kazoo`, or `none`.
    source: String,
    /// `checked`, `unchecked`, or `n/a`.
    revocation: String,
    reason: Option(String),
  )
}

pub type Facts {
  Facts(
    account_id: String,
    /// `X-AUTH-Trusted-Type` as the SBC stamped it.
    trusted_type: Option(String),
    /// `X-AUTH-Token`: `<resource_id>@<account_id>` for a carrier.
    token: Option(String),
    /// `X-AUTH-Verstat`: the carrier's own verdict, when it gave one.
    verstat: Option(String),
    /// `X-AUTH-Attest`: `P-Attestation-Indicator`, when present.
    attest_indicator: Option(String),
    /// `X-AUTH-Orig-ID`: `P-Origination-ID`, when present.
    origination_id: Option(String),
    /// The `Identity` header value, when present.
    identity: Option(String),
    caller_number: Option(String),
    dialed_number: Option(String),
  )
}

/// What is added to `verify_timeout_ms` for the work around the fetch:
/// parsing, the signature, the trust reads from the node's cache and the
/// chain validation. The fetch itself is bounded by the transport. The
/// Erlang caller (`cf_stir`) waits `verify_timeout_ms` plus 500 ms of its
/// own, so this stays under that: a timeout here is answered as a verdict
/// rather than lost to the caller's.
pub const deadline_allowance_ms = 400

/// The node-local table the counters and the log throttle live in.
const table = "stir_inbound"

/// A reason is logged at error level at most this often.
const log_interval_s = 60

/// More than `failure_alert_count` failures for one reason inside
/// `failure_window_s` raise the alert.
const failure_window_s = 300

const failure_alert_count = 10

// ---------------------------------------------------------------------------
// The Erlang entry point
// ---------------------------------------------------------------------------

/// The Erlang entry point. Never raises; answers the CCV map, or the
/// reason there is no verdict to write (`disabled`, `ignore`, `crash`).
pub fn verify(facts: Dynamic) -> Result(Dynamic, String) {
  verify_with(system.live(), http.real(), facts)
}

/// The same over a given `Kazoo` and transport, for a test that wants
/// the Erlang shape of an answer over the fake.
pub fn verify_with(
  kz: Kazoo,
  transport: Transport,
  facts: Dynamic,
) -> Result(Dynamic, String) {
  call_safely(fn() {
    decide(kz, transport, facts_from_dynamic(facts))
    |> result.map(fn(verdict) {
      ccvs(verdict)
      |> list.map(fn(pair) { #(pair.0, doc.String(pair.1)) })
      |> doc.object
      |> doc.to_string
      |> to_erlang
    })
  })
  |> result.flatten
}

/// The facts as the Erlang caller sends them: a map of binaries, where a
/// missing key, an empty value or a value that is not a binary all mean
/// unknown.
pub fn facts_from_dynamic(facts: Dynamic) -> Facts {
  let value = doc.from_dynamic(facts)
  Facts(
    account_id: option.unwrap(field(value, "account_id"), ""),
    trusted_type: field(value, "trusted_type"),
    token: field(value, "token"),
    verstat: field(value, "verstat"),
    attest_indicator: field(value, "attest_indicator"),
    origination_id: field(value, "origination_id"),
    identity: field(value, "identity"),
    caller_number: field(value, "caller_number"),
    dialed_number: field(value, "dialed_number"),
  )
}

fn field(value: Value, key: String) -> Option(String) {
  case doc.get_string(value, [key]) {
    Ok("") -> None
    Ok(text) -> Some(text)
    Error(Nil) -> None
  }
}

// ---------------------------------------------------------------------------
// The decision
// ---------------------------------------------------------------------------

/// The same over typed facts with an injected transport, for tests.
/// `Error` is not a verdict: the call is left alone.
pub fn decide(
  kz: Kazoo,
  transport: Transport,
  facts: Facts,
) -> Result(Verdict, String) {
  let config = settings.load(kz)
  let present = option.is_some(facts.identity)
  case config.verify_enabled {
    False -> Error("disabled")
    True ->
      case carrier_of(kz, facts) {
        // Not a carrier call: nothing to take a verdict from, and an
        // Identity on such a call is not verified -- see the module doc.
        NotCarrier ->
          Ok(
            nothing(present, case present {
              True -> Some("not a carrier call")
              False -> None
            }),
          )
        Resolved(carrier, global) ->
          case effective_policy(kz, config, facts, carrier, global) {
            carriers.Ignore -> Error("ignore")
            carriers.Verify -> Ok(own_or_nothing(kz, transport, config, facts))
            carriers.TrustUpstream ->
              case carrier_verdict(facts) {
                Some(verdict) -> Ok(verdict)
                None -> {
                  case present {
                    True -> Nil
                    False ->
                      quiet(
                        kz,
                        "carrier-silent:" <> carrier.resource_id,
                        "carrier resource "
                          <> carrier.resource_id
                          <> " is trusted for its verdict but sent neither a verstat nor an Identity",
                        kz.now(),
                      )
                  }
                  Ok(own_or_nothing(kz, transport, config, facts))
                }
              }
          }
      }
  }
}

type Source {
  NotCarrier
  /// The resource the token named, and whether the SBC called it a
  /// global carrier (rather than a local one).
  Resolved(carrier: carriers.Carrier, global: Bool)
}

/// What the resource's policy comes to for this call. `trust_upstream`
/// is honoured only for a global carrier and only while
/// `trust_upstream_verstat` is on; a local carrier's own upstream is
/// whatever its customer's provider does, so its verdict is verified
/// here instead, with one line per token saying why.
fn effective_policy(
  kz: Kazoo,
  config: Settings,
  facts: Facts,
  carrier: carriers.Carrier,
  global: Bool,
) -> carriers.Policy {
  case carrier.policy {
    carriers.Ignore -> carriers.Ignore
    carriers.Verify -> carriers.Verify
    carriers.TrustUpstream ->
      case config.trust_upstream_verstat, global {
        False, _ -> carriers.Verify
        True, True -> carriers.TrustUpstream
        True, False -> {
          quiet(
            kz,
            "local-trust:" <> preview(option.unwrap(facts.token, "")),
            "resource "
              <> carrier.resource_id
              <> " is a local carrier, so its upstream verdict is not taken;"
              <> " the Identity header is verified here instead",
            kz.now(),
          )
          carriers.Verify
        }
      }
  }
}

/// The carrier the SBC says the call came from, when both its stamps say
/// so: a trusted type that is positively a carrier's, and a token naming
/// a resource this account may be sent calls by.
fn carrier_of(kz: Kazoo, facts: Facts) -> Source {
  case facts.token, option.then(facts.trusted_type, fold) {
    Some(token), Some("global_carrier") -> resolve(kz, facts, token, True)
    Some(token), Some("local_carrier") -> resolve(kz, facts, token, False)
    _, _ -> NotCarrier
  }
}

fn resolve(kz: Kazoo, facts: Facts, token: String, global: Bool) -> Source {
  case carriers.policy(kz, token) {
    Error(error) -> {
      // Not an outage and not an attack: a token for a resource that has
      // been deleted, or one this node's databases do not hold. Counted
      // per account so a whole account going wrong is visible, and said
      // once a minute rather than alerted.
      quiet(
        kz,
        "no-resource:" <> account_of(token),
        "the SBC's carrier token "
          <> preview(token)
          <> " resolves to no resource ("
          <> describe_carrier_error(error)
          <> "); its verdict is not taken",
        kz.now(),
      )
      NotCarrier
    }
    Ok(carrier) ->
      case carrier.account_id == facts.account_id || is_master(carrier) {
        True -> Resolved(carrier, global)
        False -> {
          quiet(
            kz,
            "foreign-carrier:" <> account_of(token),
            "the SBC's carrier token "
              <> preview(token)
              <> " belongs to neither the call's account nor the master"
              <> " account; its verdict is not taken",
            kz.now(),
          )
          NotCarrier
        }
      }
  }
}

/// Whether the token's account is the master account, which is where a
/// global resource lives. A node that cannot say which account that is
/// answers `False`: a carrier is then only ever the call's own account's.
fn is_master(carrier: carriers.Carrier) -> Bool {
  case master_account_id() {
    Ok(master) -> carrier.account_id == master
    Error(Nil) -> False
  }
}

/// The account half of a token, for a counter that groups by it. A token
/// that is not `resource@account` counts under one key of its own.
fn account_of(token: String) -> String {
  case carriers.parse_token(token) {
    Ok(#(_resource_id, account_id)) -> preview(account_id)
    Error(Nil) -> "unparsed"
  }
}

fn describe_carrier_error(error: carriers.Error) -> String {
  case error {
    carriers.BadToken -> "not resource@account"
    carriers.NotFound -> "no such resource"
    carriers.Datastore(error) -> "datastore " <> kazoo.error_to_string(error)
  }
}

/// `No-TN-Validation` from nothing: no verdict was taken and none was
/// attempted.
fn nothing(present: Bool, reason: Option(String)) -> Verdict {
  Verdict(
    verstat: NoValidation,
    attest: None,
    origid: None,
    identity_present: present,
    source: "none",
    revocation: "n/a",
    reason:,
  )
}

// ---------------------------------------------------------------------------
// The carrier's verdict
// ---------------------------------------------------------------------------

/// The carrier's verdict from the SBC's stamps, when there is one: the
/// `verstat` value (`TN-Validation-Passed[-B|-C]`, `TN-Validation-Failed`,
/// `No-TN-Validation`), the `-B`/`-C` suffix or the attestation indicator
/// for the level, the origination id for the origid.
///
/// A plain pass with no indicator records no level. Some carriers mean A
/// by it and some (Bandwidth without its enhanced mode) say nothing about
/// the level at all, and `STIR-Attest` is what a forward of the call is
/// capped at (`stir/attest`): a level nobody stated must not be one that
/// lets a C-signed call leave here signed A.
pub fn carrier_verdict(facts: Facts) -> Option(Verdict) {
  let indicator = option.then(facts.attest_indicator, level)
  case option.then(facts.verstat, fold) {
    Some("tn-validation-passed") ->
      Some(from_carrier(facts, Passed, indicator, None))
    Some("tn-validation-passed-b") ->
      Some(from_carrier(facts, Passed, Some("B"), None))
    Some("tn-validation-passed-c") ->
      Some(from_carrier(facts, Passed, Some("C"), None))
    Some("tn-validation-failed") ->
      Some(from_carrier(
        facts,
        Failed,
        indicator,
        Some("the carrier reported TN-Validation-Failed"),
      ))
    Some("no-tn-validation") ->
      Some(from_carrier(facts, NoValidation, indicator, None))
    _ -> None
  }
}

fn from_carrier(
  facts: Facts,
  verstat: Verstat,
  attest: Option(String),
  reason: Option(String),
) -> Verdict {
  Verdict(
    verstat:,
    attest:,
    origid: facts.origination_id,
    identity_present: option.is_some(facts.identity),
    source: "carrier",
    revocation: "n/a",
    reason:,
  )
}

/// `A`, `B` or `C` out of a `P-Attestation-Indicator`, in either case.
fn level(indicator: String) -> Option(String) {
  case fold(indicator) {
    Some("a") -> Some("A")
    Some("b") -> Some("B")
    Some("c") -> Some("C")
    _ -> None
  }
}

/// A header value trimmed and lowercased, when its bytes are text. A SIP
/// header is bytes a peer chose, and `gleam/string` raises on bytes that
/// are not UTF-8; bytes that are not text match nothing here.
fn fold(value: String) -> Option(String) {
  case bit_array.is_utf8(bit_array.from_string(value)) {
    True -> Some(string.lowercase(string.trim(value)))
    False -> None
  }
}

// ---------------------------------------------------------------------------
// Our own verification
// ---------------------------------------------------------------------------

/// What one verification came to.
type Outcome {
  Verified(claims: Claims, validation: trust.Validation)
  /// The peer got something wrong: `TN-Validation-Failed`.
  Refused(key: String, why: String)
  /// This node could not do its part: `No-TN-Validation`, and an error
  /// line, since something here is not working.
  Unverifiable(key: String, why: String)
  /// There was nothing to decide on: `No-TN-Validation`, counted and
  /// said once a minute, never alerted. Neither the peer's fault nor an
  /// outage -- a call with no caller number to match is just a call.
  Inconclusive(key: String, why: String)
}

fn own_or_nothing(
  kz: Kazoo,
  transport: Transport,
  config: Settings,
  facts: Facts,
) -> Verdict {
  case facts.identity {
    None -> nothing(False, None)
    Some(value) -> {
      let now = kz.now()
      let outcome =
        bounded(
          fn() { check(kz, transport, config, facts, value, now) },
          config.verify_timeout_ms + deadline_allowance_ms,
        )
      case outcome {
        Verified(claims, validation) ->
          Verdict(
            verstat: Passed,
            attest: Some(claims.attest),
            origid: Some(claims.origid),
            identity_present: True,
            source: "kazoo",
            revocation: case validation.revocation_checked {
              True -> "checked"
              False -> "unchecked"
            },
            reason: None,
          )
        Refused(key, why) -> {
          note(kz, key, why, now)
          Verdict(
            verstat: Failed,
            attest: None,
            origid: None,
            identity_present: True,
            source: "kazoo",
            revocation: "n/a",
            reason: Some(why),
          )
        }
        Unverifiable(key, why) -> {
          note(kz, key, why, now)
          unverified(why)
        }
        Inconclusive(key, why) -> {
          quiet(kz, key, why, now)
          unverified(why)
        }
      }
    }
  }
}

/// `No-TN-Validation` from a verification of ours that reached no
/// verdict, with the reason.
fn unverified(why: String) -> Verdict {
  Verdict(
    verstat: NoValidation,
    attest: None,
    origid: None,
    identity_present: True,
    source: "kazoo",
    revocation: "n/a",
    reason: Some(why),
  )
}

/// Run the verification in a process of its own and wait `deadline_ms`
/// for it. The worker is unlinked, so its death is not the caller's, and
/// monitored, so its death is noticed rather than waited out; one that
/// is still going at the deadline is killed, since whatever it is
/// waiting for, the call is not waiting for it. Whatever it may still
/// have sent is taken out of the mailbox before this returns.
fn bounded(work: fn() -> Outcome, deadline_ms: Int) -> Outcome {
  let reply = process.new_subject()
  let worker = process.spawn_unlinked(fn() { process.send(reply, work()) })
  let watch = process.monitor(worker)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
  let outcome = case process.selector_receive(selector, deadline_ms) {
    Ok(Ok(outcome)) -> outcome
    Ok(Error(Nil)) ->
      Unverifiable("crash", "the verification stopped before it answered")
    Error(Nil) -> {
      process.kill(worker)
      Unverifiable(
        "timeout",
        "the verification did not finish within "
          <> int.to_string(deadline_ms)
          <> " ms",
      )
    }
  }
  process.demonitor_process(watch)
  let _ = process.receive(reply, 0)
  outcome
}

fn check(
  kz: Kazoo,
  transport: Transport,
  config: Settings,
  facts: Facts,
  value: String,
  now: Int,
) -> Outcome {
  case passport.parse_identity(value) {
    Error(_malformed) ->
      Refused(
        "malformed",
        "the Identity header is not a PASSporT with an info parameter",
      )
    Ok(identity) ->
      case x5u.fetch(transport, identity.x5u, config.verify_timeout_ms) {
        Error(error) -> fetch_failed(error)
        Ok(pem) ->
          case passport.verify(identity, pem, now, config.identity_max_age_s) {
            Error(error) -> Refused(passport_key(error), passport_why(error))
            Ok(claims) ->
              case numbers_match(claims, facts) {
                Error(outcome) -> outcome
                Ok(Nil) ->
                  case trust.validate_chain_report(kz, pem, now) {
                    Ok(validation) -> Verified(claims, validation)
                    Error(why) ->
                      case string.starts_with(why, "no trust material") {
                        True -> Unverifiable("no-trust", why)
                        False ->
                          Refused(
                            "chain",
                            "the certificate does not chain to the trust list: "
                              <> why,
                          )
                      }
                  }
              }
          }
      }
  }
}

/// A fetch that failed because of what the peer pointed at is the peer's
/// failure; one that failed because the server could not be reached is
/// this node's, since the peer's certificate may be perfectly good.
fn fetch_failed(error: x5u.Error) -> Outcome {
  case error {
    x5u.BadUrl ->
      Refused("bad-x5u", "the x5u is not an https URL this node will fetch")
    x5u.NotACertificate(status) ->
      Refused(
        "not-a-certificate",
        "the x5u answered " <> int.to_string(status) <> " and no certificate",
      )
    x5u.TooLarge ->
      Refused("x5u-too-large", "the x5u answered more than a certificate")
    x5u.Fetch(http.Transport(why)) ->
      Unverifiable("fetch", "the certificate could not be fetched: " <> why)
    x5u.RecentlyFailed ->
      Unverifiable(
        "fetch",
        "the certificate could not be fetched a moment ago; not retried yet",
      )
  }
}

fn passport_key(error: passport.VerifyError) -> String {
  case error {
    passport.MalformedHeader -> "malformed"
    passport.Jws(jws.BadFormat) | passport.Jws(jws.BadEncoding) -> "malformed"
    passport.Jws(jws.UnsupportedAlg) -> "bad-alg"
    passport.Jws(jws.BadSignature) | passport.Jws(jws.SignerFailed(_)) ->
      "bad-signature"
    passport.NotShaken -> "not-shaken"
    passport.X5uMismatch -> "x5u-mismatch"
    passport.Stale(_) -> "stale"
    passport.MissingClaim(_) -> "missing-claim"
  }
}

fn passport_why(error: passport.VerifyError) -> String {
  case error {
    passport.MalformedHeader ->
      "the Identity header is not a PASSporT with an info parameter"
    passport.Jws(jws.BadFormat) | passport.Jws(jws.BadEncoding) ->
      "the PASSporT is not a compact JWS"
    passport.Jws(jws.UnsupportedAlg) -> "the PASSporT is not signed with ES256"
    passport.Jws(jws.BadSignature) | passport.Jws(jws.SignerFailed(_)) ->
      "the signature does not verify against the certificate the x5u serves"
    passport.NotShaken -> "the PASSporT is not a SHAKEN passport"
    passport.X5uMismatch ->
      "the x5u in the PASSporT and the info parameter disagree"
    passport.Stale(age_s) ->
      "the PASSporT's iat is " <> int.to_string(age_s) <> " s from now"
    passport.MissingClaim(claim) -> "the PASSporT has no usable " <> claim
  }
}

/// `orig.tn` against the caller number and `dest.tn` against the dialled
/// number. Both sides are read as digits, and a national NANP form
/// matches its own E.164 form.
///
/// A call with no caller number, or one that is not a number (an
/// anonymous caller), cannot pass: a PASSporT verifies that someone
/// signed for a number, and with no number on the call there is nothing
/// it says about this one. The verdict is `No-TN-Validation`, not a
/// failure -- nobody did anything wrong. The dialled number is different:
/// it is ours, and a call that does not carry one is compared against
/// nothing.
fn numbers_match(claims: Claims, facts: Facts) -> Result(Nil, Outcome) {
  use _ <- result.try(
    case option.then(facts.caller_number, passport.canonical_tn) {
      Some(caller) ->
        case same_number(claims.orig, caller) {
          True -> Ok(Nil)
          False ->
            Error(Refused(
              "orig-mismatch",
              "the PASSporT's orig "
                <> claims.orig
                <> " is not the call's caller "
                <> caller,
            ))
        }
      None -> Error(Inconclusive("no-caller", "no caller number to match"))
    },
  )
  case option.then(facts.dialed_number, passport.canonical_tn) {
    Some(dialed) ->
      case list.any(claims.dest, same_number(_, dialed)) {
        True -> Ok(Nil)
        False ->
          Error(Refused(
            "dest-mismatch",
            "the PASSporT's dest ["
              <> string.join(claims.dest, ", ")
              <> "] does not carry the dialled "
              <> dialed,
          ))
      }
    None -> Ok(Nil)
  }
}

fn same_number(claimed: String, carried: String) -> Bool {
  case passport.canonical_tn(claimed) {
    None -> False
    Some(claimed) ->
      claimed == carried
      || "1" <> claimed == carried
      || claimed == "1" <> carried
  }
}

// ---------------------------------------------------------------------------
// The CCVs
// ---------------------------------------------------------------------------

/// The CCV map for a verdict.
pub fn ccvs(verdict: Verdict) -> List(#(String, String)) {
  list.flatten([
    [
      #("STIR-Verstat", verstat_to_string(verdict.verstat)),
      #("STIR-Identity", case verdict.identity_present {
        True -> "present"
        False -> "absent"
      }),
      #("STIR-Verdict-Source", verdict.source),
      #("STIR-Revocation", verdict.revocation),
    ],
    optional("STIR-Attest", verdict.attest),
    optional("STIR-Orig-ID", verdict.origid),
    optional("STIR-Reason", verdict.reason),
  ])
}

fn optional(key: String, value: Option(String)) -> List(#(String, String)) {
  case value {
    Some(value) -> [#(key, value)]
    None -> []
  }
}

pub fn verstat_to_string(verstat: Verstat) -> String {
  case verstat {
    Passed -> "TN-Validation-Passed"
    Failed -> "TN-Validation-Failed"
    NoValidation -> "No-TN-Validation"
  }
}

/// The verstat a `STIR-Verstat` CCV carries; anything else is `Error`.
pub fn verstat_from_string(text: String) -> Result(Verstat, Nil) {
  case text {
    "TN-Validation-Passed" -> Ok(Passed)
    "TN-Validation-Failed" -> Ok(Failed)
    "No-TN-Validation" -> Ok(NoValidation)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Counting and alerting
// ---------------------------------------------------------------------------

/// A run of failures for one reason: when it started and how many since.
type Window {
  Window(since: Int, count: Int)
}

/// Count a failure, log it (once a minute per reason) and, above the
/// rate, alert. The alert is raised in a process of its own so the
/// call does not wait on the datastore write behind the throttle.
fn note(kz: Kazoo, key: String, why: String, now: Int) -> Nil {
  case cache.first_in(table, "log:" <> key, now, log_interval_s) {
    True -> system.log_error("inbound: " <> key <> ": " <> why)
    False -> Nil
  }
  let window = count(key, now)
  case window.count > failure_alert_count {
    False -> Nil
    True -> {
      let _ =
        process.spawn_unlinked(fn() {
          alert.raise(
            kz,
            "inbound:" <> key,
            "inbound verification keeps failing: " <> key,
            int.to_string(window.count)
              <> " inbound calls in five minutes on "
              <> system.node_name()
              <> " ended in "
              <> key
              <> "; the last one: "
              <> why,
            doc.object([
              #("reason", doc.String(key)),
              #("count", doc.Int(window.count)),
              #("node", doc.String(system.node_name())),
            ]),
            now,
            alert.hourly_interval_s,
          )
        })
      Nil
    }
  }
}

/// The same counting and the same throttle, at info level and with no
/// alert: a call this node took no verdict from because of how it
/// arrived or what it carried, which is a thing to be able to count and
/// not a thing to wake anyone for.
fn quiet(_kz: Kazoo, key: String, why: String, now: Int) -> Nil {
  case cache.first_in(table, "log:" <> key, now, log_interval_s) {
    True -> system.log("inbound: " <> key <> ": " <> why)
    False -> Nil
  }
  let _window = count(key, now)
  Nil
}

/// One more for the key inside the five-minute window, or a new window.
fn count(key: String, now: Int) -> Window {
  let window = case cache.get(table, "count:" <> key) {
    Ok(Window(since:, count:))
      if now - since < failure_window_s && now >= since
    -> Window(since:, count: count + 1)
    _ -> Window(since: now, count: 1)
  }
  cache.put(table, "count:" <> key, window)
  window
}

/// How many failures for a reason the current five-minute window holds.
pub fn failures(key: String) -> Int {
  case cache.get(table, "count:" <> key) {
    Ok(Window(count:, ..)) -> count
    Error(Nil) -> 0
  }
}

/// Forget the counters and the log throttle on this node.
pub fn reset() -> Nil {
  cache.clear(table)
}

/// A token, cut short for a log line.
fn preview(token: String) -> String {
  case bit_array.is_utf8(bit_array.from_string(token)) {
    True -> string.slice(token, 0, 80)
    False -> "<bytes>"
  }
}

@external(erlang, "stir_ffi", "master_account_id")
fn master_account_id() -> Result(String, Nil)

@external(erlang, "stir_inbound_ffi", "call_safely")
fn call_safely(work: fn() -> a) -> Result(a, String)

@external(erlang, "json", "decode")
fn to_erlang(json: String) -> Dynamic
