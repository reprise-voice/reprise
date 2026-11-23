# STIR/SHAKEN

The `stir` application signs outbound carrier calls with a SHAKEN
PASSporT (the SIP `Identity` header) and verifies the `Identity` header of
inbound carrier calls. It generates and keeps its own private keys; the
certificate comes from your STI-CA through a CSR. This page is the
operator's sequence. The design is
[doc/engineering/stir-shaken.md](../engineering/stir-shaken.md), the
security model [doc/engineering/stir-shaken-security.md](../engineering/stir-shaken-security.md),
the API [applications/crossbar/doc/stir.md](../../applications/crossbar/doc/stir.md),
and every `sup` command is in
[applications/stir/README.md](../../applications/stir/README.md#sup).

Signing and verification are both off until you turn them on
(`sign_enabled`, `verify_enabled`).

## 1. Run the application with a key-encryption key

Private keys are stored sealed (AES-256-GCM) under a key-encryption key that
exists only in the environment of the nodes running `stir`:

```console
$ openssl rand -base64 32
```

Set the value as `STIR_KEK` on every kazoo_apps node that will run `stir`,
keep it in your secret store and back it up: without it the stored keys
cannot be recovered. Then add `stir` to those nodes' `KAZOO_APPS` (it is not
in the default list) or start it with `sup kapps_controller start_app stir`.
On a node that also runs `crossbar`, `stir` adds the `/v2/stir` API.

`sup stir_maintenance status` shows whether the node holds a
key-encryption key, the settings, the keys and the trust material.

## 2. Settings

In `system_config/stir`, at least:

```console
$ sup kapps_config set_default stir csr_organization "Example Telecom Inc"
$ sup kapps_config set_default stir x5u_base_url https://api.example.com/v2/stir/certs
```

`csr_organization` is the organisation named in CSRs (no default).
`x5u_base_url` is the public prefix under which verifiers fetch your
certificates; it must be an `https` URL that reaches the unauthenticated
`GET /v2/stir/certs/{KID}.pem` route of Crossbar. The attestation rules and
the other settings are described in the design document, section 3.5, and
typed with their defaults in `applications/stir/src/stir/settings.gleam`.

## 3. A key and its certificate

```console
$ sup stir_maintenance new_key <SPC> system      # prints the key id, its x5u and the CSR
  (have the STI-CA issue a certificate for the CSR)
$ sup stir_maintenance certificate <KID> chain.pem
$ sup stir_maintenance activate <KID>
$ sup stir_maintenance check_x5u <KID>
```

`<SPC>` is your service provider code. The scope `system` signs for the whole
platform; an account id instead gives a reseller its own key (off by
default, `allow_account_keys`). The same steps are available through the
API.

## 4. Trust material for verification

Verification needs the STI-PA's CA list and CRL. The tree ships only the
iconectiv staging root (`applications/stir/priv/stipa-roots.pem`); before
the first production refresh, upload the production STI-PA root obtained
directly from iconectiv, then refresh:

```console
$ sup stir_maintenance trust_upload stipa_root stipa-root.pem
$ sup stir_maintenance trust_refresh
```

## 5. Turn it on

```console
$ sup kapps_config set_default stir sign_enabled true
$ sup kapps_config set_default stir verify_enabled true
```

Outbound, `stepswitch` asks `stir` for the header when it builds a carrier
leg. Inbound, carriers are trusted according to the `stir.verify` setting of
their resource (`trust_upstream`, `verify` or `ignore`). The verdict is put on
the channel, where the `stir_shaken` callflow action can branch on it
([applications/stir/doc/stir_shaken.md](../../applications/stir/doc/stir_shaken.md)).

## Rotating the key-encryption key

See [Rotating the key-encryption key](../../applications/stir/README.md#rotating-the-key-encryption-key):
set `STIR_KEK_NEXT` everywhere, run `sup stir_maintenance rekey` once, then
move the new value to `STIR_KEK`.

## Not implemented

No ACME client (certificates are issued through a CSR by hand), no edge
rejection of failed calls, no `div` PASSporT for forwarded calls and no Rich
Call Data; see the design document, section 6.
