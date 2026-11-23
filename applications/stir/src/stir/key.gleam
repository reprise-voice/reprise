//// A signing key as the rest of the application sees it: its metadata.
////
//// The private key itself is never part of this value. It lives sealed on
//// the key's document, in a field this type does not carry, and is read
//// only by the signer (`stir/signer`) and the store that seals it
//// (`stir/keys`).
////
//// Everything stored is in Gregorian seconds, as Kazoo stores time; the
//// PASSporT's `iat` is unix seconds and is converted at the edge.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/doc.{type Value}

/// Whose calls a key signs: the platform's, or one reseller account's.
pub type Scope {
  System
  Account(id: String)
}

pub type Status {
  /// A key with no certificate yet: the CSR is waiting to be issued.
  Csr
  /// Certificate attached, not yet signing.
  Pending
  /// The key that signs for its scope.
  Active
  /// Superseded; still served at its `x5u` until `not_after`.
  Retired
}

/// How the key came to be.
pub type Source {
  /// Generated here for a CSR issued elsewhere.
  Issued
  /// Generated here and issued through ACME.
  Acme
  /// Brought in from outside with `sup stir_maintenance import_key`.
  Imported
}

/// One line of the key's audit trail: what happened, when (Gregorian
/// seconds), and the acting account and user (`account/user`, or `sup`).
pub type Event {
  Event(at: Int, what: String, by: String)
}

pub type Key {
  Key(
    kid: String,
    scope: Scope,
    /// `ES256`; nothing else is issued for SHAKEN.
    alg: String,
    spc: String,
    /// Where verifiers fetch the certificate: the URL written into every
    /// PASSporT this key signs.
    x5u: String,
    not_before: Option(Int),
    not_after: Option(Int),
    status: Status,
    source: Source,
    /// `sha256:<hex>` of the leaf certificate, when there is one.
    fingerprint: Option(String),
    /// The first eight hex characters of the SHA-256 of the key-encryption
    /// key the private key is sealed under, so a rotation can tell which
    /// keys still need re-sealing.
    kek: Option(String),
    history: List(Event),
  )
}

pub const doc_type = "stir_key"

/// The fields of a key document this type does not carry, set by
/// `stir/keys` beside the ones `to_doc` writes and kept by its merges:
/// the private key sealed under the key-encryption key (base64), the
/// certificate chain (PEM) once one is issued, and the CSR (PEM) until
/// then. `public_key` is the fourth. A field, not an attachment: one
/// document read answers the key and its material together, and no
/// storage plan can send a field anywhere but the database.
pub const sealed_private_key_field = "sealed_private_key"

pub const certificate_field = "certificate"

pub const csr_field = "csr"

pub fn scope_to_string(scope: Scope) -> String {
  case scope {
    System -> "system"
    Account(id) -> id
  }
}

pub fn scope_from_string(text: String) -> Scope {
  case text {
    "system" -> System
    id -> Account(id)
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    Csr -> "csr"
    Pending -> "pending"
    Active -> "active"
    Retired -> "retired"
  }
}

pub fn status_from_string(text: String) -> Result(Status, Nil) {
  case text {
    "csr" -> Ok(Csr)
    "pending" -> Ok(Pending)
    "active" -> Ok(Active)
    "retired" -> Ok(Retired)
    _ -> Error(Nil)
  }
}

pub fn source_to_string(source: Source) -> String {
  case source {
    Issued -> "csr"
    Acme -> "acme"
    Imported -> "imported"
  }
}

pub fn source_from_string(text: String) -> Result(Source, Nil) {
  case text {
    "csr" -> Ok(Issued)
    "acme" -> Ok(Acme)
    "imported" -> Ok(Imported)
    _ -> Error(Nil)
  }
}

/// The stored document's own fields: never the sealed private key, the
/// certificate or the CSR, which `stir/keys` sets beside them. `_id` is
/// the kid; the private fields are what the data layer expects of a
/// system document.
pub fn to_doc(key: Key) -> Value {
  doc.object([
    #("_id", doc.String(key.kid)),
    #("pvt_type", doc.String(doc_type)),
    #("scope", doc.String(scope_to_string(key.scope))),
    #("alg", doc.String(key.alg)),
    #("spc", doc.String(key.spc)),
    #("x5u", doc.String(key.x5u)),
    #("not_before", optional_int(key.not_before)),
    #("not_after", optional_int(key.not_after)),
    #("status", doc.String(status_to_string(key.status))),
    #("source", doc.String(source_to_string(key.source))),
    #("fingerprint", optional_string(key.fingerprint)),
    #("kek", optional_string(key.kek)),
    #(
      "history",
      doc.List(
        list.map(key.history, fn(event) {
          doc.object([
            #("at", doc.Int(event.at)),
            #("what", doc.String(event.what)),
            #("by", doc.String(event.by)),
          ])
        }),
      ),
    ),
  ])
}

