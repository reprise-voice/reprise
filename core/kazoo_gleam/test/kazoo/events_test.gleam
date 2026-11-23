//// Call events: the accessors over an event as it arrives, the two shapes a
//// switch describes a channel in, and what all of it does with no release.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/amqp
import kazoo/doc
import kazoo/events.{CallId, CallIdPrefix, ChannelVar, Interest, OtherLeg}

/// A `CHANNEL_ANSWER` as `ecallmgr` publishes it, cut down to the fields
/// anything reads.
fn answered_event() -> doc.Value {
  doc.object([
    #("Event-Category", doc.String("call_event")),
    #("Event-Name", doc.String("CHANNEL_ANSWER")),
    #("Call-ID", doc.String("call-one")),
    #("Other-Leg-Call-ID", doc.String("call-two")),
    #("Timestamp", doc.Int(63_900_000_000)),
    #(
      "Custom-Channel-Vars",
      doc.object([
        #("Account-ID", doc.String("4b1f0c2d7e8a9b0c1d2e3f4051627384")),
        #("Owner-ID", doc.String("owner-one")),
        #("Authorizing-ID", doc.String("device-one")),
        #("Authorizing-Type", doc.String("device")),
        #("Callcenter-Queue-ID", doc.String("queue-one")),
      ]),
    ),
  ])
}

pub fn event_accessors_test() {
  let event = answered_event()

  assert events.event_name(event) == Some("CHANNEL_ANSWER")
  assert events.call_id(event) == Some("call-one")
  assert events.other_leg_call_id(event) == Some("call-two")
  assert events.account_id(event) == Some("4b1f0c2d7e8a9b0c1d2e3f4051627384")
  assert events.owner_id(event) == Some("owner-one")
  assert events.authorizing_id(event) == Some("device-one")
  assert events.authorizing_type(event) == Some("device")
  assert events.custom_channel_var(event, "Callcenter-Queue-ID")
    == Some("queue-one")
  assert events.timestamp(event) == Some(63_900_000_000)
  assert events.hangup_cause(event) == None
}

/// A hangup carries the cause; a field that is not there is `None` rather
/// than an empty string, so nothing has to guess what "" meant.
pub fn hangup_accessors_test() {
  let event =
    doc.object([
      #("Event-Name", doc.String("CHANNEL_DESTROY")),
      #("Call-ID", doc.String("call-one")),
      #("Hangup-Cause", doc.String("NORMAL_CLEARING")),
    ])

  assert events.event_name(event) == Some("CHANNEL_DESTROY")
  assert events.hangup_cause(event) == Some("NORMAL_CLEARING")
  assert events.account_id(event) == None
  assert events.owner_id(event) == None
  assert events.custom_channel_var(event, "Callcenter-Queue-ID") == None
  assert events.timestamp(event) == None
}

/// The shape the channel queries answer in: `ecallmgr_fs_channel:to_json/1`,
/// which is snake case and calls the call id `uuid`.
pub fn channel_from_query_test() {
  let channel =
    events.channel(
      doc.object([
        #("uuid", doc.String("call-one")),
        #("account_id", doc.String("4b1f0c2d7e8a9b0c1d2e3f4051627384")),
        #("owner_id", doc.String("owner-one")),
        #("authorizing_id", doc.String("device-one")),
        #("authorizing_type", doc.String("device")),
        #("other_leg", doc.String("call-two")),
        #("answered", doc.Bool(True)),
        #("bridge_id", doc.String("bridge-one")),
        #("node", doc.String("freeswitch@one.example.test")),
        #("elapsed_s", doc.Int(42)),
      ]),
    )

  assert channel.call_id == "call-one"
  assert channel.account_id == Some("4b1f0c2d7e8a9b0c1d2e3f4051627384")
  assert channel.owner_id == Some("owner-one")
  assert channel.authorizing_id == Some("device-one")
  assert channel.authorizing_type == Some("device")
  assert channel.other_leg == Some("call-two")
  assert channel.answered
  assert channel.bridge_id == Some("bridge-one")
  assert channel.media_node == Some("freeswitch@one.example.test")
  assert channel.elapsed_s == Some(42)
}

