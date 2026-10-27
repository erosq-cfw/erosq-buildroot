#!/usr/bin/env python3
"""Host check for package/mpdctl: run an mpdctl binary against a fake MPD
Unix-socket server and assert on the exact bytes it sends and prints.
Run via test_mpdctl.sh.  usage: mpdctl_check.py <runner...> <mpdctl>
(e.g. "qemu-mipsel-static ./mpdctl" for a target build).
The default-socket case needs /run writable, so the script re-runs itself
in a user+mount namespace (unshare -rm) with a tmpfs over /run."""
import os, sys, socket, subprocess, tempfile, threading

CMD = sys.argv[1:]
GREETING = b"OK MPD 0.24.0\n"
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else ": " + detail))
    fails += not cond


def serve(path, reply):
    """Accept one client: send the greeting, read until "close\\n", then send
    `reply` in small chunks and hang up. Returns a dict filled with the bytes
    the client sent."""
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)
    got = {"rx": b""}

    def run():
        c, _ = srv.accept()
        c.sendall(GREETING)
        while not got["rx"].endswith(b"close\n"):
            d = c.recv(65536)
            if not d:
                break
            got["rx"] += d
        for i in range(0, len(reply), 1000):   # many short writes: exercises the read loop
            c.sendall(reply[i:i + 1000])
        c.close()
        srv.close()

    t = threading.Thread(target=run, daemon=True)
    t.start()
    got["thread"] = t
    return got


def run(args, env_sock):
    env = dict(os.environ)
    env.pop("MPD_HOST_SOCK", None)
    if env_sock is not None:
        env["MPD_HOST_SOCK"] = env_sock
    return subprocess.run(CMD + args, env=env, capture_output=True, timeout=20)


def case(name, sock, args, reply, use_env=True):
    got = serve(sock, reply)
    p = run(args, sock if use_env else None)
    got["thread"].join(5)
    want_tx = b"".join(a.encode() + b"\n" for a in args) + b"close\n"
    check(name + ": bytes sent", got["rx"] == want_tx, f"{got['rx']!r} != {want_tx!r}")
    check(name + ": stdout", p.stdout == GREETING + reply,
          f"{len(p.stdout)} B, starts {p.stdout[:60]!r}")
    check(name + ": exit 0, no stderr", p.returncode == 0 and p.stderr == b"",
          f"rc={p.returncode} stderr={p.stderr!r}")


def main():
    if os.environ.get("MPDCTL_CHECK_NS") != "1":   # never mount over the host's own /run
        os.environ["MPDCTL_CHECK_NS"] = "1"
        os.execvp("unshare", ["unshare", "-rm", sys.executable, "-I", __file__] + CMD)
    subprocess.run(["mount", "-t", "tmpfs", "mpdctl-test", "/run"], check=True)
    d = tempfile.mkdtemp()
    s = os.path.join(d, "mpd.sock")

    case("two commands", s, ["status", "currentsong"],
         b"volume: 40\nstate: play\nOK\nfile: a.flac\nOK\n")
    os.unlink(s)
    case("arg with spaces is one command line", s, ['playid "7"'], b"OK\n")
    os.unlink(s)
    case("no arguments sends only close", s, [], b"")
    os.unlink(s)
    big = b"".join(b"file: dir/track%05d.flac\n" % i for i in range(1500)) + b"OK\n"
    case("reply larger than one 4096 B read", s, ["playlistinfo"], big)
    os.unlink(s)
    case("ACK reply still exit 0", s, ["bogus"], b"ACK [5@0] {} unknown command \"bogus\"\n")
    case("MPD_HOST_SOCK unset uses /run/mpd.sock", "/run/mpd.sock", ["stop"], b"OK\n",
         use_env=False)

    p = run(["stop"], os.path.join(d, "missing.sock"))
    check("missing socket: exit 1, no stdout", p.returncode == 1 and p.stdout == b"",
          f"rc={p.returncode} stdout={p.stdout!r}")
    check("missing socket: perror(\"connect\")",
          p.stderr == b"connect: No such file or directory\n", repr(p.stderr))

    print(f"{'FAILED' if fails else 'OK'}: {fails} failure(s)")
    sys.exit(1 if fails else 0)


main()
