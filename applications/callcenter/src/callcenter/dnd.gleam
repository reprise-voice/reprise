//// Do not disturb, and what it does to an agent.
////
//// Setting do-not-disturb on a user takes their phones out of every ring
//// group and every callflow. An agent is no different, and the call center
//// has to know: an agent left available while their phones refuse calls is
//// an agent every queue keeps offering callers to and every offer times out
//// on. So do-not-disturb forces the agent logged out, and clearing it puts
//// them back where they were.
////
//// The trigger is the document change every save already publishes. This
//// binds to `doc_edited` for `user` documents, and because that carries the
//// ids and not the document, the user is read back before anything is
//// decided. The listener hands the work to an actor rather than doing it
//// itself: a closure that goes to the datastore stops the consumer.
////
//// One queue, `callcenter_dnd`, shared by every node, so each edit reaches
//// one node: a queue per node handed every node every user edit in the
//// cluster, and they raced each other to the same `availability.set` --
//// duplicate availability and presence events, and 409s. It holds far more
//// than the default hundred messages, because a burst of user edits -- an
//// import, a bulk change -- dropped do-not-disturb changes silently past it.
////
//// Behind the events is the sweep: every `reconcile_interval_s` it runs
//// `sweep` over the accounts this node dispatches, which reads what the
//// account's agents stand at, their availabilities and their tiers, three
//// views with no documents behind them, and touches only the agents whose
//// do-not-disturb and availability disagree. An edit that was lost, or
//// dropped, is followed a sweep later.
////
//// It is the availability document that says whether a logged-out agent was
//// logged out by this or by themselves -- `source` is `dnd` only when it was
//// -- so an agent who logged out by hand during a do-not-disturb is not
//// logged back in when it is cleared.
////
//// The same listener follows a user who stops being somebody a queue can
//// ring, off the same queue so that one node acts on each change:
////
//// - disabled (`enabled: false`, a `doc_edited`): logged out, as the
////   `system`, and their tiers kept, so that enabling them again brings them
////   back where they were in every queue, logged out. Nothing logs them back
////   in: do-not-disturb clearing restores nobody, while they are disabled or
////   after they are enabled again, because disabling an agent do-not-disturb
////   had logged out makes that logout the system's.
//// - deleted (a `doc_deleted`, which Crossbar's soft delete publishes too,
////   or a document that is gone): taken out of every queue's tiers, logged
////   out -- which writes the `agent_status_change` history to the month
////   database and publishes the change -- and their `callcenter_agent`
////   document deleted, since the user it belonged to is gone.
////
//// The dispatcher does not wait for either: it never offers a disabled or
//// deleted user, nor counts them available (`dispatcher/view.agent_state`).
//// The sweep follows both as it follows do-not-disturb: an agent disabled and
//// not logged out, and an availability document or a tier whose user is
//// gone, are looked at again.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/listener.{Limited}
import kazoo/modb
import kazoo/util

import callcenter/agent_state.{type AgentAvailability}
import callcenter/agents
import callcenter/availability
import callcenter/breaks
import callcenter/fields
import callcenter/records
import callcenter/system
import callcenter/types.{type Availability, LoggedOut}

/// What the actor is told: a user document changed.
pub type Message {
  Changed(account_id: String, user_id: String)
}

const worker = "callcenter_dnd"

/// The queue every node consumes user edits from.
pub const queue_name = "callcenter_dnd"

/// What a change to a user calls for.
pub type Decision {
  /// Do-not-disturb went on: hold the agent at logged out, remembering what
  /// they were.
  Force
  /// It went off: put the agent back where it found them.
  Restore(to: Availability)
  /// It went off, and it had found the agent on a break with an end that
  /// has not come yet: back on that break, ending at `ends` as it was going
  /// to, and then back to `then`.
  RestoreBreak(ends: Int, then: Availability)
  /// The user was disabled: logged out, tiers kept.
  Disable
  /// The user was deleted: out of every queue, logged out, and their agent
  /// document gone. `queues` are the queues their tiers were taken out of.
  Remove(queues: List(String))
  /// Nothing to do, which is nearly every user edit.
  Leave
}

