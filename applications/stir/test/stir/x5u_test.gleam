//// `stir/x5u`: the address policy, the day-long cache and its bound, the
//// negative cache, the body cap, and what is not a certificate. The
//// cache is node-global, so every test clears it first and uses URLs of
//// its own.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import stir/http
import stir/http_test.{drain, fake, fixture, ok}
import stir/x5u

const cert_url = "https://signer.test/certs/one.pem"

pub fn https_only_test() {
  x5u.clear()
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  assert x5u.fetch(transport, "http://signer.test/one.pem", 100)
    == Error(x5u.BadUrl)
  assert x5u.fetch(transport, "nope", 100) == Error(x5u.BadUrl)
  assert x5u.fetch(transport, "", 100) == Error(x5u.BadUrl)
  assert x5u.fetch(transport, "https://", 100) == Error(x5u.BadUrl)
  assert drain(calls) == []
}

/// The URL comes out of a header an attacker writes. A host that is an
/// IP literal on a network this node has no business being aimed at is
/// refused without a request being made; a hostname is not resolved
/// here, and TLS binds the answer to the name.
pub fn address_policy_test() {
  x5u.clear()
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  let refused = [
    // Userinfo, and a port that is not 443.
    "https://user@signer.test/a.pem",
    "https://user:pass@signer.test/a.pem",
    "https://signer.test:8443/a.pem",
    "https://signer.test:80/a.pem",
    // Loopback, RFC 1918, link-local, CGNAT, multicast, unspecified.
    "https://127.0.0.1/a.pem",
    "https://127.1.2.3/a.pem",
    "https://10.0.0.7/a.pem",
    "https://172.16.3.4/a.pem",
    "https://172.31.255.255/a.pem",
    "https://192.168.1.1/a.pem",
    "https://169.254.169.254/a.pem",
    "https://100.64.0.1/a.pem",
    "https://100.127.255.254/a.pem",
    "https://224.0.0.1/a.pem",
    "https://255.255.255.255/a.pem",
    "https://0.0.0.0/a.pem",
    // The same addresses as IPv6 literals.
    "https://[::1]/a.pem",
    "https://[::]/a.pem",
    "https://[fd00::1]/a.pem",
    "https://[fc00::1]/a.pem",
    "https://[fe80::1]/a.pem",
    "https://[ff02::1]/a.pem",
    "https://[0:0:0:0:0:0:0:1]/a.pem",
    "https://[::ffff:127.0.0.1]/a.pem",
    "https://[::ffff:169.254.169.254]/a.pem",
  ]
  list.each(refused, fn(url) {
    assert x5u.fetch(transport, url, 100) == Error(x5u.BadUrl)
  })
  assert drain(calls) == []

  // The spellings of an address that are not a dotted quad. The
  // resolver under the transport reads every one of them, so the
  // policy reads them with `inet:parse_address` rather than with four
  // dots of its own, and refuses a host written any way but the one
  // canonical way whatever it decodes to.
  let spellings = [
    "https://127.1/a.pem",
    "https://127.0.1/a.pem",
    "https://2130706433/a.pem",
    "https://0x7f000001/a.pem",
    "https://0177.0.0.1/a.pem",
    "https://127.0.0.1./a.pem",
    "https://10.1/a.pem",
    "https://167772161/a.pem",
    "https://169.254.43518/a.pem",
    // A public address written the same crooked way: still refused,
    // because nothing legitimate writes a host as one long number.
    "https://134744072/a.pem",
    "https://[fe80::1%25eth0]/a.pem",
    "https://[::ffff:7f00:1]/a.pem",
  ]
  list.each(spellings, fn(url) {
    assert x5u.fetch(transport, url, 100) == Error(x5u.BadUrl) as url
  })
  assert drain(calls) == []

  // A name that ends in the root dot is a name, and is fetched.
  assert x5u.fetch(transport, "https://signer.test./a.pem", 100)
    != Error(x5u.BadUrl)
  // And a URL whose bytes are not text at all is refused rather than
  // raising: the `x5u` is a binary off the wire.
  assert x5u.fetch(transport, not_text(), 100) == Error(x5u.BadUrl)

  // A name, a routable literal and the default port written out are not
  // refused by the policy; the fake has nothing at any of them, which is
  // an answer and not a refusal.
  let allowed = [
    "https://signer.test/a.pem",
    "https://signer.test:443/a.pem",
    "https://8.8.8.8/a.pem",
    "https://172.32.0.1/a.pem",
    "https://100.63.255.255/a.pem",
    "https://[2606:4700::1111]/a.pem",
  ]
  list.each(allowed, fn(url) {
    assert x5u.fetch(transport, url, 100) != Error(x5u.BadUrl)
  })
  assert x5u.fetch(transport, "https://signer.test/b.pem", 100)
    == Error(x5u.NotACertificate(404))
}

