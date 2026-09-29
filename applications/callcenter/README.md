# Call center

Queues, agents, and the dispatchers that connect them.

It is a [Gleam](https://gleam.run) OTP application, compiled to BEAM and
shipped in the `kazoo` release like every other application. It runs on
`kazoo_apps` nodes, started by `kapps_controller` when `callcenter` is in
`KAZOO_APPS` or in the `kapps` list of `system_config/kapps_controller`. It
has no HTTP surface and no port of its own. The Erlang side of its calls into
Kazoo lives in `core/kazoo_gleam`, the shared library every Gleam application
in the release takes as a path dependency.

Three halves, in the order a caller meets them: the shards and their
placement, which decide *which node* dispatches for an account; the dispatcher, which
decides *which agent* a caller is offered to; and the activity and
availability of the agents themselves, which is what the dispatcher decides
from. The ringing itself is the call path: each waiting caller's actor
(`callcenter/call/actor`), which the dispatcher reaches through one function
it is started with and the messages it sends it.

## Shards and their placement

Accounts hash into a fixed number of shards, `erlang:phash2(AccountId,
Shards)`, with `Shards` read from `system_config/callcenter.shards` once per
node: when the application starts, or, on a node where the callflow action
runs without the application, on its first call. It is kept for the life of
the node, so a running node never changes it, and the callflow that
addresses a member and the node that consumes it use the same number. Each
shard has one durable AMQP
queue, `callcenter.member.<shard>`, declared by every node as it starts,
holding the callers waiting in that shard's queues. It is a classic durable
queue with `x-message-ttl` and `x-max-length` turned off, fed through the
default exchange under its own name, bound to no exchange and owned by no
`kapi` module.

**Whoever holds the exclusive consumer on a shard's member queue dispatches
for the shard.** That is the whole election. The broker lets one consumer at
a time consume a queue exclusively and refuses every other; when the holder's
channel goes — it died, it was stopped, the broker gave up on it — the
consumer is gone, everything it had unacked is back on the queue, and the
next node to ask gets both. There is no lease to seed, hold, hand back or
lose, nothing to remember across processes, and no way for two nodes to
believe they own one shard.

Changing `shards` is a restart of the application on every node at once. Two
nodes with different counts hash the same account into different shards and
both believe they own it, so a disagreement is made loud. The broker holds
the cluster's count on a queue of its own, `callcenter.shards`: durable,
never consumed, never published to, declared by every node with
`x-max-length` set to the count it uses. The first declaration sets it. A
node whose count differs is refused the declaration with
`PRECONDITION_FAILED`, logs that it takes no shard and lets no caller join,
and does neither: it never becomes a member, takes nothing, and the callflow
action on that
node sends its callers down `no_agents` at once. It asks the broker again
once a minute. A node where the callflow runs without the application never
asks, and a member it hashed differently is caught by the shard it lands in.
The member queues themselves carry no count, because queues declared by an
earlier release without one would refuse every node with one until they were
deleted, members and all; the marker is a queue nobody had, and a fresh
deployment and an upgrade that keeps the count both simply declare it.

Changing the count is therefore: stop the application everywhere, set the
new count, delete `callcenter.shards` (`lavinmqctl delete_queue
callcenter.shards`, or `rabbitmqctl delete_queue callcenter.shards`), and
start the application everywhere. The first node up declares the new count.
Members still on the queues of the old count are not moved.

A member that reaches a shard its account does not hash to under the
node's count -- published by a callflow on a node that counts differently,
which says what it counted with (`Shard-Count`) -- is held and not
dispatched, with an error naming the account and both counts. Held, so that
the caller's cancel, which the same callflow sends to the same queue,
settles it once; not dispatched, because the node that really holds the
account's shard may be dispatching its other callers. It is not sent on to
the shard this node would have put it in: that shard's holder might count as
the sender did and send it back, and the cancel would still come here,
leaving a copy nobody ever cancels. The caller leaves on their own clocks.

### Placement

One process per node, `callcenter/placement`, decides which shards the node
dispatches. It keeps five rules.

1. **The members** are the nodes the broker can see running the application
   with the cluster's count. Each node consumes a queue of its own,
   `callcenter.node.<node>` (not durable, deleted with its last consumer),
   for as long as its count is agreed and its placement runs, and any node can
   declare another's queue and read its consumer count. That is the broker's
   own view, from the same connection as the node's member queue consumers,
   so a node loses its membership in the instant it loses its shards. The
   names to ask about come from `kz_nodes` -- every node in this zone it has
   heard running `callcenter`, and this node -- and from the members at the
   last look, and nothing else decides: `kz_nodes` hears of a node dying 12
   to 45 seconds late and of one starting 15 to 40 seconds late. The members
   are asked about again because `kz_nodes` can forget a node that is there.
   A restarted node's old entry runs out after the new one's queue is
   consumed and before its first heartbeat is heard, and the node would
   drop out and back in, taking its shards on a round trip.
2. **The assignment** is computed by every node from the members alone
   (`shards.assign`). Each member ranks every shard by
   `erlang:phash2({Member, Shard})`, and the shards are dealt in order, each
   to its highest ranked member that has fewer than `ceil(shards / members)`
   already: rendezvous hashing with bounded loads. Two members hold 32 and 32
   of 64. A member leaving moves its own shards and a few others; a member
   joining takes about its share.
3. **Take, or ask.** Every tick (five seconds and up to two of jitter) the
   placement declares the member queue of each shard it does not hold. One
   assigned to it that nobody consumes it takes, by starting the shard's tree.
   One assigned to it that somebody else consumes it asks for: one message to
   every other member's queue naming those shards (`members.want`).
4. **Hand over when asked.** A want is honoured for a shard this node holds
   and also sees assigned to the asker, and for nothing else. The shard is
   asked to give itself up (`GiveUp`) from a process of its own, so that a
   busy shard holds up neither the others nor the placement. The shard
   stops its dispatchers, gives its callers' actors three seconds to finish
   what the next holder could not see -- an originate some of whose legs
   have not shown, a bridge on its way -- and goes: every caller's member
   goes back to the broker with it, and on the node taking it each caller's
   actor finds them where they stand on the switch, a ring or a
   conversation included, and takes it on (*Takeover*). A shard that does
   not answer in time is asked again, and after `patience_ms` (two minutes)
   released anyway.
5. **Orphans.** A shard assigned elsewhere that nobody has consumed for
   `orphan_ms` (thirty seconds) is taken by whoever sees it. A member that is
   failing to take its shards must not leave callers waiting in a shard
   nobody dispatches.

Holding a shard is still holding the exclusive consumer on its member queue.
Two nodes that disagree about the members may both try to take a shard, and
the broker refuses the second: the rules decide who tries, the broker decides
who has it.

Rule 4 is what keeps a shard from moving back and forth. A shard moves on
purpose only when both ends agree it is the asker's: the asker only asks for
what it is assigned, and the holder only gives a shard to the member it sees
it assigned to. Two nodes that see different members -- one has heard of a
third through `kz_nodes` and the other has not yet -- move nothing between
them until they agree. A node that cannot take a shard never asks for one, so
nothing is given to it: a node that died and that `kz_nodes` still lists is
not a member, and a node whose count is not the cluster's never becomes one.

| What happens | When its shards are free | Who takes them |
|---|---|---|
| a node dies: killed, crashed, its pod deleted | at once: its connection closes, and its consumers with it | every other member at its next tick, as assigned among those left |
| a node freezes, or is cut off | when the broker drops its connection on the heartbeat, 15 to 20 s later | the same |
| a node comes back, or joins | -- | it asks for its shards, and each holder hands them over at the next want; each shard moves once |
| the broker restarts | at once, everywhere | each node as it reconnects; a node that sees the others late takes theirs too, and hands them back when they ask |
| a node's count is refused | it holds none | nobody gives it any |

The placement starts each tree, and so is linked to it; it unlinks and
watches it with a monitor instead, so that the tree's `shutdown` is a message
and not the placement's end, and a placement its supervisor restarts finds
the trees still running and watches them again. Until the listener has been
given the queue the shard is nobody's: `shard.holds` answers no, the actor
refuses to start a dispatcher whatever its asker checked, and the status
responder says nothing for its accounts. `sup callcenter_maintenance
rebalance` makes the placement look now, between ticks.

The broker's idle load is one `queue.declare` per shard not held and one per
candidate member, per node per tick.

This replaced, on 2026-09-26, a process per shard per node that took shards
up to a *fair share* read from `kz_nodes`' node count, took the rest as
*spares* that did not count against the share for ten minutes, and gave
surplus shards up one at a time. On the lab's e2e run that day a node that
restarted found every shard held by the other as a spare, and got none back
for ten minutes; a broker restart left one node holding all 64. A shard with
a caller waiting was never given up, so on a busy cluster the shares never
evened out.

### A holder that stops answering

A shard changes hands when the broker drops its holder's consumer, and the
broker drops it when it drops the holder's connection. A node that dies
cleanly closes its sockets and the shard is free at once. A node that stops
answering without closing anything (frozen, partitioned, a VM paused, a
half-open TCP connection) keeps the exclusive consumer, and every caller in
its shards, until the broker notices. What notices is the AMQP heartbeat,
and TCP keepalive after it.

Nothing in `kazoo_amqp` sets a heartbeat. `kz_amqp_connections:add/3` hands
the whole configured URI to `amqp_uri:parse/1` and only overrides
`connection_timeout` (to 500 ms), so the heartbeat is amqp_client's default,
`heartbeat = 10` in `amqp_client.hrl` (amqp_client 4.3.4). The two sides
agree on the smaller value when both are non-zero
(`amqp_network_connection:tune/3`), and LavinMQ offers 300 s (`[amqp]
heartbeat`, LavinMQ 2.9.3), so every Kazoo connection runs a 10 s heartbeat
today. LavinMQ closes a client from which no frame has arrived for the
heartbeat plus 5 s, checked every half heartbeat, so a silent holder is
dropped 15 to 20 s after it goes quiet -- its membership with it -- and its
shards are taken at the other members' next tick. TCP keepalive (`[main] tcp_keepalive = 60:10:3` by default,
about 90 s) is the backstop.

Recommended settings:

- Kazoo: say it explicitly, so that a change of client library default
  cannot move it: `?heartbeat=10` on the AMQP URI in `config.ini`, inside
  the quotes (`uri = "amqp://user:pass@host:5672?heartbeat=10"` under
  `[amqp]`, or `amqp_uri = "..."` in a zone section). The quotes are
  required: the `config.ini` lexer ends an unquoted value at the first `=`.
  Do not use `heartbeat=0`, which negotiates to the broker's 300 s. Going
  below 10 buys failover time at the price of a busy node that cannot get a
  frame out for a few seconds losing every channel it has; 10 is the value
  to keep. `connection_timeout` in the URI has no effect (it is overridden),
  and a query key amqp_client does not know makes the URI invalid.
- LavinMQ: leave `[amqp] heartbeat` at its default (the client's lower value
  wins) and keep `[main] tcp_keepalive` on.

Consumer timeouts. A waiting caller is an unacked delivery for as long as
they wait, with no limit here. RabbitMQ (3.8.15 and later) closes a channel
with `PRECONDITION_FAILED` when a delivery on it has been unacked longer
than `consumer_timeout`, 30 minutes by default. On RabbitMQ that means a
caller who waits 30 minutes ends their shard's tree: every member of the
shard is redelivered, to whichever node takes it next. On RabbitMQ, turn it off
for the member queues (`consumer_timeout` unset in `advanced.config`) or set
it, by policy on `^callcenter\.member\.`, above the longest wait any queue
allows. LavinMQ 2.9.3 has the same mechanism and has it off by default:
`[main] consumer_timeout` is unset, and a queue gets one only from an
`x-consumer-timeout` argument or a `consumer-timeout` policy. The member
queues are declared without one. Leave `[main] consumer_timeout` unset, and
keep any `consumer-timeout` policy from matching `callcenter.member.*`.

### One tree per shard

Taking a shard starts a supervisor of its own, `one_for_all`, with two
children: the shard actor, which holds every unacked member delivery and
hosts the account dispatchers, and the member listener, which consumes the
queue exclusively and hands the actor what arrives. They are one failure
boundary because a delivery is only good on the channel it came on. A
listener that loses its channel, is refused the consumer, or has the consumer
cancelled by the broker because its queue was deleted or lost, ends -- it
does not let `gen_listener` reconnect underneath an actor still holding
handles to the old channel -- and, as the tree's one significant child, ends
the tree with it: the broker has given back everything the old channel had
unacked, and the placement takes the shard again at its next tick, on a
fresh channel, if it is still free and still this node's. It used to restart
the tree instead, and a broker restart was five refusals in a row, a tree
that gave up, and a node left holding nothing. An actor that crashes
restarts both, which is the same redelivery. A dispatcher that crashes does
not: see below. OTP counts: more than five restarts in a minute and the
supervisor ends with `shutdown`, which the placement sees.

Before any of this existed, on the lab on 2026-09-14, shard 31's actor
crashed on a cancel that reached it as its dispatcher stopped itself, the
lease the node held stayed with a process that had nothing under it, and
the shard was held by nobody for twenty minutes with nine callers on its
member queue.

### One ack per member

The shard actor is the one thing that settles a member; its `holding` list
is the ledger. A dispatcher never acks: it asks the shard to settle a caller
(`Settle`, naming the delivery it was handed) when their call has ended or
they have left, a caller's actor saying they left (`CallerLeft`) and a
cancel from the member queue settle the caller on arrival at the shard, and
an operator settles by hand through `sup`. A caller's actor saying they are
leaving on a branch (`CallerDeparting`) settles nothing: the actor asks the
shard to settle them (`Settle`) once it has handed them back. A connected call's member is held
until the call ends, so the member queue holds every live call and a node
that dies mid-call leaves it on the broker for the next holder. Settling a call
that is already settled is nothing, and a settlement naming a delivery the
shard no longer holds — an offer for the caller's earlier passage through
the queue answering after they left and came back — is nothing too, so a
member is acked exactly once whichever of those asks first and in whatever
order. Acking a delivery twice is not harmless: the broker closes the
channel with `PRECONDITION_FAILED` and everything unacked on it is
redelivered, which on the lab is how the crash above was reached.

