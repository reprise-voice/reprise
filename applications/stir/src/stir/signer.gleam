//// The one process per node that holds decrypted keys and signs.
////
//// A named actor. It opens a key under the node's KEK the first time that
//// key is asked for, keeps it in its own state (not in an ETS table, not in
//// the caller), and answers signatures. An opened key is held for five
//// minutes and then read from the store again; on that re-read a key that
//// is no longer the active one of its scope is dropped rather than held
//// for another five, so a key retired, superseded, re-sealed or deleted
//// elsewhere in the cluster leaves this node's memory on its own.
//// `refresh` drops everything at once; the monitor calls it after an
//// activation. Without a KEK the actor runs and every `sign` answers
//// `NoVault`.
////
//// **Availability.** Signing is on the call path, so nothing here may
//// stop signing because the datastore is having a bad minute:
////
////   - A re-read that fails does not take the key away, ever. A key this
////     node has open keeps signing for as long as the datastore is
////     unreachable: an outage that stopped signing would take the
////     `Identity` header off every outbound call, which is worse than
////     signing with a key that may since have been retired. When the
////     store answers again the normal re-read applies and a key that is
////     no longer active is dropped. Only a key this node has never
////     opened is unavailable during an outage.
////   - A key the store says is *gone* (`UnknownKey`) is dropped at once:
////     that is an answer about the key, not a failure to reach it.
////   - A kid whose read failed is not read again for five seconds, so a
////     store that is refusing everything costs one attempt per kid per
////     five seconds rather than one per signature. The first failure per
////     key is an error line, then one an hour while it lasts, and an
////     alert says the node is signing from memory.
////   - Every store read happens in a process of its own that the actor
////     waits at most a second for, so one hung read blocks the signer
////     (and every other caller) for a second, not for the caller's whole
////     timeout.
////   - A blob the current KEK cannot open is tried under `STIR_KEK_NEXT`,
////     read at start and again on every re-read, so a rotation that has
////     re-sealed the store is zero-downtime on a node that has the next
////     value in its environment.
////
//// Nothing here ever waits on the actor for longer than `call_timeout_ms`,
//// and a caller is never taken down with it: the call is a send that
//// cannot raise (`stir_ops_ffi:send_named`, because `gleam_erlang` asserts
//// that a named subject resolves before it sends) and a receive with a
//// timeout, so a signer that is gone or wedged is `Unavailable` or
//// `Timeout` to the call path rather than an exit.
////
//// The vault is read from the environment when the actor starts and again
//// on every `refresh`; what is logged is which variable was missing or
//// malformed, never a value. `stats` is what `sup stir_maintenance status`
//// prints: counts, kids and times, never bytes.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import kazoo/cache
import kazoo/doc
import kazoo/kazoo.{type Kazoo}
import kazoo/util
import stir/alert
import stir/jws
import stir/key.{type Key}
import stir/keys
import stir/secret.{type Secret}
import stir/system
import stir/vault.{type Vault}

pub opaque type Message {
  Sign(
    kid: String,
    signing_input: String,
    reply: Subject(Result(BitArray, Error)),
  )
  Refresh(reply: Subject(Nil))
  Loaded(reply: Subject(List(String)))
  Statistics(reply: Subject(Stats))
}

pub type Error {
  NoVault
  UnknownKey
  Unsealable
  /// The key's sealed private key is not a blob at all; no vault opens it.
  Damaged
  Crypto(String)
  /// The actor is not running on this node.
  Unavailable
  /// It is running but did not answer in time.
  Timeout
}

