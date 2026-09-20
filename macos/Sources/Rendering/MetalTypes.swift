import AppKit
import Foundation
import Metal
import simd

struct Vertex {
    var position: simd_float2
    var texCoord: simd_float2
    var color: simd_float4
    var grid_id: Int64  // 1 = global grid, >1 = sub-grid (float window)
    var deco_flags: UInt32  // ZONVIE_DECO_* flags for decoration type
    var deco_phase: Float  // phase offset for undercurl (cell column position)
}

// DrawableSize struct matching Shaders.metal (for fragment shader clipping)
/// Allocation-free sparse set of row indices, shared by both surfaces.
///
/// The row list makes synchronization O(changed rows); the bitset prevents a
/// repeatedly updated row from growing that list. Capacity only ever grows, at
/// a `prepare` call, so the redraw/flush hot path reuses a high-water
/// allocation and never allocates. A surface that knows its ceiling up front
/// passes `preparedRows` and pays for the whole set at construction instead.
final class SparseRowSet {
    private(set) var rows: [UInt32] = []
    private var membership: [UInt64] = []
    private let rowLimit: Int
    private var preparedRowCount = 0

    init(rowLimit: Int, preparedRows: Int = 0) {
        self.rowLimit = rowLimit
        prepare(rowCount: preparedRows)
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

struct DrawableSize {
    var width: Float
    var height: Float
}

final class SurfaceRowBufferState {
    var buffers: [MTLBuffer?] = []
    var capacities: [Int] = []
    var counts: [Int] = []
    var dirtyRows: Set<Int> = []
    var usingRowBuffers: Bool = false



}

final class SurfaceRedrawScheduler {
    private let lock = NSLock()
    private var redrawPending = false
    private var pendingRedrawRect: NSRect? = nil

    func didDrawFrame() {
        lock.lock()
        pendingRedrawRect = nil
        redrawPending = false
        lock.unlock()
    }

    func requestRedraw(
        rect: NSRect?,
        bounds: NSRect,
        window: NSWindow?,
        perform: @escaping (NSRect) -> Void
    ) {
        lock.lock()

        if let rect {
            if let current = pendingRedrawRect {
                pendingRedrawRect = current.union(rect)
            } else {
                pendingRedrawRect = rect
            }
        } else {
            pendingRedrawRect = nil
        }

        if redrawPending {
            lock.unlock()
            return
        }
        redrawPending = true
        lock.unlock()

        let doPerform = { [weak self] in
            guard let self else { return }
            guard window != nil else {
                self.didDrawFrame()
                return
            }
            if window?.isMiniaturized == true {
                self.didDrawFrame()
                return
            }

            self.lock.lock()
            let redrawRect = self.pendingRedrawRect
            self.lock.unlock()
            perform(redrawRect ?? bounds)
        }

        if Thread.isMainThread {
            doPerform()
        } else {
            DispatchQueue.main.async(qos: .userInteractive, execute: doPerform)
        }
    }
}

/// A row that scrolled off a surface's edge, kept alive across the smooth
/// scroll so the vacated band shows the row that left.
///
/// By draw time the row is gone from the buffer sets: the slot remap rotates
/// it into the vacated band and Neovim writes the incoming row into that same
/// slot during the same flush. Hence a copy, taken before the slot is reused.
struct RetainedScrollRow {
    var buffer: MTLBuffer
    var count: Int
    var gridId: Int64
    /// Row the stored vertices were *built* for. The scroll fast path leaves
    /// vertices at their original row and compensates at draw time through
    /// rowSlotSourceRows, so after a few steps this is nowhere near the row
    /// the copy was taken from.
    var sourceRow: Int
    /// Row the copy must be displayed at, which walks off the edge of the grid
    /// (so it goes negative, or past the last row) as scrolling continues.
    var targetRow: Int
    /// Cell height the vertices were built for. A font or linespace change
    /// mid-ease invalidates their geometry.
    var cellHeightPx: Float
}

/// Retention of rows scrolled off a surface's edge, so the band a smooth
/// scroll opens shows the rows that left instead of the edge row's background
/// stretched across it (`pin_edges` in Shaders.metal).
///
/// Shared by the main surface and every external grid window: both capture
/// inside a flush bracket before the slots rotate, and both publish on commit
/// so a draw can never see a retained row ahead of the vertices it belongs to.
/// Only the copying differs, so that part stays with each surface.
///
/// Self-synchronising. Callers may hold their own lock across a call — this
/// class never calls back into them — but must then always take the two in
/// that order.
final class ScrollRetention {
    /// The keyboard ease is clamped to two rows, so two retained rows always
    /// cover its band. A trackpad gesture raises the depth to a wheel event's
    /// worth of rows ('mousescroll' ver), which is how wide its band gets.
    static let minDepthRows = 2
    /// A wheel event worth more rows than this leaves part of its band to the
    /// edge stretch.
    static let maxDepthRows = 4
    /// Round-robin over more buffers than can be live at once, so a capture
    /// never overwrites vertices a frame is still reading. Retained buffers
    /// are bound straight to the encoder and are not tracked by any in-flight
    /// counter, so ring size is the only thing keeping them alive.
    ///
    /// External surfaces allow TWO frames in flight; the main renderer allows
    /// one. Pinned by ScrollRetentionTests' "ringSize must exceed the buffers
    /// that can be live at once".
    static let maxInFlightFrames = 2
    /// Windows that can hold a band at the same time. Enforced in `beginStep`,
    /// not merely assumed: the ring is the only thing keeping a retained buffer
    /// alive, so an unbounded grid count would wrap it onto rows a frame is
    /// still reading. Set to Neovim's own ceiling on a diff group (E96: at most
    /// eight buffers may have 'diff' set), so no diff can outgrow it; what is
    /// reachable in practice is four, and the spare slots cost only residency.
    static let maxRetainedGrids = 8
    /// Four sets can be live at once — one per in-flight frame, the published
    /// set, and the one being staged — each holding at most
    /// `maxRetainedGrids * maxDepthRows` rows. The fifth is spare because
    /// `ringNext` advances on every take whether or not the set it filled was
    /// ever drawn; sized exactly to the live count, the ring would wrap onto a
    /// slot still being read. No "several flushes per frame" factor: a
    /// published set replaced within a frame is released at once and pins
    /// nothing. `takeBuffer` walks every slot in turn, so the whole ring
    /// becomes resident after a few seconds of scrolling in ONE window — this
    /// is a memory figure, not a lazy cap.
    static let ringSize = (maxInFlightFrames + 3) * maxDepthRows * maxRetainedGrids

    struct Plan {
        let first: Int
        let count: Int
        /// Where the row that sits AGAINST the content edge ends up — the
        /// anchor the prune measures distance from.
        let pivotTargetRow: Int
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var ring: [MTLBuffer?] = []
    private var ringCaps: [Int] = []
    private var ringNext = 0
    /// Captured during a flush, published to `published` by `commit()`.
    private var staged: [RetainedScrollRow] = []
    private var stagedValid = false
    private var published: [RetainedScrollRow] = []
    /// Grids that have opened a step, least recent first. Bounds how many can
    /// hold rows at once — see `maxRetainedGrids`.
    private var stepOrder: [Int64] = []
    /// Grids the cap dropped rows for, since the caller last took them.
    private var evictedGrids: [Int64] = []
    private var depth = ScrollRetention.minDepthRows

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Depth

    var depthRows: Int {
        lock.lock()
        defer { lock.unlock() }
        return depth
    }

    /// Raise the retention to cover a band this many rows wide, clamped to
    /// [`minDepthRows`, `maxDepthRows`].
    func setDepthRows(_ rows: Int) {
        let clamped = min(max(rows, Self.minDepthRows), Self.maxDepthRows)
        lock.lock()
        depth = clamped
        lock.unlock()
    }

    // MARK: - Flush lifecycle

    /// Discard anything staged by a bracket that aborted instead of
    /// committing; publication only ever happens from a bracket's own commit.
    func beginFlush() {
        lock.lock()
        stagedValid = false
        staged.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Publish this bracket's retention together with the vertices it belongs
    /// to. A retained row shown against pre-scroll content would draw the same
    /// line twice. Returns whether this bracket had staged anything, so the
    /// caller can publish its own per-step state on the same condition.
    @discardableResult
    func commit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stagedValid else { return false }
        stagedValid = false
        published.removeAll(keepingCapacity: true)
        published.append(contentsOf: staged)
        staged.removeAll(keepingCapacity: true)
        return true
    }

    func snapshotPublished() -> [RetainedScrollRow] {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    /// Drop published rows the caller can no longer place — typically a grid
    /// that is no longer displaced, whose retained row would be drawn one row
    /// off real content.
    func prunePublished(where shouldDrop: (RetainedScrollRow) -> Bool) {
        lock.lock()
        published.removeAll(where: shouldDrop)
        lock.unlock()
    }

    /// Drop the rows of every grid that is neither displaced now nor about to
    /// be. A published row fills the band a grid's sub-cell offset opens, so
    /// with no offset it would draw one row off real content — and its mere
    /// presence makes the grid's layer redraw every row (see
    /// `layerNeedsAllRows`). Hence every frame, not only the frames an ease
    /// happens to rebuild the offsets on.
    ///
    /// `seedGrids` names grids whose ease seed is committed but not yet spent.
    /// Seed and rows publish together while the offset they belong to is
    /// installed one main-thread step later, so a prune landing in between
    /// would empty the band of the ease that is about to start.
    ///
    /// No allocation: both lookups scan arrays the caller already owns.
    func pruneUndisplaced(
        offsets: [GridSurfaceRenderer.ScrollOffset],
        seedGrids: [(gridId: Int64, rowsDelta: Int)]
    ) {
        prunePublished { retained in
            !offsets.contains { Int64($0.grid_id) == retained.gridId }
                && !seedGrids.contains { $0.gridId == retained.gridId }
        }
    }

    func publishedCount(gridId: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return published.reduce(0) { $0 + ($1.gridId == gridId ? 1 : 0) }
    }

    /// Drop everything on screen: a retained row is only meaningful while its
    /// grid is displaced.
    ///
    /// Deliberately leaves the STAGED set alone. Called from the draw side
    /// while the core thread may be mid-bracket, and discarding its staged rows
    /// would make `commit()` report that nothing was staged — dropping the step
    /// and with it the caller's per-step state (the main surface's ease seed),
    /// so the picture snaps instead of easing.
    func clearPublished() {
        lock.lock()
        published.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Planning

    /// Which rows a step of `rowsDelta` takes out of [rowStart, rowEnd), cut
    /// down to the `depth` the retention can hold.
    ///
    /// Rows leaving through the top are the first `moved` of the region, and
    /// the band shows the LAST of them; leaving through the bottom they are
    /// the last `moved`, and the band shows the FIRST. A retained row at
    /// `targetRow = t` draws at screen row `t + o` for an offset of `o` rows,
    /// so at the top it is inside the band while `rowStart - o <= t <
    /// rowStart` — the row that survives longest as the finger consumes the
    /// offset is the one with the LARGEST target, `first + count - 1`. At the
    /// bottom the inequality flips and it is `first`.
    ///
    /// nil when the step replaces the whole region: every row the band could
    /// show is gone, so there is nothing worth easing.
    static func plan(rowStart: Int, rowEnd: Int, rowsDelta: Int, depth: Int) -> Plan? {
        let moved = abs(rowsDelta)
        guard moved > 0, moved < rowEnd - rowStart else { return nil }
        let count = min(moved, depth)
        guard count > 0 else { return nil }
        let first = rowsDelta > 0 ? rowStart + moved - count : rowEnd - moved
        let edgeAdjacent = rowsDelta > 0 ? first + count - 1 : first
        return Plan(first: first, count: count, pivotTargetRow: edgeAdjacent - rowsDelta)
    }

    /// The i-th row of a plan, ordered far-edge first: `stage` drops from the
    /// front, so the last row appended — the one against the content edge,
    /// which the band needs longest — is the last to be shed.
    static func planRow(_ plan: Plan, _ i: Int, rowsDelta: Int) -> Int {
        rowsDelta > 0 ? plan.first + i : plan.first + plan.count - 1 - i
    }

    /// Whether this many retained rows cover the whole band an offset opens.
    ///
    /// A grid whose band is covered must not also stretch its edge row's
    /// background across it: the stretch wins over the retained rows' own
    /// backgrounds, so the band would render one row's glyphs on its
    /// neighbour's background colour. Only when they cover the WHOLE band,
    /// though — a step whose row could not be retained (a row shared with an
    /// overlapping float, a jump past the depth) still moves the offset, and
    /// with the stretch also gone the uncovered part would show through as a
    /// gap, which is what the stretch is for.
    static func coversBand(retainedRows: Int, offsetNDC: Float, cellHeightNDC: Float) -> Bool {
        guard cellHeightNDC > 0 else { return false }
        let bandRows = Int(ceil(abs(offsetNDC) / cellHeightNDC - 0.001))
        return retainedRows >= bandRows
    }

    // MARK: - Credit arithmetic

    /// What a grid's sub-cell scroll offset becomes when Neovim reports that
    /// its content moved `rowsDelta` rows. `nil` means the offset settled on
    /// the cell grid and its entry should be dropped.
    ///
    /// Pure so it can be tested; the view owns the bookkeeping around it.
    ///
    /// - `heldPx` is the compensation currently being held, already including
    ///   any seed handed over when a bound window is first recognised.
    /// - `bookedRows` is what the gesture asked for and has not yet been
    ///   credited. Zero for a window the gesture merely drags along
    ///   ('scrollbind'), which is why `bound` is passed separately: the driving
    ///   window also runs its booking down to zero mid-gesture.
    static func creditedOffsetPx(
        heldPx: CGFloat,
        bookedRows: Int,
        rowsDelta: Int,
        rowHeightPx: CGFloat,
        stepRows: Int,
        bound: Bool,
        epsilonPx: CGFloat
    ) -> CGFloat? {
        let consumed = min(bookedRows, abs(rowsDelta))
        let creditedRows = bookedRows > 0 ? (rowsDelta < 0 ? -consumed : consumed) : rowsDelta
        var offset = heldPx + CGFloat(creditedRows) * rowHeightPx
        let stepPx = rowHeightPx * CGFloat(max(1, stepRows))
        if !bound {
            // Handing back what is held may overshoot zero by one step — the
            // allowance the lookahead runs on. A credit pushing AWAY from zero
            // is not handing anything back, so it may not deepen an offset that
            // already holds something.
            let deepens = heldPx == 0 || (offset < 0) == (heldPx < 0)
            let cap = deepens ? (heldPx == 0 ? stepPx : abs(heldPx)) : stepPx
            if abs(offset) > cap { offset = offset < 0 ? -cap : cap }
        } else if abs(offset) > stepPx {
            // A bound window books nothing, so its report is the only account
            // of how far it moved and must be allowed to deepen — bounded by
            // what the finger can consume before the next report lands.
            offset = offset < 0 ? -stepPx : stepPx
        }
        return abs(offset) < epsilonPx ? nil : offset
    }

    // MARK: - Capture

    /// Open a retention step: this grid's rows kept by earlier steps move
    /// `rowsDelta` further out of view, and the ones the ease can no longer
    /// show are dropped — rows past the clamp, and rows on the opposite edge
    /// after a direction reversal. Other grids are left alone; they lose their
    /// rows only to the `maxRetainedGrids` cap below. A step stages one or more
    /// rows, which is why this is separate from `stage`: rows of the same step
    /// must not displace each other.
    func beginStep(gridId: Int64, rowsDelta: Int, pivotTargetRow: Int) {
        lock.lock()
        // Seed from what is on screen before advancing it. Seeding after the
        // shift would reinstate the published rows at their old targetRow and
        // draw them a step behind the content.
        if !stagedValid {
            stagedValid = true
            staged.removeAll(keepingCapacity: true)
            staged.append(contentsOf: published)
            // Eviction takes a grid out of `staged` and out of the order, but
            // its rows leave `published` only at a commit — so a bracket that
            // aborts hands them back here for a grid the order no longer names,
            // and nothing would ever evict it again. Re-admit what the seed
            // brought, least-recent first, and drop names that hold nothing so
            // a live grid is never the victim in a ghost's place.
            stepOrder.removeAll { name in !staged.contains { $0.gridId == name } }
            for row in staged where !stepOrder.contains(row.gridId) {
                stepOrder.insert(row.gridId, at: 0)
            }
        }
        // Hold the ring's sizing assumption: rows are capped per grid, but a
        // `windo`/'scrollbind' group larger than `maxRetainedGrids` would wrap
        // the ring onto buffers a frame is still reading. The grid opening a
        // step is the one being scrolled now, so what is shed is least recent.
        stepOrder.removeAll { $0 == gridId }
        stepOrder.append(gridId)
        while stepOrder.count > Self.maxRetainedGrids {
            let dropped = stepOrder.removeFirst()
            staged.removeAll { $0.gridId == dropped }
            // Reported so the caller can forget it staged anything for this
            // grid: the row-scroll fast path stands down for a grid the
            // notification path already retained, and standing down for one
            // whose rows were just thrown away leaves its band empty AND
            // unretained.
            if !evictedGrids.contains(dropped) { evictedGrids.append(dropped) }
        }
        // Grid-scoped: 'scrollbind' (:vert diffsplit) scrolls two windows from
        // one gesture, each needing its own band. Shifting another grid's rows
        // here would move them a distance their content never travelled, and
        // dropping them would leave that window's band to the edge stretch.
        for i in staged.indices where staged[i].gridId == gridId {
            staged[i].targetRow -= rowsDelta
        }
        staged.removeAll {
            $0.gridId == gridId
                && (abs($0.targetRow - pivotTargetRow) >= depth
                    || ($0.targetRow - pivotTargetRow) * rowsDelta > 0)
        }
        lock.unlock()
    }

    /// Take the grids the cap has dropped rows for, clearing the record.
    /// Appends rather than replacing, so a caller can accumulate across steps.
    func takeEvictedGrids(into out: inout [Int64]) {
        lock.lock()
        defer { lock.unlock() }
        out.append(contentsOf: evictedGrids)
        evictedGrids.removeAll(keepingCapacity: true)
    }

    /// Grab the next ring slot with at least `needed` bytes.
    func takeBuffer(needed: Int) -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if ring.count != Self.ringSize {
            ring = Array(repeating: nil, count: Self.ringSize)
            ringCaps = Array(repeating: 0, count: Self.ringSize)
            ringNext = 0
        }
        let idx = ringNext
        ringNext = (idx + 1) % Self.ringSize
        if ring[idx] == nil || ringCaps[idx] < needed {
            // Rounded up to the next power of two so scrolling into
            // progressively wider rows converges after a few steps instead of
            // re-allocating on every widening — this runs inside the flush
            // bracket.
            var alloc = 4096
            while alloc < needed { alloc <<= 1 }
            let buf = device.makeBuffer(length: alloc, options: .storageModeShared)
            ring[idx] = buf
            ringCaps[idx] = buf == nil ? 0 : alloc
        }
        return ring[idx]
    }

    /// Append one row staged by the open step, clamping the set to the ease's
    /// reach. A step appends far-edge first (see `planRow`), so the
    /// drop-from-the-front clamp sheds what earlier steps left behind, then
    /// the rows furthest from the edge — the ones the band loses first as the
    /// finger consumes the offset.
    func stage(_ row: RetainedScrollRow) {
        lock.lock()
        staged.append(row)
        // Counted per grid: the depth is how far one band reaches, and two
        // windows scrolling together each get their own.
        var held = 0
        for candidate in staged where candidate.gridId == row.gridId { held += 1 }
        while held > depth, let oldest = staged.firstIndex(where: { $0.gridId == row.gridId }) {
            staged.remove(at: oldest)
            held -= 1
        }
        lock.unlock()
    }
}

/// Copy one outgoing row's retainable vertices into the retention ring: only
/// the vertices of `gridId` whose deco_flags carry `scrollableMask`
/// (DECO_SCROLLABLE — passed in because ScrollRetentionTests compiles this
/// file standalone, without the C header that defines it). Border and
/// margin-column cells (a float border's "│", a separator) do not carry the
/// flag, so the shader neither shifts them by the scroll offset nor marks them
/// for the fragment content clip; retained and translated to a targetRow they
/// would land statically on a margin row and persist in the back buffer.
/// Shared by GridSurfaceRenderer's grid_scroll capture and ExternalGridView's
/// pending-scroll capture, so both retain under one invariant: scrollable cells
/// of one grid, nothing else. nil when the row has nothing retainable (the band
/// then falls back to the edge stretch) or the ring has no buffer.
func copyRetainedScrollableRow(
    retention: ScrollRetention,
    srcBuf: MTLBuffer,
    vertexCount: Int,
    gridId: Int64,
    scrollableMask: UInt32
) -> (buffer: MTLBuffer, count: Int)? {
    let scrollable = scrollableMask
    let src = srcBuf.contents().bindMemory(to: Vertex.self, capacity: vertexCount)
    // Counted before a ring slot is taken, because taking one advances the
    // ring.
    var kept = 0
    for i in 0..<vertexCount where src[i].grid_id == gridId && (src[i].deco_flags & scrollable) != 0 {
        kept += 1
    }
    guard kept > 0 else { return nil }
    guard let dstBuf = retention.takeBuffer(needed: kept * MemoryLayout<Vertex>.stride) else { return nil }
    let dst = dstBuf.contents().bindMemory(to: Vertex.self, capacity: kept)
    var w = 0
    for i in 0..<vertexCount where src[i].grid_id == gridId && (src[i].deco_flags & scrollable) != 0 {
        dst[w] = src[i]
        w += 1
    }
    return (dstBuf, kept)
}

/// Maps a layer's vertex space to clip space, mirroring `LayerTransform` in
/// Shaders.metal. Core row vertices arrive in grid-local pixels; the identity
/// value (scale 1, offset 0) submits clip-space vertices unchanged.
struct LayerTransform {
    var scale: simd_float2
    var offset: simd_float2

    static let identity = LayerTransform(scale: simd_float2(1, 1), offset: simd_float2(0, 0))

    /// Pixel-to-clip mapping for a layer whose top-left sits at `originPx`
    /// within a surface of `extentPx`, with +y down in pixel space.
    init(originPx: simd_float2 = simd_float2(0, 0), extentPx: simd_float2) {
        let w = max(1, extentPx.x)
        let h = max(1, extentPx.y)
        self.scale = simd_float2(2 / w, -2 / h)
        self.offset = simd_float2(originPx.x * 2 / w - 1, 1 - originPx.y * 2 / h)
    }

    init(scale: simd_float2, offset: simd_float2) {
        self.scale = scale
        self.offset = offset
    }
}

/// Bind the vertex stage's layer transform (buffer index 4).
func bindLayerTransform(encoder: MTLRenderCommandEncoder, _ transform: LayerTransform) {
    var t = transform
    encoder.setVertexBytes(&t, length: MemoryLayout<LayerTransform>.stride, index: 4)
}

struct SurfaceViewportMetrics {
    let viewportWidth: Double
    let viewportHeight: Double
    let originX: Double
    let originY: Double
    let fragmentWidth: Float
    let fragmentHeight: Float
    /// Where the layer being drawn sits inside the viewport. Zero for a
    /// surface's root layer; an anchored float carries its own offset.
    let layerOriginPx: simd_float2

    init(
        viewportWidth: Double,
        viewportHeight: Double,
        drawableSize: CGSize,
        originX: Double = 0,
        originY: Double = 0,
        layerOriginPx: simd_float2 = simd_float2(0, 0)
    ) {
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.originX = originX
        self.originY = originY
        self.layerOriginPx = layerOriginPx
        self.fragmentWidth = Float(viewportWidth > 0 ? viewportWidth : Double(drawableSize.width))
        self.fragmentHeight = Float(viewportHeight > 0 ? viewportHeight : Double(drawableSize.height))
    }

    /// The pixel space core vertices arrive in: the layer's own top-left
    /// (`layerOriginPx`) within the viewport extent.
    var layerTransform: LayerTransform {
        LayerTransform(originPx: layerOriginPx, extentPx: simd_float2(fragmentWidth, fragmentHeight))
    }

    /// Sets the Metal viewport AND the vertex stage's layer transform, so the
    /// pixel space the core emits in can never drift from the viewport the
    /// result is mapped onto. `originX`/`originY` are carried by the viewport,
    /// so the transform itself maps from the layer's own top-left.
    func applyViewport(to encoder: MTLRenderCommandEncoder) {
        bindLayerTransform(encoder: encoder, layerTransform)
        guard viewportWidth > 0, viewportHeight > 0 else { return }
        encoder.setViewport(MTLViewport(originX: originX, originY: originY, width: viewportWidth, height: viewportHeight, znear: 0, zfar: 1))
    }
}

/// The decorated custom-shader chain compiles with preserve_alpha OFF, so it
/// discards alpha and takes RGB as the final colour: a premultiplied
/// transparent background would reach it as black. Opaque is the one
/// convention both consumers accept, and the chain forces its output opaque
/// anyway.
func resolveSurfaceBackgroundAlpha(
    blurEnabled: Bool,
    decoratedSurface: Bool,
    shaderChainConsumesSurface: Bool = false
) -> Float {
    if decoratedSurface {
        if shaderChainConsumesSurface {
            return 1.0
        }
        return blurEnabled ? 0.0 : 1.0
    }
    if blurEnabled {
        return ZonvieConfig.shared.backgroundAlpha
    }
    return 1.0
}

/// Clear color alpha for decorated surfaces. Always transparent so the
/// padding area outside the Metal viewport lets the container background
/// and icon views show through. The viewport area gets opaque backgrounds
/// from the shader (backgroundAlpha >= 1.0).
func resolveSurfaceClearAlpha(
    blurEnabled: Bool,
    decoratedSurface: Bool
) -> Double {
    if decoratedSurface {
        return 0.0
    }
    return Double(resolveSurfaceBackgroundAlpha(blurEnabled: blurEnabled, decoratedSurface: false))
}

/// Pack three 0...1 components into the 8-bit RGB both surfaces keep their
/// background as. The colour arrives from the core as 8-bit already; this is
/// for the paths that reach it through AppKit's CGFloat components.
func packSurfaceBgRGB(red: Double, green: Double, blue: Double) -> UInt32 {
    let r = UInt32(red * 255.0) & 0xFF
    let g = UInt32(green * 255.0) & 0xFF
    let b = UInt32(blue * 255.0) & 0xFF
    return (r << 16) | (g << 8) | b
}

/// The clear colour a surface's load action uses: its 8-bit background plus
/// the alpha its kind resolves to. GridSurfaceRenderer resolves that alpha
/// from `blurEnabled` on every draw; ExternalGridView is handed it by the app,
/// which picks a different one for a decorated surface's margin.
func makeSurfaceClearColor(bgRGB: UInt32, clearAlpha: Double) -> MTLClearColor {
    return MTLClearColor(
        red: Double((bgRGB >> 16) & 0xFF) / 255.0,
        green: Double((bgRGB >> 8) & 0xFF) / 255.0,
        blue: Double(bgRGB & 0xFF) / 255.0,
        alpha: clearAlpha
    )
}

func makeSurfaceClearColor(
    bgRGB: UInt32,
    blurEnabled: Bool,
    decoratedSurface: Bool = false
) -> MTLClearColor {
    return makeSurfaceClearColor(
        bgRGB: bgRGB,
        clearAlpha: resolveSurfaceClearAlpha(
            blurEnabled: blurEnabled,
            decoratedSurface: decoratedSurface
        )
    )
}

func resolveSurfaceColorLoadAction(
    blurEnabled: Bool,
    hasPresentedOnce: Bool,
    drawableSizeChanged: Bool,
    shouldReusePreviousContents: Bool,
    forceReusePreviousContents: Bool = false
) -> MTLLoadAction {
    if hasPresentedOnce && !drawableSizeChanged && forceReusePreviousContents {
        return .load
    }
    if !blurEnabled && hasPresentedOnce && !drawableSizeChanged && shouldReusePreviousContents {
        return .load
    }
    return .clear
}

/// Canonicalize a persistent dirty-row scratch after contiguous fallback
/// ranges were appended. Sorting is in-place and the compaction only shortens
/// the array, so capacity is retained and the hot path performs no heap work.
/// This replaces contains-per-row expansion, which was O(R²) when a scroll
/// blit failed and the whole region had to be redrawn.
/// Resolve one row of the range a smooth scroll draws: the grid's own rows
/// first, then the rows retained past the edge it scrolled through.
///
/// Both surfaces had this written out, identical apart from the id each calls
/// its root: a retained row belonging to a LAYER is drawn in that layer's own
/// pass, where its transform places it, so drawing it here would put it at the
/// root's origin. The main surface's root is grid 1; an external surface's root
/// is its own grid id. Hence `rootGridId` rather than a literal.
///
/// A row whose cell height no longer matches is dropped rather than drawn: a
/// font or linespace change invalidates the geometry the copy was built with.
func resolveSurfaceSmoothRow(
    logicalRow: Int,
    retainedRowBase: Int,
    retainedRows: [RetainedScrollRow],
    rootGridId: Int64,
    cellHeightPx: Int,
    resolveRow: (Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)?
) -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
    guard logicalRow >= retainedRowBase else { return resolveRow(logicalRow) }
    let i = logicalRow - retainedRowBase
    guard i < retainedRows.count else { return nil }
    let r = retainedRows[i]
    guard r.gridId == rootGridId else { return nil }
    guard r.cellHeightPx == Float(cellHeightPx) else { return nil }
    // Same relation resolveRow uses: the vertices live at sourceRow and have to
    // appear at targetRow.
    let translationY = Float(r.targetRow - r.sourceRow) * Float(cellHeightPx)
    return (r.count, r.buffer, translationY)
}

/// Submit a command buffer whose encoded work is real but whose frame will not
/// be presented, and release the frame's GPU bookkeeping once the GPU is done
/// with it.
///
/// Every abandoned frame on both surfaces ends this way. The buffer has to be
/// committed or the IOAccelerator region attached to it is never reclaimed; the
/// in-flight semaphore has to be signalled or the next draw waits forever; and
/// the buffer set this frame read has to be released or `beginFlush` treats it
/// as in flight for the rest of the session. Written out at each site that was
/// nine copies of the same steps, and the cost of getting one wrong is a
/// permanently wedged surface.
///
/// `release` is supplied already built with the caller's own `[weak self]`. A
/// strong capture here would keep the view alive until the GPU finished, while
/// the lock and semaphore inside it are captured strongly on purpose so the
/// signal still fires when the view is already gone.
func submitSurfaceFrameWithoutPresenting(
    cmd: MTLCommandBuffer,
    release: @escaping () -> Void
) {
    cmd.addCompletedHandler { _ in release() }
    cmd.commit()
}

func surfaceSortAndDeduplicateRows(_ rows: inout [Int]) {
    guard rows.count > 1 else { return }
    rows.sort()
    var write = 1
    var read = 1
    while read < rows.count {
        let value = rows[read]
        if value != rows[write - 1] {
            rows[write] = value
            write += 1
        }
        read += 1
    }
    if write < rows.count {
        rows.removeLast(rows.count - write)
    }
}

/// Encode row draws for a collection of row indices. Resolution and scissor
/// are produced via closures so the caller does not have to materialize an
/// intermediate per-frame draw-item array (zero allocation on the hot path).
///
/// `rows` accepts any `Collection<Int>` — typically `Range<Int>` for the
/// full-grid path or `[Int]` for dirty-row paths.
@discardableResult
func encodeSurfaceRowDraws<C: Collection>(
    encoder: MTLRenderCommandEncoder,
    rows: C,
    resolve: (Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)?,
    scissor: ((Int) -> MTLScissorRect?)? = nil,
    pipeline: MTLRenderPipelineState,
    backgroundPipeline: MTLRenderPipelineState?,
    glyphPipeline: MTLRenderPipelineState?,
    useTwoPass: Bool,
    unifiedBlurPipeline: MTLRenderPipelineState? = nil
) -> Int where C.Element == Int {
    var drawnRows = 0

    func encodePass(with pipelineState: MTLRenderPipelineState, countDrawnRows: Bool) {
        encoder.setRenderPipelineState(pipelineState)
        for row in rows {
            guard let resolved = resolve(row), resolved.vc > 0 else { continue }
            if let scissorFn = scissor {
                guard let sr = scissorFn(row) else { continue }
                encoder.setScissorRect(sr)
            }
            var translation = resolved.translationY
            encoder.setVertexBytes(&translation, length: MemoryLayout<Float>.size, index: 3)
            encoder.setVertexBuffer(resolved.vb, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
            if countDrawnRows {
                drawnRows += 1
            }
        }
    }

    // Single-pass via programmable blending supersedes the 2-pass discard
    // pattern when the unified pipeline is available — same visual output,
    // half the fragment-shader invocations.
    if useTwoPass, let unified = unifiedBlurPipeline {
        encodePass(with: unified, countDrawnRows: true)
    } else if useTwoPass, let backgroundPipeline, let glyphPipeline {
        encodePass(with: backgroundPipeline, countDrawnRows: true)
        encodePass(with: glyphPipeline, countDrawnRows: false)
    } else {
        encodePass(with: pipeline, countDrawnRows: true)
    }

    return drawnRows
}

// MARK: - SurfaceBufferSet (shared row-buffer state)

/// One grid's triple-buffered vertex storage, looked up by grid id so a
/// surface can draw several grids as ordered layers. A grid's buffers are
/// independent of which surface currently draws it, so a grid moving between
/// the main window and an external window keeps its rows. The core thread
/// inserts (a new grid's first row) and releases (grid destroy) while the draw
/// thread reads, so the dictionary carries its own lock: a Swift Dictionary
/// rehashing under a concurrent read is a crash, not a stale value.
final class GridBufferRegistry {
    private let registryLock = NSLock()
    private var sets: [Int64: [SurfaceBufferSet]] = [:]
    /// Insertion-ordered ids, maintained alongside `sets` so per-flush
    /// iteration does not allocate a fresh key array.
    private var ids: [Int64] = []

    /// The three buffer sets for `gridId`, creating them on first use.
    func sets(for gridId: Int64) -> [SurfaceBufferSet] {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = sets[gridId] { return existing }
        let created = [SurfaceBufferSet(), SurfaceBufferSet(), SurfaceBufferSet()]
        sets[gridId] = created
        ids.append(gridId)
        return created
    }

    /// The buffer sets for `gridId` if it has any, without creating them.
    func existingSets(for gridId: Int64) -> [SurfaceBufferSet]? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return sets[gridId]
    }

    /// Release a destroyed grid's buffers.
    func release(gridId: Int64) {
        registryLock.lock()
        defer { registryLock.unlock() }
        sets.removeValue(forKey: gridId)
        if let i = ids.firstIndex(of: gridId) { ids.remove(at: i) }
    }

    /// Snapshot of the ids into the caller's array, which is reused.
    func copyGridIds(into out: inout [Int64]) {
        registryLock.lock()
        defer { registryLock.unlock() }
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: ids)
    }
}

/// One grid placed on one surface, mirroring `zonvie_layer` in
/// include/zonvie_core.h.
struct SurfaceLayer {
    var gridId: Int64
    var anchorGrid: Int64
    var originPx: simd_float2
    var rows: Int
    var cols: Int
    var z: Int
    var followsScroll: Bool
    /// The layer accepts mouse input. A hit test must skip a layer without it:
    /// Neovim refuses an event addressed to such a window rather than passing
    /// it to what is behind, so targeting one swallows the event.
    var mouseEnabled: Bool = true
}

/// One published cursor, and the buffers the frames reading it need.
///
/// The cursor used to live on `SurfaceBufferSet`, which tied publishing a
/// cursor to rotating a ROW set: plain cursor motion — the commonest flush a
/// surface sees — had to find a free row set, resynchronize every grid's row
/// state into it and rotate, or be dropped when all three were GPU-in-flight.
/// Cursor callbacks replace the cursor outright, so a slot needs no
/// copy-forward; three are enough for the committed one plus the frames in
/// flight.
///
/// ExternalGridView split it out first. The main renderer kept its cursor in
/// the row-set objects and indexed that array with the CURSOR index, which is
/// only correct because nothing else in a set is read at that index.
final class SurfaceCursorSlot {
    var vertexBuffer: MTLBuffer? = nil
    var vertexBufferCap: Int = 0
    var vertexCount: Int = 0
    /// Fallback scratch for the cursor pass's scroll offsets, used only when
    /// they exceed setVertexBytes' 4096-byte limit. Stays nil on a surface that
    /// binds one offset rather than an array.
    var scrollOffsetBuffer: MTLBuffer? = nil
    var scrollOffsetBufferCap: Int = 0
}

/// Where the grid that owns the cursor sits on a surface, and how it moves.
///
/// Both surfaces answer this from their committed layer list, and both treat
/// their OWN root grid specially: the cursor there sits at the surface origin,
/// follows nothing and anchors to nothing. GridSurfaceRenderer said that by
/// returning zero for grid 1; ExternalGridView said it with a `!= gridId`
/// clause on two of its three lookups and not on the third, which therefore
/// took the root layer's own origin. One resolve, and one scan where the
/// external surface made three.
struct SurfaceCursorPlacement {
    var originPx: simd_float2
    var followsScroll: Bool
    var anchorGrid: Int64
}

func resolveSurfaceCursorPlacement(
    ownerGridId: Int64,
    rootGridId: Int64,
    layers: [SurfaceLayer]
) -> SurfaceCursorPlacement {
    guard ownerGridId != rootGridId,
          let layer = layers.first(where: { $0.gridId == ownerGridId })
    else {
        return SurfaceCursorPlacement(
            originPx: simd_float2(0, 0),
            followsScroll: false,
            anchorGrid: rootGridId
        )
    }
    return SurfaceCursorPlacement(
        originPx: layer.originPx,
        followsScroll: layer.followsScroll,
        anchorGrid: layer.anchorGrid
    )
}

/// Resolve a retained row in grid-local pixels, including a prior slot shift.
func resolveSurfaceGridRow(_ set: SurfaceBufferSet, row: Int, cellHeightPx: Float)
    -> (vc: Int, vb: MTLBuffer, translationY: Float)? {
    guard row >= 0, row < set.rowLogicalToSlot.count else { return nil }
    let slot = set.rowLogicalToSlot[row]
    guard slot >= 0, slot < set.rowState.buffers.count,
          slot < set.rowState.counts.count,
          let buffer = set.rowState.buffers[slot], set.rowState.counts[slot] > 0
    else { return nil }
    let source = slot < set.rowSlotSourceRows.count ? set.rowSlotSourceRows[slot] : row
    return (set.rowState.counts[slot], buffer, Float(row - source) * cellHeightPx)
}

final class SurfaceBufferSet {
    let rowState = SurfaceRowBufferState()
    var rowLogicalToSlot: [Int] = []        // logical row -> physical slot
    var rowSlotSourceRows: [Int] = []       // physical slot -> row encoded in vertex positions
    var knownTotalRows: Int = 0
    var knownTotalCols: Int = 0
    var pendingScroll: SurfaceRowScroll? = nil
    // Font generation shared by every retained row in this set. External
    // grids advance it only after a flush regenerated every logical row.
    var fontGeneration: UInt64 = 0

    // Main vertex buffer (used by GridSurfaceRenderer, not by ExternalGridView)
    var mainVertexBuffer: MTLBuffer? = nil
    var mainVertexBufferCap: Int = 0
    var mainVertexCount: Int = 0

    // Atlas texture frozen at commit time alongside this set's vertex data
    // (ExternalGridView only; GridSurfaceRenderer reads committedAtlasTexture
    // under its own `lock` in the same scope as its committed-index snapshot).
    // Without it, ExternalGridView.draw(in:) fetching the atlas from the main
    // renderer at a LATER, independent point in the same draw call could pair
    // THIS commit's vertices/UVs with a different atlas layout a core-thread
    // commit installed in between. Published in ExternalGridView.commitFlush()
    // with committedSetIndex, under the same tripleBufferLock.
    var atlasTextureSnapshot: MTLTexture? = nil
    // Scroll-offset scratch for bindSurfaceScrollOffsets' fallback path (only
    // when offsets exceed the 4096-byte setVertexBytes limit — rare). Per-set
    // because gpuInFlightCount guarantees the previous frame's read of this
    // slot completed before it is reused. The cursor pass has its own, on the
    // cursor slot, because the two passes can bind different offsets within
    // one frame.
    var scrollOffsetBuffer: MTLBuffer? = nil
    var scrollOffsetBufferCap: Int = 0

    // Detach pool: buffers saved from this set before beginFlush overwrites them.
    // On COW detach, reuse a pool buffer instead of calling device.makeBuffer().
    var detachPoolRowBuffers: [MTLBuffer?] = []
    var detachPoolRowCapacities: [Int] = []
    var detachPoolMainBuffer: MTLBuffer? = nil
    var detachPoolMainCap: Int = 0

    // Private per-row buffer pool, owned exclusively by this set: the safe
    // write target when the detach pool cannot be reused (sharesSource &&
    // gpuInFlight && pool buffer aliases src).
    //
    // Two slots per row: after rotation the COW shallow-copy chain can leave
    // src.rowState[R] aliasing this set's only private buffer, so a single slot
    // would corrupt the in-flight committed frame. Two guarantee one unaliased
    // slot after warm-up.
    //
    // The alternative in that fallback path is device.makeBuffer(): each fresh
    // MTLBuffer creates an IOAccelerator region that the macOS Metal allocator
    // pools internally rather than returning to the kernel, so phys_footprint
    // grows monotonically across scroll bursts.
    // Total bound: 3 sets x N rows x 2 slots x peak cap.
    var privateRowBuffers0: [MTLBuffer?] = []
    var privateRowCapacities0: [Int] = []
    var privateRowBuffers1: [MTLBuffer?] = []
    var privateRowCapacities1: [Int] = []
    /// 0 or 1: which slot to try first on next detach for this row.
    /// Toggles after each successful reuse so slots alternate naturally.
    var privateRowNextSlot: [Int] = []

}

/// Index of a set that is neither `committedIndex` nor GPU in-flight, for a
/// flush to write into; -1 when none is free.
func pickFreeBufferSetIndex(
    count: Int,
    committedIndex: Int,
    gpuInFlightCount: [Int]
) -> Int {
    for i in 0..<count {
        if i != committedIndex && gpuInFlightCount[i] == 0 {
            return i
        }
    }
    return -1
}

struct SurfaceRowScroll {
    var rowStart: Int
    var rowEnd: Int
    var colStart: Int
    var colEnd: Int
    var rowsDelta: Int
    var totalRows: Int
    var totalCols: Int
}

/// What one grid a surface places as a layer owes the next frame.
///
/// A reference type, so mutating one grid's entry never detaches the
/// dictionary's storage while the draw thread holds a reference into it.
///
/// `flushDirtyRows` belongs to the core thread inside the flush bracket;
/// `pendingDirtyRows`, `pendingScrollAccum` and `needsFullRedraw` cross to
/// the draw thread under the surface's lock; the `draw*` fields belong to the
/// draw thread for one frame. Every row number here is grid-local.
///
/// Only the main renderer keeps these today; ExternalGridView carries nil in
/// every layer frame. It is declared here so both surfaces can name the same
/// frame entry.
final class SurfaceLayerDrawState {
    var flushDirtyRows = IndexSet()
    var pendingDirtyRows = IndexSet()
    var pendingScrollAccum: SurfaceRowScroll? = nil
    var needsFullRedraw = false
    /// Consumed under the surface's lock at the top of a frame; capacity is reused.
    var drawRows: [Int] = []
    var drawScroll: SurfaceRowScroll? = nil
    var drawAllRows = false
    /// The band this frame's accepted GPU scroll copy vacated, in the layer's
    /// own pixel space, or nil when no blit ran for this layer.
    var drawBlitClearBand: (clearTopPx: Int, clearBottomPx: Int)? = nil
    var lastDrawnRowCount = 0
}

/// One layer a frame draws, with the buffer set it reads and what it owes.
///
/// Both surfaces take this snapshot under their own lock and then draw from it
/// without the lock. GridSurfaceRenderer held three arrays read at the same
/// index, then one array of its own struct; ExternalGridView held an array of
/// `(layer, set)` pairs. One type, and both resolve the triple-buffer index
/// where the snapshot is taken rather than at each later use.
///
/// Which layers are admitted is still each surface's own: the main renderer's
/// entry 0 is its root grid, and ExternalGridView leaves its own grid out and
/// admits only layers whose grid has submitted.
struct SurfaceLayerFrame {
    let layer: SurfaceLayer
    /// The committed set of the layer's grid, nil for one that has never
    /// submitted.
    let set: SurfaceBufferSet?
    /// What the layer owes this frame; nil on a surface that keeps no
    /// per-layer draw state, and treated as owing everything.
    let state: SurfaceLayerDrawState?
}

/// Clamp a scroll-delta accumulator (produced via wrapping &+ to avoid a
/// hard trap on the add itself) so it can never reach Int.min/max. Callers
/// eventually pass rowsDelta to abs(), which traps on Int.min — this bound
/// is astronomically larger than any real terminal row count, so it never
/// affects legitimate scrolling, and a value already within it plus another
/// clamped value can never itself overflow on the next accumulation.
func clampRowsDelta(_ value: Int) -> Int {
    max(-1_000_000, min(1_000_000, value))
}

// MARK: - Surface Buffer Helpers

/// Maximum vertex buffer capacity (256 MB), bounding a single row's vertex
/// data. Deliberately generous headroom, not a tight budget: normal content
/// stays in the low single-digit MB range, the ceiling guards pathological
/// per-cell decoration counts, and hitting it terminates the redraw session
/// (see failHardRender in nvim_core.zig).
///
/// Kept equal to MAX_VERTEX_BYTES_PER_CALLBACK in src/core/flush.zig so the
/// core never hands over a row this buffer would reject on size alone. Not the
/// binding per-row ceiling: surfaceMaxProvisionedRowBytes below is lower once
/// spread across three sets with two private slots each (~42 MiB per row), and
/// that is the limit the provisioning path actually enforces.
// Not private: SurfaceRowProvisionTests pins the budget ceiling against it.
let surfaceMaxVertexBufferCapacity: Int = 256 * 1024 * 1024
// Provisioning may hold two private row buffers in each of three sets. Bound
// both the allocation peak and the IOAccelerator object count independently
// from the core's logical vertex budget.
let surfaceMaxProvisionedRowBytes: Int = 256 * 1024 * 1024
let surfaceMaxProvisionedRowBufferCount: Int = 16_384
let processMaxProvisionedRowBytes: Int = 512 * 1024 * 1024
let processMaxProvisionedRowBufferCount: Int = 32_768

func surfaceProvisionBudgetAllows(
    liveBytes: Int,
    liveBufferCount: Int,
    plannedBytes: Int,
    plannedBufferCount: Int,
    byteLimit: Int,
    bufferCountLimit: Int
) -> Bool {
    guard liveBytes >= 0, liveBufferCount >= 0,
          plannedBytes >= 0, plannedBufferCount >= 0,
          byteLimit >= 0, bufferCountLimit >= 0
    else { return false }
    let (peakBytes, byteOverflow) = liveBytes.addingReportingOverflow(plannedBytes)
    let (peakCount, countOverflow) = liveBufferCount.addingReportingOverflow(plannedBufferCount)
    return !byteOverflow && !countOverflow
        && peakBytes <= byteLimit
        && peakCount <= bufferCountLimit
}

/// Process-wide owner for row MTLBuffer allocations across the main renderer
/// and every external surface. Weak registrations follow ARC ownership, while
/// reservations make concurrent replacement peaks visible before allocation.
final class SurfaceRowProvisionBudget {
    struct Reservation {
        fileprivate let id: UInt64
    }

    static let shared = SurfaceRowProvisionBudget(
        byteLimit: processMaxProvisionedRowBytes,
        bufferCountLimit: processMaxProvisionedRowBufferCount
    )

    private final class LiveBuffer {
        weak var object: AnyObject?
        let bytes: Int

        init(_ buffer: MTLBuffer) {
            object = buffer as AnyObject
            bytes = buffer.length
        }
    }

    private struct ReservedCapacity {
        let bytes: Int
        let count: Int
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let bufferCountLimit: Int
    private var liveBuffers: [ObjectIdentifier: LiveBuffer] = [:]
    private var reservations: [UInt64: ReservedCapacity] = [:]
    private var nextReservationID: UInt64 = 1

    init(byteLimit: Int, bufferCountLimit: Int) {
        self.byteLimit = byteLimit
        self.bufferCountLimit = bufferCountLimit
    }

    private func pruneLocked() {
        liveBuffers = liveBuffers.filter { $0.value.object != nil }
    }

    private func totalsLocked() -> (bytes: Int, count: Int)? {
        var bytes = 0
        var count = 0
        for buffer in liveBuffers.values {
            let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(buffer.bytes)
            if byteOverflow { return nil }
            bytes = nextBytes
            count += 1
        }
        for reservation in reservations.values {
            let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(reservation.bytes)
            let (nextCount, countOverflow) = count.addingReportingOverflow(reservation.count)
            if byteOverflow || countOverflow { return nil }
            bytes = nextBytes
            count = nextCount
        }
        return (bytes, count)
    }

    func observe(_ buffers: [MTLBuffer]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        for buffer in buffers {
            let identity = ObjectIdentifier(buffer as AnyObject)
            if liveBuffers[identity] == nil {
                liveBuffers[identity] = LiveBuffer(buffer)
            }
        }
        guard let totals = totalsLocked() else { return false }
        return surfaceProvisionBudgetAllows(
            liveBytes: totals.bytes,
            liveBufferCount: totals.count,
            plannedBytes: 0,
            plannedBufferCount: 0,
            byteLimit: byteLimit,
            bufferCountLimit: bufferCountLimit
        )
    }

    func reserve(bytes: Int, bufferCount: Int) -> Reservation? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        guard let totals = totalsLocked(),
              surfaceProvisionBudgetAllows(
                  liveBytes: totals.bytes,
                  liveBufferCount: totals.count,
                  plannedBytes: bytes,
                  plannedBufferCount: bufferCount,
                  byteLimit: byteLimit,
                  bufferCountLimit: bufferCountLimit
              )
        else { return nil }

        var id = nextReservationID
        while id == 0 || reservations[id] != nil {
            nextReservationID &+= 1
            id = nextReservationID
        }
        nextReservationID = id &+ 1
        reservations[id] = ReservedCapacity(bytes: bytes, count: bufferCount)
        return Reservation(id: id)
    }

    /// Replace a peak reservation with weak ownership records for the buffers
    /// actually created. Partial allocation failures therefore retain only
    /// their successful prefix in the process ledger.
    func complete(_ reservation: Reservation, createdBuffers: [MTLBuffer]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        reservations.removeValue(forKey: reservation.id)
        pruneLocked()
        for buffer in createdBuffers {
            let identity = ObjectIdentifier(buffer as AnyObject)
            if liveBuffers[identity] == nil {
                liveBuffers[identity] = LiveBuffer(buffer)
            }
        }
        guard let totals = totalsLocked() else { return false }
        return surfaceProvisionBudgetAllows(
            liveBytes: totals.bytes,
            liveBufferCount: totals.count,
            plannedBytes: 0,
            plannedBufferCount: 0,
            byteLimit: byteLimit,
            bufferCountLimit: bufferCountLimit
        )
    }

    func cancel(_ reservation: Reservation) {
        lock.lock()
        reservations.removeValue(forKey: reservation.id)
        lock.unlock()
    }

    func currentTotals() -> (bytes: Int, count: Int)? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        return totalsLocked()
    }
}

/// Bytes for a vertex count; nil on overflow.
func surfaceSafeNeededBytes(vertexCount: Int) -> Int? {
    if vertexCount <= 0 { return 0 }
    let stride = MemoryLayout<Vertex>.stride
    let vc64 = Int64(vertexCount)
    let stride64 = Int64(stride)
    if vc64 > 0 && stride64 > 0 {
        let (prod, overflow) = vc64.multipliedReportingOverflow(by: stride64)
        if overflow { return nil }
        if prod > Int64(Int.max) { return nil }
        return Int(prod)
    }
    return nil
}

/// Grow capacity with doubling, clamped to max.
func surfaceGrowCapacity(current: Int, needed: Int) -> Int? {
    if needed < 0 { return nil }
    if needed <= current { return current }
    if needed > surfaceMaxVertexBufferCapacity { return nil }

    let doubled: Int
    if current <= 0 {
        doubled = 0
    } else if current > (Int.max / 2) {
        doubled = surfaceMaxVertexBufferCapacity
    } else {
        doubled = current * 2
    }
    let next = min(max(needed, doubled), surfaceMaxVertexBufferCapacity)
    if next <= 0 { return nil }
    return next
}

private func surfaceCapacityIsOversized(_ capacity: Int, neededBytes: Int) -> Bool {
    guard capacity > 0 else { return false }
    if neededBytes == 0 { return true }
    let (doubleNeeded, overflow) = neededBytes.multipliedReportingOverflow(by: 2)
    return !overflow && capacity > doubleNeeded
}

private func surfaceCapacityBasisForDemand(_ capacity: Int, neededBytes: Int) -> Int {
    surfaceCapacityIsOversized(capacity, neededBytes: neededBytes) ? 0 : capacity
}

/// Resolve a logical row through the exact set that will receive the write.
/// Scroll remaps physical slots on the write set, so consulting the source
/// set here can provision a different slot and make retry non-convergent.
func surfacePhysicalCapacityRow(logicalRow: Int, logicalToSlot: [Int]) -> Int {
    guard logicalRow >= 0, logicalRow < logicalToSlot.count else {
        return logicalRow
    }
    return logicalToSlot[logicalRow]
}

/// Ensure row storage arrays cover at least `row + 1` entries.
func ensureSurfaceRowStorage(bufferSet: SurfaceBufferSet, _ row: Int, maxRowBuffers: Int) {
    if row < 0 { return }
    if row >= maxRowBuffers { return }
    if row < bufferSet.rowState.buffers.count { return }
    let oldCount = bufferSet.rowState.buffers.count
    let newCount = row + 1
    bufferSet.rowState.buffers.reserveCapacity(newCount)
    bufferSet.rowState.capacities.reserveCapacity(newCount)
    bufferSet.rowState.counts.reserveCapacity(newCount)
    bufferSet.rowLogicalToSlot.reserveCapacity(newCount)
    bufferSet.rowSlotSourceRows.reserveCapacity(newCount)
    for index in oldCount..<newCount {
        bufferSet.rowState.buffers.append(nil)
        bufferSet.rowState.capacities.append(0)
        bufferSet.rowState.counts.append(0)
        bufferSet.rowLogicalToSlot.append(index)
        bufferSet.rowSlotSourceRows.append(index)
    }
}

/// A buffer allocated outside the core redraw callback and installed into one
/// set's private two-slot row pool during the short publication phase.
struct SurfaceRowProvisionEntry {
    let setIndex: Int
    let row: Int
    let slot0: MTLBuffer?
    let slot0Capacity: Int
    let slot1: MTLBuffer?
    let slot1Capacity: Int
}

struct SurfaceRowProvisionMetrics {
    let liveBufferBytes: Int
    let liveBufferCount: Int
    let plannedReplacementBytes: Int
    let plannedReplacementCount: Int
    let allocationAttemptCount: Int
    let createdBufferBytes: Int
    let createdBufferCount: Int
}

struct SurfaceRowProvisionPlan {
    let rowCount: Int
    let entries: [SurfaceRowProvisionEntry]
    let metrics: SurfaceRowProvisionMetrics
}

enum SurfaceRowProvisionPlanResult {
    case ready(SurfaceRowProvisionPlan)
    case overBudget
    // Successfully allocated private buffers remain owned by this partial
    // plan. The caller publishes only those private capacities, then retries
    // the still-missing suffix; live rowState content remains untouched.
    case allocationFailed(SurfaceRowProvisionPlan)
}

enum SurfaceRowProvisionStatus: Equatable {
    case ready
    case retry
    case hardFailure
}

/// The per-row capacity demand all three provisioning paths derive the same
/// way: the bytes the row needs, and the largest capacity any set already has
/// for that row, normalised by surfaceCapacityBasisForDemand so a stale
/// oversized capacity does not keep the demand inflated.
///
/// Returns nil when the vertex count cannot be sized or exceeds the
/// per-buffer budget -- surfaceRowCapacityIsPrepared reads that as "not
/// prepared", the provisioning plan reads it as .overBudget.
///
/// This deliberately stops short of surfaceGrowCapacity. Only two of the
/// three callers can hoist that out of their per-set loop:
/// surfaceRowCapacityIsPrepared calls it inside the loop, so an empty
/// bufferSets never reaches it, and moving it out would turn a vacuous true
/// into false.
func surfaceRowCapacityDemand(
    bufferSets: [SurfaceBufferSet],
    row: Int,
    vertexCount: Int
) -> (neededBytes: Int, capacityBasis: Int)? {
    guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)),
          neededBytes <= surfaceMaxVertexBufferCapacity
    else { return nil }
    var basis = 0
    for set in bufferSets where row < set.rowState.capacities.count {
        basis = max(basis, set.rowState.capacities[row])
    }
    return (neededBytes, surfaceCapacityBasisForDemand(basis, neededBytes: neededBytes))
}

