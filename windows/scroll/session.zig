//! UI-thread owner and live wiring for smooth scrolling.
//! Accounting remains in coordinator.zig; this module only observes the
//! platform and executes coordinator effects.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const core = @import("zonvie_core");
const applog = app_mod.applog;
const coordinator_mod = @import("coordinator.zig");
const dm_mod = @import("direct_manipulation.zig");
const presenter_mod = @import("dcomp_presenter.zig");
const types = @import("types.zig");

/// Session state relevant to routing a wheel message. This deliberately
/// excludes device classification: Direct Manipulation's handled result is
/// the sole exclusivity decision for an eligible target window.
pub const WheelSessionState = enum {
    none,
    arming,
    active,
};

pub const WheelRouting = enum {
    legacy_once,
    offer,
    consume,
    reset_then_legacy,
    pending_reset_then_legacy,
};

pub const WheelRoutingInput = struct {
    target_eligible: bool,
    target_matches_session: bool,
    session_state: WheelSessionState,
    resetting: bool,
    ui_busy: bool,
    viewport_present: bool,
    dm_handled: ?bool,
};

/// Decide the route for one wheel message. `dm_handled` is null for the
/// pre-offer decision; the caller then invokes ProcessInput and calls this
/// function again with its result. Keeping all routing inputs here makes the
/// production path and its contract rows directly testable.
pub fn wheelRoutingDecision(
    input: WheelRoutingInput,
) WheelRouting {
    if (!input.target_eligible or !input.target_matches_session) return .legacy_once;
    if (input.resetting) return .legacy_once;
    return switch (input.session_state) {
        .none => .legacy_once,
        .arming, .active => {
            if (!input.viewport_present) return .legacy_once;
            if (input.dm_handled == null) {
                return if (input.ui_busy) .pending_reset_then_legacy else .offer;
            }
            if (input.dm_handled.?) return .consume;
            return if (input.ui_busy) .pending_reset_then_legacy else .reset_then_legacy;
        },
    };
}

pub fn candidatePublishedRows(
    records: *const types.FixedRing(types.SemanticCommitRecord, types.MaxSemanticCommits),
    commit_rev: u64,
    generation: u64,
    surface: types.SurfaceToken,
) i64 {
    var total: i64 = 0;
    const mutable_records = @constCast(records);
    for (0..records.count()) |i| {
        const record = mutable_records.at(i);
        if (record.commit_rev > commit_rev) break;
        if (record.session_generation == generation and record.surface.eql(surface) and record.ack_delivered) total += record.rows_delta;
    }
    return total;
}

pub fn resetTargetsSession(requested: types.ScrollSessionId, current: types.ScrollSessionId) bool {
    return requested.generation == current.generation and requested.surface.eql(current.surface);
}

pub fn deadlineIsDue(now_ms: u64, due_ms: u64) bool {
    return due_ms != 0 and now_ms >= due_ms;
}

pub fn readyToFinish(dm_ready: bool, credit_count: usize, semantic_count: usize) bool {
    return dm_ready and credit_count == 0 and semantic_count == 0;
}

const ResetDisposition = enum { begin, ignore };

fn resetDisposition(reset_in_progress: bool) ResetDisposition {
    return if (reset_in_progress) .ignore else .begin;
}

pub const CandidateRows = struct {
    rows: i64 = 0,
    due_count: usize = 0,
    acked_count: usize = 0,
};

fn candidateRows(
    records: *const types.FixedRing(types.SemanticCommitRecord, types.MaxSemanticCommits),
    commit_rev: u64,
    generation: u64,
    surface: types.SurfaceToken,
) CandidateRows {
    var result: CandidateRows = .{};
    const mutable_records = @constCast(records);
    for (0..records.count()) |i| {
        const record = mutable_records.at(i);
        if (record.commit_rev > commit_rev) break;
        if (!record.surface.eql(surface) or record.session_generation != generation) continue;
        result.due_count += 1;
        if (record.ack_delivered) {
            result.acked_count += 1;
            result.rows += record.rows_delta;
        }
    }
    return result;
}

fn semanticPresentRequired(candidates: CandidateRows) bool {
    // A due semantic record forces Present even when drawing produced no
    // dirty rows; the existing back buffer still carries the new content.
    return candidates.due_count != 0;
}

const Identity = struct {
    version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    grid_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    incarnation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const ResetRequest = struct {
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    grid_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    incarnation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reason: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(coordinator_mod.ResetReason.protocol_mismatch)),
};

const CompositionTarget = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*CompositionTarget) callconv(.c) c_ulong,
        SetRoot: *const fn (*CompositionTarget, ?*presenter_mod.IDCompositionVisual) callconv(.c) c.HRESULT,
    };
};

const CompositionBinding = struct {
    // Non-owning aliases into the ExternalWindow renderer's permanent graph.
    // The session only owns the epoch visual held by DCompScrollPresenter.
    target: *CompositionTarget,
    content: *presenter_mod.IDCompositionVisual,
    device: *presenter_mod.IDCompositionDevice,
};

pub const ScrollSessionOwner = struct {
    app: ?*App = null,
    hwnd: ?c.HWND = null,
    surface: types.SurfaceToken = .{ .grid_id = 0, .incarnation = 0 },
    generation: u64 = 0,
    pointer_id: u32 = 0,
    pending_start: bool = false,
    borrow_active: bool = false,
    deadline_armed: bool = false,
    restore_pending: bool = false,
    dm: dm_mod.DmController = undefined,
    presenter: presenter_mod.DCompScrollPresenter = .{},
    composition: ?CompositionBinding = null,
    compositor: ?*dm_mod.IDirectManipulationCompositor = null,
    content: ?*dm_mod.IDirectManipulationContent = null,
    viewport_h_px: i32 = 0,
    viewport_w_px: i32 = 0,
    deadline_generation: u64 = 0,
    deadline_kind: coordinator_mod.DeadlineKind = .borrow_retry,
    deadline_due_ms: u64 = 0,
    ui_busy: bool = false,
    reentrant_reset_pending: bool = false,
    reentrant_reset_reason: coordinator_mod.ResetReason = .generation_mismatch,
    deferred_commit_pending: bool = false,
    deferred_dm_pending: bool = false,
    deferred_deadline_pending: bool = false,
    dm_ready: bool = false,
    resetting: bool = false,
    teardown_failed: bool = false,
    /// Device-loss teardown invalidates all borrowed DComp aliases.
    dead_com: bool = false,
    full_resend_pending: bool = false,
    full_resend_app: ?*App = null,
    shutdown_pending: bool = false,
    coordinator: coordinator_mod.ScrollCoordinator = .{},

    fn identity(self: *const ScrollSessionOwner) types.ScrollSessionId {
        return .{ .generation = self.generation, .surface = self.surface };
    }
};

