//// The periodic work: activate pending keys whose `not_before` has passed,
//// raise expiry alerts, check the active `x5u` answers, refresh the trust
//// material on its schedule, and delete retired keys past `not_after`.
////
//// A named actor that reschedules itself hourly, with `now` for `sup`.
//// Alerts go through `stir/alert`, which throttles them cluster-wide and
//// addresses each to the master account and, for a reseller's key, to
//// that account too.
////
//// The first pass runs a minute after the actor starts rather than at
//// once: the tree comes up before the datastore is known to be there, and
//// a pass that finds no keys because of that would be one more alert.
//// Every pass registers the views again for the same reason: a node that
//// started before CouchDB has no design document, and without it the key
//// store reads as empty for as long as the node runs.
////
//// **The hour is never lost.** The next pass is scheduled before this one
//// runs, and the pass itself runs in a process of its own that the actor
//// waits on with a timeout. A pass that crashes takes nothing with it --
//// the actor is not linked to it -- and a pass that hangs on a network
//// read is abandoned after `pass_timeout_ms`; either way an alert goes
//// out under `monitor-crash` and the next hour comes round on time. The
//// actor itself stays answering, which is what `sup monitor_now` and
//// `last_pass` need.
////
//// **The trust refresh has a leader.** Every node runs this pass, and
//// every node refreshing the same CA list every six hours is N times the
//// requests to the STI-PA for one document every node then reads from
//// CouchDB anyway. The node whose name sorts first among the nodes
//// running `stir` (`kazoo/nodes`) does it on the cadence. A dead leader
//// cannot starve the others: any node refreshes when the stored CRL is
//// inside `crl_margin_s` of its next update, or when there is no bundle
//// stored at all, and a node that cannot see the cluster at all (no
//// release around it) refreshes as though it were alone.

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/otp/supervision
import gleam/pair
import gleam/result
import gleam/string
import kazoo/cache
import kazoo/doc
import kazoo/ffi
import kazoo/kazoo.{type Kazoo}
import kazoo/modb
import kazoo/nodes
import kazoo/util
import stir/alert
import stir/carriers
import stir/db
import stir/http.{type Transport}
import stir/key.{type Key}
import stir/keys
import stir/numbers
import stir/settings.{type Settings}
import stir/signer
import stir/stipa
import stir/system
import stir/trust
import stir/vault
import stir/views
import stir/x5u

pub type Message {
  /// Run a pass now.
  Pass
  Stop(done: Subject(Nil))
}

/// What a line of a pass is: something that happened, or something an
/// operator has to act on. The caller logs the second at error level.
pub type Level {
  Info
  Failure
}

type State {
  State(self: Subject(Message), kz: Kazoo, transport: Transport)
}

pub const interval_ms = 3_600_000

/// How long after the start the first pass runs.
pub const first_pass_ms = 60_000

/// The longest a pass may take before the actor gives up on it. Long
/// enough that nothing healthy is ever abandoned (the fetches inside are
/// seconds each), short enough that a stuck pass is noticed the same day.
pub const pass_timeout_ms = 2_700_000

/// The budget for one fetch a pass makes.
const fetch_timeout_ms = 15_000

/// How long the self-check waits for every key's fetch together. They run
/// at once, so this is the slowest one and not the sum.
const self_check_wait_s = 20

/// How many times a pending key may fail to activate before it stops
/// counting as the successor that keeps an expiry alert quiet.
const failures_before_doubting = 2

pub fn name() -> Name(Message) {
  util.name("stir_monitor")
}

pub fn supervised(
  kz: Kazoo,
  transport: Transport,
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start(kz, transport) })
  |> supervision.map_data(fn(_started) { Nil })
}

