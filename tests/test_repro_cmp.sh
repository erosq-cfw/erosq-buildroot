#!/bin/sh
# Host self-check for ci/repro-cmp.py (repro.yml's comparator): a .swu whose
# entries match but whose cpio headers differ passes; a changed payload byte,
# a reordered, missing or extra entry, a changed plain file or a file the
# rebuild lacks fails. Needs python3, cpio.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
CMP="$HERE/ci/repro-cmp.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir "$T/src"
echo '{ "sw-description" }' > "$T/src/sw-description"
echo kernel > "$T/src/erosq.itb"
head -c 5000 /dev/urandom > "$T/src/rootfs.squashfs"
swu() {  # <out.swu> <mtime> <entry>...: a cpio crc archive of $T/src files
	out=$1 when=$2; shift 2
	(cd "$T/src" && touch -d "@$when" "$@" && printf '%s\n' "$@" | cpio -o -H crc 2>/dev/null) > "$out"
}
dir() {  # <dir> <swu-builder args...>: a release dir with a .swu and a plain file
	d=$T/$1; shift; mkdir -p "$d"
	swu "$d/erosq-unsigned.swu" "$@"
	echo uboot > "$d/u-boot.bin"
	(cd "$d" && sha256sum -- * > SHA256SUMS)
}
cmp_ok()   { python3 -I "$CMP" "$T/rel" "$T/$1" > "$T/out" 2>&1 || fail "$2: $(cat "$T/out")"; }
cmp_fail() { python3 -I "$CMP" "$T/rel" "$T/$1" > "$T/out" 2>&1 && fail "$2 passed: $(cat "$T/out")"; :; }
ORDER="sw-description erosq.itb rootfs.squashfs"
# shellcheck disable=SC2086 # ORDER is a fixed word list
{
	dir rel 1000 $ORDER
	# new inodes, mode and mtime, same contents
	cp -r "$T/src" "$T/src0"; rm -rf "$T/src"; cp -r "$T/src0" "$T/src"; chmod 0600 "$T/src/erosq.itb"
	dir same 2000 $ORDER
	cmp -s "$T/rel/erosq-unsigned.swu" "$T/same/erosq-unsigned.swu" && fail "fixture: headers did not change"
	cmp_ok same "same entries, other headers"

	dir order 1000 sw-description rootfs.squashfs erosq.itb
	cmp_fail order "reordered entries"
	dir missing 1000 sw-description erosq.itb
	cmp_fail missing "missing entry"
	echo extra > "$T/src/extra"
	dir extra 1000 $ORDER extra
	cmp_fail extra "extra entry"
	printf 'x' | dd of="$T/src/rootfs.squashfs" bs=1 seek=4000 conv=notrunc 2>/dev/null
	dir byte 1000 $ORDER
	cmp_fail byte "changed payload byte"
	rm -rf "$T/src"; mv "$T/src0" "$T/src"
}
mkdir "$T/plain" && cp "$T/same/"* "$T/plain/" && echo uboot2 > "$T/plain/u-boot.bin" &&
	(cd "$T/plain" && rm SHA256SUMS && sha256sum -- * > SHA256SUMS)
cmp_fail plain "changed plain file"
mkdir "$T/lacks" && cp "$T/same/"* "$T/lacks/" && sed -i '/u-boot.bin/d' "$T/lacks/SHA256SUMS"
cmp_fail lacks "file the rebuild lacks"
mkdir "$T/more" && cp "$T/same/"* "$T/more/" && echo "0000  installer.upt" >> "$T/more/SHA256SUMS"
cmp_ok more "extra file in the rebuild"
mkdir "$T/stale" && cp "$T/same/"* "$T/stale/" && cp "$T/order/erosq-unsigned.swu" "$T/stale/"
cmp_fail stale ".swu that does not match its SHA256SUMS"
echo "PASS: repro-cmp.py ignores cpio headers, catches every payload difference"
