const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const core = @import("zonvie_core");

// ---- Logging globals for atlas ensure callbacks ----
var log_atlas_ensure_calls: u64 = 0;
var log_atlas_ensure_suspicious: u64 = 0;
var log_atlas_ensure_last_report_ns: i128 = 0;
var log_atlas_zero_bbox_count: u32 = 0;
var log_row_no_glyphs_count: u32 = 0;
var log_row_bad_uv_count: u32 = 0;

// Track styled glyph stats
var log_styled_glyph_calls: u64 = 0;
var log_styled_glyph_ok: u64 = 0;
var log_styled_glyph_fail: u64 = 0;
var log_styled_glyph_last_report_ns: i128 = 0;

// =========================================================================
// Helper functions used by callbacks
// =========================================================================

fn requestFlushRetry(app: *App) void {
    if (app.shutting_down.load(.acquire)) return;
    _ = app_mod.g_flush_retry_failure_epoch.fetchAdd(1, .acq_rel);
    if (app.hwnd) |hwnd| _ = c.PostMessageW(hwnd, app_mod.WM_APP_FLUSH_RETRY_ARM, 0, 0);
}

/// Mark the current flush as failed after a frontend callback cannot preserve
/// the transaction. Pairs the core-side abort (zonvie_core_abort_flush — the core
/// keeps its dirty state and re-sends next flush) with the frontend-side
/// flag that makes onFlushEnd CANCEL the TBS write-set brackets instead of
/// committing partially-updated (often just-cleared) buffers as a complete
/// frame. Caller must hold app.mu.
fn failFlush(app: *App) void {
    core.zonvie_core_abort_flush(app.corep);
    app.flush_failed = true;
    // Same rationale as onFlushBegin's backpressure abort: without a retry,
    // content that failed to allocate stays unflushed until the next
    // unrelated Neovim redraw. Vertex callbacks run on the core thread, so
    // persist the request and post a UI-thread wakeup; the message loop also
    // consumes the request directly if PostMessageW hits a full queue.
    requestFlushRetry(app);
}

/// Lazily open the main row/flat write set on its first actual mutation.
/// No-op and cursor-only flushes consequently avoid the O(max_rows) slot
/// release/copy/retain work in TripleBufferedSurface.beginFlush.
/// Caller holds app.mu.
fn ensureMainSurfaceFlush(app: *App) bool {
    if (app.tbs.is_in_flush) return true;
    if (app.tbs.beginFlush(app.alloc)) return true;
    failFlush(app);
    return false;
}

/// Fetch the inline atlas pointer without nesting app.mu -> atlas.mu.
/// Recovery never replaces App.atlas, and App.deinit joins the core thread
/// before destroying it, so the pointer remains valid for the callback.
fn atlasForCoreCallback(app: *App) ?*dwrite_d2d.Renderer {
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    if (app.atlas) |*a| return a;
    return null;
}

fn rememberAtlasCreateRetry(app: *App, atlas_w: u32, atlas_h: u32) void {
    app.atlas_create_retry_w.store(atlas_w, .monotonic);
    app.atlas_create_retry_h.store(atlas_h, .monotonic);
    app.atlas_create_retry_pending.store(true, .release);
}

fn abortAtlasFlush(app: *App, reason: []const u8) void {
    if (applog.isEnabled()) applog.appLog("[atlas] aborting flush: {s}\n", .{reason});
    if (app.corep) |corep| core.zonvie_core_abort_flush(corep);
    app.flush_failed = true;
    requestFlushRetry(app);
}

fn recreateAtlasCpu(a: *dwrite_d2d.Renderer, atlas_w: u32, atlas_h: u32) bool {
    a.recreateAtlasTexture(atlas_w, atlas_h) catch {
        // Keep one immediate retry for a transient allocator failure. A second
        // failure is no longer fatal: the requested dimensions stay pending
        // and the existing flush-retry timer provides bounded backoff.
        a.recreateAtlasTexture(atlas_w, atlas_h) catch |e| {
            if (applog.isEnabled()) applog.appLog("[atlas] recreateAtlasTexture({d}x{d}) failed twice: {any}\n", .{ atlas_w, atlas_h, e });
            return false;
        };
    };
    return true;
}

/// Retry a void-ABI on_atlas_create operation before opening the next TBS
/// write set. Timer-driven retries never wait behind the same wedged paint;
/// they simply abort again until the UI reader is no longer active.
fn preparePendingAtlasCreate(app: *App) bool {
    if (!app.atlas_create_retry_pending.load(.acquire)) return true;

    const atlas_w = app.atlas_create_retry_w.load(.monotonic);
    const atlas_h = app.atlas_create_retry_h.load(.monotonic);
    const a = atlasForCoreCallback(app) orelse {
        abortAtlasFlush(app, "atlas renderer unavailable during create retry");
        return false;
    };

    const admission = app.beginAtlasResetTransaction();
    if (admission != .acquired) {
        abortAtlasFlush(app, if (admission == .shutting_down) "shutdown during atlas create retry" else "atlas reader still active during create retry");
        return false;
    }
    if (!recreateAtlasCpu(a, atlas_w, atlas_h)) {
        // recreateAtlasTexture can fail after committing a new CPU atlas
        // generation (for example while rebuilding the legacy D2D target).
        // Keep paint admission closed until a retry commits matching UVs.
        abortAtlasFlush(app, "atlas recreation retry failed");
        return false;
    }

    app.atlas_create_retry_pending.store(false, .release);
    return true;
}

/// Convert NDC cursor vertices to a pixel RECT using the D3D11 viewport
/// dimensions. The viewport is snapped to cell boundaries (content_height),
/// which is typically smaller than the full client area. Using the client
/// rect directly would cause cumulative position drift toward the bottom.
pub fn cursorRectInViewport(
    verts: []const app_mod.Vertex,
    vp_x: u32,
    vp_y: u32,
    vp_w: u32,
    vp_h: u32,
    clamp_right: i32,
    clamp_bottom: i32,
) ?c.RECT {
    if (verts.len == 0) return null;

    var minx: f32 = verts[0].position[0];
    var maxx: f32 = minx;
    var miny: f32 = verts[0].position[1];
    var maxy: f32 = miny;

    for (verts) |v| {
        if (v.position[0] < minx) minx = v.position[0];
        if (v.position[0] > maxx) maxx = v.position[0];
        if (v.position[1] < miny) miny = v.position[1];
        if (v.position[1] > maxy) maxy = v.position[1];
    }

    const w_f: f32 = @floatFromInt(vp_w);
    const h_f: f32 = @floatFromInt(vp_h);
    const x_off_f: f32 = @floatFromInt(vp_x);
    const y_off_f: f32 = @floatFromInt(vp_y);

    // NDC -> viewport pixel (absolute coords)
    const l_f = x_off_f + (minx + 1.0) * 0.5 * w_f;
    const r_f = x_off_f + (maxx + 1.0) * 0.5 * w_f;
    const t_f = y_off_f + (1.0 - maxy) * 0.5 * h_f;
    const b_f = y_off_f + (1.0 - miny) * 0.5 * h_f;

    var l: i32 = @intFromFloat(@floor(l_f));
    var r: i32 = @intFromFloat(@ceil(r_f));
    var t: i32 = @intFromFloat(@floor(t_f));
    var b: i32 = @intFromFloat(@ceil(b_f));

    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (r > clamp_right) r = clamp_right;
    if (b > clamp_bottom) b = clamp_bottom;

    if (r <= l or b <= t) return null;
    return .{ .left = l, .top = t, .right = r, .bottom = b };
}

pub fn rectFromVerts(hwnd: c.HWND, verts: []const app_mod.Vertex) ?c.RECT {
    if (verts.len == 0) return null;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const w_f: f32 = @floatFromInt(@max(1, client.right - client.left));
    const h_f: f32 = @floatFromInt(@max(1, client.bottom - client.top));

    var minx: f32 = verts[0].position[0];
    var maxx: f32 = verts[0].position[0];
    var miny: f32 = verts[0].position[1];
    var maxy: f32 = verts[0].position[1];

    for (verts) |v| {
        const x = v.position[0];
        const y = v.position[1];
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
    }

    // NDC -> pixel
    const l_f = (minx + 1.0) * 0.5 * w_f;
    const r_f = (maxx + 1.0) * 0.5 * w_f;
    const t_f = (1.0 - maxy) * 0.5 * h_f;
    const b_f = (1.0 - miny) * 0.5 * h_f;

    var l: i32 = @intFromFloat(@floor(l_f));
    var r: i32 = @intFromFloat(@ceil(r_f));
    var t: i32 = @intFromFloat(@floor(t_f));
    var b: i32 = @intFromFloat(@ceil(b_f));

    // clamp
    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (r > client.right) r = client.right;
    if (b > client.bottom) b = client.bottom;

    if (r <= l or b <= t) return null;

    return .{ .left = l, .top = t, .right = r, .bottom = b };
}

pub fn markDirtyRowsByRect(app: *App, rc: c.RECT) void {
    const row_h: u32 = app.rowHeightPx();

    // When ext_tabline is enabled (and content_hwnd is not used), the rect coordinates
    // are in hwnd (main window) coordinate system which includes the tabbar.
    // We need to subtract the tabbar height to get the correct row number.
    const y_offset: i32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
        app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT)
    else
        0;

    const top_u: u32 = @intCast(@max(0, rc.top - y_offset));
    const bot_u: u32 = @intCast(@max(0, rc.bottom - y_offset));

    var r0: u32 = top_u / row_h;
    var r1: u32 = (bot_u + (row_h - 1)) / row_h; // ceil

    // Clamp to current grid rows to avoid out-of-bounds (e.g. r == rows).
    const max_rows: u32 = app.surface.rows;
    if (max_rows != 0) {
        if (r0 > max_rows) r0 = max_rows;
        if (r1 > max_rows) r1 = max_rows;
    }

    // TBS: also mark rows dirty in flush_dirty (if in flush).
    if (app.tbs.is_in_flush) {
        var rr: u32 = r0;
        while (rr < r1) : (rr += 1) {
            if (rr < app.tbs.sparse_sync.flush_dirty.bit_length) {
                if (!app.tbs.markFlushDirtyRow(rr)) failFlush(app);
            }
        }
    }
}

/// Remove DECO_CURSOR vertices from a vertex list in-place.
fn stripCursorVerts(verts: *std.ArrayListUnmanaged(app_mod.Vertex)) void {
    var write: usize = 0;
    for (verts.items) |v| {
        if ((v.deco_flags & app_mod.DECO_CURSOR) == 0) {
            verts.items[write] = v;
            write += 1;
        }
    }
    verts.items.len = write;
}

/// Swap and shift row vertex buffers for a scroll region.
/// Shared between onMainRowScroll and onGridRowScroll.
/// Swaps RowVerts structs to follow scroll direction. Moved rows keep their
/// existing VB data (origin_row tracks where vertices were generated; the draw
/// path applies viewport Y translation). Only vacated rows are invalidated.
/// When row_valid is non-null, updates the validity bitset (main window only).
fn swapAndShiftRows(
    row_verts: []app_mod.RowVerts,
    row_start: u32,
    row_end: u32,
    rows_delta: i32,
    row_valid: ?*std.DynamicBitSetUnmanaged,
) void {
    const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
    const start_idx: usize = @intCast(row_start);
    const end_idx: usize = @intCast(row_end);
    const shift: usize = @intCast(abs_rows);

    if (rows_delta > 0) {
        var dst: usize = start_idx;
        while (dst + shift < end_idx) : (dst += 1) {
            const src = dst + shift;
            std.mem.swap(app_mod.RowVerts, &row_verts[dst], &row_verts[src]);
            // No shiftVertsY or gen increment — VB is reused via viewport Y offset.
            if (row_valid) |rv| {
                if (src < rv.bit_length and rv.isSet(src)) {
                    rv.set(dst);
                } else if (dst < rv.bit_length) {
                    rv.unset(dst);
                }
            }
        }
        var vacated: usize = end_idx - shift;
        while (vacated < end_idx) : (vacated += 1) {
            row_verts[vacated].verts.clearRetainingCapacity();
            row_verts[vacated].gen +%= 1;
            if (row_valid) |rv| {
                if (vacated < rv.bit_length) rv.unset(vacated);
            }
        }
    } else {
        var dst: usize = end_idx;
        while (dst > start_idx + shift) {
            dst -= 1;
            const src = dst - shift;
            std.mem.swap(app_mod.RowVerts, &row_verts[dst], &row_verts[src]);
            // No shiftVertsY or gen increment — VB is reused via viewport Y offset.
            if (row_valid) |rv| {
                if (src < rv.bit_length and rv.isSet(src)) {
                    rv.set(dst);
                } else if (dst < rv.bit_length) {
                    rv.unset(dst);
                }
            }
        }
        var vacated: usize = start_idx;
        while (vacated < start_idx + shift) : (vacated += 1) {
            row_verts[vacated].verts.clearRetainingCapacity();
            row_verts[vacated].gen +%= 1;
            if (row_valid) |rv| {
                if (vacated < rv.bit_length) rv.unset(vacated);
            }
        }
    }
}

/// Remap slot indices in row_map for a scroll region. Physical data does not move.
/// macOS equivalent: remapMainRowSlots (MetalTerminalRenderer.swift).
/// Vacated rows retain their old slot references (shared pool data is NOT modified
/// to preserve COW safety with the committed set). The caller must ensure that
/// vacated rows are regenerated via on_vertices_row → cowDetachRow before commit.
/// ref_counts do not change (same VertexSet, just index rearrangement).
fn remapRowSlots(
    row_map: []app_mod.RowMapping,
    pool: *app_mod.SlotPool,
    alloc: std.mem.Allocator,
    row_start: u32,
    row_end: u32,
    rows_delta: i32,
) void {
    const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
    const start_idx: usize = @intCast(row_start);
    const end_idx: usize = @intCast(row_end);
    const shift: usize = @intCast(abs_rows);

    if (rows_delta > 0) {
        // Scroll up: save vacated slots from top of region
        var saved: [4096]app_mod.RowMapping = undefined;
        const save_count = @min(shift, 4096);
        var si: usize = 0;
        while (si < save_count) : (si += 1) {
            saved[si] = row_map[start_idx + si];
        }
        // Mappings beyond the save buffer are about to be overwritten by the
        // shift with no surviving copy — release their pool references now,
        // or the slots (and their vertex capacity) leak forever
        // (releaseAllSlots only walks live row_map entries).
        var drop: usize = save_count;
        while (drop < shift) : (drop += 1) {
            const m = row_map[start_idx + drop];
            if (m.slot != app_mod.SLOT_NONE) pool.release(alloc, m.slot);
        }
        // Shift mappings down
        var dst: usize = start_idx;
        while (dst + shift < end_idx) : (dst += 1) {
            row_map[dst] = row_map[dst + shift];
        }
        // Place saved mappings in vacated region, clear their verts
        var vacated: usize = end_idx - shift;
        var vi: usize = 0;
        while (vacated < end_idx) : ({
            vacated += 1;
            vi += 1;
        }) {
            if (vi < save_count) {
                row_map[vacated] = saved[vi];
            } else {
                // Shift exceeded the save buffer: the original mapping is
                // gone. Leave the entry unmapped rather than keeping the
                // shift's leftover, which would DUPLICATE a mapping that
                // also lives at its shifted position (two rows referencing
                // one slot without a ref-count bump -> ownership corruption
                // on release/reuse).
                row_map[vacated] = .{ .slot = app_mod.SLOT_NONE };
            }
            // Do NOT modify the shared pool slot data here.
            // The slot may be referenced by the committed set (ref_count > 1
            // after shallowCopyVertexSet).  Clearing verts / bumping ver /
            // changing origin_row would corrupt the committed set's view,
            // causing empty or mispositioned rows when WM_PAINT reads the
            // committed set during this flush.
            // The subsequent on_vertices_row → cowDetachRow will allocate a
            // fresh slot (ref_count > 1 triggers COW) and write the new
            // vertex data there, so this clearing was always redundant.
        }
    } else {
        // Scroll down: save vacated slots from bottom of region
        var saved: [4096]app_mod.RowMapping = undefined;
        const save_count = @min(shift, 4096);
        var si: usize = 0;
        while (si < save_count) : (si += 1) {
            saved[si] = row_map[end_idx - shift + si];
        }
        // Release the unsaved tail (see the scroll-up branch): overwritten
        // by the shift with no surviving copy — pool refs would leak.
        var drop: usize = save_count;
        while (drop < shift) : (drop += 1) {
            const m = row_map[end_idx - shift + drop];
            if (m.slot != app_mod.SLOT_NONE) pool.release(alloc, m.slot);
        }
        // Shift mappings up
        var dst: usize = end_idx;
        while (dst > start_idx + shift) {
            dst -= 1;
            row_map[dst] = row_map[dst - shift];
        }
        // Place saved mappings in vacated region, clear their verts
        var vacated: usize = start_idx;
        var vi: usize = 0;
        while (vacated < start_idx + shift) : ({
            vacated += 1;
            vi += 1;
        }) {
            if (vi < save_count) {
                row_map[vacated] = saved[vi];
            } else {
                // See the scroll-up branch: never leave a duplicated
                // mapping when the shift exceeded the save buffer.
                row_map[vacated] = .{ .slot = app_mod.SLOT_NONE };
            }
            // Do NOT modify the shared pool slot data here (same reason
            // as the scroll-up branch above: COW safety).
        }
    }
}

