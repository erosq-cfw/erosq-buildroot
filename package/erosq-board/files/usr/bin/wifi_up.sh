#!/bin/sh
# Bring the WiFi stack to "ready" and reconnect: power the chip, (re)bind
# brcmfmac, start wpa_supplicant, re-apply the saved regdomain, reconnect to the
# saved network, get a DHCP lease. cfg80211/brcmfmac are BUILT INTO the kernel
# (CONFIG_MODULES=n; brcmfmac.feature_disable=0x4 lives on the kernel cmdline).
# WiFi is deferred at boot by DESIGN: the erosq-wifi-power rfkill (pwrseq hard
# gate, WL_REG_ON) is default-BLOCKED, so the SDIO chip never enumerates until
# this script unblocks it — at which point the kernel powers the chip, the card
# enumerates, brcmfmac probes and loads firmware (rootfs is up now), and wlan0
# appears. The hand re-probe below is a last resort after waiting for that.
# Idempotent: near-instant when the stack is already up. Exit 0 = stack ready.
# erosq-ui runs this BACKGROUNDED (never on the LVGL thread) and reads the
# resulting state via rfkill + wpa PING, so exit codes must be honest.
IFACE=wlan0

# Serialize WiFi power transitions against wifi_down.sh (fast UI off->on).
# mkdir = atomic mutex (no flock/pgrep in this busybox). On wait-timeout FAIL
# rather than proceed; LOCKED gates the trap so we only remove a lock we
# created; INT/TERM exit so the release terminates the script. (Same pattern as
# bt_up.sh/bt_down.sh — see bt_up.sh for the full rationale.)
WIFI_LOCK=/run/wifi-power.lock
LOCKED=0
trap '[ $LOCKED -eq 1 ] && rmdir "$WIFI_LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM
n=0
while ! mkdir "$WIFI_LOCK" 2>/dev/null; do
	sleep 1; n=$((n+1))
	[ $n -ge 30 ] && { echo "wifi_up: timed out waiting for $WIFI_LOCK"; exit 1; }
done
LOCKED=1

# Last-intent guard: if a newer toggle turned WiFi OFF while we waited for the
# mutex, the teardown that wrote /run/wifi-want wins. Absent = proceed.
[ "$(cat /run/wifi-want 2>/dev/null)" = 0 ] && { echo "wifi_up: superseded by WiFi-off"; exit 0; }

wifi_power() {  # $1 = 0 (unblock/on) or 1 (block/off); by NAME — phy0 is also type wlan
	for r in /sys/class/rfkill/rfkill*; do
		[ "$(cat "$r/name" 2>/dev/null)" = erosq-wifi-power ] || continue
		echo "$1" > "$r/soft" 2>/dev/null
		break
	done
}

wifi_soft() {  # current soft state of the power gate (0 = powered)
	for r in /sys/class/rfkill/rfkill*; do
		[ "$(cat "$r/name" 2>/dev/null)" = erosq-wifi-power ] || continue
		cat "$r/soft" 2>/dev/null
		break
	done
}

wait_iface() {  # $1 = seconds; 0 once wlan0 exists
	i=0
	while [ $i -lt $1 ]; do [ -e /sys/class/net/$IFACE ] && return 0; sleep 1; i=$((i+1)); done
	[ -e /sys/class/net/$IFACE ]
}

