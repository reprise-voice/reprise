//// Writing a callflow action.
////
//// A callflow is a tree of actions. `cf_exe` walks it: for each node it
//// looks up the module `cf_<module>`, checks that it exports `handle/2`, and
//// spawns `Module:handle(Data, Call)` in a process that receives the call's
//// events. That process has to end by saying what happens next; an action
//// that simply returns leaves `cf_exe` with a dead flow and the caller is
//// hung up.
////
//// A Gleam module at the top of `src` compiles to an Erlang module of
//// exactly that name, so `src/cf_queue.gleam` is the callflow action
//// `queue`. It must be at the top of `src`: a module at `src/my_app/queue`
//// compiles to `my_app@queue`, which no callflow can name. Its entry point
//// is
////
//// ```gleam
//// pub fn handle(data: Dynamic, call: Call) -> Nil {
////   let data = callflow.data(data)
////   ...
//// }
//// ```
////
//// `data` is the node's `data` object as a `kz_json` object, the one place a
//// Gleam action meets one; `callflow.data` is the conversion and should be
//// the first thing the action does with it.
////
//// Every path through `handle` has to reach exactly one of `continue`,
//// `continue_branch`, `continue_with_flow`, `branch`, `stop`,
//// `stop_with_cause`, `transfer` or `control_usurped`.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option}
import kazoo/call.{type Call}
import kazoo/doc.{type Value}

/// The action's `data` object as a document. Call this first: what `cf_exe`
/// hands `handle/2` is a `kz_json` object, which nothing else in Gleam can
/// read.
pub fn data(raw: Dynamic) -> Value {
  doc.from_dynamic(ffi_data(raw))
}

@external(erlang, "kazoo_gleam_callflow_ffi", "data")
fn ffi_data(raw: Dynamic) -> Dynamic

// ---------------------------------------------------------------------------
// Reading the action's data
// ---------------------------------------------------------------------------

/// A string at the top of the action's data.
pub fn data_string(data: Value, key: String) -> Option(String) {
  option.from_result(doc.get_string(data, [key]))
}

pub fn data_int(data: Value, key: String, default: Int) -> Int {
  case doc.get_int(data, [key]) {
    Ok(number) -> number
    Error(Nil) -> default
  }
}

pub fn data_bool(data: Value, key: String, default: Bool) -> Bool {
  case doc.get_bool(data, [key]) {
    Ok(bool) -> bool
    Error(Nil) -> default
  }
}

/// A list of strings at the top of the action's data, empty when there is
/// none. Anything in the list that is not a string is skipped.
pub fn data_strings(data: Value, key: String) -> List(String) {
  doc.strings(data, [key])
}

/// A nested object, or an empty one.
pub fn data_object(data: Value, key: String) -> Value {
  case doc.get(data, [key]) {
    Ok(value) -> value
    Error(Nil) -> doc.object([])
  }
}

// ---------------------------------------------------------------------------
// Endings
// ---------------------------------------------------------------------------

/// Take the flow's `_` child, which is what an action that did its job and
/// has nothing to say about the outcome does.
@external(erlang, "kazoo_gleam_callflow_ffi", "continue")
pub fn continue(call: Call) -> Nil

/// Take the named child. A flow with no such branch takes `_` instead, so an
/// action may always offer its outcomes as branches.
@external(erlang, "kazoo_gleam_callflow_ffi", "continue_branch")
pub fn continue_branch(call: Call, key: String) -> Nil

/// Carry on into a flow built here rather than one of this action's own
/// children.
pub fn continue_with_flow(call: Call, flow: Value) -> Nil {
  ffi_continue_with_flow(call, doc.to_string(flow))
}

/// Run a flow and come back to this action's children afterwards.
pub fn branch(call: Call, flow: Value) -> Nil {
  ffi_branch(call, doc.to_string(flow))
}

/// End the flow and hang the channel up.
@external(erlang, "kazoo_gleam_callflow_ffi", "stop")
pub fn stop(call: Call) -> Nil

/// End the flow with the hangup cause the CDR should carry: `USER_BUSY`,
/// `NO_ANSWER`, `NORMAL_CLEARING`.
@external(erlang, "kazoo_gleam_callflow_ffi", "stop_with_cause")
pub fn stop_with_cause(call: Call, cause: String) -> Nil

/// End the flow because the channel is being transferred: the flow stops and
/// the channel is left alone.
@external(erlang, "kazoo_gleam_callflow_ffi", "transfer")
pub fn transfer(call: Call) -> Nil

/// End the flow because another process has taken control of the channel.
@external(erlang, "kazoo_gleam_callflow_ffi", "control_usurped")
pub fn control_usurped(call: Call) -> Nil

@external(erlang, "kazoo_gleam_callflow_ffi", "continue_with_flow")
fn ffi_continue_with_flow(call: Call, flow_json: String) -> Nil

@external(erlang, "kazoo_gleam_callflow_ffi", "branch")
fn ffi_branch(call: Call, flow_json: String) -> Nil

// ---------------------------------------------------------------------------
// The running flow
// ---------------------------------------------------------------------------