var g_identity: Identity = .{};
var g_reset_request: ResetRequest = .{};
var g_owner: ScrollSessionOwner = .{};
var g_controller_initialized: bool = false;

fn finishUiOperation(owner: *ScrollSessionOwner) void {
    owner.ui_busy = false;
    if (owner.reentrant_reset_pending and owner.app != null and (activeIdentity() != null or owner.pending_start)) {
        owner.reentrant_reset_pending = false;
        reset(owner, owner.reentrant_reset_reason);
    }
}

fn clearDeferredUiWork(owner: *ScrollSessionOwner) void {
    owner.reentrant_reset_pending = false;
    owner.deferred_commit_pending = false;
    owner.deferred_dm_pending = false;
    owner.deferred_deadline_pending = false;
}

fn servicePendingShutdown(owner: *ScrollSessionOwner) void {
    if (!owner.shutdown_pending) return;
    owner.shutdown_pending = false;
    if (g_controller_initialized) {
        owner.dm.deinit();
        g_controller_initialized = false;
    }
}

pub fn activeIdentity() ?types.ScrollSessionId {
    while (true) {
        const before = g_identity.version.load(.acquire);
        if (before & 1 != 0) continue;
        const active = g_identity.active.load(.acquire);
        const generation = g_identity.generation.load(.acquire);
        const grid_id = g_identity.grid_id.load(.acquire);
        const incarnation = g_identity.incarnation.load(.acquire);
        if (before != g_identity.version.load(.acquire)) continue;
        if (!active) return null;
        return .{ .generation = generation, .surface = .{ .grid_id = grid_id, .incarnation = incarnation } };
    }
}

fn queueResetRequest(app: *App, session: types.ScrollSessionId, reason: coordinator_mod.ResetReason) void {
    g_reset_request.generation.store(session.generation, .monotonic);
    g_reset_request.grid_id.store(session.surface.grid_id, .monotonic);
    g_reset_request.incarnation.store(session.surface.incarnation, .monotonic);
    g_reset_request.reason.store(@intFromEnum(reason), .monotonic);
    app.smooth_scroll_reset_pending.store(true, .release);
    if (app.hwnd) |hwnd| {
        if (app.dm_update_posted.cmpxchgStrong(false, true, .release, .monotonic) == null) {
            if (c.PostMessageW(hwnd, app_mod.WM_APP_DM_UPDATE, 0, 0) == 0) {
                app.dm_update_posted.store(false, .release);
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
            }
        }
    }
}

pub fn requestReset(app: *App, expected: ?types.ScrollSessionId, reason: coordinator_mod.ResetReason) void {
    const active = activeIdentity() orelse return;
    if (expected) |session| if (active.generation != session.generation or !active.surface.eql(session.surface)) return;
    queueResetRequest(app, active, reason);
}

fn queuePendingReset(owner: *const ScrollSessionOwner, reason: coordinator_mod.ResetReason) void {
    const app = owner.app orelse return;
    queueResetRequest(app, owner.identity(), reason);
}

fn publishIdentity(owner: *const ScrollSessionOwner) void {
    _ = g_identity.version.fetchAdd(1, .acq_rel);
    g_identity.generation.store(owner.generation, .monotonic);
    g_identity.grid_id.store(owner.surface.grid_id, .monotonic);
    g_identity.incarnation.store(owner.surface.incarnation, .monotonic);
    g_identity.active.store(true, .release);
    _ = g_identity.version.fetchAdd(1, .release);
}

fn clearIdentity() void {
    _ = g_identity.version.fetchAdd(1, .acq_rel);
    g_identity.active.store(false, .release);
    _ = g_identity.version.fetchAdd(1, .release);
}

fn findExternal(app: *App, hwnd: c.HWND) ?struct { grid_id: i64, ext: *app_mod.ExternalWindow } {
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    var it = app.external_windows.iterator();
    while (it.next()) |entry| if (entry.value_ptr.*.hwnd == hwnd)
        return .{ .grid_id = entry.key_ptr.*, .ext = entry.value_ptr.* };
    return null;
}

pub fn modeBusy(app: *App) bool {
    const cp = app.corep orelse return true;
    var mode: [16]u8 = undefined;
    var visible = true;
    const rc = app_mod.zonvie_core_try_get_mode_state(cp, &mode, mode.len, &visible);
    if (rc < 0) return true;
    return !visible;
}

fn wheelTargetEligible(app: *App, hwnd: c.HWND, grid_id: i64) bool {
    // External windows use the displacement presentation path exclusively.
    _ = app;
    _ = hwnd;
    _ = grid_id;
    return false;
}

fn pointerIsTouchContact(pointer_id: u32) bool {
    var pointer_type: c.POINTER_INPUT_TYPE = undefined;
    return c.GetPointerType(pointer_id, &pointer_type) != 0 and
        (pointer_type == c.PT_TOUCHPAD or pointer_type == c.PT_TOUCH);
}

fn rejectExternalComposition(owner: *ScrollSessionOwner, ext: *app_mod.ExternalWindow) !void {
    _ = owner;
    _ = ext;
    return error.ExternalCompositionDisabled;
}

fn detachComposition(owner: *ScrollSessionOwner, defer_commit: bool) bool {
    if (owner.dead_com) {
        // Device-loss recovery releases/rebuilds these objects. Do not call
        // even Release on aliases from that dead COM generation.
        owner.presenter = presenter_mod.DCompScrollPresenter.init();
        owner.compositor = null;
        owner.content = null;
        owner.composition = null;
        return true;
    }
    var succeeded = true;
    var compositor_tree_alive = true;
    if (owner.compositor) |comp| {
        if (owner.content) |content| {
            if (c.FAILED(comp.lpVtbl.RemoveContent(comp, content))) {
                succeeded = false;
                compositor_tree_alive = false;
            }
        }
        if (c.FAILED(comp.lpVtbl.Flush(comp))) {
            succeeded = false;
            compositor_tree_alive = false;
        }
        _ = comp.lpVtbl.Release(comp);
        owner.compositor = null;
    }
    if (owner.composition) |composition| {
        if (owner.presenter.generation) |gen| {
            if (compositor_tree_alive) {
                owner.presenter.detach(gen) catch {
                    succeeded = false;
                    owner.presenter.abandon();
                };
            } else {
                owner.presenter.abandon();
            }
        }
        if (!defer_commit) presenter_mod.DCompScrollPresenter.commit(composition.device) catch {
            succeeded = false;
        };
    } else if (owner.presenter.generation) |gen| {
        if (compositor_tree_alive) {
            owner.presenter.detach(gen) catch {
                succeeded = false;
                owner.presenter.abandon();
            };
        } else {
            owner.presenter.abandon();
        }
    }
    owner.composition = null;
    owner.content = null;
    return succeeded;
}

