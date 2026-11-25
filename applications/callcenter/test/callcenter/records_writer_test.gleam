//// The record writer through a datastore that goes away: nothing it was
//// asked to write is lost or written twice, and each document's changes
//// are made in the order they were asked for.

import callcenter/records.{type Edit, Account, Change, ChangePassage}
import callcenter/records/backlog
import callcenter/types
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import kazoo/doc.{type Value}
import support/cluster
import support/fake_store.{AnswerLost, Raced}
import support/rng

const account_id = "account0000000000000000000000001"

fn answered(agent_id: String) -> Edit {
  records.counting(account_id, agent_id, fn(counters) {
    records.Counters(..counters, calls_answered: counters.calls_answered + 1)
  })
}

fn agent_doc(fake: fake_store.Fake, agent_id: String) -> Value {
  let assert Ok(document) =
    fake_store.get(
      fake,
      Account(account_id),
      records.agent_document_id(agent_id),
    )
  document
}

fn calls_answered(fake: fake_store.Fake, agent_id: String) -> Int {
  records.counters(agent_doc(fake, agent_id)).calls_answered
}

fn started() -> #(fake_store.Fake, records.Writer) {
  let fake = fake_store.new()
  #(fake, records.writer(fake_store.store(fake), "w-"))
}

/// With the datastore there, a write is made at once and nothing is held.
pub fn a_write_is_made_at_once_test() {
  let #(fake, writer) = started()
  let writer = records.write(writer, answered("ann"), 0)
  assert records.held(writer) == 0
  assert records.retry_in(writer) == None
  assert calls_answered(fake, "ann") == 1
  assert doc.strings(agent_doc(fake, "ann"), [backlog.stamps_field]) == ["w-0"]
}

/// While the datastore is away, writes are held -- tried once, and the rest
/// not tried at all -- and written, all of them, once it is back.
pub fn writes_are_held_while_the_datastore_is_away_test() {
  let #(fake, writer) = started()
  fake_store.down(fake, True)
  let writer =
    [answered("ann"), answered("ann"), answered("bob"), answered("ann")]
    |> list.fold(writer, fn(writer, edit) { records.write(writer, edit, 0) })
  assert records.held(writer) == 4
  assert fake_store.tries(fake) == 1
  assert records.retry_in(writer) == Some(backlog.first_retry_ms)

  // A round is over at the first write not taken.
  let writer = records.retry(writer, 1000)
  assert records.held(writer) == 4
  assert fake_store.tries(fake) == 2
  assert records.retry_in(writer) == Some(backlog.first_retry_ms * 2)

  fake_store.down(fake, False)
  let writer = records.retry(writer, 3000)
  assert records.held(writer) == 0
  assert records.retry_in(writer) == None
  assert calls_answered(fake, "ann") == 3
  assert calls_answered(fake, "bob") == 1

  // And the writer writes at once again.
  let writer = records.write(writer, answered("bob"), 4000)
  assert records.held(writer) == 0
  assert calls_answered(fake, "bob") == 2
}

/// A write whose answer was lost had landed: tried again, it is found in
/// the document and not made twice.
pub fn a_write_whose_answer_was_lost_is_not_made_twice_test() {
  let #(fake, writer) = started()
  let doc_id = records.agent_document_id("ann")
  fake_store.next(fake, Account(account_id), doc_id, AnswerLost)
  let writer = records.write(writer, answered("ann"), 0)
  assert records.held(writer) == 1
  assert calls_answered(fake, "ann") == 1

  let writer = records.retry(writer, 1000)
  assert records.held(writer) == 0
  assert calls_answered(fake, "ann") == 1

  let writer = records.write(writer, answered("ann"), 2000)
  assert calls_answered(fake, "ann") == 2
  assert records.held(writer) == 0
}

/// A write that lost a race with another node's is read and made again at
/// once, over the other node's change.
pub fn a_write_that_lost_a_race_is_made_again_test() {
  let #(fake, writer) = started()
  let doc_id = records.agent_document_id("ann")
  let writer = records.write(writer, answered("ann"), 0)
  fake_store.next(fake, Account(account_id), doc_id, Raced)
  let writer = records.write(writer, answered("ann"), 1)
  assert records.held(writer) == 0
  assert calls_answered(fake, "ann") == 2
  assert doc.get_int(agent_doc(fake, "ann"), ["others"]) == Ok(1)
}

