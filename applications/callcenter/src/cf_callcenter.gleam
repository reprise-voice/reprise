//// The callflow action `callcenter`: a caller joins a queue and waits.
////
//// This owns the caller and nothing else. It asks the cluster whether the
//// queue will take them, confirms their answer, starts media, and only then
//// puts them on the member queue. It waits for their position, for an agent,
//// for a key, for the clocks to run out, or for them to hang up. Which agent
//// rings and when is the dispatcher's, on whichever node holds the account's
//// shard; the caller's media and the callflow's continuation are here, on
//// the node the route win landed on.
////
//// After publication, leaving without an agent publishes `member_cancel`
//// so the dispatcher can settle the member. Setup exits have no member to
//// cancel. The callflow continues on a branch that says why:
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
//// The dispatcher's own messages -- `member_position`, `member_offer`,
//// `member_connected`, `member_result` -- are sent to the call's
//// `Controller-Queue`, the queue the route win came in on, and `cf_exe`
//// relays them to this process as it relays the channel's own events: one
//// `receive_event` loop sees both, and nothing is bound or consumed for the
//// caller. `reachable_at` is the address the member message gives. For one
//// release, a caller whose shard holder does not say it sends there -- a
//// node of the release before -- is listened for on the exchange as well
//// (`Delivery`).
////
//// **Who owns the caller's media.** This action does, except while an offer
//// rings: the dispatcher's offer bridges the agents' phones from this same
//// channel, and its bridge interrupts -- it breaks the hold and carries the
//// hold music as its ringback. Nothing here interrupts in return. Every hold
//// is queued behind whatever the channel is doing, so a hold that arrives
//// while a bridge rings waits behind it and runs only if the ring comes to
//// nothing, and the order the two land in stops mattering. When the bridge
//// ends without an agent the caller is put back on hold; when it ends with
//// one, `member_connected` says so and there is nothing left to play.
////
//// **The caller's keys while an offer rings.** The switch's ring reads the
//// caller's keys only when their channel asks it to, and a key nothing reads
//// is published once the ring is over. The first queue with exit keys a
//// caller joins asks, and the ask stays on their channel for the rest of the
//// call. See `asks_ring_to_read_keys`.

import callcenter/announce
import callcenter/caller
import callcenter/fields
import callcenter/member as member_message
import callcenter/shards
import callcenter/status_query
import callcenter/system
import callcenter/types.{type CancelReason}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
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
import kazoo/listener
import kazoo/modb

/// How long the cluster is given to say what a queue looks like. One node
/// holds the account's shard, so one answer is the whole answer.
const status_timeout_ms = 3000

/// The longest a caller connected to an agent is watched for. The offer owns
/// the hangup; this is only here so that a flow whose events stopped
/// arriving ends instead of waiting for ever.
const longest_call_s = 14_400

/// The longest the greeting or an announcement is believed to be still
/// playing before hold is put back whatever the switch has said. A caller
/// left in silence because one execute-complete went missing is worse than
/// hold starting a little early.
const longest_play_s = 60

/// Allow five seconds per answer attempt, with one retry and a fixed total
/// budget. `Insert-At: now` only bypasses Kazoo's queue; the switch must still
/// confirm execution before dispatch can interrupt its private event queue.
const longest_answer_s = 5

const answer_budget_ms = 10_000

/// How much longer than its ring timeout an offer is believed to be still
/// ringing, after which the no-agent clock may run again whether or not the
/// end of the ring was heard. The same allowance the dispatcher gives the
/// offer itself, `offer_grace_s`.
const offer_slack_s = 5

/// How long a caller leaving while the phones ring waits for the switch to
/// say the ring is over, once it has been told to call it off. The cancel is
/// one command the switch runs as it arrives and the originate notices within
/// its next poll, so the end comes back in well under a second; this is the
/// ceiling for the event going missing, after which the caller leaves anyway.
const ring_cancel_wait_ms = 5000

/// The channel variable a ring from the caller's channel takes its cancel
/// key from. `ecallmgr` writes it as the switch's `origination_cancel_key`.
/// See `asks_ring_to_read_keys`.
const ring_cancel_key = "Attended-Transfer-Cancel-Dial-Key"

/// The channel variable saying `ring_cancel_key` has been written on this
/// channel. `ecallmgr` writes it with its own prefix and hands it back on
/// every event and route request, so a callflow run again, or one a
/// transfer started, knows as well as this one does. `ring_cancel_key`
/// itself is written under the switch's name and never comes back.
const ring_keys_marker = "Queue-Ring-Reads-Keys"

/// A cancel key no keypad sends. The switch takes nothing as a key but `0` to
/// `9`, `*`, `#`, `A` to `D` and `a` to `d`, and the `W`, `w`, `F` and `f`
/// of a dial string.
pub const no_keypad_key = "x"

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
      let #(status, delivery) = status(account_id, queue_id)
      case entry(queue, status) {
        Full -> {
          system.log("queue " <> queue_id <> " is full")
          callflow.continue_branch(call, branch_of(Full))
        }
        NoAgents -> {
          system.log("queue " <> queue_id <> " has nobody to take a caller")
          callflow.continue_branch(call, branch_of(NoAgents))
        }
        Enter ->
          join(kz, data, call, account_id, queue_id, queue, status, delivery)
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

/// Where the caller's media is.
///
/// The three states are in the order a caller meets them. Nothing is played
/// on a channel the switch has not said is up, and hold goes on only once
/// whatever was playing is over, so the states say what is owed: an answer,
/// an end of play, or nothing.
pub type Media {
  /// `answer` has gone out and the switch has not said the channel is up.
  /// Nothing is played until it has: a greeting on a channel that is still
  /// ringing is early media.
  Answering(since: Int, greeting: Option(String))
  /// The greeting or an announcement is playing. Hold goes back on once
  /// that is over.
  Playing(since: Int)
  /// Hold music, which is where a waiting caller spends their time.
  Held
}

/// What the switch is told about the caller's media after one of the
/// channel's own events, or after waiting too long for one.
pub type Cue {
  /// Play the greeting.
  PlayGreeting(media: String)
  /// Play an announcement in place of the hold. It interrupts the hold and
  /// not a bridge: sent to a channel whose agents are ringing, it waits
  /// behind the ring.
  Announce(items: List(call.MacroItem))
  /// Put the caller on hold, behind whatever the channel is doing.
  Hold
  /// Nothing is owed.
  Nothing
}

/// Everything the loop needs about one waiting caller.
type Waiting {
  Waiting(
    account_id: String,
    queue_id: String,
    call_id: String,
    shard: Int,
    call: Call,
    limits: caller.Limits,
    announcement: announce.Settings,
    exit_keys: List(String),
    moh: Option(String),
    language: String,
    state: caller.Caller,
    media: Media,
    published: Bool,
    /// Which of the dispatcher's messages about the caller in this queue
    /// are about this passage (`is_own`).
    passage: Passage,
    runtime: Runtime,
    /// How to stop the listener on the caller's exchange key, when there is
    /// one (`Runtime.listen`). While it runs, the dispatcher's messages count
    /// only as it relays them.
    listening: Option(fn() -> Nil),
  )
}

fn join(
  kz: Kazoo,
  data: Value,
  call: Call,
  account_id: String,
  queue_id: String,
  queue: Value,
  status: Option(Status),
  delivery: Delivery,
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
      join_on(
        data,
        call,
        account_id,
        queue_id,
        queue,
        status,
        delivery,
        joined,
        count,
      )
  }
}

