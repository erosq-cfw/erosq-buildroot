#!/bin/sh
# Host check for package/erosq-board/extract-stock-firmware.py.
# Always: the build-stopping paths (no source, wrong files, no ubi_reader).
# With EROSQ_STOCK_FW=<stock .upt, SYSTEM.UBI or extracted rootfs dir>: also a
# real extraction, checked for the expected /lib/firmware layout.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
X="$HERE/package/erosq-board/extract-stock-firmware.py"
W=$(mktemp -d /tmp/stockfw-test.XXXXXX)
trap 'rm -rf "$W"' EXIT
fails=0
expect_fail() {	# name, grep pattern, args...
	name=$1 pat=$2; shift 2
	if python3 -I "$X" "$@" >"$W/out" 2>&1; then
		echo "FAIL $name: exit 0"; fails=$((fails+1))
	elif grep -q "$pat" "$W/out" && grep -q 'BR2_PACKAGE_EROSQ_BOARD_STOCK_FW' "$W/out"; then
		echo "PASS $name"
	else
		echo "FAIL $name: $(head -c 300 "$W/out")"; fails=$((fails+1))
	fi
}
expect_fail "no source set" "not set" "" "$W/o"
expect_fail "missing source" "not found" "$W/nope.upt" "$W/o"
mkdir -p "$W/fake/firmware" "$W/fake/lib/firmware"
expect_fail "rootfs without the files" "no firmware/" "$W/fake" "$W/o"
for f in firmware/cyw43438-7.46.58.35.bin firmware/nvram_azw372.txt firmware/wifimac.txt \
	 lib/firmware/BCM4343A1_001.002.009.0122.0538.hcd; do echo junk > "$W/fake/$f"; done
expect_fail "wrong files" "unexpected sha256" "$W/fake" "$W/o"
printf 'not an image' > "$W/bad.upt"
PATH=/usr/bin:/bin expect_fail "no ubi_reader for a .upt" "ubireader_extract_files not found" "$W/bad.upt" "$W/o"
[ -d "$W/o" ] && ls -A "$W/o" | grep -q . && { echo "FAIL a failed run left files"; fails=$((fails+1)); }

if [ -n "${EROSQ_STOCK_FW:-}" ]; then
	python3 -I "$X" "$EROSQ_STOCK_FW" "$W/real" >/dev/null
	for f in BCM4343A1_001.002.009.0122.0538.hcd brcm/BCM43430A1.hcd \
		 brcm/brcmfmac43430-sdio.bin brcm/brcmfmac43430-sdio.txt; do
		[ -f "$W/real/$f" ] && [ ! -L "$W/real/$f" ] || { echo "FAIL real: $f"; fails=$((fails+1)); }
	done
	for e in bin txt; do
		[ "$(readlink "$W/real/brcm/brcmfmac43430-sdio.aigo,erosq.$e")" = "brcmfmac43430-sdio.$e" ] ||
			{ echo "FAIL real: aigo,erosq.$e link"; fails=$((fails+1)); }
	done
	[ $fails -eq 0 ] && echo "PASS real extraction from $EROSQ_STOCK_FW"
fi
echo "$([ $fails -eq 0 ] && echo OK || echo FAILED): $fails failure(s)"
[ $fails -eq 0 ]
