//// The callflow action `callcenter_agent`: an agent changing their
//// availability from a phone.
////
//// One action carries all three feature codes, because they differ only in
//// the data their callflow's node carries. Put `toggle_login` on `*22`,
//// `toggle_break` on `*24`, and `toggle_login` with `require_pin` on `*23`
//// -- the third is the same decision taken from somebody else's phone, so it
//// asks who is calling before it takes it.
////
//// Who the agent is comes from the call when it can: a call from the agent's
//// own device carries their user id, and nothing is asked. When it does not
//// -- a phone that belongs to somebody else, or to nobody -- the action
//// collects an agent id and a PIN and looks the agent up by them.
////
//// `require_pin` on the node asks for them whatever the call carries, and is
//// what `*23` is for. A shared desk phone has an owner like any other, so
//// without the flag `*23` dialled there logs that owner in whoever is
//// standing at it; with it, the agent who types the id and the PIN is the
//// agent logged in and the phone's owner has nothing to do with it. That is
//// the hot-desking login of requirement 2.11. It defaults to false, so `*22`
//// and `*24` go on taking the call's own user and asking nothing.
////
//// `toggle_login` sits on the pattern `^\*22([0-9]*)$`, so `*22` followed by
//// an extension toggles the agent whose presence id that is -- what an
//// `agent_login` key dials when pressed. Only the caller's own extension,
//// unless the caller is an account administrator. An empty capture is plain
//// `*22`. The other actions ignore a capture.
////
//// A node's `presence_id` is stored as where the agent's login lamp is
//// published (`callcenter/presence`), for this change and every later one.
////
//// A node's `timeout` is how long a break it starts lasts, in seconds, and
//// 0 or none is a break with no end. The break ends by itself then and the
//// agent is back where a resume would put them (`callcenter/breaks`).
////
//// A login, a break or a resume is refused, and nothing written, for a user
//// who is disabled, deleted or not there (`agent_state.may_become`): the
//// dispatcher would never offer them a caller and the sweep would log them
//// out again. A logout always goes ahead.
////
//// Every path ends in `callflow.stop`, after the prompt that says what
//// happened has been played to the end. The codes are the last thing on
//// their callflow; there is nothing after them to continue into, and the
//// ending hangs the channel up -- so a prompt that is merely queued behind
//// it is a prompt nobody hears.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/call.{type Call}
import kazoo/callflow
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/util

import callcenter/agent_state
import callcenter/agents
import callcenter/feature_codes.{
  type Action, type Outcome, Change, ToggleLogin, Unchanged,
}
import callcenter/system

/// How long the agent has to type their id or their PIN, and how many goes
/// they get at each.
const collect_timeout_ms = 10_000

const collect_tries = 3

const max_digits = 15

pub fn handle(data: Dynamic, call: Call) -> Nil {
  let data = callflow.data(data)
  case callflow.data_bool(data, "skip_module", False) {
    True -> callflow.continue(call)
    False -> run(system.live(), data, call)
  }
}

/// `handle` with the Kazoo record supplied rather than taken from the node,
/// which is how the tests run the whole action.
pub fn run(kz: Kazoo, data: Value, call: Call) -> Nil {
  // Answering does not have to be waited for: the switch runs a channel's
  // commands in the order they were queued, so the prompt below plays after
  // the answer without a round trip here to see it happen.
  call.answer(call)
  case action(data), call.account_id(call) {
    Error(Nil), _ -> refuse(call, "no such action")
    _, None -> refuse(call, "no account on the call")
    Ok(action), Some(account_id) ->
      case identify(kz, data, action, account_id, call) {
        Error(Gone) -> give_up(call, "the caller hung up")
        Error(Tell(reason)) -> refuse(call, reason)
        Ok(agent_id) -> change(kz, data, account_id, agent_id, action, call)
      }
  }
}

/// The extension a `*22<extension>` dial names, for `toggle_login` alone:
/// the other actions take no capture and ignore one.
pub fn extension(action: Action, call: Call) -> Option(String) {
  case action {
    ToggleLogin -> call.capture_group(call)
    _ -> None
  }
}

