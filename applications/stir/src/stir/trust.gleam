//// The trust material a verifier needs: the STI-PA's CA list, the CRL and
//// their signers, stored as `stir_trust` documents so every node reads the
//// same and a node with no network still verifies.
////
//// `refresh` is what the monitor runs on its schedule and `sup` on demand.
////
//// **Two kinds of root, and they never mix.** An operator uploads a root
//// for one of two roles. An *STI-PA root* (`upload_root(kz, StipaRoot,
//// ..)`, `POST /v2/stir/trust {"kind":"ca","role":"stipa"}`) pins the
//// STI-PA's own certificates, the CA list's signer and the CRL's, and is
//// never a call anchor. A *call root* (`CallRoot`, `"role":"calls"`) is an
//// extra anchor for a call's certificate chain beside the CA list -- a
//// lab's private CA, an STI-CA the list does not carry yet -- and never
//// pins the STI-PA. They were one `roots` field feeding both sets, which
//// let a lab CA sign a CA list or a CRL this node took, and made the
//// production STI-PA root a call anchor. A `"kind":"ca"` upload that
//// names no role is a call root, and so is `upload(kz, Ca, ..)`: that is
//// the less dangerous mistake, since a call anchor is still held to the
//// leaf checks, where a wrongly pinned STI-PA root can mint CA lists and
//// CRLs.
////
//// **What the STI-PA's own certificates are trusted against.** The roots
//// this application ships *for the STI-PA host the material came from*,
//// plus the uploaded STI-PA roots; never the CA list, which is the
//// document being authenticated and cannot vouch for its own signer, and
//// never a call root. The shipped table (`shipped`) has one entry: the
//// iconectiv **staging** root in `priv/stipa-roots.pem`, for
//// `authenticate-api-stg.iconectiv.com` and no other host. Pinned for
//// every host, it let a production cluster pointed at staging -- or
//// anyone able to answer for the production host with a staging-signed
//// list -- take the staging list and its test STI-CAs as call anchors.
//// For any other host the shipped set is empty: the production STI-PA
//// answered nothing on the network this was built from, and a root
//// nobody verified is worse than none, so before the first refresh
//// against production an operator uploads the production root with the
//// role `stipa`. There is no trust-on-first-use: a signer no pinned root
//// anchors is refused, the stored material is kept, and an alert says
//// so. The host is recorded on what a refresh stores (`stipa_host`), and
//// a verification holds the stored CRL's signer to the shipped roots for
//// that host plus the uploaded STI-PA roots. An uploaded CRL is stored
//// as from the host `stipa_api_url` names, and held to the same.
////
//// **A root upload is roots, and only roots.** It writes the field for
//// its role and nothing else: not the other role's, not the bundle, not
//// `source`, not `detail`, not `fetched_at`. It used to write the bundle
//// as well, which meant that pinning a root replaced the CA list with one
//// certificate and left inbound verification failing "no trust anchor"
//// until the next refresh -- up to `trust_refresh_hours` -- and cleared
//// the sequence the rollback check reads, which let one replayed list
//// through. The sequence lives in its own member, `sequence`, which no
//// upload touches. The upload is cut down to its `CERTIFICATE` blocks
//// before it is stored, so a private key pasted in beside them is not
//// kept, and every certificate in it is checked: one `public_key` cannot
//// read, or one that is neither a CA certificate nor self-signed, refuses
//// the whole upload. Who uploaded which role and when is on the document
//// (`stipa_roots_by`, `stipa_roots_at`, `call_roots_by`, `call_roots_at`),
//// and each certificate's subject and fingerprint goes to the log.
////
//// **A document from before the roles** has a `roots` field. It is read
//// as call roots and never as a pin, because nothing says which role it
//// was meant for and the dangerous reading must not be the default: if it
//// held the production STI-PA root, the next refresh against production
//// is refused (`no-pinned-root`, `signer-untrusted`, whose text says why)
//// until the root is uploaded again with the role `stipa`. A call-root
//// upload replaces it.
////
//// **A CRL is authenticated before it is stored**, by the checks a
//// verification makes of it (`stir_ffi:authenticate_crl`): the signature
//// is its signer's, the signer is the CRL's issuer, carries `cRLSign` and
//// chains to the STI-PA pins above, and `thisUpdate <= now <= nextUpdate`.
//// A CRL older than the stored one from the same STI-PA host -- an
//// earlier `thisUpdate`, or for the same `thisUpdate` a lower `cRLNumber`;
//// the same is fine -- is refused too: a genuine CRL still inside its
//// window, played back, is how a certificate revoked since verifies as
//// checked. CRLs from different hosts are not compared, since their
//// numbers order different issuers. A CRL that passed carries
//// `authenticated`; one without it (stored before CRLs were checked, or
//// uploaded ahead of its signer) is not used for the revocation check,
//// and calls are verified and marked unchecked. A CRL and its signer
//// uploaded in one file replace both, which is how a rotated CRL signer
//// is taken by hand. On a refusal the stored CRL is
//// kept, the refusal is logged and alerted as `trust:crl-refused`, and
//// the CA list half of the refresh goes ahead. Checking per call alone
//// was not enough: a bad CRL, stored, made every verification refuse
//// until the next refresh, and an expired one turned revocation off. An
//// uploaded CRL is held to the same checks when its signer is stored
//// already, and a signer uploaded after its CRL to authenticating the
//// stored one: the two may come in either order, and whichever comes
//// second is where the pair is checked. `this_update` and `crl_number`
//// are kept on `trust-crl` for the next comparison, once authenticated.
////
//// **A CRL that is missing or past its `nextUpdate` does not fail the
//// call.** Verification goes ahead without the revocation check, says so
//// in what it answers (`validate_chain_report`, `revocation_checked`),
//// logs at error level and alerts hourly under `trust:crl`. That is
//// a deliberate choice: an STI-PA outage that fails every inbound call
//// closed is a worse outage than a day of unchecked revocation, and the
//// condition is loud rather than silent. The inbound path records
//// `STIR-Revocation: unchecked` on such a call.
////
//// Two documents in the `stir` database, `trust-ca` and `trust-crl`, each
//// with `kind`, `fetched_at` (Gregorian seconds), `source` (`stipa` or
//// `upload`), `detail` (the list's sequence, the CRL's next update in
//// unix seconds) and, from a refresh, `stipa_host`. The PEM is the
//// document's `bundle` field; the certificate that signed it is `signer`:
//// the list signer's chain on `trust-ca`, the CRL signer's on
//// `trust-crl`. `trust-ca` also carries `stipa_roots` and `call_roots`
//// when an operator uploaded any. Fields, not attachments: the one
//// cached document read a verification makes answers all of them, and
//// no storage plan can send them anywhere but the database.
////
//// **What a refresh refuses.** A list whose `exp` has passed, a list
//// whose `sequence` is below the stored one (a replay is how a revoked
//// certificate comes back), and a signer that does not chain to a pinned
//// root: each is logged and alerted about, and nothing is stored. A CRL
//// that does not authenticate, or is older than the stored one, is
//// refused the same way, and the list is stored without it.
////
//// **The CRL and the CA list are fetched before either is stored.** A
//// CRL that did not come must not stamp the CA document into freshness:
//// that used to buy the failure an hour of silence on every pass. The
//// stored CRL is kept instead, the next pass tries again, and an alert
//// goes out when there is no stored CRL or when the stored one is inside
//// its last hour -- which is also what a CA list that could not be
//// fetched at all raises, since the effect on a verifier is the same.
////
//// The CRL's URL is the CRL distribution point of every SHAKEN
//// certificate; the STI-PA publishes it at `<base>/download/v1/crl`, which
//// is the one path used here, so a refresh needs no certificate to start
//// from.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import kazoo/cache
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error as KazooError, type Kazoo}
import kazoo/modb
import stir/alert
import stir/http.{type Transport}
import stir/settings
import stir/stipa
import stir/system

