### Queues

#### About Queues

A queue holds callers in order until an agent is free to take one. It is an ordinary account document, reached from a callflow through the `callcenter` action, so the queue's extension is whatever callflow number you give it.

The agents in a queue are users of the same account. Each one has a tier in the queue: a `level`, where lower levels are offered a caller first and higher levels are added as the caller waits, and a `position`, which orders the agents within a level for the strategies that care. Tiers are edited through the `agents` sub-resource below rather than by writing the whole queue document, so a supervisor can move an agent without racing whoever else is editing the queue. A tier is an entry in the queue document, so adding, changing or removing one answers the queue document it changed. Every tier route checks the whole queue document it would write, so an invalid entry elsewhere in the list refuses the change, with the error at `agents.N.<field>`. The exception is an entry the write leaves exactly as it was stored (same `id`, `level` and `position`): it is neither checked again nor changed, so a queue saved with a `level` or `position` of 0 before these rules can still be renamed and have other agents' tiers written, and keeps that entry as it was until the entry itself is changed.

A queue written whole, by create, change or patch, may list a user in `agents` only once, and every user it adds to the list has to exist in the account and be enabled; users already in the queue are not checked again. The schema does not say either: both are checked in code.

Any user of the account may read its queues, their tiers and their live state. Everything else here is running the call center, and only an account administrator (`priv_level` `admin`) or a superduper administrator may do it: creating, changing, patching and removing a queue, adding, changing and removing a tier, eavesdrop and pickup. Anybody else gets a `403`, before the body or the queue is looked at, and nothing is changed.

There are six strategies. `ring_all` rings every eligible agent at once and cancels the rest on the first answer. The other five work down an ordered list, `ring_simultaneously` agents at a time: `longest_idle`, the default, tries whoever has been idle longest since their last queue call; `round_robin` carries on from the agent this queue tried last and wraps around, so the callers are shared out evenly; `sequential` starts at the top of the tier order for every caller, so the agent at `level` 1, `position` 1 takes them all while they are free and the rest are the overflow; `fewest_calls` and `least_talk_time` take the agent with the fewest answered calls, or the least time spent on them, since they logged in. `most_idle` is the old spelling of `longest_idle` and is kept only so existing documents still validate.

Some fields changed meaning from the queue this replaces. `announce` was the media played as a caller was about to be connected and is now the object holding the periodic announcement: its media, how often it plays, and whether the caller's position is spoken first. `announcements` keeps only `media.you_are_at_position` and `media.in_the_queue`, the two prompts spoken around the position, for a queue that wants its own; its other keys (`interval`, `position_announcements_enabled`, `wait_time_announcements_enabled` and the wait-time prompts) are not read, and `announce` is where the announcement is turned on. `exit_keys` takes over from `caller_exit_key`, which held one key. `caller_exit_key` is a read-only alias: it is no longer in the schema, and it is read only from a document that has no `exit_keys`, which a queue written through this API always has.

The schema lists only what the call center reads. The acdc queue's `connection_timeout`, `max_priority`, `abandoned_resume_allowed`, `discard_abandoned_after`, `record_caller`, `recording_url`, `cdr_url` and `notification_email` did nothing here and are gone from it. The schema does not forbid other keys, so a document that carries them still saves, unchecked, and they still do nothing.

#### Schema

Call queues - callers wait here in order until an agent is free to take them



