#!/usr/bin/env python3
"""Host check for package/erosq-splash. Run via test_erosq_splash.sh.

  erosq_splash_check.py errors <runner...> <bin>
      Error and default-path behaviour of any build (host, or a target build
      under qemu-mipsel-static): exit codes and messages for a missing image,
      a short image, a missing /dev/dri/card0 and a card0 that is not DRM, and
      that with no argument it reads /etc/splash.raw. Re-runs itself in a user
      + mount namespace (unshare -rm) with private /etc and /dev/dri.
  erosq_splash_check.py fakedrm <shim.so> <host-bin>
      The full modeset path of a HOST build against the LD_PRELOAD fake DRM
      device: exact ioctl sequence and arguments, and the image rows landing
      in the dumb buffer at its pitch."""
import os, subprocess, sys, tempfile

W, H, PITCH = 320, 240, 704
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else ": " + detail))
    fails += not cond


def image():
    # distinct per-row/column pattern, little-endian RGB565
    return b"".join(((x * 7 + y * 131) & 0xFFFF).to_bytes(2, "little")
                    for y in range(H) for x in range(W))


def run(cmd, timeout=20):
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode(), p.stderr.decode()


def errors(cmd):
    t = tempfile.mkdtemp(prefix="splash-")
    good = os.path.join(t, "good.raw")
    short = os.path.join(t, "short.raw")
    open(good, "wb").write(image())
    open(short, "wb").write(image()[:1000])
    etc = os.path.join(t, "etc")
    dri = os.path.join(t, "dri")
    os.mkdir(etc)
    os.mkdir(dri)
    # private /etc (for the default image) and /dev/dri (for card0)
    subprocess.run(["mount", "--bind", etc, "/etc"], check=True)
    if not os.path.isdir("/dev/dri"):
        # no mount point to bind over: put a private tmpfs on /dev instead
        subprocess.run(["mount", "-t", "tmpfs", "tmpfs", "/dev"], check=True)
        os.mkdir("/dev/dri")
    subprocess.run(["mount", "--bind", dri, "/dev/dri"], check=True)

    rc, out, err = run(cmd + [os.path.join(t, "missing.raw")])
    check("missing image: exit 1", rc == 1, str(rc))
    check("missing image: message", err == "open splash: No such file or directory\n", repr(err))
    check("missing image: no stdout", out == "", repr(out))

    rc, out, err = run(cmd + [short])
    check("short image: exit 1", rc == 1, str(rc))
    check("short image: message", err == "short splash\n", repr(err))

    rc, out, err = run(cmd + [good])
    check("no card0: exit 1", rc == 1, str(rc))
    check("no card0: message", err == "open card0: No such file or directory\n", repr(err))

    rc, out, err = run(cmd)
    check("default path, none in /etc: exit 1", rc == 1, str(rc))
    check("default path, none in /etc: message",
          err == "open splash: No such file or directory\n", repr(err))

    open("/etc/splash.raw", "wb").write(image())
    rc, out, err = run(cmd)
    check("default path reads /etc/splash.raw: gets to card0", rc == 1 and
          err == "open card0: No such file or directory\n", f"{rc} {err!r}")

    open("/dev/dri/card0", "wb").close()  # exists but is not a DRM device
    rc, out, err = run(cmd + [good])
    check("non-DRM card0: exit 1", rc == 1, str(rc))
    # the strerror text is libc-specific (glibc vs musl); the prefix is ours
    check("non-DRM card0: getres0 message", err.startswith("getres0: ") and
          err.count("\n") == 1, repr(err))


def fakedrm(shim, binary):
    t = tempfile.mkdtemp(prefix="splash-")
    good = os.path.join(t, "good.raw")
    img = image()
    open(good, "wb").write(img)
    env = dict(os.environ, LD_PRELOAD=shim,
               FAKEDRM_LOG=os.path.join(t, "log"), FAKEDRM_FB=os.path.join(t, "fb"))
    p = subprocess.run([binary, good], capture_output=True, env=env, timeout=20)
    check("fakedrm: reaches the hold (pause)", p.returncode == 42,
          f"{p.returncode} {p.stderr!r}")
    check("fakedrm: stdout", p.stdout == b"splash up\n", repr(p.stdout))
    check("fakedrm: no stderr", p.stderr == b"", repr(p.stderr))
    want = [
        "open card0 flags=RDWR|CLOEXEC",
        "GETRESOURCES count",
        "GETRESOURCES fill caps=8,8,8,8",
        "GETCONNECTOR id=31 modes_ptr=0",
        "GETCONNECTOR id=31 modes_ptr=set",
        "CREATE_DUMB 320x240 bpp=16",
        f"ADDFB 320x240 bpp=16 depth=16 pitch={PITCH} handle=7",
        "MAP_DUMB handle=7",
        f"mmap len={PITCH * H} prot=RW shared=1 off=0x10000",
        "SETCRTC crtc=41 fb=55 conn=31 count=1 valid=1 mode=320x240 320x240",
        "pause",
    ]
    got = open(env["FAKEDRM_LOG"]).read().splitlines()
    check("fakedrm: ioctl sequence", got == want, "\n  " + "\n  ".join(got))
    fb = open(env["FAKEDRM_FB"], "rb").read()
    rows_ok = all(fb[y * PITCH:y * PITCH + W * 2] == img[y * W * 2:(y + 1) * W * 2]
                  for y in range(H))
    pad_ok = all(fb[y * PITCH + W * 2:(y + 1) * PITCH] == bytes(PITCH - W * 2)
                 for y in range(H))
    check("fakedrm: rows copied at pitch", rows_ok)
    check("fakedrm: pitch padding untouched", pad_ok)


if __name__ == "__main__":
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "errors":
        if os.environ.get("SPLASH_NS") != "1":
            env = dict(os.environ, SPLASH_NS="1")
            sys.exit(subprocess.run(["unshare", "-rm", sys.executable, "-I",
                                     os.path.abspath(__file__)] + sys.argv[1:],
                                    env=env).returncode)
        errors([os.path.abspath(a) if os.path.exists(a) else a for a in args])
    elif mode == "fakedrm":
        fakedrm(*args)
    else:
        sys.exit("usage: see docstring")
    print("OK" if not fails else f"{fails} FAILED")
    sys.exit(1 if fails else 0)
