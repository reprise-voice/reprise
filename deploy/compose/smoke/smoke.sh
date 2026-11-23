#!/usr/bin/env bash
# End-to-end check of a bootstrapped compose cluster: two devices register
# through Kamailio and one calls the other.
#
#   ./smoke/smoke.sh                 (after docker compose up -d and ./bootstrap.sh)
#   ./smoke/smoke.sh --devices-only  only create the devices and print their
#                                    credentials, for two real softphones
#
# Needs curl, jq and sipp (Debian/Ubuntu: apt-get install sip-tester) on this
# machine. Through the crossbar API (Monster UI's /v2), as the admin user
# from .env, it creates -- or reuses -- two devices, smoke1 and smoke2, and
# callflows 1001 and 1002 that ring them. Then:
#   1. smoke2 registers from port 5092, and a UAS takes over that port
#   2. smoke1 registers from port 5091
#   3. smoke1 calls 1002, talks 3 s, hangs up
# sipp's logs go to SMOKE_LOG_DIR (default ./smoke-logs). Exit status 0 means
# both registrations and the call succeeded. SMOKE_SIP_PASSWORD fixes the
# devices' SIP password (default: a new random one each run). It is printed
# only by --devices-only, where it is what the softphones need.
#
# The two phones talk to HOST_IP:5060 but must not send *from* HOST_IP:
# Kamailio advertises that address as its own and trusts a request from
# itself, so it would pass the call on without the device's token and
# FreeSWITCH would answer 403. They send from SMOKE_CLIENT_IP, by default
# another address of this machine: the compose network's gateway.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${HOST_IP:?set HOST_IP in .env}"
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD in .env}"
ACCOUNT_NAME=${ACCOUNT_NAME:-reprise}
ACCOUNT_REALM=${ACCOUNT_REALM:-demo.reprise.test}
ADMIN_USER=${ADMIN_USER:-admin}
UI_PORT=${UI_PORT:-8080}
API="http://$HOST_IP:$UI_PORT/v2"
SIP_PASSWORD=${SMOKE_SIP_PASSWORD:-$(head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20)}
LOG_DIR=${SMOKE_LOG_DIR:-$PWD/smoke-logs}
SCENARIOS=$PWD/smoke
TIMEOUT=${SMOKE_TIMEOUT:-300}
KAMAILIO_IP="${REPRISE_SUBNET:-172.30.10}.31"

DEVICES_ONLY=no
[ "${1:-}" = --devices-only ] && DEVICES_ONLY=yes
TOOLS="curl jq"
[ "$DEVICES_ONLY" = yes ] || TOOLS="$TOOLS sipp"
for tool in $TOOLS; do
  command -v "$tool" >/dev/null || { echo "$tool is needed on this machine" >&2; exit 1; }
done
mkdir -p "$LOG_DIR"

# client_ip: an IPv4 address of this machine other than HOST_IP, or nothing.
# First choice is the one this machine uses towards the Kamailio container,
# the compose network's gateway; with host networking there is no such
# network, and any other address will do.
client_ip() {
  command -v ip >/dev/null || return 0
  local addr
  addr=$(ip -4 route get "$KAMAILIO_IP" 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
  if [ -n "$addr" ] && [ "$addr" != "$HOST_IP" ]; then
    printf '%s' "$addr"
    return 0
  fi
  ip -4 -o addr show scope global 2>/dev/null \
    | awk -v host="$HOST_IP" '{ split($4, a, "/"); if (a[1] != host) { print a[1]; exit } }'
}

md5() {
  if command -v md5sum >/dev/null; then printf '%s' "$1" | md5sum | cut -d' ' -f1
  else printf '%s' "$1" | md5 -q
  fi
}

# api <method> <path> [json body]: prints the response body, fails on >= 400
api() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -X "$method" -H 'Content-Type: application/json')
  [ -n "${TOKEN:-}" ] && args+=(-H "X-Auth-Token: $TOKEN")
  [ -n "$body" ] && args+=(--data "$body")
  local out code
  out=$(curl "${args[@]}" -w '\n%{http_code}' "$API$path")
  code=${out##*$'\n'}
  out=${out%$'\n'*}
  if [ "$code" -ge 400 ] 2>/dev/null || [ "$code" = 000 ]; then
    echo "$method $path -> HTTP $code: $out" >&2
    return 1
  fi
  printf '%s' "$out"
}

