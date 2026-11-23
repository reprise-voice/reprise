//// The Crossbar module `cb_stir`, serving `/v2/stir`.
////
//// ```
//// GET    /v2/stir                         status: keys per scope, expiry, trust, vault
//// GET    /v2/stir/keys                    key metadata, never a private key
//// POST   /v2/stir/keys                    {"spc": "999Y", "scope": "system", "organization": "..."} -> key + CSR
//// GET    /v2/stir/keys/{kid}              one key's metadata (and its CSR while status is csr)
//// POST   /v2/stir/keys/{kid}              {"status": "active" | "retired"}
//// DELETE /v2/stir/keys/{kid}              a key that is not active; ?confirm=true while still served
//// POST   /v2/stir/keys/{kid}/certificate  {"certificate": "<chain PEM>"}
//// GET    /v2/stir/certs/{kid}.pem         public: the certificate chain, application/pem-certificate-chain
//// GET    /v2/stir/trust                   when the CA list and CRL were fetched
//// POST   /v2/stir/trust                   {"action": "refresh"} or {"kind": "ca"|"crl", "pem": "...", "role": "stipa"|"calls"}
//// GET    /v2/stir/trust/ca.pem            public: the CA bundle
//// GET    /v2/stir/trust/crl.pem           public: the CRL
//// GET    /v2/stir/credentials             which are set and since when; never a value
//// POST   /v2/stir/credentials             {"<name>": "<value>", ...} write-only
//// DELETE /v2/stir/credentials/{name}
//// ```
////
//// Every write requires a superduper admin. The two public routes are the
//// only unauthenticated ones, and only without an accounts noun: the same
//// tokens under `/v2/accounts/{id}/stir` are an account request and need a
//// token. `/v2/accounts/{id}/stir/...` (the reseller scope) answers 403
//// unless `allow_account_keys` is on, and then only for keys of that
//// account's scope; a key answered there has the platform's account and
//// user ids taken out of its history (`api.redact_history`).
////
//// No request carries a private key in either direction: the create answer
//// is metadata and a CSR, the credentials answer is a list of names, and no
//// answer or error this module builds carries a credential value. The
//// residuals are Crossbar's own: the generic schema check would put a
//// failing value into its error (which is why `stir_credentials.json`
//// applies no rule a value can fail, and `api.credentials_request` is the
//// only gate), and a form-encoded body is logged by Crossbar at debug
//// level before this module sees it -- send credentials as
//// `application/json`.
////
//// ## How the decisions reach Crossbar
////
//// `authenticate` is consulted only when no token module authenticated the
//// request (`api_util:is_authentic_noun`), so `False` here means the token
//// check stands. `authorize` is consulted after `cb_simple_authz`, which
//// says `true` for a superduper admin and for any `/accounts/{id}` in the
//// token's tree; once it has, a plain `false` from this module is ignored
//// (`api_util:is_permitted_verb_on_module` only honours a `stop`). The
//// same decision (`stir/api.permitted`) is therefore made again at the top
//// of `validate` and answers `forbidden`, which is what makes the reseller
//// path a 403 when it should be.
////
//// Schemas: `stir_keys.json`, `stir_key_status.json`,
//// `stir_certificate.json`, `stir_trust.json`, `stir_credentials.json` and
//// `system_config.stir.json` in `applications/crossbar/priv/couchdb/schemas/`;
//// docs in `applications/crossbar/doc/stir.md`. The decisions themselves
//// are in `stir/api`.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/result
import kazoo/crossbar.{type Context}
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/modb
import stir/api
import stir/credentials
import stir/http
import stir/key.{type Key}
import stir/keys
import stir/secret
import stir/settings
import stir/signer
import stir/system
import stir/trust
import stir/vault

pub const noun = "stir"

/// The schemas the bodies are checked against.
pub const keys_schema = "stir_keys"

pub const key_status_schema = "stir_key_status"

pub const certificate_schema = "stir_certificate"

pub const trust_schema = "stir_trust"

pub const credentials_schema = "stir_credentials"

