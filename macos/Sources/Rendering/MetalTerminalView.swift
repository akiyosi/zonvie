import Cocoa
import CoreVideo
import MetalKit

/// A view that can hold a key for repeat synthesis: this one, or an external
/// window's grid view. The synthesizer needs nothing from it but its window
/// and its IME state.
typealias KeyRepeatOwner = NSView & NSTextInputClient

/// Neovim's name for an AppKit "other" mouse button, or nil for one it has no
/// name for.
///
/// Both surfaces carried the same switch. It answers a question about the
/// Neovim protocol, not about either view, so it belongs to neither.
func surfaceOtherMouseButtonName(_ buttonNumber: Int) -> String? {
    switch buttonNumber {
    case 2: return "middle"
    case 3: return "x1"
    case 4: return "x2"
    default: return nil
    }
}

/// Neovim's modifier prefix for a mouse event ("S", "C", "A", "D").
func neovimModifierString(_ flags: NSEvent.ModifierFlags) -> String {
    var mods: UInt32 = 0
    if flags.contains(.shift) { mods |= UInt32(ZONVIE_MOD_SHIFT) }
    if flags.contains(.control) { mods |= UInt32(ZONVIE_MOD_CTRL) }
    if flags.contains(.option) { mods |= UInt32(ZONVIE_MOD_ALT) }
    if flags.contains(.command) { mods |= UInt32(ZONVIE_MOD_SUPER) }
    var buf = [CChar](repeating: 0, count: 5)
    _ = zonvie_core_mouse_modifiers(mods, &buf)
    return String(cString: buf)
}

/// One surface's scrollbar: which grid its knob shows, when the knob moves,
/// shows and hides, and what a click or drag on it asks the core for.
///
/// The main window and every external window carried a copy of this, about
/// 150 lines each, and they had drifted: the external one had no retry for a
/// busy core lock (so its knob stayed stale after the last flush of a scroll
/// burst), no first-show, no estimated knob after a page click, ignored the
/// knob slot's part on one side and not the other, and showed only in "scroll"
/// mode. Hover tracking is GridInputView's, one rule for both.
///
/// A knob drag is throttled to one scroll per interval with a trailing send
/// for the last position. The main window used to flush that last position
/// from its own mouseUp, which the scroller's tracking loop consumes, so the
/// final position of a quick drag could be sent on the next unrelated click.
final class SurfaceScrollbarController {
    private weak var scroller: NSScroller?
    private let surfaceId: Int64
    private let core: () -> ZonvieCore?

    private var hideTimer: Timer?
    private var lastViewportTopline: Int64 = -1
    private var lastViewportLineCount: Int64 = -1
    private var lastViewportBotline: Int64 = -1
    /// The grid the knob is showing, kept across a busy lock.
    private var lastGrid: Int64
    /// Last grid `[scrollbar]` named, so the line is a transition.
    private var lastGridLogged: Int64 = 0
    private var retryScheduled = false
    private static let dragThrottleInterval: TimeInterval = 0.016
    private var lastDragSendTime: CFAbsoluteTime = 0
    private var pendingDrag: (line: Int64, useBottom: Bool)?
    private var trailingDragScheduled = false

    /// `surfaceId` is 1 for the main window, an external window's root grid
    /// id for its own.
    init(scroller: NSScroller, surfaceId: Int64, core: @escaping () -> ZonvieCore?) {
        self.scroller = scroller
        self.surfaceId = surfaceId
        self.lastGrid = surfaceId
        self.core = core
    }

    func invalidate() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    /// The grid this surface's scrollbar ACTS on, which has to be the one it
    /// shows — a float an external window hosts included.
    private var interactionGrid: Int64 {
        let g = core()?.scrollbarGridNonBlocking(surfaceId: surfaceId) ?? lastGrid
        // Rare — a page or a drag, not a frame — and the only trace of which
        // window a scrollbar acts on.
        ZonvieCore.appLog("[scrollbar_action] surface=\(surfaceId) grid=\(g)")
        return g
    }

    /// Move the knob to the viewport of the grid this surface shows, once per
    /// change. Called after each flush or drawn frame.
    func update() {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled, let core = core() else { return }
        // On a busy lock keep the grid the knob is already showing, so the
        // stale-viewport retry below still runs — returning here would skip it.
        let grid = core.scrollbarGridNonBlocking(surfaceId: surfaceId) ?? lastGrid
        lastGrid = grid
        var lockBusy = false
        let viewportOrStale = core.getViewportNonBlocking(gridId: grid, lockBusy: &lockBusy)
        if lockBusy, !retryScheduled {
            // grid_mu was held (core thread mid-handleRedraw): the value above
            // is the one-flush-stale cache, and the FINAL flush of a scroll
            // burst has no later flush to heal it. One-shot retry, as
            // windows/ui/scrollbar.zig's TIMER_SCROLLBAR_RETRY (16ms).
            retryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                self?.retryScheduled = false
                self?.update()
            }
        }
        guard let viewport = viewportOrStale else { return }

        let changed = viewport.topline != lastViewportTopline ||
                      viewport.lineCount != lastViewportLineCount ||
                      viewport.botline != lastViewportBotline ||
                      lastViewportTopline == -1
        // A page click's estimated knob stands until this reports a change:
        // an unchanged viewport moves nothing.
        if !changed { return }
        // One line per change, not per flush: which grid a knob follows has
        // no other trace.
        if ZonvieCore.appLogEnabled, grid != lastGridLogged || viewport.topline != lastViewportTopline {
            lastGridLogged = grid
            ZonvieCore.appLog("[scrollbar] surface=\(surfaceId) grid=\(grid) topline=\(viewport.topline) lineCount=\(viewport.lineCount)")
        }
        lastViewportTopline = viewport.topline
        lastViewportLineCount = viewport.lineCount
        lastViewportBotline = viewport.botline
        scroller?.apply(viewport.scrollbarMetrics, alwaysVisible: config.isAlways)
        if config.isScroll || config.isAlways {
            show()
        }
    }

    func show() {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled, let scroller else { return }
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            scroller.animator().alphaValue = CGFloat(config.opacity)
        }
        // Auto-hide after the delay, only in "scroll" mode.
        if config.isScroll && !config.isAlways {
            hideTimer = Timer.scheduledTimer(withTimeInterval: config.delay, repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }

    func hide() {
        let config = ZonvieConfig.shared.scrollbar
        if config.isAlways { return }
        guard let scroller else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            scroller.animator().alphaValue = 0.0
        }
    }

    /// The scroller's action: a page click or a knob drag.
    func scrollerDidScroll(_ sender: NSScroller) {
        guard let core = core() else { return }
        // Read and act on the same grid: the one the knob shows. Viewport may
        // be nil before Neovim reports one; paging does not need it.
        let target = interactionGrid
        let viewport = core.getViewportNonBlocking(gridId: target)

        switch sender.hitPart {
        case .decrementPage, .incrementPage:
            let forward = sender.hitPart == .incrementPage
            // Neovim's own page step (<C-f>/<C-b>), one RPC.
            core.pageScroll(gridId: target, forward: forward)
            // Move the knob to an estimate now; update() leaves it until the
            // viewport actually moves.
            // The topline is 0-based and the knob position is the core's
            // (scrollbar_metrics), so the estimate lands where update() will.
            if var estimate = viewport {
                let visible = estimate.botline - estimate.topline
                let step = max(1, visible - 2)
                let top = estimate.topline + (forward ? step : -step)
                estimate.topline = max(0, min(estimate.lineCount - visible, top))
                estimate.botline = estimate.topline + visible
                sender.doubleValue = estimate.scrollbarMetrics.scroll_position
            }

        case .knob, .knobSlot:
            guard let viewport else { break }
            // The core's rule, shared with Windows: the lower half of the
            // travel aligns to the bottom, the only way to reach the last line.
            let drag = viewport.dragTarget(ratio: sender.doubleValue)
            sendDrag(line: drag.line, useBottom: drag.use_bottom != 0, target: target)

        default:
            break
        }
        // Keep the scrollbar visible while interacting.
        show()
    }

    private func sendDrag(line: Int64, useBottom: Bool, target: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastDragSendTime >= Self.dragThrottleInterval {
            core()?.scrollToLine(gridId: target, line, useBottom: useBottom)
            lastDragSendTime = now
            pendingDrag = nil
            return
        }
        pendingDrag = (line, useBottom)
        guard !trailingDragScheduled else { return }
        trailingDragScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragThrottleInterval) { [weak self] in
            guard let self else { return }
            self.trailingDragScheduled = false
            guard let pending = self.pendingDrag else { return }
            self.pendingDrag = nil
            self.lastDragSendTime = CFAbsoluteTimeGetCurrent()
            self.core()?.scrollToLine(gridId: self.interactionGrid, pending.line, useBottom: pending.useBottom)
        }
    }
}

