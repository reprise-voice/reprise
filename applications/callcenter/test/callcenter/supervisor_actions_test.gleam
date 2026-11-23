//// Eavesdrop and pickup: who may ask, what the body has to say, what is
//// checked about the supervisor's phone and the call before anything is
//// done, and what goes on the bus as a result.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/amqp
import kazoo/crossbar
import kazoo/doc
import kazoo/events.{type Channel}
import kazoo/kazoo
import kazoo/testing/fake

import callcenter/dispatcher/pickup as dispatch
import callcenter/supervisor_actions.{type Io, Io, Supervisor, Target}

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

const queue = "37139638ff5b68f155d8445178524df1"

const call = "5c7a1d2e-3f40-4a5b-8c9d-0e1f2a3b4c5d"

/// The supervisor's desk phone, owned by the supervisor.
const device = "9f8e7d6c"

const supervisor = "3a1b5c7d"

/// Another account, whose calls this one's administrator knows the ids of.
const other_account = "8e2a4c6b0d1f3e5a7c9b1d3f5e7a9c0b"

/// Another queue of the same account.
const other_queue = "c0ffee00c0ffee00c0ffee00c0ffee00"

fn asking(fields: List(#(String, doc.Value))) -> crossbar.Context {
  crossbar.new() |> crossbar.set_req_data(doc.object(fields))
}

/// One of `device_id` and `user_id` names the supervisor's phone; the
/// device wins when a client sends both, because it is the more specific.
pub fn target_test() {
  assert supervisor_actions.target(
      asking([
        #("device_id", doc.String("9f8e7d6c")),
        #("call_id", doc.String(call)),
      ]),
    )
    == Ok(Target("9f8e7d6c", "device", call))

  assert supervisor_actions.target(
      asking([
        #("user_id", doc.String("3a1b5c7d")),
        #("call_id", doc.String(call)),
      ]),
    )
    == Ok(Target("3a1b5c7d", "user", call))

  assert supervisor_actions.target(
      asking([
        #("device_id", doc.String("9f8e7d6c")),
        #("user_id", doc.String("3a1b5c7d")),
        #("call_id", doc.String(call)),
      ]),
    )
    == Ok(Target("9f8e7d6c", "device", call))
}

/// Neither the call nor the phone is guessed at: a request that leaves one
/// out is refused rather than acted on.
pub fn target_is_required_test() {
  assert is_refused(
    supervisor_actions.target(asking([#("device_id", doc.String("9f8e7d6c"))])),
  )
  assert is_refused(
    supervisor_actions.target(asking([#("call_id", doc.String(call))])),
  )
  assert is_refused(supervisor_actions.target(asking([])))
}

/// An empty id is no id. A `device_id` of `""` used to be a target
/// with nothing to ring, and a `202`.
pub fn an_empty_id_is_no_id_test() {
  assert is_refused(
    supervisor_actions.target(
      asking([#("device_id", doc.String("")), #("call_id", doc.String(call))]),
    ),
  )
  assert is_refused(
    supervisor_actions.target(
      asking([
        #("device_id", doc.String("")),
        #("user_id", doc.String("")),
        #("call_id", doc.String(call)),
      ]),
    ),
  )
  assert is_refused(
    supervisor_actions.target(
      asking([
        #("device_id", doc.String("9f8e7d6c")),
        #("call_id", doc.String("")),
      ]),
    ),
  )
  // An empty device with a user named is the user.
  assert supervisor_actions.target(
      asking([
        #("device_id", doc.String("")),
        #("user_id", doc.String("3a1b5c7d")),
        #("call_id", doc.String(call)),
      ]),
    )
    == Ok(Target("3a1b5c7d", "user", call))
}

pub fn mode_test() {
  assert supervisor_actions.mode(asking([])) == Ok("listen")
  assert supervisor_actions.mode(asking([#("mode", doc.String("whisper"))]))
    == Ok("whisper")
  assert supervisor_actions.mode(asking([#("mode", doc.String("full"))]))
    == Ok("full")
  assert is_refused(
    supervisor_actions.mode(asking([#("mode", doc.String("record"))])),
  )
}

/// The originate the switch takes: the eavesdrop application against the
/// named channel, with the queue on the supervisor's own leg so a CDR says
/// where they came from.
pub fn eavesdrop_request_test() {
  let request =
    supervisor_actions.eavesdrop_request(
      account,
      queue,
      Target("9f8e7d6c", "device", call),
      "listen",
      call,
    )
  assert doc.get_string(request, ["Application-Name"]) == Ok("eavesdrop")
  assert doc.get_string(request, ["Eavesdrop-Call-ID"]) == Ok(call)
  assert doc.get_string(request, ["Eavesdrop-Mode"]) == Ok("listen")
  assert doc.get_string(request, ["Existing-Call-ID"]) == Ok(call)
  assert doc.get_string(request, ["Custom-Channel-Vars", "Account-ID"])
    == Ok(account)
  assert doc.get_string(request, ["Custom-Channel-Vars", "Authorizing-ID"])
    == Ok("9f8e7d6c")
  assert doc.get_string(request, ["Custom-Channel-Vars", "Authorizing-Type"])
    == Ok("device")
  assert doc.get_string(request, ["Custom-Channel-Vars", "Queue-ID"])
    == Ok(queue)
  // No release here, so there is no endpoint to build; the switch is told so
  // rather than being sent a request with no `Endpoints` key at all.
  assert doc.get_list(request, ["Endpoints"]) == Ok([])
}

/// A pickup is a question to the dispatcher holding the caller: ring these
/// phones of this person for this caller. Nothing about konami: the old
/// pickup was a metaflow `intercept` that konami only acts on for a call
/// whose own phone has metaflows, which a caller from outside never has.
pub fn pickup_request_test() {
  let request =
    supervisor_actions.pickup_request(
      queue,
      Target(device, "device", call),
      Supervisor(id: supervisor, device_ids: [device]),
    )
  assert request
    == dispatch.Request(
      queue_id: queue,
      call_id: call,
      supervisor_id: supervisor,
      target_type: "device",
      target_id: device,
      device_ids: [device],
    )
}

/// Who answers: the user named, the owner of the device named, or the
/// device itself when nobody owns it.
pub fn the_answerer_is_a_person_where_there_is_one_test() {
  let owned =
    doc.object([
      #("pvt_type", doc.String("device")),
      #("owner_id", doc.String(supervisor)),
    ])
  let unowned = doc.object([#("pvt_type", doc.String("device"))])
  assert supervisor_actions.answerer(owned, Target(device, "device", call))
    == supervisor
  assert supervisor_actions.answerer(unowned, Target(device, "device", call))
    == device
  assert supervisor_actions.answerer(
      doc.set(unowned, ["owner_id"], doc.String("")),
      Target(device, "device", call),
    )
    == device
  assert supervisor_actions.answerer(
      doc.object([#("pvt_type", doc.String("user"))]),
      Target(supervisor, "user", call),
    )
    == supervisor
}

fn is_refused(answer: Result(a, b)) -> Bool {
  case answer {
    Error(_) -> True
    Ok(_) -> False
  }
}

// --- The checks ------------------------------------------------------------

@external(erlang, "crossbar_context_ffi", "context")
fn context_as(
  account_id: String,
  account_admin: Bool,
  superduper_admin: Bool,
) -> crossbar.Context

@external(erlang, "crossbar_context_ffi", "system_error")
fn system_error(context: crossbar.Context) -> Result(String, Nil)

@external(erlang, "crossbar_context_ffi", "error_code")
fn error_code(context: crossbar.Context) -> Result(Int, Nil)

@external(erlang, "crossbar_context_ffi", "validation_errors")
fn validation_errors(context: crossbar.Context) -> List(#(List(String), String))

/// Who is asking.
type Who {
  Admin
  Superduper
  User
}

fn request(who: Who) -> crossbar.Context {
  request_naming(who, [#("device_id", doc.String(device))])
}

fn request_naming(
  who: Who,
  phone: List(#(String, doc.Value)),
) -> crossbar.Context {
  let #(admin, superduper) = case who {
    Admin -> #(True, False)
    Superduper -> #(False, True)
    User -> #(False, False)
  }
  context_as(account, admin, superduper)
  |> crossbar.set_req_data(
    doc.object([#("call_id", doc.String(call)), ..phone]),
  )
}

/// A channel carrying the call, as a switch describes it in a channel
/// status.
fn channel(account_id: String, queue_id: Option(String)) -> Channel {
  events.channel(
    doc.object([
      #("Call-ID", doc.String(call)),
      #("Status", doc.String("active")),
      #(
        "Custom-Channel-Vars",
        doc.object_some([
          #("Account-ID", Some(doc.String(account_id))),
          #("Queue-ID", option.map(queue_id, doc.String)),
        ]),
      ),
    ]),
  )
}

/// What the request finds when it looks.
type World {
  World(
    /// Whether the queue in the path is in the account's database.
    queue: Bool,
    /// The documents in the account's database besides the queue: the
    /// supervisor's device and user, as the test wants them.
    documents: List(doc.Value),
    /// The devices that would ring, whatever was named.
    phones: List(String),
    channels: Result(List(Channel), amqp.Error),
    /// What the switches say about any other call id: an agent's leg.
    legs: List(#(String, Result(List(Channel), amqp.Error))),
    /// What the node dispatching the account answers a pickup.
    dispatcher: Result(dispatch.Answer, amqp.Error),
  )
}

fn device_doc() -> doc.Value {
  doc.object([
    #("_id", doc.String(device)),
    #("pvt_type", doc.String("device")),
    #("owner_id", doc.String(supervisor)),
  ])
}

fn user_doc() -> doc.Value {
  doc.object([
    #("_id", doc.String(supervisor)),
    #("pvt_type", doc.String("user")),
  ])
}

/// The account's own caller, waiting in the queue the path names, and a
/// supervisor with a desk phone that rings.
fn world() -> World {
  World(
    queue: True,
    documents: [device_doc(), user_doc()],
    phones: [device],
    channels: Ok([channel(account, Some(queue))]),
    legs: [],
    dispatcher: Ok(dispatch.Ringing(dispatch.ring_timeout_s)),
  )
}

/// Every request put on the bus is its function name, and every pickup
/// asked of a dispatcher is `pickup_req`.
fn io(
  world: World,
  sent: Subject(String),
  asked: Subject(dispatch.Request),
) -> Io {
  let datastore = fake.new()
  case world.queue {
    True ->
      fake.put_doc(
        datastore,
        kazoo.account_db(account),
        doc.object([
          #("_id", doc.String(queue)),
          #("pvt_type", doc.String("queue")),
          #("name", doc.String("Sales")),
        ]),
      )
    False -> Nil
  }
  list.each(world.documents, fn(document) {
    fake.put_doc(datastore, kazoo.account_db(account), document)
  })
  Io(
    kz: fake.kazoo(datastore),
    channel_status: fn(call_id) {
      case call_id == call, list.key_find(world.legs, call_id) {
        True, _ -> world.channels
        False, Ok(answer) -> answer
        False, Error(Nil) -> Ok([])
      }
    },
    phones: fn(_account_id, _target, _queue) { world.phones },
    publish: fn(_module, function, _request) {
      process.send(sent, function)
      Ok(Nil)
    },
    pick_up: fn(_account_id, request) {
      process.send(sent, "pickup_req")
      process.send(asked, request)
      world.dispatcher
    },
  )
}

fn eavesdrop(who: Who, world: World) -> #(crossbar.Context, List(String)) {
  let sent = process.new_subject()
  let answer =
    supervisor_actions.validate_eavesdrop(
      io(world, sent, process.new_subject()),
      request(who),
      queue,
    )
  #(answer, drain(sent))
}

fn pickup(who: Who, world: World) -> #(crossbar.Context, List(String)) {
  pickup_naming(who, world, [#("device_id", doc.String(device))])
}

fn pickup_naming(
  who: Who,
  world: World,
  phone: List(#(String, doc.Value)),
) -> #(crossbar.Context, List(String)) {
  let sent = process.new_subject()
  let answer =
    supervisor_actions.validate_pickup(
      io(world, sent, process.new_subject()),
      request_naming(who, phone),
      queue,
    )
  #(answer, drain(sent))
}

fn drain(subject: Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> [item, ..drain(subject)]
    Error(Nil) -> []
  }
}

/// Refused because of the call: a 400 on `call_id`, and nothing sent.
fn refused_for_the_call(answer: #(crossbar.Context, List(String))) -> Bool {
  let #(context, sent) = answer
  validation_errors(context) == [#(["call_id"], "not_found")] && sent == []
}

/// An administrator of the account, or a superduper administrator, may
/// listen in and pick up; what goes out is the originate, and the question
/// to the dispatcher.
pub fn an_administrator_may_supervise_test() {
  let #(answer, sent) = eavesdrop(Admin, world())
  assert crossbar.is_success(answer)
  assert sent == ["originate_req"]

  let #(answer, sent) = pickup(Admin, world())
  assert crossbar.is_success(answer)
  assert sent == ["pickup_req"]

  let #(answer, sent) = eavesdrop(Superduper, world())
  assert crossbar.is_success(answer)
  assert sent == ["originate_req"]

  let #(answer, sent) = pickup(Superduper, world())
  assert crossbar.is_success(answer)
  assert sent == ["pickup_req"]
}

/// The `202` says what is ringing: the call, the phone asked for, the
/// devices rung and for how long.
pub fn a_pickup_answers_what_is_ringing_test() {
  let #(answer, _sent) = pickup(Admin, world())
  let body = crossbar.resp_data(answer)
  assert doc.get_string(body, ["call_id"]) == Ok(call)
  assert doc.get_string(body, ["queue_id"]) == Ok(queue)
  assert doc.get_string(body, ["device_id"]) == Ok(device)
  assert doc.strings(body, ["ringing"]) == [device]
  assert doc.get_int(body, ["ring_timeout"]) == Ok(dispatch.ring_timeout_s)
}

/// The dispatcher is asked to ring the supervisor as a person: the owner of
/// the device named, with that device and no other.
pub fn the_dispatcher_is_asked_for_the_supervisor_test() {
  let sent = process.new_subject()
  let asked = process.new_subject()
  let _ =
    supervisor_actions.validate_pickup(
      io(world(), sent, asked),
      request(Admin),
      queue,
    )
  assert drain(asked)
    == [
      dispatch.Request(
        queue_id: queue,
        call_id: call,
        supervisor_id: supervisor,
        target_type: "device",
        target_id: device,
        device_ids: [device],
      ),
    ]

  // Named by user: every phone of theirs that rings.
  let asked = process.new_subject()
  let _ =
    supervisor_actions.validate_pickup(
      io(World(..world(), phones: [device, "desk-two"]), sent, asked),
      request_naming(Admin, [#("user_id", doc.String(supervisor))]),
      queue,
    )
  assert drain(asked)
    == [
      dispatch.Request(
        queue_id: queue,
        call_id: call,
        supervisor_id: supervisor,
        target_type: "user",
        target_id: supervisor,
        device_ids: [device, "desk-two"],
      ),
    ]
}

/// Any other user of the account is a 403, whatever the call, and nothing
/// goes on the bus.
pub fn a_user_who_is_not_an_administrator_is_refused_test() {
  let #(answer, sent) = eavesdrop(User, world())
  assert system_error(answer) == Ok("forbidden")
  assert sent == []

  let #(answer, sent) = pickup(User, world())
  assert system_error(answer) == Ok("forbidden")
  assert sent == []

  // First, before the phone is looked at: a user naming nothing is still a
  // 403 and not a 400.
  let #(answer, sent) = pickup_naming(User, world(), [])
  assert system_error(answer) == Ok("forbidden")
  assert sent == []
}

/// A queue that is not in the account's database is a 404, before the
/// switches are asked anything.
pub fn a_queue_that_is_not_there_is_a_404_test() {
  let missing = World(..world(), queue: False)

  let #(answer, sent) = eavesdrop(Admin, missing)
  assert system_error(answer) == Ok("bad_identifier")
  assert sent == []

  let #(answer, sent) = pickup(Admin, missing)
  assert system_error(answer) == Ok("bad_identifier")
  assert sent == []
}

/// Only a queue document, and not a deleted one, is a queue.
pub fn is_queue_test() {
  let queue_doc = doc.object([#("pvt_type", doc.String("queue"))])
  assert supervisor_actions.is_queue(queue_doc)
  assert !supervisor_actions.is_queue(
    doc.object([#("pvt_type", doc.String("user"))]),
  )
  assert !supervisor_actions.is_queue(doc.set(
    queue_doc,
    ["pvt_deleted"],
    doc.Bool(True),
  ))
}

// --- The supervisor's phone ------------------------------------------------

/// Refused because of the phone named: a 400 on that field, and nothing
/// sent. The switches in these worlds do not answer, so a phone checked
/// after them would be a 503 instead: the phone is checked first.
fn refused_for_the_phone(
  answer: #(crossbar.Context, List(String)),
  field: String,
  code: String,
) -> Bool {
  let #(context, sent) = answer
  validation_errors(context) == [#([field], code)] && sent == []
}

fn switches_silent(world: World) -> World {
  World(..world, channels: Error(amqp.NoAnswer))
}

/// The finding's other half: a device of another account, or no device at
/// all, is not a phone of this account and is a 400 -- for a pickup and for
/// an eavesdrop -- and nothing is asked of the dispatcher.
pub fn a_phone_of_another_account_is_refused_test() {
  // The other account's device is not in this account's database.
  let theirs = World(..world(), documents: []) |> switches_silent
  assert refused_for_the_phone(pickup(Admin, theirs), "device_id", "not_found")
  assert refused_for_the_phone(
    eavesdrop(Admin, theirs),
    "device_id",
    "not_found",
  )
  assert refused_for_the_phone(
    pickup_naming(Admin, theirs, [#("user_id", doc.String(supervisor))]),
    "user_id",
    "not_found",
  )
}

/// An id that is some other kind of document of the account -- a user
/// named as a device, the queue itself -- or a deleted device is not a
/// phone either.
pub fn only_a_live_device_or_user_is_a_phone_test() {
  let world = switches_silent(world())
  assert refused_for_the_phone(
    pickup_naming(Admin, world, [#("device_id", doc.String(supervisor))]),
    "device_id",
    "not_found",
  )
  assert refused_for_the_phone(
    pickup_naming(Admin, world, [#("device_id", doc.String(queue))]),
    "device_id",
    "not_found",
  )
  let deleted =
    World(..world, documents: [
      doc.set(device_doc(), ["pvt_deleted"], doc.Bool(True)),
    ])
  assert refused_for_the_phone(pickup(Admin, deleted), "device_id", "not_found")
}

/// A phone of the account that would ring nothing -- a user with no
/// devices, a device disabled or on do not disturb -- is a 400 too, rather
/// than a request that went out and rang nobody.
pub fn a_phone_that_rings_nothing_is_refused_test() {
  let silent = World(..world(), phones: []) |> switches_silent
  assert refused_for_the_phone(pickup(Admin, silent), "device_id", "invalid")
  assert refused_for_the_phone(eavesdrop(Admin, silent), "device_id", "invalid")
  assert refused_for_the_phone(
    pickup_naming(Admin, silent, [#("user_id", doc.String(supervisor))]),
    "user_id",
    "invalid",
  )
}

/// An empty `device_id` is a 400, and nothing is looked up or sent.
pub fn an_empty_device_is_a_400_test() {
  let #(answer, sent) =
    pickup_naming(Admin, world(), [#("device_id", doc.String(""))])
  assert validation_errors(answer) == [#(["device_id"], "required")]
  assert sent == []
}

// --- The call ----------------------------------------------------------------

/// An administrator of one account naming another account's
/// call id. The switches say whose it is, and it is refused the same way as
/// a call nobody carries, so the answer says nothing about the other
/// account. Nothing is originated and the dispatcher is asked nothing.
pub fn another_accounts_call_is_refused_test() {
  let theirs =
    World(..world(), channels: Ok([channel(other_account, Some(queue))]))
  assert refused_for_the_call(eavesdrop(Admin, theirs))
  assert refused_for_the_call(pickup(Admin, theirs))
  assert refused_for_the_call(eavesdrop(Superduper, theirs))

  // One switch saying it is this account's is not enough when another says
  // it is somebody else's.
  let both =
    World(
      ..world(),
      channels: Ok([
        channel(account, Some(queue)),
        channel(other_account, Some(queue)),
      ]),
    )
  assert refused_for_the_call(eavesdrop(Admin, both))
  assert refused_for_the_call(pickup(Admin, both))

  let nowhere = World(..world(), channels: Ok([]))
  assert refused_for_the_call(eavesdrop(Admin, nowhere))
  assert refused_for_the_call(pickup(Admin, nowhere))
}

/// Switches that did not answer are not permission.
pub fn no_answer_from_the_switches_is_a_refusal_test() {
  let silent = switches_silent(world())

  let #(answer, sent) = eavesdrop(Admin, silent)
  assert system_error(answer) == Ok("datastore_unreachable")
  assert sent == []

  let #(answer, sent) = pickup(Admin, silent)
  assert system_error(answer) == Ok("datastore_unreachable")
  assert sent == []
}

/// A channel that was put in a queue names it, and it has to be this one.
/// A channel that names no queue -- an agent's own leg -- may be listened
/// to on the account's word alone.
pub fn a_call_in_another_queue_is_refused_test() {
  let elsewhere =
    World(..world(), channels: Ok([channel(account, Some(other_queue))]))
  assert refused_for_the_call(eavesdrop(Admin, elsewhere))
  assert refused_for_the_call(pickup(Admin, elsewhere))

  let unqueued = World(..world(), channels: Ok([channel(account, None)]))
  let #(answer, sent) = eavesdrop(Admin, unqueued)
  assert crossbar.is_success(answer)
  assert sent == ["originate_req"]
}

// --- What the dispatcher says --------------------------------------------------

fn answered(answer: dispatch.Answer) -> #(crossbar.Context, List(String)) {
  pickup(Admin, World(..world(), dispatcher: Ok(answer)))
}

/// The dispatcher decides whether the caller is waiting, and only it can:
/// a caller the holder says it does not hold is a 404. Nobody answering in
/// time says nothing about the caller -- a holder too slow, or no node
/// holding the shard for the moment -- and is the documented 503
/// `no_answer`, which may be asked again.
pub fn a_caller_not_waiting_is_a_404_test() {
  let #(answer, sent) = answered(dispatch.NotWaiting)
  assert error_code(answer) == Ok(404)
  assert system_error(answer) == Ok("not_waiting")
  assert sent == ["pickup_req"]

  let #(answer, _sent) =
    pickup(Admin, World(..world(), dispatcher: Error(amqp.NoAnswer)))
  assert error_code(answer) == Ok(503)
  assert system_error(answer) == Ok("no_answer")

  // The channel naming no queue does not stop a caller the dispatcher holds.
  let #(answer, sent) =
    pickup(Admin, World(..world(), channels: Ok([channel(account, None)])))
  assert crossbar.is_success(answer)
  assert sent == ["pickup_req"]
}

/// A caller somebody is already being rung for, and a supervisor already
/// ringing or talking, are conflicts: a 409, and nothing rang.
pub fn a_ring_already_going_is_a_409_test() {
  let #(answer, _sent) = answered(dispatch.BeingOffered)
  assert error_code(answer) == Ok(409)
  assert system_error(answer) == Ok("being_offered")

  let #(answer, _sent) = answered(dispatch.SupervisorBusy)
  assert error_code(answer) == Ok(409)
  assert system_error(answer) == Ok("supervisor_busy")
}

/// Nothing rang and asking again may help: the dispatcher did not answer in
/// time, or the bus could not be reached. A ring that could not be started
/// is a 500.
pub fn nothing_rang_is_not_a_success_test() {
  let #(answer, _sent) = answered(dispatch.TooLate)
  assert error_code(answer) == Ok(503)
  assert system_error(answer) == Ok("no_answer")

  let #(answer, _sent) =
    pickup(Admin, World(..world(), dispatcher: Error(amqp.Unavailable)))
  assert system_error(answer) == Ok("datastore_unreachable")

  let #(answer, _sent) = answered(dispatch.NotStarted("no_control_queue"))
  assert error_code(answer) == Ok(500)
  assert !crossbar.is_success(answer)
}

/// Phones that built to no endpoint on the caller's call -- excluded from
/// queues, or the caller's own -- are the request's to fix: a 400 on the
/// field that named them, as a supervisor with no phone at all is.
pub fn phones_the_offer_cannot_ring_are_a_400_test() {
  let #(answer, sent) = answered(dispatch.NotStarted("no_endpoints"))
  assert validation_errors(answer) == [#(["device_id"], "invalid")]
  assert sent == ["pickup_req"]

  let sent = process.new_subject()
  let answer =
    supervisor_actions.validate_pickup(
      io(
        World(..world(), dispatcher: Ok(dispatch.NotStarted("no_endpoints"))),
        sent,
        process.new_subject(),
      ),
      request_naming(Admin, [#("user_id", doc.String(supervisor))]),
      queue,
    )
  assert validation_errors(answer) == [#(["user_id"], "invalid")]
}

/// A pickup's phones are looked for as the offer will build them, on a call
/// in the queue, so that a device excluded from queues is refused before
/// anything is asked; an eavesdrop's on no queue call at all.
pub fn a_pickups_phones_are_built_for_the_queue_test() {
  let asked = process.new_subject()
  let fake =
    Io(
      ..io(world(), process.new_subject(), process.new_subject()),
      phones: fn(_account_id, _target, queue) {
        process.send(asked, queue)
        [device]
      },
    )
  let _ = supervisor_actions.validate_pickup(fake, request(Admin), queue)
  let _ = supervisor_actions.validate_eavesdrop(fake, request(Admin), queue)
  assert drain(asked) == [Some(queue), None]
}

pub fn ownership_test() {
  assert supervisor_actions.ownership([], account, queue)
    == supervisor_actions.NotOurs
  assert supervisor_actions.ownership(
      [channel(account, Some(queue))],
      account,
      queue,
    )
    == supervisor_actions.Ours
  assert supervisor_actions.ownership([channel(account, None)], account, queue)
    == supervisor_actions.Ours
  assert supervisor_actions.ownership(
      [channel(other_account, Some(queue))],
      account,
      queue,
    )
    == supervisor_actions.NotOurs
  assert supervisor_actions.ownership(
      [channel(account, Some(other_queue))],
      account,
      queue,
    )
    == supervisor_actions.OtherQueue
  // A channel with no account at all is nobody's this request can vouch for.
  assert supervisor_actions.ownership(
      [events.channel(doc.object([#("Call-ID", doc.String(call))]))],
      account,
      queue,
    )
    == supervisor_actions.NotOurs
}

// --- Partial answers from the switches --------------------------------------
//
// `live` asks every switch with `events.channel_status_everywhere`, whose
// answers are read by `events.status_everywhere`: the same reading here, over
// the answers switches give, so what is checked is the composition the node
// runs and not a list of channels made up for it.

/// One switch's answer to a channel status: carrying the call for an
/// account, or saying it has no such channel.
fn switch_answer(account_id: Option(String), status: String) -> doc.Value {
  doc.object([
    #("Call-ID", doc.String(call)),
    #("Status", doc.String(status)),
    #(
      "Custom-Channel-Vars",
      doc.object_some([
        #("Account-ID", option.map(account_id, doc.String)),
        #("Queue-ID", Some(doc.String(queue))),
      ]),
    ),
  ])
}

fn switches(answers: List(doc.Value), finished finished: Bool) -> World {
  World(
    ..world(),
    channels: events.status_everywhere(answers, finished: finished),
  )
}

/// Not every switch answered, and the ones that did carry the call for this
/// account: a switch that was silent may carry another account's channel
/// under the same id, so this is not permission, whatever was heard.
pub fn a_partial_answer_is_a_refusal_even_when_it_looks_ours_test() {
  let partial =
    switches([switch_answer(Some(account), "active")], finished: False)

  let #(answer, sent) = eavesdrop(Admin, partial)
  assert system_error(answer) == Ok("datastore_unreachable")
  assert sent == []

  let #(answer, sent) = pickup(Superduper, partial)
  assert system_error(answer) == Ok("datastore_unreachable")
  assert sent == []

  // The reading that is content with one switch carrying the call would have
  // let it through: that is the difference `status_everywhere` makes.
  assert is_ok(events.status(
    [switch_answer(Some(account), "active")],
    finished: False,
  ))
}

/// Not every switch answered, and one that did carries the call for another
/// account.
pub fn a_partial_answer_naming_another_account_is_a_refusal_test() {
  let partial =
    switches(
      [
        switch_answer(Some(other_account), "active"),
        switch_answer(None, "terminated"),
      ],
      finished: False,
    )
  let #(answer, sent) = eavesdrop(Admin, partial)
  assert system_error(answer) == Ok("datastore_unreachable")
  assert sent == []
  let #(answer, sent) = pickup(Admin, partial)
  assert system_error(answer) == Ok("datastore_unreachable")
  assert sent == []
}

/// Every switch answered: one carries the call for this account and another
/// for somebody else's. The call is not this account's to listen to or take,
/// and the refusal is the one a call nobody carries gets.
pub fn a_whole_answer_with_another_accounts_channel_is_refused_test() {
  let mixed =
    switches(
      [
        switch_answer(Some(account), "active"),
        switch_answer(Some(other_account), "active"),
        switch_answer(None, "terminated"),
      ],
      finished: True,
    )
  assert refused_for_the_call(eavesdrop(Admin, mixed))
  assert refused_for_the_call(pickup(Admin, mixed))
  assert refused_for_the_call(eavesdrop(Superduper, mixed))
  assert refused_for_the_call(pickup(Superduper, mixed))

  // A channel whose account the switch did not say is nobody's either.
  let unowned =
    switches(
      [switch_answer(Some(account), "active"), switch_answer(None, "active")],
      finished: True,
    )
  assert refused_for_the_call(eavesdrop(Admin, unowned))
  assert refused_for_the_call(pickup(Admin, unowned))

  // Every switch answered and only this account's channel is up: allowed.
  let ours =
    switches(
      [
        switch_answer(Some(account), "active"),
        switch_answer(None, "terminated"),
      ],
      finished: True,
    )
  let #(answer, sent) = eavesdrop(Admin, ours)
  assert crossbar.is_success(answer)
  assert sent == ["originate_req"]
}

/// A user who is not an administrator is refused before the switches are
/// asked anything, whatever they would have said.
pub fn a_user_is_refused_before_any_answer_is_read_test() {
  let partial =
    switches([switch_answer(Some(account), "active")], finished: False)
  let #(answer, sent) = eavesdrop(User, partial)
  assert system_error(answer) == Ok("forbidden")
  assert sent == []
  let #(answer, sent) = pickup(User, partial)
  assert system_error(answer) == Ok("forbidden")
  assert sent == []
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

// --- Which channel an eavesdrop runs against ---------------------------------

/// The agent's leg of the call: what the switches say the caller is
/// bridged to.
const agent_leg = "cc-offer-7f3a-1"

/// A channel as a switch describes it, with its other leg and whether it
/// was answered.
fn leg(
  call_id: String,
  account_id: String,
  other_leg: Option(String),
  answered: Bool,
) -> Channel {
  events.channel(
    doc.object_some([
      #("Call-ID", Some(doc.String(call_id))),
      #("Status", Some(doc.String("active"))),
      #("Other-Leg-Call-ID", option.map(other_leg, doc.String)),
      #("Answered", Some(doc.Bool(answered))),
      #(
        "Custom-Channel-Vars",
        Some(doc.object([#("Account-ID", doc.String(account_id))])),
      ),
    ]),
  )
}

/// The account's caller in the queue, talking to an agent.
fn talking() -> World {
  World(
    ..world(),
    channels: Ok([leg(call, account, Some(agent_leg), True)]),
    legs: [#(agent_leg, Ok([leg(agent_leg, account, Some(call), True)]))],
  )
}

/// An eavesdrop in `mode`, and the requests it put on the bus.
fn eavesdrop_in(
  mode: String,
  world: World,
) -> #(crossbar.Context, List(doc.Value)) {
  let requests = process.new_subject()
  let io =
    Io(
      ..io(world, process.new_subject(), process.new_subject()),
      publish: fn(_module, _function, request) {
        process.send(requests, request)
        Ok(Nil)
      },
    )
  let answer =
    supervisor_actions.validate_eavesdrop(
      io,
      request_naming(Admin, [
        #("device_id", doc.String(device)),
        #("mode", doc.String(mode)),
      ]),
      queue,
    )
  #(answer, drain(requests))
}

fn eavesdropped_on(request: doc.Value) -> #(String, String, String) {
  let assert Ok(on) = doc.get_string(request, ["Eavesdrop-Call-ID"])
  let assert Ok(existing) = doc.get_string(request, ["Existing-Call-ID"])
  let assert Ok(mode) = doc.get_string(request, ["Eavesdrop-Mode"])
  #(on, existing, mode)
}

/// In FreeSWITCH a mode mixes the supervisor into what the channel
/// eavesdropped on hears (`whisper`, digit 2), or into that and what it sends
/// its partner (`full`, digit 3). So `listen` and `full` run against the
/// caller, and `whisper` against the agent's leg: the agent hears it and the
/// caller does not.
pub fn each_mode_runs_against_the_channel_it_is_heard_on_test() {
  let assert #(answer, [request]) = eavesdrop_in("listen", talking())
  assert crossbar.is_success(answer)
  assert eavesdropped_on(request) == #(call, call, "listen")

  let assert #(answer, [request]) = eavesdrop_in("full", talking())
  assert crossbar.is_success(answer)
  assert eavesdropped_on(request) == #(call, call, "full")

  let assert #(answer, [request]) = eavesdrop_in("whisper", talking())
  assert crossbar.is_success(answer)
  assert eavesdropped_on(request) == #(agent_leg, agent_leg, "whisper")
  // What went out is the answer, so a client sees which leg was used.
  assert doc.get_string(crossbar.resp_data(answer), ["Eavesdrop-Call-ID"])
    == Ok(agent_leg)
}

/// A caller nobody is talking to has nobody to whisper to: a 400 on
/// `call_id`, and nothing rings. Listening to them is still allowed.
pub fn a_whisper_needs_an_agent_on_the_call_test() {
  let waiting = World(..world(), channels: Ok([leg(call, account, None, True)]))
  let #(answer, sent) = eavesdrop_in("whisper", waiting)
  assert validation_errors(answer) == [#(["call_id"], "not_connected")]
  assert sent == []
  let #(answer, sent) = eavesdrop_in("listen", waiting)
  assert crossbar.is_success(answer)
  assert list.map(sent, eavesdropped_on) == [#(call, call, "listen")]

  // The agent's phone still ringing: its leg is not answered.
  let ringing =
    World(..talking(), legs: [
      #(agent_leg, Ok([leg(agent_leg, account, Some(call), False)])),
    ])
  let #(answer, sent) = eavesdrop_in("whisper", ringing)
  assert validation_errors(answer) == [#(["call_id"], "not_connected")]
  assert sent == []

  // The leg the caller names is bridged to somebody else by now.
  let elsewhere =
    World(..talking(), legs: [
      #(agent_leg, Ok([leg(agent_leg, account, Some("another-call"), True)])),
    ])
  let #(answer, sent) = eavesdrop_in("whisper", elsewhere)
  assert validation_errors(answer) == [#(["call_id"], "not_connected")]
  assert sent == []

  // Or gone: no switch carries it.
  let gone = World(..talking(), legs: [#(agent_leg, Ok([]))])
  let #(answer, sent) = eavesdrop_in("whisper", gone)
  assert !crossbar.is_success(answer)
  assert sent == []
}

/// The agent's leg is held to what the caller's call is: every channel
/// under it the account's, and every switch answering.
pub fn the_agent_leg_is_checked_as_the_call_is_test() {
  let theirs =
    World(..talking(), legs: [
      #(agent_leg, Ok([leg(agent_leg, other_account, Some(call), True)])),
    ])
  let #(answer, sent) = eavesdrop_in("whisper", theirs)
  assert validation_errors(answer) == [#(["call_id"], "not_found")]
  assert sent == []

  let silent = World(..talking(), legs: [#(agent_leg, Error(amqp.NoAnswer))])
  let #(answer, sent) = eavesdrop_in("whisper", silent)
  assert system_error(answer) == Ok("datastore_unreachable")
  assert sent == []
}

pub fn agent_leg_test() {
  assert supervisor_actions.agent_leg([], call) == Error(Nil)
  assert supervisor_actions.agent_leg([leg(call, account, None, True)], call)
    == Error(Nil)
  assert supervisor_actions.agent_leg(
      [leg(call, account, Some(agent_leg), True)],
      call,
    )
    == Ok(agent_leg)
  // The same leg named on two switches is one leg; two legs is nobody.
  assert supervisor_actions.agent_leg(
      [
        leg(call, account, Some(agent_leg), True),
        leg(call, account, Some(agent_leg), True),
      ],
      call,
    )
    == Ok(agent_leg)
  assert supervisor_actions.agent_leg(
      [
        leg(call, account, Some(agent_leg), True),
        leg(call, account, Some("cc-offer-7f3a-2"), True),
      ],
      call,
    )
    == Error(Nil)
  assert supervisor_actions.agent_leg(
      [leg(call, account, Some(call), True)],
      call,
    )
    == Error(Nil)
}