/// What this node's signer has been doing, for `sup stir_maintenance
/// status`: which key-encryption key it holds, what it has signed and
/// refused, and when each kid was last opened or last failed to open.
/// Times are unix seconds; nothing here is key material.
pub type Stats {
  Stats(
    /// The id of the key-encryption key the signer holds.
    vault: Option(String),
    /// The id of `STIR_KEK_NEXT`, while a rotation is under way.
    next_vault: Option(String),
    /// The kids open on this node right now.
    opened: List(String),
    /// Signatures answered.
    signed: Int,
    /// Signatures refused, counted by the name of the error, by name.
    refused: List(#(String, Int)),
    /// When each kid was last read from the store, by kid.
    last_open: List(#(String, Int)),
    /// When each kid last could not be read, and why, by kid.
    last_failure: List(#(String, Failure)),
    /// The kids being signed from memory because the store stopped
    /// answering for them, and the second it first did.
    stale: List(#(String, Int)),
  )
}

pub type Failure {
  Failure(at: Int, why: String)
}

type State {
  State(
    kz: Kazoo,
    vault: Option(Vault),
    next: Option(Vault),
    opened: Dict(String, Opened),
    failed: Dict(String, Failed),
    signed: Int,
    refused: Dict(String, Int),
    last_open: Dict(String, Int),
    last_failure: Dict(String, Failure),
    /// When the store first stopped answering for a kid this node holds
    /// open, so the report can say how long it has been signing from
    /// memory.
    stale: Dict(String, Int),
    /// Failed signatures per kid inside the last five minutes, which is
    /// what turns a run of them into an alert.
    sign_failures: Dict(String, Window),
  )
}

/// A run of failed signatures for one kid: when it started and how many
/// there have been since.
type Window {
  Window(since: Int, count: Int)
}

/// A key this node has open, and the second (unix) it was read from the
/// store, which is what its time to live and its grace are measured from.
type Opened {
  Opened(private_key: Secret, at: Int)
}

/// A read of one kid that failed, and when: the negative cache.
type Failed {
  Failed(at: Int, error: Error)
}

/// How long a caller waits for a signature. Opening a key is one document
/// read; signing is well under a millisecond.
const call_timeout_ms = 5000

/// How long an opened key is used before it is read from the store
/// again, so that a retirement or a re-sealing elsewhere in the cluster
/// reaches this node without a `refresh`.
const opened_ttl_s = 300

/// How long a kid whose read failed is answered from the failure rather
/// than read again.
const negative_ttl_s = 5

/// How long the actor waits for one store read before it gives up on it.
const read_deadline_ms = 1000

/// How often a key that cannot be read says so again after the first
/// time, and how often a node with no key-encryption key says so.
const failure_log_interval_s = 3600

const no_vault_log_interval_s = 600

/// The throttle behind those two. Node-local, like every other cache.
const log_throttle = "stir_signer_log"

/// How many failed signatures for one kid inside `sign_failure_window_s`
/// are a condition an operator is told about rather than a bad minute.
const sign_failure_alert_count = 10

const sign_failure_window_s = 300

/// How often an alert about the same thing is raised.
const alert_interval_s = 3600

/// Where the count of starts lives, so that a signer that keeps crashing
/// is noticed: a crash takes the keys this node had open with it.
const restart_table = "stir_signer"

pub fn name() -> Name(Message) {
  util.name("stir_signer")
}

pub fn supervised(kz: Kazoo) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start(kz) })
  |> supervision.map_data(fn(_started) { Nil })
}

pub fn start(
  kz: Kazoo,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(call_timeout_ms, fn(self) {
    note_start(kz)
    actor.initialised(fresh(kz))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name())
  |> actor.start
}

/// The raw `R||S` signature of `signing_input` under key `kid`.
pub fn sign(kid: String, signing_input: String) -> Result(BitArray, Error) {
  case call(Sign(kid, signing_input, _)) {
    Ok(answer) -> answer
    Error(error) -> Error(error)
  }
}

/// One message to the signer and its answer. A signer that is not
/// running is `Unavailable` and one that does not answer within
/// `call_timeout_ms` is `Timeout`; neither takes the caller with it,
/// which matters because the caller is a call on its way out.
///
/// The send goes through the FFI rather than `process.send`: a send to a
/// named subject asserts that the name resolves, so a signer that died
/// between a `process.named` check and the send would raise in the
/// caller. Here nothing is checked and nothing raises.
fn call(build: fn(Subject(answer)) -> Message) -> Result(answer, Error) {
  let reply = process.new_subject()
  case send_named(name(), build(reply)) {
    False -> Error(Unavailable)
    True ->
      process.receive(reply, call_timeout_ms) |> result.replace_error(Timeout)
  }
}

/// A `jws.Signer` bound to one key, for `passport.build`.
pub fn for_key(kid: String) -> jws.Signer {
  fn(signing_input) {
    sign(kid, signing_input) |> result.map_error(describe_error)
  }
}

/// The same signature within `timeout_ms`, for the call path, where the
/// budget is the caller's (`stir/outbound.budget_ms`) and not the five
/// seconds a `sup` command can spare.
///
/// The call is made from a short-lived process of its own rather than
/// from the caller: a signer that answers after the deadline would
/// otherwise leave its reply in the caller's mailbox, and the caller is a
/// `stepswitch` process with a mailbox of its own to keep clean. The
/// proxy waits the same `timeout_ms` on the signer, the caller waits it
/// on the proxy, and a proxy that has not answered by then is killed,
/// which takes any late reply with it.
pub fn sign_within(
  kid: String,
  signing_input: String,
  timeout_ms: Int,
) -> Result(BitArray, Error) {
  let reply = process.new_subject()
  let proxy =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        call_within(Sign(kid, signing_input, _), timeout_ms) |> result.flatten,
      )
    })
  let watch = process.monitor(proxy)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
  let answer = case process.selector_receive(selector, timeout_ms) {
    Ok(Ok(answer)) -> answer
    // The proxy died without answering: nothing it could have been sent
    // is the caller's problem any more.
    Ok(Error(Nil)) -> Error(Unavailable)
    Error(Nil) -> {
      process.kill(proxy)
      Error(Timeout)
    }
  }
  process.demonitor_process(watch)
  let _ = process.receive(reply, 0)
  answer
}

