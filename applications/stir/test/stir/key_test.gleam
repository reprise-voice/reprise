import gleam/option.{None, Some}
import kazoo/doc
import stir/key

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

pub fn document_round_trip_test() {
  let stored = key.to_doc(sample())
  assert doc.get_string(stored, ["pvt_type"]) == Ok("stir_key")
  assert doc.get_string(stored, ["_id"]) == Ok("0123456789abcdef")
  assert key.from_doc(stored) == Ok(sample())
}

pub fn scope_and_status_names_test() {
  assert key.scope_from_string("system") == key.System
  assert key.scope_from_string("a1") == key.Account("a1")
  assert key.status_from_string("pending") == Ok(key.Pending)
  assert key.status_from_string("nope") == Error(Nil)
  assert key.source_to_string(key.Issued) == "csr"
}

/// The public shape never carries the KEK id or a private field, and a
/// document of another type is not a key.
pub fn public_shape_test() {
  let public = key.to_public(sample())
  assert doc.get(public, ["kek"]) == Error(Nil)
  assert doc.get(public, ["pvt_type"]) == Error(Nil)
  assert doc.get_string(public, ["id"]) == Ok("0123456789abcdef")
  assert key.from_doc(doc.object([#("_id", doc.String("x"))])) == Error(Nil)
}

pub fn days_left_test() {
  assert key.days_left(sample(), 63_900_000_000) == Some(730)
  assert key.days_left(key.Key(..sample(), not_after: None), 0) == None
}
