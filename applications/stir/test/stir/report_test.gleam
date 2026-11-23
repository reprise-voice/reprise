//// What the `sup` commands print: the per-scope summary, a key, the
//// warnings before a change that cannot be taken back, the trust,
//// settings, monitor and signer lines, the claims of a hand-test token,
//// and what an error says. The commands themselves need a node; none of
//// this does.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/kazoo
import kazoo/testing/fake
import stir/key
import stir/keys
import stir/monitor
import stir/report
import stir/settings
import stir/signer
import stir/trust

/// The fake's clock as Gregorian seconds, which is what a stored key's
/// times are in.
const now = 63_900_000_000

fn sample(scope: key.Scope, status: key.Status) -> key.Key {
  key.Key(
    kid: "kid-"
      <> key.scope_to_string(scope)
      <> "-"
      <> key.status_to_string(status),
    scope:,
    alg: "ES256",
    spc: "999Y",
    x5u: "https://api.example/v2/stir/certs/k.pem",
    not_before: Some(now - 86_400),
    not_after: Some(now + 864_000),
    status:,
    source: key.Issued,
    fingerprint: Some("sha256:00"),
    kek: Some("deadbeef"),
    history: [key.Event(at: now, what: "created", by: "sup")],
  )
}

pub fn describe_key_test() {
  let lines = report.describe_key(sample(key.System, key.Active), now)
  assert lines
    == [
      "kid-system-active: active, scope system, spc 999Y, csr, ES256",
      "  x5u https://api.example/v2/stir/certs/k.pem",
      "  certificate: sha256:00 (10 days left)",
      "  sealed under deadbeef, history: created by sup at 63900000000",
    ]

  let bare =
    key.Key(
      ..sample(key.Account("a1"), key.Csr),
      not_before: None,
      not_after: None,
      fingerprint: None,
      kek: None,
      history: [],
    )
  let lines = report.describe_key(bare, now)
  assert list.length(lines) == 4
  assert list.contains(lines, "  certificate: none")
  // A key with no marker is a key nobody recorded the KEK of, which is
  // not the same as one sealed under nothing.
  assert list.contains(lines, "  sealed under an unrecorded key-encryption key")
  // Never a PEM.
  assert !string.contains(string.join(lines, "\n"), "-----BEGIN")
}

pub fn scope_lines_test() {
  // `system` is always first, even with no key at all.
  assert report.scope_lines([], now) == ["  system: no active key"]

  let all = [
    sample(key.System, key.Active),
    sample(key.System, key.Retired),
    sample(key.System, key.Retired),
    sample(key.Account("a1"), key.Csr),
    sample(key.Account("a1"), key.Pending),
  ]
  assert report.scope_lines(all, now)
    == [
      "  system: active kid-system-active (10 days left), 2 retired",
      "  a1: no active key, 1 csr, 1 pending",
    ]
}

/// Two nodes that activated at the same moment leave a scope with two
/// active keys. Both are printed, and the line under them says to retire
/// one: a status that showed only the first would hide it for good.
pub fn two_active_keys_are_printed_test() {
  let one = sample(key.System, key.Active)
  let two = key.Key(..one, kid: "second")
  let lines = report.scope_lines([one, two], now)
  let assert [scope, warning] = lines
  assert scope
    == "  system: 2 active keys: kid-system-active (10 days left), second (10 days left)"
  assert string.contains(warning, "WARNING: system has 2 active keys")
  assert string.contains(warning, "kid-system-active, second")
  assert string.contains(warning, "retire <kid> confirm")

  // The same warnings without the per-scope summary, for `keys`.
  assert report.duplicate_active_warnings([one, two]) == [warning]
  assert report.duplicate_active_warnings([one]) == []
  assert report.duplicate_active_warnings([]) == []
}

