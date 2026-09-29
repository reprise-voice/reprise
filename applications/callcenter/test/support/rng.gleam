//// A seeded generator for the property tests: the 48-bit linear
//// congruential one `java.util.Random` uses, so a failure names a seed and
//// the seed reproduces it, whatever the order the suite runs in.

import gleam/int
import gleam/list

pub type Rng {
  Rng(state: Int)
}

const multiplier = 0x5DEECE66D

const mask = 0xFFFFFFFFFFFF

pub fn seeded(seed: Int) -> Rng {
  Rng(int.bitwise_and(int.bitwise_exclusive_or(seed, multiplier), mask))
}

pub fn next(rng: Rng) -> #(Int, Rng) {
  let state = int.bitwise_and(rng.state * multiplier + 0xB, mask)
  #(int.bitwise_shift_right(state, 17), Rng(state))
}

/// 0 to `n - 1`.
pub fn below(rng: Rng, n: Int) -> #(Int, Rng) {
  let #(x, rng) = next(rng)
  #(x % n, rng)
}

pub fn chance(rng: Rng, percent: Int) -> #(Bool, Rng) {
  let #(x, rng) = below(rng, 100)
  #(x < percent, rng)
}

pub fn pick(rng: Rng, items: List(a)) -> #(a, Rng) {
  let #(index, rng) = below(rng, list.length(items))
  let assert Ok(item) = list.first(list.drop(items, index))
  #(item, rng)
}

/// `count` of something, each made from the generator as it stands.
pub fn many(
  rng: Rng,
  count: Int,
  make: fn(Rng, Int) -> #(a, Rng),
) -> #(List(a), Rng) {
  let #(made, rng) =
    upto(count)
    |> list.fold(#([], rng), fn(acc, index) {
      let #(made, rng) = acc
      let #(item, rng) = make(rng, index)
      #([item, ..made], rng)
    })
  #(list.reverse(made), rng)
}

/// 0 to `count - 1`.
pub fn upto(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index })
}

/// Some of `items`, in a shuffled order.
pub fn some_of(rng: Rng, items: List(a), percent: Int) -> #(List(a), Rng) {
  let #(kept, rng) =
    list.fold(items, #([], rng), fn(acc, item) {
      let #(kept, rng) = acc
      let #(keep, rng) = chance(rng, percent)
      let #(key, rng) = next(rng)
      case keep {
        True -> #([#(key, item), ..kept], rng)
        False -> #(kept, rng)
      }
    })
  #(
    list.sort(kept, fn(a, b) { int.compare(a.0, b.0) })
      |> list.map(fn(pair) { pair.1 }),
    rng,
  )
}