/// How long a trust refresh may take: two fetches from the STI-PA.
const refresh_timeout_ms = 30_000

pub fn init() -> Nil {
  crossbar.bind(noun, [
    crossbar.AllowedMethods(allowed_methods),
    crossbar.ResourceExists(resource_exists),
    crossbar.Authenticate(authenticate),
    crossbar.Authorize(authorize),
    crossbar.ContentTypesProvided(content_types_provided),
    crossbar.Validate(validate),
    crossbar.Post(post),
    crossbar.Delete(delete),
  ])
}

pub fn allowed_methods(tokens: List(String)) -> List(String) {
  api.allowed_methods(tokens)
}

pub fn resource_exists(tokens: List(String)) -> Bool {
  api.resource_exists(tokens)
}

/// The public routes need no token. A path with an accounts noun is not
/// one of them, whatever its tokens say.
pub fn authenticate(context: Context) -> Bool {
  api.is_public(crossbar.req_verb(context), tokens(context), account(context))
}

pub fn authorize(context: Context) -> Bool {
  permitted(context)
}

pub fn content_types_provided(
  context: Context,
  tokens: List(String),
) -> Context {
  case api.content_type(tokens) {
    option.Some(content_type) ->
      crossbar.provide_content_types(context, [content_type])
    option.None -> context
  }
}

// ---------------------------------------------------------------------------
// The request
// ---------------------------------------------------------------------------

fn tokens(context: Context) -> List(String) {
  api.tokens_of(crossbar.req_nouns(context))
}

fn account(context: Context) -> Option(String) {
  api.account_of(crossbar.req_nouns(context))
}

fn caller(context: Context) -> api.Caller {
  api.Caller(
    superduper: crossbar.is_superduper_admin(context),
    account_admin: crossbar.is_account_admin(context),
    auth_account: crossbar.auth_account_id(context),
  )
}

/// Whether `allow_account_keys` is on, read only when the account path
/// asks: it is a settings read, and `/v2/stir` does not pay for it.
fn allow_account_keys() -> Bool {
  settings.load(system.live()).allow_account_keys
}

fn permitted(context: Context) -> Bool {
  api.permitted(
    crossbar.req_verb(context),
    tokens(context),
    account(context),
    caller(context),
    allow_account_keys,
  )
}

