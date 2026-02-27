// rpc_session.zig — RPC dispatch, event loop, and session management.
// Extracted from nvim_core.zig. Free functions take *Core as first parameter.

const std = @import("std");
const c_api = @import("c_api.zig");
const grid_mod = @import("grid.zig");
const highlight = @import("highlight.zig");
const mp = @import("msgpack.zig");
const rpc = @import("rpc_encode.zig");
const redraw = @import("redraw_handler.zig");
const config = @import("config.zig");
const Logger = @import("log.zig").Logger;
const flush = @import("flush.zig");
const nvim_core = @import("nvim_core.zig");
const Core = nvim_core.Core;
const Callbacks = nvim_core.Callbacks;

pub const PipeReader = struct {
    file: std.fs.File,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(self: *PipeReader) !void {
        if (self.start < self.end) return;
        const n = try self.file.read(&self.buf);
        self.start = 0;
        self.end = n;
    }

    pub fn read(self: *PipeReader, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        var out_i: usize = 0;
        while (out_i < dest.len) {
            try self.fill();
            if (self.end == 0) break; // EOF

            const avail = self.end - self.start;
            const take = @min(avail, dest.len - out_i);
            std.mem.copyForwards(u8, dest[out_i .. out_i + take], self.buf[self.start .. self.start + take]);
            self.start += take;
            out_i += take;

            if (take == 0) break;
        }
        return out_i;
    }

    pub fn readByte(self: *PipeReader) !u8 {
        var one: [1]u8 = undefined;
        const n = try self.read(one[0..]);
        if (n != 1) return error.EndOfStream;
        return one[0];
    }

    pub fn readNoEof(self: *PipeReader, dest: []u8) !void {
        var off: usize = 0;
        while (off < dest.len) {
            const n = try self.read(dest[off..]);
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }
};

pub const CwdOwner = struct {
    open: bool = false,
    dir: std.fs.Dir = undefined,

    pub fn close(self: *CwdOwner) void {
        if (self.open) {
            self.dir.close();
            self.open = false;
        }
    }

    pub fn openPreferred(self: *CwdOwner, alloc: std.mem.Allocator, log: *Logger) void {
        self.close();
    
        // Prefer $HOME when present.
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch null;
        defer if (home) |s| alloc.free(s);
    
        if (home) |home_path| {
            if (std.fs.openDirAbsolute(home_path, .{})) |d| {
                self.dir = d;
                self.open = true;
                log.write("child cwd set to HOME: {s}\n", .{home_path});
                return;
            } else |e| {
                log.write("openDirAbsolute(HOME) failed: {any} (HOME={s})\n", .{ e, home_path });
            }
        } else {
            log.write("HOME is not set; leaving child cwd as default\n", .{});
        }
    }

    pub fn applyToChild(self: *CwdOwner, child: *std.process.Child) void {
        const CwdT = @TypeOf(child.cwd_dir);

        comptime {
            if (!(CwdT == ?std.fs.Dir or CwdT == std.fs.Dir or CwdT == ?*std.fs.Dir or CwdT == *std.fs.Dir)) {
                @compileError("Unsupported std.process.Child.cwd_dir type: " ++ @typeName(CwdT));
            }
        }

        if (!self.open) return;

        if (comptime CwdT == ?std.fs.Dir) {
            child.cwd_dir = self.dir;
            return;
        }
        if (comptime CwdT == std.fs.Dir) {
            child.cwd_dir = self.dir;
            return;
        }
        if (comptime CwdT == ?*std.fs.Dir) {
            child.cwd_dir = &self.dir;
            return;
        }
        if (comptime CwdT == *std.fs.Dir) {
            child.cwd_dir = &self.dir;
            return;
        }
    }
};

pub fn pumpStderr(self: *Core, f: std.fs.File) void {
    var buf: [4096]u8 = undefined;
    while (!self.stop_flag.load(.seq_cst)) {
        const n = f.read(&buf) catch break;
        if (n == 0) break;

        // Log stderr output
        if (self.cb.on_log) |logfn| logfn(self.ctx, buf[0..n].ptr, n);

        // SSH mode: detect password prompt in stderr
        if (self.is_ssh_mode and !self.ssh_auth_done.load(.seq_cst)) {
            const data = buf[0..n];
            // Check for common password prompts (case-insensitive check for "password")
            if (containsPasswordPrompt(data)) {
                self.log.write("SSH: detected password prompt in stderr\n", .{});
                if (self.cb.on_ssh_auth_prompt) |cb| {
                    self.ssh_auth_pending.store(true, .seq_cst);
                    cb(self.ctx, "SSH Password:", 13);
                }
            }
        }
    }
}

/// Check if data contains a password prompt (case-insensitive)
pub fn containsPasswordPrompt(data: []const u8) bool {
    // Convert to lowercase for comparison
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 1) {
        // Check for "password" (case-insensitive)
        const slice = data[i .. i + 8];
        if (eqlIgnoreCase(slice, "password")) {
            return true;
        }
    }
    // Also check for "passphrase"
    i = 0;
    while (i + 10 <= data.len) : (i += 1) {
        const slice = data[i .. i + 10];
        if (eqlIgnoreCase(slice, "passphrase")) {
            return true;
        }
    }
    return false;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

pub fn logEnvHints(self: *Core) void {
    const cwd = std.process.getCwdAlloc(self.alloc) catch null;
    defer if (cwd) |s| self.alloc.free(s);
    if (cwd) |s|
        self.log.write("cwd: {s}\n", .{s})
    else
        self.log.write("cwd: (unknown)\n", .{});

    const path_env = std.process.getEnvVarOwned(self.alloc, "PATH") catch null;
    defer if (path_env) |s| self.alloc.free(s);
    if (path_env) |s|
        self.log.write("PATH: {s}\n", .{s})
    else
        self.log.write("PATH: (missing)\n", .{});
}

pub fn handleRpcResponse(self: *Core, top: []mp.Value) void {
    // [type=1, msgid, error, result]
    if (top.len < 4) return;
    if (top[1] != .int) return;
    const id = top[1].int;

    const errv = top[2];
    const has_err = (errv != .nil);

    if (has_err) {
        self.log.write("rpc resp id={d} error={any}\n", .{ id, errv });
        // Clear quit_request_msgid if this was a failed quit request
        const pending_quit_id = self.quit_request_msgid.load(.acquire);
        if (pending_quit_id != 0 and id == pending_quit_id) {
            self.quit_request_msgid.store(0, .release);
            // On error, still try to quit (fallback)
            if (self.cb.on_quit_requested) |cb| {
                cb(self.ctx, 0); // Assume no unsaved on error
            }
        }
        return;
    }

    // Check if this is nvim_get_api_info response
    // Response format: [channel_id, api_metadata]
    if (self.get_api_info_msgid != null and id == self.get_api_info_msgid.? and self.channel_id == null) {
        if (top[3] == .arr and top[3].arr.len >= 1) {
            const result = top[3].arr;
            if (result[0] == .int) {
                self.channel_id = result[0].int;
                self.log.write("channel_id extracted: {d}\n", .{self.channel_id.?});

                // Setup clipboard after getting channel_id
                setupClipboard(self);
            }
        }
        return;
    }

    // Check if this is quit request response
    const pending_quit_id = self.quit_request_msgid.load(.acquire);
    if (pending_quit_id != 0 and id == pending_quit_id) {
        self.quit_request_msgid.store(0, .release);

        // Log the response type for debugging
        self.log.write("quit request response: result type={s}\n", .{@tagName(top[3])});

        // Result is boolean: true if there are unsaved buffers
        const has_unsaved: bool = switch (top[3]) {
            .bool => |b| b,
            .int => |i| i != 0,
            else => false,
        };

        self.log.write("quit request response: has_unsaved={}\n", .{has_unsaved});

        // Notify frontend via callback
        if (self.cb.on_quit_requested) |cb| {
            cb(self.ctx, if (has_unsaved) 1 else 0);
        } else {
            // No callback - proceed with :qa (may fail if unsaved)
            self.quitConfirmed(false);
        }
        return;
    }
}

pub fn handleRpcRequest(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
    // [type=0, msgid, method, params]
    _ = arena;
    if (top.len < 4) return;
    if (top[1] != .int) return;
    if (top[2] != .str) return;

    const msgid = top[1].int;
    const method = top[2].str;

    self.log.write("rpc request: method={s} msgid={d}\n", .{ method, msgid });

    if (std.mem.eql(u8, method, "zonvie.get_clipboard")) {
        handleClipboardGet(self, msgid, top[3]);
    } else if (std.mem.eql(u8, method, "zonvie.set_clipboard")) {
        handleClipboardSet(self, msgid, top[3]);
    } else if (std.mem.eql(u8, method, "win_move_cursor")) {
        handleWinMoveCursor(self, msgid, top[3]);
    } else {
        // Unknown method - send error response
        sendRpcErrorResponse(self, msgid, "Unknown method") catch |e| {
            self.log.write("sendRpcErrorResponse failed: {any}\n", .{e});
        };
    }
}

pub fn handleClipboardGet(self: *Core, msgid: i64, params: mp.Value) void {
    // params = [register_name] (e.g. "+" or "*")
    var register: []const u8 = "+";
    if (params == .arr and params.arr.len >= 1) {
        if (params.arr[0] == .str) {
            register = params.arr[0].str;
        }
    }

    self.log.write("clipboard get: register={s}\n", .{register});

    // Call frontend callback
    if (self.cb.on_clipboard_get) |cb| {
        var buf: [64 * 1024]u8 = undefined;
        var out_len: usize = 0;

        const result = cb(self.ctx, register.ptr, &buf, &out_len, buf.len);
        if (result != 0) {
            // Success - send clipboard content
            sendClipboardGetResponse(self, msgid, buf[0..out_len]) catch |e| {
                self.log.write("sendClipboardGetResponse failed: {any}\n", .{e});
            };
            return;
        }
    }

    // Failure - send empty result
    sendClipboardGetResponse(self, msgid, "") catch |e| {
        self.log.write("sendClipboardGetResponse (empty) failed: {any}\n", .{e});
    };
}

pub fn handleClipboardSet(self: *Core, msgid: i64, params: mp.Value) void {
    // params = [register_name, lines_array]
    if (params != .arr or params.arr.len < 2) {
        sendRpcErrorResponse(self, msgid, "Invalid params") catch {};
        return;
    }

    var register: []const u8 = "+";
    if (params.arr[0] == .str) {
        register = params.arr[0].str;
    }

    self.log.write("clipboard set: register={s}\n", .{register});

    // Convert lines array to newline-separated string
    var content_buf: [64 * 1024]u8 = undefined;
    var content_len: usize = 0;

    if (params.arr[1] == .arr) {
        const lines = params.arr[1].arr;
        for (lines, 0..) |line, i| {
            if (line == .str) {
                const line_str = line.str;
                if (content_len + line_str.len + 1 < content_buf.len) {
                    @memcpy(content_buf[content_len..][0..line_str.len], line_str);
                    content_len += line_str.len;
                    // Add newline between lines (not after last)
                    if (i < lines.len - 1) {
                        content_buf[content_len] = '\n';
                        content_len += 1;
                    }
                }
            }
        }
    }

    // Call frontend callback
    if (self.cb.on_clipboard_set) |cb| {
        const result = cb(self.ctx, register.ptr, &content_buf, content_len);
        sendRpcBoolResponse(self, msgid, result != 0) catch |e| {
            self.log.write("sendRpcBoolResponse failed: {any}\n", .{e});
        };
        return;
    }

    sendRpcErrorResponse(self, msgid, "Clipboard not available") catch {};
}

pub fn sendRpcErrorResponse(self: *Core, msgid: i64, err_msg: []const u8) !void {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packStr(&buf, self.alloc, err_msg); // error
    try rpc.packNil(&buf, self.alloc); // result

    try self.sendRaw(buf.items);
    self.log.write("rpc error response sent: msgid={d} err={s}\n", .{ msgid, err_msg });
}

pub fn sendRpcBoolResponse(self: *Core, msgid: i64, value: bool) !void {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packNil(&buf, self.alloc); // no error
    try rpc.packBool(&buf, self.alloc, value); // result

    try self.sendRaw(buf.items);
    self.log.write("rpc bool response sent: msgid={d} value={}\n", .{ msgid, value });
}

pub fn handleWinMoveCursor(self: *Core, msgid: i64, params: mp.Value) void {
    // params: [direction, count]
    // direction: 0=down, 1=up, 2=right, 3=left
    // Returns: Integer (Neovim window handle of target window)
    var direction: i32 = 0;
    var count: i32 = 1;

    if (params == .arr and params.arr.len >= 2) {
        if (params.arr[0] == .int) direction = @intCast(params.arr[0].int);
        if (params.arr[1] == .int) count = @intCast(params.arr[1].int);
    }

    self.log.write("[win_move_cursor] direction={d} count={d}\n", .{ direction, count });

    var target_win: i64 = 0;
    if (self.cb.on_win_move_cursor) |cb| {
        target_win = cb(self.ctx, direction, count);
    }

    sendRpcIntResponse(self, msgid, target_win) catch |e| {
        self.log.write("sendRpcIntResponse failed: {any}\n", .{e});
    };
}

pub fn sendRpcIntResponse(self: *Core, msgid: i64, value: i64) !void {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packNil(&buf, self.alloc); // no error
    try rpc.packInt(&buf, self.alloc, value); // result

    try self.sendRaw(buf.items);
    self.log.write("rpc int response sent: msgid={d} value={d}\n", .{ msgid, value });
}

pub fn sendClipboardGetResponse(self: *Core, msgid: i64, content: []const u8) !void {
    // Response format: [[line1, line2, ...], regtype]
    // regtype: "v" (charwise), "V" (linewise)
    var buf: rpc.Buf = .empty;
    defer buf.deinit(self.alloc);

    try rpc.packArray(&buf, self.alloc, 4);
    try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
    try rpc.packInt(&buf, self.alloc, msgid);
    try rpc.packNil(&buf, self.alloc); // no error

    // Result: [[lines...], regtype]
    try rpc.packArray(&buf, self.alloc, 2);

    // Split content by newlines into array
    var line_count: usize = 1;
    for (content) |c| {
        if (c == '\n') line_count += 1;
    }

    try rpc.packArray(&buf, self.alloc, line_count);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n') {
            try rpc.packStr(&buf, self.alloc, content[line_start..i]);
            line_start = i + 1;
        }
    }

    // regtype: "V" if ends with newline, "v" otherwise
    const regtype: []const u8 = if (content.len > 0 and content[content.len - 1] == '\n') "V" else "v";
    try rpc.packStr(&buf, self.alloc, regtype);

    try self.sendRaw(buf.items);
    self.log.write("clipboard get response sent: msgid={d} lines={d} regtype={s}\n", .{ msgid, line_count, regtype });
}

