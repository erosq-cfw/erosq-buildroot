#!/usr/bin/env bash
# Host runs of the installer's init against a fake unit: stub device tools,
# fake MTD partitions (plain files) and a fake card (a directory). init and
# install-lib.sh are copied with their absolute paths moved under the unit's
# directory; nothing else in them changes.
# Run: bash tests/test_installer_init.sh
# (bash only: under dash the {a,b} mkdir below makes one literal directory and
# every later step cascades into "Directory nonexistent")
[ -n "${BASH_VERSION:-}" ] || { echo "FAIL: needs bash, not sh (run: bash $0)"; exit 1; }
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
I=$HERE/../board/erosq/installer
TIMEOUT=$(command -v timeout)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ck() { # ck <desc> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass+1))
	else fail=$((fail+1)); printf 'FAIL: %s\n      expected: [%s]\n      actual:   [%s]\n' "$1" "$2" "$3"; fi
}
yes_() { if "$@"; then echo yes; else echo no; fi; }

# mkunit <dir>: a unit with the stock bootloader (no abselect in `uboot`)
mkunit() {
	local R=$1 i=0 p n sz
	mkdir -p "$R"/{bin,mnt,iso,dev/input,sys/class/mtd,sys/class/ubi,sys/class/input,proc/sys/vm}
	[ -d "$R/bin" ] && [ -d "$R/dev/input" ] || { echo "FAIL: mkunit: could not lay out $R"; exit 1; }
	for p in spl:131072 uboot:1048576 uboot-env:65536 ubi:4194304 wholechip:134217728 stockof:6291456; do
		n=${p%%:*}; sz=${p#*:}
		mkdir -p "$R/sys/class/mtd/mtd$i"
		echo "$n" > "$R/sys/class/mtd/mtd$i/name"
		echo "$sz" > "$R/sys/class/mtd/mtd$i/size"
		echo 0 > "$R/sys/class/mtd/mtd$i/bad_blocks"
		truncate -s "$sz" "$R/dev/mtd$i"
		[ "$n" = wholechip ] && printf 'FACTORY' | dd of="$R/dev/mtd$i" conv=notrunc status=none
		i=$((i+1))
	done
	echo x > "$R/uboot-initial-env"
	sed -e "s#/sys/#$R/sys/#g" "$I/install-lib.sh" > "$R/install-lib.sh"
	sed -e "s#/dev/kmsg#$R/kmsg#g" -e "s#/dev/null#@NULL@#g" -e "s#/dev/tty0#$R/tty#g" \
	    -e "s#\([ \"=]\)/dev/#\1$R/dev/#g" -e "s#@NULL@#/dev/null#g" \
	    -e "s#/sys/#$R/sys/#g" -e "s#/proc/sys/#$R/proc/sys/#g" \
	    -e "s#^SD=/mnt#SD=$R/mnt#" -e "s#\([ \"]\)/iso#\1$R/iso#g" \
	    -e "s#\. /install-lib.sh#. $R/install-lib.sh#" \
	    -e "s#/uboot-initial-env#$R/uboot-initial-env#g" "$I/init" > "$R/init"
	stub() { printf '#!/usr/bin/env bash\nR=%s\n%s\n' "$R" "$2" > "$R/bin/$1"; chmod +x "$R/bin/$1"; }
	stub mount 'case "$*" in *iso9660*) s=${@: -2:1}; d=${@: -1}; rm -rf "$d"; cp -r "$s.d" "$d";; esac; exit 0'
	stub umount 'exit 0'; stub sync 'exit 0'; stub sleep 'exit 0'
	stub df 'echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "/dev/x 1 1 ${FREE:-999999} 1% /mnt"'
	stub nanddump 'f=; l=; while [ $# -gt 1 ]; do case $1 in -f) f=$2; shift 2;; -l) l=$2; shift 2;; *) shift;; esac; done
if [ -n "$f" ]; then cp --sparse=always "$1" "$f"; elif [ -n "$l" ]; then head -c "$l" "$1"; else cat "$1"; fi'
	stub flash_erase 'sz=$(stat -c%s "$1"); head -c "$sz" /dev/zero | tr "\0" "\377" > "$1"; echo "erase ${1##*/}" >> "$R/writes"'
	stub nandwrite 'dd if="$3" of="$2" conv=notrunc status=none; echo "write ${2##*/}" >> "$R/writes"'
	stub ubiformat 'dd if="$3" of="$1" conv=notrunc status=none; echo "ubiformat ${1##*/}" >> "$R/writes"'
	stub ubiattach 'for v in 0 1 3 4; do mkdir -p "$R/sys/class/ubi/ubi0_$v"; echo "vol$v" > "$R/sys/class/ubi/ubi0_$v/name"; done'
	stub ubidetach 'exit 0'; stub ubimkvol 'exit 0'; stub ubiupdatevol 'exit 0'
	stub fw_setenv 'exit 0'; stub fw_printenv 'echo boot_slot=a'
	# key presses come from $R/keys, one code per line (-code: a release);
	# none left = the menu's idle timeout
	stub timeout 'k=$(head -n1 "$R/keys" 2>/dev/null); [ -n "$k" ] || exit 124; sed -i 1d "$R/keys"
v=1; [ "${k#-}" != "$k" ] && { v=0; k=${k#-}; }
printf "\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x01\\x00\\x$(printf %02x $((k & 255)))\\x$(printf %02x $((k >> 8)))\\x0$v\\x00\\x00\\x00"'
	mkdir -p "$R/sys/class/input/event0/device"; echo gpio-keys > "$R/sys/class/input/event0/device/name"
	: > "$R/dev/input/event0"; : > "$R/keys"
	stub reboot 'echo reboot > "$R/action"; kill -KILL $PPID'
	stub poweroff 'echo poweroff > "$R/action"; kill -KILL $PPID'
	: > "$R/writes"
	# the AXP2101 battery: full, on battery power
	mkdir -p "$R/sys/class/power_supply/axp2101-battery"
	echo 100 > "$R/sys/class/power_supply/axp2101-battery/capacity"
	echo Discharging > "$R/sys/class/power_supply/axp2101-battery/status"
}

# mkupt <dir>: our update.upt at the card root (the mount stub serves the
# .d directory as the mounted ISO)
mkupt() {
	local R=$1 d=$1/mnt/update.upt.d
	mkdir -p "$d"; : > "$R/mnt/update.upt"
	head -c 300000 /dev/urandom > "$d/uimage.bin"
	printf 'UBI#..kernel..rootfs..kernel_b..rootfs_b' > "$d/nand.ubi"
	printf 'spl' > "$d/ourspl.bin"
	printf 'u-boot..abselect..' > "$d/ouruboot.bin"
	(cd "$d" && md5sum nand.ubi ourspl.bin ouruboot.bin > payload.md5)
	printf 'kernel={\n        name=kernel\n        file_path=autoupdate/uimage.bin\n        md5=%s\n}\n' \
		"$(md5sum < "$d/uimage.bin" | cut -d' ' -f1)" > "$d/update.txt"
}

# boot <dir>: run init once; prints what it did at the end (reboot|poweroff)
boot() {
	local R=$1
	rm -f "$R/action"
	PATH="$R/bin:$PATH" "$TIMEOUT" 120 sh "$R/init" >/dev/null 2>&1
	cat "$R/action" 2>/dev/null
}

E=erosq-install

# --- upt: a stock unit, a card with only update.upt ---------------------------
R=$T/upt; mkunit "$R"; mkupt "$R"
ck "upt: reboots after the install" reboot "$(boot "$R")"
ck "upt: PASS recorded" yes "$(yes_ grep -q '^PASS|upt|' "$R/mnt/$E/result.txt")"
ck "upt: mode file removed on PASS" no "$(yes_ test -e "$R/mnt/$E/mode")"
ck "upt: retry marker removed on PASS" no "$(yes_ test -e "$R/mnt/$E/.attempted")"
ck "upt: no erosq.itb left at the root" no "$(yes_ test -e "$R/mnt/erosq.itb")"
ck "upt: the installer kept as $E/installer.uImage" yes \
	"$(yes_ cmp -s "$R/mnt/update.upt.d/uimage.bin" "$R/mnt/$E/installer.uImage")"
ck "upt: drop-itb says where it went" yes \
	"$(yes_ grep -q '^PASS|drop-itb|erosq.itb moved to erosq-install/installer.uImage' "$R/mnt/$E/result.txt")"

# --- install (developer card) ---------------------------------------------------
R=$T/inst; mkunit "$R"; mkdir -p "$R/mnt/$E"; echo install > "$R/mnt/$E/mode"
printf 'UBI#..kernel..rootfs..kernel_b..rootfs_b' > "$R/mnt/$E/nand.ubi"
printf 'spl' > "$R/mnt/$E/our-spl.bin"; printf 'u-boot..abselect..' > "$R/mnt/$E/our-uboot.bin"
(cd "$R/mnt/$E" && md5sum nand.ubi our-spl.bin our-uboot.bin > md5sums)
ck "install: reboots after the install" reboot "$(boot "$R")"
ck "install: PASS recorded" yes "$(yes_ grep -q '^PASS|install|' "$R/mnt/$E/result.txt")"
ck "install: mode file removed on PASS" no "$(yes_ test -e "$R/mnt/$E/mode")"

# --- restore --------------------------------------------------------------------
R=$T/rest; mkunit "$R"; mkdir -p "$R/mnt/$E"; echo restore > "$R/mnt/$E/mode"
truncate -s 134217728 "$R/mnt/$E/flash.img"
ck "restore: reboots after the restore" reboot "$(boot "$R")"
ck "restore: PASS recorded" yes "$(yes_ grep -q '^PASS|restore|' "$R/mnt/$E/result.txt")"
ck "restore: mode file removed on PASS" no "$(yes_ test -e "$R/mnt/$E/mode")"

# --- a failed run keeps its mode file (the retry needs it) ------------------------
R=$T/fail; mkunit "$R"; mkupt "$R"
echo other > "$R/mnt/erosq.itb"
ck "upt with a foreign erosq.itb: powers off" poweroff "$(boot "$R")"
ck "upt FAIL keeps the mode file" upt "$(cat "$R/mnt/$E/mode" 2>/dev/null)"
ck "upt FAIL wrote nothing" "" "$(cat "$R/writes")"

# --- rescue: our U-Boot on the chip, no mode file ---------------------------------
# The unit from the upt run above: our U-Boot is on it, update.upt is still
# at the card root, the mode file is gone.
R=$T/upt; S=$R/mnt/$E
cp "$R/writes" "$T/w0"
ck "rescue, no key: powers off" poweroff "$(boot "$R")"
ck "rescue, no key: no install from the update.upt on the card" "$(cat "$T/w0")" "$(cat "$R/writes")"
ck "rescue, no key: no mode file written" no "$(yes_ test -e "$S/mode")"
ck "rescue, no key: menu then idle in result.txt" "INFO|rescue|no mode file, booted by our U-Boot: rescue menu
INFO|rescue|no key for 120 s (powering off)" "$(tail -n2 "$S/result.txt")"

# Play on Reinstall, then Back at the confirm: nothing is written
printf '164\n-164\n158\n' > "$R/keys"
ck "rescue, cancel: powers off at idle" poweroff "$(boot "$R")"
ck "rescue, cancel: nothing written" "$(cat "$T/w0")" "$(cat "$R/writes")"
ck "rescue, cancel: no mode file" no "$(yes_ test -e "$S/mode")"

# Uninstall without stock.upt: the menu says so and comes back
printf '114\n114\n164\n164\n' > "$R/keys"
ck "rescue, uninstall without its files: powers off at idle" poweroff "$(boot "$R")"
ck "rescue, uninstall without its files: nothing written" "$(cat "$T/w0")" "$(cat "$R/writes")"
ck "rescue, uninstall without its files: no mode file" no "$(yes_ test -e "$S/mode")"

# Power off from the menu (Prev wraps from the top to the last item)
printf '165\n164\n' > "$R/keys"
ck "rescue, power off chosen" poweroff "$(boot "$R")"
ck "rescue, power off chosen: recorded" "INFO|rescue|power off chosen" "$(tail -n1 "$S/result.txt")"

# Reinstall, confirmed: runs as mode=upt through every gate
printf '164\n-164\n164\n' > "$R/keys"
ck "rescue, reinstall: reboots after the install" reboot "$(boot "$R")"
ck "rescue, reinstall: chosen" yes "$(yes_ grep -q '^INFO|rescue|chose reinstall (mode=upt)$' "$S/result.txt")"
ck "rescue, reinstall: PASS" yes "$(yes_ grep -q '^PASS|upt|' "$S/result.txt")"
ck "rescue, reinstall: wrote the chip again" yes "$(yes_ test "$(wc -l < "$R/writes")" -gt "$(wc -l < "$T/w0")")"
ck "rescue, reinstall: mode file removed on PASS" no "$(yes_ test -e "$S/mode")"
ck "rescue, reinstall: installer.uImage kept" yes "$(yes_ cmp -s "$R/mnt/update.upt.d/uimage.bin" "$S/installer.uImage")"

# USB drive mode with no USB device controller: says so, back to the menu
cp "$R/writes" "$T/w1"
printf '114\n114\n114\n164\n164\n' > "$R/keys"
ck "rescue, USB without a controller: powers off at idle" poweroff "$(boot "$R")"
ck "rescue, USB without a controller: nothing written" "$(cat "$T/w1")" "$(cat "$R/writes")"
ck "rescue, USB without a controller: no USB mode" no "$(yes_ grep -q 'USB drive mode' "$S/result.txt")"

# USB drive mode: the card goes on the gadget's LUN, comes back after
# (the fake event file reads empty, which ends the mode)
mkdir -p "$R/sys/class/udc/fake.usb"
G=$R/sys/kernel/config/usb_gadget/rescue
printf '114\n114\n114\n164\n' > "$R/keys"
ck "rescue, USB drive mode: powers off at idle after it" poweroff "$(boot "$R")"
ck "rescue, USB drive mode: in and out of it" "INFO|rescue|USB drive mode
INFO|rescue|USB drive mode ended
INFO|rescue|no key for 120 s (powering off)" "$(tail -n3 "$S/result.txt")"
ck "rescue, USB drive mode: the gadget is unbound after" "" "$(cat "$G/UDC")"
ck "rescue, USB drive mode: the LUN is empty after" "" "$(cat "$G/functions/mass_storage.0/lun.0/file")"
ck "rescue, USB drive mode: removable LUN" 1 "$(cat "$G/functions/mass_storage.0/lun.0/removable")"
ck "rescue, USB drive mode: nothing written" "$(cat "$T/w1")" "$(cat "$R/writes")"

# --- rescue: the battery and hardware gates run before every write option -----------
B=$R/sys/class/power_supply/axp2101-battery
cp "$R/writes" "$T/w2"
echo 30 > "$B/capacity"
# Reinstall at 30 % on battery: refused before the confirm, back to the menu
printf '164\n164\n' > "$R/keys"
ck "gate, reinstall at 30 %: powers off at idle" poweroff "$(boot "$R")"
ck "gate, reinstall at 30 %: nothing written" "$(cat "$T/w2")" "$(cat "$R/writes")"
ck "gate, reinstall at 30 %: no mode file" no "$(yes_ test -e "$S/mode")"
ck "gate, reinstall at 30 %: recorded" "FAIL|gate-battery|battery 30 % (Discharging), below 50 % with no charger
INFO|rescue|no key for 120 s (powering off)" "$(tail -n2 "$S/result.txt")"
# Restore at 30 %
truncate -s 134217728 "$S/flash.img"
printf '114\n164\n164\n' > "$R/keys"
ck "gate, restore at 30 %: powers off at idle" poweroff "$(boot "$R")"
ck "gate, restore at 30 %: nothing written" "$(cat "$T/w2")" "$(cat "$R/writes")"
ck "gate, restore at 30 %: no mode file" no "$(yes_ test -e "$S/mode")"
ck "gate, restore at 30 %: recorded" yes "$(yes_ test "$(grep -c '^FAIL|gate-battery|' "$S/result.txt")" -eq 2)"
rm -f "$S/flash.img"
# Uninstall at 30 % (flash-backup.img is the one the upt run took)
: > "$S/stock.upt"
printf '114\n114\n164\n164\n' > "$R/keys"
ck "gate, uninstall at 30 %: powers off at idle" poweroff "$(boot "$R")"
ck "gate, uninstall at 30 %: nothing written" "$(cat "$T/w2")" "$(cat "$R/writes")"
ck "gate, uninstall at 30 %: no mode file" no "$(yes_ test -e "$S/mode")"
ck "gate, uninstall at 30 %: recorded" yes "$(yes_ test "$(grep -c '^FAIL|gate-battery|' "$S/result.txt")" -eq 3)"
rm -f "$S/stock.upt"
# No readable battery: refused too
echo x > "$B/capacity"
printf '164\n164\n' > "$R/keys"
ck "gate, reinstall with no readable battery: powers off at idle" poweroff "$(boot "$R")"
ck "gate, reinstall with no readable battery: nothing written" "$(cat "$T/w2")" "$(cat "$R/writes")"
ck "gate, reinstall with no readable battery: recorded" yes "$(yes_ grep -q '^FAIL|gate-battery|cannot read the battery' "$S/result.txt")"
echo 100 > "$B/capacity"
# The wrong chip (a 256 MiB part): the hardware gate refuses
WC=$R/sys/class/mtd/mtd4; echo 268435456 > "$WC/size"
printf '164\n164\n' > "$R/keys"
ck "gate, reinstall on a 256 MiB chip: powers off at idle" poweroff "$(boot "$R")"
ck "gate, reinstall on a 256 MiB chip: nothing written" "$(cat "$T/w2")" "$(cat "$R/writes")"
ck "gate, reinstall on a 256 MiB chip: recorded" yes \
	"$(yes_ grep -q '^FAIL|gate-hw|the chip is 268435456 bytes, not 134217728' "$S/result.txt")"
echo 134217728 > "$WC/size"
# No AXP2101 battery at all: the hardware gate refuses
mv "$B" "$T/batt"
printf '164\n164\n' > "$R/keys"
ck "gate, reinstall with no AXP2101: powers off at idle" poweroff "$(boot "$R")"
ck "gate, reinstall with no AXP2101: nothing written" "$(cat "$T/w2")" "$(cat "$R/writes")"
ck "gate, reinstall with no AXP2101: recorded" yes "$(yes_ grep -q '^FAIL|gate-hw|no AXP2101' "$S/result.txt")"
mv "$T/batt" "$B"

# USB drive mode at 5 % on battery: the card comes back and the unit powers off
echo 5 > "$B/capacity"
printf '114\n114\n114\n164\n' > "$R/keys"
ck "USB drive mode at 5 %: powers off" poweroff "$(boot "$R")"
ck "USB drive mode at 5 %: recorded" "INFO|rescue|USB drive mode
WARN|rescue|battery 5 % in USB drive mode, no charger (powering off)" "$(tail -n2 "$S/result.txt")"
ck "USB drive mode at 5 %: the gadget is unbound" "" "$(cat "$G/UDC")"
ck "USB drive mode at 5 %: the LUN is empty" "" "$(cat "$G/functions/mass_storage.0/lun.0/file")"
ck "USB drive mode at 5 %: nothing written" "$(cat "$T/w2")" "$(cat "$R/writes")"
echo 100 > "$B/capacity"
# The battery runs down while the card is on the computer: a read that times
# out (the clock moved on USB_POLL s) looks at the battery again
echo 0 > "$R/clock"
printf '#!/usr/bin/env bash\nn=$(cat %s/clock); echo $((n + 30)) > %s/clock; echo "$n"\n[ "$n" -lt 30 ] || echo 5 > %s/capacity\n' "$R" "$R" "$B" > "$R/bin/date"
chmod +x "$R/bin/date"
printf '114\n114\n114\n164\n' > "$R/keys"
ck "USB drive mode, battery runs down: powers off" poweroff "$(boot "$R")"
ck "USB drive mode, battery runs down: recorded" "INFO|rescue|USB drive mode
WARN|rescue|battery 5 % in USB drive mode, no charger (powering off)" "$(tail -n2 "$S/result.txt")"
rm -f "$R/bin/date" "$R/clock"
echo 100 > "$B/capacity"

# --- stock: PASS removes the mode file too ---------------------------------------------
R=$T/stock; mkunit "$R"; mkdir -p "$R/mnt/$E"; echo stock > "$R/mnt/$E/mode"
i=6
for p in stockboot:3145728 stockrootfs:67108864 stockdata:50331648; do
	mkdir -p "$R/sys/class/mtd/mtd$i"; echo "${p%%:*}" > "$R/sys/class/mtd/mtd$i/name"
	echo "${p#*:}" > "$R/sys/class/mtd/mtd$i/size"; echo 0 > "$R/sys/class/mtd/mtd$i/bad_blocks"
	truncate -s "${p#*:}" "$R/dev/mtd$i"; i=$((i+1))
done
d=$R/mnt/$E/stock.upt.d; mkdir -p "$d"; : > "$R/mnt/$E/stock.upt"
printf 'stock u-boot' > "$d/uboot.bin"; printf 'stock kernel' > "$d/uimage.bin"; printf 'UBI#stock' > "$d/system.ubi"
printf 'name=erosq_2024\n' > "$d/version.txt"
for m in uboot.bin uimage.bin system.ubi; do
	printf '%s={\n        file_path=autoupdate/%s\n        md5=%s\n}\n' "${m%.*}" "$m" "$(md5sum < "$d/$m" | cut -d' ' -f1)"
done > "$d/update.txt"
ck "stock: reboots after the restore" reboot "$(boot "$R")"
ck "stock: PASS recorded" yes "$(yes_ grep -q '^PASS|stock|' "$R/mnt/$E/result.txt")"
ck "stock: mode file removed on PASS" no "$(yes_ test -e "$R/mnt/$E/mode")"

# --- no mode file, stock bootloader, no update.upt: as before ----------------------
R=$T/none; mkunit "$R"; mkdir -p "$R/mnt/$E"
ck "stock bootloader, no mode, no update.upt: powers off" poweroff "$(boot "$R")"
ck "stock bootloader, no mode, no update.upt: no menu" no "$(yes_ grep -q rescue "$R/mnt/$E/result.txt")"
ck "stock bootloader, no mode, no update.upt: nothing written" "" "$(cat "$R/writes")"

# --- the initramfs's busybox applets: what the rescue menu needs is linked -----------
AP=$I/initramfs.applets
for a in od timeout ln dd date; do
	ck "applet $a is linked in the initramfs" yes "$(yes_ grep -qx "$a" "$AP")"
done
# init with only the listed applets (and the stub device tools) on PATH: a
# menu that cancels a reinstall at its confirm, moves, and powers off. The
# fake unit's own tools (bash for its stubs) come along; host coreutils do not.
R=$T/bb; mkunit "$R"; mkupt "$R"; boot "$R" >/dev/null
BB=$T/bbbin; mkdir -p "$BB"
ln -s "$(command -v bash)" "$BB/bash"
while read -r a; do
	case "$a" in ''|'#'*) continue ;; esac
	p=$(command -v "$a") && [ "${p#/}" != "$p" ] && ln -sf "$p" "$BB/$a"
done < "$AP"
printf '164\n158\n165\n164\n' > "$R/keys"
rm -f "$R/action"
PATH="$R/bin:$BB" "$TIMEOUT" 120 "$BB/sh" "$R/init" >/dev/null 2>&1
ck "listed applets only: the menu reads keys and powers off" poweroff "$(cat "$R/action" 2>/dev/null)"
ck "listed applets only: Power off chosen from the menu" "INFO|rescue|power off chosen" \
	"$(tail -n1 "$R/mnt/$E/result.txt")"


# --- the battery and hardware gates also run outside the menu ------------------------
# The stock updater's path (upt) and the developer modes reach run_plan with
# no menu in front; the same gates must refuse there before any write.
# upt at 30 % on battery: refused, nothing on the chip or the card, no marker
R=$T/gupt; mkunit "$R"; mkupt "$R"; B=$R/sys/class/power_supply/axp2101-battery
echo 30 > "$B/capacity"
ck "gate, upt at 30 %: powers off" poweroff "$(boot "$R")"
ck "gate, upt at 30 %: nothing written" "" "$(cat "$R/writes")"
ck "gate, upt at 30 %: no retry marker" no "$(yes_ test -e "$R/mnt/$E/.attempted")"
ck "gate, upt at 30 %: no erosq.itb copied" no "$(yes_ test -e "$R/mnt/erosq.itb")"
ck "gate, upt at 30 %: mode file kept for the retry" upt "$(cat "$R/mnt/$E/mode" 2>/dev/null)"
ck "gate, upt at 30 %: recorded" "FAIL|gate-battery|battery 30 % (Discharging), below 50 % with no charger
FAIL|upt|refused before any write: Battery 30 %. Plug in the charger, or charge to 50 %." \
	"$(tail -n2 "$R/mnt/$E/result.txt")"
# charged: the same card installs
echo 80 > "$B/capacity"
ck "gate, upt once charged: reboots after the install" reboot "$(boot "$R")"
ck "gate, upt once charged: PASS" yes "$(yes_ grep -q '^PASS|upt|' "$R/mnt/$E/result.txt")"
# upt at 30 % on the charger: allowed
R=$T/gupt2; mkunit "$R"; mkupt "$R"; B=$R/sys/class/power_supply/axp2101-battery
echo 30 > "$B/capacity"; echo Charging > "$B/status"
ck "gate, upt at 30 % charging: reboots after the install" reboot "$(boot "$R")"
ck "gate, upt at 30 % charging: PASS" yes "$(yes_ grep -q '^PASS|upt|' "$R/mnt/$E/result.txt")"
# upt with no AXP2101: the hardware gate refuses
R=$T/gupt3; mkunit "$R"; mkupt "$R"; rm -rf "$R/sys/class/power_supply/axp2101-battery"
ck "gate, upt with no AXP2101: powers off" poweroff "$(boot "$R")"
ck "gate, upt with no AXP2101: nothing written" "" "$(cat "$R/writes")"
ck "gate, upt with no AXP2101: recorded" yes "$(yes_ grep -q '^FAIL|gate-hw|no AXP2101' "$R/mnt/$E/result.txt")"
# install (developer card) at 30 %: refused, reboots (the unit boots something else)
R=$T/ginst; mkunit "$R"; mkdir -p "$R/mnt/$E"; echo install > "$R/mnt/$E/mode"
printf 'UBI#..kernel..rootfs..kernel_b..rootfs_b' > "$R/mnt/$E/nand.ubi"
printf 'spl' > "$R/mnt/$E/our-spl.bin"; printf 'u-boot..abselect..' > "$R/mnt/$E/our-uboot.bin"
(cd "$R/mnt/$E" && md5sum nand.ubi our-spl.bin our-uboot.bin > md5sums)
echo 30 > "$R/sys/class/power_supply/axp2101-battery/capacity"
ck "gate, install at 30 %: reboots" reboot "$(boot "$R")"
ck "gate, install at 30 %: nothing written" "" "$(cat "$R/writes")"
ck "gate, install at 30 %: no retry marker" no "$(yes_ test -e "$R/mnt/$E/.attempted")"
ck "gate, install at 30 %: recorded" yes "$(yes_ grep -q '^FAIL|install|refused before any write' "$R/mnt/$E/result.txt")"
# restore on a 256 MiB chip: the hardware gate refuses
R=$T/grest; mkunit "$R"; mkdir -p "$R/mnt/$E"; echo restore > "$R/mnt/$E/mode"
truncate -s 134217728 "$R/mnt/$E/flash.img"; echo 268435456 > "$R/sys/class/mtd/mtd4/size"
ck "gate, restore on a 256 MiB chip: reboots" reboot "$(boot "$R")"
ck "gate, restore on a 256 MiB chip: nothing written" "" "$(cat "$R/writes")"
ck "gate, restore on a 256 MiB chip: recorded" yes \
	"$(yes_ grep -q '^FAIL|gate-hw|the chip is 268435456 bytes, not 134217728' "$R/mnt/$E/result.txt")"
# stock with an unreadable battery (the unit from the stock run above)
R=$T/stock; echo stock > "$R/mnt/$E/mode"; : > "$R/writes"
echo x > "$R/sys/class/power_supply/axp2101-battery/capacity"
ck "gate, stock with no readable battery: reboots" reboot "$(boot "$R")"
ck "gate, stock with no readable battery: nothing written" "" "$(cat "$R/writes")"
ck "gate, stock with no readable battery: recorded" yes "$(yes_ grep -q '^FAIL|gate-battery|cannot read the battery' "$R/mnt/$E/result.txt")"
# uninstall at 30 % (the unit from the first upt run: its backup and record)
R=$T/upt; S=$R/mnt/$E
cp -r "$T/stock/mnt/$E/stock.upt" "$T/stock/mnt/$E/stock.upt.d" "$S/"
echo uninstall > "$S/mode"; : > "$R/writes"
echo 30 > "$R/sys/class/power_supply/axp2101-battery/capacity"
ck "gate, uninstall at 30 %: powers off" poweroff "$(boot "$R")"
ck "gate, uninstall at 30 %: nothing written" "" "$(cat "$R/writes")"
ck "gate, uninstall at 30 %: update.upt not retired" yes "$(yes_ test -e "$R/mnt/update.upt")"
ck "gate, uninstall at 30 %: recorded" yes "$(yes_ grep -q '^FAIL|uninstall|refused before any write' "$S/result.txt")"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