fn compositionGenerationDead(owner: *const ScrollSessionOwner, app: *App, hwnd: c.HWND) bool {
    if (app.device_lost_recovering) return true;
    const found = findExternal(app, hwnd) orelse return true;
    if (found.ext.renderer.device_lost) return true;
    const composition = owner.composition orelse return false;
    const renderer_device = @field(found.ext.renderer, "dcomp_device") orelse return true;
    const renderer_target = @field(found.ext.renderer, "dcomp_target") orelse return true;
    const renderer_visual = @field(found.ext.renderer, "dcomp_visual") orelse return true;
    return @intFromPtr(renderer_device) != @intFromPtr(composition.device) or
        @intFromPtr(renderer_target) != @intFromPtr(composition.target) or
        @intFromPtr(renderer_visual) != @intFromPtr(composition.content);
}

fn armDeadline(owner: *ScrollSessionOwner, delay_ms: u32, kind: coordinator_mod.DeadlineKind) void {
    const app = owner.app orelse return;
    const hwnd = app.hwnd orelse return;
    owner.deadline_generation = owner.generation;
    owner.deadline_kind = kind;
    owner.deadline_due_ms = c.GetTickCount64() + delay_ms;
    if (c.SetTimer(hwnd, app_mod.TIMER_SMOOTH_SCROLL_DEADLINE, delay_ms, null) == 0) {
        if (applog.isEnabled()) applog.appLog("[smooth] SetTimer failed kind={s} delay_ms={d}\n", .{ @tagName(kind), delay_ms });
        owner.deadline_armed = false;
        // deadline_due_ms remains authoritative. The main message loop folds
        // it into MsgWaitForMultipleObjectsEx and services the same one-shot
        // transition even when USER cannot allocate a timer slot.
        return;
    }
    owner.deadline_armed = true;
}

pub fn fallbackDeadlineMs(app: *App) u64 {
    if (g_owner.app != app) return 0;
    return g_owner.deadline_due_ms;
}

pub fn serviceFallbackDeadline(app: *App, now_ms: u64) void {
    if (g_owner.app != app or g_owner.deadline_due_ms == 0 or g_owner.deadline_due_ms > now_ms) return;
    onDeadline(app);
}

pub fn servicePendingResend(app: *App) void {
    if (!g_owner.full_resend_pending or g_owner.full_resend_app != app) return;
    if (app.corep) |cp| {
        app_mod.zonvie_core_force_resend(cp);
        app_mod.zonvie_core_retry_flush(cp);
        g_owner.full_resend_pending = false;
        g_owner.full_resend_app = null;
    }
}

fn dropOrphanRecords(app: *App, session: types.ScrollSessionId) void {
    app.mu.lockUncancelable(core.clock.io());
    const ext = app.external_windows.get(session.surface.grid_id);
    if (ext == null or ext.?.incarnation != session.surface.incarnation) {
        app.mu.unlock(core.clock.io());
        return;
    }
    const target = ext.?;
    app.mu.unlock(core.clock.io());

    target.tbs.rotation_mu.lockUncancelable(core.clock.io());
    defer target.tbs.rotation_mu.unlock(core.clock.io());
    var kept: types.FixedRing(types.SemanticCommitRecord, types.MaxSemanticCommits) = .{};
    while (target.tbs.semantic_commits.popFront()) |record| {
        if (record.session_generation == session.generation and record.surface.eql(session.surface)) continue;
        _ = kept.push(record);
    }
    target.tbs.semantic_commits = kept;
}

fn pendingResetSession() types.ScrollSessionId {
    return .{
        .generation = g_reset_request.generation.load(.monotonic),
        .surface = .{
            .grid_id = g_reset_request.grid_id.load(.monotonic),
            .incarnation = g_reset_request.incarnation.load(.monotonic),
        },
    };
}

fn pendingResetReason() coordinator_mod.ResetReason {
    return @enumFromInt(g_reset_request.reason.load(.monotonic));
}

fn drainPendingReset(owner: *ScrollSessionOwner) bool {
    const app = owner.app orelse return false;
    if (!app.smooth_scroll_reset_pending.swap(false, .acquire)) return true;
    const requested = pendingResetSession();
    const reason = pendingResetReason();
    if (resetTargetsSession(requested, owner.identity())) {
        reset(owner, reason);
        return false;
    }
    dropOrphanRecords(app, requested);
    return true;
}

fn drainAcks(owner: *ScrollSessionOwner) bool {
    const app = owner.app orelse return false;
    if (!drainPendingReset(owner)) return false;
    const ext = findExternal(app, owner.hwnd orelse return false) orelse {
        reset(owner, .generation_mismatch);
        return false;
    };
    ext.ext.tbs.rotation_mu.lockUncancelable(core.clock.io());
    var failed = false;
    var i: usize = 0;
    while (i < ext.ext.tbs.semantic_commits.count()) : (i += 1) {
        const record = ext.ext.tbs.semantic_commits.at(i);
        if (!record.surface.eql(owner.surface) or record.session_generation != owner.generation or record.ack_delivered) continue;
        var candidate = record.*;
        candidate.ack_delivered = false;
        owner.coordinator.onGridScrollFor(candidate.session_generation, candidate.surface, candidate.rows_delta);
        if (owner.coordinator.session == null) {
            failed = true;
            break;
        }
        owner.coordinator.onSemanticCommit(candidate);
        if (owner.coordinator.session == null) {
            failed = true;
            break;
        }
        record.ack_delivered = true;
    }
    ext.ext.tbs.rotation_mu.unlock(core.clock.io());
    if (failed) executeEffects(owner, false);
    return !failed;
}

fn dropRecords(owner: *ScrollSessionOwner) void {
    const app = owner.app orelse return;
    const ext = findExternal(app, owner.hwnd orelse return) orelse return;
    ext.ext.tbs.rotation_mu.lockUncancelable(core.clock.io());
    defer ext.ext.tbs.rotation_mu.unlock(core.clock.io());
    ext.ext.tbs.semantic_commits.clear();
}

