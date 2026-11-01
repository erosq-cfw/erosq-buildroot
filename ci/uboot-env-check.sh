#!/usr/bin/env bash
# Gate the default environment compiled into u-boot.bin, or the same
# defaults as text (u-boot-initial-env, `make u-boot-initial-env`), which the
# installer seeds the chip's env from: what is checked here is also what a
# fresh install boots with.
#   ci/uboot-env-check.sh <u-boot.bin | u-boot-initial-env>
#  - the A/B boot env (swupdate rollback depends on it);
#  - the card fallback when the A/B slot fails: erosq.itb (an install cut
#    short), then erosq-install/installer.uImage, where the installer keeps
#    itself after an install (the rescue menu).
set -euo pipefail
fail() { echo "FATAL: $*" >&2; exit 1; }
B=${1:?usage: $0 <u-boot.bin>}
[ -f "$B" ] || fail "$B: no such file"
S=$(strings "$B")
for s in abselect altbootcmd boot_slot bootlimit; do
	grep -q "$s" <<<"$S" || fail "default env lacks '$s'"
done
# shellcheck disable=SC2016  # ${loadaddr} is U-Boot's, not ours
FB='fatload mmc 0 ${loadaddr} erosq.itb; bootm ${loadaddr}; fatload mmc 0 ${loadaddr} erosq-install/installer.uImage; bootm ${loadaddr}'
grep '^bootcmd=' <<<"$S" | grep -qF "$FB" ||
	fail "default bootcmd does not fall back to erosq.itb, then erosq-install/installer.uImage"
echo "u-boot env: A/B env and card fallback present"
