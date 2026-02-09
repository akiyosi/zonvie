import AppKit
import Metal
import MetalKit
import simd

/// A Metal view for rendering external Neovim grids (from win_external_pos).
/// Shares the glyph atlas with the main renderer for consistent text rendering.
/// Forwards key events to the main terminal view so keyboard input still works.
final class ExternalGridView: MTKView, MTKViewDelegate {
    private let mtlDevice: MTLDevice
    private let queue: MTLCommandQueue
    private weak var sharedAtlas: GlyphAtlas?

    /// Reference to main terminal view for key event forwarding and core access
    weak var mainTerminalView: MetalTerminalView?

    /// Custom clear color for the grid (default: black)
    var gridClearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// Track if we've presented at least once (for loadAction optimization)
    private var hasPresentedOnce = false

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
        addSubview(view)
        return view
    }()

    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    // 2-pass rendering pipelines for blur support
    private var backgroundPipeline: MTLRenderPipelineState?
    private var glyphPipeline: MTLRenderPipelineState?

    private let lock = NSLock()

    private var vertexBuffer: MTLBuffer?
    private var vertexBufferCapacity: Int = 0
    private var currentVertexCount: Int = 0
    private var pendingVertexCount: Int? = nil

    // Row-based vertex buffers (same as main window)
    private var rowVertexBuffers: [MTLBuffer?] = []
    private var rowVertexBufferCaps: [Int] = []
    private var rowVertexCounts: [Int] = []
    private var usingRowBuffers: Bool = false
    private var pendingDirtyRows: Set<Int> = []
    private let maxRowBuffers = 512

    // Scroll offset data stored as value-type; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race.
    private var scrollOffsetData: MetalTerminalRenderer.ScrollOffset?
    private var scrollOffsetActive: Bool = false

    // Blur transparency support
    private let blurEnabled: Bool
    private let isCmdline: Bool
    private var backgroundAlphaBuffer: MTLBuffer?

    // Cursor blink support
    private var cursorBlinkBuffer: MTLBuffer?
    var cursorBlinkState: Bool = true

    // --- Scrollbar ---
    private lazy var verticalScroller: NSScroller = {
        let scroller = NSScroller()
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .regular
        scroller.knobProportion = 0.2
        scroller.isEnabled = true
        scroller.alphaValue = 0.0
        scroller.target = self
        scroller.action = #selector(scrollerDidScroll(_:))
        return scroller
    }()
    private var scrollbarHideTimer: Timer?
    private var lastViewportTopline: Int64 = -1
    private var lastViewportLineCount: Int64 = -1
    private var lastViewportBotline: Int64 = -1
    private var scrollbarTrackingArea: NSTrackingArea?

    // DrawableSize struct matching Shaders.metal
    private struct DrawableSize {
        var width: Float
        var height: Float
    }

    // Use MetalTerminalRenderer.ScrollOffset for shader data (shared with main window)

    // Grid dimensions (in cells)
    private(set) var gridRows: UInt32 = 0
    private(set) var gridCols: UInt32 = 0

    let gridId: Int64

    /// Initialize with shared Metal resources from the main renderer.
    /// - Parameters:
    ///   - gridId: The Neovim grid ID
    ///   - device: Metal device
    ///   - atlas: Shared glyph atlas
    ///   - sharedPipeline: Shared render pipeline from main renderer
    ///   - sharedBackgroundPipeline: Shared 2-pass background pipeline (for blur)
    ///   - sharedGlyphPipeline: Shared 2-pass glyph pipeline (for blur)
    ///   - sharedSampler: Shared sampler state
    ///   - blurEnabled: Whether blur effect is enabled
    ///   - isCmdline: Whether this is a cmdline grid (affects background alpha)
    init?(gridId: Int64,
          device: MTLDevice,
          atlas: GlyphAtlas,
          sharedPipeline: MTLRenderPipelineState,
          sharedBackgroundPipeline: MTLRenderPipelineState?,
          sharedGlyphPipeline: MTLRenderPipelineState?,
          sharedSampler: MTLSamplerState,
          blurEnabled: Bool = false,
          isCmdline: Bool = false) {
        self.gridId = gridId
        self.mtlDevice = device
        self.sharedAtlas = atlas
        self.blurEnabled = blurEnabled
        self.isCmdline = isCmdline

        // Use shared pipelines from main renderer (no shader compilation needed)
        self.pipeline = sharedPipeline
        self.backgroundPipeline = sharedBackgroundPipeline
        self.glyphPipeline = sharedGlyphPipeline
        self.sampler = sharedSampler

        guard let q = device.makeCommandQueue() else {
            ZonvieCore.appLog("[ExternalGridView] Failed to create command queue")
            return nil
        }
        self.queue = q

        super.init(frame: .zero, device: device)

        ZonvieCore.appLog("[ExternalGridView] init: gridId=\(gridId) blurEnabled=\(blurEnabled) (using shared pipelines)")

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.isPaused = true
        self.enableSetNeedsDisplay = true  // Use setNeedsDisplay() like main window

        // Configure layer transparency based on blur setting
        // DEBUG: Log layer configuration with actual layer state
        let layerExists = self.layer != nil
        ZonvieCore.appLog("[DEBUG-EXTGRID-INIT] gridId=\(gridId) blurEnabled=\(blurEnabled) layerExists=\(layerExists) ZonvieConfig.blurEnabled=\(ZonvieConfig.shared.blurEnabled)")

        if blurEnabled {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
            ZonvieCore.appLog("[ExternalGridView] layer: isOpaque=false, backgroundColor=clear")
        } else {
            self.layer?.isOpaque = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            ZonvieCore.appLog("[ExternalGridView] layer: isOpaque=true, backgroundColor=black")
        }

        // DEBUG: Verify layer state after configuration
        if let layer = self.layer {
            ZonvieCore.appLog("[DEBUG-EXTGRID-LAYER] gridId=\(gridId) layer.isOpaque=\(layer.isOpaque) layer.backgroundColor=\(String(describing: layer.backgroundColor))")
        }

        buildShaderBuffers()

        // Create background alpha buffer for shader
        backgroundAlphaBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
        if let buf = backgroundAlphaBuffer {
            var alpha: Float
            if isCmdline && blurEnabled {
                // For cmdline with blur: don't draw background in Metal
                // containerView provides the background color
                alpha = 0.0
            } else if blurEnabled {
                alpha = ZonvieConfig.shared.backgroundAlpha
            } else {
                alpha = 1.0
            }
            ZonvieCore.appLog("[ExternalGridView] backgroundAlphaBuffer alpha=\(alpha) isCmdline=\(isCmdline)")
            memcpy(buf.contents(), &alpha, MemoryLayout<Float>.size)
        }

        // Create cursor blink buffer for shader
        cursorBlinkBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        if let buf = cursorBlinkBuffer {
            var visible: UInt32 = 1
            memcpy(buf.contents(), &visible, MemoryLayout<UInt32>.size)
        }

        // For cmdline with blur: clearColor is transparent
        if isCmdline && blurEnabled {
            gridClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }

        // Add scrollbar (for detached grids, not cmdline/popupmenu)
        setupScrollbar()
    }

    private func setupScrollbar() {
        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled else { return }

        // Don't add scrollbar to cmdline or special grids
        if isCmdline { return }

        addSubview(verticalScroller)

        if scrollbarConfig.isAlways {
            verticalScroller.isHidden = false
            verticalScroller.alphaValue = CGFloat(scrollbarConfig.opacity)
        } else {
            verticalScroller.isHidden = true
            verticalScroller.alphaValue = 0.0
        }
    }

    private func buildShaderBuffers() {
        // (scroll offset / drawable size buffers removed: now passed via setVertexBytes/setFragmentBytes)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Vertex Submission

    /// Notify that font has changed - reset state to force clear on next frame
    func notifyFontChanged() {
        lock.lock()
        defer { lock.unlock() }
        hasPresentedOnce = false
        // Clear all row vertex counts so stale rows from the old font are not drawn
        for i in 0..<rowVertexCounts.count {
            rowVertexCounts[i] = 0
        }
    }

    /// Submit vertices for rendering. Called from the Zig core callback.
    func submitVertices(ptr: UnsafeRawPointer?, count: Int, rows: UInt32, cols: UInt32) {
        // Mark scroll offset for clearing when content changes (Neovim has processed scroll)
        // The actual clearing happens in draw() via processPendingScrollClears() + updateScrollShaderOffset()
        // to ensure proper synchronization with rendering
        if let main = mainTerminalView, main.getScrollOffset(gridId: gridId) != 0 {
            main.clearScrollOffsetForGrid(gridId)
        }

        lock.lock()
        defer { lock.unlock() }

        gridRows = rows
        gridCols = cols

        if count > 0, let ptr = ptr {
            ensureVertexBufferCapacity(count)
            if let vb = vertexBuffer {
                memcpy(vb.contents(), ptr, count * MemoryLayout<Vertex>.stride)
                pendingVertexCount = count
            }
        } else {
            pendingVertexCount = 0
        }
    }

    /// Submit vertices for a specific row (row-based update, same as main window).
    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, totalRows: Int, totalCols: Int) {
        lock.lock()
        defer { lock.unlock() }

        usingRowBuffers = true
        gridRows = UInt32(totalRows)
        gridCols = UInt32(totalCols)

        // Ensure row storage
        while rowVertexBuffers.count < totalRows {
            rowVertexBuffers.append(nil)
            rowVertexBufferCaps.append(0)
            rowVertexCounts.append(0)
        }

        // Clear counts for rows beyond the current grid size (grid shrank, e.g. after guifont)
        for i in totalRows..<rowVertexCounts.count {
            rowVertexCounts[i] = 0
        }

        guard rowCount > 0, rowStart >= 0, rowStart < maxRowBuffers else { return }
        let row = rowStart

        guard row < rowVertexBuffers.count else { return }

        guard count > 0, let validPtr = ptr else {
            rowVertexCounts[row] = 0
            return
        }

        let neededBytes = count * MemoryLayout<Vertex>.stride

        // Grow buffer if needed
        if rowVertexBuffers[row] == nil || neededBytes > rowVertexBufferCaps[row] {
            let newCap = max(neededBytes, rowVertexBufferCaps[row] * 2, 4096)
            rowVertexBuffers[row] = mtlDevice.makeBuffer(length: newCap, options: .storageModeShared)
            rowVertexBufferCaps[row] = newCap
        }

        // Copy vertices
        if let vb = rowVertexBuffers[row] {
            memcpy(vb.contents(), validPtr, neededBytes)
            rowVertexCounts[row] = count
        } else {
            rowVertexCounts[row] = 0
        }

        // Mark row as dirty
        pendingDirtyRows.insert(row)
    }

    /// Request a redraw after vertices are submitted.
    func requestRedraw() {
        // Use setNeedsDisplay() like main window to ensure proper synchronization
        // with scroll offset processing in the next draw cycle
        if Thread.isMainThread {
            self.setNeedsDisplay(bounds)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.setNeedsDisplay(self.bounds)
            }
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        autoreleasepool {
            guard let pipeline = pipeline, let sampler = sampler else {
                ZonvieCore.appLog("[ExternalGridView] Pipeline not ready")
                return
            }

            if view.drawableSize.width <= 0 || view.drawableSize.height <= 0 {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) early return: drawableSize invalid (\(view.drawableSize))")
                return
            }

            // Fetch pending state under lock
            let (vertexCount, rowMode, rowBuffersSnapshot, rowCountsSnapshot, dirtyRows): (Int, Bool, [MTLBuffer?], [Int], [Int]) = {
                lock.lock()
                defer { lock.unlock() }

                if usingRowBuffers {
                    let buffers = rowVertexBuffers
                    let counts = rowVertexCounts
                    let dirty = Array(pendingDirtyRows)
                    pendingDirtyRows.removeAll()
                    return (0, true, buffers, counts, dirty)
                } else {
                    if let pending = pendingVertexCount {
                        currentVertexCount = pending
                        pendingVertexCount = nil
                    }
                    return (currentVertexCount, false, [], [], [])
                }
            }()

            if !rowMode && vertexCount <= 0 {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) early return: !rowMode && vertexCount<=0")
                return
            }
            if rowMode && rowBuffersSnapshot.isEmpty {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) early return: rowMode && rowBuffersSnapshot.isEmpty")
                return
            }

            // Debug logging
            let nonZeroRows = rowCountsSnapshot.filter { $0 > 0 }.count
            let totalVerts = rowCountsSnapshot.reduce(0, +)
            ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) rowMode=\(rowMode) rowBuffers=\(rowBuffersSnapshot.count) nonZeroRows=\(nonZeroRows) totalVerts=\(totalVerts) dirtyRows=\(dirtyRows.count)")

            // Process pending scroll clears before updating shader offset (sync with main window)
            mainTerminalView?.processPendingScrollClears()

            // Update scroll offset every frame to ensure synchronization with vertex data
            let hasScrollOffset = updateScrollShaderOffset()

            guard let drawable = view.currentDrawable else { return }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            // When blur is enabled, always use .clear to avoid ghosting from semi-transparent backgrounds.
            // Only use .load for non-blur scrolling (preserves previous content for partial update).

            // DEBUG: Detailed loadAction decision for external grid
            ZonvieCore.appLog("[DEBUG-EXTGRID-LOADACTION] gridId=\(gridId) blurEnabled=\(blurEnabled) hasScrollOffset=\(hasScrollOffset) hasPresentedOnce=\(hasPresentedOnce) gridClearColor.alpha=\(gridClearColor.alpha)")

            if !blurEnabled && hasScrollOffset && hasPresentedOnce {
                rpd.colorAttachments[0].loadAction = .load
                ZonvieCore.appLog("[DEBUG-EXTGRID-LOADACTION] gridId=\(gridId) -> .load")
            } else {
                rpd.colorAttachments[0].loadAction = .clear
                ZonvieCore.appLog("[DEBUG-EXTGRID-LOADACTION] gridId=\(gridId) -> .clear")
            }
            rpd.colorAttachments[0].storeAction = .store
            // Always use gridClearColor (which has appropriate alpha for blur/non-blur modes)
            rpd.colorAttachments[0].clearColor = gridClearColor

            guard let cmd = queue.makeCommandBuffer() else { return }
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

            // Bind atlas texture
            if let atlas = sharedAtlas, let tex = atlas.texture {
                enc.setFragmentTexture(tex, index: 0)
            } else {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) WARNING: atlas or texture is nil! sharedAtlas=\(sharedAtlas != nil)")
            }
            enc.setFragmentSamplerState(sampler, index: 0)

            // Bind scroll offset data via setVertexBytes (no GPU/CPU race)
            lock.lock()
            let scrollSnap = scrollOffsetData
            let scrollActive = scrollOffsetActive
            lock.unlock()

            if scrollActive, var so = scrollSnap {
                enc.setVertexBytes(&so, length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride, index: 1)
                var count: UInt32 = 1
                enc.setVertexBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
            } else {
                var dummy = MetalTerminalRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                enc.setVertexBytes(&dummy, length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride, index: 1)
                var count: UInt32 = 0
                enc.setVertexBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
            }

            // Bind drawable size via setFragmentBytes (no shared buffer race)
            do {
                var size = DrawableSize(
                    width: Float(view.drawableSize.width),
                    height: Float(view.drawableSize.height)
                )
                enc.setFragmentBytes(&size, length: MemoryLayout<DrawableSize>.size, index: 0)
            }

            // Bind background alpha buffer for blur transparency
            if let alphaBuf = backgroundAlphaBuffer {
                enc.setFragmentBuffer(alphaBuf, offset: 0, index: 1)
            }

            // Bind cursor blink buffer
            if let blinkBuf = cursorBlinkBuffer {
                var visible: UInt32 = cursorBlinkState ? 1 : 0
                memcpy(blinkBuf.contents(), &visible, MemoryLayout<UInt32>.size)
                enc.setFragmentBuffer(blinkBuf, offset: 0, index: 2)
            }

            // Use 2-pass rendering when blur is enabled and pipelines are available
            let use2Pass = blurEnabled && backgroundPipeline != nil && glyphPipeline != nil

            if rowMode {
                // Row-based rendering - draw all row buffers directly (no merging)
                let safeRowCount = min(rowBuffersSnapshot.count, rowCountsSnapshot.count)
                var drawnRows = 0

                if use2Pass {
                    // Pass 1: Backgrounds (all rows)
                    enc.setRenderPipelineState(backgroundPipeline!)
                    for row in 0..<safeRowCount {
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                        drawnRows += 1
                    }
                    ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) drawnRows=\(drawnRows) use2Pass=true")

                    // Pass 2: Glyphs (all rows)
                    enc.setRenderPipelineState(glyphPipeline!)
                    for row in 0..<safeRowCount {
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                    }
                } else {
                    // Single-pass rendering (all rows)
                    enc.setRenderPipelineState(pipeline)
                    for row in 0..<safeRowCount {
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                        drawnRows += 1
                    }
                }
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) drawnRows=\(drawnRows) use2Pass=\(use2Pass)")
            } else if use2Pass, let vb = vertexBuffer {
                // 2-Pass rendering for blur: draw backgrounds first, then glyphs
                // Pass 1: Background (overwrite blending)
                enc.setRenderPipelineState(backgroundPipeline!)
                enc.setVertexBuffer(vb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)

                // Pass 2: Glyphs (standard alpha blending)
                enc.setRenderPipelineState(glyphPipeline!)
                enc.setVertexBuffer(vb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            } else {
                // Standard single-pass rendering
                enc.setRenderPipelineState(pipeline)
                if let vb = vertexBuffer {
                    enc.setVertexBuffer(vb, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
                }
            }

            enc.endEncoding()

            cmd.present(drawable)
            cmd.commit()

            // Mark that we've presented at least once
            hasPresentedOnce = true

            // Update scrollbar after rendering
            DispatchQueue.main.async { [weak self] in
                self?.updateScrollbarIfNeeded()
            }
        }
    }

    // MARK: - Private

    private func ensureVertexBufferCapacity(_ count: Int) {
        let needed = count * MemoryLayout<Vertex>.stride
        if needed <= vertexBufferCapacity { return }

        // Grow with some headroom
        let newCap = max(needed, vertexBufferCapacity * 2, 4096)
        vertexBuffer = mtlDevice.makeBuffer(length: newCap, options: .storageModeShared)
        vertexBufferCapacity = newCap
    }

    // MARK: - Smooth Scroll

    /// Update scroll offset shader uniform for visual sub-cell scrolling.
    /// Uses shared scroll offset info and computation from MetalTerminalRenderer.
    /// Returns true if a non-zero scroll offset is active.
    @discardableResult
    private func updateScrollShaderOffset() -> Bool {
        guard let main = mainTerminalView else { return false }

        let drawableHeight = Float(drawableSize.height)
        let cellHeightPx = Float(main.renderer.cellHeightPx)
        guard drawableHeight > 0 && cellHeightPx > 0 else { return false }

        // Get scroll offset info from main view (includes margin data from core)
        if var info = main.getScrollOffsetInfo(gridId: gridId, drawableHeight: drawableHeight, cellHeightPx: cellHeightPx) {
            // Clamp visual offset to prevent showing empty areas (black cracks) during scrolling
            let maxOffsetPx = cellHeightPx * 2.0
            info.offsetYPx = max(-maxOffsetPx, min(maxOffsetPx, info.offsetYPx))

            // External window: grid always starts at top (Y = 1.0 in NDC)
            // Override gridTopYNDC for external grids (unlike main window grids which may have startRow offset)
            info.gridTopYNDC = 1.0

            // Use shared computation logic from MetalTerminalRenderer
            // Zig generates vertex NDC using (sg.rows * cellH) as viewport height, so we must match that
            let viewportHeight = Float(info.gridRows) * cellHeightPx
            var scrollOffset = MetalTerminalRenderer.computeScrollOffset(info: info, viewportHeight: viewportHeight, cellHeightPx: cellHeightPx)

            ZonvieCore.appLog("[ExternalGridView] scroll offset: gridId=\(gridId) offsetPx=\(info.offsetYPx) marginTop=\(info.marginTop) marginBottom=\(info.marginBottom)")

            lock.lock()
            defer { lock.unlock() }

            scrollOffsetData = scrollOffset
            scrollOffsetActive = true
            return true  // Scroll offset is active
        } else {
            // No offset
            lock.lock()
            defer { lock.unlock() }

            scrollOffsetData = nil
            scrollOffsetActive = false
            return false  // No scroll offset
        }
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
        // Forward mouse event to Neovim if needed
        sendMouseEvent(button: "left", action: "press", event: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        sendMouseEvent(button: "left", action: "release", event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        window?.makeFirstResponder(self)
        sendMouseEvent(button: "right", action: "press", event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        sendMouseEvent(button: "right", action: "release", event: event)
    }

    private func sendMouseEvent(button: String, action: String, event: NSEvent) {
        guard let main = mainTerminalView, let core = main.core else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let cellWidthPx = CGFloat(main.renderer.cellWidthPx)
        let cellHeightPx = CGFloat(main.renderer.cellHeightPx)

        let location = convert(event.locationInWindow, from: nil)

        // Convert to cell coordinates (flip Y)
        let col = Int32(location.x * scale / cellWidthPx)
        let viewHeightPx = bounds.height * scale
        let row = Int32((viewHeightPx - location.y * scale) / cellHeightPx)

        // Build modifier string (same format as MetalTerminalView)
        let mods = event.modifierFlags
        var modStr = ""
        if mods.contains(.shift)   { modStr += "S" }
        if mods.contains(.control) { modStr += "C" }
        if mods.contains(.option)  { modStr += "A" }

        ZonvieCore.appLog("[ExternalGridView mouseEvent] button=\(button) action=\(action) gridId=\(gridId) row=\(row) col=\(col)")

        // Use nvim_input_mouse API via core.sendMouseInput (includes grid_id for ext_multigrid)
        core.sendMouseInput(button: button, action: action, modifier: modStr, gridId: gridId, row: row, col: col)
    }

    // MARK: - Key Event Handling with IME Support

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let main = mainTerminalView, let core = main.core else {
            return
        }

        let m = event.modifierFlags
        let hasControlOrCommand = m.contains(.control) || m.contains(.command)

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
            // Use sendKeyEvent (same as MetalTerminalView) instead of sendInput
            var mods: UInt32 = 0
            if m.contains(.control) { mods |= UInt32(ZONVIE_MOD_CTRL) }
            if m.contains(.option)  { mods |= UInt32(ZONVIE_MOD_ALT) }
            if m.contains(.shift)   { mods |= UInt32(ZONVIE_MOD_SHIFT) }
            if m.contains(.command) { mods |= UInt32(ZONVIE_MOD_SUPER) }

            core.sendKeyEvent(
                keyCode: UInt32(event.keyCode),
                mods: mods,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            return
        }

        // Let the system handle IME input.
        if let ctx = inputContext, ctx.handleEvent(event) {
            return
        }
        // Fallback: interpret key events directly.
        interpretKeyEvents([event])
    }

    /// Returns true for special keycodes that should bypass IME.
    private func isSpecialKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x35: return true  // Escape
        case 0x7B, 0x7C, 0x7D, 0x7E: return true  // Arrow keys
        case 0x24: return true  // Return
        case 0x30: return true  // Tab
        case 0x33: return true  // Delete (Backspace)
        case 0x75: return true  // Forward Delete
        case 0x73, 0x77: return true  // Home, End
        case 0x74, 0x79: return true  // Page Up, Page Down
        case 0x7A, 0x78, 0x63, 0x76: return true  // F1-F4
        case 0x60, 0x61, 0x62, 0x64: return true  // F5-F8
        case 0x65, 0x6D, 0x67, 0x6F: return true  // F9-F12
        default: return false
        }
    }

    override func keyUp(with event: NSEvent) {
        // Key up events typically not needed for terminal input
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier-only events typically not needed for terminal input
    }

    // MARK: - Scroll Event Handling

    override func scrollWheel(with event: NSEvent) {
        guard let main = mainTerminalView else { return }

        let deltaY = event.scrollingDeltaY
        if deltaY == 0 { return }

        // Calculate cell position from mouse location within this view
        let location = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2.0
        let cellWidthPx = CGFloat(main.renderer.cellWidthPx)
        let cellHeightPx = CGFloat(main.renderer.cellHeightPx)

        // Convert location to cell coordinates
        let col = Int32(location.x * scale / cellWidthPx)
        // Flip Y coordinate (view origin is bottom-left, grid origin is top-left)
        let viewHeightPx = bounds.height * scale
        let row = Int32((viewHeightPx - location.y * scale) / cellHeightPx)

        ZonvieCore.appLog("[ExternalGridView scroll] deltaY=\(deltaY) hasPrecise=\(event.hasPreciseScrollingDeltas) gridId=\(gridId) row=\(row) col=\(col)")

        // Use shared scroll handling from main view
        let newOffset = main.handleScrollInput(
            gridId: gridId,
            row: row,
            col: col,
            deltaY: deltaY,
            scale: scale,
            hasPrecise: event.hasPreciseScrollingDeltas
        )

        if event.hasPreciseScrollingDeltas {
            ZonvieCore.appLog("[ExternalGridView scroll] offset=\(newOffset)")

            // Process any pending scroll clears first to ensure offset is in sync with vertices
            main.processPendingScrollClears()

            // Update shader uniform with current visual offset
            updateScrollShaderOffset()

            // Request redraw to show the sub-cell offset
            requestRedraw()
        }
    }

    // MARK: - IME Preedit Overlay

    /// Show the preedit overlay with the given attributed text.
    private func showPreeditOverlay(attributedText: NSAttributedString, selectedRange: NSRange) {
        guard let main = mainTerminalView else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let cellW = CGFloat(main.renderer.cellWidthPx) / scale
        let cellH = CGFloat(main.renderer.cellHeightPx) / scale

        // Use the actual font from renderer
        let fontName = main.renderer.currentFontName
        let pointSize = main.renderer.currentPointSize
        let font = NSFont(name: fontName, size: pointSize) ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)

        // Configure preedit view with attributed text (preserves IME underline info)
        preeditView.configure(
            attributedText: attributedText,
            selectedRange: selectedRange,
            font: font,
            cellWidth: cellW,
            cellHeight: cellH
        )

        // Position at cursor location within this external window
        positionPreeditOverlay()

        preeditView.isHidden = false
    }

    /// Position the preedit overlay at the cursor location.
    private func positionPreeditOverlay() {
        guard let main = mainTerminalView, let core = main.core else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let cellW = CGFloat(main.renderer.cellWidthPx) / scale
        let cellH = CGFloat(main.renderer.cellHeightPx) / scale

        // Get cursor position from core if available
        let cursor = core.getCursorPosition()
        if cursor.row >= 0 && cursor.col >= 0 && cursor.gridId == gridId {
            // For external window, cursor position is relative to the grid itself
            let x = CGFloat(cursor.col) * cellW
            let y = bounds.height - CGFloat(cursor.row + 1) * cellH

            preeditView.frame.origin = CGPoint(x: x, y: y)
            return
        }

        // Fallback: position near top-left
        preeditView.frame.origin = CGPoint(x: cellW, y: bounds.height - cellH - preeditView.frame.height)
    }

    /// Hide the preedit overlay.
    private func hidePreeditOverlay() {
        preeditView.isHidden = true
        preeditView.clear()
    }
}

