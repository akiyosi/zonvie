import AppKit
import MetalKit

/// The session's scroll model: the sub-cell offsets, the requests in flight,
/// the gesture, the keyboard ease and the edge bounce, with every operation on
/// them.
///
/// Every surface of a session scrolls one set of grids through this one
/// store. It used to live in the main window's view, so an external window
/// reached its own scroll state through that view and could not scroll at all
/// without one. What stays with each view is what depends on its geometry:
/// which grid the pointer names, and how the offsets are laid out for its own
/// renderer.
final class SessionScrollModel {
    weak var core: ZonvieCore?

    /// The main surface's renderer. Its cell metrics are the session's, and
    /// it holds the main surface's retention and seeds.
    private var renderer: GridSurfaceRenderer? { core?.terminalView?.renderer }

    /// Keep the main surface's draw clock running: the per-frame ticks below
    /// advance from its pre-draw hook.
    private func wakeMainDrawLoop() {
        guard let view = core?.terminalView, view.isPaused else { return }
        view.activateSurfaceDrawLoop()
    }
    // --- Scroll state for smooth scrolling ---
    // Per-grid accumulated scroll offset in pixels (for sub-cell smooth scrolling)
    private var scrollOffsetPx: [Int64: CGFloat] = [:]
    /// Reused by tickSmoothScroll to collect the external surfaces' seeds
    /// without allocating on the per-frame path.
    private var externalSeedScratch: [(gridId: Int64, rowsDelta: Int)] = []
    /// Reused by collectFrameOffsets for the keys it prunes.
    private var staleKeysScratch: [Int64] = []

    // Lock protecting scrollOffsetPx from concurrent access between
    // the RPC thread (processPendingScrollClears via submitVerticesRowRaw)
    // and the main thread (handleScrollInput, updateScrollShaderOffset).
    // Lock order: scrollOffsetLock -> pendingSentScrollLock (never reversed).
    private let scrollOffsetLock = NSLock()

    // Scroll commands sent to Neovim and not yet answered. Incremented on send,
    // decremented by the rows a grid_scroll reports. It bounds how far the
    // lookahead may run and feeds the buffer-edge detection (requests that stop
    // being answered) — it is NOT proof of who scrolled: one notification can
    // carry several rows and take the count to zero mid-gesture.
    private var pendingSentScroll: [Int64: Int] = [:]
    private let pendingSentScrollLock = NSLock()

    // Windows this gesture is moving besides the one it was aimed at — the rest
    // of a 'scrollbind' group. They receive the same compensation and the same
    // finger travel, so they ease out together. Guarded by scrollOffsetLock.
    private var gestureBoundGrids: Set<Int64> = []

    // The grid whose window has our 'smoothscroll' borrowed, and whether the
    // enable request still has to be retried. Main thread only (scroll input
    // and the pre-draw tick).
    private var smoothScrollBorrowedGrid: Int64?
    private var smoothScrollBorrowPending = false
    /// Windows whose borrow was handed back but whose request the core refused.
    /// Drained by the frame tick until it accepts.
    private var smoothScrollHandback: Set<Int64> = []

    // Thread-safe scroll reconciliation queues (grid_scroll events from the Zig
    // thread), carrying the signed distance the content moved in rows.
    //
    // The event arrives while its own flush is still running, and the vertices
    // that actually move those rows are published by that flush's commit — so
    // it is staged here and released to the drain only when the commit lands
    // (renderer.onCommitPublished). Reconciling earlier moves the picture back
    // by a row for one frame and forward again the next, which is what a
    // trackpad scroll showed as judder. This mirrors how the smooth-scroll row
    // retention is published: with the vertices it belongs to, never ahead.
    private var stagedScrollClear: [(gridId: Int64, rowsDelta: Int)] = []
    private var pendingScrollClear: [(gridId: Int64, rowsDelta: Int)] = []
    private let pendingScrollClearLock = NSLock()

    // Stale scroll detection: timestamp of the first unanswered tick per grid.
    // When pendingSentScroll > 0 but no grid_scroll arrives for a while, the
    // scroll likely hit a buffer boundary (Neovim can't scroll further).
    // Time-based (not frame-counted) so multiple tick callers per frame
    // (main onPreDraw + external views) cannot distort the thresholds.
    private var scrollStaleSince: [Int64: CFAbsoluteTime] = [:]

    // --- Edge bounce (rubber-band) state ---
    // Grids whose scroll hit a buffer edge. Value is the blocked direction:
    // +1 = top edge (positive offset, "up" refused), -1 = bottom edge.
    // Protected by scrollOffsetLock. While blocked, further input toward the
    // edge gets rubber-band resistance; once the gesture and momentum end,
    // the offset eases back to 0 (bounce-back).
    private var scrollEdgeBlocked: [Int64: CGFloat] = [:]
    // Lock-free hint for the per-frame tick's early exit. May lag behind
    // removals (harmless extra lock acquisition) but inserts happen on the
    // main thread — the same thread as the tick — so it never under-reports
    // an active bounce.
    private var scrollEdgeBlockedHint = false
    // Trackpad gesture lifecycle: true while a scroll gesture is running, i.e.
    // from .began/.changed until .ended/.cancelled. Fingers merely resting
    // (.mayBegin) do NOT set it — that carries no delta and can be resolved by
    // .cancelled without one, and treating it as a gesture let a resting hand
    // claim every grid's scrolls with no expiry. Gates the bounce-back so a
    // held overscroll stays put until the fingers lift (native rubber-band
    // feel); a hand put back on the pad mid-bounce no longer freezes it.
    // Momentum does NOT gate the bounce: like the native one, it starts as
    // soon as the edge is hit and swallows the remaining momentum.
    // Written on the main thread, read on the core thread as a hint — see
    // noteScrollGesturePhase for what the lock does and does not cover.
    private var scrollGestureTouching = false
    // True while a momentum phase is running. Only used to keep momentum
    // events from refreshing lastPreciseScrollInputTime, which would gate the
    // bounce-back of unrelated grids.
    private var scrollMomentumRunning = false
    // Last precise scroll input timestamp: fallback gate for phase-less
    // precise events (devices without a gesture lifecycle).
    private var lastPreciseScrollInputTime: CFAbsoluteTime = 0
    // Grid the current gesture is driving. The three fields above describe the
    // pad, not a grid, so scroll ownership must additionally match this id: a
    // grid Neovim scrolls on its own is not the finger's just because a
    // gesture is running elsewhere. Cleared when the fingers lift so a later
    // gesture cannot inherit it; during the momentum that follows, ownership
    // rests on the in-flight count and the lookahead set until the first
    // momentum event re-establishes the id.
    private var gestureScrollGridId: Int64?
    // Grids the reconciliation already cancelled a scroll against. The seed
    // guard infers "the gesture settled this grid" from the in-flight count
    // and the lookahead set, but the reconciliation drains both on its way
    // out, so after it runs those two cannot distinguish "already paid" from
    // "never involved" — and the seed would pay the same row a second time.
    // Recorded under scrollOffsetLock, which both sites already hold.
    // Lifetime is one tickSmoothScroll, not one flush: the reconciliation also
    // drains from the core thread's vertex callbacks, so a mark can outlive
    // the commit that set it when several commits land between two draws. The
    // failure that costs is over-suppression — one row loses its ease — never
    // the double payment this exists to prevent.
    private var reconciledThisTick: Set<Int64> = []
    // Last tick timestamp: dedupes multiple tick callers in the same frame
    // and scales the bounce decay by actual elapsed time.
    private var lastScrollEdgeTickTime: CFAbsoluteTime = 0

    /// Scroll offset below this threshold (in pixels) is treated as zero and removed.
    /// Used consistently in processPendingScrollClears, updateScrollShaderOffset,
    /// and tickScrollEdgeBounce to prevent stale zero-offset entries from keeping
    /// offsets.isEmpty == false (which would trigger markAllRowsDirty every frame).
    private static let scrollOffsetEpsilon: CGFloat = 1.0
    /// Wheel events the lookahead may send for one scroll input. Also the
    /// bound `fastScrollThresholdPt` derives the discrete cut-over from.
    private static let maxLookaheadEventsPerInput = 3

    /// Stale-scroll thresholds: seconds without a grid_scroll response (while
    /// scrolls are pending) after which the scroll is considered blocked at a
    /// buffer edge. The short threshold applies when the viewport confirms the
    /// edge; the long one is the safety fallback when viewport info is missing
    /// or disagrees — a genuinely slow response mid-buffer must not be
    /// mistaken for an edge, while folds at end of buffer (which the viewport
    /// check cannot see) must still decay eventually.
    private static let scrollEdgeConfirmedSeconds: TimeInterval = 0.066
    private static let scrollEdgeFallbackSeconds: TimeInterval = 0.2

    /// Per-60fps-frame decay factor for the edge bounce-back animation,
    /// scaled by actual elapsed time in the tick. From a full overscroll this
    /// eases to epsilon in ~250ms.
    private static let scrollBounceDecayPerFrame: CGFloat = 0.75

