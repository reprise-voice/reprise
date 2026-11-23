//// `stir/key.from_doc` and `stir/settings.load` over documents and
//// configuration values that are not what they should be.
////
//// Neither of these reads an attacker's bytes directly: a key document
//// comes from CouchDB and a setting from `system_config/stir`. But a
//// database write is the residual §3.2 names, an operator can put
//// anything in a config value with `sup kapps_config set_default`, and
//// a document written by an older version of the application is a
//// document with fields missing. Whatever arrives, neither may raise,
//// and what they answer must be the defaults rather than nonsense.

import gleam/list
import gleam/option.{Some}
import gleam/string
import kazoo/doc.{type Value}
import kazoo/testing/fake
import stir/key
import stir/settings
import support/mutate

fn sample() -> key.Key {
  key.Key(
    kid: "0123456789abcdef",
    scope: key.System,
    alg: "ES256",
    spc: "999Y",
    x5u: "https://api.example/v2/stir/certs/0123456789abcdef.pem",
    not_before: Some(63_900_000_000),
    not_after: Some(63_963_072_000),
    status: key.Active,
    source: key.Issued,
    fingerprint: Some("sha256:00"),
    kek: Some("deadbeef"),
    history: [key.Event(at: 63_900_000_000, what: "created", by: "sup")],
  )
}

/// Every field of a stored key document, and the nested ones.
const fields = [
  "_id", "pvt_type", "scope", "alg", "spc", "x5u", "not_before", "not_after",
  "status", "source", "fingerprint", "kek", "history",
]