fn actor(context: Context) -> String {
  api.actor(crossbar.auth_account_id(context), crossbar.auth_user_id(context))
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

pub fn validate(context: Context, tokens: List(String)) -> Context {
  case permitted(context) {
    False -> crossbar.add_system_error(context, "forbidden")
    True -> validate_route(context, crossbar.req_verb(context), tokens)
  }
}

fn validate_route(
  context: Context,
  verb: String,
  tokens: List(String),
) -> Context {
  let kz = system.live()
  case verb, api.route(tokens) {
    "GET", Ok(api.Status) -> status(kz, context)

    "GET", Ok(api.Keys) -> list_keys(kz, context)
    "POST", Ok(api.Keys) -> validate_new_key(kz, context)
    "GET", Ok(api.Key(kid)) -> read_key(kz, context, kid)
    "POST", Ok(api.Key(kid)) -> validate_status_change(kz, context, kid)
    "DELETE", Ok(api.Key(kid)) -> validate_delete_key(kz, context, kid)
    "POST", Ok(api.KeyCertificate(kid)) ->
      validate_certificate(kz, context, kid)

    "GET", Ok(api.Certificate(kid)) ->
      serve(
        context,
        keys.certificate_pem(kz, kid) |> result.map_error(key_failure),
        api.pem_chain,
      )

    "GET", Ok(api.Trust) -> trust_status(kz, context)
    "POST", Ok(api.Trust) -> validate_trust(context)
    "GET", Ok(api.TrustPem(kind)) ->
      serve(
        context,
        trust.pem(kz, kind) |> result.map_error(trust_failure),
        case kind {
          trust.Ca -> api.pem_chain
          trust.Crl -> api.pkix_crl
        },
      )

    "GET", Ok(api.Credentials) -> credentials_status(kz, context)
    "POST", Ok(api.Credentials) -> validate_credentials(context)
    "DELETE", Ok(api.Credential(_name)) ->
      crossbar.set_resp_status_success(context)

    _, _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

fn status(kz: Kazoo, context: Context) -> Context {
  case keys.list(kz) {
    Error(error) -> fail(context, key_failure(error))
    Ok(all) ->
      crossbar.respond(
        context,
        api.status_doc(
          all,
          modb.now(),
          trust.status(kz) |> result.unwrap([]),
          trust.root_sets(kz),
          credentials.status(kz) |> result.unwrap([]),
          vault_present(),
          system.node_name(),
          settings.load(kz),
        ),
      )
  }
}

/// Whether this node has a key-encryption key, and if not why. The vault
/// itself is not kept: this is a status line, not a key.
fn vault_present() -> Result(Nil, String) {
  case vault.load() {
    Ok(_vault) -> Ok(Nil)
    Error(vault.Missing(variable)) -> Error(variable <> " is not set")
    Error(vault.Malformed(variable)) ->
      Error(variable <> " is not base64 of 32 bytes")
  }
}

fn list_keys(kz: Kazoo, context: Context) -> Context {
  case keys.list(kz) {
    Error(error) -> fail(context, key_failure(error))
    Ok(all) ->
      all
      |> list.filter(api.visible(_, account(context)))
      |> list.map(fn(k) { shown(context, key.to_public(k)) })
      |> doc.List
      |> crossbar.respond(context, _)
  }
}

/// A key as this path may see it: on the account path the history names
/// no account but the requesting one.
fn shown(context: Context, public: Value) -> Value {
  api.redact_history(public, account(context))
}

/// The key, when it is one this path may see.
fn load_key(kz: Kazoo, context: Context, kid: String) -> Result(Key, Failure) {
  use found <- result.try(keys.get(kz, kid) |> result.map_error(key_failure))
  case api.visible(found, account(context)) {
    True -> Ok(found)
    False -> Error(NotFound)
  }
}

/// A delete asks once more when the key's certificate is still being
/// fetched: a retired key stays at its `x5u` until the certificate
/// expires, and removing it there makes every call it signed
/// unverifiable from then on. `?confirm=true` says go ahead, which is
/// what `sup stir_maintenance delete` does by warning and deleting.
fn validate_delete_key(kz: Kazoo, context: Context, kid: String) -> Context {
  case load_key(kz, context, kid) {
    Error(failure) -> fail(context, failure)
    Ok(found) ->
      case api.still_served_until(found, modb.now()), confirmed(context) {
        option.Some(until), False ->
          fail(
            context,
            Invalid(
              ["confirm"],
              "still_served",
              "verifiers may still fetch its certificate until "
                <> until
                <> "; send confirm=true to delete it anyway",
            ),
          )
        _, _ -> crossbar.set_resp_status_success(context)
      }
  }
}

/// `?confirm=true` in the query string.
fn confirmed(context: Context) -> Bool {
  case crossbar.req_param(context, "confirm") {
    option.Some(doc.Bool(True)) | option.Some(doc.String("true")) -> True
    _ -> False
  }
}

fn key_exists(kz: Kazoo, context: Context, kid: String) -> Context {
  case load_key(kz, context, kid) {
    Ok(_key) -> crossbar.set_resp_status_success(context)
    Error(failure) -> fail(context, failure)
  }
}

/// A `csr` key answers its CSR alongside, which is what the operator takes
/// to the CA.
fn read_key(kz: Kazoo, context: Context, kid: String) -> Context {
  case load_key(kz, context, kid) {
    Error(failure) -> fail(context, failure)
    Ok(found) ->
      case found.status {
        key.Csr ->
          case keys.csr_pem(kz, kid) {
            Ok(csr) ->
              crossbar.respond(
                context,
                shown(context, api.key_with_csr(found, csr)),
              )
            Error(_) ->
              crossbar.respond(context, shown(context, key.to_public(found)))
          }
        _ -> crossbar.respond(context, shown(context, key.to_public(found)))
      }
  }
}

/// A key is created only when this node can seal it, there is a prefix
/// for its `x5u` and an organization for its CSR; all are checked here so
/// nothing is generated for nothing.
fn validate_new_key(kz: Kazoo, context: Context) -> Context {
  use context <- crossbar.validate_request_data(keys_schema, context)
  let config = settings.load(kz)
  let body = crossbar.doc(context)
  case
    api.create_decision(
      body,
      account(context),
      caller(context),
      allow_account_keys,
    ),
    api.x5u_base_checked(config),
    api.csr_organization(body, config),
    vault_present()
  {
    // A scope this path may not create in is not a malformed body: it is
    // the reseller scope refusing, which the doc promises as a 403.
    Error(Nil), _, _, _ -> crossbar.add_system_error(context, "forbidden")
    _, Error(problem), _, _ -> fail(context, x5u_base_failure(problem))
    _, _, Error(Nil), _ -> fail(context, NoOrganization)
    _, _, _, Error(reason) -> fail(context, NoVault(reason))
    Ok(_scope), Ok(_base), Ok(_organization), Ok(Nil) ->
      crossbar.set_resp_status_success(context)
  }
}

fn validate_status_change(kz: Kazoo, context: Context, kid: String) -> Context {
  use context <- crossbar.validate_request_data(key_status_schema, context)
  case api.requested_status(crossbar.doc(context)) {
    Error(Nil) ->
      crossbar.add_validation_error(
        context,
        ["status"],
        "enum",
        "status is active or retired",
      )
    Ok(_status) -> key_exists(kz, context, kid)
  }
}

fn validate_certificate(kz: Kazoo, context: Context, kid: String) -> Context {
  use context <- crossbar.validate_request_data(certificate_schema, context)
  case doc.get_string(crossbar.doc(context), ["certificate"]) {
    Ok(_pem) -> key_exists(kz, context, kid)
    Error(Nil) ->
      crossbar.add_validation_error(
        context,
        ["certificate"],
        "required",
        "certificate is the PEM chain",
      )
  }
}

fn trust_status(kz: Kazoo, context: Context) -> Context {
  case trust.status(kz) {
    Ok(statuses) -> {
      let sets = trust.root_sets(kz)
      crossbar.respond(
        context,
        doc.List(
          list.map(statuses, fn(status) {
            api.trust_status_with_roots(status, sets)
          }),
        ),
      )
    }
    Error(trust.NotFound) -> crossbar.respond(context, doc.List([]))
    Error(error) -> fail(context, trust_failure(error))
  }
}

fn validate_trust(context: Context) -> Context {
  use context <- crossbar.validate_request_data(trust_schema, context)
  case api.trust_request(crossbar.doc(context)) {
    Ok(_request) -> crossbar.set_resp_status_success(context)
    Error(#(property, message)) ->
      crossbar.add_validation_error(context, [property], "invalid", message)
  }
}

fn credentials_status(kz: Kazoo, context: Context) -> Context {
  case credentials.status(kz) {
    Ok(statuses) ->
      crossbar.respond(
        context,
        doc.List(list.map(statuses, api.credential_status_doc)),
      )
    Error(credentials.NotFound) -> crossbar.respond(context, doc.List([]))
    Error(error) -> fail(context, credential_failure(error))
  }
}

fn validate_credentials(context: Context) -> Context {
  use context <- crossbar.validate_request_data(credentials_schema, context)
  case api.credentials_request(crossbar.doc(context)), vault_present() {
    Error(#("", message)), _ ->
      crossbar.add_validation_error(
        context,
        ["credentials"],
        "required",
        message,
      )
    Error(#(name, message)), _ ->
      crossbar.add_validation_error(context, [name], "invalid", message)
    Ok(_), Error(reason) -> fail(context, NoVault(reason))
    Ok(_), Ok(Nil) -> crossbar.set_resp_status_success(context)
  }
}

/// A raw answer, in the type `content_types_provided` named for the path.
fn serve(
  context: Context,
  pem: Result(String, Failure),
  content_type: String,
) -> Context {
  case pem {
    Ok(pem) -> crossbar.respond_body(context, pem, content_type)
    Error(failure) -> fail(context, failure)
  }
}

// ---------------------------------------------------------------------------
// The verbs
// ---------------------------------------------------------------------------

pub fn post(context: Context, tokens: List(String)) -> Context {
  let kz = system.live()
  let by = actor(context)
  let body = crossbar.doc(context)
  case api.route(tokens) {
    Ok(api.Keys) -> create_key(kz, context, body, by)
    Ok(api.Key(kid)) -> change_status(kz, context, body, kid, by)
    Ok(api.KeyCertificate(kid)) ->
      attach_certificate(kz, context, body, kid, by)
    Ok(api.Trust) -> trust_post(kz, context, body, by)
    Ok(api.Credentials) -> set_credentials(kz, context, body, by)
    _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

pub fn delete(context: Context, tokens: List(String)) -> Context {
  let kz = system.live()
  let by = actor(context)
  case api.route(tokens) {
    Ok(api.Key(kid)) ->
      case keys.delete(kz, kid, by) {
        Ok(Nil) ->
          crossbar.respond(context, doc.object([#("id", doc.String(kid))]))
        Error(error) -> fail(context, key_failure(error))
      }
    Ok(api.Credential(name)) ->
      case credentials.delete(kz, name, by) {
        Ok(Nil) ->
          crossbar.respond(context, doc.object([#("name", doc.String(name))]))
        Error(error) -> fail(context, credential_failure(error))
      }
    _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

/// Generate a key, sealed under this node's vault, and answer its metadata
/// and CSR. The scope and the `x5u` prefix are worked out the way
/// `validate` checked them.
fn create_key(kz: Kazoo, context: Context, body: Value, by: String) -> Context {
  let spc = doc.get_string(body, ["spc"]) |> result.unwrap("")
  let scope =
    api.create_decision(
      body,
      account(context),
      caller(context),
      allow_account_keys,
    )
  let config = settings.load(kz)
  let base = api.x5u_base_checked(config)
  let organization = api.csr_organization(body, config)
  case scope, base, organization, vault.load() {
    Error(Nil), _, _, _ -> crossbar.add_system_error(context, "forbidden")
    _, Error(problem), _, _ -> fail(context, x5u_base_failure(problem))
    _, _, Error(Nil), _ -> fail(context, NoOrganization)
    _, _, _, Error(_) -> fail(context, key_failure(keys.NoVault))
    Ok(scope), Ok(base), Ok(organization), Ok(sealer) ->
      case keys.create(kz, sealer, scope, spc, organization, base, by) {
        Ok(#(created, csr)) ->
          crossbar.respond(
            context,
            shown(context, api.key_with_csr(created, csr)),
          )
        Error(error) -> fail(context, key_failure(error))
      }
  }
}

fn change_status(
  kz: Kazoo,
  context: Context,
  body: Value,
  kid: String,
  by: String,
) -> Context {
  let changed = case api.requested_status(body) {
    Ok(key.Active) -> keys.activate(kz, kid, by)
    Ok(key.Retired) -> keys.retire(kz, kid, by)
    _ -> Error(keys.InvalidTransition)
  }
  // This node's signer holds decrypted keys for five minutes and its
  // `select` cache for thirty seconds; the write is what every other node
  // picks up on its own, and this makes the node that served the request
  // agree at once. Harmless when the signer is not running.
  case changed {
    Ok(_key) -> signer.refresh()
    Error(_) -> Nil
  }
  answer_key(context, changed)
}

fn attach_certificate(
  kz: Kazoo,
  context: Context,
  body: Value,
  kid: String,
  by: String,
) -> Context {
  let pem = doc.get_string(body, ["certificate"]) |> result.unwrap("")
  answer_key(context, keys.attach_certificate(kz, kid, pem, by))
}

fn answer_key(context: Context, answer: Result(Key, keys.Error)) -> Context {
  case answer {
    Ok(changed) -> crossbar.respond(context, key.to_public(changed))
    Error(error) -> fail(context, key_failure(error))
  }
}

fn trust_post(kz: Kazoo, context: Context, body: Value, by: String) -> Context {
  case api.trust_request(body) {
    Error(#(property, message)) ->
      crossbar.add_validation_error(context, [property], "invalid", message)
    Ok(api.Refresh) ->
      case
        trust.refresh(
          kz,
          http.real(),
          settings.load(kz).stipa_api_url,
          refresh_timeout_ms,
        )
      {
        Ok(statuses) ->
          crossbar.respond(
            context,
            doc.List(list.map(statuses, api.trust_status_doc)),
          )
        Error(error) -> fail(context, trust_failure(error))
      }
    // The answer names the role the roots were stored under and what each
    // role now holds, so a client that sent no role sees they went in as
    // call roots and not as the STI-PA pin.
    Ok(api.UploadRoot(role, pem)) ->
      case trust.upload_root(kz, role, pem, by) {
        Ok(status) ->
          crossbar.respond(
            context,
            api.trust_status_with_roots(status, trust.root_sets(kz))
              |> doc.set(["role"], doc.String(trust.role_to_string(role))),
          )
        Error(error) -> fail(context, trust_failure(error))
      }
    Ok(api.UploadCrl(pem)) ->
      answer_trust(context, trust.upload(kz, trust.Crl, pem, by))
  }
}

fn answer_trust(
  context: Context,
  answer: Result(trust.Status, trust.Error),
) -> Context {
  case answer {
    Ok(status) -> crossbar.respond(context, api.trust_status_doc(status))
    Error(error) -> fail(context, trust_failure(error))
  }
}

/// Seal every credential in the body and answer which are set. The values
/// go from the body into a `Secret` and nowhere else.
fn set_credentials(
  kz: Kazoo,
  context: Context,
  body: Value,
  by: String,
) -> Context {
  case api.credentials_request(body), vault.load() {
    Error(#("", message)), _ ->
      crossbar.add_validation_error(
        context,
        ["credentials"],
        "required",
        message,
      )
    Error(#(name, message)), _ ->
      crossbar.add_validation_error(context, [name], "invalid", message)
    Ok(_), Error(_) -> fail(context, key_failure(keys.NoVault))
    Ok(members), Ok(sealer) -> {
      let stored =
        list.try_each(members, fn(member) {
          let #(name, value) = member
          credentials.set(
            kz,
            sealer,
            name,
            secret.new(name, bit_array.from_string(value)),
            by,
          )
          |> result.replace(Nil)
        })
      case stored {
        Error(error) -> fail(context, credential_failure(error))
        Ok(Nil) -> credentials_status(kz, context)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Failures
// ---------------------------------------------------------------------------

/// What a store's error means to the client.
type Failure {
  NotFound
  Unreachable
  /// Another node wrote the document first and the change was not made.
  /// A 409, because repeating the request is the answer to it.
  Conflict
  /// A view the store reads is not on this node's design document. The
  /// client is told the datastore is unreachable, which it is for this
  /// listing; the log line names the view so an operator can register it.
  ViewMissing(String)
  /// The node cannot seal or open a key; the text says why.
  NoVault(String)
  /// `x5u_base_url` is not set and the request's host is not readable here.
  NoX5uBase
  /// `x5u_base_url` is set to something that is not an https URL.
  X5uBaseNotHttps
  /// Neither the request nor `csr_organization` names the CSR's organization.
  NoOrganization
  Invalid(property: List(String), code: String, message: String)
}

fn x5u_base_failure(problem: api.X5uBase) -> Failure {
  case problem {
    api.NoBase -> NoX5uBase
    api.NotHttps -> X5uBaseNotHttps
  }
}

fn fail(context: Context, failure: Failure) -> Context {
  case failure {
    NotFound -> crossbar.add_system_error(context, "not_found")
    Unreachable -> crossbar.add_system_error(context, "datastore_unreachable")
    Conflict -> crossbar.add_system_error(context, "datastore_conflict")
    ViewMissing(message) -> {
      system.log_error("crossbar: " <> message)
      crossbar.add_system_error(context, "datastore_unreachable")
    }
    NoVault(reason) ->
      crossbar.add_validation_error(
        context,
        ["vault"],
        "no_vault",
        "this node has no key-encryption key ("
          <> reason
          <> "): keys cannot be created, opened or sealed here",
      )
    NoX5uBase ->
      crossbar.add_validation_error(
        context,
        ["x5u_base_url"],
        "no_x5u_base_url",
        "set x5u_base_url in system_config/stir to the public prefix "
          <> "certificates are served under, e.g. https://api.example.com/v2/stir/certs",
      )
    X5uBaseNotHttps ->
      crossbar.add_validation_error(
        context,
        ["x5u_base_url"],
        "not_https",
        "x5u_base_url in system_config/stir is not an https URL with a host: "
          <> "a verifier fetches the certificate over https and nothing else, "
          <> "e.g. https://api.example.com/v2/stir/certs",
      )
    NoOrganization ->
      crossbar.add_validation_error(
        context,
        ["organization"],
        "no_organization",
        "name the service provider the certificate is for: set "
          <> "csr_organization in system_config/stir, or send organization "
          <> "with the request",
      )
    Invalid(property, code, message) ->
      crossbar.add_validation_error(context, property, code, message)
  }
}

fn key_failure(error: keys.Error) -> Failure {
  case error {
    keys.NotFound -> NotFound
    keys.Datastore(kazoo.NotFound) -> NotFound
    keys.Datastore(_) -> Unreachable
    keys.Conflict -> Conflict
    keys.NoVault -> NoVault(system.kek_variable <> " is not usable")
    keys.Unsealable ->
      Invalid(
        ["key"],
        "unsealable",
        "the key is sealed under another key-encryption key",
      )
    keys.Damaged ->
      Invalid(
        ["key"],
        "damaged",
        "the key's sealed private key is not a readable blob",
      )
    keys.CertificateMismatch(why) -> Invalid(["certificate"], "mismatch", why)
    keys.InvalidTransition ->
      Invalid(
        ["status"],
        "invalid_transition",
        "the key's status does not allow that",
      )
    keys.NoPrivateKey ->
      Invalid(
        ["status"],
        "no_private_key",
        "the key's sealed private key is missing, so it cannot sign: "
          <> "import it again or create a new key",
      )
    keys.ViewMissing ->
      ViewMissing(
        "the view "
        <> keys.view
        <> " is not registered on this cluster, so the keys cannot be "
        <> "listed; refresh the stir database's design documents",
      )
    keys.Crypto(why) -> {
      system.log_error("crossbar: " <> why)
      Invalid(
        ["key"],
        "crypto",
        "a cryptographic operation failed; see the log",
      )
    }
  }
}

fn trust_failure(error: trust.Error) -> Failure {
  case error {
    trust.NotFound -> NotFound
    trust.Datastore(kazoo.NotFound) -> NotFound
    trust.Datastore(_) -> Unreachable
    trust.Stipa(stipa_error) ->
      Invalid(["trust"], "stipa", api.describe_stipa_error(stipa_error))
  }
}

fn credential_failure(error: credentials.Error) -> Failure {
  case error {
    credentials.NotFound -> NotFound
    credentials.Datastore(kazoo.NotFound) -> NotFound
    credentials.Datastore(_) -> Unreachable
    credentials.Unsealable ->
      Invalid(
        ["credentials"],
        "unsealable",
        "the credential is sealed under another key-encryption key",
      )
    credentials.ViewMissing ->
      ViewMissing(
        "the view "
        <> credentials.view
        <> " is not registered on this cluster, so the credentials cannot "
        <> "be listed; refresh the stir database's design documents",
      )
  }
}
