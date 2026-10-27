#!/bin/sh
# Host check: podfetch.sh must only hand http(s) episode URLs to wget.
# Episode URLs come from index.tsv, i.e. from an untrusted RSS feed. One that
# starts with "-" would become a wget option (-O elsewhere, -e ...), and other
# schemes (file://, ftp://) must not be fetched at all. A normal https
# enclosure in the same feed must still download.
# Hermetic: stub wget/podindex, PODFETCH_NO_WIFI=1, no network.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${PODFETCH_SCRIPT:-$HERE/package/erosq-board/files/usr/bin/podfetch.sh}"
T=$(mktemp -d /tmp/podfetch-urls.XXXXXX)
trap 'rm -rf "$T"' EXIT
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN"
fails=0
fail() { echo "FAIL $*"; fails=$((fails+1)); }

cat >"$FAKEBIN/podindex" <<'EOF'
#!/bin/sh
cat >/dev/null
cat "$FAKE_PODINDEX_FIXTURE"
EOF
# Stub wget: logs its full argv (one call per line), then behaves like the
# real one for `-O FILE URL` / `-O - URL`.
cat >"$FAKEBIN/wget" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_WGET_ARGV"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-O" ] && out="$a"; prev="$a"; done
if [ "$out" = "-" ]; then echo "<rss/>"; else echo "FAKE-AUDIO" >"$out"; fi
exit 0
EOF
chmod +x "$FAKEBIN/podindex" "$FAKEBIN/wget"

echo "Test Show|https://example.invalid/feed.xml" >"$T/feeds.txt"
printf '%s\t%s\t%s\t%s\n' \
	good.mp3 2026-08-01 Good https://example.invalid/good.mp3 \
	opt.mp3  2026-08-02 Opt  -O/tmp/pwn \
	file.mp3 2026-08-03 File file:///etc/passwd \
	ftp.mp3  2026-08-04 Ftp  ftp://x >"$T/fixture.tsv"
DIR="$T/pod/Test Show"

run() {
	env PATH="$FAKEBIN:$PATH" \
	    PODCAST_ROOT="$T/pod" PODCAST_FEEDS="$T/feeds.txt" PODINDEX="$FAKEBIN/podindex" \
	    FAKE_PODINDEX_FIXTURE="$T/fixture.tsv" FAKE_WGET_ARGV="$T/argv" \
	    PODFETCH_MIN_FREE_KB=1 PODFETCH_REFRESH_MIN_FREE_KB=1 \
	    PODFETCH_STATUS="$T/status" PODFETCH_LOCK="$T/lock" PODFETCH_NO_WIFI=1 \
	    sh "$SCRIPT" "$@"
}

run refresh >"$T/refresh.out" 2>&1 || fail "refresh rc=$? ($(head -c 300 "$T/refresh.out"))"
[ -f "$DIR/index.tsv" ] || { fail "no index.tsv after refresh"; echo "FAILED: $fails"; exit 1; }
printf 'opt.mp3\nfile.mp3\nftp.mp3\ngood.mp3\n' >"$DIR/wanted.txt"
: >"$T/argv"
run download >"$T/dl.out" 2>&1

[ -s "$DIR/good.mp3" ] && echo "PASS https enclosure downloaded" || fail "good.mp3 not downloaded ($(head -c 300 "$T/dl.out"))"
for n in opt file ftp; do
	[ -e "$DIR/$n.mp3" ] && fail "$n.mp3 was downloaded" || echo "PASS $n.mp3 not downloaded"
done
for u in -O/tmp/pwn file:///etc/passwd ftp://x; do
	if grep -qF -- "$u" "$T/argv"; then fail "wget was called with $u"; else echo "PASS wget never saw $u"; fi
done
[ "$(grep -c 'skip bad episode URL' "$T/dl.out")" = 3 ] \
	&& echo "PASS 3 skips logged" || fail "expected 3 'skip bad episode URL' lines ($(head -c 300 "$T/dl.out"))"
# Every download call must end its options with -- before the URL.
grep -v -- ' -O - ' "$T/argv" | grep -qv -- ' -- https://' && fail "a download wget lacks -- before the URL: $(cat "$T/argv")" \
	|| echo "PASS download wget passes -- before the URL"
grep -qvF 'good.mp3' "$DIR/wanted.txt" 2>/dev/null && fail "bad entries left in wanted.txt: $(cat "$DIR/wanted.txt")" \
	|| echo "PASS bad entries dropped from wanted.txt"

[ $fails -eq 0 ] && echo "OK: 0 failure(s)" || { echo "FAILED: $fails"; exit 1; }
