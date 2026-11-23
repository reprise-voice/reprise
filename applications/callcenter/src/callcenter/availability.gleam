//// What an agent, a supervisor or an automatic rule chose: the other half
//// of requirement 1.2a, and the half that is persisted.
////
//// One document per agent, `callcenter_agent-<user_id>` in the account
//// database, holding the current value, when it changed, what changed it,
//// and the value to restore when do-not-disturb is cleared. Requirement 0.4:
//// a restart of every kazoo node at once brings agents back in the status
//// they had, never in a default status, and that is what this document is
//// for. Nothing else writes it. It also holds the agent's login lamp
//// override, `presence_id`, which `set_presence_id` writes, and the end of
//// a break that has one, `break_ends`, which every change writes: a change
//// to a break with an end sets it and every other change removes it, so the
//// end never outlives the break it belongs to (`callcenter/breaks`). The one
//// exception is do-not-disturb logging out an agent on such a break: the
//// break, its end and what it goes back to are kept as `held_break` until
//// the next change, so that clearing do-not-disturb can give the agent the
//// rest of it (`callcenter/dnd`).
////
//// Every change does four things and they are in this order on purpose:
////
//// 1. Writes the document. Until that has succeeded nothing has happened,
////    so a failed write is a failed change and the caller is told.
//// 2. Appends an `agent_status_change` document to the month database, which
////    is the status log in requirement 1.7.
//// 3. Publishes the login lamp's new state (`callcenter/presence`), as acdc
////    did through `acdc_util:presence_update/3`. Before the event, because
////    the dispatcher answers the event by putting the lamp of an agent on a
////    queue call back to `early`, and that has to land after this.
//// 4. Publishes `agent_availability`, which is what the wallboard, the
////    webhooks and the other nodes' caches read.
////
//// `set` is a call into the datastore, so it is not made from inside an
//// actor that is on the dispatch path. The dispatcher's own automatic
//// no-answer rule spawns it.

import callcenter/presence
import callcenter/records
import callcenter/system
import callcenter/types.{
  type Availability, Available, AvailableOnDemand, LoggedOut, OnBreak,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo}
import kazoo/modb

/// What changed an agent's availability.
pub type Source {
  /// A feature code on a phone.
  Phone
  /// The agent themselves, through Crossbar.
  Ui
  /// Somebody else, through Crossbar.
  Supervisor
  /// The queue's `max_no_answer` rule in the dispatcher.
  NoAnswerRule
  /// Do-not-disturb turning on or off on the user document.
  Dnd
  /// The application itself.
  System
}

/// An agent's availability as the document holds it.
pub type AgentAvailability {
  AgentAvailability(
    availability: Availability,
    /// What it was before, kept so that clearing do-not-disturb restores it.
    previous: Option(Availability),
    timestamp: Int,
    source: Source,
    /// When the break the agent is on ends by itself, in Gregorian seconds.
    /// Only ever set on a break, and only on one that was given an end.
    break_ends: Option(Int),
    /// The break with an end that do-not-disturb logged the agent out of,
    /// kept so that clearing it gives them back the rest of that break --
    /// or what the break would have ended to, once its end has passed --
    /// rather than a break with no end. Only ever set by that logout, and
    /// every other change removes it.
    held_break: Option(HeldBreak),
  )
}

/// A break with an end, held while do-not-disturb has the agent logged out.
pub type HeldBreak {
  HeldBreak(
    /// When it ends, in Gregorian seconds.
    ends: Int,
    /// What the agent was before the break, which is what its end goes back
    /// to (`breaks.ends_to`).
    before: Option(Availability),
  )
}

/// An agent nobody has ever set: logged out, from the start of time.
pub fn logged_out() -> AgentAvailability {
  AgentAvailability(
    availability: LoggedOut,
    previous: None,
    timestamp: 0,
    source: System,
    break_ends: None,
    held_break: None,
  )
}

// --- Reading ---------------------------------------------------------------

