#!/bin/sh
# Upgrade a connected A2DP sink to the best codec it supports: LDAC > aptX > SBC.
# WHY: bluez, acting as the A2DP initiator, always configures the sink's FIRST stream
# endpoint (SBC is mandatory and listed first), so a fresh connect lands on SBC even when
# the sink supports LDAC/aptX. bluealsa-cli can reconfigure the transport at runtime, so we
# just try each codec in priority order and keep the first that takes (a failed switch errors
# out without reconfiguring, so no audio disruption). HW-verified: WF-1000XM5 -> LDAC.
# NB: the sink must actually advertise the codec's SEP. For the WF-1000XM5, LDAC only appears
# when "Priority on Sound Quality" is set in the Sony Headphones Connect app.
# Usage: bt_best_codec.sh [MAC]   (MAC optional; defaults to the first a2dp-source PCM)
MAC="$1"
P=$(bluealsa-cli list-pcms 2>/dev/null | grep a2dpsrc | grep -i "$MAC" | head -1)
[ -z "$P" ] && P=$(bluealsa-cli list-pcms 2>/dev/null | grep a2dpsrc | head -1)
[ -z "$P" ] && { echo "bt_best_codec: no a2dp-source PCM (sink connected?)"; exit 1; }
for c in LDAC aptX SBC; do
  if bluealsa-cli codec "$P" "$c" </dev/null >/dev/null 2>&1; then
    echo "bt_best_codec: $P -> $c"
    exit 0
  fi
done
echo "bt_best_codec: no codec could be selected on $P"
exit 1