fn join_on(
  data: Value,
  call: Call,
  account_id: String,
  queue_id: String,
  queue: Value,
  status: Option(Status),
  delivery: Delivery,
  joined: Int,
  count: Int,
) -> Nil {
  run(
    data,
    call,
    queue_id,
    queue,
    status,
    shards.of_account(account_id, count),
    joined,
    Runtime(
      now: modb.now,
      monotonic_ms: monotonic_ms,
      receive_event: call.receive_event,
      answer: call.answer_now,
      destroyed: callflow.is_channel_destroyed,
      publish: publish_on_shard,
      continue_branch: callflow.continue_branch,
      listen: case delivery {
        ToController -> no_listener
        OnExchange -> exchange_listener
      },
    ),
  )
}

/// The action's external operations. Production and regression tests run the
/// same setup and waiting loops; a command send is never answer confirmation.
pub type Runtime {
  Runtime(
    now: fn() -> Int,
    monotonic_ms: fn() -> Int,
    receive_event: fn(Int) -> Result(Value, call.Timeout),
    answer: fn(Call) -> Nil,
    destroyed: fn(Call) -> Bool,
    publish: fn(Int, String, Value) -> Result(Nil, Nil),
    continue_branch: fn(Call, String) -> Nil,
    /// Listen on the caller's exchange key, `callcenter.call.<account>.<call>`,
    /// for a dispatcher that does not send to the controller queue, and say
    /// how to stop: see `Delivery`. Nothing when the dispatcher does, or when
    /// no listener could be started.
    listen: fn(String, String) -> Option(fn() -> Nil),
  )
}

/// Run an admitted caller. `joined` is captured when the caller arrived,
/// before the status question and the answer, and every waiting budget
/// counts from it.
pub fn run(
  data: Value,
  call: Call,
  queue_id: String,
  queue: Value,
  status: Option(Status),
  shard: Int,
  joined: Int,
  runtime: Runtime,
) -> Nil {
  let account_id = option.unwrap(call.account_id(call), "")
  let call_id = option.unwrap(call.call_id(call), "")
  let announcement = announce.settings(queue)
  let passage = passage_of(call, queue_id, joined)
  let exit_keys = caller.exit_keys(queue)
  // Before the member message goes out, and so before anything rings for
  // the caller. The switch's variable goes on the channel alone, ahead of the
  // mark saying it is there, which the call record carries.
  let asks = asks_ring_to_read_keys(exit_keys, call)
  case asks {
    True ->
      call.set_channel_vars(
        call,
        [#(ring_cancel_key, doc.String(no_keypad_key))],
        [],
      )
    False -> Nil
  }
  let call =
    call.set_custom_channel_vars(
      call,
      list.flatten([
        channel_vars(queue_id, queue, joined),
        [
          #(
            member_message.system_joined_var,
            doc.Int(system_joined(call, joined)),
          ),
        ],
        case asks {
          True -> [#(ring_keys_marker, doc.String("true"))]
          False -> []
        },
      ]),
    )
    |> ran_here(queue_id, joined)
  callflow.set_call(call)
  let waiting =
    Waiting(
      account_id: account_id,
      queue_id: queue_id,
      call_id: call_id,
      shard: shard,
      call: call,
      limits: caller.limits(queue)
        |> caller.with_announce_interval(announcement.interval_s),
      announcement: announcement,
      exit_keys: exit_keys,
      moh: fields.some_string(queue, ["moh"]),
      language: option.unwrap(call.language(call), "en-us"),
      state: arriving(joined, status),
      media: Answering(
        since: runtime.now(),
        greeting: fields.some_string(queue, ["greeting"]),
      ),
      published: False,
      passage: passage,
      runtime: runtime,
      // Before the member message goes out, so that the first position of
      // a dispatcher that publishes only on the exchange is heard.
      listening: runtime.listen(account_id, call_id),
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
    )
  case setup_exit(waiting) {
    True -> Nil
    False -> {
      // Timed at the send, independently of configuration and setup.
      let sent = runtime.monotonic_ms()
      runtime.answer(call)
      await_answer(
        waiting,
        member,
        sent + answer_budget_ms,
        sent + longest_answer_s * 1000,
        False,
      )
    }
  }
}

/// Setup never dispatches, announces or assumes success. One retry can recover
/// a lost event, but cannot extend the fixed total budget.
fn await_answer(
  waiting: Waiting,
  member: Value,
  deadline: Int,
  attempt: Int,
  retried: Bool,
) -> Nil {
  case setup_exit(waiting) {
    True -> Nil
    False -> {
      let runtime = waiting.runtime
      let now = runtime.monotonic_ms()
      case now >= deadline, now >= attempt, retried {
        True, _, _ -> answer_failed(waiting)
        False, True, False -> {
          system.log("call " <> waiting.call_id <> " retrying queue answer")
          runtime.answer(waiting.call)
          await_answer(waiting, member, deadline, deadline, True)
        }
        _, _, _ -> {
          let next =
            caller.next_wake_ms(
              waiting.state,
              caller.with_announce_interval(waiting.limits, 0),
              runtime.now(),
            )
          case runtime.receive_event(int.max(1, int.min(next, attempt - now))) {
            Error(call.Timeout) ->
              await_answer(waiting, member, deadline, attempt, retried)
            Ok(event) -> {
              case
                own_event(waiting, event),
                category(event),
                events.event_name(event)
              {
                True, "call_event", Some("CHANNEL_DESTROY") -> finish(waiting)
                True, "call_event", Some("DTMF") -> {
                  case
                    list.contains(
                      waiting.exit_keys,
                      option.unwrap(string_at(event, "DTMF-Digit"), ""),
                    )
                  {
                    True -> leave(waiting, types.ExitKey, "exit_key")
                    False ->
                      await_answer(waiting, member, deadline, attempt, retried)
                  }
                }
                True, _, _ -> {
                  case answer_error(event), is_answered(event) {
                    True, _ -> answer_failed(waiting)
                    False, True -> {
                      // Recheck destruction and waiting budgets at the event
                      // boundary, before starting media or publishing anything.
                      case setup_exit(waiting) {
                        True -> Nil
                        False ->
                          case runtime.monotonic_ms() >= deadline {
                            True -> answer_failed(waiting)
                            False ->
                              admit(
                                cued(waiting, up(waiting.media, runtime.now())),
                                member,
                              )
                          }
                      }
                    }
                    _, _ ->
                      await_answer(waiting, member, deadline, attempt, retried)
                  }
                }
                _, _, _ ->
                  await_answer(waiting, member, deadline, attempt, retried)
              }
            }
          }
        }
      }
    }
  }
}

fn setup_exit(waiting: Waiting) -> Bool {
  case waiting.runtime.destroyed(waiting.call) {
    True -> {
      finish(waiting)
      True
    }
    False ->
      case
        caller.expired(waiting.state, waiting.limits, waiting.runtime.now())
      {
        Some(caller.WaitedTooLong) -> {
          leave(waiting, types.Timeout, "timeout")
          True
        }
        Some(caller.NoAgentTooLong) -> {
          leave(waiting, types.NoAgentTimeout, "no_agent_timeout")
          True
        }
        None -> False
      }
  }
}

fn answer_failed(waiting: Waiting) -> Nil {
  system.log_error(
    "call "
    <> waiting.call_id
    <> " queue "
    <> waiting.queue_id
    <> ": answer_failed",
  )
  unjoined(waiting)
}

fn admit(waiting: Waiting, member: Value) -> Nil {
  case setup_exit(waiting) {
    True -> Nil
    False ->
      case publish(waiting, "member_call", member) {
        Error(Nil) -> unjoined(waiting)
        Ok(Nil) -> {
          system.log(
            "call " <> waiting.call_id <> " joined queue " <> waiting.queue_id,
          )
          // A hangup during publication must settle the newly published member.
          wait(Waiting(..waiting, published: True))
        }
      }
  }
}

/// Setup failed before publication. Stop pending commands and any queue media
/// before taking the compatibility fallback. There is no member to cancel.
fn unjoined(waiting: Waiting) -> Nil {
  system.log_error(
    "call "
    <> waiting.call_id
    <> " could not join queue "
    <> waiting.queue_id
    <> ": leaving on "
    <> unjoined_branch(),
  )
  stop_listening(waiting)
  call.flush(waiting.call)
  waiting.runtime.continue_branch(waiting.call, unjoined_branch())
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
// --- Waiting ---------------------------------------------------------------
//

fn wait(waiting: Waiting) -> Nil {
  let now = waiting.runtime.now()
  case waiting.runtime.destroyed(waiting.call) {
    True -> end_of(waiting, types.Hangup, "the caller hung up")
    False -> wait_alive(waiting, now)
  }
}

fn wait_alive(waiting: Waiting, now: Int) -> Nil {
  case caller.expired(waiting.state, waiting.limits, now) {
    Some(caller.WaitedTooLong) -> leave(waiting, types.Timeout, "timeout")
    Some(caller.NoAgentTooLong) ->
      leave(waiting, types.NoAgentTimeout, "no_agent_timeout")
    None -> {
      let waiting = waiting |> overdue(now) |> speak(now)
      case
        waiting.runtime.receive_event(wake_ms(
          waiting.media,
          caller.next_wake_ms(waiting.state, waiting.limits, now),
          now,
        ))
      {
        Error(call.Timeout) -> wait(waiting)
        Ok(event) -> heard(waiting, event)
      }
    }
  }
}

/// How long the loop may sleep: the caller's own next deadline, or the end of
/// a media ceiling if that comes first. Without this a caller with no
/// announcements and a long `max_wait_time` has nothing to wake the loop, and
/// it would sleep straight past the moment it gives up on an event the switch
/// never sent.
pub fn wake_ms(media: Media, next: Int, now: Int) -> Int {
  let ceiling = case media {
    Answering(since, _greeting) -> Some(longest_answer_s - { now - since })
    Playing(since) -> Some(longest_play_s - { now - since })
    Held -> None
  }
  case ceiling {
    None -> next
    Some(seconds) -> int.max(int.min(next, seconds * 1000), 10)
  }
}

/// Tell the caller where they are, when the interval has come round, nothing
/// else is playing, and there is something to tell them.
///
/// The interval counts as spent whether or not anything was said: a queue
/// with nothing to announce, or one whose greeting is still playing, must
/// not leave the loop with a deadline it has already passed and cannot move.
/// A caller whose agents are ringing is the one exception, and `caller`
/// makes it: nothing falls due while the phones ring, and the announcement
/// is made when the ring comes to nothing.
fn speak(waiting: Waiting, now: Int) -> Waiting {
  case caller.announcement_due(waiting.state, waiting.limits, now) {
    False -> waiting
    True ->
      cued(
        Waiting(..waiting, state: caller.announced(waiting.state, at: now)),
        announcement_cue(
          waiting.media,
          waiting.announcement,
          waiting.state.position,
          waiting.language,
          now,
        ),
      )
  }
}

/// What an announcement falling due means for the media: on hold it is
/// played, in place of the hold, and the media is playing until its end.
/// Anywhere else -- the channel not yet up, the greeting or an earlier
/// announcement still going -- nothing is said.
///
/// The announcement interrupts. Hold never finishes on its own, so an
/// announcement queued behind it would never be heard, and callers would
/// never be told their position. It is not sent
/// while an offer is known to be ringing, and the switch side keeps it
/// behind a bridge it did not know about.
pub fn announcement_cue(
  media: Media,
  settings: announce.Settings,
  position: Option(Int),
  language: String,
  now: Int,
) -> #(Media, Cue) {
  case media {
    Held ->
      case announce.items(settings, position, language) {
        [] -> #(media, Nothing)
        items -> #(Playing(since: now), Announce(items))
      }
    _not_on_hold -> #(media, Nothing)
  }
}

/// Restore hold after a missing playback completion. Answer timeouts are
/// handled only by setup recovery and never start media.
fn overdue(waiting: Waiting, now: Int) -> Waiting {
  cued(waiting, overdue_cue(waiting.media, now))
}

pub fn overdue_cue(media: Media, now: Int) -> #(Media, Cue) {
  case media {
    Playing(since) if now - since >= longest_play_s -> #(Held, Hold)
    _ -> #(media, Nothing)
  }
}

