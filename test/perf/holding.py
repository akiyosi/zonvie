#!/usr/bin/env python3
"""Motion smoothness restricted to periods of genuine continuous input.

A real capture contains pauses: the key is released, the buffer ends, the user
thinks. Those idle frames legitimately advance zero rows and would otherwise
swamp the statistic that matters — how even the motion is *while actually
scrolling*. This isolates runs of back-to-back key sends and reports only
frames inside them.
"""
import csv
import sys
from collections import defaultdict

DRAW_BEGIN, SKIP_NOCHANGE, GUARD, ADVANCE, INPUT = 1, 16, 17, 18, 12
VSYNC_NS = 16_666_667


def signed(a):
    return a if a < (1 << 63) else a - (1 << 64)


def main(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append((int(r["t_ns"]), int(r["tag"]), int(r["a"]), int(r["b"])))

    sends = [t for t, tag, _, _ in rows if tag == INPUT]
    if len(sends) < 10:
        print(f"=== {path}\nno synthesized key repeats in this capture "
              f"({len(sends)} sends) — was the key actually held?")
        return

    # A hold is a run of sends no more than 3 frame periods apart.
    holds, start, prev = [], sends[0], sends[0]
    for t in sends[1:]:
        if t - prev > 3 * VSYNC_NS:
            if prev - start > 0.5e9:
                holds.append((start, prev))
            start = t
        prev = t
    if prev - start > 0.5e9:
        holds.append((start, prev))

    total = sum(e - s for s, e in holds)
    print(f"=== {path}")
    print(f"holds: {len(holds)}  total held time: {total/1e9:.2f}s")
    for i, (s, e) in enumerate(holds):
        print(f"  hold {i}: {(e-s)/1e9:.2f}s")
    if not holds:
        return

    def inside(t):
        return any(s <= t <= e for s, e in holds)

    adv = [signed(a) for t, tag, a, _ in rows if tag == ADVANCE and inside(t)]
    hold_sends = [t for t in sends if inside(t)]
    drops = [a for t, tag, a, _ in rows if tag == SKIP_NOCHANGE and inside(t)]
    guards = [(a, b) for t, tag, a, b in rows if tag == GUARD and inside(t)]
    secs = total / 1e9

    print(f"\nwhile holding ({secs:.2f}s):")
    print(f"  key sends       {len(hold_sends):5d}  ({len(hold_sends)/secs:6.2f}/s)")
    print(f"  frames          {len(adv):5d}  ({len(adv)/secs:6.2f}/s)")
    if adv:
        hist = defaultdict(int)
        for d in adv:
            hist[d] += 1
        print("  advance histogram: " +
              "  ".join(f"{k}:{v}" for k, v in sorted(hist.items())))
        print(f"  rows delivered: {sum(adv)} over {len(adv)} frames "
              f"= {sum(adv)/secs:.2f} rows/s")

        # A long run of zero-advance frames is not a rendering fault: holding j
        # moves the cursor down the window and nvim emits no grid_scroll at all
        # until the cursor reaches the scrolloff boundary. Only isolated zeros
        # inside an otherwise scrolling stretch are motion the user loses.
        runs, cur = [], 0
        for d in adv:
            if d == 0:
                cur += 1
            else:
                if cur:
                    runs.append(cur)
                cur = 0
        if cur:
            runs.append(cur)
        travel = sum(r for r in runs if r > 3)
        isolated = sum(r for r in runs if r <= 3)
        scrolling = len(adv) - travel
        print(f"  zero-advance runs: {sorted(runs)}")
        print(f"  cursor travel (runs >3 frames, viewport legitimately still): "
              f"{travel} frames")
        if scrolling > 0:
            print(f"  --- while the viewport is actually scrolling "
                  f"({scrolling} frames, {scrolling/59.94:.2f}s) ---")
            print(f"  stalled frames: {isolated} = {isolated/(scrolling/59.94):.2f}/s "
                  f"({isolated*100.0/scrolling:.1f}%)")
        jumps = sum(v for k, v in hist.items() if k > 1)
        print(f"  jump frames (>1 row): {jumps} = {jumps/secs:.2f}/s")

        # A stall immediately followed by a jump means the row existed and
        # simply landed one frame late — a timing problem. A stall not followed
        # by a jump means no row was produced for that frame at all.
        late = lone = 0
        for i, d in enumerate(adv):
            if d == 0 and (i == 0 or adv[i - 1] != 0):
                nxt = adv[i + 1] if i + 1 < len(adv) else None
                if nxt is not None and nxt > 1:
                    late += 1
                else:
                    lone += 1
        print(f"  stall then jump (row arrived late): {late}")
        print(f"  stall with no catch-up (no row produced): {lone}")
    # Where the send lands inside the draw interval, and how long Neovim then
    # takes to commit. A phase near 1.0 means the send sits on the frame
    # boundary, so a fast reply lands right where the draw is already
    # sampling — the coin flip that produces stall/jump pairs.
    draws = sorted(t for t, tag, _, _ in rows if tag == DRAW_BEGIN and inside(t))
    commits = sorted(t for t, tag, _, _ in rows if tag == 11 and inside(t))
    if len(draws) > 10 and commits:
        import bisect
        phases = []
        for s in hold_sends:
            i = bisect.bisect_left(draws, s)
            if 0 < i < len(draws) and draws[i] > draws[i - 1]:
                phases.append((s - draws[i - 1]) / (draws[i] - draws[i - 1]))
        lat = []
        j = 0
        for s in hold_sends:
            while j < len(commits) and commits[j] < s:
                j += 1
            if j < len(commits):
                lat.append((commits[j] - s) / 1e6)
        if phases:
            phases.sort()
            print(f"  send phase in draw interval (0=just after a draw, "
                  f"1=on the next boundary): p10 {phases[len(phases)//10]:.2f}  "
                  f"p50 {phases[len(phases)//2]:.2f}  "
                  f"p90 {phases[9*len(phases)//10]:.2f}")
        if lat:
            lat.sort()
            over = sum(1 for x in lat if x > 16.67)
            print(f"  send -> commit latency ms: p50 {lat[len(lat)//2]:.2f}  "
                  f"p99 {lat[int(len(lat)*0.99)]:.2f}  max {lat[-1]:.2f}  "
                  f"(over one frame: {over})")

    if drops:
        print(f"  dropped frames: {len(drops)} = {len(drops)/secs:.2f}/s "
              f"(reasons: " +
              ", ".join(f"{c}x{drops.count(c)}" for c in sorted(set(drops))) + ")")
    if guards:
        hits = sum(1 for a, _ in guards if a == 1)
        print(f"  guard band: {len(guards)} waited, {hits} rescued, "
              f"{len(guards)-hits} timed out")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
        print()
