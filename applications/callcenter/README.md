# Call center

Queues, agents, and the dispatchers that connect them.

Callers wait in a queue, and a dispatcher offers each one to agents chosen
by the queue's strategy. The application is written in
[Gleam](https://gleam.run) as an OTP application, compiled to BEAM and
shipped in the `kazoo` release like every other application. It runs on
`kazoo_apps` nodes, started by `kapps_controller` when `callcenter` is in
`KAZOO_APPS` or in the `kapps` list of `system_config/kapps_controller`. It
has no HTTP surface and no port of its own. Its calls into Kazoo go through
`core/kazoo_gleam`, the shared library every Gleam application in the
release takes as a path dependency.

The short operator guide is
[doc/guides/callcenter.md](../../doc/guides/callcenter.md). This README
describes how the application works, how to configure and operate it, and
where things are in the code.

## How it works

**Shards.** Accounts are hashed into a fixed number of shards,
`erlang:phash2(AccountId, Shards)`, with the count read from
`system_config/callcenter.shards` (default 64). A shard is a group of
accounts that are dispatched together. Each shard has one durable AMQP
queue, `callcenter.member.<shard>`, which holds the callers waiting in that
shard's queues. A waiting caller is one message on it, the *member*.

**One node per shard.** Whichever node holds the exclusive consumer on a
shard's member queue dispatches for the shard. The broker allows one
exclusive consumer at a time, so two nodes can never both dispatch for one
shard. When the holder's connection goes, its unacknowledged members go
back on the queue and the next node to consume the queue receives them.

**Placement.** One process per node, `callcenter/placement`, decides which
shards the node should take. The members of the cluster are the nodes the
broker sees running the application with the agreed shard count (each node
consumes a queue of its own, `callcenter.node.<node>`). Every node computes
the same assignment of shards to members by rendezvous hashing with bounded
loads, so two members each hold half the shards. Every tick (about five
seconds) a node takes the free shards assigned to it and asks the current
holder for the ones somebody else has. A holder hands a shard over only to
the member it also sees the shard assigned to, and refuses while an agent
is being rung on the shard; after two minutes of refusals it hands the
shard over anyway, and the new holder picks up the ring in progress from
the caller's record. A shard nobody has consumed for thirty seconds is
taken by any node that sees it.

**Dispatchers.** The node holding a shard runs one dispatcher per account
in it that has had a caller waiting. Every offer in an account is decided
in that one process, so an agent who is in two queues is never rung for two
callers at once. Each pass orders all of the account's waiting callers by
priority and then by how long they have waited, works out which tier levels
each caller may be offered to, and asks the caller's queue strategy which
agents to ring. The ringing itself is done by the caller's own actor
(`callcenter/call/actor`), one per waiting caller, which bridges the agents'
devices from the caller's channel and, when a node dies, is started again on
the node that takes the caller's shard and finds them where they stand. A member is acknowledged only once the caller has an agent or
has left, so a node failure redelivers every caller still waiting.

**Agents.** An agent has two independent values. *Availability* is what the
agent or a supervisor chose: logged out, available, available on demand or
on break. It is stored in the `callcenter_agent-<user_id>` document in the
account database. *Activity* is what the agent's phones are doing: idle,
ringing, on a call or wrapping up. Each node derives activity from the
channel events, keyed by the channel's `Owner-ID`, and resyncs it from the
switches on start and every `reconcile_interval_s`. A channel carrying the
`Queue-ID` channel variable is a queue call.

**The caller's side.** The `callcenter` callflow action (`cf_callcenter`)
runs on whichever node won the route. It holds the caller's channel, plays
the greeting, hold music and announcements, publishes the member, and
continues the callflow on a branch that says why the caller left. The
dispatcher sends it `member_position`, `member_offer`, `member_connected`
and `member_result` on the callflow's own controller queue. The same events
are published on the `callcenter` exchange for webhooks, blackhole and
other consumers.

| Branch | When |
|---|---|
| `queue_full` | `max_queue_size` callers are already waiting |
| `no_agents` | nobody could take the caller and `enter_when_empty` is off; the queue does not exist or was deleted; the member could not be published; or this node's shard count is not the cluster's |
| `exit_key` | one of the queue's `exit_keys` was pressed |
| `timeout` | `max_wait_time` ran out |
| `no_agent_timeout` | `max_wait_time_with_no_agent` ran out with nobody available |

A caller who hangs up ends the callflow rather than taking a branch.

## Enabling it

```console
$ sup kapps_config set_default callcenter shards 64
```

Then add `callcenter` to `KAZOO_APPS`, or do nothing: it is in the default
application list. There is nothing else to set up. Every node declares the
member queues as it starts, joins the members, and takes the shards
assigned to it. A node that cannot reach the broker keeps trying and holds
nothing until it can.

The shard count must be the same on every node. The broker holds the
cluster's count on a queue of its own, `callcenter.shards`, which is never
consumed and has `x-max-length` set to the count. The first node to declare
it sets it. A node configured with a different count is refused, logs that
it takes no shard, and sends its callers down `no_agents`. To change the
count, stop the application on every node, set the new count, delete the
marker queue (`rabbitmqctl delete_queue callcenter.shards` or
`lavinmqctl delete_queue callcenter.shards`), and start the application
everywhere. Members still on the queues of the old count are not moved.

Useful log lines: `shard N taken on <node> with M caller(s) waiting`,
`shard N handed over to <node>` on the giving node, and
`members: <node>, <node> (were <node>)` when the membership changes.

## The API

The application serves two Crossbar endpoints:

- `queues`: a queue is an account document. See
  [applications/crossbar/doc/queues.md](../crossbar/doc/queues.md).
- `agents`: an agent is a user with a `call_center` object, so there is no
  agent document of its own and no `PUT`. A queue's tiers, at
  `/accounts/{id}/queues/{qid}/agents`, are served here too. See
  [applications/crossbar/doc/agents.md](../crossbar/doc/agents.md).

Any user of the account may read queues, tiers, agents and live state.
Creating, changing and removing queues and tiers, eavesdrop, whisper,
pickup, and changing another agent's availability need an account
administrator or a superduper administrator (`callcenter/permission`). An
agent may always change their own availability.

Eavesdrop and pickup check that the queue, the call and the supervisor's
device or user all belong to the account. Whisper runs against the agent's
leg, so the caller does not hear it. Pickup asks the node dispatching the
account to ring the supervisor's phones for the waiting caller, as an offer
would ring an agent.

## The feature codes

`cf_callcenter_agent` is one callflow action carrying all three codes; the
callflow node's data says which. Put `toggle_login` on the pattern
`^\*22([0-9]*)$`, `toggle_login` with `require_pin` set on `*23`, and
`toggle_break` on `*24`. An administration UI creates the first with the
feature code name `callcenter_agent[action=toggle_login]` and data
`{"action": "toggle_login"}`.

- `*22` logs the caller in or out. The agent is the call's owner, the
  user whose device placed the call. A call from a device with no owner is
  asked for an agent id and PIN.
- `*22<extension>` toggles the agent whose user `presence_id` is the
  extension, which is what an `agent_login` BLF key dials. A caller may
  always toggle their own extension; anybody else's needs the caller to have
  `priv_level` `admin`.
- `*23` (`require_pin`) always asks for an agent id and PIN, and logs in the
  agent who typed them rather than the phone's owner. This is the
  hot-desking login. Each of the id and PIN gets three tries of ten seconds.
- `*24` starts or ends a break. The node's `timeout` is how long the break
  lasts, in seconds; absent or 0 is a break with no end. A break with an end
  ends by itself and returns the agent to what they were before it
  (available or available on demand).

Logging in, taking a break or resuming is refused (`agent-invalid_choice`)
for a user who is deleted, disabled or on do-not-disturb. Logging out is
always allowed. A refused or abandoned exchange changes nothing.

The prompts are `agent-logged_in`, `agent-logged_out`, `agent-on_break`,
`agent-invalid_choice`, `hotdesk-enter_id` and `hotdesk-enter_pin`. All but
`agent-on_break` ship with the system; until it is recorded into
`system_media`, `*24` starts the break and plays nothing.

**The login lamp.** A BLF key provisioned as `agent_login` shows an agent's
login: `confirmed` while available, `early` while on an answered queue
call, `terminated` when logged out or on break. Only agents are published
for, and nothing is published on a user's own presence id. The address is
the `presence_id` on the feature code node if one was used (it is stored on
the agent's document), otherwise `<prefix><user presence_id>@<realm>`, with
the prefix from `agent_presence_prefix` (default `*22`). The application
also answers Kamailio's dialog probes, so a phone that subscribes after the
last change sees the current state.

## Configuration

Settings live in `system_config/callcenter`
(`sup kapps_config set_default callcenter <key> <value>`). The schema is
`applications/crossbar/priv/couchdb/schemas/system_config.callcenter.json`.

| Key | Default | Meaning |
|---|---|---|
| `shards` | 64 | Number of shards accounts hash into. Must be the same on every node; see "Enabling it" for how to change it |
| `offer_grace_s` | 5 | Seconds an offer may run past the agent's ring timeout before it is given up on |
| `announce_default_interval_s` | 30 | Seconds between periodic announcements when a queue sets no interval |
| `default_agent_no_answer_status` | `on_break` | Availability an agent is moved to after `max_no_answer` misses, when the queue sets none |
| `reconcile_interval_s` | 30 | Seconds between reconciliation sweeps |
| `queue_refresh_s` | 10 | Seconds between reads of a queue document from the database rather than the cache |
| `agent_presence_prefix` | `*22` | Prefix of the login lamp's address. An account's `configs/callcenter`, then its reseller's, override it |
| `stub_offer` | false | Ring nobody; see "Testing" |
| `stub_offer_answer_ms`, `stub_offer_talk_ms` | 1000, 3000 | How long a stub offer rings, and stays answered |

`shards` is read once when the node starts, and `stub_offer` once when a
shard is taken.

Per-queue behaviour (strategy, tier rules, wait limits, exit keys, ring
timeouts, recording, announcements) is set on the queue document; see
[queues.md](../crossbar/doc/queues.md).

## Dispatch strategies

| Strategy | Who is offered |
|---|---|
| `ring_all` | every eligible agent at once; the first to answer takes the caller |
| `longest_idle` (default; `most_idle` is an alias) | the agent free longest |
| `round_robin` | the next agent after the one this queue tried last |
| `sequential` | down the tier order from the top, for every caller |
| `fewest_calls` | the agent with the fewest answered calls this login |
| `least_talk_time` | the agent with the fewest seconds of talk this login |

Every strategy except `ring_all` produces an ordered list, and the
dispatcher rings `ring_simultaneously` agents from it at a time (one by
default). Level always comes first: a free level 1 agent is offered before
a level 2 one, and `tier_rules` decide when higher levels may be offered at
all. Ties fall back to tier position, then agent id. A queue naming an
unknown strategy (including the old `top_down`) is dispatched with
`longest_idle`, and the log says so. The `round_robin` cursor is held in the
dispatcher's memory, so it restarts from the top when a shard moves.

An offer lasts the agent's ring timeout plus `offer_grace_s`. An offer that
rings out, is rejected or finds the phone busy is a miss: it counts towards
the queue's `max_no_answer` and applies the agent's own delay for that
outcome. Reaching `max_no_answer` moves the agent to the queue's
`agent_no_answer_status`. A ring of several agents that nobody answers is a
miss for each of them. These are not misses:

- the agent took a break or logged out while the phone rang;
- the caller hung up or left the queue during the ring;
- the ring was called off (`release_agent`, a deleted queue);
- the agent was disabled or deleted while the phone rang;
- the offer could not ring at all (no registered device, no bridge). The
  agent is left alone for a few seconds instead.

Misses are counted since the agent last logged in; a break does not reset
the count.

## Operating it

**Do-not-disturb, disabled and deleted users.** Do-not-disturb on a user
holds the agent logged out, and clearing it restores what they were. A
disabled user is logged out and keeps their tiers. A deleted user is taken
out of every queue's tiers, logged out, and their `callcenter_agent`
document deleted. These follow user edits, and the reconciliation sweep
catches any edit that was missed. The dispatcher never offers a caller to
an agent whose user is disabled, deleted or on do-not-disturb.

**Deleting a queue** with callers in it sends every waiting caller out on
the `no_agents` branch, within `queue_refresh_s` at the latest.

**Reconciliation.** Every `reconcile_interval_s` each node resyncs agent
activity from the switches and, for the accounts it dispatches, removes
waiting callers whose channel is on no switch, follows do-not-disturb and
disabled users, and ends breaks whose end has passed on a node that has
since gone. When a node takes a shard it also looks for calls that were
answered on the previous holder and never closed, and either closes them
or watches them to the end.

**What a failover loses.** A shard that moves keeps every waiting caller,
and the new holder reads each redelivered caller's `queue_call` record
before ringing anybody, so a ring still in progress is watched rather
than rung again. Calls already answered are found by the scan described
above. It does lose the in-memory state: the miss counts towards
`max_no_answer`, the per-agent delays after a miss, the wrap-up timers,
and the `round_robin` cursor. The new holder can watch an
adopted call and write its records, but cannot hang it up.

### A holder that stops answering

A shard changes hands when the broker drops its holder's consumer, which
happens when it drops the holder's connection. A node that dies cleanly
closes its sockets and its shards are free at once. A node that stops
answering without closing anything (frozen, partitioned, a paused VM, a
half-open TCP connection) keeps its shards, and every caller waiting in
them, until the broker notices. In the meantime the callers in the
accounts of those shards wait without being offered to anybody.

What notices is the AMQP heartbeat. Nothing in `kazoo_amqp` sets one, so it
is amqp_client's default of 10 seconds; the client and broker agree on the
smaller of their two values, and LavinMQ offers 300. LavinMQ closes a
connection that has sent nothing for the heartbeat plus 5 seconds, so a
silent holder is dropped 15 to 20 seconds after it goes quiet, and the
other members take its shards at their next tick. TCP keepalive (LavinMQ's
`[main] tcp_keepalive`, about 90 seconds by default) is the backstop.

Recommended settings:

- Kazoo: set the heartbeat explicitly on the AMQP URI in `config.ini`, so
  that a change of library default cannot move it:
  `uri = "amqp://user:pass@host:5672?heartbeat=10"` under `[amqp]`, or
  `amqp_uri = "..."` in a zone section. The quotes are required, because
  the `config.ini` lexer ends an unquoted value at the first `=`. Do not use
  `heartbeat=0`, which negotiates to the broker's 300 seconds. Going below
  10 risks a busy node losing every channel it has. `connection_timeout` in
  the URI has no effect, and a query key amqp_client does not know makes
  the URI invalid.
- LavinMQ: leave `[amqp] heartbeat` at its default and keep
  `[main] tcp_keepalive` on.

**Consumer timeouts.** A waiting caller is an unacknowledged delivery for
as long as they wait. RabbitMQ (3.8.15 and later) closes a channel with a
delivery unacknowledged for longer than `consumer_timeout`, 30 minutes by
default; a caller who waits that long ends their shard's consumer and every
caller in the shard is redelivered. On RabbitMQ, turn it off for the member
queues, or set it by policy on `^callcenter\.member\.` above the longest
wait any queue allows. LavinMQ has no consumer timeout unless
`[main] consumer_timeout`, an `x-consumer-timeout` argument or a
`consumer-timeout` policy sets one; the member queues are declared without
one, so leave `[main] consumer_timeout` unset and keep any
`consumer-timeout` policy from matching `callcenter.member.*`.

A broker that loses its queues while the nodes stay up recovers on its
own: the holders' consumers are cancelled, and the next placement tick
redeclares and takes the queues. The callers whose members were lost leave
their queues on their own clocks.

## sup

| Command | What it does |
|---|---|
| `sup callcenter_maintenance status` | the shards this node holds, the members it sees and how many shards they assign it, the dispatchers, the callers waiting in each queue and the agents |
| `sup callcenter_maintenance agents <account_id>` | every agent of an account with their availability and this node's derived activity |
| `sup callcenter_maintenance set_agent <account_id> <agent_id> <availability>` | set an agent's availability as a supervisor would (`logged_out`, `available`, `available_on_demand`, `on_break`) |
| `sup callcenter_maintenance queue_status <account_id> <queue_id>` | ask the cluster what is happening in an account; an empty queue id is every queue |
| `sup callcenter_maintenance release_agent <account_id> <agent_id>` | clear the offer, wrap-up or delay this node holds for an agent. A ring in progress is called off with no miss and the caller is offered again; an answered call is ended. Availability is not changed |
| `sup callcenter_maintenance release_member <account_id> <call_id>` | take a caller out of the queue as their cancel would; run it on the node holding the account's shard |
| `sup callcenter_maintenance rebalance` | make the placement look at every shard now, and report how many are assigned and held here |
| `sup callcenter_maintenance reconcile` | run the reconciliation sweep now |
| `sup callcenter_maintenance publish_member <account_id> <queue_id> <call_id>` | publish a test member into the account's shard |
| `sup callcenter_maintenance cancel_member <account_id> <call_id>` | publish the cancel for a test member |
| `sup callcenter_maintenance ack_member <account_id> <call_id>` | the older name of `release_member` |

`status` answers for the node it runs on. On a settled cluster every node
shows the same member list and holds as many shards as are assigned to it.
A node assigned more than it holds is waiting for another node to hand
shards over; nodes with different member lists have not yet heard of each
other through `kz_nodes`, and nothing moves between them until they have.

On the broker, every `callcenter.member.<n>` queue should have exactly one
exclusive consumer, and every member one consumer on its own
`callcenter.node.<node>` queue. `callcenter.shards` never has a consumer;
its `x-max-length` is the cluster's count. A member queue with no consumer
while nodes are up is a shard between handover and take, which lasts at
most a tick, or one taken as an orphan after thirty seconds.

See also [doc/ref/maintenance.md](doc/ref/maintenance.md).

## Documents and views

| Document | Database |
|---|---|
| `queue` | account |
| `callcenter_agent-<user_id>`: availability, counters, break end, lamp address | account |
| `queue_call`, one per passage, id `<call_id>-<queue_id>-<joined>` | the month database of the second the passage joined |
| `agent_status_change`, one per availability change | month database |

A *passage* is one caller in one queue from the second they joined. A
caller who overflows into another queue, or rejoins the same one, has a
second `queue_call` document, so per-queue reports count each passage
under its own queue. Documents written by earlier releases, keyed by call
id alone, are still read for the passage they belong to.

The views are registered at start: `callcenter/agents` and
`callcenter/queues_by_agent` in the account database, and
`callcenter/queue_calls_by_queue`, `callcenter/queue_calls_by_agent`,
`callcenter/queue_calls_open` and `callcenter/status_changes_by_agent` in
the month databases. Their sources are in [priv/couchdb](priv/couchdb).

Integrators can follow events through webhooks (`webhooks_callcenter`, one
hook type per event, such as `callcenter_agent_answered`) or blackhole
(`bh_callcenter`, with `callcenter.agent.<agent_id>`,
`callcenter.queue.<queue_id>` and `callcenter.call.<call_id>`
subscriptions). The AMQP API is `kapi_callcenter`.

## Modules

| Module | Purpose |
|---|---|
| `callcenter`, `callcenter/app` | the supervision tree and the OTP application callbacks |
| `callcenter/shards`, `callcenter/members`, `callcenter/placement` | the shard count and assignment, cluster membership, and which shards this node takes |
| `callcenter/shard` | one held shard: its supervisor, the actor that holds and acknowledges its members, the member listener |
| `callcenter/dispatcher` and `callcenter/dispatcher/*` | one account's waiting callers, offers, timers and events; `pass` and `plan` decide who is offered |
| `callcenter/strategy`, `callcenter/strategies/*` | the strategy interface and one module per strategy |
| `callcenter/tiers`, `callcenter/tier_check` | tier rules, and validation of tier writes |
| `callcenter/call/*` | the call path: each waiting caller's actor, the pure core it runs, its media, originates and conversations, the publishers every actor publishes through, and finding a caller handed over by a node that died |
| `callcenter/stall` | whether a node that stood still may still act for its shards |
| `callcenter/activity` | agents' phone activity, derived from channel events |
| `callcenter/availability`, `callcenter/agent_state`, `callcenter/breaks` | the agent document, availability changes, and breaks with an end |
| `callcenter/dnd` | do-not-disturb, disabled and deleted users |
| `callcenter/presence`, `callcenter/lamp_probe` | the login lamp and Kamailio dialog probes |
| `callcenter/records`, `callcenter/records/backlog`, `callcenter/recording` | `queue_call` and `agent_status_change` documents, the writes held while the database is away, and queue call recording |
| `callcenter/reconcile`, `callcenter/closed` | the reconciliation sweep |
| `callcenter/status`, `callcenter/status_query`, `callcenter/pickup` | live status and pickup requests answered by the shard holder |
| `callcenter/supervisor_actions`, `callcenter/permission` | eavesdrop and pickup in Crossbar, and who may use the API |
| `callcenter/announce`, `callcenter/caller` | the waiting caller's announcements, clocks and exit keys |
| `cf_callcenter`, `cf_callcenter_agent` | the callflow actions for callers and for agent feature codes |
| `cb_queues`, `cb_agents` | the Crossbar endpoints |
| `callcenter_maintenance` | the `sup` commands |
| `kapi_callcenter.erl` | the AMQP event family |
| `bh_callcenter.erl`, `webhooks_callcenter.erl` | blackhole and webhooks integration |
| `callcenter_*_ffi.erl` | Erlang helpers used from Gleam |

## Testing

With Erlang/OTP 28 and Gleam installed, run `gleam test` in this directory.
Without them, use a builder image with Erlang/OTP 28 and Gleam 1.18.1 (the
`builder` stage of `docker/reprise/Dockerfile`; `$BUILDER` below is its
tag), from the repository root so that the container sees the
`core/kazoo_gleam` path dependency:

```console
$ docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src \
    -w /src/applications/callcenter "$BUILDER" gleam test
$ make gleam-check
```

`make -C applications/callcenter compile` builds the application and
installs its `ebin` and dependencies into `deps/`, which is what `make apps`
and the release do.

Do not build a release in a tree the tests have run in: the test build
writes `-DTEST` beams that the release would ship. Run
`make clean-core clean-apps` first.

### On a running node

Publishing a test member shows which node holds an account's shard:

```console
$ sup callcenter_maintenance publish_member <account_id> support call-one
published member call-one to callcenter.member.3 (shard 3)
```

The node holding shard 3 logs that it received the member. The test caller
has no channel on any switch, so the reconciliation sweep removes them
within `reconcile_interval_s`; `cancel_member` or `release_member` settles
them at once. Stopping the holding node puts the member back on the broker,
and the node that takes the shard logs it again.

### Without a media server

With no FreeSWITCH, nothing can ring a real phone. `stub_offer` answers
every offer with a process that rings nobody: ringing at once, answered
after `stub_offer_answer_ms`, ended after `stub_offer_talk_ms`. Strategies,
counters, documents and events all run as usual.

```console
$ sup kapps_config set_default callcenter stub_offer true
$ sup kapps_config flush callcenter
```

Then restart the application, because the setting is read when a shard is
taken.
