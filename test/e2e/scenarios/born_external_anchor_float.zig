// born_external_anchor_float — a float anchored to an external window must be
// composited into that window, whichever way the window became external.
//
// An external grid can reach `external_grids` two ways, and only one of them
// leaves a position behind. Split-then-detach sends `win_pos` first, so
// `Grid.setWinExternalPos` copies that entry into ExternalGridInfo.start_row.
// A window born external — `nvim_open_win(0, true, {external=true})` — never
// gets a `win_pos`, and `win_external_pos` carries no coordinates, so
// start_row keeps its -1 initialiser.
//
// A float anchored to an external window is not a main-surface layer; it is
// placed in the anchor's own surface instead. The float's stored win_pos is
// read against the anchor's origin, which is 0 for an anchor with no position
// of its own — exactly the base redraw_handler used when it stored the float's
// coordinates. Reading a negative start_row as "no compositing" instead would
// leave the born-external route drawn by nobody.
//
// The oracle is the layout the core publishes for the anchor's surface: where
// it places the float is what the frontend draws it at. The pixel side is
// gui/scenarios/visual/extfloat_over_born_external_anchor.
//
// The oracle is differential: the split-then-detach route is the control that
// says what compositing looks like. If the control places nothing the harness
// is broken, not the product, and this reports that instead.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

/// Where the float sits inside the anchor, and how tall. Strictly inside the
/// anchor's 20 rows.
const float_row: u32 = 8;
const float_height: u32 = 6;

const Route = enum { born_external, split_then_detach };

const Observation = struct {
    ext_grid: i64,
    start_row: i32,
    float_grid: i64,
    /// Where the anchor's surface layout placed the float, or null when it
    /// placed it nowhere.
    placed_y_px: ?i32,
};

fn contains(ids: []const i64, id: i64) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

fn observe(alloc: std.mem.Allocator, route: Route) !Observation {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("call setline(1, map(range(1, 300), '\"line \" . v:val'))");
    const main_grid = h.winGrid();
    try h.waitRowText(main_grid, 0, "line 1", h.opts.timeout_ms);

    switch (route) {
        .born_external => try h.command(
            "lua _G.e2e_anchor = vim.api.nvim_open_win(0, true, " ++
                "{external=true, width=40, height=20})",
        ),
        .split_then_detach => {
            // An ordinary split first, and it has to reach the core as a
            // `win_pos` before the detach, which is the entry
            // `setWinExternalPos` copies into start_row.
            try h.command("lua _G.e2e_anchor = vim.api.nvim_open_win(0, true, {split='right', width=40})");
            const CtxSplit = struct { home: i64 };
            try h.waitUntil(CtxSplit{ .home = main_grid }, struct {
                fn check(c: CtxSplit, hh: *Harness) bool {
                    const g = hh.cursor().grid_id;
                    return g != c.home and g != 1 and hh.gridPos(g) != null;
                }
            }.check, h.opts.timeout_ms);
            try h.command("lua vim.api.nvim_win_set_config(_G.e2e_anchor, {external=true, width=40, height=20})");
        },
    }

    const CtxExt = struct { home: i64 };
    try h.waitUntil(CtxExt{ .home = main_grid }, struct {
        fn check(c: CtxExt, hh: *Harness) bool {
            const g = hh.cursor().grid_id;
            return g != c.home and hh.isExternalGrid(g);
        }
    }.check, h.opts.timeout_ms);

    const ext_grid = h.cursor().grid_id;
    const ext_size = h.subGridSize(ext_grid) orelse return error.AnchorGridNotFound;
    if (ext_size.rows < float_row + float_height) return error.AnchorTooShort;
    try h.waitRowText(ext_grid, 0, "line 1", h.opts.timeout_ms);

    const before_pos = try h.positionedGridsAlloc(alloc);
    defer alloc.free(before_pos);

    try h.command(
        "lua _G.e2e_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
            "{relative='win', win=_G.e2e_anchor, row=8, col=2, width=20, height=6, style='minimal'})",
    );

    const CtxFloat = struct { before: []const i64, ext: i64 };
    try h.waitUntil(CtxFloat{ .before = before_pos, .ext = ext_grid }, struct {
        fn check(c: CtxFloat, hh: *Harness) bool {
            const now = hh.positionedGridsAlloc(hh.alloc) catch return false;
            defer hh.alloc.free(now);
            for (now) |id| {
                if (contains(c.before, id)) continue;
                const p = hh.gridPos(id) orelse continue;
                if (p.anchor_grid == c.ext) return true;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    const after_pos = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after_pos);
    var float_grid: i64 = 0;
    for (after_pos) |id| {
        if (contains(before_pos, id)) continue;
        const p = h.gridPos(id) orelse continue;
        if (p.anchor_grid == ext_grid) float_grid = id;
    }
    if (float_grid == 0) return error.FloatNotAnchoredToExternal;

    // The layout reaches the frontend with the flush that follows the float's
    // placement; give it that flush.
    const CtxPlaced = struct { ext: i64, float: i64 };
    h.waitUntil(CtxPlaced{ .ext = ext_grid, .float = float_grid }, struct {
        fn check(c: CtxPlaced, hh: *Harness) bool {
            return hh.layoutPlacement(c.ext, c.float) != null;
        }
    }.check, h.opts.timeout_ms) catch {};

    return .{
        .ext_grid = ext_grid,
        .start_row = h.externalGridStartRow(ext_grid),
        .float_grid = float_grid,
        .placed_y_px = if (h.layoutPlacement(ext_grid, float_grid)) |p| p.y_px else null,
    };
}

pub fn run(alloc: std.mem.Allocator) !void {
    const control = try observe(alloc, .split_then_detach);
    const suspect = try observe(alloc, .born_external);

    std.debug.print(
        "[e2e] born_external_anchor_float: split-then-detach start_row={d} placed_y_px={?d}\n" ++
            "[e2e] born_external_anchor_float: born-external     start_row={d} placed_y_px={?d}\n",
        .{ control.start_row, control.placed_y_px, suspect.start_row, suspect.placed_y_px },
    );

    // Vacuity gate: without a control that composites, any number on the
    // suspect route says nothing about the product.
    const control_y = control.placed_y_px orelse {
        std.debug.print(
            "[e2e] the CONTROL route's layout placed no float in its anchor (start_row={d}); " ++
                "this measurement proves nothing\n",
            .{control.start_row},
        );
        return error.ControlDidNotComposite;
    };

    // The two routes must place the float identically in the anchor.
    if (suspect.placed_y_px == null or suspect.placed_y_px.? != control_y) {
        std.debug.print(
            "[e2e] a float over an anchor born external (start_row={d}) was placed at y={?d}, while the same " ++
                "float over a detached-split anchor (start_row={d}) was placed at y={d}. The float's win_pos " ++
                "was stored against an origin of 0, so every consumer must read it back against 0 too\n",
            .{ suspect.start_row, suspect.placed_y_px, control.start_row, control_y },
        );
        return error.BornExternalAnchorNeverComposites;
    }

    // start_row itself must NOT have been normalized: zonvie_core_is_float_external
    // reads it as the born-external/detached discriminator, and both frontends
    // pick window styling from it.
    if (suspect.start_row >= 0) {
        std.debug.print(
            "[e2e] the born-external anchor now reports start_row={d}; a write-site normalization would " ++
                "silently flip zonvie_core_is_float_external for every external window\n",
            .{suspect.start_row},
        );
        return error.BornExternalStartRowNormalized;
    }
}
