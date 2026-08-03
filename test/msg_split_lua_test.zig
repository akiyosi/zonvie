//! Tests for the split-view Lua program (`Core.buildSplitLua`).
//!
//! Everything the message split does — whether it takes focus, whether it
//! auto-hides, how it closes, whether `:q` still quits — is decided by this
//! generated text, and until now nothing checked it. Each defect below was
//! found by hand and fixed with no test to keep it fixed.

const std = @import("std");
const zc = @import("zonvie_core");

const Core = zc.nvim_core.Core;
const buf_len = Core.split_lua_buf_len;

fn build(
    buf: []u8,
    line_count: u32,
    enter: bool,
    timeout_ms: u32,
    label: ?[]const u8,
) ![]const u8 {
    return Core.buildSplitLua(buf, line_count, enter, timeout_ms, label);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// -- the buffer must not overflow --------------------------------------------

test "the template fits its buffer with headroom" {
    // Overflow surfaces as error.NoSpaceLeft, which the caller only logs, so
    // the split would silently stop appearing. Require real slack, not a
    // by-one-byte fit.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 20, true, 4000, "Messages");
    try std.testing.expect(lua.len < buf_len / 2);
}

test "a tiny buffer reports overflow rather than truncating" {
    var small: [64]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, build(&small, 1, false, 0, null));
}

// -- focus --------------------------------------------------------------------

test "enter is emitted verbatim so a routed message cannot steal the cursor" {
    var buf: [buf_len]u8 = undefined;

    const not_entered = try build(&buf, 5, false, 0, null);
    try std.testing.expect(contains(not_entered, "local enter = false"));

    var buf2: [buf_len]u8 = undefined;
    const entered = try build(&buf2, 5, true, 0, null);
    try std.testing.expect(contains(entered, "local enter = true"));
}

// -- lifetime -----------------------------------------------------------------

test "the split is never closed by leaving it" {
    // noice attaches a closing BufLeave to popups but not to splits
    // (config/views.lua:99-106 vs :73-86): a split meant to be entered has to
    // survive being left. A BufLeave autocmd here once closed it on any
    // window switch. BufLeave now exists again — but only to re-arm the
    // auto-hide timer — so assert structurally: exactly one occurrence, and
    // its callback re-arms without any close.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, true, 0, null);

    const at = std.mem.indexOf(u8, lua, "'BufLeave'") orelse return error.BufLeaveMissing;
    // Only one BufLeave registration exists.
    try std.testing.expect(std.mem.indexOf(u8, lua[at + 1 ..], "'BufLeave'") == null);
    // Its callback re-arms the timer and never closes the window.
    const block = lua[at..@min(at + 160, lua.len)];
    try std.testing.expect(contains(block, "arm_timer()"));
    try std.testing.expect(!contains(block, "close("));
}

test "closing is bound to q and Esc" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, true, 0, null);
    try std.testing.expect(contains(lua, "'q'"));
    try std.testing.expect(contains(lua, "'<Esc>'"));
}

test "the split does not keep Neovim alive" {
    // Without this, `:q` closed the editor window and left the scratch split
    // as the only window, so nvim never exited.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0, null);
    try std.testing.expect(contains(lua, "QuitPre"));
    try std.testing.expect(contains(lua, "nvim_tabpage_list_wins"));
}

test "autocmds are grouped so re-showing does not stack duplicates" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0, null);
    try std.testing.expect(contains(lua, "nvim_create_augroup('ZonvieMsgSplit'"));
    try std.testing.expect(contains(lua, "clear = true"));
}

// -- content updates ----------------------------------------------------------

test "content is always re-rendered, not skipped when already mounted" {
    // The defect this pins: an early `return` before the render block when
    // buf+win were already valid, so a second message never updated the
    // split. Token presence alone cannot catch that (the buggy program also
    // contained `nvim_buf_set_lines` as text), so assert structurally: in
    // everything BEFORE the render call, the only `return`s are the inline
    // `if not ok then return end` creation guards — no bare `return`
    // statement line, which is exactly what the mounted-early-return was.
    // The e2e scenario msg_split_lifecycle covers the behavior end to end;
    // this keeps the generated program from regressing shape-wise.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0, null);

    const render_at = std.mem.indexOf(u8, lua, "nvim_buf_set_lines") orelse
        return error.RenderCallMissing;
    const prefix = lua[0..render_at];

    var lines = std.mem.splitScalar(u8, prefix, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        try std.testing.expect(!std.mem.eql(u8, trimmed, "return"));
    }
    try std.testing.expect(contains(lua, "modifiable"));
}

