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
        // Set flag before acquiring lock to detect re-entrant updateLayoutPx calls.
        self.in_handle_redraw.store(true, .seq_cst);

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
        self.in_handle_redraw.store(false, .seq_cst);
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

        // Clear pending flag
        self.ssh_auth_pending.store(false, .seq_cst);

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
