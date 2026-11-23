//// A break with an end: when it is due, what it goes back to, that every
//// other change takes the end away, and the three ways it ends -- the
//// timer of the node that started it, the sweep, and a compare-and-set that
//// makes the second of two ends nothing.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import kazoo/testing/fake

import callcenter/availability.{type AgentAvailability}
import callcenter/breaks.{NotThisBreak, Over, Running}
import callcenter/feature_codes
import callcenter/records
import callcenter/types.{Available, AvailableOnDemand, LoggedOut, OnBreak}

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const jane = "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91"

const ends = 63_929_305_000

fn on_break(
  previous: option.Option(types.Availability),
  break_ends: option.Option(Int),
) -> AgentAvailability {
  availability.AgentAvailability(
    availability: OnBreak,
    previous: previous,
    timestamp: ends - 600,
    source: availability.Phone,
    break_ends: break_ends,
    held_break: None,
  )
}

// --- The decisions -------------------------------------------------------------

/// Due at its end and not a second before.
pub fn a_break_is_over_at_its_end_test() {
  let state = on_break(Some(Available), Some(ends))
  assert breaks.verdict(state, ends, ends - 1) == Running
  assert breaks.verdict(state, ends, ends) == Over(Available)
  assert breaks.verdict(state, ends, ends + 3600) == Over(Available)
}

/// Back to exactly what the agent was before it: available and on demand
/// as they were, and anything else logged out. Nobody asked to work, so a
/// break that runs out logs nobody in -- which a resume, asked for, does.
pub fn a_break_goes_back_to_what_came_before_test() {
  let over = fn(previous) {
    breaks.verdict(on_break(previous, Some(ends)), ends, ends)
  }
  assert over(Some(Available)) == Over(Available)
  assert over(Some(AvailableOnDemand)) == Over(AvailableOnDemand)
  assert over(Some(LoggedOut)) == Over(LoggedOut)
  assert over(Some(OnBreak)) == Over(LoggedOut)
  assert over(None) == Over(LoggedOut)
  assert feature_codes.resumes_to(Some(LoggedOut)) == Available
}

/// Only the break the end was set for: not a later break with another end,
/// not one with no end, and not an agent who is no longer on a break.
pub fn only_the_same_break_ends_test() {
  assert breaks.verdict(on_break(Some(Available), Some(ends + 60)), ends, ends)
    == NotThisBreak
  assert breaks.verdict(on_break(Some(Available), None), ends, ends)
    == NotThisBreak
  let back =
    availability.AgentAvailability(
      ..on_break(Some(Available), None),
      availability: Available,
    )
  assert breaks.verdict(back, ends, ends + 60) == NotThisBreak
}

/// The sweep leaves a break to the node that started it for
/// `sweep_grace_s`, and takes it after that; nothing else is its business.
pub fn the_sweep_waits_out_the_grace_test() {
  let states = [
    #("due", on_break(Some(Available), Some(ends))),
    #("later", on_break(Some(Available), Some(ends + 600))),
    #("endless", on_break(Some(Available), None)),
    #(
      "working",
      availability.AgentAvailability(
        ..on_break(Some(OnBreak), None),
        availability: Available,
      ),
    ),
  ]
  assert breaks.overdue(states, ends) == []
  assert breaks.overdue(states, ends + breaks.sweep_grace_s - 1) == []
  assert breaks.overdue(states, ends + breaks.sweep_grace_s) == [#("due", ends)]
}

// --- The document ---------------------------------------------------------------

fn an_account() -> #(fake.Fake, Kazoo) {
  let f =
    fake.new_with_views([
      fake.Valued(
        name: "callcenter/agents",
        doc_type: "callcenter_agent",
        key: fn(d) { doc.get_string(d, ["agent_id"]) |> result.map(doc.String) },
        value: fn(d) { d },
      ),
    ])
  fake.put_account(f, account, "support.example.com", [])
  fake.put_doc(f, kazoo.account_db(account), jane_the_user(True))
  #(f, fake.kazoo(f))
}

fn jane_the_user(enabled: Bool) -> doc.Value {
  doc.object([
    #("_id", doc.String(jane)),
    #("pvt_type", doc.String("user")),
    #("enabled", doc.Bool(enabled)),
    #("call_center", doc.object([#("pin", doc.String("4321"))])),
  ])
}

