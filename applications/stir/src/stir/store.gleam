//// The document plumbing the key store, the credential store and the
//// trust store share: the `stir` database, a read-modify-write that
//// cannot lose a concurrent change, a save for a document that is
//// created whole, the shape of a sealed blob on a document, and the clock.
////
//// `update` is what every change to a stored document goes through: it
//// reads, hands the caller what it read, and saves with the revision of
//// that read, so a change written by another node in between is a
//// conflict rather than a silent overwrite. On a conflict it reads again
//// and applies the change to the new document, three times before it
//// gives up. What it carries over from the read is the revision and the
//// private fields the data layer adds.
////
//// `write` is for a document the caller computed whole (a key or a
//// credential being created, or replaced outright). It merges over what
//// is stored, and creates the document when there is none; anything else
//// the read says is an error rather than a blind overwrite.
////
//// Everything a document owns is a field of it: a sealed private key or
//// credential value is base64 text under its name, a certificate or a
//// trust bundle is its PEM. One document read answers the metadata and
//// the material together, one save writes both, and no storage plan gets
//// a say in where the material goes: an attachment is what a plan can
//// send to a bucket, a field is not. Nothing here knows what it stores.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}
import kazoo/modb
import stir/system

/// The database everything lives in.
pub const db = system.category

/// Now, in Gregorian seconds, from the record's clock so that a test can
/// hold time still.
pub fn now(kz: Kazoo) -> Int {
  modb.from_unix(kz.now())
}

pub fn open(kz: Kazoo, id: String) -> Result(Value, Error) {
  kz.datamgr.open_doc(db, id)
}

/// Save `document` over whatever is stored under its id: the stored
/// document's revision is kept, its other fields are replaced member by
/// member by the new ones. A document that is not stored yet is created;
/// a read that fails for any other reason is that failure, not a reason
/// to write over the document blind.
pub fn write(kz: Kazoo, document: Value) -> Result(Value, Error) {
  let id = doc.get_string(document, ["_id"]) |> result.unwrap("")
  case open(kz, id) {
    Ok(stored) -> kz.datamgr.save_doc(db, doc.merge(stored, document))
    Error(kazoo.NotFound) -> kz.datamgr.save_doc(db, document)
    Error(error) -> Error(error)
  }
}

/// What an `update` answers instead of the saved document: the transform
/// refused the document it was given, or the datastore refused the work.
pub type Failure(reason) {
  Rejected(reason)
  Datastore(Error)
}

/// How many times an `update` whose save conflicted reads again and
/// applies the change to what it finds.
const update_attempts = 3

/// Change a stored document: read it, hand it to `transform`, and save
/// what comes back under the revision of that read. A document written by
/// someone else in between makes the save conflict; the read and the
/// transform are then done again over the new document, up to three
/// times, so a change is applied to what is stored rather than to what
/// was stored a moment ago.
///
/// The revision and the private fields of the read are carried over;
/// nothing else of it survives a member the transform set. A document
/// that is not there is `Datastore(NotFound)`: `update` changes
/// documents, `write` creates them.
pub fn update(
  kz: Kazoo,
  id: String,
  transform: fn(Value) -> Result(Value, reason),
) -> Result(Value, Failure(reason)) {
  attempt_update(kz, id, transform, update_attempts)
}

fn attempt_update(
  kz: Kazoo,
  id: String,
  transform: fn(Value) -> Result(Value, reason),
  attempts_left: Int,
) -> Result(Value, Failure(reason)) {
  use stored <- result.try(open(kz, id) |> result.map_error(Datastore))
  use changed <- result.try(transform(stored) |> result.map_error(Rejected))
  case kz.datamgr.save_doc(db, carried_over(stored, changed)) {
    Ok(saved) -> Ok(saved)
    Error(kazoo.Conflict) if attempts_left > 1 -> {
      system.log(
        "a concurrent change to " <> id <> "; reading it again and retrying",
      )
      attempt_update(kz, id, transform, attempts_left - 1)
    }
    Error(error) -> Error(Datastore(error))
  }
}

/// The read's revision on the changed document, and the read's private
/// fields where the change has none of its own.
fn carried_over(stored: Value, changed: Value) -> Value {
  doc.members(stored)
  |> list.filter(fn(member) { carry(member.0) })
  |> list.fold(changed, fn(document, member) {
    let #(name, value) = member
    case name, doc.get(document, [name]) {
      "_rev", _ -> doc.set(document, [name], value)
      _, Ok(_) -> document
      _, Error(Nil) -> doc.set(document, [name], value)
    }
  })
}

fn carry(name: String) -> Bool {
  name == "_rev" || string.starts_with(name, "pvt_")
}

pub fn delete(kz: Kazoo, id: String) -> Result(Nil, Error) {
  kz.datamgr.del_doc(db, id) |> result.replace(Nil)
}

/// A sealed blob as a document field: base64 text. The bytes are what
/// `stir/vault` sealed, nonce and tag included, and mean nothing without
/// the key-encryption key.
pub fn sealed_field(bytes: BitArray) -> Value {
  doc.String(bit_array.base64_encode(bytes, True))
}

/// Why a sealed field could not be read as bytes: there is none, or what
/// is there is not base64 text of anything (an empty string, a null, an
/// object). The two are told apart because they mean different things to
/// a caller: a key with no private key cannot be activated, a key whose
/// private key is damaged is one an operator has to hear about.
pub type Unreadable {
  Missing
  Damaged
}

/// The sealed blob under `name` on a document.
pub fn sealed(document: Value, name: String) -> Result(BitArray, Unreadable) {
  case doc.get(document, [name]) {
    Error(Nil) -> Error(Missing)
    Ok(doc.String(text)) ->
      case bit_array.base64_decode(text) {
        Ok(<<>>) | Error(Nil) -> Error(Damaged)
        Ok(bytes) -> Ok(bytes)
      }
    Ok(_) -> Error(Damaged)
  }
}

/// `n` random bytes as lowercase hex, twice as many characters: a kid.
pub fn random_hex(n: Int) -> String {
  random_bytes(n) |> bit_array.base16_encode |> string.lowercase
}

@external(erlang, "stir_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray
