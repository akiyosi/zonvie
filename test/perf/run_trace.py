#!/usr/bin/env python3
"""Capture a frame trace from the real zonvie app during a continuous scroll.

Launches a headless nvim plus the real app attached over --connect-nvim, then
drives the scroll from a timer *inside* nvim. Driving it there means no process
spawn per key and no OS key-repeat jitter enters the measurement, so what is
left is the rendering pipeline itself.

The app must be built with the FrameTracer instrumentation (it is always
compiled in; `ZONVIE_TRACE=1` arms it). On SIGUSR1 the app dumps its ring
buffer to CSV, which analyze.py and drops.py read.

Usage:
    test/perf/run_trace.py <buffer|atlas|tig> [seconds] [out.csv] [producer_ms]

Environment:
    ZONVIE_TRACE_CONFIG     Debug (default) or Release. Release is the honest
                            configuration: its faster draw() loses the commit
                            race more often, so Debug understates the problem.
    ZONVIE_COMMIT_GUARD_US  Guard-band override passed through to the app.
                            Unset measures the shipped default; 0 disables it,
                            which is how you A/B the fix.
    ZONVIE_NVIM             nvim binary (default: first on PATH).
    ZONVIE_APP              app binary (default: the derived-data build).
    ZONVIE_TRACE_COMMIT     commit for the tig scenario (default: the largest
                            diff among recent history, so the scroll has
                            enough content to run for the whole capture).
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WORK = REPO / "tmp" / "scrollperf"
SOCK = WORK / "nvim.sock"
CFGHOME = WORK / "xdg"


def nvim_bin():
    return os.environ.get("ZONVIE_NVIM") or shutil.which("nvim") or "nvim"


def app_bin():
    if "ZONVIE_APP" in os.environ:
        return os.environ["ZONVIE_APP"]
    config = os.environ.get("ZONVIE_TRACE_CONFIG", "Debug")
    return str(REPO / "macos" / ".derived" / "Build" / "Products" / config
               / "zonvie.app" / "Contents" / "MacOS" / "zonvie")


def biggest_recent_commit():
    """Commit with the most changed lines in recent history.

    A tiny diff would let the tig scroll hit the end of the buffer partway
    through the capture, which shows up as a long idle tail in the trace.
    """
    if "ZONVIE_TRACE_COMMIT" in os.environ:
        return os.environ["ZONVIE_TRACE_COMMIT"]
    out = subprocess.run(
        ["git", "-C", str(REPO), "log", "--format=%h", "--shortstat",
         "-60", "--no-merges"],
        capture_output=True, text=True).stdout
    best, best_n, cur = "HEAD", -1, None
    for line in out.splitlines():
        line = line.strip()
        if re.fullmatch(r"[0-9a-f]{7,40}", line):
            cur = line
        elif "changed" in line and cur:
            n = sum(int(x) for x in re.findall(r"(\d+) (?:insertion|deletion)", line))
            if n > best_n:
                best, best_n = cur, n
    return best


def remote_expr(expr):
    return subprocess.run(
        [nvim_bin(), "--server", str(SOCK), "--remote-expr", expr],
        capture_output=True, text=True, timeout=20)


def main():
    scenario = sys.argv[1] if len(sys.argv) > 1 else "buffer"
    if scenario not in ("buffer", "atlas", "tig"):
        sys.exit(f"unknown scenario: {scenario} (expected buffer, atlas, or tig)")
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 15.0
    out = sys.argv[3] if len(sys.argv) > 3 else str(WORK / "trace.csv")
    # Producer period in ms. The display consumes at 60Hz; driving the producer
    # much faster (e.g. 6) removes any content-arrival phase relationship,
    # which discriminates "frame dropped because content missed the vsync"
    # from "frame dropped by the compositor".
    period = int(sys.argv[4]) if len(sys.argv) > 4 else 16

    app = app_bin()
    if not os.path.exists(app):
        sys.exit(f"app binary not found: {app}\nBuild it first (see DEVELOPMENT.md).")

    WORK.mkdir(parents=True, exist_ok=True)
    CFGHOME.mkdir(parents=True, exist_ok=True)
    for p in (SOCK, Path(out)):
        if p.exists():
            p.unlink()

    # A real, long, syntax-highlighted source file: representative per-row
    # shaping and highlight work, unlike a synthetic plain-text buffer.
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
        # Isolate config so an ambient ~/.config/zonvie/config.toml cannot
        # force the string-formatting logger on and pollute the timings.
        "XDG_CONFIG_HOME": str(CFGHOME),
    })
    app_proc = subprocess.Popen([app, f"--connect-nvim={SOCK}"], env=env)

    # Let the UI attach, size itself and settle.
    time.sleep(5)

    if scenario == "atlas":
        # Keep every visible row full through the right edge while exceeding
        # the fixed non-ASCII glyph cache working set. Sparse scrolling should
        # shape/rasterize only the entering row; a begin-abort recovery that
        # spuriously marks the full viewport dirty churns the cache and misses
        # the 60 Hz frame budget.
        setup_lua = (
            "(function() local lines = {}; "
            "for row = 0, 3999 do local chars = {}; "
            "for col = 0, 159 do "
            "chars[#chars + 1] = vim.fn.nr2char("
            "0x4E00 + ((row * 160 + col) % 20902)); "
            "end; lines[#lines + 1] = table.concat(chars); end; "
            "vim.api.nvim_buf_set_lines(0, 0, -1, false, lines); "
            "vim.api.nvim_win_set_cursor(0, {1, 0}); "
            "vim.opt_local.wrap = false; "
            "vim.cmd('syntax off'); return 1 end)()"
        )
        r = remote_expr(f'luaeval("{setup_lua}")')
        if r.returncode != 0:
            print("failed to create atlas stress buffer:", r.stderr, file=sys.stderr)
            app_proc.terminate()
            nvim_proc.terminate()
            return 1
        # Exclude initial full-viewport glyph population from the continuous
        # scroll window selected by the checker.
        time.sleep(4)

    if scenario == "tig":
        commit = biggest_recent_commit()
        remote_expr(f"execute('terminal cd {REPO} && tig show {commit}')")
        time.sleep(4)
        # luaeval takes an expression, so the timer handle is discarded; the
        # harness tears the whole nvim down at the end anyway.
        lua = (f"vim.fn.timer_start({period}, function() "
               "local c = vim.b.terminal_job_id; "
               "if c then vim.fn.chansend(c, 'j') end end, "
               "{['repeat'] = -1})")
    else:
        lua = (f"vim.fn.timer_start({period}, function() "
               "vim.api.nvim_feedkeys('j', 'n', false) end, "
               "{['repeat'] = -1})")

    r = remote_expr(f'luaeval("{lua}")')
    if r.returncode != 0:
        print("failed to start the scroll timer:", r.stderr, file=sys.stderr)

    time.sleep(secs)

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

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
