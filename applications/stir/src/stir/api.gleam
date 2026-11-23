//// What `cb_stir` decides before it touches a store: which paths exist,
//// which are public, who may do what on which path, what a body asks for,
//// and the shape of the status page. Pure, so that every decision is
//// tested without a Crossbar.
////
//// The private key is not a concern here: nothing in this module sees one.
//// The credentials body is the one place secret text passes through, and it
//// goes straight from the request to `secret.new` in `cb_stir`.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import kazoo/doc.{type Value}
import kazoo/kazoo
import kazoo/modb
import stir/credentials
import stir/http
import stir/key.{type Key, type Scope}
import stir/settings.{type Settings}
import stir/stipa
import stir/trust

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/// The paths under `/v2/stir`, by the tokens after the noun.
pub type Route {
  /// `/stir`
  Status
  /// `/stir/keys`
  Keys
  /// `/stir/keys/{kid}`
  Key(kid: String)
  /// `/stir/keys/{kid}/certificate`
  KeyCertificate(kid: String)
  /// `/stir/certs/{kid}.pem`: public.
  Certificate(kid: String)
  /// `/stir/trust`
  Trust
  /// `/stir/trust/ca.pem` and `/stir/trust/crl.pem`: public.
  TrustPem(kind: trust.Kind)
  /// `/stir/credentials`
  Credentials
  /// `/stir/credentials/{name}`
  Credential(name: String)
}

pub const pem_chain = "application/pem-certificate-chain"

pub const pkix_crl = "application/pkix-crl"

/// The credentials the API accepts, by name.
pub const credential_names = [
  credentials.stipa_user,
  credentials.stipa_password,
  credentials.acme_eab_kid,
  credentials.acme_eab_hmac,
]

