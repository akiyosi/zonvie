// numpad_key_handling — Numpad keys (KP_0 through KP_Enter) are correctly mapped.
// Goneovim #328: Numpad keys were not properly recognized and mapped in keybindings.
// Exercises: numpad key input recognition, key mapping infrastructure.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Set up a custom mapping for numpad 0: when KP_0 is pressed, insert "NUMPAD_0".
    try h.command("imap <kp0> NUMPAD_0");

    // Enter insert mode and simulate numpad 0 input.
    try h.input("i<kp0><Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "NUMPAD_0", h.opts.timeout_ms);

    // Test numpad enter key.
    try h.command("imap <kp_enter> NUMPAD_ENTER");
    try h.input("o<kp_enter><Esc>");
    try h.waitRowText(g, 1, "NUMPAD_ENTER", h.opts.timeout_ms);
}
