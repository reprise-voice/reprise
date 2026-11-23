## SUP-able functions

| Function | Arguments | Description |
| -------- | --------- | ----------- |
| `ack_member/2` | `(Account_id,Call_id)` | `release_member` under its older name |
| `agents/1` | `(Account_id)` | Every agent of an account, with the availability they chose and the activity this node derives. The activity is complete only on the node dispatching the account, which `status` shows |
| `cancel_member/2` | `(Account_id,Call_id)` | Publish a cancel (a caller hanging up) for a member, which settles the delivery the shard holds for it. The other half of `publish_member` |
| `cancel_member_message/4` | `(Account_id,Call_id,Node,At)` | Exported for the test suite (builds the cancel `cancel_member` publishes); not for `sup` |
| `publish_member/3` | `(Account_id,Queue_id,Call_id)` | Publish a test member into the shard the account hashes to: enough of a call to be logged, not enough to bridge. Shows which node holds a shard and how long a failover takes |
| `queue_status/2` | `(Account_id,Queue_id)` | Ask the cluster what is happening in an account, whichever node dispatches it. An empty queue id is every queue |
| `rebalance/0` |  | Look at every shard now rather than at the next tick, and say how many are assigned and held here |
| `reconcile/0` |  | Run the sweep now rather than waiting for the timer |
| `release_agent/2` | `(Account_id,Agent_id)` | Take an agent out of whatever this node's dispatcher believes about them: the offer they are in, the wrap-up, the delay after a miss. Does not change their availability |
| `release_member/2` | `(Account_id,Call_id)` | Take a caller out of the queue as their cancel would: the shard settles the member and tells the dispatcher, which drops them, frees the agents being rung for them and closes their record as `hangup`. Run on the node holding the account's shard |
| `set_agent/3` | `(Account_id,Agent_id,To)` | Set an agent's availability as a supervisor would: `logged_out`, `available`, `available_on_demand` or `on_break`. Refused for a disabled, deleted or missing user unless `logged_out` |
| `set_agent_lines/4` | `(Kz,Account_id,Agent_id,To)` | Exported for the test suite (`set_agent` against a given datastore); not for `sup` |
| `status/0` |  | Which shards this node dispatches for, and what each holds. This node's answer only |
