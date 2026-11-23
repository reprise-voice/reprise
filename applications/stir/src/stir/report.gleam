//// What the `sup` commands print, as functions of their arguments.
////
//// `sup` calls a module by name with binary arguments, so every public
//// function of `stir_maintenance` is a command an operator can call with
//// whatever they like in it. What the commands print is worked out here
//// instead: these take the types they mean -- a `Key`, a `Stats`, a
//// `Settings` -- so `sup` cannot reach them, and a test can.
////
//// Nothing here reads the datastore, the environment or the clock, and
//// nothing here can print a key: the only values it is given are metadata.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/kazoo
import kazoo/modb
import stir/key.{type Key}
import stir/keys
import stir/monitor
import stir/passport
import stir/settings.{type Settings}
import stir/signer
import stir/system
import stir/trust

/// One line per scope: the active key and how long it has left, and how
/// many keys are in each other status. A scope with more than one active
/// key -- two nodes that activated at the same moment, or a retirement
/// that failed -- gets a warning line of its own, because one of those
/// certificates is being served for calls nothing signs with it.
pub fn scope_lines(all: List(Key), now: Int) -> List(String) {
  list.flat_map(scope_names(all), fn(name) {
    let members =
      list.filter(all, fn(k) { key.scope_to_string(k.scope) == name })
    let actives = list.filter(members, fn(k) { k.status == key.Active })
    let others =
      [key.Csr, key.Pending, key.Retired]
      |> list.filter_map(fn(status) {
        case list.count(members, fn(k) { k.status == status }) {
          0 -> Error(Nil)
          n -> Ok(int.to_string(n) <> " " <> key.status_to_string(status))
        }
      })
    let line =
      "  "
      <> name
      <> ": "
      <> case actives {
        [] -> "no active key"
        [one] -> "active " <> one.kid <> days_left(one, now)
        many ->
          int.to_string(list.length(many))
          <> " active keys: "
          <> string.join(
            list.map(many, fn(k) { k.kid <> days_left(k, now) }),
            ", ",
          )
      }
      <> case others {
        [] -> ""
        _ -> ", " <> string.join(others, ", ")
      }
    [line, ..duplicate_active_warning(name, actives)]
  })
}

/// The scopes there are keys for, `system` first and the rest sorted,
/// with `system` listed even when it has no key at all.
fn scope_names(all: List(Key)) -> List(String) {
  let names =
    all
    |> list.map(fn(k) { key.scope_to_string(k.scope) })
    |> list.unique
    |> list.filter(fn(name) { name != "system" })
    |> list.sort(string.compare)
  ["system", ..names]
}

/// The warnings alone, for a listing that prints every key rather than a
/// line per scope.
pub fn duplicate_active_warnings(all: List(Key)) -> List(String) {
  list.flat_map(scope_names(all), fn(name) {
    duplicate_active_warning(
      name,
      list.filter(all, fn(k) {
        k.status == key.Active && key.scope_to_string(k.scope) == name
      }),
    )
  })
}

/// The warning for a scope two keys are active for.
fn duplicate_active_warning(name: String, actives: List(Key)) -> List(String) {
  case actives {
    [] | [_] -> []
    many -> [
      "    WARNING: "
      <> name
      <> " has "
      <> int.to_string(list.length(many))
      <> " active keys ("
      <> string.join(list.map(many, fn(k) { k.kid }), ", ")
      <> "); each node signs with whichever its view answered first. Retire"
      <> " all but one with `sup stir_maintenance retire <kid> confirm`",
    ]
  }
}

/// A key as `sup` prints it: its metadata, its validity, its history.
/// Never the sealed private key.
pub fn describe_key(k: Key, now: Int) -> List(String) {
  [
    k.kid
      <> ": "
      <> key.status_to_string(k.status)
      <> ", scope "
      <> key.scope_to_string(k.scope)
      <> ", spc "
      <> k.spc
      <> ", "
      <> key.source_to_string(k.source)
      <> ", "
      <> k.alg,
    "  x5u " <> k.x5u,
    "  certificate: "
      <> case k.fingerprint, k.not_after {
      Some(fingerprint), Some(_) -> fingerprint <> days_left(k, now)
      _, _ -> "none"
    },
    "  sealed under "
      <> option.unwrap(k.kek, "an unrecorded key-encryption key")
      <> case k.history {
      [] -> ""
      events ->
        ", history: "
        <> string.join(
          list.map(events, fn(event) {
            event.what
            <> " by "
            <> event.by
            <> " at "
            <> int.to_string(event.at)
          }),
          "; ",
        )
    },
  ]
}

