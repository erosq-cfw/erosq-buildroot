#!/bin/sh
# Host self-check for the update.upt tools in board/erosq/installer/:
# check-uimage.sh refuses an installer over the stock bootloader's 4 MiB read
# (one byte over included) or with the wrong header, build-upt.py writes the
# stock .upt shape and refuses wrong payloads, and check-payload.sh finds keys,
# Wi-Fi credentials and private names inside a squashfs.
# Needs mkimage/dumpimage, dtc, mksquashfs/unsquashfs, cpio, xz, zstd, lz4, bzip2, openssl and PYTHON
# (default python3) with pycdlib.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
I="$HERE/board/erosq/installer"
PY=${PYTHON:-python3}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
"$PY" -c 'import pycdlib' 2>/dev/null || fail "$PY has no pycdlib (pip install pycdlib)"

# --- check-uimage.sh ---------------------------------------------------------
mkuimage() { # mkuimage <out> <total bytes> [arch]: a uImage of exactly that size
	head -c $(($2 - 64)) /dev/urandom > "$T/data"
	mkimage -A "${3:-mips}" -O linux -T kernel -C gzip -a 0x80100000 -e 0x80100000 \
		-n installer -d "$T/data" "$1" >/dev/null || fail "mkimage"
	[ "$(stat -c %s "$1")" -eq "$2" ] || fail "mkuimage made $(stat -c %s "$1") bytes, not $2"
}
mkuimage "$T/max.uImage" 4194304
mkuimage "$T/over.uImage" 4194305
mkuimage "$T/arm.uImage" 1048576 arm
sh "$I/check-uimage.sh" "$T/max.uImage" >/dev/null 2>&1 || fail "check-uimage refused exactly 4194304 bytes"
sh "$I/check-uimage.sh" "$T/over.uImage" >/dev/null 2>&1 && fail "check-uimage accepted 4194305 bytes"
sh "$I/check-uimage.sh" "$T/arm.uImage" >/dev/null 2>&1 && fail "check-uimage accepted an ARM image"
head -c 100 /dev/zero > "$T/raw"
sh "$I/check-uimage.sh" "$T/raw" >/dev/null 2>&1 && fail "check-uimage accepted a file with no header"
head -c 6000000 /dev/zero > "$T/vm.bin"; head -c 700000 /dev/zero > "$T/vm.gz"
sh "$I/check-uimage.sh" "$T/max.uImage" "$T/vm.bin" "$T/vm.gz" >/dev/null 2>&1 &&
	fail "check-uimage accepted a kernel that grows by 5 MiB or more when inflated"
head -c 5000000 /dev/zero > "$T/vm.bin"
sh "$I/check-uimage.sh" "$T/max.uImage" "$T/vm.bin" "$T/vm.gz" >/dev/null 2>&1 ||
	fail "check-uimage refused a kernel inside the inflate head start"

# --- build-upt.py ------------------------------------------------------------
mkuimage "$T/inst.uImage" 3000000
printf 'UBI#....kernel..rootfs..kernel_b..rootfs_b' > "$T/nand.ubi"
printf 'UBI#....kernel..rootfs' > "$T/old.ubi"
printf 'spl' > "$T/spl"
printf 'u-boot..abselect..' > "$T/uboot"
printf 'u-boot..' > "$T/old-uboot"
upt() { "$PY" "$I/build-upt.py" --uimage "$1" --nand-ubi "$2" --spl "$T/spl" --uboot "$3" -o "$4"; }
SOURCE_DATE_EPOCH=1761998400 upt "$T/inst.uImage" "$T/nand.ubi" "$T/uboot" "$T/a.upt" >/dev/null || fail "build-upt"
SOURCE_DATE_EPOCH=1761998400 upt "$T/inst.uImage" "$T/nand.ubi" "$T/uboot" "$T/b.upt" >/dev/null || fail "build-upt (2)"
cmp -s "$T/a.upt" "$T/b.upt" || fail "build-upt is not reproducible under SOURCE_DATE_EPOCH"
upt "$T/over.uImage" "$T/nand.ubi" "$T/uboot" "$T/x.upt" >/dev/null 2>&1 && fail "build-upt accepted a 4194305-byte installer"
upt "$T/inst.uImage" "$T/old.ubi" "$T/uboot" "$T/x.upt" >/dev/null 2>&1 && fail "build-upt accepted a UBI image with no B slot"
upt "$T/inst.uImage" "$T/nand.ubi" "$T/old-uboot" "$T/x.upt" >/dev/null 2>&1 && fail "build-upt accepted a U-Boot with no abselect"
[ -e "$T/x.upt" ] && fail "build-upt wrote a .upt after refusing its inputs"

