#!/bin/sh
# Dep-free host tests for board/erosq/installer/install-lib.sh, the
# installer's pure decision logic. Run: sh tests/test_installer_lib.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../board/erosq/installer/install-lib.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ck() { # ck <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL: $1
      expected: [$2]
      actual:   [$3]"; fi
}

# --- il_parse_mode ---
printf 'install\n' > "$T/m"; ck "mode install"     install "$(il_parse_mode "$T/m")"
printf 'backup'    > "$T/m"; ck "mode no-newline"  backup  "$(il_parse_mode "$T/m")"
printf ' stock \r\n' > "$T/m"; ck "mode ws/CRLF"   stock   "$(il_parse_mode "$T/m")"
printf 'restore\n' > "$T/m"; ck "mode restore"     restore "$(il_parse_mode "$T/m")"
printf ' restore \r\n' > "$T/m"; ck "mode restore ws/CRLF" restore "$(il_parse_mode "$T/m")"
il_parse_mode "$T/m" >/dev/null; ck "mode restore rc" 0 $?
printf 'restor\n'  > "$T/m"; ck "mode restor (typo)" invalid "$(il_parse_mode "$T/m")"
printf 'wipe\n'    > "$T/m"; ck "mode unknown"     invalid "$(il_parse_mode "$T/m")"
printf ''          > "$T/m"; ck "mode empty"       invalid "$(il_parse_mode "$T/m")"
printf 'install\nstock\n' > "$T/m"; ck "mode first line only" install "$(il_parse_mode "$T/m")"

# --- il_parse_mode: absent vs. garbage MUST be distinguishable ---
# (an absent mode file means "not a developer card" to the caller; garbage
# content does not, and keeps the weaker $UPT fallback -- see install-lib.sh)
ck "mode missing file"        absent  "$(il_parse_mode "$T/nope")"
il_parse_mode "$T/nope" >/dev/null; ck "mode missing file rc" 2 $?
printf ''    > "$T/m"; ck "mode empty rc"   invalid "$(il_parse_mode "$T/m")"
il_parse_mode "$T/m" >/dev/null;    ck "mode empty rc code" 1 $?
printf 'wipe\n' > "$T/m"; ck "mode garbage rc" invalid "$(il_parse_mode "$T/m")"
il_parse_mode "$T/m" >/dev/null;    ck "mode garbage rc code" 1 $?

# --- il_md5_ok ---
printf 'hello' > "$T/f"   # md5 5d41402abc4b2a76b9719d911017c592
il_md5_ok "$T/f" 5d41402abc4b2a76b9719d911017c592; ck "md5 match"    0 $?
il_md5_ok "$T/f" 00000000000000000000000000000000; ck "md5 mismatch" 1 $?
il_md5_ok "$T/nope" 5d41402abc4b2a76b9719d911017c592; ck "md5 missing file" 1 $?

# --- il_mtd_by_name (fixture sysfs) ---
mkdir -p "$T/sys/mtd0" "$T/sys/mtd0ro" "$T/sys/mtd3" "$T/sys/mtd7"
printf 'spl\n'       > "$T/sys/mtd0/name"
printf 'spl\n'       > "$T/sys/mtd0ro/name"
printf 'ubi\n'       > "$T/sys/mtd3/name"
printf 'stockubi\n'  > "$T/sys/mtd7/name"
ck "mtd by name spl"      mtd0 "$(il_mtd_by_name spl      "$T/sys")"
ck "mtd by name ubi"      mtd3 "$(il_mtd_by_name ubi      "$T/sys")"
ck "mtd by name stockubi" mtd7 "$(il_mtd_by_name stockubi "$T/sys")"
il_mtd_by_name nosuch "$T/sys" >/dev/null; ck "mtd absent" 1 $?

# --- il_should_abort ---
il_should_abort "$T/marker"; ck "no marker -> proceed" 1 $?
: > "$T/marker"
il_should_abort "$T/marker"; ck "marker -> abort"      0 $?