/// Retiring the only key a scope can sign with says so before it is
/// done; retiring one of two does not.
pub fn retire_consequences_test() {
  let only = sample(key.System, key.Active)
  let assert [warning] = report.retire_consequences(only, [only], now)
  assert warning
    == "WARNING: system will have no signing key; outbound calls for it will not carry an Identity header"

  // A pending key with a certificate takes over.
  let waiting = key.Key(..sample(key.System, key.Pending), kid: "waiting")
  assert report.retire_consequences(
      only,
      [
        only,
        waiting,
      ],
      now,
    )
    == []

  // A key of another scope does not.
  let elsewhere = sample(key.Account("a1"), key.Pending)
  assert report.retire_consequences(only, [only, elsewhere], now) == [warning]

  // Neither does one whose certificate has expired, nor a csr key with
  // no certificate at all.
  let expired = key.Key(..waiting, kid: "expired", not_after: Some(now - 1))
  let no_certificate =
    key.Key(..sample(key.System, key.Csr), not_after: None, fingerprint: None)
  assert report.retire_consequences(only, [only, expired, no_certificate], now)
    == [warning]
}

/// Deleting a retired key whose certificate is still inside its validity
/// takes away a certificate verifiers may still be fetching, and says so.
pub fn still_served_test() {
  let retired = sample(key.System, key.Retired)
  let assert [line] = report.still_served(retired, now)
  assert string.contains(line, "verifiers may still fetch its certificate")
  assert string.contains(line, "10 days")
  assert string.contains(line, "until 20")

  // Past its `not_after`, and for every other status, there is nothing
  // to warn about.
  assert report.still_served(retired, now + 864_001) == []
  assert report.still_served(key.Key(..retired, not_after: None), now) == []
  assert report.still_served(sample(key.System, key.Pending), now) == []
  assert report.still_served(sample(key.System, key.Csr), now) == []

  // Deleting says both things at once: what stops being served, and
  // that the scope is left with nothing to sign with.
  let lines = report.delete_consequences(retired, [retired], now)
  assert list.length(lines) == 2
  assert string.contains(string.join(lines, "\n"), "will have no signing key")
  assert report.confirm_line("delete", "k1")
    == "nothing was changed; run `sup stir_maintenance delete k1 confirm` to do it"
}

pub fn trust_line_test() {
  // The CRL's detail is the date verification starts failing closed, so
  // it is printed as a date and not as a number of seconds.
  let crl =
    trust.Status(
      kind: trust.Crl,
      fetched_at: now - 7200,
      source: "stipa",
      detail: Some(1_800_000_000),
    )
  let line = report.trust_line(crl, now)
  assert string.starts_with(
    line,
    "  crl: fetched 2h ago from stipa (next update ",
  )
  assert string.contains(line, kazoo.iso8601(1_800_000_000))
  assert !string.contains(line, "1800000000")

  let ca = trust.Status(..crl, kind: trust.Ca, detail: Some(42))
  assert report.trust_line(ca, now)
    == "  ca: fetched 2h ago from stipa (sequence 42)"
  assert report.trust_line(trust.Status(..ca, detail: None), now)
    == "  ca: fetched 2h ago from stipa"
}

/// A key store in perfect health signs nothing with `sign_enabled` off,
/// so the status says what the settings are.
pub fn settings_line_test() {
  let config = settings.load(fake.kazoo(fake.new()))
  assert report.settings_line(config)
    == "settings: sign_enabled false, verify_enabled false, verify_mode sync, x5u_base_url not set (required: the public URL of /v2/stir/certs)"

  let on =
    settings.Settings(
      ..config,
      sign_enabled: True,
      verify_enabled: True,
      verify_mode: settings.Async,
      x5u_base_url: "https://api.example/v2/stir/certs",
    )
  assert report.settings_line(on)
    == "settings: sign_enabled true, verify_enabled true, verify_mode async, x5u_base_url https://api.example/v2/stir/certs"
}

pub fn monitor_line_test() {
  assert report.monitor_line(None) == "monitor: never ran"
  let line =
    report.monitor_line(
      Some(monitor.LastPass(at: 1_800_000_000, took_s: 3, lines: ["a", "b"])),
    )
  assert line
    == "monitor: last pass "
    <> kazoo.iso8601(1_800_000_000)
    <> " took 3s: 2 lines"
}