pub fn start(
  kz: Kazoo,
  transport: Transport,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(30_000, fn(self) {
    let _ = process.send_after(self, first_pass_ms, Pass)
    actor.initialised(State(self:, kz:, transport:))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.named(name())
  |> actor.start
}

/// Run a pass now rather than waiting for the timer, which is what `sup`
/// asks. Answers at once; the pass runs elsewhere.
pub fn now() -> Nil {
  case process.named(name()) {
    Ok(_pid) -> process.send(process.named_subject(name()), Pass)
    Error(Nil) -> Nil
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Pass -> {
      // The timer first: a pass that crashes or hangs must not take the
      // hour with it.
      let _ = process.send_after(state.self, interval_ms, Pass)
      run(state.kz, state.transport)
      actor.continue(state)
    }
    Stop(done) -> {
      process.send(done, Nil)
      actor.stop()
    }
  }
}

// ---------------------------------------------------------------------------
// Running one pass beside the actor
// ---------------------------------------------------------------------------

type Ran {
  Finished(List(#(Level, String)))
  Crashed
}

/// One pass in a process of its own. The actor is not linked to it, so a
/// crash in a parser or a datastore call is an alert rather than a
/// restart, and a pass that never comes back is abandoned rather than
/// holding the actor for good.
fn run(kz: Kazoo, transport: Transport) -> Nil {
  let answers = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      process.send(answers, pass_with_levels(kz, transport))
    })
  let watch = process.monitor(worker)
  let selector =
    process.new_selector()
    |> process.select_map(answers, Finished)
    |> process.select_specific_monitor(watch, fn(_down) { Crashed })
  case process.selector_receive(selector, pass_timeout_ms) {
    Ok(Finished(lines)) -> {
      process.demonitor_process(watch)
      list.each(lines, log)
    }
    Ok(Crashed) -> failed(kz, "crashed")
    Error(Nil) -> {
      process.kill(worker)
      process.demonitor_process(watch)
      failed(
        kz,
        "did not finish within "
          <> int.to_string(pass_timeout_ms / 60_000)
          <> " minutes and was abandoned",
      )
    }
  }
}

fn failed(kz: Kazoo, what: String) -> Nil {
  let line = "the monitor pass " <> what
  let outcome =
    alert.raise(
      kz,
      "monitor-crash",
      "STIR/SHAKEN monitor pass failed",
      "The hourly STIR/SHAKEN maintenance pass "
        <> what
        <> " on node "
        <> system.node_name()
        <> ". Certificates are not being activated, checked or alerted about"
        <> " on this node; the trust material may be going stale. The node's"
        <> " log has what it was doing.",
      doc.object([#("kind", doc.String("monitor"))]),
      kz.now(),
      alert.hourly_interval_s,
    )
  let line = alert.describe(outcome, line)
  log(#(Failure, line))
  cache.put(
    last_pass_table,
    "last",
    LastPass(at: kz.now(), took_s: 0, lines: [line]),
  )
}

fn log(line: #(Level, String)) -> Nil {
  case line {
    #(Info, text) -> system.log("monitor: " <> text)
    #(Failure, text) -> system.log_error("monitor: " <> text)
  }
}

// ---------------------------------------------------------------------------
// The pass
// ---------------------------------------------------------------------------

/// One pass, synchronously, for a test or for `sup` to report on: what it
/// did, one line per action.
pub fn pass(kz: Kazoo, transport: Transport) -> List(String) {
  pass_with_levels(kz, transport) |> list.map(pair.second)
}

/// The same, saying which lines are failures. The actor logs those at
/// error level, and `sup monitor_now` marks them.
pub fn pass_with_levels(
  kz: Kazoo,
  transport: Transport,
) -> List(#(Level, String)) {
  let started = kz.now()
  let lines = case db.ensure(kz) {
    db.Unreachable -> [#(Failure, "datastore unreachable; nothing done")]
    _ -> pass_with_datastore(kz, transport)
  }
  cache.put(
    last_pass_table,
    "last",
    LastPass(
      at: started,
      took_s: kz.now() - started,
      lines: list.map(lines, pair.second),
    ),
  )
  lines
}

/// What the last pass on this node did, for `sup status`: when it ran (unix
/// seconds), how long it took, and its lines. `None` before the first.
pub fn last_pass() -> Option(LastPass) {
  option.from_result(cache.get(last_pass_table, "last"))
}

pub type LastPass {
  LastPass(at: Int, took_s: Int, lines: List(String))
}

const last_pass_table = "stir_monitor"

/// Activation failures per kid, so a pending key that cannot take over
/// stops counting as a successor. Node-local and deliberately not
/// durable: a restart gives every key another try.
const failures_table = "stir_monitor_failures"

fn pass_with_datastore(
  kz: Kazoo,
  transport: Transport,
) -> List(#(Level, String)) {
  // The datastore is there now, whether or not it was when this node
  // started; registering is idempotent and the views are what the key
  // store reads through.
  views.register()
  let config = settings.load(kz)
  let now = modb.from_unix(kz.now())
  // Housekeeping, silent: the call-path caches are bounded by whoever
  // notices they are over, and a node that has stopped taking calls is
  // the one nobody else will notice for.
  let _swept = x5u.sweep() + numbers.sweep() + carriers.sweep()
  case keys.list(kz) {
    Error(error) ->
      list.flatten([
        [#(Failure, "keys: could not be listed: " <> keys_error(error))],
        vault_check(kz, []),
        refresh_trust(kz, transport, config, now),
      ])
    Ok(all) ->
      list.flatten([
        vault_check(kz, all),
        one_active_per_scope(kz, all),
        activate(kz, all, now),
        expiry_alerts(kz, all, config, now),
        self_check(kz, transport, all),
        refresh_trust(kz, transport, config, now),
        cleanup(kz, all, now),
      ])
  }
}

// ---------------------------------------------------------------------------
// 0. The key-encryption key
// ---------------------------------------------------------------------------

/// A node with no `STIR_KEK` cannot open a key, so it cannot sign: the
/// keys are there, the certificates are valid, and every call goes out
/// unsigned. Hourly, because it is a deployment mistake and someone has
/// to go and fix it.
fn vault_check(kz: Kazoo, all: List(Key)) -> List(#(Level, String)) {
  case vault.load() {
    Ok(_vault) -> []
    Error(error) -> {
      let active = list.count(all, fn(k) { k.status == key.Active })
      let what = "no key-encryption key: " <> vault.describe_error(error)
      let consequence = case active {
        0 ->
          "Nothing can be signed or created on this node until it is set;"
          <> " there are no active keys yet, so no call is being affected."
        n ->
          "Nothing can be signed on this node until it is set, and "
          <> int.to_string(n)
          <> " active key(s) are meant to be signing: every call this node"
          <> " handles goes out unsigned."
      }
      [
        #(
          Failure,
          alert.describe(
            alert.raise(
              kz,
              "no-vault",
              "STIR/SHAKEN has no key-encryption key on this node",
              system.kek_variable
                <> " is not a usable key on node "
                <> system.node_name()
                <> " ("
                <> vault.describe_error(error)
                <> "). "
                <> consequence,
              doc.object([#("kind", doc.String("vault"))]),
              kz.now(),
              alert.hourly_interval_s,
            ),
            what,
          ),
        ),
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// 1. One active key per scope
// ---------------------------------------------------------------------------

/// Two nodes activating at once leave a scope with two active keys --
/// the write order is deliberate, since two active is better than none
/// -- and nothing used to put it back. The longest-lived one keeps the
/// scope and the others are retired, which is also what an operator
/// would do by hand.
fn one_active_per_scope(kz: Kazoo, all: List(Key)) -> List(#(Level, String)) {
  let actives = list.filter(all, fn(k) { k.status == key.Active })
  scopes_of(actives)
  |> list.flat_map(fn(scope) {
    case list.filter(actives, fn(k) { k.scope == scope }) {
      [] | [_only] -> []
      many ->
        case list.sort(many, longest_lived_first) {
          [] -> []
          [keeps, ..extra] -> {
            let name = key.scope_to_string(scope)
            let what =
              int.to_string(list.length(many))
              <> " active keys for scope "
              <> name
              <> " ("
              <> string.join(list.map(many, fn(k) { k.kid }), ", ")
              <> "); keeping "
              <> keeps.kid
            let alerted =
              alert.raise_for(
                kz,
                Some(scope),
                "two-active:" <> name,
                "STIR/SHAKEN has more than one active key for a scope",
                "Scope "
                  <> name
                  <> " has "
                  <> int.to_string(list.length(many))
                  <> " active keys ("
                  <> string.join(list.map(many, fn(k) { k.kid }), ", ")
                  <> "). Two nodes activated at once; the longest-lived key, "
                  <> keeps.kid
                  <> ", keeps the scope and the others are being retired."
                  <> " Calls signed with the retired ones still verify until"
                  <> " their certificates expire.",
                doc.object([#("kind", doc.String("key"))]),
                kz.now(),
                alert.default_interval_s,
              )
            [
              #(Failure, alert.describe(alerted, what)),
              ..list.map(extra, fn(k) {
                case keys.retire(kz, k.kid, "monitor") {
                  Ok(_retired) -> #(
                    Info,
                    "retired key "
                      <> k.kid
                      <> ", a second active key for "
                      <> name,
                  )
                  Error(error) -> #(
                    Failure,
                    "could not retire the second active key "
                      <> k.kid
                      <> ": "
                      <> keys_error(error),
                  )
                }
              })
            ]
          }
        }
    }
  })
}

/// Every scope in the list, in the order it first appears.
fn scopes_of(all: List(Key)) -> List(key.Scope) {
  list.fold(all, [], fn(so_far, k) {
    case list.contains(so_far, k.scope) {
      True -> so_far
      False -> [k.scope, ..so_far]
    }
  })
  |> list.reverse
}

/// Longest-lived first, the kid breaking a tie so every node picks the
/// same key.
fn longest_lived_first(a: Key, b: Key) -> order.Order {
  case
    int.compare(option.unwrap(b.not_after, 0), option.unwrap(a.not_after, 0))
  {
    order.Eq -> string.compare(a.kid, b.kid)
    other -> other
  }
}

// ---------------------------------------------------------------------------
// 2. Activation
// ---------------------------------------------------------------------------

/// Every pending key whose `not_before` has passed and whose `not_after`
/// has not takes over its scope when the scope has no active key, or when
/// the active key expires before it. One activation per scope per pass,
/// the longest-lived candidate; the signer forgets its opened keys after
/// any.
///
/// A key that sat pending past its own expiry is not a candidate: it
/// cannot sign anything a verifier would accept, and activating it would
/// retire a key that still can.
fn activate(kz: Kazoo, all: List(Key), now: Int) -> List(#(Level, String)) {
  let due =
    all
    |> list.filter(fn(k) {
      k.status == key.Pending
      && case k.not_before {
        Some(at) -> at <= now
        None -> False
      }
      && case k.not_after {
        Some(at) -> at > now
        None -> False
      }
    })
    |> list.sort(longest_lived_first)
  let #(lines, _scopes) =
    list.fold(due, #([], []), fn(acc, candidate) {
      let #(lines, done) = acc
      case list.contains(done, candidate.scope) {
        True -> acc
        False ->
          case takes_over(candidate, active_of(all, candidate.scope)) {
            False -> acc
            True -> #([activation(kz, candidate), ..lines], [
              candidate.scope,
              ..done
            ])
          }
      }
    })
  case lines {
    [] -> []
    _ -> {
      signer.refresh()
      list.reverse(lines)
    }
  }
}

fn active_of(all: List(Key), scope: key.Scope) -> Result(Key, Nil) {
  list.find(all, fn(k) { k.status == key.Active && k.scope == scope })
}

fn takes_over(candidate: Key, active: Result(Key, Nil)) -> Bool {
  case active {
    Error(Nil) -> True
    Ok(current) ->
      case current.not_after, candidate.not_after {
        Some(theirs), Some(ours) -> theirs < ours
        _, _ -> False
      }
  }
}

fn activation(kz: Kazoo, candidate: Key) -> #(Level, String) {
  case keys.activate(kz, candidate.kid, "monitor") {
    Ok(_) -> {
      forget_failures(candidate.kid)
      #(
        Info,
        "activated key "
          <> candidate.kid
          <> " for scope "
          <> key.scope_to_string(candidate.scope),
      )
    }
    Error(error) -> {
      let failures = failed_to_activate(candidate.kid)
      #(
        Failure,
        "could not activate key "
          <> candidate.kid
          <> " ("
          <> int.to_string(failures)
          <> " attempt(s) now): "
          <> keys_error(error),
      )
    }
  }
}

fn failures_of(kid: String) -> Int {
  cache.get(failures_table, kid) |> result.unwrap(0)
}

fn failed_to_activate(kid: String) -> Int {
  let failures = failures_of(kid) + 1
  cache.put(failures_table, kid, failures)
  failures
}

fn forget_failures(kid: String) -> Nil {
  cache.delete(failures_table, kid)
}

// ---------------------------------------------------------------------------
// 3. Expiry alerts
// ---------------------------------------------------------------------------

/// An active key inside a threshold of its `not_after`, with nothing
/// newer pending or active for its scope, is alerted about at the
/// tightest threshold it is inside, once a day. One that is already past
/// `not_after` is alerted about under a dedupe of its own: it is not a
/// diary entry any more, it is an outage.
fn expiry_alerts(
  kz: Kazoo,
  all: List(Key),
  config: Settings,
  now: Int,
) -> List(#(Level, String)) {
  all
  |> list.filter(fn(k) { k.status == key.Active })
  |> list.filter_map(fn(k) {
    case key.days_left(k, now), has_newer(all, k) {
      Some(days), False if days < 0 -> Ok(expired_alert(kz, k, now))
      Some(days), False ->
        case
          config.alert_days
          |> list.filter(fn(threshold) { days <= threshold })
          |> list.sort(int.compare)
          |> list.first
        {
          Ok(threshold) -> Ok(expiry_alert(kz, k, days, threshold))
          Error(Nil) -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  })
}

/// Whether another pending or active key of the scope outlives this one.
///
/// A pending key that has failed to activate again and again is not a
/// successor, whatever its dates say: counting it kept the expiry alert
/// quiet for exactly the key that was not going to be replaced.
fn has_newer(all: List(Key), k: Key) -> Bool {
  list.any(all, fn(other) {
    other.kid != k.kid
    && other.scope == k.scope
    && { other.status == key.Pending || other.status == key.Active }
    && {
      other.status == key.Active
      || failures_of(other.kid) < failures_before_doubting
    }
    && case other.not_after, k.not_after {
      Some(theirs), Some(ours) -> theirs > ours
      _, _ -> False
    }
  })
}

fn expiry_alert(
  kz: Kazoo,
  k: Key,
  days: Int,
  threshold: Int,
) -> #(Level, String) {
  let what =
    "key "
    <> k.kid
    <> " ("
    <> key.scope_to_string(k.scope)
    <> ") expires in "
    <> int.to_string(days)
    <> " day(s)"
  #(
    Failure,
    alert.describe(
      alert.raise_for(
        kz,
        Some(k.scope),
        k.kid <> ":" <> int.to_string(threshold),
        "STIR/SHAKEN certificate expires in "
          <> int.to_string(days)
          <> " day(s)",
        "The signing certificate of "
          <> what
          <> " and no newer key is pending. Have a new certificate issued (POST /v2/stir/keys for a CSR), upload it and activate it.",
        metadata([#("kid", doc.String(k.kid)), #("days_left", doc.Int(days))]),
        kz.now(),
        alert.default_interval_s,
      ),
      what,
    ),
  )
}

fn expired_alert(kz: Kazoo, k: Key, now: Int) -> #(Level, String) {
  let days = case k.not_after {
    Some(at) -> int.max({ now - at } / 86_400, 0)
    None -> 0
  }
  let what =
    "key "
    <> k.kid
    <> " ("
    <> key.scope_to_string(k.scope)
    <> ") expired "
    <> int.to_string(days)
    <> " day(s) ago"
  #(
    Failure,
    alert.describe(
      alert.raise_for(
        kz,
        Some(k.scope),
        "expired:" <> k.kid,
        "STIR/SHAKEN certificate has expired",
        "The signing certificate of "
          <> what
          <> " and it is still the active key for its scope. Calls signed with"
          <> " it fail verification at every terminating carrier. Have a new"
          <> " certificate issued (POST /v2/stir/keys for a CSR), upload it and"
          <> " activate it.",
        metadata([#("kid", doc.String(k.kid)), #("expired_days", doc.Int(days))]),
        kz.now(),
        alert.default_interval_s,
      ),
      what,
    ),
  )
}

fn metadata(members: List(#(String, doc.Value))) -> doc.Value {
  doc.object([#("kind", doc.String("key")), ..members])
}

// ---------------------------------------------------------------------------
// 4. The x5u self-check
// ---------------------------------------------------------------------------

/// Every active key's own `x5u` is fetched afresh -- the cache is dropped
/// first, so this is the public URL answering now, not a day ago -- and
/// must answer the chain the store holds.
///
/// The fetches run at once, one process each: a node with eight keys and
/// an x5u host that has stopped answering used to spend eight timeouts,
/// two minutes, inside the pass.
fn self_check(
  kz: Kazoo,
  transport: Transport,
  all: List(Key),
) -> List(#(Level, String)) {
  case list.filter(all, fn(k) { k.status == key.Active && k.x5u != "" }) {
    [] -> []
    checked -> {
      let answers = process.new_subject()
      list.each(checked, fn(k) {
        process.spawn_unlinked(fn() {
          x5u.forget(k.x5u)
          process.send(answers, #(
            k.kid,
            x5u.fetch(transport, k.x5u, fetch_timeout_ms),
          ))
        })
      })
      let fetched =
        gather(
          answers,
          list.length(checked),
          ffi.now_s() + self_check_wait_s,
          [],
        )
      list.map(checked, fn(k) {
        case list.key_find(fetched, k.kid) {
          Error(Nil) ->
            x5u_alert(
              kz,
              k,
              "did not answer within "
                <> int.to_string(self_check_wait_s)
                <> " seconds",
            )
          Ok(Error(error)) ->
            case error {
              x5u.BadUrl ->
                x5u_alert(
                  kz,
                  k,
                  "is refused by the address policy (https, port 443, no"
                    <> " private addresses); set x5u_base_url to the public"
                    <> " API host",
                )
              _ ->
                x5u_alert(kz, k, "could not be fetched: " <> x5u_error(error))
            }
          Ok(Ok(served)) ->
            case keys.certificate_pem(kz, k.kid) {
              Ok(stored) if served != stored ->
                case x5u.certificates(stored) == served {
                  // The store keeps what was uploaded, comments and all;
                  // the fetch keeps the certificates. Same certificates,
                  // different bytes, is not a mismatch.
                  True -> #(Info, "x5u of key " <> k.kid <> " answers")
                  False ->
                    x5u_alert(
                      kz,
                      k,
                      "answers a different certificate than the store holds",
                    )
                }
              _ -> #(Info, "x5u of key " <> k.kid <> " answers")
            }
        }
      })
    }
  }
}

/// Answers off the subject until there are none left to come or the
/// deadline (unix seconds) passes.
fn gather(
  answers: Subject(#(String, Result(String, x5u.Error))),
  remaining: Int,
  deadline: Int,
  so_far: List(#(String, Result(String, x5u.Error))),
) -> List(#(String, Result(String, x5u.Error))) {
  case remaining <= 0 {
    True -> so_far
    False -> {
      let left = { deadline - ffi.now_s() } * 1000
      case left <= 0 {
        True -> so_far
        False ->
          case process.receive(answers, left) {
            Error(Nil) -> so_far
            Ok(answer) ->
              gather(answers, remaining - 1, deadline, [answer, ..so_far])
          }
      }
    }
  }
}

fn x5u_alert(kz: Kazoo, k: Key, why: String) -> #(Level, String) {
  let what = "x5u of key " <> k.kid <> " (" <> k.x5u <> ") " <> why
  #(
    Failure,
    alert.describe(
      alert.raise_for(
        kz,
        Some(k.scope),
        k.kid <> ":x5u",
        "STIR/SHAKEN certificate URL is not answering",
        "The "
          <> what
          <> ". Verifiers cannot fetch the certificate, so calls signed with this key fail verification.",
        metadata([#("kid", doc.String(k.kid)), #("x5u", doc.String(k.x5u))]),
        kz.now(),
        alert.default_interval_s,
      ),
      what,
    ),
  )
}

// ---------------------------------------------------------------------------
// 5. Trust
// ---------------------------------------------------------------------------

/// The CRL's own clock, not just the CA cadence.
///
/// The CRL lives 24 hours and the STI-PA reissues it on its own
/// schedule, so a refresh timed off the CA list alone leaves the stored
/// CRL past its `nextUpdate` for part of every day, and every inbound
/// verification in that window goes unchecked. A pass refreshes when
/// the stored CRL is within `crl_margin_s` of its next update, or when
/// the CA list is past `trust_refresh_hours` and this node is the one
/// that refreshes on the cadence. The pass runs hourly, so the margin
/// has to be more than an hour.
const crl_margin_s = 7200

fn refresh_trust(
  kz: Kazoo,
  transport: Transport,
  config: Settings,
  now: Int,
) -> List(#(Level, String)) {
  case due_for_refresh(kz, config, now) {
    False -> []
    True ->
      case
        trust.refresh(kz, transport, config.stipa_api_url, fetch_timeout_ms)
      {
        Ok([_ca]) -> [
          #(
            Failure,
            "refreshed the CA list from "
              <> config.stipa_api_url
              <> "; the CRL did not come or was refused, and the stored one"
              <> " was kept",
          ),
        ]
        Ok(_) -> [
          #(Info, "refreshed the trust material from " <> config.stipa_api_url),
        ]
        Error(error) -> [
          #(Failure, "trust refresh failed: " <> trust_error(error)),
        ]
      }
  }
}

/// `now` is Gregorian seconds, as the rest of the pass counts; a CRL's
/// `detail` is its next update in unix seconds.
fn due_for_refresh(kz: Kazoo, config: Settings, now: Int) -> Bool {
  case trust.status(kz) {
    Error(_) -> True
    Ok(statuses) -> {
      let ca_due = case
        list.find(statuses, fn(status) { status.kind == trust.Ca })
      {
        Error(Nil) -> True
        Ok(ca) ->
          ca.fetched_at + config.trust_refresh_hours * 3600 <= now
          || !trust.bundle_stored(kz, trust.Ca)
      }
      let crl_due = case
        list.find(statuses, fn(status) { status.kind == trust.Crl })
      {
        Error(Nil) -> True
        Ok(crl) ->
          case crl.detail {
            None -> True
            Some(next_update) -> next_update - crl_margin_s <= kz.now()
          }
      }
      // A CRL a refresh stored before CRLs were authenticated is not used
      // for the revocation check: replace it at once. The leader's to do,
      // like the cadence: if the replacement is refused, every node
      // fetching again every pass would change nothing but the load.
      let crl_unauthenticated = !trust.crl_authenticated(kz)
      // The cadence is the leader's; the CRL going stale is everyone's,
      // so a leader that has stopped refreshing cannot starve the rest.
      { { ca_due || crl_unauthenticated } && refreshes_on_the_cadence() }
      || crl_due
    }
  }
}

/// Whether this node is the one that refreshes the trust material on the
/// cadence: the first by name of the nodes running `stir`. A node that
/// cannot see a cluster at all -- a test, a release-less tree, a node
/// whose heartbeat has not landed yet -- counts itself the leader, since
/// the alternative is a cluster of one that never refreshes.
fn refreshes_on_the_cadence() -> Bool {
  let me = system.node_name()
  case running_stir() {
    [] -> True
    running ->
      case list.contains(running, me) {
        False -> True
        True -> list.sort(running, string.compare) |> list.first == Ok(me)
      }
  }
}

fn running_stir() -> List(String) {
  nodes.nodes()
  |> list.filter(fn(node) { list.contains(node.kapps, system.category) })
  |> list.map(fn(node) { node.name })
  |> list.filter(fn(name) { name != "" })
}

// ---------------------------------------------------------------------------
// 6. Retired keys
// ---------------------------------------------------------------------------

fn cleanup(kz: Kazoo, all: List(Key), now: Int) -> List(#(Level, String)) {
  all
  |> list.filter(fn(k) {
    k.status == key.Retired
    && case k.not_after {
      Some(at) -> at < now
      None -> False
    }
  })
  |> list.map(fn(k) {
    case keys.delete(kz, k.kid, "monitor") {
      Ok(Nil) -> {
        forget_failures(k.kid)
        #(Info, "deleted retired key " <> k.kid <> " past its not_after")
      }
      Error(error) -> #(
        Failure,
        "could not delete retired key " <> k.kid <> ": " <> keys_error(error),
      )
    }
  })
}

// ---------------------------------------------------------------------------
// What went wrong, in words
// ---------------------------------------------------------------------------

fn keys_error(error: keys.Error) -> String {
  case error {
    keys.Datastore(why) -> "datastore: " <> kazoo.error_to_string(why)
    keys.NotFound -> "not found"
    keys.NoVault -> "no key-encryption key on this node"
    keys.Unsealable -> "sealed under another key-encryption key"
    keys.Damaged -> "the sealed private key is not a readable blob"
    keys.NoPrivateKey -> "no sealed private key on the document"
    keys.CertificateMismatch(why) -> "certificate mismatch: " <> why
    keys.InvalidTransition -> "the status does not allow that"
    keys.Conflict -> "another node changed it first; nothing was written"
    keys.ViewMissing -> "the " <> keys.view <> " view is not registered"
    keys.Crypto(why) -> "crypto: " <> why
  }
}

fn x5u_error(error: x5u.Error) -> String {
  case error {
    x5u.BadUrl -> "not an https URL, or an address policy refused it"
    x5u.Fetch(http.Transport(why)) -> why
    x5u.NotACertificate(status) ->
      "HTTP " <> int.to_string(status) <> " without a certificate"
    x5u.TooLarge -> "the answer is above the size a certificate may be"
    x5u.RecentlyFailed -> "failed a moment ago"
  }
}

fn trust_error(error: trust.Error) -> String {
  case error {
    trust.Datastore(why) -> "datastore: " <> kazoo.error_to_string(why)
    trust.NotFound -> "not found"
    trust.Stipa(stipa.Fetch(http.Transport(why))) ->
      "the STI-PA could not be reached: " <> why
    trust.Stipa(stipa.Malformed(why)) ->
      "the STI-PA answered something unexpected: " <> why
    trust.Stipa(stipa.Untrusted(why)) ->
      "the STI-PA's answer is not trusted: " <> why
  }
}
