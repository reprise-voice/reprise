//// Several nodes' placements against one broker, in one VM: where the shards
//// settle, and what moves when a node dies, comes back, freezes, or cannot
//// take shards at all.
////
//// The broker is an actor that knows which nodes are members, who consumes
//// each shard's queue, and which shards are too busy to answer being given
//// up; it passes a
//// want to the member it is addressed to, as the member's own queue would.
//// Each node is a real placement actor whose hooks talk to it. Nothing
//// ticks on its own: every look is sent by hand, so a run is the same every
//// time.

import callcenter/placement
import callcenter/shards
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/set.{type Set}

const count = 64

// --- The broker -------------------------------------------------------------

type World {
  World(
    /// The names `kz_nodes` lists, as each node sees them.
    listed: Dict(String, List(String)),
    /// The members, each with its placement: whoever consumes its own
    /// queue.
    present: Dict(String, Subject(placement.Message)),
    /// The nodes whose shard count is not the cluster's.
    disagreeing: Set(String),
    /// The nodes whose every take fails.
    broken: Set(String),
    /// Who consumes each shard's member queue, and the tree doing it.
    owners: Dict(Int, #(String, Pid)),
    /// The shards too busy to answer being given up.
    stuck: Set(Int),
    /// How long a shard takes to answer whether it will give itself up.
    give_up_ms: Int,
    /// The clock, in milliseconds.
    now: Int,
    /// Every take, newest first: the shard and the node.
    takes: List(#(Int, String)),
  )
}

type Ask {
  Agreed(node: String, done: Subject(Bool))
  Join(node: String, inbox: Subject(placement.Message), done: Subject(Nil))
  Leave(node: String)
  Members(node: String, known: List(String), done: Subject(List(String)))
  Probe(shard: Int, done: Subject(Int))
  Take(node: String, shard: Int, done: Subject(Result(Pid, String)))
  Adopt(node: String, shard: Int, done: Subject(Result(Pid, Nil)))
  GiveUp(node: String, shard: Int, done: Subject(Bool))
  Release(node: String, shard: Int)
  Want(from: String, to: String, shards: List(Int), done: Subject(Nil))
  Now(done: Subject(Int))
  Change(change: fn(World) -> World, done: Subject(Nil))
  Get(done: Subject(World))
}

fn world() -> Subject(Ask) {
  let assert Ok(started) =
    actor.new(
      World(
        listed: dict.new(),
        present: dict.new(),
        disagreeing: set.new(),
        broken: set.new(),
        owners: dict.new(),
        stuck: set.new(),
        give_up_ms: 0,
        now: 1_000_000,
        takes: [],
      ),
    )
    |> actor.on_message(serve)
    |> actor.start
  started.data
}

fn serve(w: World, ask: Ask) -> actor.Next(World, Ask) {
  case ask {
    Agreed(node, done) -> {
      process.send(done, !set.contains(w.disagreeing, node))
      actor.continue(w)
    }
    Join(node, inbox, done) -> {
      process.send(done, Nil)
      actor.continue(World(..w, present: dict.insert(w.present, node, inbox)))
    }
    Leave(node) ->
      actor.continue(World(..w, present: dict.delete(w.present, node)))
    // As `members.now` asks: the names `kz_nodes` lists and the members
    // the node saw at its last look.
    Members(node, known, done) -> {
      let listed = dict.get(w.listed, node) |> option_list
      process.send(
        done,
        [node, ..list.append(listed, known)]
          |> list.unique
          |> list.filter(fn(name) { dict.has_key(w.present, name) }),
      )
      actor.continue(w)
    }
    Probe(shard, done) -> {
      process.send(done, case dict.has_key(w.owners, shard) {
        True -> 1
        False -> 0
      })
      actor.continue(w)
    }
    // The broker's exclusive consumer: the first to ask has it.
    Take(node, shard, done) ->
      case dict.has_key(w.owners, shard), set.contains(w.broken, node) {
        _, True -> {
          process.send(done, Error("this node cannot take anything"))
          actor.continue(w)
        }
        True, False -> {
          process.send(done, Error("in exclusive use"))
          actor.continue(w)
        }
        False, False -> {
          let tree = process.spawn_unlinked(fn() { process.sleep_forever() })
          process.send(done, Ok(tree))
          actor.continue(
            World(
              ..w,
              owners: dict.insert(w.owners, shard, #(node, tree)),
              takes: [#(shard, node), ..w.takes],
            ),
          )
        }
      }
    Adopt(node, shard, done) -> {
      process.send(done, case dict.get(w.owners, shard) {
        Ok(#(owner, tree)) if owner == node -> Ok(tree)
        _ -> Error(Nil)
      })
      actor.continue(w)
    }
    GiveUp(node, shard, done) ->
      case set.contains(w.stuck, shard) {
        True -> {
          process.send(done, False)
          actor.continue(w)
        }
        False -> {
          process.send(done, True)
          actor.continue(free(w, node, shard))
        }
      }
    Release(node, shard) -> actor.continue(free(w, node, shard))
    Want(from, to, asked, done) -> {
      case dict.get(w.present, to) {
        Ok(inbox) -> process.send(inbox, placement.Wanted(from, asked))
        Error(Nil) -> Nil
      }
      process.send(done, Nil)
      actor.continue(w)
    }
    Now(done) -> {
      process.send(done, w.now)
      actor.continue(w)
    }
    Change(change, done) -> {
      process.send(done, Nil)
      actor.continue(change(w))
    }
    Get(done) -> {
      process.send(done, w)
      actor.continue(w)
    }
  }
}

fn option_list(listed: Result(List(String), Nil)) -> List(String) {
  case listed {
    Ok(listed) -> listed
    Error(Nil) -> []
  }
}

/// The shard's consumer goes, if it is that node's: its tree ends.
fn free(w: World, node: String, shard: Int) -> World {
  case dict.get(w.owners, shard) {
    Ok(#(owner, tree)) if owner == node -> {
      process.kill(tree)
      World(..w, owners: dict.delete(w.owners, shard))
    }
    _ -> w
  }
}

fn change(w: Subject(Ask), how: fn(World) -> World) -> Nil {
  process.call(w, 1000, Change(how, _))
}

fn seen(w: Subject(Ask)) -> World {
  process.call(w, 1000, Get)
}

// --- The nodes --------------------------------------------------------------

type Node {
  Node(name: String, pid: Pid, to: Subject(placement.Message))
}

fn hooks(w: Subject(Ask), name: String) -> placement.Hooks {
  placement.Hooks(
    node: name,
    agreed: fn() { Ok(process.call(w, 1000, Agreed(name, _))) },
    join: fn(inbox) {
      process.call(w, 1000, Join(name, inbox, _))
      Ok(fn() { process.send(w, Leave(name)) })
    },
    members: fn(known) { Ok(process.call(w, 1000, Members(name, known, _))) },
    probe: fn(shard) { Ok(#(0, process.call(w, 1000, Probe(shard, _)))) },
    take: fn(shard) { process.call(w, 1000, Take(name, shard, _)) },
    adopt: fn(shard) { process.call(w, 1000, Adopt(name, shard, _)) },
    give_up: fn(shard) {
      process.sleep(seen(w).give_up_ms)
      process.call(w, 1000, GiveUp(name, shard, _))
    },
    release: fn(shard) { process.send(w, Release(name, shard)) },
    want: fn(to, asked) { process.call(w, 1000, Want(name, to, asked, _)) },
    now_ms: fn() { process.call(w, 1000, Now) },
    // Nothing ticks on its own here: every look is sent by hand.
    tick_ms: 3_600_000,
    jitter_ms: 0,
  )
}

/// A node, which `kz_nodes` on every node lists from now on.
fn node(w: Subject(Ask), name: String) -> Node {
  change(w, fn(w) {
    World(
      ..w,
      listed: dict.map_values(w.listed, fn(_node, listed) {
          list.unique([name, ..listed])
        })
        |> dict.insert(name, dict.keys(w.listed) |> list.prepend(name)),
    )
  })
  start(w, name)
}

fn start(w: Subject(Ask), name: String) -> Node {
  let assert Ok(started) = placement.start(count, hooks(w, name), False)
  // The test's process must not go down with a node that is killed.
  process.unlink(started.pid)
  let node = Node(name: name, pid: started.pid, to: started.data)
  // Its first look is its own, on start; wait for it.
  let _ = report(node)
  node
}

/// A node dies: its placement, its trees and its connection all go, so its
/// consumers do, and it is no member. `kz_nodes` goes on listing it.
fn kill(w: Subject(Ask), node: Node) -> Nil {
  process.kill(node.pid)
  change(w, fn(w) {
    let owners =
      dict.filter(w.owners, fn(_shard, owner) {
        case owner.0 == node.name {
          True -> {
            process.kill(owner.1)
            False
          }
          False -> True
        }
      })
    World(..w, owners: owners, present: dict.delete(w.present, node.name))
  })
}

fn report(node: Node) -> placement.Seen {
  process.call(node.to, 5000, placement.Report)
}

/// Every node looks once, in turn, and then answers once every want sent to
/// it during the round has been dealt with and every shard it was asking
/// has answered.
fn round(nodes: List(Node)) -> Nil {
  list.each(nodes, fn(node) {
    process.send(node.to, placement.Look)
    quiet(node, 500)
  })
  list.each(nodes, fn(node) { quiet(node, 500) })
}

fn quiet(node: Node, attempts: Int) -> Nil {
  case report(node).handing, attempts {
    [], _ -> Nil
    _asking, 0 -> panic as "a hand-over never answered"
    _asking, _ -> {
      process.sleep(5)
      quiet(node, attempts - 1)
    }
  }
}

fn rounds(nodes: List(Node), times: Int) -> Nil {
  case times {
    0 -> Nil
    _ -> {
      round(nodes)
      rounds(nodes, times - 1)
    }
  }
}

fn held(w: Subject(Ask), name: String) -> List(Int) {
  seen(w).owners
  |> dict.to_list
  |> list.filter_map(fn(owner) {
    case owner.1.0 == name {
      True -> Ok(owner.0)
      False -> Error(Nil)
    }
  })
}

fn takes(w: Subject(Ask)) -> List(#(Int, String)) {
  seen(w).takes
}

fn forget_takes(w: Subject(Ask)) -> Nil {
  change(w, fn(w) { World(..w, takes: []) })
}

/// Every shard is held, and by the node it is assigned to among `members`.
fn settled_as_assigned(w: Subject(Ask), members: List(String)) -> Bool {
  let assigned = shards.assign(count, members)
  let owners = seen(w).owners
  dict.size(owners) == count
  && dict.to_list(assigned)
  |> list.all(fn(assignment) {
    case dict.get(owners, assignment.0) {
      Ok(#(owner, _tree)) -> owner == assignment.1
      Error(Nil) -> False
    }
  })
}

/// No shard was taken twice in the takes kept, and none by a node that had
/// it before: each moved at most once.
fn each_moved_at_most_once(w: Subject(Ask)) -> Bool {
  let shards_taken = list.map(takes(w), fn(take) { take.0 })
  list.length(shards_taken) == list.length(list.unique(shards_taken))
}

fn stop(nodes: List(Node)) -> Nil {
  list.each(nodes, fn(node) { process.kill(node.pid) })
}

const a = "kazoo_apps@a"

const b = "kazoo_apps@b"

const c = "kazoo_apps@c"

// --- The tests --------------------------------------------------------------

/// Two nodes starting together settle on half each, every shard where it is
/// assigned, and nothing taken twice.
pub fn two_nodes_hold_half_each_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  assert settled_as_assigned(w, [a, b])
  assert list.length(held(w, a)) == 32
  assert list.length(held(w, b)) == 32
  // Whatever a took before b was a member went to b once, and no more.
  assert each_moved_at_most_once_after_the_first(w)
  stop([node_a, node_b])
}

/// The first take of every shard is the cold start's; after it, each moved
/// at most once.
fn each_moved_at_most_once_after_the_first(w: Subject(Ask)) -> Bool {
  let taken = list.map(takes(w), fn(take) { take.0 })
  list.all(list.unique(taken), fn(shard) {
    list.count(taken, fn(other) { other == shard }) <= 2
  })
}

/// A node is killed: the dead node is still listed by `kz_nodes`, but it
/// is no member, and the survivor takes every shard it held in one look.
pub fn a_dead_nodes_shards_are_taken_in_one_look_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  let theirs = held(w, b)
  assert list.length(theirs) == 32

  kill(w, node_b)
  round([node_a])
  assert list.length(held(w, a)) == 64
  stop([node_a])
}

/// The give-back: the node that died comes back, asks for its
/// shards, and has each back once; the survivor takes nothing back.
pub fn a_node_that_returns_is_given_its_shards_back_once_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  kill(w, node_b)
  round([node_a])
  assert list.length(held(w, a)) == 64

  forget_takes(w)
  let node_b = start(w, b)
  rounds([node_a, node_b], 3)
  assert settled_as_assigned(w, [a, b])
  assert list.length(held(w, b)) == 32
  // Only b took anything, and each shard once.
  assert list.all(takes(w), fn(take) { take.1 == b })
  assert list.length(takes(w)) == 32
  assert each_moved_at_most_once(w)

  // And it stays put.
  forget_takes(w)
  rounds([node_a, node_b], 5)
  assert takes(w) == []
  stop([node_a, node_b])
}

/// The flap: a node that comes back is one name
/// with two lives, and the survivor's `kz_nodes` drops the name when the
/// first life's entry runs out -- after the second life's queue is consumed
/// and before its heartbeat is heard. The returned node stays a member all
/// the same, since the broker still says its queue is consumed, and its
/// shards move to it once and never back.
pub fn a_returned_node_kz_nodes_forgets_stays_a_member_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  kill(w, node_b)
  round([node_a])
  assert list.length(held(w, a)) == 64

  forget_takes(w)
  let node_b = start(w, b)
  round([node_a, node_b])
  assert report(node_a).members == [a, b]

  // The first life's entry runs out on a.
  change(w, fn(w) { World(..w, listed: dict.insert(w.listed, a, [a])) })
  rounds([node_a, node_b], 3)
  assert report(node_a).members == [a, b]
  assert settled_as_assigned(w, [a, b])
  assert list.all(takes(w), fn(take) { take.1 == b })
  assert list.length(takes(w)) == 32

  // The second life's heartbeat is heard, and nothing moves.
  change(w, fn(w) { World(..w, listed: dict.insert(w.listed, a, [a, b])) })
  forget_takes(w)
  rounds([node_a, node_b], 3)
  assert takes(w) == []
  stop([node_a, node_b])
}

/// A node that stops is dropped at once, however long it was a member: the
/// broker says its queue has no consumer.
pub fn a_member_that_stops_is_no_member_at_once_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  change(w, fn(w) { World(..w, listed: dict.insert(w.listed, a, [a])) })
  round([node_a])
  assert report(node_a).members == [a, b]
  kill(w, node_b)
  round([node_a])
  assert report(node_a).members == [a]
  assert list.length(held(w, a)) == 64
  stop([node_a])
}

/// A node whose shard count is not the cluster's is no member: it takes
/// nothing and is given nothing, however long it asks.
pub fn a_node_with_the_wrong_count_takes_nothing_and_is_given_nothing_test() {
  let w = world()
  change(w, fn(w) { World(..w, disagreeing: set.from_list([b])) })
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 4)
  assert list.length(held(w, a)) == 64
  assert held(w, b) == []
  assert report(node_b).members == []
  stop([node_a, node_b])
}

/// A shard too busy to answer being given up stays where it is when its node
/// is asked for it, until the patience runs out: then it moves all the same.
pub fn a_shard_that_does_not_answer_moves_after_the_patience_test() {
  let w = world()
  let node_a = node(w, a)
  round([node_a])
  assert list.length(held(w, a)) == 64

  let assigned = shards.assign(count, [a, b])
  let assert Ok(#(stuck, _b)) =
    dict.to_list(assigned) |> list.find(fn(assigned) { assigned.1 == b })
  change(w, fn(w) { World(..w, stuck: set.from_list([stuck])) })
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  assert list.length(held(w, b)) == 31
  assert list.contains(held(w, a), stuck)

  change(w, fn(w) { World(..w, now: w.now + placement.patience_ms) })
  rounds([node_a, node_b], 2)
  assert settled_as_assigned(w, [a, b])
  stop([node_a, node_b])
}

/// A member that cannot take the shards it is assigned leaves them free,
/// and the other takes them once they have been free for `orphan_ms`, and
/// not before.
pub fn a_shard_nobody_takes_is_taken_as_an_orphan_test() {
  let w = world()
  change(w, fn(w) { World(..w, broken: set.from_list([b])) })
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  assert list.length(held(w, a)) == 32
  assert held(w, b) == []

  change(w, fn(w) { World(..w, now: w.now + placement.orphan_ms - 1) })
  round([node_a])
  assert list.length(held(w, a)) == 32

  change(w, fn(w) { World(..w, now: w.now + 1) })
  round([node_a])
  assert list.length(held(w, a)) == 64
  stop([node_a, node_b])
}

/// Shards asked for are handed over from processes of their own: a node
/// whose shards are slow to give themselves up goes on answering, and every
/// one of them is handed over in the time one takes.
pub fn a_slow_hand_over_does_not_hold_the_placement_up_test() {
  let w = world()
  let node_a = node(w, a)
  round([node_a])
  assert list.length(held(w, a)) == 64

  change(w, fn(w) { World(..w, give_up_ms: 300) })
  let node_b = node(w, b)
  // a sees b on its next look, and hears b's next want.
  process.send(node_a.to, placement.Look)
  let _ = report(node_a)
  process.send(node_b.to, placement.Look)
  let _ = report(node_b)
  assert list.length(report(node_a).handing) == 32
  quiet(node_a, 200)
  assert list.length(held(w, a)) == 32
  stop([node_a, node_b])
}

/// A want for a shard the holder sees assigned to itself, or to somebody
/// other than the asker, is not the holder's to give.
pub fn a_want_for_a_shard_assigned_elsewhere_is_refused_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  let theirs = held(w, a)
  forget_takes(w)
  process.send(node_a.to, placement.Wanted(b, theirs))
  process.send(node_a.to, placement.Wanted(c, theirs))
  let _ = report(node_a)
  assert held(w, a) == theirs
  assert takes(w) == []
  stop([node_a, node_b])
}

/// Two nodes that see different members -- b has not heard of c yet -- move
/// nothing between them that they do not agree on: nothing moves twice, and
/// once b hears of c every shard is where all three say.
pub fn nodes_that_see_different_members_move_nothing_twice_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  forget_takes(w)

  // c starts; a hears of it at once, b does not.
  change(w, fn(w) {
    World(
      ..w,
      listed: w.listed
        |> dict.insert(a, [a, b, c])
        |> dict.insert(b, [a, b])
        |> dict.insert(c, [a, b, c]),
    )
  })
  let node_c = start(w, c)
  rounds([node_a, node_b, node_c], 4)
  assert each_moved_at_most_once(w)
  assert dict.size(seen(w).owners) == count

  change(w, fn(w) { World(..w, listed: dict.insert(w.listed, b, [a, b, c])) })
  rounds([node_a, node_b, node_c], 4)
  assert settled_as_assigned(w, [a, b, c])
  assert each_moved_at_most_once(w)
  stop([node_a, node_b, node_c])
}

/// A placement its supervisor restarted finds the trees it was running and
/// watches them again, and takes nothing twice.
pub fn a_restarted_placement_adopts_its_trees_test() {
  let w = world()
  let node_a = node(w, a)
  let node_b = node(w, b)
  rounds([node_a, node_b], 3)
  let ours = held(w, a)
  forget_takes(w)

  process.kill(node_a.pid)
  let node_a = start(w, a)
  assert report(node_a).held == list.sort(ours, int.compare)
  rounds([node_a, node_b], 2)
  assert takes(w) == []
  stop([node_a, node_b])
}
