#!/usr/bin/env bash
# First-run setup of the compose test cluster; safe to run again.
#
#   ./bootstrap.sh
#
# Runs on the Docker host, next to compose.yaml and .env. Every Kazoo command
# goes through `docker compose exec <node> sup ...`: sup reaches only the node
# in its own container (Erlang distribution is bound to loopback there).
#
#  1. waits until both Kazoo nodes run every application they are meant to
#  2. creates the master account and its admin user, unless an account exists
#  3. imports the en-us system prompts, unless they are there
#  4. registers the Monster UI apps with crossbar (copied out of the
#     monster-ui container)
#  5. waits until ecallmgr has adopted FreeSWITCH
#  6. allows Kamailio as the SBC in ecallmgr's ACLs and reloads them
#  7. prints where to log in and how to register two phones
#
# BOOTSTRAP_TIMEOUT (seconds, default 900) bounds each wait.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "no .env here: run ./init-env.sh first" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${HOST_IP:?set HOST_IP in .env}"
case "$HOST_IP" in
  127.*|localhost|0.0.0.0)
    echo "HOST_IP=$HOST_IP: use this machine's LAN address; phones cannot reach a loopback address" >&2
    exit 1 ;;
esac
ACCOUNT_NAME=${ACCOUNT_NAME:-reprise}
ACCOUNT_REALM=${ACCOUNT_REALM:-demo.reprise.test}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:?set ADMIN_PASSWORD in .env}
COUCHDB_USER=${COUCHDB_USER:-admin}
COUCHDB_PASSWORD=${COUCHDB_PASSWORD:?set COUCHDB_PASSWORD in .env}
REPRISE_SUBNET=${REPRISE_SUBNET:-172.30.10}
UI_PORT=${UI_PORT:-8080}
TIMEOUT=${BOOTSTRAP_TIMEOUT:-900}

dc() { docker compose "$@"; }
# -T: no TTY, so this also runs from CI and from pipes
sup_apps() { dc exec -T kazoo-apps sup "$@"; }
sup_ecm() { dc exec -T ecallmgr sup "$@"; }
step() { printf '\n== %s\n' "$*"; }

# wait_for <what> <command...>: run the command every 5 s until it succeeds
wait_for() {
  local what=$1; shift
  local deadline=$((SECONDS + TIMEOUT))
  printf 'waiting for %s ' "$what"
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf '\ntimed out after %ss waiting for %s\n' "$TIMEOUT" "$what" >&2
      return 1
    fi
    printf '.'
    sleep 5
  done
  printf ' ok\n'
}

node_ready() { dc exec -T "$1" sup kapps_controller ready 2>/dev/null | grep -qx true; }
fs_adopted() { sup_ecm ecallmgr_maintenance list_fs_nodes 2>/dev/null | grep -q '^freeswitch@'; }

for svc in couchdb broker kazoo-apps ecallmgr freeswitch kamailio monster-ui; do
  if [ -z "$(dc ps -q "$svc" 2>/dev/null)" ]; then
    echo "service $svc is not running: docker compose up -d first" >&2
    exit 1
  fi
done

step "Kazoo nodes"
for node in kazoo-apps ecallmgr; do
  if ! wait_for "$node" node_ready "$node"; then
    echo "configured:  $(dc exec -T "$node" sup kapps_controller start_which_kapps 2>&1 || true)" >&2
    echo "running:     $(dc exec -T "$node" sup kapps_controller list_apps 2>&1 || true)" >&2
    echo "see: docker compose logs $node" >&2
    exit 1
  fi
done

step "master account"
master=$(sup_apps kapps_util get_master_account_id 2>&1 || true)
if printf '%s' "$master" | grep -q '^{ok,'; then
  echo "an account already exists (master: $master); not creating one"
  CREATED=no
else
  echo "creating account '$ACCOUNT_NAME' (realm $ACCOUNT_REALM) with admin user '$ADMIN_USER'"
  sup_apps crossbar_maintenance create_account \
    "$ACCOUNT_NAME" "$ACCOUNT_REALM" "$ADMIN_USER" "$ADMIN_PASSWORD"
  CREATED=yes
fi

step "system prompts"
# prompt documents are named <lang>/<prompt> in system_media
prompts=$(dc exec -T couchdb curl -fsS -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
  'http://127.0.0.1:5984/system_media/_all_docs?start_key=%22en-us%2F%22&end_key=%22en-us0%22&limit=1' \
  2>/dev/null || true)
if printf '%s' "$prompts" | grep -q '"id":"en-us/'; then
  echo "en-us prompts already imported"
else
  sup_apps kazoo_media_maintenance import_prompts /opt/kazoo/sounds/en/us en-us
fi

step "Monster UI apps"
# The app metadata ships in the monster-ui image; crossbar reads it from a
# directory on the kazoo-apps node. Copy it across through the host each
# time, so an upgraded UI image brings its apps along. Without an API URL,
# init_apps leaves the apps on the UI's own origin (/v2 behind nginx).
# (A fresh directory each run: the node's user cannot remove what docker cp
# wrote. It goes with the container.)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
apps_dir=/tmp/monster-apps-$(date +%Y%m%d%H%M%S)
dc cp monster-ui:/opt/monster-apps "$tmp/monster-apps"
dc cp "$tmp/monster-apps" "kazoo-apps:$apps_dir"
sup_apps crossbar_maintenance init_apps "$apps_dir"

step "FreeSWITCH"
if ! wait_for "ecallmgr to adopt FreeSWITCH" fs_adopted; then
  echo "see: docker compose logs freeswitch ecallmgr" >&2
  exit 1
fi
sup_ecm ecallmgr_maintenance list_fs_nodes

step "Kamailio as the SBC"
# The address FreeSWITCH sees Kamailio's traffic come from: its own address on
# the bridge network, or the host's when it runs on the host network.
mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$(dc ps -q kamailio)")
if [ "$mode" = host ]; then
  SBC_IP=${SBC_IP:-$HOST_IP}
else
  SBC_IP=${SBC_IP:-$REPRISE_SUBNET.31}
fi
# "true": in the default ecallmgr config, so it holds for any ecallmgr node
sup_ecm ecallmgr_maintenance allow_sbc kamailio "$SBC_IP" true
sup_ecm ecallmgr_maintenance reload_acls

UI="http://$HOST_IP:$UI_PORT"
cat <<EOF

== Done

Monster UI:  $UI
EOF
if [ "$CREATED" = yes ]; then
  cat <<EOF
  account name  $ACCOUNT_NAME
  user name     $ADMIN_USER
  password      ADMIN_PASSWORD in $PWD/.env
EOF
else
  cat <<EOF
  log in with the account you created earlier (from .env: account name
  $ACCOUNT_NAME, user $ADMIN_USER, unless you changed them since)
EOF
fi
cat <<EOF

Two softphones, on machines other than this one (a phone here that sends
from $HOST_IP registers, but its calls are refused):
  1. In Monster UI, App Store: install SmartPBX (or Callflows).
  2. SmartPBX > Users: add two users with extensions (e.g. 1001 and 1002);
     each gets a softphone device. Note each device's SIP user name and
     password (SmartPBX > Devices > the device > SIP settings).
  3. Configure each softphone with
       SIP server / registrar / proxy  $HOST_IP:5060 (UDP)
       domain / realm                  $ACCOUNT_REALM
       user name / password            the device's SIP credentials
  4. Call one extension from the other.
EOF
