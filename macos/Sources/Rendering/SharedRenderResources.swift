import Metal
import MetalKit
import QuartzCore

/// The GPU objects every surface in this app shares: one device, one set of
/// render pipelines, one sampler. A surface borrows them; none of them belongs
/// to a window.
///
/// Before this existed, an external surface reached them through
/// `mainTerminalView?.renderer`, so it could not draw unless the main window's
/// renderer object was alive — `ExternalGridView.draw` abandons the frame when
/// that reference is nil. Ownership lives here instead, which is what lets two
/// surfaces be peers rather than a host and its client.
///
/// **Construction is two-phase on purpose.** The device is available when the
/// first view is made, but the pipelines are deliberately NOT built until the
/// first draw: building several at once from separate instances trips Metal's
/// XPC shader compiler, so `ensurePipelineReady` below builds them lazily
/// with a backoff, and external window creation queues behind it.
/// Constructing this object eagerly at startup would not change that; it holds
/// the results, it does not schedule the work.
///
/// **Deliberately NOT here**, because they are per-surface rather than shared:
/// the command queue, the background-alpha buffer and the cursor-blink buffer.
/// Each external surface makes its own (see external window creation in
/// `ZonvieCore`), the alpha buffer carries an `isDecoratedSurface`-dependent
/// value, and a shared queue would serialise submission across surfaces.
///
/// The atlas upload transaction lives here too: `beginFlushTransaction` and
/// `endFlushTransaction`, opened and closed once per flush by
/// `ZonvieCore.on_flush_begin`/`on_flush_end`, whichever surfaces join it.
///
/// **Threading.** The pipelines are written once by whichever surface builds
/// them, on the thread that draws, and read by every surface's draw; every
/// macOS surface draws on the main thread, so they need no lock — the same
/// discipline they had as stored properties of the renderer. `linespace` is the
/// exception and carries `metricsLock`, which is a **leaf**: a surface may take
/// it while holding its own lock, and nothing under it calls back into a
/// surface. The atlas has locks of its own and documents them itself.
final class SharedRenderResources {
    let device: MTLDevice

    /// One glyph cache for every surface. It was the main renderer's private
    /// property, which is why an external surface had to reach through
    /// `mainTerminalView?.renderer` to sample it at all.
    let atlas: GlyphAtlas

    /// `linespace`, in drawable pixels. Global state — Neovim sends one value
    /// and `ZonvieCore.onLineSpace` applies it to one renderer — so it belongs
    /// beside the font metrics it adjusts rather than to a surface.
    private var linespacePx: Int32 = 0
    /// A **leaf** lock, in the sense of the lock rule: a surface may take it
    /// while holding its own, and nothing under it calls back into a surface.
    /// That is the point of moving `linespace` here. While it lived on the
    /// renderer under the renderer's lock, `cellHeightPx` could not be read
    /// inside a lock region on the same thread without deadlocking, and the
    /// call sites carried comments saying so.
    private let metricsLock = NSLock()

    func setLineSpace(px: Int32) {
        metricsLock.lock()
        linespacePx = px
        metricsLock.unlock()
    }

    func setBackingScale(_ s: CGFloat) {
        // Eagerly, so cellWidthPx/cellHeightPx reflect the new scale before the
        // next draw: the grid is sized from them, and sizing it with @1x
        // metrics against an @2x drawable is a visible wrong row count.
        atlas.setBackingScale(s)
    }

    /// The font the atlas is currently rasterizing with. Chrome that must match
    /// the grid's text (the IME candidate window, tab labels) asks for it.
    var currentFontName: String { atlas.currentFontName }
    var currentPointSize: CGFloat { atlas.currentPointSize }

    /// Cell width in drawable pixels.
    var cellWidthPx: Float { atlas.fontMetricsSnapshot().width }

    /// Cell height in drawable pixels, `linespace` included.
    ///
    /// `fontMetricsSnapshot()` reads all four font metrics together under the
    /// atlas's own lock (the core/RPC thread writes them there); `linespace` is
    /// a separate field under `metricsLock`. Two snapshots, but neither field
    /// can be internally torn.
    var cellHeightPx: Float {
        metricsLock.lock()
        let ls = linespacePx
        metricsLock.unlock()
        // `linespace` may be negative (Neovim allows it to tighten rows under a
        // font that reserves too much room), so the sum has to stay positive:
        // the grid divides the drawable by this to get its row count, and rows
        // cannot be measured in zero pixels.
        return max(1, atlas.fontMetricsSnapshot().height + Float(ls))
    }

    /// The grid pipeline and its sampler. `ensurePipelineReady` treats these
    /// two being non-nil as "ready"; everything below is optional extra.
    var pipeline: MTLRenderPipelineState?
    var sampler: MTLSamplerState?

    /// The 2-pass blur pair, and the single-pass replacement that supersedes it
    /// when the device supports raster order groups. Nil falls back to the pair.
    var backgroundPipeline: MTLRenderPipelineState?
    var glyphPipeline: MTLRenderPipelineState?
    var unifiedBlurPipeline: MTLRenderPipelineState?

    /// back buffer -> drawable, as a render pass rather than a blit: a blit's
    /// internal shader cannot be cached in an MTLBinaryArchive, and there is no
    /// XPC compiler service after fork().
    var copyPipeline: MTLRenderPipelineState?
    var copyVertexBuffer: MTLBuffer?

    /// The bloom chain: extract, the Dual Kawase down/up pair, the composite,
    /// the occlusion pass that keeps glow off covered rows, and the bilinear
    /// sampler every one of them reads with.
    var glowExtractPipeline: MTLRenderPipelineState?
    var kawaseDownPipeline: MTLRenderPipelineState?
    var kawaseUpPipeline: MTLRenderPipelineState?
    var glowCompositePipeline: MTLRenderPipelineState?
    var glowOccludePipeline: MTLRenderPipelineState?
    var bilinearSampler: MTLSamplerState?

