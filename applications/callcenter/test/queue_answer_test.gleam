//// Exercise the callflow action with independently scheduled switch events:
//// the answer and the join, then the wait for the caller to be handed back.

import cf_callcenter
import gleam/list
import gleam/option.{Some}
import kazoo/call
import kazoo/doc
import kazoo/testing/channel.{type Command, Command}
import support/queue_runtime.{Check, DisappearAfter, EventAfter} as runtime

const caller_id = "queue-caller"

fn event(
  category: String,
  name: String,
  fields: List(#(String, doc.Value)),
) -> doc.Value {
  doc.object([
    #("Event-Category", doc.String(category)),
    #("Event-Name", doc.String(name)),
    #("Call-ID", doc.String(caller_id)),
    ..fields
  ])
}

fn answered() -> doc.Value {
  event("call_event", "CHANNEL_ANSWER", [])
}

fn hangup() -> doc.Value {
  event("call_event", "CHANNEL_DESTROY", [])
}

fn complete(app: String, state: String, response: String) -> doc.Value {
  event("call_event", "CHANNEL_EXECUTE_COMPLETE", [
    #("Application-Name", doc.String(app)),
    #("Application-Response", doc.String(response)),
    #("Channel-Answer-State", doc.String(state)),
  ])
}

/// The actor handing the caller back, as `cf_exe` relays it from the call's
/// controller queue.
fn handed_back(handoff_id: String, branch: String) -> doc.Value {
  event("callcenter", "member_continue", [
    #("Account-ID", doc.String("account")),
    #("Queue-ID", doc.String("queue")),
    #("Handoff-ID", doc.String(handoff_id)),
    #("Branch", doc.String(branch)),
    #("Reply-To", doc.String("pid://<0.1.0>/call_replies")),
  ])
}

fn run(queue: doc.Value, rt: cf_callcenter.Runtime) -> Nil {
  cf_callcenter.run(
    doc.object([]),
    call.from_value(
      doc.object([
        #("Account-ID", doc.String("account")),
        #("Call-ID", doc.String(caller_id)),
      ]),
    ),
    "queue",
    queue,
    0,
    100,
    rt,
  )
}

fn commands() -> List(Command) {
  channel.sent()
  |> list.filter(fn(c) { c.name != "set_channel_vars" && c.name != "set_call" })
}

fn nothing_published() -> Nil {
  assert runtime.publications() == []
  assert list.all(commands(), fn(c) { c == Command("answer", "now") })
}

// --- Joining -----------------------------------------------------------------

/// A caller an agent of another queue answered and transferred here: their
/// channel still says who answered them there, and when. Joining unsets
/// both, so the call the member message carries -- and the channel, and the
/// CDR a caller who abandons this queue leaves -- says nobody has answered
/// this passage.
pub fn joining_clears_an_earlier_passages_answer_test() {
  let rt = runtime.new([EventAfter(0, answered()), EventAfter(0, hangup())], 0)
  cf_callcenter.run(
    doc.object([]),
    call.from_value(
      doc.object([
        #("Account-ID", doc.String("account")),
        #("Call-ID", doc.String(caller_id)),
        #(
          "Custom-Channel-Vars",
          doc.object([
            #("Agent-ID", doc.String("agent-from-queue-one")),
            #("Queue-Answered-Timestamp", doc.Int(50)),
            #("Queue-ID", doc.String("queue-one")),
          ]),
        ),
      ]),
    ),
    "queue",
    doc.object([]),
    0,
    100,
    rt,
  )
  let assert Ok(#(_, member)) =
    list.find(runtime.publications(), fn(p) { p.0 == "member_call" })
  let ccvs = ["Call", "Custom-Channel-Vars"]
  assert doc.get_string(member, list.append(ccvs, ["Agent-ID"])) == Ok("")
  assert doc.get_string(member, list.append(ccvs, ["Queue-Answered-Timestamp"]))
    == Ok("")
  assert doc.get_string(member, list.append(ccvs, ["Queue-ID"])) == Ok("queue")
}

/// The member names the passage, which is what the actor hands the caller
/// back by, and the flows the callflow would go on into, which is what the
/// caller is resumed at if this node goes.
pub fn the_member_names_the_passage_and_its_branches_test() {
  let rt = runtime.new([EventAfter(0, answered()), EventAfter(0, hangup())], 0)
  run(doc.object([]), rt)
  let assert [#("member_call", member)] = runtime.publications()
  assert doc.get_string(member, ["Handoff-ID"]) == Ok(runtime.handoff_id)
  assert doc.get(member, ["Branches"]) == Ok(runtime.branches())
}

/// The answer's confirmation is the gate: nothing goes out before it, and
/// the caller joins on it with nothing sent the channel but the answer. The
/// greeting and the hold are the actor's.
pub fn delayed_execution_never_publishes_and_duplicate_confirmation_is_idempotent_test() {
  let rt =
    runtime.new(
      [
        Check(nothing_published),
        EventAfter(
          4000,
          event("call_event", "CHANNEL_EXECUTE", [
            #("Application-Name", doc.String("answer")),
          ]),
        ),
        Check(nothing_published),
        EventAfter(100, answered()),
        EventAfter(0, answered()),
        EventAfter(0, complete("answer", "answered", "_none_")),
        EventAfter(0, hangup()),
      ],
      0,
    )
  run(doc.object([#("moh", doc.String("assigned-music"))]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("member_call", ""),
      Command("stop", ""),
    ]
}

pub fn an_already_answered_channel_can_join_from_execute_complete_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, complete("answer", "answered", "_none_")),
        EventAfter(0, hangup()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.take(commands(), 2)
    == [Command("answer", "now"), Command("member_call", "")]
}

pub fn unrelated_leg_and_unproven_completion_cannot_open_the_gate_test() {
  let other_leg = doc.set(answered(), ["Call-ID"], doc.String("agent-leg"))
  let rt =
    runtime.new(
      [
        EventAfter(0, other_leg),
        Check(nothing_published),
        EventAfter(0, complete("answer", "ringing", "_none_")),
        Check(nothing_published),
        EventAfter(
          0,
          event("call_event", "CHANNEL_EXECUTE_COMPLETE", [
            #("Application-Name", doc.String("answer")),
          ]),
        ),
        Check(nothing_published),
        EventAfter(0, answered()),
        EventAfter(0, hangup()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.length(runtime.publications()) == 1
}

pub fn lost_confirmation_retries_once_without_resetting_joined_time_test() {
  let rt =
    runtime.new(
      [
        EventAfter(5001, complete("answer", "answered", "_none_")),
        EventAfter(0, hangup()),
      ],
      20_000,
    )
  run(doc.object([]), rt)
  assert list.take(commands(), 3)
    == [
      Command("answer", "now"),
      Command("answer", "now"),
      Command("member_call", ""),
    ]
  let assert [#("member_call", member), ..] = runtime.publications()
  assert doc.get_int(member, ["Joined-Timestamp"]) == Ok(100)
  assert runtime.now_ms() == 25_001
}

pub fn exhaustion_takes_the_compatibility_branch_test() {
  let rt = runtime.new([], 20_000)
  run(doc.object([#("greeting", doc.String("welcome"))]), rt)
  assert runtime.now_ms() == 30_000
  assert runtime.publications() == []
  assert commands()
    == [
      Command("answer", "now"),
      Command("answer", "now"),
      Command("flush", ""),
      Command("continue_branch", "no_agents"),
    ]
}

pub fn explicit_answer_errors_fail_without_retry_test() {
  let errors = [
    event("error", "dialplan", [
      #(
        "Request",
        doc.object([
          #("Application-Name", doc.String("answer")),
        ]),
      ),
    ]),
    complete("answer", "answered", "ERROR"),
    complete("answer", "answered", "-ERR channel unavailable"),
    doc.set(
      complete("answer", "answered", "_none_"),
      ["Application-Error-Code"],
      doc.String("500"),
    ),
  ]
  list.each(errors, fn(error) {
    let rt = runtime.new([EventAfter(25, error)], 0)
    run(doc.object([]), rt)
    assert runtime.publications() == []
    assert runtime.now_ms() == 25
    assert commands()
      == [
        Command("answer", "now"),
        Command("flush", ""),
        Command("continue_branch", "no_agents"),
      ]
  })
}

pub fn caller_hangup_during_answer_setup_only_cleans_up_test() {
  list.each([[EventAfter(1, hangup())], [DisappearAfter(1)]], fn(script) {
    let rt = runtime.new(script, 0)
    run(doc.object([]), rt)
    assert runtime.publications() == []
    assert commands() == [Command("answer", "now"), Command("stop", "")]
  })
}

/// An exit key before the caller has joined takes them out on `exit_key`,
/// with nothing published: there is no member for anybody to hold.
pub fn an_exit_key_during_setup_takes_the_exit_branch_test() {
  let rt =
    runtime.new(
      [
        EventAfter(
          1,
          event("call_event", "DTMF", [
            #("DTMF-Digit", doc.String("#")),
          ]),
        ),
      ],
      0,
    )
  run(doc.object([#("exit_keys", doc.String("#"))]), rt)
  assert runtime.publications() == []
  assert list.last(commands()) == Ok(Command("continue_branch", "exit_key"))
}

pub fn publication_failure_flushes_before_continuing_test() {
  runtime.fail_publication()
  let rt = runtime.new([EventAfter(0, answered())], 0)
  runtime.fail_publication()
  run(doc.object([]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("member_call", ""),
      Command("flush", ""),
      Command("continue_branch", "no_agents"),
    ]
}

/// A caller who hangs up as their member goes out is the actor's to settle:
/// the action only stops.
pub fn hangup_during_publication_stops_test() {
  let rt = runtime.new([EventAfter(0, answered())], 0)
  runtime.hangup_on_publication()
  run(doc.object([]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("member_call", ""),
      Command("stop", ""),
    ]
}

// --- Waiting to be handed back ------------------------------------------------

/// While the caller is in the queue the action sends their channel nothing:
/// the channel's own events -- keys, the ends of the actor's media -- are
/// the actor's. The actor hands the caller back on a branch: the action
/// answers it, marks the channel, and goes on there.
pub fn the_caller_is_handed_back_on_a_branch_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(
          2000,
          event("call_event", "DTMF", [#("DTMF-Digit", doc.String("#"))]),
        ),
        EventAfter(0, complete("noop", "answered", "some-announcement")),
        Check(fn() {
          assert commands()
            == [Command("answer", "now"), Command("member_call", "")]
        }),
        EventAfter(100, handed_back(runtime.handoff_id, "exit_key")),
      ],
      0,
    )
  run(doc.object([#("exit_keys", doc.String("#"))]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("member_call", ""),
      Command("member_continuing", "pid://<0.1.0>/call_replies"),
      Command("continue_branch", "exit_key"),
    ]
  let assert [reply] = runtime.replies()
  assert doc.get_string(reply, ["Handoff-ID"]) == Ok(runtime.handoff_id)
  assert doc.get_string(reply, ["Call-ID"]) == Ok(caller_id)
  let assert Ok(marked) =
    list.find(channel.sent(), fn(c) { c.name == "set_channel_vars" })
  assert marked.name == "set_channel_vars"
}

/// A hand-back of another passage -- the caller's earlier time through this
/// queue, or another queue's -- is not this one's.
pub fn another_passages_hand_back_is_not_taken_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, handed_back("an-earlier-passage", "timeout")),
        Check(fn() {
          assert runtime.replies() == []
        }),
        EventAfter(0, handed_back(runtime.handoff_id, "timeout")),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.last(commands()) == Ok(Command("continue_branch", "timeout"))
  assert list.length(runtime.replies()) == 1
}

/// The caller's channel going while they wait ends the callflow, and so does
/// a wait longer than any call.
pub fn the_wait_ends_with_the_channel_test() {
  let rt =
    runtime.new([EventAfter(0, answered()), EventAfter(5000, hangup())], 0)
  run(doc.object([]), rt)
  assert list.last(commands()) == Ok(Command("stop", ""))

  let rt = runtime.new([EventAfter(0, answered()), DisappearAfter(70_000)], 0)
  run(doc.object([]), rt)
  assert list.last(commands()) == Ok(Command("stop", ""))

  let rt = runtime.new([EventAfter(0, answered())], 0)
  run(doc.object([]), rt)
  assert list.last(commands()) == Ok(Command("stop", ""))
  assert runtime.now_ms() >= 14_400_000
}

/// What one event means to a caller waiting to be handed back.
pub fn what_a_waiting_caller_hears_test() {
  assert cf_callcenter.heard(handed_back("h1", "timeout"), caller_id, "h1")
    == cf_callcenter.Continue("timeout", Some("pid://<0.1.0>/call_replies"))
  assert cf_callcenter.heard(handed_back("h0", "timeout"), caller_id, "h1")
    == cf_callcenter.Nothing
  assert cf_callcenter.heard(
      doc.set(handed_back("h1", "timeout"), ["Call-ID"], doc.String("other")),
      caller_id,
      "h1",
    )
    == cf_callcenter.Nothing
  assert cf_callcenter.heard(hangup(), caller_id, "h1") == cf_callcenter.Gone
  assert cf_callcenter.heard(answered(), caller_id, "h1")
    == cf_callcenter.Nothing
}
