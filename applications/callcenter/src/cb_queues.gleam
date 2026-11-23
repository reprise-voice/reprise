//// The Crossbar module `queues`: `/v2/accounts/{id}/queues`.
////
//// A queue is an ordinary account document, so the four verbs on it are the
//// ordinary ones. What is not ordinary is everything hanging off one:
////
//// - `status`, which is not a database read at all: it asks the node holding
////   the account's shard what is waiting and who is being tried.
//// - `eavesdrop` and `pickup`, which start a call rather than change one.
////   See `callcenter/supervisor_actions`.
////
//// Anybody with a token for the account may read a queue and its status.
//// Every other verb here -- creating, changing and removing a queue,
//// eavesdrop and pickup -- is an account administrator's, or a superduper
//// administrator's, and anybody else is a 403. The check is made first in
//// `validate` and not in an `Authorize` binding: Crossbar takes a `true`
//// from a noun's binding as permission when its own authorization did not
//// grant the request, so a binding here would have to decide every other
//// queue path as well. See `callcenter/permission`.
////
//// The tiers -- `/queues/{id}/agents` -- are not here. `agents` is a Crossbar
//// noun of its own, so Crossbar parses that path with `agents` as its
//// deepest noun and hands it to `cb_agents`, which serves it by reading the
//// queue out of the request's nouns. That is how every sub-resource with a
//// noun of its own works, `quickcall` included. A queue written here with
//// its `agents` list is held to the same rules a tier written there is:
//// both run `callcenter/tier_check`, then the queue schema.
////
//// One handler answers every path length and checks the tokens it was given;
//// see `kazoo/crossbar` for why.

import gleam/list
import gleam/option.{None, Some}
import kazoo/amqp
import kazoo/crossbar.{type Context}
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}

import callcenter/permission
import callcenter/status_query
import callcenter/supervisor_actions
import callcenter/system
import callcenter/tier_check

/// The `pvt_type` of a queue document, which is what keeps this noun from
/// reading another one's documents.
pub const doc_type = "queue"

/// The schema the body is checked against, for every verb that has one.
pub const schema = "queues"

/// The listing, in the queue's own design document.
pub const listing = "queues/crossbar_listing"

pub fn init() -> Nil {
  crossbar.bind("queues", [
    crossbar.AllowedMethods(allowed_methods),
    crossbar.ResourceExists(resource_exists),
    crossbar.Validate(validate),
    crossbar.Put(put),
    crossbar.Post(post),
    crossbar.Patch(patch),
    crossbar.Delete(delete),
  ])
}

pub fn allowed_methods(tokens: List(String)) -> List(String) {
  case tokens {
    [] -> ["GET", "PUT"]
    [_queue_id] -> ["GET", "POST", "PATCH", "DELETE"]
    [_queue_id, token] ->
      case token {
        "status" -> ["GET"]
        "eavesdrop" | "pickup" -> ["PUT"]
        _ -> []
      }
    _ -> []
  }
}

pub fn resource_exists(tokens: List(String)) -> Bool {
  allowed_methods(tokens) != []
}

//
// Validation
//

/// A read is anybody's with a token for the account; every other verb is an
/// administrator's, and that is asked before anything else about the
/// request, so that a refusal is the only thing a refused request learns.
pub fn validate(context: Context, tokens: List(String)) -> Context {
  validate_with(system.live(), context, tokens)
}

/// `validate` against the datastore it is given, which is where the users a
/// queue's tiers name are looked up.
pub fn validate_with(
  kz: Kazoo,
  context: Context,
  tokens: List(String),
) -> Context {
  case crossbar.req_verb(context) {
    "GET" -> validate_read(context, tokens)
    _ -> {
      use <- permission.admin_only(context)
      validate_write(kz, context, tokens)
    }
  }
}

