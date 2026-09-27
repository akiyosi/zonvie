// margin_scroll.zig — the measurement shared by the three margin-flicker
// scenarios (main_margin_, main_float_margin_ and
// extfloat_margin_scroll_flicker). Each scenario keeps its own band
// geometry, because each surface logs it differently; the sampling and the
// checks on it are the same.
//
// macOS-only, like the scenarios that use it.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

/// Width of the scrollbar overlay strip on the right, excluded from every
/// comparison.
pub const scrollbar_exclude_px: u32 = 48;

fn compareWidth(img: capture.Image) u32 {
    return if (img.w > scrollbar_exclude_px) img.w - scrollbar_exclude_px else img.w;
}

/// Capture rows of the two margin bands, [top_start, top_end) and
/// [bot_start, bot_end).
pub const Bands = struct { top_start: usize, top_end: usize, bot_start: usize, bot_end: usize };

/// True when every pixel in rows [start, end) up to `width` is the same
/// colour — what a region looks like when nothing was drawn into it.
pub fn bandIsUniform(img: capture.Image, start: usize, end: usize, width: u32) bool {
    if (end <= start or end > img.h or width == 0) return false;
    const stride = @as(usize, img.w) * 4;
    const first = img.rgba[start * stride ..][0..4].*;
    var row = start;
    while (row < end) : (row += 1) {
        const off = row * stride;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            if (!std.mem.eql(u8, img.rgba[off + x * 4 .. off + x * 4 + 4], &first)) return false;
        }
    }
    return true;
}

/// True when rows [start, end) are pixel-identical between the two images
/// up to `width` (the scrollbar strip is excluded by the caller).
pub fn bandsEqual(a: capture.Image, b: capture.Image, start: usize, end: usize, width: u32) bool {
    if (end <= start or end > a.h or end > b.h or a.w != b.w or width == 0) return true;
    const stride = @as(usize, a.w) * 4;
    const bytes = @as(usize, width) * 4;
    var row = start;
    while (row < end) : (row += 1) {
        const off = row * stride;
        if (!std.mem.eql(u8, a.rgba[off .. off + bytes], b.rgba[off .. off + bytes])) return false;
    }
    return true;
}

