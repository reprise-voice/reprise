//// Answering a presence probe for an agent's login lamp: whose lamp an
//// address is, what is published on it, and what a reboot storm costs.

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import kazoo/amqp
import kazoo/doc
import kazoo/kazoo
import kazoo/listener
import kazoo/testing/fake

import callcenter/agents
import callcenter/lamp_probe.{type Table, Lamp, Table}
import callcenter/presence
import callcenter/records
import callcenter/types.{Answered}
import support/cluster

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const realm = "one.example.test"

// --- Whose lamp ---------------------------------------------------------------

/// Ann has pointed her lamp at `sales-lamp`; Bob has not, so his is the
/// prefix and his extension.
fn table(prefix: String) -> Table {
  Table(account_id: account, realm: realm, prefix: prefix, lamps: [
    Lamp(
      agent_id: "ann",
      override: Some("sales-lamp"),
      presence_id: Some("101"),
    ),
    Lamp(agent_id: "bob", override: None, presence_id: Some("102")),
  ])
}

pub fn a_stored_override_test() {
  assert lamp_probe.resolve(table("*22"), "sales-lamp", realm) == Some("ann")
  // Ann's lamp is not at her prefixed extension any more.
  assert lamp_probe.resolve(table("*22"), "*22101", realm) == None
}

/// An override stored qualified is the same address.
pub fn a_qualified_override_test() {
  let qualified =
    Table(..table("*22"), lamps: [
      Lamp("ann", Some("sales-lamp@" <> realm), Some("101")),
    ])
  assert lamp_probe.resolve(qualified, "sales-lamp", realm) == Some("ann")
}

pub fn the_prefix_and_the_extension_test() {
  assert lamp_probe.resolve(table("*22"), "*22102", realm) == Some("bob")
}

/// The account's own prefix, and only it.
pub fn a_custom_prefix_test() {
  assert lamp_probe.resolve(table("*77"), "*77102", realm) == Some("bob")
  assert lamp_probe.resolve(table("*77"), "*22102", realm) == None
}

/// A user's plain presence id is their ordinary BLF: never answered.
pub fn a_plain_presence_id_is_left_alone_test() {
  assert lamp_probe.resolve(table("*22"), "101", realm) == None
  assert lamp_probe.resolve(table("*22"), "102", realm) == None

  // An override naming the agent's own address is not their lamp either.
  let own =
    Table(..table("*22"), lamps: [Lamp("ann", Some("101"), Some("101"))])
  assert lamp_probe.resolve(own, "101", realm) == None
  assert lamp_probe.resolve(own, "*22101", realm) == Some("ann")

  // An agent whose own extension happens to be another agent's lamp keeps
  // their ordinary BLF: the plain address wins.
  let clash =
    Table(..table("*22"), lamps: [
      Lamp("bob", None, Some("102")),
      Lamp("cat", None, Some("*22102")),
    ])
  assert lamp_probe.resolve(clash, "*22102", realm) == None
}

/// Every other BLF -- nobody's lamp -- is nobody's business here.
pub fn an_ordinary_blf_is_left_alone_test() {
  assert lamp_probe.resolve(table("*22"), "*22999", realm) == None
  assert lamp_probe.resolve(table("*22"), "999", realm) == None
  assert lamp_probe.resolve(table("*22"), "park+101", realm) == None
  assert lamp_probe.resolve(table("*22"), "", realm) == None
}

/// The realm has to be the account's, in whatever case the phone wrote it.
pub fn the_realm_test() {
  assert lamp_probe.resolve(table("*22"), "*22102", "other.example.test")
    == None
  assert lamp_probe.resolve(table("*22"), "*22102", "ONE.Example.test")
    == Some("bob")
}

/// An override is looked for before a prefixed extension.
pub fn an_override_comes_first_test() {
  let both =
    Table(..table("*22"), lamps: [
      Lamp("bob", None, Some("102")),
      Lamp("dan", Some("*22102"), Some("300")),
    ])
  assert lamp_probe.resolve(both, "*22102", realm) == Some("dan")
}

// --- The table, from the datastore -------------------------------------------

fn views() -> List(fake.View) {
  [
    fake.View(
      name: "callcenter/agents",
      doc_type: records.agent_type,
      key: fn(agent) {
        doc.get_string(agent, ["agent_id"]) |> result.map(doc.String)
      },
    ),
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

fn user(f: fake.Fake, user_id: String, presence_id: String, agent: Bool) {
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String(user_id)),
      #("pvt_type", doc.String("user")),
      #("presence_id", doc.String(presence_id)),
      #("call_center", case agent {
        True -> doc.object([#("agent_id", doc.String(user_id))])
        False -> doc.object([])
      }),
    ]),
  )
}