pub type Error {
  Datastore(KazooError)
  Stipa(stipa.Error)
  NotFound
}

pub type Kind {
  Ca
  Crl
}

/// What an uploaded root is for. The two never stand in for each other.
pub type Role {
  /// Pins the STI-PA's own certificates: the CA list's signer and the
  /// CRL's. Never a call anchor.
  StipaRoot
  /// An extra anchor for a call's certificate chain, beside the CA list.
  /// Never an STI-PA pin.
  CallRoot
}

pub type Status {
  Status(
    kind: Kind,
    /// Gregorian seconds.
    fetched_at: Int,
    /// `stipa`, `upload`.
    source: String,
    /// The CA list's sequence, or the CRL's next update (unix seconds).
    detail: Option(Int),
  )
}

/// What a chain validation did, beyond whether it passed. A call the
/// revocation check could not be run for is verified and marked, not
/// refused; `crl_age_s` is how old the stored CRL was, in seconds, or
/// `None` when there was none at all.
pub type Validation {
  Validation(revocation_checked: Bool, crl_age_s: Option(Int))
}

pub const doc_type = "stir_trust"

/// The PEM fields of a trust document.
pub const bundle_field = "bundle"

pub const signer_field = "signer"

/// The STI-PA roots an operator uploaded, on `trust-ca`. A refresh never
/// writes it, so what an operator pinned outlives the list that replaces
/// the bundle.
pub const stipa_roots_field = "stipa_roots"

/// The call roots an operator uploaded, on `trust-ca`; a refresh never
/// writes it either.
pub const call_roots_field = "call_roots"

/// The one roots field of a document written before the roles: read as
/// call roots, never as a pin.
pub const legacy_roots_field = "roots"

/// The STI-PA host a refresh fetched the document's material from.
pub const stipa_host_field = "stipa_host"

/// On `trust-crl`, what the stored CRL says of itself once authenticated:
/// its `thisUpdate` (unix seconds) and its `cRLNumber`, which the next CRL
/// must not be below.
pub const this_update_field = "this_update"

pub const crl_number_field = "crl_number"

/// True on a `trust-crl` whose CRL passed `stir_ffi:authenticate_crl`
/// against the signer stored beside it. A CRL without it -- stored before
/// CRLs were checked, or uploaded before its signer -- is not used for
/// the revocation check: calls are verified and marked unchecked.
pub const authenticated_field = "authenticated"

/// Where the STI-PA publishes the indirect CRL, under its API base.
pub const crl_path = "/download/v1/crl"

/// The iconectiv staging STI-PA.
pub const staging_host = "authenticate-api-stg.iconectiv.com"

/// The staging root, shipped under `priv`.
pub const roots_file = "stipa-roots.pem"

