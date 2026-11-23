//// The queue document: cached between refreshes, read from the database on
//// them, and left as it was when the database cannot be reached.

import callcenter/queue_doc
import gleam/result
import kazoo/cache
import kazoo/doc
import kazoo/kazoo.{type Kazoo, Datamgr, Kazoo, NotFound, Unavailable}
import kazoo/testing/fake

const db = "account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384"

const counters = "queue_doc_test_counters"

/// A data layer that counts what it is asked, over a fake holding the
/// queues given.
fn counting(queues: List(#(String, doc.Value))) -> Kazoo {
  let fake = fake.new()
  fake.put_account(
    fake,
    "4b1f0c2d7e8a9b0c1d2e3f4051627384",
    "q.example.com",
    [],
  )
  list_each(queues, fn(entry) {
    fake.put_doc(fake, db, doc.set(entry.1, ["_id"], doc.String(entry.0)))
  })
  let kz = fake.kazoo(fake)
  cache.clear(counters)
  queue_doc.reset()
  Kazoo(
    ..kz,
    datamgr: Datamgr(
      ..kz.datamgr,
      open_doc: fn(db, id) {
        bump("database")
        kz.datamgr.open_doc(db, id)
      },
      open_cache_doc: fn(db, id) {
        bump("cache")
        kz.datamgr.open_cache_doc(db, id)
      },
      flush_cache_doc: fn(_db, _id) { bump("flush") },
    ),
  )
}

fn list_each(items: List(a), f: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      f(first)
      list_each(rest, f)
    }
  }
}

fn bump(counter: String) -> Nil {
  cache.put(counters, counter, count(counter) + 1)
}

fn count(counter: String) -> Int {
  cache.get(counters, counter) |> result.unwrap(0)
}

fn support() -> doc.Value {
  doc.object([#("name", doc.String("Support"))])
}

pub fn the_database_is_read_once_per_interval_test() {
  let kz = counting([#("support", support())])

  // The first read in the interval goes to the database, and the cached
  // copy is dropped so that the next read caches the fresh one.
  let assert Ok(document) = queue_doc.read(kz, db, "support", 100, 10)
  assert doc.get_string(document, ["name"]) == Ok("Support")
  assert count("database") == 1
  assert count("flush") == 1
  assert count("cache") == 0

  // Inside the interval: the cache, and nothing else.
  let assert Ok(_) = queue_doc.read(kz, db, "support", 105, 10)
  let assert Ok(_) = queue_doc.read(kz, db, "support", 109, 10)
  assert count("database") == 1
  assert count("cache") == 2

  // The interval over: the database again.
  let assert Ok(_) = queue_doc.read(kz, db, "support", 110, 10)
  assert count("database") == 2
  assert count("flush") == 2
}

pub fn each_queue_has_its_own_interval_test() {
  let kz = counting([#("support", support()), #("sales", support())])

  let assert Ok(_) = queue_doc.read(kz, db, "support", 100, 10)
  let assert Ok(_) = queue_doc.read(kz, db, "sales", 100, 10)
  assert count("database") == 2
  assert count("cache") == 0
}

/// A refresh that finds the database unreachable leaves the cached copy in
/// force rather than forgetting the queue.
pub fn an_unreachable_database_leaves_the_cached_queue_in_force_test() {
  let kz = counting([#("support", support())])
  let down =
    Kazoo(
      ..kz,
      datamgr: Datamgr(..kz.datamgr, open_doc: fn(_db, _id) {
        bump("database")
        Error(Unavailable)
      }),
    )

  let assert Ok(document) = queue_doc.read(down, db, "support", 100, 10)
  assert doc.get_string(document, ["name"]) == Ok("Support")
  assert count("database") == 1
  assert count("cache") == 1
  assert count("flush") == 0
}

/// The database answering that the queue is gone is an answer: the cached
/// copy goes with it.
pub fn a_deleted_queue_is_forgotten_test() {
  let kz = counting([])

  assert queue_doc.read(kz, db, "support", 100, 10) == Error(NotFound)
  assert count("database") == 1
  assert count("flush") == 1
}
