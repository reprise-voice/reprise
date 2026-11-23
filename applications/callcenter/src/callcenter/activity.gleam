//// What an agent's phones are doing, derived on every node from the same
//// event stream.
////
//// Requirement 1.2a: activity is not chosen, it is observed. One actor per
//// node subscribes to the channel events of the accounts its dispatchers
//// watch (see `interest`), keeps the live channels of every agent it has
//// been asked about -- keyed by the channel's
//// `Owner-ID`, so a call on any of the user's devices on any media server
//// counts -- and derives Idle or On a call from whether there are any. A
//// channel carrying the `Queue-ID` custom channel variable is a queue call,
//// which is how the same value distinguishes a call this application made
//// from one it did not without a second state to keep.
////
//// Ringing and Wrapping up are the two the channels cannot say, because they
//// are the application's own: the dispatcher sets them with `set_offering`
//// and `set_wrapup` and takes them off with `clear`. They only ever show
//// through when the agent has no channel at all, so a stale one cannot hide
//// a real call.
////
//// Nor can one outlive what set it. Each is set for as long as it can be
//// true -- the offer's ceiling, the wrap-up's length -- and is dropped here
//// when that runs out, whoever forgot to clear it. The account belongs to
//// the dispatcher that watched it: a new dispatcher's `watch` starts it with
//// none, because the one before took its offers and wrap-ups with it, and the
//// account is forgotten when its dispatcher goes, however it goes. A
//// dispatcher that crashed never says `forget`, and before this its agents
//// stayed ringing or wrapping up until their next call and the node went on
//// resyncing an account whose shard had moved elsewhere.
////
//// Nothing is exchanged between nodes. Whichever node takes a shard over
//// computes this from the same events and the switches' answer, so there is
//// no state to hand over when a shard moves.
////
//// It self-heals from the switches themselves, which are the source of
//// truth: on start, when a node running `ecallmgr` expires, when a queue
//// document changes, and every `reconcile_interval_s` seconds, the channels
//// of every watched account are asked for again and the table is replaced by
//// the answer. A media server that died takes its channels with it and its
//// agents go back to Idle without anybody sending an event. An answer that
//// not every `ecallmgr` gave in time replaces nothing: it only adds what it
//// names, because what it leaves out may be up on the switch that was slow.
////
//// An answer is as old as the question, and the events go on while it is
//// being given. Each question is stamped with how many channel events the
//// actor had heard when it was sent, and each channel with the event that
//// last put it in the table; a destroyed channel's call id is remembered
//// for a minute. An answer never brings back a channel whose destroy has
//// been heard, and never takes away one whose create came after the
//// question: either would be an answer overruling an event it predates.

import callcenter/ask
import callcenter/fields
import callcenter/system
import callcenter/types.{type Activity, Idle, OnCall, Ringing, WrappingUp}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set.{type Set}
import gleam/string
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/events
import kazoo/kazoo.{type Kazoo}
import kazoo/listener.{Limited}
import kazoo/modb
import kazoo/util

/// The custom channel variable that says a channel came out of a queue.
const queue_id_var = "Queue-ID"

/// `system_config/callcenter.reconcile_interval_s`, when nothing says
/// otherwise.
pub const default_reconcile_interval_s = 30

/// How long a destroyed channel's call id is remembered, so that an answer
/// to a question sent before the destroy does not put the channel back. The
/// question waits two seconds for the switches; a minute is long past any
/// answer to one sent before the destroy.
pub const destroyed_kept_s = 60

