//// A dispatcher's state with no actor around it: a fake datastore with no
//// documents, and everything the state calls out through doing nothing. For
//// the tests that are about what one function does to the state.

import callcenter/dispatcher/config
import callcenter/dispatcher/state.{
  type Offer, type State, Offer, Pickup, State, Wait,
}
import callcenter/presence
import callcenter/queue_doc
import callcenter/types.{type OfferId, OfferId}
import gleam/dict
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{None}
import kazoo/testing/fake
import support/cluster
import support/fake_activity
import support/fake_offer

/// Nobody waiting, nothing offered, nobody busy, and the clock at
/// `cluster.start_of_time`.
pub fn new() -> State {
  let datastore = fake.new()
  fake.set_now(datastore, cluster.start_of_time)
  let kz = fake.kazoo(datastore)
  let activities = fake_activity.new()
  State(
    config: config.Config(
      kz: kz,
      account_id: "account",
      announce_interval_s: 30,
      offer_grace_s: 5,
      default_no_answer_status: "on_break",
      queue_refresh_s: queue_doc.default_refresh_s,
      now: kz.now,
      start_watch: fn(_request) { Error("no watches here") },
      settle: fn(_member) { Nil },
      lamp: fn(_agent_id, _state) { Nil },
      activity: fake_activity.reader(activities),
      call_off: fn(_member) { Nil },
      stop_offer: fn(_pid, _unbridged, _member) { Nil },
    ),
    ticks: process.new_subject(),
    replies: process.new_subject(),
    start_offer: fake_offer.start_offer(fake_offer.new()),
    waiting: dict.new(),
    offers: dict.new(),
    pickups: dict.new(),
    leaving: dict.new(),
    busy: dict.new(),
    delayed: dict.new(),
    wrapup: dict.new(),
    stood_down: dict.new(),
    no_document: dict.new(),
    misses: dict.new(),
    memo: dict.new(),
    worked: dict.new(),
    stats: dict.new(),
    lamps: presence.lamps(),
    ticking: False,
    listening: None,
    activities: state.Read(dict.new()),
    sync: state.Synced,
    watch_activity: fn() { Nil },
  )
}

/// These agents busy in the offer `id`, whether or not it is held.
pub fn busy(state: State, entries: List(#(String, OfferId))) -> State {
  State(
    ..state,
    busy: list.fold(entries, state.busy, fn(busy, entry) {
      dict.insert(busy, entry.0, entry.1)
    }),
  )
}

/// A caller waiting in queue `support`.
pub fn waiting(state: State, call_id: String) -> State {
  let member = cluster.member(call_id, "support", 0, cluster.start_of_time)
  State(
    ..state,
    waiting: dict.insert(
      state.waiting,
      call_id,
      Wait(
        member: member,
        position: 0,
        announced_at: 0,
        rerun: False,
        tried: [],
      ),
    ),
  )
}

/// An offer of a caller in queue `support` ringing these agents, with no
/// process behind it.
pub fn offer(call_id: String, agents: List(String)) -> Offer {
  Offer(
    id: OfferId(call_id: call_id, serial: reference.new()),
    queue_id: "support",
    member: cluster.member(call_id, "support", 0, cluster.start_of_time),
    agents: agents,
    ringing: agents,
    started_at: cluster.start_of_time,
    ceiling: cluster.start_of_time + 30,
    connected: None,
    pid: None,
    rung: True,
    called_off: False,
  )
}

/// The offer held, its agents busy in it.
pub fn held(state: State, offer: Offer) -> State {
  State(..state, offers: dict.insert(state.offers, offer.member.call_id, offer))
  |> busy(list.map(offer.agents, fn(agent_id) { #(agent_id, offer.id) }))
}

/// The offer held as a supervisor's pickup.
pub fn picked_up(state: State, offer: Offer) -> State {
  let state = held(state, offer)
  State(
    ..state,
    pickups: dict.insert(
      state.pickups,
      offer.member.call_id,
      Pickup(
        id: offer.id,
        target_type: "user",
        target_id: "",
        tell: None,
        answer_by: 0,
      ),
    ),
  )
}
