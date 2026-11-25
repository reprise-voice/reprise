#!/bin/bash
set -e
umask 027

CONF=/etc/kazoo/freeswitch

# Addresses. LOCAL_IP / PUBLIC_IP can be given outright; otherwise the local
# address is the host's, and the public one is asked from the GCE metadata
# server when there is one (1:1 NAT: the NIC only carries the private IP, so
# the public one must be advertised in SDP/Contact or one-way audio follows).
MD="http://metadata.google.internal/computeMetadata/v1"
MDH="Metadata-Flavor: Google"
PUBLIC_IP="${PUBLIC_IP:-$(curl -sf -m 2 -H "$MDH" "$MD/instance/network-interfaces/0/access-configs/0/external-ip" || true)}"
LOCAL_IP="${LOCAL_IP:-$(curl -sf -m 2 -H "$MDH" "$MD/instance/network-interfaces/0/ip" || hostname -i | awk '{print $1}')}"
# What the SIP profile advertises: PUBLIC_IP for both signalling and media,
# unless EXT_SIP_IP or EXT_RTP_IP says otherwise for one of them. A media
# server that the SBC reaches on a private network but whose RTP ports are
# published on a public address needs them apart: EXT_SIP_IP is the address
# ecallmgr reports to Kamailio's dispatcher, which must be one Kamailio can
# reach, while EXT_RTP_IP is what goes into the SDP for the phones.
EXT_SIP_IP="${EXT_SIP_IP:-$PUBLIC_IP}"
EXT_RTP_IP="${EXT_RTP_IP:-$PUBLIC_IP}"
LOCAL_NETWORK_ACL="${LOCAL_NETWORK_ACL:-loopback.auto}"

VARS_LOCAL=$CONF/vars/vars_local.xml
mkdir -p "$CONF/vars"
{
  echo '<include>'
  echo "  <X-PRE-PROCESS cmd=\"set\" data=\"local_ip_v4=${LOCAL_IP}\"/>"
  if [ -n "$EXT_SIP_IP" ]; then
    echo "  <X-PRE-PROCESS cmd=\"set\" data=\"ext_sip_ip=${EXT_SIP_IP}\"/>"
  fi
  if [ -n "$EXT_RTP_IP" ]; then
    echo "  <X-PRE-PROCESS cmd=\"set\" data=\"ext_rtp_ip=${EXT_RTP_IP}\"/>"
  fi
  echo '</include>'
} > "$VARS_LOCAL"

# sip profile: advertise them (the configs default both to local_ip_v4)
if [ -f "$CONF/sip_profiles/sipinterface_1.xml" ]; then
  if [ -n "$EXT_SIP_IP" ]; then
    xmlstarlet ed -L -u '//param[@name="ext-sip-ip"]/@value' -v "$EXT_SIP_IP" \
      "$CONF/sip_profiles/sipinterface_1.xml" || true
  fi
  if [ -n "$EXT_RTP_IP" ]; then
    xmlstarlet ed -L -u '//param[@name="ext-rtp-ip"]/@value' -v "$EXT_RTP_IP" \
      "$CONF/sip_profiles/sipinterface_1.xml" || true
  fi
  # Which callers get the local address in the SDP rather than EXT_RTP_IP.
  # FreeSWITCH judges by the address the INVITE came from, and every call
  # here comes through Kamailio, so the ACL sees Kamailio, not the phone.
  # The configs' localnet.auto counts Kamailio as local whenever it shares
  # FreeSWITCH's subnet (a Docker bridge, a cloud VPC, pods on one node) and
  # puts an address the phones cannot reach in every SDP. loopback.auto
  # advertises EXT_RTP_IP to everything but this machine; with no NAT the
  # two addresses are the same and nothing changes. Set LOCAL_NETWORK_ACL
  # back to localnet.auto only if phones send SIP to FreeSWITCH directly.
  xmlstarlet ed -L -u '//param[@name="local-network-acl"]/@value' -v "$LOCAL_NETWORK_ACL" \
    "$CONF/sip_profiles/sipinterface_1.xml" || true
fi

# RTP port range: switch.conf.xml ships 16384-32768. RTP_START_PORT and
# RTP_END_PORT narrow it, e.g. to a range a container publishes 1:1; unset,
# the shipped range stands.
SWITCH_CONF=$CONF/autoload_configs/switch.conf.xml
for var in RTP_START_PORT RTP_END_PORT; do
  value="${!var:-}"
  [ -z "$value" ] && continue
  case "$value" in
    *[!0-9]*) echo "$var=$value: not a port number" >&2; exit 1 ;;
  esac
  param=$(echo "$var" | tr 'A-Z_' 'a-z-')
  xmlstarlet ed -L -u "//param[@name=\"$param\"]/@value" -v "$value" "$SWITCH_CONF"
