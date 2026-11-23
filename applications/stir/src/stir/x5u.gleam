//// Fetching the certificate an `Identity` header points at, with a cache.
////
//// A verifier must cache a fetched certificate for 24 hours (ATIS-1000074
//// §5.3.1); a failed fetch is remembered for a short while so a burst of
//// calls from one bad signer does not become a burst of requests. The
//// cache is node-local (`kazoo/cache`): one table for the certificates,
//// one for the URLs that failed, both keyed by the URL.
////
//// **The URL is the attacker's.** It arrives in a header on an inbound
//// call, so it is fetched only when `allowed` says so: `https`, no
//// userinfo, no port or port 443 (`:443`, `:0443` and the empty `:` are
//// the same port to RFC 3986 and to the transport), and, when the host
//// is an IP literal, not one on a network this node has no business
//// being pointed at -- loopback, RFC 1918, 169.254/16, 100.64/10,
//// multicast and above, the unspecified address; for IPv6 the
//// unspecified address, loopback, `fc00::/7`, `fe80::/10`, `ff00::/8`
//// and the IPv4 addresses above wearing an `::ffff:` prefix. A hostname
//// is allowed and is not resolved here: the TLS hostname check binds the
//// answer to the name, so an attacker who does not hold a certificate
//// for the name gets nothing.
////
//// **What counts as an IP literal is OTP's answer, not this module's.**
//// The host is handed to `inet:parse_address/1`, which is the family of
//// spellings the resolver underneath the transport accepts: `127.1`,
//// `0x7f000001`, `2130706433` and `0177.0.0.1` are all the loopback to
//// it, and a policy that read dotted quads only let every one of them
//// through. A host OTP parses at all is then refused unless it is
//// *also* written canonically (`inet:parse_strict_address/1`) and
//// routable: an `x5u` that spells its host as a 32-bit integer is not a
//// certificate server, it is someone trying spellings. A trailing root
//// dot is stripped before the check, since the resolver treats
//// `127.0.0.1.` as the address and `parse_address` does not.
////
//// The residual is DNS rebinding: a name whose owner points it at
//// 127.0.0.1 and holds a certificate for that name. It buys one `GET` of
//// a loopback address whose body never reaches the attacker (it has to
//// parse as a certificate to be answered at all, and the verdict is a
//// yes or a no). Closing it needs resolution and connection to be one
//// step with the address checked in between, which `httpc` does not
//// offer; if it ever matters, the place for it is the `stir_ffi`
//// transport, not here.
////
//// **Only the certificates are kept.** What is stored and answered is
//// the `CERTIFICATE` blocks of the body, re-emitted and nothing else, so
//// a server that pads a two-kilobyte chain out to the body cap costs the
//// cache two kilobytes rather than a quarter of a megabyte.
////
//// **The tables are bounded.** `kazoo/cache` evicts nothing on its own,
//// so a fetch that has to store something sweeps the table it stored in
//// when that table is over `max_entries`: `cache.sweep` drops what has
//// gone stale and then the oldest rows, atomically, from whichever
//// process noticed. The monitor sweeps both tables every pass as well,
//// so a node that stopped fetching does not hold yesterday's rows. There
//// is no index list: the one there used to be was a read-modify-write
//// two concurrent fetches could lose each other's keys in, and a lost
//// key was a row nothing would ever evict.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import kazoo/cache
import stir/http.{type Transport}

pub type Error {
  /// Not https, or a URL the address policy refuses.
  BadUrl
  Fetch(http.Error)
  /// The server answered, but not with a certificate.
  NotACertificate(status: Int)
  /// The answer is above `max_body_bytes`.
  TooLarge
  /// A recent fetch of this URL failed; not retried yet.
  RecentlyFailed
}

pub const ttl_ms = 86_400_000

pub const negative_ttl_ms = 60_000

/// The most a certificate answer may weigh. A SHAKEN chain is two
/// kilobytes; a quarter of a megabyte is room for any chain and for none
/// of the bodies an attacker would rather this node read.
pub const max_body_bytes = 262_144

/// The most URLs either table holds.
pub const max_entries = 2048

/// The certificates, PEM text by URL.
const table = "stir_x5u"

/// The URLs whose last fetch failed, `Nil` by URL.
const failed_table = "stir_x5u_failed"

const certificate_marker = "-----BEGIN CERTIFICATE-----"

const certificate_end = "-----END CERTIFICATE-----"