/// The call as `cf_exe` has it, which is newer than the copy this action was
/// spawned with whenever an earlier action changed it.
@external(erlang, "kazoo_gleam_callflow_ffi", "get_call")
pub fn get_call(call: Call) -> Call

/// Hand `cf_exe` a call this action has changed, so the actions after it see
/// the change.
@external(erlang, "kazoo_gleam_callflow_ffi", "set_call")
pub fn set_call(call: Call) -> Nil

/// Merge this action's changes into `cf_exe`'s copy and take the result.
@external(erlang, "kazoo_gleam_callflow_ffi", "update_call")
pub fn update_call(call: Call) -> Call

/// The queue commands for this channel go to.
pub fn control_queue(call: Call) -> Option(String) {
  option.from_result(ffi_control_queue(call))
}

/// The queue `cf_exe` consumes from, which is what a reply to a command is
/// addressed to and what another node sends this flow a message on.
pub fn queue_name(call: Call) -> Option(String) {
  option.from_result(ffi_queue_name(call))
}

pub fn call_id(call: Call) -> Option(String) {
  option.from_result(ffi_call_id(call))
}

/// Whether the channel is already gone. An action that has been waiting
/// should ask before it sends anything else.
@external(erlang, "kazoo_gleam_callflow_ffi", "is_channel_destroyed")
pub fn is_channel_destroyed(call: Call) -> Bool

/// Have `cf_exe` consume another call's events as well as this one's and
/// forward them here, which is how an action follows a leg it created.
@external(erlang, "kazoo_gleam_callflow_ffi", "add_call_binding")
pub fn add_call_binding(call: Call, call_id: String) -> Nil

/// Start a process under the callflow's supervisor that receives this call's
/// events for as long as the flow runs. `cf_exe` starts it as
/// `module:start_link(call, args...)`.
///
/// `module` is an Erlang module name applied at run time. A Gleam module's
/// compiled name is its path with `/` replaced by `@`, so `my_app/watcher`
/// is `"my_app@watcher"` here.
pub fn add_event_listener(
  call: Call,
  module: String,
  args: List(Value),
) -> Nil {
  ffi_add_event_listener(call, module, doc.to_string(doc.List(args)))
}

/// Run `module:function(call, hangup_event, args...)` when the flow ends,
/// whatever ends it. The extra arguments are spliced, so with none the
/// function has two parameters, the second being the hangup event as a
/// `kz_json` object -- pass it through `data` to read it.
///
/// `module` and `function` are applied by name, so they must name something
/// Erlang can call. A Gleam module qualifies: its compiled name is its path
/// with `/` replaced by `@`, which for a module at the top of `src` is just
/// its name, and a `pub fn` is exported under its own name at its own
/// arity.
pub fn add_termination_handler(
  call: Call,
  module: String,
  function: String,
  args: List(Value),
) -> Nil {
  ffi_add_termination_handler(
    call,
    module,
    function,
    doc.to_string(doc.List(args)),
  )
}

/// Whether `cf_exe` would resolve a callflow action of this name and run it:
/// the module `cf_<action>` is loadable and exports `handle/2`. This is the
/// test `cf_exe` itself makes, and the way to check that a Gleam action is
/// reachable on a running node.
@external(erlang, "kazoo_gleam_callflow_ffi", "is_action")
pub fn is_action(action: String) -> Bool

/// The name a callflow node has to carry in its `module` key for `action` to
/// run: the module name without its `cf_` prefix.
pub fn action_module(action: String) -> String {
  "cf_" <> action
}

/// A flow node, for `branch` and `continue_with_flow`: the action to run,
/// its data, and its children by branch key.
pub fn flow(
  module module: String,
  data data: Value,
  children children: List(#(String, Value)),
) -> Value {
  doc.object([
    #("module", doc.String(module)),
    #("data", data),
    #("children", doc.object(children)),
  ])
}

/// A flow that runs nothing, which is the child a branch needs when the
/// answer is simply "stop here".
pub fn empty_flow() -> Value {
  doc.object([#("children", doc.object([]))])
}

/// The branch keys a flow node offers, which is what an action asks before
/// it decides whether an outcome has anywhere to go.
pub fn branch_keys(flow: Value) -> List(String) {
  case doc.get(flow, ["children"]) {
    Ok(children) -> list.map(doc.members(children), fn(child) { child.0 })
    Error(Nil) -> []
  }
}

@external(erlang, "kazoo_gleam_callflow_ffi", "control_queue")
fn ffi_control_queue(call: Call) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_callflow_ffi", "queue_name")
fn ffi_queue_name(call: Call) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_callflow_ffi", "call_id")
fn ffi_call_id(call: Call) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_callflow_ffi", "add_event_listener")
fn ffi_add_event_listener(call: Call, module: String, args_json: String) -> Nil

@external(erlang, "kazoo_gleam_callflow_ffi", "add_termination_handler")
fn ffi_add_termination_handler(
  call: Call,
  module: String,
  function: String,
  args_json: String,
) -> Nil
