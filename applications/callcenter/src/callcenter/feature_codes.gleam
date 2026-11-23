//// What an agent's feature code does, without a phone to do it on.
////
//// Three codes, as the call center this replaces had them: `*22` toggles the
//// login of the calling device's user -- or, as `*22<extension>`, of the
//// agent with that presence id -- `*23` logs in by agent id and PIN from any
//// phone, and `*24` toggles a break. They are callflow actions, so the
//// number each sits on is whatever callflow an administrator gives it, and
//// the `action` in the action's data is what actually distinguishes them.
////
//// Everything here is a decision about an availability, taken from the one
//// the agent is in now and the one they were in before it. What speaks it,
//// what writes it and what publishes it is `cf_callcenter_agent`; this is
//// the part that can be read and checked on its own.

import gleam/option.{type Option, None, Some}

import callcenter/types.{
  type Availability, Available, AvailableOnDemand, LoggedOut, OnBreak,
}

/// The `action` values `callflows.callcenter_agent.json` allows.
pub type Action {
  Login
  Logout
  ToggleLogin
  Break
  Resume
  ToggleBreak
}

pub fn action_to_string(action: Action) -> String {
  case action {
    Login -> "login"
    Logout -> "logout"
    ToggleLogin -> "toggle_login"
    Break -> "break"
    Resume -> "resume"
    ToggleBreak -> "toggle_break"
  }
}

pub fn action_from_string(name: String) -> Result(Action, Nil) {
  case name {
    "login" -> Ok(Login)
    "logout" -> Ok(Logout)
    "toggle_login" -> Ok(ToggleLogin)
    "break" -> Ok(Break)
    "resume" -> Ok(Resume)
    "toggle_break" -> Ok(ToggleBreak)
    _ -> Error(Nil)
  }
}

//
// The prompts. Three of these already ship with the system; `agent-on_break`
// does not and has to be recorded before a break says anything out loud.
//

pub const logged_in_prompt = "agent-logged_in"

pub const logged_out_prompt = "agent-logged_out"

pub const on_break_prompt = "agent-on_break"

pub const invalid_prompt = "agent-invalid_choice"

pub const enter_id_prompt = "hotdesk-enter_id"

pub const enter_pin_prompt = "hotdesk-enter_pin"

/// What a code does: either a new availability to write and something to say
/// about it, or nothing to write and something to say about that.
pub type Outcome {
  Change(to: Availability, prompt: String)
  Unchanged(prompt: String)
}

pub fn prompt(outcome: Outcome) -> String {
  case outcome {
    Change(_, prompt) -> prompt
    Unchanged(prompt) -> prompt
  }
}

/// The availability an outcome writes, if any.
pub fn changed_to(outcome: Outcome) -> Option(Availability) {
  case outcome {
    Change(to, _) -> Some(to)
    Unchanged(_) -> None
  }
}

/// What `action` does to an agent who is `current` now and was `previous`
/// before that.
///
/// `previous` is what a resume goes back to, which is how an agent who was
/// available on demand before a break is still available on demand after it.
pub fn apply(
  action: Action,
  current current: Availability,
  previous previous: Option(Availability),
) -> Outcome {
  case action {
    Login -> login(current)
    Logout -> logout(current)
    ToggleLogin ->
      case current {
        LoggedOut -> login(current)
        _ -> logout(current)
      }
    Break -> take_a_break(current)
    Resume -> resume(current, previous)
    ToggleBreak ->
      case current {
        OnBreak -> resume(current, previous)
        _ -> take_a_break(current)
      }
  }
}

fn login(current: Availability) -> Outcome {
  case current {
    // Already working: say so rather than resetting a break or an on-demand
    // choice the agent made deliberately.
    Available -> Unchanged(logged_in_prompt)
    AvailableOnDemand -> Unchanged(logged_in_prompt)
    OnBreak -> Unchanged(on_break_prompt)
    LoggedOut -> Change(Available, logged_in_prompt)
  }
}

fn logout(current: Availability) -> Outcome {
  case current {
    LoggedOut -> Unchanged(logged_out_prompt)
    _ -> Change(LoggedOut, logged_out_prompt)
  }
}

fn take_a_break(current: Availability) -> Outcome {
  case current {
    // A break is a pause in a login. An agent who has not logged in has
    // nothing to pause, and is told what they actually are.
    LoggedOut -> Unchanged(logged_out_prompt)
    OnBreak -> Unchanged(on_break_prompt)
    _ -> Change(OnBreak, on_break_prompt)
  }
}

fn resume(current: Availability, previous: Option(Availability)) -> Outcome {
  case current {
    OnBreak -> Change(resumes_to(previous), logged_in_prompt)
    LoggedOut -> Unchanged(logged_out_prompt)
    _ -> Unchanged(logged_in_prompt)
  }
}

/// Where a resume returns to: what the agent was before the break, when that
/// was a state they could take calls in, and plain available otherwise --
/// the agent asked to be back. A break that runs out by itself does not go
/// here: nobody asked, so it goes back to exactly what came before
/// (`breaks.ends_to`) and never logs anybody in.
pub fn resumes_to(previous: Option(Availability)) -> Availability {
  case previous {
    Some(AvailableOnDemand) -> AvailableOnDemand
    Some(Available) -> Available
    _ -> Available
  }
}
