//// The shell around one call's core: what it hears turned into inputs, the
//// effects performed in order from the one process -- what they publish
//// handed to the call's publisher -- and the process gone when the call is
//// over. `Io` records instead of commanding a switch.

import callcenter/call/actor
import callcenter/call/core
import callcenter/call/originate
import callcenter/call/publishers
import callcenter/call/recovery
import callcenter/types.{type OfferId, type OfferReply}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/erlang/reference
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import kazoo/doc
import kazoo/events
import kazoo/testing/channel
import support/cluster
import support/flag

const call_id = "caller-leg"

const controller = "pid://<0.4242.0>/callflow_route_1"

/// What the actor did: an effect performed, or a call id bound.
type Did {
  Performed(core.Effect)
  Bound(String)
}

fn io(did: Subject(Did)) -> actor.Io {
  actor.Io(
    now: fn() { cluster.start_of_time },
    monotonic_ms: monotonic_ms,
    queue: fn(_account_id, _queue_id) {
      Ok(
        doc.object([
          #("greeting", doc.String("welcome")),
          #("moh", doc.String("support-hold")),
          #("caller_exit_key", doc.String("#")),
        ]),
      )
    },
    endpoints: fn(request: types.OfferRequest, prefix) {
      request.agents
      |> list.map(fn(agent) {
        doc.object([#("Invite-Format", doc.String("endpoint"))])
        |> originate.decorate(agent, request.settings)
      })
      |> originate.named_legs(prefix)
    },
    grace_s: 5,
    bind: fn(call) { process.send(did, Bound(call)) },
    survey: fn(_member) { recovery.nothing() },
    audit: fn(_call_ids) { [] },
    address: fn() { Some("pid://<0.1.0>/call_replies") },
    perform: fn(_context, effect) { process.send(did, Performed(effect)) },
    once_sent: fn(_call_id, _since, then) { then() },
    fresh: fn(_since) { True },
  )
}

fn member() -> types.Member {
  let member =
    cluster.member(call_id, "support", 0, cluster.start_of_time)
    |> cluster.with_control_queue("callctl-1")
  types.Member(
    ..member,
    call: doc.set(member.call, ["Controller-Queue"], doc.String(controller)),
    handoff_id: "handoff-1",
  )
}

fn request(
  replies: Subject(#(OfferId, OfferReply)),
  agents: List(String),
) -> types.OfferRequest {
  types.OfferRequest(
    member: member(),
    id: types.OfferId(call_id: call_id, serial: reference.new()),
    agents: agents,
    settings: types.OfferSettings(
      ring_timeout_s: 15,
      cid_prefix: None,
      record: False,
      outbound_caller_id_name: None,
      outbound_caller_id_number: None,
      hold_media: None,
    ),
    reply_to: replies,
    devices: None,
  )
}

/// Everything the actor did since the last look, oldest first.
fn done(did: Subject(Did)) -> List(Did) {
  // Every message to the actor is handled in order, so a round trip through
  // it is a barrier.
  process.sleep(50)
  drain(did, [])
}

fn drain(did: Subject(Did), acc: List(Did)) -> List(Did) {
  case process.receive(did, 0) {
    Ok(one) -> drain(did, [one, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn event(call: String, name: String, more: List(#(String, doc.Value))) {
  actor.Heard(
    doc.object([
      #("Event-Category", doc.String("call_event")),
      #("Event-Name", doc.String(name)),
      #("Call-ID", doc.String(call)),
      ..more
    ]),
  )
}

fn started(did: Subject(Did)) -> Subject(actor.Message) {
  let assert Ok(started) = actor.start(io(did), cluster.account_id, call_id, 0)
  started.data
}

/// The actor hears its caller from the moment it starts, and a caller who
/// joins hears the queue's greeting.
pub fn a_caller_joins_to_the_greeting_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let to = started(did)
  process.send(to, actor.Join(member(), False, replies))
  assert done(did) == [Bound(call_id), Performed(core.Play("welcome"))]
}

/// A ring is one originate for the offer, every leg heard from before it
/// can ring, and the dispatcher told the ring is out.
pub fn a_ring_binds_its_legs_and_originates_once_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let to = started(did)
  process.send(to, actor.Join(member(), False, replies))
  let _ = done(did)

  let ring = request(replies, ["ann", "bob"])
  let prefix = originate.leg_prefix(ring.id)
  process.send(to, actor.Ring(ring))
  let did = done(did)
  assert list.contains(did, Bound(prefix <> "-1"))
  assert list.contains(did, Bound(prefix <> "-2"))
  let performed =
    list.filter_map(did, fn(one) {
      case one {
        Performed(effect) -> Ok(effect)
        Bound(_) -> Error(Nil)
      }
    })
  let assert [core.Originate(offer, endpoints, 15), core.Tell(told, reply)] =
    performed
  assert offer == ring.id
  assert list.length(endpoints) == 2
  assert told == ring.id
  assert reply == types.OfferRinging(["ann", "bob"])
}

/// `ecallmgr`'s answer names the offer by the prefix it was sent under,
/// and a success names the leg that answered: the caller is marked with its
/// agent and the second, with the `noop` that shows the marks ran behind
/// them, and bridged to the leg once that `noop` has completed.
pub fn an_originate_answer_names_its_offer_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let to = started(did)
  process.send(to, actor.Join(member(), False, replies))
  let ring = request(replies, ["ann"])
  let prefix = originate.leg_prefix(ring.id)
  process.send(to, actor.Ring(ring))
  let _ = done(did)

  process.send(
    to,
    actor.Heard(
      doc.object([
        #("Event-Category", doc.String("resource")),
        #("Event-Name", doc.String("originate_resp")),
        #("Msg-ID", doc.String(prefix)),
        #("Application-Response", doc.String("SUCCESS")),
        #("Call-ID", doc.String(prefix <> "-1")),
      ]),
    ),
  )
  assert done(did)
    == [
      Performed(
        core.Mark([
          #("Agent-ID", doc.String("ann")),
          #("Queue-Answered-Timestamp", doc.Int(cluster.start_of_time)),
        ]),
      ),
      Performed(core.Confirm(core.marks_id(prefix <> "-1"))),
    ]

  process.send(
    to,
    event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("noop")),
      #("Application-Response", doc.String(core.marks_id(prefix <> "-1"))),
    ]),
  )
  assert done(did) == [Performed(core.Bridge(prefix <> "-1"))]
}

/// An exit key while the phones ring: the legs hung up, the shard told,
/// the channel marked and the barrier sent, in that order.
pub fn an_exit_key_during_a_ring_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let to = started(did)
  process.send(to, actor.Join(member(), False, replies))
  let ring = request(replies, ["ann"])
  let prefix = originate.leg_prefix(ring.id)
  process.send(to, actor.Ring(ring))
  let _ = done(did)

  process.send(to, event(call_id, "DTMF", [#("DTMF-Digit", doc.String("#"))]))
  assert done(did)
    == [
      Performed(core.HangUpLegs([prefix <> "-1"])),
      Performed(core.Left(types.ExitKey)),
      Performed(
        core.Mark([
          #(core.departing_var, doc.String("handoff-1")),
          #(core.departing_branch_var, doc.String("exit_key")),
        ]),
      ),
      Performed(core.Barrier("callcenter-departure-handoff-1")),
    ]
}

/// A caller who hangs up while waiting has left, and the actor has nothing
/// more to do: it ends.
pub fn the_actor_ends_with_the_call_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let to = started(did)
  let assert Ok(pid) = process.subject_owner(to)
  process.send(to, actor.Join(member(), False, replies))
  let _ = done(did)

  process.send(to, event(call_id, "CHANNEL_DESTROY", []))
  assert done(did) == [Performed(core.Left(types.Hangup))]
  assert !process.is_alive(pid)
}

/// An actor the node stood still since it started does nothing more for the
/// call: the caller's shard may be another node's by then, whose own actor
/// has the caller (`callcenter/stall`). What it is handed -- a ring, the
/// caller's own events, its wake-ups -- is dropped, and the switch, the
/// dispatcher and the shard hear nothing from it. It still stops when its
/// shard stops it.
pub fn an_actor_fenced_by_a_stall_does_nothing_more_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let stood_still = flag.new(False)
  let io = actor.Io(..io(did), fresh: fn(_since) { !flag.get(stood_still) })
  let assert Ok(started) = actor.start(io, cluster.account_id, call_id, 0)
  let to = started.data
  process.send(to, actor.Join(member(), False, replies))
  assert done(did) == [Bound(call_id), Performed(core.Play("welcome"))]

  flag.set(stood_still, True)
  process.send(to, actor.Ring(request(replies, ["ann"])))
  process.send(to, event(call_id, "CHANNEL_DESTROY", []))
  process.send(to, actor.Wake(0))
  assert done(did) == []
  assert process.receive(replies, 0) == Error(Nil)
  assert process.is_alive(started.pid)

  // Heard no more once it is fenced, even if the stall is forgotten.
  flag.set(stood_still, False)
  process.send(to, event(call_id, "CHANNEL_DESTROY", []))
  assert done(did) == []

  let stopped = process.new_subject()
  process.send(to, actor.Stop(stopped))
  assert process.receive(stopped, 1000) == Ok(Nil)
}

/// The callflow's answer to a hand-back is what ends the actor after a
/// departure.
pub fn the_callflows_answer_ends_a_departure_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let to = started(did)
  let assert Ok(pid) = process.subject_owner(to)
  process.send(to, actor.Join(member(), False, replies))
  process.send(to, event(call_id, "DTMF", [#("DTMF-Digit", doc.String("#"))]))
  process.send(
    to,
    event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("noop")),
      #("Application-Response", doc.String("callcenter-departure-handoff-1")),
    ]),
  )
  let did_so_far = done(did)
  assert list.last(did_so_far)
    == Ok(
      Performed(core.Continue(
        core.Handoff(
          id: "handoff-1",
          reply_to: controller,
          branches: doc.object([]),
        ),
        "exit_key",
      )),
    )

  process.send(
    to,
    actor.Heard(
      doc.object([
        #("Event-Category", doc.String("callcenter")),
        #("Event-Name", doc.String("member_continuing")),
        #("Call-ID", doc.String(call_id)),
        #("Handoff-ID", doc.String("handoff-1")),
      ]),
    ),
  )
  let _ = done(did)
  assert !process.is_alive(pid)
}

/// A caller handed over is found out about: the probe goes out, the survey
/// runs beside the actor, every leg it finds is heard from before the call
/// looks at it, and the dispatcher is told what was found once the probe
/// answers.
pub fn a_caller_handed_over_is_found_out_about_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let leg = "0a1b2c3d4e5f6a7b8c9d0e1f-1"
  let rows = [
    events.channel(
      doc.object([
        #("uuid", doc.String(call_id)),
        #("answered", doc.Bool(True)),
      ]),
    ),
    events.channel(
      doc.object([
        #("uuid", doc.String(leg)),
        #("other_leg", doc.String(leg)),
        #("answered", doc.Bool(False)),
        #(
          "custom_channel_vars",
          doc.object([
            #("Queue-Call-ID", doc.String(call_id)),
            #("Queue-Offer-ID", doc.String("0a1b2c3d4e5f6a7b8c9d0e1f")),
            #("Queue-Offer-Deadline", doc.Int(cluster.start_of_time + 20)),
            #("Agent-ID", doc.String("ann")),
          ]),
        ),
      ]),
    ),
  ]
  let io =
    actor.Io(..io(did), survey: fn(_member) {
      recovery.Survey(
        channels: Some(events.Channels(channels: rows, complete: True)),
        record: recovery.RecordRead(None),
      )
    })
  let assert Ok(started) = actor.start(io, cluster.account_id, call_id, 0)
  process.send(started.data, actor.Join(member(), True, replies))
  assert done(did)
    == [
      Bound(call_id),
      Performed(core.Probe(recovery.probe_id("handoff-1", 1))),
      Bound(leg),
    ]

  process.send(
    started.data,
    event(call_id, "CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("noop")),
      #("Application-Response", doc.String(recovery.probe_id("handoff-1", 1))),
    ]),
  )
  let assert [
    Performed(core.Hold(Some("support-hold"))),
    Performed(core.Present(
      Some(_offer),
      types.PresentRinging(["ann"], ceiling, False),
    )),
  ] = done(did)
  assert ceiling == cluster.start_of_time + 20
}

