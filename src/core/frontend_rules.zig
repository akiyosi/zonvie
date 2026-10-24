//! Rules both frontends applied with their own copies: the commands a tab drag
//! sends, whether a custom shader animates, where the message floats and the
//! cmdline sit, and the cursor blink cadence. Pure; the frontends keep the
//! windows, timers and events.

const std = @import("std");

// ---------------------------------------------------------------------------
// Tabs

/// The command that moves the tab at `from_idx` (0-based) to the drop
/// insertion index `drop_idx` of the list before the move, or null when the
/// drop leaves it where it is. `:tabmove N` acts on the current tab and moves
/// it after tab page N of that same list (1-based, 0 = front), so the dragged
/// tab is made current in the same command: sent as two commands, a tab switch
/// landing between them (an autocmd, a job opening a tab) moved another tab.
pub fn tabMoveCommand(buf: []u8, from_idx: u32, drop_idx: u32, tab_count: u32) ?[]const u8 {
    if (from_idx >= tab_count) return null;
    // Onto its own slot, or just past it, is where it already is.
    if (drop_idx == from_idx or drop_idx == from_idx + 1) return null;
    const pos = @min(drop_idx, tab_count);
    return std.fmt.bufPrint(buf, "{d}tabnext | tabmove {d}", .{ from_idx + 1, pos }) catch null;
}

/// The insertion index a tab drag at `pos` drops on: the first of `count`
/// equal tabs (tab i starts at origin + i*stride and is `size` long) whose
/// centre is past `pos`, else `count`. One axis: x on a tab bar, y down a
/// sidebar.
pub fn tabDropIndex(pos: f64, count: u32, origin: f64, stride: f64, size: f64) u32 {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos < origin + @as(f64, @floatFromInt(i)) * stride + size / 2) return i;
    }
    return count;
}

test "tabDropIndex is the first tab whose centre is past the pointer" {
    // Tabs at 10, 110, 210, each 90 long: centres 55, 155, 255.
    try std.testing.expectEqual(@as(u32, 0), tabDropIndex(54, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 1), tabDropIndex(55, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 2), tabDropIndex(200, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 3), tabDropIndex(900, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 0), tabDropIndex(0, 0, 10, 100, 90));
}

/// The command that moves the only window of tab `tab_idx` (0-based) into an
/// external window, leaving a scratch buffer in the tab. Refuses a tab with a
/// split. nvim_open_win rather than a split: under ext_windows a split would
/// open another external window.
pub fn externalizeTabCommand(buf: []u8, tab_idx: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "lua vim.cmd('{d}tabnext'); local tp=vim.api.nvim_get_current_tabpage(); local ws=vim.api.nvim_tabpage_list_wins(tp); if #ws>1 then vim.notify('Cannot externalize: split window',vim.log.levels.WARN); return end; local w=ws[1]; local buf=vim.api.nvim_win_get_buf(w); local cur=vim.api.nvim_win_get_cursor(w); local W=vim.api.nvim_win_get_width(w); local H=vim.api.nvim_win_get_height(w); local ew=vim.api.nvim_open_win(buf,true,{{external=true,width=W,height=H}}); vim.api.nvim_win_set_cursor(ew,cur); vim.api.nvim_win_set_buf(w,vim.api.nvim_create_buf(true,true))", .{tab_idx + 1}) catch null;
}

test "a tab move is one command that selects the dragged tab first" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1tabnext | tabmove 3", tabMoveCommand(&buf, 0, 3, 4).?);
    try std.testing.expectEqualStrings("4tabnext | tabmove 0", tabMoveCommand(&buf, 3, 0, 4).?);
    // Past the end clamps to the last position.
    try std.testing.expectEqualStrings("1tabnext | tabmove 4", tabMoveCommand(&buf, 0, 9, 4).?);
}

test "a tab dropped onto or just past itself does not move" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(tabMoveCommand(&buf, 2, 2, 4) == null);
    try std.testing.expect(tabMoveCommand(&buf, 2, 3, 4) == null);
    try std.testing.expect(tabMoveCommand(&buf, 4, 0, 4) == null);
}

test "externalizing selects the tab by its 1-based number" {
    var buf: [1024]u8 = undefined;
    const cmd = externalizeTabCommand(&buf, 2).?;
    try std.testing.expect(std.mem.startsWith(u8, cmd, "lua vim.cmd('3tabnext');"));
    try std.testing.expect(std.mem.indexOf(u8, cmd, "{external=true,width=W,height=H}") != null);
}

// ---------------------------------------------------------------------------
// on_vertices_row

/// Which layer one on_vertices_row callback updates (zonvie_core.h): MAIN
/// replaces the row, CURSOR without MAIN is cursor-only and leaves the row.
/// The core sets exactly one, from an enum; `none` (neither set) and MAIN for
/// both set are only the decode of a word the core never sends.
pub const RowUpdate = enum(u8) { none = 0, main = 1, cursor_only = 2 };

/// The on_vertices_row flag bits (ZONVIE_VERT_UPDATE_*); c_api re-exports them.
pub const VERT_UPDATE_MAIN: u32 = 1 << 0;
pub const VERT_UPDATE_CURSOR: u32 = 1 << 1;

pub fn rowUpdate(flags: u32) RowUpdate {
    if (flags & VERT_UPDATE_MAIN != 0) return .main;
    if (flags & VERT_UPDATE_CURSOR != 0) return .cursor_only;
    return .none;
}

/// What a MAIN callback for a surface root means for the stored rows.
pub const RootRowDisposition = enum(u8) {
    /// MAIN not set: existing row contents are retained.
    retain_rows = 0,
    /// The zero-cell transition: no row content survives, only the layout.
    layout_only = 1,
    /// A row the authoritative total_rows does not contain.
    out_of_range = 2,
    single_row = 3,
    /// Never sent by the core (row_count is 0 or 1); a consumer keeps its
    /// rows and re-seeds.
    multi_row = 4,
    /// No row payload with a non-zero shape; only the layout is applied.
    no_row = 5,
};

/// From the zonvie_core.h on_vertices_row contract: the layout-only shape is
/// row_count 0, no vertices and a zero dimension; total_rows is authoritative
/// so a row at or past it is not row content; otherwise the row count says.
pub fn rootRowDisposition(update: RowUpdate, row_start: u32, row_count: u32, vert_count: usize, total_rows: u32, total_cols: u32) RootRowDisposition {
    if (update != .main) return .retain_rows;
    if (row_count == 0 and vert_count == 0 and (total_rows == 0 or total_cols == 0)) return .layout_only;
    if (total_rows != 0 and row_start >= total_rows) return .out_of_range;
    return switch (row_count) {
        0 => .no_row,
        1 => .single_row,
        else => .multi_row,
    };
}

test "a row update is MAIN, cursor-only, or neither; MAIN wins the never-sent both" {
    try std.testing.expectEqual(RowUpdate.none, rowUpdate(0));
    try std.testing.expectEqual(RowUpdate.main, rowUpdate(VERT_UPDATE_MAIN));
    try std.testing.expectEqual(RowUpdate.cursor_only, rowUpdate(VERT_UPDATE_CURSOR));
    try std.testing.expectEqual(RowUpdate.main, rowUpdate(VERT_UPDATE_MAIN | VERT_UPDATE_CURSOR));
    // Foreign bits never promote a send.
    const foreign: u32 = ~(VERT_UPDATE_MAIN | VERT_UPDATE_CURSOR);
    try std.testing.expectEqual(RowUpdate.none, rowUpdate(foreign));
    try std.testing.expectEqual(RowUpdate.cursor_only, rowUpdate(foreign | VERT_UPDATE_CURSOR));
}

test "root row disposition follows the on_vertices_row contract" {
    const D = RootRowDisposition;
    const Case = struct { update: RowUpdate, row_start: u32, row_count: u32, vert_count: usize, rows: u32, cols: u32, want: D };
    const cases = [_]Case{
        // "When MAIN is not set, existing row contents must be retained."
        .{ .update = .cursor_only, .row_start = 0, .row_count = 1, .vert_count = 6, .rows = 4, .cols = 10, .want = .retain_rows },
        .{ .update = .none, .row_start = 0, .row_count = 0, .vert_count = 0, .rows = 0, .cols = 0, .want = .retain_rows },
        // Layout-only zero-cell transition: row_count 0, no verts, a zero dimension.
        .{ .update = .main, .row_start = 0, .row_count = 0, .vert_count = 0, .rows = 0, .cols = 10, .want = .layout_only },
        .{ .update = .main, .row_start = 0, .row_count = 0, .vert_count = 0, .rows = 4, .cols = 0, .want = .layout_only },
        .{ .update = .main, .row_start = 0, .row_count = 0, .vert_count = 0, .rows = 0, .cols = 0, .want = .layout_only },
        // Both dimensions non-zero: not a zero-cell layout.
        .{ .update = .main, .row_start = 0, .row_count = 0, .vert_count = 0, .rows = 4, .cols = 10, .want = .no_row },
        // total_rows is authoritative: a row outside it is not row content.
        .{ .update = .main, .row_start = 4, .row_count = 1, .vert_count = 6, .rows = 4, .cols = 10, .want = .out_of_range },
        .{ .update = .main, .row_start = 9, .row_count = 0, .vert_count = 0, .rows = 4, .cols = 10, .want = .out_of_range },
        // No row count yet (first seed): a row payload is still row content.
        .{ .update = .main, .row_start = 0, .row_count = 1, .vert_count = 6, .rows = 0, .cols = 10, .want = .single_row },
        .{ .update = .main, .row_start = 3, .row_count = 1, .vert_count = 6, .rows = 4, .cols = 10, .want = .single_row },
        // An empty row is still a row: it replaces the old contents.
        .{ .update = .main, .row_start = 0, .row_count = 1, .vert_count = 0, .rows = 4, .cols = 10, .want = .single_row },
        .{ .update = .main, .row_start = 0, .row_count = 2, .vert_count = 12, .rows = 4, .cols = 10, .want = .multi_row },
    };
    for (cases) |cs| {
        try std.testing.expectEqual(cs.want, rootRowDisposition(cs.update, cs.row_start, cs.row_count, cs.vert_count, cs.rows, cs.cols));
    }
}

// ---------------------------------------------------------------------------
// Surface frame decision

