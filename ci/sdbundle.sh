#!/usr/bin/env bash
# Build the SD-card bundle (games, emulators, launchers, themes) against the
# staging sysroot of a finished ci/rootfs.sh build, so every binary links the
# libraries that rootfs ships. Same steps locally and in CI.
#   ci/sdbundle.sh <rootfs dir> <out dir>
# Leaves <out>/{erosq-sd-bundle.zip,SOURCES.txt,build.log}. Unzip the bundle
# onto the root of the SD card. No game data, BIOS or ROMs are included.
set -euo pipefail
EXT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=pins.mk disable=SC1091
. "$EXT/pins.mk"
W=$(cd "${1:?usage: $0 <rootfs dir> <out dir>}" && pwd)
OUT=$(mkdir -p "${2:?usage: $0 <rootfs dir> <out dir>}" && cd "$2" && pwd)
die() { echo "sdbundle: ERROR: $*" >&2; exit 1; }
H=$W/out-br/host
[ -x "$H/bin/mipsel-buildroot-linux-musl-gcc" ] || die "no rootfs build in $W (ci/rootfs.sh first)"
[ -d "$W/root/usr/lib" ] || die "no unpacked rootfs in $W/root"
export PATH=$H/bin:$PATH SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$EXT" log -1 --format=%ct)}
T=mipsel-buildroot-linux-musl
J=$(nproc)
B=$W/sd-src
D=$W/sd
rm -rf "$B" "$D" && mkdir -p "$B" "$D"
GH=https://github.com
# fetch <dir> <repo url> <sha>: exactly that commit, nothing else
fetch() {
	git init -q "$1"
	git -C "$1" fetch -q --depth 1 "$2" "$3"
	git -C "$1" -c advice.detachedHead=false checkout -q FETCH_HEAD
}
exec > >(tee "$OUT/build.log") 2>&1

fetch "$B/sd-bundle" $GH/erosq-cfw/sd-bundle "$SD_BUNDLE_SHA"
fetch "$B/erosq-ui" $GH/erosq-cfw/erosq-ui "$EROSQ_UI_SHA"
fetch "$B/pcsx" $GH/erosq-cfw/pcsx_rearmed "$PCSX_SHA"
git -C "$B/pcsx" submodule -q update --init --depth 1 frontend/libpicofe frontend/warm deps/libchdr deps/libretro-common deps/mman
fetch "$B/picoarch" $GH/erosq-cfw/picoarch "$PICOARCH_SHA"
git -C "$B/picoarch" submodule -q update --init --depth 1
fetch "$B/gambatte" $GH/libretro/gambatte-libretro "$GAMBATTE_SHA"
fetch "$B/gpsp" $GH/libretro/gpsp "$GPSP_SHA"
fetch "$B/opentyrian" $GH/erosq-cfw/opentyrian "$OPENTYRIAN_SHA"
fetch "$B/openjazz" $GH/erosq-cfw/openjazz "$OPENJAZZ_SHA"
fetch "$B/doom" $GH/erosq-cfw/doomgeneric-erosq "$DOOM_SHA"
# doom/build.sh clones these unpinned when absent; pin them first
fetch "$B/doom/doomgeneric" $GH/ozkl/doomgeneric "$DOOMGENERIC_SHA"
fetch "$B/doom/tinyalsa" $GH/tinyalsa/tinyalsa "$TINYALSA_SHA"

# --- build ---
# pcsx: plain -Ofast build (no PGO until there is a gcc 15 profile)
(cd "$B/pcsx" && CROSS_COMPILE=$T- ./configure --platform=erosq --gpu=unai --dynarec=mipsrec &&
	make -j"$J" USE_ASYNC_CDROM=1 CFLAGS_OPT="-Ofast --param max-unroll-times=2")
make -C "$B/picoarch" -j"$J" EROSQ=1 CROSS_COMPILE=$T- picoarch
make -C "$B/gambatte" -j"$J" -f Makefile.libretro platform=unix CC=$T-gcc CXX=$T-g++
make -C "$B/gpsp" -j"$J" platform=mips32 CC=$T-gcc CXX=$T-g++
make -C "$B/opentyrian" -j"$J" CC=$T-gcc PKG_CONFIG="$H/bin/pkg-config" PLATFORM=UNIX \
	WITH_NETWORK=false TYRIAN_DIR=/media/sd/opentyrian/data CFLAGS="-O2 -fomit-frame-pointer -DTARGET_EROSQ"
# log.h logs __FILE__: keep the build path out of the binary
FPM=-ffile-prefix-map=$B/openjazz/=
cmake -B "$B/openjazz/build-port" -S "$B/openjazz" -DCMAKE_TOOLCHAIN_FILE="$H/share/buildroot/toolchainfile.cmake" \
	-DTARGET_EROSQ=ON -DNETWORK=OFF -DSCALE=OFF -DCMAKE_BUILD_TYPE=Release -DDATAPATH=/media/sd/ojspike/jazz \
	-DCMAKE_CXX_FLAGS="-O2 -fomit-frame-pointer $FPM" -DCMAKE_C_FLAGS="-O2 -fomit-frame-pointer $FPM"