pub type Message {
  /// A channel of one of this account's agents came up.
  Started(
    account_id: String,
    agent_id: String,
    call_id: String,
    queue_call: Bool,
  )
  /// A channel went away: an agent's, a queue caller's, or both.
  Ended(
    account_id: String,
    /// The agent whose channel it was, when it was one.
    agent_id: Option(String),
    call_id: String,
    /// Whether it carried `Queue-ID`, which a caller in a queue does.
    queue_call: Bool,
  )
  /// The switches' own answer. With every switch in it, it replaces
  /// whatever was believed; with some missing, it only adds to it. `asked`
  /// is how many channel events the actor had heard when the question was
  /// sent: an event after that is newer than the answer.
  Snapshot(
    account_id: String,
    channels: List(#(String, String, Bool)),
    complete: Bool,
    asked: Int,
  )
  /// Start deriving activity for an account for the dispatcher `watcher`,
  /// and load its agents. `gone` is called with the call id of every queue
  /// channel of the account that goes.
  Watch(account_id: String, watcher: Pid, gone: fn(String) -> Nil)
  /// The account's queue documents changed: load its agents again and ask
  /// the switches, if it is watched here.
  Reload(account_id: String)
  /// The agents of an account, as the queue documents list them.
  Watched(account_id: String, agent_ids: List(String))
  /// Stop: the dispatcher for the account has gone. With a watcher, only if
  /// that is still the account's; without one, whoever's it is.
  Forget(account_id: String, watcher: Option(Pid))
  /// A process that watched accounts has ended.
  WatcherDown(pid: Pid)
  /// The dispatcher is ringing this agent, for at most `for_s` seconds.
  Offering(account_id: String, agent_id: String, for_s: Int)
  /// The agent's queue call ended and their wrap-up has started, for
  /// `for_s` seconds.
  Wrapup(account_id: String, agent_id: String, for_s: Int)
  /// Neither any more: back to whatever the channels say.
  Cleared(account_id: String, agent_id: String)
  /// Drop the account's overlays whose time is up.
  Expire(account_id: String)
  Ask(account_id: String, agent_id: String, done: Subject(Activity))
  /// Which accounts this node is deriving activity for.
  Accounts(done: Subject(List(String)))
  AskAll(account_id: String, done: Subject(List(#(String, Activity))))
  /// The account as a dispatcher reads it once a pass.
  Read(account_id: String, done: Subject(Reading))
  /// Ask the switches again, for one account or for all of them.
  Resync(account_id: Option(String))
  Stop(done: Subject(Nil))
}

type Overlay {
  OverlayRinging
  OverlayWrapup
}

type Account {
  Account(
    /// Agent id to the channels that agent is on: call id to whether it is a
    /// queue call.
    channels: Dict(String, Dict(String, Bool)),
    /// Agent id to what the dispatcher says about them, and the second after
    /// which it is no longer true whether it was cleared or not.
    overlay: Dict(String, #(Overlay, Int)),
    /// The dispatcher the account is watched for, which this actor monitors.
    watcher: Option(Pid),
    /// What that dispatcher is told when a queue channel of the account goes:
    /// the call id, which is a caller of its own when it is one of the
    /// callers it has waiting.
    gone: fn(String) -> Nil,
    /// Whether the switches have answered for the account since it was
    /// watched. Until they have, the table holds only the channels whose
    /// events came since, and an agent talking on a call that began before is
    /// not in it.
    synced: Bool,
    /// Every agent of every queue in the account, so that a channel of
    /// somebody who is not an agent is not kept.
    agents: Set(String),
    /// What was last published, so that only changes are.
    published: Dict(String, Activity),
    /// Call id to the number of the event that last put its channel in the
    /// table, for the channels an event put there. A whole answer to a
    /// question sent before that event does not take the channel away.
    created: Dict(String, Int),
    /// Call id to the second its channel's destroy was heard, kept for
    /// `destroyed_kept_s`. No answer puts one of these back.
    destroyed: Dict(String, Int),
  )
}

type State {
  State(
    kz: Kazoo,
    self: Subject(Message),
    accounts: Dict(String, Account),
    reconcile_interval_s: Int,
    /// How many channel events the actor has heard: what a question to the
    /// switches is stamped with, and what a channel's own event is numbered
    /// by.
    heard: Int,
    subscription: Option(events.Subscription),
    /// The accounts whose events the subscription lets through: the ones
    /// in `accounts`, and no others.
    gate: events.Gate,
  )
}

/// The registered name of the one activity actor on a node.
pub fn name() -> Name(Message) {
  util.name("callcenter_activity")
}

fn subject() -> Subject(Message) {
  process.named_subject(name())
}

fn running() -> Bool {
  case process.named(name()) {
    Ok(_pid) -> True
    Error(_) -> False
  }
}

// --- What the rest of the application asks ---------------------------------

/// How long a question to the actor waits for its answer.
///
/// Asked through `callcenter/ask` and never `process.call`: the actor is one
/// per node and every dispatcher on the node asks it, so one that is slow --
/// or gone, between a crash and its restart -- must be an answer the caller
/// can do something with, not the caller's own crash.
const ask_timeout_ms = 2000

/// This node's derived view of one agent.
///
/// `Idle` when the actor is not running, which is the answer a node with no
/// channel events has for everybody, and when it did not answer, which is
/// logged: this is for the agent API and the maintenance commands, which
/// show an agent and do not offer them anything. The dispatcher reads
/// `snapshot`, which says it did not know.
pub fn of(account_id: String, agent_id: String) -> Activity {
  case running() {
    False -> Idle
    True ->
      case ask.call(subject(), ask_timeout_ms, Ask(account_id, agent_id, _)) {
        Ok(activity) -> activity
        Error(failure) -> {
          unanswered("the activity of agent " <> agent_id, failure)
          Idle
        }
      }
  }
}

/// Every agent of an account this node has an activity for.
pub fn agents(account_id: String) -> List(#(String, Activity)) {
  case running() {
    False -> []
    True ->
      case ask.call(subject(), ask_timeout_ms, AskAll(account_id, _)) {
        Ok(agents) -> agents
        Error(failure) -> {
          unanswered("the agents of account " <> account_id, failure)
          []
        }
      }
  }
}

/// One account's activity as a dispatcher reads it.
pub type Reading {
  Reading(
    /// Whether the switches have answered for the account since it was
    /// watched, whole or not. Before, an agent on a call that began before
    /// the account was watched -- a personal call, or a queue call answered
    /// on the node that died -- looks idle.
    synced: Bool,
    /// Whether the account is watched here at all. It is from the
    /// dispatcher's `watch` on, until the dispatcher goes, unless the actor
    /// restarted in between: a new actor watches nothing, follows no event
    /// of the account and has no channel in its table, so every agent reads
    /// idle. The dispatcher that reads `False` watches the account again.
    watched: Bool,
    /// Agent id to activity. An agent it does not name is `Idle`: nothing on
    /// the switches and nothing the dispatcher said about them.
    activities: Dict(String, Activity),
  )
}

/// One account's activity, every agent in one answer: what a dispatcher
/// reads once at the start of a pass, rather than once an agent a caller.
///
/// An actor that is not running -- between a crash and its restart -- is
/// watching nothing: every agent idle as `of` says, and neither watched nor
/// synced, so the dispatcher watches the account again and offers nobody
/// until the new actor has the switches' answer. An actor that did not
/// answer is an `Error`, and the dispatcher offers nobody on it: an agent
/// whose phones nobody could look at is not one to ring.
pub fn snapshot(account_id: String) -> Result(Reading, String) {
  case running() {
    False -> Ok(Reading(synced: False, watched: False, activities: dict.new()))
    True ->
      ask.call(subject(), ask_timeout_ms, Read(account_id, _))
      |> result.map_error(ask.describe)
  }
}

fn unanswered(what: String, failure: ask.Failure) -> Nil {
  system.log_error(
    "activity did not say " <> what <> ": " <> ask.describe(failure),
  )
}

/// Derive activity for this account from now on, for the dispatcher
/// `watcher`, and load its agents.
///
/// The account is the watcher's: a watcher it did not have before starts it
/// with no ringing or wrap-up on anybody, and the account is forgotten when
/// the watcher ends. `gone` is how the watcher hears that a caller's channel
/// went: called, in this actor, with the call id of every channel of the
/// account carrying `Queue-ID` that goes, so it must do no more than send.
pub fn watch(account_id: String, watcher: Pid, gone: fn(String) -> Nil) -> Nil {
  send(Watch(account_id, watcher, gone))
}

/// Stop, whoever the account is watched for.
pub fn forget(account_id: String) -> Nil {
  send(Forget(account_id, None))
}

/// Stop, if the account is still `watcher`'s: a dispatcher that is going
/// says this, and a new one that has already watched the account again is
/// left alone.
pub fn release(account_id: String, watcher: Pid) -> Nil {
  send(Forget(account_id, Some(watcher)))
}

/// The agent's phones are ringing with an offer, for at most `for_s` more
/// seconds: the offer's ceiling.
pub fn set_offering(account_id: String, agent_id: String, for_s: Int) -> Nil {
  send(Offering(account_id, agent_id, for_s))
}

/// The agent's queue call ended; they are in wrap-up for `for_s` seconds
/// unless told otherwise sooner.
pub fn set_wrapup(account_id: String, agent_id: String, for_s: Int) -> Nil {
  send(Wrapup(account_id, agent_id, for_s))
}

/// Back to whatever the channels say.
pub fn clear(account_id: String, agent_id: String) -> Nil {
  send(Cleared(account_id, agent_id))
}

/// Ask the switches for an account's channels again.
pub fn resync(account_id: String) -> Nil {
  send(Resync(Some(account_id)))
}

/// Ask for every watched account, which is what a node expiring means.
pub fn resync_all() -> Nil {
  send(Resync(None))
}

/// The account's queue documents changed: its agents may have. Nothing for
/// an account this node does not watch: every node hears every change.
pub fn queue_changed(account_id: String) -> Nil {
  send(Reload(account_id))
}

fn send(message: Message) -> Nil {
  case running() {
    False -> Nil
    True -> process.send(subject(), message)
  }
}

// --- The actor -------------------------------------------------------------

/// The actor as a supervised child.
pub fn supervised(kz: Kazoo) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start(kz) })
  |> supervision.map_data(fn(_started) { Nil })
}

pub fn start(
  kz: Kazoo,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  builder(kz)
  |> actor.named(name())
  |> actor.start
}

/// The same actor, registered under no name: one a test can start, drive
/// through its messages and stop without touching the node's own, which the
/// application's tree started and would restart.
@internal
pub fn start_unnamed(
  kz: Kazoo,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  builder(kz) |> actor.start
}

fn builder(kz: Kazoo) -> actor.Builder(State, Message, Subject(Message)) {
  let interval =
    kz.config.get_int("reconcile_interval_s", default_reconcile_interval_s)
  actor.new_with_initialiser(30_000, fn(self) {
    let gate = events.new_gate()
    let subscription = subscribe(self, gate)
    schedule(self, interval)
    actor.initialised(State(
      kz: kz,
      self: self,
      accounts: dict.new(),
      reconcile_interval_s: interval,
      heard: 0,
      subscription: subscription,
      gate: gate,
    ))
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid: pid, ..) -> WatcherDown(pid)
          // Nothing here monitors a port; a message that is nobody's.
          process.PortDown(..) -> Expire("")
        }
      }),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
}

