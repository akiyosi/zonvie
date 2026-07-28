#!/usr/bin/env python3
"""Run or check the real-macOS-app 60 fps scroll regression test.

The test drives a full-width, high-cardinality CJK buffer at 60 updates/s,
then checks both the producer and consumer sides of the frame budget:

  * committed core flush p95 <= 16.67 ms
  * committed content rate >= 58 flushes/s
  * effective on-glass rate >= 58 fps
  * on-glass slips <= 1/s
  * visually stalled frames <= 10%

Usage:
    test/perf/test_60fps.py
    test/perf/test_60fps.py --seconds 20
    test/perf/test_60fps.py --trace tmp/scrollperf/existing.csv
"""

import argparse
import csv
import os
import subprocess
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
DEFAULT_TRACE = REPO / "tmp" / "scrollperf" / "60fps.csv"
FRAME_BUDGET_NS = 1_000_000_000 / 60
MIN_EFFECTIVE_FPS = 58.0
MIN_COMMITTED_FPS = 58.0
MAX_SLIPS_PER_SECOND = 1.0
MAX_VISUAL_STALL_RATIO = 0.10
MIN_ACTIVE_SECONDS = 5.0
MIN_COMMITTED_FLUSHES = 100

DRAW_BEGIN = 1
PRESENTED = 6
SCROLL_ADVANCE = 18
SMOOTH_SCROLL_OFFSET = 19
CORE_FLUSH_BEGIN = 24
CORE_FLUSH_END = 25


def percentile(values, percent):
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(len(ordered) * percent / 100))
    return ordered[index]


def read_trace(path):
    events = []
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            events.append((
                int(row["t_ns"]),
                int(row["tag"]),
                int(row["seq"]),
                int(row["a"]),
                int(row["b"]),
            ))
    return events


def active_scroll_window(events):
    draws = [t for t, tag, _, _, _ in events if tag == DRAW_BEGIN]
    if len(draws) <= 10:
        raise ValueError("trace has too few draw events")

    best_start = draws[0]
    best_end = draws[0]
    run_start = draws[0]
    for index in range(1, len(draws)):
        if draws[index] - draws[index - 1] > 100_000_000:
            if draws[index - 1] - run_start > best_end - best_start:
                best_start, best_end = run_start, draws[index - 1]
            run_start = draws[index]
    if draws[-1] - run_start > best_end - best_start:
        best_start, best_end = run_start, draws[-1]

    return (
        [event for event in events if best_start <= event[0] <= best_end],
        best_start,
        best_end,
    )


def committed_flush_durations(events):
    durations = []
    begin_ns = None
    for t_ns, tag, _, aborted, _ in events:
        if tag == CORE_FLUSH_BEGIN:
            begin_ns = t_ns
        elif tag == CORE_FLUSH_END and begin_ns is not None:
            if aborted == 0:
                durations.append(t_ns - begin_ns)
            begin_ns = None
    return durations


def visual_stall_ratio(events):
    advances = [
        a if a < (1 << 63) else a - (1 << 64)
        for _, tag, _, a, _ in events
        if tag == SCROLL_ADVANCE
    ]
    signs = {1 if delta > 0 else -1 for delta in advances if delta != 0}
    if len(signs) > 1:
        return None

    sign = signs.pop() if signs else 1
    offset_px = 0.0
    row_px = 0.0
    content_px = 0.0
    previous = None
    steps = []
    for _, tag, _, a, b in events:
        if tag == SMOOTH_SCROLL_OFFSET:
            offset_px = a / 1000.0
            if b:
                row_px = b / 1000.0
        elif tag == SCROLL_ADVANCE and row_px:
            delta = a if a < (1 << 63) else a - (1 << 64)
            content_px += delta * row_px
            position = content_px - sign * offset_px
            if previous is not None:
                steps.append((position - previous) / row_px)
            previous = position

    if not steps:
        return None
    stalled = sum(1 for step in steps if abs(step) < 0.05)
    return stalled / len(steps)


