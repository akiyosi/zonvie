import AppKit
import Metal
import MetalKit
import simd

private let metalTerminalMaxRowBuffers = 20_000

/// Allocation-free sparse set used only by the core/render callback thread.
/// The row list makes synchronization O(changed rows); the bitset prevents a
/// repeatedly updated row from growing that list. Capacity is reserved during
/// renderer construction, never in the redraw/flush hot path.
private final class StaleMainRowSet {
    private(set) var rows: [UInt32] = []
    private var membership: [UInt64]
    private let rowLimit: Int

    init(rowLimit: Int) {
        self.rowLimit = rowLimit
        membership = Array(repeating: 0, count: (rowLimit + 63) / 64)
        rows.reserveCapacity(rowLimit)
    }

    func insert(_ row: Int) {
        guard row >= 0, row < rowLimit else { return }
        let word = row >> 6
        let mask = UInt64(1) << UInt64(row & 63)
        guard membership[word] & mask == 0 else { return }
        membership[word] |= mask
        rows.append(UInt32(row))
    }

    func removeAll() {
        for storedRow in rows {
            let row = Int(storedRow)
            let word = row >> 6
            membership[word] &= ~(UInt64(1) << UInt64(row & 63))
        }
        rows.removeAll(keepingCapacity: true)
    }
}

