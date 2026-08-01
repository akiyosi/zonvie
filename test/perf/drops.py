#!/usr/bin/env python3
"""Timeline around each dropped frame.

Discriminates two very different causes of a dropped frame:
  - near-miss race: the next commit lands a hair AFTER the draw gave up, so
    the content existed and we simply looked too early.
  - upstream starvation: no commit arrives for most of a frame period, i.e.
    nothing was produced for that vsync and no renderer change can help.
"""
import csv
import sys

DRAW_BEGIN, COMMIT, SKIP = 1, 11, 16


def main(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append((int(r["t_ns"]), int(r["tag"]), int(r["a"])))
    commits = [t for t, tag, _ in rows if tag == COMMIT]
    drops = [t for t, tag, _ in rows if tag == SKIP]
    print(f"=== {path}\ndropped frames: {len(drops)}")
    if not drops:
        return

    after, before = [], []
    for d in drops:
        nxt = next((c for c in commits if c > d), None)
        prv = max((c for c in commits if c <= d), default=None)
        if nxt is not None:
            after.append(nxt - d)
        if prv is not None:
            before.append(d - prv)

    print(f"{'drop#':>5} {'since prev commit':>19} {'until next commit':>19}")
    for i, d in enumerate(drops):
        nxt = next((c for c in commits if c > d), None)
        prv = max((c for c in commits if c <= d), default=None)
        a = f"{(d-prv)/1e6:.2f}ms" if prv else "-"
        b = f"{(nxt-d)/1e6:.2f}ms" if nxt else "-"
        print(f"{i:>5} {a:>19} {b:>19}")

    if after:
        s = sorted(after)
        near = [x for x in after if x < 2_000_000]
        print(f"\nnext commit after the drop: p50={s[len(s)//2]/1e6:.2f}ms  "
              f"min={s[0]/1e6:.2f}ms  max={s[-1]/1e6:.2f}ms")
        print(f"drops where content arrived <2ms later (near-miss race): "
              f"{len(near)}/{len(after)}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
        print()
