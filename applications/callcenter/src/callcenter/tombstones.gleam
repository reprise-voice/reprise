//// The cancels a shard received for callers it was not holding.
////
//// `gen_listener` hands every delivery to a process of its own, and each of
//// those hands it back to the listener, so two deliveries off one queue can
//// reach the shard in either order. A `member_cancel` that arrives before
//// the `member_call` it cancels finds nothing to settle; without a note of
//// it, the `member_call` that follows is a caller nobody will ever cancel
//// again -- they have left the queue and gone on with their callflow -- and
//// the dispatcher rings an agent for them, with a bridge that breaks into
//// whatever the callflow is doing by then.
////
//// So a cancel that settled nothing is written down here, for a minute and
//// no more than a few thousand at a time, and the `member_call` of the
//// passage it cancelled is settled on arrival and never dispatched. A cancel
//// buries one passage and is used up doing it.
////
//// Which passage: a cancel that says when the caller joined
//// (`Joined-Timestamp`) buries the `member_call` of that account, call and
//// queue that joined at that second, and no other. One from a release that
//// did not say buries the first such `member_call` that joined at or before
//// the second the caller left. A caller who comes back to the same queue
//// with the same call id is a passage of its own and is dispatched like
//// anybody else: joined at another second, or, joined in the same second as
//// the passage buried, arriving after the cancel was used up.
////
//// Pure: the clock is given, so the ages can be tested.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// How long a cancel is remembered. Deliveries that reach the shard out of
/// order are milliseconds apart, a redelivery burst after a failover a few
/// seconds; a minute is many times either.
pub const max_age_ms = 60_000

/// How many cancels are remembered at most. The oldest go first.
pub const max_entries = 4096

/// A caller's passage through one queue: account, call id, queue.
pub type Passage =
  #(String, String, String)

/// A cancel's passage, and the second the caller joined it when it said.
type Key =
  #(Passage, Option(Int))

pub opaque type Tombstones {
  Tombstones(
    /// The passage and the second the caller joined it, when the cancel
    /// said, to the Gregorian second the caller left it and the monotonic
    /// millisecond it was noted here.
    entries: Dict(Key, #(Int, Int)),
  )
}

pub fn new() -> Tombstones {
  Tombstones(dict.new())
}

/// Remember a cancel that settled nothing: the caller who joined that
/// queue at `joined`, when the cancel said, left it at `cancelled_at`,
/// Gregorian seconds, and it is `now_ms` here.
///
/// Two cancels for one passage keep the later second.
pub fn note(
  tombstones: Tombstones,
  passage: Passage,
  joined joined: Option(Int),
  cancelled_at cancelled_at: Int,
  now_ms now_ms: Int,
) -> Tombstones {
  let key = #(passage, joined)
  let entries = case dict.get(tombstones.entries, key) {
    Ok(#(earlier, _noted)) if earlier > cancelled_at ->
      dict.insert(tombstones.entries, key, #(earlier, now_ms))
    _other -> dict.insert(tombstones.entries, key, #(cancelled_at, now_ms))
  }
  Tombstones(bounded(fresh(entries, now_ms)))
}

/// Bury a `member_call` of that passage, joined at `joined_at`, if a cancel
/// already reached it: one that said the caller joined at that second, or,
/// failing that, one that did not say and was made at or after that second.
/// The cancel that buries it is used up.
pub fn bury(
  tombstones: Tombstones,
  passage: Passage,
  joined_at joined_at: Int,
  now_ms now_ms: Int,
) -> Result(Tombstones, Nil) {
  let exact = #(passage, Some(joined_at))
  let unsaid = #(passage, None)
  let live = fn(key, buries: fn(Int) -> Bool) {
    case dict.get(tombstones.entries, key) {
      Ok(#(cancelled_at, noted)) ->
        now_ms - noted <= max_age_ms && buries(cancelled_at)
      Error(Nil) -> False
    }
  }
  case
    live(exact, fn(_cancelled_at) { True }),
    live(unsaid, fn(cancelled_at) { joined_at <= cancelled_at })
  {
    True, _ -> Ok(Tombstones(dict.delete(tombstones.entries, exact)))
    False, True -> Ok(Tombstones(dict.delete(tombstones.entries, unsaid)))
    False, False -> Error(Nil)
  }
}

/// How many are remembered, for the tests and `sup`.
pub fn size(tombstones: Tombstones) -> Int {
  dict.size(tombstones.entries)
}

fn fresh(
  entries: Dict(Key, #(Int, Int)),
  now_ms: Int,
) -> Dict(#(Passage, Option(Int)), #(Int, Int)) {
  dict.filter(entries, fn(_key, entry) { now_ms - entry.1 <= max_age_ms })
}

fn bounded(
  entries: Dict(Key, #(Int, Int)),
) -> Dict(#(Passage, Option(Int)), #(Int, Int)) {
  case dict.size(entries) > max_entries {
    False -> entries
    True ->
      dict.to_list(entries)
      |> list.sort(fn(a, b) { int.compare(b.1.1, a.1.1) })
      |> list.take(max_entries)
      |> dict.from_list
  }
}
