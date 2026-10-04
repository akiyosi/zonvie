// Design quality implementation roadmap (from 10-agent code review)
// Commits track Phase 1-3. This file tracks Phase 4-5 pending work.

// Phase 4 (MEDIUM) — Test Coverage Expansion:
//
// TODO: cursor-only callback test
//   Test: ZONVIE_VERT_UPDATE_CURSOR flag set → row contents retained
//   File: test/... (new cursor_only_callback_test.zig)
//   Effect: Verifies cursor layer independence (CONTRACT: cursor must not replace row)
//
// TODO: grid_line state corruption test
//   Test: Multiple consecutive grid_line → state coherency maintained
//   File: test/... (new grid_line_state_test.zig)
//   Effect: Detects partial commit failures in redraw batch
//
// TODO: pixel parity test integration
//   Current: test/gui/scenarios/visual/partial_matches_full_*.zig (partial)
//   TODO: Integrate to main branch; expand edge cases
//   Effect: Verify full-redraw == partial-redraw pixel output
//
// TODO: vertex budget cascade test
//   Test: Consecutive vertex budget overflow → recovery path correct
//   File: test/... (new vertex_budget_cascade_test.zig)
//   Effect: Ensures ledger consistency after overflow retry
//
// TODO: UTF-8 malformed input test
//   Test: Invalid UTF-8 sequences → extractAllCodepoints() handles gracefully
//   Spec: Neovim wire protocol requires malformed → U+FFFD substitution
//   File: test/... (extend redraw_handler_test.zig)
//   Effect: Input handling robustness

// Phase 5 (MEDIUM) — Frontend Validation + Performance:
//
// TODO: macOS GridSurfaceRenderer transform cache invalidation
//   Location: macos/Sources/Rendering/GridSurfaceRenderer.swift
//   Change: on_grid_destroy() must invalidate cached layer transforms
//   Effect: Prevents stale transform cache → coordinate misalignment
//   Risk: Coordinate corruption (grid destroy→recycle race)
//
// TODO: Windows concurrent grid_id lookup protection
//   Location: windows/callbacks.zig, resolveGridRouteLocked()
//   Change: Extend app.mu lock scope or add grid route reference counting
//   Effect: Thread-safe grid lookup during concurrent destroy/create
//   Risk: Use-after-free (external window cursor position)
//
// TODO: config.toml isolation for profiling
//   Setup: XDG_CONFIG_HOME isolation; verify config→logging behavior isolated
//   Measurement: perf variance 6-12% → 2-3% achieved
//   File: build.zig or profiling docs
//   Effect: Reliable performance measurements; logging doesn't pollute results

// Summary:
// - Phase 1-3: Precondition clarity + pure function extraction + encapsulation (DONE)
// - Phase 4-5: Test expansion + frontend hardening (ROADMAP)
// - Estimated completion: 1-2 weeks
// - Total 15 recommendations from Zig design quality survey
