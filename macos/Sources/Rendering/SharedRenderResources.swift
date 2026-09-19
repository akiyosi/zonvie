import Metal
import MetalKit

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
    var customShaderPipelines: [CustomShaderPipeline] = []
    var customShaderPipelinesDecorated: [CustomShaderPipeline] = []
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
