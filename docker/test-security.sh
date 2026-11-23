#!/bin/bash
# Run after docker/build.sh; image overrides also allow testing candidate tags.
set -euo pipefail
REGISTRY="${REGISTRY:-reprise}"
TAG="${TAG:-dev}"
REPRISE_IMAGE="${REPRISE_IMAGE:-$REGISTRY/reprise:$TAG}"
FREESWITCH_IMAGE="${FREESWITCH_IMAGE:-$REGISTRY/reprise-freeswitch:$TAG}"
KAMAILIO_IMAGE="${KAMAILIO_IMAGE:-$REGISTRY/reprise-kamailio:$TAG}"
MONSTER_UI_IMAGE="${MONSTER_UI_IMAGE:-$REGISTRY/reprise-monster-ui:$TAG}"
FLAGS=(--rm --network none --cap-drop=ALL --security-opt=no-new-privileges)

check_permissions() {
  local image="$1" writable="$2" immutable="$3"
  echo "Checking runtime permissions: $image"
  docker run "${FLAGS[@]}" --entrypoint /bin/sh \
    -e WRITABLE="$writable" -e IMMUTABLE="$immutable" "$image" -ec '
      test "$(id -u)" -ne 0
      test "$(id -g)" -ne 0
      for path in $WRITABLE; do
        test -w "$path" || { echo "Not writable: $path" >&2; exit 1; }
      done
      for path in $IMMUTABLE; do
        test ! -w "$path" || { echo "Unexpectedly writable: $path" >&2; exit 1; }
      done
      privileged=$(find /usr /opt -xdev -type f -perm /6000 -print)
      test -z "$privileged" || { echo "$privileged" >&2; exit 1; }
    '
}

check_permissions "$REPRISE_IMAGE" \
  '/var/lib/kazoo /opt/kazoo/log /opt/kazoo/var/lib/ra' \
  '/entrypoint.sh /opt/kazoo/bin /opt/kazoo/lib /opt/kazoo/releases /etc/kazoo'
check_permissions "$FREESWITCH_IMAGE" \
  '/run/freeswitch /var/log/freeswitch /var/lib/freeswitch/db /var/lib/freeswitch/cache /var/lib/freeswitch/storage /var/lib/freeswitch/certs /etc/kazoo/freeswitch/vars /etc/kazoo/freeswitch/autoload_configs /etc/kazoo/freeswitch/sip_profiles /etc/kazoo/freeswitch/kazoo/connections' \
  '/entrypoint.sh /usr/local/freeswitch/bin /usr/local/freeswitch/lib'
check_permissions "$KAMAILIO_IMAGE" \
  '/run/kamailio /etc/kazoo/kamailio/local.cfg /etc/kazoo/kamailio/db /etc/kazoo/kamailio/certs' \
  '/entrypoint.sh /usr/sbin/kamailio /etc/kazoo/kamailio/db_scripts /etc/kazoo/kamailio/kamailio.cfg'
check_permissions "$MONSTER_UI_IMAGE" '/tmp' \
  '/usr/sbin/nginx /usr/share/nginx/html /etc/nginx/nginx.conf /etc/nginx/templates'

# These preflights need no broker or database and run without capabilities.
docker run "${FLAGS[@]}" --entrypoint /bin/sh "$REPRISE_IMAGE" -ec '
  for boot in /opt/kazoo/releases/*/start_clean.boot; do :; done
  /opt/kazoo/erts-*/bin/epmd -daemon
  /opt/kazoo/erts-*/bin/erl -boot "${boot%.boot}" \
    -boot_var ERTS_LIB_DIR /opt/kazoo/lib -noshell -sname hardening_check \
    -eval '\''io:format("Erlang distribution: ~p~n", [node()]), halt().'\''
'
docker run "${FLAGS[@]}" --entrypoint /usr/local/freeswitch/bin/freeswitch \
  "$FREESWITCH_IMAGE" -version
docker run "${FLAGS[@]}" -e MY_HOSTNAME=localhost -e MY_LOCAL_IP=127.0.0.1 \
  -e KAMAILIO_CHECK_CONFIG=1 "$KAMAILIO_IMAGE"
# the internal-listener layout deploy/compose uses (advertised address apart)
docker run "${FLAGS[@]}" -e MY_HOSTNAME=localhost -e MY_LOCAL_IP=127.0.0.1 \
  -e MY_PUBLIC_IP=192.0.2.10 -e MY_INTERNAL_IP=127.0.0.1 \
  -e KAMAILIO_CHECK_CONFIG=1 "$KAMAILIO_IMAGE"
docker run "${FLAGS[@]}" --read-only --tmpfs /tmp:rw,nosuid,nodev \
  -e CROSSBAR_UPSTREAM=http://127.0.0.1:8000 \
  -e BLACKHOLE_UPSTREAM=http://127.0.0.1:5555 "$MONSTER_UI_IMAGE" nginx -t

echo 'Container security preflights passed.'
