//// Call events, and what the switches say is up right now.
////
//// Two ways of knowing about a call. `subscribe` and `relay` hear an
//// account's events through `kz_events`, the node's pool of call-event
//// listeners, so an application that only wants to hear about calls does not
//// bind a queue of its own. The channel queries ask every `ecallmgr` on the
//// cluster what it is carrying, which is the answer an application takes when
//// it starts, or when it has lost track.
////
//// **What a node hears.** The pool binds every call event of the cluster,
//// federated zones included, and that is not narrowed here: it is Kazoo's.
//// What is narrowed is what reaches a handler. An `Interest` says which
//// event names -- each is a binding of its own on the node, so an event of
//// another name never reaches the handler at all -- and what an event has to
//// carry to be wanted: a call id, an other leg, a call id prefix, a channel
//// variable, an account open in a `Gate`. All of it is decided on the event
//// as `kz_json` holds it, before it is turned into anything; an event nobody
//// wants costs a few list lookups and not a document.
////
//// A subscription lasts as long as the process that made it, at most: when
//// that process goes, whether it said `off` or crashed, the handler is
//// unbound.
////
//// The accessors are the ones `kz_call_event` has, over the event as a
//// document value: the interesting ones live under `Custom-Channel-Vars`,
//// where the account, the owner and the device that authorised the call are.
////
//// A handler runs in a process `kazoo_bindings` spawned for it, so the rule
//// from `kazoo/listener` holds here too: be quick, hand the work to a named
//// actor with a typed call, and return.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import kazoo/amqp
import kazoo/doc.{type Value}

/// A running subscription, and what `off` gives back to `kz_events`.
pub type Subscription

/// Every event, whatever it is, on every account.
pub const all = "*"

/// Which events a subscriber wants.
pub type Interest {
  Interest(
    /// One account, or `all`. The bus itself narrows to it.
    account: String,
    /// The event names, or `[]` for every one. Each name is a binding of its
    /// own on the node's bus, so the rest never reach the handler.
    events: List(String),
    /// What an event has to carry, any one of them; `[]` for anything.
    carrying: List(Mark),
    /// Only the accounts open in this gate, when there is one.
    gate: Option(Gate),
  )
}

/// Something an event carries that makes it wanted.
pub type Mark {
  /// Its `Call-ID` is this.
  CallId(String)
  /// Its `Other-Leg-Call-ID` is this: another leg bridged to the call.
  OtherLeg(String)
  /// Its `Call-ID` starts with this.
  CallIdPrefix(String)
  /// It carries this custom channel variable, whatever its value.
  ChannelVar(String)
}

/// Every event of an account, or of every account with `all`.
pub fn account(account: String) -> Interest {
  Interest(account: account, events: [], carrying: [], gate: None)
}

/// A set of accounts an `Interest` can be limited to, which its owner opens
/// and shuts while subscribed: what a node whose accounts come and go
/// subscribes through, once, rather than once an account. It belongs to the
/// process that made it and goes with it.
pub type Gate

@external(erlang, "kazoo_gleam_events_ffi", "new_gate")
pub fn new_gate() -> Gate

/// Let this account's events through.
@external(erlang, "kazoo_gleam_events_ffi", "open")
pub fn open(gate: Gate, account: String) -> Nil

/// Stop letting them through.
@external(erlang, "kazoo_gleam_events_ffi", "shut")
pub fn shut(gate: Gate, account: String) -> Nil

/// How long the cluster is given to answer a channel query.
/// `kz_amqp_worker`'s own default, which is what Crossbar asks with.
const query_timeout_ms = 2000

/// A channel on a switch, as `ecallmgr` describes it.
pub type Channel {
  Channel(
    call_id: String,
    account_id: Option(String),
    owner_id: Option(String),
    authorizing_id: Option(String),
    authorizing_type: Option(String),
    other_leg: Option(String),
    answered: Bool,
    bridge_id: Option(String),
    /// The media server the channel is on.
    media_node: Option(String),
    /// How long it has been up.
    elapsed_s: Option(Int),
    /// The answer as it arrived, for the fields this does not name.
    doc: Value,
  )
}

// --- Subscribing -----------------------------------------------------------

/// Call `handler` with every `event` on `account`. Both take `all`.
///
/// Every one of them is made into a document, wanted or not: `subscribe`
/// with an `Interest` is the same with the filter in front.
pub fn on_call_events(
  account account: String,
  event event: String,
  handler handler: fn(Value) -> Nil,
) -> Result(Subscription, String) {
  do_on_call_events(account, event, fn(event) {
    handler(doc.from_dynamic(event))
  })
}

