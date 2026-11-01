#!/usr/bin/env python3
"""Find and unpack the streams and archives inside a file, for check-payload.sh.

  unpack-stream.py scan <file>                    one "<format> <offset>" line
                                                  per stream found
  unpack-stream.py unpack <format> <file> <offset> <out>
                                                  exit 0: unpacked to <out>
                                                  (a file, or a directory for
                                                  cpio and ubi), and prints
                                                  the offset where the stream
                                                  ends, then for cpio one
                                                  "<start> <end>" line per
                                                  regular member written out;
                                                  exit 1: it cannot be unpacked

Formats: gzip, xz, lzma (.lzma "alone"), zstd, bzip2, lz4 (legacy, as Linux
uses it), lzo (lzop), cpio (newc, crc, odc), ubi (an ubinize image).

A file that STARTS with a format's magic is that format and must unpack.
Inside a file, a magic is a stream when its header is one a decoder accepts:
a magic number on its own also turns up as a constant in decoders, in
compressed data and in code. The header checks are:
  gzip   deflate, no reserved flag bit, XFL 0/2/4, OS 0-13 or 255
  gzip-lax  any other gzip magic + deflate method byte, its header parsed
         as gzip -d parses it (FEXTRA, FNAME, FCOMMENT, FHCRC skipped; XFL,
         OS, reserved flags and the header CRC ignored), whose deflate data
         decodes to at least one byte before an error, its end, or the end
         of the file; there is no fixed window
  gzip-kernel  the same with the header parsed as Linux's gunzip does it
         (only FNAME skipped): any gzip magic whose FEXTRA, FCOMMENT or FHCRC
         flag makes the two parses differ
  xz     stream flags with a valid CRC32
  lzma   props 0x5d, a dictionary of 2^n or 3*2^(n-1) bytes (4 KiB-1 GiB);
         inside a file only with the size unknown (8 x 0xff), as `lzma -9`
         writes it for the kernel; the plain 3-byte magic is everywhere
  zstd   no reserved frame-header bit, a first block of a known type within
         the 128 KiB block limit
  bzip2  "BZh1".."BZh9" + a block or end-of-stream magic
  lz4    a first block of 1 B to LZ4_COMPRESSBOUND(8 MiB)
  lzo    an lzop header (method 1-3) with a valid header checksum
  cpio   the magic and all of the header's hex (newc/crc) or octal (odc) digits
  ubi    at the start of a file only
The member headers inside one cpio archive are not listed as archives, and
check-payload.sh skips whatever lies inside a stream it has unpacked (inside
a cpio archive, only the data of the regular members written out). Every
stream that passes is unpacked by its own decoder up to its own end (data
after it is ignored; for gzip, every member that follows), and a stream that
then fails to decode, ends early or decodes to more than MAXOUT bytes is an
error: the caller fails closed. gzip-lax and gzip-kernel are the exception:
what they decode up to an error or the end of the file is what gzip -d or the
kernel would have written out, so it is unpacked and scanned (random bytes
after a gzip magic often decode a few bytes before an error, so refusing them
would refuse clean images); such a stream claims no range (its end is
printed as <offset> + 1), so every stream inside it is unpacked as well. A cpio member that is not a regular file or a
link but carries data is an error too. Only the Python standard library, plus the zstd, lz4 and lzop tools.
"""
import bz2
import lzma
import mmap
import os
import re
import stat
import struct
import subprocess
import sys
import zlib

MAXOUT = 1 << 30            # 1 GiB out of any one stream
CHUNK = 1 << 20
LZ4_BLOCK = 8 << 20         # legacy format: every block but the last is 8 MiB
LZ4_BOUND = LZ4_BLOCK + LZ4_BLOCK // 255 + 16
LZ4_MAGIC = b"\x02\x21\x4c\x18"
LZO_MAGIC = b"\x89LZO\x00\r\n\x1a\n"


class Bad(Exception):
    pass


# --- header checks: (format, magic regex, check(data, offset, at_start)) -----

