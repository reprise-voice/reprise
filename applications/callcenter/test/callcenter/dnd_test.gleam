//// Do not disturb: what it decides, where it reads the account from, and
//// what it does to an agent's availability document.

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import kazoo/listener
import kazoo/testing/fake

import callcenter/agent_state
import callcenter/agents
import callcenter/availability
import callcenter/breaks
import callcenter/dnd.{Disable, Force, Leave, Remove, Restore, RestoreBreak}
import callcenter/types.{Available, AvailableOnDemand, LoggedOut, OnBreak}

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const jane = "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91"

fn state(
  availability: types.Availability,
  previous: option.Option(types.Availability),
  source: String,
) -> agent_state.AgentAvailability {
  let assert Ok(source) = agent_state.source_from_string(source)
  agent_state.state(
    availability: availability,
    previous: previous,
    timestamp: 63_929_304_822,
    source: source,
  )
}

const now = 63_929_304_900

fn decide(dnd_on: Bool, state: agent_state.AgentAvailability) -> dnd.Decision {
  dnd.decide(dnd_on, state, now)
}

/// On: an agent who could take a call is stood down, and one who is already
/// out is left alone so that what they chose is not written over.
pub fn turning_it_on_test() {
  assert decide(True, state(Available, None, "ui")) == Force
  assert decide(True, state(AvailableOnDemand, None, "phone")) == Force
  assert decide(True, state(OnBreak, Some(Available), "phone")) == Force
  assert decide(True, state(LoggedOut, None, "ui")) == Leave
}

/// Off: back to where do-not-disturb found them, and only when it was
/// do-not-disturb that put them there.
pub fn turning_it_off_test() {
  assert decide(False, state(LoggedOut, Some(Available), "dnd"))
    == Restore(Available)
  assert decide(False, state(LoggedOut, Some(OnBreak), "dnd"))
    == Restore(OnBreak)

  // The agent logged themselves out while it was on; clearing it does not
  // log them back in.
  assert decide(False, state(LoggedOut, Some(Available), "phone")) == Leave
  assert decide(False, state(LoggedOut, Some(Available), "supervisor")) == Leave

  // Nothing to go back to.
  assert decide(False, state(LoggedOut, None, "dnd")) == Leave
  assert decide(False, state(LoggedOut, Some(LoggedOut), "dnd")) == Leave

  // Not logged out at all: nothing was forced, so nothing is restored.
  assert decide(False, state(Available, None, "dnd")) == Leave
}

fn held(
  ends: Int,
  before: option.Option(types.Availability),
) -> agent_state.AgentAvailability {
  availability.AgentAvailability(
    ..state(LoggedOut, Some(OnBreak), "dnd"),
    held_break: Some(availability.HeldBreak(ends: ends, before: before)),
  )
}

/// Do-not-disturb logged out an agent on a break with
/// an end, and clearing it restored a break with no end. It gives back the
/// break it held: the rest of it while its end has not come, and after that
/// what the break would have ended to -- which never logs in an agent who
/// was not logged in before the break.
pub fn a_held_break_comes_back_as_it_was_test() {
  assert decide(False, held(now + 300, Some(Available)))
    == RestoreBreak(ends: now + 300, then: Available)
  assert decide(False, held(now + 1, Some(AvailableOnDemand)))
    == RestoreBreak(ends: now + 1, then: AvailableOnDemand)
  assert decide(False, held(now + 300, None))
    == RestoreBreak(ends: now + 300, then: LoggedOut)

  assert decide(False, held(now, Some(Available))) == Restore(Available)
  assert decide(False, held(now - 600, Some(AvailableOnDemand)))
    == Restore(AvailableOnDemand)
  assert decide(False, held(now - 600, Some(LoggedOut))) == Leave
  assert decide(False, held(now - 600, None)) == Leave

  // Only do-not-disturb's own logout gives anything back.
  let by_hand =
    availability.AgentAvailability(
      ..held(now + 300, Some(Available)),
      source: availability.Phone,
    )
  assert decide(False, by_hand) == Leave
}

