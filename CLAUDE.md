# CLAUDE.md

You are working in Zonvie, a high-performance Neovim GUI.

See `README.md` for product overview and `DEVELOPMENT.md` for detailed build/setup steps.

## Project Priorities

- Preserve correctness of the Neovim `ui` API first.
- Preserve the core/frontend ABI contract in `include/zonvie_core.h`.
- Optimize for low-latency rendering and predictable frame time.
- Do not add allocations to redraw/flush hot paths unless the change is explicitly justified and measured.
- Keep platform-specific UI details in frontends; keep shared behavior in the Zig core.

## Think Before Coding

- State assumptions explicitly; ask for clarification when the request is ambiguous.
- When the request has multiple plausible interpretations, present them rather than silently picking one.
- If a simpler approach exists, propose it before implementing the requested one.
- Stop and name confusion rather than proceeding with ambiguity.

## Simplicity First

- Do not add features that were not requested.
- Do not introduce abstractions for code used in only one place.
- Do not add configurability or flexibility before there is a concrete second caller.
- Do not handle errors for scenarios that cannot occur.
- If 200 lines could be 50, rewrite it. The test: would a senior engineer call this overcomplicated?

## Surgical Changes

- Do not improve adjacent code, comments, or formatting that the request did not touch.
- Do not refactor working code as a side effect of another change.
- Match existing style conventions.
- Remove only the imports, variables, and functions that your own changes orphaned. Preserve pre-existing dead code unless explicitly asked to remove it.
- Every changed line should trace directly to the user's request.

## Goal-Driven Execution

- Translate vague requests into verifiable outcomes:
  - "Add validation" → write tests for invalid inputs, then make them pass.
  - "Fix the bug" → reproduce it with a test, then make the test pass.
- For multi-step work, state a brief plan and an explicit verification step after each phase.

## Rules That Must Not Be Broken

- For behavior that is not fully specified in `include/zonvie_core.h`, verify the corresponding Zig core implementation and both frontend consumers.
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

## Neovim UI Compliance

When changing redraw or layout handling, verify the affected events against the callback contracts in `include/zonvie_core.h` and the Neovim UI spec. `flush` must only clear dirty state after successful submission.

## Conventions

- Comments must be in English.
- Use explicit unit suffixes in names where relevant: `_px`, `_pt`, `_rows`, `_cols`, `26_6`.

## Build / Test

Common commands:
- `zig build`
- `zig build test`
- `zig build windows -Dtarget=x86_64-windows-gnu`
- `xcodebuild -project macos/zonvie.xcodeproj -scheme zonvie -configuration Debug -derivedDataPath macos/.derived -destination "platform=macOS,arch=arm64" build`