def strict_gzip(d, o):
    h = d[o:o + 10]
    return len(h) == 10 and not h[3] & 0xe0 and h[8] in (0, 2, 4) and (h[9] <= 13 or h[9] == 255)


def ok_gzip(d, o, start):
    return start or strict_gzip(d, o)


def gzip_body(d, o, kernel):
    """where the deflate data of the gzip header at <o> starts, or None when
    the header runs past the end of the file. gzip -d (and zlib) skip FEXTRA,
    FNAME, FCOMMENT and FHCRC; Linux's lib/decompress_inflate.c skips only
    FNAME and reads the rest as deflate data"""
    f, p = d[o + 3], o + 10
    if f & 4 and not kernel:
        if p + 2 > len(d):
            return None
        p += 2 + struct.unpack("<H", d[p:p + 2])[0]
    for bit in (8, 16):
        if f & bit and (bit == 8 or not kernel):
            q = d.find(b"\0", p)
            if q < 0:
                return None
            p = q + 1
    if f & 2 and not kernel:
        p += 2
    return p if p <= len(d) else None


class Output(Exception):
    pass


def output(b):
    if b:
        raise Output()


def inflate(d, p, write):
    """raw deflate from <p>, as far as it decodes, every byte it decodes
    passed to <write>: (offset, how it stopped). "end": the deflate stream
    ends at offset; "error": the byte at offset is where it fails (the
    output up to it, as a streaming decoder writes it, is written too);
    "eof": the file ends first"""
    z, step = zlib.decompressobj(-15), 4096
    while p < len(d):
        chunk, saved = d[p:p + step], z.copy()
        try:
            write(z.decompress(chunk))
        except zlib.error:
            # again one byte at a time from before the chunk: what decodes
            # up to the bad byte is written out
            z = saved
            for i in range(p, p + len(chunk)):
                try:
                    write(z.decompress(d[i:i + 1]))
                except zlib.error:
                    return i, "error"
                if z.eof:
                    return i + 1, "end"
            raise Bad("gzip: an error that one byte at a time does not repeat")
        if z.eof:
            return p + len(chunk) - len(z.unused_data), "end"
        p += len(chunk)
    write(z.flush())
    return len(d), "eof"


def lax_gzip(d, o, kernel):
    """the deflate data after the header (parsed as gzip -d or the kernel
    does) decodes to at least one byte"""
    p = gzip_body(d, o, kernel)
    if p is None:
        return False
    try:
        inflate(d, p, output)
    except Output:
        return True
    return False


def ok_xz(d, o, start):
    h = d[o + 6:o + 12]
    return start or (len(h) == 6 and struct.unpack("<I", h[2:])[0] == zlib.crc32(h[:2]))


def ok_lzma(d, o, start):
    h = d[o:o + 13]
    if len(h) < 13 or h[0] != 0x5d:
        return False
    dic = struct.unpack("<I", h[1:5])[0]
    if not any(dic in (1 << n, 3 << (n - 1)) for n in range(12, 31)):
        return False
    size = struct.unpack("<Q", h[5:13])[0]
    return size == (1 << 64) - 1 or (start and size <= MAXOUT)


def zstd_hdr(d, o):
    """the offset of the first block header, or None"""
    if o + 5 > len(d):
        return None
    fhd = d[o + 4]
    if fhd & 0x08:
        return None
    single = (fhd >> 5) & 1
    return (o + 5 + (0 if single else 1) + (0, 1, 2, 4)[fhd & 3]
            + ((1 if single else 0), 2, 4, 8)[fhd >> 6])


def ok_zstd(d, o, start):
    if start:
        return True
    b = zstd_hdr(d, o)
    if b is None or b + 3 > len(d):
        return False
    h = int.from_bytes(d[b:b + 3], "little")
    return (h >> 1) & 3 != 3 and h >> 3 <= 128 << 10


