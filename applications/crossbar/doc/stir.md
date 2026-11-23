### STIR/SHAKEN

#### About STIR/SHAKEN

`/v2/stir` manages the signing keys, certificates, trust material and credentials the `stir` application uses to sign outbound carrier calls and verify inbound ones. The design is in `doc/engineering/stir-shaken.md` at the repository root; this page is the API.

Keys are born inside Kazoo. `POST /v2/stir/keys` generates an EC key, seals it under the node's key-encryption key (`STIR_KEK`), stores it with status `csr` and answers its metadata and a certificate signing request. The operator has the CA issue a certificate for the CSR and uploads the chain with `POST /v2/stir/keys/{KID}/certificate`, which makes the key `pending`; `POST /v2/stir/keys/{KID}` with `{"status": "active"}` makes it the signing key for its scope and retires the previous one. A retired key is still served at its `x5u` until its certificate expires, so verification of recent calls keeps working.

**No request carries a private key in either direction.** No verb accepts one, and none answers one: the listings answer metadata and, for a `csr` key, the CSR; the certificate route answers the public chain; the credentials route answers which names are set and when. There is no read path for a private key through Crossbar at all; the one way to bring an existing key in is `sup stir_maintenance import_key` on a node.

**Who may do what.** Every route under `/v2/stir` requires a superduper admin, except the two public ones: `GET /v2/stir/certs/{KID}.pem` (what a verifier fetches through a PASSporT's `x5u`) and `GET /v2/stir/trust/{ca,crl}.pem`, which need no token. Those two are public only under `/v2/stir`: the same paths under `/v2/accounts/{ACCOUNT_ID}/stir` are account requests and need a token like any other, and the account path does not serve them. The reseller scope, `/v2/accounts/{ACCOUNT_ID}/stir/keys`, answers 403 unless `allow_account_keys` is on in `system_config/stir`; with it on, an admin of that account (or a superduper admin) may create a key and read keys whose `scope` is that account, and nothing else.

A node with no `STIR_KEK` answers every create with a `no_vault` validation error on `vault`; `GET /v2/stir` says so under `vault`.

#### Validation errors

Every validation error this module answers, by the property it is on. Nothing else under `/v2/stir` is a validation error; the rest are system errors (`forbidden`, `not_found`, `invalid_method`, `datastore_unreachable`).

Property | Code | When
-------- | ---- | ----
`vault` | `no_vault` | The node has no usable `STIR_KEK`, so it cannot seal or open a key
`x5u_base_url` | `no_x5u_base_url` | `x5u_base_url` is not set in `system_config/stir`
`x5u_base_url` | `not_https` | It is set to something that is not `https://<host>[/path]` (userinfo included: it would be published in every PASSporT)
`organization` | `no_organization` | A create names no `organization` and `csr_organization` is not set in `system_config/stir`, so the CSR would have no subject organization
`key` | `unsealable` | The key is sealed under another key-encryption key
`key` | `crypto` | A cryptographic operation failed; the reason is in the node's log, not in the answer
`status` | `enum` | The body's `status` is neither `active` nor `retired`
`status` | `invalid_transition` | The key's current status does not allow that change
`status` | `no_private_key` | The key's sealed private key is missing, so it could not sign if it were made active
`certificate` | `required` | `POST .../certificate` with no `certificate` in the body
`certificate` | `mismatch` | The leaf is not for this key, or does not carry its SPC
`confirm` | `still_served` | `DELETE` of a retired key whose certificate has not expired, without `confirm=true`
`trust` | `stipa` | A refresh could not reach the STI-PA, or its answer was not trusted, or an upload was refused (not a CA or self-signed root, a CRL that does not authenticate or is older than the stored one); the message names the step, never a response body
`action`, `kind`, `pem`, `role` | `invalid` | `POST /v2/stir/trust` asks for something else than a refresh or an upload
`credentials` | `required` | `POST /v2/stir/credentials` with no credential in the body
`credentials` | `unsealable` | A stored credential is sealed under another key-encryption key
the member's own name | `invalid` | A member of the credentials body is not a credential this API keeps, or its value is empty, not a string, or longer than 4096 characters. The message names the member and says which of those it is; it never carries the value

#### Key

A key as the API shows it. Never the private key, never the id of the key-encryption key.

Key | Description | Type
--- | ----------- | ----
`id` | The kid: the key's id and the name of its certificate file | `string()`
`scope` | `system`, or the reseller account id the key signs for | `string()`
`alg` | `ES256` | `string()`
`spc` | The Service Provider Code the certificate is for | `string()`
`x5u` | Where verifiers fetch the certificate: `{x5u_base_url}/{id}.pem` | `string()`
`not_before` | The certificate's validity start, Gregorian seconds; `null` before a certificate is attached | `integer()`
`not_after` | The certificate's expiry, Gregorian seconds | `integer()`
`status` | `csr`, `pending`, `active` or `retired` | `string()`
`source` | `csr` (generated here, issued elsewhere), `acme` or `imported` | `string()`
`fingerprint` | `sha256:<hex>` of the leaf certificate | `string()`
`history` | What happened to the key, when, and by whom (`{auth account}/{user}` or `sup`); under `/v2/accounts/{ACCOUNT_ID}/stir` an actor outside that account reads `platform` | `array(object())`
`csr` | The certificate signing request, PEM; only on the create answer and on a `csr` key's read | `string()`

#### Schema for a new key (`stir_keys`)

Key | Description | Type | Default | Required
--- | ----------- | ---- | ------- | --------
`organization` | The organization (`O`) the CSR names: the legal name of the service provider the certificate is for | `string(1..64)` | `csr_organization` in `system_config/stir` | `false`
`scope` | `system` or an account id; under `/v2/accounts/{ACCOUNT_ID}/stir/keys` only that account | `string()` | `system` | `false`
`spc` | The Service Provider Code | `string(1..64)` |   | `true`

## Status

The platform's STIR/SHAKEN state in one read: per scope the active key, how many keys are in each status and how long the active certificate has left; when the trust material was fetched; which credentials are set; whether this node has a vault; and the settings a console's status strip shows.

> GET /v2/stir

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/stir
```
```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "node": "kazoo_apps@node1",
        "vault": {
            "loaded": true
        },
        "scopes": [
            {
                "scope": "system",
                "active": {
                    "id": "0123456789abcdef",
                    "scope": "system",
                    "alg": "ES256",
                    "spc": "999Y",
                    "x5u": "https://api.example.com/v2/stir/certs/0123456789abcdef.pem",
                    "not_before": 63900000000,
                    "not_after": 63907776000,
                    "status": "active",
                    "source": "csr",
                    "fingerprint": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                    "history": [
                        {"at": 63900000000, "what": "created", "by": "{ACCOUNT_ID}/{USER_ID}"},
                        {"at": 63900003600, "what": "certificate", "by": "{ACCOUNT_ID}/{USER_ID}"},
                        {"at": 63900007200, "what": "activated", "by": "{ACCOUNT_ID}/{USER_ID}"}
                    ]
                },
                "expires_in_days": 89,
                "keys": {"csr": 0, "pending": 0, "active": 1, "retired": 1}
            }
        ],
        "trust": [
            {"kind": "ca", "fetched_at": 63900000000, "source": "stipa", "detail": 42},
            {"kind": "crl", "fetched_at": 63900000000, "source": "stipa", "detail": 1789000000}
        ],
        "credentials": [
            {"name": "stipa_user", "set_at": 63900000000, "by": "{ACCOUNT_ID}/{USER_ID}"}
        ],
        "settings": {
            "sign_enabled": true,
            "verify_enabled": true,
            "verify_mode": "sync",
            "renewal_enabled": false,
            "allow_account_keys": false,
            "x5u_base_url": "https://api.example.com/v2/stir/certs"
        }
    },
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```

`vault` is `{"loaded": false, "reason": "STIR_KEK is not set"}` on a node that cannot seal or open keys. `expires_in_days` is `null` when the scope has no active key. `detail` is the CA list's sequence number for `ca` and the CRL's next update (unix seconds) for `crl`.

## List keys

Every key, in every status, as metadata. A cluster whose `stir` design document is not registered answers 503 `datastore_unreachable` rather than an empty list, and the node's log names the view.

> GET /v2/stir/keys

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/stir/keys
```
```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": [
        {
            "id": "0123456789abcdef",
            "scope": "system",
            "alg": "ES256",
            "spc": "999Y",
            "x5u": "https://api.example.com/v2/stir/certs/0123456789abcdef.pem",
            "not_before": 63900000000,
            "not_after": 63907776000,
            "status": "active",
            "source": "csr",
            "fingerprint": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            "history": []
        }
    ],
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```

