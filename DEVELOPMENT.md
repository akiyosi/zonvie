# Development Guide

This document describes how to build, run, debug, and validate Zonvie during development.

For a product overview and end-user configuration examples, see `README.md`.
For Claude-specific repository guidance, see `CLAUDE.md`.

## Prerequisites

### Common

- Zig 0.15.x
- Git
- Neovim available on `PATH` or configured explicitly

### macOS

- Xcode with macOS SDK
- Xcode Command Line Tools (`xcode-select --install`)
- Metal-capable macOS system

### Windows

- Windows SDK
- A working Zig toolchain targeting `x86_64-windows-gnu`

## Repository Layout

```text
zonvie/
├── build.zig                 # Zig build graph
├── include/                  # Public C ABI headers
├── src/
│   ├── core/                 # Shared Zig core: RPC, redraw, grid, flush, config
│   └── text/                 # Shaping, atlas, and rasterization helpers
├── macos/
│   ├── Sources/App/          # App lifecycle and view controller
│   ├── Sources/Core/         # Swift ↔ Zig bridge and app-side core integration
│   ├── Sources/Rendering/    # Metal renderer and view
│   ├── Sources/UI/           # macOS-specific UI components
│   └── zonvie.xcodeproj
├── windows/
│   ├── renderer/             # D3D11 / DWrite / composition renderers
│   ├── ui/                   # Windows UI helpers (messages, tabbar, dialogs, etc.)
│   ├── callbacks.zig         # Core callback handling
│   ├── app.zig               # App state
│   ├── input.zig             # Input translation
│   └── main.zig              # Windows entry point
└── test/                     # Zig unit tests
```

## Build

### Zig core only

Useful when working on shared code or checking ABI-level breakage:

```bash
zig build core
```

### Run Zig unit tests

```bash
zig build test
```

### macOS

The Xcode project builds the Zig core automatically as part of the app build.
It invokes `zig build core` for both `aarch64-macos` and `x86_64-macos`, then creates a universal static library.

Debug build:

```bash
xcodebuild -project macos/zonvie.xcodeproj \
  -scheme zonvie \
  -configuration Debug \
  -derivedDataPath macos/.derived \
  -destination "platform=macOS,arch=arm64" \
  build
```

Release build (single-arch, matching the CI release pipeline — Homebrew
on Apple Silicon ships arm64-only dylibs, so a universal link is not
possible locally; official releases build each arch on its native
runner, see `.github/workflows/release.yml`):

```bash
xcodebuild -project macos/zonvie.xcodeproj \
  -scheme zonvie \
  -configuration Release \
  -derivedDataPath macos/.derived \
  -destination "platform=macOS,arch=arm64" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build
```

App bundle output:

```text
macos/.derived/Build/Products/<Configuration>/zonvie.app
```

### Windows

Debug/default build:

```bash
zig build windows -Dtarget=x86_64-windows-gnu
```

Optimized build:

```bash
zig build windows -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

Binary output:

```text
windows/zig-out/zonvie.exe
```

## Architecture Overview

Zonvie is split into a shared Zig core and thin native frontends.

### Shared Zig core

The shared core is responsible for:

- Neovim process management and RPC
- redraw event parsing
- grid state and highlight state
- flush scheduling and partial redraw handling
- vertex generation
- configuration parsing
- public C ABI for native frontends

Important files include:

- `src/core/nvim_core.zig`
- `src/core/redraw_handler.zig`
- `src/core/grid.zig`
- `src/core/flush.zig`
- `src/core/vertexgen.zig`
- `src/core/c_api.zig`

### Text and glyph pipeline

Text-related functionality is split between core and text helpers:

- `src/text/shaping_harfbuzz.zig`
- `src/text/rasterize_freetype.zig`
- `src/text/gpu_atlas.zig`

The glyph atlas uses a two-phase core-managed approach:
- Core manages shelf packing and glyph cache (zero per-cell allocation)
- Frontend handles rasterization (FreeType on macOS, DirectWrite on Windows) and texture upload
- Atlas textures are double-buffered with COW detach for safe concurrent read/write

### Frontends

macOS frontend:

- AppKit + Swift
- Metal renderer
- Swift bridge to the Zig core in `macos/Sources/Core/ZonvieCore.swift`

Windows frontend:

- Win32 app
- D3D11 / DXGI rendering
- DirectWrite / Direct2D text integration
- renderer and UI helpers under `windows/renderer/` and `windows/ui/`

## Core ↔ Frontend Contract

The public ABI is defined in `include/zonvie_core.h`.

Important contract areas:

- exported C API functions
- callback struct layout
- vertex update modes:
  - `on_vertices_partial`
  - `on_vertices_row`
- flush bracketing callbacks:
  - `on_flush_begin`
  - `on_flush_end`
- font/layout notifications:
  - `on_guifont`
  - `on_linespace`
- ext UI callbacks:
  - cmdline
  - popupmenu
  - messages
  - tabline
  - external windows

When changing shared behavior, verify both frontend consumers, not just the header.

## Rendering / Flush Model

The current rendering model is flush-driven.

High-level flow:

1. Neovim sends redraw events over RPC.
2. The core updates grid and UI-extension state.
3. A flush cycle begins.
4. `on_flush_begin` gives the frontend a chance to prepare or abort the flush.
   - Atlas back-texture sync: two-phase approach — phase 1 handles CPU sync and no-op cases without a command buffer; phase 2 creates a command buffer only when GPU blit is needed.
   - Vertex buffer sets are shallow-copied (COW) from the committed set.
5. The core performs atlas work and vertex generation.
   - Glyph rasterization and atlas upload callbacks fire synchronously.
6. Vertex callbacks submit main-grid, cursor, row, and external-grid updates.
   - Row buffers use COW detach: shared buffers are written in-place when the GPU semaphore guarantees no in-flight read.
   - Cursor buffers are independently owned per buffer set (no COW sharing).
7. `on_flush_end` commits the flush on the frontend side.

This matters for correctness:

- partial redraw must preserve prior buffers when update flags do not include them
- aborted flushes must preserve dirty state for retry
- layout-dependent rendering must stay synchronized with the dimensions used during flush
- COW detach must not create unbounded MTLBuffer allocations (pool-alias safety)

Rendering resource limits are split between logical core accounting and
frontend-owned physical storage:

- The core rejects a single vertex callback above 64 MiB, a completed surface
  above 128 MiB, or all completed surfaces above 256 MiB. Surface and aggregate
  limits are evaluated against the completed flush state, so replacing old
  rows cannot fail only because old and new counts temporarily coexist.
- Main-grid row-to-subgrid indexing is limited to 8 MiB. Layout mutations that
  would exceed the limit fail before publication and preserve the previous
  layout. An unchanged layout generation reuses the existing index.
- Frontends must separately bound their physical GPU allocations. Buffering and
  copy-on-write can require more storage than the core's logical totals. Core
  acceptance does not promise that every frontend can represent the frame. If
  a fixed frontend budget cannot provision a flush, it must call
  `zonvie_core_fail_render_budget`; that failure is a deliberate terminal UI
  session outcome, not retryable backpressure.
- macOS row storage has a 256 MiB per-surface peak and a 512 MiB process-wide
  peak shared by the main renderer and all external windows. Both limits count
  unique live MTLBuffer objects plus replacement reservations. With three
  sets and two private slots per set, a fresh 42 MiB row fits the per-surface
  byte limit while a 44 MiB row is rejected even though it remains below the
  core's logical 64 MiB callback limit; the boundary is covered by the Metal
  provisioning test.
- Windows row vertex buffers use the same 256 MiB per-surface and 512 MiB
  process-wide physical byte limits. Growth reserves the complete replacement
  buffer while the old buffer is still live, commits accounting only after
  `CreateBuffer` succeeds, and releases ownership on row shrink, surface
  destruction, or device loss. Exceeding either fixed limit terminates the UI
  session through `zonvie_core_fail_render_budget`.
- Windows scrollbar underlay capture and restore are part of the paint
  transaction. A missing D3D resource or function stops Present, clears the
  saved-underlay state, and requests a full retry; unchanged track geometry
  does not suppress a later allocation attempt.
- Completed external-surface vertex totals are maintained incrementally across
  membership, resize, scroll, and row replacement. A layout-generation change
  therefore does not scan every external grid at flush begin. Abort recovery
  still visits all surfaces to invalidate their row ledgers and request the
  necessarily full resend.
- macOS contraction provisioning replaces private row buffers whose capacity
  exceeds twice the current row demand. The newly committed set retires its own
  oversized detach/private storage while retaining active content. Zero is a
  valid known column count; a zero-column commit also retires the newly
  committed active row storage. Three-set rotation then converges storage to a
  later narrow demand without allocating inside the redraw callback.
- Windows device-loss recovery continues until the device is rebuilt or the
  main HWND is torn down. Retries use exponential backoff capped at 30 seconds;
  after three failed attempts Zonvie warns once without terminating recovery.

## Development Features To Be Aware Of

The current codebase includes development-sensitive behavior for:

- ext_cmdline
- ext_popupmenu
- ext_messages
- ext_tabline
- ext_windows (each Neovim window as a separate OS window)
- neon/glow effects (Dual Kawase bloom post-processing)
- variable font support (fvar variation axes)
- SSH mode and askpass flow
- devcontainer mode and rebuild flow
- quit confirmation / unsaved-buffer checks
- default color updates and other UI-side notifications

Changes in these areas usually require checking both macOS and Windows implementations.

## Logging and Debugging

### Application logging

You can enable logging with:

```bash
zonvie --log /tmp/zonvie.log
```

Or via config:

```toml
[log]
enabled = true
path = "/tmp/zonvie.log"
```

### Development notes

- Prefer narrow builds/tests while iterating.
- When touching shared ABI or redraw behavior, inspect both frontends before concluding a change is safe.
- When touching performance-sensitive code, note whether allocations, lock contention, or flush behavior changed.

## Validation Checklist

Before considering a change complete, validate the narrowest relevant subset of the following:

### Core / rendering

- basic editing and cursor movement
- resize correctness
- `guifont` changes
- `linespace` changes
- partial redraw behavior
- flush correctness after resize or scale changes

### UI extensions

- ext_cmdline
- ext_popupmenu
- ext_messages
- ext_tabline
- external windows / multigrid flows

### Environment-dependent features

- SSH connection and authentication prompt flow
- devcontainer startup
- devcontainer rebuild path
- quit confirmation with unsaved buffers

### Automated checks

- `zig build test`
- targeted platform build for the code you touched
