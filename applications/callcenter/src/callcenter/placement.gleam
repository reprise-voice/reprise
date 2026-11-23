//// Which shards this node dispatches.
////
//// Five rules, and one process per node that keeps them:
////
//// 1. The members are the nodes the broker can see running the application
////    with the cluster's shard count (`callcenter/members`).
//// 2. Every node computes the same assignment from the same members
////    (`shards.assign`): rendezvous hashing with bounded loads, so two
////    nodes hold 32 and 32 of 64, and a member leaving moves its own shards
////    and little else.
//// 3. A node takes the shards assigned to it when nobody consumes them, and
////    asks every other member for the ones somebody does (`members.want`).
//// 4. A node gives a shard up only when the member it is assigned to, as
////    this node sees the members, has asked for it -- and not while an agent
////    is being rung on it, for up to `patience_ms`.
//// 5. A shard nobody has consumed for `orphan_ms` is taken by whoever sees
////    it, assigned or not: a caller waiting in a shard nobody dispatches is
////    worse than a shard on the wrong node.
////
//// Holding a shard is still holding the exclusive consumer on its member
//// queue (`callcenter/shard`): two nodes that disagree about the members
//// may both try to take a shard, and the broker refuses the second. The
//// rules decide who tries; the broker decides who has it.
////
//// Rule 4 is what keeps a shard from moving back and forth. A handover needs
//// both ends to agree the shard is the asker's: the asker because it only
//// asks for what it is assigned, the holder because it only gives it to the
//// member it is assigned to. Two nodes that see different members -- one
//// has heard of a third and the other has not yet -- move nothing between
//// them until they agree. A node that cannot take a shard never asks for
//// it, so nothing is given to it: a node that died and that `kz_nodes`
//// still lists is not a member, and a node whose count is not the cluster's
//// never becomes one.
////
//// Everything happens on a tick of `tick_ms`, jittered, so that a free
//// shard is taken within a tick and a want is answered within one. A node
//// that dies closes its connection and leaves its shards free at once; one
//// that freezes is dropped by the broker's heartbeat, 15 to 20 seconds
//// later; either way the next tick of every other node sees it gone from
//// the members and its shards free.

import callcenter/ask
import callcenter/members
import callcenter/shard
import callcenter/shards
import callcenter/system
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
import kazoo/listener
import kazoo/util

/// What the placement is told.
pub type Message {
  /// The timer: look at every shard, and set the next tick.
  Tick
  /// Look now, between ticks: what `sup callcenter_maintenance rebalance`
  /// asks. It sets no tick.
  Look
  /// A member asked for shards it is assigned.
  Wanted(from: String, shards: List(Int))
  /// A shard asked whether it would give itself up answered: `True` when it
  /// did.
  GaveUp(shard: Int, to: String, agreed: Bool)
  /// A tree ended, however it ended.
  Ended(tree: Pid, reason: String)
  /// What this node sees, for `sup` and the tests.
  Report(done: Subject(Seen))
}

/// What a node sees: the members, the shards assigned to it, the shards
/// whose trees it runs, and those of them it is handing over.
pub type Seen {
  Seen(
    members: List(String),
    assigned: List(Int),
    held: List(Int),
    handing: List(Int),
  )
}