fn recomputeRowValidCount(app: *App) void {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < app.row_valid.bit_length) : (i += 1) {
        if (app.row_valid.isSet(i)) count += 1;
    }
    app.row_valid_count = count;
}

fn ensureRowStorageGeneric(
    alloc: std.mem.Allocator,
    row_verts: *std.ArrayListUnmanaged(app_mod.RowVerts),
    row: u32,
) bool {
    const need: usize = @intCast(row + 1);
    if (row_verts.items.len < need) {
        const old_len = row_verts.items.len;
        row_verts.resize(alloc, need) catch return false;
        var i = old_len;
        while (i < need) : (i += 1) {
            row_verts.items[i] = .{};
        }
    }
    return row < row_verts.items.len;
}

fn storeSurfaceRowVerts(
    alloc: std.mem.Allocator,
    row_verts: *std.ArrayListUnmanaged(app_mod.RowVerts),
    row: u32,
    verts_ptr: ?[*]const app_mod.Vertex,
    vert_count: usize,
) bool {
    if (!ensureRowStorageGeneric(alloc, row_verts, row)) return false;
    var rv = &row_verts.items[@intCast(row)];
    if (verts_ptr != null and vert_count != 0) {
        // Reserve BEFORE clearing: an OOM then keeps the row's previous
        // content intact (atomic per-row update; gen unbumped, so gen-gated
        // consumers keep drawing the consistent old data).
        rv.verts.ensureTotalCapacity(alloc, vert_count) catch return false;
        rv.verts.clearRetainingCapacity();
        rv.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
    } else {
        rv.verts.clearRetainingCapacity();
    }
    rv.gen +%= 1;
    rv.origin_row = row; // Vertices generated for this logical row position.
    return true;
}

pub fn appendRowsFromUpdateRegion(
    hwnd: c.HWND,
    app: *App,
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    row_verts_len: u32,
) void {
    const log_enabled = applog.isEnabled();
    const log_t0_ns: i128 = if (log_enabled) core.clock.nowNs() else 0;

    // Pre-allocate capacity for worst case (all rows dirty)
    rows_to_draw.ensureTotalCapacity(app.alloc, row_verts_len) catch {};

    var log_rect_area_sum: u64 = 0;
    var log_rows_appended: u32 = 0;

    // Create an empty region to receive the update region.
    const hrgn = c.CreateRectRgn(0, 0, 0, 0) orelse return;
    defer _ = c.DeleteObject(hrgn);

    // Populate hrgn with the window's update region (do not erase).
    const rgn_type: c.INT = c.GetUpdateRgn(hwnd, hrgn, c.FALSE);
    if (rgn_type == c.ERROR) return;

    const need_bytes: c.DWORD = c.GetRegionData(hrgn, 0, null);
    if (need_bytes == 0) return;

    if (log_enabled) {
        applog.appLog("[win] updateRgn need_bytes={d} rgn_type={d}\n", .{ need_bytes, rgn_type });
    }

    // RGNDATA needs alignment; use alignedAlloc.
    const alignment: std.mem.Alignment =
        @enumFromInt(@ctz(@as(usize, @alignOf(c.RGNDATA))));

    const buf = app.alloc.alignedAlloc(u8, alignment, need_bytes) catch return;
    defer app.alloc.free(buf);

    const rgndata: *c.RGNDATA = @ptrCast(@alignCast(buf.ptr));
    const got_bytes: c.DWORD = c.GetRegionData(hrgn, need_bytes, rgndata);
    if (got_bytes == 0) return;

    const row_h_px0: i32 = @intCast(app.rowHeightPx());

    // RECT array starts at rgndata.Buffer (flexible array).
    const rects_ptr_u8: [*]u8 = @ptrCast(&rgndata.Buffer);
    const rects_ptr: [*]c.RECT = @ptrCast(@alignCast(rects_ptr_u8));

    const n: usize = @intCast(rgndata.rdh.nCount);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dr = rects_ptr[i];

        const top_px: i32 = @max(0, dr.top);
        const bottom_px: i32 = @max(0, dr.bottom);

        // area accumulation (clamp negatives)
        const w_i32: i32 = dr.right - dr.left;
        const h_i32: i32 = dr.bottom - dr.top;
        if (w_i32 > 0 and h_i32 > 0) {
            log_rect_area_sum += @as(u64, @intCast(w_i32)) * @as(u64, @intCast(h_i32));
        }

        // [top_row, bottom_row)
        const top_row_i32: i32 = @divTrunc(top_px, row_h_px0);
        const bottom_row_i32: i32 = @divTrunc(bottom_px + (row_h_px0 - 1), row_h_px0);

        const top_row: u32 = @intCast(@max(0, top_row_i32));
        const bottom_row: u32 = @intCast(@min(@as(i32, @intCast(row_verts_len)), bottom_row_i32));

        var rr: u32 = top_row;
        while (rr < bottom_row) : (rr += 1) {
            rows_to_draw.appendAssumeCapacity(rr);
            log_rows_appended += 1;
        }
    }

    if (log_enabled) {
        const log_t1_ns: i128 = core.clock.nowNs();
        const log_dur_us: u64 = @intCast(@max(@as(i128, 0), log_t1_ns - log_t0_ns) / 1_000);
        applog.appLog(
            "[win] updateRgn rects={d} rows_appended={d} area_px={d} dur_us={d} got_bytes={d}\n",
            .{ n, log_rows_appended, log_rect_area_sum, log_dur_us, got_bytes },
        );
    }
}

pub fn unionRect(a: c.RECT, b: c.RECT) c.RECT {
    return .{
        .left = if (a.left < b.left) a.left else b.left,
        .top = if (a.top < b.top) a.top else b.top,
        .right = if (a.right > b.right) a.right else b.right,
        .bottom = if (a.bottom > b.bottom) a.bottom else b.bottom,
    };
}

// =========================================================================
// Vertex / rendering callbacks
// =========================================================================

pub fn onVerticesPartial(
    ctx: ?*anyopaque,
    main_ptr: ?[*]const app_mod.Vertex,
    main_count: usize,
    cursor_ptr: ?[*]const app_mod.Vertex,
    cursor_count: usize,
    flags: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog(
        "[win] onVerticesPartial flags=0x{x} main_count={d} cursor_count={d}\n",
        .{ flags, main_count, cursor_count },
    );

    app.mu.lockUncancelable(core.clock.io());

    if ((flags & app_mod.VERT_UPDATE_MAIN) != 0 and !ensureMainSurfaceFlush(app)) {
        app.mu.unlock(core.clock.io());
        return;
    }
    if ((flags & app_mod.VERT_UPDATE_CURSOR) != 0) {
        const cursor_slice: []const app_mod.Vertex = if (cursor_ptr != null and cursor_count != 0)
            cursor_ptr.?[0..cursor_count]
        else
            &.{};
        const cursor_row: ?u32 = if (cursor_slice.len != 0 and app.cursor != null)
            @intCast(app.cursor.?.row)
        else
            null;
        if (!app.tbs.storeMainCursor(app.alloc, cursor_slice, cursor_row)) {
            failFlush(app);
            app.mu.unlock(core.clock.io());
            return;
        }
    }

    var row_mode = app.surface.row_mode;

    // Track if cursor was updated (for blink update after unlock)
    var cursor_updated: bool = false;

    // Flags specification: keep the side that is not updated
    if ((flags & app_mod.VERT_UPDATE_MAIN) != 0) {
        if (row_mode) {
            app.surface.row_mode = false;
            row_mode = false;
        }
        // Note: We don't set content_rows_dirty here.
        // For non-row-mode, full repaints are triggered anyway.
        // For row-mode, WM_PAINT determines if it's cursor-only.

        app.surface.verts.clearRetainingCapacity();
        if (main_ptr != null and main_count != 0) {
            app.surface.verts.appendSlice(app.alloc, main_ptr.?[0..main_count]) catch {
                // OOM after the old verts were already cleared: an EMPTY set
                // would be committed as this frame while the core clears its
                // dirty state on flush end — the content would stay missing
                // until an unrelated change.
                failFlush(app);
            };
        }

        // Non-row-mode: main update implies screen update.
        // Row-mode: main_verts is not used for drawing; do not force full paint here.
        // InvalidateRect deferred to onFlushEnd for coalescing.
        if (!row_mode) {
            app.paint_rects.clearRetainingCapacity();
        }
        app.flush_needs_invalidate = true;
    }

    if ((flags & app_mod.VERT_UPDATE_CURSOR) != 0) {
        // compute old rect before overwriting cursor_verts
        const old_rc = app.last_cursor_rect_px;

        app.surface.cursor_verts.clearRetainingCapacity();
        if (cursor_ptr != null and cursor_count != 0) {
            const slice = cursor_ptr.?[0..cursor_count];

            // Log cursor vertex data for debugging
            if (applog.isEnabled() and slice.len >= 1) {
                const v0 = slice[0];
                applog.appLog(
                    "[win] onVerticesPartial cursor v0: pos=({d:.2},{d:.2}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                    .{ v0.position[0], v0.position[1], v0.color[0], v0.color[1], v0.color[2], v0.color[3] },
                );
            }
            app.surface.cursor_verts.appendSlice(app.alloc, slice) catch failFlush(app);

            if (app.hwnd) |hwnd| {
                // Compute viewport-aware cursor rect matching D3D11 viewport.
                const rect_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                var rect_client: c.RECT = undefined;
                _ = c.GetClientRect(rect_hwnd, &rect_client);

                const vp_y: u32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @intCast(app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT))
                else
                    0;
                const vp_x: u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    0;
                const sidebar_r: u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and app.sidebar_position_right)
                    @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    0;
                const client_w: u32 = @intCast(@max(1, rect_client.right));
                const client_h: u32 = @intCast(@max(1, rect_client.bottom));
                const base_w: u32 = if (app.config.scrollbar.enabled and app.config.scrollbar.isAlways())
                    app_mod.getEffectiveContentWidth(app, client_w)
                else
                    client_w;
                const vp_w: u32 = if (base_w > vp_x + sidebar_r) base_w - vp_x - sidebar_r else 1;
                const cell_total_h: u32 = app.rowHeightPx();
                const drawable_h: u32 = if (client_h > vp_y) client_h - vp_y else 0;
                const vp_h: u32 = @max((drawable_h / cell_total_h) * cell_total_h, cell_total_h);

                const new_rc = cursorRectInViewport(slice, vp_x, vp_y, vp_w, vp_h, rect_client.right, rect_client.bottom);
                app.last_cursor_rect_px = new_rc;

                // Row-mode: cursor move should only invalidate cursor rects.
                if (row_mode) {
                    if (!app.cursor_overlay_active) {
                        app.cursor_overlay_active = true;
                        app.need_full_seed.store(true, .seq_cst);
                        app.tbs.markFlushPaintFull();
                        app.paint_rects.clearRetainingCapacity();
                    }
                    // Record damage rects for WM_PAINT dirty-rect drawing.
                    // InvalidateRect deferred to onFlushEnd.
                    if (old_rc) |r0| {
                        app.paint_rects.append(app.alloc, r0) catch {};
                    }
                    if (new_rc) |r1| {
                        app.paint_rects.append(app.alloc, r1) catch {};
                    }
                    if (old_rc) |r0| {
                        markDirtyRowsByRect(app, r0);
                    }
                    if (new_rc) |r1| {
                        markDirtyRowsByRect(app, r1);
                    }
                } else {
                    // Non-row-mode: dirty state tracked via paint_full.
                    // InvalidateRect deferred to onFlushEnd.
                }
            }
        } else {
            // no cursor verts -> clear last rect
            // If cursor was already absent (old_rc == null), nothing changed
            // on the main window — skip dirty marking and invalidation.
            // This prevents unnecessary main window repaints when the cursor
            // is on an external grid and that grid scrolls (cursor_rev bumps
            // but the main window cursor state is unchanged).
            if (old_rc == null) {
                // No visual change on main window — skip entirely.
            } else {
                app.last_cursor_rect_px = null;

                // Track dirty rows for cursor erasure.
                // InvalidateRect deferred to onFlushEnd.
                if (row_mode) {
                    markDirtyRowsByRect(app, old_rc.?);
                }
                // cursor verts updated => bump generation
                app.cursor_gen +%= 1;
                cursor_updated = true;
                app.flush_needs_invalidate = true;
            }
        }

        if (cursor_ptr != null and cursor_count != 0) {
            // cursor verts updated => bump generation
            app.cursor_gen +%= 1;
            cursor_updated = true;
            app.flush_needs_invalidate = true;
        }
    }

    // TBS: write to write set.
    if (app.tbs.is_in_flush) {
        const ws = app.tbs.writeSet();
        if ((flags & app_mod.VERT_UPDATE_MAIN) != 0) {
            ws.row_mode = false;
            app.tbs.requireFullRowSync();
            ws.flat_verts.clearRetainingCapacity();
            if (main_ptr != null and main_count != 0) {
                ws.flat_verts.appendSlice(app.alloc, main_ptr.?[0..main_count]) catch failFlush(app);
            }
            app.tbs.flush_paint_full = true;
        }
    }

    // Get hwnd before unlock
    const hwnd_for_blink = app.hwnd;
    // Always post blink update when cursor flag is set (covers cursor on external grid
    // where global grid gets cursor_count=0 but blink settings may have changed via mode_change).
    const blink_update_needed = cursor_updated or ((flags & app_mod.VERT_UPDATE_CURSOR) != 0);

    app.mu.unlock(core.clock.io());

    // Post message to update cursor blinking (avoid deadlock by doing it on UI thread)
    if (blink_update_needed) {
        if (hwnd_for_blink) |hwnd| {
            _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CURSOR_BLINK, 0, 0);
        }
    }
}

