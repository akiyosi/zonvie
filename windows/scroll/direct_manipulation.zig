//! Direct Manipulation COM plumbing and the DmSnapshot mailbox.
//!
//! Contract: .agents/docs/windows-smooth-scroll-design.md (Contract A) and
//! .agents/docs/adr/002-input-routing-by-processinput-handled.md.
//!
//! This module owns the Direct Manipulation manager/viewport/content wiring
//! and the delegate-thread -> UI-thread snapshot mailbox. Thread ownership is
//! fixed by the design: the DM delegate callback may only read
//! GetOutputTransform from the primary content, overwrite the mailbox, and
//! post one coalesced WM_APP_DM_UPDATE to the main HWND. It must never call
//! into Neovim/core, touch a TBS, commit DirectComposition, or take app.mu.
//!
//! Session wiring owns eligibility and routes wheel messages through
//! ProcessInput; touch contacts use the additional SetContact path.

const std = @import("std");
const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");
const scroll_types = @import("types.zig");

pub const DmStatus = scroll_types.DmStatus;
pub const DmSnapshot = scroll_types.DmSnapshot;

/// One session's maximum travel from the recentered origin before the
/// content rect edge is reached. SyncContentTransform is banned during a
/// session, so the rect must absorb the whole session; reaching the edge is
/// handled as a fault (Effect.reset(.content_rect_edge)) by the coordinator.
/// Initial value per the design; tune on real hardware.
pub const max_session_travel_px: i32 = 1_000_000;

// =========================================================================
// COM declarations (manual vtables, following the established idiom in
// windows/renderer/d3d11_renderer.zig and winrt_composition.zig: typed
// entries for methods we call, opaque placeholders for the rest, GUID
// literals declared locally). directmanipulation is header-only COM: the
// manager is created with CoCreateInstance (ole32, already linked), so no
// new system library is needed. Vtable order matches the Windows SDK
// directmanipulation.h.
// =========================================================================

const S_OK: c.HRESULT = 0;
const E_NOINTERFACE: c.HRESULT = @bitCast(@as(u32, 0x80004002));
const CLSCTX_INPROC_SERVER: c.DWORD = 0x1;

pub const CLSID_DirectManipulationManager = c.GUID{
    .Data1 = 0x54E211B6,
    .Data2 = 0x3650,
    .Data3 = 0x4F75,
    .Data4 = .{ 0x83, 0x34, 0xFA, 0x35, 0x95, 0x98, 0xE1, 0xC5 },
};

/// Runtime class implementing IDirectManipulationCompositor (used by the
/// epoch-visual wiring in a later step, together with AddContent).
pub const CLSID_DCompManipulationCompositor = c.GUID{
    .Data1 = 0x79DEA627,
    .Data2 = 0xA08A,
    .Data3 = 0x43AC,
    .Data4 = .{ 0x8E, 0xF5, 0x69, 0x00, 0xB9, 0x29, 0x91, 0x26 },
};

pub const IID_IUnknown = c.GUID{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub const IID_IDirectManipulationManager = c.GUID{
    .Data1 = 0xFBF5D3B4,
    .Data2 = 0x70C7,
    .Data3 = 0x4163,
    .Data4 = .{ 0x93, 0x22, 0x5A, 0x6F, 0x66, 0x0D, 0x6F, 0xBC },
};

pub const IID_IDirectManipulationViewport = c.GUID{
    .Data1 = 0x28B85A3D,
    .Data2 = 0x60A0,
    .Data3 = 0x48BD,
    .Data4 = .{ 0x9B, 0xA1, 0x5C, 0xE8, 0xD9, 0xEA, 0x3A, 0x6D },
};

pub const IID_IDirectManipulationContent = c.GUID{
    .Data1 = 0xB89962CB,
    .Data2 = 0x3D89,
    .Data3 = 0x442B,
    .Data4 = .{ 0xBB, 0x58, 0x50, 0x98, 0xFA, 0x0F, 0x9F, 0x16 },
};

pub const IID_IDirectManipulationViewportEventHandler = c.GUID{
    .Data1 = 0x952121DA,
    .Data2 = 0xD69F,
    .Data3 = 0x45F9,
    .Data4 = .{ 0xB0, 0xF9, 0xF2, 0x39, 0x44, 0x32, 0x1A, 0x6D },
};

pub const IID_IDirectManipulationCompositor = c.GUID{
    .Data1 = 0x537A0825,
    .Data2 = 0x0387,
    .Data3 = 0x4EFA,
    .Data4 = .{ 0xB6, 0x2F, 0x71, 0xEB, 0x1F, 0x08, 0x5A, 0x7E },
};

// DIRECTMANIPULATION_CONFIGURATION flags (only the ones Contract A uses:
// vertical pan with inertia, no scaling, no X translation).
pub const DIRECTMANIPULATION_CONFIGURATION_INTERACTION: u32 = 0x1;
pub const DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_Y: u32 = 0x4;
pub const DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_INERTIA: u32 = 0x20;

// DIRECTMANIPULATION_STATUS raw values are pinned by scroll_types.DmStatus
// (building=0 .. suspended=6, same as the SDK enum).
fn dmStatusFromRaw(raw: u32) DmStatus {
    if (raw > @intFromEnum(DmStatus.suspended)) return DmStatus.disabled;
    return @enumFromInt(raw);
}

pub const IDirectManipulationManager = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDirectManipulationManager, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDirectManipulationManager) callconv(.c) c_ulong,
        Release: *const fn (*IDirectManipulationManager) callconv(.c) c_ulong,
        // IDirectManipulationManager (in vtable order)
        Activate: *const fn (*IDirectManipulationManager, c.HWND) callconv(.c) c.HRESULT,
        Deactivate: *const fn (*IDirectManipulationManager, c.HWND) callconv(.c) c.HRESULT,
        RegisterHitTestTarget: *const anyopaque,
        ProcessInput: *const fn (*IDirectManipulationManager, *const c.MSG, *c.BOOL) callconv(.c) c.HRESULT,
        GetUpdateManager: *const anyopaque,
        CreateViewport: *const fn (*IDirectManipulationManager, ?*anyopaque, c.HWND, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        CreateContent: *const anyopaque,
    };
};

