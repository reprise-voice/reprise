//// The decisions behind `/v2/stir`, over explicit arguments: the routes,
//// who may do what on which path, what a body asks for, and the status
//// page.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/doc
import kazoo/testing/fake
import stir/api
import stir/credentials
import stir/http
import stir/key
import stir/settings
import stir/stipa
import stir/trust

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

pub fn route_test() {
  assert api.route([]) == Ok(api.Status)
  assert api.route(["keys"]) == Ok(api.Keys)
  assert api.route(["keys", "k1"]) == Ok(api.Key("k1"))
  assert api.route(["keys", "k1", "certificate"])
    == Ok(api.KeyCertificate("k1"))
  assert api.route(["certs", "k1.pem"]) == Ok(api.Certificate("k1"))
  assert api.route(["trust"]) == Ok(api.Trust)
  assert api.route(["trust", "ca.pem"]) == Ok(api.TrustPem(trust.Ca))
  assert api.route(["trust", "crl.pem"]) == Ok(api.TrustPem(trust.Crl))
  assert api.route(["credentials"]) == Ok(api.Credentials)
  assert api.route(["credentials", "stipa_user"])
    == Ok(api.Credential("stipa_user"))

  // A certificate is `<kid>.pem` and nothing else.
  assert api.route(["certs", "k1"]) == Error(Nil)
  assert api.route(["certs", ".pem"]) == Error(Nil)
  assert api.route(["certs"]) == Error(Nil)
  // The trust files have fixed names.
  assert api.route(["trust", "roots.pem"]) == Error(Nil)
  // Only a credential this API keeps has a path.
  assert api.route(["credentials", "password"]) == Error(Nil)
  // Wrong lengths.
  assert api.route(["keys", "k1", "csr"]) == Error(Nil)
  assert api.route(["keys", "k1", "certificate", "x"]) == Error(Nil)
  assert api.route(["certs", "k1.pem", "x"]) == Error(Nil)
  assert api.route(["nope"]) == Error(Nil)
  assert api.route(["keys", ""]) == Error(Nil)
}

pub fn kid_of_pem_test() {
  assert api.kid_of_pem("0123456789abcdef.pem") == Ok("0123456789abcdef")
  assert api.kid_of_pem("pem") == Error(Nil)
  assert api.kid_of_pem(".pem") == Error(Nil)
}

pub fn allowed_methods_test() {
  assert api.allowed_methods([]) == ["GET"]
  assert api.allowed_methods(["keys"]) == ["GET", "POST"]
  assert api.allowed_methods(["keys", "k1"]) == ["GET", "POST", "DELETE"]
  assert api.allowed_methods(["keys", "k1", "certificate"]) == ["POST"]
  assert api.allowed_methods(["certs", "k1.pem"]) == ["GET"]
  assert api.allowed_methods(["trust"]) == ["GET", "POST"]
  assert api.allowed_methods(["trust", "ca.pem"]) == ["GET"]
  assert api.allowed_methods(["trust", "crl.pem"]) == ["GET"]
  assert api.allowed_methods(["credentials"]) == ["GET", "POST"]
  assert api.allowed_methods(["credentials", "acme_eab_hmac"]) == ["DELETE"]
  assert api.allowed_methods(["credentials", "nope"]) == []
  assert api.allowed_methods(["keys", "k1", "x"]) == []
}

pub fn resource_exists_test() {
  assert api.resource_exists([])
  assert api.resource_exists(["certs", "k1.pem"])
  assert !api.resource_exists(["certs", "k1"])
  assert !api.resource_exists(["trust", "ca.pem", "x"])
}

