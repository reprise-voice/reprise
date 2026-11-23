## Stir Shaken

### About Stir Shaken

#### Schema

Validator for the stir_shaken callflow data object. The action branches on the inbound STIR/SHAKEN verdict, to the child passed, failed or none, and takes no data of its own: the prefix put on the caller id name of a failed call is cid_name_prefix_failed in system_config/stir



Key | Description | Type | Default | Required | Support Level
--- | ----------- | ---- | ------- | -------- | -------------
`skip_module` | When set to true this callflow action is skipped, advancing to the wildcard branch (if any) | `boolean()` |   | `false` |  



