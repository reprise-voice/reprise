# STIR/SHAKEN: security model

Companion to [`stir-shaken.md`](stir-shaken.md). That document says what
`stir` does; this one says what it protects, from whom, how, and what it
does not protect. Each claim below names the module that enforces it and,
where there is one, the test that checks it.

## 1. Assets

| Asset | Where it lives | What losing it means |
|---|---|---|
| The signing private keys (one per scope) | `stir` database, the key document's `sealed_private_key` field | Anyone holding a key signs A-attested calls as the operator under a certificate carriers trust. Revocation goes through the STI-PA and takes a day to propagate; the reputation damage does not revert. |
| The key-encryption key (`STIR_KEK`) | a deployment secret, read into the node's environment | With a database read it turns every sealed key into a plaintext key. Losing it turns every stored key into noise. |
| STI-PA and ACME credentials | `stir` database, sealed like keys | Someone requests SPC tokens and certificates in the operator's name. |
| The trust material (STI-PA CA list, CRL, their signers, the pinned roots) | `stir` database plus `priv/stipa-roots.pem` | A poisoned list makes forged calls verify; a stale CRL makes revoked signers verify. |
| The attestation decisions | the outbound call path | Signing A for numbers the operator does not control is what the ecosystem polices; a wrong policy is a compliance problem, not a compromise. |
| Availability of the call path | the outbound and inbound hooks | A slow or crashing `stir` delays or fails call setup for every call it touches. |

## 2. Trust boundaries

```
 carrier peers ──SIP──► Kamailio SBC ──► FreeSWITCH ──AMQP──► kazoo_apps (stir)
   (untrusted)          classifies the     carries            decides, signs, verifies
                        source, strips     headers
                        X-AUTH-*
 STI-PA (iconectiv) ◄──HTTPS── stir          x5u servers ◄──HTTPS── stir
   (semi-trusted: signs         (untrusted: named by the caller of an inbound call)
    what we pin against)
 Crossbar /v2/stir ◄── operators (superduper), reseller admins (gated), anyone (two GETs)
 CouchDB ◄── stir (documents, the sealed keys on them)     node env ◄── STIR_KEK
```

Inside a node, one process (`stir/signer`) holds decrypted keys; every
other process holds kids.

## 3. Attackers and what stops them

### 3.1 A carrier-side peer sending inbound calls

Can send any SIP headers: a forged `Identity`, a `verstat` claiming
verification, an `x5u` pointing anywhere, oversized values, thousands of
calls.

| Attack | Control | Where | Test |
|---|---|---|---|
| Forged `Identity` verified because the peer controls the certificate the `x5u` names | The signature is checked against the certificate's key, and the certificate must chain to the STI-PA trust bundle; a `PUBLIC KEY` block in the fetched PEM is ignored when any certificate is present | `stir_ffi:public_key_of`, `validate_chain`; `stir/passport.verify`; `stir/trust.validate_chain` | `ffi_test` foreign-SPKI case, `passport_test` wrong key |
| A verstat the peer wrote itself | The verdict is read only from `X-AUTH-Verstat` / `X-AUTH-Attest` / `X-AUTH-Orig-ID`, which Kamailio stamps for a trusted carrier source and strips from every untrusted request, and only when the call carries the SBC's `X-AUTH-Token` naming a carrier resource whose policy is to trust upstream; a `P-` header or a `verstat` that reaches Kazoo any other way is ignored | Kamailio `trusted.cfg` `SETUP_AUTH_TRUSTED`, `defs.cfg` reserved headers; `stir/inbound`, `stir/carriers` | `inbound_test` |
| `x5u` pointing at an internal address (SSRF) | https only, no userinfo, port 443, IP-literal hosts in private, loopback, link-local, CGNAT, multicast ranges refused; what counts as a literal is `inet:parse_address`, so `127.1`, `2130706433`, `0x7f000001` and `0177.0.0.1` are refused too, as is any host OTP parses but does not spell canonically; TLS hostname verification against the OS store; no redirects | `stir/x5u.allowed`, `stir_ffi:http_get` | `x5u_test.address_policy_test`, `hostile_url_test`, `ffi_test` https-only |
| Residual: a hostname that resolves to an internal address holding a publicly trusted certificate (DNS rebinding) | Not closed; needs resolution-time checking in the transport | documented in `stir/x5u` | none |
| A slow or huge `x5u` response holding a call-setup worker | Fetch timeout per call (`verify_timeout_ms`, 1.5 s), body cap (256 KiB in `x5u`, 1 MiB in the transport), no redirects, `verify_mode = async` available | `stir/x5u`, `stir_ffi:http_get`, `stir/settings` | `x5u_test.body_cap_test` |
| Filling the certificate cache with distinct URLs | Each table capped at 2048 entries, enforced by `cache.sweep` (an atomic expiry pass plus oldest-first trim) from the fetch that went over and from every monitor pass -- no index list, which two concurrent inserts could lose each other's keys out of; only the `CERTIFICATE` blocks of an answer are kept, so a padded body costs a few KiB; negative cache for failures | `stir/x5u`, `kazoo/cache.sweep` | `x5u_test.cache_is_bounded_test`, `only_the_certificates_are_kept_test` |
| A certificate served with a valid signature but revoked | Indirect CRL from the STI-PA checked per chain (the anchor included), signer authenticated against the pinned roots, `cRLSign` required, refreshed on its own `nextUpdate`. When the CRL is stale or missing, verification continues without the revocation check, says so on the call, and alerts hourly (a deliberate choice of availability over a closed failure) | `stir_ffi:check_crl`, `stir/trust.validate_chain_report`, `stir/monitor` | `ffi_test.validate_chain_crl_test`, `monitor_test.crl_next_update_drives_the_refresh_test` |
| Replay of an old PASSporT | `iat` within 60 s either way of now, checked after the signature | `stir/passport.verify` | `passport_test` stale cases |
| Default: the carrier's verdict is trusted and nothing is fetched | Reduces the attack surface for calls from carriers trusted to verify to the SBC classification; the peer cannot reach the fetch path at all | `stir/settings` `trust_upstream_verstat`, per-resource `stir.verify` | `inbound_test`, `carriers_test` |