/// The roots this application ships, by the STI-PA host they pin: a host
/// not in here has none, and pins only what an operator uploaded with the
/// role `stipa`. A root is added by adding its file under `priv` and its
/// host here, never by adding it to another host's file.
const shipped = [#(staging_host, roots_file)]

/// A stored CRL this close to its `nextUpdate` with no refresh in sight
/// is worth waking someone for: revocation stops being checked when it
/// passes.
const crl_alert_window_s = 3600

/// The dedupe every "the CRL is not what it should be" alert shares, so
/// an STI-PA outage is one alert an hour and not one per condition.
const crl_dedupe = "trust:crl"

/// A fetched CRL that was refused: not an outage but a CRL somebody
/// should look at, so a dedupe of its own beside the list's refusals
/// (`refuse` prefixes `trust:`).
const crl_refused_dedupe = "crl-refused"

/// The pinned roots, parsed once per node.
const roots_table = "stir_trust_roots"

/// What the call path has already said recently, so a condition that
/// holds for an hour is an hour of lines and not a line per call.
const log_table = "stir_trust_log"

const log_interval_s = 60

const certificate_marker = "-----BEGIN CERTIFICATE-----"

const certificate_end = "-----END CERTIFICATE-----"

const crl_marker = "-----BEGIN X509 CRL-----"

pub fn kind_to_string(kind: Kind) -> String {
  case kind {
    Ca -> "ca"
    Crl -> "crl"
  }
}

/// The role as the API spells it.
pub fn role_to_string(role: Role) -> String {
  case role {
    StipaRoot -> "stipa"
    CallRoot -> "calls"
  }
}

fn doc_id(kind: Kind) -> String {
  "trust-" <> kind_to_string(kind)
}

/// Fetch the CA list and the CRL from the STI-PA and store both.
///
/// The CA list is checked before anything is written and the CRL is
/// fetched and authenticated before anything is written, so a refusal
/// or a failed CRL leaves the store as it was. A CRL that did not come,
/// or was refused, answers `Ok` with the CA list's status alone: the
/// list is good, and the caller says the CRL was kept.
pub fn refresh(
  kz: Kazoo,
  transport: Transport,
  stipa_base_url: String,
  timeout_ms: Int,
) -> Result(List(Status), Error) {
  let host = host_of(stipa_base_url)
  use ca_list <- result.try(
    case stipa.ca_list(transport, stipa_base_url, [], timeout_ms) {
      Ok(ca_list) -> Ok(ca_list)
      Error(why) -> {
        list_not_fetched(kz, why)
        Error(Stipa(why))
      }
    },
  )
  use _ <- result.try(check_expiry(kz, ca_list))
  use _ <- result.try(check_sequence(kz, ca_list))
  use _ <- result.try(check_signer(kz, host, ca_list.signer))
  let fetched_crl = stipa.crl(transport, stipa_base_url <> crl_path, timeout_ms)
  use ca <- result.try(
    store(
      kz,
      Ca,
      bundle: Some(string.join(ca_list.certificates, "")),
      signer: Some(ca_list.signer),
      source: "stipa",
      by: None,
      detail: Set(ca_list.sequence),
      sequence: Some(ca_list.sequence),
      facts: [#(stipa_host_field, Some(doc.String(host)))],
    ),
  )
  system.log(
    "trust: stored the STI-PA CA list, sequence "
    <> int.to_string(ca_list.sequence)
    <> ", "
    <> int.to_string(list.length(ca_list.certificates))
    <> " certificate(s)",
  )
  case fetched_crl {
    Error(why) -> {
      crl_not_refreshed(kz, why)
      Ok([ca])
    }
    Ok(crl) ->
      case newer_authentic_crl(kz, crl.pem, crl.signer, host) {
        Error(why) -> {
          crl_refused(kz, why)
          Ok([ca])
        }
        Ok(facts) -> {
          use crl_status <- result.try(
            store(
              kz,
              Crl,
              bundle: Some(crl.pem),
              signer: Some(crl.signer),
              source: "stipa",
              by: None,
              detail: Set(crl.next_update),
              sequence: None,
              facts: [
                #(stipa_host_field, Some(doc.String(host))),
                ..crl_facts(Some(facts))
              ],
            ),
          )
          system.log(
            "trust: stored the STI-PA CRL, next update "
            <> kazoo.iso8601(crl.next_update),
          )
          Ok([ca, crl_status])
        }
      }
  }
}

/// Store what an operator supplied.
///
/// A CA upload is a call root: `upload_root(kz, CallRoot, ..)`, which is
/// also what `POST /v2/stir/trust {"kind":"ca"}` with no role is. A CRL
/// upload is the CRL, and its `nextUpdate` is read out of it so a hand
/// upload does not make every pass refetch; given a certificate instead,
/// it is the CRL's signer, which an uploaded CRL does not come with and
/// without which nothing validates. Whichever of the two comes second is
/// checked against the other before it is stored (the module doc).
pub fn upload(
  kz: Kazoo,
  kind: Kind,
  pem: String,
  by: String,
) -> Result(Status, Error) {
  case kind {
    Ca -> upload_root(kz, CallRoot, pem, by)
    Crl -> upload_crl(kz, pem, by)
  }
}

/// Store the roots an operator supplied for a role: the field for that
/// role and nothing else, replacing what it held -- not the other role's
/// roots, not the bundle, the source, the sequence or the fetch time.
pub fn upload_root(
  kz: Kazoo,
  role: Role,
  pem: String,
  by: String,
) -> Result(Status, Error) {
  use text <- result.try(upload_text(pem))
  use blocks <- result.try(
    certificate_blocks(text)
    |> result.map_error(fn(why) { Stipa(stipa.Malformed(why)) }),
  )
  use described <- result.try(
    list.try_map(blocks, root_certificate)
    |> result.map_error(fn(why) { Stipa(stipa.Malformed(why)) }),
  )
  store_roots(kz, role, string.concat(blocks), by, described)
}

/// An upload is held to the pins of the STI-PA host this cluster is set
/// to (`stipa_api_url`) plus the uploaded STI-PA roots, which is what a
/// refresh from that host would be held to, and is stored as from that
/// host so that verification holds it to the same.
fn upload_crl(kz: Kazoo, pem: String, by: String) -> Result(Status, Error) {
  use text <- result.try(upload_text(pem))
  let host = host_of(settings.load(kz).stipa_api_url)
  let stored_crl = stored(kz, Crl) |> result.unwrap(None)
  let signer_in_upload = case certificate_blocks(text) {
    Ok(blocks) -> Some(string.concat(blocks))
    Error(_why) -> None
  }
  case stipa.crl_only(text), signer_in_upload {
    // A CRL, with its signer in the same file or with one already stored.
    // The two together are how an operator replaces both when the STI-PA
    // has rotated its CRL signer: neither can be checked against the
    // other one stored.
    Ok(crl), _ -> {
      let signer = case signer_in_upload {
        Some(signer) -> Some(signer)
        None -> option.then(stored_crl, present(_, signer_field))
      }
      use facts <- result.try(case signer {
        None -> Ok(None)
        Some(signer) ->
          newer_authentic_crl(kz, crl, signer, host)
          |> result.map(Some)
          |> result.map_error(upload_refused(_, "the uploaded CRL"))
      })
      store(
        kz,
        Crl,
        bundle: Some(crl),
        signer: signer_in_upload,
        source: "upload",
        by: Some(by),
        detail: case stipa.crl_next_update(crl) {
          Ok(next_update) -> Set(next_update)
          Error(Nil) -> Clear
        },
        sequence: None,
        facts: [#(stipa_host_field, Some(doc.String(host))), ..crl_facts(facts)],
      )
    }
    // A certificate under the CRL kind is the indirect CRL's signer; the
    // stored CRL and its next update stay as they were, once the stored
    // CRL is shown to be one this signer signed.
    Error(Nil), Some(signer) -> {
      use facts <- result.try(
        case option.then(stored_crl, present(_, bundle_field)) {
          None -> Ok(crl_facts(None))
          Some(crl) ->
            authentic_crl(kz, crl, signer, host)
            |> result.map(fn(facts) { crl_facts(Some(facts)) })
            |> result.map_error(upload_refused(
              _,
              "the stored CRL, checked against the uploaded signer,",
            ))
        },
      )
      store(
        kz,
        Crl,
        bundle: None,
        signer: Some(signer),
        source: "upload",
        by: Some(by),
        detail: Keep,
        sequence: None,
        facts: [#(stipa_host_field, Some(doc.String(host))), ..facts],
      )
    }
    Error(Nil), None ->
      Error(
        Stipa(stipa.Malformed("the upload holds no " <> crl_marker <> " block")),
      )
  }
}

fn upload_text(pem: String) -> Result(String, Error) {
  case utf8(pem) {
    False ->
      Error(Stipa(stipa.Malformed("the upload is not text, let alone a PEM")))
    True -> Ok(string.trim(pem) <> "\n")
  }
}

fn upload_refused(why: String, what: String) -> Error {
  system.log_error("trust: " <> what <> " was refused: " <> why)
  Stipa(stipa.Untrusted(why))
}

/// The stored PEM bundle of a kind, for a verifier or the public route.
pub fn pem(kz: Kazoo, kind: Kind) -> Result(String, Error) {
  field(kz, kind, bundle_field)
}

/// Whether there is a bundle of that kind at all: what makes a refresh
/// due whatever the clock says.
pub fn bundle_stored(kz: Kazoo, kind: Kind) -> Bool {
  case pem(kz, kind) {
    Ok(text) -> text != ""
    Error(_why) -> False
  }
}

/// Whether a CRL a refresh stored has been authenticated. One stored
/// before CRLs were checked has not, so verification runs without the
/// revocation check (`usable_crl`) and the leader's next pass replaces it.
/// An uploaded CRL waiting for its signer is the operator's to complete,
/// and does not count here.
pub fn crl_authenticated(kz: Kazoo) -> Bool {
  case stored(kz, Crl) {
    Ok(Some(document)) ->
      doc.get_string(document, ["source"]) != Ok("stipa")
      || is_authenticated(document)
    _ -> True
  }
}

fn is_authenticated(document: Value) -> Bool {
  doc.get_bool(document, [authenticated_field]) == Ok(True)
}

/// The roots an operator uploaded, per role, as `GET /v2/stir/trust`
/// reports them on the `ca` row: how many certificates each role holds,
/// who uploaded them and when. `legacy` is the field from before roots had
/// a role; it anchors calls only, and an STI-PA root left in it no longer
/// pins the STI-PA until uploaded again with the role `stipa`.
pub type RootSet {
  RootSet(role: String, count: Int, by: Option(String), at: Option(Int))
}

pub fn root_sets(kz: Kazoo) -> List(RootSet) {
  case stored(kz, Ca) {
    Ok(Some(document)) ->
      [
        #("stipa", stipa_roots_field),
        #("calls", call_roots_field),
        #("legacy", legacy_roots_field),
      ]
      |> list.filter_map(fn(pair) {
        let #(role, field) = pair
        case present(document, field) {
          None -> Error(Nil)
          Some(pem) ->
            Ok(RootSet(
              role:,
              count: list.length(string.split(pem, certificate_marker)) - 1,
              by: present(document, field <> "_by"),
              at: option.from_result(doc.get_int(document, [field <> "_at"])),
            ))
        }
      })
    _ -> []
  }
}

pub fn status(kz: Kazoo) -> Result(List(Status), Error) {
  use ca <- result.try(status_of(kz, Ca))
  use crl <- result.try(status_of(kz, Crl))
  Ok(option.values([ca, crl]))
}

/// Validate a certificate chain (PEM) against the stored CA list and the
/// stored CRL at `now` (unix seconds). `Ok(Nil)` or why not.
pub fn validate_chain(
  kz: Kazoo,
  chain_pem: String,
  now: Int,
) -> Result(Nil, String) {
  validate_chain_report(kz, chain_pem, now) |> result.replace(Nil)
}

/// The same, and what the revocation check did.
///
/// The chain anchors in the stored CA list and the call roots; the CRL's
/// own signer anchors in the STI-PA pins for the host the CRL came from,
/// which is a set of its own because the STI-PA's root is not in the list
/// the STI-PA publishes and the list must not be able to vouch for the
/// CRL.
///
/// A CRL that is missing, or past its `nextUpdate`, is not a reason to
/// fail a call: the chain is validated without one, `revocation_checked`
/// says so, and the condition is logged and alerted. Anything else the
/// checker refuses -- a revoked certificate, a CRL whose signature does
/// not verify, a CRL with no signer stored -- is a refusal.
pub fn validate_chain_report(
  kz: Kazoo,
  chain_pem: String,
  now: Int,
) -> Result(Validation, String) {
  // Each document once: the bundle and the roots come off one read, the
  // CRL, its signer and its host off the other, so a refresh landing
  // meanwhile cannot pair a new CRL with the previous signer.
  let ca = stored(kz, Ca) |> result.unwrap(None)
  let crl = stored(kz, Crl) |> result.unwrap(None)
  case call_anchors(ca) {
    Error(Nil) ->
      Error(
        "no trust material stored: refresh the CA list, or upload a root with POST /v2/stir/trust",
      )
    Ok(bundle) -> {
      let anchors = stipa_anchors(ca, crl_host(crl))
      let age = crl_age_s(crl, now)
      case usable_crl(crl, now) {
        Error(why) -> {
          revocation_unchecked(kz, why, now)
          use _ <- result.try(validate(chain_pem, bundle, "", "", anchors, now))
          Ok(Validation(revocation_checked: False, crl_age_s: age))
        }
        Ok(#(crl, signer)) ->
          case validate(chain_pem, bundle, crl, signer, anchors, now) {
            Ok(Nil) -> Ok(Validation(revocation_checked: True, crl_age_s: age))
            // The checker reads the CRL's own `nextUpdate`, which can
            // disagree with what the document says it was; either way a
            // stale CRL is an unchecked call, not a failed one.
            Error("CRL stale") -> {
              revocation_unchecked(
                kz,
                "the stored CRL is past its next update",
                now,
              )
              use _ <- result.try(validate(
                chain_pem,
                bundle,
                "",
                "",
                anchors,
                now,
              ))
              Ok(Validation(revocation_checked: False, crl_age_s: age))
            }
            Error(why) -> Error(why)
          }
      }
    }
  }
}

fn validate(
  chain_pem: String,
  bundle: String,
  crl: String,
  crl_signer: String,
  anchors: String,
  now: Int,
) -> Result(Nil, String) {
  ffi_validate_chain_with_anchors(
    chain_pem,
    bundle,
    crl,
    crl_signer,
    anchors,
    now,
  )
}

/// The stored CRL and its signer, off the `trust-crl` document, when
/// there is one worth using, or why there is not.
fn usable_crl(
  crl: Option(Value),
  now: Int,
) -> Result(#(String, String), String) {
  case crl {
    None -> Error("there is no stored CRL at all")
    Some(document) ->
      case pem_of(document, bundle_field) {
        None -> Error("there is no stored CRL at all")
        Some(pem) -> {
          let status = from_doc(Crl, document)
          case status.detail, is_authenticated(document) {
            Some(next_update), _ if next_update <= now ->
              Error("the stored CRL expired at " <> kazoo.iso8601(next_update))
            // Never shown to be signed by the signer beside it under the
            // pins of the host it came from: stored before CRLs were
            // checked, or uploaded before its signer. Refusing every call
            // over that would be an outage an upgrade or a half-finished
            // upload made; it is an unchecked call, like a stale CRL.
            _, False ->
              Error(
                "the stored CRL has not been authenticated (stored before CRLs were checked, or uploaded without its signer)",
              )
            _, True ->
              Ok(#(pem, pem_of(document, signer_field) |> option.unwrap("")))
          }
        }
      }
  }
}

fn pem_of(document: Value, name: String) -> Option(String) {
  option.from_result(doc.get_string(document, [name]))
}

/// A string field that holds something.
fn present(document: Value, name: String) -> Option(String) {
  case pem_of(document, name) {
    Some("") -> None
    other -> other
  }
}

/// The STI-PA host the stored CRL came from; `None` for an uploaded one,
/// and for one stored before hosts were recorded.
fn crl_host(crl: Option(Value)) -> Option(String) {
  option.then(crl, present(_, stipa_host_field))
}

fn stored_crl_next_update(kz: Kazoo) -> Option(Int) {
  case status_of(kz, Crl) {
    Ok(Some(crl)) -> crl.detail
    _ -> None
  }
}

/// How long ago the stored CRL was fetched, in seconds; `None` when
/// there is no CRL document at all.
fn crl_age_s(crl: Option(Value), now: Int) -> Option(Int) {
  option.map(crl, fn(document) {
    int.max(now - modb.to_unix(from_doc(Crl, document).fetched_at), 0)
  })
}

// ---------------------------------------------------------------------------
// What a refresh checks before it stores anything
// ---------------------------------------------------------------------------

fn check_expiry(kz: Kazoo, ca_list: stipa.CaList) -> Result(Nil, Error) {
  case ca_list.expires > kz.now() {
    True -> Ok(Nil)
    False ->
      refuse(
        kz,
        "ca-list-expired",
        "the CA list expired at " <> kazoo.iso8601(ca_list.expires),
        "the STI-PA answered a CA list that expired at "
          <> kazoo.iso8601(ca_list.expires)
          <> ", so it was not stored. Either this node's clock is wrong or the"
          <> " STI-PA is serving a stale list; what was stored was kept.",
      )
  }
}

fn check_sequence(kz: Kazoo, ca_list: stipa.CaList) -> Result(Nil, Error) {
  case stored_sequence(kz) {
    Some(stored) if ca_list.sequence < stored ->
      refuse(
        kz,
        "ca-list-rollback",
        "the CA list sequence "
          <> int.to_string(ca_list.sequence)
          <> " is below the stored "
          <> int.to_string(stored),
        "the STI-PA answered CA list sequence "
          <> int.to_string(ca_list.sequence)
          <> ", below the stored "
          <> int.to_string(stored)
          <> ", so it was not stored. A list played back is how a revoked"
          <> " certificate comes back.",
      )
    _ -> Ok(Nil)
  }
}

/// The highest sequence this cluster has seen from the STI-PA. Its own
/// member, not `detail`: `detail` is what the document currently holds
/// and an upload may clear it, and a rollback check that an upload
/// clears is a rollback check an attacker gets one free pass through.
fn stored_sequence(kz: Kazoo) -> Option(Int) {
  case kz.datamgr.open_cache_doc(system.category, doc_id(Ca)) {
    Error(_why) -> None
    Ok(document) ->
      case doc.get_int(document, ["sequence"]) {
        Ok(sequence) -> Some(sequence)
        // A document written before the sequence had a member of its
        // own: `detail` is where it was, and is the sequence as long as
        // the last write was a refresh.
        Error(Nil) ->
          case doc.get_string(document, ["source"]) {
            Ok("stipa") -> option.from_result(doc.get_int(document, ["detail"]))
            _ -> None
          }
      }
  }
}

/// The CA list's signer must chain to an STI-PA pin for the host it came
/// from. Nothing is trusted on first use: with no pin the refresh is
/// refused outright.
fn check_signer(kz: Kazoo, host: String, signer: String) -> Result(Nil, Error) {
  let ca = stored(kz, Ca) |> result.unwrap(None)
  let roots = stipa_anchors(ca, Some(host))
  let upload_hint =
    " Upload the STI-PA root with POST /v2/stir/trust"
    <> " {\"kind\":\"ca\",\"role\":\"stipa\"}, or sup stir_maintenance"
    <> " trust_upload stipa_root <file>."
  case string.contains(roots, certificate_marker) {
    False ->
      refuse(
        kz,
        "no-pinned-root",
        "no pinned STI-PA root to check the CA list's signer against",
        "there is no STI-PA root to check the CA list's signer against:"
          <> " this application ships none for "
          <> host
          <> " and no operator has uploaded one with the role stipa."
          <> legacy_roots_note(ca)
          <> " Nothing is trusted on first use, so the list was not stored."
          <> upload_hint,
      )
    True ->
      // The loose arity: the STI-PA's list signer is not a SHAKEN
      // end-entity certificate and carries no TNAuthList, which the
      // verify-time form holds a leaf to.
      case ffi_validate_chain(signer, roots, "", "", kz.now()) {
        Ok(Nil) -> Ok(Nil)
        Error(why) ->
          refuse(
            kz,
            "signer-untrusted",
            why,
            "the STI-PA's CA list is signed by a certificate that does not"
              <> " chain to a pinned STI-PA root for "
              <> host
              <> ": "
              <> why
              <> ". The stored list was kept."
              <> legacy_roots_note(ca)
              <> " If the STI-PA has changed its root, upload the new one."
              <> upload_hint,
          )
      }
  }
}

/// What a refusal says when `trust-ca` still has the roots field from
/// before the roles: those are call roots now, and if the STI-PA root was
/// among them it has to be uploaded again.
fn legacy_roots_note(ca: Option(Value)) -> String {
  case option.then(ca, present(_, legacy_roots_field)) {
    None -> ""
    Some(_) ->
      " trust-ca still holds roots uploaded before roots had a role; they"
      <> " anchor calls only and never pin the STI-PA, so if the STI-PA root"
      <> " is among them it must be uploaded again with the role stipa."
  }
}

/// What `stir_ffi:authenticate_crl` read off a CRL that passed.
type CrlFacts {
  CrlFacts(this_update: Int, crl_number: Option(Int))
}

/// A CRL that may replace the stored one: authentic, and not older.
fn newer_authentic_crl(
  kz: Kazoo,
  crl: String,
  signer: String,
  host: String,
) -> Result(CrlFacts, String) {
  use facts <- result.try(authentic_crl(kz, crl, signer, host))
  use _ <- result.try(not_older(kz, facts, host))
  Ok(facts)
}

/// The CRL checked as verification checks it, its signer held to the
/// STI-PA pins for `host`.
fn authentic_crl(
  kz: Kazoo,
  crl: String,
  signer: String,
  host: String,
) -> Result(CrlFacts, String) {
  let ca = stored(kz, Ca) |> result.unwrap(None)
  ffi_authenticate_crl(crl, signer, stipa_anchors(ca, Some(host)), kz.now())
  |> result.map(fn(facts) {
    let #(this_update, _next_update, crl_number) = facts
    CrlFacts(this_update:, crl_number:)
  })
}

/// A CRL issued before the stored one is refused; the same one again is
/// not, since the STI-PA answers the same CRL until it issues the next.
/// Only a CRL from the same STI-PA host is compared: `thisUpdate` and
/// `cRLNumber` order one issuer's CRLs and say nothing across issuers, so
/// comparing a production CRL with a staging one would refuse production
/// until its numbers caught up. The number decides only between two CRLs
/// issued at the same moment.
fn not_older(kz: Kazoo, facts: CrlFacts, host: String) -> Result(Nil, String) {
  let crl =
    stored(kz, Crl)
    |> result.unwrap(None)
    |> option.then(fn(document) {
      case present(document, stipa_host_field) {
        Some(stored_host) if stored_host == host -> Some(document)
        _ -> None
      }
    })
  let stored_number =
    option.then(crl, fn(document) {
      option.from_result(doc.get_int(document, [crl_number_field]))
    })
  let stored_at = option.then(crl, stored_this_update)
  case stored_at, stored_number, facts.crl_number {
    Some(stored), _, _ if facts.this_update < stored ->
      Error(
        "the CRL was issued at "
        <> kazoo.iso8601(facts.this_update)
        <> ", before the stored one ("
        <> kazoo.iso8601(stored)
        <> ")",
      )
    Some(at), Some(stored), Some(number)
      if at == facts.this_update && number < stored
    ->
      Error(
        "the CRL number "
        <> int.to_string(number)
        <> " is below the stored "
        <> int.to_string(stored),
      )
    _, _, _ -> Ok(Nil)
  }
}

/// The stored CRL's `thisUpdate`. A CRL a refresh stored before it was
/// recorded has it only inside the CRL, and is read there: leaving it
/// out would let the first refresh after an upgrade take any CRL still
/// in its window.
fn stored_this_update(document: Value) -> Option(Int) {
  case doc.get_int(document, [this_update_field]) {
    Ok(this_update) -> Some(this_update)
    Error(Nil) ->
      case
        doc.get_string(document, ["source"]),
        present(document, bundle_field)
      {
        Ok("stipa"), Some(pem) -> option.from_result(stipa.crl_this_update(pem))
        _, _ -> None
      }
  }
}

/// The members a CRL's facts are stored as; `None` clears them, for a CRL
/// stored without being authenticated.
fn crl_facts(facts: Option(CrlFacts)) -> List(#(String, Option(Value))) {
  [
    #(authenticated_field, option.map(facts, fn(_facts) { doc.Bool(True) })),
    #(
      this_update_field,
      option.map(facts, fn(facts) { doc.Int(facts.this_update) }),
    ),
    #(
      crl_number_field,
      option.then(facts, fn(facts) { option.map(facts.crl_number, doc.Int) }),
    ),
  ]
}

/// Every `CERTIFICATE` block of an upload, each rebuilt on lines of its
/// own and nothing else kept: a private key or any other block pasted in
/// with the roots never reaches the document.
fn certificate_blocks(text: String) -> Result(List(String), String) {
  case string.split(text, certificate_marker) {
    [_before, first, ..rest] ->
      list.try_map([first, ..rest], fn(block) {
        case string.split_once(block, certificate_end) {
          Ok(#(body, _after)) ->
            case string.contains(body, "-----") {
              False ->
                Ok(
                  certificate_marker
                  <> "\n"
                  <> string.trim(body)
                  <> "\n"
                  <> certificate_end
                  <> "\n",
                )
              True -> Error("a certificate block in the upload is not closed")
            }
          Error(Nil) -> Error("a certificate block in the upload is not closed")
        }
      })
    _ -> Error("the upload holds no " <> certificate_marker <> " block")
  }
}

/// A certificate of an upload has to be one `public_key` can read, and
/// one something could anchor to: a CA certificate, or a self-signed one,
/// which is the shape a private root and every test root come in and
/// which path validation takes as an anchor. An end-entity certificate
/// out of the middle of somebody's chain is refused here, rather than a
/// refresh later saying "no trust anchor" from somewhere else. Answers
/// the subject and fingerprint, for the log.
fn root_certificate(pem: String) -> Result(String, String) {
  case certificate_info(pem) {
    Error(why) ->
      Error("the upload is not a certificate this can read: " <> why)
    Ok(text) ->
      case doc.parse(text) {
        Error(Nil) -> Error("the upload is not a certificate this can read")
        Ok(info) -> {
          let subject = doc.get_string(info, ["subject"]) |> result.unwrap("?")
          let issuer = doc.get_string(info, ["issuer"]) |> result.unwrap("")
          let fingerprint =
            doc.get_string(info, ["fingerprint"]) |> result.unwrap("?")
          case doc.get_bool(info, ["is_ca"]), subject == issuer {
            Ok(True), _ | _, True -> Ok(subject <> " (" <> fingerprint <> ")")
            _, False ->
              Error(
                "the upload is neither a CA certificate nor a self-signed one ("
                <> subject
                <> " issued by "
                <> issuer
                <> "), so nothing would anchor to it",
              )
          }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// The CRL, and the alert it raises
// ---------------------------------------------------------------------------

/// A CA list that did not come at all. Nothing is stored, which is also
/// nothing refreshed, so it is the CRL's clock that says how bad it is.
fn list_not_fetched(kz: Kazoo, why: stipa.Error) -> Nil {
  let reason = stipa_reason(why)
  system.log_error(
    "trust: the STI-PA's CA list could not be fetched: "
    <> reason
    <> ". What was stored was kept; the next pass tries again.",
  )
  crl_at_risk(
    kz,
    "the STI-PA's CA list could not be fetched (" <> reason <> ")",
  )
}

/// A CRL that did not come. The stored one stays and every pass tries
/// again; an alert goes out when there is nothing stored or when what is
/// stored is inside its last hour.
fn crl_not_refreshed(kz: Kazoo, why: stipa.Error) -> Nil {
  let reason = stipa_reason(why)
  system.log_error(
    "trust: the STI-PA's CRL could not be refreshed: "
    <> reason
    <> ". The stored CRL was kept; the next pass tries again.",
  )
  crl_at_risk(kz, "the STI-PA's CRL could not be refreshed (" <> reason <> ")")
}

/// A CRL that came and was refused. It is a refusal of its own, alerted
/// daily as `trust:crl-refused`, since it is either a fault at the
/// STI-PA or somebody answering for it; and, like a CRL that did not
/// come, revocation at risk when what is stored is running out.
fn crl_refused(kz: Kazoo, why: String) -> Nil {
  let _refused =
    refuse(
      kz,
      crl_refused_dedupe,
      why,
      "the STI-PA answered a CRL that was not stored: "
        <> why
        <> ". A CRL must be signed by a signer with cRLSign that chains to a"
        <> " pinned STI-PA root, be inside its window, and be no older than"
        <> " the stored one. The stored CRL was kept; the next pass tries"
        <> " again.",
    )
  crl_at_risk(kz, "the STI-PA's CRL was refused (" <> why <> ")")
}

/// The one alert an operator gets about revocation checking: raised when
/// there is no stored CRL, or when the stored one is inside its last
/// hour or past it. Once an hour while it lasts, since it is an outage
/// and not a diary date.
fn crl_at_risk(kz: Kazoo, headline: String) -> Nil {
  let now = kz.now()
  let #(urgent, what) = case stored_crl_next_update(kz) {
    None -> #(True, "there is no stored CRL at all")
    Some(next_update) -> #(
      next_update - crl_alert_window_s <= now,
      case next_update <= now {
        True -> "the stored CRL expired at " <> kazoo.iso8601(next_update)
        False ->
          "the stored CRL is only good until "
          <> kazoo.iso8601(next_update)
          <> ", "
          <> int.to_string({ next_update - now } / 60)
          <> " minute(s) from now"
      },
    )
  }
  case urgent {
    False -> Nil
    True -> crl_alert(kz, headline <> " and " <> what, now)
  }
}

/// A call was verified without the revocation check. Alerted once an
/// hour, and logged at error level once a minute: this runs on the call
/// path, and one line per call would be thousands a minute saying the
/// same thing, which is how a log stops being read.
fn revocation_unchecked(kz: Kazoo, why: String, now: Int) -> Nil {
  case cache.first_in(log_table, "revocation-unchecked", now, log_interval_s) {
    False -> Nil
    True ->
      system.log_error(
        "trust: verifying without the revocation check: "
        <> why
        <> ". Calls are verified and marked unchecked until the CRL is back.",
      )
  }
  crl_alert(
    kz,
    "Inbound calls are being verified without the revocation check: " <> why,
    now,
  )
}

fn crl_alert(kz: Kazoo, message: String, now: Int) -> Nil {
  let _outcome =
    alert.raise(
      kz,
      crl_dedupe,
      "STIR/SHAKEN revocation checking is degraded",
      message
        <> ". Inbound calls are still verified, and marked as having had no"
        <> " revocation check. Check the node's route to the STI-PA, or upload"
        <> " a CRL with POST /v2/stir/trust {\"kind\":\"crl\"}.",
      doc.object([#("kind", doc.String("trust"))]),
      now,
      alert.hourly_interval_s,
    )
  Nil
}

fn stipa_reason(error: stipa.Error) -> String {
  case error {
    stipa.Fetch(http.Transport(why)) -> why
    stipa.Malformed(why) -> why
    stipa.Untrusted(why) -> why
  }
}

// ---------------------------------------------------------------------------
// The anchors
// ---------------------------------------------------------------------------

/// What a call's certificate chain may anchor in: the STI-PA's CA list,
/// plus the call roots an operator uploaded (a private CA in a lab, an
/// STI-CA root the list does not carry yet), the roots of a document
/// from before the roles among them. Never an STI-PA pin, shipped or
/// uploaded: those pin the STI-PA's own signers, and an STI-PA signer
/// certificate must not pass as a SHAKEN leaf, which the leaf
/// constraints in the checker refuse as well. `Error(Nil)` when there is
/// none of it.
fn call_anchors(ca: Option(Value)) -> Result(String, Nil) {
  let parts =
    list.filter_map(
      [bundle_field, call_roots_field, legacy_roots_field],
      fn(name) { option.then(ca, present(_, name)) |> option.to_result(Nil) },
    )
  case parts {
    [] -> Error(Nil)
    parts -> Ok(join(parts))
  }
}

/// The roots the STI-PA's own certificates are pinned to: the ones
/// shipped for `host`, plus the STI-PA roots an operator uploaded. Never
/// the CA list, and never a call root. `None` is a document from before
/// hosts were recorded, which has the uploaded STI-PA roots alone.
fn stipa_anchors(ca: Option(Value), host: Option(String)) -> String {
  join([
    option.map(host, shipped_pins) |> option.unwrap(""),
    option.then(ca, present(_, stipa_roots_field)) |> option.unwrap(""),
  ])
}

/// The roots this application ships for an STI-PA host, PEM; empty for a
/// host it ships none for, which is every host but staging.
pub fn shipped_pins(host: String) -> String {
  case list.key_find(shipped, string.lowercase(host)) {
    Ok(file) -> pinned_file(file)
    Error(Nil) -> ""
  }
}

/// The host of the STI-PA base URL, lowercased; empty when it has none.
fn host_of(url: String) -> String {
  case utf8(url) {
    False -> ""
    True ->
      case uri.parse(url) {
        Ok(uri.Uri(host: Some(host), ..)) -> string.lowercase(host)
        _ -> ""
      }
  }
}

/// A shipped roots file, read once per node and remembered -- but only
/// when there was something to read. A tree without the file pins
/// nothing, which refuses every refresh; remembering that emptiness
/// meant one unlucky read (a file being replaced, a full descriptor
/// table) pinned nothing for the life of the node.
fn pinned_file(file: String) -> String {
  case cache.get(roots_table, file) {
    Ok(pem) -> pem
    Error(Nil) ->
      case read_roots(file) {
        "" -> ""
        pem -> {
          cache.put(roots_table, file, pem)
          pem
        }
      }
  }
}

fn read_roots(file: String) -> String {
  case read_file(kazoo.priv_dir(system.category) <> "/" <> file) {
    Error(_why) -> ""
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Error(Nil) -> ""
        // The file is documented in its own comments; the PEM starts at
        // the first block.
        Ok(text) ->
          case string.contains(text, certificate_marker) {
            True -> string.crop(text, certificate_marker)
            False -> ""
          }
      }
  }
}

/// PEM blocks concatenated so each begins on a line of its own.
fn join(pems: List(String)) -> String {
  pems
  |> list.filter(fn(pem) { pem != "" })
  |> list.map(fn(pem) { string.trim_end(pem) <> "\n" })
  |> string.concat
}

fn utf8(text: String) -> Bool {
  case bit_array.to_string(bit_array.from_string(text)) {
    Ok(_text) -> True
    Error(Nil) -> False
  }
}

// ---------------------------------------------------------------------------
// Alerts
// ---------------------------------------------------------------------------

/// Log a refusal, alert about it, and answer the error the caller
/// returns.
fn refuse(
  kz: Kazoo,
  dedupe: String,
  error_text: String,
  message: String,
) -> Result(Nil, Error) {
  system.log_error("trust: " <> message)
  let _outcome =
    alert.raise(
      kz,
      "trust:" <> dedupe,
      "STIR/SHAKEN trust refresh refused",
      message,
      doc.object([#("kind", doc.String("trust"))]),
      kz.now(),
      alert.default_interval_s,
    )
  Error(Stipa(stipa.Untrusted(error_text)))
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

/// What happens to the document's `detail` on a write.
type Detail {
  Set(Int)
  Clear
  /// Leave what the document says: a write that is about the signer and
  /// nothing else.
  Keep
}

/// `facts` are members set as given, or removed for `None`.
fn store(
  kz: Kazoo,
  kind: Kind,
  bundle bundle: Option(String),
  signer signer: Option(String),
  source source: String,
  by by: Option(String),
  detail detail: Detail,
  sequence sequence: Option(Int),
  facts facts: List(#(String, Option(Value))),
) -> Result(Status, Error) {
  let id = doc_id(kind)
  let fetched_at = modb.from_unix(kz.now())
  let base = existing(kz, id, fetched_at)
  let detail = case detail {
    Set(n) -> Some(n)
    Clear -> None
    Keep -> option.from_result(doc.get_int(base, ["detail"]))
  }
  let document =
    base
    |> doc.set(["kind"], doc.String(kind_to_string(kind)))
    |> doc.set(["fetched_at"], doc.Int(fetched_at))
    |> doc.set(["source"], doc.String(source))
    |> doc.set(["detail"], case detail {
      Some(n) -> doc.Int(n)
      None -> doc.Null
    })
    |> doc.set(["by"], case by {
      Some(who) -> doc.String(who)
      None -> doc.Null
    })
    |> doc.set(["pvt_modified"], doc.Int(fetched_at))
  let document =
    doc.merge(
      document,
      doc.object_some([
        #("sequence", option.map(sequence, doc.Int)),
        #(bundle_field, option.map(bundle, doc.String)),
        #(signer_field, option.map(signer, doc.String)),
      ]),
    )
  let document =
    list.fold(facts, document, fn(document, fact) {
      case fact {
        #(name, Some(value)) -> doc.set(document, [name], value)
        #(name, None) -> doc.delete(document, [name])
      }
    })
  use _ <- result.try(
    kz.datamgr.save_doc(system.category, document)
    |> result.map_error(Datastore),
  )
  Ok(Status(kind:, fetched_at:, source:, detail:))
}

/// The roots an operator uploaded for a role, and nothing else about the
/// document: not the other role's roots, not the bundle, not the source,
/// not the sequence, and not `fetched_at`, which says when the CA list
/// was last fetched and would otherwise buy a node that has never fetched
/// one a refresh interval of silence.
fn store_roots(
  kz: Kazoo,
  role: Role,
  pem: String,
  by: String,
  described: List(String),
) -> Result(Status, Error) {
  let id = doc_id(Ca)
  let at = modb.from_unix(kz.now())
  let base = existing(kz, id, at)
  let #(name, what) = case role {
    StipaRoot -> #(stipa_roots_field, "STI-PA root(s), pinning the STI-PA")
    CallRoot -> #(call_roots_field, "call root(s), anchoring calls")
  }
  let document =
    base
    |> doc.set(["kind"], doc.String(kind_to_string(Ca)))
    |> doc.set([name <> "_at"], doc.Int(at))
    |> doc.set([name <> "_by"], doc.String(by))
    |> doc.set([name], doc.String(pem))
    |> doc.set(["pvt_modified"], doc.Int(at))
  // The roots from before the roles were call roots, so a call-root
  // upload is what replaces them.
  let document = case role {
    CallRoot ->
      document
      |> doc.delete([legacy_roots_field])
      |> doc.delete([legacy_roots_field <> "_at"])
      |> doc.delete([legacy_roots_field <> "_by"])
    StipaRoot -> document
  }
  use _ <- result.try(
    kz.datamgr.save_doc(system.category, document)
    |> result.map_error(Datastore),
  )
  system.log(
    "trust: "
    <> by
    <> " uploaded "
    <> int.to_string(list.length(described))
    <> " "
    <> what
    <> " (role "
    <> role_to_string(role)
    <> "), replacing the ones before: "
    <> string.join(described, "; "),
  )
  Ok(from_doc(Ca, document))
}

/// The stored document, or a new one. A document this creates has never
/// fetched anything: `fetched_at` is zero so the first pass refreshes,
/// rather than the upload that created it counting as a fetch.
fn existing(kz: Kazoo, id: String, created_at: Int) -> Value {
  case kz.datamgr.open_doc(system.category, id) {
    Ok(document) -> document
    Error(_) ->
      doc.object([
        #("_id", doc.String(id)),
        #("pvt_type", doc.String(doc_type)),
        #("pvt_created", doc.Int(created_at)),
        #("fetched_at", doc.Int(0)),
        #("source", doc.String("upload")),
      ])
  }
}

/// A trust document through the node's document cache; `None` when there
/// is none of that kind. A verification on the call path reads each of
/// the two documents once through this and takes every field off that
/// read.
fn stored(kz: Kazoo, kind: Kind) -> Result(Option(Value), Error) {
  case kz.datamgr.open_cache_doc(system.category, doc_id(kind)) {
    Error(kazoo.NotFound) -> Ok(None)
    Error(error) -> Error(Datastore(error))
    Ok(document) -> Ok(Some(document))
  }
}

/// A PEM field of a trust document, for the routes and the refresh.
fn field(kz: Kazoo, kind: Kind, name: String) -> Result(String, Error) {
  use found <- result.try(stored(kz, kind))
  case option.then(found, pem_of(_, name)) {
    Some(pem) -> Ok(pem)
    None -> Error(NotFound)
  }
}

fn status_of(kz: Kazoo, kind: Kind) -> Result(Option(Status), Error) {
  stored(kz, kind)
  |> result.map(option.map(_, fn(document) { from_doc(kind, document) }))
}

fn from_doc(kind: Kind, document: Value) -> Status {
  Status(
    kind:,
    fetched_at: doc.get_int(document, ["fetched_at"]) |> result.unwrap(0),
    source: doc.get_string(document, ["source"]) |> result.unwrap("stipa"),
    detail: option.from_result(doc.get_int(document, ["detail"])),
  )
}

@external(erlang, "stir_ffi", "validate_chain")
fn ffi_validate_chain(
  chain_pem: String,
  trust_pem: String,
  crl_pem: String,
  crl_signer_pem: String,
  now_unix: Int,
) -> Result(Nil, String)

@external(erlang, "stir_ffi", "validate_chain_with_anchors")
fn ffi_validate_chain_with_anchors(
  chain_pem: String,
  trust_pem: String,
  crl_pem: String,
  crl_signer_pem: String,
  crl_anchors_pem: String,
  now_unix: Int,
) -> Result(Nil, String)

/// A CRL checked as verification checks it: its `thisUpdate`,
/// `nextUpdate` and `cRLNumber` when it passes.
@external(erlang, "stir_ffi", "authenticate_crl")
fn ffi_authenticate_crl(
  crl_pem: String,
  signer_pem: String,
  anchors_pem: String,
  now_unix: Int,
) -> Result(#(Int, Option(Int), Option(Int)), String)

@external(erlang, "stir_ffi", "certificate_info")
fn certificate_info(chain_pem: String) -> Result(String, String)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)