/// Only a `GET` of a certificate or of the trust material needs no token,
/// and only under `/v2/stir`.
pub fn is_public_test() {
  assert api.is_public("GET", ["certs", "k1.pem"], None)
  assert api.is_public("GET", ["trust", "ca.pem"], None)
  assert api.is_public("GET", ["trust", "crl.pem"], None)
  assert !api.is_public("GET", ["trust"], None)
  assert !api.is_public("GET", ["keys", "k1"], None)
  assert !api.is_public("GET", [], None)
  assert !api.is_public("POST", ["certs", "k1.pem"], None)
  assert !api.is_public("DELETE", ["trust", "ca.pem"], None)

  // Under an accounts noun nothing is public: the same tokens there are an
  // account request, and a token check it must not slip past.
  assert !api.is_public("GET", ["certs", "k1.pem"], Some("a1"))
  assert !api.is_public("GET", ["trust", "ca.pem"], Some("a1"))
  assert !api.is_public("GET", ["trust", "crl.pem"], Some("a1"))
}

pub fn content_type_test() {
  assert api.content_type(["certs", "k1.pem"]) == Some(api.pem_chain)
  assert api.content_type(["trust", "ca.pem"]) == Some(api.pem_chain)
  assert api.content_type(["trust", "crl.pem"]) == Some(api.pkix_crl)
  assert api.content_type(["trust"]) == None
  assert api.content_type(["keys", "k1"]) == None
  assert api.content_type([]) == None
}

// ---------------------------------------------------------------------------
// The parsed path
// ---------------------------------------------------------------------------

