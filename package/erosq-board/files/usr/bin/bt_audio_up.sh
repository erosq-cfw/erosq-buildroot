#!/bin/sh
# Bring up the A2DP-source userspace stack: dbus -> bluetoothd -> bluealsa.
# Run AFTER bt_up.sh (which creates hci0). Launched/backgrounded from rcS.
LDR=""

# Serialize with bt_down.sh (see bt_up.sh): without this, a fast off->on let the
# `pidof bluetoothd`/`pidof bluealsa` guards below see a still-dying daemon,
# skip the restart, and leave BT wedged off. Holding the mutex means bt_down.sh
# has fully completed (daemons dead, chip cold) before we probe, so the guards
# are accurate. mkdir = atomic mutex; on wait-timeout FAIL rather than proceed
# (see bt_up.sh). LOCKED gates the trap so we only remove a lock we created.
BT_LOCK=/run/bt-power.lock
LOCKED=0
trap '[ $LOCKED -eq 1 ] && rmdir "$BT_LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM
n=0
while ! mkdir "$BT_LOCK" 2>/dev/null; do
	sleep 1; n=$((n+1))
	[ $n -ge 30 ] && { echo "bt_audio: timed out waiting for $BT_LOCK"; exit 1; }
done
LOCKED=1

# Last-intent guard (see bt_up.sh): a newer BT-off supersedes this bring-up.
[ "$(cat /run/bt-want 2>/dev/null)" = 0 ] && { echo "bt_audio: superseded by BT-off"; exit 0; }

# 1. system D-Bus
[ -f /etc/machine-id ] || $LDR /usr/bin/dbus-uuidgen > /etc/machine-id 2>/dev/null
# /tmp/bluealsa is the REAL path -- /var/lib/bluealsa is a symlink to it (post-build.sh),
# and `mkdir -p` on a dangling symlink fails with EEXIST instead of creating the target
# (verified), so create the target directly. Without it bluealsa can't write its
# per-device storage and logs an error on every device teardown.
mkdir -p /run/dbus /var/lib/bluetooth /tmp/bluealsa
if [ ! -S /run/dbus/system_bus_socket ]; then
  $LDR /usr/bin/dbus-daemon --config-file=/usr/share/dbus-1/system.conf --nofork >/var/log/dbus.log 2>&1 &
  i=0; while [ $i -lt 10 ] && [ ! -S /run/dbus/system_bus_socket ]; do sleep 1; i=$((i+1)); done
fi
[ -S /run/dbus/system_bus_socket ] || { echo "bt_audio: no dbus socket"; exit 1; }

# 2. wait for hci0 (bt_up.sh creates it; up to 30s)
i=0; while [ $i -lt 30 ] && [ ! -d /sys/class/bluetooth/hci0 ]; do sleep 1; i=$((i+1)); done
[ -d /sys/class/bluetooth/hci0 ] || { echo "bt_audio: no hci0"; exit 1; }

