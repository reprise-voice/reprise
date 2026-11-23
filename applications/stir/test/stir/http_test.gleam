//// `stir/http`: the transport type, `get`, and the real transport's
//// refusals. Also the fake transport the other suites inject: a table of
//// URL to answer, recording every call on a subject so a test can count
//// them.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/string
import gleam/uri
import stir/http as stir_http

pub fn get_builds_a_get_test() {
  let calls = process.new_subject()
  let transport =
    fake(
      [#("https://example.test/a.pem", ok(200, "hello"))],
      calls,
      timeouts: [],
    )
  let assert Ok(response) =
    stir_http.get(transport, "https://example.test/a.pem", 1234)
  assert response.status == 200
  assert response.body == "hello"
  assert drain(calls) == ["https://example.test/a.pem"]
}

pub fn get_passes_the_timeout_test() {
  let calls = process.new_subject()
  let timeouts = process.new_subject()
  let transport = fake([], calls, timeouts: [timeouts])
  let assert Ok(_) = stir_http.get(transport, "https://example.test/", 4321)
  assert drain(timeouts) == [4321]
}

pub fn get_refuses_a_non_url_test() {
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  assert stir_http.get(transport, "nope", 100)
    == Error(stir_http.Transport("not an http(s) URL: nope"))
  assert stir_http.get(transport, "ftp://example.test/x", 100)
    == Error(stir_http.Transport("not an http(s) URL: ftp://example.test/x"))
  assert drain(calls) == []
}

/// A URL whose bytes are not text is refused before anything parses
/// it: the `x5u` of an inbound call is a binary off the wire, and
/// `uri.parse` raises rather than answering on bytes that are not
/// UTF-8.
pub fn get_refuses_bytes_that_are_not_text_test() {
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  let url = "https://example.test/" <> unsafe_string(<<0xff, 0xfe, 0x80, 0x41>>)
  assert stir_http.get(transport, url, 100)
    == Error(stir_http.Transport("not an http(s) URL: it is not text"))
  assert drain(calls) == []
}

pub fn unknown_url_is_a_404_test() {
  let calls = process.new_subject()
  let transport = fake([], calls, timeouts: [])
  let assert Ok(response) =
    stir_http.get(transport, "https://example.test/missing", 100)
  assert response.status == 404
}

pub fn a_transport_error_is_passed_through_test() {
  let calls = process.new_subject()
  let transport =
    fake(
      [
        #(
          "https://example.test/down",
          Error(stir_http.Transport("econnrefused")),
        ),
      ],
      calls,
      timeouts: [],
    )
  assert stir_http.get(transport, "https://example.test/down", 100)
    == Error(stir_http.Transport("econnrefused"))
}

/// The real transport is `GET` only, https only, and a port nothing
/// listens on is a transport error rather than a crash.
pub fn real_transport_test() {
  let real = stir_http.real()
  let assert Ok(req) = request.to("https://127.0.0.1:9/")
  let assert Error(stir_http.Transport(refused)) = real(req, 300)
  assert string.contains(refused, "econnrefused")
    || string.contains(refused, "timeout")
    || string.contains(refused, "closed")
  assert real(request.set_method(req, http.Post), 300)
    == Error(stir_http.Transport("only GET is supported"))
  // Plain http never gets as far as a connection.
  let assert Ok(plain) = request.to("http://127.0.0.1:9/")
  let assert Error(stir_http.Transport(_)) = real(plain, 300)
}

// ---------------------------------------------------------------------------
// The fake transport
// ---------------------------------------------------------------------------

/// A transport over a table of URL to answer. Every call sends its URL on
/// `calls` and its timeout on each of `timeouts`; a URL not in the table
/// is a 404.
pub fn fake(
  routes: List(#(String, Result(Response(String), stir_http.Error))),
  calls: Subject(String),
  timeouts timeouts: List(Subject(Int)),
) -> stir_http.Transport {
  fn(req, timeout_ms) {
    let url = uri.to_string(request.to_uri(req))
    process.send(calls, url)
    list.each(timeouts, process.send(_, timeout_ms))
    case list.key_find(routes, url) {
      Ok(answer) -> answer
      Error(Nil) -> ok(404, "no such fixture: " <> url)
    }
  }
}

pub fn ok(
  status: Int,
  body: String,
) -> Result(Response(String), stir_http.Error) {
  Ok(response.Response(status:, headers: [], body:))
}

/// Everything sent on the subject so far, oldest first.
pub fn drain(subject: Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> [item, ..drain(subject)]
    Error(Nil) -> []
  }
}

pub fn fixture(name: String) -> String {
  let assert Ok(bytes) = read_file("test/fixtures/" <> name)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

/// The DER bytes of the first PEM block in a fixture, as the `String` a
/// transport answers a binary body in. A Gleam string is a binary on the
/// BEAM, which is what lets a DER answer be modelled at all.
pub fn der_of(pem: String) -> String {
  let assert [_, rest, ..] = string.split(pem, "-----\n")
  let assert [base64, ..] = string.split(rest, "\n-----END")
  let assert Ok(der) = bit_array.base64_decode(string.replace(base64, "\n", ""))
  unsafe_string(der)
}

@external(erlang, "erlang", "iolist_to_binary")
fn unsafe_string(bytes: BitArray) -> String

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)