The flip side is that the dispatcher has to name the delivery the shard
holds *now*. A caller can be delivered again while their phones ring: a
redelivery of the same passage, the callflow run again after its node died,
or a second queue's member overtaking the first queue's cancel. Each time
the shard settles the delivery it held and holds the new one, and the
waiting caller takes the new one too. An answer therefore keeps the member
of the caller waiting, not the member the offer was made from, whose
outcome is still written to the offer's own passage, and the call's end
settles that one. Settling the offer's own settled nothing, and the
delivery the shard held came back at the next failover as a call long
over.

The ledger holds a member under its account and its call id together, and
a cancel, a settlement and a settle by hand each name both. Accounts share
a shard and a call id is only what the sender said, so a cancel that names
another account's call settles nothing.

The ledger holds one member per call. A `member_call` for a call already
held is the same caller delivered again, and the delivery it replaces is
settled as it is replaced: nothing else ever would, and left on the channel
it would come back at the next failover as a caller nobody is waiting for.
The one exception is a member of an earlier passage than the one held, the
caller having left and come back and the old message being the slower; that
one is settled instead and never dispatched. A message that is not a caller
at all -- no call id, no account, not a `member_call` -- is settled on
arrival and logged, because no dispatcher could offer it and no cancel could
name it.

A caller's `member_call` and `member_cancel` can reach the shard in either
order: `gen_listener` hands each delivery to a process of its own, and each
hands it back to the listener, so two deliveries a moment apart race. A
cancel that settles nothing is therefore remembered, for a minute and at
most 4096 at a time (`callcenter/tombstones`), and the `member_call` of the
passage it cancelled is settled on arrival and never handed to a
dispatcher. Without it the member behind the cancel is a caller who has
already left, dispatched, and their actor's commands break into whatever
their callflow does next.

The cancel says which passage: the second the caller joined
(`Joined-Timestamp`, the `member_call`'s own) and the second they left
(`Cancelled-Timestamp`). It buries the `member_call` of the same account,
call and queue that joined at that second, and is used up doing it: one
cancel, one passage. A cancel used to bury every `member_call` of the queue
that joined by the second the caller left, for its whole minute, so a
caller whose callflow sent them straight back into the queue in that second
was settled on arrival and never dispatched. A cancel for an earlier passage,
or for another queue, that arrives while the caller's next passage is held
settles nothing and tells the dispatcher nothing; one for a later passage
than the one held settles the one held, which the caller has left too, and
is remembered for its own.

A node of an older release sends a cancel with neither second, or with
`Cancelled-Timestamp` alone. The shard takes it as about the first
`member_call` of the queue that joined by the second the caller left, and
one with no second as made the moment it arrived, which it can be no
younger than, so the member of the passage it cancelled is still buried,
once. What that gives up is a caller who left and came back to the same
queue inside one second and whose second `member_call` overtook their
first, which is not something a caller does; the other way round is a
caller who has gone being rung for.

The cancel itself is acked by the shard actor, once it has settled the
member or noted the cancel, and by nothing else. The listener used to ack it
whatever the actor answered, and a cancel that reached an actor that had
gone, or went with the cancel still in its mailbox, was gone from the broker
having done nothing: the caller's `member_call` came back at the failover
with no cancel behind it, and a caller who had left was rung for. Unacked,
the cancel goes back with the channel too, and the next holder meets the
two in whichever order and settles the member once. It holds nothing up:
the member queue has no prefetch limit.

A cancel tells its own account's dispatcher the caller has left (`Left`),
and no other, and does not wait for it: what is left to do about a caller
who has gone is the dispatcher's, and one slow account must not hold every
other account's cancels on the shard behind it. A caller is handed to their
dispatcher the same way (`HandedOver`), told and not asked. The dispatcher
reads the caller's `queue_call` record before it rings anybody, and after a
failover with a slow datastore it reads one per redelivered caller, one
after another; a shard that waited on it used to stall every account behind
the slow one and go silent to the status responder. Nothing is
lost by not waiting: everything the shard tells a dispatcher is a send from
one process to another, so a cancel reaches the dispatcher after the caller
it cancels, and a dispatcher that ends with callers of its account still
held is replaced at once and handed every one of them, oldest first. A
dispatcher that could not be started is started by the account's next
caller, and handed the earlier ones too. Every question the shard does ask
a dispatcher goes through `callcenter/ask`, which hands the callee's exit
back as a value, and every dispatcher is asked at once with one short wait
between them (`ask.call_all`): how many offers they have when the shard is
asked to give itself up, a second in all, a dispatcher that does not say in
time counting as one ringing; and `Stop` when the shard is let go, a second
in all and then a kill.

### Nothing outlives the shard

The dispatchers are linked to the shard actor, which traps exits, so a
dispatcher ending is a message to the actor and ends nothing else. It is
that account's alone. The account's callers are still held by the shard,
deliveries and all, on a channel that is still open, so nothing has to come
back from the broker: the actor starts a fresh dispatcher for the account
and hands it every one of them, oldest first, and the fresh dispatcher
reads their records before it rings anybody, as one handed them by a
failover would. When that start fails, the dispatcher started for the
account next -- by its next caller, or by the sweep, however long after --
is handed them the same way; the sweep's used to be handed them as fresh
callers, and a caller whose agent had answered was rung for again while
the bridge was up. Every other account's dispatcher, and its offers, go on as
they were. It used to be the whole shard: the actor ended, every account's
dispatcher and offers with it, every member on the shard was redelivered,
and more than five of those a minute moved the shard to another node.

A dispatcher tells the shard when it starts on each caller it was handed
(`Digesting`) and when it has taken them in (`Digested`: decoded, record
read, any offer left ringing taken over), before the pass after. It does one
thing at a time and what it says reaches the shard before its exit does, so
a crash between the two is that caller's, and that caller takes a strike. A
crash anywhere else -- in the pass, on a tick, a reply, a cancel -- is
nobody's. The pass looks at every caller and agent of the account; before
this, a crash in it was charged to the caller whose arrival ran it, which
after a restart is always the account's oldest, and a pass bug set off by an
agent or a queue quarantined the three longest waiting callers in turn. A
caller whose own data trips only the pass is not quarantined either; the
storm limit below is what catches that. A caller with three
strikes in a minute is one no dispatcher on any node will get past, and
handing them back would crash the next dispatcher the same way for as long
as they waited, dragging the account's other callers through every restart
-- and before this, bouncing the whole shard six times a minute and moving
it between nodes. So they are quarantined: their member is settled, a
`QUARANTINED` error names the account, call, queue, join time, priority,
callflow node and caller id, and nothing else is done or published for
them. The trade-off is that caller: they are never offered to an agent, and
they stay in their callflow until they time out or hang up (their cancel
then settles nothing); their `queue_call` record is left as the crashed
dispatcher wrote it, for the sweep. Every other caller in the account is
dispatched. An account whose dispatcher ends unasked more than
ten times in a minute, crashes and stops alike, with or without a culprit,
is something this node cannot get past, and the actor ends on it as it used
to on the first: the tree restarts, the members are redelivered, and the
supervisor's own count moves the shard on if it keeps happening. A process
linked to the actor that is none of its dispatchers and crashes ends the
actor too.

The supervisor's shutdown is a message too: the actor asks each dispatcher to
stop, waits a second for it to be gone, kills one that will not go, and
then exits with `shutdown`. A dispatcher left running would ring the
shard's agents from a node that no longer holds it, beside the node that
does. Giving a shard up goes through the supervisor (`sys:terminate`), so
the listener's channel closes after the actor has finished, and the members
go back with it.

The callers' actors are the last of the tree's children, so they are the
first it stops: nothing of a shard this node no longer holds is commanded
from here. A dispatcher still running then hears each of them end with
`shutdown`. That is not a lost call: its call goes on, and whoever holds the
caller's actor next -- this node's tree started again, or the node the shard
went to -- finds it where it stands and says so (*Takeover*). So an offer
under an actor its supervisor shut down is let go of with nothing written,
published or settled. The calls only ever go with the whole tree: a crash
of their registry or factory is not started again on its own, which would
end every actor while the dispatchers and the members stayed, but takes
the tree down, and every member back to the broker. An actor that crashes, or is killed, still
has its offer closed as lost. In the lab of 2026-09-28 (`e2e-260927-cca10`)
a thawed node whose listener found its channel gone closed an answered call
this way, as `failed_bridge`, after the node holding the shard by then had
closed it: the call had two `member_result`s.

**A node that stood still.** A node whose VM stops -- frozen, or starved
of the CPU by its host -- loses its shards once the broker has heard
nothing from it for long enough: LavinMQ gives up after 15 seconds, and an
idle connection sends a frame only about every 10, so that can be five
seconds into the stop (15 to 16 seconds in the lab of 2026-09-28,
`e2e-260927-cca10`). The broker hands every member the node held to the
next consumer, and another node takes the shards over and every caller in
them. When the node moves again, nothing it runs knows that yet. Its socket
still holds what the broker sent before it gave up, the callers' events
among it, and the connection reads all of that before it reads that it is
closed. So for a moment every process of every shard it held went on as the
holder: in that lab a call actor thawed after its agent's blind transfer
took the caller for transferred, and its dispatcher wrote the passage's
record and published `member_result` -- which failed only because the
channel it went out on had gone -- for a call the next holder had already
closed.

The stall watch (`callcenter/stall`) notes the time every second, at high
priority, so that it is among the first to run when the node moves again. A
gap of more than three seconds between two notes is a stall. A call actor,
a dispatcher or a shard actor started before the last stall is fenced, and
so is every one of them while the last note is more than three seconds old
-- the node moving again, the watch not yet run. A fenced call actor and a
fenced dispatcher drop whatever they are handed, and write, publish, settle
and command nothing more. A fenced shard actor answers nothing, settles
nothing and ends, and the tree starts again, fresh; the watch tells every
shard of a stall before it logs it, so that one that is sent nothing ends
too. The listener then takes the shard back if it is still this node's, and
every caller in it is found out about again; or it finds the shard somebody
else's, and the tree ends. A call publisher drops the work of every actor
started before the stall, whenever its turn comes, whether it was handed
over before the stall or after.

Three seconds leaves room under the broker's five at worst for the backlog
a node works through as it moves again. What the fence catches is the
whole VM standing still: a VM that runs but is too busy to answer the
broker starves the heartbeat and not the watch, which runs ahead of it, and
a VM its host pauses may show no gap, since a guest's monotonic clock can
be held across the pause. A stall that lost nothing costs as much as one
that lost everything: every member goes back to the broker and is handed
out again, every caller is found out about again, the next sweep scans
every account for orphans as for a shard newly taken, and each shard's end
is a crash report. A caller half way out of the queue is handed back by
the actor that finds them (*Leaving*). A node with no watch -- no broker,
the tests -- is never fenced, and nor is one whose watch has ended, which
would otherwise fence every shard for good. What was already handed on
goes out -- the record writer's queue, what a dispatcher gave the node's
AMQP workers -- and a message a process was handling as the VM stopped is
finished as it moves again: all of it was decided while the node held the
shard.

Giving a shard up is a question to the actor first (`GiveUp`), which it
always agrees to once its callers' actors are steady, or three seconds have
gone by (`calls.quiesce`). Once it agrees it is *releasing*,
and that is a state of the actor, not of whoever asked. It stops its
dispatchers, answers, and ends its own tree, from a process of its own
since the supervisor stops the actor on the way. From the moment it agrees
it starts no dispatcher and hands no caller over: a caller who arrives is
held and goes back to the broker with the channel, and the shard answers to
nobody as held. The placement waits ten seconds for the answer and reads
no answer as a refusal; it used to be the only one who released the tree,
so an actor that was busy and agreed later stopped every dispatcher and left
the tree held on this node with nobody dispatching it, and a caller
arriving between the answer and the release started a dispatcher again.
Now a late agreement ends the tree all the same, and the placement sees the
tree go.

## The API

Two Crossbar nouns, `queues` and `agents`, started by the application while it
starts. A queue is an account document; an agent is a user with a
`call_center` object, so `agents` has no document of its own and no `PUT`.

`agents` is a noun wherever it appears in a path, so
`/accounts/{id}/queues/{qid}/agents` -- a queue's tiers -- is served by
`cb_agents` too, which finds the queue in the request's nouns. That is how
every Crossbar sub-resource with a noun of its own works.

Any user of the account may read queues, tiers, agents and live state.
Running the call center is an account administrator's or a superduper
administrator's (`callcenter/permission`): creating, changing and removing a
queue, adding, changing and removing a tier, eavesdrop and pickup, and
changing another agent's availability. Anybody else is a 403, asked first in
`validate` so that nothing else about the request is said, and Crossbar runs
no verb after a failed `validate`, so nothing is saved. An agent's own
availability is theirs to change.

A queue's tiers are held to one set of rules on every route that writes
them (`callcenter/tier_check`): one entry per user, a user the write adds
is an enabled user of the account, and `level` and `position` are whole
numbers from 1. The rules hold what the write adds or changes, not the
entries it leaves as stored, so a queue saved before the rules existed --
one user twice, a level of 0 -- can still be renamed and have other agents'
tiers written. A write that touches a user stored twice has to leave them
one. On create every entry is checked. A user lookup the database did not
answer is `datastore_unreachable` (503), not a 400 saying the user is not
there.

Both routes then validate the queue against `queues.json`, whose `level`
and `position` also start at 1, so a stored `level: 0` used to pass
`tier_check` and fail the schema all the same. The schema is now shown each
entry left as stored with a number it would refuse read as 1, and those
entries are put back as they were once it passes
(`tier_check.for_schema`/`restore`); the list keeps its length and order,
so the schema's errors still name the entries the client sent, and what the
write adds or changes gets the schema's defaults and coercion. Relaxing the
schema's `minimum` to 0 was the other way: it would have made the published
contract say 0 is a level, applied to every writer of the schema, while
Crossbar refused it on every route.

Eavesdrop and pickup take a call id and the supervisor's phone -- a
`device_id` or a `user_id` -- from the request body, and trust neither. The
queue in the path has to be the account's. The device or user has to be a
document of the account's own database, not deleted, with at least one
device that builds to an endpoint (not disabled, not on do not disturb): a
device of another account, an empty id and a user with no phone are a 400
on the field, before the switches are asked anything. The switches have to
say every channel under the call id is the account's, and a channel put in a
queue has to have been put in this one. A switch that did not answer is a
refusal, even when another switch answered for the call: the silent one may
carry another channel under that id.

**Whisper runs against the agent's leg.** FreeSWITCH's eavesdrop mixes the
supervisor into the channel it runs against: the `whisper` mode `ecallmgr`
asks for (`queue_dtmf:w2`, `ED_MUX_WRITE`) is what that channel's own phone
hears, `full` (`w3`) that and what it sends its partner. Every client has
the caller's call id, so a whisper against it was heard by the caller.
`listen` and `full` still run against the caller's channel; `whisper` runs
against its `Other-Leg-Call-ID`, which the switches are asked about as the
call was, and which has to be answered and bridged back to the caller -- a
caller nobody is talking to is a 400 `not_connected` on `call_id`.

**Pickup is an offer, made by the dispatcher.** It used to take the caller
out of the queue with a `transfer` cancel and then publish a metaflow
`intercept`; konami acts on that only for a call already running a metaflow
state machine, which it starts for a call whose own device or user has
metaflows, and a caller from outside has neither. The caller was settled, no
`member_result` told their action, Crossbar answered 202, and they sat on
hold music offered to nobody until they gave up. Now Crossbar asks the node
dispatching the account (`callcenter/pickup`: a `pickup_req` on
`callcenter.pickup.<account>`, answered only by the shard's holder, like a
status request) and the dispatcher rings the supervisor's phones for the
caller with the offer machinery an agent is rung with
(`callcenter/dispatcher/pickup`): the caller's own control queue, the bridge
that interrupts the hold and keeps the music as its ringback, the legs named
before they ring, and `member_offer` to the caller's action once the bridge
is out. The offer is held in the dispatcher's offers like an agent's, so the
pass rings nobody else for the caller meanwhile. Its replies are the
pickup's own:

- answered: the member is settled -- there, and nowhere else -- the
  `queue_call` record's `agent_id` is the supervisor (the user named, the
  device's owner, or an unowned device's own id) with `picked_up: true`,
  and `member_connected` and in the end `member_result` go to the action and
  the exchange naming the supervisor. No `agent_answered`, `agent_offer` or
  `agent_wrapup`, no counter, no wrap-up, no login lamp and nothing for a
  strategy: the supervisor did not take a queue call as an agent, even when
  they are one;
