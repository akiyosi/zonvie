// msg_split_payload_ceiling — where the split view's RPC budget actually bites,
// and that heavy-but-real `:messages` use stays well clear of it.
//
// `showChannelView`'s split arm now DROPS a payload larger than
// `MAX_WRITE_QUEUE_SIZE - split_lua_buf_len` (flush.zig:9034-9038) — 4 MiB minus
// 16 KiB = 4_177_920 bytes — instead of sending it. The drop is deliberate (an
// over-cap payload fails identically on every retry) but it is SILENT: the
// messages are freed, `on_msg_clear` is skipped, and only a log line records it.
// So the question a user cares about is whether ordinary use can reach it.
//
// Two independent limits stack, and only the second one is the split's:
//
//   * a single msg_show is retained as a bounded 64 KiB tail
//     (grid.zig:284 MAX_MESSAGE_BYTES) — so ONE giant `:echomsg` can never
//     reach the split budget; it is clipped long before.
//   * `msg_history_show` entries are NOT bounded (grid.zig:4255-4279), so
//     `:messages` is the only realistic route to a multi-megabyte payload.
//
// This therefore drives the budget from below through `:messages`: a full
// history of 500 entries, first at ordinary line lengths and then at a size no
// real session produces, and asserts both round-trip COMPLETE. The assembled
// byte count is printed so the headroom against the 4_177_920-byte cap is a
// recorded number rather than an assumption.
//
// Ordering discipline: the generating loop is sequenced by a marker edit that
// Neovim cannot execute until the loop has finished; the split's appearance is
// a rising window-count edge; the content is only read back after the cursor
// has landed on the split's own grid (`:messages` mounts with enter=true), which
// proves the whole mount batch was applied.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const budget = zc.nvim_core.Core.MAX_WRITE_QUEUE_SIZE - zc.nvim_core.Core.split_lua_buf_len;

// Neovim's own message-history cap ('messagesopt' history, 500 by default;
// 200 on older builds). Asking for more just exercises the cap.
const entries = 500;
/// Phase A: a long-ish but unremarkable message line.
const ordinary_len = 200;
/// Phase B: far past anything a real session logs, still under the cap.
const heavy_len = 3800;

// Messages themselves are not displayed: this scenario is about the history
// payload, and rendering 500 large messages into the ext_float grid would
// measure something else entirely. They still enter Neovim's history.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .opts = .{ .skip = true } },
};

fn findSplitGrid(h: *Harness, alloc: std.mem.Allocator, buffer_grid: i64) !i64 {
    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    for (ids) |id| {
        if (id != buffer_grid and !h.isExternalGrid(id)) return id;
    }
    return error.SplitGridNotFound;
}

/// Fill Neovim's message history with `entries` lines of `body_len` filler,
/// each tagged `<tag>-<i>-end`, then prove the loop finished.
fn fillHistory(
    h: *Harness,
    buffer_grid: i64,
    tag: []const u8,
    body_len: usize,
    done_marker: []const u8,
) !void {
    var cmd_buf: [256]u8 = undefined;
    try h.command(try std.fmt.bufPrint(
        &cmd_buf,
        "for i in range({d}) | echomsg '{s}-' .. i .. '-end' .. repeat('.', {d}) | endfor",
        .{ entries, tag, body_len },
    ));
    // Ordered signal: Neovim is single-threaded over RPC requests, so this edit
    // cannot land until the loop above has run to completion.
    var input_buf: [64]u8 = undefined;
    try h.input(try std.fmt.bufPrint(&input_buf, "cc{s}<Esc>", .{done_marker}));
    try h.waitRowText(buffer_grid, 0, done_marker, h.opts.timeout_ms);
}

