#!/bin/sh
# Pair + connect an A2DP sink, then report the resulting bond's address type.
# Usage: bt_pair.sh [NAME_SUBSTRING]   (default: MEGABOOM)
# A2DP requires a BR/EDR (public, "type 0") bond. If main.conf's ControllerMode=bredr
# is in effect, the sink is discovered+bonded as public; a type-1 (LE/random) bond is
# the failure we are hunting.
LDR=""
CTL="$LDR /usr/bin/bluetoothctl"
WANT="${1:-MEGABOOM}"
SCAN_SECS="${2:-15}"

# fifo-driven persistent bluetoothctl session: keep stdin open so the agent stays
# registered for the whole pair (piping closes stdin and tears the agent down).
FIFO=/tmp/btpair.fifo
rm -f "$FIFO"; mkfifo "$FIFO"
$CTL >/tmp/btpair.out 2>&1 <"$FIFO" &
CTL_PID=$!
exec 3>"$FIFO"          # hold the write end open

send(){ printf '%s\n' "$1" >&3; sleep "${2:-1}"; }

send "agent NoInputNoOutput" 2
send "default-agent" 1
send "pairable on" 1
send "scan on" "$SCAN_SECS"

# find the sink's MAC from the live device list
MAC=$($CTL devices 2>/dev/null | grep -i "$WANT" | head -1 | awk '{print $2}')
if [ -z "$MAC" ]; then
  echo "bt_pair: '$WANT' not found in scan. Devices seen:"
  $CTL devices 2>/dev/null
  send "scan off" 1; exec 3>&-; kill $CTL_PID 2>/dev/null; exit 1
fi
echo "bt_pair: found $WANT -> $MAC"

send "scan off" 1
send "pair $MAC" 6
send "trust $MAC" 2
send "connect $MAC" 6

exec 3>&-            # close write end -> bluetoothctl exits
sleep 1; kill $CTL_PID 2>/dev/null

# bluez connects on SBC; upgrade to the best codec the sink supports (LDAC/aptX).
sleep 2; /usr/bin/bt_best_codec.sh "$MAC"

echo "=== pair session log (tail) ==="
tail -25 /tmp/btpair.out
echo "=== info $MAC (Paired/Connected/address type) ==="
$CTL info "$MAC" 2>&1 | grep -iE "Name|Paired|Trusted|Connected|UUID: Audio|RSSI"
echo "=== bond on disk (address type lives in the info file) ==="
ADAP=$(ls /var/lib/bluetooth 2>/dev/null | head -1)
echo "adapter dir: $ADAP"
ls -la /var/lib/bluetooth/$ADAP/ 2>/dev/null | grep -iE "$(echo $MAC | tr a-z A-Z)|:"
echo "=== kernel: any 'Invalid link address type' since boot? ==="
dmesg | grep -i "invalid link address" | tail -3 || echo "(none)"
