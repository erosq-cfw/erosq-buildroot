#!/bin/sh
# Refuse to ship anything private inside update.upt. Exit 1 on any finding.
#   check-payload.sh <file|dir>...
# A squashfs is unpacked and its tree scanned; any other file is scanned as is.
# Looks for:
#  - private keys (PEM/OpenSSH "PRIVATE KEY" blocks);
#  - a non-empty authorized_keys or seed-authorized_keys (public images carry
#    no root SSH key);
#  - Wi-Fi credentials (psk= / wpa_passphrase / sae_password lines);
#  - ANON_PATTERNS when set: newline-separated extended regexes, matched
#    case-insensitively against paths and contents, as ci/anon-scan.sh does.
#    It is the private tier and lives outside the repository; release builds
#    must set it.
set -u
fail=0
hit() { echo "check-payload: FAIL: $*" >&2; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM

scan_tree() { # scan_tree <dir> <label>
	d=$1 l=$2
	find "$d" \( -name authorized_keys -o -name seed-authorized_keys \) -type f -size +0 |
		while read -r f; do echo "$f"; done > "$T/keys"
	[ -s "$T/keys" ] && hit "$l: non-empty SSH key list: $(sed "s|^$d||" "$T/keys" | tr '\n' ' ')"
	# a header followed by a base64 body: crypto libraries carry the bare
	# header string, a key does not end there
	grep -rlazP -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----\r?\n[A-Za-z0-9+/=]{40}' "$d" > "$T/pk"
	[ -s "$T/pk" ] && hit "$l: private key in: $(sed "s|^$d||" "$T/pk" | tr '\n' ' ')"
	grep -rlaE '^[[:space:]]*(psk|wpa_passphrase|sae_password)=' "$d" > "$T/psk"
	[ -s "$T/psk" ] && hit "$l: Wi-Fi credential in: $(sed "s|^$d||" "$T/psk" | tr '\n' ' ')"
	if [ -n "${ANON_PATTERNS:-}" ]; then
		printf '%s\n' "$ANON_PATTERNS" | grep -v '^$' > "$T/pat"
		find "$d" | sed "s|^$d||" | grep -iE -f "$T/pat" > "$T/names"
		[ -s "$T/names" ] && hit "$l: ANON_PATTERNS match in path(s): $(head -5 "$T/names" | tr '\n' ' ')"
		grep -rlaiE -f "$T/pat" "$d" > "$T/anon"
		[ -s "$T/anon" ] && hit "$l: ANON_PATTERNS match in: $(sed "s|^$d||" "$T/anon" | head -5 | tr '\n' ' ')"
	fi
}

[ $# -gt 0 ] || { echo "usage: $0 <file|dir>..." >&2; exit 2; }
n=0
for p in "$@"; do
	n=$((n + 1))
	if [ -d "$p" ]; then
		scan_tree "$p" "$p"
	elif [ "$(head -c 4 "$p")" = hsqs ]; then
		unsquashfs -no-xattrs -q -d "$T/sq$n" "$p" >/dev/null || { hit "$p: unsquashfs failed"; continue; }
		scan_tree "$T/sq$n" "$p"
		rm -rf "$T/sq$n"
	elif [ -f "$p" ]; then
		# a copy, not a link: grep -r and find do not follow links, and
		# following them inside an unpacked rootfs would scan the host
		mkdir "$T/f$n" && cp "$p" "$T/f$n/"
		scan_tree "$T/f$n" "$(dirname "$p")/"
		rm -rf "$T/f$n"
	else
		hit "$p: no such file"
	fi
done
[ "$fail" -eq 0 ] && echo "check-payload: OK: $*"
exit "$fail"
