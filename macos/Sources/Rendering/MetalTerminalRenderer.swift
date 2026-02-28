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

    // MARK: - Triple Buffering

    /// Independent buffer set owning all vertex data for one frame.
    /// Three sets exist: at most 2 are GPU in-flight, and 1 is available for writing.
    /// Class (reference type) to avoid Swift Array copy-on-write races when
    /// different threads access different buffer sets concurrently.
    private class BufferSet {
        // Row-based vertex buffers (row-mode)
        var rowVertexBuffers: [MTLBuffer?] = []
        var rowVertexBufferCaps: [Int] = []     // bytes capacity per row buffer
        var rowVertexCounts: [Int] = []         // vertex count per row

        // Main / cursor vertex buffers (non-row-mode and partial updates)
        var mainVertexBuffer: MTLBuffer?
        var mainVertexBufferCap: Int = 0
        var mainVertexCount: Int = 0
        var cursorVertexBuffer: MTLBuffer?
        var cursorVertexBufferCap: Int = 0
        var cursorVertexCount: Int = 0

        var usingRowBuffers: Bool = false
        var knownTotalRows: Int = 0   // Actual grid row count from core
    }

    private let bufferSets: [BufferSet] = [BufferSet(), BufferSet(), BufferSet()]
    private var writeSetIndex: Int = 0       // Core thread only
    private var committedSetIndex: Int = 0   // Protected by lock
    private var isInFlush: Bool = false       // Core thread only
    private let inflightSemaphore = DispatchSemaphore(value: 1)  // Max 1 GPU in-flight
    private var commitRevision: UInt64 = 0   // Protected by lock
    private var lastDrawnRevision: UInt64 = 0 // Render thread only
    private var lastDrawnDrawableSize: CGSize = .zero // Render thread only
    private var gpuInFlightCount: [Int] = [0, 0, 0]  // Protected by lock
    private var defaultBgRGB: UInt32 = 0               // Protected by lock

    // Drawable size from the most recent committed flush.
    // Set by commitFlush() (core thread, grid_mu held) by reading the core's
    // layout directly — this guarantees the values match the NDC coordinates
    // baked into the committed vertices.
    // draw() uses these to set the Metal viewport, preventing stretching when
    // drawableSize changes between flushes.
    private var committedDrawableW: UInt32 = 0 // Protected by lock
    private var committedDrawableH: UInt32 = 0 // Protected by lock

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
        backingScale = s
        lock.unlock()
        // Eagerly update atlas so that cellWidthPx/cellHeightPx reflect the
        // new scale immediately (before the next draw() call). This ensures
        // maybeResizeCoreGrid() sends correct cell metrics to the core and
        // prevents the initial grid being sized with @1x metrics while the
        // drawable uses @2x pixel dimensions.
        atlas.setBackingScale(s)
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

    // (vertexBuffer/cursorVertexBuffer moved into BufferSet for triple buffering)

    /// Cursor blink state (true = visible, false = hidden during blink)
    var cursorBlinkState: Bool = true
    /// Last rendered blink state to detect changes
    private var lastRenderedBlinkState: Bool = true

    // --- Scroll offset for smooth scrolling ---
    // Stored as value-type array under lock; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race during smooth scrolling.
    private var scrollOffsetData: [ScrollOffset] = []
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

    // (rowVertexBuffers/rowVertexCounts/usingRowBuffers moved into BufferSet for triple buffering)

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

    // (buildScrollOffsetBuffers removed: scroll data now passed via setVertexBytes)

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

    // MARK: - Triple Buffer Flush Bracket

    /// Called from on_flush_begin callback (core thread).
    /// Deep-copies committed data into write set so partial updates overwrite cleanly.
    /// Picks a buffer set that is not committed and not GPU in-flight.
    func beginFlush() {
        isInFlush = true

        // Under lock: read committed index + gpuInFlight to pick a safe write set
        let srcIdx: Int
        lock.lock()
        srcIdx = committedSetIndex
        // Find a set that is not committed and not GPU in-flight
        var picked = -1
        for i in 0..<3 {
            if i != srcIdx && gpuInFlightCount[i] == 0 {
                picked = i
                break
            }
        }
        if picked == -1 {
            // All non-committed sets are GPU in-flight (should be unreachable
            // with semaphore=1 + sem.wait() before gpuInFlightCount++).
            // Drop this flush entirely to avoid GPU/CPU race on shared buffers.
            let inf = gpuInFlightCount
            lock.unlock()
            isInFlush = false
            ZonvieCore.appLog("[WARNING] beginFlush: no free buffer set, dropping flush committed=\(srcIdx) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return
        }
        writeSetIndex = picked
        if ZonvieCore.appLogEnabled {
            let inf = gpuInFlightCount
            ZonvieCore.appLog("[scroll_debug] beginFlush committed=\(srcIdx) write=\(picked) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
        }
        lock.unlock()

        let src = bufferSets[srcIdx]
        let dst = bufferSets[picked]

        // Deep copy row buffer contents: committed → write set
        dst.knownTotalRows = src.knownTotalRows
        let srcRowCount = src.rowVertexBuffers.count
        // Ensure dst arrays are large enough
        if dst.rowVertexBuffers.count < srcRowCount {
            let grow = srcRowCount - dst.rowVertexBuffers.count
            dst.rowVertexBuffers.append(contentsOf: Array(repeating: nil, count: grow))
            dst.rowVertexBufferCaps.append(contentsOf: Array(repeating: 0, count: grow))
            dst.rowVertexCounts.append(contentsOf: Array(repeating: 0, count: grow))
        }

        for i in 0..<srcRowCount {
            let srcCount = src.rowVertexCounts[i]
            guard srcCount > 0, let srcBuf = src.rowVertexBuffers[i] else {
                dst.rowVertexCounts[i] = 0
                continue
            }
            let neededBytes = srcCount * MemoryLayout<Vertex>.stride
            // Grow dst buffer if needed (lazy, never shrinks)
            if dst.rowVertexBuffers[i] == nil || dst.rowVertexBufferCaps[i] < neededBytes {
                let cap = max(neededBytes, dst.rowVertexBufferCaps[i] * 2, 4096)
                dst.rowVertexBuffers[i] = device.makeBuffer(length: cap, options: .storageModeShared)
                dst.rowVertexBufferCaps[i] = cap
            }
            if let dstBuf = dst.rowVertexBuffers[i] {
                memcpy(dstBuf.contents(), srcBuf.contents(), neededBytes)
                dst.rowVertexCounts[i] = srcCount
            }
        }

        // Zero out stale rows beyond src count (prevents drawing old data after grid shrink)
        let dstRowCount = dst.rowVertexBuffers.count
        if dstRowCount > srcRowCount {
            for i in srcRowCount..<dstRowCount {
                dst.rowVertexCounts[i] = 0
            }
        }

        // Deep copy main buffer
        if let srcMain = src.mainVertexBuffer, src.mainVertexCount > 0 {
            let bytes = src.mainVertexCount * MemoryLayout<Vertex>.stride
            if dst.mainVertexBuffer == nil || dst.mainVertexBufferCap < bytes {
                let cap = max(bytes, dst.mainVertexBufferCap * 2, 4096)
                dst.mainVertexBuffer = device.makeBuffer(length: cap, options: .storageModeShared)
                dst.mainVertexBufferCap = cap
            }
            if let dstBuf = dst.mainVertexBuffer {
                memcpy(dstBuf.contents(), srcMain.contents(), bytes)
            }
            dst.mainVertexCount = src.mainVertexCount
        } else {
            dst.mainVertexCount = src.mainVertexCount
        }

        // Deep copy cursor buffer
        if let srcCursor = src.cursorVertexBuffer, src.cursorVertexCount > 0 {
            let bytes = src.cursorVertexCount * MemoryLayout<Vertex>.stride
            if dst.cursorVertexBuffer == nil || dst.cursorVertexBufferCap < bytes {
                let cap = max(bytes, dst.cursorVertexBufferCap * 2, 4096)
                dst.cursorVertexBuffer = device.makeBuffer(length: cap, options: .storageModeShared)
                dst.cursorVertexBufferCap = cap
            }
            if let dstBuf = dst.cursorVertexBuffer {
                memcpy(dstBuf.contents(), srcCursor.contents(), bytes)
            }
            dst.cursorVertexCount = src.cursorVertexCount
        } else {
            dst.cursorVertexCount = src.cursorVertexCount
        }

        dst.usingRowBuffers = src.usingRowBuffers
    }

    /// Called from on_flush_end callback (core thread, grid_mu held).
    /// Atomically makes the write set the new committed set for draw().
    /// drawableW/drawableH are the core's layout at flush time, read via
    /// zonvie_core_get_layout while grid_mu is still held — this guarantees
    /// the values match the NDC coordinates in the committed vertices.
    func commitFlush(drawableW: UInt32, drawableH: UInt32) {
        guard isInFlush else { return }  // Flush was dropped by beginFlush
        let ws = writeSetIndex
        lock.lock()
        committedSetIndex = writeSetIndex
        committedDrawableW = drawableW
        committedDrawableH = drawableH
        commitRevision &+= 1
        let rev = commitRevision
        lock.unlock()
        isInFlush = false
        if ZonvieCore.appLogEnabled {
            let rowCount = bufferSets[ws].rowVertexBuffers.count
            var totalVerts = 0
            for i in 0..<rowCount {
                totalVerts += bufferSets[ws].rowVertexCounts[i]
            }
            ZonvieCore.appLog("[scroll_debug] commitFlush set=\(ws) rows=\(rowCount) totalVerts=\(totalVerts) rev=\(rev)")
        }
    }

    /// Update the default Neovim background color (for clear color in viewport edges).
    /// Called from core thread during flush.
    func updateDefaultBgColor(_ rgb: UInt32) {
        lock.lock()
        defaultBgRGB = rgb
        lock.unlock()
    }

    func submitVerticesRaw(
        mainPtr: UnsafeRawPointer?, mainCount: Int,
        cursorPtr: UnsafeRawPointer?, cursorCount: Int
    ) {
        guard isInFlush else {
            ZonvieCore.appLog("[WARNING] submitVerticesRaw called outside flush bracket")
            return
        }
        // Write to write set (called during flush, no lock needed for vertex data)
        let s = writeSetIndex

        bufferSets[s].usingRowBuffers = false

        // Clear dirty tracking under lock
        lock.lock()
        pendingDirtyRows.removeAll()
        pendingDirtyRectPx = nil
        lock.unlock()

        // main (always updated)
        if mainCount > 0, let mainPtr {
            ensureMainBufferInSet(s, vertexCount: mainCount)
            if let vb = bufferSets[s].mainVertexBuffer {
                memcpy(vb.contents(), mainPtr, mainCount * MemoryLayout<Vertex>.stride)
                bufferSets[s].mainVertexCount = mainCount
            } else {
                bufferSets[s].mainVertexCount = 0
            }
        } else {
            bufferSets[s].mainVertexCount = 0
        }

        // cursor (always updated)
        if cursorCount > 0, let cursorPtr {
            ensureCursorBufferInSet(s, vertexCount: cursorCount)
            if let cvb = bufferSets[s].cursorVertexBuffer {
                memcpy(cvb.contents(), cursorPtr, cursorCount * MemoryLayout<Vertex>.stride)
                bufferSets[s].cursorVertexCount = cursorCount
            } else {
                bufferSets[s].cursorVertexCount = 0
            }
        } else {
            bufferSets[s].cursorVertexCount = 0
        }
    }

    func submitVerticesPartialRaw(
        mainPtr: UnsafeRawPointer?, mainCount: Int,
        cursorPtr: UnsafeRawPointer?, cursorCount: Int,
        updateMain: Bool,
        updateCursor: Bool
    ) {
        guard isInFlush else {
            ZonvieCore.appLog("[WARNING] submitVerticesPartialRaw called outside flush bracket")
            return
        }
        // Write to write set (called during flush, no lock needed for vertex data)
        let s = writeSetIndex

        if updateMain {
            if mainCount > 0, let mainPtr {
                ensureMainBufferInSet(s, vertexCount: mainCount)
                if let vb = bufferSets[s].mainVertexBuffer {
                    memcpy(vb.contents(), mainPtr, mainCount * MemoryLayout<Vertex>.stride)
                    bufferSets[s].mainVertexCount = mainCount
                } else {
                    bufferSets[s].mainVertexCount = 0
                }
            } else {
                bufferSets[s].mainVertexCount = 0
            }
        }

        if updateCursor {
            if cursorCount > 0, let cursorPtr {
                ensureCursorBufferInSet(s, vertexCount: cursorCount)
                if let cvb = bufferSets[s].cursorVertexBuffer {
                    memcpy(cvb.contents(), cursorPtr, cursorCount * MemoryLayout<Vertex>.stride)
                    bufferSets[s].cursorVertexCount = cursorCount
                } else {
                    bufferSets[s].cursorVertexCount = 0
                }
            } else {
                bufferSets[s].cursorVertexCount = 0
            }
        }
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
            // Content bounds for fragment shader clipping (exact boundaries).
            // Scroll decision is now flag-based (DECO_SCROLLABLE in vertex data),
            // so these bounds only control fragment-level clipping of scrolled content
            // that ends up in margin areas.
            let contentTopY = info.gridTopYNDC - Float(info.marginTop) * cellHeightNDC
            let contentBottomY = info.gridTopYNDC - Float(info.gridRows - info.marginBottom) * cellHeightNDC

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

        // Store as value-type array; draw() will snapshot and pass via setVertexBytes.
        // This eliminates the GPU/CPU race on shared MTLBuffers.
        scrollOffsetData = scrollOffsets
        hasActiveScrollOffset = count > 0
    }

    /// Clear scroll offsets (reset to no offset)
    func clearScrollOffsets() {
        lock.lock()
        defer { lock.unlock() }

        scrollOffsetData = []
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

        // Content bounds for fragment shader clipping (exact boundaries).
        let contentTopY = info.gridTopYNDC - Float(info.marginTop) * cellHeightNDC
        let contentBottomY = info.gridTopYNDC - Float(info.gridRows - info.marginBottom) * cellHeightNDC

        return ScrollOffset(
            grid_id: Int32(truncatingIfNeeded: info.gridId),
            offset_y: ndc,
            content_top_y: contentTopY,
            content_bottom_y: contentBottomY
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Skip all rendering for minimized windows.
        // Metal's currentDrawable blocks/crashes when the window is in the
        // Dock, and onPreDraw accesses the Zig core (unnecessary CPU work).
        if let window = view.window, window.isMiniaturized {
            (view as? MetalTerminalView)?.didDrawFrame()
            return
        }

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

            // Acquire GPU slot BEFORE marking gpuInFlightCount.
            // This prevents sem.wait()-blocked draw() from inflating gpuInFlightCount,
            // which would cause beginFlush() to incorrectly see all sets as "in-flight".
            var t_sem_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_sem_start = CFAbsoluteTimeGetCurrent()
            }
            inflightSemaphore.wait()
            if ZonvieCore.appLogEnabled {
                let sem_us = (CFAbsoluteTimeGetCurrent() - t_sem_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_semaphore_wait us=\(String(format: "%.1f", sem_us))")
            }

            // === PERF LOG: lock取得開始 ===
            var t_lock_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_lock_start = CFAbsoluteTimeGetCurrent()
            }

            // --- Single lock: read committed index + pending state + mark GPU in-flight ---
            // This prevents beginFlush() from picking our committed set as its write target.
            let csi: Int
            let currentCommitRevision: UInt64
            let fontChg: (name: String, size: CGFloat)?
            let dirtyRectPxOpt: CGRect?
            let dirtyRows: [Int]
            let smoothScrolling: Bool
            let scrollSnapshot: [ScrollOffset]  // Snapshot for setVertexBytes (no GPU/CPU race)

            let snappedBgRGB: UInt32
            let snappedCommittedDrawableW: UInt32
            let snappedCommittedDrawableH: UInt32

            lock.lock()
            csi = committedSetIndex
            currentCommitRevision = commitRevision
            gpuInFlightCount[csi] += 1  // Prevent beginFlush from using this set

            fontChg = pendingFont
            pendingFont = nil
            dirtyRectPxOpt = pendingDirtyRectPx
            dirtyRows = Array(pendingDirtyRows)
            pendingDirtyRectPx = nil
            pendingDirtyRows.removeAll()
            smoothScrolling = hasActiveScrollOffset
            scrollSnapshot = scrollOffsetData  // Value-type copy (safe across frames)
            snappedBgRGB = defaultBgRGB
            snappedCommittedDrawableW = committedDrawableW
            snappedCommittedDrawableH = committedDrawableH
            lock.unlock()

            // Safety defer: decrement gpuInFlight + signal semaphore on early return.
            // On normal GPU submission, the completion handler handles cleanup instead.
            var gpuSubmitted = false
            defer {
                if !gpuSubmitted {
                    inflightSemaphore.signal()
                    lock.lock()
                    gpuInFlightCount[csi] -= 1
                    lock.unlock()
                }
            }

            // Now safe to read from committed set (protected by gpuInFlight)
            let committed = bufferSets[csi]
            let rowBuffersSnapshot = committed.rowVertexBuffers
            let rowCountsSnapshot = committed.rowVertexCounts
            let rowMode = committed.usingRowBuffers
            let committedMainCount = committed.mainVertexCount
            let committedCursorCount = committed.cursorVertexCount

            // All values below (csi, currentCommitRevision, scrollSnapshot, dirtyRows)
            // are local snapshots taken under lock above, so they form a consistent set.
            // committed.* fields are safe because gpuInFlightCount protects the buffer set.
            if smoothScrolling && ZonvieCore.appLogEnabled {
                let scrollDesc = scrollSnapshot.map { "g\($0.grid_id):ndc=\(String(format: "%.4f", $0.offset_y))" }.joined(separator: ",")
                ZonvieCore.appLog("[scroll_debug] draw set=\(csi) rev=\(currentCommitRevision) rowMode=\(rowMode) dirtyRows=\(dirtyRows.count) scroll=[\(scrollDesc)]")
            }

            // === PERF LOG: lock取得終了 ===
            if ZonvieCore.appLogEnabled {
                let t_lock_end = CFAbsoluteTimeGetCurrent()
                let lock_us = (t_lock_end - t_lock_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_lock_fetch us=\(String(format: "%.1f", lock_us))")
            }

            ZonvieCore.appLog("draw(fetch): rowMode=\(rowMode) mainCount=\(committedMainCount) cursorCount=\(committedCursorCount) dirtyRectPxOpt=\(String(describing: dirtyRectPxOpt)) dirtyRowsCount=\(dirtyRows.count) hasPresentedOnce=\(hasPresentedOnce) drawableSize=\(view.drawableSize)")

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

            // With triple buffering, counts come directly from committed set
            let currentMainCount = committedMainCount
            let currentCursorCount = committedCursorCount

            // If rowMode, we may not have a single "currentMainCount"; rows drive it.
            if !rowMode && currentMainCount <= 0 && currentCursorCount <= 0 {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Check if cursor blink state changed
            let blinkStateChanged = cursorBlinkState != lastRenderedBlinkState

            // Check if committed data changed since last draw
            let hasNewCommit = currentCommitRevision != lastDrawnRevision

            // Check if drawable size changed since last render (window resize).
            // Must re-render with current viewport even if vertices haven't changed,
            // otherwise macOS stretches the old frame to the new window size.
            let drawableSizeChanged = view.drawableSize != lastDrawnDrawableSize

            // If nothing changed, do not encode/present a new frame.
            // MTKView may call draw(in:) for reasons other than Neovim "flush" (e.g. window expose).
            if hasPresentedOnce,
               fontChg == nil,
               !hasNewCommit,
               dirtyRectPxOpt == nil,
               dirtyRows.isEmpty,
               !smoothScrolling,
               !blinkStateChanged,
               !drawableSizeChanged {
                // Still reset redrawPending so future redraws are not blocked.
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // In rowMode with no vertex updates and no dirty rows, skip rendering
            if rowMode && dirtyRows.isEmpty && !hasNewCommit && !smoothScrolling && !blinkStateChanged && !drawableSizeChanged && hasPresentedOnce {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Track that we've consumed this revision and drawable size
            lastDrawnRevision = currentCommitRevision
            lastDrawnDrawableSize = view.drawableSize

            // Update last rendered blink state since we're proceeding with render
            lastRenderedBlinkState = cursorBlinkState

            // We always need a drawable to present.
            var t_drawable_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_drawable_start = CFAbsoluteTimeGetCurrent()
            }
            guard let drawable = view.currentDrawable else { return }
            if ZonvieCore.appLogEnabled {
                let drawable_us = (CFAbsoluteTimeGetCurrent() - t_drawable_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_acquire_drawable us=\(String(format: "%.1f", drawable_us))")
            }

            // Ensure persistent back buffer matches current drawable size.
            var t_backbuf_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_backbuf_start = CFAbsoluteTimeGetCurrent()
            }
            ensureBackBuffer(drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat)
            if ZonvieCore.appLogEnabled {
                let backbuf_us = (CFAbsoluteTimeGetCurrent() - t_backbuf_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_ensure_backbuffer us=\(String(format: "%.1f", backbuf_us))")
            }
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

            if !blurEnabled && hasPresentedOnce && !drawableSizeChanged && (dirtyRectPxOpt != nil || hasAnyDirtyInRowMode) {
                rpd.colorAttachments[0].loadAction = .load
                ZonvieCore.appLog("[draw] loadAction=.load (blur=\(blurEnabled) hasPresentedOnce=\(hasPresentedOnce))")
            } else {
                rpd.colorAttachments[0].loadAction = .clear
                // Use Neovim default background as clear color so viewport edges
                // and smooth-scroll gaps between rows blend in naturally.
                // For blur: use backgroundAlpha (not 0) so gaps match the semi-transparent content.
                let clearAlpha: Double = blurEnabled ? Double(ZonvieConfig.shared.backgroundAlpha) : 1.0
                let bgR = Double((snappedBgRGB >> 16) & 0xFF) / 255.0
                let bgG = Double((snappedBgRGB >> 8) & 0xFF) / 255.0
                let bgB = Double(snappedBgRGB & 0xFF) / 255.0
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: bgR, green: bgG, blue: bgB, alpha: clearAlpha)
                ZonvieCore.appLog("[draw] loadAction=.clear bg=\(String(format: "0x%06X", snappedBgRGB)) alpha=\(clearAlpha)")
            }
            
            // === PERF LOG: Metalエンコード開始 ===
            var t_encode_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_encode_start = CFAbsoluteTimeGetCurrent()
            }

            guard let cmd = queue.makeCommandBuffer() else {
                // defer handles: semaphore.signal() + gpuInFlight decrement
                return
            }
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                // defer handles: semaphore.signal() + gpuInFlight decrement
                return
            }

            // Set viewport to exact grid pixel dimensions to prevent sub-cell stretching.
            // Must match Zig core's NDC computation: cols = drawableW / cellW, grid_w = cols * cellW.
            // Uses integer division to match Zig's u32 arithmetic exactly.
            let cellWi = max(1, UInt32(cw.rounded(.toNearestOrAwayFromZero)))
            let cellHi = max(1, UInt32(ch.rounded(.toNearestOrAwayFromZero)))
            // Use the drawable size from the last committed flush so the Metal
            // viewport matches the NDC coordinates baked into the vertices.
            // Falls back to view.drawableSize before the first flush completes.
            let drawableWi: UInt32
            let drawableHi: UInt32
            if snappedCommittedDrawableW > 0 && snappedCommittedDrawableH > 0 {
                drawableWi = snappedCommittedDrawableW
                drawableHi = snappedCommittedDrawableH
            } else {
                drawableWi = max(1, UInt32(view.drawableSize.width))
                drawableHi = max(1, UInt32(view.drawableSize.height))
            }
            let vpWidth = Double((drawableWi / cellWi) * cellWi)
            let vpHeight = Double((drawableHi / cellHi) * cellHi)
            if vpWidth > 0 && vpHeight > 0 {
                enc.setViewport(MTLViewport(originX: 0, originY: 0, width: vpWidth, height: vpHeight, znear: 0, zfar: 1))
            }

            // Safe to force unwrap: guard at top of draw() ensures pipeline/sampler are non-nil
            enc.setRenderPipelineState(pipeline!)

            // atlas texture + sampler
            if let tex = atlas.texture {
                enc.setFragmentTexture(tex, index: 0)
            }
            enc.setFragmentSamplerState(sampler!, index: 0)

            // Bind scroll offset data. Use setVertexBytes for small data (≤4KB),
            // fall back to a temporary MTLBuffer for larger payloads.
            let maxSetVertexBytesSize = 4096
            var effectiveScrollCount = UInt32(scrollSnapshot.count)
            if !scrollSnapshot.isEmpty {
                scrollSnapshot.withUnsafeBytes { ptr in
                    if ptr.count <= maxSetVertexBytesSize {
                        enc.setVertexBytes(ptr.baseAddress!, length: ptr.count, index: 1)
                    } else if let buf = device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count, options: .storageModeShared) {
                        enc.setVertexBuffer(buf, offset: 0, index: 1)
                    } else {
                        // makeBuffer failed: bind dummy and disable scroll in shader
                        var dummy = ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                        enc.setVertexBytes(&dummy, length: MemoryLayout<ScrollOffset>.stride, index: 1)
                        effectiveScrollCount = 0
                    }
                }
            } else {
                var dummy = ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                enc.setVertexBytes(&dummy, length: MemoryLayout<ScrollOffset>.stride, index: 1)
            }
            do {
                enc.setVertexBytes(&effectiveScrollCount, length: MemoryLayout<UInt32>.size, index: 2)
            }

            // Bind drawable size via setFragmentBytes (avoids shared buffer race
            // when inflightSemaphore allows 2 concurrent draw() calls).
            // Use viewport dimensions so the fragment shader's position→NDC conversion
            // matches the Metal viewport (not the full drawable).
            do {
                let dsW = vpWidth > 0 ? Float(vpWidth) : Float(view.drawableSize.width)
                let dsH = vpHeight > 0 ? Float(vpHeight) : Float(view.drawableSize.height)
                var size = DrawableSize(width: dsW, height: dsH)
                enc.setFragmentBytes(&size, length: MemoryLayout<DrawableSize>.size, index: 0)
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
                    if currentMainCount > 0, let vb = committed.mainVertexBuffer {
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentMainCount)
                    }

                    // Pass 2: Glyphs (standard alpha blending)
                    enc.setRenderPipelineState(glyphPipeline!)
                    if currentMainCount > 0, let vb = committed.mainVertexBuffer {
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

                    if currentMainCount > 0, let vb = committed.mainVertexBuffer {
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
            if cursorBlinkState, currentCursorCount > 0, let cvb = committed.cursorVertexBuffer {
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

            var t_present_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_present_start = CFAbsoluteTimeGetCurrent()
            }
            cmd.present(drawable)
            cmd.addCompletedHandler { [weak self, weak view] _ in
                guard let self = self else { return }
                // Release GPU in-flight mark + semaphore for this buffer set
                self.lock.lock()
                self.gpuInFlightCount[csi] -= 1
                self.lock.unlock()
                self.inflightSemaphore.signal()

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
            if ZonvieCore.appLogEnabled {
                let present_commit_us = (CFAbsoluteTimeGetCurrent() - t_present_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_present_commit us=\(String(format: "%.1f", present_commit_us))")
            }
            gpuSubmitted = true  // Completion handler handles cleanup; prevent defer

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
    
    /// Ensure main vertex buffer in the specified buffer set has sufficient capacity.
    private func ensureMainBufferInSet(_ setIdx: Int, vertexCount: Int) {
        let vc = max(0, vertexCount)
        guard let needed = safeNeededBytes(vertexCount: vc) else { return }

        if bufferSets[setIdx].mainVertexBuffer == nil || needed > bufferSets[setIdx].mainVertexBufferCap {
            guard let nextCap = growCapacity(current: bufferSets[setIdx].mainVertexBufferCap, needed: max(1, needed)) else { return }
            bufferSets[setIdx].mainVertexBufferCap = nextCap
            bufferSets[setIdx].mainVertexBuffer = device.makeBuffer(length: nextCap, options: .storageModeShared)
            if bufferSets[setIdx].mainVertexBuffer == nil {
                bufferSets[setIdx].mainVertexBufferCap = 0
            }
        }
    }

    /// Ensure cursor vertex buffer in the specified buffer set has sufficient capacity.
    private func ensureCursorBufferInSet(_ setIdx: Int, vertexCount: Int) {
        let vc = max(0, vertexCount)
        guard let needed = safeNeededBytes(vertexCount: vc) else { return }

        if bufferSets[setIdx].cursorVertexBuffer == nil || needed > bufferSets[setIdx].cursorVertexBufferCap {
            guard let nextCap = growCapacity(current: bufferSets[setIdx].cursorVertexBufferCap, needed: max(1, needed)) else { return }
            bufferSets[setIdx].cursorVertexBufferCap = nextCap
            bufferSets[setIdx].cursorVertexBuffer = device.makeBuffer(length: nextCap, options: .storageModeShared)
            if bufferSets[setIdx].cursorVertexBuffer == nil {
                bufferSets[setIdx].cursorVertexBufferCap = 0
            }
        }
    }

    /// Ensure row storage arrays in the specified buffer set cover at least `row + 1` entries.
    private func ensureRowStorageInSet(_ setIdx: Int, _ row: Int) {
        if row < 0 { return }
        if row >= maxRowBuffers {
            ZonvieCore.appLog("[Renderer] Row \(row) exceeds maxRowBuffers (\(maxRowBuffers))")
            return
        }
        if row < bufferSets[setIdx].rowVertexBuffers.count { return }
        let newCount = row + 1
        let grow = newCount - bufferSets[setIdx].rowVertexBuffers.count
        bufferSets[setIdx].rowVertexBuffers.append(contentsOf: Array(repeating: nil, count: grow))
        bufferSets[setIdx].rowVertexBufferCaps.append(contentsOf: Array(repeating: 0, count: grow))
        bufferSets[setIdx].rowVertexCounts.append(contentsOf: Array(repeating: 0, count: grow))
    }

    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int = 0) {
        guard isInFlush else {
            ZonvieCore.appLog("[WARNING] submitVerticesRowRaw called outside flush bracket")
            return
        }
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

        // Write to write set (called during flush, no lock needed for vertex data).
        // The write set is exclusively owned by the core thread during flush.
        let s = writeSetIndex

        // Switch to row-buffer mode.
        bufferSets[s].usingRowBuffers = true

        // Track actual grid row count for markAllRowsDirty bounds.
        if totalRows > 0 {
            bufferSets[s].knownTotalRows = totalRows
        }

        // Handle grid resize: if totalRows is smaller than current row storage,
        // shrink arrays to free memory (when significantly oversized).
        if totalRows > 0 && totalRows < bufferSets[s].rowVertexBuffers.count {
            if bufferSets[s].rowVertexBuffers.count > totalRows * 2 {
                bufferSets[s].rowVertexBuffers.removeSubrange(totalRows...)
                bufferSets[s].rowVertexBufferCaps.removeSubrange(totalRows...)
                bufferSets[s].rowVertexCounts.removeSubrange(totalRows...)
            } else {
                for r in totalRows..<bufferSets[s].rowVertexBuffers.count {
                    bufferSets[s].rowVertexCounts[r] = 0
                }
            }
        }

        // We currently assume Zig calls with rowCount == 1 (contract in Zig onFlush).
        guard rowCount > 0 else { return }
        let row = rowStart

        // Skip rows beyond the limit
        guard row >= 0 && row < maxRowBuffers else { return }

        ensureRowStorageInSet(s, row)

        // Ensure storage was actually allocated
        guard row < bufferSets[s].rowVertexBuffers.count else { return }

        guard count > 0, let validPtr = ptr else {
            bufferSets[s].rowVertexCounts[row] = 0
            return
        }

        // bytes needed
        guard let neededBytes = safeNeededBytes(vertexCount: count) else {
            bufferSets[s].rowVertexCounts[row] = 0
            return
        }

        if bufferSets[s].rowVertexBuffers[row] == nil || neededBytes > bufferSets[s].rowVertexBufferCaps[row] {
            guard let nextCap = growCapacity(current: bufferSets[s].rowVertexBufferCaps[row], needed: max(1, neededBytes)) else {
                bufferSets[s].rowVertexCounts[row] = 0
                return
            }
            bufferSets[s].rowVertexBufferCaps[row] = nextCap
            bufferSets[s].rowVertexBuffers[row] = device.makeBuffer(length: nextCap, options: .storageModeShared)
            if bufferSets[s].rowVertexBuffers[row] == nil {
                bufferSets[s].rowVertexBufferCaps[row] = 0
                bufferSets[s].rowVertexCounts[row] = 0
                return
            }
        }

        // Copy vertices
        if let vb = bufferSets[s].rowVertexBuffers[row] {
            memcpy(vb.contents(), validPtr, count * MemoryLayout<Vertex>.stride)
            bufferSets[s].rowVertexCounts[row] = count
        } else {
            bufferSets[s].rowVertexCounts[row] = 0
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

        let bufCount = bufferSets[committedSetIndex].rowVertexBuffers.count
        let known = bufferSets[committedSetIndex].knownTotalRows
        let rowCount = known > 0 ? min(bufCount, known) : bufCount
        if rowCount > 0 {
            pendingDirtyRows.insert(integersIn: 0..<rowCount)
        }
        // Also clear the rect so full redraw happens
        pendingDirtyRectPx = nil
    }

}
