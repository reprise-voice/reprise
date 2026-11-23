# Installation

Reprise runs from its container images or from a release built from
source:

* **A test cluster on one host:** the
  [Docker Compose quick start](../deploy/compose/README.md).
* **Container images:** `reprise` (both the `kazoo_apps` and the `ecallmgr`
  node), `reprise-freeswitch`, `reprise-kamailio` and `reprise-monster-ui`,
  published under `ghcr.io/reprise-voice/` and buildable from this tree
  with `docker/build.sh`. Their environment variables are in the
  [configuration reference](configuration.md#container-environment-variables),
  their runtime users and hardening in
  [container security](../docker/README.md).
* **From source:** see [building from source](building.md).

A running platform also needs CouchDB and an AMQP broker with the
consistent-hash exchange type (RabbitMQ with its plugin, or LavinMQ); see
the [configuration reference](configuration.md) and the
[architecture](architecture.md) for how the parts connect.

The Debian packages, RPM repositories and Erlang 23 instructions of
upstream Kazoo do not apply to Reprise.
