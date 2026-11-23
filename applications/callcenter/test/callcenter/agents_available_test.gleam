//// How many agents could take a caller, as the dispatcher says it -- and
//// when it does not say it at all: `member_position`, `queue_stats` and the
//// `status_resp` a caller arriving is let in on.

import callcenter/types.{OnCall}
import cf_callcenter
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{Some}
import kazoo/doc
import support/cluster
import support/fake_activity
import support/fake_offer

fn queue() -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String("longest_idle")),
    #("agent_ring_timeout", doc.Int(20)),
    // A caller is turned away from a queue nobody could take them in.
    #("enter_when_empty", doc.Bool(False)),
    #("agents", doc.List([doc.object([#("id", doc.String("ann"))])])),
  ])
}

/// One queue, Ann in it and available.
fn ann_alone() -> cluster.Cluster {
  let c =
    cluster.new([#("support", queue())], [
      #(
        "ann",
        doc.object([
          #("pvt_type", doc.String("user")),
          #("call_center", doc.object([])),
        ]),
      ),
    ])
  cluster.agent_is(c, "ann", "available")
  c
}

fn stats_published() -> Int {
  published_events()
  |> list.filter(fn(event) { event == #("exchange", "queue_stats") })
  |> list.length
}

/// The `Agents-Available` of every `member_position` published, where it
/// was said.
fn positions_said() -> List(Result(Int, Nil)) {
  published_values("member_position", "Agents-Available")
  |> list.map(fn(published) {
    decode.run(published.1, decode.int) |> result_nil
  })
}

fn result_nil(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn status_available(c: cluster.Cluster) -> Result(Int, Nil) {
  let assert [support] = cluster.status(c, Some("support"))
  doc.get_int(support, ["Agents-Available"])
}

/// When the node's activity actor did not answer,
/// every tier state was `Standby`, and `Agents-Available` went out as 0 on
/// `member_position`, `queue_stats` and the `status_resp` -- although a
/// number nobody could work out is not zero. Every waiting caller's
/// no-agent clock started on it, and a caller arriving at a queue that does
/// not let them in empty was turned away. The dispatcher now says nothing
/// it cannot vouch for: the positions go without the count, no
/// `queue_stats` goes out, the status leaves it out -- and the caller
/// arriving is let in. Nobody is offered meanwhile. Once the actor answers,
/// the count is said again, zero when it is zero.
pub fn an_unread_activity_is_not_zero_agents_test() {
  let platform = platform_start()
  let c = ann_alone()
  fake_activity.silent(c.activity, "it did not answer in time")
  cluster.arrive(c, "call-one", "support", 0, 0)
  let offered = fake_offer.count(c.offers)
  let unknown = status_available(c)
  let said_while_unread = positions_said()
  let stats_while_unread = stats_published()

  fake_activity.agents(c.activity, [#("ann", OnCall(queue_call: False))])
  cluster.tick(c)
  let known = status_available(c)
  let stats_once_read = stats_published()
  // Every member_position without the count is one its definition takes.
  let refused = rejected()
  platform_stop(platform)

  assert offered == 0
  assert unknown == Error(Nil)
  assert said_while_unread != []
  assert list.all(said_while_unread, fn(said) { said == Error(Nil) })
  assert stats_while_unread == 0
  assert refused == []

  assert known == Ok(0)
  assert stats_once_read == 1
  // Zero, said, is a refusal again.
  let assert [support] = cluster.status(c, Some("support"))
  let status =
    cf_callcenter.status_of("support", [
      doc.object([#("Queues", doc.List([support]))]),
    ])
  assert cf_callcenter.entry(queue(), status) == cf_callcenter.NoAgents
}

/// A caller arriving while the activity is unread is let in: the status
/// says nothing about the agents, and a number not said is not a refusal.
pub fn a_caller_arriving_meanwhile_is_let_in_test() {
  let c = ann_alone()
  fake_activity.silent(c.activity, "it did not answer in time")
  cluster.arrive(c, "call-one", "support", 0, 0)
  let assert [support] = cluster.status(c, Some("support"))
  let status =
    cf_callcenter.status_of("support", [
      doc.object([#("Queues", doc.List([support]))]),
    ])
  assert cf_callcenter.entry(queue(), status) == cf_callcenter.Enter
}

/// The same while the account waits for the switches' first answer: the
/// count would be made from the channel events alone, in which an agent on
/// a personal call looks free, and it is not said either.
pub fn an_unsynced_account_does_not_say_how_many_test() {
  let c = ann_alone()
  fake_activity.unsynced(c.activity, [])
  cluster.redelivered(c, "call-one", "support", 0, 0)
  assert fake_offer.count(c.offers) == 0
  assert status_available(c) == Error(Nil)

  // The answer: Ann is free, and is rung at once -- so nobody is left, and
  // that is said.
  fake_activity.agents(c.activity, [])
  cluster.tick(c)
  assert cluster.ringing(c, "call-one") == ["ann"]
  assert status_available(c) == Ok(0)
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
