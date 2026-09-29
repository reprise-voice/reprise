//// One shard, while this node holds it.
////
//// A shard is held by holding the exclusive consumer on its member queue,
//// and this is the tree that holds it: a supervisor of its own per shard,
//// `one_for_all`, with two children. The shard actor holds every member
//// delivery that has not been settled and hosts the dispatchers; the
//// member listener consumes the shard's queue, exclusively, and hands the
//// actor what arrives. The node's placement (`callcenter/placement`)
//// starts the tree when the shard is free and this node should have it, and
//// gives it up when another node should.
////
//// The two are one failure boundary because neither makes sense without
//// the other. A delivery is only good on the channel it came on, so a
//// listener that loses its channel, or is refused or cancelled, ends rather
//// than reconnect underneath an actor still holding handles to the old one,
//// and the tree ends with it; the broker has already given back everything
//// the old channel had unacked, and the placement takes the shard again on
//// a fresh channel if it is still this node's and still free. An actor that
//// crashes restarts both, which is the same redelivery. OTP does the
//// counting: a tree that restarts more than `restart_intensity` times in
//// `restart_period_s` seconds ends with `shutdown`, and the placement sees it
//// go.
////
//// Holding the members unacked is the point: the broker keeps them, and
//// the moment this node's channel goes they are redelivered to whichever
//// node consumes next.
////
//// The dispatchers -- one actor per account, started on that account's
//// first member and kept for as long as the shard is held here -- are the
//// shard actor's own, linked to it, because they are exactly as long-lived
//// as the shard: losing it has to take them with it, or two nodes would
//// dispatch for one account. The actor traps exits, so a dispatcher
//// crashing is a message here: that account's dispatcher is started again
//// and handed the account's callers, who are still held here, and no other
//// account notices. A caller that crashes their dispatcher every time it
//// takes them in is settled after `quarantine_after` crashes and dispatched
//// no more; an account whose dispatcher keeps crashing with no caller to
//// blame -- in a dispatch pass, on a tick, on a reply -- ends the actor after
//// `storm_limit`, which is the tree restarting and the members coming back. The supervisor's shutdown is a
//// message here too, on which every dispatcher is asked to stop, waited
//// for, and killed if it will not go.
////
//// The shard actor is the one thing that settles a member. A dispatcher
//// asks it to (`Settle`), and settling a call already settled is nothing:
//// a member is acked once, whichever of a cancel, a dispatcher's own
//// settlement, or an operator's hand asks first. Settling one twice is not
//// harmless: the broker closes the channel, and everything unacked on it is
//// redelivered.
////
//// A member is held under its account and its call id together, and
//// everything that settles one names both. Accounts share a shard, and a
//// call id is only a string somebody sent: a cancel from one account for
//// another account's call id settles nothing, and the other account's
//// dispatcher never hears of it.
////
//// Every question this actor asks a dispatcher is asked with
//// `callcenter/ask` and never `process.call`: a dispatcher that has gone is
//// an answer here and not this actor's crash. A caller and a cancel are not
//// questions at all: the account's dispatcher is told, and this actor does
//// not wait, so that one account's slow dispatcher holds up no other
//// account on the shard.

import callcenter/ask
import callcenter/call/actor as call_actor
import callcenter/call/calls
import callcenter/dispatcher
import callcenter/dispatcher/config as dispatcher_config
import callcenter/fields
import callcenter/member.{type Member}
import callcenter/records
import callcenter/shards
import callcenter/stall
import callcenter/system
import callcenter/tombstones.{type Tombstones}
import callcenter/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import kazoo/doc.{type Value}
import kazoo/listener.{type Delivery}
import kazoo/modb
import kazoo/util