- not answered, busy, rejected, failed, or its process gone: the caller is
  still waiting, in the same place, and the next pass offers them to an
  agent. Nobody missed anything, and nobody is put on a delay;
- the caller hanging up or leaving the queue: as during an agent's ring.

The dispatcher answers once the offer has said what came of the ring: its
`OfferRinging`, the originate out to the supervisor's phones, is the `202`; a
`Failed` before it is `not_started` with the offer's reason, and its
`no_endpoints` -- the phones built to nothing on the caller's call, which
carries `Queue-ID` and is nobody's own device -- is a 400 on the phone's
field. It used to answer ringing as soon as the offer was asked for,
so a supervisor whose only desk phone was `exclude_from_queues` got a 202
and no ring. Crossbar's own look at the phones builds them for a call in
the queue, with the offer's endpoint properties, so that device is refused
before anything is asked. A bridge that goes out after the deadline the
question came with has nobody to tell and is called off at once.

Crossbar answers once the dispatcher has: `202` with the devices ringing,
`404` when the caller is not waiting in that queue (or nobody is dispatching
the account), `409` when a phone is already ringing for the caller or the
supervisor is already ringing or talking in the account, `500` when the ring
could not be started, `503` `no_answer` when the holder's dispatcher did not
answer in time or no holder answered at all -- which says nothing about the
caller, so it is not a `404`. The holder gives its dispatcher two of the
requester's three seconds, and tells it the moment past which it must start
nothing, so a supervisor told `503` has no phone ringing. The requester's
own deadline travels in the request (`Deadline-Ms`, system time in Unix
milliseconds): a holder that reads it late gives its dispatcher only what is
left of it, less the time its answer needs, and nothing when nothing is
left; and the pickup queue's message TTL is the requester's three seconds,
so the broker drops a request nobody waits for. The holder measured from
when it read the request before, so one that sat in its queue -- whose TTL
was a minute -- could ring a phone after Crossbar had answered.

What only a lab can say: that a PSTN caller in a queue is rung through to a
supervisor's desk phone and hears the queue's music until they answer; that
a device with `exclude_from_queues` is left out of a pickup as it is out of
a queue call, because the ring is built from the caller's call, which
carries `Queue-ID`; and that a node taking the shard over while a pickup
rings watches it as an agent's offer (the record's `offered_to` entry, marked
`pickup`, is what it reads), so a supervisor who answers then is counted as
an agent would be.

The user document has no supervisor role, so `priv_level` is the whole of
who may. The checks are in `validate` because a `true` from a noun's own
`authorize` binding would permit requests Crossbar's own authorization had
not.

The reference is `applications/crossbar/doc/queues.md` and
`applications/crossbar/doc/agents.md`.

## The feature codes

`cf_callcenter_agent` is one callflow action carrying all three codes; which
one it is comes from the callflow node's data. Put `toggle_login` on the
pattern `^\*22([0-9]*)$`, `toggle_login` with `require_pin` set on `*23`, and
`toggle_break` on `*24`. Switchboard creates the first with the featurecode
name `callcenter_agent[action=toggle_login]` and data
`{"action": "toggle_login"}`.

