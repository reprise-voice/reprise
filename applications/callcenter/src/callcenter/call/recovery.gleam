//// Where a caller stands, for an actor that was handed them without knowing.
////
//// A caller's actor usually knows everything about its call, because it did
//// everything to it. Three things hand it a caller it knows nothing of:
//// the node that was holding the caller's shard died and the broker handed
//// the member to this one; the caller's actor on this node crashed and the
//// dispatcher joined them to a new one; or the member came round again for
//// a reason nobody here can see. Whatever the last actor did is still on
//// the switch -- hold still playing, phones still ringing, an agent's leg
//// answered and parked, a conversation going on, a departure half done --
//// and the caller's `queue_call` record says what was written of it.
////
//// So the new actor asks. It probes the caller's channel with a `noop` run
//// at once, whose completion carries the channel's live variables, the
//// marks the last actor wrote among them; it takes the account's channels
//// from the switches, where the queue's legs are listed with the variables
//// they were born with; and it reads the record. `classify` is what it
//// makes of the three: a function of them alone, so that every case below
//// is a table a test reads without a switch.
////
//// **A record that could not be read** is not a record that is not there
//// (`Recorded`). Whatever the record would decide -- an answered call over
//// or a caller gone, a passage over or still going -- is `Unknown` without
//// it, and asked again; only the last try takes it for no record
//// (`unread_as_none`).
////
//// **The caller's legs** are the rows whose `Queue-Call-ID` is the caller's
//// and whose own call id is their offer's name for them,
//// `<Queue-Offer-ID>-N`: a forwarded device's loopback carries the caller's
//// `Queue-Call-ID` on its far side too, under a name of its own, and is not
//// a leg the queue rang (the lab of 2026-09-27). Every `ecallmgr` lists a
//// channel it knows, so a row can come more than once; one per call id is
//// kept. A leg rung for an earlier passage of the caller -- a queue they
//// have since left -- says so by its `Queue-Joined-Timestamp`, and is only
//// ever hung up.
////
//// **Bridged** is two rows naming each other: the caller's `other_leg` is
//// the channel, and the channel's `other_leg` is the caller. The caller's
//// row alone does not say -- its `other_leg` is left behind when the
//// bridge ends -- and a leg that is not bridged names itself.
////
//// **Parked, or passed on.** A caller the record has an answer for, through
//// to nobody now, had their conversation end while nothing watched it, and
//// the listing cannot say how. The bridge put `park_after_bridge` on the
//// caller (`Park-After-Pickup`), so a caller whose agent hung up is parked,
//// in silence, and nothing but their actor will ever hang them up; a caller
//// the agent passed on is running the transfer's callflow, and is not the
//// queue's to touch. The probe tells the two apart. It goes to the control
//// queue the callflow action handed over with the caller, which `ecallmgr`
//// addresses to the one control process that took the caller into the
//// queue (`pid://`, delivered to that process and to no other), and that
//// process stops when anything else takes the channel: a transfer's
//// `CHANNEL_TRANSFEREE`, or another callflow's `usurp_control`. A command
//// sent to it after that goes nowhere. A probe answered is a caller the
//// queue still commands, through to nobody: parked alone, and the actor
//// hangs them up. A probe not answered is a caller something else has, or
//// whose control process has gone, and they are left as they are. What
//// makes the hang-up safe is that process, not the probe's completion: a
//// probe sent while the caller is still bridged is held by the switch until
//// the bridge ends, and can complete after a transfer has parked them; but
//// the hang-up goes through the process the transfer stopped, and so goes
//// nowhere.

import callcenter/records
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import kazoo/doc.{type Value}
import kazoo/events
import kazoo/kazoo

/// How much of its ring an offer found ringing must have left to be taken
/// on. Less than this and it is hung up: the phones would stop before
/// anybody could answer, and the caller is better offered again.
pub const least_ring_s = 3

/// What the probe of the caller's channel came back with.
pub type Probe {
  /// The completion of the `noop`: the event, with the channel's variables
  /// as they are now.
  Answered(event: Value)
  /// Nothing, in the time it was given.
  Unanswered
}

/// What the actor found out about the caller besides the probe: what the
/// switches list, `None` when none of them answered, and the caller's
/// record of this passage.
pub type Survey {
  Survey(channels: Option(events.Channels), record: Recorded)
}

