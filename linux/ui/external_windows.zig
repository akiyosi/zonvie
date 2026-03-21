// external_windows.zig — External grid window management for Linux frontend.
//
// Each external grid (ext_windows) gets a separate GtkWindow + GtkGLArea
// with shared GL context and its own TripleBufferedSurface.
//
// TODO: Implement full external window lifecycle:
// - Create GtkWindow + GLArea with shared GL context
// - Route vertex updates via grid_id
// - Handle window close/destroy
// - Support window move/exchange/rotate operations

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const applog = app_mod.applog;

// GTK functions used by external windows (resolved at link time)
extern "c" fn gtk_window_new() ?*anyopaque;
extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;
extern "c" fn gtk_window_set_default_size(window: *anyopaque, width: c_int, height: c_int) void;
extern "c" fn gtk_window_set_child(window: *anyopaque, child: *anyopaque) void;
extern "c" fn gtk_window_present(window: *anyopaque) void;
extern "c" fn gtk_window_destroy(window: *anyopaque) void;
extern "c" fn gtk_gl_area_new() ?*anyopaque;
extern "c" fn gtk_gl_area_set_required_version(area: *anyopaque, major: c_int, minor: c_int) void;

/// Create an external window for the given grid.
pub fn createExternalWindow(app: *App, grid_id: i64, win_id: i64, rows: u32, cols: u32) bool {
    _ = win_id;

    // Create a new GtkWindow
    const win = gtk_window_new() orelse return false;

    gtk_window_set_title(win, "zonvie (external)");

    // Size based on grid dimensions
    const w: c_int = @intCast(cols * app.cell_w_px);
    const h: c_int = @intCast(rows * (app.cell_h_px + app.linespace_px));
    gtk_window_set_default_size(win, w, h);

    // Create GLArea
    const gl_area = gtk_gl_area_new() orelse return false;
    gtk_gl_area_set_required_version(gl_area, 4, 5);
    gtk_window_set_child(win, gl_area);

    // Register in external_windows map
    var ext = app_mod.ExternalWindow{
        .gtk_window = win,
        .gl_area_ext = gl_area,
        .rows = rows,
        .cols = cols,
    };
    _ = &ext;

    app.external_windows.put(app.alloc, grid_id, ext) catch return false;

    gtk_window_present(win);
    return true;
}

/// Destroy an external window for the given grid.
pub fn destroyExternalWindow(app: *App, grid_id: i64) void {
    if (app.external_windows.fetchRemove(grid_id)) |kv| {
        var ext = kv.value;
        if (ext.gtk_window) |win| {
            gtk_window_destroy(win);
        }
        ext.deinit(app.alloc);
    }
}
