# kazoo_gleam

Kazoo bindings for the Gleam applications in the reprise release: the calls
that leave Gleam for the VM or for Kazoo's own APIs, and the typed values they
carry.

It is a source-only Gleam package. It has no `Makefile` and is not a release
application in its own right: each application that depends on it ships a copy
in its own `gleam export erlang-shipment`, which the application's `Makefile`
installs into `deps/kazoo_gleam`, and the application's generated `.app` lists
`kazoo_gleam` under `applications`, so relx pulls it in.

## Modules

| Module | What it is |
|---|---|
| `kazoo/kazoo` | the `Kazoo` record — every call that leaves Gleam, as a record of functions, built by `kazoo.live(app)` — plus `Error`, the view options, `account_db` and `is_id` |
| `kazoo/doc` | document values: what a document, a settings layer and a request body all are, with merge, patch, dotted-path flatten and JSON |
| `kazoo/ffi` | the external declarations for `kazoo_gleam_ffi` |
| `kazoo/app` | `mark_kazoo_app` and `start_tree`: what the release has to be told that a Gleam `.app` and a Gleam supervisor cannot say |
| `kazoo/accounts`, `.../users`, `.../devices` | typed views of those documents: the reseller tree, the realm, presence ids, `provision.*`, the MAC |
| `kazoo/switch` | the check-sync NOTIFY, the message `provisioner_util:send_check_sync/5` publishes |
| `kazoo/alerts` | a Kazoo alert to the account's and the reseller's admins |
| `kazoo/cache` | node-local ETS caches: plain, with a time to live, and a throttle |
| `kazoo/listener` | one AMQP listener, described in Gleam: bindings, a queue, consume options, a prefetch, and closures for a delivery, for the lifecycle and node notifications, and for the consumer coming and going |
| `kazoo/amqp` | publishing through a `kapi` module by name, and the two ways of waiting: one answer, or every node's; a confirmed publish, and the node's confirming publisher it goes out on |
| `kazoo/events` | call events without a listener of your own -- an `Interest` in event names, call ids, channel variables and a gate of accounts, decided before the event is converted -- the accessors over one, and what the switches say they are carrying |
| `kazoo/nodes` | the cluster: who is up, who is running what, who has which role |
| `kazoo/util` | a content digest, a constant-time comparison, an instant back to unix seconds, a registered name from a literal |
| `kazoo/testing/fake` | a `Kazoo` record over an in-memory store, with document revisions, conflicts and CouchDB's key ordering. Test support, in `src` because Gleam has no test-only exports |
| `kazoo/testing/channel` | the other half of that: the commands an action sent and the endings it reached, in order, and scripted answers for what it asked the caller. Test support, in `src` for the same reason |
| `kazoo_gleam_ffi.erl` | `kz_datamgr`, `kapps_config`, `kz_auth`, `kapps_alert`, `kapi_switch`, and the VM |
| `kazoo_gleam_listener.erl` | the one `gen_listener`, parameterised from Gleam |
| `kazoo_gleam_amqp_ffi.erl` | `kz_amqp_worker` and the `kapi` module called by name |
| `kazoo_gleam_confirming_publisher.erl` | one channel in confirm mode for the node's confirmed publishes, answers matched by delivery tag and `Msg-ID` |
| `kazoo_gleam_events_ffi.erl` | `kz_events` call-event handlers, the filter in front of them, and the guard that unbinds them when their subscriber goes |
| `kazoo_gleam_nodes_ffi.erl` | `kz_nodes` |
| `kazoo_gleam_cache_ffi.erl` | the ETS tables behind `kazoo/cache` |
| `kazoo_gleam_util_ffi.erl` | the Erlang behind `kazoo/util` |
| `kazoo/call` | the channel: what is known about a call, the commands sent to it, and the events that come back |
| `kazoo/endpoints` | what a bridge can be pointed at: `kz_endpoint:build` for a user or a device |
| `kazoo/callflow` | writing a callflow action: the action's data, and the endings `cf_exe` waits for |
| `kazoo/crossbar` | writing a Crossbar module: the request context, the schema validator, the document helpers, and the binding that makes a Gleam module reachable |
| `kazoo/modb` | the account's month databases, and the Gregorian seconds they are addressed in |
| `kazoo_gleam_call_ffi.erl` | `kapps_call`, `kapps_call_command` and `kz_media_util` |
| `kazoo_gleam_endpoint_ffi.erl` | `kz_endpoint`, `kz_endpoints` and `kz_attributes` |
| `kazoo_gleam_callflow_ffi.erl` | `cf_exe` |
| `kazoo_gleam_crossbar_ffi.erl` | `cb_context`, `crossbar_doc`, `crossbar_view` and `crossbar_maintenance` |
| `kazoo_gleam_cb.erl` | the module Crossbar binds on a Gleam module's behalf, so that one Gleam function answers every path length |
| `kazoo_gleam_modb_ffi.erl` | `kazoo_modb` |