pub fn onVerticesRow(
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_count: u32,
    verts_ptr: ?[*]const app_mod.Vertex,
    vert_count: usize,
    flags: u32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const log_enabled = applog.isEnabled();
    const log_verbose = applog.isVerbose();
    const layout_only =
        row_count == 0 and
        vert_count == 0 and
        (total_rows == 0 or total_cols == 0);

    // In row-only ABI configurations the core sends the main-window cursor
    // through this callback with CURSOR set and MAIN clear. Reuse the partial
    // callback's independent cursor-layer transaction; the row payload must
    // never replace or dirty the main row set.
    if (grid_id == 1 and
        (flags & app_mod.VERT_UPDATE_CURSOR) != 0 and
        (flags & app_mod.VERT_UPDATE_MAIN) == 0)
    {
        onVerticesPartial(ctx, null, 0, verts_ptr, vert_count, flags);
        return;
    }

    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    if (log_enabled) {
        app.log_flush_row_callbacks +|= 1;
        app.log_flush_vertex_count +|= @intCast(vert_count);
    }

    if (log_verbose) {
        var cur_enabled: u32 = 0;
        var cur_row: u32 = 0;
        var cur_col: u32 = 0;
        if (app.cursor) |cur| {
            cur_enabled = cur.enabled;
            cur_row = cur.row;
            cur_col = cur.col;
        }
        applog.appLog(
            "[win] on_vertices_row row_start={d} row_count={d} vert_count={d} flags=0x{x} cursor_en={d} cursor_row={d} cursor_col={d} rows={d} row_valid={d} row_verts_len={d}\n",
            .{
                row_start,
                row_count,
                vert_count,
                flags,
                cur_enabled,
                cur_row,
                cur_col,
                app.surface.rows,
                app.row_valid_count,
                app.surface.row_verts.items.len,
            },
        );
    }
    if (row_count != 1 and !layout_only and log_verbose) {
        applog.appLog(
            "[win] on_vertices_row WARN row_count={d} row_start={d} vert_count={d}\n",
            .{ row_count, row_start, vert_count },
        );
    }
    if (log_verbose and verts_ptr != null and vert_count != 0) {
        const verts = verts_ptr.?[0..vert_count];
        var glyph_verts: u32 = 0;
        var bad_uv: u32 = 0;
        var bad_pos: u32 = 0;
        var i: usize = 0;
        while (i < verts.len) : (i += 1) {
            const v = verts[i];
            const u = v.texCoord[0];
            const v2 = v.texCoord[1];
            if (!(u == -1.0 and v2 == -1.0)) {
                glyph_verts += 1;
                if (!std.math.isFinite(u) or !std.math.isFinite(v2)) {
                    bad_uv += 1;
                } else if (u < 0.0 or u > 1.0 or v2 < 0.0 or v2 > 1.0) {
                    bad_uv += 1;
                }
            }
            if (!std.math.isFinite(v.position[0]) or !std.math.isFinite(v.position[1])) {
                bad_pos += 1;
            }
        }
        if (glyph_verts == 0 and vert_count >= 12 and log_row_no_glyphs_count < 16) {
            applog.appLog(
                "[win] on_vertices_row WARN no_glyphs row_start={d} vert_count={d}\n",
                .{ row_start, vert_count },
            );
            log_row_no_glyphs_count += 1;
        }
        if ((bad_uv != 0 or bad_pos != 0) and log_row_bad_uv_count < 16) {
            applog.appLog(
                "[win] on_vertices_row WARN bad_verts row_start={d} vert_count={d} bad_uv={d} bad_pos={d}\n",
                .{ row_start, vert_count, bad_uv, bad_pos },
            );
            log_row_bad_uv_count += 1;
        }
        // Log first few vertex details for diagnostic (only for rows with glyphs)
        if (glyph_verts > 0 and row_start <= 2) {
            const log_count = @min(verts.len, 6);
            var vi: usize = 0;
            while (vi < log_count) : (vi += 1) {
                const v = verts[vi];
                applog.appLog(
                    "[win] on_vertices_row row={d} v[{d}] pos=({d:.2},{d:.2}) uv=({d:.4},{d:.4}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                    .{
                        row_start,     vi,
                        v.position[0], v.position[1],
                        v.texCoord[0], v.texCoord[1],
                        v.color[0],    v.color[1],
                        v.color[2],    v.color[3],
                    },
                );
            }
            // Also log first few GLYPH vertices (UV != -1,-1)
            var glyph_logged: u32 = 0;
            var gi: usize = 0;
            while (gi < verts.len and glyph_logged < 3) : (gi += 1) {
                const v = verts[gi];
                if (!(v.texCoord[0] == -1.0 and v.texCoord[1] == -1.0)) {
                    applog.appLog(
                        "[win] on_vertices_row row={d} GLYPH v[{d}] pos=({d:.2},{d:.2}) uv=({d:.4},{d:.4}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                        .{
                            row_start,     gi,
                            v.position[0], v.position[1],
                            v.texCoord[0], v.texCoord[1],
                            v.color[0],    v.color[1],
                            v.color[2],    v.color[3],
                        },
                    );
                    glyph_logged += 1;
                }
            }
        }
    }

    // Handle external grids (grid_id != 1) separately
    // External grids use their own vertex storage (ext_win.surface.verts or pending_external_verts)
    if (grid_id != 1) {
        const flush_generation = app.core_flush_generation.load(.acquire);
        if (log_verbose) applog.appLog(
            "[win] on_vertices_row external grid_id={d} row_start={d} vert_count={d} total_rows={d} total_cols={d}\n",
            .{ grid_id, row_start, vert_count, total_rows, total_cols },
        );

        // Cursor layer: core sends cursor as separate on_vertices_row
        // with VERT_UPDATE_CURSOR flag. Append cursor verts to the target
        // row so they are drawn as part of content (same as pre-refactor).
        // Next content update for this row will replace everything via
        // storeSurfaceRowVerts, clearing old cursor verts.
        const is_cursor_update = (flags & 2) != 0; // VERT_UPDATE_CURSOR

        // A newly-created HWND can still have a pending CPU frame when the
        // UI thread hit OOM while seeding its TBS. Keep subsequent core
        // updates in that pending transaction until the UI applies it
        // successfully; writing the live surface here would let an older
        // pending frame overwrite newer vertices on retry.
        var has_pending_capture = false;
        for (app.pending_external_verts.items) |pv| {
            if (pv.grid_id == grid_id) {
                has_pending_capture = true;
                break;
            }
        }
        const live_ext_win = blk: {
            if (has_pending_capture) break :blk null;
            const ext_win = app.external_windows.get(grid_id) orelse break :blk null;
            // A closing HWND belongs to the old lifecycle. Capture updates for
            // the replacement lifecycle instead of letting the core consume
            // them as successful writes to a window that will be destroyed.
            if (ext_win.is_pending_close) break :blk null;
            // External surfaces join lazily on their first update. Bracketing
            // every external HWND in onFlushBegin made one occluded/busy window
            // apply backpressure to unrelated main-grid flushes and copied every
            // external committed set even when it was untouched.
            if (!is_cursor_update and !ext_win.tbs.is_in_flush) {
                if (!app.core_flush_active.load(.acquire) or !ext_win.tbs.beginFlush(app.alloc)) {
                    failFlush(app);
                    return;
                }
            }
            break :blk ext_win;
        };

        // Try to find an existing external window with no pending seed.
        if (live_ext_win) |ext_win| {
            if (!is_cursor_update and ext_win.tbs.is_in_flush) {
                ext_win.tbs.writeSet().metrics_gen = app.shared_metrics_gen;
            }
            if (is_cursor_update) {
                if (!app.core_flush_active.load(.acquire)) {
                    failFlush(app);
                    return;
                }
                const cursor_slice: []const app_mod.Vertex = if (verts_ptr != null and vert_count != 0)
                    verts_ptr.?[0..vert_count]
                else
                    &.{};
                const cursor_row: ?u32 = if (cursor_slice.len != 0) row_start else null;

                // Reserve the legacy metadata copy before publishing the TBS
                // cursor transaction. Paint reads the refcount-protected TBS
                // snapshot, but shader/window metadata still mirrors this
                // buffer while app.mu is held.
                ext_win.surface.cursor_verts.ensureTotalCapacity(app.alloc, cursor_slice.len) catch {
                    failFlush(app);
                    return;
                };
                if (!ext_win.tbs.storeMainCursor(app.alloc, cursor_slice, cursor_row)) {
                    failFlush(app);
                    return;
                }

                if (ext_win.surface.row_mode) {
                    // Row-mode: store cursor verts separately (same pattern as main window).
                    // Mark old cursor row dirty so it gets redrawn to erase the cursor overlay.
                    ext_win.surface.cursor_verts.clearRetainingCapacity();
                    if (cursor_slice.len != 0) {
                        ext_win.surface.cursor_verts.appendSliceAssumeCapacity(cursor_slice);
                        ext_win.surface.last_cursor_row = row_start;
                    } else {
                        ext_win.surface.last_cursor_row = null;
                    }
                } else {
                    // Flat-mode: store the cursor in the dedicated cursor_verts
                    // buffer (replace, not append). Appending into surface.verts
                    // accumulated stale cursor geometry across mode/shape changes
                    // — the old block stayed drawn under the new insert-bar shape.
                    // Keep the legacy surface mirror in sync for lifecycle and
                    // pending-capture bookkeeping; paint reads the committed
                    // independent TBS cursor snapshot.
                    ext_win.surface.cursor_verts.clearRetainingCapacity();
                    if (cursor_slice.len != 0) {
                        ext_win.surface.cursor_verts.appendSliceAssumeCapacity(cursor_slice);
                        ext_win.surface.last_cursor_row = row_start;
                    } else {
                        ext_win.surface.last_cursor_row = null;
                    }
                }
                ext_win.needs_redraw = true;
                // InvalidateRect deferred to onFlushEnd.
                return;
            }

            const size_changed = (ext_win.surface.rows != total_rows or ext_win.surface.cols != total_cols);
            if (ext_win.tbs.is_in_flush) {
                const ws = ext_win.tbs.writeSet();
                const tbs_size_changed = ws.rows != total_rows or
                    ws.cols != total_cols or
                    ws.row_map.items.len != total_rows;
                if (tbs_size_changed) {
                    // Reserve both variable-size structures before dropping
                    // any slot refs. A failed resize cancels the write set and
                    // leaves the committed external frame intact.
                    ws.row_map.ensureTotalCapacity(app.alloc, total_rows) catch {
                        failFlush(app);
                        return;
                    };
                    if (!ext_win.tbs.prepareRowSyncTracking(app.alloc, total_rows)) {
                        failFlush(app);
                        return;
                    }
                    ext_win.tbs.requireFullRowSync();

                    const old_len = ws.row_map.items.len;
                    const new_len: usize = @intCast(total_rows);
                    if (new_len < old_len) {
                        for (ws.row_map.items[new_len..]) |*mapping| {
                            if (mapping.slot != app_mod.SLOT_NONE) {
                                ext_win.tbs.pool.release(app.alloc, mapping.slot);
                                mapping.slot = app_mod.SLOT_NONE;
                            }
                        }
                    }
                    ws.row_map.items.len = new_len;
                    if (new_len > old_len) {
                        for (ws.row_map.items[old_len..]) |*mapping| mapping.* = .{};
                    }
                    ws.rows = total_rows;
                    ws.cols = total_cols;
                }
            }
            ext_win.surface.rows = total_rows;
            ext_win.surface.cols = total_cols;
            ext_win.needs_redraw = true;
            if (size_changed) {
                ext_win.surface.paint_full = true;
                if (ext_win.tbs.is_in_flush) {
                    ext_win.tbs.flush_paint_full = true;
                }
            }

            if (row_count == 1) {
                ext_win.surface.row_mode = true;
                ext_win.surface.verts.clearRetainingCapacity();
                const removed_vert_count = ext_win.surface.truncateRows(app.alloc, total_rows);
                const old_vert_count = if (row_start < ext_win.surface.row_verts.items.len)
                    ext_win.surface.row_verts.items[@intCast(row_start)].verts.items.len
                else
                    0;
                if (!storeSurfaceRowVerts(app.alloc, &ext_win.surface.row_verts, row_start, verts_ptr, vert_count)) {
                    // Row storage OOM: without an abort the core clears this
                    // row's dirty bit at flush end and the stale row persists
                    // until the next unrelated content change (matches the
                    // main-grid path's handling below).
                    failFlush(app);
                    return;
                }
                ext_win.vert_count = ext_win.vert_count -| removed_vert_count -| old_vert_count + vert_count;
                // TBS: COW detach + write to slot, mark dirty.
                if (ext_win.tbs.is_in_flush) {
                    const ws = ext_win.tbs.writeSet();
                    ws.row_mode = true;
                    ws.rows = total_rows;
                    ws.cols = total_cols;
                    // External windows own a separate pool, so they need the
                    // same layout/peak observations as the main grid above.
                    ext_win.tbs.pool.noteLayoutWidth(total_cols);
                    if (!ws.ensureRowStorage(app.alloc, row_start)) {
                        failFlush(app);
                        return;
                    }
                    if (ext_win.tbs.cowDetachRow(app.alloc, row_start)) |slot| {
                        slot.verts.clearRetainingCapacity();
                        if (verts_ptr != null and vert_count != 0) {
                            // OOM after clear: slot left empty.
                            slot.verts.appendSlice(app.alloc, verts_ptr.?[0..vert_count]) catch failFlush(app);
                        }
                        ext_win.tbs.pool.noteRowVerts(vert_count);
                        slot.origin_row = row_start;
                        slot.ver +%= 1;
                    } else {
                        // COW detach failed: write set keeps stale slot content.
                        failFlush(app);
                    }
                    if (row_start < ext_win.tbs.sparse_sync.flush_dirty.bit_length) {
                        if (!ext_win.tbs.markFlushRowChanged(row_start)) failFlush(app);
                    } else if (total_rows > ext_win.tbs.sparse_sync.flush_dirty.bit_length) {
                        if (!ext_win.tbs.prepareRowSyncTracking(app.alloc, total_rows)) {
                            failFlush(app);
                            return;
                        }
                        if (row_start < ext_win.tbs.sparse_sync.flush_dirty.bit_length) {
                            if (!ext_win.tbs.markFlushRowChanged(row_start)) failFlush(app);
                        }
                    }
                }
            } else {
                ext_win.surface.row_mode = false;
                if (row_start == 0) {
                    ext_win.surface.verts.clearRetainingCapacity();
                    ext_win.vert_count = 0;
                }
                if (verts_ptr != null and vert_count != 0) {
                    ext_win.surface.verts.ensureTotalCapacity(app.alloc, ext_win.surface.verts.items.len + vert_count) catch {
                        // OOM possibly after the row_start==0 clear above:
                        // surface (and the untouched TBS write set) would be
                        // committed as a truncated frame.
                        failFlush(app);
                        return;
                    };
                    ext_win.surface.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                    ext_win.vert_count = ext_win.surface.verts.items.len;
                }
                // TBS: write flat verts to write set.
                if (ext_win.tbs.is_in_flush) {
                    const ws = ext_win.tbs.writeSet();
                    ws.row_mode = false;
                    ext_win.tbs.requireFullRowSync();
                    ws.rows = total_rows;
                    ws.cols = total_cols;
                    if (row_start == 0) {
                        ws.flat_verts.clearRetainingCapacity();
                    }
                    if (verts_ptr != null and vert_count != 0) {
                        ws.flat_verts.appendSlice(app.alloc, verts_ptr.?[0..vert_count]) catch failFlush(app);
                    }
                    ext_win.tbs.flush_paint_full = true;
                }
            }

            // Resize popupmenu window if size changed (keep top-left position)
            // Use deferred resize via PostMessage to avoid deadlock with WM_SIZE handler
            if (grid_id == app_mod.POPUPMENU_GRID_ID and size_changed) {
                const cell_w = app.cell_w_px;
                const cell_h = app.rowHeightPx();
                const content_w: c_int = @intCast(total_cols * cell_w);
                const content_h: c_int = @intCast(total_rows * cell_h);

                // Calculate window size (WS_POPUP has no decorations, so client = window)
                var rect: c.RECT = .{ .left = 0, .top = 0, .right = content_w, .bottom = content_h };
                _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
                const window_w: c_int = rect.right - rect.left;
                const window_h: c_int = rect.bottom - rect.top;

                if (log_verbose) applog.appLog("[win] on_vertices_row popupmenu resize pending: content=({d},{d}) window=({d},{d})\n", .{ content_w, content_h, window_w, window_h });

                // Store pending resize info and post message to do the actual resize outside of callback
                ext_win.needs_window_resize = true;
                ext_win.pending_window_w = window_w;
                ext_win.pending_window_h = window_h;
                ext_win.needs_renderer_resize = true;

                // Post message to main window to trigger resize asynchronously (outside of lock)
                if (app.hwnd) |main_hwnd| {
                    if (c.PostMessageW(main_hwnd, app_mod.WM_APP_RESIZE_POPUPMENU, @bitCast(app_mod.POPUPMENU_GRID_ID), 0) == 0) {
                        // PostMessage failed, reset flag to avoid stale state
                        ext_win.needs_window_resize = false;
                        if (log_verbose) applog.appLog("[win] on_vertices_row popupmenu PostMessageW failed\n", .{});
                    }
                } else {
                    // No main hwnd, reset flag
                    ext_win.needs_window_resize = false;
                }
            }

            // InvalidateRect deferred to onFlushEnd for coalescing.

            if (log_verbose) applog.appLog(
                "[win] on_vertices_row external grid_id={d} updated ext_win vert_count={d}\n",
                .{ grid_id, ext_win.vert_count },
            );
        } else {
            // Window doesn't exist yet - store in pending_external_verts
            // Find or create pending entry for this grid_id
            var found_idx: ?usize = null;
            for (app.pending_external_verts.items, 0..) |*pv, i| {
                if (pv.grid_id == grid_id) {
                    found_idx = i;
                    break;
                }
            }

            // Handle cursor update for pending entries. Store the cursor in the
            // dedicated cursor_verts buffer (same as the live ext_win path),
            // NOT baked into row/flat content. Baking left a stale cursor block
            // in the row that was never erased once the window existed: later
            // cursor-only updates do not re-send the row's content, so the old
            // block kept being drawn under the new shape-aware overlay cursor.
            if (is_cursor_update) {
                if (found_idx) |idx| {
                    const pv = &app.pending_external_verts.items[idx];
                    if (verts_ptr != null and vert_count != 0) {
                        // Reserve BEFORE clearing so an OOM keeps the old
                        // cursor capture intact (the pending entry is the
                        // ONLY copy — the window does not exist yet).
                        pv.surface.cursor_verts.ensureTotalCapacity(app.alloc, vert_count) catch {
                            failFlush(app);
                            return;
                        };
                        pv.surface.cursor_verts.clearRetainingCapacity();
                        pv.surface.cursor_verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                        pv.surface.last_cursor_row = row_start;
                    } else {
                        pv.surface.cursor_verts.clearRetainingCapacity();
                        pv.surface.last_cursor_row = null;
                    }
                    pv.flush_generation = flush_generation;
                }
                // No pending entry yet means no content rows either; cursor alone is not useful.
                return;
            }

            if (found_idx) |idx| {
                // Update existing pending entry. rows/cols are committed
                // AFTER the content update succeeds — the keep-old failure
                // paths below must not pair the old capture with new dims.
                const pv = &app.pending_external_verts.items[idx];
                if (row_count == 1) {
                    pv.surface.row_mode = true;
                    pv.surface.verts.clearRetainingCapacity();
                    _ = pv.surface.truncateRows(app.alloc, total_rows);
                    if (!storeSurfaceRowVerts(app.alloc, &pv.surface.row_verts, row_start, verts_ptr, vert_count)) {
                        // OOM mid-frame: rows updated earlier this flush mix
                        // with older rows — the entry is no longer a
                        // consistent frame, and onFlushEnd's TBS cancel does
                        // NOT roll pending buffers back. Discard the entry so
                        // window creation shows nothing rather than a mixed
                        // frame; the abort keeps core dirty and the next
                        // flush rebuilds the pending capture from scratch.
                        var dropped = app.pending_external_verts.swapRemove(idx);
                        dropped.deinit(app.alloc);
                        failFlush(app);
                        return;
                    }
                } else {
                    pv.surface.row_mode = false;
                    if (verts_ptr != null and vert_count != 0) {
                        // Reserve BEFORE the row_start==0 clear so an OOM on
                        // a frame-start update keeps the old capture intact.
                        const base_len: usize = if (row_start == 0) 0 else pv.surface.verts.items.len;
                        pv.surface.verts.ensureTotalCapacity(app.alloc, base_len + vert_count) catch {
                            if (row_start == 0) {
                                // Nothing overwritten yet: keep the old frame.
                                failFlush(app);
                                return;
                            }
                            // Mid-frame append failed: the entry holds a
                            // truncated new frame — discard it (see the
                            // row-mode branch above for the rationale).
                            var dropped = app.pending_external_verts.swapRemove(idx);
                            dropped.deinit(app.alloc);
                            failFlush(app);
                            return;
                        };
                        if (row_start == 0) pv.surface.verts.clearRetainingCapacity();
                        pv.surface.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                    } else if (row_start == 0) {
                        pv.surface.verts.clearRetainingCapacity();
                    }
                }
                pv.surface.rows = total_rows;
                pv.surface.cols = total_cols;
                pv.flush_generation = flush_generation;
                pv.metrics_gen = app.shared_metrics_gen;
            } else {
                // Create new pending entry
                var new_pv = app_mod.PendingExternalVertices{
                    .grid_id = grid_id,
                    .flush_generation = flush_generation,
                    .metrics_gen = app.shared_metrics_gen,
                    .surface = .{ .rows = total_rows, .cols = total_cols },
                };
                if (row_count == 1) {
                    new_pv.surface.row_mode = true;
                    if (!storeSurfaceRowVerts(app.alloc, &new_pv.surface.row_verts, row_start, verts_ptr, vert_count)) {
                        // Free the partially built entry (row storage may
                        // have been resized before the failure).
                        new_pv.deinit(app.alloc);
                        failFlush(app);
                        return;
                    }
                } else if (verts_ptr != null and vert_count != 0) {
                    new_pv.surface.verts.ensureTotalCapacity(app.alloc, vert_count) catch {
                        new_pv.deinit(app.alloc);
                        failFlush(app);
                        return;
                    };
                    new_pv.surface.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                }
                app.pending_external_verts.append(app.alloc, new_pv) catch {
                    // The freshly built pending entry is dropped — release
                    // its buffers and abort so the core re-sends.
                    var dropped = new_pv;
                    dropped.deinit(app.alloc);
                    failFlush(app);
                    return;
                };
            }

            if (log_verbose) applog.appLog(
                "[win] on_vertices_row external grid_id={d} stored in pending_external_verts\n",
                .{grid_id},
            );
        }
        return; // Don't process as global grid
    }

    // A cursor-only row callback does not mutate the main row set.
    if ((flags & app_mod.VERT_UPDATE_MAIN) == 0) return;
    if (!ensureMainSurfaceFlush(app)) return;

    const end_row_hint: u32 = row_start + row_count;
    if (end_row_hint > app.row_mode_max_row_end) {
        app.row_mode_max_row_end = end_row_hint;
        if (log_verbose) applog.appLog(
            "[win] on_vertices_row max_row_end={d} rows={d} row_verts_len={d}\n",
            .{ app.row_mode_max_row_end, app.surface.rows, app.surface.row_verts.items.len },
        );
    }

    // Rows and columns are both part of the published layout. A width-only
    // zero-cell transition has no row payload to overwrite stale contents.
    if (total_rows != app.surface.rows or total_cols != app.surface.cols) {
        const old_rows = app.surface.rows;
        const old_cols = app.surface.cols;
        app.surface.rows = total_rows;
        app.surface.cols = total_cols;
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        app.row_layout_gen +%= 1;
        if (total_rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(total_rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        // Clear old row vertex data to prevent ghost rendering from stale vertices.
        for (app.surface.row_verts.items) |*rv| {
            rv.verts.clearRetainingCapacity();
            rv.gen +%= 1;
        }
        if (old_rows != total_rows) {
            app.maybeShrinkRowStorage(total_rows);
        }
        if (log_verbose) applog.appLog(
            "[win] on_vertices_row resize old={d}x{d} new={d}x{d} row_valid={d}\n",
            .{ old_rows, old_cols, total_rows, total_cols, app.row_valid_count },
        );
    }

    // Pooled row slots keep their payload backing across release, so a narrower
    // layout would otherwise pin the pool at the widest grid ever displayed.
    // Publish the width on any change (a width-only resize never enters the row
    // branch above); the rows below rebuild the peak this layout is measured
    // against, and slots retire as they are released over the next few flushes,
    // as each set rotates through beginFlush.
    app.tbs.pool.noteLayoutWidth(total_cols);

    // TBS: update write set rows/cols and resize flush_dirty on dimension change.
    if (app.tbs.is_in_flush) {
        const write_set = app.tbs.writeSet();
        write_set.row_mode = true;
        if ((flags & 2) == 0) write_set.metrics_gen = app.shared_metrics_gen;
        if (total_rows != write_set.rows) {
            // Reserve both variable-size structures before releasing the old
            // slot map. On OOM the write set remains a valid shallow copy and
            // onFlushEnd cancels it instead of publishing a partial resize.
            write_set.row_map.ensureTotalCapacity(app.alloc, total_rows) catch {
                failFlush(app);
                return;
            };
            if (!app.tbs.prepareRowSyncTracking(app.alloc, total_rows)) {
                failFlush(app);
                return;
            }
            app.tbs.requireFullRowSync();

            write_set.releaseAllSlots(app.alloc, &app.tbs.pool);
            write_set.row_map.items.len = total_rows;
            for (write_set.row_map.items) |*m| {
                m.slot = app_mod.SLOT_NONE;
            }
            write_set.rows = total_rows;
            write_set.cols = total_cols;
        } else {
            // A width-only grid resize keeps the row-map length but changes
            // the vertex/layout contract. commitFlush observes this scalar
            // difference and applies a structural synchronization barrier.
            write_set.cols = total_cols;
        }
        if (layout_only) {
            app.tbs.requireFullRowSync();
            write_set.releaseAllSlots(app.alloc, &app.tbs.pool);
            for (write_set.row_map.items) |*mapping| {
                mapping.slot = app_mod.SLOT_NONE;
            }
        }
    }

    // Note: We don't set content_rows_dirty here anymore.
    // The WM_PAINT handler will determine if it's cursor-only by checking
    // if all dirty rows are covered by cursor rects from paint_rects_snapshot.

    // Mark row-mode and remember which rows are dirty.
    // When we enter row-mode for the first time, request a one-time full seed.
    if (!app.surface.row_mode) {
        app.surface.row_mode = true;
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        if (app.surface.rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(app.surface.rows), false) catch {};
            app.row_valid.unsetAll();
        }
    } else {
        app.surface.row_mode = true;
    }

    if (layout_only) {
        app.row_valid_count = 0;
        if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.flush_needs_invalidate = true;
        return;
    }

    // Clamp to [0, app.surface.rows) to avoid index==rows.
    const max_rows: u32 = app.surface.rows;

    if (max_rows != 0 and row_start >= max_rows) {
        return;
    }

    if (row_count == 1) {
        // Single-row path (normal case): store vertices for this row.
        const row: u32 = row_start;

        // Extra safety: if rows is known, do not store beyond it.
        if (max_rows != 0 and row >= max_rows) {
            return;
        }

        if (!storeSurfaceRowVerts(app.alloc, &app.surface.row_verts, row, verts_ptr, vert_count)) {
            // Row storage OOM: without an abort the core clears this row's
            // dirty bit at flush end and the stale row persists until the
            // next unrelated content change.
            failFlush(app);
            return;
        }

        // TBS: COW detach + write to slot, mark flush_dirty.
        if (app.tbs.is_in_flush) {
            const ws = app.tbs.writeSet();
            ws.row_mode = true;
            if (!ws.ensureRowStorage(app.alloc, row)) {
                failFlush(app);
                return;
            }
            if (app.tbs.cowDetachRow(app.alloc, row)) |slot| {
                slot.verts.clearRetainingCapacity();
                if (verts_ptr != null and vert_count != 0) {
                    // Slot left empty after clear on failure: abort so the
                    // core re-sends this row instead of committing a blank.
                    slot.verts.appendSlice(app.alloc, verts_ptr.?[0..vert_count]) catch failFlush(app);
                }
                app.tbs.pool.noteRowVerts(vert_count);
                slot.origin_row = row;
                slot.ver +%= 1;
            } else {
                // COW detach failed (OOM): the write set still references
                // the previous slot content for this row — committing it
                // would publish a stale row as if it were current.
                failFlush(app);
            }
            if (row < app.tbs.sparse_sync.flush_dirty.bit_length) {
                if (!app.tbs.markFlushRowChanged(row)) failFlush(app);
            } else if (ws.rows > app.tbs.sparse_sync.flush_dirty.bit_length) {
                // The slot was already rebound above, so the write set holds the
                // new vertices while nothing records the row as changed —
                // commitFlush would drop it behind the same bounds test and the
                // paint would skip it, leaving the previous pixels on screen.
                // Grow the tracking bitmap and mark, mirroring the external-grid
                // path in onVerticesRow.
                if (!app.tbs.prepareRowSyncTracking(app.alloc, ws.rows)) {
                    failFlush(app);
                    return;
                }
                if (row < app.tbs.sparse_sync.flush_dirty.bit_length) {
                    if (!app.tbs.markFlushRowChanged(row)) failFlush(app);
                } else {
                    failFlush(app);
                }
            } else {
                failFlush(app);
            }
        }
    } else if (row_count > 1) {
        // Multi-row path: the vertex array covers multiple rows but we cannot
        // split it per-row (no per-row vertex boundaries in the API).
        // Do NOT store the combined vertices — they would render garbled at
        // row_start while other rows show stale content.
        // Instead, keep existing row vertices intact and request a full re-seed
        // so the core resends each row individually.
        //
        // NOTE: This relies on Core's flush loop responding to need_full_seed
        // by iterating per-row with row_count=1 (see src/core/flush.zig).
        // If a future Core change sends row_count>1 even for re-seed responses,
        // the API contract must be extended with per-row vertex counts.
        if (log_verbose) applog.appLog(
            "[win] on_vertices_row row_count>1 ({d}) row_start={d} -> requesting re-seed\n",
            .{ row_count, row_start },
        );
        app.need_full_seed.store(true, .seq_cst);
    }

    // Mark the row valid only when we have exact single-row vertex data.
    // Use total_rows (content rows from core) for seed completion, not
    // app.surface.rows (global grid rows) which includes tabline/statusline
    // rows that never receive on_vertices_row callbacks.
    if (total_rows != 0 and row_count == 1) {
        const idx: usize = @intCast(row_start);
        if (idx < app.row_valid.bit_length and !app.row_valid.isSet(idx)) {
            app.row_valid.set(idx);
            app.row_valid_count += 1;
        }
        if (app.row_valid_count >= total_rows) {
            if (log_verbose) applog.appLog("[win] on_vertices_row seed_ready rows={d}\n", .{total_rows});
        }
    }

    // InvalidateRect deferred to onFlushEnd for coalescing.
    app.flush_needs_invalidate = true;
}

