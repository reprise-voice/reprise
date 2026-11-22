#!/bin/bash
# Copyright (C) 2026 Vonix LLC
# SPDX-License-Identifier: MPL-2.0
# Sustained-rate call soak on a media server VM (fs-1 / fs-2). Runs ON the
# VM (copy it there; `gcloud compute ssh` per call is far too slow):
#   nohup bash soak.sh <duration-s> <calls-per-burst> <burst-interval-s> <log> &
# Fires <calls-per-burst> loopback calls into the play callflow every
# <burst-interval-s> for <duration-s>, snapshotting the module's counters,
# the channel count and the container's CPU/memory every 5 minutes.
# Compare with the node-protocol node the same way (its `reprise status`
# lines are simply absent); ecallmgr crash reports and callflow completions
# come from the kazoo pods' logs over the same window (see README).
set -u
DUR=${1:-1800}
N=${2:-2}
INT=${3:-2}
LOG=${4:-/tmp/soak.log}
FS="sudo docker exec freeswitch /usr/local/freeswitch/bin/fs_cli -x"
ACCOUNT=946c4d65726167a7a3c581ce0f42e4f3
VARS="^^:ecallmgr_Realm=example.com:ecallmgr_Account-ID=$ACCOUNT:ecallmgr_Authorizing-Type=device:loopback_export=ecallmgr_Realm,ecallmgr_Account-ID,ecallmgr_Authorizing-Type:origination_caller_id_number=15559990000"

snap() {
  {
    echo "== $(date -u +%FT%TZ) $1"
    $FS "reprise status" 2>/dev/null | grep -E "^fetch:|^publisher|^reconnects|^  (priority|push-event) |^  (commands|fetch|nodes) "
    $FS "show calls count" | tail -1
    $FS "status" | grep -E "session|Uptime" | head -4
    sudo docker stats --no-stream --format "container cpu={{.CPUPerc}} mem={{.MemUsage}}" freeswitch
  } >> "$LOG" 2>&1
}

snap "start dur=${DUR}s burst=$N every=${INT}s"
START=$(date +%s)
CALLS=0
BURSTS=0
SNAP_EVERY=$(( 300 / INT ))
[ "$SNAP_EVERY" -lt 1 ] && SNAP_EVERY=1
while [ $(( $(date +%s) - START )) -lt "$DUR" ]; do
  for i in $(seq 1 "$N"); do
    $FS "bgapi originate {$VARS}loopback/15551230001/context_2 &park()" >/dev/null 2>&1 &
  done
  wait
  CALLS=$((CALLS + N))
  BURSTS=$((BURSTS + 1))
  if [ $(( BURSTS % SNAP_EVERY )) -eq 0 ]; then snap "calls=$CALLS"; fi
  sleep "$INT"
done
sleep 10
snap "done calls=$CALLS elapsed=$(( $(date +%s) - START ))s"
