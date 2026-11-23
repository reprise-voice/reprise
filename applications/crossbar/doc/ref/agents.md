# Agents

## About Agents

#### Schema

An agent is a user of the account, so this API has no document of its own. An agent's own settings are the `call_center` object on the user, and their tier in a queue is an entry in that queue's `agents` list.



## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/agents

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents
```

## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}
```

## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status
```

## Patch

> PATCH /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status

```shell
curl -v -X PATCH \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/status
```

## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/log

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/log
```

## Fetch

> GET /v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/stats

```shell
curl -v -X GET \
    -H "X-Auth-Token: {AUTH_TOKEN}" \
    http://{SERVER}:8000/v2/accounts/{ACCOUNT_ID}/agents/{USER_ID}/stats
```
