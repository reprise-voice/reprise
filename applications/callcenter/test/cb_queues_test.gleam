//// The queues API: the paths it claims, and who may write to them.

import gleam/list
import kazoo/crossbar
import kazoo/doc

import cb_queues

pub fn allowed_methods_test() {
  assert cb_queues.allowed_methods([]) == ["GET", "PUT"]
  assert cb_queues.allowed_methods(["q1"]) == ["GET", "POST", "PATCH", "DELETE"]
  assert cb_queues.allowed_methods(["q1", "status"]) == ["GET"]
  assert cb_queues.allowed_methods(["q1", "eavesdrop"]) == ["PUT"]
  assert cb_queues.allowed_methods(["q1", "pickup"]) == ["PUT"]

  // The tiers are not here: `agents` is a noun of its own, so Crossbar hands
  // `/queues/{id}/agents` to `cb_agents` and this module never sees it.
  assert cb_queues.allowed_methods(["q1", "agents"]) == []

  // Anything else is a 405 before a 404.
  assert cb_queues.allowed_methods(["q1", "wallboard"]) == []
  assert cb_queues.allowed_methods(["q1", "status", "u1"]) == []
}

/// A path that allows no method is a path this module does not serve.
pub fn resource_exists_test() {
  assert cb_queues.resource_exists([])
  assert cb_queues.resource_exists(["q1", "status"])
  assert !cb_queues.resource_exists(["q1", "wallboard"])
  assert !cb_queues.resource_exists(["q1", "agents"])
}

// --- Who may write -----------------------------------------------------------

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue = "37139638ff5b68f155d8445178524df1"

@external(erlang, "crossbar_context_ffi", "context")
fn context_as(
  account_id: String,
  account_admin: Bool,
  superduper_admin: Bool,
) -> crossbar.Context

@external(erlang, "crossbar_context_ffi", "with_verb")
fn with_verb(context: crossbar.Context, verb: String) -> crossbar.Context

@external(erlang, "crossbar_context_ffi", "system_error")
fn system_error(context: crossbar.Context) -> Result(String, Nil)

@external(erlang, "crossbar_context_ffi", "validation_errors")
fn validation_errors(context: crossbar.Context) -> List(#(List(String), String))

/// Who is asking.
type Who {
  Admin
  Superduper
  User
}

/// The document the request is about, as the request found it. It has no
/// `pvt_type` yet, so a validation that ran leaves a mark on it.
fn found() -> doc.Value {
  doc.object([#("_id", doc.String(queue)), #("name", doc.String("Sales"))])
}

/// A request by `who`. Outside a release `load_doc`, `load_merge` and
/// `load_view` answer the context they were given, so a context that
/// arrives holding the document with a success status stands for a load
/// that found it, and what `validate` does around the load is what is seen.
fn request(who: Who, verb: String) -> crossbar.Context {
  let #(admin, superduper) = case who {
    Admin -> #(True, False)
    Superduper -> #(False, True)
    User -> #(False, False)
  }
  context_as(account, admin, superduper)
  |> with_verb(verb)
  |> crossbar.set_req_data(doc.object([#("name", doc.String("Sales"))]))
  |> crossbar.set_doc(found())
  |> crossbar.set_resp_status_success
}

/// Every write to a queue document, with the path it is sent to.
fn writes() -> List(#(String, List(String))) {
  [#("PUT", []), #("POST", [queue]), #("PATCH", [queue]), #("DELETE", [queue])]
}

/// Anybody with a token for the account reads the queues.
pub fn anybody_reads_a_queue_test() {
  let answer = cb_queues.validate(request(User, "GET"), [])
  assert crossbar.is_success(answer)
  assert system_error(answer) == Error(Nil)

  let answer = cb_queues.validate(request(User, "GET"), [queue])
  assert crossbar.is_success(answer)
  assert system_error(answer) == Error(Nil)
  assert crossbar.doc(answer) == found()
}

/// Anybody else is a 403 on every write, before anything about the request
/// is looked at: no validation error, the document as it was found, and a
/// status Crossbar runs no verb after, so nothing is saved or removed.
pub fn a_user_may_not_change_a_queue_test() {
  list.each(writes(), fn(write) {
    let #(verb, tokens) = write
    let answer = cb_queues.validate(request(User, verb), tokens)
    assert system_error(answer) == Ok("forbidden")
    assert !crossbar.is_success(answer)
    assert validation_errors(answer) == []
    assert crossbar.doc(answer) == found()
  })

  // Eavesdrop and pickup are writes too, and are refused here before
  // `supervisor_actions` is reached.
  let answer = cb_queues.validate(request(User, "PUT"), [queue, "eavesdrop"])
  assert system_error(answer) == Ok("forbidden")
  let answer = cb_queues.validate(request(User, "PUT"), [queue, "pickup"])
  assert system_error(answer) == Ok("forbidden")
}

/// An account administrator, or a superduper administrator, creates,
/// changes and removes queues.
pub fn an_administrator_changes_a_queue_test() {
  list.each([Admin, Superduper], fn(who) {
    list.each(writes(), fn(write) {
      let #(verb, tokens) = write
      let answer = cb_queues.validate(request(who, verb), tokens)
      assert crossbar.is_success(answer)
      assert system_error(answer) == Error(Nil)
    })

    // Creating and replacing type the document, which is the validation
    // having run.
    let answer = cb_queues.validate(request(who, "PUT"), [])
    assert doc.get_string(crossbar.doc(answer), ["pvt_type"]) == Ok("queue")
    let answer = cb_queues.validate(request(who, "POST"), [queue])
    assert doc.get_string(crossbar.doc(answer), ["pvt_type"]) == Ok("queue")
    let answer = cb_queues.validate(request(who, "PATCH"), [queue])
    assert doc.get_string(crossbar.doc(answer), ["pvt_type"]) == Ok("queue")
  })
}
