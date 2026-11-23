# Configuration reference

What an operator configures in a Reprise cluster, where each setting is
read, and the defaults in this tree. For how the parts fit together see
[architecture](architecture.md); for a working single-host example see
the [Compose quick start](../deploy/compose/README.md).

Configuration lives in four places:

1. `config.ini` on every Erlang node: how to reach the broker and CouchDB,
   the cookie, logging. Read once at start.
2. Environment variables of the container images.
3. `system_config` documents in CouchDB: everything else on the Erlang
   side, shared by the cluster, changed at run time with
   `sup kapps_config ...` or the `system_configs` API.
4. The FreeSWITCH and Kamailio configuration files from `configs/`.

## config.ini

### Where it is read from

`core/kazoo_config/src/kazoo_config_init.erl` reads the first of:

1. the file named by `KAZOO_CONFIG`, if that variable is set (only that
   file is tried);
2. `/etc/kazoo/config.ini`;
3. `/etc/kazoo/core/config.ini`.

If none can be read the node starts with built-in defaults
(`amqp://guest:guest@localhost:5672`, CouchDB on `localhost:5984`), which is
rarely what you want; the log says `out of config files to attempt`. The
`reprise` image sets `KAZOO_CONFIG=/etc/kazoo/config.ini`; mount the file
there, readable by UID 10001.

### Syntax

INI sections and `key = value` lines; `;` starts a comment. An unquoted value
ends at the first `=`, so quote any value that contains one, such as an AMQP
URI with query parameters: `uri = "amqp://user:pass@broker:5672?heartbeat=10"`.
The quotes are stripped from `uri`, `ip`, `host`, `zone` and `amqp_uri`
values. `true` and `false` become booleans.

A section can be limited to one host with `host = <hostname>`, or to one zone
with `zone = <zone>`; a section with neither applies everywhere.

### Sections read by this tree

| Section | Keys | Read by |
|---|---|---|
| `[amqp]` | `uri` (may be repeated, one per broker), `pool_size`, `pool_overflow`, `pool_threshold`, `pool_server_confirms`, `prefetch`, `kz_monitor_listeners` | `core/kazoo_amqp`, `core/kazoo_apps/src/kazoo_apps_sup.erl` |
| `[zone]` | `name`, `amqp_uri` (may be repeated). Several `[zone]` sections describe a multi-site cluster; when any is present they replace `[amqp]` for broker selection | `core/kazoo_amqp/src/kz_amqp_bootstrap.erl`, `kz_amqp_connections.erl` |
| `[data]` | `config`: the name of the section that describes the datastore (default `bigcouch`) | `core/kazoo_data/src/kz_dataconfig.erl` |
| the datastore section, e.g. `[couchdb3]` | `ip` (or `host`), `port`, `username`, `password`; other keys are passed to the CouchDB client as options | `core/kazoo_couch/src/kz_couch_util.erl` |
| `[kazoo_apps]` | `cookie`: the Erlang cookie for every node | `core/kazoo_apps/src/kazoo_apps_init.erl` |
| `[<node name>]`, e.g. `[ecallmgr]` | `cookie` (used when `[kazoo_apps]` has none), `zone` | `kazoo_apps_init.erl`, `core/kazoo_config/src/kz_config.erl` |
| `[log]` | `console`, `syslog`, `error`: log levels (`debug`, `info`, `notice`, `warning`, `error`, ...) | `kazoo_apps_init.erl` |

The cookie is taken from the `KAZOO_COOKIE` environment variable first, then
`[kazoo_apps] cookie`, then `[<node name>] cookie`; with none, the node
generates a random one and no other node can talk to it. The zone is taken
from `KAZOO_ZONE` first, then the node's section, then defaults to `local`.

A minimal file for a cluster with one broker and one CouchDB:

```ini
[amqp]
uri = "amqp://kazoo:secret@broker:5672?heartbeat=10"

[data]
config = couchdb3

[couchdb3]
ip = "couchdb"
port = 5984
username = admin
password = secret

[kazoo_apps]
cookie = change_me

[log]
console = info
syslog = none
error = error
```

