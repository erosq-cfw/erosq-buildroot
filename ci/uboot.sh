#!/usr/bin/env bash
# Build EROS Q U-Boot + SPL from UBOOT_SHA with the SDK. Same steps locally and in CI.
#   ci/uboot.sh <dir>   fetch erosq-cfw/u-boot@UBOOT_SHA into <dir>/u-boot, build,
#                       leave <dir>/out/{u-boot.bin,u-boot-flash.bin,u-boot-spl.bin,uboot.version}
# u-boot-flash.bin is u-boot.bin padded to the 1 MiB the SPL reads (UBOOT_NAND_LEN);
# u-boot-spl.bin is unsigned (NAND block 0 needs the boot ROM header added).
# Env: UBOOT_GIT (default the GitHub repo; a local clone works too), JOBS.
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=pins.mk disable=SC1091
. "$EXT/pins.mk"
W=$(mkdir -p "${1:?usage: $0 <dir>}" && cd "$1" && pwd)
U=$W/u-boot B=$W/u-boot-build O=$W/out
CROSS=$EXT/sdk/bin/mipsel-linux-
[ -x "${CROSS}gcc" ] || { echo "no SDK: run ci/sdk.sh install <tgz> first" >&2; exit 1; }

if [ "$(git -C "$U" rev-parse HEAD 2>/dev/null)" != "$UBOOT_SHA" ]; then
	rm -rf "$U" && git init -q "$U"
	git -C "$U" fetch -q --depth 1 "${UBOOT_GIT:-https://github.com/erosq-cfw/u-boot.git}" "$UBOOT_SHA"
	git -C "$U" checkout -q FETCH_HEAD
fi
git -C "$U" diff --quiet HEAD || { echo "$U: tree is dirty" >&2; exit 1; }

export ARCH=mips CROSS_COMPILE=$CROSS SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$U" log -1 --format=%ct)
CC="${CROSS}gcc"
command -v ccache >/dev/null && CC="ccache $CC"
mkdir -p "$O" && rm -f "$O"/*
make -C "$U" O="$B" erosq_defconfig
make -C "$U" O="$B" -j"${JOBS:-$(nproc)}" CC="$CC" 2>&1 | tee "$O/build.log"

fail() { echo "FATAL: $*" >&2; exit 1; }
! grep -qi warning "$O/build.log" || fail "compiler warnings (see build.log)"
cd "$O"
cp "$B/u-boot.bin" "$B/spl/u-boot-spl.bin" .
# the SPL loads exactly UBOOT_NAND_LEN; a bigger u-boot.bin would be cut off (brick)
[ "$(stat -c %s u-boot.bin)" -le $((0x100000)) ] || fail "u-boot.bin is over 1 MiB"
cp u-boot.bin u-boot-flash.bin && truncate -s $((0x100000)) u-boot-flash.bin
# the A/B boot env must be compiled in (swupdate rollback depends on it)
strings u-boot.bin > strings.txt
for s in abselect altbootcmd boot_slot bootlimit; do
	grep -q "$s" strings.txt || fail "default env lacks '$s'"
done
grep -m1 '^U-Boot 20' strings.txt | tee uboot.version
rm strings.txt
ls -l "$O"