cmake --build "$B/openjazz/build-port" -j"$J"
BR_HOST=$H sh "$B/doom/build.sh"

# --- assemble the SD tree (launcher names are the extras.tsv paths) ---
cp -a "$B/sd-bundle/doom" "$B/sd-bundle/gb" "$B/sd-bundle/gba" "$B/sd-bundle/ojspike" \
	"$B/sd-bundle/opentyrian" "$B/sd-bundle/psx" "$D/"
mkdir -p "$D/picoarch/cores" "$D/themes"
install -m755 "$B/pcsx/pcsx" "$D/psx/pcsx"
install -m755 "$B/picoarch/picoarch" "$D/picoarch/picoarch"
install -m755 "$B/gambatte/gambatte_libretro.so" "$B/gpsp/gpsp_libretro.so" "$D/picoarch/cores/"
install -m755 "$B/opentyrian/opentyrian" "$D/opentyrian/opentyrian.elf"
install -m755 "$B/openjazz/build-port/OpenJazz" "$D/ojspike/OpenJazz.elf"
install -m755 "$B/doom/build/doomgeneric" "$D/doom/doomgeneric"
cp -a "$B/erosq-ui/docs/themes/." "$D/themes/"
cp "$B/sd-bundle/LICENSE" "$D/LICENSE-launchers"
ELFS=$(find "$D" -type f -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print | sort)
# shellcheck disable=SC2086
$T-strip --strip-unneeded $ELFS

# --- gates ---
for f in $ELFS; do
	file -b "$f" | grep -q 'ELF 32-bit LSB.*MIPS' || die "${f#"$D"/} is not a mipsel ELF"
	# every NEEDED library must be in the rootfs image
	for n in $($T-readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
		[ -e "$W/root/lib/$n" ] || [ -e "$W/root/usr/lib/$n" ] || die "${f#"$D"/} needs $n, not in the rootfs"
	done
done
P=$(grep -r -l -a -F -e "$W" -e "$EXT" -e /workspace -e /home/ -e ubuntu@ "$D" || true)
[ -z "$P" ] || die "build paths in: ${P//$D/}"
K=$(find "$D" -name '*authorized_keys*' -o -name '*.wad' -o -name '*.WAD' -o -name 'scph*' -o -name '*.bin' ! -path "$D/themes/*" ||:)
[ -z "$K" ] || die "unexpected files: ${K//$D/}"

# --- sources: GPL binaries ship with the exact commits they were built from ---
{
	echo "EROS Q SD-card bundle, built by erosq-buildroot $(git -C "$EXT" rev-parse HEAD)"
	echo "Each binary is built from these public commits:"
	echo "psx/pcsx                 $GH/erosq-cfw/pcsx_rearmed $PCSX_SHA (with its submodules)"
	echo "picoarch/picoarch        $GH/erosq-cfw/picoarch $PICOARCH_SHA (with its submodules)"
	echo "picoarch/cores/gambatte  $GH/libretro/gambatte-libretro $GAMBATTE_SHA"
	echo "picoarch/cores/gpsp      $GH/libretro/gpsp $GPSP_SHA"
	echo "opentyrian/opentyrian.elf $GH/erosq-cfw/opentyrian $OPENTYRIAN_SHA"
	echo "ojspike/OpenJazz.elf     $GH/erosq-cfw/openjazz $OPENJAZZ_SHA"
	echo "doom/doomgeneric         $GH/erosq-cfw/doomgeneric-erosq $DOOM_SHA"
	echo "                         + $GH/ozkl/doomgeneric $DOOMGENERIC_SHA"
	echo "                         + $GH/tinyalsa/tinyalsa $TINYALSA_SHA"
	echo "launchers                $GH/erosq-cfw/sd-bundle $SD_BUNDLE_SHA"
	echo "themes                   $GH/erosq-cfw/erosq-ui $EROSQ_UI_SHA (docs/themes)"
} > "$D/SOURCES.txt"
cp "$D/SOURCES.txt" "$OUT/"

# --- deterministic zip: sorted names, fixed times, mode bits kept ---
python3 -I - "$D" "$OUT/erosq-sd-bundle.zip" "$SOURCE_DATE_EPOCH" <<-'EOF'
import os, sys, time, zipfile
root, out, sde = sys.argv[1], sys.argv[2], int(sys.argv[3])
dt = time.gmtime(max(sde, 315532800))[:6]
names = sorted(os.path.relpath(os.path.join(d, f), root)
               for d, _, fs in os.walk(root) for f in fs)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for n in names:
        p = os.path.join(root, n)
        zi = zipfile.ZipInfo(n, dt)
        zi.external_attr = (0o100755 if os.access(p, os.X_OK) else 0o100644) << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(p, "rb") as f:
            z.writestr(zi, f.read())
EOF
(cd "$D" && find . -type f | sort | xargs ls -l)
(cd "$OUT" && sha256sum erosq-sd-bundle.zip)
