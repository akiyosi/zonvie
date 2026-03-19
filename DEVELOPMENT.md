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

Release build:

```bash
xcodebuild -project macos/zonvie.xcodeproj \
  -scheme zonvie \
  -configuration Release \
  -derivedDataPath macos/.derived \
  -destination "platform=macOS,arch=arm64" \
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
  - `on_vertices`
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
5. The core performs atlas work and vertex generation.
6. Vertex callbacks submit main-grid, cursor, row, and external-grid updates.
7. `on_flush_end` commits the flush on the frontend side.

This matters for correctness:

- partial redraw must preserve prior buffers when update flags do not include them
- aborted flushes must preserve dirty state for retry
- layout-dependent rendering must stay synchronized with the dimensions used during flush

## Development Features To Be Aware Of

The current codebase includes development-sensitive behavior for:

- ext_cmdline
- ext_popupmenu
- ext_messages
- ext_tabline
- ext_windows
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
