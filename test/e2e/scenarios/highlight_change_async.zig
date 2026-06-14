// highlight_change_async — redefining a highlight group AFTER it is applied
// updates the resolved color in the grid, i.e. the hl cache is invalidated on
// hl_attr_define rather than only on a fresh redraw.
// Related: Goneovim #605 (Telescope/colorscheme colors not reflected until a
// later reload — a highlight-cache timing bug; verified real upstream).

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = h.winGrid();

    // Content with a word to search-highlight.
    try h.input("itarget word<Esc>");
    try h.waitRowText(g, 0, "target word", h.opts.timeout_ms);

    // Define Search with a known bg, enable hlsearch, and match "target".
    try h.command("hi Search guibg=#00ff00 guifg=#000000");
    try h.command("set hlsearch");
    try h.command("/target");
    try h.input("<Esc>");

    // A matched, non-cursor cell (col 1 = 'a'; the cursor sits on col 0 and is
    // a separate overlay) must resolve to Search's green bg.
    const green: u32 = 0x00ff00;
    {
        const Ctx = struct { g: i64, want: u32 };
        try h.waitUntil(Ctx{ .g = g, .want = green }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.hlAt(c.g, 0, 1).bg == c.want;
            }
        }.check, h.opts.timeout_ms);
    }

    // Redefine Search WITHOUT re-searching; the same matched cell must pick up
    // the new bg, proving the hl cache invalidates on the new definition.
    try h.command("hi Search guibg=#0000ff guifg=#ffffff");
    const blue: u32 = 0x0000ff;
    {
        const Ctx = struct { g: i64, want: u32 };
        try h.waitUntil(Ctx{ .g = g, .want = blue }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.hlAt(c.g, 0, 1).bg == c.want;
            }
        }.check, h.opts.timeout_ms);
    }
}
