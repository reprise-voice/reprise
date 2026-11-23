//// The waiting caller, as the callflow action sees them.
////
//// A caller in a queue is a handful of numbers: when they arrived, where
//// they are, how many agents could take them, when they were last told
//// something, and the two clocks that end the wait. The callflow action owns
//// the channel and the AMQP; this owns the arithmetic, so every rule about
//// when a caller leaves and when they are spoken to is decided here and
//// checked without a call.
////
//// Every instant is in **Gregorian seconds**, which is what `kazoo/modb.now`
//// answers and what the queue's messages carry.

import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/doc.{type Value}

/// The longest a caller may wait, and how often they are spoken to. Zero is
/// "no limit" for each of the waits, which is what `queues.json` means by it.
pub type Limits {
  Limits(
    /// `max_wait_time`: the whole wait, agents or no agents.
    max_wait_s: Int,
    /// `max_wait_time_with_no_agent`: how long the queue may hold a caller
    /// while nobody could take them.
    max_wait_with_no_agent_s: Int,
    /// `max_wait_time_with_no_agent_time_reached`: how long a caller must
    /// already have waited before the no-agent clock applies at all.
    no_agent_after_s: Int,
    /// `announce.interval`.
    announce_interval_s: Int,
  )
}

/// One caller, waiting.
pub type Caller {
  Caller(
    /// When they entered the queue.
    joined: Int,
    /// Their place, as the last position event said.
    position: Option(Int),
    /// How many are waiting in the queue, as the last position event said.
    waiting: Option(Int),
    /// How many agents could take them, as the last position event said.
    agents_available: Option(Int),
    /// Since when there has been nobody to take them. `None` while there is
    /// somebody, or while nothing has been heard at all.
    no_agents_since: Option(Int),
    /// Until when an agent's phone is ringing for them, as the dispatcher
    /// last said. `None` when nobody is ringing.
    offered: Option(Int),
    /// When they were last spoken to. `None` until the first announcement.
    last_announced: Option(Int),
    /// Whether an agent has them, after which no clock applies.
    connected: Bool,
  )
}

/// Why a wait ended without an agent.
pub type Expiry {
  /// `max_wait_time` passed.
  WaitedTooLong
  /// `max_wait_time_with_no_agent` passed with nobody to take the caller.
  NoAgentTooLong
}

/// The longest a caller is left before the loop looks at the clocks again,
/// whatever the deadlines say. A caller with no limits at all still has to
/// come round often enough to notice that its channel has gone.
pub const longest_wait_ms = 30_000

/// The shortest, which is not zero.
///
/// `kapps_call_command:receive_event/1` answers a timeout of zero or less
/// without reading the mailbox at all, so a loop that asked for zero would
/// spin without ever seeing the event that would end the spin.
pub const shortest_wait_ms = 100

/// A caller who has just arrived.
pub fn new(joined: Int) -> Caller {
  Caller(
    joined: joined,
    position: None,
    waiting: None,
    agents_available: None,
    no_agents_since: None,
    offered: None,
    last_announced: None,
    connected: False,
  )
}

/// The limits a queue document sets.
pub fn limits(queue: Value) -> Limits {
  Limits(
    max_wait_s: at_least_zero(queue, "max_wait_time"),
    max_wait_with_no_agent_s: at_least_zero(
      queue,
      "max_wait_time_with_no_agent",
    ),
    no_agent_after_s: at_least_zero(
      queue,
      "max_wait_time_with_no_agent_time_reached",
    ),
    announce_interval_s: 0,
  )
}

/// The same, with the announcement interval the queue asks for.
pub fn with_announce_interval(limits: Limits, seconds: Int) -> Limits {
  Limits(..limits, announce_interval_s: at_least(seconds, 0))
}

fn at_least_zero(queue: Value, key: String) -> Int {
  doc.get_int(queue, [key]) |> result.unwrap(0) |> at_least(0)
}

fn at_least(value: Int, floor: Int) -> Int {
  case value < floor {
    True -> floor
    False -> value
  }
}

