# CLAUDE.md

You are working in Zonvie, a high-performance Neovim GUI.

See @README.md for product overview and @DEVELOPMENT.md for detailed build/setup steps.

## Project Priorities

- Preserve correctness of the Neovim `ui` API first.
- Preserve the core/frontend ABI contract in `include/zonvie_core.h`.
- Optimize for low-latency rendering and predictable frame time.
- Do not add allocations to redraw/flush hot paths unless the change is explicitly justified and measured.
- Keep platform-specific UI details in frontends; keep shared behavior in the Zig core.

## Code Areas

- `src/core/`: shared Zig core, Neovim RPC/UI handling, grid state, flush pipeline, C ABI glue
- `include/`: authoritative C ABI and callback contracts
- `macos/`: AppKit + Swift + Metal frontend
- `windows/`: Win32 frontend and renderers
- `test/`: Zig unit tests

## Rules That Must Not Be Broken

- Treat `include/zonvie_core.h` as the source of truth for the public core/frontend ABI.
- For behavior that is not fully specified in the header, verify the corresponding Zig core implementation and both frontend consumers.
- If you change callback semantics, layout behavior, or vertex submission behavior, update all affected frontends in the same change.
- For `on_vertices_partial(...)`, buffers not included in `flags` must keep their previous contents.
- For row updates, preserve partial redraw correctness over micro-optimizations.
- Do not change exported C ABI signatures, struct layouts, callback signatures, or enum values unless the change is coordinated across consumers.

## When Editing Performance-Sensitive Paths

Applies especially to:
- `src/core/flush.zig`
- `src/core/vertexgen.zig`
- `src/core/redraw_handler.zig`
- text shaping / rasterization / atlas code
- `macos/Sources/Rendering/MetalTerminalRenderer.swift` (triple-buffered vertex sets, COW detach)
- `macos/Sources/Font/GlyphAtlas.swift` (double-buffered atlas, two-phase prepare)

Requirements:
- avoid heap work on per-frame or per-cell paths
- prefer persistent buffers and capacity reuse
- avoid adding lock contention to render/input paths
- keep dirty-region behavior correct under partial redraw
- do not create MTLBuffer/MTLTexture objects in per-flush or per-frame paths (IOAccelerator leak risk)
- COW detach pool buffers may alias the committed set; removing the alias guard is safe only when the GPU semaphore guarantees no in-flight read
- if performance-sensitive behavior changes, include a short measurement note in the final summary

## Neovim UI Compliance Checklist

When changing redraw or layout handling, verify:
- `grid_*` events remain correct
- `flush` only clears dirty state after successful submission
- `guifont` and `linespace` behavior still reaches the frontend correctly
- cursor rendering semantics remain correct
- input/modifier mapping still matches Neovim expectations

## Working Style

- Explore the relevant files before editing.
- Prefer the smallest change that preserves existing contracts.
- When touching ABI or shared rendering behavior, inspect both `macos/` and `windows/` consumers before changing code.
- Comments must be in English.
- Use explicit unit suffixes in names where relevant: `_px`, `_pt`, `_rows`, `_cols`, `26_6`.

## Build / Test

Common commands:
- `zig build`
- `zig build test`
- `zig build windows -Dtarget=x86_64-windows-gnu`
- `xcodebuild -project macos/zonvie.xcodeproj -scheme zonvie -configuration Debug -derivedDataPath macos/.derived -destination "platform=macOS,arch=arm64" build`

Before finishing:
- run the narrowest relevant test/build command available
- report what was verified and what was not verified

## Metal Memory Management (macOS)

Key constraints learned from leak investigations:

- Never create and drop uncommitted `MTLCommandBuffer` objects — they leak IOAccelerator GPU memory regions that are never reclaimed.
- Atlas back-texture sync uses a two-phase API: `prepareBackTexture()` returns whether GPU blit is needed; only then create a command buffer and call `encodeBackTextureBlit()`.
- Cursor vertex buffers must NOT be COW-shared across buffer sets — each set owns its own buffer to avoid pool-alias allocation leaks.
- Row vertex buffers reuse pool buffers even when they alias the committed set's buffers, because the GPU semaphore (value=1) guarantees no in-flight draw during flush.
- Atlas textures use `.shared` storage mode (not `.managed`) to avoid Metal internal dirty-region tracking overhead on Apple Silicon.

## If Unsure

- check `include/zonvie_core.h` first
- verify how both frontends consume the behavior
- prefer keeping existing behavior unless the change is intentionally coordinated
