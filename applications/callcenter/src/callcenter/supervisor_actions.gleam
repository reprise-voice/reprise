//// What a supervisor does to a call from the live view: listen to it, or
//// take it.
////
//// Both are a supervisor's own phone being brought into somebody else's
//// call, and both name that phone the way the rest of Crossbar does -- a
//// `device_id` for one handset, a `user_id` for every handset the supervisor
//// owns -- with the `call_id` of the call to act on.
////
//// **Eavesdrop** originates to the supervisor and runs the switch's
//// `eavesdrop` application against the named channel, which is what the
//// eavesdrop callflow action does from inside a call. `mode` chooses what
//// the supervisor may do: `listen` hears both sides and says nothing, which
//// is the default; `whisper` is heard by the agent only; `full` is a
//// three-way call. It does not wait for the supervisor to answer: the answer
//// is the originate that went out.
////
//// **Which channel.** The `call_id` a client has is the caller's: the live
//// status names it for both the caller and the agent talking to them. The
//// switch's `eavesdrop` hears both sides of whichever channel it runs
//// against, so `listen` and `full` run against the caller's. What it mixes
//// the supervisor into is the mode `ecallmgr` asks for, and in FreeSWITCH
//// (`switch_ivr_eavesdrop_session`) that is relative to the channel
//// eavesdropped on: `full` (digit `3`) goes into what that channel's phone
//// hears and into what it sends its bridged partner, so both sides hear the
//// supervisor; `whisper` (digit `2`, `ED_MUX_WRITE`) goes into what that
//// channel's own phone hears and nowhere else. Run against the caller, a
//// whisper is heard by the caller. So `whisper` runs against the agent's leg
//// instead: the caller's channel's `Other-Leg-Call-ID`, which is asked about
//// as the caller's own channel was -- every channel under it the account's,
//// none in another queue -- and has to be answered and bridged back to the
//// caller. A caller nobody is talking to has nobody to whisper to, and is
//// refused.
////
//// **Pickup** is the other direction: a caller waiting in the queue is rung
//// through to the supervisor's phones, by the dispatcher holding the caller,
//// as an offer like an agent's (`callcenter/dispatcher/pickup`). The caller
//// hears the queue's music until the supervisor answers, stays in the queue
//// and is offered to nobody else while the phones ring, and leaves the queue
//// only when the supervisor answers. A supervisor who does not answer leaves
//// the caller waiting as they were. Crossbar answers once the dispatcher has
//// said what it did (`callcenter/pickup`), and the dispatcher says so once
//// the offer's bridge is out: a `202` is phones ringing. A supervisor none
//// of whose phones build to an endpoint on the caller's call is a 400 on
//// the phone's field, as one with no phone at all is.
////
//// ## Who may, and on what
////
//// Only an account administrator, or a superduper administrator, may do
//// either: `callcenter/permission`, which every other write that runs the
//// call center asks too. Anybody else is a 403, before anything else.
////
//// Nothing in the body is taken on trust. Before anything goes on the bus:
////
//// - the queue in the path is a queue document of the account, or the
////   answer is a 404;
//// - the device or user is a document of the account, and has at least one
////   phone that would ring, or the answer is a 400 on `device_id` or
////   `user_id`. A device of another account is not in this account's
////   database, and is refused the way a device nobody has is;
//// - the switches are asked about the call, and every channel they carry
////   under that id belongs to the account. A call no switch carries and a
////   call of another account are the same refusal, so the answer says
////   nothing about other accounts' calls. A channel that carries a
////   `Queue-ID` names this queue.
////
//// No answer from the switches is a refusal and not a permission.

import callcenter/call/originate
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/amqp
import kazoo/call.{type Call}
import kazoo/crossbar.{type Context}
import kazoo/doc.{type Value}
import kazoo/endpoints
import kazoo/events.{type Channel}
import kazoo/kazoo.{type Kazoo}

import callcenter/dispatcher/pickup as dispatch
import callcenter/permission
import callcenter/pickup
import callcenter/system