/// The hook, as supervised children: the actor that does the work and the
/// listener that feeds it.
///
/// Nothing at all where there is no `gen_listener` to start, which is
/// `gleam run` and the test suite, the same way the placement answers.
pub fn supervised(kz: Kazoo) -> List(supervision.ChildSpecification(Nil)) {
  case broker_available() {
    False -> []
    True -> [worker_child(kz), listener_child()]
  }
}

@external(erlang, "callcenter_ffi", "broker_available")
fn broker_available() -> Bool

fn worker_child(kz: Kazoo) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new(kz)
    |> actor.on_message(handle)
    |> actor.named(util.name(worker))
    |> actor.start
  })
  |> supervision.map_data(fn(_started) { Nil })
}

fn listener_child() -> supervision.ChildSpecification(Nil) {
  consumer()
  |> listener.supervised
  |> supervision.map_data(fn(_server) { Nil })
}

/// The listener itself, described and not started. Two bindings: a user
/// document that was edited, and one that was deleted, in any account, off
/// the queue every node shares.
pub fn consumer() -> listener.Listener {
  listener.new()
  |> listener.binding("conf", [
    listener.prop("action", listener.Text("edited")),
    listener.prop("doc_type", listener.Text("user")),
  ])
  |> listener.binding("conf", [
    listener.prop("action", listener.Text("deleted")),
    listener.prop("doc_type", listener.Text("user")),
  ])
  |> listener.queue(
    name: queue_name,
    durable: False,
    exclusive: False,
    auto_delete: True,
    // An edit followed five minutes late still puts the agent right; the
    // sweep follows anything older.
    ttl: Limited(300_000),
    max_length: Limited(10_000),
  )
  |> listener.on_event(fn(event, _delivery) {
    case account_of(event), doc.get_string(event, ["ID"]) {
      Some(account_id), Ok(user_id) ->
        process.send(
          process.named_subject(util.name(worker)),
          Changed(account_id, user_id),
        )
      _, _ -> Nil
    }
  })
}

fn handle(kz: Kazoo, message: Message) -> actor.Next(Kazoo, Message) {
  case message {
    Changed(account_id, user_id) -> {
      apply(kz, account_id, user_id)
      actor.continue(kz)
    }
  }
}

/// Read the user and the agent's availability, decide, and write.
///
/// The user is read from the database and not the document cache: the
/// cache is emptied by the same change notice that brought this here, off
/// another consumer, and read first it can still hold the user as they were
/// before the edit or the delete.
pub fn apply(kz: Kazoo, account_id: String, user_id: String) -> Decision {
  case kz.datamgr.open_doc(kazoo.account_db(account_id), user_id) {
    Error(kazoo.NotFound) -> remove(kz, account_id, user_id)
    // Nothing known; the sweep asks again.
    Error(_unreadable) -> Leave
    Ok(user) ->
      case doc.get_string(user, ["pvt_type"]), agents.is_deleted(user) {
        Ok("user"), True -> remove(kz, account_id, user_id)
        Ok("user"), False -> apply_to_user(kz, account_id, user_id, user)
        _not_a_user, _ -> Leave
      }
  }
}

fn apply_to_user(
  kz: Kazoo,
  account_id: String,
  user_id: String,
  user: Value,
) -> Decision {
  case agents.is_agent(user), agents.is_enabled(user) {
    False, _ -> Leave
    True, False -> disable(kz, account_id, user_id)
    True, True -> apply_to_agent(kz, account_id, user_id, agents.is_dnd(user))
  }
}

fn apply_to_agent(
  kz: Kazoo,
  account_id: String,
  user_id: String,
  dnd: Bool,
) -> Decision {
  case agent_state.get(kz, account_id, user_id) {
    Error(_) -> Leave
    Ok(state) -> {
      let decision = decide(dnd, state, modb.now())
      case decision {
        Force -> write(kz, account_id, user_id, LoggedOut, "do not disturb")
        Restore(to) ->
          write(kz, account_id, user_id, to, "do not disturb cleared")
        RestoreBreak(ends, then) ->
          restore_break(kz, account_id, user_id, ends, then)
        Leave | Disable | Remove(_) -> Nil
      }
      decision
    }
  }
}

