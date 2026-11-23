//// A queue call's recording.
////
//// A queue records when its document says `record` or when any agent rung
//// has `record` in their call center settings; the dispatcher decides that
//// and the offer starts the recording the moment the caller is through to
//// somebody. It runs on the caller's own leg, so it has both sides of the
//// conversation, and it stops by itself at hangup.
////
//// It is Kazoo's own recording, not a bare `record_call`: the command names
//// `kz_media_recording` as the recorder and carries these settings on the
//// switch's channel, and whichever `media_mgr` takes the `RECORD_STOP`
//// writes the `call_recording` document into the account's modb and stores
//// the file where the account's recordings go. Nothing on this node takes
//// part after the start. A shard that moves in the middle of the call, or a
//// node that dies, therefore loses nothing and leaves nothing behind.
////
//// What is stored and how is the account's. The settings start from the
//// account's own `call_recording.account.inbound` for the network the
//// caller came from -- format, time limit, `url` and the rest -- without
//// what decides whether and when that recording happens, which here is the
//// queue's to decide. What the account does not set is the system's:
//// `media.max_recording_time_limit` and `media.call_recording.extension`.
//// Whether the file is stored at all is the account's storage plan or
//// `media.store_recordings`, as for every other recording.

import callcenter/system
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import kazoo/call.{type Call}
import kazoo/doc.{type Value}
import kazoo/kazoo

/// Start the recording of a queue call on the caller's channel.
pub fn start(
  caller: Call,
  account_id: String,
  queue_id: String,
  call_id: String,
  agent_id: String,
  at: Int,
) -> Nil {
  call.start_recording(
    caller,
    of_call(
      account(account_id),
      network(caller),
      queue_id,
      call_id,
      agent_id,
      at,
    ),
  )
}

/// Stop the recording `start` began for the answer at `at`, and nothing else
/// recording on the channel: an answer the call-off of its ring overtook,
/// whose caller goes on to the rest of their callflow
/// (`callcenter/offer.overtaken`).
///
/// The switch finds a recording by its file, so the name is built as `start`
/// builds it: `name`, and the extension of the format the account's settings
/// give -- the same settings, read again.
pub fn stop(
  caller: Call,
  account_id: String,
  queue_id: String,
  call_id: String,
  at: Int,
) -> Nil {
  let format =
    account_settings(account(account_id), network(caller))
    |> doc.get_string(["format"])
  call.record_call(
    caller,
    call.RecordStop,
    call.RecordOptions(
      ..call.record_options(),
      media_name: Some(
        file_name(name(queue_id, call_id, at), case format {
          Ok(format) -> format
          Error(Nil) -> ""
        }),
      ),
    ),
  )
}

/// The file a recording called `name` is written to, for a `format` the
/// account's settings give (empty for none): `kapps_call_recording`'s own
/// choice of extension.
@external(erlang, "callcenter_ffi", "recording_file_name")
fn file_name(name: String, format: String) -> String

/// The recording of one answer of one queue call.
///
/// `origin` and `recording_vars` are what the `call_recording` document
/// says about where it came from, which is what finds it again: the queue,
/// the caller's call and the agent who answered. The call is also the
/// document's own `call_id`, and the channel's `Queue-ID` and `Agent-ID` are
/// in its `custom_channel_vars`.
pub fn of_call(
  account: Value,
  network: String,
  queue_id: String,
  call_id: String,
  agent_id: String,
  at: Int,
) -> call.Recording {
  let settings =
    account_settings(account, network)
    |> doc.set(["origin"], doc.String("callcenter : queue " <> queue_id))
    |> doc.set(
      ["recording_vars"],
      doc.object([
        #("queue_id", doc.String(queue_id)),
        #("call_id", doc.String(call_id)),
        #("agent_id", doc.String(agent_id)),
        #("answered_at", doc.Int(at)),
      ]),
    )
  call.Recording(name: name(queue_id, call_id, at), settings: settings)
}

/// What the file is called, before the format adds its extension.
///
/// A caller who comes back to a queue is answered again, and a second
/// recording under the first one's name would be appended to the first
/// file if its upload were still to come. The second of the answer keeps
/// the two apart.
pub fn name(queue_id: String, call_id: String, at: Int) -> String {
  "queue-" <> queue_id <> "-" <> call_id <> "-" <> int.to_string(at)
}

/// What decides whether and when the account's own recording happens, which
/// the queue has decided -- the time is now -- and what names it, which is
/// `name`.
const deciding = [
  "enabled", "record_on_answer", "record_on_bridge",
  "should_record_feature_calls", "media_name", "media_id",
]

/// The account's recording settings for calls coming in from `network`,
/// without the ones that are the queue's to decide.
pub fn account_settings(account: Value, network: String) -> Value {
  case doc.get(account, ["call_recording", "account", "inbound", network]) {
    Ok(settings) ->
      case doc.is_object(settings) {
        True ->
          list.fold(deciding, settings, fn(acc, key) { doc.delete(acc, [key]) })
        False -> doc.object([])
      }
    Error(Nil) -> doc.object([])
  }
}

/// Where the caller came from, in the words the account's settings are
/// keyed by: a call with an inception came from outside.
pub fn network(caller: Call) -> String {
  case call.inception(caller) {
    Some(_) -> "offnet"
    None -> "onnet"
  }
}

fn account(account_id: String) -> Value {
  case
    system.live().datamgr.open_cache_doc(
      kazoo.account_db(account_id),
      account_id,
    )
  {
    Ok(account) -> account
    Error(_) -> doc.object([])
  }
}
