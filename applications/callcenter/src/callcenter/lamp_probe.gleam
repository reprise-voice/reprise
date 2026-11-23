//// Answering a presence probe for an agent's login lamp.
////
//// Kamailio keeps a dialog update only while somebody is subscribed to its
//// address, so a lamp nobody was watching when the agent last changed has
//// no state there. When a phone then subscribes -- a reboot, a newly
//// provisioned key, a new device -- Kamailio finds no presentity for the
//// address and asks: a `presence` `probe` with `Event-Package` `dialog`,
//// `Username` and `Realm` the subscription's To user and domain, on the
//// `presence` exchange under `probes.dialog` (`REQUEST_PROBE` in
//// `presence-role.cfg`). Without an answer the key shows idle until the
//// agent's next change. This answers with the lamp's current state.
////
//// ## Who answers
////
//// Every probe of every BLF on the cluster goes out under that one routing
//// key, so a queue of each node's own would hand every node every probe.
//// The queue is shared instead, `callcenter_lamp_probes`, as callflow's
//// `callflow_listener` is for the parking and manual-presence probes: one
//// node gets each probe and answers it. That node is any node running the
//// call center, so it asks the one that knows about queue calls: its own
//// dispatcher when it holds the account's shard, and otherwise the holder,
//// through the status query the Crossbar live view uses. No answer from a
//// holder is nobody on a queue call.
////
//// ## Whose lamp
////
//// The address is `Username@Realm`. The realm names the account. The
//// account's agents -- the users with a `callcenter_agent-<user_id>`
//// document, as for publishing -- each have one lamp address, worked out
//// by `presence.address_of` exactly as every publish works it out: a stored
//// override first, then `<prefix><presence_id>`. A probe is answered only
//// when its address is one of those. An address that is an agent user's own
//// presence address is never answered, whatever else matches it, so a
//// user's ordinary line and presence keys are left alone; so is every BLF
//// that is not an agent's lamp, which is nearly all of them.
////
//// ## What it costs
////
//// A reboot storm is hundreds of probes in a few seconds, nearly all of
//// them for ordinary BLFs. The listener only hands each one to an actor.
//// The actor reads an account's agents once and keeps them for
//// `table_ttl_ms`, including the answer that the realm is nobody's or the
//// account has no agents, which is the answer for most probes. Probes that
//// arrive while an account is being read wait for that read rather than
//// starting another, and the lamps found wait together for one question
//// about who is on a queue call. The state published is read when the
//// answer is made, from the agent's own document, not from what was kept.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import kazoo/accounts
import kazoo/amqp
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Kazoo}
import kazoo/listener.{Atom, Limited, Terms, Text}
import kazoo/util

import callcenter/agents
import callcenter/ask
import callcenter/availability
import callcenter/dispatcher
import callcenter/fields
import callcenter/presence
import callcenter/shard
import callcenter/shards
import callcenter/status_query
import callcenter/system

/// The shared queue every node consumes probes from.
pub const queue_name = "callcenter_lamp_probes"

/// How long an account's agents are kept once read.
pub const table_ttl_ms = 2000

/// How long the local dispatcher is given to say who is on a call.
const dispatcher_timeout_ms = 1000

const worker = "callcenter_lamp_probe"

// --- Whose lamp -------------------------------------------------------------

/// One agent, as far as their lamp's address goes: the override stored on
/// their `callcenter_agent` document and their user's `presence_id`.
pub type Lamp {
  Lamp(agent_id: String, override: Option(String), presence_id: Option(String))
}

/// An account's agents, read for answering probes.
pub type Table {
  Table(account_id: String, realm: String, prefix: String, lamps: List(Lamp))
}

/// The agent whose lamp is at `username@realm`, if any.
///
/// Nobody when the realm is not the account's, and nobody when the address
/// is an agent user's own presence address: that is their ordinary BLF,
/// which the lamp never takes. A stored override is looked for first, then
/// the prefixed presence id, which is the order `presence.address_of`
/// decides an agent's address in.
pub fn resolve(
  table: Table,
  username: String,
  realm: String,
) -> Option(String) {
  let address = username <> "@" <> table.realm
  let own = fn(lamp: Lamp) {
    case lamp.presence_id {
      Some(id) if id != "" -> id <> "@" <> table.realm == address
      _ -> False
    }
  }
  let lamp_address = fn(lamp: Lamp) {
    presence.address_of(
      override: lamp.override,
      presence_id: lamp.presence_id,
      prefix: table.prefix,
      realm: table.realm,
    )
  }
  let by_override = fn(lamp: Lamp) {
    case lamp.override {
      Some(stored) ->
        qualify(stored, table.realm) == address
        && lamp_address(lamp) == Ok(address)
      None -> False
    }
  }
  let by_prefix = fn(lamp: Lamp) { lamp_address(lamp) == Ok(address) }
  case
    username == "" || string.lowercase(realm) != string.lowercase(table.realm)
  {
    True -> None
    False ->
      case list.any(table.lamps, own) {
        True -> None
        False ->
          list.find(table.lamps, by_override)
          |> result.lazy_or(fn() { list.find(table.lamps, by_prefix) })
          |> result.map(fn(lamp) { lamp.agent_id })
          |> option.from_result
      }
  }
}

