#!/usr/bin/env python3
"""Assemble update.upt: the file the stock EROS Q firmware runs from
Firmware Update to install erosq.

The stock updater writes each section of a .upt by MTD partition NAME, and its
`uboot` partition (512 KiB) is too small for our SPL + U-Boot. So the manifest
names ONE section, `kernel`, which carries the installer (a small kernel with
an initramfs). The stock bootloader then boots it, and the installer
loop-mounts this same file from the SD card and writes the real payload
(SPL, U-Boot, the UBI image) itself. The payload files ride in the image
under names the manifest never mentions.

Shape: ISO9660 interchange level 1, flat root, 8.3 uppercase names, volume id
CDROM, no Rock Ridge, no Joliet. `autoupdate/` in file_path= is the updater's
mount prefix, not a directory. The updater checks the md5 of each section
listed in UPDATE.TXT; the .upt carries no signature.

Needs pycdlib (LGPL-2.1), a build-time tool only.
"""
import argparse
import hashlib
import io
import os
import sys
import time

try:
    import pycdlib
except ImportError:
    sys.exit("FATAL: pycdlib missing (pip install pycdlib)")

# ISO member names; the payload names must match the lookups in the
# installer's init (mode=upt), which match case-insensitively.
ISO_UPDATE = "UPDATE.TXT"
ISO_VERSION = "VERSION.TXT"
ISO_UIMAGE = "UIMAGE.BIN"
ISO_UBI = "NAND.UBI"
ISO_SPL = "OURSPL.BIN"
ISO_UBOOT = "OURUBOOT.BIN"
ISO_MD5 = "PAYLOAD.MD5"
LOGICAL = {ISO_UBI: "nand.ubi", ISO_SPL: "ourspl.bin", ISO_UBOOT: "ouruboot.bin"}

# The stock bootloader loads the `kernel` partition with a FIXED 4 MiB read
# (0x400000), whatever the partition size (6 MiB) or the uImage header says,
# and it has no boot delay. An installer one byte larger is cut short, fails
# its CRC, and the unit boots nothing, after the stock kernel it replaced is
# gone. Do not raise this: make the installer smaller.
UIMAGE_MAX = 4 * 1024 * 1024

# Product name the stock updater requires. EROS Q hw4 ("V2.2") and the units
# that share its update file use erosq_2024.
PRODUCT = "erosq_2024"
# `ver=` as the stock update for this product carries it; the updater is not
# known to compare it, so keep the same value.
DEFAULT_VER = "2024-08-23T15:39:12+08:00"


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def manifest_text(uimage_md5):
    """UPDATE.TXT: eight-space indent, LF line ends, blank line after `}`."""
    return ("kernel={\n"
            "        name=kernel\n"
            "        file_path=autoupdate/uimage.bin\n"
            f"        md5={uimage_md5}\n"
            "}\n\n")


def version_text(ver=DEFAULT_VER, product=PRODUCT):
    """VERSION.TXT, in the stock layout (two leading newlines, eight-space indent)."""
    return ("\n\nversion={\n"
            f"        name={product}\n"
            f"        ver={ver}\n"
            "}\n\n")


def payload_md5_text(ubi, spl, uboot):
    """md5sum-format list keyed on the lowercase names the installer looks up.
    uimage.bin is absent: the updater checks it against UPDATE.TXT, and by the
    time the installer runs it is no longer a file."""
    return "".join(f"{md5_file(p)}  {LOGICAL[n]}\n"
                   for n, p in ((ISO_UBI, ubi), (ISO_SPL, spl), (ISO_UBOOT, uboot)))


