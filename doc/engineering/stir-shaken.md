# STIR/SHAKEN in Reprise

This document describes how Reprise signs outbound carrier calls and
verifies inbound ones: where the decision is made, what is stored, how a
call is attested, how keys are protected and how certificates are
renewed. The companion [threat model](stir-shaken-security.md) lists what
the design protects against.
The API is documented in `applications/crossbar/doc/stir.md`, the
operator commands in `applications/stir/README.md`.

## 1. Summary

Kazoo signs and verifies itself. FreeSWITCH puts the `Identity` header on
the wire for an outbound call and hands an inbound one up to Kazoo; the
Kamailio SBCs only classify where a call came from. A Gleam application,
`stir`, owns the keys, the certificates, the PASSporT code, the
attestation policy, the Crossbar API and the periodic work. Three Erlang
applications carry one guarded call each: `stepswitch` where carrier legs
are built, `callflow` (and `trunkstore`) where the winning node starts an
inbound call.

Building the header in Kazoo works whichever way a call leaves the
platform, and puts the multi-tenant decision (which account is calling,
which number, which key) where the tenant is known.

Per call:

- **Outbound.** `stepswitch` asks `stir` for headers once per offnet
  request. `stir` decides the attestation level (A, B or C), picks the
  key for the account's scope, builds and signs the PASSporT, and answers
  the `Identity` header plus the channel variable that keeps FreeSWITCH
  from emitting it twice. `stepswitch` merges them into every carrier
  endpoint whose resource has not opted out.
- **Inbound.** Every carrier INVITE enters through an SBC, which stamps
  `X-AUTH-*` headers that classify the source. FreeSWITCH lifts the
  `Identity` header into a variable and the route request carries it to
  Kazoo with the SBC's stamps. When callflow wins the route it asks
  `stir` for a verdict: the carrier's own verdict when the carrier is
  trusted to verify, otherwise Kazoo's own check of the signature,
  freshness, numbers and certificate chain. The verdict is written onto
  the channel as custom channel variables, so it reaches CDRs, call events,
  webhooks and callflow branching.
- **Certificates.** `stir` generates every private key itself and keeps
  it sealed in its own database under a key-encryption key that lives
  only in the node's environment. Each certificate is served at a stable
  public URL (the `x5u`). A periodic task alerts on expiry, activates
  pending keys and refreshes the STI-PA trust material. Issuance goes
  through a CSR; the private key never leaves Kazoo. Activating a key is
  a document write that every node picks up within 30 seconds, with
  nothing restarted.
- **Reseller override.** A key carries a `scope`, the platform or an
  account id, and key selection walks the account tree. The account-scoped
  API is off by default.

## 2. Background

### 2.1 Standards

- **PASSporT** (RFC 8225, RFC 8588, ATIS-1000074): protected header
  `{"alg":"ES256","ppt":"shaken","typ":"passport","x5u":<url>}`, payload
  `{"attest","dest":{"tn":[...]},"iat","orig":{"tn":...},"origid"}`, a
  compact JWS whose ECDSA signature is the raw `R||S` (64 bytes), carried
  as `Identity: <jws>;info=<x5u>;alg=ES256;ppt=shaken`. Verifiers allow
  about 60 s of `iat` skew and cache the `x5u` for a day.
- **Attestation** (ATIS-1000074 §5.2.4): A means the originating
  provider's own customer with a verified association to the number; B,
  its customer without that association; C, no relationship with the
  originator (transit, gateway).
- **Certificates** carry the service provider code (SPC) in the
  TNAuthList extension (RFC 8226, OID 1.3.6.1.5.5.7.1.26), use EC P-256
  keys, and chain to an STI-CA root on the STI-PA's trusted CA list.
- **The STI-PA** publishes the trusted CA list as a signed JWT
  (`{"caList": <JWT>}`, payload `{version, sequence, exp, trustList}`)
  and an indirect CRL signed by the STI-PA rather than by each STI-CA.
  Neither needs credentials to fetch; a login is needed only for SPC
  tokens, which only an ACME order uses.
- **Carrier verdicts.** Terminating carriers that verify commonly add a
  `verstat` parameter to P-Asserted-Identity (`TN-Validation-Passed`,
  optionally suffixed `-B`/`-C`, `TN-Validation-Failed`,
  `No-TN-Validation`), and some add `P-Attestation-Indicator` and
  `P-Origination-ID`.

