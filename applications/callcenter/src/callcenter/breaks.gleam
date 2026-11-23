//// A break with an end.
////
//// The feature code's callflow data can say how long a break lasts,
//// `timeout` in seconds, and so can the API's `PATCH .../status`. Absent or
//// 0 is a break with no end, which lasts until something ends it; above 0,
//// the break ends by itself that many seconds after it began and the agent
//// goes back to exactly what they were before it (`ends_to`): available or
//// available on demand as they were, and anything else -- a break that
//// somehow began logged out, or a document with nothing before it -- logged
//// out. A break is a pause in a login, so every route that starts one
//// refuses an agent who is logged out (`agent_state.change`); the end still
//// never logs anybody in, because an agent the refusal did not see -- one
//// logged out between the read and the write, a break do-not-disturb
//// restored, a document written before the refusal -- must not start
//// taking callers ten minutes later without having asked to. A `*24`
//// resume is different: that is the agent saying they are back, and it
//// goes to `feature_codes.resumes_to`. The call center this
//// replaces paused an agent for ten minutes when nothing was said; here
//// nothing said is no limit, as the schema has always described it.
////
//// When it ends is stored on the agent's availability document, as
//// `break_ends` in Gregorian seconds, by the change that starts the break.
//// Every other change removes it (`availability.set_timed`), so a break
//// resumed by hand, a supervisor's change, a logout, do-not-disturb or a
//// disabled user all leave no end behind for anybody to act on.
//// Do-not-disturb keeps the break aside as `held_break`, which nothing
//// ends: clearing it puts the agent back on the break with the same end
//// and the same `previous`, and this node's timer set again
//// (`callcenter/dnd`), or, once the end has passed, where `ends_to` says.
////
//// Who ends it:
////
//// - The node that started the break, on a timer of its own, at the second
////   it ends. That is nearly always, and it is on time.
//// - The sweep, for a node that died or restarted with its timer: every
////   `reconcile_interval_s` each node reads the availabilities of the
////   accounts it dispatches, and ends any break more than `sweep_grace_s`
////   past its end. The grace is what keeps the sweep out of the way of a
////   timer that is about to fire.
//// - Behind that, the scan of the accounts of every shard a node takes, and
////   of every shard it holds each twentieth sweep: an account nobody is
////   dispatching has no sweep, and it has no caller either, so its breaks
////   are ended within the backstop -- or at the next sweep once a caller
////   arrives and a dispatcher starts for it.
////
//// However many of those fire for one break, it ends once. Every end is a
//// compare-and-set (`availability.set_if`): the document is read, the
//// break is ended only when it still says on break with the very end the
//// timer or the sweep was set for, and it is written over the revision
//// that was read. Anybody else's change in between is a conflict, the
//// document is read again, and the decision is taken again from what they
//// wrote -- which is nothing to do.
////
//// The end is the application's own change, source `system`: the status log
//// and the `agent_availability` event say so, and the login lamp shows the
//// availability the agent is back in, as for any change.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/kazoo.{type Error, type Kazoo}
import kazoo/modb

import callcenter/agents
import callcenter/availability.{type AgentAvailability, type Source}
import callcenter/system
import callcenter/types.{
  type Availability, Available, AvailableOnDemand, LoggedOut, OnBreak,
}

/// How long past its end a break has to be before the sweep ends it. The
/// node that started it is due at the end itself; the sweep is for when
/// that node is gone.
pub const sweep_grace_s = 5

/// What a break's end finds on the document.
pub type Verdict {
  /// The break is over: back to `to`.
  Over(to: Availability)
  /// It is the same break and it has not ended yet.
  Running
  /// Not the break the end was set for: the agent is not on a break, is on
  /// one with no end, or on one with another end -- a later break, taken
  /// after this one was resumed.
  NotThisBreak
}

/// Whether the break that ends at `due` is over at `now`, for an agent in
/// `state`.
pub fn verdict(state: AgentAvailability, due: Int, now: Int) -> Verdict {
  case state.availability, state.break_ends {
    OnBreak, Some(ends) if ends == due ->
      case now >= ends {
        True -> Over(ends_to(state.previous))
        False -> Running
      }
    _, _ -> NotThisBreak
  }
}

/// Where a break that runs out goes: back to what the agent was before it,
/// exactly, when that was a state they took calls in, and logged out
/// otherwise. Unlike a resume (`feature_codes.resumes_to`) nobody asked to
/// work, so nobody is logged in by it.
pub fn ends_to(previous: Option(Availability)) -> Availability {
  case previous {
    Some(Available) -> Available
    Some(AvailableOnDemand) -> AvailableOnDemand
    Some(LoggedOut) | Some(OnBreak) | None -> LoggedOut
  }
}

