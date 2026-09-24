// ScrollAdjustedRowTests — the one rule that turns a pixel into a grid row
// while a sub-row ease is running.
//
// The rule lived in MetalTerminalView.hitTestGrid, and the drag path that has
// to agree with it applied the offset with no band check at all. A press on a
// winbar and the drag that followed it therefore answered differently about
// the same pixel. `scrollAdjustedLocalRow` is that rule, once, and this is
// what pins it.

import Foundation
import Metal
import simd

// Minimal collaborators required when MetalTypes.swift is compiled as a
// standalone test executable — the same set ScrollRetentionTests declares, and
// for the same reason: the file names types owned by GridSurfaceRenderer that
// the rule under test does not touch.
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


private var failures = 0

private func expect(_ actual: Int32, _ expected: Int32, _ what: String) {
    if actual != expected {
        print("FAIL: \(what): got \(actual), expected \(expected)")
        failures += 1
    }
}

private let cell: CGFloat = 20

/// A window with a winbar on top and a border row at the bottom: rows 0 and 9
/// are margins, 1..8 are content.
private let decorated = GridRowBand(startRow: 0, rows: 10, marginTop: 1, marginBottom: 1)

/// A plain window: every row scrolls.
private let plain = GridRowBand(startRow: 0, rows: 10, marginTop: 0, marginBottom: 0)

/// A float that follows its anchor is drawn displaced bodily and has no
/// offset of its own. The hit test has to find it where it is drawn — through
/// the core, at the cell the drawn pixel came from — and must not keep naming
/// it where it no longer is.
private func verifyDisplacedFollowerHit() {
    // Float 7 (z 50) placed on rows 4..6, drawn two rows lower (40px) mid-ease.
    // The core resolver, as the stub answers it: rows 4..6 are the float,
    // everything else window 2.
    let resolve: (Int32, Int32) -> (gridId: Int64, row: Int32, col: Int32)? = { row, col in
        (4...6).contains(row) ? (7, row - 4, col) : (2, row, col)
    }
    let zindexOf: (Int64) -> Int64? = { $0 == 7 ? 50 : 0 }

    // Row 7 on screen is where float row 1 is drawn now.
    let drawn = resolveDisplacedFollowerHit(
        pointPxY: 150, cellHeightPx: cell, globalCol: 3,
        staticGridId: 2, followers: [7: 40], zindexOf: zindexOf, resolve: resolve)
    expect(Int32(drawn?.gridId ?? -1), 7, "a press where the follower is drawn names it")
    expect(drawn?.row ?? -1, 1, "at the row that pixel came from")

    // Row 4 on screen: the float's placement, which it has moved off.
    let vacated = resolveDisplacedFollowerHit(
        pointPxY: 90, cellHeightPx: cell, globalCol: 3,
        staticGridId: 7, followers: [7: 40], zindexOf: zindexOf, resolve: resolve)
    expect(Int32(vacated?.gridId ?? -1), 1, "the vacated placement goes to grid 1, the window behind")

    // Not displaced: the static answer stands.
    let still = resolveDisplacedFollowerHit(
        pointPxY: 90, cellHeightPx: cell, globalCol: 3,
        staticGridId: 7, followers: [7: 0.1], zindexOf: zindexOf, resolve: resolve)
    expect(still == nil ? 1 : 0, 1, "an undisplaced follower leaves the static hit alone")
}

/// Horizontal input was read only to drop an all-zero event and never sent,
/// so neither a tilt wheel nor a sideways swipe reached Neovim.
private func verifyHorizontalScrollEvents() {
    var acc = HorizontalScrollAccumulator()
    // A tilt-wheel notch is one event whatever its size; positive is "left".
    expect(Int32(acc.consume(deltaX: 0.4, deltaY: 0, precise: false, scale: 2, stepPx: 60)), 1,
           "a wheel notch sends one event")
    expect(Int32(acc.consume(deltaX: -3, deltaY: 0, precise: false, scale: 2, stepPx: 60)), -1,
           "a wheel notch the other way sends one event")

    // A swipe banks its travel and pays one event per step.
    acc = HorizontalScrollAccumulator()
    expect(Int32(acc.consume(deltaX: 20, deltaY: 0, precise: true, scale: 2, stepPx: 60)), 0,
           "40px of a 60px step sends nothing yet")
    expect(Int32(acc.consume(deltaX: 20, deltaY: 0, precise: true, scale: 2, stepPx: 60)), 1,
           "the step completes on the next input")
    expect(Int32(acc.consume(deltaX: -70, deltaY: 0, precise: true, scale: 2, stepPx: 60)), -2,
           "a reversal spends the bank, then pays whole steps the other way")

    // A mostly vertical swipe carries sideways jitter; it must not scroll.
    acc = HorizontalScrollAccumulator()
    for _ in 0..<10 {
        expect(Int32(acc.consume(deltaX: 8, deltaY: 30, precise: true, scale: 2, stepPx: 60)), 0,
               "vertical-dominant swipe sends no horizontal event")
    }

    // A zero step cannot divide.
    expect(Int32(acc.consume(deltaX: 50, deltaY: 0, precise: true, scale: 2, stepPx: 0)), 0,
           "a zero step sends nothing")
}