/// The channel events of the accounts this node watches, through one
/// closure.
///
/// Every node hears every call event of the cluster, and most of them are
/// nothing to this actor: executes, carrier legs, other nodes' accounts.
/// `interest` drops those on the bus, before any of them is made into a
/// document. The closure runs in the bus's process, so it does the least it
/// can with the rest: read four fields and send. Everything else happens in
/// the actor.
fn subscribe(
  self: Subject(Message),
  gate: events.Gate,
) -> Option(events.Subscription) {
  case
    events.subscribe(interest(gate), fn(event) {
      case interesting(event) {
        None -> Nil
        Some(message) -> process.send(self, message)
      }
    })
  {
    Ok(subscription) -> Some(subscription)
    Error(reason) -> {
      system.log_error("activity could not subscribe to channels: " <> reason)
      None
    }
  }
}

/// What the actor subscribes with: at least every event `interesting` makes
/// a message of, decided on the bus.
///
/// The four channel events it reads, each a binding of its own, so no
/// execute, no DTMF and no progress reaches the closure; of those, only the
/// ones carrying an `Owner-ID` or a `Queue-ID`, which every event
/// `interesting` keeps does; and only for an account open in `gate`, which
/// is an account a dispatcher on this node watches.
pub fn interest(gate: events.Gate) -> events.Interest {
  events.Interest(
    account: events.all,
    events: [
      "CHANNEL_CREATE",
      "CHANNEL_ANSWER",
      "CHANNEL_BRIDGE",
      "CHANNEL_DESTROY",
    ],
    carrying: [events.ChannelVar("Owner-ID"), events.ChannelVar(queue_id_var)],
    gate: Some(gate),
  )
}

