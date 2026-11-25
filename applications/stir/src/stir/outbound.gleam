//// The outbound entry point: what `stepswitch` calls, once per offnet
//// request, when it builds carrier legs.
////
//// Erlang calls `'stir@outbound':headers(Facts)` with a map of binaries
//// (the keys below) and pattern-matches `{ok, Answer}` or `{error, Reason}`.
//// The rule that governs everything here: **a failure leaves the leg
//// unsigned and the call proceeds.** No path raises; every `Error` is a
//// log line, a counter, and, above a rate, an alert. The budget is
//// `budget_ms`; the signer is asked with that timeout.
////
//// Called once per offnet request from `stepswitch_resources:endpoints/2`,
//// before the per-gateway fold, and merged into every gateway endpoint
//// whose resource has not opted out (`Stir-Sign` CCV). Emergency legs are
//// not signed in this release: their caller id is decided after this
//// point (`stepswitch_bridge`), so the signed number could differ.
////
//// Facts map keys (binaries; absent means unknown):
////   "account_id", "orig_number" (the offnet request's outbound caller id
////   number), "dest_number" (the E.164 destination), any format,
////   canonicalised here; "inception" (Kazoo's route-string `Inception`,
////   `<user>@<realm>`, or the token "offnet"), "call_forward"
////   ("true"|"false"), "retain_cid", "privacy_hide_number", "emergency",
////   "inbound_carrier" ("true" when the call this leg forwards was an
////   inbound carrier call), "inbound_caller" (that call's caller, digits),
////   "inbound_verstat" (the inbound leg's STIR-Verstat CCV),
////   "inbound_attest" (its STIR-Attest CCV),
////   "inbound_identity" (the inbound Identity header value, for
////   passthrough), "budget_ms", "resource_id", "resource_sign" (the
////   resource's own opt-out, "false" to leave its legs alone).
////
//// The three `inbound_*` facts come from the `STIR-*` channel variables
//// the inbound hook wrote (`STIR-Inbound-Carrier`, `STIR-Inbound-Caller`,
//// `STIR-Verstat`), and that hook is the only writer of them: it clears
//// them on every call it sees first, so a device cannot hand itself a
//// forward's credentials through `X-ecallmgr_*` headers. What they are
//// for is §3.5's rule 2; `stir/attest` says what they have to add up to.
////
//// Answer: from Erlang a map with "Identity" => header value,
////   "Custom-Channel-Vars" => map, and "Exclude-Outgoing-Extra-Header" =>
////   "^sip_h_[Ii]dentity$". Passthrough has the same shape, with the
////   inbound call's own Identity value as the header and
////   "STIR-Attest" => "passthru" in the channel variables: FreeSWITCH
////   1.11.4 has nothing behind `sip_identity_passthru`, so carrying the
////   header through means answering it here for Erlang to place.
////
//// What is a failure and what is not. Signing turned off, a resource
//// that opted out, a leg the policy skips (emergency, anonymous, a
//// number outside NANP) and a request with no number to sign are
//// `Unsigned` and nothing more: that is the configuration doing what it
//// says. A key store that cannot be read, a scope with no active key, a
//// signer that refuses or does not answer, a request with no account and
//// a crash are `Unsigned` too -- the call proceeds either way -- but each
//// is an error line (once a minute per reason), a count, and, past ten of
//// one reason in five minutes, an alert once an hour.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/cache
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import stir/alert
import stir/attest
import stir/jws
import stir/key
import stir/keys
import stir/numbers
import stir/passport
import stir/settings.{type Settings}
import stir/signer
import stir/system

pub const budget_ms = 500

/// The FreeSWITCH variable that keeps a header the leg already carries
/// from being sent again beside the one set here.
pub const exclude_pattern = "^sip_h_[Ii]dentity$"

/// Failed signings per reason inside the last five minutes.
const failures_table = "stir_outbound"

/// The throttle on the error line: once a minute per reason.
const log_throttle = "stir_outbound_log"

const log_interval_s = 60

/// How many failures of one reason inside `failure_window_s` are an alert.
const failure_alert_count = 10

const failure_window_s = 300

const alert_interval_s = 3600

pub type Answer {
  /// Sign: the header, and the channel variables that record it.
  Signed(
    identity: String,
    kid: String,
    attest: String,
    origid: String,
    /// The FreeSWITCH variable that keeps the header from going out twice.
    exclude: String,
  )
  /// Carry the inbound call's Identity through: this is its value, to be
  /// placed as the outbound `Identity` header unchanged.
  Passthrough(identity: String, exclude: String)
  /// Nothing to add, with the reason (not an error: disabled, skipped by
  /// policy, no key for the scope).
  Unsigned(reason: String)
}

