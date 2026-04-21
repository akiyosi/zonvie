// Windows Jump List integration for Zonvie.
//
// Registers taskbar right-click menu items (Jump List "Tasks" category)
// using the ICustomDestinationList COM API.
//
// Windows requires the app to have a Start Menu shortcut (.lnk) with a
// matching explicit AppUserModelID for Jump Lists to work reliably. On
// first launch, the user is asked whether to create one. The choice is
// remembered via a marker file in %APPDATA%\zonvie\.
//
// Currently adds:
//   - "New Session" — launches a new zonvie.exe instance

const std = @import("std");
const c = @import("win32.zig").c;
const applog = @import("app.zig").applog;

// ============================================================
// COM extern declarations (ole32.dll / shell32.dll)
// ============================================================

const GUID = extern struct {
    Data1: c.ULONG,
    Data2: c.USHORT,
    Data3: c.USHORT,
    Data4: [8]u8,
};

const HRESULT = c.LONG;
const S_OK: HRESULT = 0;
const COINIT_APARTMENTTHREADED: c.DWORD = 0x2;
const COINIT_DISABLE_OLE1DDE: c.DWORD = 0x4;
const CLSCTX_INPROC_SERVER: c.DWORD = 0x1;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: c.DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: c.DWORD, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT;
extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(AppID: [*:0]const u16) callconv(.winapi) HRESULT;

// ============================================================
// COM GUIDs
// ============================================================

const CLSID_DestinationList = GUID{ .Data1 = 0x77f10cf0, .Data2 = 0x3db5, .Data3 = 0x4966, .Data4 = .{ 0xb5, 0x20, 0xb7, 0xc5, 0x4f, 0xd3, 0x5e, 0xd6 } };
const CLSID_EnumerableObjectCollection = GUID{ .Data1 = 0x2d3468c1, .Data2 = 0x36a7, .Data3 = 0x43b6, .Data4 = .{ 0xac, 0x24, 0xd3, 0xf0, 0x2f, 0xd9, 0x60, 0x7a } };
const CLSID_ShellLink = GUID{ .Data1 = 0x00021401, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

const IID_IShellLinkW = GUID{ .Data1 = 0x000214F9, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IPropertyStore = GUID{ .Data1 = 0x886d8eeb, .Data2 = 0x8cf2, .Data3 = 0x4446, .Data4 = .{ 0x8d, 0x02, 0xcd, 0xba, 0x1d, 0xbd, 0xcf, 0x99 } };
const IID_ICustomDestinationList = GUID{ .Data1 = 0x6332debf, .Data2 = 0x87b5, .Data3 = 0x4670, .Data4 = .{ 0x90, 0xc0, 0x5e, 0x57, 0xb4, 0x08, 0xa4, 0x9e } };
const IID_IObjectCollection = GUID{ .Data1 = 0x5632b1a4, .Data2 = 0xe38a, .Data3 = 0x400a, .Data4 = .{ 0x92, 0x8a, 0xd4, 0xcd, 0x63, 0x23, 0x02, 0x95 } };
const IID_IObjectArray = GUID{ .Data1 = 0x92CA9DCD, .Data2 = 0x5622, .Data3 = 0x4BBA, .Data4 = .{ 0xA8, 0x05, 0x5E, 0x9F, 0x54, 0x1B, 0xD8, 0xC9 } };
const IID_IPersistFile = GUID{ .Data1 = 0x0000010b, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

// ============================================================
// PROPVARIANT / PROPERTYKEY
// ============================================================

const PROPVARIANT = extern struct {
    vt: c.USHORT,
    wReserved1: c.USHORT = 0,
    wReserved2: c.USHORT = 0,
    wReserved3: c.USHORT = 0,
    pwszVal: ?[*:0]const u16 = null,
    _pad: usize = 0,
};

const VT_LPWSTR: c.USHORT = 31;

const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: c.DWORD,
};

const PKEY_Title = PROPERTYKEY{
    .fmtid = .{ .Data1 = 0xF29F85E0, .Data2 = 0x4FF9, .Data3 = 0x1068, .Data4 = .{ 0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9 } },
    .pid = 2,
};

const PKEY_AppUserModel_ID = PROPERTYKEY{
    .fmtid = .{ .Data1 = 0x9F4C2855, .Data2 = 0x9F79, .Data3 = 0x4B39, .Data4 = .{ 0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3 } },
    .pid = 5,
};

// ============================================================
// COM vtable definitions (C-style, matching CINTERFACE layout)
// ============================================================

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
};

const IShellLinkWVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    GetPath: *const anyopaque,
    GetIDList: *const anyopaque,
    SetIDList: *const anyopaque,
    GetDescription: *const anyopaque,
    SetDescription: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetWorkingDirectory: *const anyopaque,
    SetWorkingDirectory: *const anyopaque,
    GetArguments: *const anyopaque,
    SetArguments: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetHotkey: *const anyopaque,
    SetHotkey: *const anyopaque,
    GetShowCmd: *const anyopaque,
    SetShowCmd: *const anyopaque,
    GetIconLocation: *const anyopaque,
    SetIconLocation: *const fn (*anyopaque, [*:0]const u16, c.INT) callconv(.winapi) HRESULT,
    SetRelativePath: *const anyopaque,
    Resolve: *const anyopaque,
    SetPath: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
};

const IPropertyStoreVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    GetCount: *const anyopaque,
    GetAt: *const anyopaque,
    GetValue: *const anyopaque,
    SetValue: *const fn (*anyopaque, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
    Commit: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

const IObjectArrayVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    GetCount: *const fn (*anyopaque, *c.UINT) callconv(.winapi) HRESULT,
    GetAt: *const anyopaque,
};

const IObjectCollectionVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    GetCount: *const anyopaque,
    GetAt: *const anyopaque,
    AddObject: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    AddFromArray: *const anyopaque,
    RemoveObjectAt: *const anyopaque,
    Clear: *const anyopaque,
};

const ICustomDestinationListVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    SetAppID: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    BeginList: *const fn (*anyopaque, *c.UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AppendCategory: *const anyopaque,
    AppendKnownCategory: *const anyopaque,
    AddUserTasks: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    CommitList: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    GetRemovedDestinations: *const anyopaque,
    DeleteList: *const fn (*anyopaque, ?[*:0]const u16) callconv(.winapi) HRESULT,
    AbortList: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

const IPersistFileVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
    GetClassID: *const anyopaque,
    IsDirty: *const anyopaque,
    Load: *const anyopaque,
    Save: *const fn (*anyopaque, [*:0]const u16, c.BOOL) callconv(.winapi) HRESULT,
    SaveCompleted: *const anyopaque,
    GetCurFile: *const anyopaque,
};

// ============================================================
// COM helpers
// ============================================================

fn comVtbl(comptime Vtbl: type, obj: *anyopaque) *const Vtbl {
    const ptr: *const *const Vtbl = @ptrCast(@alignCast(obj));
    return ptr.*;
}

fn comRelease(obj: *anyopaque) void {
    _ = comVtbl(IUnknownVtbl, obj).Release(obj);
}

fn comQueryInterface(obj: *anyopaque, iid: *const GUID) ?*anyopaque {
    var result: ?*anyopaque = null;
    if (comVtbl(IUnknownVtbl, obj).QueryInterface(obj, iid, &result) != S_OK) return null;
    return result;
}

// ============================================================
// Wide-string path helpers
// ============================================================

/// Build a null-terminated u16 path in `buf` by concatenating segments.
/// Returns the total length (excluding null), or null if the buffer is too small.
fn buildPath(buf: []u16, segments: []const [*:0]const u16) ?usize {
    var pos: usize = 0;
    for (segments) |seg| {
        var k: usize = 0;
        while (seg[k] != 0) : (k += 1) {
            if (pos >= buf.len - 1) return null;
            buf[pos] = seg[k];
            pos += 1;
        }
    }
    buf[pos] = 0;
    return pos;
}