/// Everything the placement reaches outside itself, given rather than
/// found, so that a cluster of them can be driven in a test with no broker.
pub type Hooks {
  Hooks(
    /// This node's name, as the members are named.
    node: String,
    /// Whether this node may take shards: `Ok(True)` when its shard count
    /// is the cluster's, `Ok(False)` when the broker refused it, `Error`
    /// when there is no broker to ask.
    agreed: fn() -> Result(Bool, Nil),
    /// Make this node a member, handing the wants it hears to the subject,
    /// and answer the function that makes it one no longer.
    join: fn(Subject(Message)) -> Result(fn() -> Nil, String),
    /// The members, as the broker sees them now.
    members: fn() -> Result(List(String), String),
    /// Declare a shard's member queue and answer how many callers wait on it
    /// and how many consumers it has.
    probe: fn(Int) -> Result(#(Int, Int), String),
    /// Start a shard's tree, and answer its supervisor.
    take: fn(Int) -> Result(Pid, String),
    /// A shard's tree already running on this node: what a placement that
    /// was restarted finds where it left off.
    adopt: fn(Int) -> Result(Pid, Nil),
    /// Hand a shard over: `False` when it refused because an agent is being
    /// rung on it.
    give_up: fn(Int) -> Bool,
    /// Stop a shard's tree whatever it is doing.
    release: fn(Int) -> Nil,
    /// Ask a member for shards.
    want: fn(String, List(Int)) -> Nil,
    now_ms: fn() -> Int,
    tick_ms: Int,
    jitter_ms: Int,
  )
}

/// Every few seconds: the time a free shard waits to be taken, and a
/// `queue.declare` for every shard not held here, and for every candidate
/// member, per tick.
const tick_ms = 5000

const jitter_ms = 2000

/// How long a shard may go with no consumer before whoever sees it takes it,
/// assigned or not. Longer than a tick and its jitter, so that the member
/// it is assigned to, taking it after a handover or a broker restart, is
/// never raced for it.
pub const orphan_ms = 30_000

/// How long a handover waits for the agents being rung on the shard. Past
/// it the shard is handed over ringing, and the node taking it watches the
/// ring from the caller's record (`callcenter/takeover`); without it a shard
/// that always has somebody ringing, on a busy account, would never move.
pub const patience_ms = 120_000

type State {
  State(
    count: Int,
    self: Subject(Message),
    hooks: Hooks,
    /// How to stop being a member, while this node is one.
    leave: Option(fn() -> Nil),
    /// The members at the last look, sorted.
    members: List(String),
    /// Who each shard is assigned to, as of the last look.
    assigned: Dict(Int, String),
    /// The tree of each shard this node runs.
    trees: Dict(Int, Pid),
    /// When each shard not assigned here was first seen with no consumer.
    unconsumed: Dict(Int, Int),
    /// When each shard a member asked for was first refused because an
    /// agent was ringing on it.
    refused: Dict(Int, Int),
    /// The shards being asked, right now, whether they will be given up.
    handing: Set(Int),
  )
}

// --- Starting --------------------------------------------------------------

/// The node's placement. Nothing where there is no broker to ask: `gleam
/// run` and the test suite have the application but not the release.
pub fn supervised(
  count: Int,
  start_offer: shard.StartOffer,
) -> List(supervision.ChildSpecification(Nil)) {
  case system.broker_available() {
    False -> []
    True -> [
      supervision.worker(fn() {
        start(count, hooks(count, start_offer), registered: True)
      })
      |> supervision.map_data(fn(_started) { Nil }),
    ]
  }
}

/// The node's own hooks.
pub fn hooks(count: Int, start_offer: shard.StartOffer) -> Hooks {
  let shard_hooks = shard.hooks(count, start_offer)
  let node = system.node_name()
  Hooks(
    node: node,
    agreed: fn() {
      case shards.agreement(count) {
        shards.Agreed -> Ok(True)
        shards.Disagreed(_reason) -> Ok(False)
        shards.Unknown -> Error(Nil)
      }
    },
    join: fn(to) {
      members.listener(node, fn(from, asked) {
        process.send(to, Wanted(from, asked))
      })
      |> listener.start
      |> result.map(fn(server) { fn() { listener.stop(server) } })
    },
    members: fn() { members.now(node) },
    probe: fn(shard_id) { shards.declare(shards.member_queue(shard_id)) },
    take: fn(shard_id) { shard.take_using(shard_id, shard_hooks) },
    adopt: shard.tree,
    give_up: shard.give_up,
    release: shard.release,
    want: fn(to, asked) { members.want(to: to, from: node, shards: asked) },
    now_ms: monotonic_ms,
    tick_ms: tick_ms,
    jitter_ms: jitter_ms,
  )
}

/// A placement for `count` shards. Registered, it is the node's; several
/// unregistered ones side by side in one VM are how a cluster is tested.
pub fn start(
  count: Int,
  hooks: Hooks,
  registered registered: Bool,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  let builder =
    actor.new_with_initialiser(5000, fn(self) {
      process.send(self, Tick)
      // A placement its supervisor restarted finds the trees it was
      // watching still running, and watches them again.
      let trees =
        shards.all(count)
        |> list.filter_map(fn(shard_id) {
          hooks.adopt(shard_id)
          |> result.map(fn(tree) {
            let _monitor = process.monitor(tree)
            #(shard_id, tree)
          })
        })
        |> dict.from_list
      actor.initialised(State(
        count: count,
        self: self,
        hooks: hooks,
        leave: None,
        members: [],
        assigned: dict.new(),
        trees: trees,
        unconsumed: dict.new(),
        refused: dict.new(),
        handing: set.new(),
      ))
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(_monitor, pid, reason) ->
              Ended(pid, string.inspect(reason))
            // Nothing here monitors a port.
            process.PortDown(_monitor, _port, reason) ->
              Ended(process.self(), string.inspect(reason))
          }
        }),
      )
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
  case registered {
    True -> actor.named(builder, name())
    False -> builder
  }
  |> actor.start
}

