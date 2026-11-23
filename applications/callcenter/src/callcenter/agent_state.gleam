//// What an agent is, asked in one place.
////
//// Availability is chosen and persisted; activity is derived from the
//// channels the agent's phones are on. Both belong to the core worker, and
//// everything that reads or changes them -- the agent API, the queue status
//// view, the feature codes, the do-not-disturb hook -- goes through here
//// rather than naming those modules, so that the two imports below are the
//// whole of the seam.
////
//// The wire spellings of the three enumerations are asked for here as well,
//// because the API, the events and the documents all have to agree on them;
//// `availability` and `activity` own them.

import gleam/option.{type Option, None}
import gleam/result
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}

import callcenter/activity
import callcenter/agents
import callcenter/availability
import callcenter/breaks
import callcenter/records
import callcenter/types.{type Activity, type Availability, LoggedOut, OnBreak}

/// An agent's availability as it stands, with what it was before and what
/// changed it.
pub type AgentAvailability =
  availability.AgentAvailability

/// What made a change.
pub type Source =
  availability.Source

pub const phone: Source = availability.Phone

pub const ui: Source = availability.Ui

pub const supervisor: Source = availability.Supervisor

pub const no_answer_rule: Source = availability.NoAnswerRule

pub const dnd: Source = availability.Dnd

pub const system: Source = availability.System

/// One availability, built rather than read. The record is the core
/// worker's, so this is where anything else makes one.
pub fn state(
  availability availability: Availability,
  previous previous: Option(Availability),
  timestamp timestamp: Int,
  source source: Source,
) -> AgentAvailability {
  availability.AgentAvailability(
    availability: availability,
    previous: previous,
    timestamp: timestamp,
    source: source,
    break_ends: None,
    held_break: None,
  )
}

/// The agent's availability now.
pub fn get(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(AgentAvailability, Error) {
  availability.get(kz, account_id, agent_id)
}

/// Change it. The only writer of the availability document, wherever the
/// change came from.
pub fn set(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to to: Availability,
  source source: Source,
) -> Result(AgentAvailability, Error) {
  availability.set(kz, account_id, agent_id, to, source)
}

/// Why a change a person asked for was not made.
pub type Refused {
  /// The user may not start working (`agents.fit_to_work`).
  Unfit(agents.Unfit)
  /// A break for an agent who is logged out: a break is a pause in a login,
  /// and there is none to pause.
  NotLoggedIn
  /// The write itself failed.
  Failed(Error)
}

/// Whether the agent may be changed to `to`: always to logged out, and to
/// anything else only while they are a user who is there, not deleted and
/// enabled (`agents.fit_to_work`).
pub fn may_become(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to: Availability,
) -> Result(Nil, agents.Unfit) {
  case to {
    LoggedOut -> Ok(Nil)
    _working -> agents.may_work(kz, account_id, agent_id)
  }
}

/// Change it as a person asked to -- a feature code, the API, an operator --
/// with the length of the break when the change is to one: `break_s`
/// seconds, and 0 for a break with no end (`callcenter/breaks`).
///
/// Every such route comes through here, so they all refuse alike: nobody is
/// logged in or put on a break who is not a user that is there, not deleted
/// and enabled (`may_become`), and nothing is written for them. Logging out
/// is never refused. Nor is anybody put on a break who is logged out
/// (`NotLoggedIn`), as `*24` has always refused: the break's end goes back to
/// what came before, and that would be logged out anyway. The application's
/// own changes -- do-not-disturb, a disabled or deleted user, the no-answer
/// rule -- use `set`, and decide for themselves.
pub fn change(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to to: Availability,
  source source: Source,
  break_s break_s: Int,
) -> Result(AgentAvailability, Refused) {
  use Nil <- result.try(
    may_become(kz, account_id, agent_id, to) |> result.map_error(Unfit),
  )
  use Nil <- result.try(case to {
    OnBreak ->
      case get(kz, account_id, agent_id) {
        Ok(current) if current.availability == LoggedOut -> Error(NotLoggedIn)
        Ok(_) -> Ok(Nil)
        Error(reason) -> Error(Failed(reason))
      }
    _ -> Ok(Nil)
  })
  breaks.set(
    kz,
    account_id,
    agent_id,
    to: to,
    source: source,
    timeout_s: break_s,
  )
  |> result.map_error(Failed)
}

/// What a refusal says, for a log line and an operator.
pub fn refused_to_string(refused: Refused) -> String {
  case refused {
    Unfit(unfit) -> agents.unfit_to_string(unfit)
    NotLoggedIn -> "logged out: a break is only for an agent who is logged in"
    Failed(reason) -> kazoo.error_to_string(reason)
  }
}

/// Point the agent's login lamp at a presence id, remembered for every
/// later change. Answers whether it moved.
pub fn set_presence_id(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  presence_id: String,
) -> Result(Bool, Error) {
  availability.set_presence_id(kz, account_id, agent_id, presence_id)
}

/// The counters kept since the agent last logged in.
pub fn counters(kz: Kazoo, account_id: String, agent_id: String) -> Value {
  case availability.get_with_counters(kz, account_id, agent_id) {
    Ok(#(_state, counters)) -> records.counters_to_value(counters)
    Error(_) -> records.counters_to_value(records.counters(doc.Null))
  }
}

/// What the agent's phones are doing, as this node sees it.
pub fn activity_of(account_id: String, agent_id: String) -> Activity {
  activity.of(account_id, agent_id)
}

/// The same for every agent of the account this node knows about.
pub fn activities(account_id: String) -> List(#(String, Activity)) {
  activity.agents(account_id)
}

/// The availability of an agent, and `logged_out` for one the datastore
/// could not answer for. A listing of fifty agents must not fail because one
/// document is unreadable.
pub fn availability_of(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Availability {
  case get(kz, account_id, agent_id) {
    Ok(state) -> state.availability
    Error(_) -> LoggedOut
  }
}

//
// The wire spellings, which are `availability`'s and `activity`'s own.
//

pub fn availability_to_string(availability: Availability) -> String {
  availability.to_string(availability)
}

pub fn availability_from_string(name: String) -> Result(Availability, Nil) {
  availability.parse(name)
}

/// Whether the agent counts as logged in, which is what the login toggle
/// reads.
pub fn is_logged_in(availability: Availability) -> Bool {
  availability.logged_in(availability)
}

pub fn activity_to_string(activity: Activity) -> String {
  activity.to_string(activity)
}

pub fn source_to_string(source: Source) -> String {
  availability.source_to_string(source)
}

pub fn source_from_string(name: String) -> Result(Source, Nil) {
  availability.parse_source(name)
}
