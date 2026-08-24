//! DirectComposition epoch presenter for Contract A.
//!
//! The presenter owns the app-created epoch visual only.  The Direct
//! Manipulation compositor inserts its visual below that epoch visual and
//! above the existing content visual:
//!
//!   target -> epoch_visual -> DM visual -> content_visual -> swap chain
//!
//! Runtime wiring is intentionally deferred to a later step.  The public API
//! is nevertheless type-checked by windows/app.zig while the module remains
//! runtime-inert.

const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");
const direct_manipulation = @import("direct_manipulation.zig");

/// Vtable layouts and interface identifiers are verified against the MinGW
/// headers at /snap/zig/current/lib/libc/include/any-windows-any/dcomp.h:
/// IDCompositionVisual lines 344-378, IDCompositionDevice lines 387-415.
pub const IID_IDCompositionVisual = c.GUID{
    .Data1 = 0x4D93059D,
    .Data2 = 0x097B,
    .Data3 = 0x4651,
    .Data4 = .{ 0x9A, 0x60, 0xF0, 0xF2, 0x51, 0x16, 0xE2, 0xF3 },
};

pub const IID_IDCompositionDevice = c.GUID{
    .Data1 = 0xC37EA93A,
    .Data2 = 0xE7AA,
    .Data3 = 0x450D,
    .Data4 = .{ 0xB1, 0x6F, 0x97, 0x46, 0xCB, 0x04, 0x07, 0xF3 },
};

/// DCOMPOSITION_FRAME_STATISTICS from dcomptypes.h lines 60-66.
pub const DCOMPOSITION_FRAME_STATISTICS = extern struct {
    lastFrameTime: c.LARGE_INTEGER,
    currentCompositionRate: c.DXGI_RATIONAL,
    currentTime: c.LARGE_INTEGER,
    timeFrequency: c.LARGE_INTEGER,
    nextEstimatedFrameTime: c.LARGE_INTEGER,
};

/// IDCompositionAnimation vtable from dcompanimation.h lines 82-132.
pub const IDCompositionAnimation = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDCompositionAnimation, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDCompositionAnimation) callconv(.c) c_ulong,
        Release: *const fn (*IDCompositionAnimation) callconv(.c) c_ulong,
        Reset: *const fn (*IDCompositionAnimation) callconv(.c) c.HRESULT,
        SetAbsoluteBeginTime: *const fn (*IDCompositionAnimation, c.LARGE_INTEGER) callconv(.c) c.HRESULT,
        AddCubic: *const fn (*IDCompositionAnimation, f64, f32, f32, f32, f32) callconv(.c) c.HRESULT,
        AddSinusoidal: *const fn (*IDCompositionAnimation, f64, f32, f32, f32, f32) callconv(.c) c.HRESULT,
        AddRepeat: *const fn (*IDCompositionAnimation, f64, f64) callconv(.c) c.HRESULT,
        End: *const fn (*IDCompositionAnimation, f64, f32) callconv(.c) c.HRESULT,
    };
};

/// IDCompositionVisual, with the C ABI overload order from dcomp.h lines
/// 354-378.  In particular, SetOffsetY(animation) precedes SetOffsetY(float),
/// so the scalar setter is the fourth post-IUnknown entry.
pub const IDCompositionVisual = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDCompositionVisual, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDCompositionVisual) callconv(.c) c_ulong,
        Release: *const fn (*IDCompositionVisual) callconv(.c) c_ulong,
        SetOffsetXAnimation: *const anyopaque,
        SetOffsetX: *const anyopaque,
        SetOffsetYAnimation: *const fn (*IDCompositionVisual, *IDCompositionAnimation) callconv(.c) c.HRESULT,
        SetOffsetY: *const fn (*IDCompositionVisual, f32) callconv(.c) c.HRESULT,
        SetTransformAnimation: *const anyopaque,
        SetTransform: *const anyopaque,
        SetTransformParent: *const anyopaque,
        SetEffect: *const anyopaque,
        SetBitmapInterpolationMode: *const anyopaque,
        SetBorderMode: *const anyopaque,
        SetClipAnimation: *const anyopaque,
        SetClip: *const anyopaque,
        SetContent: *const fn (*IDCompositionVisual, ?*c.IUnknown) callconv(.c) c.HRESULT,
        AddVisual: *const fn (*IDCompositionVisual, *IDCompositionVisual, c.BOOL, ?*IDCompositionVisual) callconv(.c) c.HRESULT,
        RemoveVisual: *const fn (*IDCompositionVisual, *IDCompositionVisual) callconv(.c) c.HRESULT,
        RemoveAllVisuals: *const anyopaque,
        SetCompositeMode: *const anyopaque,
    };
};

