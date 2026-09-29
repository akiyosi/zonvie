import AppKit
import Metal
import MetalKit
import simd

/// Compute the screen-space parameters (custom shader uniforms) for an
/// external MTKView relative to the main terminal view. `screenResolution`
/// is the main MTKView's drawable size in pixels; `windowOffset` is the
/// external view's top-left corner in that drawable-pixel coordinate space
/// (top-left origin). Falls back to the external view's own drawable when
/// the main window is unavailable, so shaders still render sensibly
/// during early startup.
fileprivate func screenSpaceParameters(
    mainView: MetalTerminalView?,
    selfView: MTKView
) -> (screenResolution: CGSize, windowOffset: CGPoint) {
    let selfDrawable = selfView.drawableSize
    guard let mainView = mainView,
          let mainWin = mainView.window,
          let selfWin = selfView.window else {
        return (selfDrawable, .zero)
    }
    // The main drawable's scale: the offset is in its pixel space, beside
    // iResolution, even when this window sits on a display of another scale.
    let scale = mainWin.backingScaleFactor
    // Convert each MTKView's local bounds -> screen coords (bottom-left
    // origin, in points).
    let selfInWindow = selfView.convert(selfView.bounds, to: nil)
    let mainInWindow = mainView.convert(mainView.bounds, to: nil)
    let selfOnScreen = selfWin.convertToScreen(selfInWindow)
    let mainOnScreen = mainWin.convertToScreen(mainInWindow)
    // NSWindow uses bottom-left screen origin. The TOP of each MTKView is
    // origin.y + height in those coords. Y in drawable pixels uses a
    // top-left origin, so we subtract to get the external view's top-left
    // offset from the main view's top-left in top-left coords.
    let mainTopY = mainOnScreen.origin.y + mainOnScreen.height
    let selfTopY = selfOnScreen.origin.y + selfOnScreen.height
    let dxPts = selfOnScreen.origin.x - mainOnScreen.origin.x
    let dyPts = mainTopY - selfTopY
    let offsetPx = CGPoint(x: dxPts * scale, y: dyPts * scale)
    return (mainView.drawableSize, offsetPx)
}

/// A Metal view for rendering external Neovim grids (from win_external_pos).
/// Shares the glyph atlas with the main renderer for consistent text rendering.
final class ExternalGridView: GridInputView, MTKViewDelegate {
    private let mtlDevice: MTLDevice
    private let queue: MTLCommandQueue

    /// The main window's view, whose geometry the screen-space shader
    /// uniforms measure from and whose redraw follows a window move.
    weak var mainTerminalView: MetalTerminalView?

    /// This surface's background, in the shape GridSurfaceRenderer keeps it:
    /// the 8-bit colour the row bands paint with, and the clear colour built
    /// from it where it is used. This surface used to keep the built colour
    /// instead and recover the RGB from it four times per draw.
    ///
    /// The alpha is stored rather than derived because the app picks a
    /// different one for a decorated surface's margin; the main renderer takes
    /// its own from `blurEnabled`.
    private(set) var surfaceBgRGB: UInt32 = 0
    private(set) var surfaceClearAlpha: Double = 1.0

    func setGridBackground(rgb: UInt32, clearAlpha: Double) {
        // The colour arrives from the main queue after the commit whose rows
        // it describes, and those rows paint no default background — the core
        // leaves that to the clear once the surface hosts a layer. So a change
        // has to clear the whole surface again, or the first frame's colour
        // (black, before any was known) stays under every row.
        lock.lock()
        let changed = surfaceBgRGB != rgb || surfaceClearAlpha != clearAlpha
        surfaceBgRGB = rgb
        surfaceClearAlpha = clearAlpha
        if changed { pendingLayoutDamage = true }
        lock.unlock()
        if changed { requestRedraw() }
    }

    /// Track if we've presented at least once (for loadAction optimization)
    private var hasPresentedOnce = false
    /// Unlike `hasPresentedOnce`, never reset by a font change, resize or bail:
    /// the visibility gate asks whether this window has been on screen, not
    /// whether the back buffer is valid. Cleared only on a move to a new window.
    private var hasEverPresented = false

    /// The GPU objects every surface shares, handed in at construction. Before
    /// this, these were copied in one by one and the rest were reached through
    /// `mainTerminalView?.renderer`, which made this surface unable to draw
    /// without the main window's renderer alive.
    let shared: SharedRenderResources

    /// Everything this surface shares between the core thread, the main thread
    /// and the draw: the committed/write/free row sets, the cursor slots, the
    /// commit revision, the committed grid size, pending dirty rows, pending
    /// scroll and layout damage, the scroll input the main thread arms, and
    /// the scroll-offset publication with the committed font generation.
    ///
    /// One lock, as the main surface has. It was three, which meant an
    /// ordering invariant to state and to keep true — and a scan that reads
    /// lock regions by brace scope (`tmp/lockmerge_check.py`) found a nesting
    /// the written invariant did not mention: `notifyFontChanged` held the
    /// offset lock across `stageFontChanged`, which took the buffer lock.
    /// Merging removes the invariant rather than restating it.
    ///
    /// The split bought nothing to lose. Measured under a sustained 30 Hz
    /// scroll, the offset lock was taken 1,556 times and found held **0**, the
    /// buffer lock 4,408 times and held 9, the scroll lock 2,272 times and
    /// held 1 — against the main surface's single lock at 19,764 takes and 49
    /// held, 0.248%.
    private let lock = NSLock()


    // MARK: - Triple Buffering (same pattern as GridSurfaceRenderer)
    // Three buffer sets: one committed (being drawn), one write (being filled),
    // one free. gpuInFlightCount prevents beginFlush from picking a set that
    // the GPU is still reading.
    /// Vertex storage for every grid this surface draws, keyed by grid id. An
    /// external surface draws its root grid today and gains anchored floats
    /// once the core emits multi-layer layouts.
    let gridBuffers = GridBufferRegistry()
    /// The root grid's sets. SurfaceBufferSet is a class, so mutating through
    /// this computed property mutates the registry's own objects.
    private var bufferSets: [SurfaceBufferSet] { gridBuffers.sets(for: gridId) }

    /// Stage this surface's layer list; promoted when the flush commits.
    func setPendingSurfaceLayers(_ layers: [SurfaceLayer]) {
        lock.lock()
        pendingSurfaceLayers = layers
        // Placement alone is content: it must rotate and schedule a paint
        // even when this flush does not submit any rows.
        flushHadContent = true
        lock.unlock()
        if let owner = cursorOwner.staged,
           !layers.contains(where: { $0.gridId == owner }) {
            submitLayerCursor(gridId: owner, ptr: nil, count: 0)
            cursorOwner.stage(gridId)
        }
    }

    /// Release a destroyed grid's vertex storage.
    func releaseGridBuffers(gridId released: Int64) {
        lock.lock()
        gridBuffers.release(gridId: released)
        lock.unlock()
    }

    private var pendingSurfaceLayers: [SurfaceLayer]?
    private var committedSurfaceLayers: [SurfaceLayer] = []
    private var pendingLayoutDamage = false
    private var layerGridIdScratch: [Int64] = []
    /// Per-frame snapshot taken under `lock`, reused across frames.
    /// This surface's own grid is not a layer here; the main renderer's entry 0
    /// is its root.
    private var layerSnapshot: [SurfaceLayerFrame] = []
    /// Rows each hosted layer's committed placement has travelled upwards
    /// since this surface began, in the same units and direction as
    /// on_grid_scroll's rowsDelta. The float ledger's other half; the main
    /// renderer keeps the identical map for the layers IT places, and the debt
    /// it computes was simply absent for a float an external window hosts.
    /// Written only under `lock` at commit; read by the draw's snapshot.
    private var layerPlacementRowsUp: [Int64: Int] = [:]
    /// The counter above as this frame's layer snapshot saw it, and the zero
    /// the ledger's two halves are compared against. Both are drawn-thread
    /// state, filled under `lock` alongside `layerSnapshot`.
    private var placementRowsUpSnapshot: [Int64: Int] = [:]
    private var floatDebtLedger = SurfaceFloatDebtLedger()

    /// Clear what the bracket staged and mark it closed. Called with `lock`
    /// held, from both arms of commitFlush and from cancelFlush: what "closed"
    /// means must not drift between them.
    private func closeFlushBracketLocked() {
        flushChangedRows.removeAll()
        flushGeneratedRows.removeAll()
        flushHasStructuralRowChange = false
        rowWritePrepared = false
        writeSetIndex = -1
        bracketOpen = false
    }

    /// Rows of the anchor's compensation this hosted float is carrying that
    /// its own placement has not performed — the same ledger the main surface
    /// applies in GridSurfaceRenderer.applyFloatScrollDebt, computed against
    /// the placement THIS frame draws.
    ///
    /// The anchor half comes from the main view, which owns the landed-rows
    /// counter and moves it in the same step as the compensation it belongs
    /// to; the placement half is this surface's own, latched with the layer
    /// snapshot. Both counters run from whenever their grid appeared, so the
    /// first frame a float is seen following fixes their common zero.
    ///
    /// `seedingBaseline` is false for the hit test: the DRAW defines the zero,
    /// being the frame that first shows the float following. A press arriving
    /// before that frame would otherwise fix the zero against a placement
    /// snapshot no draw has filled, and the draw would inherit it. The hit test
    /// also reads the LIVE placement counter: it pairs the debt with the live
    /// committed layer origin, which commitFlush moves together with that
    /// counter, not with the one this surface's last draw latched.
    private func hostedFloatDebtPx(
        gridId: Int64,
        anchorGridId: Int64,
        cellHeightPx: Float,
        seedingBaseline: Bool = true
    ) -> Float {
        guard cellHeightPx > 0, let scroll = core?.scrollModel else { return 0 }
        // Taken before `lock`: it takes the scroll model's own lock, and
        // neither is held while taking the other.
        let anchorRowsUp = scroll.anchorLandedRowsUpSnapshot(anchorGridId)
        // Both ledgers under `lock`: commitFlush prunes them on the core
        // thread under it, and this runs on the main thread. Unlocked, the two
        // mutated one Swift dictionary at once.
        lock.lock()
        let rows = floatDebtLedger.rows(
            gridId: gridId,
            anchorGridId: anchorGridId,
            anchorRowsUp: anchorRowsUp,
            placementRowsUp: (seedingBaseline ? placementRowsUpSnapshot[gridId] : layerPlacementRowsUp[gridId]) ?? 0,
            seeding: seedingBaseline,
            surfaceId: self.gridId,
            log: ZonvieCore.appLogEnabled ? { ZonvieCore.appLog($0) } : nil
        )
        lock.unlock()
        // The displacement the debt adds to the drawn origin, +y down. A float
        // whose placement ran `rows` ahead of its anchor (rows < 0 when it
        // moved up first) is held where it was drawn by moving it back down,
        // so the sign is the debt's opposite — as on the main surface, where
        // the same rows are added to an NDC offset that is negated against
        // pixels. This returned `+rows`, which doubled the step instead.
        return -Float(rows) * cellHeightPx
    }

    /// The same debt, read with `lock` already held and the anchor's count
    /// taken before it. Never seeds: the draw's body call defines the zero.
    private func hostedFloatDebtPxLocked(gridId: Int64, anchorRowsUp: Int, cellHeightPx: Float) -> Float {
        guard cellHeightPx > 0 else { return 0 }
        let rows = floatDebtLedger.rows(
            gridId: gridId,
            anchorGridId: self.gridId,
            anchorRowsUp: anchorRowsUp,
            placementRowsUp: placementRowsUpSnapshot[gridId] ?? 0,
            seeding: false,
            surfaceId: self.gridId,
            log: nil
        )
        return -Float(rows) * cellHeightPx
    }

    /// Whether a hosted layer moves bodily with this window's root scroll.
    /// Only a float anchored to the root: one anchored to another float would
    /// take the root's offset while its debt was kept against a grid that
    /// never scrolls, and drift. The main surface refuses the same case.
    private func followsRootScroll(anchorGrid: Int64, followsScroll: Bool) -> Bool {
        followsScroll && anchorGrid == gridId
    }

    /// Where a hosted grid is drawn this frame. A grid scrolled in its own
    /// right (`ownOffset`) eases inside its own frame and keeps its origin; a
    /// follower with no offset of its own moves bodily with the root, less the
    /// rows its own placement has already travelled (the float ledger's debt,
    /// as the main renderer applies it). Without the debt the float is handed
    /// the anchor's whole compensation on top of a placement that moved with
    /// it, and drifts from its anchor for the length of the scroll.
    private func hostedDrawOriginPx(
        originPx: simd_float2,
        gridId layerGridId: Int64,
        anchorGrid: Int64,
        followsScroll: Bool,
        ownOffset: GridSurfaceRenderer.ScrollOffset?,
        rootOffset: GridSurfaceRenderer.ScrollOffset?,
        viewportHeightPx: Float,
        cellHeightPx: Float
    ) -> simd_float2 {
        guard ownOffset == nil, followsRootScroll(anchorGrid: anchorGrid, followsScroll: followsScroll),
              let rootOffset else { return originPx }
        // The shared helper also refuses a non-finite offset or a zero
        // viewport; the cursor's result reaches `Int(... .rounded(.down))`,
        // where a NaN traps.
        var origin = displacedLayerOriginPx(originPx: originPx, offset: rootOffset, viewportHeightPx: viewportHeightPx)
        origin.y += hostedFloatDebtPx(gridId: layerGridId, anchorGridId: anchorGrid, cellHeightPx: cellHeightPx)
        return origin
    }

    /// This surface's fixed-float mask, the same one the main renderer keeps.
    /// Built in draw() from the committed layer snapshot, so it needs no lock
    /// of its own; rebuilt only when the rectangles change.
    private let fixedFloatMask = SurfaceFixedFloatMask()
    private var fixedFloatRectsScratch: [GridSurfaceRenderer.FixedFloatRect] = []
    /// Shared with GridSurfaceRenderer. Starts nil — nothing staged yet — and
    /// a nil owner owns nothing, which is what makes a clear from a grid that
    /// is not the owner get dropped before the first cursor arrives.
    private var cursorOwner = SurfaceCursorOwner(initial: nil)
    var renderTraceFlushId: UInt64 = 0 // Core callback thread only.

    func submitLayerRow(gridId id: Int64, rowStart: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, totalRows: Int, totalCols: Int) {
        guard isInFlush, id != gridId else { return }
        guard prepareRowWriteState() else { return }
        let sets = gridBuffers.sets(for: id)
        // Match root rows: reuse buffers, then grow synchronously if needed.
        // Deferring ordinary growth aborts the whole flush into retry backoff.
        let submitted = submitSurfaceRowVertices(
            target: sets[writeSetIndex], sourceSet: sets[flushSourceSetIndex],
            device: mtlDevice, rowStart: rowStart,
            ptr: ptr.map(UnsafeRawPointer.init), count: count,
            maxRowBuffers: maxRowBuffers, totalRows: totalRows, totalCols: totalCols,
            inflightRowBuffers: { slot in
                self.lock.lock()
                defer { self.lock.unlock() }
                return surfaceInflightRowBuffers(sets: sets, gpuInFlightCount: self.gpuInFlightCount, slot: slot)
            }
        )
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=row_staged surface=\(gridId) grid=\(id) row=\(rowStart) vertices=\(count) accepted=\(submitted)")
        if !submitted { flushFailed = true }
        flushHadContent = true
        markHostedDamage(gridId: id, rowStart: rowStart, rowEnd: rowStart + 1)
    }

    private func markHostedDamage(gridId id: Int64, rowStart: Int, rowEnd: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let layer = (pendingSurfaceLayers ?? committedSurfaceLayers).first(where: { $0.gridId == id }) else { return }
        let height = max(1, Float(shared.cellHeightPx).rounded(.up))
        // Include the adjacent rows for glyph ink crossing a cell boundary.
        let first = max(0, Int(floor(layer.originPx.y / height)) + rowStart - 1)
        let end = min(Int(gridRows), Int(ceil(layer.originPx.y / height)) + rowEnd + 1)
        if first < end { flushDirtyRows.insert(integersIn: first..<end) }
    }

    /// `rootRow` is the root grid's cursor row; -1 for a hosted layer.
    func submitLayerCursor(gridId id: Int64, ptr: UnsafePointer<zonvie_vertex>?, count: Int, rootRow: Int = -1) {
        guard isInFlush else { return }
        // Clearing another grid must not erase this surface's current cursor.
        guard cursorOwner.admit(id, count: count, rootRow: rootRow) else {
            ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_ignore surface=\(gridId) grid=\(id) owner=\(cursorOwner.staged ?? 0) reason=empty_nonowner")
            return
        }
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_route surface=\(gridId) grid=\(id) vertices=\(count)")
        writeBracketCursorVertices(ptr: ptr, count: count)
        flushHadContent = true
        // The surface's own cursor path forwards its rect to the shared cursor
        // shader state; a layer's cursor is the same surface's one cursor and
        // owes the same forward, or the effect stays where the cursor was
        // before it entered the float. Nothing is held here, and the projection
        // adds this layer's origin (see republishCursorShaderState).
        if count > 0, let ptr {
            forwardExternalCursorToMainShader(ptr: ptr, count: count, cursorGridId: id)
        } else {
            // The cursor left this grid: stop republishing its rect on window
            // moves, or this view would keep overwriting whichever surface
            // now owns the cursor.
            stagedForwardedCursor = ForwardedCursor()
        }
    }

    func applyLayerRowScroll(gridId id: Int64, rowStart: Int, rowEnd: Int, rowsDelta: Int, totalRows: Int, totalCols: Int) {
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=row_shift surface=\(gridId) grid=\(id) start=\(rowStart) end=\(rowEnd) delta=\(rowsDelta)")
        guard rowsDelta != 0 else { return }
        // No capacity pre-check: shift hints precede the rows that grow a
        // layer, and remapSurfaceRowSlots grows the storage itself.
        guard isInFlush, prepareRowWriteState(),
              let sets = gridBuffers.existingSets(for: id),
              rowStart >= 0, rowEnd > rowStart else {
            flushFailed = true
            return
        }
        // Before the remap, while the source set still holds the on-screen rows
        // — the same ordering GridSurfaceRenderer.applyLayerRowScroll keeps.
        captureLayerScrollStep(
            gridId: id,
            sets: sets,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta
        )
        remapSurfaceRowSlots(bufferSet: sets[writeSetIndex], rowStart: rowStart, rowEnd: rowEnd,
                            rowsDelta: rowsDelta, totalRows: totalRows, totalCols: totalCols,
                            maxRowBuffers: maxRowBuffers)
        flushHadContent = true
        markHostedDamage(gridId: id, rowStart: rowStart, rowEnd: rowEnd)
    }
    private var writeSetIndex: Int = -1           // Main thread only (during flush)
    /// Whether this bracket has acquired `writeSetIndex`. A bracket that writes
    /// no rows never does, and commits without rotating the row triple.
    private var rowWritePrepared: Bool = false
    private var flushSourceSetIndex: Int = 0      // Main thread only (during flush)
    private var committedSetIndex: Int = 0        // Protected by lock
    private var gpuInFlightCount: [Int] = [0, 0, 0] // Protected by lock
    private var rowStorageRetirement = SurfaceRowStorageRetirementState() // Protected by lock
    private var isInFlush: Bool = false           // Flush bracket thread only
    // Set (core thread) when a vertex/row buffer allocation fails during
    // this flush bracket. Consumed by ZonvieCore's on_flush_end via
    // consumeFlushFailed(), which cancels the bracket instead of committing
    // it and calls zonvie_core_abort_flush, then schedules a retry when the
    // core reports the flush retryable (mirrors
    // GridSurfaceRenderer.flushFailed).
    private(set) var flushFailed: Bool = false    // Flush bracket thread only
    private let rowSync = SurfaceRowSyncLedger()
    private let flushChangedRows = SparseRowSet(rowLimit: surfaceMaxRowBuffers, preparedRows: surfaceMaxRowBuffers)
    // Rows regenerated after the most recent font-generation transition in
    // this bracket. A commit may advance its set's font generation only when
    // every logical row was regenerated; cursor-only and partial commits keep
    // the older generation and are suppressed by the draw-generation gate.
    private let flushGeneratedRows = SparseRowSet(rowLimit: surfaceMaxRowBuffers, preparedRows: surfaceMaxRowBuffers)
    private var flushFontGeneration: UInt64 = 0
    private var flushGeneratedTotalRows: Int = 0
    private var flushGeneratedTotalCols: Int = 0
    private var flushHasStructuralRowChange = false
    // GridSurfaceRenderer carries a deliberately parallel ledger and
    // provisioning pass. The pure parts already live as shared free functions
    // in MetalTypes.swift, which take the lock and a `lockHeld` flag so two
    // surfaces can share code without sharing a lock; what is left is each
    // class's adapter. The lock COUNT differs for one reason: this class arms
    // scroll state from the main thread mid-gesture (`lock`)
    // and publishes eased offsets outside the bracket (`lock`), and a
    // core-thread bracket may block neither. Everything else — retention
    // included — is under the same lock as the vertex publish on both
    // surfaces. Touching the provisioning path itself: b83ff29 and 4b1ad75 are
    // the same mistake twice, a capacity gate that deferred allocation and
    // raced the per-flush row remap. Audit 2026-08-25, finding 037.
    // Fixed-size capacity ledger. The core callback only raises entries;
    // ZonvieCore's retry worker provisions metadata and MTLBuffers after the
    // bracket closes, before retrying the core flush.
    private let rowCapacity = SurfaceRowCapacityLedger(maxRowBuffers: surfaceMaxRowBuffers)