/// A disabled agent: logged out, by the system, unless they are already.
/// Their tiers stay, so that enabling them brings them back, logged out.
///
/// An agent do-not-disturb logged out is logged out already, and their
/// document still says do-not-disturb did it and what they were before:
/// left so, do-not-disturb cleared once they were enabled again -- or
/// cleared while they were disabled, and they were enabled after -- logged
/// them back in. The logout is made the system's (`availability.
/// disown_logout`), so that whatever order the three come in, nothing puts
/// a disabled agent back to work but a person.
fn disable(kz: Kazoo, account_id: String, user_id: String) -> Decision {
  case agent_state.get(kz, account_id, user_id) {
    Ok(state) if state.availability != LoggedOut -> {
      write_as(
        kz,
        account_id,
        user_id,
        LoggedOut,
        agent_state.system,
        "user disabled",
      )
      Disable
    }
    Ok(state) ->
      case was_dnd(state) {
        False -> Leave
        True -> disown(kz, account_id, user_id)
      }
    Error(_unread) -> Leave
  }
}

fn disown(kz: Kazoo, account_id: String, user_id: String) -> Decision {
  case availability.disown_logout(kz, account_id, user_id) {
    Ok(True) -> {
      system.log(
        "agent "
        <> user_id
        <> " of "
        <> account_id
        <> " was logged out by do not disturb and is now disabled: "
        <> "clearing do not disturb will not log them back in",
      )
      Disable
    }
    Ok(False) -> Leave
    Error(reason) -> {
      system.log_error(
        "could not follow user disabled for agent "
        <> user_id
        <> ": "
        <> kazoo.error_to_string(reason),
      )
      Leave
    }
  }
}

/// A deleted user: out of every queue's tiers, logged out by the system --
/// which writes the status change to the month database and publishes it --
/// and their `callcenter_agent` document deleted. `Leave` when none of the
/// three had anything to do, which is a user who was never an agent, and
/// the second time the same deletion is followed.
fn remove(kz: Kazoo, account_id: String, user_id: String) -> Decision {
  let queues = case agents.remove_from_queues(kz, account_id, user_id) {
    Ok(queues) -> queues
    Error(reason) -> {
      system.log_error(
        "could not take deleted user "
        <> user_id
        <> " of "
        <> account_id
        <> " out of their queues: "
        <> kazoo.error_to_string(reason),
      )
      []
    }
  }
  let logged_out = case agent_state.get(kz, account_id, user_id) {
    Ok(state) if state.availability != LoggedOut -> {
      write_as(
        kz,
        account_id,
        user_id,
        LoggedOut,
        agent_state.system,
        "user deleted",
      )
      True
    }
    _logged_out_or_unread -> False
  }
  let forgotten = case
    kz.datamgr.del_doc(
      kazoo.account_db(account_id),
      records.agent_document_id(user_id),
    )
  {
    Ok(_) -> True
    Error(_none) -> False
  }
  case queues, logged_out, forgotten {
    [], False, False -> Leave
    _, _, _ -> {
      system.log(
        "user "
        <> user_id
        <> " of "
        <> account_id
        <> " was deleted: taken out of "
        <> int.to_string(list.length(queues))
        <> " queue(s) and no longer an agent",
      )
      Remove(queues)
    }
  }
}

/// The break do-not-disturb held, given back with the time it had left, and
/// this node's timer set for its end as for any break with one.
fn restore_break(
  kz: Kazoo,
  account_id: String,
  user_id: String,
  ends: Int,
  then: Availability,
) -> Nil {
  case
    availability.resume_break(
      kz,
      account_id,
      user_id,
      ends: ends,
      then: then,
      source: agent_state.dnd,
    )
  {
    Ok(state) -> {
      case state.break_ends {
        Some(ends) -> breaks.arm(kz, account_id, user_id, ends)
        None -> Nil
      }
      system.log(
        "agent "
        <> user_id
        <> " of "
        <> account_id
        <> " is back on the break do not disturb found them on, until "
        <> int.to_string(ends)
        <> ": do not disturb cleared",
      )
    }
    Error(reason) ->
      system.log_error(
        "could not follow do not disturb cleared for agent "
        <> user_id
        <> ": "
        <> kazoo.error_to_string(reason),
      )
  }
}

