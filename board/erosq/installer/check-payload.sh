#!/bin/sh
# Refuse to ship anything private inside update.upt. Exit 1 on any finding.
#   check-payload.sh <file|dir>...
# Every input is unpacked as deep as it goes before it is scanned: a secret
# inside a compressed initramfs is as public as one in plain text.
#   .upt (ISO9660)  members, via PYTHON (default python3) with pycdlib
#   uImage          payload (header stripped), and any bytes after it
#   FIT / ITB       each image (dumpimage)
#   squashfs        extracted tree
#   UBI image       volumes                    } unpack-stream.py (PYTHON),
#   gzip, xz, lzma, zstd, bzip2, lz4, lzo      } at the start of a file or
#   cpio (newc, crc, odc)                      } anywhere inside it
# The raw bytes of every layer are scanned too. It fails closed: a format it
# recognises but cannot unpack, an extractor or scan that fails, a container
# still found at depth MAXDEPTH, or more than MAXSTREAMS streams in one file
# is a FAIL, the same as a finding.
# Looks for:
#  - private keys (a PEM/OpenSSH "PRIVATE KEY" header with a key body);
#  - a non-empty authorized_keys or seed-authorized_keys (public images carry
#    no root SSH key);
#  - Wi-Fi credentials (psk= / wpa_passphrase / sae_password lines);
#  - ANON_PATTERNS when set: newline-separated extended regexes, matched
#    case-insensitively against paths and contents, as ci/anon-scan.sh does.
#    It is the private tier and lives outside the repository; release builds
#    must set it.
# shellcheck disable=SC3043  # local: dash, bash and busybox ash all have it
set -u
export LC_ALL=C
PY=${PYTHON:-python3}
US=$(cd "$(dirname "$0")" && pwd)/unpack-stream.py
MAXDEPTH=6
MAXSTREAMS=256
# a superset of the magics unpack-stream.py looks for: a file with none of
# them skips the Python start-up
QUICK='\x1f\x8b\x08|\xfd7zXZ\x00|\x5d\x00|\x28\xb5\x2f\xfd|BZh[1-9]|\x02\x21\x4c\x18|\x89LZO\x00|07070[127]|UBI#'
hit() { echo "check-payload: FAIL: $*" >&2; echo x >> "$T/failed"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM

magic() { od -An -tx1 -N"$2" -j"${3:-0}" "$1" 2>/dev/null | tr -d ' \n'; }

in_range() { # in_range <offset> <file of "start end" lines>
	local a b
	while read -r a b; do
		[ "$1" -ge "$a" ] && [ "$1" -lt "$b" ] && return 0
	done < "$2"
	return 1
}

kind() { # the container <file> is by its header, or nothing
	case "$(magic "$1" 4)" in
	68737173) echo squashfs ;;
	27051956) echo uImage ;;
	d00dfeed) echo FIT ;;
	*) [ "$(magic "$1" 5 32769)" != 4344303031 ] || echo ISO ;;
	esac
}

each() { # each <dir> <depth>: unpack every file of an extracted tree
	chmod -R u+rwX "$1" || hit "$1: chmod failed"
	find "$1" -type f -size +0 > "$1.list" || { hit "$1: find failed"; return; }
	while read -r g; do unpack "$g" "$2"; done < "$1.list"
}

unpack() { # unpack <file> <depth>: extracts into <file>.d, recursively
	local f="$1" o="$1.d" n=$(($2 + 1)) c k fmt off end
	[ -s "$f" ] || return 0
	c=$(kind "$f")
	if [ "$c" = FIT ]; then
		dumpimage -l "$f" > "$f.l" 2>&1 || { hit "$f: dumpimage -l failed: $(head -2 "$f.l" | tr '\n' ' ')"; return; }
		# a device tree with no /images node is a plain DTB, not a FIT
		! grep -q "^Can't find images parent node '/images'" "$f.l" || c=
	fi
	if [ -z "$c" ]; then
		grep -qaP "$QUICK" "$f"
		case $? in 0) ;; 1) return 0 ;; *) hit "$f: grep failed"; return ;; esac
		"$PY" "$US" scan "$f" > "$f.offs" < /dev/null || { hit "$f: cannot scan it for streams"; return; }
		[ -s "$f.offs" ] || return 0
		c="$(wc -l < "$f.offs") stream(s)"
	fi
	[ "$2" -lt "$MAXDEPTH" ] || { hit "$f: still a container ($c) at depth $MAXDEPTH"; return; }
	mkdir -p "$o"
	case $c in
	squashfs)
		unsquashfs -no-xattrs -q -d "$o/root" "$f" > /dev/null 2>&1 < /dev/null || { hit "$f: unsquashfs failed"; return; }
		each "$o/root" "$n" ;;
	uImage)
		dumpimage -l "$f" > "$f.l" 2>&1 || { hit "$f: dumpimage -l failed: $(head -2 "$f.l" | tr '\n' ' ')"; return; }
		k=$(sed -n 's/^Data Size: *\([0-9][0-9]*\) Bytes.*/\1/p' "$f.l")
		[ -n "$k" ] || { hit "$f: dumpimage -l lists no image"; return; }
		[ $((k + 64)) -le "$(stat -c %s "$f")" ] || { hit "$f: the payload ends early (truncated)"; return; }
		tail -c +65 "$f" | head -c "$k" > "$o/payload" || { hit "$f: cannot cut the payload out"; return; }
		unpack "$o/payload" "$n"
		# and whatever follows the payload: nothing reads it, but it ships
		tail -c +$((k + 65)) "$f" > "$o/trailer" || { hit "$f: cannot cut the trailer out"; return; }
		unpack "$o/trailer" "$n" ;;
	FIT)
		k=$(grep -c '^ *Image [0-9]' "$f.l")
		[ "$k" -gt 0 ] || { hit "$f: dumpimage -l lists no images"; return; }
		while [ "$k" -gt 0 ]; do
			k=$((k - 1))
			if dumpimage -T flat_dt -p "$k" -o "$o/image$k" "$f" > /dev/null 2>&1 < /dev/null; then
				unpack "$o/image$k" "$n"
			else
				hit "$f: dumpimage cannot extract image $k"
			fi
		done ;;
	ISO)
		"$PY" - "$f" "$o/iso" <<'EOF' || { hit "$f: cannot read the ISO (pycdlib?)"; return; }