`*22` alone -- an empty capture -- is the caller's own login, exactly as
below. `*22<extension>` toggles the agent whose user `presence_id` is the
extension, which is what an `agent_login` key dials when pressed (see "The
login lamp"). The caller may always toggle their own extension; anybody
else's needs the caller, the call's owner, to have `priv_level` `admin`. The
target is looked up among the account's agents -- `agents/crossbar_listing`,
whose rows carry the presence id -- so an extension that is not an agent's is
refused like one that is nobody's: `agent-invalid_choice`, and nothing
changes. So is a phone with no owner, and so is `require_pin` with an
extension, which would mix "who is calling" with "for whom". The prompts say
what the target now is. Only `toggle_login` reads the capture; the other
actions ignore one.

A node's `presence_id` is copied to the agent's `callcenter_agent-<user_id>`
document before the change, and the login lamp is published there from then
on, from whatever changes the agent's availability. A node without one
leaves the stored value alone. Moving it turns the lamp at the old address
off and shows the current state at the new one.

Who the agent is comes from the call when it can: the call's owner, which is
the agent's own registered device and the whole of `*22` and `*24`. A call
from a phone that belongs to nobody has no owner, so the action asks for an
agent id and a PIN and looks the agent up by them.

`require_pin` asks for them however the call arrived, and is what makes `*23`
a hot-desking login rather than a second `*22`. A shared desk phone has an
owner like any other, and without the flag `*23` dialled there would log that
owner in whoever was standing at it. With it the agent who types the id and
the PIN is the agent logged in -- their own availability changes and the
phone's owner is untouched, whoever that is -- which is requirement 2.11. It
defaults to false, so a node without it behaves as before.

A login, a break or a resume is only for a user who is there, not deleted
and enabled, whoever dials it: the agent, an administrator's
`*22<extension>`, a `*23` typist. Anybody else hears `agent-invalid_choice`
and nothing is written, the lamp's `presence_id` included. A logout always
goes ahead. See "Who may work" under "Agents".

`timeout` on the node is how long a break it starts lasts, in seconds
(Switchboard's "Break ends after N seconds"). Absent or 0 is a break with no
end, which lasts until the agent resumes or something else changes their
availability; the schema's default is 0. Old acdc paused an agent for
`acdc.default_agent_pause_timeout`, ten minutes, when the node said nothing;
here nothing said is no limit, as the schema and Switchboard have always
described it. A break with an end ends by itself and puts the agent back
to exactly what they were before it: available or available on demand. See
"Breaks that end" under "Agents". Only a change to a break
reads it: `toggle_break` on an agent already on a break resumes them as
before, and an agent already on a break who is put on one again keeps the
break, and the end, they have.

The exchange is three tries at each of the id and the PIN, ten seconds
apiece, and the PIN is compared without a timing signal. An abandoned one --
a hangup, a silence, a wrong PIN -- writes nothing at all, so a refused `*23`
leaves both the typist and the phone's owner exactly as they were.

A hangup is the one of those that says nothing back. `cf_exe` relays a
channel's destruction to the action once, the collection the caller
abandoned has already taken it, and a prompt sent afterwards would be waited
on until the wait ran out -- holding the flow, the action and their bindings
open over somebody who is not there. So a hangup ends the flow and a caller
who is still listening gets the refusal.

Every path answers, says what the agent now is, and ends the callflow. The
prompt is played with `call.prompt_and_wait`: the ending hangs the channel
up, and a prompt merely queued behind it is torn down milliseconds after it
starts, so the agent would hear the code answer and then silence.

The prompts are `agent-logged_in`, `agent-logged_out`, `agent-on_break` and
`agent-invalid_choice`, plus `hotdesk-enter_id` and `hotdesk-enter_pin` for
the `*23` exchange. All but `agent-on_break` ship with the system;
`agent-on_break` has to be recorded into `system_media` before a break says
anything. Until it is, `*24` writes the break and plays nothing, and waits
no longer for it: a waited-for prompt is queued as a `play` with a `noop`
behind it, and a `play` that failed still advances the channel's queue, so
the `noop` runs and its completion ends the wait. Only the break is silent.

## Dispatching

The node holding a shard runs one dispatcher actor per account in it that
has had somebody waiting, started on that account's first member and kept
for as long as the node holds the shard; with nothing to time it sits on its
mailbox and ticks for nothing. One actor per account is what makes an
agent in two queues safe: every offer in the account is decided in one
process, in order, so two queues cannot ring the same agent for two callers.

Each pass over the account:

1. orders every waiting caller of the account, whatever queue they are in,
   by priority, then by age, then by queue id and call id so that the order
   is total — `time_base_score` of each caller's own queue decides which
   age, and `system`, the default, counts from when the caller entered the
   system so an overflow, a transfer or a callflow re-run does not send
   them to the back. "Entered the system" is the first queue the channel
   entered: nothing the platform sends says when a channel was created, so
   the callflow action stamps the channel with a `Queue-System-Joined`
   custom channel variable the first time and leaves it alone every time
   after. It lives on the channel, so the next queue, a transfer and a
   re-run route request all carry it; a caller the action never stamped
   counts from when they joined this queue. The same caller arriving in the
   same queue again keeps the older of the two joins. One order and not
   one per queue, because an agent in two queues
   is one agent: served queue by queue, a caller who has just joined the
   queue whose id sorts first would take them ahead of one who has waited
   six minutes in the other, and a steady flow into the first would starve
   the second. Priority is compared across queues as it stands; the queue
   document has no weight of its own;

   then, for each caller in that order, against their own queue's settings:
2. works out which tier levels that caller has waited long enough for
   (`tier_rules`, including `no_agent_no_wait`);
3. builds an `AgentView` per agent from their availability, this node's
   derived activity, their tier and their counters. The activity is read
   once at the start of the pass, the whole account in one answer from the
   node's activity actor, and asked through `callcenter/ask`: an actor that
   does not answer is logged once and nobody is ready until it does, where
   a `process.call` per agent per caller used to be the dispatcher's crash;
4. asks the queue's strategy for an ordered `Sequential` or a `Simultaneous`
   set, and rings them.

Steps 2 to 4 cost a caller next to nothing, because everything they read
is read once a pass, not once a caller (`dispatcher/view.snapshot`). Each
queue's settings, memo and number of callers are read once, and so is each
agent's availability document, however many queues they are in. Each
queue's views are built once, one per tier. An offer the pass makes changes
only what it touches: its agents are offering from then on in every queue,
and its queue's strategy has had its turn. The decision itself is
`dispatcher/plan`, a pure function of that reading, and the pass sends each
offer before deciding the next caller, because an offer that could not be
started leaves its agents free. The tier states come first, from memory, and
an agent's document is only read if they are ready in some queue. A queue in
which nobody could take a caller is offered nobody without its strategy
being asked, since a strategy only ever offers from `selectable`. When that
is every queue in the account, the pass decides nothing. When no agent is
ready in any queue, it reads no agent document either.
The announcements that follow reuse the same order and the same count of
available agents. With 500 agents and 200 callers, the pass the tick runs
while every agent is busy went from about 100 ms to under 1 ms
(`test/callcenter/pass_benchmark_test.gleam`).

An offer is bounded by the agent's ring timeout plus `offer_grace_s`; a miss
counts against `max_no_answer` and applies the agent's own reject, busy or
no-answer delay; `max_no_answer` reached moves the agent to the queue's
`agent_no_answer_status`. An answer settles the caller's member message —
the only place that ever happens — and the end of the call starts the
wrap-up.

### What counts as a miss

Misses are counted since the agent logged in, and an unanswered offer is
only theirs if they were still taking callers when it came back. An agent
who took a break, or logged out, while their phone was ringing did not miss
the caller: the counter on the document is not raised, no `agent_missed`
record is written, `max_no_answer` never sees it, and so the rule cannot
stand somebody down out of a status they chose for themselves. The delay
after a reject, a busy or a no answer still applies — it is about the phone,
and an agent nobody is offering callers to does not feel it — and the
caller's own record still says what each offer did.

An agent `max_no_answer` stands down is written to the new availability by
a process of its own, and until its `agent_availability` is heard the
document may still say they are taking calls. So the dispatcher also marks
them stood down and offers them nothing until that event arrives -- or, if
it never does, for thirty seconds, after which it logs and goes by the
document again. Without the mark the next tick could ring them once more.

Logging in starts the count again, in the dispatcher and on the document
alike: `missed` is the misses of this shift. A break does not, because a
break is a pause in a login and not the end of one — an agent who was on two
misses before lunch is on two after it.

A ring of several that nobody answers -- `ring_all`, or `ring_simultaneously`
above one -- is a miss for every agent it rang, each counted against their
own `max_no_answer` and each given their own delay: every one of those phones
rang out on somebody who was there to take the caller, and one miss shared
between them would let a whole team of agents who never pick up go on being
rung. An agent the ring was lost to by an answer elsewhere missed nothing.

A caller who hangs up, or leaves the queue, while the phone rings is not the
agent's miss either: the offer reports the caller gone, and the dispatcher
treats it as the caller leaving (*The offer*, below). Nor is a ring called
off -- an agent released by hand, a queue deleted -- or one that comes back
from an agent who was disabled or deleted while it rang.

The member message is acked when the caller has an agent or has left, and
never before. Losing the node redelivers every waiting caller to whoever
takes the shard next, in the order their arrival times give.

### Strategies

Six of them. `ring_all` rings every eligible agent at once and lets the
platform cancel the losers, which is the only arrangement where two agents
cannot both answer. The other five answer an ordered list and the dispatcher
rings `ring_simultaneously` of it at a time, one by default: `longest_idle`
(`most_idle` is an alias) takes whoever has been free to take a caller
longest, and is the default; `round_robin` carries on from the agent
this queue tried last; `sequential` starts at the top of the tier order for
every caller; `fewest_calls` and `least_talk_time` take the agent with the
fewest answered calls, or the fewest seconds on them, this login.

Only round robin keeps anything between callers, a cursor, and it keeps it
in the dispatcher's memory rather than on a document: a write per offer to
even out an order that is already only a preference is not worth it. A node
taking the account over therefore starts round robin from the top of the
list again, which costs one caller's worth of unevenness per takeover. The
cursor moves over the whole tier and not over the agents who happened to be
free, so an agent who was busy when their turn came is passed rather than
queued up for the next caller, and it moves as the phones start ringing
rather than as the offer ends: two offers out at once end in whichever
order the phones answer, and the older one ending last must not rewind the
cursor onto an agent whose turn is over. Answered, missed, lost or never
rung at all, the agent has had their turn. Each level turns on its own
cursor, the agent of that level rung most recently: the memo keeps the
agents rung, newest first, so a caller whose tier rules reach level 2 moves
level 2's turn and leaves level 1's alone, and the next caller, who may
only reach level 1, carries on round level 1 rather than starting at its
top. An agent taken off the queue hands the turn to whoever of their level
was rung before them.

The other five decide afresh every pass, from the agents' counters and the
tier order. What makes `sequential` and "one after another down the list"
the same thing is the caller's own list of who has rung for them: an agent
who has already had this caller is passed over until everybody who could
take them has, and only then does the list start again. The delay an agent
takes after a miss is theirs and not the caller's, and with the delay at
zero it has passed by the time the next phone rings out. An offer that
could not ring at all -- nothing registered, no bridge -- is not a miss and
counts against nobody, but the agent is left alone for a few seconds so that
a queue whose every endpoint is broken offers once per agent per interval
rather than as fast as the failures come back. The counters `fewest_calls`
and `least_talk_time` read are reset at login and live on the agent's
document, so they are the same numbers on whichever node dispatches; an
agent coming on at noon does not spend the afternoon catching up with one
who has been on since eight.

"Free to take a caller", for `longest_idle`, is the latest of three times:
the agent's last offer, answered or not; the end of their last queue call,
or of its wrap-up; and their last change of availability, which for an
agent who can be offered anything is their login or the end of their
break. So a fresh login is idle from the login, not for ever; a break is
not idle; and an agent whose phone rings out goes to the back instead of
staying at the top and adding a ring timeout to every caller while they
are away from the desk. The dispatcher keeps the offers and the call ends
it saw in its own memory (`dispatcher/worked`), because the counters on the
document are written by another process and read back through the
document cache, and the agent who hung up a moment ago can still look there
as if their last call ended an hour ago. The same memory overlays the
counts: the strategies are shown the document's `calls_answered` and
`talk_time_s`, or this dispatcher's own count of the calls it connected and
ended for the agent since they logged in when that is larger, so a call is
counted the moment it ends and never twice. A node that has just taken the
account over has none of this, and falls back to the document's
`last_call_end`, its counters and the availability's timestamp.

Level comes first in every strategy that answers an ordered list:
`longest_idle`, `fewest_calls` and `least_talk_time` sort on level and only
then on their own measure, `round_robin` turns within a level and keeps the
levels in order, and `sequential` is the tier order itself. So a free level
1 agent is always offered before a level 2 one, with or without
`tier_rules`; `tier_rules` decide when the higher levels may be offered at
all. `ring_all` rings everybody the tier rules allow, levels together. Ties
after the measure fall back to position, then agent id --
`strategies/tier_order` -- so the order is the one a supervisor set and is
the same on every node. A queue naming a strategy this release does not have
still dispatches: it falls back to `longest_idle` and says so in the log,
which is also what a queue still naming `top_down` gets, that having turned
out to be `sequential` under another name. Adding a seventh is a module
under `src/callcenter/strategies`, two lines in `callcenter/strategy`, and an
enum value in `queues.json`; nothing in the dispatcher changes.

## Agents

Two independent values, requirement 1.2a:

- **Availability** is what the agent, a supervisor or an automatic rule
  chose: logged out, available, available on demand, on break. It lives in
  `callcenter_agent-<user_id>` in the account database and `availability.set`
  is the only thing that writes it. Every change appends an
  `agent_status_change` document to the month database, publishes the
  agent's login lamp (below), and publishes `agent_availability`.
- **Activity** is what their phones are doing: idle, ringing, on a call,
  wrapping up. It is derived on every node from the channel events, keyed by
  the channel's `Owner-ID`, and a channel carrying the `Queue-ID` variable is
  a queue call. Nothing is exchanged between nodes for it. Ringing and
  wrapping up are the dispatcher's own and only show while the agent has no
  channel at all. Each is set for as long as it can be true -- ringing for
  the offer's ceiling, wrapping up for the wrap-up -- and is dropped when
  that runs out whether or not the dispatcher cleared it. The account is
  its dispatcher's: the activity actor monitors the dispatcher that
  watched it, starts a new dispatcher's account with no ringing or
  wrap-up on anybody, and forgets the account when its dispatcher goes,
  however it goes. A queue document changing reloads an account this node
  watches and never starts watching one.

  The same stream is how a caller who hangs up while waiting leaves at
  once. Every `CHANNEL_DESTROY` carrying `Queue-ID` in a watched account,
  owner or not, is told to that account's dispatcher by the channel's own
  call id, and a dispatcher holding that call id as a waiting caller lets
  them go; any other call id costs it nothing. This used to need an
  `Owner-ID` that was an agent's and passed on the agent leg's call id, so
  a caller from the public network whose callflow node had gone stayed
  waiting until the sweep, up to thirty seconds, and could be offered.

Activity self-heals from the switches: it is resynced on start, when a node
running `ecallmgr` expires, when a queue document changes, and every
`reconcile_interval_s` seconds. An answer every `ecallmgr` gave replaces the
channel table; one the timeout ended only adds to it. No answer changes
nothing, and that includes nobody to ask: while `kz_nodes` counts no
`ecallmgr` -- one restarting, a zone that does not match -- the query
finishes at once with nothing in it, and `events.account_channels` reads that
as no answer, as a single call's status always has, not as every switch
saying "no channels", which would read every agent on a call idle.

An answer is no newer than its question, and the channel events go on while
it is given. Each question is stamped with how many channel events the actor
had heard when it was sent, each channel with the event that last put it in
the table, and a destroyed channel's call id is kept for a minute
(`destroyed_kept_s`). No answer puts back a channel whose destroy has been
heard: one given just before the destroy and arriving after it used to put
the agent back on a call nobody was on, and while any `ecallmgr` kept timing
out no answer took it away again, so the agent was never offered a caller.
And a whole answer does not take away a channel whose create came after the
question was sent.

Do-not-disturb on a user holds the agent at logged out, and clearing it puts
them back where it found them (`callcenter/dnd`), from the `doc_edited` every
user save publishes. Those edits come off one queue, `callcenter_dnd`, shared
by every node and holding up to 10,000 of them, so each edit is followed by
one node: a queue per node handed every node every user edit in the cluster,
and they raced each other to the same `availability.set`. Behind the events,
every `reconcile_interval_s` the sweep reads the agents, availabilities and
tiers of each account this node dispatches -- three views -- and follows
do-not-disturb for the agents whose flag and availability disagree, so an
edit that was lost is followed a sweep later.

A user who is disabled or deleted stops being an agent anybody rings, off the
same shared queue, which carries user deletions as well as edits:

- **Disabled** (`enabled: false`): logged out, with `source` `system`, and
  their tiers kept, so that enabling them again brings them back in every
  queue, logged out. Nothing logs them back in, do-not-disturb clearing
  included, while they are disabled or once they are enabled again: an
  agent do-not-disturb had already logged out has that logout made the
  system's (`source` `system`, `previous` `logged_out`), because left as
  do-not-disturb's it was undone when do-not-disturb was cleared, in
  whichever order that and enabling them came.
- **Deleted** (`doc_deleted`, which Crossbar's soft delete publishes too, or
  a user document that is gone): taken out of every queue's tiers (the
  `callcenter/queues_by_agent` view finds them), logged out -- which writes
  the `agent_status_change` history to the month database and publishes the
  change -- and their `callcenter_agent` document deleted, since the user it
  belonged to is gone.

The dispatcher does not wait for either. Every agent it would count available
or offer a caller to has their user read, from the document cache their
settings come from and only when their availability says they are taking
calls: a user who is disabled, deleted, gone or on do-not-disturb is logged
out as far as the dispatcher is concerned, never offered and never counted
in `Agents-Available`, whatever their availability document still says. A
ring that comes back unanswered from an agent disabled, or put on
do-not-disturb, while it rang is not their miss. The sweep follows both as it follows do-not-disturb: a disabled agent
who is not logged out, and an availability document or a tier naming nobody
the agents' listing has, are looked at again.

The Crossbar listing, one agent and a queue's tiers all mark a disabled
agent `enabled: false` and list them, logged out; a deleted user is in none
of them, and reading one by id is a 404.

### Who may work

Nobody is made available, available on demand or put on a break who is not
a user that is there, not deleted (`pvt_deleted`), enabled, and without
do-not-disturb (`agents.fit_to_work`). It is one rule, in
`agent_state.change`, which every route a person asks through goes by, so
they all refuse alike and write nothing:

| Route | Refused as |
|---|---|
| `*22`, `*23`, `*24`, and an administrator's `*22<extension>` | `agent-invalid_choice`, and the node's `presence_id` is not stored either |
| `PATCH /agents/{id}/status` | a `400`, `forbidden` on `availability`, for a disabled user or one on do-not-disturb, the message saying which; a deleted one is already a `404` |
| `sup callcenter_maintenance set_agent` | a `refused:` line naming why |
| a break that ends by itself | the break is not ended; the user's edit, or the sweep, logs them out |

Do-not-disturb used to be left to its listener: an agent on it could dial
`*22` and be made available, no user edit was published to say so, and
they were rung and missed until the sweep logged them out. It refuses a
break as well as a login: do-not-disturb holds the agent logged out, and a
break is only for an agent who is logged in, so one taken in the moment
before the listener acts would be taken away again at once.

Logging out is always allowed. A user the datastore could not answer for is
refused too: unlike a caller waiting to be offered, a person asking can ask
again. The application's own changes decide for themselves: do-not-disturb
restores only an enabled user (a disabled or deleted one goes down the
paths above), and the no-answer rule only ever stands somebody down.

### Breaks that end

A break started with a timeout -- the feature code node's `timeout`, or
`timeout` on `PATCH /agents/{id}/status` -- ends by itself that many seconds
after it began (`callcenter/breaks`). The end is stored on the agent's
`callcenter_agent-<user_id>` document as `break_ends`, in Gregorian seconds,
by the same write that starts the break, so it outlives the node that wrote
it. Every other change removes it: a resume, a supervisor, a logout, a
disabled or deleted user. Do-not-disturb logs the agent out too, and keeps
the break as `held_break` -- its end and what it goes back to -- so that
clearing it gives the agent the rest of the break, ending when it was going
to, or, once that end has passed, what the break would have ended to.
Restored as a break with no end, it used to last until somebody noticed. The end is the application's own
change, source `system`: the status log, `agent_availability` and the login
lamp say so as for any other.

A break is a pause in a login, so only a logged-in agent is given one: `*24`
says `agent-logged_out` to an agent who is logged out, `PATCH .../status`
answers `on_break` for one with a `400`, `forbidden` on `availability`, and
`sup callcenter_maintenance set_agent` refuses it (`agent_state.change`).
The end goes back to exactly what the agent was before the break --
`available` or `available_on_demand` -- and anything else, a break that
somehow began logged out included, ends `logged_out`. Nobody is logged in by
a break running out: an agent who never logged in is never rung ten minutes
after a supervisor's break. A resume (`*24`, or a change to available) is
the agent asking to be back, and goes to available whatever came before. `agent_availability` carries `Break-Ends` while
the agent is on a break with an end, and so does `GET .../status`.

Who ends it:

- **The node that started it**, on a timer of its own: a process asleep until
  the end, not linked to the feature code's call. This is the normal case,
  and it is on time to the second.
- **The sweep**, when that node is gone. Every `reconcile_interval_s` each
  node reads the availabilities of the accounts it dispatches -- the
  `callcenter/agents` view, whose rows carry `previous` and `break_ends` --
  and ends any break more than `sweep_grace_s` (five seconds) past its end.
  The grace keeps the sweep off a timer that is about to fire. After a node
  loss a break ends within one sweep and the grace.
- **The shard scan**, behind the sweep. An account nobody dispatches has no
  sweep; the scan of every shard a node takes, and of every shard it holds
  each twentieth sweep, ends its overdue breaks (the scan reads only
  accounts that have a queue). Such an account has no
  caller waiting, so nobody is kept waiting by the late end, and the sweep
  takes over as soon as a caller arrives and a dispatcher starts for it.

Ending a break twice is harmless, because it is not possible: every end is a
compare-and-set (`availability.set_if`). The document is read from the
database, the break is ended only when it still says `on_break` with the very
end the timer or the sweep was set for, and the write is made over the
revision that was read. A change anybody made in between is a conflict; the
document is read again and the decision is taken again from what they wrote,
which is nothing to do. A break resumed and taken again has another end, so
the first break's timer ends nothing.

### The login lamp

A BLF key can show an agent's login. It is opt-in: the call center never
publishes on a user's own presence id, so ordinary line and presence keys --
an agent's included -- are untouched, and only a key provisioned as
`agent_login` (or pointed at a feature code node's `presence_id`) shows
anything. Only agents are published for: users with a
`callcenter_agent-<user_id>` document.

| Agent | Dialog state |
|---|---|
| logged out | `terminated` |
| on break | `terminated` |
| available, available on demand | `confirmed` |
| on a queue call, answered until it ends (wrap-up is not a call) | `early` |

Phones choose the colours. The address is, in order:

1. the `presence_id` stored on `callcenter_agent-<user_id>`, which the
   `callcenter_agent` action copies from its node's `presence_id` whenever
   the node that ran has one. A node without one leaves the stored value
   alone, so every later change -- Crossbar, do-not-disturb,
   `max_no_answer` -- publishes where the agent last pointed it. It is
   qualified with the account realm unless it has an `@`, and it is ignored
   if it is the agent's own presence address;
2. otherwise `<prefix><user presence_id>@<account realm>`. The prefix is
   `agent_presence_prefix` in the account's `configs/callcenter` (Crossbar
   `/v2/accounts/{id}/configs/callcenter`), then its reseller's, then
   `system_config/callcenter`, then `*22`. An empty prefix is `*22`, never no
   prefix. The provisioner renders an `agent_login` key with the same
   address, so pressing it dials `*22<extension>`, which toggles that agent
   (see "The feature codes");
3. a user with neither gets no lamp, and one line at info says so.

The dialog's call id is the MD5 of the address, so one address is one dialog.

`availability.set` publishes every change as if the agent were not on a
queue call. The dispatcher knows better: it publishes `early` when an offer
is answered or an answered call adopted, and the then-current availability's
state when the call ends. It hears every `agent_availability` of its account,
and for an agent on a connected call there it publishes `early` again, so a
change made mid-call shows the new availability's state for a moment and then
`early`. That flicker is accepted. The dispatcher remembers what it last
showed each agent and publishes only a change.

Kamailio keeps a dialog update only while somebody is subscribed to it, so a
phone that subscribes after the last change -- a reboot, a newly provisioned
key, a new device -- finds no state there. Kamailio then asks for it: a
`presence` `probe` with `Event-Package` `dialog` and the subscription's
`Username` and `Realm`, under `probes.dialog` (`REQUEST_PROBE` in
`presence-role.cfg`, on a new subscription only; a refresh or a registration
asks nothing). `callcenter/lamp_probe` answers it:

- One queue, `callcenter_lamp_probes`, shared by every node, so each probe
  reaches one node: every BLF on the cluster is probed under that one key,
  and a queue per node would hand every node all of them.
- The realm names the account, and the address is answered only when it is
  one of the account's agents' lamps, worked out as every publish works it
  out: the stored override, then `<prefix><presence_id>`. A user's own
  presence address is never answered, and neither is any other BLF.
- The state is the agent's availability, read then, and `early` when they
  are on a queue call. The node holding the account's shard knows that: its
  dispatcher when the answering node is the holder, otherwise the holder's
  `status_resp`, whose `On-Queue-Call` lists them. No answer is nobody on a
  call.
- An account's agents are read once and kept for two seconds, together with
  "no such realm" and "no agents", which is what nearly every probe of a
  reboot storm gets. Probes that arrive during a read wait for it, and the
  lamps found wait together for one question about queue calls.

What is kept decides only whose lamp an address is. The address and the
availability are read again when the answer is made, so an override moved a
moment ago is not answered at the old address. An answer and a change made in
the same instant can still reach Kamailio in either order.

## Call path

A caller in a queue is three things on three nodes: the queue's callflow
action on the node that routed the call, their member on the shard's member
queue, and their actor on the node holding the shard. Only the actor decides
what the caller's channel is sent, one message at a time, and all of it goes
out through the one publisher its call is given, on one channel.

### The caller

The callflow action (`cf_callcenter`) answers the caller, asks whoever holds
the shard whether the queue will take them (`status_req`: shut, full, no
agents), marks the channel with where it joined, and publishes `member_call`
-- confirmed and mandatory -- carrying the passage's own `Handoff-ID` and the
`Branches` the callflow could go on into (`_`, `exit_key`, `timeout`,
`no_agents` and `no_agent_timeout`, each as `cf_exe:next` has it, the whole
under 32 KB). Then it sends the channel nothing. It waits for the actor to
hand the caller back: a `member_continue` naming its `Handoff-ID` is
answered with `member_continuing`, the channel is marked `Queue-Departed`
for the passage, and the callflow goes on down the branch. The channel going,
or four hours, stops it. So does the caller being bridged -- to the agent the
queue put them through to, or to a supervisor who picked them up -- and that
ends the callflow without touching the channel (`control_usurped`): nothing
is handed back after it, and an executor kept up through the conversation
hangs its channel up if its node stops, which drops the call.

The shard holds the member until the call is over (*One ack per member*),
and the dispatcher joins the caller to their actor.

### The caller's actor

One actor per call of an account, covering every passage of it through the
account's queues, on the node holding the account's shard. The shard's
registry (`callcenter/call/calls`) is the only thing that starts one and
never hands out one that has ended; the actors run under a factory
supervisor beside it, the last child of the shard's tree, and go with the
shard.

Everything the actor decides is `callcenter/call/core`: a pure step from the
call, one input and the time to the call after and the effects to perform,
in order. `callcenter/call/actor` is the shell: it turns what arrives into
inputs -- the dispatcher's messages; the caller's and every leg's events,
bound per call id through `kz_events:bind_call_id`; and the answers to what
it asks, which come to its own address, `pid://<actor>/<queue>` on the
node's reply listener (`callcenter/call/replies`) -- and performs the
effects from its one process. The call is always in one phase, and what it
may send the caller follows from the phase alone (`core.allowed`, held by a
property test): media only while waiting; the answer's marks, and the
`noop` that shows they ran, only as a leg answers; the bridge only out of
the wait that follows, never in the step that marked; the recording only
while connected; the departure's marks and barrier only as it leaves.

**Publishing.** The actor publishes nothing itself. `kz_amqp_assignments`
gives every process that publishes a channel of its own for the rest of its
life, so an actor publishing its own commands was a channel per queued call,
and a node with a couple of thousand callers would reach the broker's
`channel_max` for its connection (2047 on RabbitMQ), past which the broker
refuses every new channel (`out_of_channel_numbers`) and no actor can ring
or command anybody. Instead each node runs a few call publishers
(`callcenter/call/publishers`): `call_publishers` of them
(`system_config/callcenter`, 16, at most 256), each asking for one channel
as it starts. The actor hands everything it would publish -- every command
to the caller's control queue, the offer's `originate_req`, the legs'
hangups, `member_continue` and `callflow.resume` -- to the publisher its call
id hashes to (`erlang:phash2(call_id, call_publishers)`), as a message, in
the order the core decided it. One sender, one publisher and one channel
keep that order to the broker, and the last four, which went through the
node's worker pool -- whichever worker was free, on its channel -- now go
out on the same channel as the caller's commands. A node's channels for its
calls are `call_publishers`, however many calls it holds.

What is sent to a process stays with the actor: the dispatcher's replies and
the shard's word that the caller left go from the actor's own process, so
that the dispatcher, which watches the actor, never hears the actor's end
before its last reply. So a reply can overtake a publish decided in the
same step: the dispatcher can hear a ring's no-answer before the legs'
hangups reach the broker, as it could when those went through the worker
pool. The answers to what the actor asks still come to the actor's own
address, which it names in what it hands over. A shard asking its calls to
be steady before a handover hears from each actor through its publisher,
behind what the actor handed it, so nothing a call decided before it
answered is still waiting to go out when the next holder looks at the
caller. What a call decides after that and before its shard's tree ends can
still be queued, and goes out behind it. A
publisher runs each call's work under a catch -- a crash is logged against
the call, and the calls queued behind it lose nothing -- and one its
supervisor is starting again drops what is sent to it, logged. A node that
runs no publishers, having no broker, publishes from the actor, where every
publish is unavailable anyway.

**Waiting.** The queue's greeting, then hold (`kz_endless_playback`, whose
input callback reads the exit keys while it plays), and the announcements;
the caller's own clocks (`callcenter/caller`) take them out. An announcement
flushes the hold before it plays: a callflow executor that stops queues its
channel's hangup on the way out, which the endless hold keeps from running
and an announcement that only interrupted the hold would let run.

