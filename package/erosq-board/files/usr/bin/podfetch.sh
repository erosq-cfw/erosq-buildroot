#!/bin/sh
# podfetch.sh {refresh|download} -- podcast feed indexer + episode downloader.
#
# Two phases so the user can pick episodes between them:
#   refresh  : feed XML -> <Name>/index.tsv   (streamed through podindex)
#   download : <Name>/wanted.txt -> .mp3 files
#
# WiFi comes up only for the duration and is put back the way it was found.
# HTTPS is busybox wget's built-in TLS (CONFIG_TLS=y): encrypted but the server
# is NOT authenticated (busybox networking/tls.c does not verify certificates).
# Accepted deliberately -- the payload is public podcast audio.
#
# erosq-ui runs this BACKGROUNDED and polls $STATUS, so exit codes and the
# status file must be honest.
set -u

CMD="${1:-}"
ROOT="${PODCAST_ROOT:-/media/sd/podcasts}"
FEEDS="${PODCAST_FEEDS:-/media/sd/podcasts.txt}"
PODINDEX="${PODINDEX:-/usr/bin/podindex}"
STATUS="${PODFETCH_STATUS:-/run/podfetch.status}"
MIN_FREE_KB="${PODFETCH_MIN_FREE_KB:-204800}"   # 200 MB: one episode is up to 70 MB
# Refresh's own floor, separate from the download floor above: an index.tsv is
# only ~130 KB, and refresh's write is now safe even on failure (podindex
# exits non-zero on a write error and the atomic mv means the previous index
# survives byte-identical -- see the atomic-replace comment below). Reusing
# the 200 MB download floor for refresh blocked the ONE operation (see what's
# on the feed so you know what to delete) that still needs to work on a
# nearly-full card. 2 MB gives a >15x margin over a real index and is still
# small enough to leave room for the download floor to matter.
REFRESH_MIN_FREE_KB="${PODFETCH_REFRESH_MIN_FREE_KB:-2048}"
LOCK="${PODFETCH_LOCK:-/run/podfetch.lock}"
# Per-read/connect stall timeout, NOT a total transfer deadline -- busybox
# wget's -T resets on every successful read (networking/wget.c: second_cnt is
# reloaded from G.timeout_seconds each time n>0), so 60s is "no bytes for a
# minute", safely survivable for a 70MB episode over a slow WiFi link without
# ever letting a truly stalled connection hang the backgrounded job forever.
WGET_TIMEOUT="${PODFETCH_WGET_TIMEOUT:-60}"
# WiFi lifecycle, overridable for the hermetic test the same way ROOT/FEEDS/
# PODINDEX/STATUS/LOCK already are -- these three are absolute paths, so without
# a seam the /run/wifi-want handling could only be reviewed by eye.
WIFI_UP="${PODFETCH_WIFI_UP:-/usr/bin/wifi_up.sh}"
WIFI_DOWN="${PODFETCH_WIFI_DOWN:-/usr/bin/wifi_down.sh}"
WIFI_WANT="${PODFETCH_WIFI_WANT:-/run/wifi-want}"
# Feed list snapshot, derived from the lock name so it's predictable and lives
# on the same tmpfs. Read the loop's stdin from THIS FILE (never from a pipe):
# a `cmd | while read ...` runs the loop body in a SUBSHELL in POSIX sh, which
# would discard every `rc=1` set inside it once the pipeline exits.
FEEDLIST="$LOCK.list"
# podindex's stderr. On tmpfs next to the lock, NOT in the podcast directory:
# an index.err left on the card after every refresh was itself a review finding,
# and the card is the one thing here that is neither transient nor ours alone.
ERRF="$LOCK.err"
SKIP_TOTAL=0

case "$CMD" in
	refresh|download) ;;
	*) echo "usage: $0 {refresh|download}" >&2; exit 2 ;;
esac

# --- status -------------------------------------------------------------
# One line, rewritten atomically so a mid-write read can't see a torn line.
# <state> <feed-i>/<feed-n> <ep-i>/<ep-n> <pct> <text>
set_status() {
	printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >"$STATUS.new" 2>/dev/null &&
		mv "$STATUS.new" "$STATUS" 2>/dev/null
}