pub fn signer_lines_test() {
  assert report.signer_lines(Error(signer.Unavailable))
    == ["signer: the signer is not running on this node"]

  let stats =
    signer.Stats(
      vault: Some("deadbeef"),
      next_vault: None,
      opened: [],
      signed: 0,
      refused: [],
      last_open: [],
      last_failure: [],
      stale: [],
    )
  assert report.signer_lines(Ok(stats))
    == [
      "signer: running, no key opened",
      "  vault: deadbeef",
      "  signed 0, refused 0",
    ]

  let busy =
    signer.Stats(
      ..stats,
      next_vault: Some("cafe1234"),
      opened: ["k1"],
      signed: 12,
      refused: [#("timeout", 1), #("unknown_key", 2)],
      last_open: [#("k1", 1_800_000_000)],
      last_failure: [
        #("k2", signer.Failure(at: 1_800_000_060, why: "no such key")),
      ],
      stale: [#("k1", 1_800_000_030)],
    )
  let lines = report.signer_lines(Ok(busy))
  assert list.first(lines) == Ok("signer: running, opened k1")
  let text = string.join(lines, "\n")
  assert string.contains(text, "cafe1234 (rotating)")
  assert string.contains(text, "signed 12, refused timeout 1, unknown_key 2")
  assert string.contains(text, "opened k1 at " <> kazoo.iso8601(1_800_000_000))
  assert string.contains(
    text,
    "could not open k2 at " <> kazoo.iso8601(1_800_000_060) <> ": no such key",
  )
  // A node signing from a key it holds because the store stopped
  // answering says so: nothing else shows it, the calls all carry an
  // Identity header.
  assert string.contains(
    text,
    "signing k1 from memory since " <> kazoo.iso8601(1_800_000_030),
  )
}

pub fn claims_test() {
  let assert Ok(claims) =
    report.claims("+1 (404) 555-0199", "14045550100", "a", 1234, "an-origid")
  assert claims.attest == "A"
  assert claims.orig == "14045550199"
  assert claims.dest == ["14045550100"]
  assert claims.iat == 1234
  assert claims.origid == "an-origid"

  assert report.claims("14045550199", "14045550100", "passthru", 1, "i")
    == Error("attest is A, B or C")
  assert report.claims("14045550199", "14045550100", "D", 1, "i")
    == Error("attest is A, B or C")
  assert report.claims("anonymous", "14045550100", "A", 1, "i")
    == Error("orig is not a telephone number")
  assert report.claims("14045550199", "", "A", 1, "i")
    == Error("dest is not a telephone number")
}

pub fn describe_key_error_test() {
  assert report.describe_key_error(keys.NotFound) == "no such key"
  assert report.describe_key_error(keys.NoVault)
    == "this node has no key-encryption key"
  assert report.describe_key_error(keys.Unsealable)
    == "sealed under another key-encryption key"
  assert report.describe_key_error(keys.CertificateMismatch("why"))
    == "certificate mismatch: why"
  assert report.describe_key_error(keys.InvalidTransition)
    == "the key's status does not allow that"
  assert report.describe_key_error(keys.Crypto("why")) == "crypto: why"
  assert report.describe_key_error(keys.Datastore(kazoo.Unavailable))
    == "datastore: unavailable"
  assert report.describe_key_error(keys.NoPrivateKey)
    == "the key document has no sealed private key"
  // A conflict is not a failure of the store: the change was not made
  // and running the command again makes it.
  let conflict = report.describe_key_error(keys.Conflict)
  assert string.contains(conflict, "another node changed the key")
  assert string.contains(conflict, "run it again")
  // The one an operator has to act on says what to do about it.
  let view_missing = report.describe_key_error(keys.ViewMissing)
  assert string.contains(view_missing, keys.view)
  assert string.contains(view_missing, "refresh_views")
}