## Create a key

Generates a key for the SPC, seals it, and answers the key with status `csr` and its CSR. `x5u_base_url` must be set in `system_config/stir` first: it is the prefix stamped into the key's `x5u`, and a key nobody could fetch the certificate of is refused with a `no_x5u_base_url` validation error on `x5u_base_url`.

It must also be an `https` URL with a host -- `https://<host>[/path]`, a trailing slash optional and dropped, no user information in it -- or the answer is a `not_https` validation error on the same property. A verifier fetches a PASSporT's `x5u` over https and nothing else (ATIS-1000074 §5.3.1, and what `stir`'s own verification path allows), so a key stamped with anything else would sign calls no one could verify; `sup stir_maintenance create_key` and `import_key` read the same setting the same way.

The CSR's subject is `C=US, O={organization}, CN=SHAKEN {spc}`. The organization is the request's `organization`, or else `csr_organization` in `system_config/stir`; there is no built-in default, and a create with neither is refused with a `no_organization` validation error on `organization`. `sup stir_maintenance new_key` uses `csr_organization`.

> POST /v2/stir/keys

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"spc": "999Y"}}' \
    http://{SERVER}:8000/v2/stir/keys
```
```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "id": "fedcba9876543210",
        "scope": "system",
        "alg": "ES256",
        "spc": "999Y",
        "x5u": "https://api.example.com/v2/stir/certs/fedcba9876543210.pem",
        "not_before": null,
        "not_after": null,
        "status": "csr",
        "source": "csr",
        "fingerprint": null,
        "history": [
            {"at": 63900000000, "what": "created", "by": "{ACCOUNT_ID}/{USER_ID}"}
        ],
        "csr": "-----BEGIN CERTIFICATE REQUEST-----\nMIIB...\n-----END CERTIFICATE REQUEST-----\n"
    },
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```

Without a key-encryption key on the node:

```json
{
    "data": {
        "vault": {
            "no_vault": {
                "message": "this node has no key-encryption key (STIR_KEK is not set): keys cannot be created, opened or sealed here"
            }
        }
    },
    "error": "400",
    "message": "invalid data",
    "status": "error"
}
```

## Fetch a key

The key's metadata. While its status is `csr` the answer carries `csr` as well, so the request can be taken to the CA again.

> GET /v2/stir/keys/{KID}

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/stir/keys/{KID}
```