**An offer.** One `originate_req` rings every device of every agent the
dispatcher chose, at once (`call/originate`), whatever the strategy that
chose them:

| Field | Why |
|---|---|
| `Existing-Call-ID`, `Switch-Nodename` | the legs start on the caller's own switch, where the bridge can reach them |
| `Application-Name: park` | the leg that answers parks and waits for the actor |
| `Start-Control-Process: false` | nothing but the actor commands a leg, by name |
| `Ignore-Early-Media` | a phone's 183 is not an answer |
| `Dial-Endpoint-Method: simultaneous` | every endpoint at once; the switch ends the rest `LOSE_RACE` |
| `Outbound-Call-ID` per endpoint | legs named in advance, `<offer's leg prefix>-N` |
| `Custom-Channel-Vars` | `Account-ID`, `Queue-ID`, `Queue-Call-ID`, `Queue-Joined-Timestamp`, `Queue-Offer-ID`, `Queue-Offer-Deadline`, `Queue-Owner`, `Queue-Pickup`, `Agent-ID`: in `ecallmgr`'s channel table from the leg's birth, which is how a node taking the caller over finds them |
| `Media-Control.park_timeout` | an answered leg nobody bridges hangs itself up after ten seconds |
| `Msg-ID` | the leg prefix, which the answer echoes |

The caller hears their hold all through. The first leg to answer decides
the call, however its answer is heard first: its `CHANNEL_ANSWER`, its
`park`, which only an answered leg runs, or the originate's own success.
One channel's events can come out of order, and the originate's answer
comes by another road. The caller's channel is marked with the agent and
the second then, while they are still on hold. The marks are on the
caller's CDR, and they are what a node taking the call over dates the
answer by.

A `set` sent with `Insert-At: now` is not run as `ecallmgr` takes it.
`mod_com_kazoo` queues it on the caller's channel as a priority private
event and answers `+OK`, and the channel runs it the next time it looks,
within a frame of its hold. The bridge's flush empties that queue
(`uuid_break <caller> all`), so marks sent in the same breath as the bridge
are lost whenever the flush gets there first. So a `noop` goes at once
behind the marks, with a known `Msg-ID` (`callcenter-marked-<leg>`). The
channel runs the commands sent it at once in the order they came, and the
`noop`'s completion says the marks have run.

The caller is bridged once that completion is heard and the leg's
originate has finished with it: the leg's `park` is heard, or the
originate's own success, or 150 ms have gone by since the marks went out,
the switch running that `park` within 40 ms of the answer. A leg bridged
sooner is taken back out of the bridge by that `park` (the lab of
2026-09-27, `e2e-260927-cca2`). Marks not seen to run in those 150 ms are
waited for no longer: the bridge goes out, with a log that they may be
lost. The wait is kept short: until the bridge the agent's leg is on its
own, and the switch refuses a blind transfer from it. A caller heard
bridged to that leg while it waits is through, and waits no more: only a
caller found parked is, whom the last actor had bridged after its own marks
ran, dying before the survey listed the bridge. Bridged to anybody else's
channel, something that is not the queue has taken the caller.

The bridge is on the caller's control queue: a `noop` that flushes the
hold, then `connect_leg` run at once, not queued, so that the caller's
queue keeps running, with `Park-After-Pickup`, which `ecallmgr` sets on
both channels through the switch's API before the bridge. So the caller
parks rather than hangs up when the agent's leg goes, and the agent's leg
parks when the caller goes, and is hung up by the actor. The caller's own
`CHANNEL_BRIDGE` naming the leg is the connection: the recording starts,
and the dispatcher hears `Answered`. A bridge that has not shown in five
seconds is hung up, and the caller is put back on hold. Either side
hanging up between the answer and the bridge ends the call as the answered
call it is: the dispatcher hears the answer and its end, and the other
side is hung up.