fn name() -> Name(Message) {
  util.name("callcenter_placement")
}

/// Look at every shard now rather than at the next tick.
pub fn look_now() -> Nil {
  case process.named(name()) {
    Ok(_pid) -> process.send(process.named_subject(name()), Look)
    Error(Nil) -> Nil
  }
}

/// What this node's placement sees, or nothing when it is not running or
/// did not answer within five seconds: it may be waiting on a shard it is
/// handing over.
pub fn seen() -> Option(Seen) {
  case process.named(name()) {
    Error(Nil) -> None
    Ok(_pid) ->
      ask.call(process.named_subject(name()), 5000, Report)
      |> option.from_result
  }
}

// --- The loop --------------------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> {
      let _ =
        process.send_after(
          state.self,
          state.hooks.tick_ms + int.random(state.hooks.jitter_ms + 1),
          Tick,
        )
      actor.continue(tick(state))
    }

    Look -> actor.continue(tick(state))

    Wanted(from, asked) -> actor.continue(wanted(state, from, asked))

    GaveUp(shard_id, to, agreed) ->
      actor.continue(gave_up(state, shard_id, to, agreed))

    Ended(tree, reason) ->
      case list.find(dict.to_list(state.trees), fn(held) { held.1 == tree }) {
        // A tree this node let go of, ending late: nothing to do.
        Error(Nil) -> actor.continue(state)
        Ok(#(shard_id, _tree)) -> {
          case set.contains(state.handing, shard_id) {
            // Being handed over, and ending because it agreed before its
            // answer is here: the answer will say so.
            True -> Nil
            // Not let go of: the listener lost its channel or was refused
            // the consumer, or the actor crashed more than it may. Either
            // way the shard is whoever's is free to take it, this node
            // included.
            False ->
              system.log(
                "shard "
                <> int.to_string(shard_id)
                <> " has gone down on this node: "
                <> reason,
              )
          }
          actor.continue(
            State(..state, trees: dict.delete(state.trees, shard_id)),
          )
        }
      }

    Report(done) -> {
      process.send(
        done,
        Seen(
          members: state.members,
          assigned: assigned_to(state, state.hooks.node),
          held: dict.keys(state.trees) |> list.sort(int.compare),
          handing: set.to_list(state.handing) |> list.sort(int.compare),
        ),
      )
      actor.continue(state)
    }
  }
}

/// A node whose count is not the cluster's is no member and takes nothing:
/// every member it held would be one it hashed differently from the
/// callflow that sent it. A node with no broker to ask does nothing at all.
fn tick(state: State) -> State {
  case state.hooks.agreed() {
    Error(Nil) -> state
    Ok(False) -> leave(state)
    Ok(True) -> state |> join |> look
  }
}