/// The events that change what an agent's phones are doing, and the end of
/// a queue caller's channel, as a message, or nothing at all.
///
/// A channel with no owner is not an agent's: an inbound leg from a carrier,
/// a conference, a device with no user. Those are the majority of events on a
/// busy cluster and they stop here -- except the destroy of one carrying
/// `Queue-ID`, which is a caller in a queue hanging up. A caller from the
/// public network has no owner, and a caller's own `Owner-ID`, when there is
/// one, is not an agent's, so a destroy is looked at for both reasons apart.
pub fn interesting(event: Value) -> Option(Message) {
  let owner = events.owner_id(event)
  case events.account_id(event), events.call_id(event) {
    Some(account_id), Some(call_id) ->
      case option.unwrap(events.event_name(event), ""), owner {
        "CHANNEL_CREATE", Some(agent_id)
        | "CHANNEL_ANSWER", Some(agent_id)
        | "CHANNEL_BRIDGE", Some(agent_id)
        ->
          Some(Started(
            account_id: account_id,
            agent_id: agent_id,
            call_id: call_id,
            queue_call: is_queue_call(event),
          ))
        "CHANNEL_DESTROY", _ ->
          case owner, is_queue_call(event) {
            None, False -> None
            _, queue_call ->
              Some(Ended(
                account_id: account_id,
                agent_id: owner,
                call_id: call_id,
                queue_call: queue_call,
              ))
          }
        _other, _ -> None
      }
    _, _ -> None
  }
}

fn is_queue_call(event: Value) -> Bool {
  case events.custom_channel_var(event, queue_id_var) {
    Some("") | None -> False
    Some(_queue_id) -> True
  }
}

fn schedule(self: Subject(Message), interval_s: Int) -> Nil {
  let _ = process.send_after(self, interval_s * 1000, Resync(None))
  Nil
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Started(account_id, agent_id, call_id, queue_call) -> {
      let heard = state.heard + 1
      let state = State(..state, heard: heard)
      actor.continue(
        change(state, account_id, agent_id, fn(account) {
          Account(
            ..account,
            channels: put_channel(
              account.channels,
              agent_id,
              call_id,
              queue_call,
            ),
            // A real channel outranks a belief about one.
            overlay: dict.delete(account.overlay, agent_id),
            created: dict.insert(account.created, call_id, heard),
            destroyed: dict.delete(account.destroyed, call_id),
          )
        }),
      )
    }

    Ended(account_id, agent_id, call_id, queue_call) -> {
      let state = State(..state, heard: state.heard + 1)
      let now = state.kz.now()
      let state = case agent_id {
        None -> state
        Some(agent_id) ->
          change(state, account_id, agent_id, fn(account) {
            Account(
              ..account,
              channels: drop_channel(account.channels, agent_id, call_id),
              created: dict.delete(account.created, call_id),
              destroyed: dict.insert(account.destroyed, call_id, now),
            )
          })
      }
      // The dispatcher hears about its own caller hanging up here rather
      // than on the sweep thirty seconds later, by the caller's own call id:
      // requirement 0.6, a caller who hangs up while waiting leaves the
      // queue immediately. It is told of every queue channel of its account
      // that goes, and keeps the ones that are callers it has waiting.
      case queue_call, dict.get(state.accounts, account_id) {
        True, Ok(account) -> account.gone(call_id)
        _, _ -> Nil
      }
      actor.continue(state)
    }

    Snapshot(account_id, channels, complete, asked) ->
      actor.continue(replace(state, account_id, channels, complete, asked))

    Watch(account_id, watcher, gone) -> {
      let state = watched_by(state, account_id, watcher, gone)
      load_agents(state, account_id)
      ask_switches(state, account_id)
      actor.continue(state)
    }

    Reload(account_id) -> {
      case dict.has_key(state.accounts, account_id) {
        False -> Nil
        True -> {
          load_agents(state, account_id)
          ask_switches(state, account_id)
        }
      }
      actor.continue(state)
    }

    Watched(account_id, agent_ids) ->
      actor.continue(
        with_account(state, account_id, fn(account) {
          Account(..account, agents: set.from_list(agent_ids))
        }),
      )

    Forget(account_id, watcher) ->
      case dict.get(state.accounts, account_id), watcher {
        Ok(account), Some(pid) if account.watcher != Some(pid) ->
          actor.continue(state)
        _, _ -> {
          events.shut(state.gate, account_id)
          actor.continue(
            State(..state, accounts: dict.delete(state.accounts, account_id)),
          )
        }
      }

    WatcherDown(pid) -> {
      let gone =
        dict.filter(state.accounts, fn(_account_id, account) {
          account.watcher == Some(pid)
        })
        |> dict.keys
      list.each(gone, fn(account_id) {
        events.shut(state.gate, account_id)
        system.log(
          "dispatcher for account "
          <> account_id
          <> " has gone: activity forgets the account",
        )
      })
      actor.continue(State(..state, accounts: dict.drop(state.accounts, gone)))
    }

    Offering(account_id, agent_id, for_s) ->
      actor.continue(set_overlay(
        state,
        account_id,
        agent_id,
        OverlayRinging,
        for_s,
      ))

    Wrapup(account_id, agent_id, for_s) ->
      actor.continue(set_overlay(
        state,
        account_id,
        agent_id,
        OverlayWrapup,
        for_s,
      ))

    Cleared(account_id, agent_id) ->
      actor.continue(overlay(state, account_id, agent_id, None))

    Expire(account_id) -> actor.continue(expire(state, account_id))

    Ask(account_id, agent_id, done) -> {
      process.send(done, derived(state, account_id, agent_id, state.kz.now()))
      actor.continue(state)
    }

    Accounts(done) -> {
      process.send(done, dict.keys(state.accounts))
      actor.continue(state)
    }

    AskAll(account_id, done) -> {
      process.send(done, all_of(state, account_id, state.kz.now()))
      actor.continue(state)
    }

    Read(account_id, done) -> {
      process.send(
        done,
        Reading(
          synced: case dict.get(state.accounts, account_id) {
            Ok(account) -> account.synced
            Error(Nil) -> False
          },
          watched: dict.has_key(state.accounts, account_id),
          activities: all_of(state, account_id, state.kz.now())
            |> dict.from_list,
        ),
      )
      actor.continue(state)
    }

    Resync(None) -> {
      list.each(dict.keys(state.accounts), fn(account_id) {
        ask_switches(state, account_id)
      })
      schedule(state.self, state.reconcile_interval_s)
      // An account whose switches never answer forgets its destroyed
      // channels all the same.
      let now = state.kz.now()
      actor.continue(
        State(
          ..state,
          accounts: dict.map_values(state.accounts, fn(_account_id, account) {
            Account(..account, destroyed: recent(account.destroyed, now))
          }),
        ),
      )
    }

    Resync(Some(account_id)) -> {
      ask_switches(state, account_id)
      actor.continue(state)
    }

    Stop(done) -> {
      case state.subscription {
        Some(subscription) -> events.off(subscription)
        None -> Nil
      }
      process.send(done, Nil)
      actor.stop()
    }
  }
}

