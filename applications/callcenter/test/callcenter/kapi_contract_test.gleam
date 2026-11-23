//// The Gleam half of the AMQP contract: the values the Gleam types turn into
//// are the values `kapi_callcenter` allows, and the messages the Gleam
//// producers build are messages its definitions accept.
////
//// A definition refuses what it does not allow, and the platform drops a
//// refused publish with a line in the log: a wire name that drifted from the
//// Erlang enum is a wallboard that stops updating and nothing else. So each
//// enumeration below is every constructor of its type, which the compiler
//// holds to (`every_*`), and each is checked in both directions.

import callcenter/agent_state
import callcenter/availability
import callcenter/breaks
import callcenter/member
import callcenter/records
import callcenter/types.{
  type Activity, type Availability, type CancelReason, type EndResult,
  AgentHangup, Answered, Available, AvailableOnDemand, CallerHangup, Completed,
  Ended, ExitKey, FailedBridge, Hangup, Idle, LoggedOut, NoAgentTimeout, OnBreak,
  OnCall, QueueDeleted, QueueFull, Ringing, Timeout, Transfer, Transferred,
  WrappingUp,
}
import callcenter_maintenance
import cf_callcenter
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake
import support/cluster

// --- Every constructor -------------------------------------------------------

fn every_result() -> List(EndResult) {
  // A constructor added to the type fails to compile here until it is listed.
  let _listed = fn(result: EndResult) {
    case result {
      Completed | AgentHangup | CallerHangup | FailedBridge | Transferred -> Nil
    }
  }
  [Completed, AgentHangup, CallerHangup, FailedBridge, Transferred]
}

fn every_reason() -> List(CancelReason) {
  let _listed = fn(reason: CancelReason) {
    case reason {
      Hangup
      | Timeout
      | NoAgentTimeout
      | ExitKey
      | QueueFull
      | Transfer
      | QueueDeleted -> Nil
    }
  }
  [Hangup, Timeout, NoAgentTimeout, ExitKey, QueueFull, Transfer, QueueDeleted]
}

fn every_availability() -> List(Availability) {
  let _listed = fn(availability: Availability) {
    case availability {
      LoggedOut | Available | AvailableOnDemand | OnBreak -> Nil
    }
  }
  [LoggedOut, Available, AvailableOnDemand, OnBreak]
}

fn every_source() -> List(availability.Source) {
  let _listed = fn(source: availability.Source) {
    case source {
      availability.Phone
      | availability.Ui
      | availability.Supervisor
      | availability.NoAnswerRule
      | availability.Dnd
      | availability.System -> Nil
    }
  }
  [
    availability.Phone,
    availability.Ui,
    availability.Supervisor,
    availability.NoAnswerRule,
    availability.Dnd,
    availability.System,
  ]
}

fn every_activity() -> List(Activity) {
  let _listed = fn(activity: Activity) {
    case activity {
      Idle | Ringing | OnCall(_) | WrappingUp -> Nil
    }
  }
  [
    Idle,
    Ringing,
    OnCall(queue_call: True),
    OnCall(queue_call: False),
    WrappingUp,
  ]
}

/// The same values, whatever order and however often.
fn same(left: List(String), right: List(String)) -> Bool {
  list.sort(list.unique(left), string.compare)
  == list.sort(list.unique(right), string.compare)
}

// --- The enumerations ----------------------------------------------------------

/// How a queue call ended: `Transferred` included, which the dispatcher
/// writes when an agent passes the caller on, and `queue_deleted`, the one
/// result of a caller nobody connected, spelled as the cancel reason is.
pub fn results_are_the_definitions_test() {
  let platform = platform_start()
  let values = allowed("member_result", "Result")
  platform_stop(platform)

  assert same(
    [
      records.reason_to_string(QueueDeleted),
      ..list.map(every_result(), records.result_to_string)
    ],
    values,
  )
  list.each(every_result(), fn(result) {
    assert records.result_from_string(records.result_to_string(result))
      == result
  })
}

/// Why a caller left: `Transfer` included, which a supervisor's pickup sent
/// before it became an offer and a node of that release may still send.
/// Both spellings of it -- the record's and the callflow action's -- are the
/// definition's.
pub fn cancel_reasons_are_the_definitions_test() {
  let platform = platform_start()
  let values = allowed("member_cancel", "Reason")
  platform_stop(platform)

  assert same(list.map(every_reason(), records.reason_to_string), values)
  assert same(list.map(every_reason(), cf_callcenter.reason_name), values)
  list.each(every_reason(), fn(reason) {
    assert records.reason_to_string(reason) == cf_callcenter.reason_name(reason)
    assert records.reason_from_string(records.reason_to_string(reason))
      == reason
  })
}