    /// User post-process chains. Two of them: a decorated surface (cmdline,
    /// message panels, popupmenu) takes the opaque chain, every editor surface
    /// takes the main one. When the config names no separate decorated shader
    /// the two are identical and the second just aliases the first.
    /// The Shadertoy clock every surface measures `iTime` from, so a shader's
    /// phase matches across windows. This was the main window's own timing
    /// state, which every other surface then inherited from.
    let shaderTimeBase = SurfaceShaderTiming()

    /// The cursor a shader draws against — one, because there is one cursor.
    /// See `SurfaceShaderCursor` for why it stopped living on a surface.
    lazy var shaderCursor = SurfaceShaderCursor(timeBase: shaderTimeBase)

    var customShaderPipelines: [CustomShaderPipeline] = []
    var customShaderPipelinesDecorated: [CustomShaderPipeline] = []

    /// Which of the two a surface draws with. Asked of the object that owns
    /// both, so the surfaces differ by the argument rather than by shape: the
    /// main renderer used to name its chain directly and ExternalGridView had
    /// its own selector.
    func customShaderChain(decorated: Bool) -> [CustomShaderPipeline] {
        decorated ? customShaderPipelinesDecorated : customShaderPipelines
    }
    /// Where the user chain runs relative to bloom, and whether any shader in
    /// it animates (which keeps the draw loop alive). Both are properties of
    /// the loaded chain, so they belong with it.
    var customShaderPostProcess: ZonvieConfig.ShaderPostProcess = .afterBloom
    var anyCustomShaderNeedsAnimation: Bool = false

