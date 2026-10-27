#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 erosqcfw
"""Extract the EROS Q Wi-Fi/BT chip firmware from the stock HiBy firmware.

The CYW43438 (AzureWave AW-NM372SM) blobs are not redistributable, so the
repo does not carry them: every build takes them from a stock image the
builder supplies.

usage: extract-stock-firmware.py SOURCE OUTDIR

SOURCE is one of
  - the stock update file, e.g. update_erosQ_v2.2-rbuninstall.upt (an ISO 9660
    image holding SYSTEM.UBI; the hw4 / v2.2 file that the Rockbox
    uninstaller page distributes for the EROS Q),
  - that SYSTEM.UBI on its own,
  - a directory with the stock rootfs already extracted (it must contain
    firmware/ and lib/firmware/ as in the stock image).
A .upt or SYSTEM.UBI needs ubi_reader on the host (pip install ubi_reader,
GPL-3.0) for ubireader_extract_files.

OUTDIR receives the files laid out as /lib/firmware on the target:
  BCM4343A1_001.002.009.0122.0538.hcd       (bt_up.sh / brcm_patchram_plus)
  brcm/BCM43430A1.hcd                       (btbcm, same file)
  brcm/brcmfmac43430-sdio.bin               (stock cyw43438-7.46.58.35.bin)
  brcm/brcmfmac43430-sdio.txt               (stock nvram_azw372.txt, see below)
  brcm/brcmfmac43430-sdio.aigo,erosq.{bin,txt} -> the two above

NVRAM: the stock image keeps the NVRAM with a placeholder macaddr plus a
separate firmware/wifimac.txt; we write wifimac.txt into macaddr, which is
what the stock driver did. Both come from the stock image, so every unit
gets the same value, and the chip ignores it: wlan0 uses the MAC
programmed in the module's OTP (checked on hardware 2026-06-22).

Every input and output file is checked against a pinned sha256; anything else
(another firmware version, a damaged dump) stops the build.
"""
import hashlib, os, re, shutil, struct, subprocess, sys, tempfile

STOCK = {  # path in the stock rootfs -> sha256
    "firmware/cyw43438-7.46.58.35.bin":
        "37575bf1f36011c187adab4961fd3c96c9976f86f1211890826734a0cbeb6674",
    "firmware/nvram_azw372.txt":
        "ff2c1584579bcad0f48f8642e91641066b398094a18bad69aeff01060b6c4867",
    "firmware/wifimac.txt":
        "0eec9e69ae5e9bc1d2adf79742b36bb92645aafe04529a8478078fb34de09554",
    "lib/firmware/BCM4343A1_001.002.009.0122.0538.hcd":
        "9873217acdeaee78bd502a31fa876dc1b120c9d07ca8c16420853bc44ba64972",
}
NVRAM_OUT = "63280e581240fcba0626850e1cd561543d6d9cd80d5854423e1602d7c28f5a81"

HELP = ("Supply the stock EROS Q firmware: set BR2_PACKAGE_EROSQ_BOARD_STOCK_FW "
        "to the stock update_erosQ_v2.2-rbuninstall.upt (or its SYSTEM.UBI, or "
        "an extracted stock rootfs directory), or put the .upt in "
        "$BR2_EXTERNAL_EROSQ_PATH/stock/. See package/erosq-board/"
        "extract-stock-firmware.py.")


def die(msg):
    sys.exit(f"extract-stock-firmware: ERROR: {msg}\n{HELP}")


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def iso_extract(iso, name, out):
    """Copy root-directory file `name` out of an ISO 9660 image (stdlib only)."""
    with open(iso, "rb") as f:
        f.seek(16 * 2048)
        pvd = f.read(2048)
        if pvd[1:6] != b"CD001":
            return False
        root = pvd[156:156 + 34]
        lba, size = struct.unpack_from("<I", root, 2)[0], struct.unpack_from("<I", root, 10)[0]
        f.seek(lba * 2048)
        d = f.read(size)
        i = 0
        while i < len(d):
            n = d[i]
            if n == 0:  # records don't cross sectors: skip to the next one
                i = (i // 2048 + 1) * 2048
                continue
            ident = d[i + 33:i + 33 + d[i + 32]].split(b";")[0]
            if ident.upper() == name:
                elba, elen = struct.unpack_from("<I", d, i + 2)[0], struct.unpack_from("<I", d, i + 10)[0]
                f.seek(elba * 2048)
                with open(out, "wb") as o:
                    left = elen
                    while left:
                        chunk = f.read(min(left, 1 << 20))
                        if not chunk:
                            die(f"{iso}: truncated ISO image")
                        o.write(chunk)
                        left -= len(chunk)
                return True
            i += n
    die(f"{iso}: ISO image without {name.decode()}")


def rootfs_from(src, tmp):
    if os.path.isdir(src):
        return src
    ubi = src
    if iso_extract(src, b"SYSTEM.UBI", os.path.join(tmp, "SYSTEM.UBI")):
        ubi = os.path.join(tmp, "SYSTEM.UBI")
    tool = shutil.which("ubireader_extract_files")
    if not tool:
        die("ubireader_extract_files not found (pip install ubi_reader); "
            "or pass an already extracted stock rootfs directory")
    root = os.path.join(tmp, "root")
    # -k keeps going past chown/mknod failures (we run unprivileged)
    subprocess.run([tool, "-k", "-o", root, ubi], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
    return root


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    if not src or not os.path.exists(src):
        die(f"stock firmware source not found: {src or '(not set)'}")
    with tempfile.TemporaryDirectory(prefix="erosq-stockfw-") as tmp:
        root = rootfs_from(src, tmp)
        for rel, want in STOCK.items():
            p = os.path.join(root, rel)
            if not os.path.isfile(p):
                die(f"{src}: no {rel} in the stock rootfs")
            if sha(p) != want:
                die(f"{src}: {rel} has an unexpected sha256 (not the EROS Q stock v2.2 firmware?)")
        brcm = os.path.join(out, "brcm")
        os.makedirs(brcm, exist_ok=True)
        hcd = os.path.join(root, "lib/firmware/BCM4343A1_001.002.009.0122.0538.hcd")
        shutil.copyfile(hcd, os.path.join(out, "BCM4343A1_001.002.009.0122.0538.hcd"))
        shutil.copyfile(hcd, os.path.join(brcm, "BCM43430A1.hcd"))
        shutil.copyfile(os.path.join(root, "firmware/cyw43438-7.46.58.35.bin"),
                        os.path.join(brcm, "brcmfmac43430-sdio.bin"))
        nvram = open(os.path.join(root, "firmware/nvram_azw372.txt"), "rb").read()
        mac = open(os.path.join(root, "firmware/wifimac.txt"), "rb").read().strip()
        nvram, n = re.subn(rb"^macaddr=.*$", b"macaddr=" + mac, nvram, count=1, flags=re.M)
        txt = os.path.join(brcm, "brcmfmac43430-sdio.txt")
        with open(txt, "wb") as f:
            f.write(nvram)
        if n != 1 or sha(txt) != NVRAM_OUT:
            die("NVRAM output does not match the expected file")
        for ext in ("bin", "txt"):
            link = os.path.join(brcm, f"brcmfmac43430-sdio.aigo,erosq.{ext}")
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink(f"brcmfmac43430-sdio.{ext}", link)
    print(f"extract-stock-firmware: OK -> {out}")


if __name__ == "__main__":
    main()