/// The Erlang entry point. Never raises.
///
/// The decision runs under `stir_ffi:call_safely/1`, so whatever raises
/// inside it -- a fact of a shape nothing here expected, a datastore
/// binding that threw -- is `{error, <<"crash">>}` to `stepswitch` and a
/// counted failure here, not an exit in the process building the call.
pub fn headers(facts: Dynamic) -> Result(Dynamic, String) {
  headers_with(system.live(), facts)
}

/// The same over a given `Kazoo`, for a test that wants the Erlang shape
/// of an answer over the fake.
pub fn headers_with(kz: Kazoo, facts: Dynamic) -> Result(Dynamic, String) {
  let answer = case
    call_safely(fn() {
      decide_within(kz, facts_from(facts), budget_from(facts))
    })
  {
    Ok(answer) -> answer
    Error(reason) ->
      case call_safely(fn() { failed(kz, reason) }) {
        Ok(answer) -> answer
        Error(_) -> Unsigned(reason)
      }
  }
  case answer {
    Signed(identity:, kid:, attest:, origid:, exclude:) ->
      Ok(
        to_map(
          doc.to_string(
            doc.object([
              #("Identity", doc.String(identity)),
              #("Exclude-Outgoing-Extra-Header", doc.String(exclude)),
              #(
                "Custom-Channel-Vars",
                doc.object([
                  #("STIR-Attest", doc.String(attest)),
                  #("STIR-Orig-ID", doc.String(origid)),
                  #("STIR-Key-ID", doc.String(kid)),
                ]),
              ),
            ]),
          ),
        ),
      )
    Passthrough(identity:, exclude:) ->
      Ok(
        to_map(
          doc.to_string(
            doc.object([
              #("Identity", doc.String(identity)),
              #("Exclude-Outgoing-Extra-Header", doc.String(exclude)),
              #(
                "Custom-Channel-Vars",
                doc.object([#("STIR-Attest", doc.String("passthru"))]),
              ),
            ]),
          ),
        ),
      )
    Unsigned(reason) -> Error(reason)
  }
}

/// The same over typed facts, for tests and for `sup`.
pub fn decide(kz: Kazoo, facts: Facts) -> Answer {
  decide_within(kz, facts, budget_ms)
}

pub type Facts {
  Facts(
    account_id: String,
    orig_number: String,
    dest_number: String,
    resource_id: Option(String),
    inception_offnet: Bool,
    call_forward: Bool,
    retain_cid: Bool,
    privacy_hide_number: Bool,
    emergency: Bool,
    /// The call this leg forwards was an inbound carrier call, as the
    /// inbound hook recorded it.
    inbound_carrier: Bool,
    /// That call's caller, as the inbound hook recorded it.
    inbound_caller: Option(String),
    inbound_verstat: Option(String),
    /// That call's `STIR-Attest`, as the inbound hook recorded it.
    inbound_attest: Option(String),
    inbound_identity: Option(String),
    resource_sign: Option(Bool),
  )
}

/// The facts from the map `stepswitch` sends. Every value is a binary;
/// one that is absent is unknown, and an unknown flag is off. A map that
/// is not one at all is a request with no account, which `decide` turns
/// away as such.
pub fn facts_from(facts: Dynamic) -> Facts {
  let map = doc.from_dynamic(facts)
  let text = fn(name) {
    case doc.get_string(map, [name]) {
      Ok("") -> None
      Ok(value) -> Some(value)
      Error(Nil) -> None
    }
  }
  let flag = fn(name) {
    case text(name) {
      Some(value) -> string.lowercase(value) == "true"
      None -> False
    }
  }
  Facts(
    account_id: text("account_id") |> option.unwrap(""),
    orig_number: text("orig_number") |> option.unwrap(""),
    dest_number: text("dest_number") |> option.unwrap(""),
    resource_id: text("resource_id"),
    inception_offnet: case text("inception") {
      // The Erlang side sends the token, or leaves the key out. Kazoo's
      // own route-string `Inception` is `<user>@<realm>`, so a value that
      // carries an `@` is one that was passed on unmapped, and a call
      // that came in from somewhere is what it means either way.
      Some(value) ->
        string.lowercase(value) == "offnet" || string.contains(value, "@")
      None -> False
    },
    call_forward: flag("call_forward"),
    retain_cid: flag("retain_cid"),
    privacy_hide_number: flag("privacy_hide_number"),
    emergency: flag("emergency"),
    inbound_carrier: flag("inbound_carrier"),
    inbound_caller: text("inbound_caller"),
    inbound_verstat: text("inbound_verstat"),
    inbound_attest: text("inbound_attest"),
    inbound_identity: text("inbound_identity"),
    resource_sign: case text("resource_sign") {
      Some(value) -> Some(string.lowercase(value) == "true")
      None -> None
    },
  )
}

