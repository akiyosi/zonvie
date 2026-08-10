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

    /// One grid at a time. beginStep drops every staged row belonging to
    /// another grid, so two windows scrolling in one flush end with the later
    /// one's band filled and the earlier one's empty. Anything built on the
    /// retention is bounded by this.
    private static func verifySingleGridAtATime(device: MTLDevice) {
        let retention = ScrollRetention(device: device)
        retention.setDepthRows(3)
        retention.beginFlush()
        retention.beginStep(gridId: 2, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 2, targetRow: 0))
        retention.beginStep(gridId: 3, rowsDelta: 1, pivotTargetRow: 0)
        retention.stage(makeRow(retention, gridId: 3, targetRow: 0))
        _ = retention.commit()
        requireEqual(retention.publishedCount(gridId: 3), 1, "the later grid is retained")
        requireEqual(retention.publishedCount(gridId: 2), 0, "the earlier grid's rows are dropped")
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

        guard let device = MTLCreateSystemDefaultDevice() else {
            // Headless CI without a GPU: the arithmetic above still ran.
            print("ScrollRetentionTests: OK (no Metal device; staging tests skipped)")
            return
        }
        verifyStagingLifecycle(device: device)
        verifyAbortDiscardsStaged(device: device)
        verifySingleGridAtATime(device: device)
        verifyPrune(device: device)
        verifyDepthClamp(device: device)
        print("ScrollRetentionTests: OK")
    }
}