fn join(state: State) -> State {
  case state.leave {
    Some(_member) -> state
    None ->
      case state.hooks.join(state.self) {
        Ok(leave) -> State(..state, leave: Some(leave))
        Error(reason) -> {
          system.log_error(
            "could not join the call center's members: " <> reason,
          )
          state
        }
      }
  }
}

fn leave(state: State) -> State {
  case state.leave {
    None -> state
    Some(leave) -> {
      leave()
      State(..state, leave: None)
    }
  }
}

fn look(state: State) -> State {
  case state.hooks.members() {
    // No broker to ask: every probe would say the same.
    Error(_reason) -> state
    Ok(members) -> {
      let members = list.sort(members, string.compare)
      case members == state.members {
        True -> Nil
        False ->
          system.log(
            "members: "
            <> string.join(members, ", ")
            <> case state.members {
              [] -> ""
              before -> " (were " <> string.join(before, ", ") <> ")"
            },
          )
      }
      let state =
        State(
          ..state,
          members: members,
          assigned: shards.assign(state.count, members),
        )
      let #(state, wanted) = visit_all(state, shards.all(state.count), [])
      case wanted {
        [] -> Nil
        wanted -> {
          let wanted = list.reverse(wanted)
          members
          |> list.filter(fn(member) { member != state.hooks.node })
          |> list.each(fn(member) { state.hooks.want(member, wanted) })
        }
      }
      state
    }
  }
}