/// The budget the request names, when it names a sensible one; else
/// `budget_ms`.
fn budget_from(facts: Dynamic) -> Int {
  let map = doc.from_dynamic(facts)
  let named = case doc.get_int(map, ["budget_ms"]) {
    Ok(ms) -> Ok(ms)
    Error(Nil) ->
      case doc.get_string(map, ["budget_ms"]) {
        Ok(text) -> int.parse(text)
        Error(Nil) -> Error(Nil)
      }
  }
  case named {
    Ok(ms) if ms > 0 -> ms
    _ -> budget_ms
  }
}

fn decide_within(kz: Kazoo, facts: Facts, budget: Int) -> Answer {
  let config = settings.load(kz)
  case config.sign_enabled, facts.resource_sign {
    False, _ -> Unsigned("signing disabled")
    True, Some(False) -> Unsigned("resource opted out")
    True, _ ->
      case facts.account_id {
        "" -> failed(kz, "no account id")
        _ ->
          case
            passport.canonical_tn(facts.orig_number),
            passport.canonical_tn(facts.dest_number)
          {
            None, _ -> Unsigned("no orig number")
            _, None -> Unsigned("no dest number")
            Some(orig), Some(dest) ->
              attested(kz, config, facts, orig, dest, budget)
          }
      }
  }
}

/// The ownership facts, the policy, and then the signature.
fn attested(
  kz: Kazoo,
  config: Settings,
  facts: Facts,
  orig: String,
  dest: String,
  budget: Int,
) -> Answer {
  let #(by_account, by_ancestor) =
    numbers.owned(kz, facts.account_id, orig, config.attest_owned_scope)
  // The view is not asked about a number the number manager already
  // answered for: rule 1 decides before rule 3 is reached.
  let verified = case by_account || by_ancestor {
    True -> False
    False -> numbers.verified_external(kz, facts.account_id, orig)
  }
  let decision =
    attest.decide(
      attest.Facts(
        account_id: facts.account_id,
        orig_tn: orig,
        dest_tn: dest,
        owned_by_account: by_account,
        owned_by_ancestor: by_ancestor,
        verified_external: verified,
        inception_offnet: facts.inception_offnet,
        forwarded_with_caller_id: facts.call_forward && facts.retain_cid,
        inbound_carrier: facts.inbound_carrier,
        inbound_caller: option.unwrap(
          option.then(facts.inbound_caller, passport.canonical_tn),
          "",
        ),
        inbound_verdict: verdict(facts.inbound_verstat),
        inbound_attest: inbound_level(
          facts.inbound_attest,
          facts.inbound_verstat,
        ),
        anonymous: facts.privacy_hide_number,
        emergency: facts.emergency,
      ),
      config,
    )
  case decision {
    attest.Skip(reason) -> Unsigned(reason)
    attest.Sign(level) -> sign(kz, facts.account_id, orig, dest, level, budget)
    // Carrying the inbound header through needs the header, and needs
    // the header to be worth carrying: an Identity nobody verified, or
    // one that arrived on a call the SBC did not call a carrier's, is
    // passed on as a claim we would be seen to endorse. Either way the
    // leg is signed as transit instead.
    attest.Passthru ->
      case
        facts.inbound_identity,
        facts.inbound_carrier,
        verdict(facts.inbound_verstat)
      {
        Some(identity), True, Some(attest.Passed) ->
          Passthrough(identity:, exclude: exclude_pattern)
        _, _, _ ->
          sign(kz, facts.account_id, orig, dest, config.attest_transit, budget)
      }
  }
}

/// The inbound leg's verdict from its `STIR-Verstat` CCV: the three
/// values of §3.5a, with a carrier's `-B`/`-C` suffix on a pass.
fn verdict(verstat: Option(String)) -> Option(attest.InboundVerdict) {
  case option.map(verstat, string.lowercase) {
    Some("tn-validation-failed") -> Some(attest.Failed)
    Some("no-tn-validation") -> Some(attest.NoValidation)
    Some(value) ->
      case string.starts_with(value, "tn-validation-passed") {
        True -> Some(attest.Passed)
        False -> None
      }
    None -> None
  }
}

/// The level the inbound call carried: its `STIR-Attest`, and the
/// `-B`/`-C` suffix of its verstat, whichever is lower when both say;
/// `None` when neither does, which `stir/attest` takes as C.
fn inbound_level(
  attest: Option(String),
  verstat: Option(String),
) -> Option(settings.Attestation) {
  let from_attest = case option.map(attest, settings.attestation_from_string) {
    Some(Ok(settings.Passthru)) -> None
    Some(Ok(level)) -> Some(level)
    _ -> None
  }
  let from_verstat = case option.map(verstat, string.lowercase) {
    Some("tn-validation-passed-b") -> Some(settings.B)
    Some("tn-validation-passed-c") -> Some(settings.C)
    _ -> None
  }
  case from_attest, from_verstat {
    Some(one), Some(other) -> Some(attest.lowest(one, other))
    Some(one), None -> Some(one)
    None, other -> other
  }
}

