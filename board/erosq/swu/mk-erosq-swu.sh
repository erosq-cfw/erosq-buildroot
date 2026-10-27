#!/bin/sh
# Build an EROS Q .swu firmware bundle.
# Usage: mk-erosq-swu.sh {--key <private.pem> | --unsigned} <erosq.itb> <rootfs.squashfs> <out.swu>
#
# Versions are NOT arguments: they come from the rootfs's own /etc/sw-versions
# (written by post-build.sh), so the bundle's declared versions always match what
# the device compares against. `firmware` is the single version swupdate gates on
# (`swupdate -R <running firmware>` rejects an equal version and installs any
# other one, so the inactive slot is always coherent). Needs unsquashfs.
#
# --key: RSA-PSS signs sw-description (saltlen -2) with the private key (or set
# $EROSQ_SWU_KEY). The device only accepts bundles signed by the key whose public
# half is in /etc/swupdate/public.pem (BR2_PACKAGE_EROSQ_BOARD_SWU_PUBKEY). The
# sha256 in sw-description authenticates each image, so one signature covers the
# bundle. --unsigned: CI builds; the maintainer signs the release locally.
set -e
USAGE="usage: $0 {--key <private.pem> | --unsigned} <erosq.itb> <rootfs.squashfs> <out.swu>"
KEY=${EROSQ_SWU_KEY:-}; UNSIGNED=
case "$1" in
	--key) KEY="$2"; shift 2 ;;
	--unsigned) UNSIGNED=1; KEY=; shift ;;
esac
[ $# -eq 3 ] || { echo "$USAGE" >&2; exit 2; }
ITB="$1"; SQFS="$2"; OUT="$3"
TMPL="$(cd "$(dirname "$0")" && pwd)/sw-description.in"
if [ -z "$UNSIGNED" ]; then
	[ -n "$KEY" ] || { echo "no signing key: pass --key <private.pem>, set EROSQ_SWU_KEY, or --unsigned" >&2; exit 1; }
	[ -f "$KEY" ] || { echo "missing signing key $KEY" >&2; exit 1; }
fi
[ -f "$ITB" ]  || { echo "missing $ITB" >&2; exit 1; }
[ -f "$SQFS" ] || { echo "missing $SQFS" >&2; exit 1; }

VERS=$(unsquashfs -cat "$SQFS" etc/sw-versions) || { echo "cannot read etc/sw-versions from $SQFS" >&2; exit 1; }
ver() { printf '%s\n' "$VERS" | sed -n "s/^$1 //p"; }
FWVER=$(ver firmware); KVER=$(ver kernel); RVER=$(ver rootfs)
for v in "$FWVER" "$KVER" "$RVER"; do
	# also keeps the sed below safe: no '&', '/' or other metacharacters
	case "$v" in ""|*unknown*|*-dirty*|*[!A-Za-z0-9.+_-]*) echo "refusing: bad version in sw-versions: '$v'" >&2; exit 1 ;; esac
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$ITB" "$WORK/erosq.itb"
cp "$SQFS" "$WORK/rootfs.squashfs"
KSHA=$(sha256sum "$WORK/erosq.itb"       | cut -d' ' -f1)
RSHA=$(sha256sum "$WORK/rootfs.squashfs" | cut -d' ' -f1)
sed -e "s/@FWVER@/$FWVER/g" -e "s/@KVER@/$KVER/g" -e "s/@RVER@/$RVER/g" \
	-e "s/@K_SHA@/$KSHA/g" -e "s/@R_SHA@/$RSHA/g" \
	"$TMPL" > "$WORK/sw-description"
FILES="sw-description erosq.itb rootfs.squashfs"
if [ -z "$UNSIGNED" ]; then
	openssl dgst -sha256 -sign "$KEY" \
		-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-2 \
		-out "$WORK/sw-description.sig" "$WORK/sw-description"
	FILES="sw-description sw-description.sig erosq.itb rootfs.squashfs"
fi
# shellcheck disable=SC2086 # FILES is a fixed word list; order = swupdate's
( cd "$WORK" && printf '%s\n' $FILES | cpio -o -H crc 2>/dev/null ) > "$OUT"
echo "built $OUT${UNSIGNED:+ (UNSIGNED)}  fw=$FWVER  (kernel=$KVER rootfs=$RVER)  kSHA=$KSHA  rSHA=$RSHA"
