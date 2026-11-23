//// The agent availability document: what it says, and what setting it does.

import callcenter/availability
import callcenter/records
import callcenter/types.{Available, AvailableOnDemand, LoggedOut, OnBreak}
import gleam/option.{None, Some}
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake

const account_id = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

fn cluster() -> #(fake.Fake, kazoo.Kazoo) {
  let fake = fake.new()
  // The realm is what the presence update every change publishes is
  // addressed in.
  fake.put_account(fake, account_id, "support.example.com", [])
  #(fake, fake.kazoo(fake))
}

// --- The wire names --------------------------------------------------------

pub fn names_round_trip_test() {
  assert availability.to_string(LoggedOut) == "logged_out"
  assert availability.to_string(Available) == "available"
  assert availability.to_string(AvailableOnDemand) == "available_on_demand"
  assert availability.to_string(OnBreak) == "on_break"

  assert availability.from_string("logged_out") == LoggedOut
  assert availability.from_string("available") == Available
  assert availability.from_string("available_on_demand") == AvailableOnDemand
  assert availability.from_string("on_break") == OnBreak
  // A value from a newer release does not put an agent on a call.
  assert availability.from_string("dancing") == LoggedOut
}

pub fn source_names_round_trip_test() {
  assert availability.source_to_string(availability.Phone) == "phone"
  assert availability.source_to_string(availability.Ui) == "ui"
  assert availability.source_to_string(availability.Supervisor) == "supervisor"
  assert availability.source_to_string(availability.NoAnswerRule) == "no_answer"
  assert availability.source_to_string(availability.Dnd) == "dnd"
  assert availability.source_to_string(availability.System) == "system"

  assert availability.source_from_string("no_answer")
    == availability.NoAnswerRule
  assert availability.source_from_string("dnd") == availability.Dnd
  assert availability.source_from_string("nonsense") == availability.System
}

pub fn logged_in_test() {
  assert !availability.logged_in(LoggedOut)
  assert availability.logged_in(Available)
  assert availability.logged_in(AvailableOnDemand)
  // On break is still logged in: the login metric means "working today",
  // not "free right now".
  assert availability.logged_in(OnBreak)
}

// --- Reading ---------------------------------------------------------------

/// A user who was never made an agent is logged out, and nothing is written
/// to say so.
pub fn an_agent_with_no_document_is_logged_out_test() {
  let #(fake, kz) = cluster()
  let assert Ok(current) = availability.get(kz, account_id, "agent")
  assert current == availability.logged_out()
  assert fake.lookup(
      fake,
      kazoo.account_db(account_id),
      records.agent_document_id("agent"),
    )
    == Error(kazoo.NotFound)
}

pub fn decode_test() {
  let document =
    doc.object([
      #("agent_id", doc.String("agent")),
      #("availability", doc.String("on_break")),
      #("previous", doc.String("available")),
      #("timestamp", doc.Int(63_000_000_000)),
      #("source", doc.String("phone")),
    ])
  let decoded = availability.decode(document)
  assert decoded.availability == OnBreak
  assert decoded.previous == Some(Available)
  assert decoded.timestamp == 63_000_000_000
  assert decoded.source == availability.Phone
}

/// A document from before a field existed still reads: the availability is
/// what matters and the rest has a default.
pub fn decode_a_sparse_document_test() {
  let decoded =
    availability.decode(
      doc.object([#("availability", doc.String("available"))]),
    )
  assert decoded.availability == Available
  assert decoded.previous == None
  assert decoded.timestamp == 0
  assert decoded.source == availability.System
}

// --- Writing ---------------------------------------------------------------

pub fn set_writes_the_document_test() {
  let #(fake, kz) = cluster()
  let assert Ok(changed) =
    availability.set(
      kz,
      account_id,
      "agent",
      to: Available,
      source: availability.Phone,
    )
  assert changed.availability == Available
  assert changed.previous == Some(LoggedOut)
  assert changed.source == availability.Phone

  let assert Ok(document) =
    fake.lookup(
      fake,
      kazoo.account_db(account_id),
      records.agent_document_id("agent"),
    )
  assert doc.get_string(document, ["availability"]) == Ok("available")
  assert doc.get_string(document, ["agent_id"]) == Ok("agent")
  assert doc.get_string(document, ["pvt_type"]) == Ok("callcenter_agent")
  // The value to restore when do-not-disturb is cleared.
  assert doc.get_string(document, ["previous"]) == Ok("logged_out")
}

pub fn set_reads_back_test() {
  let #(_fake, kz) = cluster()
  let assert Ok(_) =
    availability.set(
      kz,
      account_id,
      "agent",
      to: OnBreak,
      source: availability.Ui,
    )
  let assert Ok(current) = availability.get(kz, account_id, "agent")
  assert current.availability == OnBreak
  assert current.source == availability.Ui
}

/// Setting it to what it already is is not a change. Requirement 0.6: two
/// nodes acting on one feature code give the same result as one.
pub fn setting_the_same_value_is_not_a_change_test() {
  let #(_fake, kz) = cluster()
  let assert Ok(first) =
    availability.set(
      kz,
      account_id,
      "agent",
      to: Available,
      source: availability.Phone,
    )
  let assert Ok(again) =
    availability.set(
      kz,
      account_id,
      "agent",
      to: Available,
      source: availability.Supervisor,
    )
  assert again == first
  // The second call did not rewrite the source either.
  assert again.source == availability.Phone
}

/// The previous value follows the changes, which is what makes the
/// do-not-disturb restore in requirement 1.7 possible.
pub fn previous_follows_the_changes_test() {
  let #(_fake, kz) = cluster()
  let assert Ok(_) =
    availability.set(
      kz,
      account_id,
      "agent",
      to: Available,
      source: availability.Phone,
    )
  let assert Ok(on_break) =
    availability.set(
      kz,
      account_id,
      "agent",
      to: OnBreak,
      source: availability.Phone,
    )
  assert on_break.previous == Some(Available)

  let assert Ok(out) =
    availability.set(
      kz,
      account_id,
      "agent",
      to: LoggedOut,
      source: availability.Dnd,
    )
  assert out.previous == Some(OnBreak)
}

/// One document per agent, by user id, so the datastore this is going to
/// move to sees a row and not a search.
pub fn the_document_id_is_the_agent_test() {
  assert records.agent_document_id("abc") == "callcenter_agent-abc"
}

/// The two questions the dispatcher asks of an availability, and the
/// decisions behind them.
pub fn taking_calls_test() {
  assert availability.taking_calls(Available)
  assert availability.taking_calls(AvailableOnDemand)
  // An agent on a break has said they are not taking callers, so a caller is
  // not offered to them -- and an offer that rang out after they stepped
  // away is not a miss of theirs either.
  assert !availability.taking_calls(OnBreak)
  assert !availability.taking_calls(LoggedOut)
}

/// The counters on the document are "since login". A login starts them
/// again; a break, a resume and a logout leave them alone, so the number a
/// supervisor reads is the misses of the shift the agent is in.
pub fn the_counters_start_again_at_a_login_test() {
  assert availability.starts_a_new_login(LoggedOut, Available)
  assert availability.starts_a_new_login(LoggedOut, AvailableOnDemand)

  assert !availability.starts_a_new_login(OnBreak, Available)
  assert !availability.starts_a_new_login(Available, OnBreak)
  assert !availability.starts_a_new_login(Available, AvailableOnDemand)
  assert !availability.starts_a_new_login(Available, LoggedOut)
}