/// The DTMF keys that take a caller out of the queue.
///
/// `exit_keys` is the string of them; `caller_exit_key` is acdc's single key
/// and is taken when there is no `exit_keys`. A queue that sets `exit_keys`
/// to the empty string has turned them off, which is not the same as not
/// having said anything.
pub fn exit_keys(queue: Value) -> List(String) {
  case doc.get_string(queue, ["exit_keys"]) {
    Ok(keys) -> string.to_graphemes(keys)
    Error(Nil) ->
      case doc.get_string(queue, ["caller_exit_key"]) {
        Ok(key) -> string.to_graphemes(key)
        Error(Nil) -> []
      }
  }
}

/// What a `member_position` event says: where the caller is, how many are
/// waiting, and how many agents could take them.
///
/// The no-agent clock starts the first time nobody can take the caller and
/// is cleared the moment somebody can, so a queue whose last agent logs out
/// and back in again does not carry the earlier gap forward. A count of
/// nobody while a phone is ringing for the caller is not nobody: the agents
/// being rung are counted as busy, and one of them may be about to answer.
pub fn positioned(
  caller: Caller,
  position position: Option(Int),
  waiting waiting: Option(Int),
  agents_available available: Option(Int),
  at at: Int,
) -> Caller {
  Caller(
    ..caller,
    position: option.or(position, caller.position),
    waiting: option.or(waiting, caller.waiting),
    agents_available: option.or(available, caller.agents_available),
    no_agents_since: no_agents_since(caller, available, at),
  )
}

fn no_agents_since(
  caller: Caller,
  available: Option(Int),
  at: Int,
) -> Option(Int) {
  case available, is_offered(caller, at) {
    None, _ -> caller.no_agents_since
    Some(0), True -> None
    Some(0), False ->
      case since_nobody(caller) {
        Some(since) -> Some(since)
        None -> Some(at)
      }
    Some(_some), _ -> None
  }
}

/// Since when there has been nobody, counting an offer whose end was never
/// heard: its ceiling is where the clock starts again if the last count
/// said nobody, so that a lost event pauses the clock for the length of the
/// ring and no longer.
fn since_nobody(caller: Caller) -> Option(Int) {
  case caller.no_agents_since, caller.offered, caller.agents_available {
    Some(since), _, _ -> Some(since)
    None, Some(until), Some(0) -> Some(until)
    None, _, _ -> None
  }
}

/// Whether a phone is ringing for the caller at this moment, as far as the
/// dispatcher has said. An offer whose end was never heard stops counting
/// when its own ceiling passes.
pub fn is_offered(caller: Caller, at at: Int) -> Bool {
  case caller.offered {
    Some(until) -> at < until
    None -> False
  }
}

/// The dispatcher is ringing agents for the caller, and will be until
/// `until` at the latest. Somebody can take them, so the no-agent clock is
/// cleared, and it stays cleared for as long as the phones ring whatever the
/// counts say meanwhile.
pub fn offered(caller: Caller, until until: Int) -> Caller {
  Caller(..caller, offered: Some(until), no_agents_since: None)
}

/// The ringing came to nothing: nobody is ringing for the caller any more.
///
/// The clock restarts from what was last said about the queue, which is the
/// count that was made while the phones rang: the agents who were rung are
/// still counted as busy, on their no-answer delay, and if nobody else was
/// there then nobody is there now. The next position event says otherwise
/// if things have changed. An end heard after the offer's own ceiling
/// changes nothing: the clock has been running from the ceiling.
pub fn offer_over(caller: Caller, at at: Int) -> Caller {
  let since = case is_offered(caller, at) {
    True ->
      no_agents_since(
        Caller(..caller, offered: None),
        caller.agents_available,
        at,
      )
    False -> since_nobody(caller)
  }
  Caller(..caller, offered: None, no_agents_since: since)
}

/// The caller has just been spoken to.
pub fn announced(caller: Caller, at at: Int) -> Caller {
  Caller(..caller, last_announced: Some(at))
}

