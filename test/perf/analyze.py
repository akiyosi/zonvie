#!/usr/bin/env python3
"""Analyze a zonvie binary frame trace (FrameTracer CSV dump).

Answers, per capture:
  - how often a frame failed to reach the glass on the next vsync
  - how much of the main thread went into the blocking nextDrawable call
  - how much content each frame actually had to rebuild
"""
import sys
import csv
from collections import defaultdict

TAG = {
    1: "drawBegin", 2: "drawEnd", 3: "drawableAcquireBegin", 4: "drawableAcquireEnd",
    5: "presentCall", 6: "presented", 7: "gpuComplete", 8: "drawSkipSemaphore",
    9: "drawSkipNoDrawable", 10: "drawSkipRowCapacity", 11: "commitFlush",
    12: "inputSend", 13: "encodeEnd", 14: "gpuSubmit", 15: "frameContent",
    16: "drawSkipNoChange", 17: "commitGuardBand", 18: "scrollAdvance",
    19: "smoothScrollOffset",
}
VSYNC_NS = 16_666_667


def pct(vals, p):
    if not vals:
        return 0
    s = sorted(vals)
    return s[min(len(s) - 1, int(len(s) * p / 100))]


def summarize(name, vals_ns):
    if not vals_ns:
        print(f"  {name:26s} (none)")
        return
    print(f"  {name:26s} n={len(vals_ns):6d}  "
          f"p50={pct(vals_ns,50)/1000:8.1f}us  p95={pct(vals_ns,95)/1000:8.1f}us  "
          f"p99={pct(vals_ns,99)/1000:8.1f}us  max={max(vals_ns)/1000:9.1f}us")