// MARK: - NSTextInputClient (IME support)
extension ExternalGridView: NSTextInputClient {

    /// Called when IME commits composed text or when direct character input occurs.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }

        // Clear marked text state and hide preedit overlay.
        markedText = NSMutableAttributedString()
        markedRange_ = NSRange(location: NSNotFound, length: 0)
        hidePreeditOverlay()

        // Send committed text to Neovim via core.
        if let core = mainTerminalView?.core {
            core.sendInput(text)
        }
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

        if markedText.length > 0 {
            markedRange_ = NSRange(location: 0, length: markedText.length)
            showPreeditOverlay(attributedText: markedText, selectedRange: selectedRange)
        } else {
            markedRange_ = NSRange(location: NSNotFound, length: 0)
            hidePreeditOverlay()
        }
        selectedRange_ = selectedRange
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
        return nil
    }

    /// Returns the rectangle for the character at the given index.
    /// Used by IME to position the candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let win = window, let main = mainTerminalView else { return .zero }

        let scale = win.backingScaleFactor
        let cellW = CGFloat(main.renderer.cellWidthPx) / scale
        let rowH = CGFloat(main.renderer.cellHeightPx) / scale

        var screenRow = 0
        var screenCol = 0

        if let core = main.core {
            let cursor = core.getCursorPosition()
            if cursor.row >= 0 && cursor.col >= 0 && cursor.gridId == gridId {
                screenRow = Int(cursor.row)
                screenCol = Int(cursor.col)
            }
        }

        let cursorXPt = CGFloat(screenCol) * cellW
        let cursorYPt = bounds.height - CGFloat(screenRow + 1) * rowH

        let rectInView = NSRect(x: cursorXPt, y: cursorYPt, width: cellW, height: rowH)
        let rectInWindow = convert(rectInView, to: nil)
        let rectInScreen = win.convertToScreen(rectInWindow)
        return rectInScreen
    }

    /// Returns the character index closest to the given point.
    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    // MARK: - Scrollbar

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled && !isCmdline else { return }

        // Setup scrollbar based on config
        if scrollbarConfig.isAlways {
            verticalScroller.isHidden = false
            verticalScroller.alphaValue = CGFloat(scrollbarConfig.opacity)
        }

        // Setup hover tracking for scrollbar (if "hover" mode is enabled)
        if scrollbarConfig.isHover {
            setupScrollbarHoverTracking()
        }
    }

    override func layout() {
        super.layout()
        layoutScrollbar()
    }

    private func layoutScrollbar() {
        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled && !isCmdline else { return }

        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        verticalScroller.frame = NSRect(
            x: bounds.width - scrollerWidth,
            y: 0,
            width: scrollerWidth,
            height: bounds.height
        )
    }

    /// Update scrollbar if viewport has changed (called after rendering)
    func updateScrollbarIfNeeded() {
        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled && !isCmdline else { return }
        guard let main = mainTerminalView, let core = main.core else { return }
        guard let viewport = core.getViewport(gridId: gridId) else { return }

        let viewportChanged = viewport.topline != lastViewportTopline ||
                              viewport.lineCount != lastViewportLineCount ||
                              viewport.botline != lastViewportBotline

        if viewportChanged {
            lastViewportTopline = viewport.topline
            lastViewportLineCount = viewport.lineCount
            lastViewportBotline = viewport.botline
            updateScrollbar(viewport: viewport)

            // Show scrollbar on scroll if "scroll" mode
            if scrollbarConfig.isScroll {
                showScrollbar()
            }
        }
    }

    private func updateScrollbar(viewport: ZonvieCore.ViewportInfo) {
        let config = ZonvieConfig.shared.scrollbar
        guard config.enabled else { return }

        let visibleLines = viewport.botline - viewport.topline
        let isScrollable = viewport.lineCount > visibleLines

        if !isScrollable {
            if config.isAlways {
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

    private func hideScrollbar() {
        let config = ZonvieConfig.shared.scrollbar
        if config.isAlways { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            verticalScroller.animator().alphaValue = 0.0
        }
    }

    @objc private func scrollerDidScroll(_ sender: NSScroller) {
        guard let main = mainTerminalView, let core = main.core else { return }
        guard let viewport = core.getViewport(gridId: gridId) else { return }

        let visibleLines = viewport.botline - viewport.topline

        switch sender.hitPart {
        case .decrementPage:
            // Click above knob - page up
            let newTopline = max(1, viewport.topline - (visibleLines - 2) + 1)
            core.scrollToLine(newTopline, useBottom: false)

        case .incrementPage:
            // Click below knob - page down
            let newTopline = min(viewport.lineCount - visibleLines + 1, viewport.topline + (visibleLines - 2) + 1)
            let targetLine = max(1, newTopline)
            core.scrollToLine(targetLine, useBottom: false)

        case .knob, .knobSlot:
            // Dragging knob
            let scrollRange = max(1, viewport.lineCount - visibleLines)
            let targetTopline = Int64(sender.doubleValue * Double(scrollRange)) + 1
            let clampedTopline = max(1, min(targetTopline, viewport.lineCount - visibleLines + 1))
            core.scrollToLine(clampedTopline, useBottom: false)

        default:
            break
        }
    }

    private func setupScrollbarHoverTracking() {
        if let existingArea = scrollbarTrackingArea {
            removeTrackingArea(existingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        scrollbarTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        let config = ZonvieConfig.shared.scrollbar
        if config.enabled && config.isHover && !isCmdline {
            let locationInView = convert(event.locationInWindow, from: nil)
            let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            if locationInView.x >= bounds.width - scrollerWidth {
                showScrollbar()
            }
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        let config = ZonvieConfig.shared.scrollbar
        if config.enabled && config.isHover && !isCmdline {
            hideScrollbar()
        }
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let config = ZonvieConfig.shared.scrollbar
        if config.enabled && config.isHover && !isCmdline {
            let locationInView = convert(event.locationInWindow, from: nil)
            let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            if locationInView.x >= bounds.width - scrollerWidth {
                showScrollbar()
            } else {
                hideScrollbar()
            }
        }
        super.mouseMoved(with: event)
    }
}