pub fn setupClipboard(self: *Core) void {
    if (self.clipboard_setup_done) return;
    if (self.channel_id == null) return;

    const channel = self.channel_id.?;

    // Build Lua code to setup vim.g.clipboard
    // Use vim.schedule to ensure it runs after current RPC processing
    var lua_buf: [2048]u8 = undefined;
    const lua_code = std.fmt.bufPrint(&lua_buf,
        \\vim.g.zonvie_channel = {d}
        \\vim.schedule(function()
        \\  vim.g.clipboard = {{
        \\    name = 'zonvie',
        \\    copy = {{
        \\      ['+'] = function(lines, regtype)
        \\        return vim.rpcrequest({d}, 'zonvie.set_clipboard', '+', lines)
        \\      end,
        \\      ['*'] = function(lines, regtype)
        \\        return vim.rpcrequest({d}, 'zonvie.set_clipboard', '*', lines)
        \\      end,
        \\    }},
        \\    paste = {{
        \\      ['+'] = function()
        \\        return vim.rpcrequest({d}, 'zonvie.get_clipboard', '+')
        \\      end,
        \\      ['*'] = function()
        \\        return vim.rpcrequest({d}, 'zonvie.get_clipboard', '*')
        \\      end,
        \\    }},
        \\  }}
        \\end)
    , .{ channel, channel, channel, channel, channel }) catch {
        self.log.write("setupClipboard: bufPrint failed\n", .{});
        return;
    };

    self.requestExecLua(lua_code) catch |e| {
        self.log.write("setupClipboard: requestExecLua failed: {any}\n", .{e});
        return;
    };

    self.clipboard_setup_done = true;
    self.log.write("clipboard setup done (channel={d})\n", .{channel});
}

