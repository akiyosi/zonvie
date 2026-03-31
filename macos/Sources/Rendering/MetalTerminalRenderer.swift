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
    private(set) var copyVertexBuffer: MTLBuffer?

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
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.alphaBlendOperation = .add
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
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.alphaBlendOperation = .add
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

    private let bufferSets: [SurfaceBufferSet] = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
    private var writeSetIndex: Int = 0       // Core thread only
    // Valid only while isInFlush == true. Tracks the committed set we are detaching from.
    private var flushSourceSetIndex: Int = 0 // Core thread only
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

    private var committedAtlasTexture: MTLTexture?  // Protected by lock
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

    // (rowVertexBuffers/rowVertexCounts/usingRowBuffers moved into BufferSet for triple buffering)

    /// Maximum row buffer count to prevent unbounded memory growth (1000 rows = ~40KB overhead)
    private let maxRowBuffers: Int = 1000

    // --- Dirty region tracking (drawable pixel coordinates) ---
    private var pendingDirtyRectPx: NSRect? = nil
    private var pendingDirtyRows: IndexSet = IndexSet()
    private var hasPresentedOnce: Bool = false

    // --- Accumulated scroll delta (survives across flushes, consumed by draw) ---
    // When multiple flushes occur between draws, each commitFlush accumulates
    // the scroll delta here.  draw() snapshots and resets under lock.
    // Updated ONLY in commitFlush (not in the callback) so that draw() never
    // sees a scroll delta that is ahead of the committed vertex data.
    private var pendingScrollAccum: SurfaceRowScroll? = nil

    // --- Persistent back buffer (for correct partial redraw) ---
    private var backBuffer: MTLTexture? = nil
    private var backBufferSize: CGSize = .zero
    private var scrollScratchTexture: MTLTexture? = nil
    private var scrollScratchSize: CGSize = .zero

    // --- Blur transparency support ---
    private let blurEnabled: Bool
    private var backgroundAlphaBuffer: MTLBuffer?

    // --- Cursor blink support for shader ---
    private var cursorBlinkBuffer: MTLBuffer?

    // --- Post-process bloom (neon glow, Dual Kawase) ---
    // Pipelines and sampler are internal so ExternalGridView can share them.
    private(set) var glowExtractPipeline: MTLRenderPipelineState?
    private(set) var kawaseDownPipeline: MTLRenderPipelineState?
    private(set) var kawaseUpPipeline: MTLRenderPipelineState?
    private(set) var glowCompositePipeline: MTLRenderPipelineState?
    let glowTextures = SurfaceGlowTextures()
    private(set) var bilinearSampler: MTLSamplerState?

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

    private func ensureScrollScratchTexture(drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        if scrollScratchTexture != nil, scrollScratchSize == drawableSize { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(1, Int(drawableSize.width)),
            height: max(1, Int(drawableSize.height)),
            mipmapped: false
        )
        desc.storageMode = .private
        scrollScratchTexture = device.makeTexture(descriptor: desc)
        scrollScratchSize = drawableSize
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
            var alpha = resolveSurfaceBackgroundAlpha(
                blurEnabled: blurEnabled,
                decoratedSurface: false
            )
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
    enum BeginFlushResult {
        case proceed                   // Normal flush, no special action needed
        case proceedWithInvalidation   // Flush OK, but core glyph cache invalidation needed
        case dropped                   // Flush aborted — core must skip vertex/atlas generation
    }

    func beginFlush() -> BeginFlushResult {
        isInFlush = true
        let perfEnabled = ZonvieCore.appLogEnabled
        let tBeginFlushStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        var atlasPrepareUs: Double = 0
        var atlasCommitUs: Double = 0
        var atlasWaitUs: Double = 0
        var atlasDidBlit = false
        var atlasDidCpuSync = false
        var atlasNeedsCoreInvalidation = false
        var atlasSyncedWasRecreate = false

        // Under lock: read committed index + gpuInFlight to pick a safe write set
        let srcIdx: Int
        lock.lock()
        srcIdx = committedSetIndex
        let picked = pickFreeBufferSetIndex(
            count: 3,
            committedIndex: srcIdx,
            gpuInFlightCount: gpuInFlightCount
        )
        if picked == -1 {
            // All non-committed sets are GPU in-flight (should be unreachable
            // with semaphore=1 + sem.wait() before gpuInFlightCount++).
            // Drop this flush entirely to avoid GPU/CPU race on shared buffers.
            let inf = gpuInFlightCount
            lock.unlock()
            isInFlush = false
            ZonvieCore.appLog("[WARNING] beginFlush: no free buffer set, dropping flush committed=\(srcIdx) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return .dropped
        }
        writeSetIndex = picked
        flushSourceSetIndex = srcIdx
        if ZonvieCore.appLogEnabled {
            let inf = gpuInFlightCount
            ZonvieCore.appLog("[scroll_debug] beginFlush committed=\(srcIdx) write=\(picked) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
        }
        lock.unlock()

        // Prepare atlas back texture
        var needsCoreInvalidation = false
        if let cmd = queue.makeCommandBuffer() {
            let tAtlasPrepareStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let result = atlas.prepareBackTexture(commandBuffer: cmd)
            if perfEnabled {
                atlasPrepareUs = (CFAbsoluteTimeGetCurrent() - tAtlasPrepareStart) * 1_000_000
            }
            needsCoreInvalidation = result.needsCoreInvalidation
            atlasNeedsCoreInvalidation = result.needsCoreInvalidation
            atlasDidBlit = result.didBlit
            atlasDidCpuSync = result.didCpuSync
            atlasSyncedWasRecreate = result.syncedWasRecreate
            if result.shouldAbort {
                isInFlush = false
                ZonvieCore.appLog("[WARNING] beginFlush: atlas back-texture sync failed (nil texture/resize/encoder), dropping flush")
                return .dropped
            }
            if result.didBlit {
                let tAtlasCommitStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                cmd.commit()
                if perfEnabled {
                    atlasCommitUs = (CFAbsoluteTimeGetCurrent() - tAtlasCommitStart) * 1_000_000
                }
                let tAtlasWaitStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                cmd.waitUntilCompleted()
                if perfEnabled {
                    atlasWaitUs = (CFAbsoluteTimeGetCurrent() - tAtlasWaitStart) * 1_000_000
                }
                if cmd.status == .completed {
                    atlas.markBackSynced()
                } else {
                    // Blit failed (device loss, encoding error, etc.).
                    // backDirty stays true; drop this flush to avoid writing
                    // incremental glyph changes into a stale back texture.
                    isInFlush = false
                    ZonvieCore.appLog("[WARNING] beginFlush: atlas blit command buffer failed (status=\(cmd.status.rawValue)), dropping flush")
                    return .dropped
                }
            }
        } else {
            // commandBuffer creation failed.
            // If atlas state requires attention (backDirty, needsAtlasRebuild,
            // or atlasModified), we must abort — continuing would let uploadRegion
            // write to an un-synced back texture or leave stale cache active.
            if atlas.hasAtlasStateRequiringAttention() {
                isInFlush = false
                ZonvieCore.appLog("[WARNING] beginFlush: commandBuffer creation failed with pending atlas state, dropping flush")
                return .dropped
            }
        }

        let src = bufferSets[srcIdx]
        let dst = bufferSets[picked]

        let sharedRowRefs = perfEnabled ? src.rowState.counts.reduce(into: 0) { partial, count in
            if count > 0 { partial += 1 }
        } : 0
        let tRowCopyStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0

        // Start from the committed set by sharing immutable buffer references.
        // Updated rows/buffers will be detached lazily on first write.
        let srcRowCount = src.rowState.buffers.count
        copySurfaceBufferSetRowState(from: src, to: dst)
        let tRowCopyEnd = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0

        // Save dst's main/cursor buffers into the detach pool before shallow-copying src.
        dst.detachPoolMainBuffer = dst.mainVertexBuffer
        dst.detachPoolMainCap = dst.mainVertexBufferCap
        dst.detachPoolCursorBuffer = dst.cursorVertexBuffer
        dst.detachPoolCursorCap = dst.cursorVertexBufferCap

        let sharedMainBytes = src.mainVertexCount * MemoryLayout<Vertex>.stride
        let tMainCopyStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        dst.mainVertexBuffer = src.mainVertexBuffer
        dst.mainVertexBufferCap = src.mainVertexBufferCap
        dst.mainVertexCount = src.mainVertexCount
        let tMainCopyEnd = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0

        let sharedCursorBytes = src.cursorVertexCount * MemoryLayout<Vertex>.stride
        let tCursorCopyStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        dst.cursorVertexBuffer = src.cursorVertexBuffer
        dst.cursorVertexBufferCap = src.cursorVertexBufferCap
        dst.cursorVertexCount = src.cursorVertexCount
        let tCursorCopyEnd = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0

        dst.pendingScroll = nil

        if perfEnabled {
            let rowCopyUs = (tRowCopyEnd - tRowCopyStart) * 1_000_000
            let mainCopyUs = (tMainCopyEnd - tMainCopyStart) * 1_000_000
            let cursorCopyUs = (tCursorCopyEnd - tCursorCopyStart) * 1_000_000
            let totalUs = (CFAbsoluteTimeGetCurrent() - tBeginFlushStart) * 1_000_000
            let rowCopyUsStr = String(format: "%.1f", rowCopyUs)
            let mainCopyUsStr = String(format: "%.1f", mainCopyUs)
            let cursorCopyUsStr = String(format: "%.1f", cursorCopyUs)
            let totalUsStr = String(format: "%.1f", totalUs)
            let atlasPrepareUsStr = String(format: "%.1f", atlasPrepareUs)
            let atlasCommitUsStr = String(format: "%.1f", atlasCommitUs)
            let atlasWaitUsStr = String(format: "%.1f", atlasWaitUs)
            ZonvieCore.appLog(
                "[perf] begin_flush_prepare src=\(srcIdx) dst=\(picked) atlasDidBlit=\(atlasDidBlit) atlasDidCpuSync=\(atlasDidCpuSync) atlasNeedsCoreInvalidation=\(atlasNeedsCoreInvalidation) atlasSyncedWasRecreate=\(atlasSyncedWasRecreate) atlasPrepareUs=\(atlasPrepareUsStr) atlasCommitUs=\(atlasCommitUsStr) atlasWaitUs=\(atlasWaitUsStr) rowBuffers=\(srcRowCount) sharedRowRefs=\(sharedRowRefs) sharedRowBytes=\(src.rowState.counts.reduce(0, +) * MemoryLayout<Vertex>.stride) rowPrepUs=\(rowCopyUsStr) sharedMainBytes=\(sharedMainBytes) mainPrepUs=\(mainCopyUsStr) sharedCursorBytes=\(sharedCursorBytes) cursorPrepUs=\(cursorCopyUsStr) totalUs=\(totalUsStr)"
            )
        }

        return needsCoreInvalidation ? .proceedWithInvalidation : .proceed
    }

    /// Called after beginFlush() returned .proceed/.proceedWithInvalidation but
    /// the core later called zonvie_core_abort_flush (e.g. recreateTexture failure).
    /// Clears isInFlush so commitFlush becomes a no-op, preventing stale vertices
    /// from being published under the new layout dimensions.
    func abortFlush() {
        isInFlush = false
    }

    /// Called from on_flush_end callback (core thread, grid_mu held).
    /// Atomically makes the write set the new committed set for draw().
    /// drawableW/drawableH are the core's layout at flush time, read via
    /// zonvie_core_get_layout while grid_mu is still held — this guarantees
    /// the values match the NDC coordinates in the committed vertices.
    func commitFlush(drawableW: UInt32, drawableH: UInt32) {
        guard isInFlush else { return }  // Flush was dropped or aborted

        // Atomically commit atlas (swap if modified) and snapshot front texture
        let newAtlasTex = atlas.commitAndSnapshotFrontTexture()

        let ws = writeSetIndex
        lock.lock()
        committedSetIndex = writeSetIndex
        committedDrawableW = drawableW
        committedDrawableH = drawableH
        committedAtlasTexture = newAtlasTex  // same lock as vertex state
        commitRevision &+= 1
        let rev = commitRevision
        // Accumulate the write set's pendingScroll into the global accumulator.
        // Done here (under lock, after committedSetIndex update) so draw() never
        // sees a scroll delta that precedes the matching vertex data.
        if let ps = bufferSets[ws].pendingScroll {
            if let existing = pendingScrollAccum,
               existing.rowStart == ps.rowStart,
               existing.rowEnd == ps.rowEnd {
                pendingScrollAccum = SurfaceRowScroll(
                    rowStart: ps.rowStart,
                    rowEnd: ps.rowEnd,
                    colStart: ps.colStart,
                    colEnd: ps.colEnd,
                    rowsDelta: existing.rowsDelta + ps.rowsDelta,
                    totalRows: ps.totalRows,
                    totalCols: ps.totalCols
                )
            } else {
                pendingScrollAccum = ps
            }
        }
        lock.unlock()
        isInFlush = false
        if ZonvieCore.appLogEnabled {
            let rowCount = bufferSets[ws].rowState.buffers.count
            var totalVerts = 0
            for i in 0..<rowCount {
                totalVerts += bufferSets[ws].rowState.counts[i]
            }
            ZonvieCore.appLog("[scroll_debug] commitFlush set=\(ws) rows=\(rowCount) totalVerts=\(totalVerts) rev=\(rev)")
        }
    }

    /// Returns the committed atlas texture for external grid views.
    /// Uses same lock + committed state as vertex data.
    func committedAtlasSnapshot() -> MTLTexture? {
        lock.lock()
        let tex = committedAtlasTexture
        lock.unlock()
        return tex
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

        bufferSets[s].rowState.usingRowBuffers = false

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
        if ZonvieCore.appLogEnabled,
           let inputTrace = (view as? MetalTerminalView)?.core?.currentInputTraceSnapshot(),
           inputTrace.seq != 0,
           inputTrace.sentNs != 0,
           inputTrace.lastDrawStartLoggedSeq != inputTrace.seq
        {
            let nowNs = zonvie_core_perf_now_ns()
            let deltaUs = max(Int64(0), (nowNs - inputTrace.sentNs) / 1_000)
            ZonvieCore.appLog("[perf_input] seq=\(inputTrace.seq) stage=draw_start delta_us=\(deltaUs)")
            (view as? MetalTerminalView)?.core?.markInputTraceDrawStartLogged(seq: inputTrace.seq)
        }
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
            let atlasTex: MTLTexture?
            let dirtyRectPxOpt: CGRect?
            var dirtyRows: [Int]
            let smoothScrolling: Bool
            let scrollSnapshot: [ScrollOffset]  // Snapshot for setVertexBytes (no GPU/CPU race)
            let pendingScroll: SurfaceRowScroll?
            let rowLogicalToSlotSnapshot: [Int]
            let rowSlotSourceRowsSnapshot: [Int]

            let snappedBgRGB: UInt32
            let snappedCommittedDrawableW: UInt32
            let snappedCommittedDrawableH: UInt32

            lock.lock()
            csi = committedSetIndex
            currentCommitRevision = commitRevision
            gpuInFlightCount[csi] += 1  // Prevent beginFlush from using this set

            atlasTex = committedAtlasTexture  // same lock scope as vertex snapshot
            dirtyRectPxOpt = pendingDirtyRectPx
            dirtyRows = Array(pendingDirtyRows)
            pendingDirtyRectPx = nil
            pendingDirtyRows.removeAll()
            smoothScrolling = hasActiveScrollOffset
            scrollSnapshot = scrollOffsetData  // Value-type copy (safe across frames)
            // Use accumulated scroll delta (covers multiple flushes between draws)
            // instead of per-set pendingScroll which only has the last flush's delta.
            pendingScroll = pendingScrollAccum ?? bufferSets[csi].pendingScroll
            pendingScrollAccum = nil
            rowLogicalToSlotSnapshot = bufferSets[csi].rowLogicalToSlot
            rowSlotSourceRowsSnapshot = bufferSets[csi].rowSlotSourceRows
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
            let rowBuffersSnapshot = committed.rowState.buffers
            let rowCountsSnapshot = committed.rowState.counts
            let rowMode = committed.rowState.usingRowBuffers
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

            // In rowMode with no vertex updates and no dirty rows, skip rendering.
            // Also skip when a new commit arrived but carried no visual changes
            // (e.g. empty non-scroll flush).  Without this, the .clear loadAction
            // destroys the backbuffer between GPU-blit scroll frames.
            if rowMode && dirtyRows.isEmpty && pendingScroll == nil && !smoothScrolling && !blinkStateChanged && !drawableSizeChanged && hasPresentedOnce {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Track that we've consumed this revision and drawable size
            lastDrawnRevision = currentCommitRevision
            lastDrawnDrawableSize = view.drawableSize

            // Update last rendered blink state since we're proceeding with render
            lastRenderedBlinkState = cursorBlinkState

            // --- Step 1: Detect blink-only frame condition ---
            let isBlinkOnlyFrame = blinkStateChanged
                && !hasNewCommit
                && dirtyRows.isEmpty
                && dirtyRectPxOpt == nil
                && !smoothScrolling
                && !drawableSizeChanged
                && hasPresentedOnce

            // --- Step 2: Pre-compute shared values for loadAction gate and draw branching ---
            let cellWi = max(1, UInt32(cw.rounded(.toNearestOrAwayFromZero)))
            let cellHi = max(1, UInt32(ch.rounded(.toNearestOrAwayFromZero)))
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
            let viewportMetrics = SurfaceViewportMetrics(
                viewportWidth: vpWidth,
                viewportHeight: vpHeight,
                drawableSize: view.drawableSize
            )

            let use2Pass = blurEnabled && backgroundPipeline != nil && glyphPipeline != nil

            let safeRowCount: Int
            if rowMode {
                safeRowCount = min(min(rowBuffersSnapshot.count, rowCountsSnapshot.count), rowLogicalToSlotSnapshot.count)
            } else {
                safeRowCount = 0
            }
            // Glow must be checked early — it disables partial-redraw optimizations
            // (GPU scroll copy, dirty-row-only rendering) because additive bloom
            // composite accumulates brightness when backBuffer preserves previous glow.
            let glowEnabled = (view as? MetalTerminalView)?.core?.isGlowEnabled() ?? false

            let useGpuScrollCopy = rowMode
                && hasNewCommit
                && pendingScroll != nil
                && hasPresentedOnce
                && !smoothScrolling
                && !drawableSizeChanged
                && !glowEnabled
            let rowTranslationDenom = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)
            func resolvedRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow >= 0, logicalRow < safeRowCount else { return nil }
                let slot = rowLogicalToSlotSnapshot[logicalRow]
                guard slot >= 0, slot < rowCountsSnapshot.count, slot < rowBuffersSnapshot.count else { return nil }
                let vc = rowCountsSnapshot[slot]
                guard vc > 0, let vb = rowBuffersSnapshot[slot] else { return nil }
                let sourceRow = slot < rowSlotSourceRowsSnapshot.count ? rowSlotSourceRowsSnapshot[slot] : logicalRow
                let translationY = Float(sourceRow - logicalRow) * Float(cellHi) / max(1.0, rowTranslationDenom) * 2.0
                return (vc, vb, translationY)
            }

            // --- Step 3: Compute cursor grid row from NDC vertex positions ---
            var cursorGridRow: Int = -1
            if currentCursorCount > 0, let cvb = committed.cursorVertexBuffer {
                let ptr = cvb.contents().bindMemory(to: Vertex.self, capacity: currentCursorCount)
                var maxNdcY: Float = ptr[0].position.y
                for i in 1..<currentCursorCount {
                    let y = ptr[i].position.y
                    if y > maxNdcY { maxNdcY = y }
                }
                // NDC → pixel (top-origin): y_px = (1 - ndc_y) * vpHeight / 2
                // Inverse of Zig core's ndc(): ny = 1.0 - (y_px / dh) * 2.0
                let topYPx = (1.0 - maxNdcY) * Float(vpHeight) / 2.0
                cursorGridRow = Int(floor(topYPx / Float(cellHi)))
                // No clamping: out-of-range → canBlinkFastPath = false → full redraw
            }

            // --- Step 4: Gate for blink fast path ---
            let canBlinkFastPath: Bool = {
                guard isBlinkOnlyFrame && blurEnabled && rowMode && use2Pass && !glowEnabled else { return false }
                guard cursorGridRow >= 0 && cursorGridRow < safeRowCount else { return false }
                guard resolvedRowState(cursorGridRow) != nil else { return false }
                return true
            }()

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

            guard let cmd = queue.makeCommandBuffer() else {
                return
            }
            var scrollClearBand: (clearTopPx: Int, clearBottomPx: Int)? = nil
            if useGpuScrollCopy, let pendingScroll = pendingScroll {
                scrollClearBand = encodePendingMainRowScrollCopy(
                    commandBuffer: cmd,
                    backTexture: backTex,
                    drawableWidthPx: Int(vpWidth > 0 ? vpWidth : view.drawableSize.width),
                    rowHeightPx: Int(cellHi),
                    scroll: pendingScroll,
                    logEnabled: ZonvieCore.appLogEnabled
                )

                // When multiple flushes accumulate between draws, the blit shifts
                // by the total accumulated delta D.  The vacated region (D rows)
                // must be redrawn.  Additionally, intermediate scroll steps each
                // produced a new row whose vertex data was inherited via buffer-set
                // copy + slot remap, but the backbuffer still holds pre-scroll
                // pixels for those positions.  Expand dirty rows by 2*D to cover
                // both the vacated region and these intermediate rows.
                let shift = abs(pendingScroll.rowsDelta)
                if shift > 0 {
                    let expandStart: Int
                    let expandEnd: Int
                    if pendingScroll.rowsDelta > 0 {
                        // Scroll down: vacated at bottom, intermediate rows above
                        expandEnd = pendingScroll.rowEnd
                        expandStart = max(pendingScroll.rowStart, pendingScroll.rowEnd - 2 * shift)
                    } else {
                        // Scroll up: vacated at top, intermediate rows below
                        expandStart = pendingScroll.rowStart
                        expandEnd = min(pendingScroll.rowEnd, pendingScroll.rowStart + 2 * shift)
                    }
                    let dirtySet = Set(dirtyRows)
                    for row in expandStart..<expandEnd {
                        if !dirtySet.contains(row) {
                            dirtyRows.append(row)
                        }
                    }
                }
            }

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

            // When glow is enabled, force full redraw (.clear) to prevent additive
            // bloom composite from accumulating brightness across frames.
            // When blur is enabled, partial redraw with .load is safe as long as
            // the background pass uses overwrite blending (dirty rows are fully
            // rewritten, so alpha doesn't accumulate).  Allow .load for dirty-only
            // row-mode draws to avoid expensive full-clear redraws between scroll
            // flushes (e.g. statusline updates).
            let canDirtyOnlyWithBlur = rowMode && use2Pass && hasAnyDirtyInRowMode
                && hasPresentedOnce && !smoothScrolling && !drawableSizeChanged && !glowEnabled
            let shouldReusePreviousContents = !glowEnabled && (canBlinkFastPath || useGpuScrollCopy || canDirtyOnlyWithBlur || (!smoothScrolling && (dirtyRectPxOpt != nil || hasAnyDirtyInRowMode)))
            rpd.colorAttachments[0].loadAction = resolveSurfaceColorLoadAction(
                blurEnabled: blurEnabled,
                hasPresentedOnce: hasPresentedOnce,
                drawableSizeChanged: drawableSizeChanged,
                shouldReusePreviousContents: shouldReusePreviousContents,
                forceReusePreviousContents: !glowEnabled && (canBlinkFastPath || useGpuScrollCopy || canDirtyOnlyWithBlur)
            )

            if rpd.colorAttachments[0].loadAction == .load {
                if canBlinkFastPath {
                    ZonvieCore.appLog("[draw] loadAction=.load (blinkFastPath cursorRow=\(cursorGridRow))")
                } else if useGpuScrollCopy {
                    ZonvieCore.appLog("[draw] loadAction=.load (gpuScrollCopy)")
                } else {
                    ZonvieCore.appLog("[draw] loadAction=.load (blur=\(blurEnabled) hasPresentedOnce=\(hasPresentedOnce))")
                }
            } else {
                rpd.colorAttachments[0].loadAction = .clear
                // Use Neovim default background as clear color so viewport edges
                // and smooth-scroll gaps between rows blend in naturally.
                rpd.colorAttachments[0].clearColor = makeSurfaceClearColor(
                    bgRGB: snappedBgRGB,
                    blurEnabled: blurEnabled
                )
                ZonvieCore.appLog("[draw] loadAction=.clear bg=\(String(format: "0x%06X", snappedBgRGB)) alpha=\(rpd.colorAttachments[0].clearColor.alpha)")
            }
            
            // === PERF LOG: Metalエンコード開始 ===
            var t_encode_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_encode_start = CFAbsoluteTimeGetCurrent()
            }

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                // defer handles: semaphore.signal() + gpuInFlight decrement
                return
            }

            // Set viewport to exact grid pixel dimensions to prevent sub-cell stretching.
            // Must match Zig core's NDC computation: cols = drawableW / cellW, grid_w = cols * cellW.
            // cellWi/cellHi/drawableWi/drawableHi/vpWidth/vpHeight are pre-computed in Step 2 above.
            viewportMetrics.applyViewport(to: enc)

            // Safe to force unwrap: guard at top of draw() ensures pipeline/sampler are non-nil
            enc.setRenderPipelineState(pipeline!)

            // atlas texture + sampler
            if let tex = atlasTex {
                enc.setFragmentTexture(tex, index: 0)
            }
            enc.setFragmentSamplerState(sampler!, index: 0)

            // Bind scroll offsets, fragment state (drawable size, alpha, blink) via shared helpers
            bindSurfaceScrollOffsets(encoder: enc, offsets: scrollSnapshot, device: device)
            bindSurfaceFragmentState(
                encoder: enc,
                viewportMetrics: viewportMetrics,
                backgroundAlphaBuffer: backgroundAlphaBuffer,
                cursorBlinkBuffer: cursorBlinkBuffer,
                cursorBlinkVisible: true  // always visible; cursor drawn as separate overlay pass
            )
            var zeroRowTranslation: Float = 0
            enc.setVertexBytes(&zeroRowTranslation, length: MemoryLayout<Float>.size, index: 3)

            let drawableW = max(0, Int(view.drawableSize.width.rounded(.down)))
            let cellH = max(1, Int(cellHeightPx.rounded(.up)))

            // use2Pass and safeRowCount are pre-computed in Step 2 above.

            if rowMode {
                if use2Pass {
                    if canBlinkFastPath {
                        // FAST PATH: blink-only — redraw only cursor row (2-pass)
                        let resolved = resolvedRowState(cursorGridRow)!  // guaranteed non-nil by canBlinkFastPath
                        let vc = resolved.vc
                        let vb = resolved.vb

                        let y = max(0, cursorGridRow * Int(cellHi))
                        let h = Int(cellHi)
                        if drawableW > 0 && h > 0 {
                            enc.setScissorRect(MTLScissorRect(x: 0, y: y, width: drawableW, height: h))
                        }

                        // Pass 1: Background (overwrite blending — erases old cursor)
                        enc.setRenderPipelineState(backgroundPipeline!)
                        var rowTranslation = resolved.translationY
                        enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)

                        // Pass 2: Glyph (alpha blending — redraws text/decorations)
                        enc.setRenderPipelineState(glyphPipeline!)
                        enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)

                        ZonvieCore.appLog("[draw] blinkFastPath: cursorRow=\(cursorGridRow) vc=\(vc)")
                    } else if useGpuScrollCopy {
                        // Switch to backgroundPipeline (overwrite blend: one, zero)
                        // for ALL clear operations in the scroll path.  With blur
                        // enabled, the main pipeline's alpha blend would leave stale
                        // content in both the scrollClearBand and vc==0 rows.
                        let scrollDrawableW = Float(vpWidth > 0 ? vpWidth : view.drawableSize.width)
                        let scrollDrawableH = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)
                        let scrollCellHiI = Int(cellHi)
                        if let bgPipe = backgroundPipeline {
                            enc.setRenderPipelineState(bgPipe)
                        }
                        if let clearBand = scrollClearBand {
                            drawBackgroundClearBand(
                                enc,
                                clearBand: clearBand,
                                drawableWidth: scrollDrawableW,
                                drawableHeight: scrollDrawableH,
                                bgRGB: snappedBgRGB
                            )
                        }
                        // Also clear dirty rows with vc==0 that fall outside the
                        // scrollClearBand (e.g. intermediate rows from accumulated
                        // scroll steps).
                        for row in dirtyRows {
                            if resolvedRowState(row) == nil {
                                let topPx = row * scrollCellHiI
                                let bottomPx = topPx + scrollCellHiI
                                drawBackgroundClearBand(
                                    enc,
                                    clearBand: (clearTopPx: topPx, clearBottomPx: bottomPx),
                                    drawableWidth: scrollDrawableW,
                                    drawableHeight: scrollDrawableH,
                                    bgRGB: snappedBgRGB
                                )
                            }
                        }
                        let drawItems = buildSurfaceRowDrawItems(
                            rows: dirtyRows,
                            resolve: resolvedRowState
                        ) { row in
                            makeRowScissorRect(row: row, cellHeight_px: scrollCellHiI, drawableWidth_px: drawableW)
                        }
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            items: drawItems,
                            pipeline: pipeline!,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true
                        )
                    } else if canDirtyOnlyWithBlur {
                        // Partial redraw with .load for blur: only dirty rows are
                        // redrawn using 2-pass (overwrite bg + alpha glyph) with
                        // scissor rects.  Safe because overwrite blending prevents
                        // alpha accumulation in the redrawn rows.
                        //
                        // Rows with vc==0 (cleared by core) are dropped by
                        // resolvedRowState → buildSurfaceRowDrawItems.  Since
                        // loadAction=.load, the old backbuffer pixels would persist.
                        // Draw a background-color quad for these empty rows using
                        // backgroundPipeline (overwrite blend) to fully replace old content.
                        let drawableWidthF = Float(vpWidth > 0 ? vpWidth : view.drawableSize.width)
                        let drawableHeightF = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)
                        let cellHiI = Int(cellHi)
                        if let bgPipe = backgroundPipeline {
                            enc.setRenderPipelineState(bgPipe)
                            for row in dirtyRows {
                                if resolvedRowState(row) == nil {
                                    let topPx = row * cellHiI
                                    let bottomPx = topPx + cellHiI
                                    drawBackgroundClearBand(
                                        enc,
                                        clearBand: (clearTopPx: topPx, clearBottomPx: bottomPx),
                                        drawableWidth: drawableWidthF,
                                        drawableHeight: drawableHeightF,
                                        bgRGB: snappedBgRGB
                                    )
                                }
                            }
                        }
                        let drawItems = buildSurfaceRowDrawItems(
                            rows: dirtyRows,
                            resolve: resolvedRowState
                        ) { row in
                            makeRowScissorRect(row: row, cellHeight_px: cellHiI, drawableWidth_px: drawableW)
                        }
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            items: drawItems,
                            pipeline: pipeline!,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true
                        )
                    } else {
                        // 2-Pass rendering for blur: draw backgrounds first, then glyphs
                        // This prevents ghosting with semi-transparent backgrounds
                        let drawItems = buildSurfaceRowDrawItems(safeRowCount: safeRowCount, resolve: resolvedRowState)
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            items: drawItems,
                            pipeline: pipeline!,
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
                        pipeline: pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else if useGpuScrollCopy {
                    if let clearBand = scrollClearBand {
                        drawBackgroundClearBand(
                            enc,
                            clearBand: clearBand,
                            drawableWidth: Float(vpWidth > 0 ? vpWidth : Double(view.drawableSize.width)),
                            drawableHeight: Float(vpHeight > 0 ? vpHeight : Double(view.drawableSize.height)),
                            bgRGB: snappedBgRGB
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
                        pipeline: pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else if !glowEnabled && !dirtyRows.isEmpty {
                    // Normal mode: scissor per dirty row (prevents giant scissor from accumulated unions).
                    // Skipped when glow is enabled — full redraw needed for correct bloom composite.
                    let drawItems = buildSurfaceRowDrawItems(
                        rows: dirtyRows,
                        resolve: resolvedRowState
                    ) { row in
                        makeRowScissorRect(row: row, cellHeight_px: cellH, drawableWidth_px: drawableW)
                    }
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        items: drawItems,
                        pipeline: pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else {
                    // Safety: if no dirtyRows (first frame), draw all rows without scissor.
                    let drawItems = buildSurfaceRowDrawItems(safeRowCount: safeRowCount, resolve: resolvedRowState)
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        items: drawItems,
                        pipeline: pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                }
            } else {
                // Non-rowMode: shared helper handles 2-pass vs single-pass dispatch
                let dirtyScissor: MTLScissorRect? = {
                    guard !use2Pass, let dr = dirtyRectPxOpt else { return nil }
                    let x = max(0, Int(dr.origin.x.rounded(.down)))
                    let y = max(0, Int(dr.origin.y.rounded(.down)))
                    let w = max(0, Int(dr.size.width.rounded(.up)))
                    let h = max(0, Int(dr.size.height.rounded(.up)))
                    return (w > 0 && h > 0) ? MTLScissorRect(x: x, y: y, width: w, height: h) : nil
                }()
                encodeSurfaceNonRowContent(
                    encoder: enc,
                    vertexBuffer: committed.mainVertexBuffer,
                    vertexCount: currentMainCount,
                    pipeline: pipeline!,
                    backgroundPipeline: backgroundPipeline,
                    glyphPipeline: glyphPipeline,
                    useTwoPass: use2Pass,
                    scissorRect: dirtyScissor
                )
            }

            // Reset scissor before cursor pass.
            // In rowMode we scissor per row; leaving it as-is will clip the cursor.
            // canBlinkFastPath also sets a scissor that must be reset.
            if (rowMode && (!use2Pass || useGpuScrollCopy)) || canBlinkFastPath {
                let fullW = max(0, Int(view.drawableSize.width.rounded(.down)))
                let fullH = max(0, Int(view.drawableSize.height.rounded(.down)))
                if fullW > 0 && fullH > 0 {
                    enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: fullW, height: fullH))
                }
            }

            enc.endEncoding()

            // === PERF LOG: Metalエンコード終了 ===
            if ZonvieCore.appLogEnabled {
                let t_encode_end = CFAbsoluteTimeGetCurrent()
                let encode_us = (t_encode_end - t_encode_start) * 1_000_000
                ZonvieCore.appLog("[perf] draw_encode rowMode=\(rowMode) us=\(String(format: "%.1f", encode_us))")
            }

            // --- Post-process bloom (neon glow) ---
            if glowEnabled,
               let extractPipe = glowExtractPipeline,
               let downPipe = kawaseDownPipeline,
               let upPipe = kawaseUpPipeline,
               let compositePipe = glowCompositePipeline,
               let copyVB = copyVertexBuffer,
               let bilinSamp = bilinearSampler
            {
                let vpSize = CGSize(width: viewportMetrics.viewportWidth, height: viewportMetrics.viewportHeight)
                glowTextures.ensure(device: device, drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat)
                glowTextures.ensureIntensityBuffer(device: device)
                let intensity = (view as? MetalTerminalView)?.core?.getGlowIntensity() ?? 0.8

                encodeSurfaceBloomPasses(
                    cmd: cmd,
                    backTex: backTex,
                    viewportSize: vpSize,
                    drawableSize: view.drawableSize,
                    glowTextures: glowTextures,
                    extractPipeline: extractPipe,
                    kawaseDownPipeline: downPipe,
                    kawaseUpPipeline: upPipe,
                    compositePipeline: compositePipe,
                    copyVertexBuffer: copyVB,
                    bilinearSampler: bilinSamp,
                    intensity: intensity
                ) { enc in
                    // Extract vertices: atlas + scroll offsets + row/main + cursor
                    if let tex = atlasTex {
                        enc.setFragmentTexture(tex, index: 0)
                    }
                    enc.setFragmentSamplerState(sampler!, index: 0)

                    var extractScrollCount = UInt32(scrollSnapshot.count)
                    if !scrollSnapshot.isEmpty {
                        scrollSnapshot.withUnsafeBytes { ptr in
                            enc.setVertexBytes(ptr.baseAddress!, length: ptr.count, index: 1)
                        }
                    } else {
                        var dummy = ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                        enc.setVertexBytes(&dummy, length: MemoryLayout<ScrollOffset>.stride, index: 1)
                        extractScrollCount = 0
                    }
                    enc.setVertexBytes(&extractScrollCount, length: MemoryLayout<UInt32>.size, index: 2)
                    var zeroTrans: Float = 0
                    enc.setVertexBytes(&zeroTrans, length: MemoryLayout<Float>.size, index: 3)

                    if rowMode {
                        for row in 0..<safeRowCount {
                            guard let resolved = resolvedRowState(row) else { continue }
                            var rt = resolved.translationY
                            enc.setVertexBytes(&rt, length: MemoryLayout<Float>.size, index: 3)
                            enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
                        }
                    } else if currentMainCount > 0, let mvb = committed.mainVertexBuffer {
                        enc.setVertexBuffer(mvb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentMainCount)
                    }

                    // Cursor glow
                    if cursorBlinkState, currentCursorCount > 0, let cvb = committed.cursorVertexBuffer {
                        var ct: Float = 0
                        enc.setVertexBytes(&ct, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(cvb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentCursorCount)
                    }
                }
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

            // Cursor is composited only on the final drawable.
            // This keeps the persistent back buffer cursor-free and prevents stale
            // cursor pixels from being moved by GPU scroll-region copies.
            ZonvieCore.appLog("[cursor-draw] cursorBlinkState=\(cursorBlinkState) cursorCount=\(currentCursorCount)")
            if cursorBlinkState, currentCursorCount > 0, let cvb = committed.cursorVertexBuffer {
                let cursorRPD = MTLRenderPassDescriptor()
                cursorRPD.colorAttachments[0].texture = drawable.texture
                cursorRPD.colorAttachments[0].loadAction = .load
                cursorRPD.colorAttachments[0].storeAction = .store

                if let cursorEnc = cmd.makeRenderCommandEncoder(descriptor: cursorRPD) {
                    viewportMetrics.applyViewport(to: cursorEnc)
                    cursorEnc.setRenderPipelineState(pipeline!)
                    if let tex = atlasTex {
                        cursorEnc.setFragmentTexture(tex, index: 0)
                    }
                    cursorEnc.setFragmentSamplerState(sampler!, index: 0)

                    bindSurfaceScrollOffsets(encoder: cursorEnc, offsets: scrollSnapshot, device: device)
                    bindSurfaceFragmentState(
                        encoder: cursorEnc,
                        viewportMetrics: viewportMetrics,
                        backgroundAlphaBuffer: backgroundAlphaBuffer,
                        cursorBlinkBuffer: cursorBlinkBuffer,
                        cursorBlinkVisible: true
                    )
                    var zeroTranslation: Float = 0
                    cursorEnc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)

                    cursorEnc.setVertexBuffer(cvb, offset: 0, index: 0)
                    cursorEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentCursorCount)
                    cursorEnc.endEncoding()
                }
            }

            var t_present_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_present_start = CFAbsoluteTimeGetCurrent()
            }
            cmd.present(drawable)
            // Capture semaphore and lock directly so the signal fires even
            // if the renderer is deallocated before the GPU finishes.
            let sem = inflightSemaphore
            let lk = lock
            cmd.addCompletedHandler { [weak self, weak view] _ in
                // Always release GPU in-flight mark + semaphore, even if self is gone.
                lk.lock()
                self?.gpuInFlightCount[csi] -= 1
                lk.unlock()
                sem.signal()

                guard let self = self else { return }
                let wasFirstPresent = !self.hasPresentedOnce
                self.hasPresentedOnce = true

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
                if let inputTrace = (view as? MetalTerminalView)?.core?.currentInputTraceSnapshot(),
                   inputTrace.seq != 0,
                   inputTrace.sentNs != 0,
                   inputTrace.lastDrawLoggedSeq != inputTrace.seq
                {
                    let nowNs = zonvie_core_perf_now_ns()
                    let deltaUs = max(Int64(0), (nowNs - inputTrace.sentNs) / 1_000)
                    ZonvieCore.appLog("[perf_input] seq=\(inputTrace.seq) stage=draw_end delta_us=\(deltaUs) rowMode=\(rowMode) dirtyRows=\(dirtyRows.count)")
                    (view as? MetalTerminalView)?.core?.markInputTraceDrawLogged(seq: inputTrace.seq)
                }
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
            // Build bloom pipelines for neon glow
            buildBloomPipelines(lib: lib, vs: vs, vertexDesc: vertexDesc, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat)
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
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.alphaBlendOperation = .add
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

        // Build bloom pipelines for neon glow (always, glow check is at draw time)
        buildBloomPipelines(lib: lib, vs: vs, vertexDesc: vertexDesc, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat)

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
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.alphaBlendOperation = .add
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

    /// Build bloom pipelines for post-process neon glow.
    /// Called once during pipeline initialization and also from archive path.
    private func buildBloomPipelines(lib: MTLLibrary, vs: MTLFunction, vertexDesc: MTLVertexDescriptor, copyVertexDesc: MTLVertexDescriptor, pixelFormat: MTLPixelFormat) {
        guard let fsExtract = lib.makeFunction(name: "ps_glow_extract") else {
            ZonvieCore.appLog("WARNING: Missing ps_glow_extract shader (bloom disabled)")
            return
        }
        guard let fsKawaseDown = lib.makeFunction(name: "ps_kawase_down") else {
            ZonvieCore.appLog("WARNING: Missing ps_kawase_down shader (bloom disabled)")
            return
        }
        guard let fsKawaseUp = lib.makeFunction(name: "ps_kawase_up") else {
            ZonvieCore.appLog("WARNING: Missing ps_kawase_up shader (bloom disabled)")
            return
        }
        guard let fsComposite = lib.makeFunction(name: "ps_glow_composite") else {
            ZonvieCore.appLog("WARNING: Missing ps_glow_composite shader (bloom disabled)")
            return
        }
        guard let vsCopy = lib.makeFunction(name: "vs_copy") else {
            ZonvieCore.appLog("WARNING: Missing vs_copy shader for bloom (bloom disabled)")
            return
        }

        // Glow extract: same vertex layout as main, sourceAlpha blend, render to 1/4 res
        let extractDesc = MTLRenderPipelineDescriptor()
        extractDesc.vertexFunction = vs
        extractDesc.fragmentFunction = fsExtract
        extractDesc.vertexDescriptor = vertexDesc
        extractDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = extractDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        // Kawase down/up: fullscreen quad, no blending
        let kawaseDownDesc = MTLRenderPipelineDescriptor()
        kawaseDownDesc.vertexFunction = vsCopy
        kawaseDownDesc.fragmentFunction = fsKawaseDown
        kawaseDownDesc.vertexDescriptor = copyVertexDesc
        kawaseDownDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = kawaseDownDesc.colorAttachments[0] {
            a.isBlendingEnabled = false
        }

        let kawaseUpDesc = MTLRenderPipelineDescriptor()
        kawaseUpDesc.vertexFunction = vsCopy
        kawaseUpDesc.fragmentFunction = fsKawaseUp
        kawaseUpDesc.vertexDescriptor = copyVertexDesc
        kawaseUpDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = kawaseUpDesc.colorAttachments[0] {
            a.isBlendingEnabled = false
        }

        // Composite: additive blend (ONE, ONE)
        let compositeDesc = MTLRenderPipelineDescriptor()
        compositeDesc.vertexFunction = vsCopy
        compositeDesc.fragmentFunction = fsComposite
        compositeDesc.vertexDescriptor = copyVertexDesc
        compositeDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = compositeDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .one
        }

        do {
            glowExtractPipeline = try device.makeRenderPipelineState(descriptor: extractDesc)
            kawaseDownPipeline = try device.makeRenderPipelineState(descriptor: kawaseDownDesc)
            kawaseUpPipeline = try device.makeRenderPipelineState(descriptor: kawaseUpDesc)
            glowCompositePipeline = try device.makeRenderPipelineState(descriptor: compositeDesc)
            ZonvieCore.appLog("[Renderer] Bloom pipelines created successfully")
        } catch {
            ZonvieCore.appLog("[Renderer] ERROR: Failed to create bloom pipelines: \(error)")
        }

        // Bilinear sampler for blur passes
        if bilinearSampler == nil {
            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            samplerDesc.mipFilter = .notMipmapped
            samplerDesc.sAddressMode = .clampToEdge
            samplerDesc.tAddressMode = .clampToEdge
            bilinearSampler = device.makeSamplerState(descriptor: samplerDesc)
        }

        // Intensity buffer is now managed by SurfaceGlowTextures.ensureIntensityBuffer()
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
            a.sourceRGBBlendFactor = .sourceAlpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.alphaBlendOperation = .add
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

    // safeNeededBytes / growCapacity are provided by MetalTypes.swift as
    // surfaceSafeNeededBytes() / surfaceGrowCapacity().
    
    /// Ensure main vertex buffer in the specified buffer set has sufficient capacity.
    /// If the buffer is shared with the committed set (COW), detach by reusing
    /// the pool buffer saved in beginFlush, or allocate new if pool is insufficient.
    private func ensureMainBufferInSet(_ setIdx: Int, vertexCount: Int) {
        let vc = max(0, vertexCount)
        guard let needed = surfaceSafeNeededBytes(vertexCount: vc) else { return }

        let srcMain = bufferSets[flushSourceSetIndex].mainVertexBuffer
        let sharesSource = setIdx == writeSetIndex && srcMain != nil
            && bufferSets[setIdx].mainVertexBuffer === srcMain
        let needsNew = sharesSource
            || bufferSets[setIdx].mainVertexBuffer == nil
            || needed > bufferSets[setIdx].mainVertexBufferCap

        if needsNew {
            guard let nextCap = surfaceGrowCapacity(current: bufferSets[setIdx].mainVertexBufferCap, needed: max(1, needed)) else { return }

            // Try detach pool first.
            // Guard: pool buffer must not alias source, otherwise we'd
            // write into the committed frame.
            let bs = bufferSets[setIdx]
            if let poolBuf = bs.detachPoolMainBuffer,
               bs.detachPoolMainCap >= nextCap,
               poolBuf !== srcMain
            {
                bs.mainVertexBuffer = poolBuf
                bs.mainVertexBufferCap = bs.detachPoolMainCap
                bs.detachPoolMainBuffer = nil
            } else {
                bs.mainVertexBufferCap = nextCap
                bs.mainVertexBuffer = device.makeBuffer(length: nextCap, options: .storageModeShared)
                if bs.mainVertexBuffer == nil {
                    bs.mainVertexBufferCap = 0
                }
            }
        }
    }

    /// Ensure cursor vertex buffer in the specified buffer set has sufficient capacity.
    /// If the buffer is shared with the committed set (COW), detach by reusing
    /// the pool buffer saved in beginFlush, or allocate new if pool is insufficient.
    private func ensureCursorBufferInSet(_ setIdx: Int, vertexCount: Int) {
        let vc = max(0, vertexCount)
        guard let needed = surfaceSafeNeededBytes(vertexCount: vc) else { return }

        let srcCursor = bufferSets[flushSourceSetIndex].cursorVertexBuffer
        let sharesSource = setIdx == writeSetIndex && srcCursor != nil
            && bufferSets[setIdx].cursorVertexBuffer === srcCursor
        let needsNew = sharesSource
            || bufferSets[setIdx].cursorVertexBuffer == nil
            || needed > bufferSets[setIdx].cursorVertexBufferCap

        if needsNew {
            guard let nextCap = surfaceGrowCapacity(current: bufferSets[setIdx].cursorVertexBufferCap, needed: max(1, needed)) else { return }

            // Try detach pool first.
            // Guard: pool buffer must not alias source.
            let bs = bufferSets[setIdx]
            if let poolBuf = bs.detachPoolCursorBuffer,
               bs.detachPoolCursorCap >= nextCap,
               poolBuf !== srcCursor
            {
                bs.cursorVertexBuffer = poolBuf
                bs.cursorVertexBufferCap = bs.detachPoolCursorCap
                bs.detachPoolCursorBuffer = nil
            } else {
                bs.cursorVertexBufferCap = nextCap
                bs.cursorVertexBuffer = device.makeBuffer(length: nextCap, options: .storageModeShared)
                if bs.cursorVertexBuffer == nil {
                    bs.cursorVertexBufferCap = 0
                }
            }
        }
    }

    /// Ensure row storage arrays in the specified buffer set cover at least `row + 1` entries.
    private func ensureRowStorageInSet(_ setIdx: Int, _ row: Int) {
        ensureSurfaceRowStorage(bufferSet: bufferSets[setIdx], row, maxRowBuffers: maxRowBuffers)
    }

    private func prepareRowModeSetForWrite(_ setIdx: Int, totalRows: Int) {
        prepareSurfaceRowModeSetForWrite(bufferSet: bufferSets[setIdx], totalRows: totalRows)
    }

    private func ensureRowBufferInSet(_ setIdx: Int, row: Int, vertexCount: Int) -> MTLBuffer? {
        if setIdx == writeSetIndex {
            precondition(isInFlush, "write-set row buffer allocation is only valid during an active flush")
        }
        return ensureSurfaceRowBuffer(
            bufferSet: bufferSets[setIdx],
            sourceSet: bufferSets[flushSourceSetIndex],
            device: device,
            row: row,
            vertexCount: vertexCount,
            maxRowBuffers: maxRowBuffers
        )
    }

    private func canUseGpuMainRowScrollCopy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPresentedOnce && backBuffer != nil
    }

    private func remapMainRowSlots(
        setIdx: Int,
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int,
        totalRows: Int
    ) {
        remapSurfaceRowSlots(
            bufferSet: bufferSets[setIdx],
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            totalRows: totalRows,
            maxRowBuffers: maxRowBuffers
        )
    }

    private func cpuShiftMainRowBuffers(
        setIdx: Int,
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int,
        totalRows: Int,
        totalCols: Int
    ) {
        prepareRowModeSetForWrite(setIdx, totalRows: totalRows)
        remapMainRowSlots(setIdx: setIdx, rowStart: rowStart, rowEnd: rowEnd, rowsDelta: rowsDelta, totalRows: totalRows)

        let regionHeight = rowEnd - rowStart
        let shift = abs(rowsDelta)
        guard shift > 0, shift < regionHeight else { return }

        let drawableH: Float = {
            lock.lock()
            let h = committedDrawableH
            lock.unlock()
            return h > 0 ? Float(h) : Float(max(1, totalRows)) * max(1.0, cellHeightPx)
        }()
        let deltaY = Float(rowsDelta) * cellHeightPx / max(1.0, drawableH) * 2.0

        let srcSet = bufferSets[flushSourceSetIndex]
        for row in rowStart..<rowEnd {
            if row >= maxRowBuffers { break }
            ensureRowStorageInSet(setIdx, row)
        }

        if rowsDelta > 0 {
            for dstRow in rowStart..<(rowEnd - shift) {
                let srcRow = dstRow + shift
                guard srcRow < srcSet.rowLogicalToSlot.count else {
                    bufferSets[setIdx].rowState.counts[dstRow] = 0
                    continue
                }
                let srcSlot = srcSet.rowLogicalToSlot[srcRow]
                let dstSlot = bufferSets[setIdx].rowLogicalToSlot[dstRow]
                guard srcSlot >= 0, srcSlot < srcSet.rowState.counts.count else {
                    bufferSets[setIdx].rowState.counts[dstSlot] = 0
                    continue
                }
                let srcCount = srcSet.rowState.counts[srcSlot]
                guard srcCount > 0, srcSlot < srcSet.rowState.buffers.count, let srcBuffer = srcSet.rowState.buffers[srcSlot] else {
                    bufferSets[setIdx].rowState.counts[dstSlot] = 0
                    continue
                }
                guard let dstBuffer = ensureRowBufferInSet(setIdx, row: dstSlot, vertexCount: srcCount) else {
                    bufferSets[setIdx].rowState.counts[dstSlot] = 0
                    continue
                }
                let byteCount = srcCount * MemoryLayout<Vertex>.stride
                memcpy(dstBuffer.contents(), srcBuffer.contents(), byteCount)
                let verts = dstBuffer.contents().bindMemory(to: Vertex.self, capacity: srcCount)
                for i in 0..<srcCount {
                    verts[i].position.y += deltaY
                }
                bufferSets[setIdx].rowState.counts[dstSlot] = srcCount
                bufferSets[setIdx].rowSlotSourceRows[dstSlot] = dstRow
            }
            for vacatedRow in (rowEnd - shift)..<rowEnd {
                let slot = bufferSets[setIdx].rowLogicalToSlot[vacatedRow]
                ensureRowStorageInSet(setIdx, slot)
                bufferSets[setIdx].rowState.counts[slot] = 0
                bufferSets[setIdx].rowSlotSourceRows[slot] = vacatedRow
            }
        } else {
            for dstRow in stride(from: rowEnd - 1, through: rowStart + shift, by: -1) {
                let srcRow = dstRow - shift
                guard srcRow >= 0, srcRow < srcSet.rowLogicalToSlot.count else {
                    let dstSlot = bufferSets[setIdx].rowLogicalToSlot[dstRow]
                    bufferSets[setIdx].rowState.counts[dstSlot] = 0
                    continue
                }
                let srcSlot = srcSet.rowLogicalToSlot[srcRow]
                let dstSlot = bufferSets[setIdx].rowLogicalToSlot[dstRow]
                let srcCount = srcSet.rowState.counts[srcSlot]
                guard srcCount > 0, srcSlot < srcSet.rowState.buffers.count, let srcBuffer = srcSet.rowState.buffers[srcSlot] else {
                    bufferSets[setIdx].rowState.counts[dstSlot] = 0
                    continue
                }
                guard let dstBuffer = ensureRowBufferInSet(setIdx, row: dstSlot, vertexCount: srcCount) else {
                    bufferSets[setIdx].rowState.counts[dstSlot] = 0
                    continue
                }
                let byteCount = srcCount * MemoryLayout<Vertex>.stride
                memcpy(dstBuffer.contents(), srcBuffer.contents(), byteCount)
                let verts = dstBuffer.contents().bindMemory(to: Vertex.self, capacity: srcCount)
                for i in 0..<srcCount {
                    verts[i].position.y += deltaY
                }
                bufferSets[setIdx].rowState.counts[dstSlot] = srcCount
                bufferSets[setIdx].rowSlotSourceRows[dstSlot] = dstRow
            }
            for vacatedRow in rowStart..<(rowStart + shift) {
                let slot = bufferSets[setIdx].rowLogicalToSlot[vacatedRow]
                ensureRowStorageInSet(setIdx, slot)
                bufferSets[setIdx].rowState.counts[slot] = 0
                bufferSets[setIdx].rowSlotSourceRows[slot] = vacatedRow
            }
        }

        markDirtyRows(rowStart: rowStart, rowCount: rowEnd - rowStart)
    }

    private func ndcX(_ xPx: Float, drawableWidth: Float) -> Float {
        return (xPx / max(1.0, drawableWidth)) * 2.0 - 1.0
    }

    private func ndcY(_ yPx: Float, drawableHeight: Float) -> Float {
        return 1.0 - (yPx / max(1.0, drawableHeight)) * 2.0
    }

    private func appendBackgroundQuadVertices(
        _ out: inout [Vertex],
        x0: Float,
        y0: Float,
        x1: Float,
        y1: Float,
        drawableWidth: Float,
        drawableHeight: Float,
        bgRGB: UInt32
    ) {
        let r = Float((bgRGB >> 16) & 0xFF) / 255.0
        let g = Float((bgRGB >> 8) & 0xFF) / 255.0
        let b = Float(bgRGB & 0xFF) / 255.0
        let color = simd_float4(r, g, b, 1.0)
        let tl = Vertex(position: simd_float2(ndcX(x0, drawableWidth: drawableWidth), ndcY(y0, drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let tr = Vertex(position: simd_float2(ndcX(x1, drawableWidth: drawableWidth), ndcY(y0, drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let bl = Vertex(position: simd_float2(ndcX(x0, drawableWidth: drawableWidth), ndcY(y1, drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let br = Vertex(position: simd_float2(ndcX(x1, drawableWidth: drawableWidth), ndcY(y1, drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        out.append(contentsOf: [tl, bl, tr, tr, bl, br])
    }

    private func encodePendingMainRowScrollCopy(
        commandBuffer: MTLCommandBuffer,
        backTexture: MTLTexture,
        drawableWidthPx: Int,
        rowHeightPx: Int,
        scroll: SurfaceRowScroll,
        logEnabled: Bool
    ) -> (clearTopPx: Int, clearBottomPx: Int)? {
        let shift = abs(scroll.rowsDelta)
        let regionHeightRows = scroll.rowEnd - scroll.rowStart
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

        let t0 = logEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let origin = MTLOrigin(x: 0, y: srcY, z: 0)
        let size = MTLSize(width: drawableWidthPx, height: copyHeightPx, depth: 1)
        blit.copy(from: backTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                  to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                  to: backTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: dstY, z: 0))
        blit.endEncoding()
        if logEnabled {
            let us = (CFAbsoluteTimeGetCurrent() - t0) * 1_000_000
            let usStr = String(format: "%.1f", us)
            ZonvieCore.appLog("[perf] gpu_row_scroll_copy rows=\(regionHeightRows) shift=\(scroll.rowsDelta) us=\(usStr)")
        }

        if scroll.rowsDelta > 0 {
            return ((scroll.rowEnd - shift) * rowHeightPx, scroll.rowEnd * rowHeightPx)
        } else {
            return (scroll.rowStart * rowHeightPx, (scroll.rowStart + shift) * rowHeightPx)
        }
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
        var verts: [Vertex] = []
        verts.reserveCapacity(6)
        appendBackgroundQuadVertices(
            &verts,
            x0: 0,
            y0: Float(top),
            x1: drawableWidth,
            y1: Float(bottom),
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight,
            bgRGB: bgRGB
        )
        verts.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    func applyMainRowScrollRaw(rowStart: Int, rowEnd: Int, colStart: Int, colEnd: Int, rowsDelta: Int, totalRows: Int, totalCols: Int) {
        guard isInFlush else {
            ZonvieCore.appLog("[WARNING] applySurfaceRowScrollRaw called outside flush bracket")
            return
        }
        guard rowsDelta != 0 else { return }
        guard rowStart >= 0, rowEnd > rowStart else { return }
        guard colStart == 0, colEnd == totalCols else { return }

        let s = writeSetIndex
        if canUseGpuMainRowScrollCopy() {
            remapMainRowSlots(setIdx: s, rowStart: rowStart, rowEnd: rowEnd, rowsDelta: rowsDelta, totalRows: totalRows)
            bufferSets[s].pendingScroll = SurfaceRowScroll(
                rowStart: rowStart,
                rowEnd: rowEnd,
                colStart: colStart,
                colEnd: colEnd,
                rowsDelta: rowsDelta,
                totalRows: totalRows,
                totalCols: totalCols
            )
            // pendingScrollAccum is accumulated in commitFlush() (not here)
            // to ensure draw() never sees a delta ahead of committed vertex data.
        } else {
            bufferSets[s].pendingScroll = nil
            cpuShiftMainRowBuffers(
                setIdx: s,
                rowStart: rowStart,
                rowEnd: rowEnd,
                rowsDelta: rowsDelta,
                totalRows: totalRows,
                totalCols: totalCols
            )
            // CPU path: clear accumulated scroll since backbuffer was fully updated
            lock.lock()
            pendingScrollAccum = nil
            lock.unlock()
        }
    }

    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int = 0) {
        guard isInFlush else {
            ZonvieCore.appLog("[WARNING] submitVerticesRowRaw called outside flush bracket")
            return
        }
        // We currently assume Zig calls with rowCount == 1 (contract in Zig onFlush).
        guard rowCount > 0 else { return }

        submitSurfaceRowVertices(
            target: bufferSets[writeSetIndex],
            sourceSet: bufferSets[flushSourceSetIndex],
            device: device,
            rowStart: rowStart,
            ptr: UnsafeRawPointer(ptr),
            count: count,
            maxRowBuffers: maxRowBuffers,
            totalRows: totalRows
        )
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

        let bufCount = bufferSets[committedSetIndex].rowState.buffers.count
        let known = bufferSets[committedSetIndex].knownTotalRows
        let rowCount = known > 0 ? min(bufCount, known) : bufCount
        if rowCount > 0 {
            pendingDirtyRows.insert(integersIn: 0..<rowCount)
        }
        // Also clear the rect so full redraw happens
        pendingDirtyRectPx = nil
    }

}
