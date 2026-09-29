const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;

fn traceRender(app: *App, comptime fmt: []const u8, args: anytype) void {
    if (!applog.isVerbose()) return;
    applog.appLog("[render_trace] side=windows flush={d} " ++ fmt, .{app.core_flush_generation.load(.acquire)} ++ args);
}

fn traceExternalSurfaceId(ext: *const app_mod.ExternalWindow, fallback: i64) i64 {
    const layers = ext.surf.tbs.flush_layers orelse ext.surf.tbs.committed_layers;
    return if (layers.root()) |root| root.grid_id else fallback;
}
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const core = @import("zonvie_core");
const external_windows = @import("ui/external_windows.zig");
const render_helpers = @import("render_pipeline_helpers.zig");
const input = @import("input.zig");

// ---- Logging globals for row vertex callbacks ----
var log_row_no_glyphs_count: u32 = 0;
var log_row_bad_uv_count: u32 = 0;

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

/// Post `msg` to the main window unless one is already pending: `flag` is
/// claimed false -> true here, the handler clears it, and a failed post (or no
/// window yet) clears it again so the next flush retries.
pub fn postCoalesced(app: *App, flag: *std.atomic.Value(bool), msg: c.UINT) void {
    if (flag.cmpxchgStrong(false, true, .release, .monotonic) != null) return;
    const hwnd = app.hwnd orelse {
        flag.store(false, .release);
        return;
    };
    if (c.PostMessageW(hwnd, msg, 0, 0) == 0) flag.store(false, .release);
}

/// Lazily open the main row/flat write set on its first actual mutation.
/// No-op and cursor-only flushes consequently avoid the O(max_rows) slot
/// release/copy/retain work in TripleBufferedSurface.beginFlush.
/// Caller holds app.mu.
fn ensureMainSurfaceFlush(app: *App) bool {
    if (app.surf.tbs.is_in_flush) return true;
    if (app.surf.tbs.beginFlush(app.alloc)) return true;
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
        // Keep paint admission closed until a retry commits matching UVs.
        abortAtlasFlush(app, "atlas recreation retry failed");
        return false;
    }

    app.atlas_create_retry_pending.store(false, .release);
    return true;
}

pub fn markDirtyRowsByRect(app: *App, rc: c.RECT) void {
    const row_h: u32 = app.rowHeightPx();

    // The rect is in client coordinates; rows start at the surface origin
    // (below a titlebar tabline only -- a sidebar shifts x, not rows).
    const y_offset: i32 = input.surfaceOriginPx(app, true).y;

    const top_u: u32 = @intCast(@max(0, rc.top - y_offset));
    const bot_u: u32 = @intCast(@max(0, rc.bottom - y_offset));

    var r0: u32 = top_u / row_h;
    var r1: u32 = (bot_u + (row_h - 1)) / row_h; // ceil

    // Clamp to current grid rows to avoid out-of-bounds (e.g. r == rows).
    const max_rows: u32 = app.surf.surface.rows;
    if (max_rows != 0) {
        if (r0 > max_rows) r0 = max_rows;
        if (r1 > max_rows) r1 = max_rows;
    }

    // TBS: also mark rows dirty in flush_dirty (if in flush).
    if (app.surf.tbs.is_in_flush) {
        var rr: u32 = r0;
        while (rr < r1) : (rr += 1) {
            if (rr < app.surf.tbs.sparse_sync.flush_dirty.bit_length) {
                if (!app.surf.tbs.markFlushDirtyRow(rr)) failFlush(app);
            }
        }
    }
}

/// Shift a pending capture's rows for a scroll region. Moved rows keep their
/// vertices (origin_row tracks where they were generated; the draw path
/// applies the viewport Y translation). Only vacated rows are invalidated.
fn swapAndShiftRows(row_verts: []app_mod.RowVerts, row_start: u32, row_end: u32, rows_delta: i32) void {
    const band = render_helpers.rotateRegion(app_mod.RowVerts, row_verts, row_start, row_end, rows_delta);
    for (row_verts[band.start..band.end]) |*rv| {
        rv.verts.clearRetainingCapacity();
        rv.gen +%= 1;
    }
}

