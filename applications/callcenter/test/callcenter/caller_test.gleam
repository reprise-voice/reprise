//// The clocks a waiting caller runs on.

import callcenter/caller
import gleam/option.{None, Some}
import kazoo/doc

/// A queue document as `queues.json` fills it in.
fn queue(members: List(#(String, doc.Value))) -> doc.Value {
  doc.object(members)
}

const joined = 63_900_000_000

fn limits(
  max_wait: Int,
  no_agent: Int,
  after: Int,
  announce: Int,
) -> caller.Limits {
  caller.Limits(
    max_wait_s: max_wait,
    max_wait_with_no_agent_s: no_agent,
    no_agent_after_s: after,
    announce_interval_s: announce,
  )
}

pub fn limits_from_the_queue_test() {
  let read =
    caller.limits(
      queue([
        #("max_wait_time", doc.Int(120)),
        #("max_wait_time_with_no_agent", doc.Int(30)),
        #("max_wait_time_with_no_agent_time_reached", doc.Int(5)),
      ]),
    )
    |> caller.with_announce_interval(45)
  assert read == limits(120, 30, 5, 45)
}

/// Nothing said is no limit at all, which is what `queues.json` defaults to.
pub fn limits_default_to_none_test() {
  assert caller.limits(queue([#("name", doc.String("Support"))]))
    == limits(0, 0, 0, 0)
}

pub fn exit_keys_test() {
  assert caller.exit_keys(queue([#("exit_keys", doc.String("19#"))]))
    == ["1", "9", "#"]
}

/// acdc's single key is taken when the queue has no `exit_keys`.
pub fn exit_keys_fall_back_to_the_single_key_test() {
  assert caller.exit_keys(queue([#("caller_exit_key", doc.String("*"))]))
    == ["*"]
  assert caller.exit_keys(queue([])) == []
}

/// An `exit_keys` of "" is a queue that has turned them off, and must not
/// fall back to the deprecated single key.
pub fn empty_exit_keys_turn_them_off_test() {
  assert caller.exit_keys(
      queue([
        #("exit_keys", doc.String("")),
        #("caller_exit_key", doc.String("#")),
      ]),
    )
    == []
}

pub fn a_caller_with_no_limits_never_expires_test() {
  let waiting = caller.new(joined)
  assert caller.expired(waiting, limits(0, 0, 0, 0), joined + 100_000) == None
}

pub fn max_wait_expires_test() {
  let waiting = caller.new(joined)
  let of = limits(120, 0, 0, 0)
  assert caller.expired(waiting, of, joined + 119) == None
  assert caller.expired(waiting, of, joined + 120) == Some(caller.WaitedTooLong)
}

/// The no-agent clock starts when the queue first says nobody can take the
/// caller, not when they arrived.
pub fn no_agent_expires_from_the_first_empty_position_test() {
  let of = limits(0, 30, 0, 0)
  let waiting =
    caller.new(joined)
    |> caller.positioned(
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(0),
      at: joined + 10,
    )
  assert caller.expired(waiting, of, joined + 39) == None
  assert caller.expired(waiting, of, joined + 40) == Some(caller.NoAgentTooLong)
}

/// `max_wait_time_with_no_agent_time_reached` holds the no-agent clock off
/// until the caller has waited that long whatever the queue says.
pub fn no_agent_waits_for_the_time_reached_test() {
  let of = limits(0, 5, 60, 0)
  let waiting =
    caller.new(joined)
    |> caller.positioned(
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(0),
      at: joined,
    )
  assert caller.expired(waiting, of, joined + 30) == None
  assert caller.expired(waiting, of, joined + 60) == Some(caller.NoAgentTooLong)
}

/// An agent appearing clears the clock; if they go away again it starts over.
pub fn an_agent_appearing_clears_the_no_agent_clock_test() {
  let of = limits(0, 30, 0, 0)
  let waiting =
    caller.new(joined)
    |> caller.positioned(
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(0),
      at: joined,
    )
    |> caller.positioned(
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(2),
      at: joined + 10,
    )
  assert waiting.no_agents_since == None
  assert caller.expired(waiting, of, joined + 40) == None

  let again =
    caller.positioned(
      waiting,
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(0),
      at: joined + 20,
    )
  assert again.no_agents_since == Some(joined + 20)
  assert caller.expired(again, of, joined + 49) == None
  assert caller.expired(again, of, joined + 50) == Some(caller.NoAgentTooLong)
}

/// A position event that does not carry a count leaves what was known alone.
pub fn a_position_without_counts_keeps_what_was_known_test() {
  let waiting =
    caller.new(joined)
    |> caller.positioned(
      position: Some(4),
      waiting: Some(7),
      agents_available: Some(1),
      at: joined,
    )
    |> caller.positioned(
      position: None,
      waiting: None,
      agents_available: None,
      at: joined + 5,
    )
  assert waiting.position == Some(4)
  assert waiting.waiting == Some(7)
  assert waiting.agents_available == Some(1)
}

/// Once an agent has the caller, no clock runs.
pub fn a_connected_caller_has_no_clocks_test() {
  let of = limits(10, 10, 0, 10)
  let connected =
    caller.new(joined)
    |> caller.positioned(
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(0),
      at: joined,
    )
    |> caller.connect
  assert caller.expired(connected, of, joined + 1000) == None
  assert caller.announcement_due(connected, of, joined + 1000) == False
}

/// The first announcement falls an interval after the caller arrived: the
/// greeting has only just finished.
pub fn the_first_announcement_waits_an_interval_test() {
  let waiting = caller.new(joined)
  let of = limits(0, 0, 0, 30)
  assert caller.announcement_due(waiting, of, joined) == False
  assert caller.announcement_due(waiting, of, joined + 29) == False
  assert caller.announcement_due(waiting, of, joined + 30) == True
}

pub fn announcements_repeat_from_the_last_one_test() {
  let of = limits(0, 0, 0, 30)
  let spoken = caller.new(joined) |> caller.announced(at: joined + 40)
  assert caller.announcement_due(spoken, of, joined + 69) == False
  assert caller.announcement_due(spoken, of, joined + 70) == True
}

pub fn no_interval_is_no_announcements_test() {
  let waiting = caller.new(joined)
  assert caller.announcement_due(waiting, limits(0, 0, 0, 0), joined + 10_000)
    == False
}

/// The loop sleeps until the soonest deadline, and no longer than the cap.
pub fn next_wake_is_the_soonest_deadline_test() {
  let waiting = caller.new(joined)
  assert caller.next_wake_ms(waiting, limits(0, 0, 0, 0), joined)
    == caller.longest_wait_ms
  assert caller.next_wake_ms(waiting, limits(10, 0, 0, 30), joined) == 10_000
  assert caller.next_wake_ms(waiting, limits(60, 0, 0, 15), joined) == 15_000
}

/// A deadline already past comes straight back round, so the loop acts on it
/// instead of sleeping through it -- but never with a wait of zero, which
/// `receive_event` answers without reading the mailbox, so a loop that asked
/// for it would spin past the very event that would end the spin.
pub fn a_passed_deadline_wakes_at_once_test() {
  let waiting = caller.new(joined)
  assert caller.next_wake_ms(waiting, limits(10, 0, 0, 0), joined + 50)
    == caller.shortest_wait_ms
  assert caller.shortest_wait_ms > 0
}

//
// --- A phone ringing for the caller ----------------------------------------
//

/// The queue said nobody could take the caller, then rang somebody for them.
fn nobody_then_rung(until: Int) -> caller.Caller {
  caller.new(joined)
  |> caller.positioned(
    position: Some(1),
    waiting: Some(1),
    agents_available: Some(0),
    at: joined,
  )
  |> caller.offered(until: until)
}

/// An agent's phone ringing for the caller is somebody who can take them:
/// the no-agent clock is cleared when the offer begins, and a count of
/// nobody made while the phones ring -- the agents being rung are counted as
/// busy -- does not start it again. Without this a caller was released on
/// `no_agent_timeout` with two phones ringing for them. The clock runs
/// again from the offer's ceiling at the latest, so the pause is the length
/// of the ring and no longer.
pub fn a_phone_ringing_for_the_caller_stops_the_no_agent_clock_test() {
  let of = limits(0, 30, 0, 0)
  let rung = nobody_then_rung(joined + 25)
  assert caller.expired(rung, of, joined + 30) == None
  assert caller.expired(rung, of, joined + 54) == None
  assert caller.expired(rung, of, joined + 55) == Some(caller.NoAgentTooLong)

  let still_rung =
    caller.positioned(
      rung,
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(0),
      at: joined + 10,
    )
  assert caller.expired(still_rung, of, joined + 54) == None
  assert caller.expired(still_rung, of, joined + 55)
    == Some(caller.NoAgentTooLong)
}

/// The ring came to nothing: the agents rung are on their no-answer delay
/// and the last count said nobody else was there, so the clock starts from
/// the end of the ring, not from before it began.
pub fn the_clock_restarts_when_the_ring_comes_to_nothing_test() {
  let of = limits(0, 30, 0, 0)
  let missed =
    nobody_then_rung(joined + 25) |> caller.offer_over(at: joined + 18)
  assert caller.expired(missed, of, joined + 47) == None
  assert caller.expired(missed, of, joined + 48) == Some(caller.NoAgentTooLong)
}

/// A ring that came to nothing while other agents were about starts no
/// clock, and one that ended with nothing known about the queue starts none
/// either: the next position event says.
pub fn a_missed_ring_with_agents_about_starts_no_clock_test() {
  let of = limits(0, 30, 0, 0)
  let with_others =
    caller.new(joined)
    |> caller.positioned(
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(2),
      at: joined,
    )
    |> caller.offered(until: joined + 25)
    |> caller.offer_over(at: joined + 18)
  assert caller.expired(with_others, of, joined + 100) == None

  let nothing_known =
    caller.new(joined)
    |> caller.offered(until: joined + 25)
    |> caller.offer_over(at: joined + 18)
  assert caller.expired(nothing_known, of, joined + 100) == None
  assert nothing_known.no_agents_since == None
}

/// An offer whose end was never heard -- the bridge's completion lost, the
/// listener late -- stops counting at its own ceiling, and the clock runs
/// from there on the last count, without waiting for any further event. A
/// count of nobody that does arrive afterwards keeps that start, and an end
/// heard late changes nothing either.
pub fn an_offer_whose_end_was_not_heard_runs_out_test() {
  let of = limits(0, 30, 0, 0)
  let rung = nobody_then_rung(joined + 20)
  assert caller.is_offered(rung, at: joined + 19)
  assert !caller.is_offered(rung, at: joined + 20)

  assert caller.expired(rung, of, joined + 49) == None
  assert caller.expired(rung, of, joined + 50) == Some(caller.NoAgentTooLong)
  assert caller.next_wake_ms(rung, of, now: joined + 25) == 25_000

  let nobody_again =
    caller.positioned(
      rung,
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(0),
      at: joined + 25,
    )
  assert caller.expired(nobody_again, of, joined + 49) == None
  assert caller.expired(nobody_again, of, joined + 50)
    == Some(caller.NoAgentTooLong)

  let heard_late = caller.offer_over(rung, at: joined + 40)
  assert caller.expired(heard_late, of, joined + 49) == None
  assert caller.expired(heard_late, of, joined + 50)
    == Some(caller.NoAgentTooLong)

  // With agents about at the last count, the ceiling starts nothing.
  let with_others =
    caller.new(joined)
    |> caller.positioned(
      position: Some(1),
      waiting: Some(1),
      agents_available: Some(2),
      at: joined,
    )
    |> caller.offered(until: joined + 20)
  assert caller.expired(with_others, of, joined + 100) == None
}

/// The announcement interrupts the hold, and a caller whose agents are
/// ringing is hearing the ring's own hold music: none falls due while the
/// phones ring. It is deferred, not spent, so it is made the moment the ring
/// comes to nothing, and the loop waiting for it wakes for the end of the
/// ring rather than every hundred milliseconds until then.
pub fn no_announcement_while_a_phone_rings_for_the_caller_test() {
  let of = limits(0, 0, 0, 30)
  let rung = caller.new(joined) |> caller.offered(until: joined + 45)
  assert !caller.announcement_due(rung, of, now: joined + 30)
  assert !caller.announcement_due(rung, of, now: joined + 44)
  assert caller.next_wake_ms(rung, of, now: joined + 30) == 15_000

  let missed = caller.offer_over(rung, at: joined + 40)
  assert caller.announcement_due(missed, of, now: joined + 40)

  let unheard = rung
  assert caller.announcement_due(unheard, of, now: joined + 45)
}