/// Whether one private row slot already satisfies a row's demand: it exists,
/// is at least requiredCapacity, and is not so much larger than the row needs
/// that it should be replaced with a right-sized buffer.
///
/// Pass nil / 0 for a slot the arrays do not reach; an absent slot is never
/// ready. That is what lets the three call sites share one predicate.
func surfaceRowSlotIsReady(
    buffer: MTLBuffer?,
    capacity: Int,
    requiredCapacity: Int,
    neededBytes: Int
) -> Bool {
    guard buffer != nil, capacity >= requiredCapacity else { return false }
    return !surfaceCapacityIsOversized(capacity, neededBytes: neededBytes)
}

/// What one row's capacity check owes the surface that asked.
enum SurfaceRowCapacityVerdict: Equatable {
    /// Storage already covers the row; it may be written.
    case ready
    /// Arguments out of range. The caller fails the flush but must NOT latch
    /// `rowCapacityHardFailure`: that flag is never cleared, so latching it on
    /// a soft condition permanently stops the surface from presenting. The
    /// terminal case is the provisioner's `.overBudget`, which pairs with the
    /// documented-terminal `zonvie_core_fail_render_budget`.
    case invalid
    /// Storage has to grow first. The caller folds these into its ledger under
    /// its own lock and fails the flush so the retry drives provisioning.
    case needsProvisioning(capacityRow: Int, requiredRows: Int, vertexCount: Int)
}

