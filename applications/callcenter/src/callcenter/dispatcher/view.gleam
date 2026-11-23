//// An agent as a queue's strategy sees them: their availability, this
//// node's derived activity, their tier, their counters, and the queue's own
//// read-only tier state, requirement 1.3.

import callcenter/activity.{type Reading}
import callcenter/availability
import callcenter/dispatcher/memo
import callcenter/dispatcher/plan
import callcenter/dispatcher/settings.{type QueueSettings, QueueSettings}
import callcenter/dispatcher/state.{
  type State, Read, State, Synced, Syncing, Unread, offer_of,
}
import callcenter/dispatcher/worked
import callcenter/records
import callcenter/system
import callcenter/tiers
import callcenter/types.{
  type Activity, type AgentView, ActiveInbound, AgentView, Idle, LoggedOut,
  NoAnswer, Offering, OnCall, Ready, Ringing, Standby, WrappingUp,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set

/// What a pass reads once: every queue with somebody waiting, given as its
/// settings, and every agent of theirs.
///
/// The tier states come first, from the dispatcher's own memory and the
/// activity the pass read, and only an agent who is ready in the queue has
/// their availability read to see whether they could take a caller
/// (`ready`). A queue with somebody who could has the rest of its agents
/// read as well, for the strategy to see; a queue with nobody is offered
/// nobody and needs no views. Each agent is read at most once, however many
/// queues they are in -- not once for every caller of every queue, which on
/// a large account was the whole cost of a pass.
///
/// An agent found to have no availability document is remembered for
/// `no_document_s`, which is what the state handed back carries.
pub fn snapshot(
  state: State,
  queues: List(QueueSettings),
  now: Int,
) -> #(State, plan.Snapshot) {
  let #(read, built) =
    list.map_fold(queues, dict.new(), fn(read, settings) {
      let #(read, states, ready, unread) = ready(state, now, read, settings)
      let settings = QueueSettings(..settings, agents_unread: unread)
      let #(read, views) = case ready {
        [] -> #(read, [])
        _somebody ->
          list.map_fold(states, read, fn(read, tier) {
            let #(tier, tier_state) = tier
            let #(read, #(agent, _came)) =
              read_once(state, now, read, tier.agent_id)
            #(read, of(state, tier, tier_state, agent))
          })
      }
      let selectable = set.from_list(ready)
      #(
        read,
        #(
          settings.id,
          plan.Queue(
            settings: settings,
            shown: memo.queue_state(state, settings),
            views: views,
            ready: ready,
            selectable: selectable,
            free: set.size(selectable),
          ),
        ),
      )
    })
  #(
    State(..state, no_document: remembered(state.no_document, read, now)),
    plan.Snapshot(now: now, queues: dict.from_list(built), offered: set.new()),
  )
}

/// How long an agent found to have no availability document is taken to
/// have none without being read again, in seconds.
///
/// An agent who never logged in has no document, and the data layer caches
/// no answer for a document that does not exist: read on every pass, every
/// such agent idle in a queue with a caller waiting was a database read a
/// second. After hours, with a few callers waiting and a few hundred agents
/// who never logged in, that was a few hundred reads a second for nothing.
/// So the answer is remembered. A login is an `agent_availability` event,
/// which this dispatcher listens for, and hearing one about the agent --
/// or one about nobody it can name -- forgets it at once (`heard`); this is
/// how long a login whose event was lost goes unnoticed, and how often an
/// agent nobody logs in is read.
///
/// Only a missing document is remembered. One that exists, logged out or
/// not, is read from the data layer's cache, which is emptied when the
/// document changes; remembering it here as well would keep a login out
/// for as long as the copy was kept, whether the event came or not.
pub const no_document_s = 30

type Agent =
  #(availability.AgentAvailability, records.Counters)

/// How the pass came by an agent's availability.
type Came {
  /// Read, and there is a document.
  Answered
  /// Read, and there is no document.
  NoDocument
  /// Not read: the agent was found to have no document within the last
  /// `no_document_s`.
  Remembered
  /// The read failed. Nothing is known: the agent is offered nothing, and
  /// is counted neither available nor not (`ready`). Not remembered either.
  Failed
}

