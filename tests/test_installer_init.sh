#!/usr/bin/env bash
# Host runs of the installer's init against a fake unit: stub device tools,
# fake MTD partitions (plain files) and a fake card (a directory). init and
# install-lib.sh are copied with their absolute paths moved under the unit's
# directory; nothing else in them changes.
# Run: bash tests/test_installer_init.sh
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

# --- no mode file, stock bootloader, no update.upt: as before ----------------------
R=$T/none; mkunit "$R"; mkdir -p "$R/mnt/$E"
ck "stock bootloader, no mode, no update.upt: powers off" poweroff "$(boot "$R")"
ck "stock bootloader, no mode, no update.upt: no menu" no "$(yes_ grep -q rescue "$R/mnt/$E/result.txt")"
ck "stock bootloader, no mode, no update.upt: nothing written" "" "$(cat "$R/writes")"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
