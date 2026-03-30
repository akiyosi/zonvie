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
    private let redrawScheduler = SurfaceRedrawScheduler()

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

    // MARK: - Triple Buffering (same pattern as MetalTerminalRenderer)
    // Three buffer sets: one committed (being drawn), one write (being filled),
    // one free. gpuInFlightCount prevents beginFlush from picking a set that
    // the GPU is still reading.
    private let bufferSets: [SurfaceBufferSet] = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
    private var writeSetIndex: Int = 0            // Main thread only (during flush)
    private var flushSourceSetIndex: Int = 0      // Main thread only (during flush)
    private var committedSetIndex: Int = 0        // Protected by tripleBufferLock
    private var gpuInFlightCount: [Int] = [0, 0, 0] // Protected by tripleBufferLock
    private var isInFlush: Bool = false           // Flush bracket thread only
    private var flushHadContent: Bool = false     // True if vertices were submitted during this flush
    private var commitRevision: UInt64 = 0        // Protected by tripleBufferLock
    private var lastDrawnRevision: UInt64 = 0     // Draw only
    private var committedGridRows: UInt32 = 0     // Protected by tripleBufferLock
    private var committedGridCols: UInt32 = 0     // Protected by tripleBufferLock
    private let tripleBufferLock = NSLock()
    // GPU back-pressure: allow 2 in-flight command buffers.
    // With flush ops now running on core thread (not main), main thread is free
    // to process draw requests while GPU processes the previous frame.
    // Uses non-blocking tryWait since draw() runs on main thread.
    private let inflightSemaphore = DispatchSemaphore(value: 2)
    private let maxRowBuffers = 512

    // Active rendering mode: when new commits arrive, switch to isPaused=false
    // so MTKView draws at preferredFramesPerSecond (60fps). After idle, pause.
    private var activeDrawIdleFrames: Int = 0
    private let activeDrawIdleThreshold = 10  // Pause after N frames with no new commits

    // Scroll offset data stored as value-type; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race.
    private var scrollOffsetData: MetalTerminalRenderer.ScrollOffset?
    private var scrollOffsetActive: Bool = false
    private var lastPresentedScrollOffsetData: MetalTerminalRenderer.ScrollOffset?
    private var lastPresentedScrollOffsetActive: Bool = false

    // Accumulated scroll delta (consumed by draw, survives across flushes)
    // Protected by tripleBufferLock (accessed from both flush ops and draw)
    private var pendingScrollAccum: SurfaceRowScroll? = nil

    // Dirty rows accumulated during flush (consumed by draw)
    // Protected by tripleBufferLock
    private var pendingDirtyRows: Set<Int> = []

    // Persistent back buffer for partial redraw and GPU scroll copy
    private var backBuffer: MTLTexture? = nil
    private var backBufferSize: CGSize = .zero
    private var scrollScratchTexture: MTLTexture? = nil
    private var scrollScratchSize: CGSize = .zero

    // Blur transparency support
    private let blurEnabled: Bool
    private let isDecoratedSurface: Bool
    private var backgroundAlphaBuffer: MTLBuffer?

    // Viewport origin offset (in pixels) for decorated windows where the MTKView
    // fills the full container but grid content is inset by padding.
    // Allows bloom blur to bleed into the padding area around grid content.
    var viewportOriginPx: CGPoint = .zero

    // --- Post-process bloom (neon glow) ---
    // Pipelines and sampler are shared from MetalTerminalRenderer.
    // Textures are per-view (sizes differ per window).
    private let glowTextures = SurfaceGlowTextures()

    // Cursor blink support
    private var cursorBlinkBuffer: MTLBuffer?
    var cursorBlinkState: Bool = true
    private var lastRenderedBlinkState: Bool = true
    private var lastKnownCursorRow: Int = -1

    // Separate cursor vertex buffer (not part of row buffers, immune to GPU scroll copy)
    private var cursorVertexBuffer: MTLBuffer? = nil
    private var cursorVertexCount: Int = 0
    private var cursorDirty: Bool = false

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
    ///   - isDecoratedSurface: Whether this grid uses a decorated special-window shell
    init?(gridId: Int64,
          device: MTLDevice,
          atlas: GlyphAtlas,
          sharedPipeline: MTLRenderPipelineState,
          sharedBackgroundPipeline: MTLRenderPipelineState?,
          sharedGlyphPipeline: MTLRenderPipelineState?,
          sharedSampler: MTLSamplerState,
          blurEnabled: Bool = false,
          isDecoratedSurface: Bool = false) {
        self.gridId = gridId
        self.mtlDevice = device
        self.sharedAtlas = atlas
        self.blurEnabled = blurEnabled
        self.isDecoratedSurface = isDecoratedSurface

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
        self.preferredFramesPerSecond = 60
        self.isPaused = true
        self.enableSetNeedsDisplay = true  // Idle mode: manual redraw via setNeedsDisplay

        // Configure layer transparency for compositing with container background
        if isDecoratedSurface || blurEnabled {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            self.layer?.isOpaque = true
            self.layer?.backgroundColor = NSColor.black.cgColor
        }

        buildShaderBuffers()

        // Create background alpha buffer for shader
        backgroundAlphaBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
        if let buf = backgroundAlphaBuffer {
            var alpha = resolveSurfaceBackgroundAlpha(
                blurEnabled: blurEnabled,
                decoratedSurface: isDecoratedSurface
            )
            ZonvieCore.appLog("[ExternalGridView] backgroundAlphaBuffer alpha=\(alpha) isDecoratedSurface=\(isDecoratedSurface)")
            memcpy(buf.contents(), &alpha, MemoryLayout<Float>.size)
        }

        // Create cursor blink buffer for shader
        cursorBlinkBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        if let buf = cursorBlinkBuffer {
            var visible: UInt32 = 1
            memcpy(buf.contents(), &visible, MemoryLayout<UInt32>.size)
        }

        // Initial clear color. decoratedSurface → alpha=0 so the padding
        // outside the Metal viewport is transparent (container bg shows through).
        gridClearColor = makeSurfaceClearColor(
            red: 0,
            green: 0,
            blue: 0,
            blurEnabled: blurEnabled,
            decoratedSurface: isDecoratedSurface
        )

        // Add scrollbar only for normal detached grids.
        setupScrollbar()
    }

    deinit {
        ZonvieCore.appLog("[ExternalGridView] deinit: gridId=\(gridId)")

        // Invalidate scrollbar hide timer to break its run-loop retain.
        scrollbarHideTimer?.invalidate()
        scrollbarHideTimer = nil

        // Release Metal buffers held by all three SurfaceBufferSet objects.
        // Each set contains per-row MTLBuffer references that can total ~8MB.
        for bs in bufferSets {
            for i in 0..<bs.rowState.buffers.count {
                bs.rowState.buffers[i] = nil
            }
            bs.mainVertexBuffer = nil
            bs.cursorVertexBuffer = nil
        }

        // Release per-view Metal resources.
        vertexBuffer = nil
        cursorVertexBuffer = nil
        backBuffer = nil
        scrollScratchTexture = nil
        backgroundAlphaBuffer = nil
        cursorBlinkBuffer = nil

        // Release glow textures.
        glowTextures.extractTex = nil
        for i in 0..<glowTextures.mipTextures.count {
            glowTextures.mipTextures[i] = nil
        }
        glowTextures.intensityBuffer = nil
    }

    // MARK: - Active Draw Mode

    /// Switch to active draw mode: MTKView auto-draws at preferredFramesPerSecond.
    /// Called from commitFlush (core thread) when new content is committed.
    func activateDrawLoop() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            if self.isPaused {
                self.isPaused = false
                self.enableSetNeedsDisplay = false
                self.activeDrawIdleFrames = 0
            }
        }
    }

    /// Switch back to idle mode: manual redraw via setNeedsDisplay.
    private func deactivateDrawLoop() {
        guard !isPaused else { return }
        isPaused = true
        enableSetNeedsDisplay = true
    }

    private func setupScrollbar() {
        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled else { return }

        // Don't add scrollbar to decorated special grids.
        if isDecoratedSurface { return }

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
        tripleBufferLock.lock()
        let csi = committedSetIndex
        // Mark all rows dirty so the next draw() does a full redraw
        // (same as MetalTerminalRenderer.markAllRowsDirty).
        let totalRows = Int(committedGridRows)
        for row in 0..<totalRows {
            pendingDirtyRows.insert(row)
        }
        // Reset committed grid dimensions to force fallback to runtime values
        // until the next commitFlush provides new dimensions for the new font.
        committedGridRows = 0
        committedGridCols = 0
        tripleBufferLock.unlock()
        bufferSets[csi].rowState.resetCounts()
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
            ensureVertexBufferCapacity(count, forceReplace: true)
            if let vb = vertexBuffer {
                memcpy(vb.contents(), ptr, count * MemoryLayout<Vertex>.stride)
                pendingVertexCount = count
            } else {
                pendingVertexCount = 0
            }
        } else {
            pendingVertexCount = 0
        }
    }

    /// Begin flush bracket — pick a free buffer set and shallow-copy committed state (COW).
    /// Called on main thread before vertex submission during a flush cycle.
    func beginFlush() {
        tripleBufferLock.lock()
        let srcIdx = committedSetIndex
        let picked = pickFreeBufferSetIndex(
            count: 3,
            committedIndex: srcIdx,
            gpuInFlightCount: gpuInFlightCount
        )
        if picked == -1 {
            // All non-committed sets are GPU in-flight — drop this flush
            let inf = gpuInFlightCount
            tripleBufferLock.unlock()
            isInFlush = false
            ZonvieCore.appLog("[ExternalGridView] beginFlush: no free buffer set, dropping flush gridId=\(gridId) committed=\(srcIdx) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return
        }
        writeSetIndex = picked
        flushSourceSetIndex = srcIdx
        tripleBufferLock.unlock()

        isInFlush = true
        flushHadContent = false
        copySurfaceBufferSetRowState(from: bufferSets[srcIdx], to: bufferSets[picked])
    }

    /// Commit flush — publish write set as the new committed state for draw().
    /// Called from core thread (thread-safe via tripleBufferLock).
    func commitFlush() {
        guard isInFlush else { return }
        let hadContent = flushHadContent
        if hadContent {
            tripleBufferLock.lock()
            committedSetIndex = writeSetIndex
            committedGridRows = gridRows
            committedGridCols = gridCols
            commitRevision &+= 1
            tripleBufferLock.unlock()
        }
        isInFlush = false
        if hadContent {
            // Activate auto-draw so the new commit gets rendered at display refresh rate
            activateDrawLoop()
        }
    }

    /// Bump commit revision and request redraw without flush bracket.
    /// Used by the fallback path (main thread) when vertices are submitted
    /// outside of a core-thread flush bracket.
    func bumpRevisionAndRedraw() {
        tripleBufferLock.lock()
        commitRevision &+= 1
        tripleBufferLock.unlock()
        requestRedraw()
    }

    /// Apply row scroll notification from core.
    /// Called from the core/flush thread inside the flush bracket.
    /// Performs row slot remapping on the write set and records pending scroll for GPU blit.
    func applyRowScroll(rowStart: Int, rowEnd: Int, colStart: Int, colEnd: Int, rowsDelta: Int, totalRows: Int, totalCols: Int) {
        ZonvieCore.appLog("[ext_applyRowScroll] gridId=\(gridId) rowStart=\(rowStart) rowEnd=\(rowEnd) rowsDelta=\(rowsDelta) isInFlush=\(isInFlush)")
        guard isInFlush else {
            ZonvieCore.appLog("[ExternalGridView] applyRowScroll called outside flush bracket gridId=\(gridId)")
            return
        }
        guard rowsDelta != 0 else { return }
        guard rowStart >= 0, rowEnd > rowStart else { return }

        // Consumer-side eligibility: only remap for full-width, single-row scrolls
        guard colStart == 0, colEnd == totalCols else { return }

        let ws = bufferSets[writeSetIndex]
        remapSurfaceRowSlots(
            bufferSet: ws,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            totalRows: totalRows,
            maxRowBuffers: maxRowBuffers
        )

        ws.pendingScroll = SurfaceRowScroll(
            rowStart: rowStart,
            rowEnd: rowEnd,
            colStart: colStart,
            colEnd: colEnd,
            rowsDelta: rowsDelta,
            totalRows: totalRows,
            totalCols: totalCols
        )

        // Do NOT mark the entire scroll region as dirty here.
        // GPU scroll copy (blit) handles pixel shift; only vacated rows need redraw.
        // Core sends vertex data only for dirty rows (regen_count=1 in fast path).
        // Marking all rows dirty would cause full redraw, negating the blit benefit.

        // Accumulate scroll delta so draw() gets the total shift
        // even when multiple flushes occur between draws.
        flushHadContent = true
        tripleBufferLock.lock()
        if let existing = pendingScrollAccum,
           existing.rowStart == rowStart,
           existing.rowEnd == rowEnd {
            pendingScrollAccum = SurfaceRowScroll(
                rowStart: rowStart, rowEnd: rowEnd,
                colStart: colStart, colEnd: colEnd,
                rowsDelta: existing.rowsDelta + rowsDelta,
                totalRows: totalRows, totalCols: totalCols
            )
        } else {
            pendingScrollAccum = SurfaceRowScroll(
                rowStart: rowStart, rowEnd: rowEnd,
                colStart: colStart, colEnd: colEnd,
                rowsDelta: rowsDelta,
                totalRows: totalRows, totalCols: totalCols
            )
        }
        tripleBufferLock.unlock()
    }

    /// Submit vertices for a specific row (row-based update, same as main window).
    /// Writes to the write set during a flush bracket; uses COW detach for buffer safety.
    /// When flags contains ZONVIE_VERT_UPDATE_CURSOR (2), vertices are stored in a
    /// dedicated cursor buffer that is NOT part of the row buffer system and is therefore
    /// immune to GPU scroll copy. This prevents cursor ghost artifacts.
    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32 = 1, totalRows: Int, totalCols: Int) {
        gridRows = UInt32(totalRows)
        gridCols = UInt32(totalCols)

        // Cursor layer: store in dedicated cursor buffer (not in row buffers)
        let isCursorUpdate = (flags & 2) != 0  // ZONVIE_VERT_UPDATE_CURSOR
        if isCursorUpdate {
            lastKnownCursorRow = rowStart
            cursorDirty = true
            if count > 0, let validPtr = ptr {
                let byteCount = count * MemoryLayout<Vertex>.stride
                if cursorVertexBuffer == nil || cursorVertexBuffer!.length < byteCount {
                    cursorVertexBuffer = mtlDevice.makeBuffer(length: max(byteCount, 48 * MemoryLayout<Vertex>.stride), options: .storageModeShared)
                }
                if let buf = cursorVertexBuffer {
                    memcpy(buf.contents(), validPtr, byteCount)
                    cursorVertexCount = count
                }
            } else {
                cursorVertexCount = 0
            }
            return
        }

        // Normal row update (ZONVIE_VERT_UPDATE_MAIN)

        guard rowCount > 0 else { return }

        // Determine target: write set if in flush, otherwise committed set (legacy/new-grid path)
        let target: SurfaceBufferSet
        let source: SurfaceBufferSet?
        if isInFlush {
            target = bufferSets[writeSetIndex]
            source = bufferSets[flushSourceSetIndex]
        } else {
            tripleBufferLock.lock()
            let csi = committedSetIndex
            tripleBufferLock.unlock()
            target = bufferSets[csi]
            source = nil
        }

        submitSurfaceRowVertices(
            target: target,
            sourceSet: source,
            device: mtlDevice,
            rowStart: rowStart,
            ptr: UnsafeRawPointer(ptr),
            count: count,
            maxRowBuffers: maxRowBuffers,
            totalRows: totalRows
        )

        // Track dirty rows for GPU scroll copy path (match MetalTerminalRenderer.markDirtyRows)
        tripleBufferLock.lock()
        if rowCount > 0 {
            for r in rowStart..<max(rowStart, rowStart + rowCount) {
                pendingDirtyRows.insert(r)
            }
        }
        tripleBufferLock.unlock()
        flushHadContent = true
    }

    /// Request a redraw after vertices are submitted.
    func requestRedraw() {
        redrawScheduler.requestRedraw(rect: nil, bounds: bounds, window: window) { [weak self] redrawRect in
            guard let self else { return }
            self.setNeedsDisplay(redrawRect)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: - Back Buffer Management

    private func ensureBackBuffer(drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        if backBuffer != nil, backBufferSize == drawableSize { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(1, Int(drawableSize.width)),
            height: max(1, Int(drawableSize.height)),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        backBuffer = mtlDevice.makeTexture(descriptor: desc)
        backBufferSize = drawableSize
        hasPresentedOnce = false
    }

    private func ensureScrollScratchTexture(drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        if scrollScratchTexture != nil, scrollScratchSize == drawableSize { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(1, Int(drawableSize.width)),
            height: max(1, Int(drawableSize.height)),
            mipmapped: false
        )
        desc.storageMode = .private
        scrollScratchTexture = mtlDevice.makeTexture(descriptor: desc)
        scrollScratchSize = drawableSize
    }

    private func encodePendingScrollCopy(
        commandBuffer: MTLCommandBuffer,
        backTexture: MTLTexture,
        drawableWidthPx: Int,
        rowHeightPx: Int,
        scroll: SurfaceRowScroll
    ) -> (
        clearTopPx: Int,
        clearBottomPx: Int,
        vacatedRowStart: Int,
        vacatedRowEnd: Int
    )? {
        let shift = abs(scroll.rowsDelta)
        // Clamp rowEnd to the back buffer height. The scroll callback may report
        // sg.rows (e.g. 45 with winbar) while the drawable is only viewport_rows
        // (e.g. 44) tall. Without clamping, the blit reads beyond the texture.
        let texMaxRows = rowHeightPx > 0 ? backTexture.height / rowHeightPx : 0
        let clampedRowEnd = min(scroll.rowEnd, texMaxRows)
        let regionHeightRows = clampedRowEnd - scroll.rowStart
        guard shift > 0, shift < regionHeightRows else { return nil }
        guard drawableWidthPx > 0, rowHeightPx > 0 else { return nil }
        ensureScrollScratchTexture(drawableSize: backBufferSize, pixelFormat: backTexture.pixelFormat)
        guard let scratch = scrollScratchTexture,
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }

        let copyRows = regionHeightRows - shift
        let copyHeightPx = copyRows * rowHeightPx
        if copyHeightPx <= 0 {
            blit.endEncoding()
            return nil
        }

        let srcY = (scroll.rowsDelta > 0 ? scroll.rowStart + shift : scroll.rowStart) * rowHeightPx
        let dstY = (scroll.rowsDelta > 0 ? scroll.rowStart : scroll.rowStart + shift) * rowHeightPx

        // Clamp copy height to texture bounds
        let maxCopyHeight = backTexture.height - max(srcY, dstY)
        let safeCopyHeight = min(copyHeightPx, maxCopyHeight)
        guard safeCopyHeight > 0 else {
            blit.endEncoding()
            return nil
        }

        let origin = MTLOrigin(x: 0, y: srcY, z: 0)
        let size = MTLSize(width: min(drawableWidthPx, backTexture.width), height: safeCopyHeight, depth: 1)
        blit.copy(from: backTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                  to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                  to: backTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: dstY, z: 0))
        blit.endEncoding()

        let texHeightPx = backTexture.height
        if scroll.rowsDelta > 0 {
            let vacatedRowStart = clampedRowEnd - shift
            let vacatedRowEnd = clampedRowEnd
            return (
                min(vacatedRowStart * rowHeightPx, texHeightPx),
                min(vacatedRowEnd * rowHeightPx, texHeightPx),
                vacatedRowStart,
                vacatedRowEnd
            )
        } else {
            let vacatedRowStart = scroll.rowStart
            let vacatedRowEnd = min(scroll.rowStart + shift, clampedRowEnd)
            return (
                vacatedRowStart * rowHeightPx,
                min(vacatedRowEnd * rowHeightPx, texHeightPx),
                vacatedRowStart,
                vacatedRowEnd
            )
        }
    }

    private func ndcX(_ xPx: Float, drawableWidth: Float) -> Float {
        return (xPx / max(1.0, drawableWidth)) * 2.0 - 1.0
    }

    private func ndcY(_ yPx: Float, drawableHeight: Float) -> Float {
        return 1.0 - (yPx / max(1.0, drawableHeight)) * 2.0
    }

    private func drawBackgroundClearBand(
        _ encoder: MTLRenderCommandEncoder,
        clearBand: (clearTopPx: Int, clearBottomPx: Int),
        drawableWidth: Float,
        drawableHeight: Float,
        bgRGB: UInt32
    ) {
        let top = max(0, clearBand.clearTopPx)
        let bottom = max(top, clearBand.clearBottomPx)
        guard bottom > top else { return }
        let r = Float((bgRGB >> 16) & 0xFF) / 255.0
        let g = Float((bgRGB >> 8) & 0xFF) / 255.0
        let b = Float(bgRGB & 0xFF) / 255.0
        let color = simd_float4(r, g, b, 1.0)
        let tl = Vertex(position: simd_float2(ndcX(0, drawableWidth: drawableWidth), ndcY(Float(top), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let tr = Vertex(position: simd_float2(ndcX(drawableWidth, drawableWidth: drawableWidth), ndcY(Float(top), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let bl = Vertex(position: simd_float2(ndcX(0, drawableWidth: drawableWidth), ndcY(Float(bottom), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let br = Vertex(position: simd_float2(ndcX(drawableWidth, drawableWidth: drawableWidth), ndcY(Float(bottom), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        var verts = [tl, bl, tr, tr, bl, br]
        verts.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    func draw(in view: MTKView) {
        autoreleasepool {
            var finishedRedraw = false
            defer {
                if !finishedRedraw {
                    redrawScheduler.didDrawFrame()
                }
            }

            guard let pipeline = pipeline, let sampler = sampler else {
                ZonvieCore.appLog("[ExternalGridView] Pipeline not ready")
                return
            }

            if view.drawableSize.width <= 0 || view.drawableSize.height <= 0 {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) early return: drawableSize invalid (\(view.drawableSize))")
                return
            }

            // Skip rendering for minimized windows.
            // No frame-completion notification is needed here: unlike
            // MetalTerminalView (which uses redrawPending/didDrawFrame to
            // gate future redraws), ExternalGridView is driven directly
            // by setNeedsDisplay with no coalescing gate.
            if let window = view.window, window.isMiniaturized {
                return
            }

            // GPU back-pressure: non-blocking tryWait.
            // Unlike MetalTerminalRenderer (which uses blocking wait on a
            // separate render thread), ExternalGridView's draw() and flush
            // ops share the main thread — a blocking wait would deadlock.
            if inflightSemaphore.wait(timeout: .now()) != .success {
                // GPU still processing previous frame. Skip this draw but
                // schedule a retry so the frame is not permanently lost.
                redrawScheduler.didDrawFrame()
                finishedRedraw = true
                DispatchQueue.main.async { [weak self] in
                    self?.requestRedraw()
                }
                return
            }

            // --- Snapshot committed state under lock (same pattern as MetalTerminalRenderer) ---
            let csi: Int
            let currentCommitRevision: UInt64
            let pendingScroll: SurfaceRowScroll?
            let submittedDirtyRows: Set<Int>

            let snappedGridRows: UInt32
            let snappedGridCols: UInt32
            tripleBufferLock.lock()
            csi = committedSetIndex
            currentCommitRevision = commitRevision
            snappedGridRows = committedGridRows
            snappedGridCols = committedGridCols
            gpuInFlightCount[csi] += 1  // Prevent beginFlush from reusing this set
            // Snapshot and consume pending state
            pendingScroll = pendingScrollAccum ?? bufferSets[csi].pendingScroll
            pendingScrollAccum = nil
            submittedDirtyRows = pendingDirtyRows
            pendingDirtyRows.removeAll()
            tripleBufferLock.unlock()

            // Safety defer: decrement gpuInFlight and signal semaphore on early return.
            // On normal GPU submission, the completion handler handles cleanup.
            var gpuSubmitted = false
            defer {
                if !gpuSubmitted {
                    inflightSemaphore.signal()
                    tripleBufferLock.lock()
                    gpuInFlightCount[csi] -= 1
                    tripleBufferLock.unlock()
                }
            }

            let committed = bufferSets[csi]
            let rowMode = committed.rowState.usingRowBuffers
            // Use committed grid dimensions (snapped at commitFlush) to guarantee
            // viewport matches the NDC coordinates baked into committed vertices.
            // Same approach as MetalTerminalRenderer's committedDrawableW/H.
            // Use raw committed grid dimensions without clamping to drawable.
            // The core bakes NDC with grid_h = viewport_rows * cellH, so the
            // Metal viewport height MUST match viewport_rows exactly. If
            // viewport_rows exceeds drawable rows (e.g. sg.rows=45 with winbar
            // but window fits 44), Metal clips to the render target bounds
            // automatically — the NDC mapping stays correct for visible rows.
            let snapGridRows = snappedGridRows > 0 ? snappedGridRows : gridRows
            let snapGridCols = snappedGridCols > 0 ? snappedGridCols : gridCols
            let vertexCount: Int
            let vertexBufferSnapshot: MTLBuffer?

            if !rowMode {
                lock.lock()
                if let pending = pendingVertexCount {
                    currentVertexCount = pending
                    pendingVertexCount = nil
                }
                lock.unlock()
                vertexCount = currentVertexCount
                vertexBufferSnapshot = vertexBuffer
            } else {
                vertexCount = 0
                vertexBufferSnapshot = nil
            }

            if !rowMode && vertexCount <= 0 {
                return
            }
            if rowMode && committed.rowState.buffers.isEmpty {
                return
            }

            // --- Blink state change detection ---
            let blinkStateChanged = cursorBlinkState != lastRenderedBlinkState
            lastRenderedBlinkState = cursorBlinkState

            let drawableSizeChanged = backBufferSize != view.drawableSize && backBuffer != nil
            let hasNewCommit = currentCommitRevision != lastDrawnRevision
            lastDrawnRevision = currentCommitRevision
            let hasDirtyContent = hasNewCommit && !submittedDirtyRows.isEmpty
            let hasPendingScroll = hasNewCommit && pendingScroll != nil

            // Service shared scroll state before updating the ext-view shader.
            // External windows reuse the main view's scroll offset storage but
            // do not benefit from the main view's onPreDraw hook each frame.
            mainTerminalView?.serviceSharedScrollStateForExternalView()

            // Update scroll offset before early exit check so smooth scroll
            // (trackpad sub-cell offset changes) can trigger a redraw even
            // when no new flush has occurred.
            let hasScrollOffset = updateScrollShaderOffset()
            let scrollOffsetChanged = hasScrollOffsetStateChangedSinceLastPresent()
            let smoothScrolling = hasScrollOffset || wasScrollOffsetActiveInLastPresentedFrame()

            // Early exit: nothing changed
            let hasCursorUpdate = cursorDirty
            if hasCursorUpdate { cursorDirty = false }

            if rowMode && hasPresentedOnce && !blinkStateChanged && !hasDirtyContent && !hasPendingScroll && !drawableSizeChanged && !scrollOffsetChanged && !hasCursorUpdate && !smoothScrolling {
                ZonvieCore.appLog("[ext_draw_early_exit] gridId=\(gridId) idle")
                // Auto-pause: if no new content for several frames, switch to idle mode
                activeDrawIdleFrames += 1
                if activeDrawIdleFrames > activeDrawIdleThreshold {
                    deactivateDrawLoop()
                }
                return
            }
            activeDrawIdleFrames = 0
            if gridId == 4 {
                ZonvieCore.appLog("[ext_draw_why] gridId=4 rowMode=\(rowMode) presented=\(hasPresentedOnce) blink=\(blinkStateChanged) dirty=\(hasDirtyContent) scroll=\(hasPendingScroll) sizeChg=\(drawableSizeChanged) scrollOff=\(scrollOffsetChanged) cursor=\(hasCursorUpdate) hasNewCommit=\(hasNewCommit)")
            }

            // Blink-only frame: only blink state changed, no content updates
            let isBlinkOnlyFrame = blinkStateChanged
                && !hasDirtyContent
                && !hasPendingScroll
                && !drawableSizeChanged
                && !scrollOffsetChanged
                && !smoothScrolling
                && hasPresentedOnce

            // Compute viewport metrics early (needed for both row and non-row modes)
            // Cell dimensions — integer-rounded, same formula as MetalTerminalRenderer.
            let cw = Float(mainTerminalView?.renderer.cellWidthPx ?? 0)
            let ch = Float(mainTerminalView?.renderer.cellHeightPx ?? 0)
            let cellWi = max(1, UInt32(cw.rounded(.toNearestOrAwayFromZero)))
            let cellHi = max(1, UInt32(ch.rounded(.toNearestOrAwayFromZero)))
            // Viewport: grid-rows based (NOT drawable-based).
            // External grids have viewport_rows from external_grid_target_sizes
            // which may differ from drawableH / cellH. The core bakes NDC with
            // grid_h = viewport_rows * cellH, so vpHeight must match that.
            let vpWidth = Double(snapGridCols) * Double(cellWi)
            let vpHeight = Double(snapGridRows) * Double(cellHi)
            let scale = view.window?.backingScaleFactor ?? 2.0
            let vpOriginX = Double(viewportOriginPx.x) * Double(scale)
            let vpOriginY = Double(viewportOriginPx.y) * Double(scale)
            let viewportMetrics = SurfaceViewportMetrics(
                viewportWidth: vpWidth,
                viewportHeight: vpHeight,
                drawableSize: view.drawableSize,
                originX: vpOriginX,
                originY: vpOriginY
            )

            // GPU scroll copy eligibility:
            // - must be row mode with a pending scroll from the current commit
            // - must have presented at least once (back buffer has valid content)
            // - not during smooth scrolling / resize / glow rendering
            // - not for decorated surfaces (viewport origin offset complicates reuse)
            // Float overlay detection is handled at the core dispatch level
            // (flush.zig skips on_grid_row_scroll when float windows are anchored to the grid).
            // Check glow early — it disables partial-redraw optimizations to
            // prevent additive bloom composite from accumulating brightness.
            let glowEnabled = mainTerminalView?.core?.isGlowEnabled() ?? false

            let useGpuScrollCopy = rowMode
                && hasNewCommit
                && pendingScroll != nil
                && hasPresentedOnce
                && !smoothScrolling
                && !drawableSizeChanged
                && !glowEnabled
                && !isDecoratedSurface

            // Use 2-pass rendering when blur is enabled and pipelines are available
            let use2Pass = blurEnabled && backgroundPipeline != nil && glyphPipeline != nil

            // Row state resolution — compute early so canBlinkFastPath can use it.
            let safeRowCount = rowMode ? committed.rowLogicalToSlot.count : 0
            let rowTranslationDenom_px = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)

            func resolvedRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow >= 0, logicalRow < safeRowCount else { return nil }
                guard logicalRow < committed.rowLogicalToSlot.count else { return nil }
                let slot = committed.rowLogicalToSlot[logicalRow]
                guard slot >= 0, slot < committed.rowState.counts.count else { return nil }
                let vc = committed.rowState.counts[slot]
                guard vc > 0, slot < committed.rowState.buffers.count,
                      let vb = committed.rowState.buffers[slot] else { return nil }
                let sourceRow = slot < committed.rowSlotSourceRows.count ? committed.rowSlotSourceRows[slot] : logicalRow
                let translationY = Float(sourceRow - logicalRow) * Float(cellHi) / max(1.0, rowTranslationDenom_px) * 2.0
                return (vc, vb, translationY)
            }

            // Blink fast path gate — match MetalTerminalRenderer: requires blurEnabled
            let canBlinkFastPath: Bool = {
                guard isBlinkOnlyFrame && blurEnabled && rowMode && use2Pass && !glowEnabled else { return false }
                guard lastKnownCursorRow >= 0 && lastKnownCursorRow < safeRowCount else { return false }
                guard resolvedRowState(lastKnownCursorRow) != nil else { return false }
                return true
            }()

            // --- Ensure back buffer ---
            ensureBackBuffer(drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat)
            guard let backTex = backBuffer else { return }

            guard let cmd = queue.makeCommandBuffer() else { return }

            // --- GPU scroll blit (shift pixels in back buffer) ---
            // dirtyRows is only populated when GPU scroll copy is active.
            // Without scroll copy, the back buffer doesn't have pixel-shifted
            // content, so partial row updates would leave stale rows at wrong
            // positions. In that case dirtyRows stays empty and the full-redraw
            // fallback branch draws all rows.
            var scrollClearBand: (clearTopPx: Int, clearBottomPx: Int)? = nil
            var dirtyRows: [Int] = useGpuScrollCopy ? Array(submittedDirtyRows) : []
            if useGpuScrollCopy, let scroll = pendingScroll {
                let scrollCopy = encodePendingScrollCopy(
                    commandBuffer: cmd,
                    backTexture: backTex,
                    drawableWidthPx: Int(vpWidth > 0 ? vpWidth : view.drawableSize.width),
                    rowHeightPx: Int(cellHi),
                    scroll: scroll
                )
                if let scrollCopy {
                    scrollClearBand = (
                        clearTopPx: scrollCopy.clearTopPx,
                        clearBottomPx: scrollCopy.clearBottomPx
                    )
                    let dirtySet = Set(dirtyRows)
                    for row in scrollCopy.vacatedRowStart..<scrollCopy.vacatedRowEnd {
                        if !dirtySet.contains(row) {
                            dirtyRows.append(row)
                        }
                    }
                }
            }

            // --- Render into back buffer ---
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = backTex
            rpd.colorAttachments[0].storeAction = .store

            // loadAction logic — match MetalTerminalRenderer, plus cursor-only preservation.
            // MetalTerminalRenderer marks cursor rows in pendingDirtyRows via markDirtyRect,
            // so hasAnyDirtyInRowMode is true during cursor-only frames. ExternalGridView
            // uses a dedicated cursor buffer instead, so dirtyRows may be empty. In that
            // case, preserve the back buffer to avoid clearing valid content.
            let hasAnyDirtyInRowMode = rowMode && !dirtyRows.isEmpty
            let cursorOnlyFrame = (hasCursorUpdate || isBlinkOnlyFrame) && dirtyRows.isEmpty && !hasNewCommit
            // Decorated surfaces (ext-cmdline) always clear: their viewport origin offset
            // means scissor rects for partial redraw don't align correctly.
            let shouldReusePreviousContents = !isDecoratedSurface && !glowEnabled && (canBlinkFastPath || useGpuScrollCopy || cursorOnlyFrame || (!smoothScrolling && hasAnyDirtyInRowMode))
            rpd.colorAttachments[0].loadAction = resolveSurfaceColorLoadAction(
                blurEnabled: blurEnabled,
                hasPresentedOnce: hasPresentedOnce,
                drawableSizeChanged: drawableSizeChanged,
                shouldReusePreviousContents: shouldReusePreviousContents,
                forceReusePreviousContents: !isDecoratedSurface && !glowEnabled && (canBlinkFastPath || useGpuScrollCopy)
            )
            rpd.colorAttachments[0].clearColor = gridClearColor

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            viewportMetrics.applyViewport(to: enc)
            enc.setRenderPipelineState(pipeline)

            // Bind atlas texture (also captured for bloom extract pass)
            let atlasTex = mainTerminalView?.renderer.committedAtlasSnapshot()
            if let tex = atlasTex {
                enc.setFragmentTexture(tex, index: 0)
            } else {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) WARNING: committed atlas texture is nil!")
            }
            enc.setFragmentSamplerState(sampler, index: 0)

            // Bind scroll offset data via shared helper (no GPU/CPU race)
            let scrollOffsets: [MetalTerminalRenderer.ScrollOffset] = {
                lock.lock()
                defer { lock.unlock() }
                if scrollOffsetActive, let so = scrollOffsetData { return [so] }
                return []
            }()
            bindSurfaceScrollOffsets(encoder: enc, offsets: scrollOffsets, device: mtlDevice)

            // Bind fragment-side state (drawable size, background alpha, cursor blink)
            bindSurfaceFragmentState(
                encoder: enc,
                viewportMetrics: viewportMetrics,
                backgroundAlphaBuffer: backgroundAlphaBuffer,
                cursorBlinkBuffer: cursorBlinkBuffer,
                cursorBlinkVisible: cursorBlinkState
            )

            var zeroRowTranslation: Float = 0
            enc.setVertexBytes(&zeroRowTranslation, length: MemoryLayout<Float>.size, index: 3)

            // --- Row-mode rendering branches — match MetalTerminalRenderer structure ---
            if rowMode {
                // Debug: log translationY for all rows to detect slot remap drift
                var nonZeroTranslations: [(Int, Float, Int, Int)] = []
                for row in 0..<safeRowCount {
                    let slot = row < committed.rowLogicalToSlot.count ? committed.rowLogicalToSlot[row] : -1
                    let src = (slot >= 0 && slot < committed.rowSlotSourceRows.count) ? committed.rowSlotSourceRows[slot] : -1
                    if src != row {
                        if let resolved = resolvedRowState(row) {
                            nonZeroTranslations.append((row, resolved.translationY, slot, src))
                        }
                    }
                }
                if !nonZeroTranslations.isEmpty {
                    ZonvieCore.appLog("[ext_draw_debug] gridId=\(gridId) nonZeroTranslationY rows: \(nonZeroTranslations.map { "r\($0.0):ty=\($0.1):slot=\($0.2):src=\($0.3)" }.joined(separator: " "))")
                }
                ZonvieCore.appLog("[ext_draw_debug] gridId=\(gridId) safeRowCount=\(safeRowCount) dirtyRows=\(dirtyRows.count) useGpuScrollCopy=\(useGpuScrollCopy) use2Pass=\(use2Pass) canBlink=\(canBlinkFastPath) loadAction=\(rpd.colorAttachments[0].loadAction.rawValue) vpH=\(vpHeight) snapRows=\(snapGridRows)")

                let drawableW = max(0, Int(view.drawableSize.width.rounded(.down)))
                let cellH = max(1, Int(ch.rounded(.up)))

                if use2Pass {
                    // 2-pass rendering (blur enabled)
                    if canBlinkFastPath {
                        let cursorRow = lastKnownCursorRow
                        let resolved = resolvedRowState(cursorRow)!

                        let y = max(0, cursorRow * Int(cellHi))
                        let h = Int(cellHi)
                        if drawableW > 0 && h > 0 {
                            enc.setScissorRect(MTLScissorRect(x: 0, y: y, width: drawableW, height: h))
                        }

                        // Pass 1: Background (overwrite blending — erases old cursor)
                        enc.setRenderPipelineState(backgroundPipeline!)
                        var rowTranslation = resolved.translationY
                        enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)

                        // Pass 2: Glyph (alpha blending — redraws text/decorations)
                        enc.setRenderPipelineState(glyphPipeline!)
                        enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
                    } else if useGpuScrollCopy {
                        if let clearBand = scrollClearBand {
                            let bgRGB = extractRGBFromClearColor(gridClearColor)
                            drawBackgroundClearBand(
                                enc,
                                clearBand: clearBand,
                                drawableWidth: Float(vpWidth > 0 ? vpWidth : view.drawableSize.width),
                                drawableHeight: Float(vpHeight > 0 ? vpHeight : view.drawableSize.height),
                                bgRGB: bgRGB
                            )
                        }
                        let drawItems = buildSurfaceRowDrawItems(
                            rows: dirtyRows,
                            resolve: resolvedRowState
                        ) { row in
                            makeRowScissorRect(row: row, cellHeight_px: Int(cellHi), drawableWidth_px: drawableW)
                        }
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            items: drawItems,
                            pipeline: pipeline,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true
                        )
                    } else {
                        // 2-pass full redraw (same as MetalTerminalRenderer)
                        let drawItems = buildSurfaceRowDrawItems(safeRowCount: safeRowCount, resolve: resolvedRowState)
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            items: drawItems,
                            pipeline: pipeline,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true
                        )
                    }
                } else if smoothScrolling {
                    // Smooth scroll without blur: draw all rows without scissor
                    let drawItems = buildSurfaceRowDrawItems(safeRowCount: safeRowCount, resolve: resolvedRowState)
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        items: drawItems,
                        pipeline: pipeline,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else if useGpuScrollCopy {
                    if let clearBand = scrollClearBand {
                        let bgRGB = extractRGBFromClearColor(gridClearColor)
                        drawBackgroundClearBand(
                            enc,
                            clearBand: clearBand,
                            drawableWidth: Float(vpWidth > 0 ? vpWidth : Double(view.drawableSize.width)),
                            drawableHeight: Float(vpHeight > 0 ? vpHeight : Double(view.drawableSize.height)),
                            bgRGB: bgRGB
                        )
                    }
                    let drawItems = buildSurfaceRowDrawItems(
                        rows: dirtyRows,
                        resolve: resolvedRowState
                    ) { row in
                        makeRowScissorRect(row: row, cellHeight_px: cellH, drawableWidth_px: drawableW)
                    }
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        items: drawItems,
                        pipeline: pipeline,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else if !glowEnabled && !dirtyRows.isEmpty {
                    // Normal mode: scissor per dirty row (match MetalTerminalRenderer)
                    let drawItems = buildSurfaceRowDrawItems(
                        rows: dirtyRows,
                        resolve: resolvedRowState
                    ) { row in
                        makeRowScissorRect(row: row, cellHeight_px: cellH, drawableWidth_px: drawableW)
                    }
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        items: drawItems,
                        pipeline: pipeline,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else {
                    // Full redraw fallback
                    let drawItems = buildSurfaceRowDrawItems(safeRowCount: safeRowCount, resolve: resolvedRowState)
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        items: drawItems,
                        pipeline: pipeline,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                }
            } else {
                // Non-row-mode: shared helper handles 2-pass vs single-pass dispatch
                encodeSurfaceNonRowContent(
                    encoder: enc,
                    vertexBuffer: vertexBufferSnapshot,
                    vertexCount: vertexCount,
                    pipeline: pipeline,
                    backgroundPipeline: backgroundPipeline,
                    glyphPipeline: glyphPipeline,
                    useTwoPass: use2Pass
                )
            }

            // Cursor is NOT drawn into backbuffer — it is composited onto the
            // drawable after blit, so the persistent backbuffer stays cursor-free
            // and GPU scroll-region copies don't shift stale cursor pixels.

            enc.endEncoding()

            // --- Post-process bloom (neon glow) ---
            if glowEnabled,
               let renderer = mainTerminalView?.renderer,
               let extractPipe = renderer.glowExtractPipeline,
               let downPipe = renderer.kawaseDownPipeline,
               let upPipe = renderer.kawaseUpPipeline,
               let compositePipe = renderer.glowCompositePipeline,
               let copyVB = renderer.copyVertexBuffer,
               let bilinSamp = renderer.bilinearSampler
            {
                let vpSize = CGSize(width: viewportMetrics.viewportWidth, height: viewportMetrics.viewportHeight)
                glowTextures.ensure(device: mtlDevice, drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat)
                glowTextures.ensureIntensityBuffer(device: mtlDevice)
                let intensity = mainTerminalView?.core?.getGlowIntensity() ?? 0.8

                encodeSurfaceBloomPasses(
                    cmd: cmd,
                    backTex: backTex,
                    viewportSize: vpSize,
                    drawableSize: view.drawableSize,
                    viewportOrigin: CGPoint(x: vpOriginX, y: vpOriginY),
                    glowTextures: glowTextures,
                    extractPipeline: extractPipe,
                    kawaseDownPipeline: downPipe,
                    kawaseUpPipeline: upPipe,
                    compositePipeline: compositePipe,
                    copyVertexBuffer: copyVB,
                    bilinearSampler: bilinSamp,
                    intensity: intensity
                ) { enc in
                    // Set up atlas and scroll offsets for extract pass
                    // NOTE: DrawableSize (fragment buffer 0) is already set by the shared helper
                    if let tex = atlasTex {
                        enc.setFragmentTexture(tex, index: 0)
                    }
                    enc.setFragmentSamplerState(self.sampler!, index: 0)

                    var extractScrollCount = UInt32(scrollOffsets.count)
                    if !scrollOffsets.isEmpty {
                        scrollOffsets.withUnsafeBytes { ptr in
                            enc.setVertexBytes(ptr.baseAddress!, length: ptr.count, index: 1)
                        }
                    } else {
                        var dummy = MetalTerminalRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                        enc.setVertexBytes(&dummy, length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride, index: 1)
                        extractScrollCount = 0
                    }
                    enc.setVertexBytes(&extractScrollCount, length: MemoryLayout<UInt32>.size, index: 2)
                    var zeroTranslation: Float = 0
                    enc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)

                    // Draw row vertices
                    if rowMode {
                        for row in 0..<safeRowCount {
                            guard let resolved = resolvedRowState(row) else { continue }
                            var rowTranslation = resolved.translationY
                            enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                            enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
                        }
                    } else if vertexCount > 0, let vb = vertexBufferSnapshot {
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
                    }

                    // Cursor vertices for cursor glow
                    if cursorBlinkState, cursorVertexCount > 0, let cvb = cursorVertexBuffer {
                        var ct: Float = 0
                        enc.setVertexBytes(&ct, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(cvb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cursorVertexCount)
                    }
                }
            }

            // --- Blit back buffer to drawable ---
            guard let drawable = view.currentDrawable else {
                // Capture semaphore and lock directly so the signal fires even
                // if the view is deallocated before the GPU finishes.
                let sem = inflightSemaphore
                let tbLock = tripleBufferLock
                cmd.addCompletedHandler { [weak self] _ in
                    tbLock.lock()
                    self?.gpuInFlightCount[csi] -= 1
                    tbLock.unlock()
                    sem.signal()
                }
                cmd.commit()
                gpuSubmitted = true
                finishedRedraw = true
                redrawScheduler.didDrawFrame()
                return
            }
            if let blitEnc = cmd.makeBlitCommandEncoder() {
                let w = min(backTex.width, drawable.texture.width)
                let h = min(backTex.height, drawable.texture.height)
                blitEnc.copy(
                    from: backTex, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: w, height: h, depth: 1),
                    to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blitEnc.endEncoding()
            }

            // --- Cursor overlay: composited on drawable (not backbuffer) ---
            // Keeps persistent backbuffer cursor-free so GPU scroll copies
            // don't shift stale cursor pixels (same as MetalTerminalRenderer).
            if cursorBlinkState, cursorVertexCount > 0, let cursorBuf = cursorVertexBuffer {
                let cursorRPD = MTLRenderPassDescriptor()
                cursorRPD.colorAttachments[0].texture = drawable.texture
                cursorRPD.colorAttachments[0].loadAction = .load
                cursorRPD.colorAttachments[0].storeAction = .store

                if let cursorEnc = cmd.makeRenderCommandEncoder(descriptor: cursorRPD) {
                    viewportMetrics.applyViewport(to: cursorEnc)
                    cursorEnc.setRenderPipelineState(pipeline)
                    if let tex = mainTerminalView?.renderer.committedAtlasSnapshot() {
                        cursorEnc.setFragmentTexture(tex, index: 0)
                    }
                    cursorEnc.setFragmentSamplerState(sampler, index: 0)

                    let cursorScrollOffsets: [MetalTerminalRenderer.ScrollOffset] = {
                        lock.lock()
                        defer { lock.unlock() }
                        if scrollOffsetActive, let so = scrollOffsetData { return [so] }
                        return []
                    }()
                    bindSurfaceScrollOffsets(encoder: cursorEnc, offsets: cursorScrollOffsets, device: mtlDevice)
                    bindSurfaceFragmentState(
                        encoder: cursorEnc,
                        viewportMetrics: viewportMetrics,
                        backgroundAlphaBuffer: backgroundAlphaBuffer,
                        cursorBlinkBuffer: cursorBlinkBuffer,
                        cursorBlinkVisible: true
                    )
                    var zeroTranslation: Float = 0
                    cursorEnc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)
                    cursorEnc.setVertexBuffer(cursorBuf, offset: 0, index: 0)
                    cursorEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cursorVertexCount)
                    cursorEnc.endEncoding()
                }
            }

            cmd.present(drawable)
            // Capture semaphore and lock directly so the signal fires even
            // if the view is deallocated before the GPU finishes.
            let sem = inflightSemaphore
            let tbLock = tripleBufferLock
            cmd.addCompletedHandler { [weak self] _ in
                tbLock.lock()
                self?.gpuInFlightCount[csi] -= 1
                tbLock.unlock()
                sem.signal()
            }
            cmd.commit()
            gpuSubmitted = true

            // Mark that we've presented at least once
            markScrollOffsetStatePresented()
            hasPresentedOnce = true
            redrawScheduler.didDrawFrame()
            finishedRedraw = true

            // Update scrollbar after rendering
            DispatchQueue.main.async { [weak self] in
                self?.updateScrollbarIfNeeded()
            }
        }
    }

    // MARK: - Post-Process Bloom (Neon Glow) — uses shared encodeSurfaceBloomPasses()

    // MARK: - Private

    private func ensureVertexBufferCapacity(_ count: Int, forceReplace: Bool = false) {
        let needed = count * MemoryLayout<Vertex>.stride
        if !forceReplace && needed <= vertexBufferCapacity { return }

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

        // Get scroll offset info from the main view's shared scroll state.
        if var info = main.getScrollOffsetInfo(gridId: gridId, drawableHeight: drawableHeight, cellHeightPx: cellHeightPx) {
            // Clamp visual offset to prevent showing empty areas (black cracks) during scrolling
            let maxOffsetPx = cellHeightPx * 2.0
            info.offsetYPx = max(-maxOffsetPx, min(maxOffsetPx, info.offsetYPx))

            // Use the drawable-based coordinate space, matching the fragment
            // shader's screen-space clipping and the main window's calculation.
            let scrollOffset = MetalTerminalRenderer.computeScrollOffset(
                info: info,
                viewportHeight: drawableHeight,
                cellHeightPx: cellHeightPx
            )

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

    private func scrollOffsetsEqual(
        _ lhs: MetalTerminalRenderer.ScrollOffset?,
        _ rhs: MetalTerminalRenderer.ScrollOffset?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            let epsilon: Float = 0.0001
            return l.grid_id == r.grid_id
                && abs(l.offset_y - r.offset_y) < epsilon
                && abs(l.content_top_y - r.content_top_y) < epsilon
                && abs(l.content_bottom_y - r.content_bottom_y) < epsilon
        default:
            return false
        }
    }

    private func hasScrollOffsetStateChangedSinceLastPresent() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if scrollOffsetActive != lastPresentedScrollOffsetActive {
            return true
        }
        if !scrollOffsetActive {
            return false
        }
        return !scrollOffsetsEqual(scrollOffsetData, lastPresentedScrollOffsetData)
    }

    private func wasScrollOffsetActiveInLastPresentedFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastPresentedScrollOffsetActive
    }

    private func markScrollOffsetStatePresented() {
        lock.lock()
        defer { lock.unlock() }

        lastPresentedScrollOffsetActive = scrollOffsetActive
        lastPresentedScrollOffsetData = scrollOffsetData
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

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        sendMouseEvent(button: "left", action: "drag", event: event)
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

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        sendMouseEvent(button: "right", action: "drag", event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        window?.makeFirstResponder(self)
        if let btn = otherButtonName(event.buttonNumber) {
            sendMouseEvent(button: btn, action: "press", event: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        if let btn = otherButtonName(event.buttonNumber) {
            sendMouseEvent(button: btn, action: "release", event: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        super.otherMouseDragged(with: event)
        if let btn = otherButtonName(event.buttonNumber) {
            sendMouseEvent(button: btn, action: "drag", event: event)
        }
    }

    private func otherButtonName(_ buttonNumber: Int) -> String? {
        switch buttonNumber {
        case 2: return "middle"
        case 3: return "x1"
        case 4: return "x2"
        default: return nil
        }
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
        if mods.contains(.command) { modStr += "D" }

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

        // Check if Option key should be treated as Meta (Alt) based on config.
        // Left Option raw flag: 0x20, Right Option raw flag: 0x40.
        let optionIsMeta: Bool = {
            guard m.contains(.option) else { return false }
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
            if optionIsMeta          { mods |= UInt32(ZONVIE_MOD_ALT) }
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
        let deltaX = event.scrollingDeltaX
        if deltaY == 0 && deltaX == 0 { return }

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

        // Build modifier string for scroll event
        let modifier = main.buildModifierString(from: event.modifierFlags)

        // Vertical scroll
        if deltaY != 0 {
            ZonvieCore.appLog("[ExternalGridView scroll] deltaY=\(deltaY) hasPrecise=\(event.hasPreciseScrollingDeltas) gridId=\(gridId) row=\(row) col=\(col)")

            let newOffset = main.handleScrollInput(
                gridId: gridId,
                row: row,
                col: col,
                deltaY: deltaY,
                scale: scale,
                hasPrecise: event.hasPreciseScrollingDeltas,
                modifier: modifier
            )

            if event.hasPreciseScrollingDeltas {
                ZonvieCore.appLog("[ExternalGridView scroll] offset=\(newOffset)")
                main.serviceSharedScrollStateForExternalView()
                updateScrollShaderOffset()
                requestRedraw()
            }
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
            // For external window, cursor position is relative to the grid itself.
            // Add viewportOriginPx to account for decorated surfaces (e.g. cmdline icon/padding).
            let gridContentHeight = CGFloat(gridRows) * cellH
            let x = viewportOriginPx.x + CGFloat(cursor.col) * cellW
            let y = viewportOriginPx.y + gridContentHeight - CGFloat(cursor.row + 1) * cellH

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

        // Add viewportOriginPx to account for decorated surfaces (e.g. cmdline icon/padding).
        let gridContentHeight = CGFloat(gridRows) * rowH
        let cursorXPt = viewportOriginPx.x + CGFloat(screenCol) * cellW
        let cursorYPt = viewportOriginPx.y + gridContentHeight - CGFloat(screenRow + 1) * rowH

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

        // Deactivate draw loop when removed from window
        if window == nil {
            deactivateDrawLoop()
        }

        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled && !isDecoratedSurface else { return }

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
        guard scrollbarConfig.enabled && !isDecoratedSurface else { return }

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
        guard scrollbarConfig.enabled && !isDecoratedSurface else { return }
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
        if config.enabled && config.isHover && !isDecoratedSurface {
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
        if config.enabled && config.isHover && !isDecoratedSurface {
            hideScrollbar()
        }
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let config = ZonvieConfig.shared.scrollbar
        if config.enabled && config.isHover && !isDecoratedSurface {
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
