#!/usr/bin/env python3
"""Host check for global-patches/mpd 0005 + 0006 (queue loss on a stale db).
Run via test_mpd_stale_db.sh.  usage: mpd_stale_db.py <mpd> <workdir> <some.flac>"""
import os, sys, socket, subprocess, time, shutil, signal

MPD, W, SRC = sys.argv[1], sys.argv[2], sys.argv[3]
MUSIC, SOCK, DB, STATE = f"{W}/music", f"{W}/sock", f"{W}/db", f"{W}/state"
NDIR, NPER = 40, 100
DELAY = float(os.environ.get("DELAY", "0"))   # s between update and SIGTERM

def conf():
    with open(f"{W}/mpd.conf", "w") as f:
        f.write(f'music_directory "{MUSIC}"\ndb_file "{DB}"\nstate_file "{STATE}"\n'
                f'pid_file "{W}/pid"\nbind_to_address "{SOCK}"\nlog_file "{W}/log"\n'
                f'auto_update "no"\nrestore_paused "no"\n'
                'audio_output {\n type "null"\n name "n"\n}\n')

def cmd(c):
    s = socket.socket(socket.AF_UNIX); s.connect(SOCK); f = s.makefile("rwb")
    f.readline(); f.write((c + "\n").encode()); f.flush(); out = {}
    lines = []
    while True:
        l = f.readline().decode().rstrip("\n")
        if l == "OK" or l.startswith("ACK"): break
        lines.append(l)
    s.close(); return lines

def kv(lines):
    return dict(l.split(": ", 1) for l in lines if ": " in l)

def start():
    p = subprocess.Popen([MPD, "--no-daemon", f"{W}/mpd.conf"])
    for _ in range(200):
        try: cmd("ping"); return p
        except OSError: time.sleep(0.02)
    raise SystemExit("mpd did not start")

def stop(p, sig=signal.SIGTERM):
    p.send_signal(sig); p.wait(timeout=60)

def wait_update():
    while "updating_db" in kv(cmd("status")): time.sleep(0.05)

def songs(): return int(kv(cmd("stats"))["songs"])
def qlen(): return int(kv(cmd("status"))["playlistlength"])

def setup():
    shutil.rmtree(W, ignore_errors=True); os.makedirs(MUSIC)
    for d in range(NDIR):
        os.makedirs(f"{MUSIC}/d{d:02}")
        for i in range(NPER): os.link(SRC, f"{MUSIC}/d{d:02}/t{i:03}.flac")
    conf()

def test_cancel():
    """an update cancelled by SIGTERM (mpd-persist/Extras/USB killall) must not shrink the saved db"""
    setup(); p = start(); wait_update(); full = songs(); stop(p)
    os.utime(SRC)                 # all links share the inode -> every song looks modified
    p = start(); cmd("update"); time.sleep(DELAY)
    running = "updating_db" in kv(cmd("status")); stop(p)
    print(f"cancel: update still running at SIGTERM: {running}")
    if not running: return None
    p = start(); after = songs()
    shutil.rmtree(f"{MUSIC}/d05")                    # the next complete update still purges
    cmd("update"); wait_update(); later = songs(); stop(p)
    print(f"cancel: db songs before={full} after cancelled update={after} after next full update (-100)={later}")
    return after == full and later == full - NPER

def test_stale_db():
    """a queued song missing from a stale db must survive the state-file restore"""
    setup(); p = start(); wait_update()
    cmd("add d00"); cmd("add d39"); cmd("play 150"); time.sleep(0.3); cmd("pause 1")
    want = qlen(); stop(p); shutil.copy(STATE, f"{W}/state.keep")
    shutil.move(f"{MUSIC}/d39", f"{W}/d39")          # card edit 'while off' in reverse:
    p = start(); cmd("update"); wait_update(); stop(p) # db now lacks d39 (stale vs the card)
    shutil.move(f"{W}/d39", f"{MUSIC}/d39"); shutil.copy(f"{W}/state.keep", STATE)
    os.unlink(f"{MUSIC}/d39/t099.flac")              # a file really gone from the card: still dropped
    want -= 1
    p = start(); st = kv(cmd("status")); got = qlen(); db = songs()
    cur = kv(cmd("currentsong")).get("file"); stop(p)
    print(f"stale-db: db songs={db} queue want={want} got={got} song={st.get('song')} cur={cur} elapsed={st.get('elapsed')} state={st.get('state')}")
    return got == want and cur == "d39/t050.flac" and float(st.get("elapsed", 0)) > 0

r1 = test_cancel()
if r1 is None: raise SystemExit("cancel test inconclusive: update finished before SIGTERM, lower DELAY")
r2 = test_stale_db()
print("RESULT cancel:", "PASS" if r1 else "FAIL", " stale-db:", "PASS" if r2 else "FAIL")
sys.exit(0 if r1 and r2 else 1)