    /// Why the last pipeline build failed, for the draw that skips on it.
    private(set) var initializationError: String?
    private var pipelineNeedsBuilding = true
    private var pipelineRetryDelaySeconds: TimeInterval = 0.1
    private var pipelineRetryNotBefore: CFAbsoluteTime = 0
    /// The archive compiled pipelines are cached in, so later launches skip
    /// the XPC compiler service.
    private var binaryArchive: MTLBinaryArchive?
    /// Path to the binary archive file for caching pipeline states
    static var binaryArchivePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let zonvieDir = appSupport.appendingPathComponent("zonvie", isDirectory: true)
        try? FileManager.default.createDirectory(at: zonvieDir, withIntermediateDirectories: true)
        return zonvieDir.appendingPathComponent("pipeline_cache.metallib")
    }

    init(device: MTLDevice, atlas: GlyphAtlas) {
        self.device = device
        self.atlas = atlas
    }

    // MARK: - The atlas upload transaction

    /// What opening the transaction produced. All six were locals of the
    /// surface's `beginFlush`; they are results of the transaction, not state
    /// of any surface.
    struct FlushTransactionOpened {
        var needsCoreInvalidation = false
        var didCpuSync = false
        var syncedWasRecreate = false
        var didBlit = false
        var prepareUs: Double = 0
        var commitUs: Double = 0
    }

    enum FlushTransactionBegin {
        case opened(FlushTransactionOpened)
        /// The flush must be dropped. The caller owns tearing down its own
        /// bracket; the string says why, for its log line.
        case drop(String)
    }

    /// Open the atlas upload transaction for this flush: prepare the back
    /// texture and, when it was rebuilt, encode the blit that carries the old
    /// contents forward.
    ///
    /// **`queue` must be the queue the main surface draws on.** That is what
    /// lets the main surface sample the atlas with no reader admission: one
    /// queue already orders blit-before-sample by submission. Every other
    /// surface has its own queue and pays `beginExternalRead`, which encodes an
    /// explicit wait for the blit's completion event. Handing this a different
    /// queue would remove the main surface's guarantee silently, and the only
    /// symptom would be sampling a half-written atlas.
    func beginFlushTransaction(queue: MTLCommandQueue, perfEnabled: Bool) -> FlushTransactionBegin {
        var out = FlushTransactionOpened()

        // Phase 1: handle non-GPU cases (rebuild, CPU sync, no-op).
        // Phase 2: only create a Metal command buffer if a GPU blit is needed.
        // This avoids leaking IOAccelerator GPU memory regions from uncommitted
        // command buffers (observed: ~70 leaked regions/sec without this).
        let tPrepare = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let prepResult = atlas.prepareBackTexture()
        if perfEnabled {
            out.prepareUs = (CFAbsoluteTimeGetCurrent() - tPrepare) * 1_000_000
        }
        out.needsCoreInvalidation = prepResult.needsCoreInvalidation
        out.didCpuSync = prepResult.didCpuSync
        out.syncedWasRecreate = prepResult.syncedWasRecreate
        if prepResult.shouldAbort {
            return .drop("atlas prepare failed, dropping flush")
        }
        guard prepResult.needsGpuBlit else { return .opened(out) }

        // Commit the blit without waiting on the surface's own in-flight work:
        // waiting blocked the core thread (grid_mu held) on a full-texture
        // round-trip per flush under atlas-full churn. A later back-texture
        // consumer polls the command and retries if it is still in flight; no
        // redraw callback may wait for it while grid_mu is held.
        //
        // beginAtlasWrite()/endAtlasWrite() is a separate, much cheaper gate
        // against another surface's queue reading the texture this blit
        // overwrites, and returns immediately when no external read is
        // outstanding. Held across cmd.commit() (as on every exit path below)
        // so no new external read is admitted before submission.
        guard atlas.beginAtlasWrite() else {
            // Fail-closed (see beginAtlasWrite's doc comment): drop this
            // flush's atlas blit rather than mutate a texture an external read
            // has not finished with. atlas_reset/back-sync state is untouched,
            // so the next flush attempt retries it.
            atlas.endAtlasWrite()
            return .drop("atlas write blocked by in-flight external reads, dropping flush")
        }
        guard let cmd = queue.makeCommandBuffer() else {
            atlas.endAtlasWrite()
            atlas.cancelPendingBackTextureBlit()
            return .drop("commandBuffer creation failed for atlas blit, dropping flush")
        }
        guard atlas.encodeBackTextureBlit(commandBuffer: cmd) else {
            // cmd was already created (driver-side resources reserved at
            // creation, per the IOAccelerator leak note in CLAUDE.md); nothing
            // was encoded into it, but it must still be committed — an
            // uncommitted MTLCommandBuffer left to ARC deallocation does not
            // reliably release those resources, and this path can repeat on
            // every flush attempt while the driver stays under pressure.
            cmd.commit()
            atlas.endAtlasWrite()
            return .drop("atlas blit encode failed, dropping flush")
        }
        // Signal on this SAME command buffer, before commit, so the event only
        // reaches this generation once the GPU has actually finished the blit —
        // endAtlasWrite() below reopens the CPU-side admission gate immediately
        // (no waiting), but readers' beginAtlasExternalRead() wait-encode still
        // orders their GPU work strictly after this blit via the event,
        // independent of when endAtlasWrite() runs.
        let blitGen = atlas.encodeBlitCompletionSignal(into: cmd)
        // If the GPU stops executing this buffer before reaching the signal
        // command above (device loss, driver error), the event never reaches
        // blitGen and any reader already waiting on it would hang forever —
        // see recoverFailedBlit's doc comment.
        let atlasForBlitCompletion = atlas
        cmd.addCompletedHandler { completedCmd in
            if completedCmd.status != .completed {
                atlasForBlitCompletion.recoverFailedBlit(generation: blitGen)
            }
        }
        let tCommit = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        cmd.commit()
        atlas.endAtlasWrite()
        if perfEnabled {
            out.commitUs = (CFAbsoluteTimeGetCurrent() - tCommit) * 1_000_000
        }
        atlas.setPendingBackBlit(cmd)
        out.didBlit = true
        return .opened(out)
    }

    enum FlushTransactionClose {
        /// The atlas published. The texture is the front one this flush's UVs
        /// address, for the surface to freeze into its committed set.
        case published(texture: MTLTexture?)
        /// A reader or a prior blit is still active. Staging is preserved and
        /// the caller retries the frame without publishing its UVs. The string
        /// says which half deferred, for the caller's log line.
        case deferred(String)
    }

    // Shadertoy iDate cache: Calendar(identifier:) construction plus
    // dateComponents() ran every frame (up to 60Hz while an animated custom
    // shader is active) purely to fill a uniform that effects use at
    // wall-clock, not frame, granularity. Reuse the Calendar and recompute the
    // components at most once per second. Shared because it is a wall clock:
    // every surface would have computed the same value.
    private let shaderDateCalendar = Calendar(identifier: .gregorian)
    private var shaderDateCacheSecond: Int = -1
    private var shaderDateCache: (year: Float, month: Float, day: Float, secsInDay: Float) = (0, 0, 0, 0)

    /// line up seamlessly across ext-cmdline / ext-popupmenu / extra OS
    /// windows. `windowOffset` is the current view's top-left corner in
    /// the main window's drawable pixels (top-left origin); `windowSize`
    /// is the current view's own drawable size.
    ///
    /// Each caller passes the result inline via `setFragmentBytes`, so
    /// multiple MTKViews animating at 60fps never race on a shared
    /// buffer.
    func makeShaderUniforms(
        screenResolution: CGSize,
        windowOffset: CGPoint,
        windowSize: CGSize,
        backingScale: CGFloat,
        timing: SurfaceShaderTiming? = nil,
        lastLoggedCursor: inout (Float, Float, Float, Float)
    ) -> zonvie_shader_uniforms {
        let state = timing ?? shaderTimeBase
        let now = CACurrentMediaTime()
        if state.startTimeSec == 0 {
            // External views (timing != shaderTimeBase) inherit the
            // main view's iTime origin once main has started so iTime
            // and iTimeCursorChange (which the main path computes
            // against shaderTimeBase.startTimeSec) stay in the same
            // time base across the whole app.
            if state !== shaderTimeBase, shaderTimeBase.startTimeSec != 0 {
                state.startTimeSec = shaderTimeBase.startTimeSec
            } else {
                state.startTimeSec = now
            }
            state.lastTimeSec = now
        }
        let iTime = Float(now - state.startTimeSec)
        let dt = Float(max(0, now - state.lastTimeSec))
        state.lastTimeSec = now
        if dt > 0 {
            let instant = 1.0 / dt
            state.emaFrameRate = state.emaFrameRate * 0.9 + instant * 0.1
        }

        var uniforms = zonvie_shader_uniforms()
        uniforms.iResolution.0 = Float(screenResolution.width)
        uniforms.iResolution.1 = Float(screenResolution.height)
        uniforms.iResolution.2 = 1.0
        uniforms.iTime = iTime
        uniforms.iTimeDelta = dt
        uniforms.iFrame = state.frameIndex
        uniforms.iSampleRate = 44100.0
        uniforms.iFrameRate = state.emaFrameRate
        uniforms.iWindowOffset.0 = Float(windowOffset.x)
        uniforms.iWindowOffset.1 = Float(windowOffset.y)
        uniforms.iWindowSize.0 = Float(windowSize.width)
        uniforms.iWindowSize.1 = Float(windowSize.height)
        // Ghostty 1.1+ cursor uniforms. Taken as one snapshot: the submit
        // thread writes those fields as a unit, so reading them individually
        // could mix a new rect with a stale colour or timestamp for one frame.
        // Already in screen space — `evaluate` folded each endpoint's
        // displacement in when it accepted that endpoint.
        let cursor = shaderCursor.snapshot()
        let cursorCur = cursor.current
        // Log the value the shader actually receives, not the one some
        // upstream stage computed — the two came apart once already, when a
        // re-projected rect stayed in the staging slot. Emitted only when it
        // changes, so this stays off the per-frame cost.
        if ZonvieCore.appLogEnabled, cursorCur != lastLoggedCursor {
            lastLoggedCursor = cursorCur
            // `scale` is this window's, because the rect is in ITS drawable
            // pixels whatever grid published it — an external surface converts
            // into this space before forwarding. It rides on the rect rather
            // than on a resize line: resizeExternalWindows stopped carrying a
            // shared one when each window started converting with its own, and
            // the cmdline's window is skipped by that loop entirely.
            ZonvieCore.appLog(
                "[shader_cursor] x=\(cursorCur.0) y=\(cursorCur.1) w=\(cursorCur.2) h=\(cursorCur.3) grid=\(cursor.gridId) scale=\(backingScale)"
            )
        }
        uniforms.iCurrentCursor = cursorCur
        uniforms.iPreviousCursor = cursor.previous
        uniforms.iCurrentCursorColor = cursor.currentColor
        uniforms.iPreviousCursorColor = cursor.previousColor
        uniforms.iTimeCursorChange = cursor.changeTimeSec
        // Shadertoy iDate: (year, month [1..12], day, seconds-in-day).
        // Shadertoy's howto lists the fields as "Year, month, day,
        // time in seconds" without specifying month indexing. Forward
        // Calendar's .month component verbatim (already 1..12), which
        // matches the most common interpretation.
        // Recomputed at most once per wall-clock second (see
        // shaderDateCache doc above) -- effects using iDate don't need
        // finer than 1s granularity.
        let wallDate = Date()
        let wallSecond = Int(wallDate.timeIntervalSince1970)
        if wallSecond != shaderDateCacheSecond {
            shaderDateCacheSecond = wallSecond
            let comp = shaderDateCalendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .nanosecond],
                from: wallDate
            )
            let secsInDay: Float =
                Float(comp.hour ?? 0) * 3600.0 +
                Float(comp.minute ?? 0) * 60.0 +
                Float(comp.second ?? 0) +
                Float(comp.nanosecond ?? 0) / 1_000_000_000.0
            shaderDateCache = (Float(comp.year ?? 0), Float(comp.month ?? 1), Float(comp.day ?? 0), secsInDay)
        }
        uniforms.iDate.0 = shaderDateCache.year
        uniforms.iDate.1 = shaderDateCache.month
        uniforms.iDate.2 = shaderDateCache.day
        uniforms.iDate.3 = shaderDateCache.secsInDay
        // iMouse unimplemented on macOS — stays zero.

        state.frameIndex &+= 1
        return uniforms
    }

    /// The front texture this flush published, which every surface's committed
    /// vertices address. Written here, where the swap happens, and read by the
    /// surfaces as they commit — all on the core thread, inside the flush.
    ///
    /// ExternalGridView used to ask the MAIN renderer for its copy of this,
    /// which worked only because external surfaces commit after it.
    private(set) var committedAtlasTexture: MTLTexture?

    /// Close the transaction: publish this flush's staged CPU pixels, then swap
    /// the front texture the UVs address. Both halves, because a caller that
    /// did the first and skipped the second would publish UVs into a texture
    /// that had not been replaced.
    func endFlushTransaction() -> FlushTransactionClose {
        guard atlas.endFlushUploadTransaction() else {
            return .deferred("atlas upload writer unavailable")
        }
        let commit = atlas.commitAndSnapshotFrontTexture()
        guard commit.committed else {
            return .deferred("atlas back-sync still pending or failed")
        }
        committedAtlasTexture = commit.texture
        return .published(texture: commit.texture)
    }

    /// Register a read of the atlas from a queue other than the one the blit
    /// rides, snapshot what the caller needs, and encode a GPU wait for the
    /// latest blit — all as one step under the atlas's gate lock. Returns nil
    /// when a writer's intent blocks admission; the caller abandons the frame.
    ///
    /// Non-blocking, because every surface draws on the main thread.
    func beginExternalRead<T>(commandBuffer cmd: MTLCommandBuffer, snapshot: () -> T?) -> T? {
        atlas.beginExternalRead(commandBuffer: cmd, snapshot: snapshot)
    }

    /// Leave the reader group. Called from the completion handler of the
    /// command buffer whose render pass the matching `beginExternalRead`
    /// covered — never skipped, or the atlas's writer gate wedges.
    func endExternalRead() {
        atlas.endExternalRead()
    }

    /// Close the transaction of a bracket that will not publish.
    func abortFlushTransaction() {
        _ = atlas.endFlushUploadTransaction()
    }
}