pub const IDirectManipulationViewport = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDirectManipulationViewport, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDirectManipulationViewport) callconv(.c) c_ulong,
        Release: *const fn (*IDirectManipulationViewport) callconv(.c) c_ulong,
        // IDirectManipulationViewport (in vtable order)
        Enable: *const fn (*IDirectManipulationViewport) callconv(.c) c.HRESULT,
        Disable: *const fn (*IDirectManipulationViewport) callconv(.c) c.HRESULT,
        SetContact: *const fn (*IDirectManipulationViewport, u32) callconv(.c) c.HRESULT,
        ReleaseContact: *const anyopaque,
        ReleaseAllContacts: *const fn (*IDirectManipulationViewport) callconv(.c) c.HRESULT,
        GetStatus: *const fn (*IDirectManipulationViewport, *u32) callconv(.c) c.HRESULT,
        GetTag: *const anyopaque,
        SetTag: *const anyopaque,
        GetViewportRect: *const anyopaque,
        SetViewportRect: *const fn (*IDirectManipulationViewport, *const c.RECT) callconv(.c) c.HRESULT,
        ZoomToRect: *const anyopaque,
        SetViewportTransform: *const anyopaque,
        SyncDisplayTransform: *const anyopaque,
        GetPrimaryContent: *const fn (*IDirectManipulationViewport, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddContent: *const anyopaque,
        RemoveContent: *const anyopaque,
        SetViewportOptions: *const anyopaque,
        AddConfiguration: *const anyopaque,
        RemoveConfiguration: *const anyopaque,
        ActivateConfiguration: *const fn (*IDirectManipulationViewport, u32) callconv(.c) c.HRESULT,
        SetManualGesture: *const anyopaque,
        SetChaining: *const anyopaque,
        AddEventHandler: *const fn (*IDirectManipulationViewport, c.HWND, *IDirectManipulationViewportEventHandler, *c.DWORD) callconv(.c) c.HRESULT,
        RemoveEventHandler: *const fn (*IDirectManipulationViewport, c.DWORD) callconv(.c) c.HRESULT,
        SetInputMode: *const anyopaque,
        SetUpdateMode: *const anyopaque,
        Stop: *const fn (*IDirectManipulationViewport) callconv(.c) c.HRESULT,
        Abandon: *const fn (*IDirectManipulationViewport) callconv(.c) c.HRESULT,
    };
};

pub const IDirectManipulationContent = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDirectManipulationContent, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDirectManipulationContent) callconv(.c) c_ulong,
        Release: *const fn (*IDirectManipulationContent) callconv(.c) c_ulong,
        // IDirectManipulationContent (in vtable order)
        GetContentRect: *const anyopaque,
        SetContentRect: *const fn (*IDirectManipulationContent, *const c.RECT) callconv(.c) c.HRESULT,
        GetViewport: *const anyopaque,
        GetTag: *const anyopaque,
        SetTag: *const anyopaque,
        GetOutputTransform: *const fn (*IDirectManipulationContent, [*]f32, c.DWORD) callconv(.c) c.HRESULT,
        GetContentTransform: *const anyopaque,
        // Banned during active sessions (fails while RUNNING/INERTIA/
        // SUSPENDED); the content rect recentering below replaces it.
        SyncContentTransform: *const anyopaque,
    };
};

