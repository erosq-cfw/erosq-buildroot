#!/bin/sh
# Host self-check (real wpa_supplicant): joining network B the way erosq-ui
# does keeps network A saved AND enabled in /data/etc/wpa_supplicant.conf, a
# user-disabled block stays disabled, and after a wpa_supplicant restart (=
# reboot) all are back with no unwanted disabled=1.
# erosq-ui's join (src/ui_net.c wpa_join_start / wpa_join_poll): ADD + SET +
# SELECT the new block; once joined, ENABLE_NETWORK <each previously enabled>
# no-connect, then SAVE_CONFIG. SELECT_NETWORK disables every other block in
# memory: the negative control saves straight after SELECT and must show A as
# disabled=1, or this harness proves nothing. Driver "none" cannot associate,
# so "joined" is the step between SELECT and the save.
# Same harness as tests/test_wifi_conf_persist.sh part 3 (host wpa_supplicant,
# driver none on a dummy wlan0, unshare -rnm). Skipped (loudly) without them.
# Run directly: sh tests/test_wifi_join_persist.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DEF=$HERE/package/erosq-board/files/etc/wpa_supplicant.conf.default
fail() { echo "FAIL: $*"; exit 1; }

WPA=$(command -v wpa_supplicant || ls /usr/sbin/wpa_supplicant /sbin/wpa_supplicant 2>/dev/null | head -1)
WCLI=$(command -v wpa_cli || ls /usr/sbin/wpa_cli /sbin/wpa_cli 2>/dev/null | head -1)
if [ -z "$WPA" ] || [ -z "$WCLI" ] || ! unshare -rnm true 2>/dev/null; then
	echo "SKIP: needs host wpa_supplicant, wpa_cli and unprivileged unshare -rnm"; exit 0
fi
T=$(mktemp -d)
mkdir -p "$T/data/etc" "$T/ctrl"
F=$T/data/etc/wpa_supplicant.conf
(umask 077; sed "s|^ctrl_interface=.*|ctrl_interface=$T/ctrl|" "$DEF" > "$F")
printf '\nnetwork={\n\tssid="Cafe Guest"\n\tkey_mgmt=NONE\n}\n\nnetwork={\n\tssid="throwaway"\n\tkey_mgmt=NONE\n\tdisabled=1\n}\n' >> "$F"
cat > "$T/ns.sh" <<EOF
ip link add wlan0 type dummy && ip link set wlan0 up || exit 92
W() { "$WCLI" -p "$T/ctrl" -i wlan0 "\$@" < /dev/null; }
start() { "$WPA" -D none -i wlan0 -c "$F" > "$T/wpa.log" 2>&1 & p=\$!
	i=0; while [ \$i -lt 50 ] && ! [ -S "$T/ctrl/wlan0" ]; do sleep 0.1; i=\$((i+1)); done
	[ -S "$T/ctrl/wlan0" ] || { echo "wpa_supplicant did not start: \$(cat "$T/wpa.log")"; exit 93; }; }
stop() { kill \$p; wait \$p 2>/dev/null; rm -f "$T/ctrl/wlan0"; }
start
W list_networks > "$T/before"
n=\$(W add_network)
W set_network \$n ssid 486f6d65 >/dev/null              # "Home", hex as the UI sends it
W set_network \$n psk '"homehome1"' >/dev/null
W set_network \$n scan_ssid 1 >/dev/null
W select_network \$n >/dev/null
cp "$F" "$T/f0"; W save_config >/dev/null; cp "$F" "$T/neg"; cp "$T/f0" "$F"   # negative control
for e in \$(sed 1d "$T/before" | grep -v 'DISABLED' | cut -f1); do
	W enable_network \$e no-connect >/dev/null
done
echo "save=\$(W save_config)"
stop
start                                                     # "after a reboot"
W list_networks > "$T/after"
stop
EOF
timeout 60 unshare -rnm sh "$T/ns.sh" > "$T/res" 2>&1; rc=$?
[ "$rc" = 0 ] || fail "harness rc=$rc: $(cat "$T/res")"
grep -qx 'save=OK' "$T/res" || fail "SAVE_CONFIG: $(cat "$T/res")"
blk() { awk -v s="ssid=\"$2\"" '/^network=/{b=""} {b=b $0 "\n"} index($0, s){f=1} /^}/{if (f) printf "%s", b; f=0}' "$1"; }
# negative control: saving right after SELECT persists Cafe Guest as disabled=1
blk "$T/neg" "Cafe Guest" | grep -q 'disabled=1' \
	|| fail "negative control: SELECT_NETWORK + SAVE_CONFIG did not persist disabled=1 -- harness no longer reproduces the bug"
[ "$(grep -c '^network={' "$F")" = 3 ] || fail "expected 3 networks in the file: $(cat "$F")"
blk "$F" "Cafe Guest" | grep -q . || fail "Cafe Guest lost from the file"
blk "$F" "Home" | grep -q . || fail "Home not saved"
blk "$F" "Cafe Guest" | grep -q 'disabled=1' && fail "Cafe Guest saved with disabled=1"
blk "$F" "Home" | grep -q 'disabled=1' && fail "Home saved with disabled=1"
blk "$F" "throwaway" | grep -q 'disabled=1' || fail "the user-disabled network was re-enabled"
# after a restart: all three back; Cafe Guest + Home enabled, throwaway still disabled
[ "$(sed 1d "$T/after" | wc -l)" = 3 ] || fail "restart: $(cat "$T/after")"
row() { sed 1d "$T/after" | awk -F'\t' -v s="$1" '$2 == s'; }
row "Cafe Guest" | grep -q . && ! row "Cafe Guest" | grep -q DISABLED || fail "restart: Cafe Guest missing or disabled ($(cat "$T/after"))"
row "Home" | grep -q . && ! row "Home" | grep -q DISABLED || fail "restart: Home missing or disabled ($(cat "$T/after"))"
row "throwaway" | grep -q DISABLED || fail "restart: throwaway enabled"
rm -rf "$T"
echo "test_wifi_join_persist: all checks passed"