cat > "$T/read.py" <<'EOF'
import io, sys, pycdlib
iso = pycdlib.PyCdlib(); iso.open(sys.argv[1])
pvd = iso.pvd
names = sorted(c.file_identifier().decode() for c in iso.list_children(iso_path="/")
               if c.is_file())
print(" ".join(names))
print("volid=" + pvd.volume_identifier.decode().strip())
print("rr=%s joliet=%s" % (iso.has_rock_ridge(), iso.has_joliet()))
for n in sys.argv[2:]:
    b = io.BytesIO(); iso.get_file_from_iso_fp(b, iso_path="/" + n + ";1")
    sys.stdout.write(b.getvalue().decode())
EOF
"$PY" "$T/read.py" "$T/a.upt" UPDATE.TXT VERSION.TXT PAYLOAD.MD5 > "$T/a.txt" || fail "cannot read the .upt back"
md5() { md5sum "$1" | cut -d' ' -f1; }
printf '%s\n' \
	"NAND.UBI;1 OURSPL.BIN;1 OURUBOOT.BIN;1 PAYLOAD.MD5;1 UIMAGE.BIN;1 UPDATE.TXT;1 VERSION.TXT;1" \
	"volid=CDROM" "rr=False joliet=False" \
	"kernel={" "        name=kernel" "        file_path=autoupdate/uimage.bin" \
	"        md5=$(md5 "$T/inst.uImage")" "}" "" "" "" \
	"version={" "        name=erosq_2024" "        ver=2024-08-23T15:39:12+08:00" "}" "" \
	"$(md5 "$T/nand.ubi")  nand.ubi" "$(md5 "$T/spl")  ourspl.bin" "$(md5 "$T/uboot")  ouruboot.bin" \
	> "$T/want.txt"
cmp -s "$T/want.txt" "$T/a.txt" || { diff "$T/want.txt" "$T/a.txt"; fail "the .upt is not in the stock shape"; }

# --- check-payload.sh --------------------------------------------------------
mkroot() { rm -rf "$T/root" "$T/r.sqfs"; mkdir -p "$T/root/etc" "$T/root/root/.ssh"
	echo 'firmware v2026.11.0' > "$T/root/etc/sw-versions"; : > "$T/root/root/.ssh/authorized_keys"; }
