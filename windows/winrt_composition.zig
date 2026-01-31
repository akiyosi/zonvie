// WinRT Composition for backdrop blur effect
// Uses Windows.UI.Composition APIs via COM

const std = @import("std");
const c = @import("win32.zig").c;
const applog = @import("app_log.zig");

// WinRT types
// HSTRING is a handle (pointer) type
const HSTRING = ?*anyopaque;
// HSTRING_HEADER is an opaque structure - 24 bytes on 64-bit, 20 bytes on 32-bit
const HSTRING_HEADER = extern struct {
    Reserved: [24]u8, // Use max size for 64-bit
};

// RoInitializationType
const RO_INIT_SINGLETHREADED: i32 = 0;
const RO_INIT_MULTITHREADED: i32 = 1;

// DispatcherQueueOptions
const DispatcherQueueOptions = extern struct {
    dwSize: u32,
    threadType: i32, // DISPATCHERQUEUE_THREAD_TYPE
    apartmentType: i32, // DISPATCHERQUEUE_THREAD_APARTMENTTYPE
};

const DQTYPE_THREAD_DEDICATED: i32 = 1;
const DQTYPE_THREAD_CURRENT: i32 = 2;
const DQTAT_COM_NONE: i32 = 0;
const DQTAT_COM_ASTA: i32 = 1;
const DQTAT_COM_STA: i32 = 2;

// IIDs
const IID_IInspectable = c.GUID{
    .Data1 = 0xAF86E2E0,
    .Data2 = 0xB12D,
    .Data3 = 0x4c6a,
    .Data4 = .{ 0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90 },
};

const IID_ICompositorDesktopInterop = c.GUID{
    .Data1 = 0x29E691FA,
    .Data2 = 0x4567,
    .Data3 = 0x4DCA,
    .Data4 = .{ 0xB3, 0x19, 0xD0, 0xF2, 0x07, 0xEB, 0x68, 0x07 },
};

const IID_ICompositorInterop = c.GUID{
    .Data1 = 0x25297D5C,
    .Data2 = 0x3AD4,
    .Data3 = 0x4C9C,
    .Data4 = .{ 0xB5, 0xCF, 0xE3, 0x6A, 0x38, 0x51, 0x23, 0x30 },
};

// IInspectable interface
const IInspectable = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IInspectable, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IInspectable) callconv(.c) c_ulong,
        Release: *const fn (*IInspectable) callconv(.c) c_ulong,
        // IInspectable
        GetIids: *const fn (*IInspectable, *c.ULONG, *?*c.GUID) callconv(.c) c.HRESULT,
        GetRuntimeClassName: *const fn (*IInspectable, *?HSTRING) callconv(.c) c.HRESULT,
        GetTrustLevel: *const fn (*IInspectable, *i32) callconv(.c) c.HRESULT,
    };
};

// ICompositorDesktopInterop interface
const ICompositorDesktopInterop = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*ICompositorDesktopInterop, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*ICompositorDesktopInterop) callconv(.c) c_ulong,
        Release: *const fn (*ICompositorDesktopInterop) callconv(.c) c_ulong,
        // ICompositorDesktopInterop
        CreateDesktopWindowTarget: *const fn (*ICompositorDesktopInterop, c.HWND, c.BOOL, *?*anyopaque) callconv(.c) c.HRESULT,
    };
};

// ICompositorInterop interface (for CreateCompositionSurfaceForSwapChain)
const ICompositorInterop = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*ICompositorInterop, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*ICompositorInterop) callconv(.c) c_ulong,
        Release: *const fn (*ICompositorInterop) callconv(.c) c_ulong,
        // ICompositorInterop
        CreateCompositionSurfaceForHandle: *const fn (*ICompositorInterop, c.HANDLE, *?*anyopaque) callconv(.c) c.HRESULT,
        CreateCompositionSurfaceForSwapChain: *const fn (*ICompositorInterop, *anyopaque, *?*anyopaque) callconv(.c) c.HRESULT,
        CreateGraphicsDevice: *const fn (*ICompositorInterop, *anyopaque, *?*anyopaque) callconv(.c) c.HRESULT,
    };
};

// Function pointers for dynamically loaded WinRT functions
const RoInitializeFn = *const fn (i32) callconv(.c) c.HRESULT;
const RoActivateInstanceFn = *const fn (HSTRING, *?*IInspectable) callconv(.c) c.HRESULT;
const WindowsCreateStringFn = *const fn (?[*]const u16, u32, *HSTRING) callconv(.c) c.HRESULT;
const WindowsDeleteStringFn = *const fn (HSTRING) callconv(.c) c.HRESULT;
const CreateDispatcherQueueControllerFn = *const fn (*const DispatcherQueueOptions, *?*anyopaque) callconv(.c) c.HRESULT;