fn reset(owner: *ScrollSessionOwner, reason: coordinator_mod.ResetReason) void {
    // Nested teardown callbacks are deliberately idempotent. The outer
    // teardown owns COM release and smooth-scroll restoration exactly once.
    if (resetDisposition(owner.resetting) == .ignore) return;
    owner.resetting = true;
    const app = owner.app;
    const old_hwnd = owner.hwnd;
    clearIdentity();
    if (applog.isEnabled()) applog.appLog("[smooth] reset generation={d} grid={d} reason={s}\n", .{ owner.generation, owner.surface.grid_id, @tagName(reason) });
    if (app) |a| {
        if (owner.coordinator.session != null) {
            owner.coordinator.endSession(owner.generation);
            executeEffects(owner, false);
        }
        dropRecords(owner);
        owner.full_resend_pending = true;
        owner.full_resend_app = a;
    }
    owner.deadline_due_ms = 0;
    if (!detachComposition(owner, false)) owner.teardown_failed = true;
    owner.dead_com = false;
    owner.dm.destroyViewport();
    if (!owner.restore_pending) {
        if (owner.deadline_armed) {
            if (app) |a| {
                if (a.hwnd) |h| _ = c.KillTimer(h, app_mod.TIMER_SMOOTH_SCROLL_DEADLINE);
            }
        }
        owner.deadline_armed = false;
    }
    owner.pending_start = false;
    owner.dm_ready = false;
    clearDeferredUiWork(owner);
    if (owner.borrow_active and !owner.restore_pending) {
        owner.restore_pending = if (app) |a| if (a.corep) |cp|
            app_mod.zonvie_core_set_gesture_smooth_scroll(cp, owner.surface.grid_id, false) == 0
        else
            false else false;
        if (!owner.restore_pending) owner.borrow_active = false;
    }
    if (owner.restore_pending and app != null) {
        armDeadline(owner, coordinator_mod.borrow_retry_delay_ms, .restore_retry);
    } else {
        owner.app = null;
    }
    if (old_hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, c.FALSE);
    owner.hwnd = null;
    owner.resetting = false;
    servicePendingShutdown(owner);
}

fn finishReady(owner: *ScrollSessionOwner, defer_commit: bool) void {
    // This is the orderly end path: the caller observed a READY viewport and
    // no outstanding semantic/request work before DM content teardown.
    if (resetDisposition(owner.resetting) == .ignore) return;
    owner.resetting = true;
    owner.teardown_failed = false;
    const app = owner.app;
    const old_hwnd = owner.hwnd;
    clearIdentity();
    if (owner.coordinator.session != null) {
        owner.coordinator.endSession(owner.generation);
        // A paint-owned finish folds detach surgery into the outer Present
        // gate; suppress the epoch effect's standalone Commit as well.
        executeEffects(owner, defer_commit);
    }
    dropRecords(owner);
    if (!detachComposition(owner, defer_commit)) owner.teardown_failed = true;
    owner.dead_com = false;
    owner.dm.destroyViewport();
    if (owner.deadline_armed) {
        if (app) |a| {
            if (a.hwnd) |h| {
                _ = c.KillTimer(h, app_mod.TIMER_SMOOTH_SCROLL_DEADLINE);
            }
        }
    }
    owner.deadline_armed = false;
    owner.deadline_due_ms = 0;
    owner.pending_start = false;
    owner.dm_ready = false;
    clearDeferredUiWork(owner);
    if (owner.borrow_active and !owner.restore_pending) {
        owner.restore_pending = if (app) |a| if (a.corep) |cp|
            app_mod.zonvie_core_set_gesture_smooth_scroll(cp, owner.surface.grid_id, false) == 0
        else
            false else false;
        if (!owner.restore_pending) owner.borrow_active = false;
    }
    if (owner.restore_pending and app != null) {
        armDeadline(owner, coordinator_mod.borrow_retry_delay_ms, .restore_retry);
    } else {
        owner.app = null;
    }
    if (owner.teardown_failed) {
        if (applog.isEnabled()) applog.appLog("[smooth] reset generation={d} grid={d} reason={s}\n", .{ owner.generation, owner.surface.grid_id, @tagName(coordinator_mod.ResetReason.presentation_failure) });
        if (app) |a| {
            owner.full_resend_pending = true;
            owner.full_resend_app = a;
        }
    }
    if (old_hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, c.FALSE);
    owner.hwnd = null;
    owner.resetting = false;
    servicePendingShutdown(owner);
}

fn executeEffects(owner: *ScrollSessionOwner, skip_epoch_effect: bool) void {
    const app = owner.app orelse return;
    var effects = owner.coordinator.effectsSlice();
    var copied: [coordinator_mod.effect_capacity]coordinator_mod.Effect = undefined;
    const count = @min(effects.len, copied.len);
    @memcpy(copied[0..count], effects[0..count]);
    for (copied[0..count]) |effect| switch (effect) {
        .send_scroll => |direction| {
            if (!drainAcks(owner)) return;
            if (owner.coordinator.phase == .idle) continue;
            const cp = app.corep orelse continue;
            var viewport: app_mod.ViewportInfo = undefined;
            const probe = app_mod.zonvie_core_try_get_viewport(cp, owner.surface.grid_id, &viewport);
            if (probe == 1) {
                const at_edge = if (direction == .positive) viewport.botline >= viewport.line_count else viewport.topline <= 0;
                if (at_edge) {
                    owner.coordinator.onViewportEdge(.{ .generation = owner.generation, .surface = owner.surface, .direction = direction, .viewport_edge = true });
                    executeEffects(owner, skip_epoch_effect);
                    return;
                }
            }
            const dir: [*:0]const u8 = if (direction == .positive) "down" else "up";
            app_mod.zonvie_core_send_mouse_scroll(cp, owner.surface.grid_id, 0, 0, dir, "");
        },
        .arm_deadline => |deadline| armDeadline(owner, deadline.delay_ms, deadline.kind),
        .stop_dm => owner.dm.deactivate(),
        .apply_epoch_px => |px| if (skip_epoch_effect) {} else if (owner.presenter.generation) |gen| {
            if (owner.presenter.setPresentedDisplacement(gen, px)) |_| {
                if (owner.composition) |composition| presenter_mod.DCompScrollPresenter.commit(composition.device) catch {
                    if (owner.resetting) owner.teardown_failed = true else reset(owner, .presentation_failure);
                };
            } else |_| if (owner.resetting) {
                owner.teardown_failed = true;
            } else reset(owner, .presentation_failure);
        },
        .restore_smoothscroll => {
            owner.restore_pending = true;
            if (app.corep) |cp| {
                if (app_mod.zonvie_core_set_gesture_smooth_scroll(cp, owner.surface.grid_id, false) != 0) {
                    owner.restore_pending = false;
                    owner.borrow_active = false;
                } else {
                    armDeadline(owner, coordinator_mod.borrow_retry_delay_ms, .restore_retry);
                }
            }
        },
        .reset => |reason| reset(owner, reason),
    };
}