## Consuming it

```toml
[dependencies]
kazoo_gleam = { path = "../../core/kazoo_gleam" }
```

Then, once, while the application starts:

```gleam
import gleam/option.{Some}
import kazoo/app
import kazoo/kazoo

pub const category = "my_app"

app.mark_kazoo_app(category, Some(category))
let kz = kazoo.live(category)
app.start_tree(fn() { my_app.start(kz) })
```

One string parameterises the whole library: the application's name. It is the
OTP application the version and the `priv` directory are read from, the
`system_config` category, the alert category, and the application name on the
AMQP messages published. Pass its own database to `mark_kazoo_app` so the data
layer classifies it as a system database instead of warning with a stack trace
on every read. Return what `start_tree` returns from the application's
`start`: it puts the tree under a root that records when it started, which is
where `kz_nodes` reads an application's run time from (an Erlang top
supervisor writes it in its own `init`; a Gleam one cannot), so `kz_nodes
status` shows the application with a run time and `whapp_oldest_node` can
rank it.

Everything below that takes the `Kazoo` record as an argument, so a test runs
the whole application over an in-memory store:

```gleam
import kazoo/testing/fake

let f = fake.new()
let kz = fake.kazoo(f)
```

`fake.new_with_views` adds the application's own design-document views; the
views of Kazoo's own databases are built in.

`kazoo/testing/channel` is the caller the same test talks to. Without a
release every channel command is a no-op, which is what lets an action run
at all; `channel.record()` makes those no-ops observable, so a test can run
the whole action and then read what it sent:

```gleam
import kazoo/testing/channel

channel.record()
channel.collect_answers([channel.Typed("1001"), channel.CallerHungUp])
channel.play_results([channel.Heard])
cf_something.run(kz, data, call)

assert channel.sent() == [channel.Command("answer", ""), ...]
```

`collect_answers` scripts what the caller types, `play_results` what becomes
of the prompts the action waits on -- heard, cut short by a hangup, never
played -- and both run out into the nothing a channelless command answers
anyway.

`channel.waits_for_the_channel` says whether a command is one the action
waited for the end of, and `channel.is_an_ending` whether it is a callflow
ending -- which together are how a test asserts that the last thing an
action said was heard before the flow ended.

It is all per-process, and nothing records until a test asks. `record` is
also the whole reset -- it forgets what was recorded and any answer still
scripted -- so call it first in every test that reads the channel.

Two rules the bindings keep, and a consumer has to keep too:

- `kz_json` objects never enter Gleam. Erlang applies `kz_json:to_map/1` on the
  way out and `kz_json:from_map/1` over `json:decode/1` on the way in; Gleam
  sees `Dynamic` and decodes it with the total decoder in `kazoo/doc`, which
  answers `Null` rather than failing on a document it does not recognise.
- Every FFI call guards with `code:ensure_loaded/1` and degrades to a sensible
  value, so an application starts, and its tests run, with no Kazoo release
  around them.

## Timestamps

