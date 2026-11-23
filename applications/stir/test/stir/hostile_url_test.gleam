//// `stir/x5u`'s address policy over URLs written to get past it.
////
//// The `x5u` is a URL an inbound call hands this node and asks it to
//// fetch, which makes the policy in `stir/x5u.allowed` the whole of
//// what stands between a carrier peer and a request from inside the
//// cluster. The policy is not exported, so it is exercised the way the
//// application reaches it, through `fetch` with a transport that
//// records what it was asked for: a refusal is `Error(BadUrl)` with no
//// call made, and anything else means the request went out.
////
//// The table is `test/fixtures/hostile/urls.txt`, a verdict and a URL
//// to a line, so that a URL worth thinking about can be added without
//// touching the assertions. Beside it are generated addresses: a
//// sample of every network the policy names, written as IPv4 literals
//// and as the `::ffff:` forms of themselves, and a sample of ports.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import stir/http_test.{drain, fake}
import stir/x5u
import support/mutate

/// Whether the policy let the URL through, and whether a request was
/// made for it. The two must agree: a refusal makes no request.
fn fetched(url: String) -> Bool {
  x5u.clear()
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  let answer = x5u.fetch(transport, url, 100)
  let asked = drain(calls) != []
  case answer == Error(x5u.BadUrl), asked {
    True, False -> False
    False, True -> True
    // A refusal that still made a request, or a pass that made none,
    // is neither: say so loudly rather than quietly picking one.
    refused, made ->
      panic as {
        "x5u.fetch("
        <> url
        <> ") answered BadUrl="
        <> string.inspect(refused)
        <> " and made a request="
        <> string.inspect(made)
      }
  }
}

/// The table: `refuse` or `fetch`, a tab, and the URL.
fn table() -> List(#(String, String)) {
  fixture("hostile/urls.txt")
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.starts_with(line, "#") || string.trim(line) == "" {
      True -> Error(Nil)
      False ->
        case string.split_once(line, "\t") {
          Ok(#(verdict, url)) -> Ok(#(string.trim(verdict), url))
          Error(Nil) -> Error(Nil)
        }
    }
  })
}

pub fn url_table_test() {
  let entries = table()
  assert list.length(entries) > 90
  list.each(entries, fn(entry) {
    let #(verdict, url) = entry
    case verdict {
      "refuse" -> {
        assert !fetched(url) as { "should be refused: " <> url }
      }
      "fetch" -> {
        assert fetched(url) as { "should be fetched: " <> url }
      }
      other -> panic as { "unknown verdict " <> other <> " for " <> url }
    }
  })
}

/// Every network the policy names, sampled: two hundred addresses
/// drawn from inside them are refused, and two hundred from outside
/// are not. Drawn from a fixed seed, so a failure names an address
/// that comes back on the next run.
pub fn generated_addresses_test() {
  let #(refused, seed) = addresses(private_ranges, 200, mutate.seed(169_254))
  let #(allowed, _seed) = addresses(public_ranges, 200, seed)

  list.each(refused, fn(address) {
    assert !fetched("https://" <> address <> "/a.pem")
      as { "should be refused: " <> address }
    // And the same address wearing an `::ffff:` prefix.
    assert !fetched("https://[::ffff:" <> address <> "]/a.pem")
      as { "should be refused: ::ffff:" <> address }
  })
  list.each(allowed, fn(address) {
    assert fetched("https://" <> address <> "/a.pem")
      as { "should be fetched: " <> address }
  })
}

/// The first octet (or two) of every network the policy refuses, and of
/// networks next to them that it must not.
const private_ranges = [
  #(0, 0),
  #(0, 255),
  #(10, 0),
  #(10, 255),
  #(127, 0),
  #(127, 255),
  #(169, 254),
  #(172, 16),
  #(172, 24),
  #(172, 31),
  #(192, 168),
  #(100, 64),
  #(100, 100),
  #(100, 127),
  #(224, 0),
  #(232, 1),
  #(239, 255),
  #(240, 0),
  #(255, 255),
]

const public_ranges = [
  #(1, 1),
  #(8, 8),
  #(9, 255),
  #(11, 0),
  #(99, 63),
  #(100, 0),
  #(100, 63),
  #(100, 128),
  #(100, 255),
  #(168, 254),
  #(169, 253),
  #(169, 255),
  #(171, 255),
  #(172, 0),
  #(172, 15),
  #(172, 32),
  #(173, 16),
  #(192, 167),
  #(192, 169),
  #(193, 168),
  #(223, 255),
]

fn addresses(
  ranges: List(#(Int, Int)),
  count: Int,
  seed: mutate.Seed,
) -> #(List(String), mutate.Seed) {
  list.fold(mutate.upto(count), #([], seed), fn(state, _index) {
    let #(so_far, seed) = state
    let #(range, seed) = mutate.pick(seed, ranges, #(127, 0))
    let #(third, seed) = mutate.int_below(seed, 256)
    let #(fourth, seed) = mutate.int_below(seed, 256)
    let #(first, second) = range
    let address =
      int.to_string(first)
      <> "."
      <> int.to_string(second)
      <> "."
      <> int.to_string(third)
      <> "."
      <> int.to_string(fourth)
    #([address, ..so_far], seed)
  })
}