test "stale handles are repaired rather than trusted" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0, null);
    try std.testing.expect(contains(lua, "if state.buf and not vim.api.nvim_buf_is_valid(state.buf) then state.buf = nil end"));
    try std.testing.expect(contains(lua, "if state.win and not vim.api.nvim_win_is_valid(state.win) then state.win = nil end"));
}

test "the buffer survives being hidden so it can be reused" {
    // bufhidden=wipe would destroy the buffer on close, defeating the
    // update-in-place path on the next message.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0, null);
    try std.testing.expect(contains(lua, "bufhidden = 'hide'"));
    try std.testing.expect(!contains(lua, "bufhidden = 'wipe'"));
}

// -- auto-hide ----------------------------------------------------------------

test "the timeout reaches the generated program" {
    // The split path used to ignore the routed timeout entirely. The value is
    // stored on state so the enter/leave autocmds re-arm the CURRENT show's
    // timeout, not the one captured when the window was first created.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 2500, null);
    try std.testing.expect(contains(lua, "local timeout = 2500"));
    try std.testing.expect(contains(lua, "state.timeout = timeout"));
    try std.testing.expect(contains(lua, "state.timer:start(state.timeout"));
}

test "a zero timeout leaves the split until dismissed" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0, null);
    try std.testing.expect(contains(lua, "local timeout = 0"));
    // The timer is still guarded, so 0 simply never arms it.
    try std.testing.expect(contains(lua, "if state.timeout > 0 then"));
}

test "entering the split pauses the auto-hide; leaving re-arms it" {
    // A split the cursor sits in must not vanish mid-read: BufEnter stops the
    // countdown, BufLeave re-arms the full timeout, and a show that finds the
    // cursor already inside keeps the timer stopped instead of arming it.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, true, 3000, null);

    const enter_at = std.mem.indexOf(u8, lua, "'BufEnter'") orelse return error.BufEnterMissing;
    const enter_block = lua[enter_at..@min(enter_at + 160, lua.len)];
    try std.testing.expect(contains(enter_block, "stop_timer()"));
    try std.testing.expect(!contains(enter_block, "arm_timer()"));

    // The show-time arming is conditional on the cursor's window.
    try std.testing.expect(contains(lua, "vim.api.nvim_get_current_win() == state.win"));
}

test "the timer is stopped on every path that closes the split" {
    // Every close path funnels through close(), so it suffices that close()
    // begins by stopping the timer — assert the definition itself, not just
    // that the tokens appear somewhere.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 1000, null);
    try std.testing.expect(contains(lua, "local function close()\n    stop_timer()"));
    try std.testing.expect(contains(lua, "is_closing()"));
}

// -- no second CR -------------------------------------------------------------

test "the split does not answer prompts on its own" {
    // return_prompt is answered once at the event layer. This program used to
    // feed a second <CR> of its own, racing the first.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, true, 0, null);
    try std.testing.expect(!contains(lua, "feedkeys"));
    try std.testing.expect(!contains(lua, "replace_termcodes"));
}

// -- height -------------------------------------------------------------------

test "height is clamped to a readable window" {
    try std.testing.expectEqual(@as(u32, 1), Core.splitHeight(0, null));
    try std.testing.expectEqual(@as(u32, 1), Core.splitHeight(1, null));
    try std.testing.expectEqual(@as(u32, 12), Core.splitHeight(12, null));
    try std.testing.expectEqual(@as(u32, 20), Core.splitHeight(20, null));
    try std.testing.expectEqual(@as(u32, 20), Core.splitHeight(2034, null));
}

test "a label adds its own line and separator to the height" {
    try std.testing.expectEqual(@as(u32, 7), Core.splitHeight(5, "Messages"));
    // Still clamped.
    try std.testing.expectEqual(@as(u32, 20), Core.splitHeight(19, "Messages"));
}

test "the height reaches the generated program" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 7, false, 0, null);
    try std.testing.expect(contains(lua, "local height = 7"));
}

// -- label --------------------------------------------------------------------

test "a label is rendered only when present" {
    var buf: [buf_len]u8 = undefined;
    const without = try build(&buf, 5, false, 0, null);
    try std.testing.expect(contains(without, "local has_label = false"));

    var buf2: [buf_len]u8 = undefined;
    const with = try build(&buf2, 5, false, 0, "Messages");
    try std.testing.expect(contains(with, "local has_label = true"));
    try std.testing.expect(contains(with, "local label = \"Messages\""));
}