final class MetalTerminalView: GridInputView {
    var renderer: GridSurfaceRenderer!

    override var sharedResources: SharedRenderResources { renderer.shared }

    override var dropInsertsPath: Bool { bufferDropInsertsPath }

    /// Expose drawable size without requiring MetalKit import at call site.
    var currentDrawableSize: CGSize { drawableSize }

    override weak var core: ZonvieCore? {
        didSet {
            core?.requestRedraw = { [weak self] in
                DispatchQueue.main.async {
                    self?.setNeedsDisplay(self?.bounds ?? .zero)
                }
            }
        }
    }

    private static var dirtyLogEnabled: Bool { ZonvieCore.appLogEnabled }

    // Persistent scratch buffers for updateScrollShaderOffset, reused via
    // removeAll(keepingCapacity: true) instead of building fresh arrays
    // (compactMap/etc.) every call — this runs in the pre-draw path on
    // every scrolled frame.
    private var scrollOffsetInfoScratch: [GridSurfaceRenderer.ScrollOffsetInfo] = []
    /// Set when the last offset update dropped the scroll transform (offset
    /// set overflowed), so the frame is cell-aligned. Main thread.
    private var drewWithoutScrollTransform = false
    private var gridInfoMapScratch: [Int64: ZonvieCore.GridInfo] = [:]
    private var visibleGridIdsScratch: Set<Int64> = []
    // Tracks whether the previous updateScrollShaderOffset call had any
    // offsets, so the idle (empty) case can skip rebuilding the
    // Dictionary/Set/array below every frame while still running the one
    // "just went empty" transition call that clears the renderer's state.
    private var hadScrollOffsetsLastCall = false

    /// Upper bound on the total scroll-offset entry count (directly-scrolled
    /// windows + followed floats combined) passed to the renderer each
    /// frame. The vertex shader uses binary search, but CPU preparation and
    /// setVertexBytes'/GPU-buffer cost still grow with this count. This is
    /// comfortably above any realistic simultaneous scroll-source count.
    static let maxScrollOffsets = 128

    /// The anchor counters as the frame's offsets saw them. Main thread only,
    /// filled inside the hold that reads scrollOffsetPx.
    private var anchorLandedRowsUpScratch: [Int64: Int] = [:]

    private func dirtyLog(_ msg: @autoclosure () -> String) {
        if Self.dirtyLogEnabled {
            ZonvieCore.appLog(msg())
        }
    }

    /// Called after actual drawing runs in MTKViewDelegate.draw(in:)
    func didDrawFrame() {
        redrawScheduler.didDrawFrame()
        dirtyLog("didDrawFrame: redrawPending reset to false")
    }


    // MARK: - Active Draw Loop

