#!/bin/sh
# Host self-check: wifi_up.sh must NOT write the power gate (=> pwrseq release +
# brcmfmac re-probe) when Wi-Fi is already powered and wlan0 exists, and must
# still power up otherwise. Harness as in test_wifi_up_retry.sh.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$HERE/package/erosq-board/files/usr/bin/wifi_up.sh}"
fail() { echo "FAIL: $*"; exit 1; }

run() {  # $1 = initial soft (0/1)  $2 = wlan0 present (0/1)
	T=$(mktemp -d); export T
	mkdir -p "$T/bin" "$T/sys/class/net" "$T/sys/class/rfkill/rfkill0" "$T/sys/bus/sdio/devices" \
	         "$T/sys/bus/sdio/drivers/brcmfmac" "$T/run" "$T/usr/bin"
	echo erosq-wifi-power > "$T/sys/class/rfkill/rfkill0/name"; echo "$1" > "$T/sys/class/rfkill/rfkill0/soft"
	echo 1 > "$T/run/wifi-want"; : > "$T/writes"
	[ "$2" = 1 ] && mkdir "$T/sys/class/net/wlan0"
	# the "kernel": a power-up makes wlan0 appear
	cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
[ "$(cat "$T/sys/class/rfkill/rfkill0/soft")" = 0 ] && mkdir -p "$T/sys/class/net/wlan0"
exit 0
EOF
	for c in ifconfig iw wpa_supplicant udhcpc pidof killall; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
	printf '#!/bin/sh\necho PONG\n' > "$T/bin/wpa_cli"
	printf '#!/bin/sh\necho "dhcp $*" >> "$T/writes"\n' > "$T/usr/bin/wifi_dhcp.sh"
	chmod +x "$T/bin/"* "$T/usr/bin/wifi_dhcp.sh"
	sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/data/|$T/data/|g; s|/var/run/|$T/run/|g; s|/usr/bin/wifi_dhcp.sh|$T/usr/bin/wifi_dhcp.sh|g" \
	    -e 's|echo "$1" > "$r/soft"|echo "$1" > "$r/soft"; echo "soft $1" >> "$T/writes"|' \
	    "$SRC" > "$T/wifi_up.sh"
	grep -q 'soft \$1' "$T/wifi_up.sh" || fail "harness: soft-write hook did not apply"
	PATH="$T/bin:$PATH" sh "$T/wifi_up.sh" > "$T/out" 2>&1
	rc=$?
}

run 0 1; [ "$rc" = 0 ] || fail "up+wlan0: rc=$rc"
	grep -q '^soft' "$T/writes" && fail "up+wlan0: wrote the power gate (re-probe): $(cat "$T/writes")"
	grep -q '^dhcp ensure' "$T/writes" || fail "up+wlan0: DHCP not ensured"; rm -rf "$T"
run 1 0; [ "$rc" = 0 ] || fail "off: rc=$rc"
	[ "$(sed -n 1p "$T/writes")" = "soft 0" ] || fail "off: did not power up: $(cat "$T/writes")"; rm -rf "$T"
run 0 0; [ "$rc" = 0 ] || fail "on-but-no-wlan0: rc=$rc"
	[ "$(sed -n 1p "$T/writes")" = "soft 0" ] || fail "on-but-no-wlan0: no recovery write"; rm -rf "$T"
echo "test_wifi_up_noreprobe: all checks passed"