## Attach the issued certificate

Uploads the chain the CA issued for the key's CSR. The leaf must be for this key and carry its SPC, or the answer is a validation error on `certificate`. The key becomes `pending`; `not_before`, `not_after` and `fingerprint` come from the leaf. `certificate` is at most 65536 characters, which is a leaf and its intermediates several times over; anything larger is refused by the schema before it is parsed.

> POST /v2/stir/keys/{KID}/certificate

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n"}}' \
    http://{SERVER}:8000/v2/stir/keys/{KID}/certificate
```

## Activate or retire a key

`active` makes a `pending` key the signing key of its scope and retires the scope's previous active key; every node picks it up within 30 seconds, with no restart. `retired` stops a key signing. A transition the status does not allow (activating a `csr` key) is a validation error on `status`, and so is a key whose sealed private key is missing, which could not sign if it were made active (`no_private_key`).

> POST /v2/stir/keys/{KID}

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"status": "active"}}' \
    http://{SERVER}:8000/v2/stir/keys/{KID}
```

## Remove a key

Removes a key that is not active, its sealed private key, its certificate and its CSR.

A retired key is still served at its `x5u` until its certificate expires, and deleting it stops that: a verifier fetching the certificate for a call the key signed gets a 404, and that call can no longer be verified. So a `DELETE` of a retired key whose `not_after` is still in the future is refused with a `still_served` validation error on `confirm`, naming the date --

```json
{
    "data": {
        "confirm": {
            "still_served": {
                "message": "verifiers may still fetch its certificate until 2026-12-08T08:00:00Z; send confirm=true to delete it anyway"
            }
        }
    },
    "error": "400",
    "message": "invalid data",
    "status": "error"
}
```

-- and goes ahead with `confirm=true` in the query string. Every other key (`csr`, `pending`, and a retired one whose certificate has expired) is removed without asking. `sup stir_maintenance delete` warns with the same date and deletes; the API asks first, because a request is easier to make by accident than a shell command.

> DELETE /v2/stir/keys/{KID}

```shell
curl -v -X DELETE \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    'http://{SERVER}:8000/v2/stir/keys/{KID}?confirm=true'
```

## Fetch a certificate (public)

The certificate chain of a key, as `application/pem-certificate-chain`. This is what a PASSporT's `x5u` points at, so it needs no token; it is the only thing about a key the public sees. A key with no certificate yet, and an unknown kid, are 404.

