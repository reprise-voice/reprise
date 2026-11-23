//// The key store: `stir_key` documents in the `stir` database, each
//// carrying its sealed private key, its certificate or its CSR.
////
//// Nothing here answers a private key to anything but the signer: `unseal`
//// is the one reader, and it answers a `Secret`. Every change appends to
//// the document's `history` with who did it.
////
//// Beside the fields `stir/key` knows, a key document carries `public_key`,
//// the `PUBLIC KEY` PEM of the pair, so that a certificate can be matched
//// to its key without opening the private one: attaching a certificate
//// needs no vault; `sealed_private_key`, the private key under the
//// key-encryption key; and `csr` or `certificate`, the PEM. They are
//// fields, written with the document in the one save that creates it, so
//// a key is never on record without its private key and a read is one
//// document. The private key PEM crosses this module as bytes inside a
//// `Secret` and is never a `String` a log line could pick up.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/accounts
import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error as KazooError, type Kazoo}
import kazoo/modb
import stir/alert
import stir/credentials
import stir/key.{type Key, type Scope, Event, Key}
import stir/secret.{type Secret}
import stir/settings
import stir/store
import stir/system
import stir/vault.{type Vault}

pub type Error {
  Datastore(KazooError)
  NotFound
  /// No key-encryption key on this node.
  NoVault
  /// The stored blob could not be opened under this node's KEK.
  Unsealable
  /// The document's sealed private key is not a blob at all: not base64
  /// of anything. No key-encryption key will open it; the key has to be
  /// imported again.
  Damaged
  /// The document is there but its sealed private key is not, so the key
  /// cannot sign and must not be made active.
  NoPrivateKey
  /// The certificate does not belong to the key, is not a chain, or is not
  /// for this key's SPC.
  CertificateMismatch(String)
  /// A transition the status does not allow (activating a `csr` key, or
  /// one whose certificate has expired).
  InvalidTransition
  /// The design document is not registered on the database, so the view
  /// answers nothing. An empty listing would be a lie, and a rotation
  /// that believed it would report that it had re-sealed everything.
  ViewMissing
  /// Another node changed the document while this change was being
  /// written, often enough that the store gave up re-applying it. The
  /// change was not made; nothing was overwritten. Its own variant
  /// because "try again" is the answer to it and to nothing else.
  Conflict
  Crypto(String)
}

/// The view every listing reads: `[scope, status]`.
pub const view = "stir/keys_by_scope"

/// The design document the views live in, read directly when an empty
/// listing has to be told apart from a view that is not there.
pub const design_document = "_design/stir"

/// The cache `select` answers from, and how long an answer is good for:
/// the activation latency across the cluster.
const select_cache = "stir_keys_select"

const select_ttl_ms = 30_000