# A status that describes a FINISHED run (success or a specific failure). Once
# one of these is written, cleanup() must not overwrite it with the generic
# "interrupted" line -- the specific reason is more useful than the generic one.
STATUS_FINAL=0
set_status_final() {
	STATUS_FINAL=1
	set_status "$@"
}

# --- mutex --------------------------------------------------------------
# This busybox has NO flock. mkdir is the atomic primitive; LOCKED gates the
# trap so we only ever remove a lock we created. Same pattern as wifi_up.sh.
LOCKED=0
cleanup() {
	if [ "$WIFI_WAS_UP" = 0 ] && [ "${PODFETCH_NO_WIFI:-0}" = 0 ]; then
		# Mirror what the UI does (ui_net.c wifi_want_save): wifi_down.sh
		# takes the power mutex and then honours /run/wifi-want as the
		# LAST intent -- a stale "1" (the user toggled WiFi on earlier
		# this boot) makes it exit 0 without powering the chip down, and
		# WiFi stays up after the fetch. That battery drain is the exact
		# thing this whole feature exists to avoid.
		echo 0 >"$WIFI_WANT" 2>/dev/null
		"$WIFI_DOWN" >/dev/null 2>&1
	fi
	rm -f "$FEEDLIST" "$ERRF" 2>/dev/null
	# A run that dies without writing a terminal status (SIGTERM, OOM kill,
	# `killall`) leaves the status file frozen on its last download line, so
	# the UI keeps advertising progress that is not happening. Say so.
	[ $LOCKED -eq 1 ] && [ $STATUS_FINAL -eq 0 ] && \
		set_status error 0/0 0/0 0 "interrupted"
	# rm the pid file FIRST: rmdir on a non-empty directory fails, which
	# would leak the lock for the rest of the boot.
	if [ $LOCKED -eq 1 ]; then
		rm -f "$LOCK/pid" 2>/dev/null
		rmdir "$LOCK" 2>/dev/null
	fi
}
WIFI_WAS_UP=1          # assume "leave it alone" until we know otherwise
trap cleanup EXIT
trap 'exit 1' INT TERM

# mkdir is the atomic primitive; the pid inside makes an abandoned lock
# recognisable. Without it, one OOM-killed run wedges every later Refresh and
# Download for the rest of the boot ($LOCK is on tmpfs, so only a reboot clears
# it) while the UI shows no reason at all. erosq-ui applies the SAME rule before
# it launches us (ui_podcast.c run_active()), so both sides agree on what
# "busy" means.
take_lock() {
	if mkdir "$LOCK" 2>/dev/null; then
		LOCKED=1
		echo $$ >"$LOCK/pid" 2>/dev/null
		return 0
	fi
	tl_pid=$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')
	if [ -n "$tl_pid" ] && [ -d "/proc/$tl_pid" ]; then
		return 1                      # a live run owns it
	fi
	# Stale (or written by a version with no pid file): take it over. If two
	# instances race here, exactly one wins the second mkdir and the other
	# gets a clean "already running" -- rmdir/mkdir stays atomic.
	echo "podfetch: taking over stale lock $LOCK (pid '${tl_pid:-none}' gone)" >&2
	rm -f "$LOCK/pid" 2>/dev/null
	rmdir "$LOCK" 2>/dev/null
	if mkdir "$LOCK" 2>/dev/null; then
		LOCKED=1
		echo $$ >"$LOCK/pid" 2>/dev/null
		return 0
	fi
	return 1
}

if ! take_lock; then
	# NOTE: do NOT touch $STATUS here. A live instance owns that file and is
	# actively updating it; overwriting it with "error: already running"
	# would corrupt the status the UI is polling for a perfectly healthy run.
	# The UI refuses the second press itself (run_active()), so this path is
	# the backstop for an ssh invocation, not the user-visible message.
	echo "podfetch: already running" >&2
	exit 1
fi

# --- wifi ---------------------------------------------------------------
wifi_is_up() {
	[ -e /sys/class/net/wlan0 ] || return 1
	wpa_cli -p /var/run/wpa_supplicant -i wlan0 ping 2>/dev/null | grep -q PONG
}