/// The shape a channel status answers in: the header case of the bus, with
/// the account and the owner under the channel variables.
pub fn channel_from_status_test() {
  let channel =
    events.channel(
      doc.object([
        #("Call-ID", doc.String("call-one")),
        #("Status", doc.String("active")),
        #("Switch-Nodename", doc.String("freeswitch@one.example.test")),
        #(
          "Custom-Channel-Vars",
          doc.object([
            #("Account-ID", doc.String("4b1f0c2d7e8a9b0c1d2e3f4051627384")),
            #("Owner-ID", doc.String("owner-one")),
          ]),
        ),
      ]),
    )

  assert channel.call_id == "call-one"
  assert channel.account_id == Some("4b1f0c2d7e8a9b0c1d2e3f4051627384")
  assert channel.owner_id == Some("owner-one")
  assert channel.media_node == Some("freeswitch@one.example.test")
  assert channel.answered == False
  assert channel.elapsed_s == None
  assert doc.get_string(channel.doc, ["Status"]) == Ok("active")
}

/// An answer with nothing in it is a channel with nothing in it, not a
/// crash: what a switch answers is not this library's to validate.
pub fn channel_from_nothing_test() {
  let channel = events.channel(doc.object([]))
  assert channel.call_id == ""
  assert channel.account_id == None
  assert channel.answered == False
}

// --- What a channel status says --------------------------------------------

/// A switch carrying the call answers `active` and says where it is.
fn active_status() -> doc.Value {
  doc.object([
    #("Call-ID", doc.String("call-one")),
    #("Status", doc.String("active")),
    #("Switch-Nodename", doc.String("freeswitch@one.example.test")),
  ])
}

/// A switch not carrying the call answers all the same, with `terminated`.
fn terminated_status() -> doc.Value {
  doc.object([
    #("Call-ID", doc.String("call-one")),
    #("Status", doc.String("terminated")),
    #("Error-Msg", doc.String("no node found with channel")),
  ])
}

/// Every `ecallmgr` answers a channel status, the ones without the call
/// saying so: two switches disowning a call, and nobody else to ask, is a
/// status with no channel in it, which is the call on no switch.
pub fn a_status_every_switch_disowns_is_empty_test() {
  assert events.status([terminated_status(), terminated_status()], True)
    == Ok([])
}

/// One switch carrying the call is that channel, whatever the others said
/// and whether or not the rest of them answered in time.
pub fn a_status_one_switch_carries_is_that_channel_test() {
  let assert Ok([channel]) =
    events.status([terminated_status(), active_status()], True)
  assert channel.call_id == "call-one"
  assert channel.media_node == Some("freeswitch@one.example.test")
  let assert Ok([late]) =
    events.status([terminated_status(), active_status()], False)
  assert late.call_id == "call-one"
}

/// A channel on a media node that is temporarily down is still a channel.
pub fn a_status_on_a_node_that_is_down_is_still_carried_test() {
  let assert Ok([channel]) =
    events.status(
      [active_status() |> doc.set(["Status"], doc.String("tmpdown"))],
      True,
    )
  assert channel.call_id == "call-one"
}

/// No answer at all is not an empty cluster. A query no switch heard --
/// consumers not yet rebound after the broker came back, or no `ecallmgr`
/// for `kz_nodes` to count -- is the cluster not answering, and nothing
/// that reads an empty status as "gone" is given one.
pub fn a_status_nobody_answered_is_no_answer_test() {
  assert events.status([], False) == Error(amqp.NoAnswer)
  assert events.status([], True) == Error(amqp.NoAnswer)
}

/// The switch carrying the call is slow, the others
/// say `terminated` in time, and the timeout ends the collection. That is
/// not the call on no switch -- the one that did not answer may be carrying
/// it -- and it must not read as `Ok([])`.
pub fn a_status_only_some_switches_disowned_is_no_answer_test() {
  assert events.status([terminated_status(), terminated_status()], False)
    == Error(amqp.NoAnswer)
}

/// Asked of every switch, the answer is only an answer once every switch
/// has given it: one carrying the call while another has not answered is
/// not enough to say what else is under that call id.
pub fn a_status_everywhere_needs_every_switch_test() {
  let assert Ok([channel]) =
    events.status_everywhere([terminated_status(), active_status()], True)
  assert channel.call_id == "call-one"
  assert events.status_everywhere([terminated_status()], True) == Ok([])
  assert events.status_everywhere([terminated_status(), active_status()], False)
    == Error(amqp.NoAnswer)
  assert events.status_everywhere([], True) == Error(amqp.NoAnswer)
  assert events.status_everywhere([], False) == Error(amqp.NoAnswer)
}

