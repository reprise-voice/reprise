//// The periodic announcement a waiting caller hears.
////
//// Every `announce.interval` seconds the caller is told where they are and
//// the queue's own announcement is played: the position prompt, the number,
//// the "in the queue" prompt, then the media. The whole thing goes to the
//// switch as one `audio_macro`, so the parts run without a round trip
//// between them, and hold is re-issued once it has finished -- hold
//// interrupts whatever the channel is doing, so issuing it any earlier is
//// what cuts an announcement off.
////
//// The macro interrupts the hold: hold never finishes on its own, so a
//// macro queued behind it would never play. It does not interrupt a bridge:
//// the offer rings the caller's agents from this same channel, and a macro
//// that lands while that bridge rings waits behind it and plays if the ring
//// comes to nothing. The callflow action does not start one while it knows
//// an offer is ringing; `Insert-At: interrupt` is what covers the moment
//// it does not know yet.
////
//// The prompt names are the ones acdc used, `queue-you_are_at_position' and
//// `queue-in_the_queue', which are system prompts and so are played in the
//// call's own language. A queue that names its own media in
//// `announcements.media` overrides them, which is the field acdc's queues
//// carried.
////
//// Nothing here sends anything except `play`: what to say is a value, so it
//// is decided and checked without a channel.

import callcenter/fields
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/call.{type Call, type MacroItem}
import kazoo/doc.{type Value}

/// `announce.interval` when the queue does not say.
pub const default_interval_s = 30

/// The shortest interval a queue may ask for, which is what `queues.json`
/// allows. A queue configured below it is read as this.
pub const minimum_interval_s = 15

/// The system prompt played before the caller's position.
pub const default_position_prompt = "queue-you_are_at_position"

/// The system prompt played after it.
pub const default_in_the_queue_prompt = "queue-in_the_queue"

/// The two prompts a position announcement is made of.
pub type Prompts {
  Prompts(you_are_at_position: String, in_the_queue: String)
}

/// What one queue announces, and how often.
pub type Settings {
  Settings(
    media: Option(String),
    interval_s: Int,
    position: Bool,
    prompts: Prompts,
  )
}

/// The announcement settings of a queue document.
pub fn settings(queue: Value) -> Settings {
  Settings(
    media: fields.some_string(queue, ["announce", "media"]),
    interval_s: interval(queue),
    position: doc.get_bool(queue, ["announce", "position"])
      |> result.unwrap(False),
    prompts: prompts(queue),
  )
}

fn interval(queue: Value) -> Int {
  case doc.get_int(queue, ["announce", "interval"]) {
    Ok(seconds) if seconds >= minimum_interval_s -> seconds
    Ok(_below) -> minimum_interval_s
    Error(Nil) -> default_interval_s
  }
}

/// The media the position announcement is made of: what the queue names in
/// `announcements.media`, and the system prompts otherwise.
pub fn prompts(queue: Value) -> Prompts {
  Prompts(
    you_are_at_position: fields.some_string(queue, [
      "announcements",
      "media",
      "you_are_at_position",
    ])
      |> option.unwrap(default_position_prompt),
    in_the_queue: fields.some_string(queue, [
      "announcements",
      "media",
      "in_the_queue",
    ])
      |> option.unwrap(default_in_the_queue_prompt),
  )
}

/// The macro one announcement is: the caller's position spoken first when
/// the queue asks for it and the position is known, then the queue's own
/// media.
///
/// Empty when there is nothing to say, which is a queue with no media and no
/// position announcements: the caller is left on hold rather than being
/// interrupted by silence.
pub fn items(
  settings: Settings,
  position: Option(Int),
  language: String,
) -> List(MacroItem) {
  let spoken = case settings.position, position {
    True, Some(place) -> [
      call.MacroPrompt(settings.prompts.you_are_at_position),
      call.MacroSay(int.to_string(place), "number", "pronounced", language),
      call.MacroPrompt(settings.prompts.in_the_queue),
    ]
    _, _ -> []
  }
  let media = case settings.media {
    Some(media) -> [call.MacroPlay(media)]
    None -> []
  }
  list.append(spoken, media)
}

/// Whether an announcement would say anything at all.
pub fn says_anything(settings: Settings, position: Option(Int)) -> Bool {
  items(settings, position, "en-us") != []
}

/// Play one announcement, in place of the hold.
///
/// The hold is flushed first, and with it whatever is queued behind it.
/// Nothing but the caller's actor sends a waiting caller anything, and it
/// queues nothing behind the hold -- but the callflow executor that put the
/// caller in the queue does, if it stops: it queues the channel's hangup on
/// its way out, where the endless hold keeps it from ever running. An
/// announcement that only interrupted the hold would let it run as soon as
/// the announcement ended.
///
/// The switch is not waited on: the whole macro goes out as one command and
/// the actor hears the `CHANNEL_EXECUTE_COMPLETE` of its `noop` when it has
/// finished, which is when hold goes back on.
pub fn play(call: Call, items: List(MacroItem)) -> Nil {
  call.flush(call)
  call.audio_macro_interrupting(call, items)
}

/// Put the caller back on hold, which is what an announcement ends with:
/// queued behind it, so that it starts when the announcement has finished.
pub fn resume_hold(call: Call, moh: Option(String)) -> Nil {
  call.hold_queued(call, moh)
}

/// Whether an event is the end of something this played: the `noop` the
/// switch answers a whole macro with.
pub fn is_finished(event: Value) -> Bool {
  doc.get_string(event, ["Event-Name"]) == Ok("CHANNEL_EXECUTE_COMPLETE")
  && doc.get_string(event, ["Application-Name"]) == Ok("noop")
}