/// The values a field should never hold.
fn wrong_values() -> List(Value) {
  list.flatten([
    [
      doc.Null,
      doc.Bool(True),
      doc.Bool(False),
      doc.Int(0),
      doc.Int(-1),
      doc.Int(9_223_372_036_854_775_807),
      doc.Float(1.5),
      doc.Float(0.0),
      doc.String(""),
      doc.List([]),
      doc.List([doc.Null, doc.Int(1)]),
      doc.object([]),
      doc.object([#("nested", doc.object([#("deeper", doc.Int(1))]))]),
    ],
    list.map(mutate.oddities(), doc.String),
    [doc.String(mutate.huge("a"))],
  ])
}

/// A key document with one field missing, or holding something else:
/// `from_doc` answers a key or `Error(Nil)`, and never raises. A key it
/// answers is the document's own id, with a status and a source that
/// are of the type and not of the bytes.
pub fn mutated_key_documents_test() {
  let stored = key.to_doc(sample())
  let assert Ok(_) = key.from_doc(stored)

  let dropped = list.map(fields, fn(field) { doc.delete(stored, [field]) })
  let replaced =
    list.flatten(
      list.map(fields, fn(field) {
        list.map(wrong_values(), fn(value) { doc.set(stored, [field], value) })
      }),
    )
  let nested = [
    doc.set(stored, ["history"], doc.List([doc.String("no"), doc.Int(1)])),
    doc.set(stored, ["history"], doc.object([#("at", doc.Int(1))])),
    doc.set(stored, ["history", "0", "at"], doc.String("soon")),
    doc.set(stored, ["not_before"], doc.String("soon")),
    doc.set(stored, ["not_before"], doc.String("-1")),
    doc.set(stored, ["not_before"], doc.Float(1.9)),
    doc.set(stored, ["status"], doc.String("ACTIVE")),
    doc.set(stored, ["status"], doc.String("active ")),
    doc.set(stored, ["source"], doc.String("CSR")),
    doc.set(stored, ["pvt_type"], doc.String("stir_key ")),
    doc.set(stored, ["scope"], doc.String("system ")),
  ]
  let documents = list.flatten([dropped, replaced, nested])
  assert list.length(documents) > 400

  list.each(documents, fn(document) {
    case key.from_doc(document) {
      Error(Nil) -> Nil
      Ok(answered) -> {
        let about =
          "document: " <> string.slice(doc.to_string(document), 0, 160)
        // The kid is the document's `_id` and nothing else.
        assert doc.get_string(document, ["_id"]) == Ok(answered.kid) as about
        // The status and the source are the four and the three there
        // are; a document cannot invent a fifth.
        assert list.contains(
          ["csr", "pending", "active", "retired"],
          key.status_to_string(answered.status),
        )
          as about
        assert list.contains(
          ["csr", "acme", "imported"],
          key.source_to_string(answered.source),
        )
          as about
        // Junk in the history is dropped rather than half-read: the
        // document carries one event, so a key can carry one or none.
        assert list.length(answered.history) <= 1 as about
      }
    }
  })
}

/// A document that is not an object at all, and objects nested deeper
/// than anything the store writes.
pub fn documents_that_are_not_documents_test() {
  let values =
    list.flatten([
      [doc.Null, doc.Bool(True), doc.Int(1), doc.Float(1.0), doc.List([])],
      list.map(mutate.oddities(), doc.String),
      [deep(500), doc.List([deep(500)])],
    ])
  list.each(values, fn(value) {
    assert key.from_doc(value) == Error(Nil)
      as { "value: " <> string.slice(doc.to_string(value), 0, 80) }
  })
}

fn deep(levels: Int) -> Value {
  list.fold(mutate.upto(levels), doc.Int(1), fn(inner, _index) {
    doc.object([#("a", inner)])
  })
}

/// `settings.load` over hostile values for every setting at once: the
/// numbers stay numbers a caller can use, the attestations stay one of
/// the four, and nothing raises.
pub fn hostile_settings_test() {
  let names = [
    "sign_enabled", "verify_enabled", "verify_mode", "verify_timeout_ms",
    "trust_upstream_verstat", "attest_owned_number", "attest_owned_scope",
    "attest_forwarded", "attest_forwarded_when_inbound_failed",
    "attest_verified_external_number", "attest_transit", "attest_unverified",
    "sign_anonymous", "sign_non_nanp_origin", "x5u_base_url",
    "identity_max_age_s", "require_date_header", "cid_name_prefix_failed",
    "csr_organization", "allow_account_keys", "renewal_enabled",
    "renewal_window_days", "acme_directory_url", "stipa_api_url",
    "trust_refresh_hours", "alert_days",
  ]
  let values =
    list.flatten([
      list.map(
        [
          "", " ", "yes", "no", "TRUE", "true ", "-1", "0", "1e9", "nan",
          "99999999999999999999999", "0x10", "1,2,x", "1, 2, ", ",", "A,B",
          "sync ", "ASYNC", "passthru!", "\u{0}", "../../etc/passwd",
        ],
        doc.String,
      ),
      [
        doc.Null,
        doc.Bool(True),
        doc.Float(1.5),
        doc.List([doc.Int(1)]),
        doc.object([#("a", doc.Int(1))]),
        doc.String(mutate.huge("a")),
      ],
    ])

  list.each(values, fn(value) {
    let store = fake.new()
    list.each(names, fn(name) { fake.put_config(store, name, value) })
    let loaded = settings.load(fake.kazoo(store))
    let about =
      "every setting set to " <> string.slice(doc.to_string(value), 0, 60)

    // The timeouts and windows are non-negative: they are passed to
    // `httpc` and to date arithmetic.
    assert loaded.verify_timeout_ms >= 0 as about
    assert loaded.identity_max_age_s >= 0 as about
    assert loaded.renewal_window_days >= 0 as about
    assert loaded.trust_refresh_hours >= 0 as about
    // The attestations are the four there are.
    list.each(
      [
        loaded.attest_owned_number,
        loaded.attest_forwarded,
        loaded.attest_forwarded_when_inbound_failed,
        loaded.attest_verified_external_number,
        loaded.attest_transit,
        loaded.attest_unverified,
      ],
      fn(attestation) {
        assert list.contains(
          ["A", "B", "C", "passthru"],
          settings.attestation_to_string(attestation),
        )
          as about
      },
    )
    // And the alert thresholds stay a handful of days rather than
    // however many commas the value happened to hold.
    assert list.length(loaded.alert_days) <= 64 as about
  })
}

/// One setting at a time, so that a value that only matters for its own
/// field is not hidden by the others. The settings that take a number
/// are checked against the number they answer.
pub fn hostile_numeric_settings_test() {
  let numbers = [
    "verify_timeout_ms", "identity_max_age_s", "renewal_window_days",
    "trust_refresh_hours",
  ]
  let values = [
    doc.String("-1"),
    doc.String("-0"),
    doc.String("00000"),
    doc.String(" 1"),
    doc.String("1 "),
    doc.String("+1"),
    doc.String("1.5"),
    doc.String("1e3"),
    doc.String("99999999999999999999999999"),
    doc.String(""),
    doc.Float(-1.5),
    doc.Bool(False),
    doc.Null,
  ]
  list.each(numbers, fn(name) {
    list.each(values, fn(value) {
      let store = fake.new()
      fake.put_config(store, name, value)
      let loaded = settings.load(fake.kazoo(store))
      let about = name <> " = " <> doc.to_string(value)
      let answered = case name {
        "verify_timeout_ms" -> loaded.verify_timeout_ms
        "identity_max_age_s" -> loaded.identity_max_age_s
        "renewal_window_days" -> loaded.renewal_window_days
        _ -> loaded.trust_refresh_hours
      }
      assert answered >= 0 as about
    })
  })
}

/// A negative number is refused whichever way it was written, and the
/// default stands: a negative timeout reaches `httpc` as a `badarg`
/// and a negative window makes every certificate look expired.
pub fn negative_numbers_are_refused_test() {
  let store = fake.new()
  fake.put_config(store, "verify_timeout_ms", doc.Int(-1))
  fake.put_config(store, "identity_max_age_s", doc.String("-60"))
  fake.put_config(store, "renewal_window_days", doc.Int(-30))
  fake.put_config(store, "trust_refresh_hours", doc.String("-6"))
  fake.put_config(store, "alert_days", doc.List([doc.Int(60), doc.Int(-30)]))
  let loaded = settings.load(fake.kazoo(store))
  assert loaded.verify_timeout_ms == 1500
  assert loaded.identity_max_age_s == 60
  assert loaded.renewal_window_days == 30
  assert loaded.trust_refresh_hours == 6
  assert loaded.alert_days == [60, 30, 14]
}

/// The thresholds come from a JSON list as well as from text, and a
/// list with anything but numbers in it is the default rather than a
/// half-read list.
pub fn alert_days_test() {
  let of = fn(value) {
    let store = fake.new()
    fake.put_config(store, "alert_days", value)
    settings.load(fake.kazoo(store)).alert_days
  }
  assert of(doc.List([doc.Int(7), doc.Int(1)])) == [7, 1]
  assert of(doc.List([doc.String("7"), doc.String(" 1 ")])) == [7, 1]
  assert of(doc.String("7,1")) == [7, 1]
  assert of(doc.String("7, 1")) == [7, 1]
  assert of(doc.List([])) == []
  assert of(doc.List([doc.Int(7), doc.Null])) == [60, 30, 14]
  assert of(doc.List([doc.Int(7), doc.Bool(True)])) == [60, 30, 14]
  assert of(doc.String("7,x")) == [60, 30, 14]
  assert of(doc.String("")) == [60, 30, 14]
  assert of(doc.Null) == [60, 30, 14]
  assert of(doc.Int(7)) == [60, 30, 14]
  // A mebibyte of digits is one number and not a crash: Erlang's
  // integers have no width, so the threshold is simply one nothing
  // will ever be below.
  assert list.length(of(doc.String(mutate.huge("7")))) == 1
}

/// The attestation and mode readers over every spelling: only the
/// documented ones are taken, and the case of the letter does not
/// matter for an attestation because the schema's examples are
/// uppercase and an operator types both.
pub fn attestation_spellings_test() {
  let accepted = [
    #("A", "A"),
    #("a", "A"),
    #("B", "B"),
    #("c", "C"),
    #("passthru", "passthru"),
    #("PASSTHRU", "passthru"),
    #("PassThru", "passthru"),
  ]
  list.each(accepted, fn(pair) {
    let #(written, meant) = pair
    let assert Ok(attestation) = settings.attestation_from_string(written)
      as written
    assert settings.attestation_to_string(attestation) == meant as written
  })
  let refused =
    list.flatten([
      mutate.oddities(),
      [
        "A ", " A", "AA", "A,B", "D", "1", "pass-thru", "passthru ", "A\u{0}",
        "\u{202e}A", "Α",
      ],
    ])
  list.each(refused, fn(written) {
    assert settings.attestation_from_string(written) == Error(Nil)
      as { "spelling: " <> mutate.preview(written, 32) }
  })
}

/// The default settings are what a node with no configuration runs on,
/// and they are the safe ones: nothing signs, nothing verifies,
/// account keys are off.
pub fn defaults_are_closed_test() {
  let loaded = settings.load(fake.kazoo(fake.new()))
  assert loaded.sign_enabled == False
  assert loaded.verify_enabled == False
  assert loaded.allow_account_keys == False
  assert loaded.renewal_enabled == False
  assert loaded.verify_mode == settings.Sync
  assert loaded.verify_timeout_ms == 1500
  assert loaded.stipa_api_url == settings.default_stipa_api_url
  assert loaded.alert_days == [60, 30, 14]
}