/// An account's channels say whether every switch answered: a query the
/// timeout ended is the channels of the switches that did, and not the
/// whole of what is up.
pub fn account_channels_say_whether_every_switch_answered_test() {
  let answer =
    doc.object([
      #("Channels", doc.List([doc.object([#("uuid", doc.String("call-one"))])])),
    ])
  let assert Ok(events.Channels([channel], complete: True)) =
    events.account_channels([answer], finished: True)
  assert channel.call_id == "call-one"
  let assert Ok(events.Channels([_], complete: False)) =
    events.account_channels([answer], finished: False)
  assert events.account_channels([], finished: False) == Error(amqp.NoAnswer)
  // Every switch answering with no channel is a finished collection with
  // their answers in it: no channels, and all of them.
  assert events.account_channels(
      [doc.object([#("Channels", doc.List([]))])],
      finished: True,
    )
    == Ok(events.Channels([], complete: True))
}

/// `kz_nodes` counting no `ecallmgr` -- a restart, a
/// zone that does not match -- finishes the collection at once with nothing
/// in it. That is nobody asked, as `status` has always read it, and not
/// every switch saying "no channels": read so, it wiped the channel table
/// and every agent on a call read idle and was offered a caller.
pub fn nobody_to_ask_is_no_answer_test() {
  assert events.account_channels([], finished: True) == Error(amqp.NoAnswer)
  assert events.status([], finished: True) == Error(amqp.NoAnswer)
  assert events.status_everywhere([], finished: True) == Error(amqp.NoAnswer)
}

pub fn subscribing_without_a_release_test() {
  assert events.on_call_events(
      account: events.all,
      event: events.all,
      handler: fn(_event) { Nil },
    )
    == Error("unavailable")
}

pub fn queries_without_a_release_test() {
  assert events.query_account_channels(
      app: "callcenter",
      account_id: "4b1f0c2d7e8a9b0c1d2e3f4051627384",
    )
    == Error(amqp.Unavailable)
  assert events.query_user_channels(app: "callcenter", authorizing_ids: [
      "device-one",
    ])
    == Error(amqp.Unavailable)
  assert events.channel_status(app: "callcenter", call_id: "call-one")
    == Error(amqp.Unavailable)
  assert events.channel_status_everywhere(
      app: "callcenter",
      call_id: "call-one",
    )
    == Error(amqp.Unavailable)
}

pub fn subscribing_to_an_interest_without_a_release_test() {
  assert events.subscribe(events.account(events.all), fn(_event) { Nil })
    == Error("unavailable")
  assert events.relay(events.account("acct"), to: process.self())
    == Error("unavailable")
}

// --- What an interest wants ------------------------------------------------

/// An event with the fields the filter reads, and enough of the rest.
fn channel_event(
  name: String,
  call_id: String,
  other_leg: String,
  ccvs: List(#(String, String)),
) -> doc.Value {
  doc.object([
    #("Event-Category", doc.String("call_event")),
    #("Event-Name", doc.String(name)),
    #("Call-ID", doc.String(call_id)),
    #("Other-Leg-Call-ID", doc.String(other_leg)),
    #(
      "Custom-Channel-Vars",
      doc.object(list.map(ccvs, fn(ccv) { #(ccv.0, doc.String(ccv.1)) })),
    ),
  ])
}

/// No names, no marks, no gate: everything, which is what `on_call_events`
/// has always been.
pub fn an_account_wants_everything_test() {
  let interest = events.account(events.all)
  assert events.wants(interest, channel_event("DTMF", "a", "", []))
  assert events.wants(interest, doc.object([]))
}

pub fn only_the_names_asked_for_test() {
  let interest =
    Interest(..events.account(events.all), events: [
      "CHANNEL_CREATE",
      "CHANNEL_DESTROY",
    ])
  assert events.wants(interest, channel_event("CHANNEL_CREATE", "a", "", []))
  assert events.wants(interest, channel_event("CHANNEL_DESTROY", "a", "", []))
  assert !events.wants(
    interest,
    channel_event("CHANNEL_EXECUTE_COMPLETE", "a", "", []),
  )
  assert !events.wants(interest, doc.object([]))
}

/// Any one mark is enough; none of them is not wanted.
pub fn one_of_the_marks_test() {
  let interest =
    Interest(..events.account("acct"), carrying: [
      CallId("caller"),
      OtherLeg("caller"),
      CallIdPrefix("c0ffee-"),
    ])
  let wants = fn(call_id, other_leg) {
    events.wants(
      interest,
      channel_event("CHANNEL_BRIDGE", call_id, other_leg, []),
    )
  }
  assert wants("caller", "")
  assert wants("leg", "caller")
  assert wants("c0ffee-2", "")
  assert !wants("c0ffee2-1", "")
  assert !wants("leg", "other")
  // An id the call's own starts with is not the call.
  assert !wants("call", "")
}

/// A channel variable is carried whatever its value, the empty one
/// included: the filter only has to let through at least what the handler
/// wants, and the handler decides what an empty one means.
pub fn a_channel_variable_is_carried_or_not_test() {
  let interest =
    Interest(..events.account(events.all), carrying: [
      ChannelVar("Owner-ID"),
      ChannelVar("Queue-ID"),
    ])
  assert events.wants(
    interest,
    channel_event("CHANNEL_CREATE", "a", "", [#("Owner-ID", "agent")]),
  )
  assert events.wants(
    interest,
    channel_event("CHANNEL_DESTROY", "a", "", [#("Queue-ID", "")]),
  )
  assert !events.wants(
    interest,
    channel_event("CHANNEL_CREATE", "a", "", [#("Account-ID", "acct")]),
  )
  let no_ccvs =
    doc.object([
      #("Event-Name", doc.String("CHANNEL_CREATE")),
      #("Call-ID", doc.String("a")),
    ])
  assert !events.wants(interest, no_ccvs)
  // A variable that is not a string is not one a channel carries.
  let numeric =
    doc.set(
      no_ccvs,
      ["Custom-Channel-Vars"],
      doc.object([#("Owner-ID", doc.Int(1))]),
    )
  assert !events.wants(interest, numeric)
}

/// A gate lets through the accounts open in it, and only while they are.
pub fn a_gate_opens_and_shuts_test() {
  let gate = events.new_gate()
  let interest = Interest(..events.account(events.all), gate: Some(gate))
  let event =
    channel_event("CHANNEL_CREATE", "a", "", [#("Account-ID", "acct")])
  assert !events.wants(interest, event)
  events.open(gate, "acct")
  assert events.wants(interest, event)
  assert !events.wants(
    interest,
    channel_event("CHANNEL_CREATE", "a", "", [#("Account-ID", "other")]),
  )
  assert !events.wants(interest, channel_event("CHANNEL_CREATE", "a", "", []))
  events.shut(gate, "acct")
  assert !events.wants(interest, event)
}

/// A gate whose owner has gone lets nothing through, rather than crashing
/// the handler for every event on the node.
pub fn a_gate_whose_owner_went_is_shut_test() {
  let made = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let gate = events.new_gate()
      events.open(gate, "acct")
      process.send(made, gate)
    })
  let assert Ok(gate) = process.receive(made, 1000)
  let monitor = process.monitor(owner)
  let assert Ok(_down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  let interest = Interest(..events.account(events.all), gate: Some(gate))
  assert !events.wants(
    interest,
    channel_event("CHANNEL_CREATE", "a", "", [#("Account-ID", "acct")]),
  )
}

// --- What it costs ---------------------------------------------------------

/// A channel event about the size `ecallmgr` publishes: sixty-odd headers
/// and a dozen channel variables.
fn full_event(
  name: String,
  account: String,
  call_id: String,
  owner: Option(String),
) -> doc.Value {
  let headers =
    upto(60)
    |> list.map(fn(n) {
      #("Header-" <> int.to_string(n), doc.String("value " <> int.to_string(n)))
    })
  let ccvs =
    upto(10)
    |> list.map(fn(n) {
      #(
        "Variable-" <> int.to_string(n),
        doc.String("value " <> int.to_string(n)),
      )
    })
  let ccvs = case owner {
    Some(owner) -> [#("Owner-ID", doc.String(owner)), ..ccvs]
    None -> ccvs
  }
  doc.object([
    #("Event-Category", doc.String("call_event")),
    #("Event-Name", doc.String(name)),
    #("Call-ID", doc.String(call_id)),
    #("Timestamp", doc.Int(63_900_000_000)),
    #(
      "Custom-Channel-Vars",
      doc.object([#("Account-ID", doc.String(account)), ..ccvs]),
    ),
    ..headers
  ])
}

/// What a node's event stream looks like to the call center: one event in
/// twenty is an agent's channel in an account this node dispatches for. The
/// rest are executes and their completions, carrier legs with no owner, and
/// channels of accounts dispatched elsewhere.
fn mix(count: Int) -> List(doc.Value) {
  upto(count)
  |> list.map(fn(n) {
    let call = "call-" <> int.to_string(n)
    case n % 20 {
      0 -> full_event("CHANNEL_CREATE", "held", call, Some("agent"))
      1 | 2 | 3 | 4 | 5 | 6 ->
        full_event("CHANNEL_EXECUTE", "held", call, Some("agent"))
      7 | 8 | 9 | 10 | 11 ->
        full_event("CHANNEL_EXECUTE_COMPLETE", "held", call, Some("agent"))
      12 | 13 | 14 | 15 -> full_event("CHANNEL_ANSWER", "held", call, None)
      _ -> full_event("CHANNEL_CREATE", "elsewhere", call, Some("agent"))
    }
  })
}

/// Hand the events to a handler `rounds` times: how many a second it got
/// through, and how many a round it passed on to `counted`.
fn measure(
  handler: events.Handler,
  raw: List(events.Raw),
  rounds: Int,
  counted: process.Subject(Nil),
) -> #(Int, Int) {
  let started = events.monotonic_us()
  list.each(upto(rounds), fn(_round) { events.deliver(handler, raw) })
  let took = int.max(events.monotonic_us() - started, 1)
  #(list.length(raw) * rounds * 1_000_000 / took, drain(counted, 0) / rounds)
}

fn drain(counted: process.Subject(Nil), count: Int) -> Int {
  case process.receive(counted, 0) {
    Ok(Nil) -> drain(counted, count + 1)
    Error(Nil) -> count
  }
}

/// Every event on the node became a document before anybody
/// looked at it. Measured over the same stream with the same handler behind
/// both -- the activity actor's test of whether an event is an agent's
/// channel in an account it holds -- first with nothing in front of it, as
/// `on_call_events` subscribes, then behind the interest activity
/// subscribes with.
///
/// In a release the names are bindings on the bus and the executes never
/// reach the handler at all, so this is the least of the difference.
pub fn a_filtered_subscription_costs_less_test() {
  let raw =
    mix(2000) |> list.map(fn(event) { events.from_json(doc.to_string(event)) })
  let counted = process.new_subject()
  let agent_channel = fn(event: doc.Value) {
    case
      events.account_id(event),
      events.owner_id(event),
      events.event_name(event)
    {
      Some("held"), Some(_owner), Some("CHANNEL_CREATE") ->
        process.send(counted, Nil)
      _, _, _ -> Nil
    }
  }
  let gate = events.new_gate()
  events.open(gate, "held")
  let interest =
    Interest(
      account: events.all,
      events: [
        "CHANNEL_CREATE",
        "CHANNEL_ANSWER",
        "CHANNEL_BRIDGE",
        "CHANNEL_DESTROY",
      ],
      carrying: [ChannelVar("Owner-ID"), ChannelVar("Queue-ID")],
      gate: Some(gate),
    )

  let everything = events.handler(events.account(events.all), agent_channel)
  let filtered = events.handler(interest, agent_channel)
  // Once each to warm up.
  let _ = measure(everything, raw, 1, counted)
  let _ = measure(filtered, raw, 1, counted)
  let #(before, passed_before) = measure(everything, raw, 5, counted)
  let #(after, passed_after) = measure(filtered, raw, 5, counted)

  io.println(
    "\nevents, one in twenty wanted: "
    <> int.to_string(before)
    <> "/s converting every one, "
    <> int.to_string(after)
    <> "/s filtering first",
  )
  // The handler is handed the same agent channels either way.
  assert passed_before == 100
  assert passed_after == 100
  assert after > before
}

/// One to `n`.
fn upto(n: Int) -> List(Int) {
  count_down(n, [])
}

fn count_down(n: Int, acc: List(Int)) -> List(Int) {
  case n < 1 {
    True -> acc
    False -> count_down(n - 1, [n, ..acc])
  }
}