`rel/ci.config.ini` and `core/kazoo_apps/doc/config_sample.ini` are further
examples in the tree. The `heartbeat=10` recommendation is explained in
[applications/callcenter/README.md](../applications/callcenter/README.md#a-holder-that-stops-answering).

### Release launcher files

The launcher (`rel/kazoo`, installed as `/opt/kazoo/bin/kazoo`) also looks in
`NODE_STARTUP_FILE_PATH` (default `/etc/kazoo/core`) for
`<KAZOO_NODE>.vm.args` or `vm.args`, and `<KAZOO_NODE>.sys.config` or
`sys.config`, and uses them instead of the release's own files when present.

## Container environment variables

These are the variables each image's entrypoint or software reads. Runtime
users and writable paths are in [docker/README.md](../docker/README.md).

### reprise (`docker/reprise`)

| Variable | Default | Meaning |
|---|---|---|
| `KAZOO_NODE` | `kazoo_apps` | Node name without the host part. The launcher appends `@<fully qualified hostname>`, so give the container a resolvable FQDN hostname; otherwise distribution fails with `nodistribution`. Do not include `@host` here. |
| `KAZOO_APPS` | unset | Comma- or space-separated applications to start. Unset: the node's `system_config/kapps_controller` setting, then an application named like the node (`ecallmgr` on a node called `ecallmgr`), then the cluster default. |
| `KAZOO_COOKIE` | unset | Erlang cookie; must be the same on every node. Also read by the launcher and by `sup`. |
| `KAZOO_ZONE` | unset | Zone of this node (default `local`). |
| `KAZOO_CONFIG` | `/etc/kazoo/config.ini` | Path of `config.ini`. |
| `NODE_STARTUP_FILE_PATH` | `/etc/kazoo/core` | Where the launcher looks for `vm.args` and `sys.config` overrides. |
| `ERL_EPMD_ADDRESS` | `127.0.0.1` | epmd listens on loopback only; it serves local `sup` connections. |
| `STIR_KEK`, `STIR_KEK_NEXT` | unset | The `stir` application's key-encryption key and its successor during a rotation ([STIR/SHAKEN guide](guides/stir-shaken.md)). |

An ecallmgr node is the same image with `KAZOO_NODE=ecallmgr` and
`KAZOO_APPS=ecallmgr,ecallmgr_extension`. `ecallmgr_extension` is not started
by anything else, and without it the node cannot control a FreeSWITCH running
`mod_reprise`.

### reprise-freeswitch (`docker/freeswitch`)

| Variable | Default | Meaning |
|---|---|---|
| `KZ_AMQP_HOST` | required (or `KZ_AMQP_HOSTS`) | Broker host. |
| `KZ_AMQP_HOSTS` | unset | `host[:port],host[:port],...`: a failover list. The first entry is the primary; each other entry gets its own connection file under `kazoo/connections/`. |
| `KZ_AMQP_PORT` | `5672` | Broker port. |
| `KZ_AMQP_USER`, `KZ_AMQP_PASS` | `kazoo`, `kazoo` | Broker credentials. Change them. |
| `KZ_AMQP_VHOST` | `/` | Broker virtual host. |
| `KZ_AMQP_ZONE` | `local` | Zone of this media server. |
| `LOCAL_IP` | detected | Address FreeSWITCH binds and uses toward Kamailio. Detected from the GCE metadata server when there is one, else `hostname -i`. |
| `PUBLIC_IP` | none (GCE metadata if present) | When set, written as `ext-sip-ip` and `ext-rtp-ip` of `sipinterface_1`, for 1:1 NAT. |
| `EXT_SIP_IP`, `EXT_RTP_IP` | `PUBLIC_IP` | Set one to advertise a different address for signalling or for media. `EXT_SIP_IP` is the address ecallmgr reports to Kamailio's dispatcher, so Kamailio must be able to reach it; `EXT_RTP_IP` goes into the SDP. The Compose quick start sets them apart: signalling on the bridge network, media on the host address. |
| `KAZOO_TRANSPORT` | `amqp` | Only `amqp` is accepted; the image ships no `mod_kazoo`. |

The media server's node name is `freeswitch@<hostname -f>`, so give the
container an FQDN hostname too. The RTP port range (16384-32768) is set in
`autoload_configs/switch.conf.xml` and has no environment variable.

### reprise-kamailio (`docker/kamailio`)

| Variable | Default | Meaning |
|---|---|---|
| `MY_AMQP_URL` | `amqp://guest:guest@127.0.0.1:5672` | Broker URL. Must be set in any real deployment. |
| `MY_HOSTNAME` | `hostname -f` | Server name in the configuration. |
| `MY_LOCAL_IP` | detected (GCE metadata, else `hostname -i`) | Address the listeners bind. |
| `MY_PUBLIC_IP` | `MY_LOCAL_IP` | Address advertised in Via, Record-Route and Contact. |
| `MY_WEBSOCKET_DOMAIN` | `MY_HOSTNAME` | Origin a secure-websocket client must present. |
| `KAM_TLS_DOMAIN` | unset | Use the Let's Encrypt certificate under `/etc/letsencrypt/live/<domain>/`; unset generates a self-signed certificate at each start. |
| `KAMAILIO_LOCAL_CFG_TEMPLATE` | `/local.cfg.tpl` | Alternative template for `local.cfg`. |
| `KAMAILIO_CHECK_CONFIG` | `0` | `1`: parse the configuration and exit. |

The entrypoint renders `local.cfg` from `docker/kamailio/local.cfg.tpl`,
which turns on the dispatcher, NAT traversal, registrar, presence, responder,
nodes, pusher, TLS and websockets roles, and recreates the `db_kazoo`
database at `/etc/kazoo/kamailio/db/kazoo.db` at every start. Its content
(registrations, subscriptions, the dispatcher list) is rebuilt by phones and
by Kazoo, so it is not persisted.

### reprise-monster-ui (`docker/monster-ui`)

| Variable | Default | Meaning |
|---|---|---|
| `CROSSBAR_UPSTREAM` | `http://kazoo-apps:8000` | Where nginx proxies `/v2/` (the REST API). |
| `BLACKHOLE_UPSTREAM` | `http://blackhole:5555` | Where nginx proxies `/socket` (the websocket API). Point it at the kazoo_apps node that runs `blackhole`. |

nginx listens on 8080. The image also carries the Monster UI app metadata in
`/opt/monster-apps`, for `sup crossbar_maintenance init_apps /opt/monster-apps`
on a kazoo_apps node that can read it.

## Which applications a node runs

`kapps_controller` (`core/kazoo_apps/src/kapps_controller.erl`) takes the
first of:

1. `KAZOO_APPS`;
2. `kapps` in the node's own section of `system_config/kapps_controller`;
3. the application whose name is the node name's first part, if there is
   one;
4. `kapps` in the default section of `system_config/kapps_controller`, else
   the built-in list in `core/kazoo_apps/src/kazoo_apps.hrl`: blackhole,
   callcenter, callflow, cdr, conference, crossbar, fax, hangups, media_mgr,
   milliwatt, omnipresence, pivot, registrar, reorder, stepswitch, sysconf,
   tasks, teletype, trunkstore, webhooks.

`konami`, `stir`, `jonny5`, `hotornot`, `doodle`, `pusher`, `stats` and
`call_inspector` are not in the built-in list. Add them to
`KAZOO_APPS` or start them on a running node with
`sup kapps_controller start_app <app>`. At every start a node also runs
`kapps_maintenance:init_system()`, which creates the system databases and
views, so a new cluster needs no separate database initialisation.

## system_config on day one

`system_config` documents are edited with
`sup kapps_config set_default <category> <key> <value>` (cluster-wide) or
`sup kapps_config set_node <category> <key> <value> <node>`, or through the
`/v2/system_configs` API. The settings a new cluster usually needs:

| Category and key | Why |
|---|---|
| ecallmgr ACLs, via `sup ecallmgr_maintenance allow_sbc <name> <ip> true` on the ecallmgr node | FreeSWITCH accepts calls only from addresses in the `authoritative` list. Add every Kamailio address. See below. |
| `crossbar.accounts` `account_realm_suffix` | New accounts get a random realm under this suffix (default `sip.example.com`). Set it to a domain whose names resolve to your SBCs, or give each account an explicit realm. |
| `media` `proxy_hostname` | FreeSWITCH fetches media from `http://<host>:24517`, where `<host>` defaults to the kazoo_apps node's own hostname. Set it if that name does not resolve from FreeSWITCH. |
| `kapps_controller` `kapps` | The cluster's default application list (see above). |
| `crossbar` `port` | REST API port (default 8000); `ssl_port` 8443 for TLS. |
| `callcenter` `shards` | Default 64; must be the same on every node. See the [call center guide](guides/callcenter.md). |
| `metaflows` | System-wide metaflow defaults ([metaflows guide](guides/metaflows.md)). |
| `stir` | Signing and verification switches, all off by default ([STIR/SHAKEN guide](guides/stir-shaken.md)). |

The schema of every category is in
`applications/crossbar/priv/couchdb/schemas/system_config.<category>.json`.

### ecallmgr ACLs

On the ecallmgr node:

```console
$ sup ecallmgr_maintenance allow_sbc kamailio 192.0.2.10 true
$ sup ecallmgr_maintenance allow_carrier my-carrier 198.51.100.0/24 true
$ sup ecallmgr_maintenance reload_acls
```

The third argument `true` stores the entry in the cluster default; without it
the entry is stored for the node the command runs on only. More commands are
in [applications/ecallmgr/doc/acls.md](../applications/ecallmgr/doc/acls.md).
SBC discovery from heartbeats exists in `ecallmgr_discovery` but is off by
default (`enable_discovery_server`).

FreeSWITCH servers need no registration with ecallmgr:
`ecallmgr_extension` adds each one it hears in the node heartbeats.
`sup ecallmgr_maintenance list_fs_nodes` shows them.

## FreeSWITCH and Kamailio configuration

- `configs/freeswitch/freeswitch` is installed as `/etc/kazoo/freeswitch`.
  Most of FreeSWITCH's configuration is not in these files: `mod_reprise`
  reads only its bootstrap settings from them and fetches the rest
  (`kazoo.conf`, sofia profiles, directory, dialplan) from ecallmgr over
  AMQP. The bootstrap file is `autoload_configs/com.kazoo.conf.xml`, which
  includes the broker connections from `kazoo/connections/`; the image's
  entrypoint fills those from the `KZ_AMQP_*` variables.
  `mod_reprise` reads `com.kazoo.conf` if it exists, then `reprise.conf`,
  then `com_kazoo.conf` (with a warning); its settings are listed in
  [freeswitch/mod_reprise/README.md](../freeswitch/mod_reprise/README.md#bootstrap-settings-repriseconf).
- `configs/kamailio/kamailio` is installed as `/etc/kazoo/kamailio`. Site
  settings go in `local.cfg`, which `kamailio.cfg` includes first, so its
  `#!define`s win over the `#!trydef`s in the role files. The image renders
  `local.cfg` from its environment.

The `system/` directories next to them hold the init, systemd and logrotate
files for a package installation.

## The AMQP broker

The tree declares and uses:

- `topic`, `fanout` and `direct` exchanges (`core/kazoo_amqp/include/kz_amqp.hrl`);
- exchange-to-exchange bindings (`callmgr` to `callflow.route`, `freeswitch`
  to `callmgr.route.<core-uuid>`);
- the **`x-consistent-hash`** exchange type
  (`core/kazoo_amqp/src/kz_event_listener.erl`,
  `applications/callflow/src/cf_listener.erl`,
  `applications/ecallmgr_extension/src/ecallmgr_fs_amqp_fetch_dialplan.erl`).
  The exchanges are declared with both `hash-header` (read by RabbitMQ's
  plugin) and `x-hash-on` (read by LavinMQ);
- the **`amq.headers`** exchange, for Erlang distribution (`vendor/amqp_dist`);
- queue arguments `x-message-ttl` and `x-max-length`.

So the broker must be **RabbitMQ with the `rabbitmq_consistent_hash_exchange`
plugin enabled** (`rabbitmq-plugins enable rabbitmq_consistent_hash_exchange`)
or **LavinMQ**, which has the exchange type built in. Code comments and
commit history refer to LavinMQ 2.9.3; the exact broker versions this
release was tested with are not recorded in the tree.

Broker settings that matter for `callcenter` (heartbeats; RabbitMQ's
`consumer_timeout`, which must not apply to the `callcenter.member.*`
queues) are in the
[call center README](../applications/callcenter/README.md#a-holder-that-stops-answering).

## CouchDB

`core/kazoo_couch/src/kz_couch_util.erl` recognises CouchDB 1.6, BigCouch,
2.x and 3.x, and treats any other version as 3.x. The examples in this tree
use a `[couchdb3]` section and an admin user (`username`, `password`); Kazoo
creates its own databases and views at start. The CouchDB version this
release was tested with is not recorded in the tree.

## Ports

Defaults in this tree:

| Component | Port | What |
|---|---|---|
| kazoo_apps (`crossbar`) | 8000/tcp (8443 with TLS) | REST API (`system_config/crossbar.port`, `ssl_port`) |
| kazoo_apps (`blackhole`) | 5555/tcp | Websocket API (`system_config/blackhole.port`) |
| kazoo_apps (`media_mgr`) | 24517/tcp | Media for FreeSWITCH (`system_config/media.proxy_port`) |
| Erlang nodes | 11500-11999/tcp on 127.0.0.1 | Local distribution for `sup` (`rel/vm.args`); epmd on 127.0.0.1:4369 |
| FreeSWITCH | 11000/udp+tcp, 11001/tcp TLS | SIP (`sip_profiles/sipinterface_1.xml`) |
| FreeSWITCH | 16384-32768/udp | RTP (`autoload_configs/switch.conf.xml`) |
| Kamailio | 5060/udp+tcp | SIP |
| Kamailio | 5061/tcp | SIP over TLS |
| Kamailio | 7000/udp+tcp, 7001/tcp | ALG ports (single-port proxy) |
| Kamailio | 5064/tcp, 5065/tcp | WS, WSS |
| Monster UI | 8080/tcp | nginx |
| Broker | 5672/tcp | AMQP |
| CouchDB | 5984/tcp | HTTP API |

Kamailio's ports are the defaults in
`configs/kamailio/kamailio/listener-defs.cfg`; which listeners are opened
depends on the roles and listener defines in `local.cfg`. Only the SIP, TLS,
websocket and RTP ports need to be reachable by phones and carriers; keep
the broker, CouchDB and the Erlang nodes' ports on a private network.
