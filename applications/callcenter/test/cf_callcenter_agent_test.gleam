//// The `callcenter_agent` action: the action its data names, the agent it
//// finds, the change that lands in the availability document, and the order
//// it does those in on the channel.
////
//// There is no `cf_exe` under `gleam test` and no media server, so the
//// action is run through `run/3` against `kazoo/testing/fake` for the
//// documents and `kazoo/testing/channel` for the caller: the channel keeps
//// what was sent to it in order, and answers the digit collections with
//// whatever the test scripted.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/call
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/channel.{type Command, Command}
import kazoo/testing/fake.{type View, View}

import callcenter/agent_state
import callcenter/agents
import callcenter/feature_codes.{Break, Login, ToggleBreak, ToggleLogin}
import callcenter/records
import callcenter/types.{Available, LoggedOut, OnBreak}
import cf_callcenter_agent

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const jane = "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91"

/// A second agent, who never owns the phone in these tests: what a
/// hot-desking login is about is the agent who types, not the phone.
const mo = "a7c3e1d59b40f28c6e1a0b3d4f5c6a72"

/// An account administrator who is not an agent, with a phone of their own.
const boss = "c0ffee00c0ffee00c0ffee00c0ffee00"

/// The views this action reads: the agents keyed by the id they type, and
/// the agent listing, whose rows carry the presence id `*22<extension>`
/// looks up. Only users with a `call_center` object are in the listing, as
/// in `priv/couchdb/views/crossbar_agents.json`.
fn views() -> List(View) {
  [
    View(name: agents.by_agent_id, doc_type: "user", key: fn(user) {
      doc.get_string(user, ["call_center", "agent_id"])
      |> result.map(doc.String)
    }),
    fake.Valued(
      name: agents.listing,
      doc_type: "user",
      key: fn(user) {
        case agents.is_agent(user) {
          True -> doc.get_string(user, ["_id"]) |> result.map(doc.String)
          False -> Error(Nil)
        }
      },
      value: fn(user) {
        doc.object([
          #("id", doc.get(user, ["_id"]) |> result.unwrap(doc.Null)),
          #(
            "presence_id",
            doc.get(user, ["presence_id"]) |> result.unwrap(doc.Null),
          ),
        ])
      },
    ),
  ]
}

fn an_account() -> fake.Fake {
  let f = fake.new_with_views(views())
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(jane)),
      #("pvt_type", doc.String("user")),
      #("username", doc.String("jane")),
      #("first_name", doc.String("Jane")),
      #("presence_id", doc.String("101")),
      #("priv_level", doc.String("user")),
      #("enabled", doc.Bool(True)),
      #(
        "call_center",
        doc.object([
          #("agent_id", doc.String("1001")),
          #("pin", doc.String("4321")),
        ]),
      ),
    ]),
  )
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(mo)),
      #("pvt_type", doc.String("user")),
      #("username", doc.String("mo")),
      #("first_name", doc.String("Mo")),
      #("presence_id", doc.String("102")),
      #("enabled", doc.Bool(True)),
      #(
        "call_center",
        doc.object([
          #("agent_id", doc.String("1002")),
          #("pin", doc.String("5678")),
        ]),
      ),
    ]),
  )
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(boss)),
      #("pvt_type", doc.String("user")),
      #("username", doc.String("boss")),
      #("presence_id", doc.String("100")),
      #("priv_level", doc.String("admin")),
      #("enabled", doc.Bool(True)),
    ]),
  )
  f
}

