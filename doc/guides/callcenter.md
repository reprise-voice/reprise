# Call center

`applications/callcenter` provides call queues and agents: callers wait in
a queue, and a dispatcher offers each one to agents chosen by the queue's
strategy. It is a Gleam application that runs on kazoo_apps nodes. This page
is the short operator view; how it works, its settings and how to operate
it are in [applications/callcenter/README.md](../../applications/callcenter/README.md).

## What you get

- **Queues**: account documents, managed with the `queues` API
  ([applications/crossbar/doc/queues.md](../../applications/crossbar/doc/queues.md)),
  with six distribution strategies (`ring_all`, `longest_idle` (the
  default), `round_robin`, `sequential`, `fewest_calls`,
  `least_talk_time`), periodic announcements and exit keys.
- **Agents**: users with a `call_center` object, managed with the `agents`
  API ([applications/crossbar/doc/agents.md](../../applications/crossbar/doc/agents.md)),
  with availability, breaks and a login lamp for BLF keys.
- **The `callcenter` callflow action**, which puts a caller in a queue, and
  `callcenter_agent`, one action carrying the agent feature codes
  (`toggle_login`, `toggle_break`).
- Live state over the API and blackhole, eavesdrop, whisper and pickup for
  administrators.

## Enabling it

`callcenter` is in the default application list, so a kazoo_apps node that
uses the default list already runs it. On a node with an explicit list, add
`callcenter` to `KAZOO_APPS`.

It has one cluster setting, the number of shards that accounts are hashed
into (default 64). It must be the same on every node, and changing it needs
the application stopped everywhere first:

```console
$ sup kapps_config set_default callcenter shards 64
```

Each shard is a durable queue on the broker, `callcenter.member.<n>`, and
the node that holds the exclusive consumer on it dispatches for the
accounts in that shard. Nodes share the shards between them on their own;
there is nothing to assign by hand.

## Broker requirements

- Waiting callers are unacknowledged deliveries for as long as they wait.
  **On RabbitMQ, `consumer_timeout` must not apply to the
  `callcenter.member.*` queues** (turn it off, or set it by policy above the
  longest wait any queue allows), or a caller waiting 30 minutes (the
  RabbitMQ default) ends their shard's consumer. LavinMQ has no consumer
  timeout unless one is configured.
- Set an explicit AMQP heartbeat on the nodes' broker URI in `config.ini`,
  inside quotes: `uri = "amqp://user:pass@broker:5672?heartbeat=10"`.

Both are explained in the README section
[A holder that stops answering](../../applications/callcenter/README.md#a-holder-that-stops-answering).

## Setting up a queue

1. Create the queue with `PUT /v2/accounts/{ACCOUNT_ID}/queues`.
2. Make users agents (an agent is a user with a `call_center` object; see
   [agents.md](../../applications/crossbar/doc/agents.md)) and add them to
   the queue's tiers with
   `PUT /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents`.
3. Point a callflow number at the queue with the `callcenter` action.
4. Give agents the feature codes: a callflow on `^\*22([0-9]*)$` with the
   `callcenter_agent` action and data `{"action": "toggle_login"}` logs the caller
   (or, for an administrator, the agent with that extension) in and out;
   `toggle_break` on `*24` starts and ends a break
   ([README: The feature codes](../../applications/callcenter/README.md#the-feature-codes)).

## Checking it

| Command | Shows |
|---|---|
| `sup callcenter_maintenance status` | the shards this node holds, the members it sees, the dispatchers, waiting callers and agents |
| `sup callcenter_maintenance agents <account_id>` | the account's agents and their state |
| `sup callcenter_maintenance queue_status <account_id> <queue_id>` | what is happening in a queue, cluster-wide |

`status` answers for the node it runs on. The full command list is in the
README's [sup](../../applications/callcenter/README.md#sup) section.
