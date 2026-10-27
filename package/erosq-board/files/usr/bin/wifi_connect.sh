#!/bin/sh
# Manual/dev tool: bring the stack up, wait for association + DHCP, sync the
# clock. Exit 0 only if wlan0 is associated AND has an IPv4 address.
# Uses wifi_up.sh (mutexed, idempotent) instead of killing/restarting
# wpa_supplicant — restarting it here used to tear down erosq-ui's live session
# and ctrl socket. The network to join comes from /data/etc/wpa_supplicant.conf
# (/etc/wpa_supplicant.conf links there), maintained by erosq-ui (SAVE_CONFIG)
# or by hand.
IFACE=wlan0

/usr/bin/wifi_up.sh || exit 1

# wait for association (iw link shows "Connected to <bssid>")
i=0
while [ $i -lt 20 ]; do
	iw dev $IFACE link 2>/dev/null | grep -q "Connected to" && break
	i=$((i+1)); sleep 1
done
echo "--- iw link ---"; iw dev $IFACE link

# wait for the DHCP lease (wifi_up.sh already runs a resident udhcpc)
i=0
while [ $i -lt 15 ]; do
	ifconfig $IFACE 2>/dev/null | grep -q "inet addr" && break
	i=$((i+1)); sleep 1
done
echo "--- addr ---"; ifconfig $IFACE | grep -E 'inet addr|HWaddr'
echo "--- route ---"; route -n | grep -E "^0.0.0.0|$IFACE"

# One-shot clock sync over the fresh link (RTC works these days, but it drifts
# and a dead battery still means 1970 — which breaks HTTPS cert validity).
# -nq = query the pool once and exit; rdate is the fallback if NTP is
# firewalled; persist to the RTC so the correction survives power-off.
ntpd -nq -p pool.ntp.org 2>/dev/null || rdate -s time.nist.gov 2>/dev/null
hwclock -w 2>/dev/null
echo "--- clock ---"; date; hwclock -r 2>/dev/null

# honest verdict: associated AND holding an IPv4 address
iw dev $IFACE link 2>/dev/null | grep -q "Connected to" || \
	{ echo "wifi_connect: NOT associated"; exit 1; }
ifconfig $IFACE 2>/dev/null | grep -q "inet addr" || \
	{ echo "wifi_connect: no IPv4 lease"; exit 1; }
echo "wifi_connect: connected"
exit 0