pub fn action_from_data_test() {
  assert cf_callcenter_agent.action(
      doc.object([#("action", doc.String("toggle_login"))]),
    )
    == Ok(ToggleLogin)
  assert cf_callcenter_agent.action(
      doc.object([#("action", doc.String("toggle_break"))]),
    )
    == Ok(ToggleBreak)
  assert cf_callcenter_agent.action(
      doc.object([#("action", doc.String("login"))]),
    )
    == Ok(Login)

  // A callflow written past the validator names nothing this action does.
  assert cf_callcenter_agent.action(doc.object([])) == Error(Nil)
  assert cf_callcenter_agent.action(
      doc.object([#("action", doc.String("unpause"))]),
    )
    == Error(Nil)
}

/// `*23` finds the agent by the id they type, not by their user id.
pub fn lookup_by_agent_id_test() {
  let kz = fake.kazoo(an_account())
  let assert Ok(user) = agents.by_id(kz, account, "1001")
  assert doc.get_string(user, ["_id"]) == Ok(jane)
  assert agents.pin(user) == Some("4321")
  assert agents.agent_id(user) == Some("1001")

  assert agents.by_id(kz, account, "9999") == Error(kazoo.NotFound)
}

/// An agent with no PIN cannot be logged in from a phone that is not theirs;
/// their own phone still works, because that path never asks.
pub fn agent_without_a_pin_test() {
  let f = fake.new_with_views(views())
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(jane)),
      #("pvt_type", doc.String("user")),
      #("call_center", doc.object([#("agent_id", doc.String("1001"))])),
    ]),
  )
  let kz = fake.kazoo(f)
  let assert Ok(user) = agents.by_id(kz, account, "1001")
  assert agents.pin(user) == None
}

/// The whole of `*22` twice over: in, then out, through the same code.
pub fn toggle_login_writes_the_document_test() {
  let kz = fake.kazoo(an_account())

  let assert Ok(before) = agent_state.get(kz, account, jane)
  assert before.availability == LoggedOut

  let outcome =
    feature_codes.apply(
      ToggleLogin,
      current: before.availability,
      previous: before.previous,
    )
  let assert Some(to) = feature_codes.changed_to(outcome)
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: to, source: agent_state.phone)
  assert agent_state.availability_of(kz, account, jane) == Available

  let assert Ok(now) = agent_state.get(kz, account, jane)
  let again =
    feature_codes.apply(
      ToggleLogin,
      current: now.availability,
      previous: now.previous,
    )
  let assert Some(back) = feature_codes.changed_to(again)
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: back, source: agent_state.phone)
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}

/// `*24` after `*22`: the break remembers what it interrupted.
pub fn break_then_resume_test() {
  let kz = fake.kazoo(an_account())
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.phone)

  let assert Ok(working) = agent_state.get(kz, account, jane)
  let assert Some(paused) =
    feature_codes.changed_to(feature_codes.apply(
      Break,
      current: working.availability,
      previous: working.previous,
    ))
  assert paused == OnBreak
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: paused, source: agent_state.phone)

  let assert Ok(on_break) = agent_state.get(kz, account, jane)
  assert on_break.previous == Some(Available)
  let assert Some(resumed) =
    feature_codes.changed_to(feature_codes.apply(
      ToggleBreak,
      current: on_break.availability,
      previous: on_break.previous,
    ))
  assert resumed == Available
}

/// A change made from a phone says so, which is what the status log and the
/// supervisor screen read to tell it from one made in the UI.
pub fn the_source_is_the_phone_test() {
  let kz = fake.kazoo(an_account())
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.phone)
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert agent_state.source_to_string(state.source) == "phone"
}

//
// --- The channel -----------------------------------------------------------
//
// Every path through the action ends by saying what happened and then
// ending the callflow, and the ending hangs the channel up. So the prompt
// has to be one the action waits for the end of: a prompt merely queued
// behind `callflow.stop` is torn down a few milliseconds after it starts and
// the agent hears silence.
//