def main(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append((int(r["t_ns"]), int(r["tag"]), int(r["seq"]),
                         int(r["a"]), int(r["b"])))
    if not rows:
        print("empty trace")
        return

    # Trim to the continuous-scroll window. The capture also contains app
    # startup and the settle period before keys start flowing; including those
    # idle gaps would understate every rate and inflate every max.
    draws = [t for t, tag, _, _, _ in rows if tag == 1]
    if len(draws) > 10:
        best = (0, 0, 0)
        run_start = draws[0]
        for i in range(1, len(draws)):
            if draws[i] - draws[i - 1] > 100_000_000:  # 100ms idle => new run
                if draws[i - 1] - run_start > best[0]:
                    best = (draws[i - 1] - run_start, run_start, draws[i - 1])
                run_start = draws[i]
        if draws[-1] - run_start > best[0]:
            best = (draws[-1] - run_start, run_start, draws[-1])
        lo, hi = best[1], best[2]
        rows = [r for r in rows if lo <= r[0] <= hi]
        print(f"[active scroll window: {(hi-lo)/1e9:.2f}s]")

    t0, t1 = rows[0][0], rows[-1][0]
    span_s = (t1 - t0) / 1e9
    counts = defaultdict(int)
    for _, tag, _, _, _ in rows:
        counts[tag] += 1

    print(f"=== {path}")
    print(f"span={span_s:.2f}s  events={len(rows)}")
    print("event counts:")
    for tag in sorted(counts):
        print(f"  {TAG.get(tag, tag):26s} {counts[tag]:6d}   "
              f"({counts[tag]/span_s:7.2f}/s)")

    # --- on-glass cadence -------------------------------------------------
    presented = sorted(a for _, tag, _, a, _ in rows if tag == 6 and a > 0)
    never = sum(1 for _, tag, _, a, _ in rows if tag == 6 and a == 0)
    print(f"\non-glass frames: {len(presented)} presented, {never} never displayed")
    if len(presented) > 1:
        iv = [presented[i + 1] - presented[i] for i in range(len(presented) - 1)]
        slips = [d for d in iv if d > VSYNC_NS * 1.5]
        disp_span = (presented[-1] - presented[0]) / 1e9
        print(f"  presented interval p50={pct(iv,50)/1e6:.3f}ms  "
              f"p99={pct(iv,99)/1e6:.3f}ms  max={max(iv)/1e6:.3f}ms")
        print(f"  effective fps = {len(iv)/disp_span:.2f}")
        print(f"  SLIPS (>1.5 vsync): {len(slips)}  = {len(slips)/disp_span:.3f}/s")
        buckets = defaultdict(int)
        for d in iv:
            buckets[round(d / VSYNC_NS)] += 1
        print("  interval in vsync units: " +
              "  ".join(f"{k}x:{v}" for k, v in sorted(buckets.items())))

    # --- per-phase durations ---------------------------------------------
    print("\nmain-thread phases:")
    acq, draw_dur = [], []
    open_acq = None
    open_draw = None
    for t, tag, _, _, _ in rows:
        if tag == 3:
            open_acq = t
        elif tag == 4 and open_acq is not None:
            acq.append(t - open_acq)
            open_acq = None
        elif tag == 1:
            open_draw = t
        elif tag == 2 and open_draw is not None:
            draw_dur.append(t - open_draw)
            open_draw = None
    summarize("nextDrawable block", acq)
    summarize("draw(in:) total", draw_dur)
    if acq and draw_dur:
        share = sum(acq) / sum(draw_dur) * 100
        print(f"  -> nextDrawable is {share:.1f}% of all main-thread draw time")
        over = [d for d in acq if d > 4_000_000]
        print(f"  -> blocks >4ms: {len(over)} ({len(over)/span_s:.2f}/s)")

    gpu = [b - a for _, tag, _, a, b in rows if tag == 7 and b > a]
    summarize("GPU execution", gpu)

    # --- content per frame ------------------------------------------------
    fc = [(a, b, seq) for _, tag, seq, a, b in rows if tag == 15]
    if fc:
        dirty = [a for a, _, _ in fc]
        rowmode = sum(1 for _, b, _ in fc if b == 1)
        print(f"\ncontent: frames={len(fc)}  rowMode={rowmode}/{len(fc)}")
        print(f"  dirty rows p50={pct(dirty,50)}  p95={pct(dirty,95)}  max={max(dirty)}")
        heavy = sum(1 for d in dirty if d > 20)
        print(f"  frames rebuilding >20 rows: {heavy} ({heavy*100.0/len(fc):.1f}%)")

    # --- why frames were dropped -----------------------------------------
    REASON = {1: "no vertices", 2: "nothing changed",
              3: "rowMode, no dirty rows", 4: "blink-only, no cursor"}
    skips = [a for _, tag, _, a, _ in rows if tag == 16]
    if skips:
        print(f"\ndropped frames (vsync with nothing new): {len(skips)}"
              f"  = {len(skips)/span_s:.3f}/s")
        for code in sorted(set(skips)):
            n = skips.count(code)
            print(f"  reason {code} ({REASON.get(code,'?')}): {n}")

    # --- motion smoothness ------------------------------------------------
    # A perfect present cadence still looks uneven if the content does not
    # advance by the same amount every frame. This is the separate question
    # from whether frames reached the glass.
    adv = [a if a < (1 << 63) else a - (1 << 64)
           for _, tag, _, a, _ in rows if tag == 18]
    if adv:
        moving = [d for d in adv if d != 0]
        if moving:
            typical = pct(sorted(moving), 50)
            hist = defaultdict(int)
            for d in adv:
                hist[d] += 1
            print(f"\nmotion: {len(adv)} frames, typical advance {typical} rows/frame")
            print("  advance histogram: " +
                  "  ".join(f"{k}:{v}" for k, v in sorted(hist.items())))
            uneven = sum(v for k, v in hist.items() if k != typical)
            print(f"  frames not advancing by {typical}: {uneven} "
                  f"({uneven*100.0/len(adv):.1f}%)  = {uneven/span_s:.2f}/s")
            stalls = hist.get(0, 0)
            print(f"  stalled frames (0 rows): {stalls} = {stalls/span_s:.2f}/s")
            jumps = sum(v for k, v in hist.items() if abs(k) > abs(typical))
            print(f"  jump frames (>|{typical}| rows): {jumps} = {jumps/span_s:.2f}/s")

    # --- visual motion with the sub-row ease applied -----------------------
    # Once ZONVIE_SMOOTH_SCROLL is on, the row delta above stops describing
    # what the eye sees: the picture sits at content_rows * h - offset. Replay
    # both streams in trace order and report the advance of that position.
    if any(tag == 19 for _, tag, _, _, _ in rows):
        signs = {1 if d > 0 else -1 for d in adv if d != 0}
        if len(signs) > 1:
            print("\nvisual motion: skipped (scroll reverses direction in "
                  "this capture; the traced offset is unsigned)")
        else:
            sign = signs.pop() if signs else 1
            offset_px = 0.0
            row_px = 0.0
            content_px = 0.0
            prev = None
            steps = []
            for _, tag, _, a, b in rows:
                if tag == 19:
                    offset_px = a / 1000.0
                    if b:
                        row_px = b / 1000.0
                elif tag == 18 and row_px:
                    d = a if a < (1 << 63) else a - (1 << 64)
                    content_px += d * row_px
                    # Where the picture actually sits this frame.
                    pos = content_px - sign * offset_px
                    if prev is not None:
                        steps.append(pos - prev)
                    prev = pos
            if steps and row_px:
                cells = [s / row_px for s in steps]
                mean = sum(cells) / len(cells)
                var = sum((c - mean) ** 2 for c in cells) / len(cells)
                stalled = sum(1 for c in cells if abs(c) < 0.05)
                print(f"\nvisual motion (ease applied): {len(cells)} frames, "
                      f"mean {mean:.3f} rows/frame, sd {var ** 0.5:.3f}")
                print(f"  frames not moving at all: {stalled} "
                      f"({stalled*100.0/len(cells):.1f}%) = {stalled/span_s:.2f}/s")

    # --- guard band effectiveness -----------------------------------------
    guards = [(a, b) for _, tag, _, a, b in rows if tag == 17]
    if guards:
        hits = sum(1 for a, _ in guards if a == 1)
        waits = [b for _, b in guards]
        print(f"\ncommit guard band: {len(guards)} frames waited "
              f"({len(guards)/span_s:.2f}/s), {hits} rescued, "
              f"{len(guards)-hits} timed out")
        print(f"  wait time p50={pct(waits,50)/1000:.0f}us  "
              f"p95={pct(waits,95)/1000:.0f}us  max={max(waits)/1000:.0f}us")
        print(f"  total main-thread time spent waiting: "
              f"{sum(waits)/1e6:.1f}ms over {span_s:.1f}s "
              f"({sum(waits)/1e7/span_s:.3f}% of wall clock)")

    # --- phase between content arriving and the frame that consumes it ----
    # If commits land just *after* each draw, every frame ships stale content
    # and any jitter turns into a dropped frame. This measures that phase.
    flushes = [t for t, tag, _, _, _ in rows if tag == 11]
    if len(draws) > 10 and flushes:
        lead = []
        j = 0
        for d in draws:
            while j + 1 < len(flushes) and flushes[j + 1] <= d:
                j += 1
            if flushes[j] <= d:
                lead.append(d - flushes[j])
        if lead:
            print(f"\ncommit -> draw lead time (age of content at draw):")
            print(f"  p50={pct(lead,50)/1e6:.2f}ms  p95={pct(lead,95)/1e6:.2f}ms  "
                  f"max={max(lead)/1e6:.2f}ms")
            late = [x for x in lead if x < 1_000_000]
            print(f"  draws consuming a commit <1ms old (near-miss): "
                  f"{len(late)} ({len(late)*100.0/len(lead):.1f}%)")

    # --- input cadence ----------------------------------------------------
    ins = sorted(t for t, tag, _, _, _ in rows if tag == 12)
    if len(ins) > 1:
        iv = [ins[i + 1] - ins[i] for i in range(len(ins) - 1)]
        gaps = [d for d in iv if d > pct(iv, 50) * 1.5]
        print(f"\ninput sends: {len(ins)}  p50={pct(iv,50)/1e6:.3f}ms  "
              f"gaps={len(gaps)} ({len(gaps)/span_s:.2f}/s)")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
        print()