Every timestamp Kazoo stores is in **Gregorian seconds**: seconds since the
year 0, which is what `kz_time:now_s/0` answers, 62,167,219,200 more than the
unix second for the same instant. `modb.now`, `modb.from_unix` and
`modb.to_unix` are the conversions. `kazoo.now_s` is the other kind — unix
seconds, for the `iso8601` an API renders — so an instant that goes into the
data layer goes through `modb`, and an instant that goes out to a client goes
through `kazoo`.

## Writing a callflow action

A callflow is a tree of actions. `cf_exe` walks it: for each node it looks up
the module named by prefixing the node's `module` with `cf_`, checks that it
exports `handle/2`, and spawns `Module:handle(Data, Call)` in a process that
receives the call's events.

A Gleam module at the top of `src` compiles to an Erlang module of exactly
its own name, so an action lives in `src/cf_<action>.gleam` and nowhere else:
a module at `src/my_app/queue.gleam` compiles to `my_app@queue`, which no
callflow can name.

Two rules the action has to keep:

- `Data` arrives as a `kz_json` object, the one place a Gleam action meets
  one. `callflow.data` is the conversion, and it is the first thing to do
  with it.
- Every path through `handle` has to reach exactly one of `continue`,
  `continue_branch`, `continue_with_flow`, `branch`, `stop`,
  `stop_with_cause`, `transfer` or `control_usurped`. An action that simply
  returns leaves `cf_exe` with a dead flow and the caller is hung up.
- Whatever the action says last, it has to wait for. A command is queued on
  the channel and run by the switch, not by this process, so `call.prompt`
  and `call.play` return long before the caller has heard anything; and an
  ending hangs the channel up. `prompt` immediately followed by `stop` is a
  prompt the caller never hears. Use `call.prompt_and_wait`, which returns
  when the switch says the media has finished. `answer` needs no such wait:
  the switch runs a channel's commands in the order they were queued, so a
  prompt queued behind an answer plays after it.
- An action that already knows the channel is gone must send nothing more to
  it, and end. `cf_exe` relays the channel's destruction to the action once
  and stays up itself, so whichever wait consumed that event is the last one
  that can end early; a wait started afterwards runs to its timeout with the
  flow, the action and their bindings still open. `prompt_and_wait` bounds
  that at a minute rather than `kapps_call_command`'s `max_wait_ms`, a day,
  but the wait is still a wait for nothing.

```gleam
//// The callflow action `gleam_spike`: continue on the branch its data
//// names, or stop.

import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import kazoo/call.{type Call}
import kazoo/callflow
import kazoo/doc.{type Value}

pub type Decision {
  Branch(String)
  Stop
}

pub fn handle(data: Dynamic, call: Call) -> Nil {
  case decide(callflow.data(data)) {
    Branch(key) -> callflow.continue_branch(call, key)
    Stop -> callflow.stop(call)
  }
}

/// The decision on its own, so it can be tested without a flow to end into.
pub fn decide(data: Value) -> Decision {
  case callflow.data_string(data, "branch") {
    Some(branch) -> Branch(branch)
    None -> Stop
  }
}
```

`callflow.is_action("gleam_spike")` on a running node answers the same
question `cf_exe` asks before it spawns anything, which is how to check that
an action is reachable.

A termination handler is applied by name, so it must name something Erlang
can call. A Gleam module qualifies: its compiled name is its path with `/`
replaced by `@`, and a `pub fn` is exported under its own name. `cf_exe`
calls it as `module:function(call, hangup_event, args...)`, so with no extra
arguments the function takes two, and the second is a `kz_json` object to
pass through `callflow.data`.

## Writing a Crossbar module

Crossbar is the HTTP API. A module claims a noun — the path segment `queues`
in `/v2/accounts/{id}/queues/{qid}` — and binds one function to each phase of
a request against it. The module is named `cb_<noun>`, lives at the top of
`src` for the same reason a callflow action does, and is started with
`crossbar.start_module`, which also adds it to the modules the node
autoloads.