/// Core on_main_row_scroll callback — shift row slot mappings for scroll fast path.
/// macOS equivalent: applyMainRowScrollRaw (MetalTerminalRenderer.swift).
/// Called only when core's checkScrollFastPath returns eligible.
/// When scroll_fast_path_blocked (e.g. touched-row overflow in
/// Grid.recordScrollTouchedRow), this is NOT called and both frontends
/// fall back to full dirty-row regeneration via on_vertices_row.
pub fn onMainRowScroll(
    ctx: ?*anyopaque,
    row_start: u32,
    row_end: u32,
    col_start: u32,
    col_end: u32,
    rows_delta: i32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());

    if (applog.isEnabled()) applog.appLog(
        "[scroll_diag] onMainRowScroll row_start={d} row_end={d} rows_delta={d} total_rows={d} total_cols={d}\n",
        .{ row_start, row_end, rows_delta, total_rows, total_cols },
    );

    if (rows_delta == 0 or row_end <= row_start) return;
    if (col_start != 0 or col_end != total_cols) return;
    if (!ensureMainSurfaceFlush(app)) return;

    if (total_rows != app.surface.rows) {
        app.surface.rows = total_rows;
        app.surface.cols = total_cols;
        if (total_rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(total_rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        app.row_valid_count = 0;
        app.row_layout_gen +%= 1;
    } else {
        app.surface.rows = total_rows;
        app.surface.cols = total_cols;
    }

    if (total_rows == 0) return;
    if (row_start >= total_rows or row_end > total_rows) return;

    const region_height: u32 = row_end - row_start;
    const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
    if (abs_rows == 0 or abs_rows >= region_height) return;

    app.surface.row_mode = true;
    if (app.row_valid.bit_length < total_rows) {
        app.row_valid.resize(app.alloc, @intCast(total_rows), false) catch {};
    }

    // Reserve EVERY storage this scroll needs (surface row storage, TBS
    // write-set row storage, TBS dirty bitmap size) BEFORE performing any
    // mutation below. swapAndShiftRows physically shifts app.surface's row
    // data in place — if a LATER reservation (TBS write-set) failed after
    // that shift already ran, aborting then would leave the surface
    // shifted while the core (which only advances state on a successful
    // commit) retries the same scroll delta again, causing a second,
    // corrupting shift on already-shifted data. Checking every reservation
    // first makes the mutation phase below infallible/all-or-nothing.
    const last_row: u32 = row_end - 1;
    app.ensureRowStorage(last_row);
    var ws_last_row: u32 = 0;
    if (app.tbs.is_in_flush) {
        ws_last_row = row_end - 1;
        if (!app.tbs.writeSet().ensureRowStorage(app.alloc, ws_last_row)) {
            failFlush(app);
            return;
        }
        // Always validate/prepare the complete sparse-sync storage before
        // mutating the legacy surface. A previous OOM may have grown only
        // flush_dirty while leaving a later list/bitset undersized; using the
        // dirty bit length alone as a readiness proxy would then allow the
        // legacy shift to run before row registration fails.
        if (!app.tbs.prepareRowSyncTracking(app.alloc, total_rows)) {
            failFlush(app);
            return;
        }
    }
    const surface_ok = last_row < app.surface.row_verts.items.len;
    const ws_ok = !app.tbs.is_in_flush or
        (ws_last_row < app.tbs.writeSet().row_map.items.len and app.tbs.sparse_sync.isReady(total_rows));
    // row_valid.resize (above and at this function's top, on a rows change)
    // silently ignores OOM too — swapAndShiftRows below indexes it with
    // &app.row_valid at rows within [row_start, row_end) (already verified
    // < total_rows), which would panic (Debug/ReleaseSafe bounds check) or
    // corrupt memory (ReleaseFast) if bit_length never actually grew to
    // total_rows.
    const row_valid_ok = app.row_valid.bit_length >= total_rows;
    if (!surface_ok or !ws_ok or !row_valid_ok) {
        // Row storage OOM (surface, TBS, and/or row_valid side): without an
        // abort, the core still expects this scroll's non-vacated rows to
        // have been shifted in place (it only marks the vacated band
        // dirty) — bailing out silently here leaves row_verts un-shifted
        // while the core's row indexing has already moved on, a permanent
        // mismatch. Match storeSurfaceRowVerts' OOM handling above.
        failFlush(app);
        return;
    }

    swapAndShiftRows(app.surface.row_verts.items, row_start, row_end, rows_delta, &app.row_valid);

    recomputeRowValidCount(app);

    if (row_end > app.row_mode_max_row_end) {
        app.row_mode_max_row_end = row_end;
    }

    // TBS: remap slot indices in write set (no physical data move).
    // Storage for both the row map and the dirty bitmap was already
    // reserved and verified above — infallible from here.
    if (app.tbs.is_in_flush) {
        const ws = app.tbs.writeSet();
        ws.row_mode = true;
        ws.rows = total_rows;
        ws.cols = total_cols;
        remapRowSlots(ws.row_map.items, &app.tbs.pool, app.alloc, row_start, row_end, rows_delta);
        var changed_row = row_start;
        while (changed_row < row_end) : (changed_row += 1) {
            if (!app.tbs.markFlushMappingChanged(changed_row)) {
                failFlush(app);
                return;
            }
        }
        // Mark only vacated rows dirty in flush_dirty.
        // Non-vacated rows are shifted by DXGI Present1 scroll
        // (pScrollRect/pScrollOffset) at present time.
        if (rows_delta > 0) {
            var sr: u32 = row_end - abs_rows;
            while (sr < row_end) : (sr += 1) {
                if (sr < app.tbs.sparse_sync.flush_dirty.bit_length) {
                    if (!app.tbs.markFlushDirtyRow(sr)) failFlush(app);
                }
            }
        } else {
            var sr: u32 = row_start;
            while (sr < row_start + abs_rows) : (sr += 1) {
                if (sr < app.tbs.sparse_sync.flush_dirty.bit_length) {
                    if (!app.tbs.markFlushDirtyRow(sr)) failFlush(app);
                }
            }
        }
    }

    // Accumulate scroll state on TBS (flush-local, merged at commitFlush).
    // This ensures scroll state is atomically visible with the corresponding committed set.
    const row_h: i32 = @intCast(app.rowHeightPx());
    const scroll_top_px: i32 = @as(i32, @intCast(row_start)) * row_h;
    const scroll_bot_px: i32 = @as(i32, @intCast(row_end)) * row_h;
    // rows_delta > 0 means content scrolls up (j-key), so pixels shift up (negative dy).
    // rows_delta < 0 means content scrolls down (k-key), so pixels shift down (positive dy).
    const delta_px: i32 = -rows_delta * row_h;
    // right is set to 0 here; WM_PAINT fills it with the actual client width.
    const new_rect = c.RECT{
        .left = 0,
        .top = scroll_top_px,
        .right = 0,
        .bottom = scroll_bot_px,
    };

    if (app.tbs.flush_scroll_rect) |existing| {
        // Multiple scrolls in same flush: accumulate if same region.
        if (existing.left == new_rect.left and existing.right == new_rect.right and
            existing.top == new_rect.top and existing.bottom == new_rect.bottom)
        {
            app.tbs.flush_scroll_dy_px += delta_px;
            app.tbs.flush_vb_shift += rows_delta;
        } else {
            // Different region: invalidate scroll optimization (full redraw).
            app.tbs.flush_scroll_rect = null;
            app.tbs.flush_scroll_dy_px = 0;
            app.tbs.flush_vb_shift = 0;
            app.tbs.flush_paint_full = true;
            // Re-mark all rows dirty as fallback.
            var sr: u32 = row_start;
            while (sr < row_end) : (sr += 1) {
                if (sr < app.tbs.sparse_sync.flush_dirty.bit_length) {
                    if (!app.tbs.markFlushDirtyRow(sr)) failFlush(app);
                }
            }
        }
    } else {
        app.tbs.flush_scroll_rect = new_rect;
        app.tbs.flush_scroll_dy_px = delta_px;
        app.tbs.flush_vb_shift = rows_delta;
        app.tbs.flush_scroll_row_start = row_start;
        app.tbs.flush_scroll_row_end = row_end;
    }

    // InvalidateRect deferred to onFlushEnd for coalescing.
    app.flush_needs_invalidate = true;
}

/// Shift row vertex buffers for external grid scroll.
/// Same row-swap + Y-shift logic as onMainRowScroll, but operates on
/// ext_win.surface.row_verts and has no row_valid/dirty_rows tracking.
pub fn onGridRowScroll(
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_end: u32,
    col_start: u32,
    col_end: u32,
    rows_delta: i32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());

    if (rows_delta == 0 or row_end <= row_start) return;
    if (col_start != 0 or col_end != total_cols) return;

    // A pre-window/replacement capture is the frontend's only copy of rows the
    // core omits on its scroll fast path. Shift it before the vacated rows are
    // overwritten by the row callbacks later in this flush.
    for (app.pending_external_verts.items) |*pv| {
        if (pv.grid_id != grid_id) continue;
        if (!pv.surface.row_mode or
            total_rows == 0 or
            row_start >= total_rows or
            row_end > total_rows or
            pv.surface.row_verts.items.len < total_rows)
        {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }
        for (pv.surface.row_verts.items[0..total_rows]) |row| {
            if (row.gen == 0) {
                // A partial capture has no source for rows omitted by the
                // scroll fast path. Retry with a full core regeneration.
                core.zonvie_core_force_resend_locked(app.corep);
                failFlush(app);
                return;
            }
        }

        const region_height: u32 = row_end - row_start;
        const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
        if (abs_rows == 0 or abs_rows >= region_height) {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }

        const last_row = row_end - 1;
        if (!ensureRowStorageGeneric(app.alloc, &pv.surface.row_verts, last_row)) {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }
        pv.surface.rows = total_rows;
        pv.surface.cols = total_cols;
        swapAndShiftRows(pv.surface.row_verts.items, row_start, row_end, rows_delta, null);
        if (pv.surface.last_cursor_row) |cr| {
            if (cr >= row_start and cr < row_end) {
                pv.surface.cursor_verts.clearRetainingCapacity();
                pv.surface.last_cursor_row = null;
            }
        }
        pv.flush_generation = app.core_flush_generation.load(.acquire);
        return;
    }

    const ext_win = app.external_windows.get(grid_id) orelse {
        // There is no seed to shift. Abort this partial-scroll transaction
        // and make the retry regenerate every row instead of retaining only
        // the vacated band.
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    };
    if (!ext_win.tbs.is_in_flush) {
        if (!app.core_flush_active.load(.acquire) or !ext_win.tbs.beginFlush(app.alloc)) {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }
    }
    if (ext_win.is_pending_close or
        !ext_win.surface.row_mode or
        ext_win.surface.row_verts.items.len < total_rows)
    {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }
    for (ext_win.surface.row_verts.items[0..total_rows]) |row| {
        if (row.gen == 0) {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }
    }

    ext_win.surface.rows = total_rows;
    ext_win.surface.cols = total_cols;

    if (total_rows == 0 or row_start >= total_rows or row_end > total_rows) {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    const region_height: u32 = row_end - row_start;
    const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
    if (abs_rows == 0 or abs_rows >= region_height) {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    // Reserve EVERY storage this scroll needs (external surface row
    // storage, TBS write-set row storage, TBS dirty bitmap size) BEFORE any
    // mutation below — same reserve-before-mutate rationale as
    // onMainRowScroll above: swapAndShiftRows physically shifts
    // ext_win.surface's row data in place, and aborting AFTER that shift
    // (if a later TBS-side reservation failed) would leave it shifted
    // while the core retries the same scroll delta, causing a second,
    // corrupting shift on already-shifted data.
    const last_row: u32 = row_end - 1;
    const ws_needs_reserve = ext_win.tbs.is_in_flush and ext_win.tbs.writeSet().row_mode;
    if (ws_needs_reserve) {
        if (!ext_win.tbs.writeSet().ensureRowStorage(app.alloc, last_row)) {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }
        // prepareRowSyncTracking covers every list/bitset. This call is
        // intentionally unconditional: after a partial allocation failure,
        // flush_dirty alone may already have the requested length.
        if (!ext_win.tbs.prepareRowSyncTracking(app.alloc, total_rows)) {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }
    }
    const surface_ok = ensureRowStorageGeneric(app.alloc, &ext_win.surface.row_verts, last_row);
    const ws_ok = !ws_needs_reserve or
        (last_row < ext_win.tbs.writeSet().row_map.items.len and ext_win.tbs.sparse_sync.isReady(total_rows));
    if (!surface_ok or !ws_ok) {
        // Row storage OOM (surface and/or TBS side): same rationale as
        // onMainRowScroll's identical check above — without an abort,
        // non-vacated rows are never shifted while the core's row indexing
        // has already moved on.
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    const clear_committed_cursor = if (ext_win.surface.last_cursor_row) |cr|
        cr >= row_start and cr < row_end
    else
        false;
    if (clear_committed_cursor and !ext_win.tbs.storeMainCursor(app.alloc, &.{}, null)) {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    swapAndShiftRows(ext_win.surface.row_verts.items, row_start, row_end, rows_delta, null);

    // Update last_cursor_row to follow the scroll shift.
    // If the cursor row moved into the vacated region, it was cleared.
    // Cursor verts are stored separately, so just clear them (core will re-send).
    if (ext_win.surface.last_cursor_row) |cr| {
        if (cr >= row_start and cr < row_end) {
            ext_win.surface.cursor_verts.clearRetainingCapacity();
            ext_win.surface.last_cursor_row = null;
        }
    }

    // TBS: remap slot indices in write set (no physical data move).
    // Storage for both the row map and the dirty bitmap was already
    // reserved and verified above — infallible from here.
    if (ext_win.tbs.is_in_flush) {
        const ws = ext_win.tbs.writeSet();
        if (ws.row_mode) {
            ws.rows = total_rows;
            ws.cols = total_cols;
            remapRowSlots(ws.row_map.items, &ext_win.tbs.pool, app.alloc, row_start, row_end, rows_delta);
            var changed_row = row_start;
            while (changed_row < row_end) : (changed_row += 1) {
                if (!ext_win.tbs.markFlushMappingChanged(changed_row)) {
                    core.zonvie_core_force_resend_locked(app.corep);
                    failFlush(app);
                    return;
                }
            }
            // Mark only vacated rows dirty (same as onMainRowScroll).
            // back_tex is persistent, so non-vacated rows retain correct content.
            if (rows_delta > 0) {
                var sr: u32 = row_end - abs_rows;
                while (sr < row_end) : (sr += 1) {
                    if (sr < ext_win.tbs.sparse_sync.flush_dirty.bit_length) {
                        if (!ext_win.tbs.markFlushDirtyRow(sr)) failFlush(app);
                    }
                }
            } else {
                var sr: u32 = row_start;
                while (sr < row_start + abs_rows) : (sr += 1) {
                    if (sr < ext_win.tbs.sparse_sync.flush_dirty.bit_length) {
                        if (!ext_win.tbs.markFlushDirtyRow(sr)) failFlush(app);
                    }
                }
            }
        }
    }

    // Accumulate scroll state on TBS (flush-local, merged at commitFlush).
    const row_h: i32 = @intCast(app.rowHeightPx());
    const scroll_top_px: i32 = @as(i32, @intCast(row_start)) * row_h;
    const scroll_bot_px: i32 = @as(i32, @intCast(row_end)) * row_h;
    const delta_px: i32 = -rows_delta * row_h;
    const new_rect = c.RECT{ .left = 0, .top = scroll_top_px, .right = 0, .bottom = scroll_bot_px };

    if (ext_win.tbs.flush_scroll_rect) |existing| {
        if (existing.left == new_rect.left and existing.right == new_rect.right and
            existing.top == new_rect.top and existing.bottom == new_rect.bottom)
        {
            ext_win.tbs.flush_scroll_dy_px += delta_px;
            ext_win.tbs.flush_vb_shift += rows_delta;
        } else {
            // Different region: invalidate scroll optimization.
            ext_win.tbs.flush_scroll_rect = null;
            ext_win.tbs.flush_scroll_dy_px = 0;
            ext_win.tbs.flush_vb_shift = 0;
            ext_win.tbs.flush_paint_full = true;
        }
    } else {
        ext_win.tbs.flush_scroll_rect = new_rect;
        ext_win.tbs.flush_scroll_dy_px = delta_px;
        ext_win.tbs.flush_vb_shift = rows_delta;
        ext_win.tbs.flush_scroll_row_start = row_start;
        ext_win.tbs.flush_scroll_row_end = row_end;
    }

    ext_win.recomputeVertCount();
    ext_win.needs_redraw = true;
    // InvalidateRect deferred to onFlushEnd for coalescing.
}

/// Called at the start of each flush cycle (core thread, on_flush_begin callback).
/// Opens the global transaction; each surface write set is prepared lazily by
/// its first vertex/scroll mutation so no-op and cursor-only main flushes do
/// not clone the complete row map.
pub fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
    const ctxp = ctx orelse return;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return;
    const app: *App = @ptrFromInt(ctx_bits);
    _ = app.core_flush_generation.fetchAdd(1, .acq_rel);

    if (!preparePendingAtlasCreate(app)) return;

    // Consume any pending DPI-change glyph-cache invalidation (set from
    // WM_DPICHANGED on the UI thread — see MED-1). This is the core thread,
    // as required by zonvie_core_invalidate_glyph_cache's header contract.
    if (app.pending_core_glyph_invalidate.swap(false, .acq_rel)) {
        if (app.corep) |cp| app_mod.zonvie_core_invalidate_glyph_cache(cp);
    }

    // Serialize publication with new external HWND creation. Existing
    // windows and the main row set join lazily from their first mutation.
    // This is the global core-flush transaction flag, not an indication that
    // the main O(rows) TBS bracket has already been opened.
    app.mu.lockUncancelable(core.clock.io());
    app.log_flush_row_callbacks = 0;
    app.log_flush_vertex_count = 0;
    app.core_flush_active.store(true, .release);
    app.mu.unlock(core.clock.io());
}

/// Called once per flush (from core thread via on_flush_end callback).
/// Posts a single WM_APP_UPDATE_SCROLLBAR with atomic coalescing to avoid
/// flooding the message queue when flushes are frequent.
pub fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
    const ctxp = ctx orelse return;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return;
    const app: *App = @ptrFromInt(ctx_bits);

    // Resolve the external transaction before releasing app.mu to any
    // UI-thread pending-seed consumer. The active flag, failure decision, and
    // every external commit/cancel form one publication point: after unlock a
    // new seed either sees a committed surface or writes the standalone
    // committed set, never a write set that is about to be cancelled.
    const atlas_corrupted = if (app.corep) |corep| app_mod.zonvie_core_flush_had_atlas_corruption(corep) else false;
    const core_aborted = if (app.corep) |corep| app_mod.zonvie_core_flush_was_aborted(corep) else false;
    const retryable = if (app.corep) |corep| app_mod.zonvie_core_flush_is_retryable(corep) else false;
    app.mu.lockUncancelable(core.clock.io());
    const failed = app.flush_failed or atlas_corrupted or core_aborted;
    app.flush_failed = false;
    if (failed) {
        app.flush_needs_invalidate = false;
        const failed_generation = app.core_flush_generation.load(.acquire);
        var ext_cancel_it = app.external_windows.iterator();
        while (ext_cancel_it.next()) |entry| {
            entry.value_ptr.*.tbs.cancelFlush();
        }
        // Pending captures are CPU-only and can outlive their originating
        // flush while window creation is queued. Drop exactly the captures
        // mutated by this failed generation before active is cleared; a late
        // creator can then never publish cancelled UVs or a partial frame as
        // a standalone committed seed. Older successful captures remain valid.
        var pending_idx: usize = 0;
        while (pending_idx < app.pending_external_verts.items.len) {
            if (app.pending_external_verts.items[pending_idx].flush_generation == failed_generation) {
                var dropped = app.pending_external_verts.swapRemove(pending_idx);
                for (dropped.surface.row_verts.items) |row| {
                    std.debug.assert(row.vb == null);
                }
                dropped.surface.deinitCpuState(app.alloc);
            } else {
                pending_idx += 1;
            }
        }
        // A seed may have joined this transaction before a callback reported
        // failure. Its pending copy has already been consumed, so make the
        // retry reconstruct every surface even when that external grid was
        // otherwise clean.
        if (retryable) core.zonvie_core_force_resend_locked(app.corep);
    } else {
        var ext_commit_it = app.external_windows.iterator();
        while (ext_commit_it.next()) |entry| {
            entry.value_ptr.*.tbs.commitFlush(app.alloc);
        }
    }
    const log_row_callbacks = app.log_flush_row_callbacks;
    const log_vertex_count = app.log_flush_vertex_count;
    app.core_flush_active.store(false, .release);
    app.mu.unlock(core.clock.io());

    // The main TBS has no UI-thread pending-seed path, so it can be finalized
    // outside app.mu without reopening the external publication race above.
    if (failed) {
        app.tbs.cancelFlush();
    } else {
        app.tbs.commitFlush(app.alloc);
    }
    // A failed flush after onAtlasCreate must keep paint frozen: the CPU/GPU
    // atlas is already a new generation while the committed TBS still holds
    // old UVs. The retry's successful commit releases this same transaction.
    const atlas_reset_committed = if (!failed) app.endAtlasResetTransaction() else false;

    // Always re-evaluate message deadlines, including when this flush is
    // cancelled below. A msg_show OOM keeps its pending deadline armed and
    // must not lose the only UI-thread timer driver with the TBS commit.
    if (app.msg_throttle_arm_posted.cmpxchgStrong(false, true, .release, .monotonic) == null) {
        if (app.hwnd) |hwnd| {
            if (c.PostMessageW(hwnd, app_mod.WM_APP_MSG_THROTTLE_ARM, 0, 0) == 0) {
                app.msg_throttle_arm_posted.store(false, .release);
            }
        } else {
            app.msg_throttle_arm_posted.store(false, .release);
        }
    }

    // Emit one aggregate after releasing app.mu. Per-row inspection and output
    // are verbose-only in onVerticesRow.
    if (applog.isEnabled()) {
        applog.appLog("[perf] vertices_rows callbacks={d} vertices={d}\n", .{ log_row_callbacks, log_vertex_count });
    }

    // Report DWrite rasterization stats for this flush (only when logging enabled)
    if (applog.isEnabled()) {
        const raster_count = app.rasterize_call_count.swap(0, .monotonic);
        if (raster_count > 0) {
            const raster_total = app.rasterize_total_ns.swap(0, .monotonic);
            const raster_max = app.rasterize_max_ns.swap(0, .monotonic);
            applog.appLog("[perf] flush_rasterize calls={d} total_us={d} max_us={d}\n", .{
                raster_count,
                @as(u64, @divTrunc(raster_total, 1000)),
                @as(u64, @divTrunc(raster_max, 1000)),
            });
        }
    }

    if (failed) {
        // failFlush() (frontend callback failure) already arms this itself,
        // but core-side abort/atlas-corruption paths do not. Re-posting is
        // harmless and guarantees the full resend scheduled above has a
        // driver even when no further Neovim redraw arrives.
        if (retryable) requestFlushRetry(app);
        return;
    }

    // A success covers every failure published before this callback. A later
    // failure increments the epoch again and cannot be erased by this event.
    app_mod.g_flush_retry_success_epoch.store(
        app_mod.g_flush_retry_failure_epoch.load(.acquire),
        .release,
    );

    // First flush triggers window show: keep the window hidden until a
    // flush actually committed content. Gated on the flush_failed check
    // above (which returns early) so a backpressure/OOM-aborted first
    // flush no longer shows a blank/incomplete window with window_shown
    // left permanently true — the window now only appears once real
    // content has actually been committed.
    if (!app.window_shown.load(.acquire)) {
        app.window_shown.store(true, .release);
        if (app.hwnd) |hwnd| {
            _ = c.PostMessageW(hwnd, app_mod.WM_APP_SHOW_WINDOW, 0, 0);
        }
    }

    // Warm the optional bloom pipeline on the UI thread before the paint
    // invalidations below can produce a glow-enabled WM_PAINT. The claimed
    // slot stays set until a disabled flush because the renderer keeps the
    // shaders for the current enabled period.
    if (app.corep) |corep| {
        if (core.zonvie_core_get_glow_enabled(corep)) {
            if (app.glow_prepare_posted.cmpxchgStrong(false, true, .release, .monotonic) == null) {
                if (app.hwnd) |hwnd| {
                    if (c.PostMessageW(hwnd, app_mod.WM_APP_PREPARE_GLOW, 0, 0) == 0) {
                        app.glow_prepare_posted.store(false, .release);
                    }
                } else {
                    app.glow_prepare_posted.store(false, .release);
                }
            }
        } else {
            app.glow_prepare_posted.store(false, .release);
        }
    }

    // Coalesce: only post if not already pending (atomic CAS: false -> true)
    if (app.scrollbar_update_pending.cmpxchgStrong(false, true, .release, .monotonic) == null) {
        // CAS succeeded: we own the pending slot
        if (app.hwnd) |hwnd| {
            if (c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_SCROLLBAR, 0, 0) == 0) {
                // PostMessage failed: reset pending to avoid permanent stall
                app.scrollbar_update_pending.store(false, .release);
            }
        } else {
            // No hwnd yet: reset pending
            app.scrollbar_update_pending.store(false, .release);
        }
    }

    // Coalesce all per-callback dirty state into a single InvalidateRect per
    // window.  Individual vertex callbacks (onVerticesRow, onVerticesPartial,
    // onMainRowScroll, onGridRowScroll) no longer call InvalidateRect directly;
    // they only accumulate dirty state (dirty_rows, paint_full, needs_redraw,
    // flush_needs_invalidate).  This prevents mid-flush WM_PAINT from drawing
    // incomplete frames, and skips InvalidateRect entirely for flushes that
    // carry no visual changes (e.g. msg_showcmd-only flushes).
    app.mu.lockUncancelable(core.clock.io());
    const main_dirty = app.flush_needs_invalidate or atlas_reset_committed;
    app.flush_needs_invalidate = false;
    const main_hwnd = if (main_dirty) app.hwnd else null;
    // Collect dirty external window HWNDs under lock.
    // Bounded array avoids allocation on the flush hot path.
    var ext_hwnds: [64]c.HWND = undefined;
    var ext_hwnd_count: usize = 0;
    var it = app.external_windows.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.needs_redraw or atlas_reset_committed) {
            if (entry.value_ptr.*.hwnd) |ext_hwnd| {
                if (ext_hwnd_count < ext_hwnds.len) {
                    ext_hwnds[ext_hwnd_count] = ext_hwnd;
                    ext_hwnd_count += 1;
                } else {
                    // Overflow (>64 dirty windows): invalidate in place
                    // instead of silently dropping. With a stable HashMap
                    // iteration order the same windows would otherwise be
                    // starved every flush. InvalidateRect only marks the
                    // update region (no synchronous message dispatch), so
                    // calling it under app.mu is safe.
                    _ = c.InvalidateRect(ext_hwnd, null, 0);
                }
            }
        }
    }
    app.mu.unlock(core.clock.io());

    // InvalidateRect outside of lock — triggers a single WM_PAINT per window.
    if (main_hwnd) |hwnd| {
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
    }
    for (ext_hwnds[0..ext_hwnd_count]) |ext_hwnd| {
        _ = c.InvalidateRect(ext_hwnd, null, 0);
    }
}