/// What one of the channel's own events means for the media: where it
/// leaves it, and what to send.
///
/// The end of an offer's bridge is the one event that does not follow from
/// the state. The bridge interrupted whatever was running and threw away
/// whatever was queued, and now nothing is: the caller goes back on hold
/// from wherever they were. Only a channel not yet confirmed up is left
/// alone, because its answer is still owed and brings the greeting or the
/// hold with it.
pub fn on_event(media: Media, event: Value, now: Int) -> #(Media, Cue) {
  case events.event_name(event) {
    Some("CHANNEL_ANSWER") -> up(media, now)
    Some("CHANNEL_EXECUTE_COMPLETE") ->
      case is_offer_over(event), media {
        True, Answering(..) -> #(media, Nothing)
        True, _ -> #(Held, Hold)
        False, Answering(..) ->
          case is_answered(event) {
            True -> up(media, now)
            False -> #(media, Nothing)
          }
        False, Playing(..) ->
          case announce.is_finished(event) {
            True -> #(Held, Hold)
            False -> #(media, Nothing)
          }
        False, Held -> #(media, Nothing)
      }
    _other -> #(media, Nothing)
  }
}

/// The channel is up: the greeting starts, or hold does when there is none.
/// Anything but `Answering` has been through here already.
fn up(media: Media, now: Int) -> #(Media, Cue) {
  case media {
    Answering(_since, Some(greeting)) -> #(
      Playing(since: now),
      PlayGreeting(greeting),
    )
    Answering(_since, None) -> #(Held, Hold)
    _already_up -> #(media, Nothing)
  }
}

/// Send what a cue says, and remember where that leaves the media.
///
/// The hold is queued, never interrupting: an offer may be ringing from this
/// channel, and a hold queued behind its bridge waits for the ring to come
/// to nothing, which is when the caller needs it. The announcement
/// interrupts the hold, which is the only way it is ever heard, and the
/// switch side keeps even that behind a bridge.
fn cued(waiting: Waiting, moved: #(Media, Cue)) -> Waiting {
  let #(media, cue) = moved
  case cue {
    PlayGreeting(greeting) -> call.play(waiting.call, greeting)
    Announce(items) -> announce.play(waiting.call, items)
    Hold -> announce.resume_hold(waiting.call, waiting.moh)
    Nothing -> Nil
  }
  Waiting(..waiting, media: media)
}

/// Whether an event is the end of an offer's bridge on the caller's channel:
/// the switch has finished ringing the agents, and the caller is still here
/// to hear it. A bridge that was answered ends after the caller is gone and
/// is never seen by the loop that reads this.
pub fn is_offer_over(event: Value) -> Bool {
  events.event_name(event) == Some("CHANNEL_EXECUTE_COMPLETE")
  && doc.get_string(event, ["Application-Name"]) == Ok("bridge")
}

