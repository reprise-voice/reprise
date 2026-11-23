//// `stir/monitor`: one pass over a fake store, with the keys seeded as
//// documents and the STI-PA behind the fake transport. No actor is
//// started: `pass` is the body, and `now` with no actor is nothing.
////
//// A test node has no master account, so every alert the pass would
//// raise is reported as one it could not address; the fake's alert log
//// stays empty.
////
//// The STI-PA is at the staging host, since a follow-on fetch is https
//// on the host the answer came from, and the test list's signer is
//// pinned first the way an operator would pin the production root:
//// nothing is trusted on first use.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/http/request as http_request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import kazoo/cache
import kazoo/doc
import kazoo/kazoo as kazoo_type
import kazoo/modb
import kazoo/testing/fake
import kazoo/util
import stir/carriers
import stir/http
import stir/http_test.{fake as fake_transport, fixture, ok}
import stir/key.{Key}
import stir/keys
import stir/keys_test
import stir/monitor
import stir/numbers
import stir/stipa
import stir/stipa_test.{list_jwt}
import stir/store as kv
import stir/system
import stir/trust
import stir/views

const base = "https://authenticate-api-stg.iconectiv.com"

/// 2026-09-12T08:00:00Z, unix: inside the fixture CRL's window.
const now_unix = 1_789_200_000

/// 2026-09-12T15:40:44Z, the fixture CRL's `nextUpdate`.
const crl_next_update = 1_789_227_644

const signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/certificate/ca-list.crt"

const crl_signer_url = "https://authenticate-api-stg.iconectiv.com/download/v1/external/certificate/crlCert_267913_20330824.crt"

const day = 86_400

pub fn name_test() {
  assert monitor.name() == util.name("stir_monitor")
}

pub fn now_without_an_actor_test() {
  assert monitor.now() == Nil
}

/// Registering the views is what every pass starts with, and it is safe
/// on a node with no datastore behind it.
pub fn register_views_is_harmless_test() {
  assert views.register() == Nil
}

/// With nothing stored, a pass refreshes the trust material and reports
/// that; a pass an hour later finds it fresh and does nothing.
pub fn pass_over_an_empty_store_test() {
  let #(store, kz) = new()
  let calls = process.new_subject()
  // The default STI-PA, which the fake transport does not answer.
  assert monitor.pass(kz, fake_transport([], calls, timeouts: []))
    == [
      "trust refresh failed: the STI-PA answered something unexpected: HTTP 404 from https://authenticate-api.iconectiv.com/api/v1/ca-list",
    ]
  assert trust.status(kz) == Ok([])
  pin(kz)
  fake.put_config(store, "stipa_api_url", doc.String(base))
  assert monitor.pass(kz, stipa_transport(calls))
    == ["refreshed the trust material from " <> base]
  let assert Ok([ca, _crl]) = trust.status(kz)
  assert ca.fetched_at == modb.from_unix(now_unix)
  fake.set_now(store, now_unix + 3600)
  assert monitor.pass(kz, stipa_transport(calls)) == []
  // Past `trust_refresh_hours`, it is refreshed again.
  fake.put_config(store, "trust_refresh_hours", doc.String("2"))
  fake.set_now(store, now_unix + 2 * 3600)
  assert monitor.pass(kz, stipa_transport(calls))
    == ["refreshed the trust material from " <> base]
  assert fake.alerts(store) == []
}

/// The CRL lives 24 hours and the STI-PA reissues it on its own clock,
/// so a pass watches the stored CRL's next update as well as the CA
/// cadence, whichever comes first. With the CA a day from due and the
/// CRL inside the two-hour margin, the pass still refreshes; without
/// this, verification failed "CRL stale" for part of every day.
pub fn crl_next_update_drives_the_refresh_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  fake.put_config(store, "trust_refresh_hours", doc.String("24"))
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)

  // Three hours out: the CA is a day from due and the CRL is not close
  // enough to matter.
  fake.set_now(store, crl_next_update - 3 * 3600)
  assert monitor.pass(kz, stipa_transport(calls)) == []
  // Inside the margin, and the CA cadence has not moved.
  fake.set_now(store, crl_next_update - 2 * 3600 + 1)
  assert monitor.pass(kz, stipa_transport(calls))
    == ["refreshed the trust material from " <> base]
}