pub const IDirectManipulationCompositor = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDirectManipulationCompositor, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDirectManipulationCompositor) callconv(.c) c_ulong,
        Release: *const fn (*IDirectManipulationCompositor) callconv(.c) c_ulong,
        // IDirectManipulationCompositor (in vtable order)
        AddContent: *const fn (*IDirectManipulationCompositor, *IDirectManipulationContent, ?*c.IUnknown, ?*c.IUnknown, ?*c.IUnknown) callconv(.c) c.HRESULT,
        RemoveContent: *const fn (*IDirectManipulationCompositor, *IDirectManipulationContent) callconv(.c) c.HRESULT,
        SetUpdateManager: *const anyopaque,
        Flush: *const fn (*IDirectManipulationCompositor) callconv(.c) c.HRESULT,
    };
};

pub const IDirectManipulationViewportEventHandler = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDirectManipulationViewportEventHandler, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDirectManipulationViewportEventHandler) callconv(.c) c_ulong,
        Release: *const fn (*IDirectManipulationViewportEventHandler) callconv(.c) c_ulong,
        // IDirectManipulationViewportEventHandler (in vtable order).
        // DIRECTMANIPULATION_STATUS parameters are passed as u32.
        OnViewportStatusChanged: *const fn (*IDirectManipulationViewportEventHandler, *IDirectManipulationViewport, u32, u32) callconv(.c) c.HRESULT,
        OnViewportUpdated: *const fn (*IDirectManipulationViewportEventHandler, *IDirectManipulationViewport) callconv(.c) c.HRESULT,
        OnContentUpdated: *const fn (*IDirectManipulationViewportEventHandler, *IDirectManipulationViewport, *IDirectManipulationContent) callconv(.c) c.HRESULT,
    };
};

fn guidEql(a: *const c.GUID, b: *const c.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// =========================================================================
// Snapshot mailbox (seqlock)
// =========================================================================

/// Single-writer seqlock. The DM delegate thread overwrites the latest
/// snapshot; the UI thread reads it. No lock is shared with render or input
/// paths, and neither side blocks the other: the writer never waits, and the
/// reader retries only while a write is in flight (a handful of stores).
///
/// Single-writer protocol: exactly one execution may ever be inside write()
/// at a time. The writer is the UI-thread delegate-delivery context,
/// including synchronous re-entry from IDirectManipulationManager::ProcessInput.
/// Reentrant nesting is expected: DmController's `in_publish` guard prevents
/// nested publishFromDelegate calls from interleaving seqlock writes.
/// createViewport seeds the mailbox before any handler is registered, which
/// cannot race. read()/readSnapshot() must never be called from a delegate
/// callback: a write interrupted by its own reader would spin forever on an
/// odd seq.
pub const DmMailbox = struct {
    /// Odd while a write is in progress, even when the snapshot is stable.
    seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    status_raw: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(DmStatus.building)),
    output_y_bits: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    qpc: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    /// Writer side (see the single-writer protocol above). No allocation,
    /// no locks.
    pub fn write(self: *DmMailbox, snapshot: DmSnapshot) void {
        // acq_rel: the acquire half keeps the field stores below the odd
        // transition; the closing release keeps them above the even one.
        _ = self.seq.fetchAdd(1, .acq_rel);
        self.generation.store(snapshot.generation, .monotonic);
        self.status_raw.store(@intFromEnum(snapshot.status), .monotonic);
        self.output_y_bits.store(@bitCast(snapshot.output_y), .monotonic);
        self.qpc.store(snapshot.qpc, .monotonic);
        _ = self.seq.fetchAdd(1, .release);
    }

    /// UI thread only.
    pub fn read(self: *DmMailbox) DmSnapshot {
        while (true) {
            const seq_before = self.seq.load(.acquire);
            if (seq_before & 1 == 0) {
                // Acquire loads keep the trailing seq check ordered after
                // the field loads.
                const generation = self.generation.load(.acquire);
                const status_raw = self.status_raw.load(.acquire);
                const output_y_bits = self.output_y_bits.load(.acquire);
                const qpc = self.qpc.load(.acquire);
                if (self.seq.load(.acquire) == seq_before) {
                    return .{
                        .generation = generation,
                        .status = dmStatusFromRaw(status_raw),
                        .output_y = @bitCast(output_y_bits),
                        .qpc = qpc,
                    };
                }
            }
            std.atomic.spinLoopHint();
        }
    }
};

// =========================================================================
// Viewport event handler (COM object embedded in DmController; never
// heap-allocated, so the delegate path stays allocation-free)
// =========================================================================