/// Decide what one row's capacity check owes, touching no surface state.
///
/// Both surfaces carried their own copy of this decision. The copies already
/// agreed on every term but the physical-row mapping — the main surface can be
/// asked about a row that is already physical, an external one never is — so
/// the difference is an argument, not a second implementation.
///
/// `mappingSetIndex` is the set whose logical→slot mapping places the row:
/// the write set while a flush is staging into it, the flush source otherwise.
func surfaceRowCapacityVerdict(
    bufferSets: [SurfaceBufferSet],
    row: Int,
    vertexCount: Int,
    totalRows: Int,
    maxRowBuffers: Int,
    mappingSetIndex: Int,
    rowIsPhysical: Bool
) -> SurfaceRowCapacityVerdict {
    let capacityRow: Int
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
        return .ready
    }
    guard capacityRow >= 0, capacityRow < maxRowBuffers,
          totalRows >= 0, totalRows <= maxRowBuffers,
          surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)) != nil
    else { return .invalid }
    return .needsProvisioning(
        capacityRow: capacityRow,
        requiredRows: max(totalRows, capacityRow + 1),
        vertexCount: max(0, vertexCount)
    )
}

func surfaceRowCapacityIsPrepared(
    bufferSets: [SurfaceBufferSet],
    row: Int,
    vertexCount: Int,
    totalRows: Int,
    maxRowBuffers: Int
) -> Bool {
    guard row >= 0, row < maxRowBuffers,
          totalRows >= 0, totalRows <= maxRowBuffers,
          let demand = surfaceRowCapacityDemand(
              bufferSets: bufferSets,
              row: row,
              vertexCount: vertexCount
          )
    else { return false }
    let neededBytes = demand.neededBytes

    let requiredRows = max(totalRows, row + 1)
    for set in bufferSets {
        guard set.rowState.buffers.count >= requiredRows,
              set.rowState.capacities.count >= requiredRows,
              set.rowState.counts.count >= requiredRows,
              set.rowLogicalToSlot.count >= requiredRows,
              set.rowSlotSourceRows.count >= requiredRows,
              set.detachPoolRowBuffers.count >= requiredRows,
              set.detachPoolRowCapacities.count >= requiredRows,
              set.privateRowBuffers0.count >= requiredRows,
              set.privateRowCapacities0.count >= requiredRows,
              set.privateRowBuffers1.count >= requiredRows,
              set.privateRowCapacities1.count >= requiredRows,
              set.privateRowNextSlot.count >= requiredRows
        else { return false }

        if neededBytes > 0 {
            guard let requiredCapacity = surfaceGrowCapacity(
                current: demand.capacityBasis,
                needed: max(1, neededBytes)
            ),
            surfaceRowSlotIsReady(
                buffer: set.privateRowBuffers0[row],
                capacity: set.privateRowCapacities0[row],
                requiredCapacity: requiredCapacity,
                neededBytes: neededBytes
            ),
            surfaceRowSlotIsReady(
                buffer: set.privateRowBuffers1[row],
                capacity: set.privateRowCapacities1[row],
                requiredCapacity: requiredCapacity,
                neededBytes: neededBytes
            )
            else { return false }
        }
    }
    return true
}

