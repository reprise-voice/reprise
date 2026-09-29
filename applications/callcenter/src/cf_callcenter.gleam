//// The callflow action `callcenter`: a caller joins a queue, and the queue
//// hands them back.
////
//// This owns the caller only on the way in. It asks the cluster whether the
//// queue will take them, confirms their answer, marks their channel as a
//// queue call, and puts them on the member queue. From then on the caller is
//// their actor's (`callcenter/call/actor`), on whichever node holds the
//// account's shard: their media, their clocks, their keys, the agents rung
//// for them and the bridge to the one who answers. This action sends the
//// channel nothing more, and waits.
////
//// It waits for one thing: `member_continue` carrying this passage's
//// `Handoff-ID`, which the actor sends once every command it sent the
//// channel has run. The action answers `member_continuing`, notes the
//// passage as over on the channel (`Queue-Departed`), and the callflow goes
//// on at the branch the message names:
////
//// | Branch | Why |
//// |---|---|
//// | `queue_full` | `max_queue_size` callers are already waiting |
//// | `no_agents` | `enter_when_empty` is off and nobody could take them |
//// | `no_agents` | the answer or the member publication failed |
//// | `no_agents` | the queue does not exist, was deleted, or was deleted while they waited |
//// | `exit_key` | they pressed one of the queue's `exit_keys` |
//// | `timeout` | `max_wait_time` ran out |
//// | `no_agent_timeout` | `max_wait_time_with_no_agent` ran out |
////
//// The first three are this action's own, before the caller joins; the rest
//// are the actor's. A caller put through to an agent is never handed back:
//// the call ends on their channel, and so does the callflow.
////
//// The member names the flows the callflow would go on into on each of
//// those branches (`Branches`). If this node dies while the caller waits,
//// their actor finds nobody to hand them back to, and resumes the caller at
//// the branch on whichever callflow node takes the resume.

import callcenter/call/media
import callcenter/call/recovery
import callcenter/fields
import callcenter/member as member_message
import callcenter/shards
import callcenter/status_query
import callcenter/system
import gleam/dynamic.{type Dynamic}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/amqp
import kazoo/call.{type Call}
import kazoo/callflow
import kazoo/doc.{type Value}
import kazoo/events
import kazoo/kazoo.{type Kazoo}
import kazoo/modb

/// How long the cluster is given to say what a queue looks like. One node
/// holds the account's shard, so one answer is the whole answer.
const status_timeout_ms = 3000

/// The longest a caller is waited for back. Long enough that no real call
/// reaches it; short enough that an action whose events stopped arriving
/// ends instead of waiting for ever.
const longest_wait_ms = 14_400_000

/// How long the action sleeps between looks at whether the channel is still
/// there, when nothing is heard.
const look_again_ms = 60_000

/// Allow five seconds per answer attempt, with one retry and a fixed total
/// budget. `Insert-At: now` only bypasses Kazoo's queue; the switch must still
/// confirm execution before the caller joins.
/// The first attempt's share is `media.longest_answer_s`.
const answer_budget_ms = 10_000

/// The branches a caller can be handed back on, whose flows the member
/// names (`Branches`): the default child first.
pub const branch_keys = [
  "_", "exit_key", "timeout", "no_agents", "no_agent_timeout",
]

/// The mark a caller's channel carries once the callflow has them back from
/// the queue: the passage's `Handoff-ID`.
pub const departed_var = recovery.departed_var

//
// --- The action ------------------------------------------------------------
//

pub fn handle(data: Dynamic, call: Call) -> Nil {
  let data = callflow.data(data)
  case callflow.data_string(data, "id") {
    None -> {
      system.log_error("callcenter action has no queue id")
      callflow.continue(call)
    }
    Some(queue_id) -> arrive(system.live(), data, call, queue_id)
  }
}

