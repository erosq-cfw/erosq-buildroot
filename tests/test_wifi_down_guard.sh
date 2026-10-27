#!/bin/sh
# Host self-check for wifi_down.sh's teardown wait: the script must not return
# (release the wifi-power mutex) until pwrseq_erosq's async block work has
# released brcmfmac (wlan0 gone, no SDIO function bound) -- or 8 s, logged.
# Runs the SHIPPED script with device paths redirected and tools stubbed.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$HERE/package/erosq-board/files/usr/bin/wifi_down.sh}"   # SRC= override: mutant checks
fail() { echo "FAIL: $*"; exit 1; }

run() {   # $1 = scenario: lag (teardown after 2 s) | stuck | off
	T=$(mktemp -d); export T SCEN="$1"
	mkdir -p "$T/bin" "$T/sys/class/net" "$T/sys/class/rfkill/rfkill0" "$T/sys/bus/sdio/devices/mmc1:0001:1" "$T/run"
	echo erosq-wifi-power > "$T/sys/class/rfkill/rfkill0/name"; echo 0 > "$T/sys/class/rfkill/rfkill0/soft"
	echo 0 > "$T/run/wifi-want"; : > "$T/kmsg"; echo 0 > "$T/sl"
	if [ "$1" != off ]; then mkdir "$T/sys/class/net/wlan0" "$T/sys/bus/sdio/devices/mmc1:0001:1/driver"; fi
	cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
n=$(( $(cat "$T/sl") + 1 )); echo $n > "$T/sl"
# real order: the netdev goes first (inside brcmf remove), the unbind completes after
[ "$SCEN" = lag ] && [ $n -ge 1 ] && rm -rf "$T/sys/class/net/wlan0"
[ "$SCEN" = lag ] && [ $n -ge 2 ] && rm -rf "$T/sys/bus/sdio/devices/mmc1:0001:1/driver"
exit 0
EOF
	# every tool logs its call, so the test can check the stop order
	for c in wpa_cli killall ifconfig; do printf '#!/bin/sh\necho "%s $*" >> "$T/calls"\nexit 0\n' "$c" > "$T/bin/$c"; done
	: > "$T/calls"; echo 0 > "$T/pid"
	# pidof: wpa_supplicant stays alive for $WPA_LINGER polls after the kill
	printf '#!/bin/sh\nn=$(( $(cat "$T/pid") + 1 )); echo $n > "$T/pid"; echo "pidof $*" >> "$T/calls"\n[ $n -le "${WPA_LINGER:-0}" ]\n' > "$T/bin/pidof"
	printf '#!/bin/sh\necho "usleep $*" >> "$T/calls"\nexit 0\n' > "$T/bin/usleep"
	chmod +x "$T/bin/"*
	sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/var/run/|$T/run/|g" "$SRC" > "$T/wifi_down.sh"
	PATH="$T/bin:$PATH" sh "$T/wifi_down.sh" > "$T/out" 2>&1
	rc=$?
}
sleeps() { cat "$T/sl"; }
logged() { grep -c "teardown still pending" "$T/kmsg"; }

run lag;   [ "$rc" = 0 ] || fail "lag: rc=$rc"; [ "$(sleeps)" = 2 ] || fail "lag: waited $(sleeps) s, want 2"
	[ "$(logged)" = 0 ] || fail "lag: logged a timeout"; [ "$(cat "$T/sys/class/rfkill/rfkill0/soft")" = 1 ] || fail "lag: not blocked"; rm -rf "$T"
run stuck; [ "$rc" = 0 ] || fail "stuck: rc=$rc"; [ "$(sleeps)" = 8 ] || fail "stuck: waited $(sleeps) s, want 8 (bounded)"
	[ "$(logged)" = 1 ] || fail "stuck: timeout not logged"; rm -rf "$T"
run off;   [ "$(sleeps)" = 0 ] || fail "off: waited $(sleeps) s with nothing to tear down"; rm -rf "$T"

# Stop order: wpa_supplicant is SIGTERMed and has EXITED before any ifconfig,
# and no separate `wpa_cli disconnect` is sent (it overlapped wpa's shutdown
# query with the firmware's disconnect -> 2.5 s rxctl stalls, 10-20).
WPA_LINGER=3 run lag
grep -q "^wpa_cli .*disconnect" "$T/calls" && fail "order: separate wpa_cli disconnect still sent"
k=$(grep -n "^killall wpa_supplicant" "$T/calls" | head -1 | cut -d: -f1)
f=$(grep -n "^ifconfig" "$T/calls" | head -1 | cut -d: -f1)
[ -n "$k" ] && [ -n "$f" ] && [ "$k" -lt "$f" ] || fail "order: ifconfig before killing wpa_supplicant"
[ "$(sed -n "${k},${f}p" "$T/calls" | grep -c '^usleep')" = 3 ] || fail "order: did not wait for wpa_supplicant to exit before ifconfig"
rm -rf "$T"
WPA_LINGER=999 run lag   # wpa never exits: bounded (30 x 100 ms), then carries on
[ "$(grep -c '^usleep' "$T/calls")" = 30 ] || fail "order: wpa exit wait unbounded ($(grep -c '^usleep' "$T/calls") polls)"
grep -q "^ifconfig" "$T/calls" || fail "order: stuck after a wpa that would not exit"
rm -rf "$T"
echo "test_wifi_down_guard: all checks passed"
