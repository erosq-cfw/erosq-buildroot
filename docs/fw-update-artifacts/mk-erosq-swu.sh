#!/bin/sh
# Build a signed EROS Q .swu firmware bundle with REAL per-component versions.
# Usage: mk-erosq-swu.sh [--key <private.pem>] <erosq.itb> <rootfs.squashfs> <out.swu>
#
# Versions are NOT arguments — they are the same content-tied sources post-build.sh
# bakes into the rootfs's /etc/sw-versions, so the .swu's declared versions always
# match what install-if-different compares against on the device:
#   kernel = $KERNEL_VERSION_FILE (default ../build-output/kernel.version: the
#            kernel release + source commit, written by the kernel build)
#   rootfs = `git describe` of this tree
#   ui     = `git describe` of ../erosq-ui (the checkout next to this tree)
# Run bundling right after the rootfs build (before committing) so RVER matches.
#
# RSA-PSS signs sw-description with the private key (saltlen -2): --key, or
# $EROSQ_SWU_KEY. The device only accepts bundles signed by the key whose
# public half is in /etc/swupdate/public.pem (BR2_PACKAGE_EROSQ_BOARD_SWU_PUBKEY).
# The sha256 in sw-description authenticates each image, so one signature
# covers the bundle.
set -e
KEY=${EROSQ_SWU_KEY:-}
if [ "$1" = --key ]; then KEY="$2"; shift 2; fi
[ $# -eq 3 ] || { echo "usage: $0 [--key <private.pem>] <erosq.itb> <rootfs.squashfs> <out.swu>" >&2; exit 2; }
ITB="$1"; SQFS="$2"; OUT="$3"
HERE=$(cd "$(dirname "$0")" && pwd)
BR_EXT=$(cd "$HERE/../.." && pwd)
TMPL="$HERE/sw-description.in"
[ -n "$KEY" ] || { echo "no signing key: pass --key <private.pem> or set EROSQ_SWU_KEY" >&2; exit 1; }
[ -f "$KEY" ]  || { echo "missing signing key $KEY" >&2; exit 1; }
[ -f "$ITB" ]  || { echo "missing $ITB" >&2; exit 1; }
[ -f "$SQFS" ] || { echo "missing $SQFS" >&2; exit 1; }

KVER=$(cat "${KERNEL_VERSION_FILE:-$BR_EXT/../build-output/kernel.version}" 2>/dev/null || echo "unknown")
RVER=$(git -C "$BR_EXT" describe --tags --always --dirty 2>/dev/null || echo "unknown")
[ "$KVER" = unknown ] && echo "WARN: kernel.version missing (set KERNEL_VERSION_FILE)" >&2

# FWVER = the single bundle/firmware version that swupdate gates on (sw-description
# top-level "version"). It is a COMPOSITE of every source that feeds the image so it
# changes whenever ANY of them changes -- kernel, rootfs recipe (erosq-br), or the
# erosq-ui binary (a separate repo whose change would NOT move RVER). Thus nothing
# can be silently skipped. The device passes its running FWVER as
# `swupdate -R <FWVER>` (--no-reinstalling): an equal version is rejected in the
# parser (no volume/bootenv touched); ANY different version (up or down) installs
# both components -> the inactive slot is always coherent. MUST match the composite
# post-build.sh bakes into /etc/sw-versions.
UIVER=$(git -C "$BR_EXT/../erosq-ui" describe --tags --always --dirty 2>/dev/null || echo "unknown")
FWVER="${RVER}+${KVER}+ui${UIVER}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$ITB" "$WORK/erosq.itb"
cp "$SQFS" "$WORK/rootfs.squashfs"
KSHA=$(sha256sum "$WORK/erosq.itb"       | cut -d' ' -f1)
RSHA=$(sha256sum "$WORK/rootfs.squashfs" | cut -d' ' -f1)
# '&' and '/' are sed replacement metacharacters; version strings use neither
# (git-describe / kernel release: alnum . - _ + only), so plain s/// is safe.
sed -e "s/@FWVER@/$FWVER/g" -e "s/@KVER@/$KVER/g" -e "s/@RVER@/$RVER/g" \
	-e "s/@K_SHA@/$KSHA/g" -e "s/@R_SHA@/$RSHA/g" \
	"$TMPL" > "$WORK/sw-description"
openssl dgst -sha256 -sign "$KEY" \
	-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-2 \
	-out "$WORK/sw-description.sig" "$WORK/sw-description"
( cd "$WORK" && printf '%s\n' sw-description sw-description.sig erosq.itb rootfs.squashfs \
	| cpio -o -H crc 2>/dev/null ) > "$OUT"
echo "built $OUT  fw=$FWVER  (kernel=$KVER rootfs=$RVER)  kSHA=$KSHA  rSHA=$RSHA"
