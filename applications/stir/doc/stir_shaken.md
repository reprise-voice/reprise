## Stir Shaken

### About Stir Shaken

Branches on the STIR/SHAKEN verdict the `stir` application reached for the inbound call, before the flow started: the child `passed` when the Identity header verified, `failed` when it did not (`TN-Validation-Failed`), and `none` when the call carried no Identity header or the verdict is unknown. A flow without the child taken continues to `_`, as any action does.

The action takes no data. What it does with a failed call is decided by `system_config/stir`: when `cid_name_prefix_failed` is set, the prefix goes in front of the caller id name before the flow continues, so a phone shows the call for what it is. A name that already carries the prefix is left alone.

#### Schema

Validator for the stir_shaken callflow data object. The action branches on the inbound STIR/SHAKEN verdict, to the child passed, failed or none, and takes no data of its own: the prefix put on the caller id name of a failed call is cid_name_prefix_failed in system_config/stir



Key | Description | Type | Default | Required | Support Level
--- | ----------- | ---- | ------- | -------- | -------------
`skip_module` | When set to true this callflow action is skipped, advancing to the wildcard branch (if any) | `boolean()` |   | `false` |  



