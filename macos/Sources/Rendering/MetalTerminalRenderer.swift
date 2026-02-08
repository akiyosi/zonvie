import AppKit
import Metal
import MetalKit
import simd

final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var atlas: GlyphAtlas

    /// Expose device for external grid views (shared Metal device).
    var metalDevice: MTLDevice { device }

    /// Expose atlas for external grid views (shared glyph cache).
    var glyphAtlas: GlyphAtlas { atlas }

    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var initializationError: String?
    private var pipelineNeedsBuilding = true
    private weak var viewForPipeline: MTKView?

    // 2-pass rendering pipelines for blur support
    // Background pipeline uses overwrite blending (one, zero) to avoid ghosting
    // Glyph pipeline uses standard alpha blending for correct antialiasing
    private var backgroundPipeline: MTLRenderPipelineState?
    private var glyphPipeline: MTLRenderPipelineState?

    // Copy pipeline for backBuffer -> drawable (replaces MTLBlitCommandEncoder)
    // Using render pipeline instead of blit avoids XPC compiler issues after fork()
    private var copyPipeline: MTLRenderPipelineState?
    private var copyVertexBuffer: MTLBuffer?

    // Binary archive for caching compiled pipeline states
    // This avoids XPC compiler service calls after first successful compilation
    private var binaryArchive: MTLBinaryArchive?

    /// Path to the binary archive file for caching pipeline states
    static var binaryArchivePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let zonvieDir = appSupport.appendingPathComponent("zonvie", isDirectory: true)
        // Create directory if needed
        try? FileManager.default.createDirectory(at: zonvieDir, withIntermediateDirectories: true)
        return zonvieDir.appendingPathComponent("pipeline_cache.metallib")
    }

    /// Ensure pipeline cache exists before fork.
    /// Call this from main.swift BEFORE fork() to avoid XPC errors in child process.
    /// XPC services (Metal shader compiler) don't survive fork(), so we must compile
    /// and cache pipelines in the parent process before forking.
    ///
    /// IMPORTANT: This function must NOT use FileManager or other high-level APIs
    /// that poison the fork() state. Using FileManager before fork() causes child
    /// process to crash with "USING_FORK_WITHOUT_EXEC_IS_NOT_SUPPORTED_BY_FILE_MANAGER".
    static func ensurePipelineCacheBeforeFork() {
        // Build path manually without FileManager (POSIX-safe for fork)
        // ~/Library/Application Support/zonvie/pipeline_cache.metallib
        guard let home = getenv("HOME") else { return }
        let homeStr = String(cString: home)
        let zonvieDir = homeStr + "/Library/Application Support/zonvie"
        let archivePathStr = zonvieDir + "/pipeline_cache.metallib"

        // Check if cache already exists using POSIX (fork-safe)
        var st = stat()
        if stat(archivePathStr, &st) == 0 {
            // File exists, skip
            return
        }

        // Create directory using POSIX mkdir (fork-safe)
        // Create parent directories as needed
        mkdir((homeStr + "/Library/Application Support").cString(using: .utf8)!, 0o755)
        mkdir(zonvieDir.cString(using: .utf8)!, 0o755)

        // Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        // Get shader library
        guard let lib = device.makeDefaultLibrary(),
              let vs = lib.makeFunction(name: "vs_main"),
              let fs = lib.makeFunction(name: "ps_main"),
              let fsBg = lib.makeFunction(name: "ps_background"),
              let fsGlyph = lib.makeFunction(name: "ps_glyph"),
              let vsCopy = lib.makeFunction(name: "vs_copy"),
              let fsCopy = lib.makeFunction(name: "ps_copy") else {
            return
        }

        // Create vertex descriptor (must match MetalTerminalRenderer.makeVertexDescriptor)
        guard let vertexDesc = makeVertexDescriptor() else {
            return
        }

        // Create copy vertex descriptor (simple position + texcoord)
        guard let copyVertexDesc = makeCopyVertexDescriptor() else {
            return
        }

        // Use common pixel format (matches MTKView default)
        let pixelFormat: MTLPixelFormat = .bgra8Unorm

        // Main pipeline descriptor
        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.vertexFunction = vs
        mainDesc.fragmentFunction = fs
        mainDesc.vertexDescriptor = vertexDesc
        mainDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = mainDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        // Background pipeline descriptor (for blur 2-pass)
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = vs
        bgDesc.fragmentFunction = fsBg
        bgDesc.vertexDescriptor = vertexDesc
        bgDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = bgDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .zero
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .zero
        }

        // Glyph pipeline descriptor (for blur 2-pass)
        let glyphDesc = MTLRenderPipelineDescriptor()
        glyphDesc.vertexFunction = vs
        glyphDesc.fragmentFunction = fsGlyph
        glyphDesc.vertexDescriptor = vertexDesc
        glyphDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = glyphDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        // Copy pipeline descriptor (for backBuffer -> drawable copy, replaces Blit)
        let copyDesc = MTLRenderPipelineDescriptor()
        copyDesc.vertexFunction = vsCopy
        copyDesc.fragmentFunction = fsCopy
        copyDesc.vertexDescriptor = copyVertexDesc
        copyDesc.colorAttachments[0].pixelFormat = pixelFormat
        // No blending needed for copy - just overwrite
        if let a = copyDesc.colorAttachments[0] {
            a.isBlendingEnabled = false
        }

        // Compile pipelines (this uses XPC - must happen before fork)
        do {
            _ = try device.makeRenderPipelineState(descriptor: mainDesc)
            _ = try device.makeRenderPipelineState(descriptor: bgDesc)
            _ = try device.makeRenderPipelineState(descriptor: glyphDesc)
            _ = try device.makeRenderPipelineState(descriptor: copyDesc)

            // Cache to binary archive
            let archiveDesc = MTLBinaryArchiveDescriptor()
            let archive = try device.makeBinaryArchive(descriptor: archiveDesc)
            try archive.addRenderPipelineFunctions(descriptor: mainDesc)
            try archive.addRenderPipelineFunctions(descriptor: bgDesc)
            try archive.addRenderPipelineFunctions(descriptor: glyphDesc)
            try archive.addRenderPipelineFunctions(descriptor: copyDesc)
            try archive.serialize(to: URL(fileURLWithPath: archivePathStr))
        } catch {
            // Errors are ignored - child process will retry (though it may fail)
        }
    }

    private let lock = NSLock()

    private var pendingMainCount: Int? = nil
    private var pendingCursorCount: Int? = nil
    private var currentMainCount: Int = 0
    private var currentCursorCount: Int = 0

    private var pendingFont: (name: String, size: CGFloat)?
    private var linespacePx: Int32 = 0

    private var backingScale: CGFloat = 1.0

    var onCellMetricsChanged: ((Float, Float) -> Void)?

    /// Called at the beginning of each draw call, before rendering.
    /// Used to process pending scroll clears from grid_scroll events.
    var onPreDraw: (() -> Void)?

    private var lastCellWidthPx: Float = 0
    private var lastCellHeightPx: Float = 0

    func setBackingScale(_ s: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        backingScale = s
    }

    /// Cell width in drawable pixel coordinates.
    var cellWidthPx: Float { atlas.cellWidthPx }

    /// Cell height in drawable pixel coordinates.
    // var cellHeightPx: Float { atlas.cellHeightPx }
    var cellHeightPx: Float { atlas.cellHeightPx + Float(linespacePx) }


    /// Font ascent in drawable pixel coordinates.
    var ascentPx: Float { atlas.ascentPx }

    /// Font descent in drawable pixel coordinates.
    var descentPx: Float { atlas.descentPx }

    /// Current font name.
    var currentFontName: String { atlas.currentFontName }

    /// Current point size (before scaling).
    var currentPointSize: CGFloat { atlas.currentPointSize }

    // MARK: - Shared Resources for External Grid Views

    /// Expose main pipeline for external grid views (shared shader compilation).
    var sharedPipeline: MTLRenderPipelineState? { pipeline }

    /// Expose 2-pass background pipeline for blur support.
    var sharedBackgroundPipeline: MTLRenderPipelineState? { backgroundPipeline }

    /// Expose 2-pass glyph pipeline for blur support.
    var sharedGlyphPipeline: MTLRenderPipelineState? { glyphPipeline }

    /// Expose sampler for external grid views.
    var sharedSampler: MTLSamplerState? { sampler }

    func atlasEnsureGlyphEntry(scalar: UInt32) -> GlyphAtlas.Entry? {
        // No lock needed here - GlyphAtlas.entry() has its own mu.lock() internally
        // Removing the double-lock significantly improves performance
        return atlas.entry(for: scalar)
    }

    func atlasEnsureGlyphEntryStyled(scalar: UInt32, styleFlags: UInt32) -> GlyphAtlas.Entry? {
        // No lock needed here - GlyphAtlas.entry() has its own mu.lock() internally
        // Removing the double-lock significantly improves performance
        return atlas.entry(for: scalar, styleFlags: styleFlags)
    }

    // Phase 2: Core-managed atlas pass-through

    func rasterizeGlyphOnly(scalar: UInt32, styleFlags: UInt32, outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>) -> Bool {
        return atlas.rasterizeOnly(scalar: scalar, styleFlags: styleFlags, outBitmap: outBitmap)
    }

    func uploadAtlasRegion(destX: UInt32, destY: UInt32, width: UInt32, height: UInt32, bitmap: UnsafePointer<zonvie_glyph_bitmap>) {
        atlas.uploadRegion(destX: Int(destX), destY: Int(destY), width: Int(width), height: Int(height), bitmap: bitmap)
    }

    func recreateAtlasTexture(width: UInt32, height: UInt32) {
        atlas.recreateTexture(width: Int(width), height: Int(height))
    }

    private var vertexBuffer: MTLBuffer?
    private var vertexBufferCapacity: Int = 0

    private var cursorVertexBuffer: MTLBuffer?
    private var cursorVertexBufferCapacity: Int = 0

    /// Cursor blink state (true = visible, false = hidden during blink)
    var cursorBlinkState: Bool = true
    /// Last rendered blink state to detect changes
    private var lastRenderedBlinkState: Bool = true

    // --- Scroll offset for smooth scrolling ---
    private var scrollOffsetBuffer: MTLBuffer?
    private var scrollOffsetCountBuffer: MTLBuffer?
    private var hasActiveScrollOffset: Bool = false  // true when smooth scrolling is active

    // ScrollOffset struct matching Shaders.metal
    struct ScrollOffset {
        var grid_id: Int32
        var offset_y: Float         // Y offset in NDC
        var content_top_y: Float    // Top Y of scrollable content (below margin top), in NDC
        var content_bottom_y: Float // Bottom Y of scrollable content (above margin bottom), in NDC
    }

    // DrawableSize struct matching Shaders.metal (for fragment shader clipping)
    struct DrawableSize {
        var width: Float
        var height: Float
    }
    private var drawableSizeBuffer: MTLBuffer?

    // Row-based vertex buffers for partial updates
    private var rowVertexBuffers: [MTLBuffer?] = []
    private var rowVertexBufferCaps: [Int] = []     // bytes capacity per row buffer
    private var rowVertexCounts: [Int] = []         // vertex count per row
    private var usingRowBuffers: Bool = false

    /// Maximum row buffer count to prevent unbounded memory growth (1000 rows = ~40KB overhead)
    private let maxRowBuffers: Int = 1000

    // --- Dirty region tracking (drawable pixel coordinates) ---
    private var pendingDirtyRectPx: NSRect? = nil
    private var pendingDirtyRows: IndexSet = IndexSet()
    private var hasPresentedOnce: Bool = false

    // --- Persistent back buffer (for correct partial redraw) ---
    private var backBuffer: MTLTexture? = nil
    private var backBufferSize: CGSize = .zero

    // --- Blur transparency support ---
    private let blurEnabled: Bool
    private var backgroundAlphaBuffer: MTLBuffer?

    // --- Cursor blink support for shader ---
    private var cursorBlinkBuffer: MTLBuffer?

    private func ensureBackBuffer(drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        if backBuffer != nil, backBufferSize == drawableSize { return }

        let oldSize = backBufferSize
        let wasPresented = hasPresentedOnce

        let w = max(1, Int(drawableSize.width))
        let h = max(1, Int(drawableSize.height))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private

        backBuffer = device.makeTexture(descriptor: desc)
        backBufferSize = drawableSize

        // After resize, we must clear once (contents undefined).
        hasPresentedOnce = false

        // DEBUG: Track backBuffer resize and hasPresentedOnce reset
        ZonvieCore.appLog("[DEBUG-RESIZE] ensureBackBuffer: oldSize=\(oldSize) newSize=\(drawableSize) wasPresented=\(wasPresented) -> hasPresentedOnce=false")
    }

    init?(view: MTKView) {
        guard let dev = view.device else {
            ZonvieCore.appLog("[Renderer] init failed: MTKView.device is nil")
            return nil
        }
        self.device = dev
        guard let q = dev.makeCommandQueue() else {
            ZonvieCore.appLog("[Renderer] init failed: Failed to create command queue")
            return nil
        }
        self.queue = q

        // Font priority: config.font.family > OS default (Menlo)
        let initialFont = ZonvieConfig.shared.font.family.isEmpty ? "Menlo" : ZonvieConfig.shared.font.family
        let initialSize = ZonvieConfig.shared.font.size > 0 ? ZonvieConfig.shared.font.size : 14.0
        ZonvieCore.appLog("[Renderer] init: initial font='\(initialFont)' size=\(initialSize)")

        self.atlas = GlyphAtlas(device: dev, fontName: initialFont, pointSize: CGFloat(initialSize))
        self.blurEnabled = ZonvieConfig.shared.blurEnabled

        super.init()

        ZonvieCore.appLog("[Renderer] init: blurEnabled=\(blurEnabled) ZonvieConfig.shared.blurEnabled=\(ZonvieConfig.shared.blurEnabled) backgroundAlpha=\(ZonvieConfig.shared.backgroundAlpha)")

        // Defer pipeline building to first draw to avoid XPC errors during init
        // when multiple instances start simultaneously
        self.viewForPipeline = view
        self.pipelineNeedsBuilding = true
        buildSampler()
        buildScrollOffsetBuffers()

        // Create background alpha buffer for shader
        backgroundAlphaBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
        if let buf = backgroundAlphaBuffer {
            var alpha: Float = blurEnabled ? ZonvieConfig.shared.backgroundAlpha : 1.0
            ZonvieCore.appLog("[Renderer] backgroundAlphaBuffer alpha=\(alpha)")
            memcpy(buf.contents(), &alpha, MemoryLayout<Float>.size)
        }

        // Create cursor blink buffer for shader (always visible for main window cursor)
        cursorBlinkBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        if let buf = cursorBlinkBuffer {
            var visible: UInt32 = 1
            memcpy(buf.contents(), &visible, MemoryLayout<UInt32>.size)
        }
    }

    private func buildScrollOffsetBuffers() {
        // Initialize scroll offset count buffer with zero
        scrollOffsetCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        if let countBuf = scrollOffsetCountBuffer {
            var zero: UInt32 = 0
            memcpy(countBuf.contents(), &zero, MemoryLayout<UInt32>.size)
        }
        // Initialize scroll offset buffer (will grow as needed)
        scrollOffsetBuffer = device.makeBuffer(length: 256, options: .storageModeShared)

        // Initialize drawable size buffer for fragment shader clipping
        drawableSizeBuffer = device.makeBuffer(length: MemoryLayout<DrawableSize>.size, options: .storageModeShared)
    }

    /// Ensure pipeline is ready for use by external grid views.
    /// Called before creating ExternalGridView to guarantee shared pipeline availability.
    /// This builds the pipeline synchronously if not already done.
    func ensurePipelineReady(view: MTKView) {
        if pipelineNeedsBuilding {
            pipelineNeedsBuilding = false
            buildPipeline(view: view)
            ZonvieCore.appLog("[Renderer] Pipeline built on demand for external grid")
        }
    }

    func submitVerticesRaw(
        mainPtr: UnsafeRawPointer?, mainCount: Int,
        cursorPtr: UnsafeRawPointer?, cursorCount: Int
    ) {
        lock.lock()
        defer { lock.unlock() }

        usingRowBuffers = false
        pendingDirtyRows.removeAll()
        pendingDirtyRectPx = nil
    
        // main (always updated)
        if mainCount > 0, let mainPtr {
            ensureVertexBufferCapacity(mainCount)
            if let vb = vertexBuffer {
                memcpy(vb.contents(), mainPtr, mainCount * MemoryLayout<Vertex>.stride)
                pendingMainCount = mainCount
            } else {
                pendingMainCount = 0
            }
        } else {
            pendingMainCount = 0
        }
    
        // cursor (always updated)
        if cursorCount > 0, let cursorPtr {
            ensureCursorVertexBufferCapacity(cursorCount)
            if let cvb = cursorVertexBuffer {
                memcpy(cvb.contents(), cursorPtr, cursorCount * MemoryLayout<Vertex>.stride)
                pendingCursorCount = cursorCount
            } else {
                pendingCursorCount = 0
            }
        } else {
            pendingCursorCount = 0
        }
    }

    func submitVerticesPartialRaw(
        mainPtr: UnsafeRawPointer?, mainCount: Int,
        cursorPtr: UnsafeRawPointer?, cursorCount: Int,
        updateMain: Bool,
        updateCursor: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
    
        if updateMain {
            if mainCount > 0, let mainPtr {
                ensureVertexBufferCapacity(mainCount)
                if let vb = vertexBuffer {
                    memcpy(vb.contents(), mainPtr, mainCount * MemoryLayout<Vertex>.stride)
                    pendingMainCount = mainCount
                } else {
                    pendingMainCount = 0
                }
            } else {
                // explicit "clear main"
                pendingMainCount = 0
            }
        }
        // When updateMain == false, don't touch pendingMainCount (keep as nil)

        if updateCursor {
            if cursorCount > 0, let cursorPtr {
                ensureCursorVertexBufferCapacity(cursorCount)
                if let cvb = cursorVertexBuffer {
                    memcpy(cvb.contents(), cursorPtr, cursorCount * MemoryLayout<Vertex>.stride)
                    pendingCursorCount = cursorCount
                } else {
                    pendingCursorCount = 0
                }
            } else {
                // explicit "clear cursor"
                pendingCursorCount = 0
            }
        }
        // When updateCursor == false, don't touch pendingCursorCount (keep as nil)
    }

    func setGuiFont(name: String, pointSize: CGFloat) {
        ZonvieCore.appLog("renderer setGuiFont: \(name) \(pointSize)")
        lock.lock()
        defer { lock.unlock() }
        pendingFont = (name, pointSize)
    }

    func setLineSpace(px: Int32) {
        lock.lock()
        defer { lock.unlock() }
        linespacePx = max(0, px)
    }

    /// Update scroll offsets for smooth scrolling.
    /// Scroll offset info for a grid (includes margin info)
    struct ScrollOffsetInfo {
        var gridId: Int64
        var offsetYPx: Float       // Pixel offset (scroll delta)
        var gridTopYNDC: Float     // Grid's top Y in NDC
        var gridRows: Int32        // Total rows in grid
        var marginTop: Int32       // Margin rows at top (not scrollable)
        var marginBottom: Int32    // Margin rows at bottom (not scrollable)
    }

    /// - Parameters:
    ///   - offsets: Array of ScrollOffsetInfo with margin data
    ///   - drawableHeight: Current drawable height for NDC conversion
    ///   - cellHeightPx: Cell height in pixels
    func updateScrollOffsets(_ offsets: [ScrollOffsetInfo], drawableHeight: Float, cellHeightPx: Float) {
        // Convert pixel offsets to NDC
        // NDC Y: -1 (bottom) to +1 (top), so 2.0 units = drawableHeight pixels
        // Scrolling down (positive pixel offset) should move content up (negative NDC offset)
        let scale: Float = drawableHeight > 0 ? 2.0 / drawableHeight : 0
        let cellHeightNDC: Float = cellHeightPx * scale

        var scrollOffsets = offsets.map { info in
            let ndc = -info.offsetYPx * scale

            // Calculate content bounds in NDC
            // Grid top is info.gridTopYNDC
            // Content starts after margin_top rows (going down = lower Y in NDC)
            // Subtract a small epsilon to ensure boundary vertices (at exactly marginTop row edge)
            // are NOT scrolled. Without this, the margin area's background quad bottom edge
            // would be scrolled, causing the quad to deform.
            let epsilon: Float = 0.001 * cellHeightNDC
            let contentTopY = info.gridTopYNDC - Float(info.marginTop) * cellHeightNDC - epsilon
            // Content ends before margin_bottom rows
            // Add epsilon to ensure boundary vertices at bottom margin edge are NOT scrolled
            let contentBottomY = info.gridTopYNDC - Float(info.gridRows - info.marginBottom) * cellHeightNDC + epsilon

            ZonvieCore.appLog("[renderer] scroll offset: gridId=\(info.gridId) offsetYPx=\(info.offsetYPx) ndc=\(ndc) contentTop=\(contentTopY) contentBottom=\(contentBottomY)")
            return ScrollOffset(
                grid_id: Int32(truncatingIfNeeded: info.gridId),
                offset_y: ndc,
                content_top_y: contentTopY,
                content_bottom_y: contentBottomY
            )
        }

        let count = scrollOffsets.count
        ZonvieCore.appLog("[renderer] updateScrollOffsets: count=\(count) drawableHeight=\(drawableHeight)")

        lock.lock()
        defer { lock.unlock() }

        if count > 0 {
            let neededBytes = count * MemoryLayout<ScrollOffset>.stride
            if let existingBuf = scrollOffsetBuffer, existingBuf.length >= neededBytes {
                // Buffer is large enough, reuse it
            } else {
                scrollOffsetBuffer = device.makeBuffer(length: max(neededBytes, 256), options: .storageModeShared)
            }
            if let buf = scrollOffsetBuffer {
                scrollOffsets.withUnsafeMutableBytes { ptr in
                    guard let baseAddr = ptr.baseAddress else { return }
                    memcpy(buf.contents(), baseAddr, neededBytes)
                }
            }
        }

        // Update count buffer
        if let countBuf = scrollOffsetCountBuffer {
            var countVal = UInt32(count)
            memcpy(countBuf.contents(), &countVal, MemoryLayout<UInt32>.size)
        }

        // Track whether we have active scroll offsets
        hasActiveScrollOffset = count > 0
    }

    /// Clear scroll offsets (reset to no offset)
    func clearScrollOffsets() {
        lock.lock()
        defer { lock.unlock() }

        if let countBuf = scrollOffsetCountBuffer {
            var zero: UInt32 = 0
            memcpy(countBuf.contents(), &zero, MemoryLayout<UInt32>.size)
        }
        hasActiveScrollOffset = false
    }

    /// Compute ScrollOffset from ScrollOffsetInfo (shared logic for main window and external grids).
    /// - Parameters:
    ///   - info: Scroll offset info with margin data
    ///   - viewportHeight: Height used for NDC calculation (in pixels)
    ///   - cellHeightPx: Cell height in pixels
    /// - Returns: ScrollOffset struct ready for shader
    static func computeScrollOffset(info: ScrollOffsetInfo, viewportHeight: Float, cellHeightPx: Float) -> ScrollOffset {
        let scale: Float = viewportHeight > 0 ? 2.0 / viewportHeight : 0
        let cellHeightNDC: Float = cellHeightPx * scale
        let ndc = -info.offsetYPx * scale

        // Calculate content bounds in NDC
        // Subtract a small epsilon to ensure boundary vertices at margin edge are NOT scrolled
        let epsilon: Float = 0.001 * cellHeightNDC
        let contentTopY = info.gridTopYNDC - Float(info.marginTop) * cellHeightNDC - epsilon
        let contentBottomY = info.gridTopYNDC - Float(info.gridRows - info.marginBottom) * cellHeightNDC + epsilon

        return ScrollOffset(
            grid_id: Int32(truncatingIfNeeded: info.gridId),
            offset_y: ndc,
            content_top_y: contentTopY,
            content_bottom_y: contentBottomY
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Process pending scroll clears before rendering
        onPreDraw?()

        ZonvieCore.appLog("[draw] draw(in:) called")
        autoreleasepool {
            // === PERF LOG: draw開始 ===
            var t_draw_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_draw_start = CFAbsoluteTimeGetCurrent()
            }

            // Deferred pipeline initialization: build pipeline on first draw
            // This avoids XPC errors when multiple instances start simultaneously
            if pipelineNeedsBuilding {
                pipelineNeedsBuilding = false
                buildPipeline(view: view)
            }

            // Graceful degradation: if GPU initialization failed, skip rendering
            guard pipeline != nil, sampler != nil else {
                if let error = initializationError {
                    ZonvieCore.appLog("[draw] Skipping render due to initialization error: \(error)")
                }
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            if view.drawableSize.width <= 0 || view.drawableSize.height <= 0 {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }
    
            // Update atlas backing scale outside lock (atlas has its own internal lock)
            atlas.setBackingScale(backingScale)

            // === PERF LOG: lock取得開始 ===
            var t_lock_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_lock_start = CFAbsoluteTimeGetCurrent()
            }

            // --- fetch pending state under lock ---
            let (newMainCountOpt, newCursorCountOpt, fontChg, dirtyRectPxOpt, dirtyRows, rowMode, smoothScrolling, rowBuffersSnapshot, rowCountsSnapshot): (Int?, Int?, (name: String, size: CGFloat)?, CGRect?, [Int], Bool, Bool, [MTLBuffer?], [Int]) = {
                lock.lock()
                defer { lock.unlock() }

                let mainCount = pendingMainCount
                let cursorCount = pendingCursorCount
                pendingMainCount = nil
                pendingCursorCount = nil

                let font = pendingFont
                pendingFont = nil

                // Take dirty info for this frame
                let dirtyRect = pendingDirtyRectPx
                let rows = Array(pendingDirtyRows)
                pendingDirtyRectPx = nil
                pendingDirtyRows.removeAll()

                let rowModeVal = usingRowBuffers
                let smoothScrollingVal = hasActiveScrollOffset

                // Snapshot row buffers to avoid race condition with submitVerticesRowRaw
                let buffersSnap = rowVertexBuffers
                let countsSnap = rowVertexCounts

                return (mainCount, cursorCount, font, dirtyRect, rows, rowModeVal, smoothScrollingVal, buffersSnap, countsSnap)
            }()

            // === PERF LOG: lock取得終了 ===
            if ZonvieCore.appLogEnabled {
                let t_lock_end = CFAbsoluteTimeGetCurrent()
                let lock_us = (t_lock_end - t_lock_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_lock_fetch us=\(String(format: "%.1f", lock_us))")
            }

            // INSERT right after lock.unlock() in draw(in:)
            ZonvieCore.appLog("draw(fetch): rowMode=\(rowMode) newMainCountOpt=\(String(describing: newMainCountOpt)) newCursorCountOpt=\(String(describing: newCursorCountOpt)) dirtyRectPxOpt=\(String(describing: dirtyRectPxOpt)) dirtyRowsCount=\(dirtyRows.count) hasPresentedOnce=\(hasPresentedOnce) drawableSize=\(view.drawableSize)")

            if let fontChg {
                atlas.setFont(name: fontChg.name, pointSize: fontChg.size)
            }
    
            let cw = atlas.cellWidthPx
            let ch = atlas.cellHeightPx + Float(linespacePx)
            if cw != lastCellWidthPx || ch != lastCellHeightPx {
                lastCellWidthPx = cw
                lastCellHeightPx = ch
                if let cb = onCellMetricsChanged {
                    DispatchQueue.main.async { cb(cw, ch) }
                }
            }
    
            // reflect counts (nil means "no update" => keep previous)
            if let newMainCount = newMainCountOpt {
                currentMainCount = newMainCount
            }
            if let newCursorCount = newCursorCountOpt {
                currentCursorCount = newCursorCount
            }
    
            // If rowMode, we may not have a single "currentMainCount"; rows drive it.
            if !rowMode && currentMainCount <= 0 && currentCursorCount <= 0 {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Check if cursor blink state changed
            let blinkStateChanged = cursorBlinkState != lastRenderedBlinkState

            // If nothing changed, do not encode/present a new frame.
            // MTKView may call draw(in:) for reasons other than Neovim "flush" (e.g. window expose).
            if hasPresentedOnce,
               fontChg == nil,
               newMainCountOpt == nil,
               newCursorCountOpt == nil,
               dirtyRectPxOpt == nil,
               dirtyRows.isEmpty,
               !smoothScrolling,
               !blinkStateChanged {
                // Still reset redrawPending so future redraws are not blocked.
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // In rowMode with no vertex updates and no dirty rows, skip rendering
            if rowMode && dirtyRows.isEmpty && newMainCountOpt == nil && newCursorCountOpt == nil && !smoothScrolling && !blinkStateChanged && hasPresentedOnce {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Update last rendered blink state since we're proceeding with render
            lastRenderedBlinkState = cursorBlinkState

            // We always need a drawable to present.
            guard let drawable = view.currentDrawable else { return }

            // Ensure persistent back buffer matches current drawable size.
            ensureBackBuffer(drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat)
            guard let backTex = backBuffer else { return }

            // --- 1) Render into back buffer (partial redraw is valid here) ---
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = backTex
            rpd.colorAttachments[0].storeAction = .store

            // For partial redraw, preserve back buffer contents.
            // In rowMode, even if dirtyRect is nil, we may still redraw only dirty rows.
            // If we haven't rendered at least once after resize, we must clear once.
            //
            // When blur is enabled, always use .clear because:
            // - Semi-transparent backgrounds (alpha=0.7) blend with previous frame when using .load
            // - This causes ghosting and gradual opacity buildup, making blur invisible
            // - ExternalGridView uses the same approach (always .clear) and works correctly
            let hasAnyDirtyInRowMode = rowMode && !dirtyRows.isEmpty

            // DEBUG: Detailed loadAction decision logging
            ZonvieCore.appLog("[DEBUG-LOADACTION] blurEnabled=\(blurEnabled) hasPresentedOnce=\(hasPresentedOnce) rowMode=\(rowMode) dirtyRows=\(dirtyRows.count) hasAnyDirtyInRowMode=\(hasAnyDirtyInRowMode) mainCount=\(currentMainCount) cursorCount=\(currentCursorCount) backBufferSize=\(backBufferSize)")

            if !blurEnabled && hasPresentedOnce && (dirtyRectPxOpt != nil || hasAnyDirtyInRowMode) {
                rpd.colorAttachments[0].loadAction = .load
                ZonvieCore.appLog("[draw] loadAction=.load (blur=\(blurEnabled) hasPresentedOnce=\(hasPresentedOnce))")
            } else {
                rpd.colorAttachments[0].loadAction = .clear
                // Use transparent clear color when blur is enabled
                let clearAlpha: Double = blurEnabled ? 0.0 : 1.0
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clearAlpha)
                ZonvieCore.appLog("[draw] loadAction=.clear clearAlpha=\(clearAlpha) (blur=\(blurEnabled))")
            }
            
            // === PERF LOG: Metalエンコード開始 ===
            var t_encode_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_encode_start = CFAbsoluteTimeGetCurrent()
            }

            guard let cmd = queue.makeCommandBuffer() else { return }
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            // Safe to force unwrap: guard at top of draw() ensures pipeline/sampler are non-nil
            enc.setRenderPipelineState(pipeline!)

            // atlas texture + sampler
            if let tex = atlas.texture {
                enc.setFragmentTexture(tex, index: 0)
            }
            enc.setFragmentSamplerState(sampler!, index: 0)

            // Bind scroll offset buffers for smooth scrolling
            if let scrollBuf = scrollOffsetBuffer {
                enc.setVertexBuffer(scrollBuf, offset: 0, index: 1)
            }
            if let countBuf = scrollOffsetCountBuffer {
                enc.setVertexBuffer(countBuf, offset: 0, index: 2)
            }

            // Update and bind drawable size buffer for fragment shader clipping
            if let sizeBuf = drawableSizeBuffer {
                var size = DrawableSize(
                    width: Float(view.drawableSize.width),
                    height: Float(view.drawableSize.height)
                )
                memcpy(sizeBuf.contents(), &size, MemoryLayout<DrawableSize>.size)
                enc.setFragmentBuffer(sizeBuf, offset: 0, index: 0)
            }

            // Bind background alpha buffer for blur transparency
            if let alphaBuf = backgroundAlphaBuffer {
                enc.setFragmentBuffer(alphaBuf, offset: 0, index: 1)
            }

            // Bind cursor blink buffer (always visible=1 for main window, cursor uses separate buffer)
            if let blinkBuf = cursorBlinkBuffer {
                enc.setFragmentBuffer(blinkBuf, offset: 0, index: 2)
            }

            let drawableW = max(0, Int(view.drawableSize.width.rounded(.down)))
            let cellH = max(1, Int(cellHeightPx.rounded(.up)))

            // Use 2-pass rendering when blur is enabled and pipelines are available
            let use2Pass = blurEnabled && backgroundPipeline != nil && glyphPipeline != nil

            if rowMode {
                // Safe row count: use snapshots taken under lock to avoid race conditions
                let safeRowCount = min(rowBuffersSnapshot.count, rowCountsSnapshot.count)

                if use2Pass {
                    // 2-Pass rendering for blur: draw backgrounds first, then glyphs
                    // This prevents ghosting with semi-transparent backgrounds

                    // Pass 1: Background (overwrite blending)
                    enc.setRenderPipelineState(backgroundPipeline!)
                    for row in 0..<safeRowCount {
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                    }

                    // Pass 2: Glyphs (standard alpha blending)
                    enc.setRenderPipelineState(glyphPipeline!)
                    for row in 0..<safeRowCount {
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                    }
                } else if smoothScrolling {
                    // Smooth scroll without blur: draw all rows without scissor
                    for row in 0..<safeRowCount {
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                    }
                } else if !dirtyRows.isEmpty {
                    // Normal mode: scissor per dirty row (prevents giant scissor from accumulated unions).
                    for row in dirtyRows {
                        if row < 0 || row >= safeRowCount { continue }
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }

                        let y = max(0, row * cellH)
                        if drawableW > 0 && cellH > 0 {
                            enc.setScissorRect(MTLScissorRect(x: 0, y: y, width: drawableW, height: cellH))
                        }

                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                    }
                } else {
                    // Safety: if no dirtyRows (first frame), draw all rows without scissor.
                    for row in 0..<safeRowCount {
                        let vc = rowCountsSnapshot[row]
                        if vc <= 0 { continue }
                        guard let vb = rowBuffersSnapshot[row] else { continue }
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                    }
                }
            } else {
                // Non-rowMode
                if use2Pass {
                    // 2-Pass rendering for blur
                    // Pass 1: Background (overwrite blending)
                    enc.setRenderPipelineState(backgroundPipeline!)
                    if currentMainCount > 0, let vb = vertexBuffer {
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentMainCount)
                    }

                    // Pass 2: Glyphs (standard alpha blending)
                    enc.setRenderPipelineState(glyphPipeline!)
                    if currentMainCount > 0, let vb = vertexBuffer {
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentMainCount)
                    }
                } else {
                    // Optional single scissor by dirtyRectPxOpt.
                    if let dr = dirtyRectPxOpt {
                        let x = max(0, Int(dr.origin.x.rounded(.down)))
                        let y = max(0, Int(dr.origin.y.rounded(.down)))
                        let w = max(0, Int(dr.size.width.rounded(.up)))
                        let h = max(0, Int(dr.size.height.rounded(.up)))
                        if w > 0 && h > 0 {
                            enc.setScissorRect(MTLScissorRect(x: x, y: y, width: w, height: h))
                        }
                    }

                    if currentMainCount > 0, let vb = vertexBuffer {
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentMainCount)
                    }
                }
            }

            // Reset scissor before cursor pass.
            // In rowMode we scissor per row; leaving it as-is will clip the cursor.
            if rowMode && !use2Pass {
                let fullW = max(0, Int(view.drawableSize.width.rounded(.down)))
                let fullH = max(0, Int(view.drawableSize.height.rounded(.down)))
                if fullW > 0 && fullH > 0 {
                    enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: fullW, height: fullH))
                }
            }

            // --- cursor pass ---
            // Cursor uses the original pipeline (ps_main) because:
            // - Cursor vertices use uv.x < 0 marker (same as backgrounds)
            // - ps_glyph discards uv.x < 0, so cursor would be invisible
            // - ps_main handles both backgrounds and glyphs correctly
            if use2Pass {
                enc.setRenderPipelineState(pipeline!)
            }
            // Only draw cursor if blink state is visible
            ZonvieCore.appLog("[cursor-draw] cursorBlinkState=\(cursorBlinkState) cursorCount=\(currentCursorCount)")
            if cursorBlinkState, currentCursorCount > 0, let cvb = cursorVertexBuffer {
                enc.setVertexBuffer(cvb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentCursorCount)
            }

            enc.endEncoding()

            // === PERF LOG: Metalエンコード終了 ===
            if ZonvieCore.appLogEnabled {
                let t_encode_end = CFAbsoluteTimeGetCurrent()
                let encode_us = (t_encode_end - t_encode_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_encode rowMode=\(rowMode) us=\(String(format: "%.1f", encode_us))")
            }

            // === PERF LOG: Copy開始 ===
            var t_copy_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_copy_start = CFAbsoluteTimeGetCurrent()
            }

            // --- 2) Copy back buffer to drawable using render pass (replaces Blit) ---
            // IMPORTANT:
            // currentDrawable.texture can be a fresh texture each frame.
            // If we copy only the dirty region, the rest of the drawable is undefined -> flicker.
            // Therefore we must copy the full back buffer whenever we present.
            //
            // Using render pass instead of MTLBlitCommandEncoder because:
            // - Blit shaders cannot be cached in MTLBinaryArchive
            // - After fork(), XPC compiler service is unavailable
            // - Render pipelines can be cached and work without XPC
            if let copyPipe = copyPipeline, let copyVB = copyVertexBuffer {
                let copyRPD = MTLRenderPassDescriptor()
                copyRPD.colorAttachments[0].texture = drawable.texture
                copyRPD.colorAttachments[0].loadAction = .dontCare
                copyRPD.colorAttachments[0].storeAction = .store

                if let copyEnc = cmd.makeRenderCommandEncoder(descriptor: copyRPD) {
                    copyEnc.setRenderPipelineState(copyPipe)
                    copyEnc.setVertexBuffer(copyVB, offset: 0, index: 0)
                    copyEnc.setFragmentTexture(backTex, index: 0)
                    copyEnc.setFragmentSamplerState(sampler!, index: 0)
                    copyEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    copyEnc.endEncoding()
                }

                // === PERF LOG: Copy終了 ===
                if ZonvieCore.appLogEnabled {
                    let t_copy_end = CFAbsoluteTimeGetCurrent()
                    let copy_us = (t_copy_end - t_copy_start) * 1_000_000
                    ZonvieCore.appLog("[perf] draw_copy us=\(String(format: "%.1f", copy_us))")
                }
            }

            cmd.present(drawable)
            cmd.addCompletedHandler { [weak self, weak view] _ in
                guard let self = self else { return }
                let wasFirstPresent = !self.hasPresentedOnce
                self.hasPresentedOnce = true

                // DEBUG: Track hasPresentedOnce state change in completion handler
                ZonvieCore.appLog("[DEBUG-PRESENT] completedHandler: wasFirstPresent=\(wasFirstPresent) hasPresentedOnce=\(self.hasPresentedOnce)")

                // Force shadow recalculation on first present when blur is enabled
                // Transparent windows (isOpaque=false, backgroundColor=.clear) need this
                // to properly display shadows after the first frame is rendered
                if wasFirstPresent && ZonvieConfig.shared.blurEnabled {
                    // Delay shadow recalculation to ensure window is fully rendered
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        guard let window = view?.window else {
                            ZonvieCore.appLog("[Shadow] window is nil, skipping shadow recalculation")
                            return
                        }
                        ZonvieCore.appLog("[Shadow] Recalculating shadow for window \(window.windowNumber)")
                        window.display()
                        window.hasShadow = false
                        window.hasShadow = true
                        window.invalidateShadow()
                    }
                }
            }
            cmd.commit()

            // === PERF LOG: draw終了 ===
            if ZonvieCore.appLogEnabled {
                let t_draw_end = CFAbsoluteTimeGetCurrent()
                let draw_ms = (t_draw_end - t_draw_start) * 1000.0
                ZonvieCore.appLog("[perf] draw_total rowMode=\(rowMode) dirtyRows=\(dirtyRows.count) ms=\(String(format: "%.2f", draw_ms))")
            }

            (view as? MetalTerminalView)?.didDrawFrame()
        }
    }

    private func buildPipeline(view: MTKView) {
        guard let lib = device.makeDefaultLibrary() else {
            initializationError = "Failed to make default library"
            ZonvieCore.appLog("ERROR: \(initializationError!)")
            return
        }
        guard let vs = lib.makeFunction(name: "vs_main") else {
            initializationError = "Missing vs_main shader function"
            ZonvieCore.appLog("ERROR: \(initializationError!)")
            return
        }

        // IMPORTANT: Shaders.metal defines fragment function as "ps_main".
        guard let fs = lib.makeFunction(name: "ps_main") else {
            initializationError = "Missing ps_main shader function"
            ZonvieCore.appLog("ERROR: \(initializationError!)")
            return
        }

        // Copy shaders for backBuffer -> drawable copy (replaces Blit)
        guard let vsCopy = lib.makeFunction(name: "vs_copy") else {
            initializationError = "Missing vs_copy shader function"
            ZonvieCore.appLog("ERROR: \(initializationError!)")
            return
        }
        guard let fsCopy = lib.makeFunction(name: "ps_copy") else {
            initializationError = "Missing ps_copy shader function"
            ZonvieCore.appLog("ERROR: \(initializationError!)")
            return
        }

        guard let vertexDesc = Self.makeVertexDescriptor() else {
            initializationError = "Failed to create vertex descriptor"
            ZonvieCore.appLog("ERROR: \(initializationError!)")
            return
        }

        guard let copyVertexDesc = Self.makeCopyVertexDescriptor() else {
            initializationError = "Failed to create copy vertex descriptor"
            ZonvieCore.appLog("ERROR: \(initializationError!)")
            return
        }

        let pixelFormat = view.colorPixelFormat

        // Try to load from binary archive first (avoids XPC compiler service)
        if loadPipelineFromArchive(lib: lib, vs: vs, fs: fs, vsCopy: vsCopy, fsCopy: fsCopy, vertexDesc: vertexDesc, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat) {
            ZonvieCore.appLog("[Renderer] Pipeline loaded from binary archive")
            // Build 2-pass pipelines for blur support (also from archive)
            if blurEnabled {
                _ = build2PassPipelinesAndGetDescriptors(lib: lib, vs: vs, vertexDesc: vertexDesc, pixelFormat: pixelFormat)
            }
            // Build copy vertex buffer
            buildCopyVertexBuffer()
            return
        }

        // Binary archive miss - need to compile pipeline
        ZonvieCore.appLog("[Renderer] Binary archive miss, compiling pipeline...")

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.vertexDescriptor = vertexDesc
        desc.colorAttachments[0].pixelFormat = pixelFormat

        // Enable blending so glyph coverage (alpha) composites correctly over background.
        if let a = desc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        // Create main pipeline state (this requires XPC compiler service)
        do {
            ZonvieCore.appLog("[Renderer] Creating pipeline state via XPC compiler...")
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            ZonvieCore.appLog("[Renderer] Pipeline created successfully!")
        } catch {
            initializationError = "Failed to make pipeline state: \(error)"
            ZonvieCore.appLog("[Renderer] ERROR: \(initializationError!)")
            return
        }

        // Create copy pipeline (replaces Blit)
        let copyDesc = MTLRenderPipelineDescriptor()
        copyDesc.vertexFunction = vsCopy
        copyDesc.fragmentFunction = fsCopy
        copyDesc.vertexDescriptor = copyVertexDesc
        copyDesc.colorAttachments[0].pixelFormat = pixelFormat
        // No blending - just overwrite
        if let a = copyDesc.colorAttachments[0] {
            a.isBlendingEnabled = false
        }

        do {
            copyPipeline = try device.makeRenderPipelineState(descriptor: copyDesc)
            ZonvieCore.appLog("[Renderer] Copy pipeline created successfully!")
        } catch {
            ZonvieCore.appLog("[Renderer] ERROR: Failed to make copy pipeline: \(error)")
            // Non-fatal: we can still render, just might have issues
        }

        // Build copy vertex buffer (fullscreen quad)
        buildCopyVertexBuffer()

        // Build 2-pass pipelines for blur support
        var bgDesc: MTLRenderPipelineDescriptor? = nil
        var glyphDesc: MTLRenderPipelineDescriptor? = nil
        if blurEnabled {
            (bgDesc, glyphDesc) = build2PassPipelinesAndGetDescriptors(lib: lib, vs: vs, vertexDesc: vertexDesc, pixelFormat: pixelFormat)
        }

        // Cache all pipelines to binary archive for future use
        cacheToArchive(mainDesc: desc, bgDesc: bgDesc, glyphDesc: glyphDesc, copyDesc: copyDesc)
    }

    /// Build 2-pass pipelines and return their descriptors for caching
    private func build2PassPipelinesAndGetDescriptors(lib: MTLLibrary, vs: MTLFunction, vertexDesc: MTLVertexDescriptor, pixelFormat: MTLPixelFormat) -> (MTLRenderPipelineDescriptor?, MTLRenderPipelineDescriptor?) {
        guard let fsBg = lib.makeFunction(name: "ps_background") else {
            ZonvieCore.appLog("ERROR: Missing ps_background shader function")
            return (nil, nil)
        }
        guard let fsGlyph = lib.makeFunction(name: "ps_glyph") else {
            ZonvieCore.appLog("ERROR: Missing ps_glyph shader function")
            return (nil, nil)
        }

        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = vs
        bgDesc.fragmentFunction = fsBg
        bgDesc.vertexDescriptor = vertexDesc
        bgDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = bgDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .zero
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .zero
        }

        let glyphDesc = MTLRenderPipelineDescriptor()
        glyphDesc.vertexFunction = vs
        glyphDesc.fragmentFunction = fsGlyph
        glyphDesc.vertexDescriptor = vertexDesc
        glyphDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = glyphDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        do {
            backgroundPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
            glyphPipeline = try device.makeRenderPipelineState(descriptor: glyphDesc)
            ZonvieCore.appLog("[Renderer] 2-pass pipelines created for blur support")
            return (bgDesc, glyphDesc)
        } catch {
            ZonvieCore.appLog("[Renderer] ERROR: Failed to make 2-pass pipeline states: \(error)")
            return (nil, nil)
        }
    }

    /// Try to load pipeline from binary archive
    private func loadPipelineFromArchive(lib: MTLLibrary, vs: MTLFunction, fs: MTLFunction, vsCopy: MTLFunction, fsCopy: MTLFunction, vertexDesc: MTLVertexDescriptor, copyVertexDesc: MTLVertexDescriptor, pixelFormat: MTLPixelFormat) -> Bool {
        let archivePath = Self.binaryArchivePath
        ZonvieCore.appLog("[Renderer] loadPipelineFromArchive: checking \(archivePath.path)")

        // Check if archive exists
        guard FileManager.default.fileExists(atPath: archivePath.path) else {
            ZonvieCore.appLog("[Renderer] loadPipelineFromArchive: archive NOT FOUND")
            return false
        }
        ZonvieCore.appLog("[Renderer] loadPipelineFromArchive: archive EXISTS, loading...")

        // Load binary archive
        let archiveDesc = MTLBinaryArchiveDescriptor()
        archiveDesc.url = archivePath

        do {
            binaryArchive = try device.makeBinaryArchive(descriptor: archiveDesc)
            ZonvieCore.appLog("[Renderer] Loaded binary archive from \(archivePath.path)")
        } catch {
            ZonvieCore.appLog("[Renderer] Failed to load binary archive: \(error)")
            // Delete corrupted archive
            try? FileManager.default.removeItem(at: archivePath)
            return false
        }

        guard let archive = binaryArchive else { return false }

        // Create main pipeline descriptor
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.vertexDescriptor = vertexDesc
        desc.colorAttachments[0].pixelFormat = pixelFormat

        if let a = desc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        // Create copy pipeline descriptor
        let copyDesc = MTLRenderPipelineDescriptor()
        copyDesc.vertexFunction = vsCopy
        copyDesc.fragmentFunction = fsCopy
        copyDesc.vertexDescriptor = copyVertexDesc
        copyDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = copyDesc.colorAttachments[0] {
            a.isBlendingEnabled = false
        }

        // Try to create pipelines from archive
        desc.binaryArchives = [archive]
        copyDesc.binaryArchives = [archive]

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            copyPipeline = try device.makeRenderPipelineState(descriptor: copyDesc)
            ZonvieCore.appLog("[Renderer] All pipelines loaded from archive successfully")
            return true
        } catch {
            ZonvieCore.appLog("[Renderer] Failed to create pipeline from archive: \(error)")
            // Archive might be stale, delete it
            try? FileManager.default.removeItem(at: archivePath)
            binaryArchive = nil
            return false
        }
    }

    /// Cache successfully created pipelines to binary archive for future use
    /// This avoids XPC compiler service calls on subsequent launches
    private func cacheToArchive(mainDesc: MTLRenderPipelineDescriptor?, bgDesc: MTLRenderPipelineDescriptor?, glyphDesc: MTLRenderPipelineDescriptor?, copyDesc: MTLRenderPipelineDescriptor?) {
        let archivePath = Self.binaryArchivePath
        ZonvieCore.appLog("[Renderer] cacheToArchive: starting, path=\(archivePath.path)")

        // Create new empty archive
        let archiveDesc = MTLBinaryArchiveDescriptor()
        do {
            let archive = try device.makeBinaryArchive(descriptor: archiveDesc)
            ZonvieCore.appLog("[Renderer] cacheToArchive: created empty archive")

            // Add successfully compiled pipeline descriptors
            if let desc = mainDesc {
                try archive.addRenderPipelineFunctions(descriptor: desc)
                ZonvieCore.appLog("[Renderer] cacheToArchive: added main pipeline")
            }
            if let desc = bgDesc {
                try archive.addRenderPipelineFunctions(descriptor: desc)
                ZonvieCore.appLog("[Renderer] cacheToArchive: added background pipeline")
            }
            if let desc = glyphDesc {
                try archive.addRenderPipelineFunctions(descriptor: desc)
                ZonvieCore.appLog("[Renderer] cacheToArchive: added glyph pipeline")
            }
            if let desc = copyDesc {
                try archive.addRenderPipelineFunctions(descriptor: desc)
                ZonvieCore.appLog("[Renderer] cacheToArchive: added copy pipeline")
            }

            // Serialize to disk
            try archive.serialize(to: archivePath)
            ZonvieCore.appLog("[Renderer] cacheToArchive: SUCCESS - saved to \(archivePath.path)")
        } catch {
            ZonvieCore.appLog("[Renderer] cacheToArchive: FAILED - \(error)")
        }
    }

    private static func makeVertexDescriptor() -> MTLVertexDescriptor? {
        let vd = MTLVertexDescriptor()
        let stride = MemoryLayout<Vertex>.stride

        guard
            let offPos = MemoryLayout<Vertex>.offset(of: \.position),
            let offUV  = MemoryLayout<Vertex>.offset(of: \.texCoord),
            let offCol = MemoryLayout<Vertex>.offset(of: \.color),
            let offGridId = MemoryLayout<Vertex>.offset(of: \.grid_id),
            let offDecoFlags = MemoryLayout<Vertex>.offset(of: \.deco_flags),
            let offDecoPhase = MemoryLayout<Vertex>.offset(of: \.deco_phase)
        else {
            ZonvieCore.appLog("[Renderer] Vertex layout mismatch. Expected fields: position/texCoord/color/grid_id/deco_flags/deco_phase")
            return nil
        }

        vd.attributes[0].format = .float2
        vd.attributes[0].offset = offPos
        vd.attributes[0].bufferIndex = 0

        vd.attributes[1].format = .float2
        vd.attributes[1].offset = offUV
        vd.attributes[1].bufferIndex = 0

        vd.attributes[2].format = .float4
        vd.attributes[2].offset = offCol
        vd.attributes[2].bufferIndex = 0

        // grid_id: Int64 in struct, but shader uses lower 32 bits -> use .int
        vd.attributes[3].format = .int
        vd.attributes[3].offset = offGridId
        vd.attributes[3].bufferIndex = 0

        // deco_flags: UInt32 -> .uint
        vd.attributes[4].format = .uint
        vd.attributes[4].offset = offDecoFlags
        vd.attributes[4].bufferIndex = 0

        // deco_phase: Float -> .float
        vd.attributes[5].format = .float
        vd.attributes[5].offset = offDecoPhase
        vd.attributes[5].bufferIndex = 0

        vd.layouts[0].stride = stride
        vd.layouts[0].stepFunction = .perVertex
        vd.layouts[0].stepRate = 1

        return vd
    }

    /// Vertex descriptor for copy pipeline (simple position + texcoord)
    private static func makeCopyVertexDescriptor() -> MTLVertexDescriptor? {
        let vd = MTLVertexDescriptor()
        // CopyVertex: float2 position + float2 texCoord = 16 bytes
        let stride = MemoryLayout<SIMD2<Float>>.stride * 2  // 16 bytes

        // position: float2 at offset 0
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0

        // texCoord: float2 at offset 8
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vd.attributes[1].bufferIndex = 0

        vd.layouts[0].stride = stride
        vd.layouts[0].stepFunction = .perVertex
        vd.layouts[0].stepRate = 1

        return vd
    }

    private func buildSampler() {
        let s = MTLSamplerDescriptor()
        s.minFilter = .nearest
        s.magFilter = .nearest
        s.mipFilter = .notMipmapped
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)
    }

    /// Build vertex buffer for fullscreen quad copy (replaces Blit)
    /// Quad covers NDC space (-1,-1) to (1,1) with UV (0,0) to (1,1)
    private func buildCopyVertexBuffer() {
        // Fullscreen quad: 2 triangles, 6 vertices
        // Each vertex: position (float2) + texCoord (float2) = 16 bytes
        // Note: UV.y is flipped (1-v) because Metal texture origin is top-left
        var vertices: [Float] = [
            // Triangle 1
            -1.0, -1.0,  0.0, 1.0,  // bottom-left
             1.0, -1.0,  1.0, 1.0,  // bottom-right
             1.0,  1.0,  1.0, 0.0,  // top-right
            // Triangle 2
            -1.0, -1.0,  0.0, 1.0,  // bottom-left
             1.0,  1.0,  1.0, 0.0,  // top-right
            -1.0,  1.0,  0.0, 0.0,  // top-left
        ]
        let size = vertices.count * MemoryLayout<Float>.stride
        copyVertexBuffer = device.makeBuffer(bytes: &vertices, length: size, options: .storageModeShared)
    }

    /// Compute byte size safely (no overflow). Returns nil if the request is unrealistic/overflowing.
    private func safeNeededBytes(vertexCount: Int) -> Int? {
        if vertexCount <= 0 { return 0 }
    
        let stride = MemoryLayout<Vertex>.stride
        // Prevent overflow: vertexCount * stride must fit in Int.
        // Use Int64 for intermediate math.
        let vc64 = Int64(vertexCount)
        let stride64 = Int64(stride)
    
        // If it doesn't fit, reject.
        if vc64 > 0 && stride64 > 0 {
            let (prod, overflow) = vc64.multipliedReportingOverflow(by: stride64)
            if overflow { return nil }
            if prod > Int64(Int.max) { return nil }
            return Int(prod)
        }
    
        return nil
    }
    
    /// Maximum vertex buffer capacity (64 MB) to prevent memory exhaustion.
    /// This is sufficient for extremely large terminals (e.g., 1000x1000 cells with complex rendering).
    private static let maxVertexBufferCapacity: Int = 64 * 1024 * 1024

    /// Grow capacity without arithmetic overflow.
    /// - Doubles when possible, but clamps to maxVertexBufferCapacity to prevent memory exhaustion.
    /// - If the requested size exceeds the maximum, returns nil to trigger graceful fallback.
    private func growCapacity(current: Int, needed: Int) -> Int? {
        if needed < 0 { return nil }
        if needed <= current { return current }

        // Reject requests that exceed maximum capacity
        if needed > Self.maxVertexBufferCapacity { return nil }

        // Guard: avoid overflow in doubling.
        let doubled: Int
        if current <= 0 {
            doubled = 0
        } else if current > (Int.max / 2) {
            doubled = Self.maxVertexBufferCapacity
        } else {
            doubled = current * 2
        }

        // Choose the larger of needed and doubled, clamped to maximum
        let next = min(max(needed, doubled), Self.maxVertexBufferCapacity)

        // A last sanity check: Metal buffer length must be > 0 to allocate meaningfully.
        if next <= 0 { return nil }
        return next
    }
    
    private func ensureVertexBufferCapacity(_ vertexCount: Int) {
        let vc = max(0, vertexCount)
    
        guard let needed = safeNeededBytes(vertexCount: vc) else {
            // Drop this update defensively (untrusted vertexCount from C-ABI).
            pendingMainCount = 0
            return
        }
    
        if vertexBuffer == nil || needed > vertexBufferCapacity {
            guard let nextCap = growCapacity(current: vertexBufferCapacity, needed: max(1, needed)) else {
                pendingMainCount = 0
                return
            }
            vertexBufferCapacity = nextCap
            vertexBuffer = device.makeBuffer(length: vertexBufferCapacity, options: .storageModeShared)
            // If allocation failed, avoid keeping a huge capacity that will overflow again.
            if vertexBuffer == nil {
                vertexBufferCapacity = 0
                pendingMainCount = 0
            }
        }
    }
    
    private func ensureCursorVertexBufferCapacity(_ vertexCount: Int) {
        let vc = max(0, vertexCount)
    
        guard let needed = safeNeededBytes(vertexCount: vc) else {
            // Drop this update defensively (untrusted vertexCount from C-ABI).
            pendingCursorCount = 0
            return
        }
    
        if cursorVertexBuffer == nil || needed > cursorVertexBufferCapacity {
            guard let nextCap = growCapacity(current: cursorVertexBufferCapacity, needed: max(1, needed)) else {
                pendingCursorCount = 0
                return
            }
            cursorVertexBufferCapacity = nextCap
            cursorVertexBuffer = device.makeBuffer(length: cursorVertexBufferCapacity, options: .storageModeShared)
            if cursorVertexBuffer == nil {
                cursorVertexBufferCapacity = 0
                pendingCursorCount = 0
            }
        }
    }

    private func ensureRowStorage(_ row: Int) {
        if row < 0 { return }
        // Enforce maximum row limit to prevent unbounded memory growth
        if row >= maxRowBuffers {
            ZonvieCore.appLog("[Renderer] Row \(row) exceeds maxRowBuffers (\(maxRowBuffers))")
            return
        }
        if row < rowVertexBuffers.count { return }
        let newCount = row + 1
        rowVertexBuffers.append(contentsOf: Array(repeating: nil, count: newCount - rowVertexBuffers.count))
        rowVertexBufferCaps.append(contentsOf: Array(repeating: 0, count: newCount - rowVertexBufferCaps.count))
        rowVertexCounts.append(contentsOf: Array(repeating: 0, count: newCount - rowVertexCounts.count))
    }

    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int = 0) {
        // === PERF LOG: submitVerticesRowRaw開始 ===
        var t_start: CFAbsoluteTime = 0
        if ZonvieCore.appLogEnabled {
            t_start = CFAbsoluteTimeGetCurrent()
        }
        defer {
            if ZonvieCore.appLogEnabled {
                let t_end = CFAbsoluteTimeGetCurrent()
                let us = (t_end - t_start) * 1_000_000
                ZonvieCore.appLog("[perf] submitVerticesRowRaw row=\(rowStart) count=\(count) us=\(String(format: "%.1f", us))")
            }
        }

        lock.lock()
        defer { lock.unlock() }

        // Switch to row-buffer mode.
        usingRowBuffers = true

        // Handle grid resize: if totalRows is smaller than current row storage,
        // shrink arrays to free memory (when significantly oversized).
        if totalRows > 0 && totalRows < rowVertexBuffers.count {
            // Shrink if arrays are more than 2x the needed size
            if rowVertexBuffers.count > totalRows * 2 {
                rowVertexBuffers.removeSubrange(totalRows...)
                rowVertexBufferCaps.removeSubrange(totalRows...)
                rowVertexCounts.removeSubrange(totalRows...)
            } else {
                // Just clear counts for excess rows
                for r in totalRows..<rowVertexBuffers.count {
                    rowVertexCounts[r] = 0
                }
            }
        }

        // We currently assume Zig calls with rowCount == 1 (contract in Zig onFlush).
        guard rowCount > 0 else { return }
        let row = rowStart

        // Skip rows beyond the limit
        guard row >= 0 && row < maxRowBuffers else { return }

        ensureRowStorage(row)

        // Ensure storage was actually allocated
        guard row < rowVertexBuffers.count else { return }

        guard count > 0, let validPtr = ptr else {
            rowVertexCounts[row] = 0
            return
        }
    
        // bytes needed
        guard let neededBytes = safeNeededBytes(vertexCount: count) else {
            rowVertexCounts[row] = 0
            return
        }
    
        if rowVertexBuffers[row] == nil || neededBytes > rowVertexBufferCaps[row] {
            guard let nextCap = growCapacity(current: rowVertexBufferCaps[row], needed: max(1, neededBytes)) else {
                rowVertexCounts[row] = 0
                return
            }
            rowVertexBufferCaps[row] = nextCap
            rowVertexBuffers[row] = device.makeBuffer(length: nextCap, options: .storageModeShared)
            if rowVertexBuffers[row] == nil {
                rowVertexBufferCaps[row] = 0
                rowVertexCounts[row] = 0
                return
            }
        }
    
        // Copy vertices
        if let vb = rowVertexBuffers[row] {
            memcpy(vb.contents(), validPtr, count * MemoryLayout<Vertex>.stride)
            rowVertexCounts[row] = count
        } else {
            rowVertexCounts[row] = 0
        }
    }

    // --- Dirty marking ---
    // Row updates (on_vertices_row) should NOT expand a global dirtyRect,
    // because we can scissor per-row in draw().
    func markDirtyRows(rowStart: Int, rowCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        if rowCount > 0 {
            let end = max(rowStart, rowStart + rowCount)
            pendingDirtyRows.insert(integersIn: rowStart..<end)
        }
    }

    // Rect-based dirty (cursor union, partial updates) can keep a dirty rect.
    // We also record rows so rowMode can redraw only those rows.
    func markDirtyRect(rowStart: Int, rowCount: Int, rectPx: NSRect) {
        lock.lock()
        defer { lock.unlock() }

        if let cur = pendingDirtyRectPx {
            pendingDirtyRectPx = cur.union(rectPx)
        } else {
            pendingDirtyRectPx = rectPx
        }

        if rowCount > 0 {
            let end = max(rowStart, rowStart + rowCount)
            pendingDirtyRows.insert(integersIn: rowStart..<end)
        }
    }

    /// Mark all rows as dirty (for full redraw, e.g., during smooth scrolling)
    func markAllRowsDirty() {
        lock.lock()
        defer { lock.unlock() }

        let rowCount = rowVertexBuffers.count
        if rowCount > 0 {
            pendingDirtyRows.insert(integersIn: 0..<rowCount)
        }
        // Also clear the rect so full redraw happens
        pendingDirtyRectPx = nil
    }

}
