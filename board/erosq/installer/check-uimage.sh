#!/bin/sh
# Gate the installer uImage before it goes into update.upt. Exit 1 on any failure.
#   check-uimage.sh <uImage> [<vmlinux.bin> <vmlinux.bin.gz>]
#
# 1. Size. The stock bootloader loads the `kernel` partition with a fixed
#    4 MiB read (0x400000) and boots with no delay. A larger installer is cut
#    short, fails bootm's CRC, and the unit boots nothing: by then the stock
#    kernel it replaced is gone. Do not raise the limit; slim the installer.
# 2. Header: a gzip-compressed MIPS Linux kernel, loaded at 0x80100000.
# 3. Optional, with the uncompressed and compressed kernel: bootm inflates from
#    the copy at 0x80600000 down to 0x80100000, so the writer starts 5 MiB
#    behind the reader and the image may grow by less than that.
set -u
MAX=4194304
HEAD_START=5242880
fail() { echo "check-uimage: FAIL: $*" >&2; exit 1; }
U=${1:?usage: $0 <uImage> [<vmlinux.bin> <vmlinux.bin.gz>]}
[ -f "$U" ] || fail "$U: no such file"

SZ=$(stat -c %s "$U")
[ "$SZ" -le "$MAX" ] ||
	fail "$U is $SZ bytes; the stock bootloader reads only $MAX (over by $((SZ - MAX)))"

L=$(mkimage -l "$U" 2>&1) || fail "$U: mkimage -l cannot read it"
for want in 'MIPS Linux Kernel Image (gzip compressed)' 'Load Address: 80100000'; do
	printf '%s\n' "$L" | grep -qF "$want" || fail "$U: header lacks '$want'"
done

if [ $# -ge 3 ]; then
	D=$(stat -c %s "$2") C=$(stat -c %s "$3")
	[ $((D - C)) -lt "$HEAD_START" ] ||
		fail "kernel grows by $((D - C)) bytes when inflated; the limit is $HEAD_START"
fi
echo "check-uimage: OK: $SZ bytes, $((MAX - SZ)) under the $MAX-byte stock read"