fn validate_read(context: Context, tokens: List(String)) -> Context {
  case tokens {
    [] ->
      summarised(crossbar.load_view(context, view: listing, options: paging()))
    [queue_id] -> load(context, queue_id)
    [queue_id, "status"] -> status(context, queue_id)
    _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

fn validate_write(
  kz: Kazoo,
  context: Context,
  tokens: List(String),
) -> Context {
  case crossbar.req_verb(context), tokens {
    "PUT", [] -> validate_new(kz, context)

    "POST", [queue_id] -> validate_replacement(kz, context, queue_id)
    "PATCH", [queue_id] -> validate_patch(kz, context, queue_id)
    "DELETE", [queue_id] -> load(context, queue_id)

    "PUT", [queue_id, "eavesdrop"] ->
      supervisor_actions.validate_eavesdrop(
        supervisor_actions.live(system.live()),
        context,
        queue_id,
      )
    "PUT", [queue_id, "pickup"] ->
      supervisor_actions.validate_pickup(
        supervisor_actions.live(system.live()),
        context,
        queue_id,
      )

    _, _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

fn paging() -> Value {
  doc.object([#("should_paginate", doc.Bool(True))])
}

/// A view answers rows -- an id, a key and the value the map function
/// emitted -- and a listing answers the values. Crossbar's own listings pass
/// a mapper to say so; a mapper is a function, which does not travel as
/// JSON, so the rows are unwrapped here instead. The paging on the envelope
/// is untouched.
fn summarised(context: Context) -> Context {
  case crossbar.is_success(context), crossbar.resp_data(context) {
    True, doc.List(rows) ->
      crossbar.set_resp_data(context, doc.List(list.map(rows, value_of)))
    _, _ -> context
  }
}

fn value_of(row: Value) -> Value {
  case doc.get(row, ["value"]) {
    Ok(doc.Object(_) as value) -> value
    _ -> row
  }
}

fn load(context: Context, queue_id: String) -> Context {
  crossbar.load_doc(context, queue_id, kind: Some(doc_type))
}

fn validate_new(kz: Kazoo, context: Context) -> Context {
  use context <- tiers_checked(kz, context, [])
  crossbar.validate_request_data(schema, context, fn(context) {
    context
    |> crossbar.set_doc(typed(crossbar.doc(context)))
    |> crossbar.set_resp_status_success
  })
}

/// A replacement is checked against the queue it replaces, so it is loaded
/// first: the users already in its tiers are not looked up again.
fn validate_replacement(
  kz: Kazoo,
  context: Context,
  queue_id: String,
) -> Context {
  let loaded = load(context, queue_id)
  case crossbar.is_success(loaded) {
    False -> loaded
    True -> replace(kz, loaded, queue_id)
  }
}

/// A patch arrives with the stored queue loaded and the body applied to it.
fn validate_patch(kz: Kazoo, context: Context, queue_id: String) -> Context {
  crossbar.patch_and_validate(context, queue_id, fn(queue_id, context) {
    case crossbar.is_success(context) {
      False -> context
      True -> replace(kz, context, queue_id)
    }
  })
}

/// The request body as the new queue, when the context holds the stored one.
/// The schema is not shown the tiers the body leaves as stored with a
/// number it would refuse -- a `level` of 0 saved before the rules -- and
/// those are written back as they were: `tier_check.for_schema`.
fn replace(kz: Kazoo, context: Context, queue_id: String) -> Context {
  let before = tier_check.entries(crossbar.doc(context))
  use context <- tiers_checked(kz, context, before)
  let body = crossbar.req_data(context)
  case doc.get_list(body, ["agents"]) {
    // No list to hold anything stored: the body goes to the schema as sent.
    Error(Nil) ->
      crossbar.validate_request_data(schema, context, fn(context) {
        context
        |> crossbar.set_doc(typed(crossbar.doc(context)))
        |> crossbar.load_merge(queue_id, kind: Some(doc_type))
      })
    Ok(entries) ->
      context
      |> crossbar.set_req_data(set_agents(
        body,
        tier_check.for_schema(entries, before),
      ))
      |> crossbar.validate_request_data(schema, _, fn(context) {
        let validated = crossbar.doc(context)
        let agents =
          tier_check.restore(tier_check.entries(validated), entries, before)
        context
        |> crossbar.set_doc(typed(set_agents(validated, agents)))
        |> crossbar.load_merge(queue_id, kind: Some(doc_type))
      })
  }
}

fn set_agents(queue: Value, agents: List(Value)) -> Value {
  doc.set(queue, ["agents"], doc.List(agents))
}

/// The body's tiers held to `callcenter/tier_check`, the rules every route
/// that writes a tier is held to, before the schema is: the schema's types
/// are only enforced when Crossbar validates strictly, and these are checked
/// on the body as it was sent. `before` is the tiers the queue already had,
/// none on create.
fn tiers_checked(
  kz: Kazoo,
  context: Context,
  before: List(Value),
  next: fn(Context) -> Context,
) -> Context {
  case crossbar.account_id(context) {
    None -> crossbar.add_system_error(context, "bad_identifier")
    Some(account_id) -> {
      let entries = tier_check.entries(crossbar.req_data(context))
      case tier_check.check(kz, account_id, entries, before) {
        [] -> next(context)
        problems -> tier_check.refuse(context, problems, None)
      }
    }
  }
}

/// A queue document says what it is, so that nothing else can read it back
/// out of this noun and this noun cannot read anything else.
fn typed(document: Value) -> Value {
  doc.set(document, ["pvt_type"], doc.String(doc_type))
}

//
// The verbs
//

fn put(context: Context, tokens: List(String)) -> Context {
  case tokens {
    [] -> crossbar.save_doc(context)
    // eavesdrop and pickup do their work in validate: there is nothing to
    // save, and the answer is the request that went out. Crossbar sets a
    // verb's status to `fatal` before running it, so saying nothing here is
    // a 500; this is the 202 the request actually is.
    [_queue_id, "eavesdrop"] | [_queue_id, "pickup"] ->
      crossbar.set_resp_status_accepted(context)
    _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

fn post(context: Context, _tokens: List(String)) -> Context {
  crossbar.save_doc(context)
}

fn patch(context: Context, _tokens: List(String)) -> Context {
  crossbar.save_doc(context)
}

fn delete(context: Context, _tokens: List(String)) -> Context {
  crossbar.delete_doc(context)
}

//
// Live state
//

fn status(context: Context, queue_id: String) -> Context {
  let loaded = load(context, queue_id)
  case crossbar.is_success(loaded), crossbar.account_id(context) {
    False, _ -> loaded
    _, None -> crossbar.add_system_error(loaded, "bad_identifier")
    True, Some(account_id) ->
      case status_query.ask(account_id, Some(queue_id)) {
        Error(amqp.Unavailable) ->
          crossbar.add_system_error(loaded, "datastore_unreachable")
        // Nobody answered in time, and nobody answering is also the answer
        // for an account no node is dispatching: an empty queue.
        Error(_) -> crossbar.respond(loaded, status_query.empty(queue_id))
        Ok(answers) ->
          case status_query.queue(answers, queue_id) {
            None -> crossbar.respond(loaded, status_query.empty(queue_id))
            Some(entry) -> crossbar.respond(loaded, status_query.to_api(entry))
          }
      }
  }
}