fn arrive(kz: Kazoo, data: Value, call: Call, queue_id: String) -> Nil {
  let account_id = option.unwrap(call.account_id(call), "")
  case
    usable(kz.datamgr.open_cache_doc(kazoo.account_db(account_id), queue_id))
  {
    Error(why) -> {
      system.log_error(
        "queue "
        <> queue_id
        <> " of account "
        <> account_id
        <> " "
        <> why
        <> ": leaving on "
        <> branch_of(NoAgents),
      )
      callflow.continue_branch(call, branch_of(NoAgents))
    }
    Ok(queue) -> {
      let status = status(account_id, queue_id)
      case entry(queue, status) {
        Full -> {
          system.log("queue " <> queue_id <> " is full")
          callflow.continue_branch(call, branch_of(Full))
        }
        NoAgents -> {
          system.log("queue " <> queue_id <> " has nobody to take a caller")
          callflow.continue_branch(call, branch_of(NoAgents))
        }
        Enter -> join(kz, data, call, account_id, queue_id, queue)
      }
    }
  }
}

/// The queue document a caller is about to join, or why there is no queue to
/// join: it does not exist, it was deleted -- Crossbar's delete leaves the
/// document behind marked `pvt_deleted` -- or it could not be read.
///
/// Every one of those is a queue that cannot serve the caller, and they take
/// `no_agents`, which is what a callflow naming a queue is wired for. They
/// used to continue past the queue to its default child, as if they had been
/// in it, or wait in a deleted queue nobody was offered from.
pub fn usable(read: Result(Value, kazoo.Error)) -> Result(Value, String) {
  case read {
    Ok(queue) ->
      case doc.get_bool(queue, ["pvt_deleted"]) {
        Ok(True) -> Error("was deleted")
        _live -> Ok(queue)
      }
    Error(kazoo.NotFound) -> Error("does not exist")
    Error(reason) ->
      Error("could not be read: " <> kazoo.error_to_string(reason))
  }
}

fn join(
  kz: Kazoo,
  data: Value,
  call: Call,
  account_id: String,
  queue_id: String,
  queue: Value,
) -> Nil {
  let joined = modb.now()
  let call_id = option.unwrap(call.call_id(call), "")
  let count = shards.count(kz)
  // What this node's placement last heard from the broker; nothing is asked
  // here, so a node where the application does not run knows nothing and
  // lets the caller join, and the shard's holder catches a member it
  // hashed differently.
  case shards.known_agreement(count) {
    // This node hashes accounts with a count the cluster does not use: the
    // member would go to a queue whose holder does not dispatch the account,
    // and the caller would wait out every clock in silence. They leave now,
    // on the branch a member that could not be published takes.
    shards.Disagreed(reason) -> {
      system.log_error(
        "call "
        <> call_id
        <> " could not join queue "
        <> queue_id
        <> ": "
        <> reason,
      )
      callflow.continue_branch(call, unjoined_branch())
    }
    shards.Agreed | shards.Unknown ->
      run(
        data,
        call,
        queue_id,
        queue,
        shards.of_account(account_id, count),
        joined,
        live(),
      )
  }
}

