//// The channel: what is known about a call, and what can be asked of it.
////
//// A `Call` is Kazoo's `kapps_call` record. It is a record, and a
//// gleam-compiled Erlang file has no include path to the header that
//// declares it, so it never becomes a Gleam value: it crosses the boundary
//// opaque and every read goes back out through `kapps_call`'s own accessors.
//// `from_value` and `to_value` convert to and from the JSON form, which is
//// what a route win, an AMQP message and a stored document all carry.
////
//// The call is immutable here as it is in Erlang: a setter answers a new
//// `Call` and the caller has to keep it. A command, by contrast, is a
//// message to the channel; it changes nothing about the value.
////
//// Nothing in this module needs a channel to be safe to call. Without a
//// Kazoo release the accessors read the JSON form the call was built from
//// and the commands do nothing, so a callflow action's decisions are
//// testable without a media server.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import kazoo/doc.{type Value}

/// A `kapps_call` record. Opaque on purpose: read it with the accessors.
pub type Call

/// A call with nothing known about it, which is where a test and a synthetic
/// route win both start.
@external(erlang, "kazoo_gleam_call_ffi", "new")
pub fn new() -> Call

/// A call from the JSON form of the record: `Call-ID`, `Account-ID`,
/// `Control-Queue`, `Custom-Channel-Vars` and the rest.
pub fn from_value(value: Value) -> Call {
  ffi_from_json(doc.to_string(value))
}

/// The call back as a document, for a message or a stored document.
pub fn to_value(call: Call) -> Value {
  doc.from_dynamic(ffi_to_map(call))
}

/// Whether a value really is a call. The route win and the member message
/// both carry one that came from somewhere else.
@external(erlang, "kazoo_gleam_call_ffi", "is_call")
pub fn is_call(call: Call) -> Bool

@external(erlang, "kazoo_gleam_call_ffi", "from_json")
fn ffi_from_json(json: String) -> Call

@external(erlang, "kazoo_gleam_call_ffi", "to_map")
fn ffi_to_map(call: Call) -> Dynamic

// ---------------------------------------------------------------------------
// Accessors
//
// Every one of these answers `None` where Kazoo answers `undefined` or an
// empty string, so a caller cannot mistake "never set" for "set to nothing".
// ---------------------------------------------------------------------------

pub fn call_id(call: Call) -> Option(String) {
  read(call, "call_id")
}

pub fn other_leg_call_id(call: Call) -> Option(String) {
  read(call, "other_leg_call_id")
}

pub fn account_id(call: Call) -> Option(String) {
  read(call, "account_id")
}

pub fn account_db(call: Call) -> Option(String) {
  read(call, "account_db")
}

pub fn account_realm(call: Call) -> Option(String) {
  read(call, "account_realm")
}

pub fn owner_id(call: Call) -> Option(String) {
  read(call, "owner_id")
}

pub fn authorizing_id(call: Call) -> Option(String) {
  read(call, "authorizing_id")
}

pub fn authorizing_type(call: Call) -> Option(String) {
  read(call, "authorizing_type")
}

pub fn fetch_id(call: Call) -> Option(String) {
  read(call, "fetch_id")
}

/// The queue commands for this channel are published to. Without it nothing
/// can be asked of the channel at all.
pub fn control_queue(call: Call) -> Option(String) {
  read(call, "control_queue")
}

/// The queue the channel's events come back to.
pub fn controller_queue(call: Call) -> Option(String) {
  read(call, "controller_queue")
}

pub fn caller_id_name(call: Call) -> Option(String) {
  read(call, "caller_id_name")
}

pub fn caller_id_number(call: Call) -> Option(String) {
  read(call, "caller_id_number")
}

pub fn callee_id_name(call: Call) -> Option(String) {
  read(call, "callee_id_name")
}

pub fn callee_id_number(call: Call) -> Option(String) {
  read(call, "callee_id_number")
}

