#!/bin/sh
# Host self-check: Wi-Fi networks saved from the UI must survive a reboot.
#  1. S05mounts' first-boot seed: creates /data/etc/wpa_supplicant.conf from the
#     RO skeleton (update_config=1 + ctrl_interface), mode 600; keeps a conf that
#     already has update_config=1 (user networks) but tightens it to 600; replaces
#     a legacy conf without update_config=1.
#  2. wifi_up.sh starts wpa_supplicant with -c on the REAL /data file, not the /etc
#     symlink (SAVE_CONFIG writes "<-c>.tmp-XXXX" next to -c; /etc is RO squashfs).
#  3. Real SAVE_CONFIG with the host wpa_supplicant (driver "none" on a dummy
#     netdev) inside `unshare -rnm`, with etc/ bind-mounted READ-ONLY holding the
#     same symlink post-build.sh bakes: the old /etc -c path must FAIL (negative
#     control: the harness reproduces the device bug), the -c path wifi_up.sh
#     uses must succeed, persist the network and keep mode 600. Skipped (loudly)
#     when the host lacks wpa_supplicant/unshare.
# Run directly: sh tests/test_wifi_conf_persist.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
FILES=$HERE/package/erosq-board/files
S05="${S05:-$FILES/etc/init.d/S05mounts}"
UP="${SRC:-$FILES/usr/bin/wifi_up.sh}"
DEF=$FILES/etc/wpa_supplicant.conf.default
fail() { echo "FAIL: $*"; exit 1; }
mode() { stat -c %a "$1"; }

grep -q '^update_config=1$' "$DEF" || fail "skeleton lacks update_config=1"
grep -q '^ctrl_interface=/var/run/wpa_supplicant$' "$DEF" || fail "skeleton lacks ctrl_interface"
grep -q 'network=' "$DEF" && fail "skeleton carries a network block"

# --- 1. first-boot seed (the S05mounts block, paths redirected) ---------------
seed() {  # runs S05mounts' wpa seed block against $T/data, $T/etc
	grep -q 'chmod 600 /data/etc/wpa_supplicant.conf' "$S05" || fail "S05mounts does not chmod 600 the conf"
	sed -n '/# Seed wpa_supplicant.conf/,/chmod 600 \/data\/etc\/wpa_supplicant.conf/p' "$S05" \
		| sed "s|/data/|@D@|g; s|/etc/|$T/etc/|g; s|@D@|$T/data/|g" > "$T/seed.sh"
	grep -q 'cp ' "$T/seed.sh" || fail "harness: seed block not found in S05mounts"
	(umask 022; sh "$T/seed.sh")
}
setup() { T=$(mktemp -d); mkdir -p "$T/data/etc" "$T/etc"; cp "$DEF" "$T/etc/wpa_supplicant.conf.default"; }
C() { echo "$T/data/etc/wpa_supplicant.conf"; }

setup; seed   # first boot: nothing there
	[ -f "$(C)" ] || fail "seed: not created"
	cmp -s "$(C)" "$DEF" || fail "seed: content != skeleton"
	[ "$(mode "$(C)")" = 600 ] || fail "seed: mode $(mode "$(C)") != 600"; rm -rf "$T"
setup; printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n\nnetwork={\n\tssid="home"\n\tpsk="secret12"\n}\n' > "$(C)"
	chmod 644 "$(C)"; cp "$(C)" "$T/keep"; seed
	cmp -s "$(C)" "$T/keep" || fail "seed: clobbered a conf holding user networks"
	[ "$(mode "$(C)")" = 600 ] || fail "seed: existing conf left at $(mode "$(C)")"; rm -rf "$T"
setup; printf 'ctrl_interface=/var/run/wpa_supplicant\nnetwork={\n\tkey_mgmt=NONE\n}\n' > "$(C)"; seed
	cmp -s "$(C)" "$DEF" || fail "seed: legacy conf (no update_config) not replaced"
	[ "$(mode "$(C)")" = 600 ] || fail "seed: legacy replacement mode $(mode "$(C)")"; rm -rf "$T"

# --- 2. wifi_up.sh's -c path (harness as in test_wifi_up_noreprobe.sh) --------
T=$(mktemp -d); export T
mkdir -p "$T/bin" "$T/sys/class/net/wlan0" "$T/sys/class/rfkill/rfkill0" "$T/run" "$T/usr/bin"
echo erosq-wifi-power > "$T/sys/class/rfkill/rfkill0/name"; echo 0 > "$T/sys/class/rfkill/rfkill0/soft"
echo 1 > "$T/run/wifi-want"
for c in ifconfig iw udhcpc killall sleep; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
printf '#!/bin/sh\nexit 1\n' > "$T/bin/pidof"   # no wpa_supplicant running yet
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$T/wpa.args"\n' > "$T/bin/wpa_supplicant"
printf '#!/bin/sh\necho PONG\n' > "$T/bin/wpa_cli"
printf '#!/bin/sh\nexit 0\n' > "$T/usr/bin/wifi_dhcp.sh"
chmod +x "$T/bin/"* "$T/usr/bin/wifi_dhcp.sh"
# /etc/ is NOT redirected: a -c under /etc must show up as such
sed -e "s|/sys/|$T/sys/|g; s|/run/|$T/run/|g; s|/dev/kmsg|$T/kmsg|g; s|/data/|$T/data/|g; s|/var/run/|$T/run/|g; s|/usr/bin/wifi_dhcp.sh|$T/usr/bin/wifi_dhcp.sh|g" \
	"$UP" > "$T/wifi_up.sh"
