//// `sup stir_maintenance ...`
////
//// `sup` calls a module by its literal name with binary arguments, and a
//// Gleam module at the top of `src` compiles to exactly its own name, so
//// these are the operator commands and there is no Erlang wrapper between
//// them and the work.
////
//// Each one prints its report and answers `no_return`, which is what stops
//// `sup` printing the return value underneath it. None of them prints a
//// private key or a credential value: `keys` prints metadata, `csr` a
//// certificate request, `sign` a token.
////
//// Every public function here is something an operator can call with any
//// four binaries they like, so nothing public here takes a typed argument
//// and nothing public here is a helper: what the commands print is in
//// `stir/report`, which `sup` cannot reach and a test can.
////
//// A Gleam function has one arity, so the optional arguments the README
//// lists are spelled out: `new_key <spc> <scope>` and
//// `import_key <key.pem> <chain.pem> <spc> <scope>` take `system` or an
//// account id; `check_x5u <kid>` takes `all` for every active key;
//// `sign <orig> <dest> <attest> <kid>` takes `system` for the active
//// system key; `trust_upload <kind> <file>` takes `ca`, `stipa_root` or
//// `crl`. The two commands that can leave a scope unable to sign,
//// `retire` and `delete`, take a second word: anything but `confirm`
//// prints what the command would do and changes nothing. Every action is
//// recorded in the key's history as `sup`.

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo
import kazoo/modb
import stir/alert
import stir/api
import stir/http
import stir/jws
import stir/key.{type Key}
import stir/keys
import stir/monitor
import stir/passport
import stir/report
import stir/secret
import stir/settings
import stir/signer
import stir/system
import stir/trust
import stir/vault
import stir/x5u

/// What `sup` reads as "printed already".
pub type Done

@external(erlang, "stir_ffi", "no_return")
fn done() -> Done

/// Who `sup` is, in a key's history.
const by = "sup"

/// The second word `retire` and `delete` need before they do anything.
const confirmation = "confirm"

/// How long a fetch from the network may take under `sup`.
const fetch_timeout_ms = 15_000

/// A trust refresh is two fetches.
const refresh_timeout_ms = 30_000

//
// --- status ----------------------------------------------------------------
//

/// What this node knows: the version, the database, the key-encryption
/// key, the settings that decide whether it signs at all, the monitor's
/// last pass, the signer, the keys per scope, the trust material's age.
///
/// It creates nothing: the database is asked about, not ensured, so that
/// reading a status on a node whose datastore is empty does not leave a
/// database behind.
pub fn status() -> Done {
  let kz = system.live()
  let database = case kz.datamgr.db_exists(system.category) {
    True -> "present"
    False ->
      "not there: nothing has created it yet, or the datastore is unreachable"
  }
  let vault_line = case vault.load() {
    Ok(loaded) -> "loaded, id " <> vault.id(loaded)
    Error(error) -> "none: " <> vault.describe_error(error)
  }
  let now = modb.now()
  let key_lines = case keys.list(kz) {
    Error(error) -> ["keys: " <> report.describe_key_error(error)]
    Ok(all) -> ["keys:", ..report.scope_lines(all, now)]
  }
  let trust_lines = case trust.status(kz) {
    Error(trust.NotFound) -> ["trust: nothing fetched yet"]
    Error(error) -> ["trust: " <> describe_trust_error(error)]
    Ok([]) -> ["trust: nothing fetched yet"]
    Ok(statuses) -> ["trust:", ..list.map(statuses, report.trust_line(_, now))]
  }
  report(
    list.flatten([
      [
        "stir " <> system.version() <> " on " <> system.node_name(),
        "database: " <> database,
        "vault: " <> vault_line,
        report.settings_line(settings.load(kz)),
        report.monitor_line(monitor.last_pass()),
      ],
      report.signer_lines(signer.stats()),
      key_lines,
      trust_lines,
    ]),
  )
}

