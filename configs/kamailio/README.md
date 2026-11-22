# configs/kamailio

The Kamailio configuration for Reprise, derived from 2600hz's
kazoo-configs-kamailio (5.4). `kamailio/` is installed as `/etc/kazoo/kamailio` (the
path the Erlang side and the files themselves expect); `system/` carries
the init, systemd, logrotate and launcher files for a package install.

The `docker/kamailio` image copies `kamailio/` into place and renders the
site-specific parts from the container environment at start.

## Presence policy and subscription lifecycle

SUBSCRIBE is authorized before the presence module sees it
(`PRESENCE_SUBSCRIBE_AUTHORIZATION`, `presence-role.cfg`): an authenticated
device may monitor presentities of its own account only. The account realm
comes from Kazoo's authentication reply (`Account-Realm`), for digest
authentication and for the registered-contact shortcut alike
(`AUTHORIZATION_SETUP_IDENTITY`, `authorization.cfg`); the presentity is the
Request-URI, as the presence module uses it. Refreshes are authorized against
the stored dialog and its owner, the owner may always unsubscribe, and stored
watchers that no longer satisfy the policy are revoked on refresh and by the
cleanup backstop. There is no parent/child, sibling or alias-based cross-account
access; monitoring aliases and custom presence ids are user parts within the
account realm. Denials are a generic `403` without state.

Subscriptions are retired as they expire by a one-second sweep
(`PRESENCE_EXPIRY_SWEEP`, `presence-notify.cfg`): each expired row is claimed
with one conditional update, gets at most one terminal `NOTIFY`
(`terminated;reason=timeout`, `KZ_PRESENCE_EXPIRY_TERMINAL_NOTIFY`) and is
deleted by id. The presence module's reply handler treats a completed terminal
notification as the end of the dialog. Statistics: `presence:subscribe_*`,
`presence:refresh_*`, `presence:watcher_revoked`, `presence:expired_*`,
`presence:terminal_notify_completed`.