sqfs() { mksquashfs "$T/root" "$T/r.sqfs" -quiet -noappend >/dev/null || fail mksquashfs; }
expect() { # expect ok|fail <what>
	if sh "$I/check-payload.sh" "$T/r.sqfs" >/dev/null 2>&1; then r=ok; else r=fail; fi
	[ "$r" = "$1" ] || fail "check-payload: $2 (wanted $1, got $r)"
}
mkroot
printf 'x\0-----BEGIN %s-----\0y' 'PRIVATE KEY' > "$T/root/etc/libcrypto-like"
sqfs; expect ok "clean rootfs, empty authorized_keys, a bare PEM header string"
mkroot; echo 'ssh-ed25519 AAAA test' > "$T/root/root/.ssh/authorized_keys"; sqfs
expect fail "non-empty authorized_keys"
mkroot; openssl genpkey -algorithm ED25519 -out "$T/root/etc/k.pem" 2>/dev/null || fail openssl; sqfs
expect fail "a private key"
mkroot; printf 'network={\n\tssid="x"\n\tpsk="secret"\n}\n' > "$T/root/etc/wpa.conf"; sqfs
expect fail "a Wi-Fi passphrase"
# private names come only from ANON_PATTERNS (case-insensitive, path or content)
mkroot; sqfs
ANON_PATTERNS='zq-private' sh "$I/check-payload.sh" "$T/r.sqfs" >/dev/null 2>&1 || fail "check-payload: ANON_PATTERNS false positive"
mkroot; mkdir -p "$T/root/usr/share/themes/ZQ-Private"; sqfs
ANON_PATTERNS='zq-private' sh "$I/check-payload.sh" "$T/r.sqfs" >/dev/null 2>&1 && fail "check-payload: ANON_PATTERNS path missed"
mkroot; echo 'firmware zq-private-2' > "$T/root/etc/sw-versions"; sqfs
ANON_PATTERNS='other
zq-PRIVATE' sh "$I/check-payload.sh" "$T/r.sqfs" >/dev/null 2>&1 && fail "check-payload: ANON_PATTERNS content missed"
# planted secrets inside compressed layers must be found
mkcpio() { # mkcpio <out.cpio.gz>: an initramfs with a non-empty authorized_keys
	rm -rf "$T/ir" && mkdir -p "$T/ir/root/.ssh" && echo 'ssh-ed25519 AAAA planted' > "$T/ir/root/.ssh/authorized_keys"
	(cd "$T/ir" && find . | cpio -o -H newc --quiet) | gzip -9n > "$1"
}
deep() { # deep <file> <what>: check-payload must refuse <file>
	sh "$I/check-payload.sh" "$1" >/dev/null 2>&1 && fail "check-payload missed $2"
	return 0
}
mkcpio "$T/ir.cpio.gz"
# a kernel blob with the initramfs linked into it, gzip'd, in a uImage
{ head -c 300000 /dev/urandom; cat "$T/ir.cpio.gz"; head -c 1000 /dev/urandom; } > "$T/vmlinux.bin"
gzip -9n -c "$T/vmlinux.bin" > "$T/vmlinux.bin.gz"
mkimage -A mips -O linux -T kernel -C gzip -a 0x80100000 -e 0x80100000 -n k \
	-d "$T/vmlinux.bin.gz" "$T/planted.uImage" >/dev/null || fail "mkimage (planted)"
deep "$T/planted.uImage" "an authorized_keys in an initramfs linked into a gzip'd uImage kernel"
# a FIT whose ramdisk is an xz'd cpio carrying a Wi-Fi passphrase
rm -rf "$T/ir" && mkdir -p "$T/ir/etc" && printf 'network={\n psk="planted"\n}\n' > "$T/ir/etc/wpa.conf"
(cd "$T/ir" && find . | cpio -o -H newc --quiet) | xz -9 > "$T/rd.xz"
head -c 1000 /dev/urandom > "$T/k.bin"
cat > "$T/f.its" <<ITS
/dts-v1/;
/ { description = "t"; #address-cells = <1>;
  images {
    kernel { data = /incbin/("$T/k.bin"); type = "kernel"; arch = "mips"; os = "linux";
             compression = "none"; load = <0x80100000>; entry = <0x80100000>; };
    ramdisk { data = /incbin/("$T/rd.xz"); type = "ramdisk"; arch = "mips"; os = "linux";
              compression = "none"; };
  };
  configurations { default = "c"; c { kernel = "kernel"; ramdisk = "ramdisk"; }; };
};
ITS
mkimage -f "$T/f.its" "$T/planted.itb" >/dev/null || fail "mkimage -f"
deep "$T/planted.itb" "a Wi-Fi passphrase in an xz'd ramdisk inside an ITB"
# a .upt whose installer carries the planted initramfs
upt "$T/planted.uImage" "$T/nand.ubi" "$T/uboot" "$T/planted.upt" >/dev/null || fail "build-upt (planted)"
deep "$T/planted.upt" "an authorized_keys inside the installer inside a .upt"
# zstd, and a private name only ANON_PATTERNS knows
printf 'build zq-private-host\n' | zstd -q > "$T/n.zst"
ANON_PATTERNS='zq-private' sh "$I/check-payload.sh" "$T/n.zst" >/dev/null 2>&1 &&
	fail "check-payload missed a private name in a zstd stream"
