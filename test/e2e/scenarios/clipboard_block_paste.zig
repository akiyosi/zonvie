// clipboard_block_paste — a blockwise yank into the system clipboard must
// paste back as a block (issue #40). The system clipboard carries text only,
// so the provider has to remember the regtype of the last copy itself; if it
// does not, nvim falls back to charwise and the column lands as extra lines.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();
    const t = h.opts.timeout_ms;

    try h.input("iab<CR>cd<CR>ef<Esc>");
    try h.waitRowText(g, 2, "ef", t);

    // Block-yank column 0 of all three lines into "+ ...
    try h.input("gg0<C-v>jj\"+y");
    // ... and require it to reach the harness clipboard. Without a provider
    // nvim keeps "+ as an internal register that remembers the block type on
    // its own, so the paste below would pass without exercising zonvie.
    try h.waitClipboard("a\nc\ne\n", t);
    // Paste after the last column of line 1.
    try h.input("gg$\"+p");

    // Blockwise: each yanked cell appends to its own row. Charwise or
    // linewise would push "c"/"e" onto rows of their own instead.
    try h.waitRowText(g, 0, "aba", t);
    try h.waitRowText(g, 1, "cdc", t);
    try h.waitRowText(g, 2, "efe", t);

    // Another application replaces the clipboard: the remembered block type
    // belongs to the old copy and must not apply, so "x\ny" pastes charwise.
    try h.setClipboard("x\ny");
    try h.input("gg$\"+p");
    try h.waitRowText(g, 0, "abax", t);
    try h.waitRowText(g, 1, "y", t);
    try h.waitRowText(g, 2, "cdc", t);

    // Foreign text ending in a newline has no remembered type either; the
    // core must infer linewise from the trailing newline.
    try h.setClipboard("p\nq\n");
    try h.input("gg\"+p");
    try h.waitRowText(g, 1, "p", t);
    try h.waitRowText(g, 2, "q", t);
    try h.waitRowText(g, 0, "abax", t);
    try h.waitRowText(g, 3, "y", t);
}