Key | Description | Type | Default | Required | Support Level
--- | ----------- | ---- | ------- | -------- | -------------
`agent_no_answer_status` | Availability an agent is moved to once they have missed max_no_answer offers | `string('logged_out' \| 'available' \| 'available_on_demand' \| 'on_break')` | `on_break` | `false` |  
`agent_ring_timeout` | In seconds, how long to ring an agent before progressing to the next agent available | `integer(1..)` | `15` | `false` |  
`agent_wrapup_time` | Pre-defined wait period applied after an agent handles a customer call | `integer(0..)` | `0` | `false` |  
`agents.[].id` | The user who is the agent | `string()` |   | `true` |  
`agents.[].level` | Agents at lower levels are offered a caller first | `integer(1..)` | `1` | `false` |  
`agents.[].position` | Order within the level, and the tie-break every strategy falls back to | `integer(1..)` | `1` | `false` |  
`agents` | The agents in this queue and their tier | `array(object())` | `[]` | `false` |  
`announce.interval` | Seconds between announcements | `integer(15..)` | `30` | `false` |  
`announce.media` | Media ID (or appropriate media URI) of the announcement | `string()` |   | `false` |  
`announce.position` | Speak the caller's position in the queue before the announcement | `boolean()` | `false` | `false` |  
`announce` | Media played to waiting callers at a fixed interval | `object()` | `{}` | `false` |  
`announcements.media.in_the_queue` | Media ID (or appropriate media URI) played after the caller's position | `string()` |   | `false` |  
`announcements.media.you_are_at_position` | Media ID (or appropriate media URI) played before the caller's position | `string()` |   | `false` |  
`announcements.media` | The prompts spoken around the caller's position; a prompt left out is the system prompt | `object()` |   | `false` |  
`announcements` | Overrides for the prompts the position announcement is made of; the announcement itself is set in announce | `object()` |   | `false` |  
`cid_prefix` | Prefixed to the caller ID name shown to the agent, so they know which queue the call came from | `string()` |   | `false` |  
`enter_when_empty` | Allows a caller to enter a queue and wait when no agents are available | `boolean()` | `true` | `false` |  
`exit_keys` | DTMF keys that let a caller leave the queue and continue in the callflow; an empty string turns them off | `string()` | `#` | `false` |  
`greeting` | Media ID (or appropriate media URI) of media played once as the caller enters the queue | `string()` |   | `false` |  
`max_queue_size` | How many callers are allowed to wait on hold in the queue (0 for no limit) | `integer()` | `0` | `false` |  
`max_wait_time` | Seconds a caller may wait before the callflow continues on the timeout branch, 0 for no limit | `integer(0..)` | `0` | `false` |  
`max_wait_time_with_no_agent` | Seconds a caller may wait while no agent could take them, 0 for no limit | `integer(0..)` | `0` | `false` |  
`max_wait_time_with_no_agent_time_reached` | Seconds a caller must already have waited before max_wait_time_with_no_agent starts to apply | `integer(0..)` | `5` | `false` |  
`moh` | Media ID (or appropriate media URI) of media to play while caller is on hold. | `string()` |   | `false` |  
`name` | A friendly name for the queue | `string(1..128)` |   | `true` |  
`outbound_caller_id.name` | Caller ID name | `string()` |   | `false` |  
`outbound_caller_id.number` | Caller ID number | `string()` |   | `false` |  
`outbound_caller_id` | Caller ID for agent legs to contacts outside the account | `object()` | `{}` | `false` |  
`record` | Record queue calls, through the account's own recording storage | `boolean()` | `false` | `false` |  
`ring_simultaneously` | The number of agents to try in parallel when connecting a caller | `integer(1..)` | `1` | `false` |  
`skip_agents_with_external_calls` | Do not offer callers to an agent who is on a call that did not come from a queue | `boolean()` | `true` | `false` |  
`strategy` | How the queue picks which agent to offer a caller to | `string('ring_all' \| 'longest_idle' \| 'round_robin' \| 'least_talk_time' \| 'fewest_calls' \| 'sequential' \| 'most_idle')` | `longest_idle` | `false` |  
`tier_rules.apply` | Add levels as the caller waits rather than offering every level at once | `boolean()` | `false` | `false` |  
`tier_rules.no_agent_no_wait` | Skip the wait when the current levels hold no agent who could answer | `boolean()` | `true` | `false` |  
`tier_rules.wait_multiply_level` | Multiply wait_seconds by the level, so each level waits longer than the last | `boolean()` | `false` | `false` |  
`tier_rules.wait_seconds` | Seconds a caller waits before the next level is added | `integer(0..)` | `0` | `false` |  
`tier_rules` | When higher tier levels are added to the set of agents a waiting caller may be offered to | `object()` | `{}` | `false` |  
`time_base_score` | Whether a caller's age counts from when they entered the system or when they entered this queue, which decides their place after a transfer | `string('system' \| 'queue')` | `system` | `false` |  



#### Fetch all queues

> GET /v2/accounts/{ACCOUNT_ID}/queues

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": [
        {
            "id": "37139638ff5b68f155d8445178524df1",
            "name": "Support Queue"
        }
    ],
    "page_size": 1,
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```


#### Create a queue

> PUT /v2/accounts/{ACCOUNT_ID}/queues

Administrators only; anybody else gets a `403`.

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"name":"Support Queue"}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "agent_no_answer_status": "on_break",
        "agent_ring_timeout": 15,
        "agent_wrapup_time": 0,
        "agents": [],
        "announce": {
            "interval": 30,
            "position": false
        },
        "enter_when_empty": true,
        "exit_keys": "#",
        "id": "37139638ff5b68f155d8445178524df1",
        "max_queue_size": 0,
        "max_wait_time": 0,
        "max_wait_time_with_no_agent": 0,
        "max_wait_time_with_no_agent_time_reached": 5,
        "name": "Support Queue",
        "outbound_caller_id": {},
        "record": false,
        "ring_simultaneously": 1,
        "skip_agents_with_external_calls": true,
        "strategy": "longest_idle",
        "tier_rules": {
            "apply": false,
            "no_agent_no_wait": true,
            "wait_multiply_level": false,
            "wait_seconds": 0
        },
        "time_base_score": "system"
    },
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```


