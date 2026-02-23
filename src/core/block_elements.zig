// block_elements.zig — Geometric rendering for Unicode Block Element characters.
//
// Instead of relying on font glyphs (which may not fill the cell exactly),
// block elements are rendered as solid-color rectangles that perfectly tile
// the cell grid.  This eliminates visible seams / thin lines in ASCII art,
// regardless of font and linespace setting.
//
// Shade characters (U+2591–U+2593) are intentionally excluded — they are
// better served by the font's own glyph (hatching patterns).

/// A single rectangle expressed as fractions of cell dimensions.
/// x/y values are in [0.0, 1.0]: 0 = cell left/top, 1 = cell right/bottom.
pub const BlockRect = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

/// Maximum quads for any single block element (quadrant blocks need up to 2).
pub const MAX_BLOCK_QUADS = 4;

/// Result of getBlockGeometry: up to MAX_BLOCK_QUADS rectangles.
pub const BlockResult = struct {
    rects: [MAX_BLOCK_QUADS]BlockRect,
    count: u8,
};

/// Returns true if `scalar` is a block element that should be rendered
/// geometrically.  Shade characters (U+2591–U+2593) return false.
pub inline fn isBlockElement(scalar: u32) bool {
    return (scalar >= 0x2580 and scalar <= 0x2590) or
        (scalar >= 0x2594 and scalar <= 0x259F);
}