    /// Read and clear flushFailed. Called once per flush from on_flush_end.
    func consumeFlushFailed() -> Bool {
        let v = flushFailed
        flushFailed = false
        return v
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

    /// Called from the flush-retry queue before it acquires core grid_mu.
    func provisionPendingRowCapacity() -> SurfaceRowProvisionStatus {
        provisionSurfaceRowCapacity(
            ledger: rowCapacity,
            lock: lock,
            bufferSets: bufferSets,
            device: mtlDevice,
            maxRowBuffers: maxRowBuffers,
            logLabel: "ExternalGridView:\(gridId)",
            isBusyLocked: { bracketOpen || gpuInFlightCount.contains(where: { $0 != 0 }) },
            busyLogDetailLocked: { "bracketOpen=\(bracketOpen) gpuInFlight=\(gpuInFlightCount)" }
        )
    }

    /// Same-slot buffers of the sets currently GPU in-flight, for the COW
    /// detach alias guard (see surfaceInflightRowBuffers).
    private func inflightRowBuffers(atSlot slot: Int) -> (MTLBuffer?, MTLBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        return inflightRowBuffersLocked(atSlot: slot)
    }

    /// Lock-free variant for callers already holding lock
    /// (NSLock is non-recursive — re-locking would deadlock the main thread).
    private func inflightRowBuffersLocked(atSlot slot: Int) -> (MTLBuffer?, MTLBuffer?) {
        surfaceInflightRowBuffers(sets: bufferSets, gpuInFlightCount: gpuInFlightCount, slot: slot)
    }
    private var flushHadContent: Bool = false     // True if vertices were submitted during this flush
    private var commitRevision: UInt64 = 0        // Protected by lock
    private var lastCommitTime: UInt64 = 0        // Protected by lock — mach_absolute_time of last visual commit
    private var lastDrawnRevision: UInt64 = 0     // Draw only
    /// Revision whose guard band already ran to its deadline without a commit
    /// arriving. Draw only.
    private var guardBandTimedOutRevision: UInt64 = .max
    /// Shared with GridSurfaceRenderer. This surface measures in GRID CELLS:
    /// its window is sized to the grid, so the viewport comes from the row and
    /// column counts. Width is columns, height is rows.
    /// Protected by `lock`.
    private var committedExtent = SurfaceCommittedExtent()
    // GPU back-pressure: one in-flight command buffer, as on the main surface.
    // The row and cursor rings hold three sets: two frames in flight on two
    // different sets left the committed one as the only other, so a flush
    // found no set to write and aborted the whole transaction, main included.
    // Uses non-blocking tryWait since draw() runs on main thread.
    private let inflightSemaphore = DispatchSemaphore(value: 1)
    /// Set by a GPU completion that failed, before it signals the semaphore;
    /// read by the next draw. Protected by lock.
    private var gpuFrameFailed = false
    private let maxRowBuffers = surfaceMaxRowBuffers

    /// Occlusion and window-move observers; see viewDidMoveToWindow.
    private var occlusionObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []

    /// A cursor box forwarded to the shared shader cursor state, in its
    /// grid's own local pixels, so a window move can re-project it.
    private struct ForwardedCursor {
        /// Nil while the cursor is not on this view's grids.
        var px: (minX: Float, maxX: Float, minY: Float, maxY: Float)?
        var color: (Float, Float, Float, Float)?
        /// This surface's root, or a grid it draws as a layer. Its origin is
        /// resolved at projection time.
        var gridId: Int64 = 0
    }
    /// The forward of the last committed bracket: what a window move
    /// re-anchors. Under `lock`.
    private var committedForwardedCursor = ForwardedCursor()
    /// This bracket's forward, published by commitFlush and dropped by
    /// cancelFlush, so a window move never re-anchors to a cursor the
    /// committed vertices do not show. Core thread only.
    private var stagedForwardedCursor: ForwardedCursor?

    override var drawLoopTraceName: String { "surface \(gridId)" }

    // Scroll offset data stored as value-type; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race.
    private var scrollOffsetData: GridSurfaceRenderer.ScrollOffset?
    /// Shared with GridSurfaceRenderer. This surface latches the previous
    /// frame when it PRESENTS one; the main surface latches when it commits to
    /// drawing one and rolls the latch back if that frame is abandoned.
    /// Guarded by `lock`, with the rest of the scroll-offset publication.
    private var scrollOffsetLatch = SurfaceScrollOffsetLatch()
    /// One offset per hosted grid that is scrolling in its own right, sorted by
    /// grid id for `surfaceScrollOffset`'s binary search. The root's own offset
    /// stays in `scrollOffsetData`: that is the one the surface-wide passes
    /// bind. Published under `lock`, like `scrollOffsetData`.
    private var hostedScrollOffsetData: [GridSurfaceRenderer.ScrollOffset] = []
    /// The viewport height `scrollOffsetData` and `hostedScrollOffsetData`
    /// were converted to NDC against. Written under `lock` with them.
    private var scrollOffsetViewportHeight: Float = 0
    /// Built outside `lock` (resolving an offset takes the main view's own
    /// locks) and copied in, so neither lock is ever held while taking the
    /// other. Persistent, so a scrolled frame does no heap work for it.
    private var hostedScrollOffsetScratch: [GridSurfaceRenderer.ScrollOffset] = []
    /// Root plus hosted offsets, for the per-grid retention prune. Persistent
    /// so a scroll update costs no allocation.
    private var pruneOffsetsScratch: [GridSurfaceRenderer.ScrollOffset] = []
    /// What `markScrollOffsetStatePresented` last froze, for the end-of-ease
    /// comparison the root's own `lastPresentedScrollOffsetData` makes.
    ///
    /// The whole present gate — these two `lastPresented*`,
    /// `hasScrollOffsetStateChangedSinceLastPresent` and
    /// `markScrollOffsetStatePresented` — has no counterpart on the main
    /// renderer, and should not. This surface drives its own draw loop, so it
    /// has to ask "did anything change since the frame I last put on screen?"
    /// before deciding to skip one. The main renderer is driven by the flush
    /// instead: a commit is what wakes it, so the question never arises there.
    private var lastPresentedHostedScrollOffsetData: [GridSurfaceRenderer.ScrollOffset] = []
    private var hostedLayerOriginScratch: [(gridId: Int64, originYPx: Float, z: Int32)] = []
    private var lastPresentedScrollOffsetData: GridSurfaceRenderer.ScrollOffset?

    /// Rows scrolled off this window's edge, kept alive so the band the
    /// smooth-scroll offset opens shows them instead of the edge row's
    /// background stretched over it. Same mechanism the main surface uses;
    /// only the copying differs (see captureOneLayerRetainedRow).
    private var retention: ScrollRetention!
    /// Distance each grid this surface draws — its root and every hosted
    /// layer — has moved since the last capture, handed over by the
    /// grid_scroll callback. Summed because several notifications can land
    /// before a bracket opens. Guarded by `lock`.
    private var pendingGridScrollRows: [Int64: Int] = [:]
    /// Snapshot of `pendingGridScrollRows` taken at bracket open, so the
    /// captures run without `lock`. Persistent to avoid per-flush allocation.
    private var pendingGridScrollScratch: [(gridId: Int64, rowsDelta: Int, bounds: (top: Int, bottomEx: Int))] = []
    /// Sub-row ease seeds for the steps this window's row-shift fast path
    /// opened, published by commitFlush with the vertices they belong to.
    /// Deliberately a copy of the main renderer's pair rather than something
    /// ScrollRetention owns: staging inside beginStep also seeds the
    /// grid_scroll capture, whose scrolls a gesture already compensates, and
    /// that displaced grids that were square (it misplaced the cursor shader
    /// uniform in a split).
    private var stagedSmoothScrollSeeds: [(gridId: Int64, rowsDelta: Int)] = []
    /// Grids this bracket has already opened a retention step for. Two hints
    /// can name the same grid inside one bracket; without this the second
    /// would shift the rows the first already staged. Guarded by
    /// `lock`, like GridSurfaceRenderer's set of the same name.
    private var bracketStagedGrids: Set<Int64> = []
    /// Indices into the frame's retained snapshot belonging to the layer being
    /// drawn. Persistent so the layer pass allocates nothing per frame.
    private var retainedIndexScratch: [Int] = []
    private var smoothScrollSeeds: [(gridId: Int64, rowsDelta: Int)] = []
    /// The scrollable row span of each grid this surface draws: the grid minus
    /// its viewport margins (a winbar makes marginTop 1, and its row does not
    /// scroll), grid-local. Armed on the main thread as each gesture scroll is
    /// sent, because Neovim's response can land before the next frame.
    /// Guarded by `lock`.
    private var scrollCaptureBounds: [Int64: (top: Int, bottomEx: Int)] = [:]

    // Accumulated scroll delta (consumed by draw, survives across flushes)
    // Protected by lock (accessed from both flush ops and draw)
    private var pendingScrollAccum: SurfaceRowScroll? = nil

    // Dirty rows accumulated during flush (consumed by draw)
    // Protected by lock
    private var pendingDirtyRows: IndexSet = IndexSet()
    // Render-thread scratch for the ordered row list passed to encoders.
    // Swapped into each draw and returned by defer to retain capacity without
    // sharing storage (and therefore without per-frame Array COW allocation).
    private var dirtyRowsScratch: [Int] = []
    // Separate snapshot scratch for consuming pendingDirtyRows. Copying the
    // IndexSet value itself would share its COW storage, forcing the next
    // flush's first insert to allocate after pendingDirtyRows is cleared.
    private var submittedDirtyRowsScratch: [Int] = []
    // Dirty rows staged during the current flush bracket (guarded by
    // lock; written only while isInFlush). A draw() interleaving
    // with a flush can consume pendingDirtyRows BEFORE commitFlush publishes
    // committedSetIndex: it redraws from the OLD committed set and the marks
    // are lost, so the newly committed rows are never marked dirty again.
    // commitFlush re-publishes these staged marks so the next draw() redraws
    // the rows from the newly committed set. Idempotent when no draw()
    // interleaved. Mirrors GridSurfaceRenderer's flushDirtyRows.
    private var flushDirtyRows: IndexSet = IndexSet()

    // Persistent back buffer for partial redraw and GPU scroll copy
    private var backBuffer: MTLTexture? = nil
    private var backBufferSize: CGSize = .zero
    /// Per-view shader timing state. Owning this here (instead of the
    /// shared GridSurfaceRenderer) keeps iFrame / iTimeDelta /
    /// iFrameRate independent of draw order across views.
    private let shaderTiming = SurfaceShaderTiming()
    /// Last cursor rect this surface handed its shader, so the log fires on
    /// change only. Per-surface: each logs the rect IT hands its own shader.
    private var lastLoggedShaderCursor: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var lastLoggedCursorFrame: (Int, Float, Float) = (-1, 0, 0)
    /// Ping-pong render targets for multi-pass custom shader chains.
    /// Allocated lazily inside draw() when pipelines.count > 1.
    private let customShaderPong = SurfacePingPongTextures()
    private let scrollScratch = SurfaceScrollScratchTexture()

    // Blur transparency support
    private let blurEnabled: Bool
    private let isDecoratedSurface: Bool

    // Viewport origin offset (in pixels) for decorated windows where the MTKView
    // fills the full container but grid content is inset by padding.
    // Allows bloom blur to bleed into the padding area around grid content.
    var viewportOriginPx: CGPoint = .zero

    // --- Post-process bloom (neon glow) ---
    // Pipelines and sampler are shared from GridSurfaceRenderer.
    // Textures are per-view (sizes differ per window).
    private let glowTextures = SurfaceGlowTextures()

    // Cursor blink support
    /// Cursor blink phase and what the last frame drew with. Shared with
    /// GridSurfaceRenderer; see `SurfaceBlinkState`.
    private var blink = SurfaceBlinkState()
    var cursorBlinkState: Bool {
        get { blink.isVisible(lock: lock) }
        set { blink.setVisible(newValue, lock: lock) }
    }
    /// One published cursor, independent of the row triple.
    ///
    /// The cursor triple, shared with GridSurfaceRenderer; see
    /// `SurfaceCursorSlot` for why it is not on the row sets.
    /// All four guarded by `lock`, like the row triple's own state.
    private var cursorSlots: [SurfaceCursorSlot] = [
        SurfaceCursorSlot(), SurfaceCursorSlot(), SurfaceCursorSlot()
    ]
    private var committedCursorSetIndex: Int = 0
    private var cursorGpuInFlightCount: [Int] = [0, 0, 0]
    /// The slot this bracket wrote, or -1 when it has written no cursor. Only a
    /// bracket that wrote one rotates `committedCursorSetIndex` at commit.
    private var cursorWriteSetIndex: Int = -1

    /// Complete one protected GPU read and immediately service any contraction
    /// that had to skip this set while it was in flight. Caller holds
    /// `lock`.
    private func completeSurfaceGpuReadLocked(_ setIndex: Int) {
        completeSurfaceGpuRead(
            setIndex: setIndex,
            gpuInFlightCount: &gpuInFlightCount,
            bufferSets: bufferSets,
            committedSetIndex: committedSetIndex,
            retirement: &rowStorageRetirement
        )
    }

    // True while a core-thread flush bracket is open on this view. Unlike
    // `isInFlush` (core-thread-owned, unsafe to read from main), this is
    // written and read ONLY under lock, so main-thread
    // out-of-bracket writers can consult it: while a bracket is open they
    // must STAGE instead of writing the committed set — beginFlush already
    // COW-copied the committed set, so a direct committed write would be
    // silently discarded when the bracket commits (and would race the
    // unlocked copy itself).
    private var bracketOpen: Bool = false
    // Required font generation for both the upcoming flush and draw admission.
    // Font changes never mutate committed row arrays: a set remains logically
    // stale until a full-row commit publishes this generation. This avoids
    // racing both beginFlush's unlocked carry-forward and GPU in-flight reads.
    private var fontResetState = ExternalFontResetState()

    /// Caller must hold lock. Rows submitted before a font or
    /// layout transition cannot prove that the final set belongs wholly to
    /// the current generation, so the coverage starts over at the transition.
    private func recordGeneratedRowsLocked(
        rowStart: Int,
        rowCount: Int,
        totalRows: Int,
        totalCols: Int
    ) {
        if totalRows != flushGeneratedTotalRows || totalCols != flushGeneratedTotalCols {
            flushGeneratedRows.removeAll()
            flushGeneratedTotalRows = totalRows
            flushGeneratedTotalCols = totalCols
        }
        for row in rowStart..<max(rowStart, rowStart + rowCount) {
            flushGeneratedRows.insert(row)
        }
    }

    /// Record a mutation already published into `committedIndex`. Caller must
    /// hold lock so beginFlush and capacity growth cannot replace
    /// sparse history in the middle of this update.
    private func recordCommittedRowMutationLocked(
        committedIndex: Int,
        rows: some Sequence<Int>,
        structural: Bool
    ) {
        rowSync.recordCommit(committedIndex: committedIndex, rows: rows, structural: structural)
    }

    // --- Scrollbar ---
    override var surfaceId: Int64 { gridId }
    override var sharedResources: SharedRenderResources { shared }

    /// A buffer window follows the main window's rule; the external cmdline
    /// inserts the path, whatever mode the editor thinks it is in. The other
    /// decorated surfaces (popupmenu, messages) have nothing to insert into,
    /// so they decline and the drag falls through.
    override var acceptsFileDrops: Bool { gridId == ZonvieCore.cmdlineGridId || !isDecoratedSurface }
    override var dropInsertsPath: Bool {
        if gridId == ZonvieCore.cmdlineGridId { return true }
        return !isDecoratedSurface && bufferDropInsertsPath
    }
    override var tracksURLHover: Bool { !isDecoratedSurface }

    override func urlHoverCell(at location: CGPoint) -> (gridId: Int64, row: Int32, col: Int32)? {
        resolveInputTarget(pointPx: surfacePointPx(atViewPoint: location), requireScrollable: false)
    }


    // Use GridSurfaceRenderer.ScrollOffset for shader data (shared with main window)

    // Grid dimensions (in cells)
    private(set) var gridRows: UInt32 = 0
    private(set) var gridCols: UInt32 = 0

    let gridId: Int64

    /// Initialize with shared Metal resources from the main renderer.
    /// - Parameters:
    ///   - gridId: The Neovim grid ID
    ///   - device: Metal device
    ///   - commandQueue: Command queue prepared before host-window creation
    ///   - atlas: Shared glyph atlas
    ///   - shared: The GPU objects every surface borrows
    ///   - blurEnabled: Whether blur effect is enabled
    ///   - isDecoratedSurface: Whether this grid uses a decorated special-window shell
    init(gridId: Int64,
          device: MTLDevice,
          commandQueue: MTLCommandQueue,
          initialRows: Int,
          atlas: GlyphAtlas,
          shared: SharedRenderResources,
          blurEnabled: Bool = false,
          isDecoratedSurface: Bool = false) {
        self.gridId = gridId
        self.mtlDevice = device
        self.retention = ScrollRetention(device: device)
        self.queue = commandQueue
        self.blurEnabled = blurEnabled
        self.isDecoratedSurface = isDecoratedSurface

        self.shared = shared

        super.init(frame: .zero, device: device)

        let initialFontGeneration = atlas.fontGenerationSnapshot()
        fontResetState = ExternalFontResetState(initialGeneration: initialFontGeneration)
        for bufferSet in bufferSets {
            bufferSet.fontGeneration = initialFontGeneration
        }
        ZonvieCore.appLog("[ExternalGridView] init: gridId=\(gridId) blurEnabled=\(blurEnabled) (using shared pipelines)")

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.preferredFramesPerSecond = 60
        self.isPaused = true
        self.enableSetNeedsDisplay = true  // Idle mode: manual redraw via setNeedsDisplay

        if isDecoratedSurface || blurEnabled {
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            self.layer?.isOpaque = true
            self.layer?.backgroundColor = NSColor.black.cgColor
        }

        buildShaderBuffers()

        registerFileDrops()

        ZonvieCore.appLog("[ExternalGridView] backgroundAlpha=\(surfaceBackgroundAlpha()) isDecoratedSurface=\(isDecoratedSurface) gridId=\(gridId)")

        // Initial background: black, and decoratedSurface → alpha=0 so the
        // padding outside the Metal viewport is transparent (container bg
        // shows through).
        surfaceClearAlpha = resolveSurfaceClearAlpha(
            blurEnabled: blurEnabled,
            decoratedSurface: isDecoratedSurface
        )

        installScrollbar()
    }

    /// The custom-shader chain this surface draws with. The opaque variant
    /// belongs to DECORATED surfaces, whose backTex has alpha-0 padding and
    /// empty-input regions where `preserve_alpha` would make the shader vanish.
    /// A normal external window is an editor surface like the main window and
    /// keeps the configured `preserve_alpha`; taking the decorated variant for
    /// it was what made only external windows opaque under a shader. The two
    /// arrays are identical when `preserve_alpha` is off.
    /// What this surface's per-layer pass encoded for one hosted layer.
    ///
    /// `rows=` counts the row draws encoded, `of=` the layer's row count. They
    /// are equal while this surface redraws every hosted row: it collapses
    /// hosted damage into one `flushDirtyRows` and has no per-layer dirty set,
    /// which is the gap the main surface's `layerDrawState` closes.
    ///
    /// Deliberately NOT the main surface's `[layer_draw]` tag. Three scenarios
    /// parse that one BY FIELD NAME (`float_stack_scroll_continuity`,
    /// `visual_float_over_scrolled_split`, `visual_scrolled_layer_row_gating`),
    /// and a line missing `moved`/`committedY`/`drawY` is skipped by their
    /// `orelse continue` — silently, which is the vacuity their own comments
    /// warn about. A separate tag makes the separation explicit instead.
    private func logHostedLayerDraw(
        layer: SurfaceLayer,
        encodedRows: Int,
        of rows: Int,
        drawOriginPx: simd_float2,
        bodilyMoved: Bool
    ) {
        guard ZonvieCore.appLogEnabled else { return }
        // Where it was committed and where it is actually drawn, under the same
        // field names the main surface's `[layer_draw]` uses. The tag stays
        // separate (see above) but the fields are the same three, so the same
        // question — did this layer's drawn Y move further in one frame than a
        // smooth scroll can — can be asked of a float an external window hosts.
        // It could not be, before: this line carried only a row count.
        ZonvieCore.appLog(
            "[ext_layer_draw] surface=\(gridId) gridId=\(layer.gridId) rows=\(encodedRows) of=\(rows)"
                + " committedY=\(layer.originPx.y) drawY=\(drawOriginPx.y) moved=\(bodilyMoved ? 1 : 0)"
        )
    }

    private func surfaceCustomShaderPipelines() -> [CustomShaderPipeline] {
        let pipelines = shared.customShaderChain(decorated: isDecoratedSurface)
        // Once per surface, not per frame: this runs twice inside every draw.
        // `opaque` is read back off the chain that was actually selected, by
        // identity against the decorated one — not off `isDecoratedSurface`,
        // which would report the intent rather than the choice and would say
        // the same thing however this line picked. The two chains hold the
        // same objects when `preserve_alpha` is off, and both are opaque then.
        if ZonvieCore.appLogEnabled, !loggedShaderVariant, !pipelines.isEmpty {
            loggedShaderVariant = true
            let opaque = pipelines.first === shared.customShaderPipelinesDecorated.first
            ZonvieCore.appLog(
                "[ext_shader] gridId=\(gridId) decorated=\(isDecoratedSurface ? 1 : 0) opaque=\(opaque ? 1 : 0) chain=\(pipelines.count)"
            )
        }
        return pipelines
    }
    /// Main thread only (both callers are inside `draw(in:)`).
    private var loggedShaderVariant = false

    /// True when this frame's back texture goes to the decorated custom-shader
    /// chain instead of straight to the compositor — the exact precondition of
    /// the chain-encoding branch in `draw(in:)`.
    private var shaderChainConsumesSurface: Bool {
        guard isDecoratedSurface, mainTerminalView?.renderer != nil else { return false }
        return !shared.customShaderPipelinesDecorated.isEmpty
            && shared.customShaderPostProcess == .afterBloom
    }

    private func surfaceBackgroundAlpha() -> Float {
        // Popupmenu has per-row bg colors (Pmenu vs PmenuSel) that the user
        // must be able to tell apart. The decorated-surface alpha override
        // forces the shader to multiply every bg color by 0 so the
        // cmdline-style "show blur through cells" trick works for the
        // single-color cmdline / msg surfaces, but it collapses the popupmenu
        // into a uniform transparent block and hides the selection. Use 1.0
        // instead so each cell renders with its own opaque bg; the popupmenu's
        // surrounding blur is still preserved by the container view's
        // transparent layer around the Metal viewport.
        if gridId == ZonvieCore.popupmenuGridId { return 1.0 }
        return resolveSurfaceBackgroundAlpha(
            blurEnabled: blurEnabled,
            decoratedSurface: isDecoratedSurface,
            shaderChainConsumesSurface: shaderChainConsumesSurface
        )
    }

    deinit {
        ZonvieCore.appLog("[ExternalGridView] deinit: gridId=\(gridId)")

        // viewDidMoveToWindow(nil) normally removes this on teardown, since
        // every current close path clears contentView first. Dropping it here
        // too keeps a future path that releases the view without detaching it
        // from leaving a registration behind.
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        for observer in moveObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        moveObservers.removeAll()

        // Release Metal buffers held by all three SurfaceBufferSet objects.
        // Each set contains per-row MTLBuffer references that can total ~8MB.
        for bs in bufferSets {
            for i in 0..<bs.rowState.buffers.count {
                bs.rowState.buffers[i] = nil
            }
        }
        for slot in cursorSlots {
            slot.vertexBuffer = nil
            slot.vertexBufferCap = 0
            slot.vertexCount = 0
        }

        backBuffer = nil
        scrollScratch.invalidate()

        glowTextures.extractTex = nil
        for i in 0..<glowTextures.mipTextures.count {
            glowTextures.mipTextures[i] = nil
        }
        glowTextures.intensityBuffer = nil
    }

    override func hadRecentCommit(withinNs: UInt64) -> Bool {
        lock.lock()
        let t = lastCommitTime
        lock.unlock()
        return surfaceHadRecentCommit(lastCommitTime: t, withinNs: withinNs)
    }

    /// A decorated surface (cmdline, popupmenu, messages) has no scrollbar.
    override var hostsScrollbar: Bool { !isDecoratedSurface }

    private func buildShaderBuffers() {
        // (scroll offset / drawable size buffers removed: now passed via setVertexBytes/setFragmentBytes)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Vertex Submission

    /// Stage a font generation transition. This is safe on the core thread and
    /// is called there immediately after setFont(), before rows for the new
    /// font are submitted. The later main-queue notification is idempotent.
    func stageFontChanged(generation: UInt64) {
        lock.lock()
        stageFontChangedLocked(generation: generation)
        lock.unlock()
    }

    /// The body, for a caller that already holds the lock.
    private func stageFontChangedLocked(generation: UInt64) {
        let generationAdvanced = fontResetState.stage(generation: generation)
        if bracketOpen, generation > flushFontGeneration {
            flushFontGeneration = generation
            flushGeneratedRows.removeAll()
        }
        let totalRows = Int(committedExtent.height)
        if totalRows > 0 { pendingDirtyRows.insert(integersIn: 0..<totalRows) }
        if generationAdvanced {
            // Force one draw even before the delayed main-queue notification.
            // The draw gate suppresses stale rows and clears the back buffer.
            commitRevision &+= 1
        }
    }

    /// Notify that font has changed - reset presentation state and ensure an
    /// old committed generation is cleared. A new-generation commit wins.
    func notifyFontChanged(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        hasPresentedOnce = false
        stageFontChangedLocked(generation: generation)
    }

    /// Begin flush bracket. Cheap by design: a flush that turns out to carry no
    /// rows — plain cursor motion, the commonest one an external window sees —
    /// must not pay for a row set, nor be dropped because none is free. The row
    /// side is acquired by `prepareRowWriteState()` on the first row mutation,
    /// mirroring GridSurfaceRenderer.prepareMainWriteState().
    ///
    /// Refuses the bracket while the capacity ledger is armed, which is the
    /// gate `GridSurfaceRenderer.beginFlush` has carried all along. Only that
    /// one: the row SET is still acquired lazily by `prepareRowWriteState`, so
    /// a cursor-only flush is never dropped for a set it does not want (56f3b4a
    /// moved it there for exactly that reason, and this must not undo it).
    ///
    /// Refusing here rather than at the first row submit does not change the
    /// blast radius — both end in `zonvie_core_abort_flush` plus a retry — but
    /// it spends no vertex generation first. The ledger only arms on a real
    /// allocation failure (b83ff29, 4b1ad75), so this is a rare, transient
    /// state, not a per-flush cost.
    ///
    /// The stage-by-stage table against `GridSurfaceRenderer.beginFlush` is
    /// on that declaration, including why `retention.beginFlush` runs from
    /// `prepareRowWriteState` here and from `beginFlush` there.
    @discardableResult
    func beginFlush() -> Bool {
        lock.lock()
        if rowCapacity.blocksDraw {
            lock.unlock()
            ZonvieCore.appLog("[ExternalGridView] beginFlush: waiting for row capacity provisioning gridId=\(gridId)")
            return false
        }
        flushDirtyRows.removeAll()
        let srcIdx = committedSetIndex
        writeSetIndex = -1
        rowWritePrepared = false
        cursorWriteSetIndex = -1
        flushSourceSetIndex = srcIdx
        flushFontGeneration = fontResetState.beginFlushGeneration(
            sourceGeneration: bufferSets[srcIdx].fontGeneration
        )
        flushGeneratedTotalRows = bufferSets[srcIdx].knownTotalRows
        flushGeneratedTotalCols = bufferSets[srcIdx].knownTotalCols
        flushGeneratedRows.removeAll()
        flushChangedRows.removeAll()
        flushHasStructuralRowChange = false
        bracketStagedGrids.removeAll(keepingCapacity: true)
        // Publish "bracket open" BEFORE any unlocked committed-set copy:
        // main-thread out-of-bracket writers check this under the same lock and
        // stage instead of mutating the committed set, which makes
        // prepareRowWriteState's unlocked copySurfaceBufferSetRowState reads
        // safe (no concurrent committed-set mutation can start once this is
        // set).
        bracketOpen = true
        lock.unlock()

        isInFlush = true
        flushHadContent = false
        cursorOwner.restoreStagedFromCommitted()
        return true
    }

    /// Acquire and synchronize the row write set, once, on the first row
    /// mutation of a bracket. Returns false when no set is free, and latches
    /// `flushFailed` itself — the same contract GridSurfaceRenderer.prepareMainWriteState()
    /// has, which ZonvieCore escalates into an abort at flush end. The comment
    /// here used to claim that contract while leaving the latch to the caller;
    /// every caller did it, but forgetting it is the worst failure this file
    /// has (the core clears its dirty state, the flush commits, and those rows
    /// are never resent).
    ///
    /// Returning false because no bracket is open is NOT latched: `flushFailed`
    /// is only read at flush end, so latching outside a bracket would poison
    /// the next flush instead of this one.
    @discardableResult
    private func prepareRowWriteState() -> Bool {
        if rowWritePrepared { return true }
        guard isInFlush else { return false }

        lock.lock()
        let srcIdx = flushSourceSetIndex
        let picked = pickFreeBufferSetIndex(
            count: 3,
            committedIndex: srcIdx,
            gpuInFlightCount: gpuInFlightCount
        )
        if picked == -1 {
            let inf = gpuInFlightCount
            lock.unlock()
            flushFailed = true
            ZonvieCore.appLog("[ExternalGridView] prepareRowWriteState: no free buffer set, dropping flush gridId=\(gridId) committed=\(srcIdx) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return false
        }
        writeSetIndex = picked
        rowWritePrepared = true
        lock.unlock()

        gridBuffers.carryLayerRows(skipping: gridId, from: srcIdx, to: picked, scratch: &layerGridIdScratch)
        // Discard retention staged by a bracket that aborted instead of
        // committing; publication only ever happens from commitFlush. Then
        // capture what this flush's scroll is about to take off the edge,
        // while the committed set still holds the on-screen rows.
        retention.beginFlush()
        lock.lock()
        stagedSmoothScrollSeeds.removeAll(keepingCapacity: true)
        lock.unlock()
        captureRetainedRowsForPendingScroll()
        // The row-state sync below resets the set's stale scroll staging.
        let src = bufferSets[srcIdx]
        let dst = bufferSets[picked]
        let perfStarted = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let sync = rowSync.sync(from: src, to: dst, index: picked, maxRowBuffers: maxRowBuffers)
        if ZonvieCore.appLogEnabled {
            let elapsedUs = (CFAbsoluteTimeGetCurrent() - perfStarted) * 1_000_000
            let elapsedUsString = String(format: "%.1f", elapsedUs)
            ZonvieCore.appLogPerf("[perf] external_begin_prepare gridId=\(gridId) mode=\(sync.mode) syncedRows=\(sync.syncedRows) totalRows=\(src.rowState.buffers.count) us=\(elapsedUsString)")
        }
        // No cursor carry-forward: the cursor lives on its own triple now, and
        // a row-set rotation neither publishes nor invalidates it. A staged
        // cursor is left alone too — draw() publishes it into a free slot
        // without needing this bracket to reach a commit.
        return true
    }

    enum FlushBeginResult {
        case alreadyOpen
        case opened
        case failed
    }

    /// O(1) lazy-bracket admission for repeated row callbacks in one core
    /// flush. `isInFlush` is owned by that same core thread, so this check
    /// needs no cross-thread lock and avoids scanning every previously touched
    /// external view for every row.
    func beginFlushIfNeeded() -> FlushBeginResult {
        if isInFlush { return .alreadyOpen }
        return beginFlush() ? .opened : .failed
    }

    /// Cancel an open flush bracket without publishing. Used when another
    /// view's beginFlush() failed and the whole flush is aborted (mirrors
    /// windows/callbacks.zig onFlushBegin's cancelFlush loop). The write set
    /// holds only scratch state until commitFlush publishes it, so dropping
    /// the bracket flag is sufficient. Safe no-op when no bracket is open.
    func cancelFlush() {
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=surface_abort surface=\(gridId) was_open=\(isInFlush)")
        isInFlush = false
        lock.lock()
        pendingSurfaceLayers = nil
        // The contract `SurfaceCursorOwner` documents and the main surface
        // follows: an abandoned bracket puts the owner back to what is on
        // screen, so the next bracket's clear from the true owner is accepted.
        cursorOwner.restoreStagedFromCommitted()
        stagedForwardedCursor = nil
        // Only a bracket that acquired a row set left one half-written.
        if bracketOpen, rowWritePrepared, writeSetIndex >= 0 {
            rowSync.abandon(writeSetIndex)
        }
        closeFlushBracketLocked()
        // An abandoned bracket publishes no cursor. The slot it wrote is simply
        // released; the committed one is still whatever was last published.
        cursorWriteSetIndex = -1
        lock.unlock()
    }

    /// Commit flush — publish write set as the new committed state for draw().
    /// Called from core thread (thread-safe via lock).
    func commitFlush(publishedAtlasTexture: MTLTexture?) {
        guard isInFlush else { return }
        FrameTracer.trace(.commitFlush, seq: UInt32(truncatingIfNeeded: gridId))
        let hadContent = flushHadContent
        // Captured before the bracket's state is reset below; -1 names a commit
        // that published no rows.
        let tracedWriteSet = rowWritePrepared ? writeSetIndex : -1
        if hadContent {
            // What this bracket actually published. A flush that only moved the
            // cursor took no row set and rotates none.
            let publishedRows = rowWritePrepared
            let layoutContracted = publishedRows
                && (bufferSets[flushSourceSetIndex].knownTotalRows > bufferSets[writeSetIndex].knownTotalRows
                    || bufferSets[flushSourceSetIndex].knownTotalCols > bufferSets[writeSetIndex].knownTotalCols)
            lock.lock()
            if publishedRows {
                committedSetIndex = writeSetIndex
            }
            // The cursor this bracket wrote becomes visible with the rows it
            // belongs to. A bracket that wrote none leaves the published slot
            // where it is — nothing about a row rotation ages the cursor.
            if cursorWriteSetIndex != -1 {
                committedCursorSetIndex = cursorWriteSetIndex
                cursorWriteSetIndex = -1
            }
            committedExtent.commit(width: gridCols, height: gridRows)
            cursorOwner.commit()
            if let forwarded = stagedForwardedCursor {
                committedForwardedCursor = forwarded
                stagedForwardedCursor = nil
            }
            // Layers and the vertices they place become visible together.
            if let staged = pendingSurfaceLayers {
                accumulateSurfaceLayerPlacementTravel(
                    staged: staged,
                    committed: committedSurfaceLayers,
                    rootGridId: gridId,
                    cellHeightPx: Float(shared.cellHeightPx),
                    into: &layerPlacementRowsUp
                )
                committedSurfaceLayers = staged
                pendingSurfaceLayers = nil
                pruneSurfaceLayerLedger(&layerPlacementRowsUp, to: staged)
                floatDebtLedger.prune(to: staged)
                // Removing the last child must erase its old pixels too.
                pendingLayoutDamage = true
            }
            // Publish this bracket's retention together with the vertices it
            // belongs to: a retained row shown against pre-scroll content
            // would draw the same line twice. Same for the cursor rect the
            // shader uniforms carry — it describes this bracket's cursor
            // vertices, which only reach the screen now.
            // Retention and the scroll distance it was captured against belong
            // to the row side: only a bracket that published rows spends them.
            if publishedRows {
                if retention.commit() {
                    smoothScrollSeeds.append(contentsOf: stagedSmoothScrollSeeds)
                    stagedSmoothScrollSeeds.removeAll(keepingCapacity: true)
                }
                // The distance this bracket captured against is only spent now
                // that its vertices are the committed ones; a cancelled bracket
                // leaves it for the next (see captureRetainedRowsForPendingScroll).
                pendingGridScrollRows.removeAll(keepingCapacity: true)
            }
            // Every commit bumps, as GridSurfaceRenderer's does. The revision
            // answers one question — "is the committed state a generation this
            // draw has not seen?" — and nothing else. Whether the back buffer may
            // be reused is asked of the CONTENT predicates below, which is what
            // the suppression used to stand in for. The compensation for rows
            // this commit landed is released here too, under `lock`, not at
            // the main surface's commit.
            shared.shaderCursor.publishCommitTail(
                committedBy: self,
                publishScrollClears: { core?.scrollModel.publishStagedScrollClears(ownedBy: self) },
                commitRevision: &commitRevision
            )
            if publishedRows {
                serviceSurfaceRowStorageRetirement(
                    bufferSets: bufferSets,
                    gpuInFlightCount: gpuInFlightCount,
                    committedSetIndex: committedSetIndex,
                    layoutContracted: layoutContracted,
                    state: &rowStorageRetirement
                )
            }
            // Freeze the atlas texture reference into the SAME buffer set
            // as this commit's vertex data — see SurfaceBufferSet.atlasTextureSnapshot
            // for why draw(in:) must read both from one consistent
            // generation instead of independently re-fetching the atlas at
            // a later point. Safe to call here: ZonvieCore's on_flush_end
            // closes the flush's atlas transaction before any surface
            // commits, both on the core/RPC thread.
            //
            // A cursor-only commit rotates no set, so it refreshes the standing
            // one. Always: it waited for no frame to be in flight, and a cursor
            // glyph new to this flush (one half of a ligature) then addressed a
            // texture the swap had made the back one. draw() takes the
            // reference under the lock with the set index.
            // The texture this flush published, handed in by on_flush_end as
            // the main surface's commit receives it.
            if publishedRows {
                bufferSets[writeSetIndex].atlasTextureSnapshot = publishedAtlasTexture
            } else {
                bufferSets[committedSetIndex].atlasTextureSnapshot = publishedAtlasTexture
            }
            // Merge the write set's staged scroll into the global accumulator.
            // Done here (under lock, after committedSetIndex update) so draw()
            // never sees a scroll delta that precedes the matching vertex data
            // (mirrors GridSurfaceRenderer.commitFlush).
            // This bracket's own marks are in flushDirtyRows only and are
            // merged below unshifted, since the core sends every shift hint
            // before the rows.
            if publishedRows,
               let ps = publishStagedSurfaceScroll(bufferSets[writeSetIndex], into: &pendingScrollAccum,
                                                  dirtyRows: &pendingDirtyRows) {
                ZonvieCore.appLog("[ext_scroll_commit] gridId=\(gridId) delta=\(ps.rowsDelta) accum=\(pendingScrollAccum?.rowsDelta ?? 0) rev=\(commitRevision)")
            }
            // Re-publish dirty rows staged during this flush. A draw() that
            // interleaved with the flush may have already consumed
            // pendingDirtyRows (see submitVerticesRowRaw) before this commit
            // published committedSetIndex, redrawing those rows from the
            // PREVIOUS committed set. Without this the rows committed here
            // would never be marked dirty again. Idempotent when no draw()
            // interleaved (mirrors GridSurfaceRenderer.commitFlush).
            pendingDirtyRows.formUnion(flushDirtyRows)
            flushDirtyRows.removeAll()
            if publishedRows {
                let committed = bufferSets[writeSetIndex]
                let generatedRowCount = flushGeneratedTotalRows == committed.knownTotalRows
                    && flushGeneratedTotalCols == committed.knownTotalCols
                    ? flushGeneratedRows.rows.count
                    : 0
                committed.fontGeneration = fontResetState.commitGeneration(
                    sourceGeneration: committed.fontGeneration,
                    flushGeneration: flushFontGeneration,
                    regeneratedRows: generatedRowCount,
                    totalRows: committed.knownTotalRows
                )
                recordCommittedRowMutationLocked(
                    committedIndex: writeSetIndex,
                    rows: flushChangedRows.rows.lazy.map(Int.init),
                    structural: flushHasStructuralRowChange
                )
            }
            if !pendingDirtyRows.isEmpty || pendingScrollAccum != nil {
                lastCommitTime = mach_absolute_time()
            }
            closeFlushBracketLocked()
            lock.unlock()
        } else {
            // Contentless bracket: nothing rotates. Close the bracket flag
            lock.lock()
            cursorWriteSetIndex = -1
            // Released here too, as the main surface releases at every commit:
            // compensation left staged would ride out on the next commit that
            // does carry rows, paired with rows it does not describe. The
            // revision is not bumped — nothing this draw has not seen landed.
            let released = core?.scrollModel.publishStagedScrollClears(ownedBy: self) ?? 0
            if released > 0 {
                ZonvieCore.appLog("[ext_commit] contentless bracket released \(released) scroll clears gridId=\(gridId)")
            }
            closeFlushBracketLocked()
            lock.unlock()
        }
        isInFlush = false
        if hadContent {
            ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=surface_commit surface=\(gridId) write_set=\(tracedWriteSet)")
            activateSurfaceDrawLoop()
        }
    }

    /// Record how far one grid this surface draws — its root or a hosted
    /// layer — just moved. Called from the grid_scroll callback on the core
    /// thread; the capture itself waits for this view's flush bracket to open
    /// (see captureRetainedRowsForPendingScroll).
    func noteGridScroll(gridId id: Int64, rowsDelta: Int) {
        guard GridSurfaceRenderer.smoothScrollEnabled, rowsDelta != 0 else { return }
        lock.lock()
        pendingGridScrollRows[id, default: 0] += rowsDelta
        lock.unlock()
    }

    /// Tell this window which rows of one grid it draws actually scroll.
    /// Called from the scroll input path on the main thread, where the grid's
    /// viewport margins are readable without blocking.
    func setScrollCaptureBounds(gridId id: Int64, top: Int, bottomEx: Int) {
        lock.lock()
        scrollCaptureBounds[id] = bottomEx > top ? (top: top, bottomEx: bottomEx) : nil
        lock.unlock()
    }

    /// Capture the rows the pending scrolls take off the edges of the grids
    /// this window draws.
    ///
    /// Runs at bracket open, which is the last moment the committed set still
    /// holds the on-screen content — by the end of the flush its rows have
    /// been regenerated or their slots rotated.
    ///
    /// This is the ONLY capture for the root. `applyRowScroll` covers just
    /// the core's row-scroll fast path, which the core does not always take,
    /// whereas grid_scroll is reported for every scroll; and ZonvieCore opens
    /// the bracket immediately before calling `applyRowScroll`, so capturing
    /// there as well would stage the same rows twice. A hosted layer is
    /// captured the way the main surface captures one (the shared
    /// `captureSurfaceGridScrollStep`), and its fast path stands down for it.
    private func captureRetainedRowsForPendingScroll() {
        guard GridSurfaceRenderer.smoothScrollEnabled else { return }
        // Read but do NOT consume: this bracket may be cancelled, and the core
        // never resends a grid_scroll (it consumes the notification as it
        // dispatches). Clearing here would lose the distance, leaving the
        // published rows a step behind the content they are drawn against —
        // stale lines over live text, with the edge stretch suppressed because
        // rows are still published. commitFlush clears it once the vertices
        // this capture belongs to are actually on screen.
        //
        // Margins are not part of the scrolled region: a winbar occupies the
        // top row and stays put, so taking the whole grid would capture it and
        // miss the content row next to it — leaving the band's innermost row
        // blank. The span is however many rows the margins actually cover, so
        // there is nothing to guess: without it, capture nothing and let the
        // edge stretch have the band rather than retain the wrong rows.
        lock.lock()
        pendingGridScrollScratch.removeAll(keepingCapacity: true)
        for (id, rowsDelta) in pendingGridScrollRows where rowsDelta != 0 {
            guard let bounds = scrollCaptureBounds[id] else { continue }
            pendingGridScrollScratch.append((gridId: id, rowsDelta: rowsDelta, bounds: bounds))
        }
        lock.unlock()
        let capturedCellHeightPx = Float(shared.cellHeightPx)
        for pending in pendingGridScrollScratch {
            let id = pending.gridId
            // The root is a grid of this surface like any other, read from
            // the surface's own sets and clamped to the committed extent.
            let isRoot = id == gridId
            let cs: SurfaceBufferSet
            var bounds = pending.bounds
            if isRoot {
                cs = bufferSets[flushSourceSetIndex]
                let rows = Int(committedExtent.resolved(liveWidth: gridCols, liveHeight: gridRows).height)
                bounds.bottomEx = min(bounds.bottomEx, rows)
            } else {
                guard let sets = gridBuffers.existingSets(for: id) else { continue }
                cs = sets[flushSourceSetIndex]
            }
            let captured = captureSurfaceGridScrollStep(
                gridId: id,
                cs: cs,
                bounds: bounds,
                rowsDelta: pending.rowsDelta,
                sourceShift: 0,
                retention: retention,
                lock: lock,
                bracketStagedGrids: &bracketStagedGrids,
                cellHeightPx: capturedCellHeightPx
            )
            // Seeding is decided by who compensates the scroll, not by which
            // path captured the rows: the root's capture here serves a
            // trackpad gesture (which compensates through the finger and owes
            // no seed) and a keyboard scroll that only reached here because an
            // ease was already holding an offset — that one owes one. The
            // tick drops a seed for a grid a gesture owns.
            if isRoot, captured {
                stageSurfaceEaseSeed(gridId: id, rowsDelta: pending.rowsDelta, lock: lock,
                                     stagedSmoothScrollSeeds: &stagedSmoothScrollSeeds)
            }
        }
    }


    /// Retain the rows a hosted layer's scroll is about to displace, so its own
    /// pass can ease them the way the root's are eased. The main surface does
    /// this for every layer it places; an external surface used to stage
    /// nothing for the layers it hosts, which is why a float inside one jumped
    /// a whole row while the window behind it glided.
    /// Shared with GridSurfaceRenderer (`captureSurfaceLayerScrollStep`); this
    /// surface resolves a retained row through `captureOneLayerRetainedRow`,
    /// which needs the cell height the capture was taken at, and guards its
    /// state with the triple-buffer lock.
    private func captureLayerScrollStep(
        gridId id: Int64,
        sets: [SurfaceBufferSet],
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int
    ) {
        guard GridSurfaceRenderer.smoothScrollEnabled else { return }
        captureSurfaceLayerScrollStep(
            gridId: id,
            sets: sets,
            flushSourceSetIndex: flushSourceSetIndex,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            retention: retention,
            lock: lock,
            bracketStagedGrids: &bracketStagedGrids,
            stagedSmoothScrollSeeds: &stagedSmoothScrollSeeds,
            cellHeightPx: Float(shared.cellHeightPx)
        )
    }


    /// Remap this surface's row slots for a core row-scroll and stage the
    /// scroll for the GPU blit. Core thread, inside the flush bracket.
    func applyRowScroll(rowStart: Int, rowEnd: Int, colStart: Int, colEnd: Int, rowsDelta: Int, totalRows: Int, totalCols: Int) {
        ZonvieCore.appLog("[ext_applyRowScroll] gridId=\(gridId) rowStart=\(rowStart) rowEnd=\(rowEnd) rowsDelta=\(rowsDelta) isInFlush=\(isInFlush)")
        guard isInFlush else {
            ZonvieCore.appLog("[ExternalGridView] applyRowScroll called outside flush bracket gridId=\(gridId)")
            return
        }
        guard rowsDelta != 0 else { return }
        guard rowStart >= 0, rowEnd > rowStart else { return }

        // Consumer-side eligibility: only remap full-width scrolls. The core
        // only shifts on full grid-local width (gridScrollFastPathRegion in
        // src/core/flush.zig), so a narrower one has to be redrawn rather than
        // staged as a shift the blit would apply too wide — returning here
        // left the region carrying the pre-scroll pixels with nothing owed.
        // `applyLayerRowScroll` in GridSurfaceRenderer takes the same else.
        guard colStart == 0, colEnd == totalCols else {
            lock.lock()
            flushDirtyRows.insert(integersIn: rowStart..<rowEnd)
            lock.unlock()
            return
        }
        // No capacity pre-check here, matching applyLayerRowScroll in
        // GridSurfaceRenderer: this path only grows the logical row-state
        // arrays, which remapSurfaceRowSlots does synchronously via
        // ensureSurfaceRowStorage. The pre-check also demanded the
        // async-only detach-pool and private-slot arrays, so an ordinary
        // row-count growth failed it, set flushFailed, and (via ZonvieCore's
        // per-view sweep) aborted the whole app's flush including the main
        // grid.

        guard prepareRowWriteState() else { return }
        let ws = bufferSets[writeSetIndex]
        // Capture the outgoing rows, and stage the ease seed, when the
        // grid_scroll hand-over did not already: that hand-over is gated to
        // gesture-owned scrolls, so a keyboard or Neovim-initiated scroll
        // arrives here with nothing retained and no seed — the main surface
        // takes both from the same shared step on this fast path. Stood down
        // on whether the bracket-open capture actually took a step for the
        // root (prepareRowWriteState ran it just above), because capturing
        // again would shift the same rows a second time and seed twice. A
        // hand-over it could not use (no span armed: keyboard scroll during an
        // ease) took no step, so this one does.
        if GridSurfaceRenderer.smoothScrollEnabled {
            lock.lock()
            let steppedAtBracketOpen = bracketStagedGrids.contains(gridId)
            lock.unlock()
            if !steppedAtBracketOpen {
                // The source set still holds the on-screen rows: this runs
                // before the remap below.
                captureSurfaceLayerScrollStep(
                    gridId: gridId,
                    sets: bufferSets,
                    flushSourceSetIndex: flushSourceSetIndex,
                    rowStart: rowStart,
                    rowEnd: rowEnd,
                    rowsDelta: rowsDelta,
                    retention: retention,
                    lock: lock,
                    bracketStagedGrids: &bracketStagedGrids,
                    stagedSmoothScrollSeeds: &stagedSmoothScrollSeeds,
                    cellHeightPx: Float(shared.cellHeightPx)
                )
            }
        }
        flushHasStructuralRowChange = true
        // The marks have to travel with the rows they describe. The remap below
        // moves a row's vertices to another logical row; a mark left at the
        // pre-shift index names content that is no longer there, and with the
        // blit accepted the row it moved to is never repainted. Only this
        // bracket's marks here: pendingDirtyRows carries marks a cancelled
        // bracket must keep as they are, so commitFlush shifts those instead,
        // against the shift it actually publishes.
        lock.lock()
        shiftSurfaceRowIndices(
            &flushDirtyRows,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta
        )
        lock.unlock()
        remapSurfaceRowSlots(
            bufferSet: ws,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            totalRows: totalRows,
            totalCols: totalCols,
            maxRowBuffers: maxRowBuffers
        )

        // Stage the scroll on the WRITE set only; commitFlush merges it into
        // pendingScrollAccum under lock AFTER committedSetIndex is published.
        // Accumulating here (inside the bracket) let a draw() interleaving
        // between this call and commitFlush consume the delta and blit the
        // back buffer against the still-committed PRE-scroll vertices — one
        // mis-shifted frame, and a permanent one if the bracket was then
        // cancelled (cancelFlush) so the vertices never rotated. Mirrors
        // GridSurfaceRenderer's beginFlush-stage/commitFlush-merge split.
        stageSurfaceRowScroll(
            on: ws,
            rowStart: rowStart, rowEnd: rowEnd,
            colStart: colStart, colEnd: colEnd,
            rowsDelta: rowsDelta,
            totalRows: totalRows, totalCols: totalCols,
            dirtySupersededRows: { start, end in
                flushDirtyRows.insert(integersIn: start..<end)
            }
        )

        // Do NOT mark the entire scroll region as dirty here.
        // GPU scroll copy (blit) handles pixel shift; only vacated rows need redraw.
        // Core sends vertex data only for dirty rows (regen_count=1 in fast path).
        // Marking all rows dirty would cause full redraw, negating the blit benefit.
        flushHadContent = true
    }

    /// Write a cursor from inside a flush bracket into a slot of this
    /// bracket's own, rotated in at commit. Reusing the slot already picked
    /// keeps a bracket that writes the cursor twice from consuming two.
    ///
    /// A failure — every slot being read by a frame in flight, or a buffer that
    /// cannot be grown — fails the flush, exactly as the row side does.
    private func writeBracketCursorVertices(ptr: UnsafePointer<zonvie_vertex>?, count: Int) {
        // The lock covers the PICK only, as GridSurfaceRenderer's does. What
        // makes the write safe without it is slot exclusivity, not the lock:
        // `pickCursorSlotLocked` refuses the committed slot and any slot with a
        // frame in flight, `draw(in:)` only ever latches `committedCursorSetIndex`,
        // and only this thread moves it — so the picked slot is memory no other
        // thread can name. Holding the lock across the write put a
        // `device.makeBuffer` on the core thread inside the lock that draw()
        // blocks on, for no reader it excluded.
        lock.lock()
        if cursorWriteSetIndex == -1 {
            cursorWriteSetIndex = pickCursorSlotLocked()
        }
        let target = cursorWriteSetIndex
        let inf = cursorGpuInFlightCount
        let committed = committedCursorSetIndex
        lock.unlock()

        if target != -1,
           cursorSlots[target].write(device: mtlDevice, ptr: ptr.map(UnsafeRawPointer.init), count: count) {
            return
        }
        lock.lock()
        cursorWriteSetIndex = -1
        lock.unlock()
        ZonvieCore.appLog("[ExternalGridView] cursor write failed gridId=\(gridId) committed=\(committed) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
        flushFailed = true
    }

    /// A cursor slot that is neither published nor being read by the GPU.
    /// -1 when nothing is free. Caller holds `lock`.
    private func pickCursorSlotLocked() -> Int {
        pickFreeBufferSetIndex(
            count: cursorSlots.count,
            committedIndex: committedCursorSetIndex,
            gpuInFlightCount: cursorGpuInFlightCount)
    }

    /// Release one protected GPU read of a cursor slot. Caller holds
    /// `lock`. Unlike the row triple there is no storage
    /// retirement to service: a slot owns exactly one buffer.
    /// Release both halves of one frame's protected reads: the row set it drew
    /// and the cursor slot it drew over it. draw() takes them together, so
    /// every bail and every completion handler has to give both back.
    private func completeSurfaceFrameReadLocked(rowSet: Int, cursorSlot: Int) {
        completeSurfaceGpuReadLocked(rowSet)
        completeSurfaceCursorGpuReadLocked(cursorSlot)
    }

    private func completeSurfaceCursorGpuReadLocked(_ slotIndex: Int) {
        guard slotIndex >= 0,
              slotIndex < cursorGpuInFlightCount.count,
              cursorGpuInFlightCount[slotIndex] > 0
        else { return }
        cursorGpuInFlightCount[slotIndex] -= 1
    }

    /// Submit vertices for one row into the write set during a flush bracket.
    /// With ZONVIE_VERT_UPDATE_CURSOR (2) they go to the dedicated cursor
    /// buffer instead, outside the row buffers and so immune to the GPU scroll
    /// copy (no cursor ghosts).
    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32 = 1, totalRows: Int, totalCols: Int) {
        // A view registered after on_flush_begin did not join this flush's
        // bracket. Do not reinterpret its later core callbacks as an
        // out-of-bracket publication: those vertices sample this flush's back
        // atlas, while the view can only snapshot an older committed texture.
        // External-window creation has already scheduled a bracketed resend.
        if !isInFlush {
            return
        }

        // gridRows/gridCols are core-thread bracket state; commitFlush
        // publishes them into committedExtent.
        gridRows = UInt32(totalRows)
        gridCols = UInt32(totalCols)

        let isCursorUpdate = (flags & 2) != 0  // ZONVIE_VERT_UPDATE_CURSOR
        if isCursorUpdate {
            // commitFlush publishes the slot with the commit revision it bumps.
            submitLayerCursor(gridId: gridId, ptr: ptr, count: count, rootRow: rowStart)
            return
        }


        if rowCount == 0 {
            // A zero-cell layout rewrites the write set's row state, so it owes
            // the same acquisition an ordinary row does.
            guard count == 0,
                  prepareRowWriteState(),
                  applySurfaceZeroCellLayout(
                    bufferSet: bufferSets[writeSetIndex],
                    totalRows: totalRows,
                    totalCols: totalCols
                  )
            else {
                flushFailed = true
                return
            }
            flushHadContent = true
            flushChangedRows.removeAll()
            // Font-coverage state: stageFontChangedLocked writes it from main.
            lock.lock()
            flushGeneratedRows.removeAll()
            flushGeneratedTotalRows = totalRows
            flushGeneratedTotalCols = totalCols
            lock.unlock()
            flushHasStructuralRowChange = true
            return
        }

        // In-bracket (core thread): write set is never GPU-in-flight.
        guard prepareRowWriteState() else { return }
        // A failure here escalates into an app-wide abort_flush through
        // ZonvieCore's per-view flushFailed sweep, as on the main surface.
        if let structural = submitSurfaceWriteSetRow(
            bufferSets: bufferSets,
            writeSetIndex: writeSetIndex,
            sourceSetIndex: flushSourceSetIndex,
            device: mtlDevice,
            ledger: rowCapacity,
            lock: lock,
            rowStart: rowStart,
            ptr: UnsafeRawPointer(ptr),
            count: count,
            maxRowBuffers: maxRowBuffers,
            totalRows: totalRows,
            totalCols: totalCols,
            logLabel: "ExternalGridView:\(gridId)",
            inflightRowBuffers: { self.inflightRowBuffers(atSlot: $0) }
        ) {
            lock.lock()
            recordGeneratedRowsLocked(
                rowStart: rowStart,
                rowCount: rowCount,
                totalRows: totalRows,
                totalCols: totalCols
            )
            lock.unlock()
            if structural {
                flushHasStructuralRowChange = true
            } else {
                for row in rowStart..<max(rowStart, rowStart + rowCount) {
                    flushChangedRows.insert(row)
                }
            }
        } else {
            flushFailed = true
        }
        // Staged in flushDirtyRows only; commitFlush publishes them with the
        // rows. Writing pendingDirtyRows here too made the bracket copy it
        // (IndexSet storage shared with a snapshot) on every flush.
        lock.lock()
        for r in rowStart..<max(rowStart, rowStart + rowCount) {
            flushDirtyRows.insert(r)
        }
        lock.unlock()
        flushHadContent = true
        return
    }


    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: - Back Buffer Management

    private func ensureBackBuffer(drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        if backBuffer != nil, backBufferSize == drawableSize { return }
        let desc = makeSurfaceTextureDescriptor(
            size: drawableSize,
            pixelFormat: pixelFormat,
            usage: [.renderTarget, .shaderRead]
        )
        backBuffer = mtlDevice.makeTexture(descriptor: desc)
        backBufferSize = drawableSize
        // The ping-pong is not dropped here: `SurfacePingPongTextures.ensure`
        // is keyed on the size it is asked for and reallocates when the
        // drawable changes, which is the only thing the main surface relies on.
        hasPresentedOnce = false
    }

    /// Translate this view's cursor verts (NDC, view-local) into the
    /// main window's drawable px and forward to the main renderer's
    /// shader cursor state. Without this, cursor shaders see the main
    /// grid's stale cursor while the user is editing the cmdline /
    /// popupmenu / a float window.
    /// `cursorGridId` is the grid the cursor belongs to: this surface's root,
    /// or one of the grids it draws as a layer. The projection resolves that
    /// grid's origin within the surface, so a cursor inside a hosted float is
    /// published where it is drawn rather than at the window's top-left.
    private func forwardExternalCursorToMainShader(
        ptr: UnsafePointer<zonvie_vertex>,
        count: Int,
        cursorGridId: Int64
    ) {
        guard count > 0 else { return }
        // Grid-local bounds from the core; the projection into the main
        // window's screen space is applied on republish, where the two
        // windows' positions are known.
        var rect = zonvie_cursor_rect()
        guard zonvie_core_cursor_rect(ptr, count, 0, 0, &rect) else { return }
        let c = ptr[0].color
        let forwarded = ForwardedCursor(
            px: (minX: rect.left, maxX: rect.right, minY: rect.top, maxY: rect.bottom),
            color: (c.0, c.1, c.2, c.3),
            gridId: cursorGridId
        )
        stagedForwardedCursor = forwarded
        republishCursorShaderState(forwarded)
    }

    /// Project the last forwarded cursor box from this grid's local pixels
    /// into the main window's drawable pixels and publish it as the shader
    /// cursor rect.
    ///
    /// Split out from the forwarder because the projection depends on where
    /// the two windows are, not only on the verts: `screenSpaceParameters`
    /// measures this view's top-left relative to the main view's. Dragging
    /// either window changes that offset without producing a single new
    /// cursor vertex, which used to leave the cursor shader burning at the
    /// float's pre-move position until the next cursor update.
    private func republishCursorShaderState(_ forwarded: ForwardedCursor? = nil, reanchor: Bool = false) {
        let source: ForwardedCursor
        if let forwarded {
            source = forwarded
        } else {
            lock.lock()
            source = committedForwardedCursor
            lock.unlock()
        }
        guard let local = source.px, let color = source.color else { return }
        guard let mainView = mainTerminalView else { return }
        // Same screen-space parameters the shader uniforms use, so the
        // cursor rect lands in the same coordinate system the shader
        // resolves against.
        let (_, windowOffset) = screenSpaceParameters(
            mainView: mainView,
            selfView: self
        )
        let offX = Float(windowOffset.x)
        let offY = Float(windowOffset.y)
        // Cursor verts are this grid's own local pixels, y down. The render
        // path maps them through MTLViewport(origin: viewportOriginPx*scale,
        // ...) on this view's drawable, and `windowOffset` places that
        // drawable inside the main window's screen space — so the same two
        // translations put the rect where the shader resolves it. The
        // viewport origin carries the ext-cmdline leading icon / padding
        // shift (set from layout.gridFrame.origin); omitting it lands
        // iCurrentCursor to the left of the real cursor on decorated
        // surfaces. Keeping the mapping identical to the render path
        // preserves the Ghostty contract: iCurrentCursor == the cursor's
        // true on-screen rect.
        let scale = Float(backingScale)
        let vpOriginX = Float(viewportOriginPx.x) * scale
        let vpOriginY = Float(viewportOriginPx.y) * scale
        // The origin of the grid the cursor is on, which the draw path also
        // feeds SurfaceViewportMetrics, so the two mappings cannot drift. A
        // layer's origin is already surface-absolute (drawHostedLayers binds
        // layer.originPx directly), so it REPLACES the root's rather than
        // adding to it. commitFlush replaces the array wholesale under
        // lock on the core thread, and this runs on both the core
        // thread (cursor forward) and the main thread (window move), so copy
        // the one value out under the lock — never hold it across the renderer
        // callout below. Resolved per call, not stored: a window move has to
        // reproject against the placement the surface holds now.
        lock.lock()
        // The same resolve the cursor body is placed with. The fallback this
        // had of its own, the root layer's origin, is (0,0) by the core's
        // layout contract, which is what the resolve answers for the root.
        let cursorOrigin = resolveSurfaceCursorPlacement(
            ownerGridId: source.gridId,
            rootGridId: gridId,
            layers: forwarded != nil ? (pendingSurfaceLayers ?? committedSurfaceLayers) : committedSurfaceLayers
        ).originPx
        lock.unlock()
        let leftPx = offX + vpOriginX + cursorOrigin.x + local.minX
        let rightPx = offX + vpOriginX + cursorOrigin.x + local.maxX
        let topPx = offY + vpOriginY + cursorOrigin.y + local.minY
        let botPx = offY + vpOriginY + cursorOrigin.y + local.maxY
        // Ghostty's cursor shaders treat iCurrentCursor.y as the
        // BOTTOM edge of the cursor rect (rect spans y-h..y).
        // Tag the rect with the grid the cursor is actually ON, which is this
        // surface's root for its own cursor and the layer's grid for a float it
        // hosts. That id is what decides which scroll displacement the shader
        // cursor is given, so tagging a hosted float's cursor with the surface
        // would hand it the ROOT's displacement and slide the effect away from
        // a cursor that never moved. The main renderer tags with the cursor
        // vertex's own grid_id for the same reason. It must never be left
        // unset: the cursor shader state is shared with the main view (renderer
        // is mainView.renderer), so a default of "no grid" would switch the
        // main window's correction off too.
        let owner = source.gridId
        let rect = (leftPx, botPx, rightPx - leftPx, botPx - topPx)
        if reanchor {
            // Window move: no commit will come to publish a staged value, and
            // the cursor has not moved relative to its text.
            shared.shaderCursor.reanchor(rect: rect, gridId: owner)
        } else {
            shared.shaderCursor.stage(rect: rect, color: color, gridId: owner, by: self)
        }
    }

    /// Allocate the two ping-pong textures used by multi-pass custom
    /// shader chains applied to this external view's backTex.
    /// Shift the back texture's pixels for a committed row scroll, and report
    /// the band to clear plus the rows the caller must redraw. The arithmetic
    /// and its texture clamps are `RowScrollBlitPlan`'s, shared with the main
    /// surface: the rows a redraw owes are the vacated band AND the rows an
    /// intermediate step copied before a later one overwrote them, which this
    /// path used to leave stale in the back buffer.
    private func encodePendingScrollCopy(
        commandBuffer: MTLCommandBuffer,
        backTexture: MTLTexture,
        drawableWidthPx: Int,
        rowHeightPx: Int,
        scroll: SurfaceRowScroll
    ) -> RowScrollBlitPlan? {
        guard drawableWidthPx > 0, rowHeightPx > 0 else { return nil }
        guard let plan = RowScrollBlitPlan.make(
            rowStart: scroll.rowStart,
            rowEnd: scroll.rowEnd,
            rowsDelta: scroll.rowsDelta,
            widthPx: drawableWidthPx,
            textureWidthPx: backTexture.width,
            textureHeightPx: backTexture.height,
            rowHeightPx: rowHeightPx
        ) else { return nil }

        // One region, so the encoder starts nil and is ended straight after;
        // GridSurfaceRenderer passes its own across a whole layer loop.
        var blit: MTLBlitCommandEncoder? = nil
        guard encodeSurfaceRowScrollBlit(
            plan: plan,
            backTexture: backTexture,
            scratch: scrollScratch,
            device: mtlDevice,
            backBufferSize: backBufferSize,
            commandBuffer: commandBuffer,
            encoder: &blit
        ) else {
            blit?.endEncoding()
            return nil
        }
        blit?.endEncoding()

        return plan
    }

    /// The root rows a full-width scroll blit filled with hosted-layer pixels:
    /// every row a layer covers inside the scrolled region, and the rows those
    /// pixels were dragged into. The core's rule (`overBlitRows`), which the
    /// main surface's per-layer blit also asks; its `above` rows are not
    /// needed, since `drawHostedLayers` redraws every layer row while a
    /// scroll is pending. Appends without allocating while the caller's
    /// scratch keeps its capacity; a surface holds a handful of layers at most.
    private func appendRowsDraggedByLayers(
        into rows: inout [Int],
        plan: RowScrollBlitPlan,
        rowsDelta: Int,
        cellWidthPx: Int,
        rowHeightPx: Int
    ) {
        for entry in layerSnapshot {
            guard let over = layerOverBlitRows(
                plan: plan, rowsDelta: rowsDelta, layer: entry.layer,
                cellWidthPx: cellWidthPx, rowHeightPx: rowHeightPx
            ) else { continue }
            appendOverBlitUnderAndShiftedRows(over, into: &rows)
        }
    }




    func draw(in view: MTKView) {
        autoreleasepool {
            FrameTracer.trace(.drawBegin, seq: UInt32(truncatingIfNeeded: gridId))
            var finishedRedraw = false
            // The external draw logs nothing after it acquires its drawable,
            // so a stall inside it was indistinguishable from one outside it —
            // the main surface has `draw_total` and this one had nothing. Only
            // when a frame is already far too slow to be a frame, so the line
            // cannot become the thing it is measuring.
            let probeT0 = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
            // A repeat held over this view is disarmed from its own frames:
            // the main window may not be drawing at all.
            core?.keyInput.tickKeyRepeatSynthesis()
            defer {
                FrameTracer.trace(.drawEnd, seq: UInt32(truncatingIfNeeded: gridId))
                if !finishedRedraw {
                    redrawScheduler.didDrawFrame()
                }
                if probeT0 > 0 {
                    let ms = (CFAbsoluteTimeGetCurrent() - probeT0) * 1000
                    if ms > 40 {
                        ZonvieCore.appLog("[ext_draw_slow] gridId=\(gridId) ms=\(String(format: "%.1f", ms)) presented=\(finishedRedraw)")
                    }
                }
            }

            // Any surface can build the shared pipelines; this one used to
            // wait for the main window's next draw.
            guard shared.ensurePipelineReady(view: self),
                  let pipeline = shared.pipeline, let sampler = shared.sampler else {
                ZonvieCore.appLog("[ExternalGridView] Pipeline not ready")
                // Counted as idle, as on the main surface: a failed init
                // otherwise keeps the loop waking every vsync. The shared
                // resources wake every surface they turned away, on their
                // retry backoff or on another surface's successful build.
                notifyDrawIdle()
                return
            }

            // Nothing may be drawn while this window is not on screen.
            //
            // A window that is miniaturized or fully covered stops being
            // composited, so its CAMetalLayer never gets its presented
            // drawables back, and `currentDrawable` below then takes about
            // a second to return one — measured at 993ms and 1002ms (see
            // [perf] ext_acquire_drawable). It is a MAIN-thread call, so
            // that freezes the whole app: the main window's shader
            // animation, Neovim redraws and key event delivery all stop for
            // a second at a time, once per frame this view attempts.
            //
            // Only reachable since the animation exception below makes an
            // idle view attempt a frame every vsync; before that an idle
            // window parked its draw loop and never got here. Re-armed by the
            // occlusion observer in viewDidMoveToWindow, and by commitFlush on
            // any new content.
            //
            // Before the first present only a miniaturized window is
            // refused: parking on the lagging occlusionState would leave a
            // brand-new cmdline or popupmenu panel empty until the
            // notification lands, and a window with nothing on screen yet
            // has no stale content worth protecting.
            switch visibilityGate(unpresentedMayDraw: !hasEverPresented) {
            case .draw:
                break
            case .unsettled:
                ZonvieCore.appLog("[ext_draw_defer] gridId=\(gridId) occlusion not settled yet; skipping frame")
                requestRedraw()
                return
            case .hidden:
                ZonvieCore.appLog("[ext_draw_skip] gridId=\(gridId) window not visible; skipping frame")
                parkDrawLoopWhenHidden()
                return
            }

            if view.drawableSize.width <= 0 || view.drawableSize.height <= 0 {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) early return: drawableSize invalid (\(view.drawableSize))")
                return
            }

            // Preserve the last exact-size frame during interactive resize.
            // Returning before the semaphore/state snapshot leaves pending rows
            // untouched; viewDidEndLiveResize performs the single texture
            // recreation and full redraw for the final drawable size.
            if view.inLiveResize, backBuffer != nil, backBufferSize != view.drawableSize {
                redrawScheduler.didDrawFrame()
                finishedRedraw = true
                return
            }

            GridSurfaceRenderer.waitCommitGuardBand(
                lock: lock,
                commitRevision: { self.commitRevision },
                lastDrawnRevision: lastDrawnRevision,
                hadRecentCommit: { self.hadRecentCommit(withinNs: $0) },
                timedOutRevision: &guardBandTimedOutRevision,
                seq: UInt32(truncatingIfNeeded: gridId)
            )

            // GPU back-pressure: non-blocking tryWait, so the main thread
            // (which also runs input handling) never blocks on GPU completion.
            // GridSurfaceRenderer.draw() uses the same pattern.
            if inflightSemaphore.wait(timeout: .now()) != .success {
                // GPU still processing previous frame. Skip this draw but
                // schedule a retry so the frame is not permanently lost.
                FrameTracer.trace(.drawSkipSemaphore, seq: UInt32(truncatingIfNeeded: gridId))
                redrawScheduler.didDrawFrame()
                finishedRedraw = true
                DispatchQueue.main.async { [weak self] in
                    self?.requestRedraw()
                }
                return
            }
            // A frame the GPU failed left the back buffer undefined. Recorded
            // before the semaphore was signalled, so the frame after it cannot
            // get here first and `.load` it, as the main-queue hop allowed.
            lock.lock()
            let previousFrameFailed = gpuFrameFailed
            gpuFrameFailed = false
            lock.unlock()
            if previousFrameFailed { hasPresentedOnce = false }

            // --- Snapshot committed state under lock (same pattern as GridSurfaceRenderer) ---
            let csi: Int
            let cci: Int
            // Read with `csi`, under the lock: a cursor-only commit refreshes
            // the committed set's reference while a frame may be encoding it.
            let atlasTextureSnapshot: MTLTexture?
            let currentCommitRevision: UInt64
            let pendingScroll: SurfaceRowScroll?
            var submittedDirtyRows: [Int] = []

            let snappedCommittedExtent: SurfaceCommittedExtent
            let lastKnownCursorRowSnapshot: Int
            let cursorBlinkStateSnapshot: Bool
            let committedFontIsCurrent: Bool
            // The shader cursor's measured rect as of this commit. Taken under
            // the same hold as the committed set, because commitFlush publishes
            // it under that lock: the uniforms closure below evaluates THIS
            // value, not whatever a commit landing later in the frame put
            // there — which was a rect a row step ahead of the rows drawn.
            let cursorShaderRawSnapshot: SurfaceShaderCursor.Raw
            let scrollOffsetSnapshot: GridSurfaceRenderer.ScrollOffset?
            let hostedScrollOffsetSnapshot: [GridSurfaceRenderer.ScrollOffset]
            let cursorOwnerOffset: GridSurfaceRenderer.ScrollOffset?
            let cursorShaderOffsetPx: Float?
            /// The one evaluation moved the rect. Whole-surface fragment work,
            /// so a term of the idle gate — as on the main surface. Evaluated
            /// before the gate, a moved rect the gate then skipped was never
            /// asked for again: the next evaluation finds it already current.
            let shaderCursorMoved: Bool
            // Latched with the committed set, not read later: commitFlush
            // publishes the retention inside this same lock, so taking it
            // afterwards can pair set N's vertices with set N+1's retained
            // rows — the retained line drawn against pre-scroll content, which
            // is the duplicate the publish-on-commit rule exists to prevent.
            // (GridSurfaceRenderer already snapshots it under its lock.)
            let retainedSnapshot: [RetainedScrollRow]
            // commitFlush replaces committedSurfaceLayers wholesale under this
            // lock, so the root origin must be copied out here rather than read
            // later in the frame.
            let rootLayerOriginSnapshot: simd_float2
            let cursorOwnerSnapshot: Int64
            let cursorLayerOriginSnapshot: simd_float2
            let cursorLayerFollowsScrollSnapshot: Bool
            let cursorLayerAnchorGridSnapshot: Int64
            let layoutDamageSnapshot: Bool

            // Settle this frame's scroll state BEFORE the latch below, which is
            // where the main renderer settles its own (`onBeforeCommittedSnapshot`
            // ahead of its committed snapshot). External windows reuse the main
            // view's scroll offset storage but do not benefit from its onPreDraw
            // hook each frame.
            //
            // Ordering is the point, not the work: servicing afterwards let a
            // commit land in between and paired set N's rows and retained band
            // with set N+1's offset correction — a one-row jump mid-gesture. It
            // also ran `retention.clearPublished()` after the band had been
            // snapshotted, so a settled root still drew its stale retained rows.
            //
            // Settled against THIS surface's commit, the way the main renderer
            // settles against its own; shared with it. Returns with `lock` held.
            var hasScrollOffset = false
            // For the shader cursor's debt below: a follower follows only the
            // root (followsRootScroll). Read after serviceFrame, which lands a
            // pending grid_scroll and bumps the count, so it pairs with the
            // offset updateScrollShaderOffset publishes, as the body's
            // hostedFloatDebtPx does.
            var rootAnchorRowsUp = 0
            settleSurfaceAgainstOwnCommit(
                lock: lock,
                commitRevision: { self.commitRevision },
                service: {
                    self.core?.scrollModel.serviceFrame()
                    rootAnchorRowsUp = self.core?.scrollModel.anchorLandedRowsUpSnapshot(self.gridId) ?? 0
                    hasScrollOffset = self.updateScrollShaderOffset()
                }
            )
            if rowCapacity.blocksDraw {
                let terminal = rowCapacity.hardFailure
                lock.unlock()
                FrameTracer.trace(.drawSkipRowCapacity, seq: UInt32(truncatingIfNeeded: gridId))
                inflightSemaphore.signal()
                redrawScheduler.didDrawFrame()
                finishedRedraw = true
                // A hard failure is terminal and never cleared, so re-requesting
                // a draw only spins without ever presenting.
                if !terminal {
                    DispatchQueue.main.async { [weak self] in
                        self?.requestRedraw()
                    }
                }
                return
            }
            csi = committedSetIndex
            atlasTextureSnapshot = bufferSets[csi].atlasTextureSnapshot
            retainedSnapshot = retention.snapshotPublished()
            currentCommitRevision = commitRevision
            snappedCommittedExtent = committedExtent
            committedFontIsCurrent = fontResetState.isCurrent(
                committedGeneration: bufferSets[csi].fontGeneration
            )
            gpuInFlightCount[csi] += 1  // Prevent beginFlush from reusing this set
            // The cursor rotates on its own index, so it is snapshotted and
            // protected on its own: this frame may draw a cursor published
            // after the row set it draws it over.
            cci = committedCursorSetIndex
            cursorGpuInFlightCount[cci] += 1
            pendingScroll = pendingScrollAccum ?? bufferSets[csi].pendingScroll
            pendingScrollAccum = nil
            swap(&submittedDirtyRows, &submittedDirtyRowsScratch)
            submittedDirtyRows.removeAll(keepingCapacity: true)
            submittedDirtyRows.append(contentsOf: pendingDirtyRows)
            pendingDirtyRows.removeAll()
            lastKnownCursorRowSnapshot = cursorOwner.committedRootRow
            cursorShaderRawSnapshot = shared.shaderCursor.rawSnapshot()
            cursorBlinkStateSnapshot = blink.visibleLocked
            rootLayerOriginSnapshot = committedSurfaceLayers.first?.originPx ?? simd_float2(0, 0)
            layoutDamageSnapshot = pendingLayoutDamage
            pendingLayoutDamage = false
            // One read of the committed owner, used by everything this frame
            // places against it: the cursor body's origin, whether that origin
            // follows the scroll, and the shader effect that has to land on the
            // same cursor. Asking again later is how the body and the effect
            // came to answer different flushes.
            cursorOwnerSnapshot = cursorOwner.committed ?? gridId
            // One resolve where this was three scans of the same list for
            // three fields of the same entry — which is also what keyed the
            // float ledger by the pair (float, its anchor).
            let cursorPlacement = resolveSurfaceCursorPlacement(
                ownerGridId: cursorOwnerSnapshot,
                rootGridId: gridId,
                layers: committedSurfaceLayers
            )
            cursorLayerOriginSnapshot = cursorPlacement.originPx
            cursorLayerFollowsScrollSnapshot = cursorPlacement.followsScroll
            cursorLayerAnchorGridSnapshot = cursorPlacement.anchorGrid
            layerSnapshot.removeAll(keepingCapacity: true)
            // Latched HERE, with the placements it describes. Read anywhere
            // else it is a commit out of step with them: the counter is copied
            // before the flush that publishes a placement and this snapshot is
            // taken after it, which is the skew the main surface had.
            placementRowsUpSnapshot.removeAll(keepingCapacity: true)
            for (layerGridId, rows) in layerPlacementRowsUp {
                placementRowsUpSnapshot[layerGridId] = rows
            }
            for layer in committedSurfaceLayers where layer.gridId != gridId {
                if let sets = gridBuffers.existingSets(for: layer.gridId) {
                    // This surface keeps no per-layer draw state, so every
                    // entry owes everything.
                    layerSnapshot.append(SurfaceLayerFrame(layer: layer, set: sets[csi], state: nil))
                }
            }
            // The displacements this frame draws with, latched with the rows
            // and the cursor rect they belong to. Only this thread writes
            // them, so reading them here rather than at the passes below
            // changes nothing about their value — only that the shader cursor
            // can be evaluated against them now, under the same hold, which
            // is the point the main renderer evaluates at too.
            // More fixed floats than the mask can hold drops the whole scroll
            // transform for the frame, as the main surface does: a partial
            // mask lets shifted content bleed through an omitted float, and
            // clearing the mask alone left every offset applied unmasked.
            let fixedFloatOverflow = SurfaceFixedFloatMask.overflows(layers: committedSurfaceLayers, rootGridId: gridId)
            drewWithoutScrollTransform = fixedFloatOverflow
            scrollOffsetSnapshot = scrollOffsetLatch.isActive && !fixedFloatOverflow ? scrollOffsetData : nil
            hostedScrollOffsetSnapshot = fixedFloatOverflow ? [] : hostedScrollOffsetData  // Value-type copy
            // And no retained rows: they are drawn only beside an offset that
            // places them, and without one they land unshifted and unclipped.
            if fixedFloatOverflow { hasScrollOffset = false }
            // What displaces the cursor's own grid, resolved exactly as
            // drawHostedLayers resolves a layer's: its own offset when it is
            // scrolling in its own right, the root's when it merely follows,
            // and nothing at all when it stands still. The body and the cursor
            // have to answer the same offset or they are drawn a row apart.
            let cursorOwnOffset = surfaceScrollOffset(gridId: cursorOwnerSnapshot, offsets: hostedScrollOffsetSnapshot)
            let cursorFollowsRoot = cursorOwnerSnapshot != gridId && cursorOwnOffset == nil
                && followsRootScroll(anchorGrid: cursorLayerAnchorGridSnapshot, followsScroll: cursorLayerFollowsScrollSnapshot)
            cursorOwnerOffset = cursorOwnerSnapshot == gridId
                ? scrollOffsetSnapshot
                : (cursorOwnOffset ?? (cursorFollowsRoot ? scrollOffsetSnapshot : nil))
            // Shared with GridSurfaceRenderer. The height is the one every
            // NDC above was built against, latched beside them rather than
            // recomputed on a cell size the core may have moved since. A
            // follower's effect carries its debt, as its body does and as the
            // main surface folds it into offset_y.
            var cursorShaderOffset = cursorOwnerOffset
            if cursorFollowsRoot, var followed = cursorShaderOffset, scrollOffsetViewportHeight > 0 {
                let debtPx = hostedFloatDebtPxLocked(
                    gridId: cursorOwnerSnapshot,
                    anchorRowsUp: rootAnchorRowsUp,
                    cellHeightPx: Float(shared.cellHeightPx)
                )
                followed.offset_y -= debtPx * 2 / scrollOffsetViewportHeight
                cursorShaderOffset = followed
            }
            cursorShaderOffsetPx = surfaceShaderCursorOffsetPx(
                rawGridId: cursorShaderRawSnapshot.gridId,
                ownerGridId: cursorOwnerSnapshot,
                offset: cursorShaderOffset,
                viewportHeightPx: scrollOffsetViewportHeight
            )
            shaderCursorMoved = shared.shaderCursor.evaluate(
                scrollOffsetPx: cursorShaderOffsetPx, raw: cursorShaderRawSnapshot)
            lock.unlock()
            defer {
                submittedDirtyRows.removeAll(keepingCapacity: true)
                swap(&submittedDirtyRows, &submittedDirtyRowsScratch)
            }

            // Snapshot the previous-frame gate state BEFORE draw() overwrites
            // it (blink.lastRendered at the blink-detection line,
            // lastDrawnRevision right after hasNewCommit is computed), so the
            // bail helper below can roll both back — mirrors the
            // prevDrawnRevision/prevRenderedBlinkState rollback in
            // GridSurfaceRenderer.bailWithoutSubmit.
            let prevDrawnRevision = lastDrawnRevision
            let prevRenderedBlinkState = blink.lastRendered

            // Restores state consumed above and schedules a retry when a later
            // resource acquisition fails (back buffer / command buffer / drawable).
            // Restoring the rows alone is NOT enough: by the time the loss sites
            // run, lastDrawnRevision has already been overwritten below, so a
            // retry draw would compute hasNewCommit == false and take the idle
            // early-exit, re-consuming and discarding the restored rows. Rolling
            // lastDrawnRevision (and blink.lastRendered) back makes the retry
            // draw see the commit as new again.
            // restoreScroll: pass false when the scroll blit has ALREADY been
            // committed into backTex (the drawable-nil site) — re-queueing the
            // scroll there would double-shift the already-shifted pixels.
            /// Put back what this draw consumed, so a retry heals it.
            ///
            /// Restores EXACTLY that: the rows it submitted, the flags it
            /// cleared, the scroll it took. GridSurfaceRenderer restores a
            /// superset instead — every row dirty and every layer needing a
            /// full redraw. Two policies for one job, unmeasured against each
            /// other because the path runs only when a draw gives up, which no
            /// scenario provokes.
            func bailWithoutSubmit(_ reason: String, restoreScroll: Bool = true) {
                ZonvieCore.appLog("[WARNING][ExternalGridView] draw bailed (\(reason)); restoring dirty state for retry gridId=\(gridId)")
                lock.lock()
                // Element-wise: IndexSet(submittedDirtyRows) would allocate on
                // a bail path that already failed to acquire what it needed.
                for r in submittedDirtyRows { pendingDirtyRows.insert(r) }
                if layoutDamageSnapshot { pendingLayoutDamage = true }
                if restoreScroll, let scroll = pendingScroll {
                    if let existing = pendingScrollAccum,
                       existing.rowStart == scroll.rowStart,
                       existing.rowEnd == scroll.rowEnd {
                        // A concurrent flush installed a NEW accum for the same
                        // region while this draw was in progress — merge the
                        // deltas rather than dropping either side, using the
                        // same merge logic as applyRowScroll's accumulation.
                        pendingScrollAccum = SurfaceRowScroll(
                            rowStart: existing.rowStart, rowEnd: existing.rowEnd,
                            colStart: existing.colStart, colEnd: existing.colEnd,
                            rowsDelta: clampRowsDelta(existing.rowsDelta &+ scroll.rowsDelta),
                            totalRows: existing.totalRows, totalCols: existing.totalCols
                        )
                    } else if pendingScrollAccum == nil {
                        pendingScrollAccum = scroll
                    }
                    // else: a concurrent flush installed an accum for a
                    // DIFFERENT region — keep the newer one. The restored dirty
                    // rows plus the revision rollback force a redraw that heals
                    // the un-applied older shift via row regeneration.
                }
                lock.unlock()
                lastDrawnRevision = prevDrawnRevision
                blink.lastRendered = prevRenderedBlinkState
                finishedRedraw = true
                redrawScheduler.didDrawFrame()
                DispatchQueue.main.async { [weak self] in
                    self?.requestRedraw()
                }
            }

            // Safety defer: decrement gpuInFlight and signal semaphore on early return.
            // On normal GPU submission, the completion handler handles cleanup.
            var gpuSubmitted = false

            // What this frame owes back whether it reaches the screen or not:
            // the row set and cursor slot it read, and the in-flight slot it
            // took. Stated once, the way GridSurfaceRenderer states it, and
            // used by the defer below and by every path that commits encoded
            // work it will not present. It used to be written out at six sites.
            //
            // `self` weakly so an abandoned frame does not keep the view alive;
            // the lock and semaphore strongly so the release still runs when it
            // is already gone.
            let sem = inflightSemaphore
            let tbLock = lock
            let releaseFrameState: () -> Void = { [weak self] in
                tbLock.lock()
                self?.completeSurfaceFrameReadLocked(rowSet: csi, cursorSlot: cci)
                tbLock.unlock()
                sem.signal()
            }
            defer {
                if !gpuSubmitted { releaseFrameState() }
            }

            let committed = bufferSets[csi]
            // The cursor this frame draws, held against reuse by the in-flight
            // count taken with it. Its slot is independent of `committed`.
            let committedCursor = cursorSlots[cci]
            let rowMode = committed.rowState.usingRowBuffers
            // Use committed grid dimensions (snapped at commitFlush) to guarantee
            // viewport matches the NDC coordinates baked into committed vertices.
            // Same approach as GridSurfaceRenderer's committedDrawableW/H.
            // The core bakes NDC with grid_h = viewport_rows * cellH, so the
            // Metal viewport height MUST match viewport_rows exactly. If
            // viewport_rows exceeds drawable rows (e.g. sg.rows=45 with winbar
            // but window fits 44), Metal clips to the render target bounds
            // automatically — the NDC mapping stays correct for visible rows.
            let (snapGridCols, snapGridRows) = snappedCommittedExtent.resolved(
                liveWidth: gridCols,
                liveHeight: gridRows
            )
            // External grids are row-mode only: the core reaches them through
            // on_vertices_row, and the ABI has no whole-surface callback.
            if !rowMode {
                return
            }
            if committed.rowState.buffers.isEmpty {
                return
            }

            let blinkStateChanged = cursorBlinkStateSnapshot != blink.lastRendered
            blink.lastRendered = cursorBlinkStateSnapshot

            let drawableSizeChanged = surfaceDrawableSizeChanged(
                backBufferSize: backBuffer == nil ? nil : backBufferSize,
                drawableSize: view.drawableSize
            )
            let hasNewCommit = currentCommitRevision != lastDrawnRevision
            lastDrawnRevision = currentCommitRevision
            // Content questions, asked of content. They used to be gated on
            // `hasNewCommit` because a cursor-only commit did not bump; now that
            // every commit does, the gate would make them true for frames that
            // changed nothing.
            let hasDirtyContent = !submittedDirtyRows.isEmpty
            let hasPendingScroll = pendingScroll != nil

            // `hasScrollOffset` was settled with the rest of this frame's scroll
            // state ahead of the latch, so the offset the shader applies belongs
            // to the set this frame draws.
            let scrollOffsetChanged = hasScrollOffsetStateChangedSinceLastPresent()
            // Under `lock` because both halves of the latch cross threads here:
            // `updateScrollShaderOffset` sets the live one and
            // `markScrollOffsetStatePresented` moves it into the previous frame.
            lock.lock()
            let smoothScrolling = scrollOffsetLatch.isSmoothScrolling
            lock.unlock()

            // Early exit: nothing changed. A cursor submit is published by a
            // commit, and every commit bumps commitRevision under the lock,
            // so hasNewCommit alone forces the cursor recheck (a separate
            // cursor flag could only ever be true alongside it).

            // Animation exception mirrors GridSurfaceRenderer: when a
            // loaded custom shader references iTime / iFrame / etc., we
            // must proceed every frame and keep this view's draw loop
            // active, even with no Neovim-side changes. Without this,
            // popupmenu / messages / cmdline / ext-window background stays
            // frozen while the main window animates.
            let shaderAnimates = shared.anyCustomShaderNeedsAnimation
            if shaderAnimates {
                activateSurfaceDrawLoop()
            }

            // Keep the draw loop alive while this grid's edge bounce is held
            // or animating, so the bounce-back keeps ticking after input
            // events stop (serviceSharedScrollStateForExternalView above is
            // what advances the animation).
            if core?.scrollModel.isScrollEdgeBounceActive(gridId: gridId) == true {
                activateSurfaceDrawLoop()
            }

            // Same for the sub-row ease: the last step of a scroll produces no
            // further flushes, so without this the animation stops on whatever
            // frame the input happened to end on.
            if core?.scrollModel.isSmoothScrollActive(gridId: gridId) == true {
                activateSurfaceDrawLoop()
            }

            // Shared with GridSurfaceRenderer: SurfaceIdleTerms holds every
            // term either surface has, and this surface's missing ones (a
            // dirty rect, per-layer work) stay at defaults that cannot block a
            // skip.
            let idleTerms = SurfaceIdleTerms(
                hasPresentedOnce: hasPresentedOnce,
                rowModeSatisfied: rowMode,
                hasNewCommit: hasNewCommit,
                hasDirtyRows: hasDirtyContent,
                // Layout damage is the whole surface owing a redraw that no
                // row expresses. It came only with a commit until a
                // background change could raise it between commits.
                hasDirtyRect: layoutDamageSnapshot,
                hasStagedScroll: hasPendingScroll,
                scrollOffsetChanged: scrollOffsetChanged,
                isSmoothScrolling: smoothScrolling,
                blinkStateChanged: blinkStateChanged,
                drawableSizeChanged: drawableSizeChanged,
                shaderAnimates: shaderAnimates,
                shaderCursorMoved: shaderCursorMoved
            )
            let idleGateSkips = idleTerms.skipsFrame
            ZonvieCore.drawTrace(idleTerms.traceLine(surface: gridId))
            if idleGateSkips {
                FrameTracer.trace(.drawSkipNoChange, a: 2, seq: UInt32(truncatingIfNeeded: gridId))
                ZonvieCore.appLog("[ext_draw_early_exit] gridId=\(gridId) idle")
                notifyDrawIdle()
                return
            }
            notifyDrawActive()

            // The main surface's blink gate. Measured on two idle external
            // windows over 25 s with the cursor parked in the main window: 118
            // such frames, and the count scales with the number of open
            // surfaces. A commit that moved the cursor AWAY from here leaves
            // `vertexCount` at 0 while still owing the frame that erases it;
            // `isBlinkOnly` refuses on that commit. `blink.lastRendered` was
            // already advanced above, so the toggle is acknowledged either way.
            let blinkOnlyWithNoCursor = idleTerms.skipsBlinkWithNoCursor(
                cursorVertexCount: committedCursor.vertexCount)
            ZonvieCore.drawTrace(
                "surface=\(gridId) gate=blinkNoCursor blinkOnly=\(idleTerms.isBlinkOnly ? 1 : 0)"
                    + " cursorVerts=\(committedCursor.vertexCount > 0 ? 1 : 0)"
                    + " anim=\(shaderAnimates ? 1 : 0)"
                    + " -> \(blinkOnlyWithNoCursor ? "skip" : "draw")"
            )
            if blinkOnlyWithNoCursor {
                FrameTracer.trace(.drawSkipNoChange, a: 4, seq: UInt32(truncatingIfNeeded: gridId))
                ZonvieCore.appLog("[ext_draw_early_exit] gridId=\(gridId) blink-no-cursor")
                notifyDrawIdle()
                return
            }

            // Cell dimensions — integer-rounded, same formula as GridSurfaceRenderer.
            let cw = Float(shared.cellWidthPx)
            let ch = Float(shared.cellHeightPx)
            let cellWi = max(1, UInt32(cw.rounded(.up)))
            let cellHi = max(1, UInt32(ch.rounded(.up)))
            // Viewport: grid-rows based (NOT drawable-based). An external
            // grid's viewport_rows may differ from drawableH / cellH, and the
            // core bakes NDC with grid_h = viewport_rows * cellH.
            let vpWidth = Double(snapGridCols) * Double(cellWi)
            let vpHeight = Double(snapGridRows) * Double(cellHi)
            let scale = backingScale
            let vpOriginX = Double(viewportOriginPx.x) * Double(scale)
            let vpOriginY = Double(viewportOriginPx.y) * Double(scale)
            // The root layer drives the pixel space core vertices arrive in.
            let rootLayerOrigin = rootLayerOriginSnapshot
            let viewportMetrics = SurfaceViewportMetrics(
                viewportWidth: vpWidth,
                viewportHeight: vpHeight,
                drawableSize: view.drawableSize,
                originX: vpOriginX,
                originY: vpOriginY,
                layerOriginPx: rootLayerOrigin
            )

            // The shader chain is not loaded yet when this view is built, so
            // the alpha convention its back texture needs can only be settled
            // here, per draw.
            let backgroundAlpha = surfaceBackgroundAlpha()

            // The union this surface's scrolled content must not bleed over.
            // Same rule the main renderer applies to its own layers, and it is
            // only meaningful while a scroll is easing — with no offset there is
            // nothing displaced to discard. A layer's originPx is already
            // surface-absolute, so the rectangle needs no further placement.
            fixedFloatMask.rebuild(
                layers: layerSnapshot, rootGridId: gridId, smoothScrolling: smoothScrolling,
                cellW: Float(shared.cellWidthPx), cellH: Float(ch), scratch: &fixedFloatRectsScratch
            )

            // Glow disables partial-redraw optimizations to prevent additive
            // bloom composite from accumulating brightness.
            let glowEnabled = SurfaceFixedFloatMask.permitsGlow(
                configured: core?.isGlowEnabled() ?? false, smoothScrolling: smoothScrolling,
                bands: fixedFloatMask.bands)

            let use2Pass = blurEnabled && shared.backgroundPipeline != nil && shared.glyphPipeline != nil

            // Whether a scroll blit MAY run this frame. `useGpuScrollCopy`
            // below is whether one DID, which is what the load action and
            // the row-pass plan ask; the main surface has always answered
            // them from the outcome, and this surface used to hand them the
            // permission under the same name.
            let mayGpuScrollCopy = rowMode
                && !layoutDamageSnapshot
                && committedFontIsCurrent
                && pendingScroll != nil
                && !isDecoratedSurface
                && SurfaceScrollBlitGate(
                    hasPresentedOnce: hasPresentedOnce,
                    smoothScrolling: smoothScrolling,
                    drawableSizeChanged: drawableSizeChanged,
                    hasNewCommit: hasNewCommit,
                    glowEnabled: glowEnabled,
                    blurEnabled: blurEnabled,
                    useTwoPass: use2Pass
                ).refusal == nil

            // Row state resolution.
            // A stale set may stay GPU in-flight and must remain immutable.
            // Suppress it logically instead of clearing its row counts.
            let safeRowCount = rowMode && committedFontIsCurrent
                ? committed.rowLogicalToSlot.count
                : 0

            func resolvedRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow < safeRowCount else { return nil }
                // The resolver this surface's hosted layers use: the root is a
                // grid of this surface like they are.
                return resolveSurfaceGridRow(committed, row: logicalRow, cellHeightPx: Float(cellHi))
            }

            // Rows retained across a smooth-scroll step are drawn as virtual
            // rows past the end of the grid, so the existing row encoder
            // covers them without a separate encode path. Each is translated
            // back to the edge it left through; the shader then applies this
            // grid's scroll offset like any other row, and the existing
            // content clip discards the part outside the window.
            //
            // Gated on hasScrollOffset, not smoothScrolling: both the offset
            // shift and the content clip come from this grid's ScrollOffset
            // entry, matched by grid_id in the vertex shader. On the settle's
            // final frame the offset resolves to nil (smoothScrolling stays
            // true through the latch's previous frame), so a
            // retained row drawn then matches no entry and lands unshifted
            // and UNCLIPPED at its targetRow — which sits in the margin rows
            // above the content edge it left through. With no offset the band
            // is closed and every real row is drawn on the cell grid, so
            // there is nothing for a retained row to cover.
            let retainedRows = hasScrollOffset ? retainedSnapshot : []
            let retainedRowBase = safeRowCount
            let smoothRowRange = 0..<(safeRowCount + retainedRows.count)
            // Shared with GridSurfaceRenderer; this surface's root is its own grid.
            func resolvedSmoothRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                resolveSurfaceSmoothRow(
                    logicalRow: logicalRow,
                    retainedRowBase: retainedRowBase,
                    retainedRows: retainedRows,
                    rootGridId: gridId,
                    cellHeightPx: Int(cellHi),
                    resolveRow: resolvedRowState
                )
            }

            // --- Ensure back buffer ---
            ensureBackBuffer(drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat)
            guard let backTex = backBuffer else {
                bailWithoutSubmit("no backbuffer")
                return
            }

            guard let cmd = queue.makeCommandBuffer() else {
                bailWithoutSubmit("command buffer creation failed")
                return
            }

            // Register this read, snapshot the committed atlas texture, and
            // encode a GPU-side wait for the latest blit generation, all as
            // one atomic step under GlyphAtlas's gate lock — see
            // beginExternalRead's doc comment for why splitting these into
            // separate registration/snapshot/wait-encode calls leaves a gap a
            // writer's blit can land in. Must happen before any encoder that
            // samples the atlas is created (encodeWaitForEvent cannot be issued
            // while an encoder is open).
            //
            // Bound to a local so the completion handlers below capture the
            // shared object and not this view: a [weak self] capture would
            // silently skip endExternalRead() if the view is deallocated before
            // the GPU completion fires, leaking the matching enter() forever
            // and wedging the gate (every future beginAtlasWrite() would time
            // out waiting for a read that will never leave). This used to reach
            // `mainTerminalView?.renderer`, which is why an external surface
            // could not draw at all without the main window's renderer alive.
            let atlasReader = shared
            // `guard let` rather than a plain guard: nil means no read was
            // registered, so the downstream `if let tex = atlasTex` gates become
            // compile errors rather than dead conditionals that would
            // over-release the DispatchGroup.
            guard let atlasTex = atlasReader.beginExternalRead(commandBuffer: cmd, snapshot: { atlasTextureSnapshot }) else {
                // A pending writer intentionally rejects new reader admission
                // until already-in-flight readers drain. Commit the otherwise
                // empty command buffer for prompt driver resource release, then
                // retain this frame's dirty state for the writer retry.
                cmd.commit()
                bailWithoutSubmit("atlas reader admission deferred")
                return
            }

            // The same release, plus the atlas read this frame registered.
            // Every bail past this point owes both; before it, only the defer's
            // copy applies, because no read exists yet to end.
            let releaseAbandonedFrame: () -> Void = {
                releaseFrameState()
                atlasReader.endExternalRead()
            }

            // --- GPU scroll blit (shift pixels in back buffer) ---
            // A root scroll without pixel copy requires full redraw. Any content
            // change without a root scroll — hosted or the root's own rows —
            // can use its surface damage bands without moving retained pixels.
            var scrollClearBand: (clearTopPx: Int, clearBottomPx: Int)? = nil
            var dirtyRows: [Int] = []
            swap(&dirtyRows, &dirtyRowsScratch)
            dirtyRows.removeAll(keepingCapacity: true)
            if mayGpuScrollCopy || !hasPendingScroll {
                dirtyRows.append(contentsOf: submittedDirtyRows)
            }
            var useGpuScrollCopy = false
            defer {
                dirtyRows.removeAll(keepingCapacity: true)
                swap(&dirtyRows, &dirtyRowsScratch)
            }
            if mayGpuScrollCopy, let scroll = pendingScroll {
                let scrollCopy = encodePendingScrollCopy(
                    commandBuffer: cmd,
                    backTexture: backTex,
                    drawableWidthPx: Int(vpWidth > 0 ? vpWidth : view.drawableSize.width),
                    rowHeightPx: Int(cellHi),
                    scroll: scroll
                )
                if let scrollCopy {
                    useGpuScrollCopy = true
                    scrollClearBand = (
                        clearTopPx: scrollCopy.clearTopPx,
                        clearBottomPx: scrollCopy.clearBottomPx
                    )
                    dirtyRows.append(contentsOf: scrollCopy.dirtyRows)
                    // A hosted layer's pixels sit inside the rectangle this blit
                    // moved: the copy is the surface's full width and cannot tell
                    // them from the root's. They landed `rowsDelta` rows against
                    // the scroll, so the root rows they were dragged into hold
                    // layer pixels now — redraw those from the root's vertices,
                    // and the rows they came from as well, since a layer off the
                    // cell grid straddles a row boundary at both ends. Each layer
                    // then puts itself back on top: `drawHostedLayers` redraws
                    // every row of it while a scroll is pending.
                    appendRowsDraggedByLayers(
                        into: &dirtyRows,
                        plan: scrollCopy,
                        rowsDelta: scroll.rowsDelta,
                        cellWidthPx: Int(cellWi),
                        rowHeightPx: Int(cellHi)
                    )
                } else {
                    // The blit never ran (scratch texture or blit encoder
                    // creation failed, or a degenerate copy height — see
                    // encodePendingScrollCopy's guard clauses), so the back
                    // texture's pixels were never shifted for this scroll.
                    // submittedDirtyRows only covers the vacated band on the
                    // assumption the blit succeeded; every other row in the
                    // scroll region would otherwise keep its stale,
                    // un-shifted content forever (the core never re-sends
                    // rows it only expects the frontend to visually shift).
                    // Mark the whole scroll region dirty so the per-row
                    // scissor draw below fully overwrites it from the
                    // already-remapped row slots' vertex data.
                    // Keep expansion linear in the scroll-region height; the
                    // combined rows are canonicalized below.
                    if let stale = RowScrollBlitPlan.dirtyRowsWithoutBlit(
                        rowStart: scroll.rowStart,
                        rowEnd: scroll.rowEnd,
                        textureHeightPx: backTex.height,
                        rowHeightPx: Int(cellHi)
                    ) {
                        dirtyRows.append(contentsOf: stale)
                    }
                }
            }
            // Always, not only for a scroll copy. Three consumers below draw
            // one row per entry, so a duplicate is a redundant draw, and the
            // hosted-layer band loop turns each entry into a scissor+encode —
            // where duplicates and out-of-order entries cost the most. The
            // compaction only shortens the array in place, so this adds no
            // heap work to the frame.
            surfaceSortAndDeduplicateRows(&dirtyRows)
            if let scroll = pendingScroll {
                ZonvieCore.appLog("[ext_scroll_draw] gridId=\(gridId) delta=\(scroll.rowsDelta) rows=\(scroll.rowStart)..<\(scroll.rowEnd) may=\(mayGpuScrollCopy) used=\(useGpuScrollCopy) newCommit=\(hasNewCommit) layout=\(layoutDamageSnapshot) font=\(committedFontIsCurrent) presented=\(hasPresentedOnce) smooth=\(smoothScrolling) size=\(drawableSizeChanged) submitted=\(submittedDirtyRows.count) dirty=\(dirtyRows.count) rev=\(currentCommitRevision)")
            }

            // --- Render into back buffer ---
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = backTex
            rpd.colorAttachments[0].storeAction = .store

            // loadAction logic — match GridSurfaceRenderer. A cursor-only frame
            // keeps the back buffer through reuseRootContents/reuseHostedContents,
            // which, like the main surface's skipMainPass, refuse while an ease
            // holds an offset.
            let hasAnyDirtyInRowMode = rowMode && !dirtyRows.isEmpty
            // The cursor is composited after the retained texture. A pure
            // blink needs no root or hosted-row draw, including under blur.
            // An animating shader is no reason to redraw either: its chain
            // only reads the retained texture, which is what the main surface
            // hands it on a frame with no main work.
            let reuseHostedContents = rowMode && !layerSnapshot.isEmpty
                && committedFontIsCurrent && hasPresentedOnce
                && !layoutDamageSnapshot && !hasDirtyContent
                && !hasPendingScroll && !drawableSizeChanged && !scrollOffsetChanged
                && !smoothScrolling && !glowEnabled
                && !isDecoratedSurface
            // Same deal without hosted layers: the cursor lives on the
            // drawable, not the back texture, so a frame with no root row to
            // draw — a cursor move, a blink toggle, an animating shader's
            // next frame — keeps every row. Without this the branch ladder
            // below falls through to the full-redraw arm, where the main
            // surface skips its whole pass (GridSurfaceRenderer's
            // noMainWorkFrame asks the same question).
            let reuseRootContents = rowMode && layerSnapshot.isEmpty
                && dirtyRows.isEmpty && committedFontIsCurrent && hasPresentedOnce
                && !layoutDamageSnapshot && !hasDirtyContent && !hasPendingScroll
                && !drawableSizeChanged && !scrollOffsetChanged
                && !smoothScrolling && !glowEnabled
                && !isDecoratedSurface
            let partialHostedContents = rowMode && !layerSnapshot.isEmpty
                && !dirtyRows.isEmpty && committedFontIsCurrent && hasPresentedOnce
                && !layoutDamageSnapshot && !hasPendingScroll && !drawableSizeChanged
                && !scrollOffsetChanged && !smoothScrolling
                && !glowEnabled && !isDecoratedSurface
                // Under blur the recompose is only safe as the two passes the
                // root uses: the background pass overwrites, so a band redrawn
                // over `.load` cannot accumulate alpha. Fail closed to a full
                // redraw if those pipelines could not be created.
                && (!blurEnabled || use2Pass)
            if partialHostedContents {
                ZonvieCore.renderTrace("event=hosted_partial surface=\(gridId) dirty_rows=\(dirtyRows.count)")
            }
            // Blur can still redraw dirty-only with .load because the 2-pass
            // background pass overwrites, so alpha does not accumulate — that
            // avoids a full redraw on every content update under blur.
            let canDirtyOnlyWithBlur = SurfaceLoadActionTerms.dirtyOnlyWithBlur(
                rowMode: rowMode,
                useTwoPass: use2Pass,
                hasDirtyRowsInRowMode: hasAnyDirtyInRowMode,
                hasPresentedOnce: hasPresentedOnce,
                isSmoothScrolling: smoothScrolling,
                drawableSizeChanged: drawableSizeChanged,
                glowEnabled: glowEnabled
            )
            // Decorated surfaces (ext-cmdline) always clear: their viewport origin offset
            // means scissor rects for partial redraw don't align correctly.
            // Shared with GridSurfaceRenderer: SurfaceLoadActionTerms holds
            // every guard and arm either surface has. This surface has no
            // dirty-rect state, so that term stays at its default.
            let loadTerms = SurfaceLoadActionTerms(
                glowEnabled: glowEnabled,
                fontIsCurrent: committedFontIsCurrent,
                hasLayoutDamage: layoutDamageSnapshot,
                isDecoratedSurface: isDecoratedSurface,
                layersOutsideDirtySet: !layerSnapshot.isEmpty,
                useGpuScrollCopy: useGpuScrollCopy,
                canDirtyOnlyWithBlur: canDirtyOnlyWithBlur,
                reuseHostedContents: reuseHostedContents,
                reuseRootContents: reuseRootContents,
                partialHostedContents: partialHostedContents,
                hasDirtyRowsInRowMode: hasAnyDirtyInRowMode,
                isSmoothScrolling: smoothScrolling
            )
            let shouldReusePreviousContents = loadTerms.reusesPreviousContents
            ZonvieCore.drawTrace(loadTerms.traceLine(surface: gridId))
            rpd.colorAttachments[0].loadAction = resolveSurfaceColorLoadAction(
                blurEnabled: blurEnabled,
                hasPresentedOnce: hasPresentedOnce,
                drawableSizeChanged: drawableSizeChanged,
                shouldReusePreviousContents: shouldReusePreviousContents,
                forceReusePreviousContents: loadTerms.forcesReusePreviousContents
            )
            rpd.colorAttachments[0].clearColor = makeSurfaceClearColor(
                bgRGB: surfaceBgRGB,
                clearAlpha: surfaceClearAlpha
            )

            // `scrollOffsetSnapshot`, `hostedScrollOffsetSnapshot` and
            // `cursorOwnerOffset` were latched with the committed snapshot
            // above, so the cursor and glow passes below can use them even on
            // a frame that encodes no surface pass.
            // Placed as the body of the grid it sits on, or the cursor and its
            // rows are drawn rows apart.
            let cursorDrawOrigin = hostedDrawOriginPx(
                originPx: cursorLayerOriginSnapshot,
                gridId: cursorOwnerSnapshot,
                anchorGrid: cursorLayerAnchorGridSnapshot,
                followsScroll: cursorLayerFollowsScrollSnapshot,
                ownOffset: surfaceScrollOffset(gridId: cursorOwnerSnapshot, offsets: hostedScrollOffsetSnapshot),
                rootOffset: scrollOffsetSnapshot,
                viewportHeightPx: viewportMetrics.fragmentHeight,
                cellHeightPx: Float(ch)
            )

            /// `glowPipeline` non-nil IS the glow pass. The caller binds it
            /// from the main renderer's `if let` chain, so passing it in keeps
            /// that proof instead of reaching back through `mainTerminalView`
            /// for a pipeline the enclosing scope already holds.
            func drawHostedLayers(_ encoder: MTLRenderCommandEncoder, glowPipeline: MTLRenderPipelineState? = nil) {
                let glow = glowPipeline != nil
                guard committedFontIsCurrent else { return }
                let extent = simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)
                for entry in layerSnapshot {
                    let layer = entry.layer
                    guard let set = entry.set else { continue }
                    let rows = min(layer.rows, set.rowLogicalToSlot.count)
                    guard rows > 0 else { continue }
                    // The shader displaces the rows of a layer with an offset of
                    // its own, clipped to its content bounds; a follower moves
                    // bodily — the main window's per-row offset vs `move_all`
                    // split. Either way clip and geometry share one space.
                    let layerOffset = surfaceScrollOffset(
                        gridId: layer.gridId, offsets: hostedScrollOffsetSnapshot)
                    let origin = hostedDrawOriginPx(
                        originPx: layer.originPx,
                        gridId: layer.gridId,
                        anchorGrid: layer.anchorGrid,
                        followsScroll: layer.followsScroll,
                        ownOffset: layerOffset,
                        rootOffset: scrollOffsetSnapshot,
                        viewportHeightPx: extent.y,
                        cellHeightPx: Float(ch)
                    )
                    guard let scissor = makeSurfaceLayerScissor(
                        originPx: origin,
                        viewportOriginPx: simd_float2(Float(vpOriginX), Float(vpOriginY)),
                        cols: layer.cols, rows: rows,
                        cellWidthPx: Int(cellWi), cellHeightPx: Int(cellHi),
                        scale: glow ? 0.5 : 1,
                        targetWidth: glow ? max(1, backTex.width / 2) : backTex.width,
                        targetHeight: glow ? max(1, backTex.height / 2) : backTex.height
                    ) else { continue }
                    encoder.setScissorRect(scissor)
                    bindLayerTransform(encoder: encoder, LayerTransform(originPx: origin, extentPx: extent))
                    bindSingleSurfaceScrollOffset(encoder: encoder, offset: layerOffset)
                    // This layer's rows, then the rows its own smooth scroll
                    // retained, both in its grid-local space; the same
                    // resolution the main renderer's layer pass uses.
                    let retainedForLayerCount = collectSurfaceLayerRetainedRows(
                        gridId: layer.gridId,
                        retained: retainedSnapshot,
                        hasScrollOffset: layerOffset != nil,
                        cellHeightPx: Float(cellHi),
                        into: &retainedIndexScratch
                    )
                    let scratch = retainedIndexScratch
                    func resolveLayerRow(_ row: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                        resolveSurfaceLayerRow(
                            row,
                            set: set,
                            rowCount: rows,
                            retained: retainedSnapshot,
                            retainedIndices: scratch,
                            cellHeightPx: Float(cellHi)
                        )
                    }
                    if partialHostedContents && !glow {
                        // Recompose each dirty surface band back-to-front.
                        // Every layer is clipped to the band the root erased,
                        // so unchanged pixels are neither cleared nor blended.
                        var encodedRows = 0
                        // One band per RUN of contiguous dirty rows, not per
                        // row. A run's scissor is exactly the union of its
                        // rows' scissors, so the clipping is unchanged — but
                        // the layer row range each band expands to carries a
                        // row of padding at both ends for ink crossing a cell
                        // boundary, and per-row bands make neighbouring ranges
                        // overlap. Measured on an 8-row float over an external
                        // window with 8 dirty rows: 22 row draws per frame,
                        // 2.75x what drawing every row once would cost.
                        var runStart = 0
                        while runStart < dirtyRows.count {
                            var runEnd = runStart
                            while runEnd + 1 < dirtyRows.count,
                                  dirtyRows[runEnd + 1] == dirtyRows[runEnd] + 1 {
                                runEnd += 1
                            }
                            let firstRow = dirtyRows[runStart]
                            let lastRow = dirtyRows[runEnd]
                            runStart = runEnd + 1
                            let top = max(scissor.y, firstRow * Int(cellHi))
                            let bottom = min(scissor.y + scissor.height, (lastRow + 1) * Int(cellHi))
                            guard top < bottom else { continue }
                            encoder.setScissorRect(MTLScissorRect(x: scissor.x, y: top,
                                width: scissor.width, height: bottom - top))
                            let first = max(0, Int(floor((Float(top) - origin.y) / Float(cellHi))) - 1)
                            let end = min(rows, Int(ceil((Float(bottom) - origin.y) / Float(cellHi))) + 1)
                            guard first < end else { continue }
                            encodedRows += encodeSurfaceRowDraws(encoder: encoder, rows: first..<end,
                                resolve: { resolveSurfaceGridRow(set, row: $0, cellHeightPx: Float(cellHi)) },
                                pipeline: pipeline, backgroundPipeline: shared.backgroundPipeline,
                                glyphPipeline: shared.glyphPipeline, useTwoPass: use2Pass,
                                unifiedBlurPipeline: shared.unifiedBlurPipeline)
                        }
                        logHostedLayerDraw(layer: layer, encodedRows: encodedRows, of: rows, drawOriginPx: origin, bodilyMoved: origin != layer.originPx)
                        continue
                    }
                    // A glyph hidden behind a float here must not bloom
                    // through it, over the same rows the extract draws,
                    // retained ones included.
                    if let glowPipeline {
                        encodeSurfaceLayerGlowRows(
                            encoder: encoder,
                            rows: 0..<(rows + retainedForLayerCount),
                            resolve: resolveLayerRow,
                            occludePipeline: shared.glowOccludePipeline,
                            extractPipeline: glowPipeline
                        )
                        continue
                    }
                    let encodedRows = encodeSurfaceRowDraws(
                        encoder: encoder, rows: 0..<(rows + retainedForLayerCount),
                        resolve: resolveLayerRow,
                        pipeline: pipeline,
                        backgroundPipeline: shared.backgroundPipeline, glyphPipeline: shared.glyphPipeline,
                        useTwoPass: use2Pass,
                        unifiedBlurPipeline: shared.unifiedBlurPipeline
                    )
                    logHostedLayerDraw(layer: layer, encodedRows: encodedRows, of: rows, drawOriginPx: origin, bodilyMoved: origin != layer.originPx)
                }
                bindLayerTransform(encoder: encoder, viewportMetrics.layerTransform)
                bindSingleSurfaceScrollOffset(encoder: encoder, offset: scrollOffsetSnapshot)
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0,
                    width: glow ? max(1, backTex.width / 2) : backTex.width,
                    height: glow ? max(1, backTex.height / 2) : backTex.height))
            }

            // Nothing this frame draws into backTex: both reuse arms skip
            // every root row, and drawHostedLayers is skipped with them (or has
            // no layer to visit). With `.load` and `.store` the pass would
            // still make the GPU resolve the whole attachment for no draw, so
            // skip the encoder outright, as the main renderer's skipMainPass
            // has always done. The cursor is composited onto the drawable in
            // its own pass below, and the atlas read is released by the command
            // buffer's completion handler either way.
            let skipSurfacePass = rowMode && (reuseRootContents || reuseHostedContents)
            if !skipSurfacePass {
                guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                    // Encoder creation failed (rare). Commit the empty cmd anyway so
                    // the IOAccelerator region attached to it is reclaimed; otherwise
                    // an uncommitted MTLCommandBuffer leaks GPU memory permanently.
                    // The atlas texture is never sampled on this path, so the read
                    // registered above (if any) can be released immediately rather
                    // than waiting for this now-empty command buffer's completion.
                    atlasReader.endExternalRead()
                    hasPresentedOnce = false
                    submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseFrameState)
                    gpuSubmitted = true
                    bailWithoutSubmit("render encoder creation failed")
                    return
                }
                // The atlas texture is also captured for the bloom extract
                // pass and the cursor pass below.
                beginSurfaceRowPass(
                    encoder: enc,
                    viewportMetrics: viewportMetrics,
                    pipeline: pipeline,
                    atlasTexture: atlasTex,
                    sampler: sampler,
                    backgroundAlpha: backgroundAlpha,
                    fixedFloatBands: fixedFloatMask.bands,
                    fixedFloatIntervals: fixedFloatMask.intervals,
                    bindScrollOffsets: { bindSingleSurfaceScrollOffset(encoder: $0, offset: scrollOffsetSnapshot) }
                )

                // --- Row-mode rendering branches — match GridSurfaceRenderer structure ---
                if rowMode && !reuseHostedContents && !reuseRootContents {
                    if ZonvieCore.appLogEnabled {
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
                        ZonvieCore.appLog("[ext_draw_debug] gridId=\(gridId) safeRowCount=\(safeRowCount) dirtyRows=\(dirtyRows.count) useGpuScrollCopy=\(useGpuScrollCopy) use2Pass=\(use2Pass) canBlink=false loadAction=\(rpd.colorAttachments[0].loadAction.rawValue) vpH=\(vpHeight) snapRows=\(snapGridRows) drawableH=\(view.drawableSize.height) vpOriginY=\(viewportOriginPx.y)")
                    }

                    // Shared with GridSurfaceRenderer: the geometry every row
                    // below is placed with. A decorated grid's padding stays
                    // governed by the transparent render-pass clear outside the
                    // viewport; the bands only cover the viewport itself.
                    let rowGeometry = SurfaceRowGeometry(
                        cellHeightPx: Int(cellHi),
                        renderTarget: backTex,
                        viewportMetrics: viewportMetrics,
                        drawableSize: view.drawableSize
                    )

                    // Shared with GridSurfaceRenderer: WHICH rows this pass
                    // draws is one decision; `use2Pass` says HOW.
                    let rowPassPlan = SurfaceRowPassTerms(
                        useTwoPass: use2Pass,
                        rootScrollBlitVacatedBand: useGpuScrollCopy,
                        isSmoothScrolling: smoothScrolling,
                        canDirtyOnlyWithBlur: canDirtyOnlyWithBlur,
                        loadedPreviousContents: rpd.colorAttachments[0].loadAction == .load,
                        hasDirtyRows: !dirtyRows.isEmpty,
                        glowEnabled: glowEnabled,
                        isDecoratedSurface: isDecoratedSurface,
                        drawableSizeChanged: drawableSizeChanged
                    ).plan

                    encodeSurfaceRootRowPass(
                        encoder: enc,
                        plan: rowPassPlan,
                        useTwoPass: use2Pass,
                        dirtyRows: dirtyRows,
                        rowCount: safeRowCount,
                        smoothRows: smoothRowRange,
                        resolveRow: resolvedRowState,
                        resolveSmoothRow: resolvedSmoothRowState,
                        geometry: rowGeometry,
                        scrollClearBand: scrollClearBand,
                        pipeline: pipeline,
                        shared: shared,
                        bgRGB: surfaceBgRGB,
                        gridId: gridId
                    )
                }

                // Hosted grids use the same row-slot resolution and pipelines as
                // the root. The shared back texture is recomposed before effects.
                if !reuseHostedContents { drawHostedLayers(enc) }

                // Cursor is NOT drawn into backbuffer — it is composited onto the
                // drawable after blit, so the persistent backbuffer stays cursor-free
                // and GPU scroll-region copies don't shift stale cursor pixels.

                enc.endEncoding()
            } else {
                // Traced on the path that actually skipped, not where the flag
                // is computed: the claim being made is that no surface pass was
                // encoded at all.
                ZonvieCore.renderTrace("side=macos event=retained_content_reuse surface=\(gridId) root_row_draws=0 hosted_row_draws=0")
            }

            // --- Post-process bloom (neon glow) ---
            // Shared with GridSurfaceRenderer; only where the intensity and
            // the radius are read from differs, and this surface's viewport
            // does not start at the drawable's origin.
            let glowPassSucceeded = encodeSurfaceBloom(
                enabled: glowEnabled,
                shared: shared,
                cmd: cmd,
                backTex: backTex,
                pixelFormat: view.colorPixelFormat,
                viewportMetrics: viewportMetrics,
                drawableSize: view.drawableSize,
                viewportOrigin: CGPoint(x: vpOriginX, y: vpOriginY),
                glowTextures: glowTextures,
                intensity: core?.getGlowIntensity() ?? 0.8,
                // One read, for both the chain's depth and the taps' reach.
                radiusScale: core?.getGlowRadiusScale() ?? 1.0
            ) { enc, extractPipe in
                    // Set up atlas and scroll offsets for extract pass.
                    // The bloom helper binds the layer transform (vertex buffer 4).
                    bindSurfaceGlowExtractState(
                        encoder: enc,
                        atlasTexture: atlasTex,
                        sampler: self.shared.sampler!,
                        backgroundAlpha: backgroundAlpha,
                        bindScrollOffsets: { bindSingleSurfaceScrollOffset(encoder: $0, offset: scrollOffsetSnapshot) }
                    )

                    // Draw row vertices. The same range the main pass draws:
                    // glow forces a `.clear`, so a retained row left out here
                    // has no previous-frame light to fall back on and the band
                    // a scroll vacated renders unlit for the whole ease. The
                    // main renderer's extract covers its retained rows for the
                    // same reason.
                    if rowMode {
                        encodeSurfaceResolvedRows(encoder: enc, rows: smoothRowRange, resolve: resolvedSmoothRowState)
                    }

                    drawHostedLayers(enc, glowPipeline: extractPipe)

                    // Cursor vertices for cursor glow
                    if committedFontIsCurrent,
                       cursorBlinkStateSnapshot,
                       committedCursor.vertexCount > 0,
                       let cvb = committedCursor.vertexBuffer {
                        // drawHostedLayers left the surface-wide offset bound.
                        encodeSurfaceCursorGlowExtract(
                            encoder: enc,
                            vertexBuffer: cvb,
                            vertexCount: committedCursor.vertexCount,
                            layerOriginPx: cursorDrawOrigin,
                            viewportMetrics: viewportMetrics,
                            bindScrollOffsets: { bindSingleSurfaceScrollOffset(encoder: $0, offset: cursorOwnerOffset) }
                        )
                    }
                    }

            guard glowPassSucceeded else {
                submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseAbandonedFrame)
                gpuSubmitted = true
                hasPresentedOnce = false
                bailWithoutSubmit("glow resource/encoder creation failed", restoreScroll: false)
                return
            }

            // --- Blit back buffer to drawable ---
            // Timed, mirroring the main view's draw_acquire_drawable: this
            // is a MAIN-thread call with no non-blocking variant, and it is
            // where an invisible window used to cost ~1s per frame.
            var tAcquire: CFAbsoluteTime = 0
            if ZonvieCore.appLogEnabled { tAcquire = CFAbsoluteTimeGetCurrent() }
            FrameTracer.trace(.drawableAcquireBegin, seq: UInt32(truncatingIfNeeded: gridId))
            let acquired = view.currentDrawable
            FrameTracer.trace(.drawableAcquireEnd, seq: UInt32(truncatingIfNeeded: gridId))
            if ZonvieCore.appLogEnabled {
                let us = (CFAbsoluteTimeGetCurrent() - tAcquire) * 1_000_000
                ZonvieCore.appLogPerf("[perf] ext_acquire_drawable gridId=\(gridId) us=\(String(format: "%.1f", us)) got=\(acquired != nil)")
            }
            guard let drawable = acquired else {
                FrameTracer.trace(.drawSkipNoDrawable, seq: UInt32(truncatingIfNeeded: gridId))
                // Capture semaphore and lock directly so the signal fires even
                // if the view is deallocated before the GPU finishes.
                // `releaseAbandonedFrame` ends the read through the strongly
                // captured `atlasReader`, not through `self` — see
                // beginExternalRead's declaration comment for why.
                submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseAbandonedFrame)
                gpuSubmitted = true
                // Rows + revision restored, scroll NOT restored: the scroll
                // blit is already committed into backTex above; restoring it
                // would shift those pixels a second time on the retry.
                bailWithoutSubmit("no drawable (rendered to backTex but nothing to present)", restoreScroll: false)
                return
            }
            // User-supplied custom post-process shaders take over the
            // backTex -> drawable copy when configured in `.afterBloom`
            // mode. The shader samples backTex (which already contains
            // main render + optional bloom) and writes directly to the
            // drawable, replacing the normal blit. The chain itself is
            // encoded by the same helper the main surface drives; only the
            // uniforms differ, because this window's screen-space origin does.
            // Shared with GridSurfaceRenderer: the chain-or-copy ladder is one
            // function now. The uniforms closure below is the only part this
            // surface does differently, and it runs only when the chain does.
            //
            // The plain copy used to take its pipeline, vertex buffer and
            // sampler from `mainTerminalView?.renderer`, which meant an
            // external surface could not present at ALL without the main one —
            // the last hard reach-through in this function, and in the ordinary
            // path, not an optional effect. They come from `shared` now, where
            // stage 0 put them.
            let presentation = encodeSurfaceBackBufferToDrawable(
                cmd: cmd,
                backTex: backTex,
                drawableTexture: drawable.texture,
                customShaderPipelines: surfaceCustomShaderPipelines(),
                runsCustomShaderChain: shared.customShaderPostProcess == .afterBloom
                    && mainTerminalView?.renderer != nil,
                customShaderPong: customShaderPong,
                pongSize: view.drawableSize,
                copyPipeline: shared.copyPipeline,
                copyVertexBuffer: shared.copyVertexBuffer,
                sampler: shared.sampler,
                bilinearSampler: shared.bilinearSampler,
                makeUniforms: { [weak self] in
                    guard let self, let renderer = self.mainTerminalView?.renderer else {
                        return zonvie_shader_uniforms()
                    }
                    // Screen-space unification: use the MAIN window's drawable
                    // as the shader's iResolution, and tell the shader where
                    // this external view sits inside that coordinate space so
                    // effects (stars, gradients, spotlights) line up across all
                    // windows.
                    let (screenRes, windowOffset) = screenSpaceParameters(
                        mainView: self.mainTerminalView,
                        selfView: self
                    )
                    // The cursor rect was evaluated with the committed snapshot
                    // this frame draws, under the same hold; the uniforms read it.
                    // The rect the shader gets beside the row and displacement
                    // the body is drawn with THIS frame. Their difference is a
                    // constant while the two describe the same commit; a rect
                    // evaluated against a newer flush's cursor shows up as one
                    // row step in it. Emitted on change only.
                    if ZonvieCore.appLogEnabled, let offPx = cursorShaderOffsetPx {
                        let y = self.shared.shaderCursor.snapshot().current.1
                        let frame = (lastKnownCursorRowSnapshot, offPx, y)
                        if frame != self.lastLoggedCursorFrame {
                            self.lastLoggedCursorFrame = frame
                            ZonvieCore.appLog("[ext_shader_cursor_frame] gridId=\(self.gridId) row=\(frame.0) offPx=\(offPx) y=\(y)")
                        }
                    }
                    // This surface's own scale, because the rect the log line
                    // carries is in ITS drawable pixels. Reading it off the
                    // main renderer, which is what calling through it did,
                    // reported the main window's — the same number only while
                    // every window sits on one display.
                    return self.shared.makeShaderUniforms(
                        screenResolution: screenRes,
                        windowOffset: windowOffset,
                        windowSize: view.drawableSize,
                        backingScale: self.backingScale,
                        timing: self.shaderTiming,
                        lastLoggedCursor: &self.lastLoggedShaderCursor
                    )
                }
            )

            guard presentation.encoded else {
                // Back-buffer work is valid and must be submitted to release
                // its Metal resources, but the drawable was not populated.
                // Keep the consumed rows/revision pending for another draw.
                submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseAbandonedFrame)
                gpuSubmitted = true
                hasPresentedOnce = false
                bailWithoutSubmit("final blit encoder creation failed", restoreScroll: false)
                return
            }

            // --- Cursor overlay: composited on drawable (not backbuffer) ---
            // Keeps persistent backbuffer cursor-free so GPU scroll copies
            // don't shift stale cursor pixels (same as GridSurfaceRenderer).
            if committedFontIsCurrent,
               cursorBlinkStateSnapshot,
               committedCursor.vertexCount > 0,
               let cursorBuf = committedCursor.vertexBuffer {
                // Shared with GridSurfaceRenderer. This surface binds the
                // single offset of the grid that owns the cursor where the main
                // one binds an array, and it attaches no perf samples.
                let cursorEncoded = encodeSurfaceCursorOverlay(
                    cmd: cmd,
                    drawableTexture: drawable.texture,
                    pipeline: pipeline,
                    atlasTexture: atlasTex,
                    sampler: sampler,
                    viewportMetrics: viewportMetrics,
                    cursorVertexBuffer: cursorBuf,
                    cursorVertexCount: committedCursor.vertexCount,
                    layerOriginPx: cursorDrawOrigin,
                    backgroundAlpha: backgroundAlpha,
                    fixedFloatBands: fixedFloatMask.bands,
                    fixedFloatIntervals: fixedFloatMask.intervals,
                    bindScrollOffsets: { cursorEnc in
                        bindSingleSurfaceScrollOffset(encoder: cursorEnc, offset: cursorOwnerOffset)
                    }
                )
                if !cursorEncoded {
                    submitSurfaceFrameWithoutPresenting(cmd: cmd, release: releaseAbandonedFrame)
                    gpuSubmitted = true
                    hasPresentedOnce = false
                    // Main/back-buffer and scroll work is now submitted, so
                    // do not queue the pixel shift a second time. Restored rows
                    // and revision state produce a complete retry.
                    bailWithoutSubmit("cursor encoder creation failed", restoreScroll: false)
                    return
                }
            }

            FrameTracer.tracePresented(drawable, seq: UInt32(truncatingIfNeeded: gridId))
            FrameTracer.trace(.presentCall, seq: UInt32(truncatingIfNeeded: gridId))
            cmd.present(drawable)
            // `sem` and `tbLock` are the ones captured for `releaseFrameState`
            // above, for the same reason: the signal has to fire even if the
            // view is deallocated before the GPU finishes.
            cmd.addCompletedHandler { [weak self] completed in
                let failed = completed.status != .completed
                tbLock.lock()
                self?.completeSurfaceFrameReadLocked(rowSet: csi, cursorSlot: cci)
                if failed { self?.gpuFrameFailed = true }
                tbLock.unlock()
                sem.signal()
                // Paired with beginExternalRead() at atlas-bind time
                // above. Uses the strongly-captured atlasReadRenderer, not
                // [weak self] — see its declaration comment for why.
                atlasReader.endExternalRead()
                if failed {
                    DispatchQueue.main.async { [weak self] in
                        self?.requestRedraw()
                    }
                }
            }
            cmd.commit()
            gpuSubmitted = true

            markScrollOffsetStatePresented()
            if !hasPresentedOnce { recalculateSurfaceShadowAfterFirstPresent(self) }
            hasPresentedOnce = true
            hasEverPresented = true
            redrawScheduler.didDrawFrame()
            finishedRedraw = true

            // Only when there is a scrollbar, as the main surface's flush path
            // does: this hop ran on every presented frame of an animation.
            if ZonvieConfig.shared.scrollbar.enabled && hostsScrollbar {
                DispatchQueue.main.async { [weak self] in
                    self?.updateScrollbarIfNeeded()
                }
            }
        }
    }

    // MARK: - Post-Process Bloom (Neon Glow) — uses shared encodeSurfaceBloomPasses()

    // MARK: - Private


    // MARK: - Smooth Scroll

    /// Drain the ease seeds this surface's steps committed. Spent by the main
    /// view's tick, which owns the per-grid offsets they feed.
    func takeSmoothScrollSeeds() -> [(gridId: Int64, rowsDelta: Int)] {
        guard GridSurfaceRenderer.smoothScrollEnabled else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard !smoothScrollSeeds.isEmpty else { return [] }
        let taken = smoothScrollSeeds
        smoothScrollSeeds.removeAll(keepingCapacity: true)
        return taken
    }

    /// Update scroll offset shader uniform for visual sub-cell scrolling.
    /// Uses shared scroll offset info and computation from GridSurfaceRenderer.
    /// Returns true if a non-zero scroll offset is active.
    @discardableResult
    private func updateScrollShaderOffset() -> Bool {
        guard let scroll = core?.scrollModel else { return false }

        let cellHeightPx = Float(shared.cellHeightPx)
        guard cellHeightPx > 0 else { return false }

        // Use the same grid-based snapped viewport height draw() computes
        // (vpHeight = snapGridRows * cellHi). snapGridRows is a LOCAL inside
        // draw(), not a property — recompute it here the same way:
        // the committed extent under lock, falling back to the
        // live grid when no commit has published dimensions yet. The fragment
        // shader's NDC reconstruction uses this grid-based height for external
        // surfaces (via SurfaceViewportMetrics.fragmentHeight), not
        // drawableSize.height.
        lock.lock()
        let snappedExtent = committedExtent
        lock.unlock()
        let rowsForHeight = snappedExtent.resolved(
            liveWidth: gridCols,
            liveHeight: gridRows
        ).height
        let cellHi = max(1, UInt32(cellHeightPx.rounded(.up)))
        let viewportHeight = Float(rowsForHeight) * Float(cellHi)
        guard viewportHeight > 0 else { return false }
        // The height every NDC below is built against, kept beside them so
        // draw's snapshot can undo the conversion exactly rather than
        // recompute the height on a cell size the core may have moved since.
        lock.lock()
        scrollOffsetViewportHeight = viewportHeight
        lock.unlock()

        // The band a wheel event opens is as wide as the rows it moves, so
        // this window's retention has to keep that many. The main view sets
        // its own renderer's depth on scroll input; an external window is not
        // on that path, so take it from the same source here.
        retention.setDepthRows(core?.getMouseScrollVer() ?? 0)

        let vpOriginYPxForGridTop = Float(viewportOriginPx.y)
            * Float(backingScale)

        // Resolve every hosted grid's own offset, the way the main window's
        // layer pass does. Without this a float inside an external window only
        // ever moves when the root scrolls, and a float scrolled on its own
        // stands still. Its grid top is the origin this surface placed it at —
        // the main window's startRow describes a position this view never uses.
        lock.lock()
        hostedLayerOriginScratch.removeAll(keepingCapacity: true)
        for layer in committedSurfaceLayers where layer.gridId != gridId {
            hostedLayerOriginScratch.append((gridId: layer.gridId, originYPx: layer.originPx.y, z: Int32(clamping: layer.z)))
        }
        lock.unlock()

        // A displaced grid's rows and margins, from one grid-info fetch per
        // update, taken only once some grid is displaced.
        var visibleGrids: [ZonvieCore.GridInfo]? = nil
        func displacedInfo(_ id: Int64, gridTopYNDC: Float, zindex: Int32) -> GridSurfaceRenderer.ScrollOffsetInfo? {
            guard let offsetPx = scroll.settledVisualOffsetPx(gridId: id, cellHeightPx: cellHeightPx) else { return nil }
            if visibleGrids == nil { visibleGrids = core?.getVisibleGridsCached() ?? [] }
            guard let grid = visibleGrids?.first(where: { $0.gridId == id }) else { return nil }
            return GridSurfaceRenderer.ScrollOffsetInfo(
                grid: grid, offsetYPx: offsetPx, gridTopYNDC: gridTopYNDC, zindex: zindex)
        }

        hostedScrollOffsetScratch.removeAll(keepingCapacity: true)
        for hosted in hostedLayerOriginScratch {
            // The z is the one this surface's fixed-float mask is built from,
            // so the two are on one scale: `layer.z`, which the core emits as a
            // PAINT-ORDER rank (>= 1 for every hosted layer). Left at 0 the
            // shader's `interval.z > scroll_z` was true for a float tested
            // against its OWN rect, so a fixed float scrolled on its own
            // discarded its scrolled glyphs for the whole ease.
            guard let info = displacedInfo(
                hosted.gridId,
                gridTopYNDC: 1.0 - (vpOriginYPxForGridTop + hosted.originYPx) * (2.0 / viewportHeight),
                zindex: hosted.z
            ) else { continue }
            hostedScrollOffsetScratch.append(GridSurfaceRenderer.computeScrollOffset(
                info: info,
                viewportHeight: viewportHeight,
                cellHeightPx: cellHeightPx
            ))
        }
        hostedScrollOffsetScratch.sort { $0.grid_id < $1.grid_id }
        let hasHostedOffset = !hostedScrollOffsetScratch.isEmpty
        // Retained rows cover the vacated band with the content that actually
        // left; the edge-row background stretch would paint over them, so it
        // is released per grid once they cover the whole band.
        let cellHeightNDC = cellHeightPx * (2.0 / viewportHeight)

        // Get scroll offset info from the main view's shared scroll state.
        // No second clamp here. settledVisualOffsetPx already applied the
        // shared one, which allows a whole wheel event's worth of compensation
        // ('mousescroll' ver rows); re-clamping to two cells discarded the
        // rest, jumped the picture by what it dropped, and left the
        // cursor-shader uniform — which follows the UNclamped value — a row
        // away from the cursor it is drawn on. The empty band the old clamp
        // was guarding against is now covered by the retained rows below.
        //
        // The grid top is this view's own: ndc_y = 1 - pos.y*(2/vpHeight),
        // where pos.y includes the decorated-surface padding, so the grid's
        // top edge sits at pixel vpOriginY (zero for undecorated surfaces,
        // giving 1.0, the top of the viewport).
        if let info = displacedInfo(
            gridId,
            gridTopYNDC: 1.0 - vpOriginYPxForGridTop * (2.0 / viewportHeight),
            zindex: 0
        ) {
            // Use the grid-snapped viewport coordinate space, matching the
            // fragment shader's screen-space clipping for this surface (see
            // draw()'s vpHeight/vpOriginY computation).
            let scrollOffset = GridSurfaceRenderer.computeScrollOffset(
                info: info,
                viewportHeight: viewportHeight,
                cellHeightPx: cellHeightPx
            )

            lock.lock()
            defer { lock.unlock() }

            // Retire retained rows of any grid this surface draws that is no
            // longer displaced, per grid, as the main surface does every
            // frame. The wholesale clear in the branch below only runs once
            // the ROOT has no offset, so a hosted float's rows outlived its
            // own ease while the root kept scrolling and were drawn into a
            // layer that no longer had an offset to place them under.
            // `smoothScrollSeeds` is read under the lock that published them.
            // Then the pins, for the root and every hosted grid alike, after
            // the prune as on the main surface.
            pruneOffsetsScratch.removeAll(keepingCapacity: true)
            pruneOffsetsScratch.append(scrollOffset)
            pruneOffsetsScratch.append(contentsOf: hostedScrollOffsetScratch)
            retention.pruneUndisplaced(offsets: pruneOffsetsScratch, seedGrids: smoothScrollSeeds)
            retention.releaseCoveredPins(&pruneOffsetsScratch, cellHeightNDC: cellHeightNDC)

            scrollOffsetData = pruneOffsetsScratch[0]
            scrollOffsetLatch.setActive(true)
            hostedScrollOffsetData.removeAll(keepingCapacity: true)
            hostedScrollOffsetData.append(contentsOf: pruneOffsetsScratch.dropFirst())

            ZonvieCore.appLog("[ExternalGridView] scroll offset: gridId=\(gridId) offsetPx=\(info.offsetYPx) marginTop=\(info.marginTop) marginBottom=\(info.marginBottom) ndc=\(pruneOffsetsScratch[0].offset_y) top=\(pruneOffsetsScratch[0].content_top_y) bot=\(pruneOffsetsScratch[0].content_bottom_y) pin=\(pruneOffsetsScratch[0].pin_edges) retained=\(retention.publishedCount(gridId: gridId)) gridTop=\(info.gridTopYNDC) cellNDC=\(cellHeightNDC) vpH=\(viewportHeight)")
            return true  // Scroll offset is active
        } else {
            // The root has no offset. A retained row is only meaningful while
            // its grid is displaced, so the root's go — but a hosted float
            // still easing keeps its own, per grid, as in the branch above and
            // on the main surface. Clearing every grid here cut the retained
            // band out of a float's ease the frame the root stopped.
            lock.lock()
            defer { lock.unlock() }

            pruneOffsetsScratch.removeAll(keepingCapacity: true)
            pruneOffsetsScratch.append(contentsOf: hostedScrollOffsetScratch)
            retention.pruneUndisplaced(offsets: pruneOffsetsScratch, seedGrids: smoothScrollSeeds)
            retention.releaseCoveredPins(&hostedScrollOffsetScratch, cellHeightNDC: cellHeightNDC)

            scrollOffsetData = nil
            // A hosted grid easing on its own keeps this surface in a smooth
            // scroll even with the root standing still, exactly as any grid's
            // offset does for the main renderer — whose latch is fed the count
            // over every grid, layers included. Feeding only the root's offset
            // here dropped the one frame past the ease that `isSmoothScrolling`
            // exists for: the back buffer still holds rows rendered at an
            // offset, and blitting those again is a one-row jitter.
            scrollOffsetLatch.setActive(hasHostedOffset)
            hostedScrollOffsetData.removeAll(keepingCapacity: true)
            hostedScrollOffsetData.append(contentsOf: hostedScrollOffsetScratch)
            return hasHostedOffset
        }
    }

    private func scrollOffsetsEqual(
        _ lhs: GridSurfaceRenderer.ScrollOffset?,
        _ rhs: GridSurfaceRenderer.ScrollOffset?
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

        if scrollOffsetLatch.isActive != scrollOffsetLatch.previousFrameWasActive {
            return true
        }
        // A hosted grid easing while the root stands still changes this
        // surface's picture just as much. Without this the frame that puts a
        // hosted float back at zero reads as "nothing changed" and is skipped,
        // leaving the last displaced image on screen until something else
        // redraws.
        if lastPresentedHostedScrollOffsetData.count != hostedScrollOffsetData.count {
            return true
        }
        for (index, offset) in hostedScrollOffsetData.enumerated()
        where !scrollOffsetsEqual(offset, lastPresentedHostedScrollOffsetData[index]) {
            return true
        }
        if !scrollOffsetLatch.isActive {
            return false
        }
        return !scrollOffsetsEqual(scrollOffsetData, lastPresentedScrollOffsetData)
    }

    private func markScrollOffsetStatePresented() {
        lock.lock()
        defer { lock.unlock() }

        scrollOffsetLatch.latch(scrollOffsetLatch.isActive)
        lastPresentedScrollOffsetData = scrollOffsetData
        lastPresentedHostedScrollOffsetData.removeAll(keepingCapacity: true)
        lastPresentedHostedScrollOffsetData.append(contentsOf: hostedScrollOffsetData)
    }

    // MARK: - Mouse Input

    /// Set by the last draw when more fixed floats than the mask holds made it
    /// drop the scroll transform. Main thread only (draw and input).
    private var drewWithoutScrollTransform = false

    /// The ease offset the last frame drew `grid` with: none at all on a
    /// frame that dropped the scroll transform.
    private func drawnScrollOffsetPx(_ grid: Int64, cellH: CGFloat, scroll: SessionScrollModel) -> CGFloat {
        drewWithoutScrollTransform ? 0 : scroll.visualScrollOffsetPx(gridId: grid, cellHeightPx: cellH)
    }

    /// Which grid a pointer event at `pointPx` (surface content pixels,
    /// top-origin) targets, and the point in that grid's own cells. The grid
    /// is the core's answer (`zonvie_core_resolve_pointer_grid`) with the two
    /// corrections the main window's hit test applies: a follower is found
    /// where it is DRAWN (resolveDisplacedFollowerHit), and a grid easing in
    /// its own right has its ease undone (scrollAdjustedLocalRow).
    private func resolveInputTarget(
        pointPx: CGPoint,
        requireScrollable: Bool
    ) -> (gridId: Int64, row: Int32, col: Int32) {
        guard let core else { return (gridId, 0, 0) }
        let scroll = core.scrollModel
        let cellW = CGFloat(shared.cellWidthPx)
        let cellH = CGFloat(shared.cellHeightPx)
        guard cellW > 0, cellH > 0 else { return (gridId, 0, 0) }

        // Refreshes the snapshot resolvePointerGrid reads.
        let grids = core.getVisibleGridsCached()
        let row = Int32((pointPx.y / cellH).rounded(.down))
        let col = Int32((pointPx.x / cellW).rounded(.down))
        let resolve = { (r: Int32, c: Int32) in
            core.resolvePointerGrid(surfaceId: self.gridId, row: r, col: c, requireScrollable: requireScrollable)
        }
        var hit = resolve(row, col)

        var followers: [Int64: CGFloat] = [:]
        var layers: [SurfaceLayer] = []
        if scroll.hasOffsets {
            let rootOffsetPx = drawnScrollOffsetPx(gridId, cellH: cellH, scroll: scroll)
            lock.lock()
            layers = committedSurfaceLayers
            lock.unlock()
            for layer in layers where layer.gridId != gridId {
                let ownOffsetPx = drawnScrollOffsetPx(layer.gridId, cellH: cellH, scroll: scroll)
                let displacedPx = hostedLayerDrawOriginY(layer, ownOffsetPx: ownOffsetPx,
                                                         rootOffsetPx: rootOffsetPx, cellH: cellH)
                    - CGFloat(layer.originPx.y)
                if displacedPx != 0 { followers[layer.gridId] = displacedPx }
            }
        }
        switch resolveDisplacedFollowerHit(
            pointPxY: pointPx.y,
            cellHeightPx: cellH,
            globalCol: col,
            staticGridId: hit?.gridId ?? gridId,
            followers: followers,
            paintRankOf: { id in layers.first { $0.gridId == id }?.z },
            resolveExcluding: { r, c, excluded in
                core.resolvePointerGrid(surfaceId: self.gridId, row: r, col: c,
                                        requireScrollable: requireScrollable, excluding: excluded)
            }
        ) {
        case let .follower(gridId, row, col)?:
            return (gridId, row, col)
        case let .uncovered(under)?:
            hit = under
        case nil:
            break
        }

        guard let hit, let info = grids.first(where: { $0.gridId == hit.gridId }) else {
            return resolveRootTarget(pointPx: pointPx)
        }
        return (hit.gridId,
                scrollAdjustedLocalRow(
                    pointPxY: pointPx.y,
                    cellHeightPx: cellH,
                    band: GridRowBand(of: info),
                    scrollOffsetPx: drawnScrollOffsetPx(hit.gridId, cellH: cellH, scroll: scroll)
                ),
                hit.col)
    }

    /// Where a hosted layer's rows are DRAWN on this surface, in surface
    /// pixels, so the hit test reads the placement rather than its own account
    /// of it.
    ///
    /// drawHostedLayers builds it from two terms: the anchor's displacement,
    /// which moves a follower bodily rather than easing rows inside a frame
    /// that stays put, and the float ledger's debt, giving back the rows this
    /// float's own placement has already performed. Both hit-test sites
    /// transcribed the first term and dropped the second, so for as long as a
    /// float carried debt a press landed whole ROWS from where the float is
    /// drawn -- and rebaseToPinnedGrid's comment already claimed it used the
    /// drawn origin.
    private func hostedLayerDrawOriginY(
        _ layer: SurfaceLayer,
        ownOffsetPx: CGFloat,
        rootOffsetPx: CGFloat,
        cellH: CGFloat
    ) -> CGFloat {
        guard !drewWithoutScrollTransform, ownOffsetPx == 0,
              followsRootScroll(anchorGrid: layer.anchorGrid, followsScroll: layer.followsScroll) else {
            return CGFloat(layer.originPx.y)
        }
        let debtPx = hostedFloatDebtPx(
            gridId: layer.gridId,
            anchorGridId: layer.anchorGrid,
            cellHeightPx: Float(cellH),
            seedingBaseline: false
        )
        return CGFloat(layer.originPx.y) + rootOffsetPx + CGFloat(debtPx)
    }

    /// The grid row a grid-local pixel names, undoing the sub-row ease the
    /// frame drew with.
    ///
    /// The rule is `scrollAdjustedLocalRow`, which the main window's hit test
    /// and drag both use; this file carried a third copy of it. The band is
    /// stated with `startRow: 0` because these pixels are already the grid's
    /// own -- the main window measures from the surface origin and subtracts
    /// the grid's start row, and that is the whole difference between the two.
    private func scrolledRow(
        _ localY: CGFloat,
        offsetPx: CGFloat,
        cellH: CGFloat,
        info: ZonvieCore.GridInfo?
    ) -> Int32 {
        guard let info else { return cellH > 0 ? Int32((localY / cellH).rounded(.down)) : 0 }
        return scrollAdjustedLocalRow(
            pointPxY: localY,
            cellHeightPx: cellH,
            band: GridRowBand(
                startRow: 0,
                rows: info.rows,
                marginTop: info.marginTop,
                marginBottom: info.marginBottom
            ),
            scrollOffsetPx: offsetPx
        )
    }

    override func resolvePointerTarget(_ event: NSEvent, requireScrollable: Bool) -> (gridId: Int64, row: Int32, col: Int32) {
        // A float this surface hosts is drawn above the root, so a press inside
        // it has to name that grid; naming the root applies the press to the
        // window underneath instead.
        resolveInputTarget(pointPx: surfacePointPx(event), requireScrollable: requireScrollable)
    }

    /// The layer's CURRENT drawn origin, so a float that moves mid-drag keeps
    /// receiving the right cells. A layer that has gone falls back to this
    /// surface's own grid rather than re-resolving.
    override func rebaseToPinnedGrid(_ event: NSEvent, pinned pressed: Int64)
        -> (gridId: Int64, row: Int32, col: Int32)?
    {
        let pointPx = surfacePointPx(event)
        guard let scroll = core?.scrollModel, pressed != gridId else {
            return resolveRootTarget(pointPx: pointPx)
        }
        let cellW = CGFloat(shared.cellWidthPx)
        let cellH = CGFloat(shared.cellHeightPx)
        guard cellW > 0, cellH > 0 else { return resolveRootTarget(pointPx: pointPx) }

        lock.lock()
        let layer = committedSurfaceLayers.first { $0.gridId == pressed }
        lock.unlock()
        guard let layer else { return resolveRootTarget(pointPx: pointPx) }

        let rootOffsetPx = drawnScrollOffsetPx(gridId, cellH: cellH, scroll: scroll)
        let ownOffsetPx = drawnScrollOffsetPx(pressed, cellH: cellH, scroll: scroll)
        let originY = hostedLayerDrawOriginY(layer, ownOffsetPx: ownOffsetPx,
                                             rootOffsetPx: rootOffsetPx, cellH: cellH)
        let info = core?.getVisibleGridsCached().first { $0.gridId == pressed }
        // Deliberately unclamped to the layer rectangle: a drag that leaves the
        // float still belongs to it, and Neovim clamps the position into the
        // window it was addressed to.
        return (
            pressed,
            scrolledRow(pointPx.y - originY, offsetPx: ownOffsetPx, cellH: cellH, info: info),
            Int32(((pointPx.x - CGFloat(layer.originPx.x)) / cellW).rounded(.down))
        )
    }

    /// This surface's own grid at `pointPx`, with the ease its rows were drawn
    /// with undone.
    private func resolveRootTarget(pointPx: CGPoint) -> (gridId: Int64, row: Int32, col: Int32) {
        guard let scroll = core?.scrollModel else { return (gridId, 0, 0) }
        let cellW = CGFloat(shared.cellWidthPx)
        let cellH = CGFloat(shared.cellHeightPx)
        guard cellW > 0, cellH > 0 else { return (gridId, 0, 0) }
        let info = core?.getVisibleGridsCached().first { $0.gridId == gridId }
        let offsetPx = drawnScrollOffsetPx(gridId, cellH: cellH, scroll: scroll)
        return (gridId, scrolledRow(pointPx.y, offsetPx: offsetPx, cellH: cellH, info: info),
                Int32((pointPx.x / cellW).rounded(.down)))
    }

    // MARK: - Scroll Event Handling

    private var scrollTargetLock = ScrollTargetLock()

    override func scrollWheel(with event: NSEvent) {
        guard let scroll = core?.scrollModel else { return }
        let scale = backingScale
        let pointPx = surfacePointPx(event)
        scroll.handleGridScrollWheel(
            event, lock: &scrollTargetLock, scale: scale, logTag: "ExternalGridView scroll",
            resolve: { resolveInputTarget(pointPx: pointPx, requireScrollable: $0) },
            // The draw re-runs serviceFrame and updateScrollShaderOffset
            // (settleSurfaceAgainstOwnCommit), and handleScrollInput wakes
            // the draw loop of the view showing the target grid.
            afterPrecise: { _ in requestRedraw() })
    }

    /// Cursor is grid-local; viewportOriginPx adds a decorated surface's inset
    /// (e.g. the cmdline icon/padding).
    override func imeCursorRectInView() -> NSRect? {
        guard let core = core else { return nil }
        let cursor = core.getCursorPositionNonBlocking()
        guard cursor.row >= 0, cursor.col >= 0, let origin = imeCursorGridOriginPt(cursor.gridId) else { return nil }
        let cell = imePreeditCellSize
        return NSRect(x: viewportOriginPx.x + origin.x + CGFloat(cursor.col) * cell.width,
                      y: imeContentTopPt(rowHeightPt: cell.height) - origin.y - CGFloat(cursor.row + 1) * cell.height,
                      width: cell.width, height: cell.height)
    }

    override func imeFallbackRectInView() -> NSRect {
        let cell = imePreeditCellSize
        return NSRect(x: viewportOriginPx.x,
                      y: imeContentTopPt(rowHeightPt: cell.height) - cell.height,
                      width: cell.width, height: cell.height)
    }
}