/// Call `handler` with every event `interest` wants, as a document.
///
/// The handler runs in a process of the bus's, so it does the least it can
/// and sends.
pub fn subscribe(
  interest: Interest,
  handler: fn(Value) -> Nil,
) -> Result(Subscription, String) {
  do_subscribe(interest, fn(event) { handler(doc.from_dynamic(event)) })
}

/// Put every event `interest` wants in `to`'s mailbox, in the shape
/// `kazoo/call.receive_event` reads there, exactly as it arrived: nothing is
/// converted on the way. What a process following one call's events uses.
pub fn relay(interest: Interest, to pid: Pid) -> Result(Subscription, String) {
  do_relay(interest, pid)
}

/// Whether `interest` wants an event, decided by the same code the bus runs,
/// on the event as `kz_json` would have it; the gate is read as it is now.
/// For a test that says what a subscriber is handed.
pub fn wants(interest: Interest, event: Value) -> Bool {
  do_wants(interest, from_json(doc.to_string(event)))
}

/// The closure `subscribe` binds, over events as `kz_json` has them: for
/// measuring what an event costs on the way to a handler.
@internal
pub fn handler(interest: Interest, handler: fn(Value) -> Nil) -> Handler {
  do_handler(interest, fn(event) { handler(doc.from_dynamic(event)) })
}

/// A closure bound on the bus.
@internal
pub type Handler

/// An event as the bus delivers it.
@internal
pub type Raw

/// A document as `kz_json` would decode it off the bus.
@external(erlang, "kazoo_gleam_events_ffi", "from_json")
@internal
pub fn from_json(json: String) -> Raw

/// Hand every event to a handler, as the bus would.
@external(erlang, "kazoo_gleam_events_ffi", "apply_all")
@internal
pub fn deliver(handler: Handler, events: List(Raw)) -> Nil

/// Now, in microseconds, for timing.
@external(erlang, "kazoo_gleam_events_ffi", "monotonic_us")
@internal
pub fn monotonic_us() -> Int

/// Stop calling that handler.
@external(erlang, "kazoo_gleam_events_ffi", "off")
pub fn off(subscription: Subscription) -> Nil

// --- The event -------------------------------------------------------------

/// `CHANNEL_CREATE`, `CHANNEL_ANSWER`, `CHANNEL_DESTROY`, and the rest.
pub fn event_name(event: Value) -> Option(String) {
  string_at(event, ["Event-Name"])
}

pub fn call_id(event: Value) -> Option(String) {
  string_at(event, ["Call-ID"])
}

pub fn other_leg_call_id(event: Value) -> Option(String) {
  string_at(event, ["Other-Leg-Call-ID"])
}

pub fn account_id(event: Value) -> Option(String) {
  custom_channel_var(event, "Account-ID")
}

/// The user the device belongs to, when it belongs to one.
pub fn owner_id(event: Value) -> Option(String) {
  custom_channel_var(event, "Owner-ID")
}

/// The document that authorised the call: usually the device.
pub fn authorizing_id(event: Value) -> Option(String) {
  custom_channel_var(event, "Authorizing-ID")
}

/// What that document is: `device`, `user`, `account`, `resource`.
pub fn authorizing_type(event: Value) -> Option(String) {
  custom_channel_var(event, "Authorizing-Type")
}

/// One of the channel variables an application put on the call. This is
/// where an application's own state on a channel lives.
pub fn custom_channel_var(event: Value, name: String) -> Option(String) {
  string_at(event, ["Custom-Channel-Vars", name])
}

pub fn hangup_cause(event: Value) -> Option(String) {
  string_at(event, ["Hangup-Cause"])
}

/// Gregorian seconds, as every Kazoo timestamp is.
pub fn timestamp(event: Value) -> Option(Int) {
  doc.get_int(event, ["Timestamp"]) |> option.from_result
}

// --- Asking the switches ---------------------------------------------------

/// What the switches answered to a channel query: the channels, and whether
/// every `ecallmgr` answered.
///
/// A query the timeout ended is still an answer: the channels in it are on
/// the switches. What it cannot say is that a channel missing from it is not
/// -- the `ecallmgr` carrying it may be the one that was slow -- so whoever
/// reads `channels` as the whole of what is up reads `complete` first.
pub type Channels {
  Channels(channels: List(Channel), complete: Bool)
}

/// Every channel on the cluster that belongs to an account.
///
/// Answered by every `ecallmgr`, so the result is what the switches say, not
/// what an application believes. An `ecallmgr` that is restarting or slow
/// answers nothing, its channels are not in the list, and `complete` is
/// `False`. Nothing answering at all is `Error(NoAnswer)`, and so is nobody
/// to ask: `kz_nodes` counting no `ecallmgr` finishes the collection at once
/// with nothing in it, which is not every switch saying "no channels" -- a
/// switch with none answers all the same, with an empty list.
pub fn query_account_channels(
  app app: String,
  account_id account_id: String,
) -> Result(Channels, amqp.Error) {
  let request =
    request(app, "query_account_channels_req", [
      #("Account-ID", doc.String(account_id)),
      #("Active-Only", doc.Bool(False)),
    ])
  use collection <- result.try(collect("query_account_channels_req", request))
  account_channels(collection.answers, finished: collection.finished)
}

