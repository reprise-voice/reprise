#!/bin/bash
set -e
umask 027

CONF=/etc/kazoo/kamailio

# Identity. MY_HOSTNAME / MY_LOCAL_IP / MY_PUBLIC_IP can be given outright;
# otherwise the local address is the host's (asked from the GCE metadata
# server when there is one), and the public address defaults to the local one.
MD="http://metadata.google.internal/computeMetadata/v1"
MDH="Metadata-Flavor: Google"
export MY_HOSTNAME="${MY_HOSTNAME:-$(hostname -f)}"
export MY_LOCAL_IP="${MY_LOCAL_IP:-$(curl -sf -m 2 -H "$MDH" "$MD/instance/network-interfaces/0/ip" || hostname -i | awk '{print $1}')}"
export MY_PUBLIC_IP="${MY_PUBLIC_IP:-$MY_LOCAL_IP}"
export MY_AMQP_URL="${MY_AMQP_URL:-amqp://guest:guest@127.0.0.1:5672}"
# Origin a secure-websocket client must present (websockets-role.cfg).
export MY_WEBSOCKET_DOMAIN="${MY_WEBSOCKET_DOMAIN:-$MY_HOSTNAME}"

# MY_INTERNAL_IP (optional): give the FreeSWITCH side its own listener,
# udp:MY_INTERNAL_IP:5070 with no advertised address (the configs'
# WITH_INTERNAL_LISTENER). Phones keep talking to MY_PUBLIC_IP, while
# FreeSWITCH sees and routes back to the internal address -- for a Kamailio
# whose advertised address FreeSWITCH cannot reach directly, e.g. a host's
# address in front of a container network. Unset, nothing changes.
INTERNAL_DESC=off
[ -n "${MY_INTERNAL_IP:-}" ] && INTERNAL_DESC="udp:$MY_INTERNAL_IP:5070"

# (KAMAILIO_LOCAL_CFG_TEMPLATE points at an alternative template, e.g. one
# mounted from a directory)
{
  if [ -n "${MY_INTERNAL_IP:-}" ]; then
    echo '#!define WITH_INTERNAL_LISTENER'
    echo "#!define MY_INTERNAL_IP ${MY_INTERNAL_IP}"
  fi
  # (the single-quoted list names the variables envsubst substitutes)
  # shellcheck disable=SC2016
  envsubst '$MY_HOSTNAME $MY_LOCAL_IP $MY_PUBLIC_IP $MY_AMQP_URL $MY_WEBSOCKET_DOMAIN' \
    < "${KAMAILIO_LOCAL_CFG_TEMPLATE:-/local.cfg.tpl}"
} > "$CONF/local.cfg"

# Database: db_kazoo (2600hz's in-process sqlite driver), the configs'
# default (kazoo:///etc/kazoo/kamailio/db/kazoo.db). Created fresh at every
# start by the configs' own script through the KazooDB tool. Its content
# (registrations, subscriptions, dispatcher, key cache) is rebuilt by the
# phones and by Kazoo, so nothing is worth persisting.
export KAMAILIO_SHARE_DIR=/usr/share/kamailio
export DB_SCRIPT_DIR=$CONF/db_scripts
export DB_LOCATION=$CONF/db
# (the directory may be a mounted volume, so clear its content rather than it)
mkdir -p "$DB_LOCATION" && rm -rf "${DB_LOCATION:?}"/*
# create = the module tables; check = 2600hz's extras (jwt_keys, watcher
# triggers, the views) and the schema diff — the launcher runs both.
"$DB_SCRIPT_DIR/create-kazoodb-sql.sh" >/dev/null
"$DB_SCRIPT_DIR/check-kazoodb-sql.sh" >/dev/null 2>&1 || true
DB_DESC="db_kazoo, ephemeral, $(KazooDB -db "$DB_LOCATION/kazoo.db" 'select count(*) from sqlite_master where type="table"') tables"

# TLS (tls.cfg reads certs/cert.pem + certs/key.pem): link the Let's Encrypt
# pair for KAM_TLS_DOMAIN when the host mounted one (/etc/letsencrypt, with
# live/ -> archive/ symlinks intact, so `kamcmd tls.reload` after a renewal
# picks up the new files). A configured domain must be readable; when no
# domain is configured, use a self-signed pair for development.
CERTS=$CONF/certs
mkdir -p "$CERTS"
LE="/etc/letsencrypt/live/${KAM_TLS_DOMAIN:-}"
if [ -n "${KAM_TLS_DOMAIN:-}" ]; then
  if [ ! -s "$LE/fullchain.pem" ] || [ ! -r "$LE/fullchain.pem" ] \
      || [ ! -s "$LE/privkey.pem" ] || [ ! -r "$LE/privkey.pem" ]; then
    echo "TLS certificate and key at $LE must exist and be readable by UID $(id -u)" >&2
    exit 1
  fi
  ln -sfn "$LE/fullchain.pem" "$CERTS/cert.pem"
  ln -sfn "$LE/privkey.pem" "$CERTS/key.pem"
  TLS_DESC="letsencrypt $KAM_TLS_DOMAIN"
else
  rm -f "$CERTS/cert.pem" "$CERTS/key.pem"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$MY_HOSTNAME" \
    -keyout "$CERTS/key.pem" -out "$CERTS/cert.pem" 2>/dev/null
  TLS_DESC="self-signed (no certificate at $LE)"
fi

# -m/-M/-x match 2600hz's kazoo-kamailio launcher (system/sbin): the config is
# too large for kamailio's 8MB default PKG memory — parse fails mid-file.
if [ "${KAMAILIO_CHECK_CONFIG:-0}" = "1" ]; then
  # parse the rendered configuration with the image's modules and exit:
  # -c loads modules and resolves routes/functions
  echo "kamailio checking configuration: host=$MY_HOSTNAME local=$MY_LOCAL_IP db=$DB_DESC"
  exec kamailio -c -E -m 64 -M 16 -x tlsf -w /tmp -f "$CONF/kamailio.cfg"
fi

echo "kamailio starting: host=$MY_HOSTNAME local=$MY_LOCAL_IP public=$MY_PUBLIC_IP internal=$INTERNAL_DESC tls=$TLS_DESC wss-origin=$MY_WEBSOCKET_DOMAIN db=$DB_DESC"
exec kamailio -DD -E -m 64 -M 16 -x tlsf -w /tmp -f "$CONF/kamailio.cfg"
