//// The waiting caller's media: what the switch is told after each of the
//// channel's events, and when the loop wakes for a ceiling.

import callcenter/announce
import callcenter/call/media
import gleam/list
import gleam/option.{None, Some}
import kazoo/call
import kazoo/doc

fn an_event(name: String, fields: List(#(String, doc.Value))) -> doc.Value {
  doc.object([
    #("Event-Category", doc.String("call_event")),
    #("Event-Name", doc.String(name)),
    ..fields
  ])
}

/// Nothing is played until the switch says the channel is up, and the switch
/// says it two ways: `CHANNEL_ANSWER` on a channel that was ringing, and the
/// execute-complete for `answer` either way. A channel some earlier action
/// already answered sends only the second, so both count.
pub fn the_channel_is_up_test() {
  assert media.is_answered(an_event("CHANNEL_ANSWER", []))
  assert media.is_answered(
    an_event("CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("answer")),
      #("Channel-Answer-State", doc.String("answered")),
    ]),
  )

  // The end of the greeting is not the channel coming up.
  assert !media.is_answered(
    an_event("CHANNEL_EXECUTE_COMPLETE", [
      #("Application-Name", doc.String("noop")),
    ]),
  )
  assert !media.is_answered(an_event("CHANNEL_EXECUTE_COMPLETE", []))
  assert !media.is_answered(an_event("DTMF", []))
}

/// The loop may not sleep past the moment it gives up on an event the switch
/// never sent: a caller with no announcements and a long `max_wait_time` has
/// nothing else to wake it, and would wait the whole of it in silence.
pub fn the_loop_wakes_for_a_media_ceiling_test() {
  let a_long_wait = 600_000

  // Answering: five seconds from when the answer went out, and no longer.
  assert media.wake_ms(
      media.Answering(since: 100, greeting: None),
      a_long_wait,
      100,
    )
    == 5000
  assert media.wake_ms(
      media.Answering(since: 100, greeting: None),
      a_long_wait,
      103,
    )
    == 2000

  // Never zero, or a loop already past its ceiling spins.
  assert media.wake_ms(
      media.Answering(since: 100, greeting: None),
      a_long_wait,
      200,
    )
    == 10

  // A deadline of the caller's own that comes first still wins.
  assert media.wake_ms(media.Answering(since: 100, greeting: None), 1500, 100)
    == 1500

  // On hold nothing is owed, so the caller's own deadline is the whole of it.
  assert media.wake_ms(media.Held, a_long_wait, 100) == a_long_wait
  assert media.wake_ms(media.Playing(since: 100), 90_000, 100) == 60_000
}

const greeting = "queue-welcome"

fn answered() -> doc.Value {
  an_event("CHANNEL_ANSWER", [])
}

/// The switch has finished the greeting or an announcement.
fn play_over() -> doc.Value {
  an_event("CHANNEL_EXECUTE_COMPLETE", [
    #("Application-Name", doc.String("noop")),
  ])
}

/// What the media does for a script of events: every cue in order, and
/// where it ends up.
fn cued(
  media: media.Media,
  script: List(#(Int, doc.Value)),
) -> #(media.Media, List(media.Cue)) {
  cueing(media, script, [])
}

fn cueing(
  media: media.Media,
  script: List(#(Int, doc.Value)),
  done: List(media.Cue),
) -> #(media.Media, List(media.Cue)) {
  case script {
    [] -> #(media, list.reverse(done))
    [#(at, event), ..rest] -> {
      let #(media, cue) = media.on_event(media, event, at)
      cueing(media, rest, [cue, ..done])
    }
  }
}

/// The greeting plays to its end and hold follows it, as it always did; an
/// announcement ends the same way.
pub fn hold_follows_the_greeting_test() {
  assert cued(media.Answering(since: 100, greeting: Some(greeting)), [
      #(100, answered()),
      #(108, play_over()),
    ])
    == #(media.Held, [
      media.PlayGreeting(greeting),
      media.Hold,
    ])
  assert cued(media.Playing(since: 130), [#(140, play_over())])
    == #(media.Held, [media.Hold])
}

/// Missing answer confirmation never starts media; only playback has a fallback.
pub fn only_playback_timeout_ends_in_hold_test() {
  assert media.overdue_cue(media.Answering(since: 100, greeting: None), 104)
    == #(media.Answering(since: 100, greeting: None), media.Nothing)
  assert media.overdue_cue(
      media.Answering(since: 100, greeting: Some(greeting)),
      105,
    )
    == #(media.Answering(since: 100, greeting: Some(greeting)), media.Nothing)
  assert media.overdue_cue(media.Playing(since: 100), 160)
    == #(media.Held, media.Hold)
  assert media.overdue_cue(media.Held, 10_000) == #(media.Held, media.Nothing)
}

/// A queue that says where the caller is, and nothing else.
fn position_only() -> announce.Settings {
  announce.Settings(
    media: None,
    interval_s: 30,
    position: True,
    prompts: announce.prompts(doc.object([])),
  )
}

fn the_announcement() -> List(call.MacroItem) {
  announce.items(position_only(), Some(3), "en-us")
}

/// On hold, the announcement is played in place of the hold and the media
/// is playing until its end. Anywhere else nothing is said: the interval is
/// spent, which `speak` decides, and the caller goes on hearing what they
/// were hearing.
pub fn an_announcement_interrupts_the_hold_and_nothing_else_test() {
  assert media.announcement_cue(
      media.Held,
      position_only(),
      Some(3),
      "en-us",
      130,
    )
    == #(media.Playing(since: 130), media.Announce(the_announcement()))
  assert media.announcement_cue(
      media.Playing(since: 120),
      position_only(),
      Some(3),
      "en-us",
      130,
    )
    == #(media.Playing(since: 120), media.Nothing)
  assert media.announcement_cue(
      media.Answering(since: 129, greeting: None),
      position_only(),
      Some(3),
      "en-us",
      130,
    )
    == #(media.Answering(since: 129, greeting: None), media.Nothing)
}

/// A queue with nothing to say leaves the caller on hold rather than
/// interrupting it with silence.
pub fn nothing_to_announce_leaves_the_hold_alone_test() {
  assert media.announcement_cue(media.Held, position_only(), None, "en-us", 130)
    == #(media.Held, media.Nothing)
}

/// The announcement plays to its end and hold follows it.
pub fn hold_follows_the_announcement_test() {
  let #(media, _cue) =
    media.announcement_cue(media.Held, position_only(), Some(3), "en-us", 130)
  assert cued(media, [#(138, play_over())]) == #(media.Held, [media.Hold])
}
