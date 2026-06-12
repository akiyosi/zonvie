// highlight_change_async — verify that highlight definition changes
// are applied correctly when they occur asynchronously.
// Issue: #612 (Goneovim)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Set up initial highlights
    try h.command("highlight Normal ctermfg=7 ctermbg=0");
    try h.command("highlight Search ctermfg=0 ctermbg=11");

    // Add content
    try h.command("normal! gg");
    try h.command("normal! i");
    try h.input("test content for searching");
    try h.input("<Escape>");

    // Apply search highlighting
    try h.command("set hlsearch");
    try h.command("/searching");
    try h.input("<Escape>");

    // Change highlight definition
    try h.command("highlight Search ctermfg=0 ctermbg=14");

    // Continue editing
    try h.command("normal! i");
    try h.input(" more");
    try h.input("<Escape>");

    // Add more lines and apply different highlights
    try h.command("normal! o");
    try h.input("another line");
    try h.input("<Escape>");

    // Change multiple highlights at once
    try h.command("highlight Normal ctermfg=15 ctermbg=1");
    try h.command("highlight CursorLine ctermbg=8");

    // Enable cursorline
    try h.command("set cursorline");

    // Move cursor (triggers cursorline highlight)
    try h.command("normal! j");

    // Change cursorline highlight
    try h.command("highlight CursorLine ctermbg=7");

    try h.command("normal! j");

    // Change highlight again
    try h.command("highlight CursorLine ctermbg=2");

    // Test with visual selection highlight
    try h.command("normal! gg");
    try h.command("normal! v");
    try h.command("normal! e");

    // Change visual highlight
    try h.command("highlight Visual ctermfg=0 ctermbg=10");

    try h.input("<Escape>");

    // Disable/enable highlights
    try h.command("set nohls");
    try h.command("set hlsearch");

    // Multiple rapid highlight changes
    try h.command("highlight Search ctermfg=1 ctermbg=0");
    try h.command("highlight Search ctermfg=2 ctermbg=0");
    try h.command("highlight Search ctermfg=3 ctermbg=0");
    try h.command("highlight Search ctermfg=4 ctermbg=0");

    // Continue editing
    try h.command("normal! o");
    try h.input("final_test");
    try h.input("<Escape>");

    // Clear all matches and highlights
    try h.command("call clearmatches()");
    try h.command("set nocursorline");
    try h.command("set nohls");

    // Final cleanup
    try h.command("normal! gg");
}
