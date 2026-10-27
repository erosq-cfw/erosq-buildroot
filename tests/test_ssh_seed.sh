#!/bin/sh
# Host check for package/erosq-board/files/usr/sbin/erosq-ssh-seed: the
# one-time root authorized_keys seed on /data (lockout guard).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
X="$HERE/package/erosq-board/files/usr/sbin/erosq-ssh-seed"
T=$(mktemp -d /tmp/ssh-seed-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails+1)); }
seed() { EROSQ_SEED_ROOT="$1" sh "$X" >/dev/null 2>&1; }
mode() { stat -c %a "$1"; }
K="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAK test@example"

# 1. public build: no seed file -> nothing created
A=$T/a; mkdir -p "$A/data"
seed "$A" && [ ! -e "$A/data/root/.ssh/authorized_keys" ] && [ ! -e "$A/data/root/.ssh/.seeded" ] \
	&& ok "no seed file: nothing seeded" || fail "no seed file: something was created"

# 2. private build, fresh /data -> seeded, 0600 file, 0700 dir, marker
B=$T/b; mkdir -p "$B/data" "$B/usr/share/erosq"; echo "$K" >"$B/usr/share/erosq/seed-authorized_keys"
seed "$B"
[ "$(cat "$B/data/root/.ssh/authorized_keys" 2>/dev/null)" = "$K" ] && ok "fresh /data: seeded" || fail "fresh /data: not seeded"
[ "$(mode "$B/data/root/.ssh/authorized_keys" 2>/dev/null)" = 600 ] && ok "file mode 600" || fail "file mode not 600"
[ "$(mode "$B/data/root/.ssh" 2>/dev/null)" = 700 ] && ok "dir mode 700" || fail "dir mode not 700"
[ -e "$B/data/root/.ssh/.seeded" ] && ok "marker written" || fail "no marker"

# 3. once only: the user deletes the keys -> not re-seeded
rm "$B/data/root/.ssh/authorized_keys"; seed "$B"
[ ! -e "$B/data/root/.ssh/authorized_keys" ] && ok "deleted keys stay deleted" || fail "re-seeded after a delete"

# 4. existing keys (no marker yet) -> left untouched
C=$T/c; mkdir -p "$C/data/root/.ssh" "$C/usr/share/erosq"; echo "$K" >"$C/usr/share/erosq/seed-authorized_keys"
echo "ssh-rsa USERKEY mine" >"$C/data/root/.ssh/authorized_keys"
seed "$C"
[ "$(cat "$C/data/root/.ssh/authorized_keys")" = "ssh-rsa USERKEY mine" ] && ok "existing keys untouched" || fail "existing keys overwritten"
[ -e "$C/data/root/.ssh/.seeded" ] && ok "marker written with existing keys" || fail "no marker with existing keys"

# 5. empty seed file counts as no seed
E=$T/e; mkdir -p "$E/data" "$E/usr/share/erosq"; : >"$E/usr/share/erosq/seed-authorized_keys"
seed "$E" && [ ! -e "$E/data/root/.ssh/.seeded" ] && ok "empty seed: nothing seeded" || fail "empty seed acted"

[ $fails -eq 0 ] && echo "OK: 0 failure(s)" || { echo "FAILED: $fails"; exit 1; }