/// The action's data, as a callflow node carries it.
fn node(action: String) -> doc.Value {
  doc.object([#("action", doc.String(action))])
}

/// The same node with `require_pin`, which is what `*23`'s callflow carries.
fn asking_node(action: String) -> doc.Value {
  doc.object([
    #("action", doc.String(action)),
    #("require_pin", doc.Bool(True)),
  ])
}

/// A call from the agent's own phone, which carries their user id.
fn own_phone() -> call.Call {
  a_call(Some(jane))
}

/// A call from a phone that belongs to nobody, which is what `*23` is for.
fn somebody_elses_phone() -> call.Call {
  a_call(None)
}

fn a_call(owner: Option(String)) -> call.Call {
  let owned = case owner {
    Some(id) -> [#("Owner-ID", doc.String(id))]
    None -> []
  }
  call.from_value(
    doc.object([
      #("Call-ID", doc.String("2f4a6c8e-1b3d-5f70")),
      #("Account-ID", doc.String(account)),
      #("Account-DB", doc.String(kazoo.account_db(account))),
      ..owned
    ]),
  )
}

/// Start recording a channel that plays what it is asked to. A prompt is
/// the only thing this action waits for and no path plays more than one, so
/// two is a spare.
fn a_working_channel() -> Nil {
  channel.record()
  channel.play_results([channel.Heard, channel.Heard])
}

/// Whether the availability document exists at all, which is the whole of
/// "did the action write anything".
fn was_written(f: fake.Fake) -> Bool {
  was_written_for(f, jane)
}

fn was_written_for(f: fake.Fake, agent_id: String) -> Bool {
  case
    fake.lookup(
      f,
      kazoo.account_db(account),
      records.agent_document_id(agent_id),
    )
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// `*22` from the agent's own phone: answer, say what they now are, end.
/// The prompt is the waited-for kind, and the flow ends only after it.
pub fn the_prompt_is_heard_before_the_flow_ends_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()

  cf_callcenter_agent.run(kz, node("toggle_login"), own_phone())

  assert agent_state.availability_of(kz, account, jane) == Available
  // A login writes the document, which is what makes the "nothing was
  // written" of an abandoned call below mean something.
  assert was_written(f)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_wait", feature_codes.logged_in_prompt),
      Command("stop", ""),
    ]
}

/// The same for the break, whose prompt is the one that still has to be
/// recorded: the action waits for it either way, so recording it is all that
/// is left to do.
pub fn a_break_waits_for_its_prompt_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.phone)
  a_working_channel()

  cf_callcenter_agent.run(kz, node("toggle_break"), own_phone())

  assert agent_state.availability_of(kz, account, jane) == OnBreak
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_wait", feature_codes.on_break_prompt),
      Command("stop", ""),
    ]
}

/// The node's `timeout`: seconds, and 0 for none, missing, or below 1.
pub fn the_break_timeout_is_the_nodes_test() {
  let with = fn(timeout) {
    doc.object([
      #("action", doc.String("toggle_break")),
      #("timeout", timeout),
    ])
  }
  assert cf_callcenter_agent.break_timeout(with(doc.Int(900))) == 900
  assert cf_callcenter_agent.break_timeout(with(doc.Int(0))) == 0
  assert cf_callcenter_agent.break_timeout(with(doc.Int(-5))) == 0
  assert cf_callcenter_agent.break_timeout(node("toggle_break")) == 0
}

/// `*24` on a node with a `timeout` starts a break that ends by itself: its
/// end is on the document. The resume by `*24` takes it away again.
pub fn a_break_from_a_node_with_a_timeout_has_an_end_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.phone)
  let timed =
    doc.object([
      #("action", doc.String("toggle_break")),
      #("timeout", doc.Int(900)),
    ])
  a_working_channel()

  cf_callcenter_agent.run(kz, timed, own_phone())

  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == OnBreak
  assert state.break_ends == Some(state.timestamp + 900)

  a_working_channel()
  cf_callcenter_agent.run(kz, timed, own_phone())
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == Available
  assert state.break_ends == None
}

/// A refusal is a prompt too, and it is the last thing the caller hears, so
/// it waits like the rest. A callflow node naming an action this module does
/// not have is the shortest way to one.
pub fn a_refusal_waits_for_its_prompt_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()

  cf_callcenter_agent.run(kz, node("unpause"), own_phone())

  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_wait", feature_codes.invalid_prompt),
      Command("stop", ""),
    ]
}

