// visual.zig — platform-neutral golden-image comparison for the GUI driver.
//
// Capture and PNG I/O are platform-specific (driver.capture); the compare
// policy, golden management, and diff output live here.
//
// Policy (chosen to survive the flakiness that makes naive pixel diffing
// unusable — see the AI-testing research report):
//   - Per-OS goldens under test/gui/golden/<os>/ (subpixel-AA vs ClearType
//     means cross-OS comparison is meaningless).
//   - Missing golden => write it and PASS (baseline established).
//   - ZONVIE_GUI_UPDATE_GOLDEN set => overwrite the golden and PASS.
//   - Otherwise compare with a small per-channel tolerance and a max
//     fraction of differing pixels; on failure write actual.png + diff.png
//     to tmp/ for human inspection.
// Goldens are environment-specific (DPI, font rendering) and are gitignored;
// each developer regenerates them on a known-good state.

const std = @import("std");
const builtin = @import("builtin");
const capture = @import("driver.zig").capture;

const os_dir = switch (builtin.os.tag) {
    .windows => "windows",
    .macos => "macos",
    else => "other",
};

pub const Options = struct {
    /// Max absolute per-channel difference still treated as "equal".
    tol_per_channel: u8 = 6,
    /// Max fraction of pixels allowed to exceed the tolerance. Measured
    /// separation on macOS: identical content reproduces at ~0 differing
    /// pixels (window-id crop + steady cursor + fixed font + two-frame
    /// settle), while a single-word case change trips ~0.0016. 0.0002 sits
    /// well between — tolerant of AA jitter, sensitive to real changes.
    max_diff_ratio: f64 = 0.0002,
};

