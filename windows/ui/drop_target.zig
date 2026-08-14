//! OLE drop target for file drags.
//!
//! WM_DROPFILES cannot influence the drag cursor, so the main window and the
//! external cmdline window register an IDropTarget as well. DragEnter/DragOver
//! answer with the effect that matches what the drop will actually do —
//! DROPEFFECT_LINK where the path is inserted as text, DROPEFFECT_COPY where
//! the file is opened — which is the only per-target feedback Windows offers a
//! destination. Unlike macOS the dragged image itself cannot be replaced: it
//! belongs to the drag source (Explorer), so the difference shows up as the
//! cursor's badge rather than as a path chip.
//!
//! WM_DROPFILES stays wired up as a fallback: if RegisterDragDrop fails the
//! legacy path still delivers drops, just without the badge.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const window_mod = @import("../window.zig");

/// Declared locally rather than taken from the UUID import library, which the
/// Windows target does not link.
const IID_IUnknown = c.GUID{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const IID_IDropTarget = c.GUID{
    .Data1 = 0x00000122,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

fn guidEql(a: *const c.GUID, b: *const c.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// A COM object: the vtable pointer must be the first field so a *DropTarget
/// can be handed to OLE as an IDropTarget*.
pub const DropTarget = extern struct {
    lpVtbl: *const c.IDropTargetVtbl,
    ref_count: u32,
    app: *App,
    /// Set for the external cmdline window, whose drops always insert.
    force_cmdline: bool,
    /// Latched in DragEnter: whether this drag carries files at all.
    has_files: bool,
    /// Also latched in DragEnter. DragOver fires on every mouse move, and
    /// dropInsertsPath takes the core's grid lock — recomputing it per move
    /// would put a blocking acquisition in the middle of a drag. The editor
    /// mode cannot change while the button is held anyway.
    inserts_path: bool,

    /// `allowed` is what the drag SOURCE permits — it arrives in *pdwEffect on
    /// entry to every method. Returning an effect the source did not offer is
    /// a protocol violation and the drop can be refused outright, so the
    /// preferred badge is only used when it is on offer.
    fn effectFor(self: *const DropTarget, allowed: c.DWORD) c.DWORD {
        const none: c.DWORD = @intCast(c.DROPEFFECT_NONE);
        const copy: c.DWORD = @intCast(c.DROPEFFECT_COPY);
        const link: c.DWORD = @intCast(c.DROPEFFECT_LINK);
        if (!self.has_files) return none;

        const preferred: c.DWORD = if (self.inserts_path) link else copy;
        if (allowed & preferred != 0) return preferred;
        // The badge is a nicety; delivering the drop is not. Fall back to any
        // effect the source does offer rather than refusing.
        if (allowed & copy != 0) return copy;
        if (allowed & link != 0) return link;
        return none;
    }
};

fn selfFrom(this: ?*c.IDropTarget) ?*DropTarget {
    return @ptrCast(@alignCast(this orelse return null));
}

fn queryInterface(
    this: [*c]c.IDropTarget,
    riid: [*c]const c.IID,
    ppv: [*c]?*anyopaque,
) callconv(.winapi) c.HRESULT {
    if (ppv == null) return c.E_POINTER;
    if (riid == null or this == null) {
        ppv.* = null;
        return c.E_POINTER;
    }
    if (guidEql(&riid.*, &IID_IUnknown) or guidEql(&riid.*, &IID_IDropTarget)) {
        ppv.* = this;
        _ = addRef(this);
        return c.S_OK;
    }
    ppv.* = null;
    return c.E_NOINTERFACE;
}

fn addRef(this: [*c]c.IDropTarget) callconv(.winapi) c.ULONG {
    const self = selfFrom(this) orelse return 0;
    self.ref_count += 1;
    return self.ref_count;
}

fn release(this: [*c]c.IDropTarget) callconv(.winapi) c.ULONG {
    const self = selfFrom(this) orelse return 0;
    self.ref_count -= 1;
    const remaining = self.ref_count;
    if (remaining == 0) {
        self.app.alloc.destroy(self);
    }
    return remaining;
}

fn dragEnter(
    this: [*c]c.IDropTarget,
    pDataObj: [*c]c.IDataObject,
    grfKeyState: c.DWORD,
    pt: c.POINTL,
    pdwEffect: [*c]c.DWORD,
) callconv(.winapi) c.HRESULT {
    _ = grfKeyState;
    _ = pt;
    const self = selfFrom(this) orelse return c.E_POINTER;
    self.has_files = dataObjectHasFiles(pDataObj);
    self.inserts_path = self.has_files and window_mod.dropInsertsPath(self.app, self.force_cmdline);
    if (pdwEffect != null) pdwEffect.* = self.effectFor(pdwEffect.*);
    return c.S_OK;
}

fn dragOver(
    this: [*c]c.IDropTarget,
    grfKeyState: c.DWORD,
    pt: c.POINTL,
    pdwEffect: [*c]c.DWORD,
) callconv(.winapi) c.HRESULT {
    _ = grfKeyState;
    _ = pt;
    const self = selfFrom(this) orelse return c.E_POINTER;
    if (pdwEffect != null) pdwEffect.* = self.effectFor(pdwEffect.*);
    return c.S_OK;
}

fn dragLeave(this: [*c]c.IDropTarget) callconv(.winapi) c.HRESULT {
    const self = selfFrom(this) orelse return c.E_POINTER;
    self.has_files = false;
    self.inserts_path = false;
    return c.S_OK;
}

fn drop(
    this: [*c]c.IDropTarget,
    pDataObj: [*c]c.IDataObject,
    grfKeyState: c.DWORD,
    pt: c.POINTL,
    pdwEffect: [*c]c.DWORD,
) callconv(.winapi) c.HRESULT {
    _ = grfKeyState;
    _ = pt;
    const self = selfFrom(this) orelse return c.E_POINTER;
    const applied = if (pdwEffect != null) self.effectFor(pdwEffect.*) else @as(c.DWORD, 0);
    defer {
        self.has_files = false;
        self.inserts_path = false;
    }

    if (self.has_files) {
        if (getHDrop(pDataObj)) |medium| {
            var stg = medium;
            // HDROP is an opaque USER handle, never dereferenced; translate-c
            // still gives it an alignment the void* does not carry.
            const hdrop: c.HDROP = @ptrCast(@alignCast(stg.unnamed_0.hGlobal));
            window_mod.handleDroppedFiles(self.app, hdrop, self.force_cmdline);
            c.ReleaseStgMedium(&stg);
        }
    }

    if (pdwEffect != null) pdwEffect.* = applied;
    return c.S_OK;
}

fn hdropFormat() c.FORMATETC {
    return .{
        .cfFormat = @intCast(c.CF_HDROP),
        .ptd = null,
        .dwAspect = c.DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = c.TYMED_HGLOBAL,
    };
}

fn dataObjectHasFiles(pDataObj: [*c]c.IDataObject) bool {
    if (pDataObj == null) return false;
    const vtbl = pDataObj.*.lpVtbl orelse return false;
    const query = vtbl.*.QueryGetData orelse return false;
    var fmt = hdropFormat();
    return query(pDataObj, &fmt) == c.S_OK;
}

fn getHDrop(pDataObj: [*c]c.IDataObject) ?c.STGMEDIUM {
    if (pDataObj == null) return null;
    const vtbl = pDataObj.*.lpVtbl orelse return null;
    const get_data = vtbl.*.GetData orelse return null;
    var fmt = hdropFormat();
    var stg: c.STGMEDIUM = std.mem.zeroes(c.STGMEDIUM);
    if (get_data(pDataObj, &fmt, &stg) != c.S_OK) return null;
    return stg;
}

const vtbl_instance = c.IDropTargetVtbl{
    .QueryInterface = queryInterface,
    .AddRef = addRef,
    .Release = release,
    .DragEnter = dragEnter,
    .DragOver = dragOver,
    .DragLeave = dragLeave,
    .Drop = drop,
};

/// Register an OLE drop target on `hwnd`. Returns the object on success; the
/// caller owns the one reference and must revoke() it before the window dies.
/// On failure the caller should leave the WM_DROPFILES fallback in place.
pub fn register(app: *App, hwnd: c.HWND, force_cmdline: bool) ?*DropTarget {
    const self = app.alloc.create(DropTarget) catch return null;
    self.* = .{
        .lpVtbl = &vtbl_instance,
        .ref_count = 1,
        .app = app,
        .force_cmdline = force_cmdline,
        .has_files = false,
        .inserts_path = false,
    };

    const hr = c.RegisterDragDrop(hwnd, @ptrCast(self));
    if (hr != c.S_OK) {
        if (applog.isEnabled()) applog.appLog("[win] RegisterDragDrop failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
        app.alloc.destroy(self);
        return null;
    }

    // OLE now owns the window's drops; the legacy shell path would only
    // duplicate them.
    c.DragAcceptFiles(hwnd, 0);
    return self;
}

/// Revoke and release a target registered by register().
pub fn revoke(hwnd: c.HWND, target: *DropTarget) void {
    _ = c.RevokeDragDrop(hwnd);
    _ = release(@ptrCast(target));
}
