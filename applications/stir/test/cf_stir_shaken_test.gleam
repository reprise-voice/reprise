//// `cf_stir_shaken`: the decision the action takes, over the verdict
//// and the prefix, and the two reads it makes of a call, over the fake
//// call record.

import cf_stir_shaken.{Decision}
import gleam/option.{None, Some}
import kazoo/call
import kazoo/doc
import stir/inbound

const prefix = "[SPAM?] "

pub fn a_passed_verdict_takes_passed_test() {
  assert cf_stir_shaken.decide(Some(inbound.Passed), Some("Bob"), prefix)
    == Decision(branch: "passed", caller_id_name: None)
}

pub fn a_failed_verdict_takes_failed_and_prefixes_the_name_test() {
  assert cf_stir_shaken.decide(Some(inbound.Failed), Some("Bob"), prefix)
    == Decision(branch: "failed", caller_id_name: Some("[SPAM?] Bob"))
  // No name on the call: the prefix stands alone.
  assert cf_stir_shaken.decide(Some(inbound.Failed), None, prefix)
    == Decision(branch: "failed", caller_id_name: Some("[SPAM?] "))
}

pub fn no_prefix_configured_leaves_the_name_alone_test() {
  assert cf_stir_shaken.decide(Some(inbound.Failed), Some("Bob"), "")
    == Decision(branch: "failed", caller_id_name: None)
}

pub fn a_name_already_prefixed_is_not_prefixed_again_test() {
  assert cf_stir_shaken.decide(
      Some(inbound.Failed),
      Some("[SPAM?] Bob"),
      prefix,
    )
    == Decision(branch: "failed", caller_id_name: None)
}

pub fn no_validation_and_no_verdict_take_none_test() {
  assert cf_stir_shaken.decide(Some(inbound.NoValidation), Some("Bob"), prefix)
    == Decision(branch: "none", caller_id_name: None)
  assert cf_stir_shaken.decide(None, Some("Bob"), prefix)
    == Decision(branch: "none", caller_id_name: None)
}

/// The verdict is read from the call's own key-value store first, where
/// `cf_stir` puts the CCV map: it is on the record this action is handed,
/// so it is there whether or not the channel has caught up.
pub fn the_verdict_is_read_from_the_call_store_first_test() {
  // The store wins over the channel.
  assert cf_stir_shaken.verdict_of(stored(
      "TN-Validation-Passed",
      with_verstat("No-TN-Validation"),
    ))
    == Some(inbound.Passed)
  assert cf_stir_shaken.verdict_of(stored(
      "TN-Validation-Failed",
      call.from_value(doc.object([])),
    ))
    == Some(inbound.Failed)
  // A stored map with nothing usable in it falls back to the channel.
  assert cf_stir_shaken.verdict_of(stored(
      "whatever",
      with_verstat("TN-Validation-Failed"),
    ))
    == Some(inbound.Failed)
  let empty =
    call.kvs_store(
      with_verstat("TN-Validation-Passed"),
      cf_stir_shaken.verdict_key,
      doc.object([]),
    )
  assert cf_stir_shaken.verdict_of(empty) == Some(inbound.Passed)
  // And with neither, no verdict.
  assert cf_stir_shaken.verdict_of(stored(
      "whatever",
      call.from_value(doc.object([])),
    ))
    == None
}

/// The verdict is read from the `STIR-Verstat` channel variable; a call
/// without one, or with one that is not a verstat, has no verdict.
pub fn the_verdict_is_read_from_the_channel_test() {
  assert cf_stir_shaken.verdict_of(with_verstat("TN-Validation-Failed"))
    == Some(inbound.Failed)
  assert cf_stir_shaken.verdict_of(with_verstat("TN-Validation-Passed"))
    == Some(inbound.Passed)
  assert cf_stir_shaken.verdict_of(with_verstat("No-TN-Validation"))
    == Some(inbound.NoValidation)
  assert cf_stir_shaken.verdict_of(with_verstat("whatever")) == None
  assert cf_stir_shaken.verdict_of(call.from_value(doc.object([]))) == None
}

pub fn the_caller_id_name_is_set_on_the_call_test() {
  let before =
    call.from_value(doc.object([#("Caller-ID-Name", doc.String("Bob"))]))
  assert call.caller_id_name(before) == Some("Bob")
  let after = cf_stir_shaken.with_caller_id_name(before, "[SPAM?] Bob")
  assert call.caller_id_name(after) == Some("[SPAM?] Bob")
  // The setter answers a new call; the one it was given is unchanged.
  assert call.caller_id_name(before) == Some("Bob")
}

/// The call with the verdict's CCV map on it, the way `cf_stir` stores
/// it.
fn stored(verstat: String, call: call.Call) -> call.Call {
  call.kvs_store(
    call,
    cf_stir_shaken.verdict_key,
    doc.object([
      #("STIR-Verstat", doc.String(verstat)),
      #("STIR-Verdict-Source", doc.String("carrier")),
    ]),
  )
}

fn with_verstat(verstat: String) -> call.Call {
  call.from_value(
    doc.object([
      #(
        "Custom-Channel-Vars",
        doc.object([#("STIR-Verstat", doc.String(verstat))]),
      ),
    ]),
  )
}