/// Remap slot indices in row_map for a scroll region. Physical data does not move.
/// macOS equivalent: remapMainRowSlots (GridSurfaceRenderer.swift).
/// Vacated rows keep the slots scrolled off, so ref_counts do not change. The
/// shared pool data is NOT modified: a slot may also be referenced by the
/// committed set, which WM_PAINT reads during this flush. The caller must
/// ensure that vacated rows are regenerated via on_vertices_row →
/// cowDetachRow (which detaches a shared slot) before commit.
fn remapRowSlots(row_map: []app_mod.RowMapping, row_start: u32, row_end: u32, rows_delta: i32) void {
    _ = render_helpers.rotateRegion(app_mod.RowMapping, row_map, row_start, row_end, rows_delta);
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

/// The main surface's cursor, from onVerticesRow (CURSOR set, MAIN clear:
/// the core sends no other vertex update to this surface outside rows).
/// `cursor_row` is the cursor's row in its own grid (the callback's
/// row_start), recorded with the cursor so its erase rows can be found.
fn storeMainSurfaceCursor(
    app: *App,
    cursor_ptr: ?[*]const app_mod.Vertex,
    cursor_count: usize,
    cursor_row_in_grid: u32,
) void {
    if (applog.isEnabled()) applog.appLog(
        "[win] storeMainSurfaceCursor cursor_count={d}\n",
        .{cursor_count},
    );

    app.mu.lockUncancelable(core.clock.io());

    const cursor_slice: []const app_mod.Vertex = if (cursor_ptr != null and cursor_count != 0)
        cursor_ptr.?[0..cursor_count]
    else
        &.{};
    // App.cursor was read here and is never assigned, so the main
    // window's cursor row was always null: no erase rows at commit, and
    // no cursor row in its layer for a blink-off redraw.
    const cursor_row: ?u32 = if (cursor_slice.len != 0) cursor_row_in_grid else null;
    if (!app.surf.tbs.storeMainCursor(app.alloc, cursor_slice, cursor_row)) {
        failFlush(app);
        app.mu.unlock(core.clock.io());
        return;
    }

    const row_mode = app.surf.surface.row_mode;
    // compute old rect before overwriting cursor_verts
    const old_rc = app.last_cursor_rect_px;

    if (cursor_ptr != null and cursor_count != 0) {
        const slice = cursor_ptr.?[0..cursor_count];

        // Log cursor vertex data for debugging
        if (applog.isEnabled() and slice.len >= 1) {
            const v0 = slice[0];
            applog.appLog(
                "[win] storeMainSurfaceCursor cursor v0: pos=({d:.2},{d:.2}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                .{ v0.position[0], v0.position[1], v0.color[0], v0.color[1], v0.color[2], v0.color[3] },
            );
        }
        if (app.hwnd) |hwnd| {
            // Compute viewport-aware cursor rect matching D3D11 viewport.
            var rect_client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &rect_client);

            // The cursor's grid origin on the surface (content viewport plus
            // its layer's), and the core's bounds: the paint driver computes
            // the same rectangle the same way.
            const surface_origin = input.surfaceOriginPx(app, true);
            const cursor_layer_grid = app.surf.tbs.cursorLayerGridIdInFlush();
            const layers = if (app.surf.tbs.flush_layers) |staged|
                staged
            else
                app.surf.tbs.committed_layers;
            const layer_origin = render_helpers.layerOriginPx(app_mod.SurfaceLayer, layers.slice(), cursor_layer_grid, 1);
            const new_rc: ?c.RECT = if (core.cursor_rect.bounds(
                app_mod.Vertex,
                slice,
                @floatFromInt(surface_origin.x + layer_origin[0]),
                @floatFromInt(surface_origin.y + layer_origin[1]),
            )) |cb| blk: {
                const ir = core.cursor_rect.inflateClip(cb, rect_client.right, rect_client.bottom) orelse break :blk null;
                break :blk .{ .left = ir.left, .top = ir.top, .right = ir.right, .bottom = ir.bottom };
            } else null;
            app.last_cursor_rect_px = new_rc;

            // Row-mode: cursor move should only invalidate cursor rects.
            if (row_mode) {
                if (!app.cursor_overlay_active) {
                    app.cursor_overlay_active = true;
                    app.need_full_seed.store(true, .seq_cst);
                    app.surf.tbs.markFlushPaintFull();
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
            app.surf.flush_needs_invalidate = true;
        }
    }

    if (cursor_ptr != null and cursor_count != 0) app.surf.flush_needs_invalidate = true;

    // Get hwnd before unlock
    const hwnd_for_blink = app.hwnd;

    app.mu.unlock(core.clock.io());

    // Every cursor update re-reads guicursor's blink cadence (covers a cursor
    // on an external grid, where grid 1 gets an empty set but mode_change may
    // have changed the settings). Posted: the UI thread owns the timer.
    postCursorBlinkUpdate(hwnd_for_blink);
}

fn postCursorBlinkUpdate(hwnd_opt: ?c.HWND) void {
    if (hwnd_opt) |hwnd| _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CURSOR_BLINK, 0, 0);
}

/// For a cursor update that stores nothing: every one re-reads guicursor's
/// blink cadence all the same.
fn postCursorBlinkUpdateLocking(app: *App) void {
    app.mu.lockUncancelable(core.clock.io());
    const hwnd = app.hwnd;
    app.mu.unlock(core.clock.io());
    postCursorBlinkUpdate(hwnd);
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
    traceRender(app, "event=row_receive grid={d} row={d} row_count={d} vertices={d} flags={d}\n", .{ grid_id, row_start, row_count, vert_count, flags });
    const layout_only =
        row_count == 0 and
        vert_count == 0 and
        (total_rows == 0 or total_cols == 0);

    // In row-only ABI configurations the core sends the main-window cursor
    // through this callback with CURSOR set and MAIN clear. It has its own
    // cursor-layer transaction (storeMainSurfaceCursor); the row payload must
    // never replace or dirty the main row set.
    if ((flags & app_mod.VERT_UPDATE_CURSOR) != 0 and
        (flags & app_mod.VERT_UPDATE_MAIN) == 0)
    {
        if (grid_id == 1) {
            if (vert_count == 0 and app.surf.tbs.cursorLayerGridIdInFlush() != grid_id) {
                traceRender(app, "event=cursor_ignore surface=1 grid={d} owner={d} reason=empty_nonowner\n", .{ grid_id, app.surf.tbs.cursorLayerGridIdInFlush() });
                postCursorBlinkUpdateLocking(app);
                return;
            }
            app.surf.tbs.stageCursorLayerGrid(1);
            storeMainSurfaceCursor(app, verts_ptr, vert_count, row_start);
            return;
        }
        // A grid the main surface places as a layer owns the surface's one
        // cursor. Remember which layer it is so the overlay is drawn with that
        // layer's transform.
        const owns = blk: {
            app.mu.lockUncancelable(core.clock.io());
            defer app.mu.unlock(core.clock.io());
            break :blk switch (resolveGridRouteLocked(app, grid_id)) {
                .main_root, .main_layer => true,
                .external_root, .external_layer, .unplaced => false,
            };
        };
        if (owns) {
            if (vert_count == 0 and app.surf.tbs.cursorLayerGridIdInFlush() != grid_id) {
                traceRender(app, "event=cursor_ignore surface=1 grid={d} owner={d} reason=empty_nonowner\n", .{ grid_id, app.surf.tbs.cursorLayerGridIdInFlush() });
                // Grid 1's ignored clear posted this and a layer's did not.
                postCursorBlinkUpdateLocking(app);
                return;
            }
            traceRender(app, "event=cursor_route surface=1 grid={d} vertices={d}\n", .{ grid_id, vert_count });
            app.surf.tbs.stageCursorLayerGrid(grid_id);
            storeMainSurfaceCursor(app, verts_ptr, vert_count, row_start);
            return;
        }
    }

    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    if (log_enabled) {
        app.log_flush_row_callbacks +|= 1;
        app.log_flush_vertex_count +|= @intCast(vert_count);
    }
    // A deferred layout has no valid destination for hosted rows. Do not
    // capture them under a child id: only HWND roots consume pending frames.
    if (app.flush_failed) return;

    if (log_verbose) {
        applog.appLog(
            "[win] on_vertices_row row_start={d} row_count={d} vert_count={d} flags=0x{x} rows={d} row_valid={d}\n",
            .{
                row_start,
                row_count,
                vert_count,
                flags,
                app.surf.surface.rows,
                app.row_valid_count,
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
    // External grids use their own vertex storage (the window's TBS, or
    // pending_external_verts before the window exists)
    if (grid_id != 1) {
        const flush_generation = app.core_flush_generation.load(.acquire);
        if (log_verbose) applog.appLog(
            "[win] on_vertices_row external grid_id={d} row_start={d} vert_count={d} total_rows={d} total_cols={d}\n",
            .{ grid_id, row_start, vert_count, total_rows, total_cols },
        );

        // A grid the main surface places as a layer -- a float or split that
        // lives in the main window, not its own -- is stored per grid and
        // drawn on top of the root grid. Cursor rows keep the external path,
        // which already owns the cursor layer.
        //
        // A window already closing does not count as a registration. The core
        // un-externalizes a grid and re-sends all of its rows in ONE flush
        // (flush.zig, the newly-hosted markAllDirty), while this map is only
        // cleared later by the UI thread -- so a grid moving back into the
        // main window as a float was routed to the dead window, refused there
        // for closing, and parked in pending_external_verts, which nothing
        // drains unless that id becomes an external window again. The layer
        // route is the correct one the moment the close is staged: the new
        // layout is already published, and the ABI requires tolerating rows
        // for a grid that is in no layer yet.
        const row_route = resolveGridRouteLocked(app, grid_id);
        const ext_registered = switch (row_route) {
            .external_root => true,
            .main_root, .main_layer, .external_layer, .unplaced => false,
        };
        if ((flags & 2) == 0 and !ext_registered) {
            const row_verts: []const app_mod.Vertex =
                if (verts_ptr) |vp| vp[0..vert_count] else &[_]app_mod.Vertex{};
            if (storeMainSurfaceLayerRowLocked(app, grid_id, row_start, row_verts, total_rows, total_cols, row_route)) {
                // Request a paint, but do NOT dirty the root rows underneath:
                // grid 1 holds no cells under ext_multigrid, so the root row
                // loop would draw its empty-row background fill over the whole
                // window every frame — which is opaque and destroys blur.
                // The layer's own dirty flag and present rect carry the frame.
                // Only for a main-window layer: a float an external window
                // hosts already asked its host (storeMainSurfaceLayerRowLocked
                // sets needs_redraw), and the main flag drives a whole-window
                // InvalidateRect — the row-scroll path makes the same split.
                switch (row_route) {
                    .main_root, .main_layer, .unplaced => app.surf.flush_needs_invalidate = true,
                    .external_layer, .external_root => {},
                }
                return;
            }
        }

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
            // The grid's own window only counts while it is not closing. A
            // grid moving into a float hosted by ANOTHER external window still
            // matches the stale entry here, and taking it meant the update was
            // refused as pending-close instead of falling through to the host
            // that now owns it -- the content rows found their way there, the
            // cursor did not.
            const own_win = blk_own: {
                if (app.external_windows.get(grid_id)) |w| {
                    if (!w.is_pending_close) break :blk_own w;
                }
                break :blk_own null;
            };
            const ext_win = own_win orelse externalSurfaceForGridLocked(app, grid_id) orelse break :blk null;
            // A closing HWND belongs to the old lifecycle. Capture updates for
            // the replacement lifecycle instead of letting the core consume
            // them as successful writes to a window that will be destroyed.
            if (ext_win.is_pending_close) break :blk null;
            // External surfaces join lazily on their first update. Bracketing
            // every external HWND in onFlushBegin made one occluded/busy window
            // apply backpressure to unrelated main-grid flushes and copied every
            // external committed set even when it was untouched.
            if (!is_cursor_update and !ext_win.surf.tbs.is_in_flush) {
                if (!app.core_flush_active.load(.acquire) or !ext_win.surf.tbs.beginFlush(app.alloc)) {
                    failFlush(app);
                    return;
                }
            }
            break :blk ext_win;
        };

        // Try to find an existing external window with no pending seed.
        if (live_ext_win) |ext_win| {
            if (!is_cursor_update and ext_win.surf.tbs.is_in_flush) {
                ext_win.surf.tbs.writeSet().metrics_gen = app.shared_metrics_gen;
            }
            if (is_cursor_update) {
                // guicursor carries a blink cadence per mode, so every cursor
                // update re-reads it, as on the main surface and on macOS.
                // Grid 1 used to be sent an empty cursor on every move and
                // that post covered this surface; it is sent one only when
                // the cursor leaves it now.
                if (app.hwnd) |hwnd| _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CURSOR_BLINK, 0, 0);
                if (vert_count == 0 and ext_win.surf.tbs.cursorLayerGridIdInFlush() != grid_id) {
                    traceRender(app, "event=cursor_ignore surface={d} grid={d} owner={d} reason=empty_nonowner\n", .{ traceExternalSurfaceId(ext_win, grid_id), grid_id, ext_win.surf.tbs.cursorLayerGridIdInFlush() });
                    return;
                }
                traceRender(app, "event=cursor_route surface={d} grid={d} vertices={d}\n", .{ traceExternalSurfaceId(ext_win, grid_id), grid_id, vert_count });
                if (!app.core_flush_active.load(.acquire)) {
                    failFlush(app);
                    return;
                }
                const cursor_slice: []const app_mod.Vertex = if (verts_ptr != null and vert_count != 0)
                    verts_ptr.?[0..vert_count]
                else
                    &.{};
                const cursor_row: ?u32 = if (cursor_slice.len != 0) row_start else null;

                // The TBS cursor transaction records the old and the new row;
                // paint reads its committed snapshot.
                if (!ext_win.surf.tbs.storeMainCursor(app.alloc, cursor_slice, cursor_row)) {
                    failFlush(app);
                    return;
                }
                ext_win.surf.tbs.stageCursorLayerGrid(grid_id);
                ext_win.needs_redraw = true;
                ext_win.surf.flush_needs_invalidate = true;
                // InvalidateRect deferred to onFlushEnd.
                return;
            }

            const size_changed = (ext_win.surf.surface.rows != total_rows or ext_win.surf.surface.cols != total_cols);
            if (ext_win.surf.tbs.is_in_flush) {
                const ws = ext_win.surf.tbs.writeSet();
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
                    if (!ext_win.surf.tbs.prepareRowSyncTracking(app.alloc, total_rows)) {
                        failFlush(app);
                        return;
                    }
                    ext_win.surf.tbs.requireFullRowSync();

                    const old_len = ws.row_map.items.len;
                    const new_len: usize = @intCast(total_rows);
                    if (new_len < old_len) {
                        for (ws.row_map.items[new_len..]) |*mapping| {
                            if (mapping.slot != app_mod.SLOT_NONE) {
                                ext_win.surf.tbs.pool.release(app.alloc, mapping.slot);
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
            ext_win.surf.surface.rows = total_rows;
            ext_win.surf.surface.cols = total_cols;
            ext_win.needs_redraw = true;
            ext_win.surf.flush_needs_invalidate = true;
            if (size_changed) {
                ext_win.surf.surface.paint_full = true;
                if (ext_win.surf.tbs.is_in_flush) {
                    ext_win.surf.tbs.flush_paint_full = true;
                }
            }

            if (row_count == 1) {
                // TBS: COW detach + write to slot, mark dirty.
                if (ext_win.surf.tbs.is_in_flush) {
                    const ws = ext_win.surf.tbs.writeSet();
                    ws.rows = total_rows;
                    ws.cols = total_cols;
                    // External windows own a separate pool, so they need the
                    // same layout/peak observations as the main grid above.
                    ext_win.surf.tbs.pool.noteLayoutWidth(total_cols);
                    if (!ext_win.surf.tbs.writeFlushRow(app.alloc, row_start, if (verts_ptr) |p| p[0..vert_count] else &.{})) failFlush(app);
                }
            } else if (row_count == 0) {
                // A zero-cell layout (zonvie_core.h): no row content survives.
                if (ext_win.surf.tbs.is_in_flush) {
                    const ws = ext_win.surf.tbs.writeSet();
                    ws.row_mode = true;
                    ext_win.surf.tbs.requireFullRowSync();
                    ws.releaseAllSlots(app.alloc, &ext_win.surf.tbs.pool);
                    ext_win.surf.tbs.flush_paint_full = true;
                }
            }

            // Resize popupmenu window if size changed (keep top-left position)
            // Use deferred resize via PostMessage to avoid deadlock with WM_SIZE handler
            if (grid_id == app_mod.POPUPMENU_GRID_ID and size_changed) {
                const cell_w = app.cell_w_px;
                const cell_h = app.rowHeightPx();
                const content_w: c_int = @intCast(total_cols * cell_w);
                const content_h: c_int = @intCast(total_rows * cell_h);

                const outer = external_windows.windowOuterSizePx(ext_win.hwnd, content_w, content_h);
                const window_w: c_int = outer.w;
                const window_h: c_int = outer.h;

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
                "[win] on_vertices_row external grid_id={d} updated\n",
                .{grid_id},
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
                // Every cursor update re-reads the blink cadence (see the
                // live external path above).
                if (app.hwnd) |hwnd| _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CURSOR_BLINK, 0, 0);
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
                if (row_count == 0) {
                    // A zero-cell layout: no row content survives.
                    _ = pv.surface.truncateRows(app.alloc, 0);
                } else if (row_count == 1) {
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
                    if (!storeSurfaceRowVerts(app.alloc, &new_pv.surface.row_verts, row_start, verts_ptr, vert_count)) {
                        // Free the partially built entry (row storage may
                        // have been resized before the failure).
                        new_pv.deinit(app.alloc);
                        failFlush(app);
                        return;
                    }
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
            "[win] on_vertices_row max_row_end={d} rows={d}\n",
            .{ app.row_mode_max_row_end, app.surf.surface.rows },
        );
    }

    // Rows and columns are both part of the published layout. A width-only
    // zero-cell transition has no row payload to overwrite stale contents.
    if (total_rows != app.surf.surface.rows or total_cols != app.surf.surface.cols) {
        const old_rows = app.surf.surface.rows;
        const old_cols = app.surf.surface.cols;
        app.surf.surface.rows = total_rows;
        app.surf.surface.cols = total_cols;
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
    app.surf.tbs.pool.noteLayoutWidth(total_cols);

    // TBS: update write set rows/cols and resize flush_dirty on dimension change.
    if (app.surf.tbs.is_in_flush) {
        const write_set = app.surf.tbs.writeSet();
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
            if (!app.surf.tbs.prepareRowSyncTracking(app.alloc, total_rows)) {
                failFlush(app);
                return;
            }
            app.surf.tbs.requireFullRowSync();

            write_set.releaseAllSlots(app.alloc, &app.surf.tbs.pool);
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
            app.surf.tbs.requireFullRowSync();
            write_set.releaseAllSlots(app.alloc, &app.surf.tbs.pool);
        }
    }

    // Note: We don't mark the content rows dirty here anymore.
    // The WM_PAINT handler will determine if it's cursor-only by checking
    // if all dirty rows are covered by cursor rects from paint_rects_snapshot.

    // Mark row-mode and remember which rows are dirty.
    // When we enter row-mode for the first time, request a one-time full seed.
    if (!app.surf.surface.row_mode) {
        app.surf.surface.row_mode = true;
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        if (app.surf.surface.rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(app.surf.surface.rows), false) catch {};
            app.row_valid.unsetAll();
        }
    }

    if (layout_only) {
        app.row_valid_count = 0;
        if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.surf.flush_needs_invalidate = true;
        return;
    }

    // Clamp to [0, app.surf.surface.rows) to avoid index==rows.
    const max_rows: u32 = app.surf.surface.rows;

    if (max_rows != 0 and row_start >= max_rows) {
        return;
    }

    if (row_count == 1) {
        // Single-row path (normal case): store vertices for this row.
        const row: u32 = row_start;

        // TBS: COW detach + write to slot, mark flush_dirty.
        if (app.surf.tbs.is_in_flush) {
            if (!app.surf.tbs.writeFlushRow(app.alloc, row, if (verts_ptr) |p| p[0..vert_count] else &.{})) failFlush(app);
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
    // app.surf.surface.rows (global grid rows) which includes tabline/statusline
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
    app.surf.flush_needs_invalidate = true;
}

/// Shift an external grid's rows: its write set's slots for a window root,
/// the pending capture before the window exists, a layer's own storage.
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

    // An empty region or a zero shift carries no rows, so the core vacates
    // none and this owes no resend.
    if (rows_delta == 0 or row_end <= row_start) return;
    // The core refuses a partial-width scroll and regenerates the grid
    // instead (see the on_grid_row_scroll contract in include/zonvie_core.h),
    // so one arriving here means the refusal did not happen. The shift cannot
    // be applied to full-width row storage; ask for the full resend the
    // contract owes rather than dropping it.
    if (col_start != 0 or col_end != total_cols) {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    // A grid the main surface, or another external surface, places as a layer
    // shifts its own rows here. The core sends only the vacated ones
    // afterwards, so the survivors have to be carried by moving them within
    // this grid's own storage. The route comes from the one resolver the row
    // and cursor paths use, so a window already closing no longer counts as a
    // registration here either.
    const row_route = resolveGridRouteLocked(app, grid_id);
    const is_external_root = switch (row_route) {
        .external_root => true,
        // A grid whose window is still queued has its rows captured in
        // pending_external_verts (onVerticesRow), so its shift goes there too.
        .unplaced => for (app.pending_external_verts.items) |pv| {
            if (pv.grid_id == grid_id) break true;
        } else false,
        .main_root, .main_layer, .external_layer => false,
    };
    if (!is_external_root) {
        if (app.layer_grids.get(grid_id)) |state| {
            if (!state.stageShift(app.alloc, row_start, row_end, rows_delta, total_rows, total_cols)) {
                core.zonvie_core_force_resend_locked(app.corep);
                failFlush(app);
            } else {
                // onFlushEnd invalidates an external HWND exclusively from its
                // own needs_redraw, so a float this surface hosts that only
                // SHIFTS rows scheduled a repaint of the main window and none
                // of its actual host. The row-store route one function away has
                // always set it. Usually masked, because the core sends the
                // vacated rows right after the shift and those take that route.
                // Ask the surface that actually draws this layer, and only it:
                // a float an external window hosts is not a visual change on
                // the main window, whose flag drives a whole-window
                // InvalidateRect.
                switch (row_route) {
                    .external_layer => |host| {
                        host.needs_redraw = true;
                        host.surf.flush_needs_invalidate = true;
                    },
                    .main_root, .main_layer, .unplaced => app.surf.flush_needs_invalidate = true,
                    .external_root => {},
                }
                if (applog.isEnabled()) applog.appLog(
                    "[layer_row_scroll] gridId={d} rowStart={d} rowEnd={d} rowsDelta={d}\n",
                    .{ grid_id, row_start, row_end, rows_delta },
                );
            }
        } else {
            // No storage for this grid yet, so the mandatory shift cannot be
            // applied and the vacated-rows-only follow-up would land on rows
            // that were never carried. Request the full resend instead.
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
        }
        return;
    }

    // A pre-window/replacement capture is the frontend's only copy of rows the
    // core omits on its scroll fast path. Shift it before the vacated rows are
    // overwritten by the row callbacks later in this flush.
    for (app.pending_external_verts.items) |*pv| {
        if (pv.grid_id != grid_id) continue;
        if (total_rows == 0 or
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
        swapAndShiftRows(pv.surface.row_verts.items, row_start, row_end, rows_delta);
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
    if (!ext_win.surf.tbs.is_in_flush) {
        if (!app.core_flush_active.load(.acquire) or !ext_win.surf.tbs.beginFlush(app.alloc)) {
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return;
        }
    }
    // Asked of the write set, not of a mirror the row callback kept: that
    // mirror also took rows from flushes that were cancelled afterwards.
    if (ext_win.is_pending_close or !ext_win.surf.tbs.writeSetRowsSeeded(total_rows)) {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    ext_win.surf.surface.rows = total_rows;
    ext_win.surf.surface.cols = total_cols;

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

    // Reserve the dirty tracking BEFORE any mutation below: aborting after
    // the slot remap would leave it applied while the core retries the same
    // scroll delta. The seeded test above already needs row_map to cover
    // total_rows. prepareRowSyncTracking is intentionally unconditional:
    // after a partial allocation failure, flush_dirty alone may already have
    // the requested length.
    if (!ext_win.surf.tbs.prepareRowSyncTracking(app.alloc, total_rows) or
        !ext_win.surf.tbs.sparse_sync.isReady(total_rows))
    {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    // `last_cursor_row` is a row of the grid the cursor is ON. A cursor in a
    // float this window hosts names that float's row, which says nothing
    // about the root's scroll region, and the core does not resend a cursor
    // that did not move: clearing it there erased it for good.
    const cursor_on_root = ext_win.surf.tbs.cursorLayerGridIdInFlush() == grid_id;
    const clear_committed_cursor = if (ext_win.surf.tbs.stagedCursorRow()) |cr|
        cursor_on_root and cr >= row_start and cr < row_end
    else
        false;
    if (clear_committed_cursor and !ext_win.surf.tbs.storeMainCursor(app.alloc, &.{}, null)) {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }

    // TBS: remap slot indices in write set (no physical data move).
    // Storage for both the row map and the dirty bitmap was already
    // reserved and verified above — infallible from here.
    {
        const ws = ext_win.surf.tbs.writeSet();
        {
            ws.rows = total_rows;
            ws.cols = total_cols;
            remapRowSlots(ws.row_map.items, row_start, row_end, rows_delta);
            var changed_row = row_start;
            while (changed_row < row_end) : (changed_row += 1) {
                if (!ext_win.surf.tbs.markFlushMappingChanged(changed_row)) {
                    core.zonvie_core_force_resend_locked(app.corep);
                    failFlush(app);
                    return;
                }
            }
            // Mark only vacated rows dirty.
            // back_tex is persistent, so non-vacated rows retain correct content.
            if (rows_delta > 0) {
                var sr: u32 = row_end - abs_rows;
                while (sr < row_end) : (sr += 1) {
                    if (sr < ext_win.surf.tbs.sparse_sync.flush_dirty.bit_length) {
                        if (!ext_win.surf.tbs.markFlushDirtyRow(sr)) failFlush(app);
                    }
                }
            } else {
                var sr: u32 = row_start;
                while (sr < row_start + abs_rows) : (sr += 1) {
                    if (sr < ext_win.surf.tbs.sparse_sync.flush_dirty.bit_length) {
                        if (!ext_win.surf.tbs.markFlushDirtyRow(sr)) failFlush(app);
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

    if (ext_win.surf.tbs.flush_scroll_rect) |existing| {
        if (existing.left == new_rect.left and existing.right == new_rect.right and
            existing.top == new_rect.top and existing.bottom == new_rect.bottom)
        {
            ext_win.surf.tbs.flush_scroll_dy_px += delta_px;
            ext_win.surf.tbs.flush_vb_shift += rows_delta;
        } else {
            // Different region: invalidate scroll optimization.
            ext_win.surf.tbs.flush_scroll_rect = null;
            ext_win.surf.tbs.flush_scroll_dy_px = 0;
            ext_win.surf.tbs.flush_vb_shift = 0;
            ext_win.surf.tbs.flush_paint_full = true;
        }
    } else {
        ext_win.surf.tbs.flush_scroll_rect = new_rect;
        ext_win.surf.tbs.flush_scroll_dy_px = delta_px;
        ext_win.surf.tbs.flush_vb_shift = rows_delta;
        ext_win.surf.tbs.flush_scroll_row_start = row_start;
        ext_win.surf.tbs.flush_scroll_row_end = row_end;
    }

    ext_win.needs_redraw = true;
    ext_win.surf.flush_needs_invalidate = true;
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
    traceRender(app, "event=begin\n", .{});

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
    app.pending_grid_destroys.clearRetainingCapacity();
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
    var failed = app.flush_failed or atlas_corrupted or core_aborted;
    if (!failed) {
        var prepare_it = app.layer_grids.valueIterator();
        while (prepare_it.next()) |state| {
            if (!state.*.prepareCommit(app.alloc)) {
                failFlush(app);
                failed = true;
                break;
            }
        }
    }
    app.flush_failed = false;
    if (failed) {
        app.surf.flush_needs_invalidate = false;
        const failed_generation = app.core_flush_generation.load(.acquire);
        var ext_cancel_it = app.external_windows.iterator();
        while (ext_cancel_it.next()) |entry| {
            traceRender(app, "event=surface_abort surface={d}\n", .{entry.key_ptr.*});
            entry.value_ptr.*.surf.tbs.cancelFlush();
            entry.value_ptr.*.surf.flush_needs_invalidate = false;
        }
        // Layers publish nothing until applyStaged, so dropping their staged
        // ops leaves WM_PAINT on the previous committed frame.
        var layer_cancel_it = app.layer_grids.iterator();
        while (layer_cancel_it.next()) |entry| {
            entry.value_ptr.*.discardStaged();
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
        // Publish staged rows and placements under the same app.mu hold.
        var layer_commit_it = app.layer_grids.iterator();
        while (layer_commit_it.next()) |entry| {
            const applied = entry.value_ptr.*.applyStaged(app.alloc);
            std.debug.assert(applied);
        }
        invalidateMovedLayersLocked(app, &app.surf.tbs);
        var ext_commit_it = app.external_windows.iterator();
        while (ext_commit_it.next()) |entry| {
            invalidateMovedLayersLocked(app, &entry.value_ptr.*.surf.tbs);
            entry.value_ptr.*.surf.tbs.commitFlush(app.alloc);
            traceRender(app, "event=surface_commit surface={d} layers={d}\n", .{ entry.key_ptr.*, entry.value_ptr.*.surf.tbs.committed_layers.len });
        }
        app.surf.tbs.commitFlush(app.alloc);
        if (app.pending_colorscheme_bg != 0xFFFFFFFF or app.pending_colorscheme_fg != 0xFFFFFFFF) {
            if (app.pending_colorscheme_bg != 0xFFFFFFFF) app.colorscheme_bg = app.pending_colorscheme_bg;
            if (app.pending_colorscheme_fg != 0xFFFFFFFF) app.colorscheme_fg = app.pending_colorscheme_fg;
            app.pending_colorscheme_bg = 0xFFFFFFFF;
            app.pending_colorscheme_fg = 0xFFFFFFFF;
            // The external clear colours fall back to it, and the GDI panels
            // and chrome paint from the pair.
            if (app.hwnd) |hwnd| {
                _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CMDLINE_COLORS, 0, 0);
                _ = c.PostMessageW(hwnd, app_mod.WM_APP_TABLINE_INVALIDATE, 0, 0);
            }
            if (app.message_window) |mw| _ = c.InvalidateRect(mw.hwnd, null, c.FALSE);
            for (app.mini_windows) |mini| {
                if (mini.hwnd) |h| _ = c.InvalidateRect(h, null, c.FALSE);
            }
        }
        for (app.pending_grid_destroys.items) |grid_id| {
            traceRender(app, "event=destroy_release grid={d} storage_present={}\n", .{ grid_id, app.layer_grids.contains(grid_id) });
            if (app.layer_grids.fetchRemove(grid_id)) |kv| {
                kv.value.deinit(app.alloc);
                app.alloc.destroy(kv.value);
            }
        }
    }
    if (failed) app.surf.tbs.cancelFlush();
    traceRender(app, "event=end outcome={s} retryable={} destroyed_pending={d} metadata_bytes={d} metadata_limit_bytes={d}\n", .{ if (failed) "abort" else "commit", retryable, app.pending_grid_destroys.items.len, app.layout_budget.live_bytes.load(.monotonic), core.render_layout.Budget.limit_bytes });
    app.pending_grid_destroys.clearRetainingCapacity();
    const log_row_callbacks = app.log_flush_row_callbacks;
    const log_vertex_count = app.log_flush_vertex_count;
    app.core_flush_active.store(false, .release);
    app.mu.unlock(core.clock.io());

    // A failed flush after onAtlasCreate must keep paint frozen: the CPU/GPU
    // atlas is already a new generation while the committed TBS still holds
    // old UVs. The retry's successful commit releases this same transaction.
    const atlas_reset_committed = if (!failed) app.endAtlasResetTransaction() else false;

    // Always re-evaluate message deadlines, including when this flush is
    // cancelled below. A msg_show OOM keeps its pending deadline armed and
    // must not lose the only UI-thread timer driver with the TBS commit.
    postCoalesced(app, &app.msg_throttle_arm_posted, app_mod.WM_APP_MSG_THROTTLE_ARM);

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
            postCoalesced(app, &app.glow_prepare_posted, app_mod.WM_APP_PREPARE_GLOW);
        } else {
            app.glow_prepare_posted.store(false, .release);
        }
    }

    postCoalesced(app, &app.scrollbar_update_pending, app_mod.WM_APP_UPDATE_SCROLLBAR);

    // Coalesce all per-callback dirty state into a single InvalidateRect per
    // window.  Individual vertex callbacks (onVerticesRow, storeMainSurfaceCursor,
    // onGridRowScroll) no longer call InvalidateRect directly; they only
    // accumulate dirty state (dirty_rows, paint_full, needs_redraw,
    // flush_needs_invalidate).  This prevents mid-flush WM_PAINT from drawing
    // incomplete frames, and skips InvalidateRect entirely for flushes that
    // carry no visual changes (e.g. msg_showcmd-only flushes).
    app.mu.lockUncancelable(core.clock.io());
    const main_dirty = app.surf.flush_needs_invalidate or atlas_reset_committed;
    app.surf.flush_needs_invalidate = false;
    const main_hwnd = if (main_dirty) app.hwnd else null;
    // Collect dirty external window HWNDs under lock.
    // Bounded array avoids allocation on the flush hot path.
    var ext_hwnds: [64]c.HWND = undefined;
    var ext_hwnd_count: usize = 0;
    var it = app.external_windows.iterator();
    while (it.next()) |entry| {
        const ext_dirty = entry.value_ptr.*.surf.flush_needs_invalidate or entry.value_ptr.*.needs_redraw;
        entry.value_ptr.*.surf.flush_needs_invalidate = false;
        if (ext_dirty or atlas_reset_committed) {
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
            // Recover from the mirror: bump the reset generation so every
            // surface, main included, re-uploads the full atlas from atlas_cpu.
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
        // The CPU atlas keeps its old generation, but the core's flush
        // already expects the new one: opening the gate here would pair the
        // flush's UVs with the atlas they were not made for.
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
    if (!applog.isEnabled()) return;
    if (bytes == null or len == 0) return;

    const s: []const u8 = @as([*]const u8, @ptrCast(bytes))[0..len];
    if (ctx != null and std.mem.startsWith(u8, s, "[render_trace] ")) {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        if (applog.isVerbose()) applog.appLog("[render_trace] flush={d} {s}", .{ app.core_flush_generation.load(.acquire), s[15..] });
        return;
    }
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
        // The config's own list goes through the core's formatter, the same
        // "name\tsize\tfeatures" lines the guifont payload carries (and
        // macOS reads): a bare entry inherits [font] size, and `:-liga` style
        // features are kept. This branch used to parse the list itself and
        // passed no features at all.
        const candidates: ?[]const u8 = if (skip_guifont)
            (core.config.formatFontFamilyAsCandidateList(arena.allocator(), app.config.font.family, config_pt, config_font) catch null)
        else if (bytes != null and len != 0)
            bytes.?[0..len]
        else
            null;
        if (candidates) |s| {
            // Iterate newline-separated candidates
            var line_it = std.mem.splitScalar(u8, s, '\n');
            while (line_it.next()) |entry| {
                // The core's reading of a candidate line, shared with macOS.
                const cand = core.config.parseFontCandidateLine(entry, config_pt, eff_size_explicit) orelse continue;
                const cand_name = cand.name;
                const cand_pt = cand.point_size;
                const cand_features = cand.features;

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

        // If no candidate succeeded, fall back to the config list (a
        // guifont-syntax list, walked like initMetrics does) -> OS default.
        if (!font_set and !skip_guifont) {
            const config_lines = core.config.formatFontFamilyAsCandidateList(arena.allocator(), app.config.font.family, config_pt, config_font) catch "";
            var config_it = std.mem.splitScalar(u8, config_lines, '\n');
            while (config_it.next()) |entry| {
                const cand = core.config.parseFontCandidateLine(entry, config_pt, size_explicit) orelse continue;
                a.setFontUtf8WithFeatures(cand.name, cand.point_size, cand.features) catch continue;
                applied_name = cand.name;
                applied_pt = cand.point_size;
                font_set = true;
                if (applog.isEnabled()) applog.appLog("onGuiFont: fallback config font '{s}' pt={d}", .{ cand.name, cand.point_size });
                break;
            }
        }
        if (!font_set) {
            const try_os = a.setFontUtf8WithFeatures(os_default_font, config_pt, "");
            if (try_os) |_| {
                applied_name = os_default_font;
                applied_pt = config_pt;
                if (applog.isEnabled()) applog.appLog("onGuiFont: fallback OS default '{s}' pt={d}", .{ os_default_font, config_pt });
            } else |e3| {
                if (applog.isEnabled()) applog.appLog("onGuiFont: OS default failed: {any}", .{e3});
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
    queueExternalWindowResizes(app, hwnd, cell_w, cell_h, "onGuiFont");

    // Invalidation flags must be co-set with the cell metrics update above (still
    // under app.mu): font change shifted cell_w_px/cell_h_px, so any WM_PAINT that
    // observes the new metrics must also see back_tex_valid=false and the seed
    // flags. Setting them only after InvalidateRect — as the previous code did —
    // left a window in which the UI thread could snapshot new metrics together
    // with stale back_tex_valid=true and preserve a geometrically wrong back_tex.
    app_mod.requestMainFullPaintLocked(app);
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
    queueExternalWindowResizes(app, hwnd, cell_w, cell_h, "onLineSpace");

    // Co-set invalidation flags with the linespace update above (still under
    // app.mu) for the same race-avoidance reason as onGuiFont: a WM_PAINT that
    // observes the new linespace must also see back_tex_valid=false and seed
    // flags, never an interleaved snapshot of new metrics + stale validity.
    app_mod.requestMainFullPaintLocked(app);
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
    onSessionSwap(ctx, "on_restart: reconnecting to listen_addr", addr_ptr, addr_len);
}

/// Receive the `connect` UI event (`:connect <addr>`). Same flicker-free
/// reconnect as restart; the only difference is that the previous server
/// keeps running headless instead of dying. The core handles the actual
/// hot-swap; this callback is informational only.
pub fn onConnect(ctx: ?*anyopaque, addr_ptr: ?[*]const u8, addr_len: usize) callconv(.c) void {
    onSessionSwap(ctx, "on_connect: hot-swap to server_addr", addr_ptr, addr_len);
}

fn onSessionSwap(ctx: ?*anyopaque, comptime label: []const u8, addr_ptr: ?[*]const u8, addr_len: usize) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    _ = app.external_session_generation.fetchAdd(1, .acq_rel);
    // The new session's grid ids restart, and the core forgets its last
    // cursor grid (resetForNewSession); forget ours too, or its first report
    // of a reused id reads as a repeat. Core thread, like its only reader.
    app.core_reported_cursor_grid = 1;
    if (!applog.isEnabled()) return;
    const addr: []const u8 = if (addr_ptr) |p| p[0..addr_len] else "(none)";
    applog.appLog("[win] " ++ label ++ "={s}\n", .{addr});
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
    // The renderers' clear colour (the remainder strip, and what shows under
    // dropped default-bg runs) is pulled from colorscheme_bg by each paint,
    // so it is published by onFlushEnd's commit with the cells.
    // The fg waits with it: the GDI message and mini panels read the two
    // as a pair, and a paint between here and the commit drew the new fg on
    // the old bg.
    if (bg != 0xFFFFFFFF) app.pending_colorscheme_bg = bg;
    if (fg != 0xFFFFFFFF) app.pending_colorscheme_fg = fg;
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

    // Bounded before converting (one slot kept for the null); an invalid
    // UTF-8 title keeps its valid prefix.
    const cap = app.pending_title.len - 1;
    const src = app_mod.utf8ValidPrefix(title, cap);
    app.mu.lockUncancelable(core.clock.io());
    const clamped_len = std.unicode.utf8ToUtf16Le(app.pending_title[0..cap], src) catch 0;
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

    // Failures return 0, as zonvie_core.h says; the core then answers empty.
    out_len.* = 0;
    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return 0;
    const hwnd = app.hwnd orelse return 0;
    if (!runClipboardOnUiThread(app, hwnd, app_mod.WM_APP_CLIPBOARD_GET, null)) return 0;

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

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return 0;

    const hwnd = app.hwnd orelse return 0;

    // An empty register is set too: it replaces the clipboard with "".
    if (!runClipboardOnUiThread(app, hwnd, app_mod.WM_APP_CLIPBOARD_SET, data[0..len])) return 0;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set: result={d}\n", .{app.clipboard_result});
    return app.clipboard_result;
}

/// Hand one clipboard request to the UI thread and wait up to 5s for it. A
/// set's payload is copied into clipboard_buf first, so a handler that runs
/// after the timeout never reads the core's freed buffer. True when the
/// handler completed; clipboard_buf/len/result then stay put until the next
/// request, since no handler acts without a pending one.
fn runClipboardOnUiThread(app: *App, hwnd: c.HWND, msg: c.UINT, payload: ?[]const u8) bool {
    const io = core.clock.io();
    var seq: u32 = 0;
    {
        app.clipboard_mu.lockUncancelable(io);
        defer app.clipboard_mu.unlock(io);
        if (app.clipboard_event == null) {
            // Manual-reset, initially non-signaled.
            app.clipboard_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
            if (app.clipboard_event == null) {
                if (applog.isEnabled()) applog.appLog("[win] clipboard: CreateEventW failed\n", .{});
                return false;
            }
        }
        if (payload) |p| {
            if (app.clipboard_buf.len < p.len) {
                const grown = app.alloc.alloc(u8, p.len) catch return false;
                if (app.clipboard_buf.len != 0) app.alloc.free(app.clipboard_buf);
                app.clipboard_buf = grown;
            }
            @memcpy(app.clipboard_buf[0..p.len], p);
            app.clipboard_len = p.len;
        }
        app.clipboard_seq +%= 1;
        if (app.clipboard_seq == 0) app.clipboard_seq = 1;
        seq = app.clipboard_seq;
        app.clipboard_active_seq = seq;
        app.clipboard_result = 0;
        _ = c.ResetEvent(app.clipboard_event);
    }

    const posted = c.PostMessageW(hwnd, msg, seq, 0) != 0;
    const signaled = posted and c.WaitForSingleObject(app.clipboard_event, 5000) == c.WAIT_OBJECT_0;

    app.clipboard_mu.lockUncancelable(io);
    defer app.clipboard_mu.unlock(io);
    // The handler clears the active request once its result is written; one
    // that finished just after the timeout still counts.
    const done = app.clipboard_active_seq != seq;
    if (!done) {
        app.clipboard_active_seq = 0;
        if (applog.isEnabled()) applog.appLog("[win] clipboard: request {d} not completed (posted={} signaled={})\n", .{ seq, posted, signaled });
    }
    return done;
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

    // Under app.mu: the UI handler takes the prompt from this field. Free any
    // previous one it has not taken yet.
    app.mu.lockUncancelable(core.clock.io());
    if (app.ssh_prompt_owned) |old| {
        app.alloc.free(old);
    }
    app.ssh_prompt_owned = owned;
    app.mu.unlock(core.clock.io());

    if (c.PostMessageW(hwnd, app_mod.WM_APP_SSH_AUTH_PROMPT, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: PostMessageW failed\n", .{});
        // This post will never consume the prompt; free it unless an earlier
        // pending handler already took it.
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        if (app.ssh_prompt_owned) |cur| if (cur.ptr == owned.ptr) {
            app.alloc.free(owned);
            app.ssh_prompt_owned = null;
        };
    }
}

/// Recompute every open external window's outer size for the current cell
/// metrics and queue the resize. onGuiFont and onLineSpace each ran this loop
/// verbatim; the only difference was the tag in the log line.
///
/// Sizing goes through externalSurfaceInsetsPx and
/// clampCmdlineWidthToWorkArea rather than re-deriving the padding here. The
/// hand-rolled copies this replaces omitted the copy-button reservation and
/// the cmdline's work-area clamp, so a guifont or linespace change while a
/// cmdline or message window was open queued it one copy-button width too
/// narrow for its content -- and, on a narrow monitor, wider than the work area.
pub fn queueExternalWindowResizes(
    app: *App,
    hwnd: ?c.HWND,
    cell_w: u32,
    cell_h: u32,
    log_tag: []const u8,
) void {
    // Caller must hold `app.mu`.
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const ext_win = entry.value_ptr.*;

        if (ext_win.is_pending_close) continue;

        const insets = external_windows.externalSurfaceInsetsPx(app, grid_id, ext_win.dpi_scale);
        var content_w: c_int = @as(c_int, @intCast(ext_win.surf.surface.cols * cell_w)) + insets.w;
        const content_h: c_int = @as(c_int, @intCast(ext_win.surf.surface.rows * cell_h)) + insets.h;
        if (grid_id == app_mod.CMDLINE_GRID_ID) content_w = external_windows.clampCmdlineWidthToWorkArea(grid_id, content_w, app_mod.monitorWorkArea(ext_win.hwnd), external_windows.cmdlineScreenMarginPx(app));

        // This window's actual style and DPI: WS_OVERLAPPEDWINDOW has a frame
        // WS_POPUP does not, and its height depends on the window's monitor.
        const outer = external_windows.windowOuterSizePx(ext_win.hwnd, content_w, content_h);
        ext_win.pending_window_w = outer.w;
        ext_win.pending_window_h = outer.h;
        ext_win.needs_window_resize = true;
        ext_win.needs_renderer_resize = true;

        if (applog.isEnabled()) applog.appLog("{s}: queued ext_win resize grid_id={d} to ({d},{d})\n", .{ log_tag, grid_id, ext_win.pending_window_w, ext_win.pending_window_h });

        // PostMessageW does not block, so it is safe to call under the lock.
        if (hwnd) |mh| {
            _ = c.PostMessageW(mh, app_mod.WM_APP_RESIZE_POPUPMENU, @bitCast(grid_id), 0);
        }
    }
}

/// A surface's layer list was replaced. Runs on the core thread inside the
/// flush bracket; the layers are staged and promoted when the flush commits,
/// so they become visible together with the vertices they place.
pub fn onSurfaceLayout(
    ctx: ?*anyopaque,
    surface_id: i64,
    layers: [*]const core.Layer,
    count: usize,
    surface_rows: u32,
    surface_cols: u32,
) callconv(.c) void {
    _ = surface_rows;
    _ = surface_cols;
    const app: *App = @ptrCast(@alignCast(ctx orelse return));

    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    const tbs = if (surface_id == 1) &app.surf.tbs else if (app.external_windows.get(surface_id)) |ext_win|
        &ext_win.surf.tbs
    else {
        traceRender(app, "event=layout_defer surface={d} reason=host_not_registered\n", .{surface_id});
        // The core must retain dirty rows and invalidate its layout signature
        // until the UI thread has registered the receiving surface.
        failFlush(app);
        return;
    };
    var staged = tbs.prepareLayers(app.alloc, &app.layout_budget, count) catch |err| {
        traceRender(app, "event=layout_failed surface={d} layers={d} reason={s} metadata_bytes={d}\n", .{ surface_id, count, @errorName(err), app.layout_budget.live_bytes.load(.monotonic) });
        if (err == error.LayoutBudgetExceeded) core.zonvie_core_fail_render_budget(app.corep);
        failFlush(app);
        return;
    };
    for (layers[0..count], 0..) |l, i| {
        staged.items[i] = .{
            .grid_id = l.grid_id,
            .anchor_grid = l.anchor_grid,
            .x_px = l.x_px,
            .y_px = l.y_px,
            .rows = l.rows,
            .cols = l.cols,
            .z = l.z,
            .follows_scroll = (l.flags & core.LAYER_FOLLOWS_SCROLL) != 0,
            .mouse_enabled = (l.flags & core.LAYER_MOUSE_ENABLED) != 0,
        };
    }
    tbs.stageLayers(staged);
    const cursor_owner = tbs.cursorLayerGridIdInFlush();
    var owner_present = false;
    for (layers[0..count]) |layer| {
        if (layer.grid_id == cursor_owner) {
            owner_present = true;
            break;
        }
    }
    if (!owner_present) {
        if (!tbs.storeMainCursor(app.alloc, &.{}, null)) {
            failFlush(app);
            return;
        }
        tbs.stageCursorLayerGrid(surface_id);
    }
    traceRender(app, "event=layout_stage surface={d} layers={d} metadata_bytes={d}\n", .{ surface_id, count, app.layout_budget.live_bytes.load(.monotonic) });
    // Layout-only updates must request paint as well as publish placement — of
    // the surface the layout belongs to. An external surface's layout is not a
    // visual change on the main window, and the flag drives a whole-main-window
    // InvalidateRect; the external ROW path has always kept out of it for the
    // same reason. Grid 1 has no needs_redraw of its own, so it uses the flag.
    if (app.external_windows.get(surface_id)) |ext_win| {
        ext_win.needs_redraw = true;
        ext_win.surf.flush_needs_invalidate = true;
    } else {
        app.surf.flush_needs_invalidate = true;
    }
}

/// Run after row publication and before placement publication, under app.mu.
/// Moving a layer preserves its rows, but invalidates cached surface pixels.
fn invalidateMovedLayersLocked(app: *App, tbs: *app_mod.TripleBufferedSurface) void {
    const staged = tbs.flush_layers orelse return;
    for (staged.slice(), 0..) |layer, index| {
        if (index == 0) continue;
        const state = app.layer_grids.get(layer.grid_id) orelse continue;
        var unchanged = false;
        for (tbs.committed_layers.slice()) |prev| {
            if (prev.grid_id != layer.grid_id) continue;
            unchanged = prev.x_px == layer.x_px and prev.y_px == layer.y_px and
                prev.rows == layer.rows and prev.cols == layer.cols and
                prev.z == layer.z and prev.follows_scroll == layer.follows_scroll;
            break;
        }
        if (unchanged) continue;
        state.needs_full_redraw = true;
        state.pending_scroll = null;
        state.dirty = true;
    }
}

/// Stage destruction until the layout that removes this grid commits.
pub fn onGridDestroy(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    // Outside a flush bracket there is no on_flush_end to publish against, and
    // onFlushBegin clears this list -- a staged destroy would simply be thrown
    // away. The core uses that form on session reset, where the grids are
    // already gone and the storage has to be released now or never.
    if (!app.core_flush_active.load(.acquire)) {
        traceRender(app, "event=destroy_now grid={d}\n", .{grid_id});
        if (app.layer_grids.fetchRemove(grid_id)) |kv| {
            kv.value.deinit(app.alloc);
            app.alloc.destroy(kv.value);
        }
        return;
    }
    traceRender(app, "event=destroy_stage grid={d}\n", .{grid_id});
    app.pending_grid_destroys.append(app.alloc, grid_id) catch {
        failFlush(app);
    };
}

/// True when the main surface places `grid_id` as one of its layers. The
/// staged list is consulted too, because the layout for a newly placed grid
/// arrives in the same bracket as that grid's first rows. Caller must hold
/// `app.mu`.
fn mainSurfaceOwnsGridLocked(app: *App, grid_id: i64) bool {
    if (app.surf.tbs.flush_layers) |staged| {
        for (staged.slice()) |l| {
            if (l.grid_id == grid_id) return true;
        }
        return false;
    }
    for (app.surf.tbs.committed_layers.slice()) |l| {
        if (l.grid_id == grid_id) return true;
    }
    return false;
}

fn externalSurfaceForGridLocked(app: *App, grid_id: i64) ?*app_mod.ExternalWindow {
    var it = app.external_windows.valueIterator();
    while (it.next()) |entry| {
        const ext = entry.*;
        if (ext.is_pending_close) continue;
        const layers = ext.surf.tbs.flush_layers orelse ext.surf.tbs.committed_layers;
        for (layers.slice()) |layer| {
            if (layer.grid_id == grid_id) return ext;
        }
    }
    return null;
}

/// Which surface owns one grid's per-flush work.
pub const GridRoute = union(enum) {
    /// Grid 1, the main window's own root.
    main_root,
    /// A float or split the main window places as a layer.
    main_layer,
    /// The grid is rendered as its own external surface.
    external_root: *app_mod.ExternalWindow,
    /// Another external surface places this grid as a layer.
    external_layer: *app_mod.ExternalWindow,
    /// No surface places this grid yet; the ABI requires tolerating it.
    unplaced,
};

/// Resolve `grid_id` to the surface that owns its work right now.
/// Caller must hold `app.mu`.
///
/// Rows, cursor and row shifts each asked this separately and the answers
/// drifted: the row and cursor paths treat a window that is closing as
/// unregistered so a grid moving out of its own window follows its work to
/// whichever surface now places it, while the shift path consulted the window
/// map alone, handed such a grid to the external path, and had it refused there
/// as pending-close — failing the whole flush once per fast-path scroll until
/// the UI thread drained the close. One rule, every caller.
fn resolveGridRouteLocked(app: *App, grid_id: i64) GridRoute {
    if (grid_id == 1) return .main_root;
    if (app.external_windows.get(grid_id)) |w| {
        if (!w.is_pending_close) return .{ .external_root = w };
    }
    // Main before host, matching the order the row path's layer store uses.
    if (mainSurfaceOwnsGridLocked(app, grid_id)) return .main_layer;
    if (externalSurfaceForGridLocked(app, grid_id)) |host| return .{ .external_layer = host };
    return .unplaced;
}

/// The external window that shows `grid_id` — as its own root or as a layer
/// it hosts — with that window's root grid id, or null when the main window
/// shows it. The flush routing's rule, so UI-thread decisions (which window
/// to activate, whose scrollbar to update) answer the same way; the staged
/// layout counts, because the cursor can enter a float in the flush that
/// places it. Caller must hold `app.mu`.
pub fn externalWindowShowingGridLocked(app: *App, grid_id: i64) ?struct { win: *app_mod.ExternalWindow, root_grid_id: i64 } {
    return switch (resolveGridRouteLocked(app, grid_id)) {
        .external_root => |w| .{ .win = w, .root_grid_id = grid_id },
        .external_layer => |host| {
            var it = app.external_windows.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == host) return .{ .win = host, .root_grid_id = entry.key_ptr.* };
            }
            return null;
        },
        .main_root, .main_layer, .unplaced => null,
    };
}

/// Store one row for a grid the main surface draws as a non-root layer.
/// Returns true when the row was consumed here. Caller must hold `app.mu`;
/// onVerticesRow already does, and `std.Io.Mutex` is not reentrant.
fn storeMainSurfaceLayerRowLocked(
    app: *App,
    grid_id: i64,
    row: u32,
    verts: []const app_mod.Vertex,
    total_rows: u32,
    total_cols: u32,
    route: GridRoute,
) bool {
    // The route is resolved once per row by the caller; re-deriving it here
    // would rescan the main surface's layers and every external surface's a
    // second time on the row hot path.
    const ext: ?*app_mod.ExternalWindow = switch (route) {
        .external_layer => |host| host,
        .main_root, .main_layer => null,
        .external_root, .unplaced => return false,
    };
    traceRender(app, "event=row_route surface={d} grid={d} row={d} vertices={d} rows={d} cols={d}\n", .{ if (ext) |host| traceExternalSurfaceId(host, grid_id) else @as(i64, 1), grid_id, row, verts.len, total_rows, total_cols });
    if (ext) |host| {
        host.needs_redraw = true;
        host.surf.flush_needs_invalidate = true;
    }

    // The row belongs to this path, so an allocation failure must not fall
    // through to the external-window path. Abort the flush and have the core
    // re-send instead, and still report the row consumed.
    const gop = app.layer_grids.getOrPut(app.alloc, grid_id) catch {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return true;
    };
    if (!gop.found_existing) {
        const created = app.alloc.create(app_mod.LayerGridState) catch {
            _ = app.layer_grids.remove(grid_id);
            core.zonvie_core_force_resend_locked(app.corep);
            failFlush(app);
            return true;
        };
        created.* = .{};
        gop.value_ptr.* = created;
    }
    const accepted = gop.value_ptr.*.stageRow(app.alloc, row, verts, total_rows, total_cols);
    traceRender(app, "event=row_staged grid={d} row={d} accepted={}\n", .{ grid_id, row, accepted });
    if (!accepted) {
        // Nothing was published, so the layer keeps its previous frame until
        // the core re-sends this one.
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
    }
    return true;
}
