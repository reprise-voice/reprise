//// The sweep: what the events would have said if none had been missed.
////
//// Requirement 0.6 asks for a timeout behind every event, so that no caller
//// and no agent can be stuck because a message was lost or a node died
//// between one and the next. Three of the four are elsewhere and are cheap
//// because they are: the activity actor resyncs its channel table against
//// the switches on its own timer, the dispatcher's tick expires wrap-ups,
//// per-agent delays and offers past their ceiling, and an agent whose
//// channel vanished goes back to Idle when the media node expires.
////
//// What is left is the two that need a question asked of the cluster.
////
//// A caller waiting in a queue whose channel is no longer on any switch.
//// That happens when a `CHANNEL_DESTROY` was missed during a failover, and
//// it is exactly acdc's ghost call -- a caller who is not there being
//// offered to every agent who logs in. Every `reconcile_interval_s` seconds
//// this asks the switches about every waiting caller on this node and tells
//// the dispatcher about the ones nobody is carrying.
////
//// And a call somebody answered on a node that then died. Its member
//// message was settled the moment it was answered, so the broker has
//// nothing left to redeliver and no other node will ever hear of it: the
//// `queue_call` document stays open with no end, the agent gets no wrap-up
//// and no counters, and nothing publishes `member_result` or
//// `agent_wrapup`. The record is the only thing that survived, so the
//// records are what this looks at -- `callcenter/queue_calls_open` over the
//// accounts of the shards concerned. A record whose caller is on no switch
//// is closed; one whose caller is still talking is handed to a dispatcher,
//// which adopts the call and watches it for the end.
////
//// **That scan runs when this node takes a shard, and not on every sweep.**
//// An orphan appears when a node dies, and a node dying is a shard taken
//// here: a shard this node holds now and did not at the last sweep is the
//// whole of the trigger. Scanning on every sweep instead would mean listing
//// the cluster's accounts and running a view query for each of them every
//// `reconcile_interval_s`, which on a cluster of any size is thousands of
//// queries a node for nothing -- the records of a node that is alive are
//// closed by that node. Behind it is a backstop every `backstop_sweeps`
//// sweeps over every shard held, for the cases an acquisition cannot cover:
//// a datastore that was down when the scan ran, or a record this node
//// itself lost track of.
////
//// The asking is done in a process of its own. A channel query waits two
//// seconds for the switches to answer, a view query waits on a datastore,
//// and there may be hundreds of callers; none of that may happen inside
//// this actor, which also runs the rebalance, nor inside a dispatcher. The
//// cluster's account ids are listed in that process too, and kept here for
//// `accounts_ttl_s`, because the listing is a view over the accounts
//// database and the shard of an account is a hash of its id; so is whether
//// each account has queues, because an account with none has no queue calls
//// and its month database is not read. The switches are asked once per
//// account, for its channels, and not once per record. One scan runs at a
//// time: a sweep that finds the last one still going starts none.

import callcenter/activity
import callcenter/ask
import callcenter/breaks
import callcenter/closed
import callcenter/dispatcher
import callcenter/dnd
import callcenter/member
import callcenter/records
import callcenter/shard
import callcenter/shards
import callcenter/system
import callcenter/types.{Member}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set.{type Set}
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/events
import kazoo/kazoo.{type Kazoo}
import kazoo/modb
import kazoo/nodes
import kazoo/util

/// The view of the open records, in the month databases.
pub const open_calls_view = "callcenter/queue_calls_open"

/// How many sweeps apart the backstop scan of the open records is.
///
/// The scan itself runs when this node takes a shard, which is when an
/// orphan can appear. This is only for what an acquisition cannot cover --
/// a datastore that was down when the scan ran, a record this node lost
/// track of while it held the shard -- so it is slow on purpose: it lists
/// the cluster's accounts and, for each one of the shards held that has
/// queues, runs a view query and one channel query. Twenty sweeps at the
/// default `reconcile_interval_s` of 30 is ten minutes.
pub const backstop_sweeps = 20

/// How long the cluster's account ids are kept before they are listed
/// again. The listing is a view over the accounts database; an account
/// created inside the window is one whose calls nobody has answered yet.
pub const accounts_ttl_s = 300