const system_nouns = [#("stir", ["keys", "k1"])]

const account_nouns = [#("stir", ["keys"]), #("accounts", ["a1"])]

pub fn nouns_test() {
  assert api.tokens_of(system_nouns) == ["keys", "k1"]
  assert api.tokens_of(account_nouns) == ["keys"]
  assert api.tokens_of([]) == []
  assert api.tokens_of([#("accounts", ["a1"])]) == []
  assert api.account_of(system_nouns) == None
  assert api.account_of(account_nouns) == Some("a1")
  assert api.account_of([#("stir", []), #("accounts", [])]) == None
}

// ---------------------------------------------------------------------------
// Who may
// ---------------------------------------------------------------------------

const nobody = api.Caller(
  superduper: False,
  account_admin: False,
  auth_account: None,
)

const superduper = api.Caller(
  superduper: True,
  account_admin: True,
  auth_account: Some("master"),
)

const a1_admin = api.Caller(
  superduper: False,
  account_admin: True,
  auth_account: Some("a1"),
)

const a1_user = api.Caller(
  superduper: False,
  account_admin: False,
  auth_account: Some("a1"),
)

const reseller_admin = api.Caller(
  superduper: False,
  account_admin: True,
  auth_account: Some("r1"),
)

fn on() -> Bool {
  True
}

fn off() -> Bool {
  False
}

/// A settings read that must not happen.
fn never() -> Bool {
  panic as "allow_account_keys read off the account path"
}

pub fn permitted_public_test() {
  assert api.permitted("GET", ["certs", "k1.pem"], None, nobody, never)
  assert api.permitted("GET", ["trust", "crl.pem"], None, nobody, never)

  // The same tokens under `/v2/accounts/{id}/stir` are not a public route:
  // they are an account request for a route the account path does not
  // serve, so nobody gets them without a token and not even an admin of
  // the account gets them with one.
  assert !api.permitted("GET", ["certs", "k1.pem"], Some("a1"), nobody, off)
  assert !api.permitted("GET", ["trust", "crl.pem"], Some("a1"), nobody, off)
  assert !api.permitted("GET", ["certs", "k1.pem"], Some("a1"), a1_admin, on)
  assert !api.permitted("GET", ["trust", "ca.pem"], Some("a1"), superduper, on)
}

/// Under `/v2/stir` a superduper admin and nobody else, whatever the
/// setting says.
pub fn permitted_system_test() {
  assert api.permitted("GET", [], None, superduper, never)
  assert api.permitted("POST", ["keys"], None, superduper, never)
  assert api.permitted(
    "DELETE",
    ["credentials", "stipa_user"],
    None,
    superduper,
    never,
  )
  assert !api.permitted("GET", [], None, nobody, never)
  assert !api.permitted("GET", ["keys"], None, a1_admin, never)
  assert !api.permitted("POST", ["keys"], None, a1_admin, never)
  assert !api.permitted("GET", ["trust"], None, a1_user, never)
}

/// Under `/v2/accounts/{id}/stir`: the key routes, with the setting on, for
/// a superduper admin or an admin of that account.
pub fn permitted_account_test() {
  assert api.permitted("GET", ["keys"], Some("a1"), a1_admin, on)
  assert api.permitted("POST", ["keys"], Some("a1"), a1_admin, on)
  assert api.permitted("GET", ["keys", "k1"], Some("a1"), a1_admin, on)
  assert api.permitted("GET", ["keys"], Some("a1"), superduper, on)

  // The setting gates everyone, the superduper admin included.
  assert !api.permitted("GET", ["keys"], Some("a1"), a1_admin, off)
  assert !api.permitted("GET", ["keys"], Some("a1"), superduper, off)
  // A user of the account is not its admin.
  assert !api.permitted("GET", ["keys"], Some("a1"), a1_user, on)
  // An admin of another account, even one above it, is not this account.
  assert !api.permitted("GET", ["keys"], Some("a1"), reseller_admin, on)
  assert !api.permitted("GET", ["keys"], Some("a1"), nobody, on)
  // Only creating and reading keys; never the platform's routes.
  assert !api.permitted("POST", ["keys", "k1"], Some("a1"), a1_admin, on)
  assert !api.permitted("DELETE", ["keys", "k1"], Some("a1"), a1_admin, on)
  assert !api.permitted(
    "POST",
    ["keys", "k1", "certificate"],
    Some("a1"),
    a1_admin,
    on,
  )
  assert !api.permitted("GET", [], Some("a1"), a1_admin, on)
  assert !api.permitted("GET", ["trust"], Some("a1"), a1_admin, on)
  assert !api.permitted("POST", ["credentials"], Some("a1"), superduper, on)
}

pub fn account_route_test() {
  assert api.account_route("GET", ["keys"])
  assert api.account_route("POST", ["keys"])
  assert api.account_route("GET", ["keys", "k1"])
  assert !api.account_route("POST", ["keys", "k1"])
  assert !api.account_route("GET", [])
  assert !api.account_route("GET", ["credentials"])
}

pub fn visible_test() {
  let system_key = sample(key.System, key.Active)
  let a1_key = sample(key.Account("a1"), key.Csr)
  assert api.visible(system_key, None)
  assert api.visible(a1_key, None)
  assert api.visible(a1_key, Some("a1"))
  assert !api.visible(system_key, Some("a1"))
  assert !api.visible(a1_key, Some("a2"))
}

pub fn actor_test() {
  assert api.actor(Some("acct"), Some("user")) == "acct/user"
  assert api.actor(Some("acct"), None) == "acct/"
  assert api.actor(None, None) == "/"
}

pub fn actor_account_test() {
  assert api.actor_account("acct/user") == Some("acct")
  assert api.actor_account("acct/") == Some("acct")
  // What a node did, not an account.
  assert api.actor_account("sup") == None
  assert api.actor_account("/user") == None
  assert api.actor_account("") == None
}

/// On the account path a key's history says what happened and when, and
/// names the platform operator's account and user to nobody.
pub fn redact_history_test() {
  let key_doc =
    key.to_public(
      key.Key(..sample(key.Account("a1"), key.Active), history: [
        key.Event(at: 1, what: "created", by: "a1/u1"),
        key.Event(at: 2, what: "certificate", by: "master/operator"),
        key.Event(at: 3, what: "activated", by: "sup"),
      ]),
    )

  // Under `/v2/stir` the history is answered as it is stored.
  assert api.redact_history(key_doc, None) == key_doc

  let redacted = api.redact_history(key_doc, Some("a1"))
  let assert Ok([created, certificate, activated]) =
    doc.get_list(redacted, ["history"])

  // The account's own actor stays; every other one is the platform.
  assert doc.get_string(created, ["by"]) == Ok("a1/u1")
  assert doc.get_string(certificate, ["by"]) == Ok("platform")
  assert doc.get_string(activated, ["by"]) == Ok("platform")

  // What happened and when is kept, and nothing else is added (members
  // come back in key order).
  assert doc.get_int(certificate, ["at"]) == Ok(2)
  assert doc.get_string(certificate, ["what"]) == Ok("certificate")
  assert list.map(doc.members(certificate), fn(m) { m.0 })
    == ["at", "by", "what"]

  // The rest of the key is untouched.
  assert doc.get_string(redacted, ["id"]) == doc.get_string(key_doc, ["id"])
  assert doc.get_string(redacted, ["scope"]) == Ok("a1")

  // An account that is not the key's sees no id of the key's account
  // either, and a key with no history is left alone.
  let assert Ok([first, second, third]) =
    doc.get_list(api.redact_history(key_doc, Some("a2")), ["history"])
  assert doc.get_string(first, ["by"]) == Ok("platform")
  assert doc.get_string(second, ["by"]) == Ok("platform")
  assert doc.get_string(third, ["by"]) == Ok("platform")
  let empty = key.to_public(sample(key.Account("a1"), key.Csr))
  assert doc.get_list(api.redact_history(empty, Some("a1")), ["history"])
    == Ok([])
}

// ---------------------------------------------------------------------------
// Bodies
// ---------------------------------------------------------------------------

pub fn requested_scope_test() {
  let empty = doc.object([])
  let system = doc.object([#("scope", doc.String("system"))])
  let a1 = doc.object([#("scope", doc.String("a1"))])

  assert api.requested_scope(empty, None) == Ok(key.System)
  assert api.requested_scope(system, None) == Ok(key.System)
  assert api.requested_scope(a1, None) == Ok(key.Account("a1"))

  // On the account path the scope is that account, said or not.
  assert api.requested_scope(empty, Some("a1")) == Ok(key.Account("a1"))
  assert api.requested_scope(a1, Some("a1")) == Ok(key.Account("a1"))
  assert api.requested_scope(system, Some("a1"))
    == Error("on this path a key's scope is a1")
  assert api.requested_scope(a1, Some("a2"))
    == Error("on this path a key's scope is a2")
}

/// The scope-mismatch 403, as the route answers it: `cb_stir.validate`
/// and `cb_stir.post` both ask this one question, so what is asserted
/// here is what a request gets. (The answer itself cannot be asserted
/// over a context: the fake context has no setter for `req_nouns`, and
/// `permitted` on the account path reads `allow_account_keys` from the
/// node's `system_config`, which a test without a node cannot set.)
pub fn create_decision_test() {
  let empty = doc.object([])
  let a1 = doc.object([#("scope", doc.String("a1"))])
  let system = doc.object([#("scope", doc.String("system"))])

  // Under `/v2/stir` a superduper admin creates in any scope.
  assert api.create_decision(empty, None, superduper, never) == Ok(key.System)
  assert api.create_decision(a1, None, superduper, never)
    == Ok(key.Account("a1"))

  // On the account path the scope is that account, said or not.
  assert api.create_decision(empty, Some("a1"), a1_admin, on)
    == Ok(key.Account("a1"))
  assert api.create_decision(a1, Some("a1"), a1_admin, on)
    == Ok(key.Account("a1"))

  // A foreign scope on the account path is the 403, for the account's
  // own admin and for a superduper admin taking that path alike.
  assert api.create_decision(system, Some("a1"), a1_admin, on) == Error(Nil)
  assert api.create_decision(
      doc.object([#("scope", doc.String("a2"))]),
      Some("a1"),
      a1_admin,
      on,
    )
    == Error(Nil)
  assert api.create_decision(system, Some("a1"), superduper, on) == Error(Nil)

  // And so is everything `permitted` already refuses: the setting off,
  // an admin of another account, a user who is not an admin, nobody.
  assert api.create_decision(empty, Some("a1"), a1_admin, off) == Error(Nil)
  assert api.create_decision(empty, Some("a1"), reseller_admin, on)
    == Error(Nil)
  assert api.create_decision(empty, Some("a1"), a1_user, on) == Error(Nil)
  assert api.create_decision(empty, None, nobody, never) == Error(Nil)
}

/// A retired key whose certificate has not expired is still fetched at
/// its `x5u`; every other key is not.
pub fn still_served_until_test() {
  let now = 63_900_000_000
  let retired = sample(key.System, key.Retired)
  // The sample's certificate expires ten days after `now`, and the date
  // the client is told is that instant in UTC.
  assert api.still_served_until(retired, now) == Some("2024-12-08T08:00:00Z")

  // Once the certificate has expired nothing fetches it any more.
  assert api.still_served_until(retired, 63_900_864_001) == None
  assert api.still_served_until(key.Key(..retired, not_after: Some(now)), now)
    == None
  // A key with no certificate has nothing to serve.
  assert api.still_served_until(key.Key(..retired, not_after: None), now)
    == None
  // Only a retired key: an active one is not being deleted, and a `csr`
  // or `pending` key was never served.
  assert api.still_served_until(sample(key.System, key.Active), now) == None
  assert api.still_served_until(sample(key.System, key.Csr), now) == None
  assert api.still_served_until(sample(key.System, key.Pending), now) == None
}

/// The CSR's organization: the request's, else the setting's, and no
/// default at all.
pub fn csr_organization_test() {
  let none = settings.load(fake.new() |> fake.kazoo)
  let set = settings.Settings(..none, csr_organization: "Example Telecom Inc.")
  let empty = doc.object([])
  let asking = fn(name) { doc.object([#("organization", doc.String(name))]) }

  assert none.csr_organization == ""
  assert api.csr_organization(empty, none) == Error(Nil)
  assert api.csr_organization(asking("  "), none) == Error(Nil)
  assert api.csr_organization(empty, set) == Ok("Example Telecom Inc.")
  assert api.csr_organization(asking(" Reseller LLC "), set)
    == Ok("Reseller LLC")
  assert api.csr_organization(asking("Reseller LLC"), none)
    == Ok("Reseller LLC")
  assert api.csr_organization(asking(""), set) == Ok("Example Telecom Inc.")
}

pub fn x5u_base_test() {
  let base = settings.load(fake.new() |> fake.kazoo)
  let with_base = fn(url) { settings.Settings(..base, x5u_base_url: url) }

  assert api.x5u_base_checked(base) == Error(api.NoBase)
  assert api.x5u_base_checked(with_base("  ")) == Error(api.NoBase)
  assert api.x5u_base_checked(with_base("https://api.example/v2/stir/certs"))
    == Ok("https://api.example/v2/stir/certs")
  // A trailing slash is dropped, here and nowhere else.
  assert api.x5u_base_checked(with_base("https://api.example/v2/stir/certs/"))
    == Ok("https://api.example/v2/stir/certs")
  assert api.x5u_base_checked(with_base("  https://api.example/certs  "))
    == Ok("https://api.example/certs")
  assert api.x5u_base_checked(with_base("https://api.example"))
    == Ok("https://api.example")
  assert api.x5u_base_checked(with_base("HTTPS://api.example/certs"))
    == Ok("HTTPS://api.example/certs")

  // Anything a verifier could not fetch over https is refused, so that no
  // key is stamped with an `x5u` nothing will follow.
  assert api.x5u_base_checked(with_base("http://api.example/certs"))
    == Error(api.NotHttps)
  assert api.x5u_base_checked(with_base("ftp://api.example/certs"))
    == Error(api.NotHttps)
  assert api.x5u_base_checked(with_base("api.example/certs"))
    == Error(api.NotHttps)
  assert api.x5u_base_checked(with_base("/v2/stir/certs"))
    == Error(api.NotHttps)
  assert api.x5u_base_checked(with_base("https://")) == Error(api.NotHttps)
  assert api.x5u_base_checked(with_base("https:///certs"))
    == Error(api.NotHttps)
  // Userinfo would be published in every PASSporT this key signs.
  assert api.x5u_base_checked(with_base("https://user:pw@api.example/certs"))
    == Error(api.NotHttps)

  // `stir_maintenance` reads the same decision without the reason.
  assert api.x5u_base(base) == Error(Nil)
  assert api.x5u_base(with_base("http://api.example/certs")) == Error(Nil)
  assert api.x5u_base(with_base("https://api.example/certs"))
    == Ok("https://api.example/certs")
}

pub fn requested_status_test() {
  assert api.requested_status(doc.object([#("status", doc.String("active"))]))
    == Ok(key.Active)
  assert api.requested_status(doc.object([#("status", doc.String("retired"))]))
    == Ok(key.Retired)
  // Neither of the other two can be asked for: a key becomes `csr` by being
  // created and `pending` by getting its certificate.
  assert api.requested_status(doc.object([#("status", doc.String("pending"))]))
    == Error(Nil)
  assert api.requested_status(doc.object([#("status", doc.String("csr"))]))
    == Error(Nil)
  assert api.requested_status(doc.object([])) == Error(Nil)
}

pub fn trust_request_test() {
  assert api.trust_request(doc.object([#("action", doc.String("refresh"))]))
    == Ok(api.Refresh)
  assert api.trust_request(
      doc.object([
        #("kind", doc.String("ca")),
        #("pem", doc.String("-----BEGIN")),
      ]),
    )
    == Ok(api.UploadRoot(trust.CallRoot, "-----BEGIN"))
  assert api.trust_request(
      doc.object([#("kind", doc.String("crl")), #("pem", doc.String("x"))]),
    )
    == Ok(api.UploadCrl("x"))
  // A root names its role; with none it is a call root, the less
  // dangerous of the two (`stir/trust`).
  let root = fn(role) {
    doc.object([
      #("kind", doc.String("ca")),
      #("pem", doc.String("x")),
      #("role", role),
    ])
  }
  assert api.trust_request(root(doc.String("stipa")))
    == Ok(api.UploadRoot(trust.StipaRoot, "x"))
  assert api.trust_request(root(doc.String("calls")))
    == Ok(api.UploadRoot(trust.CallRoot, "x"))
  let assert Error(#("role", _)) = api.trust_request(root(doc.String("both")))
  let assert Error(#("role", _)) = api.trust_request(root(doc.Null))
  let assert Error(#("role", _)) =
    api.trust_request(
      doc.object([
        #("kind", doc.String("crl")),
        #("pem", doc.String("x")),
        #("role", doc.String("stipa")),
      ]),
    )

  let assert Error(#("action", _)) =
    api.trust_request(doc.object([#("action", doc.String("fetch"))]))
  let assert Error(#("kind", _)) =
    api.trust_request(
      doc.object([#("kind", doc.String("roots")), #("pem", doc.String("x"))]),
    )
  let assert Error(#("pem", _)) =
    api.trust_request(
      doc.object([#("kind", doc.String("ca")), #("pem", doc.String(" "))]),
    )
  let assert Error(#("pem", _)) =
    api.trust_request(doc.object([#("kind", doc.String("ca"))]))
  let assert Error(#("action", _)) = api.trust_request(doc.object([]))
}

pub fn credentials_request_test() {
  let body =
    doc.object([
      #("stipa_user", doc.String("alice")),
      #("stipa_password", doc.String("hunter2")),
    ])
  assert api.credentials_request(body)
    == Ok([#("stipa_password", "hunter2"), #("stipa_user", "alice")])

  let assert Error(#("", _)) = api.credentials_request(doc.object([]))
  let assert Error(#("", _)) = api.credentials_request(doc.String("x"))
  let assert Error(#("password", _)) =
    api.credentials_request(doc.object([#("password", doc.String("x"))]))
  let assert Error(#("stipa_user", _)) =
    api.credentials_request(doc.object([#("stipa_user", doc.String(""))]))
  let assert Error(#("acme_eab_kid", _)) =
    api.credentials_request(doc.object([#("acme_eab_kid", doc.Int(1))]))

  // The length is bounded here rather than in the schema, because the
  // schema's own length failure would carry the value into the error
  // Crossbar logs. The longest allowed value passes.
  let longest = string.repeat("x", api.max_credential_length)
  assert api.credentials_request(
      doc.object([#("stipa_password", doc.String(longest))]),
    )
    == Ok([#("stipa_password", longest)])
  let assert Error(#("stipa_password", message)) =
    api.credentials_request(
      doc.object([#("stipa_password", doc.String(longest <> "x"))]),
    )
  assert message == "the value is longer than 4096 characters"

  // No message this module builds carries the value it refused.
  let secret = "hunter2-and-a-very-secret-tail"
  let messages =
    [
      doc.object([#("password", doc.String(secret))]),
      doc.object([#("stipa_user", doc.String(string.repeat(secret, 500)))]),
      doc.object([#("stipa_user", doc.List([doc.String(secret)]))]),
    ]
    |> list.filter_map(fn(body) {
      case api.credentials_request(body) {
        Error(#(_name, message)) -> Ok(message)
        Ok(_) -> Error(Nil)
      }
    })
  assert list.length(messages) == 3
  list.each(messages, fn(message) {
    assert !string.contains(message, "hunter2")
  })
}

pub fn credential_names_test() {
  assert api.credential_names
    == [
      credentials.stipa_user,
      credentials.stipa_password,
      credentials.acme_eab_kid,
      credentials.acme_eab_hmac,
    ]
}

// ---------------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------------

fn sample(scope: key.Scope, status: key.Status) -> key.Key {
  key.Key(
    kid: "kid-"
      <> key.scope_to_string(scope)
      <> "-"
      <> key.status_to_string(status),
    scope:,
    alg: "ES256",
    spc: "999Y",
    x5u: "https://api.example/v2/stir/certs/k.pem",
    not_before: Some(63_900_000_000),
    not_after: Some(63_900_864_000),
    status:,
    source: key.Issued,
    fingerprint: Some("sha256:00"),
    kek: Some("deadbeef"),
    history: [],
  )
}

pub fn status_doc_test() {
  let keys = [
    sample(key.System, key.Active),
    sample(key.System, key.Retired),
    sample(key.System, key.Retired),
    sample(key.Account("a1"), key.Csr),
  ]
  let config = settings.load(fake.new() |> fake.kazoo)
  let status =
    api.status_doc(
      keys,
      63_900_000_000,
      [
        trust.Status(
          kind: trust.Ca,
          fetched_at: 1,
          source: "stipa",
          detail: Some(7),
        ),
      ],
      [trust.RootSet(role: "stipa", count: 1, by: Some("m/u"), at: Some(3))],
      [credentials.Status(name: "stipa_user", set_at: 2, by: "m/u")],
      Error("STIR_KEK is not set"),
      "stir@node",
      config,
    )

  assert doc.get_string(status, ["node"]) == Ok("stir@node")
  assert doc.get_bool(status, ["vault", "loaded"]) == Ok(False)
  assert doc.get_string(status, ["vault", "reason"])
    == Ok("STIR_KEK is not set")
  assert doc.get_bool(status, ["settings", "sign_enabled"]) == Ok(False)
  assert doc.get_string(status, ["settings", "verify_mode"]) == Ok("sync")

  // One entry per scope, `system` first.
  let assert Ok([system, a1]) = doc.get_list(status, ["scopes"])
  assert doc.get_string(system, ["scope"]) == Ok("system")
  assert doc.get_string(system, ["active", "id"]) == Ok("kid-system-active")
  assert doc.get_int(system, ["expires_in_days"]) == Ok(10)
  assert doc.get_int(system, ["keys", "active"]) == Ok(1)
  assert doc.get_int(system, ["keys", "retired"]) == Ok(2)
  assert doc.get_int(system, ["keys", "csr"]) == Ok(0)
  assert doc.get_string(a1, ["scope"]) == Ok("a1")
  assert doc.get(a1, ["active"]) == Ok(doc.Null)
  assert doc.get(a1, ["expires_in_days"]) == Ok(doc.Null)
  assert doc.get_int(a1, ["keys", "csr"]) == Ok(1)

  // The public key shape, not the stored one.
  assert doc.get(system, ["active", "kek"]) == Error(Nil)

  let assert Ok([ca]) = doc.get_list(status, ["trust"])
  assert doc.get_string(ca, ["kind"]) == Ok("ca")
  assert doc.get_int(ca, ["detail"]) == Ok(7)
  // The uploaded roots by role, on the `ca` row.
  let assert Ok([stipa_roots]) = doc.get_list(ca, ["roots"])
  assert doc.get_string(stipa_roots, ["role"]) == Ok("stipa")
  assert doc.get_int(stipa_roots, ["count"]) == Ok(1)
  assert doc.get_string(stipa_roots, ["by"]) == Ok("m/u")
  let assert Ok([user]) = doc.get_list(status, ["credentials"])
  assert doc.get_string(user, ["name"]) == Ok("stipa_user")
  assert doc.get(user, ["value"]) == Error(Nil)
}

/// No keys at all still lists the `system` scope, so a console has a row.
pub fn status_doc_empty_test() {
  let config = settings.load(fake.new() |> fake.kazoo)
  let status = api.status_doc([], 0, [], [], [], Ok(Nil), "n", config)
  assert doc.get_bool(status, ["vault", "loaded"]) == Ok(True)
  let assert Ok([system]) = doc.get_list(status, ["scopes"])
  assert doc.get_string(system, ["scope"]) == Ok("system")
  assert doc.get(system, ["active"]) == Ok(doc.Null)
}

pub fn key_with_csr_test() {
  let shown =
    api.key_with_csr(
      sample(key.System, key.Csr),
      "-----BEGIN CERTIFICATE REQUEST-----",
    )
  assert doc.get_string(shown, ["csr"])
    == Ok("-----BEGIN CERTIFICATE REQUEST-----")
  assert doc.get_string(shown, ["id"]) == Ok("kid-system-csr")
  assert doc.get(shown, ["kek"]) == Error(Nil)
}

pub fn describe_stipa_error_test() {
  assert api.describe_stipa_error(stipa.Fetch(http.Transport("timeout")))
    == "the STI-PA could not be reached: timeout"
  assert api.describe_stipa_error(stipa.Malformed("no caList"))
    == "the STI-PA answered something unexpected: no caList"
  assert api.describe_stipa_error(stipa.Untrusted("signer"))
    == "the STI-PA's answer is not trusted: signer"
}

pub fn trust_status_doc_test() {
  let shown =
    api.trust_status_doc(trust.Status(
      kind: trust.Crl,
      fetched_at: 5,
      source: "upload",
      detail: None,
    ))
  assert doc.get_string(shown, ["kind"]) == Ok("crl")
  assert doc.get_int(shown, ["fetched_at"]) == Ok(5)
  assert doc.get_string(shown, ["source"]) == Ok("upload")
  assert doc.get(shown, ["detail"]) == Ok(doc.Null)
  assert list.length(doc.members(shown)) == 4
}
