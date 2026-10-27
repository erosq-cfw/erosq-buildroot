#!/bin/sh
# Host check for global-patches/mpd 0005 (a cancelled update must not shrink
# the saved db) and 0006 (the state-file restore keeps queued songs the db
# does not know yet). Builds MPD for the HOST from Buildroot's tarball plus
# every global-patches/mpd patch, then runs mpd_stale_db.py against it.
#   BR=<buildroot dir>      default ../buildroot-2026.08 (next to this tree)
#   FLAC=<any .flac file>   default ../test.flac (next to this tree)
#   SKIP='0005 0006'        leave patches out (mutant check: must FAIL)
# Needs network once (fmt/flac/ogg wraps) and ~2 min to build.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
BR=${BR:-$HERE/../buildroot-2026.08}
FLAC=${FLAC:-$HERE/../test.flac}
SKIP=${SKIP:-}
H=$BR/output/host/bin            # Buildroot's meson + ninja (its python has no ssl/lzma)
V=$(sed -n 's/^MPD_VERSION_MAJOR = //p' "$BR/package/mpd/mpd.mk").$(sed -n 's/^MPD_VERSION = $(MPD_VERSION_MAJOR)\.//p' "$BR/package/mpd/mpd.mk")
W=$(mktemp -d /tmp/mpd-stale-db.XXXXXX)
trap 'rm -rf "$W"' EXIT
cd "$W"
tar xf "$BR/dl/mpd/mpd-$V.tar.xz"
cd "mpd-$V"
for p in "$HERE"/global-patches/mpd/*.patch; do
	n=$(basename "$p"); case " $SKIP " in *" ${n%%-*} "*) echo "skip $n"; continue ;; esac
	patch -p1 -s < "$p"
done
# Unpack the wraps by hand: Buildroot's host python cannot download or unxz.
cd subprojects
for w in fmt flac ogg; do
	get() { sed -n "s/^$1 *= *//p" "$w.wrap"; }
	curl -sfL -o src.tar "$(get source_url)" && tar xf src.tar
	curl -sfL -o p.zip "$(get patch_url)"
	python3 -I -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(".")' p.zip
done
cd ..
PATH=$H:$PATH PKG_CONFIG=/usr/bin/pkg-config "$H/python3" "$H/meson" setup build \
	--buildtype=debugoptimized --auto-features=disabled --wrap-mode=forcefallback \
	-Ddatabase=true -Dflac=enabled -Ddaemon=true -Dtest=false -Ddocumentation=disabled \
	-Dhttpd=false -Drecorder=false -Dsnapcast=false -Dpipe=false -Dfifo=false \
	-Dmanpages=false -Dhtml_manual=false > "$W/setup.log" 2>&1 || { tail -20 "$W/setup.log"; exit 1; }
PATH=$H:$PATH ninja -C build > "$W/build.log" 2>&1 || { grep -A8 FAILED "$W/build.log" | head -30; exit 1; }
cp "$FLAC" "$W/src.flac"           # hard-linked 4000x; must share a filesystem with $W
rc=0
python3 -I "$HERE/tests/mpd_stale_db.py" "$W/mpd-$V/build/mpd" "$W/run" "$W/src.flac" > "$W/out" 2>&1 || rc=$?
grep -v 'exception: Failed to open' "$W/out"    # first start has no db yet: expected
exit $rc