pub fn handleRpcNotification(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
    if (top.len < 3) return;
    if (top[1] != .str or top[2] != .arr) return;

    const method = top[1].str;
    const params = top[2].arr;

    if (std.mem.eql(u8, method, "redraw")) {
        // Store current thread ID to detect re-entrant updateLayoutPx calls from this thread.
        self.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);

        // Lock grid_mu to prevent concurrent access from UI thread during redraw.
        // NOTE: All frontend callbacks invoked below (on_vertices_*, on_guifont,
        // on_linespace, on_external_window*, on_ime_off, on_cursor_grid_changed)
        // execute while grid_mu is held. Callbacks MUST NOT call
        // zonvie_core_get_* or other APIs that acquire grid_mu.
        self.grid_mu.lock();

        var fctx = flush.FlushCtx{ .core = self };
        redraw.handleRedraw(
            &self.grid,
            &self.hl,
            arena,
            params,
            &self.log,
            &fctx,
            flush.FlushCtx.onFlush,
            &fctx,
            flush.FlushCtx.onGuifont,
            &fctx,
            flush.FlushCtx.onLinespace,
            flush.FlushCtx.onSetTitle,
            flush.FlushCtx.onDefaultColors,
        ) catch |re| {
            self.log.write("redraw err: {any}\n", .{re});
        };

        // Update cmdline grid BEFORE checking external windows
        // (cmdline is rendered as an external grid)
        self.notifyCmdlineChanges();

        // Handle popupmenu changes (creates external float window via Lua API)
        self.notifyPopupmenuChanges();

        // Handle message changes (ext_messages)
        self.notifyMessageChanges();

        // Handle tabline changes (ext_tabline)
        self.notifyTablineChanges();

        // Process pending ext_windows grid resizes (from win_resize events).
        // win_resize is Neovim's request to the UI. The UI decides the actual
        // size and responds with try_resize_grid. Neovim then confirms with grid_resize.
        for (self.grid.pending_grid_resizes.items) |resize| {
            if (!self.known_external_grids.contains(resize.grid_id)) {
                // NEW grid: Use a reasonable initial size for new external windows.
                // Neovim's proposed size is based on terminal layout (e.g. height=2)
                // which is too small for an OS window. Use half the main window.
                const init_rows = @max(resize.height, self.grid.rows / 2);
                const init_cols = @max(resize.width, self.grid.cols / 2);
                self.requestTryResizeGrid(resize.grid_id, init_rows, init_cols);

                // Mark grid as pending initial resize. Window creation will be
                // deferred in notifyExternalWindowChanges until Neovim responds
                // with grid_resize matching the requested dimensions.
                self.grid.pending_ext_window_grids.put(self.alloc, resize.grid_id, .{
                    .grid_id = resize.grid_id,
                    .width = init_cols,
                    .height = init_rows,
                }) catch {};
            } else {
                // EXISTING grid: Neovim is requesting a resize (e.g. <C-w>+/-/>/<).
                // Honor the request by calling try_resize_grid with Neovim's values.
                self.requestTryResizeGrid(resize.grid_id, resize.height, resize.width);
            }
        }
        self.grid.pending_grid_resizes.clearRetainingCapacity();

        // Process pending ext_windows layout operations (win_move, win_exchange, etc.)
        // These are deferred to the end of the redraw batch (not immediate) because they
        // depend on grid state that may be updated earlier in the same batch.
        // The frontend callbacks run synchronously here on the core thread.
        for (self.grid.pending_win_ops.items) |op| {
            switch (op.op) {
                .move => {
                    if (self.cb.on_win_move) |cb| cb(self.ctx, op.grid_id, op.win, op.flags_or_direction);
                },
                .exchange => {
                    if (self.cb.on_win_exchange) |cb| cb(self.ctx, op.grid_id, op.win, op.count);
                },
                .rotate => {
                    if (self.cb.on_win_rotate) |cb| cb(self.ctx, op.grid_id, op.win, op.flags_or_direction, op.count);
                },
                .resize_equal => {
                    if (self.cb.on_win_resize_equal) |cb| cb(self.ctx);
                },
            }
        }
        self.grid.pending_win_ops.clearRetainingCapacity();

        // ext_windows: Promote external grids back to composited when the main
        // window has no composited editor windows left.
        //
        // This handles the case where the user closes the last composited window
        // in a split layout (e.g. :close). Neovim sends win_close for the closed
        // grid and win_pos for the remaining grid(s) in the same redraw batch.
        // After processing the batch, if no editor windows remain composited in
        // the main window, we promote external grids back to composited so the
        // user sees them in the main window instead of only in separate OS windows.
        //
        // notifyExternalWindowChanges() (below) naturally detects the removal from
        // external_grids and fires on_external_window_close so the frontend closes
        // the external OS window.
        //
        // IMPORTANT: This must run BEFORE the grid 2 auto-compositing fallback
        // below, because win_close removes grid 2 from win_pos, and the fallback
        // would re-add it — making the promotion check think there's still a
        // composited editor window and skipping promotion entirely.
        var ext_windows_promoted = false;
        if (self.ext_windows_enabled and self.grid.ext_windows_grids.count() > 0) {
            // Detect whether the main grid has any composited editor windows.
            // Skip: grid 1 (global/status), floats (in win_layer), external grids,
            // and grids without a real Neovim window handle (not in grid_win_ids).
            var has_composited_editor_win = false;
            var only_grid2_composited = true;
            {
                var wp_it = self.grid.win_pos.keyIterator();
                while (wp_it.next()) |key_ptr| {
                    const gid = key_ptr.*;
                    if (gid == 1) continue;
                    if (self.grid.win_layer.contains(gid)) continue;
                    if (self.grid.external_grids.contains(gid)) continue;
                    if (!self.grid.grid_win_ids.contains(gid)) continue;
                    has_composited_editor_win = true;
                    if (gid != 2) only_grid2_composited = false;
                }
            }

            // If a composited editor window was closed in this batch and the
            // only remaining composited window is grid 2, treat grid 2 as a
            // Neovim fallback and remove it so promotion can proceed.
            // This handles the case where: user closes a promoted window →
            // Neovim re-composites grid 2 as default → we want to promote the
            // next external window instead of showing grid 2's empty buffer.
            if (has_composited_editor_win and self.grid.composited_win_closed and only_grid2_composited) {
                self.grid.hideWin(2);
                has_composited_editor_win = false;
                self.log.write("[ext_windows_promote] removed fallback grid 2 (composited_win_closed)\n", .{});
            }
            self.grid.composited_win_closed = false;

            if (!has_composited_editor_win) {
                // Main window is empty of editor windows. Collect promotion candidates.
                // Only consider grids in BOTH ext_windows_grids AND external_grids.
                // ext_windows_grids can contain win_hide'd grids (tab switch) that have
                // been removed from external_grids — those must not be promoted.
                const PromoteEntry = struct {
                    grid_id: i64,
                    win_id: i64,
                    row: u32,
                    col: u32,
                };

                // Find ONE grid to promote. Only promote a single grid to avoid
                // multiple external grids rendering on top of each other in the
                // main window. The remaining external windows stay as separate
                // OS windows.
                //
                // Selection: pick the first candidate that exists in BOTH
                // ext_windows_grids AND external_grids, preferring one with a
                // valid position (start_row >= 0). If none have valid positions,
                // fall back to (0,0).
                var promote_target: ?PromoteEntry = null;
                var fallback_target: ?PromoteEntry = null;
                {
                    var ew_it = self.grid.ext_windows_grids.iterator();
                    while (ew_it.next()) |entry| {
                        const gid = entry.key_ptr.*;
                        const wid = entry.value_ptr.*;

                        const ext_info = self.grid.external_grids.get(gid) orelse continue;

                        if (ext_info.start_row >= 0 and ext_info.start_col >= 0) {
                            // First candidate with valid position wins.
                            promote_target = .{
                                .grid_id = gid,
                                .win_id = wid,
                                .row = @intCast(ext_info.start_row),
                                .col = @intCast(ext_info.start_col),
                            };
                            break;
                        } else if (fallback_target == null) {
                            // Remember first candidate as fallback (position unknown).
                            fallback_target = .{
                                .grid_id = gid,
                                .win_id = wid,
                                .row = 0,
                                .col = 0,
                            };
                        }
                    }
                }

                // Use fallback if no candidate had a valid position.
                if (promote_target == null and fallback_target != null) {
                    promote_target = fallback_target;
                    self.log.write("[ext_windows_promote] fallback: promoting grid={d} at (0,0) (no valid position)\n", .{fallback_target.?.grid_id});
                }

                // Execute promotion of the single selected grid.
                if (promote_target) |p| {
                    // Remove from external tracking BEFORE calling setWinPos
                    // (setWinPos has guard: if external_grids.contains(grid_id) return)
                    _ = self.grid.external_grids.remove(p.grid_id);
                    _ = self.grid.ext_windows_grids.remove(p.grid_id);
                    _ = self.grid.external_grid_target_sizes.remove(p.grid_id);
                    _ = self.grid.pending_ext_window_grids.remove(p.grid_id);

                    self.grid.setWinPos(p.grid_id, p.win_id, p.row, p.col) catch |e| {
                        self.log.write("[ext_windows_promote] setWinPos grid={d} failed: {any}\n", .{ p.grid_id, e });
                    };
                    self.log.write("[ext_windows_promote] promoted grid={d} win={d} at ({d},{d})\n", .{ p.grid_id, p.win_id, p.row, p.col });

                    // Resize the promoted grid to fill the main window IMMEDIATELY
                    // so the grid content covers the entire main window (prevents
                    // "window in a window" visual). New cells are filled with
                    // spaces (default bg). Neovim will populate them when it
                    // processes the try_resize_grid request.
                    self.grid.resizeGrid(p.grid_id, self.grid.rows, self.grid.cols) catch |e| {
                        self.log.write("[ext_windows_promote] resizeGrid grid={d} failed: {any}\n", .{ p.grid_id, e });
                    };
                    self.requestTryResizeGridInternal(p.grid_id, self.grid.rows, self.grid.cols) catch |e| {
                        self.log.write("[ext_windows_promote] requestTryResizeGridInternal grid={d} failed: {any}\n", .{ p.grid_id, e });
                    };
                    self.log.write("[ext_windows_promote] resized+requested grid={d} to {d}x{d}\n", .{ p.grid_id, self.grid.rows, self.grid.cols });

                    ext_windows_promoted = true;
                    self.grid.markAllDirty();
                }
            }
        } else {
            // Clear the flag even when the promotion block was skipped
            // (e.g. ext_windows disabled or no ext_windows grids).
            self.grid.composited_win_closed = false;
        }

        // ext_windows: ensure grid 2 (default editor window) is composited.
        // With ext_windows, Neovim may not send win_pos for the default window.
        // If grid 2 has no win_pos and is not tracked as an ext_windows grid,
        // auto-position it at (0,0) so it gets rendered in the main window.
        //
        // Skip this if:
        //   - External grids were just promoted in this batch, OR
        //   - Another non-float editor grid is already composited (e.g. a
        //     previously promoted grid still occupying the main window).
        // In both cases grid 2 would overlap the promoted grid.
        if (!ext_windows_promoted) {
            if (!self.grid.win_pos.contains(2) and !self.grid.ext_windows_grids.contains(2)) {
                var has_other_editor_grid = false;
                {
                    var wp_chk = self.grid.win_pos.keyIterator();
                    while (wp_chk.next()) |key_ptr| {
                        const gid = key_ptr.*;
                        if (gid == 1 or gid == 2) continue;
                        if (self.grid.win_layer.contains(gid)) continue;
                        has_other_editor_grid = true;
                        break;
                    }
                }
                if (!has_other_editor_grid) {
                    self.grid.setWinPos(2, 1000, 0, 0) catch {};
                }
            }
        }

        // Check for external window changes and notify frontend
        const new_ext_grids = self.notifyExternalWindowChanges();

        // Generate and send vertices for all external grids
        // Force render if new grids were added (to show initial content)
        self.sendExternalGridVertices(new_ext_grids);

        // Check IME off request (from mode_change event)
        if (self.grid.ime_off_requested) {
            self.grid.ime_off_requested = false;
            if (self.msg_config.ime.disable_on_modechange) {
                if (self.cb.on_ime_off) |cb| {
                    cb(self.ctx);
                }
            }
        }

        self.grid_mu.unlock();
        self.redraw_thread_id.store(0, .seq_cst);
    } else if (std.mem.eql(u8, method, "zonvie_ime_off")) {
        // Custom RPC notification for IME off (user-invokable)
        if (self.cb.on_ime_off) |cb| {
            cb(self.ctx);
        }
    }
}

