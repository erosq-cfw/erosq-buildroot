#!/bin/sh
# Refuse to ship anything private inside update.upt. Exit 1 on any finding.
#   check-payload.sh <file|dir>...
# Every input is unpacked as deep as it goes before it is scanned: a secret
# inside a compressed initramfs is as public as one in plain text.
#   .upt (ISO9660)  members, via PYTHON (default python3) with pycdlib
#   uImage          payload (header stripped)
#   FIT / ITB       each image (dumpimage)
#   gzip, xz, zstd  decompressed: whole files, and streams embedded in a blob
#                   of 256 KiB or more (an initramfs linked into a kernel)
#   cpio, squashfs  extracted trees
# The raw bytes of every layer are scanned too. A UBI image is scanned raw
# only: ci/installer.sh makes it from the ITB and rootfs it has scanned.
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
MAXDEPTH=6
hit() { echo "check-payload: FAIL: $*" >&2; echo x >> "$T/failed"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM

magic() { od -An -tx1 -N"$2" -j"${3:-0}" "$1" 2>/dev/null | tr -d ' \n'; }

unpack() { # unpack <file> <depth>: extracts into <file>.d, recursively
	local f="$1" o="$1.d" n=$(($2 + 1)) g k off
	[ "$2" -lt "$MAXDEPTH" ] && [ -s "$f" ] || return 0
	case "$(magic "$f" 4)" in
	68737173) # squashfs
		unsquashfs -no-xattrs -q -d "$o" "$f" >/dev/null 2>&1 || { hit "$f: unsquashfs failed"; return; }
		find "$o" -type f -size +0 > "$o.list"
		while read -r g; do unpack "$g" "$n"; done < "$o.list"
		return ;;
	27051956) # uImage
		mkdir -p "$o" && tail -c +65 "$f" > "$o/payload" && unpack "$o/payload" "$n"
		return ;;
	d00dfeed) # FIT
		k=$(dumpimage -l "$f" 2>/dev/null | grep -c '^ *Image [0-9]')
		mkdir -p "$o"
		while [ "$k" -gt 0 ]; do
			k=$((k - 1))
			dumpimage -T flat_dt -p "$k" -o "$o/image$k" "$f" >/dev/null 2>&1 && unpack "$o/image$k" "$n"
		done
		return ;;
	30373037) # cpio newc/crc
		mkdir -p "$o" && (cd "$o" && cpio -id --no-absolute-filenames --quiet 2>/dev/null) < "$f"
		find "$o" -type f -size +0 > "$o.list"
		while read -r g; do unpack "$g" "$n"; done < "$o.list"
		return ;;
	esac
	if [ "$(magic "$f" 5 32769)" = 4344303031 ]; then # ISO9660 (.upt)
		mkdir -p "$o"
		"$PY" - "$f" "$o" <<'EOF' || { hit "$f: cannot read the ISO (pycdlib?)"; return; }
import sys, pycdlib
iso = pycdlib.PyCdlib(); iso.open(sys.argv[1])
for c in iso.list_children(iso_path="/"):
    if c.is_file():
        n = c.file_identifier().decode()
        iso.get_file_from_iso(sys.argv[2] + "/" + n.split(";")[0], iso_path="/" + n)
EOF
		for g in "$o"/*; do unpack "$g" "$n"; done
		return
	fi
	case "$(magic "$f" 6)" in
	1f8b08*) mkdir -p "$o"; gzip -dc < "$f" > "$o/data" 2>/dev/null; unpack "$o/data" "$n"; return ;;
	fd377a585a00) mkdir -p "$o"; xz -dc < "$f" > "$o/data" 2>/dev/null; unpack "$o/data" "$n"; return ;;
	28b52ffd*) mkdir -p "$o"; zstd -dcq < "$f" > "$o/data" 2>/dev/null; unpack "$o/data" "$n"; return ;;
	esac
	# a blob, such as a kernel: try each compressed stream that starts inside it
	[ "$(stat -c %s "$f")" -ge 262144 ] || return 0
	grep -obUaP '\x1f\x8b\x08|\xfd7zXZ\x00|\x28\xb5\x2f\xfd' "$f" 2>/dev/null | head -64 | cut -d: -f1 > "$f.offs"
	k=0
	while read -r off; do
		k=$((k + 1)); mkdir -p "$o"
		tail -c +$((off + 1)) "$f" > "$o/s$k"
		unpack "$o/s$k" "$n"
	done < "$f.offs"
	rm -f "$f.offs"
}

scan_tree() { # scan_tree <dir> <label>
	local d="$1" l="$2"
	find "$d" \( -name authorized_keys -o -name seed-authorized_keys \) -type f -size +0 > "$T/keys"
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
		cp -a "$p/." "$w/"
		find "$w" -type f -size +0 > "$T/list$i"
		while read -r g; do unpack "$g" 0; done < "$T/list$i"
	elif [ -f "$p" ]; then
		cp "$p" "$w/" && unpack "$w/$(basename "$p")" 0
	else
		hit "$p: no such file"; continue
	fi
	scan_tree "$w" "$p"
	rm -rf "$w"
done
[ -s "$T/failed" ] && exit 1
echo "check-payload: OK: $*"