fn finishStart(owner: *ScrollSessionOwner) void {
    const app = owner.app orelse return;
    const ext = findExternal(app, owner.hwnd orelse return) orelse {
        reset(owner, .generation_mismatch);
        return;
    };
    const cp = app.corep orelse return;
    const ver = app_mod.zonvie_core_get_mousescroll_ver(cp);
    var rc: c.RECT = undefined;
    _ = c.GetClientRect(ext.ext.hwnd, &rc);
    owner.viewport_h_px = @max(1, rc.bottom - rc.top);
    owner.viewport_w_px = @max(1, rc.right - rc.left);
    const generation = owner.dm.generation.load(.acquire);
    owner.generation = generation;
    owner.coordinator.beginSession(.{ .session = owner.identity(), .row_height_px = @floatFromInt(app.cell_h_px + app.linespace_px), .quantum_rows = @intCast(@min(ver, std.math.maxInt(i32))), .output_origin_y_px = 0 });
    owner.coordinator.onBorrowResult(generation, true);
    rejectExternalComposition(owner, ext.ext) catch {
        reset(owner, .presentation_failure);
        return;
    };
    owner.dm.activate(ext.ext.hwnd) catch {
        reset(owner, .presentation_failure);
        return;
    };
    publishIdentity(owner);
    owner.pending_start = false;
    owner.dm_ready = false;
    // Contact-created sessions claim the pointer after viewport setup.
    if (owner.pointer_id != 0) owner.dm.onPointerHitTest(owner.pointer_id);
    if (applog.isEnabled()) applog.appLog("[smooth] start grid={d} incarnation={d} generation={d} row_height_px={d} quantum_rows={d} viewport=({d},{d})\n", .{ owner.surface.grid_id, owner.surface.incarnation, owner.generation, owner.coordinator.row_height_px, owner.coordinator.quantum_rows, owner.viewport_w_px, owner.viewport_h_px });
}

fn tryBorrow(owner: *ScrollSessionOwner) void {
    const app = owner.app orelse return;
    const cp = app.corep orelse return;
    if (app_mod.zonvie_core_set_gesture_smooth_scroll(cp, owner.surface.grid_id, true) != 0) {
        owner.borrow_active = true;
        if (owner.dm.manager == null) owner.dm.createManager() catch {
            reset(owner, .protocol_mismatch);
            return;
        };
        const ext = findExternal(app, owner.hwnd orelse return) orelse {
            reset(owner, .generation_mismatch);
            return;
        };
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(ext.ext.hwnd, &rc);
        owner.dm.createViewport(ext.ext.hwnd, @max(1, rc.right - rc.left), @max(1, rc.bottom - rc.top)) catch {
            reset(owner, .protocol_mismatch);
            return;
        };
        finishStart(owner);
    } else {
        armDeadline(owner, coordinator_mod.borrow_retry_delay_ms, .borrow_retry);
    }
}

fn begin(app: *App, hwnd: c.HWND, grid_id: i64, pointer_id: u32) bool {
    const ext = findExternal(app, hwnd) orelse return false;
    if (!wheelTargetEligible(app, hwnd, grid_id)) return false;
    if (activeIdentity() != null or g_owner.app != null or g_owner.restore_pending or g_owner.full_resend_pending) return false;
    if (!g_controller_initialized) {
        g_owner.dm = dm_mod.DmController.init(app.hwnd orelse hwnd, app_mod.WM_APP_DM_UPDATE, &app.dm_update_posted);
        g_controller_initialized = true;
    }
    g_owner.app = app;
    g_owner.hwnd = hwnd;
    g_owner.surface = .{ .grid_id = grid_id, .incarnation = ext.ext.incarnation };
    g_owner.pointer_id = pointer_id;
    g_owner.pending_start = true;
    g_owner.dm_ready = false;
    g_owner.teardown_failed = false;
    clearDeferredUiWork(&g_owner);
    g_owner.ui_busy = true;
    tryBorrow(&g_owner);
    finishUiOperation(&g_owner);
    return true;
}

pub fn onPointerHitTest(app: *App, hwnd: c.HWND, grid_id: i64, pointer_id: u32) bool {
    if (!pointerIsTouchContact(pointer_id)) return false;
    if (activeIdentity() != null) {
        if (g_owner.hwnd) |owned_hwnd| {
            if (owned_hwnd == hwnd and g_owner.surface.grid_id == grid_id) {
                if (g_owner.ui_busy) return true;
                g_owner.ui_busy = true;
                g_owner.dm.onPointerHitTest(pointer_id);
                finishUiOperation(&g_owner);
                return true;
            }
        }
        return false;
    }
    if (g_owner.app == app and g_owner.pending_start and g_owner.hwnd != null and g_owner.hwnd.? == hwnd and g_owner.surface.grid_id == grid_id) {
        g_owner.pointer_id = pointer_id;
        return true;
    }
    return begin(app, hwnd, grid_id, pointer_id);
}

pub fn onPointerDown(app: *App, hwnd: c.HWND, grid_id: i64, pointer_id: u32) bool {
    return onPointerHitTest(app, hwnd, grid_id, pointer_id);
}

pub fn onDmPointerHitTest(app: *App, hwnd: c.HWND, grid_id: i64, pointer_id: u32) bool {
    // DM_POINTERHITTEST remains the touch-contact arming entry point. It
    // performs the same eligibility check as WM_POINTERDOWN and uses the id
    // carried by this message, never a stale arming id. Once a session exists,
    // wheel messages are the primary Direct Manipulation input path; this is
    // the additional SetContact path for touch contacts.
    return onPointerHitTest(app, hwnd, grid_id, pointer_id);
}

