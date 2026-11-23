//// Generators for the hostile-input suites (`stir/hostile_*_test`).
////
//// This tree has no property-testing package and takes no new
//// dependency, so the generators are written out here. The source is a
//// linear congruential generator seeded per suite: every run mutates the
//// same bytes in the same order, so a failing assertion names a mutation
//// that comes back identically on the next run, and a suite that wants
//// another corpus changes its seed rather than its assertions.
////
//// The strategies are the ones an attacker's fuzzer would reach for over
//// a wire format: cut it short at every position, flip a byte at every
//// position, push bytes into the middle, repeat a section, paste another
//// fixture's bytes over a section, swap the base64 alphabet, rename a
//// JSON key. Beside them are the shapes that are awkward rather than
//// random -- empty, a mebibyte, control characters, CRLF for LF, deeply
//// nested brackets -- which `oddities` answers.
////
//// Nothing here asserts anything; the suites do.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// The seeded source
// ---------------------------------------------------------------------------

/// The state of the pseudo-random source. Deterministic: the same seed
/// answers the same sequence on every run and on every machine.
pub opaque type Seed {
  Seed(state: Int)
}

const modulus = 2_147_483_648

/// A source from a number. Two suites that pick different numbers mutate
/// differently; one that picks the same number mutates the same way.
pub fn seed(from: Int) -> Seed {
  Seed(state: int.absolute_value(from) % modulus)
}

/// A number `0 <= n < limit`, from the high bits of the state: the low
/// bits of a congruential generator cycle far too visibly to pick byte
/// positions with.
pub fn int_below(seed: Seed, limit: Int) -> #(Int, Seed) {
  case limit <= 0 {
    True -> #(0, seed)
    False -> {
      let next = advance(seed)
      #(next.state / 1024 % limit, next)
    }
  }
}

/// One byte's worth.
pub fn byte(seed: Seed) -> #(Int, Seed) {
  int_below(seed, 256)
}

/// `count` random bytes.
pub fn bytes(seed: Seed, count: Int) -> #(BitArray, Seed) {
  upto(count)
  |> list.fold(#(<<>>, seed), fn(state, _index) {
    let #(so_far, seed) = state
    let #(value, seed) = byte(seed)
    #(bit_array.append(so_far, <<value:8>>), seed)
  })
}

/// `0, 1, ... count - 1`.
pub fn upto(count: Int) -> List(Int) {
  list.repeat(0, int.max(count, 0))
  |> list.index_map(fn(_zero, index) { index })
}

/// One of `items`, or `fallback` when there are none.
pub fn pick(seed: Seed, items: List(a), fallback: a) -> #(a, Seed) {
  let #(index, seed) = int_below(seed, list.length(items))
  #(list.drop(items, index) |> list.first |> result.unwrap(fallback), seed)
}

fn advance(seed: Seed) -> Seed {
  Seed(state: { 1_103_515_245 * seed.state + 12_345 } % modulus)
}

// ---------------------------------------------------------------------------
// Byte strategies
// ---------------------------------------------------------------------------

/// Every prefix of `bytes` at `step`-byte intervals, the empty one
/// included and the whole thing left out: what a connection cut at every
/// point of the message would deliver.
pub fn truncations(source: BitArray, step: Int) -> List(BitArray) {
  positions(bit_array.byte_size(source), step)
  |> list.map(fn(at) { take(source, 0, at) })
}

/// `bytes` with one byte flipped (exclusive or with `0xff`) at every
/// `step`-th position.
pub fn flips(source: BitArray, step: Int) -> List(BitArray) {
  let size = bit_array.byte_size(source)
  positions(size, step)
  |> list.map(fn(at) {
    let original = case bit_array.slice(source, at, 1) {
      Ok(<<value:8>>) -> value
      _ -> 0
    }
    bit_array.concat([
      take(source, 0, at),
      <<int.bitwise_exclusive_or(original, 0xff):8>>,
      take(source, at + 1, size - at - 1),
    ])
  })
}

/// `count` copies of `bytes`, each with a run of random bytes pushed in
/// at a random position.
pub fn insertions(
  source: BitArray,
  count: Int,
  seed: Seed,
) -> #(List(BitArray), Seed) {
  let size = bit_array.byte_size(source)
  repeatedly(count, seed, fn(seed) {
    let #(at, seed) = int_below(seed, size + 1)
    let #(run, seed) = int_below(seed, 8)
    let #(inserted, seed) = bytes(seed, run + 1)
    #(
      bit_array.concat([
        take(source, 0, at),
        inserted,
        take(source, at, size - at),
      ]),
      seed,
    )
  })
}