type Agents =
  Dict(String, #(Agent, Came))

/// The agents found to have no document, as this pass leaves them: a new
/// finding for `no_document_s` from now, an agent found to have one after
/// all forgotten, and every finding past its time dropped.
fn remembered(
  no_document: Dict(String, Int),
  read: Agents,
  now: Int,
) -> Dict(String, Int) {
  dict.fold(
    read,
    dict.filter(no_document, fn(_agent_id, until) { until > now }),
    fn(no_document, agent_id, entry) {
      case entry.1 {
        NoDocument -> dict.insert(no_document, agent_id, now + no_document_s)
        Answered -> dict.delete(no_document, agent_id)
        Remembered | Failed -> no_document
      }
    },
  )
}

/// An `agent_availability` event about the agent was heard. If they were
/// remembered as having no document, they are not any more: the event is
/// most likely their first login, and the next pass reads them.
pub fn heard(state: State, agent_id: String) -> State {
  State(..state, no_document: dict.delete(state.no_document, agent_id))
}

/// An `agent_availability` event naming nobody this dispatcher could read:
/// everybody is read again.
pub fn heard_somebody(state: State) -> State {
  State(..state, no_document: dict.new())
}

/// The queue's tiers, each with the queue's tier state for its agent, and
/// the agent of every tier who could take a caller now: their tier state is
/// `Ready` and their availability says they are taking calls. Once per tier,
/// in the tier order.
///
/// This is the one rule for who could: the pass offers from it and counts
/// `Agents-Available` from it (`plan.available`), and `available_count`
/// counts it for a question asked between passes. Only an agent whose tier
/// state is `Ready` is read.
///
/// The last of the four is whether one of those could not be read: they
/// are not among the ready, and not known not to be either, so the count is
/// not the queue's (`settings.vouched`).
fn ready(
  state: State,
  now: Int,
  read: Agents,
  settings: QueueSettings,
) -> #(Agents, List(#(tiers.Tier, types.TierState)), List(String), Bool) {
  let states =
    list.map(settings.tiers, fn(tier) {
      #(tier, tier_state(state, tier.agent_id, settings))
    })
  let #(read, ready, unread) =
    list.fold(states, #(read, [], False), fn(acc, tier) {
      case tier {
        #(tier, Ready) -> {
          let #(read, ready, unread) = acc
          let #(read, #(#(current, _counters), came)) =
            read_once(state, now, read, tier.agent_id)
          case came, availability.taking_calls(current.availability) {
            Failed, _ -> #(read, ready, True)
            _, True -> #(read, [tier.agent_id, ..ready], unread)
            _, False -> #(read, ready, unread)
          }
        }
        _not_ready -> acc
      }
    })
  #(read, states, list.reverse(ready), unread)
}

/// An agent as the pass reads them, once however many tiers they have, and
/// how the pass came by them: `agent_state`, except that an agent
/// remembered as having no document is logged out without asking the
/// database again (`no_document_s`).
fn read_once(
  state: State,
  now: Int,
  read: Agents,
  agent_id: String,
) -> #(Agents, #(Agent, Came)) {
  case dict.get(read, agent_id) {
    Ok(entry) -> #(read, entry)
    Error(Nil) -> {
      let entry = case dict.get(state.no_document, agent_id) {
        Ok(until) if until > now -> #(nobody(), Remembered)
        _unknown_or_over ->
          case find(state, agent_id) {
            Ok(Some(agent)) -> #(agent, Answered)
            Ok(None) -> #(nobody(), NoDocument)
            Error(Nil) -> #(nobody(), Failed)
          }
      }
      #(dict.insert(read, agent_id, entry), entry)
    }
  }
}

/// One tier's agent as the pass began: their availability and counters as
/// read, the queue's tier state for them, and what this dispatcher has seen
/// them do.
fn of(
  state: State,
  tier: tiers.Tier,
  tier_state: types.TierState,
  agent: #(availability.AgentAvailability, records.Counters),
) -> AgentView {
  let #(current, counters) = agent
  // The document's counters, overlaid with what this dispatcher has seen
  // itself and the document may not show yet: `callcenter/dispatcher/worked`.
  let seen = worked.of(state, tier.agent_id)
  AgentView(
    agent_id: tier.agent_id,
    availability: current.availability,
    activity: activity_shown(state, tier.agent_id),
    level: tier.level,
    position: tier.position,
    tier_state: tier_state,
    last_call_end: counters.last_call_end,
    free_since: worked.free_since(seen, current, counters),
    answered: worked.answered(seen, counters),
    talk_time_s: worked.talk_time_s(seen, counters),
    missed: counters.missed,
  )
}

