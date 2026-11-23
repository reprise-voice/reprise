//// Writing a Crossbar module.
////
//// Crossbar is the HTTP API. A module claims a noun -- the path segment
//// `queues` in `/v2/accounts/{id}/queues/{qid}` -- and binds one function to
//// each phase of a request against it: which methods are allowed, whether
//// the resource exists, whether the body validates, and what each verb does.
////
//// ## How a Gleam module binds
////
//// Crossbar has one binding per noun and phase, not one per path length, and
//// applies the bound function to the whole payload: `validate` is called
//// with the context alone for `/queues` and with the context and two tokens
//// for `/queues/{id}/agents`. An Erlang Crossbar module therefore exports
//// `validate/1`, `validate/2` and `validate/3`. Gleam gives a function one
//// arity, so a Gleam module cannot do that.
////
//// `bind` closes the gap. A handler here takes the path tokens as a **list**
//// and so has one shape whatever the path is; `kazoo_gleam_cb` is the Erlang
//// module Crossbar actually binds, and it dispatches by arity into the
//// handler. Nothing about that is visible from Gleam beyond this: the tokens
//// arrive as a list, and the module has to check the list it was given.
////
//// ```gleam
//// pub fn init() -> Nil {
////   crossbar.bind("queues", [
////     crossbar.AllowedMethods(allowed_methods),
////     crossbar.ResourceExists(resource_exists),
////     crossbar.Validate(validate),
////     crossbar.Put(put),
////   ])
//// }
//// ```
////
//// The module still has to be named `cb_<noun>` and started with
//// `start_module`, which is what puts it in the node's autoloaded modules.
//// A Gleam module at the top of `src` compiles to an Erlang module of
//// exactly its own name, so `src/cb_queues.gleam` is the right file, and its
//// `pub fn init() -> Nil` is the `init/0` Crossbar calls.
////
//// ## What a phase has to answer
////
//// `Validate` and the verbs answer a context. A context whose status is not
//// success is the error response, so a validation that fails answers the
//// context `add_validation_error` gave back, not a bare failure.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc.{type Value}

/// A request in flight: what was asked, what has been read, and what will be
/// answered. Opaque: it is Crossbar's own record.
pub type Context

/// A context with nothing in it. For a test; a request's context comes from
/// Crossbar.
@external(erlang, "kazoo_gleam_crossbar_ffi", "new")
pub fn new() -> Context

@external(erlang, "kazoo_gleam_crossbar_ffi", "is_context")
pub fn is_context(context: Context) -> Bool

// ---------------------------------------------------------------------------
// Binding
// ---------------------------------------------------------------------------

/// One phase of a request, and what answers it.
pub type Handler {
  /// Which HTTP methods the path allows, e.g. `["GET", "PUT"]`. An empty
  /// list is a 405.
  AllowedMethods(fn(List(String)) -> List(String))
  /// Whether this path is one the module serves at all. `False` is a 404
  /// before anything else runs.
  ResourceExists(fn(List(String)) -> Bool)
  /// Whether the request carries valid credentials, for a noun that takes
  /// its own rather than a token.
  Authenticate(fn(Context) -> Bool)
  /// Whether the authenticated user may make this request. `False` is a
  /// 403 even where Crossbar's own authorization already said yes (an
  /// account admin on an account path), so a module can keep a route to a
  /// narrower audience than the account.
  Authorize(fn(Context) -> Bool)
  /// Which content types a path can answer besides the JSON envelope: a
  /// certificate as `application/pem-certificate-chain`, a file as its own
  /// type. Runs before `Validate`. The handler names the types with
  /// `provide_content_types`; the verb then answers with `respond_body`.
  ContentTypesProvided(fn(Context, List(String)) -> Context)
  /// Check the request and load what it is about. Runs for every verb,
  /// before the verb does.
  Validate(fn(Context, List(String)) -> Context)
  /// Create.
  Put(fn(Context, List(String)) -> Context)
  /// Replace.
  Post(fn(Context, List(String)) -> Context)
  /// Change part of.
  Patch(fn(Context, List(String)) -> Context)
  /// Remove.
  Delete(fn(Context, List(String)) -> Context)
}

/// The phase a handler answers, as Crossbar names it.
pub fn phase(handler: Handler) -> String {
  case handler {
    AllowedMethods(_) -> "allowed_methods"
    ResourceExists(_) -> "resource_exists"
    Authenticate(_) -> "authenticate"
    Authorize(_) -> "authorize"
    ContentTypesProvided(_) -> "content_types_provided"
    Validate(_) -> "validate"
    Put(_) -> "put"
    Post(_) -> "post"
    Patch(_) -> "patch"
    Delete(_) -> "delete"
  }
}

