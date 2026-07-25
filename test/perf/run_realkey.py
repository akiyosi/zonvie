#!/usr/bin/env python3
"""Capture a frame trace while a real key repeat drives the scroll.

run_trace.py drives nvim directly, so the app's own key-repeat synthesis never
engages: the repeat cadence, and the phase between a send and the frame that
consumes it, are not measurable from it. That gap used to be closed by hand —
launch the app, hold `j`, signal it — which made every input-side number
depend on someone being at the keyboard.

This posts the hold instead (see holdkey.swift): one keyDown, one autorepeat
keyDown to trigger the takeover, then a keyUp at the end. Between those the
app runs its own synthesis at production cadence.

Usage:
    test/perf/run_realkey.py [seconds] [out.csv] [keycode]

    ZONVIE_SMOOTH_SCROLL=1 ZONVIE_TRACE_CONFIG=Release \\
      test/perf/run_realkey.py 15 tmp/scrollperf/rk.csv

Needs Accessibility permission. macOS attributes it to the process
*responsible* for the driver — the GUI app at the top of this shell's process
tree, not the driver binary. The driver prints what it sees
(`accessibility-trusted=`); without the grant it refuses to post rather than
producing a capture with no scrolling in it.
"""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_trace import app_bin, nvim_bin, REPO, WORK, SOCK, CFGHOME  # noqa: E402

KEY_J = 38


def build_driver():
    src = REPO / "test" / "perf" / "holdkey.swift"
    exe = REPO / "tmp" / "holdkey"
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        exe.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(src), "-o", str(exe)], check=True)
    return exe


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 15.0
    out = sys.argv[2] if len(sys.argv) > 2 else str(WORK / "realkey.csv")
    key = int(sys.argv[3]) if len(sys.argv) > 3 else KEY_J

    app = app_bin()
    if not os.path.exists(app):
        sys.exit(f"app binary not found: {app}\nBuild it first (see DEVELOPMENT.md).")
    driver = build_driver()

    WORK.mkdir(parents=True, exist_ok=True)
    CFGHOME.mkdir(parents=True, exist_ok=True)
    for p in (SOCK, Path(out)):
        if p.exists():
            p.unlink()

    target = REPO / "src" / "core" / "flush.zig"
    nvim_proc = subprocess.Popen(
        [nvim_bin(), "--headless", "--listen", str(SOCK), "-u", "NONE",
         "--cmd", "syntax on", "--cmd", "set termguicolors number", str(target)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    for _ in range(100):
        if SOCK.exists():
            break
        time.sleep(0.1)
    else:
        nvim_proc.kill()
        sys.exit("nvim socket never appeared")

    env = dict(os.environ)
    env.update({
        "ZONVIE_TRACE": "1",
        "ZONVIE_TRACE_PATH": out,
        "XDG_CONFIG_HOME": str(CFGHOME),
    })
    app_proc = subprocess.Popen([app, f"--connect-nvim={SOCK}"], env=env)

    time.sleep(5)

    held = subprocess.run([str(driver), str(app_proc.pid), str(key), str(secs)],
                          capture_output=True, text=True)
    # Always surface the driver's report: "no scrolling in the capture" and
    # "the events were dropped for lack of permission" look identical from the
    # trace alone.
    if held.stderr.strip():
        print(held.stderr.strip(), file=sys.stderr)
    if held.returncode != 0:
        print(f"hold driver failed (exit {held.returncode})", file=sys.stderr)

    app_proc.send_signal(signal.SIGUSR1)
    time.sleep(2)

    for proc in (app_proc, nvim_proc):
        proc.terminate()
    for proc in (app_proc, nvim_proc):
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    if os.path.exists(out):
        with open(out) as f:
            n = sum(1 for _ in f)
        print(f"trace written: {out} ({n} lines)")
    else:
        sys.exit("NO TRACE PRODUCED")


if __name__ == "__main__":
    main()