// MTLCommandBuffer rule: any command buffer created via queue.makeCommandBuffer()
// MUST be committed before being dropped. Uncommitted command buffers leak
// IOAccelerator GPU memory regions that the kernel never reclaims (observable
// as growing phys_footprint under flush bursts).
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
    private var pipelineRetryDelaySeconds: TimeInterval = 0.1
    private var pipelineRetryNotBefore: CFAbsoluteTime = 0
    private weak var viewForPipeline: MTKView?

    // 2-pass rendering pipelines for blur support
    // Background pipeline uses overwrite blending (one, zero) to avoid ghosting
    // Glyph pipeline uses standard alpha blending for correct antialiasing
    private var backgroundPipeline: MTLRenderPipelineState?
    private var glyphPipeline: MTLRenderPipelineState?
    // Single-pass replacement for the (backgroundPipeline + glyphPipeline) 2-pass.
    // Uses ps_unified_blur which reads tile memory via raster_order_group and
    // composites bg + glyph + decorations in a single fragment shader. Halves
    // fragment-shader invocations vs the 2-pass discard pattern when enabled.
    // nil → fall back to 2-pass for safety.
    private var unifiedBlurPipeline: MTLRenderPipelineState?

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
        try? FileManager.default.createDirectory(at: zonvieDir, withIntermediateDirectories: true)
        return zonvieDir.appendingPathComponent("pipeline_cache.metallib")
    }


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
        pendingSurfaceLayers = layers
        // Removing or migrating the owner also removes its surface overlay.
        // Stage this with placement so abort preserves the old complete frame.
        if !layers.contains(where: { $0.gridId == pendingCursorLayerGridId }) {
            submitLayerCursor(gridId: pendingCursorLayerGridId, ptr: nil, count: 0)
            pendingCursorLayerGridId = 1
        }
    }

    /// True when `gridId` is one of this surface's layers. The pending list is
    /// consulted too, because the layout for a newly placed grid arrives in the
    /// same bracket as that grid's first rows.
    func ownsGrid(_ gridId: Int64) -> Bool {
        if gridId == 1 { return true }
        if let pending = pendingSurfaceLayers {
            return pending.contains { $0.gridId == gridId }
        }
        return committedSurfaceLayers.contains { $0.gridId == gridId }
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
    private var pendingCursorLayerGridId: Int64 = 1
    var renderTraceFlushId: UInt64 = 0 // Core callback thread only.
    private var committedCursorLayerGridId: Int64 = 1

    /// The committed cursor's layer origin within the surface.
    private var committedCursorLayerOriginPx: simd_float2 {
        guard committedCursorLayerGridId != 1 else { return simd_float2(0, 0) }
        return committedSurfaceLayers.first { $0.gridId == committedCursorLayerGridId }?.originPx
            ?? simd_float2(0, 0)
    }

    /// Publish the cursor layer for a grid the surface draws as a layer. The
    /// vertices are in that grid's own pixel space.
    func submitLayerCursor(gridId: Int64, ptr: UnsafeRawPointer?, count: Int) {
        // Cursor clears are grid-local even though the surface has one overlay.
        guard count != 0 || pendingCursorLayerGridId == gridId else {
            ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_ignore surface=1 grid=\(gridId) owner=\(pendingCursorLayerGridId) reason=empty_nonowner")
            return
        }
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_route surface=1 grid=\(gridId) vertices=\(count)")
        pendingCursorLayerGridId = gridId
        submitVerticesPartialRaw(
            mainPtr: nil,
            mainCount: 0,
            cursorPtr: ptr,
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
            if let staged = ws.pendingScroll,
               staged.rowStart == rowStart,
               staged.rowEnd == rowEnd {
                ws.pendingScroll = SurfaceRowScroll(
                    rowStart: rowStart, rowEnd: rowEnd,
                    colStart: colStart, colEnd: colEnd,
                    rowsDelta: clampRowsDelta(staged.rowsDelta &+ rowsDelta),
                    totalRows: totalRows, totalCols: totalCols
                )
            } else {
                // Region change within one bracket: the older staged shift can
                // no longer be represented, but its row slots were already
                // remapped — dirty its rows so they redraw post-remap.
                if let staged = ws.pendingScroll, staged.rowEnd > staged.rowStart {
                    markLayerRowsDirty(
                        gridId: gridId,
                        rowStart: staged.rowStart,
                        rowCount: staged.rowEnd - staged.rowStart
                    )
                }
                ws.pendingScroll = SurfaceRowScroll(
                    rowStart: rowStart, rowEnd: rowEnd,
                    colStart: colStart, colEnd: colEnd,
                    rowsDelta: rowsDelta,
                    totalRows: totalRows, totalCols: totalCols
                )
            }
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
    private func layerDrawState(gridId: Int64) -> LayerDrawState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = layerDrawStates[gridId] { return existing }
        let created = LayerDrawState()
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
        ptr: UnsafeRawPointer?,
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
            device: device,
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
    private var pendingSurfaceLayers: [SurfaceLayer]?   // Core thread only
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
    private var committedCursorSetIndex: Int = 0 // Protected by lock
    private var isInFlush: Bool = false       // Core thread only
    // Complete row metadata is retained independently in all three sets. A
    // non-committed set only needs rows changed since it last committed; this
    // avoids O(totalRows) metadata copying for a one-row flush. Structural
    // operations and aborted partial writes use the full-copy barrier.
    private let staleMainRowsBySet: [StaleMainRowSet] = [
        StaleMainRowSet(rowLimit: metalTerminalMaxRowBuffers),
        StaleMainRowSet(rowLimit: metalTerminalMaxRowBuffers),
        StaleMainRowSet(rowLimit: metalTerminalMaxRowBuffers),
    ]
    private let flushChangedMainRows = StaleMainRowSet(rowLimit: metalTerminalMaxRowBuffers)
    private var mainRowStateNeedsFullSync = [false, false, false]
    private var flushHasStructuralMainChange = false
    // Set (core thread) when a buffer allocation fails or a mandatory row shift
    // cannot be applied: an empty/undersized/unshifted set must not become the
    // committed state. ZonvieCore's on_flush_end consumes it, cancels the
    // bracket, calls zonvie_core_abort_flush and retries when retryable.
    private(set) var flushFailed: Bool = false // Core thread only
    // ExternalGridView carries a deliberately parallel ledger and provisioning
    // pass. The pure parts are already shared free functions in
    // MetalTypes.swift; what is left is each class's own concurrency contract,
    // and merging it would put both surfaces under a single lock discipline
    // neither has — in the path that produced the scroll freeze fixed by
    // de6c402. Reviewed under the 2026-08-25 audit, finding 037.
    // Fixed-size capacity ledger. Row callbacks only raise scalar entries;
    // the retry worker provisions Swift metadata and Metal buffers after the
    // flush bracket closes and before it reacquires the core grid lock.
    private var rowCapacityRequiredRows = 0
    private var rowCapacityRequiredVertexCounts = [Int](
        repeating: 0,
        count: metalTerminalMaxRowBuffers
    )
    private var rowCapacityBracketOpen = false // Protected by lock
    private var rowCapacityProvisioning = false // Protected by lock
    private var rowCapacityHardFailure = false // Protected by lock

    /// Read and clear flushFailed. Called once per flush from on_flush_end.
    func consumeFlushFailed() -> Bool {
        let v = flushFailed
        flushFailed = false
        return v
    }

    private func closeRowCapacityBracket() {
        lock.lock()
        rowCapacityBracketOpen = false
        lock.unlock()
    }

    private func requirePreparedRowCapacity(
        row: Int,
        vertexCount: Int,
        totalRows: Int,
        rowIsPhysical: Bool = false,
        useWriteMapping: Bool = false
    ) -> Bool {
        let capacityRow: Int
        let mappingSetIndex = useWriteMapping ? writeSetIndex : flushSourceSetIndex
        if !rowIsPhysical,
           mappingSetIndex >= 0,
           mappingSetIndex < bufferSets.count {
            capacityRow = surfacePhysicalCapacityRow(
                logicalRow: row,
                logicalToSlot: bufferSets[mappingSetIndex].rowLogicalToSlot
            )
        } else {
            capacityRow = row
        }
        if surfaceRowCapacityIsPrepared(
            bufferSets: bufferSets,
            row: capacityRow,
            vertexCount: vertexCount,
            totalRows: totalRows,
            maxRowBuffers: maxRowBuffers
        ) {
            return true
        }
        guard capacityRow >= 0, capacityRow < maxRowBuffers,
              totalRows >= 0, totalRows <= maxRowBuffers,
              surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)) != nil
        else {
            // Argument validation only. Fail this flush, but do not latch
            // rowCapacityHardFailure: that flag is never cleared, so latching it
            // on a soft condition permanently stops the surface from presenting.
            // The terminal case is .overBudget below, which pairs with the
            // documented-terminal zonvie_core_fail_render_budget.
            flushFailed = true
            return false
        }
        lock.lock()
        rowCapacityRequiredRows = max(max(rowCapacityRequiredRows, totalRows), capacityRow + 1)
        rowCapacityRequiredVertexCounts[capacityRow] = max(
            rowCapacityRequiredVertexCounts[capacityRow],
            max(0, vertexCount)
        )
        let newRequiredRows = rowCapacityRequiredRows
        lock.unlock()
        ZonvieCore.appLogScrollMode(
            "[scroll_debug] row_capacity_required row=\(row) capacityRow=\(capacityRow) " +
            "vertexCount=\(vertexCount) totalRows=\(totalRows) requiredRowsNow=\(newRequiredRows)"
        )
        flushFailed = true
        return false
    }

    /// True while this surface still owes a provisioning pass, or is in the
    /// middle of one. The scheduled flush retry is that pass's only driver, so
    /// a commit elsewhere must not disarm the retry while this holds.
    /// `rowCapacityProvisioning` has to count: the provisioner zeroes the
    /// ledger before it allocates outside the lock, and a commit landing in
    /// that window would otherwise see nothing owed and cancel the very retry
    /// that is doing the work — after which an allocation failure restores the
    /// ledger with no driver left to act on it.
    var hasPendingRowCapacityWork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rowCapacityRequiredRows > 0 || rowCapacityProvisioning
    }

    /// Called on the retry queue before it acquires core grid_mu. Flush
    /// admission is gated while the plan is allocated and published, so row
    /// callbacks never race these metadata mutations.
    func provisionPendingRowCapacity() -> SurfaceRowProvisionStatus {
        lock.lock()
        if rowCapacityHardFailure {
            lock.unlock()
            return .hardFailure
        }
        // Nothing owed: answer ready regardless of what this surface is
        // currently doing. Asked before the busy check because a surface
        // presenting at refresh rate almost always has a frame in flight, and
        // the caller folds any one surface's .retry into an app-wide verdict —
        // an idle ledger would otherwise keep the whole retry re-arming.
        guard rowCapacityRequiredRows > 0 else {
            lock.unlock()
            return .ready
        }
        if rowCapacityBracketOpen || rowCapacityProvisioning ||
            gpuInFlightCount.contains(where: { $0 != 0 }) {
            let bracketOpen = rowCapacityBracketOpen
            let provisioning = rowCapacityProvisioning
            let gpuInFlight = gpuInFlightCount
            lock.unlock()
            ZonvieCore.appLogScrollMode(
                "[scroll_debug] row_capacity_retry_blocked bracketOpen=\(bracketOpen) " +
                "provisioning=\(provisioning) gpuInFlight=\(gpuInFlight)"
            )
            return .retry
        }
        rowCapacityProvisioning = true
        let requiredRows = rowCapacityRequiredRows
        let requiredVertexCounts = Array(rowCapacityRequiredVertexCounts[0..<requiredRows])
        for row in 0..<requiredRows {
            rowCapacityRequiredVertexCounts[row] = 0
        }
        rowCapacityRequiredRows = 0
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
            rowCapacityProvisioning = false
            lock.unlock()
        }
        switch planResult {
        case .overBudget:
            rowCapacityHardFailure = true
            return .hardFailure
        case .allocationFailed(let partialPlan):
            let metrics = partialPlan.metrics
            ZonvieCore.appLog(
                "[Renderer] row provisioning allocation failed attempt=\(metrics.allocationAttemptCount) " +
                "created=\(metrics.createdBufferCount) createdBytes=\(metrics.createdBufferBytes) " +
                "planned=\(metrics.plannedReplacementCount) plannedBytes=\(metrics.plannedReplacementBytes) " +
                "live=\(metrics.liveBufferCount) liveBytes=\(metrics.liveBufferBytes)"
            )
            // Private pool publication is independent of committed rowState.
            // Retaining the successful prefix makes every retry monotonic
            // without exposing a partially rendered frame.
            applySurfaceRowProvisionPlan(
                partialPlan,
                to: bufferSets,
                maxRowBuffers: maxRowBuffers
            )
            rowCapacityRequiredRows = max(rowCapacityRequiredRows, requiredRows)
            for row in 0..<requiredRows {
                rowCapacityRequiredVertexCounts[row] = max(
                    rowCapacityRequiredVertexCounts[row],
                    requiredVertexCounts[row]
                )
            }
            return .retry
        case .ready(let plan):
            if ZonvieCore.appLogEnabled && plan.metrics.createdBufferCount > 0 {
                ZonvieCore.appLogPerf(
                    "[perf] row_provision created=\(plan.metrics.createdBufferCount) " +
                    "createdBytes=\(plan.metrics.createdBufferBytes) attempts=\(plan.metrics.allocationAttemptCount) " +
                    "peakBytes=\(plan.metrics.liveBufferBytes + plan.metrics.plannedReplacementBytes)"
                )
            }
            applySurfaceRowProvisionPlan(plan, to: bufferSets, maxRowBuffers: maxRowBuffers)
        }
        return rowCapacityRequiredRows == 0 ? .ready : .retry
    }
    // Per-flush row submit accumulators. Reset in beginFlush, summed in
    // submitVerticesRowRaw, dumped in commitFlush as [perf] row_submit. Surfaces
    // the Swift-side cost inside Zig-measured row_cb_us (memcpy + slot remap).
    private var perfRowSubmitNs: Int64 = 0    // Core thread only
    private var perfRowSubmitCalls: Int = 0   // Core thread only
    private var perfRowSubmitVerts: Int = 0   // Core thread only

    // Per-pass GPU timing via MTLCounterSampleBuffer (stage-boundary timestamps).
    // One sample buffer is reused across frames; safe because inflightSemaphore
    // bounds in-flight frames to 1, so the previous frame's completion handler
    // resolves the buffer before the next draw assigns slots.
    private struct GpuPerfSlot { let label: String; let startIdx: Int; let endIdx: Int }
    // Full 4-stage sampling for one pass (vertex start/end + fragment start/end).
    // Used to investigate why the copy pass measures ~2.9ms even though it's a
    // single 6-vert blit (~0.7ms theoretical bandwidth limit) — the fragment-
    // only number doesn't show vertex stage cost or the gap waiting for the
    // previous pass's tile store.
    private struct GpuPerfSlotFull {
        let label: String
        let startVIdx: Int
        let endVIdx: Int
        let startFIdx: Int
        let endFIdx: Int
    }
    private var gpuPerfSampleBuffer: MTLCounterSampleBuffer?
    private var gpuPerfSamplingEnabled: Bool = false
    private var gpuTimestampPeriodNs: Double = 1.0
    private var gpuPerfSlots: [GpuPerfSlot] = []  // Render thread only; reset per draw
    private var gpuPerfFullSlots: [GpuPerfSlotFull] = []  // ditto, full-stage sampling
    private var gpuPerfNextIdx: Int = 0  // shared sample-buffer cursor; reset per draw

    // Per-pass overdraw measurement via MTLCommonCounterSetStatistic.
    // Captures fragmentInvocations at pass start/end; ratio against the actual
    // visible pixel area (drawable_w × dirty_h_px) is true overdraw. Confirms
    // whether the 2-pass blur path actually doubles fragment work, which our
    // hypothesis says is the dominant ~5ms in main pass.
    private var gpuStatsSampleBuffer: MTLCounterSampleBuffer?
    private var gpuStatsSamplingEnabled: Bool = false
    private var gpuStatsSlots: [GpuPerfSlot] = []  // Render thread only; reset per draw

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
    private var lastDrawnDrawableSize: CGSize = .zero // Render thread only
    // Whether the most-recently-rendered frame had an active scroll offset,
    // which extends smoothScrolling for one frame past the offset reaching zero
    // (as ExternalGridView's wasScrollOffsetActiveInLastPresentedFrame does).
    // Without it a frame that both clears the offset and carries a grid_scroll
    // blits pixels already rendered with a shader offset: a 1-row jitter.
    private var lastDrawnHadActiveScrollOffset: Bool = false // Render thread only
    private var gpuInFlightCount: [Int] = [0, 0, 0]  // Protected by lock
    private var rowStorageRetirement = SurfaceRowStorageRetirementState() // Protected by lock
    private var cursorGpuInFlightCount: [Int] = [0, 0, 0] // Protected by lock
    private var defaultBgRGB: UInt32 = 0               // Protected by lock

    /// Complete one protected GPU read and immediately service any contraction
    /// that had to skip this set while it was in flight. Caller holds `lock`.
    private func completeSurfaceGpuReadLocked(_ setIndex: Int) {
        guard setIndex >= 0,
              setIndex < gpuInFlightCount.count,
              gpuInFlightCount[setIndex] > 0
        else { return }
        gpuInFlightCount[setIndex] -= 1
        serviceSurfaceRowStorageRetirement(
            bufferSets: bufferSets,
            gpuInFlightCount: gpuInFlightCount,
            committedSetIndex: committedSetIndex,
            layoutContracted: false,
            state: &rowStorageRetirement,
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
    private var committedDrawableW: UInt32 = 0 // Protected by lock
    private var committedDrawableH: UInt32 = 0 // Protected by lock
    // Layout associated with the last committed MAIN state. Cursor-only
    // commits also refresh committedDrawable*, so they cannot be used to
    // decide whether sparse row metadata crossed a layout transition.
    private var mainRowStateDrawableW: UInt32 = 0 // Core thread only
    private var mainRowStateDrawableH: UInt32 = 0 // Core thread only

    private var committedAtlasTexture: MTLTexture?  // Protected by lock
    private var linespacePx: Int32 = 0

    private var backingScale: CGFloat = 1.0

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
    var cellWidthPx: Float { atlas.fontMetricsSnapshot().width }

    /// Cell height in drawable pixel coordinates.
    // var cellHeightPx: Float { atlas.cellHeightPx }
    // atlas.fontMetricsSnapshot() reads all four font metrics together
    // under the atlas's own lock (setFont()/setBackingScale() write them
    // there from the core/RPC thread); linespacePx is a separate field
    // written under `lock` by setLineSpace(), read under that same lock
    // here. Combining the two snapshots still can't mix a fresh atlas
    // height with a stale linespace value within either field.
    var cellHeightPx: Float {
        lock.lock()
        let ls = linespacePx
        lock.unlock()
        // 'linespace' may be negative (Neovim allows it to tighten rows under
        // a font that reserves too much room between lines), so the sum has to
        // stay positive: the grid divides the drawable by this to get its row
        // count, and rows also cannot be measured in zero pixels.
        return max(1, atlas.fontMetricsSnapshot().height + Float(ls))
    }


    var currentFontName: String { atlas.currentFontName }

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

    // Phase 2: Core-managed atlas pass-through

    func rasterizeGlyphOnly(scalar: UInt32, styleFlags: UInt32, corePtr: OpaquePointer?, outBitmap: UnsafeMutablePointer<zonvie_glyph_bitmap>) -> Bool {
        return atlas.rasterizeOnly(scalar: scalar, styleFlags: styleFlags, corePtr: corePtr, outBitmap: outBitmap)
    }

    /// Classifies an upload that did not actually happen so the C callback can
    /// abort every failure, but rebuild only for terminal atlas damage. See
    /// GlyphAtlas.uploadRegion's doc comment for the cache-publication contract.
    @discardableResult
    func uploadAtlasRegion(destX: UInt32, destY: UInt32, width: UInt32, height: UInt32, bitmap: UnsafePointer<zonvie_glyph_bitmap>) -> GlyphAtlas.UploadResult {
        atlas.uploadRegion(destX: Int(destX), destY: Int(destY), width: Int(width), height: Int(height), bitmap: bitmap)
    }

    @discardableResult
    func recreateAtlasTexture(width: UInt32, height: UInt32) -> Bool {
        let created = atlas.recreateTexture(width: Int(width), height: Int(height))
        if !created && isInFlush {
            // on_atlas_create has a void C ABI. Latch the failure in the
            // frontend transaction as well as aborting from the callback so
            // on_flush_end can never publish vertices whose UVs belong to the
            // texture generation that failed to allocate.
            flushFailed = true
        }
        return created
    }

    // (vertexBuffer/cursorVertexBuffer moved into BufferSet for triple buffering)

    /// Cursor blink state (true = visible, false = hidden during blink)
    private var cursorBlinkStateStorage: Bool = true
    var cursorBlinkState: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cursorBlinkStateStorage
        }
        set {
            lock.lock()
            cursorBlinkStateStorage = newValue
            lock.unlock()
        }
    }
    private var lastRenderedBlinkState: Bool = true

    // --- Scroll offset for smooth scrolling ---
    // Stored as value-type array under lock; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race during smooth scrolling.
    private var scrollOffsetData: [ScrollOffset] = []
    private var hasActiveScrollOffset: Bool = false  // true when smooth scrolling is active
    // Exact union of fixed, non-following float rects, represented as disjoint
    // horizontal intervals inside disjoint vertical bands. The fragment shader
    // binary-searches both levels instead of scanning every float per pixel.
    private var fixedFloatBandData: [FixedFloatBand] = []
    private var fixedFloatIntervalData: [FixedFloatInterval] = []
    private var fixedFloatRectInputData: [FixedFloatRect] = []
    private var fixedFloatMaskOverflowed = false
    private var fixedFloatYEdgesScratch: [Float] = []
    private var fixedFloatXEdgesScratch: [Float] = []
    private var fixedFloatCoveringScratch: [FixedFloatRect] = []
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

        if rects.count > Self.maxFixedFloatRects {
            if !fixedFloatMaskOverflowed {
                fixedFloatRectInputData.removeAll(keepingCapacity: true)
                fixedFloatBandData.removeAll(keepingCapacity: true)
                fixedFloatIntervalData.removeAll(keepingCapacity: true)
                fixedFloatYEdgesScratch.removeAll(keepingCapacity: true)
                fixedFloatMaskOverflowed = true
            }
            return false
        }
        if !fixedFloatMaskOverflowed && rects == fixedFloatRectInputData {
            return true
        }
        fixedFloatMaskOverflowed = false
        fixedFloatRectInputData.removeAll(keepingCapacity: true)
        fixedFloatRectInputData.append(contentsOf: rects)

        buildSurfaceFixedFloatMask(
            rects: rects,
            bands: &fixedFloatBandData,
            intervals: &fixedFloatIntervalData,
            yEdgesScratch: &fixedFloatYEdgesScratch,
            xEdgesScratch: &fixedFloatXEdgesScratch,
            coveringScratch: &fixedFloatCoveringScratch
        )
        return true
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
    // Render-thread scratch. Ownership is swapped into draw() for the frame
    // and returned by defer, so appending/scroll expansion reuses capacity
    // without a live property alias that would trigger Array COW detaches.
    private var dirtyRowsScratch: [Int] = []
    /// Per-frame snapshots taken under `lock`: the committed layer list and,
    /// index-aligned, each layer's buffer sets. Reused across frames.
    private var layerSnapshot: [SurfaceLayer] = []
    private var layerSetsSnapshot: [[SurfaceBufferSet]] = []
    /// Index-aligned with `layerSnapshot` as well: the draw state of the grid
    /// each layer places, nil for the root grid and for a grid that has not
    /// submitted anything yet. Reused across frames.
    private var layerStateSnapshot: [LayerDrawState?] = []
    /// Per-grid dirty/scroll bookkeeping for the surface's non-root layers.
    /// Protected by `lock`; an entry is created when a grid first submits a row
    /// or a scroll and released when the grid is destroyed.
    private var layerDrawStates: [Int64: LayerDrawState] = [:]
    /// Rows each layer's committed placement has travelled upwards since the
    /// surface began, in the same units and direction as on_grid_scroll's
    /// rowsDelta. Only commitFlush writes it; copyPlacementRowsUp reads it.
    /// Protected by `lock`.
    private var layerPlacementRowsUp: [Int64: Int] = [:]

    /// Hand the float ledger the placement travel it needs, into storage the
    /// caller owns, so the per-frame read costs one lock and no allocation.
    func copyPlacementRowsUp(into out: inout [Int64: Int]) {
        lock.lock()
        defer { lock.unlock() }
        out.removeAll(keepingCapacity: true)
        for (gridId, rows) in layerPlacementRowsUp { out[gridId] = rows }
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
    private var hasPresentedOnce: Bool = false

    /// Previous on-glass presentation time (MTLDrawable.presentedTime, seconds).
    /// Written from presented handlers (Metal internal thread) under `lock`;
    /// only touched when logging is enabled, to measure true present cadence.
    private var lastPresentedTime: CFTimeInterval = 0

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
    /// Attenuates extracted glow by a layer's background coverage, so a glyph
    /// behind an opaque layer does not bloom through it.
    private(set) var glowOccludePipeline: MTLRenderPipelineState?
    private(set) var kawaseDownPipeline: MTLRenderPipelineState?
    private(set) var kawaseUpPipeline: MTLRenderPipelineState?
    private(set) var glowCompositePipeline: MTLRenderPipelineState?
    let glowTextures = SurfaceGlowTextures()
    private(set) var bilinearSampler: MTLSamplerState?

    // --- User-supplied custom post-process shaders ---
    // Loaded once from config paths during bloom-pipeline construction.
    // Empty array when `[shaders].enabled = false` or no paths are listed.
    private(set) var customShaderPipelines: [CustomShaderPipeline] = []
    /// Opaque variant of the custom shader chain for DECORATED surfaces
    /// (ext-cmdline / popupmenu / messages). Their backTex has alpha=0 regions —
    /// padding, empty parts of the input line — where `preserve_alpha` would
    /// make the shader inherit alpha 0 and vanish (the hazard f0c81c07b95
    /// documented), so these always compile with it OFF while the main window
    /// keeps `config.preserveAlpha`. When that is false the two sets are
    /// identical and this just aliases `customShaderPipelines`.
    private(set) var customShaderPipelinesDecorated: [CustomShaderPipeline] = []
    /// Where the custom shader chain inserts relative to bloom. Mirrored from
    /// `ZonvieConfig.shared.shaders.postProcess` at build time so the draw
    /// path does not need to re-read config each frame.
    private(set) var customShaderPostProcess: ZonvieConfig.ShaderPostProcess = .afterBloom
    /// True when any loaded custom shader references a time-varying
    /// Shadertoy uniform. Used by `MetalTerminalView` to keep the vsync
    /// draw loop active instead of falling back to flush-driven rendering.
    private(set) var anyCustomShaderNeedsAnimation: Bool = false

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
    public final class ShaderViewTimingState {
        public var frameIndex: Int32 = 0
        public var startTimeSec: CFTimeInterval = 0
        public var lastTimeSec: CFTimeInterval = 0
        public var emaFrameRate: Float = 60.0
        public init() {}
    }
    /// Main window's timing state (used by MetalTerminalView's draw).
    /// External views own their own ShaderViewTimingState instance and
    /// pass it to makeCustomShaderUniforms.
    public let mainShaderTiming = ShaderViewTimingState()
    // Shadertoy iDate cache: Calendar(identifier:) construction plus
    // dateComponents() ran every frame (up to 60Hz while an animated custom
    // shader is active) purely to fill a uniform that effects use at
    // wall-clock, not frame, granularity. Reuse the Calendar and recompute
    // the components at most once per second.
    private let shaderDateCalendar = Calendar(identifier: .gregorian)
    private var shaderDateCacheSecond: Int = -1
    private var shaderDateCache: (year: Float, month: Float, day: Float, secsInDay: Float) = (0, 0, 0, 0)
    /// Ping-pong render targets for multi-pass shader chains. Allocated
    /// only when pipelines.count > 1. Size matches backBufferSize.
    private var customShaderPong: [MTLTexture?] = [nil, nil]
    private var customShaderPongSize: CGSize = .zero
    // Ghostty 1.1+ cursor uniform state (see `zonvie_shader_uniforms`).
    //
    // Held in SCREEN space — the smooth-scroll displacement already folded in
    // — because that is what a cursor shader draws against and what "the
    // cursor moved" has to mean. The rect the core measures is in vertex
    // space, which shifts by a whole row on every scroll step while the
    // displacement cancels it and the cursor stays put on the glass. Rotating
    // on that would restart the trail every step, so it never plays out.
    private var shaderCursorCurrent: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var shaderCursorPrevious: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var shaderCursorCurrentColor: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var shaderCursorPreviousColor: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var shaderCursorChangeTime: Float = 0
    /// Last cursor rect handed to a shader, so the log fires on change only.
    private var lastLoggedShaderCursor: (Float, Float, Float, Float) = (0, 0, 0, 0)
    /// The rect as the core measured it, and the grid it belongs to. Turned
    /// into the screen-space state above by `evaluateCursorShaderChange`, once
    /// the frame's displacement for that grid is known. Written under `lock`.
    private var shaderCursorRawRect: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var shaderCursorRawColor: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var shaderCursorGridId: Int64 = 0
    /// Displacement of the cursor's grid as of the last offset rebuild. Cached
    /// because `updateScrollOffsets` is skipped entirely on idle frames, while
    /// the cursor still moves — the evaluation has to run every frame or the
    /// shader keeps whatever endpoints the last scrolled frame left it.
    private var shaderCursorScrollOffsetPx: Float = 0
    /// Sub-pixel movement is not a cursor move; it is the ease sliding the
    /// cursor along. Rotating on it would restart the trail every frame.
    private static let shaderCursorMoveEpsilonPx: Float = 0.5
    /// Cursor state measured during a flush, held until that flush commits.
    ///
    /// The rect describes the cursor vertices of the flush that measured it,
    /// and those only reach the screen at commit. Publishing at submit put the
    /// NEXT flush's cursor position into the uniforms while the screen still
    /// showed the previous one — a row apart mid-scroll, which is a cursor
    /// shader firing off the cursor for that frame.
    private var stagedShaderCursor: (rect: (Float, Float, Float, Float), color: (Float, Float, Float, Float), gridId: Int64)?

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
    private func ensureCustomShaderPong(size: CGSize, pixelFormat: MTLPixelFormat) {
        if customShaderPong[0] != nil,
           customShaderPong[1] != nil,
           customShaderPongSize == size {
            return
        }
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        customShaderPong[0] = device.makeTexture(descriptor: desc)
        customShaderPong[1] = device.makeTexture(descriptor: desc)
        customShaderPongSize = size
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
        self.atlas = builtAtlas
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

        setupGpuPerfSampling()
    }

    // Probe device support for stage-boundary timestamp counters and allocate
    // a reusable sample buffer. On unsupported devices the gate stays false and
    // the per-pass GPU log is silently skipped (gpu_execution still emits).
    private func setupGpuPerfSampling() {
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
            gpuPerfSampleBuffer = try device.makeCounterSampleBuffer(descriptor: desc)
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
            gpuTimestampPeriodNs = cpuDelta / gpuDelta
        }
        gpuPerfSamplingEnabled = true
        ZonvieCore.appLogPerf("[perf] gpu_passes: enabled (tick_period_ns=\(String(format: "%.4f", gpuTimestampPeriodNs)))")

        // ── Statistic counter set: fragment invocations for overdraw measurement.
        // Independent enable gate so a partial-support device can still benefit
        // from gpu_passes timing even if statistic isn't available.
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
            gpuStatsSampleBuffer = try device.makeCounterSampleBuffer(descriptor: stDesc)
            gpuStatsSamplingEnabled = true
            ZonvieCore.appLogPerf("[perf] gpu_overdraw: enabled")
        } catch {
            ZonvieCore.appLogPerf("[perf] gpu_overdraw: makeCounterSampleBuffer(statistic) failed: \(error)")
        }
    }

    // Attach fragment-stage timestamp samples to a render pass descriptor so the
    // GPU records start-of-fragment / end-of-fragment timestamps. The duration
    // (end - start) is scaled by gpuTimestampPeriodNs in the completion handler.
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
    private func attachGpuPerfSamples(to rpd: MTLRenderPassDescriptor, label: String) {
        guard gpuPerfSamplingEnabled, ZonvieCore.appLogEnabled,
              let buf = gpuPerfSampleBuffer
        else { return }
        let startIdx = gpuPerfNextIdx
        let endIdx = startIdx + 1
        guard endIdx < buf.sampleCount else { return }
        gpuPerfNextIdx += 2
        let attach = rpd.sampleBufferAttachments[0]!
        attach.sampleBuffer = buf
        attach.startOfVertexSampleIndex = MTLCounterDontSample
        attach.endOfVertexSampleIndex = MTLCounterDontSample
        attach.startOfFragmentSampleIndex = startIdx
        attach.endOfFragmentSampleIndex = endIdx
        gpuPerfSlots.append(GpuPerfSlot(label: label, startIdx: startIdx, endIdx: endIdx))
    }

    // Same as attachGpuPerfSamples but also samples the vertex-stage boundary
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
    private func attachGpuPerfSamplesFull(to rpd: MTLRenderPassDescriptor, label: String) {
        guard gpuPerfSamplingEnabled, ZonvieCore.appLogEnabled,
              let buf = gpuPerfSampleBuffer
        else { return }
        let baseIdx = gpuPerfNextIdx
        let endFIdx = baseIdx + 3
        guard endFIdx < buf.sampleCount else { return }
        gpuPerfNextIdx += 4
        let attach = rpd.sampleBufferAttachments[0]!
        attach.sampleBuffer = buf
        attach.startOfVertexSampleIndex = baseIdx
        attach.endOfVertexSampleIndex = baseIdx + 1
        attach.startOfFragmentSampleIndex = baseIdx + 2
        attach.endOfFragmentSampleIndex = baseIdx + 3
        gpuPerfFullSlots.append(GpuPerfSlotFull(
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
    // Resolved in the completion handler as fragmentInvocations(end - start);
    // overdraw ratio is computed against actual visible pixel area.
    private func attachGpuStatsSamples(to rpd: MTLRenderPassDescriptor, label: String) {
        guard gpuStatsSamplingEnabled, ZonvieCore.appLogEnabled,
              let buf = gpuStatsSampleBuffer
        else { return }
        let startIdx = gpuStatsSlots.count * 2
        let endIdx = startIdx + 1
        guard endIdx < buf.sampleCount else { return }
        let attach = rpd.sampleBufferAttachments[1]!
        attach.sampleBuffer = buf
        attach.startOfVertexSampleIndex = MTLCounterDontSample
        attach.endOfVertexSampleIndex = MTLCounterDontSample
        attach.startOfFragmentSampleIndex = startIdx
        attach.endOfFragmentSampleIndex = endIdx
        gpuStatsSlots.append(GpuPerfSlot(label: label, startIdx: startIdx, endIdx: endIdx))
    }

    // (buildScrollOffsetBuffers removed: scroll data now passed via setVertexBytes)

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
        lock.lock()
        if rowCapacityProvisioning || rowCapacityRequiredRows > 0 || rowCapacityHardFailure {
            lock.unlock()
            ZonvieCore.appLog("[Renderer] beginFlush: waiting for row capacity provisioning")
            return .dropped
        }
        rowCapacityBracketOpen = true
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
        // Same reason: a cursor measured by a bracket that never committed
        // describes vertices that never reached the screen.
        lock.lock()
        stagedShaderCursor = nil
        lock.unlock()
        flushChangedMainRows.removeAll()
        flushHasStructuralMainChange = false
        layerGridsPreparedThisFlush = false
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

        // Prepare atlas back texture.
        // Phase 1: handle non-GPU cases (rebuild, CPU sync, no-op).
        // Phase 2: only create a Metal command buffer if GPU blit is needed.
        // This avoids leaking IOAccelerator GPU memory regions from uncommitted
        // command buffers (observed: ~70 leaked regions/sec without this fix).
        var needsCoreInvalidation = false
        let tAtlasPrepareStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let prepResult = atlas.prepareBackTexture()
        if perfEnabled {
            atlasPrepareUs = (CFAbsoluteTimeGetCurrent() - tAtlasPrepareStart) * 1_000_000
        }
        needsCoreInvalidation = prepResult.needsCoreInvalidation
        atlasNeedsCoreInvalidation = prepResult.needsCoreInvalidation
        atlasDidCpuSync = prepResult.didCpuSync
        atlasSyncedWasRecreate = prepResult.syncedWasRecreate
        if prepResult.shouldAbort {
            isInFlush = false
            closeRowCapacityBracket()
            ZonvieCore.appLog("[WARNING] beginFlush: atlas prepare failed, dropping flush")
            return .dropped
        }
        if prepResult.needsGpuBlit {
            // Commit the blit without waiting on the renderer's own in-flight
            // work: waiting blocked the core thread (grid_mu held) on a
            // full-texture round-trip per flush under atlas-full churn. A later
            // back-texture consumer polls the command and retries if it is still
            // in flight; no redraw callback may wait for it while grid_mu is
            // held.
            //
            // beginAtlasWrite()/endAtlasWrite() is a separate, much cheaper gate
            // against ExternalGridView's queue reading the texture this blit
            // overwrites, and returns immediately when no external read is
            // outstanding. Held across cmd.commit() (as on every exit path
            // below) so no new external read is admitted before submission.
            guard atlas.beginAtlasWrite() else {
                // Fail-closed (see beginAtlasWrite's doc comment): drop
                // this flush's atlas blit rather than mutate a texture an
                // external read hasn't finished with. atlas_reset/back-sync
                // state is untouched, so the next flush attempt retries it.
                atlas.endAtlasWrite()
                isInFlush = false
                closeRowCapacityBracket()
                ZonvieCore.appLog("[WARNING] beginFlush: atlas write blocked by in-flight external reads, dropping flush")
                return .dropped
            }
            if let cmd = queue.makeCommandBuffer() {
                let blitEncoded = atlas.encodeBackTextureBlit(commandBuffer: cmd)
                guard blitEncoded else {
                    // cmd was already created (driver-side resources reserved
                    // at creation, per the IOAccelerator leak note in
                    // CLAUDE.md); nothing was encoded into it, but it must
                    // still be committed — an uncommitted MTLCommandBuffer
                    // left to ARC deallocation does not reliably release
                    // those resources, and this path can repeat on every
                    // flush attempt while the driver stays under pressure.
                    cmd.commit()
                    atlas.endAtlasWrite()
                    isInFlush = false
                    closeRowCapacityBracket()
                    ZonvieCore.appLog("[WARNING] beginFlush: atlas blit encode failed, dropping flush")
                    return .dropped
                }
                // Signal on this SAME command buffer, before commit, so the
                // event only reaches this generation once the GPU has
                // actually finished the blit — endAtlasWrite() below reopens
                // the CPU-side admission gate immediately (no waiting), but
                // readers' beginAtlasExternalRead() wait-encode still orders
                // their GPU work strictly after this blit via the event, independent of
                // when endAtlasWrite() runs.
                let blitGen = atlas.encodeBlitCompletionSignal(into: cmd)
                // If the GPU stops executing this buffer before reaching the
                // signal command above (device loss, driver error), the event
                // never reaches blitGen and any reader already waiting on it
                // would hang forever — see recoverFailedBlit's doc comment.
                let atlasForBlitCompletion = atlas
                cmd.addCompletedHandler { completedCmd in
                    if completedCmd.status != .completed {
                        atlasForBlitCompletion.recoverFailedBlit(generation: blitGen)
                    }
                }
                let tAtlasCommitStart = perfEnabled ? CFAbsoluteTimeGetCurrent() : 0
                cmd.commit()
                atlas.endAtlasWrite()
                if perfEnabled {
                    atlasCommitUs = (CFAbsoluteTimeGetCurrent() - tAtlasCommitStart) * 1_000_000
                }
                atlas.setPendingBackBlit(cmd)
                atlasDidBlit = true
            } else {
                atlas.endAtlasWrite()
                atlas.cancelPendingBackTextureBlit()
                isInFlush = false
                closeRowCapacityBracket()
                ZonvieCore.appLog("[WARNING] beginFlush: commandBuffer creation failed for atlas blit, dropping flush")
                return .dropped
            }
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
        let staleRows = staleMainRowsBySet[picked].rows
        var syncMode = "sparse"
        var syncedRows = staleRows.count
        if mainRowStateNeedsFullSync[picked] {
            copySurfaceBufferSetRowState(from: src, to: dst)
            syncMode = "full_barrier"
            syncedRows = src.rowState.buffers.count
        } else if !copySurfaceBufferSetRows(
            from: src,
            to: dst,
            logicalRows: staleRows,
            maxRowBuffers: maxRowBuffers
        ) {
            // A missed structural transition must never be approximated by
            // row patches: mappings are frame state, not per-row content.
            copySurfaceBufferSetRowState(from: src, to: dst)
            syncMode = "full_mapping_fallback"
            syncedRows = src.rowState.buffers.count
        }

        copySurfaceMainVertexState(from: src, to: dst)
        dst.pendingScroll = nil
        mainWritePrepared = true
        // The write set is two rotations old for every grid, so carry each
        // layer's rows forward: a flush that rewrites only the root must not
        // publish a set whose layers are stale or empty.
        prepareLayerGridsForWrite()

        if ZonvieCore.appLogEnabled {
            let elapsedUs = (CFAbsoluteTimeGetCurrent() - started) * 1_000_000
            ZonvieCore.appLogPerf("[perf] lazy_main_prepare src=\(flushSourceSetIndex) dst=\(picked) mode=\(syncMode) syncedRows=\(syncedRows) totalRows=\(src.rowState.buffers.count) us=\(String(format: "%.1f", elapsedUs))")
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
    func abortFlush() {
        _ = atlas.endFlushUploadTransaction()
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
        pendingCursorLayerGridId = committedCursorLayerGridId
        lock.unlock()
        flushHadLayerWork = false
        mainWritePrepared = false
        cursorWritePrepared = false
        isInFlush = false
        closeRowCapacityBracket()
    }

    /// Called from on_flush_end callback (core thread, grid_mu held).
    /// Atomically makes the write set the new committed set for draw().
    /// drawableW/drawableH are the core's layout at flush time, read via
    /// zonvie_core_get_layout while grid_mu is still held — this guarantees
    /// the values match the NDC coordinates in the committed vertices.
    @discardableResult
    func commitFlush(drawableW: UInt32, drawableH: UInt32) -> Bool {
        guard isInFlush else { return false }  // Flush was dropped or aborted
        FrameTracer.trace(.commitFlush)

        // Commit staged CPU pixels while holding reader admission only across
        // the actual texture replace. If readers or a prior blit are active,
        // preserve staging and retry the frame without publishing its UVs.
        guard atlas.endFlushUploadTransaction() else {
            if mainWritePrepared {
                mainRowStateNeedsFullSync[writeSetIndex] = true
                staleMainRowsBySet[writeSetIndex].removeAll()
            }
            flushChangedMainRows.removeAll()
            flushHasStructuralMainChange = false
            mainWritePrepared = false
            cursorWritePrepared = false
            isInFlush = false
            closeRowCapacityBracket()
            ZonvieCore.appLog("[MetalTerminalRenderer] commitFlush deferred: atlas upload writer unavailable")
            return false
        }

        // Atomically commit atlas (swap if modified) and snapshot front texture.
        // An in-flight back-sync is polled, never waited on under grid_mu.
        let atlasCommit = atlas.commitAndSnapshotFrontTexture()
        guard atlasCommit.committed else {
            if mainWritePrepared {
                mainRowStateNeedsFullSync[writeSetIndex] = true
                staleMainRowsBySet[writeSetIndex].removeAll()
            }
            flushChangedMainRows.removeAll()
            flushHasStructuralMainChange = false
            mainWritePrepared = false
            cursorWritePrepared = false
            isInFlush = false
            closeRowCapacityBracket()
            ZonvieCore.appLog("[MetalTerminalRenderer] commitFlush deferred: atlas back-sync still pending or failed")
            return false
        }

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
        // Also taken before `lock`: the accessor locks to read linespacePx, so
        // reading it inside the region below would deadlock on this thread.
        let ledgerCellHeightPx = cellHeightPx
        lock.lock()
        let mainLayoutChanged = didMainWrite
            && (mainRowStateDrawableW != drawableW || mainRowStateDrawableH != drawableH)
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
            for layer in staged where layer.gridId != 1 {
                let previous = committedSurfaceLayers.first { $0.gridId == layer.gridId }
                // How far this layer's committed placement has travelled, in
                // rows, counted upwards to match on_grid_scroll's rowsDelta.
                // The float ledger pairs the two: a float must not be handed
                // the compensation for a scroll step its own placement has not
                // performed yet. Accumulated here because this is the only
                // point a placement change is a discrete, known event.
                if let previous, ledgerCellHeightPx > 0 {
                    let rowsUp = Int(((previous.originPx.y - layer.originPx.y) / ledgerCellHeightPx).rounded())
                    if rowsUp != 0 {
                        layerPlacementRowsUp[layer.gridId, default: 0] += rowsUp
                    }
                }
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
            // A destroyed grid's travel describes a layer that no longer
            // exists, and its id is reused by the next float a scroll creates.
            if layerPlacementRowsUp.count > staged.count {
                layerPlacementRowsUp = layerPlacementRowsUp.filter { entry in
                    staged.contains { $0.gridId == entry.key }
                }
            }
        }
        if didCursorWrite {
            committedCursorLayerGridId = pendingCursorLayerGridId
        }
        committedDrawableW = drawableW
        committedDrawableH = drawableH
        committedAtlasTexture = atlasCommit.texture  // same lock as vertex state
        // Publish this bracket's smooth-scroll retention together with the
        // vertices it belongs to: a retained row shown against pre-scroll
        // content would draw the same line twice.
        if retention.commit() {
            smoothScrollSeeds.append(contentsOf: stagedSmoothScrollSeeds)
            stagedSmoothScrollSeeds.removeAll(keepingCapacity: true)
        }
        // These steps reached the screen, so there is nothing left to replay.
        pendingRetentionReplay.removeAll(keepingCapacity: true)
        publishCursorShaderStateLocked()
        commitRevision &+= 1
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
                if let existing = state.pendingScrollAccum,
                   existing.rowStart == ps.rowStart,
                   existing.rowEnd == ps.rowEnd {
                    state.pendingScrollAccum = SurfaceRowScroll(
                        rowStart: ps.rowStart,
                        rowEnd: ps.rowEnd,
                        colStart: ps.colStart,
                        colEnd: ps.colEnd,
                        // &+ mirrors the core's own +%= idiom; the clamp keeps
                        // the result away from Int.min, which the abs() calls
                        // downstream trap on. The bound is far above any real
                        // row count.
                        rowsDelta: clampRowsDelta(existing.rowsDelta &+ ps.rowsDelta),
                        totalRows: ps.totalRows,
                        totalCols: ps.totalCols
                    )
                } else {
                    // Region mismatch: the old accumulator's blit is dropped, but
                    // its row slots were already remapped, so the committed
                    // vertices are post-scroll. Dirty the dropped region rather
                    // than leave pre-scroll pixels on the rows it did not vacate.
                    if let existing = state.pendingScrollAccum,
                       existing.rowEnd > existing.rowStart {
                        state.pendingDirtyRows.insert(integersIn: existing.rowStart..<existing.rowEnd)
                    }
                    state.pendingScrollAccum = ps
                }
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
            staleMainRowsBySet[ws].removeAll()
            mainRowStateNeedsFullSync[ws] = false
            if flushHasStructuralMainChange || mainLayoutChanged {
                for i in bufferSets.indices where i != ws {
                    staleMainRowsBySet[i].removeAll()
                    mainRowStateNeedsFullSync[i] = true
                }
            } else {
                for storedRow in flushChangedMainRows.rows {
                    let row = Int(storedRow)
                    for i in bufferSets.indices
                    where i != ws && !mainRowStateNeedsFullSync[i] {
                        staleMainRowsBySet[i].insert(row)
                    }
                }
            }
            mainRowStateDrawableW = drawableW
            mainRowStateDrawableH = drawableH
        }
        flushChangedMainRows.removeAll()
        flushHasStructuralMainChange = false
        mainWritePrepared = false
        cursorWritePrepared = false
        isInFlush = false
        closeRowCapacityBracket()
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
        onCommitPublished?()
        return true
    }

    /// Returns true if a flush was committed within the given time window.
    /// Used by the draw loop idle detector to avoid premature deactivation
    /// when flushes complete between vsync intervals.
    private static let machTimebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func hadRecentCommit(withinNs: UInt64) -> Bool {
        lock.lock()
        let t = lastCommitTime
        lock.unlock()
        if t == 0 { return false }
        let now = mach_absolute_time()
        let info = Self.machTimebaseInfo
        let elapsedNs = (now - t) * UInt64(info.numer) / UInt64(info.denom)
        return elapsedNs < withinNs
    }

    /// Returns the committed atlas texture for external grid views.
    /// Uses same lock + committed state as vertex data.
    func committedAtlasSnapshot() -> MTLTexture? {
        lock.lock()
        let tex = committedAtlasTexture
        lock.unlock()
        return tex
    }

    /// Forwards to GlyphAtlas.beginExternalRead(commandBuffer:snapshot:) —
    /// see that method's doc comment. Called by an ExternalGridView right
    /// after creating its command buffer and BEFORE creating any render
    /// encoder that samples the atlas, passing a closure that returns the
    /// texture reference (e.g. `{ committed.atlasTextureSnapshot }`). This
    /// single call performs reader admission, the texture snapshot, and the
    /// GPU-side wait-for-latest-blit encode as one atomic step under the
    /// atlas's gate lock — splitting these into separate calls would leave a
    /// gap where a writer's blit (and generation bump) lands between them.
    func beginAtlasExternalRead<T>(commandBuffer cmd: MTLCommandBuffer, snapshot: () -> T?) -> T? {
        atlas.beginExternalRead(commandBuffer: cmd, snapshot: snapshot)
    }

    /// Forwards to GlyphAtlas.endExternalRead(). Called from the
    /// completion handler of the command buffer whose render pass was
    /// covered by the matching beginAtlasExternalRead().
    func endAtlasExternalRead() {
        atlas.endExternalRead()
    }

    /// Update the default Neovim background color (for clear color in viewport edges).
    /// Called from core thread during flush.
    func updateDefaultBgColor(_ rgb: UInt32) {
        lock.lock()
        defaultBgRGB = rgb
        lock.unlock()
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
                if let cvb = bufferSets[cursorSet].cursorVertexBuffer {
                    memcpy(cvb.contents(), cursorPtr, cursorCount * MemoryLayout<Vertex>.stride)
                    bufferSets[cursorSet].cursorVertexCount = cursorCount
                } else {
                    bufferSets[cursorSet].cursorVertexCount = 0
                }
                updateCursorShaderStateFromVerts(cursorPtr: cursorPtr, cursorCount: cursorCount)
            } else {
                bufferSets[cursorSet].cursorVertexCount = 0
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
        var minX: Float = verts[0].position.x
        var maxX: Float = minX
        var minY: Float = verts[0].position.y
        var maxY: Float = minY
        for i in 0..<cursorCount {
            let p = verts[i].position
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        // Positions are grid-local pixels with y down, but the cursor uniforms
        // the shader reads are screen space, so every layer but the root needs
        // its origin added — otherwise the effect stays at the top-left window
        // whichever split the cursor is in.
        let cursorGridId = verts[0].grid_id
        var layerOriginPx = simd_float2(0, 0)
        if cursorGridId != 1 {
            let layers = pendingSurfaceLayers ?? committedSurfaceLayers
            if let layer = layers.first(where: { $0.gridId == cursorGridId }) {
                layerOriginPx = layer.originPx
            }
        }
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
        let xPx = minX + layerOriginPx.x
        let rightPx = maxX + layerOriginPx.x
        let topPx = minY + layerOriginPx.y
        let botPx = maxY + layerOriginPx.y
        // Ghostty's cursor shaders treat iCurrentCursor.y as the BOTTOM
        // edge of the cursor rect (center = y - h/2, rect = y-h..y).
        // Pass bottom-edge so the SDF renders over the actual cursor.
        let c0 = verts[0].color
        setCursorShaderState(
            rect: (xPx, botPx, rightPx - xPx, botPx - topPx),
            color: (c0.x, c0.y, c0.z, c0.w),
            gridId: verts[0].grid_id
        )
    }

    func setLineSpace(px: Int32) {
        lock.lock()
        defer { lock.unlock() }
        // Kept signed: cellHeightPx floors the row height that results.
        linespacePx = px
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
    }

    /// What one grid the surface places as a layer owes the next frame.
    ///
    /// A reference type, so mutating one grid's entry never detaches the
    /// dictionary's storage while the draw thread holds a reference into it.
    ///
    /// `flushDirtyRows` belongs to the core thread inside the flush bracket;
    /// `pendingDirtyRows`, `pendingScrollAccum` and `needsFullRedraw` cross to
    /// the draw thread under `lock`; the `draw*` fields belong to the draw
    /// thread for one frame. Every row number here is grid-local.
    private final class LayerDrawState {
        var flushDirtyRows = IndexSet()
        var pendingDirtyRows = IndexSet()
        var pendingScrollAccum: SurfaceRowScroll? = nil
        var needsFullRedraw = false
        /// Consumed under `lock` at the top of a frame; capacity is reused.
        var drawRows: [Int] = []
        var drawScroll: SurfaceRowScroll? = nil
        var drawAllRows = false
        /// The band this frame's accepted GPU scroll copy vacated, in the
        /// layer's own pixel space, or nil when no blit ran for this layer.
        var drawBlitClearBand: (clearTopPx: Int, clearBottomPx: Int)? = nil
        var lastDrawnRowCount = 0
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
        // Taken in pixels straight from the input side rather than recovered
        // from the NDC below: the NDC is built against a cell-snapped height
        // that need not match the back buffer the cursor rect was measured in.
        // Any entry for the cursor's grid displaces it: cursor vertices always
        // carry DECO_SCROLLABLE (flush.zig), and a bodily-moved float
        // (move_all) translates every vertex it owns.
        var cursorScrollOffsetPx: Float = 0
        for info in offsets {
            let ndc = -info.offsetYPx * scale
            if info.gridId == shaderCursorGridId {
                cursorScrollOffsetPx = info.offsetYPx
            }

            // Content bounds in NDC, used only for fragment-level clipping of
            // scrolled content that lands in a margin; the scroll decision
            // itself is flag-based (DECO_SCROLLABLE in the vertex data). A float
            // (clipToContent == false) translates bodily, so widen the bounds
            // past the screen and clip nothing.
            let contentTopY = info.clipToContent ? (info.gridTopYNDC - Float(info.marginTop) * cellHeightNDC) : 2.0
            let contentBottomY = info.clipToContent ? (info.gridTopYNDC - Float(info.gridRows - info.marginBottom) * cellHeightNDC) : -2.0

            scrollOffsetData.append(ScrollOffset(
                grid_id: Int32(truncatingIfNeeded: info.gridId),
                offset_y: ndc,
                content_top_y: contentTopY,
                content_bottom_y: contentBottomY,
                move_all: info.clipToContent ? 0 : 1,
                zindex: info.zindex
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
        for i in scrollOffsetData.indices {
            let gid = Int64(scrollOffsetData[i].grid_id)
            let retained = retention.publishedCount(gridId: gid)
            if retained > 0, cellHeightNDC > 0, ScrollRetention.coversBand(
                retainedRows: retained,
                offsetNDC: scrollOffsetData[i].offset_y,
                cellHeightNDC: cellHeightNDC
            ) {
                scrollOffsetData[i].pin_edges = 0
            }
            // Logged AFTER the pin decision so pin/retained carry the values
            // a frame actually renders with — the GUI harness derives the
            // margin band and asserts retained-row band coverage from these
            // fields, mirroring the [ExternalGridView] scroll offset line.
            let info = offsets.first { $0.gridId == gid }
            ZonvieCore.appLog("[renderer] scroll offset: gridId=\(gid) offsetYPx=\(info?.offsetYPx ?? 0) marginTop=\(info?.marginTop ?? 0) marginBottom=\(info?.marginBottom ?? 0) ndc=\(scrollOffsetData[i].offset_y) top=\(scrollOffsetData[i].content_top_y) bot=\(scrollOffsetData[i].content_bottom_y) pin=\(scrollOffsetData[i].pin_edges) retained=\(retained) gridTop=\(info?.gridTopYNDC ?? 0) cellNDC=\(cellHeightNDC) vpH=\(drawableHeight)")
        }

        // Store as value-type array; draw() will snapshot and pass via setVertexBytes.
        // This eliminates the GPU/CPU race on shared MTLBuffers.
        hasActiveScrollOffset = count > 0
        // This surface owns the cursor's grid whenever it appears in its own
        // offsets, and a grid with no entry is simply not displaced.
        shaderCursorScrollOffsetPx = cursorScrollOffsetPx
        evaluateCursorShaderChangeLocked(scrollOffsetPx: cursorScrollOffsetPx)
    }

    /// Fold the cursor's current displacement into the shader endpoints for a
    /// frame that did not rebuild the scroll offsets.
    ///
    /// `updateScrollOffsets` is the only place that knows a grid's
    /// displacement, and the view skips it entirely once nothing is scrolling
    /// — but the cursor still moves. Without this the shader endpoints stay at
    /// whatever the last scrolled frame left, which from a cold start is a
    /// zero rect at the drawable origin: a cursor shader draws nothing at all
    /// until the first scroll (verified with the harness in tmp/cursorprobe).
    /// The cached offset is correct on those frames because the last rebuild
    /// before going idle ran with an empty offset set.
    func refreshCursorShaderState() {
        lock.lock()
        defer { lock.unlock() }
        evaluateCursorShaderChangeLocked(scrollOffsetPx: shaderCursorScrollOffsetPx)
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
        hasActiveScrollOffset = false
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

        // Content bounds for fragment shader clipping. Float windows
        // (clipToContent == false) translate as a whole; widen the bounds past the
        // screen so nothing is clipped, matching updateScrollOffsets.
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
        if let window = view.window, window.isMiniaturized || !window.occlusionState.contains(.visible) {
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
            _ = ensurePipelineReady(view: view)

            // Graceful degradation: if GPU initialization failed, skip rendering
            guard pipeline != nil, sampler != nil else {
                if let error = initializationError {
                    ZonvieCore.appLog("[draw] Skipping render due to initialization error: \(error)")
                }
                (view as? MetalTerminalView)?.notifyDrawIdle()
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // Keep the vsync draw loop alive while any custom shader references
            // animation-driving uniforms (iTime etc.). A missing pipeline must
            // not reset the idle counter every frame.
            if anyCustomShaderNeedsAnimation {
                (view as? MetalTerminalView)?.activateDrawLoop()
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

            // Take in any reconciliation published since onPreDraw ran — most
            // of all the one the guard band just waited for. Its rows are in
            // the set latched below, so it belongs to this frame.
            onBeforeCommittedSnapshot?()

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
            // Raw value of hasActiveScrollOffset at snapshot time (NOT the
            // combined smoothScrolling). Stored to lastDrawnHadActiveScrollOffset
            // below so the one-frame extension does not self-latch.
            let hadActiveScrollOffsetThisFrame: Bool
            let scrollSnapshot: [ScrollOffset]  // Snapshot for setVertexBytes (no GPU/CPU race)
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

            let snappedBgRGB: UInt32
            let snappedCommittedDrawableW: UInt32
            let snappedCommittedDrawableH: UInt32

            lock.lock()
            if rowCapacityProvisioning || rowCapacityRequiredRows > 0 || rowCapacityHardFailure {
                let terminal = rowCapacityHardFailure
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
            pendingDirtyRectPx = nil
            pendingDirtyRows.removeAll()
            // Extend smoothScrolling one frame past the offset reaching zero:
            // the back buffer still holds pixels rendered with a non-zero shader
            // offset, and blitting those again is a 1-row jitter.
            hadActiveScrollOffsetThisFrame = hasActiveScrollOffset
            smoothScrolling = hadActiveScrollOffsetThisFrame || lastDrawnHadActiveScrollOffset
            scrollSnapshot = scrollOffsetData  // Value-type copy (safe across frames)
            // Retire retained rows whose grid is no longer displaced. Also here,
            // not only in updateScrollOffsets: the view skips that function once
            // nothing is easing, so a grid that scrolled without ever being
            // displaced (a page jump, a repaint that seeded nothing) kept its
            // rows for the session and forced its layer to redraw every row.
            // `smoothScrollSeeds` is read under the lock that published them, so
            // an ease that has committed but not been spent keeps its band.
            retention.pruneUndisplaced(offsets: scrollOffsetData, seedGrids: smoothScrollSeeds)
            retainedSnapshot = retention.snapshotPublished()
            fixedFloatBandsSnapshot = fixedFloatBandData  // Value-type copies (safe across frames)
            fixedFloatIntervalsSnapshot = fixedFloatIntervalData
            rowLogicalToSlotSnapshot = bufferSets[csi].rowLogicalToSlot
            rowSlotSourceRowsSnapshot = bufferSets[csi].rowSlotSourceRows
            layerSnapshot.removeAll(keepingCapacity: true)
            layerSetsSnapshot.removeAll(keepingCapacity: true)
            layerStateSnapshot.removeAll(keepingCapacity: true)
            for layer in committedSurfaceLayers {
                layerSnapshot.append(layer)
                layerSetsSnapshot.append(gridBuffers.existingSets(for: layer.gridId) ?? [])
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
                layerStateSnapshot.append(state)
            }
            cursorLayerOriginSnapshot = committedCursorLayerOriginPx
            snappedBgRGB = defaultBgRGB
            snappedCommittedDrawableW = committedDrawableW
            snappedCommittedDrawableH = committedDrawableH
            lock.unlock()

            defer {
                dirtyRows.removeAll(keepingCapacity: true)
                swap(&dirtyRows, &dirtyRowsScratch)
            }

            // Safety defer: decrement gpuInFlight + signal semaphore on early return.
            // On normal GPU submission, the completion handler handles cleanup instead.
            var gpuSubmitted = false
            defer {
                if !gpuSubmitted {
                    inflightSemaphore.signal()
                    lock.lock()
                    completeSurfaceGpuReadLocked(csi)
                    cursorGpuInFlightCount[cci] -= 1
                    lock.unlock()
                }
            }

            // Now safe to read from committed set (protected by gpuInFlight)
            let committed = bufferSets[csi]
            let committedCursor = bufferSets[cci]
            let rowBuffersSnapshot = committed.rowState.buffers
            let rowCountsSnapshot = committed.rowState.counts
            let rowMode = committed.rowState.usingRowBuffers
            let committedMainCount = committed.mainVertexCount
            let committedCursorCount = committedCursor.cursorVertexCount

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
                return (hasPresentedOnce, cursorBlinkStateStorage)
            }()
            let hasPresentedOnceSnapshot = renderStateSnapshot.hasPresented
            let cursorBlinkStateSnapshot = renderStateSnapshot.cursorBlink

            let cw = cellWidthPx
            let ch = cellHeightPx
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
                FrameTracer.trace(.drawSkipNoChange, a: 1)
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            let blinkStateChanged = cursorBlinkStateSnapshot != lastRenderedBlinkState

            // Check if committed data changed since last draw
            let hasNewCommit = currentCommitRevision != lastDrawnRevision

            // Check if drawable size changed since last render (window resize).
            // Must re-render with current viewport even if vertices haven't changed,
            // otherwise macOS stretches the old frame to the new window size.
            let drawableSizeChanged = view.drawableSize != lastDrawnDrawableSize

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
            if hasPresentedOnceSnapshot,
               !hasNewCommit,
               dirtyRectPxOpt == nil,
               dirtyRows.isEmpty,
               !anyLayerWork,
               !smoothScrolling,
               !blinkStateChanged,
               !drawableSizeChanged,
               !anyCustomShaderNeedsAnimation {
                // Still reset redrawPending so future redraws are not blocked.
                FrameTracer.trace(.drawSkipNoChange, a: 2)
                (view as? MetalTerminalView)?.notifyDrawIdle()
                (view as? MetalTerminalView)?.didDrawFrame()
                return
            }

            // In rowMode with no vertex updates and no dirty rows, skip rendering.
            // Also skip when a new commit arrived but carried no visual changes
            // (e.g. empty non-scroll flush).  Without this, the .clear loadAction
            // destroys the backbuffer between GPU-blit scroll frames.
            // Same animation exception as above.
            if rowMode && dirtyRows.isEmpty && !anyLayerWork && !smoothScrolling && !blinkStateChanged && !drawableSizeChanged && hasPresentedOnceSnapshot && !anyCustomShaderNeedsAnimation {
                FrameTracer.trace(.drawSkipNoChange, a: 3)
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
                && !anyCustomShaderNeedsAnimation {
                lastRenderedBlinkState = cursorBlinkStateSnapshot
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
            let prevDrawnDrawableSize = lastDrawnDrawableSize
            let prevDrawnHadActiveScrollOffset = lastDrawnHadActiveScrollOffset
            let prevRenderedBlinkState = lastRenderedBlinkState

            // Track that we've consumed this revision and drawable size
            lastDrawnRevision = currentCommitRevision
            lastDrawnDrawableSize = view.drawableSize
            // Record the raw hasActiveScrollOffset, NOT the combined
            // smoothScrolling: the combined value would latch true forever.
            lastDrawnHadActiveScrollOffset = hadActiveScrollOffsetThisFrame

            // Update last rendered blink state since we're proceeding with render
            lastRenderedBlinkState = cursorBlinkStateSnapshot


            // --- Step 2: Pre-compute shared values for loadAction gate and draw branching ---
            let cellWi = max(1, UInt32(cw.rounded(.up)))
            let cellHi = max(1, UInt32(ch.rounded(.up)))
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
            // The root layer drives the pixel space core vertices arrive in.
            let rootLayerOrigin = layerSnapshot.first?.originPx ?? simd_float2(0, 0)
            let viewportMetrics = SurfaceViewportMetrics(
                viewportWidth: vpWidth,
                viewportHeight: vpHeight,
                drawableSize: view.drawableSize,
                layerOriginPx: rootLayerOrigin
            )

            let use2Pass = blurEnabled && backgroundPipeline != nil && glyphPipeline != nil

            let safeRowCount: Int
            if rowMode {
                safeRowCount = min(min(rowBuffersSnapshot.count, rowCountsSnapshot.count), rowLogicalToSlotSnapshot.count)
            } else {
                safeRowCount = 0
            }
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
            let retainedRowBase = safeRowCount
            let smoothRowRange = 0..<(safeRowCount + (smoothScrolling ? retainedSnapshot.count : 0))
            func resolvedSmoothRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow >= retainedRowBase else { return resolvedRowState(logicalRow) }
                let i = logicalRow - retainedRowBase
                guard i < retainedSnapshot.count else { return nil }
                let r = retainedSnapshot[i]
                // A layer's retained rows are drawn in that layer's own pass,
                // where its transform places them.
                guard r.gridId == 1 else { return nil }
                guard r.cellHeightPx == Float(cellHi) else { return nil }
                // Same relation resolvedRowState uses: the vertices live at
                // sourceRow and have to appear at targetRow.
                let translationY = Float(r.targetRow - r.sourceRow) * Float(cellHi)
                return (r.count, r.buffer, translationY)
            }

            // --- Step 3: Compute cursor grid row from vertex positions ---
            var cursorGridRow: Int = -1
            if currentCursorCount > 0, let cvb = committedCursor.cursorVertexBuffer {
                let ptr = cvb.contents().bindMemory(to: Vertex.self, capacity: currentCursorCount)
                // Grid-local pixels with y down: the smallest y is the top edge.
                var topYPx: Float = ptr[0].position.y
                for i in 1..<currentCursorCount {
                    let y = ptr[i].position.y
                    if y < topYPx { topYPx = y }
                }
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

            // Skip the main render pass for a frame that changes no backTex
            // pixel — blink-only or noop. The cursor lives on the drawable, not
            // backTex, so the copy + cursor passes alone reproduce the right
            // pixel. Avoids the ~5.7ms .clear cost (alpha=0.8 backgrounds
            // disable Apple's fast-clear path). Glow is excluded: bloom samples
            // backTex through its own intermediate pass.
            let noMainWorkFrame = !hasNewCommit
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
                lastDrawnDrawableSize = prevDrawnDrawableSize
                lastDrawnHadActiveScrollOffset = prevDrawnHadActiveScrollOffset
                lastRenderedBlinkState = prevRenderedBlinkState
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
            // internally, but the removeAll calls themselves would otherwise
            // run unconditionally).
            if ZonvieCore.appLogEnabled {
                gpuPerfSlots.removeAll(keepingCapacity: true)
                gpuPerfFullSlots.removeAll(keepingCapacity: true)
                gpuPerfNextIdx = 0
                gpuStatsSlots.removeAll(keepingCapacity: true)
            }
            // The rows of a layer the current buffer set can actually resolve.
            // Asked for by both the blit decision below and the layer draw
            // loop, which have to agree on how tall the layer is.
            func layerResolvableRowCount(_ li: Int, _ layer: SurfaceLayer) -> Int {
                let sets = layerSetsSnapshot[li]
                guard sets.count == 3 else { return 0 }
                return min(sets[csi].rowLogicalToSlot.count, layer.rows)
            }

            // Retained rows of this layer at the current cell height, collected
            // into `retainedIndexScratch`; the draw loop refills it per layer.
            func collectLayerRetainedRows(_ gridId: Int64) -> Int {
                retainedIndexScratch.removeAll(keepingCapacity: true)
                for (i, r) in retainedSnapshot.enumerated()
                where r.gridId == gridId && r.cellHeightPx == Float(cellHi) {
                    retainedIndexScratch.append(i)
                }
                return retainedIndexScratch.count
            }

            // Why a layer has to redraw every row instead of only the rows it
            // owes. Asked twice per frame — here, so a layer that will redraw
            // everything refuses the blit that redraw would overwrite, and again
            // in the draw loop — so the condition lives in one place.
            // `loadActionIsClear` is not known yet here; passing false is exact
            // (see the caller). A disagreement costs a wasted blit or a wider
            // redraw, never correctness.
            func layerNeedsAllRows(
                state: LayerDrawState?,
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
            // to the layers drawn on top of it. The blit rewrites every pixel of
            // the scrolled rectangle R (copy plus vacated band). For a layer M
            // above it: M's own pixels inside R moved, so every row of M meeting
            // R is redrawn; and what they covered moved with them, so the rows
            // of this layer they were dragged into — the same rows shifted by
            // -rowsDelta, plus the unshifted ones to kill boundary off-by-ones —
            // are redrawn from this layer's vertices. Both ranges come from a
            // pixel intersection, so a layer off the cell grid gets both rows a
            // boundary straddles. Only layers ABOVE need marking: R lies inside
            // this layer's own rect, and `layerSnapshot` is back-to-front, so a
            // marked layer repaints after this one, which is the screen order.
            func markLayersOverBlit(
                _ li: Int,
                _ layer: SurfaceLayer,
                _ state: LayerDrawState,
                _ p: RowScrollBlitPlan,
                _ rowsDelta: Int
            ) {
                let rowHeightPx = Int(cellHi)
                guard rowHeightPx > 0 else { return }
                let blitLeftPx = p.originXPx
                let blitRightPx = p.originXPx + p.copyWidthPx
                let blitTopPx = min(min(p.srcYPx, p.dstYPx), p.clearTopPx)
                let blitBottomPx = max(max(p.srcYPx, p.dstYPx) + p.copyHeightPx, p.clearBottomPx)
                // The region in this layer's own rows; blitTopPx is exactly
                // originYPx + rowStart * rowHeightPx.
                let regionFirstRow = (blitTopPx - p.originYPx) / rowHeightPx
                let regionLastRow = p.clampedRowEnd - 1
                guard regionLastRow >= regionFirstRow else { return }

                for mi in (li + 1)..<layerSnapshot.count {
                    let above = layerSnapshot[mi]
                    guard above.rows > 0, above.cols > 0 else { continue }
                    let aLeftPx = Int(above.originPx.x.rounded(.down))
                    let aTopPx = Int(above.originPx.y.rounded(.down))
                    let aRightPx = aLeftPx + above.cols * Int(cellWi)
                    let aBottomPx = aTopPx + above.rows * rowHeightPx
                    guard aLeftPx < blitRightPx, aRightPx > blitLeftPx,
                          aTopPx < blitBottomPx, aBottomPx > blitTopPx
                    else { continue }
                    let overlapTopPx = max(aTopPx, blitTopPx)
                    let overlapBottomPx = min(aBottomPx, blitBottomPx)

                    // The covering layer puts itself back. A layer with no draw
                    // state redraws every row anyway, so there is nothing to
                    // mark for it.
                    if let aboveState = layerStateSnapshot[mi] {
                        let aFirstRow = max(0, (overlapTopPx - aTopPx) / rowHeightPx)
                        let aLastRow = min(above.rows - 1, (overlapBottomPx - 1 - aTopPx) / rowHeightPx)
                        if aLastRow >= aFirstRow {
                            aboveState.drawRows.append(contentsOf: aFirstRow...aLastRow)
                        }
                    }

                    // This layer puts back the rows the covering layer's pixels
                    // were dragged into, plus the rows they came from.
                    let underFirstRow = max(regionFirstRow, (overlapTopPx - p.originYPx) / rowHeightPx)
                    let underLastRow = min(regionLastRow, (overlapBottomPx - 1 - p.originYPx) / rowHeightPx)
                    guard underLastRow >= underFirstRow else { continue }
                    state.drawRows.append(contentsOf: underFirstRow...underLastRow)
                    let shiftedFirstRow = max(regionFirstRow, underFirstRow - rowsDelta)
                    let shiftedLastRow = min(regionLastRow, underLastRow - rowsDelta)
                    if shiftedLastRow >= shiftedFirstRow {
                        state.drawRows.append(contentsOf: shiftedFirstRow...shiftedLastRow)
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
            for (li, layer) in layerSnapshot.enumerated().dropFirst() {
                guard let state = layerStateSnapshot[li], let scroll = state.drawScroll else { continue }
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
                    if scrollBlitEncoder == nil {
                        ensureScrollScratchTexture(drawableSize: backBufferSize, pixelFormat: backTex.pixelFormat)
                        scrollBlitEncoder = cmd.makeBlitCommandEncoder()
                    }
                    if let blit = scrollBlitEncoder, let scratch = scrollScratchTexture {
                        let t0 = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
                        encodeRowScrollBlit(blit, backTexture: backTex, scratch: scratch, plan: p)
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
                    let bandBottomPx = bandTopPx + bandRowHeightPx
                    for (li, layer) in layerSnapshot.enumerated().dropFirst() {
                        guard let state = layerStateSnapshot[li], layer.rows > 0 else { continue }
                        let originY = Int(layer.originPx.y.rounded(.down))
                        guard bandBottomPx > originY else { continue }
                        // A layer need not be cell-aligned, so one root row can
                        // straddle two of its rows.
                        let firstRow = max(0, (bandTopPx - originY) / bandRowHeightPx)
                        let lastRow = min(layer.rows - 1, (bandBottomPx - 1 - originY) / bandRowHeightPx)
                        guard lastRow >= firstRow else { continue }
                        state.drawRows.append(contentsOf: firstRow...lastRow)
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
                    let above = layerSnapshot[mi]
                    guard let aboveState = layerStateSnapshot[mi],
                          above.rows > 0, above.cols > 0 else { continue }
                    let aLeftPx = Int(above.originPx.x.rounded(.down))
                    let aRightPx = aLeftPx + above.cols * Int(cellWi)
                    guard aLeftPx < rightPx, aRightPx > leftPx else { continue }
                    let aTopPx = Int(above.originPx.y.rounded(.down))
                    let aBottomPx = aTopPx + above.rows * rowHeightPx
                    guard aTopPx < bandBottomPx, aBottomPx > bandTopPx else { continue }
                    let aFirstRow = max(0, (max(aTopPx, bandTopPx) - aTopPx) / rowHeightPx)
                    let aLastRow = min(above.rows - 1, (min(aBottomPx, bandBottomPx) - 1 - aTopPx) / rowHeightPx)
                    if aLastRow >= aFirstRow {
                        aboveState.drawRows.append(contentsOf: aFirstRow...aLastRow)
                    }
                }
            }
            // Back to front, and each layer is normalized before it becomes a
            // source: only lower layers write to a higher one, so a layer's
            // list is final by the time its turn comes. Propagating it with
            // duplicates still in it would copy every duplicate into every
            // layer above, doubling the count per overlapping layer. The
            // frontmost layer marks nothing but is normalized here too, so no
            // separate pass follows.
            for (li, layer) in layerSnapshot.enumerated().dropFirst() {
                guard let state = layerStateSnapshot[li] else { continue }
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
            let shouldReusePreviousContents = !glowEnabled && (canBlinkFastPath || useGpuScrollCopy || canDirtyOnlyWithBlur || (!smoothScrolling && (dirtyRectPxOpt != nil || hasAnyDirtyInRowMode)))
            rpd.colorAttachments[0].loadAction = resolveSurfaceColorLoadAction(
                blurEnabled: blurEnabled,
                hasPresentedOnce: hasPresentedOnceSnapshot,
                drawableSizeChanged: drawableSizeChanged,
                shouldReusePreviousContents: shouldReusePreviousContents,
                forceReusePreviousContents: !glowEnabled && (canBlinkFastPath || useGpuScrollCopy || canDirtyOnlyWithBlur)
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
            attachGpuPerfSamples(to: rpd, label: "main")
            attachGpuStatsSamples(to: rpd, label: "main")
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                // Encoder creation failed (rare). Commit the empty cmd anyway so
                // the IOAccelerator region attached to it is reclaimed; otherwise
                // an uncommitted MTLCommandBuffer leaks GPU memory permanently.
                let sem = inflightSemaphore
                let lk = lock
                cmd.addCompletedHandler { [weak self] _ in
                    lk.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    self?.cursorGpuInFlightCount[cci] -= 1
                    lk.unlock()
                    sem.signal()
                }
                cmd.commit()
                gpuSubmitted = true
                bailWithoutSubmit("render encoder creation failed")
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
            bindSurfaceScrollOffsets(encoder: enc, offsets: scrollSnapshot, device: device, scratchBuffer: &committed.scrollOffsetBuffer, scratchCapacity: &committed.scrollOffsetBufferCap)
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

            // Under .load a dirty row must overwrite its old pixels rather than
            // draw on top of them: the core drops the root's default-background
            // runs while the surface has layers (flush.zig `skip_default_bg`),
            // so a row that lost or kept a glyph covers neither. The non-blur
            // pipeline suffices — backgroundAlpha is 1.0, so the solid quad
            // overwrites.
            func clearDirtyRowsNonBlur(_ rows: [Int]) {
                enc.setRenderPipelineState(pipeline!)
                let width = Float(vpWidth > 0 ? vpWidth : Double(view.drawableSize.width))
                let height = Float(vpHeight > 0 ? vpHeight : Double(view.drawableSize.height))
                for row in rows {
                    let topPx = row * cellH
                    drawBackgroundClearBand(
                        enc,
                        clearBand: (clearTopPx: topPx, clearBottomPx: topPx + cellH),
                        xRangePx: (leftPx: 0, rightPx: width),
                        drawableHeight: height,
                        bgRGB: snappedBgRGB,
                        gridId: 1
                    )
                }
            }

            // The scissored single-pass dirty-row draw that both the
            // GPU-scroll-copy arm and the plain partial-redraw arm below
            // perform, verbatim: overwrite the dirty rows, then draw them one
            // scissor rect each.
            func drawScissoredDirtyRows() {
                clearDirtyRowsNonBlur(dirtyRows)
                _ = encodeSurfaceRowDraws(
                    encoder: enc,
                    rows: dirtyRows,
                    resolve: resolvedRowState,
                    scissor: { row in
                        makeRowScissorRect(
                            row: row,
                            cellHeight_px: cellH,
                            drawableWidth_px: drawableW,
                            renderTargetWidth_px: backTex.width,
                            renderTargetHeight_px: backTex.height
                        )
                    },
                    pipeline: pipeline!,
                    backgroundPipeline: nil,
                    glyphPipeline: nil,
                    useTwoPass: false
                )
            }

            // === PERF LOG: encode_setup → encode_rows boundary ===
            let t_encode_rows_start: CFAbsoluteTime = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
            let encode_setup_us: Double = ZonvieCore.appLogEnabled ? (t_encode_rows_start - t_encode_start) * 1_000_000 : 0

            // use2Pass and safeRowCount are pre-computed in Step 2 above.

            if rowMode {
                if use2Pass {
                    if canBlinkFastPath {
                        // FAST PATH: blink-only — redraw only cursor row.
                        // Single-pass via unified blur pipeline when available;
                        // 2-pass fallback otherwise (matches the global rule
                        // for use2Pass branches).
                        let resolved = resolvedRowState(cursorGridRow)!  // guaranteed non-nil by canBlinkFastPath
                        let vc = resolved.vc
                        let vb = resolved.vb

                        if let scissor = makeRowScissorRect(
                            row: cursorGridRow,
                            cellHeight_px: Int(cellHi),
                            drawableWidth_px: drawableW,
                            renderTargetWidth_px: backTex.width,
                            renderTargetHeight_px: backTex.height
                        ) {
                            enc.setScissorRect(scissor)
                            var rowTranslation = resolved.translationY
                            if let unified = unifiedBlurPipeline {
                                enc.setRenderPipelineState(unified)
                                enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                                enc.setVertexBuffer(vb, offset: 0, index: 0)
                                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                            } else {
                                // Pass 1: Background (overwrite blending — erases old cursor)
                                enc.setRenderPipelineState(backgroundPipeline!)
                                enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                                enc.setVertexBuffer(vb, offset: 0, index: 0)
                                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)

                                // Pass 2: Glyph (alpha blending — redraws text/decorations)
                                enc.setRenderPipelineState(glyphPipeline!)
                                enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                                enc.setVertexBuffer(vb, offset: 0, index: 0)
                                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vc)
                            }
                        }

                        ZonvieCore.appLog("[draw] blinkFastPath: cursorRow=\(cursorGridRow) vc=\(vc) unified=\(unifiedBlurPipeline != nil)")
                    } else if canDirtyOnlyWithBlur {
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
                        if let bgPipe = backgroundPipeline {
                            enc.setRenderPipelineState(bgPipe)
                            for row in dirtyRows {
                                let topPx = row * cellHiI
                                let bottomPx = topPx + cellHiI
                                drawBackgroundClearBand(
                                    enc,
                                    clearBand: (clearTopPx: topPx, clearBottomPx: bottomPx),
                                    xRangePx: (leftPx: 0, rightPx: drawableWidthF),
                                    drawableHeight: drawableHeightF,
                                    bgRGB: snappedBgRGB,
                                    gridId: 1
                                )
                            }
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
                            pipeline: pipeline!,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true,
                            unifiedBlurPipeline: unifiedBlurPipeline
                        )
                    } else {
                        // 2-Pass rendering for blur: draw backgrounds first, then glyphs
                        // This prevents ghosting with semi-transparent backgrounds
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: smoothRowRange,
                            resolve: resolvedSmoothRowState,
                            pipeline: pipeline!,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true,
                            unifiedBlurPipeline: unifiedBlurPipeline
                        )
                    }
                } else if smoothScrolling {
                    // Smooth scroll without blur: draw all rows without scissor
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        rows: smoothRowRange,
                        resolve: resolvedSmoothRowState,
                        pipeline: pipeline!,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else if !glowEnabled && (!dirtyRows.isEmpty || anyLayerWork) && !drawableSizeChanged
                            && rpd.colorAttachments[0].loadAction == .load {
                    // Normal mode: scissor per dirty row (prevents giant scissor from accumulated unions).
                    // Skipped when glow is enabled — full redraw needed for correct bloom composite.
                    // Use this only when the render pass preserved clean rows.
                    // Resize and fail-closed blur-pipeline frames use .clear;
                    // drawing only dirty rows there would blank every other row.
                    drawScissoredDirtyRows()
                } else {
                    // Safety: if no dirtyRows (first frame), draw all rows without scissor.
                    _ = encodeSurfaceRowDraws(
                        encoder: enc,
                        rows: 0..<safeRowCount,
                        resolve: resolvedRowState,
                        pipeline: pipeline!,
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
                    pipeline: pipeline!,
                    backgroundPipeline: backgroundPipeline,
                    glyphPipeline: glyphPipeline,
                    useTwoPass: use2Pass,
                    scissorRect: dirtyScissor,
                    unifiedBlurPipeline: unifiedBlurPipeline
                )
            }

            // Non-root layers, back-to-front, on top of the root grid. Each
            // gets its own pixel space and is clipped to its own rect. A layer
            // whose grid has no rows yet draws nothing, which is what the
            // core's layout contract requires.
            if layerSnapshot.count > 1 {
                enc.setRenderPipelineState(pipeline!)
                for (li, layer) in layerSnapshot.enumerated().dropFirst() {
                    let sets = layerSetsSnapshot[li]
                    guard sets.count == 3 else { continue }
                    let set = sets[csi]
                    let rowCount = layerResolvableRowCount(li, layer)
                    guard rowCount > 0 else { continue }
                    // What this layer owes the frame; nil for a grid with no
                    // draw state, which is treated as owing everything.
                    let st = layerStateSnapshot[li]

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
                    // A displaced origin is fractional mid-ease; cover the row
                    // of pixels the flooring above would otherwise clip.
                    let scissorPadY = drawOriginPx.y == drawOriginPx.y.rounded(.down) ? 0 : 1
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
                    let retainedBase = rowCount

                    // What one row of this layer owes the encoder. Shared by both
                    // arms below so the gated path resolves rows the same way.
                    func resolveLayerRow(_ row: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                        if row >= retainedBase {
                            let i = row - retainedBase
                            // Only the full-redraw arm asks for retained rows;
                            // on the gated arm there are none by construction,
                            // and a dirty row can name a row the layer lost.
                            guard i < self.retainedIndexScratch.count else { return nil }
                            let r = retainedSnapshot[self.retainedIndexScratch[i]]
                            return (r.count, r.buffer, Float(r.targetRow - r.sourceRow) * Float(cellHi))
                        }
                        guard row >= 0, row < rowCount else { return nil }
                        return resolveSurfaceGridRow(set, row: row, cellHeightPx: Float(cellHi))
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
                                let topPx = row * Int(cellHi)
                                drawBackgroundClearBand(
                                    enc,
                                    clearBand: (clearTopPx: topPx, clearBottomPx: topPx + Int(cellHi)),
                                    xRangePx: (leftPx: 0, rightPx: Float(widthPx)),
                                    drawableHeight: Float(rowCount * Int(cellHi)),
                                    bgRGB: snappedBgRGB,
                                    gridId: layer.gridId
                                )
                                encodedRows += 1
                            }
                            enc.setRenderPipelineState(pipeline!)
                        }

                        // Same pipeline choice as the root grid: under blur the
                        // background pass overwrites rather than blending, so a
                        // single-pass layer would darken its own background
                        // against whatever it covers.
                        encodedRows += encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: 0..<(rowCount + retainedForLayerCount),
                            resolve: resolveLayerRow,
                            pipeline: pipeline!,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: use2Pass,
                            unifiedBlurPipeline: unifiedBlurPipeline
                        )
                    } else {
                        let dirtyLayerRows = st!.drawRows
                        // The band this layer's GPU scroll copy vacated, in the
                        // layer's own pixel space. Drawn before the rows: the
                        // plan's dirty rows cover the band and must land on top.
                        if let band = st!.drawBlitClearBand {
                            enc.setRenderPipelineState(use2Pass ? (backgroundPipeline ?? pipeline!) : pipeline!)
                            drawBackgroundClearBand(
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
                            enc.setRenderPipelineState(use2Pass ? (backgroundPipeline ?? pipeline!) : pipeline!)
                            for row in dirtyLayerRows where resolveLayerRow(row) == nil {
                                guard row >= 0, row < rowCount else { continue }
                                let topPx = row * Int(cellHi)
                                drawBackgroundClearBand(
                                    enc,
                                    clearBand: (clearTopPx: topPx, clearBottomPx: topPx + Int(cellHi)),
                                    xRangePx: (leftPx: 0, rightPx: Float(widthPx)),
                                    drawableHeight: Float(rowCount * Int(cellHi)),
                                    bgRGB: snappedBgRGB,
                                    gridId: layer.gridId
                                )
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
                            pipeline: pipeline!,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: use2Pass,
                            unifiedBlurPipeline: unifiedBlurPipeline
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
                    device: device,
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
            var glowPassSucceeded = !glowEnabled
            if glowEnabled,
               let extractPipe = glowExtractPipeline,
               let downPipe = kawaseDownPipeline,
               let upPipe = kawaseUpPipeline,
               let compositePipe = glowCompositePipeline,
               let copyVB = copyVertexBuffer,
               let bilinSamp = bilinearSampler
            {
                let vpSize = CGSize(width: viewportMetrics.viewportWidth, height: viewportMetrics.viewportHeight)
                let intensity = (view as? MetalTerminalView)?.core?.getGlowIntensity() ?? 0.8

                if glowTextures.ensure(device: device, drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat),
                   glowTextures.ensureIntensityBuffer(device: device) {
                    glowPassSucceeded = encodeSurfaceBloomPasses(
                    cmd: cmd,
                    backTex: backTex,
                    viewportSize: vpSize,
                    drawableSize: view.drawableSize,
                    layerTransform: viewportMetrics.layerTransform,
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
                        for (li, layer) in layerSnapshot.enumerated().dropFirst() {
                            let sets = layerSetsSnapshot[li]
                            guard sets.count == 3 else { continue }
                            let set = sets[csi]
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
                                    guard let occludePipe = glowOccludePipeline else { continue }
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
                    if cursorBlinkStateSnapshot, currentCursorCount > 0, let cvb = committedCursor.cursorVertexBuffer {
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
                }
            }

            guard glowPassSucceeded else {
                let sem = inflightSemaphore
                let lk = lock
                cmd.addCompletedHandler { [weak self] _ in
                    lk.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    self?.cursorGpuInFlightCount[cci] -= 1
                    lk.unlock()
                    sem.signal()
                }
                cmd.commit()
                gpuSubmitted = true
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
                let sem = inflightSemaphore
                let lk = lock
                cmd.addCompletedHandler { [weak self] _ in
                    lk.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    self?.cursorGpuInFlightCount[cci] -= 1
                    lk.unlock()
                    sem.signal()
                }
                cmd.commit()
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
            // mode. See ExternalGridView.draw for the external-grid path.
            // Multi-pass chains ping-pong between customShaderPong[0/1];
            // the final pass writes straight into the drawable.
            var customShaderHandled = false
            if !customShaderPipelines.isEmpty,
               customShaderPostProcess == .afterBloom,
               let copyVB = copyVertexBuffer,
               let bilinSamp = bilinearSampler
            {
                let uniforms = makeCustomShaderUniforms(
                    screenResolution: view.drawableSize,
                    windowOffset: .zero,
                    windowSize: view.drawableSize
                )
                let pipelines = customShaderPipelines
                if pipelines.count > 1 {
                    ensureCustomShaderPong(size: view.drawableSize, pixelFormat: drawable.texture.pixelFormat)
                }
                let pongsReady =
                    pipelines.count <= 1
                    || (customShaderPong[0] != nil && customShaderPong[1] != nil)
                if pongsReady {
                    var allPassesEncoded = true
                    for (i, pipeline) in pipelines.enumerated() {
                        let isLast = (i == pipelines.count - 1)
                        let inputTex: MTLTexture = (i == 0) ? backTex : customShaderPong[(i - 1) % 2]!
                        let outputTex: MTLTexture = isLast ? drawable.texture : customShaderPong[i % 2]!
                        if !pipeline.encode(
                            cmd: cmd,
                            input: inputTex,
                            output: outputTex,
                            copyVertexBuffer: copyVB,
                            sampler: bilinSamp,
                            uniforms: uniforms
                        ) {
                            allPassesEncoded = false
                            break
                        }
                    }
                    customShaderHandled = allPassesEncoded
                }
            }

            var finalCopyEncoded = customShaderHandled
            if !customShaderHandled, let copyPipe = copyPipeline, let copyVB = copyVertexBuffer {
                let copyRPD = MTLRenderPassDescriptor()
                copyRPD.colorAttachments[0].texture = drawable.texture
                copyRPD.colorAttachments[0].loadAction = .dontCare
                copyRPD.colorAttachments[0].storeAction = .store

                // Full 4-stage sampling (vertex + fragment) on the copy pass
                // to investigate why it measures ~2.9ms vs ~0.7ms theoretical.
                attachGpuPerfSamplesFull(to: copyRPD, label: "copy")
                attachGpuStatsSamples(to: copyRPD, label: "copy")
                if let copyEnc = cmd.makeRenderCommandEncoder(descriptor: copyRPD) {
                    copyEnc.setRenderPipelineState(copyPipe)
                    copyEnc.setVertexBuffer(copyVB, offset: 0, index: 0)
                    copyEnc.setFragmentTexture(backTex, index: 0)
                    copyEnc.setFragmentSamplerState(sampler!, index: 0)
                    copyEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    copyEnc.endEncoding()
                    finalCopyEncoded = true
                }
            }

            guard finalCopyEncoded else {
                // Submit the already-encoded back-buffer work so Metal can
                // reclaim this command buffer, but do not present an
                // untouched drawable or consume the frame's dirty state.
                let sem = inflightSemaphore
                let lk = lock
                cmd.addCompletedHandler { [weak self] _ in
                    lk.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    self?.cursorGpuInFlightCount[cci] -= 1
                    lk.unlock()
                    sem.signal()
                }
                cmd.commit()
                gpuSubmitted = true
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
                if customShaderHandled {
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
                    && !customShaderHandled
                ZonvieCore.appLogPerf("[perf] copy_opportunity dirty_rows=\(dirtyRows.count) dirty_h_px=\(dirtyHpx) drawable_h_px=\(drawableHpx) dirty_pct=\(String(format: "%.1f", dirtyPct)) category=\(category) noop_eligible=\(noopEligible)")
            }

            // Cursor is composited only on the final drawable.
            // This keeps the persistent back buffer cursor-free and prevents stale
            // cursor pixels from being moved by GPU scroll-region copies.
            ZonvieCore.appLog("[cursor-draw] cursorBlinkState=\(cursorBlinkStateSnapshot) cursorCount=\(currentCursorCount)")
            if cursorBlinkStateSnapshot, currentCursorCount > 0, let cvb = committedCursor.cursorVertexBuffer {
                let cursorRPD = MTLRenderPassDescriptor()
                cursorRPD.colorAttachments[0].texture = drawable.texture
                cursorRPD.colorAttachments[0].loadAction = .load
                cursorRPD.colorAttachments[0].storeAction = .store

                attachGpuPerfSamples(to: cursorRPD, label: "cursor")
                attachGpuStatsSamples(to: cursorRPD, label: "cursor")
                guard let cursorEnc = cmd.makeRenderCommandEncoder(descriptor: cursorRPD) else {
                    // The drawable copy was encoded, but presenting it without
                    // the requested cursor would consume cursor_rev and leave a
                    // visibly incomplete transaction. Submit the already-
                    // encoded back-buffer work only to release driver resources,
                    // then roll the frame state back for a complete retry.
                    let sem = inflightSemaphore
                    let lk = lock
                    cmd.addCompletedHandler { [weak self] _ in
                        lk.lock()
                        self?.completeSurfaceGpuReadLocked(csi)
                        self?.cursorGpuInFlightCount[cci] -= 1
                        lk.unlock()
                        sem.signal()
                    }
                    cmd.commit()
                    gpuSubmitted = true
                    bailWithoutSubmit("cursor encoder creation failed")
                    return
                }
                viewportMetrics.applyViewport(to: cursorEnc)
                cursorEnc.setRenderPipelineState(pipeline!)
                if let tex = atlasTex {
                    cursorEnc.setFragmentTexture(tex, index: 0)
                }
                cursorEnc.setFragmentSamplerState(sampler!, index: 0)

                bindSurfaceScrollOffsets(encoder: cursorEnc, offsets: scrollSnapshot, device: device, scratchBuffer: &committedCursor.cursorScrollOffsetBuffer, scratchCapacity: &committedCursor.cursorScrollOffsetBufferCap)
                bindSurfaceFragmentState(
                    encoder: cursorEnc,
                    viewportMetrics: viewportMetrics,
                    backgroundAlphaBuffer: backgroundAlphaBuffer,
                    cursorBlinkBuffer: cursorBlinkBuffer,
                    cursorBlinkVisible: true,
                    fixedFloatBands: fixedFloatBandsSnapshot,
                    fixedFloatIntervals: fixedFloatIntervalsSnapshot  // mask a scrolling cursor under a fixed float
                )
                var zeroTranslation: Float = 0
                cursorEnc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)
                // The cursor is in its own layer's pixel space, which
                // applyViewport above set to the root layer's.
                bindLayerTransform(
                    encoder: cursorEnc,
                    LayerTransform(
                        originPx: cursorLayerOriginSnapshot,
                        extentPx: simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)
                    )
                )

                cursorEnc.setVertexBuffer(cvb, offset: 0, index: 0)
                cursorEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentCursorCount)
                cursorEnc.endEncoding()
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
            // Capture semaphore and lock directly so the signal fires even
            // if the renderer is deallocated before the GPU finishes.
            let sem = inflightSemaphore
            let lk = lock
            // Wall-time clock at submission, used to compute gpu_wall_us
            // (queue + GPU + present scheduling latency) inside the completion
            // handler. gpu_exec_us comes from Metal's own gpuStart/gpuEndTime.
            let t_gpu_submit: CFAbsoluteTime = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
            // Snapshot per-pass slots + sample buffer + tick scale for the
            // completion handler. The renderer reuses gpuPerfSlots next frame,
            // so a value-typed copy keeps this frame's data alive until resolve.
            // Gated on appLogEnabled so when logging is off the captures are
            // cheap constants instead of array struct copies / ref bumps.
            let logEnabledForCompletion = ZonvieCore.appLogEnabled
            let frameSlots: [GpuPerfSlot] = logEnabledForCompletion ? gpuPerfSlots : []
            let frameFullSlots: [GpuPerfSlotFull] = logEnabledForCompletion ? gpuPerfFullSlots : []
            let frameSampleCount: Int = logEnabledForCompletion ? gpuPerfNextIdx : 0
            let frameSampleBuf: MTLCounterSampleBuffer? = logEnabledForCompletion ? gpuPerfSampleBuffer : nil
            let frameTickNs = gpuTimestampPeriodNs
            let frameStatsSlots: [GpuPerfSlot] = logEnabledForCompletion ? gpuStatsSlots : []
            let frameStatsBuf: MTLCounterSampleBuffer? = logEnabledForCompletion ? gpuStatsSampleBuffer : nil
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
                    // frameSampleCount covers both fragment-only slots and full
                    // (vertex+fragment) slots, allocated contiguously in the
                    // shared sample buffer via gpuPerfNextIdx.
                    if let buf = frameSampleBuf, frameSampleCount > 0,
                       (!frameSlots.isEmpty || !frameFullSlots.isEmpty)
                    {
                        if let data = try? buf.resolveCounterRange(0..<frameSampleCount) {
                            data.withUnsafeBytes { raw in
                                let ts = raw.bindMemory(to: MTLCounterResultTimestamp.self)
                                guard ts.count >= frameSampleCount else { return }
                                var msg = "[perf] gpu_passes"
                                for slot in frameSlots {
                                    let s = ts[slot.startIdx].timestamp
                                    let e = ts[slot.endIdx].timestamp
                                    let ticks = (e >= s) ? Double(e &- s) : 0
                                    let us = ticks * frameTickNs / 1000.0
                                    msg += " \(slot.label)_us=\(String(format: "%.1f", us))"
                                }
                                // Full-stage slots: report fragment_us under
                                // the same `<label>_us=` field so the existing
                                // analyzer keeps working, then emit a separate
                                // [perf] gpu_pass_detail line with the full
                                // vertex/gap/fragment/total breakdown.
                                for slot in frameFullSlots {
                                    let sF = ts[slot.startFIdx].timestamp
                                    let eF = ts[slot.endFIdx].timestamp
                                    let fragTicks = (eF >= sF) ? Double(eF &- sF) : 0
                                    let fragUs = fragTicks * frameTickNs / 1000.0
                                    msg += " \(slot.label)_us=\(String(format: "%.1f", fragUs))"
                                }
                                ZonvieCore.appLogPerf(msg)

                                // Detail for full-stage slots: vertex / vfgap /
                                // fragment / total. vfgap is start_f - end_v —
                                // idle between stages, often dominated by
                                // waiting for the previous pass's tile store.
                                for slot in frameFullSlots {
                                    let sV = ts[slot.startVIdx].timestamp
                                    let eV = ts[slot.endVIdx].timestamp
                                    let sF = ts[slot.startFIdx].timestamp
                                    let eF = ts[slot.endFIdx].timestamp
                                    func usOf(_ a: UInt64, _ b: UInt64) -> Double {
                                        let t = (b >= a) ? Double(b &- a) : 0
                                        return t * frameTickNs / 1000.0
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
                    if let buf = frameStatsBuf, !frameStatsSlots.isEmpty {
                        let total = frameStatsSlots.count * 2
                        if let data = try? buf.resolveCounterRange(0..<total) {
                            data.withUnsafeBytes { raw in
                                let st = raw.bindMemory(to: MTLCounterResultStatistic.self)
                                guard st.count >= total else { return }
                                var msg = "[perf] gpu_overdraw"
                                for slot in frameStatsSlots {
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
            buildCustomShaderPipelines(lib: lib, copyVertexDesc: copyVertexDesc, pixelFormat: pixelFormat)
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

    /// Build a `zonvie_shader_uniforms` value for the current frame.
    ///
    /// `screenResolution` is always the MAIN window's drawable size, so
    /// every view shares one coordinate space — stars and other effects
    /// line up seamlessly across ext-cmdline / ext-popupmenu / extra OS
    /// windows. `windowOffset` is the current view's top-left corner in
    /// the main window's drawable pixels (top-left origin); `windowSize`
    /// is the current view's own drawable size.
    ///
    /// Each caller passes the result inline via `setFragmentBytes`, so
    /// multiple MTKViews animating at 60fps never race on a shared
    /// buffer.
    func makeCustomShaderUniforms(
        screenResolution: CGSize,
        windowOffset: CGPoint,
        windowSize: CGSize,
        timing: ShaderViewTimingState? = nil
    ) -> zonvie_shader_uniforms {
        let state = timing ?? mainShaderTiming
        let now = CACurrentMediaTime()
        if state.startTimeSec == 0 {
            // External views (timing != mainShaderTiming) inherit the
            // main view's iTime origin once main has started so iTime
            // and iTimeCursorChange (which the main path computes
            // against mainShaderTiming.startTimeSec) stay in the same
            // time base across the whole app.
            if state !== mainShaderTiming, mainShaderTiming.startTimeSec != 0 {
                state.startTimeSec = mainShaderTiming.startTimeSec
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
        // Ghostty 1.1+ cursor uniforms. Snapshot together under `lock` —
        // setCursorShaderState() (core/RPC thread) writes these same fields
        // as one unit; reading them individually here could otherwise mix
        // a new rect with a stale color/timestamp for one frame.
        // Already in screen space: evaluateCursorShaderChange folded each
        // endpoint's displacement in when it accepted that endpoint.
        let (cursorCur, cursorPrev, cursorCurColor, cursorPrevColor, cursorChangeTime, cursorGrid): (
            (Float, Float, Float, Float), (Float, Float, Float, Float),
            (Float, Float, Float, Float), (Float, Float, Float, Float), Float, Int64
        ) = {
            lock.lock()
            defer { lock.unlock() }
            return (shaderCursorCurrent, shaderCursorPrevious, shaderCursorCurrentColor, shaderCursorPreviousColor, shaderCursorChangeTime, shaderCursorGridId)
        }()
        // Log the value the shader actually receives, not the one some
        // upstream stage computed — the two came apart once already, when a
        // re-projected rect stayed in the staging slot. Emitted only when it
        // changes, so this stays off the per-frame cost.
        if ZonvieCore.appLogEnabled, cursorCur != lastLoggedShaderCursor {
            lastLoggedShaderCursor = cursorCur
            ZonvieCore.appLog(
                "[shader_cursor] x=\(cursorCur.0) y=\(cursorCur.1) w=\(cursorCur.2) h=\(cursorCur.3) grid=\(cursorGrid)"
            )
        }
        uniforms.iCurrentCursor = cursorCur
        uniforms.iPreviousCursor = cursorPrev
        uniforms.iCurrentCursorColor = cursorCurColor
        uniforms.iPreviousCursorColor = cursorPrevColor
        uniforms.iTimeCursorChange = cursorChangeTime
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

    /// Ghostty 1.1+ cursor uniform update. rect is (x, y, w, h) in
    /// drawable pixels within the shader "screen" universe (main
    /// window's drawable). color is straight RGBA in [0, 1]. No-op
    /// when incoming state matches the current state, so shaders keep
    /// seeing the last real change's iTimeCursorChange.
    /// Whether the cursor rect the shader uniforms carry was measured on this
    /// grid. The rect is shared between the main surface and every external
    /// window — whoever submitted a cursor last owns it — so a surface must
    /// not apply its own scroll displacement to a rect belonging to another
    /// grid.
    func shaderCursorBelongs(toGrid gridId: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shaderCursorGridId == gridId
    }

    /// Stage the cursor state a flush just measured. Published by
    /// `publishCursorShaderState()` when that flush commits — see
    /// `stagedShaderCursor` for why it cannot go straight out.
    func setCursorShaderState(rect: (Float, Float, Float, Float), color: (Float, Float, Float, Float), gridId: Int64) {
        // Called from the vertex-submit path (core/RPC thread), while
        // makeCustomShaderUniforms() reads the published fields from the main
        // thread during draw(in:). Guard with the existing `lock` (already
        // used for other cross-thread snapshots in this class) so a torn
        // rect/color combination is never observed mid-frame.
        lock.lock()
        stagedShaderCursor = (rect: rect, color: color, gridId: gridId)
        lock.unlock()
    }

    /// Re-anchor the shader cursor after the WINDOW that owns it moved.
    ///
    /// Writes through rather than staging: setCursorShaderState only reaches the
    /// uniforms at a commit, and a window drag produces none, so the shader
    /// would keep burning at the pre-move position.
    ///
    /// Translates rather than replaces: the cursor did not move relative to its
    /// text, so rotating previous/current would fire the cursor-move animation
    /// and drag a trail from where the window used to be. Both endpoints shift
    /// by the same delta and iTimeCursorChange is left alone.
    ///
    /// Ignored unless `gridId` still owns the shader cursor, so a window that
    /// no longer has the cursor cannot hijack it by being dragged.
    func reanchorCursorShaderState(rect: (Float, Float, Float, Float), gridId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard shaderCursorGridId == gridId else { return }
        let dx = rect.0 - shaderCursorRawRect.0
        let dy = rect.1 - shaderCursorRawRect.1
        guard dx != 0 || dy != 0 else { return }
        shaderCursorRawRect = rect
        shaderCursorCurrent = (
            shaderCursorCurrent.0 + dx,
            shaderCursorCurrent.1 + dy,
            shaderCursorCurrent.2,
            shaderCursorCurrent.3
        )
        shaderCursorPrevious = (
            shaderCursorPrevious.0 + dx,
            shaderCursorPrevious.1 + dy,
            shaderCursorPrevious.2,
            shaderCursorPrevious.3
        )
        // A cursor update that arrived during the drag is still waiting for a
        // commit; move it too, or the commit would undo this re-anchor.
        if let staged = stagedShaderCursor, staged.gridId == gridId {
            stagedShaderCursor = (rect: rect, color: staged.color, gridId: staged.gridId)
        }
    }

    /// Hand the staged cursor state to the shader uniforms, together with the
    /// vertices it describes. Called from every surface's commit; a flush that
    /// aborts instead drops it in `beginFlush`.
    func publishCursorShaderState() {
        lock.lock()
        defer { lock.unlock() }
        publishCursorShaderStateLocked()
    }

    /// Caller must hold `lock` (commitFlush publishes inside its own scope).
    private func publishCursorShaderStateLocked() {
        guard let staged = stagedShaderCursor else { return }
        stagedShaderCursor = nil
        shaderCursorRawRect = staged.rect
        shaderCursorRawColor = staged.color
        shaderCursorGridId = staged.gridId
    }

    /// Fold this frame's displacement of the cursor's grid into the shader's
    /// cursor endpoints, rotating them only when the cursor actually moved ON
    /// SCREEN.
    ///
    /// Called from each surface's pre-draw, where the displacement it is about
    /// to render with is known. The measured rect alone cannot answer "did the
    /// cursor move": a scroll step shifts it a whole row while the compensating
    /// offset holds it still on the glass, and rotating there restarts the trail
    /// every step so it never plays out.
    ///
    /// - Parameter scrollOffsetPx: displacement of the cursor's grid for this
    ///   frame, or nil when the caller does not own that grid's cursor.
    func evaluateCursorShaderChange(scrollOffsetPx: Float?) {
        guard let scrollOffsetPx else { return }
        lock.lock()
        defer { lock.unlock() }
        evaluateCursorShaderChangeLocked(scrollOffsetPx: scrollOffsetPx)
    }

    /// Caller must hold `lock` (updateScrollOffsets evaluates inside its own
    /// scope).
    private func evaluateCursorShaderChangeLocked(scrollOffsetPx: Float) {
        let rect = (
            shaderCursorRawRect.0,
            shaderCursorRawRect.1 + scrollOffsetPx,
            shaderCursorRawRect.2,
            shaderCursorRawRect.3
        )
        let color = shaderCursorRawColor
        let eps = Self.shaderCursorMoveEpsilonPx
        let sameRect =
            abs(rect.0 - shaderCursorCurrent.0) < eps &&
            abs(rect.1 - shaderCursorCurrent.1) < eps &&
            abs(rect.2 - shaderCursorCurrent.2) < eps &&
            abs(rect.3 - shaderCursorCurrent.3) < eps
        let sameColor =
            color.0 == shaderCursorCurrentColor.0 &&
            color.1 == shaderCursorCurrentColor.1 &&
            color.2 == shaderCursorCurrentColor.2 &&
            color.3 == shaderCursorCurrentColor.3
        if sameRect && sameColor {
            // Keep the endpoint exact even when the move was below the
            // threshold, so a slow ease does not accumulate drift.
            shaderCursorCurrent = rect
            return
        }

        shaderCursorPrevious = shaderCursorCurrent
        shaderCursorPreviousColor = shaderCursorCurrentColor
        shaderCursorCurrent = rect
        shaderCursorCurrentColor = color
        // The cursor change timestamp is reported in the same time
        // base as the main view's iTime (mainShaderTiming.startTimeSec).
        // External views use the same base because they share the
        // shared start when they read iTime (see makeCustomShaderUniforms).
        if mainShaderTiming.startTimeSec != 0 {
            shaderCursorChangeTime = Float(CACurrentMediaTime() - mainShaderTiming.startTimeSec)
        } else {
            shaderCursorChangeTime = 0
        }
    }

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
        for path in config.paths {
            let expanded = (path as NSString).expandingTildeInPath
            if let pipeline = CustomShaderPipeline.load(
                device: device,
                library: lib,
                vsCustomPost: vsCustomPost,
                copyVertexDescriptor: copyVertexDesc,
                sourcePath: expanded,
                pixelFormat: pixelFormat,
                preserveAlpha: config.preserveAlpha
            ) {
                customShaderPipelines.append(pipeline)
                if pipeline.needsAnimation {
                    anyCustomShaderNeedsAnimation = true
                }
            }
        }
        // Decorated variant: always opaque (preserve_alpha OFF). Only a
        // separate compile is needed when the main set is NOT already opaque;
        // otherwise alias it to avoid a redundant compile.
        if config.preserveAlpha {
            for path in config.paths {
                let expanded = (path as NSString).expandingTildeInPath
                if let pipeline = CustomShaderPipeline.load(
                    device: device,
                    library: lib,
                    vsCustomPost: vsCustomPost,
                    copyVertexDescriptor: copyVertexDesc,
                    sourcePath: expanded,
                    pixelFormat: pixelFormat,
                    preserveAlpha: false
                ) {
                    customShaderPipelinesDecorated.append(pipeline)
                }
            }
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
                bs.mainVertexBuffer = device.makeBuffer(length: nextCap, options: .storageModeShared)
                if bs.mainVertexBuffer == nil {
                    bs.mainVertexBufferCap = 0
                    flushFailed = true
                }
            }
        }
    }

    /// Ensure cursor vertex buffer in the specified buffer set has sufficient capacity.
    /// If the buffer is shared with the committed set (COW), detach by reusing
    /// the pool buffer saved in beginFlush, or allocate new if pool is insufficient.
    private func ensureCursorBufferInSet(_ setIdx: Int, vertexCount: Int) {
        let vc = max(0, vertexCount)
        guard let needed = surfaceSafeNeededBytes(vertexCount: vc) else {
            flushFailed = true
            return
        }

        // Cursor buffer is NOT COW-shared (beginFlush copies data into dst's own buffer).
        // Only allocate if nil or too small.
        let bs = bufferSets[setIdx]
        let needsNew = bs.cursorVertexBuffer == nil || needed > bs.cursorVertexBufferCap

        if needsNew {
            guard let nextCap = surfaceGrowCapacity(current: bs.cursorVertexBufferCap, needed: max(1, needed)) else {
                flushFailed = true
                return
            }
            bs.cursorVertexBufferCap = nextCap
            bs.cursorVertexBuffer = device.makeBuffer(length: nextCap, options: .storageModeShared)
            if bs.cursorVertexBuffer == nil {
                bs.cursorVertexBufferCap = 0
                flushFailed = true
            }
        }
    }

    private func drawBackgroundClearBand(
        _ encoder: MTLRenderCommandEncoder,
        clearBand: (clearTopPx: Int, clearBottomPx: Int),
        xRangePx: (leftPx: Float, rightPx: Float),
        drawableHeight: Float,
        bgRGB: UInt32,
        gridId: Int64
    ) {
        let top = max(0, clearBand.clearTopPx)
        let bottom = max(top, clearBand.clearBottomPx)
        guard bottom > top else { return }
        let r = Float((bgRGB >> 16) & 0xFF) / 255.0
        let g = Float((bgRGB >> 8) & 0xFF) / 255.0
        let b = Float(bgRGB & 0xFF) / 255.0
        let color = simd_float4(r, g, b, 1.0)
        // Pixels in whatever space the bound layer transform maps: the surface
        // for a root-grid band, the layer's own rect for a layer's band. The
        // band lands exactly where the NDC form used to.
        _ = drawableHeight
        let x0 = xRangePx.leftPx
        let x1 = xRangePx.rightPx
        guard x1 > x0 else { return }
        let y0 = Float(top)
        let y1 = Float(bottom)
        // The vertex stage binary-searches scrollOffsets by grid_id, so a band
        // must carry the id of the grid it covers: tagging a layer's band with
        // the root's id would move it by the root's scroll offset.
        let tl = Vertex(position: simd_float2(x0, y0), texCoord: simd_float2(-1, -1), color: color, grid_id: gridId, deco_flags: 0, deco_phase: 0)
        let tr = Vertex(position: simd_float2(x1, y0), texCoord: simd_float2(-1, -1), color: color, grid_id: gridId, deco_flags: 0, deco_phase: 0)
        let bl = Vertex(position: simd_float2(x0, y1), texCoord: simd_float2(-1, -1), color: color, grid_id: gridId, deco_flags: 0, deco_phase: 0)
        let br = Vertex(position: simd_float2(x1, y1), texCoord: simd_float2(-1, -1), color: color, grid_id: gridId, deco_flags: 0, deco_phase: 0)
        // Stack-allocated scratch buffer via withUnsafeTemporaryAllocation
        // (no heap) instead of building a fresh [Vertex] array every scroll frame.
        withUnsafeTemporaryAllocation(of: Vertex.self, capacity: 6) { buffer in
            buffer[0] = tl
            buffer[1] = bl
            buffer[2] = tr
            buffer[3] = tr
            buffer[4] = bl
            buffer[5] = br
            encoder.setVertexBytes(buffer.baseAddress!, length: MemoryLayout<Vertex>.stride * 6, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
        guard cs.rowState.usingRowBuffers else {
            ZonvieCore.appLog("[retain] skip grid=\(gridId) rowsDelta=\(rowsDelta) no row buffers")
            return
        }

        // A step is routinely more than one row (a whole wheel event's
        // 'mousescroll' worth, coalesced), but the retention holds only
        // `depthRows` — the offset is clamped to the same reach — so keep the
        // rows adjacent to the edge the block left through.
        let depth = retention.depthRows
        guard let plan = ScrollRetention.plan(
            rowStart: bounds.top,
            rowEnd: bounds.bottomEx,
            rowsDelta: rowsDelta,
            depth: depth
        ) else {
            ZonvieCore.appLog(
                "[retain] skip grid=\(gridId) rowsDelta=\(rowsDelta) no plan (top=\(bounds.top) bottomEx=\(bounds.bottomEx) depth=\(depth))"
            )
            return
        }

        retention.beginStep(gridId: gridId, rowsDelta: rowsDelta, pivotTargetRow: plan.pivotTargetRow)
        // Claim the step so the row-shift capture stands down for this grid.
        lock.lock()
        bracketStagedGrids.insert(gridId)
        lock.unlock()

        for i in 0..<plan.count {
            let row = ScrollRetention.planRow(plan, i, rowsDelta: rowsDelta)
            captureOneRetainedRow(
                cs: cs,
                gridId: gridId,
                readRow: row + sourceShift,
                targetRow: row - rowsDelta
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

        // Read before locking: the accessor takes `lock` itself, which is not
        // recursive.
        let capturedCellHeightPx = cellHeightPx
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
    private func captureLayerScrollStep(
        gridId: Int64,
        sets: [SurfaceBufferSet],
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int
    ) {
        guard Self.smoothScrollEnabled else { return }
        lock.lock()
        // The grid_scroll notification is dispatched earlier in this bracket and
        // may already have opened a step for this grid; a second one would shift
        // its rows twice. Standing down must not mean leaving the function: the
        // seed below is this path's alone.
        var stepped = bracketStagedGrids.contains(gridId)
        lock.unlock()

        let cs = sets[flushSourceSetIndex]
        if !stepped, cs.rowState.usingRowBuffers,
           let plan = ScrollRetention.plan(
               rowStart: rowStart,
               rowEnd: rowEnd,
               rowsDelta: rowsDelta,
               depth: retention.depthRows
           ) {
            retention.beginStep(gridId: gridId, rowsDelta: rowsDelta, pivotTargetRow: plan.pivotTargetRow)
            lock.lock()
            bracketStagedGrids.insert(gridId)
            lock.unlock()
            for i in 0..<plan.count {
                let row = ScrollRetention.planRow(plan, i, rowsDelta: rowsDelta)
                captureOneRetainedRow(cs: cs, gridId: gridId, readRow: row, targetRow: row - rowsDelta)
            }
            stepped = true
        }
        // commitFlush publishes the seeds only when a step was staged, so a
        // step that could not be opened would have its seed dropped there.
        guard stepped, abs(rowsDelta) == 1 else { return }
        lock.lock()
        stagedSmoothScrollSeeds.append((gridId: gridId, rowsDelta: rowsDelta))
        lock.unlock()
        if ZonvieCore.appLogEnabled {
            ZonvieCore.appLog(
                "[smooth_scroll_seed] gridId=\(gridId) rowsDelta=\(rowsDelta)"
            )
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

    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32, totalRows: Int = 0, totalCols: Int = 0) {
        guard isInFlush else {
            ZonvieCore.appLog("[WARNING] submitVerticesRowRaw called outside flush bracket")
            return
        }
        let updateMain = (flags & UInt32(ZONVIE_VERT_UPDATE_MAIN)) != 0
        let updateCursor = (flags & UInt32(ZONVIE_VERT_UPDATE_CURSOR)) != 0
        if updateCursor && !updateMain {
            guard count != 0 || pendingCursorLayerGridId == 1 else {
                ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_ignore surface=1 grid=1 owner=\(pendingCursorLayerGridId) reason=empty_nonowner")
                return
            }
            pendingCursorLayerGridId = 1
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
            || (totalRows > 0 && totalRows != sourceSet.knownTotalRows)
            || (totalCols > 0 && totalCols != sourceSet.knownTotalCols)
        // Allocate synchronously: the async pre-provisioning gate this replaced
        // does not converge under sustained scroll (same reasoning as
        // ExternalGridView.applyRowScroll). requirePreparedRowCapacity below
        // only records a real allocation failure for the async recovery path.
        let submitted = submitSurfaceRowVertices(
            target: bufferSets[writeSetIndex],
            sourceSet: sourceSet,
            device: device,
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
