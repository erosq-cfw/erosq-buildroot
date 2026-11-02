#!/bin/sh
# Host self-check that board/erosq/swu/mk-erosq-swu.sh is reproducible: two
# --unsigned builds of the same inputs under a different umask, input mtimes
# and wall-clock second give the same bytes, and the cpio headers carry
# $SOURCE_DATE_EPOCH. Needs mksquashfs/unsquashfs, cpio.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MK="$HERE/board/erosq/swu/mk-erosq-swu.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$T/root/etc"
printf 'firmware 1234abc+6.18.59-gabc+uie4f0fc7\nkernel 6.18.59-gabc\nrootfs 1234abc\n' > "$T/root/etc/sw-versions"
mksquashfs "$T/root" "$T/r.sqfs" -quiet -noappend >/dev/null || fail mksquashfs
echo kernel > "$T/k.itb"

(umask 022 && SOURCE_DATE_EPOCH=1761998400 sh "$MK" --unsigned "$T/k.itb" "$T/r.sqfs" "$T/a.swu" >/dev/null) || fail "build a"
sleep 1; touch "$T/k.itb" "$T/r.sqfs"; chmod 0600 "$T/k.itb"
(umask 077 && SOURCE_DATE_EPOCH=1761998400 sh "$MK" --unsigned "$T/k.itb" "$T/r.sqfs" "$T/b.swu" >/dev/null) || fail "build b"
cmp -s "$T/a.swu" "$T/b.swu" || fail "two builds of the same inputs differ"

cpio -itv --quiet < "$T/a.swu" > "$T/list" 2>/dev/null
[ "$(wc -l < "$T/list")" -eq 3 ] || fail "expected 3 entries"
# -rw-r--r--   1 root     root  ... Nov  1  2025 sw-description
awk '$1 != "-rw-r--r--" || $3 != "root" || $4 != "root" { exit 1 }' "$T/list" || fail "entries not 0644 root:root: $(cat "$T/list")"
(SOURCE_DATE_EPOCH=1761998401 sh "$MK" --unsigned "$T/k.itb" "$T/r.sqfs" "$T/c.swu" >/dev/null) || fail "build c"
cmp -s "$T/a.swu" "$T/c.swu" && fail "SOURCE_DATE_EPOCH is not in the cpio headers"
echo "PASS: mk-erosq-swu.sh is reproducible"