/// An actor started after `quarantine_after` crashes of the call's actors
/// hands the caller back whatever they join for.
pub fn a_quarantined_actor_hands_the_caller_back_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let assert Ok(started) =
    actor.start(io(did), cluster.account_id, call_id, actor.quarantine_after)
  process.send(started.data, actor.Join(member(), True, replies))
  let assert [
    Bound(_),
    Performed(core.Log(_)),
    Performed(core.Left(types.Quarantined)),
    Performed(core.Mark(_)),
    Performed(core.Barrier(_)),
  ] = done(did)
  Nil
}

/// A shard handed over asks its calls to be steady: a waiting caller's
/// actor answers at once, a ringing one once every leg has shown.
pub fn an_actor_says_when_its_call_is_steady_test() {
  let did = process.new_subject()
  let replies = process.new_subject()
  let to = started(did)
  process.send(to, actor.Join(member(), False, replies))
  let steady = process.new_subject()
  process.send(to, actor.Steady(steady))
  assert process.receive(steady, 1000) == Ok(Nil)

  let ring = request(replies, ["ann"])
  let prefix = originate.leg_prefix(ring.id)
  process.send(to, actor.Ring(ring))
  process.send(to, actor.Steady(steady))
  assert process.receive(steady, 100) == Error(Nil)
  process.send(to, event(prefix <> "-1", "CHANNEL_CREATE", []))
  assert process.receive(steady, 1000) == Ok(Nil)
}