if [ "${PODFETCH_NO_WIFI:-0}" = 0 ]; then
	if wifi_is_up; then
		WIFI_WAS_UP=1
	else
		WIFI_WAS_UP=0
		set_status wifi 0/0 0/0 0 "connecting"
		# wifi_up.sh:34 EXITS 0 when /run/wifi-want is "0" -- its
		# last-intent guard. Only ui_net.c ever wrote that file, so once
		# the user had toggled WiFi off in Settings at any point this
		# boot, every Refresh/Download silently brought nothing up, burnt
		# the 20s IP wait and reported "no IP". Record OUR intent first,
		# exactly as the UI does. (A user toggling WiFi in Settings while
		# a fetch runs still wins or loses by whoever writes last; that
		# race is inherent to the last-intent scheme.)
		echo 1 >"$WIFI_WANT" 2>/dev/null
		if ! "$WIFI_UP" >/dev/null 2>&1; then
			set_status_final error 0/0 0/0 0 "no WiFi"
			echo "podfetch: wifi_up.sh failed" >&2
			exit 1
		fi
		# wifi_up.sh returns once wpa answers; wait for an actual address.
		i=0
		while [ $i -lt 20 ]; do
			ip addr show wlan0 2>/dev/null | grep -q 'inet ' && break
			sleep 1; i=$((i+1))
		done
		if [ $i -ge 20 ]; then
			set_status_final error 0/0 0/0 0 "no IP"
			echo "podfetch: no DHCP lease" >&2
			exit 1
		fi
	fi
fi

# --- feed list ----------------------------------------------------------
# "Name|URL" or a bare URL. Name is sanitised to [A-Za-z0-9 ._-] before it is
# used as a path segment. Blank lines and # comments ignored.
feed_lines() {
	[ -r "$FEEDS" ] || return 0
	# Trailing spaces are stripped as well as the CR: erosq-ui's
	# up_parse_feeds() trims trailing ' ' and '\r' from the line before it
	# splits, so without this a bare-URL line with a trailing space derived a
	# DIFFERENT directory name on each side. See pod_dir_name() in
	# src/pod_name.h for the rule both sides must implement.
	sed -e 's/\r$//' -e 's/ *$//' -e 's/^[[:space:]]*//' "$FEEDS" |
		grep -v '^#' | grep -v '^$'
}

feed_lines >"$FEEDLIST"
FEED_N=$(wc -l <"$FEEDLIST" | tr -d ' ')
[ "$FEED_N" = 0 ] && { set_status_final error 0/0 0/0 0 "no feeds"; \
	echo "podfetch: $FEEDS empty or missing" >&2; exit 1; }

# Free space, in KB, on the filesystem holding $1. Empty when df cannot tell us
# (no card, unreadable mount) -- treated as "proceed", since refusing every
# download because df is unavailable would be worse than trying and failing.
space_ok() {
	sok=$(df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}')
	floor="${2:-$MIN_FREE_KB}"
	[ -n "$sok" ] || return 0
	[ "$sok" -ge "$floor" ] && return 0
	echo "podfetch: only ${sok}KB free, need ${floor}KB" >&2
	return 1
}

# Delete the line matching $1 (a literal filename, not a pattern) from $2.
# grep -vxF treats it as a fixed whole-line string -- no regex metacharacter
# trouble (episode filenames legitimately contain '.'). grep -v exits 1 when
# EVERY line matched and got removed (empty result) -- that is success, not
# an error, so only rc>=2 (a real grep failure) is treated as a failure.
filter_out_line() {
	fol_tmp="$2.tmp.$$"
	grep -vxF -- "$1" "$2" >"$fol_tmp"
	fol_rc=$?
	if [ $fol_rc -le 1 ]; then
		mv "$fol_tmp" "$2"
	else
		echo "podfetch: failed to update $2" >&2
		rm -f "$fol_tmp"
	fi
}