/// What a supervisor may hear and be heard by.
pub const modes = ["listen", "whisper", "full"]

pub const default_mode = "listen"

/// How long the supervisor's own phone rings before the switch gives up.
pub const ring_timeout_s = 30

/// The `pvt_type` of a queue document. `cb_queues` names it too; it cannot
/// be imported from there, because that module imports this one.
const queue_type = "queue"

/// The phone to bring in, and the call to bring it into.
pub type Target {
  Target(endpoint_id: String, endpoint_type: String, call_id: String)
}

/// The supervisor, as the account's documents say: who answers, and which
/// of their phones would ring.
pub type Supervisor {
  Supervisor(
    /// The user named, or the owner of the device named, or the device
    /// itself when nobody owns it.
    id: String,
    /// The device named, or every device the user owns, that would ring.
    device_ids: List(String),
  )
}

/// Everything eavesdrop and pickup reach outside the request, given rather
/// than found, so that the checks can be run against a fake.
pub type Io {
  Io(
    kz: Kazoo,
    /// What every switch says about one call:
    /// `events.channel_status_everywhere`, which is an error unless every
    /// switch answered.
    channel_status: fn(String) -> Result(List(Channel), amqp.Error),
    /// The devices of a target that would ring, in an account: the device
    /// itself, or each device the user owns, kept when it builds to at
    /// least one endpoint. Built for a call in the queue given -- a pickup's,
    /// which the offer builds on the caller's call -- or for none.
    phones: fn(String, Target, Option(String)) -> List(String),
    /// Put a request on the bus: `amqp.publish`.
    publish: fn(String, String, Value) -> Result(Nil, amqp.Error),
    /// Ask the node dispatching an account to ring a supervisor for one of
    /// its waiting callers: `pickup.ask_holder`.
    pick_up: fn(String, dispatch.Request) -> Result(dispatch.Answer, amqp.Error),
  )
}

/// The node's own.
pub fn live(kz: Kazoo) -> Io {
  Io(
    kz: kz,
    channel_status: fn(call_id) {
      events.channel_status_everywhere(app: system.category, call_id: call_id)
    },
    phones: phones,
    publish: fn(module, function, payload) {
      amqp.publish(module: module, function: function, payload: payload)
    },
    pick_up: pickup.ask_holder,
  )
}