/// The whole path: Jane, available, takes a ten-minute break; do-not-disturb
/// goes on and off. She is back on the same break, with the same end, and
/// going back to available when it ends.
pub fn do_not_disturb_during_a_break_keeps_its_end_test() {
  let #(f, kz) = staffed()
  let assert Ok(on_break) =
    breaks.set(
      kz,
      account,
      jane,
      to: OnBreak,
      source: agent_state.phone,
      timeout_s: 600,
    )
  let assert Some(ends) = on_break.break_ends

  assert jane_saved(f, kz, dnd: True, enabled: True) == Force
  let assert Ok(out) = agent_state.get(kz, account, jane)
  assert out.availability == LoggedOut
  assert out.break_ends == None
  assert out.held_break
    == Some(availability.HeldBreak(ends: ends, before: Some(Available)))

  assert jane_saved(f, kz, dnd: False, enabled: True)
    == RestoreBreak(ends: ends, then: Available)
  let assert Ok(back) = agent_state.get(kz, account, jane)
  assert back.availability == OnBreak
  assert back.break_ends == Some(ends)
  assert back.previous == Some(Available)
  assert back.held_break == None
  assert breaks.verdict(back, ends, ends) == breaks.Over(Available)
}

/// The break ran out while do-not-disturb was on: clearing it puts Jane
/// where the break would have, available on demand, and no break at all.
pub fn a_held_break_that_ran_out_ends_where_it_would_have_test() {
  let #(f, kz) = staffed()
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String("callcenter_agent-" <> jane)),
      #("pvt_type", doc.String("callcenter_agent")),
      #("agent_id", doc.String(jane)),
      #("availability", doc.String("logged_out")),
      #("previous", doc.String("on_break")),
      #("source", doc.String("dnd")),
      #("timestamp", doc.Int(now - 900)),
      #(
        "held_break",
        doc.object([
          #("ends", doc.Int(now - 300)),
          #("before", doc.String("available_on_demand")),
        ]),
      ),
    ]),
  )
  assert jane_saved(f, kz, dnd: False, enabled: True)
    == Restore(AvailableOnDemand)
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == AvailableOnDemand
  assert state.held_break == None
}

