//// An agent the dispatcher still has an entry for in `busy`, naming an
//// offer it no longer holds -- the offer was replaced, say by a call
//// adopted over a connected one -- is in no offer, and the queue's view of
//// them is not Offering. Counted as busy, they would never be rung again.

import callcenter/dispatcher
import callcenter/dispatcher/pickup
import callcenter/dispatcher/settings
import callcenter/dispatcher/state.{type State}
import callcenter/dispatcher/status
import callcenter/dispatcher/view
import callcenter/types.{OfferId, Offering, Ready}
import gleam/dict
import gleam/erlang/process
import gleam/erlang/reference
import kazoo/doc
import support/bare_state
import support/cluster

fn state_with(busy: List(#(String, types.OfferId))) -> State {
  bare_state.new() |> bare_state.busy(busy)
}

fn support() -> settings.QueueSettings {
  settings.queue("support", doc.object([]), 30, "on_break")
}

fn stale() -> types.OfferId {
  OfferId("call-gone", reference.new())
}

pub fn an_entry_naming_a_replaced_offer_holds_nobody_test() {
  let s = state_with([#("ann", stale())])
  assert state.offer_of(s, "ann") == Error(Nil)
  assert view.tier_state(s, "ann", support()) == Ready
}

pub fn an_agent_with_no_entry_is_in_no_offer_test() {
  let s = state_with([])
  assert state.offer_of(s, "ann") == Error(Nil)
  assert view.tier_state(s, "ann", support()) != Offering
}

/// The supervisor `sup` asked to pick up the caller `call-one`.
fn pick_up(s: State) -> #(State, process.Subject(pickup.Answer)) {
  let done = process.new_subject()
  let request =
    pickup.Request(
      queue_id: "support",
      call_id: "call-one",
      supervisor_id: "sup",
      target_type: "user",
      target_id: "sup",
      device_ids: ["sup-desk"],
    )
  #(
    pickup.start(
      s,
      request,
      cluster.start_of_time,
      monotonic_ms() + 60_000,
      done,
    ),
    done,
  )
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

/// A pickup asked a raw `busy` entry whether the supervisor
/// was busy, and a stale one refused it with `supervisor_busy`. It rings,
/// and the supervisor's entry is the pickup's from then on.
pub fn a_stale_entry_does_not_make_a_supervisor_busy_test() {
  let #(s, done) =
    state_with([#("sup", stale())])
    |> bare_state.waiting("call-one")
    |> pick_up
  assert process.receive(done, 0) == Error(Nil)
  let assert Ok(offer) = dict.get(s.offers, "call-one")
  assert pickup.is_pickup(s, offer)
  assert dict.get(s.busy, "sup") == Ok(offer.id)

  // An offer the supervisor is really in still refuses it.
  let #(_s, done) =
    bare_state.new()
    |> bare_state.held(bare_state.offer("call-two", ["sup"]))
    |> bare_state.waiting("call-one")
    |> pick_up
  assert process.receive(done, 0) == Ok(pickup.SupervisorBusy)
}

/// A release answered that it knew an agent, and `sup` listed
/// them, on a stale entry alone. Neither does; an offer they are in counts.
pub fn a_stale_entry_is_not_known_test() {
  let s = state_with([#("ann", stale())])
  assert !dispatcher.knows(s, "ann")
  assert status.known_agents(s) == []

  let s =
    bare_state.new() |> bare_state.held(bare_state.offer("call-one", ["ann"]))
  assert dispatcher.knows(s, "ann")
  assert status.known_agents(s) == ["ann"]
}