/// Said as a rule rather than as three transcripts: whatever any path says
/// last, it waited for it, and the flow ended after it and not before.
pub fn every_path_waits_before_it_ends_test() {
  let runs = [
    #(node("toggle_login"), own_phone()),
    #(node("logout"), own_phone()),
    #(node("break"), own_phone()),
    #(node("resume"), own_phone()),
    #(node("unpause"), own_phone()),
    #(node("toggle_login"), somebody_elses_phone()),
  ]
  list.each(runs, fn(run) {
    let kz = fake.kazoo(an_account())
    a_working_channel()
    cf_callcenter_agent.run(kz, run.0, run.1)

    let assert [spoken, ending] = last_two(channel.sent())
    assert channel.waits_for_the_channel(spoken)
    assert channel.is_an_ending(ending)
  })
}

fn last_two(sent: List(Command)) -> List(Command) {
  list.drop(sent, list.length(sent) - 2)
}

//
// --- `*23` from a phone with no owner --------------------------------------
//
// The only path that asks anything. What the caller types is scripted; a
// caller who hangs up mid-exchange must leave the availability exactly as it
// was, because an abandoned login is not a login.
//

/// The whole exchange: the id, then the PIN, then the change.
pub fn the_id_and_pin_exchange_logs_the_agent_in_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()
  channel.collect_answers([channel.Typed("1001"), channel.Typed("4321")])

  cf_callcenter_agent.run(kz, node("toggle_login"), somebody_elses_phone())

  assert agent_state.availability_of(kz, account, jane) == Available
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_collect_digits", feature_codes.enter_id_prompt),
      Command("prompt_and_collect_digits", feature_codes.enter_pin_prompt),
      Command("prompt_and_wait", feature_codes.logged_in_prompt),
      Command("stop", ""),
    ]
}

/// Hanging up while the id is being asked for changes nothing: the
/// availability document is never written, so the agent is not logged in and
/// their previous value is not disturbed either.
///
/// And nothing more is said. The flow relays one `CHANNEL_DESTROY` to this
/// process and the collection has already taken it, so a prompt sent now
/// would be waited on until the wait ran out, holding the flow, this process
/// and their bindings open for a minute over a caller who is not there. The
/// action ends instead.
pub fn a_call_abandoned_at_the_id_changes_nothing_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  channel.collect_answers([channel.CallerHungUp])

  cf_callcenter_agent.run(kz, node("toggle_login"), somebody_elses_phone())

  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert !was_written(f)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_collect_digits", feature_codes.enter_id_prompt),
      Command("stop", ""),
    ]
}

/// And hanging up after the id, while the PIN is being asked for: the agent
/// has been found by then, which is the point at which a login that wrote
/// early would have written.
pub fn a_call_abandoned_at_the_pin_changes_nothing_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  channel.collect_answers([channel.Typed("1001"), channel.CallerHungUp])

  cf_callcenter_agent.run(kz, node("toggle_login"), somebody_elses_phone())

  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert !was_written(f)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_collect_digits", feature_codes.enter_id_prompt),
      Command("prompt_and_collect_digits", feature_codes.enter_pin_prompt),
      Command("stop", ""),
    ]
}

/// A caller who stays on the line, by contrast, is told: they are there to
/// hear it, so the refusal is spoken and waited for like any other prompt.
pub fn a_caller_who_is_still_there_is_told_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()
  channel.collect_answers([channel.NothingTyped])

  cf_callcenter_agent.run(kz, node("toggle_login"), somebody_elses_phone())

  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_collect_digits", feature_codes.enter_id_prompt),
      Command("prompt_and_wait", feature_codes.invalid_prompt),
      Command("stop", ""),
    ]
}

/// A caller who stays on the line and types nothing is the same answer.
pub fn a_silent_caller_changes_nothing_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  channel.collect_answers([channel.NothingTyped])

  cf_callcenter_agent.run(kz, node("toggle_login"), somebody_elses_phone())

  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert !was_written(f)
}

/// So does the wrong PIN, which is the one that must not be a login however
/// many times it is tried.
pub fn a_wrong_pin_changes_nothing_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  channel.collect_answers([channel.Typed("1001"), channel.Typed("0000")])

  cf_callcenter_agent.run(kz, node("toggle_login"), somebody_elses_phone())

  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert !was_written(f)
}