    /// Per-60fps-frame decay factor for the keyboard sub-row ease. Neovim
    /// delivers whole rows, and the moment one lands drifts by a few ms
    /// against the frame clock, so occasionally a frame gets none and the next
    /// gets two. Holding the picture back by the scrolled distance and easing
    /// it forward turns that into fractional motion. Steady-state lag is
    /// h * d / (1 - d) — one row at 0.5, which is the price of covering the
    /// jitter without reading as an animation.
    ///
    /// `ZONVIE_SMOOTH_SCROLL_DECAY` overrides it (0 < d < 1) so the ease can be
    /// slowed until it is visible — at 0.5 it is deliberately too fast to read
    /// as motion, which makes "is it animating at all?" impossible to answer by
    /// eye. Values near 0.9 make one step take about half a second. The offset
    /// is still clamped to what the retention ring covers, so a very slow decay
    /// holds at that ceiling rather than easing from further away.
    private static let smoothScrollDecayPerFrame: CGFloat = {
        guard let raw = ProcessInfo.processInfo.environment["ZONVIE_SMOOTH_SCROLL_DECAY"],
              let d = Double(raw), d > 0, d < 1 else { return 0.5 }
        return CGFloat(d)
    }()

    /// Rows each scrolled window's content has travelled upwards, accumulated
    /// from on_grid_scroll. Paired with the renderer's per-layer placement
    /// travel to tell a float what it has actually performed.
    ///
    /// A landing hands the anchor a compensation that cancels the rows its
    /// content just moved, so the picture does not jump when the flush lands
    /// and the finger consumes the compensation instead. A float following
    /// that anchor inherits the compensation, but Neovim re-places the float
    /// through win_float_pos, which need not reach the frontend in the same
    /// commit. In the frames between, the float carries a compensation for a
    /// step it has not taken — the debt this ledger measures.
    /// Guarded by scrollOffsetLock.
    private var anchorLandedRowsUp: [Int64: Int] = [:]

    /// Grids whose scroll offset is owned by the keyboard ease (as opposed to
    /// a trackpad gesture). Guarded by scrollOffsetLock.
    private var smoothScrollGrids: Set<Int64> = []

    /// Grids whose offset is the lookahead compensation of a trackpad gesture:
    /// Neovim has already scrolled a row the finger has not travelled yet, and
    /// the offset holds the picture where the finger says it should be. The
    /// finger consumes it pixel by pixel, so it must not decay while the
    /// gesture lasts. Guarded by scrollOffsetLock.
    private var gestureLookaheadGrids: Set<Int64> = []

    /// How long after the last precise scroll event the ease keeps out of a
    /// grid's offset. Covers the gap between a gesture's last event and the
    /// grid_scroll it produced coming back through the flush.
    private static let smoothScrollGestureGuardSeconds: TimeInterval = 0.2

    /// Scratch for the per-frame seed drain; kept as a field so the tick does
    /// not allocate a dictionary every frame.
    private var seedScratch: [Int64: Int] = [:]
    private var lastSmoothScrollTickTime: CFAbsoluteTime = 0

    /// Maximum visual overscroll (rubber-band depth), in cells. Shared by the
    /// renderer clamp (clampVisualScrollOffsetPx) and the rubber-band
    /// resistance curve — they must agree or the band stops responding before
    /// (or keeps stretching past) what the renderer can display.
    private static let scrollMaxOverscrollCells: CGFloat = 2.0

    /// Shared by this view and every external grid view, like the vertical
    /// scroll state; a new gesture or a new target grid starts it empty.
    private var horizontalScroll = HorizontalScrollAccumulator()
    private var horizontalScrollGridId: Int64 = 0

    /// Send the horizontal part of a scroll input. Shared with external grid
    /// views, like handleScrollInput.
    func handleHorizontalScrollInput(
        gridId: Int64, row: Int32, col: Int32,
        deltaX: CGFloat, deltaY: CGFloat, scale: CGFloat,
        hasPrecise: Bool, modifier: String
    ) {
        guard let core, let renderer else { return }
        if gridId != horizontalScrollGridId {
            horizontalScroll = HorizontalScrollAccumulator()
            horizontalScrollGridId = gridId
        }
        // 'mousescroll' hor: columns one event moves. Paying one event per
        // that many cells keeps the text with the finger; 0 disables it.
        let colsPerEvent = core.getMouseScrollHor()
        guard colsPerEvent > 0 else { return }
        let stepPx = CGFloat(renderer.cellWidthPx) * CGFloat(colsPerEvent)
        let steps = horizontalScroll.consume(
            deltaX: deltaX, deltaY: deltaY, precise: hasPrecise, scale: scale, stepPx: stepPx)
        guard steps != 0 else { return }
        // AppKit turns Shift + a vertical mouse wheel into horizontal deltas.
        // That Shift chose the axis; passed on, it would make every notch
        // <S-ScrollWheelLeft>, a whole page.
        let axisSwapped = !hasPrecise && deltaY == 0 && modifier.contains("S")
        let sentModifier = axisSwapped ? modifier.replacingOccurrences(of: "S", with: "") : modifier
        let direction = steps > 0 ? "left" : "right"
        for _ in 0..<abs(steps) {
            core.sendMouseScroll(gridId: gridId, row: row, col: col, direction: direction, modifier: sentModifier)
        }
    }

    /// The scrollWheel body this view and every external grid view run.
    /// `resolve` names the grid under the pointer, each view in its own
    /// coordinates; `afterPrecise` is what the view does after a sub-cell
    /// scroll to keep its own frames coming.
    func handleGridScrollWheel(
        _ event: NSEvent,
        lock: inout ScrollTargetLock,
        scale: CGFloat,
        logTag: String,
        resolve: (_ requireScrollable: Bool) -> ScrollTargetLock.Target,
        afterPrecise: (_ newOffset: CGFloat) -> Void
    ) {
        noteScrollGesturePhase(event)
        lock.noteBegan(event)
        defer { lock.noteFinished(event) }
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        if deltaY == 0 && deltaX == 0 { return }

        let modifier = neovimModifierString(event.modifierFlags)

        if deltaY != 0 {
            let target = lock.target(for: event, isVertical: true, resolve: resolve)
            ZonvieCore.appLog("[\(logTag)] deltaY=\(deltaY) hasPrecise=\(event.hasPreciseScrollingDeltas) gridId=\(target.gridId) row=\(target.row) col=\(target.col)")
            let newOffset = handleScrollInput(
                gridId: target.gridId,
                row: target.row,
                col: target.col,
                deltaY: deltaY,
                scale: scale,
                hasPrecise: event.hasPreciseScrollingDeltas,
                modifier: modifier
            )
            if event.hasPreciseScrollingDeltas {
                ZonvieCore.appLog("[\(logTag)] stored offset=\(newOffset)")
                afterPrecise(newOffset)
            }
        }

        if deltaX != 0 {
            let target = lock.target(for: event, isVertical: false, resolve: resolve)
            handleHorizontalScrollInput(
                gridId: target.gridId, row: target.row, col: target.col,
                deltaX: deltaX, deltaY: deltaY, scale: scale,
                hasPrecise: event.hasPreciseScrollingDeltas, modifier: modifier)
        }
    }

    /// Track the trackpad gesture lifecycle for the edge bounce. A held
    /// overscroll must stay put while fingers are down; bounce-back starts as
    /// soon as they lift. Called from scrollWheel of this view and of external
    /// grid views (shared scroll state).
    func noteScrollGesturePhase(_ event: NSEvent) {
        if event.phase.contains(.began) { horizontalScroll = HorizontalScrollAccumulator() }
        // Written on the main thread, read on the core thread by
        // processPendingScrollClears when it decides who owns a scroll — so
        // the writes take the same lock that read is already holding.
        //
        // Only the id COMPARISONS are covered — `padIsDriving` reads the id for
        // nil-ness and the phase booleans before taking the lock at all, as
        // does tickScrollEdgeBounce for its early exit. Those reads are hints:
        // a few microseconds of staleness is nothing against the 0.2 s window
        // the terms carry (0.03 s for the edge-bounce exit), and a stale
        // Optional tag can only name a grid that was valid a moment ago.
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        let phase = event.phase
        // .mayBegin is fingers landing, not a scroll: it carries no delta and
        // may be resolved by .cancelled without one. Treating it as an active
        // gesture let a resting hand claim every grid's scrolls and hold the
        // keyboard ease off for as long as the fingers stayed down — the only
        // term here with no expiry of its own.
        if phase.contains(.began) || phase.contains(.changed) {
            scrollGestureTouching = true
        } else if phase.contains(.ended) || phase.contains(.cancelled) {
            scrollGestureTouching = false
            // Lift: drop the recent-input window so a blocked offset starts
            // its bounce-back on the very next tick.
            lastPreciseScrollInputTime = 0
            // The gesture is over, so it no longer speaks for any grid: a
            // later gesture on a different grid must not inherit this id.
            // The momentum that follows still owns whatever it has in flight
            // through the in-flight count and the lookahead set, and its first
            // event re-establishes the id.
            gestureScrollGridId = nil
        }
        let momentum = event.momentumPhase
        if momentum.contains(.began) || momentum.contains(.changed) {
            scrollMomentumRunning = true
        } else if momentum.contains(.ended) || momentum.contains(.cancelled) {
            scrollMomentumRunning = false
        }
    }

    // MARK: - Public Scroll API (for external windows)