# it fails closed: every format it knows is unpacked, wherever it starts,
# and what it cannot unpack is a FAIL
mkcpio "$T/ir.cpio.gz"; gzip -dc "$T/ir.cpio.gz" > "$T/ir.cpio"
blob() { head -c 300000 /dev/urandom; cat; head -c 1000 /dev/urandom; }
lz4 -lq -c "$T/ir.cpio" | blob > "$T/k-lz4.bin" || fail lz4
deep "$T/k-lz4.bin" "an authorized_keys in an lz4 (legacy) initramfs inside a kernel blob"
blob < "$T/ir.cpio" > "$T/k-cpio.bin"
deep "$T/k-cpio.bin" "an authorized_keys in a raw cpio inside a kernel blob"
printf 'network={\n psk="planted"\n}\n' | bzip2 -9 > "$T/w.bz2" || fail bzip2
deep "$T/w.bz2" "a Wi-Fi passphrase in a bzip2 stream"
if command -v lzop >/dev/null; then
	printf 'network={\n psk="planted"\n}\n' | lzop -c > "$T/w.lzo" || fail lzop
	deep "$T/w.lzo" "a Wi-Fi passphrase in an lzo stream"
else # an lzo stream it cannot unpack (no lzop) fails the gate
	{ printf '\211LZO\000\r\n\032\n'; head -c 100 /dev/zero; } > "$T/w.lzo"
	deep "$T/w.lzo" "an lzo stream it cannot unpack"
fi
printf 'network={\n psk="planted"\n}\n' > "$T/nest"
for n in 1 2 3 4 5 6 7; do gzip -n < "$T/nest" > "$T/nest.gz" && mv "$T/nest.gz" "$T/nest"; done
deep "$T/nest" "a gzip stream still nested at the depth limit"
yes 'firmware v2026.11.0' | head -c 20000 | gzip -9n > "$T/bad.gz"
printf 'X' | dd of="$T/bad.gz" bs=1 seek=40 conv=notrunc 2>/dev/null
deep "$T/bad.gz" "a corrupt gzip stream"
# a bare magic number (a constant in a decoder) is not a stream
{ head -c 300000 /dev/zero; printf '\375\067zXZ\000 and \211LZO\000\r\n\032\n and 070701'; head -c 300 /dev/zero; } > "$T/consts"
sh "$I/check-payload.sh" "$T/consts" >/dev/null 2>&1 || fail "check-payload refused bare magic numbers in a blob"
# fail-open paths a security review found in eebb58b (each one was missed)
psk() { printf 'network={\n psk="planted"\n}\n'; }
os80() { # os80 <gz>: an OS byte the header check does not know; gzip -d does not care
	printf '\200' | dd of="$1" bs=1 seek=9 conv=notrunc 2>/dev/null
}
yes 'firmware v2026.11.0' | head -c 20000 | gzip -9n > "$T/m1.gz"
psk | gzip -9n > "$T/m2.gz"; os80 "$T/m2.gz"
cat "$T/m1.gz" "$T/m2.gz" > "$T/multi.gz"
gzip -dc "$T/multi.gz" | grep -q 'psk=' || fail "gzip -dc does not decode the second member (fixture)"
deep "$T/multi.gz" "a Wi-Fi passphrase in the second member of a gzip stream"
psk | gzip -9n > "$T/odd.gz"; os80 "$T/odd.gz"
blob < "$T/odd.gz" > "$T/k-odd.bin"
deep "$T/k-odd.bin" "a gzip stream inside a blob whose header fails the XFL/OS check"
cat > "$T/newc.py" <<'EOF'
import sys
# newc.py <out> <name> <mode-octal> <data-file|-> ...: a newc cpio, members verbatim
out = open(sys.argv[1], "wb")
a = sys.argv[2:]
def pad(n): out.write(b"\0" * (-n % 4))
ms = [(a[i].encode(), int(a[i + 1], 8), b"" if a[i + 2] == "-" else open(a[i + 2], "rb").read())
      for i in range(0, len(a), 3)] + [(b"TRAILER!!!", 0, b"")]
