// born_external_anchor_float — a float anchored to an external window must be
// composited into that window's rows, whichever way the window became external.
//
// An external grid can reach `external_grids` two ways, and only one of them
// leaves a position behind. Split-then-detach sends `win_pos` first, so
// `Grid.setWinExternalPos` copies that entry into ExternalGridInfo.start_row.
// A window born external — `nvim_open_win(0, true, {external=true})` — never
// gets a `win_pos`, and `win_external_pos` carries no coordinates, so
// start_row keeps its -1 initialiser.
//
// A float anchored to an external window is not a main-surface layer
// (`collectMainLayerEntries` skips it); it is composited into the anchor's own
// rows instead. Both halves of that compositing read the float's stored
// win_pos against the anchor's origin — `Grid.dirtyCompositedRow` and
// `buildExternalFloatRowIndexWithLimits` — and that origin is 0 for an anchor
// with no position of its own, which is exactly the base redraw_handler used
// when it stored the float's coordinates. Reading a negative start_row as "no
// compositing" instead would leave the born-external route drawn by nobody.
//
// This is a dirty-row oracle only. Marking the rows is necessary but not
// sufficient: a fix that repaired `dirtyCompositedRow` alone, leaving the row
// index unbuilt, would still turn this green while the float stayed invisible.
// The pixel side is gui/scenarios/visual/extfloat_over_born_external_anchor.
//
// The dirty set is what a frontend would be asked to repaint, and this harness
// leaves `on_vertices_row` null so it only accumulates — clearing it right
// before the float opens makes the rows that opening dirtied readable.
//
// The oracle is differential: the split-then-detach route is the control that
// says what compositing looks like. If the control dirties nothing the harness
// is broken, not the product, and this reports that instead.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

/// Where the float sits inside the anchor, and how tall. Strictly inside the
/// anchor's 20 rows, so every covered row has an anchor row to land on.
const float_row: u32 = 8;
const float_height: u32 = 6;

const Route = enum { born_external, split_then_detach };

const Observation = struct {
    ext_grid: i64,
    start_row: i32,
    float_grid: i64,
    /// Rows of the anchor under the float that the open marked for repaint.
    covered_dirty: u32,
    /// Rows anywhere in the anchor that the open marked for repaint.
    total_dirty: u32,
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

    // The anchor's own content must have dirtied something before the clear.
    // Without that, a zero below could just mean this grid has no readable
    // dirty set rather than that nothing composited into it.
    var setup_dirty: u32 = 0;
    var sr: u32 = 0;
    while (sr < ext_size.rows) : (sr += 1) {
        if (h.isRowDirty(ext_grid, sr)) setup_dirty += 1;
    }
    if (setup_dirty == 0) {
        std.debug.print(
            "[e2e] anchor grid {d} reported no dirty rows even for its own content; its dirty set is not readable\n",
            .{ext_grid},
        );
        return error.AnchorDirtySetUnreadable;
    }

    // Everything the anchor's own content dirtied belongs to the setup, not to
    // the float; only what follows this line is the measurement.
    h.clearDirtyRows(ext_grid);

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

    var out: Observation = .{
        .ext_grid = ext_grid,
        .start_row = h.externalGridStartRow(ext_grid),
        .float_grid = float_grid,
        .covered_dirty = 0,
        .total_dirty = 0,
    };
    var r: u32 = 0;
    while (r < ext_size.rows) : (r += 1) {
        if (!h.isRowDirty(ext_grid, r)) continue;
        out.total_dirty += 1;
        if (r >= float_row and r < float_row + float_height) out.covered_dirty += 1;
    }
    return out;
}

pub fn run(alloc: std.mem.Allocator) !void {
    const control = try observe(alloc, .split_then_detach);
    const suspect = try observe(alloc, .born_external);

    std.debug.print(
        "[e2e] born_external_anchor_float: split-then-detach start_row={d} covered_dirty={d}/{d} total_dirty={d}\n" ++
            "[e2e] born_external_anchor_float: born-external     start_row={d} covered_dirty={d}/{d} total_dirty={d}\n",
        .{
            control.start_row, control.covered_dirty, float_height, control.total_dirty,
            suspect.start_row, suspect.covered_dirty, float_height, suspect.total_dirty,
        },
    );

    // Vacuity gate: without a control that composites, any number on the
    // suspect route says nothing about the product.
    if (control.covered_dirty != float_height) {
        std.debug.print(
            "[e2e] the CONTROL route marked {d} of the {d} rows its float covers (start_row={d}); " ++
                "this measurement proves nothing\n",
            .{ control.covered_dirty, float_height, control.start_row },
        );
        return error.ControlDidNotComposite;
    }

    // The two routes must be indistinguishable from the anchor's dirty set.
    if (suspect.covered_dirty != float_height) {
        std.debug.print(
            "[e2e] a float over an anchor born external (start_row={d}) marked {d} of the {d} rows it covers " ++
                "for repaint, while the same float over a detached-split anchor (start_row={d}) marked {d}. " ++
                "The float's win_pos was stored against an origin of 0, so every consumer must read it back " ++
                "against 0 too\n",
            .{ suspect.start_row, suspect.covered_dirty, float_height, control.start_row, control.covered_dirty },
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