/// The channels in the answers to a channel query, and whether they are all
/// there: what `query_account_channels` makes of what the switches said.
/// No answer, finished or not, is `Error(NoAnswer)`, as it is for `status`:
/// `Channels([], complete: True)` is only ever switches that answered.
pub fn account_channels(
  answers: List(Value),
  finished finished: Bool,
) -> Result(Channels, amqp.Error) {
  use answers <- result.try(amqp.collected(answers, finished: finished))
  Ok(Channels(channels: channels(answers), complete: finished))
}

/// Every channel authorised by one of those documents: a device, or a user's
/// devices. What the `ecallmgr`s that answered in time said; one that did
/// not is missing from it. Nobody answering, or nobody to ask, is
/// `Error(NoAnswer)`.
pub fn query_user_channels(
  app app: String,
  authorizing_ids authorizing_ids: List(String),
) -> Result(List(Channel), amqp.Error) {
  let request =
    request(app, "query_user_channels_req", [
      #("Authorizing-IDs", doc.List(list.map(authorizing_ids, doc.String))),
      #("Active-Only", doc.Bool(False)),
    ])
  use collection <- result.try(collect("query_user_channels_req", request))
  use answers <- result.try(amqp.collected(
    collection.answers,
    finished: collection.finished,
  ))
  Ok(channels(answers))
}

/// What the cluster knows about one call.
///
/// A switch carrying the call is the call's channels, whether or not every
/// switch answered in time. `Ok([])` is every switch having answered and
/// none of them carrying it, which is how a stale identifier answers.
/// Anything else -- no switch answered, or some did not and none of those
/// that did carries the call -- is `Error(NoAnswer)`, which says nothing
/// about the call; `status` keeps them apart.
pub fn channel_status(
  app app: String,
  call_id call_id: String,
) -> Result(List(Channel), amqp.Error) {
  use collection <- result.try(ask_status(app, call_id))
  status(collection.answers, finished: collection.finished)
}

/// The same question, answered only when every switch has answered it.
///
/// For a caller that must know the whole of what is under a call id and not
/// just that it is up: a switch that did not answer may carry another
/// channel under it. `Ok` is every `ecallmgr` having answered, with the
/// channels those carrying the call gave; anything short of that is
/// `Error(NoAnswer)`.
pub fn channel_status_everywhere(
  app app: String,
  call_id call_id: String,
) -> Result(List(Channel), amqp.Error) {
  use collection <- result.try(ask_status(app, call_id))
  status_everywhere(collection.answers, finished: collection.finished)
}

fn ask_status(
  app: String,
  call_id: String,
) -> Result(amqp.Collection, amqp.Error) {
  let request =
    request(app, "channel_status_req", [
      #("Call-ID", doc.String(call_id)),
      // Every `ecallmgr` answers, the ones not carrying the call with a
      // `Status` of `terminated`. Asking for active only would leave those
      // silent, and then "nobody carries it" and "nobody heard" would be
      // the same silence.
      #("Active-Only", doc.Bool(False)),
    ])
  collect("channel_status_req", request)
}

/// The channels in the answers to a channel status: what `channel_status`
/// makes of what the switches said, and whether the collection finished.
///
/// An `ecallmgr` that does not carry the call answers all the same, with a
/// `Status` of `terminated`, so every switch disowning the call is a
/// finished collection with no channel in it -- `Ok([])`, the call is on no
/// switch. One answer carrying the call is the call being up, finished or
/// not. What is left is not knowing: nobody answered -- a cluster whose
/// `kz_nodes` counts no `ecallmgr`, or one whose consumers were not back
/// when the question went out -- or the collection ran out of time with
/// only `terminated` in it, and the switch that did not answer in time may
/// be the one carrying the call. Both are `Error(NoAnswer)`. Nothing that
/// reads an empty list as "gone" may be given one that not every switch
/// produced.
pub fn status(
  answers: List(Value),
  finished finished: Bool,
) -> Result(List(Channel), amqp.Error) {
  case list.filter(answers, carrying), answers, finished {
    [_, ..] as carried, _, _ -> Ok(list.map(carried, channel))
    [], [], _ -> Error(amqp.NoAnswer)
    [], _answered, True -> Ok([])
    [], _answered, False -> Error(amqp.NoAnswer)
  }
}

