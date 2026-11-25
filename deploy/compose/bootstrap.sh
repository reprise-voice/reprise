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
#  2. creates the master account and its admin user, unless an account exists;
#     when one does, runs the database migration instead, for a cluster that
#     has come back up on newer images
#  3. has FreeSWITCH fetch media through the media proxy, not from CouchDB
#  4. on a new cluster, keeps call recordings (store_recordings); on one
#     created by earlier images, starts konami and the recordings API
#  5. imports the system prompts of PROMPT_LANGUAGES (en-us unless set),
#     unless all of them are there
#  6. registers the Monster UI apps with crossbar (copied out of the
#     monster-ui container)
#  7. waits until ecallmgr has adopted FreeSWITCH
#  8. allows Kamailio as the SBC in ecallmgr's ACLs and reloads them
#  9. prints where to log in and how to register two phones
#
# BOOTSTRAP_TIMEOUT (seconds, default 900) bounds each wait.
# PROMPT_LANGUAGES, here or in .env: en-us,fr-ca or `all`.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "no .env here: run ./init-env.sh first" >&2
  exit 1
fi
# .env sets PROMPT_LANGUAGES too; one given on the command line wins, so
# `PROMPT_LANGUAGES=all ./bootstrap.sh` imports more without editing .env
languages_given=${PROMPT_LANGUAGES:-}
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
PROMPT_LANGUAGES=${languages_given:-${PROMPT_LANGUAGES:-en-us}}
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
# shipped_languages: the languages the image has prompts for, one per line.
# It ships them as /opt/kazoo/sounds/<lang>/<region>, and the language they
# are imported under is <lang>-<region>.
shipped_languages() {
  # shellcheck disable=SC2016  # expanded by the shell in the container
  dc exec -T kazoo-apps sh -c \
    'cd /opt/kazoo/sounds && for d in */*/; do echo "${d%/}"; done' | tr '/' '-'
}
# prompts_shipped <dir>: how many prompts the image has in <dir>, one per
# name (import_prompts takes *.wav and *.mp3, and a prompt's document is
# named after the file without its extension)
prompts_shipped() {
  # shellcheck disable=SC2016  # expanded by the shell in the container
  dc exec -T kazoo-apps sh -c \
    'cd "$1" && for f in *.wav *.mp3; do [ -e "$f" ] && echo "${f%.*}"; done | sort -u | wc -l' \
    sh "$1" | tr -d ' \r'
}
# prompts_stored <language>: how many prompt documents system_media holds for
# it; they are named <language>/<prompt> ("0" is the character after "/")
prompts_stored() {
  dc exec -T couchdb curl -fsS -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
    "http://127.0.0.1:5984/system_media/_all_docs?start_key=%22$1%2F%22&end_key=%22${1}0%22" \
    2>/dev/null | { grep -o "\"id\":\"$1/" || true; } | wc -l | tr -d ' '
}

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
  # This is a re-run, perhaps on newer images than the ones that created the
  # databases: bring the databases and their views up to this release. A
  # node only does that for the system databases when it starts.
  step "database migration"
  sup_apps kapps_maintenance migrate
else
  echo "creating account '$ACCOUNT_NAME' (realm $ACCOUNT_REALM) with admin user '$ADMIN_USER'"
  sup_apps crossbar_maintenance create_account \
    "$ACCOUNT_NAME" "$ACCOUNT_REALM" "$ADMIN_USER" "$ADMIN_PASSWORD"
  CREATED=yes
fi

step "media through the media proxy"
# By default Kazoo hands FreeSWITCH the CouchDB URL of a prompt or of other
# stored media, with the CouchDB password in it, and FreeSWITCH has to reach
# CouchDB by the name the Kazoo nodes use. With this off, the URL is one on
# the media proxy (media_mgr on kazoo-apps, port 24517), which is all
# FreeSWITCH needs to reach, on either network layout. The setting is read
# on every request, so nothing restarts.
sup_apps kapps_config set_boolean kazoo_couch use_bigcouch_direct false

step "call recordings and transfers"
# A setting Kazoo has read is written back with its default, so a stored
# value cannot tell an operator's choice from one nobody made. These are set
# once, on the run that creates the cluster, or brought along on the run
# after an upgrade, and left alone after that.
if [ "$CREATED" = yes ]; then
  # With no storage plan, Kazoo keeps a call recording only when this is
  # true (it is false by default) and otherwise drops it; here they go to
  # the account's database.
  sup_apps kapps_config set_boolean media store_recordings true
else
  # Defaults a cluster created on earlier images does not have: konami
  # (in-call feature codes and attended transfers) and the recordings API.
  # Both commands add to the stored lists only what is missing from them.
  sup_apps kazoo_apps_maintenance start konami
  sup_apps crossbar_maintenance start_module cb_recordings
fi

step "system prompts"
if [ "$PROMPT_LANGUAGES" = all ]; then
  languages=$(shipped_languages)
else
  languages=$(printf '%s' "$PROMPT_LANGUAGES" | tr ',' ' ')
fi
for language in $languages; do
  # <lang>-<region>, lower case: it becomes a path and part of a URL
  case "$language" in
    *[!a-z-]*|-*|*-|*-*-*) valid=no ;;
    *-*) valid=yes ;;
    *) valid=no ;;
  esac
  if [ "$valid" = no ]; then
    echo "PROMPT_LANGUAGES: '$language' is not a language like en-us" >&2
    exit 1
  fi
  dir=/opt/kazoo/sounds/${language%-*}/${language#*-}
  if ! dc exec -T kazoo-apps test -d "$dir"; then
    echo "the image has no $language prompts; it has: $(shipped_languages | tr '\n' ' ')" >&2
    exit 1
  fi
  # Every prompt, not just one: an import cut short leaves some behind, and
  # importing again overwrites the ones already there.
  shipped=$(prompts_shipped "$dir")
  stored=$(prompts_stored "$language")
  if [ "$stored" -ge "$shipped" ]; then
    echo "$language prompts already imported ($stored)"
  else
    echo "$language: $stored of $shipped prompts imported; importing"
    sup_apps kazoo_media_maintenance import_prompts "$dir" "$language"
  fi
done

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