/// What the shard actor is asked.
pub type Message {
  /// A caller arrived on the member queue. The delivery is handed over
  /// unsettled and stays that way; the message itself comes with it, because
  /// the dispatcher's own type is built from more of it than the shard reads.
  Arrived(
    arrival: Member,
    message: Value,
    delivery: Delivery,
    done: Subject(Nil),
  )
  /// The caller who joined the queue at `joined_at` left it at
  /// `cancelled_at`, Gregorian seconds; a sender of an older release says
  /// neither, and the cancel is taken as made when it reached the shard and
  /// for whichever passage it can be. Settles the `member_call` being held
  /// for that passage of that call of that account, then the
  /// cancel's own `delivery`, and answers whether a member was settled.
  ///
  /// The cancel is settled here, once it has been dealt with, and nowhere
  /// else: a cancel that never reached this actor -- it had gone, or went
  /// with the cancel still in its mailbox -- stays on the channel and goes
  /// back to the broker with it, beside the `member_call` it cancels.
  Cancelled(
    account_id: String,
    call_id: String,
    queue_id: String,
    reason: String,
    joined_at: Option(Int),
    cancelled_at: Option(Int),
    delivery: Delivery,
    done: Subject(Bool),
  )
  /// A caller's actor says the caller left a queue without an agent: a key,
  /// a clock, a hang-up, a bridge somebody else made. Settled as the
  /// caller's cancel settled it, and their dispatcher told.
  CallerLeft(member: types.Member, reason: types.CancelReason)
  /// A dispatcher is done with a caller -- their call has ended, or they
  /// have left -- and their member may be settled. Nothing when it already was,
  /// and nothing when the delivery held for the call is not this one: a
  /// caller who left and came back is a new delivery, and a late word about
  /// the old one must not settle the new.
  Settle(account_id: String, call_id: String, delivery: Delivery)
  /// A dispatcher, `by`, has started on a caller it was handed. Whatever
  /// crashes it before it says `Digested` is that caller arriving.
  Digesting(
    account_id: String,
    call_id: String,
    delivery: Delivery,
    by: Subject(dispatcher.Message),
  )
  /// A dispatcher has digested a caller it was handed: taken them in, and
  /// not yet run the pass after. Whatever crashes it after this is not that
  /// caller arriving: the pass is every caller's and every agent's.
  Digested(account_id: String, call_id: String, delivery: Delivery)
  /// Take a held member of an account out by hand, as a cancel would: see
  /// `release`.
  ReleaseByHand(account_id: String, call_id: String, done: Subject(Bool))
  /// What this shard is holding, or nothing while it is not yet this
  /// node's: the asker may have checked an actor this one has replaced.
  Report(done: Subject(Option(Held)))
  /// The member listener is consuming the queue: the shard is this node's.
  Consuming
  /// Whether the shard is this node's yet.
  IsHeld(done: Subject(Bool))
  /// The dispatcher for an account, started if this shard has none and
  /// `start` says one may be.
  Dispatcher(
    account_id: String,
    start: Bool,
    done: Subject(Option(Subject(dispatcher.Message))),
  )
  /// Every dispatcher this shard is running, for the sweep and for `sup`.
  Dispatchers(done: Subject(List(#(String, Subject(dispatcher.Message)))))
  /// Let the shard go on purpose: it is assigned to another node, which has
  /// asked for it (`callcenter/placement`).
  ///
  /// It is refused -- `False`, and the shard stays where it is -- while an
  /// agent is being rung on this shard. `True` is the dispatchers
  /// stopped and the shard releasing: it starts no dispatcher and hands no
  /// caller over from then on, and ends its own tree, so that the members
  /// go back to the broker with the listener's channel whether or not
  /// whoever asked is still waiting for the answer.
  GiveUp(done: Subject(Bool))
  /// A linked process ended: the supervisor shutting this actor down, or a
  /// dispatcher going.
  Exited(pid: Pid, reason: process.ExitReason)
  /// The node stood still (`callcenter/stall`): look whether this tree may
  /// still act for the shard.
  StoodStill
}

/// What a shard is holding, for `callcenter_maintenance:status/0` and the
/// status responder.
pub type Held {
  Held(shard: Int, queue: String, call_ids: List(String))
}

type State {
  State(
    shard: Int,
    /// The supervisor this actor runs under, whose shutdown is the one exit
    /// this actor answers by stopping.
    parent: Pid,
    /// Whether the member listener has the queue. Until it has, the shard
    /// is nobody's: another node may hold the consumer, and this tree may
    /// be about to find that out and give up. Nothing answers for the shard
    /// before this.
    consuming: Bool,
    /// Whether the shard has agreed to be given up and is ending its tree.
    /// From then on it is nobody's again: no dispatcher is started and no
    /// caller handed over, and whatever arrives is held, to go back to the
    /// broker with the channel.
    releasing: Bool,
    /// Every member delivered and not settled, newest first, under its
    /// account and call id: the ledger, and the only one.
    holding: List(Entry),
    /// Account id to its dispatcher, started on the account's first member
    /// and kept until the shard is let go.
    dispatchers: Dict(String, Subject(dispatcher.Message)),
    /// Account id to the caller its dispatcher has said it is digesting and
    /// not yet that it has digested: the caller it is taking in, if it is
    /// taking one in. A dispatcher does one thing at a time, and what it
    /// says reaches here before its exit does, so when it crashes this is
    /// the caller it crashed on, and a caller handed over and not yet
    /// started on is nobody's culprit.
    digesting: Dict(String, #(String, Delivery)),
    /// When each held member's dispatcher crashed while digesting them, in
    /// the last `crash_window_ms`.
    strikes: Dict(Key, List(Int)),
    /// When each account's dispatcher ended without being asked to, in the
    /// last `crash_window_ms`.
    ends: Dict(String, List(Int)),
    /// The accounts whose dispatcher ended without being asked to, with
    /// callers of the account held, and could not be started again. The
    /// callers it had may have offers still ringing, or answered, on the
    /// switch, and whichever dispatcher is started for the account next --
    /// by its next caller, or by the sweep, however long after -- reads
    /// their records before it rings anybody. Cleared when one starts.
    orphaned: Set(String),
    /// The cancels that settled nothing, for the `member_call` that arrives
    /// after its own cancel.
    tombstones: Tombstones,
    /// Everything this shard reaches outside itself.
    hooks: Hooks,
    /// When this actor started, in the VM's monotonic milliseconds: a
    /// stall of the node after it is the shard maybe lost (`hooks.fresh`).
    since: Int,
  )
}

/// What a member is held under: its account, then its call id.
type Key =
  #(String, String)

/// One member held: its key, the delivery that settles it, which passage
/// through which queue it is, and the caller as their dispatcher was handed
/// them -- `None` for a member held here and not dispatched -- so that a
/// dispatcher started again can be handed them again.
type Entry {
  Entry(
    key: Key,
    delivery: Delivery,
    queue_id: String,
    joined_at: Int,
    member: Option(types.Member),
  )
}

/// How a shard rings an agent.
///
/// Held here and handed to every dispatcher this shard starts, so that the
/// whole tree can be built and run against a fake offer. `callcenter.gleam`
/// supplies the real one.
pub type StartOffer =
  fn(types.OfferRequest) -> Result(Pid, String)

/// How a dispatcher for an account is started, given the function it settles
/// a caller with.
pub type StartDispatcher =
  fn(String, fn(types.Member) -> Nil) ->
    Result(Subject(dispatcher.Message), String)

/// Everything a shard reaches outside itself, given rather than found: how
/// an agent is rung, how a dispatcher is started, how the member queue is
/// consumed and how a delivery is settled.
///
/// On a node every one of these is the real thing, from `hooks`. In a test
/// they are fakes, which is what lets the tree itself -- the supervisor, the
/// actor that holds the members and asks the dispatchers -- be started and
/// driven with no broker anywhere near.
pub type Hooks {
  Hooks(
    start_offer: StartOffer,
    start_dispatcher: StartDispatcher,
    /// The shard's calls (`callcenter/call/calls`): the actors of its
    /// callers, as the last child of its tree, told where a caller who
    /// leaves is settled. `None` where there is nothing to command.
    calls: fn(Int, Subject(Message)) -> Option(ChildSpecification(Nil)),
    /// The shard's member listener, as a child beside the actor, handing
    /// its deliveries to the subject. `None` where there is no broker.
    consumer: fn(Int, Subject(Message)) -> Option(ChildSpecification(Nil)),
    /// Settle a delivery: `listener.ack` on a node.
    settle: fn(Delivery) -> Nil,
    /// The node's shard count, which a member's account is hashed with to
    /// check that it belongs here. `None` checks nothing.
    count: Option(Int),
    /// Whether a process of the shard started at this monotonic millisecond
    /// may still act for it: `stall.fresh` on a node.
    fresh: fn(Int) -> Bool,
  )
}

/// The node's own hooks: real dispatchers, the real member listener, the
/// shard's call actors, the node's count, and the offer given.
pub fn hooks(count: Int, start_offer: StartOffer) -> Hooks {
  Hooks(
    start_offer: start_offer,
    start_dispatcher: fn(account_id, settle) {
      let config = dispatcher.config(system.live(), account_id)
      let registry = calls.of_shard(shards.of_account(account_id, count))
      dispatcher.start(
        dispatcher_config.Config(
          ..config,
          settle: settle,
          calls: dispatcher_config.calls_of(registry),
        ),
        start_offer: start_offer,
      )
      |> result.map(fn(started) { started.data })
      |> result.map_error(string.inspect)
    },
    calls: fn(shard, to) {
      Some(calls.supervised(
        shard,
        call_actor.live(system.live(), fn(member, reason) {
          process.send(to, CallerLeft(member, reason))
        }),
      ))
    },
    consumer: fn(shard, to) {
      Some(
        member_listener(shard, to)
        |> listener.supervised
        |> supervision.map_data(fn(_server) { Nil }),
      )
    },
    settle: listener.ack,
    count: Some(count),
    fresh: stall.fresh,
  )
}

/// No offers: every offer fails, which the dispatcher logs and treats as an
/// offer it could not make.
pub fn no_offers(_request: types.OfferRequest) -> Result(Pid, String) {
  Error("no call actors on this node")
}

/// No call actors: a tree with nothing to command, which is every test that
/// is not about the calls.
pub fn no_calls(
  _shard: Int,
  _to: Subject(Message),
) -> Option(ChildSpecification(Nil)) {
  None
}

/// The registered name of the shard actor for a shard.
///
/// One atom per shard, minted once when the application starts and bounded
/// by `system_config/callcenter.shards`, which is what makes building it
/// from a number acceptable where `kazoo/util.name` asks for a literal.
pub fn name(shard: Int) -> Name(Message) {
  util.name("callcenter_shard_" <> int.to_string(shard))
}

/// The registered name of the shard's supervisor.
fn tree_name(shard: Int) -> Name(Nil) {
  util.name("callcenter_shard_tree_" <> int.to_string(shard))
}

/// Whether this node is dispatching for that shard: its tree is up and its
/// member listener has the queue. A tree that is up and not yet consuming
/// is not holding anything, and may be about to lose the race for it.
pub fn holds(shard: Int) -> Bool {
  holder(shard) |> result.is_ok
}

/// Tell the shard's actor, if one is running here, that the node stood
/// still: a tree started before the stall ends and is started again, fresh.
pub fn stood_still(shard: Int) -> Nil {
  // Sent to the process found and not to the name: a fenced actor ends and
  // gives the name up at any moment after a stall, and a send to a name
  // nobody holds would end the watch that sends it.
  case process.named(name(shard)) {
    Ok(pid) ->
      process.send(
        process.unsafely_create_subject(pid, name_tag(name(shard))),
        StoodStill,
      )
    Error(Nil) -> Nil
  }
}

/// The shard actor, when this node is dispatching for the shard.
pub fn holder(shard: Int) -> Result(Pid, Nil) {
  case process.named(name(shard)) {
    Error(_) -> Error(Nil)
    Ok(pid) ->
      case ask.call(subject(shard), 1000, IsHeld) {
        Ok(True) -> Ok(pid)
        _not_yet -> Error(Nil)
      }
  }
}

/// The shard's supervisor, while one is running on this node, consuming or
/// not: what a placement that was restarted finds and takes over watching.
pub fn tree(shard: Int) -> Result(Pid, Nil) {
  process.named(tree_name(shard))
}

/// Take the shard up: start its supervisor and, under it, the actor and the
/// member listener. Answers the supervisor's pid, so that whoever started
/// it can watch it. The supervisor is linked to the caller, as any started
/// process is; a caller that means to outlive it unlinks and watches it
/// with a monitor instead, which is what the placement does.
///
/// A tree already running here is not started twice; the old one is
/// released first, so that a take after a tree that ended without its
/// placement noticing starts clean.
pub fn take_using(shard: Int, hooks: Hooks) -> Result(Pid, String) {
  case tree(shard) {
    Ok(_pid) -> {
      system.log(
        "shard "
        <> int.to_string(shard)
        <> " was still held when it was taken again: releasing it first",
      )
      release(shard)
    }
    Error(Nil) -> Nil
  }
  case start_tree(shard, hooks) {
    Ok(pid) -> Ok(pid)
    Error(reason) -> {
      system.log_error(
        "shard " <> int.to_string(shard) <> " could not start: " <> reason,
      )
      Error(reason)
    }
  }
}

/// The shard's supervisor: the actor, then the listener that feeds it, each
/// restarted with the other.
fn start_tree(shard: Int, hooks: Hooks) -> Result(Pid, String) {
  let to = subject(shard)
  let tree =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.restart_tolerance(
      intensity: restart_intensity,
      period: restart_period_s,
    )
    // The listener ending on its own is the shard lost: see `consumer`.
    |> supervisor.auto_shutdown(supervisor.AnySignificant)
  let consumer = hooks.consumer(shard, to)
  // With no listener to wait for, there is nothing that could refuse the
  // shard: it is held the moment the actor is up, every time it is up.
  let held_at_once = option.is_none(consumer)
  let tree =
    tree
    |> supervisor.add(
      supervision.worker(fn() {
        // The supervisor is the process this closure runs in, and the
        // actor's parent: the one exit the actor stops for.
        start_actor(shard, process.self(), hooks, held_at_once)
      })
      |> supervision.timeout(ms: release_timeout_ms),
    )
  // A listener that loses its channel, is refused the consumer or has it
  // cancelled ends normally, and is not started again: the whole tree ends
  // with it, once, and whoever looks at the shard next -- this node's
  // placement or another's -- takes it on a fresh channel. Restarted here
  // instead, a broker restart was five refusals in a row and a tree that
  // gave up after the fifth.
  let tree = case consumer {
    Some(consumer) ->
      supervisor.add(
        tree,
        consumer
          |> supervision.restart(supervision.Transient)
          |> supervision.significant(True),
      )
    None -> tree
  }
  // Last, so that everything that tells an actor something is up before
  // it, and so that the actors are stopped first when the shard goes: no
  // caller of a shard this node no longer holds is commanded from here.
  let tree = case hooks.calls(shard, to) {
    Some(calls) -> supervisor.add(tree, calls)
    None -> tree
  }
  case supervisor.start(tree) {
    Error(error) -> Error(string.inspect(error))
    Ok(started) -> {
      let _ = process.register(started.pid, tree_name(shard))
      Ok(started.pid)
    }
  }
}

/// How many restarts of the boundary in how many seconds is a shard that is
/// not going to come right here. A crashed actor costs one restart and a
/// redelivery of the shard's members; five of those in a minute is an
/// account this node cannot get past, and the tree ends. A dispatcher
/// crashing is not one of them until it is a storm (`storm_limit`).
const restart_intensity = 5

const restart_period_s = 60

/// Give the shard up. The supervisor stops the listener and then the actor,
/// which stops its dispatchers; everything the shard was holding goes back to
/// the broker with the listener's channel, for whoever consumes next, and
/// nothing here acks anything on the way out.
pub fn release(shard: Int) -> Nil {
  case process.named(tree_name(shard)) {
    Error(_) -> Nil
    Ok(pid) -> release_tree(shard, pid)
  }
}

/// End a shard's tree from inside its actor: from a process of its own,
/// because the supervisor stops the actor on the way and would wait for an
/// actor that was waiting for it.
fn end_tree(shard: Int, tree: Pid) -> Nil {
  let _ = process.spawn_unlinked(fn() { release_tree(shard, tree) })
  Nil
}

fn release_tree(shard: Int, pid: Pid) -> Nil {
  case terminate(pid, release_timeout_ms + stop_timeout_ms) {
    True -> system.log("shard " <> int.to_string(shard) <> " released")
    // Its actor is given `release_timeout_ms` to stop and is then
    // killed by the supervisor, so this is a supervisor that is itself
    // stuck. Killed; its children hear the parent go and end.
    False -> {
      system.log_error(
        "shard "
        <> int.to_string(shard)
        <> " did not release within "
        <> int.to_string(release_timeout_ms + stop_timeout_ms)
        <> " ms: killing its supervisor",
      )
      process.kill(pid)
    }
  }
}

/// How long the actor is given to stop its dispatchers when its supervisor
/// shuts it down: every dispatcher on the shard at once, given
/// `stop_timeout_ms` and then killed, behind whatever the actor was doing
/// when the shutdown reached it.
const release_timeout_ms = 30_000

/// Let the shard go on purpose, because another node is assigned it and has
/// asked for it: the dispatchers are stopped and the tree with them, and the
/// members go back to the broker with the listener's channel for that node
/// to take.
///
/// A shard always agrees. It stops its dispatchers, so that nobody is rung
/// from here any more, and gives its callers' actors `quiesce_ms` to finish
/// what the next holder could not see -- an originate some of whose legs
/// have not shown, a bridge on its way (`core.steady`) -- and goes. The
/// node taking it finds every caller where they stand on the switch and
/// takes on whatever is going on for them, a ring or a conversation
/// included (*Takeover*). A shard this node does not hold is `True`: there
/// is nothing here to let go of.
///
/// An answer that does not come in `give_up_timeout_ms` is `False`, and the
/// placement keeps watching the tree: if the shard does agree once it gets
/// to the question, it ends its own tree, and the placement sees that as
/// the tree going down. `True` waits for the tree to be gone, so that its
/// channel has closed and the members are back on the broker when this
/// answers.
pub fn give_up(shard: Int) -> Bool {
  case tree(shard) {
    Error(_) -> True
    Ok(_pid) ->
      case ask.call(subject(shard), give_up_timeout_ms, GiveUp) {
        Ok(True) -> {
          release(shard)
          True
        }
        Ok(False) -> False
        // Gone while being asked, or busy: not handed over this time.
        Error(_) -> False
      }
  }
}

const give_up_timeout_ms = 10_000

/// How long a shard being handed over gives its callers' actors to be
/// steady. What is not steady by then goes as it is: an unseen leg rings
/// out, and a bridge left half done is found by the next holder.
const quiesce_ms = 3000

/// Every dispatcher a shard this node holds is running.
pub fn dispatchers(shard: Int) -> List(#(String, Subject(dispatcher.Message))) {
  case holds(shard) {
    False -> []
    True -> ask.call(subject(shard), 5000, Dispatchers) |> result.unwrap([])
  }
}

/// The dispatcher for an account on a shard this node holds, without
/// starting one: a status query is not a reason to begin dispatching.
pub fn dispatcher(
  shard: Int,
  account_id: String,
) -> Result(Subject(dispatcher.Message), Nil) {
  case holds(shard) {
    False -> Error(Nil)
    True ->
      case ask.call(subject(shard), 5000, Dispatcher(account_id, False, _)) {
        Ok(Some(to)) -> Ok(to)
        _none -> Error(Nil)
      }
  }
}

/// Tell the dispatcher of an account on a shard this node holds that one of
/// the account's queues was deleted. Nothing when this node does not hold
/// the shard, which is every node but one, or the account has no dispatcher
/// here, which is an account nobody is waiting in.
pub fn queue_deleted(shard: Int, account_id: String, queue_id: String) -> Nil {
  case dispatcher(shard, account_id) {
    Ok(to) -> process.send(to, dispatcher.QueueDeleted(queue_id))
    Error(Nil) -> Nil
  }
}

/// The same, starting one if the shard has none.
///
/// The one caller is the sweep, closing a call answered on a node that
/// died: the caller's member message was settled when they were answered,
/// so nothing else will ever bring that account a dispatcher, and the
/// wrap-up, the counters and the events all belong to one.
pub fn start_dispatcher(
  shard: Int,
  account_id: String,
) -> Result(Subject(dispatcher.Message), Nil) {
  case holds(shard) {
    False -> Error(Nil)
    True ->
      case ask.call(subject(shard), 30_000, Dispatcher(account_id, True, _)) {
        Ok(Some(to)) -> Ok(to)
        _none -> Error(Nil)
      }
  }
}

/// How many members this node is holding for a shard.
pub fn waiting(shard: Int) -> Int {
  case held(shard) {
    None -> 0
    Some(held) -> list.length(held.call_ids)
  }
}

/// What that shard is holding, or nothing when this node does not hold it.
pub fn held(shard: Int) -> Option(Held) {
  // One question of one actor, which answers for itself whether the shard
  // is its yet; a check made first could be of an actor since replaced.
  case process.named(name(shard)) {
    Error(_) -> None
    Ok(_pid) -> ask.call(subject(shard), 5000, Report) |> result.unwrap(None)
  }
}

/// Take one caller of an account out of the queue by hand, the way their
/// cancel would: the member is settled here, and the account's dispatcher is
/// told they left (`dispatcher.Left`), which drops them, frees whoever was
/// being rung for them and closes their record as a `hangup`. `False` when
/// this shard was not holding that call for that account.
///
/// What `sup callcenter_maintenance release_member` and `ack_member` are.
/// `ack_member` used to settle the member and stop there, and the caller
/// went on being offered with nothing on the broker behind them.
pub fn release_member(shard: Int, account_id: String, call_id: String) -> Bool {
  case holds(shard) {
    False -> False
    True ->
      ask.call(subject(shard), 5000, ReleaseByHand(account_id, call_id, _))
      |> result.unwrap(False)
  }
}

/// The reason a caller released by hand leaves with, as a cancel spells it:
/// `hangup`, what an operator reaching for this is nearly always clearing up
/// after.
const released_by_hand = "hangup"

fn subject(shard: Int) -> Subject(Message) {
  process.named_subject(name(shard))
}

// --- The actor -------------------------------------------------------------

fn start_actor(
  shard: Int,
  parent: Pid,
  hooks: Hooks,
  held_at_once: Bool,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(30_000, fn(self) {
    // Trapped, so that the supervisor's shutdown and a dispatcher's end are
    // messages here rather than this process's own end.
    process.trap_exits(True)
    actor.initialised(State(
      shard: shard,
      parent: parent,
      consuming: held_at_once,
      releasing: False,
      holding: [],
      dispatchers: dict.new(),
      digesting: dict.new(),
      strikes: dict.new(),
      ends: dict.new(),
      orphaned: set.new(),
      tombstones: tombstones.new(),
      hooks: hooks,
      since: stall.now_ms(),
    ))
    |> actor.selecting(
      process.new_selector()
      |> process.select(self)
      |> process.select_trapped_exits(fn(exit) { Exited(exit.pid, exit.reason) }),
    )
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name(shard))
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    // The supervisor's shutdown is answered whatever else is so.
    Exited(pid, _reason) if pid == state.parent -> act(state, message)
    _ ->
      case state.hooks.fresh(state.since) {
        True -> act(state, message)
        // The node stood still since this tree started, and the broker may
        // have given the shard to another node meanwhile: nothing more is
        // done for it from here, not even settling a member. The tree ends
        // and starts again, the listener's channel going with it, so that
        // the shard is either taken back fresh or found to be somebody
        // else's (`callcenter/stall`).
        False -> {
          system.log(
            "shard "
            <> int.to_string(state.shard)
            <> ": this node stood still since the shard was taken:"
            <> " taking it again",
          )
          actor.stop_abnormal(
            "shard " <> int.to_string(state.shard) <> " fenced after a stall",
          )
        }
      }
  }
}

/// What the shard does with a message while it may still act for the shard.
fn act(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    // Looked at on the way in.
    StoodStill -> actor.continue(state)

    Arrived(arrival, message, delivery, done) -> {
      system.log(
        "member for account "
        <> arrival.account_id
        <> " queue "
        <> arrival.queue_id
        <> " call "
        <> arrival.call_id
        <> " received on shard "
        <> int.to_string(state.shard),
      )
      process.send(done, Nil)
      actor.continue(arrived(state, message, delivery))
    }

    // Answered here and not by whoever asked: the asker may have checked a
    // shard actor that has since been replaced by this one, and this one
    // may be about to lose the shard. A dispatcher started here before the
    // listener has the queue would act -- adopt an orphan, close its record
    // -- for a shard that is somebody else's.
    Dispatcher(_account_id, _start, done)
      if !state.consuming || state.releasing
    -> {
      process.send(done, None)
      actor.continue(state)
    }

    Dispatcher(account_id, start, done) -> {
      // One started here is handed whatever callers of the account are
      // held, as one started by an arrival is.
      let state = case start && !dict.has_key(state.dispatchers, account_id) {
        True -> start_for(state, account_id)
        False -> state
      }
      process.send(
        done,
        dict.get(state.dispatchers, account_id) |> option.from_result,
      )
      actor.continue(state)
    }

    Dispatchers(done) -> {
      process.send(done, case state.consuming && !state.releasing {
        True -> dict.to_list(state.dispatchers)
        False -> []
      })
      actor.continue(state)
    }

    Consuming -> {
      system.log("shard " <> int.to_string(state.shard) <> " is held here")
      actor.continue(State(..state, consuming: True))
    }

    IsHeld(done) -> {
      process.send(done, state.consuming && !state.releasing)
      actor.continue(state)
    }

    Cancelled(
      account_id,
      call_id,
      queue_id,
      reason,
      joined_at,
      cancelled_at,
      delivery,
      done,
    ) -> {
      let #(settled, state) =
        cancelled(
          state,
          account_id,
          call_id,
          queue_id,
          reason,
          joined_at,
          cancelled_at,
        )
      // After the member it names, and after the note of it when it named
      // nothing held: acked, the cancel is gone from the broker, and what it
      // did has to have been done.
      state.hooks.settle(delivery)
      process.send(done, settled)
      actor.continue(state)
    }

    CallerLeft(caller, reason) -> {
      let #(_settled, state) =
        cancelled(
          state,
          caller.account_id,
          caller.call_id,
          caller.queue_id,
          records.reason_to_string(reason),
          Some(caller.joined),
          Some(modb.now()),
        )
      actor.continue(state)
    }

    Settle(account_id, call_id, delivery) -> {
      // Only the delivery the dispatcher was handed. The call may since
      // have left and come back as a newer one, held here under the same
      // id, and that one is not settled by a word about the old.
      let key = #(account_id, call_id)
      let holding = case find(state.holding, key) {
        Ok(held) if held.delivery == delivery -> {
          state.hooks.settle(held.delivery)
          forget(state.holding, key)
        }
        _other_or_none -> state.holding
      }
      actor.continue(State(..state, holding: holding))
    }

    // Only from the account's dispatcher of the moment: one stopped and
    // forgotten may still have a word or two in this mailbox.
    Digesting(account_id, call_id, delivery, by) ->
      case dict.get(state.dispatchers, account_id) {
        Ok(to) if to == by ->
          actor.continue(
            State(
              ..state,
              digesting: dict.insert(state.digesting, account_id, #(
                call_id,
                delivery,
              )),
            ),
          )
        _another -> actor.continue(state)
      }

    Digested(account_id, call_id, delivery) ->
      case dict.get(state.digesting, account_id) {
        Ok(caller) if caller == #(call_id, delivery) ->
          actor.continue(
            State(..state, digesting: dict.delete(state.digesting, account_id)),
          )
        _another -> actor.continue(state)
      }

    ReleaseByHand(account_id, call_id, done) -> {
      let #(settled, holding) = drop(state, #(account_id, call_id))
      case settled {
        True -> {
          // What a cancel does, and for the same reason: a member settled
          // here and not told to the dispatcher left the caller being
          // offered with nothing on the broker behind them.
          left(state, account_id, call_id, released_by_hand)
          system.log(
            "member call "
            <> call_id
            <> " of account "
            <> account_id
            <> " released by hand on shard "
            <> int.to_string(state.shard),
          )
        }
        False -> Nil
      }
      process.send(done, settled)
      actor.continue(State(..state, holding: holding))
    }

    Report(done) -> {
      process.send(done, case state.consuming && !state.releasing {
        False -> None
        True ->
          Some(Held(
            shard: state.shard,
            queue: shards.member_queue(state.shard),
            call_ids: list.map(state.holding, fn(entry) { entry.key.1 }),
          ))
      })
      actor.continue(state)
    }

    // Already going.
    GiveUp(done) if state.releasing -> {
      process.send(done, True)
      actor.continue(state)
    }

    GiveUp(done) -> {
      // Nobody is rung from here any more once the dispatchers are stopped;
      // then the callers' actors finish what the next holder could not see.
      // Everything this shard is holding goes back to the broker when the
      // member listener's channel closes with the supervisor. The shard
      // ends its tree itself rather than leave it to whoever asked, who may
      // have stopped waiting for this answer: a tree that has stopped every
      // dispatcher it had must not be left running for a caller arriving in
      // between to start them again.
      let state = stop_dispatchers(state)
      case calls.quiesce(state.shard, quiesce_ms) {
        0 -> Nil
        unsteady ->
          system.log(
            "shard "
            <> int.to_string(state.shard)
            <> " handed over with "
            <> int.to_string(unsteady)
            <> " call(s) not steady after "
            <> int.to_string(quiesce_ms)
            <> " ms",
          )
      }
      process.send(done, True)
      system.log(
        "shard " <> int.to_string(state.shard) <> " given up: releasing",
      )
      end_tree(state.shard, state.parent)
      actor.continue(State(..state, releasing: True))
    }

    Exited(pid, _reason) if pid == state.parent -> {
      // The supervisor is shutting this actor down: this node is letting
      // the shard go, or the listener beside it went and both are being
      // started again.
      // Nothing is acked on the way out. Everything held goes back to the
      // broker with the listener's channel, for whoever consumes next.
      let state = stop_dispatchers(state)
      stop_shutdown()
      actor.continue(state)
    }

    // Given up: every dispatcher was stopped, and the tree is ending.
    Exited(_pid, _reason) if state.releasing -> actor.continue(state)

    Exited(pid, reason) ->
      case account_of(state, pid), reason {
        Some(account_id), _ending -> ended(state, account_id, reason)
        // Not on the books: a dispatcher already stopped and forgotten,
        // ending as it was told to.
        None, process.Normal -> actor.continue(state)
        // Nothing else is linked here, and a process linked here that
        // crashed is nothing this actor knows what to do about: it ends
        // with it, and the tree starts again.
        None, _crashed ->
          actor.stop_abnormal(
            "a process linked to shard "
            <> int.to_string(state.shard)
            <> " that is none of its dispatchers crashed: "
            <> string.inspect(reason),
          )
      }
  }
}

/// A member arriving: handed to its account's dispatcher and held, or
/// settled at once when it is nothing anybody could dispatch.
///
/// The delivery is handed to the dispatcher unsettled. The dispatcher asks
/// for it to be settled when the caller has an agent, or when they have
/// left; a cancel settles it here without asking.
fn arrived(state: State, message: Value, delivery: Delivery) -> State {
  case member.arrival(message, delivery) {
    // Not a caller: no call id, no account, or not a `member_call` at all.
    // Nothing on this node will ever dispatch it or name it in a cancel, and
    // held it would sit unacked on the channel for as long as the shard is
    // here and come back on every failover. Settled, and said so.
    None -> {
      state.hooks.settle(delivery)
      system.log_error(
        "a message on shard "
        <> int.to_string(state.shard)
        <> " is not a caller and was settled without being dispatched: "
        <> doc.to_string(message),
      )
      state
    }
    Some(caller) -> {
      let key = #(caller.account_id, caller.call_id)
      // A shard being given up hands nobody over: the caller is held, and
      // goes back to the broker with the channel for the node that takes
      // the shard next.
      let dispatch =
        !state.releasing
        && routed_here(state, caller, fields.some_int(message, ["Shard-Count"]))
      case
        tombstones.bury(
          state.tombstones,
          #(caller.account_id, caller.call_id, caller.queue_id),
          joined_at: caller.joined,
          now_ms: monotonic_ms(),
        ),
        find(state.holding, key)
      {
        // Its cancel got here first: the caller has already left this
        // passage, and a dispatcher that rang for them would ring for
        // somebody who is somewhere else in their callflow by now. The
        // cancel is used up: it buried this passage and buries no other,
        // so a caller sent straight back into the queue, in the same
        // second, is dispatched.
        Ok(tombstones), _held -> {
          state.hooks.settle(caller.delivery)
          system.log(
            "member call "
            <> caller.call_id
            <> " of account "
            <> caller.account_id
            <> " arrived on shard "
            <> int.to_string(state.shard)
            <> " after its own cancel: settled, not dispatched",
          )
          State(..state, tombstones: tombstones)
        }
        Error(Nil), Error(Nil) -> hold(state, caller, key, dispatch)
        Error(Nil), Ok(held) -> again(state, caller, key, held, dispatch)
      }
    }
  }
}

/// Whether a caller's account hashes to this shard under this node's count.
///
/// A member that does not is one a node with another count published: the
/// callflow runs where it runs and hashed the account with its own count.
/// It is held, so that the caller's cancel -- which the same callflow sends
/// to the same queue -- settles it once, and it is not dispatched: this node
/// does not hold the account's shard, and the node that does may be
/// dispatching the account's other callers. Nor is it sent on to the shard
/// this node would have put it in: that shard's holder may count as the
/// sender does and send it back, and the caller's cancel would still come
/// here, so the copy would be a caller nobody ever cancels. Held and not
/// dispatched is the one outcome that neither loses the member nor makes
/// two of it; the caller leaves on their own clocks, and the error in the
/// log is the operator's to act on.
fn routed_here(
  state: State,
  caller: types.Member,
  published: Option(Int),
) -> Bool {
  case state.hooks.count {
    None -> True
    Some(count) ->
      case shards.of_account(caller.account_id, count) {
        shard if shard == state.shard -> True
        shard -> {
          system.log_error(
            "member call "
            <> caller.call_id
            <> " of account "
            <> caller.account_id
            <> " arrived on shard "
            <> int.to_string(state.shard)
            <> ", which is shard "
            <> int.to_string(shard)
            <> " of this node's "
            <> int.to_string(count)
            <> "; the callflow that published it counted "
            <> case published {
              Some(published) -> int.to_string(published)
              None -> "an unknown number of"
            }
            <> " shards. Held and not dispatched: every node has to count the"
            <> " same",
          )
          False
        }
      }
  }
}

/// A caller left a queue. Settles what the shard holds for the call, and
/// tells the account's dispatcher -- unless what is held is a later passage
/// than the one cancelled, which the cancel knows nothing of.
///
/// A cancel that settled nothing is remembered (`callcenter/tombstones`),
/// because its `member_call` may be behind it: two deliveries off one queue
/// reach the shard in either order.
///
/// A cancel that says when the caller joined (`Joined-Timestamp`) is about
/// that passage and no other. What is held for the call is that passage or
/// an earlier one, and settled, or a later one, and kept; an earlier one
/// settled leaves the cancel's own passage to come, and the cancel is
/// remembered for it.
///
/// A cancel from a node that did not say when the caller joined is about
/// whatever passage of that queue joined by the second the caller left. One
/// that did not say when the caller left either is taken to have been made
/// the moment it reached the shard. It is at most that old, so a
/// `member_call` of the passage it cancels, joined before it was made, is
/// still buried; what is given up is a caller who left and came back to the
/// same queue within the same second, whose second `member_call` arrived
/// before their first. That is not a thing a caller does, and the other way
/// round is a caller already gone being rung for.
fn cancelled(
  state: State,
  account_id: String,
  call_id: String,
  queue_id: String,
  reason: String,
  joined: Option(Int),
  cancelled_at: Option(Int),
) -> #(Bool, State) {
  let at = option.lazy_unwrap(cancelled_at, modb.now)
  let key = #(account_id, call_id)
  case find(state.holding, key) {
    Ok(held) ->
      case later_passage(held, queue_id, option.unwrap(joined, at)) {
        False -> {
          state.hooks.settle(held.delivery)
          left(state, account_id, call_id, reason)
          system.log(
            "member call "
            <> call_id
            <> " of account "
            <> account_id
            <> " left shard "
            <> int.to_string(state.shard)
            <> ": "
            <> reason,
          )
          let state = State(..state, holding: forget(state.holding, key))
          #(True, case joined {
            // An earlier passage than the cancel's own, whose member is
            // still to come.
            Some(own) if own != held.joined_at ->
              remember(state, account_id, call_id, queue_id, joined, at)
            _this_one -> state
          })
        }
        True -> {
          system.log(
            "member call "
            <> call_id
            <> " of account "
            <> account_id
            <> " cancelled on shard "
            <> int.to_string(state.shard)
            <> " for an earlier passage than the one held: kept",
          )
          #(False, remember(state, account_id, call_id, queue_id, joined, at))
        }
      }
    Error(Nil) -> {
      // The account's dispatcher is told and not asked: what is left to do
      // about a caller who has gone is its own, and nothing it answers would
      // change what was done here. Only that account's: a call id is news to
      // nobody else, and another account may have sent it.
      left(state, account_id, call_id, reason)
      system.log(
        "member call "
        <> call_id
        <> " of account "
        <> account_id
        <> " cancelled on shard "
        <> int.to_string(state.shard)
        <> " but was not held here: remembered in case it is on its way",
      )
      #(False, remember(state, account_id, call_id, queue_id, joined, at))
    }
  }
}