/// Every shard in turn, and the shards to ask the other members for. A
/// broker that stops answering ends the look: the rest wait for the next
/// tick rather than each wait for a broker that is not there.
fn visit_all(
  state: State,
  remaining: List(Int),
  wanted: List(Int),
) -> #(State, List(Int)) {
  case remaining {
    [] -> #(state, wanted)
    [shard_id, ..rest] ->
      case visit(state, shard_id) {
        Error(Nil) -> #(state, wanted)
        Ok(#(state, True)) -> visit_all(state, rest, [shard_id, ..wanted])
        Ok(#(state, False)) -> visit_all(state, rest, wanted)
      }
  }
}

/// One shard: take it, ask for it, or leave it. `True` when it is to be
/// asked for.
fn visit(state: State, shard_id: Int) -> Result(#(State, Bool), Nil) {
  let mine = dict.get(state.assigned, shard_id) == Ok(state.hooks.node)
  case dict.has_key(state.trees, shard_id) {
    // Held here. One assigned elsewhere waits for its member to ask.
    True -> {
      let state = consumed(state, shard_id)
      case mine {
        True ->
          Ok(#(
            State(..state, refused: dict.delete(state.refused, shard_id)),
            False,
          ))
        False -> Ok(#(state, False))
      }
    }
    False ->
      case state.hooks.probe(shard_id) {
        Error(_reason) -> Error(Nil)
        Ok(#(_waiting, consumers)) if consumers > 0 ->
          Ok(#(consumed(state, shard_id), mine))
        Ok(#(waiting, _nobody)) ->
          case mine {
            True -> Ok(#(take(state, shard_id, waiting, False), False))
            False -> Ok(#(unowned(state, shard_id, waiting), False))
          }
      }
  }
}

fn consumed(state: State, shard_id: Int) -> State {
  State(..state, unconsumed: dict.delete(state.unconsumed, shard_id))
}

/// A shard assigned elsewhere that nobody consumes: taken once it has been
/// free for `orphan_ms`.
fn unowned(state: State, shard_id: Int, waiting: Int) -> State {
  let now = state.hooks.now_ms()
  case dict.get(state.unconsumed, shard_id) {
    Ok(since) if now - since >= orphan_ms -> take(state, shard_id, waiting, True)
    Ok(_since) -> state
    Error(Nil) ->
      State(..state, unconsumed: dict.insert(state.unconsumed, shard_id, now))
  }
}

fn take(state: State, shard_id: Int, waiting: Int, orphan: Bool) -> State {
  case state.hooks.take(shard_id) {
    Ok(tree) -> {
      // Started from this process, so linked to it, and its `shutdown` would
      // end this process too. Watched instead.
      process.unlink(tree)
      let _monitor = process.monitor(tree)
      system.log(
        "shard "
        <> int.to_string(shard_id)
        <> " taken on "
        <> state.hooks.node
        <> " with "
        <> int.to_string(waiting)
        <> " caller(s) waiting"
        <> case orphan {
          True ->
            ", as an orphan: it is assigned to "
            <> result.unwrap(dict.get(state.assigned, shard_id), "nobody")
            <> " and nobody consumed it for "
            <> int.to_string(orphan_ms / 1000)
            <> " s"
          False -> ""
        },
      )
      State(
        ..state,
        trees: dict.insert(state.trees, shard_id, tree),
        unconsumed: dict.delete(state.unconsumed, shard_id),
      )
    }
    Error(reason) -> {
      system.log_error(
        "shard "
        <> int.to_string(shard_id)
        <> " could not be taken on this node: "
        <> reason,
      )
      state
    }
  }
}

/// A member asked for shards. Each one held here and assigned to it is
/// asked to give itself up; anything else -- a shard not held here, or one
/// this node sees assigned to somebody else -- is not this node's to give,
/// and the asker asks again next tick.
///
/// Each shard is asked from a process of its own, which reports back
/// (`GaveUp`): a shard stops its dispatchers before it answers and its tree
/// is waited for after, seconds for a busy one, and the placement goes on
/// taking, answering and looking meanwhile. A shard already being asked is
/// not asked twice.
fn wanted(state: State, from: String, asked: List(Int)) -> State {
  list.fold(asked, state, fn(state, shard_id) {
    case
      from != state.hooks.node,
      dict.has_key(state.trees, shard_id),
      set.contains(state.handing, shard_id),
      dict.get(state.assigned, shard_id)
    {
      True, True, False, Ok(assigned) if assigned == from -> {
        let self = state.self
        let give_up = state.hooks.give_up
        let _ =
          process.spawn_unlinked(fn() {
            process.send(self, GaveUp(shard_id, from, give_up(shard_id)))
          })
        State(..state, handing: set.insert(state.handing, shard_id))
      }
      _, _, _, _ -> state
    }
  })
}

fn gave_up(state: State, shard_id: Int, to: String, agreed: Bool) -> State {
  let state = State(..state, handing: set.delete(state.handing, shard_id))
  case agreed, dict.has_key(state.trees, shard_id) {
    True, _ -> {
      system.log(
        "shard " <> int.to_string(shard_id) <> " handed over to " <> to,
      )
      let_go(state, shard_id)
    }
    // Refused, and its tree has ended since: nothing left to hand over.
    False, False -> let_go(state, shard_id)
    // Refused: an agent is being rung on it.
    False, True -> {
      let now = state.hooks.now_ms()
      let since = dict.get(state.refused, shard_id) |> result.unwrap(now)
      case now - since >= patience_ms {
        False ->
          State(..state, refused: dict.insert(state.refused, shard_id, since))
        True -> {
          system.log_error(
            "shard "
            <> int.to_string(shard_id)
            <> " handed over to "
            <> to
            <> " with an agent still ringing on it after "
            <> int.to_string({ now - since } / 1000)
            <> " s: "
            <> to
            <> " watches the ring from the caller's record",
          )
          let release = state.hooks.release
          let _ = process.spawn_unlinked(fn() { release(shard_id) })
          let_go(state, shard_id)
        }
      }
    }
  }
}

/// The tree's end is on its way here and is this node's doing: forgotten
/// now, so that it is not taken for a loss.
fn let_go(state: State, shard_id: Int) -> State {
  State(
    ..state,
    trees: dict.delete(state.trees, shard_id),
    refused: dict.delete(state.refused, shard_id),
  )
}

fn assigned_to(state: State, node: String) -> List(Int) {
  state.assigned
  |> dict.to_list
  |> list.filter_map(fn(assigned) {
    case assigned.1 == node {
      True -> Ok(assigned.0)
      False -> Error(Nil)
    }
  })
  |> list.sort(int.compare)
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