/// Whether an event is the switch saying the channel is up.
///
/// Two spellings, because a channel that was already answered when this
/// action began -- a transfer into a queue, an earlier callflow action --
/// never sends a second `CHANNEL_ANSWER`, but the switch still acknowledges
/// having run the `answer` application.
pub fn is_answered(event: Value) -> Bool {
  category(event) == "call_event"
  && !answer_error(event)
  && case events.event_name(event) {
    Some("CHANNEL_ANSWER") -> True
    Some("CHANNEL_EXECUTE_COMPLETE") ->
      doc.get_string(event, ["Application-Name"]) == Ok("answer")
      // FreeSWITCH answer has no application response (`_none_`). The
      // completion carries the channel's actual answer state, even when
      // this was an idempotent answer of an already-answered channel.
      && doc.get_string(event, ["Channel-Answer-State"]) == Ok("answered")
    _ -> False
  }
}

pub fn answer_error(event: Value) -> Bool {
  case category(event), events.event_name(event) {
    "error", _ ->
      doc.get_string(event, ["Request", "Application-Name"]) == Ok("answer")
    "call_event", Some("CHANNEL_EXECUTE_COMPLETE") ->
      doc.get_string(event, ["Application-Name"]) == Ok("answer")
      && {
        case string_at(event, "Application-Response") {
          Some("ERROR") | Some("FAIL") | Some("FAILURE") -> True
          Some(response) -> string.starts_with(response, "-ERR")
          None -> False
        }
        || string_at(event, "Application-Error-Code") != None
        || string_at(event, "Application-Error-Msg") != None
      }
    _, _ -> False
  }
}

fn own_event(waiting: Waiting, event: Value) -> Bool {
  is_own(waiting.call_id, waiting.queue_id, waiting.passage, event)
  && heard_where_listening(option.is_some(waiting.listening), event)
}

/// Whether a dispatcher's message counts, given where this action hears the
/// dispatcher. With a listener on the exchange key only what it relays does:
/// a dispatcher of this release sends to the controller queue and to the
/// exchange both, and each message read twice would be two positions, two
/// offers -- the second, late, restarting a ring that had ended. Without one,
/// the controller queue is the only way in. The channel's own events are
/// not the dispatcher's and always count.
pub fn heard_where_listening(listening: Bool, event: Value) -> Bool {
  case category(event), listening {
    "callcenter", True -> is_from_exchange(event)
    _, _ -> True
  }
}

/// Whether an event is this caller's, in this queue, on this passage.
///
/// Everything the executor relays names the call. The dispatcher's messages
/// also name the queue, and have to be of this one: they reach whatever
/// action the executor is running when they land, and a caller who timed
/// out of one queue into another in the same account can have the first
/// queue's last position or offer land in the second. Read there, a count
/// of nobody available would start the second queue's no-agent clock, and
/// an offer would stop it and leave an exit waiting on a ring that is not
/// there.
///
/// The same goes for a caller a timeout or exit branch sends straight back
/// into the same queue: the queue is the same, and only the passage tells
/// the first's last offer from the second's. See `Passage`.
pub fn is_own(
  call_id: String,
  queue_id: String,
  passage: Passage,
  event: Value,
) -> Bool {
  doc.get_string(event, ["Call-ID"]) == Ok(call_id)
  && case category(event) {
    "callcenter" ->
      doc.get_string(event, ["Queue-ID"]) == Ok(queue_id)
      && of_passage(passage, event)
    _channel -> True
  }
}

/// Which passages of the caller through this queue the dispatcher's
/// messages may be about, for the action running now.
///
/// A dispatcher of this release says which passage each of its messages is
/// about, as `Joined-Timestamp`: the join of the member it holds. That is
/// not always the join this action sent. A caller whose callflow is run
/// again in the queue they are waiting in -- their callflow node died and
/// the dispatcher had the switch rerun the dialplan (plan 4.4) -- keeps
/// their place: the dispatcher holds the older join, and every message it
/// sends says that one (`arrival.kept_place`). Comparing a message's join
/// with this action's own would leave that caller hearing nothing, and
/// comparing leniently -- any join no later than this one -- would let
/// through exactly the messages this is here to stop, which are of an
/// earlier passage and so earlier joins.
///
/// So which it is depends on where the earlier passage ran. One that ran on
/// this same executor is the caller sent back into the queue by a timeout
/// or exit branch: its last `member_offer` or `member_position`, in flight
/// as it left, would otherwise be read by the new passage -- an offer
/// marking it ringing for the ring timeout and five seconds more, deferring
/// its announcements, clearing its no-agent clock and having an exit in
/// that window call off a ring that is not there -- and only this
/// passage's own join counts (`Again`). The executor knows, because each
/// passage notes its join on the call's key-value store, which the executor
/// hands from action to action and which never reaches the channel
/// (`ran_here`). A rerun on another node starts from the call its route
/// request built, finds nothing noted and hears
/// whatever the dispatcher says about the caller in the queue, which is the
/// passage it continues (`FirstHere`); messages still addressed to the dead
/// node's executor are gone with it.
///
/// A message that does not say -- a dispatcher of an earlier release -- is
/// taken as it always was. What is given up: a caller back in the same
/// queue within the second they left it, whose two passages have the same
/// join, is told apart no better than before. One whose `member_call`
/// reaches the dispatcher before the cancel of the passage they left is a
/// new passage there too: the member names this node as the one that sent
/// the passage held, and the dispatcher keeps the new join
/// (`arrival.kept_place`).
pub type Passage {
  /// This executor has not had the caller in this queue before: anything
  /// about the caller in the queue is about this passage.
  FirstHere
  /// It has: only what is about the passage that joined at `joined` counts.
  Again(joined: Int)
}

/// Which passages the dispatcher's messages may be about, for a caller
/// joining `queue_id` at `joined` on this executor. See `Passage`.
pub fn passage_of(call: Call, queue_id: String, joined: Int) -> Passage {
  case call.kvs_fetch(call, passage_key(queue_id)) {
    Some(_earlier) -> Again(joined)
    None -> FirstHere
  }
}

/// The call as it goes on to the rest of its callflow, noting that this
/// executor has had the caller in `queue_id`: a later passage through the
/// same queue on the same executor is `Again`.
pub fn ran_here(call: Call, queue_id: String, joined: Int) -> Call {
  call.kvs_store(call, passage_key(queue_id), doc.Int(joined))
}

fn passage_key(queue_id: String) -> String {
  "callcenter-joined-" <> queue_id
}

fn of_passage(passage: Passage, event: Value) -> Bool {
  case passage, doc.get_int(event, ["Joined-Timestamp"]) {
    FirstHere, _ -> True
    Again(_joined), Error(Nil) -> True
    Again(joined), Ok(said) -> said == joined
  }
}

fn heard(waiting: Waiting, event: Value) -> Nil {
  case own_event(waiting, event) {
    False -> wait(waiting)
    True -> heard_own(waiting, event)
  }
}

fn heard_own(waiting: Waiting, event: Value) -> Nil {
  case category(event), events.event_name(event) {
    "call_event", Some("DTMF") -> pressed(waiting, event)
    "call_event", Some("CHANNEL_DESTROY") ->
      end_of(waiting, types.Hangup, "the caller hung up")
    "call_event", Some("CHANNEL_ANSWER") ->
      wait(cued(waiting, on_event(waiting.media, event, waiting.runtime.now())))
    "call_event", Some("CHANNEL_BRIDGE") -> answered_by(waiting, event)
    "call_event", Some("CHANNEL_EXECUTE_COMPLETE") -> {
      let now = waiting.runtime.now()
      let waiting = case is_offer_over(event) {
        True -> {
          system.log(
            "call "
            <> waiting.call_id
            <> " was offered and nobody answered: back on hold",
          )
          Waiting(..waiting, state: caller.offer_over(waiting.state, at: now))
        }
        False -> waiting
      }
      wait(cued(waiting, on_event(waiting.media, event, now)))
    }
    "callcenter", Some("member_position") ->
      wait(positioned(waiting, event, waiting.runtime.now()))
    "callcenter", Some("member_offer") ->
      wait(offered(waiting, event, waiting.runtime.now()))
    "callcenter", Some("member_connected") -> connected(waiting, event)
    "callcenter", Some("member_result") -> resulted(waiting, event)
    _, _ -> wait(waiting)
  }
}

