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

fn build(buf: []u8, line_count: u32, enter: bool, timeout_ms: u32) ![]const u8 {
    return Core.buildSplitLua(buf, line_count, enter, timeout_ms);
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
    const lua = try build(&buf, 20, true, 4000);
    try std.testing.expect(lua.len < buf_len / 2);
}

test "a tiny buffer reports overflow rather than truncating" {
    var small: [64]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, build(&small, 1, false, 0));
}

// -- focus --------------------------------------------------------------------

test "enter is emitted verbatim so a routed message cannot steal the cursor" {
    var buf: [buf_len]u8 = undefined;

    const not_entered = try build(&buf, 5, false, 0);
    try std.testing.expect(contains(not_entered, "local enter = false"));

    var buf2: [buf_len]u8 = undefined;
    const entered = try build(&buf2, 5, true, 0);
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
    const lua = try build(&buf, 5, true, 0);

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
    const lua = try build(&buf, 5, true, 0);
    try std.testing.expect(contains(lua, "'q'"));
    try std.testing.expect(contains(lua, "'<Esc>'"));
}

test "the split does not keep Neovim alive" {
    // Without this, `:q` closed the editor window and left the scratch split
    // as the only window, so nvim never exited.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0);
    try std.testing.expect(contains(lua, "QuitPre"));
    try std.testing.expect(contains(lua, "nvim_tabpage_list_wins"));
}

test "a queued auto-hide cannot close a later split" {
    // vim.schedule_wrap defers the close by an event-loop turn, and stopping
    // the timer handle cannot retract an entry that is already queued. A
    // close armed for message A therefore drained after message B was shown
    // and tore B down — including a timeout-0 prompt. The generation token
    // is what makes a queued close a no-op once anything re-armed or
    // stopped the timer.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 3000);

    // Every stop bumps the generation, so BufEnter also cancels queued closes.
    const stop_at = std.mem.indexOf(u8, lua, "local function stop_timer()") orelse
        return error.StopTimerMissing;
    const stop_block = lua[stop_at..@min(stop_at + 400, lua.len)];
    try std.testing.expect(contains(stop_block, "state.gen = (state.gen or 0) + 1"));

    // The scheduled callback is guarded by the generation it was armed with.
    try std.testing.expect(contains(lua, "local gen = state.gen"));
    try std.testing.expect(contains(lua, "if state.gen == gen then state.close() end"));
}

test "closing the split stops its timer instead of leaking the handle" {
    // Closing while the cursor is inside fires BufLeave, which re-arms a
    // fresh timer that nothing would ever close — measured with uv.walk
    // against real nvim, one libuv timer leaked per split close. Order
    // relative to `state.win = nil` is deliberately NOT asserted: stop_timer
    // never reads state.win, and a reversed variant measured identically.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 3000);

    const at = std.mem.indexOf(u8, lua, "'WinClosed'") orelse return error.WinClosedMissing;
    const block = lua[at..@min(at + 700, lua.len)];
    try std.testing.expect(contains(block, "stop_timer()"));
    try std.testing.expect(contains(block, "state.win = nil"));
}

test "a window that no longer shows our buffer is forgotten, not reused" {
    // buf and win are repaired independently, so `:bd!` on the split — or the
    // user running `:e file` inside it — leaves a valid window showing
    // something else. Reusing it took the mounted branch, which only sets the
    // height, so every later message went into a buffer nothing displayed.
    // Re-seating our buffer into it would be worse: it hijacks the user's
    // window, and the keymaps and pause autocmds are only registered on the
    // mount path, so `q` and `<Esc>` would no longer close the split.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0);

    const check = "if state.win and vim.api.nvim_win_get_buf(state.win) ~= state.buf then";
    const at = std.mem.indexOf(u8, lua, check) orelse return error.StaleWindowCheckMissing;
    try std.testing.expect(contains(lua[at..], "state.win = nil"));
    // Never seat our buffer into a window we did not mount.
    try std.testing.expect(!contains(lua, "nvim_win_set_buf"));

    // The check must precede the mount decision, or it cannot influence it.
    const mount_at = std.mem.indexOf(u8, lua, "if not state.win then") orelse
        return error.MountBranchMissing;
    try std.testing.expect(at < mount_at);
}