/// What a surface knows about one frame, after its scroll blit ran and before
/// its render pass is described. Both macOS draw drivers and both Windows
/// paint drivers decided from these facts whether the frame may keep the
/// previous back buffer, which rows it draws and what alpha backgrounds take.
/// A surface that lacks a concept leaves the term at the value that cannot
/// change its own answer. Plain bools and one float, laid out for the C ABI.
pub const SurfaceFrameTerms = extern struct {
    /// Row vertices are in use, so dirty rows describe the frame.
    row_mode: bool = true,
    /// Row mode is a precondition of skipping the pass. A surface whose
    /// whole-grid gate already returned passes true regardless of row_mode.
    row_mode_satisfied: bool = true,
    /// Pixels at these coordinates exist from a previous frame (macOS: has
    /// presented once; Windows: back_tex is valid).
    has_presented_once: bool = false,
    drawable_size_changed: bool = false,
    is_smooth_scrolling: bool = false,
    /// The surface composites translucently, so blending a partial redraw over
    /// the previous frame accumulates alpha (macOS blur; Windows opacity < 1).
    blur_enabled: bool = false,
    /// Blur's two-pass background/glyph pipelines exist, so a dirty-only
    /// redraw overwrites instead of blending. Windows has none.
    use_two_pass: bool = false,
    glow_enabled: bool = false,
    /// ext-cmdline and friends: a viewport origin offset means partial scissor
    /// rects do not line up, so they never reuse the back texture.
    is_decorated_surface: bool = false,
    /// The popupmenu keeps every cell's own opaque background.
    is_popupmenu: bool = false,
    /// The back texture goes through the decorated custom-shader chain, which
    /// discards alpha.
    shader_chain_consumes_surface: bool = false,
    /// The committed rows were generated with the font metrics in force now.
    font_is_current: bool = true,
    /// The layout moved under this surface.
    has_layout_damage: bool = false,
    /// A damaged pixel rectangle no row expresses.
    has_dirty_rect: bool = false,
    /// The pass has rows to draw this frame.
    has_dirty_rows: bool = false,
    /// A layer drawn from this surface's own pass owes work.
    has_layer_work: bool = false,
    /// The commit this frame draws changed no back-texture pixel.
    commit_changes_no_pixels: bool = true,
    has_staged_scroll: bool = false,
    scroll_offset_changed: bool = false,
    /// This surface hosts layers whose contents are not in its dirty-row set.
    hosts_layers_outside_dirty_set: bool = false,
    /// A GPU scroll blit shifted pixels in the back texture this frame.
    scroll_blit_kept_back_texture: bool = false,
    /// The blit shifted the root pass's own rows.
    root_scroll_blit_vacated_band: bool = false,
    /// The driver's own "repaint everything" request (a seed, a resize, the
    /// cursor moving to another grid). Refuses every reuse arm.
    refuses_reuse: bool = false,
    /// The configured background alpha for a blurred, undecorated surface.
    configured_blur_alpha: f32 = 1,
};

/// Which rows a surface's own pass draws (zonvie_frontend.h ZONVIE_ROW_PASS_*).
pub const RowPassPlan = enum(u8) {
    dirty_rows_only = 0,
    dirty_rows_after_scroll_blit = 1,
    all_rows_with_retained = 2,
    all_rows = 3,
};

pub const SurfaceFrameDecision = extern struct {
    /// Nothing draws into the back texture and no hosted layer is outside the
    /// dirty set: the whole pass is skipped.
    reuses_root_contents: bool,
    /// Nothing draws and the hosted layers outside the dirty set are unchanged.
    reuses_hosted_contents: bool,
    /// Hosted layers unchanged but some rows dirty: recompose those bands.
    partial_hosted_contents: bool,
    skips_surface_pass: bool,
    /// Under blur, a dirty-only redraw is still safe (two-pass overwrites).
    can_dirty_only_with_blur: bool,
    /// The render pass loads (keeps) the previous back buffer instead of
    /// clearing it. Windows: preserve_back.
    loads_previous_contents: bool,
    /// No reuse arm is open to this frame's rows: a guard refused, or the
    /// surface blends and has no two-pass path. Meaningful only when
    /// skips_surface_pass is false; under blur without two-pass it can be set
    /// together with skips_surface_pass and loads_previous_contents.
    /// Windows: force_full_rows. On macOS the same fact reaches the plan.
    redraws_everything: bool,
    row_pass_plan: RowPassPlan,
    /// The alpha the row shader multiplies background colours by.
    background_alpha: f32,
};

fn dirtyOnlyWithBlur(t: SurfaceFrameTerms, has_any_dirty_in_row_mode: bool) bool {
    return t.row_mode and t.use_two_pass and has_any_dirty_in_row_mode and
        t.has_presented_once and !t.is_smooth_scrolling and !t.drawable_size_changed and !t.glow_enabled;
}

pub fn surfaceBackgroundAlpha(blur_enabled: bool, is_decorated_surface: bool, shader_chain_consumes_surface: bool, is_popupmenu: bool, configured_blur_alpha: f32) f32 {
    if (is_popupmenu) return 1.0;
    if (is_decorated_surface) {
        if (shader_chain_consumes_surface) return 1.0;
        return if (blur_enabled) 0.0 else 1.0;
    }
    return if (blur_enabled) configured_blur_alpha else 1.0;
}

pub fn surfaceFrameDecision(t: SurfaceFrameTerms) SurfaceFrameDecision {
    // Guards: any one refuses reuse outright.
    const guards_allow = !t.glow_enabled and t.font_is_current and !t.has_layout_damage and
        !t.is_decorated_surface and !t.refuses_reuse;
    const reuse_guards = guards_allow and t.row_mode_satisfied and t.has_presented_once and
        !t.has_staged_scroll and !t.drawable_size_changed and !t.scroll_offset_changed and
        !t.is_smooth_scrolling;
    const no_surface_work = reuse_guards and t.commit_changes_no_pixels and
        !t.has_dirty_rows and !t.has_layer_work and !t.has_dirty_rect;
    const reuses_root = no_surface_work and !t.hosts_layers_outside_dirty_set;
    const reuses_hosted = no_surface_work and t.hosts_layers_outside_dirty_set;
    // Under blur the recompose is only safe as the two passes; fail closed.
    const partial_hosted = reuse_guards and t.hosts_layers_outside_dirty_set and t.has_dirty_rows and
        (!t.blur_enabled or t.use_two_pass);

    const has_any_dirty_in_row_mode = t.row_mode and (t.has_dirty_rows or t.has_layer_work);
    const dirty_blur = dirtyOnlyWithBlur(t, has_any_dirty_in_row_mode);

    // Arms: any one permits reuse. A forced arm holds even under blur.
    const layers_ok = !t.hosts_layers_outside_dirty_set or reuses_hosted or partial_hosted;
    const reuses = guards_allow and layers_ok and
        (t.scroll_blit_kept_back_texture or dirty_blur or reuses_hosted or reuses_root or partial_hosted or
            (!t.is_smooth_scrolling and (t.has_dirty_rect or has_any_dirty_in_row_mode)));
    const forces = guards_allow and
        (t.scroll_blit_kept_back_texture or dirty_blur or reuses_hosted or reuses_root);
    const frame_present = t.has_presented_once and !t.drawable_size_changed;
    const loads = frame_present and (forces or (!t.blur_enabled and reuses));

    const plan: RowPassPlan = blk: {
        const has_dirty = t.has_dirty_rows or t.has_layer_work;
        if (t.use_two_pass) {
            if (t.root_scroll_blit_vacated_band) break :blk .dirty_rows_after_scroll_blit;
            if (dirty_blur and loads) break :blk .dirty_rows_only;
            break :blk .all_rows_with_retained;
        }
        if (t.is_smooth_scrolling) break :blk .all_rows_with_retained;
        if (t.root_scroll_blit_vacated_band) break :blk .dirty_rows_after_scroll_blit;
        if (!t.is_decorated_surface and !t.glow_enabled and has_dirty and !t.drawable_size_changed and loads) {
            break :blk .dirty_rows_only;
        }
        break :blk .all_rows;
    };

    return .{
        .reuses_root_contents = reuses_root,
        .reuses_hosted_contents = reuses_hosted,
        .partial_hosted_contents = partial_hosted,
        .skips_surface_pass = reuses_root or reuses_hosted,
        .can_dirty_only_with_blur = dirty_blur,
        .loads_previous_contents = loads,
        .redraws_everything = !guards_allow or (t.blur_enabled and !t.use_two_pass),
        .row_pass_plan = plan,
        .background_alpha = surfaceBackgroundAlpha(t.blur_enabled, t.is_decorated_surface, t.shader_chain_consumes_surface, t.is_popupmenu, t.configured_blur_alpha),
    };
}

fn termBit(mask: usize, i: u6) bool {
    return (mask >> i) & 1 == 1;
}

// GridSurfaceRenderer.draw as it stood before the decision was shared (the
// oracle D3 transcribed): every assignment of its 13 terms. A skipped pass
// answers "load" (the texture is kept); every other frame must agree exactly.
test "surface frame decision agrees with the main window's original logic" {
    var skip_seen = [2]usize{ 0, 0 };
    var load_seen = [2]usize{ 0, 0 };
    var mask: usize = 0;
    while (mask < (1 << 13)) : (mask += 1) {
        const row_mode = termBit(mask,0);
        const blur = termBit(mask,1);
        const use2pass = blur and termBit(mask, 2);
        const dirty = termBit(mask,3);
        const layer_work = termBit(mask,4);
        const presented = termBit(mask,5);
        const smooth = termBit(mask,6);
        const size_chg = termBit(mask,7);
        const glow = termBit(mask,8);
        const gpu_scroll = termBit(mask,9);
        const rect = termBit(mask,10);
        const new_commit = termBit(mask,11);
        const cursor_only = termBit(mask,12);

        const no_main_work = (!new_commit or cursor_only) and !dirty and !layer_work and !rect and !smooth and !size_chg and presented;
        const skip_main_pass = no_main_work and !glow;
        const has_any_dirty = row_mode and (dirty or layer_work);
        const dirty_blur = row_mode and use2pass and has_any_dirty and presented and !smooth and !size_chg and !glow;
        const should_reuse = !glow and (gpu_scroll or dirty_blur or (!smooth and (rect or has_any_dirty)));
        const force_reuse = !glow and (gpu_scroll or dirty_blur);
        const load = (presented and !size_chg and force_reuse) or (!blur and presented and !size_chg and should_reuse);
        const plan: RowPassPlan = if (use2pass)
            (if (dirty_blur and load) .dirty_rows_only else .all_rows_with_retained)
        else if (smooth)
            .all_rows_with_retained
        else if (!glow and (dirty or layer_work) and !size_chg and load)
            .dirty_rows_only
        else
            .all_rows;

        const d = surfaceFrameDecision(.{
            .row_mode = row_mode,
            .has_presented_once = presented,
            .drawable_size_changed = size_chg,
            .is_smooth_scrolling = smooth,
            .blur_enabled = blur,
            .use_two_pass = use2pass,
            .glow_enabled = glow,
            .has_dirty_rect = rect,
            .has_dirty_rows = dirty,
            .has_layer_work = layer_work,
            .commit_changes_no_pixels = !new_commit or cursor_only,
            .scroll_blit_kept_back_texture = gpu_scroll,
        });
        try std.testing.expectEqual(skip_main_pass, d.skips_surface_pass);
        try std.testing.expect(!d.reuses_hosted_contents);
        try std.testing.expect(!d.partial_hosted_contents);
        try std.testing.expectEqual(dirty_blur, d.can_dirty_only_with_blur);
        if (skip_main_pass) {
            try std.testing.expect(d.loads_previous_contents);
        } else {
            try std.testing.expectEqual(load, d.loads_previous_contents);
            try std.testing.expectEqual(plan, d.row_pass_plan);
        }
        try std.testing.expect(d.row_pass_plan != .dirty_rows_after_scroll_blit);
        skip_seen[@intFromBool(d.skips_surface_pass)] += 1;
        load_seen[@intFromBool(d.loads_previous_contents)] += 1;
    }
    // Every decision took both values, or a loop above asserted nothing.
    try std.testing.expect(skip_seen[0] > 0 and skip_seen[1] > 0);
    try std.testing.expect(load_seen[0] > 0 and load_seen[1] > 0);
}

