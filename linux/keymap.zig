const std = @import("std");
const core = @import("zonvie_core");
const testing = std.testing;

// The modifier masks wl/window.c reports (its MASK_*).
const MASK_SHIFT: u32 = 1;
const MASK_CTRL: u32 = 4;
const MASK_ALT: u32 = 8;
const MASK_SUPER: u32 = 1 << 26;

/// Keys the core names in `winSpecialName` (src/core/nvim_core.zig), as
/// `0x10000 | VK`. Everything else, including keypad digits, reaches the core
/// as text. The keypad's navigation keys (NumLock off) are their main-block
/// twins, as Windows reports them.
pub fn coreKeycode(keyval: u32) u32 {
    const vk: u32 = switch (keyval) {
        0xff51, 0xff96 => 0x25, // Left, KP_Left
        0xff52, 0xff97 => 0x26, // Up, KP_Up
        0xff53, 0xff98 => 0x27, // Right, KP_Right
        0xff54, 0xff99 => 0x28, // Down, KP_Down
        0xff50, 0xff95 => 0x24, // Home, KP_Home
        0xff57, 0xff9c => 0x23, // End, KP_End
        0xff55, 0xff9a => 0x21, // Page_Up, KP_Page_Up
        0xff56, 0xff9b => 0x22, // Page_Down, KP_Page_Down
        0xff08 => 0x08, // BackSpace
        0xffff, 0xff9f => 0x2E, // Delete, KP_Delete
        0xff0d, 0xff8d => 0x0D, // Return, KP_Enter
        0xff09, 0xfe20 => 0x09, // Tab, ISO_Left_Tab (Shift+Tab)
        0xff1b => 0x1B, // Escape
        0xff63, 0xff9e => 0x2D, // Insert, KP_Insert
        0xffbe...0xffd5 => 0x70 + (keyval - 0xffbe), // F1..F24
        else => return 0,
    };
    return 0x10000 | vk;
}

/// The `:` <-> `;` swap ([input] swap_colon_semicolon) for one typed
/// character. Paste and IME commits do not come through here.
pub fn swapColonSemicolon(scalar: u32, enabled: bool) u32 {
    if (!enabled) return scalar;
    return switch (scalar) {
        ':' => ';',
        ';' => ':',
        else => scalar,
    };
}

test "colon and semicolon swap only when enabled" {
    try testing.expectEqual(@as(u32, ';'), swapColonSemicolon(':', true));
    try testing.expectEqual(@as(u32, ':'), swapColonSemicolon(';', true));
    try testing.expectEqual(@as(u32, 'a'), swapColonSemicolon('a', true));
    try testing.expectEqual(@as(u32, ':'), swapColonSemicolon(':', false));
}

pub fn coreMods(mask: u32) u32 {
    var m: u32 = 0;
    if (mask & MASK_CTRL != 0) m |= core.MOD_CTRL;
    if (mask & MASK_ALT != 0) m |= core.MOD_ALT;
    if (mask & MASK_SHIFT != 0) m |= core.MOD_SHIFT;
    if (mask & MASK_SUPER != 0) m |= core.MOD_SUPER;
    return m;
}

pub fn mouseModString(mask: u32, buf: *[5]u8) [:0]const u8 {
    return core.frontend_rules.mouseModifierString(buf, coreMods(mask));
}

/// The frontend's own shortcuts, on Ctrl+Shift (macOS's Cmd: Super is the
/// compositor's on Linux, and Ctrl alone is Neovim's). Neovim never sees
/// them. The tab ones only with [tabline] style = "menu", as macOS binds
/// Cmd+T, Cmd+W and Cmd+1..9 to its Tabs menu.
pub const AppShortcut = union(enum) {
    new_session,
    quit,
    /// Ctrl+Shift+?: the only way to About when no app menu is drawn
    /// (titlebar_style "native" without sidebar or menu).
    about,
    new_tab,
    close_tab,
    /// The tab's 1-based number.
    select_tab: u8,
};

/// The shortcut `base_keyval` (the key's keyval with no modifier held:
/// '1', not '!') with `mask` names; null for a key Neovim gets.
/// `keyval` is the produced one: '?' sits on a different key per layout,
/// so About matches what the key types, the others the key itself.
pub fn appShortcut(base_keyval: u32, keyval: u32, mask: u32, menu_style: bool) ?AppShortcut {
    const mods = mask & (MASK_SHIFT | MASK_CTRL | MASK_ALT | MASK_SUPER);
    if (mods != MASK_SHIFT | MASK_CTRL) return null;
    if (keyval == '?') return .about;
    const k = if (base_keyval >= 'A' and base_keyval <= 'Z') base_keyval + 32 else base_keyval;
    return switch (k) {
        'n' => .new_session,
        'q' => .quit,
        't' => if (menu_style) .new_tab else null,
        'w' => if (menu_style) .close_tab else null,
        '1'...'9' => if (menu_style) .{ .select_tab = @intCast(k - '0') } else null,
        else => null,
    };
}