/// The account comes from the event when it says, and from the database name
/// when it does not. Anything that is not an account database is not ours.
pub fn account_of_test() {
  assert dnd.account_of(doc.object([#("Account-ID", doc.String(account))]))
    == Some(account)

  assert dnd.account_of(
      doc.object([#("Database", doc.String(kazoo.account_db(account)))]),
    )
    == Some(account)

  assert dnd.account_of(
      doc.object([#("Database", doc.String("system_config"))]),
    )
    == None
  assert dnd.account_of(doc.object([])) == None
}

pub fn account_of_db_test() {
  assert dnd.account_of_db(kazoo.account_db(account)) == account
  assert dnd.account_of_db("account/4b/1f/0c2d7e8a9b0c1d2e3f4051627384")
    == account
}

fn a_user(dnd_on: Bool, agent: Bool) -> doc.Value {
  let base = [
    #("_id", doc.String(jane)),
    #("pvt_type", doc.String("user")),
    #("username", doc.String("jane")),
    #("do_not_disturb", doc.object([#("enabled", doc.Bool(dnd_on))])),
  ]
  doc.object(case agent {
    True -> [
      #("call_center", doc.object([#("pin", doc.String("4321"))])),
      ..base
    ]
    False -> base
  })
}

/// The whole path: an available agent, do-not-disturb on, then off again.
pub fn on_then_off_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  fake.put_doc(f, kazoo.account_db(account), a_user(False, True))
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.ui)

  fake.put_doc(f, kazoo.account_db(account), a_user(True, True))
  assert dnd.apply(kz, account, jane) == Force
  assert agent_state.availability_of(kz, account, jane) == LoggedOut

  fake.put_doc(f, kazoo.account_db(account), a_user(False, True))
  assert dnd.apply(kz, account, jane) == Restore(Available)
  assert agent_state.availability_of(kz, account, jane) == Available
}

/// A user who is not an agent, and one who is not there at all, are both
/// nothing to do: this hook sees every user edit in the cluster.
pub fn only_agents_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  assert dnd.apply(kz, account, jane) == Leave

  fake.put_doc(f, kazoo.account_db(account), a_user(True, False))
  assert dnd.apply(kz, account, jane) == Leave
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}

/// Repeating the same edit is not a second forcing: the second one finds the
/// agent already out and leaves the availability it remembered alone.
pub fn repeated_edits_test() {
  let f = fake.new()
  let kz = fake.kazoo(f)
  fake.put_doc(f, kazoo.account_db(account), a_user(False, True))
  let assert Ok(_) =
    agent_state.set(
      kz,
      account,
      jane,
      to: AvailableOnDemand,
      source: agent_state.ui,
    )

  fake.put_doc(f, kazoo.account_db(account), a_user(True, True))
  assert dnd.apply(kz, account, jane) == Force
  assert dnd.apply(kz, account, jane) == Leave

  fake.put_doc(f, kazoo.account_db(account), a_user(False, True))
  assert dnd.apply(kz, account, jane) == Restore(AvailableOnDemand)
}

// --- One queue for the cluster ---------------------------------------------

/// Every node had a queue of its own, capped at a
/// hundred, so every node took every user edit in the cluster and raced the
/// others to the same write, and a burst past a hundred was dropped. One
/// queue every node shares hands each edit to one node, and holds a burst.
pub fn one_shared_queue_test() {
  let spec = listener.to_spec(dnd.consumer())
  let assert Ok(queue) = dict.get(spec, "queue") |> result.map(string.inspect)
  assert string.contains(queue, dnd.queue_name)
  assert string.contains(queue, "\"max_length\", 10000)")
  let assert Ok(bindings) =
    dict.get(spec, "bindings") |> result.map(string.inspect)
  assert string.contains(bindings, "user")
}

// --- Behind the events -----------------------------------------------------

/// What disagrees: do-not-disturb on and the agent able to take calls, or
/// off and the agent still held out by it. Everything else is in step,
/// including an agent who logged themselves out.
pub fn what_disagrees_test() {
  assert dnd.disagrees(True, state(Available, None, "ui"))
  assert dnd.disagrees(True, state(OnBreak, None, "phone"))
  assert !dnd.disagrees(True, state(LoggedOut, None, "ui"))
  assert dnd.disagrees(False, state(LoggedOut, Some(Available), "dnd"))
  assert !dnd.disagrees(False, state(LoggedOut, Some(Available), "phone"))
  assert !dnd.disagrees(False, state(Available, None, "dnd"))
}

/// Only agents are looked at, by user id, and an agent with no availability
/// document is logged out: in step with do-not-disturb on.
pub fn the_agents_that_disagree_test() {
  let ann = doc.set(a_user(True, True), ["_id"], doc.String("ann"))
  let bob = doc.set(a_user(False, True), ["_id"], doc.String("bob"))
  let cat = doc.set(a_user(True, True), ["_id"], doc.String("cat"))
  let dan = doc.set(a_user(True, False), ["_id"], doc.String("dan"))
  let states =
    dict.from_list([
      #("ann", state(Available, None, "ui")),
      #("bob", state(Available, None, "ui")),
      #("dan", state(Available, None, "ui")),
    ])
  assert dnd.disagreeing([ann, bob, cat, dan], states) == ["ann"]
}

/// The users' standing, as `callcenter/agent_users` emits it: every user
/// with a `call_center` object, and what the sweep weighs of each.
fn agent_users_view() -> fake.View {
  fake.Valued(
    name: agents.standing_view,
    doc_type: "user",
    key: fn(d) {
      case doc.get(d, ["call_center"]) {
        Ok(_) -> doc.get_string(d, ["_id"]) |> result.map(doc.String)
        Error(Nil) -> Error(Nil)
      }
    },
    value: fn(d) {
      doc.object([
        #("agent", doc.Bool(agents.is_agent(d))),
        #("enabled", doc.get(d, ["enabled"]) |> result.unwrap(doc.Null)),
        #(
          "do_not_disturb",
          doc.get(d, ["do_not_disturb", "enabled"]) |> result.unwrap(doc.Null),
        ),
      ])
    },
  )
}

fn with_agent_views() -> fake.Fake {
  fake.new_with_views([
    agent_users_view(),
    fake.Valued(
      name: "callcenter/agents",
      doc_type: "callcenter_agent",
      key: fn(d) { doc.get_string(d, ["agent_id"]) |> result.map(doc.String) },
      value: fn(d) { d },
    ),
  ])
}

// --- A user disabled, or deleted ---------------------------------------------

const queue_one = "37139638ff5b68f155d8445178524df1"

const queue_two = "6a7b8c9d0e1f2a3b4c5d6e7f80912233"

/// The three views the sweep reads, and the tiers' view the deletion takes a
/// user out of queues by. A deleted document is in none of them.
fn with_every_view() -> fake.Fake {
  fake.new_with_views([
    agent_users_view(),
    fake.Valued(
      name: "callcenter/agents",
      doc_type: "callcenter_agent",
      key: fn(d) { doc.get_string(d, ["agent_id"]) |> result.map(doc.String) },
      value: fn(d) { d },
    ),
    fake.Fanout(
      name: "callcenter/queues_by_agent",
      doc_type: "queue",
      keys: fn(d) {
        doc.get_list(d, ["agents"])
        |> result.unwrap([])
        |> list.filter_map(fn(entry) { doc.get_string(entry, ["id"]) })
        |> list.map(fn(id) { doc.List([doc.String(id)]) })
      },
    ),
  ])
}

fn a_queue(id: String, agents: List(String)) -> doc.Value {
  doc.object([
    #("_id", doc.String(id)),
    #("pvt_type", doc.String("queue")),
    #(
      "agents",
      doc.List(
        list.map(agents, fn(agent) {
          doc.object([
            #("id", doc.String(agent)),
            #("level", doc.Int(1)),
            #("position", doc.Int(1)),
          ])
        }),
      ),
    ),
  ])
}

fn tiers_in(f: fake.Fake, queue_id: String) -> List(String) {
  let assert Ok(queue) = fake.lookup(f, kazoo.account_db(account), queue_id)
  doc.get_list(queue, ["agents"])
  |> result.unwrap([])
  |> list.filter_map(fn(entry) { doc.get_string(entry, ["id"]) })
}

fn has_agent_document(f: fake.Fake, user_id: String) -> Bool {
  fake.lookup(f, kazoo.account_db(account), "callcenter_agent-" <> user_id)
  |> result.is_ok
}

/// Jane, an available agent in two queues beside Bob.
fn staffed() -> #(fake.Fake, Kazoo) {
  let f = with_every_view()
  let kz = fake.kazoo(f)
  let db = kazoo.account_db(account)
  fake.put_doc(f, db, a_user(False, True))
  fake.put_doc(f, db, a_queue(queue_one, [jane, "bob"]))
  fake.put_doc(f, db, a_queue(queue_two, [jane]))
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.ui)
  #(f, kz)
}

