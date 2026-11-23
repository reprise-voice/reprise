# stir

STIR/SHAKEN for Reprise: the signing keys and certificates, PASSporT signing
for outbound carrier calls, and verification of inbound ones.

It is a [Gleam](https://gleam.run) OTP application, compiled to BEAM and
shipped in the `kazoo` release like every other application. It runs on
`kazoo_apps` nodes, started by `kapps_controller` when `stir` is in
`KAZOO_APPS` or in the `kapps` list of `system_config/kapps_controller`. Its
Erlang side is `src/stir_ffi.erl`; everything else it needs from Kazoo comes
through `core/kazoo_gleam`. The design is in
`doc/engineering/stir-shaken.md` at the repository root, the security model
in `doc/engineering/stir-shaken-security.md`, and the API in
`applications/crossbar/doc/stir.md`.

## What it does

- **Outbound.** `stepswitch` asks `stir@outbound` for headers when it builds
  a carrier leg. `stir` decides the attestation level, picks the key for the
  account's scope, signs the PASSporT, and answers the `Identity` header and
  the channel variable that keeps FreeSWITCH from sending it twice.
- **Inbound.** When callflow wins a route for a call that arrived from a
  carrier, `stir@inbound` fetches the signer's certificate from the `x5u`,
  verifies the header, and writes the verdict onto the channel.
- **Keys.** Generated here, sealed under a key-encryption key that lives
  only in the node's environment, served at a public URL for verifiers,
  renewed through a CSR the operator has issued (ACME is not built yet).

## Modules

| Module | What it is |
|---|---|
| `stir` | the supervision tree: the signer and the monitor |
| `stir/app` | the OTP callbacks: mark the application, create the database, register the views |
| `stir/system` | the application's name and its logging |
| `stir/db` | the `stir` database |
| `stir/settings` | `system_config/stir`, typed, with every default |
| `stir/key` | a key's metadata: scope, status, source, validity, history; the document shape |
| `stir/secret` | a private key or credential in memory: opaque, never inspected |
| `stir/vault` | the key-encryption key from `STIR_KEK`; AES-256-GCM seal and open |
| `stir/keys` | the store: create (generate, seal, CSR), import, attach a certificate, activate, retire, delete, select for an account |
| `stir/signer` | the one process per node that opens keys and signs |
| `stir/credentials` | write-only credentials (STI-PA login, ACME account binding), sealed like keys |
| `stir/jws` | compact JWS, ES256 |
| `stir/passport` | the PASSporT claims, canonical JSON, the `Identity` header, verification |
| `stir/http` | one transport type, injected so tests never touch the network |
| `stir/x5u` | fetching a signer's certificate, cached a day |
| `stir/stipa` | the STI-PA's CA list and indirect CRL |
| `stir/trust` | the stored trust material and chain validation |
| `stir/monitor` | hourly, in a spawned pass the actor waits on: activate pending keys, reconcile two actives, expiry alerts, x5u self-checks, trust refresh (one leader node on the cadence, every node when its CRL is near stale), cache sweeps |
| `stir/alert` | every Kazoo alert this application raises, throttled through a document in the `stir` database (node-local fallback); addressed to the master account and, for a reseller's key, to that account |
| `stir/store` | document writes that carry the revision they read, retried on conflict; the shape of a sealed blob on a document |
| `stir/report` | the pure text of the `sup` reports, testable and not `sup`-callable |
| `stir/views` | registering the application's views, at start and on every monitor pass |
| `stir/api` | the pure half of the Crossbar module: routes, permissions, request and answer shapes |
| `stir/attest` | the attestation rules of `stir-shaken.md` §3.5, pure: A, B, C or passthrough from the facts of a call |
| `stir/numbers` | who owns a number, from the number manager and the account's verified external numbers, cached a minute |
| `stir/outbound` | `headers/1`: the `Identity` header, the exclude regex and the channel variables for a carrier leg, called from `stepswitch_stir`; fails open |
| `stir/inbound` | `verify/1`: the verdict on a call from a carrier, from the carrier's own stamps or this node's verification, called from `cf_stir`; one deadline, never raises |
| `stir/carriers` | the resource behind an `X-AUTH-Token` and its `stir.verify` policy, cached a minute |
| `cf_stir_shaken` | the callflow action `stir_shaken`: branch `passed`, `failed` or `none` on the verdict; the failed caller id name prefix |
| `cb_stir` | the Crossbar module, `/v2/stir` |
| `stir_maintenance` | the `sup` commands |
| `stir_ffi.erl` | cryptography (`public_key`, `crypto`), HTTPS, the environment |
| `stir_inbound_ffi.erl` | the Erlang side of the inbound path: the guarded call the Erlang hooks make, the caller id name setter |
| `stir_ops_ffi.erl` | what the `sup` commands and the signer need from the VM: file reads with reasons, file modes, a send that cannot raise |

## Keys, and what never happens to them

- Every private key is generated inside Kazoo. No Crossbar route, `sup`
  command or AMQP message accepts one, and none answers one. The one
  exception is `sup stir_maintenance import_key`, which reads a file on the
  node, for a certificate whose key was generated elsewhere.
- At rest a key is a field of its own document, sealed with AES-256-GCM
  under `STIR_KEK` (an environment variable the node reads at start; keep
  it in the deployment's secret store) and
  written with the document in one save, so a key is never on record
  without its private key and the signer opens one with a single read.
  Never an attachment: an attachment is what a storage plan can send to a
  bucket the application does not control, and the keys stay in the
  database. Without `STIR_KEK` the application runs, cannot create or
  open keys, and says so in `status`.
  A lost `STIR_KEK` makes every stored key unrecoverable: back it up, and
  expect to recover with a new key and certificate otherwise.
- One process per node, the signer, opens keys and signs; nothing else holds
  a decrypted key, and no key is in an ETS table. Through a datastore
  outage it keeps signing with every key it has already opened, for as
  long as the outage lasts, and says so with an alert.
- `stir/secret.Secret` and `stir/vault.Vault` keep their bytes behind a
  closure, so `string.inspect` and a crash report render a label, never
  the bytes. Still: do not pass one to a document or a log.
- Every create, certificate upload, activation, retirement and deletion is
  appended to the key document's `history` with the acting account and user.

## Databases and documents

`stir`, a system database. `stir_key` (metadata plus the key's public key,
its private key sealed in `sealed_private_key`, and `csr` until a
certificate is attached, `certificate` after), `stir_trust` (`trust-ca`,
`trust-crl` with the PEM in `bundle` and, for the CRL, the signer's in
`signer`), `stir_credentials` (one per name, the value sealed in
`sealed_value`). Everything a document owns is a field of it; the
application writes no attachments, so no storage plan decides where its
material goes. Views in
`priv/couchdb/views/stir.json` (`keys_by_scope`, `credentials_by_name`,
`trust_by_kind`), registered on start, on every platform refresh, and
again by every monitor pass.

The CA-list signer and the CRL signer must chain to a pinned STI-PA
root; nothing is trusted on first use. `priv/stipa-roots.pem` ships the
iconectiv **staging** root, and pins the staging host
(`authenticate-api-stg.iconectiv.com`) and no other: the production host
answered nothing from the network this was built on, so before the first
production refresh an operator uploads the production STI-PA root with
`POST /v2/stir/trust {"kind": "ca", "role": "stipa", "pem": ...}`, taken
from iconectiv directly, never from the CA list it is meant to
authenticate. A `"kind": "ca"` upload without a role is a call root: an
extra anchor for call chains that never pins the STI-PA. The two live in
`stipa_roots` and `call_roots` on `trust-ca` and survive every refresh; a
`roots` field from before the roles is read as call roots only. A
fetched or uploaded CRL is authenticated, and refused when older than
the stored one from the same STI-PA host, before it is used; one not
yet authenticated (uploaded ahead of its signer, or stored before this
check existed) leaves calls verified without the revocation check
(`stir/trust`).

## sup

| Command | What |
|---|---|
| `sup stir_maintenance status` | version, node, database, vault, settings, signer statistics (opened keys, signs, refusals, stale-since), every active key per scope with days left, trust ages and the CRL's next update, the last monitor pass |
| `sup stir_maintenance keys` | every key's metadata |
| `sup stir_maintenance new_key <spc> <scope>` | generate a key and print its CSR; scope is `system` or an account id; the CSR names `csr_organization` from `system_config/stir` as its organization (no default) |
| `sup stir_maintenance csr <kid>` | print the CSR again |
| `sup stir_maintenance certificate <kid> <chain.pem>` | attach the issued chain |
| `sup stir_maintenance import_key <key.pem> <chain.pem> <spc> <scope>` | the one-time import: refuses a key file readable by group or others, deletes the key file itself on success, and tells you to delete it on every other outcome |
| `sup stir_maintenance activate <kid>` | make a pending key the active one for its scope |
| `sup stir_maintenance retire <kid> <confirm>` | stop signing with it. Any second word but `confirm` prints what retiring would do — including the scope being left with no signing key — and changes nothing |
| `sup stir_maintenance delete <kid> <confirm>` | remove a key that is not active. Any second word but `confirm` prints what deleting would do — the certificate verifiers may still be fetching, and the scope being left with no signing key — and changes nothing |
| `sup stir_maintenance rekey` | re-seal everything under `STIR_KEK_NEXT`; signing continues on every node that has it set (see "Rotating the key-encryption key" below) |
| `sup stir_maintenance trust_refresh` | fetch the CA list and CRL now |
| `sup stir_maintenance trust_upload <ca, stipa_root or crl> <file.pem>` | store trust material from a file: `ca` an extra call anchor, `stipa_root` the STI-PA root refreshes pin, `crl` a CRL or its signer |
| `sup stir_maintenance monitor_now` | run the hourly pass now and print what it did |
| `sup stir_maintenance check_x5u <kid or all>` | fetch a key's own certificate URL, bypassing the cache |
| `sup stir_maintenance sign <orig> <dest> <attest> <kid or system>` | a token, for a hand test |
| `sup stir_maintenance verify <identity header value>` | a verdict, for a hand test; `NOT verified` first when the chain is untrusted |

None of them prints a private key.

## Rotating the key-encryption key

Every step keeps signing:

1. Generate a new value (base64 of 32 random bytes, for example
   `openssl rand -base64 32`),
   set it as `STIR_KEK_NEXT` on every node running `stir`, keeping
   `STIR_KEK` as it is, and restart the nodes one at a time. The signer
   opens keys under either value.
2. On one node, run `sup stir_maintenance rekey`. It re-seals every key and
   credential under `STIR_KEK_NEXT`, lists any item that failed, and refuses
   to report success when nothing was re-sealed; a blob already under the
   new value is recognised and left alone.
3. Move the new value to `STIR_KEK`, remove `STIR_KEK_NEXT`, and restart the
   nodes one at a time again.

`sup stir_maintenance status` shows the key-encryption key a node holds and,
while rotating, the one in `STIR_KEK_NEXT`.

## Building and testing

With Erlang/OTP 28 and Gleam installed, run `gleam test` here. Otherwise use a
builder image with that toolchain (the `builder` stage of
`docker/reprise/Dockerfile` installs it; `$BUILDER` is its tag), from the
repository root:

```console
$ docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src \
    -w /src/applications/stir "$BUILDER" gleam test
$ make gleam-check
```

Tests are gleeunit under `test/`, mirroring `src/`; `test/fixtures/` holds
public material only: a generated example SHAKEN chain, STI-PA staging trust
material, and keys generated for the tests.
