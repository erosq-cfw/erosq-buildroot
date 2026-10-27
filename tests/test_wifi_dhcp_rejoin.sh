#!/bin/sh
# Host self-check (bug C, 2e.3): after a re-probe the old udhcpc can die with
# its wlan0 -- busybox udhcpc re-reads the interface on every retry timer
# (DISCOVER: every 3 s) and exits when it is gone -- and the hotplug used to
# turn "start" into "keep", so nothing started a new client: associated, no
# IPv4, until Wi-Fi was toggled. Now, while Wi-Fi is wanted (/run/wifi-want=1)
# and wpa is COMPLETED, exactly one udhcpc runs on the current wlan0:
#  - wifi_dhcp.sh hotplug / check start one when none runs (and only then);
#  - wifi_join.sh runs `wifi_dhcp.sh check` after a join and on each monitor
#    check;
#  - two callers back to back never start two clients (je2d item 12).
# Runs the SHIPPED scripts with /sys, /run, /usr/bin redirected and tools
# stubbed. Run directly: sh tests/test_wifi_dhcp_rejoin.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN=$HERE/package/erosq-board/files/usr/bin
DHCP="${SRC:-$BIN/wifi_dhcp.sh}"
JOIN=$BIN/wifi_join.sh
fail() { echo "FAIL: $*"; exit 1; }

setup() {  # $1 = running(0/1)  $2 = recorded ifindex  $3 = current ifindex  $4 = wifi-want ('' = absent)
	T=$(mktemp -d); export T
	mkdir -p "$T/bin" "$T/sys/class/net/wlan0" "$T/run" "$T/usr/bin"
	echo "$3" > "$T/sys/class/net/wlan0/ifindex"
	[ -n "$2" ] && echo "$2" > "$T/run/udhcpc.ifindex"
	[ -n "$4" ] && echo "$4" > "$T/run/wifi-want"
	echo "$1" > "$T/running"; : > "$T/log"; : > "$T/kmsg"; : > "$T/assoc"
	cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
[ "$(cat "$T/running")" = 1 ]
EOF
	cat > "$T/bin/killall" <<'EOF'
#!/bin/sh
echo "killall $*" >> "$T/log"; echo 0 > "$T/running"
EOF
	# like the real thing, a just-launched client is invisible to pidof for a
	# moment (fork -> exec)
	cat > "$T/bin/udhcpc" <<'EOF'
#!/bin/sh
echo "udhcpc $*" >> "$T/log"; /bin/sleep 0.2; echo 1 > "$T/running"
EOF
	cat > "$T/bin/wpa_cli" <<'EOF'
#!/bin/sh
for a; do last=$a; done
case $last in
status) [ -e "$T/assoc" ] && echo wpa_state=COMPLETED || echo wpa_state=SCANNING ;;
list_networks) printf 'network id / ssid / bssid / flags\n0\tHome\tany\t\n' ;;
*) echo OK ;;
esac
EOF
	printf '#!/bin/sh\n/bin/sleep 0.02\n' > "$T/bin/sleep"
	chmod +x "$T/bin/"*
	sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/usr/bin/|$T/usr/bin/|g" "$DHCP" > "$T/usr/bin/wifi_dhcp.sh"
	sed -e "s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/usr/bin/|$T/usr/bin/|g" "$JOIN" > "$T/usr/bin/wifi_join.sh"
	chmod +x "$T/usr/bin/"*
}
go() { MON_MAX=1 PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_dhcp.sh" "$@"; }   # MON_MAX: the watcher hotplug starts must end
starts() { grep -c '^udhcpc -i wlan0' "$T/log"; }
settle() {  # background work (hotplug worker / watcher) done: wait up to ~5 s
	i=0; while [ $i -lt 100 ]; do
		pgrep -f "$T/usr/bin/wifi_(dhcp|join).sh (worker|start)" >/dev/null || [ -d "$T/run/wifi-dhcp.lock" ] || return 0
		/bin/sleep 0.05; i=$((i+1)); done
}

# 1. the bug: old client died with its wlan0 (none running, record = old 3,
#    wlan0 now 4), Wi-Fi wanted, associated -> hotplug starts exactly one on 4
setup 0 3 4 1; go hotplug; settle
[ "$(starts)" = 1 ] || fail "client died with wlan0: hotplug started $(starts) client(s) ($(cat "$T/log"))"
[ "$(cat "$T/run/udhcpc.ifindex")" = 4 ] || fail "record not the current wlan0"
grep -q killall "$T/log" && fail "nothing to kill, but killall ran"; rm -rf "$T"

# 2. Wi-Fi being turned off (want=0) or never wanted (absent): never start one
for w in 0 ''; do
	setup 0 3 4 "$w"; go hotplug; settle
	[ "$(starts)" = 0 ] || fail "want='$w': hotplug started a client"; rm -rf "$T"
done

# 3. wanted but not associated (worker gives up waiting): no client
setup 0 3 4 1; rm "$T/assoc"; go hotplug; settle
[ "$(starts)" = 0 ] || fail "not COMPLETED: hotplug started a client"; rm -rf "$T"

# 4. a live client on the current wlan0 is kept; a stale one still restarts
setup 1 4 4 1; go check
[ "$(starts)" = 0 ] && ! grep -q killall "$T/log" || fail "check: touched a good client ($(cat "$T/log"))"; rm -rf "$T"
setup 1 3 4 1; go check
[ "$(sed -n 1p "$T/log")" = "killall udhcpc" ] && [ "$(starts)" = 1 ] || fail "check: stale client not restarted ($(cat "$T/log"))"; rm -rf "$T"

# 5. check: synchronous form of the same rule
setup 0 3 4 1; go check
[ "$(starts)" = 1 ] || fail "check: started $(starts)"; rm -rf "$T"
setup 0 3 4 0; go check
[ "$(starts)" = 0 ] || fail "check with want=0 started a client"; rm -rf "$T"

# 6. no duplicates (item 12): two callers back to back while the first
#    client is not yet visible to pidof -> one client
setup 0 3 4 1
go check & go check & wait
[ "$(starts)" = 1 ] || fail "two concurrent checks started $(starts) clients"; rm -rf "$T"
setup 0 '' 4 1
go ensure & go check & wait
[ "$(starts)" = 1 ] || fail "ensure + check started $(starts) clients"; rm -rf "$T"

# 7. wifi_join.sh: after the join (no client running) it gets one going
setup 0 3 4 1
echo tok > "$T/run/wifi-join.gen"
MON_MAX=1 PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" worker tok >/dev/null 2>&1
settle
[ "$(starts)" = 1 ] || fail "wifi_join after join: started $(starts)"; rm -rf "$T"

# 8. wifi_join.sh monitor: a client that dies later is replaced at the next
#    check; one that lives is left alone
setup 1 4 4 1
echo tok > "$T/run/wifi-join.gen"
( MON_MAX=3 PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" worker tok >/dev/null 2>&1 ) &
/bin/sleep 0.05; echo 0 > "$T/running"; wait; settle
[ "$(starts)" = 1 ] || fail "monitor: dead client not replaced (starts=$(starts))"; rm -rf "$T"
setup 1 4 4 1
echo tok > "$T/run/wifi-join.gen"
MON_MAX=3 PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" worker tok >/dev/null 2>&1; settle
[ "$(starts)" = 0 ] && ! grep -q killall "$T/log" || fail "monitor: touched a live client ($(cat "$T/log"))"; rm -rf "$T"

echo "test_wifi_dhcp_rejoin: all checks passed"