/// A disabled agent is logged out, by the system, and keeps their tiers:
/// enabled again they are back in every queue, logged out, and nothing logs
/// them back in -- not even do-not-disturb clearing while they were away.
pub fn a_disabled_agent_is_logged_out_and_keeps_their_tiers_test() {
  let #(f, kz) = staffed()
  let db = kazoo.account_db(account)
  fake.put_doc(
    f,
    db,
    doc.set(a_user(False, True), ["enabled"], doc.Bool(False)),
  )

  assert dnd.apply(kz, account, jane) == Disable
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert state.availability == LoggedOut
  assert agent_state.source_to_string(state.source) == "system"
  assert tiers_in(f, queue_one) == [jane, "bob"]
  assert tiers_in(f, queue_two) == [jane]
  // Followed once.
  assert dnd.apply(kz, account, jane) == Leave

  fake.put_doc(f, db, a_user(False, True))
  assert dnd.apply(kz, account, jane) == Leave
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}

/// Jane's user saved with do-not-disturb and `enabled` as given, and the edit
/// followed.
fn jane_saved(
  f: fake.Fake,
  kz: Kazoo,
  dnd dnd_on: Bool,
  enabled enabled: Bool,
) -> dnd.Decision {
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.set(a_user(dnd_on, True), ["enabled"], doc.Bool(enabled)),
  )
  dnd.apply(kz, account, jane)
}

