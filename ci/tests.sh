#!/usr/bin/env bash
# Run every tests/test_*.sh with what it looks for, so that none skips:
# a patched Buildroot tree with dl/mpd, host meson + ninja and the
# wpa_supplicant source, the SDK (qemu-mipsel tests) and a FLAC file.
#   ci/tests.sh <dir>
# Needs sdk/ (ci/sdk.sh install), qemu-user, flac, squashfs-tools,
# wpasupplicant (wpa_supplicant + wpa_cli), iproute2 and unprivileged user
# namespaces. Env: BR2_DL_DIR (download cache), FLAC (else one is generated).
# Fails if a test fails or prints SKIP. Logs in <dir>/logs/.
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=pins.mk disable=SC1091
. "$EXT/pins.mk"
W=$(mkdir -p "${1:?usage: $0 <dir>}" && cd "$1" && pwd)
die() { echo "tests: ERROR: $*" >&2; exit 1; }
[ -x "$EXT/sdk/bin/mipsel-linux-gcc" ] || die "no SDK in sdk/ (ci/sdk.sh install)"

BR=$W/buildroot-$BUILDROOT_VERSION
TB=$W/buildroot-$BUILDROOT_VERSION.tar.gz
[ -f "$TB" ] || wget -q -O "$TB" "https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.gz"
echo "$BUILDROOT_SHA256  $TB" | sha256sum -c -
rm -rf "$BR" && tar -xzf "$TB" -C "$W"
"$EXT/apply-patches.sh" "$BR"
# the tests read $BR/dl and $BR/output (Buildroot's default layout)
if [ -n "${BR2_DL_DIR:-}" ]; then mkdir -p "$BR2_DL_DIR" && ln -s "$BR2_DL_DIR" "$BR/dl"; fi
make -C "$BR" -s BR2_EXTERNAL="$EXT" erosq_defconfig
make -C "$BR" host-meson host-ninja mpd-source wpa_supplicant-patch > "$W/setup.log" 2>&1 ||
	{ tail -30 "$W/setup.log"; die "Buildroot setup failed"; }

if [ -z "${FLAC:-}" ]; then
	FLAC=$W/test.flac
	python3 -I - "$W/test.wav" <<-'EOF'
	import math, struct, sys, wave
	with wave.open(sys.argv[1], "wb") as w:  # 10 s, 440 Hz, 44.1 kHz stereo
	    w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
	    w.writeframes(b"".join(struct.pack("<hh", s, s) for s in
	        (int(8000 * math.sin(2 * math.pi * 440 * i / 44100)) for i in range(441000))))
	EOF
	flac -s -f -o "$FLAC" "$W/test.wav"
fi

MPD_TARBALL=$(ls "$BR"/dl/mpd/mpd-*.tar.xz)
export MPD_TARBALL
mkdir -p "$W/logs"
fail=0
for t in "$EXT"/tests/test_*.sh; do
	n=$(basename "$t" .sh)
	if BR=$BR FLAC=$FLAC sh "$t" > "$W/logs/$n.log" 2>&1; then r=ok; else r=FAIL; fi
	grep -q -w SKIP "$W/logs/$n.log" && r="$r+SKIP"
	echo "$r $n"
	[ "$r" = ok ] || { fail=1; tail -20 "$W/logs/$n.log"; }
done
[ "$fail" = 0 ] || die "test failures or skips (logs in $W/logs)"