pub fn request(call: Call) -> Option(String) {
  read(call, "request")
}

pub fn request_user(call: Call) -> Option(String) {
  read(call, "request_user")
}

pub fn request_realm(call: Call) -> Option(String) {
  read(call, "request_realm")
}

pub fn from(call: Call) -> Option(String) {
  read(call, "from")
}

pub fn from_user(call: Call) -> Option(String) {
  read(call, "from_user")
}

pub fn from_realm(call: Call) -> Option(String) {
  read(call, "from_realm")
}

pub fn to(call: Call) -> Option(String) {
  read(call, "to")
}

pub fn to_user(call: Call) -> Option(String) {
  read(call, "to_user")
}

pub fn to_realm(call: Call) -> Option(String) {
  read(call, "to_realm")
}

/// Where the call came from when it did not come from a device on this
/// account: `onnet` or `offnet`.
pub fn inception(call: Call) -> Option(String) {
  read(call, "inception")
}

pub fn language(call: Call) -> Option(String) {
  read(call, "language")
}

/// `inbound` or `outbound`, from the switch's point of view.
pub fn direction(call: Call) -> Option(String) {
  read(call, "direction")
}

/// The media server the channel is on, which is what tells two calls apart
/// when the cluster has more than one.
pub fn switch_nodename(call: Call) -> Option(String) {
  read(call, "switch_nodename")
}

pub fn resource_type(call: Call) -> Option(String) {
  read(call, "resource_type")
}

fn read(call: Call, field: String) -> Option(String) {
  option.from_result(ffi_get(call, field))
}

@external(erlang, "kazoo_gleam_call_ffi", "get")
fn ffi_get(call: Call, field: String) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_call_ffi", "set_control_queue")
pub fn set_control_queue(call: Call, queue: String) -> Call

@external(erlang, "kazoo_gleam_call_ffi", "set_controller_queue")
pub fn set_controller_queue(call: Call, queue: String) -> Call

// ---------------------------------------------------------------------------
// Channel variables and the key-value store
// ---------------------------------------------------------------------------

/// One custom channel variable as it stands on the call record.
pub fn custom_channel_var(call: Call, key: String) -> Option(Value) {
  case ffi_custom_channel_var(call, key) {
    Ok(value) -> Some(doc.from_dynamic(value))
    Error(Nil) -> None
  }
}

pub fn custom_channel_vars(call: Call) -> Value {
  doc.from_dynamic(ffi_custom_channel_vars(call))
}

