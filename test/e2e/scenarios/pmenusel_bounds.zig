// pmenusel_bounds — keyword completion surfaces candidates and accepting the
// selected one inserts it (the logical completion path the frontend renders).
// The PIXEL concern of Goneovim #619 (1-cell pmenusel overpaint) is a rendering
// matter covered by the GUI visual test `visual_pmenusel_bounds`; the headless
// harness has no pixels, so this verifies the observable half.
// Related: Goneovim #619 (verified real upstream).

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = h.winGrid();

    // Candidate words in the buffer. Wait for the setup to land before driving
    // input: without this barrier the keys race the buffer mutation (seen on
    // Windows as the input applying to the pre-setline buffer, leaving row 2 the
    // empty-buffer "~" marker). Matches the build→confirm→act order other
    // command+input scenarios use (horizontal_scroll_alt_wheel, edit_dd).
    try h.command("call setline(1, ['foobar', 'foobaz'])");
    try h.waitRowText(g, 1, "foobaz", h.opts.timeout_ms);

    // A fresh line to complete on.
    try h.input("Gofoo");
    try h.waitRowText(g, 2, "foo", h.opts.timeout_ms);

    // Keyword completion (<C-x><C-n>) from the current buffer selects the first
    // candidate ("foobar"); <C-y> accepts it, so the line becomes that word.
    try h.input("<C-x><C-n>");
    try h.input("<C-y>");
    try h.input("<Esc>");
    try h.waitRowText(g, 2, "foobar", h.opts.timeout_ms);
}