/// Allocate every missing private row buffer without touching live renderer
/// metadata. The owner excludes flush-bracket mutation while this plan is
/// built, then publishes it under its render-state lock.
func makeSurfaceRowProvisionPlan(
    bufferSets: [SurfaceBufferSet],
    device: MTLDevice,
    requiredRowCount: Int,
    requiredVertexCounts: [Int],
    maxRowBuffers: Int,
    shouldFailAllocationAtAttempt: ((Int) -> Bool)? = nil,
    budgetOwner: SurfaceRowProvisionBudget = .shared
) -> SurfaceRowProvisionPlanResult {
    guard requiredRowCount >= 0, requiredRowCount <= maxRowBuffers else { return .overBudget }
    var entries: [SurfaceRowProvisionEntry] = []
    entries.reserveCapacity(requiredRowCount * bufferSets.count)

    var provisionedBytes = 0
    var provisionedBufferCount = 0
    var liveBufferIDs = Set<ObjectIdentifier>()
    var liveBufferBytes = 0
    var liveBufferCount = 0
    var plannedReplacementBytes = 0
    var plannedReplacementCount = 0
    var allocationAttemptCount = 0
    var createdBufferBytes = 0
    var createdBufferCount = 0
    var liveBuffersForProcess: [MTLBuffer] = []
    var createdBuffersForProcess: [MTLBuffer] = []
    var budgetReservation: SurfaceRowProvisionBudget.Reservation?

    func metrics() -> SurfaceRowProvisionMetrics {
        SurfaceRowProvisionMetrics(
            liveBufferBytes: liveBufferBytes,
            liveBufferCount: liveBufferCount,
            plannedReplacementBytes: plannedReplacementBytes,
            plannedReplacementCount: plannedReplacementCount,
            allocationAttemptCount: allocationAttemptCount,
            createdBufferBytes: createdBufferBytes,
            createdBufferCount: createdBufferCount
        )
    }

    func allocationFailure() -> SurfaceRowProvisionPlanResult {
        if let reservation = budgetReservation {
            budgetReservation = nil
            if !budgetOwner.complete(reservation, createdBuffers: createdBuffersForProcess) {
                return .overBudget
            }
        }
        return .allocationFailed(SurfaceRowProvisionPlan(
            rowCount: requiredRowCount,
            entries: entries,
            metrics: metrics()
        ))
    }

    func appendProvisionEntry(
        setIndex: Int,
        row: Int,
        slot0: MTLBuffer?,
        existingSlot0Capacity: Int,
        slot1: MTLBuffer?,
        existingSlot1Capacity: Int,
        requiredCapacity: Int
    ) {
        guard slot0 != nil || slot1 != nil else { return }
        entries.append(SurfaceRowProvisionEntry(
            setIndex: setIndex,
            row: row,
            slot0: slot0,
            slot0Capacity: slot0 == nil ? existingSlot0Capacity : requiredCapacity,
            slot1: slot1,
            slot1Capacity: slot1 == nil ? existingSlot1Capacity : requiredCapacity
        ))
    }

    func accountLiveBuffer(_ buffer: MTLBuffer?) -> Bool {
        guard let buffer else { return true }
        let identity = ObjectIdentifier(buffer as AnyObject)
        guard liveBufferIDs.insert(identity).inserted else { return true }
        liveBuffersForProcess.append(buffer)
        let (nextBytes, overflow) = provisionedBytes.addingReportingOverflow(buffer.length)
        if overflow { return false }
        provisionedBytes = nextBytes
        provisionedBufferCount += 1
        return provisionedBytes <= surfaceMaxProvisionedRowBytes
            && provisionedBufferCount <= surfaceMaxProvisionedRowBufferCount
    }

    // Count every currently-live row buffer by Metal object identity. The
    // active and detach arrays intentionally alias buffers across sets during
    // COW publication; identity de-duplication counts each allocation once
    // while still charging old buffers that remain live during replacement.
    for set in bufferSets {
        for buffer in set.rowState.buffers where !accountLiveBuffer(buffer) { return .overBudget }
        for buffer in set.detachPoolRowBuffers where !accountLiveBuffer(buffer) { return .overBudget }
        for buffer in set.privateRowBuffers0 where !accountLiveBuffer(buffer) { return .overBudget }
        for buffer in set.privateRowBuffers1 where !accountLiveBuffer(buffer) { return .overBudget }
    }
    liveBufferBytes = provisionedBytes
    liveBufferCount = provisionedBufferCount

    // Account the allocation peak before creating any MTLBuffer. Replaced
    // buffers remain live in their sets until the completed plan is published.
    for row in 0..<requiredRowCount {
        let vertexCount = row < requiredVertexCounts.count ? requiredVertexCounts[row] : 0
        guard let demand = surfaceRowCapacityDemand(
            bufferSets: bufferSets,
            row: row,
            vertexCount: vertexCount
        ) else { return .overBudget }
        let neededBytes = demand.neededBytes
        guard neededBytes > 0 else { continue }
        guard let requiredCapacity = surfaceGrowCapacity(
            current: demand.capacityBasis,
            needed: max(1, neededBytes)
        ) else { return .overBudget }

        for set in bufferSets {
            let slot0Ready = surfaceRowSlotIsReady(
                buffer: row < set.privateRowBuffers0.count ? set.privateRowBuffers0[row] : nil,
                capacity: row < set.privateRowCapacities0.count ? set.privateRowCapacities0[row] : 0,
                requiredCapacity: requiredCapacity,
                neededBytes: neededBytes
            )
            let slot1Ready = surfaceRowSlotIsReady(
                buffer: row < set.privateRowBuffers1.count ? set.privateRowBuffers1[row] : nil,
                capacity: row < set.privateRowCapacities1.count ? set.privateRowCapacities1[row] : 0,
                requiredCapacity: requiredCapacity,
                neededBytes: neededBytes
            )
            for ready in [slot0Ready, slot1Ready] where !ready {
                let (nextBytes, overflow) = provisionedBytes.addingReportingOverflow(requiredCapacity)
                if overflow { return .overBudget }
                provisionedBytes = nextBytes
                provisionedBufferCount += 1
                let (nextReplacementBytes, replacementOverflow) = plannedReplacementBytes.addingReportingOverflow(requiredCapacity)
                if replacementOverflow { return .overBudget }
                plannedReplacementBytes = nextReplacementBytes
                plannedReplacementCount += 1
            }
        }
        if provisionedBytes > surfaceMaxProvisionedRowBytes
            || provisionedBufferCount > surfaceMaxProvisionedRowBufferCount {
            return .overBudget
        }
    }

    guard budgetOwner.observe(liveBuffersForProcess),
          let reservation = budgetOwner.reserve(
              bytes: plannedReplacementBytes,
              bufferCount: plannedReplacementCount
          )
    else { return .overBudget }
    budgetReservation = reservation
    defer {
        if let reservation = budgetReservation {
            budgetOwner.cancel(reservation)
        }
    }

    for row in 0..<requiredRowCount {
        let vertexCount = row < requiredVertexCounts.count ? requiredVertexCounts[row] : 0
        guard let demand = surfaceRowCapacityDemand(
            bufferSets: bufferSets,
            row: row,
            vertexCount: vertexCount
        ) else { return .overBudget }
        let neededBytes = demand.neededBytes
        guard neededBytes > 0 else { continue }

        for (setIndex, set) in bufferSets.enumerated() {
            guard let requiredCapacity = surfaceGrowCapacity(
                current: demand.capacityBasis,
                needed: max(1, neededBytes)
            ) else { return .overBudget }

            let existingSlot0 = row < set.privateRowBuffers0.count
                ? set.privateRowBuffers0[row]
                : nil
            let existingSlot0Capacity = row < set.privateRowCapacities0.count
                ? set.privateRowCapacities0[row]
                : 0
            let existingSlot1 = row < set.privateRowBuffers1.count
                ? set.privateRowBuffers1[row]
                : nil
            let existingSlot1Capacity = row < set.privateRowCapacities1.count
                ? set.privateRowCapacities1[row]
                : 0

            var slot0: MTLBuffer? = nil
            var slot1: MTLBuffer? = nil
            if !surfaceRowSlotIsReady(
                buffer: existingSlot0,
                capacity: existingSlot0Capacity,
                requiredCapacity: requiredCapacity,
                neededBytes: neededBytes
            ) {
                allocationAttemptCount += 1
                if shouldFailAllocationAtAttempt?(allocationAttemptCount) == true {
                    return allocationFailure()
                }
                guard let allocated = device.makeBuffer(
                    length: requiredCapacity,
                    options: .storageModeShared
                ) else { return allocationFailure() }
                slot0 = allocated
                createdBufferBytes += requiredCapacity
                createdBufferCount += 1
                createdBuffersForProcess.append(allocated)
            }
            if !surfaceRowSlotIsReady(
                buffer: existingSlot1,
                capacity: existingSlot1Capacity,
                requiredCapacity: requiredCapacity,
                neededBytes: neededBytes
            ) {
                allocationAttemptCount += 1
                if shouldFailAllocationAtAttempt?(allocationAttemptCount) == true {
                    appendProvisionEntry(
                        setIndex: setIndex,
                        row: row,
                        slot0: slot0,
                        existingSlot0Capacity: existingSlot0Capacity,
                        slot1: nil,
                        existingSlot1Capacity: existingSlot1Capacity,
                        requiredCapacity: requiredCapacity
                    )
                    return allocationFailure()
                }
                guard let allocated = device.makeBuffer(
                    length: requiredCapacity,
                    options: .storageModeShared
                ) else {
                    appendProvisionEntry(
                        setIndex: setIndex,
                        row: row,
                        slot0: slot0,
                        existingSlot0Capacity: existingSlot0Capacity,
                        slot1: nil,
                        existingSlot1Capacity: existingSlot1Capacity,
                        requiredCapacity: requiredCapacity
                    )
                    return allocationFailure()
                }
                slot1 = allocated
                createdBufferBytes += requiredCapacity
                createdBufferCount += 1
                createdBuffersForProcess.append(allocated)
            }
            appendProvisionEntry(
                setIndex: setIndex,
                row: row,
                slot0: slot0,
                existingSlot0Capacity: existingSlot0Capacity,
                slot1: slot1,
                existingSlot1Capacity: existingSlot1Capacity,
                requiredCapacity: requiredCapacity
            )
        }
    }
    if let reservation = budgetReservation {
        budgetReservation = nil
        guard budgetOwner.complete(reservation, createdBuffers: createdBuffersForProcess) else {
            return .overBudget
        }
    }
    return .ready(SurfaceRowProvisionPlan(
        rowCount: requiredRowCount,
        entries: entries,
        metrics: metrics()
    ))
}

/// Publish a completed provision plan. Callers hold their render-state lock
/// and have excluded a concurrent flush bracket.
func applySurfaceRowProvisionPlan(
    _ plan: SurfaceRowProvisionPlan,
    to bufferSets: [SurfaceBufferSet],
    maxRowBuffers: Int
) {
    guard plan.rowCount > 0 else { return }
    let lastRow = plan.rowCount - 1
    for set in bufferSets {
        ensureSurfaceRowStorage(bufferSet: set, lastRow, maxRowBuffers: maxRowBuffers)
        while set.detachPoolRowBuffers.count < plan.rowCount {
            set.detachPoolRowBuffers.append(nil)
            set.detachPoolRowCapacities.append(0)
        }
        while set.privateRowBuffers0.count < plan.rowCount {
            set.privateRowBuffers0.append(nil)
            set.privateRowCapacities0.append(0)
            set.privateRowBuffers1.append(nil)
            set.privateRowCapacities1.append(0)
            set.privateRowNextSlot.append(0)
        }
    }

    for entry in plan.entries {
        guard entry.setIndex >= 0, entry.setIndex < bufferSets.count,
              entry.row >= 0, entry.row < plan.rowCount
        else { continue }
        let set = bufferSets[entry.setIndex]
        if let slot0 = entry.slot0 {
            set.privateRowBuffers0[entry.row] = slot0
            set.privateRowCapacities0[entry.row] = entry.slot0Capacity
        }
        if let slot1 = entry.slot1 {
            set.privateRowBuffers1[entry.row] = slot1
            set.privateRowCapacities1[entry.row] = entry.slot1Capacity
        }
    }
}

/// Release GPU buffers belonging only to logical rows removed by a grid
/// contraction. The buffer-set arrays retain capacity for future growth, but
/// the expensive MTLBuffer objects and spare-pool references do not stay at the
/// historical row-count high-water mark. Call only for a write set that is not
/// GPU in flight. Dropping a reference is safe even when another COW set still
/// aliases the same object; ARC keeps that other set's read alive.
private func evictSurfaceRowsOutsideLogicalRange(
    bufferSet: SurfaceBufferSet,
    totalRows: Int
) {
    guard totalRows >= 0, totalRows < bufferSet.rowLogicalToSlot.count else { return }
    for logicalRow in totalRows..<bufferSet.rowLogicalToSlot.count {
        let slot = bufferSet.rowLogicalToSlot[logicalRow]
        guard slot >= 0, slot < bufferSet.rowState.buffers.count else { continue }
        bufferSet.rowState.buffers[slot] = nil
        bufferSet.rowState.capacities[slot] = 0
        bufferSet.rowState.counts[slot] = 0

        if slot < bufferSet.detachPoolRowBuffers.count {
            bufferSet.detachPoolRowBuffers[slot] = nil
        }
        if slot < bufferSet.detachPoolRowCapacities.count {
            bufferSet.detachPoolRowCapacities[slot] = 0
        }
        if slot < bufferSet.privateRowBuffers0.count {
            bufferSet.privateRowBuffers0[slot] = nil
            bufferSet.privateRowCapacities0[slot] = 0
        }
        if slot < bufferSet.privateRowBuffers1.count {
            bufferSet.privateRowBuffers1[slot] = nil
            bufferSet.privateRowCapacities1[slot] = 0
        }
    }
}

/// Record the layout on a row-mode set before a write, releasing the rows a
/// row-count change dropped.
func prepareSurfaceRowModeSetForWrite(bufferSet: SurfaceBufferSet, totalRows: Int, totalCols: Int) {
    let previousTotalRows = bufferSet.knownTotalRows
    bufferSet.knownTotalRows = max(0, totalRows)
    bufferSet.knownTotalCols = max(0, totalCols)
    bufferSet.rowState.usingRowBuffers = true

    // submitSurfaceRowVertices calls this once per dirty row. Clearing the
    // complete historical tail on every call made a D-row update after shrink
    // O(D * (peakRows - totalRows)). The tail only changes when dimensions do;
    // copied buffer sets already inherit the source set's cleared counts.
    if totalRows >= 0,
       totalRows != previousTotalRows,
       totalRows < bufferSet.rowLogicalToSlot.count {
        evictSurfaceRowsOutsideLogicalRange(bufferSet: bufferSet, totalRows: totalRows)
        // Zero counts for logical rows >= totalRows using the logical-to-slot
        // mapping. After scroll remap, slot indices are shuffled — zeroing by
        // raw slot index would corrupt data belonging to valid lower rows.
        for r in totalRows..<bufferSet.rowLogicalToSlot.count {
            let slot = bufferSet.rowLogicalToSlot[r]
            if slot >= 0, slot < bufferSet.rowState.counts.count {
                bufferSet.rowState.counts[slot] = 0
            }
        }
    }
}

