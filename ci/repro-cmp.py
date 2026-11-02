#!/usr/bin/env python3
"""Compare a release with its rebuild, for repro.yml.
  ci/repro-cmp.py <release-dir> <rebuild-dir>
Each dir holds a SHA256SUMS; every file the release lists must be in the
rebuild's. A .swu (cpio newc/crc) must also be in both dirs and match its
SHA256SUMS line, and is compared by its entries: the same names in the same
order with the same contents. The cpio headers (mtime, inode, mode, owner)
are not compared. Any other file is compared by its sha256. Exit 1 on any
difference."""
import hashlib, os, sys


def sums(d):
    out = {}
    with open(os.path.join(d, "SHA256SUMS")) as f:
        for line in f:
            h, name = line.rstrip("\n").split(None, 1)
            out[name.lstrip("*")] = h
    return out


def entries(path):
    """[(name, sha256 of content)] in archive order, TRAILER!!! excluded."""
    d = open(path, "rb").read()
    o, out = 0, []
    while True:
        if d[o:o + 6] not in (b"070701", b"070702"):
            raise ValueError(f"{path}: no cpio newc/crc header at {o}")
        f = [int(d[o + 6 + 8 * i:o + 14 + 8 * i], 16) for i in range(13)]
        size, namesize = f[6], f[11]
        name = d[o + 110:o + 110 + namesize - 1].decode()
        do = (o + 110 + namesize + 3) & ~3
        if do + size > len(d):
            raise ValueError(f"{path}: {name} truncated")
        o = (do + size + 3) & ~3
        if name == "TRAILER!!!":
            if d[o:].strip(b"\0"):
                raise ValueError(f"{path}: data after the trailer")
            return out
        out.append((name, hashlib.sha256(d[do:do + size]).hexdigest()))


def main(rel, reb):
    a, b = sums(rel), sums(reb)
    bad = 0
    for name, h in sorted(a.items()):
        if name not in b:
            print(f"MISSING in rebuild: {name}"); bad += 1; continue
        if not name.endswith(".swu"):
            if h != b[name]:
                print(f"DIFFERS: {name}"); bad += 1
            continue
        lists = []
        for d, s in ((rel, a), (reb, b)):
            p = os.path.join(d, name)
            if hashlib.sha256(open(p, "rb").read()).hexdigest() != s[name]:
                raise ValueError(f"{p} does not match its SHA256SUMS")
            lists.append(entries(p))
        if lists[0] != lists[1]:
            print(f"DIFFERS: {name} entries (name sha256)")
            for tag, l in zip("<>", lists):
                for n, eh in l:
                    print(f"  {tag} {n} {eh}")
            bad += 1
        else:
            print(f"same entries: {name} ({', '.join(n for n, _ in lists[0])})")
    if bad:
        print(f"{bad} of {len(a)} files differ")
        return 1
    print(f"{len(a)} files identical")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    try:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    except (OSError, ValueError) as e:
        print(f"repro-cmp: ERROR: {e}")
        sys.exit(1)