// MARK: - IME host

extension ExternalGridView {
    /// Where the cursor's grid sits in this view, in points from the top-left:
    /// zero for this window's root, the layer origin for a float it hosts,
    /// nil when the cursor is on another surface. The IME answered only for
    /// the root, so a hosted float's candidate window fell to the corner.
    private func imeCursorGridOriginPt(_ cursorGrid: Int64) -> CGPoint? {
        if cursorGrid == gridId { return .zero }
        lock.lock()
        let layer = committedSurfaceLayers.first { $0.gridId == cursorGrid }
        lock.unlock()
        guard let layer else { return nil }
        let scale = backingScale
        return CGPoint(x: CGFloat(layer.originPx.x) / scale, y: CGFloat(layer.originPx.y) / scale)
    }

    /// The y, in view points from the bottom, of the top of the grid content.
    /// A decorated surface's frame is sized to its content, so the grid's own
    /// height plus the viewport offset is exact there. A normal window draws
    /// from the top and may carry leftover pixels (zoom, tiling) or a stale row
    /// count mid-resize; the view's height is its top, as the mouse and the
    /// main window's IME measure it.
    private func imeContentTopPt(rowHeightPt: CGFloat) -> CGFloat {
        guard isDecoratedSurface else { return bounds.height }
        // The committed row count, under the lock the draw reads it with:
        // `gridRows` is the core thread's in-flight bracket value, unpublished
        // and not restored when that bracket is cancelled.
        lock.lock()
        let extent = committedExtent
        lock.unlock()
        let rows = extent.resolved(liveWidth: gridCols, liveHeight: gridRows).height
        return viewportOriginPx.y + CGFloat(rows) * rowHeightPt
    }

}