// =========================================================================
// Phase 2: Core-managed atlas callbacks
// =========================================================================

pub fn onRasterizeGlyph(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *app_mod.GlyphBitmap) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    // App.deinit cannot clear corep until this core callback thread has
    // joined, so no second app.mu acquisition is needed here.
    const corep = app.corep;
    if (atlasForCoreCallback(app)) |a| {
        if (applog.isEnabled()) {
            const t0 = core.clock.nowNs();
            a.rasterizeGlyphOnly(scalar, style_flags, corep, out_bitmap) catch return 0;
            const elapsed_ns: u64 = @intCast(@max(0, core.clock.nowNs() - t0));
            _ = app.rasterize_call_count.fetchAdd(1, .monotonic);
            _ = app.rasterize_total_ns.fetchAdd(elapsed_ns, .monotonic);
            var cur_max = app.rasterize_max_ns.load(.monotonic);
            while (elapsed_ns > cur_max) {
                if (app.rasterize_max_ns.cmpxchgWeak(cur_max, elapsed_ns, .monotonic, .monotonic)) |actual| {
                    cur_max = actual;
                } else break;
            }
        } else {
            a.rasterizeGlyphOnly(scalar, style_flags, corep, out_bitmap) catch return 0;
        }
        return 1;
    }
    return 0;
}

