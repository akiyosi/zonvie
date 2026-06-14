// cursor_position_after_delete — the cursor lands on the correct line/column
// after delete operations, as reflected in the (grid-relative) cursor state
// the frontend renders from.
// General frontend robustness test (cursor mirroring); not tied to a specific
// upstream issue (a prior header cited Goneovim #614, which is a Win11
// title-bar-color PR — unrelated).

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = h.winGrid();

    // Three lines: aaa / bbb / ccc.
    try h.input("iaaa<Esc>obbb<Esc>occc<Esc>");
    try h.waitRowText(g, 2, "ccc", h.opts.timeout_ms);

    // Delete the middle line (bbb). The cursor must land on the line that took
    // its place (ccc) — grid row 1. Reset the column to 0 first: Neovim
    // defaults to 'nostartofline', so dd keeps the previous column otherwise.
    try h.input("gg");
    try h.input("j");
    try h.input("0");
    try h.input("dd");
    try h.waitCursor(1, 0, h.opts.timeout_ms);
    try h.waitRowText(g, 1, "ccc", h.opts.timeout_ms);

    // dw at column 0 of the first line removes "aaa", leaving it empty; the
    // cursor stays at column 0.
    try h.input("gg");
    try h.input("0");
    try h.input("dw");
    try h.waitCursor(0, 0, h.opts.timeout_ms);
    try h.waitRowText(g, 0, "", h.opts.timeout_ms);
}
