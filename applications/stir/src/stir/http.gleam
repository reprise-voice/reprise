//// Everything that goes over HTTPS: certificate fetches, the STI-PA list
//// and CRL. Behind one function type, so a test injects a transport and
//// never touches the network.
////
//// The real transport is https only, verifies the peer against the
//// system CA store, follows no redirects and reads a bounded body. It is
//// `stir_ffi:http_get/2`, not `gleam_httpc`: `httpc` needs `ssl` options
//// (`verify_peer`, the OS trust store, a hostname check) that
//// `gleam_httpc` does not expose, and `GET` is the only verb anything
//// here needs.
////
//// `get` builds the request from a URL string and refuses what is not an
//// http(s) URL at all; the `http://` half of that is the FFI's to
//// refuse, since a caller-supplied transport in a test is welcome to
//// answer anything.

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/uri

pub type Error {
  /// Could not connect, TLS failed, timed out: the text says which.
  Transport(String)
}

pub type Transport =
  fn(Request(String), Int) -> Result(Response(String), Error)

/// The real one: `httpc` with `verify_peer`, a timeout in milliseconds,
/// no redirects. The headers come back lowercased.
pub fn real() -> Transport {
  fn(req: Request(String), timeout_ms: Int) {
    case req.method {
      http.Get ->
        case http_get(uri.to_string(request.to_uri(req)), timeout_ms) {
          Ok(#(status, headers, body)) ->
            Ok(response.Response(status:, headers:, body:))
          Error(why) -> Error(Transport(why))
        }
      _ -> Error(Transport("only GET is supported"))
    }
  }
}

/// A `GET` of a URL as text.
///
/// The URL is checked to be text before it is parsed: a `String` on the
/// BEAM is a binary, `uri.parse` is written to Gleam's promise that it
/// holds UTF-8, and a URL out of a SIP header or a certificate
/// extension is bytes somebody else chose. Bytes that are not text
/// cannot be a URL, and are refused here rather than raising two calls
/// down.
pub fn get(
  transport: Transport,
  url: String,
  timeout_ms: Int,
) -> Result(Response(String), Error) {
  case text(url) {
    False -> Error(Transport("not an http(s) URL: it is not text"))
    True ->
      case request.to(url) {
        Ok(req) -> transport(req, timeout_ms)
        Error(Nil) -> Error(Transport("not an http(s) URL: " <> url))
      }
  }
}

fn text(url: String) -> Bool {
  case bit_array.to_string(bit_array.from_string(url)) {
    Ok(_url) -> True
    Error(Nil) -> False
  }
}

@external(erlang, "stir_ffi", "http_get")
fn http_get(
  url: String,
  timeout_ms: Int,
) -> Result(#(Int, List(#(String, String)), String), String)
