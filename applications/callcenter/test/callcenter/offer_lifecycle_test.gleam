//// What the caller's action is told about an offer, and when: the
//// dispatcher against a fake offer, with the broker standing in so that
//// what it publishes can be read back.

import callcenter/dispatcher
import callcenter/dispatcher/config
import callcenter/dispatcher/offers
import callcenter/dispatcher/state.{Offer, State}
import callcenter/types.{
  type Member, ExitKey, Failed, Hangup, OfferNoAnswer, OfferRinging, Timeout,
}
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import kazoo/doc
import support/bare_state
import support/cluster
import support/fake_offer

fn queue(agents: List(String)) -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String("longest_idle")),
    #("agent_ring_timeout", doc.Int(20)),
    #(
      "agents",
      doc.List(
        list.map(agents, fn(id) { doc.object([#("id", doc.String(id))]) }),
      ),
    ),
  ])
}

fn agent() -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object([])),
  ])
}

/// One queue, Ann in it and available.
fn ann_alone() -> cluster.Cluster {
  let c = cluster.new([#("support", queue(["ann"]))], [#("ann", agent())])
  cluster.agent_is(c, "ann", "available")
  c
}

fn offers_told() -> Int {
  published_events()
  |> list.filter(fn(event) { event == #("exchange", "member_offer") })
  |> list.length
}

fn release(c: cluster.Cluster, agent_id: String) -> Nil {
  let _known =
    process.call(c.dispatcher, 5000, dispatcher.ReleaseAgent(agent_id, _))
  cluster.sync(c)
}

// --- member_offer follows the bridge ---------------------------------------

/// The action hears `member_offer` once the offer says its bridge went out,
/// and not when the offer is only asked for. An offer that fails before it
/// rings -- here, nothing of the agent's to ring -- never told the action
/// anything, so nothing is left believing in a ring.
pub fn member_offer_waits_for_the_bridge_test() {
  let platform = platform_start()
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  assert fake_offer.count(c.offers) == 1
  let asked = offers_told()

  cluster.reply(c, "call-one", Failed("no_endpoints"))
  let failed = offers_told()

  // Offered again once the failure's delay is over, and this time it rings.
  cluster.at(c, 6)
  cluster.tick(c)
  assert fake_offer.count(c.offers) == 2
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  let rung = offers_told()
  platform_stop(platform)

  assert asked == 0
  assert failed == 0
  assert rung == 1
}

/// An agent whose every device is disabled fails every offer before it
/// rings, pass after pass. The caller is never told they are being offered,
/// so their no-agent clock runs and their announcements fall due.
pub fn nothing_to_ring_is_never_an_offer_test() {
  let platform = platform_start()
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  list.each([6, 12, 18, 24], fn(second) {
    cluster.reply(c, "call-one", Failed("no_endpoints"))
    cluster.at(c, second)
    cluster.tick(c)
  })
  let tries = fake_offer.count(c.offers)
  let told = offers_told()
  platform_stop(platform)

  assert tries == 5
  assert told == 0
}

/// A ring called off before it went out is not told either: it is being
/// unbridged the moment it is out.
pub fn a_ring_called_off_before_it_went_out_is_not_told_test() {
  let platform = platform_start()
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  release(c, "ann")
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  let told = offers_told()
  platform_stop(platform)

  assert told == 0
  assert cluster.called_off(c) == ["call-one"]
}

// --- The end of a ring the channel did not show -----------------------------

/// A ring the action was told of that ends unanswered has the caller's
/// position published again, saying no offer is in flight: the action's
/// word for the end of a ring whose bridge never finished on its channel.
/// While an offer is in flight -- asked for, or ringing -- the position says
/// one is.
pub fn the_end_of_a_ring_is_told_with_the_position_test() {
  let platform = platform_start()
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  let while_asked = offered_values()
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  cluster.reply(c, "call-one", OfferNoAnswer(["ann"]))
  let after = offered_values()
  platform_stop(platform)

  assert while_asked == [#("exchange", True)]
  assert list.last(after) == Ok(#("exchange", False))
  assert list.length(after) == 2
}

// --- A caller leaving while an offer is in flight ---------------------------

/// A caller leaving -- an exit key, a timeout -- while their phones ring has
/// the ring called off by the offer's process, which unbridges it unless it
/// has seen it end. The dispatcher sends no unbridge of its own: the caller's
/// action unbridged the ring too and goes on once it ends, and one from here
/// could land in the next callflow action's ring. The agents go free at once.
pub fn a_caller_leaving_during_the_ring_calls_it_off_test() {
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))

  assert cluster.cancel(c, "call-one", ExitKey)
  assert cluster.called_off(c) == []
  assert cluster.stopped(c) == ["call-one to unbridge"]
  assert cluster.all_ringing(c) == []

  // Ann takes the next caller at once, and the called-off offer's reply,
  // when it comes, is about an offer this dispatcher no longer holds.
  cluster.arrive(c, "call-two", "support", 0, 1)
  assert cluster.ringing(c, "call-two") == ["ann"]
  let assert Ok(first) = fake_offer.requests(c.offers) |> list.first
  fake_offer.reply(first, Failed("originator_cancel"))
  cluster.sync(c)
  assert cluster.ringing(c, "call-two") == ["ann"]
}

/// A caller leaving before the dispatcher knows the bridge is out: nothing
/// is unbridged here, since there may be no bridge yet, and the offer's
/// process is told to call the ring off itself -- by not sending its bridge,
/// or by unbridging the one it sent. The action, which heard no
/// `member_offer`, unbridged nothing either.
pub fn a_caller_leaving_before_the_ring_is_out_stops_the_offer_test() {
  let platform = platform_start()
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.cancel(c, "call-one", Timeout)
  let called_off = cluster.called_off(c)
  let stopped = cluster.stopped(c)
  // The offer's reply that it rang after all is dropped, with nothing told.
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  let told = offers_told()
  platform_stop(platform)

  assert called_off == []
  assert stopped == ["call-one to unbridge"]
  assert cluster.called_off(c) == []
  assert told == 0
  assert cluster.all_ringing(c) == []
}

/// A caller leaving an offer whose process has gone, before this dispatcher
/// has heard it go, has nobody else to call the ring off: the dispatcher
/// unbridges it itself. One whose process is running is left to the
/// process, and nothing is unbridged here.
pub fn a_caller_leaving_an_offer_whose_process_has_gone_is_unbridged_here_test() {
  let called_off = process.new_subject()
  let stopped = process.new_subject()
  let bare = bare_state.new()
  let watched =
    State(
      ..bare,
      config: config.Config(
        ..bare.config,
        call_off: fn(member: Member) {
          process.send(called_off, member.call_id)
        },
        stop_offer: fn(_pid, unbridged, member: Member) {
          process.send(stopped, #(member.call_id, unbridged))
        },
      ),
    )
    |> bare_state.waiting("call-one")
  let leave = fn(ring) {
    watched |> bare_state.held(ring) |> offers.leave("call-one", ExitKey)
  }

  let _left = leave(bare_state.offer("call-one", ["ann"]))
  assert process.receive(called_off, 0) == Ok("call-one")
  assert process.receive(stopped, 0) == Error(Nil)

  let running = process.spawn_unlinked(fn() { process.sleep_forever() })
  let _left =
    leave(Offer(..bare_state.offer("call-one", ["ann"]), pid: Some(running)))
  assert process.receive(called_off, 0) == Error(Nil)
  assert process.receive(stopped, 0) == Ok(#("call-one", False))
  process.kill(running)
}

/// A caller whose channel has gone has no ring left to call off, and one
/// whose ring was already called off -- the agent released a moment before
/// -- is not called off twice.
pub fn a_hangup_or_a_second_call_off_sends_nothing_test() {
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  assert cluster.cancel(c, "call-one", Hangup)
  assert cluster.called_off(c) == []
  assert cluster.stopped(c) == []

  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  release(c, "ann")
  assert cluster.cancel(c, "call-one", ExitKey)
  assert cluster.called_off(c) == ["call-one"]
  assert cluster.stopped(c) == ["call-one unbridged"]
}

type Platform

@external(erlang, "platform_fakes", "start")
fn platform_start() -> Platform

@external(erlang, "platform_fakes", "stop")
fn platform_stop(platform: Platform) -> Nil

@external(erlang, "kapi_contract_ffi", "published_events")
fn published_events() -> List(#(String, String))

@external(erlang, "kapi_contract_ffi", "published_values")
fn published_offered(event: String, header: String) -> List(#(String, Bool))

fn offered_values() -> List(#(String, Bool)) {
  published_offered("member_position", "Offered")
}
