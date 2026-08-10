// Unit tests for ScrollRetention, the smooth-scroll retained-row store.
//
// Run: test/swift/run.sh   (compiles the real MetalTypes.swift, not a copy)
//
// This is the first Swift-side test in the repo. The retention math and its
// single-grid semantics had no automated cover at all, and every regression in
// it so far was found by scrolling on hardware.

import Foundation
import Metal

@main
struct ScrollRetentionTests {
    static var failures = 0


    static func check(_ condition: Bool, _ what: String) {
        if condition {
            print("ok   \(what)")
        } else {
            print("FAIL \(what)")
            Self.failures += 1
        }
    }

    static func checkEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
        check(got == want, "\(what) (got \(got), want \(want))")
    }


    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("FAIL no Metal device")
            exit(1)
        }

    // ── plan: which rows leave, and where they must be drawn ──────────────────

    // Scrolling down by 3 in rows 0..<10: the top three leave through the top.
    if let plan = ScrollRetention.plan(rowStart: 0, rowEnd: 10, rowsDelta: 3, depth: 4) {
        checkEqual(plan.count, 3, "plan down: keeps every moved row within depth")
        checkEqual(plan.first, 0, "plan down: first outgoing row")
        // planRow walks far-edge first so stage()'s front-drop clamp sheds the
        // rows the band loses first.
        checkEqual(ScrollRetention.planRow(plan, 0, rowsDelta: 3), 0, "plan down: row 0")
        checkEqual(ScrollRetention.planRow(plan, 2, rowsDelta: 3), 2, "plan down: row 2")
    } else {
        check(false, "plan down: produced a plan")
    }

    // Scrolling up by 2: the bottom two leave through the bottom.
    if let plan = ScrollRetention.plan(rowStart: 0, rowEnd: 10, rowsDelta: -2, depth: 4) {
        checkEqual(plan.count, 2, "plan up: row count")
        checkEqual(plan.first, 8, "plan up: first outgoing row")
    } else {
        check(false, "plan up: produced a plan")
    }

    // More rows moved than the retention can hold: keep the ones adjacent to the
    // edge they left through, drop the rest.
    if let plan = ScrollRetention.plan(rowStart: 0, rowEnd: 20, rowsDelta: 7, depth: 3) {
        checkEqual(plan.count, 3, "plan clamped to depth")
        checkEqual(plan.first, 4, "plan clamped: keeps the rows nearest the edge")
    } else {
        check(false, "plan clamped: produced a plan")
    }

    check(ScrollRetention.plan(rowStart: 0, rowEnd: 10, rowsDelta: 0, depth: 4) == nil,
          "plan: no movement, no plan")
    check(ScrollRetention.plan(rowStart: 0, rowEnd: 5, rowsDelta: 5, depth: 4) == nil,
          "plan: a scroll of the whole region retains nothing")

    // ── coversBand: may the edge stretch be suppressed? ───────────────────────

    let cellNDC: Float = 0.04
    check(ScrollRetention.coversBand(retainedRows: 3, offsetNDC: 0.10, cellHeightNDC: cellNDC),
          "coversBand: three rows cover a band under three rows wide")
    check(!ScrollRetention.coversBand(retainedRows: 2, offsetNDC: 0.10, cellHeightNDC: cellNDC),
          "coversBand: two rows do not cover a three-row band")
    check(!ScrollRetention.coversBand(retainedRows: 0, offsetNDC: 0.01, cellHeightNDC: cellNDC),
          "coversBand: nothing retained covers nothing")
    check(ScrollRetention.coversBand(retainedRows: 1, offsetNDC: 0.04, cellHeightNDC: cellNDC),
          "coversBand: an exact one-row band is covered by one row")

    // ── staging lifecycle ─────────────────────────────────────────────────────

    func makeRow(_ retention: ScrollRetention, gridId: Int64, targetRow: Int) -> RetainedScrollRow {
        let buffer = retention.takeBuffer(needed: MemoryLayout<Vertex>.stride)!
        return RetainedScrollRow(
            buffer: buffer,
            count: 1,
            gridId: gridId,
            sourceRow: targetRow,
            targetRow: targetRow,
            cellHeightPx: 20
        )
    }

    do {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        check(retention.commit(), "commit reports that a bracket staged something")
        checkEqual(retention.publishedCount(gridId: 2), 1, "published after commit")

        // A bracket that stages nothing must not clear what is on screen.
        retention.beginFlush()
        check(!retention.commit(), "commit reports an empty bracket")
        checkEqual(retention.publishedCount(gridId: 2), 1, "an empty bracket keeps the published rows")
    }

    do {
        // A bracket that aborts instead of committing leaves nothing staged behind.
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        retention.beginFlush() // the abort: the next bracket opens without a commit
        check(!retention.commit(), "an aborted bracket's rows are discarded")
        checkEqual(retention.publishedCount(gridId: 2), 0, "nothing published from an aborted bracket")
    }

    do {
        // Only one grid is retained at a time: a second grid's step in the same
        // bracket replaces the first grid's rows rather than adding to them. The
        // row-scroll fast path relies on this NOT being additive, and a caller
        // expecting two bands filled at once will not get them.
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        retention.beginStep(gridId: 3, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 3, targetRow: 0))
        _ = retention.commit()
        checkEqual(retention.publishedCount(gridId: 3), 1, "the later grid is retained")
        checkEqual(retention.publishedCount(gridId: 2), 0, "the earlier grid's rows are dropped")
    }

    do {
        // A row is only meaningful while its grid is displaced.
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        _ = retention.commit()
        retention.prunePublished { $0.gridId == 2 }
        checkEqual(retention.publishedCount(gridId: 2), 0, "prunePublished drops what the caller cannot place")
    }

    do {
        // The depth bounds what a single step keeps.
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(2)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        for row in 0..<5 { retention.stage(makeRow(retention, gridId: 2, targetRow: row)) }
        _ = retention.commit()
        checkEqual(retention.publishedCount(gridId: 2), 2, "a step keeps at most `depth` rows")
    }

    print(Self.failures == 0 ? "PASS" : "FAIL (\(Self.failures))")
    exit(Self.failures == 0 ? 0 : 1)
    }
}
