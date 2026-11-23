//// The account's month databases.
////
//// Kazoo splits everything an account accumulates -- CDRs, recordings,
//// ledgers, and the call center's own per-call documents -- into one
//// database per account per month, the MODb. A write creates that month's
//// database on demand, so nothing here has to check first, and a read over a
//// month that never existed answers `NotFound` rather than failing.
////
//// ## Timestamps
////
//// Every timestamp here is in **Gregorian seconds**: seconds since the year
//// 0, which is what `kz_time:now_s/0` answers and what every stored Kazoo
//// timestamp is. It is 62,167,219,200 more than the unix second for the same
//// instant. `now`, `from_unix` and `to_unix` are the conversions; getting
//// this wrong writes documents into the year 1970's database.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import kazoo/doc.{type Value}
import kazoo/kazoo.{type Error}

/// Seconds between the year 0 and the unix epoch. Kazoo's
/// `?UNIX_EPOCH_IN_GREGORIAN`.
pub const unix_epoch_in_gregorian = 62_167_219_200

/// Now, in Gregorian seconds.
@external(erlang, "kazoo_gleam_modb_ffi", "now_s")
pub fn now() -> Int

/// A unix second as the Gregorian second Kazoo stores.
pub fn from_unix(unix_seconds: Int) -> Int {
  unix_seconds + unix_epoch_in_gregorian
}

/// A stored Gregorian second back to the unix second an API answers with.
pub fn to_unix(gregorian_seconds: Int) -> Int {
  gregorian_seconds - unix_epoch_in_gregorian
}

/// The name of the month database an instant falls in, in the encoded form
/// the data layer uses. `None` means this month.
pub fn db_name(account_id: String, at at: Option(Int)) -> String {
  ffi_db_name(account_id, option.unwrap(at, 0))
}

/// Write a document into the month `at` falls in, creating that month if it
/// is not there. `kind` is the document's `pvt_type`, which is what the
/// views key on.
///
/// The private fields go on the way a CDR's do: the type, the account, and
/// the database the document belongs to.
pub fn save_doc(
  account_id: String,
  document: Value,
  kind kind: String,
  at at: Option(Int),
) -> Result(Value, Error) {
  ffi_save_doc(
    account_id,
    doc.to_string(document),
    kind,
    option.unwrap(at, 0),
    3,
  )
  |> to_result
}

/// Read a document from the month `at` falls in. A document whose id carries
/// its own month, as a CDR's does, is found in that month whatever `at`
/// says.
pub fn open_doc(
  account_id: String,
  doc_id: String,
  at at: Option(Int),
) -> Result(Value, Error) {
  ffi_open_doc(account_id, doc_id, option.unwrap(at, 0)) |> to_result
}

/// A view over one month.
pub fn get_results(
  account_id: String,
  view view: String,
  options options: kazoo.ViewOptions,
  at at: Option(Int),
) -> Result(List(Value), Error) {
  ffi_get_results(
    account_id,
    view,
    kazoo.view_options_to_json(options),
    option.unwrap(at, 0),
  )
  |> to_list_result
}

/// Every month database between two instants, oldest first, so a report can
/// run the same view over each of them. The databases are not checked for
/// existence: a month the account has nothing in was never created.
@external(erlang, "kazoo_gleam_modb_ffi", "get_range")
pub fn get_range(account_id: String, from: Int, to: Int) -> List(String)

/// The months a range covers, as `#(year, month)` pairs, oldest first. The
/// arithmetic `get_range` does, without a node to do it on.
pub fn months_between(from: Int, to: Int) -> List(#(Int, Int)) {
  let #(from_year, from_month) = year_month(from)
  let #(to_year, to_month) = year_month(to)
  count_months(from_year * 12 + from_month, to_year * 12 + to_month, [])
  |> list.reverse
}

fn count_months(
  from: Int,
  to: Int,
  taken: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case from > to {
    True -> taken
    False -> count_months(from + 1, to, [of_month(from), ..taken])
  }
}

/// A count of months since the year 0 back to a year and a month. December
/// is the twelfth month of the year before the division says.
fn of_month(months: Int) -> #(Int, Int) {
  case months % 12 {
    0 -> #(months / 12 - 1, 12)
    month -> #(months / 12, month)
  }
}

/// The year and month a Gregorian second falls in.
@external(erlang, "kazoo_gleam_modb_ffi", "year_month")
pub fn year_month(at: Int) -> #(Int, Int)

fn to_result(answer: Result(Dynamic, String)) -> Result(Value, Error) {
  answer
  |> result.map(doc.from_dynamic)
  |> result.map_error(kazoo.error_from_string)
}

fn to_list_result(
  answer: Result(List(Dynamic), String),
) -> Result(List(Value), Error) {
  answer
  |> result.map(list.map(_, doc.from_dynamic))
  |> result.map_error(kazoo.error_from_string)
}

/// The instant a document was written, as the private field carries it.
pub fn created(document: Value) -> Option(Int) {
  case doc.get_int(document, ["pvt_created"]) {
    Ok(at) -> Some(at)
    Error(Nil) -> None
  }
}

@external(erlang, "kazoo_gleam_modb_ffi", "db_name")
fn ffi_db_name(account_id: String, at: Int) -> String

@external(erlang, "kazoo_gleam_modb_ffi", "save_doc")
fn ffi_save_doc(
  account_id: String,
  json: String,
  kind: String,
  at: Int,
  max_retries: Int,
) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_modb_ffi", "open_doc")
fn ffi_open_doc(
  account_id: String,
  doc_id: String,
  at: Int,
) -> Result(Dynamic, String)

@external(erlang, "kazoo_gleam_modb_ffi", "get_results")
fn ffi_get_results(
  account_id: String,
  view: String,
  options_json: String,
  at: Int,
) -> Result(List(Dynamic), String)