// --- Publishing ---------------------------------------------------------------

/// A pool of `count` publishers under the test's own prefix, each recording
/// what it sends the caller (`kazoo/testing/channel`) from the moment it
/// asks for its channel, and telling `channels` that it asked.
fn recording_pool(
  label: String,
  count: Int,
  channels: Subject(Pid),
) -> publishers.Pool {
  let pool =
    publishers.Pool(
      prefix: "callcenter_test_actor_publishers_" <> label <> "_",
      count: count,
    )
  // The pool is linked to the test's process and goes with it.
  let assert Ok(_started) =
    publishers.start(
      pool,
      publishers.Io(
        channel: fn() {
          channel.record()
          process.send(channels, process.self())
          True
        },
        fresh: fn(_handed_at) { True },
      ),
    )
  pool
}

/// The node's `Io` as far as publishing goes: the effects performed by
/// `actor.perform` -- the real one -- through the pool, and recorded too.
fn io_through(did: Subject(Did), pool: publishers.Pool) -> actor.Io {
  actor.Io(
    ..io(did),
    perform: fn(context: actor.Context, effect) {
      process.send(did, Performed(effect))
      actor.perform(
        context,
        effect,
        fn(_member, _reason) { Nil },
        publishers.send(pool, context.call_id, context.since, _),
      )
    },
    once_sent: fn(call_id, since, then) {
      publishers.send(pool, call_id, since, then)
    },
  )
}