/// The caller's record of this passage, as the survey came back with it.
///
/// A record that is not there and one that could not be read are not the
/// same finding. The first is a passage nothing was written for, which says
/// the caller was never answered and never left. The second says nothing:
/// the passage may have been answered, or be over. Taken for the first, a
/// takeover during a datastore outage settles a caller whose answered call
/// ended unwatched as a hang-up, losing its end and its agent's counters,
/// and offers again a caller whose passage is over and whose member came
/// round only because its settle was lost.
pub type Recorded {
  /// Read: the passage's document, `None` when the datastore said there is
  /// none.
  RecordRead(Option(records.Passage))
  /// Not read: the datastore did not answer, or the survey did not come in
  /// before the try's time was up. `reason` is for the log.
  RecordUnreadable(reason: String)
}

/// The record as `records.read` answered.
pub fn record(read: Result(Option(records.Passage), kazoo.Error)) -> Recorded {
  case read {
    Ok(found) -> RecordRead(found)
    Error(error) -> RecordUnreadable(kazoo.error_to_string(error))
  }
}

/// Everything `classify` is given.
pub type Found {
  Found(
    call_id: String,
    /// The passage's own id, which the marks name.
    handoff_id: String,
    /// The Gregorian second the passage began, which its legs carry.
    joined: Int,
    probe: Probe,
    survey: Survey,
    /// Gregorian seconds.
    now: Int,
  )
}

/// One leg an offer rang for the caller, as the switches list it.
pub type Leg {
  Leg(
    call_id: String,
    /// The offer's leg prefix, `Queue-Offer-ID`.
    offer: String,
    agent_id: String,
    answered: Bool,
    /// `Queue-Offer-Deadline`: the Gregorian second the offer is given up
    /// at.
    deadline: Int,
    /// A supervisor's pickup rather than an agent's offer.
    pickup: Bool,
    /// `Queue-Joined-Timestamp`: the passage the leg was rung for.
    joined: Option(Int),
  )
}

/// Where the caller stands, in the order it is decided: the first that
/// holds is the answer.
pub type Finding {
  /// The caller's channel is on no switch.
  Gone
  /// The caller's channel is on no switch, and the record says an agent
  /// answered and nothing closed the call: it ended while nothing watched
  /// it, and is closed as a call, not as a caller who left.
  Finished(agent_id: String, answered_at: Int, pickup: Bool)
  /// The record says the passage is over, and its member came round again
  /// only because its settle was lost.
  Closed
  /// The callflow has the caller back: the action marked the channel
  /// `Queue-Departed` for this passage. `branch` is the one they left on,
  /// if the departure's mark says.
  Departed(branch: Option(String))
  /// The caller is through to somebody the queue did not ring: a pickup, a
  /// transfer.
  Moved
  /// The caller is through to one of the queue's legs.
  Connected(leg: Leg, answered_at: Int)
  /// The last actor was handing the caller back: the departure's mark is
  /// this passage's, and the action has not taken them.
  Departing(branch: Option(String))
  /// The record says an agent answered, and the caller is through to
  /// nobody now: the conversation ended while nothing watched it. An
  /// answered leg then is not bridged again: it is hung up.
  ///
  /// `parked` is the probe having answered: the control process the queue
  /// commands the caller through still has their channel, and the channel
  /// is in no bridge, so the caller is parked where the agent's end left
  /// them. Without it the caller may be in the callflow a transfer took
  /// them to (see "Parked, or passed on" above).
  Talked(agent_id: String, answered_at: Int, pickup: Bool, parked: Bool)
  /// A leg answered and parks, and the caller, still waiting, is not
  /// through to it. `answered_at` is when, as the last actor's marks say
  /// (`answered_at`), and `ring` is the rest of that offer's legs.
  Parked(leg: Leg, answered_at: Int, ring: List(Leg))
  /// An offer's phones are ringing, with time left.
  Ringing(ring: List(Leg))
  /// Waiting, nothing of the queue's going on for them.
  Waiting
  /// Not known: the caller did not answer the probe and the switches did
  /// not all say whether they have the channel; or the record could not be
  /// read, and what it says decides where the caller stands. Asked again.
  Unknown
}