extension ExternalGridView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasEverPresented = false

        // draw() parks the loop while this window is invisible, so a window
        // that becomes visible again with no Neovim traffic behind it would
        // otherwise stay on its stale last frame.
        if let previous = occlusionObserver {
            NotificationCenter.default.removeObserver(previous)
            occlusionObserver = nil
        }
        for observer in moveObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        moveObservers.removeAll()

        if let win = window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // The blink follows the window showing the cursor, which can
                // be this one; minimizing it also lands here. The main
                // window's delegate does the same for the main window.
                self.core?.refreshCursorBlinkGate()
                guard self.window?.occlusionState.contains(.visible) == true else { return }
                self.activateSurfaceDrawLoop()
                self.setNeedsDisplay(self.bounds)
            }

            // The shader cursor rect is expressed in the MAIN window's
            // drawable pixels, so it depends on the offset between the two
            // windows — dragging either one invalidates it without producing
            // a cursor update to recompute it from. Both are watched: this
            // window is the one the user drags, and the main window moving
            // shifts the same offset the other way.
            let movedWindows = [win, mainTerminalView?.window].compactMap { $0 }
            for moved in movedWindows {
                moveObservers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: moved,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.republishCursorShaderState(reanchor: true)
                    self.mainTerminalView?.requestRedraw()
                })
            }
        }
    }
}