// ExternalGridView.draw as it stood: every assignment of its 15 terms.
test "surface frame decision agrees with the external window's original logic" {
    var plans_seen = [4]usize{ 0, 0, 0, 0 };
    var mask: usize = 0;
    while (mask < (1 << 15)) : (mask += 1) {
        const row_mode = termBit(mask,0);
        const has_layers = termBit(mask,1);
        const font_current = termBit(mask,2);
        const presented = termBit(mask,3);
        const layout_damage = termBit(mask,4);
        const dirty = termBit(mask,5);
        const pending_scroll = termBit(mask,6);
        const size_chg = termBit(mask,7);
        const scroll_off = termBit(mask,8);
        const smooth = termBit(mask,9);
        const glow = termBit(mask,10);
        const decorated = termBit(mask,11);
        const blur = termBit(mask,12);
        const use2pass = blur and termBit(mask, 13);
        const gpu_scroll = termBit(mask,14);

        const guards = font_current and presented and !layout_damage and !pending_scroll and !size_chg and !scroll_off and !smooth and !glow and !decorated;
        const reuse_hosted = row_mode and has_layers and guards and !dirty;
        const reuse_root = row_mode and !has_layers and !dirty and guards;
        const partial_hosted = row_mode and has_layers and dirty and guards and (!blur or use2pass);
        const skip = row_mode and (reuse_root or reuse_hosted);
        const has_any_dirty = row_mode and dirty;
        const dirty_blur = row_mode and use2pass and has_any_dirty and presented and !smooth and !size_chg and !glow;
        const should_reuse = font_current and !layout_damage and (!has_layers or reuse_hosted or partial_hosted) and !decorated and !glow and
            (partial_hosted or reuse_hosted or reuse_root or gpu_scroll or dirty_blur or (!smooth and has_any_dirty));
        const force_reuse = font_current and !layout_damage and !decorated and !glow and (reuse_hosted or reuse_root or gpu_scroll or dirty_blur);
        const load = (presented and !size_chg and force_reuse) or (!blur and presented and !size_chg and should_reuse);
        const plan: RowPassPlan = if (use2pass)
            (if (gpu_scroll) .dirty_rows_after_scroll_blit else if (dirty_blur and load) .dirty_rows_only else .all_rows_with_retained)
        else if (smooth)
            .all_rows_with_retained
        else if (gpu_scroll)
            .dirty_rows_after_scroll_blit
        else if (!decorated and !glow and dirty and !size_chg and load)
            .dirty_rows_only
        else
            .all_rows;

        const d = surfaceFrameDecision(.{
            .row_mode = row_mode,
            .row_mode_satisfied = row_mode,
            .has_presented_once = presented,
            .drawable_size_changed = size_chg,
            .is_smooth_scrolling = smooth,
            .blur_enabled = blur,
            .use_two_pass = use2pass,
            .glow_enabled = glow,
            .is_decorated_surface = decorated,
            .font_is_current = font_current,
            .has_layout_damage = layout_damage,
            .has_dirty_rows = dirty,
            .has_staged_scroll = pending_scroll,
            .scroll_offset_changed = scroll_off,
            .hosts_layers_outside_dirty_set = has_layers,
            .scroll_blit_kept_back_texture = gpu_scroll,
            .root_scroll_blit_vacated_band = gpu_scroll,
        });
        try std.testing.expectEqual(reuse_hosted, d.reuses_hosted_contents);
        try std.testing.expectEqual(reuse_root, d.reuses_root_contents);
        try std.testing.expectEqual(partial_hosted, d.partial_hosted_contents);
        try std.testing.expectEqual(skip, d.skips_surface_pass);
        try std.testing.expectEqual(dirty_blur, d.can_dirty_only_with_blur);
        try std.testing.expectEqual(load, d.loads_previous_contents);
        try std.testing.expectEqual(plan, d.row_pass_plan);
        plans_seen[@intFromEnum(d.row_pass_plan)] += 1;
    }
    for (plans_seen) |n| try std.testing.expect(n > 0);
}

// The Windows paint policy as it stood: force_full_rows = force_full or
// cursor_grid_changed or glow or opacity < 1; preserve_back = !force_full_rows
// and back_tex_valid. Its terms map onto the shared ones (translucency is
// blur without a two-pass path; a seed or cursor-grid change refuses reuse).
test "surface frame decision reproduces the Windows paint policy" {
    var mask: usize = 0;
    while (mask < (1 << 5)) : (mask += 1) {
        const force_full = termBit(mask,0);
        const cursor_grid_changed = termBit(mask,1);
        const glow = termBit(mask,2);
        const translucent = termBit(mask,3);
        const back_tex_valid = termBit(mask,4);
        const force_full_rows = force_full or cursor_grid_changed or glow or translucent;
        const preserve_back = !force_full_rows and back_tex_valid;

        const d = surfaceFrameDecision(.{
            .has_presented_once = back_tex_valid,
            .blur_enabled = translucent,
            .glow_enabled = glow,
            .has_dirty_rows = true,
            .refuses_reuse = force_full or cursor_grid_changed,
        });
        try std.testing.expectEqual(force_full_rows, d.redraws_everything);
        try std.testing.expectEqual(preserve_back, d.loads_previous_contents);
    }
}

test "background alpha: popupmenu opaque, decorated transparent under blur unless a shader chain consumes it" {
    var mask: usize = 0;
    while (mask < (1 << 4)) : (mask += 1) {
        const blur = termBit(mask,0);
        const decorated = termBit(mask,1);
        const shader = termBit(mask,2);
        const pmenu = termBit(mask,3);
        for ([_]f32{ 0, 0.35, 0.8, 1 }) |cfg| {
            const want: f32 = if (pmenu) 1 else if (decorated) (if (shader) 1 else if (blur) 0 else 1) else if (blur) cfg else 1;
            try std.testing.expectEqual(want, surfaceBackgroundAlpha(blur, decorated, shader, pmenu, cfg));
        }
    }
}

// ---------------------------------------------------------------------------
// Mouse modifiers

/// The modifier string of nvim_input_mouse ("S", "C", "A", "D" in that
/// order) for the send_key_event bitmask: 1<<0 Ctrl, 1<<1 Alt, 1<<2 Shift,
/// 1<<3 Super. NUL-terminated in `buf`.
pub fn mouseModifierString(buf: *[5]u8, mods: u32) [:0]const u8 {
    var len: usize = 0;
    const order = [_]struct { bit: u32, letter: u8 }{
        .{ .bit = 1 << 2, .letter = 'S' },
        .{ .bit = 1 << 0, .letter = 'C' },
        .{ .bit = 1 << 1, .letter = 'A' },
        .{ .bit = 1 << 3, .letter = 'D' },
    };
    for (order) |m| {
        if (mods & m.bit == 0) continue;
        buf[len] = m.letter;
        len += 1;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

test "mouse modifiers come out as S, C, A, D in that order" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("", mouseModifierString(&buf, 0));
    try std.testing.expectEqualStrings("S", mouseModifierString(&buf, 1 << 2));
    try std.testing.expectEqualStrings("CA", mouseModifierString(&buf, (1 << 0) | (1 << 1)));
    try std.testing.expectEqualStrings("SCAD", mouseModifierString(&buf, 0xF));
    try std.testing.expectEqualStrings("D", mouseModifierString(&buf, (1 << 3) | (1 << 8)));
}

/// The pointer claim of a surface: which buttons have had a press sent to the
/// editor, and which one's press chose the grid every release and drag goes
/// to. Buttons are 1 left, 2 right, 3 middle, 4 x1, 5 x2 (as in zonvie_core.h).
/// A left press takes the claim; another button's takes it unless left holds
/// it. Every sent press gets its release, to the claim's grid, whatever the
/// order they are let go in; the claim ends with the last held button.
pub const PressClaim = extern struct {
    held_mask: u8 = 0,
    /// The button drags are reported as; 0 once nothing is held.
    owner: u8 = 0,

    pub const Release = struct { send: bool, ends: bool };

    fn bit(button: u8) u8 {
        return @as(u8, 1) << @intCast(button & 7);
    }

    /// Whether this press takes the claim (the caller pins its grid).
    pub fn press(self: *PressClaim, button: u8) bool {
        self.held_mask |= bit(button);
        if (self.owner == 1 and button != 1) return false;
        self.owner = button;
        return true;
    }

    /// Whether to send this release (to the claim's grid), and whether it
    /// ends the claim. A release whose press was never sent is dropped.
    pub fn release(self: *PressClaim, button: u8) Release {
        if (self.held_mask & bit(button) == 0) return .{ .send = false, .ends = self.held_mask == 0 };
        self.held_mask &= ~bit(button);
        if (self.held_mask == 0) {
            self.owner = 0;
        } else if (button == self.owner) {
            self.owner = @ctz(self.held_mask); // bit n is button n
        }
        return .{ .send = true, .ends = self.held_mask == 0 };
    }
};

test "every sent press gets its release, in any release order" {
    var c = PressClaim{};
    // Right, then middle (which takes the claim), let go last-in first-out.
    try std.testing.expect(c.press(2));
    try std.testing.expect(c.press(3));
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = false }, c.release(3));
    try std.testing.expectEqual(@as(u8, 2), c.owner);
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = true }, c.release(2));
    // Left holds the claim against a right press; left let go first.
    try std.testing.expect(c.press(1));
    try std.testing.expect(!c.press(2));
    try std.testing.expectEqual(@as(u8, 1), c.owner);
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = false }, c.release(1));
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = true }, c.release(2));
    // A left press takes over a right claim; the right release keeps it.
    try std.testing.expect(c.press(2));
    try std.testing.expect(c.press(1));
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = false }, c.release(2));
    try std.testing.expectEqual(@as(u8, 1), c.owner);
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = true }, c.release(1));
    // A release whose press never reached the editor is not sent.
    try std.testing.expectEqual(PressClaim.Release{ .send = false, .ends = true }, c.release(3));
    try std.testing.expectEqual(@as(u8, 0), c.held_mask);
}