/// Publish a zero-cell layout into a non-in-flight write set without allocating
/// or destroying backing storage. Commit-time retirement owns the actual
/// resource release so an aborted flush cannot alter the committed set.
func applySurfaceZeroCellLayout(
    bufferSet: SurfaceBufferSet,
    totalRows: Int,
    totalCols: Int
) -> Bool {
    guard totalRows >= 0,
          totalCols >= 0,
          totalRows == 0 || totalCols == 0
    else { return false }

    bufferSet.knownTotalRows = totalRows
    bufferSet.knownTotalCols = totalCols
    bufferSet.rowState.usingRowBuffers = true
    for index in bufferSet.rowState.counts.indices {
        bufferSet.rowState.counts[index] = 0
    }
    bufferSet.mainVertexCount = 0
    bufferSet.pendingScroll = nil
    return true
}

/// Drop oversized row backing only while replacing that row in a non-in-flight
/// write set after a column contraction. Other COW sets retain any aliased
/// MTLBuffer until their own GPU reads complete.
private func retireOversizedSurfaceRowStorage(
    bufferSet: SurfaceBufferSet,
    row: Int,
    neededBytes: Int
) {
    guard row >= 0, row < bufferSet.rowState.buffers.count else { return }

    if surfaceCapacityIsOversized(bufferSet.rowState.capacities[row], neededBytes: neededBytes) {
        bufferSet.rowState.buffers[row] = nil
        bufferSet.rowState.capacities[row] = 0
    }
    if row < bufferSet.detachPoolRowCapacities.count,
       surfaceCapacityIsOversized(bufferSet.detachPoolRowCapacities[row], neededBytes: neededBytes) {
        bufferSet.detachPoolRowBuffers[row] = nil
        bufferSet.detachPoolRowCapacities[row] = 0
    }
    if row < bufferSet.privateRowCapacities0.count,
       surfaceCapacityIsOversized(bufferSet.privateRowCapacities0[row], neededBytes: neededBytes) {
        bufferSet.privateRowBuffers0[row] = nil
        bufferSet.privateRowCapacities0[row] = 0
    }
    if row < bufferSet.privateRowCapacities1.count,
       surfaceCapacityIsOversized(bufferSet.privateRowCapacities1[row], neededBytes: neededBytes) {
        bufferSet.privateRowBuffers1[row] = nil
        bufferSet.privateRowCapacities1[row] = 0
    }
}

/// Retire a stale set against the largest row payload measured in the newly
/// committed layout. Call only for a set that is not GPU in flight. When
/// `includeActiveBuffers` is false, active row references remain intact and
/// only the detach/private candidates are reclaimed.
func retireSurfaceRowStorageForContractedLayout(
    bufferSet: SurfaceBufferSet,
    demandSet: SurfaceBufferSet,
    includeActiveBuffers: Bool
) {
    var peakNeededBytes = 0
    for count in demandSet.rowState.counts {
        guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, count)),
              neededBytes <= surfaceMaxVertexBufferCapacity
        else { return }
        peakNeededBytes = max(peakNeededBytes, neededBytes)
    }

    func isOversized(_ capacity: Int) -> Bool {
        guard capacity > 0 else { return false }
        if peakNeededBytes == 0 { return true }
        return capacity > peakNeededBytes * 2
    }

    if includeActiveBuffers {
        for row in bufferSet.rowState.capacities.indices
        where isOversized(bufferSet.rowState.capacities[row]) {
            bufferSet.rowState.buffers[row] = nil
            bufferSet.rowState.capacities[row] = 0
        }
    }
    for row in bufferSet.detachPoolRowCapacities.indices
    where isOversized(bufferSet.detachPoolRowCapacities[row]) {
        bufferSet.detachPoolRowBuffers[row] = nil
        bufferSet.detachPoolRowCapacities[row] = 0
    }
    for row in bufferSet.privateRowCapacities0.indices
    where isOversized(bufferSet.privateRowCapacities0[row]) {
        bufferSet.privateRowBuffers0[row] = nil
        bufferSet.privateRowCapacities0[row] = 0
    }
    for row in bufferSet.privateRowCapacities1.indices
    where isOversized(bufferSet.privateRowCapacities1[row]) {
        bufferSet.privateRowBuffers1[row] = nil
        bufferSet.privateRowCapacities1[row] = 0
    }
}

/// Durable retirement state for the three row-buffer sets owned by a surface.
/// A fixed representation avoids allocation when commits or GPU completions
/// update the state.
struct SurfaceRowStorageRetirementState {
    private var pending0 = false
    private var pending1 = false
    private var pending2 = false
    private var pendingMain0 = false
    private var pendingMain1 = false
    private var pendingMain2 = false
    private var pendingMainBuffer0: MTLBuffer?
    private var pendingMainBuffer1: MTLBuffer?
    private var pendingMainBuffer2: MTLBuffer?
    private var pendingDetachMain0: MTLBuffer?
    private var pendingDetachMain1: MTLBuffer?
    private var pendingDetachMain2: MTLBuffer?

    mutating func markMainBuffersPending(_ index: Int, bufferSet: SurfaceBufferSet) {
        switch index {
        case 0:
            pendingMain0 = true
            pendingMainBuffer0 = bufferSet.mainVertexBuffer
            pendingDetachMain0 = bufferSet.detachPoolMainBuffer
        case 1:
            pendingMain1 = true
            pendingMainBuffer1 = bufferSet.mainVertexBuffer
            pendingDetachMain1 = bufferSet.detachPoolMainBuffer
        case 2:
            pendingMain2 = true
            pendingMainBuffer2 = bufferSet.mainVertexBuffer
            pendingDetachMain2 = bufferSet.detachPoolMainBuffer
        default: break
        }
    }

    func isMainBuffersPending(_ index: Int) -> Bool {
        switch index {
        case 0: return pendingMain0
        case 1: return pendingMain1
        case 2: return pendingMain2
        default: return false
        }
    }

    func pendingMainBuffer(_ index: Int) -> MTLBuffer? {
        switch index {
        case 0: return pendingMainBuffer0
        case 1: return pendingMainBuffer1
        case 2: return pendingMainBuffer2
        default: return nil
        }
    }

    func pendingDetachMainBuffer(_ index: Int) -> MTLBuffer? {
        switch index {
        case 0: return pendingDetachMain0
        case 1: return pendingDetachMain1
        case 2: return pendingDetachMain2
        default: return nil
        }
    }

    mutating func clearMainBuffersPending(_ index: Int) {
        switch index {
        case 0:
            pendingMain0 = false
            pendingMainBuffer0 = nil
            pendingDetachMain0 = nil
        case 1:
            pendingMain1 = false
            pendingMainBuffer1 = nil
            pendingDetachMain1 = nil
        case 2:
            pendingMain2 = false
            pendingMainBuffer2 = nil
            pendingDetachMain2 = nil
        default: break
        }
    }

    var hasMainBuffersPending: Bool {
        pendingMain0 || pendingMain1 || pendingMain2
    }

    mutating func markPending(_ index: Int) {
        switch index {
        case 0: pending0 = true
        case 1: pending1 = true
        case 2: pending2 = true
        default: break
        }
    }

    mutating func clearPending(_ index: Int) {
        switch index {
        case 0: pending0 = false
        case 1: pending1 = false
        case 2: pending2 = false
        default: break
        }
    }

    func isPending(_ index: Int) -> Bool {
        switch index {
        case 0: return pending0
        case 1: return pending1
        case 2: return pending2
        default: return false
        }
    }

    var hasPending: Bool {
        pending0 || pending1 || pending2
    }
}

/// Record a contraction for every set, then retire each idle set against the
/// latest committed demand. Busy sets remain pending until their GPU
/// completion calls this function again. Looking up the demand by committed
/// index, rather than copying row counts into the pending state, makes a
/// repeated contraction automatically supersede an older demand without a
/// per-frame allocation.
/// Release one buffer set's GPU read and let any storage that was waiting on it
/// retire.
///
/// Both surfaces wrote this out: the same guard against a stale or already-zero
/// index, the same decrement, and the same retirement service call, differing
/// only in whether the main vertex buffers retire too — an external surface has
/// none. Getting the guard wrong strands a set as permanently in-flight, which
/// `beginFlush` then refuses forever, so it is worth having in one place.
func completeSurfaceGpuRead(
    setIndex: Int,
    gpuInFlightCount: inout [Int],
    bufferSets: [SurfaceBufferSet],
    committedSetIndex: Int,
    retirement: inout SurfaceRowStorageRetirementState,
    retireMainBuffers: Bool
) {
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
        state: &retirement,
        retireMainBuffers: retireMainBuffers
    )
}

/// Cycle the input context so the system IME candidate window picks up the
/// current Light/Dark appearance — unless the user is mid-composition, where
/// cycling would break the session.
///
/// A rule, not plumbing, and it was written out on both surfaces.
func surfaceCycleInputContextForAppearance(_ context: NSTextInputContext?, hasMarkedText: Bool) {
    guard let context, !hasMarkedText else { return }
    context.deactivate()
    context.activate()
}

func serviceSurfaceRowStorageRetirement(
    bufferSets: [SurfaceBufferSet],
    gpuInFlightCount: [Int],
    committedSetIndex: Int,
    layoutContracted: Bool,
    state: inout SurfaceRowStorageRetirementState,
    retireMainBuffers: Bool = false
) {
    guard bufferSets.count == 3,
          gpuInFlightCount.count == 3,
          committedSetIndex >= 0,
          committedSetIndex < bufferSets.count
    else { return }

    if layoutContracted {
        for index in bufferSets.indices {
            state.markPending(index)
        }
        if retireMainBuffers {
            for index in bufferSets.indices {
                state.markMainBuffersPending(index, bufferSet: bufferSets[index])
            }
        }
    }

    let demandSet = bufferSets[committedSetIndex]
    if state.hasPending {
        let committedLayoutIsEmpty =
            demandSet.knownTotalRows == 0 || demandSet.knownTotalCols == 0
        for index in bufferSets.indices
        where state.isPending(index) && gpuInFlightCount[index] == 0 {
            retireSurfaceRowStorageForContractedLayout(
                bufferSet: bufferSets[index],
                demandSet: demandSet,
                includeActiveBuffers: index != committedSetIndex || committedLayoutIsEmpty
            )
            state.clearPending(index)
        }
    }

    if state.hasMainBuffersPending {
        for index in bufferSets.indices
        where state.isMainBuffersPending(index) && gpuInFlightCount[index] == 0 {
            let set = bufferSets[index]
            if let pending = state.pendingMainBuffer(index), set.mainVertexBuffer === pending {
                set.mainVertexBuffer = nil
                set.mainVertexBufferCap = 0
                set.mainVertexCount = 0
            }
            if let pending = state.pendingDetachMainBuffer(index), set.detachPoolMainBuffer === pending {
                set.detachPoolMainBuffer = nil
                set.detachPoolMainCap = 0
            }
            state.clearMainBuffersPending(index)
        }
    }
}

func copySurfaceMainVertexState(from src: SurfaceBufferSet, to dst: SurfaceBufferSet) {
    dst.detachPoolMainBuffer = dst.mainVertexBuffer
    dst.detachPoolMainCap = dst.mainVertexBufferCap
    dst.mainVertexBuffer = src.mainVertexBuffer
    dst.mainVertexBufferCap = src.mainVertexBufferCap
    dst.mainVertexCount = src.mainVertexCount
}

/// Ensure a writable row buffer for the given slot.
/// If the current buffer is shared with the source set (COW), detach by
/// taking a buffer from the detach pool (saved in copySurfaceBufferSetRowState).
/// A new MTLBuffer via device.makeBuffer is only created when no pool buffer
/// of sufficient capacity exists.
func ensureSurfaceRowBuffer(
    bufferSet: SurfaceBufferSet,
    sourceSet: SurfaceBufferSet?,
    device: MTLDevice,
    row: Int,
    vertexCount: Int,
    maxRowBuffers: Int,
    allowAllocation: Bool = true,
    inflightRowBuffers: (MTLBuffer?, MTLBuffer?) = (nil, nil)
) -> MTLBuffer? {
    guard row >= 0 && row < maxRowBuffers else { return nil }
    if allowAllocation {
        ensureSurfaceRowStorage(bufferSet: bufferSet, row, maxRowBuffers: maxRowBuffers)
    }
    guard row < bufferSet.rowState.buffers.count else { return nil }
    guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)) else { return nil }

    // Check if we share this buffer with the source (committed) set.
    let srcRowBuffer = sourceSet.flatMap { src in
        row < src.rowState.buffers.count ? src.rowState.buffers[row] : nil
    }
    let sharesSource = sourceSet != nil && srcRowBuffer != nil
        && bufferSet.rowState.buffers[row] === srcRowBuffer

    let activeCapacity = bufferSet.rowState.capacities[row]
    let needsNewBuffer = sharesSource
        || bufferSet.rowState.buffers[row] == nil
        || neededBytes > activeCapacity
        || surfaceCapacityIsOversized(activeCapacity, neededBytes: neededBytes)

    if needsNewBuffer {
        let capacityBasis = surfaceCapacityBasisForDemand(
            activeCapacity,
            neededBytes: neededBytes
        )
        guard let nextCap = surfaceGrowCapacity(
            current: capacityBasis,
            needed: max(1, neededBytes)
        ) else { return nil }

        // Try to reuse a buffer from the detach pool (saved before shallow copy).
        // Guard: the pool buffer must not alias the source (committed) buffer
        // NOR the same-slot buffer of a GPU in-flight set.
        // - src exclusion is unconditional: draw() can mark the committed set
        //   in-flight at any moment between this check and the caller's
        //   memcpy (check-then-write race).
        // - inflightRowBuffers covers OLDER sets the GPU is still reading
        //   (up to two with ExternalGridView's semaphore=2): the COW chain
        //   can leave the same buffer object shared into a set that is
        //   in-flight while src already holds a detached replacement, so
        //   comparing against src alone misses it (torn row mid-scroll).
        //
        // Reuse deliberately accepts storage larger than this row needs. The
        // oversize rejection belonged to 91bb4ad's async provisioning, which
        // reached here with allowAllocation: false so the provisioner refilled
        // the slot off the redraw callback; b83ff29 restored synchronous
        // allocation at the hot sites, so the same rejection would now land as
        // device.makeBuffer() inside the callback (the provisioner survives as
        // the allocation-failure fallback). Whether it fires depends on how the
        // row widths a slot sees line up with the pool-and-ring cycle, not on
        // any single width ratio: four rotating widths measured 45 allocations
        // per flush where two or three measured none. Worst case is a flush
        // that re-submits every row, where a slot warmed to its widest demand
        // misses on every narrower one: 26.7 makeBuffer per flush against 0.02,
        // with resident growth unbounded against flat (0.77 against 0.06 when
        // the scroll fast path resubmits only the vacated rows).
        //
        // Oversize storage is reclaimed by the retire* helpers on layout
        // contraction, not here. Content narrowing at a constant window size
        // is never reclaimed; that costs a per-slot high-water mark, measured
        // at 12.5 MB retained for 60x200.
        var reused = false
        if row < bufferSet.detachPoolRowBuffers.count,
           let poolBuf = bufferSet.detachPoolRowBuffers[row],
           row < bufferSet.detachPoolRowCapacities.count,
           bufferSet.detachPoolRowCapacities[row] >= nextCap,
           poolBuf !== srcRowBuffer,
           poolBuf !== inflightRowBuffers.0,
           poolBuf !== inflightRowBuffers.1
        {
            bufferSet.rowState.buffers[row] = poolBuf
            bufferSet.rowState.capacities[row] = bufferSet.detachPoolRowCapacities[row]
            bufferSet.detachPoolRowBuffers[row] = nil  // consumed
            reused = true
        }

        if !reused {
            // Prefer this set's per-row private slots over device.makeBuffer();
            // see the privateRowBuffers0/1 field comment for why there are two
            // and why fresh allocations here grow phys_footprint.
            if !allowAllocation && (
                bufferSet.privateRowBuffers0.count <= row ||
                bufferSet.privateRowCapacities0.count <= row ||
                bufferSet.privateRowBuffers1.count <= row ||
                bufferSet.privateRowCapacities1.count <= row ||
                bufferSet.privateRowNextSlot.count <= row
            ) {
                return nil
            }
            while bufferSet.privateRowBuffers0.count <= row {
                bufferSet.privateRowBuffers0.append(nil)
                bufferSet.privateRowCapacities0.append(0)
                bufferSet.privateRowBuffers1.append(nil)
                bufferSet.privateRowCapacities1.append(0)
                bufferSet.privateRowNextSlot.append(0)
            }

            // Try slots in order [nextSlot, otherSlot]. Use the first slot
            // whose buffer satisfies cap AND is not aliased with src or a
            // GPU in-flight set's same-slot buffer (the COW chain spreads
            // private buffers across sets, see comment above).
            let primarySlot = bufferSet.privateRowNextSlot[row]
            var pickedSlotIdx: Int = -1
            for tryIdx in 0..<2 {
                let slot = (primarySlot + tryIdx) % 2
                let buf = (slot == 0) ? bufferSet.privateRowBuffers0[row] : bufferSet.privateRowBuffers1[row]
                let cap = (slot == 0) ? bufferSet.privateRowCapacities0[row] : bufferSet.privateRowCapacities1[row]
                if let priv = buf, cap >= nextCap, priv !== srcRowBuffer,
                   priv !== inflightRowBuffers.0, priv !== inflightRowBuffers.1 {
                    pickedSlotIdx = slot
                    bufferSet.rowState.buffers[row] = priv
                    bufferSet.rowState.capacities[row] = cap
                    break
                }
            }

            if pickedSlotIdx >= 0 {
                // Reuse: toggle nextSlot so future detaches alternate naturally.
                bufferSet.privateRowNextSlot[row] = 1 - pickedSlotIdx
            } else {
                guard allowAllocation else { return nil }
                // Both private slots are unusable (nil, too small, or aliased).
                // Allocate a fresh buffer into the primary slot. Old contents
                // (if any) are dropped from this set; ARC will eventually
                // release once other sets drop their COW references.
                let newBuf = device.makeBuffer(length: nextCap, options: .storageModeShared)
                if newBuf == nil {
                    bufferSet.rowState.capacities[row] = 0
                    bufferSet.rowState.buffers[row] = nil
                    return nil
                }
                if primarySlot == 0 {
                    bufferSet.privateRowBuffers0[row] = newBuf
                    bufferSet.privateRowCapacities0[row] = nextCap
                } else {
                    bufferSet.privateRowBuffers1[row] = newBuf
                    bufferSet.privateRowCapacities1[row] = nextCap
                }
                bufferSet.rowState.buffers[row] = newBuf
                bufferSet.rowState.capacities[row] = nextCap
                bufferSet.privateRowNextSlot[row] = 1 - primarySlot
            }
        }
    }
    return bufferSet.rowState.buffers[row]
}

private func reverseSurfaceRowSlots(_ slots: inout [Int], in range: Range<Int>) {
    var lower = range.lowerBound
    var upper = range.upperBound - 1
    while lower < upper {
        slots.swapAt(lower, upper)
        lower += 1
        upper -= 1
    }
}