fn member_of(call: String) -> types.Member {
  let member = member()
  types.Member(
    ..member,
    call_id: call,
    call: doc.set(member.call, ["Call-ID"], doc.String(call)),
  )
}

/// What the call's publisher has sent the callers it serves, and which
/// process it is, asked behind everything the call handed it already.
fn sent_by_publisher_of(
  pool: publishers.Pool,
  call: String,
) -> #(Pid, List(channel.Command)) {
  let answer = process.new_subject()
  publishers.send(pool, call, 0, fn() {
    process.send(answer, #(process.self(), channel.sent()))
  })
  let assert Ok(sent) = process.receive(answer, 1000)
  sent
}

/// Two callers' actors command their callers from neither of their own
/// processes: the greeting each is played goes out from the publisher its
/// call hashes to, and the only channels asked for are the pool's.
pub fn an_actors_commands_go_out_from_its_calls_publisher_test() {
  let did = process.new_subject()
  let channels = process.new_subject()
  let pool = recording_pool("commands", 2, channels)
  let replies = process.new_subject()
  // One call on each publisher, so that both have been heard from.
  let calls =
    [0, 1]
    |> list.map(fn(index) {
      let assert Ok(call) =
        list.find(
          ["caller-0", "caller-1", "caller-2", "caller-3", "caller-4"],
          fn(call) { publishers.index(call, 2) == index },
        )
      call
    })
  let actors =
    list.map(calls, fn(call) {
      let assert Ok(started) =
        actor.start(io_through(did, pool), cluster.account_id, call, 0)
      process.send(started.data, actor.Join(member_of(call), False, replies))
      // Answered through the publisher, behind the greeting.
      let steady = process.new_subject()
      process.send(started.data, actor.Steady(steady))
      assert process.receive(steady, 1000) == Ok(Nil)
      started.pid
    })

  let publisher_pids =
    [0, 1]
    |> list.map(fn(index) {
      let assert Ok(pid) = process.named(publishers.name(pool, index))
      pid
    })
  list.each(calls, fn(call) {
    let #(pid, sent) = sent_by_publisher_of(pool, call)
    let assert Ok(own) =
      publisher_pids |> list.drop(publishers.index(call, 2)) |> list.first
    assert pid == own
    assert list.contains(sent, channel.Command("play", "welcome"))
  })
  let asked = drain_pids(channels, [])
  assert list.sort(asked, compare_pids)
    == list.sort(publisher_pids, compare_pids)
  assert list.all(actors, fn(actor_pid) { !list.contains(asked, actor_pid) })
}

