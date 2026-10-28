#!/usr/bin/env bash
# Anonymity scan, run on every push and PR and as a local pre-push hook.
#   ci/anon-scan.sh <base> [<head>]   the lines and files head adds since its
#                                      merge-base with base, plus base..head's
#                                      commit messages and identities
#   ci/anon-scan.sh --root <head>     everything in head and all its commits
#   ci/anon-scan.sh --tree [<head>]   everything in head (default HEAD)
# Public tier: local paths, Claude trailers and session links, private IPv4,
# MAC addresses, private keys, e-mail addresses, new images, new binaries
# over 64 KB, commit identities other than erosqcfw or a GitHub noreply.
# A hit is ignored when its line contains a string listed in .anon-allow
# (one per line; "file:<path>" allows that new image or binary).
# Private tier: with ANON_PATTERNS set (one extended regex per line) it also
# greps for those and prints only where (file:line, commit), never the match.
set -euo pipefail
export LC_ALL=C
cd "$(git rev-parse --show-toplevel)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
E=$(git hash-object -t tree /dev/null)
case ${1:?usage: $0 <base> [<head>] | --root <head> | --tree [<head>]} in
--tree) head=${2:-HEAD}; from=$E; : > "$T/commits" ;;
--root) head=${2:?--root needs a rev}; from=$E; git rev-list "$head" > "$T/commits" ;;
*) head=${2:-HEAD}; from=$(git merge-base "$1" "$head"); git rev-list "$1..$head" > "$T/commits" ;;
esac
git show "$head:.anon-allow" > "$T/allowfile" 2>/dev/null || : > "$T/allowfile"
sed '/^#/d; /^$/d; /^file:/d' "$T/allowfile" > "$T/allow"
echo erosqcfw@gmail.com >> "$T/allow"
# added lines as path:line:text (text files only, as git diff shows them)
git -c core.quotePath=false diff -U0 --no-color --no-renames "$from" "$head" | awk '
	m > 0 && /^\+/ { print f ":" n ":" substr($0, 2); n++; m--; next }
	/^\+\+\+ / { f = substr($0, 7); next }
	/^@@/ { split($3, a, ","); n = substr(a[1], 2); m = (a[2] == "" ? 1 : a[2]) }' > "$T/lines"
git -c core.quotePath=false diff -z --name-only --diff-filter=A --no-renames "$from" "$head" > "$T/new"
while read -r c; do
	git log -1 --format=%B "$c" | awk -v c="$c" '{ print "commit " c ":" NR ":" $0 }'
done < "$T/commits" >> "$T/lines"

bad=0
hit() { echo "::error::anon-scan: $*"; bad=1; }
check() { # name ERE [grep -i]: the match must lie in the text, not the path:line prefix
	grep -a -E ${3:+"$3"} -e "^[^:]*:[0-9]+:.*($2)" "$T/lines" | grep -v -F -f "$T/allow" |
		while IFS= read -r l; do echo "::error::anon-scan: $1: $l"; done > "$T/hits" || :
	[ -s "$T/hits" ] && { cat "$T/hits"; bad=1; }
	return 0
}
check "local path" '/workspace/|/home/[a-z]|/Users/[A-Za-z]|/tmp/claude-|[A-Z]:[\]Users'
check "Claude trailer/link" 'Co-Authored-By:.*(Claude|anthropic)|Claude-Session|claude\.ai/(code|chat|share)|Generated with \[Claude' -i
check "private IPv4" '(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)'
check "MAC address" '(^|[^0-9a-f:])([0-9a-f]{2}:){5}[0-9a-f]{2}([^0-9a-f:]|$)' -i
check "private key" 'BEGIN [A-Z ]*PRIVATE KEY'
check "e-mail address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'

while IFS= read -r -d '' f; do
	grep -q -x -F "file:$f" "$T/allowfile" && continue
	[ "$(git cat-file -t "$head:$f")" = commit ] && continue   # submodule
	case "$f:$(git cat-file blob "$head:$f" | file -b --mime-type -)" in
	*:image/* | *.[Pp][Nn][Gg]:* | *.[Jj][Pp][Gg]:* | *.[Jj][Pp][Ee][Gg]:* | *.[Gg][Ii][Ff]:* | \
	*.[Bb][Mm][Pp]:* | *.[Ww][Ee][Bb][Pp]:* | *.[Hh][Ee][Ii][Cc]:* | *.[Tt][Ii][Ff]*:*)
		hit "new image: $f"; continue ;;
	esac
	if [ "$(git cat-file -s "$head:$f")" -gt 65536 ] && ! git cat-file blob "$head:$f" | grep -q -I ''; then
		hit "new binary over 64 KB: $f"
	fi
done < "$T/new"

while read -r c; do
	for e in "$(git log -1 --format=%ae "$c")" "$(git log -1 --format=%ce "$c")"; do
		case $e in *@users.noreply.github.com) continue ;; esac
		grep -q -x -F "$e" "$T/allow" || hit "commit $c: identity $e"
	done
done < "$T/commits"

if [ -n "${ANON_PATTERNS:-}" ]; then
	printf '%s\n' "$ANON_PATTERNS" | sed '/^$/d' > "$T/pats"
	while read -r c; do git log -1 --format='commit %H:0:%an %ae %cn %ce' "$c"; done < "$T/commits" >> "$T/lines"
	n=$(grep -a -c -i -E -f "$T/pats" "$T/lines" || :)
	if [ "$n" -gt 0 ]; then
		grep -a -i -E -f "$T/pats" "$T/lines" | cut -d: -f1,2 | sed 's/^/::error::anon-scan: private pattern at /'
		hit "$n private-pattern hit(s)"
	fi
fi
[ "$bad" = 0 ] && echo "anon-scan: clean"
exit "$bad"