//
// --- keys ------------------------------------------------------------------
//

/// Every key's metadata, and a warning for any scope more than one key
/// is active for.
pub fn keys() -> Done {
  let kz = system.live()
  case keys.list(kz) {
    Error(error) -> report(["keys: " <> report.describe_key_error(error)])
    Ok([]) -> report(["no keys"])
    Ok(all) -> {
      let now = modb.now()
      report(list.append(
        list.flat_map(all, report.describe_key(_, now)),
        report.duplicate_active_warnings(all),
      ))
    }
  }
}

//
// --- new_key, csr, certificate, import_key ---------------------------------
//

/// Generate a key for an SPC and print its CSR. `scope` is `system` or an
/// account id. The CSR's organization is `csr_organization` in
/// `system_config/stir`.
pub fn new_key(spc: String, scope: String) -> Done {
  let kz = system.live()
  let config = settings.load(kz)
  case
    api.x5u_base(config),
    api.csr_organization(doc.object([]), config),
    vault.load()
  {
    Error(Nil), _, _ -> report([no_x5u_base])
    _, Error(Nil), _ -> report([no_csr_organization])
    _, _, Error(error) -> report(["no vault: " <> vault.describe_error(error)])
    Ok(base), Ok(organization), Ok(sealer) ->
      case
        keys.create(
          kz,
          sealer,
          key.scope_from_string(scope),
          spc,
          organization,
          base,
          by,
        )
      {
        Error(error) ->
          report(["not created: " <> report.describe_key_error(error)])
        Ok(#(created, csr)) ->
          report([
            "created key " <> created.kid <> " for " <> scope <> ", spc " <> spc,
            "its certificate will be served at " <> created.x5u,
            csr,
          ])
      }
  }
}

/// Print a `csr` key's CSR again.
pub fn csr(kid: String) -> Done {
  case keys.csr_pem(system.live(), kid) {
    Ok(csr) -> report([csr])
    Error(keys.NotFound) ->
      report([kid <> ": no CSR (not a csr key, or no such key)"])
    Error(error) -> report([kid <> ": " <> report.describe_key_error(error)])
  }
}

/// Attach the issued chain read from a file on this node.
pub fn certificate(kid: String, chain_path: String) -> Done {
  case read_text(chain_path) {
    Error(why) -> report([chain_path <> ": " <> why])
    Ok(chain) ->
      case keys.attach_certificate(system.live(), kid, chain, by) {
        Error(error) ->
          report([kid <> ": " <> report.describe_key_error(error)])
        Ok(pending) ->
          report([
            "certificate attached to " <> kid <> "; the key is pending",
            ..report.describe_key(pending, modb.now())
          ])
      }
  }
}

/// The one-time import of a key and its chain from files on this node.
/// `scope` is `system` or an account id.
///
/// The key file is the one place in this application where a private key
/// exists unsealed outside the signer, so:
///
///   - a key file any other account on the node can read is refused
///     before it is read at all, with the mode it has and the `chmod` to
///     run;
///   - once the bytes have been read, every outcome says to delete the
///     file, as its first line, whether the import worked or not;
///   - an import that worked deletes the file itself and says so.
pub fn import_key(
  key_path: String,
  chain_path: String,
  spc: String,
  scope: String,
) -> Done {
  let kz = system.live()
  case api.x5u_base(settings.load(kz)), vault.load(), private_mode(key_path) {
    Error(Nil), _, _ -> report([no_x5u_base])
    _, Error(error), _ -> report(["no vault: " <> vault.describe_error(error)])
    _, _, Error(why) -> report([key_path <> ": " <> why])
    Ok(base), Ok(sealer), Ok(Nil) ->
      case read_file(key_path) {
        Error(why) -> report([key_path <> ": " <> why])
        // From here the key is in this VM and still on the disk, so every
        // way out of this function says what to do about that.
        Ok(private_key) ->
          case read_text(chain_path) {
            Error(why) ->
              report([delete_now(key_path), chain_path <> ": " <> why])
            Ok(chain) ->
              case
                keys.import_key(
                  kz,
                  sealer,
                  key.scope_from_string(case scope {
                    "" -> "system"
                    given -> given
                  }),
                  secret.new("imported private key", private_key),
                  chain,
                  spc,
                  base,
                  by,
                )
              {
                Error(error) ->
                  report([
                    delete_now(key_path),
                    "not imported: " <> report.describe_key_error(error),
                  ])
                Ok(imported) ->
                  report([
                    forget_key_file(key_path),
                    "imported key " <> imported.kid <> "; the key is pending",
                    ..report.describe_key(imported, modb.now())
                  ])
              }
          }
      }
  }
}

//
// --- activate, retire, delete, rekey ---------------------------------------
//

pub fn activate(kid: String) -> Done {
  case keys.activate(system.live(), kid, by) {
    Ok(activated) -> {
      signer.refresh()
      report([
        "activated " <> kid <> " for " <> key.scope_to_string(activated.scope),
      ])
    }
    Error(error) -> report([kid <> ": " <> report.describe_key_error(error)])
  }
}

/// Retire a key: it stops signing, its certificate is still served until
/// it expires. `confirm` as the second word does it; anything else
/// prints what it would do, including the warning for a scope that would
/// be left with nothing to sign with.
pub fn retire(kid: String, confirm: String) -> Done {
  let kz = system.live()
  let now = modb.now()
  case keys.get(kz, kid), confirm == confirmation {
    Error(error), _ -> report([kid <> ": " <> report.describe_key_error(error)])
    Ok(found), False ->
      report(
        list.flatten([
          ["retiring " <> kid <> " would:"],
          report.describe_key(found, now),
          report.retire_consequences(found, listed(kz), now),
          [report.confirm_line("retire", kid)],
        ]),
      )
    Ok(found), True ->
      case keys.retire(kz, kid, by) {
        Ok(_retired) -> {
          signer.refresh()
          report([
            "retired " <> kid,
            ..report.retire_consequences(found, listed(kz), now)
          ])
        }
        Error(error) ->
          report([kid <> ": " <> report.describe_key_error(error)])
      }
  }
}

/// Delete a key that is not active: the document, the sealed private key
/// and the certificate go. `confirm` as the second word does it;
/// anything else prints what it would do, including the verifiers that
/// may still be fetching the certificate.
pub fn delete(kid: String, confirm: String) -> Done {
  let kz = system.live()
  let now = modb.now()
  // Read the key first: once it is gone there is nothing left to warn
  // about, and a retired key whose certificate is still inside its
  // validity is still being fetched by verifiers.
  case keys.get(kz, kid), confirm == confirmation {
    Error(error), _ -> report([kid <> ": " <> report.describe_key_error(error)])
    Ok(found), False ->
      report(
        list.flatten([
          ["deleting " <> kid <> " would:"],
          report.describe_key(found, now),
          report.delete_consequences(found, listed(kz), now),
          [report.confirm_line("delete", kid)],
        ]),
      )
    Ok(found), True -> {
      let consequences = report.delete_consequences(found, listed(kz), now)
      case keys.delete(kz, kid, by) {
        Ok(Nil) -> {
          signer.refresh()
          report(["deleted " <> kid, ..consequences])
        }
        Error(error) ->
          report([kid <> ": " <> report.describe_key_error(error)])
      }
    }
  }
}

/// Every key, for the warnings; a listing that fails warns about
/// nothing rather than stopping the command.
fn listed(kz: kazoo.Kazoo) -> List(Key) {
  keys.list(kz) |> result.unwrap([])
}

/// Re-seal every key and credential under `STIR_KEK_NEXT`.
///
/// The signer is not told anything: it opens a blob the current KEK
/// cannot open under `STIR_KEK_NEXT` by itself, so a node that has the
/// next value in its environment keeps signing all the way through, and
/// dropping its opened keys here would only make it read them again.
pub fn rekey() -> Done {
  case vault.load(), vault.load_next() {
    Error(error), _ ->
      report(["no current vault: " <> vault.describe_error(error)])
    _, Error(vault.Missing(variable)) ->
      report([
        variable
        <> " is not set, or holds the same key as "
        <> system.kek_variable
        <> ": nothing to re-seal",
      ])
    _, Error(error) ->
      report(["no next vault: " <> vault.describe_error(error)])
    Ok(old), Ok(new) -> {
      let kz = system.live()
      let #(answer, failures) = keys.rekey_report(kz, old, new)
      case answer {
        Error(error) -> {
          rekey_failed(kz, report.describe_key_error(error))
          report([
            "REKEY FAILED: " <> report.describe_key_error(error),
            ..list.append(failures, [do_not_move()])
          ])
        }
        Ok(0) -> {
          rekey_failed(
            kz,
            "nothing moved from " <> vault.id(old) <> " to " <> vault.id(new),
          )
          report(
            list.flatten([
              [
                "NOTHING WAS RE-SEALED: no key and no credential moved from "
                  <> vault.id(old)
                  <> " to "
                  <> vault.id(new)
                  <> ".",
                "either everything was already sealed under "
                  <> vault.id(new)
                  <> ", or the store answered nothing; check `sup stir_maintenance status` and `keys`.",
              ],
              failures,
              [do_not_move()],
            ]),
          )
        }
        Ok(count) -> {
          let resealed =
            "re-sealed "
            <> int.to_string(count)
            <> " item(s) under "
            <> vault.id(new)
          case failures {
            [] ->
              report([
                resealed
                <> ". Signing continues on every node that has "
                <> system.kek_next_variable
                <> " set. Now: set "
                <> system.kek_variable
                <> " to that value, remove "
                <> system.kek_next_variable
                <> ", roll the kazoo_apps pods.",
              ])
            _ ->
              report(
                list.flatten([
                  [
                    resealed,
                    int.to_string(list.length(failures))
                      <> " could not be re-sealed:",
                  ],
                  failures,
                  [do_not_move()],
                ]),
              )
          }
        }
      }
    }
  }
}

//
// --- trust_refresh, trust_upload, monitor_now, check_x5u -------------------
//

/// Fetch the CA list and the CRL from the STI-PA now.
pub fn trust_refresh() -> Done {
  let kz = system.live()
  case
    trust.refresh(
      kz,
      http.real(),
      settings.load(kz).stipa_api_url,
      refresh_timeout_ms,
    )
  {
    Ok(statuses) ->
      report([
        "refreshed:",
        ..list.map(statuses, report.trust_line(_, modb.now()))
      ])
    Error(error) -> report(["not refreshed: " <> describe_trust_error(error)])
  }
}

/// Store trust material read from a file on this node. `kind` is `ca`
/// for an extra call anchor (what `POST /v2/stir/trust {"kind":"ca"}`
/// with no role is), `stipa_root` for the STI-PA root a refresh pins the
/// CA list's and the CRL's signers to, or `crl` for a CRL or the
/// certificate that signs it (`stir/trust.upload`).
pub fn trust_upload(kind: String, path: String) -> Done {
  let kz = system.live()
  let upload = case kind {
    "ca" -> Ok(trust.upload_root(kz, trust.CallRoot, _, by))
    "stipa_root" -> Ok(trust.upload_root(kz, trust.StipaRoot, _, by))
    "crl" -> Ok(trust.upload(kz, trust.Crl, _, by))
    _ -> Error(Nil)
  }
  case upload, read_text(path) {
    Error(Nil), _ ->
      report([kind <> ": the kind is ca, stipa_root or crl; nothing stored"])
    _, Error(why) -> report([path <> ": " <> why])
    Ok(upload), Ok(pem) ->
      case upload(pem) {
        Ok(status) ->
          report([
            "stored " <> path <> " as " <> kind <> ":",
            report.trust_line(status, modb.now()),
          ])
        Error(error) -> report(["not stored: " <> describe_trust_error(error)])
      }
  }
}

/// Run the hourly pass now, and print what it did.
pub fn monitor_now() -> Done {
  case monitor.pass(system.live(), http.real()) {
    [] -> report(["nothing to do"])
    lines -> report(lines)
  }
}

/// Fetch a key's own certificate URL and compare what comes back with the
/// certificate on record. `all` checks every active key.
///
/// The cached copy is dropped first: a check that answered from the
/// day-long cache would say the URL is fine hours after it stopped
/// answering, which is the one thing this command exists to catch.
pub fn check_x5u(kid: String) -> Done {
  let kz = system.live()
  let checked = case kid {
    "all" | "" ->
      keys.list(kz)
      |> result.map(list.filter(_, fn(k) { k.status == key.Active }))
    _ -> keys.get(kz, kid) |> result.map(fn(k) { [k] })
  }
  case checked {
    Error(error) -> report([kid <> ": " <> report.describe_key_error(error)])
    Ok([]) -> report(["no active key to check"])
    Ok(found) -> report(list.map(found, check_one_x5u))
  }
}

fn check_one_x5u(k: Key) -> String {
  x5u.forget(k.x5u)
  k.kid
  <> " at "
  <> k.x5u
  <> ": "
  <> case x5u.fetch(http.real(), k.x5u, fetch_timeout_ms) {
    Error(error) -> "fetch failed: " <> describe_x5u_error(error)
    Ok(pem) ->
      case fingerprint_of(pem), k.fingerprint {
        Error(why), _ -> "not a certificate: " <> why
        Ok(served), Some(recorded) if served == recorded ->
          "ok, serves " <> served
        Ok(served), Some(recorded) ->
          "MISMATCH: serves " <> served <> ", the key has " <> recorded
        Ok(served), None ->
          "serves " <> served <> ", the key has no certificate"
      }
  }
}

//
// --- sign, verify ----------------------------------------------------------
//

/// A PASSporT for a hand test: the `Identity` header value for a call from
/// `orig` to `dest` at attestation `attest`, signed by `kid` (`system` for
/// the active system key).
pub fn sign(orig: String, dest: String, attest: String, kid: String) -> Done {
  let kz = system.live()
  let chosen = case kid {
    "system" | "" ->
      case keys.active(kz, key.System) {
        Ok(Some(k)) -> Ok(k)
        Ok(None) -> Error("no active system key")
        Error(error) -> Error(report.describe_key_error(error))
      }
    _ -> keys.get(kz, kid) |> result.map_error(report.describe_key_error)
  }
  case chosen, report.claims(orig, dest, attest, kz.now(), uuid()) {
    Error(why), _ -> report(["not signed: " <> why])
    _, Error(why) -> report(["not signed: " <> why])
    Ok(k), Ok(claims) ->
      case passport.build(claims, k.x5u, signer.for_key(k.kid)) {
        Ok(identity) ->
          report([
            "signed by "
              <> k.kid
              <> " ("
              <> key.status_to_string(k.status)
              <> ")",
            "Identity: " <> identity,
          ])
        Error(error) -> report(["not signed: " <> describe_jws_error(error)])
      }
  }
}

/// The verdict on an `Identity` header value: the certificate is fetched
/// from its `x5u`, the token verified against it, and the chain validated
/// against the stored trust material.
///
/// A token whose signature is good over a certificate that chains to
/// nothing we trust is not a verified call, and the first line says so:
/// anyone can sign a PASSporT with a key they made this morning.
pub fn verify(identity_header: String) -> Done {
  let kz = system.live()
  case passport.parse_identity(identity_header) {
    Error(error) -> report(["not verified: " <> describe_verify_error(error)])
    Ok(identity) ->
      case x5u.fetch(http.real(), identity.x5u, fetch_timeout_ms) {
        Error(error) ->
          report([
            "not verified: could not fetch "
            <> identity.x5u
            <> ": "
            <> describe_x5u_error(error),
          ])
        Ok(pem) -> {
          let now = kz.now()
          let max_age = settings.load(kz).identity_max_age_s
          let token = case passport.verify(identity, pem, now, max_age) {
            Ok(claims) -> "the token: " <> claims_line(claims, now)
            Error(error) ->
              "the token: not verified: " <> describe_verify_error(error)
          }
          case trust.validate_chain(kz, pem, now) {
            Error(why) ->
              report([
                "NOT verified: the certificate at "
                  <> identity.x5u
                  <> " does not chain to the STI-PA trust material: "
                  <> why,
                "anyone can sign a PASSporT with a certificate of their own; this call is not authenticated",
                token,
              ])
            Ok(Nil) ->
              case passport.verify(identity, pem, now, max_age) {
                Ok(claims) ->
                  report([
                    "verified: " <> claims_line(claims, now),
                    "x5u: " <> identity.x5u,
                    "chain: trusted",
                  ])
                Error(error) ->
                  report([
                    "not verified: " <> describe_verify_error(error),
                    "x5u: " <> identity.x5u,
                    "chain: trusted",
                  ])
              }
          }
        }
      }
  }
}

fn claims_line(claims: passport.Claims, now: Int) -> String {
  "attest "
  <> claims.attest
  <> ", orig "
  <> claims.orig
  <> ", dest "
  <> string.join(claims.dest, ", ")
  <> ", iat "
  <> int.to_string(claims.iat)
  <> " ("
  <> int.to_string(now - claims.iat)
  <> "s ago), origid "
  <> claims.origid
}

//
// --- what an error means ---------------------------------------------------
//

fn describe_trust_error(error: trust.Error) -> String {
  case error {
    trust.Datastore(inner) -> "datastore: " <> kazoo.error_to_string(inner)
    trust.NotFound -> "nothing stored"
    trust.Stipa(inner) -> api.describe_stipa_error(inner)
  }
}

fn describe_x5u_error(error: x5u.Error) -> String {
  case error {
    x5u.BadUrl -> "not an https URL, or an address policy refused it"
    x5u.Fetch(http.Transport(why)) -> why
    x5u.NotACertificate(status) ->
      "answered " <> int.to_string(status) <> " rather than a certificate"
    x5u.TooLarge -> "the answer is above the size a certificate may be"
    x5u.RecentlyFailed -> "a recent fetch failed; not retried yet"
  }
}

fn describe_jws_error(error: jws.Error) -> String {
  case error {
    jws.BadFormat -> "not a compact JWS"
    jws.UnsupportedAlg -> "algorithm is not ES256"
    jws.BadEncoding -> "a JWS part is not base64url JSON"
    jws.BadSignature -> "the signature does not verify"
    jws.SignerFailed(why) -> "signer: " <> why
  }
}

fn describe_verify_error(error: passport.VerifyError) -> String {
  case error {
    passport.MalformedHeader -> "malformed Identity header"
    passport.Jws(inner) -> describe_jws_error(inner)
    passport.NotShaken -> "not a SHAKEN PASSporT"
    passport.X5uMismatch -> "the header's x5u and the info parameter disagree"
    passport.Stale(age) -> "stale: iat is " <> int.to_string(age) <> "s old"
    passport.MissingClaim(claim) -> "claim missing or malformed: " <> claim
  }
}

/// A rotation that re-sealed nothing, or failed outright, is a rotation
/// an operator may be about to follow with a change of `STIR_KEK` that
/// makes every stored key unreadable. The command says so; so does an
/// alert, because the command's output scrolls away.
fn rekey_failed(kz: kazoo.Kazoo, reason: String) -> Nil {
  let _ =
    alert.raise(
      kz,
      "rekey",
      "rekey failed",
      "a key-encryption key rotation on "
        <> system.node_name()
        <> " did not re-seal the store: "
        <> reason
        <> ". Do not change "
        <> system.kek_variable
        <> " until `sup stir_maintenance rekey` reports what it re-sealed.",
      doc.object([
        #("kid", doc.Null),
        #("scope", doc.Null),
        #("reason", doc.String(reason)),
      ]),
      kz.now(),
      3600,
    )
  Nil
}

/// What must not happen while anything is still sealed under the old
/// key-encryption key.
fn do_not_move() -> String {
  "do NOT change "
  <> system.kek_variable
  <> " yet: anything still sealed under the old key would become unreadable"
}

const no_x5u_base = "set x5u_base_url in system_config/stir to the public prefix certificates are served under, e.g. https://api.example.com/v2/stir/certs"

const no_csr_organization = "set csr_organization in system_config/stir to the legal name of the service provider the certificate is for"

//
// --- plumbing --------------------------------------------------------------
//

fn report(lines: List(String)) -> Done {
  io.println(string.join(lines, "\n"))
  done()
}

/// A file's bytes, or why not: `enoent` and `eacces` are different
/// mistakes and an operator should not have to guess which one they made.
fn read_file(path: String) -> Result(BitArray, String) {
  ffi_read_file(path)
}

fn read_text(path: String) -> Result(String, String) {
  use bytes <- result.try(read_file(path))
  bit_array.to_string(bytes) |> result.replace_error("is not text")
}

/// That the key file is not readable by anyone but its owner. A key
/// every account on the node can read is a key the node's other
/// processes, and anything that ever ran as them, have had.
fn private_mode(path: String) -> Result(Nil, String) {
  use mode <- result.try(ffi_file_mode(path))
  case int.bitwise_and(mode, 0o044) {
    0 -> Ok(Nil)
    _ ->
      Error(
        "mode "
        <> octal(mode)
        <> ": the file holds an unencrypted private key and is readable by"
        <> " the group or by everyone. Run `chmod 600 "
        <> path
        <> "` and this command again",
      )
  }
}

/// The permission bits, as `0640`; the file-type bits are not a
/// permission and are left out.
fn octal(mode: Int) -> String {
  "0"
  <> {
    int.to_base_string(int.bitwise_and(mode, 0o7777), 8)
    |> result.unwrap(int.to_string(mode))
  }
}

/// The line every outcome of an import that got as far as reading the
/// key file begins with.
fn delete_now(path: String) -> String {
  "DELETE " <> path <> " NOW: it holds an unencrypted private key"
}

/// The same when the import worked: the file is gone, said as the fact
/// it is, or the instruction again when it could not be removed.
fn forget_key_file(path: String) -> String {
  case ffi_delete_file(path) {
    Ok(Nil) -> "deleted " <> path <> ": it held an unencrypted private key"
    Error(why) ->
      delete_now(path) <> " (it could not be deleted here: " <> why <> ")"
  }
}

fn fingerprint_of(pem: String) -> Result(String, String) {
  use text <- result.try(certificate_info(pem))
  doc.parse(text)
  |> result.try(doc.get_string(_, ["fingerprint"]))
  |> result.replace_error("unreadable certificate")
}

@external(erlang, "stir_ops_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(BitArray, String)

@external(erlang, "stir_ops_ffi", "file_mode")
fn ffi_file_mode(path: String) -> Result(Int, String)

@external(erlang, "stir_ops_ffi", "delete_file")
fn ffi_delete_file(path: String) -> Result(Nil, String)

@external(erlang, "stir_ffi", "certificate_info")
fn certificate_info(chain_pem: String) -> Result(String, String)

@external(erlang, "stir_ffi", "uuid")
fn uuid() -> String
