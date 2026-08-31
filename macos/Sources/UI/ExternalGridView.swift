import AppKit
import Metal
import MetalKit
import simd

/// Sparse row history for one external surface. Capacity grows only when a
/// structural row count is observed, then redraw/flush operations reuse that
/// high-water allocation.
private final class ExternalStaleRowSet {
    private(set) var rows: [UInt32] = []
    private var membership: [UInt64] = []
    private let rowLimit: Int
    private var preparedRowCount = 0

    init(rowLimit: Int) {
        self.rowLimit = rowLimit
    }

    func prepare(rowCount: Int) {
        let target = min(rowLimit, max(0, rowCount))
        guard target > preparedRowCount else { return }
        let targetWords = (target + 63) / 64
        if targetWords > membership.count {
            membership.append(contentsOf: repeatElement(0, count: targetWords - membership.count))
        }
        rows.reserveCapacity(target)
        preparedRowCount = target
    }

    func insert(_ row: Int) {
        guard row >= 0, row < preparedRowCount else { return }
        let word = row >> 6
        let mask = UInt64(1) << UInt64(row & 63)
        guard membership[word] & mask == 0 else { return }
        membership[word] |= mask
        rows.append(UInt32(row))
    }

    func removeAll() {
        for storedRow in rows {
            let row = Int(storedRow)
            membership[row >> 6] &= ~(UInt64(1) << UInt64(row & 63))
        }
        rows.removeAll(keepingCapacity: true)
    }
}

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
    private weak var sharedAtlas: GlyphAtlas?

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

    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    // 2-pass rendering pipelines for blur support
    private var backgroundPipeline: MTLRenderPipelineState?
    private var glyphPipeline: MTLRenderPipelineState?

    private let lock = NSLock()

    private var vertexBuffer: MTLBuffer?
    private var vertexBufferCapacity: Int = 0
    private var currentVertexCount: Int = 0
    private var pendingVertexCount: Int? = nil

    // MARK: - Triple Buffering (same pattern as MetalTerminalRenderer)
    // Three buffer sets: one committed (being drawn), one write (being filled),
    // one free. gpuInFlightCount prevents beginFlush from picking a set that
    // the GPU is still reading.
    private let bufferSets: [SurfaceBufferSet] = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
    private var writeSetIndex: Int = 0            // Main thread only (during flush)
    private var flushSourceSetIndex: Int = 0      // Main thread only (during flush)
    private var committedSetIndex: Int = 0        // Protected by tripleBufferLock
    private var gpuInFlightCount: [Int] = [0, 0, 0] // Protected by tripleBufferLock
    private var rowStorageRetirement = SurfaceRowStorageRetirementState() // Protected by tripleBufferLock
    private var isInFlush: Bool = false           // Flush bracket thread only
    // Set (core thread) when a vertex/row buffer allocation fails during
    // this flush bracket. Consumed by ZonvieCore's on_flush_end via
    // consumeFlushFailed(), which cancels the bracket instead of committing
    // it and calls zonvie_core_force_resend + schedules a retry (mirrors
    // MetalTerminalRenderer.flushFailed).
    private(set) var flushFailed: Bool = false    // Flush bracket thread only
    // Complete row metadata lives independently in every set. A set only
    // carries rows changed since it last committed; scroll/resize/abort use a
    // full-copy barrier. This mirrors MetalTerminalRenderer and keeps a one-row
    // external flush O(changed rows) instead of O(total rows).
    private var staleRowsBySet: [ExternalStaleRowSet] = [
        ExternalStaleRowSet(rowLimit: 20_000),
        ExternalStaleRowSet(rowLimit: 20_000),
        ExternalStaleRowSet(rowLimit: 20_000),
    ]
    private var flushChangedRows = ExternalStaleRowSet(rowLimit: 20_000)
    // Rows regenerated after the most recent font-generation transition in
    // this bracket. A commit may advance its set's font generation only when
    // every logical row was regenerated; cursor-only and partial commits keep
    // the older generation and are suppressed by the draw-generation gate.
    private var flushGeneratedRows = ExternalStaleRowSet(rowLimit: 20_000)
    // Capacity is prepared before publication. A later structural growth is
    // staged onto the main thread; the current core flush aborts instead of
    // allocating while a row callback or flush bracket holds rendering state.
    private var rowHistoryPreparedRowCount = 0
    private var rowHistoryRequestedRowCount = 0
    private var rowHistoryGrowthScheduled = false
    private var rowHistoryGrowthWaitingForBracket = false
    private var flushFontGeneration: UInt64 = 0
    private var flushGeneratedTotalRows: Int = 0
    private var flushGeneratedTotalCols: Int = 0
    private var rowStateNeedsFullSync = [false, false, false]
    private var flushHasStructuralRowChange = false
    // Fixed-size capacity ledger. The core callback only raises entries;
    // ZonvieCore's retry worker provisions metadata and MTLBuffers after the
    // bracket closes, before retrying the core flush.
    private var rowCapacityRequiredRows = 0
    private var rowCapacityRequiredVertexCounts = [Int](repeating: 0, count: 20_000)
    private var rowCapacityProvisioning = false // Protected by tripleBufferLock
    private var rowCapacityHardFailure = false // Protected by tripleBufferLock

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
        let capacityRow: Int
        let mappingSetIndex = useWriteMapping ? writeSetIndex : flushSourceSetIndex
        if mappingSetIndex >= 0,
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
            // rowCapacityHardFailure: it is never cleared, so latching it on a
            // soft condition permanently stops this view from presenting.
            flushFailed = true
            return false
        }
        if !lockHeld { tripleBufferLock.lock() }
        rowCapacityRequiredRows = max(max(rowCapacityRequiredRows, totalRows), capacityRow + 1)
        rowCapacityRequiredVertexCounts[capacityRow] = max(
            rowCapacityRequiredVertexCounts[capacityRow],
            max(0, vertexCount)
        )
        if !lockHeld { tripleBufferLock.unlock() }
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
        tripleBufferLock.lock()
        defer { tripleBufferLock.unlock() }
        return rowCapacityRequiredRows > 0 || rowCapacityProvisioning
    }

    /// Called from the flush-retry queue before it acquires core grid_mu.
    func provisionPendingRowCapacity() -> SurfaceRowProvisionStatus {
        tripleBufferLock.lock()
        if rowCapacityHardFailure {
            tripleBufferLock.unlock()
            return .hardFailure
        }
        // Nothing owed: answer ready regardless of what this surface is
        // currently doing. Asked before the busy check because a float
        // presenting at refresh rate almost always has a frame in flight, and
        // the caller folds any one surface's .retry into an app-wide verdict —
        // an idle ledger would otherwise keep the whole retry re-arming.
        guard rowCapacityRequiredRows > 0 else {
            tripleBufferLock.unlock()
            return .ready
        }
        if bracketOpen || rowCapacityProvisioning ||
            gpuInFlightCount.contains(where: { $0 != 0 }) {
            tripleBufferLock.unlock()
            return .retry
        }
        rowCapacityProvisioning = true
        let requiredRows = rowCapacityRequiredRows
        let requiredVertexCounts = Array(rowCapacityRequiredVertexCounts[0..<requiredRows])
        for row in 0..<requiredRows {
            rowCapacityRequiredVertexCounts[row] = 0
        }
        rowCapacityRequiredRows = 0
        tripleBufferLock.unlock()

        let planResult = makeSurfaceRowProvisionPlan(
            bufferSets: bufferSets,
            device: mtlDevice,
            requiredRowCount: requiredRows,
            requiredVertexCounts: requiredVertexCounts,
            maxRowBuffers: maxRowBuffers
        )

        tripleBufferLock.lock()
        defer {
            rowCapacityProvisioning = false
            tripleBufferLock.unlock()
        }
        switch planResult {
        case .overBudget:
            rowCapacityHardFailure = true
            return .hardFailure
        case .allocationFailed(let partialPlan):
            let metrics = partialPlan.metrics
            ZonvieCore.appLog(
                "[ExternalGridView] row provisioning allocation failed gridId=\(gridId) " +
                "attempt=\(metrics.allocationAttemptCount) created=\(metrics.createdBufferCount) " +
                "createdBytes=\(metrics.createdBufferBytes) planned=\(metrics.plannedReplacementCount) " +
                "plannedBytes=\(metrics.plannedReplacementBytes) live=\(metrics.liveBufferCount) " +
                "liveBytes=\(metrics.liveBufferBytes)"
            )
            // Publish only successful private-pool capacities. Committed row
            // buffers and their counts remain transactionally unchanged.
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
                    "[perf] external_row_provision gridId=\(gridId) created=\(plan.metrics.createdBufferCount) " +
                    "createdBytes=\(plan.metrics.createdBufferBytes) attempts=\(plan.metrics.allocationAttemptCount) " +
                    "peakBytes=\(plan.metrics.liveBufferBytes + plan.metrics.plannedReplacementBytes)"
                )
            }
            applySurfaceRowProvisionPlan(plan, to: bufferSets, maxRowBuffers: maxRowBuffers)
        }
        return rowCapacityRequiredRows == 0 ? .ready : .retry
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
    private let tripleBufferLock = NSLock()
    // GPU back-pressure: allow 2 in-flight command buffers.
    // With flush ops now running on core thread (not main), main thread is free
    // to process draw requests while GPU processes the previous frame.
    // Uses non-blocking tryWait since draw() runs on main thread.
    private let inflightSemaphore = DispatchSemaphore(value: 2)
    // See MetalTerminalRenderer.maxRowBuffers for the rationale: a safety
    // cap against a corrupt row index, not a practical content limit —
    // external windows (ext_multigrid) have no smaller row bound than the
    // main grid, so this must not be materially tighter than that cap.
    private let maxRowBuffers = 20000

    /// Occlusion and window-move observers; see viewDidMoveToWindow.
    private var occlusionObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []

    /// Last cursor box this view forwarded to the shared shader cursor
    /// state, in this view's local NDC, so a window move can re-project it.
    /// Nil while the cursor is not on this view's grid.
    private var lastForwardedCursorNdc: (minX: Float, maxX: Float, minY: Float, maxY: Float)?
    private var lastForwardedCursorColor: (Float, Float, Float, Float)?

    // Active rendering mode: when new commits arrive, switch to isPaused=false
    // so MTKView draws at preferredFramesPerSecond (60fps). After idle, pause.
    private var activeDrawIdleFrames: Int = 0
    private let activeDrawIdleThreshold = 10  // Pause after N frames with no new commits

    // Scroll offset data stored as value-type; passed to GPU via setVertexBytes
    // to avoid shared MTLBuffer GPU/CPU race.
    private var scrollOffsetData: MetalTerminalRenderer.ScrollOffset?
    private var scrollOffsetActive: Bool = false
    private var lastPresentedScrollOffsetData: MetalTerminalRenderer.ScrollOffset?
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
    /// The scrollable row span of this window: the grid minus its viewport
    /// margins (a winbar makes marginTop 1, and its row does not scroll).
    /// Armed on the main thread as each gesture scroll is sent, because
    /// Neovim's response can land before the next frame. Guarded by
    /// `pendingGridScrollLock`.
    private var scrollCaptureBounds: (top: Int, bottomEx: Int)?
    private let pendingGridScrollLock = NSLock()

    // Accumulated scroll delta (consumed by draw, survives across flushes)
    // Protected by tripleBufferLock (accessed from both flush ops and draw)
    private var pendingScrollAccum: SurfaceRowScroll? = nil

    // Dirty rows accumulated during flush (consumed by draw)
    // Protected by tripleBufferLock
    private var pendingDirtyRows: Set<Int> = []
    // Render-thread scratch for the ordered row list passed to encoders.
    // Swapped into each draw and returned by defer to retain capacity without
    // sharing storage (and therefore without per-frame Array COW allocation).
    private var dirtyRowsScratch: [Int] = []
    // Separate snapshot scratch for consuming pendingDirtyRows. Copying the
    // Set value itself would share its COW storage, forcing the next flush's
    // first insert to allocate after pendingDirtyRows is cleared.
    private var submittedDirtyRowsScratch: [Int] = []
    // Dirty rows staged during the current flush bracket (guarded by
    // tripleBufferLock; written only while isInFlush). A draw() interleaving
    // with a flush can consume pendingDirtyRows BEFORE commitFlush publishes
    // committedSetIndex: it redraws from the OLD committed set and the marks
    // are lost, so the newly committed rows are never marked dirty again.
    // commitFlush re-publishes these staged marks so the next draw() redraws
    // the rows from the newly committed set. Idempotent when no draw()
    // interleaved. Mirrors MetalTerminalRenderer's flushDirtyRows.
    private var flushDirtyRows: Set<Int> = []

    // Persistent back buffer for partial redraw and GPU scroll copy
    private var backBuffer: MTLTexture? = nil
    private var backBufferSize: CGSize = .zero
    /// Per-view shader timing state. Owning this here (instead of the
    /// shared MetalTerminalRenderer) keeps iFrame / iTimeDelta /
    /// iFrameRate independent of draw order across views.
    private let shaderTiming = MetalTerminalRenderer.ShaderViewTimingState()
    /// Ping-pong render targets for multi-pass custom shader chains.
    /// Allocated lazily inside draw() when pipelines.count > 1.
    private var customShaderPong: [MTLTexture?] = [nil, nil]
    private var customShaderPongSize: CGSize = .zero
    private var scrollScratchTexture: MTLTexture? = nil
    private var scrollScratchSize: CGSize = .zero

    // Blur transparency support
    private let blurEnabled: Bool
    private let isDecoratedSurface: Bool
    private var backgroundAlphaBuffer: MTLBuffer?

    // Viewport origin offset (in pixels) for decorated windows where the MTKView
    // fills the full container but grid content is inset by padding.
    // Allows bloom blur to bleed into the padding area around grid content.
    var viewportOriginPx: CGPoint = .zero

    // --- Post-process bloom (neon glow) ---
    // Pipelines and sampler are shared from MetalTerminalRenderer.
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
    // The buffer/count themselves live per-set on SurfaceBufferSet (see beginFlush's
    // cursor copy-forward and submitVerticesRowRaw's write side) so a GPU-in-flight
    // read of the committed set never races a CPU write into the same MTLBuffer.
    private var cursorDirty: Bool = false

    // Staged out-of-bracket cursor update awaiting a safe apply point.
    // Written by submitVerticesRowRaw's out-of-bracket cursor path when the
    // committed set is GPU-in-flight (writing its cursorVertexBuffer in place
    // would race the in-flight read); applied by draw() once the set is idle
    // and mirrored into the write set by beginFlush(). cursorStagingCount:
    // -1 = none pending, 0 = clear cursor, >0 = vertex count in cursorStaging.
    // Protected by tripleBufferLock.
    private var cursorStaging: [zonvie_vertex] = []
    private var cursorStagingCount: Int = -1

    // Staged out-of-bracket ROW updates awaiting a safe apply point (mirrors
    // cursorStaging). Row buffers are COW-shared across buffer sets, so an
    // in-place write into the committed set can alias a buffer an OLDER
    // GPU-in-flight set still reads — writes are only safe when ALL sets are
    // idle. Applied by draw() at the idle check, or folded into the write set
    // by beginFlush() (a flush's own row content is newer and overwrites).
    // Protected by tripleBufferLock.
    private var rowStaging: [Int: [zonvie_vertex]] = [:]
    private var rowStagingTotalRows: Int = 0
    private var rowStagingTotalCols: Int = 0

    // Staged rows folded into the CURRENT bracket's write set by beginFlush.
    // Held here (not dropped) until the bracket resolves: commitFlush clears
    // them (published), cancelFlush / a contentless commit merges them back
    // into rowStaging (newer staged entries win) so a cancelled flush cannot
    // permanently lose replayed rows. Protected by tripleBufferLock.
    private var rowStagingFolded: [Int: [zonvie_vertex]] = [:]

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

    /// Merge folded (bracket-pending) staged rows back into rowStaging.
    /// Caller must hold tripleBufferLock. Newer staged entries win.
    private func restoreFoldedRowStagingLocked() {
        guard !rowStagingFolded.isEmpty else { return }
        for (row, verts) in rowStagingFolded where rowStaging[row] == nil {
            rowStaging[row] = verts
        }
        rowStagingFolded.removeAll(keepingCapacity: true)
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


    // Use MetalTerminalRenderer.ScrollOffset for shader data (shared with main window)

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
    ///   - sharedPipeline: Shared render pipeline from main renderer
    ///   - sharedBackgroundPipeline: Shared 2-pass background pipeline (for blur)
    ///   - sharedGlyphPipeline: Shared 2-pass glyph pipeline (for blur)
    ///   - sharedSampler: Shared sampler state
    ///   - blurEnabled: Whether blur effect is enabled
    ///   - isDecoratedSurface: Whether this grid uses a decorated special-window shell
    init(gridId: Int64,
          device: MTLDevice,
          commandQueue: MTLCommandQueue,
          backgroundAlphaBuffer: MTLBuffer,
          cursorBlinkBuffer: MTLBuffer,
          initialRows: Int,
          atlas: GlyphAtlas,
          sharedPipeline: MTLRenderPipelineState,
          sharedBackgroundPipeline: MTLRenderPipelineState?,
          sharedGlyphPipeline: MTLRenderPipelineState?,
          sharedSampler: MTLSamplerState,
          blurEnabled: Bool = false,
          isDecoratedSurface: Bool = false) {
        self.gridId = gridId
        self.mtlDevice = device
        self.retention = ScrollRetention(device: device)
        self.queue = commandQueue
        self.sharedAtlas = atlas
        self.blurEnabled = blurEnabled
        self.isDecoratedSurface = isDecoratedSurface

        // Use shared pipelines from main renderer (no shader compilation needed)
        self.pipeline = sharedPipeline
        self.backgroundPipeline = sharedBackgroundPipeline
        self.glyphPipeline = sharedGlyphPipeline
        self.sampler = sharedSampler

        super.init(frame: .zero, device: device)
        self.backgroundAlphaBuffer = backgroundAlphaBuffer
        self.cursorBlinkBuffer = cursorBlinkBuffer

        let initialFontGeneration = atlas.fontGenerationSnapshot()
        fontResetState = ExternalFontResetState(initialGeneration: initialFontGeneration)
        for bufferSet in bufferSets {
            bufferSet.fontGeneration = initialFontGeneration
        }
        prepareRowHistoryCapacityNow(rowCount: initialRows)

        ZonvieCore.appLog("[ExternalGridView] init: gridId=\(gridId) blurEnabled=\(blurEnabled) (using shared pipelines)")

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.preferredFramesPerSecond = 60
        self.isPaused = true
        self.enableSetNeedsDisplay = true  // Idle mode: manual redraw via setNeedsDisplay

        // Configure layer transparency for compositing with container background
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

        // Create background alpha buffer for shader
        if let buf = self.backgroundAlphaBuffer {
            var alpha = resolveSurfaceBackgroundAlpha(
                blurEnabled: blurEnabled,
                decoratedSurface: isDecoratedSurface
            )
            // Popupmenu has per-row bg colors (Pmenu vs PmenuSel) that the
            // user must be able to tell apart. The decorated-surface alpha
            // override above forces the shader to multiply every bg color
            // by 0 so the cmdline-style "show blur through cells" trick
            // works for the single-color cmdline / msg surfaces, but it
            // collapses the popupmenu into a uniform transparent block and
            // hides the selection. Use 1.0 instead so each cell renders
            // with its own opaque bg; the popupmenu's surrounding blur is
            // still preserved by the container view's transparent layer
            // around the Metal viewport.
            // -101 = POPUPMENU_GRID_ID (matches grid.zig:9 / ZonvieCore.popupmenuGridId)
            if gridId == -101 {
                alpha = 1.0
            }
            ZonvieCore.appLog("[ExternalGridView] backgroundAlphaBuffer alpha=\(alpha) isDecoratedSurface=\(isDecoratedSurface) gridId=\(gridId)")
            memcpy(buf.contents(), &alpha, MemoryLayout<Float>.size)
        }

        // Create cursor blink buffer for shader
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

        // Add scrollbar only for normal detached grids.
        setupScrollbar()
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

        // Release per-view Metal resources.
        vertexBuffer = nil
        backBuffer = nil
        scrollScratchTexture = nil
        backgroundAlphaBuffer = nil
        cursorBlinkBuffer = nil

        // Release glow textures.
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
                self.activeDrawIdleFrames = 0
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

    private static let machTimebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private func hadRecentCommit(withinNs: UInt64) -> Bool {
        tripleBufferLock.lock()
        let t = lastCommitTime
        tripleBufferLock.unlock()
        if t == 0 { return false }
        let now = mach_absolute_time()
        let info = Self.machTimebaseInfo
        let elapsedNs = (now - t) * UInt64(info.numer) / UInt64(info.denom)
        return elapsedNs < withinNs
    }

    private func setupScrollbar() {
        let scrollbarConfig = ZonvieConfig.shared.scrollbar
        guard scrollbarConfig.enabled else { return }

        // Don't add scrollbar to decorated special grids.
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

    private func prepareRowHistoryCapacityNow(rowCount: Int) {
        let target = min(maxRowBuffers, max(0, rowCount))
        guard target > rowHistoryPreparedRowCount else { return }
        for staleRows in staleRowsBySet {
            staleRows.prepare(rowCount: target)
        }
        flushChangedRows.prepare(rowCount: target)
        flushGeneratedRows.prepare(rowCount: target)
        rowHistoryPreparedRowCount = target
    }

    private func requestRowHistoryCapacity(rowCount: Int) -> Bool {
        let target = min(maxRowBuffers, max(0, rowCount))
        tripleBufferLock.lock()
        if target <= rowHistoryPreparedRowCount {
            tripleBufferLock.unlock()
            return true
        }
        rowHistoryRequestedRowCount = max(rowHistoryRequestedRowCount, target)
        let shouldSchedule = !rowHistoryGrowthScheduled && !rowHistoryGrowthWaitingForBracket
        if shouldSchedule {
            rowHistoryGrowthScheduled = true
        }
        tripleBufferLock.unlock()

        if shouldSchedule {
            enqueueRowHistoryGrowth()
        }
        return false
    }

    private func enqueueRowHistoryGrowth() {
        DispatchQueue.main.async { [weak self] in
            self?.growRowHistoryCapacityOutsideFlush()
        }
    }

    /// Caller holds tripleBufferLock after closing bracketOpen.
    private func scheduleWaitingRowHistoryGrowthLocked() -> Bool {
        guard rowHistoryGrowthWaitingForBracket else { return false }
        if rowHistoryRequestedRowCount <= rowHistoryPreparedRowCount {
            rowHistoryGrowthWaitingForBracket = false
            return false
        }
        guard !rowHistoryGrowthScheduled else { return false }
        // Keep the fairness gate set until the prepared capacity publishes.
        // A new core bracket arriving before the main-queue worker then aborts
        // instead of repeatedly racing and discarding another allocation.
        rowHistoryGrowthScheduled = true
        return true
    }

    private func growRowHistoryCapacityOutsideFlush() {
        tripleBufferLock.lock()
        if bracketOpen {
            rowHistoryGrowthScheduled = false
            rowHistoryGrowthWaitingForBracket = true
            tripleBufferLock.unlock()
            return
        }
        let requested = rowHistoryRequestedRowCount
        let doubled = rowHistoryPreparedRowCount > maxRowBuffers / 2
            ? maxRowBuffers
            : max(64, rowHistoryPreparedRowCount * 2)
        let target = min(maxRowBuffers, max(requested, doubled))
        tripleBufferLock.unlock()

        // Allocate every replacement outside the render-state lock. Do not
        // retain COW snapshots of the live trackers: a concurrent append or
        // removeAll would otherwise detach their Array backing storage on the
        // core hot path. Sparse history can be discarded safely by publishing
        // a full-sync barrier for all three sets at the atomic swap below.
        let replacementStaleRows = [
            ExternalStaleRowSet(rowLimit: maxRowBuffers),
            ExternalStaleRowSet(rowLimit: maxRowBuffers),
            ExternalStaleRowSet(rowLimit: maxRowBuffers),
        ]
        let replacementChangedRows = ExternalStaleRowSet(rowLimit: maxRowBuffers)
        let replacementGeneratedRows = ExternalStaleRowSet(rowLimit: maxRowBuffers)
        for rows in replacementStaleRows {
            rows.prepare(rowCount: target)
        }
        replacementChangedRows.prepare(rowCount: target)
        replacementGeneratedRows.prepare(rowCount: target)

        tripleBufferLock.lock()
        if target <= rowHistoryPreparedRowCount {
            rowHistoryGrowthWaitingForBracket = false
            let needsAnotherGrowth = rowHistoryRequestedRowCount > rowHistoryPreparedRowCount
            rowHistoryGrowthScheduled = needsAnotherGrowth
            tripleBufferLock.unlock()
            if needsAnotherGrowth {
                enqueueRowHistoryGrowth()
            }
            return
        }
        if bracketOpen {
            rowHistoryGrowthScheduled = false
            rowHistoryGrowthWaitingForBracket = true
            tripleBufferLock.unlock()
            return
        }
        // Keep the retired trackers alive until after unlock so their Array
        // backing storage cannot be freed while draw/flush waits on this lock.
        let retiredStaleRows = staleRowsBySet
        let retiredChangedRows = flushChangedRows
        let retiredGeneratedRows = flushGeneratedRows
        staleRowsBySet = replacementStaleRows
        flushChangedRows = replacementChangedRows
        flushGeneratedRows = replacementGeneratedRows
        for i in rowStateNeedsFullSync.indices {
            rowStateNeedsFullSync[i] = true
        }
        rowHistoryPreparedRowCount = target
        rowHistoryGrowthWaitingForBracket = false
        let needsAnotherGrowth = rowHistoryRequestedRowCount > target
        rowHistoryGrowthScheduled = needsAnotherGrowth
        tripleBufferLock.unlock()

        withExtendedLifetime(retiredStaleRows) {}
        withExtendedLifetime(retiredChangedRows) {}
        withExtendedLifetime(retiredGeneratedRows) {}

        ZonvieCore.appLog("[ExternalGridView] row history capacity grown outside flush gridId=\(gridId) rows=\(target)")
        if needsAnotherGrowth {
            enqueueRowHistoryGrowth()
        }
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
        for row in 0..<totalRows {
            pendingDirtyRows.insert(row)
        }
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

    /// Submit vertices for rendering. Called from the Zig core callback.
    func submitVertices(ptr: UnsafeRawPointer?, count: Int, rows: UInt32, cols: UInt32) {
        // Mark scroll offset for clearing when content changes (Neovim has processed scroll)
        // The actual clearing happens in draw() via processPendingScrollClears() + updateScrollShaderOffset()
        // to ensure proper synchronization with rendering
        if let main = mainTerminalView, main.getScrollOffset(gridId: gridId) != 0 {
            main.clearScrollOffsetForExternalGrid(gridId)
        }

        lock.lock()
        defer { lock.unlock() }

        gridRows = rows
        gridCols = cols

        if count > 0, let ptr = ptr {
            ensureVertexBufferCapacity(count, forceReplace: true)
            if let vb = vertexBuffer {
                memcpy(vb.contents(), ptr, count * MemoryLayout<Vertex>.stride)
                pendingVertexCount = count
            } else {
                pendingVertexCount = 0
            }
        } else {
            pendingVertexCount = 0
        }
    }

    /// Begin flush bracket — pick a free buffer set and copy committed buffer references.
    /// Called on main thread before vertex submission during a flush cycle.
    /// Returns false if the flush bracket could not be opened (no free buffer
    /// set) — the caller must then tell the core to abort this flush, exactly
    /// as MetalTerminalRenderer.beginFlush()'s `.dropped` result does.
    @discardableResult
    func beginFlush() -> Bool {
        tripleBufferLock.lock()
        if rowCapacityProvisioning || rowCapacityRequiredRows > 0 || rowCapacityHardFailure {
            tripleBufferLock.unlock()
            isInFlush = false
            ZonvieCore.appLog("[ExternalGridView] beginFlush: waiting for row capacity provisioning gridId=\(gridId)")
            return false
        }
        if rowHistoryGrowthWaitingForBracket {
            // A capacity worker collided with the previous bracket. Give its
            // already-scheduled main-queue retry an allocation-free publish
            // window; otherwise a high-frequency core stream can starve it by
            // opening a new bracket before every attempt.
            tripleBufferLock.unlock()
            isInFlush = false
            ZonvieCore.appLog("[ExternalGridView] beginFlush: waiting for row-history growth gridId=\(gridId)")
            return false
        }
        flushDirtyRows.removeAll(keepingCapacity: true)
        let srcIdx = committedSetIndex
        let picked = pickFreeBufferSetIndex(
            count: 3,
            committedIndex: srcIdx,
            gpuInFlightCount: gpuInFlightCount
        )
        if picked == -1 {
            // All non-committed sets are GPU in-flight — drop this flush
            let inf = gpuInFlightCount
            tripleBufferLock.unlock()
            isInFlush = false
            ZonvieCore.appLog("[ExternalGridView] beginFlush: no free buffer set, dropping flush gridId=\(gridId) committed=\(srcIdx) gpuInFlight=[\(inf[0]),\(inf[1]),\(inf[2])]")
            return false
        }
        writeSetIndex = picked
        flushSourceSetIndex = srcIdx
        flushFontGeneration = fontResetState.beginFlushGeneration(
            sourceGeneration: bufferSets[srcIdx].fontGeneration
        )
        flushGeneratedTotalRows = bufferSets[srcIdx].knownTotalRows
        flushGeneratedTotalCols = bufferSets[srcIdx].knownTotalCols
        flushGeneratedRows.removeAll()
        // Publish "bracket open" BEFORE the unlocked committed-set copies
        // below: main-thread out-of-bracket writers check this under the
        // same lock and stage instead of mutating the committed set, which
        // makes the unlocked copySurfaceBufferSetRowState / cursor
        // carry-forward reads safe (no concurrent committed-set mutation
        // can start once this is set).
        bracketOpen = true
        tripleBufferLock.unlock()

        isInFlush = true
        flushHadContent = false
        flushChangedRows.removeAll()
        flushHasStructuralRowChange = false
        // Discard retention staged by a bracket that aborted instead of
        // committing; publication only ever happens from commitFlush. Then
        // capture what this flush's scroll is about to take off the edge,
        // while the committed set still holds the on-screen rows.
        retention.beginFlush()
        captureRetainedRowsForPendingScroll()
        // Clear stale scroll staging from a previous bracket on this set
        // (mirrors MetalTerminalRenderer.beginFlush's dst.pendingScroll = nil).
        bufferSets[picked].pendingScroll = nil
        let src = bufferSets[srcIdx]
        let dst = bufferSets[picked]
        let staleRows = staleRowsBySet[picked].rows
        let perfStarted = ZonvieCore.appLogEnabled ? CFAbsoluteTimeGetCurrent() : 0
        var syncMode = "sparse"
        var syncedRows = staleRows.count
        if rowStateNeedsFullSync[picked] {
            copySurfaceBufferSetRowState(from: src, to: dst)
            syncMode = "full_barrier"
            syncedRows = src.rowState.buffers.count
        } else if !copySurfaceBufferSetRows(
            from: src,
            to: dst,
            logicalRows: staleRows,
            maxRowBuffers: maxRowBuffers
        ) {
            copySurfaceBufferSetRowState(from: src, to: dst)
            syncMode = "full_mapping_fallback"
            syncedRows = src.rowState.buffers.count
        }
        if ZonvieCore.appLogEnabled {
            let elapsedUs = (CFAbsoluteTimeGetCurrent() - perfStarted) * 1_000_000
            let elapsedUsString = String(format: "%.1f", elapsedUs)
            ZonvieCore.appLogPerf("[perf] external_begin_prepare gridId=\(gridId) mode=\(syncMode) syncedRows=\(syncedRows) totalRows=\(src.rowState.buffers.count) us=\(elapsedUsString)")
        }
        // Carry the committed set's cursor forward into the write set.
        // copySurfaceBufferSetRowState copies NO cursor state; without this,
        // a flush that commits without a cursor resubmission would rotate
        // committedSetIndex onto a stale/nil cursor slot. Copy into dst's OWN
        // buffer (allocate only on capacity growth), never COW-share — same
        // as MetalTerminalRenderer's per-set cursor copy (lines 996-1009).
        let cursorSrc = src
        let cursorDst = dst
        let cursorBytes = cursorSrc.cursorVertexCount * MemoryLayout<Vertex>.stride
        if cursorSrc.cursorVertexCount > 0, let srcBuf = cursorSrc.cursorVertexBuffer {
            if cursorDst.cursorVertexBuffer == nil || cursorDst.cursorVertexBufferCap < cursorBytes {
                let newCap = max(cursorBytes, 48 * MemoryLayout<Vertex>.stride)
                cursorDst.cursorVertexBuffer = mtlDevice.makeBuffer(length: newCap, options: .storageModeShared)
                cursorDst.cursorVertexBufferCap = cursorDst.cursorVertexBuffer != nil ? newCap : 0
                if cursorDst.cursorVertexBuffer == nil { flushFailed = true }
            }
            if let dstBuf = cursorDst.cursorVertexBuffer {
                memcpy(dstBuf.contents(), srcBuf.contents(), cursorBytes)
            }
        }
        cursorDst.cursorVertexCount = cursorSrc.cursorVertexCount
        // A staged out-of-bracket cursor update (see submitVerticesRowRaw) is
        // newer than the committed cursor copied above — overwrite the write
        // set with it so a commit without cursor resubmission publishes it.
        // Do NOT clear the staging: if this flush ends without content the
        // committed set never rotates, and draw() still needs to apply the
        // staging there once idle (re-applying identical data is idempotent).
        tripleBufferLock.lock()
        if cursorStagingCount >= 0 {
            let stagedCount = cursorStagingCount
            cursorStaging.withUnsafeBufferPointer { stagedBuf in
                if !writeCursorVertices(into: cursorDst, ptr: stagedBuf.baseAddress, count: stagedCount) {
                    flushFailed = true
                }
            }
        }
        // Fold staged out-of-bracket ROW updates into the write set (never
        // GPU-in-flight, so this is always safe). Moved into rowStagingFolded
        // (not dropped): commitFlush clears them once published, while
        // cancelFlush merges them back into rowStaging so a cancelled flush
        // cannot permanently lose replayed rows. Any newer row content
        // submitted during this bracket simply overwrites the folded rows in
        // the write set, preserving submission order.
        // Folding staged rows IS flush content — without flushHadContent the
        // bracket may end without a commit and the folded rows would stay
        // orphaned in the write set (same failure shape as the cursor-only
        // flush bug in submitVerticesRowRaw).
        if !rowStaging.isEmpty {
            flushHadContent = true
            gridRows = UInt32(rowStagingTotalRows)
            gridCols = UInt32(rowStagingTotalCols)
            for (row, verts) in rowStaging {
                verts.withUnsafeBufferPointer { stagedBuf in
                    // Locked variant: this section holds tripleBufferLock.
                    let structural = !src.rowState.usingRowBuffers
                        || rowStagingTotalRows != src.knownTotalRows
                        || rowStagingTotalCols != src.knownTotalCols
                    // Allocate synchronously, finishing the revert b83ff29 began
                    // and 4b1ad75 applied to submitVerticesRowRaw above: the
                    // pre-provisioning gate does not converge, and a per-view
                    // failure here escalates through ZonvieCore's flushFailed
                    // sweep into an app-wide abort_flush. requirePreparedRowCapacity
                    // now only records a real allocation failure for recovery.
                    if !submitSurfaceRowVertices(
                        target: cursorDst,
                        sourceSet: src,
                        device: mtlDevice,
                        rowStart: row,
                        ptr: stagedBuf.baseAddress.map(UnsafeRawPointer.init),
                        count: verts.count,
                        maxRowBuffers: maxRowBuffers,
                        totalRows: rowStagingTotalRows,
                        totalCols: rowStagingTotalCols,
                        inflightRowBuffers: { self.inflightRowBuffersLocked(atSlot: $0) }
                    ) {
                        _ = requirePreparedRowCapacity(
                            row: row,
                            vertexCount: verts.count,
                            totalRows: rowStagingTotalRows,
                            lockHeld: true,
                            useWriteMapping: true
                        )
                        flushFailed = true
                    } else {
                        recordGeneratedRowsLocked(
                            rowStart: row,
                            rowCount: 1,
                            totalRows: rowStagingTotalRows,
                            totalCols: rowStagingTotalCols
                        )
                        if structural {
                            flushHasStructuralRowChange = true
                        } else {
                            flushChangedRows.insert(row)
                        }
                    }
                }
                pendingDirtyRows.insert(row)
                flushDirtyRows.insert(row)
                rowStagingFolded[row] = verts
            }
            rowStaging.removeAll(keepingCapacity: true)
        }
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
    /// the bracket flag is sufficient — EXCEPT for staged rows this bracket's
    /// beginFlush folded into the (now discarded) write set: merge them back
    /// into rowStaging or the replayed rows are lost forever (the core never
    /// resends them). Safe no-op when no bracket is open.
    func cancelFlush() {
        isInFlush = false
        tripleBufferLock.lock()
        if bracketOpen {
            rowStateNeedsFullSync[writeSetIndex] = true
            staleRowsBySet[writeSetIndex].removeAll()
        }
        restoreFoldedRowStagingLocked()
        flushChangedRows.removeAll()
        flushGeneratedRows.removeAll()
        flushHasStructuralRowChange = false
        bracketOpen = false
        let shouldScheduleGrowth = scheduleWaitingRowHistoryGrowthLocked()
        tripleBufferLock.unlock()
        if shouldScheduleGrowth {
            enqueueRowHistoryGrowth()
        }
    }

    /// Commit flush — publish write set as the new committed state for draw().
    /// Called from core thread (thread-safe via tripleBufferLock).
    func commitFlush() {
        guard isInFlush else { return }
        let hadContent = flushHadContent
        var shouldScheduleGrowth = false
        if hadContent {
            let layoutContracted =
                bufferSets[flushSourceSetIndex].knownTotalRows > bufferSets[writeSetIndex].knownTotalRows
                || bufferSets[flushSourceSetIndex].knownTotalCols > bufferSets[writeSetIndex].knownTotalCols
            tripleBufferLock.lock()
            committedSetIndex = writeSetIndex
            committedGridRows = gridRows
            committedGridCols = gridCols
            // Publish this bracket's retention together with the vertices it
            // belongs to: a retained row shown against pre-scroll content
            // would draw the same line twice. Same for the cursor rect the
            // shader uniforms carry — it describes this bracket's cursor
            // vertices, which only reach the screen now.
            retention.commit()
            mainTerminalView?.renderer.publishCursorShaderState()
            // The distance this bracket captured against is only spent now
            // that its vertices are the committed ones; a cancelled bracket
            // leaves it for the next (see captureRetainedRowsForPendingScroll).
            pendingGridScrollLock.lock()
            pendingGridScrollRows = 0
            pendingGridScrollLock.unlock()
            commitRevision &+= 1
            serviceSurfaceRowStorageRetirement(
                bufferSets: bufferSets,
                gpuInFlightCount: gpuInFlightCount,
                committedSetIndex: committedSetIndex,
                layoutContracted: layoutContracted,
                state: &rowStorageRetirement
            )
            // Freeze the atlas texture reference into the SAME buffer set
            // as this commit's vertex data — see SurfaceBufferSet.atlasTextureSnapshot
            // for why draw(in:) must read both from one consistent
            // generation instead of independently re-fetching the atlas at
            // a later point. Safe to call here: ZonvieCore's on_flush_end
            // always commits the main renderer (which commits the atlas)
            // before calling this function, both on the core/RPC thread.
            bufferSets[writeSetIndex].atlasTextureSnapshot = mainTerminalView?.renderer.committedAtlasSnapshot()
            // Merge the write set's staged scroll into the global accumulator.
            // Done here (under lock, after committedSetIndex update) so draw()
            // never sees a scroll delta that precedes the matching vertex data
            // (mirrors MetalTerminalRenderer.commitFlush).
            if let ps = bufferSets[writeSetIndex].pendingScroll {
                if let existing = pendingScrollAccum,
                   existing.rowStart == ps.rowStart,
                   existing.rowEnd == ps.rowEnd {
                    pendingScrollAccum = SurfaceRowScroll(
                        rowStart: ps.rowStart, rowEnd: ps.rowEnd,
                        colStart: ps.colStart, colEnd: ps.colEnd,
                        // Wrapping add: matches MetalTerminalRenderer.commitFlush's
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
                        pendingDirtyRows.formUnion(existing.rowStart..<existing.rowEnd)
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
            // interleaved (mirrors MetalTerminalRenderer.commitFlush).
            pendingDirtyRows.formUnion(flushDirtyRows)
            flushDirtyRows.removeAll(keepingCapacity: true)
            // Folded staged rows are published with this commit — drop them.
            rowStagingFolded.removeAll(keepingCapacity: true)
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
            if !pendingDirtyRows.isEmpty || pendingScrollAccum != nil {
                lastCommitTime = mach_absolute_time()
            }
            flushChangedRows.removeAll()
            flushGeneratedRows.removeAll()
            flushHasStructuralRowChange = false
            bracketOpen = false
            shouldScheduleGrowth = scheduleWaitingRowHistoryGrowthLocked()
            tripleBufferLock.unlock()
        } else {
            // Contentless bracket: nothing rotates. Close the bracket flag
            // and put any folded staged rows back (unreachable in practice —
            // folding sets flushHadContent — kept for robustness).
            tripleBufferLock.lock()
            restoreFoldedRowStagingLocked()
            flushChangedRows.removeAll()
            flushGeneratedRows.removeAll()
            flushHasStructuralRowChange = false
            bracketOpen = false
            shouldScheduleGrowth = scheduleWaitingRowHistoryGrowthLocked()
            tripleBufferLock.unlock()
        }
        isInFlush = false
        if shouldScheduleGrowth {
            enqueueRowHistoryGrowth()
        }
        if hadContent {
            // Activate auto-draw so the new commit gets rendered at display refresh rate
            activateDrawLoop()
        }
    }

    /// Apply row scroll notification from core.
    /// Called from the core/flush thread inside the flush bracket.
    /// Performs row slot remapping on the write set and records pending scroll for GPU blit.
    /// Record how far this grid's content just moved. Called from the
    /// grid_scroll callback on the core thread; the capture itself waits for
    /// this view's flush bracket to open (see captureRetainedRowsForPendingScroll).
    func noteGridScroll(rowsDelta: Int) {
        guard MetalTerminalRenderer.smoothScrollEnabled, rowsDelta != 0 else { return }
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
    private func cursorScrollOffsetPxForShader() -> Float? {
        // The cursor rect is shared with the main surface and every other
        // external window. Only displace it when it is this grid's cursor;
        // otherwise say nothing and let the owner's value stand.
        guard let renderer = mainTerminalView?.renderer,
              renderer.shaderCursorBelongs(toGrid: gridId) else { return nil }
        lock.lock()
        let offset = scrollOffsetActive ? scrollOffsetData : nil
        lock.unlock()
        guard let offset else { return 0 }
        // Undo computeScrollOffset's NDC conversion against this window's
        // viewport height, which is the same height screenSpaceParameters maps
        // through — so the result is already in the rect's pixel space.
        tripleBufferLock.lock()
        let snappedRows = committedGridRows
        tripleBufferLock.unlock()
        let cellHeightPx = Float(mainTerminalView?.renderer.cellHeightPx ?? 0)
        guard cellHeightPx > 0 else { return 0 }
        let rowsForHeight = snappedRows > 0 ? snappedRows : gridRows
        let cellHi = max(1, UInt32(cellHeightPx.rounded(.up)))
        let viewportHeight = Float(rowsForHeight) * Float(cellHi)
        guard viewportHeight > 0 else { return 0 }
        return -offset.offset_y * viewportHeight / 2.0
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
    /// the core's row-scroll fast path, which it skips for a coalesced
    /// multi-row step and in the multi-scroll and anchored-float cases,
    /// whereas grid_scroll is reported for every scroll; and ZonvieCore opens
    /// the bracket immediately before calling `applyRowScroll`, so capturing
    /// there as well would stage the same rows twice.
    private func captureRetainedRowsForPendingScroll() {
        guard MetalTerminalRenderer.smoothScrollEnabled else { return }
        // Read but do NOT consume: this bracket may be cancelled, and the core
        // never resends a grid_scroll (it consumes the notification as it
        // dispatches). Clearing here would lose the distance, leaving the
        // published rows a step behind the content they are drawn against —
        // stale lines over live text, with the edge stretch suppressed because
        // rows are still published. commitFlush clears it once the vertices
        // this capture belongs to are actually on screen. Same reasoning as
        // cancelFlush's rowStaging merge-back.
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
        captureRetainedRows(
            ws: bufferSets[flushSourceSetIndex],
            rowStart: bounds.top,
            rowEnd: min(bounds.bottomEx, rows),
            rowsDelta: rowsDelta
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
    private func captureRetainedRows(ws: SurfaceBufferSet, rowStart: Int, rowEnd: Int, rowsDelta: Int) {
        guard MetalTerminalRenderer.smoothScrollEnabled else { return }
        guard ws.rowState.usingRowBuffers else { return }
        guard let plan = ScrollRetention.plan(
            rowStart: rowStart,
            rowEnd: rowEnd,
            rowsDelta: rowsDelta,
            depth: retention.depthRows
        ) else { return }

        let capturedCellHeightPx = Float(mainTerminalView?.renderer.cellHeightPx ?? 0)
        guard capturedCellHeightPx > 0 else { return }
        var stepOpened = false
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

    func applyRowScroll(rowStart: Int, rowEnd: Int, colStart: Int, colEnd: Int, rowsDelta: Int, totalRows: Int, totalCols: Int) {
        ZonvieCore.appLog("[ext_applyRowScroll] gridId=\(gridId) rowStart=\(rowStart) rowEnd=\(rowEnd) rowsDelta=\(rowsDelta) isInFlush=\(isInFlush)")
        guard isInFlush else {
            ZonvieCore.appLog("[ExternalGridView] applyRowScroll called outside flush bracket gridId=\(gridId)")
            return
        }
        guard rowsDelta != 0 else { return }
        guard rowStart >= 0, rowEnd > rowStart else { return }

        // Consumer-side eligibility: only remap for full-width, single-row scrolls
        guard colStart == 0, colEnd == totalCols else { return }
        // No capacity pre-check here, matching applyMainRowScrollRaw in
        // MetalTerminalRenderer: this path only grows the logical row-state
        // arrays, which remapSurfaceRowSlots does synchronously via
        // ensureSurfaceRowStorage. The pre-check also required all three
        // buffer sets' detach-pool and private-slot arrays to be sized, and
        // those are grown only by the async provisioning plan -- so after an
        // ordinary row-count growth it failed, set flushFailed, and (via
        // ZonvieCore's per-view sweep) aborted the whole app's flush including
        // the main grid, recovering only through the same async detour that
        // does not converge under sustained scroll.

        let ws = bufferSets[writeSetIndex]
        // No retention capture here. This runs only when the core takes the
        // row-scroll fast path, but the grid_scroll callback has already
        // handed the same distance to captureRetainedRowsForPendingScroll,
        // which ran at bracket open — and ZonvieCore opens the bracket
        // immediately before calling this. Capturing again would stage the
        // same rows twice and shift the first copy a second time.
        flushHasStructuralRowChange = true
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
        // MetalTerminalRenderer's beginFlush-stage/commitFlush-merge split.
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
            // Region change within one bracket: the older staged blit can no
            // longer be represented, but its row-slot remap already happened —
            // dirty its rows so they redraw from the (post-remap) vertices.
            if let staged = ws.pendingScroll, staged.rowEnd > staged.rowStart {
                flushDirtyRows.formUnion(staged.rowStart..<staged.rowEnd)
            }
            ws.pendingScroll = SurfaceRowScroll(
                rowStart: rowStart, rowEnd: rowEnd,
                colStart: colStart, colEnd: colEnd,
                rowsDelta: rowsDelta,
                totalRows: totalRows, totalCols: totalCols
            )
        }

        // Do NOT mark the entire scroll region as dirty here.
        // GPU scroll copy (blit) handles pixel shift; only vacated rows need redraw.
        // Core sends vertex data only for dirty rows (regen_count=1 in fast path).
        // Marking all rows dirty would cause full redraw, negating the blit benefit.
        flushHadContent = true
    }

    /// Write cursor vertices into a buffer set's dedicated cursor buffer
    /// (allocate only on capacity growth; count == 0 clears the cursor).
    /// Caller must guarantee the set is not GPU-in-flight: the write set
    /// inside a flush bracket, or the committed set with
    /// gpuInFlightCount == 0 while holding tripleBufferLock.
    @discardableResult
    private func writeCursorVertices(into targetSet: SurfaceBufferSet, ptr: UnsafePointer<zonvie_vertex>?, count: Int) -> Bool {
        if count > 0, let validPtr = ptr {
            let byteCount = count * MemoryLayout<Vertex>.stride
            if targetSet.cursorVertexBuffer == nil || targetSet.cursorVertexBufferCap < byteCount {
                let newCap = max(byteCount, 48 * MemoryLayout<Vertex>.stride)
                targetSet.cursorVertexBuffer = mtlDevice.makeBuffer(length: newCap, options: .storageModeShared)
                targetSet.cursorVertexBufferCap = targetSet.cursorVertexBuffer != nil ? newCap : 0
            }
            if let buf = targetSet.cursorVertexBuffer {
                memcpy(buf.contents(), validPtr, byteCount)
                targetSet.cursorVertexCount = count
            } else {
                return false
            }
        } else {
            targetSet.cursorVertexCount = 0
        }
        return true
    }

    /// Submit vertices for a specific row (row-based update, same as main window).
    /// Writes to the write set during a flush bracket; uses COW detach for buffer safety.
    /// When flags contains ZONVIE_VERT_UPDATE_CURSOR (2), vertices are stored in a
    /// dedicated cursor buffer that is NOT part of the row buffer system and is therefore
    /// immune to GPU scroll copy. This prevents cursor ghost artifacts.
    /// `outOfBracket: true` marks explicit MAIN-thread recovery callers outside
    /// any flush bracket. They must never consult `isInFlush` — it is core-thread
    /// state, and observing a
    /// concurrently open bracket would route the write into the SAME buffer
    /// set the core thread is mutating (unsynchronized Swift Array appends in
    /// ensureSurfaceRowStorage → memory corruption).
    func submitVerticesRowRaw(rowStart: Int, rowCount: Int, ptr: UnsafePointer<zonvie_vertex>?, count: Int, flags: UInt32 = 1, totalRows: Int, totalCols: Int, outOfBracket: Bool = false) {
        // A view registered after on_flush_begin did not join this flush's
        // bracket. Do not reinterpret its later core callbacks as an
        // out-of-bracket publication: those vertices sample this flush's back
        // atlas, while the view can only snapshot an older committed texture.
        // External-window creation has already scheduled a bracketed resend.
        if !outOfBracket && !isInFlush {
            return
        }

        // gridRows/gridCols are core-thread bracket state (commitFlush
        // publishes them into committedGridRows/Cols). Main-thread
        // out-of-bracket callers must not write them here — the direct-write
        // branch below updates them under tripleBufferLock when no bracket
        // is open (and the cursor replay passes totalRows=0, which would
        // clobber the real dims).
        if !outOfBracket {
            gridRows = UInt32(totalRows)
            gridCols = UInt32(totalCols)
        }

        // Cursor layer: store in dedicated cursor buffer (not in row buffers)
        let isCursorUpdate = (flags & 2) != 0  // ZONVIE_VERT_UPDATE_CURSOR
        if isCursorUpdate {
            tripleBufferLock.lock()
            lastKnownCursorRow = rowStart
            cursorDirty = true
            tripleBufferLock.unlock()
            if !outOfBracket && isInFlush {
                // Write set: never GPU-in-flight (pickFreeBufferSetIndex).
                if writeCursorVertices(into: bufferSets[writeSetIndex], ptr: ptr, count: count) {
                    tripleBufferLock.lock()
                    cursorStagingCount = -1 // this write supersedes any staged update
                    tripleBufferLock.unlock()
                } else {
                    flushFailed = true
                }
                // A cursor update IS flush content: without this, a
                // cursor-only flush (plain cursor movement — no row changed)
                // never rotates committedSetIndex, the cursor written above
                // stays orphaned in the write set, and draw() keeps showing
                // the stale committed cursor (invisible cursor trail during
                // j-repeat on external windows).
                flushHadContent = true
            } else {
                // Out-of-bracket: the committed set may still be read by a
                // GPU command buffer from a previous draw(); writing its
                // cursorVertexBuffer in place would race that read — the
                // exact hazard the per-set buffers exist to prevent. Write
                // directly only when provably idle (gpuInFlightCount == 0
                // while holding tripleBufferLock — draw() increments under
                // the same lock); otherwise stage CPU-side for draw() /
                // beginFlush() to apply at the next safe point.
                tripleBufferLock.lock()
                let csi = committedSetIndex
                if !bracketOpen && !rowCapacityProvisioning && gpuInFlightCount[csi] == 0 {
                    // No open bracket (a bracket's commit would rotate onto a
                    // write set copied BEFORE this write, discarding it) and
                    // the set is idle: safe to write directly.
                    if writeCursorVertices(into: bufferSets[csi], ptr: ptr, count: count) {
                        cursorStagingCount = -1
                        // Out-of-bracket publication has no commitFlush() to
                        // freeze the atlas alongside this committed set.
                        bufferSets[csi].atlasTextureSnapshot = mainTerminalView?.renderer.committedAtlasSnapshot()
                    } else {
                        cursorStaging.removeAll(keepingCapacity: true)
                        if count > 0, let validPtr = ptr {
                            cursorStaging.append(contentsOf: UnsafeBufferPointer(start: validPtr, count: count))
                        }
                        cursorStagingCount = count
                    }
                } else {
                    cursorStaging.removeAll(keepingCapacity: true)
                    if count > 0, let validPtr = ptr {
                        cursorStaging.append(contentsOf: UnsafeBufferPointer(start: validPtr, count: count))
                    }
                    cursorStagingCount = count
                }
                tripleBufferLock.unlock()
            }
            if count > 0, let validPtr = ptr {
                // Forward the cursor rect into the main renderer's
                // shader cursor state so cursor shaders running through
                // any HWND see the active (cmdline / popupmenu / float)
                // cursor instead of the main grid's stale cursor. Verts
                // arrive in this view's local NDC; translate to main
                // window drawable px using the same screen-space
                // parameters the shader uniforms use.
                forwardExternalCursorToMainShader(ptr: validPtr, count: count)
            } else {
                // The cursor left this window: stop republishing its rect on
                // window moves, or this view would keep overwriting whichever
                // surface now owns the cursor.
                lastForwardedCursorNdc = nil
            }
            return
        }

        // Normal row update (ZONVIE_VERT_UPDATE_MAIN)

        if rowCount == 0 {
            guard !outOfBracket,
                  count == 0,
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

        guard requestRowHistoryCapacity(rowCount: totalRows) else {
            flushFailed = true
            return
        }

        if !outOfBracket && isInFlush {
            // In-bracket (core thread): write set is never GPU-in-flight.
            let sourceSet = bufferSets[flushSourceSetIndex]
            let structural = !sourceSet.rowState.usingRowBuffers
                || totalRows != sourceSet.knownTotalRows
                || totalCols != sourceSet.knownTotalCols
            // Allocate synchronously (was gated behind requirePreparedRowCapacity
            // + allowAllocation: false), mirroring submitVerticesRowRaw in
            // MetalTerminalRenderer: the async pre-provisioning detour does not
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
            // mirrors MetalTerminalRenderer.markDirtyRows).
            tripleBufferLock.lock()
            for r in rowStart..<max(rowStart, rowStart + rowCount) {
                pendingDirtyRows.insert(r)
                flushDirtyRows.insert(r)
            }
            tripleBufferLock.unlock()
            flushHadContent = true
            return
        }

        // Out-of-bracket / non-flush path. Two hazards force staging:
        // (a) Row buffers are COW-shared across buffer sets, so an in-place
        //     write into the committed set can alias a buffer an older
        //     GPU-in-flight set still reads (submitSurfaceRowVertices only
        //     consults the alias guard when allocating a NEW buffer).
        // (b) An OPEN flush bracket already COW-copied the committed set;
        //     its commit rotates onto that pre-write copy, silently
        //     discarding a direct committed write (and the unlocked copy in
        //     beginFlush would race it).
        // Write directly only when no bracket is open AND all sets are idle,
        // while holding tripleBufferLock; otherwise stage for draw() /
        // beginFlush() to apply at the next safe point.
        tripleBufferLock.lock()
        let csi = committedSetIndex
        let allIdle = gpuInFlightCount[0] == 0 && gpuInFlightCount[1] == 0 && gpuInFlightCount[2] == 0
        var stagedForRetry = false
        if !bracketOpen && !rowCapacityProvisioning && allIdle {
            // Locked variant: tripleBufferLock is held (NSLock is
            // non-recursive) — and with all sets idle there are no in-flight
            // aliases anyway.
            let target = bufferSets[csi]
            let structural = !target.rowState.usingRowBuffers
                || totalRows != target.knownTotalRows
                || totalCols != target.knownTotalCols
            let submitted = submitSurfaceRowVertices(
                target: target,
                sourceSet: nil,
                device: mtlDevice,
                rowStart: rowStart,
                ptr: UnsafeRawPointer(ptr),
                count: count,
                maxRowBuffers: maxRowBuffers,
                totalRows: totalRows,
                totalCols: totalCols,
                allowAllocation: false,
                inflightRowBuffers: { self.inflightRowBuffersLocked(atSlot: $0) }
            )
            if submitted {
                for r in rowStart..<max(rowStart, rowStart + rowCount) {
                    pendingDirtyRows.insert(r)
                }
                // Track grid dims here (no bracket open, so no core-thread
                // writer can race this) instead of the unconditional top-of-
                // function write, which raced core-thread bracket state.
                gridRows = UInt32(totalRows)
                gridCols = UInt32(totalCols)
                committedGridRows = UInt32(totalRows)
                committedGridCols = UInt32(totalCols)
                // Match commitFlush's vertex/atlas publication contract for
                // deferred window creation, which replays rows outside a core
                // flush and may receive no later redraw batch.
                bufferSets[csi].atlasTextureSnapshot = mainTerminalView?.renderer.committedAtlasSnapshot()
                // Publish: without a revision bump the next draw computes
                // hasNewCommit=false and its early-exit path would consume and
                // discard the dirty marks above. Callers that bump again via
                // bumpRevisionAndRedraw are harmless (monotonic counter).
                commitRevision &+= 1
                recordCommittedRowMutationLocked(
                    committedIndex: csi,
                    rows: rowStart..<max(rowStart, rowStart + rowCount),
                    structural: structural
                )
            } else {
                var staged: [zonvie_vertex] = []
                if count > 0, let validPtr = ptr {
                    staged.append(contentsOf: UnsafeBufferPointer(start: validPtr, count: count))
                }
                rowStaging[rowStart] = staged
                rowStagingTotalRows = totalRows
                rowStagingTotalCols = totalCols
                stagedForRetry = true
            }
            tripleBufferLock.unlock()
        } else {
            var staged: [zonvie_vertex] = []
            if count > 0, let validPtr = ptr {
                staged.append(contentsOf: UnsafeBufferPointer(start: validPtr, count: count))
            }
            rowStaging[rowStart] = staged
            rowStagingTotalRows = totalRows
            rowStagingTotalCols = totalCols
            stagedForRetry = true
            tripleBufferLock.unlock()
        }
        if stagedForRetry {
            // Schedule a draw so the staging is applied once the sets go idle.
            DispatchQueue.main.async { [weak self] in
                self?.requestRedraw()
            }
        }
        // NOTE: no flushHadContent write here — that is core-thread bracket
        // state; out-of-bracket paths publish via commitRevision instead.
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
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: max(1, Int(drawableSize.width)),
            height: max(1, Int(drawableSize.height)),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        backBuffer = mtlDevice.makeTexture(descriptor: desc)
        backBufferSize = drawableSize
        // Drop ping-pong too — it must match the drawable.
        customShaderPong[0] = nil
        customShaderPong[1] = nil
        customShaderPongSize = .zero
        hasPresentedOnce = false
    }

    /// Translate this view's cursor verts (NDC, view-local) into the
    /// main window's drawable px and forward to the main renderer's
    /// shader cursor state. Without this, cursor shaders see the main
    /// grid's stale cursor while the user is editing the cmdline /
    /// popupmenu / a float window.
    private func forwardExternalCursorToMainShader(ptr: UnsafePointer<zonvie_vertex>, count: Int) {
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
        lastForwardedCursorNdc = (minX: minX, maxX: maxX, minY: minY, maxY: maxY)
        lastForwardedCursorColor = (c.0, c.1, c.2, c.3)
        republishCursorShaderState()
    }

    /// Project the last forwarded cursor NDC box into the main window's
    /// drawable pixels and publish it as the shader cursor rect.
    ///
    /// Split out from the forwarder because the projection depends on where
    /// the two windows are, not only on the verts: `screenSpaceParameters`
    /// measures this view's top-left relative to the main view's. Dragging
    /// either window changes that offset without producing a single new
    /// cursor vertex, which used to leave the cursor shader burning at the
    /// float's pre-move position until the next cursor update.
    private func republishCursorShaderState(reanchor: Bool = false) {
        guard let ndc = lastForwardedCursorNdc,
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
        let minX = ndc.minX
        let maxX = ndc.maxX
        let minY = ndc.minY
        let maxY = ndc.maxY
        // Convert NDC bounding box to main drawable pixels.
        let offX = Float(windowOffset.x)
        let offY = Float(windowOffset.y)
        // Map the cursor's NDC center through the SAME viewport the grid is
        // actually rendered into — MTLViewport(origin: viewportOriginPx*scale,
        // size: gridCols*cell x gridRows*cell) — NOT across the full drawable.
        // The viewport origin carries the ext-cmdline leading icon / padding
        // shift (set from layout.gridFrame.origin); omitting it, and scaling by
        // the full drawable instead of the grid viewport, lands iCurrentCursor
        // to the left of the real cursor on decorated surfaces. Keeping the
        // mapping identical to the render path preserves the Ghostty contract:
        // iCurrentCursor == the cursor's true on-screen rect.
        //
        // The cursor SIZE still comes from the main grid's cell metrics, not
        // the NDC span: cursor verts always cover NDC y = -1..+1, so stretching
        // them across a tall ext drawable (multi-row prompt / padding) would
        // render the cursor SDF at the drawable's height instead of one cell.
        let scale = Float(self.window?.backingScaleFactor ?? 2.0)
        let cellWpx = max(1.0, renderer.cellWidthPx.rounded(.up))
        let cellHpx = max(1.0, renderer.cellHeightPx.rounded(.up))
        let vpW = Float(gridCols) * cellWpx
        let vpH = Float(gridRows) * cellHpx
        let vpOriginX = Float(viewportOriginPx.x) * scale
        let vpOriginY = Float(viewportOriginPx.y) * scale
        let centerPxX = offX + vpOriginX + (minX + maxX + 2.0) * 0.25 * vpW
        let centerPxY = offY + vpOriginY + (2.0 - minY - maxY) * 0.25 * vpH
        let cellW = renderer.cellWidthPx
        let cellH = renderer.cellHeightPx
        let leftPx = centerPxX - cellW * 0.5
        let rightPx = centerPxX + cellW * 0.5
        let topPx = centerPxY - cellH * 0.5
        let botPx = centerPxY + cellH * 0.5
        // Ghostty's cursor shaders treat iCurrentCursor.y as the
        // BOTTOM edge of the cursor rect (rect spans y-h..y).
        // Tag the rect with this window's grid so the shader-cursor position
        // follows its smooth-scroll displacement the same way the main
        // window's does. Omitting it does not just leave this window
        // uncorrected: the cursor shader state is shared with the main view
        // (renderer is mainView.renderer), so a default of "no grid" would
        // switch the main window's correction off too.
        let rect = (leftPx, botPx, rightPx - leftPx, botPx - topPx)
        if reanchor {
            // Window move: no commit will come to publish a staged value, and
            // the cursor has not moved relative to its text.
            renderer.reanchorCursorShaderState(rect: rect, gridId: gridId)
        } else {
            renderer.setCursorShaderState(rect: rect, color: color, gridId: gridId)
        }
    }

    /// Allocate the two ping-pong textures used by multi-pass custom
    /// shader chains applied to this external view's backTex.
    private func ensureExternalCustomShaderPong(size: CGSize, pixelFormat: MTLPixelFormat) {
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
        customShaderPong[0] = mtlDevice.makeTexture(descriptor: desc)
        customShaderPong[1] = mtlDevice.makeTexture(descriptor: desc)
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
        scrollScratchTexture = mtlDevice.makeTexture(descriptor: desc)
        scrollScratchSize = drawableSize
    }

    private func encodePendingScrollCopy(
        commandBuffer: MTLCommandBuffer,
        backTexture: MTLTexture,
        drawableWidthPx: Int,
        rowHeightPx: Int,
        scroll: SurfaceRowScroll
    ) -> (
        clearTopPx: Int,
        clearBottomPx: Int,
        vacatedRowStart: Int,
        vacatedRowEnd: Int
    )? {
        let shift = abs(scroll.rowsDelta)
        // Clamp rowEnd to the back buffer height. The scroll callback may report
        // sg.rows (e.g. 45 with winbar) while the drawable is only viewport_rows
        // (e.g. 44) tall. Without clamping, the blit reads beyond the texture.
        let texMaxRows = rowHeightPx > 0 ? backTexture.height / rowHeightPx : 0
        let clampedRowEnd = min(scroll.rowEnd, texMaxRows)
        let regionHeightRows = clampedRowEnd - scroll.rowStart
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

        // Clamp copy height to texture bounds
        let maxCopyHeight = backTexture.height - max(srcY, dstY)
        let safeCopyHeight = min(copyHeightPx, maxCopyHeight)
        guard safeCopyHeight > 0 else {
            blit.endEncoding()
            return nil
        }

        let origin = MTLOrigin(x: 0, y: srcY, z: 0)
        let size = MTLSize(width: min(drawableWidthPx, backTexture.width), height: safeCopyHeight, depth: 1)
        blit.copy(from: backTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                  to: scratch, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        blit.copy(from: scratch, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                  to: backTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: dstY, z: 0))
        blit.endEncoding()

        let texHeightPx = backTexture.height
        if scroll.rowsDelta > 0 {
            let vacatedRowStart = clampedRowEnd - shift
            let vacatedRowEnd = clampedRowEnd
            return (
                min(vacatedRowStart * rowHeightPx, texHeightPx),
                min(vacatedRowEnd * rowHeightPx, texHeightPx),
                vacatedRowStart,
                vacatedRowEnd
            )
        } else {
            let vacatedRowStart = scroll.rowStart
            let vacatedRowEnd = min(scroll.rowStart + shift, clampedRowEnd)
            return (
                vacatedRowStart * rowHeightPx,
                min(vacatedRowEnd * rowHeightPx, texHeightPx),
                vacatedRowStart,
                vacatedRowEnd
            )
        }
    }

    private func ndcX(_ xPx: Float, drawableWidth: Float) -> Float {
        return (xPx / max(1.0, drawableWidth)) * 2.0 - 1.0
    }

    private func ndcY(_ yPx: Float, drawableHeight: Float) -> Float {
        return 1.0 - (yPx / max(1.0, drawableHeight)) * 2.0
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
        let r = Float((bgRGB >> 16) & 0xFF) / 255.0
        let g = Float((bgRGB >> 8) & 0xFF) / 255.0
        let b = Float(bgRGB & 0xFF) / 255.0
        let color = simd_float4(r, g, b, 1.0)
        let tl = Vertex(position: simd_float2(ndcX(0, drawableWidth: drawableWidth), ndcY(Float(top), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let tr = Vertex(position: simd_float2(ndcX(drawableWidth, drawableWidth: drawableWidth), ndcY(Float(top), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let bl = Vertex(position: simd_float2(ndcX(0, drawableWidth: drawableWidth), ndcY(Float(bottom), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
        let br = Vertex(position: simd_float2(ndcX(drawableWidth, drawableWidth: drawableWidth), ndcY(Float(bottom), drawableHeight: drawableHeight)),
                        texCoord: simd_float2(-1, -1), color: color, grid_id: 1, deco_flags: 0, deco_phase: 0)
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

    func draw(in view: MTKView) {
        autoreleasepool {
            var finishedRedraw = false
            defer {
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
            // It stayed hidden until a custom shader started animating.
            // Before that, an idle external window parked its draw loop and
            // never reached this line; the animation exception below makes
            // it attempt a frame every vsync even with nothing to show,
            // which is exactly when being invisible starts to cost a
            // second. Re-armed by the occlusion observer in
            // viewDidMoveToWindow, and by commitFlush on any new content.
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
            // MetalTerminalRenderer.draw() uses the same pattern.
            if inflightSemaphore.wait(timeout: .now()) != .success {
                // GPU still processing previous frame. Skip this draw but
                // schedule a retry so the frame is not permanently lost.
                redrawScheduler.didDrawFrame()
                finishedRedraw = true
                DispatchQueue.main.async { [weak self] in
                    self?.requestRedraw()
                }
                return
            }

            // --- Snapshot committed state under lock (same pattern as MetalTerminalRenderer) ---
            let csi: Int
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
            // (MetalTerminalRenderer already snapshots it under its lock.)
            let retainedSnapshot: [RetainedScrollRow]
            tripleBufferLock.lock()
            if rowCapacityProvisioning || rowCapacityRequiredRows > 0 || rowCapacityHardFailure {
                let terminal = rowCapacityHardFailure
                tripleBufferLock.unlock()
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
            // Set when the staged replay below raises rowCapacityRequiredRows, so
            // provisioning can be driven after tripleBufferLock is released.
            var recordedRowCapacityShortfall = false
            // Apply staged out-of-bracket ROW updates once ALL sets are idle
            // (row buffers are COW-shared across sets, so csi-idle alone is
            // not sufficient — see rowStaging doc comment) AND no bracket is
            // open (an open bracket's commit would rotate onto a write set
            // copied before this apply, discarding it). Must happen BEFORE
            // the commitRevision snapshot below AND bump the revision:
            // otherwise this draw computes hasNewCommit=false, the
            // early-exit path consumes-and-discards the dirty marks inserted
            // here, and the staged rows never reach the screen.
            if !rowStaging.isEmpty, !bracketOpen,
               gpuInFlightCount[0] == 0, gpuInFlightCount[1] == 0, gpuInFlightCount[2] == 0 {
                var appliedRows: [Int] = []
                appliedRows.reserveCapacity(rowStaging.count)
                let committed = bufferSets[csi]
                let structural = !committed.rowState.usingRowBuffers
                    || rowStagingTotalRows != committed.knownTotalRows
                    || rowStagingTotalCols != committed.knownTotalCols
                for (row, verts) in rowStaging {
                    var submitted = false
                    verts.withUnsafeBufferPointer { stagedBuf in
                        // Locked variant: this section holds tripleBufferLock.
                        submitted = submitSurfaceRowVertices(
                            target: bufferSets[csi],
                            sourceSet: nil,
                            device: mtlDevice,
                            rowStart: row,
                            ptr: stagedBuf.baseAddress.map(UnsafeRawPointer.init),
                            count: verts.count,
                            maxRowBuffers: maxRowBuffers,
                            totalRows: rowStagingTotalRows,
                            totalCols: rowStagingTotalCols,
                            allowAllocation: false,
                            inflightRowBuffers: { self.inflightRowBuffersLocked(atSlot: $0) }
                        )
                    }
                    if submitted {
                        pendingDirtyRows.insert(row)
                        appliedRows.append(row)
                    } else {
                        // Record the requirement, or the ledger stays at zero,
                        // provisionPendingRowCapacity short-circuits without
                        // allocating, and this replay fails identically on every
                        // subsequent draw while stagingPending keeps re-arming
                        // requestRedraw.
                        //
                        // Recorded inline rather than through
                        // requirePreparedRowCapacity for two reasons: the replay
                        // targets bufferSets[csi], which is neither the write set
                        // nor the flush source set that helper maps through, so it
                        // would name a different physical slot; and it latches
                        // flushFailed, which on_flush_end escalates into an
                        // app-wide abort_flush — wrong for a draw-time shortfall
                        // on one view, outside any bracket.
                        let capacityRow = surfacePhysicalCapacityRow(
                            logicalRow: row,
                            logicalToSlot: bufferSets[csi].rowLogicalToSlot
                        )
                        if capacityRow >= 0, capacityRow < maxRowBuffers,
                           rowStagingTotalRows >= 0, rowStagingTotalRows <= maxRowBuffers,
                           surfaceSafeNeededBytes(vertexCount: max(0, verts.count)) != nil {
                            rowCapacityRequiredRows = max(
                                max(rowCapacityRequiredRows, rowStagingTotalRows),
                                capacityRow + 1
                            )
                            rowCapacityRequiredVertexCounts[capacityRow] = max(
                                rowCapacityRequiredVertexCounts[capacityRow],
                                max(0, verts.count)
                            )
                            // A raised ledger gates the top of draw(), so it needs
                            // a driver: provisionPendingRowCapacity runs only from
                            // the flush-retry queue, and nothing on this path
                            // schedules one. Without it the view would stop
                            // presenting and spin the display link instead.
                            recordedRowCapacityShortfall = true
                        }
                    }
                }
                for row in appliedRows {
                    rowStaging.removeValue(forKey: row)
                }
                if !appliedRows.isEmpty {
                    gridRows = UInt32(rowStagingTotalRows)
                    gridCols = UInt32(rowStagingTotalCols)
                    committedGridRows = UInt32(rowStagingTotalRows)
                    committedGridCols = UInt32(rowStagingTotalCols)
                    bufferSets[csi].atlasTextureSnapshot = mainTerminalView?.renderer.committedAtlasSnapshot()
                    commitRevision &+= 1
                    recordCommittedRowMutationLocked(
                        committedIndex: csi,
                        rows: appliedRows,
                        structural: structural
                    )
                }
            }
            currentCommitRevision = commitRevision
            snappedGridRows = committedGridRows
            snappedGridCols = committedGridCols
            // Apply a staged out-of-bracket cursor update (see
            // submitVerticesRowRaw) now if this set is idle and no bracket
            // is open — must happen BEFORE the gpuInFlightCount increment
            // below marks it busy. Re-arm cursorDirty: an EARLIER draw may
            // already have consumed it while the staging could not yet be
            // applied (set busy), and without it the retry draw that finally
            // applies the staging would take the idle early-exit and never
            // present the freshly written cursor.
            if cursorStagingCount >= 0 && !bracketOpen && gpuInFlightCount[csi] == 0 {
                let stagedCount = cursorStagingCount
                var submitted = false
                cursorStaging.withUnsafeBufferPointer { stagedBuf in
                    submitted = writeCursorVertices(into: bufferSets[csi], ptr: stagedBuf.baseAddress, count: stagedCount)
                }
                if submitted {
                    cursorStagingCount = -1
                    cursorDirty = true
                    bufferSets[csi].atlasTextureSnapshot = mainTerminalView?.renderer.committedAtlasSnapshot()
                }
            }
            committedFontIsCurrent = fontResetState.isCurrent(
                committedGeneration: bufferSets[csi].fontGeneration
            )
            gpuInFlightCount[csi] += 1  // Prevent beginFlush from reusing this set
            // Snapshot and consume pending state
            pendingScroll = pendingScrollAccum ?? bufferSets[csi].pendingScroll
            pendingScrollAccum = nil
            swap(&submittedDirtyRows, &submittedDirtyRowsScratch)
            submittedDirtyRows.removeAll(keepingCapacity: true)
            submittedDirtyRows.append(contentsOf: pendingDirtyRows)
            pendingDirtyRows.removeAll(keepingCapacity: true)
            let stagingPending = cursorStagingCount >= 0 || !rowStaging.isEmpty
            cursorDirtySnapshot = cursorDirty
            cursorDirty = false
            lastKnownCursorRowSnapshot = lastKnownCursorRow
            cursorBlinkStateSnapshot = cursorBlinkStateStorage
            tripleBufferLock.unlock()
            defer {
                submittedDirtyRows.removeAll(keepingCapacity: true)
                swap(&submittedDirtyRows, &submittedDirtyRowsScratch)
            }

            // Staged cursor update couldn't be applied above (set still GPU
            // in-flight): schedule another draw so an idle view doesn't keep
            // showing the stale cursor (same retry idiom as the semaphore
            // skip at the top of this method).
            if stagingPending {
                DispatchQueue.main.async { [weak self] in
                    self?.requestRedraw()
                }
            }

            // Drive the provisioner for the shortfall recorded above. Done after
            // the lock is released: scheduleFlushRetry runs the worker on its own
            // queue, which re-enters this view through provisionPendingRowCapacity
            // and takes tripleBufferLock itself.
            if recordedRowCapacityShortfall {
                mainTerminalView?.core?.scheduleFlushRetry()
            }

            // Snapshot the previous-frame gate state BEFORE draw() overwrites
            // it (lastRenderedBlinkState at the blink-detection line,
            // lastDrawnRevision right after hasNewCommit is computed), so the
            // bail helper below can roll both back — mirrors the
            // prevDrawnRevision/prevRenderedBlinkState rollback in
            // MetalTerminalRenderer.bailWithoutSubmit.
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
                pendingDirtyRows.formUnion(submittedDirtyRows)
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
            defer {
                if !gpuSubmitted {
                    inflightSemaphore.signal()
                    tripleBufferLock.lock()
                    completeSurfaceGpuReadLocked(csi)
                    tripleBufferLock.unlock()
                }
            }

            let committed = bufferSets[csi]
            let rowMode = committed.rowState.usingRowBuffers
            // Use committed grid dimensions (snapped at commitFlush) to guarantee
            // viewport matches the NDC coordinates baked into committed vertices.
            // Same approach as MetalTerminalRenderer's committedDrawableW/H.
            // Use raw committed grid dimensions without clamping to drawable.
            // The core bakes NDC with grid_h = viewport_rows * cellH, so the
            // Metal viewport height MUST match viewport_rows exactly. If
            // viewport_rows exceeds drawable rows (e.g. sg.rows=45 with winbar
            // but window fits 44), Metal clips to the render target bounds
            // automatically — the NDC mapping stays correct for visible rows.
            let snapGridRows = snappedGridRows > 0 ? snappedGridRows : gridRows
            let snapGridCols = snappedGridCols > 0 ? snappedGridCols : gridCols
            let vertexCount: Int
            let vertexBufferSnapshot: MTLBuffer?

            if !rowMode {
                lock.lock()
                if let pending = pendingVertexCount {
                    currentVertexCount = pending
                    pendingVertexCount = nil
                }
                lock.unlock()
                vertexCount = currentVertexCount
                vertexBufferSnapshot = vertexBuffer
            } else {
                vertexCount = 0
                vertexBufferSnapshot = nil
            }

            if !rowMode && vertexCount <= 0 {
                return
            }
            if rowMode && committed.rowState.buffers.isEmpty {
                return
            }

            // --- Blink state change detection ---
            let blinkStateChanged = cursorBlinkStateSnapshot != lastRenderedBlinkState
            lastRenderedBlinkState = cursorBlinkStateSnapshot

            let drawableSizeChanged = backBufferSize != view.drawableSize && backBuffer != nil
            let hasNewCommit = currentCommitRevision != lastDrawnRevision
            lastDrawnRevision = currentCommitRevision
            let hasDirtyContent = hasNewCommit && !submittedDirtyRows.isEmpty
            let hasPendingScroll = hasNewCommit && pendingScroll != nil

            // Service shared scroll state before updating the ext-view shader.
            // External windows reuse the main view's scroll offset storage but
            // do not benefit from the main view's onPreDraw hook each frame.
            mainTerminalView?.serviceSharedScrollStateForExternalView()

            // Update scroll offset before early exit check so smooth scroll
            // (trackpad sub-cell offset changes) can trigger a redraw even
            // when no new flush has occurred.
            let hasScrollOffset = updateScrollShaderOffset()
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

            // Animation exception mirrors MetalTerminalRenderer: when a
            // loaded custom shader references iTime / iFrame / etc., we
            // must proceed every frame and keep this view's draw loop
            // active, even with no Neovim-side changes. Without this,
            // popupmenu / messages / cmdline / ext-window background stays
            // frozen while the main window animates.
            let shaderAnimates = mainTerminalView?.renderer.anyCustomShaderNeedsAnimation ?? false
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

            if rowMode && hasPresentedOnce && !blinkStateChanged && !hasDirtyContent && !hasPendingScroll && !drawableSizeChanged && !scrollOffsetChanged && !hasCursorUpdate && !smoothScrolling && !shaderAnimates {
                ZonvieCore.appLog("[ext_draw_early_exit] gridId=\(gridId) idle")
                // If a visual commit occurred recently, a timing race likely caused
                // this idle frame. Don't count toward deactivation.
                if hadRecentCommit(withinNs: 50_000_000) {
                    activeDrawIdleFrames = 0
                    return
                }
                activeDrawIdleFrames += 1
                if activeDrawIdleFrames > activeDrawIdleThreshold {
                    deactivateDrawLoop()
                }
                return
            }
            activeDrawIdleFrames = 0
            if gridId == 4 {
                ZonvieCore.appLog("[ext_draw_why] gridId=4 rowMode=\(rowMode) presented=\(hasPresentedOnce) blink=\(blinkStateChanged) dirty=\(hasDirtyContent) scroll=\(hasPendingScroll) sizeChg=\(drawableSizeChanged) scrollOff=\(scrollOffsetChanged) cursor=\(hasCursorUpdate) hasNewCommit=\(hasNewCommit)")
            }

            // Blink-only frame: only blink state changed, no content updates
            let isBlinkOnlyFrame = blinkStateChanged
                && !hasDirtyContent
                && !hasPendingScroll
                && !drawableSizeChanged
                && !scrollOffsetChanged
                && !smoothScrolling
                && hasPresentedOnce

            // Compute viewport metrics early (needed for both row and non-row modes)
            // Cell dimensions — integer-rounded, same formula as MetalTerminalRenderer.
            let cw = Float(mainTerminalView?.renderer.cellWidthPx ?? 0)
            let ch = Float(mainTerminalView?.renderer.cellHeightPx ?? 0)
            let cellWi = max(1, UInt32(cw.rounded(.up)))
            let cellHi = max(1, UInt32(ch.rounded(.up)))
            // Viewport: grid-rows based (NOT drawable-based).
            // External grids have viewport_rows from external_grid_target_sizes
            // which may differ from drawableH / cellH. The core bakes NDC with
            // grid_h = viewport_rows * cellH, so vpHeight must match that.
            let vpWidth = Double(snapGridCols) * Double(cellWi)
            let vpHeight = Double(snapGridRows) * Double(cellHi)
            let scale = view.window?.backingScaleFactor ?? 2.0
            let vpOriginX = Double(viewportOriginPx.x) * Double(scale)
            let vpOriginY = Double(viewportOriginPx.y) * Double(scale)
            let viewportMetrics = SurfaceViewportMetrics(
                viewportWidth: vpWidth,
                viewportHeight: vpHeight,
                drawableSize: view.drawableSize,
                originX: vpOriginX,
                originY: vpOriginY
            )

            // GPU scroll copy eligibility:
            // - must be row mode with a pending scroll from the current commit
            // - must have presented at least once (back buffer has valid content)
            // - not during smooth scrolling / resize / glow rendering
            // - not for decorated surfaces (viewport origin offset complicates reuse)
            // Float overlay detection is handled at the core dispatch level
            // (flush.zig skips on_grid_row_scroll when float windows are anchored to the grid).
            // Check glow early — it disables partial-redraw optimizations to
            // prevent additive bloom composite from accumulating brightness.
            let glowEnabled = mainTerminalView?.core?.isGlowEnabled() ?? false

            // Use 2-pass rendering when blur is enabled and pipelines are available.
            let use2Pass = blurEnabled && backgroundPipeline != nil && glyphPipeline != nil

            let useGpuScrollCopy = rowMode
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
            let rowTranslationDenom_px = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)

            func resolvedRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow >= 0, logicalRow < safeRowCount else { return nil }
                guard logicalRow < committed.rowLogicalToSlot.count else { return nil }
                let slot = committed.rowLogicalToSlot[logicalRow]
                guard slot >= 0, slot < committed.rowState.counts.count else { return nil }
                let vc = committed.rowState.counts[slot]
                guard vc > 0, slot < committed.rowState.buffers.count,
                      let vb = committed.rowState.buffers[slot] else { return nil }
                let sourceRow = slot < committed.rowSlotSourceRows.count ? committed.rowSlotSourceRows[slot] : logicalRow
                let translationY = Float(sourceRow - logicalRow) * Float(cellHi) / max(1.0, rowTranslationDenom_px) * 2.0
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
            func resolvedSmoothRowState(_ logicalRow: Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
                guard logicalRow >= retainedRowBase else { return resolvedRowState(logicalRow) }
                let i = logicalRow - retainedRowBase
                guard i < retainedRows.count else { return nil }
                let r = retainedRows[i]
                guard r.cellHeightPx == Float(cellHi) else { return nil }
                // Same relation resolvedRowState uses: the vertices live at
                // sourceRow and have to appear at targetRow.
                let translationY = Float(r.sourceRow - r.targetRow) * Float(cellHi) / max(1.0, rowTranslationDenom_px) * 2.0
                return (r.count, r.buffer, translationY)
            }

            // Blink fast path gate — match MetalTerminalRenderer: requires blurEnabled
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
            // beginAtlasExternalRead's doc comment for why splitting these
            // into separate registration/snapshot/wait-encode calls leaves
            // a gap a writer's blit can land in. Must happen before any
            // encoder that samples the atlas is created (encodeWaitForEvent
            // cannot be issued while an encoder is open). Strong reference,
            // captured once here and reused by both commit paths'
            // completion handlers below via `atlasReadRenderer` (NOT
            // `self?.mainTerminalView?.renderer`): a [weak self] capture
            // would silently skip endAtlasExternalRead() if this view is
            // deallocated before the GPU completion fires, leaking the
            // matching enter() forever and wedging GlyphAtlas's
            // reader-admission gate (every future beginAtlasWrite() would
            // time out waiting for a read that will never leave).
            let atlasReadRenderer = mainTerminalView?.renderer
            // Bound with `guard let` rather than a plain guard so the ten
            // downstream `if let tex = atlasTex` / `atlasTex != nil` gates
            // become compile errors rather than dead conditionals. Those gates
            // encode the begin/end pairing contract -- nil means no read was
            // registered, so calling endAtlasExternalRead() anyway would
            // over-release the DispatchGroup. Keeping the binding non-optional
            // makes the compiler enforce what the comments used to.
            guard let atlasTex = atlasReadRenderer?.beginAtlasExternalRead(commandBuffer: cmd, snapshot: { committed.atlasTextureSnapshot }) ?? nil else {
                // A pending writer intentionally rejects new reader admission
                // until already-in-flight readers drain. Commit the otherwise
                // empty command buffer for prompt driver resource release, then
                // retain this frame's dirty state for the writer retry.
                cmd.commit()
                bailWithoutSubmit("atlas reader admission deferred")
                return
            }

            // --- GPU scroll blit (shift pixels in back buffer) ---
            // dirtyRows is only populated when GPU scroll copy is active.
            // Without scroll copy, the back buffer doesn't have pixel-shifted
            // content, so partial row updates would leave stale rows at wrong
            // positions. In that case dirtyRows stays empty and the full-redraw
            // fallback branch draws all rows.
            var scrollClearBand: (clearTopPx: Int, clearBottomPx: Int)? = nil
            var dirtyRows: [Int] = []
            swap(&dirtyRows, &dirtyRowsScratch)
            dirtyRows.removeAll(keepingCapacity: true)
            if useGpuScrollCopy {
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
                    dirtyRows.append(contentsOf: scrollCopy.vacatedRowStart..<scrollCopy.vacatedRowEnd)
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
                    let texMaxRows = cellHi > 0 ? Int(backTex.height) / Int(cellHi) : 0
                    let clampedRowEnd = min(scroll.rowEnd, texMaxRows)
                    if clampedRowEnd > scroll.rowStart {
                        // Keep expansion linear in the scroll-region height;
                        // the combined rows are canonicalized below.
                        dirtyRows.append(contentsOf: scroll.rowStart..<clampedRowEnd)
                    }
                }
            }
            if useGpuScrollCopy {
                surfaceSortAndDeduplicateRows(&dirtyRows)
            }

            // --- Render into back buffer ---
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = backTex
            rpd.colorAttachments[0].storeAction = .store

            // loadAction logic — match MetalTerminalRenderer, plus cursor-only preservation.
            // MetalTerminalRenderer marks cursor rows in pendingDirtyRows via markDirtyRect,
            // so hasAnyDirtyInRowMode is true during cursor-only frames. ExternalGridView
            // uses a dedicated cursor buffer instead, so dirtyRows may be empty. In that
            // case, preserve the back buffer to avoid clearing valid content.
            let hasAnyDirtyInRowMode = rowMode && !dirtyRows.isEmpty
            let cursorOnlyFrame = (hasCursorUpdate || isBlinkOnlyFrame) && dirtyRows.isEmpty && !hasNewCommit
            // Decorated surfaces (ext-cmdline) always clear: their viewport origin offset
            // means scissor rects for partial redraw don't align correctly.
            let shouldReusePreviousContents = committedFontIsCurrent
                && !isDecoratedSurface
                && !glowEnabled
                && (canBlinkFastPath || useGpuScrollCopy || cursorOnlyFrame || (!smoothScrolling && hasAnyDirtyInRowMode))
            rpd.colorAttachments[0].loadAction = resolveSurfaceColorLoadAction(
                blurEnabled: blurEnabled,
                hasPresentedOnce: hasPresentedOnce,
                drawableSizeChanged: drawableSizeChanged,
                shouldReusePreviousContents: shouldReusePreviousContents,
                forceReusePreviousContents: committedFontIsCurrent
                    && !isDecoratedSurface
                    && !glowEnabled
                    && (canBlinkFastPath || useGpuScrollCopy)
            )
            rpd.colorAttachments[0].clearColor = gridClearColor

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                // Encoder creation failed (rare). Commit the empty cmd anyway so
                // the IOAccelerator region attached to it is reclaimed; otherwise
                // an uncommitted MTLCommandBuffer leaks GPU memory permanently.
                // The atlas texture is never sampled on this path, so the read
                // registered above (if any) can be released immediately rather
                // than waiting for this now-empty command buffer's completion.
                atlasReadRenderer?.endAtlasExternalRead()
                hasPresentedOnce = false
                let sem = inflightSemaphore
                let tbLock = tripleBufferLock
                cmd.addCompletedHandler { [weak self] _ in
                    tbLock.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    tbLock.unlock()
                    sem.signal()
                }
                cmd.commit()
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

            // Bind scroll offset data via shared helper (no GPU/CPU race)
            let scrollOffsetSnapshot: MetalTerminalRenderer.ScrollOffset? = {
                lock.lock()
                defer { lock.unlock() }
                if scrollOffsetActive { return scrollOffsetData }
                return nil
            }()
            bindSingleSurfaceScrollOffset(encoder: enc, offset: scrollOffsetSnapshot)

            // Bind fragment-side state (drawable size, background alpha, cursor blink)
            bindSurfaceFragmentState(
                encoder: enc,
                viewportMetrics: viewportMetrics,
                backgroundAlphaBuffer: backgroundAlphaBuffer,
                cursorBlinkBuffer: cursorBlinkBuffer,
                cursorBlinkVisible: cursorBlinkStateSnapshot
            )

            var zeroRowTranslation: Float = 0
            enc.setVertexBytes(&zeroRowTranslation, length: MemoryLayout<Float>.size, index: 3)

            // --- Row-mode rendering branches — match MetalTerminalRenderer structure ---
            if rowMode {
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

                // Match the main surface: partial non-blur passes load the
                // previous back texture, so a zero-vertex dirty row needs an
                // explicit background overwrite or stale glyphs remain. The
                // fragment backgroundAlpha is 1.0 without blur, including
                // decorated grids' viewport (their padding remains governed
                // by the transparent render-pass clear outside the viewport).
                func clearEmptyDirtyRowsNonBlur(_ rows: [Int]) {
                    enc.setRenderPipelineState(pipeline)
                    let width = Float(vpWidth > 0 ? vpWidth : Double(view.drawableSize.width))
                    let height = Float(vpHeight > 0 ? vpHeight : Double(view.drawableSize.height))
                    let bgRGB = extractRGBFromClearColor(gridClearColor)
                    for row in rows where resolvedRowState(row) == nil {
                        let topPx = row * cellH
                        drawBackgroundClearBand(
                            enc,
                            clearBand: (clearTopPx: topPx, clearBottomPx: topPx + cellH),
                            drawableWidth: width,
                            drawableHeight: height,
                            bgRGB: bgRGB
                        )
                    }
                }

                if use2Pass {
                    // 2-pass rendering (blur enabled)
                    if canBlinkFastPath {
                        let cursorRow = lastKnownCursorRowSnapshot
                        let resolved = resolvedRowState(cursorRow)!

                        if let scissor = makeRowScissorRect(
                            row: cursorRow,
                            cellHeight_px: Int(cellHi),
                            drawableWidth_px: drawableW,
                            renderTargetWidth_px: backTex.width,
                            renderTargetHeight_px: backTex.height
                        ) {
                            enc.setScissorRect(scissor)
                            // Pass 1: Background (overwrite blending — erases old cursor)
                            enc.setRenderPipelineState(backgroundPipeline!)
                            var rowTranslation = resolved.translationY
                            enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                            enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)

                            // Pass 2: Glyph (alpha blending — redraws text/decorations)
                            enc.setRenderPipelineState(glyphPipeline!)
                            enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                            enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
                        }
                    } else if useGpuScrollCopy {
                        // The back texture is loaded after the pixel shift, so all
                        // clears must overwrite it. The regular blur pipeline uses
                        // alpha blending and would leave stale glyph pixels behind.
                        enc.setRenderPipelineState(backgroundPipeline!)
                        let scrollDrawableW = Float(vpWidth > 0 ? vpWidth : view.drawableSize.width)
                        let scrollDrawableH = Float(vpHeight > 0 ? vpHeight : view.drawableSize.height)
                        let bgRGB = extractRGBFromClearColor(gridClearColor)
                        if let clearBand = scrollClearBand {
                            drawBackgroundClearBand(
                                enc,
                                clearBand: clearBand,
                                drawableWidth: scrollDrawableW,
                                drawableHeight: scrollDrawableH,
                                bgRGB: bgRGB
                            )
                        }
                        // encodeSurfaceRowDraws skips rows without vertices. Those
                        // rows still need an overwrite when this pass uses .load,
                        // including dirty rows outside the vacated scroll band.
                        for row in dirtyRows where resolvedRowState(row) == nil {
                            let topPx = row * cellH
                            drawBackgroundClearBand(
                                enc,
                                clearBand: (clearTopPx: topPx, clearBottomPx: topPx + cellH),
                                drawableWidth: scrollDrawableW,
                                drawableHeight: scrollDrawableH,
                                bgRGB: bgRGB
                            )
                        }
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
                            useTwoPass: true
                        )
                    } else {
                        // 2-pass full redraw (same as MetalTerminalRenderer),
                        // including the rows retained across a scroll step.
                        _ = encodeSurfaceRowDraws(
                            encoder: enc,
                            rows: smoothRowRange,
                            resolve: resolvedSmoothRowState,
                            pipeline: pipeline,
                            backgroundPipeline: backgroundPipeline,
                            glyphPipeline: glyphPipeline,
                            useTwoPass: true
                        )
                    }
                } else if smoothScrolling {
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
                } else if useGpuScrollCopy {
                    if let clearBand = scrollClearBand {
                        let bgRGB = extractRGBFromClearColor(gridClearColor)
                        drawBackgroundClearBand(
                            enc,
                            clearBand: clearBand,
                            drawableWidth: Float(vpWidth > 0 ? vpWidth : Double(view.drawableSize.width)),
                            drawableHeight: Float(vpHeight > 0 ? vpHeight : Double(view.drawableSize.height)),
                            bgRGB: bgRGB
                        )
                    }
                    clearEmptyDirtyRowsNonBlur(dirtyRows)
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
                        pipeline: pipeline,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else if !isDecoratedSurface && !glowEnabled && !dirtyRows.isEmpty && !drawableSizeChanged
                            && rpd.colorAttachments[0].loadAction == .load {
                    // Normal mode: scissor per dirty row. A resized backbuffer
                    // is cleared, so partial redraw would leave every clean row
                    // blank; decorated surfaces have the same constraint on
                    // every frame because their loadAction is always .clear.
                    clearEmptyDirtyRowsNonBlur(dirtyRows)
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
                        pipeline: pipeline,
                        backgroundPipeline: nil,
                        glyphPipeline: nil,
                        useTwoPass: false
                    )
                } else {
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
            } else {
                // Non-row-mode: shared helper handles 2-pass vs single-pass dispatch
                encodeSurfaceNonRowContent(
                    encoder: enc,
                    vertexBuffer: vertexBufferSnapshot,
                    vertexCount: vertexCount,
                    pipeline: pipeline,
                    backgroundPipeline: backgroundPipeline,
                    glyphPipeline: glyphPipeline,
                    useTwoPass: use2Pass
                )
            }

            // Cursor is NOT drawn into backbuffer — it is composited onto the
            // drawable after blit, so the persistent backbuffer stays cursor-free
            // and GPU scroll-region copies don't shift stale cursor pixels.

            enc.endEncoding()

            // --- Post-process bloom (neon glow) ---
            var glowPassSucceeded = !glowEnabled
            if glowEnabled,
               let renderer = mainTerminalView?.renderer,
               let extractPipe = renderer.glowExtractPipeline,
               let downPipe = renderer.kawaseDownPipeline,
               let upPipe = renderer.kawaseUpPipeline,
               let compositePipe = renderer.glowCompositePipeline,
               let copyVB = renderer.copyVertexBuffer,
               let bilinSamp = renderer.bilinearSampler
            {
                let vpSize = CGSize(width: viewportMetrics.viewportWidth, height: viewportMetrics.viewportHeight)
                let intensity = mainTerminalView?.core?.getGlowIntensity() ?? 0.8

                if glowTextures.ensure(device: mtlDevice, drawableSize: view.drawableSize, pixelFormat: view.colorPixelFormat),
                   glowTextures.ensureIntensityBuffer(device: mtlDevice) {
                    glowPassSucceeded = encodeSurfaceBloomPasses(
                    cmd: cmd,
                    backTex: backTex,
                    viewportSize: vpSize,
                    drawableSize: view.drawableSize,
                    viewportOrigin: CGPoint(x: vpOriginX, y: vpOriginY),
                    glowTextures: glowTextures,
                    extractPipeline: extractPipe,
                    kawaseDownPipeline: downPipe,
                    kawaseUpPipeline: upPipe,
                    compositePipeline: compositePipe,
                    copyVertexBuffer: copyVB,
                    bilinearSampler: bilinSamp,
                    intensity: intensity
                    ) { enc in
                    // Set up atlas and scroll offsets for extract pass
                    // NOTE: DrawableSize (fragment buffer 0) is already set by the shared helper
                    enc.setFragmentTexture(atlasTex, index: 0)
                    enc.setFragmentSamplerState(self.sampler!, index: 0)

                    bindSingleSurfaceScrollOffset(encoder: enc, offset: scrollOffsetSnapshot)
                    var zeroTranslation: Float = 0
                    enc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)

                    // Draw row vertices
                    if rowMode {
                        for row in 0..<safeRowCount {
                            guard let resolved = resolvedRowState(row) else { continue }
                            var rowTranslation = resolved.translationY
                            enc.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
                            enc.setVertexBuffer(resolved.vb, offset: 0, index: 0)
                            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
                        }
                    } else if vertexCount > 0, let vb = vertexBufferSnapshot {
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
                    }

                    // Cursor vertices for cursor glow
                    if committedFontIsCurrent,
                       cursorBlinkStateSnapshot,
                       committed.cursorVertexCount > 0,
                       let cvb = committed.cursorVertexBuffer {
                        var ct: Float = 0
                        enc.setVertexBytes(&ct, length: MemoryLayout<Float>.size, index: 3)
                        enc.setVertexBuffer(cvb, offset: 0, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: committed.cursorVertexCount)
                    }
                    }
                }
            }

            guard glowPassSucceeded else {
                let sem = inflightSemaphore
                let tbLock = tripleBufferLock
                cmd.addCompletedHandler { [weak self] _ in
                    tbLock.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    tbLock.unlock()
                    sem.signal()
                    atlasReadRenderer?.endAtlasExternalRead()
                }
                cmd.commit()
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
            let acquired = view.currentDrawable
            if ZonvieCore.appLogEnabled {
                let us = (CFAbsoluteTimeGetCurrent() - tAcquire) * 1_000_000
                ZonvieCore.appLogPerf("[perf] ext_acquire_drawable gridId=\(gridId) us=\(String(format: "%.1f", us)) got=\(acquired != nil)")
            }
            guard let drawable = acquired else {
                // Capture semaphore and lock directly so the signal fires even
                // if the view is deallocated before the GPU finishes.
                let sem = inflightSemaphore
                let tbLock = tripleBufferLock
                cmd.addCompletedHandler { [weak self] _ in
                    tbLock.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    tbLock.unlock()
                    sem.signal()
                    // Paired with beginAtlasExternalRead() above. Uses the
                    // strongly-captured atlasReadRenderer, not [weak self] —
                    // see its declaration comment for why. Gated on
                    // hadAtlasRead: when atlasTex was nil, no read was ever
                    // registered — calling endAtlasExternalRead() anyway
                    // would over-release the DispatchGroup.
                    atlasReadRenderer?.endAtlasExternalRead()
                }
                cmd.commit()
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
            // drawable, replacing the normal blit. Phase 2 applies a
            // single shader; multi-pass chaining is Phase 5's scope.
            var customShaderHandled = false
            if let renderer = mainTerminalView?.renderer,
               !renderer.customShaderPipelinesDecorated.isEmpty,
               renderer.customShaderPostProcess == .afterBloom,
               let copyVB = renderer.copyVertexBuffer,
               let bilinSamp = renderer.bilinearSampler
            {
                // Screen-space unification: use the MAIN window's
                // drawable as the shader's iResolution, and tell the
                // shader where this external view sits inside that
                // coordinate space so effects (stars, gradients,
                // spotlights) line up across all windows.
                let (screenRes, windowOffset) = screenSpaceParameters(
                    mainView: mainTerminalView,
                    selfView: self
                )
                // Hand over the displacement THIS frame is drawing with. The
                // shared value is the main view's, updated on its own draw
                // cadence, and this window routinely draws a frame ahead of
                // it — which put the cursor shader a frame of finger travel
                // away from the cursor.
                // Fold in the displacement THIS frame draws with before
                // reading the uniforms: the shared value follows the main
                // view's draw cadence, and this window routinely draws a frame
                // ahead of it.
                renderer.evaluateCursorShaderChange(scrollOffsetPx: cursorScrollOffsetPxForShader())
                let uniforms = renderer.makeCustomShaderUniforms(
                    screenResolution: screenRes,
                    windowOffset: windowOffset,
                    windowSize: view.drawableSize,
                    timing: shaderTiming
                )
                // Decorated surfaces use the OPAQUE variant (preserve_alpha
                // OFF): their backTex has alpha-0 padding / empty-input regions
                // where preserve_alpha would make the shader vanish.
                let pipelines = renderer.customShaderPipelinesDecorated
                if pipelines.count > 1 {
                    ensureExternalCustomShaderPong(
                        size: view.drawableSize,
                        pixelFormat: drawable.texture.pixelFormat
                    )
                }
                let pongsReady =
                    pipelines.count <= 1
                    || (customShaderPong[0] != nil && customShaderPong[1] != nil)
                if pongsReady {
                    var allPassesEncoded = true
                    for (i, pipeline) in pipelines.enumerated() {
                        let isLast = (i == pipelines.count - 1)
                        let inputTex: MTLTexture =
                            (i == 0) ? backTex : customShaderPong[(i - 1) % 2]!
                        let outputTex: MTLTexture =
                            isLast ? drawable.texture : customShaderPong[i % 2]!
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
            if !customShaderHandled, let blitEnc = cmd.makeBlitCommandEncoder() {
                let w = min(backTex.width, drawable.texture.width)
                let h = min(backTex.height, drawable.texture.height)
                blitEnc.copy(
                    from: backTex, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: w, height: h, depth: 1),
                    to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blitEnc.endEncoding()
                finalCopyEncoded = true
            }

            guard finalCopyEncoded else {
                // Back-buffer work is valid and must be submitted to release
                // its Metal resources, but the drawable was not populated.
                // Keep the consumed rows/revision pending for another draw.
                let sem = inflightSemaphore
                let tbLock = tripleBufferLock
                cmd.addCompletedHandler { [weak self] _ in
                    tbLock.lock()
                    self?.completeSurfaceGpuReadLocked(csi)
                    tbLock.unlock()
                    sem.signal()
                    atlasReadRenderer?.endAtlasExternalRead()
                }
                cmd.commit()
                gpuSubmitted = true
                hasPresentedOnce = false
                bailWithoutSubmit("final blit encoder creation failed", restoreScroll: false)
                return
            }

            // --- Cursor overlay: composited on drawable (not backbuffer) ---
            // Keeps persistent backbuffer cursor-free so GPU scroll copies
            // don't shift stale cursor pixels (same as MetalTerminalRenderer).
            if committedFontIsCurrent,
               cursorBlinkStateSnapshot,
               committed.cursorVertexCount > 0,
               let cursorBuf = committed.cursorVertexBuffer {
                let cursorRPD = MTLRenderPassDescriptor()
                cursorRPD.colorAttachments[0].texture = drawable.texture
                cursorRPD.colorAttachments[0].loadAction = .load
                cursorRPD.colorAttachments[0].storeAction = .store

                guard let cursorEnc = cmd.makeRenderCommandEncoder(descriptor: cursorRPD) else {
                    let sem = inflightSemaphore
                    let tbLock = tripleBufferLock
                    cmd.addCompletedHandler { [weak self] _ in
                        tbLock.lock()
                        self?.completeSurfaceGpuReadLocked(csi)
                        tbLock.unlock()
                        sem.signal()
                        atlasReadRenderer?.endAtlasExternalRead()
                    }
                    cmd.commit()
                    gpuSubmitted = true
                    hasPresentedOnce = false
                    // Main/back-buffer and scroll work is now submitted, so
                    // do not queue the pixel shift a second time. Restored rows,
                    // cursorDirty and revision state produce a complete retry.
                    bailWithoutSubmit("cursor encoder creation failed", restoreScroll: false)
                    return
                }
                viewportMetrics.applyViewport(to: cursorEnc)
                cursorEnc.setRenderPipelineState(pipeline)
                // Reuse the SAME atlasTex captured once above (from
                // committed.atlasTextureSnapshot) instead of fetching
                // fresh here — this cursor pass is still part of the
                // same draw call/generation as the main pass.
                cursorEnc.setFragmentTexture(atlasTex, index: 0)
                cursorEnc.setFragmentSamplerState(sampler, index: 0)

                bindSingleSurfaceScrollOffset(encoder: cursorEnc, offset: scrollOffsetSnapshot)
                bindSurfaceFragmentState(
                    encoder: cursorEnc,
                    viewportMetrics: viewportMetrics,
                    backgroundAlphaBuffer: backgroundAlphaBuffer,
                    cursorBlinkBuffer: cursorBlinkBuffer,
                    cursorBlinkVisible: true
                )
                var zeroTranslation: Float = 0
                cursorEnc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)
                cursorEnc.setVertexBuffer(cursorBuf, offset: 0, index: 0)
                cursorEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: committed.cursorVertexCount)
                cursorEnc.endEncoding()
            }

            cmd.present(drawable)
            // Capture semaphore and lock directly so the signal fires even
            // if the view is deallocated before the GPU finishes.
            let sem = inflightSemaphore
            let tbLock = tripleBufferLock
            cmd.addCompletedHandler { [weak self] completed in
                tbLock.lock()
                self?.completeSurfaceGpuReadLocked(csi)
                tbLock.unlock()
                sem.signal()
                // Paired with beginAtlasExternalRead() at atlas-bind time
                // above. Uses the strongly-captured atlasReadRenderer, not
                // [weak self] — see its declaration comment for why. Gated
                // on atlasTex != nil: when nil, no read was ever
                // registered — calling endAtlasExternalRead() anyway would
                // over-release the DispatchGroup.
                atlasReadRenderer?.endAtlasExternalRead()
                if completed.status != .completed {
                    DispatchQueue.main.async { [weak self] in
                        self?.hasPresentedOnce = false
                        self?.requestRedraw()
                    }
                }
            }
            cmd.commit()
            gpuSubmitted = true

            // Mark that we've presented at least once
            markScrollOffsetStatePresented()
            hasPresentedOnce = true
            redrawScheduler.didDrawFrame()
            finishedRedraw = true

            // Update scrollbar after rendering
            DispatchQueue.main.async { [weak self] in
                self?.updateScrollbarIfNeeded()
            }
        }
    }

    // MARK: - Post-Process Bloom (Neon Glow) — uses shared encodeSurfaceBloomPasses()

    // MARK: - Private

    private func ensureVertexBufferCapacity(_ count: Int, forceReplace: Bool = false) {
        let needed = count * MemoryLayout<Vertex>.stride
        if !forceReplace && needed <= vertexBufferCapacity { return }

        let newCap = max(needed, vertexBufferCapacity * 2, 4096)
        vertexBuffer = mtlDevice.makeBuffer(length: newCap, options: .storageModeShared)
        if vertexBuffer != nil {
            vertexBufferCapacity = newCap
        } else {
            // Do NOT record newCap as satisfied capacity for a nil buffer —
            // the next call would see needed <= vertexBufferCapacity and
            // skip retrying the allocation entirely, permanently believing
            // a nonexistent buffer covers this content.
            vertexBufferCapacity = 0
            flushFailed = true
        }
    }

    // MARK: - Smooth Scroll

    /// Update scroll offset shader uniform for visual sub-cell scrolling.
    /// Uses shared scroll offset info and computation from MetalTerminalRenderer.
    /// Returns true if a non-zero scroll offset is active.
    @discardableResult
    private func updateScrollShaderOffset() -> Bool {
        guard let main = mainTerminalView else { return false }

        let cellHeightPx = Float(main.renderer.cellHeightPx)
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
            let originScale = Float(self.window?.backingScaleFactor ?? 2.0)
            let vpOriginYPx = Float(viewportOriginPx.y) * originScale
            info.gridTopYNDC = 1.0 - vpOriginYPx * (2.0 / viewportHeight)

            // Use the grid-snapped viewport coordinate space, matching the
            // fragment shader's screen-space clipping for this surface (see
            // draw()'s vpHeight/vpOriginY computation).
            var scrollOffset = MetalTerminalRenderer.computeScrollOffset(
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
            return false  // No scroll offset
        }
    }

    private func scrollOffsetsEqual(
        _ lhs: MetalTerminalRenderer.ScrollOffset?,
        _ rhs: MetalTerminalRenderer.ScrollOffset?
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
        if !scrollOffsetActive {
            return false
        }
        return !scrollOffsetsEqual(scrollOffsetData, lastPresentedScrollOffsetData)
    }

    private func wasScrollOffsetActiveInLastPresentedFrame() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastPresentedScrollOffsetActive
    }

    private func markScrollOffsetStatePresented() {
        lock.lock()
        defer { lock.unlock() }

        lastPresentedScrollOffsetActive = scrollOffsetActive
        lastPresentedScrollOffsetData = scrollOffsetData
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

    private func sendMouseEvent(button: String, action: String, event: NSEvent) {
        guard let main = mainTerminalView, let core = main.core else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let cellWidthPx = CGFloat(main.renderer.cellWidthPx)
        let cellHeightPx = CGFloat(main.renderer.cellHeightPx)

        let location = convert(event.locationInWindow, from: nil)

        // Convert to cell coordinates (flip Y)
        let col = Int32(location.x * scale / cellWidthPx)
        let viewHeightPx = bounds.height * scale
        let row = Int32((viewHeightPx - location.y * scale) / cellHeightPx)

        // Build modifier string (same format as MetalTerminalView)
        let mods = event.modifierFlags
        var modStr = ""
        if mods.contains(.shift)   { modStr += "S" }
        if mods.contains(.control) { modStr += "C" }
        if mods.contains(.option)  { modStr += "A" }
        if mods.contains(.command) { modStr += "D" }

        ZonvieCore.appLog("[ExternalGridView mouseEvent] button=\(button) action=\(action) gridId=\(gridId) row=\(row) col=\(col)")

        // Use nvim_input_mouse API via core.sendMouseInput (includes grid_id for ext_multigrid)
        core.sendMouseInput(button: button, action: action, modifier: modStr, gridId: gridId, row: row, col: col)
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
        let optionIsMeta: Bool = {
            guard m.contains(.option) else { return false }
            let val = core.getOptionAsMeta()
            switch val {
            case 0: return true                       // both
            case 1: return false                      // none
            case 2: return m.rawValue & 0x20 != 0     // only_left
            case 3: return m.rawValue & 0x40 != 0     // only_right
            default: return true
            }
        }()
        let hasControlOrCommand = m.contains(.control) || m.contains(.command) || optionIsMeta

        // If IME is composing (has marked text), let IME handle all keys
        // except Escape which cancels composition.
        if hasMarkedText() {
            if event.keyCode == 0x35 {  // Escape: cancel composition
                unmarkText()
                inputContext?.discardMarkedText()
                return
            }
            // Let IME handle the key (Enter commits, arrows navigate, etc.)
            if let ctx = inputContext, ctx.handleEvent(event) {
                return
            }
            interpretKeyEvents([event])
            return
        }

        // No marked text: special keys or Ctrl/Cmd go directly to Neovim.
        let isSpecialKey = isSpecialKeyCode(event.keyCode)

        if hasControlOrCommand || isSpecialKey {
            // Use sendKeyEvent (same as MetalTerminalView) instead of sendInput
            var mods: UInt32 = 0
            if m.contains(.control) { mods |= UInt32(ZONVIE_MOD_CTRL) }
            if optionIsMeta          { mods |= UInt32(ZONVIE_MOD_ALT) }
            if m.contains(.shift)   { mods |= UInt32(ZONVIE_MOD_SHIFT) }
            if m.contains(.command) { mods |= UInt32(ZONVIE_MOD_SUPER) }

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
            return
        }

        // `:` <-> `;` swap (config-gated). Handle single keypresses here,
        // bypassing IME; paste flows through a separate path and is unaffected.
        if ZonvieConfig.shared.input.swapColonSemicolon, !hasMarkedText(),
           let ch = event.characters, let swapped = ZonvieConfig.swapColonSemicolon(ch)
        {
            core.sendInput(swapped)
            return
        }

        // Let the system handle IME input.
        if let ctx = inputContext, ctx.handleEvent(event) {
            return
        }
        // Fallback: interpret key events directly.
        interpretKeyEvents([event])
    }

    /// Returns true for special keycodes that should bypass IME.
    private func isSpecialKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x35: return true  // Escape
        case 0x7B, 0x7C, 0x7D, 0x7E: return true  // Arrow keys
        case 0x24: return true  // Return
        case 0x30: return true  // Tab
        case 0x33: return true  // Delete (Backspace)
        case 0x75: return true  // Forward Delete
        case 0x73, 0x77: return true  // Home, End
        case 0x74, 0x79: return true  // Page Up, Page Down
        case 0x7A, 0x78, 0x63, 0x76: return true  // F1-F4
        case 0x60, 0x61, 0x62, 0x64: return true  // F5-F8
        case 0x65, 0x6D, 0x67, 0x6F: return true  // F9-F12
        default: return false
        }
    }

    override func keyUp(with event: NSEvent) {
        // Key up events typically not needed for terminal input
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier-only events typically not needed for terminal input
    }

    // MARK: - Scroll Event Handling

    override func scrollWheel(with event: NSEvent) {
        guard let main = mainTerminalView else { return }
        main.noteScrollGesturePhase(event)

        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        if deltaY == 0 && deltaX == 0 { return }

        // Calculate cell position from mouse location within this view
        let location = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2.0
        let cellWidthPx = CGFloat(main.renderer.cellWidthPx)
        let cellHeightPx = CGFloat(main.renderer.cellHeightPx)

        // Convert location to cell coordinates
        let col = Int32(location.x * scale / cellWidthPx)
        // Flip Y coordinate (view origin is bottom-left, grid origin is top-left)
        let viewHeightPx = bounds.height * scale
        let row = Int32((viewHeightPx - location.y * scale) / cellHeightPx)

        // Build modifier string for scroll event
        let modifier = main.buildModifierString(from: event.modifierFlags)

        // Vertical scroll
        if deltaY != 0 {
            ZonvieCore.appLog("[ExternalGridView scroll] deltaY=\(deltaY) hasPrecise=\(event.hasPreciseScrollingDeltas) gridId=\(gridId) row=\(row) col=\(col)")

            let newOffset = main.handleScrollInput(
                gridId: gridId,
                row: row,
                col: col,
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

    }

}

// MARK: - IME host

extension ExternalGridView: IMEPreeditHost {
    var imeCore: ZonvieCore? { mainTerminalView?.core }

    var imePreeditFont: NSFont {
        guard let main = mainTerminalView else {
            return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        return NSFont(name: main.renderer.currentFontName, size: main.renderer.currentPointSize)
            ?? NSFont.monospacedSystemFont(ofSize: main.renderer.currentPointSize, weight: .regular)
    }

    var imePreeditCellSize: CGSize {
        guard let main = mainTerminalView else { return CGSize(width: 8, height: 16) }
        let scale = window?.backingScaleFactor ?? 2.0
        return CGSize(width: CGFloat(main.renderer.cellWidthPx) / scale,
                      height: CGFloat(main.renderer.cellHeightPx) / scale)
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
        let cellW = CGFloat(main.renderer.cellWidthPx) / scale
        let rowH = CGFloat(main.renderer.cellHeightPx) / scale
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

    func imeSendCommitted(_ text: String) { mainTerminalView?.core?.sendInput(text) }
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

        // Deactivate draw loop when removed from window
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

        // Setup scrollbar based on config
        if scrollbarConfig.isAlways {
            verticalScroller.isHidden = false
            verticalScroller.alphaValue = CGFloat(scrollbarConfig.opacity)
        }

        // Setup hover tracking for scrollbar (if "hover" mode is enabled)
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

            // Show scrollbar on scroll if "scroll" mode
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

        // Auto-hide after delay (only if "scroll" mode and not "always")
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
            // Click above knob - page up
            let newTopline = max(1, viewport.topline - (visibleLines - 2) + 1)
            core.scrollToLine(newTopline, useBottom: false)

        case .incrementPage:
            // Click below knob - page down
            let newTopline = min(viewport.lineCount - visibleLines + 1, viewport.topline + (visibleLines - 2) + 1)
            let targetLine = max(1, newTopline)
            core.scrollToLine(targetLine, useBottom: false)

        case .knob, .knobSlot:
            // Dragging knob
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
