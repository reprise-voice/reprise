//// What the record writer holds while the datastore will not take it:
//// every write it has not managed yet, by the document it is for, oldest
//// first.
////
//// A write the datastore could not take used to be logged and dropped. For
//// a `queue_call` record that is survivable -- the sweep closes a record
//// left open -- but an agent's counter increment dropped during an outage
//// is gone for good, and nothing counts it again. The lab of 2026-09-27
//// (e2e-260927-cca3) lost them that way. So the writer keeps what it could
//// not write and tries again, and this module is what it keeps it in and
//// the rules it keeps it by. Nothing here reads or writes a document.
////
//// Three things matter, and each is a rule here:
////
//// - **Order, per document.** Two changes to one document are made in the
////   order they were asked for: `offered` before `offer_outcome`, an answer
////   before an end. So while a document has a write waiting, every later
////   write to it waits behind it, even one the datastore would take. Writes
////   to different documents keep no order between them; none needs one.
//// - **Once.** A write whose answer never came back may have landed. Tried
////   again blindly, an increment counts twice. So every write carries an id,
////   and the document it makes carries the ids of the last few writes that
////   made it (`stamps_field`). A write tried again first reads the
////   document, and one whose id is already there is done.
//// - **Bounded.** A node that holds writes for an outage that does not end
////   holds them in memory. At most `most` are held and none longer than
////   `oldest_ms`; beyond either the oldest is given up and logged.
////
//// What a node that stops holds is lost with it. That is the limit of
//// keeping it in memory, and it is no worse than dropping it at once.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error, Conflict, Invalid, NotFound, Unavailable}

/// The first wait before a write the datastore did not take is tried again.
pub const first_retry_ms = 1000

/// The longest wait between two tries: what a write waits at most after the
/// datastore is back, once an outage has gone on long enough for the waits
/// to grow to it.
pub const longest_retry_ms = 10_000

/// How long a write is held before it is given up: an hour.
pub const oldest_ms = 3_600_000

/// How many writes are held at most. A busy node writes a few a second, so
/// this is well over an hour of them.
pub const most = 20_000

/// How many times a write that lost a race -- the document changed between
/// its read and its write -- is read and made again at once before it waits
/// with the rest.
pub const races = 3

/// The field every document the writer writes carries the ids of the last
/// writes that made it in. Private (`pvt_`), so no API answers with it and
/// no view emits it.
pub const stamps_field = "pvt_callcenter_writes"

/// How many ids the field keeps. Only a write whose answer was lost needs
/// to find its own, and it is tried again before any later write to the
/// same document; the few more are for writes from other nodes in between.
pub const stamps_kept = 8

/// Why the datastore did not take a write.
pub type Failure {
  /// The document changed between the read and the write: read it again
  /// and make the change again.
  Raced
  /// The datastore did not answer, or not in time, or not usefully: it is
  /// down, restarting or unreachable. Try again later.
  Away
  /// The datastore answered that it will not take this write, and it will
  /// answer the same again: give it up.
  Refused
}

/// What an error from the datastore means for the write that met it.
///
/// Most spellings of an outage reach here as `Invalid`, not `Unavailable`:
/// `kazoo_gleam` names three (`unavailable`, `timeout`, `db_not_reachable`)
/// and passes the rest through, and a stopped CouchDB answers
/// `connect_timeout` or `econnrefused`. So anything not known to be final
/// is taken as the datastore being away, and it is the write's age that
/// ends a failure nobody foresaw. What is final is a missing database, a
/// refusal, and any 4xx the datastore gave (`400: bad_request`).
pub fn failure(error: Error) -> Failure {
  case error {
    Conflict -> Raced
    Unavailable -> Away
    NotFound -> Refused
    Invalid(reason) ->
      case is_final(reason) {
        True -> Refused
        False -> Away
      }
  }
}

fn is_final(reason: String) -> Bool {
  case reason {
    "db_not_found"
    | "client_error"
    | "forbidden"
    | "illegal_database_name"
    | "invalid_db_name" -> True
    _ -> string.starts_with(reason, "4") && string.contains(reason, ": ")
  }
}

// --- Stamps ------------------------------------------------------------------

/// Whether a write already made the document: its id is among the last
/// writes it carries.
pub fn stamped(document: Option(Value), id: String) -> Bool {
  case document {
    Some(document) -> list.contains(stamps(document), id)
    None -> False
  }
}

/// The document a write makes, carrying its id after the ids the document
/// it replaces carried, the last `stamps_kept` of them. The ids are taken
/// from `existing` and not from `written`, because a change may build its
/// document afresh (`status_change` does).
pub fn stamp(written: Value, existing: Option(Value), id: String) -> Value {
  let before = case existing {
    Some(document) -> stamps(document)
    None -> []
  }
  let kept = list.append(before, [id])
  let kept = list.drop(kept, int.max(list.length(kept) - stamps_kept, 0))
  doc.set(written, [stamps_field], doc.List(list.map(kept, doc.String)))
}

fn stamps(document: Value) -> List(String) {
  doc.strings(document, [stamps_field])
}

// --- The backlog -------------------------------------------------------------

