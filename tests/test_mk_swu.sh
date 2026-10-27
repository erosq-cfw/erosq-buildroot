#!/bin/sh
# Host self-check for board/erosq/swu/mk-erosq-swu.sh: versions come from the
# rootfs's /etc/sw-versions, --unsigned leaves out the signature, --key signs a
# sw-description that verifies, and a -dirty/unknown version is refused.
# Needs mksquashfs/unsquashfs, openssl, cpio.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MK="$HERE/board/erosq/swu/mk-erosq-swu.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkroot() {  # $1 = rootfs version line value
	rm -rf "$T/root" "$T/r.sqfs"; mkdir -p "$T/root/etc"
	printf 'firmware %s+6.18.59-gabc+uie4f0fc7\nkernel 6.18.59-gabc\nrootfs %s\nui e4f0fc7\n' "$1" "$1" > "$T/root/etc/sw-versions"
	mksquashfs "$T/root" "$T/r.sqfs" -quiet -noappend >/dev/null || fail mksquashfs
}
echo kernel > "$T/k.itb"
mkroot 1234abc

sh "$MK" --unsigned "$T/k.itb" "$T/r.sqfs" "$T/u.swu" >/dev/null || fail "--unsigned build"
[ "$(cpio -it --quiet < "$T/u.swu" | tr '\n' ' ')" = "sw-description erosq.itb rootfs.squashfs " ] || fail "unsigned cpio order"
mkdir "$T/u" && (cd "$T/u" && cpio -id --quiet < "$T/u.swu")
grep -q '"version": "1234abc+6.18.59-gabc+uie4f0fc7"' "$T/u/sw-description" || fail "firmware version not from sw-versions"
grep -q "$(sha256sum "$T/r.sqfs" | cut -d' ' -f1)" "$T/u/sw-description" || fail "rootfs sha256 missing"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T/k.pem" 2>/dev/null
openssl pkey -in "$T/k.pem" -pubout -out "$T/p.pem"
sh "$MK" --key "$T/k.pem" "$T/k.itb" "$T/r.sqfs" "$T/s.swu" >/dev/null || fail "--key build"
[ "$(cpio -it --quiet < "$T/s.swu" | tr '\n' ' ')" = "sw-description sw-description.sig erosq.itb rootfs.squashfs " ] || fail "signed cpio order"
mkdir "$T/s" && (cd "$T/s" && cpio -id --quiet < "$T/s.swu")
openssl dgst -sha256 -verify "$T/p.pem" -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-2 \
	-signature "$T/s/sw-description.sig" "$T/s/sw-description" >/dev/null || fail "signature does not verify"
cmp -s "$T/u/sw-description" "$T/s/sw-description" || fail "signed and unsigned sw-description differ"

sh "$MK" "$T/k.itb" "$T/r.sqfs" "$T/n.swu" >/dev/null 2>&1 && fail "built without --key/--unsigned"
for bad in 1234abc-dirty unknown 'a&b'; do
	mkroot "$bad"
	sh "$MK" --unsigned "$T/k.itb" "$T/r.sqfs" "$T/b.swu" >/dev/null 2>&1 && fail "accepted version '$bad'"
done
echo "PASS: mk-erosq-swu.sh"