// ---------------------------------------------------------------------------
// CLI

pub const SshTarget = struct { host: []const u8, port: ?u16 };

/// `user@host[:port]`: the port is what follows the last colon, and only when
/// that is a port number; otherwise the whole value is the host.
pub fn sshTarget(value: []const u8) SshTarget {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return .{ .host = value, .port = null };
    const port = std.fmt.parseInt(u16, value[colon + 1 ..], 10) catch return .{ .host = value, .port = null };
    return .{ .host = value[0..colon], .port = port };
}

/// Whether a bare flag (`--ssh host`) takes the token after it as its value:
/// only when there is one and it is not itself a flag, so `--ssh --dialog`
/// does not take "--dialog" as the host.
pub fn cliNextIsValue(next: ?[]const u8) bool {
    const n = next orelse return false;
    return !std.mem.startsWith(u8, n, "-");
}

/// The longest prefix of `bytes` at most `max` long that does not end inside a
/// UTF-8 sequence, for copies into fixed-size message buffers. A cut in the
/// middle of a character left a truncated sequence that macOS decodes as an
/// empty string.
pub fn utf8PrefixLen(bytes: []const u8, max: usize) usize {
    if (bytes.len <= max) return bytes.len;
    var n = max;
    while (n > 0 and (bytes[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

test "utf8PrefixLen never cuts a character" {
    const s = "a\u{3042}b"; // 'a', 3-byte hiragana, 'b'
    try std.testing.expectEqual(@as(usize, 1), utf8PrefixLen(s, 2));
    try std.testing.expectEqual(@as(usize, 1), utf8PrefixLen(s, 3));
    try std.testing.expectEqual(@as(usize, 4), utf8PrefixLen(s, 4));
    try std.testing.expectEqual(s.len, utf8PrefixLen(s, 99));
}

/// Copy `src` into `dst`; when it does not fit, cut at a UTF-8 boundary and
/// end with '…' so the reader sees text is missing. Returns the bytes written.
pub fn copyUtf8Truncated(dst: []u8, src: []const u8) usize {
    if (src.len <= dst.len) {
        @memcpy(dst[0..src.len], src);
        return src.len;
    }
    const marker = "\u{2026}";
    if (dst.len < marker.len) return 0;
    const cut = utf8PrefixLen(src, dst.len - marker.len);
    @memcpy(dst[0..cut], src[0..cut]);
    @memcpy(dst[cut..][0..marker.len], marker);
    return cut + marker.len;
}

/// Lines a mini window shows; noice.nvim's views.mini max_height.
pub const mini_max_lines = 10;

/// Mini content as shown: a trailing newline dropped, and past
/// `mini_max_lines` lines the first nine plus a "…(N more lines)" summary
/// line. Content past `dst` is cut by copyUtf8Truncated. Returns the bytes
/// written.
pub fn clampMiniContent(dst: []u8, content: []const u8) usize {
    const src = if (content.len > 0 and content[content.len - 1] == '\n') content[0 .. content.len - 1] else content;
    const lines = std.mem.count(u8, src, "\n") + 1;
    if (lines <= mini_max_lines) return copyUtf8Truncated(dst, src);
    const kept = mini_max_lines - 1;
    var head_end: usize = 0;
    for (0..kept) |n| {
        const nl = std.mem.indexOfScalarPos(u8, src, head_end, '\n').?;
        head_end = if (n + 1 == kept) nl else nl + 1;
    }
    var summary_buf: [48]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "\n\u{2026}({d} more lines)", .{lines - kept}) catch unreachable;
    if (dst.len < summary.len) return copyUtf8Truncated(dst, src[0..head_end]);
    const head_len = copyUtf8Truncated(dst[0 .. dst.len - summary.len], src[0..head_end]);
    @memcpy(dst[head_len..][0..summary.len], summary);
    return head_len + summary.len;
}

/// A message or cmdline panel's background from Normal's (sRGB 0..1): HSB
/// brightness moved 0.05 toward the middle, hue and saturation kept. With
/// both kept, that is RGB scaled by the brightness ratio.
pub fn panelBg(r: f32, g: f32, b: f32) [3]f32 {
    const v = @max(r, @max(g, b));
    const v2 = if (v < 0.5) @min(v + 0.05, 1.0) else @max(v - 0.05, 0.0);
    if (v == 0) return .{ v2, v2, v2 };
    const k = v2 / v;
    return .{ r * k, g * k, b * k };
}

test "panelBg moves brightness toward the middle and keeps hue and saturation" {
    const tol = 1e-6;
    const dark = panelBg(0.1, 0.2, 0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), dark[2], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35) / 3.0, dark[0], tol);
    const light = panelBg(1.0, 1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), light[0], tol);
    const black = panelBg(0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), black[1], tol);
}

/// How one argument goes into a spawn command so the core's tokenizer
/// (rpc_session.zig tokenizeCommand) hands it back unchanged: 0 bare, or the
/// quote to wrap it in. The tokenizer splits on spaces, takes a leading quote
/// as grouping, never unescapes, and ends a quoted token at its quote (or at
/// a backslash-quote pair). Null when neither quote can carry the argument
/// (an empty one, or one with a space and both quote kinds).
pub fn spawnArgQuote(arg: []const u8) ?u8 {
    if (arg.len == 0) return null;
    const needs_quote = std.mem.indexOfScalar(u8, arg, ' ') != null or arg[0] == '"' or arg[0] == '\'';
    if (!needs_quote) return 0;
    const ends_in_backslash = arg[arg.len - 1] == '\\';
    for ([_]u8{ '"', '\'' }) |q| {
        if (std.mem.indexOfScalar(u8, arg, q) == null and !ends_in_backslash) return q;
    }
    return null;
}

test "spawnArgQuote picks a quote the core's tokenizer gives back unchanged" {
    try std.testing.expectEqual(@as(?u8, 0), spawnArgQuote("notes.txt"));
    try std.testing.expectEqual(@as(?u8, 0), spawnArgQuote("a\"b"));
    try std.testing.expectEqual(@as(?u8, '"'), spawnArgQuote("my notes.txt"));
    // `-c "echo \"hi there\""` arrives as `echo "hi there"`: double quotes
    // would end the token at the first inner one.
    try std.testing.expectEqual(@as(?u8, '\''), spawnArgQuote("echo \"hi there\""));
    try std.testing.expectEqual(@as(?u8, '"'), spawnArgQuote("'quoted'"));
    try std.testing.expectEqual(@as(?u8, null), spawnArgQuote("it's \"x\""));
    try std.testing.expectEqual(@as(?u8, null), spawnArgQuote("C:\\My Dir\\"));
    try std.testing.expectEqual(@as(?u8, null), spawnArgQuote(""));
}

/// Whether `arg` is a file argument to nvim: not a flag (`-`), not a command
/// (`+`), not the value of the option `prev` names (`-u NONE`). After `--`
/// every token but `-` (stdin) is a file.
pub fn nvimArgIsFile(prev: ?[]const u8, arg: []const u8, after_dash_dash: bool) bool {
    if (arg.len == 0) return false;
    if (after_dash_dash) return !std.mem.eql(u8, arg, "-");
    if (arg[0] == '-' or arg[0] == '+') return false;
    const takes_value = [_][]const u8{ "-u", "-i", "-c", "-S", "-s", "-t", "-w", "-W", "-l", "--cmd", "--listen", "--server", "--startuptime" };
    if (prev) |p| for (takes_value) |o| if (std.mem.eql(u8, p, o)) return false;
    return true;
}

test "nvimArgIsFile keeps flags, commands and option values out of the file list" {
    try std.testing.expect(nvimArgIsFile(null, "foo.txt", false));
    try std.testing.expect(nvimArgIsFile("-p", "foo.txt", false));
    try std.testing.expect(nvimArgIsFile(null, "C:foo.txt", false));
    try std.testing.expect(!nvimArgIsFile(null, "-p", false));
    try std.testing.expect(!nvimArgIsFile(null, "+10", false));
    try std.testing.expect(!nvimArgIsFile("-u", "NONE", false));
    try std.testing.expect(!nvimArgIsFile("--cmd", "set nu", false));
    try std.testing.expect(!nvimArgIsFile("-t", "main", false));
    try std.testing.expect(!nvimArgIsFile(null, "", false));
    try std.testing.expect(nvimArgIsFile(null, "-u", true));
    try std.testing.expect(nvimArgIsFile(null, "+10", true));
    try std.testing.expect(!nvimArgIsFile(null, "-", true));
}

/// Walks nvim's own command line — what follows zonvie's `--` — token by
/// token, saying which are files. Its `after_dash_dash` is nvim's `--`, not
/// zonvie's: treating zonvie's as nvim's made `zonvie -- -u init.lua` hand
/// nvim `<cwd>/-u <cwd>/init.lua`. nvim's `--` itself is no file.
pub const NvimArgScan = struct {
    prev: ?[]const u8 = null,
    after_dash_dash: bool = false,

    pub fn isFile(self: *NvimArgScan, arg: []const u8) bool {
        defer self.prev = arg;
        if (!self.after_dash_dash and std.mem.eql(u8, arg, "--")) {
            self.after_dash_dash = true;
            return false;
        }
        return nvimArgIsFile(self.prev, arg, self.after_dash_dash);
    }
};