    /// Tell the renderer which rows of each visible grid its smooth scroll may
    /// retain an outgoing row from. A vertical split or a float always fails
    /// the core's row-scroll fast path (partial width), so the grid_scroll
    /// capture is the only thing that can keep their outgoing row alive. A
    /// full-width grid normally belongs to the fast path, but that path only
    /// sees rows that actually shifted — a 'smoothscroll' window repaints
    /// instead — so it is armed as well, and the fast path stands down for a
    /// grid this one already retained.
    ///
    /// Note the spans are never disarmed in practice (see
    /// clearAllScrollOffsets), so one gesture arms every grid for the session.
    private func armScrollRetention(gridId: Int64) {
        guard GridSurfaceRenderer.smoothScrollEnabled, let core, let renderer else { return }
        // The band a wheel event opens is as wide as the rows it moves, so the
        // retention has to keep that many to cover it.
        renderer.setRetentionDepthRows(core.getMouseScrollVer())
        let grids = core.getVisibleGridsCached()
        // 'scrollbind' (:vert diffsplit) answers one gesture by scrolling every
        // bound window, and each of them opens a band of its own. Arming only
        // the window under the finger left the others with nothing to fill
        // theirs. Which ones move is Neovim's decision and is not known until
        // the scrolls arrive, so every visible grid is armed and the ones that
        // do not move simply never capture.
        // Grid 1 is not a window: its span would take in the tabline and status
        // rows, and a retained row from there is content that never scrolled.
        for candidate in grids where candidate.gridId != gridId && candidate.gridId != 1 {
            armScrollRetentionSpan(for: candidate, grids: grids)
        }
        guard let info = grids.first(where: { $0.gridId == gridId }) else { return }

        armScrollRetentionSpan(for: info, grids: grids)
    }

    /// The rows one grid's smooth scroll may retain an outgoing row from.
    private func armScrollRetentionSpan(for info: ZonvieCore.GridInfo, grids: [ZonvieCore.GridInfo]) {
        // A grid an external window draws, as its root or as a layer, keeps its
        // rows in that window's surface, so the span is armed there. Spans are
        // grid-local either way.
        switch core?.resolveExternalGridRoute(gridId: info.gridId) {
        case .externalRoot(let view), .externalLayer(let view):
            view.setScrollCaptureBounds(
                gridId: info.gridId,
                top: Int(info.marginTop),
                bottomEx: Int(info.rows - info.marginBottom)
            )
            return
        case .deferred:
            return
        default:
            break
        }

        // Armed for full-width windows too, which used to be left to the
        // row-scroll fast path alone. That path only sees rows that actually
        // shifted, so when Neovim repaints a 'smoothscroll' window instead of
        // scrolling it, nothing was staged and the band opened with no rows to
        // fill it. The fast path now stands down for a grid this one already
        // retained, so the two cannot stage the same movement twice.
        // Grid-local rows, like the external case above: each grid keeps its
        // own row buffers, so a span in surface rows would index the wrong set.
        renderer?.setGridScrollCaptureBounds(
            gridId: info.gridId,
            bounds: (
                top: Int(info.marginTop),
                bottomEx: Int(info.rows - info.marginBottom)
            )
        )
    }