func remapSurfaceRowSlots(
    bufferSet: SurfaceBufferSet,
    rowStart: Int,
    rowEnd: Int,
    rowsDelta: Int,
    totalRows: Int,
    totalCols: Int,
    maxRowBuffers: Int
) {
    prepareSurfaceRowModeSetForWrite(bufferSet: bufferSet, totalRows: totalRows, totalCols: totalCols)
    let regionHeight = rowEnd - rowStart
    guard rowsDelta != Int.min else { return }
    let shift = abs(rowsDelta)
    guard shift > 0, shift < regionHeight else { return }
    ensureSurfaceRowStorage(bufferSet: bufferSet, rowEnd - 1, maxRowBuffers: maxRowBuffers)
    guard rowEnd <= bufferSet.rowLogicalToSlot.count else { return }

    if rowsDelta > 0 {
        // Rotate left in place. Building Array(slice) here allocated on every
        // scroll event, which is part of the redraw hot path.
        reverseSurfaceRowSlots(&bufferSet.rowLogicalToSlot, in: rowStart..<(rowStart + shift))
        reverseSurfaceRowSlots(&bufferSet.rowLogicalToSlot, in: (rowStart + shift)..<rowEnd)
        reverseSurfaceRowSlots(&bufferSet.rowLogicalToSlot, in: rowStart..<rowEnd)
        for logicalRow in (rowEnd - shift)..<rowEnd {
            let slot = bufferSet.rowLogicalToSlot[logicalRow]
            bufferSet.rowState.counts[slot] = 0
            bufferSet.rowSlotSourceRows[slot] = logicalRow
        }
    } else {
        // Rotate right in place, retaining the Array's storage.
        reverseSurfaceRowSlots(&bufferSet.rowLogicalToSlot, in: rowStart..<rowEnd)
        reverseSurfaceRowSlots(&bufferSet.rowLogicalToSlot, in: rowStart..<(rowStart + shift))
        reverseSurfaceRowSlots(&bufferSet.rowLogicalToSlot, in: (rowStart + shift)..<rowEnd)
        for logicalRow in rowStart..<(rowStart + shift) {
            let slot = bufferSet.rowLogicalToSlot[logicalRow]
            bufferSet.rowState.counts[slot] = 0
            bufferSet.rowSlotSourceRows[slot] = logicalRow
        }
    }
}

/// Carry a grid's pending redraw rows with the content a row shift moved.
///
/// `remapSurfaceRowSlots` rotates logical rows onto other slots, so a row marked
/// before the shift describes content that is no longer there: with the GPU blit
/// accepted, the row it moved TO is never repainted and keeps what the copy
/// dragged into it. `rowsDelta > 0` means content moved up, so what was row
/// `r + rowsDelta` is now row `r`.
///
/// The vacated band is marked, not cleared: those rows lost their vertices and
/// have to be repainted regardless. Mirrors Windows `shiftRowBits`, including
/// its no-op guards -- the core never stages a shift at or past the region
/// height, and `remapSurfaceRowSlots` declines the same ones.
func shiftSurfaceRowIndices(
    _ rows: inout IndexSet,
    rowStart: Int,
    rowEnd: Int,
    rowsDelta: Int
) {
    guard rowsDelta != 0, rowEnd > rowStart, rowStart >= 0 else { return }
    let shift = abs(rowsDelta)
    guard shift < rowEnd - rowStart else { return }

    let region = rowStart..<rowEnd
    var moved = IndexSet()
    for row in rows.intersection(IndexSet(integersIn: region)) {
        let destination = row - rowsDelta
        if region.contains(destination) { moved.insert(destination) }
    }
    rows.remove(integersIn: region)
    rows.formUnion(moved)

    let vacatedStart = rowsDelta > 0 ? rowEnd - shift : rowStart
    rows.insert(integersIn: vacatedStart..<(vacatedStart + shift))
}

/// Carry the marks a published row shift moved, for a surface whose in-bracket
/// marks land in `pending` as well as in its own flush set.
///
/// A shift is published by the commit, not by the callback that staged it: a
/// bracket that cancels leaves the committed rows where they were, so marks an
/// earlier bracket left have to be shifted against the shift that actually
/// reached the screen. But the core dispatches every row-shift hint before it
/// generates any vertices for that flush (`dispatchGridRowScroll` in
/// src/core/flush.zig runs ahead of the vertex passes), so marks this bracket
/// made already name post-shift rows and must be left alone.
///
/// The two groups are told apart by `carried`, a snapshot of `pending` taken
/// when the bracket opened — NOT by subtracting this bracket's marks. A row
/// number can be in both groups at once and mean different rows: with one
/// scroll between them, an old mark on row 7 describes content now at row 6
/// while a new mark on row 7 describes what was just drawn there, and both
/// rows have to be repainted. Deriving one group from the other collapses that
/// pair into a single mark and leaves row 6 stale.
func mergePublishedScrollDirtyRows(
    pending: inout IndexSet,
    carried: IndexSet,
    rowStart: Int,
    rowEnd: Int,
    rowsDelta: Int
) {
    var shifted = carried
    shiftSurfaceRowIndices(&shifted, rowStart: rowStart, rowEnd: rowEnd, rowsDelta: rowsDelta)
    // The carried marks name pre-shift rows and are replaced by where their
    // content went; anything else in `pending` is this bracket's and stays.
    pending.subtract(carried)
    pending.formUnion(shifted)
}

/// Copy buffer set state from source to destination for the start of a new flush.
/// Before copying src's buffer references into dst's independently-owned Array,
/// dst's own buffers are saved into the detach pool. On buffer detach, pool buffers
/// are reused instead of calling device.makeBuffer(), keeping the total
/// MTLBuffer count bounded at 3 sets × rows.
func copySurfaceBufferSetRowState(from src: SurfaceBufferSet, to dst: SurfaceBufferSet) {
    let destinationRowsBeforeCopy = dst.knownTotalRows
    let destinationColsBeforeCopy = dst.knownTotalCols
    // Save dst's own row buffers into the detach pool before overwriting. Copy
    // into independently-owned, retained-capacity Arrays: assigning the Arrays
    // here would share Swift backing storage and force an O(rows) COW allocation
    // on the first row mutation of every flush.
    dst.detachPoolRowBuffers.removeAll(keepingCapacity: true)
    dst.detachPoolRowBuffers.append(contentsOf: dst.rowState.buffers)
    dst.detachPoolRowCapacities.removeAll(keepingCapacity: true)
    dst.detachPoolRowCapacities.append(contentsOf: dst.rowState.capacities)
    dst.knownTotalRows = src.knownTotalRows
    dst.knownTotalCols = src.knownTotalCols
    dst.fontGeneration = src.fontGeneration
    dst.rowState.buffers.removeAll(keepingCapacity: true)
    dst.rowState.buffers.append(contentsOf: src.rowState.buffers)
    dst.rowState.capacities.removeAll(keepingCapacity: true)
    dst.rowState.capacities.append(contentsOf: src.rowState.capacities)
    dst.rowState.counts.removeAll(keepingCapacity: true)
    dst.rowState.counts.append(contentsOf: src.rowState.counts)
    dst.rowState.usingRowBuffers = src.rowState.usingRowBuffers
    dst.rowLogicalToSlot.removeAll(keepingCapacity: true)
    dst.rowLogicalToSlot.append(contentsOf: src.rowLogicalToSlot)
    dst.rowSlotSourceRows.removeAll(keepingCapacity: true)
    dst.rowSlotSourceRows.append(contentsOf: src.rowSlotSourceRows)
    if src.knownTotalRows < destinationRowsBeforeCopy {
        // Evict after installing the source mapping. Scroll remaps make the
        // logical tail a non-contiguous set of physical slots; using dst's old
        // mapping here could release a still-live copied row and retain an old
        // tail buffer. This single scan clears copied row references plus the
        // write set's detach/private candidates for exactly the new tail.
        evictSurfaceRowsOutsideLogicalRange(
            bufferSet: dst,
            totalRows: src.knownTotalRows
        )
    }
    // Zero-column retirement is owned by commit, which can include the newly
    // committed active set. Doing it here would also discard narrow private
    // buffers provisioned for a following zero-to-narrow expansion.
    if src.knownTotalCols > 0, src.knownTotalCols < destinationColsBeforeCopy {
        retireSurfaceRowStorageForContractedLayout(
            bufferSet: dst,
            demandSet: src,
            includeActiveBuffers: false
        )
    }
    // The correct reset for a set two rotations old, so callers must stage a
    // new shift only AFTER the prepare that runs this copy.
    dst.pendingScroll = nil
}

/// Bring only selected logical rows in `dst` up to the committed `src` state.
///
/// This is the steady-state counterpart to `copySurfaceBufferSetRowState` for
/// the main renderer's triple buffer. Each set keeps complete, independently
/// owned metadata arrays, while the renderer records which rows a non-committed
/// set missed. A one-row update can therefore synchronize only the few rows
/// changed since that set was last committed instead of retaining/copying every
/// row reference at the start of the flush.
///
/// Returns false when the two sets do not have the same logical-to-physical
/// mapping. That means a structural operation (scroll/remap/resize) crossed the
/// sparse history; callers must use the full-copy helper in that case.
func copySurfaceBufferSetRows(
    from src: SurfaceBufferSet,
    to dst: SurfaceBufferSet,
    logicalRows: [UInt32],
    maxRowBuffers: Int
) -> Bool {
    // Validate the entire patch before changing dst. Sparse synchronization is
    // a steady-state path: if storage/mapping/pool shape differs, the caller's
    // full-copy fallback owns any required growth and performs one atomic
    // metadata replacement rather than observing a partially patched set.
    for storedRow in logicalRows {
        let logicalRow = Int(storedRow)
        guard logicalRow >= 0,
              logicalRow < src.rowLogicalToSlot.count
        else { return false }

        let slot = src.rowLogicalToSlot[logicalRow]
        guard slot >= 0,
              slot < src.rowState.buffers.count,
              slot < src.rowState.capacities.count,
              slot < src.rowState.counts.count,
              slot < src.rowSlotSourceRows.count,
              slot < maxRowBuffers,
              logicalRow < dst.rowLogicalToSlot.count,
              dst.rowLogicalToSlot[logicalRow] == slot,
              slot < dst.rowState.buffers.count,
              slot < dst.rowState.capacities.count,
              slot < dst.rowState.counts.count,
              slot < dst.rowSlotSourceRows.count,
              slot < dst.detachPoolRowBuffers.count,
              slot < dst.detachPoolRowCapacities.count
        else { return false }
    }

    for storedRow in logicalRows {
        let logicalRow = Int(storedRow)
        let slot = src.rowLogicalToSlot[logicalRow]
        // Preserve dst's previous physical buffer as its detach candidate
        // before installing src's committed reference. ensureSurfaceRowBuffer
        // still rejects candidates aliasing src or an in-flight set.
        dst.detachPoolRowBuffers[slot] = dst.rowState.buffers[slot]
        dst.detachPoolRowCapacities[slot] = dst.rowState.capacities[slot]

        dst.rowState.buffers[slot] = src.rowState.buffers[slot]
        dst.rowState.capacities[slot] = src.rowState.capacities[slot]
        dst.rowState.counts[slot] = src.rowState.counts[slot]
        dst.rowSlotSourceRows[slot] = src.rowSlotSourceRows[slot]
    }

    dst.knownTotalRows = src.knownTotalRows
    dst.knownTotalCols = src.knownTotalCols
    dst.fontGeneration = src.fontGeneration
    dst.rowState.usingRowBuffers = src.rowState.usingRowBuffers
    dst.pendingScroll = nil
    return true
}

/// Bring a freshly picked write set's row state up to date from the set it
/// rotates off, patching only the rows that went stale where that is sound.
///
/// `needsFullSync` is the caller's barrier flag: a structural transition it
/// already knows crossed this set. The second full copy is NOT an
/// optimisation being skipped — a missed structural transition must never be
/// approximated by row patches, because mappings are frame state, not per-row
/// content, so a sparse patch that reports a mapping mismatch falls all the way
/// back to a full copy.
///
/// Returns what it did and how many rows that touched, which both surfaces
/// report under their own perf-log key.
func syncSurfaceWriteSetRowState(
    from src: SurfaceBufferSet,
    to dst: SurfaceBufferSet,
    staleRows: [UInt32],
    needsFullSync: Bool,
    maxRowBuffers: Int
) -> (mode: String, syncedRows: Int) {
    if needsFullSync {
        copySurfaceBufferSetRowState(from: src, to: dst)
        return ("full_barrier", src.rowState.buffers.count)
    }
    if copySurfaceBufferSetRows(
        from: src,
        to: dst,
        logicalRows: staleRows,
        maxRowBuffers: maxRowBuffers
    ) {
        return ("sparse", staleRows.count)
    }
    copySurfaceBufferSetRowState(from: src, to: dst)
    return ("full_mapping_fallback", src.rowState.buffers.count)
}

/// Submit vertices for a single row into a SurfaceBufferSet.
/// Shared between GridSurfaceRenderer and ExternalGridView.
///
/// - Parameters:
///   - target: The buffer set to write into (write set during flush, or committed set)
///   - ptr: Raw pointer to vertex data (nil clears the row). Must point to
///          memory laid out as `Vertex` (same layout as `zonvie_vertex`).
///   - totalCols: Total columns in the grid (used to detect structural shrink)
///   - inflightRowBuffers: Resolves the physical slot index to the same-slot
///          buffers of the sets currently GPU in-flight (up to two; nil when
///          none). Used by ensureSurfaceRowBuffer's alias guard; a closure
///          because the slot is only known after the logical->slot lookup
///          below.
/// Returns false when the row's content could NOT be written (capacity
/// overflow or MTLBuffer allocation failure) — the caller must treat this as
/// a flush failure (abort/cancel + force a resend), not silently commit a
/// buffer set with an empty/stale row. Returns true both on a successful
/// write AND on a legitimate "clear this row" call (nil ptr / count == 0).
@discardableResult
func submitSurfaceRowVertices(
    target: SurfaceBufferSet,
    sourceSet: SurfaceBufferSet?,
    device: MTLDevice,
    rowStart: Int,
    ptr: UnsafeRawPointer?,
    count: Int,
    maxRowBuffers: Int,
    totalRows: Int,
    totalCols: Int,
    allowAllocation: Bool = true,
    inflightRowBuffers: (Int) -> (MTLBuffer?, MTLBuffer?) = { _ in (nil, nil) }
) -> Bool {
    let columnsContracted =
        (sourceSet?.knownTotalCols ?? 0) > totalCols || target.knownTotalCols > totalCols
    prepareSurfaceRowModeSetForWrite(bufferSet: target, totalRows: totalRows, totalCols: totalCols)

    guard rowStart >= 0, rowStart < maxRowBuffers else { return false }
    let row = rowStart

    if allowAllocation {
        ensureSurfaceRowStorage(bufferSet: target, row, maxRowBuffers: maxRowBuffers)
    }
    guard row < target.rowLogicalToSlot.count else { return false }
    let slot = target.rowLogicalToSlot[row]
    guard slot >= 0 && slot < target.rowState.buffers.count else { return false }

    guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, count)),
          neededBytes <= surfaceMaxVertexBufferCapacity
    else {
        target.rowState.counts[slot] = 0
        return false
    }
    if columnsContracted && allowAllocation {
        retireOversizedSurfaceRowStorage(
            bufferSet: target,
            row: slot,
            neededBytes: neededBytes
        )
    }

    guard count > 0, let validPtr = ptr else {
        target.rowState.counts[slot] = 0
        if slot < target.rowSlotSourceRows.count {
            target.rowSlotSourceRows[slot] = row
        }
        return true
    }

    guard let dstBuffer = ensureSurfaceRowBuffer(
        bufferSet: target,
        sourceSet: sourceSet,
        device: device,
        row: slot,
        vertexCount: count,
        maxRowBuffers: maxRowBuffers,
        allowAllocation: allowAllocation,
        inflightRowBuffers: inflightRowBuffers(slot)
    ) else {
        target.rowState.counts[slot] = 0
        return false
    }

    memcpy(dstBuffer.contents(), validPtr, count * MemoryLayout<Vertex>.stride)
    target.rowState.counts[slot] = count
    if slot < target.rowSlotSourceRows.count {
        target.rowSlotSourceRows[slot] = row
    }
    return true
}

/// The scroll entry that displaces `gridId` this frame, or nil when nothing
/// does. `offsets` is sorted by grid_id, which updateScrollOffsets guarantees
/// and the shader's own per-vertex lookup already relies on.
func surfaceScrollOffset(
    gridId: Int64,
    offsets: [GridSurfaceRenderer.ScrollOffset]
) -> GridSurfaceRenderer.ScrollOffset? {
    let key = Int32(truncatingIfNeeded: gridId)
    var lo = 0
    var hi = offsets.count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if offsets[mid].grid_id < key { lo = mid + 1 } else { hi = mid }
    }
    guard lo < offsets.count, offsets[lo].grid_id == key else { return nil }
    return offsets[lo]
}

/// Where a bodily-moved layer actually lands.
///
/// `move_all` translates every one of a layer's vertices, so the layer can be
/// drawn at a shifted origin instead, with no scroll offset bound at all. Clip
/// and geometry then live in one space: the scissor stays the layer's own size
/// and cannot reach a neighbouring layer, which matters because floats stack
/// edge to edge and a layer's background pass overwrites under blur.
/// ExternalGridView.drawHostedLayers does the same for its hosted grids.
///
/// `offset_y` is NDC against the cell-snapped viewport the layer transform maps
/// into, so `viewportHeightPx` recovers pixels exactly; +y is down in the pixel
/// space the core emits, hence the negation.
func displacedLayerOriginPx(
    originPx: simd_float2,
    offset: GridSurfaceRenderer.ScrollOffset,
    viewportHeightPx: Float
) -> simd_float2 {
    guard viewportHeightPx > 0, offset.offset_y.isFinite else { return originPx }
    return simd_float2(originPx.x, originPx.y - offset.offset_y * viewportHeightPx / 2)
}

/// A float's two running counters as they stood when its debt was last zero.
struct FloatDebtBaseline: Equatable {
    var anchorRowsUp: Int
    var placementRowsUp: Int
}

/// Rows of scroll compensation a float is carrying that its own placement has
/// not performed.
///
/// A landing hands the anchor a compensation cancelling the rows its content
/// just moved, so the picture does not jump when the flush lands. A float
/// following that anchor inherits the compensation, but Neovim re-places the
/// float through win_float_pos, which need not reach the frontend in the same
/// commit. Between the two the float carries a compensation for a step it has
/// not taken, and is drawn that many rows away from where it belongs.
///
/// Both counters run from whenever their grid first appeared, so they are only
/// comparable against a common zero: `baseline` is where the two agreed.
/// The result is zero whenever the pair arrives together, which is the case
/// that already worked and must stay untouched.
func floatDebtRowsUp(
    anchorRowsUp: Int,
    placementRowsUp: Int,
    baseline: FloatDebtBaseline
) -> Int {
    (anchorRowsUp - baseline.anchorRowsUp) - (placementRowsUp - baseline.placementRowsUp)
}

/// Clip a layer rect to the render target. Returns nil when nothing of it is
/// visible, so the caller can skip the draw entirely.
func clampScissor(
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    targetWidth: Int,
    targetHeight: Int
) -> MTLScissorRect? {
    guard targetWidth > 0, targetHeight > 0, width > 0, height > 0 else { return nil }
    let left = max(0, x)
    let top = max(0, y)
    let right = min(targetWidth, x + width)
    let bottom = min(targetHeight, y + height)
    guard right > left, bottom > top else { return nil }
    return MTLScissorRect(x: left, y: top, width: right - left, height: bottom - top)
}