test "nvim's command line keeps its flags until its own --" {
    var scan: NvimArgScan = .{};
    const args = [_][]const u8{ "-u", "init.lua", "+10", "a.txt", "--", "-b.txt", "-" };
    const want = [_]bool{ false, false, false, true, false, true, false };
    for (args, want) |a, w| try std.testing.expectEqual(w, scan.isFile(a));
}

/// A devcontainer workspace or config path as the devcontainer commands can
/// quote it: one pair of Explorer "Copy as path" quotes dropped, and trailing
/// backslashes dropped (`C:\proj\` is `C:\proj`); a root keeps its backslash
/// and gets a `.` after it (`C:\.`). Inside `"..."` a trailing backslash
/// escapes the closing quote, and the rest of the command becomes part of
/// the path. A POSIX path passes through unchanged.
pub fn writeDevcontainerPath(w: *std.Io.Writer, raw: []const u8) !void {
    var p = raw;
    if (p.len >= 2 and p[0] == '"' and p[p.len - 1] == '"') p = p[1 .. p.len - 1];
    while (p.len > 1 and p[p.len - 1] == '\\' and p[p.len - 2] != ':') p = p[0 .. p.len - 1];
    try w.writeAll(p);
    if (p.len > 0 and p[p.len - 1] == '\\') try w.writeByte('.');
}

/// The `devcontainer exec ... nvim --embed` command line, as much of it as
/// fits in `buf`: a truncated command fails at the spawn.
pub fn devcontainerExecCmd(buf: []u8, workspace: []const u8, config_path: ?[]const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("devcontainer exec --workspace-folder \"") catch {};
    writeDevcontainerPath(&w, workspace) catch {};
    w.writeAll("\"") catch {};
    if (config_path) |cfg| {
        w.writeAll(" --config \"") catch {};
        writeDevcontainerPath(&w, cfg) catch {};
        w.writeAll("\"") catch {};
    }
    w.writeAll(" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed") catch {};
    return buf[0..w.end];
}

/// The `devcontainer up` arguments after the workspace and config paths, each
/// NUL-terminated in `buf` so the frontends can apply their own shell quoting
/// per argument: the Neovim feature pinned to its stable release (nightly
/// builds with assertions on and aborts in msg_scroll_flush; the pin also
/// changes the feature hash, so a rebuild drops a cached nightly layer), the
/// bind mount of the user's nvim config where devcontainerExecCmd's
/// XDG_CONFIG_HOME finds it, and the rebuild flag.
pub fn devcontainerUpArgs(buf: []u8, nvim_config_dir: []const u8, rebuild: bool) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("--additional-features\x00{\"ghcr.io/duduribeiro/devcontainer-features/neovim:1\":{\"version\":\"stable\"}}\x00") catch {};
    w.writeAll("--mount\x00type=bind,source=") catch {};
    w.writeAll(nvim_config_dir) catch {};
    w.writeAll(",target=/nvim-config/nvim\x00") catch {};
    if (rebuild) w.writeAll("--remove-existing-container\x00") catch {};
    return buf[0..w.end];
}

test "the devcontainer up arguments pin the stable feature and mount the nvim config" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "--additional-features\x00{\"ghcr.io/duduribeiro/devcontainer-features/neovim:1\":{\"version\":\"stable\"}}\x00" ++
            "--mount\x00type=bind,source=/home/me/.config/nvim,target=/nvim-config/nvim\x00--remove-existing-container\x00",
        devcontainerUpArgs(&buf, "/home/me/.config/nvim", true),
    );
    // Without a rebuild the existing container is kept.
    const keep = devcontainerUpArgs(&buf, "C:\\Users\\me\\AppData\\Local\\nvim", false);
    try std.testing.expect(std.mem.indexOf(u8, keep, "--remove-existing-container") == null);
    try std.testing.expect(std.mem.indexOf(u8, keep, "source=C:\\Users\\me\\AppData\\Local\\nvim,target=/nvim-config/nvim\x00") != null);
    // The mount lands where the exec command's XDG_CONFIG_HOME looks.
    var exec_buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, devcontainerExecCmd(&exec_buf, "/w", null), "XDG_CONFIG_HOME=/nvim-config ") != null);
}

test "a devcontainer path drops what would break the quoted argument" {
    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = ".\\proj\\", .want = ".\\proj" },
        .{ .raw = "C:\\My Dir\\\\", .want = "C:\\My Dir" },
        .{ .raw = "\"C:\\proj\"", .want = "C:\\proj" },
        .{ .raw = "C:\\", .want = "C:\\." },
        .{ .raw = "\"D:\\\"", .want = "D:\\." },
        .{ .raw = "/work/app", .want = "/work/app" },
        .{ .raw = "/work/app/", .want = "/work/app/" },
        .{ .raw = "\\", .want = "\\." },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeDevcontainerPath(&w, case.raw);
        try std.testing.expectEqualStrings(case.want, buf[0..w.end]);
    }
}

test "the devcontainer exec command quotes both paths and embeds nvim" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "devcontainer exec --workspace-folder \"/work/app\" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed",
        devcontainerExecCmd(&buf, "/work/app", null),
    );
    try std.testing.expectEqualStrings(
        "devcontainer exec --workspace-folder \"C:\\proj\" --config \"C:\\proj\\.devcontainer\\devcontainer.json\" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed",
        devcontainerExecCmd(&buf, "\"C:\\proj\\\"", "C:\\proj\\.devcontainer\\devcontainer.json"),
    );
}

test "an ssh target splits its port off the last colon, only when numeric" {
    const plain = sshTarget("me@host");
    try std.testing.expectEqualStrings("me@host", plain.host);
    try std.testing.expect(plain.port == null);
    const with_port = sshTarget("me@host:2222");
    try std.testing.expectEqualStrings("me@host", with_port.host);
    try std.testing.expectEqual(@as(?u16, 2222), with_port.port);
    // Not a port: the colon stays in the host.
    const alias = sshTarget("me@host:dev");
    try std.testing.expectEqualStrings("me@host:dev", alias.host);
    try std.testing.expect(alias.port == null);
    try std.testing.expectEqualStrings("host:", sshTarget("host:").host);
    try std.testing.expectEqualStrings("host:99999", sshTarget("host:99999").host);
}

test "a bare flag takes the next token only when it is a value" {
    try std.testing.expect(cliNextIsValue("me@host"));
    try std.testing.expect(!cliNextIsValue("--dialog"));
    try std.testing.expect(!cliNextIsValue("-u"));
    try std.testing.expect(!cliNextIsValue(null));
}

// ---------------------------------------------------------------------------
// File drops

/// Whether a drop inserts the path into the command line rather than opening
/// the file: always on the external cmdline window itself (`force`); never on
/// a buffer surface while the cmdline has its own window; otherwise while the
/// built-in cmdline is up.
pub fn dropInsertsPath(mode: []const u8, has_external_cmdline: bool, force: bool) bool {
    if (force) return true;
    if (has_external_cmdline) return false;
    return std.mem.startsWith(u8, mode, "cmdline");
}

/// `path` as Neovim's fnameescape() writes it for a `:e`-style argument: its
/// PATH_ESC_CHARS backslashed, plus a leading `>`, `+` or lone `-`, which are
/// special at the start of :edit/:write/:cd. With `backslash_is_separator`
/// (a Windows server) `$` and `\` are plain path bytes and `[{!` are in the
/// default 'isfname', so none of them is escaped. Needs
/// `out.len >= 2 * path.len + 1`; null when the result does not fit.
pub fn escapePathForCmdline(out: []u8, path: []const u8, backslash_is_separator: bool) ?[]const u8 {
    const special: []const u8 = if (backslash_is_separator) " \t\n*?`%#'\"|<" else " \t\n*?[{`$\\%#'\"|!<";
    var n: usize = 0;
    if (path.len > 0 and (path[0] == '>' or path[0] == '+' or (path[0] == '-' and path.len == 1))) {
        if (n >= out.len) return null;
        out[n] = '\\';
        n += 1;
    }
    for (path) |ch| {
        if (std.mem.indexOfScalar(u8, special, ch) != null) {
            if (n >= out.len) return null;
            out[n] = '\\';
            n += 1;
        }
        if (n >= out.len) return null;
        out[n] = ch;
        n += 1;
    }
    return out[0..n];
}

test "a drop inserts the path only onto a command line" {
    try std.testing.expect(dropInsertsPath("cmdline_normal", false, false));
    try std.testing.expect(!dropInsertsPath("cmdline_normal", true, false));
    try std.testing.expect(dropInsertsPath("normal", true, true));
    try std.testing.expect(!dropInsertsPath("normal", false, false));
    try std.testing.expect(!dropInsertsPath("", false, false));
}

test "a cmdline path is escaped as fnameescape escapes it" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a\\*b\\ c\\?.txt", escapePathForCmdline(&buf, "a*b c?.txt", false).?);
    try std.testing.expectEqualStrings(
        "\\%\\#\\|\\\"\\'\\[\\{\\$\\`\\!\\<\\\\\\\t\\\n",
        escapePathForCmdline(&buf, "%#|\"'[{$`!<\\\t\n", false).?,
    );
    // `]` and `}` are not special; `>`, `+` and a lone `-` only lead.
    try std.testing.expectEqualStrings("a]}>+-", escapePathForCmdline(&buf, "a]}>+-", false).?);
    try std.testing.expectEqualStrings("\\+x", escapePathForCmdline(&buf, "+x", false).?);
    try std.testing.expectEqualStrings("\\>x", escapePathForCmdline(&buf, ">x", false).?);
    try std.testing.expectEqualStrings("\\-", escapePathForCmdline(&buf, "-", false).?);
    try std.testing.expectEqualStrings("-x", escapePathForCmdline(&buf, "-x", false).?);
    try std.testing.expectEqualStrings("", escapePathForCmdline(&buf, "", false).?);
}

test "a Windows server keeps backslashes, dollars and the isfname brackets" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "C:\\Users\\me\\[a]\\ $b\\*!.txt",
        escapePathForCmdline(&buf, "C:\\Users\\me\\[a] $b*!.txt", true).?,
    );
}

test "a cmdline path that does not fit is refused, not cut" {
    var buf: [3]u8 = undefined;
    try std.testing.expect(escapePathForCmdline(&buf, "a b", false) == null);
    try std.testing.expectEqualStrings("a\\ ", escapePathForCmdline(&buf, "a ", false).?);
}

// ---------------------------------------------------------------------------
// Custom shaders