Crossbar has **one binding per noun and phase**, not one per path length, and
applies the bound function to the whole payload: `validate` is called with
the context alone for `/queues` and with the context and two tokens for
`/queues/{id}/agents`. An Erlang Crossbar module therefore exports
`validate/1`, `validate/2` and `validate/3`. Gleam gives a function one
arity, so a Gleam module cannot.

`crossbar.bind` closes the gap, and the shape it imposes is the only thing a
module has to know about it: **a handler takes the path tokens as a list**,
and checks the list it was given. Underneath, `kazoo_gleam_cb` is the Erlang
module Crossbar binds; it exports each fold-phase name at every arity
Crossbar can call, finds the noun in the context, and dispatches into the
Gleam handler. The phases that go through `kazoo_bindings:map/2` —
`allowed_methods`, `resource_exists`, `authenticate`, `authorize` — accept a
closure as the bound responder, so those are bound directly.

One consequence to know about: the fold-phase bindings belong to
`kazoo_gleam_cb`, not to the `cb_` module, so `crossbar_bindings:flush_mod/1`
on a Gleam module drops only its map-phase bindings.

```gleam
//// The Crossbar module `cb_gleam_spikes`, serving
//// `/v2/accounts/{id}/gleam_spikes`.

import gleam/list
import gleam/option.{None, Some}
import kazoo/crossbar.{type Context}
import kazoo/doc

pub fn init() -> Nil {
  crossbar.bind("gleam_spikes", [
    crossbar.AllowedMethods(allowed_methods),
    crossbar.ResourceExists(resource_exists),
    crossbar.Validate(validate),
    crossbar.Put(put),
  ])
}

fn allowed_methods(tokens: List(String)) -> List(String) {
  case tokens {
    [] -> ["GET", "PUT"]
    [_id] -> ["GET"]
    _ -> []
  }
}

fn resource_exists(tokens: List(String)) -> Bool {
  list.length(tokens) < 2
}

fn validate(context: Context, tokens: List(String)) -> Context {
  case crossbar.req_verb(context), tokens {
    "GET", [] -> crossbar.respond(context, listing(context))
    "GET", [id] -> crossbar.respond(context, spike(context, id))
    "PUT", [] ->
      crossbar.validate_request_data("queues", context, fn(context) {
        crossbar.set_resp_status_success(context)
      })
    _, _ -> crossbar.add_system_error(context, "invalid_method")
  }
}

fn put(context: Context, _tokens: List(String)) -> Context {
  crossbar.respond(
    context,
    doc.object([
      #("validated", crossbar.doc(context)),
      #("account_id", account(context)),
    ]),
  )
}

fn listing(context: Context) -> doc.Value {
  doc.List([spike(context, "one"), spike(context, "two")])
}

fn spike(context: Context, id: String) -> doc.Value {
  doc.object([
    #("id", doc.String(id)),
    #("written_in", doc.String("gleam")),
    #("account_id", account(context)),
    #("verb", doc.String(crossbar.req_verb(context))),
  ])
}

fn account(context: Context) -> doc.Value {
  case crossbar.account_id(context) {
    Some(id) -> doc.String(id)
    None -> doc.Null
  }
}
```

`validate_request_data` takes the id of a schema in `system_schemas`, applies
the schema's defaults to the request body and leaves it on the context as the
document; a body that fails leaves the standard validation error response and
the success function does not run. The application starts its modules while
it starts itself:

```gleam
crossbar.start_module("cb_gleam_spikes")
```

`Authenticate` answers whether a request needs no token (`True` for a
public route; `False` leaves the ordinary token check in place).
`Authorize` answers whether the caller may proceed, and its `False` is a
403 even when Crossbar's own authorization already allowed the account
admin, which is what lets a module reserve a route for superduper admins
or gate it on a setting.