/// Where the caller stands, and the legs of theirs to hang up: every leg
/// the finding does not keep.
pub fn classify(found: Found) -> #(Finding, List(String)) {
  let rows = case found.survey.channels {
    Some(channels) -> dedupe(channels.channels)
    None -> []
  }
  let complete = case found.survey.channels {
    Some(channels) -> channels.complete
    None -> False
  }
  let caller = list.find(rows, fn(row) { row.call_id == found.call_id })
  let #(legs, earlier) =
    legs_of(rows, found.call_id)
    |> list.partition(fn(leg) {
      leg.joined == None || leg.joined == Some(found.joined)
    })
  // The caller's own switch did not answer: the legs start on the caller's
  // switch, so the listing says nothing of their legs or their bridge.
  let unlisted = !complete && caller == Error(Nil)
  let finding = case found.probe, caller, complete {
    // Only every switch answering without the channel, and the channel not
    // answering either, is a caller who has gone.
    Unanswered, Error(Nil), True -> gone(found.survey.record)
    Unanswered, Error(Nil), False -> Unknown
    _, _, _ ->
      standing(found, legs, bridged(rows, caller, found.call_id), unlisted)
  }
  let kept = case finding {
    Connected(leg, _) -> [leg]
    Parked(leg, _, ring) -> [leg, ..ring]
    Ringing(ring) -> ring
    // Nothing is hung up on a guess.
    Unknown -> legs
    Gone
    | Finished(..)
    | Closed
    | Departed(_)
    | Moved
    | Departing(_)
    | Talked(..)
    | Waiting -> []
  }
  let kept = list.map(kept, fn(leg) { leg.call_id })
  #(
    finding,
    list.append(legs, earlier)
      |> list.map(fn(leg) { leg.call_id })
      |> list.filter(fn(leg) { !list.contains(kept, leg) })
      |> list.sort(string.compare),
  )
}

/// A caller whose channel is gone: a call that ended unwatched, when the
/// record has an answer and nothing closed it. A record that could not be
/// read cannot say which, and the caller is asked about again: settled as a
/// hang-up, an answered call would lose its end and its agent's counters.
fn gone(record: Recorded) -> Finding {
  case record {
    RecordRead(Some(
      records.Passage(answered: Some(at), ended: None, cancelled: None, ..) as passage,
    )) -> Finished(passage.agent_id |> option.unwrap(""), at, passage.picked_up)
    RecordRead(_) -> Gone
    RecordUnreadable(_) -> Unknown
  }
}

/// A caller whose channel is up: the record, the marks and the bridge, in
/// that order.
///
/// A record that could not be read is `Unknown`, whatever the marks and the
/// bridge say. The record is asked first because a passage it says is over
/// is over whatever the switch still has of it, so without it no finding
/// here is sure: a `Closed` passage taken for a caller waiting or ringing
/// is offered again, and taken for one who departed or moved has its
/// cancel written over; a `Talked` call is offered again, or has its
/// answered leg bridged again. The actor asks again, and only after its
/// last try takes the caller as the switch alone finds them
/// (`unread_as_none`, `core.recover_attempts`).
///
/// `unlisted` is a listing that cannot say: the caller's own switch did not
/// answer it. The record and the marks still say what they say, but a
/// caller the record has an agent ringing or answered for is `Unknown`, not
/// `Waiting` or `Talked`. A ring nobody can see would be rung again over
/// the top of itself, and a conversation nobody can see would be closed
/// while it goes on. A node that has just started is where this happens:
/// `kz_nodes` hears of the `ecallmgr`s 15 to 40 seconds after it starts,
/// and a channel query asks nobody until then. In the lab of 2026-09-28
/// (e2e-260927-cca7), a restarted holder took its own shard back 16
/// seconds after its restart and rang a ringing agent a second time.
fn standing(
  found: Found,
  legs: List(Leg),
  through: Option(String),
  unlisted: Bool,
) -> Finding {
  case found.survey.record {
    RecordUnreadable(_) -> Unknown
    RecordRead(record) -> standing_by(found, record, legs, through, unlisted)
  }
}

/// `standing`, the record read.
fn standing_by(
  found: Found,
  record: Option(records.Passage),
  legs: List(Leg),
  through: Option(String),
  unlisted: Bool,
) -> Finding {
  let marks = case found.probe {
    Answered(event) -> Some(event)
    Unanswered -> None
  }
  let mark = fn(name) {
    option.then(marks, fn(event) {
      events.custom_channel_var(event, name) |> none_if_empty
    })
  }
  let this_passage = fn(name) { mark(name) == Some(found.handoff_id) }
  let branch = mark(departing_branch_var)
  let closed = case record {
    Some(records.Passage(ended: Some(_), ..))
    | Some(records.Passage(cancelled: Some(_), ..)) -> True
    _ -> False
  }
  case closed, this_passage(departed_var), through {
    True, _, _ -> Closed
    False, True, _ -> Departed(branch)
    False, False, Some(other) ->
      case list.find(legs, fn(leg) { leg.call_id == other }) {
        Ok(leg) -> Connected(leg, answered_at(marks, leg, record, found.now))
        Error(Nil) -> Moved
      }
    False, False, None ->
      case this_passage(departing_var), unlisted && is_busy(record) {
        True, _ -> Departing(branch)
        False, True -> Unknown
        False, False ->
          not_departing(marks, record, legs, option.is_some(marks), found.now)
      }
  }
}