fn pressed(waiting: Waiting, event: Value) -> Nil {
  case doc.get_string(event, ["DTMF-Digit"]) {
    Ok(digit) ->
      case list.contains(waiting.exit_keys, digit) {
        True -> leave(waiting, types.ExitKey, "exit_key")
        False -> wait(waiting)
      }
    Error(Nil) -> wait(waiting)
  }
}

/// Where the dispatcher says a caller is. Every field is optional: a
/// position event that leaves one out leaves what was known alone.
pub type Position {
  Position(
    position: Option(Int),
    waiting: Option(Int),
    agents_available: Option(Int),
    /// Whether the dispatcher still has out the ring it told of with
    /// `member_offer`. A dispatcher of the release before says nothing.
    offered: Option(Bool),
  )
}

/// The `member_position` event as a position.
pub fn position_of(event: Value) -> Position {
  Position(
    position: fields.some_int(event, ["Position"]),
    waiting: fields.some_int(event, ["Waiting"]),
    agents_available: fields.some_int(event, ["Agents-Available"]),
    offered: option.from_result(doc.get_bool(event, ["Offered"])),
  )
}

fn positioned(waiting: Waiting, event: Value, now: Int) -> Waiting {
  Waiting(..waiting, state: position_heard(waiting.state, event, now))
}

/// What a position event does to a waiting caller.
///
/// A position that says no offer is in flight ends the ring the caller was
/// told of, as the bridge finishing on the channel does. The dispatcher
/// says it once the offer is gone -- missed, failed, given up on, called
/// off -- and publishes the caller's position again then, so it is the
/// dispatcher's word for a ring whose end the channel never showed: a
/// bridge that was sent and never ran, whose ceiling would otherwise keep
/// the no-agent clock stopped and have an exit call off a ring that is not
/// there. While an offer is only being set up the dispatcher says one is in
/// flight, so a position overtaken by the `member_offer` after it cannot end
/// the ring that offer starts. The count it carries is taken first, so that
/// the clock restarts from it.
pub fn position_heard(
  state: caller.Caller,
  event: Value,
  now: Int,
) -> caller.Caller {
  let at = position_of(event)
  let state =
    caller.positioned(
      state,
      position: at.position,
      waiting: at.waiting,
      agents_available: at.agents_available,
      at: now,
    )
  case at.offered, caller.is_offered(state, at: now) {
    Some(False), True -> caller.offer_over(state, at: now)
    _, _ -> state
  }
}

/// The dispatcher is ringing agents for the caller. Somebody can take them,
/// so the no-agent clock stops for as long as the phones can ring; the end
/// of the ring is heard from the channel itself, as the bridge completing.
fn offered(waiting: Waiting, event: Value, now: Int) -> Waiting {
  system.log(
    "call "
    <> waiting.call_id
    <> " is being offered to "
    <> string.join(
      doc.get_list(event, ["Agent-IDs"])
        |> result.unwrap([])
        |> list.filter_map(fn(id) {
          case id {
            doc.String(id) -> Ok(id)
            _ -> Error(Nil)
          }
        }),
      ", ",
    ),
  )
  Waiting(
    ..waiting,
    state: caller.offered(waiting.state, until: offer_ceiling(event, now)),
  )
}

/// Until when an offer can still be ringing: its ring timeout and the same
/// grace the dispatcher gives it, from now. An offer that said no timeout is
/// given the grace alone.
pub fn offer_ceiling(event: Value, now: Int) -> Int {
  now
  + option.unwrap(fields.some_int(event, ["Offer-Timeout"]), 0)
  + offer_slack_s
}

/// The caller's own channel says it is bridged: somebody's phone took them.
///
/// That is the connection, heard first-hand and at once. `member_connected`
/// says the same thing later -- after the offer has named the agent and the
/// dispatcher has published it, which can be two seconds -- and a caller
/// whose exit key, `max_wait_time` or announcement fell due inside that gap
/// was taken out of a conversation or talked over. The clocks stop here, and
/// nothing else is played or cancelled.
fn answered_by(waiting: Waiting, event: Value) -> Nil {
  system.log(
    "call "
    <> waiting.call_id
    <> " bridged to leg "
    <> option.unwrap(string_at(event, "Other-Leg-Call-ID"), "unknown"),
  )
  bridged(
    Waiting(..waiting, state: caller.connect(waiting.state)),
    waiting.runtime.now() + longest_call_s,
    Seen(ended: False, word: None),
  )
}

/// An agent has the caller. The clocks stop, nothing else is played, and the
/// flow waits for the call to end: the offer owns the hangup.
fn connected(waiting: Waiting, event: Value) -> Nil {
  system.log(
    "call "
    <> waiting.call_id
    <> " connected to agent "
    <> option.unwrap(string_at(event, "Agent-ID"), "unknown"),
  )
  bridged(
    Waiting(..waiting, state: caller.connect(waiting.state)),
    waiting.runtime.now() + longest_call_s,
    Told,
  )
}

/// How the action knows the caller is through to somebody.
type Through {
  /// The dispatcher said so: `member_connected`, or the result of an
  /// answered call.
  Told
  /// Only the caller's own `CHANNEL_BRIDGE` did, and the dispatcher has not
  /// said so yet. `ended`: that bridge has ended on the caller's channel
  /// since. `word`: the dispatcher has since said the caller is not
  /// connected -- a position with no offer out, or `queue_deleted`.
  Seen(ended: Bool, word: Option(Value))
}

fn bridged(waiting: Waiting, deadline: Int, through: Through) -> Nil {
  case
    deadline <= waiting.runtime.now() || waiting.runtime.destroyed(waiting.call)
  {
    True -> finish(waiting)
    False ->
      case waiting.runtime.receive_event(caller.longest_wait_ms) {
        Error(call.Timeout) -> bridged(waiting, deadline, through)
        Ok(event) ->
          case category(event), events.event_name(event) {
            "call_event", Some("CHANNEL_DESTROY") -> finish(waiting)
            _, _ ->
              case seen_through(through, own_event(waiting, event), event) {
                Seen(ended: True, word: Some(word)) ->
                  not_through(waiting, word)
                through -> bridged(waiting, deadline, through)
              }
          }
      }
  }
}

/// What one event says about a connection only the caller's own bridge
/// showed.
///
/// That bridge can be an answer the call-off of its ring crossed: an agent
/// picked up a moment before the unbridge -- of the agent's release, of the
/// queue's deletion -- parked the caller, and the park cut it. The offer
/// takes no such answer and the dispatcher, which called the ring off, never
/// connects the caller (`offer.overtaken`): they are still waiting in the
/// queue, or leaving the deleted one. Both have to be true before this is
/// read as that -- the bridge over, and the dispatcher saying the caller is
/// not connected -- so that neither a position that was already on its way
/// when the agent answered nor the end of a real call takes a caller out of
/// a conversation.
fn seen_through(through: Through, own: Bool, event: Value) -> Through {
  case through, own {
    Told, _ | _, False -> through
    Seen(ended, word), True ->
      case category(event), events.event_name(event) {
        "callcenter", Some("member_connected") -> Told
        "callcenter", Some("member_position") ->
          case position_of(event).offered {
            Some(False) -> Seen(ended, Some(event))
            _ -> through
          }
        "callcenter", Some("member_result") ->
          case result_ending(string_at(event, "Result")) {
            Deleted -> Seen(ended, Some(event))
            _ -> through
          }
        "call_event", Some("CHANNEL_UNBRIDGE") -> Seen(True, word)
        "call_event", Some("CHANNEL_EXECUTE_COMPLETE") ->
          case is_offer_over(event) {
            True -> Seen(True, word)
            False -> through
          }
        _, _ -> through
      }
  }
}