pub fn days_left(k: Key, now: Int) -> String {
  case key.days_left(k, now) {
    Some(days) -> " (" <> int.to_string(days) <> " days left)"
    None -> ""
  }
}

/// The warning for taking away a retired key whose certificate has not
/// expired: its `x5u` stops answering, and a verifier that fetches it for
/// a call this key signed will not be able to.
pub fn still_served(k: Key, now: Int) -> List(String) {
  case k.status, k.not_after {
    key.Retired, Some(at) if at > now -> [
      "warning: verifiers may still fetch its certificate until "
      <> kazoo.iso8601(modb.to_unix(at))
      <> " ("
      <> int.to_string({ at - now } / 86_400)
      <> " days); a call it signed cannot be verified once the URL stops answering",
    ]
    _, _ -> []
  }
}

/// What retiring `k` would do: leave its scope with nothing to sign
/// with, if nothing else in that scope can.
pub fn retire_consequences(k: Key, all: List(Key), now: Int) -> List(String) {
  no_signing_key_warning(k, all, now)
}

/// What deleting `k` would do: the same, and the certificate that stops
/// being served.
pub fn delete_consequences(k: Key, all: List(Key), now: Int) -> List(String) {
  list.append(still_served(k, now), no_signing_key_warning(k, all, now))
}

/// The line to run to mean it.
pub fn confirm_line(command: String, kid: String) -> String {
  "nothing was changed; run `sup stir_maintenance "
  <> command
  <> " "
  <> kid
  <> " confirm` to do it"
}

/// Whether the scope keeps a key that can sign once `k` is gone: one
/// that is active or pending and whose certificate has not expired. A
/// `csr` key has no certificate and cannot sign; a retired one is not
/// signing any more.
fn no_signing_key_warning(k: Key, all: List(Key), now: Int) -> List(String) {
  let scope = key.scope_to_string(k.scope)
  let others =
    list.filter(all, fn(other) {
      other.kid != k.kid && key.scope_to_string(other.scope) == scope
    })
  case list.any(others, can_sign(_, now)) {
    True -> []
    False -> [
      "WARNING: "
      <> scope
      <> " will have no signing key; outbound calls for it will not carry an Identity header",
    ]
  }
}

fn can_sign(k: Key, now: Int) -> Bool {
  case k.status, k.not_after {
    key.Active, Some(at) | key.Pending, Some(at) -> at > now
    _, _ -> False
  }
}

/// One line of trust material: what it is, how old it is, where it came
/// from, and what its detail means -- the CA list's sequence, and the
/// CRL's next update, which is the date verification starts failing
/// closed if nothing refreshes it.
pub fn trust_line(status: trust.Status, now: Int) -> String {
  "  "
  <> trust.kind_to_string(status.kind)
  <> ": fetched "
  <> int.to_string({ now - status.fetched_at } / 3600)
  <> "h ago from "
  <> status.source
  <> case status.kind, status.detail {
    _, None -> ""
    trust.Crl, Some(next_update) ->
      " (next update " <> kazoo.iso8601(next_update) <> ")"
    trust.Ca, Some(sequence) -> " (sequence " <> int.to_string(sequence) <> ")"
  }
}

/// The settings that decide whether this node signs and verifies at all.
/// An operator reading a status wants these before anything else: a
/// perfectly healthy key store signs nothing with `sign_enabled` off.
pub fn settings_line(config: Settings) -> String {
  "settings: sign_enabled "
  <> bool(config.sign_enabled)
  <> ", verify_enabled "
  <> bool(config.verify_enabled)
  <> ", verify_mode "
  <> case config.verify_mode {
    settings.Sync -> "sync"
    settings.Async -> "async"
  }
  <> ", x5u_base_url "
  <> case config.x5u_base_url {
    "" -> "not set (required: the public URL of /v2/stir/certs)"
    url -> url
  }
}