# 3. bluetoothd (attaches to hci0; owns org.bluez). Wait until its Media1 interface is
#    actually ready, else bluealsa's RegisterApplication times out. Power the adapter on
#    explicitly (AutoEnable=false) so the media app + endpoints register.
# Buildroot installs bluetoothd at /usr/libexec/bluetooth (NOT /usr/bin). main.conf's
# ControllerMode=bredr forces BR/EDR-only (A2DP); without it the A2DP sink bonds as
# LE/random -> "Invalid link address type 1" -> auth 0x05. -f is explicit (Buildroot's
# bluetoothd already reads /etc/bluetooth/main.conf, but the flag is harmless + clear).
# Idempotent: this script re-runs on every UI "Bluetooth on" toggle. BT-off runs
# bt_down.sh, which kills bluetoothd + bluealsa and colds the chip, so after an
# Off->On bluetoothd is normally absent and gets started here. It can still be
# running (a second On, or a boot-time bring-up racing the UI); spawning a second
# bluetoothd just races org.bluez and burns CPU -- only start it if absent.
if ! pidof bluetoothd >/dev/null 2>&1; then
	# --noplugin: LE-Audio (bap/bass/mcp/vcp/micp/ccp/csip/tmap/gmap/asha/rap), the
	# bluez-native HFP and PAN (network; kernel has no BNEP anyway) are never used
	# here -- A2DP comes from bluealsa, HID/HoG pads need input+hog+scanparam+
	# deviceinfo+battery, which stay. Measured 2026-10-03: -40..44 kB anon in
	# bluetoothd, adapter UUIDs 13 -> 6 (GAP/GATT/DI/AVRCP x2/DIS) + bluealsa's A2DP.
	$LDR /usr/libexec/bluetooth/bluetoothd -f /etc/bluetooth/main.conf --nodetach \
		--noplugin=network,rap,bap,bass,mcp,vcp,micp,ccp,csip,tmap,gmap,asha,hfp \
		>/var/log/bluetoothd.log 2>&1 &
	# wait for bluetoothd to own org.bluez + expose the adapter (poll bluetoothctl show)
	i=0; while [ $i -lt 15 ] && ! $LDR /usr/bin/bluetoothctl show 2>/dev/null | grep -q "Powered:"; do sleep 1; i=$((i+1)); done
	# i only reaches 15 when every poll failed -- report it instead of exit-0 lying
	[ $i -lt 15 ] || { echo "bt_audio: bluetoothd not ready (see /var/log/bluetoothd.log)"; exit 1; }
fi
$LDR /usr/bin/bluetoothctl power on >/dev/null 2>&1   # cheap + idempotent: always ensure adapter powered
sleep 2

# 4. bluealsa: A2DP source, SBC + aptX + LDAC (owns org.bluealsa). Forced 44.1kHz so MPD
#    doesn't resample (CPU) and LDAC runs at 44.1 (lightest). --ldac-quality=high = 990 kbps
#    (HW-verified clean on the X1000: ~15-20% CPU, MemAvailable flat ~10MB, 0 underruns).
#    --ldac-abr (adaptive bit rate): starts at 990 and auto-steps down (660/330) when the
#    2.4GHz link congests, recovering when it clears. HW-verified to eliminate dropouts in
#    a noisy RF environment where fixed 990 stuttered/warbled (CPU was 90% idle = not host).
#    NOTE: bluez as A2DP initiator always configures the sink's FIRST SEP (SBC); the LDAC
#    upgrade must be done explicitly after connect via bt_best_codec.sh (bluealsa-cli codec).
#    Retry once if RegisterApplication races bluetoothd.
# Idempotent: only (re)start bluealsa if it isn't already running. A second
# instance can't own org.bluealsa, and the retry-loop killall below would then
# kill the working one too -> the toggle-time restart storm (bluealsa re-loading
# SBC/aptX/LDAC codecs, demand-paged from squashfs = ~76% CPU + kblockd I/O).
if ! pidof bluealsa >/dev/null 2>&1; then
  for try in 1 2; do
    $LDR /usr/bin/bluealsa -p a2dp-source -c SBC -c aptX -c LDAC --a2dp-force-audio-cd --ldac-quality=high --ldac-abr \
      >/var/log/bluealsa.log 2>&1 &
    sleep 4
    grep -q "Couldn.t register media application" /var/log/bluealsa.log || break
    echo "bt_audio: bluealsa register raced bluetoothd, retry $try"
    killall bluealsa 2>/dev/null; sleep 2   # busybox pkill -f doesn't match (HW-verified); killall works
  done
fi
# Both retries can fail (killall'd on the last raced attempt) -- verify instead
# of unconditionally reporting success; callers rely on the exit code.
pidof bluealsa >/dev/null 2>&1 || { echo "bt_audio: bluealsa failed to start (see /var/log/bluealsa.log)"; exit 1; }
echo "bt_audio: stack started"