pub fn route(tokens: List(String)) -> Result(Route, Nil) {
  case tokens {
    [] -> Ok(Status)
    ["keys"] -> Ok(Keys)
    ["keys", kid] if kid != "" -> Ok(Key(kid))
    ["keys", kid, "certificate"] if kid != "" -> Ok(KeyCertificate(kid))
    ["certs", file] -> kid_of_pem(file) |> result.map(Certificate)
    ["trust"] -> Ok(Trust)
    ["trust", "ca.pem"] -> Ok(TrustPem(trust.Ca))
    ["trust", "crl.pem"] -> Ok(TrustPem(trust.Crl))
    ["credentials"] -> Ok(Credentials)
    ["credentials", name] ->
      case list.contains(credential_names, name) {
        True -> Ok(Credential(name))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// `<kid>.pem` to `kid`; anything else is not a certificate path.
pub fn kid_of_pem(file: String) -> Result(String, Nil) {
  case string.ends_with(file, ".pem") {
    True ->
      case string.drop_end(file, 4) {
        "" -> Error(Nil)
        kid -> Ok(kid)
      }
    False -> Error(Nil)
  }
}

pub fn allowed_methods(tokens: List(String)) -> List(String) {
  case route(tokens) {
    Ok(Status) -> ["GET"]
    Ok(Keys) -> ["GET", "POST"]
    Ok(Key(_)) -> ["GET", "POST", "DELETE"]
    Ok(KeyCertificate(_)) -> ["POST"]
    Ok(Certificate(_)) -> ["GET"]
    Ok(Trust) -> ["GET", "POST"]
    Ok(TrustPem(_)) -> ["GET"]
    Ok(Credentials) -> ["GET", "POST"]
    Ok(Credential(_)) -> ["DELETE"]
    Error(Nil) -> []
  }
}

/// A path that allows no method is a path this module does not serve.
pub fn resource_exists(tokens: List(String)) -> Bool {
  allowed_methods(tokens) != []
}

/// The two routes a verifier reads without a token: a certificate and the
/// trust material. `GET` only, and only under `/v2/stir`: the same tokens
/// under `/v2/accounts/{id}/stir` are an account request, which needs a
/// token like every other one, or the accounts noun would be a way past
/// the token check.
pub fn is_public(
  verb: String,
  tokens: List(String),
  account: Option(String),
) -> Bool {
  case account, verb, route(tokens) {
    None, "GET", Ok(Certificate(_)) | None, "GET", Ok(TrustPem(_)) -> True
    _, _, _ -> False
  }
}

/// The content type a path answers instead of the JSON envelope.
pub fn content_type(tokens: List(String)) -> Option(String) {
  case route(tokens) {
    Ok(Certificate(_)) | Ok(TrustPem(trust.Ca)) -> Some(pem_chain)
    Ok(TrustPem(trust.Crl)) -> Some(pkix_crl)
    _ -> None
  }
}

// ---------------------------------------------------------------------------
// The request as Crossbar parsed it
// ---------------------------------------------------------------------------

/// The tokens after `stir` in the parsed path, which is the first noun.
pub fn tokens_of(nouns: List(#(String, List(String)))) -> List(String) {
  case nouns {
    [#("stir", tokens), ..] -> tokens
    _ -> []
  }
}

/// The account of `/accounts/{id}/stir/...`, if the path has one.
pub fn account_of(nouns: List(#(String, List(String)))) -> Option(String) {
  case list.key_find(nouns, "accounts") {
    Ok([id, ..]) if id != "" -> Some(id)
    _ -> None
  }
}

/// Who is asking, as far as the decision needs to know.
pub type Caller {
  Caller(
    superduper: Bool,
    /// An admin of the account the token belongs to.
    account_admin: Bool,
    /// The account the token belongs to.
    auth_account: Option(String),
  )
}

/// Whether the request may go ahead.
///
/// The public routes always may, and they are public only with no accounts
/// noun. Under `/v2/stir` a superduper admin may
/// and nobody else. Under `/v2/accounts/{id}/stir` the reseller scope
/// applies: only the key routes `account_route` names, only while
/// `allow_account_keys` is on, and only for a superduper admin or an admin
/// of that very account. `allow_account_keys` is a function because it is
/// a settings read, and only the account path pays for it.
pub fn permitted(
  verb: String,
  tokens: List(String),
  account: Option(String),
  caller: Caller,
  allow_account_keys: fn() -> Bool,
) -> Bool {
  case is_public(verb, tokens, account), account {
    True, _ -> True
    False, None -> caller.superduper
    False, Some(id) ->
      account_route(verb, tokens)
      && { caller.superduper || own_account_admin(caller, id) }
      && allow_account_keys()
  }
}

fn own_account_admin(caller: Caller, account: String) -> Bool {
  caller.account_admin && caller.auth_account == Some(account)
}

/// What the account path serves: creating a key and reading keys, which is
/// how a reseller gets its CSR. Everything else is the platform's.
pub fn account_route(verb: String, tokens: List(String)) -> Bool {
  case verb, route(tokens) {
    "GET", Ok(Keys) | "POST", Ok(Keys) | "GET", Ok(Key(_)) -> True
    _, _ -> False
  }
}

/// Whether a key may be seen on this path: every key under `/v2/stir`,
/// only the account's own under `/v2/accounts/{id}/stir`.
pub fn visible(k: Key, account: Option(String)) -> Bool {
  case account {
    None -> True
    Some(id) -> k.scope == key.Account(id)
  }
}

/// The acting identity written into a key's history: the token's account
/// and user, joined with `/`.
pub fn actor(account: Option(String), user: Option(String)) -> String {
  option.unwrap(account, "") <> "/" <> option.unwrap(user, "")
}

/// The account half of an actor (`account/user`). An actor with no account
/// before the slash, and one written by a node rather than a request
/// (`sup`), belongs to no account.
pub fn actor_account(by: String) -> Option(String) {
  case string.split_once(by, "/") {
    Ok(#(account, _user)) if account != "" -> Some(account)
    _ -> None
  }
}

/// A key's public shape as the requesting path may see it.
///
/// A key's `history` names the account and user who did each thing, and on
/// a reseller's own key most of those are the platform operator: it
/// created the CSR, attached the certificate and activated it. The
/// reseller has no business with the operator's account and user ids, so
/// on the account path every event keeps its `at` and `what` and its `by`
/// becomes `"platform"` unless the actor is of the requesting account.
/// Under `/v2/stir` the history is answered as it is stored.
pub fn redact_history(shown: Value, account: Option(String)) -> Value {
  case account, doc.get(shown, ["history"]) {
    Some(id), Ok(doc.List(events)) ->
      doc.set(
        shown,
        ["history"],
        doc.List(list.map(events, redact_event(_, id))),
      )
    _, _ -> shown
  }
}

fn redact_event(event: Value, account: String) -> Value {
  let by = case doc.get_string(event, ["by"]) {
    Ok(by) ->
      case actor_account(by) == Some(account) {
        True -> by
        False -> "platform"
      }
    Error(Nil) -> "platform"
  }
  doc.object([
    #("at", doc.get(event, ["at"]) |> result.unwrap(doc.Null)),
    #("what", doc.get(event, ["what"]) |> result.unwrap(doc.Null)),
    #("by", doc.String(by)),
  ])
}

// ---------------------------------------------------------------------------
// Bodies
// ---------------------------------------------------------------------------

/// The scope a new key is created in: the body's `scope` (default
/// `system`), which on the account path may only be that account.
pub fn requested_scope(
  body: Value,
  account: Option(String),
) -> Result(Scope, String) {
  case account, doc.get_string(body, ["scope"]) {
    None, Error(Nil) -> Ok(key.System)
    None, Ok(scope) -> Ok(key.scope_from_string(scope))
    Some(id), Error(Nil) -> Ok(key.Account(id))
    Some(id), Ok(scope) if scope == id -> Ok(key.Account(id))
    Some(id), Ok(_) -> Error("on this path a key's scope is " <> id)
  }
}

/// Why `x5u_base_url` cannot be used as a prefix.
pub type X5uBase {
  /// Not set.
  NoBase
  /// Set to something that is not an `https` URL with a host.
  NotHttps
}

/// What a create on this path may do, before anything is read: the scope
/// the key is created in, or `Error(Nil)` for the 403.
///
/// Two refusals, one answer. The caller may have no business on this path
/// at all (`permitted`), or the body may ask for a scope this path may not
/// create in (`requested_scope`); `cb_stir` answers `forbidden` either
/// way, which is the 403 the reseller path promises. Both are decided
/// here so that the route's answer is testable without a Crossbar.
pub fn create_decision(
  body: Value,
  account: Option(String),
  caller: Caller,
  allow_account_keys: fn() -> Bool,
) -> Result(Scope, Nil) {
  case permitted("POST", ["keys"], account, caller, allow_account_keys) {
    False -> Error(Nil)
    True -> requested_scope(body, account) |> result.replace_error(Nil)
  }
}

/// The date until which verifiers may still fetch a key's certificate:
/// `Some(<ISO 8601>)` for a retired key whose certificate has not
/// expired, `None` for every other key.
///
/// Deleting such a key stops its `x5u` answering, and a call it signed
/// cannot be verified from then on. `sup stir_maintenance delete` warns
/// and deletes; the API refuses without `confirm=true`.
pub fn still_served_until(k: Key, now: Int) -> Option(String) {
  case k.status, k.not_after {
    key.Retired, Some(at) if at > now -> Some(kazoo.iso8601(modb.to_unix(at)))
    _, _ -> None
  }
}

/// The prefix a new key's `x5u` is built from: the setting, trimmed and
/// without a trailing slash.
///
/// A key is not created for a prefix no verifier could fetch. Empty is
/// one; so is anything that is not `https://<host>[/path]`, because the
/// URL is stamped into every PASSporT the key signs and a verifier
/// refuses a `x5u` that is not https (ATIS-1000074 §5.3.1, and our own
/// `stir/x5u.allowed`). A host with userinfo is refused for the same
/// reason: the credentials would be published in every PASSporT.
pub fn x5u_base_checked(settings: Settings) -> Result(String, X5uBase) {
  case string.trim(settings.x5u_base_url) {
    "" -> Error(NoBase)
    trimmed -> {
      let base = case string.ends_with(trimmed, "/") {
        True -> string.drop_end(trimmed, 1)
        False -> trimmed
      }
      case uri.parse(base) {
        Error(Nil) -> Error(NotHttps)
        Ok(parsed) ->
          case
            option.map(parsed.scheme, string.lowercase),
            option.unwrap(parsed.host, ""),
            parsed.userinfo
          {
            Some("https"), host, None if host != "" -> Ok(base)
            _, _, _ -> Error(NotHttps)
          }
      }
    }
  }
}

/// The organization a new key's CSR names (its subject's `O`): the
/// request's `organization` when it has one, or else `csr_organization` in
/// `system_config/stir`. `Error(Nil)` when neither is set: there is no
/// default, because a CSR carries the legal name of whoever the STI-CA is
/// asked to certify, and only the operator knows it.
pub fn csr_organization(body: Value, config: Settings) -> Result(String, Nil) {
  let requested =
    doc.get_string(body, ["organization"]) |> result.unwrap("") |> string.trim
  case requested, string.trim(config.csr_organization) {
    "", "" -> Error(Nil)
    "", configured -> Ok(configured)
    requested, _ -> Ok(requested)
  }
}

/// The same, for a caller that only needs to know there is no usable
/// prefix (`stir_maintenance`, which prints one sentence either way).
pub fn x5u_base(settings: Settings) -> Result(String, Nil) {
  x5u_base_checked(settings) |> result.replace_error(Nil)
}

/// The status change `POST /stir/keys/{kid}` asks for: `active` or
/// `retired`, nothing else.
pub fn requested_status(body: Value) -> Result(key.Status, Nil) {
  case doc.get_string(body, ["status"]) {
    Ok("active") -> Ok(key.Active)
    Ok("retired") -> Ok(key.Retired)
    _ -> Error(Nil)
  }
}

/// What `POST /stir/trust` asks for.
pub type TrustRequest {
  Refresh
  /// `{"kind": "ca"}`: roots for a role, `calls` when the body names none
  /// (`stir/trust`, the module doc, for why that is the default).
  UploadRoot(role: trust.Role, pem: String)
  /// `{"kind": "crl"}`: the CRL, or the certificate that signs it.
  UploadCrl(pem: String)
}

/// The error is the property at fault and the message.
pub fn trust_request(body: Value) -> Result(TrustRequest, #(String, String)) {
  case
    doc.get_string(body, ["action"]),
    doc.get_string(body, ["kind"]),
    doc.get_string(body, ["pem"])
  {
    Ok("refresh"), _, _ -> Ok(Refresh)
    Ok(_), _, _ -> Error(#("action", "the only action is refresh"))
    Error(Nil), Ok(kind), Ok(pem) ->
      case kind, string.trim(pem), doc.get(body, ["role"]) {
        _, "", _ -> Error(#("pem", "pem is empty"))
        "ca", _, Error(Nil) -> Ok(UploadRoot(trust.CallRoot, pem))
        "ca", _, Ok(doc.String("calls")) -> Ok(UploadRoot(trust.CallRoot, pem))
        "ca", _, Ok(doc.String("stipa")) -> Ok(UploadRoot(trust.StipaRoot, pem))
        "ca", _, Ok(_) -> Error(#("role", "role is stipa or calls"))
        "crl", _, Error(Nil) -> Ok(UploadCrl(pem))
        "crl", _, Ok(_) -> Error(#("role", "role applies to kind ca only"))
        _, _, _ -> Error(#("kind", "kind is ca or crl"))
      }
    Error(Nil), Ok(_), Error(Nil) -> Error(#("pem", "pem is required"))
    Error(Nil), Error(Nil), _ ->
      Error(#("action", "send action refresh, or kind and pem"))
  }
}

/// The most a credential value may weigh. Room for any password, API key
/// or EAB HMAC several times over, and a ceiling on what one request can
/// seal into a document.
pub const max_credential_length = 4096

/// The credentials `POST /stir/credentials` sets: every member is a known
/// name with a non-empty string value no longer than
/// `max_credential_length`. The error is the member at fault and the
/// message. The values pass through here once, on their way to
/// `secret.new`; nothing keeps them.
///
/// This is the only gate on a credential's value, deliberately: it is
/// value-blind, saying the name and what is wrong with it and never the
/// text. The schema (`stir_credentials.json`) applies no rule a value can
/// fail, because the generic validator puts the failing value into the
/// error it builds and Crossbar logs those errors at debug level. The
/// length is checked here for the same reason.
pub fn credentials_request(
  body: Value,
) -> Result(List(#(String, String)), #(String, String)) {
  case doc.members(body) {
    [] -> Error(#("", "send at least one credential"))
    members ->
      list.try_map(members, fn(member) {
        let #(name, value) = member
        case list.contains(credential_names, name), value {
          False, _ -> Error(#(name, "not a credential this API keeps"))
          True, doc.String("") -> Error(#(name, "the value is empty"))
          True, doc.String(text) ->
            case string.length(text) > max_credential_length {
              True ->
                Error(#(
                  name,
                  "the value is longer than "
                    <> int.to_string(max_credential_length)
                    <> " characters",
                ))
              False -> Ok(#(name, text))
            }
          True, _ -> Error(#(name, "the value is not a string"))
        }
      })
  }
}

// ---------------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------------

/// The status page: per scope the active key, how many keys are in each
/// status and how long the active certificate has left; the trust material;
/// which credentials are set; whether this node has a vault; the settings a
/// console's status strip shows. `now` is Gregorian seconds, like every
/// stored time. `vault` is `Ok` or why the node has none.
pub fn status_doc(
  keys: List(Key),
  now: Int,
  trust_material: List(trust.Status),
  trust_roots: List(trust.RootSet),
  credential_list: List(credentials.Status),
  vault: Result(Nil, String),
  node: String,
  config: Settings,
) -> Value {
  doc.object([
    #("node", doc.String(node)),
    #("vault", vault_doc(vault)),
    #("scopes", doc.List(scopes(keys, now))),
    #(
      "trust",
      doc.List(
        list.map(trust_material, trust_status_with_roots(_, trust_roots)),
      ),
    ),
    #("credentials", doc.List(list.map(credential_list, credential_status_doc))),
    #(
      "settings",
      doc.object([
        #("sign_enabled", doc.Bool(config.sign_enabled)),
        #("verify_enabled", doc.Bool(config.verify_enabled)),
        #(
          "verify_mode",
          doc.String(case config.verify_mode {
            settings.Sync -> "sync"
            settings.Async -> "async"
          }),
        ),
        #("renewal_enabled", doc.Bool(config.renewal_enabled)),
        #("allow_account_keys", doc.Bool(config.allow_account_keys)),
        #("x5u_base_url", doc.String(config.x5u_base_url)),
      ]),
    ),
  ])
}

fn vault_doc(vault: Result(Nil, String)) -> Value {
  case vault {
    Ok(Nil) -> doc.object([#("loaded", doc.Bool(True))])
    Error(reason) ->
      doc.object([#("loaded", doc.Bool(False)), #("reason", doc.String(reason))])
  }
}

/// One entry per scope that has a key, and always `system`.
fn scopes(keys: List(Key), now: Int) -> List(Value) {
  let by_scope = list.group(keys, fn(k) { key.scope_to_string(k.scope) })
  let others =
    dict.keys(by_scope)
    |> list.filter(fn(name) { name != "system" })
    |> list.sort(string.compare)
  let names = ["system", ..others]
  list.map(names, fn(name) {
    let members = dict.get(by_scope, name) |> result.unwrap([])
    let active = list.find(members, fn(k) { k.status == key.Active })
    doc.object([
      #("scope", doc.String(name)),
      #("active", case active {
        Ok(k) -> key.to_public(k)
        Error(Nil) -> doc.Null
      }),
      #("expires_in_days", case active {
        Ok(k) ->
          case key.days_left(k, now) {
            Some(days) -> doc.Int(days)
            None -> doc.Null
          }
        Error(Nil) -> doc.Null
      }),
      #("keys", counts(members)),
    ])
  })
}

fn counts(keys: List(Key)) -> Value {
  doc.object(
    list.map([key.Csr, key.Pending, key.Active, key.Retired], fn(status) {
      #(
        key.status_to_string(status),
        doc.Int(list.count(keys, fn(k) { k.status == status })),
      )
    }),
  )
}

/// The uploaded roots by role, for the `ca` row of `GET /v2/stir/trust`
/// and the answer to a root upload.
pub fn root_sets_doc(sets: List(trust.RootSet)) -> Value {
  doc.List(
    list.map(sets, fn(set) {
      doc.object([
        #("role", doc.String(set.role)),
        #("count", doc.Int(set.count)),
        #("by", option.map(set.by, doc.String) |> option.unwrap(doc.Null)),
        #("at", option.map(set.at, doc.Int) |> option.unwrap(doc.Null)),
      ])
    }),
  )
}

/// A status row with the uploaded roots on it when it is the `ca` row.
pub fn trust_status_with_roots(
  status: trust.Status,
  sets: List(trust.RootSet),
) -> Value {
  case status.kind {
    trust.Ca ->
      doc.set(trust_status_doc(status), ["roots"], root_sets_doc(sets))
    trust.Crl -> trust_status_doc(status)
  }
}

pub fn trust_status_doc(status: trust.Status) -> Value {
  doc.object([
    #("kind", doc.String(trust.kind_to_string(status.kind))),
    #("fetched_at", doc.Int(status.fetched_at)),
    #("source", doc.String(status.source)),
    #("detail", case status.detail {
      Some(n) -> doc.Int(n)
      None -> doc.Null
    }),
  ])
}

/// Which credential is set, since when, and by whom. Never a value.
pub fn credential_status_doc(status: credentials.Status) -> Value {
  doc.object([
    #("name", doc.String(status.name)),
    #("set_at", doc.Int(status.set_at)),
    #("by", doc.String(status.by)),
  ])
}

/// A key's public shape with its CSR alongside, for the create answer and
/// for a `csr` key's read.
pub fn key_with_csr(k: Key, csr: String) -> Value {
  doc.set(key.to_public(k), ["csr"], doc.String(csr))
}

/// What a failed STI-PA fetch says to the client: which step and why, never
/// a response body.
pub fn describe_stipa_error(error: stipa.Error) -> String {
  case error {
    stipa.Fetch(http.Transport(why)) ->
      "the STI-PA could not be reached: " <> why
    stipa.Malformed(why) -> "the STI-PA answered something unexpected: " <> why
    stipa.Untrusted(why) -> "the STI-PA's answer is not trusted: " <> why
  }
}
