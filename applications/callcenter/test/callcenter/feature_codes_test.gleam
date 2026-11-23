//// The feature codes, decided on their own: every action against every
//// availability, and what the agent hears afterwards.

import gleam/list
import gleam/option.{None, Some}

import callcenter/feature_codes.{
  Break, Change, Login, Logout, Resume, ToggleBreak, ToggleLogin, Unchanged,
}
import callcenter/types.{Available, AvailableOnDemand, LoggedOut, OnBreak}

pub fn action_spellings_test() {
  let all = [Login, Logout, ToggleLogin, Break, Resume, ToggleBreak]
  list.each(all, fn(action) {
    assert feature_codes.action_from_string(feature_codes.action_to_string(
        action,
      ))
      == Ok(action)
  })
  assert feature_codes.action_to_string(ToggleLogin) == "toggle_login"
  assert feature_codes.action_from_string("pause") == Error(Nil)
}

pub fn login_test() {
  assert feature_codes.apply(Login, current: LoggedOut, previous: None)
    == Change(Available, "agent-logged_in")

  // Logging in twice is not a way to end a break or to lose an on-demand
  // choice; the agent is told what they already are.
  assert feature_codes.apply(Login, current: Available, previous: None)
    == Unchanged("agent-logged_in")
  assert feature_codes.apply(Login, current: AvailableOnDemand, previous: None)
    == Unchanged("agent-logged_in")
  assert feature_codes.apply(Login, current: OnBreak, previous: None)
    == Unchanged("agent-on_break")
}

pub fn logout_test() {
  assert feature_codes.apply(Logout, current: Available, previous: None)
    == Change(LoggedOut, "agent-logged_out")
  assert feature_codes.apply(Logout, current: OnBreak, previous: None)
    == Change(LoggedOut, "agent-logged_out")
  assert feature_codes.apply(Logout, current: LoggedOut, previous: None)
    == Unchanged("agent-logged_out")
}

/// `*22`: one code, and whichever way the agent is now it goes the other.
pub fn toggle_login_test() {
  assert feature_codes.apply(ToggleLogin, current: LoggedOut, previous: None)
    == Change(Available, "agent-logged_in")
  assert feature_codes.apply(ToggleLogin, current: Available, previous: None)
    == Change(LoggedOut, "agent-logged_out")
  assert feature_codes.apply(
      ToggleLogin,
      current: AvailableOnDemand,
      previous: None,
    )
    == Change(LoggedOut, "agent-logged_out")

  // On break is still logged in, so the login toggle logs them out.
  assert feature_codes.apply(ToggleLogin, current: OnBreak, previous: None)
    == Change(LoggedOut, "agent-logged_out")
}

pub fn break_test() {
  assert feature_codes.apply(Break, current: Available, previous: None)
    == Change(OnBreak, "agent-on_break")
  assert feature_codes.apply(Break, current: AvailableOnDemand, previous: None)
    == Change(OnBreak, "agent-on_break")
  assert feature_codes.apply(Break, current: OnBreak, previous: None)
    == Unchanged("agent-on_break")

  // A break is a pause in a login, so there is nothing to pause.
  assert feature_codes.apply(Break, current: LoggedOut, previous: None)
    == Unchanged("agent-logged_out")
}

/// A resume goes back to what the agent was before the break, so an agent
/// who was on demand is on demand again and not plain available.
pub fn resume_test() {
  assert feature_codes.apply(
      Resume,
      current: OnBreak,
      previous: Some(AvailableOnDemand),
    )
    == Change(AvailableOnDemand, "agent-logged_in")
  assert feature_codes.apply(
      Resume,
      current: OnBreak,
      previous: Some(Available),
    )
    == Change(Available, "agent-logged_in")

  // Nothing remembered, and a break that followed a logout, both come back
  // to plain available rather than back to nothing.
  assert feature_codes.apply(Resume, current: OnBreak, previous: None)
    == Change(Available, "agent-logged_in")
  assert feature_codes.apply(
      Resume,
      current: OnBreak,
      previous: Some(LoggedOut),
    )
    == Change(Available, "agent-logged_in")

  assert feature_codes.apply(Resume, current: Available, previous: None)
    == Unchanged("agent-logged_in")
  assert feature_codes.apply(Resume, current: LoggedOut, previous: None)
    == Unchanged("agent-logged_out")
}

/// `*24`: the same code takes the break and ends it.
pub fn toggle_break_test() {
  assert feature_codes.apply(ToggleBreak, current: Available, previous: None)
    == Change(OnBreak, "agent-on_break")
  assert feature_codes.apply(
      ToggleBreak,
      current: OnBreak,
      previous: Some(AvailableOnDemand),
    )
    == Change(AvailableOnDemand, "agent-logged_in")
  assert feature_codes.apply(ToggleBreak, current: LoggedOut, previous: None)
    == Unchanged("agent-logged_out")
}

/// Whatever happens, there is exactly one thing to say and at most one thing
/// to write.
pub fn every_outcome_speaks_test() {
  let actions = [Login, Logout, ToggleLogin, Break, Resume, ToggleBreak]
  let availabilities = [LoggedOut, Available, AvailableOnDemand, OnBreak]
  list.each(actions, fn(action) {
    list.each(availabilities, fn(availability) {
      let outcome =
        feature_codes.apply(action, current: availability, previous: None)
      assert feature_codes.prompt(outcome) != ""
      case feature_codes.changed_to(outcome) {
        Some(to) -> {
          assert to != availability
          Nil
        }
        None -> Nil
      }
    })
  })
}
