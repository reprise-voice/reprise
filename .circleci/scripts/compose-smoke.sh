#!/usr/bin/env bash
# The smoke job: the candidate images through deploy/compose, as a user would
# run them, then two registrations and a call.
#
#   compose-smoke.sh up          .env from init-env.sh, pull, start
#   compose-smoke.sh bootstrap   deploy/compose/bootstrap.sh
#   compose-smoke.sh sip         deploy/compose/smoke/smoke.sh
#   compose-smoke.sh security    docker/test-security.sh against the candidates
#   compose-smoke.sh logs <dir>  the services' logs and state, pass or fail
#
# REPRISE_TAG (default sha-<short>-amd64) picks the images.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$PWD
SHA=${CIRCLE_SHA1:-$(git rev-parse HEAD)}
# the namespace the image jobs pushed to (images.sh registry)
REGISTRY=$(.circleci/scripts/images.sh registry)
TAG=${REPRISE_TAG:-sha-${SHA:0:7}-amd64}

host_ip() {
  # the address the default route leaves from: what a phone on the LAN would use
  ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

cmd_up() {
  cd "$ROOT/deploy/compose"
  local ip
  ip=$(host_ip)
  [ -n "$ip" ] || { echo "could not work out this machine's address" >&2; exit 1; }
  # as a user would: HOST_IP and fresh credentials, nothing printed
  ./init-env.sh --force "$ip" >/dev/null
  sed -i -e "s|^REPRISE_TAG=.*|REPRISE_TAG=$TAG|" \
    -e "s|^REPRISE_REGISTRY=.*|REPRISE_REGISTRY=$REGISTRY|" .env
  echo "HOST_IP=$ip REPRISE_TAG=$TAG"
  docker compose config -q
  docker compose pull --quiet
  # no --wait: bootstrap.sh waits for what the cluster needs, and the
  # health of the rest is shown by `docker compose ps` afterwards
  docker compose up -d
}

cmd_bootstrap() {
  cd "$ROOT/deploy/compose"
  BOOTSTRAP_TIMEOUT=900 ./bootstrap.sh
  docker compose ps
}

cmd_sip() {
  cd "$ROOT/deploy/compose"
  SMOKE_LOG_DIR=${SMOKE_LOG_DIR:-/tmp/smoke-logs} ./smoke/smoke.sh
}

cmd_security() {
  REPRISE_IMAGE="$REGISTRY/reprise:$TAG" \
  FREESWITCH_IMAGE="$REGISTRY/reprise-freeswitch:$TAG" \
  KAMAILIO_IMAGE="$REGISTRY/reprise-kamailio:$TAG" \
  MONSTER_UI_IMAGE="$REGISTRY/reprise-monster-ui:$TAG" \
    bash docker/test-security.sh
}

cmd_logs() {
  local dir=${1:?directory}
  mkdir -p "$dir"
  cd "$ROOT/deploy/compose"
  [ -f .env ] || return 0
  docker compose ps -a >"$dir/ps.txt" 2>&1 || true
  local svc
  for svc in $(docker compose config --services 2>/dev/null); do
    docker compose logs --no-color --timestamps "$svc" >"$dir/$svc.log" 2>&1 || true
  done
  docker compose exec -T kamailio kamcmd dispatcher.list >"$dir/kamailio-dispatcher.txt" 2>&1 || true
  docker compose exec -T ecallmgr sup ecallmgr_maintenance list_fs_nodes >"$dir/ecallmgr-fs-nodes.txt" 2>&1 || true
  docker compose exec -T ecallmgr sup ecallmgr_maintenance sbc_acls true >"$dir/ecallmgr-sbc-acls.txt" 2>&1 || true
  docker compose exec -T kazoo-apps sup kapps_controller list_apps >"$dir/kazoo-apps-running.txt" 2>&1 || true
  docker compose exec -T freeswitch /usr/local/freeswitch/bin/fs_cli -x 'sofia status' >"$dir/freeswitch-sofia.txt" 2>&1 || true
  if [ -d /tmp/smoke-logs ]; then cp -r /tmp/smoke-logs "$dir/" || true; fi
  # the job output itself shows what is not well, so a failure can be read
  # without opening the artifacts
  echo "== docker compose ps -a"
  cat "$dir/ps.txt" || true
  local state health
  while read -r svc state health; do
    case "$state/$health" in
      running/healthy|running/) continue ;;
    esac
    echo "== $svc is $state ${health:-(no healthcheck)}: last 80 log lines"
    tail -n 80 "$dir/$svc.log" 2>/dev/null || true
  done < <(docker compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null || true)
}

case "${1:-}" in
  up) cmd_up ;;
  bootstrap) cmd_bootstrap ;;
  sip) cmd_sip ;;
  security) cmd_security ;;
  logs) shift; cmd_logs "$@" ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