/// Set channel variables on the call record, and on the channel.
///
/// Both, and not only the record: `kapps_call` sends the `set` command for
/// every variable whose value this changes, so a caller that wants the CDR
/// and the other nodes to see them has nothing more to do, and one that
/// calls `set_channel_vars` as well writes them twice.
pub fn set_custom_channel_vars(
  call: Call,
  vars: List(#(String, Value)),
) -> Call {
  ffi_set_custom_channel_vars(call, doc.to_string(doc.object(vars)))
}

/// Put a value in the call's key-value store, which travels with the call
/// and never reaches the channel.
pub fn kvs_store(call: Call, key: String, value: Value) -> Call {
  ffi_kvs_store(call, key, doc.to_string(value))
}

pub fn kvs_fetch(call: Call, key: String) -> Option(Value) {
  case ffi_kvs_fetch(call, key) {
    Ok(value) -> Some(doc.from_dynamic(value))
    Error(Nil) -> None
  }
}

/// What the callflow's number pattern captured: the `101` of `*22101`
/// dialled against `^\*22([0-9]*)$`. An empty capture, and a callflow
/// reached by an exact number, are both `None`.
pub fn capture_group(call: Call) -> Option(String) {
  case ffi_capture_group(call) {
    Ok(captured) -> Some(captured)
    Error(Nil) -> None
  }
}

@external(erlang, "kazoo_gleam_call_ffi", "capture_group")
fn ffi_capture_group(call: Call) -> Result(String, Nil)

@external(erlang, "kazoo_gleam_call_ffi", "custom_channel_var")
fn ffi_custom_channel_var(call: Call, key: String) -> Result(Dynamic, Nil)

@external(erlang, "kazoo_gleam_call_ffi", "custom_channel_vars")
fn ffi_custom_channel_vars(call: Call) -> Dynamic

@external(erlang, "kazoo_gleam_call_ffi", "set_custom_channel_vars")
fn ffi_set_custom_channel_vars(call: Call, json: String) -> Call

@external(erlang, "kazoo_gleam_call_ffi", "kvs_store")
fn ffi_kvs_store(call: Call, key: String, json: String) -> Call

@external(erlang, "kazoo_gleam_call_ffi", "kvs_fetch")
fn ffi_kvs_fetch(call: Call, key: String) -> Result(Dynamic, Nil)

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Answer the channel, on the end of its command queue.
@external(erlang, "kazoo_gleam_call_ffi", "answer")
pub fn answer(call: Call) -> Nil

/// Answer the channel now, ahead of its command queue rather than on the end
/// of it.
///
/// `Insert-At: now`, which `ecallmgr_call_control` runs as it arrives instead
/// of queueing it. That matters wherever an answer is followed by anything
/// that interrupts: `hold` carries `Insert-At: flush`, and a flush replaces
/// the whole command queue with itself, so an answer still waiting in that
/// queue is thrown away -- and the caller hears the hold music as early media
/// on a channel that was never answered.
///
/// It is still only the command going out. `CHANNEL_ANSWER`, or the
/// execute-complete for `answer`, is the switch saying it happened.
@external(erlang, "kazoo_gleam_call_ffi", "answer_now")
pub fn answer_now(call: Call) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "hangup")
pub fn hangup(call: Call) -> Nil

/// End whatever bridge this channel is in, or is ringing for, and keep the
/// channel: the other legs go, this one stays and is parked.
///
/// `hangup` with `Other-Leg-Only` and `Insert-At: now`, which `ecallmgr`
/// runs as `uuid_park` on this channel as it arrives. A bridge that is still
/// ringing sees its own channel stop being ready and gives up with
/// `ORIGINATOR_CANCEL`, cancelling every leg it rang; `continue_on_fail` and
/// FreeSWITCH's own rule that a cancel is always a reason to continue keep
/// the channel up. This is the one command that stops a ring from the
/// ringing channel's side: a `flush` only breaks what the channel is
/// playing, and the switch's originate does not look at that.
@external(erlang, "kazoo_gleam_call_ffi", "unbridge")
pub fn unbridge(call: Call) -> Nil

/// Put the channel on hold, playing `media` while it is there. `None` plays
/// the account's hold music.
///
/// Hold interrupts: the switch is told to stop whatever the channel is doing
/// and throw away whatever is queued behind it. So hold is issued *after*
/// the greeting or the announcement has finished, never straight behind it,
/// or the thing behind it is what gets cut off. `flush` is the same
/// interruption with nothing to follow it.
pub fn hold(call: Call, media: Option(String)) -> Nil {
  ffi_hold(call, option.unwrap(media, ""))
}

/// Put the channel on hold once whatever it is doing has finished, behind
/// whatever is already queued. The same hold as `hold`, without the
/// interruption.
///
/// `Insert-At: tail`. This is the hold for a process that must never cut
/// into something another process started on the channel: queued behind a
/// ringing bridge it waits, and runs only if the bridge comes to nothing --
/// which is exactly when the caller needs it back. Queued behind nothing it
/// runs at once, as `hold` would have.
pub fn hold_queued(call: Call, media: Option(String)) -> Nil {
  ffi_hold_queued(call, option.unwrap(media, ""))
}