var g_RoInitialize: ?RoInitializeFn = null;
var g_RoActivateInstance: ?RoActivateInstanceFn = null;
var g_WindowsCreateString: ?WindowsCreateStringFn = null;
var g_WindowsDeleteString: ?WindowsDeleteStringFn = null;
var g_CreateDispatcherQueueController: ?CreateDispatcherQueueControllerFn = null;
var g_winrt_loaded: bool = false;

fn loadWinRTFunctions() bool {
    if (g_winrt_loaded) return g_RoInitialize != null;
    g_winrt_loaded = true;

    // Load combase.dll
    const combase = c.LoadLibraryW(&[_:0]c.WCHAR{ 'c', 'o', 'm', 'b', 'a', 's', 'e', '.', 'd', 'l', 'l' });
    if (combase == null) {
        applog.appLog("[winrt] Failed to load combase.dll\n", .{});
        return false;
    }

    g_RoInitialize = @ptrCast(c.GetProcAddress(combase, "RoInitialize"));
    g_RoActivateInstance = @ptrCast(c.GetProcAddress(combase, "RoActivateInstance"));
    g_WindowsCreateString = @ptrCast(c.GetProcAddress(combase, "WindowsCreateString"));
    g_WindowsDeleteString = @ptrCast(c.GetProcAddress(combase, "WindowsDeleteString"));

    if (g_RoInitialize == null or g_RoActivateInstance == null or g_WindowsCreateString == null) {
        applog.appLog("[winrt] Failed to get combase.dll functions\n", .{});
        return false;
    }
    applog.appLog("[winrt] WindowsCreateString=0x{x}\n", .{@intFromPtr(g_WindowsCreateString)});

    // Load CoreMessaging.dll
    const coremessaging = c.LoadLibraryW(&[_:0]c.WCHAR{ 'C', 'o', 'r', 'e', 'M', 'e', 's', 's', 'a', 'g', 'i', 'n', 'g', '.', 'd', 'l', 'l' });
    if (coremessaging == null) {
        applog.appLog("[winrt] Failed to load CoreMessaging.dll\n", .{});
        return false;
    }

    g_CreateDispatcherQueueController = @ptrCast(c.GetProcAddress(coremessaging, "CreateDispatcherQueueController"));
    if (g_CreateDispatcherQueueController == null) {
        applog.appLog("[winrt] Failed to get CreateDispatcherQueueController\n", .{});
        return false;
    }

    applog.appLog("[winrt] WinRT functions loaded successfully\n", .{});
    return true;
}

// Composition state
pub const CompositionState = struct {
    initialized: bool = false,
    compositor: ?*IInspectable = null,
    desktop_interop: ?*ICompositorDesktopInterop = null,
    compositor_interop: ?*ICompositorInterop = null,
    dispatcher_queue_controller: ?*anyopaque = null,
    desktop_target: ?*anyopaque = null,
};

var g_state: CompositionState = .{};

