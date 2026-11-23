//// The account's agents, as documents rather than as state.
////
//// An agent is a user of the account with a `call_center` object, so there
//// is no agent document: the directory is a view over the users, the tiers
//// are entries in the queues' own `agents` lists, and what is live about an
//// agent -- their availability and their activity -- comes from
//// `callcenter/agent_state`.
////
//// Both edges read this: the Crossbar modules for their listings, and the
//// `callcenter_agent` callflow action for the `*23` login, which is a lookup
//// by the agent's own id rather than by the user's.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}

/// The users of the account who are agents, keyed by user id.
pub const listing = "agents/crossbar_listing"

/// The users of the account keyed by the id they type into `*23`.
pub const by_agent_id = "agents/by_agent_id"

/// The queues an agent has a tier in, keyed by `[user_id]`.
///
/// The key is a list of one and not the bare id, which is what makes room
/// for a second element later without a second view.
pub const queues_by_agent = "callcenter/queues_by_agent"

/// The users of the account the agent listing lists, keyed by user id, with
/// what the do-not-disturb sweep weighs of each and nothing more: whether
/// they are an agent, enabled, and on do-not-disturb (`Standing`).
///
/// The same users as `listing`, deleted ones left out alike, so that a user
/// absent from both is deleted or gone.
pub const standing_view = "callcenter/agent_users"

/// A user as the do-not-disturb sweep weighs them, off `standing_view` or
/// off their document: `agent` is `is_agent`, `enabled` is `is_enabled` and
/// `dnd` is `is_dnd`.
pub type Standing {
  Standing(user_id: String, agent: Bool, enabled: Bool, dnd: Bool)
}

/// One agent's tier in one queue.
pub type Tier {
  Tier(queue_id: String, queue_name: Option(String), level: Int, position: Int)
}

/// Every agent of the account, as their user documents.
pub fn all(kz: Kazoo, account_id: String) -> Result(List(Value), Error) {
  use rows <- result.try(kz.datamgr.get_results(
    kazoo.account_db(account_id),
    listing,
    kazoo.view_options() |> kazoo.with_docs,
  ))
  Ok(list.filter_map(rows, document))
}

/// Every user of the account the listing lists, as the do-not-disturb sweep
/// weighs them: one view read, with no document behind it.
pub fn standing(
  kz: Kazoo,
  account_id: String,
) -> Result(List(Standing), Error) {
  use rows <- result.try(kz.datamgr.get_results(
    kazoo.account_db(account_id),
    standing_view,
    kazoo.view_options(),
  ))
  Ok(list.filter_map(rows, standing_row))
}

fn standing_row(row: Value) -> Result(Standing, Nil) {
  use user_id <- result.try(doc.get_string(row, ["id"]))
  let value = doc.get(row, ["value"]) |> result.unwrap(doc.Null)
  Ok(Standing(
    user_id: user_id,
    agent: doc.get_bool(value, ["agent"]) == Ok(True),
    enabled: doc.get_bool(value, ["enabled"]) |> result.unwrap(True),
    dnd: doc.get_bool(value, ["do_not_disturb"]) |> result.unwrap(False),
  ))
}

/// A user's standing off their document, when it has an id.
pub fn standing_of(user: Value) -> Result(Standing, Nil) {
  use user_id <- result.try(doc.get_string(user, ["_id"]))
  Ok(Standing(
    user_id: user_id,
    agent: is_agent(user),
    enabled: is_enabled(user),
    dnd: is_dnd(user),
  ))
}

/// One agent, as their user document, when the user is one at all.
///
/// A user Crossbar has deleted is `NotFound`: the soft delete leaves the
/// document behind marked `pvt_deleted`, and the listings' views already
/// leave it out, so the one agent read here answers as the listing does.
pub fn fetch(
  kz: Kazoo,
  account_id: String,
  user_id: String,
) -> Result(Value, Error) {
  use user <- result.try(kz.datamgr.open_cache_doc(
    kazoo.account_db(account_id),
    user_id,
  ))
  case doc.get_string(user, ["pvt_type"]), is_deleted(user) {
    Ok("user"), False -> Ok(user)
    _, _ -> Error(kazoo.NotFound)
  }
}