/// IDCompositionDevice through CreateAnimation. The placeholders preserve
/// the vtable slots specified by dcomp.h lines 387-415; CreateAnimation is
/// slot 25 after IUnknown, Commit, statistics, target/visual, and the
/// surface/transform factory methods.
pub const IDCompositionDevice = extern struct {
    lpVtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDCompositionDevice, *const c.GUID, *?*anyopaque) callconv(.c) c.HRESULT,
        AddRef: *const fn (*IDCompositionDevice) callconv(.c) c_ulong,
        Release: *const fn (*IDCompositionDevice) callconv(.c) c_ulong,
        Commit: *const fn (*IDCompositionDevice) callconv(.c) c.HRESULT,
        WaitForCommitCompletion: *const anyopaque,
        GetFrameStatistics: *const fn (*IDCompositionDevice, *DCOMPOSITION_FRAME_STATISTICS) callconv(.c) c.HRESULT,
        CreateTargetForHwnd: *const anyopaque,
        CreateVisual: *const fn (*IDCompositionDevice, *?*IDCompositionVisual) callconv(.c) c.HRESULT,
        CreateSurface: *const anyopaque,
        CreateVirtualSurface: *const anyopaque,
        CreateSurfaceFromHandle: *const anyopaque,
        CreateSurfaceFromHwnd: *const anyopaque,
        CreateTranslateTransform: *const anyopaque,
        CreateScaleTransform: *const anyopaque,
        CreateRotateTransform: *const anyopaque,
        CreateSkewTransform: *const anyopaque,
        CreateMatrixTransform: *const anyopaque,
        CreateTransformGroup: *const anyopaque,
        CreateTranslateTransform3D: *const anyopaque,
        CreateScaleTransform3D: *const anyopaque,
        CreateRotateTransform3D: *const anyopaque,
        CreateMatrixTransform3D: *const anyopaque,
        CreateTransform3DGroup: *const anyopaque,
        CreateEffectGroup: *const anyopaque,
        CreateRectangleClip: *const anyopaque,
        CreateAnimation: *const fn (*IDCompositionDevice, *?*IDCompositionAnimation) callconv(.c) c.HRESULT,
        CheckDeviceState: *const anyopaque,
    };
};

pub const PresenterError = error{
    AlreadyAttached,
    NotAttached,
    GenerationMismatch,
    DCompositionCreateVisualFailed,
    DCompositionRemoveVisualFailed,
    DCompositionAddVisualFailed,
    DCompositionSetOffsetYFailed,
    DCompositionCommitFailed,
};

fn reportHr(operation: []const u8, hr: c.HRESULT) void {
    if (applog.isEnabled()) {
        applog.appLog("[dcomp] {s} failed: 0x{x}\n", .{ operation, @as(u32, @bitCast(hr)) });
    }
}

fn releaseVisual(visual: ?*IDCompositionVisual) void {
    if (visual) |v| _ = v.lpVtbl.Release(v);
}

fn addVisual(parent: *IDCompositionVisual, child: *IDCompositionVisual) PresenterError!void {
    const hr = parent.lpVtbl.AddVisual(parent, child, c.FALSE, null);
    if (c.FAILED(hr)) {
        reportHr("AddVisual", hr);
        return error.DCompositionAddVisualFailed;
    }
}