/// Stop whatever the channel is doing and throw away whatever is queued
/// behind it.
///
/// This is how hold music is ended: a `play` or an `audio_macro` goes on the
/// end of the channel's queue, and the queue never advances past hold, which
/// runs until something interrupts it.
@external(erlang, "kazoo_gleam_call_ffi", "flush")
pub fn flush(call: Call) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "park")
pub fn park(call: Call) -> Nil

/// Make the switch run its dialplan for this channel again, from the top.
///
/// FreeSWITCH's `execute_extension`, which is the one command that produces a
/// fresh route request for a channel that is already up. That request goes
/// out on the bus like any other and whichever node is alive to answer it
/// runs the callflow, so it is how an application recovers a caller whose
/// callflow process died with its node: the channel never moved, and the
/// node that owns what happens next is chosen again.
///
/// `extension` is what the dialplan is asked for, which for a re-run is the
/// number the caller originally dialled -- `request_user`.
@external(erlang, "kazoo_gleam_call_ffi", "execute_extension")
pub fn execute_extension(call: Call, extension: String) -> Nil

/// Play one media file, by id or by a path `media_path` resolved.
@external(erlang, "kazoo_gleam_call_ffi", "play")
pub fn play(call: Call, media: String) -> Nil

/// Play a system prompt in the call's own language.
///
/// This queues the prompt and returns; it does not wait for the caller to
/// hear it. An action whose next move ends the callflow -- `callflow.stop`
/// hangs the channel up -- has to use `prompt_and_wait` instead, or the
/// channel goes away while the prompt is still playing.
@external(erlang, "kazoo_gleam_call_ffi", "prompt")
pub fn prompt(call: Call, prompt: String) -> Nil

/// Why a prompt ended other than by being played to the end.
pub type PlayError {
  /// The channel went away first.
  PlayHungup
  /// The switch never said the prompt had finished: no channel, or a
  /// command that could not be sent.
  PlayFailed
}

/// Play a system prompt and wait for the switch to say it has finished.
///
/// The same command as `prompt`, followed by the wait for its `noop`. This
/// is what the last thing an action says has to be, because the caller hears
/// a prompt only for as long as the channel outlives it.
///
/// The channel does not have to be answered: an unanswered one plays it as
/// early media. It does have to still be there, which is what `PlayHungup`
/// says it was not -- and an action that already knows the caller has gone
/// should not call this at all, but end instead. The wait is bounded at a
/// minute, because a channel whose destruction this process has already been
/// told about will never announce itself again.
pub fn prompt_and_wait(call: Call, prompt: String) -> Result(Nil, PlayError) {
  case ffi_prompt_and_wait(call, prompt) {
    Ok(_) -> Ok(Nil)
    Error("hungup") -> Error(PlayHungup)
    Error(_) -> Error(PlayFailed)
  }
}

@external(erlang, "kazoo_gleam_call_ffi", "prompt_and_wait")
fn ffi_prompt_and_wait(call: Call, prompt: String) -> Result(Nil, String)

/// Say a value the switch can pronounce: `say(call, "3", "number",
/// "pronounced", "en-us")`. `say_type` is Kazoo's `number`, `items`,
/// `currency`, `name_spelled` and the rest.
@external(erlang, "kazoo_gleam_call_ffi", "say")
pub fn say(
  call: Call,
  text: String,
  say_type: String,
  method: String,
  language: String,
) -> Nil

/// One item of an audio macro.
pub type MacroItem {
  /// A media file.
  MacroPlay(media: String)
  /// A system prompt, in the call's language.
  MacroPrompt(name: String)
  /// A spoken value, as `say` takes it.
  MacroSay(text: String, say_type: String, method: String, language: String)
  /// Text through the account's text-to-speech engine.
  MacroTts(text: String)
  /// Tones, each of which is a `tone` object as `kapi_dialplan` describes
  /// it: `Frequencies`, `Duration-ON`, `Duration-OFF`.
  MacroTones(tones: List(Value))
}