/// A CRL that did not come leaves the stored one in place, and the pass
/// says so rather than reporting a clean refresh.
pub fn crl_that_did_not_come_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)
  // Inside the CRL's margin, so the pass tries; the CRL's URL answers
  // nothing this time.
  fake.set_now(store, crl_next_update - 3600)
  let without_crl =
    fake_transport(
      [
        #(
          base <> stipa.ca_list_path,
          ok(200, envelope(list_jwt(base:, sequence: 2))),
        ),
        #(signer_url, ok(200, fixture("test-cert.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert monitor.pass(kz, without_crl)
    == [
      "refreshed the CA list from "
      <> base
      <> "; the CRL did not come or was refused, and the stored one was kept",
    ]
  assert trust.pem(kz, trust.Crl) == Ok(fixture("stipa-stg-crl.pem"))
}

/// A pending key whose time has come takes over a scope with no active
/// key; an active key inside a threshold with nothing newer is alerted
/// about; a retired key past its end is deleted.
pub fn pass_over_keys_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let now = modb.from_unix(now_unix)
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)

  seed(store, "p1", key.System, key.Pending, now - 10, now + 400 * day)
  seed(store, "a1", key.Account("acc"), key.Active, now - day, now + 10 * day)
  seed(store, "r1", key.System, key.Retired, now - 800 * day, now - 1)
  // A scope whose active key has a successor pending for later: no
  // alert, no activation yet.
  seed(store, "a2", key.Account("acc2"), key.Active, now - day, now + 10 * day)
  seed(
    store,
    "p2",
    key.Account("acc2"),
    key.Pending,
    now + 5 * day,
    now + 700 * day,
  )
  // A scope whose active key outlives the pending one: not replaced.
  seed(store, "a3", key.Account("acc3"), key.Active, now - day, now + 300 * day)
  seed(store, "p3", key.Account("acc3"), key.Pending, now - 10, now + 200 * day)
  // A pending key whose own certificate has expired: its scope has no
  // active key at all, and it is still not activated -- it could not
  // sign anything a verifier would take.
  seed(store, "p4", key.Account("acc4"), key.Pending, now - 800 * day, now - 1)

  assert monitor.pass(kz, stipa_transport(calls))
    == [
      "activated key p1 for scope system",
      "no master account to alert: key a1 (acc) expires in 10 day(s)",
      "deleted retired key r1 past its not_after",
    ]
  let assert Ok(all) = keys.list(kz)
  let status = fn(kid) {
    list.find(all, fn(k) { k.kid == kid })
    |> option.from_result
    |> option.map(fn(k) { k.status })
  }
  assert status("p1") == Some(key.Active)
  assert status("r1") == None
  assert status("p2") == Some(key.Pending)
  assert status("p3") == Some(key.Pending)
  assert status("p4") == Some(key.Pending)
  assert status("a3") == Some(key.Active)
  assert fake.alerts(store) == []

  // The next pass: p1 is active and far from expiry, r1 is gone, a1 is
  // still inside its threshold.
  assert monitor.pass(kz, stipa_transport(calls))
    == ["no master account to alert: key a1 (acc) expires in 10 day(s)"]

  // Once p2's time comes it takes over from a2, which expires sooner; a
  // day later the trust material is due as well. The fixture CRL the
  // STI-PA answers is days past its `nextUpdate` by then, so the list is
  // stored and the CRL refused rather than stored stale.
  fake.set_now(store, now_unix + 6 * day)
  assert monitor.pass(kz, stipa_transport(calls))
    == [
      "activated key p2 for scope acc2",
      "no master account to alert: key a1 (acc) expires in 4 day(s)",
      "refreshed the CA list from "
        <> base
        <> "; the CRL did not come or was refused, and the stored one was kept",
    ]
  assert keys.active(kz, key.Account("acc2"))
    |> option_kid
    == Some("p2")
}