PATH="$T/bin:$PATH" sh "$T/wifi_up.sh" > "$T/out" 2>&1 || fail "wifi_up: rc=$? $(cat "$T/out")"
[ -s "$T/wpa.args" ] || fail "wifi_up: wpa_supplicant not started"
CPATH=$(sed -n '/^-c$/{n;p;}' "$T/wpa.args")
[ "$CPATH" = "$T/data/etc/wpa_supplicant.conf" ] || fail "wifi_up: wpa_supplicant -c '$CPATH', want /data/etc/wpa_supplicant.conf"
CPATH=/data/etc/wpa_supplicant.conf   # un-redirected, for part 3
rm -rf "$T"

# --- 3. real SAVE_CONFIG through the shipped layout ---------------------------
WPA=$(command -v wpa_supplicant || ls /usr/sbin/wpa_supplicant /sbin/wpa_supplicant 2>/dev/null | head -1)
WCLI=$(command -v wpa_cli || ls /usr/sbin/wpa_cli /sbin/wpa_cli 2>/dev/null | head -1)
if [ -z "$WPA" ] || [ -z "$WCLI" ] || ! unshare -rnm true 2>/dev/null; then
	echo "SKIP: SAVE_CONFIG part (needs host wpa_supplicant, wpa_cli and unprivileged unshare -rnm)"
	echo "test_wifi_conf_persist: seed + -c path checks passed"; exit 0
fi
T=$(mktemp -d)
mkdir -p "$T/data/etc" "$T/etc" "$T/ctrl"
(umask 077; sed "s|^ctrl_interface=.*|ctrl_interface=$T/ctrl|" "$DEF" > "$T/data/etc/wpa_supplicant.conf")
ln -s "$T/data/etc/wpa_supplicant.conf" "$T/etc/wpa_supplicant.conf"   # as post-build.sh bakes it
cat > "$T/ns.sh" <<EOF
umask 022   # init's umask on the device
mount --bind "$T/etc" "$T/etc" && mount -o remount,bind,ro "$T/etc" || exit 90
touch "$T/etc/probe" 2>/dev/null && exit 91      # must really be read-only
ip link add wlan0 type dummy && ip link set wlan0 up || exit 92
try() {  # \$1 = -c path; prints SAVE_CONFIG's reply
	"$WPA" -D none -i wlan0 -c "\$1" > "$T/wpa.log" 2>&1 & p=\$!
	i=0; while [ \$i -lt 50 ] && ! [ -S "$T/ctrl/wlan0" ]; do sleep 0.1; i=\$((i+1)); done
	n=\$("$WCLI" -p "$T/ctrl" -i wlan0 add_network)
	"$WCLI" -p "$T/ctrl" -i wlan0 set_network \$n ssid '"erosq-test"' >/dev/null
	"$WCLI" -p "$T/ctrl" -i wlan0 set_network \$n psk '"secret123"' >/dev/null
	"$WCLI" -p "$T/ctrl" -i wlan0 save_config
	kill \$p; wait \$p 2>/dev/null; rm -f "$T/ctrl/wlan0"
}
echo "old=\$(try "$T/etc/wpa_supplicant.conf")"
echo "new=\$(try "$T$CPATH")"
EOF
unshare -rnm sh "$T/ns.sh" > "$T/res" 2>&1; rc=$?
[ "$rc" = 0 ] || fail "SAVE_CONFIG harness rc=$rc: $(cat "$T/res")"
grep -qx 'old=FAIL' "$T/res" || fail "negative control: SAVE_CONFIG via the RO /etc symlink did not fail ($(cat "$T/res")) -- harness no longer reproduces the bug"
grep -qx 'new=OK' "$T/res" || fail "SAVE_CONFIG via wifi_up.sh's -c path: $(cat "$T/res")"
F=$T/data/etc/wpa_supplicant.conf
grep -q 'ssid="erosq-test"' "$F" || fail "saved network not in $F"
[ "$(grep -c '^network={' "$F")" = 1 ] || fail "expected exactly 1 saved network"
grep -q '^update_config=1$' "$F" || fail "update_config=1 lost on save"
grep -q '^ctrl_interface=' "$F" || fail "ctrl_interface lost on save"
# 2.11+ (the target runs 2.12) creates the temp file under umask 077 and copies the
# old file's mode (| u+rw), so the seed's 600 sticks; <= 2.10 just uses the umask.
WV=$("$WPA" -v 2>/dev/null | sed -n 's/^wpa_supplicant v\([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)
if [ -n "$WV" ] && [ "$(echo "$WV" | awk '{print ($1*100+$2 >= 211)}')" = 1 ]; then
	[ "$(mode "$F")" = 600 ] || fail "mode after SAVE_CONFIG $(mode "$F") != 600"
else
	echo "NOTE: host wpa_supplicant $(echo "${WV:-?}" | tr " " .) predates the 2.11 mode-keeping save; post-save mode not checked (seed mode is)"
fi
ls "$T/data/etc" | grep -q 'tmp-' && fail "temp file left behind"
rm -rf "$T"
echo "test_wifi_conf_persist: all checks passed"