/// A `jws.Signer` bound to one key that gives up after `timeout_ms`.
pub fn for_key_within(kid: String, timeout_ms: Int) -> jws.Signer {
  fn(signing_input) {
    sign_within(kid, signing_input, timeout_ms)
    |> result.map_error(describe_error)
  }
}

/// `call` with the deadline as an argument.
fn call_within(
  build: fn(Subject(answer)) -> Message,
  timeout_ms: Int,
) -> Result(answer, Error) {
  let reply = process.new_subject()
  case send_named(name(), build(reply)) {
    False -> Error(Unavailable)
    True -> process.receive(reply, timeout_ms) |> result.replace_error(Timeout)
  }
}

/// Forget every opened key; the next request reads the store again. The
/// vault is read from the environment again too, so a KEK set after the
/// node started is picked up.
pub fn refresh() -> Nil {
  case call(Refresh) {
    Ok(Nil) | Error(Unavailable) -> Nil
    Error(error) -> {
      system.log_error("the signer did not refresh: " <> describe_error(error))
      Nil
    }
  }
}

/// The kids currently opened on this node, for `status`.
pub fn loaded() -> List(String) {
  case call(Loaded) {
    Ok(kids) -> kids
    Error(_) -> []
  }
}

/// What this node's signer has done, for `status`.
pub fn stats() -> Result(Stats, Error) {
  call(Statistics)
}

/// What an `Error` means, for a `jws.SignerFailed` or a `sup` line.
pub fn describe_error(error: Error) -> String {
  case error {
    NoVault -> "this node has no key-encryption key"
    UnknownKey -> "no such key"
    Unsealable -> "the key is sealed under another key-encryption key"
    Damaged -> "the key's sealed private key is not a readable blob"
    Crypto(why) -> why
    Unavailable -> "the signer is not running on this node"
    Timeout -> "the signer did not answer in time"
  }
}

/// The name of an `Error`, for the statistics: one word per variant, so
/// that a count reads the same in every report.
pub fn error_name(error: Error) -> String {
  case error {
    NoVault -> "no_vault"
    UnknownKey -> "unknown_key"
    Unsealable -> "unsealable"
    Damaged -> "damaged"
    Crypto(_) -> "crypto"
    Unavailable -> "unavailable"
    Timeout -> "timeout"
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Sign(kid, signing_input, reply) -> {
      let #(state, answer) = sign_with(state, kid, signing_input)
      process.send(reply, answer)
      actor.continue(state)
    }
    Refresh(reply) -> {
      process.send(reply, Nil)
      let refreshed = fresh(state.kz)
      actor.continue(
        State(
          ..refreshed,
          signed: state.signed,
          refused: state.refused,
          last_open: state.last_open,
          last_failure: state.last_failure,
        ),
      )
    }
    Loaded(reply) -> {
      process.send(reply, dict.keys(state.opened))
      actor.continue(state)
    }
    Statistics(reply) -> {
      process.send(reply, statistics(state))
      actor.continue(state)
    }
  }
}