fn write(
  kz: Kazoo,
  account_id: String,
  user_id: String,
  to: Availability,
  why: String,
) -> Nil {
  write_as(kz, account_id, user_id, to, agent_state.dnd, why)
}

fn write_as(
  kz: Kazoo,
  account_id: String,
  user_id: String,
  to: Availability,
  source: agent_state.Source,
  why: String,
) -> Nil {
  case agent_state.set(kz, account_id, user_id, to: to, source: source) {
    Ok(_) ->
      system.log(
        "agent "
        <> user_id
        <> " of "
        <> account_id
        <> " is now "
        <> agent_state.availability_to_string(to)
        <> ": "
        <> why,
      )
    Error(reason) ->
      system.log_error(
        "could not follow "
        <> why
        <> " for agent "
        <> user_id
        <> ": "
        <> kazoo.error_to_string(reason),
      )
  }
}

/// What do-not-disturb calls for, given what the agent is now, at `now`.
///
/// Turning it on when the agent is already logged out does nothing, so that
/// the availability they chose for themselves is not overwritten with the
/// one they are already in and then restored over the top of it.
pub fn decide(dnd: Bool, state: AgentAvailability, now: Int) -> Decision {
  case dnd, state.availability {
    True, LoggedOut -> Leave
    True, _ -> Force
    False, LoggedOut -> maybe_restore(state, now)
    False, _ -> Leave
  }
}

/// A break with an end that do-not-disturb logged the agent out of is given
/// back as the break it was: the rest of it, when its end has not come, and
/// otherwise what it would have ended to (`breaks.ends_to`) -- which never
/// logs anybody in who was not logged in before it. Restored as a break
/// with no end, it lasted until somebody noticed.
fn maybe_restore(state: AgentAvailability, now: Int) -> Decision {
  case was_dnd(state), state.held_break, state.previous {
    False, _, _ -> Leave
    True, Some(availability.HeldBreak(ends, before)), _ ->
      case now >= ends, breaks.ends_to(before) {
        False, then -> RestoreBreak(ends: ends, then: then)
        True, LoggedOut -> Leave
        True, then -> Restore(then)
      }
    True, None, Some(LoggedOut) -> Leave
    True, None, None -> Leave
    True, None, Some(previous) -> Restore(previous)
  }
}

/// Whether it was do-not-disturb that logged the agent out, rather than the
/// agent or a supervisor.
fn was_dnd(state: AgentAvailability) -> Bool {
  agent_state.source_to_string(state.source) == "dnd"
}

// --- Behind the events ------------------------------------------------------

/// One account's sweep: follow do-not-disturb and the rest (`reconcile`),
/// then end the breaks that are overdue (`breaks.sweep_read`), off one read
/// of the account's availabilities for both. Says what was done to whom, by
/// each.
///
/// Three view reads for an account where every agent is in step and no
/// break is overdue, none of them with documents: the availabilities, the
/// users' standing and the tiers. Each read the availabilities for itself,
/// and the users came as their whole documents.
pub fn sweep(
  kz: Kazoo,
  account_id: String,
) -> #(List(#(String, Decision)), List(#(String, Availability))) {
  let states = availability.all(kz, account_id)
  let followed = reconcile_read(kz, account_id, states)
  let ended = breaks.sweep_read(kz, account_id, states, modb.now())
  #(followed, ended)
}

