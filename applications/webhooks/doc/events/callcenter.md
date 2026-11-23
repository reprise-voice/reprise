# Call Center Events

One hook per call center event, so a hook for agent answers does not also receive every position change:

* `callcenter_member_connected`
* `callcenter_member_position`
* `callcenter_member_result`
* `callcenter_agent_availability`
* `callcenter_agent_activity`
* `callcenter_agent_offer`
* `callcenter_agent_answered`
* `callcenter_agent_wrapup`
* `callcenter_queue_stats`

These are the same events the WebSocket relay carries, in the same shape. A wallboard takes them over the socket; an integration that has to survive a browser being closed takes them here.

## Sample

```json
{
    "account_id": "91eb05e5c68d7ca05e7618b6821d2d16",
    "agent_id": "d860229e722bf8f738737365b0b1e333",
    "availability": "available",
    "previous": "on_break",
    "source": "phone",
    "timestamp": 63887252084,
    "hook_event": "callcenter_agent_availability",
    "cluster_id": "1d2e3f4051627384"
}
```

## Fields

Every event carries `account_id`, a `timestamp` and `hook_event`. The rest are the event's own:

| Hook | Also carries |
|---|---|
| `callcenter_member_connected` | `queue_id`, `call_id`, `agent_id`, `agent_call_id`, `answered_timestamp` |
| `callcenter_member_position` | `queue_id`, `call_id`, `position`, `waiting`; `agents_available` when the dispatcher can say it; and, when known, `caller_id_name`, `caller_id_number`, `joined_timestamp`, `media_node` and `offered` |
| `callcenter_member_result` | `queue_id`, `call_id`, `result`, `ended_timestamp`, and `agent_id` and `agent_call_id` when an agent leg was built |
| `callcenter_agent_availability` | `agent_id`, `availability`, `source`, `previous` when there was one, and `break_ends` for a break that ends by itself |
| `callcenter_agent_activity` | `agent_id`, `activity`, and `call_id` and `queue_call` when the agent is on a call |
| `callcenter_agent_offer` | `queue_id`, `agent_id`, `call_id`, `offer_timeout` |
| `callcenter_agent_answered` | `queue_id`, `agent_id`, `call_id`, `agent_call_id`, `answered_timestamp` |
| `callcenter_agent_wrapup` | `queue_id`, `agent_id`, `wrapup_ends`, and `call_id` for the call that ended |
| `callcenter_queue_stats` | `queue_id`, `waiting`, `longest_wait`, `agents_available` |

`availability` is one of `logged_out`, `available`, `available_on_demand` or `on_break`, and `source` says what changed it: `phone`, `ui`, `supervisor`, `no_answer`, `dnd` or `system`. `activity` is one of `idle`, `ringing`, `on_call` or `wrapping_up`, and `queue_call` says whether the call the agent is on came from a queue. `result` is one of `completed`, `agent_hangup`, `caller_hangup`, `failed`, `transferred` or `queue_deleted`. `queue_deleted` is the one result for a caller nobody connected: the queue they waited in was deleted and the dispatcher took them out of it, so it carries no `agent_id`.

The optional fields:

* `agents_available` on `callcenter_member_position` is left out when the dispatcher cannot count the agents (their activity not read yet, or the switches not answered). Its absence means "not said", never zero. `callcenter_queue_stats` is not sent at all then.
* `offered` on `callcenter_member_position` says whether a ring for the caller is out: asked for or ringing, and neither answered nor called off.
* `joined_timestamp` on `callcenter_member_position` is when the caller joined the queue, in Gregorian seconds.
* `break_ends` on `callcenter_agent_availability` is when a break that has an end ends by itself, in Gregorian seconds.

A supervisor's pickup of a waiting caller is not a new result. `callcenter_member_connected` fires with the supervisor's user id as `agent_id` and the supervisor's leg as `agent_call_id`, and the call ends with a `callcenter_member_result` whose `agent_id` is the supervisor, with no `agent_call_id`. The supervisor gets no `callcenter_agent_offer`, `callcenter_agent_answered` or `callcenter_agent_wrapup`. What the pickup request itself got (`ringing`, `not_waiting`, `being_offered`, `supervisor_busy`, `not_started`, `too_late`) is the answer to the Crossbar request and is not an event.

`callcenter_queue_stats` fires whenever a queue's waiting count or the number of agents available changes, and once more with `waiting` 0 when the last caller leaves.
