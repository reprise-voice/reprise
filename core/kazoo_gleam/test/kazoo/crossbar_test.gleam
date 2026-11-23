//// A Crossbar module: the bindings it claims, and the context its phases
//// read and answer.

import gleam/option.{None, Some}
import kazoo/crossbar
import kazoo/doc

fn allowed_methods(tokens: List(String)) -> List(String) {
  case tokens {
    [] -> ["GET", "PUT"]
    [_id] -> ["GET", "POST", "PATCH", "DELETE"]
    _ -> []
  }
}

fn resource_exists(tokens: List(String)) -> Bool {
  case tokens {
    [] | [_] -> True
    _ -> False
  }
}

fn validate(
  context: crossbar.Context,
  _tokens: List(String),
) -> crossbar.Context {
  context
}

/// The whole point of the arity dance: one handler answers every path
/// length, and decides by looking at the list.
pub fn tokens_reach_the_handler_test() {
  assert allowed_methods([]) == ["GET", "PUT"]
  assert allowed_methods(["q1"]) == ["GET", "POST", "PATCH", "DELETE"]
  assert allowed_methods(["q1", "agents"]) == []
  assert resource_exists([])
  assert !resource_exists(["q1", "agents", "a1"])
}

pub fn phase_names_test() {
  assert crossbar.phase(crossbar.AllowedMethods(allowed_methods))
    == "allowed_methods"
  assert crossbar.phase(crossbar.ResourceExists(resource_exists))
    == "resource_exists"
  assert crossbar.phase(crossbar.ContentTypesProvided(validate))
    == "content_types_provided"
  assert crossbar.phase(crossbar.Validate(validate)) == "validate"
  assert crossbar.phase(crossbar.Put(validate)) == "put"
  assert crossbar.phase(crossbar.Post(validate)) == "post"
  assert crossbar.phase(crossbar.Patch(validate)) == "patch"
  assert crossbar.phase(crossbar.Delete(validate)) == "delete"
}

/// The verbs are bound under `execute`; everything else under its own phase.
/// The leading `*` is the API version, so one binding answers v1 and v2.
pub fn binding_table_test() {
  assert crossbar.bindings("queues", [
      crossbar.AllowedMethods(allowed_methods),
      crossbar.ResourceExists(resource_exists),
      crossbar.Validate(validate),
      crossbar.Put(validate),
      crossbar.Post(validate),
      crossbar.Patch(validate),
      crossbar.Delete(validate),
    ])
    == [
      #("*.allowed_methods.queues", "allowed_methods"),
      #("*.resource_exists.queues", "resource_exists"),
      #("*.validate.queues", "validate"),
      #("*.execute.put.queues", "put"),
      #("*.execute.post.queues", "post"),
      #("*.execute.patch.queues", "patch"),
      #("*.execute.delete.queues", "delete"),
    ]

  assert crossbar.bindings("agents", [
      crossbar.Authenticate(crossbar.is_account_admin),
      crossbar.Authorize(crossbar.is_superduper_admin),
    ])
    == [
      #("*.authenticate.agents", "authenticate"),
      #("*.authorize.agents", "authorize"),
    ]
}

/// One binding per noun and phase, whatever the path length: this is why a
/// Gleam module cannot bind its own functions.
pub fn one_binding_per_phase_test() {
  let handler = crossbar.Validate(validate)
  assert crossbar.binding("queues", handler) == "*.validate.queues"
  assert crossbar.binding("agents", handler) == "*.validate.agents"
}

pub fn context_defaults_test() {
  let context = crossbar.new()
  assert crossbar.is_context(context)
  assert crossbar.req_verb(context) == "GET"
  assert crossbar.req_nouns(context) == []
  assert crossbar.account_id(context) == None
  assert crossbar.db_name(context) == None
  assert crossbar.auth_account_id(context) == None
  assert crossbar.auth_user_id(context) == None
  assert !crossbar.is_account_admin(context)
  assert !crossbar.is_superduper_admin(context)
  assert !crossbar.is_success(context)
}

pub fn request_body_test() {
  let body =
    doc.object([
      #("name", doc.String("Support")),
      #("strategy", doc.String("longest_idle_agent")),
      #("agent_ring_timeout", doc.Int(15)),
    ])
  let context = crossbar.new() |> crossbar.set_req_data(body)

  assert crossbar.req_data(context) == body
  assert crossbar.req_value(context, ["name"]) == Some(doc.String("Support"))
  assert crossbar.req_value(context, ["agent_ring_timeout"])
    == Some(doc.Int(15))
  assert crossbar.req_value(context, ["missing"]) == None
  assert crossbar.req_param(context, "filter_by_name") == None
}