# --- il_file_contains (content gate; md5 cannot tell right-file from wrong-file) ---
printf 'hello abselect world' > "$T/withmarker"
printf 'hello world'          > "$T/nomarker"
# binary, like the real our-uboot.bin: the marker must still be found
printf 'bin\000\001\002abselect\000tail' > "$T/binmarker"
il_file_contains "$T/withmarker" abselect; ck "contains marker"        0 $?
il_file_contains "$T/nomarker"   abselect; ck "lacks marker"           1 $?
il_file_contains "$T/nope"       abselect; ck "missing file"           1 $?
il_file_contains "$T/binmarker"  abselect; ck "marker in BINARY file"  0 $?

# --- il_result_line ---
ck "result line" "FAIL|write-spl|md5 mismatch" "$(il_result_line FAIL write-spl 'md5 mismatch')"

# --- il_parse_mode: upt ---
printf 'upt\n'      > "$T/m"; ck "mode upt"          upt "$(il_parse_mode "$T/m")"
printf ' upt \r\n'  > "$T/m"; ck "mode upt ws/CRLF"  upt "$(il_parse_mode "$T/m")"
il_parse_mode "$T/m" >/dev/null; ck "mode upt rc" 0 $?
printf 'up\n'       > "$T/m"; ck "mode up (typo)" invalid "$(il_parse_mode "$T/m")"

# --- il_find_ci (ISO9660 without Rock Ridge may present EITHER case) ---
mkdir -p "$T/iso_lower" "$T/iso_upper" "$T/iso_empty"
: > "$T/iso_lower/nand.ubi"
: > "$T/iso_upper/NAND.UBI"
ck "find_ci lowercase" "$T/iso_lower/nand.ubi" "$(il_find_ci "$T/iso_lower" nand.ubi)"
ck "find_ci uppercase" "$T/iso_upper/NAND.UBI" "$(il_find_ci "$T/iso_upper" nand.ubi)"
il_find_ci "$T/iso_empty" nand.ubi >/dev/null; ck "find_ci absent" 1 $?
il_find_ci "$T/iso_lower" nand.ubi >/dev/null; ck "find_ci rc ok" 0 $?
# a directory of that name is NOT a payload file
mkdir -p "$T/iso_dir/nand.ubi"
il_find_ci "$T/iso_dir" nand.ubi >/dev/null; ck "find_ci dir is not a file" 1 $?
# dotted 8.3 name with a longer stem
: > "$T/iso_upper/OURUBOOT.BIN"
ck "find_ci 8.3 stem" "$T/iso_upper/OURUBOOT.BIN" "$(il_find_ci "$T/iso_upper" ouruboot.bin)"