/// From the agent's own phone the exchange never happens: the call carries
/// their user id, so `*23` asks nothing and behaves exactly as `*22` does.
/// This is the module's documented behaviour, recorded here so that a change
/// to it is a deliberate one.
pub fn an_owned_phone_is_never_asked_for_a_pin_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()

  cf_callcenter_agent.run(kz, node("toggle_login"), own_phone())

  assert agent_state.availability_of(kz, account, jane) == Available
  assert !list.any(channel.sent(), fn(command) {
    command.name == "prompt_and_collect_digits"
  })
}

/// A caller who hangs up while the prompt is playing has heard what they
/// were going to hear. The change stands -- it was written before the
/// prompt -- and the flow ends without waiting for anything else.
pub fn a_caller_who_goes_mid_prompt_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  channel.record()
  channel.play_results([channel.GoneBeforeTheEnd])

  cf_callcenter_agent.run(kz, node("toggle_login"), own_phone())

  assert agent_state.availability_of(kz, account, jane) == Available
  assert was_written(f)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_wait", feature_codes.logged_in_prompt),
      Command("stop", ""),
    ]
}

/// A prompt the switch never plays -- the missing `agent-on_break` is the
/// one this actually happens to -- ends the same way. The break has been
/// written either way; only the saying of it is lost.
pub fn a_prompt_that_never_plays_test() {
  let kz = fake.kazoo(an_account())
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.phone)
  channel.record()
  channel.play_results([channel.NotPlayed])

  cf_callcenter_agent.run(kz, node("toggle_break"), own_phone())

  assert agent_state.availability_of(kz, account, jane) == OnBreak
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_wait", feature_codes.on_break_prompt),
      Command("stop", ""),
    ]
}

//
// --- `require_pin`: `*23` from a phone that has an owner --------------------
//
// The flag is the difference between `*23` and a second `*22`. Without it an
// owned phone decides who logs in; with it the agent who types the id and
// the PIN does, whoever the phone belongs to.
//

pub fn require_pin_is_off_unless_the_node_says_so_test() {
  assert !cf_callcenter_agent.require_pin(node("toggle_login"))
  assert cf_callcenter_agent.require_pin(asking_node("toggle_login"))
  assert !cf_callcenter_agent.require_pin(
    doc.object([
      #("action", doc.String("toggle_login")),
      #("require_pin", doc.Bool(False)),
    ]),
  )
}

/// Requirement 2.11, and the decision this flag records: the agent who types
/// is the agent logged in. Jane's phone, Mo's id and PIN, Mo logged in --
/// and Jane, who owns the phone and did not ask for anything, left alone.
pub fn require_pin_logs_in_the_agent_who_typed_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  channel.collect_answers([channel.Typed("1002"), channel.Typed("5678")])

  cf_callcenter_agent.run(kz, asking_node("toggle_login"), own_phone())

  assert agent_state.availability_of(kz, account, mo) == Available
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert !was_written_for(f, jane)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_collect_digits", feature_codes.enter_id_prompt),
      Command("prompt_and_collect_digits", feature_codes.enter_pin_prompt),
      Command("prompt_and_wait", feature_codes.logged_in_prompt),
      Command("stop", ""),
    ]
}

/// The owner's own id and PIN are asked for like anybody else's, and work
/// like anybody else's.
pub fn require_pin_asks_the_owner_too_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()
  channel.collect_answers([channel.Typed("1001"), channel.Typed("4321")])

  cf_callcenter_agent.run(kz, asking_node("toggle_login"), own_phone())

  assert agent_state.availability_of(kz, account, jane) == Available
}

/// A wrong PIN is refused from an owned phone exactly as it is from a shared
/// one: nobody is logged in, least of all the phone's owner.
pub fn a_wrong_pin_from_an_owned_phone_changes_nothing_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  channel.collect_answers([channel.Typed("1002"), channel.Typed("0000")])

  cf_callcenter_agent.run(kz, asking_node("toggle_login"), own_phone())

  assert agent_state.availability_of(kz, account, mo) == LoggedOut
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert !was_written_for(f, mo)
  assert !was_written_for(f, jane)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_collect_digits", feature_codes.enter_id_prompt),
      Command("prompt_and_collect_digits", feature_codes.enter_pin_prompt),
      Command("prompt_and_wait", feature_codes.invalid_prompt),
      Command("stop", ""),
    ]
}