/// The routing key a phase is bound under. The leading `*` is the API
/// version, so a module answers `v1` and `v2` alike.
pub fn binding(noun: String, handler: Handler) -> String {
  case handler {
    Put(_) | Post(_) | Patch(_) | Delete(_) ->
      "*.execute." <> phase(handler) <> "." <> noun
    _ -> "*." <> phase(handler) <> "." <> noun
  }
}

/// The whole binding table a module claims: the routing key and the phase
/// for each of its handlers, in the order they were given.
pub fn bindings(
  noun: String,
  handlers: List(Handler),
) -> List(#(String, String)) {
  list.map(handlers, fn(handler) { #(binding(noun, handler), phase(handler)) })
}

/// Claim a noun. Call this from the module's `init`.
pub fn bind(noun: String, handlers: List(Handler)) -> Nil {
  list.each(handlers, fn(handler) {
    let key = binding(noun, handler)
    let phase = phase(handler)
    case handler {
      AllowedMethods(f) -> bind_methods(noun, phase, key, f)
      ResourceExists(f) -> bind_exists(noun, phase, key, f)
      Authenticate(f) | Authorize(f) -> bind_context(noun, phase, key, f)
      ContentTypesProvided(f)
      | Validate(f)
      | Put(f)
      | Post(f)
      | Patch(f)
      | Delete(f) -> bind_fold(noun, phase, key, f)
    }
  })
}

/// Start a Crossbar module and add it to the ones this node autoloads, so it
/// is there after a restart. This is what an application calls for its own
/// nouns while it starts.
@external(erlang, "kazoo_gleam_crossbar_ffi", "start_module")
pub fn start_module(module: String) -> Nil

@external(erlang, "kazoo_gleam_cb", "bind")
fn bind_methods(
  noun: String,
  phase: String,
  binding: String,
  handler: fn(List(String)) -> List(String),
) -> Nil

@external(erlang, "kazoo_gleam_cb", "bind")
fn bind_exists(
  noun: String,
  phase: String,
  binding: String,
  handler: fn(List(String)) -> Bool,
) -> Nil

@external(erlang, "kazoo_gleam_cb", "bind")
fn bind_context(
  noun: String,
  phase: String,
  binding: String,
  handler: fn(Context) -> Bool,
) -> Nil

@external(erlang, "kazoo_gleam_cb", "bind")
fn bind_fold(
  noun: String,
  phase: String,
  binding: String,
  handler: fn(Context, List(String)) -> Context,
) -> Nil

// ---------------------------------------------------------------------------
// Reading the request
// ---------------------------------------------------------------------------

/// The request body, unwrapped from its `data` envelope.
pub fn req_data(context: Context) -> Value {
  doc.from_dynamic(ffi_req_data(context))
}

pub fn set_req_data(context: Context, data: Value) -> Context {
  ffi_set_req_data(context, doc.to_string(data))
}

/// `GET`, `PUT`, `POST`, `PATCH` or `DELETE`.
@external(erlang, "kazoo_gleam_crossbar_ffi", "req_verb")
pub fn req_verb(context: Context) -> String

/// The path as Crossbar parsed it, deepest noun first:
/// `/accounts/{id}/queues/{qid}` is
/// `[#("queues", ["qid"]), #("accounts", ["id"])]`.
@external(erlang, "kazoo_gleam_crossbar_ffi", "req_nouns")
pub fn req_nouns(context: Context) -> List(#(String, List(String)))

/// A value from the request body, then the query string, then the envelope,
/// which is the order Crossbar looks in.
pub fn req_value(context: Context, path: List(String)) -> Option(Value) {
  case ffi_req_value(context, path) {
    Ok(value) -> Some(doc.from_dynamic(value))
    Error(Nil) -> None
  }
}

/// A query string parameter.
pub fn req_param(context: Context, key: String) -> Option(Value) {
  case ffi_req_param(context, key) {
    Ok(value) -> Some(doc.from_dynamic(value))
    Error(Nil) -> None
  }
}

pub fn query_string(context: Context) -> Value {
  doc.from_dynamic(ffi_query_string(context))
}

/// The account the request is against, which is not the account the token
/// belongs to.
pub fn account_id(context: Context) -> Option(String) {
  option.from_result(ffi_account_id(context))
}

/// The database this request reads and writes.
pub fn db_name(context: Context) -> Option(String) {
  option.from_result(ffi_db_name(context))
}

/// This month's database for the account the request is against.
pub fn account_modb(context: Context) -> Option(String) {
  option.from_result(ffi_account_modb(context))
}

/// The account the token belongs to.
pub fn auth_account_id(context: Context) -> Option(String) {
  option.from_result(ffi_auth_account_id(context))
}

pub fn auth_user_id(context: Context) -> Option(String) {
  option.from_result(ffi_auth_user_id(context))
}

@external(erlang, "kazoo_gleam_crossbar_ffi", "is_account_admin")
pub fn is_account_admin(context: Context) -> Bool

@external(erlang, "kazoo_gleam_crossbar_ffi", "is_superduper_admin")
pub fn is_superduper_admin(context: Context) -> Bool

/// The document the request is about: what `load_doc` read, or what the
/// validator built out of the request body.
pub fn doc(context: Context) -> Value {
  doc.from_dynamic(ffi_doc(context))
}

pub fn set_doc(context: Context, document: Value) -> Context {
  ffi_set_doc(context, doc.to_string(document))
}

// ---------------------------------------------------------------------------
// Answering
// ---------------------------------------------------------------------------

/// What the response's `data` will be.
pub fn resp_data(context: Context) -> Value {
  doc.from_dynamic(ffi_resp_data(context))
}

pub fn set_resp_data(context: Context, data: Value) -> Context {
  ffi_set_resp_data(context, doc.to_string(data))
}

/// `success`, `error`, `fatal` or `stop`. Only `success` renders a body.
@external(erlang, "kazoo_gleam_crossbar_ffi", "resp_status")
pub fn resp_status(context: Context) -> String

pub fn is_success(context: Context) -> Bool {
  resp_status(context) == "success"
}

/// Say the request worked. A phase that answers a context which never got
/// this is an error response.
///
/// Crossbar sets a verb's status to `fatal` before running it, so a verb
/// that has nothing to save says this itself.
pub fn set_resp_status_success(context: Context) -> Context {
  ffi_set_resp_status(context, "success")
}

/// Answer `data` with a success status, which is what a read does at the end
/// of `validate`.
pub fn respond(context: Context, data: Value) -> Context {
  context |> set_resp_data(data) |> set_resp_status_success
}

/// Say the request was taken but is not finished: a `202`. What a verb that
/// started a call rather than changing a document answers, because what
/// happens next takes as long as a phone takes to be picked up.
///
/// Crossbar sets a verb's status to `fatal` before it runs it, so a verb
/// that has nothing to save still has to say one of these two; a handler
/// that answers the context it was given answers a 500.
pub fn set_resp_status_accepted(context: Context) -> Context {
  ffi_set_resp_status(context, "accepted")
}

/// Say which content types besides JSON this path can answer, as
/// `"type/subtype"` strings, from a `ContentTypesProvided` handler. Crossbar
/// negotiates with the client's `Accept`; a client that accepts anything
/// gets the first.
@external(erlang, "kazoo_gleam_crossbar_ffi", "set_content_types_provided")
pub fn provide_content_types(context: Context, types: List(String)) -> Context

/// Answer a raw body with the content type it is in, and a success status:
/// a certificate, a file, anything that is not the JSON envelope. The type
/// has to be one `provide_content_types` named for the path.
@external(erlang, "kazoo_gleam_crossbar_ffi", "set_resp_body")
pub fn respond_body(
  context: Context,
  body: String,
  content_type: String,
) -> Context

/// The raw body a verb answered with `respond_body`; a JSON answer reads
/// through `resp_data`.
pub fn resp_body(context: Context) -> Option(String) {
  option.from_result(ffi_resp_body(context))
}

@external(erlang, "kazoo_gleam_crossbar_ffi", "resp_body")
fn ffi_resp_body(context: Context) -> Result(String, Nil)

/// Carry a value from one phase of a request to the next: what `validate`
/// worked out and `put` needs.
pub fn store(context: Context, key: String, value: Value) -> Context {
  ffi_store(context, key, doc.to_string(value))
}

pub fn fetch(context: Context, key: String) -> Option(Value) {
  case ffi_fetch(context, key) {
    Ok(value) -> Some(doc.from_dynamic(value))
    Error(Nil) -> None
  }
}

/// One field of the request is wrong. `property` is the path to it, `code`
/// the rule it broke -- `required`, `type`, `enum`, `unique` -- and
/// `message` what to tell the client.
@external(erlang, "kazoo_gleam_crossbar_ffi", "add_validation_error")
pub fn add_validation_error(
  context: Context,
  property: List(String),
  code: String,
  message: String,
) -> Context

/// The whole request fails for a reason Crossbar already has a status code
/// and a message for: `bad_identifier`, `forbidden`, `not_found`,
/// `datastore_unreachable`, `too_many_requests`.
@external(erlang, "kazoo_gleam_crossbar_ffi", "add_system_error")
pub fn add_system_error(context: Context, kind: String) -> Context

/// The whole request fails with a status code and a message of the
/// handler's own, for an answer Crossbar has no system error for: a `409`
/// conflict, or a `404` that says what was not there. `kind` is the short
/// name the answer's `error` carries.
@external(erlang, "kazoo_gleam_crossbar_ffi", "add_error")
pub fn add_error(
  context: Context,
  code: Int,
  kind: String,
  message: String,
) -> Context

// ---------------------------------------------------------------------------
// Schemas and documents
// ---------------------------------------------------------------------------

/// Check the request body against a JSON schema by id -- the name of a
/// document in the `system_schemas` database, e.g. `"queues"`. On success
/// the validated body becomes the context's document and `on_success` runs;
/// on failure the context carries the errors and `on_success` does not.
@external(erlang, "kazoo_gleam_crossbar_ffi", "validate_request_data")
pub fn validate_request_data(
  schema_id: String,
  context: Context,
  on_success: fn(Context) -> Context,
) -> Context

/// Load a document into the context by id. `kind` is the `pvt_type` the
/// document must have, so one noun cannot read another's documents; `None`
/// accepts any type.
pub fn load_doc(
  context: Context,
  doc_id: String,
  kind kind: Option(String),
) -> Context {
  ffi_load_doc(context, doc_id, option.unwrap(kind, ""))
}

/// Save the context's document. The answer's response data is the saved
/// document, or its status says why not.
@external(erlang, "kazoo_gleam_crossbar_ffi", "save_doc")
pub fn save_doc(context: Context) -> Context

/// Merge the context's document -- what the validator built out of the
/// request body -- over the stored document's private fields, and leave the
/// result on the context for `save_doc`. This is what a replace does: the
/// client sends the whole document and keeps none of the revision, the type
/// or the timestamps that are not theirs to send.
pub fn load_merge(
  context: Context,
  doc_id: String,
  kind kind: Option(String),
) -> Context {
  ffi_load_merge(context, doc_id, option.unwrap(kind, ""))
}

@external(erlang, "kazoo_gleam_crossbar_ffi", "load_merge")
fn ffi_load_merge(context: Context, doc_id: String, kind: String) -> Context

/// Remove the context's document. Crossbar's own delete, which is a soft
/// delete: the document is marked gone and the views stop emitting it.
@external(erlang, "kazoo_gleam_crossbar_ffi", "delete_doc")
pub fn delete_doc(context: Context) -> Context

/// Load a document, apply the request body to it as a PATCH -- an explicit
/// null removes a key -- and run `validate` over the result.
@external(erlang, "kazoo_gleam_crossbar_ffi", "patch_and_validate")
pub fn patch_and_validate(
  context: Context,
  doc_id: String,
  validate: fn(String, Context) -> Context,
) -> Context

/// Run a view into the context's response data, with Crossbar's own paging.
pub fn load_view(
  context: Context,
  view view: String,
  options options: Value,
) -> Context {
  ffi_load_view(context, view, doc.to_string(options))
}

@external(erlang, "kazoo_gleam_crossbar_ffi", "req_data")
fn ffi_req_data(context: Context) -> Dynamic

@external(erlang, "kazoo_gleam_crossbar_ffi", "set_req_data")
fn ffi_set_req_data(context: Context, json: String) -> Context

@external(erlang, "kazoo_gleam_crossbar_ffi", "req_value")
fn ffi_req_value(context: Context, path: List(String)) -> Result(Dynamic, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "req_param")
fn ffi_req_param(context: Context, key: String) -> Result(Dynamic, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "query_string")
fn ffi_query_string(context: Context) -> Dynamic

@external(erlang, "kazoo_gleam_crossbar_ffi", "account_id")
fn ffi_account_id(context: Context) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "db_name")
fn ffi_db_name(context: Context) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "account_modb")
fn ffi_account_modb(context: Context) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "auth_account_id")
fn ffi_auth_account_id(context: Context) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "auth_user_id")
fn ffi_auth_user_id(context: Context) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "doc")
fn ffi_doc(context: Context) -> Dynamic

@external(erlang, "kazoo_gleam_crossbar_ffi", "set_doc")
fn ffi_set_doc(context: Context, json: String) -> Context

@external(erlang, "kazoo_gleam_crossbar_ffi", "resp_data")
fn ffi_resp_data(context: Context) -> Dynamic

@external(erlang, "kazoo_gleam_crossbar_ffi", "set_resp_data")
fn ffi_set_resp_data(context: Context, json: String) -> Context

@external(erlang, "kazoo_gleam_crossbar_ffi", "set_resp_status")
fn ffi_set_resp_status(context: Context, status: String) -> Context

@external(erlang, "kazoo_gleam_crossbar_ffi", "store")
fn ffi_store(context: Context, key: String, json: String) -> Context

@external(erlang, "kazoo_gleam_crossbar_ffi", "fetch")
fn ffi_fetch(context: Context, key: String) -> Result(Dynamic, Nil)

@external(erlang, "kazoo_gleam_crossbar_ffi", "load_doc")
fn ffi_load_doc(context: Context, doc_id: String, kind: String) -> Context

@external(erlang, "kazoo_gleam_crossbar_ffi", "load_view")
fn ffi_load_view(
  context: Context,
  view: String,
  options_json: String,
) -> Context