fn agent_doc(
  f: fake.Fake,
  agent_id: String,
  availability: String,
  override: Option(String),
) {
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object_some([
      #("_id", Some(doc.String(records.agent_document_id(agent_id)))),
      #("pvt_type", Some(doc.String(records.agent_type))),
      #("agent_id", Some(doc.String(agent_id))),
      #("availability", Some(doc.String(availability))),
      #("presence_id", option.map(override, doc.String)),
    ]),
  )
}

/// Ann (override `sales-lamp`, available), Bob (extension 102, on break),
/// and Carl, a user who is not an agent, at extension 103.
fn an_account() -> fake.Fake {
  let f = fake.new_with_views(views())
  fake.put_account(f, account, realm, [])
  user(f, "ann", "101", True)
  user(f, "bob", "102", True)
  user(f, "carl", "103", False)
  agent_doc(f, "ann", "available", Some("sales-lamp"))
  agent_doc(f, "bob", "on_break", None)
  f
}

pub fn an_unknown_realm_test() {
  let kz = fake.kazoo(an_account())
  assert lamp_probe.load(kz, "nobody.example.test") == None
}

/// An account with no agents is read with one query and answers nothing.
pub fn an_account_without_agents_test() {
  let f = fake.new_with_views(views())
  fake.put_account(f, account, realm, [])
  user(f, "carl", "103", False)
  let assert Some(read) = lamp_probe.load(fake.kazoo(f), realm)
  assert read.lamps == []
  assert lamp_probe.resolve(read, "*22103", realm) == None
  assert lamp_probe.resolve(read, "103", realm) == None
}

pub fn the_table_test() {
  let f = an_account()
  let assert Some(read) = lamp_probe.load(fake.kazoo(f), "One.Example.Test")
  assert read.account_id == account
  assert read.prefix == "*22"
  assert list.sort(
      list.map(read.lamps, fn(lamp) { lamp.agent_id }),
      string.compare,
    )
    == ["ann", "bob"]
  assert lamp_probe.resolve(read, "sales-lamp", realm) == Some("ann")
  assert lamp_probe.resolve(read, "*22102", realm) == Some("bob")
  // Carl is not an agent, and nobody's extension is a lamp.
  assert lamp_probe.resolve(read, "*22103", realm) == None
  assert lamp_probe.resolve(read, "102", realm) == None
}

/// The prefix is the account's, from `configs_callcenter`.
pub fn the_accounts_prefix_test() {
  let f = an_account()
  fake.put_doc(
    f,
    kazoo.account_db(account),
    doc.object([
      #("_id", doc.String("configs_callcenter")),
      #("agent_presence_prefix", doc.String("*88")),
    ]),
  )
  let assert Some(read) = lamp_probe.load(fake.kazoo(f), realm)
  assert read.prefix == "*88"
  assert lamp_probe.resolve(read, "*88102", realm) == Some("bob")
  assert lamp_probe.resolve(read, "*22102", realm) == None
}

// --- Answering ------------------------------------------------------------------

pub fn the_answer_is_the_availability_test() {
  let kz = fake.kazoo(an_account())
  let assert Some(ann) =
    lamp_probe.answer(kz, account, "ann", "sales-lamp@" <> realm, False)
  assert ann.id == "sales-lamp@" <> realm
  assert ann.state == presence.confirmed
  assert ann.call_id == presence.call_id("sales-lamp@" <> realm)

  let assert Some(bob) =
    lamp_probe.answer(kz, account, "bob", "*22102@" <> realm, False)
  assert bob.state == presence.terminated
}

pub fn on_a_queue_call_the_answer_is_early_test() {
  let kz = fake.kazoo(an_account())
  let assert Some(bob) =
    lamp_probe.answer(kz, account, "bob", "*22102@" <> realm, True)
  assert bob.state == presence.early
}

/// The address is checked again against the documents as they are now, so
/// a table a moment old publishes nowhere the agent has left -- and never on
/// a user's own address.
pub fn nothing_where_the_lamp_no_longer_is_test() {
  let kz = fake.kazoo(an_account())
  assert lamp_probe.answer(kz, account, "ann", "*22101@" <> realm, False)
    == None
  assert lamp_probe.answer(kz, account, "ann", "101@" <> realm, False) == None
  assert lamp_probe.answer(kz, account, "bob", "102@" <> realm, False) == None
  assert lamp_probe.answer(kz, account, "carl", "*22103@" <> realm, False)
    == None
}

// --- Who is on a queue call ----------------------------------------------------

fn no_holder() -> Result(List(doc.Value), amqp.Error) {
  panic as "the holder is asked only when the shard is somebody else's"
}

