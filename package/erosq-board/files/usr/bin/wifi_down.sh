#!/bin/sh
# Full WiFi power-down (UI "WiFi off"). Deauth from the AP, kill the userspace
# stack (wpa_supplicant + udhcpc — both stay resident otherwise), drop the IP
# (a blocked radio with the address still bound looks online), bring wlan0
# down, then hard power-gate the chip (erosq-wifi-power rfkill -> WL_REG_ON
# low -> chip off). Turning WiFi back on re-runs wifi_up.sh for a cold bringup.
# Mirrors bt_down.sh: mutex + last-intent so a fast UI off->on converges.
IFACE=wlan0

WIFI_LOCK=/run/wifi-power.lock
LOCKED=0
trap '[ $LOCKED -eq 1 ] && rmdir "$WIFI_LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM
n=0
while ! mkdir "$WIFI_LOCK" 2>/dev/null; do
	sleep 1; n=$((n+1))
	[ $n -ge 30 ] && { echo "wifi_down: timed out waiting for $WIFI_LOCK"; exit 1; }
done
LOCKED=1

# Last-intent guard: a newer WiFi-on toggle wins. Absent = proceed.
[ "$(cat /run/wifi-want 2>/dev/null)" = 1 ] && { echo "wifi_down: superseded by WiFi-on"; exit 0; }

# Stop wpa_supplicant FIRST and let it exit -- it deauths on SIGTERM itself.
# A separate `wpa_cli disconnect` right before overlapped two firmware
# operations: wpa's shutdown-time interface query (-> brcmf get_channel) then
# sat out the 2.5 s rxctl timeout in ~8% of teardowns (10-20 trial), stalling
# the rest of this script behind the rtnl/wiphy lock.
killall wpa_supplicant 2>/dev/null
i=0
while pidof wpa_supplicant >/dev/null 2>&1 && [ $i -lt 30 ]; do usleep 100000; i=$((i+1)); done
killall udhcpc 2>/dev/null

ifconfig $IFACE 0.0.0.0 2>/dev/null   # drop the bound IPv4 address
ifconfig $IFACE down 2>/dev/null

# Hard power-gate by NAME — cfg80211's phy0 rfkill is also type wlan, and
# soft-blocking that one would leave the chip powered (battery drain).
for r in /sys/class/rfkill/rfkill*; do
	[ "$(cat "$r/name" 2>/dev/null)" = erosq-wifi-power ] || continue
	echo 1 > "$r/soft" 2>/dev/null
	break
done

# The block only SCHEDULES pwrseq_erosq's work (release brcmfmac, then cut
# WL_REG_ON). Hold the mutex until that has really happened: a wifi_up right
# behind us otherwise unblocks before the teardown ran, the work coalesces
# the two (last-writer-wins) and mmc_hw_reset()s the chip under the still-bound
# driver -- rxctl timeouts on the old phy, failed bring-up (~2.5% of fast
# off->on cycles, 10-20). Done = wlan0 gone and no SDIO function bound.
settled() { [ ! -e /sys/class/net/$IFACE ] && ! ls /sys/bus/sdio/devices/*/driver >/dev/null 2>&1; }
i=0
while ! settled && [ $i -lt 8 ]; do sleep 1; i=$((i+1)); done
settled || echo "wifi_down: teardown still pending after 8 s" > /dev/kmsg 2>/dev/null

echo "wifi_down: stack stopped, chip powered off"
exit 0
