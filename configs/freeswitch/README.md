# configs/freeswitch

The FreeSWITCH configuration for Reprise, derived from 2600hz's
kazoo-configs-freeswitch (5.4). `freeswitch/` is installed as `/etc/kazoo/freeswitch` (the
path the Erlang side and the files themselves expect); `system/` carries
the init, systemd, logrotate and launcher files for a package install.

The `docker/freeswitch` image copies `freeswitch/` into place and renders the
site-specific parts from the container environment at start.