pub fn availabilities_are_the_definitions_test() {
  let platform = platform_start()
  let values = allowed("agent_availability", "Availability")
  let previous = allowed("agent_availability", "Previous")
  let sources = allowed("agent_availability", "Source")
  platform_stop(platform)

  assert same(list.map(every_availability(), availability.to_string), values)
  assert previous == values
  list.each(every_availability(), fn(value) {
    assert availability.parse(availability.to_string(value)) == Ok(value)
  })

  assert same(list.map(every_source(), availability.source_to_string), sources)
  list.each(every_source(), fn(source) {
    assert availability.parse_source(availability.source_to_string(source))
      == Ok(source)
  })
}

pub fn activities_are_the_definitions_test() {
  let platform = platform_start()
  let values = allowed("agent_activity", "Activity")
  platform_stop(platform)

  assert same(
    list.map(every_activity(), agent_state.activity_to_string),
    values,
  )
}

// --- The producers -------------------------------------------------------------

const account_id = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue_id = "37139638ff5b68f155d8445178524df1"

const call_id = "3c2a1f.9e@pbx.example.com"

/// What the callflow action sends to the shard's queue when a caller joins
/// and when one leaves, for every reason one can leave for.
pub fn the_callflow_actions_messages_are_the_definitions_test() {
  let platform = platform_start()
  let joined =
    cf_callcenter.member_call(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      call: doc.object([#("Call-ID", doc.String(call_id))]),
      node: "kazoo_apps@one",
      joined: 63_900_000_000,
      priority: 2,
      caller_id_name: Some("A Caller"),
      caller_id_number: None,
      shards: Some(64),
    )
  let joined_valid = valid("member_call", doc.to_string(joined))
  let left =
    list.map(every_reason(), fn(reason) {
      cf_callcenter.member_cancel(
        account_id: account_id,
        queue_id: queue_id,
        call_id: call_id,
        reason: reason,
        joined: 63_900_000_000,
        cancelled_at: 63_900_000_060,
      )
      |> doc.to_string
      |> valid("member_cancel", _)
    })
  platform_stop(platform)

  assert joined_valid
  assert list.all(left, fn(ok) { ok })
}

/// What the maintenance commands put on a shard's queue.
pub fn the_maintenance_messages_are_the_definitions_test() {
  let platform = platform_start()
  let joined =
    member.call_message(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      node: "kazoo_apps@one",
      joined_at: 63_900_000_000,
      priority: 0,
      call: member.stub_call(call_id, "kazoo_apps@one"),
    )
    |> doc.to_string
    |> valid("member_call", _)
  let left =
    callcenter_maintenance.cancel_member_message(
      account_id,
      call_id,
      "kazoo_apps@one",
      63_900_000_060,
    )
    |> doc.to_string
    |> valid("member_cancel", _)
  platform_stop(platform)

  assert joined
  assert left
}

/// A caller's whole passage through a dispatcher -- joining, being offered,
/// answered, the call ending, and a second caller hanging up while waiting --
/// with the broker standing in: every event the dispatcher publishes is one
/// its definition accepts, and each of them goes out.
pub fn every_dispatcher_event_is_the_definitions_test() {
  let platform = platform_start()
  let c =
    cluster.new(
      [
        #(
          "support",
          doc.object([
            #("pvt_type", doc.String("queue")),
            #("name", doc.String("Support")),
            #("strategy", doc.String("longest_idle")),
            #("agent_wrapup_time", doc.Int(10)),
            #(
              "agents",
              doc.List([
                doc.object([#("id", doc.String("ann"))]),
                doc.object([#("id", doc.String("bob"))]),
              ]),
            ),
          ]),
        ),
      ],
      [#("ann", agent()), #("bob", agent())],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  cluster.reply(c, "call-one", types.OfferRinging(["ann"]))
  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  cluster.reply(c, "call-one", Ended(Completed, cluster.start_of_time + 60))
  cluster.at(c, 61)
  cluster.arrive(c, "call-two", "support", 0, 61)
  let _ = cluster.cancel(c, "call-two", Hangup)
  let _ = cluster.report(c)
  let published = published_events()
  let rejected = rejected()
  platform_stop(platform)

  assert rejected == []
  list.each(
    [
      "member_position", "queue_stats", "member_offer", "agent_offer",
      "agent_answered", "member_connected", "member_result", "agent_wrapup",
    ],
    fn(event) {
      assert list.contains(published, #("exchange", event))
    },
  )
}

/// A caller taken out of a queue that was deleted is told so, at their
/// callflow and on the exchange, with a `member_result` whose result is
/// `queue_deleted` and which the definition accepts: the action leaves on
/// `no_agents` when it hears it, and a webhook sees the passage end.
pub fn a_deleted_queues_result_is_the_definitions_test() {
  let platform = platform_start()
  let c =
    cluster.new(
      [
        #(
          "support",
          doc.object([
            #("pvt_type", doc.String("queue")),
            #("name", doc.String("Support")),
            #("agents", doc.List([doc.object([#("id", doc.String("ann"))])])),
          ]),
        ),
      ],
      [#("ann", agent())],
    )
  let waiting = cluster.member("call-one", "support", 0, cluster.start_of_time)
  cluster.arrive_as(
    c,
    types.Member(
      ..waiting,
      call: doc.set(
        waiting.call,
        ["Controller-Queue"],
        doc.String("pid://<0.4242.0>/callflow_route_9f8e7d6c"),
      ),
    ),
  )
  cluster.put_queue(
    c,
    "support",
    doc.object([
      #("pvt_type", doc.String("queue")),
      #("pvt_deleted", doc.Bool(True)),
    ]),
  )
  cluster.tick(c)
  let results = published_values("member_result", "Result")
  let rejected = rejected()
  platform_stop(platform)

  assert rejected == []
  assert list.contains(results, #("exchange", "queue_deleted"))
  assert list.contains(results, #("caller", "queue_deleted"))
}

/// An availability change, from wherever it came.
pub fn an_availability_change_is_the_definitions_test() {
  let datastore = fake.new()
  fake.put_doc(
    datastore,
    kazoo.account_db(account_id),
    doc.object([
      #("_id", doc.String("ann")),
      #("pvt_type", doc.String("user")),
      #("call_center", doc.object([])),
    ]),
  )
  let kz = fake.kazoo(datastore)
  let platform = platform_start()
  let changes =
    list.map(every_source(), fn(source) {
      let _ =
        agent_state.set(kz, account_id, "ann", to: Available, source: source)
      let _ =
        agent_state.set(kz, account_id, "ann", to: OnBreak, source: source)
      Nil
    })
  let published = published_events()
  let rejected = rejected()
  platform_stop(platform)

  assert list.length(changes) == 6
  assert rejected == []
  assert list.count(published, fn(event) {
      event == #("exchange", "agent_availability")
    })
    == 12
}

/// A break with an end, and its end: both events are the definition's --
/// `Break-Ends` an integer on the first -- and the end says `system`.
pub fn a_break_and_its_end_are_the_definitions_test() {
  let datastore = fake.new()
  fake.put_doc(
    datastore,
    kazoo.account_db(account_id),
    doc.set(agent(), ["_id"], doc.String("ann")),
  )
  let kz = fake.kazoo(datastore)
  let platform = platform_start()
  let assert Ok(_) =
    agent_state.set(
      kz,
      account_id,
      "ann",
      to: Available,
      source: agent_state.ui,
    )
  let assert Ok(state) =
    agent_state.change(
      kz,
      account_id,
      "ann",
      to: OnBreak,
      source: agent_state.phone,
      break_s: 600,
    )
  let assert Some(ends) = state.break_ends
  let assert Ok(Some(_ended)) =
    breaks.end(kz, account_id, "ann", due: ends, now: ends)
  let sources = published_values("agent_availability", "Source")
  let rejected = rejected()
  platform_stop(platform)

  assert rejected == []
  assert sources
    == [#("exchange", "ui"), #("exchange", "phone"), #("exchange", "system")]
}

fn agent() -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object([])),
  ])
}

type Platform

@external(erlang, "platform_fakes", "start")
fn platform_start() -> Platform

@external(erlang, "platform_fakes", "stop")
fn platform_stop(platform: Platform) -> Nil

@external(erlang, "kapi_contract_ffi", "allowed")
fn allowed(event: String, header: String) -> List(String)

@external(erlang, "kapi_contract_ffi", "valid")
fn valid(event: String, json: String) -> Bool

@external(erlang, "kapi_contract_ffi", "published_events")
fn published_events() -> List(#(String, String))

@external(erlang, "kapi_contract_ffi", "published_values")
fn published_values(event: String, header: String) -> List(#(String, String))

@external(erlang, "kapi_contract_ffi", "rejected")
fn rejected() -> List(String)
