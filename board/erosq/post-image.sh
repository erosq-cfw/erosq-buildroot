#!/bin/sh
# $1 = BINARIES_DIR (output/images). Produce the EROS p2 rootfs image + gzip.
set -e
BIN="$1"
SRC="$BIN/rootfs.ext4"
[ -f "$SRC" ] || SRC="$BIN/rootfs.ext2"
cp "$SRC" "$BIN/erosq-rootfs.ext4"
gzip -f -k "$BIN/erosq-rootfs.ext4"
echo "EROS Q rootfs: $BIN/erosq-rootfs.ext4 (+ .gz)"
