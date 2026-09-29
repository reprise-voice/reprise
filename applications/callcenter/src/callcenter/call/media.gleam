//// The waiting caller's media, as values: where it is, and what the switch
//// is told next.
////
//// A waiting caller hears three things in turn: nothing while the answer is
//// owed, the greeting or an announcement, and hold music. Which of them is
//// playing, and what one of the channel's events or a ceiling running out
//// means for it, is decided here from the media state alone and returned as
//// a `Cue`. Nothing here sends a command: whoever owns the caller's channel
//// performs the cue, so the order of the caller's media is something a test
//// reads without a switch.
////
//// Every instant is in Gregorian seconds, as in `callcenter/caller`.

import callcenter/announce
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import kazoo/call
import kazoo/doc.{type Value}
import kazoo/events

/// The longest the greeting or an announcement is believed to be still
/// playing before hold is put back whatever the switch has said. A caller
/// left in silence because one execute-complete went missing is worse than
/// hold starting a little early.
pub const longest_play_s = 60

/// How long one answer attempt is given before the action retries it: see
/// `cf_callcenter`'s answer budget.
pub const longest_answer_s = 5

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

/// What an announcement falling due means for the media: on hold it is
/// played, in place of the hold, and the media is playing until its end.
/// Anywhere else -- the channel not yet up, the greeting or an earlier
/// announcement still going -- nothing is said.
///
/// The announcement interrupts. Hold never finishes on its own, so an
/// announcement queued behind it would never be heard: the lab of
/// 2026-09-14 had callers who were never told their position. It is not sent
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

/// Hold goes back on after a play whose end the switch never reported: see
/// `longest_play_s`.
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
pub fn up(media: Media, now: Int) -> #(Media, Cue) {
  case media {
    Answering(_since, Some(greeting)) -> #(
      Playing(since: now),
      PlayGreeting(greeting),
    )
    Answering(_since, None) -> #(Held, Hold)
    _already_up -> #(media, Nothing)
  }
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

fn category(event: Value) -> String {
  doc.get_string(event, ["Event-Category"]) |> result.unwrap("")
}

fn string_at(event: Value, key: String) -> Option(String) {
  doc.get_string(event, [key]) |> option.from_result
}