/// This queue's own view of an agent, requirement 1.3's read-only tier
/// state.
pub fn tier_state(
  state: State,
  agent_id: String,
  settings: QueueSettings,
) -> types.TierState {
  // An entry naming an offer since replaced holds nobody: counting it would
  // keep the agent Offering for good.
  case result.is_ok(offer_of(state, agent_id)) {
    True -> Offering
    False ->
      case dict.has_key(state.wrapup, agent_id) {
        True -> Standby
        False ->
          case
            dict.has_key(state.delayed, agent_id)
            || dict.has_key(state.stood_down, agent_id)
          {
            // A delay after a miss and the automatic no-answer rule are the
            // same thing to a strategy: not now.
            True -> NoAnswer
            False ->
              case activity_of(state, agent_id) {
                Ok(OnCall(queue_call: True)) -> ActiveInbound
                Ok(OnCall(queue_call: False)) ->
                  case settings.skip_external_calls {
                    True -> ActiveInbound
                    False -> Ready
                  }
                Ok(Ringing) -> Offering
                Ok(WrappingUp) -> Standby
                Ok(Idle) -> Ready
                // Nobody could say what their phones are doing: not now.
                Error(Nil) -> Standby
              }
          }
      }
  }
}

/// What the agent's phones are doing, as the pass's own reading says:
/// `Error(Nil)` when the activity actor did not answer it.
pub fn activity_of(state: State, agent_id: String) -> Result(Activity, Nil) {
  case state.activities {
    Read(activities) ->
      Ok(dict.get(activities, agent_id) |> result.unwrap(Idle))
    Unread -> Error(Nil)
  }
}

/// The same, for a screen: an activity nobody could read shows as idle,
/// beside the tier state that says the agent is not being offered anything.
pub fn activity_shown(state: State, agent_id: String) -> Activity {
  activity_of(state, agent_id) |> result.unwrap(Idle)
}

/// How long a dispatcher that has just watched its account waits for the
/// switches' first answer before it offers anybody on the events alone.
///
/// The answer normally takes the two seconds the channel query waits for
/// every `ecallmgr`. A query that failed outright never answers at all, and
/// a caller must not wait on that for ever: past this the dispatcher says
/// so and goes ahead.
pub const sync_ceiling_s = 5

/// Ask the activity actor about the whole account, once.
///
/// This is the only place a dispatcher asks it anything, and it is once a
/// pass and not once an agent a caller: the actor is one per node, every
/// dispatcher on the node asks it, and a pass over ten callers and fifty
/// agents was five hundred round trips to it. An actor that did not answer
/// is logged the first time and not again until it has answered, and until
/// it does nobody is ready (`tier_state`).
pub fn read_activity(state: State) -> State {
  case state.config.activity(), state.activities {
    Ok(reading), Unread -> {
      system.log(
        "dispatcher for account "
        <> state.config.account_id
        <> " has the agents' activity again",
      )
      State(..state, activities: Read(reading.activities))
      |> synced(reading)
    }
    Ok(reading), Read(_) ->
      State(..state, activities: Read(reading.activities))
      |> synced(reading)
    Error(reason), Read(_) -> {
      system.log_error(
        "dispatcher for account "
        <> state.config.account_id
        <> " could not read the agents' activity, offering nobody until it can: "
        <> reason,
      )
      State(..state, activities: Unread)
    }
    Error(_reason), Unread -> state
  }
}

/// Whether this pass may offer anybody: the account's activity has been
/// synced with the switches, or waited for as long as it is going to be.
pub fn believed(state: State) -> Bool {
  state.sync == Synced
}

/// Whether the dispatcher can say how many agents could take a caller.
///
/// Not while the activity actor has not answered: every tier state is
/// `Standby` then, which counts nobody, and a count of nobody sent out as
/// `Agents-Available` starts every caller's no-agent clock and turns away a
/// caller arriving at a queue that does not let them in empty -- on a
/// question nobody answered. Nor while the account is waiting for the
/// switches' first answer, when the count is made from the channel events
/// alone and an agent on a personal call counts as free. A number that is
/// not known is not said: `member_position` and `status_resp` leave
/// `Agents-Available` out, which their readers take as "not said" and never
/// as zero, and `queue_stats` is not sent. Nobody is offered meanwhile
/// either (`believed`, `tier_state`).
pub fn vouched(state: State) -> Bool {
  case state.activities {
    Unread -> False
    Read(_) -> believed(state)
  }
}