/// Whether a Shadertoy-style shader reads a uniform that changes every frame,
/// so its surface has to keep drawing while nothing else changes. Whole words
/// only. iResolution, iSampleRate and iChannel0 are constant, and iMouse is
/// not implemented (always zero), so none of them animates.
pub fn shaderNeedsAnimation(source: []const u8) bool {
    return containsAnyWord(source, &.{ "iTime", "iTimeDelta", "iFrame", "iFrameRate", "iDate" });
}

/// Whether a shader reads the cell-age inputs. Gates the core's stamp lists
/// and the cell-age texture. `zonvieCellAge` is the preamble's wrapper around
/// iCellAge, so a shader that only calls it still needs the texture bound.
pub fn shaderUsesEditInputs(source: []const u8) bool {
    return containsAnyWord(source, &.{ "iCellAge", "zonvieCellAge", "iCellSize", "iGridOrigin", "iTimeLastEdit" });
}

/// Whether a shader reads iPrevFrame. Gates the feedback pair and the copy
/// pass it costs, so a cell-age-only shader still renders straight into the
/// drawable.
pub fn shaderUsesPrevFrame(source: []const u8) bool {
    return containsAnyWord(source, &.{"iPrevFrame"});
}

/// Whether a shader opts into drawing the cursor itself with the
/// `@zonvie-owns-cursor` comment token. The frontend then skips its native
/// cursor pass and glow for every shape, block included.
pub fn shaderOwnsCursor(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "@zonvie-owns-cursor") != null;
}

fn containsAnyWord(source: []const u8, tokens: []const []const u8) bool {
    for (tokens) |tok| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, source, search, tok)) |pos| {
            const before_ok = pos == 0 or !isWordPart(source[pos - 1]);
            const after_idx = pos + tok.len;
            const after_ok = after_idx >= source.len or !isWordPart(source[after_idx]);
            if (before_ok and after_ok) return true;
            search = after_idx;
        }
    }
    return false;
}

fn isWordPart(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "a shader animates when it reads a per-frame uniform as a whole word" {
    try std.testing.expect(shaderNeedsAnimation("fragColor = vec4(sin(iTime));"));
    try std.testing.expect(shaderNeedsAnimation("float f = float(iFrame);"));
    try std.testing.expect(shaderNeedsAnimation("x = iTimeDelta;"));
    try std.testing.expect(!shaderNeedsAnimation("vec2 uv = fragCoord / iResolution.xy;"));
    try std.testing.expect(!shaderNeedsAnimation("vec4 m = iMouse;"));
    try std.testing.expect(!shaderNeedsAnimation("float myiTime = 1.0; float iTimes = 2.0;"));
}

test "a shader uses the edit inputs only when it names one as a whole word" {
    try std.testing.expect(shaderUsesEditInputs("float a = texelFetch(iCellAge, c, 0).r;"));
    try std.testing.expect(shaderUsesEditInputs("vec2 cs = iCellSize;"));
    try std.testing.expect(shaderUsesEditInputs("float a = zonvieCellAge(fragCoord) + iTime;"));
    try std.testing.expect(!shaderUsesEditInputs("float myiCellAge = 1.0;"));
    try std.testing.expect(!shaderUsesEditInputs("fragColor = vec4(sin(iTime));"));
    try std.testing.expect(!shaderUsesEditInputs("vec4 p = texture(iPrevFrame, uv);"));
}

test "a shader uses iPrevFrame only when it names it" {
    try std.testing.expect(shaderUsesPrevFrame("vec4 p = texture(iPrevFrame, uv);"));
    try std.testing.expect(!shaderUsesPrevFrame("float a = texelFetch(iCellAge, c, 0).r;"));
    try std.testing.expect(!shaderUsesPrevFrame("vec4 myiPrevFrame;"));
}

test "a shader owns the cursor only with the opt-in token" {
    try std.testing.expect(shaderOwnsCursor("// @zonvie-owns-cursor\nvoid main() {}"));
    try std.testing.expect(!shaderOwnsCursor("vec4 c = iCurrentCursor;"));
}

// ---------------------------------------------------------------------------
// Message floats

pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const Point = extern struct { x: i32, y: i32 };

/// Where msg_show or msg_history puts its top-left corner: `margin` in from
/// the target's top-right corner, and msg_show `gap` below msg_history when
/// that is up (`history_bottom`, screen coordinates, y down). The core
/// registers these grids with the "top-right" sentinel position, so x follows
/// the window's current width and never a previous position: reusing that made
/// a short message keep a long one's left edge. Margins are the caller's
/// pixels, already scaled.
pub fn msgFloatTopRight(target: Rect, window_w: i32, history_bottom: ?i32, margin: i32, gap: i32) Point {
    return .{
        .x = target.right - window_w - margin,
        .y = if (history_bottom) |bottom| bottom + gap else target.top + margin,
    };
}

test "msg_show sits in from the top-right corner, below msg_history when shown" {
    const target: Rect = .{ .left = 0, .top = 100, .right = 800, .bottom = 600 };
    try std.testing.expectEqual(Point{ .x = 800 - 200 - 15, .y = 115 }, msgFloatTopRight(target, 200, null, 15, 6));
    try std.testing.expectEqual(Point{ .x = 800 - 200 - 15, .y = 300 + 6 }, msgFloatTopRight(target, 200, 300, 15, 6));
}

const msg_test_screen: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };

test "a message float's right edge is invariant across every width" {
    // The regression: a resize in place (SWP_NOMOVE) kept the previous long
    // message's left edge. The right edge is the contract; the left edge must
    // move whenever the width does.
    const widths = [_]i32{ 1, 80, 400, 401, 1200, 1910 };
    var previous_x: ?i32 = null;
    for (widths) |w| {
        const p = msgFloatTopRight(msg_test_screen, w, null, 10, 4);
        try std.testing.expectEqual(msg_test_screen.right - 10, p.x + w);
        try std.testing.expectEqual(@as(i32, 10), p.y);
        if (previous_x) |prev| try std.testing.expect(p.x != prev);
        previous_x = p.x;
    }
}

test "a short message after a long one is not left where the long one was" {
    const long = msgFloatTopRight(msg_test_screen, 900, null, 10, 4);
    const short = msgFloatTopRight(msg_test_screen, 120, null, 10, 4);
    try std.testing.expect(short.x > long.x);
    try std.testing.expectEqual(long.x + 900, short.x + 120);
}

test "msg_show stacks below msg_history without changing its right edge" {
    const history = msgFloatTopRight(msg_test_screen, 600, null, 10, 4);
    const history_bottom = history.y + 300;
    const show = msgFloatTopRight(msg_test_screen, 240, history_bottom, 10, 4);
    try std.testing.expectEqual(history_bottom + 4, show.y);
    try std.testing.expectEqual(msg_test_screen.right - 10, show.x + 240);
}

test "message placement follows a target rect off the screen origin" {
    // msg_pos = window/grid hands over the cursor window's rect in screen
    // coordinates, offset on both axes.
    const windowed: Rect = .{ .left = 300, .top = 150, .right = 1400, .bottom = 900 };
    try std.testing.expectEqual(Point{ .x = 1400 - 500 - 10, .y = 160 }, msgFloatTopRight(windowed, 500, null, 10, 4));
}

test "a message float wider than the target overhangs the left, never the right" {
    const p = msgFloatTopRight(msg_test_screen, 2400, null, 10, 4);
    try std.testing.expectEqual(msg_test_screen.right - 10, p.x + 2400);
    try std.testing.expect(p.x < msg_test_screen.left);
}

// The msg_show close badge: a small disc with a cross in the window's top-left
// corner, shown while the pointer is on the window and filled in while it is
// on the badge, as a macOS notification's. Lengths are in points; a frontend
// passes its own scale (1 on macOS, the DPI factor on Windows) and gets its
// own pixels back, rounded as Windows rounds every other chrome length.

pub const msg_close_badge_size_pt: f32 = 13.0;
pub const msg_close_badge_inset_pt: f32 = 2.0;
/// Extra leading width the window reserves so the badge clears the text.
pub const msg_close_badge_reserve_pt: f32 = 10.0;
/// Where the cross's arms end, as a fraction of the badge from each edge.
pub const msg_close_badge_cross_inset: f32 = 0.32;
pub const msg_close_badge_cross_stroke_pt: f32 = 1.25;

pub const RectF = extern struct { left: f32, top: f32, right: f32, bottom: f32 };

fn scaledPt(pt: f32, scale: f32) f32 {
    return @round(pt * scale);
}

/// Leading width the msg_show window adds for the badge, in scaled pixels.
/// Pre: scale > 0.
pub fn msgCloseBadgeReservePx(scale: f32) f32 {
    std.debug.assert(scale > 0);
    return scaledPt(msg_close_badge_reserve_pt, scale);
}

/// The badge's box in a container of `container_w` x `container_h` scaled
/// pixels, top-left origin, y down. Null when the container cannot hold it.
/// Pre: scale > 0. Post: a square of the scaled badge size, `inset` in from
/// the top and leading edges, inside the container.
pub fn msgCloseBadgeRect(container_w: f32, container_h: f32, scale: f32) ?RectF {
    std.debug.assert(scale > 0);
    const size = scaledPt(msg_close_badge_size_pt, scale);
    const inset = scaledPt(msg_close_badge_inset_pt, scale);
    if (container_w < size + inset or container_h < size + inset) return null;
    return .{ .left = inset, .top = inset, .right = inset + size, .bottom = inset + size };
}

pub const MsgCloseBadgeLook = enum(u8) { hidden = 0, resting = 1, active = 2 };

/// How the badge is painted in one look, in scaled pixels.
pub const MsgCloseBadgePaint = extern struct {
    /// The disc's alpha over the tint; 0 when hidden.
    fill_alpha: f32,
    /// The cross is drawn at full tint alpha, arms `cross_inset_px` in from
    /// each edge of the badge, `cross_stroke_px` wide. Zero when hidden.
    cross_inset_px: f32,
    cross_stroke_px: f32,
};

/// Pre: scale > 0. Post: hidden paints nothing; active fills more than resting.
pub fn msgCloseBadgePaint(look: MsgCloseBadgeLook, scale: f32) MsgCloseBadgePaint {
    std.debug.assert(scale > 0);
    if (look == .hidden) return .{ .fill_alpha = 0, .cross_inset_px = 0, .cross_stroke_px = 0 };
    return .{
        .fill_alpha = if (look == .active) 0.6 else 0.2,
        .cross_inset_px = msg_close_badge_cross_inset * scaledPt(msg_close_badge_size_pt, scale),
        .cross_stroke_px = msg_close_badge_cross_stroke_pt * scale,
    };
}

