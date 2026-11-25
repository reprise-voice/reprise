# FreeSWITCH patches

The FreeSWITCH image builds FreeSWITCH v1.11.4 with these patches, applied
in order. They add behaviour that ecallmgr and `mod_reprise` rely on and
that stock FreeSWITCH does not have. Patches 0001 to 0005 and 0007 follow
the FreeSWITCH build 2600Hz distributed with Kazoo (20.23.6); 0006 is a fix
of our own.

| Patch | What it does |
|---|---|
| `0001-kazoo-session-handoff` | Lets the module's `kz` endpoint hand a call from one session to another and keep the answered or early-media state of the leg that won. A replacement session that is missing, dead or the session itself is refused. Ordinary pickup is unchanged. |
| `0002-kazoo-intercept` | Gives `kz_intercept`, which pickup uses, its own way of accepting a group confirmation. |
| `0003-kazoo-early-transfer` | Handles an attended transfer that completes while the consultation call is still being set up. A consultation leg whose dialog ends in that window hangs up when the originate finishes. |
| `0004-loopback-replacement-event` | Puts the channel's identity on the event a loopback channel publishes when another channel replaces it. |
| `0005-kazoo-event-flags` | Records the names of a channel's flags on each event as it is created. ecallmgr's transfer handling filters on them. |
| `0006-loopback-bridge-ownership` | Stops a bridge that has bowed out from hanging up the channel that replaced it. |
| `0007-ring-ready-inline` | Allows `ring_ready` to run inline while a call is being routed. ecallmgr's route response starts with it, so the caller hears ringing as soon as the call is routed, unless the response sets `Ignore-Progress`. |

## Building

The Dockerfile checks each patch with `git apply --check` before applying
it, so a build against a FreeSWITCH revision that a patch no longer fits
fails instead of producing a half-patched tree.

The patched core, Sofia, `mod_loopback` and `mod_reprise` are one unit:
build and ship them together. The module refuses to load on a core without
the patches. Keep `bowout-hangup-cause=BOWOUT` in the loopback
configuration that `configs/freeswitch` ships.

## Testing

Run `make test` and `make test-call-paths` in `freeswitch/mod_reprise`,
inside the `reprise-freeswitch-dev` image built from this Dockerfile. The
call-path suites cover handoff, pickup, transfer and the bridge fix; see
[freeswitch/mod_reprise/README.md](../../../freeswitch/mod_reprise/README.md#building).
`REPRISE_TEST_TRACE=1` prints the full call logs.
