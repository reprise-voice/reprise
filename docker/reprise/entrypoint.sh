#!/bin/bash
set -e
umask 027

# epmd for local `sup` / nodetool (kazoo<->kazoo dist rides AMQP; this is loopback only)
epmd_binaries=(/opt/kazoo/erts-*/bin/epmd)
"${epmd_binaries[0]}" -daemon

mkdir -p /opt/kazoo/log /opt/kazoo/var/lib/ra /tmp/log /tmp/erl_pipes

echo "starting kazoo node=${KAZOO_NODE} apps=${KAZOO_APPS:-<from config/node name>}"
exec /opt/kazoo/bin/kazoo foreground