# --- il_upt_md5 (gate a .upt member against that .upt's own UPDATE.TXT) ---
# The shape build-upt.py writes, with a three-section manifest like an
# official update's. The md5s are made up.
A=0123456789abcdef0123456789abcdef
B=fedcba9876543210fedcba9876543210
C=00112233445566778899aabbccddeeff
printf 'bootloader={\n        name=uboot\n        file_path=autoupdate/uboot.bin\n        md5=%s\n}\n\nkernel={\n        name=kernel\n        file_path=autoupdate/uimage.bin\n        md5=%s\n}\n\nrootfs={\n        name=rootfs\n        file_path=autoupdate/system.ubi\n        md5=%s\n}\n\n' "$A" "$B" "$C" > "$T/u.txt"
ck "upt_md5 first"  "$A" "$(il_upt_md5 "$T/u.txt" uboot.bin)"
ck "upt_md5 middle" "$B" "$(il_upt_md5 "$T/u.txt" uimage.bin)"
ck "upt_md5 last"   "$C" "$(il_upt_md5 "$T/u.txt" system.ubi)"
ck "upt_md5 member name is case-insensitive" "$B" "$(il_upt_md5 "$T/u.txt" UIMAGE.BIN)"
il_upt_md5 "$T/u.txt" nand.ubi >/dev/null; ck "upt_md5 absent member" 1 $?
il_upt_md5 "$T/nope" uimage.bin >/dev/null; ck "upt_md5 missing file" 1 $?
# CRLF, trailing blanks, upper-case names and hex, no final newline
printf 'kernel={\r\n\tname=kernel \r\n\tfile_path=AUTOUPDATE/UIMAGE.BIN\r\n\tmd5=%s \r\n}' "FEDCBA9876543210FEDCBA9876543210" > "$T/u.txt"
ck "upt_md5 CRLF + upper case" "$B" "$(il_upt_md5 "$T/u.txt" uimage.bin)"
# only the basename counts
printf 'kernel={\nfile_path=autoupdate/x/uimage.bin\nmd5=%s\n}\n' "$B" > "$T/u.txt"
ck "upt_md5 basename of a deeper path" "$B" "$(il_upt_md5 "$T/u.txt" uimage.bin)"
printf 'kernel={\nfile_path=autoupdate/xuimage.bin\nmd5=%s\n}\n' "$B" > "$T/u.txt"
il_upt_md5 "$T/u.txt" uimage.bin >/dev/null; ck "upt_md5 suffix is not a match" 1 $?
# md5 before file_path in a section
printf 'kernel={\nmd5=%s\nfile_path=autoupdate/uimage.bin\n}\n' "$B" > "$T/u.txt"
ck "upt_md5 md5 line first" "$B" "$(il_upt_md5 "$T/u.txt" uimage.bin)"
# an md5 must not leak from one section into the next
printf 'a={\nfile_path=autoupdate/uboot.bin\nmd5=%s\n}\nb={\nfile_path=autoupdate/uimage.bin\n}\n' "$A" > "$T/u.txt"
il_upt_md5 "$T/u.txt" uimage.bin >/dev/null; ck "upt_md5 section without md5" 1 $?
# fail closed on an ambiguous or broken manifest
printf 'a={\nfile_path=autoupdate/uimage.bin\nmd5=%s\n}\nb={\nfile_path=autoupdate/UIMAGE.BIN\nmd5=%s\n}\n' "$A" "$B" > "$T/u.txt"
il_upt_md5 "$T/u.txt" uimage.bin >/dev/null; ck "upt_md5 member named twice" 1 $?
printf 'kernel={\nfile_path=autoupdate/uimage.bin\nmd5=%s\n' "$B" > "$T/u.txt"
il_upt_md5 "$T/u.txt" uimage.bin >/dev/null; ck "upt_md5 unclosed section" 1 $?
printf 'kernel={\nfile_path=autoupdate/uimage.bin\nmd5=0123\n}\n' > "$T/u.txt"
il_upt_md5 "$T/u.txt" uimage.bin >/dev/null; ck "upt_md5 short md5" 1 $?
printf 'kernel={\nfile_path=autoupdate/uimage.bin\nmd5=%sg\n}\n' "0123456789abcdef0123456789abcde" > "$T/u.txt"
il_upt_md5 "$T/u.txt" uimage.bin >/dev/null; ck "upt_md5 non-hex md5" 1 $?
printf 'kernel={\nfile_path=autoupdate/uimage.bin\nmd5=\n}\n' > "$T/u.txt"
il_upt_md5 "$T/u.txt" uimage.bin >/dev/null; ck "upt_md5 empty md5" 1 $?

# --- il_upt_product ---
printf '\n\nversion={\n        name=erosq_2024\n        ver=2024-08-23T15:39:12+08:00\n}\n\n' > "$T/v.txt"
ck "upt_product" erosq_2024 "$(il_upt_product "$T/v.txt")"
printf 'version={\r\n\tname=erosq_2024 \r\n}' > "$T/v.txt"
ck "upt_product CRLF" erosq_2024 "$(il_upt_product "$T/v.txt")"
printf 'version={\n        name=other_2024\n}\n' > "$T/v.txt"
ck "upt_product other" other_2024 "$(il_upt_product "$T/v.txt")"
printf 'version={\n        ver=1\n}\n' > "$T/v.txt"
il_upt_product "$T/v.txt" >/dev/null; ck "upt_product no name" 1 $?
il_upt_product "$T/nope" >/dev/null; ck "upt_product missing file" 1 $?

