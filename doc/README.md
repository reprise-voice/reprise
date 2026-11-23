# Reprise documentation

This directory holds the documentation that is not tied to one application;
each application and core library also keeps its own under its `doc/`
directory or in its README. Start with the [repository README](../README.md).

## Getting started

* [Quick start with Docker Compose](../deploy/compose/README.md)
* [Architecture](architecture.md): the components, the life of a
  registration and of a call, and what differs from upstream Kazoo
* [Configuration reference](configuration.md): `config.ini`, image
  environment variables, `system_config`, the broker, CouchDB, ports
* [Building from source](building.md)
* [Coming from Kazoo 5.x](upgrading-from-kazoo.md)
* [Container images and their security](../docker/README.md)

## Feature guides

* [Call center](guides/callcenter.md)
* [In-call metaflows (konami)](guides/metaflows.md)
* [STIR/SHAKEN](guides/stir-shaken.md)

## Operator reference

* [ecallmgr configuration](../applications/ecallmgr/doc/config.md)
* [ecallmgr maintenance commands](../applications/ecallmgr/doc/maintenance.md)
* [Managing ACLs](../applications/ecallmgr/doc/acls.md)
* [FreeSWITCH module (mod_reprise)](../freeswitch/mod_reprise/README.md)
* [FreeSWITCH patches](../docker/freeswitch/patches/README.md)
* [FreeSWITCH configuration](../configs/freeswitch/README.md) and
  [Kamailio configuration](../configs/kamailio/README.md)
* [Stepswitch resources](../applications/stepswitch/doc/resources.md)
* [Internationalization](internationalization/numbers.md)
* [Call recording](user_guides/call_recording.md)
* [Rating and limits](reference/routing.md)

## Integrator reference

* [REST API](../applications/crossbar/doc/README.md)
* [Webhooks](../applications/webhooks/doc/README.md)
* [Websockets](../applications/blackhole/doc/README.md)
* [Pivot](../applications/pivot/doc/README.md)

## Developer reference

* [Contributing and code standards](../CONTRIBUTING.md)
* [Engineering notes](engineering/), including the
  [STIR/SHAKEN design](engineering/stir-shaken.md) and the
  [Makefile notes](engineering/make.md)
* [Gleam bindings](../core/kazoo_gleam/README.md)
* [AMQP library](../core/kazoo_amqp/doc/README.md)
* [Number manager library](../core/kazoo_numbers/doc/README.md)
* [Datastore library](../core/kazoo_data/doc/)
* [FreeSWITCH wire-contract probe](../tools/fs-contract-probe/README.md)
* [Provenance and licenses](provenance.md): where each imported tree
  came from

## The documentation site

The `doc/mkdocs` directory builds a browsable site from these pages and the
application reference (`make docs`; it needs `mkdocs` and `cpio`). Its
navigation is `doc/mkdocs/dev_header_yml` followed by every `dev.yml` file
under `applications/`, `core/` and `doc/`.

## Background reading

* [Learn You Some Erlang](https://learnyousomeerlang.com/)
* [Gleam](https://gleam.run/documentation/)
* [FreeSWITCH documentation](https://developer.signalwire.com/freeswitch/)
* [Kamailio documentation](https://www.kamailio.org/w/documentation/)
* [AMQP concepts](https://www.rabbitmq.com/tutorials/amqp-concepts.html)
* [CouchDB documentation](https://docs.couchdb.org/)
