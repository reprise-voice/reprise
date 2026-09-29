//// Script events and time independently of command receipt. Checks run inside
//// the production loop, so they can assert nothing is published while answer
//// execution is delayed. Every test owns its state in its process dictionary.

import cf_callcenter
import kazoo/call
import kazoo/doc.{type Value}
import kazoo/testing/channel

pub type Step {
  EventAfter(milliseconds: Int, event: Value)
  DisappearAfter(milliseconds: Int)
  Check(fn() -> Nil)
}

/// The passage id every scripted caller joins with.
pub const handoff_id = "handoff-1"

/// The flows the scripted callflow would go on into.
pub fn branches() -> Value {
  doc.object([
    #("_", doc.object([#("module", doc.String("hangup"))])),
    #("exit_key", doc.object([#("module", doc.String("voicemail"))])),
  ])
}

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
    reply: fn(reply_to, payload) {
      note("member_continuing", reply_to)
      replied(payload)
    },
    mark: fn(call, vars) { call.set_channel_vars(call, vars, []) },
    continue_branch: continue_branch,
    stop: fn(_call) { note("stop", "") },
    let_go: fn(_call) { note("let_go", "") },
    branches: fn(_call) { branches() },
    handoff_id: fn() { handoff_id },
  )
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

@external(erlang, "queue_runtime_ffi", "replied")
fn replied(payload: Value) -> Nil

/// Every answer to a hand-back the action sent, oldest first.
@external(erlang, "queue_runtime_ffi", "replies")
pub fn replies() -> List(Value)

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