for ino, (nm, md, dt) in enumerate(ms, 1):
    h = b"070701" + b"".join(b"%08X" % v for v in
        (ino, md, 0, 0, 1, 0, len(dt), 0, 0, 0, 0, len(nm) + 1, 0))
    out.write(h + nm + b"\0"); pad(110 + len(nm) + 1)
    out.write(dt); pad(len(dt))
EOF
nc() { "$PY" "$T/newc.py" "$@" || fail "newc.py"; }
psk | gzip -9n > "$T/s.gz"; printf 'clean\n' > "$T/clean.txt"
# a later member with the same path must not hide the first one's data
nc "$T/dup.cpio" etc 040755 - etc/w 0100644 "$T/s.gz" etc/w 0100644 "$T/clean.txt"
blob < "$T/dup.cpio" > "$T/k-dup.bin"
deep "$T/k-dup.bin" "a passphrase in a cpio member that a later member with the same path replaces"
# a member that is not a regular file but carries data
nc "$T/fifo.cpio" etc 040755 - etc/p 010644 "$T/s.gz"
blob < "$T/fifo.cpio" > "$T/k-fifo.bin"
deep "$T/k-fifo.bin" "a passphrase in the data of a fifo cpio member"
# a member with no name that carries data (dropped, never written out)
nc "$T/dot.cpio" . 0100644 "$T/s.gz"
blob < "$T/dot.cpio" > "$T/k-dot.bin"
deep "$T/k-dot.bin" "a passphrase in a nameless cpio member"
# a stream inside an archive but outside every regular member's data (here a
# link target) is not covered by unpacking the archive: it is unpacked itself
# (a gzip header and deflate body with no NUL in them: a link target cannot
# hold one; with no trailer it cannot unpack either, which is a FAIL too)
"$PY" - "$T/l.gz" <<'EOF' || fail "no NUL-free gzip stream (fixture)"
import sys, zlib
for n in range(1000):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    # the end-of-block code is seven 0 bits: drop the last byte(s)
    body = (c.compress(b'network={\n psk="planted"\n}\n#%d\n' % n) + c.flush()).rstrip(b"\0")
    # FLG = FTEXT: a 0 flag byte would be a NUL
    g = b"\x1f\x8b\x08\x01\x5f\x5f\x5f\x5f\x02\x03" + body
    if b"\0" not in g:
        open(sys.argv[1], "wb").write(g)
        sys.exit(0)
sys.exit(1)
EOF
nc "$T/lnk.cpio" etc 040755 - etc/l 0120777 "$T/l.gz"
blob < "$T/lnk.cpio" > "$T/k-lnk.bin"
deep "$T/k-lnk.bin" "a gzip stream that is a cpio link target"
# bytes after a uImage payload ship too
head -c 1000 /dev/zero | gzip -9n > "$T/c0.gz"
mkimage -A mips -O linux -T kernel -C gzip -a 0x80100000 -e 0x80100000 -n k \
	-d "$T/c0.gz" "$T/c0.uImage" >/dev/null || fail "mkimage (trailer)"
sh "$I/check-payload.sh" "$T/c0.uImage" >/dev/null 2>&1 || fail "check-payload refused a clean uImage (trailer fixture)"
cat "$T/c0.uImage" "$T/s.gz" > "$T/trail.uImage"
deep "$T/trail.uImage" "a passphrase in a gzip stream after the uImage payload"
# gzip headers that fail the XFL/OS check are decoded with no fixed window,
# as gzip -d and the kernel read them (each one was missed by c494f46)
"$PY" - "$T" <<'EOF' || fail "gzip fixtures"
import random, struct, sys, zlib
t = sys.argv[1]
psk = b'network={\n psk="planted"\n}\n'
def raw(*parts):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return b"".join(c.compress(x) if isinstance(x, bytes) else c.flush(x) for x in parts) + c.flush()
def gz(flg, extra, body, data):  # OS 0x80: not one the header check knows
    return (b"\x1f\x8b\x08" + bytes([flg]) + b"\0\0\0\0\0\x80" + extra + body
            + struct.pack("<II", zlib.crc32(data), len(data)))
