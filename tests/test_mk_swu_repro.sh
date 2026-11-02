#!/bin/sh
# Host self-check that board/erosq/swu/mk-erosq-swu.sh is reproducible: two
# --unsigned builds of the same inputs under a different umask, input mtimes
# and wall-clock second give the same bytes, and the cpio headers carry
# $SOURCE_DATE_EPOCH; sign-release.sh --local repacks the same way. Needs
# mksquashfs/unsquashfs, cpio, openssl.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MK="$HERE/board/erosq/swu/mk-erosq-swu.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$T/root/etc/swupdate"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T/k.pem" 2>/dev/null
openssl pkey -in "$T/k.pem" -pubout -out "$T/root/etc/swupdate/public.pem"
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

# the signature has a random PSS salt, so check the headers, not the bytes
(umask 077 && SOURCE_DATE_EPOCH=1761998400 sh "$HERE/board/erosq/swu/sign-release.sh" --local "$T/a.swu" "$T/k.pem" "$T/s.swu" >/dev/null) ||
	fail "sign-release.sh --local"
cpio -itv --quiet < "$T/s.swu" > "$T/slist" 2>/dev/null
[ "$(awk '{ print $NF }' "$T/slist" | tr '\n' ' ')" = "sw-description sw-description.sig erosq.itb rootfs.squashfs " ] ||
	fail "signed cpio order"
[ "$(grep ' sw-description$' "$T/slist")" = "$(grep ' sw-description$' "$T/list")" ] ||
	fail "signed sw-description header differs from the unsigned one"
awk '$1 != "-rw-r--r--" || $3 != "root" || $4 != "root" { exit 1 }' "$T/slist" || fail "signed entries not 0644 root:root: $(cat "$T/slist")"
echo "PASS: mk-erosq-swu.sh and sign-release.sh are reproducible"