    func handleScrollInput(
        gridId: Int64,
        row: Int32,
        col: Int32,
        deltaY: CGFloat,
        scale: CGFloat,
        hasPrecise: Bool,
        modifier: String = ""
    ) -> CGFloat {
        guard let core, let renderer else { return 0 }

        let rowHeightPx = CGFloat(renderer.cellHeightPx)
        guard rowHeightPx > 0 else { return 0 }

        // grid=1 (global grid) does not support pixel-based smooth scrolling
        // gridId < 0 means Zonvie-managed external windows (ext_messages, ext_cmdline)
        // which don't receive grid_scroll events from Neovim
        var effectiveHasPrecise = hasPrecise && gridId > 1

        // Disable pixel scrolling for terminal UI tools (lazygit, tig, etc.)
        // Detection: terminal mode + cursor not visible (busy)
        // When a terminal UI tool is running, the cursor is typically hidden (busy_start).
        if effectiveHasPrecise {
            let (mode, cursorVisible) = core.getModeStateNonBlocking()
            if mode == "terminal" && !cursorVisible {
                effectiveHasPrecise = false
            }
        }

        // How many rows one wheel event is worth ('mousescroll' ver). The
        // sub-cell model asks Neovim for rows before the finger has travelled
        // them and cancels each arrival against the pixel offset it holds, so
        // an event has to be accounted as the N rows it really moves. Assuming
        // one made a fast gesture jump the other N-1 per event.
        // 'ver:0' disables mouse scrolling in Neovim, so there is nothing to
        // account with and pixel scrolling is not attempted at all.
        let rowsPerWheelEvent = core.getMouseScrollVer()
        if rowsPerWheelEvent < 1 {
            effectiveHasPrecise = false
        }

        // Instant edge detection from the (non-blocking) viewport cache:
        // engage the rubber band on the first overscroll pixel instead of
        // waiting for the stale-frame fallback. Checked before the fast-scroll
        // switch — a hard flick at the edge must stretch the band, not switch
        // to discrete mode (whose scrolls the edge would refuse anyway).
        // nil = viewport unavailable (no info, or lock busy with empty cache).
        let edgeBlockedNow: Bool? = effectiveHasPrecise
            ? isScrollBlockedAtEdge(gridId: gridId, deltaY: deltaY)
            : nil

        // Disable pixel scrolling for fast scrolling to prevent overwhelming Neovim
        // If deltaY is large (fast scroll), switch to cell-based scrolling
        if effectiveHasPrecise && edgeBlockedNow != true {
            // What the lookahead below can request in one input (see its
            // `scrollCount < Self.maxLookaheadEventsPerInput`); the rule and
            // its reasons are on the function.
            let fastScrollThreshold = CGFloat(fastScrollThresholdPt(
                rowHeightPx: Double(rowHeightPx),
                rowsPerWheelEvent: rowsPerWheelEvent,
                maxEventsPerInput: Self.maxLookaheadEventsPerInput,
                scale: Double(scale)
            ))
            if abs(deltaY) > fastScrollThreshold {
                effectiveHasPrecise = false
                // Clear any accumulated offset when switching to fast mode,
                // and hand ownership of this grid back with it. The discrete
                // path below books nothing, so every scroll it sends comes
                // back with sentCount == 0 — but while the fingers are still
                // down, gestureScrollGridId and gestureLookaheadGrids keep
                // answering "the gesture owns this grid", and
                // processPendingScrollClears then credits the arrival's whole
                // distance to the offset. Nothing consumes that, so the
                // picture carries up to a clamp's worth of displacement for
                // the body of every fast flick (26% of reconciliations in a
                // real trackpad log arrived this way). Discrete scrolling asks
                // for whole rows and wants no sub-cell compensation, so those
                // arrivals belong in the Neovim-initiated branch, which clears
                // the offset. A later slow event re-establishes ownership.
                scrollOffsetLock.lock()
                scrollOffsetPx.removeValue(forKey: gridId)
                scrollStaleSince.removeValue(forKey: gridId)
                scrollEdgeBlocked.removeValue(forKey: gridId)
                gestureLookaheadGrids.remove(gridId)
                if gestureScrollGridId == gridId {
                    gestureScrollGridId = nil
                    // The bound windows belonged to that gesture. Left behind,
                    // they would hold a compensation nothing pays down.
                    for bound in gestureBoundGrids {
                        scrollOffsetPx.removeValue(forKey: bound)
                        gestureLookaheadGrids.remove(bound)
                    }
                    gestureBoundGrids.removeAll(keepingCapacity: true)
                }
                scrollOffsetLock.unlock()
                pendingSentScrollLock.lock()
                pendingSentScroll.removeValue(forKey: gridId)
                pendingSentScrollLock.unlock()
            }
        }

        if effectiveHasPrecise {
            // Arm the outgoing-row retention before any scroll request goes
            // out: Neovim's grid_scroll can come back within a millisecond,
            // ahead of the next frame, so the geometry cannot be picked up
            // from the pre-draw pass. Takes the renderer lock, so it must
            // stay outside scrollOffsetLock (the order the rest of this file
            // keeps).
            armScrollRetention(gridId: gridId)

            // Trackpad: implement sub-cell smooth scrolling for external grids
            let deltaYPx = deltaY * scale

            // Borrow 'smoothscroll' BEFORE any wheel event goes out. Both travel
            // the same ordered RPC channel, so a request sent afterwards leaves
            // the gesture's first event to be processed under the old quantum:
            // on a 'wrap'ped line that moves four or five screen rows against a
            // booking of three, and the difference is visible as a row-sized
            // jolt at exactly the moment a gesture starts. Measured — every
            // gesture's first grid_scroll arrived before the borrow landed.
            //
            // Taken before scrollOffsetLock: the core call acquires the grid
            // lock, and nothing else here nests those two.
            requestGestureSmoothScroll(gridId: gridId)

            // Read pending scroll count OUTSIDE scrollOffsetLock to avoid deadlock
            pendingSentScrollLock.lock()
            let alreadyPending = pendingSentScroll[gridId] ?? 0
            pendingSentScrollLock.unlock()

            // Counted in ROWS, not events: one event answers for
            // rowsPerWheelEvent of them, and what the lookahead has to know is
            // the distance already asked for. The backpressure cap is scaled
            // to match so it still admits the same eight events it always did
            // — as a row count it would otherwise throttle a fast gesture the
            // moment 'mousescroll' was above one.
            let maxTotalPending = 8 * rowsPerWheelEvent
            let canSendMore = alreadyPending < maxTotalPending
            let stepPx = rowHeightPx * CGFloat(rowsPerWheelEvent)

            // Hold scrollOffsetLock for entire read-modify-write (TOCTOU fix).
            // processPendingScrollClears also acquires this lock, but it runs on the
            // core thread during flush, not concurrently with main-thread scroll input.
            scrollOffsetLock.lock()
            let currentOffset = scrollOffsetPx[gridId] ?? 0
            if let edgeBlockedNow {
                let sign: CGFloat = deltaYPx > 0 ? 1 : -1
                if edgeBlockedNow {
                    // Viewport says this direction is refused — mark the edge
                    // immediately. The stale-time path in tickScrollEdgeBounce
                    // remains as fallback when viewport info is missing or
                    // inexact (e.g. folds at end of buffer).
                    if currentOffset * sign >= 0 {
                        scrollEdgeBlocked[gridId] = sign
                        scrollEdgeBlockedHint = true
                    }
                } else if scrollEdgeBlocked[gridId] == sign {
                    // Fresh viewport disproves the block in this direction —
                    // a false positive from the stale-time fallback or from a
                    // stale lock-busy cache. Unblock so scrolling resumes.
                    scrollEdgeBlocked.removeValue(forKey: gridId)
                }
            }
            let blockedSign = scrollEdgeBlocked[gridId] ?? 0
            let pushingIntoEdge = blockedSign != 0
                && deltaYPx * blockedSign > 0
                && currentOffset * blockedSign >= 0

            var newOffset: CGFloat
            var scrollCount = 0
            var sendUp = false
            if pushingIntoEdge {
                // Pushing into a blocked edge: apply rubber-band resistance
                // (response fades quadratically toward the visual clamp) and
                // send no scroll commands — the edge refuses them. Fingers
                // refresh the recent-input window so the band holds while
                // touched; momentum does not, so the bounce-back decays the
                // band concurrently and swallows the remaining momentum,
                // like the native rubber band.
                let maxOverscrollPx = rowHeightPx * Self.scrollMaxOverscrollCells
                let frac = min(1.0, abs(currentOffset) / maxOverscrollPx)
                newOffset = currentOffset + deltaYPx * (1.0 - frac) * (1.0 - frac)
                if scrollGestureTouching {
                    lastPreciseScrollInputTime = CFAbsoluteTimeGetCurrent()
                }
            } else {
                // Momentum events must not refresh the recent-input window:
                // it would gate the bounce-back of unrelated grids.
                if !scrollMomentumRunning {
                    lastPreciseScrollInputTime = CFAbsoluteTimeGetCurrent()
                }
                var canSendNow = canSendMore
                if blockedSign != 0 {
                    // Reversing away from a blocked edge.
                    scrollEdgeBlocked.removeValue(forKey: gridId)
                    // Drop pending scrolls only when provably dead (no response
                    // for scrollEdgeFallbackSeconds). A viewport-detected block
                    // can still have live in-flight scrolls from the approach;
                    // their grid_scroll responses must stay accounted for.
                    if let since = scrollStaleSince[gridId],
                       CFAbsoluteTimeGetCurrent() - since >= Self.scrollEdgeFallbackSeconds {
                        scrollStaleSince.removeValue(forKey: gridId)
                        pendingSentScrollLock.lock()
                        pendingSentScroll.removeValue(forKey: gridId)
                        pendingSentScrollLock.unlock()
                        canSendNow = true
                    }
                }

                newOffset = currentOffset + deltaYPx

                // Keep Neovim one row ahead of the finger rather than asking for
                // a row only once the finger has travelled a whole one. The row
                // that comes back is cancelled against the distance grid_scroll
                // reports (processPendingScrollClears), so the picture does not
                // move when it lands; the finger then consumes that
                // compensation pixel by pixel and the row appears exactly as it
                // is crossed. Asking at the threshold instead leaves the
                // crossing racing an asynchronous commit, which is what a
                // trackpad scroll showed as judder.
                //
                // The offset is not consumed here either way: what the picture
                // owes is settled against content that actually arrived.
                let sendDirection: CGFloat = deltaYPx > 0 ? 1 : -1
                // A row already asked for but not yet landed is already ahead.
                var lookaheadPx = newOffset - sendDirection * rowHeightPx * CGFloat(alreadyPending)
                // Counted here, sent after the lock: the send is an RPC
                // write the core treats as potentially blocking, and the core
                // thread takes this lock under grid_mu.
                while lookaheadPx * sendDirection > 0 && canSendNow && scrollCount < Self.maxLookaheadEventsPerInput {
                    scrollCount += 1
                    lookaheadPx -= sendDirection * stepPx
                }
                if scrollCount > 0 { sendUp = sendDirection > 0 }
            }

            // Clamp stored offset to the same visual range the renderer can display.
            // Keeping state and presentation aligned avoids input/render divergence
            // during sustained trackpad scrolling.
            newOffset = clampVisualScrollOffsetPx(newOffset, cellHeightPx: rowHeightPx)

            // Store final offset (atomic with read above — no TOCTOU gap).
            // Note: the stale counter is NOT reset on input — it must keep
            // ticking during a held gesture so tickScrollEdgeBounce can detect
            // a blocked edge. Bounce-back is gated on gesture/momentum state
            // instead, so it never fights active user input.
            scrollOffsetPx[gridId] = newOffset
            // A bound window ('scrollbind') is given the same compensation when
            // its scroll lands, but the finger only ever paid down the grid it
            // was aimed at — so that compensation sat at a full step and the
            // window stayed displaced instead of easing back. The finger's
            // travel is the only thing that consumes an offset, so it has to
            // reach every window this gesture is moving.
            //
            // Only a window that is still holding compensation. A bound window
            // that has settled on the cell grid drops its entry and is skipped
            // until its next arrival re-creates it — and that arrival is the
            // proof it is still moving. Paying a window with no entry instead
            // meant one that had stopped being scrolled at all (its own buffer
            // edge, or the gesture pushing into the driver's) accumulated the
            // finger's travel with nothing to credit it back, and no decay
            // path reaches it: it stays displaced until Neovim next scrolls it.
            //
            // Clamped like the driver above all the same, so a window whose
            // arrivals stop mid-gesture cannot bank travel it will never be
            // credited for and then ignore a reversed finger.
            for bound in gestureBoundGrids where bound != gridId {
                guard let held = scrollOffsetPx[bound] else { continue }
                let paid = clampVisualScrollOffsetPx(
                    held + deltaYPx,
                    cellHeightPx: rowHeightPx
                )
                if abs(paid) < Self.scrollOffsetEpsilon {
                    scrollOffsetPx.removeValue(forKey: bound)
                    gestureLookaheadGrids.remove(bound)
                } else {
                    scrollOffsetPx[bound] = paid
                }
            }
            // This is the grid the pad is driving; gesture ownership of an
            // incoming grid_scroll is decided against it.
            gestureScrollGridId = gridId
            scrollOffsetLock.unlock()

            for _ in 0..<scrollCount {
                core.sendMouseScroll(
                    gridId: gridId,
                    row: row,
                    col: col,
                    direction: sendUp ? "up" : "down",
                    modifier: modifier
                )
            }

            if FrameTracer.enabled {
                var packed = UInt64(min(scrollCount, 255))
                packed |= UInt64(min(alreadyPending, 255)) << 8
                if blockedSign != 0 { packed |= 1 << 16 }
                if pushingIntoEdge { packed |= 1 << 17 }
                FrameTracer.trace(
                    .gestureScrollInput,
                    a: UInt64(bitPattern: Int64(round(deltaYPx * 1000))),
                    b: packed,
                    seq: UInt32(truncatingIfNeeded: gridId)
                )
            }

            // Track how many scroll commands we sent (outside scrollOffsetLock)
            if scrollCount > 0 {
                pendingSentScrollLock.lock()
                pendingSentScroll[gridId, default: 0] += scrollCount * rowsPerWheelEvent
                pendingSentScrollLock.unlock()
            }

            // Keep the draw clock running while scrolls are in flight or a
            // sub-cell offset is showing: edge detection and bounce-back
            // advance on draw ticks, and at a buffer edge Neovim sends no
            // flushes, so flush-driven activation never fires (a paused loop
            // would freeze the rubber band, e.g. while the finger holds still).
            if abs(newOffset) >= Self.scrollOffsetEpsilon || alreadyPending + scrollCount > 0 {
                wakeMainDrawLoop()
            }

            return newOffset
        } else {
            // Mouse wheel / fast scroll: send directly with acceleration
            let direction = deltaY > 0 ? "up" : "down"

            // The acceleration is measured in ROWS of finger travel, but one
            // wheel event moves 'mousescroll' ver of them — sending one event
            // per row runs the content ahead of the finger by exactly that
            // factor, which is what made a fast flick overshoot. A discrete
            // wheel notch still sends one event: its travel is under a row, so
            // the division never reduces it below the floor of one.
            // 'ver:0' disables mouse scrolling in Neovim, so there is no row
            // count to divide by; the events it sends are ignored anyway.
            let deltaYPx = abs(deltaY) * scale
            let rowsTravelled = Int(deltaYPx / rowHeightPx)
            let scrollCount = rowsPerWheelEvent > 0
                ? max(1, rowsTravelled / rowsPerWheelEvent)
                : 1

            for _ in 0..<scrollCount {
                core.sendMouseScroll(gridId: gridId, row: row, col: col, direction: direction, modifier: modifier)
            }
            return 0
        }
    }

