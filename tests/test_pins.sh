#!/bin/sh
# Self-check for pins.mk: EROSQ_UI_DESCRIBE is `git describe --tags --always` of
# EROSQ_UI_SHA (it goes into /etc/sw-versions), and erosq-ui.hash covers the
# pinned erosq-ui and LVGL tarballs (so a pin bump without a new hash fails here,
# not halfway through a build). EROSQ_UI_REPO: a clone or URL (default GitHub).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PINS="${PINS:-$HERE/pins.mk}"
HASH="$HERE/package/erosq-ui/erosq-ui.hash"
fail() { echo "FAIL: $*"; exit 1; }
# shellcheck disable=SC1090
. "$PINS"
grep -q " erosq-ui-$EROSQ_UI_SHA-git4.tar.gz\$" "$HASH" || fail "no hash for erosq-ui $EROSQ_UI_SHA"
grep -q " v$LVGL_VERSION.tar.gz\$" "$HASH" || fail "no hash for LVGL $LVGL_VERSION"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git clone -q --bare --filter=blob:none "${EROSQ_UI_REPO:-https://github.com/erosq-cfw/erosq-ui.git}" "$T/ui" || fail "clone erosq-ui"
d=$(git -C "$T/ui" describe --tags --always "$EROSQ_UI_SHA") || fail "EROSQ_UI_SHA $EROSQ_UI_SHA not in erosq-ui"
[ "$d" = "$EROSQ_UI_DESCRIBE" ] || fail "EROSQ_UI_DESCRIBE=$EROSQ_UI_DESCRIBE, git describe says $d"
echo "PASS: pins.mk erosq-ui/LVGL pins and hashes agree"
