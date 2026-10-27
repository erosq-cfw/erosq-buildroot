#!/bin/sh
# Host self-check: after wpa_supplicant or wlan0 (re)starts, a saved network
# must actually be joined. wpa_supplicant 2.12 drops an aborted scan without
# scheduling another (it then idles in DISCONNECTED), and `wpa_cli reconnect`
# is a no-op in that state, so every path that (re)starts wpa or wlan0 has to
# run wifi_join.sh, which REASSOCIATEs while wpa is idle.
#  1. wifi_join.sh decide table + worker against a stateful wpa_cli stub:
#     join phase, monitor phase (mid-session drop / ASSOC-REJECT idle), the
#     power mutex, and saved networks with disabled=1.
#  2. Path: wifi_up.sh (boot restore, UI Wi-Fi on, wifi_connect.sh) starts it
#     and no longer relies on `reconnect`; end to end with the real watcher.
#  3. Path: kernel re-probe (new wlan0 under a running wpa) -> mdev ->
#     wifi_dhcp.sh hotplug starts it; end to end with the real watcher.
#  4. Nothing shipped calls `wpa_cli reconnect` any more.
#  5. The 2.12 behaviour this relies on, pinned against the Buildroot source
#     when it is on this host (skipped otherwise).
# Run directly: sh tests/test_wifi_join.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
FILES=$HERE/package/erosq-board/files
JOIN="${SRC:-$FILES/usr/bin/wifi_join.sh}"
UP=$FILES/usr/bin/wifi_up.sh
DHCP=$FILES/usr/bin/wifi_dhcp.sh
fail() { echo "FAIL: $*"; exit 1; }

# --- 1a. pure decision table ----------------------------------------------------
d() { sh "$JOIN" decide "$1"; }
[ "$(d COMPLETED)" = done ]          || fail "COMPLETED -> done"
[ "$(d DISCONNECTED)" = kick ]       || fail "DISCONNECTED (idle after an aborted scan) -> kick"
[ "$(d INACTIVE)" = kick ]           || fail "INACTIVE -> kick"
[ "$(d '')" = gone ]                 || fail "no answer -> gone"
for s in SCANNING AUTHENTICATING ASSOCIATING ASSOCIATED 4WAY_HANDSHAKE GROUP_HANDSHAKE INTERFACE_DISABLED; do
	[ "$(d $s)" = wait ] || fail "$s -> wait"
done

# --- harness: a wpa_cli whose state a script can drive -------------------------
# $T/state  = current wpa_state ("" = wpa not running -> wpa_cli fails)
# $T/onkick = state to switch to on REASSOCIATE (absent = stay)
# $T/seq    = optional "state" lines consumed one per status poll
# $T/nets   = LIST_NETWORKS body (default: one enabled network)
setup() {
	T=$(mktemp -d); export T
	mkdir -p "$T/bin" "$T/run" "$T/usr/bin" "$T/sys/class/net/wlan0" "$T/sys/class/rfkill/rfkill0"
	: > "$T/log"; : > "$T/kmsg"; printf '%s' "${1-DISCONNECTED}" > "$T/state"
	printf '0\tHome\tany\t\n' > "$T/nets"
	cat > "$T/bin/wpa_cli" <<'EOF'
#!/bin/sh
for a; do last=$a; done
if [ "$last" = status ] && [ -s "$T/seq" ]; then head -n1 "$T/seq" | tr -d '\n' > "$T/state"; sed -i 1d "$T/seq"; fi
st=$(cat "$T/state")
case $last in
status) [ -n "$st" ] || exit 1; echo "wpa_state=$st" ;;
list_networks) [ -n "$st" ] || exit 1; echo "network id / ssid / bssid / flags"; cat "$T/nets" ;;
ping)   [ -n "$st" ] || exit 1; echo PONG ;;
reassociate)
	[ -n "$st" ] || exit 1; echo reassociate >> "$T/log"
	[ -e "$T/onkick" ] && cp "$T/onkick" "$T/state"; echo OK ;;
