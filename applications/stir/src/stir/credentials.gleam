//// Write-only credentials: the STI-PA login and the ACME external-account
//// binding, sealed like the keys.
////
//// `set` stores; `status` says which are set and since when; `get` opens
//// one for the code that needs it and answers a `Secret`. No API answers
//// a value.
////
//// One `stir_credentials` document per name, `credential-<name>`, with the
//// value sealed under the document id in its `sealed_value` field, written
//// with the document in one save, so a credential is never on record
//// without its value. They are found through the `credentials_by_name`
//// view, which is the only listing: a document that exists is listed, and
//// a rotation therefore cannot miss one. A name is lowercase letters and
//// underscores; the API's schema narrows that to the four this
//// application uses.

import gleam/list
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error as KazooError, type Kazoo}
import stir/secret.{type Secret}
import stir/store
import stir/system
import stir/vault.{type Vault}

pub type Error {
  Datastore(KazooError)
  NotFound
  Unsealable
  /// The design document is not registered, so nothing can be listed and
  /// an empty answer would be a lie.
  ViewMissing
}

/// A credential's name and when it was set (Gregorian seconds).
pub type Status {
  Status(name: String, set_at: Int, by: String)
}

pub const stipa_user = "stipa_user"

pub const stipa_password = "stipa_password"

pub const acme_eab_kid = "acme_eab_kid"

pub const acme_eab_hmac = "acme_eab_hmac"

pub const doc_type = "stir_credentials"

/// The field the sealed value is: base64 of what `stir/vault` sealed.
pub const sealed_value_field = "sealed_value"

/// The view every listing reads: the credential's name.
pub const view = "stir/credentials_by_name"

pub fn set(
  kz: Kazoo,
  vault: Vault,
  name: String,
  value: Secret,
  by: String,
) -> Result(Status, Error) {
  use _ <- result.try(check_name(name))
  let id = doc_id(name)
  let status = Status(name:, set_at: store.now(kz), by:)
  let document =
    to_doc(status, vault.id(vault))
    |> doc.set(
      [sealed_value_field],
      store.sealed_field(vault.seal(vault, id, value)),
    )
  use _ <- result.try(store.write(kz, document) |> result.map_error(Datastore))
  system.log("credential " <> name <> " set by " <> by)
  Ok(status)
}

/// The value, opened under `vault`. A document with no sealed value, which
/// no write here leaves behind, is as good as none: `NotFound`. One whose
/// sealed value is not a blob at all is `Unsealable`.
pub fn get(kz: Kazoo, vault: Vault, name: String) -> Result(Secret, Error) {
  use _ <- result.try(check_name(name))
  let id = doc_id(name)
  use #(_status, stored) <- result.try(open(kz, name))
  use sealed <- result.try(
    store.sealed(stored, sealed_value_field)
    |> result.map_error(fn(why) {
      case why {
        store.Missing -> NotFound
        store.Damaged -> Unsealable
      }
    }),
  )
  vault.open(vault, id, name, sealed) |> result.replace_error(Unsealable)
}

pub fn delete(kz: Kazoo, name: String, by: String) -> Result(Nil, Error) {
  use _ <- result.try(check_name(name))
  let id = doc_id(name)
  use _ <- result.try(open(kz, name))
  use _ <- result.try(store.delete(kz, id) |> result.map_error(datastore_error))
  system.log("credential " <> name <> " deleted by " <> by)
  Ok(Nil)
}

/// Which credentials are set, by name, from the view.
pub fn status(kz: Kazoo) -> Result(List(Status), Error) {
  use found <- result.try(rows(kz))
  Ok(list.filter_map(found, fn(row) { from_value(row.1) }))
}

/// Re-seal every credential from `old` under `new`, for a rotation; the
/// key store's `rekey` calls this for its count. A credential already
/// sealed under `new` is left alone. Answers how many were re-sealed; one
/// that cannot be re-sealed is a line in `rekey_report`, not the end of
/// the pass.
pub fn rekey(kz: Kazoo, old: Vault, new: Vault) -> Result(Int, Error) {
  rekey_report(kz, old, new).0
}

/// The same pass, with what could not be re-sealed: one line per
/// credential, so that the operator sees them rather than a count that is
/// quietly short.
pub fn rekey_report(
  kz: Kazoo,
  old: Vault,
  new: Vault,
) -> #(Result(Int, Error), List(String)) {
  case rows(kz) {
    Error(error) -> #(Error(error), [])
    Ok(found) -> {
      let #(count, failures) =
        list.fold(found, #(0, []), fn(acc, row) {
          let #(count, failures) = acc
          // The view says which are under `new` already; the save's own
          // read says so again for the ones it is asked about.
          case doc.get_string(row.1, ["kek"]) == Ok(vault.id(new)) {
            True -> acc
            False ->
              case reseal(kz, old, new, row.0) {
                Ok(True) -> #(count + 1, failures)
                Ok(False) -> acc
                Error(why) -> {
                  let line = "credential " <> row.0 <> ": " <> why
                  system.log_error("not re-sealed: " <> line)
                  #(count, [line, ..failures])
                }
              }
          }
        })
      #(Ok(count), list.reverse(failures))
    }
  }
}