/// Whether what is held for a call is a later passage than the one a cancel
/// for that queue was about: another queue, or joined after `by` -- the
/// second the cancelled passage joined, when the cancel said, and the second
/// the caller left it when it did not.
fn later_passage(held: Entry, queue_id: String, by: Int) -> Bool {
  { queue_id != "" && held.queue_id != "" && queue_id != held.queue_id }
  || held.joined_at > by
}

fn left(state: State, account_id: String, call_id: String, reason: String) {
  case dict.get(state.dispatchers, account_id) {
    Ok(to) -> process.send(to, dispatcher.Left(call_id, records_reason(reason)))
    Error(Nil) -> Nil
  }
}

fn remember(
  state: State,
  account_id: String,
  call_id: String,
  queue_id: String,
  joined: Option(Int),
  cancelled_at: Int,
) -> State {
  State(
    ..state,
    tombstones: tombstones.note(
      state.tombstones,
      #(account_id, call_id, queue_id),
      joined: joined,
      cancelled_at: cancelled_at,
      now_ms: monotonic_ms(),
    ),
  )
}

/// A member arriving for a call the shard already holds.
///
/// The same caller delivered again -- republished, or the same passage
/// twice -- replaces the one held, and the one held is settled: nothing else
/// will, since a settlement and a cancel both reach only what is held, and
/// left unsettled it would sit on the channel and come back at the next
/// failover as a caller nobody is waiting for. A member of an earlier
/// passage than the one held -- the caller left, came back, and the old
/// message is the one arriving late -- is the one settled instead, and never
/// dispatched.
fn again(
  state: State,
  caller: types.Member,
  key: Key,
  held: Entry,
  dispatch: Bool,
) -> State {
  case caller.joined < held.joined_at {
    True -> {
      state.hooks.settle(caller.delivery)
      system.log(
        "member call "
        <> caller.call_id
        <> " of account "
        <> caller.account_id
        <> " arrived on shard "
        <> int.to_string(state.shard)
        <> " for a passage older than the one held: settled",
      )
      state
    }
    False -> {
      // The very delivery held, handed over twice, is settled by neither.
      case held.delivery == caller.delivery {
        True -> Nil
        False -> state.hooks.settle(held.delivery)
      }
      system.log(
        "member call "
        <> caller.call_id
        <> " of account "
        <> caller.account_id
        <> " arrived again on shard "
        <> int.to_string(state.shard)
        <> ": the delivery held before is settled",
      )
      hold(
        State(..state, holding: forget(state.holding, key)),
        caller,
        key,
        dispatch,
      )
    }
  }
}