/// Route one wheel message through Direct Manipulation only for an existing
/// active or arming session owned by the target window. A declined message
/// resets that session before the caller's single legacy delivery.
pub fn processWheel(
    app: *App,
    hwnd: c.HWND,
    grid_id: i64,
    message: c.UINT,
    w_param: c.WPARAM,
    l_param: c.LPARAM,
    horizontal: bool,
) bool {
    _ = horizontal;
    const same_target = g_owner.app == app and g_owner.hwnd != null and
        g_owner.hwnd.? == hwnd and g_owner.surface.grid_id == grid_id;
    const state: WheelSessionState = if (same_target)
        if (activeIdentity() != null) .active else if (g_owner.pending_start) .arming else .none
    else
        .none;

    const decision_input: WheelRoutingInput = .{
        .target_eligible = wheelTargetEligible(app, hwnd, grid_id),
        .target_matches_session = same_target,
        .session_state = state,
        .resetting = g_owner.resetting,
        .ui_busy = g_owner.ui_busy,
        .viewport_present = same_target and g_owner.dm.viewport != null,
        .dm_handled = null,
    };
    const pre_offer = wheelRoutingDecision(decision_input);
    switch (pre_offer) {
        .legacy_once => return false,
        .pending_reset_then_legacy => {
            // A nested pump/lifecycle call cannot reset synchronously. The
            // coordinator's foreign_scroll reset remains the fail-closed
            // backstop for this rare case; deliver legacy exactly once.
            queuePendingReset(&g_owner, .foreign_scroll);
            return false;
        },
        .offer => {},
        .consume, .reset_then_legacy => unreachable,
    }

    var msg: c.MSG = std.mem.zeroes(c.MSG);
    msg.hwnd = hwnd;
    msg.message = message;
    msg.wParam = w_param;
    msg.lParam = l_param;
    g_owner.ui_busy = true;
    defer finishUiOperation(&g_owner);
    const dm_handled = g_owner.dm.processInput(&msg);
    const outcome = wheelRoutingDecision(.{
        .target_eligible = decision_input.target_eligible,
        .target_matches_session = decision_input.target_matches_session,
        .session_state = decision_input.session_state,
        .resetting = decision_input.resetting,
        .ui_busy = decision_input.ui_busy,
        .viewport_present = decision_input.viewport_present,
        .dm_handled = dm_handled,
    });
    switch (outcome) {
        .consume => return true,
        .reset_then_legacy => {
            reset(&g_owner, .foreign_scroll);
            return false;
        },
        .pending_reset_then_legacy => {
            // A nested pump/lifecycle call cannot reset synchronously. The
            // coordinator's foreign_scroll reset remains the fail-closed
            // backstop for this rare case; deliver legacy exactly once.
            queuePendingReset(&g_owner, .foreign_scroll);
            return false;
        },
        .legacy_once => return false,
        .offer => unreachable,
    }
}

pub fn onSmoothCommit(app: *App) void {
    if (g_owner.app != app or activeIdentity() == null) return;
    if (app.wm_paint_in_progress or g_owner.ui_busy) {
        g_owner.deferred_commit_pending = true;
        return;
    }
    g_owner.ui_busy = true;
    defer finishUiOperation(&g_owner);
    _ = drainAcks(&g_owner);
}

pub fn onDmUpdate(app: *App) void {
    if (g_owner.app != app or activeIdentity() == null) return;
    if (app.wm_paint_in_progress or g_owner.ui_busy) {
        g_owner.deferred_dm_pending = true;
        return;
    }
    g_owner.ui_busy = true;
    defer finishUiOperation(&g_owner);
    if (!drainAcks(&g_owner)) return;
    const snapshot = g_owner.dm.readSnapshot();
    const cp = app.corep orelse return;
    const direction = g_owner.coordinator.active_direction;
    var probe: ?coordinator_mod.EdgeProbe = null;
    if (direction) |known_direction| {
        var viewport: app_mod.ViewportInfo = undefined;
        const probe_result = app_mod.zonvie_core_try_get_viewport(cp, g_owner.surface.grid_id, &viewport);
        // The viewport probe is one snapshot stale by construction; a
        // reversal therefore conservatively selects the 200 ms fallback.
        probe = .{ .direction = known_direction, .confirmed = probe_result == 1 };
    }
    g_owner.coordinator.onDmSnapshotWithEdgeProbe(snapshot, probe);
    if (snapshot.generation != g_owner.generation) return;
    g_owner.dm_ready = snapshot.status == .ready;
    if (g_owner.coordinator.session != null and
        @abs(g_owner.coordinator.dm_travel_px) > @as(f64, @floatFromInt(dm_mod.max_session_travel_px - @max(1, g_owner.viewport_h_px))))
    {
        g_owner.coordinator.onContentRectEdge(g_owner.generation, g_owner.surface, true);
    }
    if (g_owner.coordinator.session == null) {
        executeEffects(&g_owner, false);
        return;
    }
    if (readyToFinish(g_owner.dm_ready, g_owner.coordinator.creditCount(), g_owner.coordinator.semanticCommitCount())) {
        finishReady(&g_owner, false);
        return;
    }
    executeEffects(&g_owner, false);
}

pub fn onDeadline(app: *App) void {
    if (g_owner.app != app) return;
    if (app.wm_paint_in_progress or g_owner.ui_busy) {
        g_owner.deferred_deadline_pending = true;
        return;
    }
    g_owner.ui_busy = true;
    defer finishUiOperation(&g_owner);
    const now_ms = c.GetTickCount64();
    if (!deadlineIsDue(now_ms, g_owner.deadline_due_ms)) return;
    _ = c.KillTimer(app.hwnd orelse return, app_mod.TIMER_SMOOTH_SCROLL_DEADLINE);
    g_owner.deadline_armed = false;
    g_owner.deadline_due_ms = 0;
    if (g_owner.deadline_generation != g_owner.generation) return;
    if (g_owner.restore_pending) {
        if (app.corep) |cp| {
            if (app_mod.zonvie_core_set_gesture_smooth_scroll(cp, g_owner.surface.grid_id, false) != 0) {
                g_owner.restore_pending = false;
                g_owner.borrow_active = false;
                g_owner.app = null;
                clearIdentity();
            } else armDeadline(&g_owner, coordinator_mod.borrow_retry_delay_ms, .restore_retry);
        }
        return;
    }
    if (g_owner.pending_start) {
        tryBorrow(&g_owner);
        return;
    }
    // Deadline expiry clears the epoch immediately; the forced full resend
    // covers the brief interval before the next pending Present.
    g_owner.coordinator.onDeadlineExpired(g_owner.generation, g_owner.deadline_kind);
    executeEffects(&g_owner, false);
}

pub fn onPaintPresent(app: *App, ext: *app_mod.ExternalWindow, snapshot: app_mod.PaintSnapshot, present_succeeded: bool) void {
    if (!snapshot.outermost_paint or present_succeeded) return;
    if (g_owner.app == app and activeIdentity() != null and g_owner.hwnd != null and g_owner.hwnd.? == ext.hwnd) {
        if (compositionGenerationDead(&g_owner, app, ext.hwnd)) g_owner.dead_com = true;
        reset(&g_owner, .presentation_failure);
    }
}

pub fn semanticDue(app: *App, ext: *app_mod.ExternalWindow, snapshot: app_mod.PaintSnapshot) bool {
    if (!snapshot.outermost_paint or g_owner.app != app or activeIdentity() == null or (g_owner.hwnd == null or ext.hwnd != g_owner.hwnd.?)) return false;
    if (!drainAcks(&g_owner)) return false;
    if (g_owner.app != app or activeIdentity() == null) return false;
    ext.tbs.rotation_mu.lockUncancelable(core.clock.io());
    defer ext.tbs.rotation_mu.unlock(core.clock.io());
    for (0..ext.tbs.semantic_commits.count()) |i| {
        const record = ext.tbs.semantic_commits.at(i);
        if (record.commit_rev > snapshot.commit_rev) break;
        if (record.surface.eql(g_owner.surface) and record.session_generation == g_owner.generation) return true;
    }
    return false;
}