/// The certificate chain (PEM) at `url`, from the cache or fetched within
/// `timeout_ms`. What comes back is the certificate blocks of the answer
/// and nothing else, cached or fresh alike.
pub fn fetch(
  transport: Transport,
  url: String,
  timeout_ms: Int,
) -> Result(String, Error) {
  case allowed(url) {
    False -> Error(BadUrl)
    True ->
      case cache.get_fresh(table, url, ttl_ms) {
        Ok(pem) -> Ok(pem)
        Error(Nil) ->
          case cache.get_fresh(failed_table, url, negative_ttl_ms) {
            Ok(Nil) -> Error(RecentlyFailed)
            Error(Nil) ->
              case download(transport, url, timeout_ms) {
                Ok(pem) -> {
                  cache.put_fresh(table, url, pem)
                  bound(table, ttl_ms)
                  Ok(pem)
                }
                Error(error) -> {
                  cache.put_fresh(failed_table, url, Nil)
                  bound(failed_table, negative_ttl_ms)
                  Error(error)
                }
              }
          }
      }
  }
}

/// Forget one URL, or everything.
pub fn forget(url: String) -> Nil {
  cache.delete(table, url)
  cache.delete(failed_table, url)
}

pub fn clear() -> Nil {
  cache.clear(table)
  cache.clear(failed_table)
}

// ---------------------------------------------------------------------------
// Keeping the tables bounded
// ---------------------------------------------------------------------------

/// How many URLs the certificate cache holds, fresh or stale.
pub fn size() -> Int {
  cache.size(table)
}

/// The same for the URLs whose last fetch failed.
pub fn failed_size() -> Int {
  cache.size(failed_table)
}

/// Drop what has gone stale in both tables and trim either back to
/// `max_entries`, oldest first; how many rows went. The monitor calls
/// this every pass, and a fetch calls it for the table it just wrote
/// when that table is over the bound.
pub fn sweep() -> Int {
  cache.sweep(table, ttl_ms, max_entries)
  + cache.sweep(failed_table, negative_ttl_ms, max_entries)
}

