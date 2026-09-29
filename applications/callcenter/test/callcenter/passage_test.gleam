//// One `queue_call` document per passage: a caller who moves on to a second
//// queue has a second record, and every reader finds the passage it is
//// about -- including one whose document an earlier release keyed by the
//// call id alone.

import callcenter/reconcile
import callcenter/records
import callcenter/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/doc
import support/cluster

const call_id = "passing-through"

fn queue(agents: List(String)) -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("queue")),
    #("name", doc.String("Support")),
    #("strategy", doc.String("longest_idle")),
    #("agent_ring_timeout", doc.Int(20)),
    #(
      "agents",
      doc.List(
        list.index_map(agents, fn(id, position) {
          doc.object([
            #("id", doc.String(id)),
            #("level", doc.Int(1)),
            #("position", doc.Int(position + 1)),
          ])
        }),
      ),
    ),
  ])
}

fn user() -> doc.Value {
  doc.object([
    #("pvt_type", doc.String("user")),
    #("call_center", doc.object([])),
  ])
}

/// Support has Ann and the overflow has Bob, both free.
fn two_queues() -> cluster.Cluster {
  let c =
    cluster.new([#("support", queue(["ann"])), #("overflow", queue(["bob"]))], [
      #("ann", user()),
      #("bob", user()),
    ])
  cluster.agent_is(c, "ann", "available")
  cluster.agent_is(c, "bob", "available")
  c
}

