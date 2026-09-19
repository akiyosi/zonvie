import AppKit
import Metal
import MetalKit
import simd

/// See GridSurfaceRenderer's cap for the rationale: a safety cap against a
/// corrupt row index, not a practical content limit — external windows
/// (ext_multigrid) have no smaller row bound than the main grid, so this must
/// not be materially tighter than that cap. File scope because the row-history
/// sets are prepared to it at construction, and a stored property cannot name
/// another one in its initializer.
private let externalGridMaxRowBuffers = 20_000

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
    let scale = selfWin.backingScaleFactor
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
/// Forwards key events to the main terminal view so keyboard input still works.
final class ExternalGridView: MTKView, MTKViewDelegate {
    private let mtlDevice: MTLDevice
    private let queue: MTLCommandQueue

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        activateDrawLoop()
        requestRedraw()
    }

    /// Reference to main terminal view for key event forwarding and core access
    weak var mainTerminalView: MetalTerminalView?

    /// Custom clear color for the grid (default: black)
    var gridClearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// Track if we've presented at least once (for loadAction optimization)
    private var hasPresentedOnce = false
    private let redrawScheduler = SurfaceRedrawScheduler()

    // --- IME / NSTextInputClient support ---
    // Shared composition handling: inline-extmark preedit with overlay fallback.
    private lazy var ime = IMEPreeditController(host: self)
    private var _inputContext: NSTextInputContext?

    override var inputContext: NSTextInputContext? {
        if _inputContext == nil {
            _inputContext = NSTextInputContext(client: self)
        }
        return _inputContext
    }

    /// The GPU objects every surface shares, handed in at construction. Before
    /// this, these were copied in one by one and the rest were reached through
    /// `mainTerminalView?.renderer`, which made this surface unable to draw
    /// without the main window's renderer alive.
    let shared: SharedRenderResources
    private var pipeline: MTLRenderPipelineState? { shared.pipeline }
    private var sampler: MTLSamplerState? { shared.sampler }

    // 2-pass rendering pipelines for blur support
    private var backgroundPipeline: MTLRenderPipelineState? { shared.backgroundPipeline }
    private var glyphPipeline: MTLRenderPipelineState? { shared.glyphPipeline }
    // Single-pass replacement for the pair above; nil falls back to them.
    private var unifiedBlurPipeline: MTLRenderPipelineState? { shared.unifiedBlurPipeline }

    /// Scroll-offset publication and the font generation: `scrollOffsetData`,
    /// `lastPresentedScrollOffsetData`, `lastPresentedScrollOffsetActive`,
    /// `retention`'s published set, and the committed font generation.
    ///
    /// One of **three** locks on this surface where the main surface has one.
    /// Measured under a sustained 30 Hz scroll, the split costs nothing and
    /// buys nothing: this lock was taken 1,556 times and found held **0**, the
    /// triple-buffer lock 4,408 times and held 9, the scroll lock 2,272 times
    /// and held 1 — against the main surface's single lock at 19,764 takes and
    /// 49 held, 0.248%. So the number of locks is a legibility question, not a
    /// performance one, which is why they are written down rather than merged.
    ///
    /// **The ordering invariant, in full:** `tripleBufferLock` may be held
    /// while `pendingGridScrollLock` is taken — twice, both in `commitFlush` —
    /// and nothing else nests. This lock is never held with either. A
    /// call-graph scan (`tmp/lockscan.py`) confirms no function reached from
    /// inside one lock's region acquires another, which is the nesting a
    /// line-level read misses.
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
        tripleBufferLock.lock()
        pendingSurfaceLayers = layers
        // Placement alone is content: it must rotate and schedule a paint
        // even when this flush does not submit any rows.
        flushHadContent = true
        tripleBufferLock.unlock()
        if let owner = pendingCursorGridId,
           !layers.contains(where: { $0.gridId == owner }) {
            submitLayerCursor(gridId: owner, ptr: nil, count: 0)
            pendingCursorGridId = gridId
        }
    }

    /// Release a destroyed grid's vertex storage.
    func releaseGridBuffers(gridId released: Int64) {
        tripleBufferLock.lock()
        gridBuffers.release(gridId: released)
        tripleBufferLock.unlock()
    }

    private var pendingSurfaceLayers: [SurfaceLayer]?
    private var committedSurfaceLayers: [SurfaceLayer] = []
    private var pendingLayoutDamage = false
    private var layerGridIdScratch: [Int64] = []
    private var layerDrawSnapshot: [(SurfaceLayer, SurfaceBufferSet)] = []
    /// Rows each hosted layer's committed placement has travelled upwards
    /// since this surface began, in the same units and direction as
    /// on_grid_scroll's rowsDelta. The float ledger's other half; the main
    /// renderer keeps the identical map for the layers IT places, and the debt
    /// it computes was simply absent for a float an external window hosts.
    /// Written only under `tripleBufferLock` at commit; read by
    /// copyPlacementRowsUp.
    private var layerPlacementRowsUp: [Int64: Int] = [:]

    /// Hand the float ledger this surface's half, merging into storage the
    /// caller owns so the per-frame read costs one lock and no allocation.
    func copyPlacementRowsUp(into out: inout [Int64: Int]) {
        tripleBufferLock.lock()
        defer { tripleBufferLock.unlock() }
        for (gridId, rows) in layerPlacementRowsUp { out[gridId] = rows }
    }

    /// This surface's fixed-float mask, the same one the main renderer keeps.
    /// Built in draw() from the committed layer snapshot, so it needs no lock
    /// of its own; rebuilt only when the rectangles change.
    private let fixedFloatMask = SurfaceFixedFloatMask()
    private var fixedFloatRectsScratch: [GridSurfaceRenderer.FixedFloatRect] = []
    private var pendingCursorGridId: Int64?
    var renderTraceFlushId: UInt64 = 0 // Core callback thread only.
    private var committedCursorGridId: Int64?

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
                self.tripleBufferLock.lock()
                defer { self.tripleBufferLock.unlock() }
                var first: MTLBuffer?
                var second: MTLBuffer?
                for index in 0..<3 where self.gpuInFlightCount[index] > 0 {
                    let buffers = sets[index].rowState.buffers
                    guard slot >= 0, slot < buffers.count, let buffer = buffers[slot] else { continue }
                    if first == nil { first = buffer } else { second = buffer }
                }
                return (first, second)
            }
        )
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=row_staged surface=\(gridId) grid=\(id) row=\(rowStart) vertices=\(count) accepted=\(submitted)")
        if !submitted { flushFailed = true }
        flushHadContent = true
        markHostedDamage(gridId: id, rowStart: rowStart, rowEnd: rowStart + 1)
    }

    private func markHostedDamage(gridId id: Int64, rowStart: Int, rowEnd: Int) {
        tripleBufferLock.lock()
        defer { tripleBufferLock.unlock() }
        guard let layer = (pendingSurfaceLayers ?? committedSurfaceLayers).first(where: { $0.gridId == id }) else { return }
        let height = max(1, Float(shared.cellHeightPx ?? 1).rounded(.up))
        // Include the adjacent rows for glyph ink crossing a cell boundary.
        let first = max(0, Int(floor(layer.originPx.y / height)) + rowStart - 1)
        let end = min(Int(gridRows), Int(ceil(layer.originPx.y / height)) + rowEnd + 1)
        if first < end { flushDirtyRows.insert(integersIn: first..<end) }
    }

    func submitLayerCursor(gridId id: Int64, ptr: UnsafePointer<zonvie_vertex>?, count: Int) {
        guard isInFlush else { return }
        // Clearing another grid must not erase this surface's current cursor.
        guard count != 0 || pendingCursorGridId == id else {
            ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_ignore surface=\(gridId) grid=\(id) owner=\(pendingCursorGridId ?? 0) reason=empty_nonowner")
            return
        }
        ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_route surface=\(gridId) grid=\(id) vertices=\(count)")
        writeBracketCursorVertices(ptr: ptr, count: count)
        pendingCursorGridId = id
        flushHadContent = true
        // The surface's own cursor path forwards its rect to the shared cursor
        // shader state; a layer's cursor is the same surface's one cursor and
        // owes the same forward, or the effect stays where the cursor was
        // before it entered the float. Nothing is held here, and the projection
        // adds this layer's origin (see republishCursorShaderState).
        if count > 0, let ptr {
            forwardExternalCursorToMainShader(ptr: ptr, count: count, cursorGridId: id)
        } else {
            // The cursor left this layer, so stop republishing its rect on
            // window moves — same reason as the root path.
            lastForwardedCursorPx = nil
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
    private var committedSetIndex: Int = 0        // Protected by tripleBufferLock
    private var gpuInFlightCount: [Int] = [0, 0, 0] // Protected by tripleBufferLock
    private var rowStorageRetirement = SurfaceRowStorageRetirementState() // Protected by tripleBufferLock
    private var isInFlush: Bool = false           // Flush bracket thread only
    // Set (core thread) when a vertex/row buffer allocation fails during
    // this flush bracket. Consumed by ZonvieCore's on_flush_end via
    // consumeFlushFailed(), which cancels the bracket instead of committing
    // it and calls zonvie_core_abort_flush, then schedules a retry when the
    // core reports the flush retryable (mirrors
    // GridSurfaceRenderer.flushFailed).
    private(set) var flushFailed: Bool = false    // Flush bracket thread only
    // Complete row metadata lives independently in every set. A set only
    // carries rows changed since it last committed; scroll/resize/abort use a
    // full-copy barrier. This mirrors GridSurfaceRenderer and keeps a one-row
    // external flush O(changed rows) instead of O(total rows).
    //
    // Prepared to the cap at construction, as GridSurfaceRenderer's are. The
    // alternative was growing them on demand, which needed a main-queue worker,
    // a bracket-fairness gate, and a refusal path that `ZonvieCore`'s per-view
    // sweep escalated into an app-wide abort_flush — so one external float's
    // unprepared history stalled the main grid. The row-BUFFER ledger was moved
    // off that same design for the same reason (see submitVerticesRowRaw
    // below); this is the gate that was left behind.
    private let staleRowsBySet: [SparseRowSet] = [
        SparseRowSet(rowLimit: externalGridMaxRowBuffers, preparedRows: externalGridMaxRowBuffers),
        SparseRowSet(rowLimit: externalGridMaxRowBuffers, preparedRows: externalGridMaxRowBuffers),
        SparseRowSet(rowLimit: externalGridMaxRowBuffers, preparedRows: externalGridMaxRowBuffers),
    ]
    private let flushChangedRows = SparseRowSet(rowLimit: externalGridMaxRowBuffers, preparedRows: externalGridMaxRowBuffers)
    // Rows regenerated after the most recent font-generation transition in
    // this bracket. A commit may advance its set's font generation only when
    // every logical row was regenerated; cursor-only and partial commits keep
    // the older generation and are suppressed by the draw-generation gate.
    private let flushGeneratedRows = SparseRowSet(rowLimit: externalGridMaxRowBuffers, preparedRows: externalGridMaxRowBuffers)
    private var flushFontGeneration: UInt64 = 0
    private var flushGeneratedTotalRows: Int = 0
    private var flushGeneratedTotalCols: Int = 0
    private var rowStateNeedsFullSync = [false, false, false]
    private var flushHasStructuralRowChange = false
    // GridSurfaceRenderer carries a deliberately parallel ledger and
    // provisioning pass. The pure parts already live as shared free functions
    // in MetalTypes.swift, which take the lock and a `lockHeld` flag so two
    // surfaces can share code without sharing a lock; what is left is each
    // class's adapter. The lock COUNT differs for one reason: this class arms
    // scroll state from the main thread mid-gesture (`pendingGridScrollLock`)
    // and publishes eased offsets outside the bracket (`lock`), and a
    // core-thread bracket may block neither. Everything else — retention
    // included — is under the same lock as the vertex publish on both
    // surfaces. Touching the provisioning path itself: b83ff29 and 4b1ad75 are
    // the same mistake twice, a capacity gate that deferred allocation and
    // raced the per-flush row remap. Audit 2026-08-25, finding 037.
    // Fixed-size capacity ledger. The core callback only raises entries;
    // ZonvieCore's retry worker provisions metadata and MTLBuffers after the
    // bracket closes, before retrying the core flush.
    private let rowCapacity = SurfaceRowCapacityLedger(maxRowBuffers: 20_000)

    /// Read and clear flushFailed. Called once per flush from on_flush_end.
    func consumeFlushFailed() -> Bool {
        let v = flushFailed
        flushFailed = false
        return v
    }

    private func requirePreparedRowCapacity(
        row: Int,
        vertexCount: Int,
        totalRows: Int,
        lockHeld: Bool = false,
        useWriteMapping: Bool = false
    ) -> Bool {
        let ok = requireSurfaceRowCapacity(
            bufferSets: bufferSets,
            ledger: rowCapacity,
            lock: tripleBufferLock,
            lockHeld: lockHeld,
            row: row,
            vertexCount: vertexCount,
            totalRows: totalRows,
            maxRowBuffers: maxRowBuffers,
            mappingSetIndex: useWriteMapping ? writeSetIndex : flushSourceSetIndex,
            // An external surface is never asked about an already-physical row.
            rowIsPhysical: false,
            logLabel: "ExternalGridView:\(gridId)"
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
        tripleBufferLock.lock()
        defer { tripleBufferLock.unlock() }
        return rowCapacity.requiredRows > 0 || rowCapacity.provisioning
    }

    /// Called from the flush-retry queue before it acquires core grid_mu.
    func provisionPendingRowCapacity() -> SurfaceRowProvisionStatus {
        provisionSurfaceRowCapacity(
            ledger: rowCapacity,
            lock: tripleBufferLock,
            bufferSets: bufferSets,
            device: mtlDevice,
            maxRowBuffers: maxRowBuffers,
            logLabel: "ExternalGridView:\(gridId)",
            isBusyLocked: { bracketOpen || gpuInFlightCount.contains(where: { $0 != 0 }) },
            busyLogDetailLocked: { "bracketOpen=\(bracketOpen) gpuInFlight=\(gpuInFlightCount)" }
        )
    }

    /// Same-slot buffers of the sets currently GPU in-flight (up to two —
    /// inflightSemaphore allows 2 concurrent draws here). Used by the COW
    /// detach alias guard in ensureSurfaceRowBuffer: buffer objects only
    /// alias across sets at the same physical slot index (shallow copies
    /// preserve array positions).
    private func inflightRowBuffers(atSlot slot: Int) -> (MTLBuffer?, MTLBuffer?) {
        tripleBufferLock.lock()
        defer { tripleBufferLock.unlock() }
        return inflightRowBuffersLocked(atSlot: slot)
    }

    /// Lock-free variant for callers already holding tripleBufferLock
    /// (NSLock is non-recursive — re-locking would deadlock the main thread).
    private func inflightRowBuffersLocked(atSlot slot: Int) -> (MTLBuffer?, MTLBuffer?) {
        var first: MTLBuffer? = nil
        var second: MTLBuffer? = nil
        for i in 0..<3 where gpuInFlightCount[i] > 0 {
            let bufs = bufferSets[i].rowState.buffers
            let buf = slot < bufs.count ? bufs[slot] : nil
            if first == nil {
                first = buf
            } else {
                second = buf
            }
        }
        return (first, second)
    }
    private var flushHadContent: Bool = false     // True if vertices were submitted during this flush
    private var commitRevision: UInt64 = 0        // Protected by tripleBufferLock
    private var lastCommitTime: UInt64 = 0        // Protected by tripleBufferLock — mach_absolute_time of last visual commit
    private var lastDrawnRevision: UInt64 = 0     // Draw only
    private var committedGridRows: UInt32 = 0     // Protected by tripleBufferLock
    private var committedGridCols: UInt32 = 0     // Protected by tripleBufferLock
    /// The committed/write/free row sets, the cursor slots, the commit
    /// revision, the committed grid size, pending dirty rows, pending scroll
    /// and layout damage — this surface's counterpart to the main surface's
    /// single `lock`, and the one the core thread holds across a flush.
    ///
    /// Outermost of the three: see `lock`'s comment for the full ordering
    /// invariant and the measurement behind keeping them apart.
    private let tripleBufferLock = NSLock()
    // GPU back-pressure: allow 2 in-flight command buffers.
    // With flush ops now running on core thread (not main), main thread is free
    // to process draw requests while GPU processes the previous frame.
    // Uses non-blocking tryWait since draw() runs on main thread.
    private let inflightSemaphore = DispatchSemaphore(value: 2)
    private let maxRowBuffers = externalGridMaxRowBuffers

    /// Occlusion and window-move observers; see viewDidMoveToWindow.
    private var occlusionObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []

    /// Last cursor box this view forwarded to the shared shader cursor
    /// state, in this grid's own local pixels, so a window move can
    /// re-project it. Nil while the cursor is not on this view's grid.
    private var lastForwardedCursorPx: (minX: Float, maxX: Float, minY: Float, maxY: Float)?
    private var lastForwardedCursorColor: (Float, Float, Float, Float)?
    /// Which grid the forwarded cursor belongs to: this surface's root, or a
    /// grid it draws as a layer. Its origin is resolved at projection time.
    private var lastForwardedCursorGridId: Int64 = 0

    // Active rendering mode: when new commits arrive, switch to isPaused=false
    // so MTKView draws at preferredFramesPerSecond (60fps). After idle, pause.
    /// Shared with MetalTerminalView (SurfaceDrawGate.swift). The threshold is
    /// this surface's own: see DrawLoopIdleCounter on why the two differ.
    private var idleCounter = DrawLoopIdleCounter(threshold: 10)

    // Scroll offset data stored as value-type; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race.
    private var scrollOffsetData: GridSurfaceRenderer.ScrollOffset?
    private var scrollOffsetActive: Bool = false
    /// One offset per hosted grid that is scrolling in its own right, sorted by
    /// grid id for `surfaceScrollOffset`'s binary search. The root's own offset
    /// stays in `scrollOffsetData`: that is the one the surface-wide passes
    /// bind. Published under `lock`, like `scrollOffsetData`.
    private var hostedScrollOffsetData: [GridSurfaceRenderer.ScrollOffset] = []
    /// Built outside `lock` (resolving an offset takes the main view's own
    /// locks) and copied in, so neither lock is ever held while taking the
    /// other. Persistent, so a scrolled frame does no heap work for it.
    private var hostedScrollOffsetScratch: [GridSurfaceRenderer.ScrollOffset] = []
    /// What `markScrollOffsetStatePresented` last froze, for the end-of-ease
    /// comparison the root's own `lastPresentedScrollOffsetData` makes.
    private var lastPresentedHostedScrollOffsetData: [GridSurfaceRenderer.ScrollOffset] = []
    private var hostedLayerOriginScratch: [(gridId: Int64, originYPx: Float, z: Int32)] = []
    private var lastPresentedScrollOffsetData: GridSurfaceRenderer.ScrollOffset?
    private var lastPresentedScrollOffsetActive: Bool = false
    /// Rows scrolled off this window's edge, kept alive so the band the
    /// smooth-scroll offset opens shows them instead of the edge row's
    /// background stretched over it. Same mechanism the main surface uses;
    /// only the copying differs (see captureRetainedRows).
    private var retention: ScrollRetention!
    /// Distance this grid's content has moved since the last capture, handed
    /// over by the grid_scroll callback. Summed because several notifications
    /// can land before a bracket opens. Guarded by `pendingGridScrollLock`.
    private var pendingGridScrollRows = 0
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
    /// `tripleBufferLock`, like GridSurfaceRenderer's set of the same name.
    private var bracketStagedGrids: Set<Int64> = []
    /// Indices into the frame's retained snapshot belonging to the layer being
    /// drawn. Persistent so the layer pass allocates nothing per frame.
    private var retainedIndexScratch: [Int] = []
    private var smoothScrollSeeds: [(gridId: Int64, rowsDelta: Int)] = []
    /// The scrollable row span of this window: the grid minus its viewport
    /// margins (a winbar makes marginTop 1, and its row does not scroll).
    /// Armed on the main thread as each gesture scroll is sent, because
    /// Neovim's response can land before the next frame. Guarded by
    /// `pendingGridScrollLock`.
    private var scrollCaptureBounds: (top: Int, bottomEx: Int)?
    /// The input side of scrolling: `scrollCaptureBounds`,
    /// `pendingGridScrollRows` and `smoothScrollSeeds`, armed on the MAIN
    /// thread as a gesture is sent and spent by a flush.
    ///
    /// Innermost of the three, and the only lock `tripleBufferLock` is ever
    /// held across (twice, in `commitFlush`). Never taken in the other order.
    private let pendingGridScrollLock = NSLock()

    // Accumulated scroll delta (consumed by draw, survives across flushes)
    // Protected by tripleBufferLock (accessed from both flush ops and draw)
    private var pendingScrollAccum: SurfaceRowScroll? = nil

    // Dirty rows accumulated during flush (consumed by draw)
    // Protected by tripleBufferLock
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
    // tripleBufferLock; written only while isInFlush). A draw() interleaving
    // with a flush can consume pendingDirtyRows BEFORE commitFlush publishes
    // committedSetIndex: it redraws from the OLD committed set and the marks
    // are lost, so the newly committed rows are never marked dirty again.
    // commitFlush re-publishes these staged marks so the next draw() redraws
    // the rows from the newly committed set. Idempotent when no draw()
    // interleaved. Mirrors GridSurfaceRenderer's flushDirtyRows.
    private var flushDirtyRows: IndexSet = IndexSet()
    /// `pendingDirtyRows` as the current bracket found it, so a published row
    /// shift can move those marks without touching the ones this bracket made.
    /// Written at beginFlush, read at commitFlush; both on the core thread.
    private var carriedDirtyRows: IndexSet = IndexSet()

    // Persistent back buffer for partial redraw and GPU scroll copy
    private var backBuffer: MTLTexture? = nil
    private var backBufferSize: CGSize = .zero
    /// Per-view shader timing state. Owning this here (instead of the
    /// shared GridSurfaceRenderer) keeps iFrame / iTimeDelta /
    /// iFrameRate independent of draw order across views.
    private let shaderTiming = GridSurfaceRenderer.ShaderViewTimingState()
    /// Ping-pong render targets for multi-pass custom shader chains.
    /// Allocated lazily inside draw() when pipelines.count > 1.
    private let customShaderPong = SurfacePingPongTextures()
    private let scrollScratch = SurfaceScrollScratchTexture()

    // Blur transparency support
    private let blurEnabled: Bool
    private let isDecoratedSurface: Bool
    private var backgroundAlphaBuffer: MTLBuffer?

    // Viewport origin offset (in pixels) for decorated windows where the MTKView
    // fills the full container but grid content is inset by padding.
    // Allows bloom blur to bleed into the padding area around grid content.
    var viewportOriginPx: CGPoint = .zero

    // --- Post-process bloom (neon glow) ---
    // Pipelines and sampler are shared from GridSurfaceRenderer.
    // Textures are per-view (sizes differ per window).
    private let glowTextures = SurfaceGlowTextures()

    // Cursor blink support
    private var cursorBlinkBuffer: MTLBuffer?
    private var cursorBlinkStateStorage: Bool = true
    var cursorBlinkState: Bool {
        get {
            tripleBufferLock.lock()
            defer { tripleBufferLock.unlock() }
            return cursorBlinkStateStorage
        }
        set {
            tripleBufferLock.lock()
            cursorBlinkStateStorage = newValue
            tripleBufferLock.unlock()
        }
    }
    private var lastRenderedBlinkState: Bool = true
    private var lastKnownCursorRow: Int = -1

    // Separate cursor vertex buffer (not part of row buffers, immune to GPU scroll copy).
    private var cursorDirty: Bool = false

    /// One published cursor, independent of the row triple.
    ///
    /// The cursor used to live on `SurfaceBufferSet`, which tied publishing a
    /// cursor to rotating a row set: plain cursor motion — the commonest flush
    /// an external window sees — had to find a free row set, resynchronize the
    /// root's and every hosted grid's row state into it, and rotate, or be
    /// dropped when all three were GPU-in-flight. Cursor callbacks replace the
    /// cursor outright, so a slot needs no copy-forward; three of them are
    /// enough for the committed one plus the frames in flight.
    /// Mirrors GridSurfaceRenderer's cursor triple.
    private final class SurfaceCursorSlot {
        var vertexBuffer: MTLBuffer? = nil
        var vertexBufferCap: Int = 0
        var vertexCount: Int = 0
    }
    /// All four guarded by `tripleBufferLock`, like the row triple's own state.
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
    /// `tripleBufferLock`.
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
            state: &rowStorageRetirement
        )
    }

    // True while a core-thread flush bracket is open on this view. Unlike
    // `isInFlush` (core-thread-owned, unsafe to read from main), this is
    // written and read ONLY under tripleBufferLock, so main-thread
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

    /// Caller must hold tripleBufferLock. Rows submitted before a font or
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
    /// hold tripleBufferLock so beginFlush and capacity growth cannot replace
    /// sparse history in the middle of this update.
    private func recordCommittedRowMutationLocked(
        committedIndex: Int,
        rows: some Sequence<Int>,
        structural: Bool
    ) {
        staleRowsBySet[committedIndex].removeAll()
        rowStateNeedsFullSync[committedIndex] = false
        if structural {
            for i in bufferSets.indices where i != committedIndex {
                staleRowsBySet[i].removeAll()
                rowStateNeedsFullSync[i] = true
            }
        } else {
            for row in rows {
                for i in bufferSets.indices
                where i != committedIndex && !rowStateNeedsFullSync[i] {
                    staleRowsBySet[i].insert(row)
                }
            }
        }
    }

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
          backgroundAlphaBuffer: MTLBuffer,
          cursorBlinkBuffer: MTLBuffer,
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
        self.backgroundAlphaBuffer = backgroundAlphaBuffer
        self.cursorBlinkBuffer = cursorBlinkBuffer

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

        if gridId == ZonvieCore.cmdlineGridId {
            registerForDraggedTypes([.fileURL])
        }

        if let buf = self.backgroundAlphaBuffer {
            var alpha = surfaceBackgroundAlpha()
            ZonvieCore.appLog("[ExternalGridView] backgroundAlphaBuffer alpha=\(alpha) isDecoratedSurface=\(isDecoratedSurface) gridId=\(gridId)")
            memcpy(buf.contents(), &alpha, MemoryLayout<Float>.size)
        }

        if let buf = self.cursorBlinkBuffer {
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

        setupScrollbar()
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
    private func logHostedLayerDraw(layer: SurfaceLayer, encodedRows: Int, of rows: Int) {
        guard ZonvieCore.appLogEnabled else { return }
        ZonvieCore.appLog(
            "[ext_layer_draw] surface=\(gridId) gridId=\(layer.gridId) rows=\(encodedRows) of=\(rows)"
        )
    }

    private func surfaceCustomShaderPipelines() -> [CustomShaderPipeline] {
        let pipelines = isDecoratedSurface
            ? shared.customShaderPipelinesDecorated
            : shared.customShaderPipelines
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
        guard isDecoratedSurface, let renderer = mainTerminalView?.renderer else { return false }
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
        // -101 = POPUPMENU_GRID_ID (matches grid.zig:9 / ZonvieCore.popupmenuGridId)
        if gridId == -101 { return 1.0 }
        return resolveSurfaceBackgroundAlpha(
            blurEnabled: blurEnabled,
            decoratedSurface: isDecoratedSurface,
            shaderChainConsumesSurface: shaderChainConsumesSurface
        )
    }

    deinit {
        ZonvieCore.appLog("[ExternalGridView] deinit: gridId=\(gridId)")

        // Invalidate scrollbar hide timer to break its run-loop retain.
        scrollbarHideTimer?.invalidate()
        scrollbarHideTimer = nil

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
            bs.mainVertexBuffer = nil
            bs.cursorVertexBuffer = nil
        }
        for slot in cursorSlots {
            slot.vertexBuffer = nil
            slot.vertexBufferCap = 0
            slot.vertexCount = 0
        }

        backBuffer = nil
        scrollScratch.invalidate()
        backgroundAlphaBuffer = nil
        cursorBlinkBuffer = nil

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
                self.idleCounter.noteActive()
                // Kick only the paused -> active transition. MTKView's
                // display link may otherwise wait one or more vsyncs after
                // unpausing; calling this for every already-active commit
                // would merely enqueue redundant AppKit invalidations.
                self.setNeedsDisplay(self.bounds)
            }
        }
    }

    /// Switch back to idle mode: manual redraw via setNeedsDisplay.
    private func deactivateDrawLoop() {
        guard !isPaused else { return }
        isPaused = true
        enableSetNeedsDisplay = true
    }

    private func hadRecentCommit(withinNs: UInt64) -> Bool {
        tripleBufferLock.lock()
        let t = lastCommitTime
        tripleBufferLock.unlock()
        return surfaceHadRecentCommit(lastCommitTime: t, withinNs: withinNs)
    }

    private func setupScrollbar() {
        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled else { return }

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

    /// Stage a font generation transition. This is safe on the core thread and
    /// is called there immediately after setFont(), before rows for the new
    /// font are submitted. The later main-queue notification is idempotent.
    func stageFontChanged(generation: UInt64) {
        tripleBufferLock.lock()
        let generationAdvanced = fontResetState.stage(generation: generation)
        if bracketOpen, generation > flushFontGeneration {
            flushFontGeneration = generation
            flushGeneratedRows.removeAll()
        }
        let totalRows = Int(committedGridRows)
        if totalRows > 0 { pendingDirtyRows.insert(integersIn: 0..<totalRows) }
        if generationAdvanced {
            // Force one draw even before the delayed main-queue notification.
            // The draw gate suppresses stale rows and clears the back buffer.
            commitRevision &+= 1
        }
        tripleBufferLock.unlock()
    }

    /// Notify that font has changed - reset presentation state and ensure an
    /// old committed generation is cleared. A new-generation commit wins.
    func notifyFontChanged(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        hasPresentedOnce = false
        stageFontChanged(generation: generation)
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
    @discardableResult
    func beginFlush() -> Bool {
        tripleBufferLock.lock()
        if rowCapacity.provisioning || rowCapacity.requiredRows > 0 || rowCapacity.hardFailure {
            tripleBufferLock.unlock()
            ZonvieCore.appLog("[ExternalGridView] beginFlush: waiting for row capacity provisioning gridId=\(gridId)")
            return false
        }
        flushDirtyRows.removeAll()
        // What the pending set held before this bracket added anything. Only
        // these marks describe pre-shift rows, and a row number this bracket
        // marks again does not make them the same mark — see
        // mergePublishedScrollDirtyRows.
        carriedDirtyRows = pendingDirtyRows
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
        tripleBufferLock.unlock()

        isInFlush = true
        flushHadContent = false
        pendingCursorGridId = committedCursorGridId
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

        tripleBufferLock.lock()
        let srcIdx = flushSourceSetIndex
        let picked = pickFreeBufferSetIndex(
            count: 3,
            committedIndex: srcIdx,
            gpuInFlightCount: gpuInFlightCount
        )
        if picked == -1 {
            let inf = gpuInFlightCount
            tripleBufferLock.unlock()
            flushFailed = true
            ZonvieCore.appLog("[ExternalGridView] prepareRowWriteState: no free buffer set, dropping flush gridId=\(gridId) committed=\(srcIdx) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return false
        }
        writeSetIndex = picked
        rowWritePrepared = true
        tripleBufferLock.unlock()

        gridBuffers.copyGridIds(into: &layerGridIdScratch)
        for id in layerGridIdScratch where id != gridId {
            let sets = gridBuffers.sets(for: id)
            copySurfaceBufferSetRowState(from: sets[srcIdx], to: sets[picked])
        }
        // Discard retention staged by a bracket that aborted instead of
        // committing; publication only ever happens from commitFlush. Then
        // capture what this flush's scroll is about to take off the edge,
        // while the committed set still holds the on-screen rows.
        retention.beginFlush()
        pendingGridScrollLock.lock()
        stagedSmoothScrollSeeds.removeAll(keepingCapacity: true)
        pendingGridScrollLock.unlock()
        captureRetainedRowsForPendingScroll()
        // Clear stale scroll staging from a previous bracket on this set
        // (mirrors GridSurfaceRenderer.beginFlush's dst.pendingScroll = nil).
        bufferSets[picked].pendingScroll = nil
        let src = bufferSets[srcIdx]
        let dst = bufferSets[picked]
        let perfStarted = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let sync = syncSurfaceWriteSetRowState(
            from: src,
            to: dst,
            staleRows: staleRowsBySet[picked].rows,
            needsFullSync: rowStateNeedsFullSync[picked],
            maxRowBuffers: maxRowBuffers
        )
        if ZonvieCore.appLogEnabled {
            let elapsedUs = (CFAbsoluteTimeGetCurrent() - perfStarted) * 1_000_000
            let elapsedUsString = String(format: "%.1f", elapsedUs)
            ZonvieCore.appLogPerf("[perf] external_begin_prepare gridId=\(gridId) mode=\(sync.mode) syncedRows=\(sync.syncedRows) totalRows=\(src.rowState.buffers.count) us=\(elapsedUsString)")
        }
        // No cursor carry-forward: the cursor lives on its own triple now, and
        // a row-set rotation neither publishes nor invalidates it. A staged
        // cursor is left alone too — draw() publishes it into a free slot
        // without needing this bracket to reach a commit.
        tripleBufferLock.lock()
        tripleBufferLock.unlock()
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
        tripleBufferLock.lock()
        pendingSurfaceLayers = nil
        pendingCursorGridId = nil
        // Only a bracket that acquired a row set left one half-written.
        if bracketOpen, rowWritePrepared, writeSetIndex >= 0 {
            rowStateNeedsFullSync[writeSetIndex] = true
            staleRowsBySet[writeSetIndex].removeAll()
        }
        rowWritePrepared = false
        writeSetIndex = -1
        // An abandoned bracket publishes no cursor. The slot it wrote is simply
        // released; the committed one is still whatever was last published.
        cursorWriteSetIndex = -1
        flushChangedRows.removeAll()
        flushGeneratedRows.removeAll()
        flushHasStructuralRowChange = false
        bracketOpen = false
        tripleBufferLock.unlock()
    }

    /// Commit flush — publish write set as the new committed state for draw().
    /// Called from core thread (thread-safe via tripleBufferLock).
    func commitFlush() {
        guard isInFlush else { return }
        FrameTracer.trace(.commitFlush, seq: UInt32(truncatingIfNeeded: gridId))
        let hadContent = flushHadContent
        // Captured before the bracket's state is reset below; -1 names a commit
        // that published no rows.
        let tracedWriteSet = rowWritePrepared ? writeSetIndex : -1
        if hadContent {
            // What this bracket actually published. A flush that only moved the
            // cursor took no row set and rotates none: it must not bump the
            // commit revision either, or draw() reads a new commit with no dirty
            // row, fails its cursor-only test and clears the whole surface to
            // redraw content that did not change.
            let publishedRows = rowWritePrepared
            let publishedLayers = pendingSurfaceLayers != nil
            let cursorOnlyCommit = !publishedRows && !publishedLayers
            let layoutContracted = publishedRows
                && (bufferSets[flushSourceSetIndex].knownTotalRows > bufferSets[writeSetIndex].knownTotalRows
                    || bufferSets[flushSourceSetIndex].knownTotalCols > bufferSets[writeSetIndex].knownTotalCols)
            tripleBufferLock.lock()
            if publishedRows {
                committedSetIndex = writeSetIndex
            }
            // The cursor this bracket wrote becomes visible with the rows it
            // belongs to. A bracket that wrote none leaves the published slot
            // where it is — nothing about a row rotation ages the cursor.
            if cursorWriteSetIndex != -1 {
                committedCursorSetIndex = cursorWriteSetIndex
                cursorWriteSetIndex = -1
                // Arm the redraw in the same lock that publishes the slot, the
                // way flushDirtyRows is re-published for rows. Two ways this
                // frame would otherwise never be drawn: a draw() that
                // interleaved between the submit and this commit already
                // consumed the flag the submit set, and submitLayerCursor never
                // sets one at all. Neither is covered by the commit revision
                // any more — a cursor-only commit deliberately leaves it alone.
                cursorDirty = true
            }
            committedGridRows = gridRows
            committedGridCols = gridCols
            committedCursorGridId = pendingCursorGridId
            // Layers and the vertices they place become visible together.
            if let staged = pendingSurfaceLayers {
                // How far each hosted layer's committed placement has travelled,
                // counted upwards to match on_grid_scroll's rowsDelta. The float
                // ledger pairs this with the anchor's compensation so a float is
                // not handed the offset for a step its own placement already
                // performed. Accumulated here for the same reason the main
                // renderer accumulates it at its own promotion: this is the only
                // point a placement change is a discrete, known event.
                let ledgerCellHeightPx = Float(shared.cellHeightPx ?? 0)
                if ledgerCellHeightPx > 0 {
                    for layer in staged where layer.gridId != gridId {
                        guard let previous = committedSurfaceLayers.first(where: { $0.gridId == layer.gridId })
                        else { continue }
                        let rowsUp = Int(((previous.originPx.y - layer.originPx.y) / ledgerCellHeightPx).rounded())
                        if rowsUp != 0 { layerPlacementRowsUp[layer.gridId, default: 0] += rowsUp }
                    }
                }
                committedSurfaceLayers = staged
                pendingSurfaceLayers = nil
                // A destroyed grid's travel describes a layer that no longer
                // exists, and its id is reused by the next float a scroll makes.
                if layerPlacementRowsUp.count > staged.count {
                    layerPlacementRowsUp = layerPlacementRowsUp.filter { entry in
                        staged.contains { $0.gridId == entry.key }
                    }
                }
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
                    pendingGridScrollLock.lock()
                    smoothScrollSeeds.append(contentsOf: stagedSmoothScrollSeeds)
                    stagedSmoothScrollSeeds.removeAll(keepingCapacity: true)
                    pendingGridScrollLock.unlock()
                }
                // The distance this bracket captured against is only spent now
                // that its vertices are the committed ones; a cancelled bracket
                // leaves it for the next (see captureRetainedRowsForPendingScroll).
                pendingGridScrollLock.lock()
                pendingGridScrollRows = 0
                pendingGridScrollLock.unlock()
            }
            mainTerminalView?.renderer.publishCursorShaderState()
            // Every commit bumps, as GridSurfaceRenderer's does. The revision
            // answers one question — "is the committed state a generation this
            // draw has not seen?" — and nothing else. Whether the back buffer may
            // be reused is asked of the CONTENT predicates below, which is what
            // the suppression used to stand in for.
            commitRevision &+= 1
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
            // always commits the main renderer (which commits the atlas)
            // before calling this function, both on the core/RPC thread.
            //
            // A cursor-only commit rotates no set, so it refreshes the standing
            // one — and only while no frame is reading it, because draw() takes
            // this reference outside the lock. A cursor glyph that missed the
            // refresh still draws: within one atlas generation the texture
            // object does not change, and a generation change is caught by
            // committedFontIsCurrent instead.
            if publishedRows {
                bufferSets[writeSetIndex].atlasTextureSnapshot = mainTerminalView?.renderer.committedAtlasSnapshot()
            } else if gpuInFlightCount[committedSetIndex] == 0 {
                bufferSets[committedSetIndex].atlasTextureSnapshot = mainTerminalView?.renderer.committedAtlasSnapshot()
            }
            // Merge the write set's staged scroll into the global accumulator.
            // Done here (under lock, after committedSetIndex update) so draw()
            // never sees a scroll delta that precedes the matching vertex data
            // (mirrors GridSurfaceRenderer.commitFlush).
            if publishedRows, let ps = bufferSets[writeSetIndex].pendingScroll {
                // Marks an earlier bracket left, that no draw has consumed,
                // still name pre-shift rows: this bracket rotated the slots
                // under them. This bracket's own marks are left where they are,
                // since the core sends every shift hint before the rows and
                // they were made post-shift. Runs before the branches below,
                // which mark rows that already describe post-remap content.
                mergePublishedScrollDirtyRows(
                    pending: &pendingDirtyRows,
                    carried: carriedDirtyRows,
                    rowStart: ps.rowStart,
                    rowEnd: ps.rowEnd,
                    rowsDelta: ps.rowsDelta
                )
                if let existing = pendingScrollAccum,
                   existing.rowStart == ps.rowStart,
                   existing.rowEnd == ps.rowEnd {
                    pendingScrollAccum = SurfaceRowScroll(
                        rowStart: ps.rowStart, rowEnd: ps.rowEnd,
                        colStart: ps.colStart, colEnd: ps.colEnd,
                        // Wrapping add: matches GridSurfaceRenderer.commitFlush's
                        // &+ for the same accumulator (core-sourced i32 deltas
                        // can't realistically overflow 64-bit Int, but avoid a
                        // hard trap/crash on a corrupted extreme value).
                        rowsDelta: clampRowsDelta(existing.rowsDelta &+ ps.rowsDelta),
                        totalRows: ps.totalRows, totalCols: ps.totalCols
                    )
                } else {
                    // Region mismatch: the old accumulator's blit is dropped,
                    // but its row slots were already remapped — dirty its rows
                    // so they redraw from the committed post-scroll vertices.
                    if let existing = pendingScrollAccum,
                       existing.rowEnd > existing.rowStart {
                        pendingDirtyRows.insert(integersIn: existing.rowStart..<existing.rowEnd)
                    }
                    pendingScrollAccum = ps
                }
                // Committed sets must not retain the staged scroll: draw()'s
                // `pendingScrollAccum ?? committed.pendingScroll` fallback
                // would re-apply it on a later frame.
                bufferSets[writeSetIndex].pendingScroll = nil
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
            flushChangedRows.removeAll()
            flushGeneratedRows.removeAll()
            flushHasStructuralRowChange = false
            rowWritePrepared = false
            writeSetIndex = -1
            bracketOpen = false
            tripleBufferLock.unlock()
        } else {
            // Contentless bracket: nothing rotates. Close the bracket flag
            tripleBufferLock.lock()
            cursorWriteSetIndex = -1
            flushChangedRows.removeAll()
            flushGeneratedRows.removeAll()
            flushHasStructuralRowChange = false
            rowWritePrepared = false
            writeSetIndex = -1
            bracketOpen = false
            tripleBufferLock.unlock()
        }
        isInFlush = false
        if hadContent {
            ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=surface_commit surface=\(gridId) write_set=\(tracedWriteSet)")
            activateDrawLoop()
        }
    }

    /// Record how far this grid's content just moved. Called from the
    /// grid_scroll callback on the core thread; the capture itself waits for
    /// this view's flush bracket to open (see captureRetainedRowsForPendingScroll).
    func noteGridScroll(rowsDelta: Int) {
        guard GridSurfaceRenderer.smoothScrollEnabled, rowsDelta != 0 else { return }
        pendingGridScrollLock.lock()
        pendingGridScrollRows += rowsDelta
        pendingGridScrollLock.unlock()
    }

    /// The displacement this window is currently drawing its grid with, in
    /// main-window drawable pixels — the space `forwardExternalCursorToMainShader`
    /// measures the cursor rect in.
    ///
    /// Taken from this view's own committed scroll offset rather than the
    /// renderer's shared one, which follows the main view's draw cadence.
    /// Returns 0 when nothing is displaced, which is also what the cursor
    /// shader needs then.
    /// Every input is the frame's own, passed in rather than re-read here.
    /// The cursor body is placed from the committed snapshot draw(in:) takes
    /// once, under one hold; a second read taken later in the same frame can
    /// answer a flush that has committed since — or, worse, one that has not
    /// committed at all, which is what `pendingSurfaceLayers` would have given.
    /// The effect would then be displaced on one generation's placement while
    /// the cursor it tracks was drawn on another's, and a lock around each read
    /// does nothing about that: the two reads are individually consistent and
    /// still disagree.
    private func cursorScrollOffsetPxForShader(
        ownerGridId: Int64,
        offset: GridSurfaceRenderer.ScrollOffset?,
        viewportHeightPx: Float
    ) -> Float? {
        // The cursor rect is shared with the main surface and every other
        // external window. Only displace it when the cursor is on a grid THIS
        // surface draws — its own, or one it hosts as a layer; otherwise say
        // nothing and let the owner's value stand.
        guard let renderer = mainTerminalView?.renderer,
              renderer.shaderCursorBelongs(toGrid: ownerGridId) else { return nil }
        // `offset` is the owner grid's EFFECTIVE displacement, resolved by the
        // caller the same way drawHostedLayers resolves a layer's: the grid's
        // own offset when it scrolls in its own right, the root's when it only
        // follows the buffer, and nil when it stands still. A fixed float's
        // cursor is drawn at a standstill, so its effect stands still with it.
        guard let offset else { return 0 }
        // Undo computeScrollOffset's NDC conversion against the viewport height
        // THIS frame drew with -- the caller's own
        // SurfaceViewportMetrics.fragmentHeight, which is the value the cursor
        // body displaces itself by. Deriving it here from the renderer's cell
        // height instead would recompute the same formula against a linespace
        // the core may have changed since the frame measured it, and the effect
        // would convert the offset on one height while the cursor it tracks was
        // placed on another. Taking the number rather than its ingredients is
        // what makes the two unable to disagree.
        // Both terms of the shared `displacedLayerOriginPx` guard, for the same
        // reason: this result is consumed as pixel geometry, and a non-finite
        // offset propagates into a rounding that traps.
        guard viewportHeightPx > 0, offset.offset_y.isFinite else { return 0 }
        return -offset.offset_y * viewportHeightPx / 2.0
    }

    /// Tell this window which of its rows actually scroll. Called from the
    /// scroll input path on the main thread, where the grid's viewport margins
    /// are readable without blocking.
    func setScrollCaptureBounds(top: Int, bottomEx: Int) {
        pendingGridScrollLock.lock()
        scrollCaptureBounds = bottomEx > top ? (top: top, bottomEx: bottomEx) : nil
        pendingGridScrollLock.unlock()
    }

    /// Capture the rows the pending scroll takes off this window's edge.
    ///
    /// Runs at bracket open, which is the last moment the committed set still
    /// holds the on-screen content — by the end of the flush its rows have
    /// been regenerated or their slots rotated.
    ///
    /// This is the ONLY capture for this surface. `applyRowScroll` covers just
    /// the core's row-scroll fast path, which the core does not always take,
    /// whereas grid_scroll is reported for every scroll; and ZonvieCore opens
    /// the bracket immediately before calling `applyRowScroll`, so capturing
    /// there as well would stage the same rows twice.
    private func captureRetainedRowsForPendingScroll() {
        guard GridSurfaceRenderer.smoothScrollEnabled else { return }
        // Read but do NOT consume: this bracket may be cancelled, and the core
        // never resends a grid_scroll (it consumes the notification as it
        // dispatches). Clearing here would lose the distance, leaving the
        // published rows a step behind the content they are drawn against —
        // stale lines over live text, with the edge stretch suppressed because
        // rows are still published. commitFlush clears it once the vertices
        // this capture belongs to are actually on screen.
        pendingGridScrollLock.lock()
        let rowsDelta = pendingGridScrollRows
        let bounds = scrollCaptureBounds
        pendingGridScrollLock.unlock()
        guard rowsDelta != 0 else { return }
        // Margins are not part of the scrolled region: a winbar occupies the
        // top row and stays put, so taking the whole grid would capture it and
        // miss the content row next to it — leaving the band's innermost row
        // blank. The span is however many rows the margins actually cover, so
        // there is nothing to guess: without it, capture nothing and let the
        // edge stretch have the band rather than retain the wrong rows.
        guard let bounds else { return }
        let rows = Int(committedGridRows > 0 ? committedGridRows : gridRows)
        // Seeding is decided by who compensates the scroll, not by which path
        // captured the rows: this same capture serves a trackpad gesture (which
        // compensates through the finger and owes no seed) and a keyboard
        // scroll that only reached here because an ease was already holding an
        // offset — that one owes one.
        captureRetainedRows(
            ws: bufferSets[flushSourceSetIndex],
            rowStart: bounds.top,
            rowEnd: min(bounds.bottomEx, rows),
            rowsDelta: rowsDelta,
            seedsEase: true
        )
    }


    /// Copy the rows about to leave this window's scroll region into the
    /// retention, so the band the smooth-scroll offset opens shows them
    /// instead of the edge row's background stretched across it.
    ///
    /// Only the row's DECO_SCROLLABLE vertices are copied (shared filter with
    /// the main renderer's grid_scroll capture — see
    /// copyRetainedScrollableRow). An external window owns its surface
    /// outright, so no OTHER grid mixes in, but its own rows still hold
    /// non-scrollable cells: a float border's "│" columns. A whole-row copy
    /// let those escape the offset shift and the content clip, landing them
    /// on the margin rows. Called from inside the flush bracket, before the
    /// slot remap.
    /// `seedsEase` mirrors the main renderer's split: the row-shift fast path
    /// owes a seed, the grid_scroll hand-over does not.
    ///
    /// It deliberately does NOT ask whether a gesture owns the grid. That is
    /// the tick's decision, on the main thread, where the gesture state lives:
    /// these seeds join the main surface's in the same `tickSmoothScroll`,
    /// which tells a gesture-owned grid from a decayed one below. Answering it
    /// here, on the core thread, dropped the seed outright — and a single-row
    /// step arriving while `pendingSentScroll` is non-zero is exactly the held
    /// key that needs one, so the picture snapped a whole cell. The main
    /// renderer's `captureLayerScrollStep` documents the same rule.
    /// Retain the rows a hosted layer's scroll is about to displace, so its own
    /// pass can ease them the way the root's are eased. The main surface does
    /// this for every layer it places; an external surface used to stage
    /// nothing for the layers it hosts, which is why a float inside one jumped
    /// a whole row while the window behind it glided.
    private func captureLayerScrollStep(
        gridId id: Int64,
        sets: [SurfaceBufferSet],
        rowStart: Int,
        rowEnd: Int,
        rowsDelta: Int
    ) {
        guard GridSurfaceRenderer.smoothScrollEnabled else { return }
        tripleBufferLock.lock()
        var stepped = bracketStagedGrids.contains(id)
        tripleBufferLock.unlock()

        let cs = sets[flushSourceSetIndex]
        if !stepped, cs.rowState.usingRowBuffers,
           let plan = ScrollRetention.plan(
               rowStart: rowStart,
               rowEnd: rowEnd,
               rowsDelta: rowsDelta,
               depth: retention.depthRows
           ) {
            retention.beginStep(gridId: id, rowsDelta: rowsDelta, pivotTargetRow: plan.pivotTargetRow)
            tripleBufferLock.lock()
            bracketStagedGrids.insert(id)
            tripleBufferLock.unlock()
            let capturedCellHeightPx = Float(shared.cellHeightPx ?? 0)
            for i in 0..<plan.count {
                let row = ScrollRetention.planRow(plan, i, rowsDelta: rowsDelta)
                captureOneLayerRetainedRow(
                    cs: cs,
                    gridId: id,
                    readRow: row,
                    targetRow: row - rowsDelta,
                    cellHeightPx: capturedCellHeightPx
                )
            }
            stepped = true
        }
        // commitFlush publishes the seeds only when a step was staged.
        guard stepped, abs(rowsDelta) == 1 else { return }
        tripleBufferLock.lock()
        stagedSmoothScrollSeeds.append((gridId: id, rowsDelta: rowsDelta))
        tripleBufferLock.unlock()
    }

    /// One row of `captureLayerScrollStep`, read out of the layer's own set.
    private func captureOneLayerRetainedRow(
        cs: SurfaceBufferSet,
        gridId id: Int64,
        readRow: Int,
        targetRow: Int,
        cellHeightPx: Float
    ) {
        guard readRow >= 0, readRow < cs.rowLogicalToSlot.count else { return }
        let slot = cs.rowLogicalToSlot[readRow]
        guard slot >= 0, slot < cs.rowState.counts.count, slot < cs.rowState.buffers.count else { return }
        let vc = cs.rowState.counts[slot]
        guard vc > 0, let srcBuf = cs.rowState.buffers[slot] else { return }
        let sourceRow = slot < cs.rowSlotSourceRows.count ? cs.rowSlotSourceRows[slot] : readRow
        guard let copied = copyRetainedScrollableRow(
            retention: retention,
            srcBuf: srcBuf,
            vertexCount: vc,
            gridId: id,
            scrollableMask: ZONVIE_DECO_SCROLLABLE
        ) else { return }
        retention.stage(RetainedScrollRow(
            buffer: copied.buffer,
            count: copied.count,
            gridId: id,
            sourceRow: sourceRow,
            targetRow: targetRow,
            cellHeightPx: cellHeightPx
        ))
    }

    private func captureRetainedRows(ws: SurfaceBufferSet, rowStart: Int, rowEnd: Int, rowsDelta: Int, seedsEase: Bool) {
        guard GridSurfaceRenderer.smoothScrollEnabled else { return }
        guard ws.rowState.usingRowBuffers else { return }
        guard let plan = ScrollRetention.plan(
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            depth: retention.depthRows
        ) else { return }

        let capturedCellHeightPx = Float(shared.cellHeightPx ?? 0)
        guard capturedCellHeightPx > 0 else { return }
        var stepOpened = false
        defer {
            if seedsEase, stepOpened, abs(rowsDelta) == 1 {
                pendingGridScrollLock.lock()
                stagedSmoothScrollSeeds.append((gridId: gridId, rowsDelta: rowsDelta))
                pendingGridScrollLock.unlock()
            }
        }
        for i in 0..<plan.count {
            let outgoingRow = ScrollRetention.planRow(plan, i, rowsDelta: rowsDelta)
            guard outgoingRow >= 0, outgoingRow < ws.rowLogicalToSlot.count else { continue }
            let slot = ws.rowLogicalToSlot[outgoingRow]
            guard slot >= 0, slot < ws.rowState.counts.count, slot < ws.rowState.buffers.count else { continue }
            let vc = ws.rowState.counts[slot]
            guard vc > 0, let srcBuf = ws.rowState.buffers[slot] else { continue }
            // Where these vertices actually sit: the slot remap leaves them at
            // their original row and lets draw() fix the position through
            // rowSlotSourceRows, so under a continuous scroll this drifts away
            // from the logical row.
            let sourceRow = slot < ws.rowSlotSourceRows.count ? ws.rowSlotSourceRows[slot] : outgoingRow

            if !stepOpened {
                retention.beginStep(
                    gridId: gridId,
                    rowsDelta: rowsDelta,
                    pivotTargetRow: plan.pivotTargetRow
                )
                stepOpened = true
            }
            guard let copied = copyRetainedScrollableRow(
                retention: retention,
                srcBuf: srcBuf,
                vertexCount: vc,
                gridId: gridId,
                scrollableMask: ZONVIE_DECO_SCROLLABLE
            ) else { continue }
            retention.stage(RetainedScrollRow(
                buffer: copied.buffer,
                count: copied.count,
                gridId: gridId,
                sourceRow: sourceRow,
                targetRow: outgoingRow - rowsDelta,
                cellHeightPx: capturedCellHeightPx
            ))
        }
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
            tripleBufferLock.lock()
            flushDirtyRows.insert(integersIn: rowStart..<rowEnd)
            tripleBufferLock.unlock()
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
        // Capture the outgoing rows when the grid_scroll callback handed over
        // no distance of its own. That hand-over is gated to gesture-owned
        // scrolls, so a keyboard or Neovim-initiated scroll arrives here with
        // nothing retained and no ease seed — the main surface takes both from
        // captureLayerScrollStep on this same fast path, which is what gives it
        // the animation an external window was missing. Guarded on the pending
        // distance, because capturing what the bracket-open capture already
        // staged would shift the same rows a second time.
        // Only a hand-over the bracket-open capture can actually USE counts as
        // one. It needs the scrollable span, and that is armed by the trackpad
        // input path alone — so a keyboard scroll arriving while an ease is
        // still running hands over a distance nothing can capture: the
        // grid_scroll gate fires on the offset that ease is holding, this guard
        // saw the distance and stood down, and the row went uncompensated.
        pendingGridScrollLock.lock()
        let handedOverByGridScroll = pendingGridScrollRows != 0 && scrollCaptureBounds != nil
        pendingGridScrollLock.unlock()
        if !handedOverByGridScroll {
            // The source set still holds the on-screen rows: this runs before
            // the remap below, the same ordering captureLayerScrollStep keeps.
            captureRetainedRows(
                ws: bufferSets[flushSourceSetIndex],
                rowStart: rowStart,
                rowEnd: rowEnd,
                rowsDelta: rowsDelta,
                seedsEase: true
            )
        }
        flushHasStructuralRowChange = true
        // The marks have to travel with the rows they describe. The remap below
        // moves a row's vertices to another logical row; a mark left at the
        // pre-shift index names content that is no longer there, and with the
        // blit accepted the row it moved to is never repainted. Only this
        // bracket's marks here: pendingDirtyRows carries marks a cancelled
        // bracket must keep as they are, so commitFlush shifts those instead,
        // against the shift it actually publishes.
        tripleBufferLock.lock()
        shiftSurfaceRowIndices(
            &flushDirtyRows,
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta
        )
        tripleBufferLock.unlock()
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

    /// Write cursor vertices into a buffer set's dedicated cursor buffer
    /// (allocate only on capacity growth; count == 0 clears the cursor).
    /// Caller must guarantee the slot is not GPU-in-flight — `pickCursorSlot`
    /// answers that, under tripleBufferLock.
    @discardableResult
    private func writeCursorVertices(into slot: SurfaceCursorSlot, ptr: UnsafePointer<zonvie_vertex>?, count: Int) -> Bool {
        if count > 0, let validPtr = ptr {
            let byteCount = count * MemoryLayout<Vertex>.stride
            if slot.vertexBuffer == nil || slot.vertexBufferCap < byteCount {
                let newCap = max(byteCount, 48 * MemoryLayout<Vertex>.stride)
                slot.vertexBuffer = mtlDevice.makeBuffer(length: newCap, options: .storageModeShared)
                slot.vertexBufferCap = slot.vertexBuffer != nil ? newCap : 0
            }
            if let buf = slot.vertexBuffer {
                memcpy(buf.contents(), validPtr, byteCount)
                slot.vertexCount = count
            } else {
                return false
            }
        } else {
            slot.vertexCount = 0
        }
        return true
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
        tripleBufferLock.lock()
        if cursorWriteSetIndex == -1 {
            cursorWriteSetIndex = pickCursorSlotLocked()
        }
        let target = cursorWriteSetIndex
        let inf = cursorGpuInFlightCount
        let committed = committedCursorSetIndex
        tripleBufferLock.unlock()

        if target != -1, writeCursorVertices(into: cursorSlots[target], ptr: ptr, count: count) {
            return
        }
        tripleBufferLock.lock()
        cursorWriteSetIndex = -1
        tripleBufferLock.unlock()
        ZonvieCore.appLog("[ExternalGridView] cursor write failed gridId=\(gridId) committed=\(committed) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
        flushFailed = true
    }

    /// A cursor slot that is neither published nor being read by the GPU.
    /// -1 when nothing is free. Caller holds `tripleBufferLock`.
    private func pickCursorSlotLocked() -> Int {
        for index in 0..<cursorSlots.count
        where index != committedCursorSetIndex
            && cursorGpuInFlightCount[index] == 0 {
            return index
        }
        return -1
    }

    /// Release one protected GPU read of a cursor slot. Caller holds
    /// `tripleBufferLock`. Unlike the row triple there is no storage
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
        // publishes them into committedGridRows/Cols.
        gridRows = UInt32(totalRows)
        gridCols = UInt32(totalCols)

        let isCursorUpdate = (flags & 2) != 0  // ZONVIE_VERT_UPDATE_CURSOR
        if isCursorUpdate {
            if count == 0 && pendingCursorGridId != gridId {
                ZonvieCore.renderTrace("flush=\(renderTraceFlushId) event=cursor_ignore surface=\(gridId) grid=\(gridId) owner=\(pendingCursorGridId ?? 0) reason=empty_nonowner")
                return
            }
            pendingCursorGridId = gridId
            tripleBufferLock.lock()
            lastKnownCursorRow = rowStart
            cursorDirty = true
            tripleBufferLock.unlock()
            // A slot of this bracket's own, rotated in at commit. Reusing
            // the one already picked keeps a bracket that writes the cursor
            // twice from consuming two slots.
            writeBracketCursorVertices(ptr: ptr, count: count)
            // A cursor update IS flush content: without this, a cursor-only
            // flush (plain cursor movement — no row changed) never rotates
            // committedSetIndex, the cursor written above stays orphaned in the
            // write set, and draw() keeps showing the stale committed cursor
            // (invisible cursor trail during j-repeat on external windows).
            flushHadContent = true
            if count > 0, let validPtr = ptr {
                // Forward the cursor rect into the main renderer's
                // shader cursor state so cursor shaders running through
                // any HWND see the active (cmdline / popupmenu / float)
                // cursor instead of the main grid's stale cursor. Verts
                // arrive in this view's local NDC; translate to main
                // window drawable px using the same screen-space
                // parameters the shader uniforms use.
                forwardExternalCursorToMainShader(ptr: validPtr, count: count, cursorGridId: gridId)
            } else {
                // The cursor left this window: stop republishing its rect on
                // window moves, or this view would keep overwriting whichever
                // surface now owns the cursor.
                lastForwardedCursorPx = nil
            }
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
            flushGeneratedRows.removeAll()
            flushGeneratedTotalRows = totalRows
            flushGeneratedTotalCols = totalCols
            flushHasStructuralRowChange = true
            return
        }

        // In-bracket (core thread): write set is never GPU-in-flight.
        guard prepareRowWriteState() else { return }
        let sourceSet = bufferSets[flushSourceSetIndex]
        let structural = !sourceSet.rowState.usingRowBuffers
            || totalRows != sourceSet.knownTotalRows
            || totalCols != sourceSet.knownTotalCols
        // Allocate synchronously (was gated behind requirePreparedRowCapacity
        // + allowAllocation: false), mirroring submitVerticesRowRaw in
        // GridSurfaceRenderer: the async pre-provisioning detour does not
        // converge under sustained scroll. The gate mattered more here than
        // on the main grid, because ZonvieCore's per-view flushFailed sweep
        // escalates any external failure into an app-wide abort_flush, so a
        // float's unprepared capacity stalled the main grid too.
        // requirePreparedRowCapacity is still used below, but only to record
        // a real allocation failure for the async recovery path.
        if !submitSurfaceRowVertices(
            target: bufferSets[writeSetIndex],
            sourceSet: sourceSet,
            device: mtlDevice,
            rowStart: rowStart,
            ptr: UnsafeRawPointer(ptr),
            count: count,
            maxRowBuffers: maxRowBuffers,
            totalRows: totalRows,
            totalCols: totalCols,
            inflightRowBuffers: { self.inflightRowBuffers(atSlot: $0) }
        ) {
            _ = requirePreparedRowCapacity(
                row: rowStart,
                vertexCount: count,
                totalRows: totalRows,
                useWriteMapping: true
            )
            flushFailed = true
        } else {
            tripleBufferLock.lock()
            recordGeneratedRowsLocked(
                rowStart: rowStart,
                rowCount: rowCount,
                totalRows: totalRows,
                totalCols: totalCols
            )
            tripleBufferLock.unlock()
            if structural {
                flushHasStructuralRowChange = true
            } else {
                for row in rowStart..<max(rowStart, rowStart + rowCount) {
                    flushChangedRows.insert(row)
                }
            }
        }
        // Track dirty rows for GPU scroll copy path, and stage into
        // flushDirtyRows so commitFlush can re-publish these marks if a
        // draw() steals them mid-flush (see flushDirtyRows doc comment;
        // mirrors GridSurfaceRenderer.markDirtyRows).
        tripleBufferLock.lock()
        for r in rowStart..<max(rowStart, rowStart + rowCount) {
            pendingDirtyRows.insert(r)
            flushDirtyRows.insert(r)
        }
        tripleBufferLock.unlock()
        flushHadContent = true
        return
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
        var minX: Float = ptr[0].position.0
        var maxX: Float = minX
        var minY: Float = ptr[0].position.1
        var maxY: Float = minY
        for i in 0..<count {
            let p = ptr[i].position
            if p.0 < minX { minX = p.0 }
            if p.0 > maxX { maxX = p.0 }
            if p.1 < minY { minY = p.1 }
            if p.1 > maxY { maxY = p.1 }
        }
        let c = ptr[0].color
        lastForwardedCursorPx = (minX: minX, maxX: maxX, minY: minY, maxY: maxY)
        lastForwardedCursorColor = (c.0, c.1, c.2, c.3)
        lastForwardedCursorGridId = cursorGridId
        republishCursorShaderState()
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
    private func republishCursorShaderState(reanchor: Bool = false) {
        guard let local = lastForwardedCursorPx,
              let color = lastForwardedCursorColor else { return }
        guard let mainView = mainTerminalView,
              let renderer = mainView.renderer else { return }
        // Same screen-space parameters the shader uniforms use, so the
        // cursor rect lands in the same coordinate system the shader
        // resolves against.
        let (screenRes, windowOffset) = screenSpaceParameters(
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
        let scale = Float(self.window?.backingScaleFactor ?? 2.0)
        let vpOriginX = Float(viewportOriginPx.x) * scale
        let vpOriginY = Float(viewportOriginPx.y) * scale
        // The origin of the grid the cursor is on, which the draw path also
        // feeds SurfaceViewportMetrics, so the two mappings cannot drift. A
        // layer's origin is already surface-absolute (drawHostedLayers binds
        // layer.originPx directly), so it REPLACES the root's rather than
        // adding to it. commitFlush replaces the array wholesale under
        // tripleBufferLock on the core thread, and this runs on both the core
        // thread (cursor forward) and the main thread (window move), so copy
        // the one value out under the lock — never hold it across the renderer
        // callout below. Resolved per call, not stored: a window move has to
        // reproject against the placement the surface holds now.
        tripleBufferLock.lock()
        let layers = pendingSurfaceLayers ?? committedSurfaceLayers
        let cursorOrigin = layers.first { $0.gridId == lastForwardedCursorGridId }?.originPx
            ?? layers.first?.originPx
            ?? simd_float2(0, 0)
        tripleBufferLock.unlock()
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
        let owner = lastForwardedCursorGridId
        let rect = (leftPx, botPx, rightPx - leftPx, botPx - topPx)
        if reanchor {
            // Window move: no commit will come to publish a staged value, and
            // the cursor has not moved relative to its text.
            renderer.reanchorCursorShaderState(rect: rect, gridId: owner)
        } else {
            renderer.setCursorShaderState(rect: rect, color: color, gridId: owner)
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
    ) -> (
        clearTopPx: Int,
        clearBottomPx: Int,
        dirtyRows: Range<Int>,
        clampedRowEnd: Int
    )? {
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

        scrollScratch.ensure(device: mtlDevice, drawableSize: backBufferSize, pixelFormat: backTexture.pixelFormat)
        guard let scratch = scrollScratch.texture,
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        encodeRowScrollBlit(blit, backTexture: backTexture, scratch: scratch, plan: plan)
        blit.endEncoding()

        return (plan.clearTopPx, plan.clearBottomPx, plan.dirtyRows, plan.clampedRowEnd)
    }

    /// The root rows a full-width scroll blit filled with hosted-layer pixels:
    /// every row a layer covers inside the scrolled region, and the rows those
    /// pixels were dragged into. Grid-local rows, like the plan's own dirty
    /// range. Appends without allocating while the caller's scratch keeps its
    /// capacity; a surface holds a handful of layers at most.
    private func appendRowsDraggedByLayers(
        into rows: inout [Int],
        regionStart: Int,
        regionEnd: Int,
        rowsDelta: Int,
        rowHeightPx: Int
    ) {
        guard rowHeightPx > 0, regionEnd > regionStart else { return }
        for (layer, _) in layerDrawSnapshot {
            guard layer.rows > 0, layer.cols > 0 else { continue }
            let topPx = Int(layer.originPx.y.rounded(.down))
            let bottomPx = topPx + layer.rows * rowHeightPx
            guard bottomPx > 0 else { continue }
            let firstRow = max(regionStart, topPx / rowHeightPx)
            let lastRow = min(regionEnd - 1, (bottomPx - 1) / rowHeightPx)
            guard lastRow >= firstRow else { continue }
            for row in firstRow...lastRow {
                rows.append(row)
                let dragged = row - rowsDelta
                if dragged >= regionStart, dragged < regionEnd { rows.append(dragged) }
            }
        }
    }




    func draw(in view: MTKView) {
        autoreleasepool {
            FrameTracer.trace(.drawBegin, seq: UInt32(truncatingIfNeeded: gridId))
            var finishedRedraw = false
            defer {
                FrameTracer.trace(.drawEnd, seq: UInt32(truncatingIfNeeded: gridId))
                if !finishedRedraw {
                    redrawScheduler.didDrawFrame()
                }
            }

            guard let pipeline = pipeline, let sampler = sampler else {
                ZonvieCore.appLog("[ExternalGridView] Pipeline not ready")
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
            // hasPresentedOnce gates it: occlusionState is published
            // asynchronously by the window server, so a window that was
            // just ordered in still reports "not visible" for a frame or
            // two. Parking there would leave a brand-new cmdline or
            // popupmenu panel empty until the notification lands — and a
            // window with nothing on screen yet has no stale content worth
            // protecting, so it is allowed to pay the acquire once.
            if hasPresentedOnce, let win = view.window,
               win.isMiniaturized || !win.occlusionState.contains(.visible) {
                ZonvieCore.appLog("[ext_draw_skip] gridId=\(gridId) window not visible; skipping frame")
                deactivateDrawLoop()
                return
            }

            if view.drawableSize.width <= 0 || view.drawableSize.height <= 0 {
                ZonvieCore.appLog("[ExternalGridView draw] gridId=\(gridId) early return: drawableSize invalid (\(view.drawableSize))")
                return
            }

            // Skip rendering for minimized windows. Reached only before the
            // first present, when the guard above stands down.
            // No frame-completion notification is needed here: unlike
            // MetalTerminalView (which uses redrawPending/didDrawFrame to
            // gate future redraws), ExternalGridView is driven directly
            // by setNeedsDisplay with no coalescing gate.
            if let window = view.window, window.isMiniaturized {
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

            // --- Snapshot committed state under lock (same pattern as GridSurfaceRenderer) ---
            let csi: Int
            let cci: Int
            let currentCommitRevision: UInt64
            let pendingScroll: SurfaceRowScroll?
            var submittedDirtyRows: [Int] = []

            let snappedGridRows: UInt32
            let snappedGridCols: UInt32
            let cursorDirtySnapshot: Bool
            let lastKnownCursorRowSnapshot: Int
            let cursorBlinkStateSnapshot: Bool
            let committedFontIsCurrent: Bool
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
            mainTerminalView?.serviceSharedScrollStateForExternalView()
            let hasScrollOffset = updateScrollShaderOffset()

            tripleBufferLock.lock()
            if rowCapacity.provisioning || rowCapacity.requiredRows > 0 || rowCapacity.hardFailure {
                let terminal = rowCapacity.hardFailure
                tripleBufferLock.unlock()
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
            retainedSnapshot = retention.snapshotPublished()
            currentCommitRevision = commitRevision
            snappedGridRows = committedGridRows
            snappedGridCols = committedGridCols
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
            cursorDirtySnapshot = cursorDirty
            cursorDirty = false
            lastKnownCursorRowSnapshot = lastKnownCursorRow
            cursorBlinkStateSnapshot = cursorBlinkStateStorage
            rootLayerOriginSnapshot = committedSurfaceLayers.first?.originPx ?? simd_float2(0, 0)
            layoutDamageSnapshot = pendingLayoutDamage
            pendingLayoutDamage = false
            // One read of the committed owner, used by everything this frame
            // places against it: the cursor body's origin, whether that origin
            // follows the scroll, and the shader effect that has to land on the
            // same cursor. Asking again later is how the body and the effect
            // came to answer different flushes.
            cursorOwnerSnapshot = committedCursorGridId ?? gridId
            cursorLayerOriginSnapshot = committedSurfaceLayers.first {
                $0.gridId == cursorOwnerSnapshot
            }?.originPx ?? .zero
            cursorLayerFollowsScrollSnapshot = committedSurfaceLayers.first {
                $0.gridId == cursorOwnerSnapshot && $0.gridId != gridId
            }?.followsScroll ?? false
            // Taken from the same committed entry as the flag above: the float
            // ledger is keyed by the pair (float, its anchor).
            cursorLayerAnchorGridSnapshot = committedSurfaceLayers.first {
                $0.gridId == cursorOwnerSnapshot && $0.gridId != gridId
            }?.anchorGrid ?? gridId
            layerDrawSnapshot.removeAll(keepingCapacity: true)
            for layer in committedSurfaceLayers where layer.gridId != gridId {
                if let sets = gridBuffers.existingSets(for: layer.gridId) {
                    layerDrawSnapshot.append((layer, sets[csi]))
                }
            }
            tripleBufferLock.unlock()
            defer {
                submittedDirtyRows.removeAll(keepingCapacity: true)
                swap(&submittedDirtyRows, &submittedDirtyRowsScratch)
            }

            // Snapshot the previous-frame gate state BEFORE draw() overwrites
            // it (lastRenderedBlinkState at the blink-detection line,
            // lastDrawnRevision right after hasNewCommit is computed), so the
            // bail helper below can roll both back — mirrors the
            // prevDrawnRevision/prevRenderedBlinkState rollback in
            // GridSurfaceRenderer.bailWithoutSubmit.
            let prevDrawnRevision = lastDrawnRevision
            let prevRenderedBlinkState = lastRenderedBlinkState

            // Restores state consumed above and schedules a retry when a later
            // resource acquisition fails (back buffer / command buffer / drawable).
            // Restoring the rows alone is NOT enough: by the time the loss sites
            // run, lastDrawnRevision has already been overwritten below, so a
            // retry draw would compute hasNewCommit == false and take the idle
            // early-exit, re-consuming and discarding the restored rows. Rolling
            // lastDrawnRevision (and lastRenderedBlinkState) back makes the retry
            // draw see the commit as new again.
            // restoreScroll: pass false when the scroll blit has ALREADY been
            // committed into backTex (the drawable-nil site) — re-queueing the
            // scroll there would double-shift the already-shifted pixels.
            func bailWithoutSubmit(_ reason: String, restoreScroll: Bool = true) {
                ZonvieCore.appLog("[WARNING][ExternalGridView] draw bailed (\(reason)); restoring dirty state for retry gridId=\(gridId)")
                tripleBufferLock.lock()
                // Element-wise: IndexSet(submittedDirtyRows) would allocate on
                // a bail path that already failed to acquire what it needed.
                for r in submittedDirtyRows { pendingDirtyRows.insert(r) }
                if layoutDamageSnapshot { pendingLayoutDamage = true }
                if cursorDirtySnapshot {
                    cursorDirty = true
                }
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
                tripleBufferLock.unlock()
                lastDrawnRevision = prevDrawnRevision
                lastRenderedBlinkState = prevRenderedBlinkState
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
            let tbLock = tripleBufferLock
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
            let snapGridRows = snappedGridRows > 0 ? snappedGridRows : gridRows
            let snapGridCols = snappedGridCols > 0 ? snappedGridCols : gridCols
            // External grids are row-mode only: the core reaches them through
            // on_vertices_row, and the ABI has no whole-surface callback.
            if !rowMode {
                return
            }
            if committed.rowState.buffers.isEmpty {
                return
            }

            let blinkStateChanged = cursorBlinkStateSnapshot != lastRenderedBlinkState
            lastRenderedBlinkState = cursorBlinkStateSnapshot

            let drawableSizeChanged = backBufferSize != view.drawableSize && backBuffer != nil
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
            let smoothScrolling = hasScrollOffset || wasScrollOffsetActiveInLastPresentedFrame()

            // Early exit: nothing changed.
            // cursorDirty alone races commitFlush(): a draw() call can read
            // and clear it for an in-bracket cursor submit that hasn't been
            // published yet (commitFlush runs later, from on_flush_end), so
            // by the time the NEW committed cursor becomes visible the flag
            // is already false and nothing else signals a redraw — the
            // cursor stays on the old committed content until an unrelated
            // dirty event happens to fire. hasNewCommit (commitRevision,
            // bumped atomically with committedSetIndex under
            // tripleBufferLock in commitFlush) closes that gap: any commit
            // this draw call hasn't seen yet also forces a cursor recheck,
            // independent of whether cursorDirty already got consumed early.
            let hasCursorUpdate = cursorDirtySnapshot || hasNewCommit

            // Animation exception mirrors GridSurfaceRenderer: when a
            // loaded custom shader references iTime / iFrame / etc., we
            // must proceed every frame and keep this view's draw loop
            // active, even with no Neovim-side changes. Without this,
            // popupmenu / messages / cmdline / ext-window background stays
            // frozen while the main window animates.
            let shaderAnimates = shared.anyCustomShaderNeedsAnimation
            if shaderAnimates {
                activateDrawLoop()
            }

            // Keep the draw loop alive while this grid's edge bounce is held
            // or animating, so the bounce-back keeps ticking after input
            // events stop (serviceSharedScrollStateForExternalView above is
            // what advances the animation).
            if mainTerminalView?.isScrollEdgeBounceActive(gridId: gridId) == true {
                activateDrawLoop()
            }

            // Same for the sub-row ease: the last step of a scroll produces no
            // further flushes, so without this the animation stops on whatever
            // frame the input happened to end on.
            if mainTerminalView?.isSmoothScrollActive(gridId: gridId) == true {
                activateDrawLoop()
            }

            // Shared with GridSurfaceRenderer: SurfaceIdleTerms holds every
            // term either surface has, and this surface's missing ones (a
            // dirty rect, per-layer work) stay at defaults that cannot block a
            // skip. `hasCursorUpdate` is passed as its two sources rather than
            // as the OR: !(a || b) == !a && !b.
            let idleTerms = SurfaceIdleTerms(
                hasPresentedOnce: hasPresentedOnce,
                rowModeSatisfied: rowMode,
                hasNewCommit: hasNewCommit,
                hasCursorUpdate: cursorDirtySnapshot,
                hasDirtyRows: hasDirtyContent,
                hasStagedScroll: hasPendingScroll,
                scrollOffsetChanged: scrollOffsetChanged,
                isSmoothScrolling: smoothScrolling,
                blinkStateChanged: blinkStateChanged,
                drawableSizeChanged: drawableSizeChanged,
                shaderAnimates: shaderAnimates
            )
            let idleGateSkips = idleTerms.skipsFrame
            ZonvieCore.drawTrace(idleTerms.traceLine(surface: gridId))
            if idleGateSkips {
                FrameTracer.trace(.drawSkipNoChange, a: 2, seq: UInt32(truncatingIfNeeded: gridId))
                ZonvieCore.appLog("[ext_draw_early_exit] gridId=\(gridId) idle")
                if idleCounter.noteIdle(hadRecentCommit: hadRecentCommit(withinNs: 50_000_000)) {
                    deactivateDrawLoop()
                }
                return
            }
            idleCounter.noteActive()
            if gridId == 4 {
                ZonvieCore.appLog("[ext_draw_why] gridId=4 rowMode=\(rowMode) presented=\(hasPresentedOnce) blink=\(blinkStateChanged) dirty=\(hasDirtyContent) scroll=\(hasPendingScroll) sizeChg=\(drawableSizeChanged) scrollOff=\(scrollOffsetChanged) cursor=\(hasCursorUpdate) hasNewCommit=\(hasNewCommit)")
            }

            let isBlinkOnlyFrame = blinkStateChanged
                && !layoutDamageSnapshot
                && layerDrawSnapshot.isEmpty
                && !hasDirtyContent
                && !hasPendingScroll
                && !drawableSizeChanged
                && !scrollOffsetChanged
                && !smoothScrolling
                && hasPresentedOnce

            // The blink toggled and this surface has no cursor to show it on,
            // so the toggle is invisible in either state and the whole cycle —
            // drawable acquire, copy pass, present, next-vsync wake — buys
            // nothing. The main surface has skipped this for a long time
            // (GridSurfaceRenderer's blink gate); an external one drew it.
            // Measured on two idle external windows over 25 s with the cursor
            // parked in the main window: 118 such frames, and the count scales
            // with the number of open surfaces.
            //
            // `!hasCursorUpdate` is needed on top of `isBlinkOnlyFrame`, which
            // — unlike the main surface's — does not test the commit revision.
            // A commit that moved the cursor AWAY from here leaves
            // `vertexCount` at 0 while still owing the frame that erases it.
            //
            // `lastRenderedBlinkState` was already advanced above, so the
            // toggle is acknowledged and `blinkStateChanged` stops firing for
            // it whether or not this frame draws.
            let blinkOnlyWithNoCursor = isBlinkOnlyFrame
                && !hasCursorUpdate
                && committedCursor.vertexCount == 0
                && !shaderAnimates
            ZonvieCore.drawTrace(
                "surface=\(gridId) gate=blinkNoCursor blinkOnly=\(isBlinkOnlyFrame ? 1 : 0)"
                    + " cursor=\(hasCursorUpdate ? 1 : 0)"
                    + " cursorVerts=\(committedCursor.vertexCount > 0 ? 1 : 0)"
                    + " anim=\(shaderAnimates ? 1 : 0)"
                    + " -> \(blinkOnlyWithNoCursor ? "skip" : "draw")"
            )
            if blinkOnlyWithNoCursor {
                FrameTracer.trace(.drawSkipNoChange, a: 4, seq: UInt32(truncatingIfNeeded: gridId))
                ZonvieCore.appLog("[ext_draw_early_exit] gridId=\(gridId) blink-no-cursor")
                if idleCounter.noteIdle(hadRecentCommit: hadRecentCommit(withinNs: 50_000_000)) {
                    deactivateDrawLoop()
                }
                return
            }

            // Cell dimensions — integer-rounded, same formula as GridSurfaceRenderer.
            let cw = Float(shared.cellWidthPx ?? 0)
            let ch = Float(shared.cellHeightPx ?? 0)
            let cellWi = max(1, UInt32(cw.rounded(.up)))
            let cellHi = max(1, UInt32(ch.rounded(.up)))
            // Viewport: grid-rows based (NOT drawable-based). An external
            // grid's viewport_rows may differ from drawableH / cellH, and the
            // core bakes NDC with grid_h = viewport_rows * cellH.
            let vpWidth = Double(snapGridCols) * Double(cellWi)
            let vpHeight = Double(snapGridRows) * Double(cellHi)
            let scale = view.window?.backingScaleFactor ?? 2.0
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
            // here. Rewritten like cursorBlinkBuffer, per draw.
            if let alphaBuf = backgroundAlphaBuffer {
                var alpha = surfaceBackgroundAlpha()
                memcpy(alphaBuf.contents(), &alpha, MemoryLayout<Float>.size)
            }

            // Check glow early — it disables partial-redraw optimizations to
            // prevent additive bloom composite from accumulating brightness.
            // It is also disabled for transient smooth-scroll frames that carry
            // a float staying put: the bloom pass blurs a flattened surface and
            // cannot keep the z-order boundary between shifted content and a
            // fixed float. The main renderer suppresses glow on the same terms.
            let configuredGlowEnabled = mainTerminalView?.core?.isGlowEnabled() ?? false
            let hasFixedFloat = layerDrawSnapshot.contains { !$0.0.followsScroll }
            let glowEnabled = configuredGlowEnabled && !(smoothScrolling && hasFixedFloat)

            // The union this surface's scrolled content must not bleed over.
            // Same rule the main renderer applies to its own layers, and it is
            // only meaningful while a scroll is easing — with no offset there is
            // nothing displaced to discard. A layer's originPx is already
            // surface-absolute, so the rectangle needs no further placement.
            fixedFloatRectsScratch.removeAll(keepingCapacity: true)
            if smoothScrolling {
                let cellW = Float(shared.cellWidthPx ?? 1)
                let cellH = Float(ch)
                for (layer, _) in layerDrawSnapshot
                where layer.z > 0 && layer.gridId != gridId && !layer.followsScroll {
                    fixedFloatRectsScratch.append(GridSurfaceRenderer.FixedFloatRect(
                        x0: layer.originPx.x,
                        x1: layer.originPx.x + Float(layer.cols) * cellW,
                        top: layer.originPx.y,
                        bottom: layer.originPx.y + Float(layer.rows) * cellH,
                        zindex: Int32(clamping: layer.z)
                    ))
                    if fixedFloatRectsScratch.count > SurfaceFixedFloatMask.maxRects { break }
                }
            }
            // A partial mask is visibly wrong, so an unrepresentable union drops
            // the whole transform rather than masking part of it — the main
            // renderer answers an overflow the same way.
            if !fixedFloatMask.update(fixedFloatRectsScratch) {
                fixedFloatMask.update([])
            }

            let use2Pass = blurEnabled && backgroundPipeline != nil && glyphPipeline != nil

            let useGpuScrollCopy = rowMode
                && !layoutDamageSnapshot
                && committedFontIsCurrent
                && hasNewCommit
                && pendingScroll != nil
                && hasPresentedOnce
                && !smoothScrolling
                && !drawableSizeChanged
                && !glowEnabled
                && !isDecoratedSurface
                // Fail closed to a clear + full retained-row redraw if blur's
                // overwrite/glyph pipelines could not be created.
                && (!blurEnabled || use2Pass)

            // Row state resolution — compute early so canBlinkFastPath can use it.
            // A stale set may stay GPU in-flight and must remain immutable.
            // Suppress it logically instead of clearing its row counts.
            let safeRowCount = rowMode && committedFontIsCurrent
                ? committed.rowLogicalToSlot.count
                : 0

            func resolvedRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow >= 0, logicalRow < safeRowCount else { return nil }
                guard logicalRow < committed.rowLogicalToSlot.count else { return nil }
                let slot = committed.rowLogicalToSlot[logicalRow]
                guard slot >= 0, slot < committed.rowState.counts.count else { return nil }
                let vc = committed.rowState.counts[slot]
                guard vc > 0, slot < committed.rowState.buffers.count,
                      let vb = committed.rowState.buffers[slot] else { return nil }
                let sourceRow = slot < committed.rowSlotSourceRows.count ? committed.rowSlotSourceRows[slot] : logicalRow
                // Pixels, y down: vertices live at sourceRow and must appear
                // at logicalRow.
                let translationY = Float(Int(logicalRow) - Int(sourceRow)) * Float(cellHi)
                return (vc, vb, translationY)
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
            // true via wasScrollOffsetActiveInLastPresentedFrame), so a
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

            let canBlinkFastPath: Bool = {
                // Decorated surfaces use loadAction=.clear because their
                // viewport origin makes partial preservation invalid. Drawing
                // only the cursor row after that clear would blank every other
                // row, so they must take the full-row path below.
                guard !isDecoratedSurface,
                      isBlinkOnlyFrame && blurEnabled && rowMode && use2Pass && !glowEnabled else { return false }
                guard lastKnownCursorRowSnapshot >= 0 && lastKnownCursorRowSnapshot < safeRowCount else { return false }
                guard resolvedRowState(lastKnownCursorRowSnapshot) != nil else { return false }
                return true
            }()

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
            guard let atlasTex = atlasReader.beginExternalRead(commandBuffer: cmd, snapshot: { committed.atlasTextureSnapshot }) else {
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
            if useGpuScrollCopy || !hasPendingScroll {
                dirtyRows.append(contentsOf: submittedDirtyRows)
            }
            defer {
                dirtyRows.removeAll(keepingCapacity: true)
                swap(&dirtyRows, &dirtyRowsScratch)
            }
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
                        regionStart: scroll.rowStart,
                        regionEnd: scrollCopy.clampedRowEnd,
                        rowsDelta: scroll.rowsDelta,
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

            // --- Render into back buffer ---
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = backTex
            rpd.colorAttachments[0].storeAction = .store

            // loadAction logic — match GridSurfaceRenderer, plus cursor-only preservation.
            // GridSurfaceRenderer marks cursor rows in pendingDirtyRows via markDirtyRect,
            // so hasAnyDirtyInRowMode is true during cursor-only frames. ExternalGridView
            // uses a dedicated cursor buffer instead, so dirtyRows may be empty. In that
            // case, preserve the back buffer to avoid clearing valid content.
            let hasAnyDirtyInRowMode = rowMode && !dirtyRows.isEmpty
            let cursorOnlyFrame = (hasCursorUpdate || isBlinkOnlyFrame) && dirtyRows.isEmpty
                && !hasDirtyContent && !hasPendingScroll && !layoutDamageSnapshot
            // The cursor is composited after the retained texture. A pure
            // blink needs no root or hosted-row draw, including under blur.
            let reuseHostedContents = rowMode && !layerDrawSnapshot.isEmpty
                && committedFontIsCurrent && hasPresentedOnce
                && !layoutDamageSnapshot && !hasDirtyContent
                && !hasPendingScroll && !drawableSizeChanged && !scrollOffsetChanged
                && !smoothScrolling && !shaderAnimates && !glowEnabled
                && !isDecoratedSurface
            if reuseHostedContents {
                ZonvieCore.renderTrace("side=macos event=retained_content_reuse surface=\(gridId) root_row_draws=0 hosted_row_draws=0")
            }
            // Same deal without hosted layers: the cursor lives on the
            // drawable, not the back texture, so a cursor move or a blink
            // toggle needs no root row redrawn. Without this the branch
            // ladder below falls through to the full-redraw arm and
            // re-encodes every row per keystroke, where the main surface
            // skips its whole pass (GridSurfaceRenderer's skipMainPass).
            let reuseRootContents = rowMode && layerDrawSnapshot.isEmpty
                && cursorOnlyFrame && committedFontIsCurrent && hasPresentedOnce
                && !layoutDamageSnapshot && !hasDirtyContent && !hasPendingScroll
                && !drawableSizeChanged && !scrollOffsetChanged
                && !smoothScrolling && !shaderAnimates && !glowEnabled
                && !isDecoratedSurface
            let partialHostedContents = rowMode && !layerDrawSnapshot.isEmpty
                && !dirtyRows.isEmpty && committedFontIsCurrent && hasPresentedOnce
                && !layoutDamageSnapshot && !hasPendingScroll && !drawableSizeChanged
                && !scrollOffsetChanged && !smoothScrolling && !shaderAnimates
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
            let canDirtyOnlyWithBlur = rowMode && use2Pass && hasAnyDirtyInRowMode
                && hasPresentedOnce && !smoothScrolling && !drawableSizeChanged && !glowEnabled
                && !isDecoratedSurface && committedFontIsCurrent && !layoutDamageSnapshot
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
                layersOutsideDirtySet: !layerDrawSnapshot.isEmpty,
                canBlinkFastPath: canBlinkFastPath,
                useGpuScrollCopy: useGpuScrollCopy,
                canDirtyOnlyWithBlur: canDirtyOnlyWithBlur,
                isCursorOnlyFrame: cursorOnlyFrame,
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
            rpd.colorAttachments[0].clearColor = gridClearColor

            // Resolved before the surface pass so the cursor and glow passes
            // below can use them even on a frame that encodes no surface pass.
            // Bind scroll offset data via shared helper (no GPU/CPU race)
            let scrollOffsetSnapshot: GridSurfaceRenderer.ScrollOffset?
            let hostedScrollOffsetSnapshot: [GridSurfaceRenderer.ScrollOffset]
            do {
                lock.lock()
                scrollOffsetSnapshot = scrollOffsetActive ? scrollOffsetData : nil
                hostedScrollOffsetSnapshot = hostedScrollOffsetData  // Value-type copy
                lock.unlock()
            }

            // What displaces the cursor's own grid, resolved exactly as
            // drawHostedLayers resolves a layer's: its own offset when it is
            // scrolling in its own right, the root's when it merely follows,
            // and nothing at all when it stands still. The body and the cursor
            // have to answer the same offset or they are drawn a row apart.
            let cursorOwnerOffset: GridSurfaceRenderer.ScrollOffset? = cursorOwnerSnapshot == gridId
                ? scrollOffsetSnapshot
                : (surfaceScrollOffset(gridId: cursorOwnerSnapshot, offsets: hostedScrollOffsetSnapshot)
                    ?? (cursorLayerFollowsScrollSnapshot ? scrollOffsetSnapshot : nil))
            var cursorDrawOrigin = cursorLayerOriginSnapshot
            // A layer with an offset of its own keeps its origin: the shader
            // displaces its rows inside it. Only a follower is moved bodily.
            if cursorLayerFollowsScrollSnapshot,
               surfaceScrollOffset(gridId: cursorOwnerSnapshot, offsets: hostedScrollOffsetSnapshot) == nil,
               let offset = scrollOffsetSnapshot {
                // The shared helper the main renderer uses, rather than the same
                // expression written out again: it also refuses a non-finite
                // offset or a zero viewport, and this result reaches
                // `Int(scissorTopPx.rounded(.down))` below, where a NaN traps.
                cursorDrawOrigin = displacedLayerOriginPx(
                    originPx: cursorDrawOrigin,
                    offset: offset,
                    viewportHeightPx: viewportMetrics.fragmentHeight
                )
                // The same debt the body gives back, or the cursor and the rows
                // it sits on are drawn rows apart.
                cursorDrawOrigin.y += mainTerminalView?.floatDebtPx(
                    gridId: cursorOwnerSnapshot,
                    anchorGridId: cursorLayerAnchorGridSnapshot,
                    cellHeightPx: Float(ch)
                ) ?? 0
            }

            /// `glowPipeline` non-nil IS the glow pass. The caller binds it
            /// from the main renderer's `if let` chain, so passing it in keeps
            /// that proof instead of reaching back through `mainTerminalView`
            /// for a pipeline the enclosing scope already holds.
            func drawHostedLayers(_ encoder: MTLRenderCommandEncoder, glowPipeline: MTLRenderPipelineState? = nil) {
                let glow = glowPipeline != nil
                guard committedFontIsCurrent else { return }
                let extent = simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)
                for (layer, set) in layerDrawSnapshot {
                    let rows = min(layer.rows, set.rowLogicalToSlot.count)
                    guard rows > 0 else { continue }
                    var origin = layer.originPx
                    // A layer scrolled in its own right eases inside its own
                    // frame: the shader displaces its rows against this offset,
                    // clipped to the layer's content bounds. A layer that only
                    // follows its anchor has no offset of its own and moves
                    // bodily with the root instead — the same split the main
                    // window's layer pass makes between a per-row offset and a
                    // `move_all` origin shift. Either way clip and geometry end
                    // up in one coordinate space.
                    let layerOffset = surfaceScrollOffset(
                        gridId: layer.gridId, offsets: hostedScrollOffsetSnapshot)
                    if layerOffset == nil, layer.followsScroll, let offset = scrollOffsetSnapshot {
                        origin = displacedLayerOriginPx(
                            originPx: origin,
                            offset: offset,
                            viewportHeightPx: extent.y
                        )
                        // Give back the rows this float's own placement has
                        // already travelled. Without it the float is handed the
                        // anchor's whole compensation on top of a placement that
                        // has moved with it, and drifts from its anchor for the
                        // length of the scroll — the correction the main
                        // renderer applies when it builds a float's offset, and
                        // which a float an external window hosts never got.
                        origin.y += mainTerminalView?.floatDebtPx(
                            gridId: layer.gridId,
                            anchorGridId: layer.anchorGrid,
                            cellHeightPx: Float(ch)
                        ) ?? 0
                    }
                    let ratio: Float = glow ? 0.5 : 1
                    // A displaced origin is fractional mid-ease; floor it and
                    // cover the row of pixels that flooring would otherwise
                    // clip, as the main renderer's layer pass does.
                    let scissorTopPx = (Float(vpOriginY) + origin.y) * ratio
                    let scissorPadY = scissorTopPx == scissorTopPx.rounded(.down) ? 0 : 1
                    guard let scissor = clampScissor(
                        x: Int(((Float(vpOriginX) + origin.x) * ratio).rounded(.down)),
                        y: Int(scissorTopPx.rounded(.down)),
                        width: Int(Float(layer.cols * Int(cellWi)) * ratio),
                        height: Int(Float(rows * Int(cellHi)) * ratio) + scissorPadY,
                        targetWidth: glow ? max(1, backTex.width / 2) : backTex.width,
                        targetHeight: glow ? max(1, backTex.height / 2) : backTex.height
                    ) else { continue }
                    encoder.setScissorRect(scissor)
                    bindLayerTransform(encoder: encoder, LayerTransform(originPx: origin, extentPx: extent))
                    bindSingleSurfaceScrollOffset(encoder: encoder, offset: layerOffset)
                    // This layer's rows, then the rows its own smooth scroll
                    // retained, both in its grid-local space. The index list is
                    // reused so a layer costs no allocation per frame. Same
                    // shape as the main renderer's layer pass.
                    retainedIndexScratch.removeAll(keepingCapacity: true)
                    for (i, r) in retainedSnapshot.enumerated()
                    where r.gridId == layer.gridId && r.cellHeightPx == Float(cellHi) {
                        retainedIndexScratch.append(i)
                    }
                    let retainedForLayerCount = retainedIndexScratch.count
                    let retainedBase = rows
                    let scratch = retainedIndexScratch
                    func resolveLayerRow(_ row: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                        if row >= retainedBase {
                            let i = row - retainedBase
                            guard i < scratch.count else { return nil }
                            let r = retainedSnapshot[scratch[i]]
                            return (r.count, r.buffer, Float(r.targetRow - r.sourceRow) * Float(cellHi))
                        }
                        return resolveSurfaceGridRow(set, row: row, cellHeightPx: Float(cellHi))
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
                                pipeline: pipeline, backgroundPipeline: backgroundPipeline,
                                glyphPipeline: glyphPipeline, useTwoPass: use2Pass,
                                unifiedBlurPipeline: unifiedBlurPipeline)
                        }
                        logHostedLayerDraw(layer: layer, encodedRows: encodedRows, of: rows)
                        continue
                    }
                    // Attenuate what this surface already extracted under the
                    // layer before adding the layer's own light, so a glyph
                    // hidden behind a float here does not bloom through it --
                    // the same two-pass order the main surface uses.
                    if glow, let occludePipe = shared.glowOccludePipeline {
                        _ = encodeSurfaceRowDraws(
                            encoder: encoder, rows: 0..<rows,
                            resolve: { resolveSurfaceGridRow(set, row: $0, cellHeightPx: Float(cellHi)) },
                            pipeline: occludePipe,
                            backgroundPipeline: nil, glyphPipeline: nil, useTwoPass: false
                        )
                    }
                    let encodedRows = encodeSurfaceRowDraws(
                        encoder: encoder, rows: 0..<(rows + retainedForLayerCount),
                        resolve: resolveLayerRow,
                        pipeline: glowPipeline ?? pipeline,
                        backgroundPipeline: backgroundPipeline, glyphPipeline: glyphPipeline,
                        useTwoPass: !glow && use2Pass,
                        unifiedBlurPipeline: unifiedBlurPipeline
                    )
                    if !glow { logHostedLayerDraw(layer: layer, encodedRows: encodedRows, of: rows) }
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
                viewportMetrics.applyViewport(to: enc)
                enc.setRenderPipelineState(pipeline)

                // Bind atlas texture (also captured for bloom extract pass and
                // the cursor pass below — registered/snapshotted once above,
                // right after cmd was created).
                enc.setFragmentTexture(atlasTex, index: 0)
                enc.setFragmentSamplerState(sampler, index: 0)

                bindSingleSurfaceScrollOffset(encoder: enc, offset: scrollOffsetSnapshot)

                // Bind fragment-side state (drawable size, background alpha, cursor blink)
                bindSurfaceFragmentState(
                    encoder: enc,
                    viewportMetrics: viewportMetrics,
                    backgroundAlphaBuffer: backgroundAlphaBuffer,
                    cursorBlinkBuffer: cursorBlinkBuffer,
                    cursorBlinkVisible: cursorBlinkStateSnapshot,
                    fixedFloatBands: fixedFloatMask.bands,
                    fixedFloatIntervals: fixedFloatMask.intervals
                )

                var zeroRowTranslation: Float = 0
                enc.setVertexBytes(&zeroRowTranslation, length: MemoryLayout<Float>.size, index: 3)

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
                        ZonvieCore.appLog("[ext_draw_debug] gridId=\(gridId) safeRowCount=\(safeRowCount) dirtyRows=\(dirtyRows.count) useGpuScrollCopy=\(useGpuScrollCopy) use2Pass=\(use2Pass) canBlink=\(canBlinkFastPath) loadAction=\(rpd.colorAttachments[0].loadAction.rawValue) vpH=\(vpHeight) snapRows=\(snapGridRows) drawableH=\(view.drawableSize.height) vpOriginY=\(viewportOriginPx.y)")
                    }

                    let drawableW = max(0, Int(view.drawableSize.width.rounded(.down)))
                    let cellH = max(1, Int(ch.rounded(.up)))
                    // Shared with GridSurfaceRenderer: the geometry every row
                    // below is placed with, resolved once instead of at each
                    // call site.
                    let rowGeometry = SurfaceRowGeometry(
                        cellHeightPx: cellH,
                        renderTarget: backTex,
                        viewportMetrics: viewportMetrics,
                        drawableSize: view.drawableSize
                    )

                    // A decorated grid's padding stays governed by the
                    // transparent render-pass clear outside the viewport; the
                    // bands only cover the viewport itself.
                    func drawScissoredDirtyRows() {
                        encodeSurfaceScissoredDirtyRows(
                            encoder: enc,
                            rows: dirtyRows,
                            pipeline: pipeline,
                            resolve: resolvedRowState,
                            geometry: rowGeometry,
                            bgRGB: extractRGBFromClearColor(gridClearColor),
                            gridId: gridId
                        )
                    }

                    // Blur's dirty-row path. Under .load a dirty row that does not
                    // repaint every pixel it owns keeps the previous frame's, and
                    // the core drops the root's default-background runs while the
                    // surface has layers (flush.zig `skip_default_bg`): an empty row
                    // is skipped entirely, and a row that still carries a glyph
                    // emits no background quad under it and creeps toward opaque.
                    // So band every dirty row with backgroundPipeline first; the
                    // row's own background quads then overwrite the band where it
                    // has any. Same shape as GridSurfaceRenderer's blur branch.
                    func drawScissoredDirtyRowsTwoPass() {
                        let bandWidth = Float(vpWidth > 0 ? vpWidth : view.drawableSize.width)
                        let bandHeight = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)
                        encodeSurfaceDirtyRowBands(
                            encoder: enc,
                            rows: dirtyRows,
                            pipeline: backgroundPipeline!,
                            cellHeightPx: cellH,
                            widthPx: bandWidth,
                            heightPx: bandHeight,
                            bgRGB: extractRGBFromClearColor(gridClearColor),
                            gridId: gridId
                        )
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: dirtyRows,
                            resolve: resolvedRowState,
                            scissor: { row in
                                makeRowScissorRect(
                                    row: row,
                                    cellHeight_px: Int(cellHi),
                                    drawableWidth_px: drawableW,
                                    renderTargetWidth_px: backTex.width,
                                    renderTargetHeight_px: backTex.height
                                )
                            },
                            pipeline: pipeline,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true,
                            unifiedBlurPipeline: unifiedBlurPipeline
                        )
                    }

                    // Shared with GridSurfaceRenderer: WHICH rows this pass
                    // draws is one decision now; `use2Pass` still says HOW,
                    // which is why four cases below still split on it.
                    let rowPassPlan = SurfaceRowPassTerms(
                        useTwoPass: use2Pass,
                        canBlinkFastPath: canBlinkFastPath,
                        rootScrollBlitVacatedBand: useGpuScrollCopy,
                        isSmoothScrolling: smoothScrolling,
                        canDirtyOnlyWithBlur: canDirtyOnlyWithBlur,
                        loadedPreviousContents: rpd.colorAttachments[0].loadAction == .load,
                        hasDirtyRows: !dirtyRows.isEmpty,
                        glowEnabled: glowEnabled,
                        isDecoratedSurface: isDecoratedSurface,
                        drawableSizeChanged: drawableSizeChanged
                    ).plan

                    switch rowPassPlan {
                    case .blinkFastPathRow:
                        let cursorRow = lastKnownCursorRowSnapshot
                        let resolved = resolvedRowState(cursorRow)!
                        // Shared with GridSurfaceRenderer; only the row differs.
                        encodeSurfaceBlinkFastPathRow(
                            encoder: enc,
                            row: cursorRow,
                            resolved: resolved,
                            geometry: rowGeometry,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            unifiedBlurPipeline: unifiedBlurPipeline
                        )
                    case .dirtyRowsAfterScrollBlit where use2Pass:
                        // The back texture is loaded after the pixel shift, so all
                        // clears must overwrite it. The regular blur pipeline uses
                        // alpha blending and would leave stale glyph pixels behind.
                        enc.setRenderPipelineState(backgroundPipeline!)
                        let scrollDrawableW = Float(vpWidth > 0 ? vpWidth : view.drawableSize.width)
                        let scrollDrawableH = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)
                        let bgRGB = extractRGBFromClearColor(gridClearColor)
                        if let clearBand = scrollClearBand {
                            drawSurfaceBackgroundClearBand(
                                enc,
                                clearBand: clearBand,
                                xRangePx: (leftPx: 0, rightPx: scrollDrawableW),
                                drawableHeight: scrollDrawableH,
                                bgRGB: bgRGB,
                                gridId: gridId
                            )
                        }
                        // The dirty rows themselves, banded then redrawn: rows
                        // without vertices need the overwrite this pass's .load
                        // would otherwise skip, including dirty rows outside the
                        // vacated scroll band.
                        drawScissoredDirtyRowsTwoPass()
                    case .dirtyRowsAfterScrollBlit:
                        if let clearBand = scrollClearBand {
                            let bgRGB = extractRGBFromClearColor(gridClearColor)
                            drawSurfaceBackgroundClearBand(
                                enc,
                                clearBand: clearBand,
                                xRangePx: (leftPx: 0, rightPx: Float(vpWidth > 0 ? vpWidth : Double(view.drawableSize.width))),
                                drawableHeight: Float(vpHeight > 0 ? vpHeight : Double(view.drawableSize.height)),
                                bgRGB: bgRGB,
                                gridId: gridId
                            )
                        }
                        drawScissoredDirtyRows()
                    case .dirtyRowsOnly where use2Pass:
                        // Only when the pass actually preserved the clean rows.
                        // Every reason this surface clears instead — layout
                        // damage, a font generation behind, a first frame —
                        // would leave every row this frame does not draw blank.
                        drawScissoredDirtyRowsTwoPass()
                    case .dirtyRowsOnly:
                        // Normal mode: scissor per dirty row. A resized backbuffer
                        // is cleared, so partial redraw would leave every clean row
                        // blank; decorated surfaces have the same constraint on
                        // every frame because their loadAction is always .clear.
                        drawScissoredDirtyRows()
                    case .allRowsWithRetained where use2Pass:
                        // 2-pass full redraw (same as GridSurfaceRenderer),
                        // including the rows retained across a scroll step.
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: smoothRowRange,
                            resolve: resolvedSmoothRowState,
                            pipeline: pipeline,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true,
                            unifiedBlurPipeline: unifiedBlurPipeline
                        )
                    case .allRowsWithRetained:
                        // Smooth scroll without blur: draw all rows without scissor
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: smoothRowRange,
                            resolve: resolvedSmoothRowState,
                            pipeline: pipeline,
                            backgroundPipeline: nil,
                            glyphPipeline: nil,
                            useTwoPass: false
                        )
                    case .allRows:
                        // Full redraw fallback
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: 0..<safeRowCount,
                            resolve: resolvedRowState,
                            pipeline: pipeline,
                            backgroundPipeline: nil,
                            glyphPipeline: nil,
                            useTwoPass: false
                        )
                    }
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
                intensity: mainTerminalView?.core?.getGlowIntensity() ?? 0.8,
                // One read, for both the chain's depth and the taps' reach.
                radiusScale: mainTerminalView?.core?.getGlowRadiusScale() ?? 1.0
            ) { enc, extractPipe in
                    // Set up atlas and scroll offsets for extract pass.
                    // ps_glow_extract takes only texture(0) + sampler(0), but the
                    // occlusion pass drawHostedLayers runs reads the background
                    // alpha at fragment buffer(1) -- the same one the main pass
                    // paints with, so the two agree on what a layer hides.
                    // The helper does bind the layer transform (vertex buffer 4).
                    enc.setFragmentTexture(atlasTex, index: 0)
                    enc.setFragmentSamplerState(self.sampler!, index: 0)
                    if let alphaBuf = self.backgroundAlphaBuffer {
                        enc.setFragmentBuffer(alphaBuf, offset: 0, index: 1)
                    }

                    bindSingleSurfaceScrollOffset(encoder: enc, offset: scrollOffsetSnapshot)
                    var zeroTranslation: Float = 0
                    enc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)

                    // Draw row vertices. The same range the main pass draws:
                    // glow forces a `.clear`, so a retained row left out here
                    // has no previous-frame light to fall back on and the band
                    // a scroll vacated renders unlit for the whole ease. The
                    // main renderer's extract covers its retained rows for the
                    // same reason.
                    if rowMode {
                        for row in smoothRowRange {
                            guard let resolved = resolvedSmoothRowState(row) else { continue }
                            var rowTranslation = resolved.translationY
                            enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                            enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
                        }
                    }

                    drawHostedLayers(enc, glowPipeline: extractPipe)

                    // Cursor vertices for cursor glow
                    if committedFontIsCurrent,
                       cursorBlinkStateSnapshot,
                       committedCursor.vertexCount > 0,
                       let cvb = committedCursor.vertexBuffer {
                        bindLayerTransform(encoder: enc, LayerTransform(originPx: cursorDrawOrigin,
                            extentPx: simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)))
                        // drawHostedLayers left the surface-wide offset bound.
                        bindSingleSurfaceScrollOffset(encoder: enc, offset: cursorOwnerOffset)
                        var ct: Float = 0
                        enc.setVertexBytes(&ct, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(cvb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: committedCursor.vertexCount)
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
                    // Fold in the displacement THIS frame draws with before
                    // reading the uniforms: the shared value follows the main
                    // view's draw cadence, and this window routinely draws a
                    // frame ahead of it — which put the cursor shader a frame
                    // of finger travel away from the cursor.
                    renderer.evaluateCursorShaderChange(
                        scrollOffsetPx: cursorScrollOffsetPxForShader(
                            ownerGridId: cursorOwnerSnapshot,
                            offset: cursorOwnerOffset,
                            viewportHeightPx: viewportMetrics.fragmentHeight
                        )
                    )
                    return renderer.makeCustomShaderUniforms(
                        screenResolution: screenRes,
                        windowOffset: windowOffset,
                        windowSize: view.drawableSize,
                        timing: shaderTiming
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
                    backgroundAlphaBuffer: backgroundAlphaBuffer,
                    cursorBlinkBuffer: cursorBlinkBuffer,
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
                    // do not queue the pixel shift a second time. Restored rows,
                    // cursorDirty and revision state produce a complete retry.
                    bailWithoutSubmit("cursor encoder creation failed", restoreScroll: false)
                    return
                }
            }

            if FrameTracer.enabled {
                let submitNs = FrameTracer.nowNs()
                let traceSeq = UInt32(truncatingIfNeeded: gridId)
                drawable.addPresentedHandler { d in
                    let t = d.presentedTime
                    let presentedNs = t > 0 ? UInt64(t * 1_000_000_000.0) : 0
                    FrameTracer.trace(.presented, a: presentedNs, b: submitNs, seq: traceSeq)
                }
            }
            FrameTracer.trace(.presentCall, seq: UInt32(truncatingIfNeeded: gridId))
            cmd.present(drawable)
            // `sem` and `tbLock` are the ones captured for `releaseFrameState`
            // above, for the same reason: the signal has to fire even if the
            // view is deallocated before the GPU finishes.
            cmd.addCompletedHandler { [weak self] completed in
                tbLock.lock()
                self?.completeSurfaceFrameReadLocked(rowSet: csi, cursorSlot: cci)
                tbLock.unlock()
                sem.signal()
                // Paired with beginExternalRead() at atlas-bind time
                // above. Uses the strongly-captured atlasReadRenderer, not
                // [weak self] — see its declaration comment for why.
                atlasReader.endExternalRead()
                if completed.status != .completed {
                    DispatchQueue.main.async { [weak self] in
                        self?.hasPresentedOnce = false
                        self?.requestRedraw()
                    }
                }
            }
            cmd.commit()
            gpuSubmitted = true

            markScrollOffsetStatePresented()
            hasPresentedOnce = true
            redrawScheduler.didDrawFrame()
            finishedRedraw = true

            DispatchQueue.main.async { [weak self] in
                self?.updateScrollbarIfNeeded()
            }
        }
    }

    // MARK: - Post-Process Bloom (Neon Glow) — uses shared encodeSurfaceBloomPasses()

    // MARK: - Private


    // MARK: - Smooth Scroll

    /// Update scroll offset shader uniform for visual sub-cell scrolling.
    /// Uses shared scroll offset info and computation from GridSurfaceRenderer.
    /// Returns true if a non-zero scroll offset is active.
    @discardableResult
    /// Drain the ease seeds this surface's steps committed. Spent by the main
    /// view's tick, which owns the per-grid offsets they feed.
    func takeSmoothScrollSeeds() -> [(gridId: Int64, rowsDelta: Int)] {
        guard GridSurfaceRenderer.smoothScrollEnabled else { return [] }
        pendingGridScrollLock.lock()
        defer { pendingGridScrollLock.unlock() }
        guard !smoothScrollSeeds.isEmpty else { return [] }
        let taken = smoothScrollSeeds
        smoothScrollSeeds.removeAll(keepingCapacity: true)
        return taken
    }

    private func updateScrollShaderOffset() -> Bool {
        guard let main = mainTerminalView else { return false }

        let cellHeightPx = Float(shared.cellHeightPx)
        guard cellHeightPx > 0 else { return false }

        // Use the same grid-based snapped viewport height draw() computes
        // (vpHeight = snapGridRows * cellHi). snapGridRows is a LOCAL inside
        // draw(), not a property — recompute it here the same way:
        // committedGridRows under tripleBufferLock, falling back to gridRows
        // when no commit has published dimensions yet. The fragment shader's
        // NDC reconstruction uses this grid-based height for external
        // surfaces (via SurfaceViewportMetrics.fragmentHeight), not
        // drawableSize.height.
        tripleBufferLock.lock()
        let snappedRows = committedGridRows
        tripleBufferLock.unlock()
        let rowsForHeight = snappedRows > 0 ? snappedRows : gridRows
        let cellHi = max(1, UInt32(cellHeightPx.rounded(.up)))
        let viewportHeight = Float(rowsForHeight) * Float(cellHi)
        guard viewportHeight > 0 else { return false }

        // The band a wheel event opens is as wide as the rows it moves, so
        // this window's retention has to keep that many. The main view sets
        // its own renderer's depth on scroll input; an external window is not
        // on that path, so take it from the same source here.
        retention.setDepthRows(main.core?.getMouseScrollVer() ?? 0)

        let vpOriginYPxForGridTop = Float(viewportOriginPx.y)
            * Float(self.window?.backingScaleFactor ?? 2.0)

        // Resolve every hosted grid's own offset, the way the main window's
        // layer pass does. Without this a float inside an external window only
        // ever moves when the root scrolls, and a float scrolled on its own
        // stands still. Its grid top is the origin this surface placed it at —
        // the main window's startRow describes a position this view never uses.
        tripleBufferLock.lock()
        hostedLayerOriginScratch.removeAll(keepingCapacity: true)
        for layer in committedSurfaceLayers where layer.gridId != gridId {
            hostedLayerOriginScratch.append((gridId: layer.gridId, originYPx: layer.originPx.y, z: Int32(clamping: layer.z)))
        }
        tripleBufferLock.unlock()

        hostedScrollOffsetScratch.removeAll(keepingCapacity: true)
        for hosted in hostedLayerOriginScratch {
            guard var info = main.getScrollOffsetInfo(
                gridId: hosted.gridId,
                drawableHeight: viewportHeight,
                cellHeightPx: cellHeightPx
            ) else { continue }
            info.gridTopYNDC = 1.0 - (vpOriginYPxForGridTop + hosted.originYPx) * (2.0 / viewportHeight)
            // The z this surface's fixed-float mask is built from, so the two
            // are on one scale. getScrollOffsetInfo leaves zindex at 0 because
            // the main window fills it in itself from the Neovim zindex; here
            // the mask carries `layer.z`, which the core emits as a PAINT-ORDER
            // rank (>= 1 for every hosted layer). Left at 0 the shader's
            // `interval.z > scroll_z` was true for a float tested against its
            // OWN rect, so a fixed float scrolled on its own discarded its
            // scrolled glyphs for the whole ease.
            info.zindex = hosted.z
            hostedScrollOffsetScratch.append(GridSurfaceRenderer.computeScrollOffset(
                info: info,
                viewportHeight: viewportHeight,
                cellHeightPx: cellHeightPx
            ))
        }
        hostedScrollOffsetScratch.sort { $0.grid_id < $1.grid_id }
        let hasHostedOffset = !hostedScrollOffsetScratch.isEmpty

        // Get scroll offset info from the main view's shared scroll state.
        if var info = main.getScrollOffsetInfo(gridId: gridId, drawableHeight: viewportHeight, cellHeightPx: cellHeightPx) {
            // No second clamp here. getScrollOffsetInfo already applied the
            // shared one, which allows a whole wheel event's worth of
            // compensation ('mousescroll' ver rows); re-clamping to two cells
            // discarded the rest, jumped the picture by what it dropped, and
            // left the cursor-shader uniform — which follows the UNclamped
            // value — a row away from the cursor it is drawn on. The empty
            // band the old clamp was guarding against is now covered by the
            // retained rows below.

            // Fold in this view's viewport origin. getScrollOffsetInfo
            // computes gridTopYNDC = 1 - startRow*cellH*(2/height) in
            // MAIN-window coordinates with no origin term — wrong for this
            // view's own shader space, where ndc_y = 1 - pos.y*(2/vpHeight)
            // and pos.y includes the decorated-surface padding offset. In
            // this view the grid's top edge sits at pixel vpOriginY (zero
            // for undecorated surfaces, giving gridTopYNDC = 1.0, i.e. the
            // top of the viewport — correct for a grid filling its own
            // window).
            info.gridTopYNDC = 1.0 - vpOriginYPxForGridTop * (2.0 / viewportHeight)

            // Use the grid-snapped viewport coordinate space, matching the
            // fragment shader's screen-space clipping for this surface (see
            // draw()'s vpHeight/vpOriginY computation).
            var scrollOffset = GridSurfaceRenderer.computeScrollOffset(
                info: info,
                viewportHeight: viewportHeight,
                cellHeightPx: cellHeightPx
            )

            // Retained rows cover the vacated band with the content that
            // actually left; the edge-row background stretch would paint over
            // them, so suppress it once they cover the whole band.
            let cellHeightNDC = cellHeightPx * (2.0 / viewportHeight)
            if ScrollRetention.coversBand(
                retainedRows: retention.publishedCount(gridId: gridId),
                offsetNDC: scrollOffset.offset_y,
                cellHeightNDC: cellHeightNDC
            ) {
                scrollOffset.pin_edges = 0
            }

            ZonvieCore.appLog("[ExternalGridView] scroll offset: gridId=\(gridId) offsetPx=\(info.offsetYPx) marginTop=\(info.marginTop) marginBottom=\(info.marginBottom) ndc=\(scrollOffset.offset_y) top=\(scrollOffset.content_top_y) bot=\(scrollOffset.content_bottom_y) pin=\(scrollOffset.pin_edges) retained=\(retention.publishedCount(gridId: gridId)) gridTop=\(info.gridTopYNDC) cellNDC=\(cellHeightNDC) vpH=\(viewportHeight)")

            lock.lock()
            defer { lock.unlock() }

            scrollOffsetData = scrollOffset
            scrollOffsetActive = true
            hostedScrollOffsetData.removeAll(keepingCapacity: true)
            hostedScrollOffsetData.append(contentsOf: hostedScrollOffsetScratch)
            return true  // Scroll offset is active
        } else {
            // No offset. A retained row is only meaningful while the grid is
            // displaced: with no offset it would be drawn one row outside real
            // content.
            retention.clearPublished()

            lock.lock()
            defer { lock.unlock() }

            scrollOffsetData = nil
            scrollOffsetActive = false
            hostedScrollOffsetData.removeAll(keepingCapacity: true)
            hostedScrollOffsetData.append(contentsOf: hostedScrollOffsetScratch)
            // A hosted grid easing on its own keeps this surface in a smooth
            // scroll even with the root standing still, exactly as any grid's
            // offset does for the main renderer.
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

        if scrollOffsetActive != lastPresentedScrollOffsetActive {
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
        if !scrollOffsetActive {
            return false
        }
        return !scrollOffsetsEqual(scrollOffsetData, lastPresentedScrollOffsetData)
    }

    private func wasScrollOffsetActiveInLastPresentedFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastPresentedScrollOffsetActive || !lastPresentedHostedScrollOffsetData.isEmpty
    }

    private func markScrollOffsetStatePresented() {
        lock.lock()
        defer { lock.unlock() }

        lastPresentedScrollOffsetActive = scrollOffsetActive
        lastPresentedScrollOffsetData = scrollOffsetData
        lastPresentedHostedScrollOffsetData.removeAll(keepingCapacity: true)
        lastPresentedHostedScrollOffsetData.append(contentsOf: hostedScrollOffsetData)
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

    /// Which grid a pointer event at `pointPx` (surface content pixels,
    /// top-origin) targets, and the point in that grid's own cells. A float
    /// this surface hosts sits above the root, so it takes the event wherever
    /// it covers the point; `requireScrollable` drops floats that already show
    /// all of their content, which stay transparent to scrolling the way the
    /// main window's resolution does.
    ///
    /// Two corrections the static layer geometry does not carry, both on the
    /// rule the main window's hit test uses -- displayed Y == static Y +
    /// offsetPx:
    ///  - a layer that follows its anchor is DRAWN at an origin the root's
    ///    offset displaced (drawHostedLayers shifts it bodily), so the
    ///    containment test has to use the displaced origin;
    ///  - a grid easing in its own right has its ROWS displaced inside a frame
    ///    that stays put, so the row a pixel names is the one the ease moved
    ///    there.
    private func resolveInputTarget(
        pointPx: CGPoint,
        requireScrollable: Bool
    ) -> (gridId: Int64, row: Int32, col: Int32) {
        guard let main = mainTerminalView else { return (gridId, 0, 0) }
        let cellW = CGFloat(shared.cellWidthPx)
        let cellH = CGFloat(shared.cellHeightPx)
        guard cellW > 0, cellH > 0 else { return (gridId, 0, 0) }

        let grids = main.core?.getVisibleGridsCached() ?? []
        let rootOffsetPx = main.visualScrollOffsetPx(gridId: gridId, cellHeightPx: cellH)

        tripleBufferLock.lock()
        let layers = committedSurfaceLayers
        tripleBufferLock.unlock()

        var best: (gridId: Int64, row: Int32, col: Int32)?
        var bestZ = Int.min
        for layer in layers where layer.gridId != gridId {
            // A float that refuses the mouse is not a target and does not
            // shadow one: Neovim rejects an event addressed to it without
            // re-resolving, so picking it would swallow the event instead of
            // letting it through to the window it is drawn over.
            guard layer.mouseEnabled else { continue }
            guard let local = layerLocalPoint(layer, pointPx: pointPx, rootOffsetPx: rootOffsetPx,
                                              cellW: cellW, cellH: cellH, main: main)
            else { continue }
            let info = grids.first { $0.gridId == layer.gridId }
            if requireScrollable {
                guard let info, main.isFloatLogicallyScrollable(info) else { continue }
            }
            guard best == nil || layer.z > bestZ else { continue }
            bestZ = layer.z
            best = (
                layer.gridId,
                scrolledRow(local.y, offsetPx: local.ownOffsetPx, cellH: cellH, info: info),
                Int32(local.x / cellW)
            )
        }
        return best ?? resolveRootTarget(pointPx: pointPx)
    }

    /// A surface point inside one layer, as that layer's own pixels, or nil
    /// when the point is outside the rectangle the layer is DRAWN in.
    private func layerLocalPoint(
        _ layer: SurfaceLayer,
        pointPx: CGPoint,
        rootOffsetPx: CGFloat,
        cellW: CGFloat,
        cellH: CGFloat,
        main: MetalTerminalView
    ) -> (x: CGFloat, y: CGFloat, ownOffsetPx: CGFloat)? {
        let ownOffsetPx = main.visualScrollOffsetPx(gridId: layer.gridId, cellHeightPx: cellH)
        // drawHostedLayers moves the whole layer with the root only when the
        // layer has no ease of its own; otherwise its frame stays put and the
        // shader displaces the rows inside it.
        let originY = CGFloat(layer.originPx.y)
            + (ownOffsetPx == 0 && layer.followsScroll ? rootOffsetPx : 0)
        let x = pointPx.x - CGFloat(layer.originPx.x)
        let y = pointPx.y - originY
        guard x >= 0, y >= 0,
              x < CGFloat(layer.cols) * cellW,
              y < CGFloat(layer.rows) * cellH
        else { return nil }
        return (x, y, ownOffsetPx)
    }

    /// The grid row a grid-local pixel names, undoing the sub-row ease the
    /// frame drew with. Left alone outside the scrollable content area, the
    /// way the main window's hit test leaves its margin rows alone.
    private func scrolledRow(
        _ localY: CGFloat,
        offsetPx: CGFloat,
        cellH: CGFloat,
        info: ZonvieCore.GridInfo?
    ) -> Int32 {
        let row = Int32(localY / cellH)
        guard abs(offsetPx) > 0.001, let info else { return row }
        // Margin rows (winbar, border) carry no DECO_SCROLLABLE, so the vertex
        // shader left them where they statically belong while the content eased
        // past them. A pixel ON one names that row: undoing an ease it never
        // took would hand back a content row the user did not click.
        guard row >= info.marginTop, row < info.rows - info.marginBottom else { return row }
        let adjusted = Int32((localY - offsetPx) / cellH)
        guard adjusted >= info.marginTop, adjusted < info.rows - info.marginBottom else { return row }
        return adjusted
    }

    /// The grid a press claimed. Neovim keeps a drag on the window the press
    /// chose, so re-resolving mid-drag switches coordinate spaces and jumps the
    /// selection by the float's placement; the release must not re-choose it
    /// either, or letting go outside the float ends the selection in the window
    /// behind it. Windows keeps the same pin (app.mouse_press_grid_id).
    private var pressGridId: Int64?

    /// Rebase a surface point into the grid a press already chose, using that
    /// layer's CURRENT drawn origin so a float that moves mid-drag keeps
    /// receiving the right cells. A layer that has gone falls back to this
    /// surface's own grid rather than re-resolving.
    private func rebaseToPressGrid(pointPx: CGPoint, pressed: Int64)
        -> (gridId: Int64, row: Int32, col: Int32)
    {
        guard let main = mainTerminalView, pressed != gridId else {
            return resolveRootTarget(pointPx: pointPx)
        }
        let cellW = CGFloat(shared.cellWidthPx)
        let cellH = CGFloat(shared.cellHeightPx)
        guard cellW > 0, cellH > 0 else { return resolveRootTarget(pointPx: pointPx) }

        tripleBufferLock.lock()
        let layer = committedSurfaceLayers.first { $0.gridId == pressed }
        tripleBufferLock.unlock()
        guard let layer else { return resolveRootTarget(pointPx: pointPx) }

        let rootOffsetPx = main.visualScrollOffsetPx(gridId: gridId, cellHeightPx: cellH)
        let ownOffsetPx = main.visualScrollOffsetPx(gridId: pressed, cellHeightPx: cellH)
        let originY = CGFloat(layer.originPx.y)
            + (ownOffsetPx == 0 && layer.followsScroll ? rootOffsetPx : 0)
        let info = main.core?.getVisibleGridsCached().first { $0.gridId == pressed }
        // Deliberately unclamped to the layer rectangle: a drag that leaves the
        // float still belongs to it, and Neovim clamps the position into the
        // window it was addressed to.
        return (
            pressed,
            scrolledRow(pointPx.y - originY, offsetPx: ownOffsetPx, cellH: cellH, info: info),
            Int32((pointPx.x - CGFloat(layer.originPx.x)) / cellW)
        )
    }

    /// This surface's own grid at `pointPx`, with the ease its rows were drawn
    /// with undone.
    private func resolveRootTarget(pointPx: CGPoint) -> (gridId: Int64, row: Int32, col: Int32) {
        guard let main = mainTerminalView else { return (gridId, 0, 0) }
        let cellW = CGFloat(shared.cellWidthPx)
        let cellH = CGFloat(shared.cellHeightPx)
        guard cellW > 0, cellH > 0 else { return (gridId, 0, 0) }
        let info = main.core?.getVisibleGridsCached().first { $0.gridId == gridId }
        let offsetPx = main.visualScrollOffsetPx(gridId: gridId, cellHeightPx: cellH)
        return (gridId, scrolledRow(pointPx.y, offsetPx: offsetPx, cellH: cellH, info: info),
                Int32(pointPx.x / cellW))
    }

    private func sendMouseEvent(button: String, action: String, event: NSEvent) {
        guard let main = mainTerminalView, let core = main.core else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let location = convert(event.locationInWindow, from: nil)

        // Convert to cell coordinates (flip Y)
        let pointPx = CGPoint(x: location.x * scale,
                              y: bounds.height * scale - location.y * scale)
        // A float this surface hosts is drawn above the root, so a press inside
        // it has to name that grid; naming the root applies the press to the
        // window underneath instead. The drag and release that follow stay on
        // the grid the press chose -- see pressGridId.
        let target: (gridId: Int64, row: Int32, col: Int32)
        if action == "press" {
            target = resolveInputTarget(pointPx: pointPx, requireScrollable: false)
            pressGridId = target.gridId
        } else if let pressed = pressGridId {
            target = rebaseToPressGrid(pointPx: pointPx, pressed: pressed)
            if action == "release" { pressGridId = nil }
        } else {
            target = resolveInputTarget(pointPx: pointPx, requireScrollable: false)
        }

        // Build modifier string (same format as MetalTerminalView)
        let mods = event.modifierFlags
        var modStr = ""
        if mods.contains(.shift)   { modStr += "S" }
        if mods.contains(.control) { modStr += "C" }
        if mods.contains(.option)  { modStr += "A" }
        if mods.contains(.command) { modStr += "D" }

        ZonvieCore.appLog("[ExternalGridView mouseEvent] button=\(button) action=\(action) gridId=\(target.gridId) row=\(target.row) col=\(target.col)")

        core.sendMouseInput(button: button, action: action, modifier: modStr,
                            gridId: target.gridId, row: target.row, col: target.col)
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
        let optionIsMeta = KeyCharacterSelection.optionActsAsMeta(
            hasOption: m.contains(.option),
            modifierRawValue: m.rawValue,
            optionAsMeta: core.getOptionAsMeta()
        )
        let hasControlOrCommand = m.contains(.control) || m.contains(.command) || optionIsMeta

        // Key repeat synthesis. This view's keys reach Neovim through the main
        // view's core, so they have to run on the same paced cadence: left on
        // the OS repeat timer they beat against the display and the picture
        // stalls a frame at a time. State and pacing live in MetalTerminalView
        // (see its Key Repeat Synthesis mark); this view only supplies itself
        // as the owner, being the one whose window and IME state decide when a
        // repeat must stop.
        let swallowed = main.keyRepeatSwallowsOSRepeat(event, owner: self)
        if FrameTracer.enabled {
            FrameTracer.trace(
                .inputSend,
                a: UInt64(event.keyCode),
                b: (event.isARepeat ? 1 : 0) | (swallowed ? 2 : 0),
                seq: UInt32(truncatingIfNeeded: gridId)
            )
        }
        if swallowed { return }

        // If IME is composing (has marked text), let IME handle all keys
        // except Escape which cancels composition.
        if consumeKeyDuringComposition(event) { return }

        // No marked text: special keys or Ctrl/Cmd go directly to Neovim.
        let isSpecialKey = KeyCharacterSelection.isSpecialKeyCode(event.keyCode)

        if hasControlOrCommand || isSpecialKey {
            // Use sendKeyEvent (same as MetalTerminalView) instead of sendInput
            let mods = KeyCharacterSelection.modifierMask(
                control: m.contains(.control),
                optionIsMeta: optionIsMeta,
                shift: m.contains(.shift),
                command: m.contains(.command),
                ctrlBit: UInt32(ZONVIE_MOD_CTRL),
                altBit: UInt32(ZONVIE_MOD_ALT),
                shiftBit: UInt32(ZONVIE_MOD_SHIFT),
                superBit: UInt32(ZONVIE_MOD_SUPER)
            )

            let chars = KeyCharacterSelection.primaryCharacters(
                optionIsMeta: optionIsMeta,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )

            core.sendKeyEvent(
                keyCode: UInt32(event.keyCode),
                mods: mods,
                characters: chars,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            // Cmd shortcuts must not synthesize repeats; everything else
            // (arrows, Ctrl-d, ...) is a replayable held-key candidate.
            if !event.isARepeat && !m.contains(.command) {
                main.armHeldKeyEvent(
                    owner: self,
                    code: event.keyCode,
                    mods: mods,
                    characters: chars,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers
                )
            }
            return
        }

        // `:` <-> `;` swap (config-gated). Handle single keypresses here,
        // bypassing IME; paste flows through a separate path and is unaffected.
        if ZonvieConfig.shared.input.swapColonSemicolon, !hasMarkedText(),
           let ch = event.characters, let swapped = ZonvieConfig.swapColonSemicolon(ch)
        {
            main.beginHeldKeyCapture(isRepeat: event.isARepeat)
            main.sendInputForHeldKey(swapped)
            main.endHeldKeyCapture(owner: self, code: event.keyCode)
            return
        }

        // Plain key: capture what this keyDown sends (via IME insertText ->
        // imeSendCommitted -> sendInputForHeldKey) so repeats can replay it.
        main.beginHeldKeyCapture(isRepeat: event.isARepeat)
        defer { main.endHeldKeyCapture(owner: self, code: event.keyCode) }

        // Let the system handle IME input.
        if let ctx = inputContext, ctx.handleEvent(event) {
            return
        }
        // Fallback: interpret key events directly.
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        mainTerminalView?.disarmKeyRepeat(ifHeld: event.keyCode, reason: "keyUp")
        // Key up events typically not needed for terminal input
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier-only events typically not needed for terminal input, but a
        // modifier change invalidates a recorded held key (e.g. j -> C-j).
        mainTerminalView?.disarmKeyRepeat(ifHeld: nil, reason: "flagsChanged")
    }

    // MARK: - Scroll Event Handling

    /// The grid a trackpad gesture claimed at its start, held through momentum.
    private var lockedScrollTarget: (gridId: Int64, row: Int32, col: Int32)?

    override func scrollWheel(with event: NSEvent) {
        guard let main = mainTerminalView else { return }
        main.noteScrollGesturePhase(event)

        // A gesture's .began carries no delta, so it is dropped by the check
        // below before the lock is consulted. Retire the previous gesture's
        // target here or the first .changed event finds a stale lock and the
        // whole new gesture drives the grid the last one did.
        if event.phase.contains(.began) { lockedScrollTarget = nil }

        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        if deltaY == 0 && deltaX == 0 { return }

        let location = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2.0

        // Flip Y coordinate (view origin is bottom-left, grid origin is top-left)
        let pointPx = CGPoint(x: location.x * scale,
                              y: bounds.height * scale - location.y * scale)

        // Resolve which grid this scroll drives. A trackpad gesture resolves
        // once at its start and keeps that target through its momentum, so a
        // pointer drifting across a float's edge mid-gesture cannot hand the
        // rest of the scroll to another grid; a wheel resolves per event.
        let target: (gridId: Int64, row: Int32, col: Int32)
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.hasPreciseScrollingDeltas && isGesture {
            if lockedScrollTarget == nil {
                lockedScrollTarget = resolveInputTarget(pointPx: pointPx, requireScrollable: true)
            }
            target = lockedScrollTarget ?? resolveInputTarget(pointPx: pointPx, requireScrollable: true)
        } else {
            lockedScrollTarget = nil
            target = resolveInputTarget(pointPx: pointPx, requireScrollable: true)
        }

        let modifier = main.buildModifierString(from: event.modifierFlags)

        if deltaY != 0 {
            ZonvieCore.appLog("[ExternalGridView scroll] deltaY=\(deltaY) hasPrecise=\(event.hasPreciseScrollingDeltas) gridId=\(target.gridId) row=\(target.row) col=\(target.col)")

            let newOffset = main.handleScrollInput(
                gridId: target.gridId,
                row: target.row,
                col: target.col,
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
                // Keep this view's draw clock running while a sub-cell offset
                // is showing: at a buffer edge there are no flushes to
                // activate it, and the edge bounce advances on draw ticks.
                if isPaused && newOffset != 0 {
                    activateDrawLoop()
                }
            }
        }

        // Release the lock once the gesture and its inertia are done. The
        // gesture's own .ended is not released here so momentum keeps the same
        // target; a fresh gesture re-locks on its .began.
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            || event.phase.contains(.cancelled) {
            lockedScrollTarget = nil
        }
    }

}

// MARK: - IME host

extension ExternalGridView: IMEPreeditHost {
    var imeCore: ZonvieCore? { mainTerminalView?.core }

    var imePreeditFont: NSFont {
        guard let main = mainTerminalView else {
            return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        return NSFont(name: shared.currentFontName, size: shared.currentPointSize)
            ?? NSFont.monospacedSystemFont(ofSize: shared.currentPointSize, weight: .regular)
    }

    var imePreeditCellSize: CGSize {
        guard let main = mainTerminalView else { return CGSize(width: 8, height: 16) }
        let scale = window?.backingScaleFactor ?? 2.0
        return CGSize(width: CGFloat(shared.cellWidthPx) / scale,
                      height: CGFloat(shared.cellHeightPx) / scale)
    }

    var imePreeditContainer: NSView { self }

    func imePreeditOrigin(preeditHeight: CGFloat) -> CGPoint {
        let cell = imePreeditCellSize
        if let core = mainTerminalView?.core {
            let cursor = core.getCursorPositionNonBlocking()
            if cursor.row >= 0 && cursor.col >= 0 && cursor.gridId == gridId {
                // Cursor is grid-local; add viewportOriginPx for decorated
                // surfaces (e.g. the cmdline icon/padding).
                let gridContentHeight = CGFloat(gridRows) * cell.height
                let x = viewportOriginPx.x + CGFloat(cursor.col) * cell.width
                let y = viewportOriginPx.y + gridContentHeight - CGFloat(cursor.row + 1) * cell.height
                return CGPoint(x: x, y: y)
            }
        }
        return CGPoint(x: cell.width, y: bounds.height - cell.height - preeditHeight)
    }

    func imeFirstRect() -> NSRect {
        guard let win = window, let main = mainTerminalView else { return .zero }
        let scale = win.backingScaleFactor
        let cellW = CGFloat(shared.cellWidthPx) / scale
        let rowH = CGFloat(shared.cellHeightPx) / scale
        var screenRow = 0
        var screenCol = 0
        if let core = main.core {
            let cursor = core.getCursorPositionNonBlocking()
            if cursor.row >= 0 && cursor.col >= 0 && cursor.gridId == gridId {
                screenRow = Int(cursor.row)
                screenCol = Int(cursor.col)
            }
        }
        let gridContentHeight = CGFloat(gridRows) * rowH
        let cursorXPt = viewportOriginPx.x + CGFloat(screenCol) * cellW
        let cursorYPt = viewportOriginPx.y + gridContentHeight - CGFloat(screenRow + 1) * rowH
        let rectInView = NSRect(x: cursorXPt, y: cursorYPt, width: cellW, height: rowH)
        return win.convertToScreen(convert(rectInView, to: nil))
    }

    func imeSendCommitted(_ text: String) { mainTerminalView?.sendInputForHeldKey(text) }
}

// MARK: - NSTextInputClient (IME support)
extension ExternalGridView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        ime.insertText(string)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        ime.setMarkedText(string, selectedRange: selectedRange)
    }

    func unmarkText() {
        ime.unmarkText()
    }

    func markedRange() -> NSRange { ime.markedRange }

    func selectedRange() -> NSRange { ime.selectedRange }

    func hasMarkedText() -> Bool { ime.hasMarkedText }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { ime.validAttributes }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return ime.firstRect()
    }

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

        if window == nil {
            deactivateDrawLoop()
        }

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
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.activateDrawLoop()
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

        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled && !isDecoratedSurface else { return }

        if scrollbarConfig.isAlways {
            verticalScroller.isHidden = false
            verticalScroller.alphaValue = CGFloat(scrollbarConfig.opacity)
        }

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
        guard let viewport = core.getViewportNonBlocking(gridId: gridId) else { return }

        let viewportChanged = viewport.topline != lastViewportTopline ||
                              viewport.lineCount != lastViewportLineCount ||
                              viewport.botline != lastViewportBotline

        if viewportChanged {
            lastViewportTopline = viewport.topline
            lastViewportLineCount = viewport.lineCount
            lastViewportBotline = viewport.botline
            updateScrollbar(viewport: viewport)

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
        guard let viewport = core.getViewportNonBlocking(gridId: gridId) else { return }

        let visibleLines = viewport.botline - viewport.topline

        switch sender.hitPart {
        case .decrementPage:
            let newTopline = max(1, viewport.topline - (visibleLines - 2) + 1)
            core.scrollToLine(newTopline, useBottom: false)

        case .incrementPage:
            let newTopline = min(viewport.lineCount - visibleLines + 1, viewport.topline + (visibleLines - 2) + 1)
            let targetLine = max(1, newTopline)
            core.scrollToLine(targetLine, useBottom: false)

        case .knob, .knobSlot:
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

// MARK: - Drag & Drop (path expansion on the external cmdline)
extension ExternalGridView {

    /// Only the external cmdline accepts file drops; a drop there inserts the
    /// path as text instead of opening the file. The other decorated surfaces
    /// (popupmenu, messages) have nothing to insert into, so they decline and
    /// the drag falls through.
    var acceptsFileDrops: Bool { gridId == ZonvieCore.cmdlineGridId }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsFileDrops, hasFileURLs(sender) else { return [] }
        FileDragFeedback.showPathText(sender, in: self)
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsFileDrops,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty,
              let core = mainTerminalView?.core else {
            return false
        }

        // Dropping on the command line means "put this path here", regardless
        // of what mode the editor thinks it is in.
        let paths = urls.map { escapePathForNeovim($0.path) }.joined(separator: " ")
        core.sendInput(paths)
        return true
    }
}
