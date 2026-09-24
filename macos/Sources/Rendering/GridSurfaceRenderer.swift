import AppKit
import Metal
import MetalKit
import simd

private let metalTerminalMaxRowBuffers = 20_000

// MARK: - Surface Render Helpers Shared With ExternalGridView
//
// File-scope because both surfaces call them and neither owns them. They live
// here rather than in MetalTypes.swift because they reach ZonvieCore's logging
// and the shader C ABI, and MetalTypes.swift is compiled standalone by the
// `zig build test` Swift targets, which have neither.

/// Ask the core for the bloom chain's geometry and carry it into the shape
/// MetalTypes.swift can hold. That file is compiled on its own by `zig build
/// test`, so the translation has to happen somewhere that can see the C ABI.
func surfaceGlowChain(surfaceWidthPx: Int, surfaceHeightPx: Int, radiusScale: Float) -> SurfaceGlowChain {
    var c = zonvie_glow_chain()
    zonvie_core_glow_chain_plan(UInt32(max(0, surfaceWidthPx)), UInt32(max(0, surfaceHeightPx)), radiusScale, &c)
    // The plan fills both arrays and says how many entries are the ladder; drop
    // the padding here so the encoder just walks what it is given.
    let levels = min(Int(c.level_count), SurfaceGlowChain.mipCount)
    func passes(_ tuple: (zonvie_glow_pass, zonvie_glow_pass, zonvie_glow_pass)) -> [SurfaceGlowChain.Pass] {
        [tuple.0, tuple.1, tuple.2].prefix(levels).map {
            .init(src: Int($0.src), dst: Int($0.dst),
                  dstWidthPx: Int($0.dst_w_px), dstHeightPx: Int($0.dst_h_px))
        }
    }
    return .init(
        halfWidthPx: Int(c.half_w_px),
        halfHeightPx: Int(c.half_h_px),
        mipWidthPx: [Int(c.mip_w_px.0), Int(c.mip_w_px.1), Int(c.mip_w_px.2)],
        mipHeightPx: [Int(c.mip_h_px.0), Int(c.mip_h_px.1), Int(c.mip_h_px.2)],
        down: passes(c.down),
        up: passes(c.up)
    )
}

extension RowScrollBlitPlan {
    /// Ask the core where this scroll's blit reads and writes. Nil means no
    /// blit is worth encoding and the caller redraws the region instead.
    ///
    /// The arithmetic is `src/core/row_scroll.zig`, which the Windows frontend
    /// calls as Zig; this is the same answer through the C ABI. The Swift
    /// struct stays a separate shape so the draw code keeps reading
    /// `dirtyRows` as a Range.
    static func make(
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int,
        originXPx: Int = 0,
        originYPx: Int = 0,
        widthPx: Int,
        textureWidthPx: Int,
        textureHeightPx: Int,
        rowHeightPx: Int
    ) -> RowScrollBlitPlan? {
        var c = zonvie_row_scroll_plan()
        guard zonvie_core_row_scroll_plan_make(
            UInt32(max(0, rowStart)),
            UInt32(max(0, rowEnd)),
            Int32(clamping: rowsDelta),
            Int32(clamping: originXPx),
            Int32(clamping: originYPx),
            Int32(clamping: widthPx),
            Int32(clamping: textureWidthPx),
            Int32(clamping: textureHeightPx),
            Int32(clamping: rowHeightPx),
            &c
        ) else { return nil }
        return RowScrollBlitPlan(
            srcYPx: Int(c.src_y_px),
            dstYPx: Int(c.dst_y_px),
            copyWidthPx: Int(c.copy_w_px),
            copyHeightPx: Int(c.copy_h_px),
            clearTopPx: Int(c.clear_top_px),
            clearBottomPx: Int(c.clear_bottom_px),
            clampedRowEnd: Int(c.clamped_row_end),
            dirtyRows: Int(c.dirty_row_start)..<Int(c.dirty_row_end),
            originXPx: Int(c.origin_x_px),
            originYPx: Int(c.origin_y_px)
        )
    }

    /// The rows to redraw when the blit never ran. Nil when nothing of the
    /// region is inside the texture.
    static func dirtyRowsWithoutBlit(
        rowStart: Int,
        rowEnd: Int,
        originYPx: Int = 0,
        textureHeightPx: Int,
        rowHeightPx: Int
    ) -> Range<Int>? {
        var start: UInt32 = 0
        var end: UInt32 = 0
        guard zonvie_core_row_scroll_dirty_rows_without_blit(
            UInt32(max(0, rowStart)),
            UInt32(max(0, rowEnd)),
            Int32(clamping: originYPx),
            Int32(clamping: textureHeightPx),
            Int32(clamping: rowHeightPx),
            &start,
            &end
        ) else { return nil }
        return Int(start)..<Int(end)
    }

    /// The plan in the core's own shape, for the calls that take one back.
    var cValue: zonvie_row_scroll_plan {
        zonvie_row_scroll_plan(
            origin_x_px: Int32(clamping: originXPx),
            origin_y_px: Int32(clamping: originYPx),
            src_y_px: Int32(clamping: srcYPx),
            dst_y_px: Int32(clamping: dstYPx),
            copy_w_px: Int32(clamping: copyWidthPx),
            copy_h_px: Int32(clamping: copyHeightPx),
            clear_top_px: Int32(clamping: clearTopPx),
            clear_bottom_px: Int32(clamping: clearBottomPx),
            clamped_row_end: UInt32(clamping: clampedRowEnd),
            dirty_row_start: UInt32(clamping: dirtyRows.lowerBound),
            dirty_row_end: UInt32(clamping: dirtyRows.upperBound)
        )
    }
}

/// Which of a layer's own rows a full-width damage band overpaints, inclusive.
/// The arithmetic is `src/core/row_scroll.zig`, which the Windows driver calls
/// as Zig; this is the same answer through the C ABI.
func layerRowsUnderBand(
    bandTopPx: Int,
    bandBottomPx: Int,
    layer: SurfaceLayer,
    rowHeightPx: Int
) -> ClosedRange<Int>? {
    var firstRow: UInt32 = 0
    var lastRow: UInt32 = 0
    guard zonvie_core_band_layer_rows(
        Int32(clamping: bandTopPx),
        Int32(clamping: bandBottomPx),
        Int32(clamping: Int(layer.originPx.y.rounded(.down))),
        UInt32(clamping: layer.rows),
        Int32(clamping: rowHeightPx),
        &firstRow,
        &lastRow
    ) else { return nil }
    return Int(firstRow)...Int(lastRow)
}

/// Record what a row callback found missing, so the provisioner can supply it
/// after the bracket closes. Returns false when the row cannot be written this
/// flush; the caller owns `flushFailed`, which is the only part of this
/// decision that is not shared.
///
/// `lockHeld` is for the call sites that already hold the surface's lock. The
/// main surface has none and passes false; an external surface has several.
func requireSurfaceRowCapacity(
    bufferSets: [SurfaceBufferSet],
    ledger: SurfaceRowCapacityLedger,
    lock: NSLock,
    lockHeld: Bool,
    row: Int,
    vertexCount: Int,
    totalRows: Int,
    maxRowBuffers: Int,
    mappingSetIndex: Int,
    rowIsPhysical: Bool,
    logLabel: String
) -> Bool {
    switch surfaceRowCapacityVerdict(
        bufferSets: bufferSets,
        row: row,
        vertexCount: vertexCount,
        totalRows: totalRows,
        maxRowBuffers: maxRowBuffers,
        mappingSetIndex: mappingSetIndex,
        rowIsPhysical: rowIsPhysical
    ) {
    case .ready:
        return true

    case .invalid:
        return false

    case .needsProvisioning(let capacityRow, let requiredRows, let neededVertexCount):
        if !lockHeld { lock.lock() }
        ledger.requiredRows = max(ledger.requiredRows, requiredRows)
        ledger.requiredVertexCounts[capacityRow] = max(
            ledger.requiredVertexCounts[capacityRow],
            neededVertexCount
        )
        let newRequiredRows = ledger.requiredRows
        if !lockHeld { lock.unlock() }
        ZonvieCore.appLogScrollMode(
            "[scroll_debug] row_capacity_required surface=\(logLabel) row=\(row) " +
            "capacityRow=\(capacityRow) vertexCount=\(vertexCount) " +
            "totalRows=\(totalRows) requiredRowsNow=\(newRequiredRows)"
        )
        return false
    }
}

/// Provision the row capacity `ledger` owes, outside any flush bracket.
///
/// `isBusyLocked` is evaluated while the lock is held and reports whatever else
/// the surface has in flight; the two surfaces track their flush bracket under
/// different flags, which is the only part of this decision they do not share.
/// `busyLogDetailLocked` is likewise read under the lock, and only when the
/// scroll-mode log tier is on.
func provisionSurfaceRowCapacity(
    ledger: SurfaceRowCapacityLedger,
    lock: NSLock,
    bufferSets: [SurfaceBufferSet],
    device: MTLDevice,
    maxRowBuffers: Int,
    logLabel: String,
    isBusyLocked: () -> Bool,
    busyLogDetailLocked: () -> String
) -> SurfaceRowProvisionStatus {
    lock.lock()
    if ledger.hardFailure {
        lock.unlock()
        return .hardFailure
    }
    // Nothing owed: answer ready regardless of what this surface is currently
    // doing. Asked before the busy check because a surface presenting at
    // refresh rate almost always has a frame in flight, and the caller folds
    // any one surface's .retry into an app-wide verdict — an idle ledger would
    // otherwise keep the whole retry re-arming.
    guard ledger.requiredRows > 0 else {
        lock.unlock()
        return .ready
    }
    if ledger.provisioning || isBusyLocked() {
        let detail = ZonvieCore.appLogEnabled ? busyLogDetailLocked() : ""
        let provisioning = ledger.provisioning
        lock.unlock()
        ZonvieCore.appLogScrollMode(
            "[scroll_debug] row_capacity_retry_blocked surface=\(logLabel) " +
            "\(detail) provisioning=\(provisioning)"
        )
        return .retry
    }
    ledger.provisioning = true
    let requiredRows = ledger.requiredRows
    let requiredVertexCounts = Array(ledger.requiredVertexCounts[0..<requiredRows])
    for row in 0..<requiredRows {
        ledger.requiredVertexCounts[row] = 0
    }
    ledger.requiredRows = 0
    lock.unlock()

    let planResult = makeSurfaceRowProvisionPlan(
        bufferSets: bufferSets,
        device: device,
        requiredRowCount: requiredRows,
        requiredVertexCounts: requiredVertexCounts,
        maxRowBuffers: maxRowBuffers
    )

    lock.lock()
    defer {
        ledger.provisioning = false
        lock.unlock()
    }
    switch planResult {
    case .overBudget:
        ledger.hardFailure = true
        return .hardFailure
    case .allocationFailed(let partialPlan):
        let metrics = partialPlan.metrics
        ZonvieCore.appLog(
            "[\(logLabel)] row provisioning allocation failed " +
            "attempt=\(metrics.allocationAttemptCount) created=\(metrics.createdBufferCount) " +
            "createdBytes=\(metrics.createdBufferBytes) planned=\(metrics.plannedReplacementCount) " +
            "plannedBytes=\(metrics.plannedReplacementBytes) live=\(metrics.liveBufferCount) " +
            "liveBytes=\(metrics.liveBufferBytes)"
        )
        // Private pool publication is independent of committed rowState.
        // Retaining the successful prefix makes every retry monotonic without
        // exposing a partially rendered frame.
        applySurfaceRowProvisionPlan(
            partialPlan,
            to: bufferSets,
            maxRowBuffers: maxRowBuffers
        )
        ledger.requiredRows = max(ledger.requiredRows, requiredRows)
        for row in 0..<requiredRows {
            ledger.requiredVertexCounts[row] = max(
                ledger.requiredVertexCounts[row],
                requiredVertexCounts[row]
            )
        }
        return .retry
    case .ready(let plan):
        if ZonvieCore.appLogEnabled && plan.metrics.createdBufferCount > 0 {
            ZonvieCore.appLogPerf(
                "[perf] row_provision surface=\(logLabel) created=\(plan.metrics.createdBufferCount) " +
                "createdBytes=\(plan.metrics.createdBufferBytes) attempts=\(plan.metrics.allocationAttemptCount) " +
                "peakBytes=\(plan.metrics.liveBufferBytes + plan.metrics.plannedReplacementBytes)"
            )
        }
        applySurfaceRowProvisionPlan(plan, to: bufferSets, maxRowBuffers: maxRowBuffers)
    }
    return ledger.requiredRows == 0 ? .ready : .retry
}

/// Encode the user's custom post-process chain, sampling `input` and writing
/// the last pass into `output`.
///
/// Intermediate passes ping-pong through `pong`, which is sized here because
/// only a chain longer than one pass needs it. Returns false when the chain
/// could not be fully encoded; `output` is then still untouched — every
/// partial pass wrote into `pong` — so the caller falls back to its own copy.
///
/// `pongSize` is the caller's drawable size rather than `output`'s dimensions:
/// the two surfaces each derive it from their own view, and reading it off the
/// texture would change which value the pair is keyed on.
/// Which route put the back buffer on the drawable, or that none did.
enum SurfaceDrawablePresentation {
    case customShaderChain
    case plainCopy
    case notEncoded

    var encoded: Bool { self != .notEncoded }
    var tookCustomShaderChain: Bool { self == .customShaderChain }
}

@discardableResult
func encodeSurfaceBackBufferToDrawable(
    cmd: MTLCommandBuffer,
    backTex: MTLTexture,
    drawableTexture: MTLTexture,
    customShaderPipelines: [CustomShaderPipeline],
    runsCustomShaderChain: Bool,
    customShaderPong: SurfacePingPongTextures,
    pongSize: CGSize,
    copyPipeline: MTLRenderPipelineState?,
    copyVertexBuffer: MTLBuffer?,
    sampler: MTLSamplerState?,
    bilinearSampler: MTLSamplerState?,
    makeUniforms: () -> zonvie_shader_uniforms,
    prepareCopy: (MTLRenderPassDescriptor) -> Void = { _ in }
) -> SurfaceDrawablePresentation {
    if runsCustomShaderChain,
       !customShaderPipelines.isEmpty,
       let copyVB = copyVertexBuffer,
       let bilinSamp = bilinearSampler,
       encodeSurfaceCustomShaderChain(
           cmd: cmd,
           pipelines: customShaderPipelines,
           input: backTex,
           output: drawableTexture,
           pong: customShaderPong,
           pongSize: pongSize,
           copyVertexBuffer: copyVB,
           sampler: bilinSamp,
           uniforms: makeUniforms()
       )
    {
        return .customShaderChain
    }
    guard let copyPipe = copyPipeline,
          let copyVB = copyVertexBuffer,
          let samp = sampler else { return .notEncoded }
    let copied = encodeSurfaceDrawableCopy(
        cmd: cmd,
        input: backTex,
        output: drawableTexture,
        pipeline: copyPipe,
        copyVertexBuffer: copyVB,
        sampler: samp,
        prepare: prepareCopy
    )
    return copied ? .plainCopy : .notEncoded
}

/// The bloom pass, taking its resources from where they live rather than from
/// seven `let`s the caller unpacks by hand.
///
/// Five pipelines, the copy vertex buffer and the bilinear sampler are on
/// SharedRenderResources; the textures, viewport and layer transform belong to
/// the surface. Both surfaces wrote out the same seven-binding `if let` ladder
/// and the same fifteen-argument call, differing only in where they read the
/// intensity and radius from.
///
/// Returns false only when the pass was wanted and could not be encoded — a
/// missing resource, or textures that would not allocate — which both callers
/// treat as a frame to abandon. Glow being off is `true`: nothing to encode is
/// not a failure.
func encodeSurfaceBloom(
    enabled: Bool,
    shared: SharedRenderResources,
    cmd: MTLCommandBuffer,
    backTex: MTLTexture,
    pixelFormat: MTLPixelFormat,
    viewportMetrics: SurfaceViewportMetrics,
    drawableSize: CGSize,
    /// A decorated surface's viewport does not start at the drawable's origin.
    viewportOrigin: CGPoint = .zero,
    glowTextures: SurfaceGlowTextures,
    intensity: Float,
    radiusScale: Float,
    /// The extract pass's own pipeline is handed back, because the vertices a
    /// surface extracts are drawn with it and both callers need it inside.
    encodeExtractVertices: (MTLRenderCommandEncoder, MTLRenderPipelineState) -> Void
) -> Bool {
    guard enabled else { return true }
    guard let extractPipe = shared.glowExtractPipeline,
          let downPipe = shared.kawaseDownPipeline,
          let upPipe = shared.kawaseUpPipeline,
          let compositePipe = shared.glowCompositePipeline,
          let copyVB = shared.copyVertexBuffer,
          let bilinSamp = shared.bilinearSampler else { return false }
    let chain = surfaceGlowChain(
        surfaceWidthPx: Int(drawableSize.width),
        surfaceHeightPx: Int(drawableSize.height),
        radiusScale: radiusScale
    )
    guard glowTextures.ensure(device: shared.device, chain: chain, pixelFormat: pixelFormat),
          glowTextures.ensureIntensityBuffer(device: shared.device) else { return false }
    return encodeSurfaceBloomPasses(
        cmd: cmd,
        backTex: backTex,
        viewportSize: CGSize(
            width: viewportMetrics.viewportWidth,
            height: viewportMetrics.viewportHeight
        ),
        drawableSize: drawableSize,
        viewportOrigin: viewportOrigin,
        layerTransform: viewportMetrics.layerTransform,
        glowTextures: glowTextures,
        extractPipeline: extractPipe,
        kawaseDownPipeline: downPipe,
        kawaseUpPipeline: upPipe,
        compositePipeline: compositePipe,
        copyVertexBuffer: copyVB,
        bilinearSampler: bilinSamp,
        intensity: intensity,
        chain: chain,
        radiusScale: radiusScale,
        encodeExtractVertices: { enc in encodeExtractVertices(enc, extractPipe) }
    )
}

/// Stage a row scroll on the WRITE set, merging it into one already staged for
/// the same region.
///
/// Staging on the write set rather than straight onto a per-grid accumulator is
/// what stops a draw() interleaving before commitFlush from consuming a delta
/// whose vertices are not committed yet — and, if the bracket is then
/// cancelled, from keeping that mis-shifted frame permanently.
///
/// When the region changes inside one bracket the older shift can no longer be
/// represented, but its row slots were already remapped, so the rows it covered
/// are handed to `dirtySupersededRows` to redraw post-remap. Each caller keeps
/// its own guard on when staging is allowed at all.
///
/// The merge itself is the core's (`src/core/row_scroll.zig` `mergeStaged`),
/// beside the blit plan it feeds. Three implementations of this rule were
/// found and they did not agree — see that function's comment. Nothing is left
/// here to drift: this reads the answer and writes it down.
///
/// Lives here rather than in MetalTypes.swift because that file is compiled
/// standalone by the Swift test steps and cannot see the core's header.
func stageSurfaceRowScroll(
    on set: SurfaceBufferSet,
    rowStart: Int,
    rowEnd: Int,
    colStart: Int,
    colEnd: Int,
    rowsDelta: Int,
    totalRows: Int,
    totalCols: Int,
    dirtySupersededRows: (_ rowStart: Int, _ rowEnd: Int) -> Void
) {
    var incoming = zonvie_row_scroll(
        row_start: Int32(clamping: rowStart),
        row_end: Int32(clamping: rowEnd),
        col_start: Int32(clamping: colStart),
        col_end: Int32(clamping: colEnd),
        rows_delta: Int32(clamping: rowsDelta),
        total_rows: Int32(clamping: totalRows),
        total_cols: Int32(clamping: totalCols)
    )
    var out = zonvie_row_scroll_merge()
    let answered: Bool
    if let staged = set.pendingScroll {
        var existing = zonvie_row_scroll(
            row_start: Int32(clamping: staged.rowStart),
            row_end: Int32(clamping: staged.rowEnd),
            col_start: Int32(clamping: staged.colStart),
            col_end: Int32(clamping: staged.colEnd),
            rows_delta: Int32(clamping: staged.rowsDelta),
            total_rows: Int32(clamping: staged.totalRows),
            total_cols: Int32(clamping: staged.totalCols)
        )
        answered = zonvie_core_row_scroll_merge(&existing, &incoming, &out)
    } else {
        answered = zonvie_core_row_scroll_merge(nil, &incoming, &out)
    }
    // The core refuses only a null argument, which cannot happen here.
    guard answered else { return }

    if out.has_superseded != 0 {
        dirtySupersededRows(Int(out.superseded.row_start), Int(out.superseded.row_end))
    }
    set.pendingScroll = SurfaceRowScroll(
        rowStart: Int(out.staged.row_start),
        rowEnd: Int(out.staged.row_end),
        colStart: Int(out.staged.col_start),
        colEnd: Int(out.staged.col_end),
        rowsDelta: Int(out.staged.rows_delta),
        totalRows: Int(out.staged.total_rows),
        totalCols: Int(out.staged.total_cols)
    )
}

/// Begin one smooth-scroll retention step for a layer, capture the rows it
/// pushes past the edge, and seed the sub-row ease.
///
/// The rule, not the capture: `bracketStagedGrids` is what stops one grid being
/// stepped twice inside a bracket, and `abs(rowsDelta) == 1` is what limits the
/// seed to a step small enough to ease. Both surfaces carried both conditions,
/// and scroll retention is where this project's scroll defects have repeatedly
/// come from — so the two conditions live together, once.
///
/// `captureRow` is the caller's, because the two surfaces resolve a row's
/// vertices differently. `lock` is the caller's for the same reason the two
/// surfaces still have different numbers of locks.
///
/// Returns true when a step was staged or was already staged for this grid in
/// this bracket, which is what the seed below is gated on.
@discardableResult
func captureSurfaceLayerScrollStep(
    gridId: Int64,
    sets: [SurfaceBufferSet],
    flushSourceSetIndex: Int,
    rowStart: Int,
    rowEnd: Int,
    rowsDelta: Int,
    retention: ScrollRetention,
    lock: NSLock,
    bracketStagedGrids: inout Set<Int64>,
    stagedSmoothScrollSeeds: inout [(gridId: Int64, rowsDelta: Int)],
    captureRow: (SurfaceBufferSet, Int, Int) -> Void
) -> Bool {
    lock.lock()
    var stepped = bracketStagedGrids.contains(gridId)
    lock.unlock()

    let cs = sets[flushSourceSetIndex]
    if !stepped, cs.rowState.usingRowBuffers,
       let plan = ScrollRetention.plan(
           rowStart: rowStart,
           rowEnd: rowEnd,
           rowsDelta: rowsDelta,
           depth: retention.depthRows
       )
    {
        retention.beginStep(gridId: gridId, rowsDelta: rowsDelta, pivotTargetRow: plan.pivotTargetRow)
        // Claim the step so the row-shift capture stands down for this grid.
        lock.lock()
        bracketStagedGrids.insert(gridId)
        lock.unlock()
        for i in 0..<plan.count {
            let row = ScrollRetention.planRow(plan, i, rowsDelta: rowsDelta)
            captureRow(cs, row, row - rowsDelta)
        }
        stepped = true
    }

    if stepped {
        stageSurfaceEaseSeed(gridId: gridId, rowsDelta: rowsDelta, lock: lock,
                             stagedSmoothScrollSeeds: &stagedSmoothScrollSeeds)
    }
    return stepped
}

/// Stage the sub-row ease seed for a retention step that was taken. Only a
/// single-row step can be eased; anything larger lands whole. Every surface
/// that seeds goes through here.
func stageSurfaceEaseSeed(
    gridId: Int64,
    rowsDelta: Int,
    lock: NSLock,
    stagedSmoothScrollSeeds: inout [(gridId: Int64, rowsDelta: Int)]
) {
    guard abs(rowsDelta) == 1 else { return }
    lock.lock()
    stagedSmoothScrollSeeds.append((gridId: gridId, rowsDelta: rowsDelta))
    lock.unlock()
    // `continuous_j_scroll_matches_jump` counts these to tell an eased scroll
    // from one that jumped, so the marker is part of the contract. An external
    // root used to seed through its own copy without it.
    if ZonvieCore.appLogEnabled {
        ZonvieCore.appLog("[smooth_scroll_seed] gridId=\(gridId) rowsDelta=\(rowsDelta)")
    }
}

/// Begin one retention step for a grid_scroll the row-shift fast path does not
/// see, and capture the rows it pushes out of `bounds` — the grid's scrollable
/// span, margins excluded. A bordered float or a vertical split scrolls less
/// than its full width, so the core repaints it instead of shifting it, and
/// this is the only capture it gets.
///
/// The main renderer runs it from the grid_scroll callback; an external
/// surface runs it when its bracket opens, for every grid it draws, root or
/// hosted layer. Claiming the grid in `bracketStagedGrids` is what makes the
/// fast path stand down if it does fire for the same step. No ease seed: the
/// gesture that drives these scrolls holds its own compensation.
///
/// `sourceShift` is how far the source set lags the content this step
/// describes (see the main renderer's replay). `captureRow` is the caller's,
/// for the reason `captureSurfaceLayerScrollStep` gives.
///
/// Returns false when nothing could be planned.
@discardableResult
func captureSurfaceGridScrollStep(
    gridId: Int64,
    cs: SurfaceBufferSet,
    bounds: (top: Int, bottomEx: Int),
    rowsDelta: Int,
    sourceShift: Int,
    retention: ScrollRetention,
    lock: NSLock,
    bracketStagedGrids: inout Set<Int64>,
    captureRow: (SurfaceBufferSet, Int, Int) -> Void
) -> Bool {
    guard cs.rowState.usingRowBuffers else { return false }
    // Clamped to the rows the grid actually has: spans are armed per gesture
    // and never disarmed, so a grid that has shrunk since would plan rows past
    // its end, open the band empty, and let `beginStep` prune the previous
    // step's good rows against a pivot derived from the stale span.
    guard let plan = ScrollRetention.plan(
        rowStart: bounds.top,
        rowEnd: min(bounds.bottomEx, cs.rowState.counts.count),
        rowsDelta: rowsDelta,
        depth: retention.depthRows
    ) else { return false }
    retention.beginStep(gridId: gridId, rowsDelta: rowsDelta, pivotTargetRow: plan.pivotTargetRow)
    lock.lock()
    bracketStagedGrids.insert(gridId)
    lock.unlock()
    for i in 0..<plan.count {
        let row = ScrollRetention.planRow(plan, i, rowsDelta: rowsDelta)
        captureRow(cs, row + sourceShift, row - rowsDelta)
    }
    return true
}