/// Compare `captured` against the golden named `name` (without extension).
/// Establishes or updates the golden when appropriate; otherwise asserts.
/// `captured` is borrowed (caller frees it).
pub fn assertMatch(alloc: std.mem.Allocator, name: []const u8, captured: capture.Image, opts: Options) !void {
    const dir = try std.fmt.allocPrint(alloc, "test/gui/golden/{s}", .{os_dir});
    defer alloc.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    const golden = try std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ dir, name, capture.image_ext });
    defer alloc.free(golden);

    const update = updateRequested(alloc);
    const exists = blk: {
        std.fs.cwd().access(golden, .{}) catch break :blk false;
        break :blk true;
    };

    if (update or !exists) {
        try capture.writeImage(alloc, golden, captured);
        std.debug.print(
            "[gui] golden {s}: {s} ({d}x{d}) — passing\n",
            .{ if (update) "updated" else "created", golden, captured.w, captured.h },
        );
        return;
    }

    var ref = try capture.readImage(alloc, golden);
    defer ref.deinit(alloc);

    if (ref.w != captured.w or ref.h != captured.h) {
        std.debug.print(
            "[gui] visual size mismatch for {s}: golden {d}x{d} vs captured {d}x{d}\n",
            .{ name, ref.w, ref.h, captured.w, captured.h },
        );
        try dumpActual(alloc, name, captured);
        return error.VisualSizeMismatch;
    }

    const total = @as(usize, captured.w) * @as(usize, captured.h);
    var diff_count: usize = 0;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const o = i * 4;
        const dr = absDiff(ref.rgba[o], captured.rgba[o]);
        const dg = absDiff(ref.rgba[o + 1], captured.rgba[o + 1]);
        const db = absDiff(ref.rgba[o + 2], captured.rgba[o + 2]);
        if (dr > opts.tol_per_channel or dg > opts.tol_per_channel or db > opts.tol_per_channel) {
            diff_count += 1;
        }
    }

    const ratio = @as(f64, @floatFromInt(diff_count)) / @as(f64, @floatFromInt(total));
    if (ratio > opts.max_diff_ratio) {
        std.debug.print(
            "[gui] visual mismatch for {s}: {d}/{d} pixels differ ({d:.4} > {d:.4})\n",
            .{ name, diff_count, total, ratio, opts.max_diff_ratio },
        );
        printDiffHeatmap(ref, captured, opts.tol_per_channel);
        try dumpActual(alloc, name, captured);
        try dumpDiff(alloc, name, ref, captured, opts.tol_per_channel);
        return error.VisualMismatch;
    }
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Golden-update mode is requested only when ZONVIE_GUI_UPDATE_GOLDEN is set
/// to a non-empty, non-"0" value. Checking the VALUE (not mere existence)
/// avoids a common footgun: an empty/leftover var silently forcing every
/// run into update mode so comparisons never happen.
fn updateRequested(alloc: std.mem.Allocator) bool {
    const v = std.process.getEnvVarOwned(alloc, "ZONVIE_GUI_UPDATE_GOLDEN") catch return false;
    defer alloc.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Print a coarse ASCII heatmap of where pixels differ, so the diff
/// distribution is visible without opening the image. Scattered density
/// across all text => antialiasing/subpixel (e.g. ClearType) variance;
/// a few hot cells => a localized element (cursor, a line, chrome).
fn printDiffHeatmap(ref: capture.Image, captured: capture.Image, tol: u8) void {
    const cols: u32 = 40;
    const rows: u32 = 20;
    var grid = [_]u32{0} ** (40 * 20);
    const cw = @max(1, captured.w / cols);
    const ch = @max(1, captured.h / rows);

    var y: u32 = 0;
    while (y < captured.h) : (y += 1) {
        var x: u32 = 0;
        while (x < captured.w) : (x += 1) {
            const o = (@as(usize, y) * @as(usize, captured.w) + @as(usize, x)) * 4;
            const differ = absDiff(ref.rgba[o], captured.rgba[o]) > tol or
                absDiff(ref.rgba[o + 1], captured.rgba[o + 1]) > tol or
                absDiff(ref.rgba[o + 2], captured.rgba[o + 2]) > tol;
            if (!differ) continue;
            const gx = @min(cols - 1, x / cw);
            const gy = @min(rows - 1, y / ch);
            grid[gy * cols + gx] += 1;
        }
    }

    const cell_px = cw * ch;
    std.debug.print("[gui] diff heatmap ({d}x{d} cells, ' '=0 .<2% :<10% +<30% #>=30%):\n", .{ cols, rows });
    var gy: u32 = 0;
    while (gy < rows) : (gy += 1) {
        std.debug.print("[gui] ", .{});
        var gx: u32 = 0;
        while (gx < cols) : (gx += 1) {
            const d = grid[gy * cols + gx];
            const pct = if (cell_px == 0) 0 else d * 100 / cell_px;
            const ch_out: u8 = if (d == 0) ' ' else if (pct < 2) '.' else if (pct < 10) ':' else if (pct < 30) '+' else '#';
            std.debug.print("{c}", .{ch_out});
        }
        std.debug.print("\n", .{});
    }
}

fn dumpActual(alloc: std.mem.Allocator, name: []const u8, captured: capture.Image) !void {
    std.fs.cwd().makePath("tmp") catch {};
    const p = try std.fmt.allocPrint(alloc, "tmp/visual_{s}_actual{s}", .{ name, capture.image_ext });
    defer alloc.free(p);
    capture.writeImage(alloc, p, captured) catch {};
    std.debug.print("[gui]   wrote actual to {s}\n", .{p});
}

/// Write a diff image: differing pixels in red, matching pixels dimmed.
fn dumpDiff(alloc: std.mem.Allocator, name: []const u8, ref: capture.Image, captured: capture.Image, tol: u8) !void {
    const total = @as(usize, captured.w) * @as(usize, captured.h);
    const buf = try alloc.alloc(u8, total * 4);
    defer alloc.free(buf);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const o = i * 4;
        const differ = absDiff(ref.rgba[o], captured.rgba[o]) > tol or
            absDiff(ref.rgba[o + 1], captured.rgba[o + 1]) > tol or
            absDiff(ref.rgba[o + 2], captured.rgba[o + 2]) > tol;
        if (differ) {
            buf[o] = 255;
            buf[o + 1] = 0;
            buf[o + 2] = 0;
        } else {
            const dim = captured.rgba[o] / 3 + captured.rgba[o + 1] / 3 + captured.rgba[o + 2] / 3;
            buf[o] = dim;
            buf[o + 1] = dim;
            buf[o + 2] = dim;
        }
        buf[o + 3] = 255;
    }
    const p = try std.fmt.allocPrint(alloc, "tmp/visual_{s}_diff{s}", .{ name, capture.image_ext });
    defer alloc.free(p);
    capture.writeImage(alloc, p, .{ .w = captured.w, .h = captured.h, .rgba = buf }) catch {};
    std.debug.print("[gui]   wrote diff to {s}\n", .{p});
}
