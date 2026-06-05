import Cocoa
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

    // --- Scroll state for smooth scrolling ---
    // Per-grid accumulated scroll offset in pixels (for sub-cell smooth scrolling)
    private var scrollOffsetPx: [Int64: CGFloat] = [:]
    // Lock protecting scrollOffsetPx from concurrent access between
    // the RPC thread (processPendingScrollClears via submitVerticesRowRaw)
    // and the main thread (handleScrollInput, updateScrollShaderOffset).
    // Lock order: scrollOffsetLock -> pendingSentScrollLock (never reversed).
    private let scrollOffsetLock = NSLock()

    // Track scroll commands sent to Neovim (to distinguish frontend vs Neovim-initiated scrolls)
    // When we send a scroll, we increment this; when grid_scroll arrives, we decrement.
    // If count > 0, it's a response to our scroll (keep offset); if 0, it's Neovim-initiated (clear offset).
    private var pendingSentScroll: [Int64: Int] = [:]
    private let pendingSentScrollLock = NSLock()

    // Thread-safe pending scroll clear set (for grid_scroll events from Zig thread)
    private var pendingScrollClear = [Int64: Int]()  // gridId → count of grid_scroll events
    private let pendingScrollClearLock = NSLock()

    // Stale scroll detection: tracks frames since last grid_scroll per grid.
    // When pendingSentScroll > 0 but no grid_scroll arrives for several frames,
    // the scroll likely hit a buffer boundary (Neovim can't scroll further).
    // In that case, we decay the offset to prevent it from getting stuck.
    private var scrollStaleFrameCount: [Int64: Int] = [:]

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
    /// and decayStaleScrollOffsets to prevent stale zero-offset entries from keeping
    /// offsets.isEmpty == false (which would trigger markAllRowsDirty every frame).
    private static let scrollOffsetEpsilon: CGFloat = 1.0

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
        let ms = core.nextMsgTimeoutMs()
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

    // Debug: call this from draw to test scrollbar update
    func debugUpdateScrollbar() {
        guard let core else {
            ZonvieCore.appLog("[Scrollbar-debug] no core")
            return
        }
        let vp = core.getViewport(gridId: -1)
        ZonvieCore.appLog("[Scrollbar-debug] getViewport(1) = \(String(describing: vp))")
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
    // render-clock-driven synthesizer. Subsequent OS repeats are swallowed.
    // The synthesizer fires from the draw callback (main thread, 60Hz in
    // continuous mode) at the user's configured repeat interval, so held-key
    // scrolling advances in lockstep with the display: no beats, no holes,
    // and no per-repeat IME round-trip (~4ms main-thread each).

    /// What the initial keyDown sent to Neovim; replayed verbatim per repeat.
    private enum HeldKeyAction {
        case text(String)
        case keyEvent(mods: UInt32, characters: String?, charactersIgnoringModifiers: String?)
    }
    private var heldKeyCode: UInt16? = nil
    private var heldKeyAction: HeldKeyAction? = nil
    private var synthRepeatActive = false
    /// CLOCK_UPTIME_RAW seconds of the next synthesized fire.
    private var synthNextFire: Double = 0
    private var synthInterval: Double = 1.0 / 60.0
    // Capture window: set for the duration of a fresh keyDown's processing.
    private var keyRepeatCaptureActive = false
    private var keyRepeatCapturedText: String? = nil
    private var keyRepeatCapturedCount = 0

    private static func uptimeNow() -> Double {
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
    }

    /// Record the held key after a fresh keyDown was processed.
    private func armHeldKey(code: UInt16, action: HeldKeyAction) {
        heldKeyCode = code
        heldKeyAction = action
    }

    private func disarmKeyRepeatSynthesis(_ reason: String) {
        if synthRepeatActive {
            ZonvieCore.appLog("[keyRepeat] disarm (\(reason))")
        }
        synthRepeatActive = false
        heldKeyCode = nil
        heldKeyAction = nil
    }

    /// First OS auto-repeat observed for the held key: take over the cadence.
    private func takeOverKeyRepeat() {
        // NSEvent.keyRepeatInterval mirrors the user's key-repeat setting.
        // Clamp defensively; 0 would spin and >1s is nonsense for repeats.
        synthInterval = max(1.0 / 120.0, min(1.0, NSEvent.keyRepeatInterval))
        synthRepeatActive = true
        synthNextFire = Self.uptimeNow() + synthInterval
        ZonvieCore.appLog("[keyRepeat] takeover keyCode=0x\(String(heldKeyCode ?? 0, radix: 16)) interval_ms=\(String(format: "%.2f", synthInterval * 1000.0))")
        // This OS repeat is replaced by an immediate synthesized one, then
        // the render clock paces the rest.
        replayHeldKey()
        activateDrawLoop()
    }

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

    /// Called from the renderer's draw entry every frame (main thread).
    /// No-op unless a synthesized repeat is armed.
    func tickKeyRepeatSynthesis() {
        guard synthRepeatActive else { return }
        // Safety net: lost keyUps (Cmd-Tab etc.) and IME activation must
        // never leave a key repeating forever.
        if hasMarkedText() || window?.isKeyWindow != true {
            disarmKeyRepeatSynthesis("safety")
            return
        }
        let now = Self.uptimeNow()
        // synthInterval can equal the draw tick period exactly (16.67ms repeat
        // on the 60Hz loop), making a bare `now >= synthNextFire` a per-tick
        // race: a tick arriving microseconds early skips an entire frame of
        // input (visible as a one-frame scroll stall). Fire when the due time
        // is closer to this tick than to the next one (half-tick tolerance).
        let tickPeriod = 1.0 / Double(max(1, preferredFramesPerSecond))
        guard now >= synthNextFire - min(tickPeriod, synthInterval) * 0.5 else { return }
        replayHeldKey()
        // At most one send per frame; if we fell behind (loop was paused),
        // re-anchor instead of bursting catch-up repeats.
        synthNextFire += synthInterval
        if synthNextFire < now {
            synthNextFire = now + synthInterval
        }
        activeDrawIdleFrames = 0
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
            ZonvieCore.appLog("[perf_input] seq=\(inputTrace.seq) stage=request_redraw delta_us=\(deltaUs)")
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
                ZonvieCore.appLog("[drawloop] activate: switching to continuous rendering")
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
        ZonvieCore.appLog("[drawloop] deactivate: switching to on-demand rendering (idle=\(activeDrawIdleFrames))")
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

        renderer.onPreDraw = { [weak self] in
            // Process pending scroll clears from grid_scroll events before rendering.
            // This ensures scroll offsets are cleared before vertices are drawn,
            // preventing double-shift glitches in split windows.
            self?.processPendingScrollClears()
            // Decay stale scroll offsets (pending scrolls that never got grid_scroll response,
            // e.g. when Neovim is at buffer boundary and can't scroll further).
            self?.decayStaleScrollOffsets()
            // Update shader with current scroll offsets (safe to call here on main thread).
            self?.updateScrollShaderOffset()
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
        }
    }

    deinit {
        scrollbarHideTimer?.invalidate()
        scrollbarHideTimer = nil
        msgTimer?.invalidate()
        msgTimer = nil
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

    /// Update scrollbar if viewport changed
    private func updateScrollbarIfNeeded() {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled else { return }
        guard let core else { return }
        guard let viewport = core.getViewport(gridId: -1) else { return }

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
        let viewport = core.getViewport(gridId: -1)

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

    private func maybeResizeCoreGrid() {
        guard let core else { return }

        let cellWi = max(1, Int(renderer.cellWidthPx.rounded(.toNearestOrAwayFromZero)))
        let cellHi = max(1, Int(renderer.cellHeightPx.rounded(.toNearestOrAwayFromZero)))

        let pxWi = max(1, Int(drawableSize.width))
        let pxHi = max(1, Int(drawableSize.height))

        // Move rows/cols decision + suppression to Zig core (shared logic).
        core.updateLayoutPx(
            drawableW: UInt32(pxWi),
            drawableH: UInt32(pxHi),
            cellW: UInt32(cellWi),
            cellH: UInt32(cellHi)
        )

        // Unblock the RPC thread's waitForLayoutReady() once we know real
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

        // Set screen width in cells for cmdline max width.
        // Must match the contentWidth constraint in resizeCmdlineWindow
        // to keep NDC viewport == drawable size.
        // TODO: Use window?.screen instead of NSScreen.main for multi-display correctness.
        //       All cmdline NSScreen.main usage (here and in ZonvieCore.swift) should be
        //       migrated to window?.screen in a coordinated change.
        if let screen = NSScreen.main {
            let scale = window?.backingScaleFactor ?? 2.0
            let cmdlinePad = ZonvieConfig.cmdlinePadding
            let cmdlineOverheadPt = cmdlinePad * 2 + ZonvieConfig.cmdlineIconTotalWidth + ZonvieConfig.cmdlineScreenMargin
            let availableWidthPt = screen.visibleFrame.width - cmdlineOverheadPt
            let availableWidthPx = availableWidthPt * scale
            let screenCols = UInt32(max(40, availableWidthPx / CGFloat(cellWi)))
            core.setScreenCols(screenCols)
        }
    }

    // Called from C-ABI callback: ensure glyph exists and return uv/metrics.
    func atlasEnsureGlyph(scalar: UInt32, out: UnsafeMutablePointer<zonvie_glyph_entry>) -> Bool {
        guard let e = renderer.atlasEnsureGlyphEntry(scalar: scalar) else { return false }

        out.pointee.uv_min.0 = e.uvMin.x
        out.pointee.uv_min.1 = e.uvMin.y
        out.pointee.uv_max.0 = e.uvMax.x
        out.pointee.uv_max.1 = e.uvMax.y

        out.pointee.bbox_origin_px.0 = e.bboxOriginPx.x
        out.pointee.bbox_origin_px.1 = e.bboxOriginPx.y
        out.pointee.bbox_size_px.0 = e.bboxSizePx.x
        out.pointee.bbox_size_px.1 = e.bboxSizePx.y

        out.pointee.advance_px = e.advancePx

        out.pointee.ascent_px = renderer.ascentPx
        out.pointee.descent_px = renderer.descentPx

        return true
    }

    func atlasEnsureGlyphStyled(scalar: UInt32, styleFlags: UInt32, out: UnsafeMutablePointer<zonvie_glyph_entry>) -> Bool {
        guard let e = renderer.atlasEnsureGlyphEntryStyled(scalar: scalar, styleFlags: styleFlags) else { return false }

        out.pointee.uv_min.0 = e.uvMin.x
        out.pointee.uv_min.1 = e.uvMin.y
        out.pointee.uv_max.0 = e.uvMax.x
        out.pointee.uv_max.1 = e.uvMax.y

        out.pointee.bbox_origin_px.0 = e.bboxOriginPx.x
        out.pointee.bbox_origin_px.1 = e.bboxOriginPx.y
        out.pointee.bbox_size_px.0 = e.bboxSizePx.x
        out.pointee.bbox_size_px.1 = e.bboxSizePx.y

        out.pointee.advance_px = e.advancePx

        out.pointee.ascent_px = renderer.ascentPx
        out.pointee.descent_px = renderer.descentPx

        return true
    }

    func submitVerticesRaw(
        mainPtr: UnsafeRawPointer?, mainCount: Int,
        cursorPtr: UnsafeRawPointer?, cursorCount: Int
    ) {
        // Process pending scroll clears BEFORE submitting new vertices.
        processPendingScrollClears()

        renderer.submitVerticesRaw(
            mainPtr: mainPtr, mainCount: mainCount,
            cursorPtr: cursorPtr, cursorCount: cursorCount
        )
        requestRedraw()

        // Update scrollbar on vertex submission
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollbarIfNeeded()
        }
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



    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int = 0) {
        // Process pending scroll clears BEFORE submitting new vertices.
        processPendingScrollClears()

        renderer.submitVerticesRowRaw(rowStart: rowStart, rowCount: rowCount, ptr: ptr, count: count, flags: flags, totalRows: totalRows)

        // Compute dirty rect in drawable pixel coordinates (TOP-ORIGIN to match vertexgen.ndc()).
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

        // Update scrollbar on vertex submission
        DispatchQueue.main.async { [weak self] in
            self?.updateScrollbarIfNeeded()
        }
    }

    func applyMainRowScrollRaw(rowStart: Int, rowEnd: Int, colStart: Int, colEnd: Int, rowsDelta: Int, totalRows: Int, totalCols: Int) {
        processPendingScrollClears()
        renderer.applyMainRowScrollRaw(
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
        guard drawableWPx > 0, hPx > 0 else { return }

        let rectPx = NSRect(
            x: 0,
            y: max(0, yFromTopPx),
            width: drawableWPx,
            height: hPx
        )
        requestRedrawDrawablePx(rectPx)
    }

    func applyLineSpace(px: Int32) {
        renderer.setLineSpace(px: px)

        // cell metrics changed (height)
        maybeResizeCoreGrid()

        // Ensure a redraw even if no new vertices arrive immediately.
        requestRedraw(nil)
    }

    override func keyDown(with event: NSEvent) {
        guard let core else { return }

        let m = event.modifierFlags

        // Check if Option key should be treated as Meta (Alt) based on config.
        // Left Option raw flag: 0x20, Right Option raw flag: 0x40.
        let optionIsMeta: Bool = {
            guard m.contains(.option) else { return false }
            // Read the runtime value from the core (atomic, lock-free).
            // Settable via :call rpcnotify(0, 'zonvie_option_as_meta', 'both')
            let val = core.getOptionAsMeta()
            switch val {
            case 0: return true                       // both
            case 1: return false                      // none
            case 2: return m.rawValue & 0x20 != 0     // only_left
            case 3: return m.rawValue & 0x40 != 0     // only_right
            default: return true
            }
        }()
        let hasControlOrCommand = m.contains(.control) || m.contains(.command) || optionIsMeta

        // evt_ts: NSEvent.timestamp (kernel event time, seconds since boot) in ms.
        // Comparing evt_ts deltas against handler-entry deltas separates the
        // repeat generator's cadence from main-runloop delivery quantization.
        ZonvieCore.appLog("[keyDown] keyCode=0x\(String(event.keyCode, radix: 16)) chars=\(event.characters ?? "") hasMarked=\(hasMarkedText()) ctrl/cmd=\(hasControlOrCommand) isRepeat=\(event.isARepeat) evt_ts=\(String(format: "%.3f", event.timestamp * 1000.0))")

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
        if hasMarkedText() {
            if event.keyCode == 0x35 {  // Escape: cancel composition
                unmarkText()
                inputContext?.discardMarkedText()
                return
            }
            // Let IME handle the key (Enter commits, arrows navigate, etc.)
            if let ctx = inputContext, ctx.handleEvent(event) {
                return
            }
            interpretKeyEvents([event])
            return
        }

        // No marked text: special keys or Ctrl/Cmd go directly to Neovim.
        let isSpecialKey = isSpecialKeyCode(event.keyCode)

        if hasControlOrCommand || isSpecialKey {
            var mods: UInt32 = 0
            if m.contains(.control) { mods |= UInt32(ZONVIE_MOD_CTRL) }
            if optionIsMeta          { mods |= UInt32(ZONVIE_MOD_ALT) }
            if m.contains(.shift)   { mods |= UInt32(ZONVIE_MOD_SHIFT) }
            if m.contains(.command) { mods |= UInt32(ZONVIE_MOD_SUPER) }

            // When Option is treated as Meta, use charactersIgnoringModifiers
            // as the primary characters to avoid macOS Option-transformed chars
            // (e.g. ƒ instead of f).  Neovim will see <A-f>, not <A-ƒ>.
            let chars = optionIsMeta ? event.charactersIgnoringModifiers : event.characters

            ZonvieCore.appLog("[keyDown] -> sendKeyEvent (special/mod) optMeta=\(optionIsMeta) chars=\(chars ?? "nil")")
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
            ZonvieCore.appLog("[keyDown] -> inputContext.handleEvent returned true")
            return
        }
        ZonvieCore.appLog("[keyDown] -> interpretKeyEvents fallback")
        // Fallback: interpret key events directly.
        interpretKeyEvents([event])
    }

    /// Returns true for special keycodes that should bypass IME.
    private func isSpecialKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x35: return true  // Escape
        case 0x7B, 0x7C, 0x7D, 0x7E: return true  // Arrow keys (left, right, down, up)
        case 0x24: return true  // Return
        case 0x30: return true  // Tab
        case 0x33: return true  // Delete (Backspace)
        case 0x75: return true  // Forward Delete
        case 0x73, 0x77: return true  // Home, End
        case 0x74, 0x79: return true  // Page Up, Page Down
        case 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64,
             0x65, 0x6D, 0x67, 0x6F: return true  // F1-F12
        default: return false
        }
    }

    // MARK: - Smooth Scrolling

    /// Scroll target locked at the start of a trackpad gesture. Subsequent
    /// events (including momentum) scroll this grid even if the pointer drifts
    /// over another grid. Cleared when the gesture and its momentum finish.
    private var lockedScrollTarget: (gridId: Int64, row: Int32, col: Int32)?

    override func scrollWheel(with event: NSEvent) {
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

    /// Update the shader uniform with current scroll offsets
    private func updateScrollShaderOffset() {
        guard let core else { return }

        let drawableHeight = Float(drawableSize.height)
        let cellHeightPx = Float(renderer.cellHeightPx)
        guard drawableHeight > 0 && cellHeightPx > 0 else { return }

        // Get grid info to look up margins and positions (non-blocking)
        let grids = core.getVisibleGridsCached()
        let gridInfoMap = Dictionary(uniqueKeysWithValues: grids.map { ($0.gridId, $0) })

        // Prune stale entries: remove gridIds that are no longer visible
        let visibleGridIds = Set(gridInfoMap.keys)
        scrollOffsetLock.lock()
        let staleKeys = scrollOffsetPx.keys.filter { !visibleGridIds.contains($0) }
        for key in staleKeys {
            scrollOffsetPx.removeValue(forKey: key)
        }

        // NDC scale: 2.0 / drawableHeight (top = 1.0, bottom = -1.0)
        let ndcScale: Float = 2.0 / drawableHeight

        var offsets: [MetalTerminalRenderer.ScrollOffsetInfo] = scrollOffsetPx.compactMap { (gridId, offsetPx) in
            guard let info = gridInfoMap[gridId] else { return nil }
            let clampedOffsetPx = clampVisualScrollOffsetPx(offsetPx, cellHeightPx: CGFloat(cellHeightPx))
            // Skip near-zero offsets to ensure offsets.isEmpty becomes true,
            // preventing markAllRowsDirty from firing every frame.
            guard abs(clampedOffsetPx) >= Self.scrollOffsetEpsilon else { return nil }

            // Calculate grid's top Y in NDC
            // Grid starts at startRow (in cells from top), each cell is cellHeightPx
            let gridTopPx = Float(info.startRow) * cellHeightPx
            // In NDC: top of screen = 1.0, so gridTopY = 1.0 - (gridTopPx * scale)
            let gridTopYNDC = 1.0 - gridTopPx * ndcScale

            return MetalTerminalRenderer.ScrollOffsetInfo(
                gridId: gridId,
                offsetYPx: Float(clampedOffsetPx),
                gridTopYNDC: gridTopYNDC,
                gridRows: info.rows,
                marginTop: info.marginTop,
                marginBottom: info.marginBottom
            )
        }
        scrollOffsetLock.unlock()

        // Propagate the underlying window's sub-cell offset to float windows that
        // sit over it. Neovim repositions floats discretely (cell granularity) on
        // every committed line scroll, but during the sub-line smooth phase the
        // buffer is shifted by offsetYPx while the float stays put. Shifting the
        // float by the same amount keeps it glued to the buffer line it annotates.
        // Floats carry their own grid_id with DECO_SCROLLABLE already set by the
        // core, so adding a scroll-offset entry is sufficient — no vertex regen.
        appendFloatScrollOffsets(into: &offsets, grids: grids, gridInfoMap: gridInfoMap, cellHeightPx: cellHeightPx, ndcScale: ndcScale)

        // Collect fixed (non-following) floats so the fragment shader can discard
        // scrolled content that would otherwise bleed over them while an adjacent
        // row is shifted. Only relevant while a smooth scroll is active.
        var fixedRects: [MetalTerminalRenderer.FixedFloatRect] = []
        if !offsets.isEmpty {
            let cellW = Float(renderer.cellWidthPx)
            let ndcXScale: Float = 2.0 / Float(drawableSize.width)
            for g in grids where g.zindex > 0 && g.gridId != 1 && !g.followsScroll {
                // A fixed float that is itself being scrolled (its own content,
                // because it is logically scrollable) must not mask its own
                // scrolled content — skip it so the guard never self-discards.
                if offsets.contains(where: { $0.gridId == g.gridId }) { continue }
                fixedRects.append(MetalTerminalRenderer.FixedFloatRect(
                    x0: Float(g.startCol) * cellW * ndcXScale - 1.0,
                    x1: Float(g.startCol + g.cols) * cellW * ndcXScale - 1.0,
                    top: 1.0 - Float(g.startRow) * cellHeightPx * ndcScale,
                    bottom: 1.0 - Float(g.startRow + g.rows) * cellHeightPx * ndcScale
                ))
            }
        }
        renderer.updateFixedFloatRects(fixedRects)

        renderer.updateScrollOffsets(offsets, drawableHeight: drawableHeight, cellHeightPx: cellHeightPx)

        if !offsets.isEmpty {
            renderer.markAllRowsDirty()
        }
    }

    /// Clear scroll offset for a specific grid (called when Neovim updates content)
    private func clearScrollOffset(gridId: Int64) {
        scrollOffsetLock.lock()
        scrollOffsetPx.removeValue(forKey: gridId)
        scrollOffsetLock.unlock()
        updateScrollShaderOffset()
    }

    /// Clear all scroll offsets
    private func clearAllScrollOffsets() {
        scrollOffsetLock.lock()
        scrollOffsetPx.removeAll()
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

        // grid=1 (global grid) does not support pixel-based smooth scrolling
        // gridId < 0 means Zonvie-managed external windows (ext_messages, ext_cmdline)
        // which don't receive grid_scroll events from Neovim
        var effectiveHasPrecise = hasPrecise && gridId > 1

        // Disable pixel scrolling for terminal UI tools (lazygit, tig, etc.)
        // Detection: terminal mode + cursor not visible (busy)
        // When a terminal UI tool is running, the cursor is typically hidden (busy_start).
        if effectiveHasPrecise {
            let mode = core.getCurrentMode()
            let cursorVisible = core.isCursorVisible()
            if mode == "terminal" && !cursorVisible {
                effectiveHasPrecise = false
            }
        }

        // Disable pixel scrolling for fast scrolling to prevent overwhelming Neovim
        // If deltaY is large (fast scroll), switch to cell-based scrolling
        if effectiveHasPrecise {
            let fastScrollThreshold = rowHeightPx / scale  // ~20 points at 2x scale
            if abs(deltaY) > fastScrollThreshold {
                effectiveHasPrecise = false
                // Clear any accumulated offset when switching to fast mode
                scrollOffsetLock.lock()
                scrollOffsetPx.removeValue(forKey: gridId)
                scrollStaleFrameCount.removeValue(forKey: gridId)
                scrollOffsetLock.unlock()
                pendingSentScrollLock.lock()
                pendingSentScroll.removeValue(forKey: gridId)
                pendingSentScrollLock.unlock()
            }
        }

        if effectiveHasPrecise {
            // Trackpad: implement sub-cell smooth scrolling for external grids
            let deltaYPx = deltaY * scale

            // Read pending scroll count OUTSIDE scrollOffsetLock to avoid deadlock
            pendingSentScrollLock.lock()
            let alreadyPending = pendingSentScroll[gridId] ?? 0
            pendingSentScrollLock.unlock()

            let maxTotalPending = 8
            let canSendMore = alreadyPending < maxTotalPending

            // Hold scrollOffsetLock for entire read-modify-write (TOCTOU fix).
            // processPendingScrollClears also acquires this lock, but it runs on the
            // core thread during flush, not concurrently with main-thread scroll input.
            scrollOffsetLock.lock()
            let currentOffset = scrollOffsetPx[gridId] ?? 0
            var newOffset = currentOffset + deltaYPx

            // When accumulated offset reaches row height, emit nvim_input_mouse.
            // Don't consume offset here — wait for grid_scroll response in
            // processPendingScrollClears to keep visual offset synchronized
            // with actual content movement (prevents flickering).
            var scrollCount = 0
            var checkOffset = newOffset
            while abs(checkOffset) >= rowHeightPx && canSendMore && scrollCount < 3 {
                let direction = checkOffset > 0 ? "up" : "down"
                core.sendMouseScroll(gridId: gridId, row: row, col: col, direction: direction, modifier: modifier)
                scrollCount += 1

                if checkOffset > 0 {
                    checkOffset -= rowHeightPx
                } else {
                    checkOffset += rowHeightPx
                }
            }

            // Clamp stored offset to the same visual range the renderer can display.
            // Keeping state and presentation aligned avoids input/render divergence
            // during sustained trackpad scrolling.
            newOffset = clampVisualScrollOffsetPx(newOffset, cellHeightPx: rowHeightPx)

            // Store final offset (atomic with read above — no TOCTOU gap)
            scrollOffsetPx[gridId] = newOffset
            // Reset stale counter — user is actively scrolling.
            // This prevents decayStaleScrollOffsets from fighting active user input.
            scrollStaleFrameCount[gridId] = 0
            scrollOffsetLock.unlock()

            // Track how many scroll commands we sent (outside scrollOffsetLock)
            if scrollCount > 0 {
                pendingSentScrollLock.lock()
                pendingSentScroll[gridId, default: 0] += scrollCount
                pendingSentScrollLock.unlock()
            }

            return newOffset
        } else {
            // Mouse wheel / fast scroll: send directly with acceleration
            let direction = deltaY > 0 ? "up" : "down"

            // Calculate scroll count based on speed (acceleration)
            let deltaYPx = abs(deltaY) * scale
            let scrollCount = max(1, Int(deltaYPx / rowHeightPx))

            for _ in 0..<scrollCount {
                core.sendMouseScroll(gridId: gridId, row: row, col: col, direction: direction, modifier: modifier)
            }
            return 0
        }
    }

    /// Get the current scroll offset for a grid.
    func getScrollOffset(gridId: Int64) -> CGFloat {
        scrollOffsetLock.lock()
        defer { scrollOffsetLock.unlock() }
        return clampVisualScrollOffsetPx(scrollOffsetPx[gridId] ?? 0, cellHeightPx: CGFloat(renderer.cellHeightPx))
    }

    /// Mark a grid for scroll offset clearing (thread-safe, can be called from any thread).
    /// Called from ZonvieCore when Neovim sends grid_scroll event.
    /// Each call increments the count so multiple grid_scroll events are not collapsed.
    func clearScrollOffsetForGrid(_ gridId: Int64) {
        pendingScrollClearLock.lock()
        pendingScrollClear[gridId, default: 0] += 1
        pendingScrollClearLock.unlock()
    }

    /// Decay stale scroll offsets. Called every frame from onPreDraw.
    /// When pendingSentScroll > 0 but no grid_scroll response arrives for several
    /// frames, the scroll likely hit a buffer boundary (Neovim can't scroll further).
    /// Decay the offset toward 0 over several frames to prevent it from getting stuck.
    private func decayStaleScrollOffsets() {
        let rowHeightPx = CGFloat(renderer.cellHeightPx)
        guard rowHeightPx > 0 else { return }

        // Threshold: ~10 frames at 60fps ≈ 166ms without grid_scroll response
        let staleThreshold = 10

        pendingSentScrollLock.lock()
        let pendingSnapshot = pendingSentScroll
        pendingSentScrollLock.unlock()

        // Only process grids that have pending sent scrolls
        guard !pendingSnapshot.isEmpty else {
            scrollStaleFrameCount.removeAll()
            return
        }

        scrollOffsetLock.lock()
        for (gridId, pendingCount) in pendingSnapshot {
            guard pendingCount > 0 else { continue }

            scrollStaleFrameCount[gridId, default: 0] += 1
            let staleFrames = scrollStaleFrameCount[gridId]!

            if staleFrames >= staleThreshold {
                let currentOffset = scrollOffsetPx[gridId] ?? 0
                if abs(currentOffset) < Self.scrollOffsetEpsilon {
                    // Close enough to 0 — clear everything
                    scrollOffsetPx.removeValue(forKey: gridId)
                    scrollStaleFrameCount.removeValue(forKey: gridId)
                    pendingSentScrollLock.lock()
                    pendingSentScroll.removeValue(forKey: gridId)
                    pendingSentScrollLock.unlock()
                    ZonvieCore.appLog("[decayStaleScroll] gridId=\(gridId) cleared (offset was \(currentOffset))")
                } else {
                    // Decay: reduce offset by ~30% per frame (converges in ~5 frames)
                    let decayed = currentOffset * 0.7
                    if abs(decayed) < Self.scrollOffsetEpsilon {
                        scrollOffsetPx.removeValue(forKey: gridId)
                        scrollStaleFrameCount.removeValue(forKey: gridId)
                        pendingSentScrollLock.lock()
                        pendingSentScroll.removeValue(forKey: gridId)
                        pendingSentScrollLock.unlock()
                        ZonvieCore.appLog("[decayStaleScroll] gridId=\(gridId) cleared after decay (was \(currentOffset) -> \(decayed))")
                    } else {
                        scrollOffsetPx[gridId] = decayed
                        ZonvieCore.appLog("[decayStaleScroll] gridId=\(gridId) decay offset=\(currentOffset) -> \(decayed) pending=\(pendingCount) staleFrames=\(staleFrames)")
                    }
                }
            }
        }
        scrollOffsetLock.unlock()
    }

    /// Process pending scroll clears (can be called from any thread).
    /// Does NOT call updateScrollShaderOffset() to avoid deadlock when called from Zig callback.
    /// Shader update will happen in onPreDraw before rendering.
    /// Public so external grid views can call this before their draw to stay in sync.
    func processPendingScrollClears() {
        pendingScrollClearLock.lock()
        let pending = pendingScrollClear
        pendingScrollClear.removeAll()
        pendingScrollClearLock.unlock()

        guard !pending.isEmpty else { return }

        let rowHeightPx = CGFloat(renderer.cellHeightPx)

        scrollOffsetLock.lock()
        for (gridId, scrollEventCount) in pending {
            // grid_scroll received — reset stale counter for this grid
            scrollStaleFrameCount.removeValue(forKey: gridId)

            // Check if this is a response to our scroll command or Neovim-initiated
            pendingSentScrollLock.lock()
            let sentCount = pendingSentScroll[gridId] ?? 0
            let currentOffset = scrollOffsetPx[gridId] ?? 0
            if sentCount > 0 {
                // Consume as many events as we have pending sent scrolls
                let toConsume = min(sentCount, scrollEventCount)
                pendingSentScroll[gridId] = sentCount - toConsume
                pendingSentScrollLock.unlock()

                // Consume rowHeightPx per grid_scroll event from stored offset.
                // This synchronizes visual offset reduction with actual content movement.
                var newOffset = currentOffset
                for _ in 0..<toConsume {
                    if newOffset > 0 {
                        newOffset -= rowHeightPx
                    } else if newOffset < 0 {
                        newOffset += rowHeightPx
                    }
                }
                // If there were more scroll events than sent scrolls,
                // the remaining are Neovim-initiated - clear offset
                if scrollEventCount > toConsume {
                    newOffset = 0
                }
                if abs(newOffset) < Self.scrollOffsetEpsilon {
                    scrollOffsetPx.removeValue(forKey: gridId)
                } else {
                    scrollOffsetPx[gridId] = newOffset
                }
                ZonvieCore.appLog("[processPendingScrollClears] gridId=\(gridId) events=\(scrollEventCount) sentCount=\(sentCount) consumed=\(toConsume) offset=\(currentOffset) -> \(newOffset)")
            } else {
                pendingSentScrollLock.unlock()
                // Neovim-initiated scroll (j/k keys, etc.) - clear offset
                scrollOffsetPx.removeValue(forKey: gridId)
                ZonvieCore.appLog("[processPendingScrollClears] gridId=\(gridId) events=\(scrollEventCount) nvim-initiated, clearing offset=\(currentOffset)")
            }
        }
        scrollOffsetLock.unlock()
        // Note: updateScrollShaderOffset() is called in onPreDraw, not here,
        // to avoid deadlock when this is called from Zig thread (which holds grid_mu).
    }

    /// Service shared smooth-scroll state for external windows that reuse the
    /// main view's scroll offset storage but do not run the main view's
    /// onPreDraw hook every frame.
    func serviceSharedScrollStateForExternalView() {
        processPendingScrollClears()
        decayStaleScrollOffsets()
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
        let cellW = max(1.0, CGFloat(Int(renderer.cellWidthPx.rounded(.toNearestOrAwayFromZero))))
        let cellH = max(1.0, CGFloat(Int(renderer.cellHeightPx.rounded(.toNearestOrAwayFromZero))))

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
    ) {
        // Nothing to propagate unless a window is actively being scrolled.
        guard !offsets.isEmpty else { return }

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

            let gridTopPx = Float(floatGrid.startRow) * cellHeightPx
            let gridTopYNDC = 1.0 - gridTopPx * ndcScale
            offsets.append(MetalTerminalRenderer.ScrollOffsetInfo(
                gridId: floatGrid.gridId,
                offsetYPx: offsetYPx,
                gridTopYNDC: gridTopYNDC,
                gridRows: floatGrid.rows,
                marginTop: 0,
                marginBottom: 0,
                clipToContent: false
            ))
        }
    }

    private func clampVisualScrollOffsetPx(_ offsetPx: CGFloat, cellHeightPx: CGFloat) -> CGFloat {
        let safeCellHeightPx = max(0, cellHeightPx)
        let maxOffsetPx = safeCellHeightPx * 2.0
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
            let cursor = core.getCursorPosition()
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
            let cursor = core.getCursorPosition()
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
        return .copy
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
        let mode = core.getCurrentMode()

        if mode.hasPrefix("cmdline") {
            // In command-line mode: insert paths at cursor position.
            core.sendInput(paths)
        } else {
            // In normal/insert/visual mode: execute :drop immediately.
            core.sendCommand("drop \(paths)")
        }
        return true
    }
}