/// Encode one row-scroll blit through a scratch texture, making the encoder on
/// first use.
///
/// The encoder is `inout` so a surface with several layers to move batches them
/// into ONE blit encoder — which is what GridSurfaceRenderer does across its
/// layer loop. ExternalGridView moves one region and ends the encoder straight
/// after; it passes a local that starts nil.
///
/// Returns false when the scratch texture or the encoder could not be made. The
/// caller then redraws those rows instead of moving them.
func encodeSurfaceRowScrollBlit(
    plan: RowScrollBlitPlan,
    backTexture: MTLTexture,
    scratch: SurfaceScrollScratchTexture,
    device: MTLDevice,
    backBufferSize: CGSize,
    commandBuffer: MTLCommandBuffer,
    encoder: inout MTLBlitCommandEncoder?
) -> Bool {
    if encoder == nil {
        scratch.ensure(
            device: device,
            drawableSize: backBufferSize,
            pixelFormat: backTexture.pixelFormat
        )
        encoder = commandBuffer.makeBlitCommandEncoder()
    }
    guard let blit = encoder, let scratchTexture = scratch.texture else { return false }
    encodeRowScrollBlit(blit, backTexture: backTexture, scratch: scratchTexture, plan: plan)
    return true
}

/// One surface's Shadertoy clock. Each surface counts its own frames, but they
/// all measure `iTime` from the same start so a shader's phase matches across
/// windows; `SharedRenderResources.shaderTimeBase` holds that start.
///
/// This was nested inside GridSurfaceRenderer, so ExternalGridView had to name
/// `GridSurfaceRenderer.ShaderViewTimingState` for a value that is not the main
/// window's.
final class SurfaceShaderTiming {
    var frameIndex: Int32 = 0
    var startTimeSec: CFTimeInterval = 0
    var lastTimeSec: CFTimeInterval = 0
    var emaFrameRate: Float = 60.0
    init() {}
}

