### Agents

#### About Agents

An agent is a user of the account with a `call_center` object on their user document; a user without one is not an agent and this API does not answer for them. That object holds the settings that belong to the person rather than to a queue: the login id and PIN for the `*23` feature code, how long their phones ring on an offer, how many offers they may miss before they are stood down, the delays after a reject, a busy or a no answer, their wrap-up time and whether their leg is recorded. It is edited through the `users` API like any other part of a user; this API is about what the agent is doing.

An agent has two values, and they are independent.

**Availability** is what the agent, a supervisor or an automatic rule chose: `logged_out`, `available`, `available_on_demand` or `on_break`. It is persisted on every change with a timestamp and the source of the change, and it survives a restart of every node.

**Activity** is what the agent's phones are doing right now: `idle`, `ringing`, `on_call` or `wrapping_up`. It is derived from channel events, not chosen, and it covers every call the user is on, whether or not it came from a queue. It cannot be set.

A queue offers a caller to an agent only when their availability is `available` (or `available_on_demand` with someone waiting), their activity is `idle`, and their tier in that queue is not standing them down. Because activity is per user and not per queue, an agent in two queues who is on a call from one is never rung by the other.

A disabled user (`enabled: false`) is never offered a caller and is logged out by the system; they keep their tiers, and are listed here marked `"enabled": false`, so that enabling them again brings them back in every queue, logged out. A deleted user is no agent: they are taken out of every queue's tiers and logged out, their agent document is removed, and this API no longer lists them or answers for them.

Any user of the account may read everything here. The one write is an agent's availability, which is their own to change and an administrator's to change for anybody. An agent's tier in a queue is part of running the queue: it is edited at `/queues/{QUEUE_ID}/agents` (see `queues.md`), by an administrator only.

#### Schema

An agent is a user of the account, so this API has no document of its own. An agent's own settings are the `call_center` object on the user, and their tier in a queue is an entry in that queue's `agents` list.



#### Fetch all agents

> GET /v2/accounts/{ACCOUNT_ID}/agents

Every user of the account with a `call_center` object, with their availability and activity as of now, and the queues they are an agent in.

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": [
        {
            "activity": "idle",
            "availability": "available",
            "enabled": true,
            "first_name": "Jane",
            "id": "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91",
            "last_name": "Roe",
            "presence_id": null,
            "queues": [
                {
                    "level": 1,
                    "position": 1,
                    "queue_id": "37139638ff5b68f155d8445178524df1",
                    "queue_name": "Support Queue"
                }
            ],
            "source": "ui",
            "timestamp": 63929304822,
            "username": "jane"
        }
    ],
    "page_size": 1,
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```


#### Fetch an agent

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}

The same entry for one agent, with the queues they are in and their tier in each.

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}
```


#### Fetch an agent's status

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status
```

`break_ends` is there only while the agent is on a break that ends by itself: when it ends, in Gregorian seconds.

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "activity": "idle",
        "agent_id": "f2a1c66b6d2e1f6a4dcd6fa2b45c5a91",
        "availability": "on_break",
        "break_ends": 63929305722,
        "source": "phone",
        "timestamp": 63929304822
    },
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```


#### Change an agent's status

> PATCH /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status

Sets availability only; activity is derived and cannot be set. `availability` is one of `logged_out`, `available`, `available_on_demand` or `on_break`. `source` says who is asking and is one of `ui` or `supervisor`; it defaults to `ui`, and an agent changing their own status may not claim `supervisor`.

`timeout` is how long a break lasts, in seconds, as on the `*24` feature code: a whole number, 0 or absent for a break with no end. The break then ends by itself and the agent goes back to exactly what they were before it, `available` or `available_on_demand`; the change is recorded with `source` `system`. It is read only with `on_break`, and an agent already on a break keeps the break they are on. Any other change before the end, a resume included, cancels it. The answer carries `break_ends` when the break has an end. A negative `timeout` is a `400` with `minimum`, and one that is not a whole number a `400` with `type`.

An agent may change only their own status. An account administrator (`priv_level` `admin`) or a superduper administrator may change any agent's; anybody else asking about another agent gets a `400` with `forbidden` on `availability`.

A break pauses a login, so `on_break` for an agent who is `logged_out` is a `400` with `forbidden` on `availability`, with or without a `timeout`, and nothing changes; log the agent in first. The `*24` feature code refuses it the same way.

A disabled user (`enabled: false`), and a user with do-not-disturb set, may only be set to `logged_out`: anything else, a break included, gets a `400` with `forbidden` on `availability`, whose message says which, and nothing changes. A deleted user is not an agent, so any change to them is a `404`. The `*22`, `*23` and `*24` feature codes refuse the same users the same way. Nor is a user on do-not-disturb offered a caller or counted available, whatever their availability says.

While do-not-disturb is set on the user the agent is held at `logged_out`, and clearing it restores the availability they had before. A break with an end comes back with the time it had left, or, if its end passed meanwhile, as what the break would have ended to. A user disabled in the meantime is not restored, whether do-not-disturb is cleared while they are disabled or after they are enabled again: disabling them makes the logout the system's.

```shell
curl -v -X PATCH \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{"data":{"availability":"on_break","source":"ui","timeout":900}}' \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status
```


#### Fetch an agent's status log

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/log

Every availability change, newest first, out of the monthly account databases the range covers. `created_from` and `created_to` are Gregorian seconds; without them the range is the month up to now. `page_size` says how many changes to answer with, and defaults to 50.

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    'http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/log?created_from=63929304000&created_to=63929390400'
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": [
        {
            "availability": "on_break",
            "previous": "available",
            "source": "ui",
            "timestamp": 63929304822
        },
        {
            "availability": "available",
            "previous": "logged_out",
            "source": "phone",
            "timestamp": 63929290110
        }
    ],
    "page_size": 2,
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```


#### Fetch an agent's counters

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/stats

The counters kept since the agent last logged in: queue calls answered, seconds spent on them, offers missed, and when their last queue call ended. Logging in starts them again; a break does not, so the numbers cover the whole of the shift the agent is in. `missed` counts the offers that rang an agent who was there to take them: an offer that rang out, was rejected or found the phone busy after the agent had already gone on break or logged out is not counted against them and does not count toward `max_no_answer`. These are the counters the strategies run on, so they are here as soon as there is a call center at all. Queue and agent statistics proper -- offered, abandoned, answered within the SLA threshold, average wait and handle time, per interval and per day -- are phase 2 and will be their own endpoint.

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/stats
```

```json
{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "calls_answered": 12,
        "last_call_end": 63929304822,
        "missed": 1,
        "talk_time_s": 2831
    },
    "request_id": "{REQUEST_ID}",
    "revision": "{REVISION}",
    "status": "success"
}
```