reconnect) echo reconnect >> "$T/log"; echo OK ;;
*) echo OK ;;
esac
EOF
	printf '#!/bin/sh\n/bin/sleep 0.02\n' > "$T/bin/sleep"
	chmod +x "$T/bin/"*
	sed -e "s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g" "$JOIN" > "$T/usr/bin/wifi_join.sh"; chmod +x "$T/usr/bin/wifi_join.sh"
}
worker() {  # runs the watcher in the foreground; rc in $RC. $1 = monitor rounds
	echo tok > "$T/run/wifi-join.gen"
	MON_MAX=${1:-1} PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" worker tok > /dev/null 2>&1; RC=$?
}
kicks() { grep -c '^reassociate' "$T/log"; }

# idle in DISCONNECTED (the device symptom): one REASSOCIATE joins
setup DISCONNECTED; echo COMPLETED > "$T/onkick"; worker
[ $RC = 0 ] && [ "$(kicks)" = 1 ] || fail "idle DISCONNECTED: rc=$RC kicks=$(kicks)"
grep -q 'joined after 1 reassociate' "$T/kmsg" || fail "idle: no kmsg line"; rm -rf "$T"

# already connected (UI restart with Wi-Fi up): leave the link alone
setup COMPLETED; worker
[ $RC = 0 ] && [ "$(kicks)" = 0 ] || fail "COMPLETED: rc=$RC kicks=$(kicks)"; rm -rf "$T"

# joining on its own (scanning/handshake): no kick
setup SCANNING; printf 'SCANNING\nASSOCIATING\n4WAY_HANDSHAKE\nCOMPLETED\n' > "$T/seq"; worker
[ $RC = 0 ] && [ "$(kicks)" = 0 ] || fail "in progress: rc=$RC kicks=$(kicks)"; rm -rf "$T"

# re-probe: INTERFACE_DISABLED while wlan0 is re-created, then idle -> kick
setup INTERFACE_DISABLED; printf 'INTERFACE_DISABLED\nINTERFACE_DISABLED\nDISCONNECTED\n' > "$T/seq"
echo COMPLETED > "$T/onkick"; worker
[ $RC = 0 ] && [ "$(kicks)" = 1 ] || fail "re-probe: rc=$RC kicks=$(kicks)"; rm -rf "$T"

# hotplug runs before wifi_up.sh has started wpa: wait for it, then kick
setup ''; printf '\n\nDISCONNECTED\n' > "$T/seq"; echo COMPLETED > "$T/onkick"; worker
[ $RC = 0 ] && [ "$(kicks)" = 1 ] || fail "wpa starting late: rc=$RC kicks=$(kicks)"; rm -rf "$T"

# the kick fails to join (AP out of range): bounded kicks, LOUD, keeps monitoring
setup DISCONNECTED; worker 1
[ $RC = 0 ] || fail "never joins: rc=$RC"
k=$(kicks); [ "$k" -ge 2 ] && [ "$k" -le 5 ] || fail "never joins: $k kicks in 30 s (want 2..5, held off between)"
grep -q 'not associated after 30 s (wpa_state=DISCONNECTED.*monitoring' "$T/kmsg" || fail "never joins: not loud ($(cat "$T/kmsg"))"; rm -rf "$T"

# --- 1b. monitor phase: mid-session drop / ASSOC-REJECT, wpa then idle --------
# (device: COMPLETED at 2 s, DISCONNECTED at 6 s, no retry in 150 s)
setup COMPLETED; printf 'COMPLETED\nDISCONNECTED\nDISCONNECTED\n' > "$T/seq"; echo COMPLETED > "$T/onkick"
worker 4
[ $RC = 0 ] && [ "$(kicks)" = 1 ] || fail "drop then idle: rc=$RC kicks=$(kicks)"
grep -q 'idle in DISCONNECTED for >= 30 s, reassociate' "$T/kmsg" || fail "drop then idle: no kmsg line"; rm -rf "$T"
# idle on ONE check only (wpa retrying by itself): leave it alone
setup COMPLETED; printf 'COMPLETED\nDISCONNECTED\nSCANNING\nDISCONNECTED\nCOMPLETED\nINACTIVE\n' > "$T/seq"; worker 5
[ $RC = 0 ] && [ "$(kicks)" = 0 ] || fail "transient idle kicked: kicks=$(kicks)"; rm -rf "$T"
# monitor checks are MON (30) s apart by default -- no busy polling
grep -q '^MON=${MON:-30}' "$JOIN" || fail "monitor interval is not 30 s"
# Wi-Fi off during the monitor phase: normal end, before the round limit
setup COMPLETED; printf 'COMPLETED\nCOMPLETED\n\n' > "$T/seq"; worker 0
[ $RC = 0 ] && [ "$(kicks)" = 0 ] || fail "monitor wpa gone: rc=$RC"; rm -rf "$T"