/// A state with no key open and the environment read again.
fn fresh(kz: Kazoo) -> State {
  State(
    kz:,
    vault: load_vault(),
    next: load_next_vault(),
    opened: dict.new(),
    failed: dict.new(),
    signed: 0,
    refused: dict.new(),
    last_open: dict.new(),
    last_failure: dict.new(),
    stale: dict.new(),
    sign_failures: dict.new(),
  )
}

fn statistics(state: State) -> Stats {
  Stats(
    vault: option.map(state.vault, vault.id),
    next_vault: option.map(state.next, vault.id),
    opened: dict.keys(state.opened) |> list.sort(string.compare),
    signed: state.signed,
    refused: dict.to_list(state.refused)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
    last_open: dict.to_list(state.last_open)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
    last_failure: dict.to_list(state.last_failure)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
    stale: dict.to_list(state.stale)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) }),
  )
}

fn sign_with(
  state: State,
  kid: String,
  signing_input: String,
) -> #(State, Result(BitArray, Error)) {
  let now = state.kz.now()
  case state.vault {
    None -> {
      no_vault(state, now)
      #(counted(state, Error(NoVault)), Error(NoVault))
    }
    Some(sealer) -> {
      let #(state, opened) = open(state, sealer, kid, now)
      let answer = case opened {
        Error(error) -> Error(error)
        Ok(private_key) ->
          secret.with(private_key, ecdsa_sign(_, signing_input))
          |> result.map_error(Crypto)
      }
      #(noted(counted(state, answer), kid, answer, now), answer)
    }
  }
}

/// A run of failed signatures for one kid is a key that is not signing
/// and calls that carry no `Identity` header, which is an alert and not
/// only a log line. A signature that works ends the run.
fn noted(
  state: State,
  kid: String,
  answer: Result(a, Error),
  now: Int,
) -> State {
  case answer {
    Ok(_) ->
      State(..state, sign_failures: dict.delete(state.sign_failures, kid))
    Error(error) -> {
      let window = case dict.get(state.sign_failures, kid) {
        Ok(run) if now - run.since < sign_failure_window_s ->
          Window(since: run.since, count: run.count + 1)
        _ -> Window(since: now, count: 1)
      }
      case window.count > sign_failure_alert_count {
        False -> Nil
        True ->
          alert_aside(state.kz, fn(kz) {
            alert.raise(
              kz,
              "sign-failures:" <> kid,
              "a signing key keeps failing",
              "key "
                <> kid
                <> " could not sign "
                <> int.to_string(window.count)
                <> " times in five minutes on "
                <> system.node_name()
                <> "; the last failure was: "
                <> describe_error(error)
                <> ". Calls that would have used it carry no Identity header.",
              metadata(kid, describe_error(error)),
              now,
              alert_interval_s,
            )
          })
      }
      State(
        ..state,
        sign_failures: dict.insert(state.sign_failures, kid, window),
      )
    }
  }
}

/// One more signature answered, or one more refusal of its kind.
fn counted(state: State, answer: Result(a, Error)) -> State {
  case answer {
    Ok(_) -> State(..state, signed: state.signed + 1)
    Error(error) ->
      State(
        ..state,
        refused: dict.upsert(state.refused, error_name(error), fn(count) {
          option.unwrap(count, 0) + 1
        }),
      )
  }
}

/// The key from the actor's state while what it holds is still fresh,
/// else from the store; and when the store cannot be read, the held copy
/// for as long as its grace lasts.
fn open(
  state: State,
  sealer: Vault,
  kid: String,
  now: Int,
) -> #(State, Result(Secret, Error)) {
  let held = dict.get(state.opened, kid) |> option.from_result
  case held {
    Some(fresh_enough) if now - fresh_enough.at < opened_ttl_s -> #(
      state,
      Ok(fresh_enough.private_key),
    )
    _ ->
      case recent_failure(state, kid, now) {
        Some(error) -> fall_back(state, kid, held, error)
        None -> read(state, sealer, kid, held, now)
      }
  }
}