fn blank(watcher: Pid, gone: fn(String) -> Nil) -> Account {
  Account(
    channels: dict.new(),
    overlay: dict.new(),
    watcher: Some(watcher),
    gone: gone,
    synced: False,
    agents: set.new(),
    published: dict.new(),
    created: dict.new(),
    destroyed: dict.new(),
  )
}

/// The account, watched for `watcher`.
///
/// The dispatcher it is already watched for, watching again, changes
/// nothing. A different one is a new dispatcher for the account, and
/// whatever the one before it said about ringing and wrap-ups went with it:
/// its offers are not this one's, and nothing but a dispatcher ever clears
/// them. The channels stay, since they are the switches' and have been
/// followed all along.
fn watched_by(
  state: State,
  account_id: String,
  watcher: Pid,
  gone: fn(String) -> Nil,
) -> State {
  events.open(state.gate, account_id)
  case dict.get(state.accounts, account_id) {
    Ok(account) if account.watcher == Some(watcher) -> state
    Ok(account) -> {
      let _monitor = process.monitor(watcher)
      let before = everyone(account)
      let account =
        Account(
          ..account,
          overlay: dict.new(),
          watcher: Some(watcher),
          gone: gone,
        )
      announce(state, account_id, account, before)
    }
    Error(Nil) -> {
      let _monitor = process.monitor(watcher)
      State(
        ..state,
        accounts: dict.insert(state.accounts, account_id, blank(watcher, gone)),
      )
    }
  }
}

/// Apply a change to one account and publish whatever it moved.
fn change(
  state: State,
  account_id: String,
  agent_id: String,
  apply: fn(Account) -> Account,
) -> State {
  case dict.get(state.accounts, account_id) {
    // A channel of an account nothing on this node dispatches for is not
    // kept: only the holder needs the table. The subscription's gate stops
    // most of them before they are sent; one already on its way when the
    // account was forgotten stops here.
    Error(_) -> state
    Ok(account) ->
      case is_agent(account, agent_id) {
        False -> state
        True -> announce(state, account_id, apply(account), [agent_id])
      }
  }
}

fn with_account(
  state: State,
  account_id: String,
  apply: fn(Account) -> Account,
) -> State {
  case dict.get(state.accounts, account_id) {
    Error(_) -> state
    Ok(account) -> {
      let account = apply(account)
      announce(state, account_id, account, everyone(account))
    }
  }
}