### 2.2 The header path through FreeSWITCH

- Kazoo's `Custom-SIP-Headers` become `sip_h_<Name>` variables with no
  name filter (`applications/ecallmgr/src/ecallmgr_fs_xml.erl`), and sofia
  emits every `sip_h_` variable as a header. Endpoint keys listed in
  `?SPECIAL_CHANNEL_VARS` become FreeSWITCH variables, which is how
  `exclude_outgoing_extra_header` is set per leg.
- **Duplicate `Identity`.** With native signing compiled out, sofia reads
  `sip_h_identity` both for its typed `Identity` tag and again as a
  generic extra header, and sofia-sip declares `Identity` an append-kind
  header, so both copies go on the wire. Setting
  `exclude_outgoing_extra_header=^sip_h_[Ii]dentity$` on the leg leaves
  exactly one, with its `;info=<...>` parameters intact. The regex
  matches the variable name (PCRE, case-sensitive, hence `[Ii]`). The
  bridge endpoint definition (`kapi_dialplan`) names
  `Exclude-Outgoing-Extra-Header` so the key survives the endpoint
  rebuild, and `stepswitch_stir` leaves an empty answer off the endpoint.
- Inbound, sofia sets `sip_h_identity` from the first `Identity` header,
  and the route request carries it as `Custom-SIP-Headers.identity`. The
  SBC's stamps arrive as `Custom-AUTH-Headers` and are read with
  `kapps_call:custom_auth_header/2`. A peer cannot forge `X-AUTH-*`:
  Kamailio strips that prefix from every untrusted request
  (`configs/kamailio/kamailio/defs.cfg`).
- An inbound `Identity` is never copied to the B leg by accident
  (`sip_copy_custom_headers` does not cover it). Passthrough on a
  forwarded call is explicit: `stir/outbound` answers the inbound call's
  own `Identity` as the outbound header. FreeSWITCH 1.11.3 has nothing
  behind `sip_identity_passthru`, so that variable is not used.

### 2.3 How calls reach carriers