FEED_I=0
rc=0
# Reason for the FINAL error status. "see log" is useless on a device with no
# log the user can read, so the specific reasons overwrite it.
FAILTEXT="see log"
while IFS= read -r line || [ -n "$line" ]; do
	FEED_I=$((FEED_I+1))
	case "$line" in
		*"|"*) name=${line%%|*}; url=${line#*|} ;;
		*)     url=$line; name=$(echo "$url" | sed -e 's|^[a-z]*://||' -e 's|/.*||') ;;
	esac
	# The feed-DIRECTORY-name rule. It MUST match pod_dir_name() in
	# erosq-ui/src/pod_name.h byte for byte -- the script creates the
	# directory, the UI reads it back, and a one-byte disagreement makes the
	# feed read "(not indexed)" forever while every wanted.txt the UI writes
	# lands somewhere this script never opens. The four steps, in this order:
	#   1. whitelist [A-Za-z0-9._-] plus space
	#   2. truncate to 63 bytes (UP_NAME_MAX-1 on the C side)
	#   3. strip TRAILING spaces -- after the truncation, not before
	#   4. reject empty, and reject all-dots ('..' survives the whitelist but
	#      resolves to the PARENT, which would drop index.tsv into /media/sd)
	# There is deliberately NO "feed$FEED_I" fallback: the UI drops a feed it
	# cannot name, so inventing a name here would recreate the divergence.
	# tests/test_pod_dirname_agree.sh diffs the two implementations.
	name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9 ._-' | cut -b1-63 | sed -e 's/ *$//')
	if [ -z "$name" ] || [ -z "$(printf '%s' "$name" | tr -d '.')" ]; then
		echo "podfetch: skipping feed with unusable name: $line" >&2
		continue
	fi
	case "$url" in https://*|http://*) ;; *) echo "podfetch: skip bad URL: $url" >&2; continue ;; esac
	dir="$ROOT/$name"
	mkdir -p "$dir" || { echo "podfetch: cannot create $dir" >&2; rc=1; continue; }

	if [ "$CMD" = refresh ]; then
		set_status refresh "$FEED_I/$FEED_N" 0/0 0 "$name"
		# Refresh writes to the card too, and a full card is the common
		# way podindex's writes fail. Check BEFORE the write, with
		# refresh's OWN (much smaller) floor -- see REFRESH_MIN_FREE_KB
		# above for why reusing the download floor here is wrong.
		if ! space_ok "$dir" "$REFRESH_MIN_FREE_KB"; then
			set_status error "$FEED_I/$FEED_N" 0/0 0 "card full"
			FAILTEXT="card full"
			rc=1
			continue
		fi
		# Atomic replace: a failed parse must leave the old index intact.
		if wget -q -T "$WGET_TIMEOUT" -O - -- "$url" | "$PODINDEX" >"$dir/index.tsv.new" 2>"$ERRF"; then
			if mv "$dir/index.tsv.new" "$dir/index.tsv"; then
				# vfat has no journal: without this the rename
				# can be durable while the new file's DATA is
				# not, leaving a zero-filled index.tsv after a
				# card pull or a power loss.
				sync
				echo "podfetch: $name indexed $(wc -l <"$dir/index.tsv" | tr -d ' ') episodes"
			else
				rm -f "$dir/index.tsv.new"
				echo "podfetch: $name index rename FAILED" >&2
				rc=1
			fi
			# Surface podindex's skip/drop counts on the SUCCESS
			# path too. They used to go into index.err, which was
			# cat'd only on failure, so from the user's seat
			# episodes with an unusable enclosure URL were still
			# dropped in silence -- the exact thing reporting them
			# was supposed to fix.
			if [ -s "$ERRF" ]; then
				cat "$ERRF"
				sk=$(sed -n -e 's/^podindex: \([0-9]*\) items skipped.*/\1/p' \
				            -e 's/^podindex: \([0-9]*\) episodes dropped.*/\1/p' \
				     "$ERRF" | awk '{n+=$0} END {print n+0}')
				SKIP_TOTAL=$((SKIP_TOTAL+sk))
			fi
		else
			rm -f "$dir/index.tsv.new"
			echo "podfetch: $name refresh FAILED: $(cat "$ERRF" 2>/dev/null)" >&2
			rc=1
		fi
		: >"$ERRF" 2>/dev/null
		continue
	fi

	# --- download ---
	# Orphaned partials from an interrupted run. The lock guarantees nothing
	# else owns them, and the glob can only match OUR ".<name>.part" naming
	# (neither "." nor ".." ends in ".part"). With no match ash leaves the
	# pattern literal and `rm -f` on a nonexistent path is silent.
	rm -f "$dir"/.*.part 2>/dev/null
	[ -s "$dir/wanted.txt" ] || continue
	# Count the way the loop iterates, not with `wc -l`: the loop also
	# processes a final line with no trailing newline and skips empty lines,
	# so wc -l could report "3/2" or "2/3" in the status row.
	EP_N=$(awk '$0 != "" {n++} END {print n+0}' "$dir/wanted.txt")
	EP_I=0
	while IFS= read -r want || [ -n "$want" ]; do
		[ -n "$want" ] || continue
		EP_I=$((EP_I+1))
		# Re-validate the name read back off a removable card: no path
		# separators, no leading dot, and every byte in [A-Za-z0-9._-].
		case "$want" in
			*/*|.*|"") echo "podfetch: refusing name '$want'" >&2; continue ;;
		esac
		if [ -n "$(printf '%s' "$want" | tr -d 'A-Za-z0-9._-')" ]; then
			echo "podfetch: refusing name '$want'" >&2; continue
		fi
		[ -f "$dir/$want" ] && { filter_out_line "$want" "$dir/wanted.txt"; continue; }

		# Resolve the URL from OUR index -- the UI never supplies one.
		url_ep=$(awk -F'\t' -v f="$want" '$1==f {print $4; exit}' "$dir/index.tsv" 2>/dev/null)
		[ -n "$url_ep" ] || { echo "podfetch: '$want' not in index; refresh first" >&2; rc=1; continue; }
		# The URL comes from the feed (untrusted): only http(s). This also stops
		# a leading "-" from reaching wget as an option. Such an entry can never
		# download from this index, so drop it from wanted.txt.
		case "$url_ep" in
			http://*|https://*) ;;
			*) echo "podfetch: skip bad episode URL for '$want'" >&2
			   filter_out_line "$want" "$dir/wanted.txt"; continue ;;
		esac

		if ! space_ok "$dir"; then
			set_status error "$FEED_I/$FEED_N" "$EP_I/$EP_N" 0 "card full"
			FAILTEXT="card full"
			rc=1
			break
		fi

		set_status download "$FEED_I/$FEED_N" "$EP_I/$EP_N" 0 "$want"
		# The rename must be checked too: a wget that returns 0 but whose
		# target rename fails (missing source, EISDIR, SD-card I/O error)
		# must NOT be treated as success -- same failure branch as a
		# failed download, so the entry survives for a retry.
		if wget -q -T "$WGET_TIMEOUT" -O "$dir/.$want.part" -- "$url_ep" && mv "$dir/.$want.part" "$dir/$want"; then
			filter_out_line "$want" "$dir/wanted.txt"
			# vfat, no journal, removable card, and this device has
			# SD failure history: without this the episode and the
			# rewritten wanted.txt can both exist at full length
			# with unwritten data after a card pull -- the UI marks
			# the file on-disk and MPD plays garbage, and the queue
			# comes back empty. One sync per episode is noise next
			# to a 40-70 MB download.
			sync
			echo "podfetch: got $want"
		else
			# Leave the wanted entry so a re-run retries with a fresh signed URL.
			rm -f "$dir/.$want.part"
			echo "podfetch: FAILED $want" >&2
			rc=1
		fi
	done <"$dir/wanted.txt"
done <"$FEEDLIST"

if [ $rc -eq 0 ]; then
	# Put the skip count where the user can actually see it: stdout is
	# /dev/null when erosq-ui launches us, so the status line is the only
	# channel that reaches the screen.
	if [ "$SKIP_TOTAL" -gt 0 ]; then
		set_status_final done "$FEED_N/$FEED_N" 0/0 100 "$SKIP_TOTAL skipped"
	else
		set_status_final done "$FEED_N/$FEED_N" 0/0 100 "finished"
	fi
else
	set_status_final error "$FEED_N/$FEED_N" 0/0 0 "$FAILTEXT"
fi
exit $rc