#### Fetch a queue

> GET /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```


#### Change a queue

> POST /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

Administrators only; anybody else gets a `403`.

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"name":"Support Queue","strategy":"ring_all","max_wait_time":300}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```


#### Patch a queue

> PATCH /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

Administrators only; anybody else gets a `403`.

```shell
curl -v -X PATCH \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"strategy":"ring_all"}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```


#### Remove a queue

> DELETE /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

Administrators only; anybody else gets a `403`.

```shell
curl -v -X DELETE \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```


#### Fetch a queue's tiers

> GET /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents

The queue's `agents` list, with each agent's user document summarised so a supervisor screen does not have to fetch them one at a time.

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": [
        {
            "first_name": "Jane",
            "id": "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91",
            "last_name": "Roe",
            "level": 1,
            "position": 1,
            "username": "jane"
        },
        {
            "first_name": "John",
            "id": "8bd2ec3c8c8c9b58f7db4c9d1b2e6d3a",
            "last_name": "Doe",
            "level": 2,
            "position": 1,
            "username": "john"
        }
    ],
    "page_size": 2,
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```


#### Add a tier

> PUT /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents

`id` is the user who becomes an agent in this queue, and has to exist in the account and be enabled. `level` and `position` are whole numbers of 1 or more, and both default to 1. An error in the new tier is reported at the body's own field, such as `level`. Adding a tier for a user who already has one is an error; change the existing tier instead. Administrators only; anybody else gets a `403`.

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"id":"f2a1c66b6d2e1f6a4dcd6fa2b45c5a91","level":1,"position":2}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents
```


#### Change a tier

> PATCH /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}

`level` and `position`, when given, are whole numbers of 1 or more. Takes effect on the next offer; a caller already ringing this agent is not disturbed. Administrators only; anybody else gets a `403`.

```shell
curl -v -X PATCH \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"level":2}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}
```


#### Remove a tier

> DELETE /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}

Administrators only; anybody else gets a `403`.

```shell
curl -v -X DELETE \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}
```


#### Fetch a queue's live state

> GET /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/status

Who is waiting and who could take them, as of now. This is a query against the node dispatching the account rather than a database read, so it is not a document and it is not cached. The same information arrives unasked over the WebSocket, which is what a wallboard or a supervisor screen should use; this endpoint is for the first paint and for scripts.

`media_node` is the media server the caller's channel is parked on, and `offered_to` is the agent currently being tried, if any.

An agent being rung for a caller or talking to one has that caller's `call_id`, the `queue_id` the caller came in through, and `connected`, which is `true` once the agent has answered and `false` while their phones ring. The `queue_id` is another of the agent's queues when they are in more than one and the call came from there. The three are `null` when the agent is on no queue call. The `call_id` is the caller's call, not the agent's leg, and is the one to [eavesdrop](#eavesdrop-on-an-agents-call) on, through the queue `queue_id` names: listening to it hears both of them.

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/status
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "agents": [
            {
                "activity": "on_call",
                "agent_id": "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91",
                "answered": 12,
                "availability": "available",
                "call_id": "8d2e4f6a-1b3c-4d5e-9f70-a1b2c3d4e5f6",
                "connected": true,
                "last_call_end": 63929304822,
                "missed": 1,
                "queue_id": "37139638ff5b68f155d8445178524df1",
                "tier_level": 1,
                "tier_position": 1,
                "tier_state": "active_inbound"
            }
        ],
        "queue_id": "37139638ff5b68f155d8445178524df1",
        "waiting": [
            {
                "call_id": "5c7a1d2e-3f40-4a5b-8c9d-0e1f2a3b4c5d",
                "caller_id_number": "+15551234567",
                "joined_timestamp": 63929305001,
                "media_node": "freeswitch@fs1.example.com",
                "offered_to": null,
                "position": 1
            }
        ]
    },
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```


#### Eavesdrop on an agent's call

> PUT /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/eavesdrop

Calls the supervisor and puts them on the named call. Give either `device_id` or `user_id` for the supervisor's own phone, and `call_id` for the call to listen to. Without a `call_id` the request is refused rather than guessed at.

`mode` says what the supervisor may be heard by: `listen`, the default, hears both sides and says nothing; `whisper` hears both sides and is heard by the agent only; `full` is a three-way call. `call_id` is the caller's call in every mode, the one the queue's and the agents' status name.

The switch's `eavesdrop` hears both sides of the channel it runs against, and mixes the supervisor into that channel: into what that channel's phone hears for a whisper, and also into what it sends the other side for `full`. So `listen` and `full` run against the caller's channel, and `whisper` against the agent's leg -- the channel the caller's is bridged to -- so that the agent hears the supervisor and the caller does not. That leg is checked as the caller's call is (every channel under it the account's, none put in another queue, a `503` when a switch does not answer), and it has to be answered and bridged to the caller: a whisper to a caller nobody is talking to yet, or whose agent's phone is still ringing, is a `400` with `not_connected` on `call_id`, and nothing rings. The answer's `Eavesdrop-Call-ID` is the channel the eavesdrop runs against. Once connected, the supervisor's keypad changes the mode as the switch's eavesdrop does, relative to that channel: `2` speaks to its phone, `1` to the other side, `3` to both, `0` to neither.

Only an account administrator (`priv_level` `admin`) or a superduper administrator may eavesdrop; anybody else gets a `403`, before anything else is looked at. The queue has to exist in the account, or the answer is a `404`. The device or user has to be one of the account's, not deleted, or the answer is a `400` with `not_found` on `device_id` or `user_id`; a device of another account is refused the same way. It has to have a phone that would ring -- the device itself, or a device the user owns, that is not disabled or on do not disturb -- or the answer is a `400` with `invalid` on the same field. An empty `device_id` or `user_id` is no id at all. The switches are then asked about `call_id`, and every channel carrying it has to belong to the account; a channel that was put in a queue has to have been put in this one. A call that no switch carries and a call of another account are both a `400` with `not_found` on `call_id`. When no switch answers, the answer is a `503` and nothing is started.

The answer is the request that went out, not the call: the supervisor's phone has not rung yet.

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"user_id":"3a1b5c7d9e0f2a4b6c8d0e1f2a3b4c5d","call_id":"5c7a1d2e-3f40-4a5b-8c9d-0e1f2a3b4c5d","mode":"listen"}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/eavesdrop
```


