#!/bin/sh
# Host self-check for wifi_up.sh's single bring-up retry. Runs the SHIPPED
# script with its device paths redirected into a temp dir and the tools it
# calls stubbed on PATH. No framework; run directly: sh tests/test_wifi_up_retry.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$HERE/package/erosq-board/files/usr/bin/wifi_up.sh}"   # SRC= override: mutant checks
fail() { echo "FAIL: $*"; exit 1; }

run() {   # $1 = scenario; sets $rc, leaves state in $T
	T=$(mktemp -d); export T SCEN="$1"
	mkdir -p "$T/bin" "$T/sys/class/net" "$T/sys/class/rfkill/rfkill0" "$T/sys/bus/sdio/devices" \
	         "$T/sys/bus/sdio/drivers/brcmfmac" "$T/run"
	echo erosq-wifi-power > "$T/sys/class/rfkill/rfkill0/name"; echo 1 > "$T/sys/class/rfkill/rfkill0/soft"
	echo 1 > "$T/run/wifi-want"; : > "$T/kmsg"; echo 0 > "$T/offs"
	[ "$1" = ok ] && mkdir "$T/sys/class/net/wlan0"
	# sleep: the "hardware". Counts power-offs (soft=1 after having been 0) and
	# makes wlan0 appear on the 2nd power-up in scenario "once".
	cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
soft=$(cat "$T/sys/class/rfkill/rfkill0/soft")
case "$SCEN" in
late)  echo $(( $(cat "$T/sl" 2>/dev/null || echo 0) + 1 )) > "$T/sl"
       [ "$(cat "$T/sl")" -ge 3 ] && mkdir -p "$T/sys/class/net/wlan0" ;;   # kernel attach: wlan0 at ~3 s
once)  [ "$soft" = 0 ] && [ "$(cat "$T/offs")" -ge 1 ] && mkdir -p "$T/sys/class/net/wlan0" ;;
off)   echo 0 > "$T/run/wifi-want" ;;   # user turns WiFi off mid-attempt
esac
exit 0
EOF
	for c in ifconfig iw wpa_supplicant udhcpc pidof; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
	printf '#!/bin/sh\necho PONG\n' > "$T/bin/wpa_cli"
	# killall is only called on the wpa-failure path; record power-offs via wifi_power 1 instead:
	printf '#!/bin/sh\nexit 0\n' > "$T/bin/killall"
	chmod +x "$T/bin/"*
	sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/data/|$T/data/|g; s|/var/run/|$T/run/|g" \
	    -e 's|echo "$1" > "$r/soft"|echo "$1" > "$r/soft"; [ "$1" = 1 ] \&\& echo $(( $(cat "$T/offs") + 1 )) > "$T/offs"|' \
	    "$SRC" > "$T/wifi_up.sh"
	grep -q 'offs' "$T/wifi_up.sh" || fail "harness: power-off hook did not apply"
	PATH="$T/bin:$PATH" sh "$T/wifi_up.sh" > "$T/out" 2>&1
	rc=$?
}
retries() { grep -c "retrying once" "$T/kmsg"; }
handbind() { [ -e "$T/sys/bus/sdio/drivers/brcmfmac/bind" ] && echo 1 || echo 0; }

run ok;   [ "$rc" = 0 ] || fail "ok: rc=$rc"; [ "$(retries)" = 0 ] || fail "ok: retried"; rm -rf "$T"
run late; [ "$rc" = 0 ] || fail "late: rc=$rc"; [ "$(retries)" = 0 ] || fail "late: retried"
	[ "$(handbind)" = 0 ] || fail "late: hand-bind raced the kernel's attach"; rm -rf "$T"
run once; [ "$rc" = 0 ] || fail "once: rc=$rc"; [ "$(retries)" = 1 ] || fail "once: retries=$(retries)"
	[ "$(cat "$T/offs")" = 1 ] || fail "once: power-offs=$(cat "$T/offs")"; rm -rf "$T"
run never; [ "$rc" = 1 ] || fail "never: rc=$rc"; [ "$(handbind)" = 1 ] || fail "never: no last-resort re-probe"; [ "$(retries)" = 1 ] || fail "never: unbounded, retries=$(retries)"
	[ "$(cat "$T/offs")" = 2 ] || fail "never: power-offs=$(cat "$T/offs")"
	[ "$(cat "$T/sys/class/rfkill/rfkill0/soft")" = 1 ] || fail "never: chip left powered"; rm -rf "$T"
run off;  [ "$rc" = 0 ] || fail "off: rc=$rc"; grep -q "superseded" "$T/out" || fail "off: did not honour WiFi-off"
	[ "$(cat "$T/offs")" = 1 ] || fail "off: retried a power-up after WiFi-off"; rm -rf "$T"
echo "test_wifi_up_retry: all checks passed"
