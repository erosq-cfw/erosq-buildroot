#!/bin/sh
# Bring up Bluetooth on the EROS Q (AzureWave AW-NM372SM = BCM43438A1).
# BT is BUILT INTO the kernel (CONFIG_MODULES=n). The DT has a bluetooth node,
# so the 8250 registers a serdev device and /dev/ttyS0 is ABSENT at boot; the
# built-in hci_uart binds that serdev during boot, btbcm loads the .hcd once the
# rootfs is mounted, and hci0 appears. This script just waits for hci0 and (if
# present) forces it up. The plain-/dev/ttyS0 userspace path is kept as a
# fallback for a kernel that lacks the serdev BT node.
HCD=/lib/firmware/BCM4343A1_001.002.009.0122.0538.hcd

# Serialize BT power transitions: a fast UI off->on must not let this script race
# bt_down.sh (teardown) on the shared chip/daemons. mkdir is an atomic mutex (no
# flock/pgrep in this busybox). On wait-timeout FAIL rather than proceed: a
# legitimate holder can run ~35s (patchram wedge), so barging in would break the
# exclusion, and the trap would then delete the holder's lock. LOCKED gates the
# trap so we only ever remove a lock we created; INT/TERM exit so the release
# actually terminates the script instead of resuming it unlocked.
BT_LOCK=/run/bt-power.lock
LOCKED=0
trap '[ $LOCKED -eq 1 ] && rmdir "$BT_LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM
n=0
while ! mkdir "$BT_LOCK" 2>/dev/null; do
	sleep 1; n=$((n+1))
	[ $n -ge 30 ] && { echo "bt_up: timed out waiting for $BT_LOCK"; exit 1; }
done
LOCKED=1

# Last-intent guard: if a newer toggle turned BT OFF while we waited for the
# mutex, abort the bring-up -- the teardown that wrote /run/bt-want wins, so a
# fast off<->on lands on the last intent regardless of lock order. Absent = no
# opposing intent -> proceed (safe default for any non-UI caller).
[ "$(cat /run/bt-want 2>/dev/null)" = 0 ] && { echo "bt_up: superseded by BT-off"; exit 0; }

if [ ! -e /dev/ttyS0 ]; then
	# --- serdev path: built-in hci_uart already bound the serdev at boot,
	#     btbcm loads the .hcd from /lib/firmware -> hci0 appears ---
	i=0
	while [ $i -lt 15 ]; do [ -d /sys/class/bluetooth/hci0 ] && break; sleep 1; i=$((i+1)); done
	[ -d /sys/class/bluetooth/hci0 ] || { echo "bt_up: no hci0 (built-in hci_uart/serdev)"; exit 1; }
	# hci0 exists; bluetoothd powers the controller via the mgmt API. hciconfig is
	# optional (absent in this build) -- use it only to force UP early if present.
	if [ -x /usr/sbin/hciconfig ]; then
		# BT core can need a few seconds after BT_REG_ON before HCI_Reset; retry.
		n=0
		while [ $n -lt 6 ]; do
			/usr/sbin/hciconfig hci0 up 2>/dev/null && break
			sleep 2; n=$((n+1))
		done
		/usr/sbin/hciconfig hci0
	fi
	exit 0
fi

# --- userspace path: load firmware via brcm_patchram_plus. The N_HCI line
# discipline it attaches is provided by the built-in hci_uart. ---
# Idempotent (checked under the mutex, so post-teardown state is settled): if the
# chip is already up and patchram is holding the line discipline, don't cold-cycle
# it -- just return. This replaces the old caller-side `[ -e hci0 ] ||` guard
# (ui_bt_set_power), which read hci0 racily mid-teardown and could skip bt_up.sh
# entirely, leaving no one to recreate hci0 after bt_down.sh removed it.
if [ -d /sys/class/bluetooth/hci0 ] && pidof brcm_patchram_plus >/dev/null 2>&1; then
	exit 0
fi
killall brcm_patchram_plus 2>/dev/null; sleep 1
# Assert host RTS (chip CTS_N low) BEFORE REG_ON rises. Until ttyS0's first
# CRTSCTS open, UART0 UMCR sits at its reset value 0 = RTS_ forced high, and a
# chip powered up that way ignores HCI_Reset for exactly 12 s (HW A/B: MCR 0x00
# -> 12.0 s x2; 0xC0/0xC2 -> 6-17 ms x4). One crtscts open latches MDCE|FCM
# (8250_ingenic keeps them after close), so the hardware holds RTS_ low from now on.
stty -F /dev/ttyS0 crtscts 2>/dev/null
# Cold-cycle the BT chip via its rfkill (BT_REG_ON/PC18, rfkill-gpio in the DT) so
# patchram always cold-inits a freshly-reset chip. Without this, a warm reboot
# leaves stale firmware on the chip (REG_ON stayed high) and patchram's re-download
# wedges it mute. Busybox has no rfkill applet -> drive the sysfs node, found by
# type=bluetooth (numbering varies). Harmless if the node is absent (old kernel).
for r in /sys/class/rfkill/rfkill*; do
	[ "$(cat "$r/type" 2>/dev/null)" = bluetooth ] || continue
	echo 1 > "$r/soft" 2>/dev/null; sleep 1   # REG_ON low: power down BT core
	echo 0 > "$r/soft" 2>/dev/null; sleep 1   # REG_ON high: cold boot
	break
done
# 3 Mbaud = stock operational rate. Reachable since 8250_ingenic now shrinks the
# UMR oversampling factor to 8 (24 MHz EXCLK / (8*1) = 3 Mbaud); a stock 8250
# capped at /16 oversampling tops out at 1.5 Mbaud (HW-verified: UMR=0x08 @3M).
# NB: download the .hcd at the default 115200, then switch to 3 M operational.
# Do NOT add --use_baudrate_for_download: the cold BCM43438 ROM can't reliably
# receive the patch at 3 M and the attempt wedges the chip (HW-confirmed 2026-06-25).
setsid /usr/bin/brcm_patchram_plus --enable_hci --baudrate 3000000 --no2bytes \
	--tosleep=50000 --patchram "$HCD" /dev/ttyS0 >/var/log/bt_patchram.log 2>&1 &
i=0
while [ $i -lt 30 ]; do [ -d /sys/class/bluetooth/hci0 ] && break; sleep 1; i=$((i+1)); done
if [ ! -d /sys/class/bluetooth/hci0 ]; then
	# Failed bring-up must not leak: reap the wedged patchram and put the chip
	# back to cold (REG_ON low) so we don't drain the battery holding a radio
	# nothing can talk to. Match the power rfkill by name (see bt_down.sh).
	echo "bt_up: hci0 not created (see /var/log/bt_patchram.log)"
	killall brcm_patchram_plus 2>/dev/null
	for r in /sys/class/rfkill/rfkill*; do
		[ "$(cat "$r/name" 2>/dev/null)" = erosq-bt-power ] || continue
		echo 1 > "$r/soft" 2>/dev/null
		break
	done
	exit 1
fi
# hci0 exists; bluetoothd powers the controller via the mgmt API. hciconfig is
# optional (absent in this build) -- use it only to force UP early if present.
if [ -x /usr/sbin/hciconfig ]; then /usr/sbin/hciconfig hci0 up; /usr/sbin/hciconfig hci0; fi