/// The breaks among an account's availabilities that the sweep ends: more
/// than `sweep_grace_s` past their end at `now`. Each with the end it was
/// found with, which is the break the sweep ends and no other.
pub fn overdue(
  states: List(#(String, AgentAvailability)),
  now: Int,
) -> List(#(String, Int)) {
  list.filter_map(states, fn(entry) {
    let #(agent_id, state) = entry
    case state.availability, state.break_ends {
      OnBreak, Some(ends) if now >= ends + sweep_grace_s -> Ok(#(agent_id, ends))
      _, _ -> Error(Nil)
    }
  })
}

// --- Starting one ------------------------------------------------------------

/// Change an agent's availability, and when the change is to a break of
/// `timeout_s` seconds above 0, store its end and set this node's timer for
/// it. Anything but a break ignores the timeout. An agent already on a break
/// stays on the break they are on (`availability.set_timed`); when it has an
/// end the timer is set for that end, which is one more timer for a break
/// that ends once.
pub fn set(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to to: Availability,
  source source: Source,
  timeout_s timeout_s: Int,
) -> Result(AgentAvailability, Error) {
  use state <- result.try(availability.set_timed(
    kz,
    account_id,
    agent_id,
    to: to,
    source: source,
    break_s: timeout_s,
  ))
  case to, timeout_s > 0, state.break_ends {
    OnBreak, True, Some(ends) -> arm(kz, account_id, agent_id, ends)
    _, _, _ -> Nil
  }
  Ok(state)
}

/// This node's timer for a break that ends at `ends`: a process of its own,
/// asleep until then, which ends the break if it is still the one it was set
/// for. Nothing links it to whoever set it -- the feature code's call is
/// long gone by then -- and a node that stops takes it along, which is what
/// the sweep is for.
pub fn arm(kz: Kazoo, account_id: String, agent_id: String, ends: Int) -> Nil {
  let wait_ms = int.max(ends - modb.now(), 0) * 1000
  let _timer =
    process.spawn_unlinked(fn() {
      process.sleep(wait_ms)
      let _ended = end(kz, account_id, agent_id, due: ends, now: modb.now())
      Nil
    })
  Nil
}

// --- Ending one --------------------------------------------------------------

/// End the break that ends at `due`, when it is still the agent's and it is
/// over at `now`. `Ok(None)` is nothing to end: the document says something
/// else, which is the answer every end but the first gets.
///
/// The decision is taken from the document it is written over, and a
/// conflict -- somebody else's change between the two -- is decided once
/// more from the document they wrote.
pub fn end(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  due due: Int,
  now now: Int,
) -> Result(Option(AgentAvailability), Error) {
  case attempt(kz, account_id, agent_id, due, now) {
    Error(kazoo.Conflict) -> attempt(kz, account_id, agent_id, due, now)
    answered -> answered
  }
  |> tell(account_id, agent_id)
}

fn attempt(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  due: Int,
  now: Int,
) -> Result(Option(AgentAvailability), Error) {
  availability.set_if(
    kz,
    account_id,
    agent_id,
    source: availability.System,
    decide: fn(current) {
      case verdict(current, due, now) {
        Over(to) -> return_to(kz, account_id, agent_id, to)
        Running | NotThisBreak -> Error(Nil)
      }
    },
  )
}

/// A break that is over puts the agent back to work, and that is only for a
/// user who may work (`agents.may_work`), as it is for every other route.
/// One who may not stays on the break: disabled or deleted, the
/// do-not-disturb listener and its sweep log them out and take the end away.
/// A break that ends logged out is always allowed, as a logout is.
fn return_to(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to: Availability,
) -> Result(Availability, Nil) {
  case to {
    LoggedOut -> Ok(LoggedOut)
    _working -> back_to_work(kz, account_id, agent_id, to)
  }
}

fn back_to_work(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to: Availability,
) -> Result(Availability, Nil) {
  case agents.may_work(kz, account_id, agent_id) {
    Ok(Nil) -> Ok(to)
    Error(unfit) -> {
      system.log(
        "not ending the break of agent "
        <> agent_id
        <> " of "
        <> account_id
        <> ": "
        <> agents.unfit_to_string(unfit),
      )
      Error(Nil)
    }
  }
}

fn tell(
  ended: Result(Option(AgentAvailability), Error),
  account_id: String,
  agent_id: String,
) -> Result(Option(AgentAvailability), Error) {
  case ended {
    Ok(Some(state)) ->
      system.log(
        "agent "
        <> agent_id
        <> " of "
        <> account_id
        <> " is back from their break: "
        <> availability.to_string(state.availability),
      )
    Ok(None) -> Nil
    Error(reason) ->
      system.log_error(
        "could not end the break of agent "
        <> agent_id
        <> " of "
        <> account_id
        <> ": "
        <> kazoo.error_to_string(reason),
      )
  }
  ended
}

/// End every break of an account that is overdue now: see `sweep_at`.
pub fn sweep(kz: Kazoo, account_id: String) -> List(#(String, Availability)) {
  sweep_at(kz, account_id, modb.now())
}

/// End every break of an account that is more than `sweep_grace_s` past its
/// end at `now`, off the account's availabilities view, and say whom and to
/// what. Nothing when the view cannot be read; the next sweep reads again.
pub fn sweep_at(
  kz: Kazoo,
  account_id: String,
  now: Int,
) -> List(#(String, Availability)) {
  sweep_read(kz, account_id, availability.all(kz, account_id), now)
}

/// The same, off the availabilities view as already read (`availability.
/// all`): what the do-not-disturb sweep hands on, having read it for itself
/// a moment before (`dnd.sweep`).
///
/// A row a moment old is as good as a new one here. Every end is decided
/// again from the document it is written over (`end`), so a break the row
/// still shows that has been ended or taken away since is left alone; and
/// nothing between the read and this starts a break that is overdue.
pub fn sweep_read(
  kz: Kazoo,
  account_id: String,
  states: Result(List(#(String, AgentAvailability)), Error),
  now: Int,
) -> List(#(String, Availability)) {
  case states {
    Error(_unread) -> []
    Ok(states) ->
      overdue(states, now)
      |> list.filter_map(fn(entry) {
        let #(agent_id, due) = entry
        case end(kz, account_id, agent_id, due: due, now: now) {
          Ok(Some(state)) -> Ok(#(agent_id, state.availability))
          Ok(None) | Error(_) -> Error(Nil)
        }
      })
  }
}
