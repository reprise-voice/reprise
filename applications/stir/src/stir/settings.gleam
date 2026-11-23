//// `system_config/stir`, typed.
////
//// Every value has a default here and in the schema
//// (`applications/crossbar/priv/couchdb/schemas/system_config.stir.json`);
//// the two must agree. Booleans and numbers are read as strings first
//// because `sup kapps_config set_default` stores whatever it was given.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import stir/system

/// What the attestation policy answers for one kind of call: `A`, `B`, `C`,
/// or `passthru` for a forwarded call that keeps the original `Identity`.
pub type Attestation {
  A
  B
  C
  Passthru
}

pub type VerifyMode {
  /// Verify before the callflow starts, within `verify_timeout_ms`.
  Sync
  /// Start the callflow; the verdict lands on the channel when ready.
  Async
}

pub type Settings {
  Settings(
    sign_enabled: Bool,
    verify_enabled: Bool,
    verify_mode: VerifyMode,
    verify_timeout_ms: Int,
    trust_upstream_verstat: Bool,
    attest_owned_number: Attestation,
    /// `account` or `tree`: whether a number assigned to an ancestor counts
    /// as owned. The ancestor walk leaves out the master account, which is
    /// every account's ancestor.
    attest_owned_scope: String,
    /// The level for a leg that forwards an inbound call with its caller
    /// id kept, B by default. The caller's number is not ours: ATIS-1000074
    /// gives A only to a provider with a verified association with the
    /// number, which a forward does not give us, so A here is an
    /// operator's choice and not the default. Whatever is set, a forward
    /// is never signed above the level the inbound call itself carried
    /// (`stir/attest`), and the forward markers alone are a claim a device
    /// can make, so `stir/attest` also wants the inbound hook's own record
    /// that the call came from a carrier and that its caller is the number
    /// being signed. `passthru` carries the inbound call's own Identity.
    attest_forwarded: Attestation,
    /// The same when that inbound call's Identity failed verification;
    /// an inbound call nobody validated takes `attest_unverified`, not
    /// this.
    attest_forwarded_when_inbound_failed: Attestation,
    /// B by default: how an external number comes to be verified is
    /// outside this application, and some of the ways (an IVR call that
    /// plays text the requester chose, `gather_external_numbers`) do not
    /// show that the account holds the number. An operator who trusts
    /// the platform's verification can raise it to A.
    attest_verified_external_number: Attestation,
    attest_transit: Attestation,
    attest_unverified: Attestation,
    sign_anonymous: Bool,
    sign_non_nanp_origin: Bool,
    /// The prefix of every new key's `x5u`; empty derives it from the API
    /// domain at key creation.
    x5u_base_url: String,
    /// The `O` of every CSR a key is created with: the legal name of the
    /// service provider the certificate is for. No default; a key cannot be
    /// created while it is empty, unless the API request names one.
    csr_organization: String,
    identity_max_age_s: Int,
    require_date_header: Bool,
    cid_name_prefix_failed: String,
    allow_account_keys: Bool,
    renewal_enabled: Bool,
    renewal_window_days: Int,
    acme_directory_url: String,
    stipa_api_url: String,
    /// How often the trust material is refreshed; the CRL lives 24 hours,
    /// so this stays well below that.
    trust_refresh_hours: Int,
    /// Days before `not_after` at which an expiry alert is raised.
    alert_days: List(Int),
  )
}

pub const default_stipa_api_url = "https://authenticate-api.iconectiv.com"