/// And an abandoned exchange leaves both of them alone. This is the one the
/// flag exists for: before it, dialling `*23` at your own desk and hanging
/// up logged you in.
pub fn an_abandoned_exchange_from_an_owned_phone_changes_nothing_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  channel.collect_answers([channel.CallerHungUp])

  cf_callcenter_agent.run(kz, asking_node("toggle_login"), own_phone())

  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert !was_written_for(f, jane)
  assert !was_written_for(f, mo)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_collect_digits", feature_codes.enter_id_prompt),
      Command("stop", ""),
    ]
}

/// The flag written out as false is the flag left out: `*22` and `*24` keep
/// taking the call's own user and asking nothing.
pub fn require_pin_false_takes_the_owner_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()

  cf_callcenter_agent.run(
    kz,
    doc.object([
      #("action", doc.String("toggle_login")),
      #("require_pin", doc.Bool(False)),
    ]),
    own_phone(),
  )

  assert agent_state.availability_of(kz, account, jane) == Available
  assert !list.any(channel.sent(), fn(command) {
    command.name == "prompt_and_collect_digits"
  })
}

/// A phone with no owner asks whether the flag is there or not, so `*23`
/// from a lobby phone is the same exchange it always was.
pub fn a_phone_with_no_owner_is_asked_with_the_flag_too_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()
  channel.collect_answers([channel.Typed("1002"), channel.Typed("5678")])

  cf_callcenter_agent.run(
    kz,
    asking_node("toggle_login"),
    somebody_elses_phone(),
  )

  assert agent_state.availability_of(kz, account, mo) == Available
}

//
// --- `*22<extension>` -------------------------------------------------------
//
// The pattern callflow `^\*22([0-9]*)$` hands the action what followed the
// `*22`. An `agent_login` key dials it when pressed, so a supervisor's key
// toggles the agent it shows.
//

/// A call as the pattern callflow hands it over, with its capture group.
fn dialled(on: call.Call, digits: String) -> call.Call {
  call.kvs_store(on, "cf_capture_group", doc.String(digits))
}

fn the_bosses_phone() -> call.Call {
  a_call(Some(boss))
}

/// An empty capture is plain `*22`: the caller's own login, nothing asked.
pub fn an_empty_extension_is_plain_star_22_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()

  cf_callcenter_agent.run(kz, node("toggle_login"), dialled(own_phone(), ""))

  assert agent_state.availability_of(kz, account, jane) == Available
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_wait", feature_codes.logged_in_prompt),
      Command("stop", ""),
    ]
}

/// The caller's own extension is theirs to toggle.
pub fn the_callers_own_extension_test() {
  let kz = fake.kazoo(an_account())
  a_working_channel()

  cf_callcenter_agent.run(kz, node("toggle_login"), dialled(own_phone(), "101"))

  assert agent_state.availability_of(kz, account, jane) == Available
  assert list.contains(
    channel.sent(),
    Command("prompt_and_wait", feature_codes.logged_in_prompt),
  )
}

/// An administrator toggles somebody else, and hears what the agent now is;
/// the administrator's own availability is not touched.
pub fn an_admin_toggles_another_agent_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()

  cf_callcenter_agent.run(
    kz,
    node("toggle_login"),
    dialled(the_bosses_phone(), "102"),
  )
  assert agent_state.availability_of(kz, account, mo) == Available
  assert !was_written_for(f, boss)
  assert !was_written(f)
  assert list.contains(
    channel.sent(),
    Command("prompt_and_wait", feature_codes.logged_in_prompt),
  )

  // And back out again.
  a_working_channel()
  cf_callcenter_agent.run(
    kz,
    node("toggle_login"),
    dialled(the_bosses_phone(), "102"),
  )
  assert agent_state.availability_of(kz, account, mo) == LoggedOut
  assert list.contains(
    channel.sent(),
    Command("prompt_and_wait", feature_codes.logged_out_prompt),
  )
}

