//// The month databases: which month an instant is in, what that database is
//// called, and the Gregorian seconds every one of these is counted in.

import gleam/option.{None, Some}
import kazoo/doc
import kazoo/kazoo
import kazoo/modb

const account = "4b1f0c2d7e8a9b0c1d2e3f4051627384"

/// 2026-09-10T12:00:00Z.
const september = 63_956_260_800

/// 2025-12-31T23:59:59Z, the last second of that year.
const new_years_eve = 63_934_444_799

/// 2026-01-01T00:00:00Z, the first second of the next.
const new_years_day = 63_934_444_800

/// Kazoo counts from the year 0, not from 1970. Getting this wrong writes a
/// document into the year 1970's database.
pub fn gregorian_seconds_test() {
  assert modb.unix_epoch_in_gregorian == 62_167_219_200
  assert modb.from_unix(1_789_041_600) == september
  assert modb.to_unix(september) == 1_789_041_600
  assert modb.to_unix(modb.from_unix(0)) == 0
  // Now is in this century, which it would not be if the two were confused.
  assert modb.now() > 63_000_000_000
}

pub fn year_month_test() {
  assert modb.year_month(september) == #(2026, 9)
  assert modb.year_month(new_years_eve) == #(2025, 12)
  assert modb.year_month(new_years_day) == #(2026, 1)
  // A leap day is in February like any other day of it.
  assert modb.year_month(63_876_427_200) == #(2024, 2)
}

/// The database name is the encoded account database with the month on the
/// end, and the month is padded to two digits.
pub fn db_name_test() {
  assert modb.db_name(account, at: Some(september))
    == "account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384-202609"
  assert modb.db_name(account, at: Some(new_years_eve))
    == "account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384-202512"
  assert modb.db_name(account, at: Some(new_years_day))
    == "account%2F4b%2F1f%2F0c2d7e8a9b0c1d2e3f4051627384-202601"
  // One second apart, two different databases.
  assert modb.db_name(account, at: Some(new_years_eve))
    != modb.db_name(account, at: Some(new_years_day))
  // No instant means this month, which is a database name all the same.
  assert modb.db_name(account, at: None) != ""
}

pub fn months_between_test() {
  assert modb.months_between(september, september) == [#(2026, 9)]
  assert modb.months_between(new_years_eve, new_years_day)
    == [#(2025, 12), #(2026, 1)]
  assert modb.months_between(new_years_day, september)
    == [
      #(2026, 1),
      #(2026, 2),
      #(2026, 3),
      #(2026, 4),
      #(2026, 5),
      #(2026, 6),
      #(2026, 7),
      #(2026, 8),
      #(2026, 9),
    ]
  // A range that runs backwards covers nothing.
  assert modb.months_between(september, new_years_day) == []
}

/// Without a datastore every read and write says so rather than pretending.
pub fn unavailable_test() {
  let document = doc.object([#("call_id", doc.String("4b1f"))])
  assert modb.save_doc(account, document, kind: "queue_call", at: None)
    == Error(kazoo.Unavailable)
  assert modb.open_doc(account, "202609-4b1f", at: None)
    == Error(kazoo.Unavailable)
  assert modb.get_results(
      account,
      view: "queue_calls/crossbar_listing",
      options: kazoo.view_options(),
      at: Some(september),
    )
    == Error(kazoo.Unavailable)
  assert modb.get_range(account, new_years_day, september) == []
}

pub fn created_test() {
  assert modb.created(doc.object([#("pvt_created", doc.Int(september))]))
    == Some(september)
  assert modb.created(doc.object([])) == None
}