test "QuitPre ignores quits that cannot end the session" {
    // Two spurious-close paths the last-window count alone cannot see:
    // quitting the split itself (closing it here makes the pending `:q` fail
    // on an invalid window, so nvim stays open), and quitting a float —
    // floats are excluded from the count, so dismissing an LSP hover with
    // `:q` looked like "one real window left" and took the split with it.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0);

    const at = std.mem.indexOf(u8, lua, "'QuitPre'") orelse return error.QuitPreMissing;
    const block = lua[at..];
    const self_at = std.mem.indexOf(u8, block, "if cur == state.win then return end") orelse
        return error.SelfQuitGuardMissing;
    const float_needle = "nvim_win_get_config(cur).relative ~= '' then return end";
    const float_at = std.mem.indexOf(u8, block, float_needle) orelse
        return error.FloatGuardMissing;
    // Both guards must precede EVERY close decision, including the
    // alone-in-its-tabpage one that deliberately ignores the tabpage guard.
    const first_close = std.mem.indexOf(u8, block, "state.close()") orelse
        return error.CloseDecisionMissing;
    try std.testing.expect(self_at < first_close);
    try std.testing.expect(float_at < first_close);
    // Exactly one float check: a second copy behind the alone case is how the
    // guard silently stopped covering it.
    try std.testing.expect(std.mem.indexOf(u8, block[float_at + float_needle.len ..], "relative ~= ''") == null);
}

test "the split never survives as the last window of its own tabpage" {
    // Verified against real nvim: tab 1 holding the editor, tab 2 holding
    // nothing but the split, `:q` in tab 1 — without this branch nvim stays
    // alive with a scratch message split as the session's only window.
    // The tabpage guard cannot cover it (the quit is in the other tab), so
    // the alone case has to be decided ahead of that guard.
    //
    // It is narrowed to quits that would actually strand the split: closing
    // whenever the split is alone destroyed a whole tabpage on a `:q` that
    // left windows behind in its own tab.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0);

    const at = std.mem.indexOf(u8, lua, "'QuitPre'") orelse return error.QuitPreMissing;
    const block = lua[at..];
    // The count is taken over the SPLIT's tabpage, not the current one.
    const count_at = std.mem.indexOf(u8, block, "nvim_tabpage_list_wins(split_tab)") orelse
        return error.SplitTabCountMissing;
    const alone_at = std.mem.indexOf(u8, block, "if others == 0 then") orelse
        return error.AloneCaseMissing;
    const tab_guard_at = std.mem.indexOf(u8, block, "split_tab ~= vim.api.nvim_get_current_tabpage() then return end") orelse
        return error.TabpageGuardMissing;
    try std.testing.expect(count_at < alone_at);
    // The alone case is decided BEFORE the tabpage guard can return early.
    try std.testing.expect(alone_at < tab_guard_at);

    // ...and only when the quitting window is the last real one in its own
    // tabpage, with no third tabpage left to keep the session alive.
    const alone_block = block[alone_at..tab_guard_at];
    try std.testing.expect(contains(alone_block, "nvim_tabpage_list_wins(cur_tab)"));
    try std.testing.expect(contains(alone_block, "cur_others == 0 and #vim.api.nvim_list_tabpages() <= 2"));
}

test "autocmds are grouped so re-showing does not stack duplicates" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0);
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
    const lua = try build(&buf, 5, false, 0);

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
    const lua = try build(&buf, 5, false, 0);
    try std.testing.expect(contains(lua, "if state.buf and not vim.api.nvim_buf_is_valid(state.buf) then state.buf = nil end"));
    try std.testing.expect(contains(lua, "if state.win and not vim.api.nvim_win_is_valid(state.win) then state.win = nil end"));
}

