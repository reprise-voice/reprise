//// What a waiting caller is told, and how often.

import callcenter/announce
import gleam/option.{None, Some}
import kazoo/call
import kazoo/doc

fn queue(members: List(#(String, doc.Value))) -> doc.Value {
  doc.object(members)
}

pub fn settings_defaults_test() {
  let settings = announce.settings(queue([#("name", doc.String("Support"))]))
  assert settings.media == None
  assert settings.interval_s == announce.default_interval_s
  assert settings.position == False
  assert settings.prompts.you_are_at_position
    == announce.default_position_prompt
  assert settings.prompts.in_the_queue == announce.default_in_the_queue_prompt
}

pub fn settings_from_the_announce_object_test() {
  let settings =
    announce.settings(
      queue([
        #(
          "announce",
          doc.object([
            #("media", doc.String("all_agents_busy")),
            #("interval", doc.Int(45)),
            #("position", doc.Bool(True)),
          ]),
        ),
      ]),
    )
  assert settings.media == Some("all_agents_busy")
  assert settings.interval_s == 45
  assert settings.position == True
}

/// `queues.json` will not store an interval below fifteen seconds, and a
/// document that predates the schema must not make the loop spin.
pub fn interval_is_floored_test() {
  let settings =
    announce.settings(
      queue([#("announce", doc.object([#("interval", doc.Int(1))]))]),
    )
  assert settings.interval_s == announce.minimum_interval_s
}

/// An empty media string is a queue that has media turned off, not one that
/// announces a file with no name.
pub fn empty_media_is_no_media_test() {
  let settings =
    announce.settings(
      queue([#("announce", doc.object([#("media", doc.String(""))]))]),
    )
  assert settings.media == None
}

pub fn queue_prompts_override_the_system_ones_test() {
  let prompts =
    announce.prompts(
      queue([
        #(
          "announcements",
          doc.object([
            #(
              "media",
              doc.object([
                #("you_are_at_position", doc.String("my-position")),
                #("in_the_queue", doc.String("my-queue")),
              ]),
            ),
          ]),
        ),
      ]),
    )
  assert prompts.you_are_at_position == "my-position"
  assert prompts.in_the_queue == "my-queue"
}

fn announcing(
  media: option.Option(String),
  position: Bool,
) -> announce.Settings {
  announce.Settings(
    media: media,
    interval_s: 30,
    position: position,
    prompts: announce.Prompts(
      you_are_at_position: announce.default_position_prompt,
      in_the_queue: announce.default_in_the_queue_prompt,
    ),
  )
}

pub fn media_only_test() {
  assert announce.items(announcing(Some("hold-tight"), False), Some(3), "en-us")
    == [call.MacroPlay("hold-tight")]
}

/// The position is spoken before the media, and the number goes between the
/// two prompts.
pub fn position_then_media_test() {
  assert announce.items(announcing(Some("hold-tight"), True), Some(3), "en-us")
    == [
      call.MacroPrompt(announce.default_position_prompt),
      call.MacroSay("3", "number", "pronounced", "en-us"),
      call.MacroPrompt(announce.default_in_the_queue_prompt),
      call.MacroPlay("hold-tight"),
    ]
}

pub fn position_in_the_callers_language_test() {
  assert announce.items(announcing(None, True), Some(11), "fr-ca")
    == [
      call.MacroPrompt(announce.default_position_prompt),
      call.MacroSay("11", "number", "pronounced", "fr-ca"),
      call.MacroPrompt(announce.default_in_the_queue_prompt),
    ]
}

/// Nothing is played to a caller whose position is not known yet, even when
/// the queue asks for position announcements.
pub fn no_position_yet_test() {
  assert announce.items(announcing(None, True), None, "en-us") == []
  assert announce.says_anything(announcing(None, True), None) == False
}

pub fn nothing_to_say_test() {
  assert announce.items(announcing(None, False), Some(2), "en-us") == []
  assert announce.says_anything(announcing(None, False), Some(2)) == False
  assert announce.says_anything(announcing(Some("x"), False), None) == True
}

/// One announcement ends with the `noop` the switch answers a whole macro
/// with, which is when the caller may be put back on hold: hold interrupts,
/// so issuing it any earlier cuts the announcement off.
pub fn the_end_of_an_announcement_test() {
  assert announce.is_finished(
      doc.object([
        #("Event-Name", doc.String("CHANNEL_EXECUTE_COMPLETE")),
        #("Application-Name", doc.String("noop")),
      ]),
    )
    == True
  assert announce.is_finished(
      doc.object([
        #("Event-Name", doc.String("CHANNEL_EXECUTE_COMPLETE")),
        #("Application-Name", doc.String("bridge")),
      ]),
    )
    == False
  assert announce.is_finished(
      doc.object([#("Event-Name", doc.String("CHANNEL_ANSWER"))]),
    )
    == False
}