/// Whether a document has been deleted by Crossbar's soft delete.
pub fn is_deleted(document: Value) -> Bool {
  doc.get_bool(document, ["pvt_deleted"]) == Ok(True)
}

/// Whether a user who has a tier can be offered a caller at all: they are
/// there, enabled, and not on do-not-disturb. A user who is deleted, gone,
/// or disabled is not an agent anybody rings, whatever their availability
/// document still says; nor is one whose phones refuse calls, until the
/// listener that follows do-not-disturb has logged them out.
///
/// A user who could not be read is taken as there: a datastore that did not
/// answer has said nothing about them, and dispatch through an outage is
/// best effort on what is known.
pub fn can_be_offered(read: Result(Value, Error)) -> Bool {
  case read {
    Ok(user) -> !is_deleted(user) && is_enabled(user) && !is_dnd(user)
    Error(kazoo.NotFound) -> False
    Error(_unreachable) -> True
  }
}

/// Why a user may not start working: be made available, available on
/// demand, or put on a break.
pub type Unfit {
  /// No such user, or a document that is not one.
  NoSuchUser
  /// Deleted by Crossbar's soft delete.
  Deleted
  /// `enabled: false`.
  Disabled
  /// Do-not-disturb is set on the user, which holds the agent at logged
  /// out for as long as it is.
  DoNotDisturb
  /// The user could not be read, so nothing is known about them.
  Unread(Error)
}

/// Whether the user read may start working: there, a user, not deleted,
/// enabled and not on do-not-disturb. The one rule every route that logs an
/// agent in or puts them on a break goes by -- the feature codes, the API,
/// the operator's command and a break that ends by itself -- so that none
/// of them makes a user available whom the dispatcher would never offer a
/// caller to, and whom the sweep would log out again. Logging out needs
/// none of it.
///
/// Do-not-disturb refuses a break as well as a login. A break is only for
/// an agent who is logged in, and do-not-disturb holds the agent logged
/// out; a break taken in the moment before the listener does so would be
/// logged out a moment later, so it is one rule for all three.
///
/// Unlike `can_be_offered`, a user who could not be read is refused: this
/// is a person asking, who can ask again, not a caller waiting.
pub fn fit_to_work(read: Result(Value, Error)) -> Result(Nil, Unfit) {
  case read {
    Error(kazoo.NotFound) -> Error(NoSuchUser)
    Error(reason) -> Error(Unread(reason))
    Ok(user) ->
      case doc.get_string(user, ["pvt_type"]), is_deleted(user) {
        Ok("user"), True -> Error(Deleted)
        Ok("user"), False ->
          case is_enabled(user), is_dnd(user) {
            False, _ -> Error(Disabled)
            True, True -> Error(DoNotDisturb)
            True, False -> Ok(Nil)
          }
        _not_a_user, _ -> Error(NoSuchUser)
      }
  }
}

/// `fit_to_work` for the user by id, read through the document cache,
/// which a user's edit empties.
pub fn may_work(
  kz: Kazoo,
  account_id: String,
  user_id: String,
) -> Result(Nil, Unfit) {
  kz.datamgr.open_cache_doc(kazoo.account_db(account_id), user_id)
  |> fit_to_work
}

/// What `Unfit` says, for a log line, a refusal and an operator.
pub fn unfit_to_string(unfit: Unfit) -> String {
  case unfit {
    NoSuchUser -> "no such user"
    Deleted -> "the user is deleted"
    Disabled -> "the user is disabled"
    DoNotDisturb -> "do not disturb is set on the user"
    Unread(reason) ->
      "the user could not be read: " <> kazoo.error_to_string(reason)
  }
}

/// Whether a user document is an agent.
///
/// The `call_center` object is what makes one, and it has to say something:
/// an empty object is a user nobody has made an agent, which is what a
/// document written before the object had any meaning looks like.
pub fn is_agent(user: Value) -> Bool {
  case settings(user) {
    doc.Object(_) as settings -> doc.members(settings) != []
    _ -> False
  }
}

/// The `call_center` object, which is where an agent's own settings live.
pub fn settings(user: Value) -> Value {
  case doc.get(user, ["call_center"]) {
    Ok(settings) -> settings
    Error(Nil) -> doc.Null
  }
}

