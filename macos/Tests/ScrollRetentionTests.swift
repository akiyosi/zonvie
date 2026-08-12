import Foundation
import Metal

// Minimal collaborators required when MetalTypes.swift is compiled as a
// standalone test executable. Same shape as SurfaceRowProvisionTests', and for
// the same reason: the file's fixed-float mask and scroll-offset builders name
// types owned by MetalTerminalRenderer, which the retention does not touch.
final class ZonvieConfig {
    static let shared = ZonvieConfig()
    var backgroundAlpha: Float = 1.0
}

final class MetalTerminalRenderer {
    struct ScrollOffset {
        var grid_id: Int32
        var offset_y: Float
        var content_top_y: Float
        var content_bottom_y: Float
        var move_all: Int32 = 0
        var pin_edges: Int32 = 1
        var zindex: Int32 = 0
    }

    struct FixedFloatRect: Equatable {
        var x0: Float
        var x1: Float
        var top: Float
        var bottom: Float
        var zindex: Int32
    }

    struct FixedFloatBand {
        var top: Float
        var bottom: Float
        var intervalStart: UInt32
        var intervalCount: UInt32
    }

    struct FixedFloatInterval {
        var x0: Float
        var x1: Float
        var z: Float = 0
    }
}

/// ScrollRetention keeps the rows a scroll pushed off the window edge so the
/// band a sub-cell offset opens shows the content that left instead of the edge
/// row's background stretched over it. Every regression in it so far was found
/// by scrolling on hardware; these are the parts that need not have been.
@main
private enum ScrollRetentionTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func requireEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
        require(got == want, "\(message) (got \(got), want \(want))")
    }

    private static func makeRow(
        _ retention: ScrollRetention,
        gridId: Int64,
        targetRow: Int
    ) -> RetainedScrollRow {
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

    /// Which rows leave through which edge, and how far back they must be drawn.
    private static func verifyPlan() {
        // Scrolling down: the rows at the top leave through the top.
        guard let down = ScrollRetention.plan(rowStart: 0, rowEnd: 10, rowsDelta: 3, depth: 4) else {
            require(false, "a three-row scroll produced no plan")
            return
        }
        requireEqual(down.count, 3, "every moved row is kept while depth allows")
        requireEqual(down.first, 0, "the outgoing rows start at the region top")
        // planRow walks the far edge first, so stage()'s front-drop clamp sheds
        // the rows the band loses first.
        requireEqual(ScrollRetention.planRow(down, 0, rowsDelta: 3), 0, "first planned row")
        requireEqual(ScrollRetention.planRow(down, 2, rowsDelta: 3), 2, "last planned row")

        guard let up = ScrollRetention.plan(rowStart: 0, rowEnd: 10, rowsDelta: -2, depth: 4) else {
            require(false, "an upward scroll produced no plan")
            return
        }
        requireEqual(up.count, 2, "upward row count")
        requireEqual(up.first, 8, "an upward scroll retains from the region bottom")

        // More rows moved than can be held: keep the ones next to the edge they
        // left through, since those are the ones the band shows first.
        guard let clamped = ScrollRetention.plan(rowStart: 0, rowEnd: 20, rowsDelta: 7, depth: 3) else {
            require(false, "a clamped scroll produced no plan")
            return
        }
        requireEqual(clamped.count, 3, "a plan keeps at most depth rows")
        requireEqual(clamped.first, 4, "a clamped plan keeps the rows nearest the edge")

        require(
            ScrollRetention.plan(rowStart: 0, rowEnd: 10, rowsDelta: 0, depth: 4) == nil,
            "no movement must produce no plan"
        )
        require(
            ScrollRetention.plan(rowStart: 0, rowEnd: 5, rowsDelta: 5, depth: 4) == nil,
            "a scroll of the whole region leaves nothing on screen to retain"
        )
    }

    /// Whether the retained rows cover the band, which is what allows the edge
    /// stretch to be suppressed. Getting this wrong either paints over the
    /// retained rows or leaves a gap.
    private static func verifyCoversBand() {
        let cell: Float = 0.04
        require(
            ScrollRetention.coversBand(retainedRows: 3, offsetNDC: 0.10, cellHeightNDC: cell),
            "three rows cover a band under three rows wide"
        )
        require(
            !ScrollRetention.coversBand(retainedRows: 2, offsetNDC: 0.10, cellHeightNDC: cell),
            "two rows do not cover a three-row band"
        )
        require(
            !ScrollRetention.coversBand(retainedRows: 0, offsetNDC: 0.01, cellHeightNDC: cell),
            "nothing retained covers nothing"
        )
        require(
            ScrollRetention.coversBand(retainedRows: 1, offsetNDC: 0.04, cellHeightNDC: cell),
            "an exact one-row band is covered by one row"
        )
    }

    /// staged -> published only ever happens through a bracket's own commit.
    private static func verifyStagingLifecycle(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        require(retention.commit(), "commit must report that the bracket staged something")
        requireEqual(retention.publishedCount(gridId: 2), 1, "the staged row is published")

        // A bracket that stages nothing must not clear what is on screen.
        retention.beginFlush()
        require(!retention.commit(), "an empty bracket must report that it staged nothing")
        requireEqual(
            retention.publishedCount(gridId: 2), 1,
            "an empty bracket must leave the published rows alone"
        )
    }

    /// A bracket that aborts describes vertices that never reached the screen.
    private static func verifyAbortDiscardsStaged(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        // The abort: the next bracket opens without a commit in between.
        retention.beginFlush()
        require(!retention.commit(), "an aborted bracket's rows must not be published")
        requireEqual(
            retention.publishedCount(gridId: 2), 0,
            "nothing survives a bracket that did not commit"
        )
    }

    /// 'scrollbind' (:vert diffsplit) moves two windows from one gesture, and
    /// both need their band filled. A step describes one grid, so opening a
    /// second one must leave the first grid's rows where they are.
    private static func verifyGridsAreIndependent(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        retention.beginStep(gridId: 3, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 3, targetRow: 0))
        _ = retention.commit()
        requireEqual(retention.publishedCount(gridId: 2), 1, "the first grid keeps its rows")
        requireEqual(retention.publishedCount(gridId: 3), 1, "the second grid gets its own")

        // And the depth is per grid, not shared between them.
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        for row in 0..<5 { retention.stage(makeRow(retention, gridId: 2, targetRow: row)) }
        retention.beginStep(gridId: 3, rowsDelta: 1, pivotTargetRow: 0)
        for row in 0..<5 { retention.stage(makeRow(retention, gridId: 3, targetRow: row)) }
        _ = retention.commit()
        requireEqual(retention.publishedCount(gridId: 2), 3, "first grid holds a full depth")
        requireEqual(retention.publishedCount(gridId: 3), 3, "second grid holds a full depth")
    }

    /// A step must not drag another grid's rows along with it: they describe
    /// content that did not move, and shifting them draws them off real text.
    private static func verifyStepLeavesOtherGridsInPlace(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 5))
        // A step for another grid, three rows in the opposite direction.
        retention.beginStep(gridId: 3, rowsDelta: -3, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 3, targetRow: 0))
        _ = retention.commit()
        let rows = retention.snapshotPublished()
        guard let kept = rows.first(where: { $0.gridId == 2 }) else {
            require(false, "the untouched grid's row survived")
            return
        }
        requireEqual(kept.targetRow, 5, "the untouched grid's row stayed where it was")
    }

    /// The ring is the only thing keeping a retained buffer alive, so the grid
    /// count it is sized for has to be an enforced limit and not a hope. The
    /// least recently stepped grid loses its rows.
    private static func verifyGridCountIsCapped(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(2)
        retention.beginFlush()
        // One more grid than the cap allows, derived so raising the cap does
        // not silently turn this into a test that never evicts anything.
        let newest = Int64(ScrollRetention.maxRetainedGrids) + 2
        let grids: [Int64] = Array(Int64(2)...newest)
        for grid in grids {
            retention.beginStep(gridId: grid, rowsDelta: 1, pivotTargetRow: 0)
            retention.stage(makeRow(retention, gridId: grid, targetRow: 0))
        }
        _ = retention.commit()

        var held = 0
        for grid in grids where retention.publishedCount(gridId: grid) > 0 { held += 1 }
        requireEqual(held, ScrollRetention.maxRetainedGrids, "at most maxRetainedGrids keep rows")
        requireEqual(
            retention.publishedCount(gridId: 2), 0,
            "the least recently stepped grid is the one dropped"
        )
        requireEqual(retention.publishedCount(gridId: newest), 1, "the newest grid keeps its rows")

        // Stepping a grid again makes it the most recent, so it survives the
        // next eviction rather than being dropped for its original position.
        retention.beginFlush()
        retention.beginStep(gridId: 3, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 3, targetRow: 0))
        retention.beginStep(gridId: newest + 1, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: newest + 1, targetRow: 0))
        _ = retention.commit()
        // Rows carried over from the previous commit are re-seeded alongside
        // the new one, so what matters here is that any survive at all.
        require(retention.publishedCount(gridId: 3) > 0, "a re-stepped grid is not evicted")
        requireEqual(retention.publishedCount(gridId: 4), 0, "the next least recent goes instead")
    }

    /// The cap has to hold across brackets that abort. Eviction drops a grid
    /// from `staged`, but its rows leave `published` only at a commit — so a
    /// bracket that aborts leaves rows for a grid the order no longer names,
    /// and the next bracket seeds them back in as a grid nothing will evict.
    private static func verifyCapSurvivesAbortedBrackets(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(2)

        func step(_ grids: [Int64]) {
            for grid in grids {
                retention.beginStep(gridId: grid, rowsDelta: 1, pivotTargetRow: 0)
                retention.stage(makeRow(retention, gridId: grid, targetRow: 0))
            }
        }

        // Two more grids than the cap allows, so the two least recent (2 and 3)
        // are evicted. Derived from the cap for the reason above.
        let last = Int64(ScrollRetention.maxRetainedGrids) + 3
        retention.beginFlush()
        step(Array(Int64(2)...last))
        _ = retention.commit()

        // Two brackets that stage and then abort (the next beginFlush is the
        // abort), leaving 2 and 3 named by the order but holding nothing.
        retention.beginFlush()
        step([2, 3])
        retention.beginFlush()
        step([4, 5])
        retention.beginFlush()
        step([last + 1])
        _ = retention.commit()

        var held = 0
        for grid in Int64(2)...(last + 1) where retention.publishedCount(gridId: grid) > 0 {
            held += 1
        }
        require(
            held <= ScrollRetention.maxRetainedGrids,
            "grids holding rows after an aborted bracket: \(held), cap is \(ScrollRetention.maxRetainedGrids)"
        )
    }

    /// The ring is the only thing keeping a retained buffer alive, so it must
    /// be strictly larger than the buffers that can be live at once: the
    /// published set, the set being staged, and one snapshot per in-flight
    /// frame. External surfaces allow two frames.
    private static func verifyRingOutlivesTheLiveSet() {
        let perSet = ScrollRetention.maxRetainedGrids * ScrollRetention.maxDepthRows
        let live = perSet * (1 /* published */ + 1 /* staging */ + ScrollRetention.maxInFlightFrames)
        require(
            ScrollRetention.ringSize > live,
            "ringSize \(ScrollRetention.ringSize) must exceed the \(live) buffers that can be live at once"
        )
    }

    /// The credit rule. Two kinds of grid, two rules — keyed on whether the
    /// grid books scrolls, not on whether its booking happens to be empty.
    private static func verifyCreditRule() {
        let h: CGFloat = 40
        let step = 3
        let eps: CGFloat = 1

        func credit(
            _ held: CGFloat, booked: Int, delta: Int, bound: Bool = false
        ) -> CGFloat? {
            ScrollRetention.creditedOffsetPx(
                heldPx: held, bookedRows: booked, rowsDelta: delta,
                rowHeightPx: h, stepRows: step, bound: bound, epsilonPx: eps
            )
        }

        // Driver: the booking bounds the credit, and settling drops the entry.
        require(credit(120, booked: 3, delta: -3) == nil, "driver settles on the cell grid")
        requireEqual(credit(30, booked: 3, delta: -3), -90, "driver keeps the finger's residue")
        requireEqual(credit(120, booked: 3, delta: -1), 80, "driver at a buffer edge")
        // The driver's booking also empties mid-gesture on a wrapped scroll —
        // there the deepen rule is what stops the over-report running away.
        requireEqual(credit(-45, booked: 0, delta: -12), -45, "driver's over-report may not deepen")

        // Bound: the report is the only account, so it may deepen — capped.
        requireEqual(credit(-5, booked: 0, delta: -3, bound: true), -120, "bound deepens from near zero")
        requireEqual(credit(0, booked: 0, delta: -3, bound: true), -120, "bound from rest")
        requireEqual(credit(-120, booked: 0, delta: -3, bound: true), -120, "bound holds at the ceiling")
        requireEqual(credit(100, booked: 0, delta: -3, bound: true), -20, "bound crosses zero")
        requireEqual(credit(0, booked: 0, delta: -12, bound: true), -120, "bound over-report bounded")

        // The invariant the whole rule exists for: a bound window is never told
        // its content moved and then left with the same compensation.
        for heldTicks in -40...40 {
            for delta in -12...12 where delta != 0 {
                let held = CGFloat(heldTicks) * 5
                guard let got = credit(held, booked: 0, delta: delta, bound: true) else { continue }
                let ceiling = h * CGFloat(step)
                require(
                    got != held || abs(held) >= ceiling - 0.001,
                    "bound window uncompensated at held \(held), delta \(delta)"
                )
            }
        }
    }

    /// A bound window is only recognised once its first scroll shares a batch
    /// with the driver's, by which time the finger has banked a round trip's
    /// travel it was never paid. Starting it from zero leaves the two panes of
    /// a diff a fraction of a row apart for the rest of the gesture, so the
    /// banked value has to reach the credit — not just the dictionary.
    private static func verifyBoundWindowStartsFromTheDriver() {
        let h: CGFloat = 40
        // The driver banked this much finger travel before the first arrival,
        // and booked one wheel event for it.
        let banked: CGFloat = 30

        let driver = ScrollRetention.creditedOffsetPx(
            heldPx: banked, bookedRows: 3, rowsDelta: -3,
            rowHeightPx: h, stepRows: 3, bound: false, epsilonPx: 1
        )
        let seeded = ScrollRetention.creditedOffsetPx(
            heldPx: banked, bookedRows: 0, rowsDelta: -3,
            rowHeightPx: h, stepRows: 3, bound: true, epsilonPx: 1
        )
        let unseeded = ScrollRetention.creditedOffsetPx(
            heldPx: 0, bookedRows: 0, rowsDelta: -3,
            rowHeightPx: h, stepRows: 3, bound: true, epsilonPx: 1
        )
        require(
            seeded != unseeded,
            "seeding must change the credit (got \(String(describing: seeded)) either way)"
        )
        // The point of seeding: the two panes land in the same place.
        requireEqual(seeded, driver, "a seeded bound window lands where the driver does")
        require(
            unseeded != driver,
            "without the seed the panes would not have differed, so this test proves nothing"
        )
    }

    /// Eviction has to be reported. The renderer stands the row-scroll fast
    /// path down for a grid the notification path already retained; standing
    /// down for one whose rows the cap has just thrown away would leave that
    /// window with neither a retained row nor a fast-path capture.
    private static func verifyEvictionIsReported(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(2)
        retention.beginFlush()

        var evicted: [Int64] = []
        retention.takeEvictedGrids(into: &evicted)
        require(evicted.isEmpty, "nothing evicted before the cap is reached")

        // Exactly the cap, derived so raising it does not turn this into a test
        // that never reaches an eviction at all.
        let atCap = Int64(ScrollRetention.maxRetainedGrids) + 1
        for grid in Int64(2)...atCap {
            retention.beginStep(gridId: grid, rowsDelta: 1, pivotTargetRow: 0)
            retention.stage(makeRow(retention, gridId: grid, targetRow: 0))
        }
        retention.takeEvictedGrids(into: &evicted)
        require(evicted.isEmpty, "at the cap, still nothing evicted")

        retention.beginStep(gridId: atCap + 1, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: atCap + 1, targetRow: 0))
        retention.takeEvictedGrids(into: &evicted)
        requireEqual(evicted, [2], "the grid whose rows were dropped is named")

        // Taking clears the record.
        evicted.removeAll()
        retention.takeEvictedGrids(into: &evicted)
        require(evicted.isEmpty, "the record is cleared by taking it")
    }

    /// A retained row is only meaningful while its grid is displaced.
    private static func verifyPrune(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        _ = retention.commit()
        retention.prunePublished { $0.gridId == 2 }
        requireEqual(
            retention.publishedCount(gridId: 2), 0,
            "prunePublished drops what the caller can no longer place"
        )
    }

    /// The depth is what the ease can reach, so it bounds a single step.
    private static func verifyDepthClamp(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(2)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        for row in 0..<5 {
            retention.stage(makeRow(retention, gridId: 2, targetRow: row))
        }
        _ = retention.commit()
        requireEqual(retention.publishedCount(gridId: 2), 2, "a step keeps at most depth rows")
    }

    static func main() {
        verifyPlan()
        verifyCoversBand()
        verifyRingOutlivesTheLiveSet()
        verifyCreditRule()
        verifyBoundWindowStartsFromTheDriver()

        guard let device = MTLCreateSystemDefaultDevice() else {
            // Headless CI without a GPU: the arithmetic above still ran.
            print("ScrollRetentionTests: OK (no Metal device; staging tests skipped)")
            return
        }
        verifyStagingLifecycle(device: device)
        verifyAbortDiscardsStaged(device: device)
        verifyGridsAreIndependent(device: device)
        verifyStepLeavesOtherGridsInPlace(device: device)
        verifyGridCountIsCapped(device: device)
        verifyCapSurvivesAbortedBrackets(device: device)
        verifyEvictionIsReported(device: device)
        verifyPrune(device: device)
        verifyDepthClamp(device: device)
        print("ScrollRetentionTests: OK")
    }
}