Inbound: carrier to SBC (the carrier's address is in a resource's
`inbound_ips`, which Kazoo pushes to the SBCs and to FreeSWITCH's ACL),
SBC to FreeSWITCH, FreeSWITCH to Kazoo over AMQP.

Outbound: `stepswitch` picks gateways and FreeSWITCH dials them. A local
resource on an account with a dedicated IP routes the INVITE through an
SBC (`Proxy-IP`, rendered by ecallmgr as `;fs_path=`); global resources
are dialled from FreeSWITCH directly. Signing in Kazoo does not depend on
which of the two a call takes.

## 3. Architecture

### 3.1 Where to sign and verify

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Kazoo signs and verifies (`stir`); FreeSWITCH carries the header** | every egress path; account, number and resource known at the decision point; keys stay in Kazoo; reseller override is a lookup; unit-testable; no SBC or FreeSWITCH rebuild | bad inbound calls are marked after the SBC relayed them, not refused at the edge | **chosen** |
| Kamailio `secsipid` signs and verifies, Kazoo passes attestation in headers | signs at the last hop; edge rejection | needs every carrier leg through an SBC; private keys on the SBCs; claims decoded in routing script | kept as an optional edge-rejection add-on (§3.9) |
| FreeSWITCH native signing (libstirshaken) | nothing elsewhere | one key per switch; no tenant knowledge; an extra library to build and maintain | rejected |

### 3.2 Call flow

```
OUTBOUND
phone ──► SBC ──► FreeSWITCH ──► Kazoo callflow ──► stepswitch
                                                      │ stepswitch_stir:maybe_sign/3
                                                      │ 'stir@outbound':headers(#{account_id, orig_tn, dest_tn,
                                                      │                          resource_id, inception, privacy...})
                                                      │   ← Identity value, attest, origid, kid,
                                                      │     exclude_outgoing_extra_header
                                                      ▼
                     FreeSWITCH ──Identity: <jws>;info=<x5u>;alg=ES256;ppt=shaken──► carrier
                     (direct, or through an SBC when the account has a dedicated IP)

INBOUND
carrier ──► SBC (trusted carrier source) ──X-AUTH-Trusted-Type, X-AUTH-Token, X-AUTH-Verstat...──► FreeSWITCH
        ──route_req{Custom-SIP-Headers.identity, Custom-AUTH-Headers.*}──► callflow
        cf_route_win ──► cf_stir:maybe_verify/1 ──► 'stir@inbound':verify(call facts)
             carrier verdict, or: x5u fetch (cached 24 h) → signature, iat, orig/dest match, chain, CRL
             → CCVs STIR-Verstat / STIR-Attest / STIR-Orig-ID / STIR-Verdict-Source ... on the channel
        ──► callflow runs; the stir_shaken action branches; the CDR carries the CCVs

KEYS
stir/monitor (hourly) ── activation, expiry alerts, x5u self-check, trust refresh
new key (API or sup) → CSR → certificate issued by the STI-CA → upload → activate
        → every node's key cache refreshes within 30 s
Public: GET https://<api host>/v2/stir/certs/<kid>.pem  (the x5u)
```

### 3.3 The `stir` application

`applications/stir` is a Gleam package built on `core/kazoo_gleam`; its
module table is in `applications/stir/README.md`. The parts:

- **Pure core**: `stir/passport` (claims, canonical JSON, the header,
  verification), `stir/jws` (ES256 compact JWS, `R||S` packing),
  `stir/attest` (the policy of §3.5), `stir/api` (routes, permissions and
  shapes of the Crossbar module), `stir/report` (the text of the `sup`
  reports).
- **Keys**: `stir/key` (metadata and document shape), `stir/secret` (an
  opaque in-memory secret), `stir/vault` (the key-encryption key and
  AES-256-GCM sealing), `stir/keys` (create, import, attach, activate,
  retire, delete, select), `stir/signer` (the one process per node that
  opens keys and signs), `stir/credentials` (write-only credentials).
- **Trust**: `stir/http` (an injected transport, so tests never touch the
  network), `stir/x5u` (certificate fetch and cache), `stir/stipa` (the CA
  list and CRL), `stir/trust` (stored trust material, chain validation).
- **Call path**: `stir/outbound` (`headers/1`), `stir/inbound`
  (`verify/1`), `stir/numbers` (number ownership), `stir/carriers` (the
  resource behind an SBC token and its policy), `cf_stir_shaken` (the
  callflow action).
- **Operations**: `stir/monitor` (the periodic pass), `stir/alert`
  (cluster-wide throttled alerts), `stir/store` (revision-carrying writes),
  `stir/views`, `cb_stir` (Crossbar), `stir_maintenance` (`sup`).
- **Erlang FFI**: `stir_ffi.erl` (`public_key` and `crypto`: EC key
  generation, ECDSA with DER to `R||S`, CSR, certificate parsing including
  TNAuthList, path validation with an indirect CRL, AES-256-GCM, HTTPS),
  `stir_inbound_ffi.erl`, `stir_ops_ffi.erl`.

Erlang touch points, each guarded with `code:ensure_loaded/1` so a
release built without `stir` behaves exactly as before:

| Where | What |
|---|---|
| `applications/stepswitch/src/stepswitch_stir.erl`, called from `stepswitch_resources:endpoints/2` and `stepswitch_resource_selectors` | sign once per offnet request, merge the answer into each endpoint, drop every foreign `Identity` from carrier legs |
| `applications/ecallmgr/src/ecallmgr.hrl` | `Exclude-Outgoing-Extra-Header` in `?SPECIAL_CHANNEL_VARS` |
| `applications/ecallmgr/src/ecallmgr_fs_acls.erl` | the trusted-source `group` the SBC turns into `X-AUTH-Trusted-Type` |
| `applications/callflow/src/cf_stir.erl`, called from `cf_route_win` | clear every `STIR-*` variable, ask for a verdict, write it |
| `applications/trunkstore/src/ts_from_offnet.erl` | the same call for trunkstore inbound |
| `configs/kamailio/kamailio/trusted.cfg`, `defs.cfg` | the `X-AUTH-Verstat`, `X-AUTH-Attest`, `X-AUTH-Orig-ID` stamps for trusted carriers; reserved header prefixes stripped from untrusted requests |

### 3.4 Data model

**Database `stir`**, a system database created at start.

`stir_key`:

```json
{
  "_id": "<kid: 16 hex>",
  "pvt_type": "stir_key",
  "scope": "system",                 // or an account id (reseller override)
  "alg": "ES256",
  "spc": "1234",
  "x5u": "https://api.example.com/v2/stir/certs/<kid>.pem",
  "not_before": 63900000000,         // Gregorian seconds, like everything stored
  "not_after":  63907776000,
  "status": "active",                // csr | pending | active | retired
  "source": "csr",                   // csr | acme | imported
  "fingerprint": "sha256:...",
  "kek": "<8 hex of sha256(KEK)>",   // which key-encryption key the private key is sealed under
  "public_key": "-----BEGIN PUBLIC KEY-----...",
  "sealed_private_key": "<base64>",  // AES-256-GCM under the KEK, nonce and tag prepended, AAD = kid
  "certificate": "-----BEGIN CERTIFICATE-----...", // leaf plus intermediates, once issued
  "csr": "-----BEGIN CERTIFICATE REQUEST-----...", // while status is csr
  "history": [ { "at": 63900000000, "what": "activated", "by": "<account id>/<user id>" } ]
}
```

The sealed key, the certificate and the CSR are fields of the document,
never attachments, written in the one save that creates the document. An
attachment goes wherever the cluster's storage plan sends attachments,
which can be a bucket the application does not control; a field stays in
the database. One read answers a key and its private key together, and a
key is never on record without one.

One `active` key per scope. A `csr` key has no certificate yet; `pending`
keys are already served at their `x5u` (so a verifier that caches early
still works); `retired` keys stay served until `not_after` so recent calls
still verify, then the monitor deletes them.

`stir_trust`: one document per kind. `trust-ca` holds the CA list PEM in
`bundle`, plus the uploaded `stipa_roots` (pins for the STI-PA signers)
and `call_roots` (extra anchors for call chains); `trust-crl` holds the
CRL, its signer in `signer`, and the authenticated CRL's `this_update`
and `crl_number`. Both record `fetched_at`, `source` and `stipa_host`.

`stir_credentials`: one per name (STI-PA login, ACME external account
binding), the value sealed in `sealed_value` like a key.

**Settings**: `system_config/stir`, schema
`applications/crossbar/priv/couchdb/schemas/system_config.stir.json`,
edited through `/v2/system_configs/stir`:

| Key | Default | Meaning |
|---|---|---|
| `sign_enabled` | false | add `Identity` to carrier legs |
| `verify_enabled` | false | verify inbound carrier calls |
| `verify_mode` | `sync` | `sync`: before the callflow starts, within `verify_timeout_ms`; `async`: the flow starts and the verdict lands when ready |
| `verify_timeout_ms` | 1500 | budget for the `x5u` fetch; past it the verdict is `No-TN-Validation` |
| `trust_upstream_verstat` | true | take a trusted carrier's own verdict and skip Kazoo's fetch and check (§3.5a) |
| `attest_owned_number` | `A` | the caller id is a number assigned to the account (or its tree, see the next key) |
| `attest_owned_scope` | `account` | `account` or `tree` |
| `attest_verified_external_number` | `B` | a verified `external_numbers` document of the account; an adopted one never counts |
| `attest_unverified` | `B` | an authenticated customer calling from a number the platform does not know |
| `attest_forwarded` | `B` | a carrier call forwarded back out with its caller id kept, never above the level the inbound call carried; `passthru` carries the original `Identity` instead |
| `attest_forwarded_when_inbound_failed` | `B` | the same when the inbound `Identity` failed verification; capped at C |
| `attest_transit` | `C` | any other call that arrived from a carrier and goes back out |
| `sign_anonymous` | true | sign when privacy hides the caller id; `orig.tn` is the real number |
| `sign_non_nanp_origin` | false | sign when the originating number is outside NANP |
| `x5u_base_url` | `""` | public prefix stamped on new keys, e.g. `https://api.example.com/v2/stir/certs`; no key can be created while it is empty |
| `identity_max_age_s` | 60 | inbound freshness window |
| `require_date_header` | false | reject an inbound `Identity` without a `Date` header |
| `cid_name_prefix_failed` | `""` | prefix on the caller id name when verification fails |
| `allow_account_keys` | false | enable `/v2/accounts/{id}/stir/keys` (reseller override) |
| `alert_days` | `60,30,14` | days before `not_after` at which expiry alerts are raised |
| `trust_refresh_hours` | 6 | how often the CA list and CRL are refreshed |
| `renewal_enabled` | false | order through ACME inside the renewal window (not implemented yet, §5) |
| `renewal_window_days` | 30 | days before `not_after` at which a renewal is ordered |
| `acme_directory_url` | `""` | the STI-CA's ACME directory; empty means the CSR path |
| `stipa_api_url` | `https://authenticate-api.iconectiv.com` | the STI-PA API base |

**Per carrier** (`resources` documents): `stir.sign` (default true; false
for a carrier that signs on the platform's behalf or rejects `Identity`)
and `stir.verify` (`trust_upstream` | `verify` | `ignore`, default
`trust_upstream`). The resource is known on both paths: outbound through
the gateway, inbound through the SBC's token (`resource_id@account_id` in
its address table).

**Per call**: custom channel variables. Outbound legs carry `STIR-Attest`,
`STIR-Orig-ID` and `STIR-Key-ID`. Inbound calls carry `STIR-Verstat`,
`STIR-Attest`, `STIR-Orig-ID`, `STIR-Identity` (present or absent),
`STIR-Verdict-Source` (`carrier`, `kazoo` or `none`), `STIR-Revocation`
(`checked`, `unchecked` or `n/a`) and, on failure, `STIR-Reason`; a
carrier call also gets `STIR-Inbound-Carrier` and `STIR-Inbound-Caller`
for the forwarding rule. They are set with `kapps_call_command:set/2`, so
they reach CDRs (`kzd_cdrs:custom_channel_vars/2`), call events and
webhooks with no schema change. The whole verdict is also kept in the
call's key-value store under `stir_verdict`.

### 3.5 Attestation policy

`stir/attest` is a pure function over facts `stepswitch` already has
(origination number, account, resource, emergency flag, requestor channel
variables), with `stir/numbers` answering the ownership questions. The
rules, in order:

1. The originating number is assigned in service to the account
   (`knm_numbers`, cached), or to an ancestor when
   `attest_owned_scope = tree`: `attest_owned_number`, A.
2. The leg forwards an inbound call with its caller id kept
   (`Call-Forward` plus `Retain-CID`), **and** the inbound leg was a
   carrier call the inbound hook classified (`STIR-Inbound-Carrier`),
   **and** the forwarded caller id equals the number that hook recorded
   (`STIR-Inbound-Caller`): `attest_forwarded` (B) when the inbound call
   verified, `attest_forwarded_when_inbound_failed` when its `Identity`
   failed, `attest_unverified` when there was no verdict. On such a
   corroborated forward the level any rule gives, rule 1 included, is
   capped at the inbound call's own level (its `STIR-Attest`, or the
   `-B`/`-C` suffix of its verstat; C when it failed, was not validated,
   or nothing stated a level), so a C-signed spoof that verified is not
   re-signed higher. `passthru` carries the original `Identity` through,
   allowed only under the same corroboration with a passed verdict.