test "Ctrl+Shift shortcuts; the tab ones only with the menu style" {
    const cs = MASK_CTRL | MASK_SHIFT;
    try testing.expectEqual(AppShortcut.new_session, appShortcut('N', 'N', cs, false).?);
    try testing.expectEqual(AppShortcut.new_session, appShortcut('n', 'n', cs | 0x10, false).?); // NumLock (Mod2)
    try testing.expectEqual(AppShortcut.quit, appShortcut('q', 'q', cs, false).?);
    try testing.expectEqual(AppShortcut.about, appShortcut('/', '?', cs, false).?); // US
    try testing.expectEqual(AppShortcut.about, appShortcut(0xdf, '?', cs, false).?); // DE: Shift+ß
    try testing.expect(appShortcut('/', '/', MASK_CTRL, false) == null);
    try testing.expect(appShortcut('t', 't', cs, false) == null);
    try testing.expectEqual(AppShortcut.new_tab, appShortcut('t', 't', cs, true).?);
    try testing.expectEqual(AppShortcut{ .select_tab = 3 }, appShortcut('3', '#', cs, true).?);
    try testing.expect(appShortcut('n', 'n', MASK_CTRL, false) == null);
    try testing.expect(appShortcut('N', 'N', MASK_SHIFT, false) == null);
    try testing.expect(appShortcut('N', 'N', cs | MASK_ALT, false) == null);
}


test "special keys map to Win32 VK and the core treats them as special" {
    const cases = [_][2]u32{
        .{ 0xff51, 0x25 }, .{ 0xff52, 0x26 }, .{ 0xff53, 0x27 }, .{ 0xff54, 0x28 }, // arrows
        .{ 0xff50, 0x24 }, .{ 0xff57, 0x23 }, .{ 0xff55, 0x21 }, .{ 0xff56, 0x22 }, // Home End PgUp PgDn
        .{ 0xff63, 0x2D }, .{ 0xffff, 0x2E }, // Insert Delete
        .{ 0xffbe, 0x70 }, .{ 0xffc9, 0x7B }, // F1 F12
        .{ 0xffca, 0x7C }, .{ 0xffd5, 0x87 }, // F13 F24
        .{ 0xff08, 0x08 }, .{ 0xff09, 0x09 }, .{ 0xff0d, 0x0D }, .{ 0xff1b, 0x1B }, // BS Tab CR Esc
        .{ 0xff8d, 0x0D }, .{ 0xfe20, 0x09 }, // KP_Enter, ISO_Left_Tab (Shift+Tab)
        .{ 0xff95, 0x24 }, .{ 0xff96, 0x25 }, .{ 0xff97, 0x26 }, .{ 0xff98, 0x27 }, // KP_Home KP arrows
        .{ 0xff99, 0x28 }, .{ 0xff9a, 0x21 }, .{ 0xff9b, 0x22 }, .{ 0xff9c, 0x23 }, // KP_Down PgUp PgDn End
        .{ 0xff9e, 0x2D }, .{ 0xff9f, 0x2E }, // KP_Insert KP_Delete
    };
    for (cases) |c| {
        try testing.expectEqual(0x10000 | c[1], coreKeycode(c[0]));
        try testing.expect(core.zonvie_core_key_is_special(coreKeycode(c[0])));
    }
}

test "printable keys are not special" {
    try testing.expectEqual(@as(u32, 0), coreKeycode('a'));
    try testing.expectEqual(@as(u32, 0), coreKeycode(0x20)); // space
    try testing.expectEqual(@as(u32, 0), coreKeycode(0xffb1)); // KP_1: sent as text
}

test "mods" {
    try testing.expectEqual(core.MOD_CTRL | core.MOD_SHIFT, coreMods(4 | 1));
    try testing.expectEqual(core.MOD_ALT, coreMods(8));
    try testing.expectEqual(core.MOD_SUPER, coreMods(1 << 26));
    try testing.expectEqual(@as(u32, 0), coreMods(2)); // lock mask is not a modifier
}

test "mouse modifier string matches the core's S/C/A/D form" {
    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("SC", mouseModString(1 | 4, &buf));
    try testing.expectEqualStrings("", mouseModString(0, &buf));
    try testing.expectEqualStrings("SCAD", mouseModString(1 | 4 | 8 | (1 << 26), &buf));
}