fn qualify(id: String, realm: String) -> String {
  case string.contains(id, "@") {
    True -> id
    False -> id <> "@" <> realm
  }
}

/// The account a probe's realm names, and its agents. `None` when the realm
/// is nobody's or the account has no realm to address anything in.
pub fn load(kz: Kazoo, realm: String) -> Option(Table) {
  case accounts.id_for_realm(kz, realm) {
    Error(_) -> None
    Ok(account_id) -> table(kz, account_id)
  }
}

/// An account's agents. An account with none has an empty table, read with
/// one view query: the agent listing and the prefix are read only when
/// there is somebody to use them for.
pub fn table(kz: Kazoo, account_id: String) -> Option(Table) {
  use realm <- option.then(presence.realm(kz, account_id))
  let documents =
    kz.datamgr.get_results(
      kazoo.account_db(account_id),
      "callcenter/agents",
      kazoo.view_options() |> kazoo.with_docs,
    )
    |> result.unwrap([])
    |> list.filter_map(agents.document)
  case documents {
    [] -> Some(Table(account_id, realm, presence.default_prefix, []))
    _ -> {
      let presence_ids = presence_ids(kz, account_id)
      Some(Table(
        account_id: account_id,
        realm: realm,
        prefix: presence.prefix(kz, account_id),
        lamps: list.filter_map(documents, fn(document) {
          use agent_id <- result.map(doc.get_string(document, ["agent_id"]))
          Lamp(
            agent_id: agent_id,
            override: presence.stored(document),
            presence_id: dict.get(presence_ids, agent_id) |> option.from_result,
          )
        }),
      ))
    }
  }
}