/// Set an overlay until `for_s` seconds from now, and look at the account
/// again then.
fn set_overlay(
  state: State,
  account_id: String,
  agent_id: String,
  kind: Overlay,
  for_s: Int,
) -> State {
  let for_s = int.max(for_s, 1)
  let _ = process.send_after(state.self, for_s * 1000, Expire(account_id))
  overlay(state, account_id, agent_id, Some(#(kind, state.kz.now() + for_s)))
}

/// The account without the overlays whose time is up, published.
fn expire(state: State, account_id: String) -> State {
  case dict.get(state.accounts, account_id) {
    Error(Nil) -> state
    Ok(account) -> {
      let now = state.kz.now()
      let #(kept, over) =
        dict.to_list(account.overlay)
        |> list.partition(fn(entry) { entry.1.1 > now })
      case over {
        [] -> state
        _ -> {
          let names = list.map(over, fn(entry) { entry.0 })
          system.log(
            "account "
            <> account_id
            <> ": nobody cleared "
            <> string.join(names, ", ")
            <> " in time; back to what the channels say",
          )
          announce(
            state,
            account_id,
            Account(..account, overlay: dict.from_list(kept)),
            names,
          )
        }
      }
    }
  }
}

fn overlay(
  state: State,
  account_id: String,
  agent_id: String,
  to: Option(#(Overlay, Int)),
) -> State {
  change(state, account_id, agent_id, fn(account) {
    Account(..account, overlay: case to {
      None -> dict.delete(account.overlay, agent_id)
      Some(overlay) -> dict.insert(account.overlay, agent_id, overlay)
    })
  })
}

/// The switches' answer, in place of everything believed about the account's
/// channels. Overlays survive it: a ringing agent has no channel yet by
/// definition, and a wrap-up is a timer this node owns.
///
/// What the events said after the question was sent outranks it: see
/// `answered`.
fn replace(
  state: State,
  account_id: String,
  channels: List(#(String, String, Bool)),
  complete: Bool,
  asked: Int,
) -> State {
  case dict.get(state.accounts, account_id) {
    Error(_) -> state
    Ok(account) -> {
      let channels =
        list.filter(channels, fn(channel) { is_agent(account, channel.0) })
      let destroyed = recent(account.destroyed, state.kz.now())
      let meanwhile =
        Meanwhile(
          created: account.created
            |> dict.filter(fn(_call_id, heard) { heard > asked })
            |> dict.keys
            |> set.from_list,
          destroyed: dict.keys(destroyed) |> set.from_list,
        )
      let table =
        answered(
          account.channels,
          channels,
          complete: complete,
          since: meanwhile,
        )
      let up = call_ids(table)
      let account =
        Account(
          ..account,
          channels: table,
          synced: True,
          created: dict.filter(account.created, fn(call_id, _heard) {
            set.contains(up, call_id)
          }),
          destroyed: destroyed,
        )
      // An agent whose channels have gone has to be told about as much as one
      // whose have appeared, so both tables' agents are looked at.
      announce(state, account_id, account, everyone(account))
    }
  }
}

/// The channel table once the switches have answered: agent id to call id to
/// whether it is a queue call.
///
/// An answer every `ecallmgr` gave is the whole of what is up, and replaces
/// the table. One the timeout ended is missing whatever the slow switch
/// carries, and a table replaced by it would show that switch's agents idle
/// -- to be offered callers while they are talking. So it only adds: what it
/// names is up, and what it leaves out is left as it was, for the channel's
/// own destroy or the next whole answer to take away. The answers do not
/// say which media servers an `ecallmgr` that did answer covers, so a
/// channel cannot be dropped by the switch it was on either.
///
/// Neither kind of answer is newer than the events heard while it was being
/// given, `since`. A channel whose destroy has been heard is not put back,
/// whatever the answer names: a switch that answered just before the
/// destroy still named it, and an answer arriving after the destroy used to
/// put the agent back on a call nobody was on -- for good while any
/// `ecallmgr` kept timing out, since a partial answer takes nothing away,
/// and an agent on a call is never offered one. A channel whose create came
/// after the question was sent is kept by a whole answer that leaves it
/// out: the switches answered before it was up.
pub fn answered(
  table: Dict(String, Dict(String, Bool)),
  channels: List(#(String, String, Bool)),
  complete complete: Bool,
  since since: Meanwhile,
) -> Dict(String, Dict(String, Bool)) {
  let start = case complete {
    True -> only_created(table, since.created)
    False -> table
  }
  list.fold(channels, start, fn(table, channel) {
    let #(agent_id, call_id, queue_call) = channel
    case set.contains(since.destroyed, call_id) {
      True -> table
      False -> put_channel(table, agent_id, call_id, queue_call)
    }
  })
}

/// What the channel events said while the switches were being asked.
pub type Meanwhile {
  Meanwhile(
    /// The call ids an event put in the table after the question was sent.
    created: Set(String),
    /// The call ids whose destroy has been heard lately, before the
    /// question or after it.
    destroyed: Set(String),
  )
}

/// No event while the switches were being asked.
pub fn nothing_meanwhile() -> Meanwhile {
  Meanwhile(created: set.new(), destroyed: set.new())
}

/// The table's channels among `created`, and nothing else.
fn only_created(
  table: Dict(String, Dict(String, Bool)),
  created: Set(String),
) -> Dict(String, Dict(String, Bool)) {
  table
  |> dict.map_values(fn(_agent_id, held) {
    dict.filter(held, fn(call_id, _queue_call) {
      set.contains(created, call_id)
    })
  })
  |> dict.filter(fn(_agent_id, held) { !dict.is_empty(held) })
}

fn call_ids(table: Dict(String, Dict(String, Bool))) -> Set(String) {
  dict.fold(table, set.new(), fn(up, _agent_id, held) {
    set.union(up, set.from_list(dict.keys(held)))
  })
}

/// The destroyed call ids still worth remembering at `now`.
fn recent(destroyed: Dict(String, Int), now: Int) -> Dict(String, Int) {
  dict.filter(destroyed, fn(_call_id, at) { now - at < destroyed_kept_s })
}

fn everyone(account: Account) -> List(String) {
  set.to_list(account.agents)
  |> list.append(dict.keys(account.channels))
  |> list.append(dict.keys(account.published))
  |> list.unique
}

/// An account's agent list is loaded from the queue documents; until it
/// arrives every owner counts, so that a channel that came up in the second
/// before the view answered is not lost.
fn is_agent(account: Account, agent_id: String) -> Bool {
  set.is_empty(account.agents) || set.contains(account.agents, agent_id)
}

fn put_channel(
  channels: Dict(String, Dict(String, Bool)),
  agent_id: String,
  call_id: String,
  queue_call: Bool,
) -> Dict(String, Dict(String, Bool)) {
  let held = dict.get(channels, agent_id) |> result.unwrap(dict.new())
  dict.insert(channels, agent_id, dict.insert(held, call_id, queue_call))
}

fn drop_channel(
  channels: Dict(String, Dict(String, Bool)),
  agent_id: String,
  call_id: String,
) -> Dict(String, Dict(String, Bool)) {
  case dict.get(channels, agent_id) {
    Error(_) -> channels
    Ok(held) -> {
      let left = dict.delete(held, call_id)
      case dict.is_empty(left) {
        True -> dict.delete(channels, agent_id)
        False -> dict.insert(channels, agent_id, left)
      }
    }
  }
}

// --- Deriving --------------------------------------------------------------

/// Requirement 1.2a, in one function: the channels decide, and what the
/// application believes about an agent only shows when there are none.
pub fn from_channels(
  channels: List(Bool),
  offering: Bool,
  wrapping_up: Bool,
) -> Activity {
  case channels {
    [] ->
      case offering, wrapping_up {
        True, _ -> Ringing
        False, True -> WrappingUp
        False, False -> Idle
      }
    _any ->
      OnCall(queue_call: list.any(channels, fn(queue_call) { queue_call }))
  }
}

fn derived(
  state: State,
  account_id: String,
  agent_id: String,
  now: Int,
) -> Activity {
  case dict.get(state.accounts, account_id) {
    Error(_) -> Idle
    Ok(account) -> derived_in(account, agent_id, now)
  }
}

/// An overlay past its second is not there, whether or not `Expire` has
/// been round to drop it yet.
fn derived_in(account: Account, agent_id: String, now: Int) -> Activity {
  let channels =
    dict.get(account.channels, agent_id)
    |> result.unwrap(dict.new())
    |> dict.values
  let overlay = case dict.get(account.overlay, agent_id) {
    Ok(#(kind, until)) if until > now -> Some(kind)
    _none_or_over -> None
  }
  from_channels(
    channels,
    overlay == Some(OverlayRinging),
    overlay == Some(OverlayWrapup),
  )
}

fn all_of(
  state: State,
  account_id: String,
  now: Int,
) -> List(#(String, Activity)) {
  case dict.get(state.accounts, account_id) {
    Error(_) -> []
    Ok(account) ->
      list.map(everyone(account), fn(agent_id) {
        #(agent_id, derived_in(account, agent_id, now))
      })
  }
}

// --- Publishing ------------------------------------------------------------

/// Store the account and publish `agent_activity` for every agent whose
/// derived value moved. Nothing is published for a value that did not.
fn announce(
  state: State,
  account_id: String,
  account: Account,
  agent_ids: List(String),
) -> State {
  let #(published, changed) =
    list.fold(agent_ids, #(account.published, []), fn(carry, agent_id) {
      let #(published, changed) = carry
      let now = derived_in(account, agent_id, state.kz.now())
      case dict.get(published, agent_id) {
        Ok(before) if before == now -> #(published, changed)
        // Idle that was never anything else is not news.
        Error(_) if now == Idle -> #(published, changed)
        _moved -> #(dict.insert(published, agent_id, now), [
          #(agent_id, now),
          ..changed
        ])
      }
    })
  list.each(changed, fn(entry) { publish(account_id, entry.0, entry.1) })
  State(
    ..state,
    accounts: dict.insert(
      state.accounts,
      account_id,
      Account(..account, published: published),
    ),
  )
}

fn publish(account_id: String, agent_id: String, activity: Activity) -> Nil {
  system.publish(
    "agent_activity",
    doc.object([
      #("Account-ID", doc.String(account_id)),
      #("Agent-ID", doc.String(agent_id)),
      #("Activity", doc.String(to_string(activity))),
      #("Queue-Call", doc.Bool(activity == OnCall(queue_call: True))),
      #("Timestamp", doc.Int(modb.now())),
    ]),
  )
}

/// The `Activity` values `kapi_callcenter` validates.
pub fn to_string(activity: Activity) -> String {
  case activity {
    Idle -> "idle"
    Ringing -> "ringing"
    OnCall(_) -> "on_call"
    WrappingUp -> "wrapping_up"
  }
}

pub fn from_string(name: String) -> Activity {
  case name {
    "ringing" -> Ringing
    "on_call" -> OnCall(queue_call: False)
    "wrapping_up" -> WrappingUp
    _idle -> Idle
  }
}

// --- Asking the cluster ----------------------------------------------------

/// Ask every `ecallmgr` for an account's channels, in a process of its own.
///
/// Two seconds of waiting for the switches inside the actor would be two
/// seconds in which no offer is made anywhere on the node, so the answer
/// comes back as a message like any other.
fn ask_switches(state: State, account_id: String) -> Nil {
  let self = state.self
  let asked = state.heard
  let _ =
    process.spawn_unlinked(fn() {
      case
        snapshot_of(
          account_id,
          asked,
          events.query_account_channels(system.category, account_id),
        )
      {
        None -> Nil
        Some(snapshot) -> process.send(self, snapshot)
      }
    })
  Nil
}

/// What the switches' answer tells the actor: a `Snapshot`, or nothing at
/// all when there was no answer. No answer includes nobody to ask --
/// `kz_nodes` counting no `ecallmgr` while one restarts -- which
/// `events.account_channels` keeps apart from every switch answering with
/// no channel: a complete, empty snapshot would wipe the table, and every
/// agent on a call would read idle and be offered a caller. `asked` is what
/// the question was stamped with when it was sent.
@internal
pub fn snapshot_of(
  account_id: String,
  asked: Int,
  answer: Result(events.Channels, amqp.Error),
) -> Option(Message) {
  case answer {
    Error(_unanswered) -> None
    Ok(events.Channels(channels, complete)) ->
      Some(Snapshot(
        account_id,
        list.filter_map(channels, snapshot_row),
        complete,
        asked,
      ))
  }
}

fn snapshot_row(
  channel: events.Channel,
) -> Result(#(String, String, Bool), Nil) {
  case channel.owner_id {
    None -> Error(Nil)
    Some("") -> Error(Nil)
    Some(owner_id) ->
      Ok(#(owner_id, channel.call_id, channel_is_queue_call(channel)))
  }
}

/// A channel query answers in `ecallmgr_fs_channel:to_json/1`'s snake case
/// and a channel status in the header case of the bus, so both spellings of
/// the custom channel variables are looked at.
fn channel_is_queue_call(channel: events.Channel) -> Bool {
  named(channel.doc, ["custom_channel_vars", queue_id_var])
  || named(channel.doc, ["Custom-Channel-Vars", queue_id_var])
}

fn named(value: Value, path: List(String)) -> Bool {
  case doc.get_string(value, path) {
    Ok("") -> False
    Ok(_name) -> True
    Error(_) -> False
  }
}

/// The account's agents, from the `queues_by_agent` view, in a process of its
/// own for the same reason the channel query is.
fn load_agents(state: State, account_id: String) -> Nil {
  let self = state.self
  let kz = state.kz
  let _ =
    process.spawn_unlinked(fn() {
      case
        kz.datamgr.get_results(
          kazoo.account_db(account_id),
          "callcenter/queues_by_agent",
          kazoo.view_options(),
        )
      {
        Error(_reason) -> Nil
        Ok(rows) ->
          process.send(
            self,
            Watched(account_id, list.filter_map(rows, agent_of_row)),
          )
      }
    })
  Nil
}

fn agent_of_row(row: Value) -> Result(String, Nil) {
  case doc.get_string(row, ["value", "agent_id"]) {
    Ok(agent_id) if agent_id != "" -> Ok(agent_id)
    _other ->
      case doc.get_list(row, ["key"]) {
        Ok([doc.String(agent_id), ..]) if agent_id != "" -> Ok(agent_id)
        _other ->
          case doc.get_string(row, ["key"]) {
            Ok(agent_id) if agent_id != "" -> Ok(agent_id)
            _other -> Error(Nil)
          }
      }
  }
}

// --- The configuration listener --------------------------------------------

/// A listener for the two things outside the channel stream that change what
/// this actor believes: a queue document being edited, which may have added
/// or removed an agent, and a node with `ecallmgr` on it expiring, which
/// takes its channels with it.
///
/// It is described here rather than folded into the shard placement because
/// it has nothing to do with a shard: a node holding no shard at all still
/// derives activity, and still has to hear both.
///
/// A queue being deleted is also told to `on_queue_deleted`, with the
/// account and the queue: every node hears it, so the node dispatching the
/// account does, and its dispatcher takes the queue's callers out of it at
/// once rather than on its next look at the document.
pub fn conf_listener(
  on_queue_deleted: fn(String, String) -> Nil,
) -> listener.Listener {
  listener.new()
  |> listener.binding("conf", [
    listener.prop("doc_type", listener.Text("queue")),
    listener.prop("action", listener.Text("*")),
  ])
  |> listener.queue(
    name: "",
    durable: False,
    exclusive: False,
    auto_delete: True,
    ttl: Limited(60_000),
    max_length: Limited(1000),
  )
  |> listener.notify_nodes(of: [listener.NodeGone])
  |> listener.on_event(fn(event, _delivery) {
    case account_of_conf(event) {
      None -> Nil
      Some(account_id) -> queue_changed(account_id)
    }
    case deleted_queue(event) {
      Some(#(account_id, queue_id)) -> on_queue_deleted(account_id, queue_id)
      None -> Nil
    }
  })
  |> listener.on_info(fn(info) {
    case info {
      // A node with ecallmgr on it is gone and its channels with it. Every
      // watched account is asked again rather than working out which
      // channels were on it: the answer is the same and the sweep is cheap.
      listener.NodeExpire(node) ->
        case list.contains(node.kapps, "ecallmgr") {
          False -> Nil
          True -> {
            system.log(
              "media node " <> node.name <> " expired: resyncing activity",
            )
            resync_all()
          }
        }
      _other -> Nil
    }
  })
}

/// The account a configuration event is about: what it says, or the database
/// it names.
pub fn account_of_conf(event: Value) -> Option(String) {
  fields.account_of_change(event)
}

/// The account and queue a configuration event deletes, when it is a queue
/// being deleted: `doc_deleted`, which is what Crossbar's soft delete
/// publishes as well as a document really going.
pub fn deleted_queue(event: Value) -> Option(#(String, String)) {
  case
    doc.get_string(event, ["Event-Name"]),
    doc.get_string(event, ["Type"]),
    doc.get_string(event, ["ID"]),
    account_of_conf(event)
  {
    Ok("doc_deleted"), Ok("queue"), Ok(queue_id), Some(account_id)
      if queue_id != ""
    -> Some(#(account_id, queue_id))
    _, _, _, _ -> None
  }
}

/// The reconcile interval this node is configured with, for the sweep and
/// for `sup`.
pub fn reconcile_interval_s(kz: Kazoo) -> Int {
  case kz.config.get_int("reconcile_interval_s", default_reconcile_interval_s) {
    seconds if seconds > 0 -> seconds
    _invalid -> default_reconcile_interval_s
  }
}

/// How many agents of an account this node is deriving activity for, for
/// `sup callcenter_maintenance status`.
pub fn watched() -> List(String) {
  case running() {
    False -> []
    True ->
      case ask.call(subject(), ask_timeout_ms, Accounts) {
        Ok(accounts) -> accounts
        Error(failure) -> {
          unanswered("which accounts it watches", failure)
          []
        }
      }
  }
}