fn createHStringFromPtr(ptr: [*]const u16, len: u32) HSTRING {
    var hstring: HSTRING = null;

    const func = g_WindowsCreateString orelse return null;

    applog.appLog("[winrt] createHString: ptr=0x{x} len={d}\n", .{ @intFromPtr(ptr), len });

    const hr = func(ptr, len, &hstring);

    if (c.FAILED(hr)) {
        applog.appLog("[winrt] WindowsCreateString failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return null;
    }

    applog.appLog("[winrt] WindowsCreateString ok, hstring=0x{x}\n", .{@intFromPtr(hstring)});
    return hstring;
}

/// Initialize WinRT Composition for backdrop blur
pub fn init(hwnd: c.HWND) bool {
    applog.appLog("[winrt] Initializing WinRT Composition\n", .{});

    // Load WinRT functions dynamically
    if (!loadWinRTFunctions()) {
        applog.appLog("[winrt] Failed to load WinRT functions\n", .{});
        return false;
    }

    // Initialize WinRT
    var hr = g_RoInitialize.?(RO_INIT_SINGLETHREADED);
    if (c.FAILED(hr) and hr != @as(c.HRESULT, @bitCast(@as(u32, 0x80010106)))) { // RPC_E_CHANGED_MODE is OK
        applog.appLog("[winrt] RoInitialize failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return false;
    }
    applog.appLog("[winrt] RoInitialize ok\n", .{});

    // Create DispatcherQueue (required for Compositor)
    const options = DispatcherQueueOptions{
        .dwSize = @sizeOf(DispatcherQueueOptions),
        .threadType = DQTYPE_THREAD_CURRENT,
        .apartmentType = DQTAT_COM_STA,
    };

    hr = g_CreateDispatcherQueueController.?(&options, &g_state.dispatcher_queue_controller);
    if (c.FAILED(hr)) {
        applog.appLog("[winrt] CreateDispatcherQueueController failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return false;
    }
    applog.appLog("[winrt] CreateDispatcherQueueController ok\n", .{});

    // Create Compositor via RoActivateInstance
    // Class name: "Windows.UI.Composition.Compositor" (34 chars)
    const class_name = [_]u16{ 'W', 'i', 'n', 'd', 'o', 'w', 's', '.', 'U', 'I', '.', 'C', 'o', 'm', 'p', 'o', 's', 'i', 't', 'i', 'o', 'n', '.', 'C', 'o', 'm', 'p', 'o', 's', 'i', 't', 'o', 'r' };
    const hstr = createHStringFromPtr(&class_name, 34);

    if (hstr == null) {
        applog.appLog("[winrt] Failed to create HSTRING for Compositor class\n", .{});
        return false;
    }
    defer {
        if (g_WindowsDeleteString) |deleteStr| {
            _ = deleteStr(hstr);
        }
    }

    hr = g_RoActivateInstance.?(hstr, &g_state.compositor);
    if (c.FAILED(hr) or g_state.compositor == null) {
        applog.appLog("[winrt] RoActivateInstance(Compositor) failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return false;
    }
    applog.appLog("[winrt] RoActivateInstance(Compositor) ok: 0x{x}\n", .{@intFromPtr(g_state.compositor)});

    // Query for ICompositorDesktopInterop
    hr = g_state.compositor.?.lpVtbl.QueryInterface(
        g_state.compositor.?,
        &IID_ICompositorDesktopInterop,
        @ptrCast(&g_state.desktop_interop),
    );
    if (c.FAILED(hr) or g_state.desktop_interop == null) {
        applog.appLog("[winrt] QueryInterface(ICompositorDesktopInterop) failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return false;
    }
    applog.appLog("[winrt] QueryInterface(ICompositorDesktopInterop) ok\n", .{});

    // Query for ICompositorInterop (for swapchain surface)
    hr = g_state.compositor.?.lpVtbl.QueryInterface(
        g_state.compositor.?,
        &IID_ICompositorInterop,
        @ptrCast(&g_state.compositor_interop),
    );
    if (c.FAILED(hr) or g_state.compositor_interop == null) {
        applog.appLog("[winrt] QueryInterface(ICompositorInterop) failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        // Not fatal, continue
    } else {
        applog.appLog("[winrt] QueryInterface(ICompositorInterop) ok\n", .{});
    }

    // Create DesktopWindowTarget
    hr = g_state.desktop_interop.?.lpVtbl.CreateDesktopWindowTarget(
        g_state.desktop_interop.?,
        hwnd,
        c.TRUE, // isTopmost
        &g_state.desktop_target,
    );
    if (c.FAILED(hr) or g_state.desktop_target == null) {
        applog.appLog("[winrt] CreateDesktopWindowTarget failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return false;
    }
    applog.appLog("[winrt] CreateDesktopWindowTarget ok: 0x{x}\n", .{@intFromPtr(g_state.desktop_target)});

    g_state.initialized = true;
    applog.appLog("[winrt] WinRT Composition initialized successfully\n", .{});

    // TODO: Create backdrop brush and sprite visual
    // This requires more WinRT interface definitions (ICompositor2, ISpriteVisual, etc.)

    return true;
}

/// Cleanup WinRT Composition resources
pub fn deinit() void {
    if (g_state.desktop_target) |target| {
        const unk: *IInspectable = @ptrCast(@alignCast(target));
        _ = unk.lpVtbl.Release(unk);
        g_state.desktop_target = null;
    }

    if (g_state.compositor_interop) |interop| {
        _ = interop.lpVtbl.Release(interop);
        g_state.compositor_interop = null;
    }

    if (g_state.desktop_interop) |interop| {
        _ = interop.lpVtbl.Release(interop);
        g_state.desktop_interop = null;
    }

    if (g_state.compositor) |compositor| {
        _ = compositor.lpVtbl.Release(compositor);
        g_state.compositor = null;
    }

    if (g_state.dispatcher_queue_controller) |controller| {
        const unk: *IInspectable = @ptrCast(@alignCast(controller));
        _ = unk.lpVtbl.Release(unk);
        g_state.dispatcher_queue_controller = null;
    }

    g_state.initialized = false;
    applog.appLog("[winrt] WinRT Composition cleaned up\n", .{});
}

/// Check if WinRT Composition is available and initialized
pub fn isInitialized() bool {
    return g_state.initialized;
}
