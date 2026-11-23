# Queues

## About Queues

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



## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/queues

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues
```

## Create

> PUT /v2/accounts/{ACCOUNT_ID}/queues

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues
```

## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```

## Change

> POST /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

```shell
curl -v -X POST \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```

## Patch

> PATCH /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

```shell
curl -v -X PATCH \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```

## Remove

> DELETE /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}

```shell
curl -v -X DELETE \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}
```

## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents
```

## Create

> PUT /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents
```

## Patch

> PATCH /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}

```shell
curl -v -X PATCH \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}
```

## Remove

> DELETE /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}

```shell
curl -v -X DELETE \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/agents/{USER_ID}
```

## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/status

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/status
```

## Create

> PUT /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/eavesdrop

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/eavesdrop
```

## Create

> PUT /v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/pickup

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/queues/{QUEUE_ID}/pickup
```
