//// The `/v2/stir` module: the paths it claims, what it decides over a
//// context that carries no token, and that its schemas are what they say.
////
//// The phases that read a store need Crossbar and the other workers'
//// modules, which `gleam test` has neither of; what runs here is what a
//// phase does before that. The fake context (`crossbar.new()`) has no
//// verb, no nouns and no admin, so it is the anonymous request to
//// `/v2/stir`; the decisions over other paths are in `stir/api_test`.

import cb_stir
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/result
import gleam/string
import kazoo/crossbar
import kazoo/doc.{type Value}
import kazoo/testing/fake
import stir/api
import stir/settings

pub fn noun_test() {
  assert cb_stir.noun == "stir"
}

pub fn allowed_methods_test() {
  assert cb_stir.allowed_methods([]) == ["GET"]
  assert cb_stir.allowed_methods(["keys"]) == ["GET", "POST"]
  assert cb_stir.allowed_methods(["keys", "k1"]) == ["GET", "POST", "DELETE"]
  assert cb_stir.allowed_methods(["keys", "k1", "certificate"]) == ["POST"]
  assert cb_stir.allowed_methods(["certs", "k1.pem"]) == ["GET"]
  assert cb_stir.allowed_methods(["trust"]) == ["GET", "POST"]
  assert cb_stir.allowed_methods(["trust", "ca.pem"]) == ["GET"]
  assert cb_stir.allowed_methods(["trust", "crl.pem"]) == ["GET"]
  assert cb_stir.allowed_methods(["credentials"]) == ["GET", "POST"]
  assert cb_stir.allowed_methods(["credentials", "stipa_user"]) == ["DELETE"]

  // Anything else is a 405 before a 404.
  assert cb_stir.allowed_methods(["certs"]) == []
  assert cb_stir.allowed_methods(["certs", "k1"]) == []
  assert cb_stir.allowed_methods(["keys", "k1", "csr"]) == []
  assert cb_stir.allowed_methods(["trust", "ca.pem", "x"]) == []
  assert cb_stir.allowed_methods(["credentials", "nope"]) == []
  assert cb_stir.allowed_methods(["a", "b", "c", "d"]) == []
}

pub fn resource_exists_test() {
  assert cb_stir.resource_exists([])
  assert cb_stir.resource_exists(["keys", "k1", "certificate"])
  assert cb_stir.resource_exists(["trust", "crl.pem"])
  assert !cb_stir.resource_exists(["certs", "k1"])
  assert !cb_stir.resource_exists(["keys", "k1", "certificate", "x"])
}

/// A context with no token asking for `/v2/stir`: not a public route, so
/// the ordinary token check stands.
pub fn authenticate_test() {
  assert !cb_stir.authenticate(crossbar.new())
}

/// The same request is not authorized: nobody is a superduper admin here.
pub fn authorize_test() {
  assert !cb_stir.authorize(crossbar.new())
}

/// The PEM paths name their type; every other path leaves the context as
/// it was.
pub fn content_types_provided_test() {
  let context = crossbar.new()
  assert cb_stir.content_types_provided(context, ["certs", "k1.pem"]) != context
  assert cb_stir.content_types_provided(context, ["trust", "ca.pem"]) != context
  assert cb_stir.content_types_provided(context, ["trust", "crl.pem"])
    != context
  assert cb_stir.content_types_provided(context, []) == context
  assert cb_stir.content_types_provided(context, ["keys"]) == context
  assert cb_stir.content_types_provided(context, ["trust"]) == context
}