/// One agent's availability.
///
/// An agent with no document is logged out, which is the same answer as a
/// user who was never made an agent; nothing is written to say so.
pub fn get(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(AgentAvailability, Error) {
  case
    kz.datamgr.open_cache_doc(
      kazoo.account_db(account_id),
      records.agent_document_id(agent_id),
    )
  {
    Ok(document) -> Ok(decode(document))
    Error(kazoo.NotFound) -> Ok(logged_out())
    Error(reason) -> Error(reason)
  }
}

/// One agent's availability and their counters, which is what the dispatcher
/// builds an `AgentView` from and what `cb_agents` lists.
pub fn get_with_counters(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(#(AgentAvailability, records.Counters), Error) {
  find_with_counters(kz, account_id, agent_id)
  |> result.map(option.unwrap(_, #(logged_out(), records.no_counters())))
}

/// The same, saying `None` for an agent with no document -- one who never
/// logged in -- rather than answering it as logged out.
///
/// The difference is the cost of the next read. A document that exists is
/// held by the data layer's document cache, emptied when it changes, so
/// reading it again reads memory; one that does not exist is not cached, and
/// every read of it goes to the database. The dispatcher, which reads every
/// idle agent of a queue with somebody waiting on every pass, remembers the
/// `None` instead (`dispatcher/view`).
pub fn find_with_counters(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(Option(#(AgentAvailability, records.Counters)), Error) {
  case
    kz.datamgr.open_cache_doc(
      kazoo.account_db(account_id),
      records.agent_document_id(agent_id),
    )
  {
    Ok(document) -> Ok(Some(#(decode(document), records.counters(document))))
    Error(kazoo.NotFound) -> Ok(None)
    Error(reason) -> Error(reason)
  }
}

/// Every agent of an account who has a document, through the account view.
pub fn all(
  kz: Kazoo,
  account_id: String,
) -> Result(List(#(String, AgentAvailability)), Error) {
  kz.datamgr.get_results(
    kazoo.account_db(account_id),
    "callcenter/agents",
    kazoo.view_options(),
  )
  |> result.map(fn(rows) { list.filter_map(rows, row) })
}

fn row(row: Value) -> Result(#(String, AgentAvailability), Nil) {
  case doc.get_string(row, ["key"]) {
    Ok("") -> Error(Nil)
    Ok(agent_id) ->
      case doc.get(row, ["value"]) {
        Ok(value) -> Ok(#(agent_id, decode(value)))
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

/// The document as an availability.
pub fn decode(document: Value) -> AgentAvailability {
  AgentAvailability(
    availability: from_string(
      doc.get_string(document, ["availability"]) |> result.unwrap("logged_out"),
    ),
    previous: doc.get_string(document, ["previous"])
      |> option.from_result
      |> option.map(from_string),
    timestamp: doc.get_int(document, ["timestamp"]) |> result.unwrap(0),
    source: source_from_string(
      doc.get_string(document, ["source"]) |> result.unwrap("system"),
    ),
    break_ends: doc.get_int(document, ["break_ends"]) |> option.from_result,
    held_break: case doc.get_int(document, ["held_break", "ends"]) {
      Ok(ends) ->
        Some(HeldBreak(
          ends: ends,
          before: doc.get_string(document, ["held_break", "before"])
            |> option.from_result
            |> option.map(from_string),
        ))
      Error(Nil) -> None
    },
  )
}

// --- Writing ---------------------------------------------------------------

/// Set an agent's availability, and tell everything that has to hear about
/// it.
///
/// Setting it to what it already is is not a change: the document is left
/// alone, no status-change record is written and nothing is published. It
/// still answers with the current value, so a caller that sets it twice --
/// two nodes acting on one feature code, requirement 0.6 -- gets the same
/// answer both times.
///
/// A change made here has no break end: a break taken through it lasts until
/// something ends it, and any other change removes the end of the break the
/// agent was on.
pub fn set(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to to: Availability,
  source source: Source,
) -> Result(AgentAvailability, Error) {
  set_timed(kz, account_id, agent_id, to: to, source: source, break_s: 0)
}

/// `set`, with the length of the break when the change is to one: a break
/// of `break_s` seconds above 0 ends that long after the change, and the end
/// is stored on the document, as `break_ends`, so that whichever node is
/// alive then can end it (`callcenter/breaks`). Ignored for anything but a
/// break. An agent already on a break keeps the break they are on, end and
/// all: setting it again is not a change.
pub fn set_timed(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  to to: Availability,
  source source: Source,
  break_s break_s: Int,
) -> Result(AgentAvailability, Error) {
  use current <- result.try(get(kz, account_id, agent_id))
  case current.availability == to {
    True -> Ok(current)
    False -> {
      // Written over the document as it is now, whatever the cache said:
      // the decision above is the cache's, the write is last-writer-wins.
      let base = case
        kz.datamgr.open_doc(
          kazoo.account_db(account_id),
          records.agent_document_id(agent_id),
        )
      {
        Ok(document) -> document
        Error(_missing) -> doc.object([])
      }
      apply(kz, account_id, agent_id, base, current, to, source, break_s)
    }
  }
}

/// Change the availability when `decide`, given the document as it is in the
/// database now, says what to -- and only over that revision of it.
///
/// This is how a rule that fires on a timer changes somebody: the decision
/// is taken from the document it overwrites, so a change that lands between
/// the read and the write is a `Conflict` and nothing is written, and two
/// nodes firing the same rule write once between them. `Ok(None)` is
/// `decide` saying nothing is to change, or naming what the agent already
/// is. The change has no break end.
pub fn set_if(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  source source: Source,
  decide decide: fn(AgentAvailability) -> Result(Availability, Nil),
) -> Result(Option(AgentAvailability), Error) {
  use existing <- result.try(
    case
      kz.datamgr.open_doc(
        kazoo.account_db(account_id),
        records.agent_document_id(agent_id),
      )
    {
      Ok(document) -> Ok(Some(document))
      Error(kazoo.NotFound) -> Ok(None)
      Error(reason) -> Error(reason)
    },
  )
  let current = option.map(existing, decode) |> option.unwrap(logged_out())
  case decide(current) {
    Error(Nil) -> Ok(None)
    Ok(to) if to == current.availability -> Ok(None)
    Ok(to) ->
      apply(
        kz,
        account_id,
        agent_id,
        option.unwrap(existing, doc.object([])),
        current,
        to,
        source,
        0,
      )
      |> result.map(Some)
  }
}

/// Write the change over `base`, the document as it was read, and tell
/// everybody. `base` carries its revision, so a document somebody else wrote
/// since is a `Conflict` and nothing else happens.
fn apply(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  base: Value,
  current: AgentAvailability,
  to: Availability,
  source: Source,
  break_s: Int,
) -> Result(AgentAvailability, Error) {
  let at = modb.now()
  let changed =
    AgentAvailability(
      availability: to,
      previous: Some(current.availability),
      timestamp: at,
      source: source,
      break_ends: case to, break_s > 0 {
        OnBreak, True -> Some(at + break_s)
        _, _ -> None
      },
      held_break: held(current, to, source),
    )
  write(kz, account_id, agent_id, base, current, changed)
}

/// The break a change holds: the one with an end that do-not-disturb logs
/// the agent out of. The logout takes the end off the document, as every
/// change but a break's own does, and the break is otherwise lost: restored
/// as a break with no end, and the agent on it until somebody noticed.
fn held(
  current: AgentAvailability,
  to: Availability,
  source: Source,
) -> Option(HeldBreak) {
  case source, to, current.availability, current.break_ends {
    Dnd, LoggedOut, OnBreak, Some(ends) ->
      Some(HeldBreak(ends: ends, before: current.previous))
    _, _, _, _ -> None
  }
}

fn write(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  base: Value,
  current: AgentAvailability,
  changed: AgentAvailability,
) -> Result(AgentAvailability, Error) {
  use _saved <- result.try(save(kz, account_id, agent_id, base, changed))
  let to = changed.availability
  records.status_change(
    account_id,
    agent_id,
    Some(to_string(current.availability)),
    to_string(to),
    source_to_string(changed.source),
    changed.timestamp,
  )
  case starts_a_new_login(current.availability, to) {
    True -> records.reset_counters(account_id, agent_id)
    False -> Nil
  }
  presence(kz, account_id, agent_id, to)
  publish(account_id, agent_id, changed)
  Ok(changed)
}

/// Put an agent back on the break do-not-disturb held: on a break again,
/// ending at `ends` as it was going to, and going back to `then` when it
/// does -- stored as `previous`, which is what a break's end reads -- rather
/// than to the logout it is restored from. An agent already on a break keeps
/// the break they are on, as `set_timed` does. Arming the timer for the end
/// is the caller's (`breaks.arm`).
pub fn resume_break(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  ends ends: Int,
  then then: Availability,
  source source: Source,
) -> Result(AgentAvailability, Error) {
  use current <- result.try(get(kz, account_id, agent_id))
  case current.availability {
    OnBreak -> Ok(current)
    _ -> {
      let base = case
        kz.datamgr.open_doc(
          kazoo.account_db(account_id),
          records.agent_document_id(agent_id),
        )
      {
        Ok(document) -> document
        Error(_missing) -> doc.object([])
      }
      write(
        kz,
        account_id,
        agent_id,
        base,
        current,
        AgentAvailability(
          availability: OnBreak,
          previous: Some(then),
          timestamp: modb.now(),
          source: source,
          break_ends: Some(ends),
          held_break: None,
        ),
      )
    }
  }
}

/// Make a logout do-not-disturb made the application's own: source
/// `system`, and `logged_out` before it, so that nothing is left to put the
/// agent back to. What a user being disabled calls for when they are
/// already logged out: a logout do-not-disturb made is otherwise undone
/// when it is cleared, however long after and whatever happened in between
/// -- the user disabled and enabled again included.
///
/// `Ok(True)` when it was written, `Ok(False)` when the agent is not logged
/// out by do-not-disturb. Written over the revision read, and decided once
/// more from the document a conflict brings. The availability does not
/// change, so there is no status change to log and nothing to publish.
pub fn disown_logout(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(Bool, Error) {
  case disown_attempt(kz, account_id, agent_id) {
    Error(kazoo.Conflict) -> disown_attempt(kz, account_id, agent_id)
    written -> written
  }
}

fn disown_attempt(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
) -> Result(Bool, Error) {
  case
    kz.datamgr.open_doc(
      kazoo.account_db(account_id),
      records.agent_document_id(agent_id),
    )
  {
    Error(kazoo.NotFound) -> Ok(False)
    Error(reason) -> Error(reason)
    Ok(document) -> {
      let current = decode(document)
      case current.availability, current.source {
        LoggedOut, Dnd ->
          save(
            kz,
            account_id,
            agent_id,
            document,
            AgentAvailability(
              ..current,
              source: System,
              previous: Some(LoggedOut),
              held_break: None,
            ),
          )
          |> result.replace(True)
        _, _ -> Ok(False)
      }
    }
  }
}

/// Point the agent's login lamp at `presence_id`: what a feature code's node
/// names, stored so that every later change publishes there too.
///
/// Answers whether it moved. Storing what is already stored is nothing. A
/// move turns the lamp at the old address off and shows the agent's current
/// state at the new one, so neither is left showing something stale when the
/// feature code that moved it changes nothing else.
pub fn set_presence_id(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  presence_id: String,
) -> Result(Bool, Error) {
  let db = kazoo.account_db(account_id)
  let doc_id = records.agent_document_id(agent_id)
  let existing = case kz.datamgr.open_doc(db, doc_id) {
    Ok(document) -> Some(document)
    Error(_missing) -> None
  }
  let current = option.map(existing, decode) |> option.unwrap(logged_out())
  case option.then(existing, presence.stored) == Some(presence_id) {
    True -> Ok(False)
    False -> {
      let was = presence.address(kz, account_id, agent_id)
      use _saved <- result.try(kz.datamgr.save_doc(
        db,
        option.unwrap(existing, doc.object([]))
          |> doc.set(["_id"], doc.String(doc_id))
          |> doc.set(["pvt_type"], doc.String(records.agent_type))
          |> doc.set(["pvt_account_id"], doc.String(account_id))
          |> doc.set(["agent_id"], doc.String(agent_id))
          |> doc.set(["presence_id"], doc.String(presence_id)),
      ))
      let now = presence.address(kz, account_id, agent_id)
      case was, now {
        Ok(old), Ok(new) if old != new -> {
          let _ = presence.send(presence.update(old, presence.terminated))
          Nil
        }
        _, _ -> Nil
      }
      presence(kz, account_id, agent_id, current.availability)
      Ok(True)
    }
  }
}

fn save(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  base: Value,
  availability: AgentAvailability,
) -> Result(Value, Error) {
  let doc_id = records.agent_document_id(agent_id)
  kz.datamgr.save_doc(
    kazoo.account_db(account_id),
    base
      |> doc.set(["_id"], doc.String(doc_id))
      |> doc.set(["pvt_type"], doc.String(records.agent_type))
      |> doc.set(["pvt_account_id"], doc.String(account_id))
      |> doc.set(["agent_id"], doc.String(agent_id))
      |> doc.set(
        ["availability"],
        doc.String(to_string(availability.availability)),
      )
      |> doc.set(["timestamp"], doc.Int(availability.timestamp))
      |> doc.set(["source"], doc.String(source_to_string(availability.source)))
      |> set_previous(availability.previous)
      |> set_break_ends(availability.break_ends)
      |> set_held_break(availability.held_break),
  )
}

fn set_held_break(document: Value, held: Option(HeldBreak)) -> Value {
  case held {
    None -> doc.delete(document, ["held_break"])
    Some(HeldBreak(ends, before)) ->
      doc.set(
        document,
        ["held_break"],
        doc.object_some([
          #("ends", Some(doc.Int(ends))),
          #("before", option.map(before, fn(b) { doc.String(to_string(b)) })),
        ]),
      )
  }
}

fn set_break_ends(document: Value, break_ends: Option(Int)) -> Value {
  case break_ends {
    None -> doc.delete(document, ["break_ends"])
    Some(at) -> doc.set(document, ["break_ends"], doc.Int(at))
  }
}

fn set_previous(document: Value, previous: Option(Availability)) -> Value {
  case previous {
    None -> document
    Some(previous) ->
      doc.set(document, ["previous"], doc.String(to_string(previous)))
  }
}

fn publish(
  account_id: String,
  agent_id: String,
  availability: AgentAvailability,
) -> Nil {
  system.publish(
    "agent_availability",
    doc.object_some([
      #("Account-ID", Some(doc.String(account_id))),
      #("Agent-ID", Some(doc.String(agent_id))),
      #("Availability", Some(doc.String(to_string(availability.availability)))),
      #(
        "Previous",
        option.map(availability.previous, fn(previous) {
          doc.String(to_string(previous))
        }),
      ),
      #("Source", Some(doc.String(source_to_string(availability.source)))),
      #("Timestamp", Some(doc.Int(availability.timestamp))),
      #("Break-Ends", option.map(availability.break_ends, doc.Int)),
    ]),
  )
}

// --- Presence --------------------------------------------------------------

/// Show an availability on the agent's login lamp. Not being on a queue call
/// is assumed: the dispatcher, which knows better, corrects it. What the
/// state is, and where it is addressed, is `callcenter/presence`.
pub fn presence(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  availability: Availability,
) -> Nil {
  case
    presence.publish(
      kz,
      account_id,
      agent_id,
      presence.state(availability, on_queue_call: False),
    )
  {
    Ok(_update) -> Nil
    Error(presence.NoRealm) ->
      system.log_error(
        "no realm for account " <> account_id <> ": no presence update",
      )
    // Said at info by `presence.publish`, or not an agent at all.
    Error(presence.NoPresenceId) | Error(presence.NotAnAgent) -> Nil
  }
}

// --- The wire names --------------------------------------------------------

/// The `Availability` values `kapi_callcenter` and the schemas validate.
pub fn to_string(availability: Availability) -> String {
  case availability {
    LoggedOut -> "logged_out"
    Available -> "available"
    AvailableOnDemand -> "available_on_demand"
    OnBreak -> "on_break"
  }
}

/// A wire name back to the availability, and logged out for one this
/// release does not know: a value from a newer release is not a crash in a
/// listener, and an agent nobody can read is not taking calls.
pub fn from_string(name: String) -> Availability {
  parse(name) |> result.unwrap(LoggedOut)
}

/// A wire name back to the availability, refusing one this release does not
/// know, for the API that has to say so.
pub fn parse(name: String) -> Result(Availability, Nil) {
  case name {
    "logged_out" -> Ok(LoggedOut)
    "available" -> Ok(Available)
    "available_on_demand" -> Ok(AvailableOnDemand)
    "on_break" -> Ok(OnBreak)
    _ -> Error(Nil)
  }
}

/// Whether an agent in this availability is working at all, which is what
/// the login metrics mean. The login lamp is not this: it goes out for a
/// break too (`presence.state`).
pub fn logged_in(availability: Availability) -> Bool {
  availability != LoggedOut
}

/// Whether a change is the start of a shift.
///
/// Every counter on the document is "since login" -- calls answered, talk
/// time, offers missed -- so this is where they go back to zero. A resume
/// from a break is not a login: the break paused a login and the numbers
/// from before it are the same shift's. Logging out leaves them where they
/// are, so the shift just ended can still be read off the document.
pub fn starts_a_new_login(from: Availability, to: Availability) -> Bool {
  !logged_in(from) && logged_in(to)
}

/// Whether an agent in this availability is there to be rung.
///
/// Logged in and not on a break: the whole of "this agent has said they are
/// taking callers". The dispatcher asks it twice -- before it offers anybody,
/// and again when an offer comes back unanswered, because a phone that rang
/// out after the agent stepped away was not a caller anybody missed.
pub fn taking_calls(availability: Availability) -> Bool {
  logged_in(availability) && availability != OnBreak
}

pub fn source_to_string(source: Source) -> String {
  case source {
    Phone -> "phone"
    Ui -> "ui"
    Supervisor -> "supervisor"
    NoAnswerRule -> "no_answer"
    Dnd -> "dnd"
    System -> "system"
  }
}

/// A wire name back to the source, and `system` for one this release does
/// not know.
pub fn source_from_string(name: String) -> Source {
  parse_source(name) |> result.unwrap(System)
}

/// A wire name back to the source, refusing one this release does not know.
pub fn parse_source(name: String) -> Result(Source, Nil) {
  case name {
    "phone" -> Ok(Phone)
    "ui" -> Ok(Ui)
    "supervisor" -> Ok(Supervisor)
    "no_answer" -> Ok(NoAnswerRule)
    "dnd" -> Ok(Dnd)
    "system" -> Ok(System)
    _ -> Error(Nil)
  }
}
