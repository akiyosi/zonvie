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
/// XPC shader compiler, so `GridSurfaceRenderer.ensurePipelineReady` builds
/// them lazily with a backoff, and external window creation queues behind it.
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
/// `endFlushTransaction`. A surface's `beginFlush`/`commitFlush` still call
/// them, so a flush is still gated on the main window committing first —
/// moving that gate to `ZonvieCore.on_flush_end` is its own step.
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
    /// shader firing off the cursor for that frame.
    private var staged: (rect: Rect, color: Color, gridId: Int64)?

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

    /// Whether the cursor a shader is drawing belongs to this grid. A surface
    /// asks before applying its own scroll displacement to the rect, so it does
    /// not displace a rect belonging to another grid.
    func belongs(toGrid grid: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gridId == grid
    }

    /// Stage the cursor state a flush just measured. Published by `publish()`
    /// when that flush commits — see `staged` for why it cannot go straight
    /// out. Called from the vertex-submit path (core/RPC thread) while a draw
    /// reads the published fields on the main thread.
    func stage(rect: Rect, color: Color, gridId grid: Int64) {
        lock.lock()
        staged = (rect: rect, color: color, gridId: grid)
        lock.unlock()
    }

    /// Drop a measurement whose flush never committed.
    func dropStaged() {
        lock.lock()
        staged = nil
        lock.unlock()
    }

    /// Hand the staged state to the shader uniforms, together with the vertices
    /// it describes. Called from every surface's commit.
    func publish() {
        lock.lock()
        defer { lock.unlock() }
        guard let s = staged else { return }
        staged = nil
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
        if let s = staged, s.gridId == grid {
            staged = (rect: rect, color: s.color, gridId: s.gridId)
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
    func evaluate(scrollOffsetPx: Float?) {
        guard let scrollOffsetPx else { return }
        lock.lock()
        defer { lock.unlock() }
        let rect = (rawRect.0, rawRect.1 + scrollOffsetPx, rawRect.2, rawRect.3)
        let color = rawColor
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
            return
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
    }
}
