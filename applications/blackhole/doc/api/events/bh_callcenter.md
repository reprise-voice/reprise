# Overview

Every state change in the call center is published on AMQP with the account id in the routing key. `bh_callcenter` relays those to a WebSocket, so a wallboard or an agent panel follows a queue without polling.

The module only relays. A live answer to "who is waiting right now" is `GET /queues/{QUEUE_ID}/status`, which asks the node holding the account's shard; a socket that subscribes gets what happens from that moment on.

## Subscription Bindings Overview

- `callcenter.agent.{AGENT_ID}`: one agent's availability, activity, offers, answers and wrap-ups
- `callcenter.queue.{QUEUE_ID}`: one queue's waiting count and longest wait, on every change
- `callcenter.call.{CALL_ID}`: what the dispatcher does with one waiting caller
- `callcenter.*.{ID}`: all three

Replace the id with `*` for every agent, queue or call in the account. `callcenter.*.*` is an account's whole call center on one subscription.

The account is not part of the binding. It comes from the socket's auth token, or from `data.account_id` for a descendant account, and the usual subscribe authorisation applies: an account id outside the authenticated account's tree is refused, and `*` is refused unless the user is a superduper admin.

```json
{
  "action": "subscribe",
  "auth_token": "{AUTH_TOKEN}",
  "request_id": "{REQUEST_ID}",
  "data": {
    "account_id": "{ACCOUNT_ID}",
    "binding": "callcenter.agent.*"
  }
}
```

## Events

Each event arrives as the usual blackhole envelope, with `name` set to the event name below and `data` carrying the event's fields with lower-cased, underscored names.

| Binding | `name` | What it says |
|---|---|---|
| `callcenter.agent.{AGENT_ID}` | `agent_availability` | the agent's chosen availability changed, with `previous` and the `source` that changed it, and `break_ends` for a break that ends by itself |
| | `agent_activity` | the agent's phones changed state: `idle`, `ringing`, `on_call` or `wrapping_up`, with `queue_call` saying whether this call came from a queue |
| | `agent_offer` | a caller is being offered and the agent's phones are ringing, with `offer_timeout` |
| | `agent_answered` | the agent answered, with `agent_call_id` and `answered_timestamp` |
| | `agent_wrapup` | the call ended and wrap-up started, with `wrapup_ends` |
| `callcenter.queue.{QUEUE_ID}` | `queue_stats` | `waiting`, `longest_wait` and `agents_available`, whenever the waiting count or the agents available change, and once with `waiting` 0 when the last caller leaves. Not sent while the dispatcher cannot count the agents |
| `callcenter.call.{CALL_ID}` | `member_offer` | the caller is being offered, with the `agent_ids` being rung and `offer_timeout` |
| | `member_connected` | the caller was bridged, with `agent_id` and `agent_call_id` |
| | `member_position` | the caller's `position` and the queue's `waiting` count, on every change and on the announcement interval; `agents_available` when the dispatcher can say it (absent means not said, never zero), `offered` for whether a ring for the caller is out, and `joined_timestamp`, `caller_id_name`, `caller_id_number` and `media_node` when known |
| | `member_result` | how the call ended: `completed`, `agent_hangup`, `caller_hangup`, `failed`, `transferred`, or `queue_deleted` when the queue the caller waited in was deleted and nobody was connected |

A supervisor's pickup of a waiting caller is not a new result: `member_connected` and `member_result` arrive on the call's binding with the supervisor's user id as `agent_id`, and the supervisor gets no `agent_offer`, `agent_answered` or `agent_wrapup`.

Every event also carries `account_id` and a `timestamp`, and each carries the ids of whatever it is about, so a socket subscribed to `callcenter.*.*` can route each event without keeping the binding it arrived on.