/// A shard waiting for its calls to be steady hears from a waiting caller's
/// actor only once the call's publisher has sent what the actor handed it:
/// a publisher held up holds the answer up with it.
pub fn an_actor_is_steady_once_its_publisher_has_sent_everything_test() {
  let did = process.new_subject()
  let channels = process.new_subject()
  let pool = recording_pool("steady", 1, channels)
  let gate = process.new_subject()
  publishers.send(pool, "somebody-else", 0, fn() {
    let release = process.new_subject()
    process.send(gate, release)
    let _ = process.receive(release, 2000)
    Nil
  })
  let assert Ok(release) = process.receive(gate, 1000)

  let replies = process.new_subject()
  let assert Ok(started) =
    actor.start(io_through(did, pool), cluster.account_id, call_id, 0)
  process.send(started.data, actor.Join(member(), False, replies))
  let steady = process.new_subject()
  process.send(started.data, actor.Steady(steady))
  assert process.receive(steady, 100) == Error(Nil)

  process.send(release, Nil)
  assert process.receive(steady, 1000) == Ok(Nil)
  let #(_pid, sent) = sent_by_publisher_of(pool, call_id)
  assert sent == [channel.Command("play", "welcome")]
}

fn drain_pids(subject: Subject(Pid), acc: List(Pid)) -> List(Pid) {
  case process.receive(subject, 0) {
    Ok(one) -> drain_pids(subject, [one, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn compare_pids(a: Pid, b: Pid) -> order.Order {
  string.compare(string.inspect(a), string.inspect(b))
}

// --- What is heard ------------------------------------------------------------

pub fn what_is_heard_test() {
  assert actor.kind_of(
      doc.object([
        #("Event-Category", doc.String("resource")),
        #("Event-Name", doc.String("originate_resp")),
        #("Msg-ID", doc.String("abc")),
      ]),
    )
    == actor.OriginateAnswer("abc")
  // An error answer is an originate's answer too.
  assert actor.kind_of(
      doc.object([
        #("Event-Category", doc.String("error")),
        #("Event-Name", doc.String("originate_resp")),
        #("Msg-ID", doc.String("abc")),
      ]),
    )
    == actor.OriginateAnswer("abc")
  assert actor.kind_of(
      doc.object([
        #("Event-Category", doc.String("callcenter")),
        #("Event-Name", doc.String("member_continuing")),
        #("Handoff-ID", doc.String("h1")),
      ]),
    )
    == actor.ContinuingAnswer("h1")
  assert actor.kind_of(
      doc.object([
        #("Event-Category", doc.String("switch_event")),
        #("Event-Name", doc.String("reply")),
      ]),
    )
    == actor.CommandAnswer
  assert actor.kind_of(
      doc.object([
        #("Event-Category", doc.String("call_event")),
        #("Event-Name", doc.String("CHANNEL_ANSWER")),
      ]),
    )
    == actor.CallEvent
}

/// A caller resumed elsewhere goes on at the branch's own flow, or the
/// callflow's default child, and nowhere when there is neither.
pub fn the_flow_a_caller_is_resumed_at_test() {
  let voicemail = doc.object([#("module", doc.String("voicemail"))])
  let hangup = doc.object([#("module", doc.String("hangup"))])
  let branches = doc.object([#("exit_key", voicemail), #("_", hangup)])
  assert actor.resume_flow(branches, "exit_key") == Some(voicemail)
  assert actor.resume_flow(branches, "timeout") == Some(hangup)
  assert actor.resume_flow(doc.object([]), "timeout") == None

  // What is resumed marks the passage handed back before the branch runs.
  let handoff =
    core.Handoff(id: "handoff-1", reply_to: controller, branches: branches)
  assert actor.resumed_flow(handoff, "exit_key")
    == Some(
      doc.object([
        #("module", doc.String("callcenter_departed")),
        #("data", doc.object([#("handoff_id", doc.String("handoff-1"))])),
        #("children", doc.object([#("_", voicemail)])),
      ]),
    )
  assert actor.resumed_flow(
      core.Handoff(..handoff, branches: doc.object([])),
      "timeout",
    )
    == None
}

/// Where the callflow waits for a caller: the member's own passage id and
/// branches, and the Controller-Queue of the call.
pub fn the_handoff_is_the_members_test() {
  let handoff = actor.handoff(member())
  assert handoff.id == "handoff-1"
  assert handoff.reply_to == controller
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
