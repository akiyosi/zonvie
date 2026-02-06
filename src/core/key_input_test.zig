// Key input formatting tests for Zonvie.
// Tests the pure formatKeyEvent function that converts keycode/mods to Neovim input notation.

const std = @import("std");
const nvim_core = @import("nvim_core.zig");

// Modifier bitmask constants (match zonvie_core.h)
const MOD_CTRL: u32 = 1 << 0;
const MOD_ALT: u32 = 1 << 1;
const MOD_SHIFT: u32 = 1 << 2;
const MOD_SUPER: u32 = 1 << 3;

// Windows VK flag (keycodes with this flag are Win32 Virtual-Key codes)
const WIN_VK_FLAG: u32 = 0x10000;

// Test helper: format key event and compare result
fn expectKeyFormat(expected: []const u8, keycode: u32, mods: u32, chars: []const u8, ign: []const u8) !void {
    var buf: [256]u8 = undefined;
    const result = nvim_core.Core.formatKeyEvent(&buf, keycode, mods, chars, ign);
    if (result) |actual| {
        try std.testing.expectEqualStrings(expected, actual);
    } else {
        // null result means no output expected
        try std.testing.expect(expected.len == 0);
    }
}

// Test helper: expect null result (no output)
fn expectNoOutput(keycode: u32, mods: u32, chars: []const u8, ign: []const u8) !void {
    var buf: [256]u8 = undefined;
    const result = nvim_core.Core.formatKeyEvent(&buf, keycode, mods, chars, ign);
    try std.testing.expect(result == null);
}

// ============================================================================
// Category A: macOS Special Keys
// ============================================================================

test "mac Escape" {
    try expectKeyFormat("<Esc>", 53, 0, "", "");
}

test "mac Enter" {
    try expectKeyFormat("<CR>", 36, 0, "", "");
}

test "mac Tab" {
    try expectKeyFormat("<Tab>", 48, 0, "", "");
}

test "mac Backspace" {
    try expectKeyFormat("<BS>", 51, 0, "", "");
}

test "mac Delete" {
    try expectKeyFormat("<Del>", 117, 0, "", "");
}

test "mac Left arrow" {
    try expectKeyFormat("<Left>", 123, 0, "", "");
}

test "mac Right arrow" {
    try expectKeyFormat("<Right>", 124, 0, "", "");
}

test "mac Down arrow" {
    try expectKeyFormat("<Down>", 125, 0, "", "");
}

test "mac Up arrow" {
    try expectKeyFormat("<Up>", 126, 0, "", "");
}

test "mac Home" {
    try expectKeyFormat("<Home>", 115, 0, "", "");
}

test "mac End" {
    try expectKeyFormat("<End>", 119, 0, "", "");
}

test "mac PageUp" {
    try expectKeyFormat("<PageUp>", 116, 0, "", "");
}

test "mac PageDown" {
    try expectKeyFormat("<PageDown>", 121, 0, "", "");
}

// ============================================================================
// Category A: Windows Special Keys (VK codes with WIN_VK_FLAG)
// ============================================================================

test "win VK_ESCAPE" {
    try expectKeyFormat("<Esc>", WIN_VK_FLAG | 0x1B, 0, "", "");
}

test "win VK_RETURN" {
    try expectKeyFormat("<CR>", WIN_VK_FLAG | 0x0D, 0, "", "");
}

test "win VK_TAB" {
    try expectKeyFormat("<Tab>", WIN_VK_FLAG | 0x09, 0, "", "");
}

test "win VK_BACK" {
    try expectKeyFormat("<BS>", WIN_VK_FLAG | 0x08, 0, "", "");
}

test "win VK_DELETE" {
    try expectKeyFormat("<Del>", WIN_VK_FLAG | 0x2E, 0, "", "");
}

test "win VK_LEFT" {
    try expectKeyFormat("<Left>", WIN_VK_FLAG | 0x25, 0, "", "");
}

test "win VK_UP" {
    try expectKeyFormat("<Up>", WIN_VK_FLAG | 0x26, 0, "", "");
}

test "win VK_RIGHT" {
    try expectKeyFormat("<Right>", WIN_VK_FLAG | 0x27, 0, "", "");
}

test "win VK_DOWN" {
    try expectKeyFormat("<Down>", WIN_VK_FLAG | 0x28, 0, "", "");
}

test "win VK_HOME" {
    try expectKeyFormat("<Home>", WIN_VK_FLAG | 0x24, 0, "", "");
}

test "win VK_END" {
    try expectKeyFormat("<End>", WIN_VK_FLAG | 0x23, 0, "", "");
}

test "win VK_PRIOR (PageUp)" {
    try expectKeyFormat("<PageUp>", WIN_VK_FLAG | 0x21, 0, "", "");
}

test "win VK_NEXT (PageDown)" {
    try expectKeyFormat("<PageDown>", WIN_VK_FLAG | 0x22, 0, "", "");
}

// ============================================================================
// Category B: Modifier Keys
// ============================================================================

test "Ctrl+a" {
    try expectKeyFormat("<C-a>", 0, MOD_CTRL, "", "a");
}

test "Alt+a" {
    try expectKeyFormat("<M-a>", 0, MOD_ALT, "", "a");
}

test "Shift alone does not produce modifier notation" {
    // Shift alone is not treated as a modifier for formatKeyEvent.
    // The text comes through chars (e.g., 'A' from Shift+a) not as <S-a>.
    // This matches Neovim's expected behavior where Shift+letter = uppercase letter.
    try expectNoOutput(0, MOD_SHIFT, "", "a");
}