pub fn onSurfaceInvalidated(app: *App, hwnd: c.HWND, reason: coordinator_mod.ResetReason) void {
    if (reason == .generation_mismatch or reason == .presentation_failure) {
        if (findExternal(app, hwnd)) |external| external.ext.resetContractBEase(@tagName(reason));
    }
    if (g_owner.resetting) return;
    if (g_owner.app == app and g_owner.hwnd != null and g_owner.hwnd.? == hwnd) {
        if (g_owner.ui_busy or app.wm_paint_in_progress) {
            g_owner.reentrant_reset_pending = true;
            g_owner.reentrant_reset_reason = reason;
            return;
        }
        reset(&g_owner, reason);
    }
}

/// Paint-owned lifecycle boundary used immediately before swap-chain
/// recreation or after device loss. The caller already excludes inner paint
/// publication and must tear DM/DComp down before touching the swap chain.
pub fn onSurfaceInvalidatedFromPaint(app: *App, hwnd: c.HWND, reason: coordinator_mod.ResetReason) void {
    const found = findExternal(app, hwnd);
    if (found) |external| external.ext.resetContractBEase(@tagName(reason));
    if (g_owner.resetting) return;
    if (g_owner.app == app and g_owner.hwnd != null and g_owner.hwnd.? == hwnd) {
        if (reason == .presentation_failure and compositionGenerationDead(&g_owner, app, hwnd)) g_owner.dead_com = true;
        if (g_owner.ui_busy or app.wm_paint_in_progress) {
            g_owner.reentrant_reset_pending = true;
            g_owner.reentrant_reset_reason = reason;
            return;
        }
        reset(&g_owner, reason);
    }
}

pub fn onDeviceLost(app: *App) void {
    app.mu.lockUncancelable(core.clock.io());
    var external_it = app.external_windows.valueIterator();
    while (external_it.next()) |ext| {
        ext.*.resetContractBEase("device_loss");
    }
    app.mu.unlock(core.clock.io());
    if (g_owner.resetting) return;
    if (g_owner.app != app) return;
    g_owner.dead_com = true;
    if (g_owner.ui_busy or app.wm_paint_in_progress) {
        g_owner.reentrant_reset_pending = true;
        g_owner.reentrant_reset_reason = .presentation_failure;
        return;
    }
    reset(&g_owner, .presentation_failure);
}

/// Resume UI messages that were delivered by a nested pump while an outer
/// paint owned the Present gate. They are ordinary drains/deadlines, not
/// accounting failures, and run only after the paint has fully unwound.
pub fn serviceDeferredUiWork(app: *App) void {
    if (g_owner.app != app or app.wm_paint_in_progress or g_owner.ui_busy or g_owner.resetting) return;
    if (g_owner.reentrant_reset_pending) {
        const reason = g_owner.reentrant_reset_reason;
        g_owner.reentrant_reset_pending = false;
        reset(&g_owner, reason);
        return;
    }
    if (g_owner.deferred_commit_pending) {
        g_owner.deferred_commit_pending = false;
        onSmoothCommit(app);
    }
    if (g_owner.deferred_dm_pending) {
        g_owner.deferred_dm_pending = false;
        onDmUpdate(app);
    }
    if (g_owner.deferred_deadline_pending) {
        g_owner.deferred_deadline_pending = false;
        onDeadline(app);
    }
}

/// Fallback for a failed PostMessage from the core-thread semantic bridge.
/// The reset flag is consumed with swap(false, acquire) before touching the
/// semantic ring, including when this fallback runs without an active owner.
pub fn servicePendingReset(app: *App) void {
    if (g_owner.app != app) {
        if (app.smooth_scroll_reset_pending.swap(false, .acquire)) {
            dropOrphanRecords(app, pendingResetSession());
        }
        return;
    }
    if (app.wm_paint_in_progress or g_owner.ui_busy) {
        g_owner.deferred_commit_pending = true;
        return;
    }
    g_owner.ui_busy = true;
    defer finishUiOperation(&g_owner);
    _ = drainPendingReset(&g_owner);
}

pub fn shutdown(app: *App) void {
    if (g_owner.resetting) {
        // Teardown may pump messages. Defer controller destruction until the
        // outer reset/READY teardown has released every viewport and COM edge.
        g_owner.shutdown_pending = true;
        return;
    }
    if (g_owner.app == app) reset(&g_owner, .generation_mismatch);
    if (g_controller_initialized) {
        g_owner.dm.deinit();
        g_controller_initialized = false;
    }
}

fn routingInput(
    target_eligible: bool,
    target_matches_session: bool,
    session_state: WheelSessionState,
    resetting: bool,
    ui_busy: bool,
    viewport_present: bool,
    dm_handled: ?bool,
) WheelRoutingInput {
    return .{
        .target_eligible = target_eligible,
        .target_matches_session = target_matches_session,
        .session_state = session_state,
        .resetting = resetting,
        .ui_busy = ui_busy,
        .viewport_present = viewport_present,
        .dm_handled = dm_handled,
    };
}

test "wheel routing leaves an eligible window without a session on legacy" {
    try std.testing.expectEqual(
        WheelRouting.legacy_once,
        wheelRoutingDecision(routingInput(true, false, .none, false, false, false, null)),
    );
}

test "wheel routing offers an existing active or arming session" {
    try std.testing.expectEqual(
        WheelRouting.offer,
        wheelRoutingDecision(routingInput(true, true, .active, false, false, true, null)),
    );
    try std.testing.expectEqual(
        WheelRouting.offer,
        wheelRoutingDecision(routingInput(true, true, .arming, false, false, true, null)),
    );
}

test "handled wheel routing consumes an existing session message" {
    try std.testing.expectEqual(
        WheelRouting.consume,
        wheelRoutingDecision(routingInput(true, true, .active, false, false, true, true)),
    );
    try std.testing.expectEqual(
        WheelRouting.consume,
        wheelRoutingDecision(routingInput(true, true, .arming, false, false, true, true)),
    );
}

test "declined wheel routing resets before one legacy delivery" {
    try std.testing.expectEqual(
        WheelRouting.reset_then_legacy,
        wheelRoutingDecision(routingInput(true, true, .active, false, false, true, false)),
    );
    try std.testing.expectEqual(
        WheelRouting.reset_then_legacy,
        wheelRoutingDecision(routingInput(true, true, .arming, false, false, true, false)),
    );
}