# Power on -> bind -> wlan0 -> wpa_supplicant answering. Returns 1 (chip
# powered back down) on failure so the caller can retry.
bring_up() {
# Already powered with wlan0 up (erosq-ui restarting with Wi-Fi on): leave it.
# Writing soft=0 again makes pwrseq_erosq release + re-probe brcmfmac, which
# costs a new wlan0 (IPv4 gone, association dropped) every UI start.
# One kmsg line per decision: makes every re-probe attributable (boot logs).
if [ "$(wifi_soft)" != 0 ] || [ ! -e /sys/class/net/$IFACE ]; then
	echo "wifi_up: powering up (soft=$(wifi_soft))" >> /dev/kmsg 2>/dev/null
	wifi_power 0
else
	echo "wifi_up: already powered with $IFACE, no re-probe" >> /dev/kmsg 2>/dev/null
fi

# The unblock only SCHEDULES pwrseq_erosq's work (mmc_hw_reset + device_attach)
# and brcmfmac then loads firmware asynchronously (~1-3 s). Wait for that FIRST.
# Re-probing by hand straight away raced the kernel's attach -- two probes on
# one SDIO function: usually the hand-bind lost mid-reset (one "probe ...
# failed -145" per bring-up), but ~2-4% of the time it won and the kernel's
# attach reloaded firmware under it (rxctl timeouts, no wlan0).
wait_iface 10
if [ ! -e /sys/class/net/$IFACE ]; then
	# kernel attach produced no wlan0: re-probe by hand as a last resort
	echo 0 > /sys/bus/sdio/drivers_autoprobe
	echo 1 > /sys/bus/sdio/drivers_autoprobe
	for d in /sys/bus/sdio/devices/*; do
		echo "$(basename "$d")" > /sys/bus/sdio/drivers/brcmfmac/bind 2>/dev/null
	done
	wait_iface 5
fi
if [ ! -e /sys/class/net/$IFACE ]; then
	# Failed bring-up must not leak: put the chip back to cold (WL_REG_ON low)
	# so we don't drain the battery holding a radio nothing can talk to.
	echo "wifi_up: $IFACE did not appear"
	wifi_power 1
	return 1
fi
ifconfig $IFACE up 2>/dev/null

# Saved regdomain: cfg80211 drops it whenever the wiphy goes down, so re-apply
# after every bring-up. File written by erosq-ui's Country picker.
[ -s /data/erosq-wifi-country ] && \
	iw reg set "$(cat /data/erosq-wifi-country)" 2>/dev/null

# wpa_supplicant: erosq-ui talks to its ctrl socket (/var/run/wpa_supplicant/wlan0).
# -c is the REAL file on /data, never the /etc symlink: SAVE_CONFIG writes
# "<-c path>.tmp-XXXX" next to the -c path and renames it over, and /etc is the
# RO squashfs -- so with -c /etc/... every saved network was silently lost.
if ! pidof wpa_supplicant >/dev/null 2>&1; then
	mkdir -p /var/run/wpa_supplicant
	wpa_supplicant -B -D nl80211 -i $IFACE -c /data/etc/wpa_supplicant.conf 2>/dev/null
fi
i=0
while [ $i -lt 10 ]; do
	wpa_cli -p /var/run/wpa_supplicant -i $IFACE ping 2>/dev/null | grep -q PONG && break
	sleep 1; i=$((i+1))
done
if [ $i -ge 10 ]; then
	echo "wifi_up: wpa_supplicant not answering; powering back down"
	killall wpa_supplicant 2>/dev/null
	wifi_power 1
	return 1
fi
}

# One retry: ~2% of bring-ups lose the firmware's first control replies
# (brcmf rxctl timeout -> probe fails, wlan0 never appears) and a fresh
# power-up almost always works. Still under the mutex; skipped if a WiFi-off
# arrived meanwhile. Logged to kmsg so the underlying failure stays countable.
if ! bring_up; then
	echo "wifi_up: bring-up failed, retrying once" > /dev/kmsg 2>/dev/null
	[ "$(cat /run/wifi-want 2>/dev/null)" = 0 ] && { echo "wifi_up: superseded by WiFi-off"; exit 0; }
	sleep 1
	bring_up || exit 1
fi

# Join a saved network, and make sure a DHCP client is running on THIS wlan0.
# NOT `wpa_cli reconnect`: it only acts after an explicit DISCONNECT, so it was a
# no-op while wpa sat idle in DISCONNECTED after a lost (aborted) first scan.
# wifi_join.sh watches wpa_state in the background and REASSOCIATEs while idle;
# it leaves an existing connection alone. No -q/-n: udhcpc stays resident and
# RENEWS the lease; wifi_down.sh (and erosq-ui's connect flow) kill it.
/usr/bin/wifi_join.sh start
/usr/bin/wifi_dhcp.sh ensure   # start it, or restart one stranded on an old wlan0

echo "wifi_up: stack ready"
exit 0
