//// Raising a Kazoo alert about this application.
////
//// Alerts are what an administration UI lists through Crossbar's alerts
//// API, so this is how an operator hears about a certificate near its
//// end, a key that cannot be opened, a signer that keeps crashing, or a
//// trust list the STI-PA refused, without reading a node's log. Every
//// alert is addressed to the master account (platform operators) and, when
//// it concerns a reseller's own key, to that account as well.
////
//// Throttled by a dedupe key so a condition that persists raises once per
//// `interval_s` and not once per pass, per call or per node restart. The
//// throttle consumes its slot only when the alert was actually recorded, so
//// a datastore blip does not swallow the day's one chance.
////
//// **The throttle is the cluster's, not the node's.** Every node runs the
//// same monitor pass and every node verifies the same calls, so a
//// node-local throttle meant one alert per condition *per node*: a
//// three-node cluster filed three of everything, and a rolling restart
//// filed them again. The last-raised time of each dedupe key is a field on
//// one document, `alerts` in the `stir` database, read and written with the
//// revision it was read under so two nodes raising at once make a conflict
//// rather than two alerts. A node-local table in front of it keeps the
//// read off the datastore for a condition this node has already seen
//// inside the interval -- verification runs per call -- and is what the
//// throttle falls back to when the datastore cannot be reached at all.
////
//// The cluster's `alerts` must be enabled (`system_config/alerts.enabled`,
//// the default) for anything to be recorded; `kapps_alert` drops them
//// otherwise and `raised` answers `Discarded`.

import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/alerts
import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import stir/key.{type Scope}
import stir/system

/// What happened to an alert this application tried to raise.
pub type Outcome {
  /// Recorded for the master account (and the scope's account when given).
  Raised
  /// The same dedupe key was raised inside `interval_s` already.
  Throttled
  /// No master account could be found, or the datastore refused; logged
  /// at error level instead.
  Discarded
}

pub const default_interval_s = 86_400

pub const hourly_interval_s = 3600

/// The document every node's throttle is kept in, in the `stir` database.
pub const throttle_id = "alerts"

const throttle_table = "stir_alerts"

/// How many times a conflicting claim is read again and re-applied.
const attempts = 3

/// Raise an alert, once per `dedupe` per `interval_s`. `now` is unix seconds.
pub fn raise(
  kz: Kazoo,
  dedupe: String,
  title: String,
  message: String,
  metadata: Value,
  now: Int,
  interval_s: Int,
) -> Outcome {
  raise_for(kz, None, dedupe, title, message, metadata, now, interval_s)
}

/// The same, also addressed to the account a reseller-scoped key belongs
/// to, so the reseller's own admins see it.
pub fn raise_for(
  kz: Kazoo,
  scope: Option(Scope),
  dedupe: String,
  title: String,
  message: String,
  metadata: Value,
  now: Int,
  interval_s: Int,
) -> Outcome {
  // The master account first: without one nothing can be recorded, and a
  // throttle slot must not be spent on an alert nobody will read.
  case master_account_id() {
    Error(Nil) -> {
      system.log_error(
        "alert not raised (no master account): " <> title <> ": " <> message,
      )
      Discarded
    }
    Ok(master) ->
      case claim(kz, dedupe, now, interval_s) {
        False -> Throttled
        True -> {
          let full_title = "STIR/SHAKEN: " <> title
          alerts.about_account(kz, master, full_title, message, metadata)
          case scope {
            Some(key.Account(account_id)) if account_id != master ->
              alerts.about_account(
                kz,
                account_id,
                full_title,
                message,
                metadata,
              )
            _ -> Nil
          }
          system.log("alert raised: " <> title <> ": " <> message)
          Raised
        }
      }
  }
}

/// Forget a throttle on this node, so the next `raise` with this dedupe
/// asks the cluster's document again: what a test, or an operator's `sup`
/// command, wants. `reset_for` forgets the cluster's record too.
pub fn reset(dedupe: String) -> Nil {
  cache.delete(throttle_table, dedupe)
}

/// The same, and the field on the `alerts` document with it, so the next
/// `raise` anywhere on the cluster goes through.
pub fn reset_for(kz: Kazoo, dedupe: String) -> Nil {
  reset(dedupe)
  case kz.datamgr.open_doc(system.category, throttle_id) {
    Error(_why) -> Nil
    Ok(document) -> {
      let _ =
        kz.datamgr.save_doc(
          system.category,
          doc.delete(document, ["raised", field(dedupe)]),
        )
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// The throttle
// ---------------------------------------------------------------------------

/// Whether this caller is the one that gets to raise `dedupe` in this
/// interval, cluster-wide, taking the slot if it is. The node's own
/// table answers first, both to keep a per-call path off the datastore
/// and as the fallback when the datastore is not there; the document is
/// what makes it one alert for the cluster rather than one per node.
///
/// Public so that a caller with an alert of its own to file -- and a
/// test -- can ask for the slot without going through `raise`.
pub fn claim(kz: Kazoo, dedupe: String, now: Int, interval_s: Int) -> Bool {
  case cache.first_in(throttle_table, dedupe, now, interval_s) {
    False -> False
    True ->
      case claim_in_cluster(kz, dedupe, now, interval_s, attempts) {
        // The local slot is spent either way: a node that lost the race
        // for the document should not ask again until the interval is up.
        Claimed -> True
        Taken -> False
        // Nothing to claim it in. The node's own table is the throttle,
        // which is what this application did before there was a document.
        Unreachable -> True
      }
  }
}

type Claim {
  Claimed
  Taken
  Unreachable
}

fn claim_in_cluster(
  kz: Kazoo,
  dedupe: String,
  now: Int,
  interval_s: Int,
  attempts: Int,
) -> Claim {
  case attempts <= 0 {
    True -> Unreachable
    False -> {
      let existing = case kz.datamgr.open_doc(system.category, throttle_id) {
        Ok(document) -> Ok(document)
        Error(kazoo.NotFound) ->
          Ok(
            doc.object([
              #("_id", doc.String(throttle_id)),
              #("pvt_type", doc.String("stir_alerts")),
            ]),
          )
        Error(error) -> Error(error)
      }
      case existing {
        Error(_error) -> Unreachable
        Ok(document) ->
          case doc.get_int(document, ["raised", field(dedupe)]) {
            Ok(last) if now - last < interval_s && now >= last -> Taken
            _ ->
              case
                kz.datamgr.save_doc(
                  system.category,
                  doc.set(document, ["raised", field(dedupe)], doc.Int(now)),
                )
              {
                Ok(_saved) -> Claimed
                // Another node wrote the document in between: read it
                // again, which is where its claim will be seen.
                Error(kazoo.Conflict) ->
                  claim_in_cluster(kz, dedupe, now, interval_s, attempts - 1)
                Error(_error) -> Unreachable
              }
          }
      }
    }
  }
}

/// The document member a dedupe key is kept under. A key holds a kid, a
/// scope or a reason and can carry a `:`, which `kazoo/doc` reads as
/// nothing in particular but which is not a character a JSON key wants;
/// the dots are what `doc.get_int` would split a path on, so the name is
/// one member of one object and the path is spelled out here.
fn field(dedupe: String) -> String {
  string.replace(dedupe, ":", "-")
}

/// What the throttle answers a caller that wants to log it.
pub fn describe(outcome: Outcome, what: String) -> String {
  case outcome {
    Raised -> "alerted: " <> what
    Throttled -> "already alerted: " <> what
    Discarded -> "no master account to alert: " <> what
  }
}

@external(erlang, "stir_ffi", "master_account_id")
fn master_account_id() -> Result(String, Nil)