pub fn fetch_and_cache_test() {
  x5u.clear()
  let chain = fixture("example-999Y-chain.pem")
  let calls = process.new_subject()
  let transport = fake([#(cert_url, ok(200, chain))], calls, timeouts: [])
  assert x5u.fetch(transport, cert_url, 100) == Ok(chain)
  // The second fetch is answered from the cache: no call.
  assert x5u.fetch(transport, cert_url, 100) == Ok(chain)
  assert drain(calls) == [cert_url]
  // Forgotten, it is fetched again.
  x5u.forget(cert_url)
  assert x5u.fetch(transport, cert_url, 100) == Ok(chain)
  assert drain(calls) == [cert_url]
  // Cleared, the same.
  x5u.clear()
  assert x5u.fetch(transport, cert_url, 100) == Ok(chain)
  assert drain(calls) == [cert_url]
}

pub fn negative_cache_test() {
  x5u.clear()
  let url = "https://signer.test/certs/missing.pem"
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  assert x5u.fetch(transport, url, 100) == Error(x5u.NotACertificate(404))
  // Not retried for a while, and the transport is not asked.
  assert x5u.fetch(transport, url, 100) == Error(x5u.RecentlyFailed)
  assert drain(calls) == [url]
  // `forget` clears the failure too.
  x5u.forget(url)
  assert x5u.fetch(transport, url, 100) == Error(x5u.NotACertificate(404))
  assert drain(calls) == [url]
}

pub fn not_a_certificate_test() {
  x5u.clear()
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #("https://signer.test/html", ok(200, "<html>not a certificate</html>")),
        #("https://signer.test/key", ok(200, fixture("test-key-pub.pem"))),
        #("https://signer.test/gone", ok(410, fixture("test-cert.pem"))),
      ],
      calls,
      timeouts: [],
    )
  assert x5u.fetch(transport, "https://signer.test/html", 100)
    == Error(x5u.NotACertificate(200))
  assert x5u.fetch(transport, "https://signer.test/key", 100)
    == Error(x5u.NotACertificate(200))
  // A certificate body under another status is not taken either.
  assert x5u.fetch(transport, "https://signer.test/gone", 100)
    == Error(x5u.NotACertificate(410))
}