const ViewportEventHandler = extern struct {
    /// Must stay the first field: DM sees &iface as the COM object.
    iface: IDirectManipulationViewportEventHandler,
    controller: *DmController,
    ref_count: u32,
};

fn handlerFromIface(iface: *IDirectManipulationViewportEventHandler) *ViewportEventHandler {
    return @fieldParentPtr("iface", iface);
}

fn evtQueryInterface(iface: *IDirectManipulationViewportEventHandler, riid: *const c.GUID, out: *?*anyopaque) callconv(.c) c.HRESULT {
    if (guidEql(riid, &IID_IUnknown) or guidEql(riid, &IID_IDirectManipulationViewportEventHandler)) {
        _ = evtAddRef(iface);
        out.* = iface;
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}

fn evtAddRef(iface: *IDirectManipulationViewportEventHandler) callconv(.c) c_ulong {
    const self = handlerFromIface(iface);
    return @atomicRmw(u32, &self.ref_count, .Add, 1, .monotonic) + 1;
}

fn evtRelease(iface: *IDirectManipulationViewportEventHandler) callconv(.c) c_ulong {
    // The handler is embedded in DmController and is never freed here; the
    // count only follows the COM protocol. DmController.destroyViewport
    // removes the handler before the controller can go away.
    const self = handlerFromIface(iface);
    return @atomicRmw(u32, &self.ref_count, .Sub, 1, .monotonic) - 1;
}

fn evtOnViewportStatusChanged(iface: *IDirectManipulationViewportEventHandler, viewport: *IDirectManipulationViewport, current: u32, previous: u32) callconv(.c) c.HRESULT {
    _ = viewport;
    _ = previous;
    const self = handlerFromIface(iface);
    // Poison check BEFORE any controller state is touched (including
    // last_status): DM coalesces callbacks onto the HWND's message queue,
    // so a queued callback can still run after RemoveEventHandler returned.
    if (!self.controller.delegateAlive()) return S_OK;
    const status = dmStatusFromRaw(current);
    // Delegate-thread-only field; the UI thread sees it via the mailbox.
    self.controller.last_status = status;
    self.controller.publishFromDelegate(status);
    return S_OK;
}

fn evtOnViewportUpdated(iface: *IDirectManipulationViewportEventHandler, viewport: *IDirectManipulationViewport) callconv(.c) c.HRESULT {
    _ = viewport;
    const self = handlerFromIface(iface);
    if (!self.controller.delegateAlive()) return S_OK;
    self.controller.publishFromDelegate(self.controller.last_status);
    return S_OK;
}

fn evtOnContentUpdated(iface: *IDirectManipulationViewportEventHandler, viewport: *IDirectManipulationViewport, content: *IDirectManipulationContent) callconv(.c) c.HRESULT {
    _ = viewport;
    // The transform is always read from the stored primary content (the only
    // content Contract A attaches), per the design's transform-source rule.
    _ = content;
    const self = handlerFromIface(iface);
    if (!self.controller.delegateAlive()) return S_OK;
    self.controller.publishFromDelegate(self.controller.last_status);
    return S_OK;
}

const viewport_event_handler_vtbl = IDirectManipulationViewportEventHandler.Vtbl{
    .QueryInterface = evtQueryInterface,
    .AddRef = evtAddRef,
    .Release = evtRelease,
    .OnViewportStatusChanged = evtOnViewportStatusChanged,
    .OnViewportUpdated = evtOnViewportUpdated,
    .OnContentUpdated = evtOnContentUpdated,
};

// =========================================================================
// Controller
// =========================================================================

/// Owns the Direct Manipulation lifecycle for the single target external
/// window of Contract A.
///
/// Threading and re-entrancy invariants:
/// - Lifecycle methods (createManager, createViewport, recenterContentRect,
///   activate, deactivate, destroyViewport, deinit, onPointerHitTest) are
///   UI-thread-only AND non-reentrant. DM COM calls can spin a nested
///   message pump while blocking on DM's internal thread, and a WM_DESTROY
///   or WM_APP handler dispatched from that pump may re-enter them mid-call
///   (Chromium ships DestroyDuringUpdateEventHandler-style regression tests
///   for exactly this). `lifecycle_busy` makes a re-entered call bail with
///   a log — never assert/crash — which is safe because the outer call
///   completes the state change.
/// - publishFromDelegate and last_status belong to the DM delegate callback
///   context; every delegate entry point bails once `content` is poisoned
///   to null.
/// - processInput is UI-thread-only and is a per-message hot path, not a
///   lifecycle method. DM may synchronously re-enter the viewport event
///   handler on this thread during the call; `in_publish` is the required
///   protection for that re-entry.
/// - The instance must be pinned (stable address) from createViewport() on:
///   the registered event handler holds a pointer back into it. The memory
///   must stay valid (not freed or reused) until the embedded handler's
///   ref_count has returned to its baseline of 1; deinit asserts this.
/// - The window passed to AddEventHandler must NEVER be null: with a null
///   window DM dispatches callbacks on a DM worker thread and the
///   single-writer mailbox protocol dies. Callbacks are pinned to the
///   thread that owns the HWND passed to AddEventHandler.
pub const DmController = struct {
    /// Main-window HWND that receives the coalesced WM_APP_DM_UPDATE wakeup.
    main_hwnd: c.HWND,
    /// app_mod.WM_APP_DM_UPDATE, passed in so this module does not import
    /// app.zig (app.zig imports this file; see the app.zig header comment).
    dm_update_msg: c.UINT,
    /// App-owned coalescing flag (app.dm_update_posted): set here before
    /// posting, cleared by the UI-thread WM_APP_DM_UPDATE handler before it
    /// reads the mailbox.
    update_posted: *std.atomic.Value(bool),

    manager: ?*IDirectManipulationManager = null,
    viewport: ?*IDirectManipulationViewport = null,
    /// Primary content of `viewport`, queried as IDirectManipulationContent.
    /// Written by the UI thread with atomic stores and read by delegate
    /// entry points with atomic loads: clearing it to null is the poison
    /// that makes late (queued) delegate callbacks bail before touching the
    /// released content or the controller. The COM reference itself is
    /// released only after RemoveEventHandler has returned.
    content: ?*IDirectManipulationContent = null,
    handler: ViewportEventHandler = undefined,
    /// True once `handler` has been initialized by createViewport, so deinit
    /// can assert on the refcount without reading undefined memory.
    handler_initialized: bool = false,
    handler_cookie: ?c.DWORD = null,
    /// External HWND passed to IDirectManipulationManager::Activate.
    activated_hwnd: ?c.HWND = null,

    /// Carried in every mailbox snapshot; the UI thread drops snapshots
    /// whose generation does not match the active session. Advanced on
    /// viewport destruction / device loss.
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Last status seen by OnViewportStatusChanged. Delegate context only
    /// (reset by createViewport before any handler is registered); the UI
    /// thread observes status through the mailbox.
    last_status: DmStatus = .building,

    /// UI-thread-only re-entrancy guard for lifecycle methods; see the
    /// struct doc comment. Not atomic on purpose: only the UI thread
    /// touches it, re-entry happens via a nested pump on the same thread.
    lifecycle_busy: bool = false,

    /// Delegate-context-only re-entrancy guard for publishFromDelegate.
    /// Plain bool on purpose: nested publishes come from a nested pump on
    /// the same thread, never from a second thread.
    in_publish: bool = false,

    mailbox: DmMailbox = .{},

    pub fn init(main_hwnd: c.HWND, dm_update_msg: c.UINT, update_posted: *std.atomic.Value(bool)) DmController {
        return .{
            .main_hwnd = main_hwnd,
            .dm_update_msg = dm_update_msg,
            .update_posted = update_posted,
        };
    }

    /// CoCreateInstance(CLSID_DirectManipulationManager). UI thread.
    pub fn createManager(self: *DmController) !void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] createManager re-entered from a nested pump; bailing\n", .{});
            return error.DmReentered;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;

        if (self.manager != null) return;
        var obj: ?*anyopaque = null;
        const hr = c.CoCreateInstance(
            &CLSID_DirectManipulationManager,
            null,
            CLSCTX_INPROC_SERVER,
            &IID_IDirectManipulationManager,
            &obj,
        );
        if (c.FAILED(hr) or obj == null) {
            if (applog.isEnabled()) applog.appLog("[dm] CoCreateInstance(DirectManipulationManager) failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmManagerCreateFailed;
        }
        self.manager = @ptrCast(@alignCast(obj));
    }

    /// Create the viewport for one external HWND: configuration (vertical
    /// pan + inertia), viewport rect, recentered content rect, primary
    /// content, event handler registration, Enable. UI thread; `self` must
    /// be pinned from here on.
    pub fn createViewport(self: *DmController, hwnd: c.HWND, viewport_w_px: i32, viewport_h_px: i32) !void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] createViewport re-entered from a nested pump; bailing\n", .{});
            return error.DmReentered;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;

        const mgr = self.manager orelse return error.DmManagerMissing;
        if (self.viewport != null) return error.DmViewportExists;

        // New viewport = new session identity. Advance the generation so an
        // in-flight delegate write that loaded the previous generation can
        // never publish into the new session, reset the delegate-context
        // status cache, and seed the mailbox with a fresh building-status
        // snapshot: a destroy/create reuse must not surface the previous
        // session's status (e.g. .inertia) under a stale generation. No
        // handler is registered yet, so this pre-registration mailbox write
        // cannot race the delegate writer.
        self.bumpGeneration();
        self.last_status = .building;
        var seed_qpc: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceCounter(&seed_qpc);
        self.mailbox.write(.{
            .generation = self.generation.load(.monotonic),
            .status = .building,
            .output_y = 0,
            .qpc = seed_qpc.QuadPart,
        });

        var vp_obj: ?*anyopaque = null;
        var hr = mgr.lpVtbl.CreateViewport(mgr, null, hwnd, &IID_IDirectManipulationViewport, &vp_obj);
        if (c.FAILED(hr) or vp_obj == null) {
            if (applog.isEnabled()) applog.appLog("[dm] CreateViewport failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmViewportCreateFailed;
        }
        const vp: *IDirectManipulationViewport = @ptrCast(@alignCast(vp_obj));
        errdefer {
            _ = vp.lpVtbl.Abandon(vp);
            _ = vp.lpVtbl.Release(vp);
        }

        // Contract A: vertical translation with inertia only.
        const configuration: u32 = DIRECTMANIPULATION_CONFIGURATION_INTERACTION |
            DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_Y |
            DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_INERTIA;
        hr = vp.lpVtbl.ActivateConfiguration(vp, configuration);
        if (c.FAILED(hr)) {
            if (applog.isEnabled()) applog.appLog("[dm] ActivateConfiguration failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmConfigurationFailed;
        }

        const viewport_rect = c.RECT{ .left = 0, .top = 0, .right = viewport_w_px, .bottom = viewport_h_px };
        hr = vp.lpVtbl.SetViewportRect(vp, &viewport_rect);
        if (c.FAILED(hr)) {
            if (applog.isEnabled()) applog.appLog("[dm] SetViewportRect failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmSetViewportRectFailed;
        }

        var content_obj: ?*anyopaque = null;
        hr = vp.lpVtbl.GetPrimaryContent(vp, &IID_IDirectManipulationContent, &content_obj);
        if (c.FAILED(hr) or content_obj == null) {
            if (applog.isEnabled()) applog.appLog("[dm] GetPrimaryContent failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmPrimaryContentFailed;
        }
        const content: *IDirectManipulationContent = @ptrCast(@alignCast(content_obj));
        errdefer _ = content.lpVtbl.Release(content);

        try setContentRectCentered(content, viewport_w_px, viewport_h_px);

        self.handler = .{
            .iface = .{ .lpVtbl = &viewport_event_handler_vtbl },
            .controller = self,
            .ref_count = 1,
        };
        self.handler_initialized = true;

        // Publish the content pointer BEFORE AddEventHandler: the first
        // enabled/ready callbacks can arrive as soon as the handler is
        // registered, and they bail while `content` is null (poison check),
        // which would silently drop the session's first snapshot.
        @atomicStore(?*IDirectManipulationContent, &self.content, content, .release);
        errdefer @atomicStore(?*IDirectManipulationContent, &self.content, null, .release);

        var cookie: c.DWORD = 0;
        hr = vp.lpVtbl.AddEventHandler(vp, hwnd, &self.handler.iface, &cookie);
        if (c.FAILED(hr)) {
            if (applog.isEnabled()) applog.appLog("[dm] AddEventHandler failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmAddEventHandlerFailed;
        }
        errdefer _ = vp.lpVtbl.RemoveEventHandler(vp, cookie);

        hr = vp.lpVtbl.Enable(vp);
        if (c.FAILED(hr)) {
            if (applog.isEnabled()) applog.appLog("[dm] viewport Enable failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmEnableFailed;
        }

        self.viewport = vp;
        self.handler_cookie = cookie;
    }

    /// Re-center the content rect before a session starts (viewport READY).
    /// SyncContentTransform cannot rebase during a session, so the rect must
    /// leave +-max_session_travel_px of travel from the recentered origin.
    pub fn recenterContentRect(self: *DmController, viewport_w_px: i32, viewport_h_px: i32) !void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] recenterContentRect re-entered from a nested pump; bailing\n", .{});
            return error.DmReentered;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;

        const content = self.content orelse return error.DmContentMissing;
        try setContentRectCentered(content, viewport_w_px, viewport_h_px);
    }

    /// Activate DM message processing for the target external HWND.
    pub fn activate(self: *DmController, hwnd: c.HWND) !void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] activate re-entered from a nested pump; bailing\n", .{});
            return error.DmReentered;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;

        const mgr = self.manager orelse return error.DmManagerMissing;
        const hr = mgr.lpVtbl.Activate(mgr, hwnd);
        if (c.FAILED(hr)) {
            if (applog.isEnabled()) applog.appLog("[dm] Activate failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.DmActivateFailed;
        }
        self.activated_hwnd = hwnd;
    }

    /// Offer one input message to Direct Manipulation on the UI thread.
    /// ProcessInput is deliberately not covered by `lifecycle_busy`: it is a
    /// per-message hot path, and DM may synchronously re-enter the viewport
    /// event handler on this thread while processing the message. The
    /// `in_publish` guard protects the mailbox from that re-entry.
    ///
    /// A missing or tearing-down viewport is not an error: returning false
    /// lets the caller deliver the message through the legacy path exactly
    /// once. The caller owns the MSG storage and must keep it live for this
    /// call only; no allocation occurs here.
    pub fn processInput(self: *DmController, msg: *const c.MSG) bool {
        const mgr = self.manager orelse return false;
        if (self.viewport == null or self.activated_hwnd == null or
            @atomicLoad(?*IDirectManipulationContent, &self.content, .acquire) == null)
        {
            return false;
        }

        var handled: c.BOOL = 0;
        const hr = mgr.lpVtbl.ProcessInput(mgr, msg, &handled);
        if (c.FAILED(hr)) {
            if (applog.isEnabled()) applog.appLog("[dm] ProcessInput failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return false;
        }
        return handled != 0;
    }

    pub fn deactivate(self: *DmController) void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] deactivate re-entered from a nested pump; bailing\n", .{});
            return;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;
        self.deactivateInner();
    }

    /// Shared unguarded body: called by deactivate() and by teardown paths
    /// that already hold the lifecycle guard.
    fn deactivateInner(self: *DmController) void {
        const mgr = self.manager orelse return;
        if (self.activated_hwnd) |hwnd| {
            _ = mgr.lpVtbl.Deactivate(mgr, hwnd);
            self.activated_hwnd = null;
        }
    }

    /// Window destruction / device loss: advance the generation (so stale
    /// delegate snapshots are dropped), poison the delegate path, deactivate,
    /// unregister the handler, and release the viewport and content.
    pub fn destroyViewport(self: *DmController) void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] destroyViewport re-entered from a nested pump; bailing\n", .{});
            return;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;
        self.destroyViewportInner();
    }

    /// Shared unguarded body: called by destroyViewport() and deinit().
    fn destroyViewportInner(self: *DmController) void {
        self.bumpGeneration();

        // Poison the delegate path FIRST: DM coalesces callbacks onto the
        // HWND's message queue, so a queued callback can still be dispatched
        // after RemoveEventHandler returns. Clearing `content` atomically
        // makes every delegate entry point bail before touching the released
        // content or the controller state. Only the COM release below (after
        // RemoveEventHandler, which synchronizes the truly concurrent
        // cross-thread case) actually drops the reference.
        const content = @atomicLoad(?*IDirectManipulationContent, &self.content, .monotonic);
        @atomicStore(?*IDirectManipulationContent, &self.content, null, .release);

        self.deactivateInner();
        if (self.viewport) |vp| {
            if (self.handler_cookie) |cookie| {
                _ = vp.lpVtbl.RemoveEventHandler(vp, cookie);
                self.handler_cookie = null;
            }
            _ = vp.lpVtbl.Stop(vp);
            _ = vp.lpVtbl.Abandon(vp);
            _ = vp.lpVtbl.Release(vp);
            self.viewport = null;
        }
        if (content) |ct| _ = ct.lpVtbl.Release(ct);
    }

    pub fn deinit(self: *DmController) void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] deinit re-entered from a nested pump; bailing\n", .{});
            return;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;

        self.destroyViewportInner();
        if (self.manager) |mgr| {
            _ = mgr.lpVtbl.Release(mgr);
            self.manager = null;
        }
        // The embedded handler stays COM-visible for as long as DM holds
        // references above the baseline of 1 (our own embedded reference).
        // The controller's memory must not be freed or reused before the
        // count returns to baseline.
        if (self.handler_initialized) {
            std.debug.assert(@atomicLoad(u32, &self.handler.ref_count, .monotonic) <= 1);
        }
    }

    pub fn bumpGeneration(self: *DmController) void {
        _ = self.generation.fetchAdd(1, .monotonic);
    }

    /// DM_POINTERHITTEST forwarding entry point: claim a touch contact for
    /// the viewport through Direct Manipulation's SetContact path. Wheel
    /// messages are routed through processInput by the session owner.
    pub fn onPointerHitTest(self: *DmController, pointer_id: u32) void {
        if (self.lifecycle_busy) {
            if (applog.isEnabled()) applog.appLog("[dm] onPointerHitTest re-entered from a nested pump; bailing\n", .{});
            return;
        }
        self.lifecycle_busy = true;
        defer self.lifecycle_busy = false;

        const vp = self.viewport orelse return;
        const hr = vp.lpVtbl.SetContact(vp, pointer_id);
        if (c.FAILED(hr)) {
            if (applog.isEnabled()) applog.appLog("[dm] SetContact({d}) failed: 0x{x}\n", .{ pointer_id, @as(u32, @bitCast(hr)) });
        }
    }

    /// UI thread: latest snapshot for the coordinator drain (later step).
    pub fn readSnapshot(self: *DmController) DmSnapshot {
        return self.mailbox.read();
    }

    /// Delegate-side poison check: true while a live primary content is
    /// attached. destroyViewport clears the pointer before RemoveEventHandler
    /// so that late queued callbacks bail here.
    fn delegateAlive(self: *const DmController) bool {
        return @atomicLoad(?*IDirectManipulationContent, &self.content, .acquire) != null;
    }

    /// DM delegate context. Per the thread-ownership contract this is the
    /// complete list of allowed work: GetOutputTransform on the primary
    /// content, one mailbox overwrite, one coalesced PostMessage. No core
    /// calls, no TBS access, no DirectComposition Commit, no app.mu, and no
    /// heap allocation.
    fn publishFromDelegate(self: *DmController, status: DmStatus) void {
        // Seqlock re-entrancy guard: GetOutputTransform is a COM call and
        // may pump, so a nested OnContentUpdated could otherwise interleave
        // the seq fetchAdds (even mid-write) and let a reader accept a torn
        // snapshot. The nested publish bails before the first fetchAdd; the
        // outer one finishes and carries an equally fresh transform.
        if (self.in_publish) return;
        self.in_publish = true;
        defer self.in_publish = false;

        // Poisoned (or not yet created): bail without touching DM.
        const content = @atomicLoad(?*IDirectManipulationContent, &self.content, .acquire) orelse return;
        // 2x3 row-major matrix; [4]=x translation, [5]=y translation. The
        // output transform includes the sync transform, unlike
        // GetContentTransform — the design pins this as the only source.
        var matrix = [6]f32{ 1, 0, 0, 1, 0, 0 };
        const hr = content.lpVtbl.GetOutputTransform(content, &matrix, matrix.len);
        if (c.FAILED(hr)) return; // Keep the previous snapshot.

        var qpc: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceCounter(&qpc);

        self.mailbox.write(.{
            .generation = self.generation.load(.monotonic),
            .status = status,
            .output_y = matrix[5],
            .qpc = qpc.QuadPart,
        });

        // Coalesced wakeup, mirroring the WM_APP_SMOOTH_SCROLL_COMMIT
        // pattern in windows/callbacks.zig: the message carries no payload,
        // the mailbox is the source of truth, so a coalesced post loses
        // nothing. Reset the flag if the post fails to avoid a stall.
        if (self.update_posted.cmpxchgStrong(false, true, .release, .monotonic) == null) {
            if (c.PostMessageW(self.main_hwnd, self.dm_update_msg, 0, 0) == 0) {
                self.update_posted.store(false, .release);
            }
        }
    }
};

