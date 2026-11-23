//// The one seam every reader and writer of an agent's state goes through:
//// the wire spellings, and a change that lands in the document, the log and
//// the availability that comes back out.

import callcenter_maintenance
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import kazoo/doc
import kazoo/kazoo
import kazoo/testing/fake

import callcenter/agent_state
import callcenter/agents
import callcenter/records
import callcenter/types.{
  Available, AvailableOnDemand, Idle, LoggedOut, OnBreak, OnCall, Ringing,
  WrappingUp,
}

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const agent = "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91"

/// The four availabilities, and the strings the schema, the events and the
/// API all spell them with.
pub fn availability_spellings_test() {
  let all = [LoggedOut, Available, AvailableOnDemand, OnBreak]
  list.each(all, fn(availability) {
    assert agent_state.availability_from_string(
        agent_state.availability_to_string(availability),
      )
      == Ok(availability)
  })
  assert agent_state.availability_to_string(AvailableOnDemand)
    == "available_on_demand"
  assert agent_state.availability_from_string("paused") == Error(Nil)
}

/// Activity has no `from_string`: it is derived and never asked for.
pub fn activity_spellings_test() {
  assert agent_state.activity_to_string(Idle) == "idle"
  assert agent_state.activity_to_string(Ringing) == "ringing"
  assert agent_state.activity_to_string(OnCall(True)) == "on_call"
  assert agent_state.activity_to_string(OnCall(False)) == "on_call"
  assert agent_state.activity_to_string(WrappingUp) == "wrapping_up"
}

pub fn source_spellings_test() {
  assert agent_state.source_to_string(agent_state.phone) == "phone"
  assert agent_state.source_to_string(agent_state.ui) == "ui"
  assert agent_state.source_to_string(agent_state.supervisor) == "supervisor"
  assert agent_state.source_to_string(agent_state.no_answer_rule) == "no_answer"
  assert agent_state.source_to_string(agent_state.dnd) == "dnd"
  assert agent_state.source_to_string(agent_state.system) == "system"

  assert agent_state.source_from_string("ui") == Ok(agent_state.ui)
  assert agent_state.source_from_string("dnd") == Ok(agent_state.dnd)
  assert agent_state.source_from_string("shouting") == Error(Nil)
}

/// On break is still logged in: the phone key follows the login and not the
/// break, as the feature code it replaces did.
pub fn logged_in_test() {
  assert !agent_state.is_logged_in(LoggedOut)
  assert agent_state.is_logged_in(Available)
  assert agent_state.is_logged_in(AvailableOnDemand)
  assert agent_state.is_logged_in(OnBreak)
}

/// An agent nobody has ever changed is logged out, which is not an error.
pub fn unknown_agent_is_logged_out_test() {
  let kz = fake.kazoo(fake.new())
  let assert Ok(state) = agent_state.get(kz, account, agent)
  assert state.availability == LoggedOut
  assert state.previous == None
  assert agent_state.availability_of(kz, account, agent) == LoggedOut
}

/// A change is readable afterwards, and says what it was before.
pub fn set_then_get_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)

  let assert Ok(state) =
    agent_state.set(kz, account, agent, to: Available, source: agent_state.ui)
  assert state.availability == Available
  assert state.previous == Some(LoggedOut)

  let assert Ok(read_back) = agent_state.get(kz, account, agent)
  assert read_back.availability == Available
  assert agent_state.source_to_string(read_back.source) == "ui"

  let assert Ok(next) =
    agent_state.set(kz, account, agent, to: OnBreak, source: agent_state.phone)
  assert next.previous == Some(Available)
  assert agent_state.availability_of(kz, account, agent) == OnBreak
}

/// The document is not the user's own: both live in the account database.
pub fn availability_has_its_own_document_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  let _ =
    agent_state.set(kz, account, agent, to: Available, source: agent_state.ui)

  let written =
    fake.all_docs(f, kazoo.account_db(account))
    |> list.filter(fn(document) {
      doc.get_string(document, ["pvt_type"]) == Ok("callcenter_agent")
    })
  assert list.length(written) == 1
  let assert [document] = written
  assert doc.get_string(document, ["agent_id"]) == Ok(agent)
  assert doc.get_string(document, ["_id"]) != Ok(agent)
  assert doc.get_string(document, ["availability"]) == Ok("available")
}