/// Play a sequence as one queued command, so the switch runs it without a
/// round trip between items. This is how a position announcement plays a
/// prompt, then a number, then another prompt.
///
/// The switch answers with one `CHANNEL_EXECUTE_COMPLETE` for `noop` when
/// the whole sequence has finished, which is what tells a process watching
/// the call's events that it may put the caller back on hold. `play` ends
/// the same way.
pub fn audio_macro(call: Call, items: List(MacroItem)) -> Nil {
  ffi_audio_macro(
    call,
    doc.to_string(doc.List(list.map(items, macro_to_value))),
  )
}

/// The same sequence, played in place of whatever the channel is doing --
/// unless that is a bridge.
///
/// `Insert-At: interrupt`. A caller on hold is on `kz_endless_playback`,
/// which never finishes, so a sequence queued behind it with `audio_macro`
/// is never played. This stops the hold and throws away whatever was queued,
/// as `hold` does; but where a bridge is running the sequence is queued
/// behind it instead, because a command executed on top of a bridge is run
/// nested inside it and plays on into the answered call. So it is safe to
/// send to a caller whose agents may be ringing from this same channel: it
/// plays after the ring comes to nothing, or never, if the ring is answered.
pub fn audio_macro_interrupting(call: Call, items: List(MacroItem)) -> Nil {
  ffi_audio_macro_interrupting(
    call,
    doc.to_string(doc.List(list.map(items, macro_to_value))),
  )
}