fn sign(
  kz: Kazoo,
  account_id: String,
  orig: String,
  dest: String,
  level: settings.Attestation,
  budget: Int,
) -> Answer {
  case keys.select(kz, account_id) {
    Error(error) -> failed(kz, "key store: " <> store_reason(error))
    Ok(None) -> failed(kz, "no key for scope")
    Ok(Some(found)) ->
      case found.status {
        key.Active -> {
          let attest = settings.attestation_to_string(level)
          let origid = uuid()
          let claims =
            passport.Claims(
              attest:,
              dest: [dest],
              iat: kz.now(),
              orig:,
              origid:,
            )
          case
            passport.build(
              claims,
              found.x5u,
              signer.for_key_within(found.kid, budget),
            )
          {
            Ok(identity) ->
              Signed(
                identity:,
                kid: found.kid,
                attest:,
                origid:,
                exclude: exclude_pattern,
              )
            Error(error) -> failed(kz, "signer: " <> sign_reason(error))
          }
        }
        _ -> failed(kz, "no key for scope")
      }
  }
}

/// A leg left unsigned by something going wrong: an error line once a
/// minute per reason, one more in the five-minute count for the reason,
/// and past `failure_alert_count` of them an alert, raised off the call
/// path and once an hour.
fn failed(kz: Kazoo, reason: String) -> Answer {
  let now = kz.now()
  case cache.first_in(log_throttle, reason, now, log_interval_s) {
    False -> Nil
    True ->
      system.log_error(
        "outbound: a call goes out unsigned: "
        <> reason
        <> " (this line is written at most once a minute per reason)",
      )
  }
  let count = case cache.get(failures_table, reason) {
    Ok(#(since, count)) if now - since < failure_window_s -> {
      cache.put(failures_table, reason, #(since, count + 1))
      count + 1
    }
    _ -> {
      cache.put(failures_table, reason, #(now, 1))
      1
    }
  }
  case count > failure_alert_count {
    False -> Nil
    True -> {
      let _ =
        process.spawn_unlinked(fn() {
          alert.raise(
            kz,
            "outbound:" <> reason,
            "outbound calls are going out unsigned",
            system.node_name()
              <> " could not sign "
              <> int.to_string(count)
              <> " outbound calls in five minutes: "
              <> reason
              <> ". The calls proceed without an Identity header.",
            doc.object([
              #("reason", doc.String(reason)),
              #("count", doc.Int(count)),
              #("node", doc.String(system.node_name())),
            ]),
            now,
            alert_interval_s,
          )
        })
      Nil
    }
  }
  Unsigned(reason)
}

/// How many failures of `reason` this node has counted inside the
/// window, for a test and for `status`.
pub fn failures(kz: Kazoo, reason: String) -> Int {
  let now = kz.now()
  case cache.get(failures_table, reason) {
    Ok(#(since, count)) if now - since < failure_window_s -> count
    _ -> 0
  }
}

/// Forget the counts and the log throttle on this node, for a test.
pub fn forget_failures() -> Nil {
  cache.clear(failures_table)
  cache.clear(log_throttle)
}

fn store_reason(error: keys.Error) -> String {
  case error {
    keys.Datastore(why) -> kazoo.error_to_string(why)
    keys.NotFound -> "not found"
    keys.NoVault -> "no key-encryption key"
    keys.Unsealable -> "unsealable"
    keys.Damaged -> "damaged"
    keys.NoPrivateKey -> "no private key"
    keys.CertificateMismatch(why) -> why
    keys.InvalidTransition -> "invalid transition"
    keys.ViewMissing -> "view missing"
    keys.Conflict -> "conflict"
    keys.Crypto(why) -> why
  }
}

fn sign_reason(error: jws.Error) -> String {
  case error {
    jws.SignerFailed(why) -> why
    jws.BadFormat -> "bad format"
    jws.UnsupportedAlg -> "unsupported algorithm"
    jws.BadEncoding -> "bad encoding"
    jws.BadSignature -> "bad signature"
  }
}

@external(erlang, "stir_ffi", "call_safely")
fn call_safely(run: fn() -> a) -> Result(a, String)

@external(erlang, "stir_ffi", "to_map")
fn to_map(json: String) -> Dynamic

@external(erlang, "stir_ffi", "uuid")
fn uuid() -> String
