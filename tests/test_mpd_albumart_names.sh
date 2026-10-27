#!/bin/sh
# Host test for global-patches/mpd/0007: apply every mpd patch in order to the
# pristine tarball (as Buildroot does) and check find_stream_art() tries the
# folder-image names after cover.*, in order. The device check is
# `mpc albumart <song>` on an album with only folder.jpg.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
TARBALL=${MPD_TARBALL:-$HERE/../buildroot-2026.08/dl/mpd/mpd-0.24.15.tar.xz}
[ -f "$TARBALL" ] || { echo "SKIP: no $TARBALL"; exit 0; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
tar xf "$TARBALL" -C "$W"
cd "$W"/mpd-*
for p in "$HERE"/global-patches/mpd/*.patch; do
	patch -p1 -s --no-backup-if-mismatch < "$p" || { echo "FAIL: $(basename "$p") does not apply"; exit 1; }
done
got=$(sed -n '/find_stream_art(std::string_view/,/^	};/p' src/command/FileCommands.cxx \
	| grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ')
want="cover.png cover.jpg cover.webp folder.jpg folder.png front.jpg AlbumArt.jpg albumart.jpg Folder.jpg "
if [ "$got" = "$want" ]; then echo "PASS: albumart names: $got"; else
	echo "FAIL: albumart names"; echo " got:  $got"; echo " want: $want"; exit 1; fi
