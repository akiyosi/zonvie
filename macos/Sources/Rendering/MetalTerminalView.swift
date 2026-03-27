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
    private var markedText: NSMutableAttributedString = NSMutableAttributedString()
    private var markedRange_: NSRange = NSRange(location: NSNotFound, length: 0)
    private var selectedRange_: NSRange = NSRange(location: 0, length: 0)
    private var _inputContext: NSTextInputContext?

    override var inputContext: NSTextInputContext? {
        if _inputContext == nil {
            _inputContext = NSTextInputContext(client: self)
        }
        return _inputContext
    }

    // Preedit overlay for showing IME composition text
    private lazy var preeditView: PreeditOverlayView = {
        let view = PreeditOverlayView()
        view.isHidden = true
        return view
    }()

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

    // --- Input throttling to prevent event accumulation during slow rendering ---
    private var pendingInput: String? = nil
    private let inputLock = NSLock()
    private var displayLink: CVDisplayLink?
    // Track if current key event is a repeat (for insertText to use)
    private var currentKeyEventIsRepeat: Bool = false
    
    private func dirtyLog(_ msg: @autoclosure () -> String) {
        if Self.dirtyLogEnabled {
            ZonvieCore.appLog(msg())
        }
    }

    // MARK: - Input Throttling (DisplayLink-based)

    /// Start the display link for input throttling
    private func startInputThrottling() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<MetalTerminalView>.fromOpaque(userInfo).takeUnretainedValue()
            view.displayLinkFired()
            return kCVReturnSuccess
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, callback, userInfo)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    /// Stop the display link
    private func stopInputThrottling() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    /// Called by display link at screen refresh rate
    private func displayLinkFired() {
        // Flush pending input on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Skip all work when minimized: the Zig core's grid state
            // must not be queried while the window is in the Dock.
            if self.window?.isMiniaturized == true { return }

            self.flushPendingInput()
            // Check msg_show throttle timeout (noice.nvim-style)
            self.core?.tickMsgThrottle()
            // Only poll viewport when a flush has occurred since last check.
            // This prevents bursts of getViewport calls after scrolling stops
            // while displayLink is still active.
            if self.flushSinceLastPoll {
                self.flushSinceLastPoll = false
                self.updateScrollbarIfNeeded()
            }
        }
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

    /// Try to send input, respecting throttling for repeat events
    private func trySendInput(_ text: String, isRepeat: Bool) -> Bool {
        // For repeat events, queue and let display link flush when idle.
        // This ensures input is only sent when rendering is complete,
        // preventing accumulation when rendering is slow.
        if isRepeat {
            inputLock.lock()
            pendingInput = text
            inputLock.unlock()
            return true
        }

        // Non-repeat: send immediately
        core?.sendInput(text)
        return true
    }

    /// Flush pending input (called by display link)
    /// Sends pending input immediately without waiting for redraw completion.
    /// With fast rendering (~1.5ms), waiting for redraw adds unnecessary latency.
    private func flushPendingInput() {
        inputLock.lock()
        let pending = pendingInput
        pendingInput = nil
        inputLock.unlock()

        if let text = pending {
            core?.sendInput(text)
        }
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

    // INSERT near requestRedraw(_:)
    
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
        framebufferOnly = false

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

        // Add preedit overlay for IME composition
        addSubview(preeditView)

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
            startInputThrottling()

            // Ensure layer transparency settings are applied after window is available
            if ZonvieConfig.shared.blurEnabled {
                self.layer?.isOpaque = false
                self.layer?.backgroundColor = NSColor.clear.cgColor
            } else {
                self.layer?.isOpaque = true
                self.layer?.backgroundColor = NSColor.black.cgColor
            }
        } else {
            stopInputThrottling()
        }
    }

    deinit {
        stopInputThrottling()
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

    /// Set when a flush completes; consumed by displayLinkFired to gate
    /// viewport polling. Without this, displayLink calls getViewport every
    /// tick (~60fps) even when nothing has changed, causing bursts of
    /// redundant calls after scrolling stops. Only accessed on main thread.
    private var flushSinceLastPoll = false

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
            self?.flushSinceLastPoll = true
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
            self?.flushSinceLastPoll = true
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

        // Track repeat status for input throttling in insertText
        currentKeyEventIsRepeat = event.isARepeat

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

        ZonvieCore.appLog("[keyDown] keyCode=0x\(String(event.keyCode, radix: 16)) chars=\(event.characters ?? "") hasMarked=\(hasMarkedText()) ctrl/cmd=\(hasControlOrCommand) isRepeat=\(event.isARepeat)")

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
            return
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

    override func keyUp(with event: NSEvent) {
        // Clear any pending input when key is released.
        // This prevents accumulated input from continuing after the user stops.
        inputLock.lock()
        let hadPending = pendingInput != nil
        pendingInput = nil
        inputLock.unlock()

        if hadPending {
            ZonvieCore.appLog("[keyUp] cleared pending input")
        }
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

    override func scrollWheel(with event: NSEvent) {
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        if deltaY == 0 && deltaX == 0 { return }

        // Get cursor position in cell coordinates
        let location = convert(event.locationInWindow, from: nil)
        let (gridId, row, col) = hitTestGrid(at: location, adjustForSmoothScroll: false)

        let scale = window?.backingScaleFactor ?? 2.0

        // Build modifier string for scroll event
        let modifier = buildModifierString(from: event.modifierFlags)

        // Vertical scroll
        if deltaY != 0 {
            ZonvieCore.appLog("[scroll] deltaY=\(deltaY) hasPrecise=\(event.hasPreciseScrollingDeltas) gridId=\(gridId)")

            let newOffset = handleScrollInput(
                gridId: gridId,
                row: row,
                col: col,
                deltaY: deltaY,
                scale: scale,
                hasPrecise: event.hasPreciseScrollingDeltas,
                modifier: modifier
            )

            if event.hasPreciseScrollingDeltas {
                ZonvieCore.appLog("[scroll] stored offset=\(newOffset) updating shader...")
                updateScrollShaderOffset()
                requestRedraw()
            }
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

        let offsets: [MetalTerminalRenderer.ScrollOffsetInfo] = scrollOffsetPx.compactMap { (gridId, offsetPx) in
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

    /// Clamp visual scroll offset to the range the shader can actually display.
    private func clampVisualScrollOffsetPx(_ offsetPx: CGFloat, cellHeightPx: CGFloat) -> CGFloat {
        let safeCellHeightPx = max(0, cellHeightPx)
        let maxOffsetPx = safeCellHeightPx * 2.0
        guard maxOffsetPx > 0 else { return 0 }
        return max(-maxOffsetPx, min(maxOffsetPx, offsetPx))
    }
}

// MARK: - NSTextInputClient (IME support)
extension MetalTerminalView: NSTextInputClient {

    /// Called when IME commits composed text or when direct character input occurs.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            ZonvieCore.appLog("[IME] insertText: unknown type, ignoring")
            return
        }

        ZonvieCore.appLog("[IME] insertText: \"\(text)\" core=\(core != nil ? "set" : "nil")")

        // Clear marked text state and hide preedit overlay.
        markedText = NSMutableAttributedString()
        markedRange_ = NSRange(location: NSNotFound, length: 0)
        hidePreeditOverlay()

        // Send committed text to Neovim with frame-synchronized throttling.
        // For repeat events during slow rendering, input may be queued or dropped.
        let sent = trySendInput(text, isRepeat: currentKeyEventIsRepeat)
        if !sent {
            ZonvieCore.appLog("[IME] insertText: input dropped (rendering slow, already have pending)")
        }
        // Reset repeat flag
        currentKeyEventIsRepeat = false
    }

    /// Called during IME composition to show uncommitted text.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? String {
            markedText = NSMutableAttributedString(string: s)
        } else if let attr = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attr)
        } else {
            markedText = NSMutableAttributedString()
        }

        ZonvieCore.appLog("[IME] setMarkedText: \"\(markedText.string)\" selectedRange=\(selectedRange)")

        if markedText.length > 0 {
            markedRange_ = NSRange(location: 0, length: markedText.length)
            showPreeditOverlay(attributedText: markedText, selectedRange: selectedRange)
        } else {
            markedRange_ = NSRange(location: NSNotFound, length: 0)
            hidePreeditOverlay()
        }
        selectedRange_ = selectedRange
    }

    /// Show the preedit overlay with the given attributed text.
    private func showPreeditOverlay(attributedText: NSAttributedString, selectedRange: NSRange) {
        let scale = window?.backingScaleFactor ?? 2.0
        let cellW = CGFloat(renderer.cellWidthPx) / scale
        let cellH = CGFloat(renderer.cellHeightPx) / scale

        // Use the actual font from renderer
        let fontName = renderer.currentFontName
        let pointSize = renderer.currentPointSize
        let font = NSFont(name: fontName, size: pointSize) ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)

        // Configure preedit view with attributed text (preserves IME underline info)
        preeditView.configure(
            attributedText: attributedText,
            selectedRange: selectedRange,
            font: font,
            cellWidth: cellW,
            cellHeight: cellH
        )

        // Position at cursor location
        positionPreeditOverlay()

        preeditView.isHidden = false
    }

    /// Position the preedit overlay at the cursor location.
    private func positionPreeditOverlay() {
        let scale = window?.backingScaleFactor ?? 2.0
        let cellW = CGFloat(renderer.cellWidthPx) / scale
        let cellH = CGFloat(renderer.cellHeightPx) / scale

        // Get cursor position from core if available
        if let core = core {
            let cursor = core.getCursorPosition()
            if cursor.row >= 0 && cursor.col >= 0 {
                // Cursor position is grid-local. We need to find the grid's screen position.
                var screenRow = Int(cursor.row)
                var screenCol = Int(cursor.col)

                // Find the grid and add its startRow/startCol for screen position (non-blocking)
                let grids = core.getVisibleGridsCached()
                for grid in grids {
                    if grid.gridId == cursor.gridId {
                        screenRow = Int(grid.startRow) + Int(cursor.row)
                        screenCol = Int(grid.startCol) + Int(cursor.col)
                        break
                    }
                }

                // Calculate position in view coordinates (bottom-origin)
                // Row 0 is at the top, so we need to flip the Y coordinate
                let x = CGFloat(screenCol) * cellW
                let y = bounds.height - CGFloat(screenRow + 1) * cellH

                preeditView.frame.origin = CGPoint(x: x, y: y)
                return
            }
        }

        // Fallback: position near top-left
        preeditView.frame.origin = CGPoint(x: cellW, y: bounds.height - cellH - preeditView.frame.height)
    }

    /// Hide the preedit overlay.
    private func hidePreeditOverlay() {
        preeditView.isHidden = true
        preeditView.clear()
    }

    /// Called when IME composition is cancelled.
    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedRange_ = NSRange(location: NSNotFound, length: 0)
        hidePreeditOverlay()
    }

    /// Returns the range of the current marked (composing) text.
    func markedRange() -> NSRange {
        return markedRange_
    }

    /// Returns the range of the currently selected text.
    func selectedRange() -> NSRange {
        return selectedRange_
    }

    /// Returns whether there is currently marked (composing) text.
    func hasMarkedText() -> Bool {
        return markedRange_.location != NSNotFound && markedRange_.length > 0
    }

    /// Returns valid attributes for marked text styling.
    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return [.underlineStyle, .foregroundColor, .backgroundColor]
    }

    /// Returns the attributed string for the given range (used by IME).
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // We don't maintain a full text buffer; return nil.
        return nil
    }

    /// Returns the rectangle for the character at the given index.
    /// Used by IME to position the candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return cursor position in screen coordinates for IME candidate window placement.
        guard let win = window else { return .zero }

        let scale = win.backingScaleFactor
        let cellW = CGFloat(renderer.cellWidthPx) / scale
        // cellHeightPx already includes linespace
        let rowH = CGFloat(renderer.cellHeightPx) / scale

        // Get actual cursor position from core (grid-local)
        var screenRow = 0
        var screenCol = 0

        if let core = core {
            let cursor = core.getCursorPosition()
            if cursor.row >= 0 && cursor.col >= 0 {
                screenRow = Int(cursor.row)
                screenCol = Int(cursor.col)

                // Find the grid and add its startRow/startCol for screen position (non-blocking)
                let grids = core.getVisibleGridsCached()
                for grid in grids {
                    if grid.gridId == cursor.gridId {
                        screenRow = Int(grid.startRow) + Int(cursor.row)
                        screenCol = Int(grid.startCol) + Int(cursor.col)
                        break
                    }
                }
            }
        }

        let cursorXPt = CGFloat(screenCol) * cellW
        // NSView uses bottom-origin, cursor cell bottom is at this Y
        let cursorYPt = bounds.height - CGFloat(screenRow + 1) * rowH

        // Return rect at cursor position - IME will place candidate window below this rect
        let rectInView = NSRect(x: cursorXPt, y: cursorYPt, width: cellW, height: rowH)
        let rectInWindow = convert(rectInView, to: nil)
        let rectInScreen = win.convertToScreen(rectInWindow)
        ZonvieCore.appLog("[IME] firstRect: screenRow=\(screenRow) screenCol=\(screenCol) cellW=\(cellW) rowH=\(rowH) bounds=\(bounds) rectInView=\(rectInView) rectInScreen=\(rectInScreen)")
        return rectInScreen
    }

    /// Returns the character index closest to the given point.
    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    /// Handle unbound key commands from interpretKeyEvents.
    override func doCommand(by selector: Selector) {
        // Some keys (like arrow keys during IME) may come through here.
        // For most terminal usage, we can ignore these or handle specific selectors.
    }
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
