// visual/emoji_cluster_cache — distinct emoji clusters must render distinctly.
//
// Emoji reach the frontend rasterizer as a cluster: a base scalar plus the
// cell's overflow codepoints (ZWJ joiners, variation selectors, the tail of a
// sequence). The core caches the resulting bitmap under a key built from those
// same inputs, so the key has to be exactly as fine as the picture it names. A
// key coarser than the bitmap — the base scalar alone, say — makes two clusters
// that share a base collapse onto one entry, and the second one silently
// renders as the first.
//
// Nothing below the glass catches that: the cache hit is a hit, the atlas
// entry is valid, and the vertices are well-formed. The pixels are the only
// witness, which is why this is a visual scenario and not a core unit test.
//
// Golden-free by construction. Each pair is rendered in the same session, the
// first render populating the cache and the second probing it, and the
// assertion is only that the two frames differ. That survives font, DPI and
// colorscheme drift, and it says nothing about what an emoji *should* look
// like — only that two different ones cannot look identical.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const driver = @import("../../driver.zig");

/// No crop: compare the window at whatever size the app opened at, which is
/// the size a user actually renders into. A crop would make the result depend
/// on where in the window a single glyph happened to land; filling the buffer
/// instead (see fillCmd) makes the compared area scale with the window and puts
/// hundreds of emoji cells through the cache rather than one.
const crop: ?driver.capture.Crop = null;

/// Rows and columns of emoji to lay down. Both exceed any plausible viewport,
/// so the visible area is saturated regardless of window size and DPI; Neovim
/// simply does not display the overflow.
const fill_rows = 200;
const fill_cols = 200;

/// The control pair (two unrelated emoji) establishes what "these cells render
/// differently" looks like in this run's font, DPI and crop. Every other pair
/// must reach this share of it. A collision lands at zero, so the bar only has
/// to sit clear of noise, not near the control.
const min_share_of_control = 0.25;

/// The control itself must move this many pixels, or the harness is looking at
/// the wrong place (crop missing the glyph, capture not settled) and every
/// comparison below would trivially "pass" as a collision.
const control_floor = 0.002;

const Pair = struct {
    name: []const u8,
    a: []const u8,
    b: []const u8,
};

/// Two emoji sharing no codepoints. Measured first, and every pair below is
/// judged against it.
const control = Pair{ .name = "distinct_bases", .a = "😀", .b = "🚀" };

const pairs = [_]Pair{
    // Same base scalar; the second carries a ZWJ tail. A key built from the
    // base alone cannot tell them apart.
    .{ .name = "base_vs_zwj_sequence", .a = "👩", .b = "👩‍💻" },
    // Same base AND same joiner; only the trailing symbol differs. This is the
    // case flush.zig's cluster key comment calls out by name (👩‍💻 vs 👩‍🔬).
    .{ .name = "zwj_tail_differs", .a = "👩‍💻", .b = "👩‍🔬" },
    // Same base scalar, one with a variation selector. The selector is carried
    // in the overflow map, not in the base, so it is the same class of hazard.
    .{ .name = "variation_selector", .a = "❤", .b = "❤️" },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    try g.exec("execute('set guicursor=a:block,a:blinkon0')");

    const control_ratio = try pairDiff(alloc, g, control);
    if (control_ratio < control_floor) {
        std.debug.print(
            "visual: emoji_cluster_cache: control '{s}' vs '{s}' differs in only " ++
                "{d:.5} of pixels (need {d:.5}) — the capture is not showing the " ++
                "glyphs, so no collision result below would mean anything\n",
            .{ control.a, control.b, control_ratio, control_floor },
        );
        return error.VisualHarnessNotObservingGlyphs;
    }

    // Reported unconditionally: a visual assertion that only speaks when it
    // fails leaves no way to tell a comfortable pass from a marginal one, and
    // no record of what this host actually rendered.
    std.debug.print(
        "[gui] emoji_cluster_cache: control '{s}' vs '{s}' = {d:.5} of pixels; " ++
            "bar for the pairs below is {d:.5}\n",
        .{ control.a, control.b, control_ratio, control_ratio * min_share_of_control },
    );

    const min_diff = control_ratio * min_share_of_control;
    for (pairs) |pair| {
        const ratio = try pairDiff(alloc, g, pair);
        std.debug.print(
            "[gui] emoji_cluster_cache: {s} '{s}' vs '{s}' = {d:.5} ({d:.0}% of control)\n",
            .{ pair.name, pair.a, pair.b, ratio, ratio / control_ratio * 100.0 },
        );
        if (ratio < min_diff) {
            std.debug.print(
                "visual: emoji_cluster_cache/{s}: '{s}' and '{s}' differ in only " ++
                    "{d:.5} of pixels, {d:.1}% of the control's {d:.5} — the second " ++
                    "cluster rendered the first one's bitmap\n",
                .{ pair.name, pair.a, pair.b, ratio, ratio / control_ratio * 100.0, control_ratio },
            );
            return error.EmojiClusterCollision;
        }
    }
}

/// Render `a`, then `b`, in one session so the first populates the fallback
/// glyph cache and the second probes it. Returns the fraction of pixels that
/// differ between the two frames.
fn pairDiff(alloc: std.mem.Allocator, g: *driver.Gui, pair: Pair) !f64 {
    try g.exec("execute('%delete _')");

    const cmd_a = try fillCmd(alloc, pair.a);
    defer alloc.free(cmd_a);
    try g.exec(cmd_a);
    var img_a = try g.captureStable(crop, 6000);
    defer img_a.deinit(alloc);

    const cmd_b = try fillCmd(alloc, pair.b);
    defer alloc.free(cmd_b);
    try g.exec(cmd_b);
    var img_b = try g.captureStable(crop, 6000);
    defer img_b.deinit(alloc);

    return visual.regionDiffRatio(img_a, img_b, .{}, 6);
}

/// Saturate the buffer with one emoji so the compared area is the whole
/// viewport. The emoji goes in a double-quoted Vim string nested inside the
/// single-quoted execute() argument; none of these sequences contain either
/// quote, so no escaping is needed.
fn fillCmd(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "execute('call setline(1, repeat([repeat(\"{s}\", {d})], {d}))')",
        .{ text, fill_cols, fill_rows },
    );
}
