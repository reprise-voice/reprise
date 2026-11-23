//// The timers: the per-agent delay after a miss, the wrap-up after a call,
//// the ceiling on an offer that never came back, and the tick that looks at
//// all three.
////
//// Nothing ticks while nothing is waiting on the clock. The actor maps the
//// tick into its own mailbox as `Tick`, and `tick` is what it does then.

import callcenter/activity
import callcenter/dispatcher/offers
import callcenter/dispatcher/pickup
import callcenter/dispatcher/state.{type Offer, type State, State}
import callcenter/system
import callcenter/types.{FailedBridge}
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string

/// How often the timers are looked at while anything is waiting. One second
/// is finer than any of them needs and cheap: only an account with a caller
/// in it has a dispatcher at all.
const tick_ms = 1000

/// Everything that happens because time passed.
pub fn tick(state: State) -> State {
  let now = state.config.now()
  state
  |> expire_delays(now)
  |> expire_stand_downs(now)
  |> expire_wrapups(now)
  |> expire_offers(now)
  |> expire_calls(now)
}

/// Whether anything here is waiting on the clock: a caller, an offer, a
/// wrap-up, or an agent's delay after a miss. Nothing is, on an account with
/// nobody in it, and then nothing ticks: the next message is the next thing
/// that happens.
fn timed(state: State) -> Bool {
  !{
    dict.is_empty(state.waiting)
    && dict.is_empty(state.offers)
    && dict.is_empty(state.wrapup)
    && dict.is_empty(state.delayed)
    && dict.is_empty(state.stood_down)
  }
}

fn expire_delays(state: State, now: Int) -> State {
  State(
    ..state,
    delayed: dict.filter(state.delayed, fn(_agent_id, until) { until > now }),
  )
}

/// A stand-down whose `agent_availability` was never heard: the write failed,
/// or its event went nowhere. The agent is let go after
/// `offers.stand_down_hold_s` all the same, to whatever their document says
/// now, rather than held back for ever by a mark nothing will clear.
fn expire_stand_downs(state: State, now: Int) -> State {
  let #(over, held) =
    dict.to_list(state.stood_down)
    |> list.partition(fn(entry) { entry.1 <= now })
  list.each(over, fn(entry) {
    system.log(
      "agent "
      <> entry.0
      <> " was stood down and no availability change was heard for it: "
      <> "going by the document again",
    )
  })
  case over {
    [] -> state
    _ -> State(..state, stood_down: dict.from_list(held))
  }
}

fn expire_wrapups(state: State, now: Int) -> State {
  let over =
    dict.filter(state.wrapup, fn(_agent_id, ends) { ends <= now })
    |> dict.keys
  list.each(over, fn(agent_id) {
    activity.clear(state.config.account_id, agent_id)
  })
  State(
    ..state,
    wrapup: dict.filter(state.wrapup, fn(_agent_id, ends) { ends > now }),
  )
}

/// Requirement 0.6: an offer has a ceiling, so an agent can never be left
/// ringing because a bridge result was missed. Past it the agents are
/// released.
///
/// An offer that had a process is only taken back once that process has
/// gone (`still_ringing`), and a process that went without a reply is a
/// crash, which is what `offers.down` closes when the monitor says so: its
/// ring called off, `Failed`, nobody's miss. The tick can see the process
/// gone before that word has been heard, and closes it the same way
/// (`offers.lost`) -- read as a no answer instead, every agent it rang was
/// charged a miss, and possibly stood down, for a ring left going on the
/// caller's channel with nobody to call it off. An offer with no process
/// to ask is counted as a no answer.
fn expire_offers(state: State, now: Int) -> State {
  let stuck =
    dict.values(state.offers)
    |> list.filter(fn(offer) {
      offer.connected == None && offer.ceiling <= now && !still_ringing(offer)
    })
  list.fold(stuck, state, fn(state, offer) {
    use <- unless_pickup(state, offer, now)
    case offer.pid {
      Some(_gone) -> offers.lost(state, offer, "gone past its ceiling")
      None -> {
        system.log_error(
          "offer for call "
          <> offer.member.call_id
          <> " never came back: releasing "
          <> string.join(offer.agents, ", "),
        )
        let ringing = case offer.ringing {
          [] -> offer.agents
          ringing -> ringing
        }
        case offer.called_off {
          True -> offers.give_up(state, offer)
          False -> offers.missed(state, offer, ringing, "no_answer")
        }
      }
    }
  })
}

/// A supervisor's pickup is nobody's miss and nobody's call to count: one
/// with nothing left watching it is closed by `dispatcher/pickup`.
fn unless_pickup(
  state: State,
  offer: Offer,
  now: Int,
  otherwise: fn() -> State,
) -> State {
  case pickup.is_pickup(state, offer) {
    True -> pickup.expired(state, offer, now)
    False -> otherwise()
  }
}

/// A connected call with nothing watching it: its offer's or takeover's
/// process is gone. Its monitor normally says so the moment it goes
/// (`offers.down`); this is the backstop for one whose word was lost, so
/// that an agent is never held busy until the sweep's ten minutes come round
/// by a call nobody will ever report the end of. It is closed the way `down`
/// closes it, as a call whose end was lost.
fn expire_calls(state: State, now: Int) -> State {
  let unwatched =
    dict.values(state.offers)
    |> list.filter(fn(offer) {
      option.is_some(offer.connected) && !still_ringing(offer)
    })
  list.fold(unwatched, state, fn(state, offer) {
    use <- unless_pickup(state, offer, now)
    system.log_error(
      "call "
      <> offer.member.call_id
      <> " to "
      <> string.join(offer.agents, ", ")
      <> " has nothing watching it: closing it",
    )
    offers.ended(state, offer, FailedBridge, now)
  })
}

/// Whether the offer's own process is still there to answer for itself.
///
/// The ceiling is for an offer that will never reply -- its process crashed,
/// or the switch said nothing and it went with it. An offer whose process is
/// alive has not finished: its phones may still be ringing, and taking it
/// back now would free agents who are still being rung and charge them a miss
/// for a ring whose real outcome would then be dropped as stale.
fn still_ringing(offer: Offer) -> Bool {
  case offer.pid {
    Some(pid) -> process.is_alive(pid)
    None -> False
  }
}

/// The next tick, if one is already on its way or there is anything to
/// time. A dispatcher with nothing to time sits on its mailbox and costs
/// nothing a second: it is not stopped, because stopping it is what put a
/// caller's cancel and a dispatcher's own exit in a race, and an actor per
/// account that has had a caller since the shard was taken is cheap.
pub fn schedule(state: State) -> State {
  case state.ticking, timed(state) {
    True, _ | False, False -> state
    False, True -> {
      let _ = process.send_after(state.ticks, tick_ms, Nil)
      State(..state, ticking: True)
    }
  }
}