/// This node dispatches the account: its dispatcher says.
pub fn on_a_queue_call_here_test() {
  let c =
    cluster.new(
      [
        #(
          "support",
          doc.object([
            #("pvt_type", doc.String("queue")),
            #("strategy", doc.String("longest_idle")),
            #("agents", doc.List([doc.object([#("id", doc.String("ann"))])])),
          ]),
        ),
      ],
      [
        #(
          "ann",
          doc.object([
            #("pvt_type", doc.String("user")),
            #("call_center", doc.object([])),
          ]),
        ),
      ],
    )
  cluster.agent_is(c, "ann", "available")
  cluster.arrive(c, "call-one", "support", 0, 0)
  let here = lamp_probe.Here(c.dispatcher)
  // Rung is not on a call.
  assert lamp_probe.on_queue_call(here, no_holder) == []

  cluster.reply(
    c,
    "call-one",
    Answered("ann", "agent-leg", cluster.start_of_time),
  )
  assert lamp_probe.on_queue_call(here, no_holder) == ["ann"]
}

/// Held here with no dispatcher: nobody is waiting, so nobody is talking.
pub fn held_and_quiet_test() {
  assert lamp_probe.on_queue_call(lamp_probe.HeldQuiet, no_holder) == []
}

/// Held elsewhere: the holder's status answer says.
pub fn on_a_queue_call_elsewhere_test() {
  let answer =
    doc.object([
      #("Account-ID", doc.String(account)),
      #("Queues", doc.List([])),
      #("On-Queue-Call", doc.List([doc.String("ann")])),
    ])
  assert lamp_probe.on_queue_call(lamp_probe.Remote, fn() { Ok([answer]) })
    == ["ann"]
}

/// Nobody answered: nobody is on a queue call, which is the lamp's
/// availability state and not silence.
pub fn no_answer_from_the_holder_test() {
  assert lamp_probe.on_queue_call(lamp_probe.Remote, fn() {
      Error(amqp.NoAnswer)
    })
    == []
  assert lamp_probe.on_queue_call(lamp_probe.Remote, fn() { Ok([]) }) == []
}

// --- The actor ---------------------------------------------------------------------

type Clock {
  Set(Int)
  Get(Subject(Int))
}

fn clock() -> Subject(Clock) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(now, message) {
      case message {
        Set(to) -> actor.continue(to)
        Get(done) -> {
          process.send(done, now)
          actor.continue(now)
        }
      }
    })
    |> actor.start
  started.data
}