/// The id the agent types into `*23`, when they have one that differs from
/// their user id.
pub fn agent_id(user: Value) -> Option(String) {
  case doc.get_string(user, ["call_center", "agent_id"]) {
    Ok("") | Error(Nil) -> None
    Ok(agent_id) -> Some(agent_id)
  }
}

/// The PIN the agent types after their id. An agent with none cannot log in
/// from a phone that is not their own, which is the safe direction.
pub fn pin(user: Value) -> Option(String) {
  case doc.get_string(user, ["call_center", "pin"]) {
    Ok("") | Error(Nil) -> None
    Ok(pin) -> Some(pin)
  }
}

pub fn is_enabled(user: Value) -> Bool {
  doc.get_bool(user, ["enabled"]) |> result.unwrap(True)
}

/// Whether do-not-disturb is set on the user, which holds the agent at
/// logged out for as long as it is.
pub fn is_dnd(user: Value) -> Bool {
  doc.get_bool(user, ["do_not_disturb", "enabled"]) |> result.unwrap(False)
}

/// The user whose agent id this is. `NotFound` when nobody claims it, and
/// the first when -- through a document written by hand -- two do.
pub fn by_id(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(Value, Error) {
  use rows <- result.try(kz.datamgr.get_results(
    kazoo.account_db(account_id),
    by_agent_id,
    kazoo.view_options()
      |> kazoo.with_key(doc.String(agent_id))
      |> kazoo.with_docs,
  ))
  case list.filter_map(rows, document) {
    [user, ..] -> Ok(user)
    [] -> Error(kazoo.NotFound)
  }
}

/// The agent whose user `presence_id` -- their extension -- is this, which
/// is who `*22<extension>` toggles. Read off the agent listing, whose rows
/// carry the presence id, so a user who is not an agent is never found.
/// `NotFound` when nobody has it, and the first when two do.
pub fn by_presence_id(
  kz: Kazoo,
  account_id: String,
  presence_id: String,
) -> Result(String, Error) {
  use rows <- result.try(kz.datamgr.get_results(
    kazoo.account_db(account_id),
    listing,
    kazoo.view_options(),
  ))
  rows
  |> list.find_map(fn(row) {
    case doc.get_string(row, ["value", "presence_id"]) {
      Ok(found) if found == presence_id -> doc.get_string(row, ["id"])
      _ -> Error(Nil)
    }
  })
  |> result.replace_error(kazoo.NotFound)
}

/// Whether a user is an administrator of their account: `priv_level`
/// `admin`, which is what lets them toggle somebody else's login.
pub fn is_admin(user: Value) -> Bool {
  doc.get_string(user, ["priv_level"]) == Ok("admin")
}

/// The tiers an agent holds, one per queue they are in.
pub fn tiers(
  kz: Kazoo,
  account_id: String,
  user_id: String,
) -> Result(List(Tier), Error) {
  use rows <- result.try(kz.datamgr.get_results(
    kazoo.account_db(account_id),
    queues_by_agent,
    kazoo.view_options()
      |> kazoo.with_key(doc.List([doc.String(user_id)]))
      |> kazoo.with_docs,
  ))
  Ok(
    rows
    |> list.filter_map(document)
    |> list.filter_map(fn(queue) { tier_in(queue, user_id) }),
  )
}

/// Every user of the account with a tier in any queue, once each.
pub fn tiered(kz: Kazoo, account_id: String) -> Result(List(String), Error) {
  use rows <- result.try(kz.datamgr.get_results(
    kazoo.account_db(account_id),
    queues_by_agent,
    kazoo.view_options(),
  ))
  rows
  |> list.filter_map(fn(row) {
    case doc.get_list(row, ["key"]) {
      Ok([doc.String(user_id), ..]) -> Ok(user_id)
      _ -> doc.get_string(row, ["value", "agent_id"])
    }
  })
  |> list.unique
  |> Ok
}

/// Take a user out of every queue of the account they have a tier in, and
/// answer the queues they were taken out of. What a user being deleted
/// calls for: a tier naming nobody is a line on every supervisor's screen
/// and a read on every dispatch pass, for an agent nobody will ever ring.
///
/// Each queue is read from the database and written back without the tier,
/// once more on a conflict: a supervisor saving the queue at the same moment
/// is the one other writer, and their save is not overwritten.
pub fn remove_from_queues(
  kz: Kazoo,
  account_id: String,
  user_id: String,
) -> Result(List(String), Error) {
  let db = kazoo.account_db(account_id)
  use rows <- result.try(kz.datamgr.get_results(
    db,
    queues_by_agent,
    kazoo.view_options() |> kazoo.with_key(doc.List([doc.String(user_id)])),
  ))
  rows
  |> list.filter_map(fn(row) { doc.get_string(row, ["id"]) })
  |> list.unique
  |> list.try_map(fn(queue_id) {
    remove_tier(kz, db, queue_id, user_id, 2)
    |> result.map(fn(_saved) { queue_id })
  })
}

fn remove_tier(
  kz: Kazoo,
  db: String,
  queue_id: String,
  user_id: String,
  tries: Int,
) -> Result(Nil, Error) {
  use queue <- result.try(kz.datamgr.open_doc(db, queue_id))
  case kz.datamgr.save_doc(db, without_tier(queue, user_id)) {
    Ok(_saved) -> Ok(Nil)
    Error(kazoo.Conflict) if tries > 1 ->
      remove_tier(kz, db, queue_id, user_id, tries - 1)
    Error(reason) -> Error(reason)
  }
}

/// A queue document with a user's tier taken out of its `agents` list.
pub fn without_tier(queue: Value, user_id: String) -> Value {
  let kept =
    doc.get_list(queue, ["agents"])
    |> result.unwrap([])
    |> list.filter(fn(entry) { doc.get_string(entry, ["id"]) != Ok(user_id) })
  doc.set(queue, ["agents"], doc.List(kept))
}

/// One agent's tier in one queue document, when they have one.
pub fn tier_in(queue: Value, user_id: String) -> Result(Tier, Nil) {
  use entry <- result.try(
    doc.get_list(queue, ["agents"])
    |> result.unwrap([])
    |> list.filter(fn(entry) { doc.get_string(entry, ["id"]) == Ok(user_id) })
    |> list.first,
  )
  Ok(Tier(
    queue_id: doc.get_string(queue, ["_id"]) |> result.unwrap(""),
    queue_name: doc.get_string(queue, ["name"]) |> option.from_result,
    level: doc.get_int(entry, ["level"]) |> result.unwrap(1),
    position: doc.get_int(entry, ["position"]) |> result.unwrap(1),
  ))
}

pub fn tier_to_value(tier: Tier) -> Value {
  doc.object([
    #("queue_id", doc.String(tier.queue_id)),
    #("queue_name", case tier.queue_name {
      Some(name) -> doc.String(name)
      None -> doc.Null
    }),
    #("level", doc.Int(tier.level)),
    #("position", doc.Int(tier.position)),
  ])
}

/// The parts of a user document a listing shows, which is what a supervisor
/// screen needs to name the agent without fetching them one at a time.
///
/// `enabled` says whether the user is: a disabled agent is listed, marked,
/// logged out and never offered a caller, and keeps their tiers so that
/// enabling them again brings them back as they were, logged out. A deleted
/// one is not listed at all.
pub fn summary(user: Value) -> Value {
  doc.object([
    #("id", doc.get(user, ["_id"]) |> result.unwrap(doc.Null)),
    #("enabled", doc.Bool(is_enabled(user))),
    #("first_name", doc.get(user, ["first_name"]) |> result.unwrap(doc.Null)),
    #("last_name", doc.get(user, ["last_name"]) |> result.unwrap(doc.Null)),
    #("username", doc.get(user, ["username"]) |> result.unwrap(doc.Null)),
    #("email", doc.get(user, ["email"]) |> result.unwrap(doc.Null)),
    #("presence_id", doc.get(user, ["presence_id"]) |> result.unwrap(doc.Null)),
  ])
}

/// The document a view row carries when the view was asked to include it.
pub fn document(row: Value) -> Result(Value, Nil) {
  doc.get(row, ["doc"])
}