/// A dispatcher that has just taken its account watches it asynchronously,
/// and the activity actor starts the account with an empty table: the
/// switches' answer comes up to two seconds later. Offered in between, a
/// caller redelivered from a node that died goes to an agent on a personal
/// call, or still talking to the caller that node connected. So until the
/// first answer -- whole or not: one a slow switch missed only adds -- the
/// dispatcher offers nobody, for at most `sync_ceiling_s`.
///
/// The same holds after the activity actor restarts. It is one per node
/// under a `one_for_one` supervisor, and the new one watches nothing: no
/// channel event of the account reaches it, its table is empty and every
/// agent reads idle -- an agent on a personal call is offered a caller --
/// and no dispatcher hears `ChannelGone` again. A reading that says the
/// account is not watched is that restart, whenever it comes: the
/// dispatcher's own `watch` is sent from this process before any read, so
/// the actor has handled it before it answers one. The dispatcher watches
/// the account again and is back to syncing, offering nobody until the new
/// actor has the switches' answer or `sync_ceiling_s` has passed since the
/// watch. Each unwatched reading watches again and starts the wait again:
/// an actor that is not running yet drops the watch, and the wait is for
/// the one that takes it.
fn synced(state: State, reading: Reading) -> State {
  case reading.watched, state.sync {
    False, sync -> {
      case sync {
        Synced ->
          system.log(
            "dispatcher for account "
            <> state.config.account_id
            <> ": the activity actor no longer watches the account (it "
            <> "restarted); watching it again and offering nobody until the "
            <> "switches answer",
          )
        Syncing(_) -> Nil
      }
      state.watch_activity()
      State(..state, sync: Syncing(until: state.config.now() + sync_ceiling_s))
    }
    True, _ -> synced_by(state, reading.synced)
  }
}

fn synced_by(state: State, answered: Bool) -> State {
  case state.sync, answered {
    Synced, _ -> state
    Syncing(_), True -> State(..state, sync: Synced)
    Syncing(until), False ->
      case state.config.now() >= until {
        False -> state
        True -> {
          system.log(
            "dispatcher for account "
            <> state.config.account_id
            <> ": the switches have not said what the agents' phones are doing "
            <> "after "
            <> int.to_string(sync_ceiling_s)
            <> " s; offering on the channel events alone",
          )
          State(..state, sync: Synced)
        }
      }
  }
}

/// An agent's availability and counters, as the dispatcher goes by them.
///
/// A user who is disabled, deleted, gone or on do-not-disturb is logged out
/// here whatever their availability document says: never offered, never
/// counted available.
/// Their document is logged out behind this (`callcenter/dnd`), but that is
/// a write another process makes, off an event that can be lost, and until
/// it lands the document still says available. The user is read only for an
/// agent the document says is taking calls, from the document cache the
/// agent's own settings are read from, so a pass in which nobody is free
/// reads no user at all.
pub fn agent_state(state: State, agent_id: String) -> Agent {
  case find(state, agent_id) {
    Ok(Some(agent)) -> agent
    Ok(None) | Error(Nil) -> nobody()
  }
}

/// `agent_state`, saying `Ok(None)` for an agent with no document and
/// `Error(Nil)` for one that could not be read.
fn find(state: State, agent_id: String) -> Result(Option(Agent), Nil) {
  case
    availability.find_with_counters(
      state.config.kz,
      state.config.account_id,
      agent_id,
    )
  {
    Ok(Some(#(current, counters))) ->
      case
        availability.taking_calls(current.availability)
        && !settings.can_be_offered(state.config, agent_id)
      {
        True ->
          Ok(
            Some(#(
              availability.AgentAvailability(..current, availability: LoggedOut),
              counters,
            )),
          )
        False -> Ok(Some(#(current, counters)))
      }
    Ok(None) -> Ok(None)
    Error(_reason) -> Error(Nil)
  }
}

/// An agent nobody has ever set, or who could not be read: logged out.
fn nobody() -> Agent {
  #(availability.logged_out(), records.no_counters())
}

/// How many of the queue's agents could take a caller right now, once per
/// tier: `ready`, as a pass counts it, for a question asked between passes.
/// An agent remembered as having no document is not read for it either,
/// though nothing it finds is remembered: only a pass keeps what it read.
///
/// Nothing when the count cannot be vouched for (`vouched_for`): the
/// account's activity unread or not synced, the queue's document unreadable,
/// or an agent who could be ready unread.
pub fn available_count(state: State, settings: QueueSettings) -> Option(Int) {
  let #(_read, _states, ready, unread) =
    ready(state, state.config.now(), dict.new(), settings)
  case vouched_for(state, QueueSettings(..settings, agents_unread: unread)) {
    True -> Some(list.length(ready))
    False -> None
  }
}

/// Whether the dispatcher can say how many of one queue's agents could take
/// a caller: `vouched` for the account, and `settings.vouched` for the
/// queue as the pass read it.
pub fn vouched_for(state: State, queue: QueueSettings) -> Bool {
  vouched(state) && settings.vouched(queue)
}