/// Create a key for `scope` and `spc`: generate it, seal it, store it with
/// status `csr`, and answer the key and its CSR (PEM). `organization` is
/// the subject's `O`, the legal name of the service provider the
/// certificate is for (`csr_organization` in `system_config/stir`, or the
/// request's own); the CSR is refused without one. `x5u_base` is the URL
/// prefix the certificate will be served under; `by` is who asked.
pub fn create(
  kz: Kazoo,
  vault: Vault,
  scope: Scope,
  spc: String,
  organization: String,
  x5u_base: String,
  by: String,
) -> Result(#(Key, String), Error) {
  let kid = store.random_hex(8)
  let pem = generate_ec_key()
  use csr <- result.try(
    csr(pem, string.trim(organization), "SHAKEN " <> spc, spc)
    |> result.map_error(Crypto),
  )
  use public_key <- result.try(public_key_pem(pem) |> result.map_error(Crypto))
  let created =
    Key(
      kid:,
      scope:,
      alg: "ES256",
      spc:,
      x5u: x5u_of(x5u_base, kid),
      not_before: None,
      not_after: None,
      status: key.Csr,
      source: key.Issued,
      fingerprint: None,
      kek: Some(vault.id(vault)),
      history: [Event(at: store.now(kz), what: "created", by:)],
    )
  use created <- result.try(
    write(kz, created, [
      #("public_key", doc.String(public_key)),
      #(key.sealed_private_key_field, sealed_private_key(vault, kid, pem)),
      #(key.csr_field, doc.String(csr)),
    ]),
  )
  system.log(
    "created key "
    <> kid
    <> " for "
    <> key.scope_to_string(scope)
    <> " (spc "
    <> spc
    <> ") by "
    <> by,
  )
  Ok(#(created, csr))
}

/// Bring in an existing key and its certificate chain (both PEM text read
/// from a file on the node by `sup`). Sealed at once; the caller is
/// responsible for the file. Status `pending`, source `imported`.
pub fn import_key(
  kz: Kazoo,
  vault: Vault,
  scope: Scope,
  private_key_pem: Secret,
  chain_pem: String,
  spc: String,
  x5u_base: String,
  by: String,
) -> Result(Key, Error) {
  use pem <- secret.with(private_key_pem)
  use public_key <- result.try(
    public_key_pem(pem)
    |> result.map_error(fn(why) { CertificateMismatch("the key: " <> why) }),
  )
  use _ <- result.try(case certificate_matches_key(chain_pem, pem) {
    True -> Ok(Nil)
    False ->
      Error(CertificateMismatch("the certificate does not belong to the key"))
  })
  use info <- result.try(certificate(chain_pem, spc))
  let kid = store.random_hex(8)
  let now = store.now(kz)
  let imported =
    Key(
      kid:,
      scope:,
      alg: "ES256",
      spc:,
      x5u: x5u_of(x5u_base, kid),
      not_before: Some(info.not_before),
      not_after: Some(info.not_after),
      status: key.Pending,
      source: key.Imported,
      fingerprint: Some(info.fingerprint),
      kek: Some(vault.id(vault)),
      history: [Event(at: now, what: "imported", by:)],
    )
  use imported <- result.try(
    write(kz, imported, [
      #("public_key", doc.String(public_key)),
      #(key.sealed_private_key_field, sealed_private_key(vault, kid, pem)),
      #(key.certificate_field, doc.String(info.pem)),
    ]),
  )
  system.log(
    "imported key "
    <> kid
    <> " (spc "
    <> spc
    <> ", "
    <> info.fingerprint
    <> ") by "
    <> by,
  )
  Ok(imported)
}

/// Attach the issued certificate chain to a `csr` key: it must match the
/// key and carry the SPC. Status becomes `pending`; `not_before`,
/// `not_after` and the fingerprint come from the leaf.
pub fn attach_certificate(
  kz: Kazoo,
  kid: String,
  chain_pem: String,
  by: String,
) -> Result(Key, Error) {
  use #(found, _stored) <- result.try(get_with_doc(kz, kid))
  use _ <- result.try(case found.status {
    key.Csr -> Ok(Nil)
    _ -> Error(InvalidTransition)
  })
  use info <- result.try(certificate(chain_pem, found.spc))
  let now = store.now(kz)
  // The status and the public key are checked again over the document the
  // save is made against, so that a certificate cannot be attached to a
  // key another node changed in the meantime.
  use pending <- result.try(
    saved_key(
      store.update(kz, kid, fn(stored) {
        use current <- result.try(
          key.from_doc(stored) |> result.replace_error(NotFound),
        )
        use _ <- result.try(case current.status {
          key.Csr -> Ok(Nil)
          _ -> Error(InvalidTransition)
        })
        use _ <- result.try(case doc.get_string(stored, ["public_key"]) {
          Ok(public_key) if public_key == info.public_key -> Ok(Nil)
          Ok(_) ->
            Error(CertificateMismatch(
              "the certificate does not belong to the key",
            ))
          Error(Nil) ->
            Error(CertificateMismatch("the key's public key is not on record"))
        })
        // The certificate takes the CSR's place in the same save.
        Ok(
          doc.merge(
            stored,
            key.to_doc(
              Key(
                ..current,
                not_before: Some(info.not_before),
                not_after: Some(info.not_after),
                fingerprint: Some(info.fingerprint),
                status: key.Pending,
                history: append(current, now, "certificate attached", by),
              ),
            ),
          )
          |> doc.set([key.certificate_field], doc.String(info.pem))
          |> doc.delete([key.csr_field]),
        )
      }),
    ),
  )
  system.log(
    "certificate "
    <> info.fingerprint
    <> " attached to key "
    <> kid
    <> " by "
    <> by,
  )
  Ok(pending)
}

/// Make a `pending` key the active one for its scope, retiring the
/// previous active key of that scope. A `retired` key may be activated
/// again, which is how an activation is rolled back.
///
/// A key whose certificate has expired, and one whose sealed private key
/// is not there, are refused: the first would sign tokens no verifier
/// accepts, the second could not sign at all.
///
/// The new key is written first and the previous one retired afterwards,
/// so that a failure in between leaves the scope with a key that signs
/// rather than none. A retirement that fails is logged at error level and
/// the activation still stands; the scope then has two active keys until
/// the next pass, and the monitor's next activation retires the older.
pub fn activate(kz: Kazoo, kid: String, by: String) -> Result(Key, Error) {
  use #(found, stored) <- result.try(get_with_doc(kz, kid))
  let now = store.now(kz)
  use _ <- result.try(activatable(found, now))
  use _ <- result.try(has_private_key(stored))
  use current <- result.try(active(kz, found.scope))
  use activated <- result.try(
    update_key(kz, kid, fn(stored) {
      use _ <- result.try(activatable(stored, now))
      Ok(
        Key(
          ..stored,
          status: key.Active,
          history: append(stored, now, "activated", by),
        ),
      )
    }),
  )
  forget_selection()
  system.log(
    "activated key "
    <> kid
    <> " for "
    <> key.scope_to_string(found.scope)
    <> " by "
    <> by,
  )
  case current {
    Some(previous) if previous.kid != kid -> {
      case
        update_key(kz, previous.kid, fn(stored) {
          case stored.status {
            key.Active ->
              Ok(
                Key(
                  ..stored,
                  status: key.Retired,
                  history: append(
                    stored,
                    now,
                    "retired, superseded by " <> kid,
                    by,
                  ),
                ),
              )
            _ -> Error(InvalidTransition)
          }
        })
      {
        Ok(_) -> {
          forget_selection()
          system.log(
            "retired key " <> previous.kid <> ", superseded by " <> kid,
          )
        }
        Error(error) ->
          system.log_error(
            "key "
            <> kid
            <> " is active for "
            <> key.scope_to_string(found.scope)
            <> ", but "
            <> previous.kid
            <> " could not be retired ("
            <> describe_error(error)
            <> "): the scope has two active keys until one is retired by hand",
          )
      }
      Nil
    }
    _ -> Nil
  }
  Ok(activated)
}

/// Whether a key may be made active now: the status allows it and the
/// certificate has not expired.
fn activatable(found: Key, now: Int) -> Result(Nil, Error) {
  case found.status {
    key.Pending | key.Retired ->
      case found.not_after {
        Some(at) if at <= now -> Error(InvalidTransition)
        _ -> Ok(Nil)
      }
    _ -> Error(InvalidTransition)
  }
}

/// That the sealed private key is on the document. The blob is decoded
/// and dropped: it is never opened here, and no vault is needed to ask.
fn has_private_key(stored: Value) -> Result(Nil, Error) {
  store.sealed(stored, key.sealed_private_key_field)
  |> result.replace(Nil)
  |> result.map_error(unreadable)
}

/// What an unreadable sealed field means for a key: none on the document,
/// or one nothing can open.
fn unreadable(why: store.Unreadable) -> Error {
  case why {
    store.Missing -> NoPrivateKey
    store.Damaged -> Damaged
  }
}

pub fn retire(kz: Kazoo, kid: String, by: String) -> Result(Key, Error) {
  use retired <- result.try(
    update_key(kz, kid, fn(stored) {
      case stored.status {
        key.Active ->
          Ok(
            Key(
              ..stored,
              status: key.Retired,
              history: append(stored, store.now(kz), "retired", by),
            ),
          )
        _ -> Error(InvalidTransition)
      }
    }),
  )
  forget_selection()
  system.log("retired key " <> kid <> " by " <> by)
  Ok(retired)
}

/// Remove a key that is not active.
pub fn delete(kz: Kazoo, kid: String, by: String) -> Result(Nil, Error) {
  use found <- result.try(get(kz, kid))
  use _ <- result.try(case found.status {
    key.Active -> Error(InvalidTransition)
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    store.delete(kz, kid) |> result.map_error(datastore_error),
  )
  forget_selection()
  system.log(
    "deleted key "
    <> kid
    <> " ("
    <> key.status_to_string(found.status)
    <> ") by "
    <> by,
  )
  Ok(Nil)
}

pub fn list(kz: Kazoo) -> Result(List(Key), Error) {
  rows(kz, kazoo.view_options())
}

pub fn get(kz: Kazoo, kid: String) -> Result(Key, Error) {
  get_with_doc(kz, kid) |> result.map(fn(pair) { pair.0 })
}

/// The active key of a scope, if any. Where two nodes activated at once
/// there is more than one and this is the first the view answers;
/// `actives` is what sees the others.
pub fn active(kz: Kazoo, scope: Scope) -> Result(Option(Key), Error) {
  use found <- result.try(actives(kz, scope))
  Ok(option.from_result(list.first(found)))
}

/// Every active key of a scope. A scope with more than one is a scope two
/// nodes activated a key for at the same time, or one whose retirement of
/// the superseded key failed: signing still works, the wrong certificate
/// may be named, and someone has to retire one of them. `status` and
/// `keys` print them all.
pub fn actives(kz: Kazoo, scope: Scope) -> Result(List(Key), Error) {
  let options =
    kazoo.view_options()
    |> kazoo.with_key(
      doc.List([
        doc.String(key.scope_to_string(scope)),
        doc.String(key.status_to_string(key.Active)),
      ]),
    )
  rows(kz, options)
}

/// The key that signs for an account: the first active key found walking
/// the account and its ancestors upward (`accounts.chain`, reversed), else
/// the `system` key.
///
/// With `allow_account_keys` off -- the default, and what a platform that
/// signs everything under one SPC runs -- there are no account keys to
/// find, so the walk is skipped entirely and the `system` scope answered
/// straight from the cache: one cached lookup per call on the outbound
/// path rather than a view query for every account in the chain.
///
/// The cache is per scope and holds 30 seconds, the activation latency
/// across the cluster; a scope with no key caches that too, so an account
/// tree with no keys of its own costs nothing to walk again. Every
/// activation, retirement and deletion on this node clears it.
pub fn select(kz: Kazoo, account_id: String) -> Result(Option(Key), Error) {
  case settings.load(kz).allow_account_keys {
    False -> cached_active(kz, key.System)
    True -> {
      let chain = case accounts.chain(kz, account_id) {
        Ok(chain) -> chain
        Error(_) -> [account_id]
      }
      chain
      |> list.reverse
      |> list.map(key.Account)
      |> list.append([key.System])
      |> first_active(kz, _)
    }
  }
}

/// The active key of one scope, from the cache when it was read less than
/// 30 seconds ago. `None` is cached as well as `Some`.
/// The cached key carries no history: every call copies the entry out
/// of the table, the signing path reads the kid, the status and the
/// `x5u`, and the history only grows.
fn cached_active(kz: Kazoo, scope: Scope) -> Result(Option(Key), Error) {
  let name = key.scope_to_string(scope)
  case cache.get_fresh(select_cache, name, select_ttl_ms) {
    Ok(found) -> Ok(found)
    Error(Nil) -> {
      use found <- result.try(active(kz, scope))
      let found = option.map(found, fn(k) { Key(..k, history: []) })
      cache.put_fresh(select_cache, name, found)
      Ok(found)
    }
  }
}

fn first_active(kz: Kazoo, scopes: List(Scope)) -> Result(Option(Key), Error) {
  case scopes {
    [] -> Ok(None)
    [scope, ..rest] ->
      case cached_active(kz, scope) {
        Ok(Some(found)) -> Ok(Some(found))
        Ok(None) -> first_active(kz, rest)
        Error(error) -> Error(error)
      }
  }
}

/// The certificate chain (PEM) served at the key's `x5u`.
pub fn certificate_pem(kz: Kazoo, kid: String) -> Result(String, Error) {
  use #(found, stored) <- result.try(get_with_doc(kz, kid))
  case found.status {
    key.Csr -> Error(NotFound)
    // Only the certificates, whatever the field holds: a document written
    // before chains were reduced to their certificates may carry more.
    _ ->
      doc.get_string(stored, [key.certificate_field])
      |> result.try(fn(chain) {
        certificates_pem(chain) |> result.replace_error(Nil)
      })
      |> result.replace_error(NotFound)
  }
}

/// The CSR (PEM) of a `csr` key.
pub fn csr_pem(kz: Kazoo, kid: String) -> Result(String, Error) {
  use #(found, stored) <- result.try(get_with_doc(kz, kid))
  case found.status {
    key.Csr ->
      doc.get_string(stored, [key.csr_field]) |> result.replace_error(NotFound)
    _ -> Error(NotFound)
  }
}

/// The private key, opened under this node's KEK. For the signer only.
pub fn unseal(kz: Kazoo, vault: Vault, kid: String) -> Result(Secret, Error) {
  unseal_with_key(kz, vault, kid) |> result.map(fn(pair) { pair.1 })
}

/// The same, with the key the read answered anyway.
///
/// The signer re-reads a key every five minutes to see whether it is
/// still the active one of its scope; the document this call opens
/// carries the sealed private key, so the whole re-read is one datastore
/// read. A document with no sealed private key is `NoPrivateKey`; one
/// whose sealed private key is not a blob at all is `Unsealable`, like
/// one sealed under another key-encryption key.
pub fn unseal_with_key(
  kz: Kazoo,
  vault: Vault,
  kid: String,
) -> Result(#(Key, Secret), Error) {
  use #(found, stored) <- result.try(get_with_doc(kz, kid))
  use sealed <- result.try(
    store.sealed(stored, key.sealed_private_key_field)
    |> result.map_error(unreadable),
  )
  use opened <- result.try(
    vault.open(vault, kid, private_key_label(kid), sealed)
    |> result.replace_error(Unsealable),
  )
  Ok(#(found, opened))
}

/// Alert that a stored key cannot be opened on this node under any
/// key-encryption key it has: `STIR_KEK` and, during a rotation,
/// `STIR_KEK_NEXT` were both tried and neither opened its blob. The key
/// is on record, it is meant to sign, and this node cannot sign with it;
/// that is a condition an operator has to be told about, once a day per
/// key, and not only a line in a log.
///
/// The signer calls it when a re-read ends that way. The key's scope is
/// read for the alert so a reseller's own admins see it too; a scope
/// that cannot be read is no reason not to raise it.
pub fn alert_unsealable(kz: Kazoo, kid: String) -> Nil {
  let scope = case get(kz, kid) {
    Ok(found) -> Some(found.scope)
    Error(_) -> None
  }
  let _ =
    alert.raise_for(
      kz,
      scope,
      "unsealable:" <> kid,
      "a signing key cannot be opened",
      "key "
        <> kid
        <> " is sealed under a key-encryption key "
        <> system.node_name()
        <> " does not have ("
        <> system.kek_variable
        <> " and "
        <> system.kek_next_variable
        <> " were both tried). It cannot sign there, and calls for "
        <> case scope {
        Some(found) -> key.scope_to_string(found)
        None -> "its scope"
      }
        <> " carry no Identity header from that node.",
      metadata(kid, scope, "unsealable"),
      kz.now(),
      alert.default_interval_s,
    )
  Nil
}

/// Alert that a stored key's sealed private key is not a blob at all:
/// a field something rewrote. No key-encryption key will open it, so
/// unlike `alert_unsealable` this does not point at the KEK; the key has
/// to be imported again, or deleted if it is not active. The signer
/// raises it the same way, once a day per key.
pub fn alert_damaged(kz: Kazoo, kid: String) -> Nil {
  let scope = case get(kz, kid) {
    Ok(found) -> Some(found.scope)
    Error(_) -> None
  }
  let _ =
    alert.raise_for(
      kz,
      scope,
      "damaged:" <> kid,
      "a signing key's sealed private key is not readable",
      "key "
        <> kid
        <> "'s sealed private key is not a sealed blob, and no key-encryption key can open it. It cannot sign, and calls for "
        <> case scope {
        Some(found) -> key.scope_to_string(found)
        None -> "its scope"
      }
        <> " carry no Identity header. Import the key again with `sup stir_maintenance import_key`, or delete it if it is not active.",
      metadata(kid, scope, "damaged"),
      kz.now(),
      alert.default_interval_s,
    )
  Nil
}

/// The metadata every alert from the key store carries.
fn metadata(kid: String, scope: Option(Scope), reason: String) -> Value {
  doc.object([
    #("kid", doc.String(kid)),
    #("scope", case scope {
      Some(found) -> doc.String(key.scope_to_string(found))
      None -> doc.Null
    }),
    #("reason", doc.String(reason)),
  ])
}

/// Re-seal every key (and credential) from `old` under `new`, for a
/// rotation. Answers how many were re-sealed. A key already sealed under
/// `new` is left alone; one that cannot be re-sealed is logged, counted
/// as a failure and the pass goes on, so that one unreadable key does not
/// leave the rest of the store behind. `rekey_report` answers those
/// failures as well as the count.
pub fn rekey(kz: Kazoo, old: Vault, new: Vault) -> Result(Int, Error) {
  rekey_report(kz, old, new).0
}

/// The rotation pass, with a line for every key and credential that could
/// not be re-sealed. A pass that finds no keys at all where the design
/// document is not registered is `ViewMissing` rather than a count of
/// nothing: reporting success there would invite the operator to move the
/// key-encryption key and lose every private key.
pub fn rekey_report(
  kz: Kazoo,
  old: Vault,
  new: Vault,
) -> #(Result(Int, Error), List(String)) {
  case list(kz) {
    Error(error) -> #(Error(error), [])
    Ok(all) ->
      case listing_is_real(kz, all) {
        Error(error) -> #(Error(error), [])
        Ok(Nil) -> {
          let #(resealed, failures) =
            list.fold(all, #(0, []), fn(acc, found) {
              let #(count, failures) = acc
              case found.kek == Some(vault.id(new)) {
                True -> acc
                False ->
                  case reseal(kz, old, new, found) {
                    Ok(True) -> #(count + 1, failures)
                    Ok(False) -> acc
                    Error(why) -> {
                      let line = "key " <> found.kid <> ": " <> why
                      system.log_error("not re-sealed: " <> line)
                      #(count, [line, ..failures])
                    }
                  }
              }
            })
          let #(credential_count, credential_failures) =
            credentials.rekey_report(kz, old, new)
          let failures =
            list.append(list.reverse(failures), credential_failures)
          case credential_count {
            Error(error) -> #(Error(credential_error(error)), failures)
            Ok(credentials_resealed) -> {
              system.log(
                "re-sealed "
                <> int.to_string(resealed)
                <> " key(s) and "
                <> int.to_string(credentials_resealed)
                <> " credential(s) under "
                <> vault.id(new)
                <> case failures {
                  [] -> ""
                  _ ->
                    "; "
                    <> int.to_string(list.length(failures))
                    <> " could not be re-sealed"
                },
              )
              #(Ok(resealed + credentials_resealed), failures)
            }
          }
        }
      }
  }
}