**The race.** An answer, a key, a clock running out and a call-off can all be
in flight at once. Whichever the actor handles first stands: a leg that
answered first is bridged, and the dispatcher accepts that answer even for an
offer it has called off; an exit that came first hangs every leg up, one that
has just answered included.

**A call-off** -- the caller leaving, the agent released, the queue
deleted, a pickup let go -- hangs the offer's legs up by name, through
`ecallmgr`'s `call_command` hangup (`uuid_kill`), and hangs up any leg of
the offer that turns up later as it does. That never touches the caller.
Nothing ever parks or unbridges the caller.

**The caller hanging up while the phones ring.** The ring is called off at
once, but the shard hears the caller left only once the ring is over, or
two seconds later (`desertion_ms`). The caller's end and a leg's answer are
events of two channels, and nothing orders them. An agent who answers just
as the caller hangs up may be heard answering second. In the lab of
2026-09-27 (`e2e-260927-cca5`), a call answered like that was never
counted. So the call-off watches its legs. A leg whose answer the switch
dates before the caller's end, by `Event-Timestamp` on the caller's
switch's one clock, makes it an answered call that the caller ended: the
dispatcher hears `Answered` and `Ended(caller_hangup)`, and the counters,
the record and the wrap-up are an answered call's. An answer dated after
the caller's end is an agent picking up a caller already gone, and is no
call.

**Connected.** When the agent's leg goes the caller parks; the end waits
`transfer_wait_ms` for a sign that it was a transfer, and hangs the caller up
if none came (`call/talk`). When the caller goes, the leg parks and the
actor hangs it up. A transfer ends the queue's part and leaves the caller
alone, on their way to the target. The agent's leg is hung up then too: the
bridge's `park_after_bridge` parks it rather than letting it end. In the lab
of 2026-09-27 (`e2e-260927-cca5`), a leg stayed parked for 45 minutes after
a blind transfer, and the agent's phone was busy with it. A leg the
transfer itself is moving (its own `CHANNEL_TRANSFEREE`) is left alone. The
dispatcher hears `Ended`, and settles the member.

