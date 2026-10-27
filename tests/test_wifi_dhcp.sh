#!/bin/sh
# Host self-check for wifi_dhcp.sh (udhcpc must follow the CURRENT wlan0).
# Runs the SHIPPED script with /sys and /run redirected into a temp dir and the
# tools stubbed on PATH. Run directly: sh tests/test_wifi_dhcp.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$HERE/package/erosq-board/files/usr/bin/wifi_dhcp.sh}"
HOOK="$HERE/package/erosq-board/files/usr/share/udhcpc/default.script.d/10-ifindex"
fail() { echo "FAIL: $*"; exit 1; }

# --- pure decision table -------------------------------------------------
d() { sh "$SRC" decide "$1" "$2" "$3"; }
[ "$(d 0 '' 4)" = start ]   || fail "no client -> start"
[ "$(d 0 3 4)" = start ]    || fail "no client, stale record -> start"
[ "$(d 1 4 4)" = keep ]     || fail "client on current wlan0 -> keep"
[ "$(d 1 3 4)" = restart ]  || fail "client on gone wlan0 -> restart"
[ "$(d 1 '' 4)" = keep ]    || fail "client just starting (no record) -> keep"

# --- harness ---------------------------------------------------------------
setup() {  # $1 = running(0/1)  $2 = recorded ifindex ('' = none)  $3 = current ifindex
	T=$(mktemp -d); export T
	mkdir -p "$T/bin" "$T/sys/class/net/wlan0" "$T/run"
	echo "$3" > "$T/sys/class/net/wlan0/ifindex"
	[ -n "$2" ] && echo "$2" > "$T/run/udhcpc.ifindex"
	echo "$1" > "$T/running"; : > "$T/log"; : > "$T/kmsg"
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
echo "udhcpc $*" >> "$T/log"; echo 1 > "$T/running"
EOF
	cat > "$T/bin/wpa_cli" <<'EOF'
#!/bin/sh
[ -e "$T/assoc" ] && echo wpa_state=COMPLETED || echo wpa_state=SCANNING
EOF
	: > "$T/assoc"
	printf '#!/bin/sh\n/bin/sleep 0.05\n' > "$T/bin/sleep"
	chmod +x "$T/bin/"*
	sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g" "$SRC" > "$T/wifi_dhcp.sh"
}
go() { PATH="$T/bin:$PATH" sh "$T/wifi_dhcp.sh" "$1"; }
waitlog() {  # hotplug works in the background: wait for it (max ~5 s)
	i=0; while [ $i -lt 50 ]; do [ -d "$T/run/wifi-dhcp.lock" ] || \
	  { grep -q "$1" "$T/log" && return 0; }; i=$((i+1)); /bin/sleep 0.1; done; grep -q "$1" "$T/log"
}

# ensure: nothing running -> start exactly one client
setup 0 '' 4; go ensure
[ "$(grep -c '^udhcpc -i wlan0' "$T/log")" = 1 ] || fail "ensure/start: $(cat "$T/log")"
grep -q killall "$T/log" && fail "ensure/start killed something"; rm -rf "$T"

# ensure: client stranded on old ifindex 3, wlan0 is now 4 -> kill + restart
setup 1 3 4; go ensure
[ "$(sed -n 1p "$T/log")" = "killall udhcpc" ] || fail "ensure/stale: $(cat "$T/log")"
[ "$(sed -n 2p "$T/log")" = "udhcpc -i wlan0" ] || fail "ensure/stale: no restart"
grep -q "restarting" "$T/kmsg" || fail "ensure/stale: not logged"
[ "$(cat "$T/run/udhcpc.ifindex")" = 4 ] || fail "ensure/stale: record not moved to the current ifindex"
[ -d "$T/run/wifi-dhcp.lock" ] && fail "ensure: lock leaked"; rm -rf "$T"

# ensure: healthy client -> untouched
setup 1 4 4; go ensure; [ -s "$T/log" ] && fail "ensure/healthy touched: $(cat "$T/log")"; rm -rf "$T"

# hotplug: stale client -> restarted (after association)
setup 1 3 4; go hotplug; waitlog "udhcpc -i wlan0" || fail "hotplug/stale: no restart"
grep -q "killall udhcpc" "$T/log" || fail "hotplug/stale: old client not killed"; rm -rf "$T"

# hotplug: no client -> must NOT start one (Wi-Fi may be going down)
setup 0 '' 4; go hotplug; /bin/sleep 1
[ -d "$T/run/wifi-dhcp.lock" ] && /bin/sleep 2
[ -s "$T/log" ] && fail "hotplug/none started DHCP: $(cat "$T/log")"; rm -rf "$T"

# hotplug: healthy client -> untouched
setup 1 4 4; go hotplug; /bin/sleep 1; [ -s "$T/log" ] && fail "hotplug/healthy touched"; rm -rf "$T"

