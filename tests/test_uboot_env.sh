#!/usr/bin/env bash
# Host test for ci/uboot-env-check.sh: a u-boot.bin whose default bootcmd
# falls back to erosq.itb only is refused (after an install the installer is
# erosq-install/installer.uImage, so that U-Boot would never find it).
# Run: bash tests/test_uboot_env.sh
# shellcheck disable=SC2016  # ${loadaddr} etc. are U-Boot's, written literally
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
C=$HERE/ci/uboot-env-check.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (expected $2, got $3)"; fi; }
ok() { if bash "$C" "$1" >/dev/null 2>&1; then echo accepted; else echo refused; fi; }
# mkub <out> <bootcmd>: a fake u-boot.bin, its default env as NUL-separated strings
mkub() {
	{ head -c 4096 /dev/zero
	  printf 'U-Boot 2026.01 (erosq)\0bootcmd=%s\0' "$2"
	  printf 'altbootcmd=setenv boot_try; run bootcmd\0abselect=if test ${boot_slot} = b; then setenv kvol kernel_b; fi\0'
	  printf 'boot_slot=a\0bootlimit=3\0'
	  head -c 4096 /dev/zero; } > "$1"
}
AB='run abselect; ubi part ubi; ubi read ${loadaddr} ${kvol}; bootm ${loadaddr}; echo A/B slot boot failed'
mkub "$T/new.bin" "$AB; fatload mmc 0 \${loadaddr} erosq.itb; bootm \${loadaddr}; fatload mmc 0 \${loadaddr} erosq-install/installer.uImage; bootm \${loadaddr}"
mkub "$T/old.bin" "$AB; fatload mmc 0 \${loadaddr} erosq.itb; bootm \${loadaddr}"
mkub "$T/only.bin" "$AB; fatload mmc 0 \${loadaddr} erosq-install/installer.uImage; bootm \${loadaddr}"
ck "fallback erosq.itb then installer.uImage" accepted "$(ok "$T/new.bin")"
ck "fallback erosq.itb only (UBOOT_SHA 76df256d)" refused "$(ok "$T/old.bin")"
ck "fallback installer.uImage only (an install cut short is not retried)" refused "$(ok "$T/only.bin")"
sed 's/bootlimit=3/bootlimix=3/' "$T/new.bin" > "$T/nolimit.bin"
ck "no bootlimit" refused "$(ok "$T/nolimit.bin")"
# the same defaults as text (make u-boot-initial-env), which the installer seeds
printf 'altbootcmd=setenv boot_try; run bootcmd\nabselect=x\nboot_slot=a\nbootcmd=%s\nbootlimit=3\n' \
	"$AB; fatload mmc 0 \${loadaddr} erosq.itb; bootm \${loadaddr}; fatload mmc 0 \${loadaddr} erosq-install/installer.uImage; bootm \${loadaddr}" > "$T/new.env"
ck "u-boot-initial-env with the fallback chain" accepted "$(ok "$T/new.env")"
printf 'altbootcmd=setenv boot_try; run bootcmd\nabselect=x\nboot_slot=a\nbootcmd=%s\nbootlimit=3\n' \
	"$AB; fatload mmc 0 \${loadaddr} erosq.itb; bootm \${loadaddr}" > "$T/old.env"
ck "u-boot-initial-env, erosq.itb only" refused "$(ok "$T/old.env")"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
