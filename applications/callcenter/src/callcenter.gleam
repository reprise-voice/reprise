//// The reprise call center.
////
//// Queues, agents, and the dispatchers that connect them. The application is
//// started by `kapps_controller` on a kazoo_apps node (`KAZOO_APPS=...,
//// callcenter`, or the `kapps` list in `system_config/kapps_controller`);
//// see `callcenter/app` for the OTP application callbacks.
////
//// Every node runs the same tree. What differs between two nodes is only
//// which shards the broker has handed them, and that changes on its own.

import callcenter/activity
import callcenter/closed
import callcenter/dnd
import callcenter/lamp_probe
import callcenter/offer
import callcenter/pickup
import callcenter/placement
import callcenter/reconcile
import callcenter/records
import callcenter/shard
import callcenter/shards
import callcenter/status
import callcenter/system
import callcenter/types.{
  type OfferRequest, Answered, Completed, Ended, Failed, OfferRinging,
}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import kazoo/amqp
import kazoo/kazoo.{type Kazoo}
import kazoo/listener
import kazoo/modb

pub fn main() -> Nil {
  let assert Ok(_) = start(system.live(), shards.default_count)
  process.sleep_forever()
}

/// Start the supervision tree.
///
/// One for one, because these are independent jobs and none of them is worth
/// restarting the others for:
///
/// - the owner of the table of passages closed lately (`closed`), first so
///   that the sweep and the dispatchers find it there and a crash in either
///   keeps it;
/// - the record writer, which serialises every document this application
///   writes so that no dispatcher waits on a datastore;
/// - the activity actor, which derives what every agent's phones are doing
///   from the channel events of the accounts this node dispatches for,
///   and the configuration listener that tells it when a queue document
///   changed or a media node expired;
/// - the status responder, which answers live queries for the accounts this
///   node dispatches for and stays quiet for the rest;
/// - the pickup responder, which hands a supervisor's pickup to the
///   dispatcher holding the caller, on the same terms;
/// - the login lamp probe responder, which answers a phone subscribing to
///   an agent's lamp that Kamailio has no state for, off a queue every node
///   shares;
/// - the reconciler, the sweep behind the events;
/// - the node's confirming publisher, the one channel every caller's
///   `member_call` goes out on;
/// - the placement, which takes the shards assigned to this node and hands
///   over the ones another member asks for.
pub fn start(
  kz: Kazoo,
  count: Int,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  system.log(
    "starting on "
    <> system.node_name()
    <> " with "
    <> int.to_string(count)
    <> " shards",
  )
  list.fold(
    children(kz, count),
    supervisor.new(supervisor.OneForOne)
      // A shard whose broker channel keeps failing must not be able to take
      // the other sixty-three down with it.
      |> supervisor.restart_tolerance(intensity: 10, period: 60),
    supervisor.add,
  )
  |> supervisor.start
}

fn children(
  kz: Kazoo,
  count: Int,
) -> List(supervision.ChildSpecification(Nil)) {
  let always = [
    closed.supervised(),
    records.supervised(kz),
    activity.supervised(kz),
    reconcile.supervised(kz, count),
  ]
  // Everything that consumes AMQP needs a `gen_listener`, which a release
  // has and `gleam run` and the test suite do not. Without one the rest of
  // the tree still starts, which is what lets any of this be tested.
  case system.broker_available() {
    False -> always
    True ->
      always
      |> list.append([amqp.confirming_publisher()])
      |> list.append([
        supervised_listener(activity.conf_listener(queue_deleted(count))),
      ])
      |> list.append([status.supervised(count)])
      |> list.append([pickup.supervised(count)])
      |> list.append(lamp_probe.supervised(kz, count))
      |> list.append(dnd.supervised(kz))
      |> list.append(placement.supervised(count, start_offer(kz)))
  }
}

/// A queue deleted anywhere in the cluster, told to its account's dispatcher
/// when this node is the one dispatching the account. In a process of its
/// own: finding the dispatcher asks the shard, and the listener that heard
/// the deletion must not wait on that.
fn queue_deleted(count: Int) -> fn(String, String) -> Nil {
  fn(account_id, queue_id) {
    let _ =
      process.spawn_unlinked(fn() {
        shard.queue_deleted(
          shards.of_account(account_id, count),
          account_id,
          queue_id,
        )
      })
    Nil
  }
}

fn supervised_listener(
  described: listener.Listener,
) -> supervision.ChildSpecification(Nil) {
  described
  |> listener.supervised
  |> supervision.map_data(fn(_server) { Nil })
}

/// How this node rings an agent.
///
/// The one seam between choosing an agent and dialling one. The call path is
/// `callcenter/offer`, built and shipped separately, and this is the line
/// that names it once it is there. Until then a node answers that no offer
/// can be made, which the dispatcher logs and treats as an offer it could
/// not start: the caller stays in the queue and is offered again next pass.
///
/// `system_config/callcenter.stub_offer` turns on an offer that rings
/// nobody and answers on a timer. It exists so that the dispatcher, the
/// events and the documents can be exercised on a cluster with no media
/// server, which is every cluster this is developed on.
pub fn start_offer(kz: Kazoo) -> shard.StartOffer {
  case kz.config.get_string("stub_offer", "false") {
    "true" | "1" -> stub_offer(kz)
    _off -> offer.start
  }
}

fn milliseconds(kz: Kazoo, key: String, default: Int) -> Int {
  case int.parse(kz.config.get_string(key, "")) {
    Ok(milliseconds) if milliseconds >= 0 -> milliseconds
    _unset -> kz.config.get_int(key, default)
  }
}

/// An offer that rings nobody: ringing at once, answered after
/// `stub_offer_answer_ms`, ended after `stub_offer_talk_ms`.
fn stub_offer(kz: Kazoo) -> shard.StartOffer {
  // `sup kapps_config set_default` stores whatever it was given as a string,
  // so these are read as one and turned into a number here rather than
  // trusting the type in the document.
  let answer_ms = milliseconds(kz, "stub_offer_answer_ms", 1000)
  let talk_ms = milliseconds(kz, "stub_offer_talk_ms", 3000)
  fn(request: OfferRequest) -> Result(Pid, String) {
    let call_id = request.member.call_id
    let id = request.id
    Ok(
      process.spawn_unlinked(fn() {
        process.send(request.reply_to, #(id, OfferRinging(request.agents)))
        process.sleep(answer_ms)
        case request.agents {
          [] -> process.send(request.reply_to, #(id, Failed("no agents")))
          [agent_id, ..] -> {
            process.send(request.reply_to, #(
              id,
              Answered(agent_id, call_id <> "-agent", modb.now()),
            ))
            process.sleep(talk_ms)
            process.send(request.reply_to, #(id, Ended(Completed, modb.now())))
          }
        }
      }),
    )
  }
}