/// The action's external operations. Production and the tests run the same
/// setup and waiting; a command send is never answer confirmation.
pub type Runtime {
  Runtime(
    /// Gregorian seconds.
    now: fn() -> Int,
    monotonic_ms: fn() -> Int,
    receive_event: fn(Int) -> Result(Value, call.Timeout),
    answer: fn(Call) -> Nil,
    destroyed: fn(Call) -> Bool,
    /// Put a message on a shard's member queue, and say whether it went.
    publish: fn(Int, String, Value) -> Result(Nil, Nil),
    /// Answer a `member_continue` at its `Reply-To`.
    reply: fn(String, Value) -> Nil,
    /// Set channel variables on the caller.
    mark: fn(Call, List(#(String, Value))) -> Nil,
    continue_branch: fn(Call, String) -> Nil,
    stop: fn(Call) -> Nil,
    /// End the callflow and leave the channel as it is: somebody else has
    /// the caller now.
    let_go: fn(Call) -> Nil,
    /// The flows the callflow would go on into, by branch.
    branches: fn(Call) -> Value,
    /// A new passage's own id: what the actor's `member_continue` carries,
    /// and what this action takes one by. Fresh for every passage, the same
    /// caller back in the same queue within the second included.
    handoff_id: fn() -> String,
  )
}

fn live() -> Runtime {
  Runtime(
    now: modb.now,
    monotonic_ms: monotonic_ms,
    receive_event: call.receive_event,
    answer: call.answer_now,
    destroyed: callflow.is_channel_destroyed,
    publish: publish_on_shard,
    reply: fn(reply_to, payload) {
      case
        amqp.publish_to(
          target: reply_to,
          module: system.category,
          function: "member_continuing",
          payload: payload,
        )
      {
        Ok(Nil) -> Nil
        Error(reason) ->
          system.log_error(
            "could not answer a member_continue at "
            <> reply_to
            <> ": "
            <> amqp.error_to_string(reason),
          )
      }
    },
    mark: fn(call, vars) { call.set_channel_vars(call, vars, []) },
    continue_branch: callflow.continue_branch,
    stop: callflow.stop,
    let_go: callflow.control_usurped,
    branches: fn(call) {
      doc.from_dynamic(callflow_branches(call, branch_keys))
      |> bounded
    },
    handoff_id: fn() { unique(reference.new()) },
  )
}

/// The flows a member names, when they are small enough to carry: a
/// callflow whose branches run to a page of JSON is resumed at nothing
/// rather than making every member on the shard's queue that big.
fn bounded(branches: Value) -> Value {
  case string.byte_size(doc.to_string(branches)) > branches_limit_bytes {
    False -> branches
    True -> {
      system.log_error(
        "the branches of a queue's callflow are too big to carry on its member",
      )
      doc.object([])
    }
  }
}

const branches_limit_bytes = 32_768

/// Everything the action knows about the caller it is putting in the queue.
type Joining {
  Joining(
    account_id: String,
    queue_id: String,
    call_id: String,
    shard: Int,
    call: Call,
    exit_keys: List(String),
    handoff_id: String,
    runtime: Runtime,
  )
}

/// Run an admitted caller. `joined` is captured when the caller arrived,
/// before the status question and the answer.
pub fn run(
  data: Value,
  call: Call,
  queue_id: String,
  queue: Value,
  shard: Int,
  joined: Int,
  runtime: Runtime,
) -> Nil {
  let account_id = option.unwrap(call.account_id(call), "")
  let call_id = option.unwrap(call.call_id(call), "")
  let call =
    call.set_custom_channel_vars(
      call,
      list.append(channel_vars(queue_id, queue, joined), [
        #(
          member_message.system_joined_var,
          doc.Int(system_joined(call, joined)),
        ),
      ]),
    )
  callflow.set_call(call)
  let joining =
    Joining(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      shard: shard,
      call: call,
      exit_keys: exit_keys(queue),
      handoff_id: runtime.handoff_id(),
      runtime: runtime,
    )
  let member =
    member_call(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      call: call.to_value(reachable(call)),
      node: system.node_name(),
      joined: joined,
      priority: priority(data, call),
      caller_id_name: call.caller_id_name(call),
      caller_id_number: call.caller_id_number(call),
      shards: shards.node_count(),
      handoff_id: joining.handoff_id,
      branches: runtime.branches(call),
    )
  case runtime.destroyed(call) {
    True -> runtime.stop(call)
    False -> {
      let sent = runtime.monotonic_ms()
      runtime.answer(call)
      await_answer(
        joining,
        member,
        sent + answer_budget_ms,
        sent + media.longest_answer_s * 1000,
        False,
      )
    }
  }
}

/// The queue's exit keys, which a caller can use before they have joined.
fn exit_keys(queue: Value) -> List(String) {
  case doc.get_string(queue, ["exit_keys"]) {
    Ok(keys) -> string.to_graphemes(keys)
    Error(Nil) ->
      case doc.get_string(queue, ["caller_exit_key"]) {
        Ok(key) -> string.to_graphemes(key)
        Error(Nil) -> []
      }
  }
}

/// Wait for the answer to be confirmed. Nothing is published until it is:
/// one retry can recover a lost event, but cannot extend the fixed total
/// budget. The caller hanging up ends the callflow; an exit key before the
/// answer is confirmed takes them out on `exit_key`, as it would once they
/// joined.
fn await_answer(
  joining: Joining,
  member: Value,
  deadline: Int,
  attempt: Int,
  retried: Bool,
) -> Nil {
  let runtime = joining.runtime
  case runtime.destroyed(joining.call) {
    True -> runtime.stop(joining.call)
    False -> {
      let now = runtime.monotonic_ms()
      case now >= deadline, now >= attempt, retried {
        True, _, _ -> answer_failed(joining)
        False, True, False -> {
          system.log("call " <> joining.call_id <> " retrying queue answer")
          runtime.answer(joining.call)
          await_answer(joining, member, deadline, deadline, True)
        }
        _, _, _ ->
          case runtime.receive_event(int.max(1, attempt - now)) {
            Error(call.Timeout) ->
              await_answer(joining, member, deadline, attempt, retried)
            Ok(event) ->
              case own(joining, event), events.event_name(event) {
                True, Some("CHANNEL_DESTROY") -> runtime.stop(joining.call)
                True, Some("DTMF") ->
                  case
                    list.contains(
                      joining.exit_keys,
                      doc.get_string(event, ["DTMF-Digit"]) |> result.unwrap(""),
                    )
                  {
                    True -> {
                      system.log(
                        "call "
                        <> joining.call_id
                        <> " pressed an exit key before it joined queue "
                        <> joining.queue_id,
                      )
                      runtime.continue_branch(joining.call, "exit_key")
                    }
                    False ->
                      await_answer(joining, member, deadline, attempt, retried)
                  }
                True, _ ->
                  case media.answer_error(event), media.is_answered(event) {
                    True, _ -> answer_failed(joining)
                    False, True ->
                      case runtime.monotonic_ms() >= deadline {
                        True -> answer_failed(joining)
                        False -> admit(joining, member)
                      }
                    _, _ ->
                      await_answer(joining, member, deadline, attempt, retried)
                  }
                False, _ ->
                  await_answer(joining, member, deadline, attempt, retried)
              }
          }
      }
    }
  }
}

fn own(joining: Joining, event: Value) -> Bool {
  events.call_id(event) == Some(joining.call_id)
  || events.call_id(event) == None
}

fn answer_failed(joining: Joining) -> Nil {
  system.log_error(
    "call "
    <> joining.call_id
    <> " queue "
    <> joining.queue_id
    <> ": answer_failed",
  )
  unjoined(joining)
}

fn admit(joining: Joining, member: Value) -> Nil {
  case joining.runtime.destroyed(joining.call) {
    True -> joining.runtime.stop(joining.call)
    False ->
      case joining.runtime.publish(joining.shard, "member_call", member) {
        Error(Nil) -> unjoined(joining)
        Ok(Nil) -> {
          system.log(
            "call " <> joining.call_id <> " joined queue " <> joining.queue_id,
          )
          let started = joining.runtime.monotonic_ms()
          wait(joining, started + longest_wait_ms)
        }
      }
  }
}

/// Setup failed before publication: nothing was sent the caller but the
/// answer, and there is no member anybody holds. Pending commands are
/// flushed and the callflow goes on.
fn unjoined(joining: Joining) -> Nil {
  system.log_error(
    "call "
    <> joining.call_id
    <> " could not join queue "
    <> joining.queue_id
    <> ": leaving on "
    <> unjoined_branch(),
  )
  call.flush(joining.call)
  joining.runtime.continue_branch(joining.call, unjoined_branch())
}

/// The branch a caller takes when their member message could not go out.
///
/// `no_agents`, the branch a queue with nobody to take a caller already has:
/// every queue in a callflow is wired for it, and what it leads to -- an
/// operator, a voicemail box, another queue -- is exactly what should happen
/// to somebody this queue cannot serve. A branch of its own would be a
/// branch nobody had wired, which continues the callflow at the same place
/// while saying less.
pub fn unjoined_branch() -> String {
  branch_of(NoAgents)
}

//
// --- Waiting to be handed back ------------------------------------------------
//

/// Wait for the caller to be handed back, the channel to go, or the longest
/// wait to run out. Nothing is sent the channel: it is the actor's.
fn wait(joining: Joining, until: Int) -> Nil {
  let runtime = joining.runtime
  let now = runtime.monotonic_ms()
  case now >= until, runtime.destroyed(joining.call) {
    True, _ -> {
      system.log_error(
        "call "
        <> joining.call_id
        <> " was not handed back by queue "
        <> joining.queue_id
        <> " in "
        <> int.to_string(longest_wait_ms / 1000)
        <> " s: stopping",
      )
      runtime.stop(joining.call)
    }
    False, True -> runtime.stop(joining.call)
    False, False ->
      case runtime.receive_event(int.min(until - now, look_again_ms)) {
        Error(call.Timeout) -> wait(joining, until)
        Ok(event) ->
          case handed_back(joining, event) {
            Continue(branch, reply_to) -> continued(joining, branch, reply_to)
            Gone -> runtime.stop(joining.call)
            Through -> let_go(joining)
            Nothing -> wait(joining, until)
          }
      }
  }
}

/// What one event means to a caller waiting to be handed back.
pub type Heard {
  /// The queue hands them back on `branch`, and wants its answer at
  /// `reply_to` when it said where.
  Continue(branch: String, reply_to: Option(String))
  /// The caller's channel is gone.
  Gone
  /// The caller's channel is bridged: to an agent the queue rang, or to
  /// whoever picked the caller up. Nothing is handed back after that.
  Through
  /// Anything else: an event of the channel that is the actor's to act on,
  /// or a hand-back of another passage.
  Nothing
}

/// What one event is, for the passage `handoff_id` of the call `call_id`.
pub fn heard(event: Value, call_id: String, handoff_id: String) -> Heard {
  let category = doc.get_string(event, ["Event-Category"])
  let name = events.event_name(event)
  let ours = events.call_id(event) == Some(call_id)
  case category, name {
    Ok("callcenter"), Some("member_continue") ->
      case doc.get_string(event, ["Handoff-ID"]) {
        Ok(id) if id == handoff_id && ours ->
          Continue(
            doc.get_string(event, ["Branch"]) |> result.unwrap("_"),
            doc.get_string(event, ["Reply-To"]) |> option.from_result,
          )
        _other -> Nothing
      }
    Ok("call_event"), Some("CHANNEL_DESTROY") if ours -> Gone
    Ok("call_event"), Some("CHANNEL_BRIDGE") if ours -> Through
    _, _ -> Nothing
  }
}

/// The caller is through to somebody, and the queue will not hand them
/// back: the callflow ends here, and leaves the channel alone.
///
/// Waiting on would keep the callflow's executor up for the whole
/// conversation, and an executor that stops -- its node shut down, or
/// restarted in a rollout -- hangs its channel up on the way out. For a
/// caller on hold that hangup waits behind the hold, which never ends; for a
/// caller in a conversation it runs at once, and the call is dropped. What
/// is left of the call is the actor's: the end of the conversation, and the
/// caller's own hangup after it.
fn let_go(joining: Joining) -> Nil {
  system.log(
    "call "
    <> joining.call_id
    <> " is through in queue "
    <> joining.queue_id
    <> ": the callflow lets it go",
  )
  joining.runtime.let_go(joining.call)
}

fn handed_back(joining: Joining, event: Value) -> Heard {
  heard(event, joining.call_id, joining.handoff_id)
}

/// The queue has handed the caller back: say so to the actor, mark the
/// channel, and go on.
fn continued(
  joining: Joining,
  branch: String,
  reply_to: Option(String),
) -> Nil {
  let runtime = joining.runtime
  case reply_to {
    Some(reply_to) ->
      runtime.reply(
        reply_to,
        member_continuing(
          call_id: joining.call_id,
          handoff_id: joining.handoff_id,
        ),
      )
    None -> Nil
  }
  system.log(
    "call "
    <> joining.call_id
    <> " handed back by queue "
    <> joining.queue_id
    <> " on "
    <> branch,
  )
  runtime.mark(joining.call, [#(departed_var, doc.String(joining.handoff_id))])
  runtime.continue_branch(joining.call, branch)
}

//
// --- What the queue will take ----------------------------------------------
//

/// What the cluster says one queue looks like right now.
///
/// Both numbers are optional, and a missing one means "the node that answered
/// did not say" rather than zero. Zero is a refusal -- no agents available
/// turns a caller away -- and nothing a node left out may be read as one.
pub type Status {
  Status(waiting: Option(Int), agents_available: Option(Int))
}

/// Whether a caller may join.
pub type Entry {
  Enter
  Full
  NoAgents
}

/// The branch a refusal continues on.
pub fn branch_of(entry: Entry) -> String {
  case entry {
    Enter -> "_"
    Full -> "queue_full"
    NoAgents -> "no_agents"
  }
}

/// Whether this caller joins, given what the queue says and what the cluster
/// answered.
///
/// An unanswered status is not a refusal. Nobody holding the account's shard
/// means nobody is dispatching it, which a caller cannot be turned away for:
/// they join, the member message waits on the durable queue, and the node
/// that takes the shard next finds them there.
pub fn entry(queue: Value, status: Option(Status)) -> Entry {
  case status {
    None -> Enter
    Some(status) ->
      case is_full(queue, status), has_agents(queue, status) {
        True, _ -> Full
        False, False -> NoAgents
        False, True -> Enter
      }
  }
}

fn is_full(queue: Value, status: Status) -> Bool {
  case
    doc.get_int(queue, ["max_queue_size"]) |> result.unwrap(0),
    status.waiting
  {
    limit, Some(waiting) if limit > 0 -> waiting >= limit
    _no_limit, _unknown -> False
  }
}

fn has_agents(queue: Value, status: Status) -> Bool {
  case
    doc.get_bool(queue, ["enter_when_empty"]) |> result.unwrap(True),
    status.agents_available
  {
    True, _ -> True
    False, Some(available) -> available > 0
    // Nobody said how many agents there are, which is not the same as saying
    // there are none.
    False, None -> True
  }
}

fn status(account_id: String, queue_id: String) -> Option(Status) {
  case
    amqp.call_collect(
      module: system.category,
      function: "status_req",
      payload: status_query.request(account_id, Some(queue_id)),
      until: amqp.Count(1),
      timeout: status_timeout_ms,
    )
  {
    Ok(answers) -> status_of(queue_id, answers)
    Error(_reason) -> None
  }
}

/// One queue's entry in whatever the cluster answered.
///
/// A node that is not dispatching the account has nothing to say about the
/// queue, so an answer without it is skipped rather than read as an empty
/// queue with no agents.
pub fn status_of(queue_id: String, answers: List(Value)) -> Option(Status) {
  case answers {
    [] -> None
    [answer, ..rest] ->
      case queue_status(queue_id, doc.get_list(answer, ["Queues"])) {
        Some(status) -> Some(status)
        None -> status_of(queue_id, rest)
      }
  }
}

fn queue_status(
  queue_id: String,
  queues: Result(List(Value), Nil),
) -> Option(Status) {
  case queues {
    Error(Nil) -> None
    Ok(queues) ->
      queues
      |> list.find(fn(queue) {
        doc.get_string(queue, ["Queue-ID"]) == Ok(queue_id)
      })
      |> option.from_result
      |> option.map(fn(queue) {
        // `Waiting` is the list of callers, for a screen. `Waiting-Count` is
        // how many of them there are, which is what a caller arriving needs.
        Status(
          waiting: fields.some_int(queue, ["Waiting-Count"]),
          agents_available: fields.some_int(queue, ["Agents-Available"]),
        )
      })
  }
}

//
// --- The messages ----------------------------------------------------------
//

/// A caller entering a queue, as `kapi_callcenter` validates it.
pub fn member_call(
  account_id account_id: String,
  queue_id queue_id: String,
  call_id call_id: String,
  call call: Value,
  node node: String,
  joined joined: Int,
  priority priority: Int,
  caller_id_name caller_id_name: Option(String),
  caller_id_number caller_id_number: Option(String),
  shards shards: Option(Int),
  handoff_id handoff_id: String,
  branches branches: Value,
) -> Value {
  doc.merge(
    amqp.default_headers(system.category, system.category, "member_call"),
    doc.object_some([
      #("Account-ID", Some(doc.String(account_id))),
      #("Queue-ID", Some(doc.String(queue_id))),
      #("Call-ID", Some(doc.String(call_id))),
      #("Call", Some(call)),
      #("Callflow-Node", Some(doc.String(node))),
      #("Joined-Timestamp", Some(doc.Int(joined))),
      #("Priority", Some(doc.Int(priority))),
      #("Caller-ID-Name", option.map(caller_id_name, doc.String)),
      #("Caller-ID-Number", option.map(caller_id_number, doc.String)),
      // The count the shard was worked out with, so that a shard whose own
      // count says the account is not its own can say what the sender's was.
      #("Shard-Count", option.map(shards, doc.Int)),
      #("Handoff-ID", Some(doc.String(handoff_id))),
      #("Branches", Some(branches)),
    ]),
  )
}

/// The action's answer to a `member_continue`: it has the caller back.
pub fn member_continuing(
  call_id call_id: String,
  handoff_id handoff_id: String,
) -> Value {
  doc.merge(
    amqp.default_headers(system.category, system.category, "member_continuing"),
    doc.object([
      #("Call-ID", doc.String(call_id)),
      #("Handoff-ID", doc.String(handoff_id)),
    ]),
  )
}

/// The channel variables a queue call carries, which is what the CDR is read
/// back through.
///
/// A caller joining a queue starts a passage with nobody answering it yet,
/// so the `Agent-ID` and `Queue-Answered-Timestamp` an earlier passage's
/// answer left on the channel go in the same `set`. A caller an agent
/// transferred into a second queue, who then abandoned it, otherwise ended
/// with a CDR saying the second queue was answered by the first agent; and
/// a takeover of the second queue read the first agent's `Agent-ID` as the
/// dead offer having marked the channel already. An empty value is how
/// Kazoo unsets one (`kapps_call:remove_custom_channel_vars/2` sends the
/// same): the switch's `set` with nothing after the `=` removes the
/// variable. A JSON null would be written as the text `null`.
pub fn channel_vars(
  queue_id: String,
  queue: Value,
  joined: Int,
) -> List(#(String, Value)) {
  [
    #("Queue-ID", doc.String(queue_id)),
    #(
      "Queue-Name",
      doc.String(doc.get_string(queue, ["name"]) |> result.unwrap(queue_id)),
    ),
    #("Queue-Joined-Timestamp", doc.Int(joined)),
    #("Agent-ID", doc.String("")),
    #("Queue-Answered-Timestamp", doc.String("")),
  ]
}

/// When this caller entered the system: the `Queue-System-Joined` the
/// channel already carries, or `joined` if this is the first queue the
/// channel has been in. The first queue's time is kept however many queues
/// come after it, which is what `time_base_score: system` orders by.
pub fn system_joined(call: Call, joined: Int) -> Int {
  call.custom_channel_var(call, member_message.system_joined_var)
  |> option.then(member_message.system_joined_value)
  |> option.unwrap(joined)
}

/// The caller's priority: what the action's data says, then the
/// `Call-Priority` the channel arrived with, then none at all.
pub fn priority(data: Value, call: Call) -> Int {
  case doc.get_int(data, ["priority"]) {
    Ok(priority) -> priority
    Error(Nil) ->
      case call.custom_channel_var(call, "Call-Priority") {
        Some(doc.Int(priority)) -> priority
        _ -> 0
      }
  }
}

/// Put a `member_call` on the account's member queue, and say whether it
/// went.
///
/// A failed publish is never only a log line here: the member queue is the
/// whole of what the rest of the cluster knows about this caller, so a
/// `member_call` that did not go out means nobody is looking for them. It
/// goes out through the node's confirming publisher -- one channel in
/// confirm mode for every confirmed publish on the node -- and `mandatory`:
/// a member queue that does not exist -- a shard nobody declared, under a
/// count the rest of the cluster does not use -- returns it, and the caller
/// leaves on `no_agents` rather than waiting for a dispatcher that will
/// never see them.
fn publish_on_shard(
  shard: Int,
  name: String,
  payload: Value,
) -> Result(Nil, Nil) {
  case
    amqp.publish_to_confirmed(
      target: int.to_string(shard),
      module: system.category,
      function: name,
      payload: payload,
      timeout: confirm_timeout_ms,
    )
  {
    Ok(Nil) -> Ok(Nil)
    // Sent, and the broker did not confirm it in time. It may well be on the
    // queue, and a caller turned away while their member waits there is a
    // caller rung for after they have gone; so they join, as they did before
    // anything was confirmed.
    Error(amqp.NoAnswer) -> {
      system.log_error(
        name
        <> " for call "
        <> option.unwrap(string_at(payload, "Call-ID"), "unknown")
        <> " was not confirmed by the broker within "
        <> int.to_string(confirm_timeout_ms)
        <> " ms: joining all the same",
      )
      Ok(Nil)
    }
    Error(reason) -> {
      system.log_error(
        name
        <> " for call "
        <> option.unwrap(string_at(payload, "Call-ID"), "unknown")
        <> " did not go out: "
        <> amqp.error_to_string(reason),
      )
      Error(Nil)
    }
  }
}

/// How long the broker is given to confirm a `member_call`.
const confirm_timeout_ms = 2000

//
// --- Where the caller is handed back -------------------------------------------
//

/// The address the member message gives for this caller: where the actor
/// hands them back to, and what `cf_exe` relays to this action from. See
/// `reachable_at`.
fn reachable(call: Call) -> Call {
  case
    reachable_at(call.controller_queue(call), executor(call), callflow_queue)
  {
    None -> call
    Some(queue) -> call.set_controller_queue(call, queue)
  }
}

/// Where the dispatcher can reach the callflow running this action.
///
/// A callflow that began with a route request has it already: its
/// `Controller-Queue` is `pid://<executor>/<queue>`, the queue of this node's
/// callflow listener that the route win came in on and the executor it
/// hands a message for the call to, and that is the answer.
///
/// A callflow that was resumed -- out of a conference, or by a konami
/// metaflow -- carries the controller queue of whatever held the call
/// before: an executor that has ended, a conference participant's queue.
/// Nothing sent there reaches this action, so the address is made again
/// from this executor and a queue of this node's callflow listener, which
/// hands a message addressed to a pid on this node to that pid whichever
/// message it was. With no executor to name (not a callflow) or no listener
/// to name, the call's own controller queue stands.
pub fn reachable_at(
  controller_queue: Option(String),
  executor: Option(String),
  node_queue: fn() -> Option(String),
) -> Option(String) {
  case executor {
    None -> controller_queue
    Some(executor) ->
      case option.map(controller_queue, addressed_to) {
        Some(Some(pid)) if pid == executor -> controller_queue
        _elsewhere ->
          case node_queue() {
            Some(queue) -> Some("pid://" <> executor <> "/" <> queue)
            None -> controller_queue
          }
      }
  }
}

/// The pid a `pid://<pid>/<queue>` address delivers to.
fn addressed_to(queue: String) -> Option(String) {
  case queue {
    "pid://" <> rest ->
      case string.split_once(rest, "/") {
        Ok(#(pid, _queue)) -> Some(pid)
        Error(Nil) -> None
      }
    _plain_queue -> None
  }
}

/// The callflow executor running this action, as `kapi:encode_pid/2`
/// spells a pid. Nothing outside a callflow.
@external(erlang, "callcenter_ffi", "callflow_executor")
fn executor(call: Call) -> Option(String)

/// The queue of one of this node's callflow listeners. Nothing when
/// `callflow` is not running here.
@external(erlang, "callcenter_ffi", "callflow_queue")
fn callflow_queue() -> Option(String)

@external(erlang, "callcenter_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

@external(erlang, "callcenter_ffi", "leg_prefix")
fn unique(serial: Reference) -> String

@external(erlang, "callcenter_ffi", "callflow_branches")
fn callflow_branches(call: Call, keys: List(String)) -> Dynamic

fn string_at(event: Value, key: String) -> Option(String) {
  doc.get_string(event, [key]) |> option.from_result
}