/// The caller's bridge ended and the queue never connected them: back to
/// waiting, on hold -- the park the bridge ended in stopped the music -- with
/// the clocks running again, or out of a deleted queue on `no_agents`.
fn not_through(waiting: Waiting, word: Value) -> Nil {
  let now = waiting.runtime.now()
  system.log(
    "call "
    <> waiting.call_id
    <> " was bridged in queue "
    <> waiting.queue_id
    <> " as its ring was called off, and the queue did not connect it",
  )
  let state =
    caller.Caller(..waiting.state, connected: False)
    |> caller.offer_over(at: now)
  case events.event_name(word) {
    Some("member_result") -> resulted(Waiting(..waiting, state: state), word)
    _ -> {
      let state = position_heard(state, word, now)
      wait(cued(Waiting(..waiting, state: state), #(Held, Hold)))
    }
  }
}

/// The dispatcher says how the call ended. After a connection there is
/// nothing left to do. Before one, what to do depends on the result
/// (`result_ending`); nothing is cancelled, since the dispatcher has settled
/// the caller already.
fn resulted(waiting: Waiting, event: Value) -> Nil {
  let result = string_at(event, "Result")
  case waiting.state.connected, result_ending(result) {
    True, _ -> finish(waiting)
    False, Deleted -> {
      system.log(
        "call "
        <> waiting.call_id
        <> " taken out of queue "
        <> waiting.queue_id
        <> ": the queue was deleted",
      )
      depart(waiting, branch_of(NoAgents))
    }
    False, Answered -> {
      system.log(
        "call "
        <> waiting.call_id
        <> " in queue "
        <> waiting.queue_id
        <> " was answered without its connection being heard: "
        <> option.unwrap(result, "unknown"),
      )
      bridged(
        Waiting(..waiting, state: caller.connect(waiting.state)),
        waiting.runtime.now() + longest_call_s,
        Told,
      )
    }
    False, GivenUp -> {
      system.log(
        "call "
        <> waiting.call_id
        <> " left queue "
        <> waiting.queue_id
        <> ": "
        <> option.unwrap(result, "unknown"),
      )
      depart(waiting, branch_of(Enter))
    }
  }
}

/// What a `member_result` heard before any connection means for the caller.
pub type ResultEnding {
  /// `queue_deleted`: the dispatcher took the caller out of a queue that is
  /// no longer there. They leave on `no_agents`, as a caller arriving at a
  /// deleted queue does, a ring still going for them called off first.
  Deleted
  /// Every other result the dispatcher sends -- `completed`,
  /// `agent_hangup`, `caller_hangup`, `failed`, `transferred` -- is the end
  /// of an offer that was answered: the action missed the caller's
  /// `CHANNEL_BRIDGE` and the `member_connected`, or the result overtook
  /// them. The caller is, or was, with an agent, and is treated as after a
  /// connection that was heard: nothing is flushed or unbridged -- either
  /// would break into a live bridge -- no callflow action runs on a caller
  /// still talking or already transferred, and the flow waits for the
  /// channel to go, the offer owning the hangup.
  Answered
  /// A result this action does not know, from a dispatcher of another
  /// release: the queue giving the caller up. They leave as a caller who
  /// gives up leaves -- a ring still going called off, the hold flushed --
  /// and the callflow carries on at its default child.
  GivenUp
}

pub fn result_ending(result: Option(String)) -> ResultEnding {
  case result {
    Some("queue_deleted") -> Deleted
    Some("completed")
    | Some("agent_hangup")
    | Some("caller_hangup")
    | Some("failed")
    | Some("transferred") -> Answered
    _unknown -> GivenUp
  }
}

//
// --- Leaving ---------------------------------------------------------------
//

/// The caller is going without an agent: tell the dispatcher why, call off
/// a ring that is going on for them, stop the hold music, and take the branch
/// that says so.
///
/// The ring is the offer's bridge, running on this caller's own channel, and
/// a `flush` does not end it: it breaks what the channel is playing, and the
/// switch's originate does not look at that. The agents' phones rang on, the
/// next callflow action -- a voicemail box, another queue -- ran nested inside
/// the ring, and an agent who answered was put through into it while the
/// dispatcher, which had dropped the offer on the cancel, counted them free.
/// So while an offer is known to be ringing the ring is called off first,
/// with `kazoo/call.unbridge`, and the caller moves on only once the switch
/// says the ring is over.
fn leave(waiting: Waiting, reason: CancelReason, branch: String) -> Nil {
  system.log(
    "call "
    <> waiting.call_id
    <> " leaving queue "
    <> waiting.queue_id
    <> ": "
    <> reason_name(reason),
  )
  // The cancel goes first: it is what drops the offer and frees the agents
  // in the dispatcher, and the offer's own end, when it comes, is then an
  // answer about somebody who has gone.
  cancel(waiting, reason)
  depart(waiting, branch)
}

/// Out of the queue and on to `branch`: a ring still going for the caller
/// called off and waited for, the hold stopped, and the callflow continued.
fn depart(waiting: Waiting, branch: String) -> Nil {
  let waiting = stop_listening(waiting)
  let now = waiting.runtime.now()
  let over = case caller.is_offered(waiting.state, at: now) {
    False -> RingOver
    True -> {
      call.unbridge(waiting.call)
      let started = waiting.runtime.monotonic_ms()
      ring_called_off(waiting, started + ring_cancel_wait_ms)
    }
  }
  case over {
    HungUp -> finish(waiting)
    RingOver | RingUnheard -> {
      // Hold runs until something interrupts it and nothing queued behind it
      // is ever reached, so without this the next callflow action is never
      // heard.
      call.flush(waiting.call)
      waiting.runtime.continue_branch(waiting.call, branch)
    }
  }
}

/// What became of a ring the caller's leaving called off.
pub type RingEnd {
  /// The switch said the bridge is over: the caller can move on.
  RingOver
  /// The caller hung up while the ring was being called off.
  HungUp
  /// Nothing was heard within the ceiling. The caller moves on all the same,
  /// as they did before the ring was called off at all.
  RingUnheard
}

/// Wait for the end of a ring that has been called off: the caller's own
/// `CHANNEL_EXECUTE_COMPLETE` for the bridge, which comes back with
/// `ORIGINATOR_CANCEL`. Everything else on the channel is let go by.
fn ring_called_off(waiting: Waiting, deadline: Int) -> RingEnd {
  let now = waiting.runtime.monotonic_ms()
  case now >= deadline {
    True -> {
      system.log_error(
        "call "
        <> waiting.call_id
        <> ": the ring called off for it did not end within "
        <> int.to_string(ring_cancel_wait_ms)
        <> " ms: leaving the queue anyway",
      )
      RingUnheard
    }
    False ->
      case waiting.runtime.receive_event(int.max(1, deadline - now)) {
        Error(call.Timeout) -> ring_called_off(waiting, deadline)
        Ok(event) ->
          case ring_end(waiting, event) {
            Some(end) -> end
            None -> ring_called_off(waiting, deadline)
          }
      }
  }
}

/// Whether one event ends the wait for a ring that was called off.
fn ring_end(waiting: Waiting, event: Value) -> Option(RingEnd) {
  case own_event(waiting, event), category(event), events.event_name(event) {
    True, "call_event", Some("CHANNEL_DESTROY") -> Some(HungUp)
    True, "call_event", Some("CHANNEL_EXECUTE_COMPLETE") ->
      case is_offer_over(event) {
        True -> Some(RingOver)
        False -> None
      }
    _, _, _ -> None
  }
}

/// The channel is gone. The cancel still goes out -- it is what settles the
/// member the dispatcher is holding -- and then the flow ends.
fn end_of(waiting: Waiting, reason: CancelReason, why: String) -> Nil {
  system.log("call " <> waiting.call_id <> ": " <> why)
  cancel(waiting, reason)
  finish(waiting)
}

fn finish(waiting: Waiting) -> Nil {
  stop_listening(waiting)
  callflow.stop(waiting.call)
}

fn cancel(waiting: Waiting, reason: CancelReason) -> Nil {
  case waiting.published {
    False -> Nil
    True -> cancel_published(waiting, reason)
  }
}

fn cancel_published(waiting: Waiting, reason: CancelReason) -> Nil {
  // Logged and no more: the caller is going either way, and the sweep behind
  // the dispatcher takes a member whose channel is on no switch.
  let _ =
    publish(
      waiting,
      "member_cancel",
      member_cancel(
        account_id: waiting.account_id,
        queue_id: waiting.queue_id,
        call_id: waiting.call_id,
        reason: reason,
        joined: waiting.state.joined,
        cancelled_at: waiting.runtime.now(),
      ),
    )
  Nil
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

fn status(account_id: String, queue_id: String) -> #(Option(Status), Delivery) {
  case
    amqp.call_collect(
      module: system.category,
      function: "status_req",
      payload: status_query.request(account_id, Some(queue_id)),
      until: amqp.Count(1),
      timeout: status_timeout_ms,
    )
  {
    Ok(answers) -> #(status_of(queue_id, answers), delivery_of(answers))
    Error(_reason) -> #(None, OnExchange)
  }
}

/// How the dispatcher holding the account's shard reaches a waiting caller.
///
/// A dispatcher of this release sends its four messages to the caller's
/// controller queue, and on the exchange as well. One of the release before
/// sends them only on the exchange, under `callcenter.call.<account>.<call>`,
/// where this action no longer binds anything: during a rolling upgrade a
/// caller on an upgraded callflow node, dispatched by a node not yet
/// upgraded, heard no position, no offer, no connection and no result. So
/// the status answer says which it is (`Caller-Delivery`, `controller`), and
/// an answer that does not say -- the release before -- or no answer at
/// all, which leaves unknown who will dispatch the caller, has the action
/// listen on the exchange key as it used to.
///
/// For one release: once every node runs the release that says
/// `Caller-Delivery`, `OnExchange` and the listener behind it go, and a
/// caller with no status answer relies on the controller queue alone.
pub type Delivery {
  /// The holder sends to the controller queue.
  ToController
  /// The holder did not say it does, or nobody answered: listen on the
  /// exchange key too.
  OnExchange
}

/// What the status answers say about delivery: `ToController` when one of
/// them says `Caller-Delivery: controller`.
pub fn delivery_of(answers: List(Value)) -> Delivery {
  case
    list.any(answers, fn(answer) {
      doc.get_string(answer, ["Caller-Delivery"]) == Ok(controller_delivery)
    })
  {
    True -> ToController
    False -> OnExchange
  }
}

/// The `Caller-Delivery` a status answer of this release carries.
pub const controller_delivery = "controller"

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
    ]),
  )
}