3. The originating number is a verified `external_numbers` document of
   the account: `attest_verified_external_number`, B. An adopted number
   (`gather_external_numbers`) never counts.
4. Any other call that arrived from a carrier and goes back out:
   `attest_transit`, C.
5. Otherwise `attest_unverified`, B.

`Call-Forward` and `Retain-CID` are channel variables a device can ask
for, so on their own they are a claim, not evidence. The corroboration
comes only from the inbound hook (`cf_stir`), the sole writer of `STIR-*`
on a call, which clears them on every call it sees; the SBC strips the
`X-ecallmgr` and `X-cav` header prefixes that would otherwise let a peer
set channel variables at all. A leg that claims to be a forward without
those facts falls through to rules 3 to 5, which never answer A for a
number the account does not hold.

Emergency legs are not signed (their caller id is decided later, in
`stepswitch_bridge`). Privacy does not change `orig.tn`
(`sign_anonymous`); an originating number outside NANP is signed only
with `sign_non_nanp_origin`. `origid` is a fresh UUID per call (RFC 8588
guidance), kept as a channel variable so traceback can join it to the
CDR.

### 3.5a Inbound: the carrier's verdict first

Terminating carriers commonly verify inbound calls themselves, so by
default Kazoo takes a trusted carrier's verdict and fetches nothing. That
keeps the `x5u` fetch off the call-setup path for the common case; Kazoo's
own verification is the fallback.

