const std = @import("std");
const core = @import("zonvie_core");
const testing = std.testing;

const GDK_SHIFT_MASK: u32 = 1;
const GDK_CONTROL_MASK: u32 = 4;
const GDK_ALT_MASK: u32 = 8;
const GDK_SUPER_MASK: u32 = 1 << 26;

/// Keys the core names in `winSpecialName` (src/core/nvim_core.zig), as
/// `0x10000 | VK`. Everything else, including keypad digits, reaches the core
/// as text.
pub fn coreKeycode(keyval: u32) u32 {
    const vk: u32 = switch (keyval) {
        0xff51 => 0x25, // Left
        0xff52 => 0x26, // Up
        0xff53 => 0x27, // Right
        0xff54 => 0x28, // Down
        0xff50 => 0x24, // Home
        0xff57 => 0x23, // End
        0xff55 => 0x21, // Page_Up
        0xff56 => 0x22, // Page_Down
        0xff08 => 0x08, // BackSpace
        0xffff => 0x2E, // Delete
        0xff0d, 0xff8d => 0x0D, // Return, KP_Enter
        0xff09, 0xfe20 => 0x09, // Tab, ISO_Left_Tab (Shift+Tab)
        0xff1b => 0x1B, // Escape
        0xff63 => 0x2D, // Insert
        0xffbe...0xffd5 => 0x70 + (keyval - 0xffbe), // F1..F24
        else => return 0,
    };
    return 0x10000 | vk;
}

pub fn coreMods(gdk_state: u32) u32 {
    var m: u32 = 0;
    if (gdk_state & GDK_CONTROL_MASK != 0) m |= core.MOD_CTRL;
    if (gdk_state & GDK_ALT_MASK != 0) m |= core.MOD_ALT;
    if (gdk_state & GDK_SHIFT_MASK != 0) m |= core.MOD_SHIFT;
    if (gdk_state & GDK_SUPER_MASK != 0) m |= core.MOD_SUPER;
    return m;
}

pub fn mouseModString(gdk_state: u32, buf: *[8]u8) [:0]const u8 {
    var n: usize = 0;
    const order = [_]struct { mask: u32, letter: u8 }{
        .{ .mask = GDK_SHIFT_MASK, .letter = 'S' },
        .{ .mask = GDK_CONTROL_MASK, .letter = 'C' },
        .{ .mask = GDK_ALT_MASK, .letter = 'A' },
        .{ .mask = GDK_SUPER_MASK, .letter = 'D' },
    };
    for (order) |o| {
        if (gdk_state & o.mask == 0) continue;
        buf[n] = o.letter;
        n += 1;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

/// While a preedit is active the IME owns every key, including Return.
pub fn swallowDuringPreedit(preedit_active: bool, keyval: u32) bool {
    _ = keyval;
    return preedit_active;
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
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("SC", mouseModString(1 | 4, &buf));
    try testing.expectEqualStrings("", mouseModString(0, &buf));
    try testing.expectEqualStrings("SCAD", mouseModString(1 | 4 | 8 | (1 << 26), &buf));
}

test "key during preedit is swallowed" {
    try testing.expect(swallowDuringPreedit(true, 0xff0d)); // Return
    try testing.expect(!swallowDuringPreedit(false, 0xff0d));
}
