# Conference Authentication

A Crossbar Authentication module for public conferences.

## Not loaded by default in Reprise

`cb_conference_auth` is left out of Crossbar's default module list, so both
routes below answer 404 until an operator adds the module to
`system_config/crossbar.autoload_modules` or starts it with
`sup crossbar_maintenance start_module cb_conference_auth`. Two reasons,
both of which need fixing before the module is used again:

1. **The token it mints is not confined to the conference.** The claims
   carry `conference_id`, `pin_number` and `scope: crossbar:conference_join`,
   but nothing in Crossbar reads them: no module binds an `allowed_scopes`
   event, so scope enforcement in `api_util` always sees an empty
   requirement; `cb_conferences` never compares the token's `conference_id`
   with the requested one; and there is no `token_restrictions` ruleset for
   the `cb_conference_auth` method, so a token with no `owner_id` lands in
   the unrestricted `admin` bucket. What is left is `cb_simple_authz`, which
   scopes the token to the account tree. An invite link therefore carried a
   token with full Crossbar access to the account, and until the expiry
   change in kazoo_auth the method's default `"infinity"` lifetime made that
   permanent.
2. **Nothing in this fork consumes it.** The public conference join app
   that read the bridge details with this token was a 2600hz web
   application, and nothing in this tree offers a shareable link or a public
   join page.

To bring it back: add a `token_restrictions` template for the
`cb_conference_auth` method that allows `conferences` reads only (the
system template lives in `system_config/crossbar.token_restrictions`), make
`cb_conferences` refuse a `cb_conference_auth` token whose `conference_id`
claim is not the conference being read, give the method a short
`token_auth_expiry_s` in `crossbar.auth` instead of `"infinity"`, and only
then add the module back to `?DEFAULT_MODULES` in `src/crossbar.hrl`.

## About Conference Authentication

This module module provide an authentication for public conferences or can if there is a valid JWT, create an invite link to the public including a JWT token.

The account that the requested conference belongs needs to have their reseller account configured a public conference domain in the reseller's white label document.

The generated JWT token in this module will have a limited scope to only read the conference bridge info from desktop application API to join the conference.

#### Schema

Schema for conference_auth



Key | Description | Type | Default | Required | Support Level
--- | ----------- | ---- | ------- | -------- | -------------
`account_name` | The account name of the conference | `string(1..128)` |   | `true` |  
`conference_name` | Conference name | `string(1..128)` |   | `true` |  
`conference_pin` | Conference member pin number | `string()` |   | `true` |  



## Request Auth Token for a conference

If accessing public conference domain directly, a user can get logging by MUST provide:

1) A conference name
2) The conference member pin number
3) An account name

The successful response payload Auth Token then can be used to request the conference bridge info.

> PUT /v2/conference_auth

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    -d '{ "data": {"account_name": "dummy", "conference_pin": "2600", "conference_name": "Our public Townhall"} }' \
    http://{SERVER}:8000/v2/conference_auth
```

## Get an link to a conference

To create a link to public link, the person that want to create and share the invite link must be a Kazoo user already and have logged in to the UI.
Then they can create a link by making a request to this API.

The successful response payload have an JSON object containing the full link to the conference with JWT token included.

Upon opening the link the conference login app will uses the provided JWT to request the conference bridge info.

> PUT /v2/accounts/{ACCOUNT_ID}/conference_auth/{CONFERENCE_ID}

```shell
curl -v -X PUT \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/conference_auth/{CONFERENCE_ID}
```

Successful response:

```json

{
    "auth_token": "{AUTH_TOKEN}",
    "data": {
        "link": "conf.test.com?auth=eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6IjJjYmVlZTAzYjJhZjk4Yjg0YzYxNTYwMDg2YTFmYjY3In0.eyJpc3MiOiJrYXpvbyIsImlkZW50aXR5X3NpZyI6IkUzbFlybEZOU0ltSkNxX295Q0hxZXB5bzdCSUhEMFI2M3UtV3VsNWZtd1UiLCJhY2NvdW50X2lkIjoiMWQ1OGQ2MGRiNmE2NjdmMzRhMTgzNDE4NzhlNzc3YmIiLCJtZXRob2QiOiJjYl9jb25mZXJlbmNlcyIsImV4cCI6MTYwMzQ4NTA3NCwiYWNjb3VudF9pZCI6IjFkNThkNjBkYjZhNjY3ZjM0YTE4MzQxODc4ZTc3N2JiIiwiY29uZmVyZW5jZV9pZCI6IjMxNDE1ZGM4Y2FjN2QyOWQxMzAxOGUwY2E0ZmZlMzM5IiwicGluX251bWJlciI6IjEyMzQiLCJzY29wZSI6ImNyb3NzYmFyOmNvbmZlcmVuY2Vfam9pbiJ9.UoSO5AkoTQI9zoL2kbTWXxyNpA_-9nVVpTW8OqtNskX41JdNp46JHPGAfgVRpVM_T_susvd-yhvgLoHzCehBwA-P52nh8ZXcnaRY-RLdMrg9nqM96kwQKvv0The4lKEXgRoZ-EOW-S1YnlrKXIsTqggGzIVZZMVctoJSGtgKQe3Sz6V-oawnefmFL57utqA-z2sFwv0WfYxCH44Na0S3Y5H0iMNIRjZD4oVBbJOXU9mr2CDe641wJr5sEW0Q_pkquRr7tM1aojPie-M7w0r9inXzSagey-mp98iRD7qcLcVOIYqibnCYnk9cmOw8GiG6_nC_3bfBdDy_2kRvg093WA"
    },
    "node": "{NODE}",
    "request_id": "{REQUEST_ID}",
    "revision": "1-100475067fa624422c9a21bd976c7b84",
    "status": "success",
    "timestamp": "{TIMESTAMP}",
    "version": "4.2.2"
}
```