/// A key from its stored document. A document that is not a key answers
/// `Error(Nil)`; a field missing where the type allows it is `None`.
pub fn from_doc(value: Value) -> Result(Key, Nil) {
  use kid <- result.try(doc.get_string(value, ["_id"]))
  use _ <- result.try(case doc.get_string(value, ["pvt_type"]) {
    Ok(t) if t == doc_type -> Ok(Nil)
    _ -> Error(Nil)
  })
  from_row(kid, value)
}

/// A key from a row of the `keys_by_scope` view: the row's id and the
/// value its map function emitted, which carries the fields below and
/// never the material. The view's own filter is what says the row is a
/// key; there is no type to check here.
pub fn from_row(kid: String, value: Value) -> Result(Key, Nil) {
  use status <- result.try(
    doc.get_string(value, ["status"]) |> result.try(status_from_string),
  )
  use source <- result.try(
    doc.get_string(value, ["source"]) |> result.try(source_from_string),
  )
  Ok(Key(
    kid:,
    scope: doc.get_string(value, ["scope"])
      |> result.map(scope_from_string)
      |> result.unwrap(System),
    alg: doc.get_string(value, ["alg"]) |> result.unwrap("ES256"),
    spc: doc.get_string(value, ["spc"]) |> result.unwrap(""),
    x5u: doc.get_string(value, ["x5u"]) |> result.unwrap(""),
    not_before: get_int(value, ["not_before"]),
    not_after: get_int(value, ["not_after"]),
    status:,
    source:,
    fingerprint: option.from_result(doc.get_string(value, ["fingerprint"])),
    kek: option.from_result(doc.get_string(value, ["kek"])),
    history: history(value),
  ))
}

/// The public shape of a key, for an API listing or a `sup` report: the
/// stored document minus its private fields, and never the sealed
/// private key, the certificate or the CSR.
pub fn to_public(key: Key) -> Value {
  doc.object([
    #("id", doc.String(key.kid)),
    #("scope", doc.String(scope_to_string(key.scope))),
    #("alg", doc.String(key.alg)),
    #("spc", doc.String(key.spc)),
    #("x5u", doc.String(key.x5u)),
    #("not_before", optional_int(key.not_before)),
    #("not_after", optional_int(key.not_after)),
    #("status", doc.String(status_to_string(key.status))),
    #("source", doc.String(source_to_string(key.source))),
    #("fingerprint", optional_string(key.fingerprint)),
    #(
      "history",
      doc.List(
        list.map(key.history, fn(event) {
          doc.object([
            #("at", doc.Int(event.at)),
            #("what", doc.String(event.what)),
            #("by", doc.String(event.by)),
          ])
        }),
      ),
    ),
  ])
}

/// Days until `not_after`, at `now` (Gregorian seconds). `None` for a key
/// with no certificate.
pub fn days_left(key: Key, now: Int) -> Option(Int) {
  option.map(key.not_after, fn(at) { { at - now } / 86_400 })
}

fn history(value: Value) -> List(Event) {
  case doc.get(value, ["history"]) {
    Ok(doc.List(items)) ->
      list.filter_map(items, fn(item) {
        case
          get_int(item, ["at"]),
          doc.get_string(item, ["what"]),
          doc.get_string(item, ["by"])
        {
          Some(at), Ok(what), Ok(by) -> Ok(Event(at:, what:, by:))
          _, _, _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn get_int(value: Value, path: List(String)) -> Option(Int) {
  case doc.get(value, path) {
    Ok(doc.Int(n)) -> Some(n)
    Ok(doc.Float(f)) -> Some(float_to_int(f))
    Ok(doc.String(s)) -> option.from_result(int.parse(s))
    _ -> None
  }
}

@external(erlang, "erlang", "trunc")
fn float_to_int(f: Float) -> Int

fn optional_int(value: Option(Int)) -> Value {
  case value {
    Some(n) -> doc.Int(n)
    None -> doc.Null
  }
}

fn optional_string(value: Option(String)) -> Value {
  case value {
    Some(s) -> doc.String(s)
    None -> doc.Null
  }
}