/// The cursor a shader draws against: one across the main window and every
/// external one, because there is one cursor.
///
/// Held in SCREEN space — the smooth-scroll displacement already folded in —
/// because that is what a cursor shader draws against and what "the cursor
/// moved" has to mean. The rect the core measures is in vertex space, which
/// shifts by a whole row on every scroll step while the displacement cancels it
/// and the cursor stays put on the glass. Rotating on that would restart the
/// trail every step, so it never plays out.
///
/// This lived on GridSurfaceRenderer under that surface's lock, so every other
/// surface asked the main renderer for permission before touching it and
/// published through it — the last place an external surface reached into the
/// main one for something that is not the main window's own. It has its own
/// lock now, taken as a leaf: a surface may hold its own lock across a call
/// here, and nothing here calls back out.
final class SurfaceShaderCursor {
    typealias Rect = (Float, Float, Float, Float)
    typealias Color = (Float, Float, Float, Float)

    /// What the shader is handed, and where it came from.
    struct Snapshot {
        var current: Rect
        var previous: Rect
        var currentColor: Color
        var previousColor: Color
        var changeTimeSec: Float
        var gridId: Int64
    }

    private let lock = NSLock()
    /// Read inside this type's lock, but NOT protected by it: the time base is
    /// written by whichever surface draws first, once, as it goes from 0 to a
    /// fixed origin. A pre-existing unsynchronised transition, named here so
    /// the lock below is not read as covering it.
    private let timeBase: SurfaceShaderTiming

    /// Sub-pixel movement is not a cursor move; it is the ease sliding the
    /// cursor along. Rotating on it would restart the trail every frame.
    private static let moveEpsilonPx: Float = 0.5

    private var current: Rect = (0, 0, 0, 0)
    private var previous: Rect = (0, 0, 0, 0)
    private var currentColor: Color = (0, 0, 0, 0)
    private var previousColor: Color = (0, 0, 0, 0)
    private var changeTimeSec: Float = 0

    /// The rect as the core measured it, and the grid it belongs to. Turned
    /// into the screen-space state above by `evaluate`, once the frame's
    /// displacement for that grid is known.
    private var rawRect: Rect = (0, 0, 0, 0)
    private var rawColor: Color = (0, 0, 0, 0)
    private var gridId: Int64 = 0

    /// Cursor state measured during a flush, held until that flush commits.
    ///
    /// The rect describes the cursor vertices of the flush that measured it,
    /// and those only reach the screen at commit. Publishing at submit put the
    /// NEXT flush's cursor position into the uniforms while the screen still
    /// showed the previous one — a row apart mid-scroll, which is a cursor
    /// shader firing off the cursor for that frame. Only the staging surface's
    /// own commit publishes it: the main surface commits first when it joins
    /// a flush, and publishing an external window's cursor there paired it
    /// with that window's previous rows for any frame drawn before its commit.
    private var staged = SurfaceCommitStaged<(rect: Rect, color: Color, gridId: Int64)>()

    init(timeBase: SurfaceShaderTiming) {
        self.timeBase = timeBase
    }

