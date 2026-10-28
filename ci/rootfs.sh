#!/usr/bin/env bash
# Build the rootfs (erosq_defconfig) against the installed SDK, gate the
# image, and collect legal-info and an SBOM. Same steps locally and in CI.
#   ci/rootfs.sh <dir> <kernel.version>
# Needs sdk/ (ci/sdk.sh install) and the kernel.version from ci/kernel.sh.
# Leaves <dir>/out/{rootfs.squashfs,sw-versions,legal-info.tar.gz,
# sources.tar,sbom.cdx.json,build.log}.
# Env: BR2_DL_DIR (download cache, optional). Parallelism is BR2_JLEVEL.
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=pins.mk disable=SC1091
. "$EXT/pins.mk"
W=$(mkdir -p "${1:?usage: $0 <dir> <kernel.version>}" && cd "$1" && pwd)
KV=$(cat "${2:?usage: $0 <dir> <kernel.version>}")
die() { echo "rootfs: ERROR: $*" >&2; exit 1; }
[ -x "$EXT/sdk/bin/mipsel-linux-gcc" ] || die "no SDK in sdk/ (ci/sdk.sh install)"

BR=$W/buildroot-$BUILDROOT_VERSION
TB=$W/buildroot-$BUILDROOT_VERSION.tar.gz
[ -f "$TB" ] || wget -q -O "$TB" "https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.gz"
echo "$BUILDROOT_SHA256  $TB" | sha256sum -c -
rm -rf "$BR" && tar -xzf "$TB" -C "$W"
"$EXT/apply-patches.sh" "$BR"

export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$EXT" log -1 --format=%ct)}
export EROSQ_KERNEL_VERSION=$KV
O=$W/out-br
OUT=$W/out
rm -rf "$O" "$OUT" && mkdir -p "$OUT"
M=(make -C "$BR" O="$O" ${BR2_DL_DIR:+BR2_DL_DIR="$BR2_DL_DIR"})
"${M[@]}" BR2_EXTERNAL="$EXT" erosq_defconfig
"${M[@]}" 2>&1 | tee "$OUT/build.log"
"${M[@]}" legal-info >/dev/null
"${M[@]}" -s show-info | python3 -I "$BR/utils/generate-cyclonedx" > "$OUT/sbom.cdx.json"

# --- gates on the image itself, not the target/ dir ---
cp "$O/images/rootfs.squashfs" "$OUT/"
R=$W/root
rm -rf "$R" && unsquashfs -q -d "$R" "$OUT/rootfs.squashfs" >/dev/null
cp "$R/etc/sw-versions" "$OUT/"
grep -E '^firmware [A-Za-z0-9.+_-]+$' "$OUT/sw-versions" | grep -qv -e unknown -e -dirty ||
	die "bad /etc/sw-versions: $(tr '\n' ' ' < "$OUT/sw-versions")"
# no SSH keys: public images ship none (users put theirs under /data)
K=$(find "$R" -name '*authorized_keys*' ! -type l)
[ -z "$K" ] || die "SSH keys in the image: ${K//$R/}"
# no build paths or builder identity
P=$(grep -r -l -a -F -e "$W" -e "$EXT" -e /workspace -e /home/ -e ubuntu@ "$R" || true)
[ -z "$P" ] || die "build paths in: ${P//$R/}"
# chip firmware: if present it must be the pinned stock files (see
# package/erosq-board/extract-stock-firmware.py); absent is allowed
FW=$R/lib/firmware
if [ -e "$FW/brcm/brcmfmac43430-sdio.bin" ]; then
	python3 -I - "$EXT/package/erosq-board/extract-stock-firmware.py" "$FW" <<-'EOF'
	import hashlib, runpy, sys
	g = runpy.run_path(sys.argv[1]); fw = sys.argv[2]
	want = {"brcm/brcmfmac43430-sdio.bin": g["STOCK"]["firmware/cyw43438-7.46.58.35.bin"],
	        "brcm/brcmfmac43430-sdio.txt": g["NVRAM_OUT"],
	        "brcm/BCM43430A1.hcd": g["STOCK"]["lib/firmware/BCM4343A1_001.002.009.0122.0538.hcd"],
	        "BCM4343A1_001.002.009.0122.0538.hcd": g["STOCK"]["lib/firmware/BCM4343A1_001.002.009.0122.0538.hcd"]}
	bad = [p for p, h in want.items()
	       if hashlib.sha256(open(f"{fw}/{p}", "rb").read()).hexdigest() != h]
	sys.exit(f"rootfs: ERROR: chip firmware not the pinned stock files: {bad}" if bad else 0)
	EOF
else
	echo "::warning::rootfs: no Wi-Fi/BT chip firmware in the image (Wi-Fi and BT off)"
fi

# legal-info: the config and manifests name BR2_EXTERNAL by its build path;
# replace it (and refresh those files' lines in legal-info.sha256)
L=$O/legal-info
for f in buildroot.config manifest.csv host-manifest.csv; do
	sed -i "s|$EXT|erosq-buildroot|g; s|$W|build|g" "$L/$f"
	h=$(sha256sum "$L/$f" | cut -d' ' -f1)
	sed -i "s|^[0-9a-f]\{64\}  $f\$|$h  $f|" "$L/legal-info.sha256"
done
P=$(grep -r -l -a -F -e "$W" -e "$EXT" -e /workspace -e /home/ -e ubuntu@ \
	--exclude-dir=sources --exclude-dir=host-sources "$L" || true)
[ -z "$P" ] || die "build paths in legal-info: ${P//$L/}"
(cd "$L" && sha256sum -c --quiet legal-info.sha256) || die "legal-info.sha256 mismatch"

# legal-info: sources (already compressed) apart from the rest
tar -C "$O/legal-info" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
	--numeric-owner -cf "$OUT/sources.tar" sources host-sources
tar -C "$O/legal-info" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
	--numeric-owner --exclude=./sources --exclude=./host-sources -cf - . |
	gzip -9 -n > "$OUT/legal-info.tar.gz"
ls -l "$OUT"
cat "$OUT/sw-versions"
