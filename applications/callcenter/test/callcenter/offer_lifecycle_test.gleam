//// What is told about an offer, and when: the dispatcher against a fake
//// offer, with the broker standing in so that what it publishes can be
//// read back, and the callers' actors recorded.

import callcenter/dispatcher
import callcenter/dispatcher/config
import callcenter/dispatcher/offers
import callcenter/dispatcher/state.{Offer, State}
import callcenter/types.{
  type Member, ExitKey, Failed, Hangup, OfferNoAnswer, OfferRinging,
  QueueDeleted, Timeout,
}
import gleam/dict
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

// --- An actor shut down ----------------------------------------------------

/// The offer under an actor its supervisor shut down is let go of: dropped,
/// its agents freed, and nothing else -- no outcome written, no miss, no
/// call-off, nothing published -- since the call goes on under whoever has
/// the caller's actor next (`dispatcher.OfferDown`). The caller stays
/// waiting, for a new actor to be joined to. Only the offer under that actor
/// goes, and an actor holding none changes nothing.
pub fn an_offer_let_go_of_frees_its_agents_and_nothing_else_test() {
  let platform = platform_start()
  let gone = process.spawn_unlinked(fn() { process.sleep_forever() })
  let other = process.spawn_unlinked(fn() { process.sleep_forever() })
  let stray = process.spawn_unlinked(fn() { process.sleep_forever() })
  let ring =
    Offer(..bare_state.offer("call-one", ["ann", "bob"]), pid: Some(gone))
  let kept = Offer(..bare_state.offer("call-two", ["cal"]), pid: Some(other))
  let before =
    bare_state.new()
    |> bare_state.waiting("call-one")
    |> bare_state.waiting("call-two")
    |> bare_state.held(ring)
    |> bare_state.held(kept)
  let events = list.length(published_events())

  let after = offers.let_go(before, gone)
  assert dict.keys(after.offers) == ["call-two"]
  assert dict.to_list(after.busy) == [#("cal", kept.id)]
  assert dict.has_key(after.waiting, "call-one")
  assert list.length(published_events()) == events
  assert offers.let_go(before, stray) == before

  list.each([gone, other, stray], process.kill)
  platform_stop(platform)
}

/// A deleted queue's caller whose departure a node taking them over takes
/// up again is not told of twice: the node that took them out of the queue
/// published their `member_result` then. One the dispatcher takes out of
/// the queue itself is told of.
pub fn a_departure_taken_up_again_is_not_told_twice_test() {
  let platform = platform_start()
  let results = fn() {
    published_events()
    |> list.filter(fn(event) { event.1 == "member_result" })
    |> list.length
  }
  let state = bare_state.new() |> bare_state.waiting("call-one")
  let before = results()
  let _ = offers.depart(state, "call-one", QueueDeleted)
  let departed = results()
  let _ = offers.leave(state, "call-one", QueueDeleted)
  let left = results()
  platform_stop(platform)
  assert departed == before
  assert left == before + 1
}

// --- member_offer follows the bridge ---------------------------------------

/// `member_offer` goes out once the actor says the ring went out, and not
/// when the offer is only asked for. An offer that fails before it rings --
/// here, nothing of the agent's to ring -- is never told as one.
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
/// rings, pass after pass, and none of it is told as an offer.
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

/// A ring called off before it went out is not told either: the actor
/// calls it off the moment it is out.
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

/// A ring that was told of and ends unanswered has the caller's position
/// published again, saying no offer is in flight. While an offer is in
/// flight -- asked for, or ringing -- the position says one is.
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
/// the ring called off by their actor, which decided they left; the
/// dispatcher's call-off, for a caller taken out any other way, is nothing
/// to an actor that has already let the ring go. The agents go free at
/// once.
pub fn a_caller_leaving_during_the_ring_calls_it_off_test() {
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))

  assert cluster.cancel(c, "call-one", ExitKey)
  assert cluster.called_off(c) == ["call-one"]
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

/// A caller leaving before the dispatcher knows the ring is out: the call-off
/// goes to the actor, which handles the ring first, and the reply that it
/// rang after all is dropped, with nothing told.
pub fn a_caller_leaving_before_the_ring_is_out_calls_it_off_test() {
  let platform = platform_start()
  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)

  assert cluster.cancel(c, "call-one", Timeout)
  let called_off = cluster.called_off(c)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  let told = offers_told()
  platform_stop(platform)

  assert called_off == ["call-one"]
  assert cluster.called_off(c) == ["call-one"]
  assert told == 0
  assert cluster.all_ringing(c) == []
}

/// A caller leaving an offer whose actor has gone, before this dispatcher
/// has heard it go, is told to the actor all the same: a call-off to an
/// actor that is not there is nothing, and one to an actor that is
/// running is the same call-off.
pub fn a_caller_leaving_an_offer_calls_it_off_whatever_its_actor_test() {
  let called_off = process.new_subject()
  let bare = bare_state.new()
  let watched =
    State(
      ..bare,
      config: config.Config(
        ..bare.config,
        calls: config.Calls(
          ..bare.config.calls,
          call_off: fn(member: Member, _offer) {
            process.send(called_off, member.call_id)
          },
        ),
      ),
    )
    |> bare_state.waiting("call-one")
  let leave = fn(ring) {
    watched |> bare_state.held(ring) |> offers.leave("call-one", ExitKey)
  }

  let _left = leave(bare_state.offer("call-one", ["ann"]))
  assert process.receive(called_off, 0) == Ok("call-one")

  let running = process.spawn_unlinked(fn() { process.sleep_forever() })
  let _left =
    leave(Offer(..bare_state.offer("call-one", ["ann"]), pid: Some(running)))
  assert process.receive(called_off, 0) == Ok("call-one")
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

  let c = ann_alone()
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", OfferRinging(["ann"]))
  release(c, "ann")
  assert cluster.cancel(c, "call-one", ExitKey)
  assert cluster.called_off(c) == ["call-one"]
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