/// Every active key's `x5u` is fetched afresh; one that does not answer
/// is alerted about.
pub fn self_check_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let now = modb.from_unix(now_unix)
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)
  fake.put_doc(
    store,
    "stir",
    key.to_doc(
      Key(
        ..blank("a1", key.System, key.Active, now - day, now + 300 * day),
        x5u: "https://api.test/v2/stir/certs/a1.pem",
      ),
    ),
  )
  fake.put_doc(
    store,
    "stir",
    key.to_doc(
      Key(
        ..blank(
          "a2",
          key.Account("acc"),
          key.Active,
          now - day,
          now + 300 * day,
        ),
        x5u: "https://api.test/v2/stir/certs/a2.pem",
      ),
    ),
  )
  let transport =
    fake_transport(
      [
        #(
          "https://api.test/v2/stir/certs/a1.pem",
          ok(200, fixture("test-cert.pem")),
        ),
        #(
          base <> stipa.ca_list_path,
          ok(200, envelope(list_jwt(base:, sequence: 1))),
        ),
        #(signer_url, ok(200, fixture("test-cert.pem"))),
        #(base <> trust.crl_path, ok(200, fixture("stipa-stg-crl.pem"))),
        #(crl_signer_url, ok(200, fixture("stipa-stg-crl-signer.pem"))),
      ],
      calls,
      timeouts: [],
    )
  // The view orders keys by scope, so `acc` comes before `system`.
  assert monitor.pass(kz, transport)
    == [
      "no master account to alert: x5u of key a2 (https://api.test/v2/stir/certs/a2.pem) could not be fetched: HTTP 404 without a certificate",
      "x5u of key a1 answers",
    ]
  // Fetched afresh each pass, not from the cache.
  assert monitor.pass(kz, transport)
    == [
      "no master account to alert: x5u of key a2 (https://api.test/v2/stir/certs/a2.pem) could not be fetched: HTTP 404 without a certificate",
      "x5u of key a1 answers",
    ]
  assert list.filter(http_test.drain(calls), fn(url) {
      url == "https://api.test/v2/stir/certs/a1.pem"
    })
    == [
      "https://api.test/v2/stir/certs/a1.pem",
      "https://api.test/v2/stir/certs/a1.pem",
    ]
}

/// A node with no key-encryption key cannot sign at all, which is a
/// deployment mistake and is said out loud every pass, at error level,
/// with the alert escalating once keys are active.
pub fn no_vault_is_reported_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)
  without_kek()
  assert monitor.pass(kz, stipa_transport(calls))
    == [
      "no master account to alert: no key-encryption key: STIR_KEK is not set",
    ]
  // It is a failure, not a note.
  assert monitor.pass_with_levels(kz, stipa_transport(calls))
    == [
      #(
        monitor.Failure,
        "no master account to alert: no key-encryption key: STIR_KEK is not set",
      ),
    ]
  with_kek()
  assert monitor.pass(kz, stipa_transport(calls)) == []
}

/// Two nodes activating at once leave two active keys for a scope. The
/// pass keeps the longest-lived and retires the rest.
pub fn two_active_keys_for_one_scope_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let now = modb.from_unix(now_unix)
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)
  seed(store, "t1", key.Account("acc8"), key.Active, now - day, now + 100 * day)
  seed(store, "t2", key.Account("acc8"), key.Active, now - day, now + 200 * day)

  assert monitor.pass(kz, stipa_transport(calls))
    == [
      "no master account to alert: 2 active keys for scope acc8 (t1, t2); keeping t2",
      "retired key t1, a second active key for acc8",
    ]
  let assert Ok(all) = keys.list(kz)
  assert list.filter(all, fn(k) { k.status == key.Active })
    |> list.map(fn(k) { k.kid })
    == ["t2"]
  // And the next pass has nothing to say about the scope.
  assert monitor.pass(kz, stipa_transport(calls)) == []
}

/// An expired certificate is its own alert, and a pending key that
/// cannot be activated stops standing in for the successor that would
/// have kept the alert quiet.
pub fn an_expired_certificate_is_alerted_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let now = modb.from_unix(now_unix)
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)
  seed(
    store,
    "e1",
    key.Account("acc9"),
    key.Active,
    now - 400 * day,
    now - 3 * day,
  )
  // Its successor is pending and due, but has no private key, so every
  // activation fails.
  seed_without_a_private_key(
    store,
    "s1",
    key.Account("acc9"),
    key.Pending,
    now - 10,
    now + 300 * day,
  )

  // The first pass tries the successor and says why it could not.
  assert monitor.pass(kz, stipa_transport(calls))
    == [
      "could not activate key s1 (1 attempt(s) now): no sealed private key on the document",
    ]
  // By the second, the successor is not believed any more and the
  // expired certificate is alerted about.
  assert monitor.pass(kz, stipa_transport(calls))
    == [
      "could not activate key s1 (2 attempt(s) now): no sealed private key on the document",
      "no master account to alert: key e1 (acc9) expired 3 day(s) ago",
    ]
}

/// An `x5u` on an address the policy refuses says what to do about it:
/// it is `x5u_base_url` pointing at something private, every time.
pub fn a_refused_x5u_says_what_to_set_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let now = modb.from_unix(now_unix)
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)
  fake.put_doc(
    store,
    "stir",
    key.to_doc(
      Key(
        ..blank("r1", key.System, key.Active, now - day, now + 300 * day),
        x5u: "https://10.0.0.5/v2/stir/certs/r1.pem",
      ),
    ),
  )
  assert monitor.pass(kz, stipa_transport(calls))
    == [
      "no master account to alert: x5u of key r1 (https://10.0.0.5/v2/stir/certs/r1.pem) is refused by the address policy (https, port 443, no private addresses); set x5u_base_url to the public API host",
    ]
}