# --- il_fail_action (what finish does; the guard is armed only before the first erase) ---
ck "PASS reboots"                      reboot   "$(il_fail_action PASS 0)"
ck "PASS reboots on a self-booting unit" reboot "$(il_fail_action PASS 1)"
ck "FAIL reboots elsewhere"            reboot   "$(il_fail_action FAIL 0)"
ck "FAIL powers off when a reboot boots the installer" poweroff "$(il_fail_action FAIL 1)"

# --- il_write_plan ---
INIT="$HERE/../board/erosq/installer/init"
ck "plan install (hardware-proven order)" "arm write-ubi verify-ubi erase-env write-uboot write-spl seed-env" "$(il_write_plan install)"
ck "plan upt" "copy-itb arm erase-env write-uboot write-spl write-ubi verify-ubi seed-env drop-itb" "$(il_write_plan upt)"
il_write_plan backup >/dev/null; ck "no plan for backup (no chip writes)" 1 $?
il_write_plan wipe >/dev/null;   ck "no plan for an unknown mode" 1 $?
il_write_plan "" >/dev/null;     ck "no plan for no mode" 1 $?
pos() { # pos <word> <list...> -> 1-based index of the first match, 0 if none
    _w=$1; shift; _i=0
    for _x in "$@"; do _i=$((_i+1)); [ "$_x" = "$_w" ] && { echo "$_i"; return; }; done
    echo 0
}
writes() { case "$1" in erase-*|write-*|restore-*|seed-*) return 0 ;; esac; return 1; }
for m in install upt stock restore; do
    p=$(il_write_plan "$m"); ck "plan $m exists" 0 $?
    n=0; before=ok; after=; seen=
    for s in $p; do
        [ "$s" = arm ] && n=$((n+1))
        if [ -z "$seen" ]; then
            if [ "$s" = arm ]; then seen=1; elif writes "$s"; then before="$s writes before arm"; fi
        elif [ -z "$after" ]; then after=$s
        fi
        grep -q "^step_$(echo "$s" | tr - _)() " "$INIT"; ck "init has step_$s() for plan $m" 0 $?
    done
    ck "plan $m arms once" 1 "$n"
    ck "plan $m writes nothing before arm" ok "$before"
    writes "$after"; ck "plan $m: the step after arm ($after) erases" 0 $?
done
set -- $(il_write_plan upt)
u=$(pos write-uboot "$@"); sp=$(pos write-spl "$@"); ub=$(pos write-ubi "$@")
[ "$u" -gt 0 ] && [ "$u" -lt "$sp" ] && [ "$sp" -lt "$ub" ]; ck "upt: uboot < spl < ubi" 0 $?
[ "$(pos copy-itb "$@")" -lt "$(pos arm "$@")" ]; ck "upt: erosq.itb is on the card before arm" 0 $?
[ "$(pos drop-itb "$@")" -eq $# ]; ck "upt: drop-itb is last" 0 $?
[ "$(pos verify-ubi "$@")" -gt "$ub" ]; ck "upt: verify-ubi after write-ubi" 0 $?
set --

# --- il_backup_verdict ---
ck "verdict fresh"                 fresh   "$(il_backup_verdict "$A" "$A" "")"
ck "verdict fresh, record agrees"  fresh   "$(il_backup_verdict "$A" "$A" "$A")"
ck "verdict fresh, record differs" fresh   "$(il_backup_verdict "$A" "$A" "$B")"
ck "verdict earlier"               earlier "$(il_backup_verdict "$A" "$B" "$A")"
ck "verdict bad, no record"        bad     "$(il_backup_verdict "$A" "$B" "")"
ck "verdict bad, other record"     bad     "$(il_backup_verdict "$A" "$B" "$C")"
ck "verdict bad, empty backup md5" bad     "$(il_backup_verdict "" "" "")"
ck "verdict bad, empty backup md5 and chip" bad "$(il_backup_verdict "" "$B" "")"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
