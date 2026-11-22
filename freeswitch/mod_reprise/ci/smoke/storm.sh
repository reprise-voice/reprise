#!/bin/bash
# Copyright (C) 2026 Vonix LLC
# SPDX-License-Identifier: MPL-2.0
# Event-storm / call-load check against a node running mod_reprise.
# Fires N concurrent loopback calls into the play callflow (15551230001:
# 2 s tone, then hangup — every call is answered, paced by
# execute-complete, and hung up by ecallmgr), then reports the module's
# stream/binding/fetch counters, ecallmgr crash reports and how many
# callflows completed.
#
#   ./storm.sh <fs_cli-runner> <N> [batches]
#   e.g. ./storm.sh "kubectl -n kazoo exec reprise-smoke -- /usr/local/freeswitch/bin/fs_cli -x" 50 2
#   e.g. ./storm.sh "ssh media-server-2 sudo docker exec freeswitch /usr/local/freeswitch/bin/fs_cli -x" 50
set -u
RUN=${1:?fs_cli runner}
N=${2:-20}
BATCHES=${3:-1}
ACCOUNT=946c4d65726167a7a3c581ce0f42e4f3
VARS="^^:ecallmgr_Realm=example.com:ecallmgr_Account-ID=$ACCOUNT:ecallmgr_Authorizing-Type=device:loopback_export=ecallmgr_Realm,ecallmgr_Account-ID,ecallmgr_Authorizing-Type:origination_caller_id_number=15559990000"

fs() { eval "$RUN \"\$1\"" 2>&1; }

echo "== before"; fs "reprise status" | grep -E "^fetch:|^  (priority|push-event) "
START=$(date +%s)
for b in $(seq 1 "$BATCHES"); do
  for i in $(seq 1 "$N"); do
    fs "bgapi originate {$VARS}loopback/15551230001/context_2 &park()" >/dev/null &
  done
  wait
  sleep 4
done
sleep 6
echo "== after ($(( $(date +%s) - START ))s, $((N*BATCHES)) calls)"
fs "reprise status" | sed -n '/^publisher/,/^workers/p' | grep -v "idle\|^workers"
fs "show channels" | tail -1
if command -v kubectl >/dev/null; then
  export KUBECONFIG=${KUBECONFIG:-$HOME/.config/gcloud-kazoo/kubeconfig}
  # kazoo-apps / ecallmgr are StatefulSets of two (2026-09-03): sum over pods
  echo "== ecallmgr crash reports (last 5 min)"
  kubectl -n kazoo logs -l app.kubernetes.io/name=ecallmgr -c kazoo --since=5m --max-log-requests=10 2>/dev/null | grep -ci "crash report\|exception" || true
  echo "== callflows completed normally (last 5 min)"
  kubectl -n kazoo logs -l app.kubernetes.io/name=kazoo-apps -c kazoo --since=5m --max-log-requests=10 2>/dev/null | grep -c "callflow execution has been stopped: normal" || true
fi