test "the buffer survives being hidden so it can be reused" {
    // bufhidden=wipe would destroy the buffer on close, defeating the
    // update-in-place path on the next message.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0);
    try std.testing.expect(contains(lua, "bufhidden = 'hide'"));
    try std.testing.expect(!contains(lua, "bufhidden = 'wipe'"));
}

// -- auto-hide ----------------------------------------------------------------

test "the timeout reaches the generated program" {
    // The split path used to ignore the routed timeout entirely. The value is
    // stored on state so the enter/leave autocmds re-arm the CURRENT show's
    // timeout, not the one captured when the window was first created.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 2500);
    try std.testing.expect(contains(lua, "local timeout = 2500"));
    try std.testing.expect(contains(lua, "state.timeout = timeout"));
    try std.testing.expect(contains(lua, "state.timer:start(state.timeout"));
}

test "a zero timeout leaves the split until dismissed" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, false, 0);
    try std.testing.expect(contains(lua, "local timeout = 0"));
    // The timer is still guarded, so 0 simply never arms it.
    try std.testing.expect(contains(lua, "if state.timeout > 0 then"));
}

test "entering the split pauses the auto-hide; leaving re-arms it" {
    // A split the cursor sits in must not vanish mid-read: BufEnter stops the
    // countdown, BufLeave re-arms the full timeout, and a show that finds the
    // cursor already inside keeps the timer stopped instead of arming it.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, true, 3000);

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
    const lua = try build(&buf, 5, false, 1000);
    try std.testing.expect(contains(lua, "local function close()\n    stop_timer()"));
    try std.testing.expect(contains(lua, "is_closing()"));
}

// -- no second CR -------------------------------------------------------------

test "the split does not answer prompts on its own" {
    // return_prompt is answered once at the event layer. This program used to
    // feed a second <CR> of its own, racing the first.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 5, true, 0);
    try std.testing.expect(!contains(lua, "feedkeys"));
    try std.testing.expect(!contains(lua, "replace_termcodes"));
}

// -- height -------------------------------------------------------------------

test "height is clamped to a readable window" {
    try std.testing.expectEqual(@as(u32, 1), Core.splitHeight(0));
    try std.testing.expectEqual(@as(u32, 1), Core.splitHeight(1));
    try std.testing.expectEqual(@as(u32, 12), Core.splitHeight(12));
    try std.testing.expectEqual(@as(u32, 20), Core.splitHeight(20));
    try std.testing.expectEqual(@as(u32, 20), Core.splitHeight(2034));
}

test "the height reaches the generated program" {
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 7, false, 0);
    try std.testing.expect(contains(lua, "local height = 7"));
}

test "nothing user-controlled is interpolated into the program" {
    // The message text travels as a msgpack argument, never as source, so the
    // generated Lua needs no escaping. That only holds while every `{}` in
    // the template takes an integer or a boolean literal — a formatted
    // string would reintroduce a Lua-literal injection surface.
    var buf: [buf_len]u8 = undefined;
    const lua = try build(&buf, 7, true, 4000);
    try std.testing.expect(contains(lua, "local height = 7"));
    try std.testing.expect(contains(lua, "local enter = true"));
    try std.testing.expect(contains(lua, "local timeout = 4000"));
    // `local content = ...` is the vararg the RPC argument binds to.
    try std.testing.expect(contains(lua, "local content = ...\n"));

    // The emitted program contains no `"` byte at all (the template quotes
    // exclusively with '), so this trips on the historically likely
    // reintroduction: reviving the deleted label code, which was
    // double-quoted (`local label = "{s}"`). It does NOT catch a fresh
    // single-quoted `'{s}'` or a long-bracket `[[{s}]]` — those are stopped
    // only by buildSplitLua's closed integer/bool signature, where feeding a
    // string requires a parameter change that breaks this file's build.
    try std.testing.expect(!contains(lua, "\""));
}
