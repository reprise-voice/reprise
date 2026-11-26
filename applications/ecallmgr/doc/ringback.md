# Ringback and codec negotiation

What a caller hears while a call rings, and why it decides the caller's
codec.

## Two settings

`system_config/ecallmgr` has two ringback settings. Each applies only when
the call has no ringback of its own (a `Ringback-Media` on the route, or a
`Ringback` on the bridge).

| Setting | Played to | Default |
|---|---|---|
| `default_ringback` | a caller not answered yet | unset: none |
| `default_transfer_ringback` | a caller already answered (after a menu, on a transfer, a queue offering to an agent) | `default_ringback` when that is set, otherwise `%(2000,4000,440,480)` |

ecallmgr sets these on the call as FreeSWITCH's `ringback` and
`transfer_ringback`. FreeSWITCH plays `transfer_ringback` to a caller it has
already answered and `ringback` to one it has not.

## Why a caller not answered yet hears none

The profile negotiates codecs late (`inbound-late-negotiation`) and gives the
caller's leg its callee's codec when the callee answers (`inherit_codec`).
Both phones on G722 stay on G722, and a G722 phone calling a carrier that
only answers PCMU is answered on PCMU, so nothing is transcoded.

That only works while the caller's leg is still waiting for SDP. To play a
ringback to a caller it has not answered, FreeSWITCH has to pre-answer that
caller, which sends it SDP and settles its codec: the first one in
`inbound_codecs` the caller offered, G722 for most phones and carriers. By
then the callee has not answered, so the caller's codec is chosen without
it, and a callee that answers on another codec is transcoded for the whole
call. With FreeSWITCH's own ringback this happens as soon as the callee
starts ringing; a carrier's 180 does the same on an outbound call.

With no `default_ringback`, the caller keeps the 180 it has already had
(phones, softphones and carriers play their own ringback on it) and gets SDP
only from the callee's early media or answer, on the callee's codec.

A caller already answered has its codec already, so
`default_transfer_ringback` costs nothing, and without it that caller would
hear silence while the next phone rings.

## Callers that need a ringback played to them

A caller that plays nothing on a 180 hears silence until the call is
answered. Most often that is a WebRTC client whose application does not play
its own ringback. Setting `default_ringback` plays one to every caller, at
the cost described above:

```shell
sup kapps_config set_default ecallmgr default_ringback '%(2000,4000,440,480)'
```

A ringback a call asks for itself (an account's or a callflow's ringback
media) is still played, with the same cost, because someone chose it.

## Clusters from before the split

Kazoo stored `default_ringback` (`%(2000,4000,440,480)`) in
`system_config/ecallmgr` the first time it read it, so every cluster that has
routed a call has it, Reprise 5.4.0 clusters included. ecallmgr reads the
stored value as a setting someone chose, and such a cluster keeps playing a
ringback to callers not answered yet, as before. To have it negotiate as a
new cluster does, delete the stored value:

```shell
sup kapps_config set_default ecallmgr default_ringback ''
```

An empty value is the same as none. If `default_ringback` held a custom tone
that answered callers should keep hearing, set `default_transfer_ringback` to
it first.