fn bound(table: String, ttl_ms: Int) -> Nil {
  case cache.size(table) > max_entries {
    False -> Nil
    True -> {
      let _dropped = cache.sweep(table, ttl_ms, max_entries)
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// The fetch
// ---------------------------------------------------------------------------

fn download(
  transport: Transport,
  url: String,
  timeout_ms: Int,
) -> Result(String, Error) {
  case http.get(transport, url, timeout_ms) {
    Error(error) -> Error(Fetch(error))
    Ok(response) ->
      case byte_size(response.body) > max_body_bytes {
        True -> Error(TooLarge)
        False ->
          case
            response.status,
            string.contains(response.body, certificate_marker),
            is_utf8(response.body)
          {
            // A PEM whose first certificate does not parse is not cached
            // for a day: a poisoned entry would outlive the call it
            // arrived on. What is parsed is what is kept, so nothing
            // that failed to parse can be answered later.
            200, True, True -> {
              let pem = certificates(response.body)
              case certificate_info(pem) {
                Ok(_info) -> Ok(pem)
                Error(_why) -> Error(NotACertificate(200))
              }
            }
            status, _, _ -> Error(NotACertificate(status))
          }
      }
  }
}

/// The `CERTIFICATE` blocks of a PEM body, in order, each ending in one
/// newline: everything between and around them is dropped. A body that
/// holds none is `""`.
pub fn certificates(body: String) -> String {
  body
  |> string.split(certificate_marker)
  |> list.drop(1)
  |> list.filter_map(fn(rest) {
    case string.split_once(rest, certificate_end) {
      Ok(#(inside, _after)) ->
        Ok(certificate_marker <> inside <> certificate_end <> "\n")
      Error(Nil) -> Error(Nil)
    }
  })
  |> string.concat
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

/// Whether the text is what a `String` promises to be. A body off the
/// wire and a URL out of a SIP header are binaries, and `gleam/string`
/// raises on bytes that are not UTF-8.
fn is_utf8(text: String) -> Bool {
  case bit_array.to_string(bit_array.from_string(text)) {
    Ok(_text) -> True
    Error(Nil) -> False
  }
}

// ---------------------------------------------------------------------------
// The address policy
// ---------------------------------------------------------------------------

/// Whether the URL may be fetched at all. See the module doc.
fn allowed(url: String) -> Bool {
  case is_utf8(url) {
    False -> False
    True ->
      case uri.parse(url) {
        Error(Nil) -> False
        Ok(parsed) -> {
          let https = case parsed.scheme {
            Some(scheme) -> string.lowercase(scheme) == "https"
            None -> False
          }
          let port_allowed = case parsed.port {
            None | Some(443) -> True
            Some(_other) -> False
          }
          let host = option.unwrap(parsed.host, "")
          https
          && port_allowed
          && parsed.userinfo == None
          && host != ""
          && !refused_address(host)
        }
      }
  }
}

/// Whether the host is an address rather than a name, and one nothing
/// outside this node should be able to aim it at. A name is not one, and
/// is not resolved here.
fn refused_address(host: String) -> Bool {
  let text = normalised(host)
  case address(text) {
    Error(Nil) -> False
    // A literal written the long way round -- `127.1`, `0x7f000001`,
    // `0177.0.0.1` -- is refused whatever it decodes to: the spellings
    // exist to get past a policy, and no certificate server needs one.
    Ok(fields) -> !canonical(text) || refused_fields(fields)
  }
}

/// The host with its brackets, its case and one trailing root dot taken
/// off: `[::1]`, `::1` and `127.0.0.1.` are the addresses they resolve
/// to, whatever they are written as.
fn normalised(host: String) -> String {
  let text =
    string.lowercase(host)
    |> string.replace("[", "")
    |> string.replace("]", "")
  case string.ends_with(text, ".") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}

fn refused_fields(fields: List(Int)) -> Bool {
  case fields {
    [_, _, _, _] -> refused_ipv4(fields)
    [_, _, _, _, _, _, _, _] -> refused_ipv6(fields)
    // Not an address shape this knows: nothing is fetched from it.
    _ -> True
  }
}

fn refused_ipv4(octets: List(Int)) -> Bool {
  case octets {
    // 0.0.0.0/8, the unspecified address and "this network".
    [0, _, _, _] -> True
    [10, _, _, _] -> True
    [127, _, _, _] -> True
    [169, 254, _, _] -> True
    [172, second, _, _] if second >= 16 && second <= 31 -> True
    [192, 168, _, _] -> True
    [100, second, _, _] if second >= 64 && second <= 127 -> True
    // 224/4 multicast, 240/4 reserved, and the broadcast address.
    [first, _, _, _] if first >= 224 -> True
    _ -> False
  }
}

fn refused_ipv6(groups: List(Int)) -> Bool {
  case groups {
    [0, 0, 0, 0, 0, 0, 0, 0] -> True
    [0, 0, 0, 0, 0, 0, 0, 1] -> True
    // ::ffff:a.b.c.d, an IPv4 address in disguise.
    [0, 0, 0, 0, 0, 0xffff, high, low] ->
      refused_ipv4([high / 256, high % 256, low / 256, low % 256])
    [first, ..] if first >= 0xfc00 && first <= 0xfdff -> True
    [first, ..] if first >= 0xfe80 && first <= 0xfebf -> True
    [first, ..] if first >= 0xff00 -> True
    _ -> False
  }
}

/// The address OTP reads out of the host, in every spelling it accepts.
fn address(text: String) -> Result(List(Int), Nil) {
  fields(parse_address(charlist(text)))
}

/// Whether the host is the one spelling of that address OTP calls
/// strict: a dotted quad of plain decimals, or an IPv6 literal.
fn canonical(text: String) -> Bool {
  fields(parse_strict_address(charlist(text))) |> result.is_ok
}

fn fields(parsed: Result(Dynamic, Dynamic)) -> Result(List(Int), Nil) {
  case parsed {
    Error(_einval) -> Error(Nil)
    Ok(address) ->
      tuple_to_list(address)
      |> list.try_map(fn(field) {
        decode.run(field, decode.int) |> result.replace_error(Nil)
      })
  }
}

fn charlist(text: String) -> List(Int) {
  string.to_utf_codepoints(text)
  |> list.map(string.utf_codepoint_to_int)
}

@external(erlang, "inet", "parse_address")
fn parse_address(host: List(Int)) -> Result(Dynamic, Dynamic)

@external(erlang, "inet", "parse_strict_address")
fn parse_strict_address(host: List(Int)) -> Result(Dynamic, Dynamic)

@external(erlang, "erlang", "tuple_to_list")
fn tuple_to_list(tuple: Dynamic) -> List(Dynamic)

@external(erlang, "stir_ffi", "certificate_info")
fn certificate_info(chain_pem: String) -> Result(String, String)