/// The same answers, read by `channel_status_everywhere`: only a finished
/// collection with at least one answer in it is an answer.
pub fn status_everywhere(
  answers: List(Value),
  finished finished: Bool,
) -> Result(List(Channel), amqp.Error) {
  case answers, finished {
    [_, ..], True -> Ok(answers |> list.filter(carrying) |> list.map(channel))
    _none, _ -> Error(amqp.NoAnswer)
  }
}

/// Whether one channel status answer is a switch carrying the call. A
/// `Status` of `active` or `tmpdown` is; `terminated` is the switch saying
/// it has no such channel.
fn carrying(answer: Value) -> Bool {
  doc.get_string(answer, ["Status"]) != Ok("terminated")
}

fn request(app: String, name: String, fields: List(#(String, Value))) -> Value {
  doc.merge(amqp.default_headers(app, "channel", name), doc.object(fields))
}

fn collect(
  function: String,
  request: Value,
) -> Result(amqp.Collection, amqp.Error) {
  amqp.call_collect_all(
    module: "call",
    function: function,
    payload: request,
    until: amqp.Ecallmgr,
    timeout: query_timeout_ms,
  )
}

/// The `Channels` of every answer, flattened. An `ecallmgr` with nothing to
/// say answers with an empty list, which is why the collection can finish
/// before the timeout.
fn channels(answers: List(Value)) -> List(Channel) {
  answers
  |> list.flat_map(fn(answer) {
    doc.get_list(answer, ["Channels"]) |> result.unwrap([])
  })
  |> list.map(channel)
}

/// One channel, from either shape the switches answer in: the channel
/// queries answer in `ecallmgr_fs_channel:to_json/1`'s snake case, a channel
/// status in the header case of the bus.
pub fn channel(value: Value) -> Channel {
  Channel(
    call_id: first_string(value, [["uuid"], ["call_id"], ["Call-ID"]])
      |> option.unwrap(""),
    account_id: first_string(value, [
      ["account_id"],
      ["Account-ID"],
      ["Custom-Channel-Vars", "Account-ID"],
    ]),
    owner_id: first_string(value, [
      ["owner_id"],
      ["Owner-ID"],
      ["Custom-Channel-Vars", "Owner-ID"],
    ]),
    authorizing_id: first_string(value, [
      ["authorizing_id"],
      ["Authorizing-ID"],
      ["Custom-Channel-Vars", "Authorizing-ID"],
    ]),
    authorizing_type: first_string(value, [
      ["authorizing_type"],
      ["Authorizing-Type"],
      ["Custom-Channel-Vars", "Authorizing-Type"],
    ]),
    other_leg: first_string(value, [["other_leg"], ["Other-Leg-Call-ID"]]),
    answered: doc.get_bool(value, ["answered"])
      |> result.lazy_or(fn() { doc.get_bool(value, ["Answered"]) })
      |> result.unwrap(False),
    bridge_id: first_string(value, [["bridge_id"], ["Bridge-ID"]]),
    media_node: first_string(value, [
      ["node"],
      ["switch_nodename"],
      ["Media-Node"],
      ["Switch-Nodename"],
    ]),
    elapsed_s: doc.get_int(value, ["elapsed_s"])
      |> result.lazy_or(fn() { doc.get_int(value, ["Elapsed-Seconds"]) })
      |> option.from_result,
    doc: value,
  )
}

fn first_string(value: Value, paths: List(List(String))) -> Option(String) {
  paths
  |> list.fold_right(Error(Nil), fn(found, path) {
    case doc.get_string(value, path) {
      Ok(text) -> Ok(text)
      Error(_) -> found
    }
  })
  |> option.from_result
}

fn string_at(value: Value, path: List(String)) -> Option(String) {
  doc.get_string(value, path) |> option.from_result
}

@external(erlang, "kazoo_gleam_events_ffi", "on_call_events")
fn do_on_call_events(
  account: String,
  event: String,
  handler: fn(Dynamic) -> Nil,
) -> Result(Subscription, String)

@external(erlang, "kazoo_gleam_events_ffi", "subscribe")
fn do_subscribe(
  interest: Interest,
  handler: fn(Dynamic) -> Nil,
) -> Result(Subscription, String)

@external(erlang, "kazoo_gleam_events_ffi", "relay")
fn do_relay(interest: Interest, pid: Pid) -> Result(Subscription, String)

@external(erlang, "kazoo_gleam_events_ffi", "wanted")
fn do_wants(interest: Interest, event: Raw) -> Bool

@external(erlang, "kazoo_gleam_events_ffi", "handler")
fn do_handler(interest: Interest, handler: fn(Dynamic) -> Nil) -> Handler