/// Build a path from APPDATA env + suffix. Returns length or null.
fn buildAppdataPath(buf: []u16, suffix: [*:0]const u16) ?usize {
    var appdata_buf: [260]u16 = std.mem.zeroes([260]u16);
    const appdata_len = c.GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("APPDATA"),
        &appdata_buf,
        260,
    );
    if (appdata_len == 0 or appdata_len >= 260) return null;
    const appdata_ptr: [*:0]const u16 = @ptrCast(&appdata_buf);
    return buildPath(buf, &.{ appdata_ptr, suffix });
}

fn fileExists(path: [*:0]const u16) bool {
    return c.GetFileAttributesW(path) != c.INVALID_FILE_ATTRIBUTES;
}

fn touchFile(path: [*:0]const u16) void {
    const h = c.CreateFileW(
        path,
        c.GENERIC_WRITE,
        0,
        null,
        c.CREATE_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(h);
}

// ============================================================
// Public API
// ============================================================

const APP_USER_MODEL_ID = std.unicode.utf8ToUtf16LeStringLiteral("Zonvie.Zonvie");

/// Initialize COM for the calling thread (STA).
pub fn initCom() void {
    const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (hr != S_OK and hr != 1) {
        if (applog.isEnabled()) applog.appLog("[win] CoInitializeEx failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
    }

    const appid_hr = SetCurrentProcessExplicitAppUserModelID(APP_USER_MODEL_ID);
    if (appid_hr != S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] SetCurrentProcessExplicitAppUserModelID failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(appid_hr))});
    }
}

/// Register Jump List tasks on the Windows taskbar.
/// Uses an explicit AppUserModelID and a matching Start Menu shortcut.
pub fn initJumpList() void {
    var exe_path_buf: [260]u16 = std.mem.zeroes([260]u16);
    const exe_len = c.GetModuleFileNameW(null, &exe_path_buf, 260);
    if (exe_len == 0 or exe_len >= 260) return;
    const exe_path: [*:0]const u16 = @ptrCast(&exe_path_buf);

    // Build shortcut path
    var lnk_buf: [512]u16 = std.mem.zeroes([512]u16);
    if (buildAppdataPath(&lnk_buf, std.unicode.utf8ToUtf16LeStringLiteral("\\Microsoft\\Windows\\Start Menu\\Programs\\Zonvie.lnk")) == null) return;
    const lnk_path: [*:0]const u16 = @ptrCast(&lnk_buf);

    // Build decline marker path
    var marker_buf: [512]u16 = std.mem.zeroes([512]u16);
    if (buildAppdataPath(&marker_buf, std.unicode.utf8ToUtf16LeStringLiteral("\\zonvie\\.jumplist_declined")) == null) return;
    const marker_path: [*:0]const u16 = @ptrCast(&marker_buf);

    if (!fileExists(lnk_path)) {
        if (createStartMenuShortcut(exe_path, lnk_path)) {
            if (applog.isEnabled()) applog.appLog("[win] Jump List: shortcut created\n", .{});
        } else {
            if (fileExists(marker_path)) {
                if (applog.isEnabled()) applog.appLog("[win] Jump List: shortcut missing and user previously declined\n", .{});
                return;
            }

            const result = c.MessageBoxW(
                null,
                std.unicode.utf8ToUtf16LeStringLiteral(
                    "Zonvie can add items to the taskbar right-click menu.\r\n\r\n" ++
                        "This requires creating a Start Menu shortcut for the app.\r\n\r\n" ++
                        "Create the shortcut now?",
                ),
                std.unicode.utf8ToUtf16LeStringLiteral("Zonvie"),
                c.MB_YESNO | c.MB_ICONQUESTION,
            );

            if (result != c.IDYES) {
                touchFile(marker_path);
                return;
            }

            if (!createStartMenuShortcut(exe_path, lnk_path)) {
                if (applog.isEnabled()) applog.appLog("[win] Jump List: failed to create shortcut after confirmation\n", .{});
                return;
            }
        }
    } else if (!createStartMenuShortcut(exe_path, lnk_path)) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: failed to refresh shortcut\n", .{});
        return;
    }

    // Shortcut exists — register Jump List
    if (applog.isEnabled()) applog.appLog("[win] Jump List: registering\n", .{});
    registerJumpList(exe_path);
}