    /// What the uniforms need, read in one critical section so a frame never
    /// sees a rect from one update beside a colour from another.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            current: current,
            previous: previous,
            currentColor: currentColor,
            previousColor: previousColor,
            changeTimeSec: changeTimeSec,
            gridId: gridId
        )
    }

    /// Stage the cursor state a flush just measured. Published by `publish()`
    /// when that flush commits — see `staged` for why it cannot go straight
    /// out. Called from the vertex-submit path (core/RPC thread) while a draw
    /// reads the published fields on the main thread.
    func stage(rect: Rect, color: Color, gridId grid: Int64, by surface: AnyObject) {
        lock.lock()
        staged.stage((rect: rect, color: color, gridId: grid), by: ObjectIdentifier(surface))
        lock.unlock()
    }

    /// What every surface's commit publishes last, in one order: the cursor
    /// rect this bracket measured, then the scroll compensation for the rows
    /// it landed, then the revision a draw settles against. Called under the
    /// surface's own lock, so a draw's settle-and-hold sees all three as one
    /// generation. The main surface used to release its compensation after
    /// its lock, and the external surface's was released by the main
    /// surface's commit.
    /// `bumpRevision` is false for a bracket that landed nothing: a new
    /// revision is a frame the surface cannot skip.
    func publishCommitTail(
        committedBy surface: AnyObject,
        publishScrollClears: () -> Void,
        commitRevision: inout UInt64,
        bumpRevision: Bool = true
    ) {
        publish(committedBy: surface)
        publishScrollClears()
        if bumpRevision { commitRevision &+= 1 }
    }

    /// Drop a measurement whose flush never committed.
    func dropStaged() {
        lock.lock()
        staged.drop()
        lock.unlock()
    }

    /// Hand the staged state to the shader uniforms, together with the vertices
    /// it describes. Called from every surface's commit.
    func publish(committedBy surface: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        guard let s = staged.take(committedBy: ObjectIdentifier(surface)) else { return }
        rawRect = s.rect
        rawColor = s.color
        gridId = s.gridId
    }

    /// Re-anchor after the WINDOW that owns the cursor moved.
    ///
    /// Writes through rather than staging: `stage` only reaches the uniforms at
    /// a commit, and a window drag produces none, so the shader would keep
    /// burning at the pre-move position.
    ///
    /// Translates rather than replaces: the cursor did not move relative to its
    /// text, so rotating previous/current would fire the cursor-move animation
    /// and drag a trail from where the window used to be. Both endpoints shift
    /// by the same delta and the change time is left alone.
    ///
    /// Ignored unless `grid` still owns the cursor, so a window that no longer
    /// has it cannot hijack it by being dragged.
    func reanchor(rect: Rect, gridId grid: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard gridId == grid else { return }
        let dx = rect.0 - rawRect.0
        let dy = rect.1 - rawRect.1
        guard dx != 0 || dy != 0 else { return }
        rawRect = rect
        current = (current.0 + dx, current.1 + dy, current.2, current.3)
        previous = (previous.0 + dx, previous.1 + dy, previous.2, previous.3)
        // A cursor update that arrived during the drag is still waiting for a
        // commit; move it too, or the commit would undo this re-anchor.
        staged.update { s in
            if s.gridId == grid { s.rect = rect }
        }
    }

    /// Fold this frame's displacement of the cursor's grid into the endpoints,
    /// rotating them only when the cursor actually moved ON SCREEN.
    ///
    /// Called from each surface's pre-draw, where the displacement it is about
    /// to render with is known. The measured rect alone cannot answer "did the
    /// cursor move": a scroll step shifts it a whole row while the compensating
    /// offset holds it still on the glass, and rotating there restarts the trail
    /// every step so it never plays out.
    ///
    /// - Parameter scrollOffsetPx: displacement of the cursor's grid for this
    ///   frame, or nil when the caller does not own that grid's cursor.
    /// Returns true when the endpoints moved, so the caller's draw gate can
    /// treat it as work: the rect is a whole-surface fragment input.
    /// The measured rect as one value, for a surface that must evaluate the
    /// cursor the frame it snapshotted draws. A surface takes it under its own
    /// lock beside its committed set, so a commit landing later in the frame
    /// (which publishes a newer rect here) cannot reach that frame's uniforms.
    struct Raw {
        var rect: Rect
        var color: Color
        var gridId: Int64
    }

    func rawSnapshot() -> Raw {
        lock.lock()
        defer { lock.unlock() }
        return Raw(rect: rawRect, color: rawColor, gridId: gridId)
    }

    @discardableResult
    func evaluate(scrollOffsetPx: Float?, raw: Raw? = nil) -> Bool {
        guard let scrollOffsetPx else { return false }
        lock.lock()
        defer { lock.unlock() }
        let base = raw ?? Raw(rect: rawRect, color: rawColor, gridId: gridId)
        let rect = (base.rect.0, base.rect.1 + scrollOffsetPx, base.rect.2, base.rect.3)
        let color = base.color
        let eps = Self.moveEpsilonPx
        let sameRect =
            abs(rect.0 - current.0) < eps &&
            abs(rect.1 - current.1) < eps &&
            abs(rect.2 - current.2) < eps &&
            abs(rect.3 - current.3) < eps
        let sameColor =
            color.0 == currentColor.0 &&
            color.1 == currentColor.1 &&
            color.2 == currentColor.2 &&
            color.3 == currentColor.3
        if sameRect && sameColor {
            // Keep the endpoint exact even when the move was below the
            // threshold, so a slow ease does not accumulate drift.
            current = rect
            return false
        }

        previous = current
        previousColor = currentColor
        current = rect
        currentColor = color
        // Reported in the same time base as every surface's iTime, which is why
        // that base is shared rather than the main window's.
        changeTimeSec = timeBase.startTimeSec != 0
            ? Float(CACurrentMediaTime() - timeBase.startTimeSec)
            : 0
        return true
    }
}

// MARK: - Pipeline construction

/// Building the shared pipelines. This was `GridSurfaceRenderer`'s, which
/// meant only the main surface could build what every surface draws with:
/// an external surface that found `pipeline == nil` could only bail and wait
/// for the main window's next draw. The build is lazy with a backoff (see
/// `ensurePipelineReady`) because building several pipelines at once from
/// separate instances trips Metal's XPC shader compiler; that policy moved
/// with it. The stored state is the one piece of mutable state here that a
/// surface's draw writes, and it is written from the drawing thread only.
extension SharedRenderResources {
    /// Compile the configured custom shaders. Run twice — once for the surface
    /// set and once for the decorated variant, which is always opaque — and
    /// only `preserveAlpha` differs between them.
    private func loadCustomShaders(
        _ paths: [String],
        lib: MTLLibrary,
        vsCustomPost: MTLFunction,
        copyVertexDesc: MTLVertexDescriptor,
        pixelFormat: MTLPixelFormat,
        preserveAlpha: Bool
    ) -> [CustomShaderPipeline] {
        var out: [CustomShaderPipeline] = []
        for path in paths {
            if let loaded = CustomShaderPipeline.load(
                device: device,
                library: lib,
                vsCustomPost: vsCustomPost,
                copyVertexDescriptor: copyVertexDesc,
                sourcePath: (path as NSString).expandingTildeInPath,
                pixelFormat: pixelFormat,
                preserveAlpha: preserveAlpha
            ) {
                out.append(loaded)
            }
        }
        return out
    }