pub fn answering_test() {
  let data = doc.object([#("id", doc.String("q1"))])
  let context = crossbar.new() |> crossbar.respond(data)
  assert crossbar.is_success(context)
  assert crossbar.resp_status(context) == "success"
  assert crossbar.resp_data(context) == data

  // A listing answers an array, not an object, and one of objects comes
  // back as objects rather than as the records the data layer keeps them in.
  let listing = doc.List([doc.String("q1"), doc.String("q2")])
  assert crossbar.resp_data(crossbar.set_resp_data(context, listing)) == listing

  let rows =
    doc.List([
      doc.object([#("id", doc.String("q1")), #("name", doc.String("Support"))]),
      doc.object([#("id", doc.String("q2"))]),
    ])
  assert crossbar.resp_data(crossbar.set_resp_data(context, rows)) == rows
}

pub fn document_test() {
  let document = doc.object([#("name", doc.String("Support"))])
  let context = crossbar.new() |> crossbar.set_doc(document)
  assert crossbar.doc(context) == document
  // With no datastore, saving leaves the context as it was rather than
  // pretending it worked.
  assert !crossbar.is_success(crossbar.save_doc(context))
  assert crossbar.doc(crossbar.load_doc(context, "q1", kind: Some("queue")))
    == document
}

/// A verb that started something rather than saving something says so, and
/// Crossbar reads it as a success.
pub fn accepted_test() {
  let context = crossbar.new() |> crossbar.set_resp_status_accepted
  assert crossbar.resp_status(context) == "accepted"
  // `is_success` is the narrow question -- did this answer a document -- and
  // an accepted request has not, yet.
  assert !crossbar.is_success(context)
}

/// With no datastore there is nothing to merge over, so the context comes
/// back as it was rather than as a half-merged document.
pub fn load_merge_test() {
  let document = doc.object([#("name", doc.String("Support"))])
  let context = crossbar.new() |> crossbar.set_doc(document)
  assert crossbar.doc(crossbar.load_merge(context, "q1", kind: Some("queue")))
    == document
}

/// With no datastore, removing a document leaves the context as it was
/// rather than reporting a delete that did not happen.
pub fn delete_test() {
  let context =
    crossbar.new() |> crossbar.set_doc(doc.object([#("_id", doc.String("q1"))]))
  assert !crossbar.is_success(crossbar.delete_doc(context))
}

/// What one phase worked out, the next one reads.
pub fn store_test() {
  let context = crossbar.new()
  assert crossbar.fetch(context, "queue") == None

  let context = crossbar.store(context, "queue", doc.String("q1"))
  assert crossbar.fetch(context, "queue") == Some(doc.String("q1"))
  assert crossbar.fetch(context, "agent") == None
}

pub fn errors_test() {
  let context =
    crossbar.new()
    |> crossbar.set_resp_status_success
    |> crossbar.add_validation_error(
      ["strategy"],
      "enum",
      "value not found in enumerated list of values",
    )
  assert !crossbar.is_success(context)

  let context =
    crossbar.new()
    |> crossbar.set_resp_status_success
    |> crossbar.add_system_error("bad_identifier")
  assert !crossbar.is_success(context)
}

/// With no schema database the validator cannot judge, so the success path
/// runs: a test exercises the module's own logic rather than jesse's.
pub fn validate_request_data_test() {
  let context = crossbar.new() |> crossbar.set_req_data(doc.object([]))
  let validated =
    crossbar.validate_request_data("queues", context, fn(context) {
      crossbar.respond(context, doc.String("on_success ran"))
    })
  assert crossbar.resp_data(validated) == doc.String("on_success ran")
}

/// The patch path runs the caller's own validation even with nothing to
/// patch against.
pub fn patch_and_validate_test() {
  let context = crossbar.new()
  let patched =
    crossbar.patch_and_validate(context, "q1", fn(id, context) {
      crossbar.respond(context, doc.String(id))
    })
  assert crossbar.resp_data(patched) == doc.String("q1")
}

/// A path that answers a certificate rather than JSON names the type in
/// the content-types phase and the verb answers the raw body in it; the
/// body reads back as it was written, and the answer is a success.
pub fn binary_answer_test() {
  let handler = crossbar.ContentTypesProvided(validate)
  assert crossbar.binding("stir", handler) == "*.content_types_provided.stir"

  let pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  let context =
    crossbar.new()
    |> crossbar.provide_content_types(["application/pem-certificate-chain"])
    |> crossbar.respond_body(pem, "application/pem-certificate-chain")
  assert crossbar.is_success(context)
  assert crossbar.resp_body(context) == Some(pem)

  // A JSON answer has no raw body.
  assert crossbar.resp_body(crossbar.new() |> crossbar.respond(doc.Null))
    == None
}
