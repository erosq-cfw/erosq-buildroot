#!/usr/bin/env bash
# Build update.upt, the installer the stock EROS Q firmware runs from
# Firmware Update (stock firmware -> erosq). Same steps locally and in CI.
#   ci/installer.sh upt <dir> <installer.uImage> <erosq.itb> <rootfs.squashfs> \
#                       <u-boot-spl.bin> <u-boot.bin>
#     -> <dir>/out/{update.upt,nand.ubi,MD5SUMS}
# The installer kernel and its initramfs are not built here yet (PLAN step 6);
# the uImage is an input. Every gate runs before anything is written to out/.
# Needs: ubinize (mtd-utils), mkimage + dumpimage, zstd, lz4, unsquashfs, python3 with pycdlib,
# and MKSPL (default mkspl-x1000 on PATH: Rockbox tools/, GPL-2.0+).
# Env: SOURCE_DATE_EPOCH (else the commit time), MKSPL, ANON_PATTERNS.
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
I=$EXT/board/erosq/installer
fail() { echo "FATAL: $*" >&2; exit 1; }

if [ "${1:-}" != upt ] || [ $# -ne 7 ]; then
	fail "usage: $0 upt <dir> <installer.uImage> <erosq.itb> <rootfs.squashfs> <u-boot-spl.bin> <u-boot.bin>"
fi
W=$(mkdir -p "$2" && cd "$2" && pwd)
UIMAGE=$3 ITB=$4 ROOTFS=$5 SPL_RAW=$6 UBOOT=$7
for f in "$UIMAGE" "$ITB" "$ROOTFS" "$SPL_RAW" "$UBOOT"; do [ -f "$f" ] || fail "$f: no such file"; done
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$EXT" log -1 --format=%ct)}
O=$W/out T=$W/tmp
rm -rf "$O" "$T" && mkdir -p "$O" "$T"

# the brick ceiling first: nothing else matters if this fails
"$I/check-uimage.sh" "$UIMAGE"
# nothing private inside, whatever built the inputs (unpacked all the way down)
"$I/check-payload.sh" "$UIMAGE" "$ITB" "$ROOTFS" "$SPL_RAW" "$UBOOT"

# SPL with the X1000 boot ROM header for NAND, padded to 8 KiB
"${MKSPL:-mkspl-x1000}" -type=nand -ppb=2 -bpp=2 "$SPL_RAW" "$T/spl.erosq"
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