/// Force the window's shadow to be recalculated after a surface's first
/// present when blur is enabled. Transparent windows (isOpaque=false,
/// backgroundColor=.clear) need this to show a shadow once the first frame is
/// rendered. Every surface owes it; only the main one used to do it.
func recalculateSurfaceShadowAfterFirstPresent(_ view: NSView?) {
    guard ZonvieConfig.shared.blurEnabled else { return }
    // Delay so the window is fully rendered first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in
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

func encodeSurfaceCustomShaderChain(
    cmd: MTLCommandBuffer,
    pipelines: [CustomShaderPipeline],
    input: MTLTexture,
    output: MTLTexture,
    pong: SurfacePingPongTextures,
    pongSize: CGSize,
    copyVertexBuffer: MTLBuffer,
    sampler: MTLSamplerState,
    uniforms: zonvie_shader_uniforms
) -> Bool {
    guard !pipelines.isEmpty else { return false }
    if pipelines.count > 1 {
        pong.ensure(device: output.device, size: pongSize, pixelFormat: output.pixelFormat)
        guard pong.ready else { return false }
    }
    for (i, pipeline) in pipelines.enumerated() {
        let isLast = (i == pipelines.count - 1)
        let inputTex: MTLTexture = (i == 0) ? input : pong[(i - 1) % 2]!
        let outputTex: MTLTexture = isLast ? output : pong[i % 2]!
        if !pipeline.encode(
            cmd: cmd,
            input: inputTex,
            output: outputTex,
            copyVertexBuffer: copyVertexBuffer,
            sampler: sampler,
            uniforms: uniforms
        ) {
            return false
        }
    }
    return true
}

/// Per-pass GPU measurement for one surface: stage-boundary timestamps on
/// attachment slot 0 and fragment-invocation counters on slot 1.
///
/// One sample buffer of each kind is reused across frames; safe because
/// inflightSemaphore bounds in-flight frames to 1, so the previous frame's
/// completion handler resolves the buffers before the next draw assigns slots.
/// The two kinds gate independently: a device that exposes `timestamp` but not
/// `statistic` still reports pass timings.
struct GpuPassSampler {
    struct Slot { let label: String; let startIdx: Int; let endIdx: Int }
    /// Full 4-stage sampling for one pass (vertex start/end + fragment
    /// start/end). Used to investigate why the copy pass measures ~2.9ms even
    /// though it's a single 6-vert blit (~0.7ms theoretical bandwidth limit) —
    /// the fragment-only number doesn't show vertex stage cost or the gap
    /// waiting for the previous pass's tile store.
    struct FullSlot {
        let label: String
        let startVIdx: Int
        let endVIdx: Int
        let startFIdx: Int
        let endFIdx: Int
    }

    /// What one frame hands its completion handler. A value copy, so the
    /// renderer is free to reset the live slot arrays on the next draw.
    struct Frame {
        var timestampBuffer: MTLCounterSampleBuffer?
        var sampleCount: Int = 0
        var tickPeriodNs: Double = 1.0
        var slots: [Slot] = []
        var fullSlots: [FullSlot] = []
        var statsBuffer: MTLCounterSampleBuffer?
        var statsSlots: [Slot] = []
    }

    private var timestampBuffer: MTLCounterSampleBuffer?
    private var timestampsEnabled = false
    private var tickPeriodNs: Double = 1.0
    private var slots: [Slot] = []        // Render thread only; reset per draw
    private var fullSlots: [FullSlot] = []  // ditto, full-stage sampling
    private var nextIdx = 0               // shared sample-buffer cursor; reset per draw
    private var statsBuffer: MTLCounterSampleBuffer?
    private var statsEnabled = false
    private var statsSlots: [Slot] = []   // Render thread only; reset per draw

    /// Probe device support for stage-boundary counters and allocate the
    /// reusable sample buffers. On unsupported devices the gates stay false and
    /// the per-pass logs are silently skipped (gpu_execution still emits).
    mutating func setUp(device: MTLDevice) {
        // Diagnostic dump of what the device actually exposes. M-series Macs
        // typically only show "timestamp" via runtime API; statistic and
        // stageutilization are restricted to Xcode GPU Capture on macOS.
        let exposedSets = (device.counterSets ?? []).map { $0.name }.joined(separator: ",")
        let supportsStage = device.supportsCounterSampling(.atStageBoundary)
        let supportsDraw = device.supportsCounterSampling(.atDrawBoundary)
        let supportsBlit = device.supportsCounterSampling(.atBlitBoundary)
        ZonvieCore.appLogPerf("[perf] gpu_counters: sets=[\(exposedSets)] stage=\(supportsStage) draw=\(supportsDraw) blit=\(supportsBlit)")

        guard supportsStage else {
            ZonvieCore.appLogPerf("[perf] gpu_passes: device does not support .atStageBoundary; skipping per-pass GPU timing")
            return
        }
        let timestampSet = device.counterSets?.first { cs in
            // MTLCommonCounterSet is a RawRepresentable wrapper around String;
            // MTLCounterSet.name returns a Swift String, so compare via rawValue.
            cs.name == MTLCommonCounterSet.timestamp.rawValue
        }
        guard let cs = timestampSet else {
            ZonvieCore.appLogPerf("[perf] gpu_passes: no timestamp counter set available; skipping per-pass GPU timing")
            return
        }
        let desc = MTLCounterSampleBufferDescriptor()
        desc.counterSet = cs
        desc.label = "ZonvieGpuPerfTimestamps"
        desc.storageMode = .shared
        // Capacity 16 = up to 8 passes per frame (start+end each). Today we attach
        // 3 (main, copy, cursor); headroom for future custom-shader chain entries.
        desc.sampleCount = 16
        do {
            timestampBuffer = try device.makeCounterSampleBuffer(descriptor: desc)
        } catch {
            ZonvieCore.appLogPerf("[perf] gpu_passes: makeCounterSampleBuffer failed: \(error)")
            return
        }
        // Calibrate GPU tick → ns. On Apple Silicon timestamps already arrive in
        // nanoseconds, but compute the ratio so other backends (Intel discrete
        // GPUs, future hw) report correctly. Newer SDKs expose this as a
        // tuple-returning method instead of inout pointers.
        let (cpu0, gpu0) = device.sampleTimestamps()
        Thread.sleep(forTimeInterval: 0.002)
        let (cpu1, gpu1) = device.sampleTimestamps()
        let cpuDelta = Double(cpu1 &- cpu0)
        let gpuDelta = Double(gpu1 &- gpu0)
        if cpuDelta > 0, gpuDelta > 0 {
            // sampleTimestamps' cpuTimestamp is in nanoseconds (mach_absolute_time
            // converted via timebase, per Apple docs); gpuTimestamp is in GPU ticks.
            tickPeriodNs = cpuDelta / gpuDelta
        }
        timestampsEnabled = true
        ZonvieCore.appLogPerf("[perf] gpu_passes: enabled (tick_period_ns=\(String(format: "%.4f", tickPeriodNs)))")

        // ── Statistic counter set: fragment invocations for overdraw measurement.
        let statisticSet = device.counterSets?.first { cs in
            cs.name == MTLCommonCounterSet.statistic.rawValue
        }
        guard let stCs = statisticSet else {
            ZonvieCore.appLogPerf("[perf] gpu_overdraw: no statistic counter set; skipping")
            return
        }
        let stDesc = MTLCounterSampleBufferDescriptor()
        stDesc.counterSet = stCs
        stDesc.label = "ZonvieGpuStatsBuffer"
        stDesc.storageMode = .shared
        stDesc.sampleCount = 16
        do {
            statsBuffer = try device.makeCounterSampleBuffer(descriptor: stDesc)
            statsEnabled = true
            ZonvieCore.appLogPerf("[perf] gpu_overdraw: enabled")
        } catch {
            ZonvieCore.appLogPerf("[perf] gpu_overdraw: makeCounterSampleBuffer(statistic) failed: \(error)")
        }
    }

    /// Drop the previous frame's slot assignments. The caller gates this on
    /// perf logging so the hot path pays nothing when logging is off (the
    /// attach calls bail out internally, but these removeAlls would not).
    mutating func beginFrame() {
        slots.removeAll(keepingCapacity: true)
        fullSlots.removeAll(keepingCapacity: true)
        nextIdx = 0
        statsSlots.removeAll(keepingCapacity: true)
    }

    // Attach fragment-stage timestamp samples to a render pass descriptor so the
    // GPU records start-of-fragment / end-of-fragment timestamps. The duration
    // (end - start) is scaled by tickPeriodNs when the frame resolves.
    //
    // Why fragment-stage only (not start_v..end_f): on Apple Silicon TBDR, the
    // vertex stage of pass N+1 runs in parallel with the fragment stage of pass
    // N, so start_v..end_f intervals overlap heavily and don't yield meaningful
    // per-pass cost (sum was ~1.6x exec_us when measured that way). Adjacent
    // passes that share textures are serialized at the fragment boundary
    // (read-after-write), so fragment-only sampling produces costs that roughly
    // sum to gpu_exec_us. Vertex cost is small for text rendering and acceptable
    // to elide.
    //
    // No-op when perf logging is off or the device lacks counter sampling.
    // Must be called BEFORE makeRenderCommandEncoder(rpd).
    mutating func attach(to rpd: MTLRenderPassDescriptor, label: String) {
        guard timestampsEnabled, ZonvieCore.appLogEnabled, let buf = timestampBuffer else { return }
        let startIdx = nextIdx
        let endIdx = startIdx + 1
        guard endIdx < buf.sampleCount else { return }
        nextIdx += 2
        let attach = rpd.sampleBufferAttachments[0]!
        attach.sampleBuffer = buf
        attach.startOfVertexSampleIndex = MTLCounterDontSample
        attach.endOfVertexSampleIndex = MTLCounterDontSample
        attach.startOfFragmentSampleIndex = startIdx
        attach.endOfFragmentSampleIndex = endIdx
        slots.append(Slot(label: label, startIdx: startIdx, endIdx: endIdx))
    }

    // Same as attach(to:label:) but also samples the vertex-stage boundary
    // so we get start_v / end_v / start_f / end_f for one pass. Lets us split:
    //   vertex_us  = end_v - start_v   (vertex shader + binning)
    //   vfgap_us   = start_f - end_v   (idle waiting for tile binning to settle
    //                                   or for previous pass's tile store)
    //   fragment_us = end_f - start_f  (= existing copy_us field)
    //   total_us   = end_f - start_v   (whole pass wall time)
    //
    // Used only for the copy pass today, where the 2.9ms p50 measurement is
    // 4x the bandwidth-limited theoretical minimum and we need the breakdown
    // to know whether the cost is in vertex/binning, in cross-pass scheduling,
    // or actually in fragment shading.
    mutating func attachFull(to rpd: MTLRenderPassDescriptor, label: String) {
        guard timestampsEnabled, ZonvieCore.appLogEnabled, let buf = timestampBuffer else { return }
        let baseIdx = nextIdx
        let endFIdx = baseIdx + 3
        guard endFIdx < buf.sampleCount else { return }
        nextIdx += 4
        let attach = rpd.sampleBufferAttachments[0]!
        attach.sampleBuffer = buf
        attach.startOfVertexSampleIndex = baseIdx
        attach.endOfVertexSampleIndex = baseIdx + 1
        attach.startOfFragmentSampleIndex = baseIdx + 2
        attach.endOfFragmentSampleIndex = baseIdx + 3
        fullSlots.append(FullSlot(
            label: label,
            startVIdx: baseIdx,
            endVIdx: baseIdx + 1,
            startFIdx: baseIdx + 2,
            endFIdx: baseIdx + 3
        ))
    }

    // Attach fragment-invocation counter samples on attachment slot 1 (slot 0 is
    // taken by timestamps). Uses the same fragment-stage boundaries so the
    // invocation count covers the same work the timestamp duration does.
    // Resolved as fragmentInvocations(end - start); overdraw ratio is computed
    // against actual visible pixel area.
    mutating func attachStats(to rpd: MTLRenderPassDescriptor, label: String) {
        guard statsEnabled, ZonvieCore.appLogEnabled, let buf = statsBuffer else { return }
        let startIdx = statsSlots.count * 2
        let endIdx = startIdx + 1
        guard endIdx < buf.sampleCount else { return }
        let attach = rpd.sampleBufferAttachments[1]!
        attach.sampleBuffer = buf
        attach.startOfVertexSampleIndex = MTLCounterDontSample
        attach.endOfVertexSampleIndex = MTLCounterDontSample
        attach.startOfFragmentSampleIndex = startIdx
        attach.endOfFragmentSampleIndex = endIdx
        statsSlots.append(Slot(label: label, startIdx: startIdx, endIdx: endIdx))
    }

    /// Snapshot this frame's slots for the completion handler. `logging` is the
    /// caller's one read of `appLogEnabled`: when it is false the copy is empty
    /// constants rather than array copies / ref bumps.
    func frameSnapshot(logging: Bool) -> Frame {
        guard logging else { return Frame(tickPeriodNs: tickPeriodNs) }
        return Frame(
            timestampBuffer: timestampBuffer,
            sampleCount: nextIdx,
            tickPeriodNs: tickPeriodNs,
            slots: slots,
            fullSlots: fullSlots,
            statsBuffer: statsBuffer,
            statsSlots: statsSlots
        )
    }
}

// MTLCommandBuffer rule: any command buffer created via queue.makeCommandBuffer()
// MUST be committed before being dropped. Uncommitted command buffers leak
// IOAccelerator GPU memory regions that the kernel never reclaims (observable
// as growing phys_footprint under flush bursts).
final class GridSurfaceRenderer: NSObject, MTKViewDelegate {
    /// The GPU objects this surface shares with every other one. Created here
    /// because the main window's renderer is the first surface to exist; every
    /// other surface is handed this same instance.
    let shared: SharedRenderResources
    private let queue: MTLCommandQueue

    /// Expose device for external grid views (shared Metal device).
    var metalDevice: MTLDevice { shared.device }

    /// The queue this surface draws on. The atlas blit rides the MAIN
    /// surface's queue so that surface needs no reader admission — see
    /// SharedRenderResources.beginFlushTransaction.
    var commandQueue: MTLCommandQueue { queue }

    /// Whether this surface allocates GPU counter sample buffers and reports
    /// `[perf] gpu_passes`. A property rather than "this is the main renderer",
    /// so the surface kind stops being implied by the type. Defaults on
    /// because the only surface built from this type today is the main one;
    /// a surface that comes and goes with a float must pass false, since
    /// GpuPassSampler.setUp allocates an MTLCounterSampleBuffer per instance.
    private let collectsGpuPerfSamples: Bool

    /// Expose atlas for external grid views (shared glyph cache).
    var glyphAtlas: GlyphAtlas { shared.atlas }

    // Forwarders onto `shared`, so the ~170 uses below read as they always did
    // while the objects themselves belong to no surface. Read-only on purpose:
    // the build sites write `shared.x` directly, which keeps "who writes these"
    // answerable by searching for `shared.`.
    /// Also read by ExternalGridView for the shared back-buffer copy.
    private weak var viewForPipeline: MTKView?

    // 2-pass rendering pipelines for blur support
    // Background pipeline uses overwrite blending (one, zero) to avoid ghosting
    // Glyph pipeline uses standard alpha blending for correct antialiasing
    // Single-pass replacement for the (backgroundPipeline + glyphPipeline) 2-pass.
    // Uses ps_unified_blur which reads tile memory via raster_order_group and
    // composites bg + glyph + decorations in a single fragment shader. Halves
    // fragment-shader invocations vs the 2-pass discard pattern when enabled.
    // nil → fall back to 2-pass for safety.

    // Copy pipeline for backBuffer -> drawable (replaces MTLBlitCommandEncoder)
    // Using render pipeline instead of blit avoids XPC compiler issues after fork()



    /// Everything this surface publishes across threads: the buffer sets and
    /// their GPU in-flight counts, the commit revision, pending dirty rows and
    /// rect, scroll offsets and retention, the committed layer list, the
    /// shader cursor state, and `hasPresentedOnce`.
    ///
    /// One lock where ExternalGridView has three, and it stays that way:
    /// measured under a sustained 30 Hz scroll this lock was taken 19,764
    /// times and found already held 49 — 0.248%, against 0.204% for the
    /// busiest of the external surface's three. The count is a legibility
    /// difference, not a performance one. What each of theirs guards, and the
    /// single ordering rule between them, is written at their declarations.
    ///
    /// Cell metrics and `linespace` are NOT here: they live on
    /// SharedRenderResources behind a leaf lock, because reading cell height
    /// while holding this one used to be a self-deadlock hazard callers had to
    /// route around.
    private let lock = NSLock()

    // MARK: - Triple Buffering

    /// Vertex storage for every grid this renderer draws, keyed by grid id.
    let gridBuffers = GridBufferRegistry()
    /// Grid 1's sets. SurfaceBufferSet is a class, so mutating through this
    /// computed property mutates the registry's own objects.
    private var bufferSets: [SurfaceBufferSet] { gridBuffers.sets(for: 1) }

    /// Stage a surface's layer list. Called on the core thread inside the flush
    /// bracket; `commitFlush` promotes it so layers and vertices become visible
    /// in the same transaction.
    func setPendingSurfaceLayers(_ layers: [SurfaceLayer]) {
        // Under `lock`, as abortFlush and commitFlush write it and as the
        // external surface writes its own: every reader today is on the core
        // thread, but the external one already has a main-thread reader, and
        // one discipline means adding a reader here cannot race.
        lock.lock()
        pendingSurfaceLayers = layers
        lock.unlock()
        // Removing or migrating the owner also removes its surface overlay.
        // Stage this with placement so abort preserves the old complete frame.
        if !layers.contains(where: { $0.gridId == (cursorOwner.staged ?? 1) }) {
            submitLayerCursor(gridId: cursorOwner.staged ?? 1, ptr: nil, count: 0)
            cursorOwner.stage(1)
        }
    }


    private var layerGridsPreparedThisFlush = false

    /// Scratch for prepareLayerGridsForWrite; reused so the per-flush walk
    /// does not allocate.
    private var layerGridIdScratch: [Int64] = []

    /// Carry every non-root grid's rows from the committed set into this
    /// bracket's write set. The write set is two rotations old, so a grid the
    /// core does not resend this flush would otherwise draw stale rows.
    func prepareLayerGridsForWrite() {
        guard isInFlush, !layerGridsPreparedThisFlush else { return }
        layerGridsPreparedThisFlush = true
        gridBuffers.copyGridIds(into: &layerGridIdScratch)
        for gridId in layerGridIdScratch where gridId != 1 {
            let sets = gridBuffers.sets(for: gridId)
            copySurfaceBufferSetRowState(from: sets[flushSourceSetIndex], to: sets[writeSetIndex])
        }
    }

    /// Which layer the committed cursor belongs to. The surface draws one
    /// cursor, and it has to be placed with its own layer's transform.
    /// Shared with ExternalGridView. This surface's root is grid 1, so that is
    /// what "no particular layer" means here and the owner is never nil.
    private var cursorOwner = SurfaceCursorOwner(initial: 1)
    var renderTraceFlushId: UInt64 = 0 // Core callback thread only.

    /// Where the committed cursor's own grid sits on this surface.
    private var committedCursorPlacement: SurfaceCursorPlacement {
        resolveSurfaceCursorPlacement(
            ownerGridId: cursorOwner.committed ?? 1,
            rootGridId: 1,
            layers: committedSurfaceLayers
        )
    }

    /// Publish the cursor layer for a grid the surface draws as a layer. The
    /// vertices are in that grid's own pixel space.
    func submitLayerCursor(gridId: Int64, ptr: UnsafePointer<zonvie_vertex>?, count: Int) {
        // Outside a bracket there is nothing to stage into, and staging the
        // owner anyway moves it for a cursor no commit will publish. The
        // external surface has always refused here; the root path warns.
        guard isInFlush else { return }
        // Cursor clears are grid-local even though the surface has one overlay.
        guard count != 0 || cursorOwner.owns(gridId) else {
            ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_ignore surface=1 grid=\(gridId) owner=\(cursorOwner.staged ?? 1) reason=empty_nonowner")
            return
        }
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_route surface=1 grid=\(gridId) vertices=\(count)")
        cursorOwner.stage(gridId)
        submitVerticesPartialRaw(
            mainPtr: nil,
            mainCount: 0,
            cursorPtr: ptr.map { UnsafeRawPointer($0) },
            cursorCount: count,
            updateMain: false,
            updateCursor: true
        )
    }

    /// Apply a row-shift hint to a grid the surface draws as a layer. The
    /// core sends only the vacated rows afterwards, so the surviving rows are
    /// carried by remapping this grid's own row slots.
    func applyLayerRowScroll(
        gridId: Int64,
        rowStart: Int,
        rowEnd: Int,
        colStart: Int,
        colEnd: Int,
        rowsDelta: Int,
        totalRows: Int,
        totalCols: Int
    ) {
        guard isInFlush, gridId != 1, rowsDelta != 0 else { return }
        guard prepareMainWriteState() else { return }
        guard let sets = gridBuffers.existingSets(for: gridId) else {
            // The core sends only the rows it vacated, so a grid whose buffer
            // sets do not exist yet cannot be left unshifted. No route here is
            // known — ids register on the first submitLayerRow — but failing
            // the flush makes on_flush_end abort and retry, which resends
            // every row.
            flushFailed = true
            return
        }
        // Must run before the remap: it reuses the outgoing row's slot for the
        // incoming row within this same flush.
        captureLayerScrollStep(
            gridId: gridId,
            sets: sets,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta
        )
        // The marks have to travel with the rows they describe. The remap below
        // moves a row's vertices to another logical row; a mark left at the
        // pre-shift index names content that is no longer there, and with the
        // blit accepted the row it moved to is never repainted.
        // Only this bracket's marks here: pendingDirtyRows carries marks a
        // cancelled bracket must keep as they are, so commitFlush shifts those
        // instead, against the shift it actually publishes.
        shiftSurfaceRowIndices(
            &layerDrawState(gridId: gridId).flushDirtyRows,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta
        )
        remapSurfaceRowSlots(
            bufferSet: sets[writeSetIndex],
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            totalRows: totalRows,
            totalCols: totalCols,
            maxRowBuffers: maxRowBuffers
        )
        let regionRows = rowEnd - rowStart
        // Stage on the WRITE set, never straight onto the per-grid accumulator:
        // commitFlush merges it under `lock` after committedSetIndex is
        // published, so an interleaving draw() cannot consume a delta whose
        // vertices are not committed yet. Must run AFTER prepareMainWriteState()
        // above: the prepareLayerGridsForWrite() inside it resets the
        // destination's pendingScroll.
        let ws = sets[writeSetIndex]
        if colStart == 0, colEnd == totalCols, regionRows > 0 {
            stageSurfaceRowScroll(
                on: ws,
                rowStart: rowStart, rowEnd: rowEnd,
                colStart: colStart, colEnd: colEnd,
                rowsDelta: rowsDelta,
                totalRows: totalRows, totalCols: totalCols,
                dirtySupersededRows: { start, end in
                    markLayerRowsDirty(gridId: gridId, rowStart: start, rowCount: end - start)
                }
            )
            // Only the band the shift vacated needs new content; the surviving
            // rows are carried by the remapped slots. A draw that refuses the
            // blit dirties the whole region itself.
            let shiftRows = min(abs(rowsDelta), regionRows)
            let vacatedStart = rowsDelta > 0 ? rowEnd - shiftRows : rowStart
            markLayerRowsDirty(gridId: gridId, rowStart: vacatedStart, rowCount: shiftRows)
        } else {
            // The core only shifts on full grid-local width
            // (gridScrollFastPathRegion in src/core/flush.zig), so redraw the
            // region rather than stage a shift the blit would apply too wide.
            markLayerRowsDirty(gridId: gridId, rowStart: rowStart, rowCount: regionRows)
        }
        // Once per hint, not per row: the scroll scenarios assert the fast
        // path actually ran, since regenerating everything looks identical on
        // screen and would let them pass with the shift broken.
        if ZonvieCore.appLogEnabled {
            ZonvieCore.appLog(
                "[layer_row_scroll] gridId=\(gridId) rowStart=\(rowStart) rowEnd=\(rowEnd) rowsDelta=\(rowsDelta)"
            )
        }
    }

    /// This grid's draw state, created on first use — grid creation time, not a
    /// per-frame path. Must not be called while holding `lock`.
    private func layerDrawState(gridId: Int64) -> SurfaceLayerDrawState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = layerDrawStates[gridId] { return existing }
        let created = SurfaceLayerDrawState()
        layerDrawStates[gridId] = created
        return created
    }

    /// Drop a destroyed grid's draw state, alongside its buffer sets.
    func releaseLayerDrawState(gridId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        layerDrawStates.removeValue(forKey: gridId)
    }

    /// Mark the rows a layer's change lands on, in that grid's own row space.
    /// The draw loop deactivates after a few frames with nothing to render and
    /// a layer change leaves the root grid clean, so without this mark held-key
    /// scrolling drops to on-demand redraws. Recorded whether or not the grid is
    /// in the layer list yet: the layout placing a new grid may not be staged.
    private func markLayerRowsDirty(gridId: Int64, rowStart: Int, rowCount: Int) {
        guard rowCount > 0, rowStart >= 0 else { return }
        layerDrawState(gridId: gridId).flushDirtyRows
            .insert(integersIn: rowStart..<(rowStart + rowCount))
        flushHadLayerWork = true
    }

    /// Store one row for a non-root layer, in that grid's own buffer sets.
    func submitLayerRow(
        gridId: Int64,
        rowStart: Int,
        ptr: UnsafePointer<zonvie_vertex>?,
        count: Int,
        totalRows: Int,
        totalCols: Int
    ) {
        guard isInFlush, gridId != 1 else { return }
        // Also selects this bracket's write set, which every grid shares, and
        // carries every layer's rows into it.
        guard prepareMainWriteState() else { return }
        let sets = gridBuffers.sets(for: gridId)
        // Match root rows: reuse buffers, then grow synchronously if needed.
        // Deferring ordinary growth aborts the whole flush into retry backoff.
        let submitted = submitSurfaceRowVertices(
            target: sets[writeSetIndex],
            sourceSet: sets[flushSourceSetIndex],
            device: shared.device,
            rowStart: rowStart,
            ptr: ptr,
            count: count,
            maxRowBuffers: maxRowBuffers,
            totalRows: totalRows,
            totalCols: totalCols,
            inflightRowBuffers: { (self.inflightRowBuffer(gridId: gridId, atSlot: $0), nil) }
        )
        if !submitted {
            // Same contract as the root grid's submitVerticesRowRaw: a row that
            // could not be stored must abort the flush, or the core clears its
            // dirty state and never resends it.
            flushFailed = true
        }
        markLayerRowsDirty(gridId: gridId, rowStart: rowStart, rowCount: 1)
    }

    /// Committed layer list for the main surface, back-to-front. Replaced
    /// wholesale by on_surface_layout and promoted at commitFlush.
    private var pendingSurfaceLayers: [SurfaceLayer]?   // Written under lock; read on the core thread
    private var committedSurfaceLayers: [SurfaceLayer] = [
        SurfaceLayer(gridId: 1, anchorGrid: 1, originPx: simd_float2(0, 0), rows: 0, cols: 0, z: 0, followsScroll: false)
    ]                                                    // Protected by lock
    private var writeSetIndex: Int = 0       // Core thread only
    private var mainWritePrepared = false    // Core thread only
    /// Whether this bracket dirtied any layer grid's rows. The root grid's own
    /// dirty marks no longer stand in for layer work, so commitFlush reads this
    /// to decide whether the commit carried a visual change.
    private var flushHadLayerWork = false    // Core thread only
    // Valid only while isInFlush == true. Tracks the committed set we are detaching from.
    private var flushSourceSetIndex: Int = 0 // Core thread only
    private var committedSetIndex: Int = 0   // Protected by lock
    private var cursorWriteSetIndex: Int = 0 // Core thread only
    private var cursorWritePrepared = false  // Core thread only
    /// The cursor triple, shared with ExternalGridView; see `SurfaceCursorSlot`
    /// for why it is not on the row sets. Guarded by `lock`.
    private var cursorSlots: [SurfaceCursorSlot] = [
        SurfaceCursorSlot(), SurfaceCursorSlot(), SurfaceCursorSlot()
    ]
    private var committedCursorSetIndex: Int = 0 // Protected by lock
    private var isInFlush: Bool = false       // Core thread only
    // Complete row metadata is retained independently in all three sets. A
    // non-committed set only needs rows changed since it last committed; this
    // avoids O(totalRows) metadata copying for a one-row flush. Structural
    // operations and aborted partial writes use the full-copy barrier.
    private let staleMainRowsBySet: [SparseRowSet] = [
        SparseRowSet(rowLimit: metalTerminalMaxRowBuffers, preparedRows: metalTerminalMaxRowBuffers),
        SparseRowSet(rowLimit: metalTerminalMaxRowBuffers, preparedRows: metalTerminalMaxRowBuffers),
        SparseRowSet(rowLimit: metalTerminalMaxRowBuffers, preparedRows: metalTerminalMaxRowBuffers),
    ]
    private let flushChangedMainRows = SparseRowSet(rowLimit: metalTerminalMaxRowBuffers, preparedRows: metalTerminalMaxRowBuffers)
    private var mainRowStateNeedsFullSync = [false, false, false]
    private var flushHasStructuralMainChange = false
    // Set (core thread) when a buffer allocation fails or a mandatory row shift
    // cannot be applied: an empty/undersized/unshifted set must not become the
    // committed state. ZonvieCore's on_flush_end consumes it, cancels the
    // bracket, calls zonvie_core_abort_flush and retries when retryable.
    private(set) var flushFailed: Bool = false // Core thread only
    // ExternalGridView carries a deliberately parallel ledger and provisioning
    // pass. The pure parts are already shared free functions in
    // MetalTypes.swift, which take the lock and a `lockHeld` flag so two
    // surfaces can share code without sharing a lock; what is left is each
    // class's adapter. This class keeps ONE lock where ExternalGridView keeps
    // three: splitting it would make commitFlush hold two at once, because the
    // retention publish there has to be atomic with the vertex publish.
    // Audit 2026-08-25, finding 037.
    // Fixed-size capacity ledger. Row callbacks only raise scalar entries;
    // the retry worker provisions Swift metadata and Metal buffers after the
    // flush bracket closes and before it reacquires the core grid lock.
    private let rowCapacity = SurfaceRowCapacityLedger(maxRowBuffers: metalTerminalMaxRowBuffers)
    // True while a core-thread flush bracket is open on this surface. Unlike
    // `isInFlush` (core-thread-owned, unsafe to read from main), this is
    // written and read ONLY under `lock`, so the provisioning worker can
    // consult it. ExternalGridView keeps the same pair under the same names.
    private var bracketOpen = false

    /// Read and clear flushFailed. Called once per flush from on_flush_end.
    func consumeFlushFailed() -> Bool {
        let v = flushFailed
        flushFailed = false
        return v
    }

    private func closeBracketFlag() {
        lock.lock()
        bracketOpen = false
        lock.unlock()
    }

    private func requirePreparedRowCapacity(
        row: Int,
        vertexCount: Int,
        totalRows: Int,
        rowIsPhysical: Bool = false,
        useWriteMapping: Bool = false
    ) -> Bool {
        let ok = requireSurfaceRowCapacity(
            bufferSets: bufferSets,
            ledger: rowCapacity,
            lock: lock,
            lockHeld: false,
            row: row,
            vertexCount: vertexCount,
            totalRows: totalRows,
            maxRowBuffers: maxRowBuffers,
            mappingSetIndex: useWriteMapping ? writeSetIndex : flushSourceSetIndex,
            rowIsPhysical: rowIsPhysical,
            logLabel: "Renderer"
        )
        if !ok { flushFailed = true }
        return ok
    }

    /// True while this surface still owes a provisioning pass, or is in the
    /// middle of one. The scheduled flush retry is that pass's only driver, so
    /// a commit elsewhere must not disarm the retry while this holds.
    /// `rowCapacity.provisioning` has to count: the provisioner zeroes the
    /// ledger before it allocates outside the lock, and a commit landing in
    /// that window would otherwise see nothing owed and cancel the very retry
    /// that is doing the work — after which an allocation failure restores the
    /// ledger with no driver left to act on it.
    var hasPendingRowCapacityWork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rowCapacity.requiredRows > 0 || rowCapacity.provisioning
    }

    /// Called on the retry queue before it acquires core grid_mu. Flush
    /// admission is gated while the plan is allocated and published, so row
    /// callbacks never race these metadata mutations.
    func provisionPendingRowCapacity() -> SurfaceRowProvisionStatus {
        provisionSurfaceRowCapacity(
            ledger: rowCapacity,
            lock: lock,
            bufferSets: bufferSets,
            device: shared.device,
            maxRowBuffers: maxRowBuffers,
            logLabel: "Renderer",
            isBusyLocked: { bracketOpen || gpuInFlightCount.contains(where: { $0 != 0 }) },
            busyLogDetailLocked: { "bracketOpen=\(bracketOpen) gpuInFlight=\(gpuInFlightCount)" }
        )
    }
    // Per-flush row submit accumulators. Reset in beginFlush, summed in
    // submitVerticesRowRaw, dumped in commitFlush as [perf] row_submit. Surfaces
    // the Swift-side cost inside Zig-measured row_cb_us (memcpy + slot remap).
    private var perfRowSubmitNs: Int64 = 0    // Core thread only
    private var perfRowSubmitCalls: Int = 0   // Core thread only
    private var perfRowSubmitVerts: Int = 0   // Core thread only

    // Per-pass GPU measurement (stage-boundary timestamps + fragment
    // invocation counters). Render thread only; reset at the top of each draw.
    private var gpuSampler = GpuPassSampler()

    private let inflightSemaphore = DispatchSemaphore(value: 1)  // Max 1 GPU in-flight
    /// How long a frame may wait for an in-flight commit before giving up and
    /// dropping itself. Traced waits during a held-key scroll ran 364us at the
    /// median and 1.2ms at the worst, so 2ms clears the measured distribution
    /// while staying far inside the 16.67ms frame budget.
    /// `ZONVIE_COMMIT_GUARD_US` overrides it; 0 disables the wait entirely.
    static let commitGuardBandNs: UInt64 = {
        guard let s = ProcessInfo.processInfo.environment["ZONVIE_COMMIT_GUARD_US"],
              let us = UInt64(s) else { return 2_000_000 }
        // Clamped: this is a main-thread wait, so an unbounded override stalls
        // input for as long as it names.
        return min(us, 8_000) * 1_000
    }()

    private var commitRevision: UInt64 = 0   // Protected by lock
    private var lastCommitTime: UInt64 = 0   // Protected by lock — mach_absolute_time() of last commit
    private var lastDrawnRevision: UInt64 = 0 // Render thread only
    /// Revision whose guard band already ran to its deadline without a commit
    /// arriving. Render thread only.
    private var guardBandTimedOutRevision: UInt64 = .max
    // Whether the most-recently-rendered frame had an active scroll offset,
    // which extends smoothScrolling for one frame past the offset reaching zero
    // (as ExternalGridView's wasScrollOffsetActiveInLastPresentedFrame does).
    // Without it a frame that both clears the offset and carries a grid_scroll
    // blits pixels already rendered with a shader offset: a 1-row jitter.
    private var gpuInFlightCount: [Int] = [0, 0, 0]  // Protected by lock
    private var rowStorageRetirement = SurfaceRowStorageRetirementState() // Protected by lock
    private var cursorGpuInFlightCount: [Int] = [0, 0, 0] // Protected by lock
    /// This surface's background: the 8-bit colour the row bands paint with.
    /// The clear colour is built from it where it is used, as on
    /// ExternalGridView, which additionally stores the alpha the app hands it —
    /// this surface derives that from `blurEnabled` instead. Protected by `lock`.
    private var surfaceBgRGB: UInt32 = 0

    /// Complete one protected GPU read and immediately service any contraction
    /// that had to skip this set while it was in flight. Caller holds `lock`.
    /// Shared with ExternalGridView; this surface has main vertex buffers to
    /// retire and an external one does not.
    private func completeSurfaceGpuReadLocked(_ setIndex: Int) {
        completeSurfaceGpuRead(
            setIndex: setIndex,
            gpuInFlightCount: &gpuInFlightCount,
            bufferSets: bufferSets,
            committedSetIndex: committedSetIndex,
            retirement: &rowStorageRetirement,
            retireMainBuffers: true
        )
    }

    /// Buffer at the given physical slot in whichever set is currently GPU
    /// in-flight, or nil when none. With semaphore=1 at most one set is
    /// in-flight at any instant (the completion handler decrements under
    /// lock BEFORE signaling). Buffer objects only alias across sets at the
    /// same physical slot index: shallow copies preserve array positions and
    /// slot remaps permute the logical->slot mapping, not the buffers array.
    /// Must be called from the core thread during flush (the in-flight set
    /// is never the write set, so its rowState is stable while we read it).
    private func inflightRowBuffer(gridId: Int64, atSlot slot: Int) -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let sets = gridBuffers.existingSets(for: gridId) else { return nil }
        for i in 0..<3 where gpuInFlightCount[i] > 0 {
            let bufs = sets[i].rowState.buffers
            return slot < bufs.count ? bufs[slot] : nil
        }
        return nil
    }

    /// The root grid's in-flight buffer at `slot`. Every grid rotates through
    /// the same set indices, so `gpuInFlightCount` selects the in-flight set
    /// for any of them.
    private func inflightRowBuffer(atSlot slot: Int) -> MTLBuffer? {
        inflightRowBuffer(gridId: 1, atSlot: slot)
    }

    /// Main vertex buffer of the set currently GPU in-flight (see
    /// inflightRowBuffer(atSlot:) for the invariants).
    private func inflightMainBuffer() -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<3 where gpuInFlightCount[i] > 0 {
            return bufferSets[i].mainVertexBuffer
        }
        return nil
    }

    // Drawable size from the most recent committed flush.
    // Set by commitFlush() (core thread, grid_mu held) by reading the core's
    // layout directly — this guarantees the values match the NDC coordinates
    // baked into the committed vertices.
    // draw() uses these to set the Metal viewport, preventing stretching when
    // drawableSize changes between flushes.
    /// Shared with ExternalGridView. This surface measures in DRAWABLE PIXELS:
    /// its grid is the window, so the viewport comes from the drawable size.
    /// Protected by `lock`.
    private var committedExtent = SurfaceCommittedExtent()
    // Layout associated with the last committed MAIN state. Cursor-only
    // commits also refresh committedDrawable*, so they cannot be used to
    // decide whether sparse row metadata crossed a layout transition.
    private var mainRowStateDrawableW: UInt32 = 0 // Core thread only
    private var mainRowStateDrawableH: UInt32 = 0 // Core thread only

    private var committedAtlasTexture: MTLTexture?  // Protected by lock

    private var backingScale: CGFloat = surfaceFallbackBackingScale

    var onCellMetricsChanged: ((Float, Float) -> Void)?

    /// Called at the beginning of each draw call, before rendering.
    /// Used to process pending scroll clears from grid_scroll events.
    var onPreDraw: (() -> Void)?

    /// Called immediately before the committed vertex set is latched for this
    /// frame, after the guard band has had its chance to catch a commit that
    /// was still arriving. onPreDraw runs too early to see such a commit: the
    /// scroll reconciliation it carries would land a frame after the rows it
    /// pays for. A no-op on a frame where nothing was published in between.
    var onBeforeCommittedSnapshot: (() -> Void)?

    /// Called at the end of a successful commitFlush, on the core thread with
    /// no renderer lock held. A scroll reconciliation is staged while the flush
    /// runs and released here, so it reaches the first drawn frame that shows
    /// the rows it accounts for — not an earlier one, which moves the picture
    /// back for a frame, and not a later one, which overshoots by a row.
    var onCommitPublished: (() -> Void)?

    private var lastCellWidthPx: Float = 0
    private var lastCellHeightPx: Float = 0

    /// Fan a cell-metric change out to every surface, at most once per change.
    ///
    /// Both `draw(in:)` and the callbacks that change the metrics (guifont,
    /// linespace) call this; whichever observes the change first does the work.
    /// It used to live inline in `draw(in:)` alone, past the occlusion
    /// early-return, so a minimized or covered main window left every external
    /// window at the old size while the core had already regenerated their rows
    /// at the new one.
    ///
    /// `shared.cellWidthPx` / `shared.cellHeightPx` take leaf locks inside
    /// `shared`, so they are read before `lock` is taken here.
    func notifyCellMetricsIfChanged() {
        let cw = shared.cellWidthPx
        let ch = shared.cellHeightPx
        lock.lock()
        let changed = cw != lastCellWidthPx || ch != lastCellHeightPx
        if changed {
            lastCellWidthPx = cw
            lastCellHeightPx = ch
            // The back texture now holds pixels laid out at the OLD cell size,
            // and a metrics change does not resize the drawable — so
            // `ensureBackBuffer` does not fire and nothing else drops this
            // latch. Every row the new layout covers is redrawn, but a layout
            // that got SHORTER leaves a strip below it that no row reaches, and
            // `.load` would keep the old pixels there. ExternalGridView has
            // always cleared this from `notifyFontChanged`; the main surface
            // was only ever told to redraw.
            hasPresentedOnce = false
        }
        lock.unlock()
        guard changed, let cb = onCellMetricsChanged else { return }
        DispatchQueue.main.async { cb(cw, ch) }
    }

    func setBackingScale(_ s: CGFloat) {
        lock.lock()
        backingScale = s
        lock.unlock()
        shared.setBackingScale(s)
    }

    /// Cell width in drawable pixel coordinates.
    var cellWidthPx: Float { shared.cellWidthPx }

    /// Cell height in drawable pixel coordinates, `linespace` included.
    var cellHeightPx: Float { shared.cellHeightPx }


    var currentFontName: String { shared.atlas.currentFontName }

    var currentPointSize: CGFloat { shared.atlas.currentPointSize }

    // Phase 2: Core-managed atlas pass-through

    func rasterizeGlyphOnly(scalar: UInt32, styleFlags: UInt32, corePtr: OpaquePointer?, outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>) -> Bool {
        return shared.atlas.rasterizeOnly(scalar: scalar, styleFlags: styleFlags, corePtr: corePtr, outBitmap: outBitmap)
    }

    /// Classifies an upload that did not actually happen so the C callback can
    /// abort every failure, but rebuild only for terminal atlas damage. See
    /// GlyphAtlas.uploadRegion's doc comment for the cache-publication contract.
    @discardableResult
    func uploadAtlasRegion(destX: UInt32, destY: UInt32, width: UInt32, height: UInt32, bitmap: UnsafePointer<zonvie_glyph_bitmap>) -> GlyphAtlas.UploadResult {
        shared.atlas.uploadRegion(destX: Int(destX), destY: Int(destY), width: Int(width), height: Int(height), bitmap: bitmap)
    }

    @discardableResult
    func recreateAtlasTexture(width: UInt32, height: UInt32) -> Bool {
        let created = shared.atlas.recreateTexture(width: Int(width), height: Int(height))
        if !created && isInFlush {
            // on_atlas_create has a void C ABI. Latch the failure in the
            // frontend transaction as well as aborting from the callback so
            // on_flush_end can never publish vertices whose UVs belong to the
            // texture generation that failed to allocate.
            flushFailed = true
        }
        return created
    }

    /// Cursor blink phase and what the last frame drew with. Shared with
    /// ExternalGridView; see `SurfaceBlinkState`.
    private var blink = SurfaceBlinkState()
    var cursorBlinkState: Bool {
        get { blink.isVisible(lock: lock) }
        set { blink.setVisible(newValue, lock: lock) }
    }

    // --- Scroll offset for smooth scrolling ---
    // Stored as value-type array under lock; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race during smooth scrolling.
    private var scrollOffsetData: [ScrollOffset] = []
    /// Shared with ExternalGridView. This surface latches the previous frame
    /// when it commits to drawing one (and rolls the latch back if that frame
    /// is then abandoned); an external surface latches when it presents.
    /// Protected by `lock` for the live half, render thread only for the latch.
    private var scrollOffsetLatch = SurfaceScrollOffsetLatch()
    // Exact union of fixed, non-following float rects, represented as disjoint
    // horizontal intervals inside disjoint vertical bands. The fragment shader
    // binary-searches both levels instead of scanning every float per pixel.
    /// This surface's fixed-float mask. Shared with the external surfaces,
    /// which own one each; see SurfaceFixedFloatMask.
    private let fixedFloatMask = SurfaceFixedFloatMask()
    // setFragmentBytes is limited to 4096 bytes. Sixteen arbitrary rectangles
    // produce at most 31 bands and 496 intervals, fitting both buffers. When
    // this limit is exceeded the caller disables smooth scrolling for the
    // frame instead of silently omitting an occluder.
    static let maxFixedFloatRects = 16

    /// On by default, with `ZONVIE_SMOOTH_SCROLL=0` as the way back out without
    /// a rebuild. Two earlier attempts at hiding the row quantisation measured
    /// well and looked wrong, so the escape hatch stays.
    ///
    /// The band that made the third attempt wrong on the glass is fixed: the
    /// shader used to pin the edge row's background quad across the gap the
    /// offset opens, painting it over the retained row's own, so the band showed
    /// one row's glyphs on its neighbour's background colour. The stretch is now
    /// suppressed (`pin_edges`) for a grid whose whole band is retained.
    static let smoothScrollEnabled: Bool =
        ProcessInfo.processInfo.environment["ZONVIE_SMOOTH_SCROLL"] != "0"
    /// Rows kept alive across a smooth-scroll step, shared with every external
    /// grid window through `ScrollRetention` (see MetalTypes.swift).
    private var retention: ScrollRetention!
    private var stagedSmoothScrollSeeds: [(gridId: Int64, rowsDelta: Int)] = []
    private var smoothScrollSeeds: [(gridId: Int64, rowsDelta: Int)] = []
    /// Capture spans for captureRetainedRowForGridScroll, armed on the main
    /// thread as each gesture scroll is sent and read on the core thread when
    /// the resulting grid_scroll arrives. Armed at send time, not at draw
    /// time: Neovim's response can land within a millisecond, before any
    /// frame is drawn, which left every gesture's first row uncaptured.
    private var gridScrollCaptureBounds: [Int64: (top: Int, bottomEx: Int)] = [:]
    /// grid_scroll steps captured by a bracket that has not committed yet.
    /// Cleared by commitFlush; replayed by beginFlush when a bracket aborted
    /// instead. Guarded by `lock`.
    private var pendingRetentionReplay: [(gridId: Int64, rowsDelta: Int)] = []
    /// A run of aborting brackets must not accumulate steps without bound. One
    /// beginFlush replays every pending step, each taking up to `depthRows` ring
    /// buffers, and the ring has no in-flight counter to stop a wrap from
    /// re-handing a buffer a frame is still reading: `maxDepthRows` steps x
    /// `maxDepthRows` rows stays well inside `ringSize`.
    private static let maxPendingRetentionReplay = ScrollRetention.maxDepthRows

    /// Per-grid distance the source set is behind the steps staged so far in
    /// this bracket. Reset every beginFlush. Guarded by `lock`.
    private var bracketSourceShift: [Int64: Int] = [:]

    /// Grids that have opened a retention step in this bracket. Both captures
    /// can see the same movement, and a second beginStep would shift the rows
    /// the first staged twice. Reset every beginFlush. Guarded by `lock`.
    private var bracketStagedGrids: Set<Int64> = []

    // ScrollOffset struct matching Shaders.metal
    struct ScrollOffset {
        var grid_id: Int32
        var offset_y: Float         // Y offset in NDC
        var content_top_y: Float    // Top Y of scrollable content (below margin top), in NDC
        var content_bottom_y: Float // Bottom Y of scrollable content (above margin bottom), in NDC
        var move_all: Int32 = 0     // 1 = translate every vertex of this grid (float bodily move)
        // 1 = stretch the edge row's background across the gap the offset opens.
        // Cleared for a grid whose vacated band is covered by a retained row: the
        // stretch paints the edge row's background over the retained row's own,
        // so the band shows one row's glyphs on its neighbour's background.
        var pin_edges: Int32 = 1
        // The scrolled grid's zindex (0 for windows, > 0 for floats). The
        // fragment guard only discards scrolled content under a STRICTLY
        // higher-z fixed float — see Shaders.metal insideFixedFloatAbove.
        var zindex: Int32 = 0
    }

    // Fixed-float rect in drawable pixel edges, carrying the float's zindex
    // for the z-aware mask (see Shaders.metal insideFixedFloatAbove).
    struct FixedFloatRect: Equatable {
        var x0: Float
        var x1: Float
        var top: Float
        var bottom: Float
        var zindex: Int32
    }

    // Matches Shaders.metal. Bands are sorted from top to bottom; intervals
    // belonging to each band are sorted left to right and do not overlap.
    struct FixedFloatBand {
        var top: Float
        var bottom: Float
        var intervalStart: UInt32
        var intervalCount: UInt32
    }

    struct FixedFloatInterval {
        var x0: Float
        var x1: Float
        // Max zindex of the fixed floats covering this segment; overlapping
        // rects are split at their x edges so one value is always exact.
        var z: Float = 0
    }

    /// Set the fixed (non-following) float rects used by the fragment shader to
    /// keep scrolled content from bleeding over them. Called from the main thread.
    /// Builds the exact rectangle union once per scroll-state update. Returns
    /// false when the exact union cannot be represented by setFragmentBytes;
    /// callers must then disable the scroll transform rather than use a
    /// semantically truncated mask. Persistent arrays retain capacity; COW
    /// only detaches when a draw snapshot is still in flight.
    @discardableResult
    func updateFixedFloatRects(_ rects: [FixedFloatRect]) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return fixedFloatMask.update(rects)
    }

    // (rowVertexBuffers/rowVertexCounts/usingRowBuffers moved into BufferSet for triple buffering)

    /// Maximum row buffer count, bounding worst-case memory growth: row storage
    /// grows lazily per row and neither the C ABI nor Neovim's redraw protocol
    /// imposes a limit, so rows beyond the cap silently stop updating. 20000
    /// rows is ~800KB of bookkeeping — a safety net against a corrupt row index,
    /// not a practical content limit.
    private let maxRowBuffers: Int = metalTerminalMaxRowBuffers

    // --- Dirty region tracking (drawable pixel coordinates) ---
    private var pendingDirtyRectPx: NSRect? = nil
    private var pendingDirtyRows: IndexSet = IndexSet()
    /// The last commit carried a cursor and nothing else, and left no earlier
    /// damage undrawn. `ExternalGridView` calls the same thing `cursorOnlyCommit`
    /// and uses it to reuse the surface instead of clearing it; this is that
    /// state on the main surface, so neither surface has to spend a dirty row to
    /// say "the cursor moved". Cleared by any commit that writes content, and by
    /// a cursor commit that finds rows a draw has not consumed yet — those rows
    /// are the frame's real work and must not be reused over.
    private var pendingCursorOnlyCommit = false
    // Render-thread scratch. Ownership is swapped into draw() for the frame
    // and returned by defer, so appending/scroll expansion reuses capacity
    // without a live property alias that would trigger Array COW detaches.
    private var dirtyRowsScratch: [Int] = []
    /// Per-frame snapshot taken under `lock`, reused across frames. Entry 0 is
    /// this surface's root grid, which every draw loop below skips.
    private var layerSnapshot: [SurfaceLayerFrame] = []
    /// Per-grid dirty/scroll bookkeeping for the surface's non-root layers.
    /// Protected by `lock`; an entry is created when a grid first submits a row
    /// or a scroll and released when the grid is destroyed.
    private var layerDrawStates: [Int64: SurfaceLayerDrawState] = [:]
    /// Rows each layer's committed placement has travelled upwards since the
    /// surface began, in the same units and direction as on_grid_scroll's
    /// rowsDelta. Only commitFlush writes it; copyPlacementRowsUp reads it.
    /// Protected by `lock`.
    private var layerPlacementRowsUp: [Int64: Int] = [:]
    /// The float-debt ledger's anchor half, published with the offsets it
    /// belongs to, and the zero the two halves are compared against. Both are
    /// protected by `lock` and consumed in `applyFloatScrollDebt`.
    private var scrollDebtAnchorRowsUp: [Int32: Int32] = [:]
    private var scrollDebtBaseline: [Int32: FloatDebtBaseline] = [:]
    /// A cell's height in the NDC the offsets above were built in, so the
    /// debt, which is counted in rows, can be paid in them.
    private var scrollDebtCellHeightNDC: Float = 0
    /// The viewport height those NDC were built against. Written under `lock`
    /// with them; draw recovers the shader cursor's pixels from it.
    private var scrollOffsetViewportHeight: Float = 0
    /// Last debt logged per grid. The ledger had no logging at all, and the
    /// `[renderer] scroll offset` line reports the offset BEFORE the debt is
    /// paid, so a float held by the ledger looked identical to one that was
    /// not. One line per transition rather than per frame: a run holds a
    /// handful of distinct debts, and a per-frame line changes the very
    /// timing this pays for.
    private var scrollDebtLastLogged: [Int32: Int32] = [:]
    /// Last value `[main_visibility]` reported, so the line is a transition.
    private var lastWindowHiddenLogged = false

    /// Hand the float ledger the placement travel it needs, into storage the
    /// caller owns, so the per-frame read costs one lock and no allocation.
    func copyPlacementRowsUp(into out: inout [Int64: Int]) {
        lock.lock()
        defer { lock.unlock() }
        out.removeAll(keepingCapacity: true)
        for (gridId, rows) in layerPlacementRowsUp { out[gridId] = rows }
    }

    /// Withhold the part of a following float's compensation that stands for
    /// scroll steps its own placement has not performed — or lend it the part
    /// its placement has already performed and the anchor has not landed yet.
    ///
    /// Called with `lock` held, from the frame's committed snapshot, because
    /// that is the only point where the placement this frame DRAWS and the
    /// counter describing it are the same commit. Built with the offsets
    /// instead, the counter is copied before the flush that publishes the
    /// placement and the snapshot is taken after it, so a float whose
    /// `win_float_pos` arrives a frame ahead of its anchor's `grid_scroll` is
    /// drawn with the debt reading zero — a whole 'mousescroll' step of jump,
    /// then the same jump back when the compensation lands.
    ///
    /// Both counters run from whenever their grid appeared, so the first frame
    /// a float is seen following fixes the zero they are compared against.
    ///
    /// The shader cursor is evaluated from the offsets this leaves, so the
    /// debt withheld from the cursor's grid reaches its effect too.
    private func applyFloatScrollDebt(to snapshot: inout [ScrollOffset]) {
        guard !scrollDebtAnchorRowsUp.isEmpty, scrollDebtCellHeightNDC > 0 else { return }
        for i in snapshot.indices {
            let gid = snapshot[i].grid_id
            guard let anchorRowsUp = scrollDebtAnchorRowsUp[gid] else { continue }
            let placementRowsUp = layerPlacementRowsUp[Int64(gid)] ?? 0
            guard let baseline = scrollDebtBaseline[gid] else {
                scrollDebtBaseline[gid] = FloatDebtBaseline(
                    anchorRowsUp: Int(anchorRowsUp), placementRowsUp: placementRowsUp)
                continue
            }
            // The one definition of this subtraction, the one ScrollRetentionTests
            // pins. Two more had grown beside it.
            let debtRows = Int32(clamping: floatDebtRowsUp(
                anchorRowsUp: Int(anchorRowsUp),
                placementRowsUp: placementRowsUp,
                baseline: baseline
            ))
            if ZonvieCore.appLogEnabled, scrollDebtLastLogged[gid] != debtRows {
                scrollDebtLastLogged[gid] = debtRows
                ZonvieCore.appLog("[float_debt] gridId=\(gid) rows=\(debtRows) anchorUp=\(anchorRowsUp) placeUp=\(placementRowsUp) base=(\(baseline.anchorRowsUp),\(baseline.placementRowsUp))")
            }
            guard debtRows != 0 else { continue }
            // offset_y is NDC and negated against the pixel offset the view
            // built (see computeScrollOffset), so withholding pixels adds here.
            snapshot[i].offset_y += Float(debtRows) * scrollDebtCellHeightNDC
        }
    }

    /// Scratch for commitFlush's per-layer merge; reused so the per-flush walk
    /// does not allocate.
    private var commitGridIdScratch: [Int64] = []
    /// Indices into `retainedSnapshot` belonging to the layer being drawn.
    private var retainedIndexScratch: [Int] = []
    /// The blit rectangles this frame's per-layer scroll copies were accepted
    /// for, in the shared back texture's pixel space. Filled back-to-front so a
    /// layer above one of them can refuse its own shift; kept for its capacity.
    private var acceptedBlitRectsPx: [(leftPx: Int, topPx: Int, rightPx: Int, bottomPx: Int)] = []
    // Dirty marks staged during the current flush bracket (guarded by `lock`;
    // written only on the core thread while isInFlush). A draw() interleaving
    // with a flush consumes pendingDirtyRows BEFORE commitFlush publishes the
    // matching vertices, redrawing them from the OLD committed set and losing
    // the marks; commitFlush re-publishes these so the next draw() picks up the
    // new content. Without an interleave the re-publish is an idempotent union.
    private var flushDirtyRows: IndexSet = IndexSet()
    private var flushDirtyRectPx: NSRect? = nil
    /// Two questions wear this one name, and the merged draw has to keep them
    /// apart.
    ///
    /// **"The back texture holds a frame worth loading"** — what the load-action
    /// and idle gates ask. That becomes true at *submit*, because command
    /// buffers on one queue are ordered and the next frame's `.load` sees this
    /// frame's output. ExternalGridView answers exactly that, and sets its own
    /// flag at submit.
    ///
    /// **"The window is on screen"** — what the deferred guifont flush and the
    /// blur shadow recalculation below ask. That is the GPU completion handler,
    /// which is where this one is set.
    ///
    /// Measured cost of answering the first question with the second: one extra
    /// `.clear` per app launch (one `presented=0` decision in a 50 s capture),
    /// so the conservative answer stays. Noted because the two are not the same
    /// question, and because `hasPresentedOnce` is also cleared on every back
    /// buffer resize — which re-arms the "first present" side effects below
    /// after a window resize. `markFirstPresentDone` has its own latch and is
    /// unaffected; the shadow recalculation does not.
    private var hasPresentedOnce: Bool = false

    /// Previous on-glass presentation time (MTLDrawable.presentedTime, seconds).
    /// Written from presented handlers (Metal internal thread) under `lock`;
    /// only touched when logging is enabled, to measure true present cadence.
    private var lastPresentedTime: CFTimeInterval = 0

    // --- Persistent back buffer (for correct partial redraw) ---
    private var backBuffer: MTLTexture? = nil
    private var backBufferSize: CGSize = .zero
    private let scrollScratch = SurfaceScrollScratchTexture()

    // --- Blur transparency support ---
    private let blurEnabled: Bool
    private var backgroundAlphaBuffer: MTLBuffer?

    // --- Cursor blink support for shader ---
    private var cursorBlinkBuffer: MTLBuffer?

    // --- Post-process bloom (neon glow, Dual Kawase) ---
    // Pipelines and sampler are internal so ExternalGridView can share them.
    /// Attenuates extracted glow by a layer's background coverage, so a glyph
    /// behind an opaque layer does not bloom through it.
    let glowTextures = SurfaceGlowTextures()

    // Shadertoy-style uniforms block (160 bytes, std140). Populated per
    // draw into a local `zonvie_shader_uniforms` value and handed to the
    // pipeline via `setFragmentBytes(_:length:index:)`, so each MTKView
    // (main window, external grids, cmdline, popupmenu) gets its own
    // independent copy with no shared-buffer write race.
    /// Per-view shader timing state. Owned by each MTKView (main +
    /// each ExternalGridView), so iFrame / iTimeDelta / iFrameRate
    /// don't ping-pong with draw order across views that share the
    /// renderer. Cursor state stays on the renderer because it
    /// reflects "the cursor", which is global across views.
    /// Ping-pong render targets for multi-pass shader chains. Allocated
    /// only when pipelines.count > 1. Size matches backBufferSize.
    private let customShaderPong = SurfacePingPongTextures()
    /// Last cursor rect handed to a shader, so the log fires on change only.
    /// Per-surface, because each logs the rect IT hands its own shader.
    private var lastLoggedShaderCursor: (Float, Float, Float, Float) = (0, 0, 0, 0)
    /// Set by the pre-draw when the shader's cursor rect moved; consumed by
    /// this frame's idle gate. Draw thread only.
    private var shaderCursorMovedThisFrame = false

    private func ensureBackBuffer(drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        if backBuffer != nil, backBufferSize == drawableSize { return }

        let oldSize = backBufferSize
        let wasPresented = hasPresentedOnce

        let desc = makeSurfaceTextureDescriptor(
            size: drawableSize,
            pixelFormat: pixelFormat,
            usage: [.renderTarget, .shaderRead]
        )

        backBuffer = shared.device.makeTexture(descriptor: desc)
        // backBufferSize is read from updateCursorShaderStateFromVerts() on
        // the core/RPC thread (to convert cursor NDC coords to pixels) —
        // guard the write with `lock` so that read never sees a stale size
        // paired with a shader-cursor rect computed against a texture that
        // no longer matches it.
        lock.lock()
        backBufferSize = drawableSize
        // After resize, we must clear once (contents undefined).
        hasPresentedOnce = false
        lock.unlock()

        // DEBUG: Track backBuffer resize and hasPresentedOnce reset
        ZonvieCore.appLog("[DEBUG-RESIZE] ensureBackBuffer: oldSize=\(oldSize) newSize=\(drawableSize) wasPresented=\(wasPresented) -> hasPresentedOnce=false")
    }

    /// Allocate the two ping-pong textures used by multi-pass custom
    /// shader chains. Size/format must match the drawable so the final
    /// pass can write the same pixel format the drawable expects.
    init?(view: MTKView, collectsGpuPerfSamples: Bool = true) {
        self.collectsGpuPerfSamples = collectsGpuPerfSamples
        guard let dev = view.device else {
            ZonvieCore.appLog("[Renderer] init failed: MTKView.device is nil")
            return nil
        }
        self.retention = ScrollRetention(device: dev)
        guard let q = dev.makeCommandQueue() else {
            ZonvieCore.appLog("[Renderer] init failed: Failed to create command queue")
            return nil
        }
        self.queue = q
        // Sized once so a new layer grid's first submit never rehashes the
        // dictionary while a frame holds references into it.
        layerDrawStates.reserveCapacity(64)

        // Initial font: walk the config's candidate list (parsed from
        // [font] family using guifont syntax) and pick the first family
        // available on the system. Falls back to Menlo if nothing in
        // the list resolves. The actual `setFont` we run here only
        // primes the atlas; if nvim later sends a `guifont` payload,
        // onGuiFont takes over with its own fallback walk.
        let configSize = ZonvieConfig.shared.font.size > 0 ? ZonvieConfig.shared.font.size : 14.0
        let configCandidates = ZonvieConfig.shared.font.candidates
        let sizeExplicit = ZonvieConfig.shared.font.sizeExplicit
        var pickedName: String
        var pickedSize: Double
        if let picked = ZonvieConfig.pickFirstAvailable(from: configCandidates, skipLogPrefix: "[Renderer] init:") {
            pickedName = picked.name
            pickedSize = sizeExplicit ? configSize : picked.size
        } else {
            // Reached only when the core formatter failed (OOM) and the
            // candidate list is empty, OR none of the listed families
            // are installed. Fall back to whatever single name the
            // back-compat `family` field still carries (Menlo by
            // default), at the configured size.
            pickedName = ZonvieConfig.shared.font.family.isEmpty ? "Menlo" : ZonvieConfig.shared.font.family
            pickedSize = configSize
        }
        let initialFont = pickedName
        let initialSize = pickedSize
        ZonvieCore.appLog("[Renderer] init: initial font='\(initialFont)' size=\(initialSize) (from \(configCandidates.count) candidate(s))")

        // Pull the configured atlas size up-front so GlyphAtlas allocates at the
        // right dimensions immediately, instead of recreating when
        // zonvie_core_set_atlas_size lands during nvim bring-up. The 1024 lower
        // bound matches Config validation.
        let configuredAtlasSize = max(1024, ZonvieConfig.shared.performance.atlasSize)
        guard let builtAtlas = GlyphAtlas(device: dev, fontName: initialFont, pointSize: CGFloat(initialSize), atlasSize: configuredAtlasSize) else {
            ZonvieCore.appLog("[Renderer] init failed: GlyphAtlas init failed")
            return nil
        }
        self.shared = SharedRenderResources(device: dev, atlas: builtAtlas)
        self.blurEnabled = ZonvieConfig.shared.blurEnabled

        super.init()

        ZonvieCore.appLog("[Renderer] init: blurEnabled=\(blurEnabled) ZonvieConfig.shared.blurEnabled=\(ZonvieConfig.shared.blurEnabled) backgroundAlpha=\(ZonvieConfig.shared.backgroundAlpha)")

        // Defer pipeline building to first draw to avoid XPC errors during init
        // when multiple instances start simultaneously
        self.viewForPipeline = view
        shared.buildSampler()

        // Create background alpha buffer for shader
        backgroundAlphaBuffer = shared.device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
        if let buf = backgroundAlphaBuffer {
            var alpha = resolveSurfaceBackgroundAlpha(
                blurEnabled: blurEnabled,
                decoratedSurface: false
            )
            ZonvieCore.appLog("[Renderer] backgroundAlphaBuffer alpha=\(alpha)")
            memcpy(buf.contents(), &alpha, MemoryLayout<Float>.size)
        }

        // Create cursor blink buffer for shader (always visible for main window cursor)
        cursorBlinkBuffer = shared.device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        if let buf = cursorBlinkBuffer {
            var visible: UInt32 = 1
            memcpy(buf.contents(), &visible, MemoryLayout<UInt32>.size)
        }

        if collectsGpuPerfSamples { gpuSampler.setUp(device: shared.device) }
    }

    // (buildScrollOffsetBuffers removed: scroll data now passed via setVertexBytes)

    // MARK: - Triple Buffer Flush Bracket

    /// Called from on_flush_begin callback (core thread).
    /// Deep-copies committed data into write set so partial updates overwrite cleanly.
    /// Picks a buffer set that is not committed and not GPU in-flight.
    ///
    /// The flush bracket, stage by stage, against `ExternalGridView`'s. The
    /// two are not one implementation on purpose: the shared parts
    /// (`pickFreeBufferSetIndex`, `syncSurfaceWriteSetRowState`, the atlas
    /// transaction on `shared`) already are, and what is left differs in
    /// what each surface's root grid IS (see `prepareLayerGridsForWrite`).
    ///
    /// | stage | this surface | ExternalGridView |
    /// |---|---|---|
    /// | begin | drop while row capacity provisions; `retention.beginFlush`; drop the staged shader cursor; reseed the cursor owner | same drop; `carriedDirtyRows`; font generation; `bracketStagedGrids` |
    /// | first row write | `prepareMainWriteState`: pick set, sync rows, `prepareLayerGridsForWrite` | `prepareRowWriteState`: pick set, copy each layer grid's row state, `retention.beginFlush`, capture retained rows, sync rows |
    /// | abort | `endBracketWithoutPublishing`, from all three exits | `cancelFlush` |
    /// | commit | retained rows published; `pendingCursorOnlyCommit` | font generation verdict; `cursorOnlyCommit`; `layoutContracted` |
    ///
    /// `retention.beginFlush` sits at begin here and at the first row write
    /// there because of where each surface CAPTURES: this surface captures on
    /// the grid_scroll callback, which can arrive before any row write, so the
    /// discard has to precede the whole bracket; the external surface captures
    /// in `prepareRowWriteState`, right before the sync overwrites the rows it
    /// copies from, and discards just ahead of that. A cursor-only bracket
    /// therefore discards here and not there.
    enum BeginFlushResult {
        case proceed                   // Normal flush, no special action needed
        case proceedWithInvalidation   // Flush OK, but core glyph cache invalidation needed
        case dropped                   // Flush aborted — core must skip vertex/shared.atlas generation
    }

    func beginFlush() -> BeginFlushResult {
        lock.lock()
        if rowCapacity.blocksDraw {
            lock.unlock()
            ZonvieCore.appLog("[Renderer] beginFlush: waiting for row capacity provisioning")
            return .dropped
        }
        bracketOpen = true
        lock.unlock()
        isInFlush = true
        mainWritePrepared = false
        cursorWritePrepared = false
        // Discard any retention staged by a bracket that aborted instead of
        // committing; publication only ever happens from this bracket's own
        // commitFlush.
        if Self.smoothScrollEnabled {
            retention.beginFlush()
            lock.lock()
            stagedSmoothScrollSeeds.removeAll(keepingCapacity: true)
            lock.unlock()
        }
        flushChangedMainRows.removeAll()
        flushHasStructuralMainChange = false
        layerGridsPreparedThisFlush = false
        // Begin owns this, not the terminators. A bracket has three exits —
        // abortFlush and commitFlush's two deferred returns — and only the
        // first cleared it, so a deferred commit leaked a stale `true` into the
        // next bracket and gave it a `lastCommitTime` it had not earned.
        // ExternalGridView clears its `flushHadContent` at begin for the same
        // reason.
        flushHadLayerWork = false
        let perfEnabled = ZonvieCore.appLogEnabled
        if perfEnabled {
            perfRowSubmitNs = 0
            perfRowSubmitCalls = 0
            perfRowSubmitVerts = 0
        }
        let tBeginFlushStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        var atlasPrepareUs: Double = 0
        var atlasCommitUs: Double = 0
        var atlasDidBlit = false
        var atlasDidCpuSync = false
        var atlasNeedsCoreInvalidation = false
        var atlasSyncedWasRecreate = false

        // Snapshot the row source, but defer all O(rows) COW preparation until
        // the first main/row/scroll mutation. Cursor-only and no-op flushes do
        // not touch the large row metadata arrays.
        lock.lock()
        flushDirtyRows.removeAll()
        flushDirtyRectPx = nil
        flushSourceSetIndex = committedSetIndex
        // Re-seed the pending cursor owner from the committed one, as
        // ExternalGridView.beginFlush does. abortFlush restores it too, but the
        // two deferred returns in commitFlush do not, and the caller does not
        // call abortFlush for them — so a deferred commit carried a stale owner
        // into the retry, where the `count != 0 || pending == id` guards would
        // drop the true owner's cursor clear and leave a cursor drawn where it
        // no longer is.
        cursorOwner.restoreStagedFromCommitted()
        bracketSourceShift.removeAll(keepingCapacity: true)
        bracketStagedGrids.removeAll(keepingCapacity: true)
        let retentionReplay = Self.smoothScrollEnabled ? pendingRetentionReplay : []
        lock.unlock()

        // Re-stage the steps of any bracket that aborted after the core had
        // already handed over its grid_scroll. The source set is the same one
        // those captures read, because an aborted bracket does not commit.
        for step in retentionReplay {
            captureRetainedRowForGridScroll(
                gridId: step.gridId,
                rowsDelta: step.rowsDelta,
                replaying: true
            )
        }

        // The atlas transaction belongs to the flush, not to this surface;
        // SharedRenderResources owns it. What stays here is mapping a refusal
        // onto this bracket's own teardown.
        //
        // OPENED here and CLOSED by ZonvieCore.on_flush_end, which is
        // deliberate rather than an oversight. It opens late, after the guards
        // above have accepted the flush: prepareBackTexture can encode a blit,
        // and a flush this surface was going to drop for row capacity must not
        // pay for one. It closes centrally because EVERY surface's publication
        // depends on the swap, so no single surface may own that decision.
        //
        // The queue handed over is this surface's, and the main window's
        // surface is the one whose bracket the core opens — see the doc comment
        // on beginFlushTransaction for why the blit must ride the queue the
        // main surface draws on.
        var needsCoreInvalidation = false
        switch shared.beginFlushTransaction(queue: queue, perfEnabled: perfEnabled) {
        case .drop(let reason):
            isInFlush = false
            closeBracketFlag()
            ZonvieCore.appLog("[WARNING] beginFlush: \(reason)")
            return .dropped
        case .opened(let opened):
            needsCoreInvalidation = opened.needsCoreInvalidation
            atlasNeedsCoreInvalidation = opened.needsCoreInvalidation
            atlasDidCpuSync = opened.didCpuSync
            atlasSyncedWasRecreate = opened.syncedWasRecreate
            atlasDidBlit = opened.didBlit
            atlasPrepareUs = opened.prepareUs
            atlasCommitUs = opened.commitUs
        }

        if perfEnabled {
            let totalUs = (CFAbsoluteTimeGetCurrent() - tBeginFlushStart) * 1_000_000
            let totalUsStr = String(format: "%.1f", totalUs)
            let atlasPrepareUsStr = String(format: "%.1f", atlasPrepareUs)
            let atlasCommitUsStr = String(format: "%.1f", atlasCommitUs)
            ZonvieCore.appLogPerf(
                "[perf] begin_flush_prepare lazyRows=true atlasDidBlit=\(atlasDidBlit) atlasDidCpuSync=\(atlasDidCpuSync) atlasNeedsCoreInvalidation=\(atlasNeedsCoreInvalidation) atlasSyncedWasRecreate=\(atlasSyncedWasRecreate) atlasPrepareUs=\(atlasPrepareUsStr) atlasCommitUs=\(atlasCommitUsStr) totalUs=\(totalUsStr)"
            )
        }

        return needsCoreInvalidation ? .proceedWithInvalidation : .proceed
    }

    /// Lazily prepare the large row/main state on the first mutation in a
    /// flush. Cursor-only, atlas-only, and no-op flushes never call this.
    @discardableResult
    private func prepareMainWriteState() -> Bool {
        if mainWritePrepared { return true }
        guard isInFlush else { return false }

        lock.lock()
        let picked = pickFreeBufferSetIndex(
            count: 3,
            committedIndex: flushSourceSetIndex,
            gpuInFlightCount: gpuInFlightCount
        )
        if picked == -1 {
            let inf = gpuInFlightCount
            lock.unlock()
            flushFailed = true
            ZonvieCore.appLog("[WARNING] prepareMainWriteState: no free row set committed=\(flushSourceSetIndex) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return false
        }
        writeSetIndex = picked
        lock.unlock()

        let started = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let src = bufferSets[flushSourceSetIndex]
        let dst = bufferSets[picked]
        let sync = syncSurfaceWriteSetRowState(
            from: src,
            to: dst,
            staleRows: staleMainRowsBySet[picked].rows,
            needsFullSync: mainRowStateNeedsFullSync[picked],
            maxRowBuffers: maxRowBuffers
        )

        copySurfaceMainVertexState(from: src, to: dst)
        dst.pendingScroll = nil
        mainWritePrepared = true
        // The write set is two rotations old for every grid, so carry each
        // layer's rows forward: a flush that rewrites only the root must not
        // publish a set whose layers are stale or empty.
        prepareLayerGridsForWrite()

        if ZonvieCore.appLogEnabled {
            let elapsedUs = (CFAbsoluteTimeGetCurrent() - started) * 1_000_000
            ZonvieCore.appLogPerf("[perf] lazy_main_prepare src=\(flushSourceSetIndex) dst=\(picked) mode=\(sync.mode) syncedRows=\(sync.syncedRows) totalRows=\(src.rowState.buffers.count) us=\(String(format: "%.1f", elapsedUs))")
        }
        return true
    }

    /// Reserve a small cursor slot independently from the row triple. Cursor
    /// callbacks fully replace cursor content, so no committed-state copy is
    /// needed before writing the chosen non-in-flight slot.
    @discardableResult
    private func prepareCursorWriteState() -> Bool {
        if cursorWritePrepared { return true }
        guard isInFlush else { return false }

        lock.lock()
        let picked = pickFreeBufferSetIndex(
            count: 3,
            committedIndex: committedCursorSetIndex,
            gpuInFlightCount: cursorGpuInFlightCount
        )
        if picked == -1 {
            let inf = cursorGpuInFlightCount
            lock.unlock()
            flushFailed = true
            ZonvieCore.appLog("[WARNING] prepareCursorWriteState: no free cursor set committed=\(committedCursorSetIndex) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return false
        }
        cursorWriteSetIndex = picked
        lock.unlock()
        cursorWritePrepared = true
        return true
    }

    /// Called after beginFlush() returned .proceed/.proceedWithInvalidation but
    /// the core later called zonvie_core_abort_flush (e.g. recreateTexture failure).
    /// Clears isInFlush so commitFlush becomes a no-op, preventing stale vertices
    /// from being published under the new layout dimensions.
    /// Put this surface's bracket back without publishing. The atlas
    /// transaction is NOT closed here: it belongs to the flush, not to a
    /// surface, and `ZonvieCore` closes it once for every surface.
    func abortFlush() {
        endBracketWithoutPublishing()
    }

    /// Put the surface back as an unpublished bracket found it.
    ///
    /// Three exits need this, not one: `abortFlush`, and commitFlush's two
    /// deferred returns for an atlas transaction that could not close. Those
    /// two used to reset a subset — leaving `pendingSurfaceLayers`, the layers'
    /// staged dirty marks, and (before begin took them) the pending cursor
    /// owner and `flushHadLayerWork` — and the caller does not call
    /// `abortFlush` for them either (`ZonvieCore`'s `!mainCommitted` branch
    /// cancels the external views and retries the core, nothing more).
    private func endBracketWithoutPublishing() {
        if mainWritePrepared {
            // The scratch set may contain any prefix of this flush. It cannot
            // participate in sparse carry-forward until fully overwritten.
            mainRowStateNeedsFullSync[writeSetIndex] = true
            staleMainRowsBySet[writeSetIndex].removeAll()
        }
        flushChangedMainRows.removeAll()
        flushHasStructuralMainChange = false
        // Drop every layer's staged dirty marks: the core re-dirties the grid
        // and resends its rows on the retry. The write sets' stale pendingScroll
        // needs no cleanup here — the next bracket's prepareLayerGridsForWrite
        // copies fresh row state over each layer set, and that copy resets it.
        lock.lock()
        for state in layerDrawStates.values {
            state.flushDirtyRows.removeAll()
        }
        pendingSurfaceLayers = nil
        cursorOwner.restoreStagedFromCommitted()
        lock.unlock()
        flushHadLayerWork = false
        mainWritePrepared = false
        cursorWritePrepared = false
        isInFlush = false
        closeBracketFlag()
    }

    /// Called from on_flush_end callback (core thread, grid_mu held).
    /// Atomically makes the write set the new committed set for draw().
    /// drawableW/drawableH are the core's layout at flush time, read via
    /// zonvie_core_get_layout while grid_mu is still held — this guarantees
    /// the values match the NDC coordinates in the committed vertices.
    @discardableResult
    /// Publish this bracket. `publishedAtlasTexture` is the front texture the
    /// flush's transaction swapped in — the caller closed the transaction
    /// before calling this, for every surface at once, because a surface that
    /// published UVs against an unswapped texture would sample the wrong
    /// glyphs.
    func commitFlush(
        drawableW: UInt32,
        drawableH: UInt32,
        publishedAtlasTexture: MTLTexture?,
        defaultBgRGB: UInt32
    ) -> Bool {
        guard isInFlush else { return false }  // Flush was dropped or aborted
        FrameTracer.trace(.commitFlush)

        // Atomically commit atlas (swap if modified) and snapshot front texture.
        // An in-flight back-sync is polled, never waited on under grid_mu.
        let didMainWrite = mainWritePrepared
        let didCursorWrite = cursorWritePrepared
        let ws = writeSetIndex
        let mainLayoutContracted = didMainWrite
            && (bufferSets[flushSourceSetIndex].knownTotalRows > bufferSets[ws].knownTotalRows
                || bufferSets[flushSourceSetIndex].knownTotalCols > bufferSets[ws].knownTotalCols)
        let mainLayoutIsEmpty = didMainWrite
            && (bufferSets[ws].knownTotalRows == 0 || bufferSets[ws].knownTotalCols == 0)
        // Grid ids for the per-layer merge below, taken before `lock`: the
        // registry has its own lock and the established order is
        // lock -> registryLock, so read the list outside that nesting.
        gridBuffers.copyGridIds(into: &commitGridIdScratch)
        // Read here rather than inside the region below for symmetry with the
        // line above, not out of necessity: the accessor takes a leaf lock
        // inside `shared`, so reading it under `lock` would be safe.
        let ledgerCellHeightPx = shared.cellHeightPx
        lock.lock()
        let mainLayoutChanged = didMainWrite
            && (mainRowStateDrawableW != drawableW || mainRowStateDrawableH != drawableH)
        // The background the viewport edges and scroll gaps clear to lands
        // with the rows it belongs to. Set after the commit, a draw in between
        // took the new rows with the old colour and kept it, the commit's
        // revision already spent.
        let bgChanged = surfaceBgRGB != defaultBgRGB
        surfaceBgRGB = defaultBgRGB
        // The core opens this bracket on every flush, including one that only
        // changed an external window. Nothing landed here then, and a new
        // revision would still be a frame this surface cannot skip. An atlas
        // swap is not a landing either: the new texture keeps every glyph the
        // committed UVs name, and the next frame that has work reads it.
        let bracketLanded = didMainWrite || didCursorWrite || flushHadLayerWork
            || pendingSurfaceLayers != nil
            || !flushDirtyRows.isEmpty || flushDirtyRectPx != nil
            || bgChanged
        if didMainWrite {
            committedSetIndex = writeSetIndex
        }
        if didCursorWrite {
            committedCursorSetIndex = cursorWriteSetIndex
        }
        // Layers and the vertices they place become visible together.
        if let staged = pendingSurfaceLayers {
            // A layer that is new, or that moved or changed size, cannot reuse
            // anything the back texture holds for it: its rows are somewhere
            // else now, and a shift computed for the old rectangle would move
            // the wrong pixels.
            accumulateSurfaceLayerPlacementTravel(
                staged: staged,
                committed: committedSurfaceLayers,
                rootGridId: 1,
                cellHeightPx: ledgerCellHeightPx,
                into: &layerPlacementRowsUp
            )
            for layer in staged where layer.gridId != 1 {
                let previous = committedSurfaceLayers.first { $0.gridId == layer.gridId }
                guard let state = layerDrawStates[layer.gridId] else { continue }
                let unchanged = previous.map {
                    $0.originPx == layer.originPx && $0.rows == layer.rows && $0.cols == layer.cols
                } ?? false
                if !unchanged {
                    state.needsFullRedraw = true
                    state.pendingScrollAccum = nil
                }
            }
            committedSurfaceLayers = staged
            pendingSurfaceLayers = nil
            pruneSurfaceLayerLedger(&layerPlacementRowsUp, to: staged)
            pruneSurfaceLayerLedger(&scrollDebtBaseline, to: staged)
            pruneSurfaceLayerLedger(&scrollDebtLastLogged, to: staged)
        }
        if didCursorWrite {
            cursorOwner.commit()
        }
        committedExtent.commit(width: drawableW, height: drawableH)
        committedAtlasTexture = publishedAtlasTexture  // same lock as vertex state
        // Publish this bracket's smooth-scroll retention together with the
        // vertices it belongs to: a retained row shown against pre-scroll
        // content would draw the same line twice.
        let retentionLanded = retention.commit()
        if retentionLanded {
            smoothScrollSeeds.append(contentsOf: stagedSmoothScrollSeeds)
            stagedSmoothScrollSeeds.removeAll(keepingCapacity: true)
        }
        // These steps reached the screen, so there is nothing left to replay.
        pendingRetentionReplay.removeAll(keepingCapacity: true)
        shared.shaderCursor.publishCommitTail(
            committedBy: self,
            publishScrollClears: { onCommitPublished?() },
            commitRevision: &commitRevision,
            bumpRevision: bracketLanded || retentionLanded
        )
        let rev = commitRevision
        serviceSurfaceRowStorageRetirement(
            bufferSets: bufferSets,
            gpuInFlightCount: gpuInFlightCount,
            committedSetIndex: committedSetIndex,
            layoutContracted: mainLayoutContracted,
            state: &rowStorageRetirement,
            retireMainBuffers: mainLayoutIsEmpty
        )
        // Merge each layer grid's staged shift into its own accumulator and
        // publish this bracket's dirty marks. Under `lock` and after
        // committedSetIndex was updated, so draw() never sees a scroll delta
        // that precedes its vertices, and an interleaving draw that already
        // consumed pendingDirtyRows gets those rows back.
        for gridId in commitGridIdScratch where gridId != 1 {
            guard let state = layerDrawStates[gridId] else { continue }
            if didMainWrite,
               let sets = gridBuffers.existingSets(for: gridId),
               let ps = sets[ws].pendingScroll {
                // Marks an earlier bracket left, that no draw has consumed,
                // still name pre-shift rows: this bracket rotated the slots
                // under them. Before the branches below, which mark rows that
                // already describe post-remap content, and before
                // flushDirtyRows is merged in -- those were shifted as they
                // were made.
                shiftSurfaceRowIndices(
                    &state.pendingDirtyRows,
                    rowStart: ps.rowStart,
                    rowEnd: ps.rowEnd,
                    rowsDelta: ps.rowsDelta
                )
                mergeCommittedSurfaceScroll(into: &state.pendingScrollAccum, ps,
                                            dirtyRows: &state.pendingDirtyRows)
                // A committed set must not keep the staged shift, or a later
                // frame would apply it a second time.
                sets[ws].pendingScroll = nil
            }
            if !state.flushDirtyRows.isEmpty {
                state.pendingDirtyRows.formUnion(state.flushDirtyRows)
                state.flushDirtyRows.removeAll()
            }
        }
        // Re-publish dirty marks staged during this flush. A draw() that
        // interleaved with the flush consumed pendingDirtyRows and redrew
        // those rows from the PREVIOUS committed set; without this the rows
        // committed here would never be drawn (and lastCommitTime below
        // would not be updated). Idempotent when no draw() interleaved.
        pendingDirtyRows.formUnion(flushDirtyRows)
        if let staged = flushDirtyRectPx {
            pendingDirtyRectPx = pendingDirtyRectPx?.union(staged) ?? staged
        }
        flushDirtyRows.removeAll()
        flushDirtyRectPx = nil
        // Read the pending sets AFTER this bracket folded into them: a cursor
        // commit that arrives while a content commit still waits for a draw is
        // not a cursor-only frame, and treating it as one loses those rows.
        pendingCursorOnlyCommit = didCursorWrite
            && !didMainWrite
            && !flushHadLayerWork
            && pendingDirtyRows.isEmpty
            && pendingDirtyRectPx == nil
        // Only update lastCommitTime when there are pending visual changes
        // (dirty rows, dirty rect, or a layer's rows/shift). Empty flushes
        // should not prevent the draw loop from deactivating.
        if !pendingDirtyRows.isEmpty || pendingDirtyRectPx != nil || flushHadLayerWork {
            lastCommitTime = mach_absolute_time()
        }
        lock.unlock()
        flushHadLayerWork = false

        if didMainWrite {
            // Only a successful publication advances other sets' sparse
            // history. Aborted scratch mutations are handled by abortFlush's
            // full-sync barrier instead.
            recordCommittedRowMutation(
                stale: staleMainRowsBySet,
                needsFullSync: &mainRowStateNeedsFullSync,
                committedIndex: ws,
                rows: flushChangedMainRows.rows.lazy.map(Int.init),
                structural: flushHasStructuralMainChange || mainLayoutChanged
            )
            mainRowStateDrawableW = drawableW
            mainRowStateDrawableH = drawableH
        }
        flushChangedMainRows.removeAll()
        flushHasStructuralMainChange = false
        mainWritePrepared = false
        cursorWritePrepared = false
        isInFlush = false
        closeBracketFlag()
        if ZonvieCore.appLogEnabled, didMainWrite {
            let bs = bufferSets[ws]
            let rowCount = bs.rowState.buffers.count
            var totalVerts = 0
            for i in 0..<rowCount {
                totalVerts += bs.rowState.counts[i]
            }
            ZonvieCore.appLogScrollMode("[scroll_debug] commitFlush set=\(ws) rows=\(rowCount) totalVerts=\(totalVerts) rev=\(rev)")
            // Aggregate Swift-side row submit cost (memcpy + slot remap) for this flush.
            ZonvieCore.appLogPerf("[perf] row_submit calls=\(perfRowSubmitCalls) verts=\(perfRowSubmitVerts) ns=\(perfRowSubmitNs)")
        }
        return true
    }

    /// Returns true if a flush was committed within the given time window.
    /// Used by the draw loop idle detector to avoid premature deactivation
    /// when flushes complete between vsync intervals.
    func hadRecentCommit(withinNs: UInt64) -> Bool {
        lock.lock()
        let t = lastCommitTime
        lock.unlock()
        return surfaceHadRecentCommit(lastCommitTime: t, withinNs: withinNs)
    }


    /// Update the default Neovim background color (for clear color in viewport edges).
    /// Called from core thread during flush.

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
        if updateMain, !prepareMainWriteState() { return }
        if updateCursor, !prepareCursorWriteState() { return }
        if updateMain {
            flushHasStructuralMainChange = true
        }
        // Write to write set (called during flush, no lock needed for vertex data)
        let s = writeSetIndex
        let cursorSet = cursorWriteSetIndex

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
                ensureCursorBufferInSet(cursorSet, vertexCount: cursorCount)
                if let cvb = cursorSlots[cursorSet].vertexBuffer {
                    memcpy(cvb.contents(), cursorPtr, cursorCount * MemoryLayout<Vertex>.stride)
                    cursorSlots[cursorSet].vertexCount = cursorCount
                } else {
                    cursorSlots[cursorSet].vertexCount = 0
                }
                updateCursorShaderStateFromVerts(cursorPtr: cursorPtr, cursorCount: cursorCount)
            } else {
                cursorSlots[cursorSet].vertexCount = 0
            }
        }
    }

    /// Compute the cursor bounding rectangle and color from its raw
    /// vertex data (grid-local pixels + straight RGBA) and forward the
    /// result into the Ghostty cursor uniform state. Cheap — scans at
    /// most ~12 vertices. Called from the vertex-submit path so the
    /// next shader draw picks up the new iCurrentCursor /
    /// iTimeCursorChange immediately.
    private func updateCursorShaderStateFromVerts(cursorPtr: UnsafeRawPointer, cursorCount: Int) {
        guard cursorCount > 0 else { return }
        let verts = cursorPtr.bindMemory(to: Vertex.self, capacity: cursorCount)
        // Positions are grid-local pixels with y down, but the cursor uniforms
        // the shader reads are screen space, so every layer but the root needs
        // its origin added — otherwise the effect stays at the top-left window
        // whichever split the cursor is in.
        // The same resolve the cursor body is placed with; this used to be a
        // third scan of the layer list, with its own fallback.
        let cursorGridId = verts[0].grid_id
        let layerOriginPx = resolveSurfaceCursorPlacement(
            ownerGridId: cursorGridId,
            rootGridId: 1,
            layers: pendingSurfaceLayers ?? committedSurfaceLayers
        ).originPx
        // backBufferSize is written under `lock` by ensureBackBuffer() (main
        // thread); read it under the same lock here since this runs on the
        // core/RPC thread and a resize can race with this cursor update.
        let (bufW, bufH): (CGFloat, CGFloat) = {
            lock.lock()
            defer { lock.unlock() }
            return (backBufferSize.width, backBufferSize.height)
        }()
        // Before the first ensureBackBuffer() call, backBufferSize is still
        // .zero — skip computing nonsensical (0,0,0,0) cursor-shader uniforms;
        // the next call (once a real size is known) will compute correctly.
        guard bufW > 0, bufH > 0 else { return }
        // The core's bounds, with the origin folded in: the same rectangle
        // the Windows driver hands its shader and its damage from.
        var rect = zonvie_cursor_rect()
        guard zonvie_core_cursor_rect(
            cursorPtr.assumingMemoryBound(to: zonvie_vertex.self),
            cursorCount,
            layerOriginPx.x,
            layerOriginPx.y,
            &rect
        ) else { return }
        // Ghostty's cursor shaders treat iCurrentCursor.y as the BOTTOM
        // edge of the cursor rect (center = y - h/2, rect = y-h..y).
        // Pass bottom-edge so the SDF renders over the actual cursor.
        let c0 = verts[0].color
        shared.shaderCursor.stage(
            rect: (rect.left, rect.bottom, rect.right - rect.left, rect.bottom - rect.top),
            color: (c0.x, c0.y, c0.z, c0.w),
            gridId: verts[0].grid_id,
            by: self
        )
    }

    func setLineSpace(px: Int32) {
        // Kept signed: cellHeightPx floors the row height that results.
        shared.setLineSpace(px: px)
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
        // When false, the fragment shader does not clip scrolled content to the
        // grid's own bounds. Used for float windows that must translate bodily
        // (frame + content) by the underlying window's sub-cell scroll offset,
        // rather than scroll their content within a fixed frame.
        var clipToContent: Bool = true
        // The scrolled grid's zindex (0 for windows, > 0 for floats). The
        // fixed-float guard only discards this grid's scrolled content under
        // fixed floats with a STRICTLY higher zindex, so a float scrolling
        // above its own backdrop keeps drawing.
        var zindex: Int32 = 0
        // Rows the anchor this float follows has landed, for the float debt
        // (see applyFloatScrollDebt). Non-nil only for a following float, and
        // raw rather than differenced: the other half of the subtraction is
        // only readable under this renderer's lock, so the subtraction itself
        // has to happen there.
        var debtAnchorRowsUp: Int32? = nil
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

        let count = offsets.count
        ZonvieCore.appLog("[renderer] updateScrollOffsets: count=\(count) drawableHeight=\(drawableHeight)")

        lock.lock()
        defer { lock.unlock() }

        // Reuse scrollOffsetData's own storage (removeAll + append) instead
        // of building a fresh array via offsets.map and assigning it: this
        // only allocates when draw(in:)'s scrollSnapshot from an in-flight
        // frame still holds this buffer's previous storage (a genuine,
        // unavoidable thread-safety copy — see updateFixedFloatRects for
        // the same reasoning), not unconditionally on every scrolled frame.
        scrollOffsetData.removeAll(keepingCapacity: true)
        scrollOffsetData.reserveCapacity(offsets.count)
        scrollDebtAnchorRowsUp.removeAll(keepingCapacity: true)
        scrollDebtCellHeightNDC = cellHeightNDC
        scrollOffsetViewportHeight = drawableHeight
        for info in offsets {
            if let anchorRowsUp = info.debtAnchorRowsUp {
                scrollDebtAnchorRowsUp[Int32(clamping: info.gridId)] = anchorRowsUp
            }
            scrollOffsetData.append(Self.computeScrollOffset(
                info: info,
                viewportHeight: drawableHeight,
                cellHeightPx: cellHeightPx
            ))
        }
        // Shaders.metal uses binary search for the per-vertex grid lookup.
        // Sort the renderer-owned buffer after conversion so every draw pass
        // (main, extract, and cursor) observes the same ordering contract.
        scrollOffsetData.sort { $0.grid_id < $1.grid_id }

        // Prune before the pin decision below, so `coversBand` is asked about
        // rows this frame will actually draw. `draw(in:)` applies the same rule
        // again on the frames this function does not run at all — which is
        // every frame once nothing is easing.
        retention.pruneUndisplaced(offsets: scrollOffsetData, seedGrids: smoothScrollSeeds)
        retention.releaseCoveredPins(&scrollOffsetData, cellHeightNDC: cellHeightNDC)
        for i in scrollOffsetData.indices {
            let gid = Int64(scrollOffsetData[i].grid_id)
            // Logged AFTER the pin decision so pin/retained carry the values
            // a frame actually renders with — the GUI harness derives the
            // margin band and asserts retained-row band coverage from these
            // fields, mirroring the [ExternalGridView] scroll offset line.
            let info = offsets.first { $0.gridId == gid }
            ZonvieCore.appLog("[renderer] scroll offset: gridId=\(gid) offsetYPx=\(info?.offsetYPx ?? 0) marginTop=\(info?.marginTop ?? 0) marginBottom=\(info?.marginBottom ?? 0) ndc=\(scrollOffsetData[i].offset_y) top=\(scrollOffsetData[i].content_top_y) bot=\(scrollOffsetData[i].content_bottom_y) pin=\(scrollOffsetData[i].pin_edges) retained=\(retention.publishedCount(gridId: gid)) gridTop=\(info?.gridTopYNDC ?? 0) cellNDC=\(cellHeightNDC) vpH=\(drawableHeight)")
        }

        // Store as value-type array; draw() will snapshot and pass via setVertexBytes.
        // This eliminates the GPU/CPU race on shared MTLBuffers.
        scrollOffsetLatch.setActive(count > 0)
    }

    /// Arm (or, with a nil span, disarm) the retention capture for a grid.
    /// See gridScrollCaptureBounds.
    func setGridScrollCaptureBounds(gridId: Int64, bounds: (top: Int, bottomEx: Int)?) {
        lock.lock()
        defer { lock.unlock() }
        if let bounds, bounds.bottomEx > bounds.top {
            gridScrollCaptureBounds[gridId] = bounds
        } else {
            gridScrollCaptureBounds.removeValue(forKey: gridId)
        }
    }

    func clearScrollOffsets() {
        lock.lock()
        defer { lock.unlock() }

        // Unreachable: its one caller, MetalTerminalView.clearAllScrollOffsets,
        // has no callers of its own. See that function's note before relying on
        // any of this running.
        scrollOffsetData = []
        scrollOffsetLatch.setActive(false)
        // The spans describe the layout this reset abandons.
        gridScrollCaptureBounds.removeAll(keepingCapacity: true)
        // A parked step describes the same abandoned layout, and would be
        // replayed against post-reset bounds and a post-reset source set.
        pendingRetentionReplay.removeAll(keepingCapacity: true)
        bracketSourceShift.removeAll(keepingCapacity: true)
        // Retained rows were built for the layout being abandoned.
        retention.clearPublished()
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

        // Content bounds in NDC, used only for fragment-level clipping of
        // scrolled content that lands in a margin; the scroll decision itself
        // is flag-based (DECO_SCROLLABLE in the vertex data). A float
        // (clipToContent == false) translates bodily, so widen the bounds past
        // the screen and clip nothing.
        let contentTopY = info.clipToContent ? (info.gridTopYNDC - Float(info.marginTop) * cellHeightNDC) : 2.0
        let contentBottomY = info.clipToContent ? (info.gridTopYNDC - Float(info.gridRows - info.marginBottom) * cellHeightNDC) : -2.0

        return ScrollOffset(
            grid_id: Int32(truncatingIfNeeded: info.gridId),
            offset_y: ndc,
            content_top_y: contentTopY,
            content_bottom_y: contentBottomY,
            move_all: info.clipToContent ? 0 : 1,
            zindex: info.zindex
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Frame-timing trace. Covers every exit path via defer so early
        // returns (semaphore busy, no drawable, row-capacity gate) still show
        // up as a bounded draw in the timeline.
        if FrameTracer.enabled {
            FrameTracer.trace(.drawBegin)
        }
        defer {
            if FrameTracer.enabled {
                FrameTracer.trace(.drawEnd)
            }
        }
        // Drive key-repeat synthesis off the render clock (main thread; 60Hz
        // while the continuous draw loop is active). No-op unless armed.
        (view as? MetalTerminalView)?.tickKeyRepeatSynthesis()
        if ZonvieCore.appLogEnabled,
           let inputTrace = (view as? MetalTerminalView)?.core?.currentInputTraceSnapshot(),
           inputTrace.seq != 0,
           inputTrace.sentNs != 0,
           inputTrace.lastDrawStartLoggedSeq != inputTrace.seq
        {
            let nowNs = zonvie_core_perf_now_ns()
            let deltaUs = max(Int64(0), (nowNs - inputTrace.sentNs) / 1_000)
            ZonvieCore.appLogPerf("[perf_input] seq=\(inputTrace.seq) stage=draw_start delta_us=\(deltaUs)")
            (view as? MetalTerminalView)?.core?.markInputTraceDrawStartLogged(seq: inputTrace.seq)
        }
        // Skip all rendering while this window is not on screen.
        // Metal's currentDrawable blocks/crashes when the window is in the
        // Dock, and onPreDraw accesses the Zig core (unnecessary CPU work).
        // A fully covered window has the same problem for the same reason —
        // it stops being composited, so its layer never recovers the
        // drawables it presented — and an animating custom shader keeps
        // asking for a frame every vsync regardless of visibility.
        // ExternalGridView.draw carries the same guard, where the block was
        // first measured at ~1s per attempt.
        let windowIsHidden = view.window.map {
            $0.isMiniaturized || !$0.occlusionState.contains(.visible)
        } ?? false
        if windowIsHidden != lastWindowHiddenLogged {
            lastWindowHiddenLogged = windowIsHidden
            // A transition, not a frame: this path returns before
            // `[draw] draw(in:) called`, so a window the server calls hidden
            // leaves a gap in the draw series that is indistinguishable from a
            // main thread blocked in `currentDrawable`. Both are ~1s in the
            // field, and only this line tells them apart.
            ZonvieCore.appLog("[main_visibility] hidden=\(windowIsHidden) miniaturized=\(view.window?.isMiniaturized ?? false)")
        }
        if windowIsHidden {
            // Drain the scroll clears anyway: they are appended from the core
            // thread and drained ONLY inside draw(), so a window left covered
            // for an hour with a background :terminal scrolling would leave an
            // unbounded array and an O(external x N) scan for the first frame
            // back. Lock and dictionary work, not GPU work.
            (view as? MetalTerminalView)?.processPendingScrollClears()
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
            _ = shared.ensurePipelineReady(view: view)

            // Graceful degradation: if GPU initialization failed, skip rendering
            guard shared.pipeline != nil, shared.sampler != nil else {
                if let error = shared.initializationError {
                    ZonvieCore.appLog("[draw] Skipping render due to initialization error: \(error)")
                }
                (view as? MetalTerminalView)?.notifyDrawIdle()
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Keep the vsync draw loop alive while any custom shader references
            // animation-driving uniforms (iTime etc.). A missing pipeline must
            // not reset the idle counter every frame.
            if shared.anyCustomShaderNeedsAnimation {
                (view as? MetalTerminalView)?.activateSurfaceDrawLoop()
            }

            if view.drawableSize.width <= 0 || view.drawableSize.height <= 0 {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Keep the last exact-size frame while AppKit is live-resizing.
            // Recreating back/scratch/ping-pong textures for every size tick
            // creates a stream of IOAccelerator resources. Do this before the
            // committed/dirty snapshots below so no render state is consumed;
            // viewDidEndLiveResize requests one exact-size full redraw.
            if view.inLiveResize, backBuffer != nil, backBufferSize != view.drawableSize {
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Continuous-scroll guard band.
            //
            // Traced measurement (Release, held-key scroll): every dropped
            // frame was a near miss. The commit landed 0.07-1.1ms (median
            // ~0.2ms) after this draw had already concluded "nothing changed"
            // and bailed, so the content sat until the next vsync — the 33ms
            // on-glass gap that reads as a stutter. draw(in:) spends ~0.3ms of
            // the 16.67ms budget, so the slack to absorb this is already there.
            //
            // Only a frame that would otherwise be dropped can wait, and only
            // while a scroll is actually in progress, so a genuinely idle
            // screen still bails immediately. The wait ends the moment the
            // commit lands; the bound only caps a genuinely late producer.
            if Self.commitGuardBandNs > 0 {
                lock.lock()
                var revision = commitRevision
                lock.unlock()
                if revision == lastDrawnRevision, revision != guardBandTimedOutRevision,
                   hadRecentCommit(withinNs: 50_000_000) {
                    let start = FrameTracer.nowNs()
                    let deadline = start + Self.commitGuardBandNs
                    while FrameTracer.nowNs() < deadline {
                        // Short enough to catch a ~200us miss, long enough not
                        // to spin the main thread hot.
                        usleep(100)
                        lock.lock()
                        revision = commitRevision
                        lock.unlock()
                        if revision != lastDrawnRevision { break }
                    }
                    if revision == lastDrawnRevision {
                        // The band ran out with no commit, so the producer is not
                        // merely a few hundred microseconds late. hadRecentCommit
                        // is a trailing window, so without this every frame for
                        // the rest of it would burn the full band for nothing —
                        // ~3 frames after each scroll stop at 60Hz.
                        guardBandTimedOutRevision = revision
                    }
                    if FrameTracer.enabled {
                        FrameTracer.trace(
                            .commitGuardBand,
                            a: revision != lastDrawnRevision ? 1 : 0,
                            b: FrameTracer.nowNs() - start
                        )
                    }
                }
            }

            // Acquire the GPU slot BEFORE marking gpuInFlightCount, or a
            // slot-blocked draw() inflates it and beginFlush() sees every set as
            // in-flight. Non-blocking because draw(in:) runs on the MAIN thread
            // and waiting here stalls input for the duration (measured up to
            // ~6.7ms under blur); a busy slot skips the tick and re-requests a
            // redraw, having consumed nothing. This does NOT remove the
            // acquire-drawable wait below — CAMetalLayer has no non-blocking
            // nextDrawable.
            if inflightSemaphore.wait(timeout: .now()) != .success {
                FrameTracer.trace(.drawSkipSemaphore)
                ZonvieCore.appLogPerf("[perf] draw_semaphore_busy skip=true")
                (view as? MetalTerminalView)?.didDrawFrame()
                (view as? MetalTerminalView)?.requestRedraw()
                return
            }

            // === PERF LOG: lock取得開始 ===
            var t_lock_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_lock_start = CFAbsoluteTimeGetCurrent()
            }

            // --- Single lock: read committed index + pending state + mark GPU in-flight ---
            // This prevents beginFlush() from picking our committed set as its write target.
            let csi: Int
            let cci: Int
            let currentCommitRevision: UInt64
            let atlasTex: MTLTexture?
            let dirtyRectPxOpt: CGRect?
            var dirtyRows: [Int] = []
            let smoothScrolling: Bool
            // Raw `scrollOffsetLatch.isActive` at snapshot time (NOT the
            // combined smoothScrolling). Latched as the previous frame
            // below so the one-frame extension does not self-latch.
            let hadActiveScrollOffsetThisFrame: Bool
            // Snapshot for setVertexBytes (no GPU/CPU race). `var` for the
            // float debt below, which is COW-free until a float actually owes
            // one — the common frame copies nothing.
            var scrollSnapshot: [ScrollOffset]
            let retainedSnapshot: [RetainedScrollRow]  // Rows kept alive across a smooth-scroll step
            let fixedFloatBandsSnapshot: [FixedFloatBand]  // Snapshots for setFragmentBytes
            let fixedFloatIntervalsSnapshot: [FixedFloatInterval]
            // Whether any layer the committed layout places owes this frame
            // rows, a shift, or a full redraw. The root grid's dirty rows no
            // longer stand in for that.
            var anyLayerWork = false
            let rowLogicalToSlotSnapshot: [Int]
            let rowSlotSourceRowsSnapshot: [Int]
            // Taken under `lock` with the layer list and per-layer buffer sets:
            // the core thread replaces both while this frame is being encoded.
            let cursorLayerOriginSnapshot: simd_float2
            let cursorOwnerGridSnapshot: Int64
            let lastKnownCursorRowSnapshot: Int
            /// The committed state carries a cursor move and nothing else.
            let cursorOnlyCommitSnapshot: Bool

            let snappedBgRGB: UInt32
            let snappedCommittedExtent: SurfaceCommittedExtent
            // The shader cursor's measured rect as of this commit, taken under
            // the same hold as the rows: commitFlush publishes it under `lock`.
            let cursorShaderRawSnapshot: SurfaceShaderCursor.Raw

            // Take in any reconciliation published since onPreDraw ran — most
            // of all the one the guard band just waited for. Its rows are in
            // the set latched below, so it belongs to this frame. Shared with
            // ExternalGridView; returns with `lock` held.
            settleSurfaceAgainstOwnCommit(
                lock: lock,
                commitRevision: { self.commitRevision },
                service: { self.onBeforeCommittedSnapshot?() }
            )
            if rowCapacity.blocksDraw {
                let terminal = rowCapacity.hardFailure
                lock.unlock()
                FrameTracer.trace(.drawSkipRowCapacity)
                inflightSemaphore.signal()
                (view as? MetalTerminalView)?.didDrawFrame()
                // A hard failure is terminal and never cleared, so re-requesting
                // a draw only spins the display link without ever presenting.
                if !terminal {
                    (view as? MetalTerminalView)?.requestRedraw()
                }
                return
            }
            csi = committedSetIndex
            cci = committedCursorSetIndex
            currentCommitRevision = commitRevision
            gpuInFlightCount[csi] += 1  // Prevent beginFlush from using this set
            cursorGpuInFlightCount[cci] += 1

            atlasTex = committedAtlasTexture  // same lock scope as vertex snapshot
            dirtyRectPxOpt = pendingDirtyRectPx
            swap(&dirtyRows, &dirtyRowsScratch)
            dirtyRows.removeAll(keepingCapacity: true)
            dirtyRows.append(contentsOf: pendingDirtyRows)
            cursorOnlyCommitSnapshot = pendingCursorOnlyCommit
            pendingDirtyRectPx = nil
            pendingDirtyRows.removeAll()
            pendingCursorOnlyCommit = false
            // Extend smoothScrolling one frame past the offset reaching zero:
            // the back buffer still holds pixels rendered with a non-zero shader
            // offset, and blitting those again is a 1-row jitter.
            hadActiveScrollOffsetThisFrame = scrollOffsetLatch.isActive
            smoothScrolling = scrollOffsetLatch.isSmoothScrolling
            scrollSnapshot = scrollOffsetData  // Value-type copy (safe across frames)
            cursorShaderRawSnapshot = shared.shaderCursor.rawSnapshot()
            applyFloatScrollDebt(to: &scrollSnapshot)
            // The one evaluation of the shader cursor this frame, against the
            // rect and the displacement of the commit it draws — the same
            // point, and the same rule, as the external surface. The cursor's
            // grid is displaced by whichever entry names it: cursor vertices
            // always carry DECO_SCROLLABLE (flush.zig), and a bodily-moved
            // float (move_all) translates every vertex it owns. A moved rect
            // is whole-surface fragment work, latched for the idle gate below.
            let cursorShaderOffsetPx = surfaceShaderCursorOffsetPx(
                rawGridId: cursorShaderRawSnapshot.gridId,
                ownerGridId: cursorOwner.committed ?? 1,
                offset: scrollSnapshot.first { Int64($0.grid_id) == cursorShaderRawSnapshot.gridId },
                viewportHeightPx: scrollOffsetViewportHeight
            )
            if shared.shaderCursor.evaluate(scrollOffsetPx: cursorShaderOffsetPx, raw: cursorShaderRawSnapshot) {
                shaderCursorMovedThisFrame = true
            }
            // Retire retained rows whose grid is no longer displaced. Also here,
            // not only in updateScrollOffsets: the view skips that function once
            // nothing is easing, so a grid that scrolled without ever being
            // displaced (a page jump, a repaint that seeded nothing) kept its
            // rows for the session and forced its layer to redraw every row.
            // `smoothScrollSeeds` is read under the lock that published them, so
            // an ease that has committed but not been spent keeps its band.
            retention.pruneUndisplaced(offsets: scrollOffsetData, seedGrids: smoothScrollSeeds)
            retainedSnapshot = retention.snapshotPublished()
            fixedFloatBandsSnapshot = fixedFloatMask.bands  // Value-type copies (safe across frames)
            fixedFloatIntervalsSnapshot = fixedFloatMask.intervals
            rowLogicalToSlotSnapshot = bufferSets[csi].rowLogicalToSlot
            rowSlotSourceRowsSnapshot = bufferSets[csi].rowSlotSourceRows
            layerSnapshot.removeAll(keepingCapacity: true)
            for layer in committedSurfaceLayers {
                // Only a grid the committed layout places is consumed. Work
                // staged for one not on screen yet waits for the layout that
                // places it, which marks it fully dirty (see commitFlush).
                let state = layer.gridId == 1 ? nil : layerDrawStates[layer.gridId]
                if let state {
                    state.drawRows.removeAll(keepingCapacity: true)
                    state.drawRows.append(contentsOf: state.pendingDirtyRows)
                    state.pendingDirtyRows.removeAll()
                    state.drawScroll = state.pendingScrollAccum
                    state.pendingScrollAccum = nil
                    state.drawBlitClearBand = nil
                    state.drawAllRows = state.needsFullRedraw
                    state.needsFullRedraw = false
                    if !state.drawRows.isEmpty || state.drawScroll != nil || state.drawAllRows {
                        anyLayerWork = true
                    }
                }
                let layerSets = gridBuffers.existingSets(for: layer.gridId)
                layerSnapshot.append(SurfaceLayerFrame(
                    layer: layer,
                    set: layerSets?.count == 3 ? layerSets?[csi] : nil,
                    state: state
                ))
            }
            cursorLayerOriginSnapshot = committedCursorPlacement.originPx
            cursorOwnerGridSnapshot = cursorOwner.committed ?? 1
            lastKnownCursorRowSnapshot = cursorOwner.committedRootRow
            snappedBgRGB = surfaceBgRGB
            snappedCommittedExtent = committedExtent
            lock.unlock()

            defer {
                dirtyRows.removeAll(keepingCapacity: true)
                swap(&dirtyRows, &dirtyRowsScratch)
            }

            // Safety defer: decrement gpuInFlight + signal semaphore on early return.
            // On normal GPU submission, the completion handler handles cleanup instead.
            var gpuSubmitted = false

            // What this frame owes back whether it reaches the screen or not:
            // the buffer set it read, the cursor slot it read, and the in-flight
            // slot it took. Stated once and used by every path that gives up —
            // the defer below when nothing was submitted, and
            // `submitSurfaceFrameWithoutPresenting` when encoded work has to be
            // committed anyway. It used to be written out at each of six sites.
            //
            // `self` weakly so an abandoned frame does not keep the renderer
            // alive; the lock and semaphore strongly so the release still runs
            // when it is already gone.
            let sem = inflightSemaphore
            let lk = lock
            let releaseFrameState: () -> Void = { [weak self] in
                lk.lock()
                self?.completeSurfaceGpuReadLocked(csi)
                self?.cursorGpuInFlightCount[cci] -= 1
                lk.unlock()
                sem.signal()
            }
            defer {
                if !gpuSubmitted { releaseFrameState() }
            }

            // Now safe to read from committed set (protected by gpuInFlight)
            let committed = bufferSets[csi]
            let committedCursor = cursorSlots[cci]
            let rowBuffersSnapshot = committed.rowState.buffers
            let rowCountsSnapshot = committed.rowState.counts
            let rowMode = committed.rowState.usingRowBuffers
            let committedMainCount = committed.mainVertexCount
            let committedCursorCount = committedCursor.vertexCount

            if FrameTracer.enabled {
                FrameTracer.trace(
                    .frameContent,
                    a: UInt64(dirtyRows.count),
                    b: rowMode ? 1 : 0,
                    seq: UInt32(truncatingIfNeeded: committedMainCount)
                )
            }

            // All values below (csi, currentCommitRevision, scrollSnapshot, dirtyRows)
            // are local snapshots taken under lock above, so they form a consistent set.
            // committed.* fields are safe because gpuInFlightCount protects the buffer set.
            if smoothScrolling && ZonvieCore.appLogEnabled {
                let scrollDesc = scrollSnapshot.map { "g\($0.grid_id):ndc=\(String(format: "%.4f", $0.offset_y))" }.joined(separator: ",")
                ZonvieCore.appLogScrollMode("[scroll_debug] draw set=\(csi) rev=\(currentCommitRevision) rowMode=\(rowMode) dirtyRows=\(dirtyRows.count) scroll=[\(scrollDesc)]")
            }

            // === PERF LOG: lock取得終了 ===
            if ZonvieCore.appLogEnabled {
                let t_lock_end = CFAbsoluteTimeGetCurrent()
                let lock_us = (t_lock_end - t_lock_start) * 1_000_000
                ZonvieCore.appLogPerf("[perf] draw_lock_fetch us=\(String(format: "%.1f", lock_us))")
            }

            ZonvieCore.appLog("draw(fetch): rowMode=\(rowMode) mainCount=\(committedMainCount) cursorCount=\(committedCursorCount) dirtyRectPxOpt=\(String(describing: dirtyRectPxOpt)) dirtyRowsCount=\(dirtyRows.count) hasPresentedOnce=\(hasPresentedOnce) drawableSize=\(view.drawableSize)")

            // Single locked snapshot of hasPresentedOnce for this entire draw
            // call. hasPresentedOnce is also written from the GPU completion-
            // handler thread (unlocked previously); reading it once here
            // (instead of per-branch) keeps all control-flow decisions in this
            // frame consistent even if a completion handler races concurrently.
            let renderStateSnapshot: (hasPresented: Bool, cursorBlink: Bool) = {
                lock.lock()
                defer { lock.unlock() }
                return (hasPresentedOnce, blink.visibleLocked)
            }()
            let hasPresentedOnceSnapshot = renderStateSnapshot.hasPresented
            let cursorBlinkStateSnapshot = renderStateSnapshot.cursorBlink

            notifyCellMetricsIfChanged()
            let cw = shared.cellWidthPx
            let ch = shared.cellHeightPx

            // With triple buffering, counts come directly from committed set
            let currentMainCount = committedMainCount
            let currentCursorCount = committedCursorCount

            // If rowMode, we may not have a single "currentMainCount"; rows drive it.
            if !rowMode && currentMainCount <= 0 && currentCursorCount <= 0 {
                FrameTracer.trace(.drawSkipNoChange, a: 1)
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            let blinkStateChanged = cursorBlinkStateSnapshot != blink.lastRendered

            // Check if committed data changed since last draw
            let hasNewCommit = currentCommitRevision != lastDrawnRevision

            // Check if drawable size changed since last render (window resize).
            // Must re-render with current viewport even if vertices haven't changed,
            // otherwise macOS stretches the old frame to the new window size.
            let drawableSizeChanged = surfaceDrawableSizeChanged(
                backBufferSize: backBuffer == nil ? nil : backBufferSize,
                drawableSize: view.drawableSize
            )

            // "Blink-only frame" = blinkStateChanged is the ONLY change this draw.
            // Used both for skipMainPass later AND for the cursor==0 skipFrame
            // early-return below — defined here so both can share the predicate
            // safely (the early-return must NOT trigger when there are dirty
            // rows / dirtyRectPxOpt / new commits / scroll, otherwise we drop
            // updates already consumed under the lock).
            let isBlinkOnlyFrame = blinkStateChanged
                && !hasNewCommit
                && dirtyRows.isEmpty
                && !anyLayerWork
                && dirtyRectPxOpt == nil
                && !smoothScrolling
                && !drawableSizeChanged
                && hasPresentedOnceSnapshot

            // If nothing changed, do not encode/present a new frame.
            // MTKView may call draw(in:) for reasons other than Neovim "flush" (e.g. window expose).
            //
            // Exception: when a loaded custom shader references time-varying
            // uniforms (iTime etc.), we MUST proceed every frame so the
            // shader pass sees an advancing clock. Otherwise the shader only
            // runs on Neovim flushes and the animation appears frozen
            // between keystrokes.
            // Shared with ExternalGridView: SurfaceIdleTerms holds every term
            // either surface has, and the ones this surface does not have
            // (a staged scroll, a scroll-offset latch, an unpublished cursor
            // flag) stay at defaults that cannot block a skip. `rowMode` is
            // settled by the whole-grid gate above, so it passes true.
            let idleTerms = SurfaceIdleTerms(
                hasPresentedOnce: hasPresentedOnceSnapshot,
                hasNewCommit: hasNewCommit,
                hasDirtyRows: !dirtyRows.isEmpty,
                hasDirtyRect: dirtyRectPxOpt != nil,
                hasLayerWork: anyLayerWork,
                isSmoothScrolling: smoothScrolling,
                blinkStateChanged: blinkStateChanged,
                drawableSizeChanged: drawableSizeChanged,
                shaderAnimates: shared.anyCustomShaderNeedsAnimation,
                shaderCursorMoved: shaderCursorMovedThisFrame
            )
            let idleGateSkips = idleTerms.skipsFrame
            // The defect this gate term exists for, stated as a check: a frame
            // skipped while the shader is still showing an older cursor rect
            // means nothing will ask for the new one again. It fired fifteen
            // times in a row on a failing run and zero times after the fix, so
            // it is the signal to look for if the effect ever sticks again.
            // Costs one comparison on an already-skipped frame.
            if idleGateSkips, ZonvieCore.appLogEnabled,
               shared.shaderCursor.snapshot().current.0 != lastLoggedShaderCursor.0 {
                ZonvieCore.appLog("[shader_cursor_stale] " + idleTerms.traceLine(surface: 1))
            }
            ZonvieCore.drawTrace(idleTerms.traceLine(surface: 1))
            if idleGateSkips {
                // Still reset redrawPending so future redraws are not blocked.
                FrameTracer.trace(.drawSkipNoChange, a: 2)
                (view as? MetalTerminalView)?.notifyDrawIdle()
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Blink toggled with no cursor to draw: the toggle is invisible in
            // either state, so the whole draw cycle — drawable acquire, copy
            // pass (~2.9ms), present, next-vsync wake — is wasted. Skip and
            // acknowledge the toggle so blinkStateChanged stops firing. Common
            // when the cursor is hidden (t_vi, long-running commands).
            //
            // isBlinkOnlyFrame already covers !hasNewCommit, dirtyRows.isEmpty,
            // !anyLayerWork, dirtyRectPxOpt == nil, !smoothScrolling,
            // !drawableSizeChanged and hasPresentedOnce — critical, because
            // those were consumed under the lock above and skipping without
            // checking them would lose the update.
            if rowMode
                && isBlinkOnlyFrame
                && currentCursorCount == 0
                && !shared.anyCustomShaderNeedsAnimation {
                blink.lastRendered = cursorBlinkStateSnapshot
                FrameTracer.trace(.drawSkipNoChange, a: 4)
                ZonvieCore.appLog("[draw] skipFrame=true (blink toggle with no cursor; draw cycle skipped)")
                (view as? MetalTerminalView)?.notifyDrawIdle()
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Drawable resized but no new commit yet — draw anyway. The snapped
            // viewport (drawableWi/drawableHi below) renders the last committed
            // vertices at their true pixel size in the upper-left and .clear
            // fills the rest. Skipping instead lets the compositor stretch the
            // previously-presented frame, which is what the user stares at when
            // nvim is busy (lazy.nvim blocking the main loop for 1-2 seconds).
            // Safe because the snapped viewport matches the dw/dh the core used
            // for those vertices — both compute (drawable / cell) * cell.

            // Rendering will proceed — reset active draw loop idle counter.
            (view as? MetalTerminalView)?.notifyDrawActive()

            // Snapshot pre-frame skip-gate state so an acquisition failure
            // below (bailWithoutSubmit) can un-consume it for retry.
            let prevDrawnRevision = lastDrawnRevision
            var prevDrawnHadActiveScrollOffset = false
            let prevRenderedBlinkState = blink.lastRendered

            // Track that we've consumed this revision
            lastDrawnRevision = currentCommitRevision
            // Latch the raw active flag, NOT the combined
            // smoothScrolling: the combined value would latch true forever.
            prevDrawnHadActiveScrollOffset = scrollOffsetLatch.latch(hadActiveScrollOffsetThisFrame)

            // Update last rendered blink state since we're proceeding with render
            blink.lastRendered = cursorBlinkStateSnapshot


            // --- Step 2: Pre-compute shared values for loadAction gate and draw branching ---
            let cellWi = max(1, UInt32(cw.rounded(.up)))
            let cellHi = max(1, UInt32(ch.rounded(.up)))
            let (drawableWi, drawableHi) = snappedCommittedExtent.resolved(
                liveWidth: max(1, UInt32(view.drawableSize.width)),
                liveHeight: max(1, UInt32(view.drawableSize.height))
            )
            let vpWidth = Double((drawableWi / cellWi) * cellWi)
            let vpHeight = Double((drawableHi / cellHi) * cellHi)
            // The root layer drives the pixel space core vertices arrive in.
            let rootLayerOrigin = layerSnapshot.first?.layer.originPx ?? simd_float2(0, 0)
            let viewportMetrics = SurfaceViewportMetrics(
                viewportWidth: vpWidth,
                viewportHeight: vpHeight,
                drawableSize: view.drawableSize,
                layerOriginPx: rootLayerOrigin
            )

            let use2Pass = blurEnabled && shared.backgroundPipeline != nil && shared.glyphPipeline != nil

            // Logical rows, as on the external surface: the slot a row maps to
            // is bounds-checked per row in resolvedRowState, which is the one
            // place a row's buffers are read.
            let safeRowCount = rowMode ? rowLogicalToSlotSnapshot.count : 0
            // Glow must be checked early — it disables partial-redraw
            // optimizations, because additive bloom accumulates brightness when
            // the back buffer preserves previous glow. It is also disabled for
            // transient smooth-scroll frames: the bloom pass blurs a flattened
            // surface and cannot keep the z-order boundary between shifted
            // content and a fixed float.
            let configuredGlowEnabled = (view as? MetalTerminalView)?.core?.isGlowEnabled() ?? false
            let glowEnabled = configuredGlowEnabled
                && !(smoothScrolling && !fixedFloatBandsSnapshot.isEmpty)

            func resolvedRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow >= 0, logicalRow < safeRowCount else { return nil }
                let slot = rowLogicalToSlotSnapshot[logicalRow]
                guard slot >= 0, slot < rowCountsSnapshot.count, slot < rowBuffersSnapshot.count else { return nil }
                let vc = rowCountsSnapshot[slot]
                guard vc > 0, let vb = rowBuffersSnapshot[slot] else { return nil }
                let sourceRow = slot < rowSlotSourceRowsSnapshot.count ? rowSlotSourceRowsSnapshot[slot] : logicalRow
                // Pixels, y down: vertices live at sourceRow and must appear
                // at logicalRow.
                let translationY = Float(Int(logicalRow) - Int(sourceRow)) * Float(cellHi)
                return (vc, vb, translationY)
            }

            // Rows retained across a smooth-scroll step are drawn as virtual
            // rows past the end of the grid, so the existing two-pass row
            // encoder covers them without a separate encode path. Each is
            // translated back to the edge it left through; the shader then
            // applies its grid's scroll offset like any other row, and the
            // existing content clip discards the part outside the window.
            // Gated on this frame's raw offset, not on smoothScrolling. Both
            // the offset shift and the content clip come from the grid's
            // ScrollOffset entry, matched by grid_id in the vertex shader. On
            // the settle's final frame the offset is gone while smoothScrolling
            // stays true for one more frame (the extension the back-buffer blit
            // needs), so a retained row drawn then matches no entry and lands
            // unshifted and UNCLIPPED at its targetRow, in the margin rows above
            // the edge it left through. `pruneUndisplaced` is not a defence:
            // it deliberately keeps a band whose grid still has an unspent seed.
            // The external surface has always used this predicate.
            let retainedRows = hadActiveScrollOffsetThisFrame ? retainedSnapshot : []
            let retainedRowBase = safeRowCount
            let smoothRowRange = 0..<(safeRowCount + retainedRows.count)
            // Shared with ExternalGridView; this surface's root is grid 1.
            func resolvedSmoothRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                resolveSurfaceSmoothRow(
                    logicalRow: logicalRow,
                    retainedRowBase: retainedRowBase,
                    retainedRows: retainedRows,
                    rootGridId: 1,
                    cellHeightPx: Int(cellHi),
                    resolveRow: resolvedRowState
                )
            }

            // --- Step 3: the row the core named for the cursor ---
            // This used to be rediscovered every frame by scanning the
            // committed cursor vertices for their topmost y and dividing by the
            // cell height — an inference from pixels back to the row the core
            // had already named. ExternalGridView records the callback's row
            // instead; a full suite with the two compared under a precondition
            // never disagreed.
            let cursorGridRow = lastKnownCursorRowSnapshot

            // --- Step 4: Gate for blink fast path ---
            let canBlinkFastPath: Bool = {
                guard isBlinkOnlyFrame && blurEnabled && rowMode && use2Pass && !glowEnabled else { return false }
                // `cursorGridRow` came from vertices in the CURSOR GRID's own
                // pixels, but everything below it here — the range check, the
                // row resolve, the scissor — is the ROOT's row space. They only
                // coincide while the cursor is on the root. Under ext_multigrid
                // every editor window is a layer, so without this the fast path
                // scissored and redrew a root row that was not the cursor's,
                // and could overwrite a hosted layer's pixels in that band on a
                // frame where no layer was being redrawn. The external surface
                // avoids it by refusing the fast path whenever it hosts a layer
                // at all; naming the cursor's owner is the same rule, stated
                // precisely enough to keep the fast path on a root cursor.
                guard cursorOwnerGridSnapshot == 1 else { return false }
                guard cursorGridRow >= 0 && cursorGridRow < safeRowCount else { return false }
                guard resolvedRowState(cursorGridRow) != nil else { return false }
                return true
            }()

            // Skip the main render pass for a frame that changes no backTex
            // pixel — blink-only or noop. The cursor lives on the drawable, not
            // backTex, so the copy + cursor passes alone reproduce the right
            // pixel. Avoids the ~5.7ms .clear cost (alpha=0.8 backgrounds
            // disable Apple's fast-clear path). Glow is excluded: bloom samples
            // backTex through its own intermediate pass.
            // `cursorOnlyCommitSnapshot` joins `!hasNewCommit` rather than
            // replacing it: a commit that moved only the cursor changes no
            // backTex pixel either, which is why `ExternalGridView` reuses its
            // surface for one. Without it the main surface needs a dirty row to
            // keep the frame alive, and that row drags a background band and
            // every layer under it into the redraw.
            let noMainWorkFrame = (!hasNewCommit || cursorOnlyCommitSnapshot)
                && dirtyRows.isEmpty
                && !anyLayerWork
                && dirtyRectPxOpt == nil
                && !smoothScrolling
                && !drawableSizeChanged
                && hasPresentedOnceSnapshot
            let skipMainPass = noMainWorkFrame && !glowEnabled

            // Bail path for acquisition failures below (drawable exhaustion,
            // command-buffer failure). Dirty rows/rect, the scroll accumulator
            // and the skip-gate state were consumed under the lock above, so
            // returning without restoring them leaves stale rows until the next
            // full update and wedges the redraw scheduler (didDrawFrame() never
            // fires). Restore a superset — all rows dirty, which also heals the
            // unapplied blit since committed vertices are already post-scroll.
            //
            // ExternalGridView restores EXACTLY what its draw consumed: its
            // submitted rows, its layout-damage and cursor flags, its scroll
            // accumulator. Two policies for one job, unmeasured against each
            // other because the path runs only when a draw gives up, which no
            // scenario provokes.
            func bailWithoutSubmit(_ reason: String) {
                ZonvieCore.appLog("[WARNING] draw bailed (\(reason)); restoring dirty state for retry")
                markAllRowsDirty()
                markAllLayersDirty()
                if let r = dirtyRectPxOpt {
                    lock.lock()
                    pendingDirtyRectPx = pendingDirtyRectPx?.union(r) ?? r
                    lock.unlock()
                }
                lastDrawnRevision = prevDrawnRevision
                scrollOffsetLatch.restore(previousFrameWasActive: prevDrawnHadActiveScrollOffset)
                blink.lastRendered = prevRenderedBlinkState
                (view as? MetalTerminalView)?.didDrawFrame()
                (view as? MetalTerminalView)?.requestRedraw()
            }

            // Ensure persistent back buffer matches current drawable size.
            var t_backbuf_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_backbuf_start = CFAbsoluteTimeGetCurrent()
            }
            ensureBackBuffer(drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat)
            if ZonvieCore.appLogEnabled {
                let backbuf_us = (CFAbsoluteTimeGetCurrent() - t_backbuf_start) * 1_000_000
                ZonvieCore.appLogPerf("[perf] draw_ensure_backbuffer us=\(String(format: "%.1f", backbuf_us))")
            }
            guard let backTex = backBuffer else {
                bailWithoutSubmit("no backbuffer")
                return
            }

            guard let cmd = queue.makeCommandBuffer() else {
                bailWithoutSubmit("command buffer creation failed")
                return
            }
            // Per-pass GPU timing: reset slot list at frame start; attach calls
            // below append entries that the completion handler resolves into a
            // single [perf] gpu_passes line. Gated so the hot path pays zero
            // cost when perf logging is off (the attach helpers also bail out
            // internally, but beginFrame's removeAlls would otherwise run
            // unconditionally).
            if ZonvieCore.appLogEnabled {
                gpuSampler.beginFrame()
            }
            // The rows of a layer the current buffer set can actually resolve.
            // Asked for by both the blit decision below and the layer draw
            // loop, which have to agree on how tall the layer is.
            func layerResolvableRowCount(_ li: Int, _ layer: SurfaceLayer) -> Int {
                guard let set = layerSnapshot[li].set else { return 0 }
                return min(set.rowLogicalToSlot.count, layer.rows)
            }

            // Retained rows of this layer at the current cell height, collected
            // into `retainedIndexScratch`; the draw loop refills it per layer.
            func collectLayerRetainedRows(_ gridId: Int64) -> Int {
                collectSurfaceLayerRetainedRows(
                    gridId: gridId,
                    retained: retainedSnapshot,
                    cellHeightPx: Float(cellHi),
                    into: &retainedIndexScratch
                )
            }

            // Why a layer has to redraw every row instead of only the rows it
            // owes. Asked twice per frame — here, so a layer that will redraw
            // everything refuses the blit that redraw would overwrite, and again
            // in the draw loop — so the condition lives in one place.
            // `loadActionIsClear` is not known yet here; passing false is exact
            // (see the caller). A disagreement costs a wasted blit or a wider
            // redraw, never correctness.
            func layerNeedsAllRows(
                state: SurfaceLayerDrawState?,
                rowCount: Int,
                retainedRowCount: Int,
                loadActionIsClear: Bool
            ) -> Bool {
                guard let state else { return true }
                return loadActionIsClear
                    || state.drawAllRows
                    || smoothScrolling
                    || glowEnabled
                    || retainedRowCount > 0
                    || rowCount != state.lastDrawnRowCount
            }

            // Repaint both sides of the damage an accepted per-layer blit does
            // to the layers drawn on top of it. The rule and its arithmetic are
            // the core's (`src/core/row_scroll.zig`), which the Windows driver
            // calls as Zig; this is the same answer through the C ABI.
            func markLayersOverBlit(
                _ li: Int,
                _ layer: SurfaceLayer,
                _ state: SurfaceLayerDrawState,
                _ p: RowScrollBlitPlan,
                _ rowsDelta: Int
            ) {
                guard cellHi > 0 else { return }
                var plan = p.cValue

                for mi in (li + 1)..<layerSnapshot.count {
                    let above = layerSnapshot[mi].layer
                    guard above.rows > 0, above.cols > 0 else { continue }
                    var over = zonvie_over_blit_rows()
                    guard zonvie_core_row_scroll_over_blit_rows(
                        &plan,
                        Int32(clamping: rowsDelta),
                        Int32(clamping: Int(above.originPx.x.rounded(.down))),
                        Int32(clamping: Int(above.originPx.y.rounded(.down))),
                        UInt32(clamping: above.rows),
                        UInt32(clamping: above.cols),
                        Int32(clamping: cellWi),
                        Int32(clamping: cellHi),
                        &over
                    ) else { continue }

                    // The covering layer puts itself back. A layer with no draw
                    // state redraws every row anyway, so there is nothing to
                    // mark for it.
                    if over.has_above != 0, let aboveState = layerSnapshot[mi].state {
                        aboveState.drawRows.append(
                            contentsOf: Int(over.above_first)...Int(over.above_last))
                    }

                    // This layer puts back the rows the covering layer's pixels
                    // were dragged into, plus the rows they came from.
                    if over.has_under != 0 {
                        state.drawRows.append(
                            contentsOf: Int(over.under_first)...Int(over.under_last))
                    }
                    if over.has_shifted != 0 {
                        state.drawRows.append(
                            contentsOf: Int(over.shifted_first)...Int(over.shifted_last))
                    }
                }
            }

            // Per-layer row-scroll copy. Each layer owns a rectangle of the
            // shared back texture, so its shift is a blit of that rectangle only
            // — `RowScrollBlitPlan` carries the origin that stops the copy at
            // the layer's own columns. Clearing the ladder below shifts on the
            // GPU and redraws only the vacated band plus the rows earlier steps
            // left stale; failing any rung redraws the whole shifted region from
            // the row slots the core already remapped.
            var useGpuScrollCopy = false
            var scrollBlitEncoder: MTLBlitCommandEncoder? = nil
            acceptedBlitRectsPx.removeAll(keepingCapacity: true)
            for (li, entry) in layerSnapshot.enumerated().dropFirst() {
                let layer = entry.layer
                guard let state = entry.state, let scroll = state.drawScroll else { continue }
                state.drawScroll = nil

                let originXPx = Int(layer.originPx.x.rounded(.down))
                let originYPx = Int(layer.originPx.y.rounded(.down))
                var refusalReason: String? = nil
                var plan: RowScrollBlitPlan? = nil

                // Surface-wide rungs first: none of them depends on the layer,
                // and each is the same reason the main surface used to refuse.
                if !hasPresentedOnceSnapshot {
                    // The back texture's pixels are not a previous frame yet.
                    refusalReason = "presented"
                } else if smoothScrolling {
                    // An eased frame's pixels are already shifted by the shader
                    // offset (the one-frame extension at the `smoothScrolling`
                    // definition covers the frame after it returns to zero);
                    // shifting them again is the 1-row jitter.
                    refusalReason = "smooth"
                } else if drawableSizeChanged || !hasNewCommit {
                    // No previous pixels at these coordinates, or no new commit
                    // and so no remapped row slots to shift.
                    refusalReason = "resize"
                } else if glowEnabled {
                    // Bloom composites the whole back texture and forces
                    // .clear, which erases anything the blit moved.
                    refusalReason = "glow"
                } else if blurEnabled && !use2Pass {
                    // Blur's partial redraw needs the overwrite-background and
                    // alpha-glyph pipelines; fail closed to a full redraw.
                    refusalReason = "blur"
                } else if layer.rows <= 0 || layer.cols <= 0 {
                    // A layer the layout has not sized yet owns no rectangle.
                    refusalReason = "layout"
                } else if scroll.totalRows != layer.rows || scroll.totalCols != layer.cols {
                    // Staged against a grid size the committed layout no longer
                    // places, so its rows do not name this rectangle's rows.
                    refusalReason = "size"
                } else {
                    plan = RowScrollBlitPlan.make(
                        rowStart: scroll.rowStart,
                        rowEnd: scroll.rowEnd,
                        rowsDelta: scroll.rowsDelta,
                        originXPx: originXPx,
                        originYPx: originYPx,
                        widthPx: layer.cols * Int(cellWi),
                        textureWidthPx: backTex.width,
                        textureHeightPx: backTex.height,
                        rowHeightPx: Int(cellHi)
                    )
                    if plan == nil {
                        // Nothing of the region survives the texture clamp, or
                        // the shift covers it entirely.
                        refusalReason = "plan"
                    }
                }

                if plan != nil, refusalReason == nil {
                    // The one overlap case that still refuses, now that
                    // markLayersOverBlit repaints the rest. Accepted blits share
                    // one encoder in snapshot order, so a layer above an accepted
                    // one would copy pixels the lower shift just moved and carry
                    // the smear into its own rows; repainting cannot fix that
                    // without undoing the other shift. Refusing also keeps the
                    // marking one-directional.
                    let layerLeftPx = originXPx
                    let layerRightPx = originXPx + layer.cols * Int(cellWi)
                    let layerTopPx = originYPx
                    let layerBottomPx = originYPx + layer.rows * Int(cellHi)
                    for r in acceptedBlitRectsPx
                    where layerLeftPx < r.rightPx && layerRightPx > r.leftPx
                        && layerTopPx < r.bottomPx && layerBottomPx > r.topPx {
                        refusalReason = "overlap"
                        break
                    }
                }

                if refusalReason == nil {
                    // A layer that redraws every row overwrites whatever the blit
                    // moved. `loadActionIsClear: false` is exact even though the
                    // frame has not chosen yet: accepting a plan sets
                    // `useGpuScrollCopy` → `forceReusePreviousContents`, and with
                    // the rungs above already passed
                    // resolveSurfaceColorLoadAction returns .load.
                    if layerNeedsAllRows(
                        state: state,
                        rowCount: layerResolvableRowCount(li, layer),
                        retainedRowCount: collectLayerRetainedRows(layer.gridId),
                        loadActionIsClear: false
                    ) {
                        refusalReason = "drawall"
                    }
                }

                if refusalReason == nil, let p = plan {
                    let t0 = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
                    // One encoder across every layer this frame moves, which is
                    // why it is passed in rather than made here.
                    if encodeSurfaceRowScrollBlit(
                        plan: p,
                        backTexture: backTex,
                        scratch: scrollScratch,
                        device: shared.device,
                        backBufferSize: backBufferSize,
                        commandBuffer: cmd,
                        encoder: &scrollBlitEncoder
                    ) {
                        useGpuScrollCopy = true
                        state.drawRows.append(contentsOf: p.dirtyRows)
                        state.drawBlitClearBand = p.localClearBand()
                        markLayersOverBlit(li, layer, state, p, scroll.rowsDelta)
                        acceptedBlitRectsPx.append((
                            leftPx: p.originXPx,
                            topPx: min(min(p.srcYPx, p.dstYPx), p.clearTopPx),
                            rightPx: p.originXPx + p.copyWidthPx,
                            bottomPx: max(max(p.srcYPx, p.dstYPx) + p.copyHeightPx, p.clearBottomPx)
                        ))
                        if ZonvieCore.appLogEnabled {
                            let us = (CFAbsoluteTimeGetCurrent() - t0) * 1_000_000
                            ZonvieCore.appLog("[layer_blit] gridId=\(layer.gridId) rowStart=\(scroll.rowStart) rowEnd=\(p.clampedRowEnd) rowsDelta=\(scroll.rowsDelta) us=\(String(format: "%.1f", us))")
                        }
                        continue
                    }
                    // The scratch texture or the encoder could not be made.
                    refusalReason = "plan"
                }

                if ZonvieCore.appLogEnabled, let reason = refusalReason {
                    ZonvieCore.appLog("[layer_blit_refused] gridId=\(layer.gridId) reason=\(reason)")
                }
                guard let refusedRows = RowScrollBlitPlan.dirtyRowsWithoutBlit(
                    rowStart: scroll.rowStart,
                    rowEnd: scroll.rowEnd,
                    originYPx: originYPx,
                    textureHeightPx: backTex.height,
                    rowHeightPx: Int(cellHi)
                ) else { continue }
                state.drawRows.append(contentsOf: refusedRows)
            }
            scrollBlitEncoder?.endEncoding()

            // Every root dirty row is overpainted below with a background band
            // spanning the whole drawable width, which .load makes mandatory:
            // the core drops default-background runs from the root's rows while
            // the surface has layers (flush.zig `skip_default_bg`), so a root
            // row would otherwise keep the pixels it lost or re-blend the ones
            // it kept. The band also erases layer pixels, so mark the grid-local
            // rows it lands on here, where the damage is produced; the layer
            // then repaints those rows instead of all of them.
            let bandRowHeightPx = Int(cellHi)
            if layerSnapshot.count > 1 && bandRowHeightPx > 0 {
                for row in dirtyRows {
                    let bandTopPx = row * bandRowHeightPx
                    for entry in layerSnapshot.dropFirst() {
                        let layer = entry.layer
                        guard let state = entry.state else { continue }
                        guard let rows = layerRowsUnderBand(
                            bandTopPx: bandTopPx,
                            bandBottomPx: bandTopPx + bandRowHeightPx,
                            layer: layer,
                            rowHeightPx: bandRowHeightPx
                        ) else { continue }
                        state.drawRows.append(contentsOf: rows)
                    }
                }
            }

            // Rows every layer repaints over the layers above it. A layer owns
            // the whole rectangle of each row it draws, so drawing one erases
            // what a layer over it had there, and that layer draws nothing this
            // frame unless it is marked too. An accepted blit is already handled
            // above; this covers the rest — a refused one, and any ordinary
            // dirty-row or whole-layer repaint. Back to front, so a mark lands
            // before the layer carrying it becomes the source of the next one.
            func markLayersOverBand(
                _ li: Int,
                _ leftPx: Int,
                _ rightPx: Int,
                _ bandTopPx: Int,
                _ bandBottomPx: Int
            ) {
                let rowHeightPx = Int(cellHi)
                guard rowHeightPx > 0 else { return }
                for mi in (li + 1)..<layerSnapshot.count {
                    let above = layerSnapshot[mi].layer
                    guard let aboveState = layerSnapshot[mi].state, above.cols > 0 else { continue }
                    let aLeftPx = Int(above.originPx.x.rounded(.down))
                    let aRightPx = aLeftPx + above.cols * Int(cellWi)
                    guard aLeftPx < rightPx, aRightPx > leftPx else { continue }
                    guard let rows = layerRowsUnderBand(
                        bandTopPx: bandTopPx,
                        bandBottomPx: bandBottomPx,
                        layer: above,
                        rowHeightPx: rowHeightPx
                    ) else { continue }
                    aboveState.drawRows.append(contentsOf: rows)
                }
            }
            // Back to front, and each layer is normalized before it becomes a
            // source: only lower layers write to a higher one, so a layer's
            // list is final by the time its turn comes. Propagating it with
            // duplicates still in it would copy every duplicate into every
            // layer above, doubling the count per overlapping layer. The
            // frontmost layer marks nothing but is normalized here too, so no
            // separate pass follows.
            for (li, entry) in layerSnapshot.enumerated().dropFirst() {
                let layer = entry.layer
                guard let state = entry.state else { continue }
                surfaceSortAndDeduplicateRows(&state.drawRows)
                guard layer.rows > 0, layer.cols > 0, bandRowHeightPx > 0 else { continue }
                let leftPx = Int(layer.originPx.x.rounded(.down))
                let rightPx = leftPx + layer.cols * Int(cellWi)
                let topPx = Int(layer.originPx.y.rounded(.down))
                // `loadActionIsClear: false` for the same reason the blit
                // ladder passes it: a frame that does clear redraws every
                // layer whole anyway, so the disagreement cannot lose a row.
                if layerNeedsAllRows(
                    state: state,
                    rowCount: layerResolvableRowCount(li, layer),
                    retainedRowCount: collectLayerRetainedRows(layer.gridId),
                    loadActionIsClear: false
                ) {
                    markLayersOverBand(li, leftPx, rightPx, topPx, topPx + layer.rows * bandRowHeightPx)
                    continue
                }
                for row in state.drawRows where row >= 0 && row < layer.rows {
                    let bandTopPx = topPx + row * bandRowHeightPx
                    markLayersOverBand(li, leftPx, rightPx, bandTopPx, bandTopPx + bandRowHeightPx)
                }
            }

            // --- 1) Render into back buffer (partial redraw is valid here) ---
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = backTex
            rpd.colorAttachments[0].storeAction = .store

            // For partial redraw, preserve back buffer contents; clear once after
            // a resize. Under blur, .load blends semi-transparent backgrounds
            // with the previous frame (ghosting, opacity buildup) unless the
            // 2-pass background pass overwrites them — see canDirtyOnlyWithBlur.
            // A layer that owes rows counts as dirty here: its rows are not in
            // the surface's own dirty set, and a layer-only frame must not clear.
            let hasAnyDirtyInRowMode = rowMode && (!dirtyRows.isEmpty || anyLayerWork)

            // Glow forces .clear: additive bloom would accumulate brightness.
            // Blur can still redraw dirty-only with .load because the 2-pass
            // background pass overwrites, so alpha does not accumulate — that
            // avoids a full clear between scroll flushes (e.g. statusline).
            let canDirtyOnlyWithBlur = rowMode && use2Pass && hasAnyDirtyInRowMode
                && hasPresentedOnceSnapshot && !smoothScrolling && !drawableSizeChanged && !glowEnabled
            // Shared with ExternalGridView: SurfaceLoadActionTerms holds every
            // guard and arm either surface has. This surface has no font gate,
            // no separate layout-damage flag and is never decorated, so those
            // stay at defaults. `layersOutsideDirtySet` stays false on purpose
            // — the layers this surface hosts are already inside
            // `hasAnyDirtyInRowMode`, via `anyLayerWork`.
            let loadTerms = SurfaceLoadActionTerms(
                glowEnabled: glowEnabled,
                canBlinkFastPath: canBlinkFastPath,
                useGpuScrollCopy: useGpuScrollCopy,
                canDirtyOnlyWithBlur: canDirtyOnlyWithBlur,
                hasDirtyRect: dirtyRectPxOpt != nil,
                hasDirtyRowsInRowMode: hasAnyDirtyInRowMode,
                isSmoothScrolling: smoothScrolling
            )
            let shouldReusePreviousContents = loadTerms.reusesPreviousContents
            ZonvieCore.drawTrace(loadTerms.traceLine(surface: 1))
            rpd.colorAttachments[0].loadAction = resolveSurfaceColorLoadAction(
                blurEnabled: blurEnabled,
                hasPresentedOnce: hasPresentedOnceSnapshot,
                drawableSizeChanged: drawableSizeChanged,
                shouldReusePreviousContents: shouldReusePreviousContents,
                forceReusePreviousContents: loadTerms.forcesReusePreviousContents
            )

            if rpd.colorAttachments[0].loadAction == .load {
                if canBlinkFastPath {
                    ZonvieCore.appLog("[draw] loadAction=.load (blinkFastPath cursorRow=\(cursorGridRow))")
                } else if useGpuScrollCopy {
                    ZonvieCore.appLog("[draw] loadAction=.load (layerScrollCopy)")
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

            if skipMainPass {
                let reason = isBlinkOnlyFrame ? "blink-only" : "noop"
                ZonvieCore.appLog("[draw] skipMainPass=true (\(reason); backTex preserved, copy+cursor only)")
            }
            if !skipMainPass {
            gpuSampler.attach(to: rpd, label: "main")
            gpuSampler.attachStats(to: rpd, label: "main")
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                // Encoder creation failed (rare). Commit the empty cmd anyway so
                // the IOAccelerator region attached to it is reclaimed; otherwise
                // an uncommitted MTLCommandBuffer leaks GPU memory permanently.
                submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseFrameState)
                gpuSubmitted = true
                // Submitted, but the drawable was never populated and backTex
                // may hold a half-drawn frame. Refuse to `.load` it next time,
                // as ExternalGridView does at each of its matching bails.
                // `markAllRowsDirty` below bands every cell-aligned row, which
                // is not the same statement: this one also stops the idle gates
                // skipping past the repair. Deliberately NOT set on the
                // "no drawable" bail below — there backTex is complete and only
                // the present is missing, which is why the external surface
                // leaves its own copy of that one alone too.
                //
                // Under the lock, unlike ExternalGridView's copies of this: the
                // GPU completion handler writes this flag from its own thread
                // (:4805, :4814) and an earlier frame's can still be in flight
                // behind the semaphore, so an unlocked `false` here races it and
                // can be lost. The external surface's flag is main-thread
                // confined — its completion handler hops to the main queue
                // first — which is why its writes need no lock and this one does.
                lock.lock()
                hasPresentedOnce = false
                lock.unlock()
                bailWithoutSubmit("render encoder creation failed")
                return
            }

            // Set viewport to exact grid pixel dimensions to prevent sub-cell stretching.
            // Must match Zig core's NDC computation: cols = drawableW / cellW, grid_w = cols * cellW.
            // cellWi/cellHi/drawableWi/drawableHi/vpWidth/vpHeight are pre-computed in Step 2 above.
            viewportMetrics.applyViewport(to: enc)

            // Safe to force unwrap: guard at top of draw() ensures pipeline/sampler are non-nil
            enc.setRenderPipelineState(shared.pipeline!)

            // atlas texture + sampler
            if let tex = atlasTex {
                enc.setFragmentTexture(tex, index: 0)
            }
            enc.setFragmentSamplerState(shared.sampler!, index: 0)

            // Bind scroll offsets, fragment state (drawable size, alpha, blink) via shared helpers
            bindSurfaceScrollOffsets(encoder: enc, offsets: scrollSnapshot, device: shared.device, scratchBuffer: &committed.scrollOffsetBuffer, scratchCapacity: &committed.scrollOffsetBufferCap)
            bindSurfaceFragmentState(
                encoder: enc,
                viewportMetrics: viewportMetrics,
                backgroundAlphaBuffer: backgroundAlphaBuffer,
                cursorBlinkBuffer: cursorBlinkBuffer,
                cursorBlinkVisible: true,  // always visible; cursor drawn as separate overlay pass
                fixedFloatBands: fixedFloatBandsSnapshot,
                fixedFloatIntervals: fixedFloatIntervalsSnapshot
            )
            var zeroRowTranslation: Float = 0
            enc.setVertexBytes(&zeroRowTranslation, length: MemoryLayout<Float>.size, index: 3)

            let drawableW = max(0, Int(view.drawableSize.width.rounded(.down)))
            let cellH = max(1, Int(cellHeightPx.rounded(.up)))
            // Shared with ExternalGridView: the geometry every row below is
            // placed with, resolved once instead of at each call site.
            let rowGeometry = SurfaceRowGeometry(
                cellHeightPx: cellH,
                renderTarget: backTex,
                viewportMetrics: viewportMetrics,
                drawableSize: view.drawableSize
            )

            func drawScissoredDirtyRows() {
                encodeSurfaceScissoredDirtyRows(
                    encoder: enc,
                    rows: dirtyRows,
                    pipeline: shared.pipeline!,
                    resolve: resolvedRowState,
                    geometry: rowGeometry,
                    bgRGB: snappedBgRGB,
                    gridId: 1
                )
            }

            // === PERF LOG: encode_setup → encode_rows boundary ===
            let t_encode_rows_start: CFAbsoluteTime = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let encode_setup_us: Double = ZonvieCore.appLogEnabled ? (t_encode_rows_start - t_encode_start) * 1_000_000 : 0

            // use2Pass and safeRowCount are pre-computed in Step 2 above.

            // Shared with ExternalGridView: WHICH rows this pass draws is
            // one decision now; `use2Pass` still says HOW, which is why three
            // cases below still split on it.
            //
            // `rootScrollBlitVacatedBand` is false here on purpose — this
            // surface blits for its LAYERS, whose own pass repaints them, and
            // its root is the ext_multigrid container, which never scrolls.
            // `hasDirtyRows` carries `anyLayerWork` because those layers are
            // drawn from this same pass.
            let rowPassPlan = SurfaceRowPassTerms(
                useTwoPass: use2Pass,
                canBlinkFastPath: canBlinkFastPath,
                isSmoothScrolling: smoothScrolling,
                canDirtyOnlyWithBlur: canDirtyOnlyWithBlur,
                loadedPreviousContents: rpd.colorAttachments[0].loadAction == .load,
                hasDirtyRows: !dirtyRows.isEmpty || anyLayerWork,
                glowEnabled: glowEnabled,
                drawableSizeChanged: drawableSizeChanged
            ).plan

            if rowMode {
                switch rowPassPlan {
                case .blinkFastPathRow:
                    // FAST PATH: blink-only — redraw only cursor row.
                    // Single-pass via unified blur pipeline when available;
                    // 2-pass fallback otherwise (matches the global rule
                    // for use2Pass branches).
                    let resolved = resolvedRowState(cursorGridRow)!  // guaranteed non-nil by canBlinkFastPath
                    // Shared with ExternalGridView; only the row differs.
                    encodeSurfaceBlinkFastPathRow(
                        encoder: enc,
                        row: cursorGridRow,
                        resolved: resolved,
                        geometry: rowGeometry,
                        backgroundPipeline: shared.backgroundPipeline,
                        glyphPipeline: shared.glyphPipeline,
                        unifiedBlurPipeline: shared.unifiedBlurPipeline
                    )
                    ZonvieCore.appLog("[draw] blinkFastPath: cursorRow=\(cursorGridRow) vc=\(resolved.vc) unified=\(shared.unifiedBlurPipeline != nil)")
                case .dirtyRowsOnly where use2Pass:
                    // Partial redraw with .load for blur: only dirty rows are
                    // redrawn 2-pass (overwrite bg + alpha glyph) with
                    // scissor rects, so alpha cannot accumulate.
                    //
                    // Under .load a dirty row that does not repaint every
                    // pixel it owns keeps the previous frame's, and the core
                    // drops the root's default-background runs while the
                    // surface has layers (flush.zig `skip_default_bg`): an
                    // empty row is skipped entirely, and a row that still
                    // carries a glyph emits no background quad under it and
                    // creeps toward opaque. So band every dirty row with
                    // backgroundPipeline first; the row's own background
                    // quads then overwrite the band where it has any.
                    let drawableWidthF = Float(vpWidth > 0 ? vpWidth : view.drawableSize.width)
                    let drawableHeightF = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)
                    let cellHiI = Int(cellHi)
                    if let bgPipe = shared.backgroundPipeline {
                        encodeSurfaceDirtyRowBands(
                            encoder: enc,
                            rows: dirtyRows,
                            pipeline: bgPipe,
                            cellHeightPx: cellHiI,
                            widthPx: drawableWidthF,
                            heightPx: drawableHeightF,
                            bgRGB: snappedBgRGB,
                            gridId: 1
                        )
                    }
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        rows: dirtyRows,
                        resolve: resolvedRowState,
                        scissor: { row in
                            makeRowScissorRect(
                                row: row,
                                cellHeight_px: cellHiI,
                                drawableWidth_px: drawableW,
                                renderTargetWidth_px: backTex.width,
                                renderTargetHeight_px: backTex.height
                            )
                        },
                        pipeline: shared.pipeline!,
                        backgroundPipeline: shared.backgroundPipeline,
                        glyphPipeline: shared.glyphPipeline,
                        useTwoPass: true,
                        unifiedBlurPipeline: shared.unifiedBlurPipeline
                    )
                case .dirtyRowsOnly:
                    // Normal mode: scissor per dirty row (prevents giant scissor from accumulated unions).
                    // Skipped when glow is enabled — full redraw needed for correct bloom composite.
                    // Use this only when the render pass preserved clean rows.
                    // Resize and fail-closed blur-pipeline frames use .clear;
                    // drawing only dirty rows there would blank every other row.
                    drawScissoredDirtyRows()
                case .allRowsWithRetained where use2Pass:
                    // 2-Pass rendering for blur: draw backgrounds first, then glyphs
                    // This prevents ghosting with semi-transparent backgrounds
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        rows: smoothRowRange,
                        resolve: resolvedSmoothRowState,
                        pipeline: shared.pipeline!,
                        backgroundPipeline: shared.backgroundPipeline,
                        glyphPipeline: shared.glyphPipeline,
                        useTwoPass: true,
                        unifiedBlurPipeline: shared.unifiedBlurPipeline
                    )
                case .allRowsWithRetained:
                    // Smooth scroll without blur: draw all rows without scissor
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        rows: smoothRowRange,
                        resolve: resolvedSmoothRowState,
                        pipeline: shared.pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                case .allRows:
                    // Safety: if no dirtyRows (first frame), draw all rows without scissor.
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        rows: 0..<safeRowCount,
                        resolve: resolvedRowState,
                        pipeline: shared.pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                case .dirtyRowsAfterScrollBlit:
                    // Unreachable: this surface passes
                    // `rootScrollBlitVacatedBand: false`, its root being the
                    // container grid. Named rather than folded into a default,
                    // so giving the root a scroll blit later lands here instead
                    // of silently taking someone else's arm.
                    assertionFailure("main surface has no root scroll blit")
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        rows: 0..<safeRowCount,
                        resolve: resolvedRowState,
                        pipeline: shared.pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                }
            } else {
                // Non-rowMode: shared helper handles 2-pass vs single-pass dispatch
                let dirtyScissor: MTLScissorRect? = {
                    // A scissor is valid only when the render pass preserved
                    // the rest of backTex. On a first/resize frame .clear has
                    // already erased everything outside the dirty rectangle,
                    // so that frame must redraw the complete committed set.
                    guard !use2Pass,
                          rpd.colorAttachments[0].loadAction == .load,
                          let dr = dirtyRectPxOpt
                    else { return nil }
                    guard dr.minX.isFinite, dr.maxX.isFinite,
                          dr.minY.isFinite, dr.maxY.isFinite,
                          backTex.width > 0, backTex.height > 0
                    else { return nil }
                    let targetW = CGFloat(backTex.width)
                    let targetH = CGFloat(backTex.height)
                    let minX = max(0, min(targetW, dr.minX.rounded(.down)))
                    let maxX = max(0, min(targetW, dr.maxX.rounded(.up)))
                    let minY = max(0, min(targetH, dr.minY.rounded(.down)))
                    let maxY = max(0, min(targetH, dr.maxY.rounded(.up)))
                    let x = Int(minX)
                    let y = Int(minY)
                    let w = Int(maxX - minX)
                    let h = Int(maxY - minY)
                    return (w > 0 && h > 0) ? MTLScissorRect(x: x, y: y, width: w, height: h) : nil
                }()
                encodeSurfaceNonRowContent(
                    encoder: enc,
                    vertexBuffer: committed.mainVertexBuffer,
                    vertexCount: currentMainCount,
                    pipeline: shared.pipeline!,
                    backgroundPipeline: shared.backgroundPipeline,
                    glyphPipeline: shared.glyphPipeline,
                    useTwoPass: use2Pass,
                    scissorRect: dirtyScissor,
                    unifiedBlurPipeline: shared.unifiedBlurPipeline
                )
            }

            // Non-root layers, back-to-front, on top of the root grid. Each
            // gets its own pixel space and is clipped to its own rect. A layer
            // whose grid has no rows yet draws nothing, which is what the
            // core's layout contract requires.
            if layerSnapshot.count > 1 {
                enc.setRenderPipelineState(shared.pipeline!)
                for (li, entry) in layerSnapshot.enumerated().dropFirst() {
                    let layer = entry.layer
                    guard let set = entry.set else { continue }
                    let rowCount = layerResolvableRowCount(li, layer)
                    guard rowCount > 0 else { continue }
                    // What this layer owes the frame; nil for a grid with no
                    // draw state, which is treated as owing everything.
                    let st = entry.state

                    // A layer this frame displaces bodily (move_all: a float
                    // following its anchor's smooth scroll) is drawn at a
                    // shifted origin with no offset bound, so its clip and its
                    // geometry share one space. Widening the scissor instead
                    // would reach into the neighbouring float — they stack edge
                    // to edge, an ease runs to more than two cells, and a
                    // layer's background pass overwrites under blur. A layer
                    // the shader displaces per-row keeps the offset: its
                    // content clip holds those rows inside this same rect.
                    let layerOffset = surfaceScrollOffset(gridId: layer.gridId, offsets: scrollSnapshot)
                    let bodilyMoved = (layerOffset?.move_all ?? 0) != 0
                    let drawOriginPx = bodilyMoved
                        ? displacedLayerOriginPx(
                            originPx: layer.originPx,
                            offset: layerOffset!,
                            viewportHeightPx: viewportMetrics.fragmentHeight)
                        : layer.originPx
                    bindLayerTransform(
                        encoder: enc,
                        LayerTransform(
                            originPx: drawOriginPx,
                            extentPx: simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)
                        )
                    )
                    // Only this layer's vertices are in this pass, so one entry
                    // is all the shader can match — and none at all once the
                    // origin already carries the displacement.
                    bindSingleSurfaceScrollOffset(encoder: enc, offset: bodilyMoved ? nil : layerOffset)
                    let originX = Int(drawOriginPx.x.rounded(.down))
                    let originY = Int(drawOriginPx.y.rounded(.down))
                    let widthPx = layer.cols * Int(cellWi)
                    let heightPx = rowCount * Int(cellHi)
                    let scissorPadY = surfaceLayerScissorPadY(topPx: drawOriginPx.y)
                    if let rect = clampScissor(
                        x: originX, y: originY, width: widthPx, height: heightPx + scissorPadY,
                        targetWidth: backTex.width, targetHeight: backTex.height
                    ) {
                        enc.setScissorRect(rect)
                    } else {
                        continue
                    }

                    // This layer's rows, then the rows its own smooth scroll
                    // retained; both in its grid-local space. The index list is
                    // reused so a layer costs no allocation per frame.
                    let retainedForLayerCount = collectLayerRetainedRows(layer.gridId)

                    // What one row of this layer owes the encoder. Shared by both
                    // arms below so the gated path resolves rows the same way.
                    /// Paint one empty layer row with the surface background.
                    /// Both arms below reach it — the full-redraw arm decides a
                    /// row is empty from the buffer slot, the gated arm from
                    /// resolveLayerRow — and the band itself is the same band.
                    func clearEmptyLayerRow(_ enc: MTLRenderCommandEncoder, _ row: Int) {
                        let topPx = row * Int(cellHi)
                        drawSurfaceBackgroundClearBand(
                            enc,
                            clearBand: (clearTopPx: topPx, clearBottomPx: topPx + Int(cellHi)),
                            xRangePx: (leftPx: 0, rightPx: Float(widthPx)),
                            drawableHeight: Float(rowCount * Int(cellHi)),
                            bgRGB: snappedBgRGB,
                            gridId: layer.gridId
                        )
                    }

                    func resolveLayerRow(_ row: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                        // Only the full-redraw arm asks for retained rows; on
                        // the gated arm there are none by construction.
                        resolveSurfaceLayerRow(
                            row,
                            set: set,
                            rowCount: rowCount,
                            retained: retainedSnapshot,
                            retainedIndices: self.retainedIndexScratch,
                            cellHeightPx: Float(cellHi)
                        )
                    }

                    // Why this layer cannot be drawn from its dirty rows alone:
                    // .clear erased the whole back texture; no draw state means
                    // nothing tracked what this grid owes; drawAllRows means it
                    // moved, resized or is new; an eased frame re-places every
                    // row through a shader offset (retained rows are pruned once
                    // the layer stops being displaced — draw's pruneUndisplaced —
                    // so a layer still holding any is easing); glow composites
                    // bloom from the whole texture; and a changed row count means
                    // the rows it gained were never drawn.
                    //
                    // A dirty ROOT row is deliberately not a reason. Its
                    // full-width background band does erase this layer's pixels,
                    // but the band marks the layer rows it crosses where the
                    // damage is produced, so they are already in drawRows.
                    let drawAll = layerNeedsAllRows(
                        state: st,
                        rowCount: rowCount,
                        retainedRowCount: retainedForLayerCount,
                        loadActionIsClear: rpd.colorAttachments[0].loadAction == .clear
                    )

                    var encodedRows = 0
                    if drawAll {
                        // Rows the core emptied must overwrite their old pixels:
                        // backTex is loaded, not cleared, on this path. The blur
                        // arm's background pass already overwrites.
                        if !use2Pass {
                            for row in 0..<rowCount {
                                let slot = set.rowLogicalToSlot[row]
                                let empty = slot < 0 || slot >= set.rowState.buffers.count
                                    || set.rowState.buffers[slot] == nil || set.rowState.counts[slot] == 0
                                guard empty else { continue }
                                clearEmptyLayerRow(enc, row)
                                encodedRows += 1
                            }
                            enc.setRenderPipelineState(shared.pipeline!)
                        }

                        // Same pipeline choice as the root grid: under blur the
                        // background pass overwrites rather than blending, so a
                        // single-pass layer would darken its own background
                        // against whatever it covers.
                        encodedRows += encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: 0..<(rowCount + retainedForLayerCount),
                            resolve: resolveLayerRow,
                            pipeline: shared.pipeline!,
                            backgroundPipeline: shared.backgroundPipeline,
                            glyphPipeline: shared.glyphPipeline,
                            useTwoPass: use2Pass,
                            unifiedBlurPipeline: shared.unifiedBlurPipeline
                        )
                    } else {
                        let dirtyLayerRows = st!.drawRows
                        // The band this layer's GPU scroll copy vacated, in the
                        // layer's own pixel space. Drawn before the rows: the
                        // plan's dirty rows cover the band and must land on top.
                        if let band = st!.drawBlitClearBand {
                            enc.setRenderPipelineState(use2Pass ? (shared.backgroundPipeline ?? shared.pipeline!) : shared.pipeline!)
                            drawSurfaceBackgroundClearBand(
                                enc,
                                clearBand: band,
                                xRangePx: (leftPx: 0, rightPx: Float(widthPx)),
                                drawableHeight: Float(rowCount * Int(cellHi)),
                                bgRGB: snappedBgRGB,
                                gridId: layer.gridId
                            )
                        }
                        // A dirty row the core emptied resolves to nothing, so
                        // encodeSurfaceRowDraws skips it and .load keeps its old
                        // glyphs. Overwrite it explicitly — on the blur arm too,
                        // where the background pass never runs for a row with no
                        // vertices.
                        if !dirtyLayerRows.isEmpty {
                            enc.setRenderPipelineState(use2Pass ? (shared.backgroundPipeline ?? shared.pipeline!) : shared.pipeline!)
                            for row in dirtyLayerRows where resolveLayerRow(row) == nil {
                                guard row >= 0, row < rowCount else { continue }
                                clearEmptyLayerRow(enc, row)
                                encodedRows += 1
                            }
                        }
                        // One scissor per dirty row, the root's precedent for a
                        // dirty-only draw. makeRowScissorRect cannot serve here:
                        // it pins x to 0, and a layer starts at its own origin.
                        encodedRows += encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: dirtyLayerRows,
                            resolve: resolveLayerRow,
                            scissor: { row in
                                clampScissor(
                                    x: originX,
                                    y: originY + row * Int(cellHi),
                                    width: widthPx,
                                    height: Int(cellHi) + scissorPadY,
                                    targetWidth: backTex.width,
                                    targetHeight: backTex.height
                                )
                            },
                            pipeline: shared.pipeline!,
                            backgroundPipeline: shared.backgroundPipeline,
                            glyphPipeline: shared.glyphPipeline,
                            useTwoPass: use2Pass,
                            unifiedBlurPipeline: shared.unifiedBlurPipeline
                        )
                    }
                    st?.lastDrawnRowCount = rowCount
                    // rows= counts the row draws encoded (drawn rows plus
                    // overwritten empty ones); a quiet layer encodes none.
                    // blit=1 means a GPU scroll copy shifted this layer, so
                    // rows= counts only what the shift left stale.
                    // committedY is where the core placed this layer; drawY is
                    // where this frame puts it. Logged for the GUI harness, the
                    // way [renderer] scroll offset carries the margin band:
                    // float_stack_scroll_continuity asserts drawY never jumps a
                    // whole cell between frames, which is the only way a float
                    // teleporting for one frame can be caught without a person
                    // watching it.
                    ZonvieCore.appLog("[layer_draw] gridId=\(layer.gridId) rows=\(encodedRows) of=\(rowCount) blit=\(st?.drawBlitClearBand != nil ? 1 : 0) committedY=\(layer.originPx.y) drawY=\(drawOriginPx.y) moved=\(bodilyMoved ? 1 : 0)")
                }
                // Restore the surface's own pixel space and the full offset set
                // for the cursor pass: the loop above narrowed both to whatever
                // the last layer needed.
                bindLayerTransform(encoder: enc, viewportMetrics.layerTransform)
                bindSurfaceScrollOffsets(
                    encoder: enc,
                    offsets: scrollSnapshot,
                    device: shared.device,
                    scratchBuffer: &committed.scrollOffsetBuffer,
                    scratchCapacity: &committed.scrollOffsetBufferCap
                )
            }

            // === PERF LOG: encode_rows → encode_finalize boundary ===
            let t_encode_finalize_start: CFAbsoluteTime = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let encode_rows_us: Double = ZonvieCore.appLogEnabled ? (t_encode_finalize_start - t_encode_rows_start) * 1_000_000 : 0

            // Reset scissor before cursor pass.
            // In rowMode we scissor per row; leaving it as-is will clip the cursor.
            // canBlinkFastPath also sets a scissor that must be reset.
            if (rowMode && !use2Pass) || canBlinkFastPath {
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
                let encode_finalize_us = (t_encode_end - t_encode_finalize_start) * 1_000_000
                let dirtyRowCount = dirtyRows.count
                ZonvieCore.appLogPerf("[perf] draw_encode rowMode=\(rowMode) us=\(String(format: "%.1f", encode_us)) setup_us=\(String(format: "%.1f", encode_setup_us)) rows_us=\(String(format: "%.1f", encode_rows_us)) finalize_us=\(String(format: "%.1f", encode_finalize_us)) dirtyRows=\(dirtyRowCount)")
            }
            }  // end of `if !skipMainPass`

            // --- Post-process bloom (neon glow) ---
            // Shared with ExternalGridView; only where the intensity and the
            // radius are read from differs.
            let glowPassSucceeded = encodeSurfaceBloom(
                enabled: glowEnabled,
                shared: shared,
                cmd: cmd,
                backTex: backTex,
                pixelFormat: view.colorPixelFormat,
                viewportMetrics: viewportMetrics,
                drawableSize: view.drawableSize,
                glowTextures: glowTextures,
                intensity: (view as? MetalTerminalView)?.core?.getGlowIntensity() ?? 0.8,
                // One read, for both the chain's depth and the taps' reach.
                radiusScale: (view as? MetalTerminalView)?.core?.getGlowRadiusScale() ?? 1.0
            ) { enc, extractPipe in
                    // Extract vertices: atlas + scroll offsets + row/main + cursor
                    if let tex = atlasTex {
                        enc.setFragmentTexture(tex, index: 0)
                    }
                    enc.setFragmentSamplerState(shared.sampler!, index: 0)
                    // ps_glow_occlude reads the same background alpha the main
                    // pass paints with, so the two agree on what a layer hides.
                    if let alphaBuf = backgroundAlphaBuffer {
                        enc.setFragmentBuffer(alphaBuf, offset: 0, index: 1)
                    }

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
                        for row in smoothRowRange {
                            guard let resolved = resolvedSmoothRowState(row) else { continue }
                            var rt = resolved.translationY
                            enc.setVertexBytes(&rt, length: MemoryLayout<Float>.size, index: 3)
                            enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
                        }
                    } else if currentMainCount > 0, let mvb = committed.mainVertexBuffer {
                        enc.setVertexBuffer(mvb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentMainCount)
                    }

                    // Non-root layers glow too: under ext_multigrid every
                    // editor row is one of these, so extracting only the root
                    // grid leaves the whole screen unlit.
                    if layerSnapshot.count > 1 {
                        for entry in layerSnapshot.dropFirst() {
                            let layer = entry.layer
                            guard let set = entry.set else { continue }
                            let rowCount = min(set.rowLogicalToSlot.count, layer.rows)
                            guard rowCount > 0 else { continue }
                            bindLayerTransform(
                                encoder: enc,
                                LayerTransform(
                                    originPx: layer.originPx,
                                    extentPx: simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)
                                )
                            )
                            // Pass 0 attenuates what the layers below already
                            // extracted by this layer's background coverage,
                            // pass 1 adds this layer's own light. Back to front
                            // over the layer list, which is the screen order the
                            // extract pass otherwise has no way to honour.
                            // The rows this layer's own smooth scroll retained
                            // are drawn with its others (see resolveLayerRow),
                            // so they light the same way. Glow forces .clear, so
                            // a row missing here has no previous frame and no
                            // root-side extraction to fall back on: the root
                            // pass takes only gridId == 1 retained rows.
                            let retainedForGlowCount = collectLayerRetainedRows(layer.gridId)
                            for pass in 0..<2 {
                                if pass == 0 {
                                    guard let occludePipe = shared.glowOccludePipeline else { continue }
                                    enc.setRenderPipelineState(occludePipe)
                                } else {
                                    enc.setRenderPipelineState(extractPipe)
                                }
                                for row in 0..<rowCount {
                                    let slot = set.rowLogicalToSlot[row]
                                    guard slot >= 0, slot < set.rowState.buffers.count,
                                          let vb = set.rowState.buffers[slot],
                                          set.rowState.counts[slot] > 0
                                    else { continue }
                                    let sourceRow = slot < set.rowSlotSourceRows.count
                                        ? set.rowSlotSourceRows[slot]
                                        : row
                                    var rt = Float(row - sourceRow) * Float(cellHi)
                                    enc.setVertexBytes(&rt, length: MemoryLayout<Float>.size, index: 3)
                                    enc.setVertexBuffer(vb, offset: 0, index: 0)
                                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: set.rowState.counts[slot])
                                }
                                for i in 0..<retainedForGlowCount {
                                    let r = retainedSnapshot[retainedIndexScratch[i]]
                                    guard r.count > 0 else { continue }
                                    var rt = Float(r.targetRow - r.sourceRow) * Float(cellHi)
                                    enc.setVertexBytes(&rt, length: MemoryLayout<Float>.size, index: 3)
                                    enc.setVertexBuffer(r.buffer, offset: 0, index: 0)
                                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: r.count)
                                }
                            }
                        }
                    }

                    // Cursor glow
                    if cursorBlinkStateSnapshot, currentCursorCount > 0, let cvb = committedCursor.vertexBuffer {
                        var ct: Float = 0
                        // The cursor is in its own layer's pixel space.
                        bindLayerTransform(
                            encoder: enc,
                            LayerTransform(
                                originPx: cursorLayerOriginSnapshot,
                                extentPx: simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)
                            )
                        )
                        enc.setVertexBytes(&ct, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(cvb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentCursorCount)
                        bindLayerTransform(encoder: enc, viewportMetrics.layerTransform)
                    }
                    }

            guard glowPassSucceeded else {
                submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseFrameState)
                gpuSubmitted = true
                // Submitted but never presented — see "render encoder creation
                // failed" above for why this is set here, why not on "no
                // drawable", and why it takes the lock.
                lock.lock()
                hasPresentedOnce = false
                lock.unlock()
                bailWithoutSubmit("glow resource/encoder creation failed")
                return
            }

            // Delay CAMetalLayer acquisition until the final drawable copy.
            // All earlier work targets persistent textures, so acquiring here
            // shortens drawable ownership and reduces pool-starvation risk.
            var t_drawable_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_drawable_start = CFAbsoluteTimeGetCurrent()
            }
            FrameTracer.trace(.drawableAcquireBegin)
            guard let drawable = view.currentDrawable else {
                FrameTracer.trace(.drawSkipNoDrawable)
                // Commit the already-encoded persistent-texture work so Metal
                // can reclaim the command buffer. A full dirty retry heals the
                // consumed scroll state before the next presentation.
                submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseFrameState)
                gpuSubmitted = true
                bailWithoutSubmit("no drawable after back-buffer encode")
                return
            }
            FrameTracer.trace(.drawableAcquireEnd)
            if ZonvieCore.appLogEnabled {
                let drawable_us = (CFAbsoluteTimeGetCurrent() - t_drawable_start) * 1_000_000
                ZonvieCore.appLogPerf("[perf] draw_acquire_drawable us=\(String(format: "%.1f", drawable_us))")
            }

            // === PERF LOG: Copy開始 ===
            var t_copy_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_copy_start = CFAbsoluteTimeGetCurrent()
            }

            // --- 2) Copy back buffer to drawable using render pass (replaces Blit) ---
            // currentDrawable.texture can be a fresh texture each frame, so a
            // dirty-region-only copy leaves the rest undefined: copy it whole.
            // A render pass, not MTLBlitCommandEncoder, because blit shaders
            // cannot be cached in MTLBinaryArchive and the XPC compiler service
            // is unavailable after fork().

            // User-supplied custom post-process shaders take over the
            // backTex -> drawable step when configured in `.afterBloom`
            // mode. See ExternalGridView.draw for the external-grid path,
            // which drives the same chain through the same helper.
            // Shared with ExternalGridView: the chain-or-copy ladder is one
            // function now, and the two closures are the only places the
            // surfaces differ.
            // Cleared HERE, not at the gate: between the two this frame can
            // still give up (no drawable, semaphore busy, no back buffer), and
            // clearing early stranded the signal — `evaluate` reports a move
            // once, so a frame that consumed it and then bailed left every
            // later frame with nothing to say and the effect at its old place.
            shaderCursorMovedThisFrame = false
            let presentation = encodeSurfaceBackBufferToDrawable(
                cmd: cmd,
                backTex: backTex,
                drawableTexture: drawable.texture,
                customShaderPipelines: shared.customShaderChain(decorated: false),
                runsCustomShaderChain: shared.customShaderPostProcess == .afterBloom,
                customShaderPong: customShaderPong,
                pongSize: view.drawableSize,
                copyPipeline: shared.copyPipeline,
                copyVertexBuffer: shared.copyVertexBuffer,
                sampler: shared.sampler,
                bilinearSampler: shared.bilinearSampler,
                makeUniforms: {
                    shared.makeShaderUniforms(
                        screenResolution: view.drawableSize,
                        windowOffset: .zero,
                        windowSize: view.drawableSize,
                        backingScale: backingScale,
                        lastLoggedCursor: &lastLoggedShaderCursor
                    )
                },
                prepareCopy: { copyRPD in
                    // Full 4-stage sampling (vertex + fragment) on the copy
                    // pass to investigate why it measures ~2.9ms vs ~0.7ms
                    // theoretical.
                    gpuSampler.attachFull(to: copyRPD, label: "copy")
                    gpuSampler.attachStats(to: copyRPD, label: "copy")
                }
            )

            guard presentation.encoded else {
                // Submit the already-encoded back-buffer work so Metal can
                // reclaim this command buffer, but do not present an
                // untouched drawable or consume the frame's dirty state.
                submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseFrameState)
                gpuSubmitted = true
                // Submitted but never presented — see "render encoder creation
                // failed" above for why this is set here, why not on "no
                // drawable", and why it takes the lock.
                lock.lock()
                hasPresentedOnce = false
                lock.unlock()
                bailWithoutSubmit("final copy encoder creation failed")
                return
            }

            // === PERF LOG: Copy終了 ===
            if ZonvieCore.appLogEnabled {
                let t_copy_end = CFAbsoluteTimeGetCurrent()
                let copy_us = (t_copy_end - t_copy_start) * 1_000_000
                ZonvieCore.appLogPerf("[perf] draw_copy us=\(String(format: "%.1f", copy_us))")

                // Copy-pass dirty-region opportunity: characterizes how much of the
                // drawable actually changed this frame so we can quantify Option B
                // (skip / partial copy). Pairs 1:1 with [perf] gpu_passes copy_us.
                //   dirty_rows=N    : rows the main pass actually rewrote
                //   dirty_h_px=H    : bbox height in pixels (not row-count * cellH;
                //                     accounts for non-contiguous dirty)
                //   drawable_h_px=DH: full drawable height
                //   dirty_pct=P     : H / DH × 100 (how much of vertical extent
                //                     could be omitted from the copy)
                //   category        : full | partial | scroll | blink | shader |
                //                     noop  (what the frame actually was)
                //   noop_eligible   : true when nothing main-touched and no blink,
                //                     i.e. copy is structurally avoidable if we
                //                     had drawable preservation
                let cellHpx = max(1, Int(cellHi))
                let drawableHpx = max(1, Int(drawableHi))
                var minRow = Int.max
                var maxRow = Int.min
                for r in dirtyRows {
                    if r < minRow { minRow = r }
                    if r > maxRow { maxRow = r }
                }
                let dirtyHpx: Int
                if dirtyRows.isEmpty {
                    dirtyHpx = 0
                } else {
                    dirtyHpx = max(0, maxRow - minRow + 1) * cellHpx
                }
                let dirtyPct = Double(dirtyHpx) * 100.0 / Double(drawableHpx)
                let category: String
                if presentation.tookCustomShaderChain {
                    category = "shader"
                } else if smoothScrolling || useGpuScrollCopy {
                    category = "scroll"
                } else if isBlinkOnlyFrame {
                    category = "blink"
                } else if !rowMode {
                    category = "full"
                } else if dirtyRows.isEmpty {
                    category = "noop"
                } else if dirtyPct >= 95.0 {
                    category = "full"
                } else {
                    category = "partial"
                }
                let noopEligible = dirtyRows.isEmpty
                    && !smoothScrolling
                    && !useGpuScrollCopy
                    && !drawableSizeChanged
                    && !blinkStateChanged
                    && hasPresentedOnceSnapshot
                    && !presentation.tookCustomShaderChain
                ZonvieCore.appLogPerf("[perf] copy_opportunity dirty_rows=\(dirtyRows.count) dirty_h_px=\(dirtyHpx) drawable_h_px=\(drawableHpx) dirty_pct=\(String(format: "%.1f", dirtyPct)) category=\(category) noop_eligible=\(noopEligible)")
            }

            // Cursor is composited only on the final drawable.
            // This keeps the persistent back buffer cursor-free and prevents stale
            // cursor pixels from being moved by GPU scroll-region copies.
            ZonvieCore.appLog("[cursor-draw] cursorBlinkState=\(cursorBlinkStateSnapshot) cursorCount=\(currentCursorCount)")
            if cursorBlinkStateSnapshot, currentCursorCount > 0, let cvb = committedCursor.vertexBuffer {
                // Shared with ExternalGridView. The two closures below are the
                // only places the surfaces differ: perf samples, and an array
                // of per-grid offsets where an external surface binds one.
                let cursorEncoded = encodeSurfaceCursorOverlay(
                    cmd: cmd,
                    drawableTexture: drawable.texture,
                    pipeline: shared.pipeline!,
                    atlasTexture: atlasTex,
                    sampler: shared.sampler!,
                    viewportMetrics: viewportMetrics,
                    cursorVertexBuffer: cvb,
                    cursorVertexCount: currentCursorCount,
                    layerOriginPx: cursorLayerOriginSnapshot,
                    backgroundAlphaBuffer: backgroundAlphaBuffer,
                    cursorBlinkBuffer: cursorBlinkBuffer,
                    fixedFloatBands: fixedFloatBandsSnapshot,
                    // mask a scrolling cursor under a fixed float
                    fixedFloatIntervals: fixedFloatIntervalsSnapshot,
                    prepare: { cursorRPD in
                        gpuSampler.attach(to: cursorRPD, label: "cursor")
                        gpuSampler.attachStats(to: cursorRPD, label: "cursor")
                    },
                    bindScrollOffsets: { cursorEnc in
                        bindSurfaceScrollOffsets(
                            encoder: cursorEnc,
                            offsets: scrollSnapshot,
                            device: shared.device,
                            scratchBuffer: &committedCursor.scrollOffsetBuffer,
                            scratchCapacity: &committedCursor.scrollOffsetBufferCap
                        )
                    }
                )
                if !cursorEncoded {
                    // The drawable copy was encoded, but presenting it without
                    // the requested cursor would consume cursor_rev and leave a
                    // visibly incomplete transaction. Submit the already-
                    // encoded back-buffer work only to release driver resources,
                    // then roll the frame state back for a complete retry.
                    submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseFrameState)
                    gpuSubmitted = true
                    // Submitted but never presented — see "render encoder creation
                    // failed" above for why this is set here, why not on "no
                    // drawable", and why it takes the lock.
                    lock.lock()
                    hasPresentedOnce = false
                    lock.unlock()
                    bailWithoutSubmit("cursor encoder creation failed")
                    return
                }
            }

            if FrameTracer.enabled {
                // presentedTime shares CACurrentMediaTime's base, which is the
                // same clock as FrameTracer.nowNs (CLOCK_UPTIME_RAW), so the
                // on-glass timestamp lines up with the CPU-side events.
                // a = presentedTime in ns (0 when the frame never reached the
                // display), b = the drawBegin-side timestamp of this frame.
                let submitNs = FrameTracer.nowNs()
                drawable.addPresentedHandler { d in
                    let t = d.presentedTime
                    let presentedNs = t > 0 ? UInt64(t * 1_000_000_000.0) : 0
                    FrameTracer.trace(.presented, a: presentedNs, b: submitNs)
                }
            }
            var t_present_start: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled {
                t_present_start = CFAbsoluteTimeGetCurrent()
                if !hasPresentedOnceSnapshot {
                    ZonvieCore.appLog("[startup] first present scheduled (cmd.present called)")
                }
                // On-glass presentation cadence: presentedTime is the host time
                // the frame actually hit the display (0 if it never did). The
                // interval between consecutive presentedTimes is the ground
                // truth for vsync slips that CPU-side draw timing cannot see.
                let presentLock = lock
                drawable.addPresentedHandler { [weak self] d in
                    guard ZonvieCore.appLogEnabled else { return }
                    let t = d.presentedTime
                    guard t > 0 else {
                        ZonvieCore.appLogPerf("[perf] presented skipped=true")
                        return
                    }
                    var prev: CFTimeInterval = 0
                    if let self {
                        presentLock.lock()
                        prev = self.lastPresentedTime
                        self.lastPresentedTime = t
                        presentLock.unlock()
                    }
                    if prev > 0 {
                        ZonvieCore.appLogPerf("[perf] presented interval_ms=\(String(format: "%.3f", (t - prev) * 1000.0)) t_ms=\(String(format: "%.3f", t * 1000.0))")
                    } else {
                        ZonvieCore.appLogPerf("[perf] presented first t_ms=\(String(format: "%.3f", t * 1000.0))")
                    }
                }
            }
            FrameTracer.trace(.presentCall)
            cmd.present(drawable)
            FrameTracer.trace(.gpuSubmit)
            // `sem` and `lk` are the ones captured for `releaseFrameState`
            // above, for the same reason: the signal has to fire even if the
            // renderer is deallocated before the GPU finishes.
            // Wall-time clock at submission, used to compute gpu_wall_us
            // (queue + GPU + present scheduling latency) inside the completion
            // handler. gpu_exec_us comes from Metal's own gpuStart/gpuEndTime.
            let t_gpu_submit: CFAbsoluteTime = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
            // Snapshot per-pass slots + sample buffers + tick scale for the
            // completion handler. The sampler reuses its slot arrays next frame,
            // so a value-typed copy keeps this frame's data alive until resolve.
            // Gated on appLogEnabled so when logging is off the copy is empty
            // constants instead of array copies / ref bumps.
            let gpuFrame = gpuSampler.frameSnapshot(logging: ZonvieCore.appLogEnabled)
            cmd.addCompletedHandler { [weak self, weak view] completed in
                if FrameTracer.enabled {
                    // a/b = Metal's own GPU start/end in ns, so GPU execution
                    // can be separated from queue + present scheduling latency.
                    FrameTracer.trace(
                        .gpuComplete,
                        a: UInt64(max(0, completed.gpuStartTime) * 1_000_000_000.0),
                        b: UInt64(max(0, completed.gpuEndTime) * 1_000_000_000.0)
                    )
                }
                // Always release GPU in-flight mark + semaphore, even if self is gone.
                lk.lock()
                self?.completeSurfaceGpuReadLocked(csi)
                self?.cursorGpuInFlightCount[cci] -= 1
                lk.unlock()
                sem.signal()

                if ZonvieCore.appLogEnabled {
                    let gpu_wall_us = (CFAbsoluteTimeGetCurrent() - t_gpu_submit) * 1_000_000
                    let gpu_exec_us = (completed.gpuEndTime - completed.gpuStartTime) * 1_000_000
                    ZonvieCore.appLogPerf("[perf] gpu_execution exec_us=\(String(format: "%.1f", gpu_exec_us)) wall_us=\(String(format: "%.1f", gpu_wall_us))")

                    // Per-pass GPU breakdown via stage-boundary timestamps.
                    // Pairs with gpu_execution: per-pass durations should sum to
                    // ≤ exec_us (the gap is tile-binning / submit overhead).
                    // gpuFrame.sampleCount covers both fragment-only slots and full
                    // (vertex+fragment) slots, allocated contiguously in the
                    // shared sample buffer by the sampler.
                    if let buf = gpuFrame.timestampBuffer, gpuFrame.sampleCount > 0,
                       (!gpuFrame.slots.isEmpty || !gpuFrame.fullSlots.isEmpty)
                    {
                        if let data = try? buf.resolveCounterRange(0..<gpuFrame.sampleCount) {
                            data.withUnsafeBytes { raw in
                                let ts = raw.bindMemory(to: MTLCounterResultTimestamp.self)
                                guard ts.count >= gpuFrame.sampleCount else { return }
                                var msg = "[perf] gpu_passes"
                                for slot in gpuFrame.slots {
                                    let s = ts[slot.startIdx].timestamp
                                    let e = ts[slot.endIdx].timestamp
                                    let ticks = (e >= s) ? Double(e &- s) : 0
                                    let us = ticks * gpuFrame.tickPeriodNs / 1000.0
                                    msg += " \(slot.label)_us=\(String(format: "%.1f", us))"
                                }
                                // Full-stage slots: report fragment_us under
                                // the same `<label>_us=` field so the existing
                                // analyzer keeps working, then emit a separate
                                // [perf] gpu_pass_detail line with the full
                                // vertex/gap/fragment/total breakdown.
                                for slot in gpuFrame.fullSlots {
                                    let sF = ts[slot.startFIdx].timestamp
                                    let eF = ts[slot.endFIdx].timestamp
                                    let fragTicks = (eF >= sF) ? Double(eF &- sF) : 0
                                    let fragUs = fragTicks * gpuFrame.tickPeriodNs / 1000.0
                                    msg += " \(slot.label)_us=\(String(format: "%.1f", fragUs))"
                                }
                                ZonvieCore.appLogPerf(msg)

                                // Detail for full-stage slots: vertex / vfgap /
                                // fragment / total. vfgap is start_f - end_v —
                                // idle between stages, often dominated by
                                // waiting for the previous pass's tile store.
                                for slot in gpuFrame.fullSlots {
                                    let sV = ts[slot.startVIdx].timestamp
                                    let eV = ts[slot.endVIdx].timestamp
                                    let sF = ts[slot.startFIdx].timestamp
                                    let eF = ts[slot.endFIdx].timestamp
                                    func usOf(_ a: UInt64, _ b: UInt64) -> Double {
                                        let t = (b >= a) ? Double(b &- a) : 0
                                        return t * gpuFrame.tickPeriodNs / 1000.0
                                    }
                                    let vUs = usOf(sV, eV)
                                    let gapUs = usOf(eV, sF)
                                    let fUs = usOf(sF, eF)
                                    let totalUs = usOf(sV, eF)
                                    ZonvieCore.appLogPerf(
                                        "[perf] gpu_pass_detail \(slot.label) " +
                                        "vertex_us=\(String(format: "%.1f", vUs)) " +
                                        "vfgap_us=\(String(format: "%.1f", gapUs)) " +
                                        "fragment_us=\(String(format: "%.1f", fUs)) " +
                                        "total_us=\(String(format: "%.1f", totalUs))"
                                    )
                                }
                            }
                        }
                    }

                    // Per-pass fragment invocations (overdraw numerator). Pairs
                    // with copy_opportunity dirty_h_px / drawable info to
                    // compute true overdraw per pass. Validates whether the
                    // 2-pass-for-blur path actually doubles fragment work.
                    if let buf = gpuFrame.statsBuffer, !gpuFrame.statsSlots.isEmpty {
                        let total = gpuFrame.statsSlots.count * 2
                        if let data = try? buf.resolveCounterRange(0..<total) {
                            data.withUnsafeBytes { raw in
                                let st = raw.bindMemory(to: MTLCounterResultStatistic.self)
                                guard st.count >= total else { return }
                                var msg = "[perf] gpu_overdraw"
                                for slot in gpuFrame.statsSlots {
                                    let s = st[slot.startIdx].fragmentInvocations
                                    let e = st[slot.endIdx].fragmentInvocations
                                    let inv = (e >= s) ? (e &- s) : 0
                                    msg += " \(slot.label)_frags=\(inv)"
                                }
                                ZonvieCore.appLogPerf(msg)
                            }
                        }
                    }
                }

                guard let self = self else { return }
                guard completed.status == .completed else {
                    self.lock.lock()
                    self.hasPresentedOnce = false
                    self.lock.unlock()
                    ZonvieCore.appLog("[WARNING] Metal command failed (status=\(completed.status.rawValue)); forcing full redraw")
                    DispatchQueue.main.async { [weak view] in
                        (view as? MetalTerminalView)?.requestRedraw()
                    }
                    return
                }
                self.lock.lock()
                let wasFirstPresent = !self.hasPresentedOnce
                self.hasPresentedOnce = true
                self.lock.unlock()
                if ZonvieCore.appLogEnabled, wasFirstPresent {
                    ZonvieCore.appLog("[startup] first present completed (GPU done)")
                }
                if wasFirstPresent {
                    // Now that the first frame is on screen, flush any
                    // guifont payload that was deferred from onGuiFont. The
                    // atlas rebuild and updateLayoutPx must run on main so
                    // they don't race with another draw cycle.
                    DispatchQueue.main.async { [weak view] in
                        (view as? MetalTerminalView)?.core?.markFirstPresentDone()
                    }
                }

                if wasFirstPresent { recalculateSurfaceShadowAfterFirstPresent(view) }
            }
            cmd.commit()
            if ZonvieCore.appLogEnabled {
                let present_commit_us = (CFAbsoluteTimeGetCurrent() - t_present_start) * 1_000_000
                ZonvieCore.appLogPerf("[perf] draw_present_commit us=\(String(format: "%.1f", present_commit_us))")
            }
            gpuSubmitted = true  // Completion handler handles cleanup; prevent defer

            // === PERF LOG: draw終了 ===
            if ZonvieCore.appLogEnabled {
                let t_draw_end = CFAbsoluteTimeGetCurrent()
                let draw_ms = (t_draw_end - t_draw_start) * 1000.0
                ZonvieCore.appLogPerf("[perf] draw_total rowMode=\(rowMode) dirtyRows=\(dirtyRows.count) ms=\(String(format: "%.2f", draw_ms))")
                if let inputTrace = (view as? MetalTerminalView)?.core?.currentInputTraceSnapshot(),
                   inputTrace.seq != 0,
                   inputTrace.sentNs != 0,
                   inputTrace.lastDrawLoggedSeq != inputTrace.seq
                {
                    let nowNs = zonvie_core_perf_now_ns()
                    let deltaUs = max(Int64(0), (nowNs - inputTrace.sentNs) / 1_000)
                    ZonvieCore.appLogPerf("[perf_input] seq=\(inputTrace.seq) stage=draw_end delta_us=\(deltaUs) rowMode=\(rowMode) dirtyRows=\(dirtyRows.count)")
                    (view as? MetalTerminalView)?.core?.markInputTraceDrawLogged(seq: inputTrace.seq)
                }
            }

            (view as? MetalTerminalView)?.didDrawFrame()
        }
    }

    // safeNeededBytes / growCapacity are provided by MetalTypes.swift as
    // surfaceSafeNeededBytes() / surfaceGrowCapacity().
    
    /// Ensure main vertex buffer in the specified buffer set has sufficient capacity.
    /// If the buffer is shared with the committed set (COW), detach by reusing
    /// the pool buffer saved in beginFlush, or allocate new if pool is insufficient.
    private func ensureMainBufferInSet(_ setIdx: Int, vertexCount: Int) {
        let vc = max(0, vertexCount)
        guard let needed = surfaceSafeNeededBytes(vertexCount: vc) else {
            flushFailed = true
            return
        }

        let srcMain = bufferSets[flushSourceSetIndex].mainVertexBuffer
        let sharesSource = setIdx == writeSetIndex && srcMain != nil
            && bufferSets[setIdx].mainVertexBuffer === srcMain
        let needsNew = sharesSource
            || bufferSets[setIdx].mainVertexBuffer == nil
            || needed > bufferSets[setIdx].mainVertexBufferCap

        if needsNew {
            guard let nextCap = surfaceGrowCapacity(current: bufferSets[setIdx].mainVertexBufferCap, needed: max(1, needed)) else {
                flushFailed = true
                return
            }

            // Try detach pool first.
            // Guard: pool buffer must not alias the source (committed) main
            // buffer NOR the main buffer of a GPU in-flight set — the COW
            // chain can leave the same object shared into an older set the
            // GPU is still reading (see ensureSurfaceRowBuffer).
            let bs = bufferSets[setIdx]
            if let poolBuf = bs.detachPoolMainBuffer,
               bs.detachPoolMainCap >= nextCap,
               poolBuf !== srcMain,
               poolBuf !== inflightMainBuffer()
            {
                bs.mainVertexBuffer = poolBuf
                bs.mainVertexBufferCap = bs.detachPoolMainCap
                bs.detachPoolMainBuffer = nil
            } else {
                bs.mainVertexBufferCap = nextCap
                bs.mainVertexBuffer = shared.device.makeBuffer(length: nextCap, options: .storageModeShared)
                if bs.mainVertexBuffer == nil {
                    bs.mainVertexBufferCap = 0
                    flushFailed = true
                }
            }
        }
    }

    /// Ensure one cursor slot's vertex buffer has room for `vertexCount`.
    ///
    /// No COW detach: a cursor callback replaces the cursor outright, so a slot
    /// never shares a buffer with the committed one (see
    /// `prepareCursorWriteState`). Allocate only when nil or too small.
    private func ensureCursorBufferInSet(_ setIdx: Int, vertexCount: Int) {
        let vc = max(0, vertexCount)
        guard let needed = surfaceSafeNeededBytes(vertexCount: vc) else {
            flushFailed = true
            return
        }
        let slot = cursorSlots[setIdx]
        guard slot.vertexBuffer == nil || needed > slot.vertexBufferCap else { return }
        guard let nextCap = surfaceGrowCapacity(current: slot.vertexBufferCap, needed: max(1, needed)) else {
            flushFailed = true
            return
        }
        slot.vertexBufferCap = nextCap
        slot.vertexBuffer = shared.device.makeBuffer(length: nextCap, options: .storageModeShared)
        if slot.vertexBuffer == nil {
            slot.vertexBufferCap = 0
            flushFailed = true
        }
    }


    /// Raise the retention to cover a band this many rows wide. Set from the
    /// scroll input path, where a wheel event's row count is known.
    func setRetentionDepthRows(_ rows: Int) {
        retention.setDepthRows(rows)
    }

    /// How many rows of displacement the retention can currently cover. The
    /// keyboard ease clamps its offset to this: lagging further than the band
    /// can show would snap the picture when the clamp caught up.
    var retentionDepthRows: Int { retention.depthRows }

    /// Retain the outgoing row of a grid the row-scroll fast path cannot cover.
    /// A non-full-width window (vertical split, float) always fails that path on
    /// partial width, so applyLayerRowScroll — and with it
    /// captureLayerScrollStep — never runs for it: its outgoing row is
    /// recomposed away within the flush and the vacated band falls back to the
    /// edge-row background stretch, which paints the neighbouring row's
    /// highlight across it. Full-width grids are armed too, so the two paths
    /// overlap; `bracketStagedGrids` is what keeps them from staging the same
    /// movement twice.
    ///
    /// Called from the on_grid_scroll callback, inside the flush bracket and
    /// before row recomposition, so the flush's source set still holds the
    /// on-screen content. Only the grid's own DECO_SCROLLABLE vertices are
    /// copied: composite rows mix the grid with its backdrop, and its
    /// border/margin cells must not ease. No ease seed is staged here — the
    /// trackpad gesture owns the offset it reconciles against;
    /// captureLayerScrollStep stages the seed for the steps that need one.
    func captureRetainedRowForGridScroll(gridId: Int64, rowsDelta: Int) {
        captureRetainedRowForGridScroll(gridId: gridId, rowsDelta: rowsDelta, replaying: false)
    }

    private func captureRetainedRowForGridScroll(gridId: Int64, rowsDelta: Int, replaying: Bool) {
        guard Self.smoothScrollEnabled, rowsDelta != 0, isInFlush else { return }

        lock.lock()
        let bounds = gridScrollCaptureBounds[gridId]
        let capturable = (bounds?.bottomEx ?? 0) > (bounds?.top ?? 0)
        // The core hands a grid_scroll over exactly once (see e2e
        // grid_scroll_abort_delivery) and beginFlush discards retention staged
        // by a bracket that did not commit, so the step would be lost outright:
        // remember it here and stage it again next bracket. The rows come from
        // the committed set, which an aborted bracket left untouched.
        //
        // Only steps that could actually be staged are remembered: a grid with
        // no armed bounds would otherwise spend slots in the window and evict a
        // real step.
        if !replaying, capturable {
            pendingRetentionReplay.append((gridId: gridId, rowsDelta: rowsDelta))
            if pendingRetentionReplay.count > Self.maxPendingRetentionReplay {
                pendingRetentionReplay.removeFirst(
                    pendingRetentionReplay.count - Self.maxPendingRetentionReplay
                )
            }
        }
        // How far the source set is behind what this step describes. A replayed
        // step did not move the committed content, so a capture that follows it
        // in the same bracket must read that much further into the set or it
        // retains the same line twice.
        let sourceShift = bracketSourceShift[gridId] ?? 0
        bracketSourceShift[gridId] = sourceShift + rowsDelta
        lock.unlock()
        guard let bounds, capturable else {
            ZonvieCore.appLog("[retain] skip grid=\(gridId) rowsDelta=\(rowsDelta) no armed bounds")
            return
        }

        // Read the scrolling grid's OWN rows: every grid keeps its own buffers
        // and its own row space now, so the bounds above are grid-local.
        let cs = (gridBuffers.existingSets(for: gridId) ?? bufferSets)[flushSourceSetIndex]
        // A step is routinely more than one row (a whole wheel event's
        // 'mousescroll' worth, coalesced), but the retention holds only
        // `depthRows` — the offset is clamped to the same reach — so the
        // shared step keeps the rows adjacent to the edge the block left
        // through.
        let captured = captureSurfaceGridScrollStep(
            gridId: gridId,
            cs: cs,
            bounds: bounds,
            rowsDelta: rowsDelta,
            sourceShift: sourceShift,
            retention: retention,
            lock: lock,
            bracketStagedGrids: &bracketStagedGrids
        ) { cs, readRow, targetRow in
            captureOneRetainedRow(cs: cs, gridId: gridId, readRow: readRow, targetRow: targetRow)
        }
        if !captured {
            ZonvieCore.appLog(
                "[retain] skip grid=\(gridId) rowsDelta=\(rowsDelta) no row buffers or no plan (top=\(bounds.top) bottomEx=\(bounds.bottomEx) depth=\(retention.depthRows))"
            )
        }
    }

    /// Copy one outgoing row's own scrollable vertices into the retention ring
    /// and append it to the open step. A row with nothing to retain is skipped,
    /// and the band falls back to the edge stretch. `readRow` is where the row
    /// currently sits in the source set, `targetRow` where it must be drawn;
    /// they differ by more than rowsDelta once a replayed step has moved content
    /// the source set has not caught up with.
    private func captureOneRetainedRow(
        cs: SurfaceBufferSet,
        gridId: Int64,
        readRow: Int,
        targetRow: Int
    ) {
        let row = readRow
        guard row >= 0, row < cs.rowLogicalToSlot.count else { return }
        let slot = cs.rowLogicalToSlot[row]
        guard slot >= 0, slot < cs.rowState.counts.count, slot < cs.rowState.buffers.count else { return }
        let vc = cs.rowState.counts[slot]
        guard vc > 0, let srcBuf = cs.rowState.buffers[slot] else { return }
        let sourceRow = slot < cs.rowSlotSourceRows.count ? cs.rowSlotSourceRows[slot] : row
        let capturedCellHeightPx = shared.cellHeightPx
        // Content cells only — see copyRetainedScrollableRow.
        guard let copied = copyRetainedScrollableRow(
            retention: retention,
            srcBuf: srcBuf,
            vertexCount: vc,
            gridId: gridId,
            scrollableMask: ZONVIE_DECO_SCROLLABLE
        ) else { return }

        retention.stage(RetainedScrollRow(
            buffer: copied.buffer,
            count: copied.count,
            gridId: gridId,
            sourceRow: sourceRow,
            targetRow: targetRow,
            cellHeightPx: capturedCellHeightPx
        ))
    }


    /// Retain the rows a layer's shift takes out of view, and stage the ease
    /// seed for it. The core hands the scrolled region over here, so a keyboard
    /// scroll is covered without the gesture-armed spans
    /// captureRetainedRowForGridScroll depends on — a held key never sends the
    /// gesture that arms them.
    ///
    /// The seed is staged for every single-row step, gesture or not, and the
    /// view decides whether to spend it: tickSmoothScroll drops a seed for a
    /// grid a gesture owns, which already holds compensation of its own. Gating
    /// it here would need gesture state the main thread owns, and would drop the
    /// held-key seed on exactly the steps that need it.
    ///
    /// A larger jump — page motion, a resize — is not seeded: it would displace
    /// the picture by the whole jump and ease back only the rows the retention
    /// can cover. The rows are still retained, and the draw path prunes them.
    /// Shared with ExternalGridView (`captureSurfaceLayerScrollStep`); this
    /// surface resolves a retained row through `captureOneRetainedRow` and
    /// guards its state with its single lock.
    private func captureLayerScrollStep(
        gridId: Int64,
        sets: [SurfaceBufferSet],
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int
    ) {
        guard Self.smoothScrollEnabled else { return }
        captureSurfaceLayerScrollStep(
            gridId: gridId,
            sets: sets,
            flushSourceSetIndex: flushSourceSetIndex,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            retention: retention,
            lock: lock,
            bracketStagedGrids: &bracketStagedGrids,
            stagedSmoothScrollSeeds: &stagedSmoothScrollSeeds
        ) { cs, readRow, targetRow in
            captureOneRetainedRow(cs: cs, gridId: gridId, readRow: readRow, targetRow: targetRow)
        }
    }

    /// Drain the ease seeds committed since the last call. The view converts
    /// them into a pixel offset and decays it; the renderer only records which
    /// grid moved by how much, because the vertices it retained carry the grid
    /// tag the shader will match.
    func takeSmoothScrollSeeds() -> [(gridId: Int64, rowsDelta: Int)] {
        guard Self.smoothScrollEnabled else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard !smoothScrollSeeds.isEmpty else { return [] }
        let seeds = smoothScrollSeeds
        smoothScrollSeeds.removeAll(keepingCapacity: true)
        return seeds
    }

    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int, totalCols: Int) {
        guard isInFlush else {
            ZonvieCore.appLog("[WARNING] submitVerticesRowRaw called outside flush bracket")
            return
        }
        let updateMain = (flags & UInt32(ZONVIE_VERT_UPDATE_MAIN)) != 0
        let updateCursor = (flags & UInt32(ZONVIE_VERT_UPDATE_CURSOR)) != 0
        if updateCursor && !updateMain {
            guard count != 0 || cursorOwner.owns(1) else {
                ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_ignore surface=1 grid=1 owner=\(cursorOwner.staged ?? 1) reason=empty_nonowner")
                return
            }
            cursorOwner.stage(1, rootRow: rowStart)
            submitVerticesPartialRaw(
                mainPtr: nil,
                mainCount: 0,
                cursorPtr: UnsafeRawPointer(ptr),
                cursorCount: count,
                updateMain: false,
                updateCursor: true
            )
            return
        }
        guard updateMain else { return }
        if rowCount == 0 {
            guard count == 0,
                  prepareMainWriteState(),
                  applySurfaceZeroCellLayout(
                    bufferSet: bufferSets[writeSetIndex],
                    totalRows: totalRows,
                    totalCols: totalCols
                  )
            else {
                flushFailed = true
                return
            }
            flushChangedMainRows.removeAll()
            flushHasStructuralMainChange = true
            return
        }
        // Content submissions are one row at a time (contract in Zig onFlush).
        // A preceding scroll may already have remapped the write set. Select
        // and synchronize that set before resolving the physical capacity
        // slot, otherwise the retry worker grows the source slot forever.
        guard prepareMainWriteState() else { return }

        let perfEnabled = ZonvieCore.appLogEnabled
        let t0 = perfEnabled ? zonvie_core_perf_now_ns() : 0
        let sourceSet = bufferSets[flushSourceSetIndex]
        let changesRowStructure = !sourceSet.rowState.usingRowBuffers
            || totalRows != sourceSet.knownTotalRows
            || totalCols != sourceSet.knownTotalCols
        // Allocate synchronously: the async pre-provisioning gate this replaced
        // does not converge under sustained scroll (same reasoning as
        // ExternalGridView.applyRowScroll). requirePreparedRowCapacity below
        // only records a real allocation failure for the async recovery path.
        let submitted = submitSurfaceRowVertices(
            target: bufferSets[writeSetIndex],
            sourceSet: sourceSet,
            device: shared.device,
            rowStart: rowStart,
            ptr: UnsafeRawPointer(ptr),
            count: count,
            maxRowBuffers: maxRowBuffers,
            totalRows: totalRows,
            totalCols: totalCols,
            inflightRowBuffers: { (self.inflightRowBuffer(atSlot: $0), nil) }
        )
        if !submitted {
            _ = requirePreparedRowCapacity(
                row: rowStart,
                vertexCount: count,
                totalRows: totalRows,
                useWriteMapping: true
            )
            flushFailed = true
        } else if changesRowStructure {
            flushHasStructuralMainChange = true
        } else {
            flushChangedMainRows.insert(rowStart)
        }
        if perfEnabled {
            let dt = zonvie_core_perf_now_ns() - t0
            perfRowSubmitNs &+= dt
            perfRowSubmitCalls &+= 1
            perfRowSubmitVerts &+= count
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
            // isInFlush is core-thread-only; all in-flush callers of this
            // method run on the core thread (row/partial submit paths).
            if isInFlush {
                flushDirtyRows.insert(integersIn: rowStart..<end)
            }
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

        // isInFlush is core-thread-only; all in-flush callers of this
        // method run on the core thread (cursor erase path).
        if isInFlush {
            if let cur = flushDirtyRectPx {
                flushDirtyRectPx = cur.union(rectPx)
            } else {
                flushDirtyRectPx = rectPx
            }
            if rowCount > 0 {
                let end = max(rowStart, rowStart + rowCount)
                flushDirtyRows.insert(integersIn: rowStart..<end)
            }
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

    /// Mark every layer for a full redraw, the layer counterpart of
    /// markAllRowsDirty: a bailed draw already consumed each layer's pending
    /// rows and shift, and a full redraw of the layer heals the shift it never
    /// applied, since the committed vertices are already post-scroll.
    func markAllLayersDirty() {
        lock.lock()
        defer { lock.unlock() }
        for state in layerDrawStates.values {
            state.needsFullRedraw = true
            state.drawScroll = nil
        }
    }

}
