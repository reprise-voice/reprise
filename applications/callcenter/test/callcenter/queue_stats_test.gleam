//// `queue_stats` when a queue empties: the last caller leaving is a change
//// of the queue's shape like any other, and is said.

import callcenter/types.{Hangup}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import kazoo/doc
import support/cluster
import support/fake_activity

fn queue() -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String("longest_idle")),
    #("agent_ring_timeout", doc.Int(20)),
    #("agents", doc.List([doc.object([#("id", doc.String("ann"))])])),
  ])
}

/// One queue, Ann in it and logged out: a caller waits and nobody is rung.
fn nobody_free() -> cluster.Cluster {
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
  cluster.agent_is(c, "ann", "logged_out")
  c
}

/// The `Waiting` of every `queue_stats` published, in order.
fn waiting_said() -> List(Int) {
  published_values("queue_stats", "Waiting")
  |> list.filter_map(fn(published) {
    case decode.run(published.1, decode.int) {
      Ok(waiting) -> Ok(waiting)
      Error(_) -> Error(Nil)
    }
  })
}

/// `queue_stats` went out only for a queue with
/// somebody still waiting, so when the last caller left nothing said so and
/// a wallboard went on showing one waiting. The pass now says the queue
/// empty, once.
pub fn the_last_caller_leaving_is_said_test() {
  let platform = platform_start()
  let c = nobody_free()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let while_waiting = waiting_said()
  let _held = cluster.cancel(c, "call-one", Hangup)
  let after_leaving = waiting_said()
  cluster.tick(c)
  cluster.tick(c)
  let after_more_passes = waiting_said()
  platform_stop(platform)

  assert while_waiting == [1]
  assert after_leaving == [1, 0]
  assert after_more_passes == [1, 0]
}

/// An emptying the dispatcher cannot count the agents for is not said while
/// it cannot: the queue keeps its last shape, and is said empty on the
/// first pass that can.
pub fn an_emptying_waits_for_a_vouched_count_test() {
  let platform = platform_start()
  let c = nobody_free()
  cluster.arrive(c, "call-one", "support", 0, 0)
  fake_activity.silent(c.activity, "it did not answer in time")
  let _held = cluster.cancel(c, "call-one", Hangup)
  let while_unread = waiting_said()
  fake_activity.agents(c.activity, [])
  cluster.tick(c)
  let once_read = waiting_said()
  platform_stop(platform)

  assert while_unread == [1]
  assert once_read == [1, 0]
}

type Platform

@external(erlang, "platform_fakes", "start")
fn platform_start() -> Platform

@external(erlang, "platform_fakes", "stop")
fn platform_stop(platform: Platform) -> Nil

@external(erlang, "kapi_contract_ffi", "published_values")
fn published_values(event: String, header: String) -> List(#(String, Dynamic))