/// The geometry every row this frame draws is placed with: a cell's height,
/// how wide and tall a full-width band is, and the render target rows are
/// clipped to.
///
/// All six are settled once the frame's metrics and back texture are known, and
/// both surfaces then recomputed them at each row-drawing call site — the same
/// `Int(cellHi)`, the same `backTex.width`/`.height`, the same
/// `vpWidth > 0 ? vpWidth : drawableSize.width` fallback, six times each. They
/// are decided once a frame, so they are stated once a frame.
struct SurfaceRowGeometry {
    let cellHeightPx: Int
    let drawableWidthPx: Int
    let renderTargetWidthPx: Int
    let renderTargetHeightPx: Int
    let bandWidthPx: Float
    let bandHeightPx: Float

    init(
        cellHeightPx: Int,
        renderTarget: MTLTexture,
        viewportMetrics: SurfaceViewportMetrics,
        drawableSize: CGSize
    ) {
        self.cellHeightPx = cellHeightPx
        // Both surfaces derived this the same way from the drawable; there is
        // no reason for either to hand it in.
        self.drawableWidthPx = max(0, Int(drawableSize.width.rounded(.down)))
        self.renderTargetWidthPx = renderTarget.width
        self.renderTargetHeightPx = renderTarget.height
        // A viewport of zero means "not resolved yet"; the drawable is the only
        // size known to be real then.
        let vw = viewportMetrics.viewportWidth
        let vh = viewportMetrics.viewportHeight
        self.bandWidthPx = Float(vw > 0 ? vw : Double(drawableSize.width))
        self.bandHeightPx = Float(vh > 0 ? vh : Double(drawableSize.height))
    }
}

func makeRowScissorRect(
    row: Int,
    cellHeight_px: Int,
    drawableWidth_px: Int,
    renderTargetWidth_px: Int,
    renderTargetHeight_px: Int
) -> MTLScissorRect? {
    guard row >= 0, drawableWidth_px > 0, cellHeight_px > 0,
          renderTargetWidth_px > 0, renderTargetHeight_px > 0
    else { return nil }
    let (y, overflow) = row.multipliedReportingOverflow(by: cellHeight_px)
    guard !overflow, y < renderTargetHeight_px else { return nil }
    let width = min(drawableWidth_px, renderTargetWidth_px)
    let height = min(cellHeight_px, renderTargetHeight_px - y)
    guard width > 0, height > 0 else { return nil }
    return MTLScissorRect(x: 0, y: y, width: width, height: height)
}

// MARK: - Fixed-Float Mask Geometry

/// Build the fragment-shader fixed-float mask (bands plus z-carrying interval
/// segments) from fixed-float rects. Pure geometry, shared between the
/// renderer and the standalone test harness. Where rects overlap within a
/// band, intervals are split at the rects' x edges and each segment carries
/// the MAX zindex of the rects covering it, so the shader's per-fragment
/// z comparison needs a single lookup. Outputs and scratch buffers retain
/// capacity; the steady path allocates nothing.
func buildSurfaceFixedFloatMask(
    rects: [GridSurfaceRenderer.FixedFloatRect],
    bands: inout [GridSurfaceRenderer.FixedFloatBand],
    intervals: inout [GridSurfaceRenderer.FixedFloatInterval],
    yEdgesScratch: inout [Float],
    xEdgesScratch: inout [Float],
    coveringScratch: inout [GridSurfaceRenderer.FixedFloatRect]
) {
    bands.removeAll(keepingCapacity: true)
    intervals.removeAll(keepingCapacity: true)
    yEdgesScratch.removeAll(keepingCapacity: true)

    guard !rects.isEmpty else { return }

    for rect in rects where rect.x0 < rect.x1 && rect.top < rect.bottom {
        yEdgesScratch.append(rect.top)
        yEdgesScratch.append(rect.bottom)
    }
    guard yEdgesScratch.count >= 2 else { return }

    yEdgesScratch.sort(by: <)
    dedupSortedSurfaceEdges(&yEdgesScratch)

    for edgeIndex in 0..<(yEdgesScratch.count - 1) {
        let top = yEdgesScratch[edgeIndex]
        let bottom = yEdgesScratch[edgeIndex + 1]
        let sampleY = (top + bottom) * 0.5

        coveringScratch.removeAll(keepingCapacity: true)
        xEdgesScratch.removeAll(keepingCapacity: true)
        for rect in rects
            where rect.x0 < rect.x1 && sampleY > rect.top && sampleY < rect.bottom
        {
            coveringScratch.append(rect)
            xEdgesScratch.append(rect.x0)
            xEdgesScratch.append(rect.x1)
        }
        guard !coveringScratch.isEmpty else { continue }
        xEdgesScratch.sort(by: <)
        dedupSortedSurfaceEdges(&xEdgesScratch)

        // Assign each x segment the max z of the rects covering it; merge
        // contiguous segments with equal z so the common non-overlapping
        // case emits exactly one interval per rect, as before.
        let start = intervals.count
        var pending: GridSurfaceRenderer.FixedFloatInterval?
        for xIndex in 0..<(xEdgesScratch.count - 1) {
            let x0 = xEdgesScratch[xIndex]
            let x1 = xEdgesScratch[xIndex + 1]
            let sampleX = (x0 + x1) * 0.5
            var maxZ: Int32?
            for rect in coveringScratch where sampleX > rect.x0 && sampleX < rect.x1 {
                maxZ = max(maxZ ?? rect.zindex, rect.zindex)
            }
            guard let z = maxZ else {
                if let flushed = pending {
                    intervals.append(flushed)
                    pending = nil
                }
                continue
            }
            let zf = Float(z)
            if var merged = pending, merged.x1 == x0, merged.z == zf {
                merged.x1 = x1
                pending = merged
            } else {
                if let flushed = pending { intervals.append(flushed) }
                pending = GridSurfaceRenderer.FixedFloatInterval(x0: x0, x1: x1, z: zf)
            }
        }
        if let flushed = pending { intervals.append(flushed) }
        guard intervals.count > start else { continue }
        bands.append(GridSurfaceRenderer.FixedFloatBand(
            top: top,
            bottom: bottom,
            intervalStart: UInt32(start),
            intervalCount: UInt32(intervals.count - start)
        ))
    }
}

/// In-place dedup of a sorted edge list (exact float equality is intended:
/// edges come from identical cell-grid products, not accumulated math).
private func dedupSortedSurfaceEdges(_ values: inout [Float]) {
    guard values.count > 1 else { return }
    var uniqueCount = 1
    for i in 1..<values.count where values[i] != values[uniqueCount - 1] {
        values[uniqueCount] = values[i]
        uniqueCount += 1
    }
    if uniqueCount < values.count {
        values.removeLast(values.count - uniqueCount)
    }
}

// MARK: - Surface Encoder Binding Helpers

/// Bind scroll offset data to a render encoder, with a dummy entry standing in
/// for an empty array.
func bindSurfaceScrollOffsets(
    encoder: MTLRenderCommandEncoder,
    offsets: [GridSurfaceRenderer.ScrollOffset],
    device: MTLDevice,
    scratchBuffer: inout MTLBuffer?,
    scratchCapacity: inout Int
) {
    let maxSetVertexBytesSize = 4096
    var effectiveCount = UInt32(offsets.count)
    if !offsets.isEmpty {
        offsets.withUnsafeBytes { ptr in
            if ptr.count <= maxSetVertexBytesSize {
                encoder.setVertexBytes(ptr.baseAddress!, length: ptr.count, index: 1)
            } else {
                // Rare path (256+ simultaneous scroll offsets). Reuse the
                // caller's persistent per-set scratch buffer instead of
                // calling device.makeBuffer() fresh every time this
                // triggers — see the SurfaceBufferSet field comments for
                // why overwriting it here is safe.
                if scratchBuffer == nil || scratchCapacity < ptr.count {
                    scratchBuffer = device.makeBuffer(length: ptr.count, options: .storageModeShared)
                    scratchCapacity = scratchBuffer != nil ? ptr.count : 0
                }
                if let buf = scratchBuffer {
                    memcpy(buf.contents(), ptr.baseAddress!, ptr.count)
                    encoder.setVertexBuffer(buf, offset: 0, index: 1)
                } else {
                    var dummy = GridSurfaceRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                    encoder.setVertexBytes(&dummy, length: MemoryLayout<GridSurfaceRenderer.ScrollOffset>.stride, index: 1)
                    effectiveCount = 0
                }
            }
        }
    } else {
        var dummy = GridSurfaceRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
        encoder.setVertexBytes(&dummy, length: MemoryLayout<GridSurfaceRenderer.ScrollOffset>.stride, index: 1)
    }
    encoder.setVertexBytes(&effectiveCount, length: MemoryLayout<UInt32>.size, index: 2)
}

/// Bind the zero-or-one scroll offset used by an external grid without
/// constructing a temporary Swift Array in the per-frame draw path.
func bindSingleSurfaceScrollOffset(
    encoder: MTLRenderCommandEncoder,
    offset: GridSurfaceRenderer.ScrollOffset?
) {
    var effectiveCount: UInt32 = 0
    if var value = offset {
        encoder.setVertexBytes(
            &value,
            length: MemoryLayout<GridSurfaceRenderer.ScrollOffset>.stride,
            index: 1
        )
        effectiveCount = 1
    } else {
        var dummy = GridSurfaceRenderer.ScrollOffset(
            grid_id: 0,
            offset_y: 0,
            content_top_y: 0,
            content_bottom_y: 0
        )
        encoder.setVertexBytes(
            &dummy,
            length: MemoryLayout<GridSurfaceRenderer.ScrollOffset>.stride,
            index: 1
        )
    }
    encoder.setVertexBytes(&effectiveCount, length: MemoryLayout<UInt32>.size, index: 2)
}

/// Bind fragment-side state shared by all surface draw passes:
/// drawable size, background alpha buffer, and cursor blink buffer.
/// One surface's fixed-float mask: the rectangles scrolled content must not
/// bleed over, kept in the band/interval form the fragment shader binary-
/// searches, and rebuilt only when the rectangles actually change.
///
/// Every surface that hosts layers owes one. The main renderer was the only
/// one that kept it, so `bindSurfaceFragmentState` fell back to its zero-band
/// default on every external surface and the shader guard was dead there —
/// even though an external window hosts floats and eases its own scrolls.
final class SurfaceFixedFloatMask {
    /// One entry beyond this selects the cell-aligned fallback instead of a
    /// partial mask, which would let shifted content bleed through an omitted
    /// float.
    static let maxRects = 16

    private(set) var bands: [GridSurfaceRenderer.FixedFloatBand] = []
    private(set) var intervals: [GridSurfaceRenderer.FixedFloatInterval] = []
    private var input: [GridSurfaceRenderer.FixedFloatRect] = []
    private var overflowed = false
    private var yEdgesScratch: [Float] = []
    private var xEdgesScratch: [Float] = []
    private var coveringScratch: [GridSurfaceRenderer.FixedFloatRect] = []

    /// False when the union cannot be represented. A partial transform is
    /// visibly wrong, so the caller must drop the whole scroll transform rather
    /// than mask part of it.
    @discardableResult
    func update(_ rects: [GridSurfaceRenderer.FixedFloatRect]) -> Bool {
        if rects.count > Self.maxRects {
            if !overflowed {
                input.removeAll(keepingCapacity: true)
                bands.removeAll(keepingCapacity: true)
                intervals.removeAll(keepingCapacity: true)
                yEdgesScratch.removeAll(keepingCapacity: true)
                overflowed = true
            }
            return false
        }
        if !overflowed && rects == input { return true }
        overflowed = false
        input.removeAll(keepingCapacity: true)
        input.append(contentsOf: rects)
        buildSurfaceFixedFloatMask(
            rects: rects,
            bands: &bands,
            intervals: &intervals,
            yEdgesScratch: &yEdgesScratch,
            xEdgesScratch: &xEdgesScratch,
            coveringScratch: &coveringScratch
        )
        return true
    }
}

func bindSurfaceFragmentState(
    encoder: MTLRenderCommandEncoder,
    viewportMetrics: SurfaceViewportMetrics,
    backgroundAlphaBuffer: MTLBuffer?,
    cursorBlinkBuffer: MTLBuffer?,
    cursorBlinkVisible: Bool,
    fixedFloatBands: [GridSurfaceRenderer.FixedFloatBand] = [],
    fixedFloatIntervals: [GridSurfaceRenderer.FixedFloatInterval] = []
) {
    var size = DrawableSize(width: viewportMetrics.fragmentWidth, height: viewportMetrics.fragmentHeight)
    encoder.setFragmentBytes(&size, length: MemoryLayout<DrawableSize>.size, index: 0)

    if let alphaBuf = backgroundAlphaBuffer {
        encoder.setFragmentBuffer(alphaBuf, offset: 0, index: 1)
    }

    if let blinkBuf = cursorBlinkBuffer {
        var visible: UInt32 = cursorBlinkVisible ? 1 : 0
        memcpy(blinkBuf.contents(), &visible, MemoryLayout<UInt32>.size)
        encoder.setFragmentBuffer(blinkBuf, offset: 0, index: 2)
    }

    // Exact fixed-float union (fragment buffers 3/4/5). Bands and their
    // interval slices are both sorted and disjoint, so each fragment needs
    // two binary searches instead of a linear scan over every float.
    let bandStride = MemoryLayout<GridSurfaceRenderer.FixedFloatBand>.stride
    let intervalStride = MemoryLayout<GridSurfaceRenderer.FixedFloatInterval>.stride
    var fixedBandCount = UInt32(fixedFloatBands.count)
    if fixedFloatBands.isEmpty {
        var dummyBand = GridSurfaceRenderer.FixedFloatBand(top: 0, bottom: 0, intervalStart: 0, intervalCount: 0)
        encoder.setFragmentBytes(&dummyBand, length: bandStride, index: 3)
    } else {
        fixedFloatBands.withUnsafeBytes { ptr in
            encoder.setFragmentBytes(ptr.baseAddress!, length: fixedFloatBands.count * bandStride, index: 3)
        }
    }
    encoder.setFragmentBytes(&fixedBandCount, length: MemoryLayout<UInt32>.size, index: 4)
    if fixedFloatIntervals.isEmpty {
        var dummyInterval = GridSurfaceRenderer.FixedFloatInterval(x0: 0, x1: 0)
        encoder.setFragmentBytes(&dummyInterval, length: intervalStride, index: 5)
    } else {
        fixedFloatIntervals.withUnsafeBytes { ptr in
            encoder.setFragmentBytes(ptr.baseAddress!, length: fixedFloatIntervals.count * intervalStride, index: 5)
        }
    }
}

/// Encode non-row-mode content draw (2-pass for blur, or single-pass with optional scissor).
func encodeSurfaceNonRowContent(
    encoder: MTLRenderCommandEncoder,
    vertexBuffer: MTLBuffer?,
    vertexCount: Int,
    pipeline: MTLRenderPipelineState,
    backgroundPipeline: MTLRenderPipelineState?,
    glyphPipeline: MTLRenderPipelineState?,
    useTwoPass: Bool,
    scissorRect: MTLScissorRect? = nil,
    unifiedBlurPipeline: MTLRenderPipelineState? = nil
) {
    guard vertexCount > 0, let vb = vertexBuffer else { return }

    var zeroTranslation: Float = 0
    encoder.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)

    // Single-pass via programmable blending supersedes 2-pass when available.
    if useTwoPass, let unified = unifiedBlurPipeline {
        encoder.setRenderPipelineState(unified)
        if let sr = scissorRect {
            encoder.setScissorRect(sr)
        }
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    } else if useTwoPass, let bgPipe = backgroundPipeline, let glyphPipe = glyphPipeline {
        encoder.setRenderPipelineState(bgPipe)
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)

        encoder.setRenderPipelineState(glyphPipe)
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    } else {
        encoder.setRenderPipelineState(pipeline)
        if let sr = scissorRect {
            encoder.setScissorRect(sr)
        }
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}

// MARK: - Bloom (Neon Glow) Shared Helpers

/// The bloom chain's geometry: how large each scratch texture is, and which
/// one every pass reads and writes.
///
/// The arithmetic is the core's (`src/core/glow_chain.zig`,
/// `zonvie_core_glow_chain_plan`), so both frontends step the same ladder.
/// This is a plain value rather than the C struct because build.zig hands this
/// file to swiftc on its own, with no ZonvieCore; the callers translate.
struct SurfaceGlowChain {
    static let mipCount = 3
    /// A pass's source or destination: this, or a mip index.
    static let extractTarget = -1

    struct Pass {
        var src: Int
        var dst: Int
        var dstWidthPx: Int
        var dstHeightPx: Int
    }

    var halfWidthPx: Int
    var halfHeightPx: Int
    var mipWidthPx: [Int]
    var mipHeightPx: [Int]
    /// Only the passes to run. How many there are follows the radius: a tight
    /// one stops a level short of the smallest mip. The extents above do not,
    /// so the textures need no resize when the radius changes.
    var down: [Pass]
    var up: [Pass]
}

/// Shared glow texture state managed per-view (sizes differ per window).
final class SurfaceGlowTextures {
    var extractTex: MTLTexture?
    var mipTextures: [MTLTexture?] = [nil, nil, nil]
    var texSize: CGSize = .zero
    var intensityBuffer: MTLBuffer?

    /// Ensure the glow textures exist at the sizes `chain` gives. The chain is
    /// sized from the drawable, not the grid viewport, so blur can bleed into
    /// the margins.
    @discardableResult
    func ensure(device: MTLDevice, chain: SurfaceGlowChain, pixelFormat: MTLPixelFormat) -> Bool {
        let halfSize = CGSize(width: chain.halfWidthPx, height: chain.halfHeightPx)
        if extractTex != nil, mipTextures.allSatisfy({ $0 != nil }), texSize == halfSize { return true }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.pixelFormat = pixelFormat
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        desc.mipmapLevelCount = 1

        desc.width = max(1, Int(halfSize.width))
        desc.height = max(1, Int(halfSize.height))
        guard let newExtract = device.makeTexture(descriptor: desc) else { return false }

        var newMips: [MTLTexture?] = [nil, nil, nil]
        for i in 0..<SurfaceGlowChain.mipCount {
            desc.width = chain.mipWidthPx[i]
            desc.height = chain.mipHeightPx[i]
            guard let mip = device.makeTexture(descriptor: desc) else { return false }
            newMips[i] = mip
        }
        extractTex = newExtract
        mipTextures = newMips
        texSize = halfSize
        return true
    }

    @discardableResult
    func ensureIntensityBuffer(device: MTLDevice) -> Bool {
        if intensityBuffer == nil {
            intensityBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
        }
        return intensityBuffer != nil
    }
}