/// Hand a caller to their dispatcher, when they are this shard's to
/// dispatch, and hold their delivery.
fn hold(state: State, caller: types.Member, key: Key, dispatch: Bool) -> State {
  let state =
    State(..state, holding: [
      Entry(
        key: key,
        delivery: caller.delivery,
        queue_id: caller.queue_id,
        joined_at: caller.joined,
        member: case dispatch {
          True -> Some(caller)
          False -> None
        },
      ),
      ..state.holding
    ])
  case dispatch {
    True -> hand_over(state, caller)
    False -> state
  }
}

/// Settle the delivery held for an account's call, if there is one, and say
/// whether there was. The whole of settlement: once, here, whoever asked.
fn drop(state: State, key: Key) -> #(Bool, List(Entry)) {
  case find(state.holding, key) {
    Error(_) -> #(False, state.holding)
    Ok(held) -> {
      state.hooks.settle(held.delivery)
      #(True, forget(state.holding, key))
    }
  }
}

fn find(holding: List(Entry), key: Key) -> Result(Entry, Nil) {
  list.find(holding, fn(entry) { entry.key == key })
}

/// Stop holding an account's call without settling it.
fn forget(holding: List(Entry), key: Key) -> List(Entry) {
  list.filter(holding, fn(entry) { entry.key != key })
}

