//// The rules the record writer holds writes by: what a datastore's answer
//// means, how a document says which writes made it, and the order and
//// bounds of what is held.

import callcenter/records/backlog.{Away, Pending, Raced, Refused}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc
import kazoo/kazoo.{Conflict, Invalid, NotFound, Unavailable}
import support/rng

/// Everything a stopped, restarting or unreachable CouchDB answers is the
/// datastore being away; only what it will answer again is final.
pub fn what_an_answer_means_test() {
  let cases = [
    #(Conflict, Raced),
    #(Unavailable, Away),
    #(Invalid("connect_timeout"), Away),
    #(Invalid("econnrefused"), Away),
    #(Invalid("connection_timeout"), Away),
    #(Invalid("network_unreachable"), Away),
    #(Invalid("tcp_closed"), Away),
    #(Invalid("gateway_timeout"), Away),
    #(Invalid("server_timeout"), Away),
    #(Invalid("server_error"), Away),
    #(Invalid("500: unknown_error"), Away),
    #(Invalid("something nobody foresaw"), Away),
    #(NotFound, Refused),
    #(Invalid("db_not_found"), Refused),
    #(Invalid("client_error"), Refused),
    #(Invalid("forbidden"), Refused),
    #(Invalid("400: bad_request"), Refused),
    #(Invalid("413: document_too_large"), Refused),
  ]
  list.each(cases, fn(case_) {
    let #(error, meaning) = case_
    assert backlog.failure(error) == meaning
  })
}

/// A document carries the ids of the last writes that made it, taken from
/// the one it replaces even when the change built it afresh.
pub fn a_document_names_the_writes_that_made_it_test() {
  let first = backlog.stamp(doc.object([]), None, "w-1")
  assert backlog.stamped(Some(first), "w-1")
  assert !backlog.stamped(Some(first), "w-2")
  assert !backlog.stamped(None, "w-1")

  let afresh =
    backlog.stamp(
      doc.object([#("to", doc.String("ready"))]),
      Some(first),
      "w-2",
    )
  assert backlog.stamped(Some(afresh), "w-1")
  assert backlog.stamped(Some(afresh), "w-2")
}

/// Only the last `stamps_kept` ids are kept.
pub fn a_document_keeps_the_last_few_test() {
  let document =
    rng.upto(backlog.stamps_kept + 3)
    |> list.map(fn(n) { n + 1 })
    |> list.fold(None, fn(document, n) {
      Some(backlog.stamp(doc.object([]), document, "w-" <> int.to_string(n)))
    })
  let assert Some(document) = document
  assert doc.strings(document, [backlog.stamps_field])
    == list.map(rng.upto(backlog.stamps_kept), fn(n) {
      "w-" <> int.to_string(n + 4)
    })
}

fn pending(id: String, since_ms: Int) -> backlog.Pending(String) {
  Pending(id: id, write: id, since_ms: since_ms)
}

fn held(
  writes: List(#(String, backlog.Pending(String))),
) -> backlog.Backlog(String) {
  list.fold(writes, backlog.new(), fn(held, write) {
    let #(held, dropped) = backlog.add(held, write.0, write.1, 100)
    assert dropped == []
    held
  })
}

/// Everything held, in the order the rounds would write it when the
/// datastore takes every one.
fn drained(held: backlog.Backlog(String)) -> List(String) {
  case backlog.next(held) {
    None -> []
    Some(#(key, first)) -> [first.id, ..drained(backlog.done(held, key))]
  }
}

/// A document's writes come out oldest first, and a document is drained
/// before the next is started.
pub fn a_document_is_written_in_order_test() {
  let held =
    held([
      #("a", pending("a1", 1)),
      #("b", pending("b1", 2)),
      #("a", pending("a2", 3)),
      #("b", pending("b2", 4)),
      #("a", pending("a3", 5)),
    ])
  assert backlog.size(held) == 5
  assert backlog.holds(held, "a")
  assert !backlog.holds(held, "c")
  assert drained(held) == ["a1", "a2", "a3", "b1", "b2"]
}

/// A document the datastore did not take goes to the back, and keeps its
/// writes and their order.
pub fn a_document_not_taken_goes_to_the_back_test() {
  let held =
    held([
      #("a", pending("a1", 1)),
      #("b", pending("b1", 2)),
      #("a", pending("a2", 3)),
    ])
  let held = backlog.later(held, "a")
  assert drained(held) == ["b1", "a1", "a2"]
  assert backlog.later(held, "nothing held") == held
}

/// Over the most held, the oldest write held is given up.
pub fn over_the_most_the_oldest_goes_test() {
  let #(held, dropped) =
    backlog.new()
    |> backlog.add("a", pending("a1", 10), 2)
  assert dropped == []
  let #(held, dropped) = backlog.add(held, "b", pending("b1", 5), 2)
  assert dropped == []
  let #(held, dropped) = backlog.add(held, "a", pending("a2", 20), 2)
  assert list.map(dropped, fn(pending) { pending.id }) == ["b1"]
  assert backlog.size(held) == 2
  assert drained(held) == ["a1", "a2"]
}

/// A write held longer than the longest is given up, and a document's
/// later writes stay held.
pub fn a_write_held_too_long_is_given_up_test() {
  let held =
    held([
      #("a", pending("a1", 100)),
      #("a", pending("a2", 900)),
      #("b", pending("b1", 200)),
      #("c", pending("c1", 950)),
    ])
  let #(held, expired) = backlog.expire(held, 1000, 500)
  assert list.map(expired, fn(pending) { pending.id }) == ["a1", "b1"]
  assert backlog.size(held) == 2
  assert !backlog.holds(held, "b")
  assert drained(held) == ["a2", "c1"]
}

/// The wait doubles to the longest.
pub fn the_wait_grows_to_the_longest_test() {
  let waits =
    rng.upto(6)
    |> list.scan(backlog.first_retry_ms, fn(wait, _) { backlog.backoff(wait) })
  assert waits == [2000, 4000, 8000, 10_000, 10_000, 10_000]
}
