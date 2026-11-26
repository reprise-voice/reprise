# Coming from Kazoo 5.x

Notes for operators of an existing Kazoo 5.x cluster who are considering
Reprise.

**Read this first.** No in-place upgrade of a Kazoo cluster to Reprise has
been tested, and this tree contains no migration tooling for one. This page
lists what Reprise keeps compatible, what is different, and what is not
known. Treat any move as a migration to be rehearsed on a copy of your data,
not as a package upgrade.

## What stays the same

- **APIs.** The REST API (`crossbar`, `/v2/...`), the websocket API
  (`blackhole`), the AMQP message formats (`kapi_*`) and webhooks are the
  Kazoo 5.4 ones. Reprise adds endpoints (`queues`, `agents`, `stir`).
- **Database layout.** The same CouchDB databases, documents and views.
  Every node runs `kapps_maintenance:init_system()` at start, which creates
  missing system databases and updates the views it manages. New
  applications add their own databases (`stir`) and documents (call center
  queues in the account databases).
- **Configuration files and names.** `config.ini` keeps its format and
  paths (`/etc/kazoo/config.ini`, `/etc/kazoo/core/config.ini`), Erlang
  application and node names are unchanged (`kazoo_apps`, `ecallmgr`), and
  so are the `sup` commands and the `system_config` categories.
- **Erlang distribution over AMQP** (`amqp_dist`) and the `-proto_dist kz
  amqp` launcher arguments, as in Kazoo 5.
- **Monster UI.** The image builds Monster UI and its apps from the
  reprise-voice forks of the 2600Hz repositories.

## What is different

### FreeSWITCH and its module

- Reprise controls FreeSWITCH only through `mod_reprise`, an open
  implementation of the AMQP transport of 2600Hz's closed `mod_com_kazoo`.
  `mod_kazoo` (the Erlang node protocol) is not shipped in the
  `reprise-freeswitch` image, and its use with Reprise has not been
  tested.
- The ecallmgr node must also run `ecallmgr_extension`
  (`KAZOO_APPS=ecallmgr,ecallmgr_extension`). Nothing starts it
  automatically. When it starts it writes the node-module list it needs into
  `system_config/ecallmgr` (`configuration.commercial.modules`).