/// The caller's passage through support: joined at 0, rung on Ann, timed out
/// at 30 and gone on to the overflow.
fn left_support() -> doc.Value {
  cluster.record(call_id, "support", 0, [#("ann", 0, Some("cancelled"))], None)
  |> doc.set(["cancelled"], doc.Int(cluster.start_of_time + 30))
  |> doc.set(["cancel_reason"], doc.String("timeout"))
}

fn support() -> types.Member {
  cluster.member(call_id, "support", 0, cluster.start_of_time)
}

fn overflow() -> types.Member {
  cluster.member(call_id, "overflow", 0, cluster.start_of_time + 30)
}

/// A lookup over one month of the cluster's datastore, as the writer does it.
fn lookup(c: cluster.Cluster) -> fn(String) -> option.Option(doc.Value) {
  fn(doc_id) {
    c.kz.datamgr.open_doc(cluster.month(0), doc_id) |> option.from_result
  }
}

// --- The id ------------------------------------------------------------------

/// Call, queue and the second the caller joined.
pub fn a_passage_is_its_call_queue_and_join_test() {
  assert records.passage_id(support())
    == call_id <> "-support-" <> int.to_string(cluster.start_of_time)
  assert records.passage_id(overflow())
    == call_id <> "-overflow-" <> int.to_string(cluster.start_of_time + 30)
  assert !records.same_passage(support(), overflow())
  // A redelivery is the same passage, whatever else changed about it.
  assert records.same_passage(
    support(),
    cluster.member(call_id, "support", 5, cluster.start_of_time),
  )
}

// --- Writing ---------------------------------------------------------------

/// The caller moves on to the overflow: its changes go to a document of its
/// own, not to the support passage's, which keeps its queue and its cancel.
pub fn re_entry_into_a_second_queue_is_a_record_of_its_own_test() {
  let c = two_queues()
  cluster.put_record(c, 0, left_support())

  assert records.locate(overflow(), True, lookup(c))
    == #(records.passage_id(overflow()), None)
  let assert #(id, Some(_support_passage)) =
    records.locate(support(), True, lookup(c))
  assert id == records.passage_id(support())
}

/// A call id document from an earlier release is the passage it began, and
/// only that one: the overflow does not take it over as a re-entry used to.
pub fn a_call_id_document_is_its_own_passage_only_test() {
  let c = two_queues()
  cluster.put_record(
    c,
    0,
    left_support() |> doc.set(["_id"], doc.String(call_id)),
  )

  let assert #(id, Some(document)) = records.locate(support(), True, lookup(c))
  assert id == call_id
  assert doc.get_string(document, ["queue_id"]) == Ok("support")
  assert records.locate(overflow(), True, lookup(c))
    == #(records.passage_id(overflow()), None)
  // A first delivery does not look for one.
  assert records.locate(support(), False, lookup(c))
    == #(records.passage_id(support()), None)
}

// --- Taking a caller over ----------------------------------------------------

/// The record a caller's actor reads when it finds out where a caller
/// handed over stands (`records.read`), for the member it was handed.
fn read(
  c: cluster.Cluster,
  queue_id: String,
  joined: Int,
) -> Option(records.Passage) {
  let assert Ok(found) =
    records.read(
      c.kz,
      cluster.member(call_id, queue_id, 0, cluster.start_of_time + joined),
    )
  found
}

/// The node dispatching the overflow died with Bob ringing. The redelivered
/// member is the overflow's, and so is the record read: the support passage
/// is closed, the overflow's is not, and it has Bob's ring in flight.
pub fn a_takeover_reads_the_passage_it_is_about_test() {
  let c = two_queues()
  cluster.put_record(c, 0, left_support())
  cluster.put_record(
    c,
    30,
    cluster.record(call_id, "overflow", 30, [#("bob", 31, None)], None),
  )

  let assert Some(passage) = read(c, "overflow", 30)
  assert passage.cancelled == None
  let assert Some(offered) = passage.offer
  assert offered.agents == ["bob"]
  assert offered.at == cluster.start_of_time + 31
}

/// With only the support passage on record, as a call id document from an
/// earlier release, the overflow's member has no record: nothing had been
/// written about it.
pub fn a_takeover_does_not_read_another_passages_call_id_document_test() {
  let c = two_queues()
  cluster.put_record(
    c,
    0,
    left_support() |> doc.set(["_id"], doc.String(call_id)),
  )

  assert read(c, "overflow", 30) == None
}

/// A caller waiting across the upgrade: their passage's document is the call
/// id one, and a takeover still finds the offer on it in flight.
pub fn a_takeover_reads_a_call_id_document_test() {
  let c = two_queues()
  cluster.put_record(
    c,
    0,
    cluster.legacy_record(call_id, "support", 0, [#("ann", 0, None)], None),
  )

  let assert Some(passage) = read(c, "support", 0)
  let assert Some(offered) = passage.offer
  assert offered.agents == ["ann"]
}

// --- The open-call scan ----------------------------------------------------

/// Bob answered in the overflow and the node died before the end. The
/// support passage was cancelled, and used to be the same document; now the
/// overflow's answered passage is a record of its own and the scan finds it.
pub fn the_open_scan_finds_an_answered_second_passage_test() {
  let c = two_queues()
  cluster.put_record(c, 0, left_support())
  cluster.put_record(
    c,
    30,
    cluster.record(
      call_id,
      "overflow",
      30,
      [#("bob", 31, Some("answered"))],
      Some(#("bob", "bob-leg", 35)),
    ),
  )

  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  assert call.queue_id == "overflow"
  assert call.agent_id == "bob"
  assert call.joined == cluster.start_of_time + 30
  assert reconcile.passage(call) == records.passage_id(overflow())
  // The member rebuilt from it writes its end to that same document.
  let assert #(id, Some(_open)) =
    records.locate(reconcile.rebuilt(call), True, lookup(c))
  assert id == records.passage_id(overflow())
}

/// An answered call id document from an earlier release is still open to
/// the scan, and the member rebuilt from it closes that document.
pub fn the_open_scan_finds_a_call_id_document_test() {
  let c = two_queues()
  cluster.put_record(
    c,
    0,
    cluster.legacy_record(
      call_id,
      "support",
      0,
      [#("ann", 0, Some("answered"))],
      Some(#("ann", "ann-leg", 3)),
    ),
  )

  let assert [call] =
    reconcile.open_calls(
      c.kz,
      cluster.account_id,
      at: Some(cluster.start_of_time),
    )
  assert call.queue_id == "support"
  let assert #(id, Some(_open)) =
    records.locate(reconcile.rebuilt(call), True, lookup(c))
  assert id == call_id
  assert records.read(c.kz, reconcile.rebuilt(call))
    |> result.map(option.map(_, fn(passage) { passage.agent_id }))
    == Ok(Some(Some("ann")))
}