/// A node that cannot see a cluster refreshes the trust material
/// itself: the leader rule must not leave a lone node never refreshing.
pub fn a_node_with_no_cluster_refreshes_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let calls = process.new_subject()
  pin(kz)
  assert monitor.pass(kz, stipa_transport(calls))
    == ["refreshed the trust material from " <> base]
}

/// The self-checks run at once rather than one after another. A node
/// with several keys and an x5u host that has gone slow used to spend
/// one timeout per key inside the pass; five fetches of a third of a
/// second each take a third of a second together, not a second and a
/// half.
pub fn the_self_checks_run_at_once_test() {
  let #(store, kz) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let now = modb.from_unix(now_unix)
  let calls = process.new_subject()
  pin(kz)
  let assert Ok(_) = trust.refresh(kz, stipa_transport(calls), base, 100)
  let kids = ["c1", "c2", "c3", "c4", "c5"]
  list.each(kids, fn(kid) {
    fake.put_doc(
      store,
      "stir",
      key.to_doc(
        Key(
          ..blank(kid, key.Account(kid), key.Active, now - day, now + 300 * day),
          x5u: "https://api.test/v2/stir/certs/" <> kid <> ".pem",
        ),
      ),
    )
  })

  let delay_ms = 300
  let started = monotonic(atom.create("millisecond"))
  let lines = monitor.pass(kz, slow_x5u(calls, delay_ms))
  let took = monotonic(atom.create("millisecond")) - started
  assert list.filter(lines, fn(line) { string.contains(line, "answers") })
    |> list.length
    == 5
  // Serially this is five delays; together it is one, with room for a
  // slow machine.
  assert took < 3 * delay_ms
    as { "the self-checks took " <> int.to_string(took) <> "ms" }
}

/// The actor runs the pass beside itself. A pass that crashes -- here
/// because the transport itself raises, which is what a parser bug or a
/// broken client library looks like -- is an alert and a line, not a
/// dead monitor and not a lost hour: the actor answers afterwards and
/// the next pass is already scheduled.
///
/// `gleam test` starts the `stir` application, whose tree holds a
/// monitor under the same name, so the application is stopped for the
/// length of this and started again after, as `signer_test` does.
pub fn a_crashing_pass_does_not_take_the_actor_with_it_test() {
  let #(store, _unused) = new()
  fake.put_config(store, "stipa_api_url", doc.String(base))
  let kz = fake.kazoo(store)
  let _ = application_stop(atom.create("stir"))
  let assert Ok(started) = monitor.start(kz, fn(_request, _timeout) { panic })

  monitor.now()
  // The actor answers the message after the one that crashed, which is
  // what says it is still there.
  let done = process.new_subject()
  process.send(started.data, monitor.Stop(done))
  assert process.receive(done, 10_000) == Ok(Nil)
  let assert Some(last) = monitor.last_pass()
  assert last.lines == ["no master account to alert: the monitor pass crashed"]

  process.unlink(started.pid)
  process.kill(started.pid)
  let _ = application_ensure_all_started(atom.create("stir"))
  Nil
}

// ---------------------------------------------------------------------------
// Arranging
// ---------------------------------------------------------------------------

fn new() -> #(fake.Fake, kazoo_type.Kazoo) {
  // A node with no `STIR_KEK` cannot sign, which every pass says out
  // loud; the tests that are not about that give it one.
  with_kek()
  let store =
    fake.new_with_views([
      keys_test.key_view(),
    ])
  fake.set_now(store, now_unix)
  #(store, fake.kazoo(store))
}

/// What an operator does before the first refresh: pin the root the
/// STI-PA's list signer is under, with the role `stipa`. Here the signer
/// is its own root.
fn pin(kz: kazoo_type.Kazoo) -> Nil {
  let assert Ok(_) =
    trust.upload_root(kz, trust.StipaRoot, fixture("test-cert.pem"), "sup")
  Nil
}

fn seed(
  store: fake.Fake,
  kid: String,
  scope: key.Scope,
  status: key.Status,
  not_before: Int,
  not_after: Int,
) -> Nil {
  // A stored key has its sealed private key; an activation refuses one
  // that does not, so a seeded key carries a blob too. What is in it
  // does not matter: nothing here opens it.
  fake.put_doc(
    store,
    "stir",
    key.to_doc(blank(kid, scope, status, not_before, not_after))
      |> doc.set([key.sealed_private_key_field], kv.sealed_field(<<"sealed">>)),
  )
}