def ok_lz4(d, o, start):
    h = d[o + 4:o + 8]
    return start or (len(h) == 4 and 0 < struct.unpack("<I", h)[0] <= LZ4_BOUND)


def ok_lzo(d, o, start):
    """an lzop file header with a valid checksum"""
    if start:
        return True
    try:
        p = o + 9
        ver = struct.unpack(">H", d[p:p + 2])[0]
        new = ver >= 0x0940
        p += 6 if new else 4
        method = d[p]
        p += 2 if new else 1
        flags = struct.unpack(">I", d[p:p + 4])[0]
        p += 4 + (4 if flags & 0x800 else 0) + (12 if new else 8)
        p += 1 + d[p]
        want = struct.unpack(">I", d[p:p + 4])[0]
    except (IndexError, struct.error):
        return False
    sum_ = zlib.crc32 if flags & 0x1000 else zlib.adler32
    return method in (1, 2, 3) and sum_(d[o + 9:p]) == want


def ok_any(d, o, start):
    return True


FORMATS = [
    ("gzip", rb"\x1f\x8b\x08", ok_gzip),
    ("xz", rb"\xfd7zXZ\x00", ok_xz),
    ("lzma", rb"\x5d\x00\x00..\xff{8}", ok_lzma),
    ("zstd", rb"\x28\xb5\x2f\xfd", ok_zstd),
    ("bzip2", rb"BZh[1-9](?:\x31\x41\x59\x26\x53\x59|\x17\x72\x45\x38\x50\x90)", ok_any),
    ("lz4", re.escape(LZ4_MAGIC), ok_lz4),
    ("lzo", re.escape(LZO_MAGIC), ok_lzo),
    ("cpio", rb"07070[12][0-9A-Fa-f]{104}|070707[0-7]{70}", ok_any),
]


def scan(path):
    out = []
    with open(path, "rb") as fh:
        if os.fstat(fh.fileno()).st_size == 0:
            return out
        d = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
        if d[:4] == b"UBI#":
            return [("ubi", 0)]
        # any lzma "alone" header at the start, not only the 8 x 0xff kind
        if ok_lzma(d, 0, True):
            out.append(("lzma", 0))
        for name, rx, ok in FORMATS:
            r, m = re.compile(rx, re.S), None
            while True:  # every match, overlapping ones too
                m = r.search(d, m.start() + 1 if m else 0)
                if not m:
                    break
                o = m.start()
                if ok(d, o, o == 0):
                    if (name, o) not in out:
                        out.append((name, o))
                elif name == "gzip" and lax_gzip(d, o, False):
                    out.append(("gzip-lax", o))
                # where the kernel would read other deflate data, that too
                if name == "gzip" and o + 3 < len(d) and d[o + 3] & 0x16 and lax_gzip(d, o, True):
                    out.append(("gzip-kernel", o))
    out.sort(key=lambda x: x[1])
    # the member headers of one cpio archive are not archives of their own
    end, kept = 0, []
    for name, o in out:
        if name == "cpio":
            if o < end:
                continue
            try:
                end = cpio_walk(d, o)
            except Bad:
                end = 0     # a broken archive: unpack says why
        kept.append((name, o))
    return kept


# --- decoders ----------------------------------------------------------------

class Sink:
    def __init__(self, path):
        self.f = open(path, "wb")
        self.n = 0

    def write(self, b):
        self.n += len(b)
        if self.n > MAXOUT:
            raise Bad("decodes to more than %d bytes" % MAXOUT)
        self.f.write(b)

    def close(self):
        self.f.close()


def py_stream(dec, d, o, out, name):
    """stdlib decompressor objects: they say where their stream ends"""
    s = Sink(out)
    try:
        return into(dec, d, o, s, name)
    finally:
        s.close()


def un_gzip(d, o, out):
    """every member, as gzip -d decodes them: a gzip magic right after a member
    is the next member of the same stream"""
    s = Sink(out)
    try:
        while True:
            o = into(Zlib(), d, o, s, "gzip")
            if d[o:o + 2] != b"\x1f\x8b":
                return o
    finally:
        s.close()