/// A write the datastore refuses is given up, not held.
pub fn a_refused_write_is_given_up_test() {
  let #(fake, writer) = started()
  fake_store.refuse(fake, Account(account_id), records.agent_document_id("ann"))
  let writer = records.write(writer, answered("ann"), 0)
  assert records.held(writer) == 0
  assert records.retry_in(writer) == None
  let writer = records.write(writer, answered("bob"), 1)
  assert records.held(writer) == 0
  assert calls_answered(fake, "bob") == 1
}

/// One document the datastore cannot reach keeps no other back for more
/// than a round: it goes to the back of the next.
pub fn one_document_away_keeps_no_other_back_test() {
  let #(fake, writer) = started()
  let ann = records.agent_document_id("ann")
  fake_store.doc_down(fake, Account(account_id), ann, True)
  let writer = records.write(writer, answered("ann"), 0)
  let writer = records.write(writer, answered("bob"), 0)
  assert records.held(writer) == 2

  let writer = records.retry(writer, 1000)
  let writer = records.retry(writer, 3000)
  assert records.held(writer) == 1
  assert calls_answered(fake, "bob") == 1
  assert fake_store.get(fake, Account(account_id), ann) == Error(Nil)
}

/// A write held for longer than the longest is given up.
pub fn a_write_held_too_long_is_given_up_test() {
  let #(fake, writer) = started()
  fake_store.down(fake, True)
  let writer = records.write(writer, answered("ann"), 0)
  let writer = records.retry(writer, backlog.oldest_ms - 1)
  assert records.held(writer) == 1
  fake_store.down(fake, False)
  let writer = records.retry(writer, backlog.oldest_ms + 1)
  assert records.held(writer) == 0
  assert fake_store.get(
      fake,
      Account(account_id),
      records.agent_document_id("ann"),
    )
    == Error(Nil)
}

/// A caller's passage the datastore could not read is not taken for one
/// with no document: the change waits, and is made over what is there.
pub fn a_passage_not_read_is_not_a_new_one_test() {
  let #(fake, writer) = started()
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let writer = records.write(writer, appended(Passage(member), 1), 0)
  fake_store.down(fake, True)
  let writer = records.write(writer, appended(Passage(member), 2), 1)
  assert records.held(writer) == 1
  fake_store.down(fake, False)
  let writer = records.retry(writer, 1000)
  assert records.held(writer) == 0
  assert logged(fake, Passage(member)) == [1, 2]
}

/// The writer's process tries again by itself.
pub fn the_writer_tries_again_by_itself_test() {
  let fake = fake_store.new()
  let assert Ok(started) =
    records.start_with(None, fake_store.store(fake), "w-", monotonic_ms)
  fake_store.down(fake, True)
  process.send(started.data, records.Write(answered("ann")))
  let _ = process.call(started.data, 1000, records.Flush)
  fake_store.down(fake, False)
  process.sleep(backlog.first_retry_ms + 300)
  assert calls_answered(fake, "ann") == 1
  let _ = process.call(started.data, 1000, records.Stop)
  Nil
}

// --- Any outage --------------------------------------------------------------

/// A document of the property: an agent's or a caller's.
type Target {
  Agent(String)
  Passage(types.Member)
}

fn targets() -> List(Target) {
  [
    Agent("ann"),
    Agent("bob"),
    Passage(cluster.member("call-one", "support", 0, cluster.start_of_time)),
  ]
}

fn where_of(target: Target) -> #(records.Where, String) {
  case target {
    Agent(agent_id) -> #(
      Account(account_id),
      records.agent_document_id(agent_id),
    )
    Passage(member) -> #(
      records.Month(member.account_id, member.joined),
      records.passage_id(member),
    )
  }
}