/// One answered call whose `queue_call` record was never closed.
pub type OpenCall {
  OpenCall(
    account_id: String,
    queue_id: String,
    call_id: String,
    joined: Int,
    agent_id: String,
    agent_call_id: String,
    answered: Int,
    /// A supervisor's pickup (`records.picked_up`), not an agent's queue
    /// call: `agent_id` is whoever picked the caller up, and nothing an
    /// agent's call counts is counted when it closes.
    picked_up: Bool,
  )
}

pub type Message {
  /// Sweep now.
  Sweep
  /// A caller nobody is carrying.
  Gone(account_id: String, call_id: String)
  /// An answered call whose record is open, and what the switches said about
  /// its caller: `Some(second)` is a channel that has gone, `None` one that
  /// is still up.
  Unclosed(call: OpenCall, ended: Option(Int))
  /// The passages the open-records view named for one account, read by a
  /// scan after every `Unclosed` of that account was sent. What `closing`
  /// holds of that account and the view no longer names has been written.
  Named(account_id: String, passages: List(String))
  /// A record this node asked about and could not hand over, or found closed
  /// when it read it again: the next scan asks again.
  NotHanded(passage: String)
  /// The cluster's account ids, as the scan that listed them found them.
  Listed(account_ids: List(String), at: Int)
  /// Whether an account has queues, as a scan found out. Kept with the
  /// listing and forgotten with it.
  Queued(account_id: String, has_queues: Bool)
  Stop(done: Subject(Nil))
}

type State {
  State(
    kz: Kazoo,
    self: Subject(Message),
    shards: Int,
    interval_s: Int,
    /// The passages this node has already told a dispatcher to close, so
    /// that the next scan does not close them twice: the write that takes
    /// them out of the view is a cast to the records actor and may not have
    /// landed by then. See `Asked`.
    closing: Dict(String, Asked),
    /// The shards this node held at the last sweep, each with the actor
    /// holding it. What it holds now and did not then is a shard that
    /// moved, which is the only way an orphaned call reaches this node --
    /// and a shard held by a new actor is one that moved away and back,
    /// through a crash or a lost channel, in between two sweeps.
    held: Set(#(Int, Pid)),
    /// Sweeps since the last backstop scan.
    sweeps: Int,
    /// The cluster's account ids, and the second they were listed. Kept
    /// because the listing is a view over the accounts database and is done
    /// in a scan's own process, never in this one.
    accounts: List(String),
    listed_at: Int,
    /// Whether each account read since the listing has queues. An account
    /// with none has no queue calls to lose, and is not read.
    queued: Dict(String, Bool),
    /// The scan running now. Another is not started until it is done.
    scanning: Option(Pid),
    /// The do-not-disturb pass running now, under the same rule.
    following: Option(Pid),
  )
}

pub fn name() -> Name(Message) {
  util.name("callcenter_reconcile")
}

/// Sweep now rather than waiting for the timer, which is what `sup` asks.
pub fn now() -> Nil {
  case process.named(name()) {
    Ok(_pid) -> process.send(process.named_subject(name()), Sweep)
    Error(_) -> Nil
  }
}

pub fn supervised(
  kz: Kazoo,
  count: Int,
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start(kz, count) })
  |> supervision.map_data(fn(_started) { Nil })
}