fn removeVisual(parent: *IDCompositionVisual, child: *IDCompositionVisual) PresenterError!void {
    const hr = parent.lpVtbl.RemoveVisual(parent, child);
    if (c.FAILED(hr)) {
        reportHr("RemoveVisual", hr);
        return error.DCompositionRemoveVisualFailed;
    }
}

/// App-owned DirectComposition epoch visual and its original visual edge.
pub const DCompScrollPresenter = struct {
    epoch_visual: ?*IDCompositionVisual = null,
    parent_visual: ?*IDCompositionVisual = null,
    content_visual: ?*IDCompositionVisual = null,
    device: ?*IDCompositionDevice = null,
    generation: ?u64 = null,

    pub fn init() DCompScrollPresenter {
        return .{};
    }

    /// Create epoch_visual and replace parent_visual -> content_visual with
    /// parent_visual -> epoch_visual -> content_visual. The returned visual
    /// is the one later passed to IDirectManipulationCompositor::AddContent.
    ///
    /// The caller must Commit on `device` after this method succeeds and
    /// before calling AddContent. AddContent then moves content_visual below
    /// a compositor-owned visual, so content_visual is no longer a direct
    /// child of epoch_visual.
    pub fn attach(
        self: *DCompScrollPresenter,
        generation: u64,
        device: *IDCompositionDevice,
        parent_visual: *IDCompositionVisual,
        content_visual: *IDCompositionVisual,
    ) PresenterError!*IDCompositionVisual {
        if (self.generation) |active_generation| {
            if (active_generation != generation) return error.GenerationMismatch;
            return error.AlreadyAttached;
        }

        var epoch: ?*IDCompositionVisual = null;
        errdefer releaseVisual(epoch);

        const create_hr = device.lpVtbl.CreateVisual(device, &epoch);
        if (c.FAILED(create_hr) or epoch == null) {
            reportHr("CreateVisual", create_hr);
            return error.DCompositionCreateVisualFailed;
        }

        var original_edge_removed = false;
        var epoch_added_to_parent = false;
        var content_added_to_epoch = false;
        errdefer {
            if (content_added_to_epoch) {
                removeVisual(epoch.?, content_visual) catch {};
            }
            if (epoch_added_to_parent) {
                removeVisual(parent_visual, epoch.?) catch {};
            }
            if (original_edge_removed) {
                addVisual(parent_visual, content_visual) catch {};
            }
        }

        try removeVisual(parent_visual, content_visual);
        original_edge_removed = true;
        try addVisual(parent_visual, epoch.?);
        epoch_added_to_parent = true;
        try addVisual(epoch.?, content_visual);
        content_added_to_epoch = true;

        self.epoch_visual = epoch;
        self.parent_visual = parent_visual;
        self.content_visual = content_visual;
        self.device = device;
        self.generation = generation;
        epoch = null;
        return self.epoch_visual.?;
    }

    /// Restore the original parent_visual -> content_visual edge and release
    /// the app-owned epoch visual. Before calling this method the caller must
    /// RemoveContent from the Direct Manipulation compositor and flush it,
    /// because AddContent has moved content_visual below the compositor-owned
    /// visual. No DirectComposition Commit is performed here; the caller must
    /// Commit on the creating device after detach.
    pub fn detach(self: *DCompScrollPresenter, generation: u64) PresenterError!void {
        const active_generation = self.generation orelse return error.NotAttached;
        if (active_generation != generation) return error.GenerationMismatch;

        const epoch = self.epoch_visual.?;
        const parent = self.parent_visual.?;
        const content = self.content_visual.?;
        var content_removed = false;
        var epoch_removed = false;
        var final_edge_missing = false;
        errdefer {
            if (!final_edge_missing) {
                if (epoch_removed) {
                    addVisual(parent, content) catch {};
                } else if (content_removed) {
                    addVisual(epoch, content) catch {};
                }
            }
        }

        try removeVisual(epoch, content);
        content_removed = true;
        try removeVisual(parent, epoch);
        epoch_removed = true;
        addVisual(parent, content) catch |err| {
            // The epoch has already been removed from parent. Retrying the
            // same failed AddVisual in errdefer cannot repair the topology and
            // leaves the epoch reference/bookkeeping permanently wedged.
            // Commit to the detached state and let the caller rebuild the
            // missing parent -> content edge.
            final_edge_missing = true;
            releaseVisual(self.epoch_visual);
            self.* = .{};
            return err;
        };

        releaseVisual(self.epoch_visual);
        self.* = .{};
    }

    /// Abandon presenter bookkeeping without any DirectComposition tree
    /// surgery. This is for device-loss and other dead-COM paths where
    /// RemoveVisual/AddVisual cannot be expected to succeed. The caller owns
    /// rebuilding the parent/content tree after abandon.
    pub fn abandon(self: *DCompScrollPresenter) void {
        releaseVisual(self.epoch_visual);
        self.* = .{};
    }

    /// Set an absolute epoch offset.  Positive content_travel_px means the
    /// content moved up on screen (published_rows * row_height_px).  The
    /// epoch visual COMPENSATES, it does not apply, that movement: the
    /// Direct Manipulation compositor visual below it already carries the
    /// full continuous up-shift (output_y, negative when content moves up),
    /// and the Presented swap chain already draws the published rows at
    /// their final cells.  Shifting the subtree DOWN by content_travel_px
    /// (DirectComposition positive Y) leaves exactly the unpublished
    /// residual visible: epoch_y + output_y = -(dm_travel_px - published_px).
    /// This presenter is the sole sign-conversion boundary.
    /// Setters deliberately do not Commit; the outermost paint path must call
    /// swap-chain Present, this setter, then commit(device) once.
    pub fn setPresentedDisplacement(
        self: *DCompScrollPresenter,
        generation: u64,
        content_travel_px: f64,
    ) PresenterError!void {
        const active_generation = self.generation orelse return error.NotAttached;
        if (active_generation != generation) return error.GenerationMismatch;
        const epoch = self.epoch_visual.?;
        const offset_y: f32 = @floatCast(content_travel_px);
        const hr = epoch.lpVtbl.SetOffsetY(epoch, offset_y);
        if (c.FAILED(hr)) {
            reportHr("SetOffsetY", hr);
            return error.DCompositionSetOffsetYFailed;
        }
    }

    /// Return the epoch offset to the cell-aligned origin for this session.
    /// The caller owns the subsequent Commit ordering.
    pub fn endSession(self: *DCompScrollPresenter, generation: u64) PresenterError!void {
        try self.setPresentedDisplacement(generation, 0);
    }

    /// Commit the DirectComposition batch after swap-chain Present and epoch
    /// offset updates.  This function intentionally has no hidden Present or
    /// offset side effects.
    pub fn commit(device: *IDCompositionDevice) PresenterError!void {
        const hr = device.lpVtbl.Commit(device);
        if (c.FAILED(hr)) {
            reportHr("Commit", hr);
            return error.DCompositionCommitFailed;
        }
    }
};

// Compile coverage while the module is runtime-inert, mirroring
// direct_manipulation.zig.  The compositor declarations are imported from
// that module; they are intentionally not redeclared here.
comptime {
    _ = direct_manipulation.CLSID_DCompManipulationCompositor;
    _ = direct_manipulation.IDirectManipulationCompositor;
    _ = &DCompScrollPresenter.init;
    _ = &DCompScrollPresenter.attach;
    _ = &DCompScrollPresenter.detach;
    _ = &DCompScrollPresenter.abandon;
    _ = &DCompScrollPresenter.setPresentedDisplacement;
    _ = &DCompScrollPresenter.endSession;
    _ = &DCompScrollPresenter.commit;
}