/// An agent has the caller: the clocks stop.
pub fn connect(caller: Caller) -> Caller {
  Caller(..caller, connected: True)
}

/// Which clock, if any, has run out.
///
/// A connected caller has none: the wait is over and the offer owns what
/// happens next.
pub fn expired(caller: Caller, limits: Limits, now now: Int) -> Option(Expiry) {
  case caller.connected {
    True -> None
    False ->
      case now >= max_wait_deadline(caller, limits) {
        True -> Some(WaitedTooLong)
        False ->
          case no_agent_deadline(caller, limits) {
            Some(deadline) if now >= deadline -> Some(NoAgentTooLong)
            _ -> None
          }
      }
  }
}

/// When the whole wait runs out, or never.
fn max_wait_deadline(caller: Caller, limits: Limits) -> Int {
  case limits.max_wait_s {
    0 -> never
    seconds -> caller.joined + seconds
  }
}

/// When the no-agent wait runs out: the later of the two thresholds, and
/// never while somebody could take the caller. An offer whose end is never
/// heard counts as somebody until its ceiling, and as nobody from then.
fn no_agent_deadline(caller: Caller, limits: Limits) -> Option(Int) {
  case limits.max_wait_with_no_agent_s, since_nobody(caller) {
    0, _ -> None
    _, None -> None
    seconds, Some(since) ->
      Some(later(since + seconds, caller.joined + limits.no_agent_after_s))
  }
}

fn later(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

/// Whether the caller is due an announcement. The first one falls an
/// interval after they arrived, not the moment they do: the greeting has
/// only just finished.
///
/// None is due while a phone is ringing for them. The announcement
/// interrupts the hold, and what they are hearing then is the ring's own
/// hold music: the announcement is deferred, not spent, and falls due the
/// moment the ring comes to nothing.
pub fn announcement_due(caller: Caller, limits: Limits, now now: Int) -> Bool {
  !caller.connected
  && !is_offered(caller, at: now)
  && now >= announce_deadline(caller, limits)
}

/// When the next announcement falls, or never. While a phone rings for the
/// caller it is no sooner than the ring can end, so that the loop waiting
/// for it does not wake for nothing.
fn announce_deadline(caller: Caller, limits: Limits) -> Int {
  case limits.announce_interval_s {
    0 -> never
    seconds -> {
      let due = option.unwrap(caller.last_announced, caller.joined) + seconds
      case caller.offered {
        Some(until) -> later(due, until)
        None -> due
      }
    }
  }
}

/// How long the callflow action may block before one of the clocks needs
/// looking at again, in milliseconds.
///
/// Between `shortest_wait_ms` and `longest_wait_ms`: a deadline that has
/// already passed brings the loop straight back round to act on it, and the
/// floor is what makes the loop read its mailbox on the way.
pub fn next_wake_ms(caller: Caller, limits: Limits, now now: Int) -> Int {
  case caller.connected {
    True -> longest_wait_ms
    False ->
      [
        max_wait_deadline(caller, limits),
        announce_deadline(caller, limits),
        option.unwrap(no_agent_deadline(caller, limits), never),
      ]
      |> soonest
      |> milliseconds_until(now)
  }
}

fn soonest(deadlines: List(Int)) -> Int {
  case deadlines {
    [] -> never
    [deadline] -> deadline
    [deadline, ..rest] -> {
      let other = soonest(rest)
      case deadline < other {
        True -> deadline
        False -> other
      }
    }
  }
}

fn milliseconds_until(deadline: Int, now: Int) -> Int {
  case deadline - now {
    seconds if seconds <= 0 -> shortest_wait_ms
    seconds if seconds > 30 -> longest_wait_ms
    seconds -> seconds * 1000
  }
}

/// A deadline that is not set. Far enough away that the arithmetic never
/// reaches it and still an ordinary integer, so nothing has to special-case
/// it on the way through.
const never = 9_999_999_999_999