    /// Direction-specific buffer-edge check from the non-blocking viewport
    /// cache. deltaY > 0 scrolls "up" (blocked at the buffer top); negative
    /// scrolls "down" (blocked once the last line reached the window top,
    /// which is where Neovim stops). Returns nil when viewport info is
    /// unavailable — the stale-time fallback in tickScrollEdgeBounce covers
    /// that case.
    private func isScrollBlockedAtEdge(gridId: Int64, deltaY: CGFloat) -> Bool? {
        guard let vp = core?.getViewportNonBlocking(gridId: gridId), vp.lineCount > 0 else {
            return nil
        }
        if deltaY > 0 { return vp.topline <= 0 }
        return vp.topline >= vp.lineCount - 1
    }

    /// Drop all scroll bookkeeping for a grid (offset, edge flag, stale time,
    /// pending sends). Caller must hold scrollOffsetLock.
    private func clearScrollStateLocked(gridId: Int64) {
        scrollOffsetPx.removeValue(forKey: gridId)
        scrollEdgeBlocked.removeValue(forKey: gridId)
        scrollStaleSince.removeValue(forKey: gridId)
        pendingSentScrollLock.lock()
        pendingSentScroll.removeValue(forKey: gridId)
        pendingSentScrollLock.unlock()
    }

    /// Record how far a grid's content just moved (thread-safe, callable from
    /// any thread). Called from ZonvieCore on grid_scroll. rowsDelta is signed
    /// and already summed over the scrolls the notification stands for, so it
    /// is the distance to reconcile — the number of calls is not.
    /// Staged until the flush carrying those rows commits.
    func clearScrollOffsetForGrid(_ gridId: Int64, rowsDelta: Int) {
        guard rowsDelta != 0 else { return }
        // The reconciliation staged below hands the gesture a row of
        // compensation to ease out; retain the outgoing row now, while the
        // flush's source set still holds it, so the vacated band shows the
        // row that left instead of the edge-row background stretch (the
        // neighbouring row's highlight) on grids the row-scroll fast path
        // cannot cover.
        if GridSurfaceRenderer.smoothScrollEnabled {
            scrollOffsetLock.lock()
            let offset = scrollOffsetPx[gridId] ?? 0
            let lookahead = gestureLookaheadGrids.contains(gridId)
            scrollOffsetLock.unlock()
            pendingSentScrollLock.lock()
            let sent = pendingSentScroll[gridId] ?? 0
            pendingSentScrollLock.unlock()
            // Mirrors processPendingScrollClears' gestureOwns: only a scroll
            // whose compensation will displace the grid needs its row kept —
            // an unowned (keyboard/nvim) scroll here clears the offset, and
            // the draw path would prune the retained row unused.
            //
            // padIsDriving covers the bound windows of a 'scrollbind' group on
            // their first arrival, where none of the three terms above hold yet:
            // the offset that displaces them is installed by the reconciliation
            // this callback stages, so waiting for it would mean capturing a
            // step too late and opening their band over nothing.
            let padIsDriving = gestureScrollGridId != nil
                && gridId != 1
                && (scrollGestureTouching
                    || scrollMomentumRunning
                    || CFAbsoluteTimeGetCurrent() - lastPreciseScrollInputTime < Self.smoothScrollGestureGuardSeconds)
            if sent > 0 || lookahead || padIsDriving || abs(offset) >= Self.scrollOffsetEpsilon {
                // The route publishStagedScrollClears takes: the surface
                // that draws the grid owns its rows. Asking only whether the
                // grid IS an external window sent a float one hosts to the main
                // renderer, which does not draw it — the band that float's
                // offset opened was left to the edge stretch.
                switch core?.resolveGridRoute(gridId: gridId) {
                case .externalRoot(let view), .externalLayer(let view):
                    // An external window's rows live in its own surface, not
                    // the main composite, so the capture belongs to it. It
                    // cannot happen here: its flush bracket opens lazily on
                    // first content, which is after this callback, and opening
                    // discards anything staged before it. Hand over the
                    // distance instead and let it capture when the bracket
                    // opens — the committed set still holds the on-screen rows
                    // at that point.
                    view.noteGridScroll(gridId: gridId, rowsDelta: rowsDelta)
                case .deferred:
                    break
                default:
                    renderer?.captureRetainedRowForGridScroll(gridId: gridId, rowsDelta: rowsDelta)
                }
            }
        }
        pendingScrollClearLock.lock()
        stagedScrollClear.append((gridId: gridId, rowsDelta: rowsDelta))
        pendingScrollClearLock.unlock()
    }

    /// Release what the main surface's commit landed. Called from the renderer
    /// on the core thread with no renderer lock held.
    ///
    /// A grid an external surface draws is left staged for that surface's own
    /// commit (`publishStagedScrollClears(ownedBy:)`): its rows land there, and
    /// releasing its compensation here — a moment earlier, on the same thread
    /// — let a draw of that surface pair the credit with rows it had not been
    /// given yet, one row step early.
    func publishStagedScrollClears() {
        publishStagedScrollClears { gridId in
            switch core?.resolveGridRoute(gridId: gridId) {
            case .externalRoot, .externalLayer: return false
            default: return true
            }
        }
    }

    /// Release what `view`'s commit landed. Called under that view's lock.
    /// Returns how many entries were released.
    @discardableResult
    func publishStagedScrollClears(ownedBy view: ExternalGridView) -> Int {
        publishStagedScrollClears { gridId in
            switch core?.resolveGridRoute(gridId: gridId) {
            case .externalRoot(let owner): return owner === view
            case .externalLayer(let host): return host === view
            default: return false
            }
        }
    }

    @discardableResult
    private func publishStagedScrollClears(where owned: (Int64) -> Bool) -> Int {
        pendingScrollClearLock.lock()
        var released = 0
        if !stagedScrollClear.isEmpty {
            var kept = 0
            for entry in stagedScrollClear {
                if owned(entry.gridId) {
                    pendingScrollClear.append(entry)
                    released += 1
                } else {
                    stagedScrollClear[kept] = entry
                    kept += 1
                }
            }
            stagedScrollClear.removeLast(stagedScrollClear.count - kept)
        }
        pendingScrollClearLock.unlock()
        return released
    }

    /// Per-frame scroll edge tick. Called from onPreDraw and from external
    /// grid views; a time-based guard dedupes multiple callers per frame.
    ///
    /// Edge detection (fallback): when pendingSentScroll > 0 but no
    /// grid_scroll response arrives, the scroll may have hit a buffer edge.
    /// The viewport is consulted to confirm: a confirmed edge blocks after
    /// scrollEdgeConfirmedSeconds, while a missing or disagreeing viewport
    /// (slow response mid-buffer, folds at end of buffer) only blocks after
    /// scrollEdgeFallbackSeconds. The primary, instant detection happens in
    /// handleScrollInput from the same viewport cache.
    ///
    /// Bounce-back: once the trackpad gesture and its momentum end, blocked
    /// offsets ease back to 0 (native rubber-band feel). While the user holds
    /// the overscroll, the offset stays put.
    private func tickScrollEdgeBounce() {
        guard let renderer else { return }
        let rowHeightPx = CGFloat(renderer.cellHeightPx)
        guard rowHeightPx > 0 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastScrollEdgeTickTime >= 0.008 else { return }
        // Elapsed time in 60fps frames, for rate-independent decay.
        let elapsedFrames = min((now - lastScrollEdgeTickTime) * 60.0, 3.0)
        lastScrollEdgeTickTime = now

        pendingSentScrollLock.lock()
        let pendingSnapshot = pendingSentScroll
        pendingSentScrollLock.unlock()

        // Cheap early exit without taking scrollOffsetLock (render-path rule).
        // The hint may lag behind removals (one harmless extra pass) but
        // inserts happen on this thread, so it never under-reports.
        if pendingSnapshot.isEmpty && !scrollEdgeBlockedHint { return }

        // Input is active while fingers are down; the timestamp fallback
        // covers phase-less precise events. Momentum deliberately does not
        // count: a blocked edge bounces back immediately, swallowing the
        // remaining momentum (native rubber-band behavior).
        let inputActive = scrollGestureTouching || now - lastPreciseScrollInputTime < 0.03

        scrollOffsetLock.lock()
        defer {
            scrollEdgeBlockedHint = !scrollEdgeBlocked.isEmpty
            scrollOffsetLock.unlock()
        }

        // 1) Edge detection fallback: track time without a grid_scroll response.
        for (gridId, pendingCount) in pendingSnapshot {
            guard pendingCount > 0 else { continue }

            let since: CFAbsoluteTime
            if let existing = scrollStaleSince[gridId] {
                since = existing
            } else {
                scrollStaleSince[gridId] = now
                since = now
            }
            guard scrollEdgeBlocked[gridId] == nil else { continue }

            let currentOffset = scrollOffsetPx[gridId] ?? 0
            // Confirm with the viewport when possible. tryLock inside
            // scrollOffsetLock cannot deadlock against the core thread's
            // grid_mu -> scrollOffsetLock order because it never blocks.
            let confirmed = abs(currentOffset) >= Self.scrollOffsetEpsilon
                && isScrollBlockedAtEdge(gridId: gridId, deltaY: currentOffset) == true
            let threshold = confirmed ? Self.scrollEdgeConfirmedSeconds : Self.scrollEdgeFallbackSeconds
            guard now - since >= threshold else { continue }

            if abs(currentOffset) < Self.scrollOffsetEpsilon {
                // No visual offset to bounce — just drop the dead pending state.
                clearScrollStateLocked(gridId: gridId)
                ZonvieCore.appLog("[scrollEdge] gridId=\(gridId) cleared (offset was \(currentOffset))")
            } else {
                scrollEdgeBlocked[gridId] = currentOffset > 0 ? 1 : -1
                ZonvieCore.appLog("[scrollEdge] gridId=\(gridId) blocked at edge, offset=\(currentOffset) pending=\(pendingCount) confirmed=\(confirmed)")
            }
        }

        // 2) Bounce-back: ease blocked offsets to 0 once input has ended.
        guard !inputActive && !scrollEdgeBlocked.isEmpty else { return }
        let decay = CGFloat(pow(Double(Self.scrollBounceDecayPerFrame), elapsedFrames))
        for (gridId, _) in scrollEdgeBlocked {
            let currentOffset = scrollOffsetPx[gridId] ?? 0
            let eased = currentOffset * decay
            if abs(eased) < Self.scrollOffsetEpsilon {
                clearScrollStateLocked(gridId: gridId)
                ZonvieCore.appLog("[scrollEdge] gridId=\(gridId) bounce settled (was \(currentOffset))")
            } else {
                scrollOffsetPx[gridId] = eased
            }
        }
    }