type Rig {
  Rig(
    probes: Subject(lamp_probe.Message),
    clock: Subject(Clock),
    loads: Subject(String),
    counts: Subject(String),
    answers: Subject(#(String, String, String, Bool)),
  )
}

/// The actor over fakes: `realm` is the account's, whose table is `read`;
/// Bob is on a queue call.
fn rig(read: Table) -> Rig {
  rig_hanging(read, False)
}

/// The same, with a first read that never comes back when `hang` is set.
fn rig_hanging(read: Table, hang: Bool) -> Rig {
  let loads = process.new_subject()
  let counts = process.new_subject()
  let answers = process.new_subject()
  let time = clock()
  let assert Ok(probes) =
    lamp_probe.start(lamp_probe.Deps(
      load: fn(probed) {
        process.send(loads, probed)
        case hang && process.call(time, 1000, Get) == 0 {
          True -> process.sleep_forever()
          False -> Nil
        }
        case string.lowercase(probed) == realm {
          True -> Some(read)
          False -> None
        }
      },
      on_queue_call: fn(account_id) {
        process.send(counts, account_id)
        ["bob"]
      },
      answer: fn(account_id, agent_id, address, on_queue_call) {
        process.send(answers, #(account_id, agent_id, address, on_queue_call))
      },
      now_ms: fn() { process.call(time, 1000, Get) },
      ttl_ms: 2000,
    ))
  Rig(probes, time, loads, counts, answers)
}

fn probe(rig: Rig, username: String, probed_realm: String) {
  process.send(rig.probes, lamp_probe.Probe(username, probed_realm))
}

fn drain(subject: Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 200) {
    Ok(one) -> drain(subject, [one, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn the_actor_answers_a_lamp_test() {
  let rig = rig(table("*22"))
  probe(rig, "sales-lamp", realm)
  probe(rig, "*22102", realm)
  let answers = drain(rig.answers, [])
  assert list.sort(answers, fn(a, b) { string.compare(a.1, b.1) })
    == [
      #(account, "ann", "sales-lamp@" <> realm, False),
      #(account, "bob", "*22102@" <> realm, True),
    ]
}

/// Plain presence ids, ordinary BLFs and unknown realms: no answer, and no
/// question about queue calls either.
pub fn the_actor_leaves_the_rest_alone_test() {
  let rig = rig(table("*22"))
  probe(rig, "101", realm)
  probe(rig, "102", realm)
  probe(rig, "*22999", realm)
  probe(rig, "*22102", "other.example.test")
  assert drain(rig.answers, []) == []
  assert drain(rig.counts, []) == []
}

/// An account with no agents answers nothing and asks nothing more.
pub fn the_actor_and_an_account_without_agents_test() {
  let rig = rig(Table(account, realm, "*22", []))
  probe(rig, "*22102", realm)
  probe(rig, "102", realm)
  assert drain(rig.answers, []) == []
  assert drain(rig.counts, []) == []
  assert drain(rig.loads, []) == [realm]
}

/// A storm: one read of the account while it is fresh, one question about
/// queue calls for the lamps found together, each lamp answered once.
pub fn a_storm_is_read_once_test() {
  let rig = rig(table("*22"))
  list.each(list.repeat(Nil, 50), fn(_) {
    probe(rig, "*22102", realm)
    probe(rig, "sales-lamp", realm)
    probe(rig, "103", realm)
  })
  let answers = drain(rig.answers, [])
  assert drain(rig.loads, []) == [realm]
  // Every lamp is answered, and the duplicates of one batch are one answer.
  assert list.unique(answers) |> list.length == 2
  assert list.length(drain(rig.counts, [])) <= list.length(answers)

  // Still fresh: nothing is read again.
  process.send(rig.clock, Set(1999))
  probe(rig, "*22102", realm)
  assert drain(rig.answers, []) == [#(account, "bob", "*22102@" <> realm, True)]
  assert drain(rig.loads, []) == []

  // Stale: read again.
  process.send(rig.clock, Set(2000))
  probe(rig, "*22102", realm)
  assert drain(rig.answers, []) == [#(account, "bob", "*22102@" <> realm, True)]
  assert drain(rig.loads, []) == [realm]
}

/// A read that never comes back does not leave its realm waiting for good:
/// past `stuck_ms` the next probe reads again, and what waited is answered.
pub fn a_stuck_read_is_started_again_test() {
  let rig = rig_hanging(table("*22"), True)
  probe(rig, "*22102", realm)
  probe(rig, "sales-lamp", realm)
  assert drain(rig.answers, []) == []

  process.send(rig.clock, Set(14_999))
  probe(rig, "*22102", realm)
  assert drain(rig.answers, []) == []
  assert drain(rig.loads, []) == [realm]

  process.send(rig.clock, Set(15_000))
  probe(rig, "*22102", realm)
  let answers = drain(rig.answers, [])
  assert list.sort(list.unique(answers), fn(a, b) { string.compare(a.1, b.1) })
    == [
      #(account, "ann", "sales-lamp@" <> realm, False),
      #(account, "bob", "*22102@" <> realm, True),
    ]
  assert drain(rig.loads, []) == [realm]
}

/// An unknown realm is remembered for as long as a table is.
pub fn an_unknown_realm_is_read_once_test() {
  let rig = rig(table("*22"))
  probe(rig, "*22102", "other.example.test")
  let _ = process.call(rig.probes, 1000, lamp_probe.Sync)
  probe(rig, "*22102", "other.example.test")
  assert drain(rig.loads, []) == ["other.example.test"]
  assert drain(rig.answers, []) == []
}

// --- The listener ------------------------------------------------------------------

pub fn a_dialog_probe_test() {
  let probe =
    doc.object([
      #("Event-Category", doc.String("presence")),
      #("Event-Name", doc.String("probe")),
      #("Event-Package", doc.String("dialog")),
      #("Username", doc.String("*22102")),
      #("Realm", doc.String(realm)),
      #("Call-ID", doc.String("subscribe-1")),
    ])
  assert lamp_probe.probe_of(probe) == Some(#("*22102", realm))
  assert lamp_probe.probe_of(doc.set(
      probe,
      ["Event-Package"],
      doc.String("presence"),
    ))
    == None
  assert lamp_probe.probe_of(doc.set(probe, ["Username"], doc.String("")))
    == None
  assert lamp_probe.probe_of(doc.set(probe, ["Event-Name"], doc.String("mwi")))
    == None
}

/// Dialog probes, off one queue every node shares: one node answers each.
pub fn the_listener_test() {
  let spec = listener.to_spec(lamp_probe.consumer())
  let bindings = dict.get(spec, "bindings") |> result.map(string.inspect)
  let assert Ok(bindings) = bindings
  assert string.contains(bindings, "probe_type")
  assert string.contains(bindings, "dialog")
  let assert Ok(queue) = dict.get(spec, "queue") |> result.map(string.inspect)
  assert string.contains(queue, lamp_probe.queue_name)
  assert dict.has_key(spec, "on_event")
}