# --- overlapping add-events: the newest supersedes, final state is right --
# Re-probe #1 (ifindex 4) while not yet associated; re-probe #2 (ifindex 5)
# arrives while worker #1 still waits. Only worker #2 may act: one restart,
# and the record ends on the CURRENT ifindex.
setup 1 3 4; rm "$T/assoc"
go hotplug; /bin/sleep 0.3
echo 5 > "$T/sys/class/net/wlan0/ifindex"; go hotplug; /bin/sleep 0.3
nw=$(pgrep -f "$T/wifi_dhcp.sh worker" | wc -l)
[ "$nw" = 1 ] || fail "overlap: $nw workers alive, superseded one did not exit"
: > "$T/assoc"
waitlog "udhcpc -i wlan0" || fail "overlap: no restart"; /bin/sleep 1.5
[ "$(grep -c '^udhcpc -i wlan0' "$T/log")" = 1 ] || fail "overlap: $(grep -c '^udhcpc' "$T/log") restarts: $(cat "$T/log")"
[ "$(cat "$T/run/udhcpc.ifindex")" = 5 ] || fail "overlap: record=$(cat "$T/run/udhcpc.ifindex"), want 5"
[ -d "$T/run/wifi-dhcp.lock" ] && fail "overlap: lock leaked"; rm -rf "$T"

# a stale lock (holder died) must not block: it is broken, the action happens
setup 1 3 4; mkdir "$T/run/wifi-dhcp.lock"; echo 999999 > "$T/run/wifi-dhcp.lock/pid"
go ensure; grep -q "^udhcpc -i wlan0" "$T/log" || fail "stale lock blocked ensure"; rm -rf "$T"

# wlan0 re-created DURING act (a re-probe lands while we restart the client):
# the holder re-checks and ends with ONE client on the newest wlan0. The new
# client is invisible to pidof here (as right after a fork): it must still be
# replaced, not joined by a second one.
setup 1 3 4
cat > "$T/bin/killall" <<'EOF'
#!/bin/sh
echo "killall $*" >> "$T/log"; echo 0 > "$T/running"
[ -e "$T/bumped" ] || { : > "$T/bumped"; echo 6 > "$T/sys/class/net/wlan0/ifindex"; }
EOF
printf '#!/bin/sh\necho "udhcpc $*" >> "$T/log"\n' > "$T/bin/udhcpc"
chmod +x "$T/bin/killall" "$T/bin/udhcpc"; go ensure
[ "$(grep -c '^udhcpc -i wlan0' "$T/log")" = 2 ] || fail "recheck: $(cat "$T/log")"
[ "$(sed -n 3p "$T/log")" = "killall udhcpc" ] || fail "recheck: 2nd start without killing the 1st: $(cat "$T/log")"
[ "$(cat "$T/run/udhcpc.ifindex")" = 6 ] || fail "recheck: record=$(cat "$T/run/udhcpc.ifindex")"; rm -rf "$T"

# slow exit (je2d 6.4): the old client is busy in its hook script and exits
# ~1 s after SIGTERM. The new client must not start before it is gone.
setup 1 3 4
cat > "$T/bin/killall" <<'EOF'
#!/bin/sh
echo "killall $*" >> "$T/log"
case "$1" in -9) echo 0 > "$T/running" ;; *) ( /bin/sleep 1; echo 0 > "$T/running" ) & ;; esac
EOF
cat > "$T/bin/udhcpc" <<'EOF'
#!/bin/sh
echo "udhcpc $* old_running=$(cat "$T/running")" >> "$T/log"; echo 1 > "$T/running"
EOF
printf '#!/bin/sh\n/bin/sleep 0.1\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*; go ensure
grep -q '^udhcpc -i wlan0 old_running=0$' "$T/log" || fail "slow exit: new client started next to the old one: $(cat "$T/log")"
grep -q 'killall -9' "$T/log" && fail "slow exit: SIGKILLed a client that exits within 5 s"; rm -rf "$T"

# a client that never exits on SIGTERM is SIGKILLed (~5 s), then replaced
setup 1 3 4
cat > "$T/bin/killall" <<'EOF'
#!/bin/sh
echo "killall $*" >> "$T/log"; [ "$1" = -9 ] && echo 0 > "$T/running"; exit 0
EOF
cat > "$T/bin/udhcpc" <<'EOF'
#!/bin/sh
echo "udhcpc $* old_running=$(cat "$T/running")" >> "$T/log"; echo 1 > "$T/running"
EOF
printf '#!/bin/sh\n/bin/sleep 0.01\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*; go ensure
[ "$(sed -n 2p "$T/log")" = "killall -9 udhcpc" ] || fail "stuck client: no SIGKILL: $(cat "$T/log")"
[ "$(sed -n 3p "$T/log")" = "udhcpc -i wlan0 old_running=0" ] || fail "stuck client: $(cat "$T/log")"
grep -q "ignored SIGTERM" "$T/kmsg" || fail "stuck client: not logged"; rm -rf "$T"

# 10-ifindex hook: records the current wlan0's ifindex, ignores other ifaces/actions
T=$(mktemp -d); mkdir -p "$T/sys/class/net/wlan0" "$T/run"; echo 7 > "$T/sys/class/net/wlan0/ifindex"
sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g" "$HOOK" > "$T/hook"
interface=usb0 sh "$T/hook" bound;  [ -e "$T/run/udhcpc.ifindex" ] && fail "hook: recorded usb0"
interface=wlan0 sh "$T/hook" leasefail; [ -e "$T/run/udhcpc.ifindex" ] && fail "hook: recorded on leasefail"
interface=wlan0 sh "$T/hook" deconfig; [ "$(cat "$T/run/udhcpc.ifindex")" = 7 ] || fail "hook: deconfig not recorded"
rm -rf "$T"
echo "test_wifi_dhcp: all checks passed"