fn stored(f: fake.Fake) -> doc.Value {
  let assert Ok(document) =
    fake.lookup(f, kazoo.account_db(account), records.agent_document_id(jane))
  document
}

fn take_a_break(kz: Kazoo, seconds: Int) -> Int {
  let assert Ok(_) =
    availability.set(kz, account, jane, to: Available, source: availability.Ui)
  let assert Ok(state) =
    breaks.set(
      kz,
      account,
      jane,
      to: OnBreak,
      source: availability.Phone,
      timeout_s: seconds,
    )
  let assert Some(ends) = state.break_ends
  ends
}

/// The end is stored on the document, that many seconds after the break
/// began; a break with no timeout has none.
pub fn the_end_is_stored_test() {
  let #(f, kz) = an_account()
  let ends = take_a_break(kz, 900)
  let assert Ok(state) = availability.get(kz, account, jane)
  assert state.break_ends == Some(ends)
  assert ends == state.timestamp + 900
  assert doc.get_int(stored(f), ["break_ends"]) == Ok(ends)

  let assert Ok(_) =
    availability.set(kz, account, jane, to: Available, source: availability.Ui)
  let assert Ok(state) =
    breaks.set(
      kz,
      account,
      jane,
      to: OnBreak,
      source: availability.Phone,
      timeout_s: 0,
    )
  assert state.break_ends == None
  assert doc.get(stored(f), ["break_ends"]) == Error(Nil)
}

