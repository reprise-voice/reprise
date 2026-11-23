//// Exercise the production loop with independently scheduled switch events.

import cf_callcenter
import gleam/list
import gleam/option.{None, Some}
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

/// One of the dispatcher's messages about this caller in this queue, as
/// `cf_exe` relays it from the call's controller queue.
fn from_dispatcher(
  name: String,
  fields: List(#(String, doc.Value)),
) -> doc.Value {
  event("callcenter", name, [#("Queue-ID", doc.String("queue")), ..fields])
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

fn run(queue: doc.Value, rt: cf_callcenter.Runtime) -> Nil {
  run_with_status(queue, rt, None)
}

fn run_with_status(
  queue: doc.Value,
  rt: cf_callcenter.Runtime,
  status: option.Option(cf_callcenter.Status),
) -> Nil {
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
    status,
    0,
    100,
    rt,
  )
}

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
    None,
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

fn commands() -> List(Command) {
  channel.sent()
  |> list.filter(fn(c) { c.name != "set_channel_vars" && c.name != "set_call" })
}

fn no_dispatch_or_media() -> Nil {
  assert runtime.publications() == []
  assert list.all(commands(), fn(c) { c == Command("answer", "now") })
}

pub fn delayed_execution_never_dispatches_and_duplicate_confirmation_is_idempotent_test() {
  let rt =
    runtime.new(
      [
        Check(no_dispatch_or_media),
        EventAfter(
          4000,
          event("call_event", "CHANNEL_EXECUTE", [
            #("Application-Name", doc.String("answer")),
          ]),
        ),
        Check(no_dispatch_or_media),
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
      Command("hold_queued", "assigned-music"),
      Command("member_call", ""),
      Command("member_cancel", ""),
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
  assert list.take(commands(), 3)
    == [
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
    ]
}

pub fn unrelated_leg_and_unproven_completion_cannot_open_the_gate_test() {
  let other_leg = doc.set(answered(), ["Call-ID"], doc.String("agent-leg"))
  let rt =
    runtime.new(
      [
        EventAfter(0, other_leg),
        Check(no_dispatch_or_media),
        EventAfter(0, complete("answer", "ringing", "_none_")),
        Check(no_dispatch_or_media),
        EventAfter(
          0,
          event("call_event", "CHANNEL_EXECUTE_COMPLETE", [
            #("Application-Name", doc.String("answer")),
          ]),
        ),
        Check(no_dispatch_or_media),
        EventAfter(0, answered()),
        EventAfter(0, hangup()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.length(runtime.publications()) == 2
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
  assert list.take(commands(), 4)
    == [
      Command("answer", "now"),
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
    ]
  let assert [#("member_call", member), ..] = runtime.publications()
  assert doc.get_int(member, ["Joined-Timestamp"]) == Ok(100)
  assert runtime.now_ms() == 25_001
}

pub fn exhaustion_never_starts_greeting_or_hold_and_takes_compatibility_branch_test() {
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
  list.each(
    [
      [EventAfter(1, hangup())],
      [DisappearAfter(1)],
    ],
    fn(script) {
      let rt = runtime.new(script, 0)
      run(doc.object([]), rt)
      assert runtime.publications() == []
      assert commands()
        == [
          Command("answer", "now"),
          Command("stop", ""),
        ]
    },
  )
}

pub fn caller_exit_during_setup_never_cancels_an_unpublished_member_test() {
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

pub fn configured_wait_limits_apply_during_setup_test() {
  let rt = runtime.new([], 0)
  run(doc.object([#("max_wait_time", doc.Int(3))]), rt)
  assert runtime.now_ms() == 3000
  assert runtime.publications() == []
  assert list.last(commands()) == Ok(Command("continue_branch", "timeout"))

  let rt = runtime.new([], 0)
  run_with_status(
    doc.object([#("max_wait_time_with_no_agent", doc.Int(2))]),
    rt,
    Some(cf_callcenter.Status(waiting: Some(0), agents_available: Some(0))),
  )
  assert runtime.now_ms() == 2000
  assert runtime.publications() == []
  assert list.last(commands())
    == Ok(Command("continue_branch", "no_agent_timeout"))
}

/// A dispatcher's message reaches whatever action the call's executor is
/// running when it lands. An offer from a queue the caller was in before --
/// sent as they timed out of it into this one -- is not about this passage:
/// the no-agent clock runs on, and there is no ring to call off.
pub fn another_queues_offer_leaves_the_no_agent_clock_running_test() {
  let nobody =
    Some(cf_callcenter.Status(waiting: Some(0), agents_available: Some(0)))
  let queue = doc.object([#("max_wait_time_with_no_agent", doc.Int(2))])
  let earlier =
    event("callcenter", "member_offer", [
      #("Queue-ID", doc.String("earlier-queue")),
      #("Offer-Timeout", doc.Int(20)),
    ])
  let rt = runtime.new([EventAfter(0, answered()), EventAfter(500, earlier)], 0)
  run_with_status(queue, rt, nobody)
  // The clocks count in whole seconds, and the offer woke the loop half way
  // through one: the caller goes on the wake after the two seconds are up.
  assert runtime.now_ms() == 2500
  assert list.contains(commands(), Command("unbridge", "")) == False
  assert list.last(commands())
    == Ok(Command("continue_branch", "no_agent_timeout"))

  // The same offer from this queue is somebody ringing for the caller.
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(
          500,
          from_dispatcher("member_offer", [#("Offer-Timeout", doc.Int(20))]),
        ),
      ],
      0,
    )
  run_with_status(queue, rt, nobody)
  assert runtime.now_ms() > 20_000
}

/// A caller a timeout or exit branch sent straight back into the queue they
/// left, on the same executor: the first passage's last offer, in flight as
/// it left, says the first passage's join and is not about this one. The
/// no-agent clock runs on, and there is no ring to call off. The same offer
/// from a dispatcher of an earlier release, which says no join, is heard as
/// it always was; and one about this passage is somebody ringing.
pub fn the_last_passages_offer_is_not_this_ones_test() {
  let nobody =
    Some(cf_callcenter.Status(waiting: Some(0), agents_available: Some(0)))
  let queue = doc.object([#("max_wait_time_with_no_agent", doc.Int(2))])
  let offer = fn(joined: option.Option(Int)) {
    from_dispatcher("member_offer", [
      #("Offer-Timeout", doc.Int(20)),
      ..case joined {
        Some(joined) -> [#("Joined-Timestamp", doc.Int(joined))]
        None -> []
      }
    ])
  }
  let back = fn(rt) {
    cf_callcenter.run(
      doc.object([]),
      cf_callcenter.ran_here(
        call.from_value(
          doc.object([
            #("Account-ID", doc.String("account")),
            #("Call-ID", doc.String(caller_id)),
          ]),
        ),
        "queue",
        90,
      ),
      "queue",
      queue,
      nobody,
      0,
      100,
      rt,
    )
  }

  let stale = offer(Some(90))
  let rt = runtime.new([EventAfter(0, answered()), EventAfter(500, stale)], 0)
  back(rt)
  assert runtime.now_ms() == 2500
  assert list.contains(commands(), Command("unbridge", "")) == False
  assert list.last(commands())
    == Ok(Command("continue_branch", "no_agent_timeout"))

  list.each([offer(Some(100)), offer(None)], fn(heard) {
    let rt = runtime.new([EventAfter(0, answered()), EventAfter(500, heard)], 0)
    back(rt)
    assert runtime.now_ms() > 20_000
  })

  // The first time this executor has the caller in the queue, an older join
  // is the passage the dispatcher kept for a callflow run again elsewhere.
  let rt = runtime.new([EventAfter(0, answered()), EventAfter(500, stale)], 0)
  run_with_status(queue, rt, nobody)
  assert runtime.now_ms() > 20_000
}

/// A position that says no offer is in flight ends the ring the caller was
/// told of, as the bridge finishing would: a bridge that was sent and never
/// ran shows no end on the channel, and the no-agent clock would stay
/// stopped until the ring's ceiling. It runs from the position's count, and
/// the caller leaving is not an unbridge of a ring that is not there.
pub fn a_position_with_no_offer_out_ends_the_ring_test() {
  let nobody =
    Some(cf_callcenter.Status(waiting: Some(0), agents_available: Some(0)))
  let queue = doc.object([#("max_wait_time_with_no_agent", doc.Int(2))])
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(500, offered(20)),
        EventAfter(
          500,
          from_dispatcher("member_position", [
            #("Position", doc.Int(1)),
            #("Waiting", doc.Int(1)),
            #("Agents-Available", doc.Int(0)),
            #("Offered", doc.Bool(False)),
          ]),
        ),
      ],
      0,
    )
  run_with_status(queue, rt, nobody)
  assert runtime.now_ms() < 5000
  assert list.contains(commands(), Command("unbridge", "")) == False
  assert list.last(commands())
    == Ok(Command("continue_branch", "no_agent_timeout"))
}

pub fn time_before_the_answer_counts_toward_queue_limits_test() {
  let rt = runtime.new([], 20_000)
  run(doc.object([#("max_wait_time", doc.Int(10))]), rt)
  assert commands()
    == [
      Command("flush", ""),
      Command("continue_branch", "timeout"),
    ]
}

pub fn publication_failure_flushes_started_media_before_continuing_test() {
  let rt = runtime.new([EventAfter(0, answered())], 0)
  runtime.fail_publication()
  run(doc.object([#("greeting", doc.String("welcome"))]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("play", "welcome"),
      Command("member_call", ""),
      Command("flush", ""),
      Command("continue_branch", "no_agents"),
    ]
}

pub fn hangup_during_publication_settles_the_published_member_test() {
  let rt = runtime.new([EventAfter(0, answered())], 0)
  runtime.hangup_on_publication()
  run(doc.object([]), rt)
  assert list.map(runtime.publications(), fn(p) { p.0 })
    == ["member_call", "member_cancel"]
  assert list.last(commands()) == Ok(Command("stop", ""))
}

pub fn repeated_ringouts_keep_assigned_moh_and_connection_stops_restoration_test() {
  let offer = from_dispatcher("member_offer", [#("Offer-Timeout", doc.Int(10))])
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offer),
        EventAfter(10_000, complete("bridge", "answered", "NO_ANSWER")),
        EventAfter(0, offer),
        EventAfter(10_000, complete("bridge", "answered", "NO_ANSWER")),
        EventAfter(0, offer),
        EventAfter(100, from_dispatcher("member_connected", [])),
        // A late bridge completion must not queue music in the conversation.
        EventAfter(0, complete("bridge", "answered", "SUCCESS")),
        EventAfter(100, hangup()),
      ],
      0,
    )
  run(
    doc.object([
      #("moh", doc.String("assigned-music")),
      #("max_wait_time", doc.Int(0)),
      #("max_wait_time_with_no_agent", doc.Int(0)),
    ]),
    rt,
  )
  assert commands()
    == [
      Command("answer", "now"),
      Command("hold_queued", "assigned-music"),
      Command("member_call", ""),
      Command("hold_queued", "assigned-music"),
      Command("hold_queued", "assigned-music"),
      Command("stop", ""),
    ]
}

pub fn greeting_finishes_into_hold_after_publication_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(500, complete("noop", "answered", "")),
        EventAfter(0, hangup()),
      ],
      0,
    )
  run(
    doc.object([
      #("greeting", doc.String("welcome")),
      #("moh", doc.String("assigned-music")),
    ]),
    rt,
  )
  assert list.take(commands(), 4)
    == [
      Command("answer", "now"),
      Command("play", "welcome"),
      Command("member_call", ""),
      Command("hold_queued", "assigned-music"),
    ]
}

pub fn confirmation_at_total_deadline_cannot_extend_the_answer_budget_test() {
  let rt = runtime.new([EventAfter(10_000, answered())], 0)
  run(doc.object([]), rt)
  assert runtime.publications() == []
  assert list.last(commands()) == Ok(Command("continue_branch", "no_agents"))
  assert runtime.now_ms() == 10_000
}

pub fn confirmation_at_queue_deadline_does_not_admit_an_expired_caller_test() {
  let rt = runtime.new([EventAfter(3000, answered())], 0)
  run(doc.object([#("max_wait_time", doc.Int(3))]), rt)
  assert runtime.publications() == []
  assert list.last(commands()) == Ok(Command("continue_branch", "timeout"))
}

pub fn overdue_announcement_waits_for_answer_then_restores_hold_test() {
  let rt =
    runtime.new(
      [
        Check(no_dispatch_or_media),
        EventAfter(100, answered()),
        EventAfter(100, complete("noop", "answered", "")),
        EventAfter(0, hangup()),
      ],
      20_000,
    )
  run(
    doc.object([
      #(
        "announce",
        doc.object([
          #("interval", doc.Int(15)),
          #("media", doc.String("queue-update")),
        ]),
      ),
    ]),
    rt,
  )
  let names = list.map(commands(), fn(c) { c.name })
  assert names
    == [
      "answer",
      "hold_queued",
      "member_call",
      "audio_macro_interrupting",
      "hold_queued",
      "member_cancel",
      "stop",
    ]
}

//
// --- Leaving while the phones ring -------------------------------------------
//

fn offered(timeout: Int) -> doc.Value {
  from_dispatcher("member_offer", [#("Offer-Timeout", doc.Int(timeout))])
}

fn pressed(digit: String) -> doc.Value {
  event("call_event", "DTMF", [#("DTMF-Digit", doc.String(digit))])
}

/// The dispatcher took the caller out of a queue that was deleted.
fn queue_deleted() -> doc.Value {
  from_dispatcher("member_result", [
    #("Result", doc.String("queue_deleted")),
    #("Ended-Timestamp", doc.Int(101)),
  ])
}

/// A caller whose queue is deleted while they wait is told so by the
/// dispatcher, and leaves on `no_agents` -- the branch a queue that cannot
/// serve a caller takes -- with the hold flushed first. Nothing is
/// cancelled: the dispatcher settled them before it said so.
pub fn a_deleted_queue_sends_the_caller_on_to_no_agents_test() {
  let rt =
    runtime.new(
      [EventAfter(0, answered()), EventAfter(1000, queue_deleted())],
      0,
    )
  run(doc.object([]), rt)
  assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
  assert commands()
    == [
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
      Command("flush", ""),
      Command("continue_branch", "no_agents"),
    ]
}

/// One who hears it while an offer is still ringing, as far as it knows, has
/// the ring called off and waited for before moving on, as leaving for any
/// other reason does: the dispatcher calls it off too, and the next action
/// never runs inside a ring.
pub fn a_deleted_queue_during_a_ring_waits_for_the_ring_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, queue_deleted()),
        Check(last_command_is(Command("unbridge", ""))),
        EventAfter(50, ring_called_off()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
  assert list.drop(commands(), 3)
    == [
      Command("unbridge", ""),
      Command("flush", ""),
      Command("continue_branch", "no_agents"),
    ]
}

/// Any other result before a connection is the queue giving the caller up,
/// and a result after one is the end of a call already over: neither is a
/// deleted queue.
pub fn a_result_after_a_connection_is_not_a_deleted_queue_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, bridged_to_agent()),
        EventAfter(100, queue_deleted()),
        EventAfter(100, hangup()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.contains(commands(), Command("continue_branch", "no_agents"))
    == False
}

fn result(value: option.Option(String)) -> doc.Value {
  from_dispatcher("member_result", [
    #("Ended-Timestamp", doc.Int(101)),
    ..case value {
      Some(value) -> [#("Result", doc.String(value))]
      None -> []
    }
  ])
}

/// Every result but `queue_deleted` is the end of an offer that was
/// answered. One heard before the connection -- the caller's bridge and
/// `member_connected` missed, or overtaken -- finds a caller who is, or was,
/// with an agent: nothing is unbridged or flushed, whatever ring the action
/// thought was out, no callflow action runs, and the flow waits for the
/// channel to go.
pub fn an_answered_result_before_the_connection_leaves_the_bridge_alone_test() {
  let answered_results = [
    "completed",
    "agent_hangup",
    "caller_hangup",
    "failed",
    "transferred",
  ]
  list.each(answered_results, fn(value) {
    assert cf_callcenter.result_ending(Some(value)) == cf_callcenter.Answered
    list.each([[], [EventAfter(0, offered(20))]], fn(ring) {
      let rt =
        runtime.new(
          list.flatten([
            [EventAfter(0, answered())],
            ring,
            [
              EventAfter(1000, result(Some(value))),
              Check(last_command_is(Command("member_call", ""))),
              // Past the ring's ceiling: nothing is waiting on it.
              EventAfter(30_000, hangup()),
            ],
          ]),
          0,
        )
      run(doc.object([#("max_wait_time", doc.Int(5))]), rt)
      assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
      assert commands()
        == [
          Command("answer", "now"),
          Command("hold_queued", ""),
          Command("member_call", ""),
          Command("stop", ""),
        ]
    })
  })
}

/// A result this action does not know -- or none -- is the queue giving the
/// caller up. They leave as a caller who gives up does: a ring still going
/// called off and waited for, the hold flushed, and the callflow carried on
/// at its default child through the runtime, with nothing cancelled.
pub fn an_unknown_result_leaves_as_a_caller_who_gives_up_test() {
  list.each([Some("abandoned"), None], fn(value) {
    assert cf_callcenter.result_ending(value) == cf_callcenter.GivenUp

    let rt =
      runtime.new(
        [EventAfter(0, answered()), EventAfter(1000, result(value))],
        0,
      )
    run(doc.object([]), rt)
    assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
    assert list.drop(commands(), 3)
      == [Command("flush", ""), Command("continue_branch", "_")]

    let rt =
      runtime.new(
        [
          EventAfter(0, answered()),
          EventAfter(0, offered(20)),
          EventAfter(1000, result(value)),
          Check(last_command_is(Command("unbridge", ""))),
          EventAfter(50, ring_called_off()),
        ],
        0,
      )
    run(doc.object([]), rt)
    assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
    assert list.drop(commands(), 3)
      == [
        Command("unbridge", ""),
        Command("flush", ""),
        Command("continue_branch", "_"),
      ]
  })
  assert cf_callcenter.result_ending(Some("queue_deleted"))
    == cf_callcenter.Deleted
}

/// The caller's own bridge: an agent's phone took them.
fn bridged_to_agent() -> doc.Value {
  event("call_event", "CHANNEL_BRIDGE", [
    #("Other-Leg-Call-ID", doc.String("agent-leg")),
  ])
}

/// What the switch says when a ring was called off from the caller's side.
fn ring_called_off() -> doc.Value {
  complete("bridge", "answered", "ORIGINATOR_CANCEL")
}

fn last_command_is(expected: Command) -> fn() -> Nil {
  fn() {
    assert list.last(commands()) == Ok(expected)
    Nil
  }
}

/// An exit key pressed while an offer rings calls the ring off before the
/// caller goes anywhere: the cancel first, so the dispatcher lets the agents
/// go, then the unbridge, which the switch runs on the caller's channel and
/// which ends the ring with `ORIGINATOR_CANCEL`. Only once the ring is over
/// is the hold flushed and the next callflow action reached, so it never
/// runs inside a ring whose phones are still going.
pub fn an_exit_key_during_a_ring_calls_the_ring_off_first_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, pressed("#")),
        Check(last_command_is(Command("unbridge", ""))),
        EventAfter(50, ring_called_off()),
      ],
      0,
    )
  run(doc.object([#("exit_keys", doc.String("#"))]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
      Command("member_cancel", ""),
      Command("unbridge", ""),
      Command("flush", ""),
      Command("continue_branch", "exit_key"),
    ]
}

/// The channel writes the join made: the switch's own variables, which go on
/// the channel and nowhere else.
fn channel_writes() -> List(Command) {
  list.filter(channel.sent(), fn(c) { c.name == "set_channel_vars" })
}

/// The member message's copy of the call record the join left.
fn member_ccvs() -> doc.Value {
  let assert Ok(#(_, member)) =
    list.find(runtime.publications(), fn(p) { p.0 == "member_call" })
  let assert Ok(ccvs) = doc.get(member, ["Call", "Custom-Channel-Vars"])
  ccvs
}

fn a_caller(ccvs: List(#(String, doc.Value))) -> call.Call {
  call.from_value(
    doc.object([
      #("Account-ID", doc.String("account")),
      #("Call-ID", doc.String(caller_id)),
      #("Custom-Channel-Vars", doc.object(ccvs)),
    ]),
  )
}

fn join(queue: doc.Value, caller: call.Call) -> Nil {
  let rt = runtime.new([EventAfter(0, answered()), EventAfter(0, hangup())], 0)
  cf_callcenter.run(doc.object([]), caller, "queue", queue, None, 0, 100, rt)
}

/// The switch's ring reads the caller's keys only when their channel asks it
/// to, and one it does not read is published when the ring is over. An exit
/// key pressed half a second into a ring used to be heard only
/// when the ring timed out ten seconds later, and the dispatcher charged the
/// agent a miss. A queue with exit keys asks before the member goes out: the
/// switch's variable written on the channel alone, and the mark that says so
/// on the call record, which never carries the variable itself.
pub fn a_queue_with_exit_keys_asks_the_ring_to_read_keys_test() {
  join(doc.object([#("exit_keys", doc.String("#"))]), a_caller([]))
  assert channel_writes() == [Command("set_channel_vars", "")]
  let assert [Command("set_channel_vars", ""), ..after] =
    list.drop_while(channel.sent(), fn(c) { c.name != "set_channel_vars" })
  assert list.contains(after, Command("member_call", ""))
  let ccvs = member_ccvs()
  assert doc.get_string(ccvs, ["Queue-Ring-Reads-Keys"]) == Ok("true")
  assert doc.get(ccvs, ["Attended-Transfer-Cancel-Dial-Key"]) == Error(Nil)

  join(doc.object([]), a_caller([]))
  assert channel_writes() == []
  assert doc.get(member_ccvs(), ["Queue-Ring-Reads-Keys"]) == Error(Nil)
}

/// A channel that already asks -- a callflow run again while the phones
/// rang, a caller sent on from one queue with exit keys into another -- is
/// not written again: a ring still running on it keeps the value it read,
/// and a second write would free it under that ring.
pub fn a_channel_that_already_asks_is_not_written_again_test() {
  let asked = a_caller([#("Queue-Ring-Reads-Keys", doc.String("true"))])
  join(doc.object([#("exit_keys", doc.String("#"))]), asked)
  assert channel_writes() == []
}

/// No way out of the queue writes the ask again or takes it back: not an
/// exit key while the phones ring, not the wait running out, not a caller
/// who could not join. The channel sees the join's one write and no other,
/// and the call record handed on to the rest of the callflow still carries
/// the mark and never the variable.
pub fn no_way_out_touches_the_ring_keys_test() {
  let keys = doc.object([#("exit_keys", doc.String("#"))])
  let handed_on = fn(branch: String) {
    assert list.last(commands()) == Ok(Command("continue_branch", branch))
    assert channel_writes() == [Command("set_channel_vars", "")]
    let assert Ok(call) = runtime.continued_with()
    let ccvs = call.custom_channel_vars(call)
    assert doc.get_string(ccvs, ["Queue-Ring-Reads-Keys"]) == Ok("true")
    assert doc.get(ccvs, ["Attended-Transfer-Cancel-Dial-Key"]) == Error(Nil)
  }

  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(10)),
        EventAfter(500, pressed("#")),
        EventAfter(50, ring_called_off()),
      ],
      0,
    )
  run(keys, rt)
  handed_on("exit_key")

  let rt = runtime.new([EventAfter(0, answered())], 0)
  run(doc.set(keys, ["max_wait_time"], doc.Int(2)), rt)
  handed_on("timeout")

  let rt = runtime.new([EventAfter(0, answered())], 0)
  runtime.fail_publication()
  run(keys, rt)
  handed_on("no_agents")
}

/// `max_wait_time` running out while the phones ring is the same: the ring
/// is called off, and the caller takes the timeout branch once it is over.
pub fn the_wait_running_out_during_a_ring_calls_the_ring_off_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(5100, ring_called_off()),
      ],
      0,
    )
  run(doc.object([#("max_wait_time", doc.Int(5))]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
      Command("member_cancel", ""),
      Command("unbridge", ""),
      Command("flush", ""),
      Command("continue_branch", "timeout"),
    ]
  assert runtime.now_ms() == 5100
}

/// A ring whose end never comes back holds the caller for the ceiling and no
/// longer: they leave as they would have before the ring was called off.
pub fn a_ring_whose_end_is_not_heard_holds_the_caller_briefly_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, pressed("#")),
      ],
      0,
    )
  run(doc.object([#("exit_keys", doc.String("#"))]), rt)
  assert runtime.now_ms() == 6000
  assert list.drop(commands(), 4)
    == [
      Command("unbridge", ""),
      Command("flush", ""),
      Command("continue_branch", "exit_key"),
    ]
}

/// A caller who hangs up while their ring is being called off has nowhere
/// left to go: the flow stops.
pub fn a_caller_who_hangs_up_while_the_ring_is_called_off_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, pressed("#")),
        EventAfter(10, hangup()),
      ],
      0,
    )
  run(doc.object([#("exit_keys", doc.String("#"))]), rt)
  assert list.drop(commands(), 4)
    == [
      Command("unbridge", ""),
      Command("stop", ""),
    ]
}

/// With no ring going there is nothing to call off: an exit key after the
/// ring has come to nothing leaves as it always did.
pub fn an_exit_key_between_rings_leaves_at_once_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(20_000, complete("bridge", "answered", "NO_ANSWER")),
        EventAfter(100, pressed("#")),
      ],
      0,
    )
  run(doc.object([#("exit_keys", doc.String("#"))]), rt)
  assert list.contains(commands(), Command("unbridge", "")) == False
  assert list.drop(commands(), 4)
    == [
      Command("member_cancel", ""),
      Command("flush", ""),
      Command("continue_branch", "exit_key"),
    ]
}

/// The caller's own bridge is the connection, heard at once: an exit key or
/// `max_wait_time` falling due before `member_connected` arrives no longer
/// takes a caller out of a conversation, and no announcement is made into it.
pub fn the_callers_own_bridge_connects_them_at_once_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, bridged_to_agent()),
        EventAfter(100, pressed("#")),
        EventAfter(10_000, hangup()),
      ],
      0,
    )
  run(
    doc.object([
      #("exit_keys", doc.String("#")),
      #("max_wait_time", doc.Int(5)),
      #("announce", doc.object([#("interval", doc.Int(2))])),
    ]),
    rt,
  )
  assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
  assert commands()
    == [
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
      Command("stop", ""),
    ]
}

/// The caller's own bridge ended by the park of a call-off.
fn unbridged_from_agent() -> doc.Value {
  event("call_event", "CHANNEL_UNBRIDGE", [
    #("Other-Leg-Call-ID", doc.String("agent-leg")),
  ])
}

fn no_offer_out() -> doc.Value {
  from_dispatcher("member_position", [
    #("Position", doc.Int(1)),
    #("Waiting", doc.Int(1)),
    #("Agents-Available", doc.Int(1)),
    #("Offered", doc.Bool(False)),
  ])
}

/// An agent picked up as their release called the ring off: the caller's
/// bridge came and went -- the unbridge parked them in the middle of it --
/// and the dispatcher, which took no answer, says no offer is out for them.
/// They are waiting again: back on hold, the clocks running, and an exit
/// key works. The order the two arrive in does not matter.
pub fn a_bridge_the_call_off_cut_leaves_the_caller_waiting_test() {
  let orders = [
    [unbridged_from_agent(), no_offer_out()],
    [no_offer_out(), unbridged_from_agent()],
  ]
  list.each(orders, fn(order) {
    let rt =
      runtime.new(
        list.flatten([
          [
            EventAfter(0, answered()),
            EventAfter(0, offered(20)),
            EventAfter(1000, bridged_to_agent()),
          ],
          list.map(order, EventAfter(100, _)),
          [EventAfter(100, pressed("#"))],
        ]),
        0,
      )
    run(doc.object([#("exit_keys", doc.String("#"))]), rt)
    assert list.map(runtime.publications(), fn(p) { p.0 })
      == ["member_call", "member_cancel"]
    assert commands()
      == [
        Command("answer", "now"),
        Command("hold_queued", ""),
        Command("member_call", ""),
        Command("hold_queued", ""),
        Command("member_cancel", ""),
        Command("flush", ""),
        Command("continue_branch", "exit_key"),
      ]
  })
}

/// The same, with the queue deleted: the caller leaves on `no_agents`.
pub fn a_bridge_the_call_off_cut_leaves_a_deleted_queue_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, bridged_to_agent()),
        EventAfter(100, unbridged_from_agent()),
        EventAfter(100, queue_deleted()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
  assert list.drop(commands(), 3)
    == [Command("flush", ""), Command("continue_branch", "no_agents")]
}

/// Neither alone takes a caller out of a conversation: a position that was
/// on its way when the agent answered, with the bridge still up, or the end
/// of a bridge the dispatcher confirmed.
pub fn a_live_or_confirmed_bridge_is_not_left_test() {
  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, bridged_to_agent()),
        EventAfter(100, no_offer_out()),
        EventAfter(100, pressed("#")),
        EventAfter(10_000, hangup()),
      ],
      0,
    )
  run(doc.object([#("exit_keys", doc.String("#"))]), rt)
  assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
  assert list.drop(commands(), 3) == [Command("stop", "")]

  let rt =
    runtime.new(
      [
        EventAfter(0, answered()),
        EventAfter(0, offered(20)),
        EventAfter(1000, bridged_to_agent()),
        EventAfter(100, from_dispatcher("member_connected", [])),
        EventAfter(100, unbridged_from_agent()),
        EventAfter(100, no_offer_out()),
        EventAfter(100, queue_deleted()),
        EventAfter(1000, hangup()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.map(runtime.publications(), fn(p) { p.0 }) == ["member_call"]
  assert list.drop(commands(), 3) == [Command("stop", "")]
}

//
// --- A dispatcher of the release before ----------------------------------------
//

/// The holder of the account's shard said it sends to the controller queue:
/// nothing is listened on, and the message `cf_exe` relays is the one read.
pub fn a_holder_that_sends_to_the_controller_is_not_listened_for_test() {
  let rt =
    runtime.new(
      [EventAfter(0, answered()), EventAfter(1000, queue_deleted())],
      0,
    )
  run(doc.object([]), rt)
  assert commands()
    == [
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
      Command("flush", ""),
      Command("continue_branch", "no_agents"),
    ]
}

/// A holder that did not say so -- a node of the release before, whose
/// dispatcher publishes only on the exchange -- is listened for on the
/// caller's exchange key, from before the member message goes out until the
/// caller leaves, and what it says is heard there.
pub fn a_holder_of_the_release_before_is_heard_on_the_exchange_test() {
  let rt =
    runtime.new_listening(
      [
        EventAfter(0, answered()),
        EventAfter(1000, cf_callcenter.from_exchange(queue_deleted())),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert commands()
    == [
      Command("listen", caller_id),
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
      Command("stop_listening", ""),
      Command("flush", ""),
      Command("continue_branch", "no_agents"),
    ]
}

/// While the listener is up only what it relays counts: a dispatcher of this
/// release sends to the controller queue as well, and the same message read
/// twice would be a second offer restarting a ring that had ended. The
/// controller queue's copy is passed over, and the caller who hangs up has
/// the listener stopped with the flow.
pub fn only_the_listeners_copy_counts_while_it_listens_test() {
  let rt =
    runtime.new_listening(
      [
        EventAfter(0, answered()),
        EventAfter(1000, queue_deleted()),
        EventAfter(1000, hangup()),
      ],
      0,
    )
  run(doc.object([]), rt)
  assert list.map(runtime.publications(), fn(p) { p.0 })
    == ["member_call", "member_cancel"]
  assert commands()
    == [
      Command("listen", caller_id),
      Command("answer", "now"),
      Command("hold_queued", ""),
      Command("member_call", ""),
      Command("member_cancel", ""),
      Command("stop_listening", ""),
      Command("stop", ""),
    ]
}

/// Which answers mean which: `Caller-Delivery: controller` is a holder of
/// this release; an answer without it, or no answer at all, is listened for.
/// And what counts while listening, and while not.
pub fn where_the_dispatcher_is_heard_test() {
  let says = doc.object([#("Caller-Delivery", doc.String("controller"))])
  let silent = doc.object([#("Queues", doc.List([]))])
  assert cf_callcenter.delivery_of([says]) == cf_callcenter.ToController
  assert cf_callcenter.delivery_of([silent, says]) == cf_callcenter.ToController
  assert cf_callcenter.delivery_of([silent]) == cf_callcenter.OnExchange
  assert cf_callcenter.delivery_of([]) == cf_callcenter.OnExchange

  let position = from_dispatcher("member_position", [])
  assert cf_callcenter.heard_where_listening(False, position)
  assert !cf_callcenter.heard_where_listening(True, position)
  assert cf_callcenter.heard_where_listening(
    True,
    cf_callcenter.from_exchange(position),
  )
  assert cf_callcenter.heard_where_listening(True, hangup())
}