pub fn onAtlasUpload(ctx: ?*anyopaque, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const app_mod.GlyphBitmap) callconv(.c) void {
    const ctxp = ctx orelse return;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return;
    const app: *App = @ptrFromInt(ctx_bits);

    // A prior on_atlas_create could not acquire exclusive atlas admission or
    // recreate the CPU atlas. Do not write new-generation pixels into the old
    // atlas while the void callback ABI is waiting for a timer-driven retry.
    if (app.atlas_create_retry_pending.load(.acquire)) {
        abortAtlasFlush(app, "atlas upload arrived before pending create succeeded");
        return;
    }

    if (atlasForCoreCallback(app)) |a| {
        a.uploadAtlasRegion(dest_x, dest_y, width, height, bitmap) catch {
            // The CPU mirror (atlas_cpu) was already written; the only
            // failure point is the dirty-rect enqueue (OOM). The core caches
            // the GlyphEntry as valid after this callback, so without
            // recovery the glyph would stay blank until an atlas reset.
            // Recover from the mirror: schedule a full-atlas upload for the
            // main window and bump the reset generation so every external
            // window also re-uploads the full atlas from atlas_cpu.
            app.atlas_full_upload_needed.store(true, .release);
            a.mu.lockUncancelable(core.clock.io());
            a.atlas_reset_generation +%= 1;
            a.mu.unlock(core.clock.io());
        };
    }
}

pub fn onAtlasCreate(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
    const ctxp = ctx orelse return;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return;
    const app: *App = @ptrFromInt(ctx_bits);

    rememberAtlasCreateRetry(app, atlas_w, atlas_h);
    const a = atlasForCoreCallback(app) orelse {
        abortAtlasFlush(app, "atlas renderer unavailable during create");
        return;
    };

    // recreateAtlasTexture clears every CPU texel. Exclude a paint using the
    // previous committed UV generation first; onFlushEnd releases this gate
    // only after a successful matching TBS commit.
    const admission = app.beginAtlasResetTransaction();
    if (admission != .acquired) {
        abortAtlasFlush(app, if (admission == .busy) "atlas reader active during create" else "shutdown during atlas create");
        return;
    }
    if (!recreateAtlasCpu(a, atlas_w, atlas_h)) {
        // The CPU atlas may already be a new generation even though the
        // legacy render-target rebuild failed. Opening the gate here would
        // pair old committed UVs with that new atlas.
        abortAtlasFlush(app, "atlas recreation failed");
        return;
    }

    app.atlas_create_retry_pending.store(false, .release);
}

// =========================================================================
// Text-run shaping callbacks (ligature + ASCII fast path support)
// =========================================================================

pub fn onShapeTextRun(
    ctx: ?*anyopaque,
    scalars: [*]const u32,
    scalar_count: usize,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_clusters: [*]u32,
    out_x_advance: [*]i32,
    out_x_offset: [*]i32,
    out_y_offset: [*]i32,
    out_cap: usize,
) callconv(.c) usize {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    if (atlasForCoreCallback(app)) |a| {
        return a.shapeTextRunDWrite(
            scalars,
            scalar_count,
            style_flags,
            out_glyph_ids,
            out_clusters,
            out_x_advance,
            out_x_offset,
            out_y_offset,
            out_cap,
        );
    }
    return 0;
}

pub fn onRasterizeGlyphById(
    ctx: ?*anyopaque,
    glyph_id: u32,
    style_flags: u32,
    out_bitmap: *app_mod.GlyphBitmap,
) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    if (atlasForCoreCallback(app)) |a| {
        if (applog.isEnabled()) {
            const t0 = core.clock.nowNs();
            a.rasterizeGlyphByIdDWrite(glyph_id, style_flags, out_bitmap) catch return 0;
            const elapsed_ns: u64 = @intCast(@max(0, core.clock.nowNs() - t0));
            _ = app.rasterize_call_count.fetchAdd(1, .monotonic);
            _ = app.rasterize_total_ns.fetchAdd(elapsed_ns, .monotonic);
            var cur_max = app.rasterize_max_ns.load(.monotonic);
            while (elapsed_ns > cur_max) {
                if (app.rasterize_max_ns.cmpxchgWeak(cur_max, elapsed_ns, .monotonic, .monotonic)) |actual| {
                    cur_max = actual;
                } else break;
            }
        } else {
            a.rasterizeGlyphByIdDWrite(glyph_id, style_flags, out_bitmap) catch return 0;
        }
        return 1;
    }
    return 0;
}

