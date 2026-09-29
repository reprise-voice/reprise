//// The durable record of what happened: the `queue_call` and
//// `agent_status_change` documents, and the counters on `callcenter_agent`.
////
//// Requirement 0.4 and 1.9: history is in the monthly account database as it
//// happens, never only in a process. A caller's whole passage through a
//// queue is one `queue_call` document, keyed by the passage -- call id,
//// queue and the second they joined, see `passage_id` -- and written to the
//// month they joined in, so a member redelivered to another node keeps the
//// document they already had and a caller who moves on to a second queue
//// gets a second one. Every availability change is one
//// `agent_status_change` document, which is the status log in 1.7.
////
//// All of it goes through one writer actor per node. Two reasons, and the
//// second is the important one:
////
//// - The dispatcher must not wait on a database. An offer that took 200 ms
////   because a document was slow to save is 200 ms in which no other caller
////   in that account is connected.
//// - A document is read, changed and written, and two of those interleaved
////   lose one of the changes. Serialising them on one process is the cheapest
////   version of that which does not need a conflict loop.
////
//// A write the datastore did not take is held and tried again
//// (`callcenter/records/backlog`): in order per document, once however
//// often it is tried, for up to an hour. Dispatch carries on meanwhile,
//// which is requirement 0.5's "database unavailable" row. A write that lost
//// a race with another node's -- the `callcenter_agent` document is also
//// written by `callcenter/availability` -- is read and made again at once.

import callcenter/ask
import callcenter/call/originate
import callcenter/records/backlog.{type Backlog, type Failure, Pending, Refused}
import callcenter/system
import callcenter/types.{
  type CancelReason, type EndResult, type Member, type OfferId, AgentHangup,
  CallerHangup, Completed, ExitKey, FailedBridge, Hangup, NoAgentTimeout,
  Quarantined, QueueDeleted, QueueFull, Timeout, Transfer, Transferred,
}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, type Kazoo, Invalid, NotFound}
import kazoo/listener
import kazoo/modb
import kazoo/util

/// The `pvt_type` of a caller's passage through a queue.
pub const queue_call_type = "queue_call"

/// The `pvt_type` of one availability change.
pub const status_change_type = "agent_status_change"

/// The `pvt_type` of an agent's availability document.
pub const agent_type = "callcenter_agent"

/// Where a document lives.
pub type Where {
  /// The account's database, by document id.
  Account(account_id: String)
  /// The month `at` falls in, by document id.
  Month(account_id: String, at: Int)
}

/// One change to one document: read it, change it, write it back.
pub type Edit {
  Change(
    where: Where,
    doc_id: String,
    kind: String,
    update: fn(Option(Value)) -> Value,
  )
  /// The same for a caller's `queue_call`, which is found by its passage
  /// and, when `legacy` is set and nothing is there, by the call id alone:
  /// see `passage_id`.
  ChangePassage(
    member: Member,
    legacy: Bool,
    update: fn(Option(Value)) -> Value,
  )
}

pub type Message {
  Write(Edit)
  /// Try the writes held again.
  Retry
  /// Answer once everything sent before this has been written, or is held
  /// for the datastore to come back: what a test and `sup` need and nothing
  /// on the call path does.
  Flush(done: Subject(Nil))
  Stop(done: Subject(Nil))
}

/// What the writer reads and writes through: the datastore on a node, a
/// map with faults in the tests.
pub type Store {
  Store(
    /// One document, by where and id.
    read: fn(Where, String) -> Result(Value, Error),
    /// One document, by where, id and `pvt_type`. The document carries its
    /// `_id`, and its `_rev` when it replaces one.
    save: fn(Where, String, String, Value) -> Result(Nil, Error),
  )
}

/// The datastore a node writes to.
pub fn live_store(kz: Kazoo) -> Store {
  Store(
    read: fn(where, doc_id) {
      case where {
        Account(account_id) ->
          kz.datamgr.open_doc(kazoo.account_db(account_id), doc_id)
        Month(account_id, at) -> modb.open_doc(account_id, doc_id, at: Some(at))
      }
    },
    save: fn(where, _doc_id, kind, document) {
      case where {
        Account(account_id) ->
          kz.datamgr.save_doc(
            kazoo.account_db(account_id),
            document
              |> doc.set(["pvt_type"], doc.String(kind))
              |> doc.set(["pvt_account_id"], doc.String(account_id)),
          )
        Month(account_id, at) ->
          modb.save_doc(account_id, document, kind: kind, at: Some(at))
      }
      |> result.replace(Nil)
    },
  )
}

pub fn name() -> Name(Message) {
  util.name("callcenter_records")
}

fn subject() -> Subject(Message) {
  process.named_subject(name())
}

fn running() -> Bool {
  case process.named(name()) {
    Ok(_pid) -> True
    Error(_) -> False
  }
}

fn send(edit: Edit) -> Nil {
  case running() {
    False -> Nil
    True -> process.send(subject(), Write(edit))
  }
}