    override func hadRecentCommit(withinNs: UInt64) -> Bool {
        renderer?.hadRecentCommit(withinNs: withinNs) == true
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

    /// Test only: with ZONVIE_TEST_FULL_REDRAW=1, SIGUSR2 forces the next frame
    /// to redraw everything, so a gui-test can compare it with the partial
    /// frame before it.
    private var testFullRedrawSource: DispatchSourceSignal?

    private func installTestFullRedrawHandler() {
        guard ProcessInfo.processInfo.environment["ZONVIE_TEST_FULL_REDRAW"] == "1" else { return }
        signal(SIGUSR2, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let renderer = self.renderer else { return }
            renderer.forceFullRedrawForTest()
            self.requestRedraw()
        }
        src.resume()
        testFullRedrawSource = src
    }

    private func commonInit() {
        FrameTracer.installDumpHandler()
        installTestFullRedrawHandler()
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

        guard let newRenderer = GridSurfaceRenderer(view: self) else {
            ZonvieCore.appLog("[View] Failed to create GridSurfaceRenderer")
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
            self?.scrollModel?.publishStagedScrollClears()
        }

        renderer.onBeforeCommittedSnapshot = { [weak self] in
            guard let self else { return }
            self.scrollModel?.processPendingScrollClears()
            self.updateScrollShaderOffset()
        }

        renderer.onPreDraw = { [weak self] in
            self?.scrollModel?.serviceFrame()
            // Keep the draw loop alive while an edge bounce is held/animating,
            // so the bounce-back keeps ticking after input events stop.
            if let self, self.isPaused, self.scrollModel?.isScrollEdgeBounceActive() == true {
                self.activateSurfaceDrawLoop()
            }
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
        applyLayerTransparency()

        // The IME preedit overlay is added to this view lazily by IMEPreeditController.

        installScrollbar()

        registerFileDrops()
    }

    /// The layer's transparency, which follows the blur setting. Applied when
    /// the view is set up and again once it has a window: the second call is
    /// not a repeat of the first, it is the point at which AppKit has a layer
    /// to apply it to.
    private func applyLayerTransparency() {
        if ZonvieConfig.shared.blurEnabled {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            self.layer?.isOpaque = true
            self.layer?.backgroundColor = NSColor.black.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        needsLayout = true

        if window != nil {
            window?.acceptsMouseMovedEvents = true

            // Ensure layer transparency settings are applied after window is available
            applyLayerTransparency()
        } else {
            core?.cancelMsgTimer()
        }
    }

    // MARK: - Mouse Input

    override func resolvePointerTarget(_ event: NSEvent, requireScrollable: Bool) -> (gridId: Int64, row: Int32, col: Int32) {
        hitTestGrid(at: convert(event.locationInWindow, from: nil))
    }

    override func rebaseToPinnedGrid(_ event: NSEvent, pinned: Int64) -> (gridId: Int64, row: Int32, col: Int32)? {
        guard let core, let g = pointerGeometry(at: convert(event.locationInWindow, from: nil)) else { return nil }
        // The pinned grid closed mid-drag: the surface's root grid in
        // global cells, as Windows' rebaseToGrid, never the window under
        // the pointer.
        guard let current = core.getVisibleGridsCached().first(where: { $0.gridId == pinned }) else {
            return (1, g.globalRow, g.globalCol)
        }
        let localRow: Int32
        if let followerOffsetPx = drawnFollowerOffsetsPx()[pinned] {
            // A follower is drawn displaced bodily and has no ease of its
            // own to undo.
            localRow = Int32(((g.pointPx.y - followerOffsetPx) / g.cellH).rounded(.down)) - current.startRow
        } else {
            localRow = scrollAdjustedLocalRow(
                pointPxY: g.pointPx.y,
                cellHeightPx: g.cellH,
                band: GridRowBand(of: current),
                scrollOffsetPx: drawnScrollOffsetPx(pinned, cellH: g.cellH)
            )
        }
        return (pinned, localRow, g.globalCol - current.startCol)
    }

    override func layout() {
        super.layout()
        ZonvieCore.appLog("[DEBUG-LAYOUT] bounds=\(bounds) drawableSize=\(drawableSize)")
        updateDrawableSizeIfPossible()
    }

    // The cell a click here would name, ease undone: hovering read the drawn
    // row, so mid-ease the hand showed over a row a click missed.
    override func urlHoverCell(at location: CGPoint) -> (gridId: Int64, row: Int32, col: Int32)? {
        hitTestGrid(at: location)
    }

    /// Another surface's start_row and start_col are in that surface's space,
    /// so only a cursor this window draws has a rect here.
    override func imeCursorRectInView() -> NSRect? {
        guard let core else { return nil }
        let cursor = core.getCursorPositionNonBlocking()
        guard cursor.row >= 0, cursor.col >= 0, core.showingSurfaceId(for: cursor.gridId) == 1 else { return nil }
        // Cursor is grid-local; add the grid's screen offset.
        var screenRow = Int(cursor.row)
        var screenCol = Int(cursor.col)
        for grid in core.getVisibleGridsCached() where grid.gridId == cursor.gridId {
            screenRow = Int(grid.startRow) + Int(cursor.row)
            screenCol = Int(grid.startCol) + Int(cursor.col)
            break
        }
        let cell = imePreeditCellSize
        return NSRect(x: CGFloat(screenCol) * cell.width,
                      y: bounds.height - CGFloat(screenRow + 1) * cell.height,
                      width: cell.width, height: cell.height)
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

        let generationBefore = renderer.glyphAtlas.fontGenerationSnapshot()
        renderer.setBackingScale(scale)
        // A backing-scale change rebuilds the font and clears the atlas caches,
        // bumping the same generation guifont bumps. The external surfaces gate
        // their committed rows on it, so without this fan-out they kept naming
        // the old generation and drew stale rows against the rebuilt atlas.
        let generationAfter = renderer.glyphAtlas.fontGenerationSnapshot()
        if generationAfter != generationBefore {
            core?.stageFontGenerationOnExternalSurfaces(generationAfter)
        }

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

        let (cellWi, cellHi) = renderer.coreCellPx

        let pxWi = max(1, Int(drawableSize.width))
        let pxHi = max(1, Int(drawableSize.height))

        // The cmdline's width budget in cells. Must match the contentWidth
        // constraint in buildDecoratedCmdlineLayout to keep NDC viewport ==
        // drawable size. Computed before the core call so it can ride the same
        // grid_mu acquisition instead of locking twice.
        let scale = window?.backingScaleFactor ?? 2.0
        // Chrome that sits beside the cmdline grid inside its own window.
        let copyButtonPt = ZonvieConfig.shared.cmdline.copyButton ? ZonvieConfig.copyButtonTotalWidth : 0.0
        let cmdlineChromePt = ZonvieConfig.cmdlinePadding * 2 + ZonvieConfig.cmdlineIconTotalWidth + copyButtonPt
        let workWidthPt = (window?.screen ?? NSScreen.main)?.visibleFrame.width ?? 0
        let mainWidthPt = window?.frame.width ?? 0
        var screenCols: UInt32 = 0
        var cmdlineDefaultCols: UInt32 = 0
        zonvie_core_cmdline_cols(
            UInt32(max(0, workWidthPt * scale)),
            UInt32(max(0, mainWidthPt * scale)),
            UInt32(cmdlineChromePt * scale),
            UInt32(ZonvieConfig.cmdlineScreenMargin * scale),
            UInt32(cellWi),
            &screenCols,
            &cmdlineDefaultCols
        )

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




    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int, totalCols: Int) {
        scrollModel?.processPendingScrollClears()

        renderer.submitVerticesRowRaw(rowStart: rowStart, rowCount: rowCount, ptr: ptr, count: count, flags: flags, totalRows: totalRows, totalCols: totalCols)

        let update = VertexRowUpdate(flags: flags)
        let isZeroCellLayout =
            rowCount == 0
            && count == 0
            && update == .main
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

    
        let rectPx = NSRect(
            x: 0,
            y: max(0, yFromTopPx),
            width: drawableWPx,
            height: hPx
        )


    
        // A cursor-only callback marks no row damage: the renderer records the
        // commit as cursor-only and reuses the surface, exactly as
        // ExternalGridView does. A row marked here would instead band that row,
        // redraw it, and pull every layer crossing it into the frame. The
        // redraw request below still schedules the frame.
        if update != .cursorOnly {
            renderer.markDirtyRows(rowStart: rowStart, rowCount: rowCount)
        }
    

    
        requestRedrawDrawablePx(rectPx)
    }

    // MARK: - Smooth Scrolling

    private var scrollTargetLock = ScrollTargetLock()

    private var scrollModel: SessionScrollModel? { core?.scrollModel }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        scrollModel?.handleGridScrollWheel(
            event, lock: &scrollTargetLock, scale: window?.backingScaleFactor ?? 2.0, logTag: "scroll",
            resolve: { hitTestGrid(at: location, requireScrollable: $0) },
            // Shader uniforms are propagated in onPreDraw (which always runs
            // updateScrollShaderOffset before draw); calling it here too would
            // re-do the same work and fire markAllRowsDirty twice per input.
            afterPrecise: { _ in requestRedraw() })
    }

    /// Whether the MAIN window composites this grid.
    ///
    /// The scroll offsets, the float debt ledger and the fixed-float mask this
    /// file builds are all the main renderer's, and none of them has any use
    /// for a grid an external window draws: such a grid reports its start row
    /// and column in THAT surface's space, so the numbers describe a region of
    /// the wrong window. `isExternal` is the adjacent question -- "is this a
    /// window of its own" -- and misses exactly the floats such a window hosts.
    private func mainSurfaceDraws(_ grid: ZonvieCore.GridInfo) -> Bool {
        grid.placedBySurface == 1
    }

    private func updateScrollShaderOffset() {
        guard let core else { return }

        let cellHeightPx = Float(renderer.cellHeightPx)
        guard cellHeightPx > 0 else { return }

        // Idle fast path: nothing to do once the model has held no offset
        // for more than one call. appendFloatScrollOffsets() itself no-ops
        // when offsets is empty, so "no floats need servicing" is already
        // implied here -- skip building the Dictionary/Set/array below
        // entirely. The FIRST empty call after a non-empty one still falls
        // through, so the transition still propagates an empty state to the
        // renderer (clearing stale offsets).
        guard let scrollModel = scrollModel else { return }
        let isEmptyNow = !scrollModel.hasOffsets
        if isEmptyNow && !hadScrollOffsetsLastCall {
            return
        }

        // draw()'s vpHeight: the committed extent the vertices were baked
        // with, not the live drawable, which runs ahead of it after a resize.
        let cellHi = max(1, UInt32(cellHeightPx.rounded(.up)))
        let drawableHeight = Float(renderer.committedViewportHeightPx(
            liveHeight: max(1, UInt32(drawableSize.height)), cellHi: cellHi))
        guard drawableHeight > 0 else { return }
        hadScrollOffsetsLastCall = !isEmptyNow

        // Get grid info to look up margins and positions (non-blocking).
        // Built into persistent scratch storage (removeAll(keepingCapacity:)
        // + manual insert loops) instead of grids.map + Dictionary(uniqueKeysWithValues:)
        // + Set(...) — this runs in the pre-draw path on every scrolled frame.
        let grids = core.getVisibleGridsCached()
        gridInfoMapScratch.removeAll(keepingCapacity: true)
        for g in grids { gridInfoMapScratch[g.gridId] = g }
        let gridInfoMap = gridInfoMapScratch

        visibleGridIdsScratch.removeAll(keepingCapacity: true)
        for key in gridInfoMap.keys { visibleGridIdsScratch.insert(key) }

        let ndcScale: Float = 2.0 / drawableHeight

        scrollOffsetInfoScratch.removeAll(keepingCapacity: true)
        scrollModel.collectFrameOffsets(
            visible: visibleGridIdsScratch,
            cellHeightPx: CGFloat(cellHeightPx),
            anchors: &anchorLandedRowsUpScratch
        ) { gridId, clampedOffsetPx in
            // Pruned whatever surface draws it -- every surface reads its
            // offsets from the one model -- but only entered here when the
            // MAIN renderer is the one drawing it.
            guard let info = gridInfoMap[gridId], mainSurfaceDraws(info) else { return }

            let gridTopPx = Float(info.startRow) * cellHeightPx
            let gridTopYNDC = 1.0 - gridTopPx * ndcScale

            scrollOffsetInfoScratch.append(GridSurfaceRenderer.ScrollOffsetInfo(
                grid: info,
                offsetYPx: Float(clampedOffsetPx),
                gridTopYNDC: gridTopYNDC,
                // The paint rank is written at draw (rankOffsets).
                zindex: 0
            ))
        }

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

        // A partial transform is visibly wrong: it can split related windows.
        // Fall back to the committed, cell-aligned frame when the offset
        // buffer would overflow instead of truncating semantic state. The
        // fixed-float mask is the renderer's, built in draw from its layers.
        drewWithoutScrollTransform = false
        if !scrollOffsetsComplete || scrollOffsetInfoScratch.count > Self.maxScrollOffsets {
            drewWithoutScrollTransform = true
            scrollOffsetInfoScratch.removeAll(keepingCapacity: true)
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
    /// surface (an external grid view has no GridSurfaceRenderer of its own).
    ///
    /// What it would reset is handled elsewhere: pendingRetentionReplay by
    /// commitFlush, bracketSourceShift by beginFlush, published rows by
    /// the draw path's prune. scrollOffsetData is rebuilt whenever
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
        scrollModel?.clearAllOffsets()
        renderer.clearScrollOffsets()
    }

    /// A view point in the drawable's pixel space, with the cell grid it is
    /// read against and the cell it lands in.
    private struct PointerGeometry {
        var pointPx: CGPoint
        var cellW: CGFloat
        var cellH: CGFloat
        var globalRow: Int32
        var globalCol: Int32
    }

    /// Where a view point lands in the core's cell grid.
    ///
    /// Shared by the hit test and the drag, so a press and the drag that
    /// follows it agree about the column of the same pixel.
    ///
    /// nil before the renderer has cell metrics, which is what both call sites
    /// bailed on separately.
    private func pointerGeometry(at point: CGPoint) -> PointerGeometry? {
        guard renderer.cellWidthPx > 0, renderer.cellHeightPx > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        // The integer cell size the core receives through updateLayoutPx.
        let (cellWi, cellHi) = renderer.coreCellPx
        let cellW = CGFloat(cellWi)
        let cellH = CGFloat(cellHi)
        // From the current bounds, the same formula updateDrawableSizeIfPossible
        // uses: the stored drawableSize can lag behind bounds during a resize.
        let drawableH = CGFloat(max(1, Int((bounds.height * scale).rounded(.toNearestOrAwayFromZero))))
        // NSView is bottom-origin; the drawable is top-origin.
        let pointPx = isFlipped
            ? CGPoint(x: point.x * scale, y: point.y * scale)
            : CGPoint(x: point.x * scale, y: drawableH - point.y * scale)
        return PointerGeometry(
            pointPx: pointPx,
            cellW: cellW,
            cellH: cellH,
            // Floored, not truncated: a drag a fraction of a cell above or left
            // of the grid names row/column -1, which starts Neovim's drag
            // autoscroll, as Windows' floor division does.
            globalRow: Int32((pointPx.y / cellH).rounded(.down)),
            globalCol: Int32((pointPx.x / cellW).rounded(.down))
        )
    }

    /// The ease offset the last frame drew `grid` with: none at all on a frame
    /// that dropped the scroll transform, as on the external surface.
    private func drawnScrollOffsetPx(_ grid: Int64, cellH: CGFloat) -> CGFloat {
        if drewWithoutScrollTransform || renderer.drewWithoutScrollTransform { return 0 }
        return scrollModel?.visualScrollOffsetPx(gridId: grid, cellHeightPx: cellH) ?? 0
    }

    /// The renderer's follower map, skipped while nothing is displaced: the
    /// answer would be empty, and asking costs its lock and a Dictionary on
    /// every pointer move.
    private func drawnFollowerOffsetsPx() -> [Int64: CGFloat] {
        guard scrollModel?.hasOffsets == true, let renderer else { return [:] }
        return renderer.drawnFollowerOffsetsPx()
    }

    /// `requireScrollable`: a non-scrollable float is transparent to a wheel,
    /// which falls through to the scrollable grid beneath it.
    private func hitTestGrid(at point: CGPoint, requireScrollable: Bool = false) -> (gridId: Int64, row: Int32, col: Int32) {
        guard let core else { return (1, 0, 0) }
        // Early return when renderer is uninitialized (cellMetrics not yet available).
        guard let g = pointerGeometry(at: point) else { return (1, 0, 0) }
        let cellH = g.cellH
        let pointPx = g.pointPx
        let globalCol = g.globalCol
        let globalRow = g.globalRow

        let grids = core.getVisibleGridsCached()

        ZonvieCore.appLog("[hitTest] point=\(point) pointPx=\(pointPx) globalRow=\(globalRow) globalCol=\(globalCol) gridsCount=\(grids.count)")
        for grid in grids {
            ZonvieCore.appLog("[hitTest]   grid: id=\(grid.gridId) zindex=\(grid.zindex) startRow=\(grid.startRow) startCol=\(grid.startCol) rows=\(grid.rows) cols=\(grid.cols) marginTop=\(grid.marginTop) marginBottom=\(grid.marginBottom)")
        }

        // Find grid with highest zindex containing this point
        var bestGridId: Int64 = 1  // default to global grid
        var localRow: Int32 = globalRow
        var localCol: Int32 = globalCol

        if let hit = pointerTargetGrid(globalRow: globalRow, globalCol: globalCol, requireScrollable: requireScrollable) {
            bestGridId = hit.gridId
            localRow = hit.row
            localCol = hit.col
        }

        // A float that follows its anchor is drawn displaced bodily and has no
        // offset of its own for the correction below: during an ease or a held
        // bounce a press landed rows from where it is drawn, or in the window
        // behind. See resolveDisplacedFollowerHit.
        let followers = drawnFollowerOffsetsPx()
        let ranks = followers.isEmpty ? [:] : (renderer?.paintRanks() ?? [:])
        switch resolveDisplacedFollowerHit(
            pointPxY: pointPx.y,
            cellHeightPx: cellH,
            globalCol: globalCol,
            staticGridId: bestGridId,
            followers: followers,
            paintRankOf: { ranks[$0] },
            resolveExcluding: { row, col, excluded in
                core.resolvePointerGrid(surfaceId: 1, row: row, col: col,
                                        requireScrollable: requireScrollable, excluding: excluded)
            }
        ) {
        case let .follower(gridId, row, col)?:
            ZonvieCore.appLog("[hitTest] result: displaced follower gridId=\(gridId) row=\(row) col=\(col)")
            return (gridId, row, col)
        case let .uncovered(under)?:
            bestGridId = under?.gridId ?? 1
            localRow = under?.row ?? globalRow
            localCol = under?.col ?? globalCol
        case nil:
            break
        }

        // Adjust for smooth scroll offset: during scrolling, content rows are
        // visually shifted by scrollOffsetPx. Without this adjustment, clicking
        // on visually-shifted content selects the wrong row.
        let offsetPx = drawnScrollOffsetPx(bestGridId, cellH: cellH)

        if let grid = grids.first(where: { $0.gridId == bestGridId }) {
            localRow = scrollAdjustedLocalRow(
                pointPxY: pointPx.y,
                cellHeightPx: cellH,
                band: GridRowBand(of: grid),
                scrollOffsetPx: offsetPx
            )
        }

        ZonvieCore.appLog("[hitTest] result: gridId=\(bestGridId) localRow=\(localRow) localCol=\(localCol) scrollOffset=\(offsetPx)")
        return (bestGridId, localRow, localCol)
    }

    /// The grid a cell position names.
    ///
    /// The rule is the core's (`zonvie_core_resolve_pointer_grid`). It used to
    /// be here, and the Windows frontend had its own copy; between them they
    /// held different parts of it, so a float another surface hosts was
    /// hit-testable on one side and the mouse flag was ignored on the other.
    ///
    /// nil when nothing matches, which leaves the caller on the container grid
    /// with the position it was given.
    private func pointerTargetGrid(
        globalRow: Int32,
        globalCol: Int32,
        requireScrollable: Bool
    ) -> (gridId: Int64, row: Int32, col: Int32)? {
        core?.resolvePointerGrid(
            surfaceId: 1,
            row: globalRow,
            col: globalCol,
            requireScrollable: requireScrollable
        )
    }

    /// Give float windows the sub-cell scroll offset of the window they sit over,
    /// so they stay glued to the buffer line during smooth scrolling. Floats are
    /// sub-grids with a non-zero zindex; each follows the scrolled window with the
    /// largest rectangle overlap (so a float whose border extends a row/column past
    /// the window edge still tracks it). The whole float — including its border
    /// (viewport-margin) rows — translates via move_all, so a scroll-offset entry
    /// is all that is needed; the float's vertices are not regenerated.
    private func appendFloatScrollOffsets(
        into offsets: inout [GridSurfaceRenderer.ScrollOffsetInfo],
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
            // Not covered by the filter on the offsets above: an
            // editor-anchored float takes the overlap branch below, and a
            // foreign float's start row and column are numbers in ANOTHER
            // surface's space, which can overlap a main-window source by
            // arithmetic alone.
            guard mainSurfaceDraws(floatGrid) else { continue }
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
            var followedGridId: Int64?
            if floatGrid.anchorGrid > 1 {
                for i in 0..<windowCount where offsets[i].gridId == floatGrid.anchorGrid {
                    // Only follow when the anchor is itself a scrolled window.
                    if let aw = gridInfoMap[offsets[i].gridId], aw.zindex <= 0 {
                        followedOffsetYPx = offsets[i].offsetYPx
                        followedGridId = offsets[i].gridId
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
                        followedGridId = offsets[i].gridId
                    }
                }
            }
            guard let offsetYPx = followedOffsetYPx, let followedGridId else { continue }
            // The anchor half of the float debt, handed down raw. The other
            // half — how far this float's own placement has travelled — is only
            // consistent with the placement a frame draws inside the renderer's
            // own lock, so GridSurfaceRenderer.applyFloatScrollDebt does the
            // subtraction there rather than here.
            let debtAnchorRowsUp = Int32(clamping: anchorLandedRowsUpScratch[followedGridId] ?? 0)
            // A partial offset set can split a float from its anchor. Signal
            // overflow so the caller disables the whole transform for this
            // frame instead of silently truncating semantic state.
            guard offsets.count < Self.maxScrollOffsets else { return false }

            let gridTopPx = Float(floatGrid.startRow) * cellHeightPx
            let gridTopYNDC = 1.0 - gridTopPx * ndcScale
            offsets.append(GridSurfaceRenderer.ScrollOffsetInfo(
                gridId: floatGrid.gridId,
                offsetYPx: offsetYPx,
                gridTopYNDC: gridTopYNDC,
                gridRows: floatGrid.rows,
                marginTop: 0,
                marginBottom: 0,
                clipToContent: false,
                zindex: 0,
                debtAnchorRowsUp: debtAnchorRowsUp,
                debtAnchorGridId: followedGridId
            ))
        }
        return true
    }

}

// MARK: - NSTextInputClient (IME support)
/// The grids a scroll event drives, one per axis. A trackpad gesture locks
/// each axis on that axis's first delta and keeps it through its momentum, so
/// a pointer drifting across a float's edge mid-gesture cannot hand the rest
/// of the scroll to another grid; a wheel resolves per event. One per view.
///
/// Per axis because "can scroll" is a line-count test, a vertical rule: the
/// vertical axis must skip a float that shows all its lines and the
/// horizontal one must not. One lock for both either sent a diagonal swipe's
/// vertical part to a float that could not scroll, or moved its horizontal
/// part to the window below mid-gesture.
struct ScrollTargetLock {
    typealias Target = (gridId: Int64, row: Int32, col: Int32)
    private var vertical: Target?
    private var horizontal: Target?

    /// Call first for every event, delta or not: a gesture's .began carries
    /// no delta, and the previous gesture's targets must not survive into it.
    mutating func noteBegan(_ event: NSEvent) {
        if event.phase.contains(.began) {
            vertical = nil
            horizontal = nil
        }
    }

    /// The grid this event's `isVertical` axis drives. `resolve` takes
    /// whether the grid must be able to scroll.
    mutating func target(
        for event: NSEvent, isVertical: Bool,
        resolve: (_ requireScrollable: Bool) -> Target
    ) -> Target {
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard event.hasPreciseScrollingDeltas && isGesture else {
            // A wheel, or a phase-less precise event: never reuse a stale lock.
            vertical = nil
            horizontal = nil
            return resolve(isVertical)
        }
        if isVertical {
            if let vertical { return vertical }
            let resolved = resolve(true)
            vertical = resolved
            return resolved
        }
        if let horizontal { return horizontal }
        let resolved = resolve(false)
        horizontal = resolved
        return resolved
    }

    /// Release once the gesture and its inertia are done. The gesture's own
    /// .ended keeps the locks so momentum stays on the same grids. The events
    /// that end a gesture carry no delta, so the caller runs this before it
    /// returns on one.
    mutating func noteFinished(_ event: NSEvent) {
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            || event.phase.contains(.cancelled) {
            vertical = nil
            horizontal = nil
        }
    }
}

/// The input side the main grid view and every external grid view share: the
/// NSTextInputClient glue over the shared IME controller, the input context,
/// and first-responder acceptance. It is a class, not a protocol extension,
/// because the ObjC runtime never sees a Swift default implementation.
/// Subclasses supply the view-specific half as an IMEPreeditHost.
class GridInputView: MTKView, NSTextInputClient, SurfaceDrawLoopHost, IMEPreeditHost {
    /// The session this surface serves: input, scrollbar and IME all route
    /// through it. The views kept three names for it (core, scrollbarCore,
    /// imeCore).
    weak var core: ZonvieCore?

    /// The surface this view draws: 1 for the main window, an external
    /// window's root grid for its own. Scrollbar and key traces name it.
    var surfaceId: Int64 { 1 }

    var imeCore: ZonvieCore? { core }

    /// The GPU objects and font every surface shares.
    var sharedResources: SharedRenderResources {
        preconditionFailure("GridInputView subclasses provide their shared resources")
    }

    var backingScale: CGFloat { window?.backingScaleFactor ?? surfaceFallbackBackingScale }

    var imePreeditFont: NSFont {
        let shared = sharedResources
        return NSFont(name: shared.currentFontName, size: shared.currentPointSize)
            ?? NSFont.monospacedSystemFont(ofSize: shared.currentPointSize, weight: .regular)
    }

    var imePreeditCellSize: CGSize {
        let shared = sharedResources
        let scale = backingScale
        return CGSize(width: CGFloat(shared.cellWidthPx) / scale,
                      height: CGFloat(shared.cellHeightPx) / scale)
    }

    var imePreeditContainer: NSView { self }

    /// The cursor's cell in view points, or nil when this surface does not
    /// draw the cursor. The overlay and the candidate window both come from
    /// here, so they cannot disagree about whose cursor it is.
    func imeCursorRectInView() -> NSRect? { nil }

    /// The candidate-window cell when the cursor is not on this surface.
    func imeFallbackRectInView() -> NSRect {
        let cell = imePreeditCellSize
        return NSRect(x: 0, y: bounds.height - cell.height, width: cell.width, height: cell.height)
    }

    func imePreeditOrigin(preeditHeight: CGFloat) -> CGPoint {
        if let rect = imeCursorRectInView() { return rect.origin }
        let cell = imePreeditCellSize
        return CGPoint(x: cell.width, y: bounds.height - cell.height - preeditHeight)
    }

    /// A grid another surface shows is placed by that surface, in its own
    /// coordinates, hosted float included: ask it. An external window made key
    /// by Cmd-` does not move Neovim's cursor, so the answer may be the main
    /// window's. The candidate window and the preedit overlay both go there.
    var imeShowingHost: IMEPreeditHost {
        guard let core else { return self }
        let cursor = core.getCursorPositionNonBlocking()
        let showing: GridInputView? = core.externalViewShowing(gridId: cursor.gridId) ?? core.terminalView
        guard cursor.row >= 0, cursor.col >= 0, let showing else { return self }
        return showing
    }

    func imeFirstRect() -> NSRect {
        guard let win = window else { return .zero }
        if let showing = imeShowingHost as? GridInputView, showing !== self {
            return showing.imeFirstRect()
        }
        return win.convertToScreen(convert(imeCursorRectInView() ?? imeFallbackRectInView(), to: nil))
    }

    func imeSendCommitted(_ text: String) { core?.keyInput.sendInput(text, owner: self) }

    // MARK: - Redraw

    /// Until this moment, `occlusionState` may still describe this window as
    /// it stood BEFORE the app ordered another window in front of it.
    private var occlusionSuspectUntil: CFAbsoluteTime = 0

    /// The app just ordered some window in front; this one may now be covered
    /// and does not know it yet. `occlusionState` is published asynchronously
    /// (measured 25-36ms), and meanwhile `currentDrawable` on a covered window
    /// burns its one-second timeout on the MAIN thread
    /// (extfloat_resize_shader_stall). Frames in the next 100ms are skipped
    /// rather than guessed at; a window still visible loses at most that much
    /// animation on a focus change.
    func markOcclusionSuspect() {
        occlusionSuspectUntil = CFAbsoluteTimeGetCurrent() + 0.1
        ZonvieCore.appLog("[occlusion_suspect] \(drawLoopTraceName)")
        // The frames skipped are frames the animation still owes.
        requestRedraw()
    }

    /// Only a window covering all of this one can hide it; holding the frames
    /// on every activation stalled the surface at each `:`. A higher-level
    /// window (a .floating panel) or a child of `front` stays above it.
    func markOcclusionSuspect(ifCoveredBy front: NSWindow) {
        guard let win = window, win.parent !== front, front.level >= win.level else { return }
        if front.frame.contains(win.frame) { markOcclusionSuspect() }
    }

    enum VisibilityGate { case draw, unsettled, hidden }

    /// Whether this surface may draw now. `.unsettled` is checked first: during
    /// it the state `.hidden` reads is the stale one. `unpresentedMayDraw`: a
    /// surface with nothing on screen yet draws unless miniaturized, since
    /// occlusionState lags a window just ordered in.
    func visibilityGate(unpresentedMayDraw: Bool) -> VisibilityGate {
        if unpresentedMayDraw, window?.isMiniaturized != true { return .draw }
        if CFAbsoluteTimeGetCurrent() < occlusionSuspectUntil { return .unsettled }
        if let win = window, win.isMiniaturized || !win.occlusionState.contains(.visible) { return .hidden }
        return .draw
    }

    /// DrawLoopIdleCounter counts idle frames, SurfaceDrawLoopHost switches
    /// the mode; each surface decides when a frame was idle.
    var drawLoopIdleCounter = DrawLoopIdleCounter()
    var drawLoopTraceName: String { "main" }

    /// Whether this surface committed content within `withinNs`.
    func hadRecentCommit(withinNs: UInt64) -> Bool { false }

    /// Called from draw() early-return paths when no rendering was needed.
    func notifyDrawIdle() {
        // `heldActive`: while a synthesized key repeat is armed, the draw loop
        // is its clock and must never stop, even on frames with nothing to
        // render (holding j at the end of the buffer).
        if drawLoopIdleCounter.noteIdle(
            hadRecentCommit: hadRecentCommit(withinNs: 50_000_000),
            heldActive: core?.keyInput.synthesisHeld(by: self) == true
        ) {
            deactivateSurfaceDrawLoop()
        }
    }

    /// A hidden frame parks the loop, except while a synthesized key repeat is
    /// armed: its safety tick runs at the top of draw(). Showing the window
    /// repaints it, which re-activates the loop.
    func parkDrawLoopWhenHidden() {
        if core?.keyInput.synthesisHeld(by: self) != true {
            deactivateSurfaceDrawLoop()
        }
    }

    /// Called from draw() when actual rendering proceeds.
    func notifyDrawActive() {
        drawLoopIdleCounter.noteActive()
    }

    /// Coalesces setNeedsDisplay to once per runloop tick, unioning rects.
    let redrawScheduler = SurfaceRedrawScheduler()

    func requestRedraw(_ rect: NSRect? = nil) {
        // The input trace's request_redraw stage is the main window's (a
        // one-shot per keystroke): an external view taking it misattributed
        // the latency of every input the main window then drew.
        if ZonvieCore.appLogEnabled, surfaceId == 1, let inputTrace = core?.currentInputTraceSnapshot(),
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
            if ZonvieCore.appLogEnabled {
                ZonvieCore.appLog("setNeedsDisplay(out): surface=\(self.surfaceId) r=\(String(describing: redrawRect)) bounds=\(self.bounds)")
            }
            self.setNeedsDisplay(redrawRect)
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        activateSurfaceDrawLoop()
        requestRedraw()
    }

    // A view leaving its window (tab or window closed, maybe with a key still
    // held) stops the repeat-pacing display link, which releases its extra
    // retain, and parks its draw loop; the main view used to leave the loop
    // running.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAlwaysScrollbarVisibility()
        guard window == nil else { return }
        deactivateSurfaceDrawLoop()
        core?.keyInput.disarmIfHeld(by: self, reason: "view detached from window")
    }

    override func layout() {
        super.layout()
        layoutScrollbar()
    }

    // MARK: - Pointer

    /// An event's position in surface pixels from the top-left.
    func surfacePointPx(_ event: NSEvent) -> CGPoint {
        surfacePointPx(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    func surfacePointPx(atViewPoint location: CGPoint) -> CGPoint {
        let scale = backingScale
        return CGPoint(x: location.x * scale, y: bounds.height * scale - location.y * scale)
    }

    /// The cell a click at `location` (view points) would name, or nil where
    /// this surface shows no URL hover. Each surface resolves it its own way.
    func urlHoverCell(at location: CGPoint) -> (gridId: Int64, row: Int32, col: Int32)? { nil }

    /// One area over the bounds serves the URL hand and the scrollbar hover;
    /// AppKit asks for it on geometry changes, so it is not rebuilt per layout.
    private var urlTrackingArea: NSTrackingArea?
    private var lastUrlCursorIsHand = false

    // Entered/exited too: a hand set over a URL stayed when the pointer left
    // for another window, which sets no cursor of its own there.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = urlTrackingArea { removeTrackingArea(existing) }
        urlTrackingArea = nil
        guard tracksURLHover || hoverScrollbarEnabled else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        urlTrackingArea = area
    }

    /// Whether this surface shows the hand over a URL.
    var tracksURLHover: Bool { true }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === urlTrackingArea, hoverScrollbarEnabled {
            updateScrollbarHover(overStrip: pointerIsOverScrollbarStrip(event))
        }
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if hoverScrollbarEnabled {
            updateScrollbarHover(overStrip: pointerIsOverScrollbarStrip(event))
        }
        guard tracksURLHover, let core,
              let cell = urlHoverCell(at: convert(event.locationInWindow, from: nil))
        else { return }
        let hasUrl = core.cellHasURL(gridId: cell.gridId, row: cell.row, col: cell.col)
        guard hasUrl != lastUrlCursorIsHand else { return }
        lastUrlCursorIsHand = hasUrl
        (hasUrl ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === urlTrackingArea {
            if hoverScrollbarEnabled {
                updateScrollbarHover(overStrip: false)
            }
            if lastUrlCursorIsHand {
                lastUrlCursorIsHand = false
                NSCursor.arrow.set()
            }
        }
        super.mouseExited(with: event)
    }

    // MARK: - File drops

    /// Whether this surface takes file drops at all.
    var acceptsFileDrops: Bool { true }

    /// Whether a drop inserts the paths at the cursor rather than opening
    /// the files. Each surface decides; the rest of a drop is the same.
    var dropInsertsPath: Bool { false }

    /// A buffer surface's rule: when the command line is a separate window
    /// that window is the drop target for it, so a drop here opens. Only when
    /// it is drawn in the main window ([cmdline] external = false) does a drop
    /// while it is up insert.
    final var bufferDropInsertsPath: Bool {
        guard let core else { return false }
        return core.getCurrentMode().withCString {
            zonvie_core_drop_inserts_path($0, strlen($0), core.hasExternalCmdlineWindow, false)
        }
    }

    func registerFileDrops() {
        if acceptsFileDrops { registerForDraggedTypes([.fileURL]) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsFileDrops,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        // The dragged item predicts what the drop does. Set on every entry,
        // which also restores the file icon after the external cmdline window
        // swapped the item to text on its way past.
        if dropInsertsPath {
            FileDragFeedback.showPathText(sender, in: self)
        } else {
            FileDragFeedback.showFileIcon(sender, in: self)
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsFileDrops,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty,
              let core
        else { return false }
        if dropInsertsPath {
            core.sendInput(urls.map { ZonvieCore.escapePathForCmdline($0.path) }.joined(separator: " "))
        } else {
            core.dropPaths(urls.map { $0.path }, tabPerFile: false)
        }
        return true
    }

    private lazy var ime = IMEPreeditController(host: self)
    private var _inputContext: NSTextInputContext?

    // Nonisolated so the subclasses' nonisolated deinits have one to
    // override; the implicit one here would be main-actor isolated. The
    // scrollbar's hide timer is invalidated to break its run-loop retain.
    nonisolated deinit {
        createdScrollbarController?.invalidate()
    }

    override var inputContext: NSTextInputContext? {
        if _inputContext == nil {
            _inputContext = NSTextInputContext(client: self)
        }
        return _inputContext
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        surfaceCycleInputContextForAppearance(_inputContext, hasMarkedText: hasMarkedText())
    }

    // MARK: - Keys

    // The session's keyDown: keys reach Neovim through the shared repeat
    // synthesis, with this view as the owner whose window and IME state
    // decide when a repeat stops.
    override func keyDown(with event: NSEvent) {
        core?.keyInput.handleGridKeyDown(event, owner: self, traceSurface: surfaceId)
    }

    override func keyUp(with event: NSEvent) {
        core?.keyInput.disarmKeyRepeat(ifHeld: event.keyCode, reason: "keyUp")
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        // Any modifier change invalidates the recorded input (e.g. j -> C-j),
        // which is what a nil `ifHeld` means.
        core?.keyInput.disarmKeyRepeat(ifHeld: nil, reason: "flagsChanged")
        super.flagsChanged(with: event)
    }

    // MARK: - Mouse buttons

    /// The grid a press claimed, kept for its drag and release: Neovim keeps a
    /// drag on the window the press chose, so re-resolving mid-drag switches
    /// coordinate spaces, and a release re-resolved under the pointer ended a
    /// selection dragged out of a float in the window behind it. Windows pins
    /// the same way (app.mouse_press_grid_id). Which presses were sent and
    /// when the claim ends is the core's rule (zonvie_press_claim).
    private var pressClaim = zonvie_press_claim()
    private var pressGridId: Int64?

    private static func pressButtonCode(_ button: String) -> UInt8 {
        switch button {
        case "left": return 1
        case "right": return 2
        case "middle": return 3
        case "x1": return 4
        default: return 5
        }
    }

    /// The grid an event's point names, resolved this surface's way.
    func resolvePointerTarget(_ event: NSEvent, requireScrollable: Bool) -> (gridId: Int64, row: Int32, col: Int32) {
        (surfaceId, 0, 0)
    }

    /// The pinned grid at its CURRENT placement, so a grid that moves
    /// mid-drag keeps receiving the cells under the pointer; nil sends nothing.
    func rebaseToPinnedGrid(_ event: NSEvent, pinned: Int64) -> (gridId: Int64, row: Int32, col: Int32)? {
        resolvePointerTarget(event, requireScrollable: false)
    }

    /// Send one button event to Neovim: a press resolves and pins its grid,
    /// the drag and release that follow stay on it.
    func sendGridMouseEvent(button: String, action: String, event: NSEvent) {
        guard let core else { return }
        let target: (gridId: Int64, row: Int32, col: Int32)
        let code = Self.pressButtonCode(button)
        if action == "press" {
            let hit = resolvePointerTarget(event, requireScrollable: false)
            if zonvie_core_press_claim_press(&pressClaim, code) { pressGridId = hit.gridId }
            target = hit
        } else {
            var pinned = pressGridId
            if action == "release" {
                let r = UInt32(zonvie_core_press_claim_release(&pressClaim, code))
                if r & ZONVIE_PRESS_RELEASE_ENDS != 0 { pressGridId = nil }
                // Its press never reached Neovim.
                if r & ZONVIE_PRESS_RELEASE_SEND == 0 { pinned = nil }
            }
            guard let pinned, let rebased = rebaseToPinnedGrid(event, pinned: pinned) else { return }
            target = rebased
        }
        core.sendMouseInput(button: button, action: action, modifier: neovimModifierString(event.modifierFlags),
                            gridId: target.gridId, row: target.row, col: target.col)
    }

    // Every press takes first responder, so keys follow the grid clicked;
    // the main surface used to take it on the left button only.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
        sendGridMouseEvent(button: "left", action: "press", event: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        sendGridMouseEvent(button: "left", action: "release", event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        sendGridMouseEvent(button: "left", action: "drag", event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        window?.makeFirstResponder(self)
        sendGridMouseEvent(button: "right", action: "press", event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        sendGridMouseEvent(button: "right", action: "release", event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        sendGridMouseEvent(button: "right", action: "drag", event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        window?.makeFirstResponder(self)
        if let btn = surfaceOtherMouseButtonName(event.buttonNumber) {
            sendGridMouseEvent(button: btn, action: "press", event: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        if let btn = surfaceOtherMouseButtonName(event.buttonNumber) {
            sendGridMouseEvent(button: btn, action: "release", event: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        super.otherMouseDragged(with: event)
        if let btn = surfaceOtherMouseButtonName(event.buttonNumber) {
            sendGridMouseEvent(button: btn, action: "drag", event: event)
        }
    }

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

    /// Unbound key commands from interpretKeyEvents are swallowed. Passing
    /// them up the responder chain beeps.
    override func doCommand(by selector: Selector) {}

    // --- Scrollbar ---


    lazy var verticalScroller: NSScroller = {
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
    // Created on first use, never from deinit: forming `[weak self]` while
    // self is deallocating traps.
    private var createdScrollbarController: SurfaceScrollbarController?
    var scrollbarController: SurfaceScrollbarController {
        if let controller = createdScrollbarController { return controller }
        let controller = SurfaceScrollbarController(
            scroller: verticalScroller, surfaceId: surfaceId, core: { [weak self] in self?.core })
        createdScrollbarController = controller
        return controller
    }

    /// Whether this surface has a scrollbar at all.
    var hostsScrollbar: Bool { true }

    /// Add the scroller, hidden until a viewport shows there is something to
    /// scroll -- or shown at once in "always" mode. The views answered this
    /// differently: one added it even when disabled and left it hit-testable
    /// at alpha 0 until the first update.
    func installScrollbar() {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled, hostsScrollbar else { return }
        addSubview(verticalScroller)
        verticalScroller.isHidden = !config.isAlways
        verticalScroller.alphaValue = config.isAlways ? CGFloat(config.opacity) : 0.0
    }

    /// Re-apply "always" visibility when the view (re)joins a window.
    func applyAlwaysScrollbarVisibility() {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled, hostsScrollbar, config.isAlways else { return }
        verticalScroller.isHidden = false
        verticalScroller.alphaValue = CGFloat(config.opacity)
    }

    /// Lay the scroller out, only where there is one: the main surface used
    /// to create and place it with the scrollbar turned off.
    func layoutScrollbar() {
        guard ZonvieConfig.shared.scrollbar.enabled, hostsScrollbar else { return }
        layoutScrollbarFrame()
    }

    /// Move the knob after a drawn frame.
    func updateScrollbarIfNeeded() {
        guard hostsScrollbar else { return }
        scrollbarController.update()
    }

    /// Pin the scroller to the right edge, full height.
    func layoutScrollbarFrame() {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        verticalScroller.frame = NSRect(
            x: bounds.width - scrollerWidth,
            y: 0,
            width: scrollerWidth,
            height: bounds.height
        )
    }

    func showScrollbar() {
        scrollbarController.show()
    }

    func hideScrollbar() {
        scrollbarController.hide()
    }

    /// Whether the pointer was last seen over the scrollbar strip.
    private var pointerOverScrollbarStrip = false

    /// Whether this surface shows its scrollbar on hover.
    var hoverScrollbarEnabled: Bool {
        let config = ZonvieConfig.shared.scrollbar
        return config.enabled && config.isHover && hostsScrollbar
    }

    /// Whether the pointer is over the strip the scrollbar occupies.
    private func pointerIsOverScrollbarStrip(_ event: NSEvent) -> Bool {
        let locationInView = convert(event.locationInWindow, from: nil)
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        return locationInView.x >= bounds.width - scrollerWidth
    }

    /// Show and hide only on the pointer crossing the strip, and never hide a
    /// bar "scroll" mode showed: its own delay hides it. Windows'
    /// scrollbar.hover/leave rule. Every move over the strip re-shows, or a
    /// "scroll" mode delay would fade the bar under a pointer resting on it.
    private func updateScrollbarHover(overStrip: Bool) {
        if overStrip {
            pointerOverScrollbarStrip = true
            showScrollbar()
            return
        }
        guard pointerOverScrollbarStrip else { return }
        pointerOverScrollbarStrip = false
        if !ZonvieConfig.shared.scrollbar.isScroll {
            hideScrollbar()
        }
    }

    @objc func scrollerDidScroll(_ sender: NSScroller) {
        scrollbarController.scrollerDidScroll(sender)
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
    /// The host whose surface shows Neovim's cursor; the overlay is placed there.
    var imeShowingHost: IMEPreeditHost { get }
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
        guard let host = host?.imeShowingHost else { return }
        // Moving the overlay to the showing view takes it off the key view.
        if preeditView.superview !== host.imePreeditContainer {
            host.imePreeditContainer.addSubview(preeditView)
        }
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
        // A foreign view would keep it past this controller's lifetime.
        if let superview = preeditView.superview, superview !== host?.imePreeditContainer {
            preeditView.removeFromSuperview()
        }
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
    /// X of each UTF-16 offset of `text`, plus the end: the IME's ranges are
    /// UTF-16.
    private var utf16XOffsets: [CGFloat] = []

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
        utf16XOffsets.removeAll()
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

        parseUnderlineSegments(attributedText: attributedText, selectedRange: selectedRange)

        // Each character takes the cells the core lays it out in, so the text
        // lines up with the grid beneath.
        utf16XOffsets.removeAll(keepingCapacity: true)
        var x: CGFloat = 0
        for char in text {
            let width = String(char).withCString { zonvie_core_display_width($0, strlen($0)) }
            let cells = CGFloat(min(2, max(1, width)))
            for _ in 0..<char.utf16.count { utf16XOffsets.append(x) }
            x += cellWidth * cells
        }
        utf16XOffsets.append(x)

        frame.size = NSSize(width: max(1, x), height: max(1, cellHeight))
        needsDisplay = true
    }

    /// Parse IME attributes to determine underline segments.
    /// Selected/converting portion gets thick underline, others get thin underline.
    private func parseUnderlineSegments(attributedText: NSAttributedString, selectedRange: NSRange) {
        underlineSegments.removeAll()

        let fullRange = NSRange(location: 0, length: attributedText.length)
        guard fullRange.length > 0 else { return }

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

        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath.fill(bounds)

        // Text attributes without underline (we draw underline separately)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]

        guard utf16XOffsets.count == text.utf16.count + 1 else { return }
        var u16 = 0
        for char in text {
            String(char).draw(at: NSPoint(x: utf16XOffsets[u16], y: 0), withAttributes: attrs)
            u16 += char.utf16.count
        }

        NSColor.textColor.setStroke()
        for segment in underlineSegments {
            let startIndex = segment.range.location
            let endIndex = min(segment.range.location + segment.range.length, utf16XOffsets.count - 1)

            guard startIndex < utf16XOffsets.count else { continue }

            let startX = utf16XOffsets[startIndex]
            let endX = utf16XOffsets[endIndex]

            let underlinePath = NSBezierPath()
            underlinePath.lineWidth = segment.isThick ? 2.0 : 1.0
            let yPos: CGFloat = segment.isThick ? 2.0 : 1.5
            underlinePath.move(to: NSPoint(x: startX, y: yPos))
            underlinePath.line(to: NSPoint(x: endX, y: yPos))
            underlinePath.stroke()
        }
    }
}

/// The band a grid's sub-row ease actually moves, from the grid the core
/// reports. Lives here rather than beside GridRowBand because MetalTypes.swift
/// is compiled standalone by the Swift test steps and must not name ZonvieCore.
extension GridRowBand {
    init(of grid: ZonvieCore.GridInfo) {
        self.init(
            startRow: grid.startRow,
            rows: grid.rows,
            marginTop: grid.marginTop,
            marginBottom: grid.marginBottom
        )
    }
}