    /// The blend every glyph-drawing pipeline uses: straight `over`, leaving
    /// the destination's own alpha. Three pipelines set it — the main one on
    /// each of the two creation paths, and the 2-pass glyph pass — and they
    /// have to agree, because they draw the same vertices into the same
    /// texture. The other blends in this file are deliberately different modes.
    private static func applyGlyphOverBlend(_ a: MTLRenderPipelineColorAttachmentDescriptor) {
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.sourceRGBBlendFactor = .sourceAlpha
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.alphaBlendOperation = .add
        a.sourceAlphaBlendFactor = .one
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    /// The main glyph pipeline. Built on both creation paths — through the XPC
    /// compiler and from the binary archive — and blending is on so glyph
    /// coverage composites over the background it is drawn onto.
    private static func makeGlyphPipelineDescriptor(
        vs: MTLFunction?,
        fs: MTLFunction?,
        vertexDescriptor: MTLVertexDescriptor,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vs
        d.fragmentFunction = fs
        d.vertexDescriptor = vertexDescriptor
        d.colorAttachments[0].pixelFormat = pixelFormat
        if let a = d.colorAttachments[0] { applyGlyphOverBlend(a) }
        return d
    }

    /// The copy pipeline (what replaced the blit). Built on both creation
    /// paths — through the XPC compiler and from the binary archive — and it
    /// never blends: it overwrites.
    private static func makeCopyPipelineDescriptor(
        vsCopy: MTLFunction?,
        fsCopy: MTLFunction?,
        vertexDescriptor: MTLVertexDescriptor,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vsCopy
        d.fragmentFunction = fsCopy
        d.vertexDescriptor = vertexDescriptor
        d.colorAttachments[0].pixelFormat = pixelFormat
        d.colorAttachments[0]?.isBlendingEnabled = false
        return d
    }

    /// Ensure pipeline is ready for use by external grid views.
    /// Called before creating ExternalGridView to guarantee shared pipeline availability.
    /// This builds the pipeline synchronously if not already done.
    @discardableResult
    func ensurePipelineReady(view: MTKView) -> Bool {
        if pipeline != nil && sampler != nil {
            pipelineRetryDelaySeconds = 0.1
            pipelineRetryNotBefore = 0
            return true
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard pipelineNeedsBuilding, now >= pipelineRetryNotBefore else { return false }

        pipelineNeedsBuilding = false
        if sampler == nil { buildSampler() }
        buildPipeline(view: view)
        if pipeline != nil && sampler != nil {
            initializationError = nil
            pipelineRetryDelaySeconds = 0.1
            pipelineRetryNotBefore = 0
            ZonvieCore.appLog("[Renderer] Pipeline built on demand")
            return true
        }

        // Shader compiler/XPC failures can be transient. Keep the renderer
        // retryable, but cap attempts so a permanent failure cannot spin the
        // draw loop or external-window lifecycle at 10 Hz.
        let retryDelay = pipelineRetryDelaySeconds
        pipelineNeedsBuilding = true
        pipelineRetryNotBefore = now + retryDelay
        pipelineRetryDelaySeconds = min(pipelineRetryDelaySeconds * 2, 5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self, weak view] in
            guard let self, let view,
                  self.pipeline == nil,
                  CFAbsoluteTimeGetCurrent() >= self.pipelineRetryNotBefore else { return }
            if let terminalView = view as? MetalTerminalView {
                terminalView.requestRedraw()
            } else {
                view.setNeedsDisplay(view.bounds)
            }
        }
        return false
    }

    func pipelineRetryDelay() -> TimeInterval {
        max(0.1, pipelineRetryNotBefore - CFAbsoluteTimeGetCurrent())
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
        let blurEnabled = ZonvieConfig.shared.blurEnabled

        // Try to load from binary archive first (avoids XPC compiler service)
        if loadPipelineFromArchive(lib: lib, vs: vs, fs: fs, vsCopy: vsCopy, fsCopy: fsCopy, vertexDesc: vertexDesc, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat) {
            ZonvieCore.appLog("[Renderer] Pipeline loaded from binary archive")
            // Build 2-pass pipelines for blur support (also from archive)
            if blurEnabled {
                _ = build2PassPipelinesAndGetDescriptors(lib: lib, vs: vs, vertexDesc: vertexDesc, pixelFormat: pixelFormat)
            }
            // Build bloom pipelines for neon glow
            buildBloomPipelines(lib: lib, vs: vs, vertexDesc: vertexDesc, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat)
            buildCustomShaderPipelines(lib: lib, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat)
            buildCopyVertexBuffer()
            return
        }

        // Binary archive miss - need to compile pipeline
        ZonvieCore.appLog("[Renderer] Binary archive miss, compiling pipeline...")

        let desc = Self.makeGlyphPipelineDescriptor(
            vs: vs, fs: fs, vertexDescriptor: vertexDesc, pixelFormat: pixelFormat
        )

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
        let copyDesc = Self.makeCopyPipelineDescriptor(
            vsCopy: vsCopy, fsCopy: fsCopy,
            vertexDescriptor: copyVertexDesc, pixelFormat: pixelFormat
        )

        do {
            copyPipeline = try device.makeRenderPipelineState(descriptor: copyDesc)
            ZonvieCore.appLog("[Renderer] Copy pipeline created successfully!")
        } catch {
            ZonvieCore.appLog("[Renderer] ERROR: Failed to make copy pipeline: \(error)")
            // Non-fatal: we can still render, just might have issues
        }

        buildCopyVertexBuffer()

        // Build 2-pass pipelines for blur support
        var bgDesc: MTLRenderPipelineDescriptor? = nil
        var glyphDesc: MTLRenderPipelineDescriptor? = nil
        if blurEnabled {
            (bgDesc, glyphDesc) = build2PassPipelinesAndGetDescriptors(lib: lib, vs: vs, vertexDesc: vertexDesc, pixelFormat: pixelFormat)
        }

        // Build bloom pipelines for neon glow (always, glow check is at draw time)
        buildBloomPipelines(lib: lib, vs: vs, vertexDesc: vertexDesc, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat)
        buildCustomShaderPipelines(lib: lib, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat)

        // Cache all pipelines to binary archive for future use
        cacheToArchive(mainDesc: desc, bgDesc: bgDesc, glyphDesc: glyphDesc, copyDesc: copyDesc)
    }

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
            Self.applyGlyphOverBlend(a)
        }

        do {
            backgroundPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
            glyphPipeline = try device.makeRenderPipelineState(descriptor: glyphDesc)
            ZonvieCore.appLog("[Renderer] 2-pass pipelines created for blur support")
        } catch {
            ZonvieCore.appLog("[Renderer] ERROR: Failed to make 2-pass pipeline states: \(error)")
            return (nil, nil)
        }

