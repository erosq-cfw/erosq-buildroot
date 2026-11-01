#!/bin/sh
# Host self-check for the update.upt tools in board/erosq/installer/:
# check-uimage.sh refuses an installer over the stock bootloader's 4 MiB read
# (one byte over included) or with the wrong header, build-upt.py writes the
# stock .upt shape and refuses wrong payloads, and check-payload.sh finds keys,
# Wi-Fi credentials and private names inside a squashfs.
# Needs mkimage/dumpimage, dtc, mksquashfs/unsquashfs, cpio, xz, zstd, openssl and PYTHON (default python3)
# with pycdlib.
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
# and a clean compressed installer passes
{ head -c 300000 /dev/zero; head -c 1000 /dev/zero | gzip -9n; } | gzip -9n > "$T/clean.gz"
mkimage -A mips -O linux -T kernel -C gzip -a 0x80100000 -e 0x80100000 -n k \
	-d "$T/clean.gz" "$T/clean.uImage" >/dev/null || fail "mkimage (clean)"
sh "$I/check-payload.sh" "$T/clean.uImage" >/dev/null 2>&1 || fail "check-payload refused a clean uImage"
echo "PASS: installer tools"