/// Do-not-disturb cleared on an agent who is disabled restores nobody: a
/// disabled user is never logged back in by anything but a person.
pub fn a_disabled_agent_is_not_restored_by_do_not_disturb_test() {
  let #(f, kz) = staffed()
  assert jane_saved(f, kz, dnd: True, enabled: True) == Force
  assert jane_saved(f, kz, dnd: False, enabled: False) == Disable
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert jane_saved(f, kz, dnd: False, enabled: False) == Leave
}

/// Do-not-disturb logged Jane out, she was disabled --
/// already logged out, so nothing was written -- do-not-disturb was cleared
/// while she was disabled, and enabling her again read the logout as still
/// do-not-disturb's and logged her back in. Disabling her makes the logout
/// the system's, whatever order the edits come in.
pub fn enabling_again_restores_nobody_whatever_the_order_test() {
  // On, disabled, off, enabled.
  let #(f, kz) = staffed()
  assert jane_saved(f, kz, dnd: True, enabled: True) == Force
  assert jane_saved(f, kz, dnd: True, enabled: False) == Disable
  let assert Ok(state) = agent_state.get(kz, account, jane)
  assert agent_state.source_to_string(state.source) == "system"
  assert state.previous == Some(LoggedOut)
  assert jane_saved(f, kz, dnd: False, enabled: False) == Leave
  assert jane_saved(f, kz, dnd: False, enabled: True) == Leave
  assert agent_state.availability_of(kz, account, jane) == LoggedOut

  // On, disabled, enabled, off.
  let #(f, kz) = staffed()
  assert jane_saved(f, kz, dnd: True, enabled: True) == Force
  assert jane_saved(f, kz, dnd: True, enabled: False) == Disable
  assert jane_saved(f, kz, dnd: True, enabled: True) == Leave
  assert jane_saved(f, kz, dnd: False, enabled: True) == Leave
  assert agent_state.availability_of(kz, account, jane) == LoggedOut

  // Disabled, on, enabled, off.
  let #(f, kz) = staffed()
  assert jane_saved(f, kz, dnd: False, enabled: False) == Disable
  assert jane_saved(f, kz, dnd: True, enabled: False) == Leave
  assert jane_saved(f, kz, dnd: True, enabled: True) == Leave
  assert jane_saved(f, kz, dnd: False, enabled: True) == Leave
  assert agent_state.availability_of(kz, account, jane) == LoggedOut

  // Disabled, on, off, enabled.
  let #(f, kz) = staffed()
  assert jane_saved(f, kz, dnd: False, enabled: False) == Disable
  assert jane_saved(f, kz, dnd: True, enabled: False) == Leave
  assert jane_saved(f, kz, dnd: False, enabled: False) == Leave
  assert jane_saved(f, kz, dnd: False, enabled: True) == Leave
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}

