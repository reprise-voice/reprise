//// The callflow action `stir_shaken`: branch on the inbound verdict.
////
//// The verdict was reached before the flow started (`stir/inbound`,
//// called from `cf_stir` on the route win), and it reaches this action
//// two ways: `cf_stir` stores the CCV map on the call itself under
//// `stir_verdict`, and sets the same variables on the channel. The store
//// is read first -- it is on the call record this action is handed, so
//// it is there whether or not the channel has caught up, which for an
//// async verdict it may not have -- and the channel variable is the
//// fallback. With neither, the branch is `none`.
////
//// The child taken is `passed`, `failed` or `none`; a flow without that
//// child takes `_`, which `callflow.continue_branch` does on its own.
//// The action's data is `{}`: what it does is decided by
//// `system_config/stir`, not per flow.
////
//// When `cid_name_prefix_failed` is set and the verdict is
//// `TN-Validation-Failed`, the prefix goes in front of the caller id
//// name, so a phone shows a call whose signature did not check out for
//// what it is. The name is changed on the call `cf_exe` carries forward
//// and on the channel, so the bridge that follows and the CDR both see
//// it. A name that already carries the prefix is left alone: a flow that
//// runs this action twice does not stack it.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/call.{type Call}
import kazoo/callflow
import kazoo/doc
import stir/inbound
import stir/settings
import stir/system

/// What the action does with a call: the child to take, and the caller
/// id name to set first, when there is one to set.
/// The key `cf_stir` stores the verdict's CCV map under on the call.
pub const verdict_key = "stir_verdict"

pub type Decision {
  Decision(branch: String, caller_id_name: Option(String))
}

pub fn handle(data: Dynamic, call: Call) -> Nil {
  let _data = callflow.data(data)
  let config = settings.load(system.live())
  run(call, config.cid_name_prefix_failed)
}

/// The action over a call and the prefix, without the configuration
/// read. Every path ends in `continue_branch`.
pub fn run(call: Call, prefix: String) -> Nil {
  let decision = decide(verdict_of(call), call.caller_id_name(call), prefix)
  let call = case decision.caller_id_name {
    None -> call
    Some(name) -> {
      system.log("inbound verdict failed; caller id name is now " <> name)
      let call = with_caller_id_name(call, name)
      callflow.set_call(call)
      call
    }
  }
  callflow.continue_branch(call, decision.branch)
}

/// The decision on its own, so it can be tested without a flow to end
/// into.
pub fn decide(
  verstat: Option(inbound.Verstat),
  caller_id_name: Option(String),
  prefix: String,
) -> Decision {
  case verstat {
    Some(inbound.Passed) -> Decision(branch: "passed", caller_id_name: None)
    Some(inbound.Failed) ->
      Decision(
        branch: "failed",
        caller_id_name: prefixed(caller_id_name, prefix),
      )
    Some(inbound.NoValidation) | None ->
      Decision(branch: "none", caller_id_name: None)
  }
}

/// The verdict `stir/inbound` reached, from the call's own key-value
/// store first and the channel variable second.
pub fn verdict_of(call: Call) -> Option(inbound.Verstat) {
  option.or(stored_verdict(call), channel_verdict(call))
}

/// The CCV map `cf_stir` stored on the call under `stir_verdict`.
fn stored_verdict(call: Call) -> Option(inbound.Verstat) {
  case call.kvs_fetch(call, verdict_key) {
    Some(stored) -> verstat(doc.get_string(stored, ["STIR-Verstat"]))
    None -> None
  }
}

fn channel_verdict(call: Call) -> Option(inbound.Verstat) {
  case call.custom_channel_var(call, "STIR-Verstat") {
    Some(doc.String(text)) -> verstat(Ok(text))
    _ -> None
  }
}

fn verstat(text: Result(String, Nil)) -> Option(inbound.Verstat) {
  case text {
    Ok(text) -> option.from_result(inbound.verstat_from_string(text))
    Error(Nil) -> None
  }
}

/// The call with its caller id name changed, on the record and, on a node
/// with a channel, on the channel. `kazoo/call` has no setter for it, so
/// this is the FFI's.
pub fn with_caller_id_name(call: Call, name: String) -> Call {
  set_caller_id_name(call, name)
}

/// The name with the prefix in front, or nothing to set: no prefix
/// configured, or the name carries it already.
fn prefixed(caller_id_name: Option(String), prefix: String) -> Option(String) {
  case prefix {
    "" -> None
    _ -> {
      let name = option.unwrap(caller_id_name, "")
      case string.starts_with(name, prefix) {
        True -> None
        False -> Some(prefix <> name)
      }
    }
  }
}

@external(erlang, "stir_inbound_ffi", "set_caller_id_name")
fn set_caller_id_name(call: Call, name: String) -> Call