// ============================================================
// Start Menu shortcut
// ============================================================

/// Create or refresh the Start Menu shortcut used for Jump List association.
fn createStartMenuShortcut(exe_path: [*:0]const u16, lnk_path: [*:0]const u16) bool {
    var link_raw: ?*anyopaque = null;
    var hr = CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &link_raw);
    if (hr != S_OK or link_raw == null) return false;
    const link = link_raw.?;
    defer comRelease(link);

    if (!configureShellLink(link, exe_path, null, std.unicode.utf8ToUtf16LeStringLiteral("Zonvie"), exe_path)) {
        return false;
    }

    if (comQueryInterface(link, &IID_IPersistFile)) |pf| {
        const pf_vtbl = comVtbl(IPersistFileVtbl, pf);
        hr = pf_vtbl.Save(pf, lnk_path, 1);
        if (applog.isEnabled()) applog.appLog("[win] Jump List: shortcut Save hr=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        comRelease(pf);
        return hr == S_OK;
    }
    return false;
}

// ============================================================
// Jump List registration
// ============================================================

fn registerJumpList(exe_path: [*:0]const u16) void {
    // Create ICustomDestinationList
    var dest_list_raw: ?*anyopaque = null;
    var hr = CoCreateInstance(&CLSID_DestinationList, null, CLSCTX_INPROC_SERVER, &IID_ICustomDestinationList, &dest_list_raw);
    if (hr != S_OK or dest_list_raw == null) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: CoCreateInstance(DestinationList) failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        return;
    }
    const dest_list = dest_list_raw.?;
    defer comRelease(dest_list);
    const dest_vtbl = comVtbl(ICustomDestinationListVtbl, dest_list);

    hr = dest_vtbl.SetAppID(dest_list, APP_USER_MODEL_ID);
    if (hr != S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: SetAppID failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        return;
    }

    // BeginList
    var removed_raw: ?*anyopaque = null;
    var max_slots: c.UINT = 0;
    hr = dest_vtbl.BeginList(dest_list, &max_slots, &IID_IObjectArray, &removed_raw);
    if (hr != S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: BeginList failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        return;
    }
    if (applog.isEnabled()) applog.appLog("[win] Jump List: BeginList ok, maxSlots={d}\n", .{max_slots});
    if (removed_raw) |removed| comRelease(removed);

    // Create task collection
    var coll_raw: ?*anyopaque = null;
    hr = CoCreateInstance(&CLSID_EnumerableObjectCollection, null, CLSCTX_INPROC_SERVER, &IID_IObjectCollection, &coll_raw);
    if (hr != S_OK or coll_raw == null) {
        _ = dest_vtbl.AbortList(dest_list);
        return;
    }
    const coll = coll_raw.?;
    defer comRelease(coll);

    // Add "New Session" task
    var cmd_path_buf: [260]u16 = std.mem.zeroes([260]u16);
    const cmd_path = buildComSpecPath(&cmd_path_buf) orelse std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");

    var new_session_args_buf: [1024]u16 = std.mem.zeroes([1024]u16);
    const new_session_args = buildNewSessionTaskArgs(&new_session_args_buf, exe_path) orelse null;

    if (createTaskLink(cmd_path, new_session_args, std.unicode.utf8ToUtf16LeStringLiteral("New Sessions"), exe_path)) |link| {
        hr = comVtbl(IObjectCollectionVtbl, coll).AddObject(coll, link);
        if (applog.isEnabled()) applog.appLog("[win] Jump List: AddObject hr=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        comRelease(link);
    } else {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: createTaskLink failed\n", .{});
        _ = dest_vtbl.AbortList(dest_list);
        return;
    }

    // AddUserTasks
    if (comQueryInterface(coll, &IID_IObjectArray)) |array| {
        hr = dest_vtbl.AddUserTasks(dest_list, array);
        if (applog.isEnabled()) applog.appLog("[win] Jump List: AddUserTasks hr=0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        comRelease(array);
    } else {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: QI IObjectArray failed\n", .{});
        _ = dest_vtbl.AbortList(dest_list);
        return;
    }

    // Commit
    hr = dest_vtbl.CommitList(dest_list);
    if (hr != S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: CommitList failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
    } else {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: registered successfully\n", .{});
    }
}

fn configureShellLink(link: *anyopaque, exe_path: [*:0]const u16, args: ?[*:0]const u16, title: ?[*:0]const u16, icon_path: [*:0]const u16) bool {
    const vtbl = comVtbl(IShellLinkWVtbl, link);
    var hr = vtbl.SetPath(link, exe_path);
    if (hr != S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] Jump List: SetPath failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        return false;
    }

    if (args) |task_args| {
        hr = vtbl.SetArguments(link, task_args);
        if (hr != S_OK) {
            if (applog.isEnabled()) applog.appLog("[win] Jump List: SetArguments failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
            return false;
        }
    }

    _ = vtbl.SetDescription(link, std.unicode.utf8ToUtf16LeStringLiteral("Zonvie - Neovim GUI"));
    _ = vtbl.SetIconLocation(link, icon_path, 0);

    if (comQueryInterface(link, &IID_IPropertyStore)) |store| {
        defer comRelease(store);
        const store_vtbl = comVtbl(IPropertyStoreVtbl, store);

        var app_id_value = PROPVARIANT{ .vt = VT_LPWSTR, .pwszVal = APP_USER_MODEL_ID };
        hr = store_vtbl.SetValue(store, &PKEY_AppUserModel_ID, &app_id_value);
        if (hr != S_OK) {
            if (applog.isEnabled()) applog.appLog("[win] Jump List: SetValue(AppUserModelID) failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
            return false;
        }

        if (title) |task_title| {
            var title_value = PROPVARIANT{ .vt = VT_LPWSTR, .pwszVal = task_title };
            hr = store_vtbl.SetValue(store, &PKEY_Title, &title_value);
            if (hr != S_OK) {
                if (applog.isEnabled()) applog.appLog("[win] Jump List: SetValue(Title) failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
                return false;
            }
        }

        hr = store_vtbl.Commit(store);
        if (hr != S_OK) {
            if (applog.isEnabled()) applog.appLog("[win] Jump List: PropertyStore.Commit failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
            return false;
        }
        return true;
    }

    if (applog.isEnabled()) applog.appLog("[win] Jump List: QI IPropertyStore failed\n", .{});
    return false;
}

fn createTaskLink(exe_path: [*:0]const u16, args: ?[*:0]const u16, title: [*:0]const u16, icon_path: [*:0]const u16) ?*anyopaque {
    var link_raw: ?*anyopaque = null;
    const hr = CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &link_raw);
    if (hr != S_OK or link_raw == null) return null;
    const link = link_raw.?;
    if (!configureShellLink(link, exe_path, args, title, icon_path)) {
        comRelease(link);
        return null;
    }
    return link;
}

fn buildComSpecPath(buf: []u16) ?[*:0]const u16 {
    const len = c.GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("ComSpec"),
        buf.ptr,
        @intCast(buf.len),
    );
    if (len == 0 or len >= buf.len) return null;
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

fn buildNewSessionTaskArgs(buf: []u16, exe_path: [*:0]const u16) ?[*:0]const u16 {
    _ = buildPath(buf, &.{
        std.unicode.utf8ToUtf16LeStringLiteral("/d /s /c \"set ZONVIE_INTERNAL_SHOW_NEW_SESSION_DIALOG=1 && start \"\" \""),
        exe_path,
        std.unicode.utf8ToUtf16LeStringLiteral("\"\""),
    }) orelse return null;
    return @ptrCast(buf.ptr);
}