/// `count` copies of `bytes`, each with a random section repeated where
/// it sits.
pub fn duplications(
  source: BitArray,
  count: Int,
  seed: Seed,
) -> #(List(BitArray), Seed) {
  let size = bit_array.byte_size(source)
  repeatedly(count, seed, fn(seed) {
    let #(at, seed) = int_below(seed, int.max(size, 1))
    let #(length, seed) = int_below(seed, int.max(size - at, 1))
    #(
      bit_array.concat([
        take(source, 0, at),
        take(source, at, length + 1),
        take(source, at, size - at),
      ]),
      seed,
    )
  })
}

/// `count` copies of `bytes`, each with a random section overwritten by
/// `other`'s bytes: a fixture spliced into another fixture, which is how
/// a chain ends up carrying somebody else's certificate.
pub fn splices(
  source: BitArray,
  other: BitArray,
  count: Int,
  seed: Seed,
) -> #(List(BitArray), Seed) {
  let size = bit_array.byte_size(source)
  let other_size = bit_array.byte_size(other)
  repeatedly(count, seed, fn(seed) {
    let #(at, seed) = int_below(seed, int.max(size, 1))
    let #(length, seed) = int_below(seed, int.max(size - at, 1))
    let #(from, seed) = int_below(seed, int.max(other_size - length, 1))
    #(
      bit_array.concat([
        take(source, 0, at),
        take(other, from, length + 1),
        take(source, at + length + 1, size - at - length - 1),
      ]),
      seed,
    )
  })
}

/// The positions `0, step, 2 * step, ...` below `size`.
pub fn positions(size: Int, step: Int) -> List(Int) {
  case size <= 0 || step <= 0 {
    True -> []
    False ->
      upto({ size - 1 } / step + 1)
      |> list.map(fn(index) { index * step })
  }
}

fn take(source: BitArray, at: Int, length: Int) -> BitArray {
  case length <= 0 {
    True -> <<>>
    False -> bit_array.slice(source, at, length) |> result.unwrap(<<>>)
  }
}

fn repeatedly(
  count: Int,
  seed: Seed,
  generate: fn(Seed) -> #(a, Seed),
) -> #(List(a), Seed) {
  let #(reversed, seed) =
    upto(count)
    |> list.fold(#([], seed), fn(state, _index) {
      let #(so_far, seed) = state
      let #(value, seed) = generate(seed)
      #([value, ..so_far], seed)
    })
  #(list.reverse(reversed), seed)
}

// ---------------------------------------------------------------------------
// Text strategies
// ---------------------------------------------------------------------------

/// Every prefix of `text` at `step`-character intervals.
pub fn text_truncations(text: String, step: Int) -> List(String) {
  positions(string.length(text), step)
  |> list.map(fn(at) { string.slice(text, 0, at) })
}

/// `text` with the character at every `step`-th position swapped for
/// another printable one.
///
/// A flipped *byte* of an ASCII input leaves a `String` whose bytes are
/// not UTF-8, which is a case of its own -- the suites keep it in a
/// `non_utf8_` test rather than in the corpus, since Gleam's type
/// promises a `String` is text and every function in the standard
/// library is written to that promise.
pub fn ascii_flips(text: String, step: Int) -> List(String) {
  let length = string.length(text)
  positions(length, step)
  |> list.map(fn(at) {
    string.slice(text, 0, at)
    <> other_character(string.slice(text, at, 1))
    <> string.slice(text, at + 1, length)
  })
}

/// `count` copies of `text` with a run of printable characters pushed in
/// at a random position.
pub fn text_insertions(
  text: String,
  count: Int,
  seed: Seed,
) -> #(List(String), Seed) {
  let length = string.length(text)
  repeatedly(count, seed, fn(seed) {
    let #(at, seed) = int_below(seed, length + 1)
    let #(run, seed) = int_below(seed, 8)
    let #(pushed, seed) = printable(seed, run + 1)
    #(
      string.slice(text, 0, at) <> pushed <> string.slice(text, at, length),
      seed,
    )
  })
}

/// `count` printable characters.
pub fn printable(seed: Seed, count: Int) -> #(String, Seed) {
  upto(count)
  |> list.fold(#("", seed), fn(state, _index) {
    let #(so_far, seed) = state
    let #(value, seed) = int_below(seed, 95)
    let assert Ok(codepoint) = string.utf_codepoint(value + 32)
    #(so_far <> string.from_utf_codepoints([codepoint]), seed)
  })
}