/// The agents' user presence ids, off the agent listing, whose rows carry
/// them.
fn presence_ids(kz: Kazoo, account_id: String) -> Dict(String, String) {
  kz.datamgr.get_results(
    kazoo.account_db(account_id),
    agents.listing,
    kazoo.view_options(),
  )
  |> result.unwrap([])
  |> list.filter_map(fn(row) {
    case
      doc.get_string(row, ["id"]),
      doc.get_string(row, ["value", "presence_id"])
    {
      Ok(user_id), Ok(presence_id) if presence_id != "" ->
        Ok(#(user_id, presence_id))
      _, _ -> Error(Nil)
    }
  })
  |> dict.from_list
}

// --- Who is on a queue call ---------------------------------------------------

/// Where the account's queue calls are known.
pub type Holder {
  /// This node holds the shard and dispatches the account.
  Here(dispatcher: Subject(dispatcher.Message))
  /// This node holds the shard and nobody is waiting in the account: nobody
  /// is on a queue call either, or there would be a dispatcher.
  HeldQuiet
  /// Another node, or none.
  Remote
}

/// The agents on a queue call, from whoever knows. `ask_holder` is the
/// status query, asked only when the shard is somebody else's; no answer is
/// nobody.
pub fn on_queue_call(
  holder: Holder,
  ask_holder: fn() -> Result(List(Value), amqp.Error),
) -> List(String) {
  case holder {
    Here(to) ->
      ask.call(to, dispatcher_timeout_ms, dispatcher.OnQueueCall)
      |> result.unwrap([])
    HeldQuiet -> []
    Remote ->
      case ask_holder() {
        Ok(answers) -> status_query.on_queue_call(answers)
        Error(_) -> []
      }
  }
}

/// Where the account's queue calls are known, seen from this node.
pub fn holder(account_id: String, count: Int) -> Holder {
  let shard_id = shards.of_account(account_id, count)
  case shard.dispatcher(shard_id, account_id) {
    Ok(to) -> Here(to)
    Error(Nil) ->
      case shard.held(shard_id) {
        Some(_held) -> HeldQuiet
        None -> Remote
      }
  }
}

// --- Answering --------------------------------------------------------------

/// Publish the lamp's state on the probed address. The address is worked
/// out again from the documents as they are now, and nothing is published
/// unless it is still the agent's: the table it was found in may be a
/// couple of seconds old.
pub fn answer(
  kz: Kazoo,
  account_id: String,
  agent_id: String,
  address: String,
  on_queue_call: Bool,
) -> Option(presence.Presence) {
  case presence.address(kz, account_id, agent_id) {
    Ok(current) ->
      case string.lowercase(current) == string.lowercase(address) {
        False -> None
        True ->
          case availability.get(kz, account_id, agent_id) {
            Error(_) -> None
            Ok(agent) ->
              Some(
                presence.send(presence.update(
                  current,
                  presence.state(agent.availability, on_queue_call:),
                )),
              )
          }
      }
    Error(_) -> None
  }
}

// --- The actor --------------------------------------------------------------

/// What the actor does its work with: the live ones on a node, fakes in a
/// test.
pub type Deps {
  Deps(
    /// A realm's account and agents.
    load: fn(String) -> Option(Table),
    /// The agents on a queue call in an account.
    on_queue_call: fn(String) -> List(String),
    /// Publish one answer: account, agent, address, on a queue call.
    answer: fn(String, String, String, Bool) -> Nil,
    /// A clock in milliseconds.
    now_ms: fn() -> Int,
    ttl_ms: Int,
  )
}

pub type Message {
  /// A dialog probe for `username@realm`.
  Probe(username: String, realm: String)
  /// A realm's table, read.
  Loaded(realm: String, table: Option(Table))
  /// Who is on a queue call in an account, found out.
  Counted(account_id: String, on_queue_call: List(String))
  /// Answered once everything sent before it has been handled, for a test.
  Sync(done: Subject(Nil))
}

/// A worker's errand, and what waits on it. One that has run longer than
/// `stuck_ms` is taken to have died and is started again, keeping what
/// waits: a worker is unlinked, and one that crashed on a datastore would
/// otherwise leave its realm or account waiting for good.
type Pending(a) {
  Pending(since: Int, waiting: List(a))
}

/// Longer than the slowest errand: a shard actor asked for five seconds and
/// the status query's three.
const stuck_ms = 15_000

type State {
  State(
    deps: Deps,
    self: Subject(Message),
    /// Realm, in lower case, to when it was read and what was found.
    tables: Dict(String, #(Int, Option(Table))),
    /// Realm to the usernames probed while it is being read.
    loading: Dict(String, Pending(String)),
    /// Account to the agents and addresses found while its queue calls are
    /// being asked about.
    counting: Dict(String, Pending(#(String, String))),
  )
}

/// Start the actor, unnamed.
pub fn start(deps: Deps) -> Result(Subject(Message), actor.StartError) {
  new(deps, None)
}

fn new(
  deps: Deps,
  name: Option(process.Name(Message)),
) -> Result(Subject(Message), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    actor.initialised(State(deps, self, dict.new(), dict.new(), dict.new()))
    |> actor.selecting(process.new_selector() |> process.select(self))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> fn(builder) {
    case name {
      Some(name) -> actor.named(builder, name)
      None -> builder
    }
  }
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Probe(username, realm) -> actor.continue(probed(state, username, realm))

    Loaded(realm, table) -> {
      let key = string.lowercase(realm)
      let now = state.deps.now_ms()
      let waiting = case dict.get(state.loading, key) {
        Ok(pending) -> list.reverse(pending.waiting)
        Error(Nil) -> []
      }
      let state =
        State(
          ..state,
          // What has gone stale is dropped as it is replaced, so that the
            // realms of a storm long over are not kept.
            tables: state.tables
            |> dict.filter(fn(_realm, read) { now - read.0 < state.deps.ttl_ms })
            |> dict.insert(key, #(now, table)),
          loading: dict.delete(state.loading, key),
        )
      actor.continue(
        list.fold(waiting, state, fn(state, username) {
          found(state, table, username, realm)
        }),
      )
    }

    Counted(account_id, on_queue_call) -> {
      let waiting = case dict.get(state.counting, account_id) {
        Ok(pending) -> pending.waiting |> list.reverse |> list.unique
        Error(Nil) -> []
      }
      let answer = state.deps.answer
      let _ =
        process.spawn_unlinked(fn() {
          list.each(waiting, fn(found) {
            let #(agent_id, address) = found
            answer(
              account_id,
              agent_id,
              address,
              list.contains(on_queue_call, agent_id),
            )
          })
        })
      actor.continue(
        State(..state, counting: dict.delete(state.counting, account_id)),
      )
    }

    Sync(done) -> {
      process.send(done, Nil)
      actor.continue(state)
    }
  }
}

/// Add to what waits on an errand, starting the errand when nothing is
/// running it.
fn wait(
  pending: Dict(String, Pending(a)),
  key: String,
  item: a,
  now: Int,
  run: fn() -> Nil,
) -> Dict(String, Pending(a)) {
  case dict.get(pending, key) {
    Ok(Pending(since, waiting)) if now - since < stuck_ms ->
      dict.insert(pending, key, Pending(since, [item, ..waiting]))
    Ok(Pending(_stuck, waiting)) -> {
      run()
      dict.insert(pending, key, Pending(now, [item, ..waiting]))
    }
    Error(Nil) -> {
      run()
      dict.insert(pending, key, Pending(now, [item]))
    }
  }
}

fn probed(state: State, username: String, realm: String) -> State {
  let key = string.lowercase(realm)
  let now = state.deps.now_ms()
  case dict.get(state.tables, key) {
    Ok(#(read_at, table)) if now - read_at < state.deps.ttl_ms ->
      found(state, table, username, realm)
    _stale_or_never_read -> {
      let load = state.deps.load
      let self = state.self
      State(
        ..state,
        loading: wait(state.loading, key, username, now, fn() {
          let _ =
            process.spawn_unlinked(fn() {
              process.send(self, Loaded(realm, load(realm)))
            })
          Nil
        }),
      )
    }
  }
}

fn found(
  state: State,
  table: Option(Table),
  username: String,
  realm: String,
) -> State {
  case option.then(table, resolve(_, username, realm)), table {
    Some(agent_id), Some(table) -> {
      let count = state.deps.on_queue_call
      let self = state.self
      let account_id = table.account_id
      let entry = #(agent_id, username <> "@" <> table.realm)
      State(
        ..state,
        counting: wait(
          state.counting,
          account_id,
          entry,
          state.deps.now_ms(),
          fn() {
            let _ =
              process.spawn_unlinked(fn() {
                process.send(self, Counted(account_id, count(account_id)))
              })
            Nil
          },
        ),
      )
    }
    _, _ -> state
  }
}

// --- On a node --------------------------------------------------------------

/// What a node answers with.
pub fn live(kz: Kazoo, count: Int) -> Deps {
  Deps(
    load: fn(realm) { load(kz, realm) },
    on_queue_call: fn(account_id) {
      on_queue_call(holder(account_id, count), fn() {
        status_query.ask(account_id, None)
      })
    },
    answer: fn(account_id, agent_id, address, on_queue_call) {
      case answer(kz, account_id, agent_id, address, on_queue_call) {
        Some(published) ->
          system.log(
            "answered the probe for "
            <> address
            <> ", agent "
            <> agent_id
            <> "'s login lamp, with "
            <> published.state,
          )
        None -> Nil
      }
    },
    now_ms: monotonic_ms,
    ttl_ms: table_ttl_ms,
  )
}

/// The actor and the listener that feeds it, as supervised children.
pub fn supervised(
  kz: Kazoo,
  count: Int,
) -> List(supervision.ChildSpecification(Nil)) {
  [
    supervision.worker(fn() {
      new(live(kz, count), Some(util.name(worker)))
      |> result.map(fn(subject) {
        let assert Ok(pid) = process.subject_owner(subject)
        actor.Started(pid: pid, data: Nil)
      })
    }),
    consumer()
      |> listener.supervised
      |> supervision.map_data(fn(_server) { Nil }),
  ]
}

/// The listener, described and not started: dialog probes, off the queue
/// every node shares, handed to the actor.
pub fn consumer() -> listener.Listener {
  listener.new()
  |> listener.binding("presence", [
    listener.prop("restrict_to", Terms([Atom("probe")])),
    listener.prop("probe_type", Text("dialog")),
  ])
  |> listener.queue(
    name: queue_name,
    durable: False,
    exclusive: False,
    auto_delete: True,
    // A probe answered late still lights a key that would otherwise wait
    // for the agent's next change; one a minute old is from a phone that
    // has given up on it. The default of a hundred messages is less than
    // one reboot storm.
    ttl: Limited(60_000),
    max_length: Limited(10_000),
  )
  |> listener.on_event(fn(event, _delivery) {
    case probe_of(event) {
      Some(#(username, realm)) ->
        process.send(
          process.named_subject(util.name(worker)),
          Probe(username, realm),
        )
      None -> Nil
    }
  })
}

/// The username and realm of a dialog probe, or nothing for anything else.
pub fn probe_of(event: Value) -> Option(#(String, String)) {
  case
    doc.get_string(event, ["Event-Name"]),
    doc.get_string(event, ["Event-Package"]),
    fields.some_string(event, ["Username"]),
    fields.some_string(event, ["Realm"])
  {
    Ok("probe"), Ok("dialog"), Some(username), Some(realm) ->
      Some(#(username, realm))
    _, _, _, _ -> None
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