/// Store the node's `presence_id` as where the agent's login lamp is
/// published, before the change that publishes it. A node without one
/// leaves whatever an earlier node stored. A failed write is logged and the
/// change goes ahead: the lamp is not the login.
fn point_the_lamp(
  kz: Kazoo,
  data: Value,
  account_id: String,
  agent_id: String,
) -> Nil {
  case callflow.data_string(data, "presence_id") {
    None | Some("") -> Nil
    Some(presence_id) ->
      case agent_state.set_presence_id(kz, account_id, agent_id, presence_id) {
        Ok(_moved) -> Nil
        Error(reason) ->
          system.log_error(
            "could not store presence id "
            <> presence_id
            <> " for agent "
            <> agent_id
            <> ": "
            <> kazoo.error_to_string(reason),
          )
      }
  }
}

/// Why the action is not going to change anything, and whether there is
/// still somebody to say so to.
type Refusal {
  /// A reason the caller should hear.
  Tell(reason: String)
  /// The caller has gone. Nothing may be sent to the channel after this:
  /// this process has already been handed the one `CHANNEL_DESTROY` the
  /// flow relays, so a prompt would be waited for until the wait timed out
  /// and `cf_exe`, this process and their bindings would stay up for it.
  Gone
}

/// The action the callflow node names. `callflows.callcenter_agent.json`
/// requires it, so a node without one is a callflow that was written by hand
/// and past the validator.
pub fn action(data: Value) -> Result(Action, Nil) {
  case callflow.data_string(data, "action") {
    Some(name) -> feature_codes.action_from_string(name)
    None -> Error(Nil)
  }
}

/// How long a break this node starts lasts, in seconds: the node's
/// `timeout`, and 0 -- no end -- when it has none or one below 1. Only a
/// change to a break reads it (`callcenter/breaks`).
pub fn break_timeout(data: Value) -> Int {
  int.max(callflow.data_int(data, "timeout", 0), 0)
}

/// Whether the node asks for an id and a PIN however the call arrived.
/// `*23`'s callflow sets it; `*22` and `*24` leave it out.
pub fn require_pin(data: Value) -> Bool {
  callflow.data_bool(data, "require_pin", False)
}

/// Which agent the code is for.
///
/// `*22<extension>` names one: see `on_behalf`. Otherwise it is the agent
/// calling -- the call's owner when it has one and the node is content to
/// take it, which is the whole of `*22` and `*24`. Otherwise the id and the
/// PIN: a call from a phone with no owner has nothing else to go on, and a
/// node with `require_pin` asks even when it has, because the point of that
/// flag is that the phone does not decide who logs in.
fn identify(
  kz: Kazoo,
  data: Value,
  action: Action,
  account_id: String,
  call: Call,
) -> Result(String, Refusal) {
  case extension(action, call), require_pin(data), call.owner_id(call) {
    Some(digits), _, _ -> on_behalf(kz, data, account_id, digits, call)
    None, False, Some(owner_id) -> Ok(owner_id)
    None, _asked, _ -> ask_who(kz, account_id, call)
  }
}

/// `*22<extension>`: the agent whose presence id is the extension, which
/// is what an `agent_login` key dials when it is pressed.
///
/// The caller's own extension is always theirs to toggle. Anybody else's
/// needs the caller -- the call's owner -- to be an account administrator.
/// An extension no agent has, a caller who may not, and a phone with no
/// owner are all refused the same way, and nothing changes. So is a node
/// with `require_pin`: an id and a PIN say who is calling, not whom for, and
/// the two are not mixed.
fn on_behalf(
  kz: Kazoo,
  data: Value,
  account_id: String,
  digits: String,
  call: Call,
) -> Result(String, Refusal) {
  use owner_id <- result.try(case require_pin(data), call.owner_id(call) {
    True, _ -> Error(Tell("require_pin takes no extension"))
    False, None -> Error(Tell("no owner to toggle extension " <> digits))
    False, Some(owner_id) -> Ok(owner_id)
  })
  use target <- result.try(
    agents.by_presence_id(kz, account_id, digits)
    |> result.replace_error(Tell("no agent at extension " <> digits)),
  )
  let allowed =
    target == owner_id
    || case agents.fetch(kz, account_id, owner_id) {
      Ok(owner) -> agents.is_admin(owner)
      Error(_) -> False
    }
  case allowed {
    True -> Ok(target)
    False -> Error(Tell(owner_id <> " may not toggle extension " <> digits))
  }
}

