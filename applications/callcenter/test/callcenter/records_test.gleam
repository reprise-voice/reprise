//// The caller's own record, read back: the only thing about a caller that
//// survives the node which was dispatching for them.

import callcenter/recording
import callcenter/records
import callcenter/types.{CallerHangup, Completed, QueueDeleted, Transferred}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import kazoo/doc
import kazoo/kazoo.{Datamgr, Invalid, Kazoo, NotFound, Unavailable}
import support/cluster

const joined_at = 63_800_000_000

fn offer(
  agent_id: String,
  at: Int,
  outcome: option.Option(String),
) -> doc.Value {
  doc.object_some([
    #("agent_id", Some(doc.String(agent_id))),
    #("at", Some(doc.Int(at))),
    #("outcome", option.map(outcome, doc.String)),
  ])
}

fn record(offers: List(doc.Value)) -> doc.Value {
  doc.object([
    #("call_id", doc.String("call-one")),
    #("queue_id", doc.String("support")),
    #("joined", doc.Int(joined_at)),
    #("offered_to", doc.List(offers)),
  ])
}

// --- The offer that never came back ----------------------------------------

/// An offer with no outcome is one nothing reported: the agent's phone may
/// still be ringing.
pub fn an_offer_in_flight_test() {
  assert records.passage(record([offer("ann", joined_at + 5, None)])).offer
    == Some(records.Offered(
      agents: ["ann"],
      at: joined_at + 5,
      leg_prefix: None,
      pickup: False,
    ))
}

/// An offer that came back is over, whatever it did.
pub fn an_offer_that_came_back_test() {
  assert records.passage(
      record([offer("ann", joined_at + 5, Some("no_answer"))]),
    ).offer
    == None
}

/// A simultaneous ring is one entry per agent at the same second, and one
/// offer.
pub fn a_simultaneous_ring_is_one_offer_test() {
  assert records.passage(
      record([
        offer("ann", joined_at + 5, None),
        offer("bob", joined_at + 5, None),
      ]),
    ).offer
    == Some(records.Offered(
      agents: ["ann", "bob"],
      at: joined_at + 5,
      leg_prefix: None,
      pickup: False,
    ))
}

/// A document whose earlier outcome was lost -- a node that died between the
/// ring and the reply -- must not report an offer that stopped ringing long
/// ago. The newest second is the offer.
pub fn the_newest_open_offer_wins_test() {
  assert records.passage(
      record([
        offer("ann", joined_at + 5, None),
        offer("bob", joined_at + 30, None),
      ]),
    ).offer
    == Some(records.Offered(
      agents: ["bob"],
      at: joined_at + 30,
      leg_prefix: None,
      pickup: False,
    ))
}

/// The offer's entries say what its legs' call ids start with, which is how
/// whoever takes the caller over tells that offer's answer from the
/// caller's next bridge. A record of the release before says nothing.
pub fn the_open_offer_names_its_legs_test() {
  let with_prefix = fn(agent_id, at) {
    doc.set(offer(agent_id, at, None), ["leg_prefix"], doc.String("c0ffee"))
  }
  assert records.passage(
      record([
        offer("ann", joined_at + 5, Some("no_answer")),
        with_prefix("bob", joined_at + 30),
        with_prefix("cat", joined_at + 30),
      ]),
    ).offer
    == Some(records.Offered(
      agents: ["bob", "cat"],
      at: joined_at + 30,
      leg_prefix: Some("c0ffee"),
      pickup: False,
    ))
}

/// A caller nobody has rung.
pub fn a_caller_never_offered_test() {
  assert records.passage(record([])).offer == None
  assert records.passage(doc.object([])).offer == None
}

// --- The rest of the passage -----------------------------------------------

pub fn an_answered_record_test() {
  let answered =
    record([offer("ann", joined_at + 5, Some("answered"))])
    |> doc.set(["agent_id"], doc.String("ann"))
    |> doc.set(["agent_call_id"], doc.String("agent-leg"))
    |> doc.set(["answered"], doc.Int(joined_at + 8))
  let passage = records.passage(answered)

  assert passage.answered == Some(joined_at + 8)
  assert passage.agent_id == Some("ann")
  assert passage.agent_call_id == Some("agent-leg")
  assert passage.ended == None
  assert passage.cancelled == None
  assert !passage.picked_up
}

