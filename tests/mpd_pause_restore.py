#!/usr/bin/env python3
"""Host check for global-patches/mpd 0008: a "state: pause" restore must come
back at exactly the saved elapsed time, with no audio played in between.
Unpatched MPD restores a paused song by seeking + PLAYING it, then pausing,
so every restore adds the audio the output consumed in between (2:04 -> 2:05
on the device, je2d TEST-PLAN 5.1). Repeated power cycles accumulate it.
Run via test_mpd_pause_restore.sh.  usage: mpd_pause_restore.py <mpd> <workdir> <some.flac>"""
import os, sys, socket, subprocess, time, shutil, signal

MPD, W, SRC = sys.argv[1], sys.argv[2], sys.argv[3]
MUSIC, SOCK, DB, STATE = f"{W}/music", f"{W}/sock", f"{W}/db", f"{W}/state"
CYCLES = 30
TOL = 0.010   # s: the saved value is printed with %g-ish precision

def conf(sync):
    # setup: a "sync" null output consumes audio in real time.  Restores:
    # sync "no" consumes whatever reaches it at once, like ALSA filling its
    # ~0.5 s hardware buffer (exaggerated: any audio played shows as drift)
    with open(f"{W}/mpd.conf", "w") as f:
        f.write(f'music_directory "{MUSIC}"\ndb_file "{DB}"\nstate_file "{STATE}"\n'
                f'pid_file "{W}/pid"\nbind_to_address "{SOCK}"\nlog_file "{W}/log"\n'
                f'auto_update "no"\nrestore_paused "no"\n'
                f'audio_output {{\n type "null"\n name "n"\n  sync "{sync}"\n}}\n')

def cmd(c):
    s = socket.socket(socket.AF_UNIX); s.connect(SOCK); f = s.makefile("rwb")
    f.readline(); f.write((c + "\n").encode()); f.flush(); lines = []
    while True:
        l = f.readline().decode().rstrip("\n")
        if l == "OK" or l.startswith("ACK"): break
        lines.append(l)
    s.close(); return lines

def kv(lines): return dict(l.split(": ", 1) for l in lines if ": " in l)

def start():
    p = subprocess.Popen(["taskset", "-c", "0", MPD, "--no-daemon", f"{W}/mpd.conf"])
    for _ in range(200):
        try: cmd("ping"); return p
        except OSError: time.sleep(0.02)
    raise SystemExit("mpd did not start")

def stop(p): p.send_signal(signal.SIGTERM); p.wait(timeout=60)

def saved_time():
    for l in open(STATE):
        if l.startswith("time: "): return float(l[6:])
    return None

shutil.rmtree(W, ignore_errors=True); os.makedirs(MUSIC)
os.link(SRC, f"{MUSIC}/a.flac"); os.link(SRC, f"{MUSIC}/b.flac"); conf("yes")
p = start(); cmd("update")
while "updating_db" in kv(cmd("status")): time.sleep(0.05)
cmd("add a.flac"); cmd("add b.flac")
dur = float(kv(cmd("currentsong") or cmd("playlistinfo 1")).get("duration", "0") or 0)
cmd("play 1"); time.sleep(0.2)
want = min(4.4, max(dur - 1.0, 0.5))          # an x.4 s point: +0.1 s already flips RoundS
cmd(f"seekcur {want}"); cmd("pause 1"); time.sleep(0.3)
st = kv(cmd("status")); stop(p)
want = saved_time()
print(f"setup: song dur={dur:.2f} paused elapsed={st.get('elapsed')} saved time={want}")
ok = want is not None and st.get("state") == "pause"
if not ok: raise SystemExit("setup failed: no paused state saved")
conf("no")
worst = 0.0
for i in range(CYCLES):
    p = start(); time.sleep(0.5)                 # give a playing restore time to run
    st = kv(cmd("status")); stop(p); t = saved_time()
    el = float(st.get("elapsed", "nan"))
    worst = max(worst, abs(el - want), abs((t or 0) - want))
    print(f"cycle {i}: state={st.get('state')} song={st.get('song')} elapsed={el:.3f} time={st.get('time')} saved={t}")
    ok &= st.get("state") == "pause" and st.get("song") == "1"
# Play must still resume from there (outputs open on unpause)
conf("yes"); p = start(); cmd("pause 0"); time.sleep(0.5); st = kv(cmd("status")); cmd("pause 1"); stop(p)
el = float(st.get("elapsed", "nan"))
print(f"unpause: state={st.get('state')} elapsed={el:.3f} (want > {want})")
ok &= st.get("state") == "play" and el > want + 0.05
print(f"worst drift over {CYCLES} restores: {worst:.3f} s (tolerance {TOL})")
ok &= worst <= TOL
print("RESULT pause-restore:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