/// `validate` refuses before it reads anything: the stores are stubs that
/// would crash, and none is reached.
///
/// The reseller path's 403s are not asserted over a context here. The
/// fake context has no setter for `req_nouns`, so no request can be made
/// to look like `/v2/accounts/{id}/stir/keys`, and `permitted` on that
/// path reads `allow_account_keys` from the node's `system_config`, which
/// a test without a node cannot turn on: every such request would be
/// refused for the wrong reason. `validate` and `post` ask one question
/// for a create -- `api.create_decision`, which folds `permitted` and the
/// body's scope into the answer `forbidden` -- and that question is
/// asserted in `stir/api_test.create_decision_test`.
pub fn validate_forbidden_test() {
  assert crossbar.resp_status(cb_stir.validate(crossbar.new(), [])) == "error"
  assert crossbar.resp_status(cb_stir.validate(crossbar.new(), ["keys"]))
    == "error"
  assert crossbar.resp_status(
      cb_stir.validate(crossbar.new(), ["credentials", "stipa_user"]),
    )
    == "error"
  // A body does not change that.
  let with_body =
    crossbar.set_req_data(
      crossbar.new(),
      doc.object([#("spc", doc.String("999Y"))]),
    )
  assert crossbar.resp_status(cb_stir.validate(with_body, ["keys"])) == "error"
}

// ---------------------------------------------------------------------------
// The schemas
// ---------------------------------------------------------------------------

const schemas_dir = "../crossbar/priv/couchdb/schemas/"

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

fn schema(id: String) -> Value {
  let assert Ok(bytes) = read_file(schemas_dir <> id <> ".json")
  let assert Ok(text) = bit_array.to_string(bytes)
  let assert Ok(parsed) = doc.parse(text)
  assert doc.get_string(parsed, ["_id"]) == Ok(id)
  assert doc.get_string(parsed, ["type"]) == Ok("object")
  parsed
}

fn property_names(value: Value) -> List(String) {
  doc.get(value, ["properties"])
  |> result.map(doc.members)
  |> result.unwrap([])
  |> list.map(fn(member) { member.0 })
}

pub fn request_schemas_test() {
  let keys = schema(cb_stir.keys_schema)
  assert doc.strings(keys, ["required"]) == ["spc"]
  assert property_names(keys) == ["organization", "scope", "spc"]
  assert doc.get_int(keys, ["properties", "organization", "maxLength"])
    == Ok(64)

  let status = schema(cb_stir.key_status_schema)
  assert doc.strings(status, ["required"]) == ["status"]
  assert doc.strings(status, ["properties", "status", "enum"])
    == ["active", "retired"]

  // The PEM fields are bounded, so a body nothing could parse is refused
  // before it is read into a document.
  let certificate = schema(cb_stir.certificate_schema)
  assert doc.strings(certificate, ["required"]) == ["certificate"]
  assert doc.get_int(certificate, ["properties", "certificate", "minLength"])
    == Ok(1)
  assert doc.get_int(certificate, ["properties", "certificate", "maxLength"])
    == Ok(65_536)

  let trust = schema(cb_stir.trust_schema)
  assert doc.get_int(trust, ["properties", "pem", "minLength"]) == Ok(1)
  assert doc.get_int(trust, ["properties", "pem", "maxLength"]) == Ok(1_048_576)
  assert doc.strings(trust, ["properties", "action", "enum"]) == ["refresh"]
  assert doc.strings(trust, ["properties", "kind", "enum"]) == ["ca", "crl"]
  assert doc.strings(trust, ["properties", "role", "enum"])
    == ["calls", "stipa"]
  assert property_names(trust) == ["action", "kind", "pem", "role"]

  // The credentials body is the one the schema does not police. Every
  // rule it could apply to a value -- a length, a type, an unknown name --
  // fails by putting that value into the error, and Crossbar logs the
  // errors at debug level. So the schema names the credentials for
  // documentation and rejects nothing about a value; `api.credentials_request`
  // is the gate, and it says the name and never the text.
  let credentials = schema(cb_stir.credentials_schema)
  assert property_names(credentials)
    == list.sort(api.credential_names, string.compare)
  assert doc.get_bool(credentials, ["additionalProperties"]) == Ok(True)
  assert doc.get_int(credentials, ["minProperties"]) == Ok(1)
  list.each(api.credential_names, fn(name) {
    // A description and nothing that can fail on a value.
    let assert Ok(_) =
      doc.get_string(credentials, ["properties", name, "description"])
    assert doc.get(credentials, ["properties", name, "minLength"]) == Error(Nil)
    assert doc.get(credentials, ["properties", name, "maxLength"]) == Error(Nil)
    assert doc.get(credentials, ["properties", name, "type"]) == Error(Nil)
    assert doc.get(credentials, ["properties", name, "enum"]) == Error(Nil)
    assert doc.get(credentials, ["properties", name, "pattern"]) == Error(Nil)
  })
}

/// The settings schema names every field `stir/settings` reads, with the
/// same default.
pub fn settings_schema_test() {
  let config = schema("system_config.stir")
  let names = property_names(config)
  let expected = [
    "acme_directory_url",
    "alert_days",
    "allow_account_keys",
    "attest_forwarded",
    "attest_forwarded_when_inbound_failed",
    "attest_owned_number",
    "attest_owned_scope",
    "attest_transit",
    "attest_unverified",
    "attest_verified_external_number",
    "cid_name_prefix_failed",
    "csr_organization",
    "identity_max_age_s",
    "renewal_enabled",
    "renewal_window_days",
    "require_date_header",
    "sign_anonymous",
    "sign_enabled",
    "sign_non_nanp_origin",
    "stipa_api_url",
    "trust_refresh_hours",
    "trust_upstream_verstat",
    "verify_enabled",
    "verify_mode",
    "verify_timeout_ms",
    "x5u_base_url",
  ]
  assert names == expected

  // Every property has a description and a default.
  list.each(names, fn(name) {
    let assert Ok(_) =
      doc.get_string(config, ["properties", name, "description"])
    let assert Ok(_) = doc.get(config, ["properties", name, "default"])
  })

  let defaults = settings.load(fake.new() |> fake.kazoo)
  let default = fn(name) { doc.get(config, ["properties", name, "default"]) }
  assert default("sign_enabled") == Ok(doc.Bool(defaults.sign_enabled))
  assert default("verify_enabled") == Ok(doc.Bool(defaults.verify_enabled))
  assert default("verify_mode") == Ok(doc.String("sync"))
  assert default("verify_timeout_ms") == Ok(doc.Int(defaults.verify_timeout_ms))
  assert default("attest_owned_number") == Ok(doc.String("A"))
  assert default("attest_owned_scope")
    == Ok(doc.String(defaults.attest_owned_scope))
  assert default("attest_unverified") == Ok(doc.String("B"))
  assert default("attest_transit") == Ok(doc.String("C"))
  assert default("sign_anonymous") == Ok(doc.Bool(defaults.sign_anonymous))
  assert default("x5u_base_url") == Ok(doc.String(defaults.x5u_base_url))
  assert default("csr_organization")
    == Ok(doc.String(defaults.csr_organization))
  assert defaults.csr_organization == ""
  assert default("identity_max_age_s")
    == Ok(doc.Int(defaults.identity_max_age_s))
  assert default("allow_account_keys")
    == Ok(doc.Bool(defaults.allow_account_keys))
  assert default("renewal_enabled") == Ok(doc.Bool(defaults.renewal_enabled))
  assert default("renewal_window_days")
    == Ok(doc.Int(defaults.renewal_window_days))
  assert default("stipa_api_url") == Ok(doc.String(defaults.stipa_api_url))
  assert default("trust_refresh_hours")
    == Ok(doc.Int(defaults.trust_refresh_hours))
  assert default("alert_days") == Ok(doc.String("60,30,14"))
  assert defaults.alert_days == [60, 30, 14]
}