**The audit.** Every thirty seconds a waiting, ringing or connected call
asks every switch about the caller, and about the agent's leg once they are
through (`channel_status`, off the actor's own process). A channel every
switch disowns is taken as gone, as its `CHANNEL_DESTROY` would have been:
an event lost on the way would otherwise leave a caller nobody hears go, or
an agent held busy for the four hours a call is watched at most.

**Leaving.** An exit key, a clock, or a deleted queue takes the caller out:
their legs are hung up, the shard is told they are leaving
(`CallerDeparting`; a deleted queue is the dispatcher's own doing), the
channel is marked `Queue-Departing` and `Queue-Departing-Branch`, and a
`noop` run at once behind the marks shows they ran. Only then does a `noop`
that flushes go out with a known `Msg-ID`: its flush would throw away marks
not yet run, and the marks are what a node taking the caller over on their
way out finds them by. Marks not seen to run in a second are waited for no
longer. The flush's completion proves `ecallmgr` has run everything the
actor sent before it, and only then does `member_continue` go to the
action's Controller-Queue, asked again every two seconds, three times, until
the action says `member_continuing`.

The shard tells the caller's dispatcher they are leaving, which lets them
go as it lets a caller who left go -- their place, their ring, their record
closed -- but keeps their member. The departure is over when the callflow
has them back, a resumed flow took them, they are gone, they joined the next
queue, or they were hung up for want of a flow; in that step the actor has
the shard settle the member it kept (`Settle`, naming the delivery). Until
then a shard that ends -- handed over, its node stopped or stood still, its
broker connection gone -- gives the member back to the broker, and the
actor of the tree that takes the shard next finds the caller on their way
out and hands them back itself (*Takeover*). Settled as they left, as it
was, a caller whose actor ended half way out was handed back by nobody: the
action waited up to four hours, and they heard hold or silence until they
hung up. An actor that crashes half way out is replaced as a waiting
caller's is: the dispatcher watches it until the departure is over, and
joins the caller to a new actor that finds them leaving. A caller a deleted
queue takes out is settled at once, as before: an agent who answered before
the actor heard of the deletion has the caller, and nobody would ever hand
back a caller the actor bridged.

**The callflow's node gone.** An action that never answers is on a node
that has gone. Before the caller is resumed elsewhere their channel is
probed, and a `Queue-Departed` of this passage is the action having taken
them after all, its answer lost. Otherwise they are resumed at the branch
through `callflow.resume` on whichever callflow node takes it, with
`callcenter_departed` in front of the branch's flow: it marks the channel
`Queue-Departed` as the action would have, so that a node taking the caller
over later does not hand them back twice. A branch with nowhere to go hangs
the caller up.

**A resume nobody takes.** Nothing on the bus says a resume was taken. The
callflow node that takes one first asks the switches whether the channel is
up, and when that fails it drops the resume without a word
(`cf_route_resume:handle_if_up`). Or no node takes it at all. The caller's
callflow is gone, so only the actor can notice. It stays after the resume and watches the
caller's channel (`Resumed`). `callcenter_departed` writes the passage's
`Queue-Departed` mark before the flow runs anything else, and every event
carries the channel's variables, so the first event with the mark ends the
watch. So do the channel's end, a late `member_continuing`, and the caller
joining a queue again. If no mark shows in eight seconds (`resume_ack_ms`),
the actor probes the channel with a `noop` run at once, whose completion
carries its variables. A completion without the mark, or no completion in
three seconds, means nobody took the resume, and the actor publishes it
again. The wait is long on purpose. A resume published again while the
first is still starting would run the branch twice on one channel. After
the third try (`resume_attempts`), about half a minute on, the actor logs
an error and hangs the caller up. The caller has heard silence since the
departure's barrier flushed their hold, the queue has no hold to give them
any more, and a caller who is hung up can call back.

**Quarantine.** An actor that crashes is not restarted: the dispatcher
joins its caller to a new one, which finds out where they stand
(*Takeover*). A call whose actors keep crashing is one this code cannot get
past, so the registry counts each call's crashes over ten minutes. From the
third, the actor it starts is quarantined: it asks nothing and tries
nothing, hands the caller back on `no_agents` through the usual departure,
their member settled once it has, as `quarantined`, logging `QUARANTINED`. From the sixth -- the
quarantine itself crashing -- it starts none, and the caller is left as the
switch has them.

A caller handed to an actor that does not know them is *Takeover*'s.

### What they say to each other

| From | To | What |
|---|---|---|
| dispatcher | actor | `Join` (a caller joined, or was handed over: `resumed`), `Ring`, `CallOff`, `QueueGone`, `Positioned`, `Adopt` (an answered call the sweep found) |
| actor | dispatcher | an offer's `OfferRinging`, `Answered`, `OfferNoAnswer`, `Busy`, `Rejected`, `Failed` and `Ended`; `Present` for a caller handed over |
| actor | shard | `CallerLeft`: a caller who left of their own accord, settled; `CallerDeparting`: a caller leaving on a branch, their member kept; `Settle`: a departure over, the member kept settled |
| shard | dispatcher | `Left`: a caller who left; `Departing`: a caller on their way out, let go of but not settled |
| actor | action | `member_continue`, through the call's publisher, answered with `member_continuing` at the actor's own address |
| actor | switch | the caller's commands on their control queue, one `originate_req` per offer, `call_command` hangups of legs, all through the call's publisher on its one channel |

## Reconciliation

| What | When |
|---|---|
| the channel table, against `query_account_channels` | start, media node expiry, queue document change, every `reconcile_interval_s` |
| a waiting caller whose channel is on no switch | `CHANNEL_DESTROY`, and every `reconcile_interval_s` through `channel_status`: the dispatcher closes the caller itself only while nobody is being rung for them. With an offer out, the caller's actor decides, since it alone knows whether an agent answered first (the lab of 2026-09-28, `e2e-260927-cca6`) |
| a caller, or a connected agent's leg, whose end was never heard | their actor's audit, every thirty seconds, through `channel_status` |
| an offer that never came back | the agent's ring timeout plus `offer_grace_s` |
| a wrap-up, a per-agent delay | the dispatcher's own second-by-second tick |
| a dispatcher whose shard was lost | the shard's tree stops and takes them with it |
| a shard held on a node it is not assigned to | the next want from the node it is assigned to, every placement tick |
| a shard that did not answer being given up | the next want, and released anyway after `patience_ms` |
| a shard nobody consumes | the next placement tick of the node it is assigned to, or of any node after `orphan_ms` |
| a caller whose offer was left ringing on a node that died | the redelivery of their member message |
| an agent whose do-not-disturb and availability disagree | a user edit, off one shared queue, and every `reconcile_interval_s` for the accounts this node dispatches |
| an agent who was disabled or deleted | a user edit or deletion, off the same queue, and every `reconcile_interval_s` for the accounts this node dispatches; the dispatcher never offers them meanwhile |
| a break whose end has come | the timer of the node that started it; every `reconcile_interval_s`, five seconds late, for the accounts this node dispatches; and the shard scan for the rest |
| a queue deleted with callers waiting in it | the `doc_deleted` every node hears, and the next pass that reads the document, from the database at least every `queue_refresh_s` |
| a call answered on a node that died and never closed | the sweep that finds this node holding a shard it did not hold before, and every twentieth sweep behind that |

"On no switch" is every `ecallmgr` having answered and none of them carrying
the call. A channel status the timeout ended with only `terminated` in it is
not that: the switch that was slower than the query may be the one carrying
the caller, so it is nothing, and the next sweep asks again. One answer
carrying the call is the call being up, whoever else was late. The channel
table is held to the same rule the other way round: an answer every switch
gave replaces it, and one the timeout ended only adds what it names, because
an agent whose switch was slow is still talking and a table that said
otherwise would offer them callers.

### Takeover

A node handing a shard over stops dispatching and gives its callers'
actors three seconds to finish what the next holder could not see, and goes
(*Placement*). A node being killed does not even do that, and neither does a
broker giving up on one, so the node that takes the shard next meets callers
whose phones are already ringing and conversations that are already going
on. Dispatch state was in the node that
died; what is left is the caller's own `queue_call` document and the call on
the switch.

**Nobody is offered before the switches have answered.** A dispatcher that
has just taken its account watches it asynchronously, and the activity actor
starts the account with an empty channel table; the switches' answer comes
up to two seconds later. Offered in between, a redelivered caller would go
to an agent on a personal call, or to one still talking to a caller the dead
node connected, because both look idle to a table that has seen no event for
their calls. So until the first answer arrives -- whole or not, since one a
slow switch missed only adds -- the dispatcher offers nobody and its callers
wait, for at most five seconds, after which it logs that it is going on the
channel events alone.

The same holds when the node's activity actor restarts. It is one per node
under a `one_for_one` supervisor, and the new one watches nothing: it hears
no channel event of the account, its table is empty, every agent reads idle
and no dispatcher is told `ChannelGone`. Its reading says the account is not
watched, and a dispatcher that reads that -- however long it has been synced
-- logs it, watches the account again and goes back to waiting for the
switches, with the same five-second ceiling counted from the new watch. A
dispatcher's own watch is sent from its process before any read, so an
unwatched reading is only ever the actor having lost it. The watchers are
not kept across the restart in the supervisor instead: the new actor's table
would be just as empty until the switches answer, so the dispatcher has to
notice and wait either way, and watching again from the dispatcher is the
one mechanism that does both.

**A caller the dispatcher did not see join** -- a member the broker has
handed out before (its `redelivered` flag, and nothing else), a caller handed
on from a dispatcher of this node that ended, or one whose actor ended while
they waited -- joins their actor `resumed`, and nobody is rung for them until
the actor has said where they stand (`Present`), or for `present_wait_s`
(sixty seconds) if it never does. A first delivery is asked nothing: finding
out is the price of a failover, not of a call.

An actor already running the caller's passage knows, and says so at once:
it is the dispatcher that is new. One that has just started finds out
(`callcenter/call/recovery`), with three questions asked at once:

- **the probe**: a `noop` run at once on the caller's channel, whose
  completion carries the channel's variables as they are now, the marks the
  last actor wrote among them;
- **the switches**: the account's channels from every `ecallmgr`, asked once
  per account for every actor that wants them while a question is in flight
  or under two seconds old (`callcenter/call/snapshots`). The caller's legs
  are the rows whose `Queue-Call-ID` is the caller's and whose own call id is
  their offer's name for them, `<Queue-Offer-ID>-N` -- a forwarded device's
  loopback carries the caller's `Queue-Call-ID` on its far side too -- one
  per call id, since every `ecallmgr` lists what it knows;
- **the record**: the `queue_call` document of the member's own passage,
  found by the call id, queue and join second the member carries
  (*Documents and views*). A caller who timed out of one queue into another
  has the second queue's record read, not the first queue's closed one. A
  document, or a month database, the datastore says is not there is no
  record; one it did not answer for is a record not read, which is not the
  same thing (below).

Everything that arrives meanwhile -- a key, a hang-up, a leg answering --
waits, and is heard once the call has been classified; a ring asked for
meanwhile is refused. The first of these that holds is where the caller
stands, and every leg of theirs it does not keep is hung up:

| Found | What happens |
|---|---|
| the probe unanswered, and every switch answering without the caller | gone: the member is settled as a hang-up -- or, when the record has an answer nothing closed, the call is told the dispatcher and closed as a call that ended |
| the record cancelled as the caller left on a branch, the probe reaching them, through to nobody, and no `Queue-Departed` of this passage | still on their way out: the last actor went before it handed them back, and the shard kept their member until it had. The departure is taken up again from its marks, and the caller handed back on the branch the departure's mark names, or the record's reason when the mark never ran |
| the record closed, by an end or a cancel | the queue is done with them, and only the settle was lost: `PresentOver`, and the member is settled -- by the actor too, for a dispatcher that joined the caller to it to finish a departure and takes no `Present` |
| `Queue-Departed` naming this passage | the callflow has them back: settled on the branch the departure's mark names |
| the caller bridged to a channel that is not one of their legs | a pickup or a transfer: settled as a transfer |
| the caller bridged to one of their legs | connected, dated by the last actor's marks when they name the leg's agent: not marked again, since the last actor marked them before it bridged them, and a command sent to a caller in a bridge runs inside it, if at all, holding the agent while it does; `PresentConnected`, and the end heard as any call's |
| `Queue-Departing` naming this passage | the departure is taken up again at its barrier, and the caller handed back on `Queue-Departing-Branch` |
| the record answered, and the caller through to nobody | the call ended while nothing watched it: `PresentConnected`, and its end told at once, as the agent's; a caller the probe reached is parked alone, and is hung up |
| one of their legs answered and parked | marked again at once, dated by the last actor's marks when they name the leg's agent, and bridged once the marks are seen to run: `PresentRinging`, and the answer told as any |
| legs of one offer ringing with at least three seconds of it left | the ring is taken on: `PresentRinging`, and its end told as any ring's |
| none of that | waiting: a hold queued behind whatever was playing, and `PresentWaiting` |

Bridged is two rows naming each other: the caller's `other_leg` is the
channel and the channel's is the caller. The caller's own row keeps the
other leg of a bridge that has ended, and a leg that is not bridged names
itself. A caller the probe did not reach and whom not every switch answered
about is asked about again, six times, and then taken to be waiting:
nothing is hung up on a guess. So is a caller the probe reached, whose own
switch did not answer, and whose record has an offer out or an answer. The
legs start on the caller's switch, so the listing can say nothing of their
ring or their conversation. A node that has just started asks nobody for
its first 15 to 40 seconds, until `kz_nodes` has heard of the `ecallmgr`s.
In the lab of 2026-09-28 (`e2e-260927-cca7`), a holder that took its own
shard back 16 seconds after a restart took a ringing caller to be waiting,
and rang their agent a second time. Each try waits out its eight seconds
before the next, so the six span 48 seconds.

**A record that could not be read** is not taken for one that is not
there. Taken so, a takeover during a datastore outage would settle a caller
whose answered call ended unwatched as a hang-up, losing its end and its
agent's counters, and offer again a caller whose passage is over and whose
member came round only because its settle was lost. So every row the
record decides waits on it: gone or ended unwatched, and, since the
record's close is asked before anything the switch says, every row for a
caller whose channel is up. A survey that did not come in within its try
did not read the record either. The caller is asked about again on the same six
tries, and a datastore that answers within them decides them as it would
have at once. One that does not is taken, on the last try, for no record:
the caller is where the probe and the switches alone put them, and only a
caller they cannot place either is taken to be waiting. Waiting would put a
caller in a conversation on hold, offer a caller who has gone and keep one
the callflow has back; the switches' word gets wrong only what the record
alone knows. Asking for longer would leave the caller unwatched for longer:
nobody rings for them, a departure half done keeps them in silence, and the
phones found ringing are nobody's.

**Parked, or passed on.** A caller whose record has an answer and who is
through to nobody had their conversation end while nothing watched it, and
the listing cannot say how. The bridge's `Park-After-Pickup` parks the
caller when the agent's leg goes, so a caller whose agent hung up in the
gap between the old holder's death and the new actor's survey is parked,
in silence, and nothing but their actor will ever hang them up. A caller
the agent passed on is running the transfer's callflow. The probe tells the
two apart. It goes to the control queue the callflow action handed over
with the caller, which `ecallmgr` addresses to the one control process that
took the caller into the queue (`pid://`, delivered to that process and no
other). That process stops when anything else takes the channel: a
transfer's `CHANNEL_TRANSFEREE`, or another callflow's `usurp_control`. So
a caller the probe reached is still the queue's, and, through to nobody,
is parked alone: they are hung up. A caller the probe did not reach is left
as they are. Either way the dispatcher hears the call's end as the agent's
(`agent_hangup`). What makes the hang-up safe is the control process, not
the probe's completion: a probe sent while the caller was still bridged is
held by the switch until the bridge ends, and can complete after a transfer
has parked them; but the hang-up goes through the same control process as
the probe, and a transfer has stopped it, so it only ever reaches a caller
the queue still commands.

The dispatcher takes a ring or a call its actor found as an offer of its own,
under the id the actor names, and hears its end from the actor as it hears
any offer's: the agents of a ring are held until its ceiling, and a
no-answer is theirs to miss, since their phones did ring; a supervisor's
pickup is held as the pickup it is. Nothing is written or published for
either as it is taken on: the node that rang them wrote and published them.

A call the sweep adopts (below) is taken by the caller's actor as it stands,
and the caller is sent nothing.
The end of the bridge is read as any connected call's end: the agent's leg
going hangs the caller up after `transfer_wait_ms` unless something said it
was a transfer, and the caller's own destroy is the end. The dispatcher hears
`Ended`, and everything after is its usual path: the record is closed, the
member settled, and `member_result` and `agent_wrapup` go out.

**A call that was already answered** and whose member was settled -- by a
node of the release before this one, which settled at the answer -- is
brought by no redelivery. What finds it is `callcenter/queue_calls_open` —
answered, no end, no cancel — read over the accounts concerned, and then the
switches asked about each caller. A caller on no switch, every switch having
said so, is closed: the record gets an end, the agent gets their wrap-up and
their counters, and `member_result` and `agent_wrapup` are published. A
caller still on a switch is adopted by an actor, so the end is caught when it
comes. An actor that cannot be had closes the call there and then, as a call
its record says was answered: a call nothing watches is one nothing will say
the end of, and its agent would be held busy until the backstop below. The
same goes for a call whose actor ends without saying the call did: its
monitor closes it at once, and the dispatcher's tick closes any connected
call it finds with nothing watching it. Either way the agent's own channels
keep them out of the next offer for as long as they really are talking.

**That scan runs when a shard is taken, not on every sweep.** An orphan appears
because a node died, and a node dying is a shard moving here: a shard this node
holds now and did not at the last sweep is the whole of the trigger, and the
accounts read are the accounts of those shards. Running it every
`reconcile_interval_s` instead would list the cluster's accounts and query a
month database for each of them, every thirty seconds, on every node, to find
what a live node closes for itself. Behind it is a backstop every twentieth
sweep — ten minutes at the default interval — over every shard held, for a
datastore that was down when the scan ran or a record this node lost track of
while it held the shard. The account listing is kept for five minutes; an
account created inside that window has no answered calls to lose.

What a scan costs is kept down three ways. Only accounts with queues are read:
one row of the account's queue listing (`queues/crossbar_listing`) says so,
and the answer is kept with the account listing and forgotten with it. The
switches are asked once per account, `query_account_channels`, and not once
per record: a record whose caller is in that answer is adopted, one missing
from an answer every switch gave is asked about on its own before it is
closed, and one missing from an answer the timeout ended is nothing -- the
same partial-answer rule as above. And a sweep that finds the last scan still
running starts none, and moves nothing on, so that the shards it took and a
backstop that was due are still there for the next one. All of it happens in
a process of its own: view queries and two seconds of switches per account
are not waits the sweep, a shard or a dispatcher can afford.

Closed once, by five things. Only the node holding the account's shard looks.
The calls it has asked about are remembered, because the write is a cast and
the next scan may come first: a scan says which passages the view named for
each account it read, and what the sweep remembers of that account and the
view no longer names is forgotten. A record whose hand-over failed -- no
dispatcher, or the read below found it closed or could not read it -- is
forgotten at once so that the next scan asks again, and one the view still
names ten minutes later (`retry_s`) is asked about again too. The document is
read again just before a record is closed, and one that has an end or a cancel
by then, or cannot be read, is left. The dispatcher's own close is idempotent
per passage: every close this node's dispatchers make is noted by passage in
a node-wide table (`callcenter/closed`, kept an hour), and an orphan handed to
a dispatcher that is in it is not adopted or closed -- its end is written
again with the result and second the first close had, and nothing is
published. That is what stops the backstop taking a call this node finished a
moment ago, whose end was still queued in the records writer or held there
for the datastore to come back, for an orphan: a second `member_result` and `agent_wrapup`, talk
time counted twice and a second wrap-up. And `records.closed` leaves a
document that already carries an end alone.

What still does not survive the node:

- **the misses counted against an agent.** `max_no_answer` counts since the
  agent logged in and the count is in the dispatcher, so a failover starts it
  again. The counter on the `callcenter_agent` document is untouched and the
  caller's record still says what each offer did.
- **the per-agent delays** after a reject, a busy or a no answer, and the
  second a wrap-up ends. An agent who had just missed a caller can be offered
  the next one at once.
- **an answered call's end time.** The end written is the second the scan
  found the channel gone, not the second it went, so a call that ended while
  the shard was moving is recorded as a little longer than it was. The CDR
  would say; reading one means knowing what it is keyed by in the queue call's
  month database.
- **what only the record knows, through a longer datastore outage.** A
  caller handed over whose record no try read in 48 seconds is taken as the
  switches find them (above). An answered call that ended unwatched in
  that time is settled as a hang-up, its end and its agent's counters lost,
  and a passage that was over, whose settle was lost, is taken up again.
- **a call answered in a month the scan no longer reads.** It looks at the
  current month only, so a call answered at ten to midnight on the last day of
  one, whose holder died after it, is not found.
- **commanding a call the sweep adopted.** The `kapps_call` the callflow
  published went with the node that died, so a call rebuilt from its record
  can be watched and written about but not hung up. For those,
  `hangup_after_bridge` is the switch's own bridge teardown.

## Documents and views

| Document | Database |
|---|---|
| `queue` | account |
| `callcenter_agent-<user_id>` | account |
| `queue_call`, one per caller's passage through a queue, `<call_id>-<queue_id>-<joined>` | MODB, the month the passage joined |
| `agent_status_change`, one per availability change | MODB |

A passage is one caller in one queue from the second they joined: the id is
the call id, the queue id and `joined` in Gregorian seconds, all three on the
member message, so a redelivery, a takeover and the sweep's rebuilt caller
address the document the first node wrote. A caller who times out into an
overflow queue, or joins the same queue again, has a second document with its
own queue, offers, answer and end. Per-queue reports count each passage under
its own queue, and the open-call view finds the answered second passage of a
caller whose first was cancelled.

Every offer is an `offered_to` entry, and every entry gets an outcome:
- `answered`;
- `no_answer`, `busy` or `reject`;
- `cancelled`, a ring called off, by the caller leaving, by somebody else
  answering a ring-all, or by the passage ending around it;
- `failed`, an offer that never rang or broke, with its `reason`:
  `no_endpoints`, `offer_crashed`, `offer_down` for a pickup, or the
  switch's cause.

The end or cancel of a passage marks any entry still without one
`cancelled`, which covers a ring whose last word died with its node. A
closed record has no offer open.

Earlier releases keyed the document by the call id alone, and a re-entry
reused it. Such a document is still read and written for the passage it
belongs to: the one whose `queue_id` and `joined` it carries. That lookup
runs only when the passage has no document of its own, so it costs a caller
nothing once their own document exists, and a first delivery never makes it.
The takeover read, every write after `joined` and the sweep's close all
follow the rule. A caller waiting or talking across the upgrade keeps the
document their passage began in, and the open-call view, which keys on fields
and not ids, finds either kind. Once no call-id document can still be open
the lookup finds nothing and can be removed. The sweep reads the current
month only, so that is a month after the upgrade.

A caller already waiting who arrives again as a different passage (the
callflow run again, or a second queue whose member overtook the first's
cancel) gets the new passage's document. The one it replaces is closed as a
`transfer`, unless an offer made for it is still in flight: that offer's
outcome is written to it as usual, and when the offer ends the passage left
over is closed as a `transfer`. That is the old one if nobody answered. If
an agent did, the answer is the old passage's, the one the agent was rung
for, and the new one is closed.

Views, registered at start the way skel registers its own: `callcenter/agents`
and `callcenter/queues_by_agent` in the account database,
`callcenter/queue_calls_by_queue`, `callcenter/queue_calls_by_agent`,
`callcenter/queue_calls_open` and `callcenter/status_changes_by_agent` in the
month databases.

Every document write goes through one writer actor per node, so the
dispatchers never wait on a datastore and two changes to one document cannot
interleave.

A write the datastore did not take is held and tried again
(`callcenter/records/backlog`), rather than dropped. Before, an agent's
counter increment made during a database outage was lost for good. The
writer's rules:

- **Order.** A document's writes are made in the order they were asked
  for. While one is held, every later write to that document waits behind
  it.
- **Once.** Every write carries an id, and every document the writer
  writes carries the ids of the last eight writes that made it, in
  `pvt_callcenter_writes`. A write tried again first reads its document,
  and one whose id is already there is done. That is how a write whose
  answer was lost, but which landed, is not counted twice.
- **Pacing.** The first write the datastore does not take puts the writer
  into holding: later writes are held without being tried, so a datastore
  that answers only after its connect timeout does not put the writer
  minutes behind its mailbox. The writes held are tried again after 1 s,
  then 2, 4 and 8, and every 10 s after that. A round tries the documents
  in turn, each document's oldest write first, and ends at the first write
  not taken. That document goes to the back of the next round, so one
  unreachable database never keeps the others back.
- **Races.** A write that loses a race is read and made again at once, up
  to three times. The race is with another node's change to the document
  between the writer's read and its write; `callcenter/availability`
  writes the `callcenter_agent` document too.
- **What counts as final.** An outage is anything the datastore did not
  answer usefully, which includes `connect_timeout`, `econnrefused` and
  `tcp_closed`. A missing database or a 4xx answer is final, and the write
  is given up and logged.
- **Limits.** At most 20,000 writes are held, and none for longer than an
  hour. Past either, the oldest is given up and logged. A node that stops
  loses what it holds, and says how many writes it held.

The log lines are `the datastore did not take a write (<reason>); holding
writes and trying again`, `the datastore is back: N held write(s) done`
and `could not write <type> <id>, given up: <reason>`.

The queue document is read on every dispatch pass, through the data layer's
document cache: an edit empties the cache through its `doc_edited` and is in
force on the next pass, and no pass reads the database. Every
`queue_refresh_s` (`system_config/callcenter`, ten seconds) the dispatcher
reads the queue from the database instead and drops the cached copy, because
a change notice is a broker message and a broker restart can lose one -- the
node that took the edit publishes before its channel is back -- after which
the cache would serve the old queue for its full fifteen minutes. A refresh
that finds the database unreachable leaves the cached copy in force. That is
what dispatch through a database outage is: best effort, on what the cache
still holds. A document the database says is not there, or one marked
`pvt_deleted`, is a deleted queue, and its callers leave it (*The caller*,
below).

## Enabling it

```console
$ sup kapps_config set_default callcenter shards 64
```

then `callcenter` in `KAZOO_APPS` -- or nothing, since it is in the default
application list. There is nothing else to set up: every node declares the
member queues as it starts, joins the members, and takes up the shards
assigned to it. A node that cannot reach the broker keeps asking and holds
nothing until it can, which is when it can dispatch anyway. The log line for
a take is `shard N taken on <node> with M caller(s) waiting`, for a handover
on the giving node `shard N handed over to <node>`, and for a change in
the members `members: <node>, <node> (were <node>)`.

A broker that lost its queues while the nodes stayed up is repaired by the
same means: the broker cancels the holders' consumers with the queues, their
listeners end, and the placement's next tick redeclares the queues and
takes them again. What was on them is gone, and the callers whose messages those
were leave their queues on their own clocks.

## sup

| Command | What it does |
|---|---|
| `sup callcenter_maintenance status` | which shards this node holds, the members it sees and how many shards they assign it, the dispatchers, the callers waiting in each queue and the agents |
| `sup callcenter_maintenance agents <account_id>` | every agent of an account with their availability and this node's derived activity |
| `sup callcenter_maintenance set_agent <account_id> <agent_id> <availability>` | set an agent's availability as a supervisor would |
| `sup callcenter_maintenance queue_status <account_id> <queue_id>` | ask the cluster what is happening in an account; an empty queue id is every queue |
| `sup callcenter_maintenance release_agent <account_id> <agent_id>` | take an agent out of the offer, wrap-up or delay this node believes about them. A ring still going is called off by the caller's actor, which hangs its legs up, and the offer is held until the actor says the ring is over, which frees everybody it rang with no miss and no delay, and the caller is offered again; an agent who answered before the call-off reached the actor has the caller. A ring is called off once however often it is asked for. An offer whose actor is gone is dropped at once, and an answered call is ended here |
| `sup callcenter_maintenance release_member <account_id> <call_id>` | take a caller out of the queue as their cancel would: the account's shard settles their member and tells the dispatcher they left, which drops them, frees the agents being rung for them with no miss, and closes their record as `hangup`. Run it on the node holding the account's shard (`status`) |
| `sup callcenter_maintenance rebalance` | make the placement look at every shard now, and say how many are assigned and held here |
| `sup callcenter_maintenance reconcile` | run the sweep now rather than on the timer |
| `sup callcenter_maintenance ack_member <account_id> <call_id>` | `release_member` under its older name. It used to settle the member and tell nobody, and the dispatcher went on offering the caller with nothing on the broker behind them |
| `sup callcenter_maintenance publish_member <account_id> <queue_id> <call_id>` | publish a test member into the account's shard |
| `sup callcenter_maintenance cancel_member <account_id> <call_id>` | publish the cancel that settles it again |

`status` answers for the node it runs on. `rabbitmqctl list_consumers` is the
cluster-wide view of who holds what.

## Modules

| Module | What it is |
|---|---|
| `callcenter` | the supervision tree, and the one line that names how an agent is rung |
| `callcenter/types` | the types the dispatcher, the call path and the agent control agree on |
| `callcenter/call/*` | the call path: each waiting caller's actor, the pure core it runs, the registry, the reply listener, the publishers every actor publishes through, and finding out about a caller handed over (*Call path*, *Takeover*) |
| `callcenter/dispatcher` | one account's waiting lists, offers, timers and events |
| `callcenter/dispatcher/arrival` | a caller reaching the dispatcher, including a redelivery or an answered call a node that died left behind |
| `callcenter/dispatcher/offers` | an offer from sent to settled: the replies, the misses, the end, and a caller leaving |
| `callcenter/dispatcher/pass` | one pass over the account: who is offered, to whom |
| `callcenter/dispatcher/pickup` | a supervisor's pickup: a waiting caller rung through to the supervisor's phones as an offer, and what its replies mean |
| `callcenter/dispatcher/waiting` | the account's one order of waiting callers |
| `callcenter/dispatcher/view` | an agent as a strategy sees them, and the queue's tier state |
| `callcenter/dispatcher/memo` | what a queue's strategy is shown and keeps between callers |
| `callcenter/dispatcher/worked` | when each agent last became free, and the calls counted here before their document shows them |
| `callcenter/dispatcher/timers` | the delays, the wrap-ups, the offer ceilings and the tick |
| `callcenter/dispatcher/position` | `member_position` and `queue_stats` |
| `callcenter/dispatcher/publish` | the payloads of every event a dispatcher publishes |
| `callcenter/dispatcher/status` | the `status_resp` a dispatcher answers with, and the `sup` snapshot |
| `callcenter/dispatcher/settings` | what a dispatcher reads out of a queue document and a user |
| `callcenter/dispatcher/config`, `callcenter/dispatcher/state` | what a dispatcher is started with, and what it holds between messages |
| `callcenter/strategy` | the interface a strategy answers, the exclusions they share, and the registry |
| `callcenter/strategies/*` | one module per strategy |
| `callcenter/tiers` | the queue's tier rules: which levels a caller of a given age may be offered to |
| `callcenter/activity` | what every agent's phones are doing, derived from the channel events |
| `callcenter/availability` | the `callcenter_agent` document, and the only thing that writes it |
| `callcenter/breaks` | a break with an end: when it is over, what it goes back to, the timer of the node that started it and the sweep's end |
| `callcenter/records` | the `queue_call` and `agent_status_change` documents and the per-login counters |
| `callcenter/records/backlog` | the writes the record writer holds while the datastore is away: per-document order, write ids, limits |
| `callcenter/recording` | a queue call's recording: its name and the settings `media_mgr` stores it by |
| `callcenter/reconcile` | the sweep behind the events |
| `callcenter/closed` | the passages this node's dispatchers closed lately, so that the sweep never closes one twice |
| `callcenter/status` | the answer to a live `status_req`, from the node that is dispatching |
| `callcenter/pickup` | a supervisor's pickup on the bus: Crossbar's `pickup_req`, and the holder handing it to the dispatcher and answering |
| `callcenter/app` | the OTP application callbacks, and the start-up work (database, queue declaration) |
| `callcenter/system` | the one name — application, `system_config` category, database — and the log |
| `callcenter/shards` | the shard of an account and the node's count, the assignment of shards to members, the queue names, how a member queue is declared, the declaration that reports what is on a queue, and whether the node's count is the cluster's |
| `callcenter/members` | which nodes take shards: each node's own queue, whose consumer is its membership and which carries the wants |
| `callcenter/placement` | one process per node: takes the shards assigned to it, asks for the ones somebody else holds, and hands over the ones another member asks for |
| `callcenter/shard` | one shard while this node holds it: its supervisor, the actor that settles its members, the member listener, the dispatchers and the callers' actors |
| `callcenter/stall` | the node's stall watch: a note of the time every second, and whether a process of a shard started before the node last stood still may still act for it |
| `callcenter/ask` | a call that hands the callee's exit or silence back as a value |
| `callcenter/member` | what is on a member queue: `member_call` and `member_cancel` |
| `callcenter/tombstones` | the cancels a shard received for callers it was not holding, for the `member_call` behind them |
| `callcenter/db` | the application's own system database |
| `callcenter/fields` | one field off a document or an event, an empty string read as none |
| `callcenter/agent_state` | availability and activity, asked in one place, and the wire spelling of each |
| `callcenter/agents` | the account's agents as documents: the directory, the `*23` lookup, the tiers, and whether a user can be offered a caller at all |
| `callcenter/feature_codes` | what `*22`, `*23` and `*24` decide, and what the agent hears |
| `callcenter/presence` | the agent login lamp: its state, its address, and what the dispatcher last showed |
| `callcenter/lamp_probe` | answering Kamailio's dialog probe for a login lamp nobody was watching |
| `callcenter/dnd` | do not disturb, which forces an agent logged out and puts them back; and a user disabled (logged out) or deleted (out of every queue, logged out, agent document gone) |
| `callcenter/status_query` | asking the node that holds the shard what is happening now |
| `callcenter/supervisor_actions` | eavesdrop and pickup in Crossbar: the checks, the originate, the question to the dispatcher and its answer |
| `callcenter/permission` | who may run the call center through the API: an account or superduper administrator |
| `callcenter/api` | the nouns Crossbar serves for this application, and the views it registers |
| `cf_callcenter` | the queue's callflow action: puts the caller in the queue and waits to be handed back (*Call path*) |
| `cf_callcenter_departed` | the callflow action a caller resumed elsewhere goes through: marks them handed back |
| `cf_callcenter_agent` | the callflow action behind the agent feature codes |
| `cb_queues` | `/v2/accounts/{id}/queues` |
| `cb_agents` | `/v2/accounts/{id}/agents`, and a queue's tiers |
| `callcenter_maintenance` | the `sup` commands |
| `callcenter_ffi.erl` | the shard hash, the queue declaration with its counts, the shard count's marker queue, the node's own values, where a callflow action can be reached, the exit signal a listener acts on, the stops a supervised process ends with, a call actor's reach: its events, its address, its raw commands and a callflow's branches, and a call publisher's: its channel, a `kapi` publish from its own process and a run that cannot crash it |
| `callcenter_closed_ffi.erl` | the node-wide table behind `callcenter/closed` |
| `callcenter_api_ffi.erl` | registering the application's own CouchDB views, now and on every refresh |
| `kapi_callcenter.erl` | the application's AMQP event family: the contract with every other application on the bus |

## Testing

No local Gleam or Erlang; both run through the builder image, from the
repository root so the container sees the path dependency to
`core/kazoo_gleam` as well:

```console
$ docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src \
    -w /src/applications/callcenter offhook-builder:erl28-gleam gleam test
$ make gleam-check
```

`make -C applications/callcenter compile` builds the shipment and installs
this application's `ebin` and its dependencies into `deps/`, which is what
`make apps` and the release do.

### Building the release to run it

`make eunit` and `make build-release` cannot share a tree: the test build
writes `-DTEST` beams into the `ebin` the release ships, and a `TEST`
`kapps_config` never persists anything, which breaks configuration and auth
tokens on the node in ways that look like anything but a stale beam. Run
`make clean-core clean-apps` before `make JOBS=1 prerequisites deps core apps
build-release` in any tree the tests have run in.

### On a running node

A node, a broker and a datastore in three containers, as in the provisioner's
own local check. There is no media server, so no call is placed; what that
proves is every decision and every message the call centre makes, which is
the half that is not the switch's. The switch's half is the lab's
(`callcenterfunctional` in offhook-infra, and the call-actor spike's runbook
there, `doc/engineering/spike/callcenter-call-actor.md`).

Five things the recipe needs that the provisioner's does not say:

- `rabbitmq:3` wants `rabbitmq-plugins enable
  rabbitmq_consistent_hash_exchange`, and on some Docker Desktop versions
  `chown rabbitmq:rabbitmq /var/lib/rabbitmq && chmod 700 /var/lib/rabbitmq`
  before it will boot at all.
- `sup kapps_maintenance init_system` comes before `crossbar_maintenance
  create_account`.
- The raw release runner does not honour `KAZOO_APPS`. Start what you need
  with `sup kapps_controller start_app callcenter`.
- `vm.args` pins distribution to `127.0.0.1`, so a second node is a second
  container -- its own network namespace, its own `127.0.0.1` -- with
  `KAZOO_NODE=kazoo_apps_b@127.0.0.1` and the same broker and datastore. The
  two never speak Erlang to each other; everything between them is the bus,
  which is the point.
- `system_config/ecallmgr`
  `default.node_call_command_allowed_applications.callcenter.hangup` has to
  be `true` for the caller's actor to hang a leg up.

The action resolves the way `cf_exe` asks:

```console
$ sup -n kazoo_apps kazoo@callflow is_action callcenter
true
```

### Without a media server

There is no FreeSWITCH on a development cluster, so nothing there can ring a
real phone. `stub_offer` answers every offer with a process that rings
nobody: ringing at once, answered after `stub_offer_answer_ms`, ended after
`stub_offer_talk_ms`. It stands in for the caller's actor's ring and nothing
else: the dispatcher, the strategy, the counters, the documents and the
events run unchanged, which is enough to watch a caller be picked up,
connected and wrapped up end to end. The caller's actor never hears of the
stub's answer, so a caller there waits on until their clocks take them out.

```console
$ sup kapps_config set_default callcenter stub_offer true
$ sup kapps_config flush callcenter
```

then restart the application, because the offer function is read once when a
shard is taken.