def put(n, b): open("%s/%s" % (t, n), "wb").write(b)
# a file name longer than the old 1 MiB trial window
put("fname.gz", gz(8, b"a" * (1100 << 10) + b"\0", raw(psk), psk))
# 1.1 MiB of empty stored blocks (no output) before the data
put("empty.gz", gz(0, b"", b"\0\0\0\xff\xff" * 230000 + raw(psk), psk))
# FEXTRA set but no extra field: the kernel reads deflate data at byte 10
put("kern.gz", gz(4, b"", raw(psk), psk))
# the data, then a block of the reserved type: a streaming decoder writes
# the data out before it fails
put("cut.gz", gz(0, b"", raw(psk, zlib.Z_SYNC_FLUSH)[:-1] + b"\x07\0\0", psk))
# one header, two readings: gzip -d skips an FEXTRA field that the kernel
# reads as deflate data (its XLEN is the first two bytes of that data)
ks = raw(psk)
xlen = struct.unpack("<H", ks[:2])[0]
assert len(ks) - 2 <= xlen
clean = b"clean\n"
put("two.gz", b"\x1f\x8b\x08\x04\0\0\0\0\0\x03" + ks.ljust(xlen + 2, b"\0") + raw(clean)
    + struct.pack("<II", zlib.crc32(clean), len(clean)))
# random bytes behind many gzip magics decode a few bytes now and then:
# a clean blob still passes
r = random.Random(1)
b = bytearray(r.getrandbits(8) for _ in range(1 << 21))
for i in range(600):
    o = r.randrange(len(b) - 16)
    b[o:o + 10] = b"\x1f\x8b\x08" + bytes([r.choice((0, 2, 4, 8, 16, 0x16, 0x20))]) + bytes(r.getrandbits(8) for _ in range(5)) + b"\x80"
put("magics.bin", bytes(b))
EOF
gzip -dc "$T/fname.gz" 2>/dev/null | grep -q 'psk=' || fail "gzip -dc does not decode fname.gz (fixture)"
gzip -dc "$T/empty.gz" 2>/dev/null | grep -q 'psk=' || fail "gzip -dc does not decode empty.gz (fixture)"
gzip -dc "$T/cut.gz" 2>/dev/null | grep -q 'psk=' || fail "gzip -dc writes nothing of cut.gz (fixture)"
gzip -dc "$T/two.gz" 2>/dev/null | grep -qx clean || fail "gzip -dc does not decode two.gz (fixture)"
for g in fname empty kern cut two; do blob < "$T/$g.gz" > "$T/k-$g.bin"; done
deep "$T/k-fname.bin" "a gzip stream with a 1.1 MiB file name inside a blob"
deep "$T/k-empty.bin" "a gzip stream that starts with 1.1 MiB of empty blocks inside a blob"
deep "$T/k-kern.bin" "a gzip stream the kernel reads past an FEXTRA flag inside a blob"
deep "$T/k-cut.bin" "the data a gzip stream decodes before its error inside a blob"
deep "$T/k-two.bin" "the kernel's reading of a gzip header that gzip -d reads otherwise"
sh "$I/check-payload.sh" "$T/magics.bin" >/dev/null 2>&1 || fail "check-payload refused random bytes behind gzip magics"
# and a clean compressed installer passes
{ head -c 300000 /dev/zero; head -c 1000 /dev/zero | gzip -9n; } | gzip -9n > "$T/clean.gz"
mkimage -A mips -O linux -T kernel -C gzip -a 0x80100000 -e 0x80100000 -n k \
	-d "$T/clean.gz" "$T/clean.uImage" >/dev/null || fail "mkimage (clean)"
sh "$I/check-payload.sh" "$T/clean.uImage" >/dev/null 2>&1 || fail "check-payload refused a clean uImage"
echo "PASS: installer tools"