/// Whether the record has something of the queue's going on for the
/// caller: an offer out, or an agent's answer.
fn is_busy(record: Option(records.Passage)) -> Bool {
  case record {
    Some(records.Passage(answered: Some(_), ..))
    | Some(records.Passage(offer: Some(_), ..)) -> True
    _ -> False
  }
}

/// A caller still in the queue, not through to anybody: an answered leg to
/// bridge them to, the end of a conversation nobody watched, a ring to take
/// on, or nothing. `marks` date a parked leg's answer when they name its
/// agent; `reached` is the probe having answered, which after a
/// conversation is the caller parked alone.
fn not_departing(
  marks: Option(Value),
  record: Option(records.Passage),
  legs: List(Leg),
  reached: Bool,
  now: Int,
) -> Finding {
  let answered_leg = list.find(legs, fn(leg) { leg.answered })
  let talked = case record {
    Some(records.Passage(answered: Some(at), ..) as passage) ->
      Some(Talked(
        agent_id: passage.agent_id |> option.unwrap(""),
        answered_at: at,
        pickup: passage.picked_up,
        parked: reached,
      ))
    _ -> None
  }
  case talked, answered_leg {
    Some(talked), _ -> talked
    None, Ok(leg) ->
      Parked(
        leg,
        answered_at(marks, leg, record, now),
        list.filter(legs, fn(other) {
          other.offer == leg.offer && other.call_id != leg.call_id
        }),
      )
    None, Error(Nil) ->
      case newest_ring(legs, now) {
        [] -> Waiting
        ring -> Ringing(ring)
      }
  }
}

/// The legs of the offer rung last, if it has `least_ring_s` of its ring
/// left: the newest deadline among the legs still ringing.
fn newest_ring(legs: List(Leg), now: Int) -> List(Leg) {
  let ringing = list.filter(legs, fn(leg) { !leg.answered })
  let newest =
    ringing
    |> list.sort(fn(a, b) {
      int.compare(b.deadline, a.deadline)
      |> order.lazy_break_tie(fn() { string.compare(a.offer, b.offer) })
    })
    |> list.first
  case newest {
    Ok(newest) if newest.deadline - now >= least_ring_s ->
      list.filter(ringing, fn(leg) { leg.offer == newest.offer })
    _ -> []
  }
}

/// The channel the caller is through to, if two rows name each other.
fn bridged(
  rows: List(events.Channel),
  caller: Result(events.Channel, Nil),
  call_id: String,
) -> Option(String) {
  case caller {
    Error(Nil) -> None
    Ok(caller) ->
      case caller.other_leg {
        Some(other) if other != "" && other != call_id ->
          case list.find(rows, fn(row) { row.call_id == other }) {
            Ok(row) if row.other_leg == Some(call_id) -> Some(other)
            _ -> None
          }
        _ -> None
      }
  }
}

/// When a leg answered. The last actor marked the caller's channel with the
/// agent and the second as the leg answered, before it bridged them; a mark
/// naming this leg's agent is that. Without one -- the actor died before
/// its marks ran -- the record's answer, and failing that, now.
fn answered_at(
  marks: Option(Value),
  leg: Leg,
  record: Option(records.Passage),
  now: Int,
) -> Int {
  let marked =
    option.then(marks, fn(event) {
      case
        events.custom_channel_var(event, "Agent-ID"),
        option.then(
          events.custom_channel_var(event, "Queue-Answered-Timestamp"),
          fn(text) { int.parse(text) |> option.from_result },
        )
      {
        Some(agent_id), Some(at) if agent_id == leg.agent_id && at > 0 ->
          Some(at)
        _, _ -> None
      }
    })
  case marked, record {
    Some(at), _ -> at
    None, Some(records.Passage(answered: Some(at), ..)) -> at
    None, _ -> now
  }
}

