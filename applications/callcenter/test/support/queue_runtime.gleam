//// Script events and time independently of command receipt. Checks run inside
//// the production loop, so they can assert no media/publication while answer
//// execution is delayed. Every test owns its state in its process dictionary.

import cf_callcenter
import gleam/option.{Some}
import kazoo/call
import kazoo/doc.{type Value}
import kazoo/testing/channel

pub type Step {
  EventAfter(milliseconds: Int, event: Value)
  DisappearAfter(milliseconds: Int)
  Check(fn() -> Nil)
}

/// A caller whose shard holder said it sends to the controller queue: no
/// listener, and the dispatcher's messages arrive as `cf_exe` relays them.
pub fn new(script: List(Step), now: Int) -> cf_callcenter.Runtime {
  channel.record()
  init(script, now)
  cf_callcenter.Runtime(
    now: fn() { 100 + now_ms() / 1000 },
    monotonic_ms: now_ms,
    receive_event: next,
    answer: call.answer_now,
    destroyed: destroyed,
    publish: publish,
    continue_branch: continue_branch,
    listen: cf_callcenter.no_listener,
  )
}

/// A caller whose shard holder did not say so -- a node of the release
/// before, or no answer: the action listens on the exchange key. Starting
/// and stopping the listener are noted as the commands `listen` (the call
/// id) and `stop_listening`, in order with everything else sent.
pub fn new_listening(script: List(Step), now: Int) -> cf_callcenter.Runtime {
  cf_callcenter.Runtime(..new(script, now), listen: fn(_account_id, call_id) {
    note("listen", call_id)
    Some(fn() { note("stop_listening", "") })
  })
}

@external(erlang, "kazoo_gleam_call_ffi", "note")
fn note(name: String, argument: String) -> Nil

@external(erlang, "queue_runtime_ffi", "init")
fn init(script: List(Step), now: Int) -> Nil

@external(erlang, "queue_runtime_ffi", "now_ms")
pub fn now_ms() -> Int

@external(erlang, "queue_runtime_ffi", "next")
fn next(timeout: Int) -> Result(Value, call.Timeout)

@external(erlang, "queue_runtime_ffi", "destroyed")
fn destroyed(call: call.Call) -> Bool

@external(erlang, "queue_runtime_ffi", "publish")
fn publish(shard: Int, name: String, payload: Value) -> Result(Nil, Nil)

@external(erlang, "queue_runtime_ffi", "publications")
pub fn publications() -> List(#(String, Value))

@external(erlang, "queue_runtime_ffi", "continue_branch")
fn continue_branch(call: call.Call, branch: String) -> Nil

/// The call record the action handed on to the rest of its callflow, when
/// it went on to a branch.
@external(erlang, "queue_runtime_ffi", "continued_with")
pub fn continued_with() -> Result(call.Call, Nil)

@external(erlang, "queue_runtime_ffi", "fail_publication")
pub fn fail_publication() -> Nil

@external(erlang, "queue_runtime_ffi", "hangup_on_publication")
pub fn hangup_on_publication() -> Nil
