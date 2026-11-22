# fs-contract-probe

A fake FreeSWITCH node, written as one Erlang escript. It speaks the AMQP
wire contract that `freeswitch/mod_reprise` implements, against a running
`ecallmgr_extension`, and reports which parts of the contract held. Use it
to check a change to the extension without a media server, or to see what
the extension sends a node.

It uses `amqp_client` and a JSON encoder directly, with none of the Kazoo
AMQP libraries, so that it meets the contract the way the C module does.

## Running it

The probe needs `amqp_client` 4.x on the code path. The `reprise` image has
it, so the easiest place to run the probe is a running ecallmgr container:

```bash
docker cp probe.escript <ecallmgr-container>:/tmp/probe.escript
docker exec <ecallmgr-container> \
    sh -c '/opt/kazoo/erts-*/bin/escript /tmp/probe.escript'
```

It prints one line per check and exits 0 when every check passed.

| Setting | Default | Meaning |
|---|---|---|
| `PROBE_AMQP_URI` | `amqp://guest:guest@127.0.0.1:5672` | The broker to connect to. |
| `PROBE_RUN_SECS` | 90 | How long `--advertise` watches before it reports. |

## Modes

**No argument.** Connects, declares a reply queue on the `targeted`
exchange, and makes two configuration fetches: one for `com.kazoo.conf`,
which must come back as the full module configuration, and one for a key
that does not exist, which must come back as "not found".

**`--dump <path>`.** Makes the `com.kazoo.conf` fetch and writes the reply to
`<path>`. `samples/kazoo.conf.xml` is one such reply.

**`--advertise`.** Behaves as a media server for the length of the run. It
advertises itself on the `nodes` exchange and keeps up the heartbeats,
answers the commands ecallmgr sends a new node, and once ecallmgr has
adopted it, makes dialplan, directory, location and channel fetches and
publishes a channel create and destroy. While it runs, the fake node shows
in `sup ecallmgr_maintenance node_summary` and its channel in
`channel_summary`.

`--advertise` adds a media server to the cluster that cannot carry a call.
Run it against a test cluster only.

## The contract

The facts of the contract that the module depends on are listed in
[freeswitch/mod_reprise/README.md](../../freeswitch/mod_reprise/README.md#wire-contract).