/// Encode bloom post-process passes (extract → downsample → upsample → composite).
/// The extract pass draws vertices via the `encodeExtractVertices` closure, which
/// receives the encoder with pipeline/viewport/fragment state already configured.
///
/// - `viewportSize`: grid-snapped pixel dimensions matching the main render pass viewport.
///   Used for the extract viewport only; NDC is viewport relative, so the half-size
///   viewport keeps the NDC ↔ pixel mapping aligned with the main pass.
/// - `drawableSize`: raw drawable pixel dimensions. Used for extract texture sizing so that
///   blur can bleed beyond the grid viewport into surrounding margin areas.
/// - `layerTransform`: the pixel space the extract vertices arrive in. Bound before the
///   closure runs so no call site can forget it; a closure that draws several layers
///   rebinds it per layer.
///
/// Returns true if bloom was applied.
@discardableResult
func encodeSurfaceBloomPasses(
    cmd: MTLCommandBuffer,
    backTex: MTLTexture,
    viewportSize: CGSize,
    drawableSize: CGSize,
    viewportOrigin: CGPoint = .zero,
    layerTransform: LayerTransform,
    glowTextures: SurfaceGlowTextures,
    extractPipeline: MTLRenderPipelineState,
    kawaseDownPipeline: MTLRenderPipelineState,
    kawaseUpPipeline: MTLRenderPipelineState,
    compositePipeline: MTLRenderPipelineState,
    copyVertexBuffer: MTLBuffer,
    bilinearSampler: MTLSamplerState,
    intensity: Float,
    chain: SurfaceGlowChain,
    /// `vim.g.zonvie_glow.radius` as a tap-offset multiplier; 1.0 is the
    /// default radius. It sets how far each Kawase tap reaches; how deep the
    /// chain goes is already decided, in `chain`.
    radiusScale: Float,
    encodeExtractVertices: (MTLRenderCommandEncoder) -> Void
) -> Bool {
    guard let extractTex = glowTextures.extractTex,
          glowTextures.mipTextures.allSatisfy({ $0 != nil }),
          let intensityBuf = glowTextures.intensityBuffer
    else { return false }

    intensityBuf.contents().storeBytes(of: intensity, as: Float.self)

    let halfW = max(1, Int(viewportSize.width / 2.0))
    let halfH = max(1, Int(viewportSize.height / 2.0))
    let extractViewport = MTLViewport(originX: viewportOrigin.x / 2.0, originY: viewportOrigin.y / 2.0,
                                       width: Double(halfW), height: Double(halfH),
                                       znear: 0, zfar: 1)

    // Pass 1: Glow extract
    let extractRPD = MTLRenderPassDescriptor()
    extractRPD.colorAttachments[0].texture = extractTex
    extractRPD.colorAttachments[0].loadAction = .clear
    extractRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    extractRPD.colorAttachments[0].storeAction = .store

    guard let extractEnc = cmd.makeRenderCommandEncoder(descriptor: extractRPD) else { return false }
    extractEnc.setRenderPipelineState(extractPipeline)
    extractEnc.setViewport(extractViewport)
    // Vertices are in their layer's own pixel space. The extract viewport is
    // half-size, but NDC is viewport relative, so the same transform maps correctly.
    bindLayerTransform(encoder: extractEnc, layerTransform)
    encodeExtractVertices(extractEnc)
    extractEnc.endEncoding()

    // Down then up, both the same shape: bind the pass's target, size the
    // viewport to it, bind its source, draw. Which texture each end is comes
    // from the core's plan.
    func glowTexture(_ target: Int) -> MTLTexture? {
        target == SurfaceGlowChain.extractTarget ? extractTex : glowTextures.mipTextures[target]
    }
    for (stage, passes) in [chain.down, chain.up].enumerated() {
        for pass in passes {
            guard let srcTex = glowTexture(pass.src), let dstTex = glowTexture(pass.dst) else { return false }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dstTex
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store

            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            enc.setRenderPipelineState(stage == 0 ? kawaseDownPipeline : kawaseUpPipeline)
            var radius = radiusScale
            enc.setFragmentBytes(&radius, length: MemoryLayout<Float>.size, index: 0)
            enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                         width: Double(pass.dstWidthPx), height: Double(pass.dstHeightPx),
                                         znear: 0, zfar: 1))
            enc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(srcTex, index: 0)
            enc.setFragmentSamplerState(bilinearSampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }
    }

    // Composite → backBuffer (additive blend)
    let compositeRPD = MTLRenderPassDescriptor()
    compositeRPD.colorAttachments[0].texture = backTex
    compositeRPD.colorAttachments[0].loadAction = .load
    compositeRPD.colorAttachments[0].storeAction = .store

    guard let compositeEnc = cmd.makeRenderCommandEncoder(descriptor: compositeRPD) else { return false }
    compositeEnc.setRenderPipelineState(compositePipeline)
    // No explicit viewport: default = full backBuffer so blur bleed
    // extends naturally into margin areas beyond the grid viewport.
    compositeEnc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
    compositeEnc.setFragmentTexture(extractTex, index: 0)
    compositeEnc.setFragmentSamplerState(bilinearSampler, index: 0)
    compositeEnc.setFragmentBuffer(intensityBuf, offset: 0, index: 0)
    compositeEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    compositeEnc.endEncoding()

    return true
}

// MARK: - Row Capacity Provisioning

/// What a surface's flush found missing, and whether a provisioning pass is
/// already running. Both surfaces keep exactly these fields, guarded by the
/// surface's own triple-buffer lock — which is why the lock is handed to the
/// provisioner rather than owned here.
final class SurfaceRowCapacityLedger {
    var hardFailure = false
    var requiredRows = 0
    var requiredVertexCounts: [Int]
    var provisioning = false

    init(maxRowBuffers: Int) {
        requiredVertexCounts = [Int](repeating: 0, count: maxRowBuffers)
    }
}


// MARK: - Background Clear Band

/// Draw the solid background band a scroll blit vacated, in the pixel space of
/// whatever layer transform is currently bound: the surface for a root-grid
/// band, the layer's own rect for a layer's band.
///
/// The vertex stage binary-searches scrollOffsets by grid_id, so a band must
/// carry the id of the grid it covers: tagging a layer's band with the root's
/// id would move it by the root's scroll offset.
func drawSurfaceBackgroundClearBand(
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
    _ = drawableHeight
    let x0 = xRangePx.leftPx
    let x1 = xRangePx.rightPx
    guard x1 > x0 else { return }
    let y0 = Float(top)
    let y1 = Float(bottom)
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


/// Copy `input` into `output` through a fullscreen render pass.
///
/// A render pass rather than an MTLBlitCommandEncoder: a blit's internal
/// shaders cannot be cached in an MTLBinaryArchive, and the XPC compiler
/// service is unavailable after fork() — which is exactly where this path is
/// the last step between a finished back buffer and the screen.
///
/// `prepare` runs on the descriptor before the encoder is made; the main
/// surface attaches its GPU counter samples there.
/// backTex -> drawable: the custom post-process chain when one is configured
/// for `.afterBloom`, otherwise the plain copy pass.
///
/// Both surfaces wrote this ladder out — the same four conditions in the same
/// order, the same fall-through, the same "encoded nothing" answer — and
/// differed only in two places, which are the two closures. The uniforms differ
/// because an external window's screen-space origin is not the main window's;
/// `prepareCopy` differs because only the main surface attaches GPU performance
/// samples to the copy pass.
///
/// `makeUniforms` is a closure rather than a value: building them costs a
/// cursor-shader evaluation on the external side, and the chain only runs when
/// all four conditions hold.
///
/// `.notEncoded` means nothing could be encoded. Both callers read that as
/// "submit what is already encoded, present nothing, and do not consume this
/// frame's state" — the drawable would otherwise be presented untouched.
/// The blink fast path: one row, scissored, redrawn in place so the old cursor
/// is erased and the new one drawn without touching any other pixel.
///
/// Single pass through the unified blur pipeline when one exists; the two-pass
/// background-then-glyph fallback otherwise, which is the rule every other
/// `use2Pass` branch follows — the background pass overwrites, which is what
/// erases the old cursor, and the glyph pass blends the text back over it.
///
/// Both surfaces had this written out, identical apart from where each keeps
/// the cursor's row. A row whose scissor cannot be formed encodes nothing: the
/// row is outside the render target, and drawing it unscissored would repaint
/// the wrong band.
func encodeSurfaceBlinkFastPathRow(
    encoder: MTLRenderCommandEncoder,
    row: Int,
    resolved: (vc: Int, vb: MTLBuffer, translationY: Float),
    geometry: SurfaceRowGeometry,
    backgroundPipeline: MTLRenderPipelineState?,
    glyphPipeline: MTLRenderPipelineState?,
    unifiedBlurPipeline: MTLRenderPipelineState?
) {
    guard let scissor = makeRowScissorRect(
        row: row,
        cellHeight_px: geometry.cellHeightPx,
        drawableWidth_px: geometry.drawableWidthPx,
        renderTargetWidth_px: geometry.renderTargetWidthPx,
        renderTargetHeight_px: geometry.renderTargetHeightPx
    ) else { return }
    encoder.setScissorRect(scissor)
    var rowTranslation = resolved.translationY
    func draw(_ pipeline: MTLRenderPipelineState) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rowTranslation, length: MemoryLayout<Float>.size, index: 3)
        encoder.setVertexBuffer(resolved.vb, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: resolved.vc)
    }
    if let unified = unifiedBlurPipeline {
        draw(unified)
        return
    }
    if let bg = backgroundPipeline { draw(bg) }
    if let glyph = glyphPipeline { draw(glyph) }
}

/// The cursor, composited onto the drawable after the copy.
///
/// It goes on the drawable and never into the back buffer, so a GPU scroll copy
/// cannot drag stale cursor pixels, and so nothing repaints over it — which is
/// also why the fixed-float mask has to be bound here: without it a cursor
/// easing with a scroll slides across a hosted fixed float instead of being
/// discarded under it.
///
/// Both surfaces wrote this pass out in full. The two that could not be plain
/// parameters are closures: `prepare` because only the main surface attaches GPU
/// performance samples, and `bindScrollOffsets` because the main surface binds
/// an array of per-grid offsets where an external one binds the single offset of
/// the grid that owns the cursor.
///
/// Returns false when the encoder could not be created. Both callers treat that
/// as "submit what is encoded, present nothing": presenting the copy without the
/// cursor it was asked for would consume the cursor revision and leave a
/// visibly incomplete transaction.
func encodeSurfaceCursorOverlay(
    cmd: MTLCommandBuffer,
    drawableTexture: MTLTexture,
    pipeline: MTLRenderPipelineState,
    atlasTexture: MTLTexture?,
    sampler: MTLSamplerState,
    viewportMetrics: SurfaceViewportMetrics,
    cursorVertexBuffer: MTLBuffer,
    cursorVertexCount: Int,
    layerOriginPx: simd_float2,
    backgroundAlphaBuffer: MTLBuffer?,
    cursorBlinkBuffer: MTLBuffer?,
    fixedFloatBands: [GridSurfaceRenderer.FixedFloatBand],
    fixedFloatIntervals: [GridSurfaceRenderer.FixedFloatInterval],
    prepare: (MTLRenderPassDescriptor) -> Void = { _ in },
    bindScrollOffsets: (MTLRenderCommandEncoder) -> Void
) -> Bool {
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = drawableTexture
    rpd.colorAttachments[0].loadAction = .load
    rpd.colorAttachments[0].storeAction = .store
    prepare(rpd)
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
    viewportMetrics.applyViewport(to: enc)
    enc.setRenderPipelineState(pipeline)
    if let atlasTexture {
        enc.setFragmentTexture(atlasTexture, index: 0)
    }
    enc.setFragmentSamplerState(sampler, index: 0)
    bindScrollOffsets(enc)
    bindSurfaceFragmentState(
        encoder: enc,
        viewportMetrics: viewportMetrics,
        backgroundAlphaBuffer: backgroundAlphaBuffer,
        cursorBlinkBuffer: cursorBlinkBuffer,
        cursorBlinkVisible: true,
        fixedFloatBands: fixedFloatBands,
        fixedFloatIntervals: fixedFloatIntervals
    )
    var zeroTranslation: Float = 0
    enc.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)
    // The cursor is in its own layer's pixel space; applyViewport above set the
    // viewport to the root layer's.
    bindLayerTransform(
        encoder: enc,
        LayerTransform(
            originPx: layerOriginPx,
            extentPx: simd_float2(viewportMetrics.fragmentWidth, viewportMetrics.fragmentHeight)
        )
    )
    enc.setVertexBuffer(cursorVertexBuffer, offset: 0, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cursorVertexCount)
    enc.endEncoding()
    return true
}

func encodeSurfaceDrawableCopy(
    cmd: MTLCommandBuffer,
    input: MTLTexture,
    output: MTLTexture,
    pipeline: MTLRenderPipelineState,
    copyVertexBuffer: MTLBuffer,
    sampler: MTLSamplerState,
    prepare: (MTLRenderPassDescriptor) -> Void
) -> Bool {
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = output
    rpd.colorAttachments[0].loadAction = .dontCare
    rpd.colorAttachments[0].storeAction = .store
    prepare(rpd)
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
    enc.setFragmentTexture(input, index: 0)
    enc.setFragmentSamplerState(sampler, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    enc.endEncoding()
    return true
}

/// Repaint the background band under every dirty row, before the rows
/// themselves are drawn.
///
/// The band spans the whole viewport width, so it also repaints the margin
/// strip beside the row, which the row's own vertices never cover — that strip
/// is why a row that already has content still gets a band. The external
/// surface used to band only rows with no resolvable content and left its
/// margin to whatever the previous frame had.
func encodeSurfaceDirtyRowBands(
    encoder: MTLRenderCommandEncoder,
    rows: [Int],
    pipeline: MTLRenderPipelineState,
    cellHeightPx: Int,
    widthPx: Float,
    heightPx: Float,
    bgRGB: UInt32,
    gridId: Int64
) {
    encoder.setRenderPipelineState(pipeline)
    for row in rows {
        let topPx = row * cellHeightPx
        drawSurfaceBackgroundClearBand(
            encoder,
            clearBand: (clearTopPx: topPx, clearBottomPx: topPx + cellHeightPx),
            xRangePx: (leftPx: 0, rightPx: widthPx),
            drawableHeight: heightPx,
            bgRGB: bgRGB,
            gridId: gridId
        )
    }
}

/// The scissored single-pass dirty-row draw both surfaces perform: band every
/// dirty row, then draw the rows one scissor rect each. Reached from the
/// GPU-scroll-copy arm and from the plain partial-redraw arm.
///
/// Under `.load` a dirty row must overwrite its old pixels rather than draw on
/// top of them: the core drops the root's default-background runs while the
/// surface has layers (flush.zig `skip_default_bg`), so a row that lost or kept
/// a glyph covers neither. Single-pass means no blur, where `backgroundAlpha`
/// is 1.0 and the solid quad overwrites, so one pipeline serves both the bands
/// and the rows.
func encodeSurfaceScissoredDirtyRows(
    encoder: MTLRenderCommandEncoder,
    rows: [Int],
    pipeline: MTLRenderPipelineState,
    resolve: (Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)?,
    geometry: SurfaceRowGeometry,
    bgRGB: UInt32,
    gridId: Int64
) {
    let cellHeightPx = geometry.cellHeightPx
    let bandWidthPx = geometry.bandWidthPx
    let bandHeightPx = geometry.bandHeightPx
    let drawableWidthPx = geometry.drawableWidthPx
    let renderTargetWidthPx = geometry.renderTargetWidthPx
    let renderTargetHeightPx = geometry.renderTargetHeightPx
    encodeSurfaceDirtyRowBands(
        encoder: encoder,
        rows: rows,
        pipeline: pipeline,
        cellHeightPx: cellHeightPx,
        widthPx: bandWidthPx,
        heightPx: bandHeightPx,
        bgRGB: bgRGB,
        gridId: gridId
    )
    _ = encodeSurfaceRowDraws(
        encoder: encoder,
        rows: rows,
        resolve: resolve,
        scissor: { row in
            makeRowScissorRect(
                row: row,
                cellHeight_px: cellHeightPx,
                drawableWidth_px: drawableWidthPx,
                renderTargetWidth_px: renderTargetWidthPx,
                renderTargetHeight_px: renderTargetHeightPx
            )
        },
        pipeline: pipeline,
        backgroundPipeline: nil,
        glyphPipeline: nil,
        useTwoPass: false
    )
}

// MARK: - Shared Surface Timing

/// Resolved once for the process. Both surfaces carried a private copy of this
/// same lazy static to convert their own commit stamps.
private let surfaceMachTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

/// True when a commit landed within `withinNs` of now. `lastCommitTime` is a
/// `mach_absolute_time()` stamp, or 0 for "never committed".
///
/// The draw loop's idle detector uses this so a flush completing between vsync
/// intervals does not read as an idle surface. The caller reads the stamp under
/// its own lock and passes the value, because the two surfaces guard it with
/// differently named locks.
func surfaceHadRecentCommit(lastCommitTime: UInt64, withinNs: UInt64) -> Bool {
    if lastCommitTime == 0 { return false }
    let now = mach_absolute_time()
    let info = surfaceMachTimebaseInfo
    let elapsedNs = (now - lastCommitTime) * UInt64(info.numer) / UInt64(info.denom)
    return elapsedNs < withinNs
}

// MARK: - Shared Off-Screen Surface Textures

/// Descriptor for an off-screen texture sized from a drawable.
///
/// The `max(1, …)` floor is the load-bearing part: a window mid-resize or
/// freshly ordered out reports a zero-sized drawable, and a zero extent is an
/// invalid descriptor. `.private` is the storage mode every texture here wants —
/// nothing reads them back on the CPU.
func makeSurfaceTextureDescriptor(
    size: CGSize,
    pixelFormat: MTLPixelFormat,
    usage: MTLTextureUsage
) -> MTLTextureDescriptor {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: max(1, Int(size.width)),
        height: max(1, Int(size.height)),
        mipmapped: false
    )
    desc.usage = usage
    desc.storageMode = .private
    return desc
}

/// The off-screen texture pair a multi-pass custom shader chain ping-pongs
/// between. Both surfaces size it from their own drawable, so the pair lives
/// with this holder rather than being restated per surface class.
final class SurfacePingPongTextures {
    private(set) var textures: [MTLTexture?] = [nil, nil]
    private(set) var size: CGSize = .zero

    var ready: Bool { textures[0] != nil && textures[1] != nil }

    subscript(index: Int) -> MTLTexture? { textures[index] }

    func invalidate() {
        textures[0] = nil
        textures[1] = nil
        size = .zero
    }

    /// Allocate only when the size changed. This is reached from the present
    /// path every frame a chain is configured, so the size guard is what keeps
    /// texture creation out of the per-frame path.
    func ensure(device: MTLDevice, size newSize: CGSize, pixelFormat: MTLPixelFormat) {
        if ready, size == newSize { return }
        let desc = makeSurfaceTextureDescriptor(
            size: newSize,
            pixelFormat: pixelFormat,
            usage: [.renderTarget, .shaderRead]
        )
        textures[0] = device.makeTexture(descriptor: desc)
        textures[1] = device.makeTexture(descriptor: desc)
        size = newSize
    }
}

/// The off-screen copy of the back buffer a scroll blit reads from, so the
/// shift cannot sample pixels it has already written.
final class SurfaceScrollScratchTexture {
    private(set) var texture: MTLTexture? = nil
    private(set) var size: CGSize = .zero

    func invalidate() {
        texture = nil
        size = .zero
    }

    func ensure(device: MTLDevice, drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        if texture != nil, size == drawableSize { return }
        // `.shaderRead` alone, matching the descriptor default this used to
        // take: the scratch is a blit destination and a sampling source, never
        // a render target.
        let desc = makeSurfaceTextureDescriptor(
            size: drawableSize,
            pixelFormat: pixelFormat,
            usage: .shaderRead
        )
        texture = device.makeTexture(descriptor: desc)
        size = drawableSize
    }
}

