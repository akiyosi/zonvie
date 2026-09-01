import Cocoa
import CoreVideo
import MetalKit

final class MetalTerminalView: MTKView {
    var renderer: MetalTerminalRenderer!

    /// Expose drawable size without requiring MetalKit import at call site.
    var currentDrawableSize: CGSize { drawableSize }

    weak var core: ZonvieCore? {
        didSet {
            // Set up cursor blink redraw callback when core is assigned
            core?.requestRedraw = { [weak self] in
                DispatchQueue.main.async {
                    self?.setNeedsDisplay(self?.bounds ?? .zero)
                }
            }
        }
    }

    // Coalesce setNeedsDisplay to at most once per runloop tick, and union dirty rects.
    private let redrawScheduler = SurfaceRedrawScheduler()
    private var lastCursorDirtyRectPx: NSRect? = nil

    private static var dirtyLogEnabled: Bool { ZonvieCore.appLogEnabled }

    // --- IME / NSTextInputClient support ---
    // Shared composition handling: inline-extmark preedit with overlay fallback.
    private lazy var ime = IMEPreeditController(host: self)
    private var _inputContext: NSTextInputContext?

    override var inputContext: NSTextInputContext? {
        if _inputContext == nil {
            _inputContext = NSTextInputContext(client: self)
        }
        return _inputContext
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        activateDrawLoop()
        requestRedraw(nil)
    }

    // --- Scroll state for smooth scrolling ---
    // Per-grid accumulated scroll offset in pixels (for sub-cell smooth scrolling)
    private var scrollOffsetPx: [Int64: CGFloat] = [:]
    // Persistent scratch buffers for updateScrollShaderOffset, reused via
    // removeAll(keepingCapacity: true) instead of building fresh arrays
    // (compactMap/etc.) every call — this runs in the pre-draw path on
    // every scrolled frame.
    private var scrollOffsetInfoScratch: [MetalTerminalRenderer.ScrollOffsetInfo] = []
    private var scrollOffsetStaleKeysScratch: [Int64] = []
    private var gridInfoMapScratch: [Int64: ZonvieCore.GridInfo] = [:]
    private var visibleGridIdsScratch: Set<Int64> = []
    // Reused by the fixedRects collection below; updateFixedFloatRects()
    // copies elements into the renderer's own storage rather than aliasing
    // this buffer, so reusing it here doesn't force a COW detach there.
    private var fixedFloatRectsScratch: [MetalTerminalRenderer.FixedFloatRect] = []
    // Lock protecting scrollOffsetPx from concurrent access between
    // the RPC thread (processPendingScrollClears via submitVerticesRowRaw)
    // and the main thread (handleScrollInput, updateScrollShaderOffset).
    // Lock order: scrollOffsetLock -> pendingSentScrollLock (never reversed).
    private let scrollOffsetLock = NSLock()
    // Tracks whether the previous updateScrollShaderOffset call had any
    // offsets, so the idle (empty) case can skip rebuilding the
    // Dictionary/Set/array below every frame while still running the one
    // "just went empty" transition call that clears the renderer's state.
    private var hadScrollOffsetsLastCall = false

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
    /// Grids an external window reported new content for. Those vertices are
    /// committed by that window's own renderer, so this view's commit cannot
    /// time them — and it reports a content change rather than a measured
    /// scroll, so the offset is simply dropped, as it always was.
    private var pendingExternalScrollClear: [Int64] = []
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

    // --- Scrollbar ---
    private lazy var verticalScroller: NSScroller = {
        let scroller = NSScroller()
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .regular
        scroller.knobProportion = 0.2  // Initial value
        scroller.isEnabled = true
        scroller.alphaValue = 0.0  // Hidden initially
        scroller.target = self
        scroller.action = #selector(scrollerDidScroll(_:))
        return scroller
    }()
    private var scrollbarHideTimer: Timer?
    private var lastViewportTopline: Int64 = -1
    private var lastViewportLineCount: Int64 = -1
    private var lastViewportBotline: Int64 = -1
    // Scrollbar drag throttling (16ms = ~60fps)
    private static let scrollbarThrottleInterval: TimeInterval = 0.016
    private var lastScrollbarDragTime: CFAbsoluteTime = 0
    private var pendingScrollLine: Int64 = -1
    private var pendingScrollUseBottom: Bool = false
    // Page scroll knob guard: prevent updateScrollbarIfNeeded from reverting
    // the estimated knob position before viewport actually updates
    private var pageScrollTime: CFAbsoluteTime = 0
    private static let pageScrollGuardInterval: TimeInterval = 0.5

    /// Scroll offset below this threshold (in pixels) is treated as zero and removed.
    /// Used consistently in processPendingScrollClears, updateScrollShaderOffset,
    /// and tickScrollEdgeBounce to prevent stale zero-offset entries from keeping
    /// offsets.isEmpty == false (which would trigger markAllRowsDirty every frame).
    private static let scrollOffsetEpsilon: CGFloat = 1.0

    /// Upper bound on the total scroll-offset entry count (directly-scrolled
    /// windows + followed floats combined) passed to the renderer each
    /// frame. The vertex shader uses binary search, but CPU preparation and
    /// setVertexBytes'/GPU-buffer cost still grow with this count. This is
    /// comfortably above any realistic simultaneous scroll-source count.
    static let maxScrollOffsets = 128

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
    private static let smoothScrollDecayPerFrame: CGFloat = 0.5

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

    // --- Active draw loop (mirrors ExternalGridView.activateDrawLoop pattern) ---
    // During rapid updates (scrolling, typing), switch MTKView to continuous
    // vsync-driven rendering to eliminate the requestRedraw → setNeedsDisplay
    // async dispatch latency.  Revert to on-demand mode after idle frames.
    private var activeDrawIdleFrames: Int = 0
    private let activeDrawIdleThreshold = 15

    // Drives msg_show throttle / auto-hide ticks via a one-shot timer armed
    // only while the core reports a pending deadline. Replaces the former
    // always-on CVDisplayLink (see scheduleMsgTimer).
    private var msgTimer: Timer?

    private func dirtyLog(_ msg: @autoclosure () -> String) {
        if Self.dirtyLogEnabled {
            ZonvieCore.appLog(msg())
        }
    }

    // MARK: - Msg throttle timer (replaces the always-on display link)

