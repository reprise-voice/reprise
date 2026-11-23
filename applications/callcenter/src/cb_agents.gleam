//// The Crossbar module `agents`: `/v2/accounts/{id}/agents`.
////
//// An agent is a user with a `call_center` object, so this noun has no
//// document of its own and no `PUT` or `DELETE`: making somebody an agent is
//// an edit of their user document through `/users`. What is here is what an
//// agent is doing and has done.
////
//// - the listing and one agent, each with the availability they chose and
////   the activity derived from their phones. A disabled user is listed,
////   marked `enabled: false`; a deleted one is not, and reading them by id
////   is a 404 (`agents.fetch`);
//// - the tiers of a queue, at `/queues/{id}/agents`. `agents` is this
////   module's noun wherever it appears in a path, so Crossbar hands that
////   path here and the queue is read out of the request's nouns, the way
////   every sub-resource with a noun of its own works;
//// - `status`, the same two values on their own, and the one `PATCH` in this
////   module: an agent may change their own availability, and a supervisor may
////   change anybody's. A disabled user may only be logged out; anything
////   else is a 400, `forbidden` on `availability` (`agent_state.change`).
////   So is `on_break` for an agent who is logged out: a break pauses a
////   login, and one with a `timeout` ends back where it began;
//// - `log`, the availability changes out of the month databases;
//// - `stats`, the counters kept since the agent last logged in.
////
//// Everything here is readable by anybody with a token for the account. A
//// tier is part of how the queue is run, so adding, changing and removing
//// one is an administrator's (`callcenter/permission`), refused first in
//// `validate`; an agent's availability is their own to change, and an
//// administrator's to change for anybody.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/crossbar.{type Context}
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/modb

import callcenter/agent_state
import callcenter/agents
import callcenter/permission
import callcenter/status_query
import callcenter/system
import callcenter/tier_check
import cb_queues

/// The MODB view the status log reads, keyed by `[agent_id, timestamp]`.
pub const log_view = "callcenter/status_changes_by_agent"

/// How many changes a page of the log holds when the request does not say.
pub const log_page_size = 50

pub fn init() -> Nil {
  crossbar.bind("agents", [
    crossbar.AllowedMethods(allowed_methods),
    crossbar.ResourceExists(resource_exists),
    crossbar.Validate(validate),
    crossbar.Put(put),
    crossbar.Patch(patch),
    crossbar.Delete(delete),
  ])
}

/// The methods a path length allows, which is all a Crossbar module gets to
/// say: the phase is given the tokens and not the context, so it cannot tell
/// `/agents` from `/queues/{id}/agents`. The two are told apart in
/// `validate`, by the nouns, and a verb that means nothing where it was sent
/// is refused there.
pub fn allowed_methods(tokens: List(String)) -> List(String) {
  case tokens {
    // GET is the account's agents; PUT adds a tier, under a queue.
    [] -> ["GET", "PUT"]
    // GET is one agent; PATCH and DELETE are their tier, under a queue.
    [_user_id] -> ["GET", "PATCH", "DELETE"]
    [_user_id, token] ->
      case token {
        "status" -> ["GET", "PATCH"]
        "log" | "stats" -> ["GET"]
        _ -> []
      }
    _ -> []
  }
}

pub fn resource_exists(tokens: List(String)) -> Bool {
  allowed_methods(tokens) != []
}

fn validate(context: Context, tokens: List(String)) -> Context {
  validate_with(system.live(), context, tokens)
}

/// `validate` against the datastore it is given.
pub fn validate_with(
  kz: Kazoo,
  context: Context,
  tokens: List(String),
) -> Context {
  case queue_of(context) {
    Some(queue_id) -> validate_tier(kz, context, tokens, queue_id)
    None -> validate_agent(kz, context, tokens)
  }
}

