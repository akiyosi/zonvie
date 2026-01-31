# CLAUDE.md (Zonvie)

You are working in **Zonvie**, a high-performance Neovim GUI.

## Project intent

Zonvie is designed around these non-negotiables:

- **Core in Zig** and shared across platforms.
- **Thin, native UI frontends**:
  - macOS: **AppKit + Swift** (Metal rendering)
  - Windows: **Win32 + D2D/DWrite and/or D3D11/DXGI**
- **Fastest possible rendering path** (prioritize frame time and latency over convenience).
- **Zig “zero-allocation” design in hot paths** (no heap work during redraw/flush unless explicitly justified).
- **Full compliance with Neovim’s `ui` API** (a.k.a. “api-ui”), including correctness under partial redraws and option changes.

## Architecture overview

### 1) Zig core (shared)
- Lives under `src/shared/`.
- Exposed to frontends as a **C ABI** (headers under `include/`).
- The frontend calls `zonvie_core_start(...)`, sends input/key events, and notifies layout changes (drawable size + cell metrics).
- The core calls back into the frontend via `zonvie_callbacks` for:
  - vertex submission (full, partial, row-based)
  - atlas glyph ensure
  - render-plan / background spans + text runs (if used)
  - guifont / linespace notifications
  - logging and exit notification  
  (See `zonvie_callbacks` and the vertex update contracts in `include/zonvie_core.h`.) :contentReference[oaicite:0]{index=0} :contentReference[oaicite:1]{index=1}

### 2) macOS frontend (AppKit + Swift, Metal)
- Swift side includes Zig headers via a bridging header. :contentReference[oaicite:2]{index=2}
- Metal renderer is fed by vertex buffers (and supports dirty/partial redraw strategies).
- Swift forwards user input and layout updates to core (e.g., `zonvie_core_send_key_event`, `zonvie_core_update_layout_px`). :contentReference[oaicite:3]{index=3} :contentReference[oaicite:4]{index=4}

### 3) Windows frontend (Win32 + DWrite/D2D and/or D3D11)
- Built via `zig build windows` and links system graphics libs (DWrite/D2D + D3D11/DXGI). :contentReference[oaicite:5]{index=5}

## Repository map (mental model)

- `include/`
  - `zonvie_core.h`: C ABI for core + callback contracts (authoritative integration spec). :contentReference[oaicite:6]{index=6}
  - `zonvie_hbft.h`: C ABI for HarfBuzz+FreeType helper (shape/rasterize). :contentReference[oaicite:7]{index=7}
- `src/shared/`
  - `nvim_core.zig`: Neovim RPC/ui event handling, grid state, flush pipeline
  - `grid.zig`, `redraw_handler.zig`: apply api-ui “redraw” events to internal model
  - `vertexgen.zig`: convert grid model → GPU-friendly vertices; uses `zonvie_hbft.h`. :contentReference[oaicite:8]{index=8}
  - `c_api.zig`: exported symbols / C ABI glue
- `macos/`
  - Swift/Metal frontend; calls into Zig core via bridging header. :contentReference[oaicite:9]{index=9}
- `windows/`
  - Win32 frontend + renderers, built from Zig

## Core ↔ Frontend contract (must not break)

### Vertex update modes
The core may submit vertices in one of these ways:

1) **Full replace**: `on_vertices(main, cursor)`  
2) **Partial update**: `on_vertices_partial(..., flags)`  
   - If a buffer is *not* included in flags, the frontend **must keep the previous vertices** for that buffer. :contentReference[oaicite:10]{index=10}
3) **Row update**: `on_vertices_row(row_start, row_count, verts, count, flags)`  
   - Used for very fast partial redraw; treat `row_start..row_start+row_count` as the affected band. :contentReference[oaicite:11]{index=11}

**Claude rule:** when changing core output behavior, update the corresponding frontend handling and keep the “keep previous vertices when not flagged” rule correct.

### Layout updates
Frontends must notify the core with drawable size and cell size in *pixels* so core can compute rows/cols and resize Neovim appropriately. :contentReference[oaicite:12]{index=12}

## Performance rules (read before editing hot paths)

1) **No allocations on the redraw/flush hot path** unless there is an explicit, measured reason.
   - Prefer persistent buffers, `ArrayList` with `ensureTotalCapacity`, “keepCapacity”, ring buffers, or fixed arenas with bounded lifetime.
2) **Minimize cross-thread contention.**
   - Prefer single-producer/single-consumer patterns; avoid holding locks while doing heavy work.
3) **Avoid per-cell/per-glyph overhead at frame time.**
   - Cache glyph metrics and atlas entries; batch work by rows/spans/runs.
4) **Dirty region correctness > micro-optimizations.**
   - Partial redraw must never produce undefined contents (e.g., if the backend requires full-present, keep a persistent back buffer).
5) **Measure first, then optimize.**
   - When you change the rendering pipeline, include a short note in the PR describing what you measured (FPS, frame time, CPU usage, allocations).

## Neovim api-ui compliance checklist

When implementing or modifying any redraw handling:

- Correctly handle `grid_*` events and multi-grid scenarios (if supported).
- Ensure `flush` semantics: all prior updates are visible after flush; dirty flags reset only after successful submission. (See flush handling patterns.) :contentReference[oaicite:13]{index=13}
- Respect options that affect rendering/layout:
  - `guifont` notifications (frontend applies font name + size) :contentReference[oaicite:14]{index=14}
  - `linespace` extra line spacing (frontend applies pixel delta) :contentReference[oaicite:15]{index=15}
- Cursor rendering must match Neovim semantics (shape, color, percent).
- Input must map to Neovim expectations (key events + modifiers).

## Build / run (developer-friendly defaults)

### Zig core + Windows frontend
- Build core + Windows app:
  - `zig build windows -Dtarget=x86_64-windows-gnu`

### macOS frontend
- Build core + MacOS pp:
  - `xcodebuild -project macos/zonvie.xcodeproj -scheme zonvie -configuration Debug -derivedDataPath macos/.derived -destination "platform=macOS,arch=arm64" build`


## Coding conventions

- **Comments must be in English.**
- Prefer small, composable functions and explicit data flow.
- Be explicit about units in names:
  - `_px`, `_pt`, `_rows`, `_cols`, `26_6` (for HarfBuzz/FreeType fixed-point).
- Keep platform conditionals isolated to frontends; do not leak AppKit/Win32 types into shared core.

## Zig version and compatibility

- Keep Zig code compatible with the project’s target Zig toolchain (assume **Zig 0.15.x**).
- When you provide/modify Zig code, ensure it builds with the current `build.zig` and does not introduce toolchain-specific features without a fallback.

## When you’re unsure

If you’re about to change something that affects correctness or ABI stability, stop and:
- find the relevant contract in `include/zonvie_core.h`
- verify how both macOS and Windows consume it
- keep old behavior working unless the change is coordinated across all frontends

(ABI and callback contracts are the "source of truth", not assumptions in one frontend.)