fn ask_who(
  kz: Kazoo,
  account_id: String,
  call: Call,
) -> Result(String, Refusal) {
  use typed <- result.try(collect(call, feature_codes.enter_id_prompt))
  use user <- result.try(
    agents.by_id(kz, account_id, typed)
    |> result.replace_error(Tell("no agent with that id")),
  )
  use pin <- result.try(
    agents.pin(user) |> option.to_result(Tell("agent has no pin")),
  )
  use typed_pin <- result.try(collect(call, feature_codes.enter_pin_prompt))
  case util.secure_compare(typed_pin, pin) {
    False -> Error(Tell("wrong pin"))
    True ->
      doc.get_string(user, ["_id"])
      |> result.replace_error(Tell("agent has no id"))
  }
}

fn collect(call: Call, prompt: String) -> Result(String, Refusal) {
  case
    call.prompt_and_collect_digits(
      call,
      prompt: prompt,
      max_digits: max_digits,
      tries: collect_tries,
      timeout_ms: collect_timeout_ms,
      invalid: Some(feature_codes.invalid_prompt),
    )
  {
    Ok("") -> Error(Tell("nothing was typed"))
    Ok(digits) -> Ok(digits)
    Error(call.Hungup) -> Error(Gone)
    Error(call.DtmfTimeout) -> Error(Tell("nothing was typed"))
  }
}

/// Decide, and then do it: point the lamp and make the change.
///
/// A change that would put the agent to work -- a login, a break, a resume
/// -- is for a user who is there, not deleted and enabled
/// (`agent_state.may_become`), whoever dials it: the agent, an
/// administrator's `*22<extension>`, a `*23` typist. Anybody else is refused
/// like any other refusal and nothing is written, the lamp included. A
/// logout is never refused.
fn change(
  kz: Kazoo,
  data: Value,
  account_id: String,
  agent_id: String,
  action: Action,
  call: Call,
) -> Nil {
  case agent_state.get(kz, account_id, agent_id) {
    Error(reason) -> refuse(call, kazoo.error_to_string(reason))
    Ok(state) -> {
      let outcome =
        feature_codes.apply(
          action,
          current: state.availability,
          previous: state.previous,
        )
      let allowed = case outcome {
        Change(to, _) -> agent_state.may_become(kz, account_id, agent_id, to)
        Unchanged(_) -> Ok(Nil)
      }
      case allowed {
        Error(unfit) ->
          refuse(
            call,
            "agent " <> agent_id <> ": " <> agents.unfit_to_string(unfit),
          )
        Ok(Nil) -> {
          point_the_lamp(kz, data, account_id, agent_id)
          speak(kz, account_id, agent_id, outcome, break_timeout(data), call)
        }
      }
    }
  }
}

fn speak(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  outcome: Outcome,
  break_s: Int,
  call: Call,
) -> Nil {
  case outcome {
    Unchanged(prompt) -> say_and_stop(call, prompt)
    Change(to, prompt) ->
      case
        agent_state.change(
          kz,
          account_id,
          agent_id,
          to: to,
          source: agent_state.phone,
          break_s: break_s,
        )
      {
        Error(refused) -> refuse(call, agent_state.refused_to_string(refused))
        Ok(_) -> {
          system.log(
            "agent "
            <> agent_id
            <> " of "
            <> account_id
            <> " is now "
            <> agent_state.availability_to_string(to)
            <> " by phone",
          )
          say_and_stop(call, prompt)
        }
      }
  }
}

fn refuse(call: Call, reason: String) -> Nil {
  system.log("agent feature code refused: " <> reason)
  say_and_stop(call, feature_codes.invalid_prompt)
}

/// End the flow without speaking, because there is nobody left to speak to.
fn give_up(call: Call, reason: String) -> Nil {
  system.log("agent feature code stopped: " <> reason)
  callflow.stop(call)
}

/// Say it, wait for the caller to have heard it, and end the callflow.
///
/// The wait is the whole of it. `callflow.stop` hangs the channel up, and a
/// prompt is queued on the channel rather than played by this process, so a
/// prompt that is not waited for is torn down a few milliseconds after it
/// starts and the caller hears nothing at all. Every path through this
/// action ends here.
fn say_and_stop(call: Call, prompt: String) -> Nil {
  case call.prompt_and_wait(call, prompt) {
    // Heard, or the caller had already gone: either way there is nothing
    // left to say and the flow ends.
    Ok(Nil) -> Nil
    Error(call.PlayHungup) -> Nil
    // The switch reported an execution error, or nothing came back at all.
    // Worth a line: the change itself already stands, so an agent who heard
    // nothing is still logged in and the log is where that is visible.
    Error(call.PlayFailed) ->
      system.log("agent feature code could not play " <> prompt)
  }
  callflow.stop(call)
}
