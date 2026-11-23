//// A queue document, or an agent, the datastore does not answer for: not
//// the same thing as a queue with nobody in it, nor an agent logged out.

import callcenter/dispatcher/settings
import callcenter/types.{Answered, Completed, Ended}
import cf_callcenter
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{Some}
import gleam/result
import kazoo/cache
import kazoo/doc
import kazoo/kazoo.{type Kazoo, Datamgr, Kazoo, Unavailable}
import support/cluster
import support/fake_offer

/// The documents the datastore does not answer for, by id.
const down = "unreadable_queue_test_down"

fn queue(strategy: String) -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String(strategy)),
    #("agent_ring_timeout", doc.Int(20)),
    #("enter_when_empty", doc.Bool(False)),
    #(
      "agents",
      doc.List([
        doc.object([#("id", doc.String("ann")), #("position", doc.Int(1))]),
        doc.object([#("id", doc.String("bob")), #("position", doc.Int(2))]),
      ]),
    ),
  ])
}

fn user() -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object([])),
  ])
}

/// Ann and Bob in support, whose strategy is `strategy`; the datastore
/// answers for everything until `unreadable` says otherwise.
fn support(strategy: String) -> cluster.Cluster {
  cache.clear(down)
  let c =
    cluster.new_with(
      [#("support", queue(strategy))],
      [#("ann", user()), #("bob", user())],
      failing,
    )
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  c
}

fn failing(kz: Kazoo) -> Kazoo {
  let unless_down = fn(id, read) {
    case cache.get(down, id) {
      Ok(True) -> Error(Unavailable)
      _up -> read()
    }
  }
  Kazoo(
    ..kz,
    datamgr: Datamgr(
      ..kz.datamgr,
      open_doc: fn(db, id) {
        unless_down(id, fn() { kz.datamgr.open_doc(db, id) })
      },
      open_cache_doc: fn(db, id) {
        unless_down(id, fn() { kz.datamgr.open_cache_doc(db, id) })
      },
    ),
  )
}

fn unreadable(id: String) -> Nil {
  cache.put(down, id, True)
}

fn readable(id: String) -> Nil {
  cache.delete(down, id)
}

fn status_available(c: cluster.Cluster) -> Result(Int, Nil) {
  let assert [support] = cluster.status(c, Some("support"))
  doc.get_int(support, ["Agents-Available"])
}

fn entry(c: cluster.Cluster) -> cf_callcenter.Entry {
  let assert [support] = cluster.status(c, Some("support"))
  cf_callcenter.entry(
    queue("longest_idle"),
    cf_callcenter.status_of("support", [
      doc.object([#("Queues", doc.List([support]))]),
    ]),
  )
}

fn positions_said() -> List(Result(Int, Nil)) {
  published_values("member_position", "Agents-Available")
  |> list.map(fn(published) {
    decode.run(published.1, decode.int) |> result.replace_error(Nil)
  })
}

fn stats_published() -> Int {
  published_events()
  |> list.filter(fn(event) { event == #("exchange", "queue_stats") })
  |> list.length
}

/// A queue document the datastore did not answer for,
/// with no copy of it on the node, was read as a queue with every default
/// and no agents, and the dispatcher said so -- `Agents-Available` 0 on
/// `member_position`, `queue_stats` and the `status_resp`, which starts
/// every caller's no-agent clock and turns away a caller at a queue that
/// does not let them in empty. Now nobody is offered from it and nothing is
/// said about its agents; once it is read again, it is dispatched as ever.
pub fn an_unreadable_queue_is_not_zero_agents_test() {
  let platform = platform_start()
  let c = support("longest_idle")
  unreadable("support")
  cluster.arrive(c, "call-one", "support", 0, 0)
  let offered = fake_offer.count(c.offers)
  let unknown = status_available(c)
  let let_in = entry(c)
  let said = positions_said()
  let stats = stats_published()

  readable("support")
  cluster.tick(c)
  let rung = cluster.ringing(c, "call-one")
  let refused = rejected()
  platform_stop(platform)

  assert offered == 0
  assert unknown == Error(Nil)
  assert let_in == cf_callcenter.Enter
  assert said != []
  assert list.all(said, fn(said) { said == Error(Nil) })
  assert stats == 0
  assert refused == []
  assert rung == ["ann"]
}

/// The last copy of the queue this node read stands in for it while the
/// datastore does not answer, and the caller is dispatched on it.
pub fn the_last_copy_read_stands_in_test() {
  let c = support("longest_idle")
  cluster.agent_is(c, "ann", "logged_out")
  cluster.agent_is(c, "bob", "logged_out")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert status_available(c) == Ok(0)

  unreadable("support")
  cluster.agent_is(c, "bob", "available")
  cluster.changed(c)
  assert cluster.ringing(c, "call-one") == ["bob"]
}

/// An agent who could be ready and could not be read was taken to be logged
/// out, and counted so. They are offered nothing, and the queue's count
/// leaves them out, so it is not said either.
pub fn an_unreadable_agent_is_counted_neither_way_test() {
  let platform = platform_start()
  let c = support("longest_idle")
  cluster.agent_is(c, "ann", "logged_out")
  unreadable("callcenter_agent-bob")
  cluster.arrive(c, "call-one", "support", 0, 0)
  let offered = fake_offer.count(c.offers)
  let unknown = status_available(c)
  let said = positions_said()
  let stats = stats_published()

  readable("callcenter_agent-bob")
  cluster.tick(c)
  let rung = cluster.ringing(c, "call-one")
  platform_stop(platform)

  assert offered == 0
  assert unknown == Error(Nil)
  assert said != []
  assert list.all(said, fn(said) { said == Error(Nil) })
  assert stats == 0
  assert rung == ["bob"]
}

/// The outcome of an offer heard while its queue cannot be read leaves the
/// strategy's memo alone. Read as nothing, the queue's strategy was the
/// default and the round robin's cursor was replaced by a new memo of that,
/// so the next caller started at the top of the tier again.
pub fn an_unreadable_queue_leaves_the_memo_alone_test() {
  let c = support("round_robin")
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert cluster.ringing(c, "call-one") == ["ann"]

  unreadable("support")
  // Nothing kept on the node either: the queue is unreadable, not stale.
  settings.forget_kept()
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "call-one-agent", cluster.start_of_time),
  )
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 5))

  readable("support")
  cluster.at(c, 30)
  cluster.tick(c)
  cluster.arrive(c, "call-two", "support", 0, 30)
  assert cluster.ringing(c, "call-two") == ["bob"]
}

type Platform

@external(erlang, "platform_fakes", "start")
fn platform_start() -> Platform

@external(erlang, "platform_fakes", "stop")
fn platform_stop(platform: Platform) -> Nil

@external(erlang, "kapi_contract_ffi", "published_events")
fn published_events() -> List(#(String, String))

@external(erlang, "kapi_contract_ffi", "published_values")
fn published_values(event: String, header: String) -> List(#(String, Dynamic))

@external(erlang, "kapi_contract_ffi", "rejected")
fn rejected() -> List(String)