/// When the monitor last ran on this node. A node whose monitor has
/// never run has just started, or its monitor is not running.
pub fn monitor_line(last: Option(monitor.LastPass)) -> String {
  "monitor: "
  <> case last {
    None -> "never ran"
    Some(pass) ->
      "last pass "
      <> kazoo.iso8601(pass.at)
      <> " took "
      <> int.to_string(pass.took_s)
      <> "s: "
      <> int.to_string(list.length(pass.lines))
      <> " lines"
  }
}

/// What the signer on this node holds and has done.
pub fn signer_lines(
  answer: Result(signer.Stats, signer.Error),
) -> List(String) {
  case answer {
    Error(error) -> ["signer: " <> signer.describe_error(error)]
    Ok(stats) ->
      list.flatten([
        [
          "signer: "
            <> case stats.opened {
            [] -> "running, no key opened"
            kids -> "running, opened " <> string.join(kids, ", ")
          },
          "  vault: "
            <> option.unwrap(stats.vault, "none")
            <> case stats.next_vault {
            None -> ""
            Some(next) ->
              ", " <> system.kek_next_variable <> " " <> next <> " (rotating)"
          },
          "  signed "
            <> int.to_string(stats.signed)
            <> ", refused "
            <> case stats.refused {
            [] -> "0"
            refused ->
              string.join(
                list.map(refused, fn(pair) {
                  pair.0 <> " " <> int.to_string(pair.1)
                }),
                ", ",
              )
          },
        ],
        list.map(stats.stale, fn(pair) {
          "  signing "
          <> pair.0
          <> " from memory since "
          <> kazoo.iso8601(pair.1)
          <> ": the key store has not answered for it since then"
        }),
        list.map(stats.last_open, fn(pair) {
          "  opened " <> pair.0 <> " at " <> kazoo.iso8601(pair.1)
        }),
        list.map(stats.last_failure, fn(pair) {
          let #(kid, failure) = pair
          "  could not open "
          <> kid
          <> " at "
          <> kazoo.iso8601(failure.at)
          <> ": "
          <> failure.why
        }),
      ])
  }
}

/// The claims of a hand test, with the numbers canonical and a fresh
/// `origid`.
pub fn claims(
  orig: String,
  dest: String,
  attest: String,
  now: Int,
  origid: String,
) -> Result(passport.Claims, String) {
  use attest <- result.try(case settings.attestation_from_string(attest) {
    Ok(settings.Passthru) | Error(Nil) -> Error("attest is A, B or C")
    Ok(level) -> Ok(settings.attestation_to_string(level))
  })
  use orig <- result.try(
    passport.canonical_tn(orig)
    |> option.to_result("orig is not a telephone number"),
  )
  use dest <- result.try(
    passport.canonical_tn(dest)
    |> option.to_result("dest is not a telephone number"),
  )
  Ok(passport.Claims(attest:, dest: [dest], iat: now, orig:, origid:))
}

/// What a key store error means to an operator. `stir/keys` has its own
/// wording for the lines it logs; this one says what to do about it.
pub fn describe_key_error(error: keys.Error) -> String {
  case error {
    keys.Datastore(inner) -> "datastore: " <> kazoo.error_to_string(inner)
    keys.NotFound -> "no such key"
    keys.NoVault -> "this node has no key-encryption key"
    keys.Unsealable -> "sealed under another key-encryption key"
    keys.Damaged ->
      "the key's sealed private key is not a readable blob; import it again"
    keys.NoPrivateKey -> "the key document has no sealed private key"
    keys.CertificateMismatch(why) -> "certificate mismatch: " <> why
    keys.InvalidTransition -> "the key's status does not allow that"
    keys.Conflict ->
      "another node changed the key while this change was being written; nothing was changed, run it again"
    keys.ViewMissing ->
      "the "
      <> keys.view
      <> " view is not registered on the "
      <> system.category
      <> " database, so nothing can be listed; run `sup kapps_maintenance refresh_views "
      <> system.category
      <> "` or restart a kazoo_apps node"
    keys.Crypto(why) -> "crypto: " <> why
  }
}

fn bool(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