/// A supervisor's pickup reads back as one, so that whoever takes the call
/// over does not count it as an agent's queue call.
pub fn a_picked_up_record_test() {
  let passage =
    records.passage(
      record([])
      |> doc.set(["agent_id"], doc.String("sup"))
      |> doc.set(["answered"], doc.Int(joined_at + 8))
      |> doc.set(["picked_up"], doc.Bool(True)),
    )
  assert passage.picked_up
  assert passage.agent_id == Some("sup")
  assert passage.answered == Some(joined_at + 8)
}

/// The supervisor's phone ringing for the caller is an open offer marked as
/// a pickup, not an agent's ring.
pub fn a_pickup_ringing_is_an_open_pickup_offer_test() {
  let ringing =
    offer("sup", joined_at + 5, None) |> doc.set(["pickup"], doc.Bool(True))
  assert records.passage(record([ringing])).offer
    == Some(records.Offered(
      agents: ["sup"],
      at: joined_at + 5,
      leg_prefix: None,
      pickup: True,
    ))
}

pub fn a_cancelled_record_test() {
  let passage =
    records.passage(
      record([]) |> doc.set(["cancelled"], doc.Int(joined_at + 40)),
    )
  assert passage.cancelled == Some(joined_at + 40)
}

// --- Closing one -----------------------------------------------------------

/// The end of the call, written once.
pub fn an_end_is_written_test() {
  let closed = records.closed(record([]), Completed, joined_at + 90)
  assert doc.get_int(closed, ["ended"]) == Ok(joined_at + 90)
  assert doc.get_string(closed, ["result"]) == Ok("completed")
}

/// A caller the dispatcher took out of a deleted queue is a cancelled
/// passage like any other, and says why: `queue_deleted`, which reads back
/// as itself. The offers made for them keep their own outcomes.
pub fn a_deleted_queue_is_a_cancel_reason_of_its_own_test() {
  let left =
    records.cancellation(
      record([offer("ann", joined_at + 5, Some("cancelled"))]),
      QueueDeleted,
      joined_at + 30,
    )
  assert doc.get_int(left, ["cancelled"]) == Ok(joined_at + 30)
  assert doc.get_string(left, ["cancel_reason"]) == Ok("queue_deleted")
  assert records.reason_from_string("queue_deleted") == QueueDeleted
  assert records.passage(left).cancelled == Some(joined_at + 30)
  let assert Ok([kept]) = doc.get_list(left, ["offered_to"])
  assert doc.get_string(kept, ["outcome"]) == Ok("cancelled")
}

/// A recorded call's record names its recording, as `media_mgr` names the
/// `call_recording` document.
pub fn a_recording_is_named_on_the_record_test() {
  let named =
    records.recording_named(
      record([]),
      recording.name("queue-one", "call-one", joined_at + 20),
    )
  assert doc.get_string(named, ["recording"])
    == Ok("queue-queue-one-call-one-" <> int.to_string(joined_at + 20))
}

/// Every reason a caller leaves for is written as its own word, and reads
/// back as itself.
pub fn every_cancel_reason_reads_back_test() {
  [
    types.Hangup,
    types.Timeout,
    types.NoAgentTimeout,
    types.ExitKey,
    types.QueueFull,
    types.Transfer,
    types.QueueDeleted,
    types.Quarantined,
  ]
  |> list.each(fn(reason) {
    assert records.reason_from_string(records.reason_to_string(reason))
      == reason
  })
  assert records.reason_to_string(types.Quarantined) == "quarantined"
}

/// Written twice it changes nothing. The dispatcher that connected a caller
/// usually closes their record, and the sweep closes the ones whose
/// dispatcher died first; a second end would move the second the call
/// finished and, with it, the talk time every report reads off it.
pub fn an_end_is_written_only_once_test() {
  let closed = records.closed(record([]), Completed, joined_at + 90)
  assert records.closed(closed, CallerHangup, joined_at + 200) == closed
}

// --- Every offer has an outcome ---------------------------------------------

fn outcomes(document: doc.Value) -> List(#(String, String, String)) {
  let assert Ok(offers) = doc.get_list(document, ["offered_to"])
  list.map(offers, fn(offer) {
    let field = fn(name) {
      case doc.get_string(offer, [name]) {
        Ok(value) -> value
        Error(Nil) -> "-"
      }
    }
    #(field("agent_id"), field("outcome"), field("reason"))
  })
}