/// Anybody else may not, and nothing changes.
pub fn a_non_admin_is_refused_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()

  cf_callcenter_agent.run(kz, node("toggle_login"), dialled(own_phone(), "102"))

  assert !was_written_for(f, mo)
  assert !was_written(f)
  assert channel.sent()
    == [
      Command("answer", ""),
      Command("prompt_and_wait", feature_codes.invalid_prompt),
      Command("stop", ""),
    ]
}

/// An extension no agent has is refused the same way. The administrator's
/// own extension is one: they are not an agent.
pub fn an_unknown_extension_is_refused_test() {
  list.each(["999", "100"], fn(digits) {
    let f = an_account()
    let kz = fake.kazoo(f)
    a_working_channel()

    cf_callcenter_agent.run(
      kz,
      node("toggle_login"),
      dialled(the_bosses_phone(), digits),
    )

    assert !was_written_for(f, boss)
    assert list.contains(
      channel.sent(),
      Command("prompt_and_wait", feature_codes.invalid_prompt),
    )
  })
}

/// A phone with no owner has nobody to be allowed, and `require_pin` with an
/// extension is not a combination this action takes.
pub fn no_owner_and_require_pin_are_refused_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()
  cf_callcenter_agent.run(
    kz,
    node("toggle_login"),
    dialled(somebody_elses_phone(), "101"),
  )
  assert !was_written(f)
  assert list.contains(
    channel.sent(),
    Command("prompt_and_wait", feature_codes.invalid_prompt),
  )

  a_working_channel()
  cf_callcenter_agent.run(
    kz,
    asking_node("toggle_login"),
    dialled(the_bosses_phone(), "101"),
  )
  assert !was_written(f)
  // Refused outright: nobody is asked for an id.
  assert !list.any(channel.sent(), fn(command) {
    command.name == "prompt_and_collect_digits"
  })
}

/// Only `toggle_login` reads the capture: a break code on a pattern is the
/// caller's own break.
pub fn other_actions_ignore_the_extension_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.phone)
  let assert Ok(_) =
    agent_state.set(kz, account, mo, to: Available, source: agent_state.phone)
  a_working_channel()

  cf_callcenter_agent.run(kz, node("toggle_break"), dialled(own_phone(), "102"))

  assert agent_state.availability_of(kz, account, jane) == OnBreak
  assert agent_state.availability_of(kz, account, mo) == Available
}

//
// --- The node's `presence_id` ------------------------------------------------
//

fn stored_presence_id(f: fake.Fake, agent_id: String) -> Option(String) {
  case
    fake.lookup(
      f,
      kazoo.account_db(account),
      records.agent_document_id(agent_id),
    )
  {
    Ok(document) ->
      doc.get_string(document, ["presence_id"]) |> option.from_result
    Error(_) -> None
  }
}

/// A node's `presence_id` is stored on the agent's document, for every later
/// change to publish at; a node without one leaves it where it was.
pub fn the_nodes_presence_id_is_remembered_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()

  cf_callcenter_agent.run(
    kz,
    doc.object([
      #("action", doc.String("toggle_login")),
      #("presence_id", doc.String("sales-lamp")),
    ]),
    own_phone(),
  )
  assert agent_state.availability_of(kz, account, jane) == Available
  assert stored_presence_id(f, jane) == Some("sales-lamp")

  a_working_channel()
  cf_callcenter_agent.run(kz, node("toggle_login"), own_phone())
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert stored_presence_id(f, jane) == Some("sales-lamp")
}

/// The target's document is the one a `*22<extension>` node points.
pub fn the_presence_id_goes_to_the_target_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  a_working_channel()

  cf_callcenter_agent.run(
    kz,
    doc.object([
      #("action", doc.String("toggle_login")),
      #("presence_id", doc.String("mo-lamp")),
    ]),
    dialled(the_bosses_phone(), "102"),
  )
  assert stored_presence_id(f, mo) == Some("mo-lamp")
  assert stored_presence_id(f, boss) == None
}