> GET /v2/stir/certs/{KID}.pem

```shell
curl -v -X GET \
    -H "Accept: application/pem-certificate-chain" \
    http://{SERVER}:8000/v2/stir/certs/{KID}.pem
```
```
-----BEGIN CERTIFICATE-----
MIIC...
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIID...
-----END CERTIFICATE-----
```

## Trust material

When the trusted CA list and the CRL were last fetched, and from where.

> GET /v2/stir/trust

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/stir/trust
```
```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": [
        {"kind": "ca", "fetched_at": 63900000000, "source": "stipa", "detail": 42},
        {"kind": "crl", "fetched_at": 63900000000, "source": "stipa", "detail": 1789000000}
    ],
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```

## Refresh or upload trust material

`{"action": "refresh"}` fetches the CA list and the CRL from the STI-PA at `stipa_api_url` and answers both statuses; a failure to reach the STI-PA is a `stipa` validation error saying which step failed. A CRL that came but does not authenticate (its signature, a signer with `cRLSign` chaining to a pinned STI-PA root, its `thisUpdate`/`nextUpdate` window) or is older than the stored one is not stored: the answer carries the CA status alone, the stored CRL is kept, and a `trust:crl-refused` alert says why. `pem` is at most 1048576 characters: room for the whole STI-PA CA list and a large CRL, and a ceiling on what one request can put in a document.

`{"kind": "ca", "pem": "...", "role": "stipa"|"calls"}` stores roots by hand and answers the CA status. Every `CERTIFICATE` block in `pem` must be a CA certificate or self-signed, and only those blocks are kept. The role says what they are for, and one never stands in for the other:

* `stipa` pins the STI-PA root: the CA list's signer and the CRL's signer must chain to it. It never anchors a call. The application ships the iconectiv staging root, and only for `authenticate-api-stg.iconectiv.com`; against any other `stipa_api_url` host, production included, a refresh is refused (`no-pinned-root`) until the STI-PA root is uploaded with this role.
* `calls` (the default when `role` is absent) is an extra anchor for call certificate chains beside the CA list, for a lab's private CA. It never pins the STI-PA.

An upload replaces the roots of its role and nothing else. Roots uploaded before roles existed are read as `calls` only: if the production STI-PA root was among them, the next production refresh is refused until it is uploaded again with `"role": "stipa"`.

`{"kind": "crl", "pem": "..."}` stores a CRL, a certificate in `pem` alone is the CRL's signer, and a CRL and a certificate together are both, which is how a rotated CRL signer is replaced; `role` is refused here. The CRL is checked against the signer (the uploaded one, else the stored one) before it is stored, with the signer held to the pins of the STI-PA host `stipa_api_url` names plus the uploaded `stipa` roots, and a CRL older than the stored one from the same host is refused. A CRL uploaded before any signer is stored, but not used for the revocation check until its signer arrives: calls are verified and marked unchecked meanwhile. Only the CRL block of an upload is kept, and only the certificate blocks of a signer.

The answer to a root upload, and the `ca` row of `GET /v2/stir/trust` and of `GET /v2/stir`'s `trust` list, carry `roots`: one entry per role that holds roots, `{"role": "stipa" | "calls" | "legacy", "count", "by", "at"}`, where `legacy` is roots uploaded before roles existed, which anchor calls only. A root upload's answer also says the `role` it was stored under.

> POST /v2/stir/trust

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"action": "refresh"}}' \
    http://{SERVER}:8000/v2/stir/trust
```

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"kind": "ca", "role": "stipa", "pem": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n"}}' \
    http://{SERVER}:8000/v2/stir/trust
```

## Fetch the trust files (public)

The CA bundle as `application/pem-certificate-chain` and the CRL as `application/pkix-crl`; no token, for an SBC that verifies at the edge with the same material.

> GET /v2/stir/trust/ca.pem
> GET /v2/stir/trust/crl.pem

```shell
curl -v -X GET \
    http://{SERVER}:8000/v2/stir/trust/ca.pem