/// Any other change takes the end away: a resume, a supervisor, a logout,
/// do-not-disturb. So does a timeout on something that is not a break.
pub fn every_other_change_clears_the_end_test() {
  let #(f, kz) = an_account()
  let check = fn(change: #(types.Availability, availability.Source)) {
    let _ends = take_a_break(kz, 900)
    let assert Ok(state) =
      availability.set(kz, account, jane, to: change.0, source: change.1)
    assert state.break_ends == None
    assert doc.get(stored(f), ["break_ends"]) == Error(Nil)
  }
  check(#(Available, availability.Phone))
  check(#(AvailableOnDemand, availability.Supervisor))
  check(#(LoggedOut, availability.Ui))
  check(#(LoggedOut, availability.Dnd))
  check(#(LoggedOut, availability.System))

  let assert Ok(state) =
    breaks.set(
      kz,
      account,
      jane,
      to: Available,
      source: availability.Ui,
      timeout_s: 900,
    )
  assert state.break_ends == None
}

/// Already on a break: setting a break again keeps the one they are on, end
/// and all.
pub fn a_second_break_keeps_the_first_test() {
  let #(_f, kz) = an_account()
  let ends = take_a_break(kz, 900)
  let assert Ok(state) =
    breaks.set(
      kz,
      account,
      jane,
      to: OnBreak,
      source: availability.Ui,
      timeout_s: 60,
    )
  assert state.break_ends == Some(ends)
  assert state.source == availability.Phone
}

// --- Ending it -----------------------------------------------------------------

/// The end, at the second it is due: back to what they were, by the system,
/// and the end gone from the document. A second end is nothing.
pub fn a_break_ends_once_test() {
  let #(f, kz) = an_account()
  let ends = take_a_break(kz, 900)

  assert breaks.end(kz, account, jane, due: ends, now: ends - 1) == Ok(None)
  assert availability.get(kz, account, jane)
    |> result.map(fn(state) { state.availability })
    == Ok(OnBreak)

  let assert Ok(Some(state)) =
    breaks.end(kz, account, jane, due: ends, now: ends)
  assert state.availability == Available
  assert state.previous == Some(OnBreak)
  assert state.source == availability.System
  assert state.break_ends == None
  assert doc.get_string(stored(f), ["source"]) == Ok("system")
  assert doc.get(stored(f), ["break_ends"]) == Error(Nil)

  assert breaks.end(kz, account, jane, due: ends, now: ends + 5) == Ok(None)
}

/// A break resumed and taken again is a different break: the first one's
/// timer ends nothing.
pub fn an_old_timer_ends_nothing_test() {
  let #(_f, kz) = an_account()
  let first = take_a_break(kz, 900)
  let second = take_a_break(kz, 1800)
  assert first != second

  assert breaks.end(kz, account, jane, due: first, now: first) == Ok(None)
  let assert Ok(state) = availability.get(kz, account, jane)
  assert state.availability == OnBreak
  assert state.break_ends == Some(second)
}

/// The write is over the revision the decision was read from: a change
/// that lands in between is a conflict, and nothing is written over it.
pub fn a_change_in_between_is_a_conflict_test() {
  let #(_f, kz) = an_account()
  let _ends = take_a_break(kz, 900)

  let answer =
    availability.set_if(
      kz,
      account,
      jane,
      source: availability.System,
      decide: fn(_read) {
        // A supervisor logs Jane out between the read and the write.
        let assert Ok(_) =
          availability.set(
            kz,
            account,
            jane,
            to: LoggedOut,
            source: availability.Supervisor,
          )
        Ok(Available)
      },
    )
  assert answer == Error(kazoo.Conflict)
  let assert Ok(state) = availability.get(kz, account, jane)
  assert state.availability == LoggedOut
  assert state.source == availability.Supervisor
}

/// The sweep ends the breaks the node that started them did not, once the
/// grace is past, and each once.
pub fn the_sweep_ends_an_overdue_break_test() {
  let #(_f, kz) = an_account()
  let ends = take_a_break(kz, 900)

  assert breaks.sweep_at(kz, account, ends) == []
  assert breaks.sweep_at(kz, account, ends + breaks.sweep_grace_s)
    == [#(jane, Available)]
  assert breaks.sweep_at(kz, account, ends + breaks.sweep_grace_s) == []
  let assert Ok(state) = availability.get(kz, account, jane)
  assert state.availability == Available
  assert state.source == availability.System
}

/// A break that is over puts the agent back to work, and a user who has been
/// disabled meanwhile may not be: the break is left for the do-not-disturb
/// listener and its sweep, which log them out.
pub fn a_disabled_users_break_does_not_end_test() {
  let #(f, kz) = an_account()
  let ends = take_a_break(kz, 900)
  fake.put_doc(f, kazoo.account_db(account), jane_the_user(False))

  assert breaks.end(kz, account, jane, due: ends, now: ends) == Ok(None)
  assert breaks.sweep_at(kz, account, ends + breaks.sweep_grace_s) == []
  let assert Ok(state) = availability.get(kz, account, jane)
  assert state.availability == OnBreak
}

/// The node that started the break ends it on its own timer.
pub fn the_timer_ends_the_break_test() {
  let #(_f, kz) = an_account()
  let _ends = take_a_break(kz, 1)
  process.sleep(2200)
  let assert Ok(state) = availability.get(kz, account, jane)
  assert state.availability == Available
  assert state.source == availability.System
  assert state.break_ends == None
}

/// A timed break that began logged out -- written before the routes refused
/// it, or restored under the refusal's nose -- ends logged out, by the
/// timer's end and the sweep alike, and the dispatcher never sees an agent
/// who did not log in. A disabled user is let out too: a logout is always
/// allowed.
pub fn a_break_from_logged_out_ends_logged_out_test() {
  let #(f, kz) = an_account()
  let assert Ok(state) =
    availability.set_timed(
      kz,
      account,
      jane,
      to: OnBreak,
      source: availability.Supervisor,
      break_s: 600,
    )
  assert state.previous == Some(LoggedOut)
  let assert Some(ends) = state.break_ends

  let assert Ok(Some(state)) =
    breaks.end(kz, account, jane, due: ends, now: ends)
  assert state.availability == LoggedOut
  assert state.break_ends == None
  assert state.source == availability.System

  let assert Ok(state) =
    availability.set_timed(
      kz,
      account,
      jane,
      to: OnBreak,
      source: availability.Supervisor,
      break_s: 600,
    )
  let assert Some(ends) = state.break_ends
  fake.put_doc(f, kazoo.account_db(account), jane_the_user(False))
  assert breaks.sweep_at(kz, account, ends + breaks.sweep_grace_s)
    == [#(jane, LoggedOut)]
  let assert Ok(state) = availability.get(kz, account, jane)
  assert state.availability == LoggedOut
  assert doc.get(stored(f), ["break_ends"]) == Error(Nil)
}