//
// --- Users who may not work ------------------------------------------------
//
// A login, a break or a resume is for a user who is there, not deleted and
// enabled. Anybody else hears the refusal and nothing is written -- not the
// availability, not the lamp. A logout always goes ahead.
//

/// The user as they are in the fake, with one field changed.
fn edit_user(
  f: fake.Fake,
  user_id: String,
  field: String,
  value: doc.Value,
) -> Nil {
  let db = kazoo.account_db(account)
  let assert Ok(user) = fake.lookup(f, db, user_id)
  fake.put_doc(f, db, doc.set(user, [field], value))
}

fn refused(sent: List(Command)) -> Bool {
  sent
  == [
    Command("answer", ""),
    Command("prompt_and_wait", feature_codes.invalid_prompt),
    Command("stop", ""),
  ]
}

/// `*22` from a disabled or deleted user's own phone logs nobody in, and
/// the node's lamp is not pointed either.
pub fn a_disabled_or_deleted_user_cannot_log_in_test() {
  list.each(
    [#("enabled", doc.Bool(False)), #("pvt_deleted", doc.Bool(True))],
    fn(edit) {
      let f = an_account()
      let kz = fake.kazoo(f)
      edit_user(f, jane, edit.0, edit.1)
      a_working_channel()

      cf_callcenter_agent.run(
        kz,
        doc.object([
          #("action", doc.String("toggle_login")),
          #("presence_id", doc.String("sales-lamp")),
        ]),
        own_phone(),
      )

      assert refused(channel.sent())
      assert !was_written(f)
      assert agent_state.availability_of(kz, account, jane) == LoggedOut
    },
  )
}

/// `*22` from the phone of a user on do-not-disturb
/// made them available, and no user edit told the listener that holds them
/// out. It is refused as for a disabled user, and nothing is written, the
/// lamp included; `*24` is refused too.
pub fn a_user_on_do_not_disturb_cannot_log_in_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  edit_user(
    f,
    jane,
    "do_not_disturb",
    doc.object([#("enabled", doc.Bool(True))]),
  )

  a_working_channel()
  cf_callcenter_agent.run(
    kz,
    doc.object([
      #("action", doc.String("toggle_login")),
      #("presence_id", doc.String("sales-lamp")),
    ]),
    own_phone(),
  )
  assert refused(channel.sent())
  assert !was_written(f)
  assert agent_state.availability_of(kz, account, jane) == LoggedOut

  a_working_channel()
  cf_callcenter_agent.run(kz, node("toggle_break"), own_phone())
  assert !was_written(f)
}

/// A disabled agent still logged in -- the sweep has not got there yet --
/// may log out, and may not take a break.
pub fn a_disabled_user_may_only_log_out_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.phone)
  edit_user(f, jane, "enabled", doc.Bool(False))

  a_working_channel()
  cf_callcenter_agent.run(kz, node("toggle_break"), own_phone())
  assert refused(channel.sent())
  assert agent_state.availability_of(kz, account, jane) == Available

  a_working_channel()
  cf_callcenter_agent.run(kz, node("toggle_login"), own_phone())
  assert list.contains(
    channel.sent(),
    Command("prompt_and_wait", feature_codes.logged_out_prompt),
  )
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}

/// An administrator's `*22<extension>` is refused the same way for a
/// disabled agent, and a `*23` typist who is disabled is too.
pub fn nobody_logs_a_disabled_agent_in_test() {
  let f = an_account()
  let kz = fake.kazoo(f)
  edit_user(f, mo, "enabled", doc.Bool(False))

  a_working_channel()
  cf_callcenter_agent.run(
    kz,
    node("toggle_login"),
    dialled(the_bosses_phone(), "102"),
  )
  assert refused(channel.sent())
  assert !was_written_for(f, mo)

  a_working_channel()
  channel.collect_answers([channel.Typed("1002"), channel.Typed("5678")])
  cf_callcenter_agent.run(kz, asking_node("toggle_login"), own_phone())
  assert list.contains(
    channel.sent(),
    Command("prompt_and_wait", feature_codes.invalid_prompt),
  )
  assert !was_written_for(f, mo)
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}