/// A macro item as the object the Erlang side turns into Kazoo's own tuple.
/// Exposed because it is what the tests check.
pub fn macro_to_value(item: MacroItem) -> Value {
  case item {
    MacroPlay(media) ->
      doc.object([
        #("type", doc.String("play")),
        #("media", doc.String(media)),
      ])
    MacroPrompt(name) ->
      doc.object([#("type", doc.String("prompt")), #("name", doc.String(name))])
    MacroSay(text, say_type, method, language) ->
      doc.object([
        #("type", doc.String("say")),
        #("text", doc.String(text)),
        #("say_type", doc.String(say_type)),
        #("method", doc.String(method)),
        #("language", doc.String(language)),
      ])
    MacroTts(text) ->
      doc.object([#("type", doc.String("tts")), #("text", doc.String(text))])
    MacroTones(tones) ->
      doc.object([#("type", doc.String("tones")), #("tones", doc.List(tones))])
  }
}

/// How several endpoints are rung.
pub type Strategy {
  /// All of them at once, first to answer wins.
  Simultaneous
  /// One after another, each for the whole timeout.
  Single
}

fn strategy_to_string(strategy: Strategy) -> String {
  case strategy {
    Simultaneous -> "simultaneous"
    Single -> "single"
  }
}

/// Ring `endpoints` from this channel. The command goes to this call's
/// control queue, so the new leg originates on this channel's media server.
///
/// `endpoints` are what `kazoo/endpoints` built. `timeout_s` is how long the
/// switch rings before giving up.
pub fn bridge(
  call: Call,
  endpoints: List(Value),
  timeout_s: Int,
  strategy: Strategy,
  ignore_early_media: Bool,
  ringback: Option(String),
) -> Nil {
  ffi_bridge(
    call,
    doc.to_string(doc.List(endpoints)),
    timeout_s,
    strategy_to_string(strategy),
    ignore_early_media,
    option.unwrap(ringback, ""),
  )
}

/// What the caller hears while the endpoints ring.
pub type Ringback {
  /// The switch's default ringback tone.
  Tone
  /// The channel's own hold music: what `hold` with no media plays.
  HoldMusic
  /// A media file or stream, as `hold` takes it.
  Music(String)
}

fn ringback_to_string(ringback: Ringback) -> String {
  case ringback {
    Tone -> ""
    // The switch's variable, which `hold` plays as `kz_endless_playback
    // ${hold_music}`; passed through as it is, not as a media path.
    HoldMusic -> "${hold_music}"
    Music(media) -> media
  }
}

/// Ring `endpoints` from this channel, interrupting whatever the channel is
/// doing and throwing away whatever was queued behind it, with `ringback`
/// played to the caller for as long as the phones ring.
///
/// `Insert-At: flush`. `bridge` goes on the end of the channel's command
/// queue, which never advances past a hold; this stops the hold and rings at
/// once, and is the command in the queue while it rings, so that a hold
/// queued behind it by whoever was holding the caller waits for the ring to
/// come to nothing. Early media from the phones is ignored in favour of the
/// ringback, so a caller on hold music stays on it.
///
/// `Error` is the command not going out at all -- the call has no control
/// queue to send it to, no broker connection is up, it did not validate,
/// or it could not be published -- which is the one thing a caller can know
/// without the switch's events. `Ok` says only that it was sent: a publish
/// the broker drops once it has it still looks sent, and only the switch's
/// silence tells.
pub fn bridge_interrupting(
  call: Call,
  endpoints: List(Value),
  timeout_s: Int,
  strategy: Strategy,
  ringback: Ringback,
) -> Result(Nil, String) {
  ffi_bridge_interrupting(
    call,
    doc.to_string(doc.List(endpoints)),
    timeout_s,
    strategy_to_string(strategy),
    ringback_to_string(ringback),
  )
}

/// What became of a bridge.
pub type BridgeResult {
  /// The legs are bridged; the event says which endpoint answered.
  Bridged(event: Value)
  /// No answer, busy, rejected, or an execution error. Read
  /// `disposition` and `hangup_cause` from the event.
  BridgeFailed(event: Value)
  /// Nothing came back in time. The channel may still be ringing.
  BridgeTimeout
}

/// Wait for the bridge to succeed, fail or time out. Only the process that
/// receives the call's events can call this.
pub fn wait_for_bridge(call: Call, timeout_ms: Int) -> BridgeResult {
  case ffi_wait_for_bridge(call, timeout_ms) {
    #("bridged", event) -> Bridged(doc.from_dynamic(event))
    #("failed", event) -> BridgeFailed(doc.from_dynamic(event))
    #(_, _) -> BridgeTimeout
  }
}

/// The switch's own word for how a bridge ended: `ANSWER`, `NO_ANSWER`,
/// `BUSY`, `CALL_REJECTED`.
pub fn disposition(event: Value) -> Option(String) {
  case doc.get_string(event, ["Disposition"]) {
    Ok(text) -> Some(text)
    Error(Nil) -> None
  }
}

pub fn hangup_cause(event: Value) -> Option(String) {
  case doc.get_string(event, ["Hangup-Cause"]) {
    Ok(text) -> Some(text)
    Error(Nil) -> None
  }
}

/// Start or stop recording.
///
/// This is the switch command and nothing more: it names no recorder, so no
/// `media_mgr` stores what it records. A recording meant to be kept is
/// `start_recording`.
pub type RecordAction {
  RecordStart
  RecordStop
}

/// What the recording is called and how long it may run. `None` on either
/// leaves Kazoo's own default in place.
pub type RecordOptions {
  RecordOptions(media_name: Option(String), time_limit_s: Option(Int))
}

pub fn record_options() -> RecordOptions {
  RecordOptions(media_name: None, time_limit_s: None)
}

pub fn record_call(
  call: Call,
  action: RecordAction,
  options: RecordOptions,
) -> Nil {
  let action = case action {
    RecordStart -> "start"
    RecordStop -> "stop"
  }
  ffi_record_call(
    call,
    action,
    option.unwrap(options.media_name, ""),
    option.unwrap(options.time_limit_s, 0),
  )
}

/// A recording made and kept the way Kazoo keeps its own.
///
/// The command is the one `kapps_call_recording` builds: it names
/// `kz_media_recording` as the recorder -- when the account's storage plan
/// or the system says recordings are stored -- and carries `settings` on
/// the switch's channel. The switch stops it at hangup, and whichever
/// `media_mgr` takes the `RECORD_STOP` off the shared `recordings` queue
/// writes the `call_recording` document into the account's modb and stores
/// the file. Nothing on the node that started it has to be there when it
/// ends.
pub type Recording {
  Recording(
    /// The file's name without its extension, which the format adds.
    name: String,
    /// The `call_recording` settings `kapps_call_recording` reads:
    /// `format`, `time_limit`, `url`, `origin`, `recording_vars` and the
    /// rest. What is missing is the system's default.
    settings: Value,
  )
}

/// Start `recording` on the call's own leg, ahead of anything queued on the
/// channel. A running bridge is what it usually lands on, and a command
/// queued behind one would wait for the call to end.
pub fn start_recording(call: Call, recording: Recording) -> Nil {
  ffi_start_recording(call, recording.name, doc.to_string(recording.settings))
}

/// Write channel and application variables on the channel itself, where the
/// CDR and every other node can see them. `set_custom_channel_vars` is the
/// one that only changes the record this process holds.
pub fn set_channel_vars(
  call: Call,
  ccvs: List(#(String, Value)),
  cavs: List(#(String, Value)),
) -> Nil {
  ffi_set_channel_vars(
    call,
    doc.to_string(doc.object(ccvs)),
    doc.to_string(doc.object(cavs)),
  )
}

/// Nothing arrived in time.
pub type Timeout {
  Timeout
}

/// The next call event delivered to this process. A callflow action's own
/// process receives the call's events, so this is how it sees DTMF, a
/// destroy, or a message another node sent it.
pub fn receive_event(timeout_ms: Int) -> Result(Value, Timeout) {
  case ffi_receive_event(timeout_ms) {
    Ok(event) -> Ok(doc.from_dynamic(event))
    Error(Timeout) -> Error(Timeout)
  }
}

/// Hand an event to another process in the shape that process's own
/// `receive_event` expects.
pub fn relay_event(to pid: Pid, event event: Value) -> Nil {
  ffi_relay_event(pid, doc.to_string(event))
}

/// Wait for the channel to go away.
pub fn wait_for_hangup(timeout_ms: Int) -> Result(Nil, Timeout) {
  ffi_wait_for_hangup(timeout_ms)
}

/// Why there was no digit.
pub type DtmfError {
  /// The channel was destroyed while waiting.
  Hungup
  /// Nothing was pressed in time.
  DtmfTimeout
}

/// Wait for one DTMF digit.
pub fn wait_for_dtmf(timeout_ms: Int) -> Result(String, DtmfError) {
  case ffi_wait_for_dtmf(timeout_ms) {
    Ok(digit) -> Ok(digit)
    Error("hungup") -> Error(Hungup)
    Error(_) -> Error(DtmfTimeout)
  }
}

/// Collect what is pressed, up to `max_digits`, until `timeout_ms` passes
/// with nothing new. An empty string is nobody pressing anything, which is
/// an answer and not an error.
pub fn collect_digits(
  call: Call,
  max_digits: Int,
  timeout_ms: Int,
) -> Result(String, DtmfError) {
  ffi_collect_digits(call, max_digits, timeout_ms) |> digits
}

/// Play a system prompt and collect the digits pressed after it, giving the
/// caller `tries` attempts and playing `invalid` when the last one is still
/// wrong. This is an id-and-PIN exchange in one command, which is what
/// `hotdesk` and the agent feature codes ask for.
pub fn prompt_and_collect_digits(
  call: Call,
  prompt prompt: String,
  max_digits max_digits: Int,
  tries tries: Int,
  timeout_ms timeout_ms: Int,
  invalid invalid: Option(String),
) -> Result(String, DtmfError) {
  ffi_prompt_and_collect_digits(
    call,
    prompt,
    max_digits,
    tries,
    timeout_ms,
    option.unwrap(invalid, ""),
  )
  |> digits
}

fn digits(answer: Result(String, String)) -> Result(String, DtmfError) {
  case answer {
    Ok(digits) -> Ok(digits)
    Error("hungup") -> Error(Hungup)
    Error(_) -> Error(DtmfTimeout)
  }
}

@external(erlang, "kazoo_gleam_call_ffi", "collect_digits")
fn ffi_collect_digits(
  call: Call,
  max_digits: Int,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "kazoo_gleam_call_ffi", "prompt_and_collect_digits")
fn ffi_prompt_and_collect_digits(
  call: Call,
  prompt: String,
  max_digits: Int,
  tries: Int,
  timeout_ms: Int,
  invalid: String,
) -> Result(String, String)

@external(erlang, "kazoo_gleam_call_ffi", "hold")
fn ffi_hold(call: Call, media: String) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "hold_queued")
fn ffi_hold_queued(call: Call, media: String) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "audio_macro")
fn ffi_audio_macro(call: Call, json: String) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "audio_macro_interrupting")
fn ffi_audio_macro_interrupting(call: Call, json: String) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "bridge")
fn ffi_bridge(
  call: Call,
  endpoints_json: String,
  timeout_s: Int,
  strategy: String,
  ignore_early_media: Bool,
  ringback: String,
) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "bridge_interrupting")
fn ffi_bridge_interrupting(
  call: Call,
  endpoints_json: String,
  timeout_s: Int,
  strategy: String,
  ringback: String,
) -> Result(Nil, String)

@external(erlang, "kazoo_gleam_call_ffi", "wait_for_bridge")
fn ffi_wait_for_bridge(call: Call, timeout_ms: Int) -> #(String, Dynamic)

@external(erlang, "kazoo_gleam_call_ffi", "record_call")
fn ffi_record_call(
  call: Call,
  action: String,
  media_name: String,
  time_limit_s: Int,
) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "start_recording")
fn ffi_start_recording(call: Call, name: String, settings: String) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "set_channel_vars")
fn ffi_set_channel_vars(call: Call, ccvs: String, cavs: String) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "receive_event")
fn ffi_receive_event(timeout_ms: Int) -> Result(Dynamic, Timeout)