A path that answers something other than the JSON envelope -- a
certificate, a file -- binds a `ContentTypesProvided` handler as well. It
runs before `Validate` and names the types the path can answer with
`provide_content_types`; the verb then answers the raw body in one of them
with `respond_body`, and Crossbar negotiates with the client's `Accept`:

```gleam
crossbar.ContentTypesProvided(fn(context, tokens) {
  case tokens {
    ["certs", _kid] ->
      crossbar.provide_content_types(context, [
        "application/pem-certificate-chain",
      ])
    _ -> context
  }
})
```

## Listeners

`gen_listener` is a behaviour, and a behaviour is Erlang only, so every Kazoo
application that consumes AMQP has had to write one. There is one here, and
`kazoo/listener` is how an application describes it:

```gleam
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import kazoo/doc
import kazoo/listener.{Infinity}
import kazoo/util

/// The actor the closures hand the work to.
pub type Message {
  Member(call_id: String, done: process.Subject(Nil))
}

const worker = "callcenter_member_worker"

pub fn supervised(account_id: String) -> supervision.ChildSpecification(Nil) {
  listener.new()
  |> listener.named(util.name("callcenter_member_listener"))
  |> listener.binding("callcenter", [
    listener.restrict_to(["member_call"]),
    listener.federate(),
  ])
  |> listener.queue(
    name: "callcenter.member." <> account_id,
    durable: True,
    exclusive: False,
    auto_delete: False,
    ttl: Infinity,
    max_length: Infinity,
  )
  |> listener.consume(manual_ack: True, exclusive: False)
  |> listener.prefetch(1)
  |> listener.on_event(fn(event, delivery) {
    let call_id = doc.get_string(event, ["Call-ID"]) |> result.unwrap("")
    // The work happens in the worker, not here; the ack waits for it, so the
    // broker hands this node nothing else until it is done.
    let Nil =
      actor.call(process.named_subject(util.name(worker)), 30_000, Member(
        call_id,
        _,
      ))
    listener.ack(delivery)
  })
  |> listener.on_info(fn(info) {
    case info {
      // A node that was holding calls is gone: take its work back.
      listener.NodeExpire(node) -> reclaim(node.name)
      _ -> Nil
    }
  })
  |> listener.notify_nodes(of: [listener.NodeGone])
  |> listener.supervised
  |> supervision.map_data(fn(_server) { Nil })
}
```

`start` gives the same listener back as a `Server`, for `queue_name`,
`add_binding`, `rm_binding`, `notify` and `stop`.

Two rules hold, and neither is checked for you:

- **A closure is quick.** All three run in the listener process, so one that
  blocks stops this consumer -- which, with a prefetch, is the point -- and one
  that crashes takes the listener down, which is what should happen to a
  delivery that was never acked, but not what should happen because a closure
  went to a database. Hand the work to a named actor with a typed call and
  return. `kazoo/events` handlers run in a process `kazoo_bindings` spawned and
  keep the same rule.
- **`kapi` modules stay Erlang.** A binding name resolves to `kapi_<name>` and
  `amqp.publish("call", "channel_status_req", …)` resolves to
  `kapi_call:publish_channel_status_req/1`, so an application keeps a short,
  declarative Erlang module for its own event family. That module is the
  contract with every other application on the bus, and this library does not
  replace it.

## Building and testing

With Erlang/OTP 28 and Gleam installed, run `gleam test` and
`gleam format --check src test` in this directory. Without them, use
a builder image with Erlang/OTP 28 and Gleam 1.18.1 (the `builder` stage of `docker/reprise/Dockerfile` installs that toolchain; `$BUILDER` below is the tag of such an image), from the repository root so the container sees the path
dependency as well:

```console
$ docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src \
    -w /src/core/kazoo_gleam "$BUILDER" gleam test
$ docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src \
    -w /src/core/kazoo_gleam "$BUILDER" gleam format --check src test
```

Every consumer's manifest must resolve `gleam_stdlib`, `gleam_erlang`,
`gleam_otp` and `gleam_json` to the same versions this one does, because two
consumers write the same `deps/<app>` directories.