/// The caller's legs among the rows: named by their offer, carrying the
/// caller's call id.
pub fn legs_of(rows: List(events.Channel), call_id: String) -> List(Leg) {
  list.filter_map(rows, fn(row) {
    let var = fn(name) { channel_var(row.doc, name) }
    case var("Queue-Call-ID"), var("Queue-Offer-ID") {
      Some(of), Some(offer) if of == call_id ->
        case string.starts_with(row.call_id, offer <> "-") {
          True ->
            Ok(Leg(
              call_id: row.call_id,
              offer: offer,
              agent_id: var("Agent-ID") |> option.unwrap(""),
              answered: row.answered,
              deadline: var("Queue-Offer-Deadline")
                |> option.then(fn(text) {
                  int.parse(text) |> option.from_result
                })
                |> option.unwrap(0),
              pickup: var("Queue-Pickup") == Some("true"),
              joined: var("Queue-Joined-Timestamp")
                |> option.then(fn(text) {
                  int.parse(text) |> option.from_result
                }),
            ))
          False -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { string.compare(a.call_id, b.call_id) })
}

/// The call ids of the caller's legs among what a survey found: what the
/// actor listens to before it looks at them.
pub fn leg_ids(survey: Survey, call_id: String) -> List(String) {
  case survey.channels {
    Some(channels) ->
      legs_of(dedupe(channels.channels), call_id)
      |> list.map(fn(leg) { leg.call_id })
    None -> []
  }
}

/// One row per call id: every `ecallmgr` lists the channels it knows.
fn dedupe(rows: List(events.Channel)) -> List(events.Channel) {
  list.fold(rows, dict.new(), fn(seen, row) {
    case dict.has_key(seen, row.call_id) {
      True -> seen
      False -> dict.insert(seen, row.call_id, row)
    }
  })
  |> dict.values
  |> list.sort(fn(a, b) { string.compare(a.call_id, b.call_id) })
}

/// A channel variable of a row, in either spelling the switches answer in,
/// as text: the channel queries answer in `ecallmgr_fs_channel:to_json/1`'s
/// snake case, and a number or a flag may come back as either.
fn channel_var(row: Value, name: String) -> Option(String) {
  [["custom_channel_vars", name], ["Custom-Channel-Vars", name]]
  |> list.find_map(fn(path) {
    case
      doc.get_string(row, path),
      doc.get_int(row, path),
      doc.get_bool(row, path)
    {
      Ok(text), _, _ -> Ok(text)
      _, Ok(number), _ -> Ok(int.to_string(number))
      _, _, Ok(True) -> Ok("true")
      _, _, Ok(False) -> Ok("false")
      _, _, _ -> Error(Nil)
    }
  })
  |> option.from_result
  |> none_if_empty
}

fn none_if_empty(value: Option(String)) -> Option(String) {
  case value {
    Some("") -> None
    other -> other
  }
}

// --- The marks -----------------------------------------------------------------

/// The mark a departing caller's channel carries: the passage's id.
pub const departing_var = "Queue-Departing"

/// The branch the departing caller leaves on, beside the mark.
pub const departing_branch_var = "Queue-Departing-Branch"

/// The mark the callflow action writes once it has the caller back: the
/// passage's id. `cf_callcenter.departed_var` is the same name.
pub const departed_var = "Queue-Departed"

/// The `Msg-ID` of a probe.
pub fn probe_id(handoff_id: String, attempt: Int) -> String {
  "callcenter-probe-" <> handoff_id <> "-" <> int.to_string(attempt)
}

/// The survey an actor that could not survey classifies with: no switch
/// answered, and the record was not read. It is not a survey that found no
/// record -- the datastore may be what kept it -- so nothing the record
/// would decide is decided on it.
pub fn nothing() -> Survey {
  Survey(channels: None, record: RecordUnreadable("not surveyed"))
}

/// The survey with a record that could not be read taken to be no record:
/// what the actor's last try classifies with, once every try has failed to
/// read it (`core.recover_attempts`).
///
/// The caller is then where the probe and the switches alone put them. That
/// is right far more often than taking them to be waiting, which is what a
/// caller the switches cannot place is taken to be: a caller in a
/// conversation is not put on hold, one who has gone is not offered, and
/// one the callflow has back is let go. What it can get wrong is only what
/// the record alone knows -- an answered call that ended unwatched is
/// settled as a hang-up, and a passage that is over is taken up again.
/// Asking for longer is no better: while the actor asks, nobody rings for
/// the caller, a departure half done keeps them in silence, and the phones
/// found ringing are watched by nobody.
pub fn unread_as_none(survey: Survey) -> Survey {
  case survey.record {
    RecordUnreadable(_) -> Survey(..survey, record: RecordRead(None))
    RecordRead(_) -> survey
  }
}

/// A probe's completion, if an event is one: the `noop` with this
/// `Msg-ID`.
pub fn probe_of(event: Value, msg_id: String) -> Option(Probe) {
  case
    events.event_name(event) == Some("CHANNEL_EXECUTE_COMPLETE")
    && doc.get_string(event, ["Application-Name"]) == Ok("noop")
    && doc.get_string(event, ["Application-Response"]) == Ok(msg_id)
  {
    True -> Some(Answered(event))
    False -> None
  }
}