    /// Ask Neovim to turn 'smoothscroll' on for the grid the gesture is
    /// driving. Idempotent on the Neovim side, but only sent once per gesture;
    /// a request that could not be issued is retried by the tick below.
    private func requestGestureSmoothScroll(gridId: Int64) {
        guard GridSurfaceRenderer.smoothScrollEnabled, let core else { return }
        if smoothScrollBorrowedGrid == gridId, !smoothScrollBorrowPending { return }
        // A gesture that moved to another grid hands the old one back first.
        // Queued rather than issued once: the core refuses while the grid lock
        // is busy, which is most of a flush, and this was the one hand-back
        // with nothing left holding the id afterwards. It heals on the next
        // gesture over that window either way, but "either way" can be never.
        if let previous = smoothScrollBorrowedGrid, previous != gridId {
            smoothScrollHandback.insert(previous)
        }
        smoothScrollHandback.remove(gridId)
        smoothScrollBorrowedGrid = gridId
        smoothScrollBorrowPending = !core.setGestureSmoothScroll(gridId: gridId, enable: true)
        ZonvieCore.appLog("[ss_borrow] request grid=\(gridId) pending=\(smoothScrollBorrowPending)")
    }

    /// Hand 'smoothscroll' back once the gesture and its momentum are done.
    ///
    /// Frame-driven rather than tied to the .ended phase: that phase can be
    /// missed (a cancelled gesture, a window losing focus mid-scroll), and the
    /// option is the user's, not ours to keep. Retried until the core accepts
    /// it, since the request is dropped when the grid lock is busy.
    private func tickGestureSmoothScroll() {
        // The bound windows belong to one gesture. Once it and its momentum are
        // done their offsets are decayed by tickSmoothScroll like any other, but
        // the membership must not carry into the next gesture, which may be
        // driving an entirely different window.
        if !scrollGestureTouching, !scrollMomentumRunning,
           CFAbsoluteTimeGetCurrent() - lastPreciseScrollInputTime > Self.smoothScrollGestureGuardSeconds {
            scrollOffsetLock.lock()
            gestureBoundGrids.removeAll(keepingCapacity: true)
            scrollOffsetLock.unlock()
        }
        guard let core else { return }
        for handback in smoothScrollHandback where core.setGestureSmoothScroll(gridId: handback, enable: false) {
            smoothScrollHandback.remove(handback)
        }
        guard let gridId = smoothScrollBorrowedGrid else { return }
        if smoothScrollBorrowPending {
            smoothScrollBorrowPending = !core.setGestureSmoothScroll(gridId: gridId, enable: true)
        }
        let idleFor = CFAbsoluteTimeGetCurrent() - lastPreciseScrollInputTime
        guard !scrollGestureTouching,
              !scrollMomentumRunning,
              idleFor > Self.smoothScrollGestureGuardSeconds
        else { return }
        if core.setGestureSmoothScroll(gridId: gridId, enable: false) {
            smoothScrollBorrowedGrid = nil
            smoothScrollBorrowPending = false
        }
    }

    func processPendingScrollClears() {
        pendingScrollClearLock.lock()
        let pending = pendingScrollClear
        pendingScrollClear.removeAll(keepingCapacity: true)
        pendingScrollClearLock.unlock()

        guard !pending.isEmpty else { return }

        let rowHeightPx = CGFloat(renderer?.cellHeightPx ?? 0)
        // One wheel event's worth of rows, the unit the lookahead books in and
        // therefore the most it may ever be running ahead by. Read once: it is
        // a lock-free atomic, but this loop runs per arrival.
        let rowsPerWheelEventForClamp = core?.getMouseScrollVer() ?? 1
        // Whether the pad is mid-gesture at all. The per-grid questions below
        // add who the gesture is for.
        let padIsDriving = gestureScrollGridId != nil
            && (scrollGestureTouching
                || scrollMomentumRunning
                || CFAbsoluteTimeGetCurrent() - lastPreciseScrollInputTime < Self.smoothScrollGestureGuardSeconds)

        scrollOffsetLock.lock()
        for (gridId, rowsDelta) in pending {
            // The content this window owns has now moved, and the branches
            // below hand it the compensation that cancels the move. A float
            // following this window inherits that compensation, so record the
            // distance here: until the float's own placement travels the same
            // way, it is carrying a compensation for a step it has not taken.
            anchorLandedRowsUp[gridId, default: 0] += rowsDelta

            // grid_scroll received — reset stale tracking for this grid.
            // A response also proves the grid is not blocked at a buffer edge.
            scrollStaleSince.removeValue(forKey: gridId)
            scrollEdgeBlocked.removeValue(forKey: gridId)

            // Check if this is a response to our scroll command or Neovim-initiated
            pendingSentScrollLock.lock()
            let sentCount = pendingSentScroll[gridId] ?? 0
            // A bound window may be seeded below, before the credit is taken,
            // so this is not captured until then.
            var currentOffset = scrollOffsetPx[gridId] ?? 0
            // The in-flight count is bookkeeping for how many requests are
            // outstanding, not proof of who scrolled: one notification can
            // carry several rows and take the count to zero while the gesture
            // is still going. Treating what follows as Neovim's own scroll
            // would drop the offset instead of cancelling it — a jump per
            // occurrence, which is what remained after the lookahead landed.
            // A grid still holding lookahead compensation, or one whose gesture
            // is still live, stays the gesture's.
            //
            // The pad-state terms describe the pad, not a grid, so they only
            // speak for the grid the gesture is actually driving. Without that
            // qualification a resting finger makes every scroll look like the
            // gesture's: a keyboard scroll would have a row added to its
            // offset instead of cleared, with the ease seed suppressed and
            // nothing left to decay it, and an unrelated split scrolled by
            // Neovim would pick up a phantom row of its own.
            let gestureDrivesThisGrid = gestureScrollGridId == gridId && padIsDriving
            // 'scrollbind' (:vert diffsplit) answers one wheel event by
            // scrolling every bound window, and only the window the event was
            // aimed at carries a booking. The others used to reach the
            // Neovim-initiated branch below and have their offset dropped, so
            // they stepped a row at a time while the window under the finger
            // moved by pixels.
            //
            // The tie is the BATCH, not the pad: bound windows are scrolled by
            // the same keystroke and arrive together. Asking only whether the
            // pad was busy let anything Neovim scrolled during a gesture claim
            // an offset — including grid 1, whose displacement drags the
            // tabline and status rows with it.
            let boundToThisGesture = padIsDriving
                && gridId != 1
                && gestureScrollGridId != gridId
                && pending.contains { $0.gridId == gestureScrollGridId }
            if boundToThisGesture, gestureBoundGrids.insert(gridId).inserted,
               scrollOffsetPx[gridId] == nil,
               let driving = gestureScrollGridId, let banked = scrollOffsetPx[driving] {
                // Seeded from the driver on the way in. A bound window is only
                // recognised when its first scroll shares a batch with the
                // driver's, by which time the finger has banked a round trip's
                // travel that this window was never paid — starting it from
                // zero left the two panes of a diff a fraction of a row apart
                // for the rest of the gesture.
                //
                // Into `currentOffset`, not just the dictionary: the credit
                // below is taken from this value, and writing only the map left
                // the seed to be overwritten by the credit it was supposed to
                // shift. Pinned by ScrollRetentionTests' "a seeded bound window
                // lands where the driver does".
                currentOffset = banked
                scrollOffsetPx[gridId] = banked
            }
            let gestureOwns = sentCount > 0
                || gestureLookaheadGrids.contains(gridId)
                || gestureDrivesThisGrid
                || boundToThisGesture
            if gestureOwns {
                // These rows are the lookahead the gesture asked for before the
                // finger got there.
                smoothScrollGrids.remove(gridId)
                let toConsume = min(sentCount, abs(rowsDelta))
                pendingSentScroll[gridId] = sentCount - toConsume
                pendingSentScrollLock.unlock()

                // Cancel the distance the compensation was taken out for, so
                // the picture stays where the finger left it. What is left is
                // the compensation the finger then consumes pixel by pixel —
                // the row appears as it is crossed, with no frame in which the
                // content has moved and the offset has not.
                //
                // Booked rows, not reported rows: 'mousescroll' counts buffer
                // lines while grid_scroll counts screen rows, so on a 'wrap'ped
                // buffer one wheel event books ver rows and Neovim answers with
                // every row those lines occupy — four times as many for a line
                // spanning four rows. Crediting the report would drive the
                // offset past zero and out the other side. Where nothing was
                // booked there is no better number than the report itself, and
                // the healthy case has the two equal, so this only bites where
                // the units genuinely disagree.
                let credited = ScrollRetention.creditedOffsetPx(
                    heldPx: currentOffset,
                    bookedRows: sentCount,
                    rowsDelta: rowsDelta,
                    rowHeightPx: rowHeightPx,
                    stepRows: rowsPerWheelEventForClamp,
                    // Membership alone is not enough: nothing takes a grid out
                    // of the set when it BECOMES the driver, so scrolling the
                    // other pane of a diff within the gesture guard would have
                    // handed the driver the bound rule and disabled the deepen
                    // clamp its wrapped over-reports depend on.
                    bound: gestureScrollGridId != gridId && gestureBoundGrids.contains(gridId),
                    epsilonPx: Self.scrollOffsetEpsilon
                )
                let newOffset = credited ?? 0
                if credited == nil {
                    scrollOffsetPx.removeValue(forKey: gridId)
                    gestureLookaheadGrids.remove(gridId)
                    // Settling here erases both signals the seed guard reads,
                    // so record the payment explicitly. Only this branch needs
                    // it: the else below keeps the grid in the lookahead set,
                    // which already blocks the seed. Recorded under exactly the
                    // conditions tickSmoothScroll needs to reach its clear, so
                    // a mark can never outlive the only thing that erases it.
                    if GridSurfaceRenderer.smoothScrollEnabled, rowHeightPx > 0 {
                        reconciledThisTick.insert(gridId)
                    }
                } else {
                    scrollOffsetPx[gridId] = newOffset
                    gestureLookaheadGrids.insert(gridId)
                }
                ZonvieCore.appLog("[processPendingScrollClears] gridId=\(gridId) rowsDelta=\(rowsDelta) sentCount=\(sentCount) offset=\(currentOffset) -> \(newOffset)")
                if FrameTracer.enabled {
                    FrameTracer.trace(
                        .gestureScrollClear,
                        a: UInt64(bitPattern: Int64(rowsDelta)),
                        b: UInt64(max(0, sentCount - toConsume)),
                        seq: UInt32(truncatingIfNeeded: gridId)
                    )
                }
            } else if smoothScrollGrids.contains(gridId) {
                pendingSentScrollLock.unlock()
                // The keyboard ease owns this grid's offset: it is the lag the
                // ease deliberately holds, not a stale trackpad offset, and
                // tickSmoothScroll decays it out. Clearing here would snap the
                // picture back to cell alignment every scrolled frame — this
                // function also runs on the core thread during vertex
                // submission, so it cannot see a seed the flush has not
                // committed yet.
            } else {
                pendingSentScrollLock.unlock()
                // Neovim-initiated scroll (j/k keys, etc.) - clear offset
                smoothScrollGrids.remove(gridId)
                gestureLookaheadGrids.remove(gridId)
                scrollOffsetPx.removeValue(forKey: gridId)
                ZonvieCore.appLog(
                    "[processPendingScrollClears] gridId=\(gridId) rowsDelta=\(rowsDelta) nvim-initiated, clearing offset=\(currentOffset)"
                )
            }
        }
        scrollOffsetLock.unlock()
        // Note: updateScrollShaderOffset() is called in onPreDraw, not here,
        // to avoid deadlock when this is called from Zig thread (which holds grid_mu).
    }