/// Wait until everything asked for so far has been written, or is held for
/// the datastore to come back.
///
/// Through `callcenter/ask`: a writer that is stuck on a datastore, or that
/// is restarting, is logged and waited for no longer, rather than being the
/// crash of whoever asked.
pub fn flush() -> Nil {
  case running() {
    False -> Nil
    True ->
      case ask.call(subject(), 30_000, Flush) {
        Ok(Nil) -> Nil
        Error(failure) ->
          system.log_error(
            "the record writer did not flush: " <> ask.describe(failure),
          )
      }
  }
}

// --- The actor -------------------------------------------------------------

type State {
  State(
    self: Subject(Message),
    writer: Writer,
    now_ms: fn() -> Int,
    /// A `Retry` is on its way.
    retrying: Bool,
  )
}

pub fn supervised(kz: Kazoo) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start(kz) })
  |> supervision.map_data(fn(_started) { Nil })
}

pub fn start(
  kz: Kazoo,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  // The ids of this writer's writes: unique to it among every writer that
  // ever wrote a document, so that a document never shows another's write
  // as this one's.
  start_with(Some(name()), live_store(kz), kz.random(12) <> "-", monotonic_ms)
}

/// Start one: named on a node, anonymous over a test's store and clock.
pub fn start_with(
  name: Option(Name(Message)),
  store: Store,
  prefix: String,
  now_ms: fn() -> Int,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  let builder =
    actor.new_with_initialiser(1000, fn(self) {
      actor.initialised(State(
        self: self,
        writer: writer(store, prefix),
        now_ms: now_ms,
        retrying: False,
      ))
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Write(edit) ->
      State(..state, writer: write(state.writer, edit, state.now_ms()))
      |> scheduled
      |> actor.continue
    Retry ->
      State(
        ..state,
        retrying: False,
        writer: retry(state.writer, state.now_ms()),
      )
      |> scheduled
      |> actor.continue
    Flush(done) -> {
      process.send(done, Nil)
      actor.continue(state)
    }
    Stop(done) -> {
      case held(state.writer) {
        0 -> Nil
        count ->
          system.log_error(
            "the record writer stopped holding "
            <> int.to_string(count)
            <> " write(s) the datastore never took; they are lost",
          )
      }
      process.send(done, Nil)
      actor.stop()
    }
  }
}

/// A `Retry` sent after the writer's wait, when it holds writes and none is
/// on its way.
fn scheduled(state: State) -> State {
  case state.retrying, retry_in(state.writer) {
    False, Some(wait_ms) -> {
      process.send_after(state.self, wait_ms, Retry)
      State(..state, retrying: True)
    }
    _, _ -> state
  }
}

// --- The writer ------------------------------------------------------------

/// The writer's state, apart from its process: what it writes through, the
/// writes it holds and how long it waits before trying them again. A test
/// drives it directly, with a clock of its own.
pub opaque type Writer {
  Writer(
    store: Store,
    /// Every write's id is this and a number.
    prefix: String,
    serial: Int,
    held: Backlog(Edit),
    /// The last write tried did not reach the datastore. Until one does,
    /// a new write is held without being tried: a writer that tried each
    /// one against a datastore that answers in its connect timeout would
    /// fall minutes behind its mailbox.
    away: Bool,
    wait_ms: Int,
  )
}

pub fn writer(store: Store, prefix: String) -> Writer {
  Writer(
    store: store,
    prefix: prefix,
    serial: 0,
    held: backlog.new(),
    away: False,
    wait_ms: backlog.first_retry_ms,
  )
}

/// How many writes are held.
pub fn held(writer: Writer) -> Int {
  backlog.size(writer.held)
}

/// How long until the writes held are tried again; `None` when none is.
pub fn retry_in(writer: Writer) -> Option(Int) {
  case backlog.size(writer.held) {
    0 -> None
    _held -> Some(writer.wait_ms)
  }
}

/// Write one change: now, or -- when the datastore is away, or the document
/// has a write held that it must follow -- once the writes held are tried
/// again.
pub fn write(writer: Writer, edit: Edit, now_ms: Int) -> Writer {
  let id = writer.prefix <> int.to_string(writer.serial)
  let writer = Writer(..writer, serial: writer.serial + 1)
  let key = key_of(edit)
  let pending = Pending(id: id, write: edit, since_ms: now_ms)
  case writer.away || backlog.holds(writer.held, key) {
    True -> hold(writer, key, pending)
    False ->
      case attempt(writer.store, id, edit) {
        Ok(Nil) -> writer
        Error(#(Refused, reason)) -> {
          given_up(edit, reason)
          writer
        }
        Error(#(_away, reason)) -> {
          system.log_error(
            "the datastore did not take a write ("
            <> reason
            <> "); holding writes and trying again",
          )
          hold(Writer(..writer, away: True), key, pending)
        }
      }
  }
}

fn hold(writer: Writer, key: String, pending: backlog.Pending(Edit)) -> Writer {
  let #(held, dropped) = backlog.add(writer.held, key, pending, backlog.most)
  list.each(dropped, fn(pending) {
    given_up(pending.write, "more than the most writes held")
  })
  Writer(..writer, held: held)
}

/// Try the writes held: every document's in turn, each document's oldest
/// first, until the datastore does not take one. That document goes to
/// the back, and the round is over.
pub fn retry(writer: Writer, now_ms: Int) -> Writer {
  let #(held, expired) = backlog.expire(writer.held, now_ms, backlog.oldest_ms)
  list.each(expired, fn(pending) {
    given_up(pending.write, "held longer than the longest a write is held")
  })
  round(Writer(..writer, held: held), backlog.size(held))
}

fn round(writer: Writer, before: Int) -> Writer {
  case backlog.next(writer.held) {
    None -> {
      // Nothing left, and nothing tried when every write held had expired:
      // the next write finds out whether the datastore is back.
      case writer.away, before {
        True, tried if tried > 0 ->
          system.log(
            "the datastore is back: "
            <> int.to_string(tried)
            <> " held write(s) done",
          )
        _, _ -> Nil
      }
      Writer(..writer, away: False, wait_ms: backlog.first_retry_ms)
    }
    Some(#(key, pending)) ->
      case attempt(writer.store, pending.id, pending.write) {
        Ok(Nil) ->
          round(Writer(..writer, held: backlog.done(writer.held, key)), before)
        Error(#(Refused, reason)) -> {
          given_up(pending.write, reason)
          round(Writer(..writer, held: backlog.done(writer.held, key)), before)
        }
        Error(#(_away, _reason)) ->
          Writer(
            ..writer,
            held: backlog.later(writer.held, key),
            away: True,
            wait_ms: backlog.backoff(writer.wait_ms),
          )
      }
  }
}

fn given_up(edit: Edit, reason: String) -> Nil {
  let #(kind, doc_id) = case edit {
    Change(_where, doc_id, kind, _update) -> #(kind, doc_id)
    ChangePassage(member, _legacy, _update) -> #(
      queue_call_type,
      passage_id(member),
    )
  }
  system.log_error(
    "could not write " <> kind <> " " <> doc_id <> ", given up: " <> reason,
  )
}

/// The document a change is to, for keeping changes to one document in
/// order.
fn key_of(edit: Edit) -> String {
  case edit {
    Change(Account(account_id), doc_id, _kind, _update) ->
      "account/" <> account_id <> "/" <> doc_id
    Change(Month(account_id, _at), doc_id, _kind, _update) ->
      "month/" <> account_id <> "/" <> doc_id
    ChangePassage(member, _legacy, _update) ->
      "passage/" <> member.account_id <> "/" <> passage_id(member)
  }
}

/// One write, read again and made again at once when it lost a race, up to
/// `backlog.races` times; a write that keeps losing waits with the rest.
fn attempt(
  store: Store,
  id: String,
  edit: Edit,
) -> Result(Nil, #(Failure, String)) {
  attempt_racing(store, id, edit, backlog.races)
}

fn attempt_racing(
  store: Store,
  id: String,
  edit: Edit,
  left: Int,
) -> Result(Nil, #(Failure, String)) {
  case try_once(store, id, edit) {
    Error(#(backlog.Raced, _reason)) if left > 1 ->
      attempt_racing(store, id, edit, left - 1)
    Error(#(backlog.Raced, reason)) -> Error(#(backlog.Away, reason))
    tried -> tried
  }
}

/// Read the document, and write the change unless it is already there.
///
/// The written document replaces the one read: it carries its `_rev`,
/// whether or not the change kept it, so a change that builds its document
/// afresh (`status_change`) replaces one written twice rather than failing
/// on it for ever.
fn try_once(
  store: Store,
  id: String,
  edit: Edit,
) -> Result(Nil, #(Failure, String)) {
  use #(where, doc_id, kind, existing) <- result.try(found(store, edit))
  case backlog.stamped(existing, id) {
    True -> Ok(Nil)
    False -> {
      let document =
        update_of(edit)(existing)
        |> backlog.stamp(existing, id)
        |> doc.set(["_id"], doc.String(doc_id))
      let document = case
        option.then(existing, fn(existing) {
          doc.get_string(existing, ["_rev"]) |> option.from_result
        })
      {
        Some(rev) -> doc.set(document, ["_rev"], doc.String(rev))
        None -> document
      }
      store.save(where, doc_id, kind, document)
      |> result.map_error(failed)
    }
  }
}

/// Where the change's document is, its id, its `pvt_type`, and what it
/// holds now.
fn found(
  store: Store,
  edit: Edit,
) -> Result(#(Where, String, String, Option(Value)), #(Failure, String)) {
  case edit {
    Change(where, doc_id, kind, _update) -> {
      use existing <- result.map(read_through(store, where, doc_id))
      #(where, doc_id, kind, existing)
    }
    ChangePassage(member, legacy, _update) -> {
      let where = Month(member.account_id, member.joined)
      use #(doc_id, existing) <- result.map(
        locate_through(member, legacy, read_through(store, where, _)),
      )
      #(where, doc_id, queue_call_type, existing)
    }
  }
}

fn update_of(edit: Edit) -> fn(Option(Value)) -> Value {
  case edit {
    Change(update: update, ..) -> update
    ChangePassage(update: update, ..) -> update
  }
}

/// One document, `None` when it is not there. A read over a database that
/// is not there -- a month nothing was written to yet -- is a document that
/// is not there; the write makes it.
fn read_through(
  store: Store,
  where: Where,
  doc_id: String,
) -> Result(Option(Value), #(Failure, String)) {
  store.read(where, doc_id)
  |> absent_as_none
  |> result.map_error(failed)
}

/// A read of one document, with the document not being there -- or its
/// database not being there, a month nothing was written to yet -- told
/// apart from the datastore not answering: the first is `Ok(None)`, and
/// anything else the datastore said is the error it was.
///
/// The writer and `read` both need the difference. A write that took a
/// datastore that did not answer for a passage with no document would
/// start the document over; a takeover that took it for a passage with no
/// record would take an answered call for a caller who hung up, and a
/// passage that is over for one to offer again.
pub fn absent_as_none(
  read: Result(Value, Error),
) -> Result(Option(Value), Error) {
  case read {
    Ok(document) -> Ok(Some(document))
    Error(NotFound) | Error(Invalid("db_not_found")) -> Ok(None)
    Error(error) -> Error(error)
  }
}

fn failed(error: Error) -> #(Failure, String) {
  #(backlog.failure(error), kazoo.error_to_string(error))
}

// --- The caller's passage through a queue ----------------------------------

/// The id of a caller's `queue_call` document: `<call id>-<queue id>-<joined>`,
/// the second they joined in Gregorian seconds, in the month they joined.
///
/// One document per passage. Everything in it is on the member message, so
/// a node that never saw the caller -- a redelivery, the sweep rebuilding an
/// answered call from its record -- addresses the same document as the node
/// that wrote it. A caller who times out of one queue into another, or is
/// sent round the same queue again, has a new `joined` and a document of
/// their own.
///
/// Releases before this one keyed the document by the call id alone, and a
/// re-entry reused it. A call id document is still read and written for the
/// passage it belongs to (`of_passage`) when the passage has none of its
/// own: a caller who was waiting, or talking, across the upgrade keeps the
/// document their passage began in. A first delivery never looks, since
/// nothing was written for it before. Once no call id document can still be
/// open -- the sweep reads the current month only, so a month after the
/// upgrade -- the fallback finds nothing and can go.
pub fn passage_id(member: Member) -> String {
  member.call_id
  <> "-"
  <> member.queue_id
  <> "-"
  <> int.to_string(member.joined)
}

/// The document a passage is in, by id, and what it holds now: its own, or
/// -- when `legacy` allows the look and there is none of its own -- the call
/// id document an earlier release wrote, if that is this passage's. Neither
/// is the passage's own id and nothing yet.
///
/// `lookup` reads one document of the passage's month by id.
pub fn locate(
  member: Member,
  legacy: Bool,
  lookup: fn(String) -> Option(Value),
) -> #(String, Option(Value)) {
  let found: Result(#(String, Option(Value)), Nil) =
    locate_through(member, legacy, fn(doc_id) { Ok(lookup(doc_id)) })
  result.unwrap(found, #(passage_id(member), None))
}

/// `locate` over a `lookup` that can fail, failing with it: the writer's and
/// `read`'s, neither of which may take a datastore that did not answer for a
/// passage with no document yet.
pub fn locate_through(
  member: Member,
  legacy: Bool,
  lookup: fn(String) -> Result(Option(Value), e),
) -> Result(#(String, Option(Value)), e) {
  let id = passage_id(member)
  use own <- result.try(lookup(id))
  case own, legacy {
    Some(document), _ -> Ok(#(id, Some(document)))
    None, False -> Ok(#(id, None))
    None, True -> {
      use earlier <- result.map(lookup(member.call_id))
      case earlier {
        Some(document) ->
          case of_passage(document, member) {
            True -> #(member.call_id, Some(document))
            False -> #(id, None)
          }
        None -> #(id, None)
      }
    }
  }
}

/// Whether two members are the same passage, and so the same document.
pub fn same_passage(one: Member, other: Member) -> Bool {
  passage_id(one) == passage_id(other)
}

/// Whether a call id document an earlier release wrote is this member's
/// passage: the same queue, joined the same second. Anything else is an
/// earlier passage of the same call, which a re-entry in that release took
/// over and left carrying the first queue's id and times.
pub fn of_passage(document: Value, member: Member) -> Bool {
  doc.get_string(document, ["queue_id"]) == Ok(member.queue_id)
  && doc.get_int(document, ["joined"]) == Ok(member.joined)
}

/// A caller entered a queue.
///
/// Written once per passage: a member redelivered to another node finds the
/// document the first node wrote and changes nothing.
pub fn joined(member: Member) -> Nil {
  send(ChangePassage(
    member,
    // Only a redelivery can have been written by an earlier release.
    listener.redelivered(member.delivery),
    fn(existing) {
      case existing {
        // Already there: this is a re-entry, not an arrival.
        Some(document) -> document
        None ->
          doc.object_some([
            #("call_id", Some(doc.String(member.call_id))),
            #("queue_id", Some(doc.String(member.queue_id))),
            #("joined", Some(doc.Int(member.joined))),
            #("caller_id_name", option.map(member.caller_id_name, doc.String)),
            #(
              "caller_id_number",
              option.map(member.caller_id_number, doc.String),
            ),
            #("offered_to", Some(doc.List([]))),
          ])
      }
    },
  ))
}

/// The caller is being offered to an agent, by the offer `id`. The entry
/// carries what that offer's legs' call ids start with (`originate.leg_prefix`):
/// what tells whoever takes the caller over an answer from that ring from a
/// bridge to anybody else.
pub fn offered(member: Member, agent_id: String, at: Int, id: OfferId) -> Nil {
  let leg_prefix = originate.leg_prefix(id)
  change_queue_call(member, fn(document) {
    let offers = doc.get_list(document, ["offered_to"]) |> result.unwrap([])
    doc.set(
      document,
      ["offered_to"],
      doc.List(
        list.append(offers, [
          doc.object([
            #("agent_id", doc.String(agent_id)),
            #("at", doc.Int(at)),
            #("leg_prefix", doc.String(leg_prefix)),
          ]),
        ]),
      ),
    )
  })
}

/// How the last offer to an agent turned out: `answered`, `no_answer`,
/// `busy`, `reject` or `cancelled` -- the last also for an agent whose
/// phone was ringing when somebody else answered.
pub fn offer_outcome(member: Member, agent_id: String, outcome: String) -> Nil {
  change_queue_call(member, offer_closed(_, agent_id, outcome, None))
}

/// The last offer to an agent failed: nothing rang (`no_endpoints`), the
/// actor ringing it went (`offer_crashed`), or the switch refused the
/// originate, whose cause is the reason. Its outcome is `failed`, with the
/// reason beside it.
pub fn offer_failed(member: Member, agent_id: String, reason: String) -> Nil {
  change_queue_call(member, offer_closed(_, agent_id, "failed", Some(reason)))
}

/// The document with the agent's last offer that has no outcome given
/// `outcome`, and the `reason` of a failure. A document with no such offer
/// is left as it is: the outcome has been written, or the offer never was.
pub fn offer_closed(
  document: Value,
  agent_id: String,
  outcome: String,
  reason: Option(String),
) -> Value {
  let offers = doc.get_list(document, ["offered_to"]) |> result.unwrap([])
  doc.set(
    document,
    ["offered_to"],
    doc.List(close_last(list.reverse(offers), agent_id, outcome, reason, [])),
  )
}

fn close_last(
  newest_first: List(Value),
  agent_id: String,
  outcome: String,
  reason: Option(String),
  seen: List(Value),
) -> List(Value) {
  case newest_first {
    [] -> seen
    [offer, ..older] ->
      case
        doc.get_string(offer, ["agent_id"]) == Ok(agent_id)
        && doc.get_string(offer, ["outcome"]) == Error(Nil)
      {
        True -> {
          let closed = doc.set(offer, ["outcome"], doc.String(outcome))
          let closed = case reason {
            Some(reason) -> doc.set(closed, ["reason"], doc.String(reason))
            None -> closed
          }
          list.append(list.reverse(older), [closed, ..seen])
        }
        False -> close_last(older, agent_id, outcome, reason, [offer, ..seen])
      }
  }
}

/// Every offer the document still has open given the outcome `cancelled`:
/// whatever was ringing when the passage ended was called off with it.
///
/// A passage's record closes with none open. The outcomes are written as
/// the offers end, and this is for those whose end nobody wrote: a ring
/// whose node died before its last word, whose actor the successor found
/// with the ring over.
pub fn offers_settled(document: Value) -> Value {
  case doc.get_list(document, ["offered_to"]) {
    Ok(offers) ->
      doc.set(
        document,
        ["offered_to"],
        doc.List(
          list.map(offers, fn(offer) {
            case doc.get_string(offer, ["outcome"]) {
              Ok(_outcome) -> offer
              Error(Nil) -> doc.set(offer, ["outcome"], doc.String("cancelled"))
            }
          }),
        ),
      )
    Error(Nil) -> document
  }
}

/// An agent answered.
pub fn answered(
  member: Member,
  agent_id: String,
  agent_call_id: String,
  at: Int,
) -> Nil {
  change_queue_call(member, fn(document) {
    document
    |> doc.set(["agent_id"], doc.String(agent_id))
    |> doc.set(["agent_call_id"], doc.String(agent_call_id))
    |> doc.set(["answered"], doc.Int(at))
  })
}

/// A supervisor's phone is ringing for the caller: an `offered_to` entry
/// like an agent's, naming whoever will answer it and marked `pickup`, so
/// that the passage says who rang and a report can tell a supervisor from
/// an agent.
pub fn pickup_offered(
  member: Member,
  supervisor_id: String,
  at: Int,
  id: OfferId,
) -> Nil {
  let leg_prefix = originate.leg_prefix(id)
  change_queue_call(member, fn(document) {
    let offers = doc.get_list(document, ["offered_to"]) |> result.unwrap([])
    doc.set(
      document,
      ["offered_to"],
      doc.List(
        list.append(offers, [
          doc.object([
            #("agent_id", doc.String(supervisor_id)),
            #("at", doc.Int(at)),
            #("pickup", doc.Bool(True)),
            #("leg_prefix", doc.String(leg_prefix)),
          ]),
        ]),
      ),
    )
  })
}

/// A supervisor picked the caller up. `agent_id` is whoever answered, as it
/// is for an agent -- a user id, or the device id of a phone nobody owns --
/// and `picked_up` says it was a supervisor's pickup and not a queue call
/// an agent took, so that nobody's answered calls count it.
pub fn picked_up(
  member: Member,
  supervisor_id: String,
  agent_call_id: String,
  at: Int,
) -> Nil {
  change_queue_call(member, fn(document) {
    document
    |> doc.set(["agent_id"], doc.String(supervisor_id))
    |> doc.set(["agent_call_id"], doc.String(agent_call_id))
    |> doc.set(["answered"], doc.Int(at))
    |> doc.set(["picked_up"], doc.Bool(True))
  })
}

/// The call finished.
pub fn ended(member: Member, result: EndResult, at: Int) -> Nil {
  change_queue_call(member, closed(_, result, at))
}

/// The document as the end of the call leaves it, or unchanged when it
/// already carries an end.
///
/// Idempotent on purpose. The dispatcher that connected a caller usually
/// closes their record itself, and the sweep closes the ones whose
/// dispatcher died before it could; both go through here, and the second of
/// them must change nothing -- an end written twice would move the second
/// the call finished and, with it, the talk time every report reads off it.
pub fn closed(document: Value, result: EndResult, at: Int) -> Value {
  case doc.get_int(document, ["ended"]) {
    Ok(_already_closed) -> document
    Error(Nil) ->
      document
      |> doc.set(["ended"], doc.Int(at))
      |> doc.set(["result"], doc.String(result_to_string(result)))
      |> offers_settled
  }
}

/// The caller left without being connected.
pub fn cancelled(member: Member, reason: CancelReason, at: Int) -> Nil {
  change_queue_call(member, cancellation(_, reason, at))
}

/// The document as a caller leaving without an agent leaves it: when, and
/// why -- `queue_deleted` for a caller the dispatcher took out of a queue
/// that was deleted. A passage cancelled already keeps its second and its
/// reason: a node that takes a caller over on their way out cancels it
/// again, later, and on a branch that may not say which reason it was.
pub fn cancellation(document: Value, reason: CancelReason, at: Int) -> Value {
  case doc.get_int(document, ["cancelled"]) {
    Ok(_) -> offers_settled(document)
    Error(_) ->
      document
      |> doc.set(["cancelled"], doc.Int(at))
      |> doc.set(["cancel_reason"], doc.String(reason_to_string(reason)))
      |> offers_settled
  }
}

/// The recording of a queue call, when the queue or the agent asked for one:
/// its name (`recording.name`), which is the `name` of the `call_recording`
/// document `media_mgr` stores it under, less the extension.
pub fn recorded(member: Member, recording: String) -> Nil {
  change_queue_call(member, recording_named(_, recording))
}

/// The document as a recording leaves it.
pub fn recording_named(document: Value, recording: String) -> Value {
  doc.set(document, ["recording"], doc.String(recording))
}

fn change_queue_call(member: Member, apply: fn(Value) -> Value) -> Nil {
  send(ChangePassage(
    member,
    // The passage's own document is there from `joined` on, so the call
    // id document is only looked for when it is not: a passage that began
    // before the upgrade, or whose `joined` was never written.
    True,
    fn(existing) {
      apply(case existing {
        Some(document) -> document
        None ->
          doc.object([
            #("call_id", doc.String(member.call_id)),
            #("queue_id", doc.String(member.queue_id)),
            #("joined", doc.Int(member.joined)),
            #("offered_to", doc.List([])),
          ])
      })
    },
  ))
}

// --- Reading a caller's passage back ---------------------------------------

/// An offer the document remembers: everybody it rang and the second it
/// began.
///
/// A simultaneous ring is one entry per agent written at the same second, so
/// one offer is a second and the agents in it. `leg_prefix` is what that
/// offer's legs' call ids start with; a record written by the release before
/// this one does not say. `pickup` is a supervisor's phone rung for the
/// caller (`pickup_offered`), not an agent's.
pub type Offered {
  Offered(
    agents: List(String),
    at: Int,
    leg_prefix: Option(String),
    pickup: Bool,
  )
}

/// What a caller's `queue_call` document says has happened to them.
///
/// Read on a takeover and nowhere else. The document is the only thing about
/// a caller that survives the node that was dispatching for them, so it is
/// what a new holder asks before it rings anybody a second time.
pub type Passage {
  Passage(
    /// The offer that never came back: the entries with no outcome, which on
    /// a document written by a live dispatcher is the last ring and nothing
    /// else.
    offer: Option(Offered),
    /// When an agent answered, and who they were.
    answered: Option(Int),
    agent_id: Option(String),
    agent_call_id: Option(String),
    /// Whether whoever answered was a supervisor picking the caller up
    /// (`picked_up`) rather than an agent taking a queue call. Nobody's
    /// counters, wrap-up, agent events or lamp are about such a call.
    picked_up: Bool,
    /// Set once the passage is over, whichever way it went.
    ended: Option(Int),
    cancelled: Option(Int),
    /// Why a passage that was cancelled was: `exit_key`, `timeout` and the
    /// rest (`reason_to_string`).
    cancel_reason: Option(String),
  )
}

/// The document of the member's passage, read straight out of the month
/// they joined in: its own, or failing that the call id document an earlier
/// release wrote, if that is this passage's (`of_passage`).
///
/// Through the data layer rather than through the writer actor: this is a
/// read, it is on the failover path and not the call path, and the writer
/// has work of its own. It is `open_doc` and not the cached one because a
/// cache that answered with what this node believed before the failover
/// would defeat the whole point.
///
/// `Ok(None)` is a passage with no document: the datastore said it is not
/// there, or that the month's database is not (`absent_as_none`). Anything
/// else it said is an `Error`, and is not the same thing. A takeover that
/// took a datastore that did not answer for a passage with no record would
/// settle a caller whose answered call ended unwatched as a hang-up, and
/// offer again a caller whose passage the record says is over
/// (`call/recovery`).
pub fn read(kz: Kazoo, member: Member) -> Result(Option(Passage), Error) {
  let db = modb.db_name(member.account_id, at: Some(member.joined))
  use #(_doc_id, found) <- result.map(
    locate_through(member, True, fn(doc_id) {
      kz.datamgr.open_doc(db, doc_id) |> absent_as_none
    }),
  )
  option.map(found, passage)
}

/// One `queue_call` document as a `Passage`. Total: a document missing
/// everything is a caller nothing has happened to yet.
pub fn passage(document: Value) -> Passage {
  Passage(
    offer: open_offer(
      doc.get_list(document, ["offered_to"]) |> result.unwrap([]),
    ),
    answered: doc.get_int(document, ["answered"]) |> option.from_result,
    agent_id: doc.get_string(document, ["agent_id"]) |> option.from_result,
    agent_call_id: doc.get_string(document, ["agent_call_id"])
      |> option.from_result,
    picked_up: doc.get_bool(document, ["picked_up"]) |> result.unwrap(False),
    ended: doc.get_int(document, ["ended"]) |> option.from_result,
    cancelled: doc.get_int(document, ["cancelled"]) |> option.from_result,
    cancel_reason: doc.get_string(document, ["cancel_reason"])
      |> option.from_result,
  )
}

/// The offer that is still open: the newest second among the entries that
/// have no outcome, and everybody rung in it.
///
/// Entries with an outcome are offers that came back and are over. Taking
/// the newest second rather than every open entry is what keeps a document
/// whose earlier outcome was lost -- a node that died between the ring and
/// the reply -- from reporting an offer that stopped ringing long ago.
fn open_offer(offers: List(Value)) -> Option(Offered) {
  let open =
    list.filter(offers, fn(offer) {
      doc.get_string(offer, ["outcome"]) == Error(Nil)
    })
  let newest =
    list.fold(open, 0, fn(newest, offer) {
      int.max(newest, doc.get_int(offer, ["at"]) |> result.unwrap(0))
    })
  let newest_offer =
    list.filter(open, fn(offer) { doc.get_int(offer, ["at"]) == Ok(newest) })
  let agents =
    list.filter_map(newest_offer, fn(offer) {
      doc.get_string(offer, ["agent_id"])
    })
  let leg_prefix =
    list.find_map(newest_offer, fn(offer) {
      doc.get_string(offer, ["leg_prefix"])
    })
    |> option.from_result
  let pickup =
    list.any(newest_offer, fn(offer) {
      doc.get_bool(offer, ["pickup"]) == Ok(True)
    })
  case agents {
    [] -> None
    _rung ->
      Some(Offered(
        agents: agents,
        at: newest,
        leg_prefix: leg_prefix,
        pickup: pickup,
      ))
  }
}

// --- The status log --------------------------------------------------------

/// One availability change, for the status log in requirement 1.7.
///
/// The document id carries the agent and the second, so the same change
/// written twice -- two nodes acting on one event, which requirement 0.6
/// says must be safe -- is one document.
pub fn status_change(
  account_id: String,
  agent_id: String,
  from: Option(String),
  to: String,
  source: String,
  at: Int,
) -> Nil {
  send(
    Change(
      Month(account_id, at),
      status_change_id(agent_id, to, at),
      status_change_type,
      fn(_existing) {
        doc.object_some([
          #("agent_id", Some(doc.String(agent_id))),
          #("from", option.map(from, doc.String)),
          #("to", Some(doc.String(to))),
          #("source", Some(doc.String(source))),
          #("timestamp", Some(doc.Int(at))),
        ])
      },
    ),
  )
}

@external(erlang, "callcenter_ffi", "status_change_id")
fn status_change_id(agent_id: String, to: String, at: Int) -> String

// --- The agent's counters --------------------------------------------------

/// The counters strategies 5 and 6 will need, kept from the MVP so that
/// adding them is a module and not a data migration, and read by
/// `longest_idle` today.
pub type Counters {
  Counters(
    calls_answered: Int,
    talk_time_s: Int,
    missed: Int,
    last_call_end: Option(Int),
  )
}

pub fn no_counters() -> Counters {
  Counters(calls_answered: 0, talk_time_s: 0, missed: 0, last_call_end: None)
}

pub fn counters(document: Value) -> Counters {
  Counters(
    calls_answered: doc.get_int(document, ["counters", "calls_answered"])
      |> result.unwrap(0),
    talk_time_s: doc.get_int(document, ["counters", "talk_time_s"])
      |> result.unwrap(0),
    missed: doc.get_int(document, ["counters", "missed"]) |> result.unwrap(0),
    last_call_end: doc.get_int(document, ["counters", "last_call_end"])
      |> option.from_result,
  )
}

pub fn counters_to_value(counters: Counters) -> Value {
  doc.object_some([
    #("calls_answered", Some(doc.Int(counters.calls_answered))),
    #("talk_time_s", Some(doc.Int(counters.talk_time_s))),
    #("missed", Some(doc.Int(counters.missed))),
    #("last_call_end", option.map(counters.last_call_end, doc.Int)),
  ])
}

/// The agent answered a queue call.
pub fn agent_answered(account_id: String, agent_id: String) -> Nil {
  count(account_id, agent_id, fn(counters) {
    Counters(..counters, calls_answered: counters.calls_answered + 1)
  })
}

/// The agent missed an offer: no answer, busy or rejected.
pub fn agent_missed(account_id: String, agent_id: String) -> Nil {
  count(account_id, agent_id, fn(counters) {
    Counters(..counters, missed: counters.missed + 1)
  })
}

/// The agent's queue call ended. `talk_time_s` is what it added, and
/// `last_call_end` is what `longest_idle` orders by.
pub fn agent_call_ended(
  account_id: String,
  agent_id: String,
  talk_time_s: Int,
  at: Int,
) -> Nil {
  count(account_id, agent_id, fn(counters) {
    Counters(
      ..counters,
      talk_time_s: counters.talk_time_s + talk_time_s,
      last_call_end: Some(at),
    )
  })
}

/// Back to zero, which is what logging in means: every counter is "since
/// login" and the strategies that read them say so.
pub fn reset_counters(account_id: String, agent_id: String) -> Nil {
  count(account_id, agent_id, fn(_counters) { no_counters() })
}

fn count(
  account_id: String,
  agent_id: String,
  apply: fn(Counters) -> Counters,
) -> Nil {
  send(counting(account_id, agent_id, apply))
}

/// The change to an agent's counters `apply` makes, as the writer takes it.
pub fn counting(
  account_id: String,
  agent_id: String,
  apply: fn(Counters) -> Counters,
) -> Edit {
  Change(
    Account(account_id),
    agent_document_id(agent_id),
    agent_type,
    fn(existing) {
      let document = case existing {
        Some(document) -> document
        None ->
          doc.object([
            #("agent_id", doc.String(agent_id)),
            #("availability", doc.String("logged_out")),
          ])
      }
      doc.set(
        document,
        ["counters"],
        counters_to_value(apply(counters(document))),
      )
    },
  )
}

/// The `callcenter_agent` document of a user. One per agent, by user id, so
/// that it maps to a row without difficulty when the datastore changes.
pub fn agent_document_id(agent_id: String) -> String {
  "callcenter_agent-" <> agent_id
}

// --- The wire names --------------------------------------------------------

/// The `Result` values `kapi_callcenter` validates.
pub fn result_to_string(result: EndResult) -> String {
  case result {
    Completed -> "completed"
    AgentHangup -> "agent_hangup"
    CallerHangup -> "caller_hangup"
    FailedBridge -> "failed"
    Transferred -> "transferred"
  }
}

pub fn result_from_string(name: String) -> EndResult {
  case name {
    "agent_hangup" -> AgentHangup
    "caller_hangup" -> CallerHangup
    "failed" -> FailedBridge
    "transferred" -> Transferred
    _completed -> Completed
  }
}

/// The `Reason` values `kapi_callcenter` validates.
pub fn reason_to_string(reason: CancelReason) -> String {
  case reason {
    Hangup -> "hangup"
    Timeout -> "timeout"
    NoAgentTimeout -> "no_agent_timeout"
    ExitKey -> "exit_key"
    QueueFull -> "queue_full"
    Transfer -> "transfer"
    QueueDeleted -> "queue_deleted"
    Quarantined -> "quarantined"
  }
}

pub fn reason_from_string(name: String) -> CancelReason {
  case name {
    "timeout" -> Timeout
    "no_agent_timeout" -> NoAgentTimeout
    "exit_key" -> ExitKey
    "queue_full" -> QueueFull
    "transfer" -> Transfer
    "queue_deleted" -> QueueDeleted
    "quarantined" -> Quarantined
    _hangup -> Hangup
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
