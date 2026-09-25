import Foundation
import Metal
import simd

// Minimal collaborators required when MetalTypes.swift is compiled as a
// standalone test executable. Same shape as SurfaceRowProvisionTests', and for
// the same reason: the file's fixed-float mask and scroll-offset builders name
// types owned by GridSurfaceRenderer, which the retention does not touch.
final class ZonvieConfig {
    static let shared = ZonvieConfig()
    var backgroundAlpha: Float = 1.0
}

final class GridSurfaceRenderer {
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

    /// The pin is released per grid, for every grid a surface displaces. An
    /// external window used to ask only about its root, so a float it hosts
    /// kept stretching its edge row over the rows it had retained.
    private static func verifyReleaseCoveredPins(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 5, rowsDelta: 3, pivotTargetRow: 0)
        for row in 0..<3 { retention.stage(makeRow(retention, gridId: 5, targetRow: row - 3)) }
        _ = retention.commit()

        let cell: Float = 0.04
        var offsets = [
            // The root: displaced, nothing retained, so it keeps the stretch.
            GridSurfaceRenderer.ScrollOffset(
                grid_id: 4, offset_y: 0.10, content_top_y: 1, content_bottom_y: -1),
            // A hosted float, three rows retained for a band under three rows.
            GridSurfaceRenderer.ScrollOffset(
                grid_id: 5, offset_y: -0.10, content_top_y: 0.2, content_bottom_y: -0.2),
        ]
        retention.releaseCoveredPins(&offsets, cellHeightNDC: cell)
        requireEqual(offsets[0].pin_edges, 1, "a grid with nothing retained keeps its stretch")
        requireEqual(offsets[1].pin_edges, 0, "a hosted grid whose band is covered drops its stretch")

        // Wider than the retention: the uncovered part needs the stretch.
        var wide = [GridSurfaceRenderer.ScrollOffset(
            grid_id: 5, offset_y: 0.13, content_top_y: 0.2, content_bottom_y: -0.2)]
        retention.releaseCoveredPins(&wide, cellHeightNDC: cell)
        requireEqual(wide[0].pin_edges, 1, "a band wider than the retained rows keeps its stretch")
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

    /// The lifetime rule: a published row lives exactly as long as its grid is
    /// displaced. The prune used to run only from the offset rebuild, which the
    /// view skips entirely once nothing is easing, so a grid that scrolled once
    /// kept its rows for the rest of the session — drawn a row off real content
    /// and forcing its layer to redraw every row on every frame.
    private static func verifyUndisplacedPrune(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(2)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        retention.beginStep(gridId: 3, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 3, targetRow: 0))
        _ = retention.commit()

        let displaced = GridSurfaceRenderer.ScrollOffset(
            grid_id: 3, offset_y: 0.04, content_top_y: 1, content_bottom_y: -1
        )
        retention.pruneUndisplaced(offsets: [displaced], seedGrids: [])
        requireEqual(
            retention.publishedCount(gridId: 2), 0,
            "a grid with no scroll offset loses its retained rows"
        )
        requireEqual(
            retention.publishedCount(gridId: 3), 1,
            "a grid that is still displaced keeps them"
        )