/// An offer that failed is `failed`, and says why; the agent's earlier
/// offers keep theirs.
pub fn a_failed_offer_says_why_test() {
  let document =
    record([
      offer("ann", joined_at + 5, Some("no_answer")),
      offer("ann", joined_at + 20, None),
      offer("bob", joined_at + 20, None),
    ])
    |> records.offer_closed("ann", "failed", Some("no_endpoints"))
  assert outcomes(document)
    == [
      #("ann", "no_answer", "-"),
      #("ann", "failed", "no_endpoints"),
      #("bob", "-", "-"),
    ]
  // An agent with no offer open is nothing to close.
  assert records.offer_closed(document, "cat", "failed", Some("x")) == document
}

/// A passage closes with no offer open: whatever was still ringing when it
/// ended -- a ring whose last word nobody heard -- is `cancelled`, and the
/// outcomes written stand.
pub fn a_closed_passage_has_no_offer_open_test() {
  let open =
    record([
      offer("ann", joined_at + 5, Some("failed")),
      offer("ann", joined_at + 20, Some("answered")),
      offer("bob", joined_at + 20, None),
    ])
  let settled = [
    #("ann", "failed", "-"),
    #("ann", "answered", "-"),
    #("bob", "cancelled", "-"),
  ]
  assert outcomes(records.closed(open, Completed, joined_at + 60)) == settled
  assert outcomes(records.cancellation(open, types.Hangup, joined_at + 60))
    == settled
  // A record already closed is left alone, as `closed` leaves it.
  let ended = doc.set(open, ["ended"], doc.Int(joined_at + 30))
  assert records.closed(ended, Completed, joined_at + 60) == ended
}

// --- Reading it off the datastore ------------------------------------------

/// The document is found in the month the caller joined in, keyed by their
/// passage: call id, queue and the second they joined.
pub fn a_record_is_read_from_its_month_test() {
  let c = cluster.new([], [])
  cluster.put_record(
    c,
    0,
    cluster.record("call-one", "support", 0, [#("ann", 0, None)], None),
  )
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)

  let assert Ok(Some(passage)) = records.read(c.kz, member)
  assert passage.offer
    == Some(records.Offered(
      agents: ["ann"],
      at: cluster.start_of_time,
      leg_prefix: None,
      pickup: False,
    ))
}

/// A caller with no record at all is one nothing has happened to.
pub fn no_record_is_no_passage_test() {
  let c = cluster.new([], [])
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  assert records.read(c.kz, member) == Ok(None)
}

/// The datastore saying the document, or the month's database, is not there
/// is no record; anything else it says is not a record read, and a takeover
/// must not take it for none (`call/recovery`). The call id document an
/// earlier release wrote is looked for too, so a datastore that answers for
/// the passage's own id and not for that one has not been read either.
pub fn a_record_not_read_is_not_no_record_test() {
  let c = cluster.new([], [])
  let member = cluster.member("call-one", "support", 0, cluster.start_of_time)
  let answering = fn(own, legacy) {
    Kazoo(
      ..c.kz,
      datamgr: Datamgr(..c.kz.datamgr, open_doc: fn(_db, id) {
        case id == member.call_id {
          True -> Error(legacy)
          False -> Error(own)
        }
      }),
    )
  }
  let cases = [
    #(NotFound, NotFound, Ok(None)),
    #(Invalid("db_not_found"), Invalid("db_not_found"), Ok(None)),
    #(NotFound, Invalid("db_not_found"), Ok(None)),
    #(Unavailable, NotFound, Error(Unavailable)),
    #(Invalid("timeout"), NotFound, Error(Invalid("timeout"))),
    #(Invalid("econnrefused"), NotFound, Error(Invalid("econnrefused"))),
    #(NotFound, Invalid("timeout"), Error(Invalid("timeout"))),
  ]
  list.each(cases, fn(case_) {
    let #(own, legacy, read) = case_
    assert records.read(answering(own, legacy), member) == read
  })
}

/// A transfer is its own result on the wire, and reads back as itself.
pub fn a_transfer_is_a_result_of_its_own_test() {
  assert records.result_to_string(Transferred) == "transferred"
  assert records.result_from_string("transferred") == Transferred
}
