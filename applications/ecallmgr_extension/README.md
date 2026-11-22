# Ecallmgr Extension

KAZOO code required to integrate with `mod_reprise` in FreeSWITCH
(`freeswitch/mod_reprise` in this tree).

`mod_reprise` is an open implementation of the AMQP transport of 2600hz's
previously commercial FreeSWITCH module `mod_com_kazoo`, which
replaces the legacy ErlangConnection (`mod_erlang_event`)/`freeswitch`
node protocol with AMQP as the transport between `ecallmgr` and
FreeSWITCH. This application implements the KAZOO side of that
AMQP-based protocol:

* **`kapi_freeswitch`** - defines and publishes the AMQP API used to talk to
  `mod_reprise` (API/bgapi calls, commands, events, config, dialplan/fetch
  replies, etc).
* **`mod_com_kazoo*`** - Erlang modules (named after 2600hz's FreeSWITCH
  module) implementing the equivalent of the classic
  `freeswitch` module's API (`api/3`, `bgapi/3`, `sendmsg/3`, `sendevent/3`,
  ...) but over AMQP, plus the listener, configuration and dialplan/fetch
  handlers that answer requests coming from FreeSWITCH.
* **`ecallmgr_amqp_*` / `ecallmgr_fs_amqp_*`** - supervisors and workers that
  manage per-node AMQP resources, the fetch request/response cycle (e.g.
  dialplan XML fetches), and event streams consumed from FreeSWITCH.
* **`metaflow_*`** - binds to and handles metaflow (in-call feature/DTMF
  control) requests delivered over AMQP instead of the node protocol.

In short, this application lets `ecallmgr` control and receive events
from a FreeSWITCH instance running the `mod_reprise` module purely over
AMQP, as an alternative to the built-in Erlang node
connection.