/// One write held: its id, the write, and when it was first asked for.
pub type Pending(w) {
  Pending(id: String, write: w, since_ms: Int)
}

/// The writes held, by the document they are for.
pub opaque type Backlog(w) {
  Backlog(
    /// Every document with a write held, to its writes, oldest first.
    waiting: Dict(String, List(Pending(w))),
    /// The documents in the order the next round tries them. A document
    /// the datastore did not take goes to the back, so that one document
    /// the datastore will not take never keeps it from the others.
    order: List(String),
    count: Int,
  )
}

pub fn new() -> Backlog(w) {
  Backlog(waiting: dict.new(), order: [], count: 0)
}

/// How many writes are held.
pub fn size(backlog: Backlog(w)) -> Int {
  backlog.count
}

/// Whether a document has a write held, which every later write to it
/// waits behind.
pub fn holds(backlog: Backlog(w), key: String) -> Bool {
  dict.has_key(backlog.waiting, key)
}

/// Hold a write behind the document's others. Over `most`, the oldest write
/// held is given up, and it is answered so it can be logged.
pub fn add(
  backlog: Backlog(w),
  key: String,
  pending: Pending(w),
  most: Int,
) -> #(Backlog(w), List(Pending(w))) {
  let backlog = case dict.get(backlog.waiting, key) {
    Ok(held) ->
      Backlog(
        ..backlog,
        waiting: dict.insert(backlog.waiting, key, list.append(held, [pending])),
        count: backlog.count + 1,
      )
    Error(Nil) ->
      Backlog(
        waiting: dict.insert(backlog.waiting, key, [pending]),
        order: list.append(backlog.order, [key]),
        count: backlog.count + 1,
      )
  }
  case backlog.count > most {
    False -> #(backlog, [])
    True ->
      case oldest(backlog) {
        Some(key) -> {
          let assert Ok([given_up, ..]) = dict.get(backlog.waiting, key)
          #(done(backlog, key), [given_up])
        }
        None -> #(backlog, [])
      }
  }
}

/// The document whose first write held is the oldest.
fn oldest(backlog: Backlog(w)) -> Option(String) {
  dict.fold(backlog.waiting, None, fn(found, key, held) {
    case held, found {
      [first, ..], None -> Some(#(key, first.since_ms))
      [first, ..], Some(#(_key, since)) if first.since_ms < since ->
        Some(#(key, first.since_ms))
      _, _ -> found
    }
  })
  |> option.map(fn(found) { found.0 })
}

/// The next write to try: the first held for the document at the front.
pub fn next(backlog: Backlog(w)) -> Option(#(String, Pending(w))) {
  case backlog.order {
    [key, ..] ->
      case dict.get(backlog.waiting, key) {
        Ok([first, ..]) -> Some(#(key, first))
        _ -> None
      }
    [] -> None
  }
}

/// The first write held for a document is over, written or given up. The
/// document keeps its place while it has more.
pub fn done(backlog: Backlog(w), key: String) -> Backlog(w) {
  case dict.get(backlog.waiting, key) {
    Ok([_first]) ->
      Backlog(
        waiting: dict.delete(backlog.waiting, key),
        order: list.filter(backlog.order, fn(other) { other != key }),
        count: backlog.count - 1,
      )
    Ok([_first, ..rest]) ->
      Backlog(
        ..backlog,
        waiting: dict.insert(backlog.waiting, key, rest),
        count: backlog.count - 1,
      )
    _ -> backlog
  }
}

/// The datastore did not take the document's first write: it goes to the
/// back of the next round.
pub fn later(backlog: Backlog(w), key: String) -> Backlog(w) {
  case holds(backlog, key) {
    True ->
      Backlog(
        ..backlog,
        order: list.append(
          list.filter(backlog.order, fn(other) { other != key }),
          [key],
        ),
      )
    False -> backlog
  }
}

/// Give up every write held since before `now_ms - oldest_ms`, answering
/// them so they can be logged. Writes are held oldest first, so a
/// document's given-up writes are the front of its list.
pub fn expire(
  backlog: Backlog(w),
  now_ms: Int,
  oldest_ms: Int,
) -> #(Backlog(w), List(Pending(w))) {
  let cutoff = now_ms - oldest_ms
  list.fold(backlog.order, #(backlog, []), fn(acc, key) {
    let #(backlog, given_up) = acc
    let assert Ok(held) = dict.get(backlog.waiting, key)
    case list.split_while(held, fn(pending) { pending.since_ms < cutoff }) {
      #([], _) -> acc
      #(old, []) -> #(
        Backlog(
          waiting: dict.delete(backlog.waiting, key),
          order: list.filter(backlog.order, fn(other) { other != key }),
          count: backlog.count - list.length(old),
        ),
        list.append(given_up, old),
      )
      #(old, kept) -> #(
        Backlog(
          ..backlog,
          waiting: dict.insert(backlog.waiting, key, kept),
          count: backlog.count - list.length(old),
        ),
        list.append(given_up, old),
      )
    }
  })
}

/// The wait after a round the datastore did not finish: twice the last,
/// up to `longest_retry_ms`.
pub fn backoff(delay_ms: Int) -> Int {
  int.min(delay_ms * 2, longest_retry_ms)
}