/// A change that appends `n` to the document's log.
fn appended(target: Target, n: Int) -> Edit {
  let append = fn(existing) {
    let document = option.unwrap(existing, doc.object([]))
    let log = doc.get_list(document, ["log"]) |> result.unwrap([])
    doc.set(document, ["log"], doc.List(list.append(log, [doc.Int(n)])))
  }
  case target {
    Agent(agent_id) ->
      Change(
        Account(account_id),
        records.agent_document_id(agent_id),
        records.agent_type,
        append,
      )
    Passage(member) -> ChangePassage(member, False, append)
  }
}

fn logged(fake: fake_store.Fake, target: Target) -> List(Int) {
  let #(where, doc_id) = where_of(target)
  case fake_store.get(fake, where, doc_id) {
    Ok(document) ->
      doc.get_list(document, ["log"])
      |> result.unwrap([])
      |> list.filter_map(fn(value) {
        case value {
          doc.Int(n) -> Ok(n)
          _ -> Error(Nil)
        }
      })
    Error(Nil) -> []
  }
}

/// Whatever the datastore does -- goes down, loses a document's database,
/// loses the answer to a write that landed, takes another writer's change
/// first -- once it is back every change asked for is in its document once,
/// in the order it was asked for.
pub fn nothing_is_lost_or_doubled_by_an_outage_test() {
  rng.upto(200)
  |> list.each(fn(seed) {
    let fake = fake_store.new()
    let writer = records.writer(fake_store.store(fake), "w-")
    let #(writer, sent, _rng) =
      rng.upto(40)
      |> list.fold(#(writer, dict.new(), rng.seeded(seed)), fn(acc, step) {
        let #(writer, sent, rng) = acc
        let now = step * 700
        let #(kind, rng) = rng.below(rng, 100)
        let #(target, rng) = rng.pick(rng, targets())
        let #(where, doc_id) = where_of(target)
        case kind {
          _ if kind < 50 -> {
            let n = step
            let sent =
              dict.upsert(sent, doc_id, fn(before) {
                list.append(option.unwrap(before, []), [n])
              })
            #(records.write(writer, appended(target, n), now), sent, rng)
          }
          _ if kind < 60 -> {
            fake_store.down(fake, True)
            #(writer, sent, rng)
          }
          _ if kind < 70 -> {
            fake_store.down(fake, False)
            #(writer, sent, rng)
          }
          _ if kind < 75 -> {
            let #(down, rng) = rng.chance(rng, 50)
            fake_store.doc_down(fake, where, doc_id, down)
            #(writer, sent, rng)
          }
          _ if kind < 82 -> {
            fake_store.next(fake, where, doc_id, AnswerLost)
            #(writer, sent, rng)
          }
          _ if kind < 88 -> {
            fake_store.next(fake, where, doc_id, Raced)
            #(writer, sent, rng)
          }
          _ -> #(records.retry(writer, now), sent, rng)
        }
      })

    fake_store.down(fake, False)
    list.each(targets(), fn(target) {
      let #(where, doc_id) = where_of(target)
      fake_store.doc_down(fake, where, doc_id, False)
    })
    let writer = drain(writer, 40 * 700, 10)
    assert records.held(writer) == 0

    list.each(targets(), fn(target) {
      let #(_where, doc_id) = where_of(target)
      let asked = dict.get(sent, doc_id) |> result.unwrap([])
      case logged(fake, target) == asked {
        True -> Nil
        False ->
          panic as {
            "seed "
            <> int.to_string(seed)
            <> ": "
            <> doc_id
            <> " logged "
            <> string_of(logged(fake, target))
            <> ", asked "
            <> string_of(asked)
          }
      }
    })
  })
}

fn drain(writer: records.Writer, now: Int, left: Int) -> records.Writer {
  case records.held(writer), left {
    0, _ -> writer
    _, 0 -> writer
    _, _ -> drain(records.retry(writer, now + 1000), now + 1000, left - 1)
  }
}

fn string_of(ns: List(Int)) -> String {
  "[" <> list.map(ns, int.to_string) |> string_join <> "]"
}

fn string_join(parts: List(String)) -> String {
  case parts {
    [] -> ""
    [one] -> one
    [one, ..rest] -> one <> "," <> string_join(rest)
  }
}

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int