fn nudge(window: platform.MainWindow, pid: i32, step_px: f64, steps: u32) bool {
    if (!platform.scrollBegin(pid, window)) return false;
    var n: u32 = 0;
    while (n < steps) : (n += 1) {
        platform.scrollStep(step_px);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();
    return true;
}

/// Asks a scenario's own `marginBand` for the bands until its log has the
/// line they come from. The first settle phase starts before it does.
pub fn LogBands(comptime marginBand: anytype) type {
    return struct {
        alloc: std.mem.Allocator,
        capture_h: usize,
        since_ms: f64,

        pub fn bands(r: @This()) ?Bands {
            return marginBand(r.alloc, r.capture_h, r.since_ms) catch null;
        }
    };
}

/// For a phase whose bands are already known.
pub const known_bands = struct {
    pub fn bands(_: @This()) ?Bands {
        return null;
    }
}{};

/// Captures that showed a margin band or the mid row differing from the
/// rest reference.
pub const Settle = struct { shots: usize = 0, top: usize = 0, bottom: usize = 0, body: usize = 0 };

/// Nudge by `step_px` and lift with no momentum, then sample `cycles`
/// captures of the settle against the rest reference `base`. The nudge
/// repeats every 20 captures, and only after the previous settle has run
/// down: overlapping them accumulates offset past a whole row, which emits a
/// grid_scroll and leaves the settle path. Bands are compared once known;
/// while `bands.*` is null, `source.bands()` is asked on every capture.
pub fn sampleSettle(
    alloc: std.mem.Allocator,
    pid: i32,
    window: platform.MainWindow,
    base: capture.Image,
    step_px: f64,
    nudge_steps: u32,
    cycles: u32,
    bands: *?Bands,
    source: anytype,
) !Settle {
    if (!nudge(window, pid, step_px, nudge_steps)) return error.ScrollRefused;
    var out: Settle = .{};
    var c: u32 = 0;
    while (c < cycles) : (c += 1) {
        var shot = capture.captureWindow(alloc, window.number) catch continue;
        out.shots += 1;
        if (bands.* == null) bands.* = source.bands();
        defer shot.deinit(alloc);
        if (shot.w != base.w or shot.h != base.h) continue;
        const cw = compareWidth(shot);
        if (bands.*) |b| {
            if (!bandsEqual(shot, base, b.top_start, b.top_end, cw)) out.top += 1;
            if (!bandsEqual(shot, base, b.bot_start, b.bot_end, cw)) out.bottom += 1;
        }
        const stride = @as(usize, shot.w) * 4;
        const mid = (shot.h / 2) * stride;
        const cmp = @as(usize, cw) * 4;
        if (!std.mem.eql(u8, shot.rgba[mid .. mid + cmp], base.rgba[mid .. mid + cmp])) out.body += 1;

        if (c % 20 == 19) {
            gui_io.sleepNs(400 * std.time.ns_per_ms);
            _ = nudge(window, pid, step_px, nudge_steps);
        }
    }
    return out;
}

pub const BlankBand = struct { shots: usize = 0, blank: usize = 0 };

/// Scroll hard by `hard_px` per step, LET GO, and keep watching the settle.
/// While the fingers are down new commits republish the retained rows every
/// frame, so the band the offset opens only goes empty once the commits stop
/// and the animation is still running it out. Counts captures whose rows
/// [blank_start, blank_end) are uniform, i.e. the band came up empty.
pub fn hardScrollBlankBand(
    alloc: std.mem.Allocator,
    pid: i32,
    window: platform.MainWindow,
    hard_px: f64,
    blank_start: usize,
    blank_end: usize,
) BlankBand {
    var out: BlankBand = .{};
    if (!platform.scrollBegin(pid, window)) return out;
    var k: u32 = 0;
    while (k < 12) : (k += 1) {
        platform.scrollStep(hard_px);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();
    while (k < 40) : (k += 1) {
        var shot = capture.captureWindow(alloc, window.number) catch continue;
        defer shot.deinit(alloc);
        out.shots += 1;
        if (bandIsUniform(shot, blank_start, blank_end, compareWidth(shot))) out.blank += 1;
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    return out;
}

pub const Coverage = struct { frames: usize = 0, uncovered: usize = 0 };

/// Scroll-offset log lines (`ndc`, `cellNDC`, `retained`) whose offset is
/// SHRINKING, and how many of those retained fewer rows than the band the
/// offset holds open. A frame where the offset just GREW is the wheel's
/// lookahead booking: no row has left yet and the edge stretch legitimately
/// covers the band, so counting it would fail correct code.
pub fn shrinkCoverage(lines: []const u8) Coverage {
    var out: Coverage = .{};
    var prev_ndc: ?f64 = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const ndc = app_log.field(line, "ndc") orelse continue;
        const cell_ndc = app_log.field(line, "cellNDC") orelse continue;
        const retained = app_log.field(line, "retained") orelse continue;
        defer prev_ndc = ndc;
        if (cell_ndc <= 0) continue;
        const shrinking = if (prev_ndc) |p| @abs(ndc) < @abs(p) else false;
        if (!shrinking) continue;
        // Same rounding as ScrollRetention.coversBand.
        const band_rows = std.math.ceil(@abs(ndc) / cell_ndc - 0.001);
        if (band_rows < 1) continue;
        out.frames += 1;
        if (retained < band_rows) out.uncovered += 1;
    }
    return out;
}

pub fn shrinkCoverageSince(alloc: std.mem.Allocator, log_path: []const u8, marker: []const u8, since_ms: f64) !Coverage {
    const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(lines);
    return shrinkCoverage(lines);
}

test "margin_scroll: shrinkCoverage counts only shrinking offsets that outgrow the retained rows" {
    const lines =
        "[x] scroll offset: ndc=-0.30 cellNDC=0.10 retained=3\n" ++ // first line: nothing to shrink from
        "[x] scroll offset: ndc=-0.25 cellNDC=0.10 retained=2\n" ++ // shrinking, needs 3 > 2: uncovered
        "[x] scroll offset: ndc=-0.40 cellNDC=0.10 retained=0\n" ++ // growing: lookahead booking, skipped
        "[x] scroll offset: ndc=-0.20 cellNDC=0.10 retained=2\n" ++ // shrinking, needs 2: covered
        "[x] scroll offset: ndc=-0.00005 cellNDC=0.10 retained=0\n" ++ // shrinking below one row: skipped
        "[x] scroll offset: cellNDC=0.10 retained=0\n"; // no ndc: skipped
    const cov = shrinkCoverage(lines);
    try std.testing.expectEqual(@as(usize, 2), cov.frames);
    try std.testing.expectEqual(@as(usize, 1), cov.uncovered);
}

test "margin_scroll: band predicates" {
    // 2x3 image: rows 0-1 uniform, row 2 differs in its second pixel.
    var px = [_]u8{0} ** (2 * 3 * 4);
    px[2 * 2 * 4 + 4] = 9;
    const a: capture.Image = .{ .w = 2, .h = 3, .rgba = &px };
    try std.testing.expect(bandIsUniform(a, 0, 2, 2));
    try std.testing.expect(!bandIsUniform(a, 0, 3, 2));
    try std.testing.expect(bandIsUniform(a, 0, 3, 1)); // the differing pixel is past `width`
    try std.testing.expect(!bandIsUniform(a, 1, 1, 2)); // an empty band is not "blank"

    var px2 = px;
    px2[0] = 1;
    const b: capture.Image = .{ .w = 2, .h = 3, .rgba = &px2 };
    try std.testing.expect(!bandsEqual(a, b, 0, 1, 2));
    try std.testing.expect(bandsEqual(a, b, 1, 3, 2));
}
