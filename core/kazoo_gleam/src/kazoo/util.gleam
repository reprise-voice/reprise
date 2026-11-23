//// The odds and ends every Kazoo application needs and Gleam has no way to
//// express: a content digest, a constant-time comparison, an instant back to
//// unix seconds, and a registered name built from a literal.

import gleam/erlang/process.{type Name}

/// A short content digest, for a revision a client can cache on: the first
/// four bytes of the MD5, in lowercase hexadecimal. It identifies content, it
/// does not authenticate it.
@external(erlang, "kazoo_gleam_util_ffi", "digest")
pub fn digest(content: String) -> String

/// Compare two secrets in time that depends on their length but not on where
/// they first differ.
@external(erlang, "kazoo_gleam_util_ffi", "secure_compare")
pub fn secure_compare(a: String, b: String) -> Bool

/// An RFC 3339 instant back to unix seconds; the other direction is
/// `kazoo.iso8601`.
@external(erlang, "kazoo_gleam_util_ffi", "from_iso8601")
pub fn from_iso8601(text: String) -> Result(Int, Nil)

/// A registered name from a literal string.
///
/// `process.new_name` mints a fresh atom on every call, which is not what a
/// name has to be when a caller holding nothing but a string has to find the
/// process. Call this with literals only: every distinct string is one more
/// atom in the table, for good.
@external(erlang, "kazoo_gleam_util_ffi", "atom_name")
pub fn name(name: String) -> Name(message)