        // Unified single-pass pipeline that supersedes 2-pass when available.
        // Pipeline blend disabled — ps_unified_blur reads tile via
        // raster_order_group and writes the final composited pixel directly.
        if let fsUnified = lib.makeFunction(name: "ps_unified_blur") {
            let uDesc = MTLRenderPipelineDescriptor()
            uDesc.vertexFunction = vs
            uDesc.fragmentFunction = fsUnified
            uDesc.vertexDescriptor = vertexDesc
            uDesc.colorAttachments[0].pixelFormat = pixelFormat
            if let a = uDesc.colorAttachments[0] {
                a.isBlendingEnabled = false  // shader does manual alpha blend via tile read
            }
            do {
                unifiedBlurPipeline = try device.makeRenderPipelineState(descriptor: uDesc)
                ZonvieCore.appLog("[Renderer] unified blur pipeline created (1-pass programmable blending)")
            } catch {
                ZonvieCore.appLog("[Renderer] WARNING: unified blur pipeline build failed; 2-pass fallback in use: \(error)")
                unifiedBlurPipeline = nil
            }
        } else {
            ZonvieCore.appLog("[Renderer] WARNING: ps_unified_blur shader not found; 2-pass fallback in use")
        }

        return (bgDesc, glyphDesc)
    }

    /// Build bloom pipelines for post-process neon glow.
    /// Called once during pipeline initialization and also from archive path.
    private func buildBloomPipelines(lib: MTLLibrary, vs: MTLFunction, vertexDesc: MTLVertexDescriptor, copyVertexDesc: MTLVertexDescriptor, pixelFormat: MTLPixelFormat) {
        guard let fsExtract = lib.makeFunction(name: "ps_glow_extract") else {
            ZonvieCore.appLog("WARNING: Missing ps_glow_extract shader (bloom disabled)")
            return
        }
        guard let fsOcclude = lib.makeFunction(name: "ps_glow_occlude") else {
            ZonvieCore.appLog("WARNING: Missing ps_glow_occlude shader (bloom disabled)")
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

        // Glow occlude: same vertex layout as extract, and the destination is
        // scaled by the background's alpha instead of adding to it.
        let occludeDesc = MTLRenderPipelineDescriptor()
        occludeDesc.vertexFunction = vs
        occludeDesc.fragmentFunction = fsOcclude
        occludeDesc.vertexDescriptor = vertexDesc
        occludeDesc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = occludeDesc.colorAttachments[0] {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .zero
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .zero
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
            glowOccludePipeline = try device.makeRenderPipelineState(descriptor: occludeDesc)
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

    /// Ghostty 1.1+ cursor uniform update. rect is (x, y, w, h) in
    /// drawable pixels within the shader "screen" universe (main
    /// window's drawable). color is straight RGBA in [0, 1]. No-op
    /// when incoming state matches the current state, so shaders keep
    /// seeing the last real change's iTimeCursorChange.
    /// Load user-supplied custom post-process shaders listed in config.toml's
    /// `[shaders].paths`, cross-compile them to MSL, and create one pipeline
    /// state per entry. Called once alongside the bloom-pipeline construction.
    private func buildCustomShaderPipelines(
        lib: MTLLibrary,
        copyVertexDesc: MTLVertexDescriptor,
        pixelFormat: MTLPixelFormat
    ) {
        let config = ZonvieConfig.shared.shaders
        customShaderPostProcess = config.postProcess
        customShaderPipelines.removeAll()
        customShaderPipelinesDecorated.removeAll()
        anyCustomShaderNeedsAnimation = false
        if !config.enabled || config.paths.isEmpty {
            return
        }
        guard let vsCustomPost = lib.makeFunction(name: "vs_custom_post") else {
            ZonvieCore.appLog("[Renderer] WARNING: Missing vs_custom_post shader (custom shaders disabled)")
            return
        }
        for loaded in loadCustomShaders(
            config.paths, lib: lib, vsCustomPost: vsCustomPost,
            copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat,
            preserveAlpha: config.preserveAlpha
        ) {
            customShaderPipelines.append(loaded)
            if loaded.needsAnimation { anyCustomShaderNeedsAnimation = true }
        }
        // Decorated variant: always opaque (preserve_alpha OFF). Only a
        // separate compile is needed when the main set is NOT already opaque;
        // otherwise alias it to avoid a redundant compile.
        if config.preserveAlpha {
            customShaderPipelinesDecorated = loadCustomShaders(
                config.paths, lib: lib, vsCustomPost: vsCustomPost,
                copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat,
                preserveAlpha: false
            )
        } else {
            customShaderPipelinesDecorated = customShaderPipelines
        }
        ZonvieCore.appLog("[Renderer] Loaded \(customShaderPipelines.count)/\(config.paths.count) custom shaders (decorated=\(customShaderPipelinesDecorated.count)), anyNeedsAnimation=\(anyCustomShaderNeedsAnimation)")
    }

    private func loadPipelineFromArchive(lib: MTLLibrary, vs: MTLFunction, fs: MTLFunction, vsCopy: MTLFunction, fsCopy: MTLFunction, vertexDesc: MTLVertexDescriptor, copyVertexDesc: MTLVertexDescriptor, pixelFormat: MTLPixelFormat) -> Bool {
        let archivePath = Self.binaryArchivePath
        ZonvieCore.appLog("[Renderer] loadPipelineFromArchive: checking \(archivePath.path)")

        guard FileManager.default.fileExists(atPath: archivePath.path) else {
            ZonvieCore.appLog("[Renderer] loadPipelineFromArchive: archive NOT FOUND")
            return false
        }
        ZonvieCore.appLog("[Renderer] loadPipelineFromArchive: archive EXISTS, loading...")

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
        let desc = Self.makeGlyphPipelineDescriptor(
            vs: vs, fs: fs, vertexDescriptor: vertexDesc, pixelFormat: pixelFormat
        )

        let copyDesc = Self.makeCopyPipelineDescriptor(
            vsCopy: vsCopy, fsCopy: fsCopy,
            vertexDescriptor: copyVertexDesc, pixelFormat: pixelFormat
        )

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

    func buildSampler() {
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
}