/// A key document with no sealed private key: activating it fails,
/// every time, which is the pending key that never takes over.
fn seed_without_a_private_key(
  store: fake.Fake,
  kid: String,
  scope: key.Scope,
  status: key.Status,
  not_before: Int,
  not_after: Int,
) -> Nil {
  fake.put_doc(
    store,
    "stir",
    key.to_doc(blank(kid, scope, status, not_before, not_after)),
  )
}

fn blank(
  kid: String,
  scope: key.Scope,
  status: key.Status,
  not_before: Int,
  not_after: Int,
) -> key.Key {
  Key(
    kid:,
    scope:,
    alg: "ES256",
    spc: "999Y",
    x5u: "",
    not_before: Some(not_before),
    not_after: Some(not_after),
    status:,
    source: key.Issued,
    fingerprint: None,
    kek: None,
    history: [],
  )
}

/// A key-encryption key in the environment, so `vault.load` answers.
fn with_kek() -> Nil {
  putenv(
    system.kek_variable,
    bit_array.base64_encode(
      <<
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
      >>,
      True,
    ),
  )
}

fn without_kek() -> Nil {
  putenv(system.kek_variable, "")
}

fn putenv(name: String, value: String) -> Nil {
  let _ = os_putenv(charlist.from_string(name), charlist.from_string(value))
  Nil
}

fn option_kid(
  answer: Result(option.Option(key.Key), keys.Error),
) -> option.Option(String) {
  case answer {
    Ok(Some(k)) -> Some(k.kid)
    _ -> None
  }
}

/// The STI-PA as ever, and a certificate server that takes its time.
fn slow_x5u(calls: process.Subject(String), delay_ms: Int) -> http.Transport {
  let stipa = stipa_transport(calls)
  fn(request, timeout_ms) {
    let url = uri.to_string(http_request.to_uri(request))
    case string.starts_with(url, "https://api.test/") {
      False -> stipa(request, timeout_ms)
      True -> {
        process.send(calls, url)
        process.sleep(delay_ms)
        ok(200, fixture("test-cert.pem"))
      }
    }
  }
}

fn stipa_transport(calls: process.Subject(String)) -> http.Transport {
  fake_transport(
    [
      #(
        base <> stipa.ca_list_path,
        ok(200, envelope(list_jwt(base:, sequence: 1))),
      ),
      #(signer_url, ok(200, fixture("test-cert.pem"))),
      #(base <> trust.crl_path, ok(200, fixture("stipa-stg-crl.pem"))),
      #(crl_signer_url, ok(200, fixture("stipa-stg-crl-signer.pem"))),
    ],
    calls,
    timeouts: [],
  )
}

fn envelope(jwt: String) -> String {
  doc.to_string(doc.object([#("caList", doc.String(jwt))]))
}

@external(erlang, "os", "putenv")
fn os_putenv(name: Charlist, value: Charlist) -> Bool

@external(erlang, "application", "stop")
fn application_stop(application: Atom) -> Result(Nil, Dynamic)

@external(erlang, "application", "ensure_all_started")
fn application_ensure_all_started(
  application: Atom,
) -> Result(List(Atom), Dynamic)

@external(erlang, "erlang", "monotonic_time")
fn monotonic(unit: Atom) -> Int

/// Every pass sweeps the caches the call path fills: the certificates
/// and their failures (`x5u`), the number-ownership answers, and the
/// carrier tokens. Each is bounded by whoever writes past the bound too,
/// so the tables are seeded here the way a race between two writers
/// could leave one -- over the bound, with nobody having noticed -- and
/// the pass is what brings them back.
pub fn a_pass_sweeps_the_call_path_caches_test() {
  numbers.forget()
  carriers.forget_cached()
  let #(_store, kz) = new()
  let calls = process.new_subject()
  let seed = fn(n) { int.to_string(n) }
  down_from(4200)
  |> list.each(fn(n) {
    cache.put_fresh(numbers.table, "owner:" <> seed(n), numbers.Nobody)
    cache.put_fresh(
      carriers.table,
      "token:" <> seed(n),
      Error(carriers.NotFound),
    )
  })
  assert numbers.size() > numbers.max_entries
  assert carriers.size() > carriers.max_entries

  let _lines = monitor.pass(kz, stipa_transport(calls))

  assert numbers.size() == numbers.max_entries
  assert carriers.size() == carriers.max_entries
  numbers.forget()
  carriers.forget_cached()
}

/// `n` down to 1; `gleam/list` has no `range`.
fn down_from(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> [n, ..down_from(n - 1)]
  }
}