test "Shift with text produces text" {
    // When Shift is held, the frontend typically sends 'A' in chars, not 'a'.
    try expectKeyFormat("A", 0, MOD_SHIFT, "A", "");
}

test "Super+a (Command on macOS)" {
    try expectKeyFormat("<D-a>", 0, MOD_SUPER, "", "a");
}

test "Ctrl+Shift+a" {
    try expectKeyFormat("<C-S-a>", 0, MOD_CTRL | MOD_SHIFT, "", "a");
}

test "Ctrl+Alt+a" {
    try expectKeyFormat("<C-M-a>", 0, MOD_CTRL | MOD_ALT, "", "a");
}

test "Ctrl+Alt+Shift+a" {
    try expectKeyFormat("<C-M-S-a>", 0, MOD_CTRL | MOD_ALT | MOD_SHIFT, "", "a");
}

test "Ctrl+Alt+Shift+Super+a" {
    try expectKeyFormat("<C-M-S-D-a>", 0, MOD_CTRL | MOD_ALT | MOD_SHIFT | MOD_SUPER, "", "a");
}

test "Ctrl+Left arrow (mac)" {
    try expectKeyFormat("<C-Left>", 123, MOD_CTRL, "", "");
}

test "Shift+Tab (mac)" {
    try expectKeyFormat("<S-Tab>", 48, MOD_SHIFT, "", "");
}

test "Ctrl+Escape (win)" {
    try expectKeyFormat("<C-Esc>", WIN_VK_FLAG | 0x1B, MOD_CTRL, "", "");
}

test "Alt+Enter (win)" {
    try expectKeyFormat("<M-CR>", WIN_VK_FLAG | 0x0D, MOD_ALT, "", "");
}

// ============================================================================
// Category C: Escaping '<' as '<lt>'
// ============================================================================

test "escape less-than" {
    try expectKeyFormat("<lt>", 0, 0, "<", "");
}

test "escape multiple less-than" {
    try expectKeyFormat("<lt><lt>", 0, 0, "<<", "");
}

test "escape less-than in string" {
    try expectKeyFormat("a<lt>b", 0, 0, "a<b", "");
}

test "escape less-than at end" {
    try expectKeyFormat("hello<lt>", 0, 0, "hello<", "");
}

test "no escape for greater-than" {
    try expectKeyFormat("a>b", 0, 0, "a>b", "");
}

// ============================================================================
// Category D: Plain Text Input (no modifiers)
// ============================================================================

test "single ASCII char" {
    try expectKeyFormat("a", 0, 0, "a", "");
}

test "ASCII string" {
    try expectKeyFormat("Hello", 0, 0, "Hello", "");
}

test "UTF-8 Japanese" {
    try expectKeyFormat("日本語", 0, 0, "日本語", "");
}

test "UTF-8 emoji" {
    try expectKeyFormat("🎉", 0, 0, "🎉", "");
}

test "mixed ASCII and UTF-8" {
    try expectKeyFormat("Hello世界", 0, 0, "Hello世界", "");
}

// ============================================================================
// Category E: Case Normalization (Ctrl makes lowercase)
// ============================================================================

test "Ctrl normalizes uppercase to lowercase" {
    // When Ctrl is held, 'A' should become <C-a>
    try expectKeyFormat("<C-a>", 0, MOD_CTRL, "", "A");
}

test "Ctrl+Shift keeps lowercase" {
    // Ctrl+Shift+A -> <C-S-a>
    try expectKeyFormat("<C-S-a>", 0, MOD_CTRL | MOD_SHIFT, "", "A");
}

test "Alt normalizes uppercase to lowercase" {
    try expectKeyFormat("<M-z>", 0, MOD_ALT, "", "Z");
}

// ============================================================================
// Category F: Edge Cases
// ============================================================================

test "empty chars with no special key returns null" {
    try expectNoOutput(0, 0, "", "");
}

test "unknown keycode with no chars returns null" {
    try expectNoOutput(9999, 0, "", "");
}

test "Ctrl with UTF-8 char" {
    // Non-ASCII with Ctrl should still work
    try expectKeyFormat("<C-あ>", 0, MOD_CTRL, "", "あ");
}

test "modifier uses ign over chars" {
    // When both chars and ign are provided, ign takes precedence
    try expectKeyFormat("<C-b>", 0, MOD_CTRL, "x", "b");
}

test "modifier fallback to chars when ign empty" {
    try expectKeyFormat("<C-c>", 0, MOD_CTRL, "c", "");
}

// ============================================================================
// Helper Function Tests
// ============================================================================

test "isWinVkKeycode detects Windows VK flag" {
    try std.testing.expect(nvim_core.Core.isWinVkKeycode(WIN_VK_FLAG | 0x41));
    try std.testing.expect(!nvim_core.Core.isWinVkKeycode(123)); // macOS keycode
}

test "winVk extracts VK code" {
    try std.testing.expectEqual(@as(u32, 0x41), nvim_core.Core.winVk(WIN_VK_FLAG | 0x41));
}

test "winSpecialName returns correct names" {
    try std.testing.expectEqualStrings("Left", nvim_core.Core.winSpecialName(0x25).?);
    try std.testing.expectEqualStrings("Esc", nvim_core.Core.winSpecialName(0x1B).?);
    try std.testing.expect(nvim_core.Core.winSpecialName(0x41) == null); // 'A' is not special
}

test "macSpecialName returns correct names" {
    try std.testing.expectEqualStrings("Left", nvim_core.Core.macSpecialName(123).?);
    try std.testing.expectEqualStrings("Esc", nvim_core.Core.macSpecialName(53).?);
    try std.testing.expect(nvim_core.Core.macSpecialName(0) == null); // 0 is not special
}