/// The base64 confusions: the standard alphabet where base64url is
/// expected and the other way round, padding where JWS allows none,
/// whitespace and newlines inside the body, and a padded part.
pub fn base64_swaps(text: String) -> List(String) {
  [
    string.replace(text, "-", "+"),
    string.replace(text, "_", "/"),
    string.replace(text, "+", "-"),
    string.replace(text, "/", "_"),
    string.replace(text, "A", "+"),
    string.replace(text, "A", "/"),
    text <> "=",
    text <> "==",
    text <> "\n",
    text <> "\r\n",
    " " <> text,
    "\t" <> text,
    string.replace(text, ".", ".="),
    string.replace(text, ".", "=."),
    string.replace(text, ".", "\n"),
    string.replace(text, ".", "\r\n"),
    string.replace(text, ".", ".."),
    string.replace(text, ".", ""),
  ]
}

fn other_character(character: String) -> String {
  case character {
    "A" -> "B"
    "a" -> "b"
    "0" -> "1"
    "-" -> "_"
    "_" -> "-"
    "." -> "-"
    "" -> "A"
    _ -> "A"
  }
}

/// The text with `"<key>"` renamed, one copy per key: what a parser sees
/// when a member it needs is not there and an unknown one is.
pub fn renamed_keys(text: String, keys: List(String)) -> List(String) {
  list.map(keys, fn(key) {
    string.replace(text, "\"" <> key <> "\"", "\"" <> key <> "_\"")
  })
}

/// The inputs that are awkward rather than random: nothing, whitespace,
/// control characters, a byte order mark, right-to-left overrides,
/// astral characters, CRLF where LF is expected, and deeply nested
/// brackets. Small, so that a suite can cross them with every position
/// of the value it is mutating; the mebibytes are `huge` and are meant
/// to be used one at a time.
pub fn oddities() -> List(String) {
  [
    "",
    " ",
    "\n",
    "\r\n",
    "\t",
    "\u{0}",
    "a\u{0}b",
    "\u{feff}",
    "\u{202e}drowssap",
    "\u{1f600}",
    "é",
    "\u{c0}\u{80}",
    string.repeat("\u{0}", 64),
    string.repeat("\r\n", 512),
    nested("[", "]", 512),
    nested("{", "}", 512),
    nested("<", ">", 512),
    nested("(", ")", 512),
  ]
}

/// A mebibyte of `unit` repeated.
pub fn huge(unit: String) -> String {
  string.repeat(unit, 1_048_576 / int.max(string.byte_size(unit), 1))
}

/// `depth` opening brackets, then `depth` closing ones.
pub fn nested(open: String, close: String, depth: Int) -> String {
  string.repeat(open, depth) <> string.repeat(close, depth)
}

/// Only the base64 data characters of a value, in order: the alphabet
/// without the `=`, which carries no data.
///
/// This is what a PEM decoder reads. `public_key:pem_decode` hands the
/// body to `base64:mime_decode`, which skips every byte that is not a
/// data character, so two PEMs whose data characters agree decode to
/// the same DER however much junk sits between them.
pub fn alphabet_only(text: String) -> String {
  keep_alphabet(bit_array.from_string(text), <<>>) |> unsafe_string
}

fn keep_alphabet(source: BitArray, kept: BitArray) -> BitArray {
  case source {
    <<byte:8, rest:bytes>> ->
      case is_alphabet(byte) {
        True -> keep_alphabet(rest, bit_array.append(kept, <<byte:8>>))
        False -> keep_alphabet(rest, kept)
      }
    _ -> kept
  }
}

fn is_alphabet(byte: Int) -> Bool {
  { byte >= 0x41 && byte <= 0x5a }
  || { byte >= 0x61 && byte <= 0x7a }
  || { byte >= 0x30 && byte <= 0x39 }
  || byte == 0x2b
  || byte == 0x2f
}

/// The first `count` bytes of a value as hex, for a failure message:
/// the value may be a mutation whose bytes are not text, which
/// `string.slice` would raise on.
pub fn preview(text: String, count: Int) -> String {
  bit_array.base16_encode(
    bit_array.from_string(text)
    |> bit_array.slice(0, int.min(count, string.byte_size(text)))
    |> result.unwrap(<<>>),
  )
}

/// `binary:replace`, which matches and substitutes bytes and so works
/// on a value whose bytes are not UTF-8, where `string.replace` raises.
/// The first occurrence only.
@external(erlang, "binary", "replace")
pub fn replace_bytes(
  subject: String,
  pattern: String,
  replacement: String,
) -> String

/// A binary as a `String` without checking that it is text. Gleam's
/// `String` is an Erlang binary, and the bytes that arrive in a SIP
/// header or an HTTP body are not promised to be UTF-8, so this is how a
/// suite hands the modules under test what the wire can actually carry.
@external(erlang, "erlang", "iolist_to_binary")
pub fn unsafe_string(bytes: BitArray) -> String