/// That a listing of no keys means a store with no keys. The view
/// answering nothing and the design document not being registered look
/// the same from here, so when nothing is listed the design document is
/// read directly.
fn listing_is_real(kz: Kazoo, all: List(Key)) -> Result(Nil, Error) {
  case all {
    [_, ..] -> Ok(Nil)
    [] ->
      case store.open(kz, design_document) {
        Ok(_) -> Ok(Nil)
        Error(kazoo.NotFound) -> Error(ViewMissing)
        Error(error) -> Error(Datastore(error))
      }
  }
}

/// Why a re-seal wrote nothing.
type NotResealed {
  /// The document says `new` already: another pass got there first.
  AlreadySealed
  Because(String)
}

/// Whether the key was re-sealed: `False` when its private key is already
/// sealed under `new`, or its document is gone (a retired key the monitor
/// deleted since the listing holds nothing under the old key). The blob
/// is opened and replaced inside the save's own read, so a rotation
/// running on two nodes at once cannot open a blob one of them has since
/// replaced: whichever save lands second sees the marker already moved
/// and writes nothing. A key that opens under neither key-encryption
/// key, or that is sealed under `new` while its document says otherwise
/// (something the one-save write never leaves behind, so a hand edit), is
/// a failure line, not the end of the pass.
fn reseal(
  kz: Kazoo,
  old: Vault,
  new: Vault,
  found: Key,
) -> Result(Bool, String) {
  let kid = found.kid
  let target = vault.id(new)
  let outcome =
    store.update(kz, kid, fn(stored) {
      use current <- result.try(
        key.from_doc(stored)
        |> result.replace_error(Because("its document is not a key")),
      )
      let was = option.unwrap(current.kek, "none")
      use _ <- result.try(case current.kek == Some(target) {
        True -> Error(AlreadySealed)
        False -> Ok(Nil)
      })
      use sealed <- result.try(
        store.sealed(stored, key.sealed_private_key_field)
        |> result.map_error(fn(why) {
          Because(case why {
            store.Missing -> "it has no private key"
            store.Damaged -> "its private key is not a sealed blob"
          })
        }),
      )
      case vault.reseal(old, new, kid, private_key_label(kid), sealed) {
        vault.Resealed(blob) ->
          Ok(
            doc.merge(
              stored,
              key.to_doc(
                Key(
                  ..current,
                  kek: Some(target),
                  history: append(current, store.now(kz), "re-sealed", "rekey"),
                ),
              ),
            )
            |> doc.set([key.sealed_private_key_field], store.sealed_field(blob)),
          )
        vault.UnderNew ->
          Error(Because(
            "its private key is sealed under "
            <> target
            <> " already but its document says "
            <> was,
          ))
        vault.OpensUnderNeither ->
          Error(Because(
            "its private key opens under neither key-encryption key (marked "
            <> was
            <> ")",
          ))
      }
    })
  case outcome {
    Ok(_saved) -> {
      system.log("re-sealed key " <> kid <> " under " <> target)
      Ok(True)
    }
    Error(store.Rejected(AlreadySealed)) -> Ok(False)
    Error(store.Rejected(Because(why))) -> Error(why)
    Error(store.Datastore(kazoo.NotFound)) -> {
      system.log("key " <> kid <> " was deleted during the rotation")
      Ok(False)
    }
    Error(store.Datastore(error)) ->
      Error(
        "its private key cannot be written: " <> kazoo.error_to_string(error),
      )
  }
}