```

## Credentials

The STI-PA login and the ACME external account binding are write-only. `GET` says which names are set, since when and by whom, and no answer or error this API builds carries a value.

What that promise covers, exactly. `stir` never answers a credential and never logs one: the sealed value goes from the request into the vault, and the module's own validation errors name the member and what is wrong with it (unknown name, empty, not a string, longer than 4096 characters) and never the text. Two things around it are Crossbar's, not `stir`'s:

* **The schema is deliberately toothless.** The generic validator puts the value that failed a rule into the error it builds, and Crossbar logs those errors at debug level. So `stir_credentials.json` applies no rule a credential value can fail -- no `minLength`, no `maxLength`, no `type`, and `additionalProperties` is `true` -- and only keeps `minProperties: 1`, which can only fail on an empty object. The names and the length are checked afterwards, by `stir/api.credentials_request`, which is value-blind. The one rule left that a body can fail is the schema's `type: object`: send `"data"` as a bare string and the string is the value in that error, so send an object.
* **Send the body as `application/json`.** Crossbar logs a form-encoded request body at debug level, with its values, before any module sees it. There is no content-type check on this route: the Gleam Crossbar binding exposes no request content type or headers to check it with. This is a known residual.

> GET /v2/stir/credentials

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/stir/credentials
```
```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": [
        {"name": "stipa_user", "set_at": 63900000000, "by": "{ACCOUNT_ID}/{USER_ID}"},
        {"name": "stipa_password", "set_at": 63900000000, "by": "{ACCOUNT_ID}/{USER_ID}"}
    ],
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```

## Set credentials

The body is an object whose keys are credential names -- `stipa_user`, `stipa_password`, `acme_eab_kid`, `acme_eab_hmac` -- and whose values are the secrets, as `application/json`. Each is sealed under the node's key-encryption key at once. The answer is the same list `GET` gives. A body with no credential in it is a `required` validation error on `credentials`; a name this API does not keep, an empty value, a value that is not a string, and a value longer than 4096 characters are each a validation error on that member, naming it and not its value.

> POST /v2/stir/credentials

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"stipa_user": "{STIPA_USER}", "stipa_password": "{STIPA_PASSWORD}"}}' \
    http://{SERVER}:8000/v2/stir/credentials
```

## Remove a credential

> DELETE /v2/stir/credentials/{NAME}

```shell
curl -v -X DELETE \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/stir/credentials/stipa_password
```

## The reseller scope

With `allow_account_keys` on in `system_config/stir`, a reseller account may hold its own signing key, which then signs the calls of that account and its descendants instead of the platform's key. The account's admin creates it and reads its keys through the account path; the key's `scope` is always that account, said or not. Attaching the certificate, activating and retiring stay platform operations on `/v2/stir/keys/{KID}`.

> GET /v2/accounts/{ACCOUNT_ID}/stir/keys
> POST /v2/accounts/{ACCOUNT_ID}/stir/keys
> GET /v2/accounts/{ACCOUNT_ID}/stir/keys/{KID}

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"data": {"spc": "123A"}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/stir/keys
```

A key's `history` on this path names no account but the requesting one: every event keeps its `at` and `what`, and a `by` that is not of this account -- the platform operator attaching the certificate, activating the key, or a `sup` command -- reads `platform`. Under `/v2/stir` the history is answered as it is stored.

```json
{
    "data": {
        "id": "fedcba9876543210",
        "scope": "{ACCOUNT_ID}",
        "status": "active",
        "history": [
            {"at": 63900000000, "what": "created", "by": "{ACCOUNT_ID}/{USER_ID}"},
            {"at": 63900003600, "what": "certificate", "by": "platform"},
            {"at": 63900007200, "what": "activated", "by": "platform"}
        ]
    },
    "status": "success"
}
```

Everything the account path answers 403 to, in one list:

* `allow_account_keys` is off in `system_config/stir` (it is off by default), whoever is asking -- a superduper admin on this path included.
* The route is not one of the three above: attaching a certificate, activating, retiring, deleting, the trust routes, the credentials routes, the status page. Those are platform operations on `/v2/stir`.
* The token is not a superduper admin's and not an admin's of that very account: an admin of another account, a non-admin user of this one, and a token for an ancestor account all get 403, even though Crossbar's own authorization lets an ancestor's token onto an `/accounts/{id}` path.
* `POST .../keys` whose body carries a `scope` that is not this account (`system` included). The scope is forced to the account, so naming another one is refused rather than quietly corrected.
* The certificate and trust files, which are public under `/v2/stir` but not here: `GET /v2/accounts/{ACCOUNT_ID}/stir/certs/{KID}.pem` and the `trust/*.pem` paths are account requests for routes the account path does not serve.

A key that exists but is not this account's is 404, not 403: the account path is not told which kids exist elsewhere. The same 403 decision is made twice, in `authorize` and again at the top of `validate`, because Crossbar ignores a plain `false` from a module's authorize once its own authorization has said yes.