/// An account's dispatcher ended without being asked to: it crashed, or
/// stopped itself.
///
/// Only that account's. Its callers are held here, deliveries and all, and
/// the channel they came on is still open, so nothing has to come back from
/// the broker: a dispatcher is started again and handed every one of them,
/// oldest first, and reads their records before it rings anybody, as a
/// dispatcher handed them by a failover would. Every other account on the
/// shard goes on as it was, offers in flight and all.
///
/// A crash while the dispatcher was taking a caller in -- started on and not
/// yet digested: decoding them, reading their record, taking over an offer
/// left ringing -- is laid at that caller's door. A crash anywhere else,
/// the pass after an arrival included, is laid at nobody's: the pass looks
/// at every caller and agent of the account, and blaming the caller whose
/// arrival happened to run it would quarantine the account's longest
/// waiting callers one after another for a bug that is none of theirs. A
/// caller who crashes their dispatcher
/// `quarantine_after` times within `crash_window_ms` is one no dispatcher
/// on any node will digest, and handing them back would crash the next one
/// the same way, for as long as they waited, taking every other caller of
/// the account through the restart each time; and before this, the whole
/// shard, on every node in turn. So they are settled -- acked, gone from the
/// broker -- logged as loudly as this log gets, and nothing else is done or
/// published for them: the caller's callflow still runs, and they leave on
/// their own clocks, by timing out or by hanging up, whose cancel then
/// settles nothing. That caller is never offered to an agent; every other
/// caller in the account is.
///
/// A dispatcher that keeps ending with no caller to blame -- more than
/// `storm_limit` times in `crash_window_ms`, crashes and stops alike -- is
/// something about the account this node cannot get past, and the actor
/// ends with it, as it used to on the first: the supervisor starts the tree
/// again, the broker hands the members back, and after five of those in a
/// minute the tree gives up and another node tries.
fn ended(
  state: State,
  account_id: String,
  reason: process.ExitReason,
) -> actor.Next(State, Message) {
  let now = monotonic_ms()
  let digesting = option.from_result(dict.get(state.digesting, account_id))
  let ends = [
    now,
    ..recent(dict.get(state.ends, account_id) |> result.unwrap([]), now)
  ]
  let state =
    State(
      ..state,
      dispatchers: dict.delete(state.dispatchers, account_id),
      digesting: dict.delete(state.digesting, account_id),
      ends: dict.insert(state.ends, account_id, ends),
    )
  case list.length(ends) > storm_limit {
    True ->
      actor.stop_abnormal(
        "the dispatcher for account "
        <> account_id
        <> " on shard "
        <> int.to_string(state.shard)
        <> " ended "
        <> int.to_string(list.length(ends))
        <> " times in "
        <> int.to_string(crash_window_ms / 1000)
        <> " s, the last with "
        <> string.inspect(reason)
        <> ": restarting the shard",
      )
    False -> {
      let state = case reason {
        process.Normal -> state
        _crashed -> blame(state, account_id, digesting, now, reason)
      }
      let state = case dispatchable(state, account_id) {
        [] -> state
        _held -> start_for(state, account_id)
      }
      case reason {
        process.Normal -> Nil
        _crashed ->
          system.log_error(
            "the dispatcher for account "
            <> account_id
            <> " on shard "
            <> int.to_string(state.shard)
            <> " crashed ("
            <> int.to_string(list.length(ends))
            <> " in the last "
            <> int.to_string(crash_window_ms / 1000)
            <> " s): "
            <> string.inspect(reason)
            <> case digesting {
              Some(#(call_id, _delivery)) -> " while digesting call " <> call_id
              None -> " with no caller being taken in"
            }
            <> "; started again with "
            <> int.to_string(list.length(dispatchable(state, account_id)))
            <> " caller(s)",
          )
      }
      actor.continue(state)
    }
  }
}

/// A crash counted against the caller it was digesting, and that caller
/// settled if it is the `quarantine_after`th. Strikes against members no
/// longer held are dropped as they are counted, so the book is never
/// bigger than the ledger.
fn blame(
  state: State,
  account_id: String,
  digesting: Option(#(String, Delivery)),
  now: Int,
  reason: process.ExitReason,
) -> State {
  let strikes =
    dict.filter(state.strikes, fn(key, _at) {
      result.is_ok(find(state.holding, key))
    })
    |> dict.map_values(fn(_key, at) { recent(at, now) })
  let state = State(..state, strikes: strikes)
  case digesting {
    None -> state
    Some(#(call_id, delivery)) -> {
      let key = #(account_id, call_id)
      case find(state.holding, key) {
        // Settled since it was handed over, or held as a later delivery:
        // not the member that was being digested.
        Ok(held) if held.delivery == delivery -> {
          let at = [now, ..dict.get(strikes, key) |> result.unwrap([])]
          case list.length(at) >= quarantine_after {
            False -> State(..state, strikes: dict.insert(strikes, key, at))
            True -> quarantine(state, held, list.length(at), reason)
          }
        }
        _other -> state
      }
    }
  }
}

/// Settle a member that crashes every dispatcher it is handed to, and say
/// so as loudly as the log allows.
fn quarantine(
  state: State,
  held: Entry,
  strikes: Int,
  reason: process.ExitReason,
) -> State {
  state.hooks.settle(held.delivery)
  let #(account_id, call_id) = held.key
  system.log_error(
    "QUARANTINED: member call "
    <> call_id
    <> " of account "
    <> account_id
    <> " in queue "
    <> held.queue_id
    <> ", joined at "
    <> int.to_string(held.joined_at)
    <> ", crashed its dispatcher on shard "
    <> int.to_string(state.shard)
    <> " "
    <> int.to_string(strikes)
    <> " times in "
    <> int.to_string(crash_window_ms / 1000)
    <> " s, the last with "
    <> string.inspect(reason)
    <> ". Its member is settled and it will not be offered to an agent; the"
    <> " caller stays in their callflow until they time out or hang up."
    <> case held.member {
      Some(member) ->
        " Priority "
        <> int.to_string(member.priority)
        <> ", callflow node "
        <> member.callflow_node
        <> ", caller id "
        <> option.unwrap(member.caller_id_name, "")
        <> " <"
        <> option.unwrap(member.caller_id_number, "")
        <> ">."
      None -> ""
    },
  )
  State(
    ..state,
    holding: forget(state.holding, held.key),
    strikes: dict.delete(state.strikes, held.key),
  )
}

/// The times given that are within `crash_window_ms` of `now`.
fn recent(times: List(Int), now: Int) -> List(Int) {
  list.filter(times, fn(at) { now - at < crash_window_ms })
}

/// How many times a caller crashes their dispatcher before they are settled
/// and dispatched no more. Three: once is a bug anybody can hit, twice in a
/// row could be a coincidence of timing, three times handed to a fresh
/// dispatcher is the caller.
const quarantine_after = 3

/// How many times an account's dispatcher may end unasked in
/// `crash_window_ms` before the shard gives up on itself. Enough for three
/// quarantines and some.
const storm_limit = 10

const crash_window_ms = 60_000

/// The account whose dispatcher that is, if it is one.
fn account_of(state: State, pid: Pid) -> Option(String) {
  dict.to_list(state.dispatchers)
  |> list.find(fn(entry) { process.subject_owner(entry.1) == Ok(pid) })
  |> result.map(fn(entry) { entry.0 })
  |> option.from_result
}

/// Hand a caller to their account's dispatcher, starting one if the shard
/// has none.
///
/// Told and never asked. The dispatcher reads the caller's `queue_call`
/// record before it rings anybody, which on a slow datastore is a while, and
/// after a failover it has every redelivered caller of the account to read
/// one after another; a shard that waited on each would hold every other
/// account's arrivals, cancels and settlements behind it, and fall silent to
/// the status responder while it did. Nothing is lost by not
/// waiting. Everything this actor tells a dispatcher is a send from this one
/// process to that one, so it arrives in the order it was sent: a cancel
/// for a caller reaches the dispatcher after the caller did. A dispatcher
/// that is gone by the time the caller reaches its mailbox is a message
/// here (`Exited`), and a new one is handed every caller of the account
/// still held.
fn hand_over(state: State, caller: types.Member) -> State {
  case dict.get(state.dispatchers, caller.account_id) {
    Ok(to) -> {
      tell(state, to, caller, False)
      state
    }
    Error(Nil) -> start_for(state, caller.account_id)
  }
}

/// Whether a dispatcher started for the account now may find offers the
/// last one left ringing: the last one ended without being asked to, within
/// the crash window, or ended with callers held and none could be started
/// since (`orphaned`), however long ago that was.
fn ended_lately(state: State, account_id: String) -> Bool {
  set.contains(state.orphaned, account_id)
  || case dict.get(state.ends, account_id) {
    Ok(times) -> recent(times, monotonic_ms()) != []
    Error(Nil) -> False
  }
}

/// Start a dispatcher for an account and hand it every caller of the
/// account this shard holds for dispatching, oldest first: the members of
/// an account whose dispatcher went, or never started, are still held here
/// and the broker will not hand them over again while the channel lasts.
///
/// Every start goes through here -- a dispatcher ending, a caller arriving,
/// the sweep asking for one -- and each asks `ended_lately` whether the
/// callers are `recovered`: whatever the account's last dispatcher left
/// ringing is still on the switch, and the new one reads each caller's
/// record before it rings anybody. The sweep used to start one as if
/// nothing had gone before, and a caller whose dispatcher crashed with an
/// agent answering, and could not be started again at once, was offered to
/// a second agent while the first bridge was up.
fn start_for(state: State, account_id: String) -> State {
  let recovered = ended_lately(state, account_id)
  case dispatcher_for(state, account_id, True) {
    #(state, None) ->
      case recovered && dispatchable(state, account_id) != [] {
        True -> State(..state, orphaned: set.insert(state.orphaned, account_id))
        False -> state
      }
    #(state, Some(to)) -> {
      list.each(dispatchable(state, account_id), fn(caller) {
        tell(state, to, caller, recovered)
      })
      State(..state, orphaned: set.delete(state.orphaned, account_id))
    }
  }
}

/// Every caller of an account held for dispatching, oldest first.
fn dispatchable(state: State, account_id: String) -> List(types.Member) {
  list.reverse(state.holding)
  |> list.filter_map(fn(entry) {
    case entry.key.0 == account_id, entry.member {
      True, Some(member) -> Ok(member)
      _, _ -> Error(Nil)
    }
  })
}

/// Hand one caller over. The dispatcher says here when it starts on them
/// and when it has taken them in, so that a crash in between is theirs.
fn tell(
  state: State,
  to: Subject(dispatcher.Message),
  caller: types.Member,
  recovered: Bool,
) -> Nil {
  let shard = subject(state.shard)
  process.send(
    to,
    dispatcher.HandedOver(
      caller,
      recovered,
      fn() {
        process.send(
          shard,
          Digesting(caller.account_id, caller.call_id, caller.delivery, to),
        )
      },
      fn() {
        process.send(
          shard,
          Digested(caller.account_id, caller.call_id, caller.delivery),
        )
      },
    ),
  )
}

// --- The member listener ---------------------------------------------------

/// The shard's member listener: the shard's own durable queue, manual ack,
/// and no prefetch at all, because every caller waiting in the shard is this
/// node's to hold.
///
/// Described and not started, because the description is the contract with
/// the broker and is worth asserting on without one.
pub fn member_listener(shard: Int, to: Subject(Message)) -> listener.Listener {
  listener.new()
  |> shards.declared(shards.member_queue(shard))
  // Exclusive: holding this consumer is holding the shard. The broker
  // refuses a second one, which is the whole of how two nodes are kept
  // from dispatching the same accounts.
  |> listener.consume(manual_ack: True, exclusive: True)
  |> listener.prefetch(0)
  |> listener.on_event(fn(value, delivery) {
    let arrival = member.decode(value)
    case arrival.kind {
      // A cancel settles the call it names and then itself, in the shard
      // actor and not here. It used to be acked here whatever the actor
      // answered, and an actor that had gone -- or went with the cancel in
      // its mailbox -- had settled nothing and noted nothing: the cancel was
      // gone from the broker, and the caller's `member_call` came back at
      // the failover with nothing behind it, a caller who had left,
      // dispatched and rung for. Unsettled, the cancel goes back with the
      // channel too, and the next holder settles the member with it in
      // whichever order the two arrive. It holds nothing up: the member
      // queue has no prefetch limit.
      member.Cancel -> {
        let reason =
          doc.get_string(value, ["Reason"]) |> result.unwrap("hangup")
        let _ =
          ask.call(to, 30_000, Cancelled(
            arrival.account_id,
            arrival.call_id,
            arrival.queue_id,
            reason,
            fields.some_int(value, ["Joined-Timestamp"]),
            arrival.cancelled_at,
            delivery,
            _,
          ))
        Nil
      }
      // Everything else is a caller. The delivery goes to the shard actor
      // unsettled and this closure returns, which is the rule: the work is
      // not done in the listener's process.
      _ -> {
        let _ = ask.call(to, 30_000, Arrived(arrival, value, delivery, _))
        Nil
      }
    }
  })
  |> listener.on_info(fn(info) {
    case info {
      // The broker gave this listener the consumer: the shard is this
      // node's from here, and not before.
      listener.Consuming(True) -> process.send(to, Consuming)
      // The channel went, the broker cancelled the consumer, or it refused
      // it because another node holds it. Every delivery the actor is
      // holding came on this channel and is good on no other, and the
      // broker has already given them back. `gen_listener` would reconnect
      // under the actor and consume again as if nothing had happened;
      // instead this ends, and the tree with it (`start_tree`).
      listener.Consuming(False) -> {
        system.log(
          "member queue "
          <> shards.member_queue(shard)
          <> " is not ours to consume: letting shard "
          <> int.to_string(shard)
          <> " go",
        )
        stop_normally()
      }
      listener.QueueCreated(queue) -> system.log("member queue " <> queue)
      _other -> Nil
    }
  })
}

// --- The dispatchers -------------------------------------------------------

/// The dispatcher for an account, started if there is none and `start` says
/// one may be.
fn dispatcher_for(
  state: State,
  account_id: String,
  start: Bool,
) -> #(State, Option(Subject(dispatcher.Message))) {
  case dict.get(state.dispatchers, account_id) {
    Ok(to) -> #(state, Some(to))
    Error(_) ->
      case start {
        False -> #(state, None)
        True -> {
          let held = subject(state.shard)
          case
            state.hooks.start_dispatcher(account_id, fn(member: types.Member) {
              // Asked of the shard, never done here: the shard's ledger is
              // the one place a member is settled. Sent and not called,
              // because the shard may be waiting on this dispatcher at the
              // same moment.
              process.send(
                held,
                Settle(member.account_id, member.call_id, member.delivery),
              )
            })
          {
            Error(reason) -> {
              system.log_error(
                "no dispatcher for account " <> account_id <> ": " <> reason,
              )
              #(state, None)
            }
            Ok(to) -> {
              system.log(
                "dispatching for account "
                <> account_id
                <> " on shard "
                <> int.to_string(state.shard),
              )
              #(
                State(
                  ..state,
                  dispatchers: dict.insert(state.dispatchers, account_id, to),
                ),
                Some(to),
              )
            }
          }
        }
      }
  }
}