pub fn runLoop(self: *Core) void {
    // DEBUG: Log immediately at runLoop start
    if (self.cb.on_log) |logfn| {
        const msg = "[RUNLOOP] runLoop started!\n";
        logfn(self.ctx, msg.ptr, msg.len);
    }

    const nvim_path = self.nvim_path_owned orelse "nvim";

    // Check if this is a WSL or SSH command
    // WSL command format: "wsl.exe [-d distro] --shell-type login -- nvim --embed"
    // SSH command format: "ssh [-p port] [-i identity] user@host ..." or full path like "C:\...\ssh.exe ..."
    // SSH-ASKPASS format: "ssh-askpass ..." - SSH_ASKPASS already handled auth, skip waiting
    // CMD format: "cmd.exe /c ssh ..." - used on Windows to run SSH via shell
    // Shell format: "/bin/sh -c ..." - used for complex commands (e.g., devcontainer up && exec)
    const is_wsl = std.mem.startsWith(u8, nvim_path, "wsl");
    const is_ssh_askpass = std.mem.startsWith(u8, nvim_path, "ssh-askpass");
    const is_cmd = std.mem.startsWith(u8, nvim_path, "cmd");
    const is_shell = std.mem.startsWith(u8, nvim_path, "/bin/sh") or std.mem.startsWith(u8, nvim_path, "/bin/bash");
    // Check for devcontainer: "devcontainer exec ..." or "devcontainer.cmd exec ..."
    const is_devcontainer = std.mem.startsWith(u8, nvim_path, "devcontainer");
    // Check for SSH: starts with "ssh", contains "ssh.exe", or cmd.exe with ssh
    const contains_ssh_exe = std.mem.indexOf(u8, nvim_path, "ssh.exe") != null;
    const is_ssh = (std.mem.startsWith(u8, nvim_path, "ssh") and !is_ssh_askpass) or
        contains_ssh_exe or
        (is_cmd and std.mem.indexOf(u8, nvim_path, "ssh") != null);

    // Buffer for parsed arguments
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;

    if (is_wsl or is_ssh or is_ssh_askpass or is_cmd or is_devcontainer or is_shell) {
        // Parse command string into arguments (split by spaces, handle quotes and escapes)
        var i: usize = 0;
        while (i < nvim_path.len and argc < argv_buf.len) {
            // Skip leading spaces
            while (i < nvim_path.len and nvim_path[i] == ' ') : (i += 1) {}
            if (i >= nvim_path.len) break;

            var arg_start = i;
            var arg_end = i;

            if (nvim_path[i] == '\'' or nvim_path[i] == '"') {
                // Quoted argument - find closing quote (handle escaped quotes)
                const quote_char = nvim_path[i];
                i += 1;
                arg_start = i;
                while (i < nvim_path.len) {
                    if (nvim_path[i] == '\\' and i + 1 < nvim_path.len and nvim_path[i + 1] == quote_char) {
                        // Skip escaped quote (e.g., \" inside "..." or \' inside '...')
                        i += 2;
                    } else if (nvim_path[i] == quote_char) {
                        // Found unescaped closing quote
                        break;
                    } else {
                        i += 1;
                    }
                }
                arg_end = i;
                if (i < nvim_path.len) i += 1; // Skip closing quote
            } else {
                // Unquoted argument - find next space
                while (i < nvim_path.len and nvim_path[i] != ' ') : (i += 1) {}
                arg_end = i;
            }

            if (arg_end > arg_start) {
                const part = nvim_path[arg_start..arg_end];
                // Skip "ssh-askpass" prefix - actual ssh command is next argument
                if (argc == 0 and is_ssh_askpass and std.mem.eql(u8, part, "ssh-askpass")) {
                    // Don't add to argv, just continue to next argument
                    continue;
                }
                argv_buf[argc] = part;
                argc += 1;
            }
        }
        if (is_wsl) {
            self.log.write("WSL mode: parsed {d} arguments\n", .{argc});
        } else if (is_ssh_askpass) {
            self.log.write("SSH-ASKPASS mode: parsed {d} arguments (auth already done)\n", .{argc});
            // Don't set is_ssh_mode - auth is already handled by SSH_ASKPASS
        } else if (is_devcontainer) {
            self.log.write("devcontainer mode: parsed {d} arguments\n", .{argc});
            // Don't set is_ssh_mode - devcontainer doesn't need SSH auth
        } else if (is_shell) {
            self.log.write("shell mode: parsed {d} arguments\n", .{argc});
            // Don't set is_ssh_mode - shell command handles its own execution
        } else {
            self.log.write("SSH mode: parsed {d} arguments\n", .{argc});
            self.is_ssh_mode = true;
        }
    } else {
        // Native: parse command string and insert --embed after first argument
        // e.g., "nvim file.txt" → ["nvim", "--embed", "file.txt"]
        // e.g., "nvim -u /tmp/init.lua +10 file.txt" → ["nvim", "--embed", "-u", "/tmp/init.lua", "+10", "file.txt"]
        var i: usize = 0;
        while (i < nvim_path.len and argc < argv_buf.len - 1) { // -1 to leave room for --embed
            // Skip leading spaces
            while (i < nvim_path.len and nvim_path[i] == ' ') : (i += 1) {}
            if (i >= nvim_path.len) break;

            var arg_start = i;
            var arg_end = i;

            if (nvim_path[i] == '\'' or nvim_path[i] == '"') {
                // Quoted argument - find closing quote (handle escaped quotes)
                const quote_char = nvim_path[i];
                i += 1;
                arg_start = i;
                while (i < nvim_path.len) {
                    if (nvim_path[i] == '\\' and i + 1 < nvim_path.len and nvim_path[i + 1] == quote_char) {
                        // Skip escaped quote
                        i += 2;
                    } else if (nvim_path[i] == quote_char) {
                        // Found unescaped closing quote
                        break;
                    } else {
                        i += 1;
                    }
                }
                arg_end = i;
                if (i < nvim_path.len) i += 1; // Skip closing quote
            } else {
                // Unquoted argument - find next space
                while (i < nvim_path.len and nvim_path[i] != ' ') : (i += 1) {}
                arg_end = i;
            }

            if (arg_end > arg_start) {
                argv_buf[argc] = nvim_path[arg_start..arg_end];
                argc += 1;

                // Insert --embed after first argument (nvim executable)
                if (argc == 1) {
                    argv_buf[argc] = "--embed";
                    argc += 1;
                }
            }
        }

        // If no arguments parsed, fall back to simple path + --embed
        if (argc == 0) {
            argv_buf[0] = nvim_path;
            argv_buf[1] = "--embed";
            argc = 2;
        }

        self.log.write("Native mode: parsed {d} arguments\n", .{argc});
    }

    self.log.write("spawning nvim: {s}\n", .{nvim_path});
    for (argv_buf[0..argc]) |arg| {
        self.log.write("  arg: {s}\n", .{arg});
    }
    self.log.write("[MARKER] before logEnvHints\n", .{});
    logEnvHints(self);
    self.log.write("[MARKER] after logEnvHints\n", .{});

    var child = std.process.Child.init(argv_buf[0..argc], self.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;

    var cwd_owner: CwdOwner = .{};
    defer cwd_owner.close();
    if (!self.inherit_cwd) {
        cwd_owner.openPreferred(self.alloc, &self.log);
        cwd_owner.applyToChild(&child);
    } else {
        self.log.write("inherit_cwd=true; child inherits parent cwd\n", .{});
    }

    // Check for path separators - both '/' (Unix) and '\' (Windows)
    const has_slash = (std.mem.indexOfScalar(u8, nvim_path, '/') != null) or
        (std.mem.indexOfScalar(u8, nvim_path, '\\') != null);
    if (@hasField(@TypeOf(child), "expand_arg0")) {
        child.expand_arg0 = if (has_slash) .no_expand else .expand;
    }
    self.log.write("expand_arg0: has_slash={}, mode={s}\n", .{ has_slash, if (has_slash) "no_expand" else "expand" });

    self.log.write("about to spawn...\n", .{});
    // Direct callback log before spawn
    if (self.cb.on_log) |logfn| {
        const msg1 = "[DIRECT] calling child.spawn() now\n";
        logfn(self.ctx, msg1.ptr, msg1.len);
    }
    const spawn_start_ns = std.time.nanoTimestamp();
    child.spawn() catch |e| {
        self.log.write("spawn failed: {any}\n", .{e});
        if (self.cb.on_log) |logfn| {
            const msg_err = "[DIRECT] spawn error occurred\n";
            logfn(self.ctx, msg_err.ptr, msg_err.len);
        }
        return;
    };
    const spawn_end_ns = std.time.nanoTimestamp();
    const spawn_ms = @divTrunc(spawn_end_ns - spawn_start_ns, 1_000_000);
    // Direct callback log after spawn
    if (self.cb.on_log) |logfn| {
        const msg2 = "[DIRECT] child.spawn() returned successfully\n";
        logfn(self.ctx, msg2.ptr, msg2.len);
    }
    self.log.write("[TIMING] nvim spawn: {d}ms\n", .{spawn_ms});
    self.log.write("spawn returned ok, pid={any}\n", .{child.id});

    // Note: Don't try to read stderr here - it blocks if no data available

    self.child_handle = child.id;
    self.stdin_file = child.stdin;
    self.stdout_file = child.stdout;
    self.stderr_file = child.stderr;

    // OWNERSHIP TRANSFER:
    // We keep the pipe handles in Core, so prevent std.process.Child from closing them.
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;

    if (self.stderr_file) |ef| {
        self.stderr_thread = std.Thread.spawn(.{}, pumpStderr, .{ self, ef }) catch null;
    }

    // Start writer thread for non-blocking stdin writes.
    // SSH mode defers this until after authentication completes (see below).
    if (!self.is_ssh_mode) {
        self.startWriterThread();
    }

    // SSH mode: prompt for password immediately after process start
    // With -tt option, password prompt goes to TTY (not visible via pipes)
    // So we show dialog immediately and wait for user to enter password
    if (self.is_ssh_mode) {
        self.log.write("SSH mode: prompting for password immediately...\n", .{});

        // Set pending flag to block other stdin writes (RPC sends)
        self.ssh_auth_pending.store(true, .seq_cst);

        // Small delay to let SSH start
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Call callback to show password dialog
        if (self.cb.on_ssh_auth_prompt) |cb| {
            cb(self.ctx, "SSH Password:", 13);

            // Wait for password to be sent (ssh_auth_done flag)
            self.log.write("SSH mode: waiting for user to enter password...\n", .{});
            var waited_ms: u32 = 0;
            const timeout_ms: u32 = 60000; // 60 seconds
            const poll_ms: u32 = 100;

            while (waited_ms < timeout_ms and !self.stop_flag.load(.seq_cst)) {
                if (self.ssh_auth_done.load(.seq_cst)) {
                    self.log.write("SSH mode: password sent, waiting for connection...\n", .{});
                    // Give SSH time to authenticate
                    std.Thread.sleep(2000 * std.time.ns_per_ms);
                    break;
                }
                std.Thread.sleep(poll_ms * std.time.ns_per_ms);
                waited_ms += poll_ms;
            }

            if (waited_ms >= timeout_ms) {
                self.log.write("SSH mode: authentication timeout\n", .{});
            }
        } else {
            self.log.write("SSH mode: no callback registered\n", .{});
        }

        // Clear pending flag and start writer thread now that auth is done
        self.ssh_auth_pending.store(false, .seq_cst);
        self.startWriterThread();

        if (self.stop_flag.load(.seq_cst)) {
            self.log.write("SSH mode: stopped by user\n", .{});
            return;
        }
    }

    var ui_attached = false;

    self.requestGetApiInfo() catch |e| self.log.write("send get_api_info failed: {any}\n", .{e});
    self.requestSetClientInfo() catch |e| self.log.write("send set_client_info failed: {any}\n", .{e});
    self.requestUiAttach(self.init_rows, self.init_cols) catch |e| {
        self.log.write("ui_attach send failed: {any}\n", .{e});
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return;
    };
    ui_attached = true;
    self.requestTryResize(self.init_rows, self.init_cols) catch |e| self.log.write("try_resize send failed: {any}\n", .{e});
    self.requestCommand("redraw!") catch |e| self.log.write("redraw! send failed: {any}\n", .{e});

    if (self.pending_resize_valid) {
        const pr = self.pending_resize_rows;
        const pc = self.pending_resize_cols;
        var pending_sent = true;
        self.requestTryResize(pr, pc) catch |e| {
            self.log.write("pending resize send failed: {any}\n", .{e});
            pending_sent = false;
        };
        if (pending_sent) {
            self.pending_resize_valid = false;
            self.log.write("pending resize sent rows={d} cols={d}\n", .{ pr, pc });
        }
    }

    if (self.stdout_file == null) {
        self.log.write("stdout pipe is null\n", .{});
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return;
    }
    var pr = PipeReader{ .file = self.stdout_file.? };

    while (!self.stop_flag.load(.seq_cst)) {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const root = mp.decode(arena, &pr) catch |e| {
            if (e == error.EndOfStream) {
                self.log.write("decode err: EndOfStream (nvim stdout closed)\n", .{});
            } else {
                self.log.write("decode err: {any}\n", .{e});
            }
            break;
        };

        if (root != .arr or root.arr.len < 1) continue;
        const top = root.arr;
        if (top[0] != .int) continue;

        const t = top[0].int;
        if (t == 0) {
            // RPC request from Neovim (e.g., clipboard operations)
            handleRpcRequest(self, arena, top);
            continue;
        }
        if (t == 1) {
            // RPC response (e.g., nvim_get_api_info result)
            handleRpcResponse(self, top);
            continue;
        }
        if (t == 2) {
            handleRpcNotification(self, arena, top);
            continue;
        }
    }

    if (self.stop_flag.load(.seq_cst)) {
        _ = child.kill() catch {};
    }

    const term = child.wait() catch |e| {
        self.log.write("wait err: {any}\n", .{e});
        return;
    };
    self.log.write("nvim terminated: {any}\n", .{term});
    self.child_handle = null;


    self.log.write("nvim terminated: {any}\n", .{term});
    self.child_handle = null;

    // If nvim exited by itself (e.g. :q), notify the frontend.
    // When stop() is requested by the app side, stop_flag is set and we should not trigger on_exit.
    if (!self.stop_flag.load(.seq_cst) and ui_attached) {
        if (self.cb.on_exit) |f| {
            // Convert Term to exit code:
            // - Exited: use exit code directly
            // - Signal: 128 + signal number (Unix convention)
            // - Stopped/Unknown: return 1 (generic error)
            const exit_code: i32 = switch (term) {
                .Exited => |code| @intCast(code),
                .Signal => |sig| 128 + @as(i32, @intCast(sig)),
                .Stopped, .Unknown => 1,
            };
            self.log.write("calling on_exit with code: {d}\n", .{exit_code});
            f(self.ctx, exit_code);
        }
    }
}