@main
struct ScrollAdjustedRowTests {
    static func main() {
        verifyHorizontalScrollEvents()

        // A pixel on a CONTENT row, eased: the ease is undone, because the shader
        // really did move that pixel.
        expect(
            scrollAdjustedLocalRow(pointPxY: 50, cellHeightPx: cell, band: decorated, scrollOffsetPx: 20),
            1,
            "content row with the ease undone"
        )

        // The same pixel with no offset: nothing to undo.
        expect(
            scrollAdjustedLocalRow(pointPxY: 50, cellHeightPx: cell, band: decorated, scrollOffsetPx: 0),
            2,
            "no offset leaves the drawn row"
        )

        // A pixel on the TOP MARGIN, with the content eased down a row. The winbar
        // carries no DECO_SCROLLABLE, so the shader left it where it is; undoing the
        // ease would name row 1, a content row the user did not click.
        // This is the numeric case the drag path used to get wrong.
        expect(
            scrollAdjustedLocalRow(pointPxY: 10, cellHeightPx: cell, band: decorated, scrollOffsetPx: -20),
            0,
            "top margin keeps its drawn row"
        )

        // A pixel on the BOTTOM MARGIN, content eased up a row.
        expect(
            scrollAdjustedLocalRow(pointPxY: 190, cellHeightPx: cell, band: decorated, scrollOffsetPx: 20),
            9,
            "bottom margin keeps its drawn row"
        )

        // A content pixel whose adjusted row would land ON a margin: refused, because
        // the answer has to be a row the ease could have brought there.
        expect(
            scrollAdjustedLocalRow(pointPxY: 30, cellHeightPx: cell, band: decorated, scrollOffsetPx: 20),
            1,
            "adjustment onto the top margin is refused"
        )
        expect(
            scrollAdjustedLocalRow(pointPxY: 170, cellHeightPx: cell, band: decorated, scrollOffsetPx: -20),
            8,
            "adjustment onto the bottom margin is refused"
        )

        // With no margins every row is content, so the ease is always undone.
        expect(
            scrollAdjustedLocalRow(pointPxY: 10, cellHeightPx: cell, band: plain, scrollOffsetPx: -20),
            1,
            "an undecorated window undoes the ease on its first row"
        )

        // startRow shifts the answer into the grid's own space.
        expect(
            scrollAdjustedLocalRow(
                pointPxY: 150,
                cellHeightPx: cell,
                band: GridRowBand(startRow: 5, rows: 10, marginTop: 0, marginBottom: 0),
                scrollOffsetPx: 0
            ),
            2,
            "startRow is subtracted"
        )

        // A sub-pixel offset is not an ease.
        expect(
            scrollAdjustedLocalRow(pointPxY: 50, cellHeightPx: cell, band: plain, scrollOffsetPx: 0.0005),
            2,
            "an offset below the epsilon is ignored"
        )

        // A zero cell height cannot name a row; it must not divide.
        expect(
            scrollAdjustedLocalRow(pointPxY: 50, cellHeightPx: 0, band: plain, scrollOffsetPx: 20),
            0,
            "a zero cell height returns zero"
        )

        verifyDisplacedFollowerHit()

        if failures == 0 {
            print("ScrollAdjustedRowTests: all checks passed")
        } else {
            print("ScrollAdjustedRowTests: \(failures) failure(s)")
            exit(1)
        }
    }
}