/// Returns the geometric rectangles for a block element codepoint.
/// All coordinates are fractions of cell dimensions [0.0, 1.0].
/// Returns count == 0 for non-block-element codepoints.
pub fn getBlockGeometry(scalar: u32) BlockResult {
    var result = BlockResult{ .rects = undefined, .count = 0 };

    switch (scalar) {
        // --- Upper / lower fractional blocks ---
        0x2580 => result = single(0, 0, 1, 0.5), // ▀ UPPER HALF BLOCK
        0x2581 => result = single(0, 7.0 / 8.0, 1, 1), // ▁ LOWER ONE EIGHTH BLOCK
        0x2582 => result = single(0, 0.75, 1, 1), // ▂ LOWER ONE QUARTER BLOCK
        0x2583 => result = single(0, 5.0 / 8.0, 1, 1), // ▃ LOWER THREE EIGHTHS BLOCK
        0x2584 => result = single(0, 0.5, 1, 1), // ▄ LOWER HALF BLOCK
        0x2585 => result = single(0, 3.0 / 8.0, 1, 1), // ▅ LOWER FIVE EIGHTHS BLOCK
        0x2586 => result = single(0, 0.25, 1, 1), // ▆ LOWER THREE QUARTERS BLOCK
        0x2587 => result = single(0, 1.0 / 8.0, 1, 1), // ▇ LOWER SEVEN EIGHTHS BLOCK
        0x2588 => result = single(0, 0, 1, 1), // █ FULL BLOCK
        // --- Left fractional blocks ---
        0x2589 => result = single(0, 0, 7.0 / 8.0, 1), // ▉ LEFT SEVEN EIGHTHS BLOCK
        0x258A => result = single(0, 0, 0.75, 1), // ▊ LEFT THREE QUARTERS BLOCK
        0x258B => result = single(0, 0, 5.0 / 8.0, 1), // ▋ LEFT FIVE EIGHTHS BLOCK
        0x258C => result = single(0, 0, 0.5, 1), // ▌ LEFT HALF BLOCK
        0x258D => result = single(0, 0, 3.0 / 8.0, 1), // ▍ LEFT THREE EIGHTHS BLOCK
        0x258E => result = single(0, 0, 0.25, 1), // ▎ LEFT ONE QUARTER BLOCK
        0x258F => result = single(0, 0, 1.0 / 8.0, 1), // ▏ LEFT ONE EIGHTH BLOCK
        // --- Right half ---
        0x2590 => result = single(0.5, 0, 1, 1), // ▐ RIGHT HALF BLOCK
        // 0x2591–0x2593 are shade characters — handled by font glyphs
        // --- Upper/right thin blocks ---
        0x2594 => result = single(0, 0, 1, 1.0 / 8.0), // ▔ UPPER ONE EIGHTH BLOCK
        0x2595 => result = single(7.0 / 8.0, 0, 1, 1), // ▕ RIGHT ONE EIGHTH BLOCK
        // --- Quadrant blocks ---
        // TL = (0, 0)–(0.5, 0.5)   TR = (0.5, 0)–(1, 0.5)
        // BL = (0, 0.5)–(0.5, 1)   BR = (0.5, 0.5)–(1, 1)
        0x2596 => result = single(0, 0.5, 0.5, 1), // ▖ QUADRANT LOWER LEFT
        0x2597 => result = single(0.5, 0.5, 1, 1), // ▗ QUADRANT LOWER RIGHT
        0x2598 => result = single(0, 0, 0.5, 0.5), // ▘ QUADRANT UPPER LEFT
        0x2599 => result = pair( // ▙ QUADRANT UPPER LEFT AND LOWER LEFT AND LOWER RIGHT
            .{ .x0 = 0, .y0 = 0, .x1 = 0.5, .y1 = 0.5 },
            .{ .x0 = 0, .y0 = 0.5, .x1 = 1, .y1 = 1 },
        ),
        0x259A => result = pair( // ▚ QUADRANT UPPER LEFT AND LOWER RIGHT
            .{ .x0 = 0, .y0 = 0, .x1 = 0.5, .y1 = 0.5 },
            .{ .x0 = 0.5, .y0 = 0.5, .x1 = 1, .y1 = 1 },
        ),
        0x259B => result = pair( // ▛ QUADRANT UPPER LEFT AND UPPER RIGHT AND LOWER LEFT
            .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5 },
            .{ .x0 = 0, .y0 = 0.5, .x1 = 0.5, .y1 = 1 },
        ),
        0x259C => result = pair( // ▜ QUADRANT UPPER LEFT AND UPPER RIGHT AND LOWER RIGHT
            .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5 },
            .{ .x0 = 0.5, .y0 = 0.5, .x1 = 1, .y1 = 1 },
        ),
        0x259D => result = single(0.5, 0, 1, 0.5), // ▝ QUADRANT UPPER RIGHT
        0x259E => result = pair( // ▞ QUADRANT UPPER RIGHT AND LOWER LEFT
            .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 0.5 },
            .{ .x0 = 0, .y0 = 0.5, .x1 = 0.5, .y1 = 1 },
        ),
        0x259F => result = pair( // ▟ QUADRANT UPPER RIGHT AND LOWER LEFT AND LOWER RIGHT
            .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 0.5 },
            .{ .x0 = 0, .y0 = 0.5, .x1 = 1, .y1 = 1 },
        ),
        else => {},
    }
    return result;
}

// --- helpers to keep the switch arms terse ---

fn single(x0: f32, y0: f32, x1: f32, y1: f32) BlockResult {
    return .{
        .rects = .{
            .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
            undefined,
            undefined,
            undefined,
        },
        .count = 1,
    };
}

fn pair(a: BlockRect, b: BlockRect) BlockResult {
    return .{
        .rects = .{ a, b, undefined, undefined },
        .count = 2,
    };
}

// =========================================================================
// Unit tests
// =========================================================================

const testing = @import("std").testing;

// --- isBlockElement boundary tests ---

test "isBlockElement boundary: U+257F is NOT a block element" {
    try testing.expect(!isBlockElement(0x257F));
}

test "isBlockElement boundary: U+2580 IS a block element" {
    try testing.expect(isBlockElement(0x2580));
}

test "isBlockElement boundary: U+2590 IS a block element" {
    try testing.expect(isBlockElement(0x2590));
}

test "isBlockElement boundary: U+2591 (shade) is NOT a block element" {
    try testing.expect(!isBlockElement(0x2591));
}

