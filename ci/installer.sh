#!/usr/bin/env bash
# Build update.upt, the installer the stock EROS Q firmware runs from
# Firmware Update (stock firmware -> erosq). Same steps locally and in CI.
#   ci/installer.sh uimage <dir> <buildroot-src> <buildroot-output> <u-boot-initial-env>
#     -> <dir>/out/{installer.uImage,installer.config,initramfs.cpio.gz,SHA256SUMS}
#     The installer kernel: erosq-cfw/linux@LINUX_SHA (its own checkout in
#     <dir>/linux) + kernel.fragment, installer.dts appended, and the
#     initramfs (build-initramfs.sh) from a finished erosq_defconfig build
#     (ci/rootfs.sh) and ci/uboot.sh's u-boot-initial-env.
#   ci/installer.sh upt <dir> <installer.uImage> <erosq.itb> <rootfs.squashfs> \
#                       <u-boot-spl.bin> <u-boot.bin>
#     -> <dir>/out/{update.upt,nand.ubi,MD5SUMS}
# Every gate runs before anything is written to out/.
# Needs: ubinize (mtd-utils), mkimage + dumpimage, zstd, lz4, unsquashfs, python3 with pycdlib,
# cpio, and a host cc for mkspl-x1000 (Rockbox tools/, GPL-2.0+; built from
# ROCKBOX_SHA, its source checked against MKSPL_SHA256).
# Env: SOURCE_DATE_EPOCH (else the commit time), MKSPL (a built mkspl-x1000
# instead), ROCKBOX_GIT (a local clone, else the source is downloaded),
# ANON_PATTERNS, LINUX_GIT (a local clone works too), CROSS (default the SDK's),
# BR2_DL_DIR, JOBS.
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
I=$EXT/board/erosq/installer
fail() { echo "FATAL: $*" >&2; exit 1; }