echo "== crossbar at $API"
deadline=$((SECONDS + TIMEOUT))
until auth=$(api PUT /user_auth "$(jq -nc --arg c "$(md5 "$ADMIN_USER:$ADMIN_PASSWORD")" \
    --arg a "$ACCOUNT_NAME" '{data: {credentials: $c, account_name: $a}}')" 2>/dev/null); do
  [ "$SECONDS" -lt "$deadline" ] || { echo "could not log in to $API as $ADMIN_USER@$ACCOUNT_NAME" >&2; exit 1; }
  sleep 5
done
TOKEN=$(jq -r .auth_token <<<"$auth")
ACCOUNT_ID=$(jq -r .data.account_id <<<"$auth")
echo "logged in, account $ACCOUNT_ID"

# ensure_device <name>: prints the device id; (re)sets its SIP password
ensure_device() {
  local name=$1 id
  id=$(api GET "/accounts/$ACCOUNT_ID/devices" | jq -r --arg n "$name" '.data[] | select(.name == $n) | .id' | head -n1)
  if [ -n "$id" ]; then
    api PATCH "/accounts/$ACCOUNT_ID/devices/$id" \
      "$(jq -nc --arg p "$SIP_PASSWORD" '{data: {sip: {password: $p}}}')" >/dev/null
  else
    id=$(api PUT "/accounts/$ACCOUNT_ID/devices" \
      "$(jq -nc --arg n "$name" --arg p "$SIP_PASSWORD" \
        '{data: {name: $n, device_type: "softphone", enabled: true, sip: {username: $n, password: $p}}}')" \
      | jq -r .data.id)
  fi
  printf '%s' "$id"
}

# ensure_callflow <number> <device id>: one callflow ringing the device
ensure_callflow() {
  local number=$1 device=$2 id
  for id in $(api GET "/accounts/$ACCOUNT_ID/callflows" \
      | jq -r --arg n "$number" '.data[] | select((.numbers // []) | index($n)) | .id'); do
    api DELETE "/accounts/$ACCOUNT_ID/callflows/$id" >/dev/null
  done
  api PUT "/accounts/$ACCOUNT_ID/callflows" \
    "$(jq -nc --arg n "$number" --arg d "$device" \
      '{data: {numbers: [$n], flow: {module: "device", data: {id: $d}, children: {}}}}')" >/dev/null
}

echo "== devices and callflows"
D1=$(ensure_device smoke1)
D2=$(ensure_device smoke2)
ensure_callflow 1001 "$D1"
ensure_callflow 1002 "$D2"
echo "smoke1 ($D1) on 1001, smoke2 ($D2) on 1002"
if [ "$DEVICES_ONLY" = yes ]; then
  cat <<EOF

Two softphones, one per device:
  SIP server / proxy  $HOST_IP:5060 (UDP)
  domain / realm      $ACCOUNT_REALM
  user / password     smoke1 / $SIP_PASSWORD   (extension 1001)
                      smoke2 / $SIP_PASSWORD   (extension 1002)
Dial 1002 from smoke1, or 1001 from smoke2. Run the softphones on other
machines: one on this machine that sends from $HOST_IP registers, but its
calls are refused (403), because that is the address Kamailio calls its own.
EOF
  exit 0
fi

# A media server ecallmgr reports is added to the dispatcher inactive, and
# becomes active once it answers Kamailio's OPTIONS probe (every 10 s). Calls
# are routed to set 1, the address FreeSWITCH advertises for signalling; set
# 3 holds its local address and only classifies traffic. Until set 1 has an
# active entry an INVITE is answered "480 All servers busy", so wait for
# that: FLAGS reads AP or AX when active, IP while inactive and probed.
echo "== Kamailio's dispatcher has an active media server to route to"
ds_list() { docker compose exec -T kamailio kamcmd dispatcher.list 2>&1; }
ds_routable() {
  ds_list | awk '/^[[:space:]]*ID:/ { set = $2 } /FLAGS: A/ && set == 1 { ok = 1 } END { exit !ok }'
}
deadline=$((SECONDS + TIMEOUT))
until ds_routable; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "no active media server in set 1 of Kamailio's dispatcher list after ${TIMEOUT}s:" >&2
    ds_list >&2 || true
    echo "-- kamailio, last lines:" >&2
    docker compose logs --no-color --tail 30 kamailio >&2 || true
    exit 1
  fi
  sleep 3
