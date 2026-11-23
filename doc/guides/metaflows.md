# In-call metaflows (konami)

Metaflows act on a call that is already up: a party presses a binding digit
(`*` by default) and a sequence, and the platform transfers the call, starts
a recording, parks it, plays something, and so on. The `konami`
application listens for the digits and runs the actions; the API reference
is [applications/crossbar/doc/metaflows.md](../../applications/crossbar/doc/metaflows.md),
and each action has a page under
[applications/konami/doc](../../applications/konami/doc/README.md).

## Enabling it

1. **Run `konami`.** It is not in the default application list. Start it on
   a kazoo_apps node:

   ```console
   $ sup kapps_controller start_app konami
   $ sup konami_maintenance is_running
   ```

   To start it at every boot, add it to the node's `KAZOO_APPS` or to
   `kapps` in `system_config/kapps_controller`
   ([configuration](../configuration.md#which-applications-a-node-runs)).

2. **Run `ecallmgr_extension`** on the ecallmgr node, as every Reprise
   cluster must. It carries the metaflow bindings to FreeSWITCH over AMQP.
   DTMF metaflows are only triggered on bridged channels
   ([ecallmgr_extension notes](../../applications/ecallmgr_extension/doc/README.md#metaflows)).

3. **Give the endpoints metaflows.** A metaflow definition is a
   `metaflows` object on an account, a user or a device:

   - `/v2/accounts/{ACCOUNT_ID}/metaflows`
   - `/v2/accounts/{ACCOUNT_ID}/users/{USER_ID}/metaflows`
   - `/v2/accounts/{ACCOUNT_ID}/devices/{DEVICE_ID}/metaflows`

   When a callflow rings a device, Kazoo merges the account's, the device's
   and the owner's `metaflows` into the endpoint like its other attributes,
   and if the result is not empty it asks `konami` to listen on the call.

## An example

Let `*2<extension>` blind-transfer the other party, for every device in an
account:

```shell
curl -X POST -H "X-Auth-Token: $AUTH_TOKEN" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/metaflows \
    -d '{"data":{"binding_digit":"*","patterns":{"2(\\d+)":{"module":"transfer","data":{"takeback_dtmf":"*1"}}}}}'
```

`numbers` maps exact sequences, `patterns` maps regular expressions whose
captures are passed to the action. Each entry names a `module` (an action
under `applications/konami/src/module`: `audio_level`, `break`, `callflow`,
`hangup`, `hold`, `intercept`, `move`, `play`, `record_call`, `resume`,
`say`, `transfer`, `tts`) and its `data`.

## System defaults

`system_config/metaflows` holds the defaults `konami` falls back to:
`binding_digit` (`*`), `digit_timeout_ms` (800), `listen_on` (`a`),
`numbers` and `patterns` (both default to a test entry that says "hi" on
`2`), and `default_metaflow`. `sup konami_maintenance add_default_metaflow`
and `sup konami_maintenance add_default_account_metaflow <account_id>` are
interactive builders for the default metaflow (they prompt for each
value).

The `listen_on` values differ between the two places they are set: the
endpoint schema (`metaflows.json`) takes `both`, `self` or `peer`, while
`system_config/metaflows` is read as `a`, `b`, `ab` or `both`
(`applications/konami/src/konami_config.erl`).
