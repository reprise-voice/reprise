//// A datastore for the record writer, with the faults it has to survive.
////
//// Documents by where and id, each with a `_rev` that every write moves on,
//// and a write carrying a `_rev` that is not the stored one is a
//// `Conflict`, as CouchDB's is. On top of that a test can say:
////
//// - the whole datastore is down, or one document's database is: every read
////   and write fails as a stopped CouchDB's does (`connect_timeout`);
//// - a document refuses writes, as a 400 would;
//// - the next write to a document lands but its answer is lost
////   (`tcp_closed`), which is the write that must not be made twice;
//// - another writer changes a document just before the next write to it,
////   which is then a `Conflict`.

import callcenter/records.{type Where, Account, Month}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, Conflict, Invalid, NotFound}

pub opaque type Fake {
  Fake(subject: Subject(Message))
}

/// What happens to the next write to one document, once.
pub type Fault {
  /// It is stored, and the writer is told it failed.
  AnswerLost
  /// Another writer changes the document first.
  Raced
}

pub opaque type Message {
  Read(key: String, done: Subject(Result(Value, Error)))
  Save(key: String, document: Value, done: Subject(Result(Nil, Error)))
  Down(Bool, done: Subject(Nil))
  DocDown(key: String, down: Bool, done: Subject(Nil))
  Refuse(key: String, done: Subject(Nil))
  Next(key: String, fault: Fault, done: Subject(Nil))
  Get(key: String, done: Subject(Result(Value, Nil)))
  Tries(done: Subject(Int))
}

type State {
  State(
    docs: Dict(String, Value),
    down: Bool,
    down_docs: Set(String),
    refused: Set(String),
    faults: Dict(String, Fault),
    /// Every read and write asked of it, including the failed ones.
    tries: Int,
  )
}

/// The error a stopped CouchDB answers with, as `kazoo_gleam` passes it on.
pub const outage = Invalid("connect_timeout")

pub fn new() -> Fake {
  let assert Ok(started) =
    actor.new(State(
      docs: dict.new(),
      down: False,
      down_docs: set.new(),
      refused: set.new(),
      faults: dict.new(),
      tries: 0,
    ))
    |> actor.on_message(handle)
    |> actor.start
  Fake(subject: started.data)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Read(key, done) -> {
      let state = State(..state, tries: state.tries + 1)
      process.send(done, case unreachable(state, key) {
        True -> Error(outage)
        False -> dict.get(state.docs, key) |> result.replace_error(NotFound)
      })
      actor.continue(state)
    }
    Save(key, document, done) -> {
      let state = State(..state, tries: state.tries + 1)
      case unreachable(state, key), set.contains(state.refused, key) {
        True, _ -> {
          process.send(done, Error(outage))
          actor.continue(state)
        }
        _, True -> {
          process.send(done, Error(Invalid("400: bad_request")))
          actor.continue(state)
        }
        False, False -> {
          let fault = dict.get(state.faults, key)
          let state = State(..state, faults: dict.delete(state.faults, key))
          let state = case fault {
            Ok(Raced) -> State(..state, docs: another_writer(state.docs, key))
            _ -> state
          }
          case stored(state.docs, key, document), fault {
            Ok(docs), Ok(AnswerLost) -> {
              process.send(done, Error(Invalid("tcp_closed")))
              actor.continue(State(..state, docs: docs))
            }
            Ok(docs), _ -> {
              process.send(done, Ok(Nil))
              actor.continue(State(..state, docs: docs))
            }
            Error(error), _ -> {
              process.send(done, Error(error))
              actor.continue(state)
            }
          }
        }
      }
    }
    Down(down, done) -> {
      process.send(done, Nil)
      actor.continue(State(..state, down: down))
    }
    DocDown(key, down, done) -> {
      process.send(done, Nil)
      actor.continue(
        State(..state, down_docs: case down {
          True -> set.insert(state.down_docs, key)
          False -> set.delete(state.down_docs, key)
        }),
      )
    }
    Refuse(key, done) -> {
      process.send(done, Nil)
      actor.continue(State(..state, refused: set.insert(state.refused, key)))
    }
    Next(key, fault, done) -> {
      process.send(done, Nil)
      actor.continue(
        State(..state, faults: dict.insert(state.faults, key, fault)),
      )
    }
    Get(key, done) -> {
      process.send(done, dict.get(state.docs, key))
      actor.continue(state)
    }
    Tries(done) -> {
      process.send(done, state.tries)
      actor.continue(state)
    }
  }
}

