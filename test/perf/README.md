# Scroll performance harness

Measures where frames go during a continuous scroll in the real macOS app:
how many reach the glass, how many are dropped and why, and how the main
thread and GPU divide up the 16.67ms frame budget.

This exists because the obvious approach does not work. The app's normal
logger formats a String per event and writes it, which costs enough to move
the timings being measured — a repeatedly confirmed effect in this project.
Every conclusion drawn from those logs carried that doubt. So the app carries
a separate instrument, `macos/Sources/Rendering/FrameTracer.swift`: a
preallocated ring of POD records with no allocation, no formatting and no I/O
on the hot path, converted to CSV only when explicitly dumped.

## Requirements

- a built `zonvie.app` (see `DEVELOPMENT.md`)
- `nvim` on `PATH`
- `tig` on `PATH`, for the `tig` scenario only
- Python 3

## Running

```bash
# Debug build, normal buffer, 15s
test/perf/run_trace.py buffer 15 tmp/scrollperf/base.csv

# Release build — use this for any conclusion you intend to keep
ZONVIE_TRACE_CONFIG=Release test/perf/run_trace.py buffer 15 tmp/scrollperf/rel.csv

# tig diff scroll in a :terminal
ZONVIE_TRACE_CONFIG=Release test/perf/run_trace.py tig 15 tmp/scrollperf/tig.csv

test/perf/analyze.py tmp/scrollperf/rel.csv
test/perf/drops.py   tmp/scrollperf/rel.csv
```

A real app window opens and scrolls for the duration of the capture. Output
goes under `tmp/`, which is gitignored.

**Use Release for anything you plan to act on.** Its `draw(in:)` finishes
sooner than Debug's, which makes it *lose* the commit race more often. Debug
consistently understates the problem.

## What the scripts do

| script | purpose |
| --- | --- |
| `run_trace.py` | launches headless nvim + the app, drives the scroll, dumps the trace |
| `analyze.py` | per-capture summary: on-glass cadence, dropped frames, phase timings |
| `drops.py` | timeline around each dropped frame, to attribute the cause |

`run_trace.py` drives the scroll from a timer **inside** nvim rather than by
synthesizing key events. That removes process-spawn cost and OS key-repeat
jitter from the measurement, leaving the rendering pipeline. The tradeoff is
in "Limitations" below.

It also points `XDG_CONFIG_HOME` at a scratch directory, so an ambient
`~/.config/zonvie/config.toml` cannot force the string-formatting logger back
on behind your back.

## Reading the output

The numbers that matter most:

- **`SLIPS (>1.5 vsync)`** — frames that failed to reach the glass on the next
  vsync. This is the metric that corresponds to perceived stutter.
- **`dropped frames (vsync with nothing new)`** — vsyncs where the renderer
  itself decided there was nothing to present, with the reason code. In a
  healthy capture this is ~0. When it tracks the slip count 1:1, the stutter
  is self-inflicted, not compositor-side.
- **`commit -> draw lead time`** — how old the content was when the frame
  consumed it. A large near-miss percentage means content and vsync are
  arriving in near-lockstep, so jitter decides which side of the boundary a
  frame lands on.
- **`nextDrawable block`** — time lost to `CAMetalLayer`'s blocking drawable
  acquire. Long suspected as the cause of the residual slip floor; measured
  at p50 23-69us with no block above 4ms, so it is not.
- **`commit guard band`** — how often a frame waited for an in-flight commit
  instead of dropping itself, and whether the wait paid off. Timeouts mean the
  bound is too tight for the producer.

`drops.py` prints, for each dropped frame, how long before it the previous
commit landed and how long after it the next one did. A next-commit distance
of a few hundred microseconds is a near-miss race — the content existed and
the renderer looked too early. A distance of many milliseconds means nothing
was produced for that vsync, which no rendering change can fix.

## Discriminating experiments

**Is the drop a race, or was nothing produced?** Raise the producer rate above
the display rate, so every vsync is guaranteed fresh content:

```bash
ZONVIE_TRACE_CONFIG=Release test/perf/run_trace.py buffer 15 tmp/scrollperf/fast.csv 6
```

If dropped frames go to zero, the drops were a phase race.

**Does a change actually help?** A/B the guard band, back to back, several
times each — single captures fall inside this project's known run-to-run
spread and have produced wrong conclusions before:

```bash
ZONVIE_TRACE_CONFIG=Release ZONVIE_COMMIT_GUARD_US=0    test/perf/run_trace.py buffer 15 tmp/scrollperf/off.csv
ZONVIE_TRACE_CONFIG=Release ZONVIE_COMMIT_GUARD_US=2000 test/perf/run_trace.py buffer 15 tmp/scrollperf/on.csv
```

## Limitations

Read these before trusting a number.

- **The producer is not the real one.** The nvim-side timer is not the app's
  own vsync-locked key-repeat synthesis, so the phase relationship between
  content production and vsync differs from a real held key. The harness is
  sound for finding and fixing pipeline behaviour; confirm anything
  user-visible with an actual held key.
- **Window visibility silently ruins a capture.** If the window is occluded or
  the display sleeps, most frames report `presentedTime == 0` and the capture
  reads as ~25fps with a huge slip count while the CPU/GPU pipeline shows a
  perfect 60/s. **Always check the `never displayed` count** before believing a
  bad result; a capture that recovers with no code change was environmental.
- **The idle period is trimmed automatically.** `analyze.py` isolates the
  longest continuous run of draws, so app startup and the settle period do not
  drag the rates down. Check the reported window length looks sane.
- **macOS only.** The Windows frontend has no equivalent instrument yet.

## Adding a trace point

Add a case to `FrameTraceTag` in `FrameTracer.swift`, call
`FrameTracer.trace(.yourTag, a:, b:)` at the site, and add the tag to the `TAG`
map in `analyze.py`. `a` and `b` are free 64-bit fields — existing tags use
them for durations, timestamps, counts and reason codes. Wrap anything that
costs more than a couple of loads in `if FrameTracer.enabled`.