/// A body with the marker on it but nothing `public_key` can read is not
/// cached for a day: a poisoned entry would outlive the call it came in
/// on.
pub fn unparseable_certificate_test() {
  x5u.clear()
  let url = "https://signer.test/certs/garbage.pem"
  let calls = process.new_subject()
  let poisoned =
    "-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydGlmaWNhdGU=\n-----END CERTIFICATE-----\n"
  let transport = fake([#(url, ok(200, poisoned))], calls, timeouts: [])
  assert x5u.fetch(transport, url, 100) == Error(x5u.NotACertificate(200))
  // It went into the negative cache, not the certificate cache.
  assert x5u.fetch(transport, url, 100) == Error(x5u.RecentlyFailed)
  x5u.forget(url)
  assert x5u.fetch(transport, url, 100) == Error(x5u.NotACertificate(200))
}

/// A body above the cap is refused before anything is parsed. The peer
/// picks the size, and a chain is two kilobytes.
pub fn body_cap_test() {
  x5u.clear()
  let url = "https://signer.test/certs/huge.pem"
  let calls = process.new_subject()
  let chain = fixture("example-999Y-chain.pem")
  let huge = chain <> string.repeat("x", x5u.max_body_bytes)
  let transport = fake([#(url, ok(200, huge))], calls, timeouts: [])
  assert x5u.fetch(transport, url, 100) == Error(x5u.TooLarge)
  assert x5u.fetch(transport, url, 100) == Error(x5u.RecentlyFailed)
  // Just under the cap and still a certificate: fetched, and what is
  // kept is the certificates, not the padding around them.
  let under = "https://signer.test/certs/padded.pem"
  let padding = string.repeat("# padding\n", 100)
  let transport =
    fake([#(under, ok(200, padding <> chain))], calls, timeouts: [])
  assert x5u.fetch(transport, under, 100) == Ok(chain)
}

/// A body that is mostly not a certificate costs the cache what the
/// certificates in it weigh, and nothing else: the answer is the
/// `CERTIFICATE` blocks, re-emitted, cached or fresh alike.
pub fn only_the_certificates_are_kept_test() {
  x5u.clear()
  let chain = fixture("example-999Y-chain.pem")
  let url = "https://signer.test/certs/padded-hard.pem"
  let calls = process.new_subject()
  // A quarter of a megabyte of nothing, wrapped around the chain.
  let noise = string.repeat("x", 120_000)
  let body =
    noise <> chain <> "\n# and a trailer\n" <> string.repeat("y", 100_000)
  let transport = fake([#(url, ok(200, body))], calls, timeouts: [])
  assert x5u.fetch(transport, url, 100) == Ok(chain)
  // The second answer is the cache, and it is the same bytes.
  assert x5u.fetch(transport, url, 100) == Ok(chain)
  assert drain(calls) == [url]
  // A body whose block never ends holds no certificate at all.
  let truncated = "https://signer.test/certs/truncated.pem"
  let transport =
    fake(
      [
        #(truncated, ok(200, "-----BEGIN CERTIFICATE-----\nMIIDHzCCAsSg\n")),
      ],
      calls,
      timeouts: [],
    )
  assert x5u.fetch(transport, truncated, 100) == Error(x5u.NotACertificate(200))
  assert x5u.certificates("nothing here") == ""
  assert x5u.certificates(chain) == chain
}

/// `kazoo/cache` evicts nothing on its own, so the table is bounded
/// here: past `max_entries` the oldest URL is dropped and the newest is
/// kept, and `size` says so. There is no index list any more -- two
/// concurrent inserts used to lose each other's keys out of it, and a
/// lost key was a row nothing would ever evict.
pub fn cache_is_bounded_test() {
  x5u.clear()
  let chain = fixture("test-cert.pem")
  let calls = process.new_subject()
  let url = fn(n) { "https://signer.test/bound/" <> int.to_string(n) <> ".pem" }
  let count = x5u.max_entries + 8
  let ns = list.reverse(down_from(count))
  let routes = list.map(ns, fn(n) { #(url(n), ok(200, chain)) })
  let transport = fake(routes, calls, timeouts: [])
  list.each(ns, fn(n) {
    assert x5u.fetch(transport, url(n), 100) == Ok(chain)
  })
  assert list.length(drain(calls)) == count
  // The table itself is inside its bound, which is what the row count
  // says rather than what a bookkeeping list believes.
  assert x5u.size() <= x5u.max_entries
  // The newest are still cached: no call for them.
  assert x5u.fetch(transport, url(count), 100) == Ok(chain)
  assert x5u.fetch(transport, url(count - 1), 100) == Ok(chain)
  assert drain(calls) == []
  // The oldest were evicted, so they are fetched again.
  assert x5u.fetch(transport, url(1), 100) == Ok(chain)
  assert drain(calls) == [url(1)]
  assert x5u.size() <= x5u.max_entries
  // A sweep of a table inside its bound with nothing stale in it drops
  // nothing, and is what the monitor calls every pass.
  assert x5u.sweep() == 0
  x5u.clear()
  assert x5u.size() == 0
}

/// The negative cache is bounded the same way, and by the same means.
pub fn the_negative_cache_is_bounded_test() {
  x5u.clear()
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  let url = fn(n) { "https://signer.test/gone/" <> int.to_string(n) <> ".pem" }
  list.each(list.reverse(down_from(x5u.max_entries + 4)), fn(n) {
    assert x5u.fetch(transport, url(n), 100) == Error(x5u.NotACertificate(404))
  })
  assert x5u.failed_size() <= x5u.max_entries
  x5u.clear()
}

pub fn transport_failure_test() {
  x5u.clear()
  let url = "https://signer.test/down.pem"
  let calls = process.new_subject()
  let transport =
    fake([#(url, Error(http.Transport("timeout")))], calls, timeouts: [])
  assert x5u.fetch(transport, url, 100)
    == Error(x5u.Fetch(http.Transport("timeout")))
  assert x5u.fetch(transport, url, 100) == Error(x5u.RecentlyFailed)
  assert drain(calls) == [url]
}

pub fn timeout_is_passed_on_test() {
  x5u.clear()
  let calls = process.new_subject()
  let timeouts = process.new_subject()
  let transport =
    fake([#(cert_url, ok(200, fixture("test-cert.pem")))], calls, timeouts: [
      timeouts,
    ])
  let assert Ok(_) = x5u.fetch(transport, cert_url, 1500)
  assert drain(timeouts) == [1500]
}

/// A URL with bytes in it that are not UTF-8, which is what an
/// `Identity` header can carry and what `gleam/string` raises on.
fn not_text() -> String {
  "https://signer.test/" <> unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
}

@external(erlang, "erlang", "iolist_to_binary")
fn unsafe_string(bytes: BitArray) -> String

/// `n` down to 1; `gleam/list` has no `range`.
fn down_from(n: Int) -> List(Int) {
  case n {
    0 -> []
    _ -> [n, ..down_from(n - 1)]
  }
}