fn validate_agent(
  kz: Kazoo,
  context: Context,
  tokens: List(String),
) -> Context {
  case crossbar.req_verb(context), tokens {
    "GET", [] -> listing(kz, context)
    "GET", [user_id] -> one(kz, context, user_id)
    "GET", [user_id, "status"] -> status(kz, context, user_id)
    "PATCH", [user_id, "status"] -> validate_status(kz, context, user_id)
    "GET", [user_id, "log"] -> log(context, user_id)
    "GET", [user_id, "stats"] -> stats(kz, context, user_id)
    _, _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

fn validate_tier(
  kz: Kazoo,
  context: Context,
  tokens: List(String),
  queue_id: String,
) -> Context {
  case crossbar.req_verb(context), tokens {
    "GET", [] -> tier_listing(kz, context, queue_id)
    "GET", _ -> crossbar.add_system_error(context, "invalid_method")
    // Anything but a read changes the queue, which is an administrator's,
    // and is refused before the queue or the body is looked at.
    verb, tokens -> {
      use <- permission.admin_only(context)
      case verb, tokens {
        "PUT", [] -> validate_new_tier(kz, context, queue_id)
        "PATCH", [user_id] ->
          validate_tier_change(kz, context, queue_id, user_id)
        "DELETE", [user_id] ->
          validate_tier_removal(kz, context, queue_id, user_id)
        _, _ -> crossbar.add_system_error(context, "invalid_method")
      }
    }
  }
}

/// The queue this request is about, when it is about one: Crossbar parses
/// `/accounts/{id}/queues/{qid}/agents` into this module's noun first and the
/// queue's second, so the parent is right there in the nouns.
pub fn queue_of(context: Context) -> Option(String) {
  parent_queue(crossbar.req_nouns(context))
}

/// The queue id in a parsed path, deepest noun first.
pub fn parent_queue(nouns: List(#(String, List(String)))) -> Option(String) {
  case nouns {
    [#("agents", _), #("queues", [queue_id, ..]), ..] -> Some(queue_id)
    _ -> None
  }
}

fn put(context: Context, _tokens: List(String)) -> Context {
  // Only a tier reaches here, and a tier is an edit of the queue document.
  save_queue(context)
}

fn patch(context: Context, tokens: List(String)) -> Context {
  case queue_of(context), tokens {
    Some(_queue_id), [_user_id] -> save_queue(context)
    // The status change was made in validate, where the authorisation is;
    // there is no document of this noun's own to save.
    None, [_user_id, "status"] -> crossbar.set_resp_status_success(context)
    _, _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

fn delete(context: Context, _tokens: List(String)) -> Context {
  save_queue(context)
}

/// Crossbar sets a verb's status to `fatal` before it runs, so a verb that
/// answers the context it was given answers a 500. Saving the queue sets the
/// status itself; the status change has nothing to save and says so.
fn save_queue(context: Context) -> Context {
  crossbar.save_doc(context)
}

//
// The listings
//

fn listing(kz: Kazoo, context: Context) -> Context {
  case crossbar.account_id(context) {
    None -> crossbar.add_system_error(context, "bad_identifier")
    Some(account_id) ->
      case agents.all(kz, account_id) {
        Error(reason) -> failed(context, reason)
        Ok(users) -> {
          let activities = live_activities(account_id)
          crossbar.respond(
            context,
            doc.List(
              list.map(users, fn(user) {
                let entry = summary(kz, account_id, user, activities)
                doc.merge(
                  entry,
                  queues_of(
                    kz,
                    account_id,
                    doc.get_string(user, ["_id"])
                      |> result.unwrap(""),
                  ),
                )
              }),
            ),
          )
        }
      }
  }
}

fn one(kz: Kazoo, context: Context, user_id: String) -> Context {
  case crossbar.account_id(context) {
    None -> crossbar.add_system_error(context, "bad_identifier")
    Some(account_id) ->
      case agent(kz, account_id, user_id) {
        Error(context_error) ->
          crossbar.add_system_error(context, context_error)
        Ok(user) -> {
          let entry = summary(kz, account_id, user, live_activities(account_id))
          crossbar.respond(
            context,
            doc.merge(entry, queues_of(kz, account_id, user_id)),
          )
        }
      }
  }
}

/// The user, when they are an agent of this account at all.
fn agent(
  kz: Kazoo,
  account_id: String,
  user_id: String,
) -> Result(Value, String) {
  case agents.fetch(kz, account_id, user_id) {
    Error(kazoo.NotFound) -> Error("bad_identifier")
    Error(_) -> Error("datastore_unreachable")
    Ok(user) ->
      case agents.is_agent(user) {
        // A user without the object is not an agent, and this noun does not
        // answer for users.
        False -> Error("bad_identifier")
        True -> Ok(user)
      }
  }
}

/// One agent as the listing shows them: who they are, what they chose, and
/// what their phones are doing.
fn summary(
  kz: Kazoo,
  account_id: String,
  user: Value,
  activities: Dict(String, String),
) -> Value {
  let user_id = doc.get_string(user, ["_id"]) |> result.unwrap("")
  let state = agent_state.get(kz, account_id, user_id)
  doc.merge(
    agents.summary(user),
    doc.object([
      #("availability", doc.String(availability_of(state))),
      #("activity", doc.String(activity_of(activities, account_id, user_id))),
      #("timestamp", timestamp_of(state)),
      #("source", source_of(state)),
    ]),
  )
}

fn queues_of(kz: Kazoo, account_id: String, user_id: String) -> Value {
  case agents.tiers(kz, account_id, user_id) {
    Error(_) -> doc.object([#("queues", doc.List([]))])
    Ok(tiers) ->
      doc.object([
        #("queues", doc.List(list.map(tiers, agents.tier_to_value))),
      ])
  }
}

fn availability_of(
  state: Result(agent_state.AgentAvailability, kazoo.Error),
) -> String {
  case state {
    Ok(state) -> agent_state.availability_to_string(state.availability)
    Error(_) -> "logged_out"
  }
}

fn timestamp_of(
  state: Result(agent_state.AgentAvailability, kazoo.Error),
) -> Value {
  case state {
    Ok(state) -> doc.Int(state.timestamp)
    Error(_) -> doc.Null
  }
}

fn source_of(
  state: Result(agent_state.AgentAvailability, kazoo.Error),
) -> Value {
  case state {
    Ok(state) -> doc.String(agent_state.source_to_string(state.source))
    Error(_) -> doc.Null
  }
}

/// What the node holding the account's shard says the agents are doing.
/// Nothing when it cannot be asked, which reads as idle: a listing must not
/// fail because the dispatcher is restarting.
fn live_activities(account_id: String) -> Dict(String, String) {
  case status_query.ask(account_id, None) {
    Ok(answers) -> status_query.activities(answers)
    Error(_) -> dict.new()
  }
}

fn activity_of(
  activities: Dict(String, String),
  account_id: String,
  user_id: String,
) -> String {
  case dict.get(activities, user_id) {
    Ok(activity) -> activity
    // Nobody is dispatching this account, so fall back to what this node has
    // derived for itself.
    Error(Nil) ->
      agent_state.activity_to_string(agent_state.activity_of(
        account_id,
        user_id,
      ))
  }
}

//
// Status
//

fn status(kz: Kazoo, context: Context, user_id: String) -> Context {
  case crossbar.account_id(context) {
    None -> crossbar.add_system_error(context, "bad_identifier")
    Some(account_id) ->
      case agent(kz, account_id, user_id) {
        Error(reason) -> crossbar.add_system_error(context, reason)
        Ok(_) ->
          case agent_state.get(kz, account_id, user_id) {
            Error(reason) -> failed(context, reason)
            Ok(state) ->
              crossbar.respond(
                context,
                doc.object_some([
                  #("agent_id", Some(doc.String(user_id))),
                  #(
                    "availability",
                    Some(
                      doc.String(agent_state.availability_to_string(
                        state.availability,
                      )),
                    ),
                  ),
                  #(
                    "activity",
                    Some(
                      doc.String(activity_of(
                        live_activities(account_id),
                        account_id,
                        user_id,
                      )),
                    ),
                  ),
                  #(
                    "source",
                    Some(doc.String(agent_state.source_to_string(state.source))),
                  ),
                  #("timestamp", Some(doc.Int(state.timestamp))),
                  #("break_ends", break_ends(state)),
                ]),
              )
          }
      }
  }
}

/// Who may change what.
///
/// An agent may change their own availability and nobody else's. An account
/// administrator, or a superduper administrator, may change anybody's, and
/// only they may say the change came from a supervisor rather than from the
/// agent themselves.
pub type Change {
  /// `break_s` is how long a break lasts, in seconds, and 0 for no end. Only
  /// a change to `on_break` reads it.
  Change(availability: String, source: String, break_s: Int)
}

/// The change a request asks for, or why it is refused. Separate from the
/// context so that the rules are checked without one.
pub fn requested(
  body: Value,
  auth_user_id: Option(String),
  target_user_id: String,
  is_admin: Bool,
) -> Result(Change, #(List(String), String, String)) {
  use availability <- result.try(case doc.get_string(body, ["availability"]) {
    Error(Nil) ->
      Error(#(["availability"], "required", "the availability to change to"))
    Ok(availability) ->
      case agent_state.availability_from_string(availability) {
        Error(Nil) ->
          Error(#(
            ["availability"],
            "enum",
            "logged_out, available, available_on_demand or on_break",
          ))
        Ok(_) -> Ok(availability)
      }
  })

  let source =
    doc.get_string(body, ["source"])
    |> result.unwrap(agent_state.source_to_string(agent_state.ui))

  use source <- result.try(case source {
    "ui" | "supervisor" -> Ok(source)
    _ -> Error(#(["source"], "enum", "ui or supervisor"))
  })

  // The same `timeout` as the feature code's: seconds, 0 or absent for a
  // break with no end, and read only by a change to `on_break`.
  use break_s <- result.try(case doc.get(body, ["timeout"]) {
    Error(Nil) | Ok(doc.Null) -> Ok(0)
    Ok(doc.Int(seconds)) if seconds >= 0 -> Ok(seconds)
    Ok(doc.Int(_)) ->
      Error(#(["timeout"], "minimum", "0 or more seconds; 0 is no end"))
    Ok(_) -> Error(#(["timeout"], "type", "whole seconds"))
  })

  // Only an administrator may act as a supervisor, and only an
  // administrator may act on somebody else at all.
  case is_admin, auth_user_id == Some(target_user_id) {
    True, _ -> Ok(Change(availability, source, break_s))
    False, _ if source == "supervisor" ->
      Error(#(["source"], "forbidden", "only a supervisor may say supervisor"))
    False, True -> Ok(Change(availability, "ui", break_s))
    False, False ->
      Error(#(
        ["availability"],
        "forbidden",
        "an agent may only change their own status",
      ))
  }
}

fn validate_status(kz: Kazoo, context: Context, user_id: String) -> Context {
  case crossbar.account_id(context) {
    None -> crossbar.add_system_error(context, "bad_identifier")
    Some(account_id) ->
      case agent(kz, account_id, user_id) {
        Error(reason) -> crossbar.add_system_error(context, reason)
        Ok(_) ->
          case
            requested(
              crossbar.req_data(context),
              crossbar.auth_user_id(context),
              user_id,
              permission.is_admin(context),
            )
          {
            Error(#(property, code, message)) ->
              crossbar.add_validation_error(context, property, code, message)
            Ok(change) -> write(kz, context, account_id, user_id, change)
          }
      }
  }
}

fn write(
  kz: Kazoo,
  context: Context,
  account_id: String,
  user_id: String,
  change: Change,
) -> Context {
  let assert Ok(availability) =
    agent_state.availability_from_string(change.availability)
  let assert Ok(source) = agent_state.source_from_string(change.source)
  case
    agent_state.change(
      kz,
      account_id,
      user_id,
      to: availability,
      source: source,
      break_s: change.break_s,
    )
  {
    Error(agent_state.Failed(reason)) -> failed(context, reason)
    Error(agent_state.Unfit(agents.Unread(reason))) -> failed(context, reason)
    // `agent` has already answered 404 for a deleted user or one who is
    // not there, so this is a disabled one, one on do-not-disturb, or a
    // user deleted in between.
    Error(agent_state.Unfit(unfit)) ->
      crossbar.add_validation_error(
        context,
        ["availability"],
        "forbidden",
        agents.unfit_to_string(unfit) <> ": the only availability is logged_out",
      )
    Error(agent_state.NotLoggedIn) ->
      crossbar.add_validation_error(
        context,
        ["availability"],
        "forbidden",
        "the agent is logged_out: a break is only for an agent who is logged in",
      )
    Ok(state) -> {
      system.log(
        "agent "
        <> user_id
        <> " of "
        <> account_id
        <> " is now "
        <> change.availability
        <> " by "
        <> change.source,
      )
      crossbar.respond(
        context,
        doc.object_some([
          #("agent_id", Some(doc.String(user_id))),
          #("availability", Some(doc.String(change.availability))),
          #("source", Some(doc.String(change.source))),
          #("timestamp", Some(doc.Int(state.timestamp))),
          #("break_ends", break_ends(state)),
        ]),
      )
    }
  }
}

/// When the break the agent is on ends by itself, for the answers that show
/// it: absent when there is no such break.
fn break_ends(state: agent_state.AgentAvailability) -> Option(Value) {
  option.map(state.break_ends, doc.Int)
}

//
// Tiers
//
// A tier links an agent to a queue with a level and a position, and lives in
// the queue document's own `agents` list. They are edited one at a time so
// that a supervisor moving one agent does not overwrite whatever else
// somebody was doing to the queue.
//

/// The `pvt_type` of the queue a tier belongs to.
const queue_type = "queue"

fn load_queue(context: Context, queue_id: String) -> Context {
  crossbar.load_doc(context, queue_id, kind: Some(queue_type))
}

/// The queue's `agents` list, each entry with the user it names summarised,
/// so that a supervisor screen does not fetch them one at a time.
fn tier_listing(kz: Kazoo, context: Context, queue_id: String) -> Context {
  let loaded = load_queue(context, queue_id)
  case crossbar.is_success(loaded), crossbar.account_id(context) {
    False, _ -> loaded
    _, None -> crossbar.add_system_error(loaded, "bad_identifier")
    True, Some(account_id) ->
      crossbar.respond(
        loaded,
        doc.List(
          tiers(crossbar.doc(loaded))
          |> list.map(fn(tier) { named(kz, account_id, tier) }),
        ),
      )
  }
}

fn named(kz: Kazoo, account_id: String, tier: Value) -> Value {
  case doc.get_string(tier, ["id"]) {
    Error(Nil) -> tier
    Ok(user_id) ->
      case agents.fetch(kz, account_id, user_id) {
        Error(_) -> tier
        Ok(user) -> doc.merge(agents.summary(user), tier)
      }
  }
}

/// The entries of a queue's `agents` list, with the defaults the schema
/// gives an entry that left them out.
pub fn tiers(queue: Value) -> List(Value) {
  doc.get_list(queue, ["agents"])
  |> result.unwrap([])
  |> list.filter_map(fn(entry) {
    use id <- result.try(doc.get_string(entry, ["id"]))
    Ok(tier(id, level(entry), position(entry)))
  })
}

pub fn tier(user_id: String, level: Int, position: Int) -> Value {
  doc.object([
    #("id", doc.String(user_id)),
    #("level", doc.Int(level)),
    #("position", doc.Int(position)),
  ])
}

fn level(entry: Value) -> Int {
  doc.get_int(entry, ["level"]) |> result.unwrap(1)
}

fn position(entry: Value) -> Int {
  doc.get_int(entry, ["position"]) |> result.unwrap(1)
}

/// Add a tier. The user has to exist, to be enabled, and not to have one
/// already: two tiers for one agent in one queue is a queue that would offer
/// them a caller twice. The rules are `callcenter/tier_check`'s, the ones a
/// write to the queue itself is held to.
fn validate_new_tier(kz: Kazoo, context: Context, queue_id: String) -> Context {
  let loaded = load_queue(context, queue_id)
  case crossbar.is_success(loaded), crossbar.account_id(context) {
    False, _ -> loaded
    _, None -> crossbar.add_system_error(loaded, "bad_identifier")
    True, Some(account_id) -> {
      let body = crossbar.req_data(context)
      let existing = tiers(crossbar.doc(loaded))
      let added =
        doc.object([
          #("id", doc.get(body, ["id"]) |> result.unwrap(doc.Null)),
          ..sent(body, ["level", "position"])
        ])
      write_tiers(
        kz,
        loaded,
        account_id,
        list.append(existing, [added]),
        Some(list.length(existing)),
      )
    }
  }
}

/// Change a tier: whichever of `level` and `position` the body names, and
/// nothing else. The change takes effect on the next offer; a caller already
/// ringing this agent is not disturbed.
fn validate_tier_change(
  kz: Kazoo,
  context: Context,
  queue_id: String,
  user_id: String,
) -> Context {
  let loaded = load_queue(context, queue_id)
  case crossbar.is_success(loaded), crossbar.account_id(context) {
    False, _ -> loaded
    _, None -> crossbar.add_system_error(loaded, "bad_identifier")
    True, Some(account_id) -> {
      let existing = tiers(crossbar.doc(loaded))
      case index_of(existing, user_id) {
        Error(Nil) -> crossbar.add_system_error(loaded, "bad_identifier")
        Ok(#(index, tier)) -> {
          let changed =
            doc.merge(
              tier,
              doc.object(
                sent(crossbar.req_data(context), ["level", "position"]),
              ),
            )
          write_tiers(
            kz,
            loaded,
            account_id,
            replace(existing, user_id, Some(changed)),
            Some(index),
          )
        }
      }
    }
  }
}

fn validate_tier_removal(
  kz: Kazoo,
  context: Context,
  queue_id: String,
  user_id: String,
) -> Context {
  let loaded = load_queue(context, queue_id)
  case crossbar.is_success(loaded), crossbar.account_id(context) {
    False, _ -> loaded
    _, None -> crossbar.add_system_error(loaded, "bad_identifier")
    True, Some(account_id) -> {
      let existing = tiers(crossbar.doc(loaded))
      case index_of(existing, user_id) {
        Error(Nil) -> crossbar.add_system_error(loaded, "bad_identifier")
        Ok(_) ->
          write_tiers(
            kz,
            loaded,
            account_id,
            replace(existing, user_id, None),
            None,
          )
      }
    }
  }
}

/// The members of `body` among `fields`, as they were sent: a value of the
/// wrong type is `tier_check`'s to refuse, not this module's to drop.
fn sent(body: Value, fields: List(String)) -> List(#(String, Value)) {
  list.filter_map(fields, fn(field) {
    doc.get(body, [field]) |> result.map(fn(value) { #(field, value) })
  })
}

/// Where a user's tier is in the list, and the tier.
fn index_of(tiers: List(Value), user_id: String) -> Result(#(Int, Value), Nil) {
  tiers
  |> list.index_map(fn(tier, index) { #(index, tier) })
  |> list.find(fn(pair) { doc.get_string(pair.1, ["id"]) == Ok(user_id) })
}

pub fn existing_tier(queue: Value, user_id: String) -> Option(Value) {
  tiers(queue)
  |> list.filter(fn(tier) { doc.get_string(tier, ["id"]) == Ok(user_id) })
  |> list.first
  |> option.from_result
}

/// The tiers with one user's replaced, or dropped when there is nothing to
/// replace it with.
pub fn replace(
  tiers: List(Value),
  user_id: String,
  with changed: Option(Value),
) -> List(Value) {
  list.flat_map(tiers, fn(tier) {
    case doc.get_string(tier, ["id"]) == Ok(user_id), changed {
      False, _ -> [tier]
      True, Some(changed) -> [changed]
      True, None -> []
    }
  })
}

/// The queue with `entries` as its tiers, when `callcenter/tier_check` and
/// then the queue schema pass it: the two checks a write to the queue itself
/// goes through, in the same order. `written` is the entry the request names
/// by its path, whose problems are reported on the body's own fields.
fn write_tiers(
  kz: Kazoo,
  context: Context,
  account_id: String,
  entries: List(Value),
  written: Option(Int),
) -> Context {
  let before = tiers(crossbar.doc(context))
  case tier_check.check(kz, account_id, entries, before) {
    [_, ..] as problems -> tier_check.refuse(context, problems, written)
    [] ->
      with_tiers(
        context,
        list.filter_map(entries, fn(entry) {
          use user_id <- result.try(doc.get_string(entry, ["id"]))
          Ok(tier(user_id, level(entry), position(entry)))
        }),
        before,
      )
  }
}

/// The queue document with a new tier list, validated against the queue
/// schema and ready for the verb to save. Crossbar validates the request
/// body, so the queue stands in for the body while the schema runs, and the
/// body is put back after. The tiers left as stored are not held to the
/// schema's numbers -- another agent's `level` of 0, saved before the rules
/// -- and are written back as they were: `tier_check.for_schema`.
fn with_tiers(
  context: Context,
  tiers: List(Value),
  before: List(Value),
) -> Context {
  let body = crossbar.req_data(context)
  let queue = doc.set(crossbar.doc(context), ["agents"], doc.List(tiers))
  context
  |> crossbar.set_doc(queue)
  |> crossbar.set_req_data(doc.set(
    queue,
    ["agents"],
    doc.List(tier_check.for_schema(tiers, before)),
  ))
  |> crossbar.validate_request_data(cb_queues.schema, _, fn(context) {
    let validated = crossbar.doc(context)
    let agents =
      tier_check.restore(tier_check.entries(validated), tiers, before)
    context
    |> crossbar.set_doc(doc.set(validated, ["agents"], doc.List(agents)))
    |> crossbar.set_resp_status_success
  })
  |> crossbar.set_req_data(body)
}

//
// The status log and the counters
//

/// Every availability change in the range, newest first.
///
/// The changes are in the month databases, one per month, so a range that
/// spans two months is two views read and merged. A month the account has
/// nothing in was never created and answers nothing, which is not an error.
fn log(context: Context, user_id: String) -> Context {
  case crossbar.account_id(context) {
    None -> crossbar.add_system_error(context, "bad_identifier")
    Some(account_id) -> {
      let #(from, to) = range(context)
      crossbar.respond(
        context,
        doc.List(
          months(from, to)
          |> list.flat_map(fn(at) { changes(account_id, user_id, from, to, at) })
          |> list.sort(fn(a, b) { int.compare(timestamp(b), timestamp(a)) })
          |> list.take(page_size(context)),
        ),
      )
    }
  }
}

fn changes(
  account_id: String,
  user_id: String,
  from: Int,
  to: Int,
  at: Int,
) -> List(Value) {
  let options =
    kazoo.view_options()
    |> kazoo.with_range(
      doc.List([doc.String(user_id), doc.Int(to)]),
      doc.List([doc.String(user_id), doc.Int(from)]),
    )
  let descending = kazoo.ViewOptions(..options, descending: True)
  case
    modb.get_results(
      account_id,
      view: log_view,
      options: descending,
      at: Some(at),
    )
  {
    Ok(rows) -> list.map(rows, change_to_api)
    Error(_) -> []
  }
}

/// One instant in every month the range touches, oldest first. A month is
/// never longer than 31 days, so stepping by 28 cannot step over one.
pub fn months(from: Int, to: Int) -> List(Int) {
  marks(from, to, [])
  |> list.reverse
  |> list.fold([], fn(kept, at) {
    case kept {
      [previous, ..] ->
        case modb.year_month(previous) == modb.year_month(at) {
          True -> kept
          False -> [at, ..kept]
        }
      [] -> [at]
    }
  })
  |> list.reverse
}

const seconds_in_28_days = 2_419_200

fn marks(from: Int, to: Int, taken: List(Int)) -> List(Int) {
  case from >= to {
    True -> [to, ..taken]
    False -> marks(from + seconds_in_28_days, to, [from, ..taken])
  }
}

fn timestamp(change: Value) -> Int {
  doc.get_int(change, ["timestamp"]) |> result.unwrap(0)
}

/// A view row as the API answers it. The view emits the change itself as its
/// value, and includes the document when it was asked to; either shape reads
/// the same fields.
fn change_to_api(row: Value) -> Value {
  let change = case doc.get(row, ["value"]), doc.get(row, ["doc"]) {
    Ok(doc.Object(_) as value), _ -> value
    _, Ok(document) -> document
    _, _ -> row
  }
  doc.object([
    #("availability", doc.get(change, ["to"]) |> result.unwrap(doc.Null)),
    #("previous", doc.get(change, ["from"]) |> result.unwrap(doc.Null)),
    #("source", doc.get(change, ["source"]) |> result.unwrap(doc.Null)),
    #("timestamp", doc.get(change, ["timestamp"]) |> result.unwrap(doc.Null)),
  ])
}

/// The Gregorian-second range a request asks for, and the month up to now
/// when it asks for nothing. A range given backwards is read forwards.
pub fn range(context: Context) -> #(Int, Int) {
  let now = modb.now()
  let to = seconds(context, "created_to") |> option.unwrap(now)
  let from =
    seconds(context, "created_from") |> option.unwrap(to - seconds_in_28_days)
  case from > to {
    True -> #(to, from)
    False -> #(from, to)
  }
}

fn page_size(context: Context) -> Int {
  case seconds(context, "page_size") {
    Some(size) if size > 0 -> size
    _ -> log_page_size
  }
}

/// A query string parameter as a number. Crossbar hands them over as text,
/// and a client that sends JSON gets the number back either way.
fn seconds(context: Context, key: String) -> Option(Int) {
  case crossbar.req_param(context, key) {
    Some(doc.Int(number)) -> Some(number)
    Some(doc.String(text)) -> option.from_result(int.parse(text))
    _ -> None
  }
}

/// The counters kept since the agent last logged in, which are the ones the
/// strategies run on.
fn stats(kz: Kazoo, context: Context, user_id: String) -> Context {
  case crossbar.account_id(context) {
    None -> crossbar.add_system_error(context, "bad_identifier")
    Some(account_id) ->
      case agent(kz, account_id, user_id) {
        Error(reason) -> crossbar.add_system_error(context, reason)
        Ok(_) ->
          crossbar.respond(
            context,
            to_api(agent_state.counters(kz, account_id, user_id)),
          )
      }
  }
}

/// The counters, with the zeroes an agent who has answered nothing still
/// has, so a client never has to tell absent from none.
pub fn to_api(counters: Value) -> Value {
  doc.object([
    #(
      "calls_answered",
      doc.get(counters, ["calls_answered"]) |> result.unwrap(doc.Int(0)),
    ),
    #(
      "talk_time_s",
      doc.get(counters, ["talk_time_s"]) |> result.unwrap(doc.Int(0)),
    ),
    #("missed", doc.get(counters, ["missed"]) |> result.unwrap(doc.Int(0))),
    #(
      "last_call_end",
      doc.get(counters, ["last_call_end"]) |> result.unwrap(doc.Null),
    ),
  ])
}

fn failed(context: Context, reason: kazoo.Error) -> Context {
  case reason {
    kazoo.NotFound -> crossbar.add_system_error(context, "bad_identifier")
    _ -> crossbar.add_system_error(context, "datastore_unreachable")
  }
}