done
ds_list | grep -E 'URI:|FLAGS:' | sed 's/^[[:space:]]*/   /'

CLIENT_IP=${SMOKE_CLIENT_IP:-$(client_ip)}
if [ -z "$CLIENT_IP" ]; then
  CLIENT_IP=$HOST_IP
  echo "note: found no address of this machine other than $HOST_IP for the test phones;" >&2
  echo "      if the call is refused with 403, set SMOKE_CLIENT_IP to one" >&2
fi

printf 'SEQUENTIAL\nsmoke1;%s;1002\n' "$ACCOUNT_REALM" >"$LOG_DIR/smoke1.csv"
printf 'SEQUENTIAL\nsmoke2;%s;1001\n' "$ACCOUNT_REALM" >"$LOG_DIR/smoke2.csv"

# run_sipp <name> <scenario> <port> <media port> [sipp args...]
run_sipp() {
  local name=$1 scenario=$2 port=$3 mport=$4; shift 4
  sipp -sf "$SCENARIOS/$scenario" -i "$CLIENT_IP" -p "$port" -nostdin \
    -min_rtp_port "$mport" -max_rtp_port $((mport + 9)) \
    -timeout 60s -timeout_error \
    -trace_err -error_file "$LOG_DIR/$name.errors.log" \
    -trace_msg -message_file "$LOG_DIR/$name.messages.log" \
    "$@" </dev/null >"$LOG_DIR/$name.out" 2>&1
}

register() {
  local user=$1 port=$2
  echo "-- REGISTER $user from $CLIENT_IP:$port"
  # Kamailio may still be learning the device: retry a few times
  local n
  for n in 1 2 3 4 5 6; do
    if run_sipp "register-$user" register.xml "$port" $((6000 + port % 100 * 10)) -m 1 \
        -inf "$LOG_DIR/$user.csv" -au "$user" -ap "$SIP_PASSWORD" "$HOST_IP:5060"; then
      echo "   registered"
      return 0
    fi
    echo "   attempt $n failed; see $LOG_DIR/register-$user.*" >&2
    sleep 5
  done
  return 1
}

echo "== SIP: phones at $CLIENT_IP, Kamailio at $HOST_IP:5060"
register smoke2 5092
# (no -m 1: uas.xml stops sipp itself after the call, see there)
run_sipp uas-smoke2 uas.xml 5092 6200 &
UAS=$!
sleep 1
register smoke1 5091

echo "-- smoke1 calls 1002"
call=0
run_sipp call-smoke1 caller.xml 5091 6100 -m 1 \
  -inf "$LOG_DIR/smoke1.csv" -au smoke1 -ap "$SIP_PASSWORD" "$HOST_IP:5060" || call=$?
uas=0
wait "$UAS" || uas=$?

if [ "$call" -eq 0 ] && [ "$uas" -eq 0 ]; then
  echo "== smoke test passed: two registrations and a call from 1001 to 1002"
  exit 0
fi
echo "== smoke test FAILED (caller sipp exit $call, callee sipp exit $uas); logs in $LOG_DIR" >&2
# enough to see why without opening the logs: what the caller was told, the
# dispatcher's view, and what Kamailio and FreeSWITCH said last
grep -h -m 3 -E '^SIP/2.0 [3-6]' "$LOG_DIR/call-smoke1.messages.log" 2>/dev/null | sort -u | sed 's/^/   caller received: /' >&2 || true
grep -h -E '^(INVITE|NOTIFY|OPTIONS|ACK|BYE) ' "$LOG_DIR/uas-smoke2.messages.log" 2>/dev/null | cut -d' ' -f1 | sort | uniq -c \
  | sed 's/^ */   callee received: /' >&2 || true
if [ "$CLIENT_IP" = "$HOST_IP" ]; then
  echo "   the phones sent from $HOST_IP, Kamailio's own address: a 403 here means" >&2
  echo "   SMOKE_CLIENT_IP has to name another address of this machine" >&2
fi
echo "-- dispatcher:" >&2
ds_list 2>&1 | grep -E 'ID:|URI:|FLAGS:' >&2 || true
echo "-- kamailio, last lines:" >&2
docker compose logs --no-color --tail 40 kamailio >&2 || true
echo "-- freeswitch, last lines:" >&2
docker compose logs --no-color --tail 40 freeswitch >&2 || true
exit 1
