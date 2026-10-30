#!/bin/sh
# Host self-check for board/erosq/swu/sign-release.sh --local: signs an
# unsigned .swu into the signed cpio order, the signature verifies against the
# rootfs's own public.pem, and a wrong key or a tampered image is refused.
# Needs mksquashfs/unsquashfs, openssl, cpio.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
MK="$HERE/board/erosq/swu/mk-erosq-swu.sh"
SIGN="$HERE/board/erosq/swu/sign-release.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
key() { openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1" 2>/dev/null; }
key "$T/k.pem"; key "$T/other.pem"
mkdir -p "$T/root/etc/swupdate"
printf 'firmware 1234abc+6.18.59-gabc+uie4f0fc7\nkernel 6.18.59-gabc\nrootfs 1234abc\n' > "$T/root/etc/sw-versions"
openssl pkey -in "$T/k.pem" -pubout -out "$T/root/etc/swupdate/public.pem"
mksquashfs "$T/root" "$T/r.sqfs" -quiet -noappend >/dev/null || fail mksquashfs
echo kernel > "$T/k.itb"
sh "$MK" --unsigned "$T/k.itb" "$T/r.sqfs" "$T/u.swu" >/dev/null || fail "unsigned build"

sh "$SIGN" --local "$T/u.swu" "$T/k.pem" "$T/s.swu" >/dev/null || fail "sign"
[ "$(cpio -it --quiet < "$T/s.swu" | tr '\n' ' ')" = "sw-description sw-description.sig erosq.itb rootfs.squashfs " ] ||
	fail "signed cpio order"
mkdir "$T/s" && (cd "$T/s" && cpio -id --quiet < "$T/s.swu")
openssl dgst -sha256 -verify "$T/root/etc/swupdate/public.pem" -sigopt rsa_padding_mode:pss \
	-sigopt rsa_pss_saltlen:-2 -signature "$T/s/sw-description.sig" "$T/s/sw-description" >/dev/null ||
	fail "signature does not verify"
cmp -s "$T/s/rootfs.squashfs" "$T/r.sqfs" || fail "rootfs changed"

sh "$SIGN" --local "$T/u.swu" "$T/other.pem" "$T/x.swu" 2>/dev/null && fail "signed with a key the rootfs does not trust"
sh "$SIGN" --local "$T/s.swu" "$T/k.pem" "$T/x.swu" 2>/dev/null && fail "re-signed an already signed .swu"
mkdir "$T/t" && (cd "$T/t" && cpio -id --quiet < "$T/u.swu" && echo tampered > erosq.itb &&
	printf '%s\n' sw-description erosq.itb rootfs.squashfs | cpio -o -H crc 2>/dev/null > "$T/t.swu")
sh "$SIGN" --local "$T/t.swu" "$T/k.pem" "$T/x.swu" 2>/dev/null && fail "signed a tampered itb"
echo "PASS: sign-release.sh signs, verifies against the rootfs key, refuses bad input"