fn unreachable(state: State, key: String) -> Bool {
  state.down || set.contains(state.down_docs, key)
}

/// A write, as CouchDB takes it: over the stored revision only, or as a new
/// document only when there is none.
fn stored(
  docs: Dict(String, Value),
  key: String,
  document: Value,
) -> Result(Dict(String, Value), Error) {
  let given = doc.get_string(document, ["_rev"])
  let generation = case dict.get(docs, key) {
    Ok(current) ->
      case doc.get_string(current, ["_rev"]) == given {
        True -> Ok(revision(current) + 1)
        False -> Error(Conflict)
      }
    Error(Nil) ->
      case given {
        Error(Nil) -> Ok(1)
        Ok(_rev) -> Error(Conflict)
      }
  }
  use generation <- result.map(generation)
  dict.insert(
    docs,
    key,
    doc.set(document, ["_rev"], doc.String(int.to_string(generation) <> "-x")),
  )
}

fn revision(document: Value) -> Int {
  doc.get_string(document, ["_rev"])
  |> result.try(string.split_once(_, "-"))
  |> result.try(fn(parts) { int.parse(parts.0) })
  |> result.unwrap(0)
}

/// Another node's write to the document: a field of its own moved on, and a
/// new revision.
fn another_writer(
  docs: Dict(String, Value),
  key: String,
) -> Dict(String, Value) {
  case dict.get(docs, key) {
    Ok(current) -> {
      let others = doc.get_int(current, ["others"]) |> result.unwrap(0)
      dict.insert(
        docs,
        key,
        current
          |> doc.set(["others"], doc.Int(others + 1))
          |> doc.set(
            ["_rev"],
            doc.String(int.to_string(revision(current) + 1) <> "-y"),
          ),
      )
    }
    Error(Nil) ->
      dict.insert(
        docs,
        key,
        doc.object([#("others", doc.Int(1)), #("_rev", doc.String("1-y"))]),
      )
  }
}

/// The key a document is stored under: its database, less the month, and
/// its id.
pub fn key(where: Where, doc_id: String) -> String {
  case where {
    Account(account_id) -> "account/" <> account_id <> "/" <> doc_id
    Month(account_id, _at) -> "month/" <> account_id <> "/" <> doc_id
  }
}

/// The store the writer is started over.
pub fn store(fake: Fake) -> records.Store {
  records.Store(
    read: fn(where, doc_id) {
      process.call(fake.subject, 5000, Read(key(where, doc_id), _))
    },
    save: fn(where, doc_id, _kind, document) {
      process.call(fake.subject, 5000, Save(key(where, doc_id), document, _))
    },
  )
}

/// The whole datastore goes down, or comes back.
pub fn down(fake: Fake, down: Bool) -> Nil {
  process.call(fake.subject, 5000, Down(down, _))
}

/// One document's database goes down, or comes back.
pub fn doc_down(fake: Fake, where: Where, doc_id: String, down: Bool) -> Nil {
  process.call(fake.subject, 5000, DocDown(key(where, doc_id), down, _))
}

/// Every write to one document is refused from now on.
pub fn refuse(fake: Fake, where: Where, doc_id: String) -> Nil {
  process.call(fake.subject, 5000, Refuse(key(where, doc_id), _))
}

/// The next write to one document meets `fault`.
pub fn next(fake: Fake, where: Where, doc_id: String, fault: Fault) -> Nil {
  process.call(fake.subject, 5000, Next(key(where, doc_id), fault, _))
}

/// A document as stored.
pub fn get(fake: Fake, where: Where, doc_id: String) -> Result(Value, Nil) {
  process.call(fake.subject, 5000, Get(key(where, doc_id), _))
}

/// How many reads and writes were asked of it.
pub fn tries(fake: Fake) -> Int {
  process.call(fake.subject, 5000, Tries)
}