/// The `x5u` of a key: the base without a trailing slash, the kid, `.pem`.
pub fn x5u_of(x5u_base: String, kid: String) -> String {
  let base = case string.ends_with(x5u_base, "/") {
    True -> string.drop_end(x5u_base, 1)
    False -> x5u_base
  }
  base <> "/" <> kid <> ".pem"
}

//
// The documents.
//

/// The key and the document it came from, for the fields `stir/key` does
/// not carry.
fn get_with_doc(kz: Kazoo, kid: String) -> Result(#(Key, Value), Error) {
  use stored <- result.try(
    store.open(kz, kid) |> result.map_error(datastore_error),
  )
  case key.from_doc(stored) {
    Ok(found) -> Ok(#(found, stored))
    Error(Nil) -> Error(NotFound)
  }
}

/// Write a key's document: the fields the type carries and, beside them,
/// `fields` (the public key, the sealed private key, the CSR or the
/// certificate), set on this first write and kept by the merge on every
/// later one. One save: a key is never on record without its material.
fn write(
  kz: Kazoo,
  found: Key,
  fields: List(#(String, Value)),
) -> Result(Key, Error) {
  let document = doc.merge(key.to_doc(found), doc.object(fields))
  use saved <- result.try(
    store.write(kz, document) |> result.map_error(Datastore),
  )
  key.from_doc(saved) |> result.replace_error(NotFound)
}

/// Change a stored key: the document is read, the change applied to the
/// key that document holds, and the save made against that read, so a
/// change written by another node is a conflict the store retries rather
/// than an overwrite. Every field of the document the key type does not
/// carry (`public_key`, the private fields) survives.
fn update_key(
  kz: Kazoo,
  kid: String,
  change: fn(Key) -> Result(Key, Error),
) -> Result(Key, Error) {
  saved_key(
    store.update(kz, kid, fn(stored) {
      use current <- result.try(
        key.from_doc(stored) |> result.replace_error(NotFound),
      )
      use changed <- result.try(change(current))
      Ok(doc.merge(stored, key.to_doc(changed)))
    }),
  )
}

/// The key an `update` saved, or what went wrong.
fn saved_key(
  answer: Result(Value, store.Failure(Error)),
) -> Result(Key, Error) {
  answer
  |> result.map_error(fn(failure) {
    case failure {
      store.Rejected(error) -> error
      store.Datastore(error) -> datastore_error(error)
    }
  })
  |> result.try(fn(saved) {
    key.from_doc(saved) |> result.replace_error(NotFound)
  })
}

/// What an `Error` means, for a log line. `stir_maintenance` has its own
/// wording for an operator; this is for the lines this module writes.
fn describe_error(error: Error) -> String {
  case error {
    Datastore(inner) -> "datastore: " <> kazoo.error_to_string(inner)
    NotFound -> "no such key"
    NoVault -> "no key-encryption key on this node"
    Unsealable -> "sealed under another key-encryption key"
    Damaged -> "the sealed private key is not a readable blob"
    NoPrivateKey -> "no private key on the document"
    CertificateMismatch(why) -> "certificate mismatch: " <> why
    InvalidTransition -> "the status does not allow that"
    ViewMissing -> "the " <> view <> " view is not registered"
    Conflict -> "another node changed it first"
    Crypto(why) -> "crypto: " <> why
  }
}

fn append(found: Key, at: Int, what: String, by: String) -> List(key.Event) {
  list.append(found.history, [Event(at:, what:, by:)])
}

/// The private key sealed for its document, as the field it is stored in.
fn sealed_private_key(vault: Vault, kid: String, pem: BitArray) -> Value {
  store.sealed_field(vault.seal(
    vault,
    kid,
    secret.new(private_key_label(kid), pem),
  ))
}

fn private_key_label(kid: String) -> String {
  "private key " <> kid
}

/// The keys the view answers, from its values. A row whose value is not
/// a key's is skipped; a view that is not registered is `ViewMissing`,
/// never an empty listing, because everything that reads the store would
/// otherwise take a missing design document for an empty store: the
/// status would say there are no keys, and a rotation would report that
/// it had re-sealed all of them.
///
/// The keys are built from the view's values, never from the documents:
/// a value is the metadata the type carries, a document also carries the
/// sealed private key and the certificate chain, which a listing has no
/// use for and the signing path would otherwise fetch every half minute.
fn rows(kz: Kazoo, options: kazoo.ViewOptions) -> Result(List(Key), Error) {
  case kz.datamgr.get_results(store.db, view, options) {
    Ok(found) ->
      Ok(
        list.filter_map(found, fn(row) {
          use id <- result.try(doc.get_string(row, ["id"]))
          use value <- result.try(doc.get(row, ["value"]))
          key.from_row(id, value)
        }),
      )
    Error(kazoo.NotFound) -> Error(ViewMissing)
    Error(error) -> Error(Datastore(error))
  }
}

/// Forget what `select` has cached on this node: every scope is read from
/// the store again. Every change to a key's status here calls it; the
/// monitor calls it when it reconciles what another node did.
pub fn forget_selection() -> Nil {
  cache.clear(select_cache)
}

fn datastore_error(error: KazooError) -> Error {
  case error {
    kazoo.NotFound -> NotFound
    kazoo.Conflict -> Conflict
    other -> Datastore(other)
  }
}

fn credential_error(error: credentials.Error) -> Error {
  case error {
    credentials.Datastore(inner) -> Datastore(inner)
    credentials.NotFound -> NotFound
    credentials.Unsealable -> Unsealable
    credentials.ViewMissing -> ViewMissing
  }
}

//
// The certificate.
//

/// What the store keeps of a certificate chain: the leaf's validity in
/// Gregorian seconds, its fingerprint and its public key.
type Certificate {
  Certificate(
    not_before: Int,
    not_after: Int,
    fingerprint: String,
    public_key: String,
    /// The chain's certificates and nothing else: what is stored and
    /// served at the `x5u`.
    pem: String,
  )
}

/// The chain parsed, and checked to carry `spc`.
fn certificate(chain_pem: String, spc: String) -> Result(Certificate, Error) {
  use text <- result.try(
    certificate_info(chain_pem) |> result.map_error(CertificateMismatch),
  )
  use info <- result.try(
    doc.parse(text)
    |> result.replace_error(CertificateMismatch("unreadable certificate")),
  )
  use _ <- result.try(case list.contains(doc.strings(info, ["spcs"]), spc) {
    True -> Ok(Nil)
    False ->
      Error(CertificateMismatch(
        "the certificate is not for SPC "
        <> spc
        <> case doc.strings(info, ["spcs"]) {
          [] -> " (it carries no TNAuthList)"
          spcs -> " (it carries " <> string.join(spcs, ", ") <> ")"
        },
      ))
  })
  case
    doc.get_int(info, ["not_before"]),
    doc.get_int(info, ["not_after"]),
    doc.get_string(info, ["fingerprint"]),
    doc.get_string(info, ["public_key_pem"]),
    certificates_pem(chain_pem)
  {
    Ok(not_before), Ok(not_after), Ok(fingerprint), Ok(public_key), Ok(pem) ->
      Ok(Certificate(
        not_before: modb.from_unix(not_before),
        not_after: modb.from_unix(not_after),
        fingerprint:,
        public_key:,
        pem:,
      ))
    _, _, _, _, _ -> Error(CertificateMismatch("unreadable certificate"))
  }
}

//
// The FFI. The private key PEM is a `BitArray` on this side so that it
// never becomes a `String` by accident.
//

@external(erlang, "stir_ffi", "generate_ec_key")
fn generate_ec_key() -> BitArray

@external(erlang, "stir_ffi", "public_key_pem")
fn public_key_pem(private_key_pem: BitArray) -> Result(String, String)

@external(erlang, "stir_ffi", "csr")
fn csr(
  private_key_pem: BitArray,
  org: String,
  cn: String,
  spc: String,
) -> Result(String, String)

@external(erlang, "stir_ffi", "certificate_info")
fn certificate_info(chain_pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "certificates_pem")
fn certificates_pem(pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "certificate_matches_key")
fn certificate_matches_key(chain_pem: String, private_key_pem: BitArray) -> Bool
