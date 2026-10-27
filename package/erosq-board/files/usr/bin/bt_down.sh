#!/bin/sh
# Full Bluetooth power-down (UI "Bluetooth off").
# Stops the A2DP-source userspace stack and colds the chip, freeing ~2MB
# (bluetoothd ~0.9M + bluealsa ~1.1M) and fully quiescing the radio. Turning BT
# back on re-runs bt_up.sh (rfkill cycle + patchram firmware reload -> hci0) and
# bt_audio_up.sh (dbus/bluetoothd/bluealsa) for a cold bring-up.
#
# Kill bluetoothd FIRST: it owns the A2DP transport, and a streaming bluealsa can
# be blocked in a socket write against it -> SIGTERM to bluealsa would stay
# pending until the transport drops. Then bluealsa + patchram (patchram owns the
# N_HCI line discipline on /dev/ttyS0, so dropping it removes hci0). SIGKILL
# fallback for anything that slow-walks SIGTERM.
#
# Serialize with the bring-up (bt_up.sh/bt_audio_up.sh, see bt_up.sh): hold the
# mutex across the ENTIRE teardown so a fast UI off->on can't start bringing the
# stack/chip back up until this has fully quiesced them. mkdir = atomic mutex.
# On wait-timeout FAIL rather than proceed (see bt_up.sh: barging in breaks the
# exclusion and the trap would delete the holder's lock). LOCKED gates the trap
# so we only remove a lock we created; INT/TERM exit so the release terminates.
BT_LOCK=/run/bt-power.lock
LOCKED=0
trap '[ $LOCKED -eq 1 ] && rmdir "$BT_LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM
n=0
while ! mkdir "$BT_LOCK" 2>/dev/null; do
	sleep 1; n=$((n+1))
	[ $n -ge 30 ] && { echo "bt_down: timed out waiting for $BT_LOCK"; exit 1; }
done
LOCKED=1

# Last-intent guard (see bt_up.sh): if a newer toggle turned BT ON while we
# waited for the mutex, abort the teardown before we kill anything -- the
# bring-up that wrote /run/bt-want wins. Absent = proceed (safe default).
[ "$(cat /run/bt-want 2>/dev/null)" = 1 ] && { echo "bt_down: superseded by BT-on"; exit 0; }

killall bluetoothd 2>/dev/null
sleep 1
killall bluealsa brcm_patchram_plus 2>/dev/null
sleep 1
killall -9 bluetoothd bluealsa brcm_patchram_plus 2>/dev/null
# Cold the chip: drive BT_REG_ON low via its rfkill node (name erosq-bt-power;
# busybox has no rfkill applet, and hci0 has its own bluetooth-type node too, so
# match by name not type). Next bt_up.sh cold-inits a freshly-reset chip.
for r in /sys/class/rfkill/rfkill*; do
	[ "$(cat "$r/name" 2>/dev/null)" = erosq-bt-power ] || continue
	echo 1 > "$r/soft" 2>/dev/null
	break
done

# Wait for hci0 to vanish (patchram dropping the N_HCI ldisc removes it) BEFORE
# releasing the mutex, so the next bt_up.sh's idempotence probe reads settled
# state. (The old rmmod block that followed was dead code: BT is built into the
# kernel, CONFIG_MODULES=n, so /proc/modules never lists it.)
i=0; while [ -d /sys/class/bluetooth/hci0 ] && [ $i -lt 5 ]; do sleep 1; i=$((i + 1)); done