/// The msg_show window's chrome state: where the pointer is, and whether the
/// user has dragged the window off its top-right slot. One per msg_show
/// window; zero it to start.
///
/// Invariant: `on_badge` implies `on_surface` -- the badge is part of the
/// window. Every transition preserves it.
pub const MsgShowChrome = extern struct {
    on_surface: bool = false,
    on_badge: bool = false,
    user_placed: bool = false,

    pub fn invariant(self: MsgShowChrome) bool {
        return !self.on_badge or self.on_surface;
    }

    /// The badge's look, from the pointer alone.
    pub fn look(self: MsgShowChrome) MsgCloseBadgeLook {
        std.debug.assert(self.invariant());
        if (self.on_badge) return .active;
        return if (self.on_surface) .resting else .hidden;
    }

    /// Whether placement may move the window back to its top-right slot.
    /// While false, every re-placement -- a resize included -- keeps the
    /// window's top-left corner where the user left it.
    pub fn followsAnchor(self: MsgShowChrome) bool {
        return !self.user_placed;
    }

    /// The pointer is now on the window (`on_surface`) and on the badge
    /// (`on_badge`). Returns whether the badge's look changed, so a caller
    /// repaints only then.
    /// Pre: on_badge implies on_surface.
    pub fn pointer(self: *MsgShowChrome, on_surface: bool, on_badge: bool) bool {
        std.debug.assert(!on_badge or on_surface);
        const before = self.look();
        self.on_surface = on_surface;
        self.on_badge = on_badge;
        std.debug.assert(self.invariant());
        return self.look() != before;
    }

    /// A press on the window ended; `moved` says whether it moved the window.
    /// Only a real move makes placement leave the window alone until it
    /// closes: a click that moved nothing must not unpin it from its anchor.
    /// A later still click does not re-anchor a moved window either.
    pub fn dragEnded(self: *MsgShowChrome, moved: bool) void {
        if (moved) self.user_placed = true;
    }

    /// The window closed. A window gone under a still pointer gets no leave
    /// event, so the pointer is forgotten too; the next show starts anchored.
    pub fn reset(self: *MsgShowChrome) void {
        self.* = .{};
    }
};

test "the close badge sits in the top-left corner at every scale" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const r = msgCloseBadgeRect(400, 40, scale).?;
        const size = @round(msg_close_badge_size_pt * scale);
        const inset = @round(msg_close_badge_inset_pt * scale);
        try std.testing.expectEqual(inset, r.left);
        try std.testing.expectEqual(inset, r.top);
        try std.testing.expectEqual(size, r.right - r.left);
        try std.testing.expectEqual(size, r.bottom - r.top);
    }
}

test "the close badge never leaves a container too small for it" {
    try std.testing.expect(msgCloseBadgeRect(14, 40, 1.0) == null);
    try std.testing.expect(msgCloseBadgeRect(400, 14, 1.0) == null);
    const fits = msgCloseBadgeRect(15, 15, 1.0).?;
    try std.testing.expect(fits.right <= 15 and fits.bottom <= 15);
}

test "the close badge cross matches the one windows/shaders/main.hlsl hardcodes" {
    // ICON_CROSS cannot read these constants: a change here must be made in
    // the shader too (arm inset 0.32, half-stroke 0.048 of the badge).
    try std.testing.expectEqual(@as(f32, 0.32), msg_close_badge_cross_inset);
    try std.testing.expectApproxEqAbs(@as(f32, 0.048), msg_close_badge_cross_stroke_pt / msg_close_badge_size_pt / 2, 0.0005);
}

test "the reserve scales with the badge" {
    try std.testing.expectEqual(@as(f32, 10), msgCloseBadgeReservePx(1.0));
    try std.testing.expectEqual(@as(f32, 15), msgCloseBadgeReservePx(1.5));
}

test "a hidden badge paints nothing and the active one fills in" {
    const hidden = msgCloseBadgePaint(.hidden, 1.0);
    try std.testing.expectEqual(@as(f32, 0), hidden.fill_alpha);
    try std.testing.expectEqual(@as(f32, 0), hidden.cross_stroke_px);
    const resting = msgCloseBadgePaint(.resting, 1.0);
    const active = msgCloseBadgePaint(.active, 1.0);
    try std.testing.expect(resting.fill_alpha > 0);
    try std.testing.expect(active.fill_alpha > resting.fill_alpha);
    try std.testing.expectEqual(resting.cross_stroke_px, active.cross_stroke_px);
    try std.testing.expect(resting.cross_inset_px * 2 < @round(msg_close_badge_size_pt));
}

test "the badge shows with the pointer on the window and fills in on the badge" {
    var c = MsgShowChrome{};
    try std.testing.expectEqual(MsgCloseBadgeLook.hidden, c.look());
    try std.testing.expect(c.pointer(true, false));
    try std.testing.expectEqual(MsgCloseBadgeLook.resting, c.look());
    try std.testing.expect(!c.pointer(true, false)); // no change, no repaint
    try std.testing.expect(c.pointer(true, true));
    try std.testing.expectEqual(MsgCloseBadgeLook.active, c.look());
    try std.testing.expect(c.pointer(false, false));
    try std.testing.expectEqual(MsgCloseBadgeLook.hidden, c.look());
}

test "a click that moves nothing leaves msg_show anchored" {
    var c = MsgShowChrome{};
    _ = c.pointer(true, false);
    c.dragEnded(false);
    try std.testing.expect(c.followsAnchor());
}

test "a dragged msg_show stays put until it closes" {
    var c = MsgShowChrome{};
    try std.testing.expect(c.followsAnchor());
    _ = c.pointer(true, false);
    c.dragEnded(true);
    try std.testing.expect(!c.followsAnchor());
    // A later click that moves nothing does not re-anchor it.
    c.dragEnded(false);
    try std.testing.expect(!c.followsAnchor());
    // Pointer moves do not release the placement.
    _ = c.pointer(false, false);
    try std.testing.expect(!c.followsAnchor());
    c.reset();
    try std.testing.expect(c.followsAnchor());
    try std.testing.expectEqual(MsgCloseBadgeLook.hidden, c.look());
}

// ---------------------------------------------------------------------------
// Cmdline

/// Where an open cmdline window goes when its size changes, screen
/// coordinates with y down: it keeps its centre, so a cmdline growing as you
/// type widens both ways, and once it takes 90% of the area's width it is
/// centred. Always kept inside `area`. Windows grew it rightward from its
/// top-left, past the monitor edge.
pub fn cmdlineOrigin(old: Rect, new_w: i32, new_h: i32, area: Rect) Point {
    const area_w = area.right - area.left;
    var x = old.left + @divTrunc(old.right - old.left, 2) - @divTrunc(new_w, 2);
    var y = old.top + @divTrunc(old.bottom - old.top, 2) - @divTrunc(new_h, 2);
    if (@as(i64, new_w) * 10 >= @as(i64, area_w) * 9) x = area.left + @divTrunc(area_w - new_w, 2);
    x = @max(area.left, @min(x, area.right - new_w));
    y = @max(area.top, @min(y, area.bottom - new_h));
    return .{ .x = x, .y = y };
}

test "a growing cmdline keeps its centre, and stays on the area" {
    const area: Rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 900 };
    const old: Rect = .{ .left = 300, .top = 280, .right = 700, .bottom = 320 };
    try std.testing.expectEqual(Point{ .x = 250, .y = 280 }, cmdlineOrigin(old, 500, 40, area));
    // Near the right edge: clamped instead of running off it.
    const right: Rect = .{ .left = 800, .top = 280, .right = 1000, .bottom = 320 };
    try std.testing.expectEqual(Point{ .x = 600, .y = 280 }, cmdlineOrigin(right, 400, 40, area));
}

test "a cmdline taking 90% of the width is centred" {
    const area: Rect = .{ .left = 100, .top = 0, .right = 1100, .bottom = 900 };
    const old: Rect = .{ .left = 150, .top = 280, .right = 550, .bottom = 320 };
    try std.testing.expectEqual(Point{ .x = 150, .y = 280 }, cmdlineOrigin(old, 900, 40, area));
}

pub const CmdlineCols = extern struct { screen_cols: u32, default_cols: u32 };

/// The cmdline's width budget in cells, from widths in the frontend's pixels.
/// `screen_cols` caps its growth: the work area less the chrome beside the
/// grid and `margin_px`, at least 40. `default_cols` is its width before the
/// content needs more: the cmdline window spans 95% of the main window, chrome
/// included, at least 20. A zero width gives 0, "not supplied" to the core.
pub fn cmdlineCols(work_w_px: u32, main_w_px: u32, chrome_px: u32, margin_px: u32, cell_w_px: u32) CmdlineCols {
    const cw = @max(1, cell_w_px);
    const target_w_px: u32 = @intCast(@as(u64, main_w_px) * 95 / 100);
    return .{
        .screen_cols = if (work_w_px == 0) 0 else @max(40, (work_w_px -| (chrome_px +| margin_px)) / cw),
        .default_cols = if (main_w_px == 0) 0 else @max(20, (target_w_px -| chrome_px) / cw),
    };
}

test "the cmdline grows to the work area less chrome and margin, from 95% of the main window" {
    // 2000 - 64 - 40 = 1896 / 8 = 237; 1000 * 95% = 950 - 64 = 886 / 8 = 110.
    try std.testing.expectEqual(CmdlineCols{ .screen_cols = 237, .default_cols = 110 }, cmdlineCols(2000, 1000, 64, 40, 8));
}

test "a narrow screen or window still gives the cmdline 40 and 20 cells" {
    try std.testing.expectEqual(CmdlineCols{ .screen_cols = 40, .default_cols = 20 }, cmdlineCols(50, 50, 64, 40, 8));
    try std.testing.expectEqual(CmdlineCols{ .screen_cols = 0, .default_cols = 0 }, cmdlineCols(0, 0, 64, 40, 8));
}

// ---------------------------------------------------------------------------
// External window placement memory

pub const SavedOrigin = extern struct { grid_id: i64, x: f64, y: f64, generation: u64 };

pub const Placement = struct {
    kind: enum(u8) { pending, saved },
    x: f64,
    y: f64,
};