/// `:messages`, read the assembled payload, assert the first and last entries
/// of `tag` survived, then dismiss the split. Returns the assembled size.
fn showAndCheck(
    h: *Harness,
    alloc: std.mem.Allocator,
    buffer_grid: i64,
    start_windows: usize,
    tag: []const u8,
    phase: []const u8,
) !usize {
    try h.command("messages");
    h.waitWindowCount(start_windows + 1, h.opts.timeout_ms) catch |e| {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: {s}: :messages opened no split — the payload " ++
                "was dropped by the {d}-byte RPC budget\n",
            .{ phase, budget },
        );
        return e;
    };

    const split_grid = try findSplitGrid(h, alloc, buffer_grid);
    try h.waitCursorGrid(split_grid, h.opts.timeout_ms);

    const content = try h.splitContentAlloc(alloc);
    defer alloc.free(content);

    // The oldest surviving entry of this batch is unknown (Neovim's history cap
    // may have evicted the earliest), but the LAST one must always be there,
    // and it must be whole — head tag and trailing filler both.
    var needle_buf: [64]u8 = undefined;
    const last = try std.fmt.bufPrint(&needle_buf, "{s}-{d}-end", .{ tag, entries - 1 });
    const at = std.mem.indexOf(u8, content, last) orelse {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: {s}: the last history entry is missing from " ++
                "{d} assembled bytes\n",
            .{ phase, content.len },
        );
        return error.HistoryTailMissing;
    };
    if (std.mem.indexOfPos(u8, content, at + last.len, last) != null) {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: {s}: the last history entry appears twice\n",
            .{phase},
        );
        return error.HistoryEntryDuplicated;
    }
    // Nothing was clipped mid-payload: the tail entry's own filler is intact.
    if (std.mem.indexOfScalarPos(u8, content, at + last.len, '\n') == null) {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: {s}: payload ends mid-entry ({d} bytes)\n",
            .{ phase, content.len },
        );
        return error.SplitContentClipped;
    }

    const len = content.len;
    std.debug.print(
        "[e2e] msg_split_payload_ceiling: {s}: {d} bytes assembled and shown " ++
            "({d}% of the {d}-byte budget)\n",
        .{ phase, len, len * 100 / budget, budget },
    );

    try h.input("q");
    try h.waitWindowCount(start_windows, h.opts.timeout_ms);
    try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);
    return len;
}

pub fn run(alloc: std.mem.Allocator) !void {
    // Generous: this deliberately moves megabytes through a real Neovim.
    var h = try Harness.init(alloc, .{
        .ext_messages = true,
        .msg_routes = &routes,
        .timeout_ms = 20000,
    });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    // ── A. A full history of ordinary lines ────────────────────────────
    try fillHistory(h, buffer_grid, "ordinary", ordinary_len, "PHASEA");
    const small = try showAndCheck(h, alloc, buffer_grid, start_windows, "ordinary", "phase A");
    if (small >= budget) {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: an ordinary 500-entry history is already at the " ++
                "budget ({d} of {d})\n",
            .{ small, budget },
        );
        return error.OrdinaryHistoryAtBudget;
    }

    // ── B. A history far heavier than any real session ─────────────────
    try fillHistory(h, buffer_grid, "heavy", heavy_len, "PHASEB");
    const big = try showAndCheck(h, alloc, buffer_grid, start_windows, "heavy", "phase B");
    if (big <= small) {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: phase B assembled {d} bytes, not more than " ++
                "phase A's {d} — the heavy history never reached the split\n",
            .{ big, small },
        );
        return error.HeavyHistoryNotAssembled;
    }

    // ── C. The pipeline still works afterwards ─────────────────────────
    // A retry deadline stranded by the heavy dispatch would delay or swallow
    // this; `:messages` must open once more, promptly.
    try h.command("echomsg 'tail-marker-end'");
    try h.input("ccPHASEC<Esc>");
    try h.waitRowText(buffer_grid, 0, "PHASEC", h.opts.timeout_ms);

    try h.command("messages");
    h.waitWindowCount(start_windows + 1, h.opts.timeout_ms) catch |e| {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: :messages stopped working after a multi-megabyte " ++
                "history\n",
            .{},
        );
        return e;
    };
    const final_content = try h.splitContentAlloc(alloc);
    defer alloc.free(final_content);
    if (std.mem.indexOf(u8, final_content, "tail-marker-end") == null) {
        std.debug.print(
            "[e2e] msg_split_payload_ceiling: the newest entry is missing from the final show\n",
            .{},
        );
        return error.TailMarkerMissing;
    }
}