/// Why a re-seal wrote nothing.
type NotResealed {
  /// The document says `new` already, or is gone.
  Nothing
  Because(String)
}

/// Whether the credential was re-sealed: `False` when it is already under
/// `new` or its document is gone. The value is opened and replaced inside
/// the save's own read, so two nodes rotating at once cannot open a value
/// one of them has since replaced. A value that opens under neither
/// key-encryption key, or under `new` while the document says otherwise
/// (which the one-save write never leaves behind, so a hand edit), is a
/// failure line.
fn reseal(
  kz: Kazoo,
  old: Vault,
  new: Vault,
  name: String,
) -> Result(Bool, String) {
  let id = doc_id(name)
  let target = vault.id(new)
  let outcome =
    store.update(kz, id, fn(stored) {
      let was = doc.get_string(stored, ["kek"]) |> result.unwrap("none")
      use _ <- result.try(case was == target {
        True -> Error(Nothing)
        False -> Ok(Nil)
      })
      use sealed <- result.try(
        store.sealed(stored, sealed_value_field)
        |> result.map_error(fn(why) {
          Because(case why {
            store.Missing -> "it has no value"
            store.Damaged -> "its value is not a sealed blob"
          })
        }),
      )
      case vault.reseal(old, new, id, name, sealed) {
        vault.Resealed(blob) ->
          Ok(
            stored
            |> doc.set(["kek"], doc.String(target))
            |> doc.set([sealed_value_field], store.sealed_field(blob)),
          )
        vault.UnderNew ->
          Error(Because(
            "its value is sealed under "
            <> target
            <> " already but its document says "
            <> was,
          ))
        vault.OpensUnderNeither ->
          Error(Because(
            "its value opens under neither key-encryption key (marked "
            <> was
            <> ")",
          ))
      }
    })
  case outcome {
    Ok(_saved) -> {
      system.log("credential " <> name <> " re-sealed under " <> target)
      Ok(True)
    }
    Error(store.Rejected(Nothing)) -> Ok(False)
    Error(store.Datastore(kazoo.NotFound)) -> Ok(False)
    Error(store.Rejected(Because(why))) -> Error(why)
    Error(store.Datastore(error)) ->
      Error("its value cannot be written: " <> kazoo.error_to_string(error))
  }
}

/// The status of one credential from its document, and the document.
fn open(kz: Kazoo, name: String) -> Result(#(Status, Value), Error) {
  use stored <- result.try(
    store.open(kz, doc_id(name)) |> result.map_error(datastore_error),
  )
  from_doc(stored)
  |> result.map(fn(status) { #(status, stored) })
  |> result.replace_error(NotFound)
}

pub fn doc_id(name: String) -> String {
  "credential-" <> name
}

fn to_doc(status: Status, kek: String) -> Value {
  doc.object([
    #("_id", doc.String(doc_id(status.name))),
    #("pvt_type", doc.String(doc_type)),
    #("name", doc.String(status.name)),
    #("set_at", doc.Int(status.set_at)),
    #("by", doc.String(status.by)),
    #("kek", doc.String(kek)),
  ])
}

fn from_doc(value: Value) -> Result(Status, Nil) {
  use _ <- result.try(case doc.get_string(value, ["pvt_type"]) {
    Ok(t) if t == doc_type -> Ok(Nil)
    _ -> Error(Nil)
  })
  from_value(value)
}

/// The status from what the view emits, which is the document's `name`,
/// `set_at`, `by` and `kek` and nothing else: never the sealed value.
fn from_value(value: Value) -> Result(Status, Nil) {
  use name <- result.try(doc.get_string(value, ["name"]))
  use set_at <- result.try(doc.get_int(value, ["set_at"]))
  Ok(Status(
    name:,
    set_at:,
    by: doc.get_string(value, ["by"]) |> result.unwrap(""),
  ))
}

/// A name: lowercase letters and underscores, at least one.
pub fn valid_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(c) {
    string.contains(name_alphabet, c)
  })
}

const name_alphabet = "abcdefghijklmnopqrstuvwxyz_"

fn check_name(name: String) -> Result(Nil, Error) {
  case valid_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        Datastore(kazoo.Invalid(
          "a credential name is lowercase letters and underscores",
        )),
      )
  }
}

/// The values the view answers, each with the name it was emitted under.
/// Values, not documents: a document carries the sealed value, which a
/// listing has no use for. A view that is not registered is `ViewMissing`,
/// never an empty listing: a rotation that trusted an empty listing would
/// report that it had re-sealed everything.
fn rows(kz: Kazoo) -> Result(List(#(String, Value)), Error) {
  case kz.datamgr.get_results(store.db, view, kazoo.view_options()) {
    Ok(found) ->
      Ok(
        list.filter_map(found, fn(row) {
          use value <- result.try(doc.get(row, ["value"]))
          use name <- result.try(doc.get_string(value, ["name"]))
          Ok(#(name, value))
        }),
      )
    Error(kazoo.NotFound) -> Error(ViewMissing)
    Error(error) -> Error(Datastore(error))
  }
}

fn datastore_error(error: KazooError) -> Error {
  case error {
    kazoo.NotFound -> NotFound
    other -> Datastore(other)
  }
}
