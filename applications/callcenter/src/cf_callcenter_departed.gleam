//// The callflow action `callcenter_departed`: a caller handed back to their
//// callflow on a node other than the one whose queue action put them in.
////
//// The queue's action (`cf_callcenter`) waits on the node that routed the
//// call for the caller's actor to hand them back, marks the channel
//// `Queue-Departed` for the passage as it takes them, and goes on down its
//// branch. When that node is gone the actor resumes the caller on whichever
//// callflow node takes the resume (`callcenter/call/actor.resumed_flow`),
//// and this runs first there: it writes the same mark, so that a node that
//// takes the caller over later finds them handed back already rather than
//// handing them back twice, and goes on to its one child, the branch's own
//// flow.
////
//// The mark is also how the actor that resumed the caller knows somebody
//// took the resume. The actor stays and watches the channel
//// (`core.Resumed`), and the first event carrying the mark ends the watch.
//// It publishes a resume that shows no mark again, and after
//// `core.resume_attempts` it hangs the caller up. So this writes the mark
//// before the flow does anything else.
////
//// A node with no `handoff_id` marks nothing and goes on all the same: a
//// caller is never held up by a mark.

import callcenter/call/recovery
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import kazoo/call.{type Call}
import kazoo/callflow
import kazoo/doc

pub fn handle(data: Dynamic, call: Call) -> Nil {
  case callflow.data_string(callflow.data(data), "handoff_id") {
    Some(handoff_id) ->
      call.set_channel_vars(
        call,
        [#(recovery.departed_var, doc.String(handoff_id))],
        [],
      )
    None -> Nil
  }
  callflow.continue(call)
}