#### Pick up a waiting caller

> PUT /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/pickup

Rings the supervisor's own phones for a caller waiting in the queue, which is the "pick up" action on the live view. Same body as `eavesdrop` without the `mode`, where `call_id` is the waiting caller: `device_id` rings that one device, `user_id` every device the user owns that would ring.

The ring is made by the node dispatching the account, as an agent's is: the caller goes on hearing the queue's music while the supervisor's phones ring, and nobody else is rung for them meanwhile. The caller leaves the queue only when the supervisor answers, and the queue's record of the call names the supervisor as `agent_id` with `picked_up` set; no agent's counters move and no wrap-up starts. If the supervisor does not answer within 30 seconds, is busy or rejects the call, the caller is simply still waiting, in the same place, and is offered to the next agent free. A caller who hangs up or leaves the queue while the phones ring leaves as they would during an agent's ring.

The same people may pick up, and the same checks are made, as for `eavesdrop`. Then the node dispatching the account is asked, and Crossbar answers with what it did:

| Status | `error` | When |
|---|---|---|
| `202` | | The supervisor's phones are ringing: the ring is out on the caller's channel. `data` says which: `call_id`, `queue_id`, the `device_id` or `user_id` asked for, `ringing` (the devices) and `ring_timeout` (seconds). |
| `400` | `invalid` on `device_id` or `user_id` | None of the phones can be rung for this caller: excluded from queues (`exclude_from_queues`), disabled, on do not disturb, or the caller is on one of them. A device excluded from queues is refused before the dispatcher is asked, as a queue call would leave it out; the rest is known once the ring is built on the caller's call. Nothing rang. |
| `404` | `not_waiting` | Nobody with that `call_id` is waiting in this queue: they were answered, left, are in another queue, or nobody is dispatching the account. |
| `409` | `being_offered` | A phone is already ringing for the caller, an agent's or another supervisor's. Ask again once it has stopped. |
| `409` | `supervisor_busy` | The supervisor is already ringing for, or talking to, another caller of the account through a pickup, or as an agent. |
| `500` | `not_started` | The ring could not be started; the message says why. Nothing rang. |
| `503` | `no_answer` | The node dispatching the account did not answer within three seconds, or no node answered for the account at all. Nothing rang, and it is safe to ask again: the request carries the moment Crossbar stops waiting, and a node that reads it after that rings nothing. |

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"device_id":"9f8e7d6c5b4a39281706f5e4d3c2b1a0","call_id":"5c7a1d2e-3f40-4a5b-8c9d-0e1f2a3b4c5d"}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/pickup
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "call_id": "5c7a1d2e-3f40-4a5b-8c9d-0e1f2a3b4c5d",
        "device_id": "9f8e7d6c5b4a39281706f5e4d3c2b1a0",
        "queue_id": "37139638ff5b68f155d8445178524df1",
        "ring_timeout": 30,
        "ringing": [
            "9f8e7d6c5b4a39281706f5e4d3c2b1a0"
        ]
    },
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```

A caller an agent is already talking to is not waiting, so a pickup of them is a `404`: taking a connected call off an agent is not a pickup.
