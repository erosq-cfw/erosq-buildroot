#!/bin/sh
# Host self-check for sd-hotplug's resume record on card removal. Runs the
# SHIPPED script against a stub mpc (fake MPD state) and stub umount/sd-mount.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$HERE/package/erosq-board/files/usr/sbin/sd-hotplug}"   # SRC= override: mutant checks
fail() { echo "FAIL: $*"; exit 1; }

run() {   # $1 = ACTION, $2 = mpd state (playing|paused|stopped), $3 = songid, $4 = m:ss
	T=$(mktemp -d); export T
	mkdir -p "$T/bin"
	echo "$2" > "$T/state"; echo "$3" > "$T/id"; echo "$4" > "$T/time"; : > "$T/calls"
	cat > "$T/bin/mpc" <<'EOF'
#!/bin/sh
echo "mpc $*" >> "$T/calls"
[ "$1" = -q ] && shift
case "$1 $2" in
"status %state%") cat "$T/state" ;;
"status %currenttime%") cat "$T/time" ;;
"current -f") cat "$T/id" ;;
"stop ") echo stopped > "$T/state" ;;
esac
EOF
	printf '#!/bin/sh\necho "umount $*" >> "$T/calls"\n' > "$T/bin/umount"
	printf '#!/bin/sh\necho "sd-mount" >> "$T/calls"\n' > "$T/bin/sd-mount"
	chmod +x "$T/bin/"*
	sed -e "s|/run/sd-resume|$T/resume|; s|/usr/sbin/sd-mount|sd-mount|" "$SRC" > "$T/hp"
	ACTION=$1 PATH="$T/bin:$PATH" sh "$T/hp"
}
rec() { cat "$T/resume" 2>/dev/null || echo "<none>"; }
before() { # $1 before $2 in the call log
	a=$(grep -n "$1" "$T/calls" | head -1 | cut -d: -f1); b=$(grep -n "$2" "$T/calls" | head -1 | cut -d: -f1)
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

run remove playing 57 0:55     # mid-song pull: record id + seconds, stop BEFORE umount
[ "$(rec)" = "57 55" ] || fail "playing: record '$(rec)'"
before "mpc -q stop" "umount" || fail "playing: not stopped before umount"
grep -q "mpc update" "$T/calls" || fail "playing: no update"; rm -rf "$T"
run remove paused 9 3:08       # paused pull: the paused position is kept
[ "$(rec)" = "9 188" ] || fail "paused: record '$(rec)'"
grep -q "mpc -q stop" "$T/calls" || fail "paused: not stopped"; rm -rf "$T"
run remove playing 4 75:00     # past an hour: mpc prints minutes only
[ "$(rec)" = "4 4500" ] || fail "long: record '$(rec)'"; rm -rf "$T"
run remove playing 4 2:00      # :00 seconds (leading-zero strip leaves 0)
[ "$(rec)" = "4 120" ] || fail "zero secs: record '$(rec)'"; rm -rf "$T"
run remove stopped 57 0:00     # already stopped: no record, no stop
[ "$(rec)" = "<none>" ] || fail "stopped: wrote '$(rec)'"
grep -q "mpc -q stop" "$T/calls" && fail "stopped: sent stop"
grep -q "umount" "$T/calls" || fail "stopped: no umount"; rm -rf "$T"
# second remove event (disk after partition): MPD now stopped, first record kept
run remove playing 57 0:55; ACTION=remove PATH="$T/bin:$PATH" sh "$T/hp"
[ "$(rec)" = "57 55" ] || fail "2nd remove: record '$(rec)'"; rm -rf "$T"
run add playing 57 0:55        # add: mount + update only, no record
[ "$(rec)" = "<none>" ] || fail "add: wrote a record"
before "sd-mount" "mpc update" || fail "add: no mount+update"; rm -rf "$T"
echo "test_sd_hotplug: all passed"