test "declined busy wheel routing queues reset before one legacy delivery" {
    try std.testing.expectEqual(
        WheelRouting.pending_reset_then_legacy,
        wheelRoutingDecision(routingInput(true, true, .active, false, true, true, false)),
    );
    try std.testing.expectEqual(
        WheelRouting.pending_reset_then_legacy,
        wheelRoutingDecision(routingInput(true, true, .active, false, true, true, null)),
    );
}

test "ineligible wheel routing delivers legacy input exactly once" {
    try std.testing.expectEqual(
        WheelRouting.legacy_once,
        wheelRoutingDecision(routingInput(false, true, .active, false, false, true, null)),
    );
}

test "different-window wheel never touches the session" {
    try std.testing.expectEqual(
        WheelRouting.legacy_once,
        wheelRoutingDecision(routingInput(true, false, .active, false, false, true, false)),
    );
}

test "resetting or viewport-less session delivers legacy input exactly once" {
    try std.testing.expectEqual(
        WheelRouting.legacy_once,
        wheelRoutingDecision(routingInput(true, true, .active, true, false, true, null)),
    );
    try std.testing.expectEqual(
        WheelRouting.legacy_once,
        wheelRoutingDecision(routingInput(true, true, .active, false, false, false, null)),
    );
}

test "semantic due forces Present without dirty rows" {
    try std.testing.expect(semanticPresentRequired(.{ .due_count = 1, .acked_count = 1, .rows = 0 }));
    try std.testing.expect(!semanticPresentRequired(.{}));
}

test "due unacknowledged record blocks retirement but contributes to due count" {
    const surface: types.SurfaceToken = .{ .grid_id = 3, .incarnation = 1 };
    var records: types.FixedRing(types.SemanticCommitRecord, types.MaxSemanticCommits) = .{};
    try std.testing.expect(records.push(.{ .session_generation = 1, .surface = surface, .commit_rev = 4, .rows_delta = 5, .ack_delivered = false }));
    const result = candidateRows(&records, 4, 1, surface);
    try std.testing.expectEqual(@as(usize, 1), result.due_count);
    try std.testing.expectEqual(@as(usize, 0), result.acked_count);
    try std.testing.expectEqual(@as(i64, 0), result.rows);
    try std.testing.expect(!readyToFinish(true, 0, result.due_count));
}

test "candidate publication rows require due acknowledged matching records" {
    const surface: types.SurfaceToken = .{ .grid_id = 8, .incarnation = 4 };
    var records: types.FixedRing(types.SemanticCommitRecord, types.MaxSemanticCommits) = .{};
    try std.testing.expect(records.push(.{ .session_generation = 2, .surface = surface, .commit_rev = 9, .rows_delta = 3, .ack_delivered = true }));
    try std.testing.expect(records.push(.{ .session_generation = 2, .surface = surface, .commit_rev = 10, .rows_delta = 2, .ack_delivered = false }));
    try std.testing.expect(records.push(.{ .session_generation = 3, .surface = surface, .commit_rev = 11, .rows_delta = 7, .ack_delivered = true }));
    try std.testing.expectEqual(@as(i64, 3), candidatePublishedRows(&records, 10, 2, surface));
}

test "candidate publication rows include only acked matching records at or below commit" {
    const session: types.ScrollSessionId = .{ .generation = 9, .surface = .{ .grid_id = 4, .incarnation = 2 } };
    const other_surface: types.SurfaceToken = .{ .grid_id = 5, .incarnation = 2 };
    var records: types.FixedRing(types.SemanticCommitRecord, types.MaxSemanticCommits) = .{};
    try std.testing.expect(records.push(.{ .session_generation = 9, .surface = session.surface, .commit_rev = 3, .rows_delta = 2, .ack_delivered = true }));
    try std.testing.expect(records.push(.{ .session_generation = 9, .surface = session.surface, .commit_rev = 4, .rows_delta = -1, .ack_delivered = false }));
    try std.testing.expect(records.push(.{ .session_generation = 8, .surface = session.surface, .commit_rev = 4, .rows_delta = 4, .ack_delivered = true }));
    try std.testing.expect(records.push(.{ .session_generation = 9, .surface = other_surface, .commit_rev = 4, .rows_delta = 8, .ack_delivered = true }));
    try std.testing.expect(records.push(.{ .session_generation = 9, .surface = session.surface, .commit_rev = 7, .rows_delta = 3, .ack_delivered = true }));
    try std.testing.expectEqual(@as(i64, 2), candidatePublishedRows(&records, 4, session.generation, session.surface));
    try std.testing.expectEqual(@as(i64, 5), candidatePublishedRows(&records, 7, session.generation, session.surface));
}

test "candidate publication distinguishes zero-sum due records" {
    const surface: types.SurfaceToken = .{ .grid_id = 4, .incarnation = 2 };
    var records: types.FixedRing(types.SemanticCommitRecord, types.MaxSemanticCommits) = .{};
    try std.testing.expect(records.push(.{ .session_generation = 1, .surface = surface, .commit_rev = 1, .rows_delta = 2, .ack_delivered = true }));
    try std.testing.expect(records.push(.{ .session_generation = 1, .surface = surface, .commit_rev = 2, .rows_delta = -2, .ack_delivered = true }));
    const result = candidateRows(&records, 2, 1, surface);
    try std.testing.expectEqual(@as(usize, 2), result.due_count);
    try std.testing.expectEqual(@as(usize, 2), result.acked_count);
    try std.testing.expectEqual(@as(i64, 0), result.rows);
}

test "reset request is generation and surface qualified" {
    const current: types.ScrollSessionId = .{ .generation = 7, .surface = .{ .grid_id = 4, .incarnation = 2 } };
    try std.testing.expect(resetTargetsSession(current, current));
    try std.testing.expect(!resetTargetsSession(.{ .generation = 6, .surface = current.surface }, current));
    try std.testing.expect(!resetTargetsSession(.{ .generation = 7, .surface = .{ .grid_id = 4, .incarnation = 3 } }, current));
}

test "deadline rejects zero and early stale timer deliveries" {
    try std.testing.expect(!deadlineIsDue(100, 0));
    try std.testing.expect(!deadlineIsDue(99, 100));
    try std.testing.expect(deadlineIsDue(100, 100));
    try std.testing.expect(deadlineIsDue(101, 100));
}

test "READY finish requires no outstanding credits or semantic records" {
    try std.testing.expect(!readyToFinish(false, 0, 0));
    try std.testing.expect(!readyToFinish(true, 1, 0));
    try std.testing.expect(!readyToFinish(true, 0, 1));
    try std.testing.expect(readyToFinish(true, 0, 0));
}

test "nested reset is idempotently ignored while teardown owns cleanup" {
    try std.testing.expectEqual(ResetDisposition.begin, resetDisposition(false));
    try std.testing.expectEqual(ResetDisposition.ignore, resetDisposition(true));
}