pub fn load(kz: Kazoo) -> Settings {
  Settings(
    sign_enabled: bool(kz, "sign_enabled", False),
    verify_enabled: bool(kz, "verify_enabled", False),
    verify_mode: case kz.config.get_string("verify_mode", "sync") {
      "async" -> Async
      "sync" | "" -> Sync
      other -> {
        system.log_error(
          "settings: verify_mode "
          <> other
          <> " is not sync or async; using sync",
        )
        Sync
      }
    },
    verify_timeout_ms: integer(kz, "verify_timeout_ms", 1500),
    trust_upstream_verstat: bool(kz, "trust_upstream_verstat", True),
    attest_owned_number: attestation(kz, "attest_owned_number", A),
    attest_owned_scope: case kz.config.get_string("attest_owned_scope", "") {
      "tree" -> "tree"
      _ -> "account"
    },
    attest_forwarded: attestation(kz, "attest_forwarded", B),
    attest_forwarded_when_inbound_failed: attestation(
      kz,
      "attest_forwarded_when_inbound_failed",
      B,
    ),
    attest_verified_external_number: attestation(
      kz,
      "attest_verified_external_number",
      B,
    ),
    attest_transit: attestation(kz, "attest_transit", C),
    attest_unverified: attestation(kz, "attest_unverified", B),
    sign_anonymous: bool(kz, "sign_anonymous", True),
    sign_non_nanp_origin: bool(kz, "sign_non_nanp_origin", False),
    x5u_base_url: kz.config.get_string("x5u_base_url", ""),
    csr_organization: string.trim(kz.config.get_string("csr_organization", "")),
    identity_max_age_s: integer(kz, "identity_max_age_s", 60),
    require_date_header: bool(kz, "require_date_header", False),
    cid_name_prefix_failed: kz.config.get_string("cid_name_prefix_failed", ""),
    allow_account_keys: bool(kz, "allow_account_keys", False),
    renewal_enabled: bool(kz, "renewal_enabled", False),
    renewal_window_days: integer(kz, "renewal_window_days", 30),
    acme_directory_url: kz.config.get_string("acme_directory_url", ""),
    stipa_api_url: kz.config.get_string("stipa_api_url", default_stipa_api_url),
    trust_refresh_hours: integer(kz, "trust_refresh_hours", 6),
    alert_days: integers(kz, "alert_days", [60, 30, 14]),
  )
}

pub fn attestation_to_string(attestation: Attestation) -> String {
  case attestation {
    A -> "A"
    B -> "B"
    C -> "C"
    Passthru -> "passthru"
  }
}

pub fn attestation_from_string(text: String) -> Result(Attestation, Nil) {
  case string.uppercase(text) {
    "A" -> Ok(A)
    "B" -> Ok(B)
    "C" -> Ok(C)
    "PASSTHRU" -> Ok(Passthru)
    _ -> Error(Nil)
  }
}

/// `passthru` is a way to forward, not a way to attest, so only the two
/// forwarded settings accept it; anywhere else it is the default.
fn attestation(kz: Kazoo, key: String, default: Attestation) -> Attestation {
  let forwarded =
    key == "attest_forwarded" || key == "attest_forwarded_when_inbound_failed"
  case attestation_from_string(kz.config.get_string(key, "")) {
    Ok(Passthru) if !forwarded -> {
      system.log_error(
        "settings: " <> key <> " cannot be passthru; using the default",
      )
      default
    }
    Ok(value) -> value
    Error(Nil) -> default
  }
}

fn bool(kz: Kazoo, key: String, default: Bool) -> Bool {
  case string.lowercase(kz.config.get_string(key, "")) {
    "true" -> True
    "false" -> False
    _ -> default
  }
}

/// A non-negative integer; anything else (a negative, a word) is the
/// default, with a log line, because a wrong number here silently changes
/// what is verified or when an alert fires.
fn integer(kz: Kazoo, key: String, default: Int) -> Int {
  let raw = case int.parse(kz.config.get_string(key, "")) {
    Ok(n) -> n
    Error(Nil) -> kz.config.get_int(key, default)
  }
  case raw >= 0 {
    True -> raw
    False -> {
      system.log_error(
        "settings: "
        <> key
        <> " is negative; using the default "
        <> int.to_string(default),
      )
      default
    }
  }
}

/// A list of non-negative integers, stored either as a JSON array or as the
/// comma-separated string `sup kapps_config set_default` leaves behind.
/// A value that is present but unreadable is the default, with a log line.
fn integers(kz: Kazoo, key: String, default: List(Int)) -> List(Int) {
  let from_json = case kz.config.get_json(key) {
    Ok(doc.List(items)) ->
      list.try_map(items, fn(item) {
        case item {
          doc.Int(n) if n >= 0 -> Ok(n)
          doc.String(text) ->
            case int.parse(string.trim(text)) {
              Ok(n) if n >= 0 -> Ok(n)
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> result.map(Some)
    _ -> Ok(None)
  }
  case from_json {
    Ok(Some(values)) -> values
    _ ->
      case kz.config.get_string(key, "") {
        "" -> default
        text ->
          case
            string.split(text, ",")
            |> list.map(string.trim)
            |> list.try_map(fn(part) {
              case int.parse(part) {
                Ok(n) if n >= 0 -> Ok(n)
                _ -> Error(Nil)
              }
            })
          {
            Ok(values) -> values
            Error(Nil) -> {
              system.log_error(
                "settings: "
                <> key
                <> " is not a list of numbers; using the default",
              )
              default
            }
          }
      }
  }
}