### 3.1a A customer's own endpoint (a registered device, a trunk)

| Attack | Control | Where | Test |
|---|---|---|---|
| Get A for a number the account does not own by presenting the call as a forward | The forwarding rule requires facts only the inbound hook writes: the inbound leg was a carrier call, its verdict passed, and its recorded caller number equals the forwarded caller id; otherwise B at most. Known limitation: a call forward is a loopback leg whose own route request makes `cf_stir` clear these facts, so the rule never fires today and forwards fall to the later rules. Keeping them on the loopback is not safe: a device's `custom_channel_vars`, which an account admin writes, ride onto the loopback too. The fix is to look the facts up by the inbound call's id, not to trust what the loopback carries | `stir/attest` rule 2, `cf_stir` | `attest_test` |
| Launder a C-attested spoof into A by forwarding it: a DID set to forward with the caller id kept, called by a spoofer whose provider signed C (the terminating carrier verifies the signature, so the verdict is a pass) | A corroborated forward is never signed above the inbound call's own level, whichever rule decides it, ownership included: its `STIR-Attest`, or its verstat's `-B`/`-C` suffix, when it verified, and C when it failed, was not validated, or nothing stated a level. A carrier's plain pass with no indicator records no level. `attest_forwarded` defaults to B | `stir/attest.forward`, `stir/outbound.inbound_level`, `stepswitch_stir` (`inbound_attest`) | `attest_test.a_forward_is_never_signed_above_the_call_it_forwards_test`, `outbound_test` |
| Get A for someone else's number through the platform's own records | `attest_verified_external_number` defaults to B, and an adopted external number (`gather_external_numbers` writes every caller id it finds as verified and adopted) never counts; the number import task honours `ported_in` only from a superduper admin, since a ported-in number goes straight into service as the account's own | `stir/numbers.row_verified`, `stir/settings`, `kt_numbers:import_ported_in/2` | `outbound_test`, `attest_test.verified_external_number_test` |
| Inject channel variables (`X-ecallmgr_*` SIP headers become CCVs) to fake those facts or a verdict | The SBC strips `X-ecallmgr` and `X-cav` from every untrusted request; the inbound hook clears every `STIR-*` variable on every call before writing its own | Kamailio `defs.cfg` reserved headers; `cf_stir` | Kamailio parse check; `cf_stir_tests` |
| Send its own `Identity` header and have Kazoo verify it as if from a carrier | Kazoo verifies only carrier-classified calls; a non-carrier source's `Identity` yields `No-TN-Validation` and no fetch | `stir/inbound.carrier_of` | `inbound_test` |
| Create a local resource pointing at its own PBX and write its own `verstat` | `trust_upstream` is honoured only for global carriers; a local carrier is verified by Kazoo | `stir/carriers` | `carriers_test`, `inbound_test` |
| Pass its own `Identity` through on an outbound leg | Passthrough requires the same corroboration as A on a forward, with a passed verdict; any other `Identity`, in any case, is dropped from a carrier leg whether it is signed or not: the request's `Custom-SIP-Headers` (a trunk's arrives as `identity`), the resource's or gateway's own headers, an originate's headers, and the signer's is set after the header merge and the formatters | `stir/outbound`; `stepswitch_stir` (the signer's value travels in the private endpoint key `Stir-Identity`; `take_own_identity/1` and `put_own_identity/2` from `stepswitch_util:format_sip_headers/3` drop every other `Identity` and write that one, so an endpoint that never went through the signer carries none), `stepswitch_originate` for the top-level headers | `outbound_test`; `stepswitch_stir_tests` `foreign_identity_*` |
| Fill the number and carrier caches with distinct values | Both tables bounded and swept from the monitor pass | `stir/numbers`, `stir/carriers`, `stir/monitor` | `monitor_test` |

### 3.2 Someone with read access to CouchDB (a dump, a backup, a replica)

| Attack | Control | Where | Test |
|---|---|---|---|
| Read the private keys | Sealed with AES-256-GCM under `STIR_KEK`, which is never in the database; a dump holds nonce, tag and ciphertext | `stir/vault`, `stir_ffi:aes_gcm_seal` | `vault_test` round trip and tamper |
| Move a sealed blob to another key document | The document id is the associated data; a blob opens only under its own id | `stir/vault.seal` | `vault_test.wrong_aad_test` |
| Read credentials | Same sealing, same AAD rule | `stir/credentials` | `credentials_test` |
| Learn which KEK a blob is under | Only the first 8 hex of SHA-256 of the KEK is stored, a discriminator, not a disclosure | `stir/vault.id` | `vault_test` |
| Residual: a database *write* (not read) can replace the certificate served at an `x5u`, the trust bundle, or a key's status | Not closed by the application; CouchDB access control and the audit `history` are the controls | operations | none |

### 3.3 A network position on the STI-PA path, or a wrong `stipa_api_url`

| Attack | Control | Where | Test |
|---|---|---|---|
| Serve a fake CA list | The list is a JWT whose signer must chain to an STI-PA pin: the shipped staging root, for the staging host only, and the roots an operator uploaded with role `stipa` (the production root, never taken from the list); no trust-on-first-use. Call chains anchor in the list plus the roots uploaded with role `calls` (the default), never in an STI-PA pin, and the leaf constraints keep an STI-PA signer certificate from passing as a SHAKEN leaf. A `roots` field from before the roles is read as call roots only | `stir/trust.check_signer`, `trust.call_anchors`, `trust.shipped_pins`, `priv/stipa-roots.pem` | `trust_test.refresh_needs_a_pinned_root_test`, `refresh_refuses_a_new_signer_test`, `an_uploaded_root_anchors_calls_test`, `a_call_root_never_anchors_an_stipa_signer_test`, `an_stipa_root_never_anchors_a_call_test`, `the_staging_root_pins_only_the_staging_host_test`, `legacy_roots_are_call_roots_only_test` |
| Replay an old, genuinely signed list | `exp` enforced; `sequence` must not go backwards, and the highest seen sits in a member of its own that no upload clears | `stir/trust.refresh` | `trust_test.refresh_refuses_an_expired_list_test`, `refresh_refuses_a_rollback_test`, `a_root_upload_does_not_reset_the_rollback_check_test` |
| Serve an empty, fake or old CRL | Checked before it is stored, and again per call: the signature verifies, the signer is the CRL's issuer, carries `cRLSign` and chains to the STI-PA pins for the host the CRL came from -- a set of its own, never the CA list or a call root, so no CA in the published list can mint a CRL signer -- and `thisUpdate`/`nextUpdate` hold now. A CRL older than the stored one from the same STI-PA host (`thisUpdate`, or `cRLNumber` for the same `thisUpdate`) is refused too; CRLs from different hosts are not compared. A refused CRL leaves the stored one in place and raises `trust:crl-refused`. An uploaded CRL is held to the pins of the host `stipa_api_url` names; one uploaded with its signer in the same file replaces both (a rotated signer). A CRL that never authenticated (uploaded ahead of its signer, stored before the check existed) is not used: calls are verified and marked unchecked, not refused | `stir_ffi:authenticate_crl`, `check_crl`, `validate_chain_with_anchors`, `stir/trust.refresh`, `trust.upload` | `ffi_test` wrong-signer and unchained-signer cases, `trust_test.refresh_refuses_a_crl_with_a_bad_signature_test`, `an_uploaded_crl_is_authenticated_test`, `a_crl_and_its_signer_uploaded_together_replace_both_test`, `only_a_crl_from_the_same_host_is_compared_test`, `an_unauthenticated_crl_leaves_calls_unchecked_test`, `a_signer_without_crl_sign_is_refused_test`, `refresh_refuses_an_expired_crl_test`, `refresh_refuses_an_older_crl_test`, `the_crl_signer_anchors_in_the_pinned_roots_test` |
| Downgrade the follow-on fetches to plaintext or another host | The list signer's `x5u` and the CRL's AIA must be https on the same host as the answer they came from; the transport refuses `http` | `stir/stipa.follow_on`, `stir_ffi:http_get` | `stipa_test` same-origin cases |
| Starve verification by making the CRL unavailable, or unusable | The stored CRL is kept and retried every pass, and nothing that fails the checks above is stored over it, so a bad CRL cannot make every call refuse. A stale or absent CRL does not fail the call: verification continues without the revocation check, marks the call and alerts hourly (§3.1) | `stir/trust.crl_not_refreshed`, `trust.crl_refused`, `stir/monitor` | `trust_test.refresh_keeps_the_old_crl_test`, `refresh_refuses_an_expired_crl_test`, `a_missing_crl_is_unchecked_not_closed_test` |

### 3.4 A reseller admin (the account-scoped API, off by default)

| Attack | Control | Where | Test |
|---|---|---|---|
| Reach anything while `allow_account_keys` is off | Every account-scoped route is 403 | `stir/api.permitted` | `api_test.permitted_*` |
| Create a key for another scope, read another scope's key or CSR | Scope forced to the requesting account; other scopes answer 404 | `api.requested_scope`, `api.visible` | `api_test`, `cb_stir_test` |
| Activate, retire, upload a certificate, touch trust or credentials | Not on the account-scoped route list; 403 | `api.account_route` | `api_test` |
| Learn platform operators' account and user ids from the audit trail | `history` redacted to `platform` on account-scoped reads | `api.redact_history` | `api_test.redact_history_test` |
| A plain `false` from the module's authorize being ignored by Crossbar on account paths | The Gleam binding answers `{stop, forbidden}`; the validate phase re-checks | `kazoo_gleam_cb:authorize_predicate`, `cb_stir.validate` | reasoning over `api_util.erl`; not testable without a node |

### 3.5 Anyone on the internet (the two public routes)

`GET /v2/stir/certs/{kid}.pem` and `GET /v2/stir/trust/{ca,crl}.pem`,
only without an accounts noun, only GET, only the certificate or trust
PEM field, only for documents of the right `pvt_type`. A `kid` of
`..` or another document's id reaches nothing but a 404
(`cb_stir_test`, `api_test.is_public_test`). Residual: the x5u
availability depends on the TLS front end that serves the API (its
certificate renewal must reach the running server) and on a node being
up; an unreachable
x5u makes every one of our calls unverifiable at terminating carriers,
which the monitor's self-check alerts on.

### 3.6 A compromised or misbehaving node, or a remote shell

| Fact | Consequence |
|---|---|
| The signer holds decrypted keys in its process state, re-reading each every 5 minutes; during a datastore outage it keeps every key it holds until the store answers again | A remote shell or a crash dump on that node yields those keys (`sys:get_state` and `erlang:fun_info` see through the closures; they protect renderings, not shells). BEAM cannot zero memory. This is the accepted residual: the node is the trust boundary, and the design keeps the exposure to one process and one node. |
| `Secret` and `Vault` render as a label under `string.inspect` | A crash report, an `io.debug`, or an assertion message cannot carry bytes (`vault_test.nothing_renders_the_bytes_test`). |
| The FFI wraps every key-bearing call in `try` and formats only the reason | A malformed PEM cannot put the key in a stacktrace (`stir_ffi` `public_key_pem`, `ecdsa_sign`, `generate_ec_key`). |
| Keys never travel over AMQP; the upstream `jwt.keys` path is unused | A broker read yields nothing. |
| A deleted key stays decrypted on other nodes for at most 5 minutes while the datastore answers; through an outage, until it answers again | Bounded residency without a bus message, traded for signing through outages. |

### 3.7 The operator (mistakes, not malice)

| Mistake | Control |
|---|---|
| Rotating `STIR_KEK` before re-sealing | The runbook is three steps and every one keeps signing: add `STIR_KEK_NEXT` and roll (the signer opens under either), `rekey` on one node, move the value and roll. `rekey` refuses to report success when nothing was re-sealed, lists per-item failures, and a blob already under the new KEK is recognised. |
| Losing `STIR_KEK` | Documented recovery: a new key and a new certificate; the stored ones are unrecoverable by design. Back it up with the deployment's other secrets. |
| Importing a key with a certificate that does not match, or the wrong SPC | Refused (`keys_test`). |
| Importing or uploading a chain file that also holds the private key (`import_key bundle.pem bundle.pem ...`) | Only the chain's `CERTIFICATE` blocks are stored, and only they are served at the `x5u`, whatever an older document's field holds (`stir_ffi:certificates_pem`, `keys.certificate_pem`; `keys_test.only_the_certificates_are_stored_and_served_test`). |
| Activating a key with no private key, or an expired certificate | Refused (`NoPrivateKey`, `InvalidTransition`). |
| Deleting a retired key whose certificate verifiers may still fetch | `sup` refuses without a trailing `confirm` and prints the date; the API refuses without `confirm=true` with a `still_served` error naming the date. |
| A node that came up before CouchDB | Views re-registered on every monitor pass; a missing view is `ViewMissing`, never "no keys". |
| Pointing `stipa_api_url` at the wrong place | A shipped pin applies to its own host only: staging material is trusted from the staging host alone, and any other host pins only the roots uploaded with role `stipa`. A production cluster pointed at staging, or at anything else, refuses the list (`no-pinned-root`, `signer-untrusted`) and keeps what it had. |
| Uploading a root with the wrong role | No role means `calls`, which is still held to the leaf checks; only an explicit `stipa` pins. An upload keeps its `CERTIFICATE` blocks alone, refuses any certificate that is neither a CA nor self-signed, replaces its own role's roots only, and logs who uploaded which subject and fingerprint. |

## 3.8 Alerts: how an operator hears

Every condition an operator has to act on is raised as a Kazoo alert
through `stir/alert` (a `kapps_alert` document, addressed to the master
account and, for a reseller-scoped key, to that account too), which an
administration UI or any API client can list through Crossbar's alerts
API. Each alert is throttled by a dedupe key so a condition that
persists raises once a day (or once an hour for the operational ones),
and the throttle slot is consumed only when the alert was recorded.
The throttle is the cluster's, not the node's: the last-raised time of
each dedupe key is a member of one document (`alerts` in the `stir`
database), written under the revision it was read at, so three nodes
running the same pass file one alert and not three. A node-local table
in front of it keeps the call path off the datastore and is the
fallback when the datastore cannot be reached at all.
The cluster's `system_config/alerts.enabled` must be true (the default).

| Condition | Dedupe | Interval |
|---|---|---|
| Active certificate within 60, 30, 14 days of `not_after`, no newer key | `kid:threshold` | daily |
| Certificate expired | `expired:kid` | daily |
| A key's own x5u cannot be fetched or serves another certificate | `kid:x5u` | daily |
| STI-PA CA list refused (expired, rolled back, unpinned signer) | `trust:<reason>` | daily |
| A fetched CRL refused (does not authenticate, out of its window, older than the stored one); the stored CRL was kept | `trust:crl-refused` | daily |
| STI-PA unreachable (CA list or CRL) and the stored CRL is missing or in its last hour, or a call was verified with no revocation check | `trust:crl` | hourly |
| No key-encryption key on this node | `no-vault` | hourly |
| A key cannot be opened under either KEK | `unsealable:kid` | daily |
| Signer restarted after a crash | `signer-restart` | hourly |
| More than 10 signing failures for one key in 5 minutes | `sign-failures:kid` | hourly |
| Monitor pass crashed | `monitor-crash` | hourly |
| `rekey` ended in failure or re-sealed nothing | `rekey` | hourly |
| Two active keys for one scope | `two-active:scope` | daily |
| More than 10 outbound calls on a node in 5 minutes could not be signed for one reason (they proceed unsigned) | `outbound:reason` | hourly |
| More than 10 inbound calls on a node in 5 minutes ended in the same verification failure | `inbound:reason` | hourly |

Not alerted yet: a carrier whose calls carry no verdict while its policy
says to trust it.

## 4. Availability

| Failure | Behaviour | Where |
|---|---|---|
| Datastore unreachable at start | The tree starts; the signer answers `UnknownKey`/`NoVault`; the monitor pass returns at once; `db.ensure` and views retry each pass | `stir/app`, `stir/monitor.pass` |
| Datastore slow or gone while signing | Every key the signer has already opened keeps signing for as long as the outage lasts (by design: outbound signing never stops because CouchDB is away); store reads inside the signer are bounded to 1 s with a per-key negative cache, so one hung read cannot serialise the node; the caller's call has a timeout and answers `Timeout`, never a crash; the condition is alerted hourly | `stir/signer` |
| Datastore unreachable while verifying | The trust material is cached per node and used from memory; with nothing cached, verification answers `No-TN-Validation`; with the carrier's verdict trusted by default nothing is fetched at all | `stir/trust`, `stir-shaken.md` §3.5a |
| STI-PA unreachable | Stored list kept; the CRL is retried every pass; a stale or missing CRL is alerted hourly and verification continues without the revocation check, marked as such | `stir/trust`, `stir/monitor` |
| x5u server slow or hostile | Bounded by the timeout, body cap, cache caps and negative cache | `stir/x5u` |
| Signer or monitor crash | One-for-one supervision, 10 restarts a minute; a crash does not print state (gleam_otp actors do not) | `stir.gleam` |
| A monitor pass that crashes or hangs | The next pass is scheduled before this one runs, and the pass runs in an unlinked process the actor waits on for 45 minutes; a crash or a stall is an `monitor-crash` alert and an error line, the actor goes on answering, and the hour is not lost | `stir/monitor.run` | `monitor_test.a_crashing_pass_does_not_take_the_actor_with_it_test` |
| Every node refreshing the trust material | The node whose name sorts first among those running `stir` refreshes on the cadence; any node refreshes when its stored CRL is inside `crl_margin_s` or nothing is stored, so a dead leader starves nobody | `stir/monitor.refreshes_on_the_cadence`, `kazoo/nodes` | `monitor_test.a_node_with_no_cluster_refreshes_test` |
| A slow x5u host and several keys | The self-checks are fetched at once, one process each, with a bounded wait, so N keys are one timeout and not N | `stir/monitor.self_check` | `monitor_test.the_self_checks_run_at_once_test` |
| Two nodes activating at once | Writes carry the revision they read; conflicts retry the transform; the new key is written active before the old is retired, so the window has two active keys rather than none, and the next monitor pass retires all but the longest-lived and alerts | `stir/store.update`, `stir/keys.activate`, `stir/monitor.one_active_per_scope` |
| Key rotation | Activation is a document write; every node's `select` cache refreshes within 30 s and the signer re-reads within 5 minutes; the old certificate stays served until `not_after` | `stir/keys`, `stir/signer` |
| Certificate expiry | Alerts at 60, 30 and 14 days; the monitor activates a pending key when its `not_before` passes and it outlives the active one | `stir/monitor` |

Latency budget: signing is one actor call and one ECDSA
signature, well under a millisecond after the first call warms the key,
with store reads inside the signer bounded to 1 s and negatively cached;
verification, when it runs at all (the carrier's verdict is trusted by
default), is the x5u fetch under `verify_timeout_ms` (the transport adds
up to 2 s of connect and stream allowances on top, so the real ceiling is
about 3.5 s), trust material from the node's revision-keyed cache, and
one chain validation. The hooks run the whole of it under one deadline
(`stir-shaken.md` §4).

## 5. What is deliberately not done

- No hardware or external KMS: the KEK is an environment variable on
  the node. A KMS-backed vault would change `stir/vault` only.
- No memory zeroing: BEAM does not offer it.
- No DNS-rebinding defence on the x5u fetch beyond TLS hostname
  verification.
- No edge rejection (438) of failed inbound verification; calls are
  marked, not refused.
- No cluster-wide invalidation message for the signer; residency is
  time-bounded instead (and unbounded through a datastore outage, by
  decision).
- No content-type restriction on `POST /v2/stir/credentials`: a
  form-encoded body may be logged by Crossbar at debug level; send JSON.
- A streamed 206 answer from an x5u server is reported as 200 unless it
  carries `content-range`; harmless, since a partial PEM fails parsing.
- Alerts need a master account; a cluster without one gets error-level
  log lines instead.