/// Follow do-not-disturb, a disabled user and a deleted one for every agent
/// of an account whose documents disagree, and say what was done to whom.
///
/// Three views -- the users' standing, their availabilities and the tiers
/// -- and nothing more for an account where they agree, which is nearly
/// every account on nearly every sweep. Each agent found is decided again by
/// `apply`, from the documents read then, so an agent a user edit put right
/// in between is left alone.
pub fn reconcile(kz: Kazoo, account_id: String) -> List(#(String, Decision)) {
  reconcile_read(kz, account_id, availability.all(kz, account_id))
}

/// The same, off the availabilities view as already read.
pub fn reconcile_read(
  kz: Kazoo,
  account_id: String,
  states: Result(List(#(String, AgentAvailability)), kazoo.Error),
) -> List(#(String, Decision)) {
  case agents.standing(kz, account_id), states, agents.tiered(kz, account_id) {
    Ok(users), Ok(states), Ok(tiered) ->
      list.append(
        disagreeing_standing(users, dict.from_list(states)),
        orphaned_standing(
          users,
          list.append(list.map(states, fn(s) { s.0 }), tiered),
        ),
      )
      |> list.unique
      |> list.filter_map(fn(user_id) {
        case apply(kz, account_id, user_id) {
          Leave -> Error(Nil)
          decision -> Ok(#(user_id, decision))
        }
      })
    // Any view unread is nothing known; the next sweep reads again.
    _, _, _ -> []
  }
}

/// The agents whose documents disagree: the users given, by id, against
/// their availabilities. Do-not-disturb and the availability out of step
/// (`disagrees`), or a disabled agent who is not logged out or whose logout
/// do-not-disturb could still undo. An agent with no availability document
/// is logged out.
pub fn disagreeing(
  users: List(Value),
  states: Dict(String, AgentAvailability),
) -> List(String) {
  disagreeing_standing(list.filter_map(users, agents.standing_of), states)
}

/// The same, of the users as the standing view gives them.
pub fn disagreeing_standing(
  users: List(agents.Standing),
  states: Dict(String, AgentAvailability),
) -> List(String) {
  list.filter_map(users, fn(user) {
    case user.agent {
      True -> {
        let state =
          dict.get(states, user.user_id)
          |> result.unwrap(availability.logged_out())
        case
          disagrees(user.dnd, state)
          || {
            !user.enabled
            && { state.availability != LoggedOut || was_dnd(state) }
          }
        {
          True -> Ok(user.user_id)
          False -> Error(Nil)
        }
      }
      False -> Error(Nil)
    }
  })
}

/// The ids with an availability document or a tier that name no agent of
/// the listing: a user who was deleted -- the listing's view leaves them
/// out -- or whose document is gone, and whose deletion was not followed.
/// A user with a tier who was never made an agent is one of these too, and
/// `apply` leaves them be.
pub fn orphaned(users: List(Value), named: List(String)) -> List(String) {
  orphaned_standing(list.filter_map(users, agents.standing_of), named)
}

/// The same, of the users as the standing view gives them, which leaves
/// deleted users out as the listing does: a user absent from it is deleted
/// or gone.
pub fn orphaned_standing(
  users: List(agents.Standing),
  named: List(String),
) -> List(String) {
  let known =
    users
    |> list.map(fn(user) { user.user_id })
    |> set.from_list
  named
  |> list.unique
  |> list.filter(fn(user_id) { user_id != "" && !set.contains(known, user_id) })
}

/// Whether an agent's do-not-disturb and availability disagree: on and
/// logged in, or off and still held out by it. The second is only worth
/// deciding when there is somewhere to put them back, which `decide` reads
/// off the document; the views do not carry it, so the agent is looked at.
pub fn disagrees(dnd: Bool, state: AgentAvailability) -> Bool {
  case dnd, state.availability {
    True, LoggedOut -> False
    True, _ -> True
    False, LoggedOut -> was_dnd(state)
    False, _ -> False
  }
}

/// The account a document change belongs to: the event says so, and where it
/// does not the database name does.
pub fn account_of(event: Value) -> Option(String) {
  fields.account_of_change(event)
}

/// An encoded account database back to the account id.
pub fn account_of_db(database: String) -> String {
  fields.account_of_db(database)
}
