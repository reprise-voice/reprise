# Reprise quick start: a test cluster on one machine

This directory starts a complete Reprise system with Docker Compose -- CouchDB,
the AMQP broker (LavinMQ), a `kazoo_apps` node, an `ecallmgr` node,
FreeSWITCH, Kamailio and Monster UI -- so that you can log in, create two
phones and call between them within a few minutes of the images being pulled.

> **This is a test and evaluation setup, not a production deployment.** There
> is one of everything, so any container that stops takes the service with
> it; the broker runs with its default credentials on the container network;
> nothing uses TLS (the UI and API are plain HTTP, SIP is
> UDP/TCP, Kamailio's TLS port has a self-signed certificate); and all data
> lives in Docker volumes on one host, without backups. Run it on a machine
> and network you trust. `docker/README.md` lists what a real deployment needs
> on top of the images.

## Requirements

- Docker Engine 25 or later with the Compose plugin 2.24 or later
  (`docker compose version`), or Docker Desktop of the same vintage
- about 4 GB of free memory (8 GB is comfortable) and a few GB of disk
- a linux/amd64 machine: the images are built for linux/amd64 only
- free ports on the host address: 5060 (UDP and TCP), 16384-16483 (UDP),
  8080; and on 127.0.0.1: 5984, 15672
- two SIP softphones (Linphone, Zoiper, MicroSIP, baresip, ...) on other
  machines that can reach this one (not on this machine itself: see
  Troubleshooting)

## Start

```sh
cd deploy/compose
./init-env.sh
docker compose up -d
./bootstrap.sh
```

`init-env.sh` writes `.env` from `.env.example`. It sets `HOST_IP` to this
machine's LAN address, the address the phones and your browser will use,
and generates the Monster UI admin password, the CouchDB password and the
Erlang cookie. If it picks the wrong address, or cannot find one, give it
yours: `./init-env.sh 192.168.1.50` (`ip -4 addr`, `hostname -I`, or
`ipconfig getifaddr en0` on macOS; never `127.0.0.1`).

`.env.example` holds no credentials, and the cluster does not start while
any of the three is empty. To choose your own, edit `.env` before the first
`docker compose up`; mind the comments (the CouchDB password is letters and
digits only). `init-env.sh` leaves an existing `.env` alone unless it is
given `--force`, because the volumes keep the credentials the cluster was
first started with.

The first start pulls a few GB of images and creates the databases, which
takes a few minutes; `bootstrap.sh` waits for it. It is safe to run again. It:

1. waits until both Kazoo nodes run all their applications,
2. creates the master account and its admin user from `.env` (`ACCOUNT_NAME`,
   `ACCOUNT_REALM`, `ADMIN_USER`, `ADMIN_PASSWORD`), unless an account exists;
   when one does, it runs `sup kapps_maintenance migrate` instead, which is
   what a cluster needs after it comes back up on newer images,
3. has FreeSWITCH fetch prompts and other media through the media proxy
   (`system_config/kazoo_couch.use_bigcouch_direct` off), so it is never
   handed a CouchDB URL with the password in it,
4. imports the system prompts, unless they are there: US English, or the
   languages in `PROMPT_LANGUAGES` (`en-us,fr-ca`, or `all` for every
   language the image ships), set in `.env` or for one run as
   `PROMPT_LANGUAGES=all ./bootstrap.sh`,
5. registers the Monster UI apps with the API,
6. waits until ecallmgr has adopted FreeSWITCH,
7. allows Kamailio as the SBC in ecallmgr's ACLs,

and then prints the UI address, the account and user name, and the softphone
settings. The password is not printed: it is `ADMIN_PASSWORD` in `.env`.

## Make a call

1. Open `http://HOST_IP:8080` and log in with the account name, user name and
   password from `.env`.
2. Open the **App Store** and install **Callflows** (and **SmartPBX** if you
   like) for your account.
3. Create two devices (SIP phone or softphone), each with a name; note the
   SIP user name and password on each device's SIP settings.
4. Give each an extension: in Callflows, add a callflow with the number
   `1001` whose only action is **Device** > the first device, and one with
   `1002` for the second. (SmartPBX does both through **Users** and
   **Devices**, if you prefer.)
5. Configure each softphone:

   | Setting | Value |
   |---|---|
   | SIP server / registrar / proxy | `HOST_IP`, port 5060, UDP |
   | Domain / realm | `ACCOUNT_REALM` from `.env` |
   | User name / password | the device's SIP credentials |

6. Call `1002` from the first phone.

In a hurry? `./smoke/smoke.sh --devices-only` creates two such devices
(`smoke1` on 1001, `smoke2` on 1002) through the API and prints their
credentials. Without `--devices-only`, and with `sipp` installed
(`apt-get install sip-tester jq`), it also registers both and places a call
itself -- the same check CI runs.

## Build the images from this tree instead

```sh
docker compose -f compose.yaml -f compose.build.yaml build
docker compose -f compose.yaml -f compose.build.yaml up -d
./bootstrap.sh
```

or put `COMPOSE_FILE=compose.yaml:compose.build.yaml` in `.env` and use plain
`docker compose ...`. The build fetches the reprise-voice source repositories
from GitHub and takes an hour or more the first time (the Erlang release and
FreeSWITCH dominate); `docker/build.sh` builds the same images by hand.

## Linux: Kamailio and FreeSWITCH on the host network

The default puts everything on a Docker bridge network and publishes the SIP
port and a narrowed RTP range (100 ports, about 25 simultaneous calls) on
`HOST_IP`. On Linux, `compose.host-network.yaml` runs Kamailio and FreeSWITCH
on the host's network instead: no port publishing or NAT, the full RTP range
16384-32768, and the layout closest to a real media server.

```sh
echo 'COMPOSE_FILE=compose.yaml:compose.host-network.yaml' >> .env
docker compose up -d
./bootstrap.sh
```

They then take ports 5060-5065, 7000-7001, 11000-11001 and 16384-32768 on
the host, and `127.0.0.1:8021` (FreeSWITCH's event socket). Switching an
existing cluster between the two layouts: `docker compose down` first, then
`bootstrap.sh` again afterwards (it allows the SBC address that applies).

## Docker Desktop (macOS, Windows)

- `HOST_IP` must still be the machine's LAN address. If Docker Desktop
  refuses to publish on it, set `BIND_IP=0.0.0.0` in `.env`.
- Publishing 100 UDP ports through Desktop's port forwarder makes the first
  `up` slow; lower `RTP_END_PORT` if it bothers you.
- Desktop rewrites the source address of incoming UDP, so Kamailio sees every
  phone as coming from one address. Registration and calls rely on SIP's
  `rport` handling and FreeSWITCH's RTP auto-adjust there; treat audio
  through Docker Desktop as best effort, and prefer a Linux host.
- The host-network variant does not apply.
- Give Docker at least 6 GB of memory (Settings > Resources).
- On Apple silicon the images run under emulation: slowly, and only with
  `ERL_FLAGS=+JMsingle true` in `.env` (the Erlang JIT's default memory
  mapping does not work under QEMU user-mode emulation). Good enough to
  look around the UI; use a linux/amd64 host to test calls.

## Ports

| Where | Port | What |
|---|---|---|
| `HOST_IP` | 5060 UDP/TCP | Kamailio: phones register and call here |
| `HOST_IP` | 16384-16483 UDP | FreeSWITCH RTP (`RTP_START_PORT`-`RTP_END_PORT`) |
| `HOST_IP` | 8080 | Monster UI, with the REST API at `/v2` and websockets at `/socket` (`UI_PORT`) |
| 127.0.0.1 | 5984 | CouchDB (Fauxton at `/_utils`, the `.env` credentials) |
| 127.0.0.1 | 15672 | LavinMQ management UI, guest / guest |

Inside the `reprise` network only (172.30.10.0/24, `REPRISE_SUBNET`): AMQP
5672, crossbar 8000, blackhole 5555, the media proxy 24517, FreeSWITCH SIP
11000, Kamailio's FreeSWITCH-side listener 5070.

## Looking inside

```sh
docker compose ps                         # state and health of each service
docker compose logs -f kazoo-apps         # or ecallmgr, freeswitch, kamailio, ...
docker compose exec kazoo-apps sup kapps_controller list_apps
docker compose exec ecallmgr sup ecallmgr_maintenance list_fs_nodes
docker compose exec ecallmgr sup ecallmgr_maintenance sbc_acls true
docker compose exec kamailio kamcmd dispatcher.list
docker compose exec freeswitch /usr/local/freeswitch/bin/fs_cli
```

`sup` works only inside the node's own container: Kazoo's Erlang
distribution is bound to loopback there, and the nodes talk to each other
over the broker. Run it with `docker compose exec <kazoo-apps|ecallmgr> sup
<module> <function> [args...]`.

## Stop, reset

```sh
docker compose stop          # stop; start again with docker compose up -d
docker compose down          # remove the containers, keep the data
docker compose down -v       # remove the containers and the volumes: a clean slate
```

After `down -v`, run `bootstrap.sh` again once the cluster is up.

## Troubleshooting

**No audio, or audio one way.** `HOST_IP` is not the address the phones
reach this machine on, or the RTP range does not get through: check
`docker compose logs freeswitch | head` (it prints the local and public
address and the RTP range it uses), that no firewall on the host blocks
16384-16483/udp, and that the phones are not behind a second NAT. Changing
`HOST_IP` or the RTP range needs `docker compose up -d` again (it recreates
the affected containers).

**Phones do not register (401/403 again and again).** The domain/realm must
be `ACCOUNT_REALM`, the user name and password the device's SIP credentials
(not the Monster UI login), the server `HOST_IP:5060`.

**Registered, but every call is refused with 403 Forbidden.** The phone runs
on the Docker host and sends from `HOST_IP`. Kamailio advertises `HOST_IP`
as its own address and takes a request coming from itself as already
authorised, so it passes the call on without the registered device's token,
and FreeSWITCH refuses it. Run the phone on another machine, or bind it to
another address of this one. (`smoke.sh` does the latter for its own test
phones: they send from the compose network's gateway, `172.30.10.1`, or from
`SMOKE_CLIENT_IP`.)

**Registered, but calls fail (480, 503, no answer).** Look at
`kamcmd dispatcher.list` (set 1 must list FreeSWITCH with `FLAGS: AP`; `IP`
  means it has not answered Kamailio's probe at that address, and calls get
  "480 All servers busy" until it does), `list_fs_nodes` (ecallmgr
must have adopted `freeswitch@...`) and `sbc_acls true` (Kamailio's address
must be allowed: run `bootstrap.sh` again). The number dialled needs a
callflow.

**`bootstrap.sh` times out waiting for a node, or `sup` says "Connection to
service failed".** Read `docker compose logs kazoo-apps` (or `ecallmgr`).
`nodistribution` or a node that never comes up usually means the hostname or
the cookie: keep the `hostname:` entries in `compose.yaml` as they are (the
node name is `<node>@<hostname>`), and after changing `KAZOO_COOKIE` recreate
both nodes (`docker compose up -d --force-recreate kazoo-apps ecallmgr`). On
a slow machine the first start can take several minutes; set
`BOOTSTRAP_TIMEOUT` (seconds) higher.

**CouchDB authentication errors in the node logs.** The CouchDB password was
changed after the first start (the volume keeps the old admin), or it holds
characters other than letters and digits. `docker compose down -v` and start
over with a simple password.

**`docker compose up` fails: address already in use / pool overlaps.** Another
program holds 5060, 8080, 5984 or 15672 (change `UI_PORT`,
`COUCHDB_LOCAL_PORT`, `BROKER_UI_LOCAL_PORT`; a local SIP client may hold
5060), or 172.30.10.0/24 is in use (set `REPRISE_SUBNET`).

**Pulling the images fails with "denied" or "not found".** The images are
`ghcr.io/reprise-voice/reprise`, `-freeswitch`, `-kamailio` and `-monster-ui`
at `REPRISE_TAG`; if a tag is not published (yet), build from source as above.

**The UI loads but the app list is empty.** Run `bootstrap.sh` again (it
registers the apps), then install them from the App Store for your account.