done
if [ -n "${RTP_START_PORT:-}" ] && [ -n "${RTP_END_PORT:-}" ] \
    && [ "$RTP_START_PORT" -ge "$RTP_END_PORT" ]; then
  echo "RTP_START_PORT ($RTP_START_PORT) must be below RTP_END_PORT ($RTP_END_PORT)" >&2
  exit 1
fi

# Transport: this image ships mod_reprise (AMQP) only; the stock
# modules.conf.xml still names mod_kazoo, so rewrite the load line (and a
# mounted configuration that names the module's former name, mod_com_kazoo).
case "${KAZOO_TRANSPORT:-amqp}" in
  amqp) ;;
  *) echo "KAZOO_TRANSPORT=$KAZOO_TRANSPORT: only amqp is supported (mod_kazoo is not shipped)" >&2; exit 1 ;;
esac
MODULES_CONF=$CONF/autoload_configs/modules.conf.xml
# KZ_AMQP_HOSTS="host[:port],host[:port],..." is the failover list for this
# media server. The first entry feeds the stock kazoo/connections/up.xml
# through the kz_amqp_* vars (the shipped com.kazoo.conf reads them); every
# other entry gets its own connection file. The module tries them in order
# (the primary property first; the include glob is alphabetical, hence the
# file names sort after up.xml) and keeps them ahead of whatever brokers the
# fetched kazoo.conf names.
if [ -n "${KZ_AMQP_HOSTS:-}" ]; then
  KZ_AMQP_HOST="${KZ_AMQP_HOSTS%%,*}"
  case "$KZ_AMQP_HOST" in *:*) KZ_AMQP_PORT="${KZ_AMQP_HOST##*:}"; KZ_AMQP_HOST="${KZ_AMQP_HOST%%:*}";; esac
fi
: "${KZ_AMQP_HOST:?KZ_AMQP_HOST or KZ_AMQP_HOSTS required}"
export KZ_AMQP_HOST KZ_AMQP_PORT="${KZ_AMQP_PORT:-5672}" KZ_AMQP_USER="${KZ_AMQP_USER:-kazoo}" \
       KZ_AMQP_PASS="${KZ_AMQP_PASS:-kazoo}" KZ_AMQP_ZONE="${KZ_AMQP_ZONE:-local}" \
       KZ_AMQP_VHOST="${KZ_AMQP_VHOST:-/}"
rm -f "$CONF"/kazoo/connections/up_failover-*.xml
n=0
for entry in $(echo "${KZ_AMQP_HOSTS:-}" | tr ',' ' '); do
  n=$((n + 1)); [ "$n" -eq 1 ] && continue
  host="$entry"; port="$KZ_AMQP_PORT"
  case "$entry" in *:*) port="${entry##*:}"; host="${entry%%:*}";; esac
  cat > "$CONF/kazoo/connections/up_failover-$n.xml" <<EOX
<include>
  <connection name="failover-$n">
    <param name="hostname" value="$host"/>
    <param name="port" value="$port"/>
    <param name="username" value="\$\${kz_amqp_user}"/>
    <param name="password" value="\$\${kz_amqp_pass}"/>
    <param name="zone" value="\$\${kz_amqp_zone}"/>
    <property name="zone" value="\$\${kz_amqp_zone}"/>
    <property name="primary" value="false"/>
    <property name="is-federated" value="false"/>
    <property name="is-local" value="true"/>
    <property name="is-bootstrap" value="true"/>
  </connection>
</include>
EOX
done
xmlstarlet ed -L -u '//load[@module="mod_kazoo" or @module="mod_com_kazoo"]/@module' -v "mod_reprise" "$MODULES_CONF" || true

echo "freeswitch starting: local_ip=$LOCAL_IP ext_sip_ip=${EXT_SIP_IP:-$LOCAL_IP} ext_rtp_ip=${EXT_RTP_IP:-$LOCAL_IP} local_network_acl=$LOCAL_NETWORK_ACL rtp=$(xmlstarlet sel -t -v '//param[@name="rtp-start-port"]/@value' -o - -v '//param[@name="rtp-end-port"]/@value' "$SWITCH_CONF") hostname=$(hostname -f) transport=amqp (mod_reprise -> ${KZ_AMQP_HOSTS:-$KZ_AMQP_HOST:$KZ_AMQP_PORT} zone $KZ_AMQP_ZONE)"
exec /usr/local/freeswitch/bin/freeswitch -nf -nonat -np \
  -conf "$CONF" -log /var/log/freeswitch -db /var/lib/freeswitch/db \
  -run /run/freeswitch -cache /var/lib/freeswitch/cache \
  -storage /var/lib/freeswitch/storage -certs /var/lib/freeswitch/certs
