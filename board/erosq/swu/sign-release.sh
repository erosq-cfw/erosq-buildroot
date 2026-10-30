#!/bin/sh
# Sign a CI-built release on the maintainer's machine. The key never goes to
# GitHub.
#   sign-release.sh <tag> <private.pem>
#     downloads erosq-unsigned.swu + SHA256SUMS from the draft release <tag>,
#     checks the build provenance attestation and the hashes, signs, verifies,
#     and uploads erosq-<tag>.swu (+ .sha256) and SHA256SUMS.sig to the same
#     draft release.
#   sign-release.sh --local <unsigned.swu> <private.pem> <out.swu>
#     the signing step alone, no network.
# The signature (RSA-PSS, saltlen -2, as mk-erosq-swu.sh --key) covers
# sw-description, which holds the sha256 of erosq.itb and rootfs.squashfs; the
# signed bundle must verify against the public.pem that its own rootfs ships.
# Env: EROSQ_REPO (default erosq-cfw/erosq-buildroot). Needs gh, openssl, cpio,
# unsquashfs. An encrypted key makes openssl ask for its passphrase.
set -eu
die() { echo "sign-release: ERROR: $*" >&2; exit 1; }
USAGE="usage: $0 <tag> <private.pem> | $0 --local <unsigned.swu> <private.pem> <out.swu>"

sign() {  # <unsigned.swu> <key> <out.swu>
	[ -f "$1" ] || die "missing $1"
	[ -f "$2" ] || die "missing key $2"
	[ "$(cpio -it --quiet < "$1" | tr '\n' ' ')" = "sw-description erosq.itb rootfs.squashfs " ] ||
		die "$1 is not an unsigned erosq .swu"
	S=$(mktemp -d)
	for f in sw-description erosq.itb rootfs.squashfs; do
		cpio -i --quiet --to-stdout "$f" < "$1" > "$S/$f"
	done
	for f in erosq.itb rootfs.squashfs; do
		grep -q "\"$(sha256sum "$S/$f" | cut -d' ' -f1)\"" "$S/sw-description" ||
			die "sha256 of $f is not in sw-description"
	done
	unsquashfs -cat "$S/rootfs.squashfs" etc/swupdate/public.pem > "$S/public.pem" 2>/dev/null ||
		die "rootfs ships no /etc/swupdate/public.pem"
	openssl dgst -sha256 -sign "$2" -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-2 \
		-out "$S/sw-description.sig" "$S/sw-description"
	openssl dgst -sha256 -verify "$S/public.pem" -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-2 \
		-signature "$S/sw-description.sig" "$S/sw-description" >/dev/null ||
		die "signature does not verify against the rootfs public.pem (wrong key?)"
	(cd "$S" && printf '%s\n' sw-description sw-description.sig erosq.itb rootfs.squashfs |
		cpio -o -H crc 2>/dev/null) > "$3"
	rm -rf "$S"
	echo "signed $3"
}

if [ "${1:-}" = --local ]; then
	[ $# -eq 4 ] || die "$USAGE"
	sign "$2" "$3" "$4"
	exit 0
fi
[ $# -eq 2 ] || die "$USAGE"
TAG=$1 KEY=$2 REPO=${EROSQ_REPO:-erosq-cfw/erosq-buildroot}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
gh release view "$TAG" -R "$REPO" --json isDraft --jq .isDraft | grep -qx true ||
	die "$TAG is not a draft release in $REPO"
gh release download "$TAG" -R "$REPO" -D "$D" -p erosq-unsigned.swu -p SHA256SUMS
(cd "$D" && grep ' erosq-unsigned.swu$' SHA256SUMS | sha256sum -c -) || die "erosq-unsigned.swu does not match SHA256SUMS"
# built by firmware.yml from this tag (release.yml calls it), nothing else
for f in erosq-unsigned.swu SHA256SUMS; do
	gh attestation verify "$D/$f" -R "$REPO" --signer-workflow "$REPO/.github/workflows/firmware.yml" \
		--source-ref "refs/tags/$TAG" >/dev/null || die "no build provenance from $TAG's release build for $f"
done
OUT=$D/erosq-$TAG.swu
sign "$D/erosq-unsigned.swu" "$KEY" "$OUT"
(cd "$D" && sha256sum "erosq-$TAG.swu" > "erosq-$TAG.swu.sha256" && cat "erosq-$TAG.swu.sha256")
openssl dgst -sha256 -sign "$KEY" -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:-2 \
	-out "$D/SHA256SUMS.sig" "$D/SHA256SUMS"
gh release upload "$TAG" -R "$REPO" "$OUT" "$OUT.sha256" "$D/SHA256SUMS.sig"
echo "uploaded erosq-$TAG.swu to the draft $TAG; test it on hardware, then publish"