test "isBlockElement boundary: U+2592 (shade) is NOT a block element" {
    try testing.expect(!isBlockElement(0x2592));
}

test "isBlockElement boundary: U+2593 (shade) is NOT a block element" {
    try testing.expect(!isBlockElement(0x2593));
}

test "isBlockElement boundary: U+2594 IS a block element" {
    try testing.expect(isBlockElement(0x2594));
}

test "isBlockElement boundary: U+259F IS a block element" {
    try testing.expect(isBlockElement(0x259F));
}

test "isBlockElement boundary: U+25A0 is NOT a block element" {
    try testing.expect(!isBlockElement(0x25A0));
}

test "isBlockElement: ASCII 'A' is NOT a block element" {
    try testing.expect(!isBlockElement('A'));
}

// --- getBlockGeometry: all 29 characters ---

fn expectSingle(scalar: u32, x0: f32, y0: f32, x1: f32, y1: f32) !void {
    const g = getBlockGeometry(scalar);
    try testing.expectEqual(@as(u8, 1), g.count);
    try testing.expectApproxEqAbs(x0, g.rects[0].x0, 1e-6);
    try testing.expectApproxEqAbs(y0, g.rects[0].y0, 1e-6);
    try testing.expectApproxEqAbs(x1, g.rects[0].x1, 1e-6);
    try testing.expectApproxEqAbs(y1, g.rects[0].y1, 1e-6);
}

fn expectPair(scalar: u32, a: BlockRect, b: BlockRect) !void {
    const g = getBlockGeometry(scalar);
    try testing.expectEqual(@as(u8, 2), g.count);
    try testing.expectApproxEqAbs(a.x0, g.rects[0].x0, 1e-6);
    try testing.expectApproxEqAbs(a.y0, g.rects[0].y0, 1e-6);
    try testing.expectApproxEqAbs(a.x1, g.rects[0].x1, 1e-6);
    try testing.expectApproxEqAbs(a.y1, g.rects[0].y1, 1e-6);
    try testing.expectApproxEqAbs(b.x0, g.rects[1].x0, 1e-6);
    try testing.expectApproxEqAbs(b.y0, g.rects[1].y0, 1e-6);
    try testing.expectApproxEqAbs(b.x1, g.rects[1].x1, 1e-6);
    try testing.expectApproxEqAbs(b.y1, g.rects[1].y1, 1e-6);
}

test "U+2580 ▀ UPPER HALF BLOCK" {
    try expectSingle(0x2580, 0, 0, 1, 0.5);
}

test "U+2581 ▁ LOWER ONE EIGHTH" {
    try expectSingle(0x2581, 0, 7.0 / 8.0, 1, 1);
}

test "U+2582 ▂ LOWER ONE QUARTER" {
    try expectSingle(0x2582, 0, 0.75, 1, 1);
}

test "U+2583 ▃ LOWER THREE EIGHTHS" {
    try expectSingle(0x2583, 0, 5.0 / 8.0, 1, 1);
}

test "U+2584 ▄ LOWER HALF" {
    try expectSingle(0x2584, 0, 0.5, 1, 1);
}

test "U+2585 ▅ LOWER FIVE EIGHTHS" {
    try expectSingle(0x2585, 0, 3.0 / 8.0, 1, 1);
}

test "U+2586 ▆ LOWER THREE QUARTERS" {
    try expectSingle(0x2586, 0, 0.25, 1, 1);
}

test "U+2587 ▇ LOWER SEVEN EIGHTHS" {
    try expectSingle(0x2587, 0, 1.0 / 8.0, 1, 1);
}

test "U+2588 █ FULL BLOCK" {
    try expectSingle(0x2588, 0, 0, 1, 1);
}

test "U+2589 ▉ LEFT SEVEN EIGHTHS" {
    try expectSingle(0x2589, 0, 0, 7.0 / 8.0, 1);
}

