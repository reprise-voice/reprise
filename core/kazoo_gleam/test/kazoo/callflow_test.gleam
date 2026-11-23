//// A callflow action: reading its data, building the flows it branches
//// into, and ending without a `cf_exe` to end into.

import gleam/option.{None, Some}
import kazoo/call
import kazoo/callflow
import kazoo/doc

fn a_call() -> call.Call {
  call.from_value(
    doc.object([
      #("Call-ID", doc.String("4b1f0c2d-7e8a-9b0c")),
      #("Control-Queue", doc.String("callctl-4b1f")),
      #("Controller-Queue", doc.String("callflow-node-1")),
    ]),
  )
}

fn action_data() -> doc.Value {
  doc.object([
    #("id", doc.String("6a7b8c9d0e1f2a3b4c5d6e7f80912233")),
    #("max_queue_size", doc.Int(25)),
    #("enter_when_empty", doc.Bool(False)),
    #("exit_keys", doc.List([doc.String("1"), doc.String("2"), doc.Int(3)])),
    #("announcements", doc.object([#("interval", doc.Int(30))])),
  ])
}

pub fn data_helpers_test() {
  let data = action_data()
  assert callflow.data_string(data, "id")
    == Some("6a7b8c9d0e1f2a3b4c5d6e7f80912233")
  assert callflow.data_string(data, "missing") == None
  // A key of the wrong type reads as absent rather than as a crash.
  assert callflow.data_string(data, "max_queue_size") == None

  assert callflow.data_int(data, "max_queue_size", 50) == 25
  assert callflow.data_int(data, "missing", 50) == 50
  assert callflow.data_int(data, "id", 50) == 50

  assert callflow.data_bool(data, "enter_when_empty", True) == False
  assert callflow.data_bool(data, "missing", True) == True

  // Anything in the list that is not a string is skipped, not fatal.
  assert callflow.data_strings(data, "exit_keys") == ["1", "2"]
  assert callflow.data_strings(data, "missing") == []

  assert doc.get_int(callflow.data_object(data, "announcements"), ["interval"])
    == Ok(30)
  assert callflow.data_object(data, "missing") == doc.object([])
}

pub fn flow_building_test() {
  let flow =
    callflow.flow(
      module: "callcenter",
      data: doc.object([#("id", doc.String("q1"))]),
      children: [
        #("_", callflow.empty_flow()),
        #("timeout", callflow.empty_flow()),
      ],
    )
  assert doc.get_string(flow, ["module"]) == Ok("callcenter")
  assert doc.get_string(flow, ["data", "id"]) == Ok("q1")
  assert callflow.branch_keys(flow) == ["_", "timeout"]
  assert callflow.branch_keys(callflow.empty_flow()) == []
  assert callflow.branch_keys(doc.object([])) == []
}

/// The name a callflow node has to carry, and the module it resolves to.
pub fn action_module_test() {
  assert callflow.action_module("callcenter") == "cf_callcenter"
  // Nothing named this is loadable here, so `cf_exe` would not run it.
  assert !callflow.is_action("no_such_action_at_all")
}

/// With no flow running, every ending is a no-op and every read falls back
/// to the call itself.
pub fn endings_are_safe_test() {
  let c = a_call()
  assert callflow.continue(c) == Nil
  assert callflow.continue_branch(c, "timeout") == Nil
  assert callflow.continue_with_flow(c, callflow.empty_flow()) == Nil
  assert callflow.branch(c, callflow.empty_flow()) == Nil
  assert callflow.stop(c) == Nil
  assert callflow.stop_with_cause(c, "USER_BUSY") == Nil
  assert callflow.transfer(c) == Nil
  assert callflow.control_usurped(c) == Nil
  assert callflow.set_call(c) == Nil
  assert callflow.add_call_binding(c, "other-leg") == Nil
  assert callflow.add_event_listener(c, "cf_gleam_watcher", []) == Nil
  assert callflow.add_termination_handler(c, "cf_gleam_spike", "on_hangup", [])
    == Nil
  assert !callflow.is_channel_destroyed(c)
}

pub fn flow_state_test() {
  let c = a_call()
  assert callflow.call_id(callflow.get_call(c)) == Some("4b1f0c2d-7e8a-9b0c")
  assert callflow.control_queue(callflow.update_call(c)) == Some("callctl-4b1f")
  assert callflow.queue_name(c) == Some("callflow-node-1")
  assert callflow.call_id(call.new()) == None
}