/// Stop every dispatcher, and do not come back until each is gone.
///
/// Asked, then waited for, then killed. A dispatcher that stayed behind
/// would go on ringing this shard's agents from a node that no longer holds
/// it, beside the node that does. One that has already stopped itself is
/// the same thing done sooner. Their exit signals are messages to this
/// actor and are left in its mailbox: they name no dispatcher any more.
///
/// All of them at once, sharing one wait: a shard of forty accounts with a
/// wedged dispatcher among them stops in `stop_timeout_ms` and a kill, not
/// in forty turns of it.
fn stop_dispatchers(state: State) -> State {
  let running =
    dict.to_list(state.dispatchers)
    |> list.filter_map(fn(entry) {
      let #(account_id, to) = entry
      case process.subject_owner(to) {
        Error(Nil) -> Error(Nil)
        // Monitored before it is asked, so that its exit is seen whether it
        // comes before or after the answer.
        Ok(pid) -> Ok(#(account_id, to, pid, process.monitor(pid)))
      }
    })
  let deadline = monotonic_ms() + stop_timeout_ms
  let _ =
    ask.call_all(
      list.map(running, fn(entry) { entry.1 }),
      stop_timeout_ms,
      dispatcher.Stop,
    )
  list.each(running, fn(entry) {
    let #(account_id, _to, pid, monitor) = entry
    case gone(monitor, int.max(0, deadline - monotonic_ms())) {
      True -> Nil
      False -> {
        system.log_error(
          "the dispatcher for account "
          <> account_id
          <> " on shard "
          <> int.to_string(state.shard)
          <> " did not stop within "
          <> int.to_string(stop_timeout_ms)
          <> " ms: killing it",
        )
        // Unlinked first: a kill reaches everything linked to the
        // killed process.
        process.unlink(pid)
        process.kill(pid)
        let _ = gone(monitor, stop_timeout_ms)
        Nil
      }
    }
    process.demonitor_process(monitor)
  })
  State(..state, dispatchers: dict.new(), digesting: dict.new())
}

/// Whether the monitored process exited within the time given.
fn gone(monitor: process.Monitor, within_ms: Int) -> Bool {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_down) { Nil })
  |> process.selector_receive(within_ms)
  |> result.is_ok
}

/// How long a dispatcher is given to stop when asked, and then to die when
/// killed. A stop is a listener stopped and a cache entry cleared.
const stop_timeout_ms = 1000

/// The cancel reason a `member_cancel` carries, as the dispatcher's type.
fn records_reason(reason: String) -> types.CancelReason {
  records.reason_from_string(reason)
}

/// End this process with reason `shutdown`, from inside the callback it is
/// running in: what the supervisor is waiting for.
@external(erlang, "callcenter_ffi", "stop_shutdown")
fn stop_shutdown() -> Nil

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// End this process normally, from inside the callback it is running in.
@external(erlang, "callcenter_ffi", "stop_normally")
fn stop_normally() -> Nil

/// Shut a supervisor down from any process, and wait for it to be gone:
/// `True` once it is, `False` when it is not within the time given.
@external(erlang, "callcenter_ffi", "terminate")
fn terminate(pid: Pid, within_ms: Int) -> Bool

@external(erlang, "gleam_stdlib", "identity")
fn name_tag(name: Name(Message)) -> Dynamic