/// Every port but 443 and none, sampled across the range, and the
/// spellings of a port that are not numbers.
pub fn ports_test() {
  let #(ports, _seed) =
    list.fold(mutate.upto(100), #([], mutate.seed(443_443)), fn(state, _index) {
      let #(so_far, seed) = state
      let #(port, seed) = mutate.int_below(seed, 65_536)
      #([port, ..so_far], seed)
    })
  list.each(ports, fn(port) {
    let url = "https://signer.test:" <> int.to_string(port) <> "/a.pem"
    case port {
      443 -> {
        assert fetched(url) as url
      }
      _ -> {
        assert !fetched(url) as url
      }
    }
  })
  // A port that is not a number is not a port: the URL does not
  // parse, which is a refusal. An empty one is the default port
  // written out, which is 443 and is fetched.
  list.each(["443 ", " 443", "443a", "-443", "+443", "44 3"], fn(port) {
    let url = "https://signer.test:" <> port <> "/a.pem"
    assert !fetched(url) as url
  })
  // An empty port is the default written out, and a padded one is the
  // number it pads: both are 443 and both are fetched.
  assert fetched("https://signer.test:/a.pem")
  assert fetched("https://signer.test:0443/a.pem")
}

/// Sizes and shapes rather than addresses: a mebibyte of URL, control
/// characters, nesting, the empty string.
pub fn hostile_shapes_test() {
  let shapes =
    list.flatten([
      mutate.oddities(),
      list.map(mutate.oddities(), fn(odd) { "https://signer.test/" <> odd }),
      list.map(mutate.oddities(), fn(odd) { "https://" <> odd }),
      [
        mutate.huge("a"),
        "https://signer.test/" <> mutate.huge("a"),
        "https://" <> mutate.huge("a") <> ".test/a.pem",
        "https://signer.test/?" <> mutate.huge("a"),
        "https://" <> string.repeat("a.", 10_000) <> "test/a.pem",
        "https://signer.test/" <> string.repeat("../", 10_000) <> "a.pem",
      ],
    ])
  list.each(shapes, fn(shape) {
    // Whatever it is, the answer is a verdict and not a crash; a
    // hostname with a mebibyte in it is a name like any other.
    let _ = fetched(shape)
    Nil
  })
}

/// FINDING (open): the policy reads an IPv4 literal only as a dotted
/// quad, and Erlang's resolver reads four more forms.
///
/// `refused_address` parses a host as four dot-separated decimal
/// octets (`ipv4` in `stir/x5u.gleam`), so `127.1`, `2130706433` and
/// `0177.0.0.1`
/// are not literals to it and are passed through as names. They are
/// literals to `inet:getaddr/2`, which is what the transport's
/// connection resolves with: each of those three answers `{127,0,0,1}`
/// on this machine, as does `0x7f000001` to `inet:parse_address/1`.
/// `127.0.0.1.`, the same address with the root dot, is a fifth
/// spelling the policy does not read, though the resolver here answers
/// `nxdomain` for it.
///
/// What it buys an attacker is a TLS connection attempt from inside the
/// cluster to an address of their choosing on port 443 -- the body is
/// still bounded by the hostname check in the TLS handshake, which no
/// public certificate for `127.1` will pass -- so this is a port
/// knock and a network probe rather than a read. The control the
/// threat model claims (`§3.1`, "IP-literal hosts in private,
/// loopback, link-local, CGNAT, multicast ranges refused") does not
/// hold as written. Failing on purpose.
pub fn alternate_ipv4_literal_forms_test() {
  let spellings = [
    // 127.0.0.1, five ways.
    "127.1", "127.0.1", "2130706433", "0x7f000001", "0177.0.0.1", "127.0.0.1.",
    // 10.0.0.1 and 169.254.169.254, the same way.
    "10.1", "167772161", "0012.0.0.1", "169.254.43518", "2852039166",
  ]
  list.each(spellings, fn(host) {
    assert !fetched("https://" <> host <> "/a.pem")
      as { "should be refused: " <> host }
  })
}

/// FINDING (open): a URL whose bytes are not UTF-8 raises rather than
/// answering `Error(BadUrl)`.
///
/// `allowed` hands the URL to `uri.parse` (`stir/x5u.gleam`), which
/// is written to Gleam's promise that a `String` is UTF-8 and raises
/// `function_clause` when it is not. The URL is the `info` parameter of
/// an `Identity` header, which is a binary off the wire. Failing on
/// purpose; the same root as `hostile_passport_test`'s.
pub fn non_utf8_url_raises_test() {
  let url =
    "https://signer.test/" <> mutate.unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
  x5u.clear()
  let calls = process.new_subject()
  assert x5u.fetch(fake([], calls, timeouts: []), url, 100) == Error(x5u.BadUrl)
}

fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)