/// The error of a read that failed less than `negative_ttl_s` ago, so
/// that a kid the store is refusing costs one read every five seconds
/// and not one per signature.
fn recent_failure(state: State, kid: String, now: Int) -> Option(Error) {
  case dict.get(state.failed, kid) {
    Ok(failed) if now - failed.at < negative_ttl_s -> Some(failed.error)
    _ -> None
  }
}

/// The key from the store, held for `opened_ttl_s`.
///
/// A read that is a re-read (the held copy went stale) asks what the key
/// is now: one that is no longer the active key of its scope is used for
/// this signature and then dropped, so a key retired, superseded or
/// re-sealed elsewhere in the cluster leaves this node's memory without
/// anyone having to tell it. That question is answered from the document
/// the read opened anyway, not from a read of its own.
fn read(
  state: State,
  sealer: Vault,
  kid: String,
  held: Option(Opened),
  now: Int,
) -> #(State, Result(Secret, Error)) {
  // A rotation may have re-sealed the store under `STIR_KEK_NEXT` while
  // this node was up, so the successor is read from the environment
  // again on every read rather than only at start.
  let state = State(..state, next: load_next_vault())
  case bounded_unseal(state.kz, sealer, state.next, kid) {
    Error(error) -> {
      let state =
        State(
          ..state,
          failed: dict.insert(state.failed, kid, Failed(at: now, error:)),
          last_failure: dict.insert(
            state.last_failure,
            kid,
            Failure(at: now, why: describe_error(error)),
          ),
        )
      let state = case held, error {
        Some(_), UnknownKey | None, _ -> state
        Some(_), _ ->
          State(..state, stale: case dict.get(state.stale, kid) {
            Ok(_) -> state.stale
            Error(Nil) -> dict.insert(state.stale, kid, now)
          })
      }
      read_failed(state, kid, held, error, now)
      fall_back(state, kid, held, error)
    }
    Ok(#(found, private_key, under)) -> {
      case dict.get(state.stale, kid) {
        Error(Nil) -> Nil
        Ok(since) ->
          system.log(
            "signer read key "
            <> kid
            <> " again after "
            <> int.to_string(now - since)
            <> "s of signing it from memory",
          )
      }
      // The next outage's first failure is logged at once rather than an
      // hour into it.
      cache.delete(log_throttle, "open:" <> kid)
      let state =
        State(
          ..state,
          failed: dict.delete(state.failed, kid),
          stale: dict.delete(state.stale, kid),
          last_open: dict.insert(state.last_open, kid, now),
        )
      let holding =
        State(
          ..state,
          opened: dict.insert(state.opened, kid, Opened(private_key:, at: now)),
        )
      case held, found.status {
        None, _ -> {
          system.log("signer opened key " <> kid <> " under " <> under)
          #(holding, Ok(private_key))
        }
        Some(_), key.Active -> #(holding, Ok(private_key))
        Some(_), other -> {
          system.log(
            "signer dropped key "
            <> kid
            <> " ("
            <> key.status_to_string(other)
            <> "): it is not the active key of its scope",
          )
          #(
            State(..state, opened: dict.delete(state.opened, kid)),
            Ok(private_key),
          )
        }
      }
    }
  }
}

/// What a signature gets when the store could not be read: the copy this
/// node holds, for as long as the store is away. There is no deadline on
/// that: a call signed by a key that may have been retired somewhere
/// else beats a call with no `Identity` header at all. A key the store
/// says is *gone* is a different matter and is let go of at once --
/// `UnknownKey` is an answer about the key, not a failure to reach it.
///
/// `at` stays at the read the held copy came from, so it is the negative
/// cache that paces the attempts to read it again: one every five
/// seconds, and the first that succeeds decides in the usual way whether
/// the key is still the active one of its scope.
fn fall_back(
  state: State,
  kid: String,
  held: Option(Opened),
  error: Error,
) -> #(State, Result(Secret, Error)) {
  case held, error {
    None, _ -> #(state, Error(error))
    Some(_), UnknownKey -> #(dropped(state, kid), Error(error))
    Some(from_memory), _ -> #(state, Ok(from_memory.private_key))
  }
}

