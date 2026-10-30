#!/usr/bin/env bash
# Build the EROS Q kernel FIT image (kernel + DTB) from LINUX_SHA with the SDK.
# Same steps locally and in CI. Needs: ci/sdk.sh install done, mkimage + dtc.
#   ci/kernel.sh <dir>   fetch erosq-cfw/linux@LINUX_SHA into <dir>/linux, build,
#                        leave <dir>/out/{erosq-<KVER>.itb,kernel.version,vmlinux}
# Env: LINUX_GIT (default the GitHub repo; a local clone works too), JOBS.
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=pins.mk disable=SC1091
. "$EXT/pins.mk"
W=$(mkdir -p "${1:?usage: $0 <dir>}" && cd "$1" && pwd)
K=$W/linux O=$W/out
CROSS=$EXT/sdk/bin/mipsel-linux-
[ -x "${CROSS}gcc" ] || { echo "no SDK: run ci/sdk.sh install <tgz> first" >&2; exit 1; }

if [ "$(git -C "$K" rev-parse HEAD 2>/dev/null)" != "$LINUX_SHA" ]; then
	rm -rf "$K" && git init -q "$K"
	git -C "$K" fetch -q --depth 1 "${LINUX_GIT:-https://github.com/erosq-cfw/linux.git}" "$LINUX_SHA"
	git -C "$K" checkout -q FETCH_HEAD
fi
# this checkout belongs to the script; a previous build refreshed .config's compiler banner
git -C "$K" reset -q --hard

# reproducible: no user/host/time of the builder in the banner
KBUILD_BUILD_TIMESTAMP=$(git -C "$K" log -1 --format=%cd --date=rfc2822)
export ARCH=mips CROSS_COMPILE=$CROSS LOCALVERSION='' KBUILD_BUILD_USER=erosqcfw \
	KBUILD_BUILD_HOST=erosq-cfw KBUILD_BUILD_VERSION=1 KBUILD_BUILD_TIMESTAMP
CC="${CROSS}gcc"
command -v ccache >/dev/null && CC="ccache $CC"
mkdir -p "$O" && rm -f "$O"/*
# separate calls: one make with both targets builds the dtb twice in parallel (race)
for t in vmlinux.bin ingenic/x1000-erosq-min.dtb; do
	make -C "$K" -j"${JOBS:-$(nproc)}" CC="$CC" "$t" 2>&1 | tee -a "$O/build.log"
done
VER=$(make -C "$K" -s kernelrelease)
KVER=$VER-g$(git -C "$K" rev-parse --short=10 HEAD)

# gates (from the 2f kernel build)
fail() { echo "FATAL: $*" >&2; exit 1; }
! grep -qi 'warning' "$O/build.log" || fail "compiler/kbuild warnings (see build.log)"
# the build may only refresh the compiler banner and the host rustc probes
# (CONFIG_RUST is off and the image has no IKCONFIG) in the committed .config
grep -q '^CONFIG_RUST=y' "$K/.config" && fail "CONFIG_RUST is on: the rustc probes matter"
D=$(git -C "$K" diff -U0 HEAD -- .config | grep '^[-+]CONFIG' |
	grep -v -e '^[-+]CONFIG_CC_VERSION_TEXT=' -e '^[-+]CONFIG_RUSTC_' || true)
[ -z "$D" ] || fail ".config changed during the build:
$D"
grep -qx '# CONFIG_MODULES is not set' "$K/.config" || fail "CONFIG_MODULES is on: modules would not ship"
"${CROSS}readelf" -h "$K/vmlinux" | grep -q 'little endian' || fail "vmlinux is big-endian"

cd "$O"
cp "$K/vmlinux" vmlinux
cp "$K/arch/mips/boot/dts/ingenic/x1000-erosq-min.dtb" erosq.dtb
gzip -9 -n -c "$K/arch/mips/boot/vmlinux.bin" > vmlinux.bin.gz
ENTRY=$("${CROSS}nm" vmlinux | awk '/ kernel_entry$/{print "0x"$1}')
SIZE=$(stat -c %s "$K/arch/mips/boot/vmlinux.bin")
[ $((0x80100000 + SIZE)) -lt $((0x81000000)) ] || fail "kernel ($SIZE B) overlaps the FIT load address 0x81000000"
sed -e "s/@VER@/$VER/g" -e "s/@ENTRY@/$ENTRY/" "$EXT/board/erosq/kernel/erosq.its.in" > erosq.its
SOURCE_DATE_EPOCH=$(git -C "$K" log -1 --format=%ct) mkimage -f erosq.its "erosq-$KVER.itb" >/dev/null
rm erosq.its vmlinux.bin.gz erosq.dtb
# the kernel UBI volume is 67 LEBs = 8507392 B
[ "$(stat -c %s "erosq-$KVER.itb")" -le 8507392 ] || fail "itb does not fit the kernel volume"
printf '%s\n' "$KVER" > kernel.version
mkimage -l "erosq-$KVER.itb" | grep -E 'Description|Entry|Load'
ls -l "$O"