    /// Schedule a one-shot tick at the core's next pending msg timeout.
    /// No timer is armed when the core reports no pending work (idle case),
    /// so the app does not wake the CPU while the editor is idle.
    /// Main thread only.
    func scheduleMsgTimer() {
        msgTimer?.invalidate()
        msgTimer = nil
        guard let core else { return }
        // Skip while minimized: the Zig core's grid state must not be queried
        // while the window is in the Dock, and nothing is visible anyway.
        if window?.isMiniaturized == true { return }
        let ms = core.tryNextMsgTimeoutMs()
        if ms == -2 {
            // Core's grid lock was busy (mid-flush). Do NOT treat this as
            // "nothing pending" -- an already-armed auto-hide deadline could
            // be missed. Retry shortly instead of polling every frame.
            msgTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: false) { [weak self] _ in
                self?.scheduleMsgTimer()
            }
            return
        }
        guard ms >= 0 else { return }  // -1 => nothing pending
        msgTimer = Timer.scheduledTimer(withTimeInterval: Double(max(0, ms)) / 1000.0,
                                        repeats: false) { [weak self] _ in
            guard let self else { return }
            // Re-check at fire time: the window may have been minimized after
            // the timer was armed.  The Zig core's grid state must not be
            // queried while the window is in the Dock.  Let the timer die here;
            // windowDidDeminiaturize re-arms it on restore.
            if self.window?.isMiniaturized == true { return }
            self.core?.tickMsgThrottle()
            self.scheduleMsgTimer()  // re-arm for the next deadline, if any
        }
    }

    /// Stop the msg throttle timer (e.g. while minimized). Main thread only.
    func cancelMsgTimer() {
        msgTimer?.invalidate()
        msgTimer = nil
    }


    /// Send committed text to Neovim immediately on the keyDown path.
    /// Why: a prior design buffered repeats in a single-slot `pendingInput`
    /// flushed by displayLink. That added 2-8ms of pre-send latency, which
    /// gave Neovim a window to batch consecutive keystroke responses into
    /// one flush (visible as "0-row frame, then 2-row jump" stutter during
    /// held-`j` scrolling), and silently dropped extras when keys arrived
    /// faster than vsync.
    private func sendInputNow(_ text: String) {
        // Record what a fresh keyDown actually sent, so synthesized repeats
        // can replay exactly the same input (see Key Repeat Synthesis below).
        if keyRepeatCaptureActive {
            keyRepeatCapturedText = text
            keyRepeatCapturedCount += 1
        }
        core?.sendInput(text)
        // Keep the active draw loop alive so the response is drawn promptly.
        activeDrawIdleFrames = 0
    }

    // MARK: - Key Repeat Synthesis
    //
    // macOS key-repeat delivery is not metronomic: the system repeat timer
    // (and especially Karabiner-Elements' virtual-device path) can drift and
    // beat against the 60Hz display, dropping ~1 repeat/sec and producing a
    // visible scroll hitch (see tmp/ scroll-jank investigation, runs 1-8).
    // Instead of trusting the OS cadence, zonvie uses OS events only as
    // edges: the initial keyDown is processed normally and its outgoing
    // input recorded; the FIRST OS auto-repeat proves the key is repeatable
    // (this also keeps press-and-hold/accent-popup behavior intact, since
    // those keys never produce OS repeats) and hands the cadence over to a
    // synthesizer.
    //
    // EXPERIMENT (decoupled-key-repeat, tmp/project_scroll_jank_investigation
    // Run11-12): the synthesizer used to fire from the draw callback (main
    // thread), tying repeat-send timing to render-loop pacing. That couples
    // the two: a compositor-side stall in nextDrawable() (unavoidable, see
    // Run11) delays the next draw(in:) call and, with it, the next repeat
    // send, one-for-one. A dedicated CVDisplayLink (its own thread, per
    // Apple's docs) now drives send timing instead, so a render stall no
    // longer perturbs input cadence — matching how Neovide's OS-driven
    // (non-synthesized) repeats are unaffected by its own render stalls.
    // draw(in:)'s tick is kept only for the IME/focus safety-disarm check,
    // which must run on the main thread (AppKit calls).
    //
    // sendInput/sendKeyEvent's Zig-core path is safe for this concurrent
    // caller: nextMsgId() is atomic and sendRaw() already serializes through
    // write_queue_mu; only the shared key_buf escape scratch buffer needed a
    // new lock (key_buf_mu, core-side).

    /// What the initial keyDown sent to Neovim; replayed verbatim per repeat.
    private enum HeldKeyAction {
        case text(String)
        case keyEvent(mods: UInt32, characters: String?, charactersIgnoringModifiers: String?)
    }
    // Guards the fields below: written from the main thread (keyDown/keyUp,
    // takeOverKeyRepeat, disarmKeyRepeatSynthesis) and read+partially-written
    // (synthNextFire) from the display-link callback thread.
    private var keyRepeatLock = os_unfair_lock()
    private var heldKeyCode: UInt16? = nil
    private var heldKeyAction: HeldKeyAction? = nil
    private var synthRepeatActive = false
    /// Bumped by disarmKeyRepeatSynthesis. The display-link tick snapshots it
    /// under the lock and replayHeldKeyOffMain re-validates it immediately
    /// before the send, narrowing (not closing) the window in which a keyUp
    /// still lets one extra keystroke through. The send must stay OUTSIDE the
    /// lock: it reaches Core.sendRawClassified, which polls in 50ms steps
    /// while SSH auth is pending, and the main thread takes this same lock
    /// every frame in tickKeyRepeatSynthesis().
    private var keyRepeatGeneration: UInt64 = 0
    /// CLOCK_UPTIME_RAW seconds of the next synthesized fire.
    private var synthNextFire: Double = 0
    private var synthInterval: Double = 1.0 / 60.0
    // Capture window: set for the duration of a fresh keyDown's processing.
    // Main thread only (only ever read/written from the real keyDown path,
    // never from the display-link repeat path — see replayHeldKeyOffMain).
    private var keyRepeatCaptureActive = false
    private var keyRepeatCapturedText: String? = nil
    private var keyRepeatCapturedCount = 0

    private var repeatDisplayLink: CVDisplayLink? = nil
    /// Extra retain on self held while the display link may still fire;
    /// released in stopRepeatDisplayLink(). See startRepeatDisplayLink().
    private var repeatDisplayLinkContext: Unmanaged<MetalTerminalView>? = nil

    private static func uptimeNow() -> Double {
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
    }

    /// Record the held key after a fresh keyDown was processed.
    private func armHeldKey(code: UInt16, action: HeldKeyAction) {
        heldKeyCode = code
        heldKeyAction = action
    }

    private func disarmKeyRepeatSynthesis(_ reason: String) {
        os_unfair_lock_lock(&keyRepeatLock)
        let wasActive = synthRepeatActive
        synthRepeatActive = false
        keyRepeatGeneration &+= 1
        heldKeyCode = nil
        heldKeyAction = nil
        os_unfair_lock_unlock(&keyRepeatLock)
        if wasActive {
            ZonvieCore.appLogScrollMode("[keyRepeat] disarm (\(reason))")
        }
        stopRepeatDisplayLink()
    }

    /// First OS auto-repeat observed for the held key: take over the cadence.
    private func takeOverKeyRepeat() {
        // NSEvent.keyRepeatInterval mirrors the user's key-repeat setting.
        // Clamp defensively; 0 would spin and >1s is nonsense for repeats.
        let interval = max(1.0 / 120.0, min(1.0, NSEvent.keyRepeatInterval))
        os_unfair_lock_lock(&keyRepeatLock)
        synthInterval = interval
        synthRepeatActive = true
        synthNextFire = Self.uptimeNow() + interval
        let code = heldKeyCode ?? 0
        os_unfair_lock_unlock(&keyRepeatLock)
        ZonvieCore.appLogScrollMode("[keyRepeat] takeover keyCode=0x\(String(code, radix: 16)) interval_ms=\(String(format: "%.2f", interval * 1000.0))")
        // This OS repeat is replaced by an immediate synthesized one, then
        // the display link paces the rest.
        replayHeldKey()
        activateDrawLoop()
        startRepeatDisplayLink()
    }

    /// Replay on the main thread (initial takeover, and the safety path).
    private func replayHeldKey() {
        guard let code = heldKeyCode, let action = heldKeyAction else {
            disarmKeyRepeatSynthesis("no held action")
            return
        }
        switch action {
        case .text(let t):
            sendInputNow(t)
        case .keyEvent(let mods, let chars, let charsIg):
            core?.sendKeyEvent(
                keyCode: UInt32(code),
                mods: mods,
                characters: chars,
                charactersIgnoringModifiers: charsIg
            )
        }
    }

    /// Replay from the display-link callback thread. Must not touch
    /// keyRepeatCaptureActive/keyRepeatCapturedText (main-thread only; a
    /// synthesized repeat is never captured) or read AppKit state directly.
    private func replayHeldKeyOffMain(code: UInt16, action: HeldKeyAction, generation: UInt64) {
        // Last check before the send, and it must be the LAST statement before
        // it: a keyUp running disarmKeyRepeatSynthesis on the main thread any
        // time up to this point must suppress the repeat, or the user sees one
        // extra character. Checking earlier (e.g. straight after the tick's own
        // critical section) is worthless -- nothing runs in between, so it only
        // re-observes state the tick already held the lock for.
        //
        // This narrows the race to the few instructions between the unlock and
        // the send; it does not eliminate it. Closing it completely would mean
        // holding keyRepeatLock across the send, which is not acceptable: the
        // send reaches Core.sendRawClassified, which sleeps in 50ms steps while
        // SSH auth is pending (bounded only by the 60s auth timeout), and the
        // main thread takes this same lock every frame from draw(in:) via
        // tickKeyRepeatSynthesis().
        os_unfair_lock_lock(&keyRepeatLock)
        let stillArmed = synthRepeatActive && keyRepeatGeneration == generation
        os_unfair_lock_unlock(&keyRepeatLock)
        guard stillArmed else { return }
        FrameTracer.trace(.inputSend, a: UInt64(code))
        switch action {
        case .text(let t):
            core?.sendInput(t)
        case .keyEvent(let mods, let chars, let charsIg):
            core?.sendKeyEvent(
                keyCode: UInt32(code),
                mods: mods,
                characters: chars,
                charactersIgnoringModifiers: charsIg
            )
        }
        // No activeDrawIdleFrames reset here: notifyDrawIdle() already resets
        // it every frame while synthRepeatActive is set (checked on the main
        // thread from the draw loop itself), so a cross-thread async dispatch
        // from this callback would be redundant. A prior version dispatched
        // one here per repeat tick (~60/s while held).
    }

    /// Called from the display-link callback (its own thread, per Apple's
    /// CVDisplayLink docs — not main). Determines whether a repeat is due
    /// and, if so, sends it directly: this is the whole point of the
    /// experiment — a main-thread render stall (nextDrawable under
    /// compositor backpressure) must not delay this send.
    private func tickKeyRepeatSynthesisOffMain() {
        os_unfair_lock_lock(&keyRepeatLock)
        guard synthRepeatActive, let code = heldKeyCode, let action = heldKeyAction else {
            os_unfair_lock_unlock(&keyRepeatLock)
            return
        }
        let now = Self.uptimeNow()
        let interval = synthInterval
        // Mirrors the main-thread tick's half-tick tolerance, but there is no
        // single well-defined "tick period" off the render clock, so use half
        // the repeat interval itself as the tolerance window.
        guard now >= synthNextFire - interval * 0.5 else {
            os_unfair_lock_unlock(&keyRepeatLock)
            return
        }
        synthNextFire += interval
        if synthNextFire < now {
            synthNextFire = now + interval
        }
        let generation = keyRepeatGeneration
        os_unfair_lock_unlock(&keyRepeatLock)
        // replayHeldKeyOffMain re-validates `generation` immediately before the
        // send; see its comment for why the check lives there and not here, and
        // why the send stays outside the lock.
        replayHeldKeyOffMain(code: code, action: action, generation: generation)
    }

    private func startRepeatDisplayLink() {
        guard repeatDisplayLink == nil else { return }
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard status == kCVReturnSuccess, let link else {
            ZonvieCore.appLogScrollMode("[keyRepeat] CVDisplayLinkCreateWithActiveCGDisplays failed status=\(status)")
            return
        }
        // Retained (not passUnretained): the display link's callback runs on
        // its own thread and may fire at any point until CVDisplayLinkStop
        // takes effect. An unretained context would dangle if this view were
        // deallocated (e.g. its tab/window closed) while a repeat was still
        // armed — deinit had no stopRepeatDisplayLink() call, so the link
        // could keep running past the view's lifetime. The extra retain here
        // keeps self alive until stopRepeatDisplayLink() releases it below.
        let retained = Unmanaged.passRetained(self)
        repeatDisplayLinkContext = retained
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let view = Unmanaged<MetalTerminalView>.fromOpaque(ctx).takeUnretainedValue()
            view.tickKeyRepeatSynthesisOffMain()
            return kCVReturnSuccess
        }, retained.toOpaque())
        CVDisplayLinkStart(link)
        repeatDisplayLink = link
    }

    private func stopRepeatDisplayLink() {
        guard let link = repeatDisplayLink else { return }
        CVDisplayLinkStop(link)
        repeatDisplayLink = nil
        repeatDisplayLinkContext?.release()
        repeatDisplayLinkContext = nil
    }

    /// Called from the renderer's draw entry every frame (main thread).
    /// No-op unless a synthesized repeat is armed. Only the safety-disarm
    /// check remains here; send timing is driven by the display link.
    func tickKeyRepeatSynthesis() {
        os_unfair_lock_lock(&keyRepeatLock)
        let active = synthRepeatActive
        os_unfair_lock_unlock(&keyRepeatLock)
        guard active else { return }
        // Safety net: lost keyUps (Cmd-Tab etc.) and IME activation must
        // never leave a key repeating forever.
        if hasMarkedText() || window?.isKeyWindow != true {
            disarmKeyRepeatSynthesis("safety")
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == heldKeyCode {
            disarmKeyRepeatSynthesis("keyUp")
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Any modifier change invalidates the recorded input (e.g. j -> C-j).
        if heldKeyCode != nil {
            disarmKeyRepeatSynthesis("flagsChanged")
        }
        super.flagsChanged(with: event)
    }

    /// Called after actual drawing runs in MTKViewDelegate.draw(in:)
    func didDrawFrame() {
        redrawScheduler.didDrawFrame()
        dirtyLog("didDrawFrame: redrawPending reset to false")
    }

    func requestRedraw(_ rect: NSRect? = nil) {
        if ZonvieCore.appLogEnabled, let inputTrace = core?.currentInputTraceSnapshot(),
           inputTrace.seq != 0, inputTrace.sentNs != 0,
           inputTrace.lastRequestRedrawLoggedSeq != inputTrace.seq
        {
            let nowNs = zonvie_core_perf_now_ns()
            let deltaUs = max(Int64(0), (nowNs - inputTrace.sentNs) / 1_000)
            ZonvieCore.appLogPerf("[perf_input] seq=\(inputTrace.seq) stage=request_redraw delta_us=\(deltaUs)")
            core?.markInputTraceRequestRedrawLogged(seq: inputTrace.seq)
        }
        redrawScheduler.requestRedraw(rect: rect, bounds: bounds, window: window) { [weak self] redrawRect in
            guard let self else { return }
            dirtyLog("setNeedsDisplay(out): r=\(String(describing: redrawRect)) bounds=\(self.bounds) isFlipped=\(self.isFlipped) windowScale=\(self.window?.backingScaleFactor ?? -1)")
            self.setNeedsDisplay(redrawRect)
        }
    }

    // MARK: - Active Draw Loop

    /// Activate continuous vsync-driven rendering.
    /// Called from core thread (on_flush_end) — dispatches to main.
    func activateDrawLoop() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.activeDrawIdleFrames = 0
            if self.isPaused {
                ZonvieCore.appLogScrollMode("[drawloop] activate: switching to continuous rendering")
                self.isPaused = false
                self.enableSetNeedsDisplay = false
                // Kick a draw immediately. Without this, MTKView's internal
                // CADisplayLink can take up to 1-2 vsyncs to start firing
                // after isPaused flips, which lets several commits pile up
                // and produces a multi-row "jump" on the first draw of a
                // held-key scroll.
                self.setNeedsDisplay(self.bounds)
            }
        }
    }

    /// Switch back to on-demand rendering (setNeedsDisplay-driven).
    private func deactivateDrawLoop() {
        guard !isPaused else { return }
        ZonvieCore.appLogScrollMode("[drawloop] deactivate: switching to on-demand rendering (idle=\(activeDrawIdleFrames))")
        isPaused = true
        enableSetNeedsDisplay = true
    }

    /// Called from draw() early-return paths when no rendering was needed.
    func notifyDrawIdle() {
        // While a synthesized key repeat is armed, the draw loop is its clock:
        // never deactivate, even if individual frames had nothing to render
        // (e.g. holding j at the end of the buffer).
        if synthRepeatActive {
            activeDrawIdleFrames = 0
            return
        }
        // If a flush committed data recently (within ~50ms = ~3 vsync periods),
        // the "idle" frame is likely a timing race: the flush completed between
        // the draw's lock snapshot and the next vsync.  Don't count it toward
        // deactivation, so rapid scrolling doesn't trigger premature on-demand
        // switching that causes periodic stuttering.
        if renderer?.hadRecentCommit(withinNs: 50_000_000) == true {
            activeDrawIdleFrames = 0
            return
        }
        activeDrawIdleFrames += 1
        if activeDrawIdleFrames > activeDrawIdleThreshold {
            deactivateDrawLoop()
        }
    }

    /// Called from draw() when actual rendering proceeds.
    func notifyDrawActive() {
        activeDrawIdleFrames = 0
    }

    private func drawablePxRectToViewRect(_ rectPxTopOrigin: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    
        // drawable px (top-origin) -> points (top-origin)
        var r = NSRect(
            x: rectPxTopOrigin.origin.x / scale,
            y: rectPxTopOrigin.origin.y / scale,
            width: rectPxTopOrigin.size.width / scale,
            height: rectPxTopOrigin.size.height / scale
        )
    
        // Convert to NSView coordinates if the view is not flipped (bottom-left origin).
        if !isFlipped {
            r.origin.y = bounds.height - (r.origin.y + r.size.height)
        }
    
        return r.intersection(bounds)
    }
    
    private func requestRedrawDrawablePx(_ rectPxTopOrigin: NSRect) {
        let vr = drawablePxRectToViewRect(rectPxTopOrigin)
        if vr.isNull || vr.isEmpty { return }
        requestRedraw(vr)
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: dev)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if self.device == nil { self.device = MTLCreateSystemDefaultDevice() }
        commonInit()
    }

    private func commonInit() {
        FrameTracer.installDumpHandler()
        guard self.device != nil else {
            ZonvieCore.appLog("[View] Failed to create MTLDevice - Metal not available")
            return
        }

        // On-demand draw. Render only when new data arrives.
        autoResizeDrawable = false
        colorPixelFormat = .bgra8Unorm
        // Drawable is render-target-only across the renderer: copy / cursor /
        // custom-shader passes use it as colorAttachment, never as a sampled
        // texture or blit source. Keeping this true lets Apple Silicon apply
        // lossless framebuffer compression, reducing GPU memory bandwidth and
        // easing contention with WindowServer's blur compositor.
        framebufferOnly = true

        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60

        // Safe initial drawable size.
        drawableSize = CGSize(width: 1, height: 1)

        guard let newRenderer = MetalTerminalRenderer(view: self) else {
            ZonvieCore.appLog("[View] Failed to create MetalTerminalRenderer")
            return
        }
        renderer = newRenderer
        delegate = renderer

        renderer.onCellMetricsChanged = { [weak self] (newCellW: Float, newCellH: Float) in
            guard let self else { return }
            self.maybeResizeCoreGrid()
            // Resize external windows to match new cell metrics
            self.core?.resizeExternalWindows(cellWidthPx: CGFloat(newCellW), cellHeightPx: CGFloat(newCellH))
            // Do not request redraw here; Neovim will redraw on the next "flush" after resize.
        }

        renderer.onCommitPublished = { [weak self] in
            self?.publishStagedScrollClears()
        }

        renderer.onBeforeCommittedSnapshot = { [weak self] in
            guard let self else { return }
            self.processPendingScrollClears()
            self.updateScrollShaderOffset()
        }

        renderer.onPreDraw = { [weak self] in
            // Process pending scroll clears from grid_scroll events before rendering.
            // This ensures scroll offsets are cleared before vertices are drawn,
            // preventing double-shift glitches in split windows.
            // 'smoothscroll' reports its movement only through win_viewport, so
            // collect what grid_scroll did not describe before processing.
            self?.processPendingScrollClears()
            // Hand 'smoothscroll' back once the gesture is over. Frame-driven
            // so a missed .ended phase cannot leave the user's option flipped.
            self?.tickGestureSmoothScroll()
            // Advance the sub-row ease (seed + decay) for keyboard scrolling.
            self?.tickSmoothScroll()
            // Detect buffer-edge blocked scrolls and run the rubber-band
            // bounce-back animation once the gesture/momentum ends.
            self?.tickScrollEdgeBounce()
            // Keep the draw loop alive while an edge bounce is held/animating,
            // so the bounce-back keeps ticking after input events stop.
            if let self, self.isPaused, self.isScrollEdgeBounceActive() {
                self.activateDrawLoop()
            }
            // Update shader with current scroll offsets (safe to call here on main thread).
            self?.updateScrollShaderOffset()
            // …and fold the cursor's displacement into the shader endpoints
            // even when the call above took its idle early-out, which it does
            // whenever nothing is scrolling. The cursor still moves then.
            self?.renderer.refreshCursorShaderState()
            // Update cursor blink state for rendering
            if let core = self?.core {
                let state = core.cursorBlinkState
                self?.renderer.cursorBlinkState = state
            }
        }

        wantsLayer = true
        needsLayout = true

        // Configure layer transparency based on blur setting
        if ZonvieConfig.shared.blurEnabled {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            self.layer?.isOpaque = true
            self.layer?.backgroundColor = NSColor.black.cgColor
        }

        // The IME preedit overlay is added to this view lazily by IMEPreeditController.

        // Add vertical scrollbar
        addSubview(verticalScroller)

        // Accept file drops via drag & drop
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Cycle the input context so the system IME candidate window
        // picks up the current Light/Dark appearance.
        // Skip if the user is mid-composition to avoid breaking the IME session.
        if let ctx = _inputContext, !hasMarkedText() {
            ctx.deactivate()
            ctx.activate()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        needsLayout = true

        // Setup scrollbar based on config
        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        if !scrollbarConfig.enabled {
            verticalScroller.isHidden = true
        } else if scrollbarConfig.isAlways {
            // For "always" mode, show scrollbar immediately
            verticalScroller.isHidden = false
            verticalScroller.alphaValue = CGFloat(scrollbarConfig.opacity)
        }

        // Setup hover tracking for scrollbar (if "hover" mode is enabled)
        if scrollbarConfig.enabled && scrollbarConfig.isHover {
            setupScrollbarHoverTracking()
        }

        if window != nil {
            window?.acceptsMouseMovedEvents = true

            // Ensure layer transparency settings are applied after window is available
            if ZonvieConfig.shared.blurEnabled {
                self.layer?.isOpaque = false
                self.layer?.backgroundColor = NSColor.clear.cgColor
            } else {
                self.layer?.isOpaque = true
                self.layer?.backgroundColor = NSColor.black.cgColor
            }
        } else {
            msgTimer?.invalidate()
            msgTimer = nil
            // The view is leaving its window (tab/window closed, possibly
            // while a key is still held): disarm proactively so the
            // repeat-pacing CVDisplayLink stops and releases its extra
            // retain on self (see startRepeatDisplayLink) instead of relying
            // on deinit, which cannot run while that retain is outstanding.
            disarmKeyRepeatSynthesis("view detached from window")
        }
    }

    deinit {
        scrollbarHideTimer?.invalidate()
        scrollbarHideTimer = nil
        msgTimer?.invalidate()
        msgTimer = nil
        // Belt-and-suspenders: viewDidMoveToWindow(nil) already disarms (and
        // releases the display-link's retain on self) on the normal
        // detachment path. This covers any path that reaches deinit without
        // going through that first — a no-op if already stopped.
        stopRepeatDisplayLink()
    }

    // MARK: - Mouse Input

    /// Track which button is being held for drag events
    private var heldMouseButton: String? = nil

    /// Cache of grid info at drag start to prevent oscillation during separator dragging.
    /// When resizing splits by dragging, the grid sizes change, which would cause
    /// hitTestGrid to return different coordinates for the same pixel position.
    /// By caching the grid info at drag start, we ensure consistent coordinates.
    private struct DragGridCache {
        var gridId: Int64
        var startRow: Int32
        var startCol: Int32
    }
    private var dragGridCache: DragGridCache? = nil

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
        heldMouseButton = "left"

        // Cache grid info at drag start
        let location = convert(event.locationInWindow, from: nil)
        let (gridId, _, _) = hitTestGrid(at: location)
        if let grid = core?.getVisibleGridsCached().first(where: { $0.gridId == gridId }) {
            dragGridCache = DragGridCache(
                gridId: grid.gridId,
                startRow: grid.startRow,
                startCol: grid.startCol
            )
        }

        sendMouseEvent(button: "left", action: "press", event: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        heldMouseButton = nil
        dragGridCache = nil  // Clear drag cache on mouse up

        // Send any pending scrollbar position
        if pendingScrollLine > 0 {
            core?.scrollToLine(pendingScrollLine, useBottom: pendingScrollUseBottom)
            pendingScrollLine = -1
        }

        sendMouseEvent(button: "left", action: "release", event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        sendMouseEvent(button: "left", action: "drag", event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        heldMouseButton = "right"
        sendMouseEvent(button: "right", action: "press", event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        heldMouseButton = nil
        sendMouseEvent(button: "right", action: "release", event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        sendMouseEvent(button: "right", action: "drag", event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        let btn = otherButtonName(event.buttonNumber)
        if let btn {
            heldMouseButton = btn
            sendMouseEvent(button: btn, action: "press", event: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        let btn = otherButtonName(event.buttonNumber)
        if btn != nil {
            heldMouseButton = nil
            sendMouseEvent(button: btn!, action: "release", event: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        super.otherMouseDragged(with: event)
        let btn = otherButtonName(event.buttonNumber)
        if let btn {
            sendMouseEvent(button: btn, action: "drag", event: event)
        }
    }

    /// Map NSEvent.buttonNumber to Neovim button name for "other" mouse buttons.
    private func otherButtonName(_ buttonNumber: Int) -> String? {
        switch buttonNumber {
        case 2: return "middle"
        case 3: return "x1"
        case 4: return "x2"
        default: return nil
        }
    }

    /// Build modifier string from NSEvent modifierFlags
    func buildModifierString(from flags: NSEvent.ModifierFlags) -> String {
        var mods = ""
        if flags.contains(.shift) { mods += "S" }
        if flags.contains(.control) { mods += "C" }
        if flags.contains(.option) { mods += "A" }
        if flags.contains(.command) { mods += "D" }
        return mods
    }

    /// Send mouse event to core
    private func sendMouseEvent(button: String, action: String, event: NSEvent) {
        guard let core else { return }

        let location = convert(event.locationInWindow, from: nil)
        let modifier = buildModifierString(from: event.modifierFlags)

        // For drag events, use cached grid info to prevent oscillation during separator dragging
        if action == "drag", let cache = dragGridCache {
            // Calculate coordinates using cached grid position.
            // Use integer-rounded cell dimensions to match core grid math.
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

            guard renderer.cellWidthPx > 0 && renderer.cellHeightPx > 0 else { return }

            let cellW = max(1.0, CGFloat(Int(renderer.cellWidthPx.rounded(.toNearestOrAwayFromZero))))
            let cellH = max(1.0, CGFloat(Int(renderer.cellHeightPx.rounded(.toNearestOrAwayFromZero))))
            let drawableH = CGFloat(max(1, Int((bounds.height * scale).rounded(.toNearestOrAwayFromZero))))

            let pointPx: CGPoint
            if isFlipped {
                pointPx = CGPoint(x: location.x * scale, y: location.y * scale)
            } else {
                pointPx = CGPoint(x: location.x * scale, y: drawableH - location.y * scale)
            }

            let globalCol = Int32(pointPx.x / cellW)
            var globalRow = Int32(pointPx.y / cellH)

            // Adjust for smooth scroll offset (same logic as hitTestGrid)
            scrollOffsetLock.lock()
            let dragOffsetPx = clampVisualScrollOffsetPx(scrollOffsetPx[cache.gridId] ?? 0, cellHeightPx: cellH)
            scrollOffsetLock.unlock()
            if abs(dragOffsetPx) > 0.001 {
                let adjustedPxY = pointPx.y - CGFloat(dragOffsetPx)
                globalRow = Int32(adjustedPxY / cellH)
            }

            // Use cached startRow/startCol for consistent coordinate conversion
            let localRow = globalRow - cache.startRow
            let localCol = globalCol - cache.startCol

            core.sendMouseInput(
                button: button,
                action: action,
                modifier: modifier,
                gridId: cache.gridId,
                row: localRow,
                col: localCol
            )
        } else {
            let (gridId, row, col) = hitTestGrid(at: location)
            core.sendMouseInput(
                button: button,
                action: action,
                modifier: modifier,
                gridId: gridId,
                row: row,
                col: col
            )
        }
    }

    override func layout() {
        super.layout()
        // DEBUG: Track layout changes (window resize/snap)
        ZonvieCore.appLog("[DEBUG-LAYOUT] bounds=\(bounds) drawableSize=\(drawableSize)")
        updateDrawableSizeIfPossible()
        layoutScrollbar()
    }

    private func layoutScrollbar() {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        verticalScroller.frame = NSRect(
            x: bounds.width - scrollerWidth,
            y: 0,
            width: scrollerWidth,
            height: bounds.height
        )

        // Update hover tracking area if hover mode is enabled
        let config = ZonvieConfig.shared.scrollbar
        if config.enabled && config.isHover {
            setupScrollbarHoverTracking()
        }
    }

    private var scrollbarTrackingArea: NSTrackingArea?
    private var urlTrackingArea: NSTrackingArea?
    private var lastUrlCursorIsHand = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Re-add URL tracking area covering entire view
        if let existing = urlTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        urlTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let location = convert(event.locationInWindow, from: nil)
        let (gridId, row, col) = hitTestGrid(at: location, adjustForSmoothScroll: false)
        let hasUrl = core?.cellHasURL(gridId: gridId, row: row, col: col) ?? false
        if hasUrl != lastUrlCursorIsHand {
            lastUrlCursorIsHand = hasUrl
            if hasUrl {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func setupScrollbarHoverTracking() {
        // Remove existing tracking area if any
        if let existing = scrollbarTrackingArea {
            removeTrackingArea(existing)
        }

        // Create tracking area for right edge (scrollbar area + some margin)
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let trackingRect = NSRect(
            x: bounds.width - scrollerWidth - 30,  // 30px margin for easier hover
            y: 0,
            width: scrollerWidth + 30,
            height: bounds.height
        )

        let trackingArea = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: ["scrollbar": true]
        )
        addTrackingArea(trackingArea)
        scrollbarTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        if let userInfo = event.trackingArea?.userInfo as? [String: Bool],
           userInfo["scrollbar"] == true {
            let config = ZonvieConfig.shared.scrollbar
            if config.enabled && config.isHover {
                showScrollbar()
            }
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if let userInfo = event.trackingArea?.userInfo as? [String: Bool],
           userInfo["scrollbar"] == true {
            let config = ZonvieConfig.shared.scrollbar
            if config.enabled && config.isHover {
                hideScrollbar()
            }
        }
        super.mouseExited(with: event)
    }

    // MARK: - Scrollbar

    /// One-shot retry pending for updateScrollbarIfNeeded (main thread only).
    private var scrollbarRetryScheduled = false

    /// Update scrollbar if viewport changed
    func updateScrollbarIfNeeded() {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled else { return }
        guard let core else { return }
        var lockBusy = false
        let viewportOrStale = core.getViewportNonBlocking(gridId: -1, lockBusy: &lockBusy)
        if lockBusy, !scrollbarRetryScheduled {
            // grid_mu was held (core thread mid-handleRedraw): the value above
            // is the one-flush-stale cache. This update runs once per flush, so
            // a busy read on the FINAL flush of a scroll burst has no later
            // flush to heal it — the knob would stay at the pre-scroll position.
            // One-shot main-thread retry, mirroring windows/ui/scrollbar.zig's
            // TIMER_SCROLLBAR_RETRY (16ms ≈ one frame).
            scrollbarRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                self?.scrollbarRetryScheduled = false
                self?.updateScrollbarIfNeeded()
            }
        }
        guard let viewport = viewportOrStale else { return }

        // Check if any viewport property changed (topline, botline, lineCount)
        let viewportChanged = viewport.topline != lastViewportTopline ||
                              viewport.lineCount != lastViewportLineCount ||
                              viewport.botline != lastViewportBotline ||
                              lastViewportTopline == -1

        // After page scroll, skip knob updates until viewport actually changes.
        // This prevents the display link from reverting the estimated knob position
        // before Neovim sends updated viewport data.
        if !viewportChanged {
            let elapsed = CFAbsoluteTimeGetCurrent() - pageScrollTime
            if elapsed < Self.pageScrollGuardInterval {
                return
            }
        }

        if viewportChanged {
            pageScrollTime = 0  // Clear guard on real viewport update
            lastViewportTopline = viewport.topline
            lastViewportLineCount = viewport.lineCount
            lastViewportBotline = viewport.botline
            updateScrollbar(viewport: viewport)
            // Show scrollbar on scroll only if "scroll" or "always" mode
            if config.isScroll || config.isAlways {
                showScrollbar()
            }
        }
    }

    /// Update scrollbar position based on viewport info
    private func updateScrollbar(viewport: ZonvieCore.ViewportInfo) {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled else { return }

        let visibleLines = viewport.botline - viewport.topline
        let isScrollable = viewport.lineCount > visibleLines

        if !isScrollable {
            if config.isAlways {
                // For "always" mode, keep visible but show full-size knob
                verticalScroller.isHidden = false
                verticalScroller.doubleValue = 0
                verticalScroller.knobProportion = 1.0
            } else {
                verticalScroller.isHidden = true
            }
            return
        }

        verticalScroller.isHidden = false
        verticalScroller.doubleValue = viewport.scrollPosition
        verticalScroller.knobProportion = viewport.knobProportion
    }

    /// Show scrollbar with fade-in animation
    private func showScrollbar() {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled else { return }

        scrollbarHideTimer?.invalidate()

        let targetAlpha = CGFloat(config.opacity)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            verticalScroller.animator().alphaValue = targetAlpha
        }

        // Auto-hide after delay (only if "scroll" mode and not "always")
        if config.isScroll && !config.isAlways {
            scrollbarHideTimer = Timer.scheduledTimer(withTimeInterval: config.delay, repeats: false) { [weak self] _ in
                self?.hideScrollbar()
            }
        }
    }

    /// Hide scrollbar with fade-out animation
    private func hideScrollbar() {
        let config = ZonvieConfig.shared.scrollbar
        // Don't hide if "always" mode is enabled
        if config.isAlways { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            verticalScroller.animator().alphaValue = 0.0
        }
    }

    /// Handle scrollbar interaction
    @objc private func scrollerDidScroll(_ sender: NSScroller) {
        guard let core else { return }

        // Viewport may be nil if Neovim hasn't sent win_viewport for the cursor grid yet
        // (e.g., after window split with no content change). pageScroll doesn't need viewport.
        let viewport = core.getViewportNonBlocking(gridId: -1)

        switch sender.hitPart {
        case .decrementPage:
            // Click above knob - page up (single RPC, Neovim-native <C-b>)
            core.pageScroll(gridId: -1, forward: false)
            // Update knob position immediately (estimated) and guard against revert
            if let viewport {
                let visibleLines = viewport.botline - viewport.topline
                let upScrollRange = max(1, viewport.lineCount - visibleLines)
                let upNewTopline = max(1, viewport.topline - max(1, visibleLines - 2))
                verticalScroller.doubleValue = max(0, Double(upNewTopline - 1) / Double(upScrollRange))
            }
            pageScrollTime = CFAbsoluteTimeGetCurrent()

        case .incrementPage:
            // Click below knob - page down (single RPC, Neovim-native <C-f>)
            core.pageScroll(gridId: -1, forward: true)
            // Update knob position immediately (estimated) and guard against revert
            if let viewport {
                let visibleLines = viewport.botline - viewport.topline
                let downScrollRange = max(1, viewport.lineCount - visibleLines)
                let downNewTopline = min(viewport.lineCount - visibleLines + 1, viewport.topline + max(1, visibleLines - 2))
                verticalScroller.doubleValue = min(1.0, max(0, Double(downNewTopline - 1) / Double(downScrollRange)))
            }
            pageScrollTime = CFAbsoluteTimeGetCurrent()

        case .knob:
            // Dragging knob - jump directly to target line (requires viewport data)
            guard let viewport else { break }
            let visibleLines = viewport.botline - viewport.topline
            let scrollRatio = sender.doubleValue
            let scrollRange = max(1, viewport.lineCount - visibleLines)
            let targetLine0based = Int64(scrollRatio * Double(scrollRange))
            let targetLine1based = targetLine0based + 1  // Neovim uses 1-based line numbers

            // Use bottom alignment for second half to allow scrolling to end of file
            let useBottom = scrollRatio >= 0.5
            let targetLine: Int64 = if useBottom {
                // For bottom mode, calculate the bottom line of the viewport
                min(targetLine1based + visibleLines - 1, viewport.lineCount)
            } else {
                targetLine1based
            }

            // Store pending position for throttling
            pendingScrollLine = targetLine
            pendingScrollUseBottom = useBottom

            // Throttle: only send if enough time has passed
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastScrollbarDragTime >= Self.scrollbarThrottleInterval {
                core.scrollToLine(targetLine, useBottom: useBottom)
                lastScrollbarDragTime = now
                pendingScrollLine = -1
            }

        default:
            break
        }

        // Keep scrollbar visible while interacting
        showScrollbar()
    }

    private func updateDrawableSizeIfPossible() {
        let bw = bounds.size.width
        let bh = bounds.size.height
        guard bw.isFinite, bh.isFinite, bw > 0, bh > 0 else {
            if drawableSize.width != 1 || drawableSize.height != 1 {
                drawableSize = CGSize(width: 1, height: 1)
            }
            return
        }

        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        guard scale.isFinite, scale > 0 else { return }

        renderer.setBackingScale(scale)

        let pw = bw * scale
        let ph = bh * scale
        guard pw.isFinite, ph.isFinite, pw > 0, ph > 0 else { return }

        let w = max(1, Int(pw.rounded(.toNearestOrAwayFromZero)))
        let h = max(1, Int(ph.rounded(.toNearestOrAwayFromZero)))
        let newSize = CGSize(width: w, height: h)
        let oldSize = drawableSize
        if drawableSize != newSize {
            drawableSize = newSize
            // DEBUG: Track drawable size changes (triggers backBuffer resize)
            ZonvieCore.appLog("[DEBUG-DRAWABLE-RESIZE] oldSize=\(oldSize) newSize=\(newSize) scale=\(scale)")
        }

        maybeResizeCoreGrid()
    }

    /// One-shot retry pending for maybeResizeCoreGrid (main thread only).
    /// See its call site below: mirrors updateCursorBlinking's
    /// cursorBlinkRetryScheduled / TIMER_CURSOR_BLINK_RETRY pattern.
    private var layoutResizeRetryScheduled = false

    private func maybeResizeCoreGrid() {
        guard let core else { return }

        let cellWi = max(1, Int(renderer.cellWidthPx.rounded(.toNearestOrAwayFromZero)))
        let cellHi = max(1, Int(renderer.cellHeightPx.rounded(.toNearestOrAwayFromZero)))

        let pxWi = max(1, Int(drawableSize.width))
        let pxHi = max(1, Int(drawableSize.height))

        // Screen width in cells for cmdline max width. Must match the
        // contentWidth constraint in resizeCmdlineWindow to keep NDC viewport
        // == drawable size. Computed before the core call so it can ride the
        // same grid_mu acquisition instead of taking the lock a second time.
        // TODO: Use window?.screen instead of NSScreen.main for multi-display correctness.
        //       All cmdline NSScreen.main usage (here and in ZonvieCore.swift) should be
        //       migrated to window?.screen in a coordinated change.
        let scale = window?.backingScaleFactor ?? 2.0
        // Chrome that sits beside the cmdline grid inside its own window.
        let copyButtonPt = ZonvieConfig.shared.cmdline.copyButton ? ZonvieConfig.copyButtonTotalWidth : 0.0
        let cmdlineChromePt = ZonvieConfig.cmdlinePadding * 2 + ZonvieConfig.cmdlineIconTotalWidth + copyButtonPt

        var screenCols: UInt32 = 0
        if let screen = NSScreen.main {
            let cmdlineOverheadPt = cmdlineChromePt + ZonvieConfig.cmdlineScreenMargin
            let availableWidthPt = screen.visibleFrame.width - cmdlineOverheadPt
            let availableWidthPx = availableWidthPt * scale
            screenCols = UInt32(max(40, availableWidthPx / CGFloat(cellWi)))
        }

        // Default cmdline width: the cmdline WINDOW spans
        // cmdlineDefaultWindowFraction of the main window, so the chrome comes
        // off before converting to cells. Without this the core falls back to
        // the main grid's cols, which makes the cmdline window wider than the
        // main window by exactly the chrome.
        var cmdlineDefaultCols: UInt32 = 0
        if let mainWidthPt = window?.frame.width, mainWidthPt > 0 {
            let targetPt = mainWidthPt * ZonvieConfig.cmdlineDefaultWindowFraction - cmdlineChromePt
            let targetPx = targetPt * scale
            cmdlineDefaultCols = UInt32(max(20, targetPx / CGFloat(cellWi)))
        }

        // Move rows/cols decision + suppression to Zig core (shared logic).
        // Non-blocking: a live-resize drag calls this many times per second
        // on the main thread, and the core thread may be mid-flush holding
        // grid_mu. Blocking here would stall the whole drag on that flush;
        // instead retry once shortly (~1 frame) with then-current geometry
        // rather than dropping this layout update (it's a write, not a
        // cacheable read, so it must eventually land).
        //
        // KNOWN TRADE: the caller already committed the new drawableSize
        // above. On a busy return the core's drawable_w_px/h_px stay stale
        // until the retry lands, so the in-flight flush can publish vertices
        // whose NDC was baked for the old drawable and draw() will present
        // them into the new one -- one visibly misregistered frame per lost
        // race, where the blocking call instead stalled and was never wrong
        // on screen. Accepted because the stall it replaces was unbounded
        // (a whole flush) and the retry re-reads live geometry so it
        // converges within ~16ms. If drag-time misregistration is ever
        // reported, hold the last good frame while the core layout disagrees
        // with drawableSize rather than reverting to the blocking call.
        let acquired = core.tryUpdateLayoutPx(
            drawableW: UInt32(pxWi),
            drawableH: UInt32(pxHi),
            cellW: UInt32(cellWi),
            cellH: UInt32(cellHi),
            screenCols: screenCols,
            cmdlineDefaultCols: cmdlineDefaultCols
        )
        if !acquired, !layoutResizeRetryScheduled {
            layoutResizeRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                self?.layoutResizeRetryScheduled = false
                self?.maybeResizeCoreGrid()
            }
        }

        // Unblock the RPC thread's layout-ready wait (ui_attach_cond in
        // rpc_session.zig) once we know real
        // dimensions, so nvim_ui_attach is sent with the correct rows/cols
        // on the first try (mirrors Windows' WM_SIZE → notify_layout_ready
        // path). The Zig core treats notifyLayoutReady as idempotent, so any
        // later drawable changes go through the normal resize path —
        // meaning a transient 1×N or N×1 drawable observed during initial
        // layout would otherwise lock nvim_ui_attach to a bogus rows=1 or
        // cols=1. Require BOTH axes to exceed the placeholder size and to
        // be at least one full cell wide before signalling.
        if pxWi >= cellWi && pxHi >= cellHi {
            let cols = UInt32(max(1, pxWi / cellWi))
            let rows = UInt32(max(1, pxHi / cellHi))
            core.notifyInitialLayout(rows: rows, cols: cols)

            // Track the user's desired terminal size as the reference the main
            // window cell-snap operates on (see snapMainWindowContentToCell).
            // Update on every genuine resize — the restored frame at launch,
            // user drags, zoom, display changes — but skip the resize echo our
            // own snap setFrame produces: it matches the size the snap recorded
            // in lastSnappedTermPx. Gated on the >= 1 cell check above so the
            // transient 1×N / N×1 placeholder layout never becomes the
            // reference. Main-thread only, same as the snap.
            let curTermPt = bounds.size
            if let snapped = core.lastSnappedTermPx,
               abs(curTermPt.width - snapped.width) < 0.5,
               abs(curTermPt.height - snapped.height) < 0.5 {
                // Echo from our own snap; leave desiredTermPx untouched.
            } else {
                core.desiredTermPx = curTermPt
            }
        }

        // screenCols was applied above, inside tryUpdateLayoutPx's single
        // grid_mu acquisition (see its computation before that call).
    }

    func submitVerticesPartialRaw(
        mainPtr: UnsafeRawPointer?, mainCount: Int,
        cursorPtr: UnsafeRawPointer?, cursorCount: Int,
        updateMain: Bool,
        updateCursor: Bool
    ) {
        // Process pending scroll clears BEFORE submitting new vertices.
        // This ensures scroll offsets are cleared atomically with vertex updates,
        // preventing double-shift glitches when grid_scroll moves content.
        processPendingScrollClears()

        renderer.submitVerticesPartialRaw(
            mainPtr: mainPtr, mainCount: mainCount,
            cursorPtr: cursorPtr, cursorCount: cursorCount,
            updateMain: updateMain,
            updateCursor: updateCursor
        )

        // If nothing is updated, exit without issuing a draw request (most critical)
        if !updateMain && !updateCursor {
            return
        }

        if updateCursor {
            // cursorPtr absent / cursorCount==0 can be 'cursor erase' etc.
            // In this case, redraw only 'previous cursor region' instead of full redraw to erase it.
            if cursorCount <= 0 || cursorPtr == nil {
                if let prev = lastCursorDirtyRectPx {
                    // Mark previous cursor region as dirty to erase it
                    let cellHpx = max(1.0, CGFloat(renderer.cellHeightPx))
                    let rowStart = max(0, Int(floor(prev.minY / cellHpx)))
                    let rowEndExclusive = max(rowStart + 1, Int(ceil(prev.maxY / cellHpx)))
                    let rowCount = max(1, rowEndExclusive - rowStart)

                    renderer.markDirtyRect(rowStart: rowStart, rowCount: rowCount, rectPx: prev)



                    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
                    let rectPt = NSRect(
                        x: prev.origin.x / scale,
                        y: prev.origin.y / scale,
                        width: prev.size.width / scale,
                        height: prev.size.height / scale
                    )
                    requestRedraw(rectPt)
                }
                lastCursorDirtyRectPx = nil
                return
            }

            // From here: normal update with cursor vertices present
            if let cursorPtr {
                // Validate cursorCount to prevent buffer overrun
                guard cursorCount > 0 && cursorCount <= 1000 else {
                    // Invalid count - skip cursor processing
                    renderer.submitVerticesPartialRaw(
                        mainPtr: nil, mainCount: 0,
                        cursorPtr: nil, cursorCount: 0,
                        updateMain: false,
                        updateCursor: updateCursor
                    )
                    return
                }

                let cursor = cursorPtr.assumingMemoryBound(to: zonvie_vertex.self)

                // Compute cursor bounds in NDC, then map to drawable pixel rect (TOP-ORIGIN).
                var minX: Float =  1e9
                var maxX: Float = -1e9
                var minY: Float =  1e9
                var maxY: Float = -1e9

                for i in 0..<cursorCount {
                    let x = cursor[i].position.0
                    let y = cursor[i].position.1
                    minX = Swift.min(minX, x)
                    maxX = Swift.max(maxX, x)
                    minY = Swift.min(minY, y)
                    maxY = Swift.max(maxY, y)
                }

                let dw = CGFloat(self.drawableSize.width)
                let dh = CGFloat(self.drawableSize.height)

                // NDC (-1..1) -> drawable pixel (top-origin)
                let x0 = CGFloat((minX + 1.0) * 0.5) * dw
                let x1 = CGFloat((maxX + 1.0) * 0.5) * dw
                let y0 = CGFloat((1.0 - maxY) * 0.5) * dh
                let y1 = CGFloat((1.0 - minY) * 0.5) * dh

                let rectPx = NSRect(
                    x: floor(Swift.min(x0, x1)),
                    y: floor(Swift.min(y0, y1)),
                    width: ceil(abs(x1 - x0)),
                    height: ceil(abs(y1 - y0))
                )

                let unionRectPx: NSRect
                if let prev = lastCursorDirtyRectPx {
                    unionRectPx = prev.union(rectPx)
                } else {
                    unionRectPx = rectPx
                }
                lastCursorDirtyRectPx = rectPx

                let cellHpx = max(1.0, CGFloat(renderer.cellHeightPx))
                let rowStart = max(0, Int(floor(unionRectPx.minY / cellHpx)))
                let rowEndExclusive = max(rowStart + 1, Int(ceil(unionRectPx.maxY / cellHpx)))
                let rowCount = max(1, rowEndExclusive - rowStart)

                renderer.markDirtyRows(rowStart: rowStart, rowCount: rowCount)
                requestRedrawDrawablePx(unionRectPx)
                return
            }
        }

        // main-only update etc.: at this point updateMain should be true (updateMain/updateCursor==false already returned above)
        requestRedraw()
    }



    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int = 0, totalCols: Int = 0) {
        // Process pending scroll clears BEFORE submitting new vertices.
        processPendingScrollClears()

        renderer.submitVerticesRowRaw(rowStart: rowStart, rowCount: rowCount, ptr: ptr, count: count, flags: flags, totalRows: totalRows, totalCols: totalCols)

        let isZeroCellLayout =
            rowCount == 0
            && count == 0
            && (flags & UInt32(ZONVIE_VERT_UPDATE_MAIN)) != 0
            && (totalRows == 0 || totalCols == 0)
        if isZeroCellLayout {
            let fullDrawableRectPx = NSRect(
                x: 0,
                y: 0,
                width: CGFloat(drawableSize.width),
                height: CGFloat(drawableSize.height)
            )
            if fullDrawableRectPx.width > 0, fullDrawableRectPx.height > 0 {
                // A layout-only callback has no rows from which to derive
                // damage. Clear the previous wide frame only after this
                // bracket commits by staging full drawable damage.
                renderer.markDirtyRect(
                    rowStart: 0,
                    rowCount: 0,
                    rectPx: fullDrawableRectPx
                )
                requestRedrawDrawablePx(fullDrawableRectPx)
            } else {
                requestRedraw()
            }
            return
        }

        // Compute dirty rect in drawable pixel coordinates (TOP-ORIGIN to match VH.ndc in flush.zig).
        let cellHpx = CGFloat(renderer.cellHeightPx)
    
        let yFromTopPx = CGFloat(rowStart) * cellHpx
        let hPx = CGFloat(rowCount) * cellHpx
    
        let drawableWPx = CGFloat(self.drawableSize.width)
        let drawableHPx = CGFloat(self.drawableSize.height)
        guard drawableWPx > 0, drawableHPx > 0 else { return }

    
        // y is measured from TOP in drawable pixels (consistent with ndc(): ny = 1 - (y/dh)*2).
        let rectPx = NSRect(
            x: 0,
            y: max(0, yFromTopPx),
            width: drawableWPx,
            height: hPx
        )


    
        renderer.markDirtyRows(rowStart: rowStart, rowCount: rowCount)
    

    
        requestRedrawDrawablePx(rectPx)
    }

    @discardableResult
    func applyMainRowScrollRaw(rowStart: Int, rowEnd: Int, colStart: Int, colEnd: Int, rowsDelta: Int, totalRows: Int, totalCols: Int) -> Bool {
        processPendingScrollClears()
        let ok = renderer.applyMainRowScrollRaw(
            rowStart: rowStart,
            rowEnd: rowEnd,
            colStart: colStart,
            colEnd: colEnd,
            rowsDelta: rowsDelta,
            totalRows: totalRows,
            totalCols: totalCols
        )

        let cellHpx = CGFloat(renderer.cellHeightPx)
        let yFromTopPx = CGFloat(rowStart) * cellHpx
        let hPx = CGFloat(max(0, rowEnd - rowStart)) * cellHpx
        let drawableWPx = CGFloat(self.drawableSize.width)
        guard drawableWPx > 0, hPx > 0 else { return ok }

        let rectPx = NSRect(
            x: 0,
            y: max(0, yFromTopPx),
            width: drawableWPx,
            height: hPx
        )
        requestRedrawDrawablePx(rectPx)
        return ok
    }

    override func keyDown(with event: NSEvent) {
        guard let core else { return }

        let m = event.modifierFlags

        // Check if Option key should be treated as Meta (Alt) based on config.
        // Left Option raw flag: 0x20, Right Option raw flag: 0x40.
        let optionIsMeta = KeyCharacterSelection.optionActsAsMeta(
            hasOption: m.contains(.option),
            modifierRawValue: m.rawValue,
            optionAsMeta: core.getOptionAsMeta()
        )
        let hasControlOrCommand = m.contains(.control) || m.contains(.command) || optionIsMeta

        // evt_ts: NSEvent.timestamp (kernel event time, seconds since boot) in ms.
        // Comparing evt_ts deltas against handler-entry deltas separates the
        // repeat generator's cadence from main-runloop delivery quantization.
        ZonvieCore.appLogScrollMode("[keyDown] keyCode=0x\(String(event.keyCode, radix: 16)) chars=\(event.characters ?? "") hasMarked=\(hasMarkedText()) ctrl/cmd=\(hasControlOrCommand) isRepeat=\(event.isARepeat) evt_ts=\(String(format: "%.3f", event.timestamp * 1000.0))")

        // --- Key repeat synthesis (see MARK above) ---
        if event.isARepeat {
            if synthRepeatActive && event.keyCode == heldKeyCode {
                return  // synthesis owns this key's cadence; swallow OS repeats
            }
            if !synthRepeatActive, event.keyCode == heldKeyCode,
               heldKeyAction != nil, !hasMarkedText()
            {
                takeOverKeyRepeat()
                return
            }
            // Unknown repeat state: stay transparent, process normally below.
        } else {
            // Fresh press (also rollover to another key): previous synthesis
            // no longer matches reality.
            disarmKeyRepeatSynthesis("new keyDown")
        }

        // If IME is composing (has marked text), let IME handle all keys
        // except Escape which cancels composition.
        if consumeKeyDuringComposition(event) { return }

        // No marked text: special keys or Ctrl/Cmd go directly to Neovim.
        let isSpecialKey = KeyCharacterSelection.isSpecialKeyCode(event.keyCode)

        if hasControlOrCommand || isSpecialKey {
            var mods: UInt32 = 0
            if m.contains(.control) { mods |= UInt32(ZONVIE_MOD_CTRL) }
            if optionIsMeta          { mods |= UInt32(ZONVIE_MOD_ALT) }
            if m.contains(.shift)   { mods |= UInt32(ZONVIE_MOD_SHIFT) }
            if m.contains(.command) { mods |= UInt32(ZONVIE_MOD_SUPER) }

            let chars = KeyCharacterSelection.primaryCharacters(
                optionIsMeta: optionIsMeta,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )

            ZonvieCore.appLogScrollMode("[keyDown] -> sendKeyEvent (special/mod) optMeta=\(optionIsMeta) chars=\(chars ?? "nil")")
            core.sendKeyEvent(
                keyCode: UInt32(event.keyCode),
                mods: mods,
                characters: chars,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            // Cmd shortcuts must not synthesize repeats; everything else
            // (arrows, Ctrl-d, ...) is a replayable held-key candidate.
            if !event.isARepeat && !m.contains(.command) {
                armHeldKey(code: event.keyCode, action: .keyEvent(
                    mods: mods,
                    characters: chars,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers
                ))
            }
            return
        }

        // `:` <-> `;` swap (config-gated). Handle it here, on the keyDown path
        // for a single keypress, rather than in sendInputNow: paste also flows
        // through sendInputNow, and swapping there would corrupt pasted text
        // containing `:`/`;`. These two ASCII chars never start IME
        // composition, so bypassing IME for them is safe. The held action
        // stores the swapped char so synthesized repeats replay it verbatim.
        if ZonvieConfig.shared.input.swapColonSemicolon, !hasMarkedText(),
           let ch = event.characters, let swapped = ZonvieConfig.swapColonSemicolon(ch)
        {
            keyRepeatCaptureActive = !event.isARepeat
            keyRepeatCapturedText = nil
            keyRepeatCapturedCount = 0
            sendInputNow(swapped)
            if keyRepeatCaptureActive {
                keyRepeatCaptureActive = false
                if keyRepeatCapturedCount == 1 {
                    armHeldKey(code: event.keyCode, action: .text(swapped))
                }
            }
            return
        }

        // Plain key: capture what this keyDown sends (via IME insertText ->
        // sendInputNow) so repeats can replay it. Only a clean single-send
        // keyDown is a synthesis candidate.
        keyRepeatCaptureActive = !event.isARepeat
        keyRepeatCapturedText = nil
        keyRepeatCapturedCount = 0
        defer {
            if keyRepeatCaptureActive {
                keyRepeatCaptureActive = false
                if keyRepeatCapturedCount == 1, let t = keyRepeatCapturedText,
                   !hasMarkedText()
                {
                    armHeldKey(code: event.keyCode, action: .text(t))
                }
            }
        }

        // Let the system handle IME input.
        if let ctx = inputContext, ctx.handleEvent(event) {
            ZonvieCore.appLogScrollMode("[keyDown] -> inputContext.handleEvent returned true")
            return
        }
        ZonvieCore.appLogScrollMode("[keyDown] -> interpretKeyEvents fallback")
        // Fallback: interpret key events directly.
        interpretKeyEvents([event])
    }

    // MARK: - Smooth Scrolling

    /// Scroll target locked at the start of a trackpad gesture. Subsequent
    /// events (including momentum) scroll this grid even if the pointer drifts
    /// over another grid. Cleared when the gesture and its momentum finish.
    private var lockedScrollTarget: (gridId: Int64, row: Int32, col: Int32)?

    override func scrollWheel(with event: NSEvent) {
        noteScrollGesturePhase(event)
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        if deltaY == 0 && deltaX == 0 { return }

        let location = convert(event.locationInWindow, from: nil)

        // Determine the grid to scroll. For trackpad (precise) gestures the
        // target is resolved once at gesture start and held for the whole
        // gesture + momentum, so the scroll stays on the grid the gesture began
        // over even if the pointer later drifts over a scrollable float (req #2).
        // Mouse-wheel events resolve per event.
        let target: (gridId: Int64, row: Int32, col: Int32)
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.hasPreciseScrollingDeltas && isGesture {
            if event.phase.contains(.began) || lockedScrollTarget == nil {
                lockedScrollTarget = resolveScrollTarget(at: location)
            }
            target = lockedScrollTarget ?? resolveScrollTarget(at: location)
        } else {
            // Mouse wheel, or a phase-less precise event with no gesture lifecycle:
            // resolve per event and drop any stale lock so it is never reused.
            lockedScrollTarget = nil
            target = resolveScrollTarget(at: location)
        }

        let scale = window?.backingScaleFactor ?? 2.0
        let modifier = buildModifierString(from: event.modifierFlags)

        if deltaY != 0 {
            ZonvieCore.appLog("[scroll] deltaY=\(deltaY) hasPrecise=\(event.hasPreciseScrollingDeltas) gridId=\(target.gridId)")

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
                // Shader uniforms are propagated in onPreDraw (which always
                // runs updateScrollShaderOffset before draw); calling it
                // here too would just re-do the same work and fire
                // markAllRowsDirty twice per scroll input.
                ZonvieCore.appLog("[scroll] stored offset=\(newOffset) requesting redraw")
                requestRedraw()
            }
        }

        // Release the lock once the gesture and its inertia have finished. The
        // gesture's own .ended is not released here so momentum keeps the same
        // target; a fresh gesture re-locks on its .began.
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            || event.phase.contains(.cancelled) {
            lockedScrollTarget = nil
        }
    }

    /// Track the trackpad gesture lifecycle for the edge bounce. A held
    /// overscroll must stay put while fingers are down; bounce-back starts as
    /// soon as they lift. Called from scrollWheel of this view and of external
    /// grid views (shared scroll state).
    func noteScrollGesturePhase(_ event: NSEvent) {
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

    /// Update the shader uniform with current scroll offsets
    private func updateScrollShaderOffset() {
        guard let core else { return }

        let cellHeightPx = Float(renderer.cellHeightPx)
        guard cellHeightPx > 0 else { return }

        // Use the same cell-snapped viewport height the vertex data and
        // fragment shader already use (see draw()'s vpHeight / MetalTypes.swift
        // fragmentHeight), not the raw drawable height — otherwise this
        // scroll-offset math disagrees with the shader's NDC reconstruction
        // whenever drawableHeight is not an exact multiple of cellHeightPx
        // (fullscreen / zoomed / tiled window states).
        let cellHi = max(1, UInt32(cellHeightPx.rounded(.up)))
        let drawableHi = max(1, UInt32(drawableSize.height))
        let drawableHeight = Float((drawableHi / cellHi) * cellHi)
        guard drawableHeight > 0 else { return }

        // Idle fast path: nothing to do once scrollOffsetPx has been empty
        // for more than one call. appendFloatScrollOffsets() itself no-ops
        // when offsets (built from scrollOffsetPx) is empty, so "no floats
        // need servicing" is already implied here -- skip building the
        // Dictionary/Set/array below entirely. The FIRST empty call after a
        // non-empty one still falls through, so the transition still
        // propagates an empty state to the renderer (clearing stale offsets).
        scrollOffsetLock.lock()
        let isEmptyNow = scrollOffsetPx.isEmpty
        scrollOffsetLock.unlock()
        if isEmptyNow && !hadScrollOffsetsLastCall {
            return
        }
        hadScrollOffsetsLastCall = !isEmptyNow

        // Get grid info to look up margins and positions (non-blocking).
        // Built into persistent scratch storage (removeAll(keepingCapacity:)
        // + manual insert loops) instead of grids.map + Dictionary(uniqueKeysWithValues:)
        // + Set(...) — this runs in the pre-draw path on every scrolled frame.
        let grids = core.getVisibleGridsCached()
        gridInfoMapScratch.removeAll(keepingCapacity: true)
        for g in grids { gridInfoMapScratch[g.gridId] = g }
        let gridInfoMap = gridInfoMapScratch

        // Prune stale entries: remove gridIds that are no longer visible.
        // visibleGridIdsScratch and scrollOffsetStaleKeysScratch are reused
        // below (cleared again) for the near-zero-offset pruning pass —
        // safe since both passes are sequential, non-overlapping uses
        // within this same call.
        visibleGridIdsScratch.removeAll(keepingCapacity: true)
        for key in gridInfoMap.keys { visibleGridIdsScratch.insert(key) }
        scrollOffsetLock.lock()
        scrollOffsetStaleKeysScratch.removeAll(keepingCapacity: true)
        for key in scrollOffsetPx.keys where !visibleGridIdsScratch.contains(key) {
            scrollOffsetStaleKeysScratch.append(key)
        }
        for key in scrollOffsetStaleKeysScratch {
            scrollOffsetPx.removeValue(forKey: key)
            scrollEdgeBlocked.removeValue(forKey: key)
        }

        // NDC scale: 2.0 / drawableHeight (top = 1.0, bottom = -1.0)
        let ndcScale: Float = 2.0 / drawableHeight

        scrollOffsetStaleKeysScratch.removeAll(keepingCapacity: true)
        scrollOffsetInfoScratch.removeAll(keepingCapacity: true)
        for (gridId, offsetPx) in scrollOffsetPx {
            guard let info = gridInfoMap[gridId] else { continue }
            let clampedOffsetPx = clampVisualScrollOffsetPx(offsetPx, cellHeightPx: CGFloat(cellHeightPx))
            // Skip near-zero offsets to ensure offsets.isEmpty becomes true,
            // preventing markAllRowsDirty from firing every frame. Also prune
            // the entry itself — otherwise scrollOffsetPx never becomes empty
            // for this grid, permanently disabling the idle fast path above
            // and causing this function to rebuild the offsets array every
            // call indefinitely.
            guard abs(clampedOffsetPx) >= Self.scrollOffsetEpsilon else {
                scrollOffsetStaleKeysScratch.append(gridId)
                continue
            }

            // Calculate grid's top Y in NDC
            // Grid starts at startRow (in cells from top), each cell is cellHeightPx
            let gridTopPx = Float(info.startRow) * cellHeightPx
            // In NDC: top of screen = 1.0, so gridTopY = 1.0 - (gridTopPx * scale)
            let gridTopYNDC = 1.0 - gridTopPx * ndcScale

            scrollOffsetInfoScratch.append(MetalTerminalRenderer.ScrollOffsetInfo(
                gridId: gridId,
                offsetYPx: Float(clampedOffsetPx),
                gridTopYNDC: gridTopYNDC,
                gridRows: info.rows,
                marginTop: info.marginTop,
                marginBottom: info.marginBottom,
                // The z-aware guard only discards this grid's scrolled content
                // under STRICTLY higher fixed floats, so a directly-scrolled
                // float keeps drawing above its own backdrop.
                zindex: Int32(clamping: info.zindex)
            ))
        }
        for key in scrollOffsetStaleKeysScratch {
            scrollOffsetPx.removeValue(forKey: key)
        }
        scrollOffsetLock.unlock()

        // Propagate the underlying window's sub-cell offset to float windows that
        // sit over it. Neovim repositions floats discretely (cell granularity) on
        // every committed line scroll, but during the sub-line smooth phase the
        // buffer is shifted by offsetYPx while the float stays put. Shifting the
        // float by the same amount keeps it glued to the buffer line it annotates.
        // Floats carry their own grid_id with DECO_SCROLLABLE already set by the
        // core, so adding a scroll-offset entry is sufficient — no vertex regen.
        // Mutates scrollOffsetInfoScratch directly (rather than a local copy)
        // so this append reuses its existing capacity instead of triggering
        // a copy-on-write allocation.
        let scrollOffsetsComplete = appendFloatScrollOffsets(
            into: &scrollOffsetInfoScratch,
            grids: grids,
            gridInfoMap: gridInfoMap,
            cellHeightPx: cellHeightPx,
            ndcScale: ndcScale
        )

        // Collect fixed (non-following) floats so the fragment shader can discard
        // scrolled content that would otherwise bleed over them while an adjacent
        // row is shifted. Only relevant while a smooth scroll is active.
        fixedFloatRectsScratch.removeAll(keepingCapacity: true)
        if scrollOffsetsComplete && !scrollOffsetInfoScratch.isEmpty {
            let cellW = Float(renderer.cellWidthPx)
            for g in grids where g.zindex > 0 && g.gridId != 1 && !g.followsScroll {
                // A directly-scrolled float stays in the mask: the z-aware
                // guard compares its own zindex against the mask segment's, so
                // it cannot self-discard, while lower-z content scrolled in
                // the same frame is still masked under it.
                fixedFloatRectsScratch.append(MetalTerminalRenderer.FixedFloatRect(
                    x0: Float(g.startCol) * cellW,
                    x1: Float(g.startCol + g.cols) * cellW,
                    top: Float(g.startRow) * cellHeightPx,
                    bottom: Float(g.startRow + g.rows) * cellHeightPx,
                    zindex: Int32(clamping: g.zindex)
                ))
                // One entry beyond the representable maximum is enough to
                // select the cell-aligned fallback; do not grow this hot-path
                // scratch buffer with every remaining float.
                if fixedFloatRectsScratch.count > MetalTerminalRenderer.maxFixedFloatRects { break }
            }
        }
        let fixedFloatMaskRepresentable = renderer.updateFixedFloatRects(fixedFloatRectsScratch)

        // A partial transform is visibly wrong: it can split related windows
        // or let shifted content bleed through an omitted fixed float. Fall
        // back to the committed, cell-aligned frame when either constant
        // buffer would overflow instead of truncating semantic state.
        if !fixedFloatMaskRepresentable {
            scrollOffsetInfoScratch.removeAll(keepingCapacity: true)
        } else if !scrollOffsetsComplete || scrollOffsetInfoScratch.count > Self.maxScrollOffsets {
            scrollOffsetInfoScratch.removeAll(keepingCapacity: true)
            renderer.updateFixedFloatRects([])
        }

        if FrameTracer.enabled {
            var maxOffsetPx: Float = 0
            for info in scrollOffsetInfoScratch {
                maxOffsetPx = max(maxOffsetPx, abs(info.offsetYPx))
            }
            FrameTracer.trace(
                .gestureScrollOffset,
                a: UInt64(Int64(round(Double(maxOffsetPx) * 1000))),
                b: UInt64(Int64(round(Double(cellHeightPx) * 1000)))
            )
        }

        renderer.updateScrollOffsets(scrollOffsetInfoScratch, drawableHeight: drawableHeight, cellHeightPx: cellHeightPx)

        if !scrollOffsetInfoScratch.isEmpty {
            renderer.markAllRowsDirty()
        }
    }

    /// Clear all scroll offsets.
    ///
    /// UNREACHABLE: nothing calls this, and it is the only caller of the
    /// renderer's clearScrollOffsets — so none of that reset happens on any
    /// surface (an external grid view has no MetalTerminalRenderer of its own).
    ///
    /// What it would reset is handled elsewhere: pendingRetentionReplay by
    /// commitFlush, bracketSourceShift by beginFlush, published rows by
    /// updateScrollOffsets' prune. scrollOffsetData is rebuilt whenever
    /// anything is displaced — updateScrollShaderOffset takes an idle early-out
    /// once nothing is, having pushed one empty state through first.
    ///
    /// The capture spans are the exception. They survive a layout change and
    /// are only re-armed by a precise scroll event, so a keyboard scroll
    /// between a window MOVING and the next gesture captures against the old
    /// span. Handles are never reused, so a span cannot be misapplied to a
    /// different window — but that also means the dictionary only grows.
    ///
    /// Left in place rather than deleted; do not write code that relies on it
    /// running.
    private func clearAllScrollOffsets() {
        scrollOffsetLock.lock()
        scrollOffsetPx.removeAll()
        scrollEdgeBlocked.removeAll()
        scrollOffsetLock.unlock()
        renderer.clearScrollOffsets()
    }

    // MARK: - Public Scroll API (for external windows)

    /// Handle scroll input for a specific grid.
    /// Returns the current scroll offset in pixels for visual rendering.
    /// - Parameters:
    ///   - gridId: The grid to scroll
    ///   - row: Row position for nvim_input_mouse
    ///   - col: Column position for nvim_input_mouse
    ///   - deltaY: Scroll delta in points
    ///   - scale: Backing scale factor
    ///   - hasPrecise: Whether this is precise (trackpad) scrolling
    /// - Returns: Current scroll offset in pixels (for sub-cell visual offset)
    /// Tell the renderer which main-surface rows each visible grid's smooth
    /// scroll may retain an outgoing row from. A vertical split or a float
    /// always fails the core's row-scroll fast path (partial_width), so the
    /// grid_scroll capture is the only thing that can keep their outgoing row
    /// alive. A full-width grid normally belongs to the fast path, but that
    /// path only sees rows that actually shifted — a 'smoothscroll' window
    /// repaints instead — so it is armed as well, and the fast path stands
    /// down for a grid this one already retained.
    ///
    /// Note the spans are never disarmed in practice (see
    /// clearAllScrollOffsets), so one gesture arms every grid for the session.
    private func armScrollRetention(gridId: Int64) {
        guard MetalTerminalRenderer.smoothScrollEnabled, let core else { return }
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
        // Grid 1 is the whole-screen composite, not a window: its span would
        // take in the tabline and status rows, and a retained row from there
        // is content that never scrolled.
        for candidate in grids where candidate.gridId != gridId && candidate.gridId != 1 {
            armScrollRetentionSpan(for: candidate, grids: grids)
        }
        guard let info = grids.first(where: { $0.gridId == gridId }) else { return }

        armScrollRetentionSpan(for: info, grids: grids)
    }

    /// The rows one grid's smooth scroll may retain an outgoing row from.
    private func armScrollRetentionSpan(for info: ZonvieCore.GridInfo, grids: [ZonvieCore.GridInfo]) {
        // An external window renders its own surface, so its rows are its own
        // and the full-width test below does not apply. The core reports it at
        // (0,0), which is already this window's row space.
        if let external = core?.externalGridView(for: info.gridId) {
            external.setScrollCaptureBounds(
                top: Int(info.marginTop),
                bottomEx: Int(info.rows - info.marginBottom)
            )
            return
        }

        // Armed for full-width windows too, which used to be left to the
        // row-scroll fast path alone. That path only sees rows that actually
        // shifted, so when Neovim repaints a 'smoothscroll' window instead of
        // scrolling it, nothing was staged and the band opened with no rows to
        // fill it. The fast path now stands down for a grid this one already
        // retained, so the two cannot stage the same movement twice.
        renderer.setGridScrollCaptureBounds(
            gridId: info.gridId,
            bounds: (
                top: Int(info.startRow + info.marginTop),
                bottomEx: Int(info.startRow + info.rows - info.marginBottom)
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
        guard let core else { return 0 }

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
            let fastScrollThreshold = rowHeightPx / scale  // ~20 points at 2x scale
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
                while lookaheadPx * sendDirection > 0 && canSendNow && scrollCount < 3 {
                    core.sendMouseScroll(
                        gridId: gridId,
                        row: row,
                        col: col,
                        direction: sendDirection > 0 ? "up" : "down",
                        modifier: modifier
                    )
                    scrollCount += 1
                    lookaheadPx -= sendDirection * stepPx
                }
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
            if isPaused && (abs(newOffset) >= Self.scrollOffsetEpsilon || alreadyPending + scrollCount > 0) {
                activateDrawLoop()
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
        if MetalTerminalRenderer.smoothScrollEnabled {
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
            // updateScrollOffsets would prune the retained row unused.
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
                if let external = core?.externalGridView(for: gridId) {
                    // An external window's rows live in its own surface, not
                    // the main composite, so the capture belongs to it. It
                    // cannot happen here: its flush bracket opens lazily on
                    // first content, which is after this callback, and opening
                    // discards anything staged before it. Hand over the
                    // distance instead and let it capture when the bracket
                    // opens — the committed set still holds the on-screen rows
                    // at that point.
                    external.noteGridScroll(rowsDelta: rowsDelta)
                } else {
                    renderer.captureRetainedRowForGridScroll(gridId: gridId, rowsDelta: rowsDelta)
                }
            }
        }
        pendingScrollClearLock.lock()
        stagedScrollClear.append((gridId: gridId, rowsDelta: rowsDelta))
        pendingScrollClearLock.unlock()
    }

    /// Release everything staged during the flush that just committed. Called
    /// from the renderer on the core thread with no renderer lock held.
    func publishStagedScrollClears() {
        pendingScrollClearLock.lock()
        if !stagedScrollClear.isEmpty {
            pendingScrollClear.append(contentsOf: stagedScrollClear)
            stagedScrollClear.removeAll(keepingCapacity: true)
        }
        pendingScrollClearLock.unlock()
    }

    /// An external window published new content for a grid whose scroll offset
    /// this view holds. See pendingExternalScrollClear.
    func clearScrollOffsetForExternalGrid(_ gridId: Int64) {
        pendingScrollClearLock.lock()
        pendingExternalScrollClear.append(gridId)
        pendingScrollClearLock.unlock()
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

    /// Process pending scroll clears (can be called from any thread).
    /// Does NOT call updateScrollShaderOffset() to avoid deadlock when called from Zig callback.
    /// Shader update will happen in onPreDraw before rendering.
    /// Public so external grid views can call this before their draw to stay in sync.
    /// Ask Neovim to turn 'smoothscroll' on for the grid the gesture is
    /// driving. Idempotent on the Neovim side, but only sent once per gesture;
    /// a request that could not be issued is retried by the tick below.
    private func requestGestureSmoothScroll(gridId: Int64) {
        guard MetalTerminalRenderer.smoothScrollEnabled, let core else { return }
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
        let external = pendingExternalScrollClear
        pendingExternalScrollClear.removeAll(keepingCapacity: true)
        pendingScrollClearLock.unlock()

        guard !pending.isEmpty || !external.isEmpty else { return }

        let rowHeightPx = CGFloat(renderer.cellHeightPx)
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
        for gridId in external {
            // A reconciliation in the same batch carries the distance the
            // content actually moved and settles the offset itself; dropping
            // it here first would leave that reconciliation adding a full row
            // to zero and displace the grid.
            //
            // This only covers the co-drained case. An external window appends
            // its clear during vertex generation, while a reconciliation is
            // staged until this view's commit — so a drain landing between the
            // two, or a flush that aborts before committing, still sees the
            // clear alone. Pairing them properly needs the external clear to
            // be timed against the external window's own commit, which this
            // view cannot observe.
            if pending.contains(where: { $0.gridId == gridId }) { continue }
            smoothScrollGrids.remove(gridId)
            gestureLookaheadGrids.remove(gridId)
            scrollOffsetPx.removeValue(forKey: gridId)
        }
        for (gridId, rowsDelta) in pending {
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
                    if MetalTerminalRenderer.smoothScrollEnabled, rowHeightPx > 0 {
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
        guard MetalTerminalRenderer.smoothScrollEnabled else { return }
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
        // them in, updateScrollOffsets prunes them unused.
        seedScratch.removeAll(keepingCapacity: true)
        for seed in renderer.takeSmoothScrollSeeds() {
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
        if easeActive && isPaused {
            activateDrawLoop()
        }
    }

    /// Service shared smooth-scroll state for external windows that reuse the
    /// main view's scroll offset storage but do not run the main view's
    /// onPreDraw hook every frame.
    func serviceSharedScrollStateForExternalView() {
        processPendingScrollClears()
        tickScrollEdgeBounce()
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

    /// Get scroll offset info for a specific grid (for external window shader update).
    /// Returns nil if the grid is not found.
    func getScrollOffsetInfo(gridId: Int64, drawableHeight: Float, cellHeightPx: Float) -> MetalTerminalRenderer.ScrollOffsetInfo? {
        guard let core else { return nil }

        scrollOffsetLock.lock()
        let offsetPx = clampVisualScrollOffsetPx(scrollOffsetPx[gridId] ?? 0, cellHeightPx: CGFloat(cellHeightPx))
        scrollOffsetLock.unlock()
        if abs(offsetPx) < 0.001 { return nil }

        // Get grid info for margins (non-blocking)
        let grids = core.getVisibleGridsCached()
        guard let info = grids.first(where: { $0.gridId == gridId }) else { return nil }

        // Calculate grid's top Y in NDC
        let ndcScale: Float = 2.0 / drawableHeight
        let gridTopPx = Float(info.startRow) * cellHeightPx
        let gridTopYNDC = 1.0 - gridTopPx * ndcScale

        return MetalTerminalRenderer.ScrollOffsetInfo(
            gridId: gridId,
            offsetYPx: Float(offsetPx),
            gridTopYNDC: gridTopYNDC,
            gridRows: info.rows,
            marginTop: info.marginTop,
            marginBottom: info.marginBottom
        )
    }

    /// Hit-test to find which grid is at the given point (highest zindex wins)
    private func hitTestGrid(at point: CGPoint, adjustForSmoothScroll: Bool = true) -> (gridId: Int64, row: Int32, col: Int32) {
        guard let core else { return (1, 0, 0) }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        // Early return when renderer is uninitialized (cellMetrics not yet available).
        guard renderer.cellWidthPx > 0 && renderer.cellHeightPx > 0 else { return (1, 0, 0) }

        // Use integer-rounded cell dimensions to match core grid math exactly.
        // The core receives these rounded values via updateLayoutPx and uses them
        // for row/col computation and vertex positioning.
        let cellW = max(1.0, CGFloat(Int(renderer.cellWidthPx.rounded(.up))))
        let cellH = max(1.0, CGFloat(Int(renderer.cellHeightPx.rounded(.up))))

        // Compute integer drawable height from current bounds (same formula as
        // updateDrawableSizeIfPossible). This avoids depending on the stored
        // drawableSize property which may lag behind bounds during resize.
        let drawableH = CGFloat(max(1, Int((bounds.height * scale).rounded(.toNearestOrAwayFromZero))))

        // Convert point to drawable pixel coordinates (top-origin).
        let pointPx: CGPoint
        if isFlipped {
            pointPx = CGPoint(x: point.x * scale, y: point.y * scale)
        } else {
            // NSView is bottom-origin, convert to top-origin
            pointPx = CGPoint(x: point.x * scale, y: drawableH - point.y * scale)
        }

        // Calculate cell position in global grid coordinates
        let globalCol = Int32(pointPx.x / cellW)
        let globalRow = Int32(pointPx.y / cellH)

        // Get visible grids from core (non-blocking)
        let grids = core.getVisibleGridsCached()

        ZonvieCore.appLog("[hitTest] point=\(point) pointPx=\(pointPx) globalRow=\(globalRow) globalCol=\(globalCol) gridsCount=\(grids.count)")
        for grid in grids {
            ZonvieCore.appLog("[hitTest]   grid: id=\(grid.gridId) zindex=\(grid.zindex) startRow=\(grid.startRow) startCol=\(grid.startCol) rows=\(grid.rows) cols=\(grid.cols) marginTop=\(grid.marginTop) marginBottom=\(grid.marginBottom)")
        }

        // Find grid with highest zindex containing this point
        var bestGridId: Int64 = 1  // default to global grid
        var bestZindex: Int64 = Int64.min
        var localRow: Int32 = globalRow
        var localCol: Int32 = globalCol

        for grid in grids {
            // External grids are separate top-level windows reported at (0,0);
            // they must not be hit by the main window's coordinate-space test.
            if grid.isExternal { continue }
            let inRowRange = globalRow >= grid.startRow && globalRow < grid.startRow + grid.rows
            let inColRange = globalCol >= grid.startCol && globalCol < grid.startCol + grid.cols

            if inRowRange && inColRange {
                // Prefer higher zindex; if same zindex, prefer grid_id > 1 (actual windows over background)
                let dominated = grid.zindex > bestZindex ||
                    (grid.zindex == bestZindex && grid.gridId > 1 && bestGridId == 1)
                if dominated {
                    bestZindex = grid.zindex
                    bestGridId = grid.gridId
                    localRow = globalRow - grid.startRow
                    localCol = globalCol - grid.startCol
                }
            }
        }

        // Adjust for smooth scroll offset: during scrolling, content rows are
        // visually shifted by scrollOffsetPx. Without this adjustment, clicking
        // on visually-shifted content selects the wrong row.
        scrollOffsetLock.lock()
        let offsetPx = clampVisualScrollOffsetPx(scrollOffsetPx[bestGridId] ?? 0, cellHeightPx: cellH)
        scrollOffsetLock.unlock()

        if adjustForSmoothScroll, abs(offsetPx) > 0.001, let grid = grids.first(where: { $0.gridId == bestGridId }) {
            // Content at static pixel Y is displayed at visual pixel Y + scrollOffsetPx.
            // Reverse: static Y = visual Y - scrollOffsetPx.
            let adjustedPxY = pointPx.y - CGFloat(offsetPx)
            let adjustedGlobalRow = Int32(adjustedPxY / cellH)
            let adjustedLocalRow = adjustedGlobalRow - grid.startRow

            // Only apply adjustment within the scrollable content area (not margins)
            let contentTop = grid.marginTop
            let contentBottom = grid.rows - grid.marginBottom
            if adjustedLocalRow >= contentTop && adjustedLocalRow < contentBottom {
                localRow = adjustedLocalRow
            }
        }

        ZonvieCore.appLog("[hitTest] result: gridId=\(bestGridId) localRow=\(localRow) localCol=\(localCol) scrollOffset=\(offsetPx)")
        return (bestGridId, localRow, localCol)
    }

    /// True when the float has more buffer content than fits in its visible
    /// area, i.e. it can scroll its own content. Floats that fully show their
    /// content must not capture smooth scroll — it falls through to the window
    /// beneath them (req #1). Uses the cached grid info (line_count) so the input
    /// path never makes a blocking viewport query into the core.
    private func isFloatLogicallyScrollable(_ grid: ZonvieCore.GridInfo) -> Bool {
        // Content rows = grid height minus border/winbar margins. Logical
        // scrollability is position-independent: the buffer simply has more
        // lines than fit in the visible content area.
        let contentRows = Int64(max(0, grid.rows - grid.marginTop - grid.marginBottom))
        return grid.lineCount > contentRows
    }

    /// Resolve which grid a scroll at `point` should target. A non-scrollable
    /// float overlay is transparent to scrolling, so the scroll falls through to
    /// the topmost window beneath it (req #1). Returns grid-local row/col.
    private func resolveScrollTarget(at point: CGPoint) -> (gridId: Int64, row: Int32, col: Int32) {
        guard let core, renderer.cellWidthPx > 0 && renderer.cellHeightPx > 0 else { return (1, 0, 0) }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let cellW = max(1.0, CGFloat(Int(renderer.cellWidthPx.rounded(.toNearestOrAwayFromZero))))
        let cellH = max(1.0, CGFloat(Int(renderer.cellHeightPx.rounded(.toNearestOrAwayFromZero))))
        let drawableH = CGFloat(max(1, Int((bounds.height * scale).rounded(.toNearestOrAwayFromZero))))
        let pointPx: CGPoint = isFlipped
            ? CGPoint(x: point.x * scale, y: point.y * scale)
            : CGPoint(x: point.x * scale, y: drawableH - point.y * scale)
        let globalCol = Int32(pointPx.x / cellW)
        let globalRow = Int32(pointPx.y / cellH)

        let grids = core.getVisibleGridsCached()

        // Pick the topmost (highest zindex) grid at this point that can actually
        // receive scroll: a window (zindex 0) or a logically-scrollable float.
        // Non-scrollable floats are transparent to scrolling and skipped, so a
        // scrollable grid directly beneath one — be it another float or the base
        // window — shows through (req #1).
        var target: ZonvieCore.GridInfo?
        var bestZ = Int64.min
        for grid in grids {
            // External grids are separate top-level windows reported at (0,0);
            // exclude them from the main window's scroll-target resolution.
            if grid.isExternal { continue }
            let inRow = globalRow >= grid.startRow && globalRow < grid.startRow + grid.rows
            let inCol = globalCol >= grid.startCol && globalCol < grid.startCol + grid.cols
            guard inRow && inCol else { continue }
            // Skip non-scrollable floats — they do not capture scroll.
            if grid.zindex > 0 && !isFloatLogicallyScrollable(grid) { continue }
            let dominated = target == nil || grid.zindex > bestZ ||
                (grid.zindex == bestZ && grid.gridId > 1 && target!.gridId == 1)
            if dominated { target = grid; bestZ = grid.zindex }
        }
        guard let g = target else { return (1, globalRow, globalCol) }
        return (g.gridId, globalRow - g.startRow, globalCol - g.startCol)
    }

    /// Clamp visual scroll offset to the range the shader can actually display.
    /// Give float windows the sub-cell scroll offset of the window they sit over,
    /// so they stay glued to the buffer line during smooth scrolling. Floats are
    /// sub-grids with a non-zero zindex; each follows the scrolled window with the
    /// largest rectangle overlap (so a float whose border extends a row/column past
    /// the window edge still tracks it). The whole float — including its border
    /// (viewport-margin) rows — translates via move_all, so a scroll-offset entry
    /// is all that is needed; the float's vertices are not regenerated.
    private func appendFloatScrollOffsets(
        into offsets: inout [MetalTerminalRenderer.ScrollOffsetInfo],
        grids: [ZonvieCore.GridInfo],
        gridInfoMap: [Int64: ZonvieCore.GridInfo],
        cellHeightPx: Float,
        ndcScale: Float
    ) -> Bool {
        // Nothing to propagate unless a window is actively being scrolled.
        guard !offsets.isEmpty else { return true }
        guard offsets.count <= Self.maxScrollOffsets else { return false }

        // Only the window entries built before this call are scroll sources; the
        // float entries appended below must not be treated as sources. Capture the
        // count up front and scan offsets[0..<windowCount] in place — no per-frame
        // array allocation (this runs in the pre-draw path every scrolled frame).
        let windowCount = offsets.count

        for floatGrid in grids {
            guard floatGrid.zindex > 0, floatGrid.gridId != 1 else { continue }
            // Only buffer-tracking floats (repositioned on scroll) pixel-follow.
            // A fixed editor overlay never repositions and must stay put.
            guard floatGrid.followsScroll else { continue }
            // Skip floats that were scrolled directly (already have a window entry).
            var alreadyScrolled = false
            for i in 0..<windowCount where offsets[i].gridId == floatGrid.gridId {
                alreadyScrolled = true
                break
            }
            if alreadyScrolled { continue }

            // Choose which scroll offset to follow:
            //  - A window-anchored float (anchorGrid > 1) follows ONLY its anchor
            //    window's scroll, never another window it merely overlaps.
            //  - An editor/global-anchored float (anchorGrid == 1, e.g. a plugin
            //    that re-pins it to a buffer line on scroll) follows the scrolled
            //    window it sits over, by largest rectangle overlap. anchorGrid
            //    alone cannot tell a buffer-tracking editor float from a fixed one,
            //    so this case keeps the overlap heuristic.
            var followedOffsetYPx: Float?
            if floatGrid.anchorGrid > 1 {
                for i in 0..<windowCount where offsets[i].gridId == floatGrid.anchorGrid {
                    // Only follow when the anchor is itself a scrolled window.
                    if let aw = gridInfoMap[offsets[i].gridId], aw.zindex <= 0 {
                        followedOffsetYPx = offsets[i].offsetYPx
                    }
                    break
                }
            } else {
                // Only windows (zindex <= 0) are valid overlap sources: a directly
                // scrolled float scrolls its own content and must not bodily-move
                // other floats.
                var bestOverlap: Int32 = 0
                for i in 0..<windowCount {
                    guard let w = gridInfoMap[offsets[i].gridId], w.zindex <= 0 else { continue }
                    let rowOverlap = min(floatGrid.startRow + floatGrid.rows, w.startRow + w.rows) - max(floatGrid.startRow, w.startRow)
                    let colOverlap = min(floatGrid.startCol + floatGrid.cols, w.startCol + w.cols) - max(floatGrid.startCol, w.startCol)
                    guard rowOverlap > 0, colOverlap > 0 else { continue }
                    let overlap = rowOverlap * colOverlap
                    if overlap > bestOverlap {
                        bestOverlap = overlap
                        followedOffsetYPx = offsets[i].offsetYPx
                    }
                }
            }
            guard let offsetYPx = followedOffsetYPx else { continue }
            // A partial offset set can split a float from its anchor. Signal
            // overflow so the caller disables the whole transform for this
            // frame instead of silently truncating semantic state.
            guard offsets.count < Self.maxScrollOffsets else { return false }

            let gridTopPx = Float(floatGrid.startRow) * cellHeightPx
            let gridTopYNDC = 1.0 - gridTopPx * ndcScale
            offsets.append(MetalTerminalRenderer.ScrollOffsetInfo(
                gridId: floatGrid.gridId,
                offsetYPx: offsetYPx,
                gridTopYNDC: gridTopYNDC,
                gridRows: floatGrid.rows,
                marginTop: 0,
                marginBottom: 0,
                clipToContent: false,
                zindex: Int32(clamping: floatGrid.zindex)
            ))
        }
        return true
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

// MARK: - NSTextInputClient (IME support)
extension MetalTerminalView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        ime.insertText(string)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        ime.setMarkedText(string, selectedRange: selectedRange)
    }

    func unmarkText() {
        ime.unmarkText()
    }

    func markedRange() -> NSRange { ime.markedRange }

    func selectedRange() -> NSRange { ime.selectedRange }

    func hasMarkedText() -> Bool { ime.hasMarkedText }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { ime.validAttributes }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return ime.firstRect()
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    /// Handle unbound key commands from interpretKeyEvents.
    override func doCommand(by selector: Selector) {
        // Some keys (like arrow keys during IME) may come through here.
        // For most terminal usage, we can ignore these or handle specific selectors.
    }
}

// MARK: - Shared IME preedit handling

/// View-specific bits the shared IME controller needs. Implemented by the main
/// terminal view and each external-window grid view so both share one
/// NSTextInputClient implementation.
protocol IMEPreeditHost: AnyObject {
    /// Core handle used to route preedit/commit through the inline-extmark path.
    var imeCore: ZonvieCore? { get }
    /// Font used to draw the fallback preedit overlay.
    var imePreeditFont: NSFont { get }
    /// Cell size in points (width, height) for overlay layout.
    var imePreeditCellSize: CGSize { get }
    /// View the preedit overlay is added to as a subview.
    var imePreeditContainer: NSView { get }
    /// Overlay frame origin (container-local). `preeditHeight` is the overlay's
    /// own height, for the top-left fallback when no cursor position is known.
    func imePreeditOrigin(preeditHeight: CGFloat) -> CGPoint
    /// Candidate-window rect in screen coordinates.
    func imeFirstRect() -> NSRect
    /// Send committed (final) IME text to Neovim.
    func imeSendCommitted(_ text: String)
}

/// Shared IME composition handling for the main grid and external windows.
/// Prefers the core's inline-extmark preedit (which shifts following buffer
/// text); falls back to a floating overlay when the core declines (e.g. cmdline).
final class IMEPreeditController {
    private weak var host: IMEPreeditHost?

    private var markedText = NSMutableAttributedString()
    private var markedRange_ = NSRange(location: NSNotFound, length: 0)
    private var selectedRange_ = NSRange(location: 0, length: 0)

    private lazy var preeditView: PreeditOverlayView = {
        let view = PreeditOverlayView()
        view.isHidden = true
        host?.imePreeditContainer.addSubview(view)
        return view
    }()

    init(host: IMEPreeditHost) { self.host = host }

    // MARK: NSTextInputClient-backing logic

    func insertText(_ string: Any) {
        guard let text = IMEPreeditController.text(from: string) else { return }
        ZonvieCore.appLog("[IME] insertText: \"\(text)\"")
        // Clear marked state, the inline extmark, and the overlay before commit.
        markedText = NSMutableAttributedString()
        markedRange_ = NSRange(location: NSNotFound, length: 0)
        host?.imeCore?.clearPreedit()
        hideOverlay()
        host?.imeSendCommitted(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange) {
        markedText = IMEPreeditController.attributed(from: string)
        ZonvieCore.appLog("[IME] setMarkedText: \"\(markedText.string)\" selectedRange=\(selectedRange)")
        if markedText.length > 0 {
            markedRange_ = NSRange(location: 0, length: markedText.length)
            // Prefer the core's inline-extmark preedit; fall back to the overlay
            // when the core declines (extmark mode off, or no buffer to anchor).
            if host?.imeCore?.setPreedit(markedText, selectedRange: selectedRange) == true {
                hideOverlay()
            } else {
                showOverlay(selectedRange: selectedRange)
            }
        } else {
            markedRange_ = NSRange(location: NSNotFound, length: 0)
            host?.imeCore?.clearPreedit()
            hideOverlay()
        }
        selectedRange_ = selectedRange
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedRange_ = NSRange(location: NSNotFound, length: 0)
        host?.imeCore?.clearPreedit()
        hideOverlay()
    }

    var markedRange: NSRange { markedRange_ }
    var selectedRange: NSRange { selectedRange_ }
    var hasMarkedText: Bool { markedRange_.location != NSNotFound && markedRange_.length > 0 }
    var validAttributes: [NSAttributedString.Key] { [.underlineStyle, .foregroundColor, .backgroundColor] }
    func firstRect() -> NSRect { host?.imeFirstRect() ?? .zero }

    // MARK: Overlay

    private func showOverlay(selectedRange: NSRange) {
        guard let host else { return }
        let cell = host.imePreeditCellSize
        preeditView.configure(
            attributedText: markedText,
            selectedRange: selectedRange,
            font: host.imePreeditFont,
            cellWidth: cell.width,
            cellHeight: cell.height
        )
        preeditView.frame.origin = host.imePreeditOrigin(preeditHeight: preeditView.frame.height)
        preeditView.isHidden = false
    }

    private func hideOverlay() {
        preeditView.isHidden = true
        preeditView.clear()
    }

    // MARK: Helpers

    private static func text(from string: Any) -> String? {
        if let s = string as? String { return s }
        if let a = string as? NSAttributedString { return a.string }
        return nil
    }

    private static func attributed(from string: Any) -> NSMutableAttributedString {
        if let s = string as? String { return NSMutableAttributedString(string: s) }
        if let a = string as? NSAttributedString { return NSMutableAttributedString(attributedString: a) }
        return NSMutableAttributedString()
    }
}

// MARK: - MetalTerminalView IME host

extension MetalTerminalView: IMEPreeditHost {
    var imeCore: ZonvieCore? { core }

    var imePreeditFont: NSFont {
        NSFont(name: renderer.currentFontName, size: renderer.currentPointSize)
            ?? NSFont.monospacedSystemFont(ofSize: renderer.currentPointSize, weight: .regular)
    }

    var imePreeditCellSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2.0
        return CGSize(width: CGFloat(renderer.cellWidthPx) / scale,
                      height: CGFloat(renderer.cellHeightPx) / scale)
    }

    var imePreeditContainer: NSView { self }

    func imePreeditOrigin(preeditHeight: CGFloat) -> CGPoint {
        let cell = imePreeditCellSize
        if let core = core {
            let cursor = core.getCursorPositionNonBlocking()
            if cursor.row >= 0 && cursor.col >= 0 {
                // Cursor is grid-local; add the grid's screen offset.
                var screenRow = Int(cursor.row)
                var screenCol = Int(cursor.col)
                for grid in core.getVisibleGridsCached() where grid.gridId == cursor.gridId {
                    screenRow = Int(grid.startRow) + Int(cursor.row)
                    screenCol = Int(grid.startCol) + Int(cursor.col)
                    break
                }
                let x = CGFloat(screenCol) * cell.width
                let y = bounds.height - CGFloat(screenRow + 1) * cell.height
                return CGPoint(x: x, y: y)
            }
        }
        return CGPoint(x: cell.width, y: bounds.height - cell.height - preeditHeight)
    }

    func imeFirstRect() -> NSRect {
        guard let win = window else { return .zero }
        let scale = win.backingScaleFactor
        let cellW = CGFloat(renderer.cellWidthPx) / scale
        let rowH = CGFloat(renderer.cellHeightPx) / scale
        var screenRow = 0
        var screenCol = 0
        if let core = core {
            let cursor = core.getCursorPositionNonBlocking()
            if cursor.row >= 0 && cursor.col >= 0 {
                screenRow = Int(cursor.row)
                screenCol = Int(cursor.col)
                for grid in core.getVisibleGridsCached() where grid.gridId == cursor.gridId {
                    screenRow = Int(grid.startRow) + Int(cursor.row)
                    screenCol = Int(grid.startCol) + Int(cursor.col)
                    break
                }
            }
        }
        let cursorXPt = CGFloat(screenCol) * cellW
        let cursorYPt = bounds.height - CGFloat(screenRow + 1) * rowH
        let rectInView = NSRect(x: cursorXPt, y: cursorYPt, width: cellW, height: rowH)
        return win.convertToScreen(convert(rectInView, to: nil))
    }

    func imeSendCommitted(_ text: String) { sendInputNow(text) }
}

// MARK: - Preedit Overlay View

/// Custom view for drawing preedit (IME composition) text with exact cell-width alignment.
final class PreeditOverlayView: NSView {
    private var text: String = ""
    private var attributedText: NSAttributedString?
    private var selectedRange: NSRange = NSRange(location: NSNotFound, length: 0)
    private var font: NSFont?
    private var cellWidth: CGFloat = 0
    private var cellHeight: CGFloat = 0

    /// Underline segment info (character range -> isThick)
    private var underlineSegments: [(range: NSRange, isThick: Bool)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Re-resolve the dynamic NSColor for the current Light/Dark appearance.
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        needsDisplay = true
    }

    /// Clear the preedit overlay content.
    func clear() {
        text = ""
        attributedText = nil
        selectedRange = NSRange(location: NSNotFound, length: 0)
        underlineSegments.removeAll()
        needsDisplay = true
    }

    func configure(
        attributedText: NSAttributedString,
        selectedRange: NSRange,
        font: NSFont?,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) {
        self.text = attributedText.string
        self.attributedText = attributedText
        self.selectedRange = selectedRange
        self.font = font
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight

        // Parse underline segments from attributed string
        parseUnderlineSegments(attributedText: attributedText, selectedRange: selectedRange)

        // Calculate total width based on cell widths
        var totalCells = 0
        for char in text {
            totalCells += PreeditOverlayView.cellWidth(for: char)
        }

        let width = cellWidth * CGFloat(totalCells)
        let height = cellHeight

        frame.size = NSSize(width: max(1, width), height: max(1, height))
        needsDisplay = true
    }

    /// Parse IME attributes to determine underline segments.
    /// Selected/converting portion gets thick underline, others get thin underline.
    private func parseUnderlineSegments(attributedText: NSAttributedString, selectedRange: NSRange) {
        underlineSegments.removeAll()

        let fullRange = NSRange(location: 0, length: attributedText.length)
        guard fullRange.length > 0 else { return }

        // Enumerate NSMarkedClauseSegment to find clause boundaries
        var clauseRanges: [NSRange] = []
        attributedText.enumerateAttribute(
            NSAttributedString.Key.markedClauseSegment,
            in: fullRange,
            options: []
        ) { value, range, _ in
            if value != nil {
                clauseRanges.append(range)
            }
        }

        if clauseRanges.isEmpty {
            // No clause info: use selectedRange for thick, rest for thin
            if selectedRange.location != NSNotFound && selectedRange.length > 0 {
                // Before selected
                if selectedRange.location > 0 {
                    underlineSegments.append((
                        range: NSRange(location: 0, length: selectedRange.location),
                        isThick: false
                    ))
                }
                // Selected portion (thick)
                underlineSegments.append((range: selectedRange, isThick: true))
                // After selected
                let afterStart = selectedRange.location + selectedRange.length
                if afterStart < fullRange.length {
                    underlineSegments.append((
                        range: NSRange(location: afterStart, length: fullRange.length - afterStart),
                        isThick: false
                    ))
                }
            } else {
                // No selection info: entire text gets thin underline
                underlineSegments.append((range: fullRange, isThick: false))
            }
        } else {
            // Use clause boundaries; the clause containing selectedRange.location is thick
            for clauseRange in clauseRanges {
                let containsSelection = selectedRange.location != NSNotFound &&
                    clauseRange.location <= selectedRange.location &&
                    selectedRange.location < clauseRange.location + clauseRange.length
                underlineSegments.append((range: clauseRange, isThick: containsSelection))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let font = font, cellWidth > 0, cellHeight > 0 else { return }

        // Draw background
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath.fill(bounds)

        // Text attributes without underline (we draw underline separately)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]

        // Build character-to-xOffset mapping
        var charXOffsets: [CGFloat] = []
        var xOffset: CGFloat = 0
        for char in text {
            charXOffsets.append(xOffset)
            let cellCount = PreeditOverlayView.cellWidth(for: char)
            xOffset += cellWidth * CGFloat(cellCount)
        }
        charXOffsets.append(xOffset)  // End position

        // Draw each character at exact cell positions
        for (index, char) in text.enumerated() {
            let charStr = String(char)
            let point = NSPoint(x: charXOffsets[index], y: 0)
            charStr.draw(at: point, withAttributes: attrs)
        }

        // Draw underlines based on segments
        NSColor.textColor.setStroke()
        for segment in underlineSegments {
            let startCharIndex = segment.range.location
            let endCharIndex = min(segment.range.location + segment.range.length, charXOffsets.count - 1)

            guard startCharIndex < charXOffsets.count && endCharIndex <= charXOffsets.count else { continue }

            let startX = charXOffsets[startCharIndex]
            let endX = charXOffsets[endCharIndex]

            let underlinePath = NSBezierPath()
            underlinePath.lineWidth = segment.isThick ? 2.0 : 1.0
            let yPos: CGFloat = segment.isThick ? 2.0 : 1.5
            underlinePath.move(to: NSPoint(x: startX, y: yPos))
            underlinePath.line(to: NSPoint(x: endX, y: yPos))
            underlinePath.stroke()
        }
    }

    /// Returns the cell width (1 or 2) for a character based on East Asian Width.
    static func cellWidth(for char: Character) -> Int {
        guard let scalar = char.unicodeScalars.first else { return 1 }
        let value = scalar.value

        // East Asian Wide (W) and Fullwidth (F) characters take 2 cells
        if (0x1100...0x115F).contains(value) ||   // Hangul Jamo
           (0x2E80...0x9FFF).contains(value) ||   // CJK radicals, symbols, ideographs
           (0xAC00...0xD7AF).contains(value) ||   // Hangul syllables
           (0xF900...0xFAFF).contains(value) ||   // CJK compatibility ideographs
           (0xFE10...0xFE1F).contains(value) ||   // Vertical forms
           (0xFE30...0xFE6F).contains(value) ||   // CJK compatibility forms
           (0xFF00...0xFF60).contains(value) ||   // Fullwidth forms
           (0xFFE0...0xFFE6).contains(value) ||   // Fullwidth symbols
           (0x20000...0x2FFFF).contains(value) || // CJK Extension B and beyond
           (0x30000...0x3FFFF).contains(value) {  // CJK Extension G and beyond
            return 2
        }

        // Hiragana and Katakana (3040-30FF)
        if (0x3040...0x30FF).contains(value) {
            return 2
        }

        return 1
    }
}

// MARK: - Drag & Drop (file opening)
extension MetalTerminalView {

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        // The dragged item has to predict what the drop does, and both follow
        // the same test (dropInsertsPath). Setting it on every entry also
        // restores the file icon after the external cmdline window swapped the
        // item to text on its way past.
        if dropInsertsPath {
            FileDragFeedback.showPathText(sender, in: self)
        } else {
            FileDragFeedback.showFileIcon(sender, in: self)
        }
        return .copy
    }

    /// Whether a drop on THIS view inserts a path rather than opening the file.
    ///
    /// The drop target decides. When the command line is a separate window this
    /// view is purely the buffer, so a drop here always opens — the command
    /// line has its own drop target. Only when the command line is drawn in
    /// this window's own bottom row ([cmdline] external = false) does dropping
    /// while it is up mean "put the path here".
    private var dropInsertsPath: Bool {
        guard let core, !core.hasExternalCmdlineWindow else { return false }
        return core.getCurrentMode().hasPrefix("cmdline")
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return false
        }

        guard !urls.isEmpty, let core = core else { return false }

        let paths = urls.map { escapePathForNeovim($0.path) }.joined(separator: " ")

        if dropInsertsPath {
            // Built-in command line is up: insert paths at the cursor.
            core.sendInput(paths)
        } else {
            // Buffer drop: open the files.
            core.sendCommand("drop \(paths)")
        }
        return true
    }
}