def check_trace(path):
    events = read_trace(path)
    if not events:
        print(f"FAIL: empty trace: {path}", file=sys.stderr)
        return 1

    try:
        active, window_start, window_end = active_scroll_window(events)
    except ValueError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    active_seconds = (window_end - window_start) / 1e9
    flush_durations = committed_flush_durations(active)
    presented = sorted(
        a for _, tag, _, a, _ in active if tag == PRESENTED and a > 0
    )
    never_displayed = sum(
        1 for _, tag, _, a, _ in active if tag == PRESENTED and a == 0
    )

    failures = []
    if active_seconds < MIN_ACTIVE_SECONDS:
        failures.append(
            f"active window {active_seconds:.2f}s < {MIN_ACTIVE_SECONDS:.0f}s"
        )
    if len(flush_durations) < MIN_COMMITTED_FLUSHES:
        failures.append(
            f"committed flush samples {len(flush_durations)} "
            f"< {MIN_COMMITTED_FLUSHES}"
        )
    if len(presented) < 2:
        failures.append("fewer than two on-glass frames")

    flush_p50_ns = percentile(flush_durations, 50) if flush_durations else 0
    flush_p95_ns = percentile(flush_durations, 95) if flush_durations else 0
    flush_p99_ns = percentile(flush_durations, 99) if flush_durations else 0
    committed_fps = (
        len(flush_durations) / active_seconds if active_seconds > 0 else 0.0
    )
    if flush_durations and flush_p95_ns > FRAME_BUDGET_NS:
        failures.append(
            f"committed core flush p95 {flush_p95_ns / 1e6:.3f}ms "
            f"> {FRAME_BUDGET_NS / 1e6:.3f}ms"
        )
    if committed_fps < MIN_COMMITTED_FPS:
        failures.append(
            f"committed content rate {committed_fps:.2f}/s "
            f"< {MIN_COMMITTED_FPS:.2f}/s"
        )

    effective_fps = 0.0
    slips = []
    slip_rate = 0.0
    if len(presented) >= 2:
        intervals = [
            presented[index + 1] - presented[index]
            for index in range(len(presented) - 1)
        ]
        display_seconds = (presented[-1] - presented[0]) / 1e9
        if display_seconds > 0:
            effective_fps = len(intervals) / display_seconds
            slips = [
                interval
                for interval in intervals
                if interval > FRAME_BUDGET_NS * 1.5
            ]
            slip_rate = len(slips) / display_seconds
        if effective_fps < MIN_EFFECTIVE_FPS:
            failures.append(
                f"effective on-glass rate {effective_fps:.2f}fps "
                f"< {MIN_EFFECTIVE_FPS:.2f}fps"
            )
        if slip_rate > MAX_SLIPS_PER_SECOND:
            failures.append(
                f"on-glass slips {slip_rate:.3f}/s "
                f"> {MAX_SLIPS_PER_SECOND:.3f}/s"
            )

    presented_events = len(presented) + never_displayed
    if presented_events and never_displayed / presented_events > 0.01:
        failures.append(
            f"{never_displayed}/{presented_events} frames were never displayed; "
            "keep the test window visible and unobscured"
        )

    stall_ratio = visual_stall_ratio(active)
    if stall_ratio is not None and stall_ratio > MAX_VISUAL_STALL_RATIO:
        failures.append(
            f"visually stalled frames {stall_ratio * 100:.1f}% "
            f"> {MAX_VISUAL_STALL_RATIO * 100:.1f}%"
        )

    print(f"=== 60 fps scroll test: {path}")
    print(
        f"active={active_seconds:.2f}s  "
        f"committed_flushes={len(flush_durations)}  "
        f"presented={len(presented)}  never_displayed={never_displayed}"
    )
    print(
        "committed core flush: "
        f"p50={flush_p50_ns / 1e6:.3f}ms  "
        f"p95={flush_p95_ns / 1e6:.3f}ms  "
        f"p99={flush_p99_ns / 1e6:.3f}ms  "
        f"budget={FRAME_BUDGET_NS / 1e6:.3f}ms"
    )
    print(f"committed content rate: {committed_fps:.2f}/s")
    print(
        f"on-glass: effective_fps={effective_fps:.2f}  "
        f"slips={len(slips)} ({slip_rate:.3f}/s)"
    )
    if stall_ratio is not None:
        print(f"visually stalled frames: {stall_ratio * 100:.1f}%")

    if failures:
        sys.stdout.flush()
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    print("PASS: sustained the 60 fps scroll budget")
    return 0


def capture_trace(path, seconds):
    env = dict(os.environ)
    env.setdefault("ZONVIE_TRACE_CONFIG", "Release")
    command = [
        sys.executable,
        str(REPO / "test" / "perf" / "run_trace.py"),
        "atlas",
        str(seconds),
        str(path),
        "16",
    ]
    return subprocess.run(command, cwd=REPO, env=env).returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--seconds",
        type=float,
        default=12.0,
        help="continuous-scroll capture duration (default: 12)",
    )
    parser.add_argument(
        "--trace",
        type=Path,
        help="check an existing trace instead of launching the app",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_TRACE,
        help=f"capture output (default: {DEFAULT_TRACE})",
    )
    args = parser.parse_args()

    trace = args.trace.resolve() if args.trace else args.output.resolve()
    if args.trace is None:
        if capture_trace(trace, args.seconds) != 0:
            return 1
    if not trace.exists():
        print(f"FAIL: trace not found: {trace}", file=sys.stderr)
        return 1
    return check_trace(trace)


if __name__ == "__main__":
    raise SystemExit(main())