    /// Seed and decay the keyboard sub-row scroll ease. Seeding first and
    /// decaying second settles at one row of lag; decaying first would settle
    /// at two, which is past what the retention ring can cover.
    private func tickSmoothScroll() {
        guard GridSurfaceRenderer.smoothScrollEnabled, let renderer else { return }
        let rowHeightPx = CGFloat(renderer.cellHeightPx)
        guard rowHeightPx > 0 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsedFrames = lastSmoothScrollTickTime > 0
            ? min(max((now - lastSmoothScrollTickTime) * 60.0, 0.0), 3.0)
            : 1.0
        lastSmoothScrollTickTime = now

        // A seed exists only for a single-row step whose outgoing row was
        // retained — the shape a held key produces. Page motion and
        // non-fast-path redraws seed nothing and simply land where they land;
        // rows may still be retained for them, but with no offset to show
        // them in, the draw path prunes them unused.
        seedScratch.removeAll(keepingCapacity: true)
        for seed in renderer.takeSmoothScrollSeeds() {
            seedScratch[seed.gridId, default: 0] += seed.rowsDelta
        }
        // An external window opens its steps on its own surface, so its seeds
        // are held by its own retention. The offsets they feed are this view's
        // shared per-grid store, so they are spent here alongside the main
        // surface's rather than on a second, competing decay clock.
        externalSeedScratch.removeAll(keepingCapacity: true)
        core?.appendExternalSmoothScrollSeeds(into: &externalSeedScratch)
        for seed in externalSeedScratch {
            seedScratch[seed.gridId, default: 0] += seed.rowsDelta
        }

        // A trackpad gesture asks Neovim for a row before the finger has
        // travelled it, and the row arrives back here as an ordinary row scroll.
        // Its seed is applied the same way either way — it is what stops the
        // picture jumping when the row lands — but the gesture's compensation is
        // consumed by the finger rather than by the decay, so the two owners are
        // told apart below.
        pendingSentScrollLock.lock()
        let pendingSent = pendingSentScroll
        pendingSentScrollLock.unlock()
        let gestureActive = scrollGestureTouching
            || scrollMomentumRunning
            || now - lastPreciseScrollInputTime < Self.smoothScrollGestureGuardSeconds

        scrollOffsetLock.lock()
        let maxOffsetPx = rowHeightPx * CGFloat(renderer.retentionDepthRows)
        for (gridId, rowsDelta) in seedScratch where rowsDelta != 0 {
            // A gesture-owned grid is already square: its rows were cancelled
            // against the distance the notification reported, which exists for
            // every scroll — where a seed only exists for one the renderer
            // could retain a row for. Seeding it as well would pay twice.
            guard !gestureActive,
                  (pendingSent[gridId] ?? 0) == 0,
                  !gestureLookaheadGrids.contains(gridId),
                  !reconciledThisTick.contains(gridId) else { continue }
            // Content moved up by rowsDelta rows, so draw it that much lower
            // and let the decay below carry it up over the next few frames.
            // Not clamped here: the clamp belongs after the decay, or a frame
            // that lands two rows at once has its whole jump clipped straight
            // back onto the glass — the exact case the ease exists for.
            scrollOffsetPx[gridId] = (scrollOffsetPx[gridId] ?? 0) + CGFloat(rowsDelta) * rowHeightPx
            smoothScrollGrids.insert(gridId)
        }
        // A payment is only good against the seed published alongside it, so
        // the record lives exactly one tick. A grid marked without a seed
        // arriving (the renderer retains no row for a multi-row scroll) simply
        // clears here.
        reconciledThisTick.removeAll(keepingCapacity: true)

        // Once the gesture and its momentum are over, whatever compensation the
        // finger did not consume is handed to the ease: the row it stands for
        // has already been scrolled, so the picture animates the rest of the way
        // instead of sitting part-way into a row.
        if !gestureActive, !gestureLookaheadGrids.isEmpty {
            for gridId in gestureLookaheadGrids {
                smoothScrollGrids.insert(gridId)
            }
            gestureLookaheadGrids.removeAll(keepingCapacity: true)
        }

        if !smoothScrollGrids.isEmpty {
            let decay = CGFloat(pow(Double(Self.smoothScrollDecayPerFrame), elapsedFrames))
            for gridId in Array(smoothScrollGrids) {
                // Clamped to what the retention ring can cover: past that the
                // vacated band has no row to show.
                let decayed = (scrollOffsetPx[gridId] ?? 0) * decay
                let eased = max(-maxOffsetPx, min(maxOffsetPx, decayed))
                if abs(eased) < Self.scrollOffsetEpsilon {
                    scrollOffsetPx.removeValue(forKey: gridId)
                    smoothScrollGrids.remove(gridId)
                } else {
                    scrollOffsetPx[gridId] = eased
                }
            }
        }
        let easeActive = !smoothScrollGrids.isEmpty
        // Computed only when the tracer will consume it: the reduction allocates,
        // and this runs every eased frame.
        var tracedOffsetPx: CGFloat = 0
        if FrameTracer.enabled, easeActive {
            for gridId in smoothScrollGrids {
                tracedOffsetPx = max(tracedOffsetPx, abs(scrollOffsetPx[gridId] ?? 0))
            }
        }
        scrollOffsetLock.unlock()

        if FrameTracer.enabled {
            // The visual position is content_rows * h - offset, so smoothness
            // has to be reconstructed from the offset actually applied each
            // frame; the content row delta alone no longer shows it.
            FrameTracer.trace(
                .smoothScrollOffset,
                a: UInt64(Int64(round(tracedOffsetPx * 1000))),
                b: UInt64(Int64(round(rowHeightPx * 1000)))
            )
        }

        // The last key of a hold produces no further flushes, so the ease
        // needs the draw clock kept alive to settle.
        if easeActive {
            wakeMainDrawLoop()
        }
    }

