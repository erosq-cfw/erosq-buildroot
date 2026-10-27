#!/usr/bin/env bash
# Build the Buildroot SDK (external toolchain) from configs/erosq_sdk_defconfig.
# Same steps locally and in CI.
#   ci/sdk.sh id            print SDK_ID (changes when any toolchain input does)
#   ci/sdk.sh build <dir>   fetch+verify Buildroot, patch, build; leaves
#                           <dir>/sdk-<SDK_ID>.tar.gz
#   ci/sdk.sh install <tgz> unpack + relocate an SDK tarball to sdk/, where
#                           erosq_defconfig expects it
# Env: BR2_DL_DIR (download cache, optional). Parallelism is BR2_JLEVEL (0 = nproc).
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=pins.mk disable=SC1091
. "$EXT/pins.mk"

sdk_id() {
	# ponytail: only these files define the toolchain; add more if a Buildroot
	# patch outside patches/buildroot ever touches it.
	(cd "$EXT" && cat pins.mk configs/erosq_sdk_defconfig patches/buildroot/*.patch) |
		sha256sum | cut -c1-12
}

case "${1:-}" in
id) sdk_id ;;
build)
	W=$(mkdir -p "${2:?usage: $0 build <dir>}" && cd "$2" && pwd)
	BR=$W/buildroot-$BUILDROOT_VERSION
	TB=$W/buildroot-$BUILDROOT_VERSION.tar.gz
	[ -f "$TB" ] || wget -q -O "$TB" "https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.gz"
	echo "$BUILDROOT_SHA256  $TB" | sha256sum -c -
	rm -rf "$BR" && tar -xzf "$TB" -C "$W"
	"$EXT/apply-patches.sh" "$BR"
	export KBUILD_BUILD_USER=erosqcfw KBUILD_BUILD_HOST=erosq-cfw
	export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$EXT" log -1 --format=%ct)}
	make -C "$BR" O="$W/out" BR2_EXTERNAL="$EXT" erosq_sdk_defconfig
	make -C "$BR" O="$W/out" ${BR2_DL_DIR:+BR2_DL_DIR="$BR2_DL_DIR"} sdk
	mv "$W"/out/images/*_sdk-buildroot.tar.gz "$W/sdk-$(sdk_id).tar.gz"
	ls -l "$W/sdk-$(sdk_id).tar.gz"
	;;
install)
	rm -rf "$EXT/sdk" && mkdir "$EXT/sdk"
	tar -xzf "${2:?usage: $0 install <sdk tarball>}" -C "$EXT/sdk" --strip-components=1
	"$EXT/sdk/relocate-sdk.sh"
	;;
*) sed -n '2,10p' "$0"; exit 2 ;;
esac
