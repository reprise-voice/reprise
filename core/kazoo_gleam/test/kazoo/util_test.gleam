//// The odds and ends.

import gleam/erlang/process
import gleam/string
import kazoo/kazoo
import kazoo/util

/// A digest identifies content: the same content always gives the same eight
/// hexadecimal characters, and different content gives different ones.
pub fn digest_test() {
  let one = util.digest("a phone configuration")
  assert string.length(one) == 8
  assert one == util.digest("a phone configuration")
  assert one != util.digest("a phone configuration ")
  assert one == string.lowercase(one)
  assert util.digest("") == util.digest("")
}

pub fn secure_compare_test() {
  assert util.secure_compare("s3cret", "s3cret")
  assert !util.secure_compare("s3cret", "s3crets")
  assert !util.secure_compare("s3cret", "s3crec")
  assert !util.secure_compare("s3cret", "")
  assert util.secure_compare("", "")
}

/// The two directions of the instant format Kazoo's APIs use.
pub fn iso8601_round_trip_test() {
  assert util.from_iso8601("2025-09-09T06:40:00Z") == Ok(1_757_400_000)
  assert util.from_iso8601(kazoo.iso8601(1_757_400_000)) == Ok(1_757_400_000)
  // An offset is honoured rather than ignored.
  assert util.from_iso8601("2025-09-09T08:40:00+02:00") == Ok(1_757_400_000)
  assert util.from_iso8601("yesterday") == Error(Nil)
  assert util.from_iso8601("") == Error(Nil)
}

/// A name from a literal is the same name every time it is asked for, which
/// is the whole point: `process.new_name` is not.
pub fn name_test() {
  let name: process.Name(Nil) = util.name("kazoo_gleam_test_worker")
  assert name == util.name("kazoo_gleam_test_worker")
  assert process.named(name) == Error(Nil)

  let assert Ok(Nil) = process.register(process.self(), name)
  assert process.named(name) == Ok(process.self())
  let assert Ok(Nil) = process.unregister(name)
  assert process.named(name) == Error(Nil)
}