test "U+258A ▊ LEFT THREE QUARTERS" {
    try expectSingle(0x258A, 0, 0, 0.75, 1);
}

test "U+258B ▋ LEFT FIVE EIGHTHS" {
    try expectSingle(0x258B, 0, 0, 5.0 / 8.0, 1);
}

test "U+258C ▌ LEFT HALF" {
    try expectSingle(0x258C, 0, 0, 0.5, 1);
}

test "U+258D ▍ LEFT THREE EIGHTHS" {
    try expectSingle(0x258D, 0, 0, 3.0 / 8.0, 1);
}

test "U+258E ▎ LEFT ONE QUARTER" {
    try expectSingle(0x258E, 0, 0, 0.25, 1);
}

test "U+258F ▏ LEFT ONE EIGHTH" {
    try expectSingle(0x258F, 0, 0, 1.0 / 8.0, 1);
}

test "U+2590 ▐ RIGHT HALF" {
    try expectSingle(0x2590, 0.5, 0, 1, 1);
}

test "U+2594 ▔ UPPER ONE EIGHTH" {
    try expectSingle(0x2594, 0, 0, 1, 1.0 / 8.0);
}

test "U+2595 ▕ RIGHT ONE EIGHTH" {
    try expectSingle(0x2595, 7.0 / 8.0, 0, 1, 1);
}

test "U+2596 ▖ QUADRANT LOWER LEFT" {
    try expectSingle(0x2596, 0, 0.5, 0.5, 1);
}

test "U+2597 ▗ QUADRANT LOWER RIGHT" {
    try expectSingle(0x2597, 0.5, 0.5, 1, 1);
}

test "U+2598 ▘ QUADRANT UPPER LEFT" {
    try expectSingle(0x2598, 0, 0, 0.5, 0.5);
}

test "U+2599 ▙ QUADRANT UL+BL+BR" {
    try expectPair(0x2599, .{ .x0 = 0, .y0 = 0, .x1 = 0.5, .y1 = 0.5 }, .{ .x0 = 0, .y0 = 0.5, .x1 = 1, .y1 = 1 });
}

test "U+259A ▚ QUADRANT UL+BR" {
    try expectPair(0x259A, .{ .x0 = 0, .y0 = 0, .x1 = 0.5, .y1 = 0.5 }, .{ .x0 = 0.5, .y0 = 0.5, .x1 = 1, .y1 = 1 });
}

test "U+259B ▛ QUADRANT UL+UR+BL" {
    try expectPair(0x259B, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5 }, .{ .x0 = 0, .y0 = 0.5, .x1 = 0.5, .y1 = 1 });
}

test "U+259C ▜ QUADRANT UL+UR+BR" {
    try expectPair(0x259C, .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5 }, .{ .x0 = 0.5, .y0 = 0.5, .x1 = 1, .y1 = 1 });
}

test "U+259D ▝ QUADRANT UPPER RIGHT" {
    try expectSingle(0x259D, 0.5, 0, 1, 0.5);
}

test "U+259E ▞ QUADRANT UR+BL" {
    try expectPair(0x259E, .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 0.5 }, .{ .x0 = 0, .y0 = 0.5, .x1 = 0.5, .y1 = 1 });
}

test "U+259F ▟ QUADRANT UR+BL+BR" {
    try expectPair(0x259F, .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 0.5 }, .{ .x0 = 0, .y0 = 0.5, .x1 = 1, .y1 = 1 });
}

test "non-block-element returns count 0" {
    const g = getBlockGeometry(0x0041); // 'A'
    try testing.expectEqual(@as(u8, 0), g.count);
}

test "shade U+2591 returns count 0" {
    const g = getBlockGeometry(0x2591);
    try testing.expectEqual(@as(u8, 0), g.count);
}

test "shade U+2593 returns count 0" {
    const g = getBlockGeometry(0x2593);
    try testing.expectEqual(@as(u8, 0), g.count);
}