pub fn start(
  kz: Kazoo,
  count: Int,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  let interval = activity.reconcile_interval_s(kz)
  actor.new_with_initialiser(30_000, fn(self) {
    // The node's note of the passages its dispatchers closed is pruned by
    // this actor and owned by another (`closed.supervised`), so that it
    // outlives a crash here.
    schedule(self, interval)
    actor.initialised(State(
      kz: kz,
      self: self,
      shards: count,
      interval_s: interval,
      closing: dict.new(),
      held: set.new(),
      sweeps: 0,
      accounts: [],
      listed_at: 0,
      queued: dict.new(),
      scanning: None,
      following: None,
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name())
  |> actor.start
}

fn schedule(self: Subject(Message), interval_s: Int) -> Nil {
  let _ = process.send_after(self, interval_s * 1000, Sweep)
  Nil
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Sweep -> {
      let _forgotten = closed.forget_old()
      let state =
        State(..state, closing: expired(state.closing, modb.now()))
        |> sweep
        |> follow_dnd
      schedule(state.self, state.interval_s)
      actor.continue(state)
    }

    Gone(account_id, call_id) -> {
      case dispatcher_for(state, account_id) {
        Error(_) -> Nil
        Ok(to) -> {
          system.log(
            "caller "
            <> call_id
            <> " of account "
            <> account_id
            <> " is on no switch: leaving the queue",
          )
          process.send(to, dispatcher.ChannelGone(call_id))
        }
      }
      actor.continue(state)
    }

    Unclosed(call, ended) -> actor.continue(unclosed(state, call, ended))

    Named(account_id, passages) ->
      actor.continue(
        State(..state, closing: named(state.closing, account_id, passages)),
      )

    NotHanded(passage) ->
      actor.continue(
        State(..state, closing: dict.delete(state.closing, passage)),
      )

    Listed(account_ids, at) ->
      actor.continue(
        State(..state, accounts: account_ids, listed_at: at, queued: dict.new()),
      )

    Queued(account_id, has_queues) ->
      actor.continue(
        State(
          ..state,
          queued: dict.insert(state.queued, account_id, has_queues),
        ),
      )

    Stop(done) -> {
      process.send(done, Nil)
      actor.stop()
    }
  }
}

fn sweep(state: State) -> State {
  case nodes.whapp_count("ecallmgr") {
    // With no switch to ask there is nothing to learn, so nothing is asked.
    // The shards held are not noted either, so the next sweep that can ask
    // still sees them as new.
    0 -> {
      quiet(state)
      state
    }
    _switches -> {
      ask_about_everybody(state)
      look_for_orphans(state)
    }
  }
}

fn quiet(state: State) -> Nil {
  case dispatchers(state) {
    [] -> Nil
    _somebody_waiting ->
      system.log(
        "no ecallmgr is running: not sweeping the callers on "
        <> system.node_name(),
      )
  }
}

// --- Do not disturb ---------------------------------------------------------

/// Put right the agents of the accounts this node dispatches whose
/// do-not-disturb and availability disagree, in a process of its own: the
/// user edit that would have done it can be lost, and nothing else looks.
/// See `callcenter/dnd`. End the breaks there that are over and that the
/// node which started them did not end (`callcenter/breaks`). Not while the
/// last pass is still going.
fn follow_dnd(state: State) -> State {
  case scan_running(state.following), dispatching(state) {
    True, _ -> state
    False, [] -> State(..state, following: None)
    False, accounts -> {
      let kz = state.kz
      let pid =
        process.spawn_unlinked(fn() {
          list.each(accounts, fn(account_id) {
            let _followed_and_ended = dnd.sweep(kz, account_id)
            Nil
          })
        })
      State(..state, following: Some(pid))
    }
  }
}

/// The accounts this node is dispatching, each once.
fn dispatching(state: State) -> List(String) {
  dispatchers(state)
  |> list.map(fn(entry) { entry.0 })
  |> list.unique
}

// --- Callers waiting in a queue --------------------------------------------

/// What the switches said about one call, as the sweep reads it.
pub type Whereabouts {
  /// A switch is carrying the call.
  Carried
  /// Every switch answered, and none is carrying it.
  Nowhere
  /// The cluster did not answer, not all of it answered in time, or it could
  /// not be asked. Nothing is known about the call, and nothing is done to
  /// it.
  Unanswered
}

/// The one reading of a channel status the sweep has, for both passes.
///
/// A caller is only ever "gone" on the word of the switches: an empty list
/// is every `ecallmgr` saying it does not carry the call, and nothing else
/// is. `events.channel_status` gives `NoAnswer` for a query no switch
/// answered -- a broker restart with the consumers not yet rebound, a
/// cluster with nobody listening -- and for one the timeout ended with only
/// `terminated` in it, where the switch that was slow may be the one
/// carrying the caller. Either is a question to ask again, not an answer. A
/// cluster whose media nodes are all restarting must not lose its callers, a
/// switch slower than the query must not lose the callers on it, and a
/// development cluster with no media server at all must not lose them
/// either.
pub fn whereabouts(
  answer: Result(List(events.Channel), amqp.Error),
) -> Whereabouts {
  case answer {
    Ok([]) -> Nowhere
    Ok(_carried) -> Carried
    Error(_unanswered) -> Unanswered
  }
}

/// Every waiting caller this node is holding, asked about at the switches.
///
/// Nothing is swept while no `ecallmgr` is running, and nothing is done
/// with a query the switches did not answer: see `whereabouts`.
fn ask_about_everybody(state: State) -> Nil {
  let self = state.self
  list.each(dispatchers(state), fn(entry) {
    let #(account_id, to) = entry
    // A dispatcher that stopped since the list was taken has nobody
    // waiting, which is why it stopped.
    let waiting = ask.call(to, 5000, dispatcher.Waiting) |> result.unwrap([])
    case waiting {
      [] -> Nil
      call_ids -> {
        let _ =
          process.spawn_unlinked(fn() {
            list.each(call_ids, fn(call_id) {
              case
                whereabouts(events.channel_status(system.category, call_id))
              {
                Nowhere -> process.send(self, Gone(account_id, call_id))
                Carried -> Nil
                Unanswered -> Nil
              }
            })
          })
        Nil
      }
    }
  })
}

// --- Calls answered on a node that died ------------------------------------

/// Which shards to scan for open records this sweep, and where that leaves
/// the sweep's own counters.
///
/// A shard taken here since the last sweep is a node that died, and
/// the calls it answered are what is looked for. The backstop is every shard
/// held, every `backstop_sweeps` sweeps.
///
/// Never while the last scan is still running: a scan of many accounts can
/// outlast the interval, and two at once would ask about the same records
/// twice. The sweep that finds one running changes nothing, so that the
/// shards taken since, and a backstop that was due, are still there for the
/// next sweep to see.
fn look_for_orphans(state: State) -> State {
  case scan_running(state.scanning) {
    True -> state
    False -> {
      let held = set.from_list(held_shards(state.shards))
      let due = due_for_backstop(state.sweeps)
      let scanning = case due {
        True -> held
        False -> taken(held, state.held)
      }
      let pid =
        scan(
          state,
          set.to_list(scanning) |> list.map(fn(held) { held.0 }),
          because: due,
        )
      State(..state, held: held, scanning: pid, sweeps: case due {
        True -> 0
        False -> state.sweeps + 1
      })
    }
  }
}

/// Whether the last scan is still going.
pub fn scan_running(scanning: Option(Pid)) -> Bool {
  case scanning {
    Some(pid) -> process.is_alive(pid)
    None -> False
  }
}

/// The shards this node holds now and did not hold before. Each is the
/// shard and the process holding it, so that a shard held by a new process
/// counts as taken.
pub fn taken(held: Set(held), before: Set(held)) -> Set(held) {
  set.difference(held, before)
}

/// Whether this sweep is the one that scans everything anyway.
pub fn due_for_backstop(sweeps: Int) -> Bool {
  sweeps + 1 >= backstop_sweeps
}

fn held_shards(count: Int) -> List(#(Int, Pid)) {
  list.filter_map(shards.all(count), fn(shard_id) {
    shard.holder(shard_id) |> result.map(fn(pid) { #(shard_id, pid) })
  })
}

/// The open records of the accounts of some shards, asked about at the
/// switches, in a process of its own, which is returned.
///
/// Everything here waits on something -- the accounts database, a queue
/// listing and a month database per account, two seconds of switches per
/// account -- and none of it may happen in the actor, which is also the one
/// that rebalances. What it costs is kept down three ways: only accounts
/// with queues are read (`has_queues`, kept with the account listing), the
/// switches are asked once per account and not once per record
/// (`located`), and only the records that look gone are asked about one by
/// one, to be sure before they are closed.
fn scan(
  state: State,
  scanning: List(Int),
  because backstop: Bool,
) -> Option(Pid) {
  case scanning {
    [] -> None
    shards_scanned -> {
      let self = state.self
      let kz = state.kz
      let count = state.shards
      let cached = case
        state.accounts,
        modb.now() - state.listed_at < accounts_ttl_s
      {
        [_, ..] as account_ids, True -> Some(account_ids)
        _stale, _ -> None
      }
      let queued = case cached {
        Some(_) -> state.queued
        None -> dict.new()
      }
      let pid =
        process.spawn_unlinked(fn() {
          let account_ids = case cached {
            Some(account_ids) -> account_ids
            None -> {
              let listed = case kz.cluster.account_ids() {
                Ok(account_ids) -> account_ids
                Error(_unreachable) -> []
              }
              process.send(self, Listed(listed, modb.now()))
              listed
            }
          }
          let accounts =
            accounts_of(account_ids, shards_scanned, count)
            |> list.filter(fn(account_id) {
              with_queues(kz, self, queued, account_id)
            })
          announce(accounts, shards_scanned, backstop)
          list.each(accounts, fn(account_id) {
            // The breaks of an account nobody dispatches have no sweep of
            // their own: this is where they end when the node that started
            // them is gone (`callcenter/breaks`).
            let _ended = breaks.sweep(kz, account_id)
            case read_open_calls(kz, account_id, at: None) {
              // The datastore did not answer: nothing is known about this
              // account's records, and nothing is forgotten either.
              Error(Nil) -> Nil
              Ok(calls) -> {
                ask_about_open(self, account_id, calls)
                process.send(self, Named(account_id, list.map(calls, passage)))
              }
            }
          })
        })
      Some(pid)
    }
  }
}

/// Whether an account's records are worth reading: whether it has queues,
/// from what the scans since the listing found, or found out now and told
/// to the sweep. An account whose queues could not be listed is read all
/// the same.
fn with_queues(
  kz: Kazoo,
  self: Subject(Message),
  queued: Dict(String, Bool),
  account_id: String,
) -> Bool {
  case dict.get(queued, account_id) {
    Ok(known) -> known
    Error(Nil) ->
      case has_queues(kz, account_id) {
        Ok(has) -> {
          process.send(self, Queued(account_id, has))
          has
        }
        Error(Nil) -> True
      }
  }
}

/// Whether an account has a queue: one row of its queue listing. An account
/// with none has had no queue calls, and its month database is not read.
pub fn has_queues(kz: Kazoo, account_id: String) -> Result(Bool, Nil) {
  case
    kz.datamgr.get_results(
      kazoo.account_db(account_id),
      queues_view,
      kazoo.view_options() |> kazoo.with_limit(1),
    )
  {
    Ok(rows) -> Ok(rows != [])
    Error(kazoo.NotFound) -> Ok(False)
    Error(_unreachable) -> Error(Nil)
  }
}

/// The view `has_queues` reads: `cb_queues`' own listing.
pub const queues_view = "queues/crossbar_listing"

/// One account's open records, asked about at the switches: one question
/// for the account's channels, and one more for each record that answer
/// does not carry, before it is closed.
fn ask_about_open(
  self: Subject(Message),
  account_id: String,
  calls: List(OpenCall),
) -> Nil {
  case calls {
    [] -> Nil
    calls -> {
      let channels =
        events.query_account_channels(
          app: system.category,
          account_id: account_id,
        )
      list.each(calls, fn(call) {
        case located(channels, call.call_id) {
          Carried -> process.send(self, Unclosed(call, None))
          // Gone by the account's channels. The call's own status is asked
          // before it is closed, as a second look: nobody counted to ask is
          // already no answer (`events.account_channels`), and the call's
          // own question is the one every switch answers about it.
          Nowhere ->
            case
              whereabouts(events.channel_status(system.category, call.call_id))
            {
              Nowhere -> process.send(self, Unclosed(call, Some(modb.now())))
              Carried -> process.send(self, Unclosed(call, None))
              Unanswered -> Nil
            }
          // Not every switch answered, and none that did carries the call:
          // nothing is known. The backstop asks again.
          Unanswered -> Nil
        }
      })
    }
  }
}

/// Where one call is, by the answer to a query for its account's channels.
///
/// A channel with its call id is the call being up, whoever else was late.
/// Missing from an answer every switch gave is the call on no switch.
/// Missing from one the timeout ended is nothing: the switch that was slow
/// may be the one carrying it, which is `whereabouts`' rule, and the rule
/// the channel table is held to.
pub fn located(
  answer: Result(events.Channels, amqp.Error),
  call_id: String,
) -> Whereabouts {
  case answer {
    Error(_unanswered) -> Unanswered
    Ok(events.Channels(channels, complete)) ->
      case
        list.any(channels, fn(channel) { channel.call_id == call_id }),
        complete
      {
        True, _ -> Carried
        False, True -> Nowhere
        False, False -> Unanswered
      }
  }
}

fn announce(
  accounts: List(String),
  scanning: List(Int),
  backstop: Bool,
) -> Nil {
  case accounts {
    [] -> Nil
    _some ->
      system.log(
        "reading the open records of "
        <> int.to_string(list.length(accounts))
        <> " account(s) in "
        <> int.to_string(list.length(scanning))
        <> " shard(s) "
        <> case backstop {
          True -> "on the backstop sweep"
          False -> "this node has just taken"
        },
      )
  }
}

/// Which of the cluster's accounts belong to those shards.
pub fn accounts_of(
  account_ids: List(String),
  scanning: List(Int),
  count: Int,
) -> List(String) {
  list.filter(account_ids, fn(account_id) {
    list.contains(scanning, shards.of_account(account_id, count))
  })
}

/// The answered calls of one account whose records are still open, in the
/// month `at` falls in.
///
/// Through the data layer on the month database rather than through
/// `kazoo/modb`, because this is a read of a month that a write has already
/// created: a month with no such call answers nothing, which is the same
/// thing as no open records.
///
/// One month, and it is this one. A call answered at ten to midnight on the
/// last day of a month whose holder died after it is in the month before,
/// and is not found until something else closes it; asking two months on
/// every sweep to catch that is a cost every account pays all month long.
pub fn open_calls(
  kz: Kazoo,
  account_id: String,
  at at: Option(Int),
) -> List(OpenCall) {
  read_open_calls(kz, account_id, at: at) |> result.unwrap([])
}

/// The same, keeping a datastore that did not answer apart from a month
/// with nothing open in it: only the second says the view no longer names
/// what `closing` remembers.
pub fn read_open_calls(
  kz: Kazoo,
  account_id: String,
  at at: Option(Int),
) -> Result(List(OpenCall), Nil) {
  case
    kz.datamgr.get_results(
      modb.db_name(account_id, at: at),
      open_calls_view,
      kazoo.ViewOptions(
        ..kazoo.view_options(),
        key: Some(doc.String(account_id)),
        include_docs: True,
      ),
    )
  {
    // A month nothing was written in has no database.
    Error(kazoo.NotFound) -> Ok([])
    Error(_unreachable) -> Error(Nil)
    Ok(rows) -> Ok(list.filter_map(rows, open_call(_, account_id)))
  }
}

/// One row of that view as an `OpenCall`. A row naming no call, or no agent,
/// is one nothing can be done about and is left where it is. A supervisor's
/// pickup names whoever picked up as its agent, and says it is a pickup.
///
/// The passage is what the document says -- its call, queue and `joined` --
/// and not its id, so a call id document an earlier release wrote reads the
/// same as one of this release's: the close goes back through
/// `records.ended`, which finds either by those three.
pub fn open_call(row: Value, account_id: String) -> Result(OpenCall, Nil) {
  let document = doc.get(row, ["doc"]) |> result.unwrap(row)
  use call_id <- result.try(doc.get_string(document, ["call_id"]))
  use agent_id <- result.try(doc.get_string(document, ["agent_id"]))
  use answered <- result.try(doc.get_int(document, ["answered"]))
  Ok(OpenCall(
    account_id: account_id,
    queue_id: doc.get_string(document, ["queue_id"]) |> result.unwrap(""),
    call_id: call_id,
    joined: doc.get_int(document, ["joined"]) |> result.unwrap(answered),
    agent_id: agent_id,
    agent_call_id: doc.get_string(document, ["agent_call_id"])
      |> result.unwrap(""),
    answered: answered,
    picked_up: doc.get_bool(document, ["picked_up"]) |> result.unwrap(False),
  ))
}

/// Hand one open record to the account's dispatcher, which closes it or
/// adopts the call exactly as it would one of its own.
///
/// Only this node does it, and only for a shard it holds: the accounts were
/// filtered by that before the records were read. What is guarded here is
/// this node asking twice -- the close is a cast to the records actor and
/// the view will not have caught up by the next scan.
///
/// The handing over is spawned, because there may be no dispatcher for the
/// account yet and starting one is a call to the shard actor: it reads the
/// account's documents and the shard may be busy with a member of its own.
/// That is not a wait this actor can afford, and the decision -- whether
/// this record has been asked about already -- is made here before anything
/// is spawned. A record whose shard has moved on by the time the spawn runs
/// finds no dispatcher and is left for whichever node holds it now.
fn unclosed(state: State, call: OpenCall, ended: Option(Int)) -> State {
  case already_asked(state.closing, call) {
    True -> state
    False -> {
      say(call, ended)
      let count = state.shards
      let kz = state.kz
      let self = state.self
      let _ =
        process.spawn_unlinked(fn() {
          case hand_over(kz, call, ended, count) {
            True -> Nil
            False -> process.send(self, NotHanded(passage(call)))
          }
        })
      case ended {
        None -> state
        Some(_) ->
          State(..state, closing: asking(state.closing, call, modb.now()))
      }
    }
  }
}

/// Whether the record went to a dispatcher.
fn hand_over(
  kz: Kazoo,
  call: OpenCall,
  ended: Option(Int),
  count: Int,
) -> Bool {
  case ended {
    Some(_) ->
      case still_open(records.read(kz, rebuilt(call))) {
        True -> give(call, ended, count)
        False -> {
          system.log(
            "call "
            <> call.call_id
            <> " of account "
            <> call.account_id
            <> " has been closed since the scan read it, or cannot be read:"
            <> " leaving it",
          )
          False
        }
      }
    None -> give(call, ended, count)
  }
}

/// Whether a passage read back just before it is closed is still open.
///
/// The view the scan read is behind the documents by however long its index
/// takes, and a scan spends two seconds asking the switches between reading
/// it and handing a record over. A dispatcher -- this node's own, or one on
/// the node that handed the shard over -- that closed the call in between has
/// written its end by now, and a second close would be a second
/// `member_result` and a second wrap-up. A document that cannot be read is
/// not closed on a guess either: the next scan comes back to it.
pub fn still_open(found: Option(records.Passage)) -> Bool {
  case found {
    Some(records.Passage(ended: None, cancelled: None, ..)) -> True
    Some(_finished) | None -> False
  }
}

fn give(call: OpenCall, ended: Option(Int), count: Int) -> Bool {
  case
    shard.start_dispatcher(
      shards.of_account(call.account_id, count),
      call.account_id,
    )
  {
    Error(_no_dispatcher) -> {
      system.log_error(
        "no dispatcher for account "
        <> call.account_id
        <> ": the record of call "
        <> call.call_id
        <> " is left open for whichever node holds the shard now",
      )
      False
    }
    Ok(to) -> {
      process.send(
        to,
        dispatcher.Orphaned(
          member: rebuilt(call),
          agent_id: call.agent_id,
          agent_call_id: call.agent_call_id,
          answered_at: call.answered,
          picked_up: call.picked_up,
          ended: ended,
        ),
      )
      True
    }
  }
}

/// The passage an open record is, as `closing` remembers it: one caller can
/// have had more than one, in more than one queue.
pub fn passage(call: OpenCall) -> String {
  records.passage_id(rebuilt(call))
}

/// One record this node has told a dispatcher to close: whose account it is
/// in, so that a scan of that account can forget it, and when it was asked.
pub type Asked {
  Asked(account_id: String, at: Int)
}

/// How long a record asked about is left alone while the view still names
/// it, before a scan asks about it again: the backstop's own period at the
/// default interval.
///
/// Only a record whose close never landed is still named by then -- a
/// dispatcher that stopped before it closed it, a write that was dropped --
/// and asking again is safe: a passage this node's dispatchers closed is in
/// `callcenter/closed` for longer than this, and one found there has its end
/// written again and nothing else.
pub const retry_s = 600

/// Whether this node has already told a dispatcher to close that record.
///
/// The end is written by the records actor, which is a cast, and the view
/// only stops naming a record once that write has landed. Two sweeps are
/// `reconcile_interval_s` apart and that is long enough in every ordinary
/// case, but "long enough" is not a guarantee and a second close would be a
/// second wrap-up, a second `member_result` and a second set of counters.
/// So the calls asked about are remembered until a scan of their account
/// finds the view no longer naming them (`named`), the hand-over fails
/// (`NotHanded`), or `retry_s` goes by (`expired`).
pub fn already_asked(asked: Dict(String, Asked), call: OpenCall) -> Bool {
  dict.has_key(asked, passage(call))
}

/// The record, asked about now.
pub fn asking(
  asked: Dict(String, Asked),
  call: OpenCall,
  now: Int,
) -> Dict(String, Asked) {
  dict.insert(asked, passage(call), Asked(account_id: call.account_id, at: now))
}

/// What is left of `asked` once a scan has read one account's open records:
/// the records of that account the view no longer names have been written,
/// and are forgotten. Other accounts' are not the scan's to judge.
pub fn named(
  asked: Dict(String, Asked),
  account_id: String,
  passages: List(String),
) -> Dict(String, Asked) {
  let still = set.from_list(passages)
  dict.filter(asked, fn(passage, entry) {
    entry.account_id != account_id || set.contains(still, passage)
  })
}

/// What is left of `asked` once the records asked about more than
/// `retry_s` ago are forgotten.
pub fn expired(asked: Dict(String, Asked), now: Int) -> Dict(String, Asked) {
  dict.filter(asked, fn(_passage, entry) { now - entry.at < retry_s })
}

fn say(call: OpenCall, ended: Option(Int)) -> Nil {
  system.log(
    "call "
    <> call.call_id
    <> " of account "
    <> call.account_id
    <> case call.picked_up {
      True -> " was picked up by "
      False -> " was answered by "
    }
    <> call.agent_id
    <> " and never closed: "
    <> case ended {
      Some(_) -> "the caller is on no switch, closing it here"
      None -> "the caller is still on a switch, watching for the end"
    },
  )
}

/// The caller as a `Member` again, out of their own record.
///
/// The message they arrived on was settled by the node that answered them,
/// so the delivery settles nothing; the call is the identifier and no more,
/// because the `kapps_call` the callflow published went with that node. A
/// call rebuilt this way can be watched and written about but not
/// commanded.
pub fn rebuilt(call: OpenCall) -> types.Member {
  Member(
    account_id: call.account_id,
    queue_id: call.queue_id,
    call_id: call.call_id,
    call: doc.object([#("Call-ID", doc.String(call.call_id))]),
    priority: 0,
    joined: call.joined,
    callflow_node: "",
    caller_id_name: None,
    caller_id_number: None,
    handoff_id: member.handoff_of(call.call_id, call.joined),
    branches: doc.object([]),
    delivery: member.no_delivery(),
  )
}

// --- The dispatchers -------------------------------------------------------

/// Every dispatcher on this node, across every shard it holds.
fn dispatchers(state: State) -> List(#(String, Subject(dispatcher.Message))) {
  shards.all(state.shards)
  |> list.filter(shard.holds)
  |> list.flat_map(shard.dispatchers)
}

fn dispatcher_for(
  state: State,
  account_id: String,
) -> Result(Subject(dispatcher.Message), Nil) {
  case
    shard.dispatcher(shards.of_account(account_id, state.shards), account_id)
  {
    Ok(to) -> Ok(to)
    Error(_) -> Error(Nil)
  }
}

/// How many dispatchers this node is running, for `sup`.
pub fn count(shards_count: Int) -> Int {
  shards.all(shards_count)
  |> list.filter(shard.holds)
  |> list.flat_map(shard.dispatchers)
  |> list.length
}

/// The sweep interval as a line for `sup`.
pub fn describe(interval_s: Int) -> String {
  "sweeping every " <> int.to_string(interval_s) <> "s"
}