/// Listen to an agent's call.
pub fn validate_eavesdrop(
  io: Io,
  context: Context,
  queue_id: String,
) -> Context {
  let checked = {
    use Nil <- result.try(permitted(context))
    use target <- result.try(target(context))
    use mode <- result.try(mode(context))
    use account_id <- result.try(account(context))
    use _queue <- result.try(queue(io.kz, context, account_id, queue_id))
    use _supervisor <- result.try(supervisor(
      io,
      context,
      account_id,
      target,
      None,
    ))
    use channels <- result.try(owned(
      io,
      context,
      account_id,
      queue_id,
      target.call_id,
    ))
    use leg <- result.try(eavesdropped(
      io,
      context,
      account_id,
      queue_id,
      target.call_id,
      mode,
      channels,
    ))
    Ok(#(account_id, target, mode, leg))
  }
  case checked {
    Error(context) -> context
    Ok(#(account_id, target, mode, leg)) ->
      publish(
        io,
        context,
        "resource",
        "originate_req",
        eavesdrop_request(account_id, queue_id, target, mode, leg),
        fn() {
          "eavesdrop ("
          <> mode
          <> ") on "
          <> leg
          <> " of call "
          <> target.call_id
          <> " for "
          <> target.endpoint_id
        },
      )
  }
}

/// Ring the supervisor's own phones for a caller waiting in the queue.
pub fn validate_pickup(io: Io, context: Context, queue_id: String) -> Context {
  let checked = {
    use Nil <- result.try(permitted(context))
    use target <- result.try(target(context))
    use account_id <- result.try(account(context))
    use _queue <- result.try(queue(io.kz, context, account_id, queue_id))
    use supervisor <- result.try(supervisor(
      io,
      context,
      account_id,
      target,
      Some(queue_id),
    ))
    use _channels <- result.try(owned(
      io,
      context,
      account_id,
      queue_id,
      target.call_id,
    ))
    Ok(#(account_id, target, supervisor))
  }
  case checked {
    Error(context) -> context
    Ok(#(account_id, target, supervisor)) -> {
      let request = pickup_request(queue_id, target, supervisor)
      picked_up(context, request, io.pick_up(account_id, request))
    }
  }
}

/// What the dispatcher is asked to do.
pub fn pickup_request(
  queue_id: String,
  target: Target,
  supervisor: Supervisor,
) -> dispatch.Request {
  dispatch.Request(
    queue_id: queue_id,
    call_id: target.call_id,
    supervisor_id: supervisor.id,
    target_type: target.endpoint_type,
    target_id: target.endpoint_id,
    device_ids: supervisor.device_ids,
  )
}

/// The dispatcher's answer, as Crossbar gives it: `202` with what is
/// ringing, `404` for a caller the holder says is not waiting in the queue,
/// `409` for a caller or a supervisor already being rung for, and a `5xx`
/// when nothing could be done and asking again may help -- `503` for no
/// answer in time, from the holder's dispatcher or from any holder at all.
pub fn picked_up(
  context: Context,
  request: dispatch.Request,
  answer: Result(dispatch.Answer, amqp.Error),
) -> Context {
  case answer {
    Ok(dispatch.Ringing(ring_timeout_s)) -> {
      system.log(
        "ringing "
        <> request.target_type
        <> " "
        <> request.target_id
        <> " for call "
        <> request.call_id,
      )
      crossbar.respond(context, started(request, ring_timeout_s))
    }
    // A holder's own answer: it holds the account's shard and nobody with
    // that call id is waiting in the queue.
    Ok(dispatch.NotWaiting) ->
      crossbar.add_error(
        context,
        404,
        "not_waiting",
        "no caller is waiting in this queue with that call_id",
      )
    // Nobody answered in time: a holder too slow, or no node holding the
    // shard for the moment. Neither says the caller is not waiting, and the
    // request's deadline, now past, keeps any holder from ringing for it.
    Error(amqp.NoAnswer) ->
      crossbar.add_error(
        context,
        503,
        "no_answer",
        "the node dispatching the account did not answer in time; nothing was rung",
      )
    Ok(dispatch.BeingOffered) ->
      crossbar.add_error(
        context,
        409,
        "being_offered",
        "a phone is already ringing for that caller; ask again once it has stopped",
      )
    Ok(dispatch.SupervisorBusy) ->
      crossbar.add_error(
        context,
        409,
        "supervisor_busy",
        "that phone is already ringing for, or talking to, another caller of this account",
      )
    // None of the phones built to an endpoint on the caller's own call:
    // the request's mistake, or the caller is on one of them, and nothing
    // rang. The field is the one the request named the phones by.
    Ok(dispatch.NotStarted("no_endpoints"))
    | Ok(dispatch.NotStarted("no_devices")) ->
      crossbar.add_validation_error(
        context,
        [request.target_type <> "_id"],
        "invalid",
        "none of that "
          <> request.target_type
          <> "'s phones can be rung for this caller: excluded from queues, disabled, on do not disturb, or the caller's own",
      )
    Ok(dispatch.NotStarted(reason)) -> {
      system.log_error(
        "could not ring "
        <> request.target_id
        <> " for call "
        <> request.call_id
        <> ": "
        <> reason,
      )
      crossbar.add_error(
        context,
        500,
        "not_started",
        "the supervisor's phones could not be rung: " <> reason,
      )
    }
    Ok(dispatch.TooLate) ->
      crossbar.add_error(
        context,
        503,
        "no_answer",
        "the node dispatching the account did not answer in time; nothing was rung",
      )
    Error(reason) -> {
      system.log_error(
        "could not ask for the pickup of "
        <> request.call_id
        <> ": "
        <> amqp.error_to_string(reason),
      )
      crossbar.add_system_error(context, "datastore_unreachable")
    }
  }
}

/// What a `202` carries: the call, the phone asked for, the devices ringing
/// and for how long.
fn started(request: dispatch.Request, ring_timeout_s: Int) -> Value {
  doc.object([
    #("call_id", doc.String(request.call_id)),
    #("queue_id", doc.String(request.queue_id)),
    #(request.target_type <> "_id", doc.String(request.target_id)),
    #("ringing", doc.List(list.map(request.device_ids, doc.String))),
    #("ring_timeout", doc.Int(ring_timeout_s)),
  ])
}

fn permitted(context: Context) -> Result(Nil, Context) {
  case permission.is_admin(context) {
    True -> Ok(Nil)
    False -> Error(crossbar.add_system_error(context, "forbidden"))
  }
}

fn account(context: Context) -> Result(String, Context) {
  case crossbar.account_id(context) {
    Some(account_id) -> Ok(account_id)
    None -> Error(crossbar.add_system_error(context, "bad_identifier"))
  }
}

/// The queue in the path, which has to be one of the account's.
fn queue(
  kz: Kazoo,
  context: Context,
  account_id: String,
  queue_id: String,
) -> Result(Value, Context) {
  case kz.datamgr.open_cache_doc(kazoo.account_db(account_id), queue_id) {
    Ok(document) ->
      case is_queue(document) {
        True -> Ok(document)
        False -> Error(crossbar.add_system_error(context, "bad_identifier"))
      }
    Error(kazoo.NotFound) ->
      Error(crossbar.add_system_error(context, "bad_identifier"))
    Error(_unreachable) ->
      Error(crossbar.add_system_error(context, "datastore_unreachable"))
  }
}

/// A queue document, and not one deleted.
pub fn is_queue(document: Value) -> Bool {
  doc.get_string(document, ["pvt_type"]) == Ok(queue_type)
  && doc.get_bool(document, ["pvt_deleted"]) != Ok(True)
}

/// The device or user the request named, which has to be the account's and
/// have a phone that would ring. Asked of both actions, before the switches
/// are asked anything: a supervisor's phone that is not there was the
/// request's mistake, and it is answered as one rather than as a request
/// that went out and rang nothing. A pickup's phones are built as its offer
/// builds them, for a call in `queue`: a device excluded from queues is
/// not one of them.
fn supervisor(
  io: Io,
  context: Context,
  account_id: String,
  target: Target,
  queue: Option(String),
) -> Result(Supervisor, Context) {
  let field = target.endpoint_type <> "_id"
  let not_ours =
    crossbar.add_validation_error(
      context,
      [field],
      "not_found",
      "no " <> target.endpoint_type <> " of this account has that id",
    )
  case
    io.kz.datamgr.open_cache_doc(
      kazoo.account_db(account_id),
      target.endpoint_id,
    )
  {
    Ok(document) ->
      case is_endpoint(document, target.endpoint_type) {
        False -> Error(not_ours)
        True ->
          case io.phones(account_id, target, queue) {
            [] ->
              Error(crossbar.add_validation_error(
                context,
                [field],
                "invalid",
                "that "
                  <> target.endpoint_type
                  <> " has no phone that can be rung: none, or every one disabled, on do not disturb, or excluded from queues",
              ))
            device_ids ->
              Ok(Supervisor(
                id: answerer(document, target),
                device_ids: device_ids,
              ))
          }
      }
    Error(kazoo.NotFound) -> Error(not_ours)
    Error(_unreachable) ->
      Error(crossbar.add_system_error(context, "datastore_unreachable"))
  }
}

/// A device or user document, of the kind the request said, and not one
/// deleted.
pub fn is_endpoint(document: Value, endpoint_type: String) -> Bool {
  doc.get_string(document, ["pvt_type"]) == Ok(endpoint_type)
  && doc.get_bool(document, ["pvt_deleted"]) != Ok(True)
}

/// Who answers when the phone is picked up: the user named, the owner of
/// the device named, or the device itself when nobody owns it. It is what
/// the caller's record and events name as whoever took them.
pub fn answerer(document: Value, target: Target) -> String {
  case target.endpoint_type, doc.get_string(document, ["owner_id"]) {
    "device", Ok(owner) if owner != "" -> owner
    _, _ -> target.endpoint_id
  }
}

/// What the switches' answer about a call says about a request.
pub type Ownership {
  /// Every channel carried under the call id is the account's, and none
  /// names another queue.
  Ours
  /// No switch carries the call, or one carries it for another account or
  /// for none.
  NotOurs
  /// The account's call, in another of its queues.
  OtherQueue
}

/// The call's channels judged against the account and the queue of the
/// request. Every channel has to be the account's: a call id is a string
/// anybody can send, and one channel of another account under it is
/// enough to refuse.
pub fn ownership(
  channels: List(Channel),
  account_id: String,
  queue_id: String,
) -> Ownership {
  let accounts_match =
    list.all(channels, fn(channel) { channel.account_id == Some(account_id) })
  let queues_match =
    list.all(channels, fn(channel) {
      case queue_of(channel) {
        None -> True
        Some(queue) -> queue == queue_id
      }
    })
  case channels, accounts_match, queues_match {
    [], _, _ -> NotOurs
    _, False, _ -> NotOurs
    _, True, False -> OtherQueue
    _, True, True -> Ours
  }
}

/// The queue a channel was put in, when it was put in one. A channel status
/// carries the custom channel variables in the bus's own case; a channel
/// query in snake case.
fn queue_of(channel: Channel) -> Option(String) {
  case events.custom_channel_var(channel.doc, "Queue-ID") {
    Some(queue) -> Some(queue)
    None ->
      doc.get_string(channel.doc, ["custom_channel_vars", "Queue-ID"])
      |> option.from_result
  }
}

/// The channels under a call id, when every one of them is the account's
/// and none is in another queue.
fn owned(
  io: Io,
  context: Context,
  account_id: String,
  queue_id: String,
  call_id: String,
) -> Result(List(Channel), Context) {
  case io.channel_status(call_id) {
    // Not every switch answered, or the question never went out: what is
    // under the call id on the switch that was silent is not known, and
    // nothing known is not permission.
    Error(reason) -> {
      system.log_error(
        "could not ask the switches about "
        <> call_id
        <> ": "
        <> amqp.error_to_string(reason),
      )
      Error(crossbar.add_system_error(context, "datastore_unreachable"))
    }
    Ok(channels) ->
      case ownership(channels, account_id, queue_id) {
        Ours -> Ok(channels)
        NotOurs ->
          Error(crossbar.add_validation_error(
            context,
            ["call_id"],
            "not_found",
            "no call of this account has that id",
          ))
        OtherQueue ->
          Error(crossbar.add_validation_error(
            context,
            ["call_id"],
            "not_found",
            "that call is not in this queue",
          ))
      }
  }
}

/// The channel the eavesdrop runs against: the named call's own for `listen`
/// and `full`, and for `whisper` the agent's leg bridged to it, which has to
/// pass the same checks the call did.
fn eavesdropped(
  io: Io,
  context: Context,
  account_id: String,
  queue_id: String,
  call_id: String,
  mode: String,
  channels: List(Channel),
) -> Result(String, Context) {
  let no_agent =
    crossbar.add_validation_error(
      context,
      ["call_id"],
      "not_connected",
      "nobody is talking to that caller: a whisper is heard by the agent on the call, and there is none",
    )
  case mode {
    "whisper" ->
      case agent_leg(channels, call_id) {
        Error(Nil) -> Error(no_agent)
        Ok(leg) -> {
          use legs <- result.try(owned(io, context, account_id, queue_id, leg))
          case is_talking_to(legs, call_id) {
            True -> Ok(leg)
            False -> Error(no_agent)
          }
        }
      }
    _listen_or_full -> Ok(call_id)
  }
}

/// The leg the caller's channels say they are bridged to: exactly one other
/// leg named, and not the call itself. None, or more than one, is nobody to
/// whisper to.
pub fn agent_leg(
  channels: List(Channel),
  call_id: String,
) -> Result(String, Nil) {
  case
    channels
    |> list.filter_map(fn(channel) { option.to_result(channel.other_leg, Nil) })
    |> list.filter(fn(leg) { leg != "" && leg != call_id })
    |> list.unique
  {
    [leg] -> Ok(leg)
    _none_or_several -> Error(Nil)
  }
}

/// Whether the channels under an agent's leg are an answered call bridged
/// back to the caller. `ecallmgr` sets both legs' `Other-Leg-Call-ID` on the
/// bridge and clears both on the unbridge, so a leg still ringing, or one
/// bridged to somebody else by now, is not the agent on the caller's call.
pub fn is_talking_to(legs: List(Channel), call_id: String) -> Bool {
  legs != []
  && list.all(legs, fn(leg) { leg.answered && leg.other_leg == Some(call_id) })
}

/// The supervisor's phone and the call, from the request body. An empty
/// id is no id: a `device_id` of `""` falls through to `user_id`, and
/// neither is a 400.
pub fn target(context: Context) -> Result(Target, Context) {
  let body = crossbar.req_data(context)
  case non_empty(body, "call_id") {
    None ->
      Error(crossbar.add_validation_error(
        context,
        ["call_id"],
        "required",
        "the call to act on",
      ))
    Some(call_id) ->
      case non_empty(body, "device_id"), non_empty(body, "user_id") {
        Some(device_id), _ -> Ok(Target(device_id, "device", call_id))
        None, Some(user_id) -> Ok(Target(user_id, "user", call_id))
        None, None ->
          Error(crossbar.add_validation_error(
            context,
            ["device_id"],
            "required",
            "the supervisor's own device or user",
          ))
      }
  }
}

fn non_empty(body: Value, key: String) -> Option(String) {
  case doc.get_string(body, [key]) {
    Ok("") | Error(Nil) -> None
    Ok(found) -> Some(found)
  }
}

pub fn mode(context: Context) -> Result(String, Context) {
  case doc.get_string(crossbar.req_data(context), ["mode"]) {
    Error(Nil) -> Ok(default_mode)
    Ok(mode) ->
      case list.contains(modes, mode) {
        True -> Ok(mode)
        False ->
          Error(crossbar.add_validation_error(
            context,
            ["mode"],
            "enum",
            "listen, whisper or full",
          ))
      }
  }
}

/// The originate that rings the supervisor and puts them on the call:
/// `eavesdrop` against `leg`, the channel `eavesdropped` chose, which is
/// also the `Existing-Call-ID` -- how `ecallmgr` finds the switch to
/// originate on.
pub fn eavesdrop_request(
  account_id: String,
  queue_id: String,
  target: Target,
  mode: String,
  leg: String,
) -> Value {
  doc.merge(
    amqp.default_headers("callcenter", "resource", "originate_req"),
    doc.object([
      #("Application-Name", doc.String("eavesdrop")),
      #("Eavesdrop-Call-ID", doc.String(leg)),
      #("Eavesdrop-Mode", doc.String(mode)),
      #("Endpoints", doc.List(supervisor_endpoints(account_id, target))),
      #("Existing-Call-ID", doc.String(leg)),
      #("Timeout", doc.Int(ring_timeout_s)),
      #("Continue-On-Fail", doc.Bool(False)),
      #("Dial-Endpoint-Method", doc.String("simultaneous")),
      #("Ignore-Early-Media", doc.Bool(True)),
      #("Media", doc.String("process")),
      #("Start-Control-Process", doc.Bool(False)),
      #(
        "Custom-Channel-Vars",
        doc.object([
          #("Account-ID", doc.String(account_id)),
          #("Authorizing-ID", doc.String(target.endpoint_id)),
          #("Authorizing-Type", doc.String(target.endpoint_type)),
          #("Queue-ID", doc.String(queue_id)),
          #("Callcenter-Supervisor", doc.Bool(True)),
        ]),
      ),
      #(
        "Export-Custom-Channel-Vars",
        doc.List([
          doc.String("Account-ID"),
          doc.String("Authorizing-ID"),
          doc.String("Authorizing-Type"),
          doc.String("Queue-ID"),
        ]),
      ),
    ]),
  )
}

/// The supervisor's phones, as the switch takes them for an originate.
fn supervisor_endpoints(account_id: String, target: Target) -> List(Value) {
  case
    endpoints.build_with(synthetic(account_id), target.endpoint_id, props())
  {
    Ok(built) -> built
    Error(_) -> []
  }
}

/// The devices of a target that would ring: `Io.phones` on a node. Each is
/// built on its own, as the pickup's offer builds them, and one that builds
/// to nothing -- disabled, on do not disturb -- is left out.
///
/// For a pickup (`queue` given) with the rules the offer builds with: the
/// call carries the queue's `Queue-ID`, as the caller's does, so a device
/// with `exclude_from_queues` builds to nothing, and there is no
/// `can_call_self`. What only the caller's own call can say -- that the
/// caller is on one of these phones -- is left to the offer, whose
/// `no_endpoints` the dispatcher answers before Crossbar does.
fn phones(
  account_id: String,
  target: Target,
  queue: Option(String),
) -> List(String) {
  let #(call, props) = case queue {
    None -> #(synthetic(account_id), props())
    Some(queue_id) -> #(
      synthetic_in(account_id, queue_id),
      originate.properties(),
    )
  }
  case target.endpoint_type {
    "user" ->
      endpoints.owned_by(
        kazoo.account_db(account_id),
        target.endpoint_id,
        "device",
      )
    _device -> [target.endpoint_id]
  }
  |> list.filter(fn(device_id) {
    case endpoints.build_with(call, device_id, props) {
      Ok([_, ..]) -> True
      _nothing -> False
    }
  })
}

