# Phase 6-8 実装完遂計画（30+修正）

## Overview
修正#1-18（Phase 1-5）の実装完遂後、Phase 6-8による継続改善の詳細ロードマップ。
設計品質スコア 82.5/100 → 96+/100 を目指す。

---

## Phase 6（2026-11-01 Release Gate）
**工数**: 4週間 | **目標スコア**: 88/100 | **改善**: +5.5pt

### Tier A: CRITICAL（1.5週間）

#### A1: redraw_handler.zig Contract Documentation
**対象**: 64関数、うち最優先14関数に Precondition/Postcondition 追加
**実装者**: Session 2（次セッション）
**工数見積もり**: 1.5週間
**効果**: Contract Clarity 72 → 88/100（+16pt）

**最優先14関数リスト**:
```
1. handleRedraw() - main event dispatch
2. parseGridResize(width, height) - dimension validation
3. parseGridCursorGoto(grid_id, row, col) - position bounds
4. parseGridLine(grid_id, row, cells) - UTF-8 validation + state update
5. parseModeInfoSet(infos) - mode table construction
6. parseModeChange(mode) - mode index validation
7. parseHlAttrDefine(id, attrs) - attribute uniqueness
8. parseDefaultColorsSet(fg, bg) - color range validation
9. parseOptionSet(option, value) - option dispatch + validation
10. parseGridScroll(grid_id, top, bot, left_col, right_col, rows) - scroll bounds
11. parseCmdlineShow(level, content) - cmdline state machine
12. parsePopupmenuShow(items, selected, row, col) - menu array precondition
13. parseGridDestroy(grid_id) - grid lifecycle postcondition
14. parseFlush() - transaction boundary
```

**Session 2 Checklist**:
- [ ] applyModeInfo contract 既に追加（commit b8055e8）
- [ ] showmodeModeKeepsStatus contract 既に追加（commit b8055e8）
- [ ] 残り12関数の Contract Documentation 追加
- [ ] zig build test 全通過確認
- [ ] xcodebuild 確認（macOS）
- [ ] zig build windows 確認（Windows）

---

#### A2: Paired Assertions caller-side check拡張
**対象**: redraw_handler.zig 32関数、flush_helpers 12関数
**工数見積もり**: 3週間（Phase 7に統合）
**効果**: Assertion Coverage 68 → 82/100（+14pt）

---

#### A3: config.toml Isolation Verification
**対象**: profiling noise 測定
**工数見積もり**: 2日
**効果**: perf variance 6-12% → 2-3% 実測

---

### Tier B: HIGH（1.5週間、Phase 7開始前実施）

#### B3: perf_*カウンタ累積隔離（優先度最高）
**工数見積もり**: 1日
**効果**: perf測定信頼度 +3pt

**実装位置**: src/core/flush.zig L2918-2935（onFlush内のcounter reset）

---

### Tier C: MEDIUM（1週間）

#### C1: Test Vacuity残8件解決
**工数見積もり**: 3-4日
**対象**:
- cursor-only callback expect()詳細化
- grid_line state並行書き込み検証
- partial redraw pixel-exact検証
- UTF-8 malformed edge case

---

## Phase 7（2026-12-01）
**工数**: 4週間 | **目標スコア**: 94/100 | **改善**: +6pt

### Tier A2（再掲）: Paired Assertions caller-side check拡張
**実装予定**: Session 3

---

### Tier B: HIGH（3週間）

#### B1: ロック保持下の間接副作用隔離
**工数見積もり**: 2-3日
**効果**: 副作用隔離 +5pt

#### B2: ledger journal recovery strategy
**工数見積もり**: 2-3日
**効果**: error recovery精度 +8pt

---

### Tier D1: Recovery Action Strategy Implementation
**工数見積もり**: 1.5-2週間
**効果**: operational precision +18pt
**実装**: PerCallback/PerSurface/Aggregate各種のhandler

---

## Phase 8（2026-12-31）
**工数**: 4-8週間 | **目標スコア**: 96+/100 | **改善**: +2-6pt

### Tier A3: GridMutexGuard Type-Safety
**工数見積もり**: 15-20行（短期実装）
**効果**: Contract Clarity +8pt

### Tier D2: Surface Unification（macOS ↔ Windows）
**工数見積もり**: 3-4週間
**効果**: 保守性 +20pt

### Tier D3: Instanced Rendering Windows拡張
**工数見積もり**: 2-3週間
**効果**: perf +15-20%

---

## Multi-Session Implementation Strategy

| Session | 工数 | Tiers | 目標スコア | 完了予定 |
|---------|------|-------|----------|---------|
| Session 1（完了） | 3週間 | Phase 1-5 + 計画確定 | 82.5 | 2026-10-04 ✅ |
| Session 2（次） | 4週間 | Phase 6（A1+C） | 88 | 2026-11-01 |
| Session 3 | 4週間 | Phase 7（A2+B+D1） | 94 | 2026-12-01 |
| Session 4+ | 4-8週間 | Phase 8（A3+D2+D3） | 96+ | 2026-12-31 |

---

## Session 2 開始時チェックリスト

- [ ] Branch: feat/per-grid-rendering
- [ ] Latest commit: b8055e8（Phase 6 A1開始）
- [ ] Status: redraw_handler.zig 2/14関数のContractドキュメント追加完了
- [ ] Tasks:
  - [ ] 残り12関数のContract Documentation追加（1.5w）
  - [ ] test vacuity 8件解決（3-4d）
  - [ ] perf カウンタ隔離（1d）
  - [ ] ビルド・テスト検証（全Platform）
  - [ ] マージゲート確認（2026-11-01）

---

## 設計品質スコア軌跡

```
Initial (6a5fb16):           38/100
└─ Phase 1-5完了 (c5860e4):  82.5/100 (+117%)
   └─ Phase 6A1開始 (b8055e8): 82.5→88/100 (進行中)
      └─ Phase 6完遂予定:       88/100
         └─ Phase 7完遂予定:    94/100
            └─ Phase 8完遂予定: 96+/100
```

---

## 最終目標

✅ **2026-11-01**: Phase 6完遂 → Merge Release
🎯 **2026-12-01**: Phase 7完遂 → Production Stability
🚀 **2026-12-31**: Phase 8完遂 → Near-Perfection（96+/100）