pub fn onGetAsciiTable(
    ctx: ?*anyopaque,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_x_advances: [*]i32,
    out_lig_triggers: [*]u8,
) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    if (atlasForCoreCallback(app)) |a| {
        return if (a.getAsciiTableDWrite(style_flags, out_glyph_ids, out_x_advances, out_lig_triggers)) 1 else 0;
    }
    return 0;
}

// =========================================================================
// Logging callback
// =========================================================================

pub fn onLog(ctx: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) void {
    _ = ctx;
    if (!applog.isEnabled()) return;
    if (bytes == null or len == 0) return;

    const s: []const u8 = @as([*]const u8, @ptrCast(bytes))[0..len];
    // Prefix is optional; keep empty for now.
    applog.appLogBytes("", s);
}

// =========================================================================
// Font / linespace callbacks
// =========================================================================

pub fn onGuiFont(ctx: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    // `:set guifont=*` is a picker request: defer to the UI thread to open the
    // native ChooseFontW dialog instead of applying a font. This callback runs
    // on the core thread; ChooseFontW is
    // modal and must run on the UI thread, so post and return. The chosen font
    // is written back to nvim as a concrete "Family:hN", which returns here as
    // a normal payload and applies through the path below.
    if (bytes) |b| {
        if (len == 1 and b[0] == '*') {
            // Defer to the UI thread. wParam carries whether the first frame
            // has been shown: only then do we pop the dialog (so nvim's initial
            // guifont broadcast at attach, which may already be "*", does not
            // open it at startup). The handler always rewrites guifont back to
            // the current font so it is never left as "*" (a repeated
            // `:set guifont=*` would otherwise be a no-op, and a leftover "*"
            // on a reused nvim would re-pop / get stuck).
            const shown: c.WPARAM = if (app.window_shown.load(.acquire)) 1 else 0;
            if (app.hwnd) |hwnd| {
                _ = c.PostMessageW(hwnd, app_mod.WM_APP_OPEN_FONT_PICKER, shown, 0);
            }
            return;
        }
    }

    // Font priority:
    //   1. config.font.family/size when explicitly set in config.toml
    //   2. guifont payload from nvim
    //   3. config.font defaults
    //   4. OS default (Consolas)
    //
    // Nvim sends its own default guifont ("Cascadia Code,Cascadia Mono,...")
    // on Windows at ui_attach time even when the user hasn't set one. Letting
    // that default override an explicit config.toml [font] entry surprises
    // users. If the user wants :set guifont=... to control the font, they
    // should leave [font] out of config.toml.
    const os_default_font = "Consolas";
    const default_font_pt: f32 = 18.0;

    // Get config font (fallback to OS default if empty)
    const config_font = if (app.config.font.family.len > 0) app.config.font.family else os_default_font;
    const config_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else default_font_pt;
    const family_explicit = app.config.font.family_explicit;
    const size_explicit = app.config.font.size_explicit;

    // The payload may contain multiple newline-separated candidates
    // (guifont fallback list).  Try each in order; use the first font
    // that loads successfully via setFontUtf8WithFeatures.
    var name: []const u8 = config_font;
    var pt: f32 = config_pt;
    var features_str: []const u8 = "";

    if (bytes == null or len == 0) {
        if (applog.isEnabled()) applog.appLog("onGuiFont: empty payload, using config font", .{});
    }

    var new_metrics: ?struct { w_px: u32, h_px: u32 } = null;
    var font_changed = false;

    if (atlasForCoreCallback(app)) |a| {
        const prev_font_generation = a.fontGenerationValue();
        var applied_name: []const u8 = config_font;
        var applied_pt: f32 = config_pt;
        var font_set = false;

        // Arena must outlive applied_name: the skip_guifont branch assigns
        // resolved.name (arena-backed) into applied_name, which is read by
        // appLog at the end of this block.
        var arena = std.heap.ArenaAllocator.init(app.alloc);
        defer arena.deinit();

        // If the user explicitly set font.family in config.toml, skip
        // nvim's guifont payload and walk the config's own candidate
        // list (parsed from the raw guifont-syntax string in
        // app.config.font.family). Same fallback rule as the nvim
        // payload path below.
        //
        // Exception: a font the user just picked in ChooseFontW arrives as a
        // guifont broadcast and must override config precedence. Consume the
        // one-shot flag so that pick applies.
        const picker_selection = app.font_picker_selection_pending.swap(false, .acq_rel);
        const skip_guifont = family_explicit and !picker_selection;
        // A picked font overrides both family and size precedence, so its size
        // is honored even when config.toml [font] size is explicit.
        const eff_size_explicit = size_explicit and !picker_selection;
        // Base weight/slant for the picked font (regular unless the user picked
        // a Bold/Italic face). Only meaningful for the picker payload branch.
        const pick_bold = picker_selection and app.picked_font_bold.load(.acquire);
        const pick_italic = picker_selection and app.picked_font_italic.load(.acquire);
        if (skip_guifont) {
            const aa = arena.allocator();
            const cands = core.config.splitFontFamilyList(aa, app.config.font.family) catch &.{};
            for (cands) |cand_str| {
                const resolved = core.redraw_handler.parseGuiFontCandidate(aa, cand_str) catch continue;
                if (resolved.name.len == 0) continue;
                const parsed_pt: f32 = @floatCast(resolved.point_size);
                const cand_pt: f32 = if (size_explicit or parsed_pt <= 0) config_pt else parsed_pt;

                const try_result = a.setFontUtf8WithFeatures(resolved.name, cand_pt, "");
                if (try_result) |_| {
                    applied_name = resolved.name;
                    applied_pt = cand_pt;
                    name = resolved.name;
                    pt = cand_pt;
                    features_str = "";
                    font_set = true;
                    if (applog.isEnabled()) applog.appLog("onGuiFont: selected from config '{s}' pt={d}", .{ resolved.name, cand_pt });
                    break;
                } else |e| {
                    if (applog.isEnabled()) applog.appLog("onGuiFont: skipped config '{s}' pt={d}: {any}", .{ resolved.name, cand_pt, e });
                }
            }
        }

        if (!skip_guifont and bytes != null and len != 0) {
            const s = bytes.?[0..len];
            // Iterate newline-separated candidates
            var line_it = std.mem.splitScalar(u8, s, '\n');
            while (line_it.next()) |entry| {
                if (entry.len == 0) continue;

                var cand_name: []const u8 = "";
                var cand_pt: f32 = config_pt;
                var cand_features: []const u8 = "";

                if (std.mem.indexOfScalar(u8, entry, '\t')) |tab1| {
                    cand_name = entry[0..tab1];
                    const after_name = entry[tab1 + 1 ..];
                    if (std.mem.indexOfScalar(u8, after_name, '\t')) |tab2| {
                        const size_str = after_name[0..tab2];
                        cand_features = after_name[tab2 + 1 ..];
                        const parsed_pt = std.fmt.parseFloat(f32, size_str) catch 0;
                        cand_pt = if (eff_size_explicit or parsed_pt <= 0) config_pt else parsed_pt;
                    } else {
                        const parsed_pt = std.fmt.parseFloat(f32, after_name) catch 0;
                        cand_pt = if (eff_size_explicit or parsed_pt <= 0) config_pt else parsed_pt;
                    }
                } else {
                    continue; // no tab => skip invalid entry
                }

                if (cand_name.len == 0) continue;

                // Try loading this candidate (with the picked weight/slant when
                // this payload came from the font picker).
                const try_result = a.setFontUtf8WithStyle(cand_name, cand_pt, cand_features, pick_bold, pick_italic);
                if (try_result) |_| {
                    applied_name = cand_name;
                    applied_pt = cand_pt;
                    name = cand_name;
                    pt = cand_pt;
                    features_str = cand_features;
                    font_set = true;
                    if (applog.isEnabled()) applog.appLog("onGuiFont: selected '{s}' pt={d}", .{ cand_name, cand_pt });
                    break;
                } else |e| {
                    if (applog.isEnabled()) applog.appLog("onGuiFont: skipped '{s}' pt={d}: {any}", .{ cand_name, cand_pt, e });
                }
            }
        }

        // If no candidate succeeded, fall back to config font -> OS default
        if (!font_set) {
            const try_config = a.setFontUtf8WithFeatures(config_font, config_pt, "");
            if (try_config) |_| {
                applied_name = config_font;
                applied_pt = config_pt;
                if (applog.isEnabled()) applog.appLog("onGuiFont: fallback config font '{s}' pt={d}", .{ config_font, config_pt });
            } else |_| {
                const try_os = a.setFontUtf8WithFeatures(os_default_font, config_pt, "");
                if (try_os) |_| {
                    applied_name = os_default_font;
                    applied_pt = config_pt;
                    if (applog.isEnabled()) applog.appLog("onGuiFont: fallback OS default '{s}' pt={d}", .{ os_default_font, config_pt });
                } else |e3| {
                    if (applog.isEnabled()) applog.appLog("onGuiFont: OS default failed: {any}", .{e3});
                }
            }
        }

        const metrics = a.cellMetrics();
        new_metrics = .{ .w_px = metrics.w_px, .h_px = metrics.h_px };
        const new_font_generation = a.fontGenerationValue();
        font_changed = new_font_generation != prev_font_generation;
        if (applog.isEnabled()) {
            applog.appLog("onGuiFont: applied name='{s}' pt={d} cell=({d},{d})", .{ applied_name, applied_pt, metrics.w_px, metrics.h_px });
            if (font_changed) {
                applog.appLog("onGuiFont: font changed (gen {}->{}), invalidating core glyph cache\n", .{ prev_font_generation, new_font_generation });
            }
        }
    } else {
        if (applog.isEnabled()) applog.appLog("onGuiFont: atlas is null", .{});
    }

    app.mu.lockUncancelable(core.clock.io());
    if (new_metrics) |metrics| {
        if (font_changed or app.cell_w_px != metrics.w_px or app.cell_h_px != metrics.h_px) {
            app.row_layout_gen +%= 1;
            app.shared_metrics_gen +%= 1;
        }
        app.cell_w_px = metrics.w_px;
        app.cell_h_px = metrics.h_px;
    }
    const corep_to_invalidate = if (font_changed) app.corep else null;

    const hwnd = app.hwnd;
    if (hwnd) |h| {
        app_mod.updateRowsColsFromClientForce(h, app);
    }

    // Clear saved cmdline position so it re-centers with the new font size
    app.cmdline_saved_x = null;
    app.cmdline_saved_y = null;

    // Calculate pending resize for all external windows (same as onLineSpace)
    const cell_w = app.cell_w_px;
    const cell_h = app.rowHeightPx();
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const ext_win = entry.value_ptr.*;

        if (ext_win.is_pending_close) continue;

        const rows = ext_win.surface.rows;
        const cols = ext_win.surface.cols;

        var content_w: c_int = @intCast(cols * cell_w);
        var content_h: c_int = @intCast(rows * cell_h);

        const is_cmdline = (grid_id == app_mod.CMDLINE_GRID_ID);
        const is_msg_show = (grid_id == app_mod.MESSAGE_GRID_ID);
        const is_msg_history = (grid_id == app_mod.MSG_HISTORY_GRID_ID);

        if (is_cmdline) {
            const cmdline_icon_total_width: u32 = app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT;
            const cmdline_total_padding: u32 = app_mod.CMDLINE_PADDING * 2;
            content_w += @as(c_int, @intCast(cmdline_icon_total_width + cmdline_total_padding));
            content_h += @as(c_int, @intCast(cmdline_total_padding));
        } else if (is_msg_show or is_msg_history) {
            const scaled_msg_pad = app.scalePx(@as(c_int, app_mod.MSG_PADDING)) * 2;
            content_w += scaled_msg_pad;
            content_h += scaled_msg_pad;
        }

        // Use this window's ACTUAL current style/exstyle (WS_POPUP for
        // cmdline/popupmenu/msg_show/msg_history, WS_OVERLAPPEDWINDOW for
        // regular float/split external windows) instead of assuming
        // WS_POPUP unconditionally — WS_OVERLAPPEDWINDOW has caption+border
        // non-client area that WS_POPUP does not, and using the wrong style
        // here silently shrinks the computed client rect on every font/
        // linespace change for normal (non-decorated-surface) windows.
        // GetWindowLongW (not the Ptr variant) + @bitCast matches the
        // existing GWL_STYLE read idiom at window.zig:201-202 — GWL_STYLE
        // is a 32-bit value, and for WS_POPUP windows (bit 31 set) the
        // LONG_PTR-returning GetWindowLongPtrW would sign-extend to a
        // negative isize, making @intCast to u32/DWORD panic.
        const dwStyle: c.DWORD = @bitCast(c.GetWindowLongW(ext_win.hwnd, c.GWL_STYLE));
        const dwExStyle: c.DWORD = @bitCast(c.GetWindowLongW(ext_win.hwnd, c.GWL_EXSTYLE));
        var rect: c.RECT = .{ .left = 0, .top = 0, .right = content_w, .bottom = content_h };
        _ = c.AdjustWindowRectEx(&rect, dwStyle, 0, dwExStyle);

        ext_win.pending_window_w = rect.right - rect.left;
        ext_win.pending_window_h = rect.bottom - rect.top;
        ext_win.needs_window_resize = true;
        ext_win.needs_renderer_resize = true;

        if (applog.isEnabled()) applog.appLog("onGuiFont: queued ext_win resize grid_id={d} to ({d},{d})\n", .{ grid_id, ext_win.pending_window_w, ext_win.pending_window_h });

        if (hwnd) |mh| {
            _ = c.PostMessageW(mh, app_mod.WM_APP_RESIZE_POPUPMENU, @bitCast(grid_id), 0);
        }
    }

    // Invalidation flags must be co-set with the cell metrics update above (still
    // under app.mu): font change shifted cell_w_px/cell_h_px, so any WM_PAINT that
    // observes the new metrics must also see back_tex_valid=false and the seed
    // flags. Setting them only after InvalidateRect — as the previous code did —
    // left a window in which the UI thread could snapshot new metrics together
    // with stale back_tex_valid=true and preserve a geometrically wrong back_tex.
    app.surface.paint_full = true;
    app.paint_rects.clearRetainingCapacity();
    app.need_full_seed.store(true, .seq_cst);
    app.seed_pending = true;
    app.seed_clear_pending = true;
    app.back_tex_valid = false;
    app.last_cursor_rect_px = null;

    app.mu.unlock(core.clock.io());

    if (corep_to_invalidate) |cp| {
        app_mod.zonvie_core_invalidate_glyph_cache(cp);
    }
    if (hwnd) |h| {
        app_mod.updateLayoutToCore(h, app);
        _ = c.InvalidateRect(h, null, 0);

        // Snap the main window's client rect to a multiple of the new
        // cell size. Without this, drawable_px % cell_px leaves a strip
        // along the bottom/right edge that the cell-aligned NDC viewport
        // never covers, so it shows whatever the renderer last cleared
        // there. Posted (not sent) because we are on the RPC thread with
        // grid_mu held; the UI handler does the SetWindowPos and lets
        // WM_SIZE drive the rest of the resize pipeline.
        _ = c.PostMessageW(h, app_mod.WM_APP_SNAP_MAIN_WINDOW, 0, 0);
    }
}

/// Neovim resized the global grid itself (`:set columns=` / `:set lines=`).
/// Runs on the core thread with grid_mu held, so the actual SetWindowPos is
/// deferred to the UI thread via WM_APP_RESIZE_TO_GRID.
pub fn onMainGridSize(ctx: ?*anyopaque, rows: u32, cols: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog(
        "[win] onMainGridSize: rows={d} cols={d}\n",
        .{ rows, cols },
    );
    if (app.hwnd) |h| {
        _ = c.PostMessageW(h, app_mod.WM_APP_RESIZE_TO_GRID, rows, @intCast(cols));
    }
}

