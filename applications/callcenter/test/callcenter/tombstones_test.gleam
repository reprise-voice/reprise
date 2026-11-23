//// The cancels a shard remembers for the member that may be behind them.

import callcenter/tombstones
import gleam/option.{None, Some}

const passage = #("account", "call-one", "queue")

fn buries(
  t: tombstones.Tombstones,
  passage: tombstones.Passage,
  joined_at: Int,
  now_ms: Int,
) -> Bool {
  case tombstones.bury(t, passage, joined_at: joined_at, now_ms: now_ms) {
    Ok(_used) -> True
    Error(Nil) -> False
  }
}

/// A cancel that did not say when the caller joined: a member that joined at
/// or before the caller left is the one the cancel was about; one that
/// joined after is the caller back again.
pub fn a_cancel_buries_what_joined_before_it_test() {
  let t =
    tombstones.new()
    |> tombstones.note(passage, joined: None, cancelled_at: 100, now_ms: 0)
  assert buries(t, passage, 90, 10) == True
  assert buries(t, passage, 100, 10) == True
  assert buries(t, passage, 101, 10) == False
  assert buries(t, #("account", "call-one", "another-queue"), 90, 10) == False
  assert buries(t, #("another-account", "call-one", "queue"), 90, 10) == False
}

/// One cancel, one passage: the member it buries uses it up, and the
/// caller's next passage, joined in the same second, is nobody's to bury.
pub fn a_cancel_is_used_up_by_the_member_it_buries_test() {
  let t =
    tombstones.new()
    |> tombstones.note(passage, joined: None, cancelled_at: 100, now_ms: 0)
  let assert Ok(t) = tombstones.bury(t, passage, joined_at: 90, now_ms: 10)
  assert tombstones.size(t) == 0
  assert tombstones.bury(t, passage, joined_at: 100, now_ms: 11) == Error(Nil)
}

/// A cancel that said when the caller joined buries that passage, and no
/// other: not one that joined before the caller left at another second.
pub fn a_cancel_that_says_when_the_caller_joined_buries_that_passage_test() {
  let t =
    tombstones.new()
    |> tombstones.note(passage, joined: Some(90), cancelled_at: 100, now_ms: 0)
  assert buries(t, passage, 100, 10) == False
  assert buries(t, passage, 95, 10) == False
  let assert Ok(t) = tombstones.bury(t, passage, joined_at: 90, now_ms: 10)
  assert buries(t, passage, 90, 11) == False
}

/// Two passages' cancels are two tombstones, each buried by its own member.
pub fn cancels_of_two_passages_bury_one_each_test() {
  let t =
    tombstones.new()
    |> tombstones.note(passage, joined: Some(90), cancelled_at: 100, now_ms: 0)
    |> tombstones.note(passage, joined: Some(100), cancelled_at: 105, now_ms: 1)
  assert tombstones.size(t) == 2
  let assert Ok(t) = tombstones.bury(t, passage, joined_at: 100, now_ms: 2)
  let assert Ok(t) = tombstones.bury(t, passage, joined_at: 90, now_ms: 3)
  assert tombstones.size(t) == 0
}

/// For a minute and no longer.
pub fn a_cancel_is_forgotten_after_a_minute_test() {
  let t =
    tombstones.new()
    |> tombstones.note(passage, joined: None, cancelled_at: 100, now_ms: 0)
  assert buries(t, passage, 90, tombstones.max_age_ms) == True
  assert buries(t, passage, 90, tombstones.max_age_ms + 1) == False
  // And gone from the table the next time anything is noted.
  let t =
    tombstones.note(
      t,
      #("account", "call-two", "queue"),
      joined: None,
      cancelled_at: 100,
      now_ms: tombstones.max_age_ms + 1,
    )
  assert tombstones.size(t) == 1
}

/// Two cancels for one passage keep the later second.
pub fn the_later_cancel_is_kept_test() {
  let t =
    tombstones.new()
    |> tombstones.note(passage, joined: None, cancelled_at: 200, now_ms: 0)
    |> tombstones.note(passage, joined: None, cancelled_at: 100, now_ms: 1)
  assert buries(t, passage, 150, 2) == True
}

/// No more than a few thousand at a time, the oldest going first.
pub fn the_table_is_bounded_test() {
  let t = fill(tombstones.new(), 1, tombstones.max_entries + 10)
  assert tombstones.size(t) == tombstones.max_entries
  assert buries(t, #("account", int_name(1), "queue"), 90, 20) == False
  assert buries(
      t,
      #("account", int_name(tombstones.max_entries + 10), "queue"),
      90,
      20,
    )
    == True
}

fn fill(t: tombstones.Tombstones, n: Int, last: Int) -> tombstones.Tombstones {
  case n > last {
    True -> t
    False ->
      fill(
        tombstones.note(
          t,
          #("account", int_name(n), "queue"),
          joined: None,
          cancelled_at: 100,
          now_ms: n,
        ),
        n + 1,
        last,
      )
  }
}

fn int_name(n: Int) -> String {
  "call-" <> string_of(n)
}

@external(erlang, "erlang", "integer_to_binary")
fn string_of(n: Int) -> String
