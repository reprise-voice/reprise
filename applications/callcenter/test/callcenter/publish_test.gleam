//// Where the dispatcher's events about one caller go.

import callcenter/dispatcher/publish.{Caller, Exchange}
import callcenter/member
import callcenter/types.{type Member, Member}
import gleam/option.{None, Some}
import kazoo/doc

const controller_queue = "pid://<0.4242.0>/callflow_route_9f8e7d6c"

fn waiting_with(call: doc.Value) -> Member {
  Member(
    account_id: "4b1f0c2d7e8a9b0c1d2e3f4051627384",
    queue_id: "support",
    call_id: "call-one",
    call: call,
    priority: 0,
    joined: 63_900_000_000,
    callflow_node: "kazoo_apps@one",
    caller_id_name: None,
    caller_id_number: None,
    delivery: member.no_delivery(),
  )
}

fn routed_call() -> doc.Value {
  doc.object([
    #("Call-ID", doc.String("call-one")),
    #("Controller-Queue", doc.String(controller_queue)),
  ])
}

/// A caller whose call says where its callflow is hears the dispatcher
/// there, and the exchange carries the same event for whoever watches.
pub fn a_caller_is_told_at_their_controller_queue_test() {
  assert publish.call_targets(waiting_with(routed_call()))
    == [Exchange, Caller(controller_queue)]
}

/// A call that does not say -- a stub, or a caller rebuilt from their
/// record -- is published on the exchange alone.
pub fn a_call_with_no_controller_queue_is_only_published_test() {
  assert publish.call_targets(waiting_with(member.stub_call("call-one", "fs1")))
    == [Exchange]
  let empty =
    doc.object([
      #("Call-ID", doc.String("call-one")),
      #("Controller-Queue", doc.String("")),
    ])
  assert publish.call_targets(waiting_with(empty)) == [Exchange]
}

pub fn the_controller_queue_is_read_off_the_call_test() {
  assert member.controller_queue(routed_call()) == Some(controller_queue)
  assert member.controller_queue(doc.object([])) == None
}

/// Without a broker every publish is refused, and the dispatcher carries on:
/// an event that could not reach a callflow node that has gone is not an
/// error anybody acts on.
pub fn publishing_to_a_caller_with_no_broker_does_not_fail_test() {
  assert publish.call("account", "member_offer", waiting_with(routed_call()), [
      #("Agent-IDs", doc.List([doc.String("agent-a")])),
      #("Offer-Timeout", doc.Int(20)),
    ])
    == Nil
}

/// The dispatcher's own publish goes through `kapi_callcenter`, so the key
/// its events go out under is the one every binding is built from: a SIP
/// Call-ID's dots and `@` are escaped into one word of it. The caller's
/// callflow hears the same event at its controller queue, which takes no
/// key at all.
pub fn a_dispatcher_event_goes_out_under_the_escaped_key_test() {
  let sip_call_id = "3c2a1f.9e@pbx.example.com"
  let member =
    Member(
      ..waiting_with(
        doc.object([
          #("Call-ID", doc.String(sip_call_id)),
          #("Controller-Queue", doc.String(controller_queue)),
        ]),
      ),
      call_id: sip_call_id,
    )

  let platform = platform_start()
  publish.position(
    member.account_id,
    member,
    2,
    3,
    Some(1),
    False,
    63_900_000_010,
  )
  let published = platform_published()
  let targeted = platform_targeted()
  platform_stop(platform)

  assert published
    == [
      #(
        "callcenter",
        "callcenter.call."
          <> member.account_id
          <> ".3c2a1f%2E9e%40pbx%2Eexample%2Ecom",
      ),
    ]
  assert published
    == [#("callcenter", call_routing_key(member.account_id, sip_call_id))]
  assert targeted == [controller_queue]
}

type Platform

@external(erlang, "platform_fakes", "start")
fn platform_start() -> Platform

@external(erlang, "platform_fakes", "stop")
fn platform_stop(platform: Platform) -> Nil

@external(erlang, "platform_fakes", "published")
fn platform_published() -> List(#(String, String))

@external(erlang, "platform_fakes", "targeted")
fn platform_targeted() -> List(String)

@external(erlang, "kapi_callcenter", "call_routing_key")
fn call_routing_key(account_id: String, call_id: String) -> String