/// Nothing is derived without a node, so every agent reads as idle and the
/// shape is still the right one.
pub fn activity_without_a_node_test() {
  assert agent_state.activity_of(account, agent) == Idle
  assert agent_state.activities(account) == []
}

// --- Who may start working ---------------------------------------------------

fn a_user(fields: List(#(String, doc.Value))) -> doc.Value {
  doc.object([
    #("_id", doc.String(agent)),
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object([#("pin", doc.String("4321"))])),
    ..fields
  ])
}

/// There, a user, not deleted and enabled; and a user nobody could read is
/// refused, since a person asking can ask again.
pub fn who_may_start_working_test() {
  assert agents.fit_to_work(Ok(a_user([]))) == Ok(Nil)
  assert agents.fit_to_work(Ok(a_user([#("enabled", doc.Bool(True))])))
    == Ok(Nil)
  assert agents.fit_to_work(Ok(a_user([#("enabled", doc.Bool(False))])))
    == Error(agents.Disabled)
  assert agents.fit_to_work(Ok(a_user([on_dnd()])))
    == Error(agents.DoNotDisturb)
  // Disabled says the more lasting of the two.
  assert agents.fit_to_work(
      Ok(a_user([on_dnd(), #("enabled", doc.Bool(False))])),
    )
    == Error(agents.Disabled)
  assert agents.fit_to_work(
      Ok(
        a_user([
          #("do_not_disturb", doc.object([#("enabled", doc.Bool(False))])),
        ]),
      ),
    )
    == Ok(Nil)
  assert agents.fit_to_work(Ok(a_user([#("pvt_deleted", doc.Bool(True))])))
    == Error(agents.Deleted)
  assert agents.fit_to_work(
      Ok(doc.object([#("pvt_type", doc.String("device"))])),
    )
    == Error(agents.NoSuchUser)
  assert agents.fit_to_work(Error(kazoo.NotFound)) == Error(agents.NoSuchUser)
  assert agents.fit_to_work(Error(kazoo.Unavailable))
    == Error(agents.Unread(kazoo.Unavailable))
}

/// A change a person asks for goes through when the user may work, and is
/// refused, with nothing written, when they may not -- except a logout,
/// which is always allowed.
pub fn a_disabled_or_missing_user_is_only_logged_out_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  let db = kazoo.account_db(account)
  let change = fn(to, source) {
    agent_state.change(kz, account, agent, to: to, source: source, break_s: 60)
  }

  // Nobody at all: nothing is written.
  assert change(Available, agent_state.ui)
    == Error(agent_state.Unfit(agents.NoSuchUser))
  assert fake.lookup(f, db, records.agent_document_id(agent))
    == Error(kazoo.NotFound)

  // Enabled: in.
  fake.put_doc(f, db, a_user([]))
  let assert Ok(_) = change(Available, agent_state.ui)

  // Disabled: no break, no other way of working -- but out, yes.
  fake.put_doc(f, db, a_user([#("enabled", doc.Bool(False))]))
  assert change(OnBreak, agent_state.supervisor)
    == Error(agent_state.Unfit(agents.Disabled))
  assert change(AvailableOnDemand, agent_state.ui)
    == Error(agent_state.Unfit(agents.Disabled))
  assert agent_state.availability_of(kz, account, agent) == Available
  let assert Ok(out) = change(LoggedOut, agent_state.ui)
  assert out.availability == LoggedOut

  // Deleted.
  fake.put_doc(f, db, a_user([#("pvt_deleted", doc.Bool(True))]))
  assert change(Available, agent_state.phone)
    == Error(agent_state.Unfit(agents.Deleted))
  assert agent_state.availability_of(kz, account, agent) == LoggedOut
}

fn on_dnd() -> #(String, doc.Value) {
  #("do_not_disturb", doc.object([#("enabled", doc.Bool(True))]))
}

/// An agent on do-not-disturb could dial `*22` and be
/// made available. No user edit is published by that, so the listener that
/// holds them out never heard of it, and they collected misses until the
/// sweep. Every route refuses them now, as it refuses a disabled user: a
/// login, on demand, and a break -- which do-not-disturb's logout would take
/// away a moment later anyway -- with nothing written. Logging out is
/// allowed, and the operator's command says why it refused.
pub fn a_user_on_do_not_disturb_is_only_logged_out_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  let db = kazoo.account_db(account)
  fake.put_doc(f, db, a_user([]))
  let assert Ok(_) =
    agent_state.change(
      kz,
      account,
      agent,
      to: Available,
      source: agent_state.ui,
      break_s: 0,
    )
  let assert Ok(_) =
    agent_state.change(
      kz,
      account,
      agent,
      to: LoggedOut,
      source: agent_state.ui,
      break_s: 0,
    )

  fake.put_doc(f, db, a_user([on_dnd()]))
  let change = fn(to) {
    agent_state.change(
      kz,
      account,
      agent,
      to: to,
      source: agent_state.phone,
      break_s: 0,
    )
  }
  assert change(Available) == Error(agent_state.Unfit(agents.DoNotDisturb))
  assert change(AvailableOnDemand)
    == Error(agent_state.Unfit(agents.DoNotDisturb))
  assert change(OnBreak) == Error(agent_state.Unfit(agents.DoNotDisturb))
  assert agent_state.availability_of(kz, account, agent) == LoggedOut

  let assert [line] =
    callcenter_maintenance.set_agent_lines(kz, account, agent, "available")
  assert string.starts_with(line, "refused: ")
  assert string.contains(line, "do not disturb")
  assert agent_state.availability_of(kz, account, agent) == LoggedOut

  let assert Ok(out) = change(LoggedOut)
  assert out.availability == LoggedOut
}

/// `sup callcenter_maintenance set_agent` goes the same way: refused and
/// said so for a disabled user, logged out whatever.
pub fn the_operators_command_is_refused_alike_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  let db = kazoo.account_db(account)
  fake.put_doc(f, db, a_user([]))
  assert callcenter_maintenance.set_agent_lines(kz, account, agent, "available")
    == [agent <> " is now available (was logged_out)"]

  fake.put_doc(f, db, a_user([#("enabled", doc.Bool(False))]))
  let assert [line] =
    callcenter_maintenance.set_agent_lines(kz, account, agent, "on_break")
  assert string.starts_with(line, "refused: ")
  assert string.contains(line, "disabled")
  assert agent_state.availability_of(kz, account, agent) == Available

  assert callcenter_maintenance.set_agent_lines(
      kz,
      account,
      agent,
      "logged_out",
    )
    == [agent <> " is now logged_out (was available)"]
}

/// A break is a pause in a login: a logged-out agent is refused one, with
/// or without an end, and nothing is written. Logged in, the same break
/// goes through. The operator's command says so too.
pub fn a_logged_out_agent_is_refused_a_break_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  let db = kazoo.account_db(account)
  fake.put_doc(f, db, a_user([]))
  let take = fn(source, break_s) {
    agent_state.change(
      kz,
      account,
      agent,
      to: OnBreak,
      source: source,
      break_s: break_s,
    )
  }

  assert take(agent_state.supervisor, 600) == Error(agent_state.NotLoggedIn)
  assert take(agent_state.ui, 0) == Error(agent_state.NotLoggedIn)
  assert fake.lookup(f, db, records.agent_document_id(agent))
    == Error(kazoo.NotFound)
  let assert [line] =
    callcenter_maintenance.set_agent_lines(kz, account, agent, "on_break")
  assert string.starts_with(line, "refused: ")
  assert string.contains(line, "logged out")
  assert agent_state.availability_of(kz, account, agent) == LoggedOut

  let assert Ok(_) =
    agent_state.change(
      kz,
      account,
      agent,
      to: Available,
      source: agent_state.ui,
      break_s: 0,
    )
  let assert Ok(state) = take(agent_state.supervisor, 600)
  assert state.availability == OnBreak
  assert state.break_ends != None
}
