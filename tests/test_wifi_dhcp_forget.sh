#!/bin/sh
# Host self-check (saved Wi-Fi, Forget): when erosq-ui forgets the CONNECTED
# network, wpa deauthenticates, but busybox udhcpc keeps its lease -- SIGTERM
# without -R does not deconfig -- so wlan0 kept the old IPv4 and routes.
# erosq-ui then runs `wifi_dhcp.sh check; wifi_join.sh start`:
#  - check, wpa answering but not COMPLETED: stop udhcpc, run its deconfig
#    (the shipped default.script: ifconfig 0.0.0.0 + resolv.conf), start none;
#  - check on COMPLETED and with wpa gone behaves as before (act);
#  - a join afterwards gets a fresh client from the same `check`;
#  - wifi_join.sh's monitor never drops a lease while wpa is idle (an AP
#    drop reconnects on the old lease; a 30 s monitor would delay the IPv4).
# Runs the SHIPPED scripts with /sys, /run, /usr/bin redirected and tools
# stubbed. Run directly: sh tests/test_wifi_dhcp_forget.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN=$HERE/package/erosq-board/files/usr/bin
DHCP="${SRC:-$BIN/wifi_dhcp.sh}"
JOIN=$BIN/wifi_join.sh
fail() { echo "FAIL: $*"; exit 1; }

setup() {  # $1 = running(0/1)  $2 = wpa_state ('' = wpa not answering)
	T=$(mktemp -d); export T
	mkdir -p "$T/bin" "$T/sys/class/net/wlan0" "$T/run" "$T/usr/bin"
	echo 4 > "$T/sys/class/net/wlan0/ifindex"; echo 4 > "$T/run/udhcpc.ifindex"
	echo 1 > "$T/run/wifi-want"
	echo "$1" > "$T/running"; printf '%s' "$2" > "$T/state"; : > "$T/log"; : > "$T/kmsg"
	cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
[ "$(cat "$T/running")" = 1 ]
EOF
	cat > "$T/bin/killall" <<'EOF'
#!/bin/sh
echo "killall $*" >> "$T/log"; echo 0 > "$T/running"
EOF
	cat > "$T/bin/udhcpc" <<'EOF'
#!/bin/sh
echo "udhcpc $*" >> "$T/log"; /bin/sleep 0.2; echo 1 > "$T/running"
EOF
	cat > "$T/bin/wpa_cli" <<'EOF'
#!/bin/sh
for a; do last=$a; done
s=$(cat "$T/state")
[ -n "$s" ] || exit 1          # wpa not answering
case $last in
status) echo "wpa_state=$s" ;;
list_networks) printf 'network id / ssid / bssid / flags\n0\tHome\tany\t\n' ;;
reassociate) echo "reassociate" >> "$T/log"; echo OK ;;
*) echo OK ;;
esac
EOF
	cat > "$T/deconfig" <<'EOF'
#!/bin/sh
echo "script $1 $interface" >> "$T/log"
EOF
	printf '#!/bin/sh\n/bin/sleep 0.02\n' > "$T/bin/sleep"
	chmod +x "$T/bin/"* "$T/deconfig"
	sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/usr/bin/|$T/usr/bin/|g" "$DHCP" > "$T/usr/bin/wifi_dhcp.sh"
	sed -e "s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/usr/bin/|$T/usr/bin/|g" "$JOIN" > "$T/usr/bin/wifi_join.sh"
	chmod +x "$T/usr/bin/"*
}
go() { DECONFIG="$T/deconfig" MON_MAX=1 PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_dhcp.sh" "$@"; }
starts() { grep -c '^udhcpc -i wlan0' "$T/log"; }
deconfigs() { grep -c '^script deconfig wlan0$' "$T/log"; }

# 0. the pure rule
for s in COMPLETED ''; do
	[ "$(sh "$DHCP" check-decide "$s")" = act ] || fail "check-decide '$s' != act"
done
for s in DISCONNECTED INACTIVE SCANNING AUTHENTICATING ASSOCIATING ASSOCIATED 4WAY_HANDSHAKE GROUP_HANDSHAKE INTERFACE_DISABLED; do
	[ "$(sh "$DHCP" check-decide "$s")" = drop ] || fail "check-decide $s != drop"
done

# 1. the bug: forgot the connected network (wpa DISCONNECTED or already
#    SCANNING for another), client still bound -> stopped, deconfig, no start
for s in DISCONNECTED SCANNING; do
	setup 1 "$s"; go check
	[ "$(sed -n 1p "$T/log")" = "killall udhcpc" ] || fail "$s: client not stopped ($(cat "$T/log"))"
	[ "$(sed -n 2p "$T/log")" = "script deconfig wlan0" ] || fail "$s: no deconfig after the stop ($(cat "$T/log"))"
	[ "$(starts)" = 0 ] || fail "$s: started a client with no association"
	[ -d "$T/run/wifi-dhcp.lock" ] && fail "$s: lock left behind"
	grep -q "dropping the old lease" "$T/kmsg" || fail "$s: not logged"
	rm -rf "$T"
done

# 2. nothing running: still deconfig (an address can outlive its client), no kill
setup 0 DISCONNECTED; go check
[ "$(deconfigs)" = 1 ] && ! grep -q killall "$T/log" && [ "$(starts)" = 0 ] || fail "idle: $(cat "$T/log")"; rm -rf "$T"

# 3. unchanged: COMPLETED with a good client -> untouched; wpa gone -> no drop
setup 1 COMPLETED; go check
[ ! -s "$T/log" ] || fail "COMPLETED: touched a good client ($(cat "$T/log"))"; rm -rf "$T"
setup 1 ''; go check
[ "$(deconfigs)" = 0 ] && ! grep -q killall "$T/log" || fail "wpa gone: dropped ($(cat "$T/log"))"; rm -rf "$T"

# 4. no wlan0: nothing
setup 1 DISCONNECTED; rm -rf "$T/sys/class/net/wlan0"; go check
[ ! -s "$T/log" ] || fail "no wlan0: $(cat "$T/log")"; rm -rf "$T"

# 5. forget, then wpa joins another saved network: the next check (wifi_join
#    on COMPLETED) starts exactly one fresh client
setup 1 DISCONNECTED; go check
echo COMPLETED > "$T/state"; go check
[ "$(starts)" = 1 ] && [ "$(deconfigs)" = 1 ] || fail "rejoin after forget: $(cat "$T/log")"; rm -rf "$T"

# 6. two checks back to back (UI + watcher) share the lock: one stop, no start
setup 1 DISCONNECTED
go check & go check & wait
[ "$(grep -c killall "$T/log")" = 1 ] && [ "$(starts)" = 0 ] || fail "concurrent: $(cat "$T/log")"; rm -rf "$T"

# 7. wifi_join.sh while wpa idles (AP gone): it reassociates, never drops the
#    lease (the old client keeps serving when wpa reconnects to the same AP)
setup 1 DISCONNECTED
echo tok > "$T/run/wifi-join.gen"
DECONFIG="$T/deconfig" JOIN_SECS=4 MON_MAX=3 PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" worker tok >/dev/null 2>&1
grep -q reassociate "$T/log" || fail "watcher: never kicked ($(cat "$T/log"))"
[ "$(deconfigs)" = 0 ] && ! grep -q killall "$T/log" || fail "watcher dropped the lease ($(cat "$T/log"))"; rm -rf "$T"

echo "test_wifi_dhcp_forget: all checks passed"