def un_gzip_lax(d, o, out, kernel):
    """one member, decoded as gzip -d (or the kernel) decodes it: the header
    parsed leniently, the trailer not checked, the output up to an error or
    the end of the file kept. A member that ends cleanly ends at its trailer
    (and a member after it is decoded too); otherwise the stream claims no
    range: <o> + 1"""
    p = gzip_body(d, o, kernel)
    if p is None:
        raise Bad("gzip header runs past the end of the file")
    s = Sink(out)
    try:
        e, how = inflate(d, p, s.write)
        if how != "end" or e + 8 > len(d):
            return o + 1
        e += 8
        while d[e:e + 3] == b"\x1f\x8b\x08" and not kernel:
            if strict_gzip(d, e):
                e = into(Zlib(), d, e, s, "gzip")
                continue
            q = gzip_body(d, e, False)
            if q is None:
                break
            q, how = inflate(d, q, s.write)
            if how != "end" or q + 8 > len(d):
                break
            e = q + 8
        return e
    finally:
        s.close()


def into(dec, d, o, s, name):
    try:
        while not dec.eof:
            if o >= len(d):
                raise Bad("%s stream ends early (truncated)" % name)
            chunk = d[o:o + CHUNK]
            o += len(chunk)
            # max_length bounds memory; whatever it holds back stays buffered
            s.write(dec.decompress(chunk, CHUNK))
            while not dec.eof and not dec.needs_input:
                s.write(dec.decompress(b"", CHUNK))
        return o - len(dec.unused_data)
    except (OSError, EOFError, zlib.error, lzma.LZMAError, ValueError) as e:
        raise Bad("%s: %s" % (name, e))


class Zlib:
    """zlib.decompressobj with the bz2/lzma interface"""
    def __init__(self):
        self.z = zlib.decompressobj(31)
        self.needs_input = True

    @property
    def eof(self):
        return self.z.eof

    @property
    def unused_data(self):
        return self.z.unused_data

    def decompress(self, b, n):
        r = self.z.decompress(self.z.unconsumed_tail + b, n)
        self.needs_input = not self.z.unconsumed_tail
        return r