Per carrier resource (`stir.verify`):

1. `trust_upstream` (default). If the call carries a carrier verdict
   (`X-AUTH-Verstat`, `X-AUTH-Attest`, `X-AUTH-Orig-ID`, stamped by the
   SBC from `verstat` on P-Asserted-Identity or From,
   `P-Attestation-Indicator` and `P-Origination-ID`), take it: the
   verstat as given, the attestation from the `-B`/`-C` suffix or the
   indicator (none when a plain pass states no level), the origid when
   present. If the carrier said nothing and an `Identity` is present,
   verify it. If neither, `No-TN-Validation`.
2. `verify`. Ignore any upstream verdict and verify the `Identity`.
3. `ignore`. Record nothing.

Kazoo's own verification checks the ES256 signature against the
certificate fetched from the `x5u` (https only, address policy, cached a
day), `iat` within `identity_max_age_s`, `orig.tn` against the
P-Asserted-Identity or From user, `dest.tn` against the dialled number,
the certificate chain against the trust material with the leaf
constraints (TNAuthList, not a CA, `digitalSignature`), and revocation
against the STI-PA's CRL. The whole verification runs under one deadline
in a process of its own and never raises into the call.

Three guards make trusting upstream safe:

- A verdict is taken only from a call the SBC classified as a carrier
  call (`X-AUTH-Trusted-Type` `global_carrier` or `local_carrier`, with
  the SBC's `X-AUTH-Token`); a registered device or unknown peer that
  writes `verstat` itself is never believed, and its `Identity` is not
  even verified.
- The carrier is resolved to its resource through the SBC's token, so the
  policy is the resource's, not a header's; a token naming a resource of
  another account is refused.
- `trust_upstream` is honoured only for a global carrier. A local
  resource belongs to an account, which could point it at its own PBX and
  write its own verdicts, so a local carrier is always verified by Kazoo.

FreeSWITCH keeps P-Asserted-Identity in a variable no route-request
definition carries, which is why the SBC stamps the verdict as
`X-AUTH-*` headers in `trusted.cfg` (`SETUP_AUTH_TRUSTED`), where it
already parses that header for every trusted carrier call.

### 3.6 Key selection and the reseller override

`stir/keys` selects a key by walking the account's ancestry upward and
returning the first `active` key whose `scope` matches, else the `system`
key. Results are cached per account for 30 s, which is also the
activation latency. With `allow_account_keys` on, `cb_stir` accepts
`/v2/accounts/{id}/stir/keys` for a reseller, for its own scope only.
Per-reseller attestation overrides and delegate certificates
(ATIS-1000092) are not implemented; the latter would be one more `source`
on the same document.

### 3.7 Certificate lifecycle

1. **CSR path.** `POST /v2/stir/keys {"spc": ...}` (or
   `sup stir_maintenance new_key`) generates a key inside Kazoo and
   answers its CSR. The operator has the certificate issued by the STI-CA
   and uploads the chain with `POST /v2/stir/keys/{kid}/certificate`;
   activation is `POST /v2/stir/keys/{kid} {"status":"active"}`. No
   request carries a private key in either direction.
2. **Serving.** `GET /v2/stir/certs/{kid}.pem` is unauthenticated,
   answers `application/pem-certificate-chain` with
   `Cache-Control: max-age=86400`, and is what the `x5u` points at. It
   serves the certificate field only.
3. **Monitor.** An hourly pass activates a pending key once its
   `not_before` has passed and it outlives the active one, reconciles two
   actives in one scope, alerts at the `alert_days` thresholds while no
   newer key exists, self-fetches each key's `x5u`, refreshes the trust
   material, deletes retired keys past `not_after`, and sweeps the caches.
   Every condition an operator must act on is a Kazoo alert addressed to
   the master account (and, for a reseller's key, to that account);
   `stir-shaken-security.md` §3.8 lists them.
4. **Trust refresh.** The CA-list JWT must verify against a pinned STI-PA
   root before it is used, its `exp` must hold and its `sequence` must not
   go backwards. The CRL must be signed by a certificate that carries
   `cRLSign` and chains to the STI-PA pins for the host it came from, and
   must be newer than the stored one. Neither is trusted on first use.
   `priv/stipa-roots.pem` ships the STI-PA staging root, pinned for the
   staging host only; before the first production refresh an operator
   uploads the production root (`POST /v2/stir/trust` with
   `"role": "stipa"`), taken from the STI-PA directly.
5. **ACME.** An ACME client (TNAuthList order, `tkauth-01` challenge with
   an SPC token from the STI-PA) is designed for but not built; the
   settings and credentials it needs exist. Until then renewal is the CSR
   path with expiry alerts.

Nothing needs a restart at any step.

### 3.8 Key security

- **Keys are born inside Kazoo.** Every EC key is generated by `stir`.
  The one exception is `sup stir_maintenance import_key`, which reads a
  key and chain from the node's filesystem for a certificate issued
  elsewhere, seals the key at once, records `source: imported`, refuses a
  key file readable by group or others, and deletes it on success. No
  Crossbar verb or AMQP message accepts a private key, and none returns
  one.
- **Sealed at rest under a key CouchDB never sees.** AES-256-GCM under a
  key-encryption key read from the `STIR_KEK` environment variable, with
  the document id as associated data. A database dump, replica or backup
  holds no usable key. Without `STIR_KEK` the application starts, reports
  "no key-encryption key", refuses to create or open keys, and never falls
  back to plaintext. Rotation keeps signing throughout: set
  `STIR_KEK_NEXT` everywhere, run `sup stir_maintenance rekey` on one
  node, then move the value to `STIR_KEK` (`applications/stir/README.md`).
- **One process holds decrypted keys.** `stir/signer` is one actor per
  node; callers send the payload and receive the signature. Keys are not
  in ETS and not in the calling process; `Secret` and `Vault` values
  render as a label, never as bytes.
- **Nothing over the bus.** Keys never leave the node they are opened on.
  The upstream `jwt.keys` path that can ship `stir-shaken` keys to the
  SBCs is unused.
- **Who may do what.** Every write on `/v2/stir` requires a superduper
  admin; the reseller path, when enabled, allows a reseller to create a
  key and read a CSR for its own scope only. Every create, certificate
  upload, activation, retirement and deletion is appended to the key's
  `history` with the acting account and user.
- **Two public routes.** `GET /v2/stir/certs/{kid}.pem` and
  `GET /v2/stir/trust/{ca,crl}.pem` are the only unauthenticated routes.

### 3.9 Edge rejection

Verification in Kazoo marks calls; it does not answer 438 to the carrier.
Where rejection at the edge is required, the SBC can verify with
`secsipid` on trusted carrier sources and answer 438 with a `Reason`
header; the trust files it needs are served at
`/v2/stir/trust/{ca,crl}.pem`. This is not built.

## 4. Call-path constraints

The hooks on the call path keep to these rules:

- Sign once per offnet request, not once per gateway.
- The signer call on the call path has a short budget (`stepswitch_stir`
  waits about 600 ms through a proxy process that dies with its caller,
  so a late reply never lands in a call worker's mailbox); the `sup`
  commands use 5 s.
- Fail open in one place: any error from `stir@outbound:headers/1`
  leaves the leg unsigned and the call proceeds.
- Verification runs under one deadline covering the `x5u` fetch, the
  trust reads (cached per node by document revision) and the chain check.
- Nothing in `cf_stir` can stop a call: an unloaded application, a late
  or failed verifier, or an exception leaves the call as the clearing
  left it.

## 5. Testing

- **Gleam** (`gleam test` in `applications/stir`, `make gleam-check` at
  the root): `passport` and `jws` against known-answer vectors (the RFC
  8225 example, tokens from an independent implementation); `attest` over
  a fact table; `x5u`, `stipa`, `trust`, `keys` over a fake transport and
  `kazoo/testing/fake`; the Crossbar route and permission tables; hostile
  inputs for the parsers, PEM and CRL handling and the address policy.
  Fixtures under `applications/stir/test/fixtures` are public material
  and keys generated for the tests.
- **Erlang**: `stepswitch_stir_tests`, `cf_stir_tests`, and the guarded
  call sites with `stir` absent.
- **End to end**: an outbound call captured at the carrier side shows one
  `Identity`; an inbound call shows the verdict variables in the CDR; a
  tampered header fails. `sup stir_maintenance sign` and `verify` give a
  hand round trip against a served certificate.

## 6. Known limitations and future work

- The forwarding rule (§3.5 rule 2) does not fire across a call forward's
  loopback leg: the loopback's own route request makes `cf_stir` clear
  the inbound facts, and keeping them there is unsafe because a device's
  channel variables ride onto the loopback too. Forwards therefore fall to
  the later rules. The fix is to look the facts up by the inbound call's
  id.
- No ACME client yet (§3.7).
- No edge rejection (§3.9).
- No `div` PASSporT for forwarded calls (ATIS-1000085); passthrough
  carries the original instead.
- No Rich Call Data (`rcd`).
- Per-reseller attestation overrides, and a second renewal scope for
  reseller keys, are not built.
- One signer actor per node; it can become a pool if it ever shows in
  latency.