@external(erlang, "kazoo_gleam_call_ffi", "relay_event")
fn ffi_relay_event(pid: Pid, json: String) -> Nil

@external(erlang, "kazoo_gleam_call_ffi", "wait_for_hangup")
fn ffi_wait_for_hangup(timeout_ms: Int) -> Result(Nil, Timeout)

@external(erlang, "kazoo_gleam_call_ffi", "wait_for_dtmf")
fn ffi_wait_for_dtmf(timeout_ms: Int) -> Result(String, String)

// ---------------------------------------------------------------------------
// Media
// ---------------------------------------------------------------------------

/// A media name as a path the switch can play, resolved against an account:
/// a media id becomes the URL the switch fetches it from, and a name Kazoo
/// does not know is left alone.
@external(erlang, "kazoo_gleam_call_ffi", "media_path")
pub fn media_path(media: String, account_id: String) -> String

/// The media a system prompt resolves to. `language` empty takes the call's
/// own.
pub fn prompt_path(
  call: Call,
  prompt: String,
  language: Option(String),
) -> Option(String) {
  option.from_result(ffi_prompt_path(call, prompt, option.unwrap(language, "")))
}

@external(erlang, "kazoo_gleam_call_ffi", "prompt_path")
fn ffi_prompt_path(
  call: Call,
  prompt: String,
  language: String,
) -> Result(String, Nil)

/// The channel variables of an event as a dictionary, which is where the
/// `Queue-ID` and `Agent-ID` this application sets come back.
pub fn event_channel_vars(event: Value) -> Value {
  case doc.get(event, ["Custom-Channel-Vars"]) {
    Ok(vars) -> vars
    Error(Nil) -> doc.Object(dict.new())
  }
}