/// The call a pickup's phones are built for: a call in the queue.
pub fn synthetic_in(account_id: String, queue_id: String) -> Call {
  call.from_value(
    doc.object([
      #("Account-ID", doc.String(account_id)),
      #("Account-DB", doc.String(kazoo.account_db(account_id))),
      #("Resource-Type", doc.String("audio")),
      #(
        "Custom-Channel-Vars",
        doc.object([#("Queue-ID", doc.String(queue_id))]),
      ),
    ]),
  )
}

/// The call a supervisor's phone is built for outside any call.
///
/// The supervisor's phone is where this call is going, not where it came
/// from, so the call carries no authorizing endpoint: a call authorized by
/// the device it is ringing is a device calling itself, which is refused.
/// `can_call_self` covers the real case of that -- a supervisor listening
/// in on a call one of their own phones is already on.
fn synthetic(account_id: String) -> Call {
  call.from_value(
    doc.object([
      #("Account-ID", doc.String(account_id)),
      #("Account-DB", doc.String(kazoo.account_db(account_id))),
      #("Resource-Type", doc.String("audio")),
    ]),
  )
}

fn props() -> Value {
  doc.object([
    #("can_call_self", doc.Bool(True)),
    #("source", doc.String("callcenter")),
  ])
}

/// Send the request and answer it back, so that a client can see what went
/// out even though nothing has happened yet.
fn publish(
  io: Io,
  context: Context,
  module: String,
  function: String,
  request: Value,
  describe: fn() -> String,
) -> Context {
  case io.publish(module, function, request) {
    Error(reason) -> {
      system.log_error(
        "could not start the "
        <> describe()
        <> ": "
        <> amqp.error_to_string(reason),
      )
      crossbar.add_system_error(context, "datastore_unreachable")
    }
    Ok(Nil) -> {
      system.log("started the " <> describe())
      crossbar.respond(context, answer(request))
    }
  }
}

/// What went out, without the envelope nobody outside the bus reads.
fn answer(request: Value) -> Value {
  list.fold(
    [
      "Event-Category", "Event-Name", "App-Name", "App-Version", "Node",
      "Msg-ID", "Server-ID",
    ],
    request,
    fn(value, key) { doc.delete(value, [key]) },
  )
}
