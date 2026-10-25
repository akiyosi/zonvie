// ScrollAdjustedRowTests — the pixel-to-row rules that stay in Swift: where
// a displaced follower is hit, and how horizontal scroll input is paid out.
// The sub-row ease rule itself is the core's (pointer_target.cellInGridEased).

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

/// A float that follows its anchor is drawn displaced bodily and has no
/// offset of its own. The hit test has to find it where it is drawn — through
/// the core, at the cell the drawn pixel came from — and must not keep naming
/// it where it no longer is.
private typealias Hit = (gridId: Int64, row: Int32, col: Int32)

private func followerId(_ r: DisplacedFollowerHit?) -> Int64 {
    if case let .follower(gridId, _, _)? = r { return gridId }
    return -1
}

private func uncoveredId(_ r: DisplacedFollowerHit?) -> Int64 {
    if case let .uncovered(under)? = r { return under?.gridId ?? 0 }
    return -1
}

private func verifyDisplacedFollowerHit() {
    // Float 7 (paint rank 5) placed on rows 4..6, drawn two rows lower (40px)
    // mid-ease. A static float 9 (rank 3) lies under row 4. The core
    // resolver, as the stub answers it: 7 over 9 over window 2, minus any grid
    // `excluded` names.
    let resolveExcluding: (Int32, Int32, (Int64) -> Bool) -> Hit? = { row, col, excluded in
        if (4...6).contains(row), !excluded(7) { return (7, row - 4, col) }
        if row == 4, !excluded(9) { return (9, row - 4, col) }
        return (2, row, col)
    }
    let rankOf: (Int64) -> Int? = { [7: 5, 9: 3, 2: 1][$0] }

    // Row 7 on screen is where float row 1 is drawn now.
    let drawn = resolveDisplacedFollowerHit(
        pointPxY: 150, cellHeightPx: cell, globalCol: 3, staticGridId: 2, followers: [7: 40],
        paintRankOf: rankOf, resolveExcluding: resolveExcluding)
    expect(Int32(followerId(drawn)), 7, "a press where the follower is drawn names it")
    if case let .follower(_, row, _)? = drawn { expect(row, 1, "at the row that pixel came from") }

    // Row 4 on screen: the float's placement, which it has moved off. The
    // static float under it is what is drawn there now, not grid 1.
    let vacated = resolveDisplacedFollowerHit(
        pointPxY: 90, cellHeightPx: cell, globalCol: 3, staticGridId: 7, followers: [7: 40],
        paintRankOf: rankOf, resolveExcluding: resolveExcluding)
    expect(Int32(uncoveredId(vacated)), 9, "the vacated placement goes to the float behind it")

    // Row 5, also vacated: nothing but the window behind.
    let vacatedSplit = resolveDisplacedFollowerHit(
        pointPxY: 110, cellHeightPx: cell, globalCol: 3, staticGridId: 7, followers: [7: 40],
        paintRankOf: rankOf, resolveExcluding: resolveExcluding)
    expect(Int32(uncoveredId(vacatedSplit)), 2, "then the window behind")

    // Not displaced: the static answer stands.
    let still = resolveDisplacedFollowerHit(
        pointPxY: 90, cellHeightPx: cell, globalCol: 3, staticGridId: 7, followers: [7: 0.1],
        paintRankOf: rankOf, resolveExcluding: resolveExcluding)
    expect(still == nil ? 1 : 0, 1, "an undisplaced follower leaves the static hit alone")

    // Equal Neovim zindex, different paint rank: follower 8 is drawn in front
    // of static float 9 where they overlap, so it takes the press. Follower 8
    // sits on rows 4..5, drawn a row lower; row 5 on screen is its row 0.
    let overlap: (Int32, Int32, (Int64) -> Bool) -> Hit? = { row, col, excluded in
        if (4...5).contains(row), !excluded(8) { return (8, row - 4, col) }
        if (4...5).contains(row), !excluded(9) { return (9, row - 4, col) }
        return (2, row, col)
    }
    let overlapRank: (Int64) -> Int? = { [8: 4, 9: 3, 2: 1][$0] }
    let front = resolveDisplacedFollowerHit(
        pointPxY: 110, cellHeightPx: cell, globalCol: 3, staticGridId: 9, followers: [8: 20],
        paintRankOf: overlapRank, resolveExcluding: overlap)
    expect(Int32(followerId(front)), 8, "the follower drawn in front takes the press")

    // Two followers drawn over the same pixel: the higher paint rank wins,
    // whatever order the dictionary yields them in.
    let both: (Int32, Int32) -> Hit? = { row, col in
        row == 2 ? (10, 0, col) : row == 3 ? (11, 0, col) : (2, row, col)
    }
    for _ in 0..<8 {
        let pick = resolveDisplacedFollowerHit(
            pointPxY: 90, cellHeightPx: cell, globalCol: 3, staticGridId: 2, followers: [10: 40, 11: 20],
            paintRankOf: { [10: 6, 11: 7, 2: 1][$0] },
            resolveExcluding: { r, c, _ in both(r, c) })
        expect(Int32(followerId(pick)), 11, "the follower painted in front wins")
    }

    // A fixed float 12 (rank 8) covers row 5 only, the source cell of float
    // 7 drawn a row lower. It is not drawn at row 6, so it must not hide 7.
    let over: (Int32, Int32, (Int64) -> Bool) -> Hit? = { row, col, excluded in
        if row == 5, !excluded(12) { return (12, 0, col) }
        if (4...6).contains(row), !excluded(7) { return (7, row - 4, col) }
        return (2, row, col)
    }
    let hidden = resolveDisplacedFollowerHit(
        pointPxY: 130, cellHeightPx: cell, globalCol: 3, staticGridId: 7, followers: [7: 20],
        paintRankOf: { [7: 5, 12: 8, 2: 1][$0] }, resolveExcluding: over)
    expect(Int32(followerId(hidden)), 7, "a float over the source cell does not hide the follower")
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

        verifyDisplacedFollowerHit()

        if failures == 0 {
            print("ScrollAdjustedRowTests: all checks passed")
        } else {
            print("ScrollAdjustedRowTests: \(failures) failure(s)")
            exit(1)
        }
    }
}
