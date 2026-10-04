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

// Phase 6-8 Implementation Roadmap
// =================================
//
// Phase 6 (HIGH) — Testability Final Optimization & Release Prep:
//
// TODO: Phase 4 test expect()実装（1週間）
//   Test: cursor-only callback, grid_line state, partial redraw, vertex budget cascade, UTF-8
//   Effect: スタブから実装テンプレートへ完全化、検証可能性向上
//
// TODO: computeScrollableRange() 純粋関数抽出（3日）
//   Location: flush.zig setViewportRowDecoFlags()から計算部分分離
//   Effect: Testability +30pt、隔離度向上
//
// TODO: viewportCellScrollable() 公開関数化検討（2日）
//   Location: flush.zig → pub fn化、ドキュメント拡張
//   Effect: performance-sensitive caller の直接利用可能
//
// TODO: Profiling isolation 検証（2日）
//   Setup: XDG_CONFIG_HOME=/tmp/zonvie_profile_$$ でconfig隔離
//   Measurement: perf variance 6-12% → 2-3% 達成確認
//
// Phase 7 (MEDIUM) — Technology Debt Reduction (3-4 weeks):
//
// TODO: Paired Assertions caller-side check拡張（3週間）
//   Target: redraw_handler.zig 32関数、flush_helpers 12関数
//   Effect: Assertion Coverage 68 → 82/100 (+14pt)
//   Validation: Neovim RPC invariant detection +20%
//
// TODO: Recovery Action Strategy Implementation（1.5-2週間）
//   Target: PerCallback/PerSurface/Aggregate各種の handler
//   Effect: Operational precision +18pt、recovery reliability +25%
//   Integration: Error Context 3種化との統合
//
// TODO: ロック保持下の間接副作用隔離（2-3日）
//   Target: grid.sub_grids.getPtr()反復中の状態変更
//   Effect: 副作用隔離 +4-6pt
//   Pattern: Borrowed reference + validation guard
//
// Phase 8 (LONG-TERM) — Architectural Improvements (4-8+ weeks):
//
// TODO: Surface Unification macOS ↔ Windows（3-4週間）
//   Target: draw backend統一、OS固有コード削減
//   Effect: 保守性 +20pt、バグ減少 30%
//   Dependencies: Per-grid damage fixes、shader harmonization
//
// TODO: Instanced Rendering拡張 Windows（2-3週間）
//   Target: macOS完了、Windows Phase D実装
//   Effect: 性能向上 15-20%
//   Branch: feature/instanced-rendering
//
// TODO: GridMutexGuard Type-Safety（15-20行）
//   Target: grid_mu ロック忘却の型システム防止
//   Effect: Contract Clarity +5-8pt、Runtime Safety +12pt
//   Pattern: Zig comptime validation
//
// Summary:
// - Phase 1-3: Precondition clarity + pure function extraction + encapsulation (DONE - 4593d9d)
// - Phase 4-5: Error Context 3種化 + 計算部分抽出（DONE - 06bebce）
// - Phase 6: テスト実装完成 + Testability最適化（2026-11-01 target）
// - Phase 7: Technology Debt削減（Paired Assertions + Recovery Strategy）
// - Phase 8: Architectural改善（Surface unification + Instanced rendering）
//
// Total fixes: 18 (Phase 1-5) + 12+ (Phase 6-8) = 30+
// Design quality score trajectory:
//   - Initial: 38/100
//   - After Phase 1-5: 82.5/100 (+117%)
//   - After Phase 6: 88/100 (estimated)
//   - After Phase 7: 94/100 (estimated)
//   - Phase 8+: 96+/100 (continuous improvement)
//
// Target completion: 2026-12-31（Phase 8）
// Merge status: ✅ GO (Risk: LOW) - Phase 6 interim gate
//
// Multi-session implementation plan:
// - Session 1 (current): Phase 1-5 implementation + Phase 6-8 planning (COMPLETE)
// - Session 2: Phase 6 redraw_handler Contract doc + Tier A completion
// - Session 3: Phase 7 Paired Assertions + Recovery strategy
// - Session 4+: Phase 8 Surface unification + Instanced rendering