fn dropped(state: State, kid: String) -> State {
  State(..state, opened: dict.delete(state.opened, kid))
}

/// One store read, in a process of its own, given a second.
///
/// `keys.unseal_with_key` is one datastore call, and the actor answers
/// nothing else while it runs. A datastore that accepts the call and then
/// says nothing would hold every signature on the node for as long as it
/// felt like; here it holds them for a second and the kid is answered
/// `Timeout` (and not read again for five seconds).
///
/// The reader is unlinked, so its death is not the signer's, and
/// monitored, so its death is noticed rather than waited out. Whatever it
/// may still have sent is taken out of the actor's mailbox before the
/// call returns.
fn bounded_unseal(
  kz: Kazoo,
  sealer: Vault,
  next: Option(Vault),
  kid: String,
) -> Result(#(Key, Secret, String), Error) {
  let reply = process.new_subject()
  let reader =
    process.spawn_unlinked(fn() {
      let answer = unseal_under(kz, sealer, next, kid)
      process.send(reply, answer)
      // After the answer, so that the alert's own datastore write is not
      // inside the signer's deadline. A key sealed under a
      // key-encryption key this node does not have signs nowhere here
      // until someone acts on it.
      case answer {
        Error(Unsealable) -> keys.alert_unsealable(kz, kid)
        Error(Damaged) -> keys.alert_damaged(kz, kid)
        _ -> Nil
      }
    })
  let watch = process.monitor(reader)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(watch, fn(_down) { Error(Nil) })
  let answer = case process.selector_receive(selector, read_deadline_ms) {
    // The reader answered; it finishes on its own time.
    Ok(Ok(read)) -> read
    // It died without answering.
    Ok(Error(Nil)) ->
      Error(Crypto("the key store read stopped before it answered"))
    // It is still going, and must not spend any more of the signer's
    // time: whatever it was waiting for, this signature is not waiting
    // for it.
    Error(Nil) -> {
      process.kill(reader)
      Error(Timeout)
    }
  }
  process.demonitor_process(watch)
  let _ = process.receive(reply, 0)
  answer
}