/// Where the next external window goes, in the caller's screen units: the
/// drop point of a tab drag (`pending`, good for 500 ms) beats the origin the
/// grid's window had when it closed (`saved`), which is kept only for the
/// session that created it: grid ids restart per server. Holds 100 saved
/// origins; a new one past that evicts the smallest grid id.
pub const PlacementMemory = extern struct {
    pub const cap = 100;
    pub const pending_timeout_ms: i64 = 500;

    saved: [cap + 1]SavedOrigin = undefined,
    saved_len: usize = 0,
    pending_x: f64 = 0,
    pending_y: f64 = 0,
    pending_set_ms: i64 = 0,
    has_pending: bool = false,

    pub fn setPending(self: *PlacementMemory, x: f64, y: f64, now_ms: i64) void {
        self.pending_x = x;
        self.pending_y = y;
        self.pending_set_ms = now_ms;
        self.has_pending = true;
    }

    /// The window of `grid_id`, created under `generation`, closed at (x, y).
    pub fn save(self: *PlacementMemory, grid_id: i64, x: f64, y: f64, generation: u64, current_generation: u64) void {
        if (generation != current_generation) {
            self.forget(grid_id);
            return;
        }
        if (self.find(grid_id)) |i| {
            self.saved[i] = .{ .grid_id = grid_id, .x = x, .y = y, .generation = generation };
            return;
        }
        if (self.saved_len > cap) {
            var min_i: usize = 0;
            for (self.saved[0..self.saved_len], 0..) |e, i| {
                if (e.grid_id < self.saved[min_i].grid_id) min_i = i;
            }
            self.removeAt(min_i);
        }
        self.saved[self.saved_len] = .{ .grid_id = grid_id, .x = x, .y = y, .generation = generation };
        self.saved_len += 1;
    }

    /// The placement for a window of `grid_id` opening under `generation`, or
    /// null for none. A pending drop point is consumed; a saved origin stays
    /// for the next reopen; one from another session is dropped.
    pub fn take(self: *PlacementMemory, grid_id: i64, generation: u64, now_ms: i64) ?Placement {
        if (self.has_pending) {
            self.has_pending = false;
            if (now_ms - self.pending_set_ms < pending_timeout_ms) {
                return .{ .kind = .pending, .x = self.pending_x, .y = self.pending_y };
            }
        }
        const i = self.find(grid_id) orelse return null;
        const e = self.saved[i];
        if (e.generation != generation) {
            self.removeAt(i);
            return null;
        }
        return .{ .kind = .saved, .x = e.x, .y = e.y };
    }

    fn forget(self: *PlacementMemory, grid_id: i64) void {
        if (self.find(grid_id)) |i| self.removeAt(i);
    }

    fn find(self: *const PlacementMemory, grid_id: i64) ?usize {
        for (self.saved[0..self.saved_len], 0..) |e, i| {
            if (e.grid_id == grid_id) return i;
        }
        return null;
    }

    fn removeAt(self: *PlacementMemory, i: usize) void {
        self.saved_len -= 1;
        self.saved[i] = self.saved[self.saved_len];
    }
};

test "a drop point beats a saved origin and is used once, within 500 ms" {
    var m: PlacementMemory = .{};
    m.save(5, 10, 20, 1, 1);
    m.setPending(300, 400, 1000);
    const p = m.take(5, 1, 1400).?;
    try std.testing.expectEqual(@as(f64, 300), p.x);
    try std.testing.expect(p.kind == .pending);
    // Consumed: the saved origin is what remains.
    const s = m.take(5, 1, 1401).?;
    try std.testing.expect(s.kind == .saved);
    try std.testing.expectEqual(@as(f64, 10), s.x);
    try std.testing.expectEqual(@as(f64, 20), s.y);
    // A stale drop point is dropped, not used.
    m.setPending(1, 2, 2000);
    try std.testing.expect(m.take(7, 1, 2500) == null);
    try std.testing.expect(!m.has_pending);
}

test "a saved origin belongs to the session that created it" {
    var m: PlacementMemory = .{};
    // Closed after a restart: nothing kept.
    m.save(3, 1, 1, 1, 2);
    try std.testing.expect(m.take(3, 2, 0) == null);
    // Kept, then asked for under a later generation: dropped.
    m.save(3, 1, 1, 2, 2);
    try std.testing.expect(m.take(3, 2, 0) != null);
    try std.testing.expect(m.take(3, 3, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), m.saved_len);
}

test "the 101st new grid evicts the smallest grid id; a re-save evicts nothing" {
    var m: PlacementMemory = .{};
    var g: i64 = 1;
    while (g <= 101) : (g += 1) m.save(g, @floatFromInt(g), 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 101), m.saved_len);
    m.save(50, 0, 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 101), m.saved_len);
    m.save(102, 0, 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 101), m.saved_len);
    try std.testing.expect(m.take(1, 1, 0) == null);
    try std.testing.expectEqual(@as(f64, 2), m.take(2, 1, 0).?.x);
}

// ---------------------------------------------------------------------------
// Cursor blink

/// A surface's cursor blink cadence, as the frontends' timers drive it.
/// `blinkwait`/`blinkon`/`blinkoff` come from guicursor via mode_info_set.
/// Neovim sends 0 for any entry guicursor leaves out (cursor_shape.c clears
/// the table), and its default gives terminal mode blinkon/blinkoff with no
/// blinkwait, so a zero wait means "start blinking at once", not "never".
pub const Blink = extern struct {
    wait_ms: u32 = 0,
    on_ms: u32 = 0,
    off_ms: u32 = 0,
    /// 0 = not blinking, 1 = waiting out blinkwait, 2 = cycling.
    phase: u8 = 0,
    visible: bool = true,

    /// Whether these settings blink at all.
    pub fn blinks(on_ms: u32, off_ms: u32) bool {
        return on_ms > 0 and off_ms > 0;
    }

    /// (Re)start with these settings, the cursor shown. Returns the delay to
    /// the first tick, or 0 for no timer (the cursor stays shown).
    pub fn start(self: *Blink, wait_ms: u32, on_ms: u32, off_ms: u32) u32 {
        self.wait_ms = wait_ms;
        self.on_ms = on_ms;
        self.off_ms = off_ms;
        self.visible = true;
        if (!blinks(on_ms, off_ms)) {
            self.phase = 0;
            return 0;
        }
        if (wait_ms > 0) {
            self.phase = 1;
            return wait_ms;
        }
        self.phase = 2;
        return on_ms;
    }

    /// The timer fired. Returns the delay to the next tick, or 0 for none.
    pub fn tick(self: *Blink) u32 {
        switch (self.phase) {
            1 => {
                self.phase = 2;
                self.visible = true;
                return self.on_ms;
            },
            2 => {
                self.visible = !self.visible;
                return if (self.visible) self.on_ms else self.off_ms;
            },
            else => return 0,
        }
    }

    /// Stop with the cursor shown, keeping the settings.
    pub fn stop(self: *Blink) void {
        self.phase = 0;
        self.visible = true;
    }

    pub fn sameSettings(self: *const Blink, wait_ms: u32, on_ms: u32, off_ms: u32) bool {
        return self.wait_ms == wait_ms and self.on_ms == on_ms and self.off_ms == off_ms;
    }
};

test "blinkwait, then on and off in turn" {
    var b: Blink = .{};
    try std.testing.expectEqual(@as(u32, 700), b.start(700, 400, 250));
    try std.testing.expect(b.visible);
    try std.testing.expectEqual(@as(u32, 400), b.tick());
    try std.testing.expect(b.visible);
    try std.testing.expectEqual(@as(u32, 250), b.tick());
    try std.testing.expect(!b.visible);
    try std.testing.expectEqual(@as(u32, 400), b.tick());
    try std.testing.expect(b.visible);
}

test "a zero blinkwait cycles at once; a zero on or off never blinks" {
    var b: Blink = .{};
    try std.testing.expectEqual(@as(u32, 500), b.start(0, 500, 500));
    try std.testing.expectEqual(@as(u32, 500), b.tick());
    try std.testing.expect(!b.visible);
    try std.testing.expectEqual(@as(u32, 0), b.start(700, 0, 250));
    try std.testing.expectEqual(@as(u32, 0), b.tick());
    try std.testing.expect(b.visible);
}

test "stopping leaves the cursor shown" {
    var b: Blink = .{};
    _ = b.start(0, 400, 250);
    _ = b.tick();
    try std.testing.expect(!b.visible);
    b.stop();
    try std.testing.expect(b.visible);
    try std.testing.expectEqual(@as(u32, 0), b.tick());
}

// ---------------------------------------------------------------------------
// Window snap

/// The window's terminal-area pixel size shrunk to a multiple of the cell
/// size, so no `size % cell` remainder strip is left uncleared past the
/// cell-aligned viewport. Applied to a stable *desired* size, not the live
/// window: snapping a snap's own result loses a strip on every reapply
/// (snap(snap(x,c1),c2) <= snap(x,c2)), so both frontends snap a value that
/// is updated only by a user or system resize, never by the snap's own
/// setFrame/SetWindowPos echo. At least one cell when desired_px > 0; 0 (no
/// window yet, e.g. before the terminal view's first layout pass) stays 0
/// rather than being floored up to one cell.
pub fn snapTerminalPx(desired_px: u32, cell_px: u32) u32 {
    if (desired_px == 0 or cell_px == 0) return desired_px;
    const cells = desired_px / cell_px;
    return @max(cell_px, cells * cell_px);
}

test "snapping keeps the largest whole-cell size, at least one cell above zero" {
    try std.testing.expectEqual(@as(u32, 990), snapTerminalPx(999, 11));
    try std.testing.expectEqual(@as(u32, 990), snapTerminalPx(990, 11));
    try std.testing.expectEqual(@as(u32, 11), snapTerminalPx(5, 11));
    // A desired size of 0 (no window yet) is not forced up to one cell: the
    // review found this defeated the caller's own `<= 0` skip-and-retry
    // guard, resizing a not-yet-laid-out window down to a single cell.
    try std.testing.expectEqual(@as(u32, 0), snapTerminalPx(0, 11));
}

test "snapping a stable desired size is idempotent across an intermediate cell change" {
    // The bug the desired-size rule fixes: chaining a snap onto its own
    // result loses a strip. Snapping the same desired size at both cells
    // must give the same final size no matter what ran in between.
    const desired: u32 = 999;
    const direct = snapTerminalPx(desired, 9);
    const via_other_cell = snapTerminalPx(snapTerminalPx(desired, 11), 9);
    try std.testing.expect(via_other_cell <= direct);
}
