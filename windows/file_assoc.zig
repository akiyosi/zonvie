// Windows file association icon registration for Zonvie.
//
// Registers Applications\zonvie.exe with DefaultIcon pointing to
// zombie_txt_icon.ico (resource ID 2). When the user sets Zonvie
// as the default app for a file type via "Open with", Windows uses
// this icon for those files in Explorer.
//
// Called once on first launch (when no config file exists).

const std = @import("std");
const c = @import("win32.zig").c;

// ============================================================
// Win32 Registry API (advapi32.dll)
// ============================================================

const HKEY = *anyopaque;
const LSTATUS = c.LONG;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_WRITE: c.DWORD = 0x20006;
const REG_SZ: c.DWORD = 1;
const REG_OPTION_NON_VOLATILE: c.DWORD = 0;
const ERROR_SUCCESS: c.LONG = 0;

extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    Reserved: c.DWORD,
    lpClass: ?[*:0]const u16,
    dwOptions: c.DWORD,
    samDesired: c.DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*c.DWORD,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: ?[*:0]const u16,
    Reserved: c.DWORD,
    dwType: c.DWORD,
    lpData: ?[*]const u8,
    cbData: c.DWORD,
) callconv(.winapi) LSTATUS;

extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) LSTATUS;

// Shell notification
extern "shell32" fn SHChangeNotify(
    wEventId: c.LONG,
    uFlags: c.UINT,
    dwItem1: ?*const anyopaque,
    dwItem2: ?*const anyopaque,
) callconv(.winapi) void;

const SHCNE_ASSOCCHANGED: c.LONG = 0x08000000;
const SHCNF_IDLIST: c.UINT = 0;

// ============================================================
// Public API
// ============================================================

/// Register Applications\zonvie.exe with DefaultIcon and shell\open\command.
/// Called on startup. When the user picks Zonvie via "Open with",
/// Windows uses zombie_txt_icon.ico (resource ID 2) as the file icon.
/// Returns true on success, false if any registry operation fails.
pub fn registerAppIcon() bool {
    var exe_path: [260]u16 = undefined;
    const exe_len = c.GetModuleFileNameW(null, &exe_path, 260);
    if (exe_len == 0 or exe_len >= 260) return false;
    const len: usize = @intCast(exe_len);

    var ok = true;

    // DefaultIcon = "<exe>,-2"  (negative = resource ID, not ordinal index)
    {
        const key = comptime std.unicode.utf8ToUtf16LeStringLiteral(
            "Software\\Classes\\Applications\\zonvie.exe\\DefaultIcon",
        );
        var icon_val: [270]u16 = undefined;
        @memcpy(icon_val[0..len], exe_path[0..len]);
        icon_val[len] = ',';
        icon_val[len + 1] = '-';
        icon_val[len + 2] = '2';
        icon_val[len + 3] = 0;

        var hkey: HKEY = undefined;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, null, REG_OPTION_NON_VOLATILE, KEY_WRITE, null, &hkey, null) == ERROR_SUCCESS) {
            if (!setStringValue(hkey, null, (icon_val[0 .. len + 3 :0]).ptr)) ok = false;
            _ = RegCloseKey(hkey);
        } else {
            ok = false;
        }
    }

    // shell\open\command = "\"<exe>\" \"%1\""
    {
        const key = comptime std.unicode.utf8ToUtf16LeStringLiteral(
            "Software\\Classes\\Applications\\zonvie.exe\\shell\\open\\command",
        );
        const suffix = comptime std.unicode.utf8ToUtf16LeStringLiteral("\" \"%1\"");
        var cmd_val: [280]u16 = undefined;
        cmd_val[0] = '"';
        @memcpy(cmd_val[1 .. 1 + len], exe_path[0..len]);
        const suf_start = 1 + len;
        @memcpy(cmd_val[suf_start .. suf_start + suffix.len], suffix);
        cmd_val[suf_start + suffix.len] = 0;

        var hkey: HKEY = undefined;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, null, REG_OPTION_NON_VOLATILE, KEY_WRITE, null, &hkey, null) == ERROR_SUCCESS) {
            if (!setStringValue(hkey, null, (cmd_val[0 .. suf_start + suffix.len :0]).ptr)) ok = false;
            _ = RegCloseKey(hkey);
        } else {
            ok = false;
        }
    }

    // Notify Explorer to pick up the new icon
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, null, null);
    return ok;
}

fn setStringValue(key: HKEY, name: ?[*:0]const u16, data: [*:0]const u16) bool {
    const data_len = std.mem.len(data);
    const byte_size: c.DWORD = @intCast((data_len + 1) * @sizeOf(u16));
    return RegSetValueExW(key, name, 0, REG_SZ, @ptrCast(data), byte_size) == ERROR_SUCCESS;
}
