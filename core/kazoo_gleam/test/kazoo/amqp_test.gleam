//// Publishing on a node with no broker: every path degrades, and none of
//// them raises.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import kazoo/amqp
import kazoo/doc

pub fn error_to_string_test() {
  assert amqp.error_to_string(amqp.Unavailable) == "unavailable"
  assert amqp.error_to_string(amqp.NoAnswer) == "no_answer"
  assert amqp.error_to_string(amqp.Failed("returned")) == "returned"
}

/// No release means no `kz_amqp_worker' and no `kapi' module, which is one
/// answer and not two: the message did not go out.
pub fn publish_without_a_release_test() {
  assert amqp.publish(
      module: "switch",
      function: "notify",
      payload: doc.object([#("Event", doc.String("check-sync"))]),
    )
    == Error(amqp.Unavailable)
}

pub fn call_without_a_release_test() {
  assert amqp.call(
      module: "call",
      function: "channel_status_req",
      payload: doc.object([#("Call-ID", doc.String("call-one"))]),
      timeout: 100,
    )
    == Error(amqp.Unavailable)
}

pub fn call_collect_without_a_release_test() {
  assert amqp.call_collect(
      module: "call",
      function: "query_account_channels_req",
      payload: doc.object([]),
      until: amqp.Ecallmgr,
      timeout: 100,
    )
    == Error(amqp.Unavailable)

  assert amqp.call_collect(
      module: "call",
      function: "query_account_channels_req",
      payload: doc.object([]),
      until: amqp.Count(2),
      timeout: 100,
    )
    == Error(amqp.Unavailable)

  assert amqp.call_collect(
      module: "call",
      function: "query_account_channels_req",
      payload: doc.object([]),
      until: amqp.Deadline,
      timeout: 100,
    )
    == Error(amqp.Unavailable)

  assert amqp.call_collect_all(
      module: "call",
      function: "channel_status_req",
      payload: doc.object([]),
      until: amqp.Ecallmgr,
      timeout: 100,
    )
    == Error(amqp.Unavailable)
}

/// How a collection ended is part of its answer. The timeout ending one
/// with answers in it is a node that was restarting, and the answers are
/// the result; the timeout ending one with nothing in it is a request
/// nobody heard, which is not an empty cluster and must not read as one.
pub fn a_collection_nobody_answered_is_no_answer_test() {
  assert amqp.collected([], finished: False) == Error(amqp.NoAnswer)
}

/// A collection that finished with nothing in it is the worker saying there
/// was nobody to ask -- `kz_nodes` counted no node, and nothing was
/// published -- which is no answer either, not an empty cluster.
pub fn a_collection_nobody_was_asked_is_no_answer_test() {
  assert amqp.collected([], finished: True) == Error(amqp.NoAnswer)
}

pub fn the_answers_that_arrived_are_the_result_test() {
  let answer = doc.object([#("Status", doc.String("active"))])
  assert amqp.collected([answer], finished: False) == Ok([answer])
  assert amqp.collected([answer], finished: True) == Ok([answer])
}

/// Off a node there are no default headers, and a request built from them is
/// still a document: a test can assert on the fields it did set.
pub fn default_headers_without_a_release_test() {
  assert amqp.default_headers("callcenter", "channel", "channel_status_req")
    == doc.object([])

  let request =
    doc.merge(
      amqp.default_headers("callcenter", "channel", "channel_status_req"),
      doc.object([#("Call-ID", doc.String("call-one"))]),
    )
  assert doc.get_string(request, ["Call-ID"]) == Ok("call-one")
}

/// A plain work queue is fed through the default exchange, with no `kapi`
/// module in the way at all -- and still nothing without a broker.
pub fn publish_to_queue_without_a_release_test() {
  assert amqp.publish_to_queue(
      queue: "callcenter.lease.7",
      payload: doc.object([#("Shard", doc.Int(7))]),
    )
    == Error(amqp.Unavailable)
}

/// An answer is published at the queue the request named, which is the same
/// nothing without a release.
pub fn publish_to_without_a_release_test() {
  assert amqp.publish_to(
      target: "callcenter-answers",
      module: "self",
      function: "message",
      payload: doc.object([]),
    )
    == Error(amqp.Unavailable)
}

// --- Confirmed publishing --------------------------------------------------

pub fn publish_to_confirmed_without_a_release_test() {
  assert amqp.publish_to_confirmed(
      target: "3",
      module: "callcenter",
      function: "member_call",
      payload: doc.object([]),
      timeout: 100,
    )
    == Error(amqp.Unavailable)
}

@external(erlang, "kazoo_gleam_listener", "as_term")
fn term(value: anything) -> Dynamic

fn basic_ack() -> Dynamic {
  term(#(atom.create("basic.ack"), 1, False))
}

fn basic_nack() -> Dynamic {
  term(#(atom.create("basic.nack"), 1, False, True))
}

/// A `basic.return` arrives with the message it returns.
fn basic_return() -> Dynamic {
  term(#(
    #(atom.create("basic.return"), 312, "NO_ROUTE", "", "callcenter.member.63"),
    #(atom.create("amqp_msg"), Nil, "{}"),
  ))
}

/// The broker's ack is the message taken. The ack of a message it returned
/// first is the message routed nowhere: a member
/// published to a shard queue nobody declared, which vanished and left the
/// caller waiting for ever.
pub fn a_returned_message_is_not_published_test() {
  assert amqp.confirmed(False, [basic_ack()]) == Ok(Nil)
  assert amqp.confirmed(False, [basic_return(), basic_ack()])
    == Error(amqp.Failed("returned"))
  assert amqp.confirmed(False, [basic_nack()]) == Error(amqp.Failed("nacked"))
}

/// Anything else on the channel is passed over, and no confirmation at all
/// is not knowing.
pub fn no_confirmation_is_no_answer_test() {
  let flow = term(#(atom.create("channel.flow"), True))
  assert amqp.confirmed(False, [flow, basic_ack()]) == Ok(Nil)
  assert amqp.confirmed(False, [basic_return()]) == Error(amqp.NoAnswer)
  assert amqp.confirmed(False, []) == Error(amqp.NoAnswer)
}

// --- One channel for every confirmed message -------------------------------

fn published(tag: Int, msg_id: String) -> Dynamic {
  term(#(atom.create("published"), tag, msg_id))
}

fn ack(tag: Int, multiple: Bool) -> Dynamic {
  term(#(atom.create("basic.ack"), tag, multiple))
}

fn nack(tag: Int, multiple: Bool) -> Dynamic {
  term(#(atom.create("basic.nack"), tag, multiple, False))
}

/// A `basic.return` of the message with that `Msg-ID`: no delivery tag, only
/// the message.
fn returned(msg_id: String) -> Dynamic {
  term(#(
    #(atom.create("basic.return"), 312, "NO_ROUTE", "", "callcenter.member.63"),
    #(
      atom.create("amqp_msg"),
      Nil,
      doc.to_string(doc.object([#("Msg-ID", doc.String(msg_id))])),
    ),
  ))
}

/// A message published with an expiry of its own, as the publisher gives
/// every message; `published` is one whose expiry is its tag.
fn published_expiring(tag: Int, msg_id: String, expiry: String) -> Dynamic {
  term(#(atom.create("published"), tag, msg_id, expiry))
}

fn expire(expiry: anything) -> Dynamic {
  term(#(atom.create("expire"), expiry))
}

/// Acks name a delivery tag, and answer that message and no other, in
/// whatever order the broker sends them.
pub fn an_ack_answers_its_own_message_test() {
  assert amqp.confirmations([
      published(1, "a"),
      published(2, "b"),
      published(3, "c"),
      ack(2, False),
      ack(3, False),
      ack(1, False),
    ])
    == [#(2, Ok(Nil)), #(3, Ok(Nil)), #(1, Ok(Nil))]
}

/// `multiple` answers every message waiting up to the tag, oldest first, and
/// none after it.
pub fn a_multiple_ack_answers_everything_up_to_it_test() {
  assert amqp.confirmations([
      published(1, "a"),
      published(2, "b"),
      published(3, "c"),
      nack(2, True),
      ack(3, False),
    ])
    == [
      #(1, Error(amqp.Failed("nacked"))),
      #(2, Error(amqp.Failed("nacked"))),
      #(3, Ok(Nil)),
    ]
}

/// A return is matched on the message's `Msg-ID`, and makes that message's
/// ack a `returned` -- whichever of the messages waiting it was, and
/// whether its ack came alone or with others'.
pub fn a_return_is_matched_on_the_message_test() {
  assert amqp.confirmations([
      published(1, "a"),
      published(2, "b"),
      published(3, "c"),
      returned("b"),
      ack(3, True),
    ])
    == [#(1, Ok(Nil)), #(2, Error(amqp.Failed("returned"))), #(3, Ok(Nil))]
}

/// Two messages carrying the same `Msg-ID`: a return is the older one's,
/// and a second return the younger's.
pub fn a_return_is_the_oldest_of_the_same_id_test() {
  assert amqp.confirmations([
      published(1, "same"),
      published(2, "same"),
      returned("same"),
      ack(2, True),
    ])
    == [#(1, Error(amqp.Failed("returned"))), #(2, Ok(Nil))]
  assert amqp.confirmations([
      published(1, "same"),
      published(2, "same"),
      returned("same"),
      returned("same"),
      ack(2, True),
    ])
    == [
      #(1, Error(amqp.Failed("returned"))),
      #(2, Error(amqp.Failed("returned"))),
    ]
}

/// A return of a message nobody is waiting for any more, or one that names
/// no id this publisher gave, changes nothing.
pub fn a_stray_return_changes_nothing_test() {
  assert amqp.confirmations([
      published(1, "a"),
      returned("gone"),
      ack(1, False),
    ])
    == [#(1, Ok(Nil))]
}

/// A message whose time ran out is `NoAnswer`, and its late ack is
/// nobody's; a lost channel is `NoAnswer` for everything still waiting.
pub fn what_is_not_confirmed_is_no_answer_test() {
  assert amqp.confirmations([
      published(1, "a"),
      published(2, "b"),
      published(3, "c"),
      expire(1),
      ack(1, False),
      atom_term("lost_channel"),
      ack(3, False),
    ])
    == [
      #(1, Error(amqp.NoAnswer)),
      #(2, Error(amqp.NoAnswer)),
      #(3, Error(amqp.NoAnswer)),
    ]
}

/// Tags start again at one on every channel. An expiry that was on its way
/// when the last channel went is that message's, and settles nothing on
/// the next channel -- not the message that has the same tag there.
pub fn a_stale_expiry_is_nobody_s_test() {
  assert amqp.confirmations([
      published_expiring(1, "a", "first"),
      atom_term("lost_channel"),
      published_expiring(1, "b", "second"),
      expire("first"),
      ack(1, False),
    ])
    == [#(1, Error(amqp.NoAnswer)), #(1, Ok(Nil))]
  assert amqp.confirmations([
      published_expiring(1, "a", "first"),
      published_expiring(2, "b", "second"),
      expire("second"),
      ack(2, True),
    ])
    == [#(2, Error(amqp.NoAnswer)), #(1, Ok(Nil))]
}

/// A tag already waiting is not given to a second message: the one waiting
/// keeps it and is answered by its ack, and the second, which cannot be
/// told apart from it, is `NoAnswer` at once.
pub fn a_waiting_tag_is_not_overwritten_test() {
  assert amqp.confirmations([
      published_expiring(1, "a", "first"),
      published_expiring(1, "b", "second"),
      expire("second"),
      ack(1, False),
    ])
    == [#(1, Error(amqp.NoAnswer)), #(1, Ok(Nil))]
}

fn atom_term(name: String) -> Dynamic {
  term(atom.create(name))
}

@external(erlang, "confirming_publisher_ffi", "lifecycle")
fn lifecycle() -> List(#(String, Dynamic))

/// The publisher's life with a channel the test plays: nothing published
/// before it has a channel in confirm mode, each answer on one, a publish
/// the channel refused answered at once without taking a tag, a message
/// that could not be built answered with its reason and nothing sent, every
/// message waiting when it goes answered, the next channel's tags counted
/// from one and out of reach of the last channel's expiries, and a channel
/// found gone at the publish, or gone by the time it is published on,
/// `not_ready` rather than waited on.
pub fn the_confirming_publisher_lives_through_its_channels_test() {
  let ok = term(Ok(Nil))
  let no_answer = term(Error("no_answer"))
  let not_ready = term(Error(atom.create("not_ready")))
  let unavailable = Error("unavailable")
  assert lifecycle()
    == [
      #("before a channel", not_ready),
      #("acked", ok),
      #("acked with one returned", term(#(Ok(Nil), Error("returned")))),
      #("nacked", term(Error("nacked"))),
      #("not confirmed", no_answer),
      #(
        "refused by the channel",
        term(#(unavailable, unavailable, Ok(Nil), Ok(Nil))),
      ),
      #("not built", term(#(Error("invalid"), Error("not_a_message"), Ok(Nil)))),
      #("channel lost", no_answer),
      #("without a channel", not_ready),
      #("lost while its channel was replaced", no_answer),
      #("the next channel", ok),
      #("channel gone at the publish", not_ready),
      #("channel gone before the publish", not_ready),
      #("still running", term(True)),
    ]
}
