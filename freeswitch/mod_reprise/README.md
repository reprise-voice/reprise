# mod_reprise

An open FreeSWITCH module implementing the AMQP transport between
FreeSWITCH and Kazoo's `ecallmgr_extension`: the wire contract of 2600hz's
closed commercial `mod_com_kazoo`, recovered from the open Kazoo side and
verified against a live `ecallmgr_extension` with `tools/fs-contract-probe`.

The module loads, connects to a broker from a failover list, fetches and
parses its own `kazoo.conf` over AMQP, runs one consumer worker per
queue-bearing profile, advertises itself to kz_nodes, answers ecallmgr's
command stream, serves the switch's XML fetches, publishes the event
streams the event profiles describe, executes call-control commands,
produces CDRs and publishes presence dialog (BLF) updates. Kazoo callflows
route and drive calls on a FreeSWITCH running this module: bridges, DTMF,
hold, recording, conferences, metaflows (konami), voicemail, fax, the
`config` command, broker failover. The closed module's `dialog` and
`live-events` relays have no open consumer and are not implemented; RTCP
events are off by default (nothing in Kazoo reads them).

## Layout

- `src/reprise.h` — globals/types
- `src/mod_reprise.c` — module entry, bootstrap config (`reprise.conf`),
  CLI api
- `src/reprise_transport.c` — the transport thread: rabbitmq-c connection with
  multi-broker failover (patterns from FS's in-tree mod_amqp), targeted
  reply queue (Server-ID semantics), kazoo.conf fetch RPC, consume loop
  with reconnect; `reprise_amqp_publish_json` for every publisher
- `src/reprise_profiles.c` — parses the fetched kazoo.conf (brokers, amqp /
  event / fetch profiles, templates) into structs; `reprise profiles`
- `src/reprise_workers.c` — one consumer per queue-bearing amqp profile
  (own connection, declared exchanges, expanded queue + bindings, qos,
  reconnect); dispatches deliveries by profile and runs a per-iteration
  tick on the worker's own connection
- `src/reprise_node.c` — node identity (`freeswitch@<hostname -f>`), the
  kz_nodes advertise/heartbeat published from the nodes worker, and the
  `json_api node.info` document (also `json {"command":"node.info"}` on
  the CLI)
- `src/reprise_commands.c` — the `freeswitch.cmds.<core-uuid>` responder:
  version / api / bgapi (two-step, executed off-thread) / json_api,
  replies to Server-ID via `targeted` with Reply-To-PID + Msg-ID
- `src/reprise_fields.c` — the kazoo.conf `<definitions>` / `<fields>` /
  `<filters>` grammar (ported from mod_kazoo, extended for the closed
  module's additions) and the `${...}` expansion engine; renders a
  switch event into a kz_api document
- `src/reprise_publisher.c` — a mutex-guarded publish-only connection for
  the switch's own threads
- `src/reprise_fetch.c` — XML fetches served over AMQP: one search function
  over the fetch sections, document rendered through the profile's
  fields, published with the spec's routing key and the call-id hash
  header, reply matched by `message_id` on the fetch worker's queue
- `src/reprise_events.c` — event streams: every event of every event profile
  bound in the switch, filtered, rendered, keyed and queued to a
  per-amqp-profile publisher thread
- `src/reprise_presence.c` — KZ_PRESENCE_DIALOG: ecallmgr's (dead on this
  transport) presence publisher ported onto the core's PRESENCE_IN, so
  the served `presence` profile publishes BLF dialog updates for
  Kamailio's presence role
- `src/reprise_dptools.c`, `src/reprise_kzcommands.c`, `src/reprise_tweaks.c`,
  `src/reprise_endpoints.c`, `src/reprise_cdr.c` — OpenKazoo mod_kazoo's `kz_*`
  apps/APIs, channel tweaks, `kz` endpoint and KZ_CDR producer, ported
  as-is (`reprise_kz.h`, `reprise_kzutils.c` carry what they need);
  `kz_deliver_event` and the interaction timestamp/key are new
- `src/reprise_originate.c` — `kz_originate` / `kz_originate_cancel` /
  `kz_originate_list`, the API family every Kazoo-initiated originate
  goes through (ported from the community mod_kazoo in 2600hz's
  freeswitch-kazoo 20.23.6 package)
- `src/reprise_prompts.c` — the `prompt://` file interface: resolves Kazoo's
  prompt names through a configuration fetch, caches them, and plays
  them through `http_cache://` (mod_http_cache must be loaded); same
  origin
- `conf/reprise.conf.xml` — bootstrap config example (brokers + node name;
  everything else the module learns from the fetched kazoo.conf)
- `tests/` — unit tests (`make test`): the fields/filters grammar and
  renderer, the `${...}` expansion engine, the kazoo.conf parser (on a
  synthetic document and on the served one, `tests/fixtures`), routing
  keys, templates and the presence-dialog derivation, against
  libfreeswitch's minimal core with the in-tree test framework
- `ci/` — compile check + unit tests against FS 1.11.4 in the
  `reprise-freeswitch-dev` image (what CI runs); `ci/smoke/` the in-cluster
  smoke harness (image, sipp scenarios, load scripts, command escript)

## Building

Against the matching patched FreeSWITCH dev tree built by
`docker/freeswitch/Dockerfile` (needs `freeswitch.pc` and librabbitmq):

```
PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig make
```

Unit tests (same prerequisites; the binary links the module's objects
against libfreeswitch and runs in `tests/run`):

```
PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig make test
```

Without a local FreeSWITCH install, the `reprise-freeswitch-dev` image
(the freeswitch image's build stage, `docker/build.sh freeswitch-dev` from
the repository root) has everything (amd64; emulated on Apple silicon,
about a minute):

```
docker run --rm --platform linux/amd64 -v "$PWD":/usr/src/mod_reprise -w /usr/src/mod_reprise \
  -e PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig \
  reprise/reprise-freeswitch-dev:dev make test
```

The complete native call-path regression target is `make test-call-paths`
(113 tests). It includes simultaneous endpoint handoff, physical-leg CDRs,
pickup, transfer-event filtering, loopback replacement ownership, a digit
pressed during `kz_endless_playback` (published while the music plays) and
`record_session` through the rewrite (a short new recording is discarded, one
restarted under the same name appends to the file awaiting upload). These
suites also need the matching FreeSWITCH source tree; set `FS_SRCDIR` if it is
not `/usr/src/freeswitch`. The loopback test compiles the bridge implementation
with one scheduling boundary controlled to reproduce the captured ownership
race. CI runs this target against the matching dev image.

## Bootstrap settings (`reprise.conf`)

The module reads `com.kazoo.conf` (the file kazoo-configs-freeswitch
ships) if it exists, then `reprise.conf`, then `com_kazoo.conf`, the name
this module's file had before the module was renamed (logged at WARNING).

| param | default | meaning |
|---|---|---|
| `node-name` | `freeswitch@<hostname -f>` | what kz_nodes knows us as |
| `reconnect-interval-ms` | 2000 | broker reconnect pacing |
| `fetch-timeout-ms` | 3500 | kazoo.conf fetch RPC timeout |
| `advertise-interval-ms` | 5000 | kz_nodes heartbeat period (expires at 30 s) |
| `trace-fetch` | false | log every fetch document and reply at INFO |
| `presence-dialog` | true | fire KZ_PRESENCE_DIALOG from PRESENCE_IN (BLF) |
| `rtcp-events` | false | bind the rtcp profile's events and set `fire_rtcp_events`; off because nothing in Kazoo consumes the `rtcp` exchange and every leg would publish an unread event per report interval |

## Limits and deadlines

Compile-time constants in `src/reprise.h`; `reprise status` reports the
counters they drive.

| constant | value | what it bounds |
|---|---|---|
| `REPRISE_CONNECT_TIMEOUT_MS` | 5000 | TCP connect to a broker (every connection: transport, workers, publishers) |
| `REPRISE_RPC_TIMEOUT_MS` | 10000 | login, channel open, declares, binds, consume (rabbitmq-c's RPC timeout) |
| `REPRISE_SEND_TIMEOUT_MS` | 15000 | how long sent frames may sit unacknowledged (`TCP_USER_TIMEOUT`); rabbitmq-c publishes with no deadline of its own, so this is what fails a publisher whose broker stops reading |
| `REPRISE_MAX_COMMAND_BYTES` | 1 MiB | a command body; larger ones are dropped after consumption |
| `REPRISE_MAX_FETCH_REPLY_BYTES` | 4 MiB | a fetch reply body |
| `REPRISE_MAX_CONFIG_BYTES` | 8 MiB | the kazoo.conf document |
| `REPRISE_BG_JOBS_MAX` | 256 | `bgapi` jobs running at once, which for ecallmgr means simultaneous `kz_originate` attempts (each holds its job for the ring time); beyond it the request is answered `-ERR too many background jobs` |
| `REPRISE_STREAM_QUEUE_LEN` / `REPRISE_STREAM_QUEUE_BYTES` | 20000 / 64 MiB | events queued per stream while its publisher is away (count and body bytes; excess is dropped and counted) |
| `REPRISE_PROMPT_CACHE_MAX` | 4096 | resolved `prompt://` paths kept (expired entries are swept, the oldest evicted) |

The body caps bound what the module copies and parses, not what
rabbitmq-c allocates: the library sizes the buffer from the header frame
before the module sees the message, so the broker's `max_message_size`
is the limit that protects the process.

A fetch handler waits for the shared publisher at most until its own
fetch deadline; a publish stuck behind a stalled broker fails that fetch
instead of holding every fetch thread. Unload closes admission (no new
bgapi jobs, originates or configuration applies), joins the transport
thread, the workers and every bgapi job thread, cancels originates in
flight and waits for them, and only then frees the state they used.

### `kz_http_put` (recording upload)

Options read from the URL's `{…}` params, then from core globals:

| option | default | meaning |
|---|---|---|
| `kz_put_ssl_verify` | true | verify the store's certificate (peer and host name); `false` is logged at WARNING on every upload |
| `kz_put_cainfo` / `kz_put_capath` | system store | CA bundle / directory for a private store |
| `kz_put_connect_timeout_ms` | 10000 | TCP/TLS connect |
| `kz_put_timeout_ms` | 300000 | the whole transfer (0: unlimited) |
| `kz_put_disable_100_continue`, `kz_put_expect_100_timeout_ms`, `kz_put_use_curl_http_version` | – | as in freeswitch-kazoo 20.23.6 |

Only `http`/`https` URLs are accepted, redirects included (at most 5). A
transfer error, a TLS failure, a timeout, or a redirect that turned the
PUT into a GET all fail the command and keep the local file; it is
deleted only after a PUT that the store answered 200/201/202/204. The
API takes an arbitrary local path and URL: publishing to the command
queue is administrative access.

## Wire contract

`tools/fs-contract-probe` checks the contract against a running
`ecallmgr_extension`. The facts this module depends on:

- version string `mod_reprise v5.4.0 commercial` — the third token selects
  ecallmgr's node-module set; `commercial` = the AMQP transport
- all `freeswitch`-exchange routing keys carry a `freeswitch.` prefix
- config fetch: `freeswitch.configuration.fetch.<core-uuid>.<fetch-uuid>`,
  `Event-Name: GENERAL`, `Fetch-Version: commercial`,
  `Fetch-Key-Value: com.kazoo.conf`; reply is text/xml on the `targeted`
  queue named in `Server-ID`, `message_id` echoing `Fetch-UUID`
- kz_nodes advertise `Expires` is milliseconds; the freeswitch kapp's
  `Startup` is unix seconds; `Modules.loaded` claims `mod_sofia` so the
  monitor skips its node-start batch
- command replies address by `Reply-To-PID` and must be `API` /
  `BACKGROUND_JOB` / `json_api.reply`; bgapi's ack is `+OK<job-uuid>`
  byte-identical; `conference xml_list` must be XML
- fetch requests are the kazoo.conf fetch profiles rendered verbatim;
  `Fetch-Timeout` is microseconds; the dialplan fetch IS the route_req
- events are the event profiles rendered verbatim (`call.<EVENT>.<call-id>`
  on `callevt` with the `call-id` header); `pid://<pid>/<queue>` routing
  keys become queue + `Deliver-To-PID` header (ROUTE_WINNER)

## License

Copyright (C) 2026 Vonix LLC. The module is distributed under the Mozilla
Public License 2.0 (`LICENSE`). Files ported from FreeSWITCH's mod_kazoo
keep their original MPL 1.1 notices (Anthony Minessale II and the
mod_kazoo contributors, among them 2600Hz): `src/reprise_cdr.c`,
`src/reprise_dptools.c`, `src/reprise_endpoints.c`,
`src/reprise_kzcommands.c` and `src/reprise_tweaks.c`. Files that carry
portions of mod_kazoo (`src/reprise_fields.c`, `src/reprise_fields.h`,
`src/reprise_kzutils.c`, `src/reprise_originate.c`,
`src/reprise_prompts.c`) or of Kazoo's ecallmgr (`src/reprise_presence.c`)
say so in their headers.