/// The key under this node's KEK, or under its successor when a rotation
/// has already re-sealed the store. Answers which one opened it.
fn unseal_under(
  kz: Kazoo,
  sealer: Vault,
  next: Option(Vault),
  kid: String,
) -> Result(#(Key, Secret, String), Error) {
  case keys.unseal_with_key(kz, sealer, kid) {
    Ok(#(found, private_key)) -> Ok(#(found, private_key, vault.id(sealer)))
    Error(keys.Unsealable) ->
      case next {
        None -> Error(Unsealable)
        Some(successor) ->
          case keys.unseal_with_key(kz, successor, kid) {
            Ok(#(found, private_key)) ->
              Ok(#(found, private_key, vault.id(successor)))
            Error(_) -> Error(Unsealable)
          }
      }
    Error(error) -> Error(store_error(error))
  }
}

/// A read that failed: an error line the first time and then once an
/// hour while it lasts, and -- when this node is answering from a key it
/// holds rather than refusing -- an alert saying it is signing from
/// memory, once an hour.
///
/// Signing from memory shows up nowhere else: every call still carries
/// an `Identity` header, and the only sign that the key store is away is
/// this.
fn read_failed(
  state: State,
  kid: String,
  held: Option(Opened),
  error: Error,
  now: Int,
) -> Nil {
  let from_memory = case held, error {
    None, _ | Some(_), UnknownKey -> False
    Some(_), _ -> True
  }
  case
    cache.first_in(log_throttle, "open:" <> kid, now, failure_log_interval_s)
  {
    False -> Nil
    True ->
      system.log_error(
        "signer could not open key "
        <> kid
        <> ": "
        <> describe_error(error)
        <> case from_memory {
          True ->
            "; it goes on signing with the copy it holds until the store answers again"
          False -> "; it cannot sign with that key on this node"
        },
      )
  }
  case from_memory {
    False -> Nil
    True ->
      alert_aside(state.kz, fn(kz) {
        alert.raise(
          kz,
          "signer-datastore",
          "signing from memory: datastore unreachable",
          system.node_name()
            <> " cannot read the key store ("
            <> describe_error(error)
            <> ") and is signing with the keys it already holds. Calls are"
            <> " still signed; a key retired or re-sealed elsewhere will not"
            <> " reach this node until the store answers again, and a key"
            <> " this node has never opened cannot sign here at all.",
          metadata(kid, describe_error(error)),
          now,
          alert_interval_s,
        )
      })
  }
}

/// A node asked to sign with no key-encryption key at all: an error line
/// once every ten minutes and an alert once an hour. It signs nothing
/// until an operator puts `STIR_KEK` in its environment, which is not
/// something to find out from a log.
fn no_vault(state: State, now: Int) -> Nil {
  case cache.first_in(log_throttle, "no_vault", now, no_vault_log_interval_s) {
    False -> Nil
    True -> {
      let why =
        "this node has no "
        <> system.kek_variable
        <> ": nothing can be signed here and outbound calls carry no Identity header"
      system.log_error("signer was asked to sign and " <> why)
      alert_aside(state.kz, fn(kz) {
        alert.raise(
          kz,
          "no-vault",
          "a node cannot sign",
          system.node_name() <> ": " <> why,
          metadata("", why),
          now,
          alert_interval_s,
        )
      })
    }
  }
}

/// How many times a signer has started on this node. The first start is
/// the node coming up; every one after it is a crash, and a crash takes
/// every key this node had open with it.
fn note_start(kz: Kazoo) -> Nil {
  let starts = { cache.get(restart_table, "starts") |> result.unwrap(0) } + 1
  cache.put(restart_table, "starts", starts)
  case starts > 1 {
    False -> Nil
    True -> {
      let _ =
        alert.raise(
          kz,
          "signer-restart",
          "the signer keeps restarting",
          "the signer on "
            <> system.node_name()
            <> " has started "
            <> int.to_string(starts)
            <> " times: it is crashing, and every crash drops the keys it held and delays the calls it was signing.",
          metadata("", "restart " <> int.to_string(starts)),
          kz.now(),
          alert_interval_s,
        )
      Nil
    }
  }
}

/// The metadata every alert from here carries.
fn metadata(kid: String, reason: String) -> doc.Value {
  doc.object([
    #("kid", case kid {
      "" -> doc.Null
      given -> doc.String(given)
    }),
    #("scope", doc.Null),
    #("reason", doc.String(reason)),
  ])
}

/// Raise an alert without making a call on its way out wait for a
/// datastore write. An alert is a notification; answering signatures is
/// the job.
fn alert_aside(kz: Kazoo, raise: fn(Kazoo) -> alert.Outcome) -> Nil {
  let _ = process.spawn_unlinked(fn() { raise(kz) })
  Nil
}

fn store_error(error: keys.Error) -> Error {
  case error {
    keys.NotFound | keys.Datastore(kazoo.NotFound) -> UnknownKey
    keys.NoVault -> NoVault
    keys.Unsealable -> Unsealable
    keys.Damaged -> Damaged
    keys.Conflict -> Crypto("datastore: conflict")
    keys.Datastore(other) ->
      Crypto("datastore: " <> kazoo.error_to_string(other))
    keys.CertificateMismatch(why) | keys.Crypto(why) -> Crypto(why)
    keys.InvalidTransition -> Crypto("invalid transition")
    keys.NoPrivateKey -> UnknownKey
    keys.ViewMissing -> Crypto("the key store's view is not registered")
  }
}

fn load_vault() -> Option(Vault) {
  case vault.load() {
    Ok(loaded) -> {
      system.log("signer holds key-encryption key " <> vault.id(loaded))
      Some(loaded)
    }
    Error(error) -> {
      system.log(
        "signer has no key-encryption key: " <> vault.describe_error(error),
      )
      None
    }
  }
}

/// The successor key-encryption key, when a rotation is under way. Not
/// having one is the normal state and says nothing.
fn load_next_vault() -> Option(Vault) {
  option.from_result(vault.load_next())
}

@external(erlang, "stir_ffi", "ecdsa_sign")
fn ecdsa_sign(
  private_key_pem: BitArray,
  message: String,
) -> Result(BitArray, String)

@external(erlang, "stir_ops_ffi", "send_named")
fn send_named(name: Name(Message), message: Message) -> Bool