/// The disable that was never delivered is followed by the sweep for an
/// agent do-not-disturb logged out too: their documents disagree, since
/// do-not-disturb could still undo the logout of a disabled user.
pub fn a_lost_disable_of_an_agent_held_out_by_dnd_is_swept_test() {
  let #(f, kz) = staffed()
  assert jane_saved(f, kz, dnd: True, enabled: True) == Force
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.set(a_user(True, True), ["enabled"], doc.Bool(False)),
  )
  // Bob has a tier and no user, and goes too.
  assert list.key_find(dnd.reconcile(kz, account), jane) == Ok(Disable)
  assert dnd.reconcile(kz, account) == []

  // Enabled and cleared, both edits lost: still logged out.
  fake.put_doc(f, kazoo.account_db(account), a_user(False, True))
  assert dnd.reconcile(kz, account) == []
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}

/// A deleted user -- Crossbar's soft delete, which leaves the document
/// marked -- is taken out of every queue, logged out (the status change is
/// history in the month database, and published), and their agent document
/// deleted. Bob's tier is untouched. The second time is nothing.
pub fn a_deleted_user_leaves_every_queue_test() {
  let #(f, kz) = staffed()
  let db = kazoo.account_db(account)
  fake.put_doc(
    f,
    db,
    doc.set(a_user(False, True), ["pvt_deleted"], doc.Bool(True)),
  )

  let assert Remove(queues) = dnd.apply(kz, account, jane)
  assert list.sort(queues, string.compare)
    == list.sort([queue_one, queue_two], string.compare)
  assert tiers_in(f, queue_one) == ["bob"]
  assert tiers_in(f, queue_two) == []
  assert !has_agent_document(f, jane)
  assert agent_state.availability_of(kz, account, jane) == LoggedOut

  assert dnd.apply(kz, account, jane) == Leave
}

/// A user whose document is gone altogether is deleted too.
pub fn a_user_gone_altogether_leaves_every_queue_test() {
  let #(f, kz) = staffed()
  let assert Ok(_) = kz.datamgr.del_doc(kazoo.account_db(account), jane)

  let assert Remove(_queues) = dnd.apply(kz, account, jane)
  assert tiers_in(f, queue_one) == ["bob"]
  assert !has_agent_document(f, jane)
}