- `mod_reprise` reads its bootstrap settings from `com.kazoo.conf` (the file
  `configs/freeswitch` ships, as 2600Hz's configuration did), then from
  `reprise.conf`, then from `com_kazoo.conf`, logging a warning that the
  last should be renamed (`freeswitch/mod_reprise/src/mod_reprise.c`). An
  existing `com.kazoo.conf` with its `kazoo/connections` includes can
  therefore be kept. `modules.conf.xml` must load `mod_reprise`; the image's
  entrypoint rewrites a `mod_kazoo` or `mod_com_kazoo` load line.
- `mod_reprise` announces itself as `mod_reprise v5.4.0 commercial`; the
  third word is what selects ecallmgr's AMQP node-module set.
- The module is built against FreeSWITCH v1.11.4 with the patches in
  `docker/freeswitch/patches`. A module built for these patches refuses to
  load on an unpatched core (the `switch_kazoo_session_swap_v1` link guard).
  Whether it runs on 2600Hz's own FreeSWITCH builds has not been tested.
- Not implemented: the closed module's `dialog` and `live-events` relays.
  RTCP events are off by default (`rtcp-events`).

### Erlang/OTP 28

The release is built with OTP 28; upstream Kazoo 5.4 targeted OTP 26.
Running Reprise nodes and Kazoo nodes built on an older OTP in one Erlang
cluster (a rolling upgrade) has not been tested. The release also no longer
includes the GUI tools (`wx`, `observer`, `debugger`).

### The broker

- Reprise needs the `x-consistent-hash` exchange type, as Kazoo 5 does:
  RabbitMQ with `rabbitmq_consistent_hash_exchange`, or LavinMQ.
- The consistent-hash exchanges (`callflow.route`,
  `callmgr.route.<core-uuid>` and those in
  `core/kazoo_amqp/src/kz_event_listener.erl`) are declared with an
  additional `x-hash-on` argument beside `hash-header`. RabbitMQ refuses to
  redeclare an existing exchange with different arguments, so Reprise and
  Kazoo nodes declaring the same exchange on one broker are likely to
  conflict. This has not been tested; plan for a broker, or virtual host,
  that is not shared with old nodes.
- The call-id hash header on call events is now an AMQP string
  (`longstr`) rather than a byte array, which LavinMQ requires.
- `callcenter` is in the default application list and declares durable
  queues (`callcenter.member.<n>`, `callcenter.shards`, `callcenter.node.<node>`).
  See its [broker notes](../applications/callcenter/README.md#a-holder-that-stops-answering).

### Kamailio

The `reprise-kamailio` image runs Kamailio 6.1 from the reprise-voice fork
with `configs/kamailio`, which adds the files Kamailio 5.8 and later need
(`dispatcher-role-5.8.cfg` to `dispatcher-role-6.1.cfg`, among others) and
changes presence authorization (an authenticated device may only watch
presentities of its own account) and subscription expiry. The image uses
the in-process `db_kazoo` SQLite database, recreated at every start; the
PostgreSQL and MySQL configurations are still in `configs/kamailio` but are
not used by the image. Compare your `local.cfg` with
`docker/kamailio/local.cfg.tpl`.

### Changed defaults

These defaults pointed at 2600Hz domains or named 2600Hz; stored values and
explicit settings are not changed:

| Setting | Kazoo 5.4 default | Reprise default |
|---|---|---|
| `system_config/crossbar.accounts` `account_realm_suffix` (new accounts' generated realm) | `sip.2600hz.com` | `sip.example.com` |
| `system_config/kazoo_endpoint.mobile` `realm` | `mobile.k.zswitch.net` | `mobile.example.com` |
| `fax` `default_smtp_domain` (new faxbox addresses) | `fax.kazoo.io` | `fax.example.com` |
| FreeSWITCH SIP User-Agent (`sipinterface_1.xml`, ecallmgr's sofia configuration) | `2600Hz` / `2600hz` | `Reprise` |
| Kamailio `USER_AGENT` (`globals.cfg`) | `Kazoo` | `Reprise` |
| SNMP `sysContact` (`stats`) | a 2600Hz address | empty |

If your cluster relied on one of the old defaults without storing it, set
it explicitly before switching. If a carrier or peer filters on the
User-Agent, tell them or override it.

### Ringback for a caller not answered yet

Kazoo plays its default ringback (`system_config/ecallmgr`
`default_ringback`) to every caller while the call rings. Playing it
pre-answers the caller's leg, which settles its codec before the callee has
answered, so a G722 caller reaching a G.711 phone or carrier is transcoded
rather than answered on G.711. Reprise splits the setting: `default_ringback`
is now played only to callers not answered yet and is unset by default, and
the new `default_transfer_ringback` is played to callers already answered,
as before.

Kazoo stored `default_ringback` the first time it read it, so an existing
cluster has a value and keeps Kazoo's behaviour. See
[ringback.md](../applications/ecallmgr/doc/ringback.md) for what changes,
which callers may need a ringback played to them, and how to remove the
stored value.


- **Telemetry.** `kazoo_telemetry` and the `system_config.telemetry` and
  `system_config.telemetry.waveguide` schemas are gone. Documents it wrote
  into an existing cluster (those `system_config` documents and its alerts)
  are left in place and can be deleted.
- Kazoo 4.x-only applications and 2600Hz's separate developer tools
  (kazoo-ast, kazoo-properly) are not in this tree; `make apis` fetches
  kazoo-ast on demand.

### Added

- `ecallmgr_extension` and `mod_reprise` (above).
- `konami` (in-call metaflows), not started by default.
- `callcenter`, started by default.
- `stir`, not started by default.

## Not known

The following have not been tested and are not documented anywhere in this
tree:

- an in-place or rolling upgrade of a Kazoo 5.x cluster to Reprise;
- mixing Reprise and Kazoo Erlang nodes, or OTP 26 and OTP 28 nodes, in
  one cluster;
- sharing one broker between Reprise and Kazoo nodes;
- running `mod_reprise` on a FreeSWITCH other than the one the
  `reprise-freeswitch` image builds, or running ecallmgr against
  `mod_kazoo` or 2600Hz's `mod_com_kazoo`;
- reusing an existing Kamailio deployment's database or configuration with
  the `reprise-kamailio` image;
- the effect of `callcenter`'s default start on a cluster that already has
  documents of the same type from another source.

If you try any of these, please report what you find in the
[issue tracker](https://github.com/reprise-voice/reprise/issues).
