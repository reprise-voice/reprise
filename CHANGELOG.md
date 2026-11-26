# Changelog

All notable changes to Reprise are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases are
`v*` tags on `main`.

## [Unreleased]

### Changed

- The FreeSWITCH image builds FreeSWITCH v1.11.4 (from v1.11.3) against
  sofia-sip v1.13.19 (from v1.13.18), which fixes an out-of-bounds read
  when parsing multipart MIME bodies. FreeSWITCH 1.11.4 also brings upstream
  security fixes (MSRP parsing, REFER targets carrying dial-string
  separators) and requires sofia-sip 1.13.19. The image now builds against
  Debian's miniupnpc and libnatpmp, which FreeSWITCH no longer carries
  in-tree. All seven patches in `docker/freeswitch/patches` apply unchanged.
- FreeSWITCH 1.11.4's `deflect` sends a target that already carries a URI
  scheme as given and sends no REFER for an empty target, where 1.11.3 sent
  `sip:@<profile ip>`. ecallmgr's `sip:` redirect contacts are unaffected.
- Kamailio's dispatcher no longer reloads when a media server joins or
  leaves. A reload rebuilt every destination from its stored flags
  (inactive and probing), so for up to a ping interval (10 s) every
  destination was inactive and the SBC answered every call "480 All
  servers busy". The table is still kept from ecallmgr's heartbeats; one
  timer process now applies each change to the dispatcher with
  `dispatcher.add` or `dispatcher.remove`, which leave every other
  destination's state as it is. A new server takes calls once its pings
  answer. A server that leaves takes its secondary address
  (`dispatcher_add_secondary_ip`) with it, which used to stay listed.

## [5.4.0] - 2026-11-24

The initial public release. Reprise is based on Kazoo 5.4 (`VERSION`
5.4.0); this entry describes what differs from Kazoo 5.4 as 2600Hz
published it. See [doc/upgrading-from-kazoo.md](doc/upgrading-from-kazoo.md)
before moving an existing cluster.

### Added

- `freeswitch/mod_reprise`: an open FreeSWITCH module implementing the AMQP
  transport between FreeSWITCH and ecallmgr (the wire contract of 2600Hz's
  closed `mod_com_kazoo`): configuration and dialplan fetches, event
  streams, call control, originate, CDRs, presence dialog updates for BLF,
  `prompt://` media, recording upload, broker failover. Unit tests and
  native call-path regression tests run in the `reprise-freeswitch-dev`
  image.
- `tools/fs-contract-probe`: a fake FreeSWITCH node for checking the AMQP
  wire contract against a running `ecallmgr_extension`.
- `core/kazoo_gleam`: Gleam bindings to the Kazoo core (datastore,
  configuration, AMQP, Crossbar, callflow), with an in-memory fake for
  tests.
- `callcenter` (Gleam): call queues and agents, with six distribution
  strategies, periodic announcements, exit keys, breaks, a login lamp for
  BLF keys, eavesdrop, whisper and pickup, the `queues` and `agents`
  Crossbar APIs and the `callcenter` and `callcenter_agent` callflow
  actions. In the default application list.
- `stir` (Gleam): STIR/SHAKEN signing of outbound carrier calls and
  verification of inbound ones, keys generated and sealed under a
  key-encryption key (`STIR_KEK`), certificates through CSRs, STI-PA trust
  material with authenticated CRLs, the `/v2/stir` API and the
  `stir_shaken` callflow action. Off until enabled.
- `konami`: in-call metaflows, ported from Kazoo 4.x to 5.x.
- `kazoo_numbers`: a Telnyx API v2 carrier module.
- `system_config/pusher` `token_type_modules`: push modules for further
  token types without code changes.
- `system_config/crossbar.auth` `external_auth_methods`: token methods
  minted by other applications, listed in configuration.
- Container images built from this tree: `reprise` (both Erlang node
  types), `reprise-freeswitch` (with `reprise-freeswitch-dev`),
  `reprise-kamailio` and `reprise-monster-ui`, with `docker/build.sh` and
  `docker/test-security.sh`.
- Documentation: architecture, configuration, building, upgrading notes,
  and guides for metaflows, the call center and STIR/SHAKEN.

### Changed

- Erlang/OTP 28 (from OTP 26), with the dependencies moved to versions
  that build on it.
- Every source repository the build fetches is a fork under
  github.com/reprise-voice at a pinned commit or tag, selectable as a whole
  with `REPRISE_GIT_BASE`.
- The FreeSWITCH image builds FreeSWITCH v1.11.3 with patches for session
  handoff, intercept, early transfer, loopback replacement events, event
  flags, bridge ownership and inline `ring_ready` (the caller hears ringing
  as soon as a call is routed).
- Kamailio is built from the reprise-voice fork (Kamailio 6.1 with the
  `kazoo` and `db_kazoo` modules); `configs/kamailio` gains the files
  Kamailio 5.8 and 6.x need.
- Kamailio authorizes SUBSCRIBE against the watcher's own account, retires
  expired presence subscriptions exactly once, escapes published header
  values as JSON, enables the pusher role, and bounds its AMQP connect at
  ten seconds.
- Consistent-hash exchanges are declared for both RabbitMQ (`hash-header`)
  and LavinMQ (`x-hash-on`), and the call-id hash header is a string, so
  LavinMQ routes Kazoo's own call events.
- All images run as unprivileged users; Monster UI listens on 8080.
- The release image includes LibreOffice for office-document fax
  attachments, and the release no longer includes the GUI tools (`wx`,
  `observer`, `debugger`).
- Defaults that pointed at 2600Hz: new account realms are generated under
  `sip.example.com`, the mobile realm defaults to `mobile.example.com`, new
  faxbox addresses to `fax.example.com`, the SNMP `sysContact` is empty, and
  FreeSWITCH, ecallmgr and Kamailio send `Reprise` as their SIP User-Agent.
- A release is refused from a tree compiled for tests.

### Removed

- `kazoo_telemetry`, which sent cluster metrics to a 2600Hz endpoint, and
  its `system_config` schemas.
- The 2600Hz commercial documentation, KazooCon material, blog posts and
  App Exchange guides from `doc/`.

### Fixed

- A received fax is uploaded as soon as its document is saved.
- A webhook created disabled is not loaded.
- A pickup or park retrieval that moves media servers keeps its answered
  CDR.
- `ecallmgr_extension` re-initializes a media server that comes back with a
  new Core-UUID.
- Unset call recording settings inherit from the level below, and callflow
  defaults missing recording announcement settings.
- A digit pressed during `kz_endless_playback` is published at once.
- Kamailio publishes the surviving binding when a replaced contact
  unregisters.