/// A deletion that was never delivered is followed a sweep later, off the
/// availability document and the tiers that name nobody the listing has;
/// and so is a disabled agent the edit missed.
pub fn a_lost_deletion_or_disable_is_followed_by_the_sweep_test() {
  let #(f, kz) = staffed()
  let db = kazoo.account_db(account)
  let bob = doc.set(a_user(False, True), ["_id"], doc.String("bob"))
  fake.put_doc(f, db, bob)
  let assert Ok(_) =
    agent_state.set(kz, account, "bob", to: Available, source: agent_state.ui)
  assert dnd.reconcile(kz, account) == []

  fake.put_doc(f, db, doc.set(bob, ["enabled"], doc.Bool(False)))
  fake.put_doc(
    f,
    db,
    doc.set(a_user(False, True), ["pvt_deleted"], doc.Bool(True)),
  )
  let followed = dnd.reconcile(kz, account)
  assert list.length(followed) == 2
  assert list.contains(followed, #("bob", Disable))
  assert tiers_in(f, queue_one) == ["bob"]
  assert !has_agent_document(f, jane)
  assert agent_state.availability_of(kz, account, "bob") == LoggedOut

  // Followed once.
  assert dnd.reconcile(kz, account) == []
}

/// Deletions come off the same shared queue as edits, so that one node
/// follows each.
pub fn deletions_come_off_the_same_queue_test() {
  let spec = listener.to_spec(dnd.consumer())
  let assert Ok(bindings) =
    dict.get(spec, "bindings") |> result.map(string.inspect)
  assert string.contains(bindings, "deleted")
  assert string.contains(bindings, "edited")
}

/// An edit the listener never delivered is followed a sweep later: the
/// agent whose do-not-disturb went on is stood down, and one whose
/// availability is in step is not touched.
pub fn a_lost_edit_is_followed_by_the_sweep_test() {
  let f = with_agent_views()
  let kz = fake.kazoo(f)
  let bob = doc.set(a_user(False, True), ["_id"], doc.String("bob"))
  fake.put_doc(f, kazoo.account_db(account), a_user(False, True))
  fake.put_doc(f, kazoo.account_db(account), bob)
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: Available, source: agent_state.ui)
  let assert Ok(_) =
    agent_state.set(kz, account, "bob", to: Available, source: agent_state.ui)
  assert dnd.reconcile(kz, account) == []

  // Do-not-disturb goes on, and the edit is lost.
  fake.put_doc(f, kazoo.account_db(account), a_user(True, True))
  assert dnd.reconcile(kz, account) == [#(jane, Force)]
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
  assert agent_state.availability_of(kz, account, "bob") == Available
  // Followed once.
  assert dnd.reconcile(kz, account) == []

  // And off again, lost again.
  fake.put_doc(f, kazoo.account_db(account), a_user(False, True))
  assert dnd.reconcile(kz, account) == [#(jane, Restore(Available))]
  assert agent_state.availability_of(kz, account, jane) == Available
}

// --- What a sweep costs ------------------------------------------------------

/// Every datastore read the sweep of one account makes, in order: the view
/// and whether it asked for the documents, or the document opened.
fn reads_of_a_sweep(kz: Kazoo) -> List(#(String, Bool)) {
  let reads = process.new_subject()
  let datamgr = kz.datamgr
  let counting =
    kazoo.Kazoo(
      ..kz,
      datamgr: kazoo.Datamgr(
        ..datamgr,
        get_results: fn(db, view, options: kazoo.ViewOptions) {
          process.send(reads, #(view, options.include_docs))
          datamgr.get_results(db, view, options)
        },
        open_doc: fn(db, id) {
          process.send(reads, #("open " <> id, True))
          datamgr.open_doc(db, id)
        },
        open_cache_doc: fn(db, id) {
          process.send(reads, #("open " <> id, True))
          datamgr.open_cache_doc(db, id)
        },
      ),
    )
  let _ = dnd.sweep(counting, account)
  drain(reads, [])
}

fn drain(
  reads: process.Subject(#(String, Bool)),
  seen: List(#(String, Bool)),
) -> List(#(String, Bool)) {
  case process.receive(reads, 0) {
    Ok(read) -> drain(reads, [read, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

/// An account whose agents are all in step, with no break overdue, costs
/// its sweep three view reads and no document: the availabilities once, for
/// do-not-disturb and the breaks both, the users' standing -- not every
/// agent's user document -- and the tiers.
pub fn a_sweep_of_an_account_in_step_reads_three_views_test() {
  let #(_f, kz) = staffed()
  // Bob has a tier and no user: his deletion is followed the first time.
  let _ = reads_of_a_sweep(kz)
  assert reads_of_a_sweep(kz)
    == [
      #("callcenter/agents", False),
      #(agents.standing_view, False),
      #("callcenter/queues_by_agent", False),
    ]
}

/// The breaks are ended off the availabilities do-not-disturb read, which
/// can be a moment old: a break the rows still show as overdue, since
/// logged out, is decided again from the document and left alone.
pub fn a_break_ended_since_the_rows_were_read_is_left_alone_test() {
  let #(_f, kz) = staffed()
  let assert Ok(_) =
    agent_state.set(kz, account, jane, to: LoggedOut, source: agent_state.ui)
  let read_before =
    availability.AgentAvailability(
      ..state(OnBreak, Some(Available), "phone"),
      break_ends: Some(now - 600),
    )
  assert breaks.sweep_read(kz, account, Ok([#(jane, read_before)]), now) == []
  assert agent_state.availability_of(kz, account, jane) == LoggedOut
}