        // A step whose ease seed has been committed but not yet spent has no
        // offset yet. Pruning it there would empty the band of the ease that is
        // one main-thread step away from starting.
        retention.beginFlush()
        retention.beginStep(gridId: 4, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 4, targetRow: 0))
        _ = retention.commit()
        retention.pruneUndisplaced(offsets: [], seedGrids: [(gridId: 4, rowsDelta: 1)])
        requireEqual(
            retention.publishedCount(gridId: 4), 1,
            "an unspent ease seed keeps its grid's rows alive"
        )
        retention.pruneUndisplaced(offsets: [], seedGrids: [])
        requireEqual(
            retention.publishedCount(gridId: 4), 0,
            "a seed spent without producing an offset stops keeping them"
        )
    }

    /// A layer the vertex stage moves bodily is drawn at a shifted origin with
    /// no offset bound, so its clip travels with it. The scissor must stay the
    /// layer's own size: floats stack edge to edge, so a widened one would
    /// reach the next float, whose background pass overwrites under blur.
    private static func verifyBodilyMovedLayerShiftsItsOrigin() {
        let height: Float = 1760
        // updateScrollOffsets: offset_y = -offsetYPx * 2 / viewportHeight.
        func ndc(_ px: Float) -> Float { -px * 2 / height }
        let follower = GridSurfaceRenderer.ScrollOffset(
            grid_id: 15, offset_y: ndc(88),
            content_top_y: 2.0, content_bottom_y: -2.0, move_all: 1)

        // Floats in the failing case sat at y = 40, 160, 280 ... exactly three
        // rows apart and three rows tall, so an 88px ease is more than two
        // cells and lands the layer squarely over its neighbour's committed
        // rect. Shifting the origin is what keeps the two apart.
        let moved = displacedLayerOriginPx(
            originPx: simd_float2(0, 160), offset: follower, viewportHeightPx: height)
        require(abs(moved.y - 248) < 0.001,
                "a followed layer's origin carries the displacement (got \(moved.y))")
        requireEqual(moved.x, 0, "displacement is vertical only")

        // The clip is the layer's own extent at the shifted origin: 3 rows of
        // 40px, not one pixel more.
        guard let rect = clampScissor(
            x: 0, y: Int(moved.y), width: 300, height: 120,
            targetWidth: 3348, targetHeight: 1760
        ) else {
            require(false, "a displaced layer still has visible pixels")
            return
        }
        requireEqual(rect.y, 248, "the scissor follows the shifted origin")
        requireEqual(rect.height, 120, "the scissor stays the layer's own height")
        // The float stacked below is displaced by the same amount, so the two
        // must still tile exactly: this scissor ends where that one begins.
        let neighbour = displacedLayerOriginPx(
            originPx: simd_float2(0, 280), offset: follower, viewportHeightPx: height)
        requireEqual(Float(rect.y + rect.height), neighbour.y,
                     "the scissor ends where the float stacked below begins")

        // A sub-pixel ease step: the origin is fractional, and the caller pads
        // one pixel so flooring cannot clip the layer's leading edge.
        let easing = GridSurfaceRenderer.ScrollOffset(
            grid_id: 15, offset_y: ndc(3.90125),
            content_top_y: 2.0, content_bottom_y: -2.0, move_all: 1)
        let sub = displacedLayerOriginPx(
            originPx: simd_float2(0, 160), offset: easing, viewportHeightPx: height)
        require(abs(sub.y - 163.90125) < 0.001, "a sub-pixel step moves by less than a cell")
        require(sub.y != sub.y.rounded(.down), "the ease leaves a fractional origin to pad for")

        // An undisplaced layer must not move at all.
        let still = GridSurfaceRenderer.ScrollOffset(
            grid_id: 15, offset_y: 0, content_top_y: 2.0, content_bottom_y: -2.0, move_all: 1)
        requireEqual(
            displacedLayerOriginPx(originPx: simd_float2(0, 160), offset: still,
                                   viewportHeightPx: height).y,
            160, "a still layer keeps its committed origin")
    }

    /// Which entry a layer's pass binds. A grid with none is not displaced, and
    /// a per-row (non-move_all) grid keeps its entry so the shader still clips
    /// its scrolled rows to its content band.
    private static func verifyScrollOffsetLookup() {
        let offsets = [
            GridSurfaceRenderer.ScrollOffset(
                grid_id: 2, offset_y: -0.1,
                content_top_y: 0.954, content_bottom_y: -0.954),
            GridSurfaceRenderer.ScrollOffset(
                grid_id: 15, offset_y: -0.1,
                content_top_y: 2.0, content_bottom_y: -2.0, move_all: 1),
        ]
        requireEqual(surfaceScrollOffset(gridId: 15, offsets: offsets)?.move_all, 1,
                     "a following float is bodily moved")
        requireEqual(surfaceScrollOffset(gridId: 2, offsets: offsets)?.move_all, 0,
                     "a window keeps the per-row path")
        require(surfaceScrollOffset(gridId: 22, offsets: offsets) == nil,
                "a fixed float past the last entry is not displaced")
        // A missing id BETWEEN two entries is where a lower bound that forgets
        // to check equality hands back its neighbour's displacement.
        require(surfaceScrollOffset(gridId: 10, offsets: offsets) == nil,
                "a fixed float between two entries is not displaced")
        require(surfaceScrollOffset(gridId: 15, offsets: []) == nil,
                "an idle frame displaces nothing")
    }

    /// A float inherits its anchor's landing compensation, but Neovim re-places
    /// the float through its own event, which need not reach the frontend in
    /// the same commit. The debt is what it is carrying in between.
    private static func verifyFloatDebtLedger() {
        // The case that already worked: both halves land together, so nothing
        // is withheld and the existing behaviour is untouched.
        requireEqual(
            floatDebtRowsUp(anchorRowsUp: 3, placementRowsUp: 3,
                            baseline: FloatDebtBaseline(anchorRowsUp: 0, placementRowsUp: 0)),
            0, "a step that lands with its placement is owed nothing")

        // The anchor landed three rows; the float has not been re-placed yet,
        // so it is carrying three rows of compensation it did not earn.
        requireEqual(
            floatDebtRowsUp(anchorRowsUp: 3, placementRowsUp: 0,
                            baseline: FloatDebtBaseline(anchorRowsUp: 0, placementRowsUp: 0)),
            3, "an anchor that landed first leaves the float three rows in debt")

        // The placement arrived first: the float moved before the compensation
        // that pays for it, which is the same defect with the sign reversed.
        requireEqual(
            floatDebtRowsUp(anchorRowsUp: 0, placementRowsUp: 3,
                            baseline: FloatDebtBaseline(anchorRowsUp: 0, placementRowsUp: 0)),
            -3, "a placement that landed first leaves the float three rows ahead")

        // The debt settles once the other half arrives, whichever order.
        requireEqual(
            floatDebtRowsUp(anchorRowsUp: 3, placementRowsUp: 3,
                            baseline: FloatDebtBaseline(anchorRowsUp: 0, placementRowsUp: 0)),
            0, "the debt retires when the pair completes")

        // Both counters run from whenever their own grid appeared, so only the
        // baseline makes them comparable. A float created mid-scroll must start
        // square instead of inheriting the whole history it was absent for.
        requireEqual(
            floatDebtRowsUp(anchorRowsUp: 41, placementRowsUp: 5,
                            baseline: FloatDebtBaseline(anchorRowsUp: 41, placementRowsUp: 5)),
            0, "a float seeded mid-scroll starts out of debt")
        requireEqual(
            floatDebtRowsUp(anchorRowsUp: 44, placementRowsUp: 5,
                            baseline: FloatDebtBaseline(anchorRowsUp: 41, placementRowsUp: 5)),
            3, "and accrues only what happens after it was seeded")

        // A whole gesture of paired steps must not drift.
        var anchor = 0, placement = 0
        let baseline = FloatDebtBaseline(anchorRowsUp: 0, placementRowsUp: 0)
        for _ in 0..<20 {
            anchor += 3
            require(floatDebtRowsUp(anchorRowsUp: anchor, placementRowsUp: placement,
                                    baseline: baseline) == 3,
                    "the split frame owes exactly one step")
            placement += 3
            require(floatDebtRowsUp(anchorRowsUp: anchor, placementRowsUp: placement,
                                    baseline: baseline) == 0,
                    "and settles on the next")
        }
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

    private static func verifyDirtyRowsTravelWithTheShift() {
        // Content moves UP by one: the mark on row 10 describes what is now
        // row 9, and row 9 is what the blit leaves stale.
        var up: IndexSet = [10]
        shiftSurfaceRowIndices(&up, rowStart: 0, rowEnd: 20, rowsDelta: 1)
        require(up.contains(9), "a mark follows its content up the region")
        require(!up.contains(10), "the mark does not stay at the pre-shift row")

        // Content moves DOWN by two.
        var down: IndexSet = [4]
        shiftSurfaceRowIndices(&down, rowStart: 0, rowEnd: 20, rowsDelta: -2)
        require(down.contains(6), "a mark follows its content down the region")
        require(!down.contains(4), "the mark does not stay at the pre-shift row")

        // The band the shift vacated is always redrawn: those rows lost their
        // vertices. Upward shift vacates the bottom, downward the top.
        var vacatedUp = IndexSet()
        shiftSurfaceRowIndices(&vacatedUp, rowStart: 0, rowEnd: 20, rowsDelta: 3)
        requireEqual(vacatedUp.count, 3, "an upward shift vacates three rows")
        require(vacatedUp.contains(17) && vacatedUp.contains(19), "vacated band sits at the bottom")
        var vacatedDown = IndexSet()
        shiftSurfaceRowIndices(&vacatedDown, rowStart: 0, rowEnd: 20, rowsDelta: -3)
        require(vacatedDown.contains(0) && vacatedDown.contains(2), "vacated band sits at the top")

        // A mark carried out of the region is dropped, not wrapped onto a row
        // that never held it.
        var leaving: IndexSet = [1]
        shiftSurfaceRowIndices(&leaving, rowStart: 0, rowEnd: 20, rowsDelta: 3)
        // Nothing but the vacated band survives: row 1 leaves through the top.
        requireEqual(leaving.count, 3, "a mark leaving the region is dropped, not wrapped")
        require(leaving.contains(17), "and what is left is the vacated band")

        // Rows outside the scrolled region describe content that did not move.
        var outside: IndexSet = [2, 25]
        shiftSurfaceRowIndices(&outside, rowStart: 10, rowEnd: 20, rowsDelta: 1)
        require(outside.contains(2) && outside.contains(25), "rows outside the region are untouched")

        // The guards the core's own staging shares: no delta, empty region, and
        // a shift that covers the whole region leave the set alone.
        var untouched: IndexSet = [5]
        shiftSurfaceRowIndices(&untouched, rowStart: 0, rowEnd: 20, rowsDelta: 0)
        shiftSurfaceRowIndices(&untouched, rowStart: 10, rowEnd: 10, rowsDelta: 2)
        shiftSurfaceRowIndices(&untouched, rowStart: 0, rowEnd: 20, rowsDelta: 20)
        requireEqual(untouched.count, 1, "a declined shift changes nothing")
        require(untouched.contains(5), "and leaves the original mark where it was")
    }

    /// ExternalGridView's commit: in-bracket marks live only in the flush set,
    /// so the pending set holds only marks an earlier bracket left. Those are
    /// shifted against the published shift, then this bracket's are merged
    /// back unshifted (the core sends every shift hint before the rows).
    private static func verifyOnlyCarriedMarksAreShiftedAtCommit() {
        // Row 10 was marked by an EARLIER bracket and no draw consumed it.
        // Row 3 was marked by THIS bracket, after the core had already sent
        // the shift hint, so it names a post-shift row already.
        var pending: IndexSet = [10]
        shiftSurfaceRowIndices(&pending, rowStart: 0, rowEnd: 20, rowsDelta: 1)
        pending.formUnion([3])
        require(pending.contains(9), "a mark carried from an earlier bracket follows its content")
        require(!pending.contains(10), "and does not stay at the pre-shift row")
        require(pending.contains(3), "a mark made after the hint stays where it was made")
        require(
            !pending.contains(2),
            "and is not shifted again onto the row above it"
        )
        // The vacated band still has to be redrawn: those rows lost their
        // vertices whoever marked what.
        require(pending.contains(19), "the vacated band is marked")

        // The same row number in BOTH groups names two different rows: the old
        // mark's content moved up one, the new mark's content is what was just
        // drawn there. Both need painting, so neither may swallow the other.
        // Deriving the carried group by subtraction loses the first of them.
        var both: IndexSet = [7]
        shiftSurfaceRowIndices(&both, rowStart: 0, rowEnd: 20, rowsDelta: 1)
        // commitFlush merges this bracket's own marks back in afterwards.
        both.formUnion([7])
        require(both.contains(6), "the carried mark's content is followed to its new row")
        require(both.contains(7), "and this bracket's own mark still names the row it drew")
    }

    private static func verifyCommittedScrollMerge() {
        func scroll(_ start: Int, _ end: Int, _ delta: Int) -> SurfaceRowScroll {
            SurfaceRowScroll(rowStart: start, rowEnd: end, colStart: 0, colEnd: 80,
                             rowsDelta: delta, totalRows: 24, totalCols: 80)
        }
        var accum: SurfaceRowScroll? = nil
        var dirty = IndexSet()
        mergeCommittedSurfaceScroll(into: &accum, scroll(0, 20, 1), dirtyRows: &dirty)
        requireEqual(accum?.rowsDelta, 1, "the first shift becomes the accumulator")
        mergeCommittedSurfaceScroll(into: &accum, scroll(0, 20, 2), dirtyRows: &dirty)
        requireEqual(accum?.rowsDelta, 3, "a shift of the same region adds, so no draw loses one")
        require(dirty.isEmpty, "and dirties nothing")

        // A different region cannot be one blit: the old one is dropped, and
        // the rows it would have moved are repainted from their remapped slots.
        mergeCommittedSurfaceScroll(into: &accum, scroll(2, 10, -1), dirtyRows: &dirty)
        requireEqual(accum?.rowStart, 2, "a new region replaces the accumulator")
        requireEqual(accum?.rowsDelta, -1, "with its own distance")
        requireEqual(dirty, IndexSet(integersIn: 0..<20), "the dropped region is dirtied whole")
    }

    private static func verifyStagedValueIsPublishedByItsOwnCommit() {
        final class Surface {}
        let main = ObjectIdentifier(Surface.self)
        let external = Surface()
        let ext = ObjectIdentifier(external)
        var slot = SurfaceCommitStaged<Int>()
        slot.stage(7, by: ext)
        // The main surface commits first at every flush end. Handing it the
        // external window's measurement paired that rect with rows the
        // external window had not committed yet.
        requireEqual(slot.take(committedBy: main), nil, "another surface's commit leaves it staged")
        requireEqual(slot.take(committedBy: ext), 7, "the stager's own commit publishes it")
        requireEqual(slot.take(committedBy: ext), nil, "once")

        slot.stage(1, by: ext)
        slot.stage(2, by: main)
        requireEqual(slot.take(committedBy: main), 2, "the latest measurement wins, published by its stager")
    }

    private static func verifyCommittedRowMutationLedger() {
        let stale = (0..<3).map { _ in SparseRowSet(rowLimit: 16, preparedRows: 16) }
        var needsFullSync = [false, true, false]
        stale[0].insert(9)
        recordCommittedRowMutation(stale: stale, needsFullSync: &needsFullSync,
                                   committedIndex: 0, rows: [2, 5], structural: false)
        require(stale[0].rows.isEmpty, "the committed set owes nothing")
        requireEqual(needsFullSync[0], false, "and is in sync")
        requireEqual(stale[2].rows, [2, 5], "another set owes the changed rows")
        require(stale[1].rows.isEmpty, "a set owing a full sync records no rows")

        recordCommittedRowMutation(stale: stale, needsFullSync: &needsFullSync,
                                   committedIndex: 2, rows: [1], structural: true)
        requireEqual(needsFullSync, [true, true, false], "a structural change owes every other set a full sync")
        require(stale[0].rows.isEmpty && stale[2].rows.isEmpty, "and clears their row lists")
    }

    /// An editor-anchored float follows whichever window it overlaps most this
    /// frame. Two windows' landed-row counters share no zero, so a baseline
    /// seeded against one and read against the other made the debt jump by
    /// their difference.
    private static func verifyFloatDebtBaselineFollowsOneGrid() {
        let first = floatDebtBaselineFollowing(anchorGridId: 2, stored: nil, anchorRowsUp: 0, placementRowsUp: 0)
        require(first.seeded, "a float seen following for the first time is seeded")
        let same = floatDebtBaselineFollowing(anchorGridId: 2, stored: first.baseline, anchorRowsUp: 3, placementRowsUp: 0)
        require(!same.seeded, "following the same window keeps its baseline")
        requireEqual(floatDebtRowsUp(anchorRowsUp: 3, placementRowsUp: 0, baseline: same.baseline),
                     3, "and accrues that window's steps")
        let switched = floatDebtBaselineFollowing(anchorGridId: 5, stored: same.baseline, anchorRowsUp: 50, placementRowsUp: 0)
        require(switched.seeded, "a switch to another window re-seeds")
        requireEqual(floatDebtRowsUp(anchorRowsUp: 50, placementRowsUp: 0, baseline: switched.baseline),
                     0, "so the other window's history is not carried as debt")
    }

    /// A layer ledger never holds the root, and every staged layout does, so a
    /// count comparison left a single closed float's entry behind.
    private static func verifyLedgerForgetsALoneClosedLayer() {
        func layer(_ id: Int64) -> SurfaceLayer {
            SurfaceLayer(gridId: id, anchorGrid: 1, originPx: .zero, rows: 1, cols: 1, z: 0, followsScroll: true)
        }
        var ledger: [Int64: Int] = [7: 3]
        pruneSurfaceLayerLedger(&ledger, to: [layer(1)])
        require(ledger.isEmpty, "a closed float's entry is dropped even when it is the only one")
        ledger = [7: 3, 9: 1]
        pruneSurfaceLayerLedger(&ledger, to: [layer(1), layer(9), layer(12)])
        requireEqual(ledger, [9: 1], "a closed float's entry is dropped while another float opens")
    }

    static func main() {
        verifyLedgerForgetsALoneClosedLayer()
        verifyFloatDebtBaselineFollowsOneGrid()
        verifyCommittedRowMutationLedger()
        verifyStagedValueIsPublishedByItsOwnCommit()
        verifyCommittedScrollMerge()
        verifyPlan()
        verifyCoversBand()
        verifyRingOutlivesTheLiveSet()
        verifyCreditRule()
        verifyBoundWindowStartsFromTheDriver()
        verifyBodilyMovedLayerShiftsItsOrigin()
        verifyScrollOffsetLookup()
        verifyFloatDebtLedger()
        verifyDirtyRowsTravelWithTheShift()
        verifyOnlyCarriedMarksAreShiftedAtCommit()

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
        verifyUndisplacedPrune(device: device)
        verifyDepthClamp(device: device)
        verifyReleaseCoveredPins(device: device)
        print("ScrollRetentionTests: OK")
    }
}