# --- 1c. saved networks with disabled=1 -----------------------------------------
# only a disabled entry: nothing to join, no kicks, no false alarm
setup DISCONNECTED; printf '0\tthrowaway\tany\t[DISABLED]\n' > "$T/nets"; worker 2
[ "$(kicks)" = 0 ] || fail "disabled-only: kicked $(kicks)x"
grep -q 'not associated' "$T/kmsg" && fail "disabled-only: false alarm"; rm -rf "$T"
# a disabled entry next to an enabled one does not stop the enabled one
setup DISCONNECTED; printf '0\tthrowaway\tany\t[DISABLED]\n1\tCafe Guest\tany\t\n' > "$T/nets"
echo COMPLETED > "$T/onkick"; worker
[ $RC = 0 ] && [ "$(kicks)" = 1 ] || fail "disabled+enabled: kicks=$(kicks)"; rm -rf "$T"

# --- 1d. power mutex: never kick during a wifi_up/wifi_down transition ---------
setup DISCONNECTED; mkdir "$T/run/wifi-power.lock"; echo COMPLETED > "$T/onkick"
( echo tok > "$T/run/wifi-join.gen"; MON_MAX=1 PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" worker tok >/dev/null 2>&1 ) &
/bin/sleep 0.15; [ "$(kicks)" = 0 ] || fail "kicked while the power lock was held"
rmdir "$T/run/wifi-power.lock"; wait
[ "$(kicks)" = 1 ] || fail "no kick after the power lock was released ($(kicks))"
[ -d "$T/run/wifi-power.lock" ] && fail "watcher left the power lock behind"; rm -rf "$T"

# Wi-Fi turned off mid-watch (wpa killed): stop, loudly
setup DISCONNECTED; printf 'SCANNING\n\n' > "$T/seq"; worker
[ $RC = 1 ] && [ "$(kicks)" = 0 ] || fail "wpa gone: rc=$RC kicks=$(kicks)"
grep -q 'went away' "$T/kmsg" || fail "wpa gone: not loud"; rm -rf "$T"

# wpa never comes up: loud
setup ''; worker
[ $RC = 1 ] && grep -q 'never answered' "$T/kmsg" || fail "wpa never up: rc=$RC $(cat "$T/kmsg")"; rm -rf "$T"

# superseded by a newer start: exits quietly, no kick
setup DISCONNECTED; echo other > "$T/run/wifi-join.gen"
PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" worker tok >/dev/null 2>&1; RC=$?
[ $RC = 0 ] && [ "$(kicks)" = 0 ] || fail "superseded: rc=$RC kicks=$(kicks)"; rm -rf "$T"

# `start` returns at once and the detached watcher does the work
setup DISCONNECTED; echo COMPLETED > "$T/onkick"
PATH="$T/bin:$PATH" sh "$T/usr/bin/wifi_join.sh" start || fail "start rc"
i=0; while [ $i -lt 100 ] && ! grep -q joined "$T/kmsg"; do /bin/sleep 0.05; i=$((i+1)); done
[ "$(kicks)" = 1 ] || fail "start: watcher did not kick ($(kicks))"; rm -rf "$T"

# --- 2. path: wifi_up.sh (boot / UI on / wifi_connect.sh) -----------------------
grep -q '^/usr/bin/wifi_join.sh start$' "$UP" || fail "wifi_up.sh does not start wifi_join.sh"
setup DISCONNECTED; echo COMPLETED > "$T/onkick"
echo erosq-wifi-power > "$T/sys/class/rfkill/rfkill0/name"; echo 0 > "$T/sys/class/rfkill/rfkill0/soft"
echo 1 > "$T/run/wifi-want"
for c in ifconfig iw udhcpc killall; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pidof"   # wpa_supplicant already running
printf '#!/bin/sh\nexit 0\n' > "$T/usr/bin/wifi_dhcp.sh"
chmod +x "$T/bin/"* "$T/usr/bin/wifi_dhcp.sh"
sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/data/|$T/data/|g; s|/var/run/|$T/run/|g; s|/usr/bin/|$T/usr/bin/|g" \
	"$UP" > "$T/wifi_up.sh"
PATH="$T/bin:$PATH" sh "$T/wifi_up.sh" > "$T/out" 2>&1 || fail "wifi_up rc=$? $(cat "$T/out")"
i=0; while [ $i -lt 100 ] && ! grep -q joined "$T/kmsg"; do /bin/sleep 0.05; i=$((i+1)); done
grep -q '^reconnect' "$T/log" && fail "wifi_up.sh still sends reconnect"
[ "$(kicks)" = 1 ] || fail "wifi_up.sh: idle wpa not kicked (kicks=$(kicks); $(cat "$T/kmsg"))"; rm -rf "$T"

# --- 3. path: re-probe -> mdev -> wifi_dhcp.sh hotplug --------------------------
grep -q '@/usr/bin/wifi_dhcp.sh hotplug' "$FILES/etc/mdev.conf" || fail "mdev no longer runs wifi_dhcp.sh hotplug on wlan0"
setup DISCONNECTED; echo COMPLETED > "$T/onkick"; echo 4 > "$T/sys/class/net/wlan0/ifindex"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pidof"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/udhcpc"; chmod +x "$T/bin/"*
sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/usr/bin/|$T/usr/bin/|g" "$DHCP" > "$T/wifi_dhcp.sh"
PATH="$T/bin:$PATH" sh "$T/wifi_dhcp.sh" hotplug || fail "hotplug rc"
i=0; while [ $i -lt 100 ] && ! grep -q joined "$T/kmsg"; do /bin/sleep 0.05; i=$((i+1)); done
[ "$(kicks)" = 1 ] || fail "hotplug: idle wpa not kicked after a new wlan0 (kicks=$(kicks))"
i=0; while [ $i -lt 100 ] && [ -e "$T/run/wifi-dhcp.gen" ] && pgrep -f "$T/wifi_dhcp.sh worker" >/dev/null; do /bin/sleep 0.05; i=$((i+1)); done
rm -rf "$T"

# --- 4. nobody relies on reconnect any more -------------------------------------
grep -rn 'wpa_cli.*reconnect' "$FILES" | grep -v ':[0-9]*:[[:space:]]*#' | grep . && fail "a shipped script still uses wpa_cli reconnect (no-op when idle)"

# --- 5. the 2.12 behaviour this relies on --------------------------------------
WS=$(ls -d "${BR:-$HERE/../buildroot-2026.08}"/output/build/wpa_supplicant-2.12/wpa_supplicant 2>/dev/null | head -1)
if [ -n "$WS" ]; then
	grep -A4 '"RECONNECT") == 0' "$WS/ctrl_iface.c" | grep -q 'else if (wpa_s->disconnected)' \
		|| fail "2.12 source: RECONNECT is no longer gated on wpa_s->disconnected (re-check the rationale)"
	grep -A3 'os_strcmp(buf, "REASSOCIATE") == 0' "$WS/ctrl_iface.c" | grep -q 'wpas_request_connection\|WPA_INTERFACE_DISABLED' \
		|| fail "2.12 source: REASSOCIATE no longer requests a connection"
	grep -A3 'data->scan_info.aborted) {' "$WS/events.c" | grep -q 'goto scan_work_done' \
		|| fail "2.12 source: aborted scans now handled differently (re-check the rationale)"
else
	echo "SKIP: 2.12 source pin (no buildroot-2026.08 wpa_supplicant-2.12 build dir)"
fi
echo "test_wifi_join: all checks passed"
