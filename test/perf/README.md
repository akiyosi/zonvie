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
| `run_realkey.py` | same, but holds a real key so the app's repeat synthesis runs |
| `holding.py` | motion inside the stretches where a key was genuinely held |
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

## Capturing a held key without a person

`run_realkey.py` holds the key for you. It launches the same headless nvim plus
app as `run_trace.py`, then posts three events through `holdkey.swift`: a
keyDown, a keyDown with the autorepeat flag (which is what the app's takeover
keys off — `NSEvent.isARepeat`), and a keyUp at the end. Everything in between
is the app's own repeat synthesis at production cadence, so the whole input
path is exercised.

```bash
ZONVIE_SMOOTH_SCROLL=1 ZONVIE_TRACE_CONFIG=Release \
  test/perf/run_realkey.py 12 tmp/scrollperf/rk.csv
test/perf/holding.py tmp/scrollperf/rk.csv
```

A good capture reports `holds: 1` for the full duration, `key sends` at ~60/s
and `send -> commit` never over one frame — the same signature a hand-held
capture produces.

**It needs Accessibility permission**, and macOS attributes that to the process
*responsible* for the driver — the GUI app at the top of the shell's process
tree, not the driver binary. Grant it to the terminal you run this from. The
driver prints what it sees (`accessibility-trusted=`) and refuses to post
without it, rather than producing a capture with no scrolling in it.

Two things to watch for:

- **A run occasionally produces nothing** (~1 in 6 observed): the app logs
  `error messaging the mach port for IMKCFRunLoopWakeUpReliable`, the first
  keyDown is lost in the input context, and with no press to replay there is no
  takeover. `holding.py` reports no holds. Re-run.
- **The producer is noisier here than in normal use.** These captures contain
  frames advancing three rows, which a hand-held capture on a real session did
  not. Do not tune the ease clamp to them without checking the same number on a
  hand-held trace first.

## Capturing a real held key by hand

`run_trace.py` drives nvim directly, which means the app's own key-repeat
synthesis never engages. Anything about input timing — the repeat cadence, the
phase between a send and the frame that consumes it — can only be measured
from a real held key. Do it by hand:

```bash
ZONVIE_TRACE=1 ZONVIE_TRACE_PATH=$PWD/tmp/scrollperf/real.csv \
  macos/.derived/Build/Products/Release/zonvie.app/Contents/MacOS/zonvie --nofork
```

Open a long file, hold `j` for ~20s, then from another terminal:

```bash
kill -USR1 $(pgrep -n -f "Products/Release/zonvie.app")
test/perf/holding.py tmp/scrollperf/real.csv
```

**Pass `--nofork`.** Without it the app re-spawns itself with stdout and
stderr redirected to `/dev/null` (`macos/Sources/App/main.swift`), so the
`[frametrace] wrote N events` confirmation is swallowed even though the dump
succeeds. The environment is inherited either way.

`holding.py` isolates the stretches where the key was genuinely held and
reports motion only there. It also separates two things the raw histogram
conflates: a long run of zero-advance frames is usually **not** a fault —
holding `j` walks the cursor down the window and nvim emits no `grid_scroll`
at all until it reaches the scrolloff boundary. Only isolated zeros inside an
otherwise scrolling stretch are motion the user actually loses.

## Sub-row smooth scrolling (`ZONVIE_SMOOTH_SCROLL=1`)

Off by default. When set, a keyboard-driven scroll holds the picture back by
the distance Neovim just scrolled and eases it forward (decay 0.5/frame, about
one row of steady-state lag), so a frame that receives no row still moves and a
frame that receives two shows part of the jump now and the rest next frame. The
outgoing row is copied out of its slot before the scroll rotation reuses it, so
the vacated band has real content to show.

`scrollAdvance` alone can no longer describe the result: it records content row
deltas, which are unchanged. The picture sits at `content_rows * h - offset`,
and the applied offset is traced per frame as `smoothScrollOffset`. `analyze.py`
reports the combination as **`visual motion (ease applied)`**.

```bash
ZONVIE_TRACE_CONFIG=Release                        test/perf/run_trace.py buffer 15 tmp/scrollperf/ss_off.csv
ZONVIE_SMOOTH_SCROLL=1 ZONVIE_TRACE_CONFIG=Release test/perf/run_trace.py buffer 15 tmp/scrollperf/ss_on.csv
```

Measured back to back (Release, 15s, four captures each side): per-frame advance
sd 0.205-0.265 -> 0.116-0.134 rows, stalled frames inside a scrolling stretch
3.1-4.5% -> 0.4%, two-row jumps 10-22 -> 3-4. Cost: the offset forces a full row
redraw (dirty rows 3 -> 53) for the duration of the scroll, which measured as
GPU p50 4.8ms of the 16.67ms budget — unchanged from the partial-redraw
baseline within run-to-run spread — plus one row-sized buffer copy per scrolled
row.

Two things the harness cannot settle, both of which need a real held key:

- the app's key-repeat synthesis never engages here (see "Limitations")
- the top/bottom band is where the earlier no-retention attempt broke, and no
  metric sees it. Check scroll start, scroll end, both buffer edges and a
  split. Known cosmetic limitation: the vertex shader pins the edge background
  quad so it stretches into the gap, so within that band the retained row's
  glyphs are drawn over the neighbouring row's background colour.

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

**Is the repeat send landing on a frame boundary?** `holding.py` reports
`send phase in draw interval`; 1.0 means the send sits exactly on the
boundary, so Neovim's reply lands where the draw is already sampling. Note
that shifting that phase by delaying the send through a dispatch timer was
tried and reverted: it felt worse. The repeat currently goes out directly from
the display-link callback, giving a cadence measured at a 16.667ms median with
zero gaps, and a timer's leeway is enough to spoil that — trading a rare
boundary coin flip for jitter on every frame.

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