/// A caller who joined at `joined` leaving one without an agent, at
/// `cancelled_at`, Gregorian seconds: what lets the shard tell the passage
/// it cancels -- the `member_call` with that `Joined-Timestamp` -- from the
/// caller's next one when the cancel reaches it first.
pub fn member_cancel(
  account_id account_id: String,
  queue_id queue_id: String,
  call_id call_id: String,
  reason reason: CancelReason,
  joined joined: Int,
  cancelled_at cancelled_at: Int,
) -> Value {
  doc.merge(
    amqp.default_headers(system.category, system.category, "member_cancel"),
    doc.object([
      #("Account-ID", doc.String(account_id)),
      #("Queue-ID", doc.String(queue_id)),
      #("Call-ID", doc.String(call_id)),
      #("Reason", doc.String(reason_name(reason))),
      #("Joined-Timestamp", doc.Int(joined)),
      #("Cancelled-Timestamp", doc.Int(cancelled_at)),
    ]),
  )
}

/// The `Reason` a cancel carries, as `kapi_callcenter` spells it.
pub fn reason_name(reason: CancelReason) -> String {
  case reason {
    types.Hangup -> "hangup"
    types.Timeout -> "timeout"
    types.NoAgentTimeout -> "no_agent_timeout"
    types.ExitKey -> "exit_key"
    types.QueueFull -> "queue_full"
    types.Transfer -> "transfer"
    types.QueueDeleted -> "queue_deleted"
  }
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

/// Whether a caller joining a queue with `exit_keys` has a ring from their
/// channel asked to read their keys: not when the queue has no exit keys,
/// and not when `call` says their channel already asks.
///
/// An offer rings the agents from the caller's own channel, and while the
/// switch's originate runs nothing takes the caller's keys off it. A key is
/// published when something takes it, so an exit key pressed while an agent
/// rang waited on the channel until the ring was over. The caller left when
/// the ring timed out, and the dispatcher charged the agent a miss. Had the
/// agent answered, the bridge would have taken the waiting keys and played
/// them to the agent.
///
/// The originate takes the caller's keys only when `origination_cancel_key`
/// is set on their channel. It then takes each key as it comes, which
/// publishes it, and cancels the ring if the key is that one. A queue with
/// exit keys sets it to a key no keypad sends. Every key then reaches this
/// action while the phones ring and none cancels the ring in the switch. An
/// exit key calls the ring off as every way out does (`depart`):
/// `member_cancel` first, then the unbridge, which ends the ring as
/// `ORIGINATOR_CANCEL`. Nobody is charged a miss for that.
///
/// The exit key itself as the cancel key would end the ring one round trip
/// sooner, but as `NO_ANSWER`, or `LOSE_RACE` with several phones, which the
/// offer reads as the agents not answering. The switch also has only one
/// cancel key, and a queue can have several exit keys.
///
/// It is written once on a channel, and never changed or removed. The
/// originate looks it up when the ring starts and keeps a pointer to the
/// channel's copy of the value, and it runs the commands queued for the
/// channel while it rings. Writing the variable again while a ring runs
/// frees the value that ring compares every key with. This action cannot
/// always know that nothing rings: a caller can leave before `member_offer`
/// reaches them, or once the wait for a ring's end has run out, and a
/// callflow run again while the phones rang (plan 4.4) joins with the old
/// ring still going. So the first join of a queue with exit keys writes it,
/// with `ring_keys_marker` after it, and a join that finds the marker writes
/// nothing. The first write is safe whatever is ringing: a ring that started
/// before it found no variable and keeps no pointer. Only the marker goes on
/// the call record, so nothing that copies a record's variables onto a
/// channel can write the switch's variable again.
///
/// The price is that the variable outlives the queue. Every later ring from
/// the caller's own channel reads their keys: the exit branch's, another
/// queue's, an agent's transfer of them. There the switch publishes the keys
/// pressed while it rings instead of playing them to whoever answers.
/// Confining it to the queue's own rings would take a scope on the offer's
/// bridge, which `ecallmgr` does not offer.
pub fn asks_ring_to_read_keys(exit_keys: List(String), call: Call) -> Bool {
  case exit_keys, reads_keys(call) {
    [], _ | _, True -> False
    _keys, False -> True
  }
}

/// Whether the caller's channel already has a ring read their keys, as far
/// as `call` knows: `ring_keys_marker`, which comes back from the switch as
/// text.
fn reads_keys(call: Call) -> Bool {
  case call.custom_channel_var(call, ring_keys_marker) {
    Some(doc.String("true")) | Some(doc.Bool(True)) -> True
    _ -> False
  }
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

/// Put one message on the account's member queue, and say whether it went.
///
/// A failed publish is never only a log line here: the member queue is the
/// whole of what the rest of the cluster knows about this caller, so a
/// `member_call` that did not go out means nobody is looking for them.
/// A `member_call` goes out through the node's confirming publisher -- one
/// channel in confirm mode for every confirmed publish on the node -- and
/// `mandatory`: a member queue that does not exist -- a shard nobody
/// declared, under a count the rest of the cluster does not use -- returns
/// it, and the caller leaves on `no_agents` rather than waiting for a
/// dispatcher that will never see them. The cancel goes out as it always did:
/// nothing about the caller changes if it is lost, and the sweep settles a
/// member whose caller has gone.
fn published(
  shard: Int,
  name: String,
  payload: Value,
) -> Result(Nil, amqp.Error) {
  case name {
    "member_call" ->
      amqp.publish_to_confirmed(
        target: int.to_string(shard),
        module: system.category,
        function: name,
        payload: payload,
        timeout: confirm_timeout_ms,
      )
    _other ->
      amqp.publish_to(
        target: int.to_string(shard),
        module: system.category,
        function: name,
        payload: payload,
      )
  }
}

/// How long the broker is given to confirm a `member_call`.
const confirm_timeout_ms = 2000

fn publish(waiting: Waiting, name: String, payload: Value) -> Result(Nil, Nil) {
  waiting.runtime.publish(waiting.shard, name, payload)
}

fn publish_on_shard(
  shard: Int,
  name: String,
  payload: Value,
) -> Result(Nil, Nil) {
  case published(shard, name, payload) {
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

//
// --- The dispatcher's messages ---------------------------------------------
//

/// The address the member message gives for this caller: where the
/// dispatcher sends its four messages, and what `cf_exe` relays to this
/// action from. See `reachable_at`.
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

// --- A dispatcher of the release before ------------------------------------

/// No listener: the dispatcher holding the shard sends to the controller
/// queue (`Delivery`).
pub fn no_listener(
  _account_id: String,
  _call_id: String,
) -> Option(fn() -> Nil) {
  None
}

/// What the exchange listener marks the messages it relays with, so that
/// the loop can tell them from the controller queue's copies.
const exchange_marker = "Callcenter-Heard-On-Exchange"

/// A dispatcher's message as the exchange listener relays it.
pub fn from_exchange(event: Value) -> Value {
  doc.set(event, [exchange_marker], doc.Bool(True))
}

/// Whether a message came through the exchange listener.
pub fn is_from_exchange(event: Value) -> Bool {
  doc.get_bool(event, [exchange_marker]) == Ok(True)
}

/// Listen for what the dispatcher says about this one caller on the
/// exchange, `callcenter.call.<account>.<call>`, and relay it into this
/// process, where the channel's own events already arrive: how every caller
/// heard the dispatcher before the controller queue, kept for a holder that
/// does not say it sends there (`Delivery`).
///
/// The member message goes out only once the listener consumes, or two
/// seconds have gone by, because a dispatcher answers a `member_call` with
/// a `member_position` within milliseconds and that first position is what
/// starts the no-agent clock. A listener that does not consume by then is
/// stopped and the caller joins all the same, hearing the controller queue
/// alone: a holder of this release still reaches them, where the release
/// before turned them away on `no_agents`.
fn exchange_listener(
  account_id: String,
  call_id: String,
) -> Option(fn() -> Nil) {
  let me = process.self()
  let started =
    listener.new()
    |> listener.binding(system.category, [
      listener.restrict_to(["call"]),
      listener.prop("account_id", listener.Text(account_id)),
      listener.prop("call_id", listener.Text(call_id)),
    ])
    |> listener.on_event(fn(event, _delivery) {
      call.relay_event(to: me, event: from_exchange(event))
    })
    // `gen_listener' traps exits, so a flow that crashed would otherwise
    // leave this consuming a queue nobody is reading.
    |> listener.on_info(fn(info) {
      case info {
        listener.Other(term) ->
          case exit_from(term, me) {
            True -> stop_normally()
            False -> Nil
          }
        _other -> Nil
      }
    })
    |> listener.start
  case started {
    Error(reason) -> {
      system.log_error(
        "call "
        <> call_id
        <> " cannot listen for a dispatcher of the release before: "
        <> reason,
      )
      None
    }
    Ok(server) ->
      case consuming_within(server, listener_ready_ms) {
        True -> {
          system.log(
            "call "
            <> call_id
            <> ": the shard's holder did not say it sends to the controller "
            <> "queue; listening on the exchange as well",
          )
          Some(fn() { listener.stop(server) })
        }
        False -> {
          system.log_error(
            "call "
            <> call_id
            <> " listener did not become ready: hearing the controller queue "
            <> "alone",
          )
          listener.stop(server)
          None
        }
      }
  }
}

/// How long the exchange listener is given to be on its queue.
const listener_ready_ms = 2000

const listener_poll_ms = 10

/// `gen_listener` answers `is_consuming` from state it sets after the
/// delayed bindings are created, so a listener that says yes is bound.
/// Timed by the clock and not by the sleeps: each ask is a call to a
/// process that may be busy with its broker.
fn consuming_within(server: listener.Server, budget_ms: Int) -> Bool {
  wait_for_consuming(server, monotonic_ms() + budget_ms)
}

fn wait_for_consuming(server: listener.Server, deadline: Int) -> Bool {
  case listener.consuming(server) {
    True -> True
    False ->
      case monotonic_ms() >= deadline {
        True -> False
        False -> {
          process.sleep(listener_poll_ms)
          wait_for_consuming(server, deadline)
        }
      }
  }
}

/// Whether a term the listener was sent is an exit signal from the flow.
@external(erlang, "callcenter_ffi", "is_exit_from")
fn exit_from(term: Dynamic, pid: process.Pid) -> Bool

/// End the listener from inside its own callback.
@external(erlang, "callcenter_ffi", "stop_normally")
fn stop_normally() -> Nil

/// Stop the exchange listener, if there is one, and carry on without it.
fn stop_listening(waiting: Waiting) -> Waiting {
  case waiting.listening {
    Some(stop) -> stop()
    None -> Nil
  }
  Waiting(..waiting, listening: None)
}

/// The caller as they arrive, with what the cluster already said about the
/// queue.
///
/// The status answer that let them in counted the agents who could take
/// them. When it counted none, the no-agent clock starts now and not at the
/// first `member_position`: that event is published the moment the
/// dispatcher sees the member, and a caller who heard nothing -- a
/// dispatcher on a node that died, a message the broker had nowhere to put
/// -- would otherwise wait out the whole of `max_wait_time` in a queue that
/// told them on the way in that nobody was there. An account nobody is
/// waiting in has no dispatcher and answers no counts; that caller starts
/// with nothing known, as before.
pub fn arriving(joined: Int, status: Option(Status)) -> caller.Caller {
  case status {
    None -> caller.new(joined)
    Some(status) ->
      caller.positioned(
        caller.new(joined),
        position: None,
        waiting: status.waiting,
        agents_available: status.agents_available,
        at: joined,
      )
  }
}

//
// --- Reading ---------------------------------------------------------------
//

fn category(event: Value) -> String {
  doc.get_string(event, ["Event-Category"]) |> result.unwrap("")
}

fn string_at(event: Value, key: String) -> Option(String) {
  doc.get_string(event, [key]) |> option.from_result
}
