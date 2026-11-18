//! `:set guifont=*`: the font is picked in Neovim itself. There is no font
//! dialog without a toolkit, and Neovim has the pieces for one: the
//! installed monospace families go through vim.ui.select, the size through
//! vim.ui.input, and the answer is set as 'guifont'. Main thread, except
//! request.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const glib = @import("glib.zig");
const fc = @import("fc.zig");
const applog = @import("app_log.zig");

/// The most families the list offers.
const max_families = 400;

/// From on_guifont (core thread) when the payload is "*".
pub fn request(app: *App) void {
    _ = glib.g_idle_add(&idleOpen, app);
}

fn idleOpen(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.mu.lockUncancelable(clock.io());
    var family: [129]u8 = undefined;
    const n = app.preedit_family_len;
    @memcpy(family[0..n], app.preedit_family[0..n]);
    const pt = app.font_pt;
    const drawn = app.surface.committedLayers().len != 0;
    app.mu.unlock(clock.io());
    const cp = app.corep orelse return 0;

    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    const ask: ?[]const u8 = if (drawn and n != 0) pickCommand(arena.allocator(), family[0..n], pt) else null;
    // 'guifont' is "*" now: it goes back to the font in use, so a cancelled
    // pick leaves a value that names a font. With a pick to follow, this
    // write and then the pick are the next two guifont broadcasts
    // (App.font_pick).
    if (ask != null) app.font_pick.store(.restoring, .release);
    if (!writeGuifont(app, family[0..n], pt)) {
        app.font_pick.store(.none, .release);
        return 0;
    }
    if (ask) |lua| core.zonvie_core_send_command(cp, lua.ptr, lua.len);
    return 0;
}

/// The command that asks for a family, then a size, and sets 'guifont' to
/// the answer. Null without a family to offer.
fn pickCommand(a: std.mem.Allocator, family: []const u8, pt: f32) ?[]const u8 {
    const families = listFamilies(a) catch return null;
    if (families.len == 0) return null;
    var lua: std.ArrayListUnmanaged(u8) = .empty;
    lua.appendSlice(a, "lua local f={") catch return null;
    for (families) |name| {
        appendLuaString(&lua, a, name) catch return null;
        lua.append(a, ',') catch return null;
    }
    lua.print(a,
        \\}};vim.ui.select(f,{{prompt='Font (now {s}):'}},function(c) if not c then return end;
        \\vim.ui.input({{prompt='Size (pt): ',default='{d}'}},function(s) local n=tonumber(s);
        \\if not n or n<1 then return end;vim.o.guifont=c:gsub(',','\\,')..':h'..n end) end)
    , .{ luaSafe(a, family) catch return null, @max(1, @as(i32, @intFromFloat(@round(pt)))) }) catch return null;
    // One line: nvim_command takes no newline.
    for (lua.items) |*ch| {
        if (ch.* == '\n') ch.* = ' ';
    }
    return lua.items;
}

/// `s` as a Lua string literal.
fn appendLuaString(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"', '\\' => try out.appendSlice(a, &.{ '\\', ch }),
        '\n', '\r' => try out.append(a, ' '),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

/// `s` with what would end a single-quoted Lua string taken out.
fn luaSafe(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try a.dupe(u8, s);
    for (out) |*ch| {
        if (ch.* == '\'' or ch.* == '\\' or ch.* == '\n') ch.* = ' ';
    }
    return out;
}

/// The installed monospace families, sorted, each once.
fn listFamilies(a: std.mem.Allocator) ![]const []const u8 {
    const pattern = fc.FcPatternCreate() orelse return error.OutOfMemory;
    defer fc.FcPatternDestroy(pattern);
    _ = fc.FcPatternAddInteger(pattern, fc.FC_SPACING, fc.FC_MONO);
    const objects = fc.FcObjectSetBuild(fc.FC_FAMILY, @as(?[*:0]const u8, null)) orelse return error.OutOfMemory;
    defer fc.FcObjectSetDestroy(objects);
    const set = fc.FcFontList(null, pattern, objects) orelse return error.OutOfMemory;
    defer fc.FcFontSetDestroy(set);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    const fonts = set.fonts orelse return names.items;
    for (fonts[0..@intCast(@max(0, set.nfont))]) |p| {
        var s: [*c]fc.FcChar8 = undefined;
        if (fc.FcPatternGetString(p, fc.FC_FAMILY, 0, &s) != .match) continue;
        try names.append(a, try a.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(s)))));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lt);
    var n: usize = 0;
    for (names.items) |name| {
        if (n != 0 and std.mem.eql(u8, names.items[n - 1], name)) continue;
        if (n == max_families) break;
        names.items[n] = name;
        n += 1;
    }
    return names.items[0..n];
}

/// Sets 'guifont' to `family` at `pt`. False when nothing was written.
fn writeGuifont(app: *App, family: []const u8, pt: f32) bool {
    const cp = app.corep orelse return false;
    if (family.len == 0) return false;
    var buf: [320]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (family) |ch| {
        if (ch == ',') w.writeByte('\\') catch return false;
        w.writeByte(ch) catch return false;
    }
    w.print(":h{d}", .{@max(1, @as(i32, @intFromFloat(@round(pt))))}) catch return false;
    const value = w.buffered();
    applog.appLog("[font_picker] guifont={s}\n", .{value});
    const name = "guifont";
    core.zonvie_core_set_option_value(cp, name.ptr, name.len, value.ptr, value.len);
    return true;
}