def check_inputs(uimage, nand_ubi, spl, uboot):
    """Every gate the build enforces; returns a list of errors (empty = OK).
    The md5 lists prove WHICH files were packed, never that they were the
    RIGHT ones, so the payloads are also checked for what they contain."""
    errs = []
    size = os.path.getsize(uimage)
    if size > UIMAGE_MAX:
        errs.append(f"uimage is {size} bytes; the stock bootloader reads only "
                    f"{UIMAGE_MAX} (a larger image fails its CRC and nothing boots)")
    with open(uimage, "rb") as f:
        if f.read(4) != b"\x27\x05\x19\x56":
            errs.append("uimage has no uImage header")
    with open(uboot, "rb") as f:
        if b"abselect" not in f.read():
            errs.append("uboot has no `abselect`: not the A/B U-Boot")
    with open(nand_ubi, "rb") as f:
        ubi = f.read()
    if not ubi.startswith(b"UBI#"):
        errs.append("nand-ubi is not a UBI image")
    if b"kernel_b" not in ubi or b"rootfs_b" not in ubi:
        errs.append("nand-ubi has no kernel_b/rootfs_b: not the A/B layout")
    if os.path.getsize(spl) > 0x20000:
        errs.append("spl is larger than the 128 KiB spl partition")
    return errs


def pin_clock():
    """With SOURCE_DATE_EPOCH set, every ISO date is that time in UTC, so the
    same inputs give a byte-identical .upt. pycdlib takes its dates from
    time.time() and time.localtime()."""
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if epoch is None:
        return
    os.environ["TZ"] = "UTC"
    time.tzset()
    time.time = lambda: float(int(epoch))


def build_upt(out_path, uimage, nand_ubi, spl, uboot, version):
    """Write the .upt and return the manifest text."""
    pin_clock()
    manifest = manifest_text(md5_file(uimage)).encode()
    payload_md5 = payload_md5_text(nand_ubi, spl, uboot).encode()

    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=1, vol_ident="CDROM")
    for name, data in ((ISO_UPDATE, manifest), (ISO_VERSION, version.encode()),
                       (ISO_MD5, payload_md5)):
        iso.add_fp(io.BytesIO(data), len(data), f"/{name};1")
    handles = []  # pycdlib reads them at write()
    for name, path in ((ISO_UIMAGE, uimage), (ISO_UBI, nand_ubi),
                       (ISO_SPL, spl), (ISO_UBOOT, uboot)):
        fp = open(path, "rb")
        handles.append(fp)
        iso.add_fp(fp, os.path.getsize(path), f"/{name};1")
    iso.write(out_path)
    iso.close()
    for fp in handles:
        fp.close()
    return manifest.decode()


def main():
    ap = argparse.ArgumentParser(description="Build update.upt (stock firmware -> erosq)")
    ap.add_argument("--uimage", required=True, help=f"installer uImage (max {UIMAGE_MAX} bytes)")
    ap.add_argument("--nand-ubi", required=True, help="A/B UBI image")
    ap.add_argument("--spl", required=True, help="SPL with its boot ROM header")
    ap.add_argument("--uboot", required=True, help="U-Boot (must contain `abselect`)")
    ap.add_argument("--ver", default=DEFAULT_VER, help="VERSION.TXT ver= value")
    ap.add_argument("-o", "--out", required=True, help="output .upt")
    a = ap.parse_args()

    for label, path in (("uimage", a.uimage), ("nand-ubi", a.nand_ubi),
                        ("spl", a.spl), ("uboot", a.uboot)):
        if not os.path.isfile(path):
            sys.exit(f"FATAL: --{label} not found: {path}")
    errs = check_inputs(a.uimage, a.nand_ubi, a.spl, a.uboot)
    if errs:
        sys.exit("FATAL: " + "\nFATAL: ".join(errs))

    manifest = build_upt(a.out, a.uimage, a.nand_ubi, a.spl, a.uboot, version_text(a.ver))
    print(f"{a.out}: {os.path.getsize(a.out)} bytes, uimage "
          f"{os.path.getsize(a.uimage)} of {UIMAGE_MAX}")
    print(manifest, end="")
    print(f"{md5_file(a.out)}  {os.path.basename(a.out)}")


if __name__ == "__main__":
    main()