import os, sys, pycdlib
iso = pycdlib.PyCdlib(); iso.open(sys.argv[1]); os.mkdir(sys.argv[2])
for c in iso.list_children(iso_path="/"):
    if c.is_file():
        n = c.file_identifier().decode()
        iso.get_file_from_iso(sys.argv[2] + "/" + n.split(";")[0], iso_path="/" + n)
EOF
		each "$o/iso" "$n" ;;
	*)
		[ "$(wc -l < "$f.offs")" -le "$MAXSTREAMS" ] || { hit "$f: $c, over the $MAXSTREAMS it unpacks"; return; }
		k=0 end=0 rng=
		while read -r fmt off; do
			# inside a stream already unpacked: a part of it, not a stream.
			# Inside a cpio archive, only inside the data of a regular member
			# written out (and so unpacked and scanned); a magic in a header,
			# a name or a link target is unpacked on its own.
			if [ "$off" -lt "$end" ]; then
				[ -z "$rng" ] && continue
				in_range "$off" "$rng" && continue
			fi
			k=$((k + 1))
			if ! "$PY" "$US" unpack "$fmt" "$f" "$off" "$o/s$k" > "$o/s$k.out" 2> "$o/s$k.err" < /dev/null; then
				hit "$f: $fmt at offset $off cannot be unpacked: $(tail -1 "$o/s$k.err")"
				[ "$off" -lt "$end" ] || end=0
			else
				if [ "$off" -ge "$end" ]; then
					end=$(head -1 "$o/s$k.out") rng=
					[ "$fmt" != cpio ] || { tail -n +2 "$o/s$k.out" > "$o/s$k.rng"; rng=$o/s$k.rng; }
				fi
				if [ -d "$o/s$k" ]; then each "$o/s$k" "$n"; else unpack "$o/s$k" "$n"; fi
			fi
		done < "$f.offs" ;;
	esac
}

scan_tree() { # scan_tree <dir> <label>; grep exits 2 on an error, 1 on no match
	local d="$1" l="$2"
	find "$d" \( -name authorized_keys -o -name seed-authorized_keys \) -type f -size +0 > "$T/keys" ||
		hit "$l: find failed"
	[ -s "$T/keys" ] && hit "$l: non-empty SSH key list: $(sed "s|^$d||" "$T/keys" | tr '\n' ' ')"
	# a header followed by a base64 body: crypto libraries carry the bare
	# header string, a key does not end there
	grep -rlazP -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----\r?\n[A-Za-z0-9+/=]{40}' "$d" > "$T/pk"
	[ $? -lt 2 ] || hit "$l: grep (private keys) failed"
	[ -s "$T/pk" ] && hit "$l: private key in: $(sed "s|^$d||" "$T/pk" | tr '\n' ' ')"
	grep -rlaE '^[[:space:]]*(psk|wpa_passphrase|sae_password)=' "$d" > "$T/psk"
	[ $? -lt 2 ] || hit "$l: grep (Wi-Fi credentials) failed"
	[ -s "$T/psk" ] && hit "$l: Wi-Fi credential in: $(sed "s|^$d||" "$T/psk" | tr '\n' ' ')"
	if [ -n "${ANON_PATTERNS:-}" ]; then
		printf '%s\n' "$ANON_PATTERNS" | grep -v '^$' > "$T/pat"
		find "$d" > "$T/paths" || hit "$l: find failed"
		sed "s|^$d||" "$T/paths" | grep -iE -f "$T/pat" > "$T/names"
		[ $? -lt 2 ] || hit "$l: grep (ANON_PATTERNS paths) failed"
		[ -s "$T/names" ] && hit "$l: ANON_PATTERNS match in path(s): $(head -5 "$T/names" | tr '\n' ' ')"
		grep -rlaiE -f "$T/pat" "$d" > "$T/anon"
		[ $? -lt 2 ] || hit "$l: grep (ANON_PATTERNS) failed"
		[ -s "$T/anon" ] && hit "$l: ANON_PATTERNS match in: $(sed "s|^$d||" "$T/anon" | head -5 | tr '\n' ' ')"
	fi
	return 0
}

[ $# -gt 0 ] || { echo "usage: $0 <file|dir>..." >&2; exit 2; }
i=0
for p in "$@"; do
	i=$((i + 1)); w=$T/in$i
	mkdir "$w"
	if [ -d "$p" ]; then
		# a copy: grep -r and find do not follow links, and following them
		# inside an unpacked rootfs would scan the host
		cp -a "$p/." "$w/" || hit "$p: cannot copy it"
		each "$w" 0
	elif [ -f "$p" ]; then
		if cp "$p" "$w/"; then unpack "$w/$(basename "$p")" 0; else hit "$p: cannot copy it"; fi
	else
		hit "$p: no such file"; continue
	fi
	scan_tree "$w" "$p"
	rm -rf "$w"
done
[ -s "$T/failed" ] && exit 1
echo "check-payload: OK: $*"