if [ "${1:-}" = uimage ]; then
	[ $# -eq 5 ] || fail "usage: $0 uimage <dir> <buildroot-src> <buildroot-output> <u-boot-initial-env>"
	# shellcheck source=pins.mk disable=SC1091
	. "$EXT/pins.mk"
	W=$(mkdir -p "$2" && cd "$2" && pwd)
	K=$W/linux O=$W/out
	export CROSS=${CROSS:-$EXT/sdk/bin/mipsel-linux-}
	[ -x "${CROSS}gcc" ] || fail "no SDK: run ci/sdk.sh install <tgz> first"
	export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$EXT" log -1 --format=%ct)}
	mkdir -p "$O" && rm -f "$O"/*

	"$I/build-initramfs.sh" "$W/initramfs" "$3" "$4" "$5" "$W/initramfs.cpio.gz"

	# its own checkout: the installer config is merged over the firmware's
	# committed .config in place, which ci/kernel.sh's tree must not see
	if [ "$(git -C "$K" rev-parse HEAD 2>/dev/null)" != "$LINUX_SHA" ]; then
		rm -rf "$K" && git init -q "$K"
		git -C "$K" fetch -q --depth 1 "${LINUX_GIT:-https://github.com/erosq-cfw/linux.git}" "$LINUX_SHA"
		git -C "$K" checkout -q FETCH_HEAD
	fi
	git -C "$K" reset -q --hard
	DTS=arch/mips/boot/dts/ingenic/x1000-erosq-installer.dts
	cp "$I/installer.dts" "$K/$DTS"

	KBUILD_BUILD_TIMESTAMP=$(git -C "$K" log -1 --format=%cd --date=rfc2822)
	export ARCH=mips CROSS_COMPILE=$CROSS LOCALVERSION='' KBUILD_BUILD_USER=erosqcfw \
		KBUILD_BUILD_HOST=erosq-cfw KBUILD_BUILD_VERSION=1 KBUILD_BUILD_TIMESTAMP
	CC="${CROSS}gcc"
	command -v ccache >/dev/null && CC="ccache $CC"
	printf 'CONFIG_INITRAMFS_SOURCE="%s"\n' "$W/initramfs.cpio.gz" > "$W/initramfs.frag"
	(cd "$K" && scripts/kconfig/merge_config.sh -m .config "$I/kernel.fragment" "$W/initramfs.frag") \
		> "$W/merge.log" 2>&1 || { cat "$W/merge.log"; fail "merge_config failed"; }
	make -C "$K" olddefconfig >> "$W/merge.log" 2>&1

	# olddefconfig drops a symbol whose dependencies are off without a word;
	# an installer without NAND, the card or the PMIC would boot on a unit
	# whose stock kernel is already gone. Every symbol the installer needs,
	# and every line of the fragment, must be in the final .config.
	for sym in $(grep -v '^#' "$I/kernel.required"); do
		grep -qx "CONFIG_$sym=y" "$K/.config" || fail "installer .config lost CONFIG_$sym"
	done
	while IFS= read -r l; do
		case "$l" in
		'CONFIG_'*) grep -qxF "$l" "$K/.config" || fail "fragment line did not stick: $l" ;;
		# off: either said so, or gone with its dependencies
		'# CONFIG_'*' is not set') l=${l#\# }; l=${l% is not set}
			! grep -q "^$l=" "$K/.config" || fail "fragment turns $l off; it is on" ;;
		esac
	done < "$I/kernel.fragment"
	! grep -q '^CONFIG_CMDLINE=.*earlycon' "$K/.config" || fail "earlycon in CONFIG_CMDLINE: it hangs the installer"

	: > "$W/build.log"
	for t in vmlinux.bin ingenic/x1000-erosq-installer.dtb; do
		make -C "$K" -j"${JOBS:-$(nproc)}" CC="$CC" "$t" >> "$W/build.log" 2>&1 ||
			{ tail -n 30 "$W/build.log"; fail "kernel build ($t) failed"; }
	done
	! grep -qi 'warning' "$W/build.log" || fail "compiler/kbuild warnings (see $W/build.log)"
	"${CROSS}readelf" -h "$K/vmlinux" | grep -q 'little endian' || fail "vmlinux is big-endian"

	# The stock bootloader and the Rockbox one pass no DTB: it rides after
	# the kernel, where MIPS_RAW_APPENDED_DTB looks for it (__appended_dtb is
	# 32-byte aligned).
	KB=$W/installer.bin
	cp "$K/arch/mips/boot/vmlinux.bin" "$KB"
	SZ=$(stat -c %s "$KB")
	truncate -s $(( (SZ + 31) / 32 * 32 )) "$KB"
	cat "$K/${DTS%.dts}.dtb" >> "$KB"
	gzip -9 -n -c "$KB" > "$KB.gz"
	ENTRY=$("${CROSS}nm" "$K/vmlinux" | awk '/ kernel_entry$/{print "0x"$1}')
	[ -n "$ENTRY" ] || fail "no kernel_entry in vmlinux"
	mkimage -A mips -O linux -T kernel -C gzip -a 0x80100000 -e "$ENTRY" \
		-n "EROS Q installer" -d "$KB.gz" "$W/installer.uImage" >/dev/null

	# the brick ceiling, and the gunzip head start
	"$I/check-uimage.sh" "$W/installer.uImage" "$KB" "$KB.gz" | tee "$W/check-uimage.log"
	# nothing private inside, unpacked all the way down (the kernel banner
	# carries the build host; KBUILD_BUILD_HOST above keeps it neutral)
	"$I/check-payload.sh" "$W/installer.uImage"

	cp "$W/installer.uImage" "$O/"
	# the published config names the initramfs by its published name, not a build path
	sed 's#^CONFIG_INITRAMFS_SOURCE=.*#CONFIG_INITRAMFS_SOURCE="initramfs.cpio.gz"#' "$K/.config" > "$O/installer.config"
	cp "$W/initramfs.cpio.gz" "$O/"
	(cd "$O" && sha256sum installer.uImage installer.config initramfs.cpio.gz > SHA256SUMS && cat SHA256SUMS)
	exit 0
fi

if [ "${1:-}" != upt ] || [ $# -ne 7 ]; then
	fail "usage: $0 upt <dir> <installer.uImage> <erosq.itb> <rootfs.squashfs> <u-boot-spl.bin> <u-boot.bin>"
fi
W=$(mkdir -p "$2" && cd "$2" && pwd)
UIMAGE=$3 ITB=$4 ROOTFS=$5 SPL_RAW=$6 UBOOT=$7
for f in "$UIMAGE" "$ITB" "$ROOTFS" "$SPL_RAW" "$UBOOT"; do [ -f "$f" ] || fail "$f: no such file"; done
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$EXT" log -1 --format=%ct)}
O=$W/out T=$W/tmp
rm -rf "$O" "$T" && mkdir -p "$O" "$T"

# the boot ROM header writer, from the pinned Rockbox source
if [ -z "${MKSPL:-}" ]; then
	# shellcheck source=pins.mk disable=SC1091
	. "$EXT/pins.mk"
	if [ -n "${ROCKBOX_GIT:-}" ]; then
		git -C "$ROCKBOX_GIT" show "$ROCKBOX_SHA:tools/mkspl-x1000.c" > "$T/mkspl-x1000.c"
	else
		wget -q -O "$T/mkspl-x1000.c" "https://raw.githubusercontent.com/Rockbox/rockbox/$ROCKBOX_SHA/tools/mkspl-x1000.c"
	fi
	echo "$MKSPL_SHA256  $T/mkspl-x1000.c" | sha256sum -c --quiet - || fail "mkspl-x1000.c: sha256 mismatch"
	${HOSTCC:-cc} -O2 -o "$T/mkspl-x1000" "$T/mkspl-x1000.c"
	MKSPL=$T/mkspl-x1000
fi

# the brick ceiling first: nothing else matters if this fails
"$I/check-uimage.sh" "$UIMAGE"
# nothing private inside, whatever built the inputs (unpacked all the way down)
"$I/check-payload.sh" "$UIMAGE" "$ITB" "$ROOTFS" "$SPL_RAW" "$UBOOT"

# SPL with the X1000 boot ROM header for NAND, padded to 8 KiB
"$MKSPL" -type=nand -ppb=2 -bpp=2 "$SPL_RAW" "$T/spl.erosq"
[ "$(stat -c %s "$T/spl.erosq")" -le 8192 ] || fail "SPL with header is over 8 KiB"
truncate -s 8192 "$T/spl.erosq"
# U-Boot padded to the 1 MiB the SPL reads
[ "$(stat -c %s "$UBOOT")" -le $((0x100000)) ] || fail "u-boot.bin is over 1 MiB"
cp "$UBOOT" "$T/u-boot-flash.bin" && truncate -s $((0x100000)) "$T/u-boot-flash.bin"

# A/B UBI image: static kernel/rootfs volumes for both slots, ids 0/1/3/4
# (id 2 is /data, which the firmware makes on first boot). The image sequence
# number is fixed so the same inputs give the same image.
cat > "$T/ubinize.cfg" <<EOF
[kernel]
mode=ubi
image=$ITB
vol_id=0
vol_type=static
vol_size=8MiB
vol_name=kernel
[rootfs]
mode=ubi
image=$ROOTFS
vol_id=1
vol_type=static
vol_size=24MiB
vol_name=rootfs
[kernel_b]
mode=ubi
image=$ITB
vol_id=3
vol_type=static
vol_size=8MiB
vol_name=kernel_b
[rootfs_b]
mode=ubi
image=$ROOTFS
vol_id=4
vol_type=static
vol_size=24MiB
vol_name=rootfs_b
EOF
ubinize -o "$T/nand.ubi" -p 128KiB -m 2048 -s 2048 -Q 0x20adf942 "$T/ubinize.cfg"

python3 "$I/build-upt.py" --uimage "$UIMAGE" --nand-ubi "$T/nand.ubi" \
	--spl "$T/spl.erosq" --uboot "$T/u-boot-flash.bin" -o "$T/update.upt"
# and the outputs themselves, before they reach out/ (the .upt is unpacked to
# its members, nand.ubi to its volumes)
"$I/check-payload.sh" "$T/spl.erosq" "$T/u-boot-flash.bin" "$T/nand.ubi" "$T/update.upt"
mv "$T/update.upt" "$T/nand.ubi" "$O/"
(cd "$O" && md5sum update.upt nand.ubi > MD5SUMS && cat MD5SUMS)
rm -rf "$T"