    /// Advance the frame-driven scroll state; every surface calls this before
    /// it draws.
    func serviceFrame() {
        // Clear the offsets grid_scroll left pending before any vertices are
        // drawn, or split windows shift twice.
        processPendingScrollClears()
        // Hand 'smoothscroll' back once the gesture is over, and advance the
        // sub-row ease. Both are frame-driven and both were previously reached
        // only through the main view's onPreDraw, so a grid living in an
        // external window never eased at all -- its steps seeded an offset
        // nothing spent, and the picture jumped a whole row. Running them from
        // every surface's frame also means a paused or occluded main window
        // cannot stall an external window's animation. Calling twice in one
        // frame is harmless: the decay is wall-clock based, so the second call
        // advances it by ~0.
        tickGestureSmoothScroll()
        tickSmoothScroll()
        tickScrollEdgeBounce()
    }

    /// Whether any grid is displaced.
    var hasOffsets: Bool {
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        return !scrollOffsetPx.isEmpty
    }

    /// One frame's pass over the offsets, in one hold: forgets grids that are
    /// no longer visible, drops offsets that have settled, hands `visit` each
    /// remaining grid's clamped offset, and copies the anchor counters into
    /// `anchors`.
    func collectFrameOffsets(
        visible: Set<Int64>,
        cellHeightPx: CGFloat,
        anchors: inout [Int64: Int],
        visit: (_ gridId: Int64, _ clampedOffsetPx: CGFloat) -> Void
    ) {
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        staleKeysScratch.removeAll(keepingCapacity: true)
        for key in scrollOffsetPx.keys where !visible.contains(key) {
            staleKeysScratch.append(key)
        }
        for key in staleKeysScratch {
            scrollOffsetPx.removeValue(forKey: key)
            scrollEdgeBlocked.removeValue(forKey: key)
        }
        // A destroyed grid's ledger describes a float that no longer exists,
        // and its id is reused by the next float a scroll creates. The
        // baselines live with the surfaces that draw the floats now; only the
        // anchor counter is kept here.
        staleKeysScratch.removeAll(keepingCapacity: true)
        for key in anchorLandedRowsUp.keys where !visible.contains(key) {
            staleKeysScratch.append(key)
        }
        for key in staleKeysScratch {
            anchorLandedRowsUp.removeValue(forKey: key)
        }

        staleKeysScratch.removeAll(keepingCapacity: true)
        for (gridId, offsetPx) in scrollOffsetPx {
            let clampedOffsetPx = clampVisualScrollOffsetPx(offsetPx, cellHeightPx: cellHeightPx)
            // Skip near-zero offsets to ensure offsets.isEmpty becomes true,
            // preventing markAllRowsDirty from firing every frame. Also prune
            // the entry itself — otherwise scrollOffsetPx never becomes empty
            // for this grid, permanently disabling the idle fast path and
            // causing the caller to rebuild its offsets array every call
            // indefinitely.
            guard abs(clampedOffsetPx) >= Self.scrollOffsetEpsilon else {
                staleKeysScratch.append(gridId)
                continue
            }
            visit(gridId, clampedOffsetPx)
        }
        for key in staleKeysScratch {
            scrollOffsetPx.removeValue(forKey: key)
        }
        // The anchor counters, taken with the offsets they belong to.
        // processPendingScrollClears moves a grid's landed rows and its
        // compensation in the same iteration of the same lock; read in a
        // second acquisition, the float ledger could be handed a counter from
        // after a landing and an offset from before it, and withhold nothing
        // for a row the compensation had just gained. Measured as a 33.1px
        // step with the placement standing still.
        anchors.removeAll(keepingCapacity: true)
        for (gridId, rows) in anchorLandedRowsUp { anchors[gridId] = rows }
    }

    /// Drop every offset and edge flag. Only reached from the view's
    /// unreachable clearAllScrollOffsets.
    func clearAllOffsets() {
        scrollOffsetLock.lock()
        scrollOffsetPx.removeAll()
        scrollEdgeBlocked.removeAll()
        scrollOffsetLock.unlock()
    }

    /// Whether a trackpad gesture is compensating this grid's scrolls through
    /// the finger, in which case an arriving row owes no ease seed.
    ///
    /// Mirrors the first three terms of the grid_scroll handler's gate and
    /// deliberately drops its fourth, `abs(offset) >= epsilon`. That term means
    /// "something is displaced", which an ease in flight also satisfies — so a
    /// key struck mid-ease read as gesture-owned and its row lost the seed that
    /// would have carried it.
    func gestureOwnsScroll(gridId: Int64) -> Bool {
        pendingSentScrollLock.lock()
        let sent = pendingSentScroll[gridId] ?? 0
        pendingSentScrollLock.unlock()
        if sent > 0 { return true }
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        if gestureLookaheadGrids.contains(gridId) { return true }
        guard gestureScrollGridId != nil, gridId != 1 else { return false }
        return scrollGestureTouching
            || scrollMomentumRunning
            || CFAbsoluteTimeGetCurrent() - lastPreciseScrollInputTime < Self.smoothScrollGestureGuardSeconds
    }

    /// True while a sub-row ease is running (for the given grid, or any grid
    /// when nil). Views use this to keep their draw loop alive while the ease
    /// settles, the way `isScrollEdgeBounceActive` does for the bounce.
    func isSmoothScrollActive(gridId: Int64? = nil) -> Bool {
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        if let gridId { return smoothScrollGrids.contains(gridId) }
        return !smoothScrollGrids.isEmpty
    }

    /// True while an edge bounce is held or animating (for the given grid, or
    /// any grid when nil). Views use this to keep their draw loop alive while
    /// the bounce-back animation runs.
    func isScrollEdgeBounceActive(gridId: Int64? = nil) -> Bool {
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        if let gridId { return scrollEdgeBlocked[gridId] != nil }
        return !scrollEdgeBlocked.isEmpty
    }

    /// The clamped visual offset one grid's content is currently drawn at, in
    /// drawable pixels: displayed Y == static Y + this. An external view maps a
    /// pointer event back onto the rows the frame actually shows with it, the
    /// way hitTestGrid does for the main window.
    func visualScrollOffsetPx(gridId: Int64, cellHeightPx: CGFloat) -> CGFloat {
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        return clampVisualScrollOffsetPx(scrollOffsetPx[gridId] ?? 0, cellHeightPx: cellHeightPx)
    }

    /// Scroll offset info for one grid, for an external window's shader update.
    /// nil when the grid is gone or its offset has settled.
    func getScrollOffsetInfo(gridId: Int64, drawableHeight: Float, cellHeightPx: Float) -> GridSurfaceRenderer.ScrollOffsetInfo? {
        guard let core else { return nil }

        scrollOffsetLock.lock()
        let offsetPx = clampVisualScrollOffsetPx(scrollOffsetPx[gridId] ?? 0, cellHeightPx: CGFloat(cellHeightPx))
        scrollOffsetLock.unlock()
        // The main surface's threshold (updateScrollShaderOffset): below it an
        // offset is settled, and drawing it here kept an external surface in a
        // smooth scroll the main surface had already ended.
        if abs(offsetPx) < Self.scrollOffsetEpsilon { return nil }

        // Get grid info for margins (non-blocking)
        let grids = core.getVisibleGridsCached()
        guard let info = grids.first(where: { $0.gridId == gridId }) else { return nil }

        let ndcScale: Float = 2.0 / drawableHeight
        let gridTopPx = Float(info.startRow) * cellHeightPx
        let gridTopYNDC = 1.0 - gridTopPx * ndcScale

        return GridSurfaceRenderer.ScrollOffsetInfo(
            gridId: gridId,
            offsetYPx: Float(offsetPx),
            gridTopYNDC: gridTopYNDC,
            gridRows: info.rows,
            marginTop: info.marginTop,
            marginBottom: info.marginBottom
        )
    }

    /// The anchor's landed-rows counter. The main surface does not use this —
    /// it takes the whole map with the offsets, in one hold — but an external
    /// surface has no access to that hold and asks per layer at draw time.
    func anchorLandedRowsUpSnapshot(_ anchorGridId: Int64) -> Int {
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        return anchorLandedRowsUp[anchorGridId] ?? 0
    }

    private func clampVisualScrollOffsetPx(_ offsetPx: CGFloat, cellHeightPx: CGFloat) -> CGFloat {
        let safeCellHeightPx = max(0, cellHeightPx)
        // One wheel event hands the gesture a whole event's worth of
        // compensation to consume. Clamping below that would discard the part
        // it cannot show, and the picture would jump by exactly that much when
        // the rows land — so the ceiling has to be at least 'mousescroll' ver
        // rows, with the overscroll allowance as the floor.
        //
        // Bounded by what the retention can cover: displacing further than
        // that leaves part of the band with no retained row, and the edge
        // stretch then paints over the rows that ARE retained. A 'mousescroll'
        // past the depth loses the excess to a jump either way; taking it here
        // at least keeps the band consistent.
        let ver = min(core?.getMouseScrollVer() ?? 0, ScrollRetention.maxDepthRows)
        let cells = max(Self.scrollMaxOverscrollCells, CGFloat(ver))
        let maxOffsetPx = safeCellHeightPx * cells
        guard maxOffsetPx > 0 else { return 0 }
        return max(-maxOffsetPx, min(maxOffsetPx, offsetPx))
    }
}