pub fn onLineSpace(ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    // Negative values are kept: Neovim uses them to tighten rows under a font
    // that reserves too much room between lines. rowHeightPx() floors the
    // result so the layout never divides the client area by zero.
    const v: i32 = linespace_px;

    // Defer external window resizes via PostMessage to avoid deadlock.
    // SetWindowPos sends WM_SIZE synchronously, and WM_SIZE handler calls
    // zonvie_core_try_resize_grid which needs core locks held by the flush path.
    app.mu.lockUncancelable(core.clock.io());
    const changed = app.linespace_px != v;
    app.linespace_px = v;
    if (applog.isEnabled()) applog.appLog(
        "[win] onLineSpace: linespace_px={d} v={d} cell_h_px={d} -> row_h={d}\n",
        .{ linespace_px, v, app.cell_h_px, app.rowHeightPx() },
    );
    if (changed) {
        app.row_layout_gen +%= 1;
        app.shared_metrics_gen +%= 1;
    }
    const hwnd = app.hwnd;
    if (hwnd) |h| {
        app_mod.updateRowsColsFromClientForce(h, app);
    }

    // Calculate pending resize for all external windows
    const cell_w = app.cell_w_px;
    const cell_h = app.rowHeightPx();
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const ext_win = entry.value_ptr.*;

        if (ext_win.is_pending_close) continue;

        const rows = ext_win.surface.rows;
        const cols = ext_win.surface.cols;

        var content_w: c_int = @intCast(cols * cell_w);
        var content_h: c_int = @intCast(rows * cell_h);

        const is_cmdline = (grid_id == app_mod.CMDLINE_GRID_ID);
        const is_msg_show = (grid_id == app_mod.MESSAGE_GRID_ID);
        const is_msg_history = (grid_id == app_mod.MSG_HISTORY_GRID_ID);

        if (is_cmdline) {
            const cmdline_icon_total_width: u32 = app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT;
            const cmdline_total_padding: u32 = app_mod.CMDLINE_PADDING * 2;
            content_w += @as(c_int, @intCast(cmdline_icon_total_width + cmdline_total_padding));
            content_h += @as(c_int, @intCast(cmdline_total_padding));
        } else if (is_msg_show or is_msg_history) {
            const scaled_msg_pad = app.scalePx(@as(c_int, app_mod.MSG_PADDING)) * 2;
            content_w += scaled_msg_pad;
            content_h += scaled_msg_pad;
        }

        // See onGuiFont for why this must use the window's actual style
        // (via GetWindowLongW + @bitCast, not GetWindowLongPtrW + @intCast)
        // instead of hardcoding WS_POPUP.
        const dwStyle: c.DWORD = @bitCast(c.GetWindowLongW(ext_win.hwnd, c.GWL_STYLE));
        const dwExStyle: c.DWORD = @bitCast(c.GetWindowLongW(ext_win.hwnd, c.GWL_EXSTYLE));
        var rect: c.RECT = .{ .left = 0, .top = 0, .right = content_w, .bottom = content_h };
        _ = c.AdjustWindowRectEx(&rect, dwStyle, 0, dwExStyle);

        ext_win.pending_window_w = rect.right - rect.left;
        ext_win.pending_window_h = rect.bottom - rect.top;
        ext_win.needs_window_resize = true;
        ext_win.needs_renderer_resize = true;

        if (applog.isEnabled()) applog.appLog("[win] onLineSpace: queued ext_win resize grid_id={d} to ({d},{d})\n", .{ grid_id, ext_win.pending_window_w, ext_win.pending_window_h });

        // PostMessageW does not block, so it's safe to call while holding the lock.
        if (hwnd) |mh| {
            _ = c.PostMessageW(mh, app_mod.WM_APP_RESIZE_POPUPMENU, @bitCast(grid_id), 0);
        }
    }

    // Co-set invalidation flags with the linespace update above (still under
    // app.mu) for the same race-avoidance reason as onGuiFont: a WM_PAINT that
    // observes the new linespace must also see back_tex_valid=false and seed
    // flags, never an interleaved snapshot of new metrics + stale validity.
    app.surface.paint_full = true;
    app.paint_rects.clearRetainingCapacity();
    app.need_full_seed.store(true, .seq_cst);
    app.seed_pending = true;
    app.seed_clear_pending = true;
    app.back_tex_valid = false;

    app.mu.unlock(core.clock.io());

    if (hwnd) |h| {
        app_mod.updateLayoutToCore(h, app);
        _ = c.InvalidateRect(h, null, 0);

        // Same client-rect snap as onGuiFont — linespace changes the row
        // height, so the same drawable_h % cell_h remainder problem applies.
        _ = c.PostMessageW(h, app_mod.WM_APP_SNAP_MAIN_WINDOW, 0, 0);
    }
}

// =========================================================================
// Exit / IME / quit / title callbacks
// =========================================================================

pub fn onRestart(ctx: ?*anyopaque, addr_ptr: ?[*]const u8, addr_len: usize) callconv(.c) void {
    _ = ctx;
    if (!applog.isEnabled()) return;
    if (addr_ptr) |p| {
        applog.appLog("[win] on_restart: reconnecting to listen_addr={s}\n", .{p[0..addr_len]});
    } else {
        applog.appLog("[win] on_restart: (no listen_addr)\n", .{});
    }
}

/// Receive the `connect` UI event (`:connect <addr>`). Same flicker-free
/// reconnect as restart; the only difference is that the previous server
/// keeps running headless instead of dying. The core handles the actual
/// hot-swap; this callback is informational only.
pub fn onConnect(ctx: ?*anyopaque, addr_ptr: ?[*]const u8, addr_len: usize) callconv(.c) void {
    _ = ctx;
    if (!applog.isEnabled()) return;
    if (addr_ptr) |p| {
        applog.appLog("[win] on_connect: hot-swap to server_addr={s}\n", .{p[0..addr_len]});
    } else {
        applog.appLog("[win] on_connect: (no server_addr)\n", .{});
    }
}

pub fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_exit: code={d}\n", .{exit_code});
    // Mark Neovim as exited (to skip requestQuit in WM_CLOSE)
    app.neovim_exited.store(true, .release);
    // Store exit code globally (Nvy style - returned from main instead of ExitProcess)
    app_mod.g_exit_code.store(@intCast(@as(u32, @bitCast(exit_code)) & 0xFF), .seq_cst);
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
    }
}

pub fn onIMEOff(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.hwnd) |hwnd| {
        // Post message to main thread (IME APIs must be called from the window's thread)
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_IME_OFF, 0, 0);
    }
}

pub fn onQuitRequested(ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] onQuitRequested: has_unsaved={d}\n", .{has_unsaved});

    // Post message to main thread to avoid blocking RPC thread
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_QUIT_REQUESTED, @intCast(has_unsaved), 0);
    }
}

pub fn onDefaultColorsSet(ctx: ?*anyopaque, fg: u32, bg: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog("[win] onDefaultColorsSet: fg=0x{x:0>8} bg=0x{x:0>8}\n", .{ fg, bg });

    // 0xFFFFFFFF means "not set" — only update the color that is valid
    app.mu.lockUncancelable(core.clock.io());
    if (bg != 0xFFFFFFFF) app.colorscheme_bg = bg;
    if (fg != 0xFFFFFFFF) app.colorscheme_fg = fg;
    // Push the bg into the d3d11 renderer so its ClearRenderTargetView
    // call uses the colorscheme bg instead of the historical hardcoded
    // black. This is what makes the bottom/right remainder strip
    // (drawable_px % cell_px) blend with the rest of the grid instead
    // of showing as a black band.
    if (bg != 0xFFFFFFFF) {
        if (app.renderer) |*r| r.setDefaultBgColor(bg);
    }
    app.mu.unlock(core.clock.io());

    // Invalidate tabline/sidebar to repaint with new colors, and
    // update cached highlight group bg colors for external window clear color.
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_TABLINE_INVALIDATE, 0, 0);
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CMDLINE_COLORS, 0, 0);
    }
}

pub fn onSetTitle(ctx: ?*anyopaque, title_ptr: ?[*]const u8, title_len: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog("[win] onSetTitle: len={d}\n", .{title_len});

    if (title_ptr == null or title_len == 0) return;

    const title = title_ptr.?[0..title_len];
    if (applog.isEnabled()) applog.appLog("[win] onSetTitle: {s}\n", .{title});

    // Defer SetWindowTextW to UI thread via PostMessage to avoid deadlock.
    // SetWindowTextW from a non-owning thread is an implicit cross-thread
    // SendMessage(WM_SETTEXT), which blocks with grid_mu held.
    const hwnd = app.hwnd orelse return;

    // Truncate UTF-8 input to fit the pending_title buffer (511 UTF-16 units + null).
    // If the full title doesn't fit, progressively shorten the UTF-8 slice at
    // codepoint boundaries until it fits, so we always get a partial update
    // rather than silently dropping the title.
    app.mu.lockUncancelable(core.clock.io());
    var src = title;
    var wide_len: usize = 0;
    while (src.len > 0) {
        wide_len = std.unicode.utf8ToUtf16Le(&app.pending_title, src) catch {
            // Shorten src by one codepoint from the end and retry.
            var trim = src.len - 1;
            while (trim > 0 and (src[trim] & 0xC0) == 0x80) trim -= 1;
            src = src[0..trim];
            continue;
        };
        break;
    }
    const clamped_len = @min(wide_len, app.pending_title.len - 1);
    app.pending_title[clamped_len] = 0; // null terminate
    app.pending_title_len = clamped_len;
    app.mu.unlock(core.clock.io());

    if (clamped_len > 0) {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_SET_TITLE, 0, 0);
    }
}

// =========================================================================
// ext_cmdline callbacks
// =========================================================================

pub fn onCmdlineShow(
    ctx: ?*anyopaque,
    _: ?[*]const app_mod.CmdlineChunk, // content
    _: usize, // content_count
    _: u32, // pos
    firstc: u8,
    _: ?[*]const u8, // prompt
    _: usize, // prompt_len
    _: u32, // indent
    _: u32, // level
    _: u32, // prompt_hl_id
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cmdline_show: firstc={c}({d})\n", .{ firstc, firstc });

    app.mu.lockUncancelable(core.clock.io());
    app.cmdline_firstc = firstc;
    app.mu.unlock(core.clock.io());

    // Request UI thread to update cmdline colors from core highlights.
    // We can't call zonvie_core_get_hl_by_name here (callback context) because
    // core holds an internal lock during callbacks, causing deadlock.
    // Post message to UI thread which will call updateCmdlineColors().
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CMDLINE_COLORS, 0, 0);
    }
}

pub fn onCmdlineHide(ctx: ?*anyopaque, _: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cmdline_hide\n", .{});

    app.mu.lockUncancelable(core.clock.io());
    app.cmdline_firstc = 0;
    app.mu.unlock(core.clock.io());
}

// =========================================================================
// ext_popupmenu callbacks
// =========================================================================

pub fn onPopupmenuShow(
    ctx: ?*anyopaque,
    _: ?*const anyopaque, // items (unused — grid rendering handles display)
    _: usize, // item_count
    _: i32, // selected
    _: i32, // row
    _: i32, // col
    _: i64, // grid_id
    colors: ?*const core.PopupmenuColors,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (colors) |clrs| {
        app.mu.lockUncancelable(core.clock.io());
        app.popupmenu_bg_rgb = clrs.pmenu_bg;
        app.mu.unlock(core.clock.io());
        if (applog.isEnabled()) applog.appLog("[win] on_popupmenu_show: pmenu_bg=0x{x:0>6}\n", .{clrs.pmenu_bg});
    }
}

pub fn onPopupmenuHide(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.mu.lockUncancelable(core.clock.io());
    app.popupmenu_bg_rgb = 0xFFFFFFFF;
    app.mu.unlock(core.clock.io());
    if (applog.isEnabled()) applog.appLog("[win] on_popupmenu_hide\n", .{});
}

// =========================================================================
// Clipboard and SSH auth callbacks
// =========================================================================

pub fn onClipboardGet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    out_buf: [*]u8,
    out_len: *usize,
    max_len: usize,
) callconv(.c) c_int {
    _ = register;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_get: called\n", .{});

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else {
        out_len.* = 0;
        return 1;
    };

    const hwnd = app.hwnd orelse {
        out_len.* = 0;
        return 1;
    };

    // Create event if not exists (manual-reset, initially non-signaled)
    if (app.clipboard_event == null) {
        app.clipboard_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
        if (app.clipboard_event == null) {
            if (applog.isEnabled()) applog.appLog("[win] clipboard_get: CreateEventW failed\n", .{});
            out_len.* = 0;
            return 1;
        }
    }

    // Reset event
    _ = c.ResetEvent(app.clipboard_event);

    // Post message to UI thread
    if (c.PostMessageW(hwnd, app_mod.WM_APP_CLIPBOARD_GET, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get: PostMessageW failed\n", .{});
        out_len.* = 0;
        return 1;
    }

    // Wait for UI thread to complete (timeout: 5 seconds)
    const wait_result = c.WaitForSingleObject(app.clipboard_event, 5000);
    if (wait_result != c.WAIT_OBJECT_0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get: WaitForSingleObject failed or timeout\n", .{});
        out_len.* = 0;
        return 1;
    }

    // Copy what fits, but report the full size: the core retries with a bigger
    // buffer when out_len exceeds max_len, so clamping here would silently
    // truncate the paste instead.
    const copy_len = @min(app.clipboard_len, max_len);
    if (copy_len > 0) {
        @memcpy(out_buf[0..copy_len], app.clipboard_buf[0..copy_len]);
    }
    out_len.* = app.clipboard_len;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_get: len={d}\n", .{copy_len});
    return app.clipboard_result;
}

pub fn onClipboardSet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    data: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    _ = register;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set: called len={d}\n", .{len});

    if (len == 0) return 1;

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return 0;

    const hwnd = app.hwnd orelse return 0;

    // Create event if not exists
    if (app.clipboard_event == null) {
        app.clipboard_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
        if (app.clipboard_event == null) {
            if (applog.isEnabled()) applog.appLog("[win] clipboard_set: CreateEventW failed\n", .{});
            return 0;
        }
    }

    // Reset event
    _ = c.ResetEvent(app.clipboard_event);

    // Store data pointer and length for UI thread
    app.clipboard_set_data = data;
    app.clipboard_set_len = len;

    // Post message to UI thread
    if (c.PostMessageW(hwnd, app_mod.WM_APP_CLIPBOARD_SET, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set: PostMessageW failed\n", .{});
        return 0;
    }

    // Wait for UI thread to complete (timeout: 5 seconds)
    const wait_result = c.WaitForSingleObject(app.clipboard_event, 5000);
    if (wait_result != c.WAIT_OBJECT_0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set: WaitForSingleObject failed or timeout\n", .{});
        return 0;
    }

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set: result={d}\n", .{app.clipboard_result});
    return app.clipboard_result;
}

/// SSH authentication prompt callback
/// Called when SSH mode detects a password prompt
pub fn onSSHAuthPrompt(
    ctx: ?*anyopaque,
    prompt: [*]const u8,
    prompt_len: usize,
) callconv(.c) void {
    if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: called len={d}\n", .{prompt_len});

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return;

    // Post message to UI thread to show password dialog
    const hwnd = app.hwnd orelse return;

    // Copy prompt data into owned buffer (core may free original after callback returns)
    const owned = app.alloc.alloc(u8, prompt_len) catch {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: OOM copying prompt\n", .{});
        return;
    };
    @memcpy(owned, prompt[0..prompt_len]);

    // Free any previous owned prompt that was not consumed
    if (app.ssh_prompt_owned) |old| {
        app.alloc.free(old);
    }
    app.ssh_prompt_owned = owned;

    if (c.PostMessageW(hwnd, app_mod.WM_APP_SSH_AUTH_PROMPT, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: PostMessageW failed\n", .{});
        // UI thread will never consume this prompt, free it now.
        app.alloc.free(owned);
        app.ssh_prompt_owned = null;
    }
}