fn setContentRectCentered(content: *IDirectManipulationContent, viewport_w_px: i32, viewport_h_px: i32) !void {
    // Height = viewport + 2 * max_session_travel_px, centered on the
    // viewport, so one session cannot reach an edge (where DM silently
    // clamps the transform).
    const rect = c.RECT{
        .left = 0,
        .top = -max_session_travel_px,
        .right = viewport_w_px,
        .bottom = viewport_h_px + max_session_travel_px,
    };
    const hr = content.lpVtbl.SetContentRect(content, &rect);
    if (c.FAILED(hr)) {
        if (applog.isEnabled()) applog.appLog("[dm] SetContentRect failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.DmSetContentRectFailed;
    }
}

// Compile coverage keeps every controller entry point type-checked in the
// Windows build, including the UI-thread wheel forwarding path.
comptime {
    _ = &DmController.init;
    _ = &DmController.createManager;
    _ = &DmController.createViewport;
    _ = &DmController.recenterContentRect;
    _ = &DmController.activate;
    _ = &DmController.processInput;
    _ = &DmController.deactivate;
    _ = &DmController.destroyViewport;
    _ = &DmController.deinit;
    _ = &DmController.bumpGeneration;
    _ = &DmController.onPointerHitTest;
    _ = &DmController.readSnapshot;
    _ = &viewport_event_handler_vtbl;
}