def tool(argv, data, what):
    try:
        p = subprocess.run(argv, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        raise Bad("%s: %s is not installed" % (what, argv[0]))
    if p.returncode:
        raise Bad("%s: %s: %s" % (what, argv[0], p.stderr.decode(errors="replace").strip()))
    return p.stdout


def un_zstd(d, o, out):
    p = zstd_hdr(d, o)
    if p is None:
        raise Bad("zstd: reserved frame-header bit set")
    checksum = d[o + 4] & 0x04
    while True:
        if p + 3 > len(d):
            raise Bad("zstd frame ends early (truncated)")
        h = int.from_bytes(d[p:p + 3], "little")
        kind, size = (h >> 1) & 3, h >> 3
        if kind == 3 or size > 128 << 10:
            raise Bad("zstd: bad block header at %d" % p)
        p += 3 + (1 if kind == 1 else size)
        if h & 1:
            break
    p += 4 if checksum else 0
    if p > len(d):
        raise Bad("zstd frame ends early (truncated)")
    s = Sink(out)
    try:
        s.write(tool(["zstd", "-dcq"], d[o:p], "zstd"))
    finally:
        s.close()
    return p


def un_lz4(d, o, out):
    """legacy frames: <size><block>... with no end mark. The stream ends at a
    block that decodes to less than 8 MiB, or at a size no block can have."""
    s = Sink(out)
    try:
        p, first = o + 4, True
        while p + 4 <= len(d):
            n = struct.unpack("<I", d[p:p + 4])[0]
            if n == 0 or n > LZ4_BOUND or d[p:p + 4] == LZ4_MAGIC:
                if first:
                    raise Bad("lz4: empty legacy stream")
                break
            if p + 4 + n > len(d):
                raise Bad("lz4 block ends early (truncated)")
            b = tool(["lz4", "-dcq"], LZ4_MAGIC + d[p:p + 4 + n], "lz4")
            s.write(b)
            p += 4 + n
            first = False
            if len(b) < LZ4_BLOCK:
                break
        if first:
            raise Bad("lz4 stream ends early (truncated)")
    finally:
        s.close()
    return p


def un_lzo(d, o, out):
    # not delimited here: lzop must accept the rest of the file as is
    s = Sink(out)
    try:
        s.write(tool(["lzop", "-dc"], d[o:], "lzo"))
    finally:
        s.close()
    return len(d)


def safe_path(root, name):
    """root-relative path of an archive member, or Bad; never through a link"""
    parts = [x for x in name.split("/") if x not in ("", ".")]
    if not parts:
        return None
    if ".." in parts:
        raise Bad("cpio member %r leaves the archive" % name)
    p = root
    for x in parts[:-1]:
        p = os.path.join(p, x)
        if os.path.islink(p) or (os.path.exists(p) and not os.path.isdir(p)):
            raise Bad("cpio member %r goes through a non-directory" % name)
        os.makedirs(p, exist_ok=True)
    p = os.path.join(p, parts[-1])
    if os.path.islink(p) or os.path.isdir(p):
        raise Bad("cpio member %r would replace %s" % (name, "a link" if os.path.islink(p) else "a directory"))
    return p


def cpio_walk(d, o, member=None):
    """the end of the archive at <o>; each member goes to member(name, mode,
    data offset, data end)"""
    while True:
        try:
            if d[o:o + 6] == b"070707":
                h = d[o:o + 76].decode("ascii")
                if len(h) < 76:
                    raise ValueError
                mode, nlen, size = int(h[18:24], 8), int(h[59:65], 8), int(h[65:76], 8)
                name_at, pad = o + 76, 1
            elif d[o:o + 6] in (b"070701", b"070702"):
                h = d[o:o + 110].decode("ascii")
                if len(h) < 110:
                    raise ValueError
                mode, size, nlen = int(h[14:22], 16), int(h[54:62], 16), int(h[94:102], 16)
                name_at, pad = o + 110, 4
            else:
                raise Bad("cpio: no header at %d (truncated or corrupt)" % o)
        except ValueError:
            raise Bad("cpio: bad header at %d" % o)
        if nlen == 0:
            raise Bad("cpio: empty name at %d" % o)
        e = name_at + nlen
        e += -e % pad
        name = d[name_at:name_at + nlen - 1].decode("utf-8", "surrogateescape")
        data_end = e + size
        if data_end > len(d):
            raise Bad("cpio member %r ends early (truncated)" % name)
        o = data_end + -data_end % pad
        if name == "TRAILER!!!":
            return o
        if member:
            member(name, mode, e, data_end)


def un_cpio(d, o, out):
    """unpacks to <out>; returns the end and, in RANGES, the data range of each
    regular member written out (only those bytes are unpacked and scanned)"""
    os.makedirs(out)
    RANGES.clear()

    def member(name, mode, e, data_end):
        p = safe_path(out, name)
        if p is None:
            if data_end > e:
                raise Bad("cpio member %r has no name but carries data" % name)
            return
        if stat.S_ISLNK(mode):
            os.symlink(d[e:data_end].decode("utf-8", "surrogateescape"), p)
        elif stat.S_ISREG(mode):
            # hard links: an earlier link is empty and a later one carries the
            # data. Data never replaces data: a second member with the same
            # path is written next to the first, so both are scanned.
            if os.path.exists(p) and (data_end == e or os.path.getsize(p)):
                if data_end == e:
                    return
                n = 1
                while os.path.lexists("%s.dup%d" % (p, n)):
                    n += 1
                p = "%s.dup%d" % (p, n)
            with open(p, "wb") as f:
                f.write(d[e:data_end])
            if data_end > e:
                RANGES.append((e, data_end))
        elif data_end > e:
            # directories, devices, fifos and sockets carry no data
            raise Bad("cpio member %r is not a regular file but carries %d bytes" % (name, data_end - e))
        elif stat.S_ISDIR(mode):
            os.makedirs(p, exist_ok=True)
    return cpio_walk(d, o, member)


RANGES = []


def un_ubi(d, o, out):
    """volumes of an ubinize image, each as vol<id> (static ones trimmed to
    their data size); the PEB size is the stride of the EC headers"""
    peb = next((s for s in (1 << n for n in range(14, 22))
                if len(d) % s == 0 and all(d[i:i + 4] == b"UBI#" for i in range(0, len(d), s))), None)
    if peb is None:
        raise Bad("ubi: no PEB size from 16 KiB to 2 MiB fits the EC headers")
    vols, need = {}, {}
    for i in range(0, len(d), peb):
        vid_off, data_off = struct.unpack(">II", d[i + 16:i + 24])
        v = d[i + vid_off:i + vid_off + 64]
        if v[:4] != b"UBI!":
            if v.strip(b"\xff"):
                raise Bad("ubi: PEB at %d has a corrupt VID header" % i)
            continue
        vol, lnum, size, used, pad = struct.unpack(">II4xIII", v[8:32])
        if v[5] not in (1, 2) or data_off + pad > peb:
            raise Bad("ubi: PEB at %d: bad VID header" % i)
        leb = d[i + data_off:i + peb - pad]
        if v[5] == 2:
            if size > len(leb):
                raise Bad("ubi: PEB at %d: data size over the LEB" % i)
            leb = leb[:size]
        if lnum in vols.setdefault(vol, {}):
            raise Bad("ubi: volume %d has two copies of LEB %d" % (vol, lnum))
        vols[vol][lnum] = leb
        # a static volume says how many LEBs it has
        need[vol] = max(need.get(vol, 0), used if v[5] == 2 else lnum + 1)
    os.makedirs(out)
    for vol, lebs in vols.items():
        with open(os.path.join(out, "vol%d" % vol), "wb") as f:
            for n in range(max(need[vol], max(lebs) + 1)):
                if n not in lebs:
                    raise Bad("ubi: volume %d has no LEB %d" % (vol, n))
                f.write(lebs[n])
    return len(d)


DECODERS = {
    "gzip": un_gzip,
    "gzip-lax": lambda d, o, out: un_gzip_lax(d, o, out, False),
    "gzip-kernel": lambda d, o, out: un_gzip_lax(d, o, out, True),
    "xz": lambda d, o, out: py_stream(lzma.LZMADecompressor(lzma.FORMAT_XZ), d, o, out, "xz"),
    "lzma": lambda d, o, out: py_stream(lzma.LZMADecompressor(lzma.FORMAT_ALONE), d, o, out, "lzma"),
    "bzip2": lambda d, o, out: py_stream(bz2.BZ2Decompressor(), d, o, out, "bzip2"),
    "zstd": un_zstd, "lz4": un_lz4, "lzo": un_lzo, "cpio": un_cpio, "ubi": un_ubi,
}


def unpack(fmt, path, o, out):
    """unpacks one stream; returns the offset where it ends"""
    if fmt not in DECODERS:
        raise Bad("unknown format %s" % fmt)
    with open(path, "rb") as fh:
        return DECODERS[fmt](mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ), o, out)


def main(a):
    try:
        if len(a) == 2 and a[0] == "scan":
            for name, o in scan(a[1]):
                print(name, o)
        elif len(a) == 5 and a[0] == "unpack":
            RANGES.clear()
            print(unpack(a[1], a[2], int(a[3]), a[4]))
            for r in RANGES:
                print(*r)
        else:
            sys.exit(__doc__)
    except Bad as e:
        sys.exit("%s @%s: %s" % (a[2], a[3], e))
    except OSError as e:
        sys.exit("%s: %s" % (a[-1], e))


if __name__ == "__main__":
    main(sys.argv[1:])
