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
/// A row that scrolls off is gone from the buffer sets by draw time: the slot
/// remap rotates it into the vacated band and Neovim writes the incoming row
/// into that same slot during the same flush. Holding the picture back by the
/// scrolled distance therefore needs a copy taken before the slot is reused.
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
/// Shared by the main surface and every external grid window: both keep row
/// buffers under the same slot / source-row contract, both capture inside a
/// flush bracket before the slots rotate, and both publish on commit so a draw
/// can never see a retained row ahead of the vertices it belongs to. Only the
/// copying differs, so that part stays with each surface.
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
    /// Live at once, each set at most `maxRetainedGrids * maxDepthRows` rows:
    /// one snapshot per in-flight frame, the published set, and the set being
    /// staged. External surfaces allow TWO frames in flight (the main renderer
    /// allows one), so the worst case is four sets. `ringSize` below carries
    /// one more on top; a set replaced within a frame is released at once and
    /// pins nothing, but `ringNext` advances past its slots regardless.
    /// Pinned by ScrollRetentionTests' "ringSize must exceed the buffers that
    /// can be live at once".
    static let maxInFlightFrames = 2
    /// Windows that can hold a band at the same time. 'scrollbind' moves two
    /// (:vert diffsplit), and each keeps its own rows, so the ring drains that
    /// many times faster. Enforced in `beginStep`, not merely assumed: the ring
    /// is the only thing keeping a retained buffer alive, so an unbounded grid
    /// count would wrap it onto rows a frame is still reading.
    ///
    /// Set to Neovim's own ceiling on a diff group (E96: at most eight buffers
    /// may have 'diff' set), so no diff can outgrow it. What is reachable in
    /// practice is smaller — `git mergetool --tool=vimdiff` and diffview.nvim's
    /// diff4_mixed both top out at four windows, and `nvim -d` takes at most
    /// four files — but the cap evicts deterministically once it is exceeded,
    /// and the extra slots cost only residency.
    static let maxRetainedGrids = 8
    /// One set per in-flight frame, plus the published set and the one being
    /// staged, times the grids that can each hold their own. Deliberately
    /// without the "several flushes per frame" factor the earlier sizing
    /// carried: a published set replaced within a frame is released
    /// immediately, so it pins nothing and buying headroom for it only doubles
    /// a residency that is never reclaimed. `takeBuffer` walks every slot in
    /// turn, so the whole ring becomes resident after a few seconds of
    /// scrolling in ONE window — the count is a memory figure, not a lazy cap.
    /// One set spare on top of the live ones, because `ringNext` advances on
    /// every take regardless of whether the set it filled was ever drawn: a
    /// bracket landing while a frame is in flight pushes the cursor further
    /// without releasing that frame's snapshot. Sized exactly to the live
    /// count would wrap onto a slot still being read.
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

    func publishedCount(gridId: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return published.reduce(0) { $0 + ($1.gridId == gridId ? 1 : 0) }
    }

    /// Drop everything on screen: a retained row is only meaningful while its
    /// grid is displaced, and with no offset it would draw a row outside real
    /// content.
    ///
    /// Deliberately leaves the STAGED set alone. This is called from the draw
    /// side while the core thread may be mid-bracket, and discarding its
    /// staged rows would make `commit()` report that nothing was staged —
    /// dropping the step, and with it the caller's own per-step state (the
    /// main surface's ease seed), so the picture snaps instead of easing.
    /// An open bracket's rows are the bracket's to publish or abandon.
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
    /// Pure so it can be tested: the view owns the bookkeeping around it, but
    /// the rule itself is the part that has been got wrong repeatedly.
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
            // and nothing would ever evict it again. Re-admit whatever the seed
            // brought, least-recent first (it is not being stepped now), and
            // drop names that hold nothing so a live grid is never the victim
            // in a ghost's place. In place on a list of at most a few entries.
            stepOrder.removeAll { name in !staged.contains { $0.gridId == name } }
            for row in staged where !stepOrder.contains(row.gridId) {
                stepOrder.insert(row.gridId, at: 0)
            }
        }
        // Hold the ring's sizing assumption. Rows are capped per grid but the
        // number of grids was not, and a `windo`/'scrollbind' group larger than
        // `maxRetainedGrids` would wrap the ring onto buffers a frame is still
        // reading. The grid opening a step is the one being scrolled now, so
        // the rows shed here are the least recent.
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
        // Grid-scoped: a step describes one grid's movement, and 'scrollbind'
        // (:vert diffsplit) scrolls two windows from one gesture, each needing
        // its own band filled. Shifting or pruning another grid's rows here
        // would move them by a distance their content never travelled, and
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

/// Copy one outgoing row's retainable vertices into the retention ring:
/// only the vertices of `gridId` whose deco_flags carry `scrollableMask`
/// (DECO_SCROLLABLE — passed in because this file is also compiled
/// standalone by ScrollRetentionTests, without the C header that defines
/// the constant). Border and margin-column cells (a float border's "│", a
/// separator) do not carry the flag, so the vertex shader neither shifts
/// them by the scroll offset nor marks them for the fragment content clip —
/// retained and translated to a targetRow they would land statically on a
/// margin row and persist in the back buffer. Shared by
/// MetalTerminalRenderer's grid_scroll capture and ExternalGridView's
/// pending-scroll capture so both retain under the same invariant: a
/// retained row holds scrollable cells of one grid, nothing else. Returns
/// nil when the row has nothing retainable (the band then falls back to
/// the edge stretch) or the ring has no buffer.
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

struct SurfaceViewportMetrics {
    let viewportWidth: Double
    let viewportHeight: Double
    let originX: Double
    let originY: Double
    let fragmentWidth: Float
    let fragmentHeight: Float

    init(viewportWidth: Double, viewportHeight: Double, drawableSize: CGSize, originX: Double = 0, originY: Double = 0) {
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.originX = originX
        self.originY = originY
        self.fragmentWidth = Float(viewportWidth > 0 ? viewportWidth : Double(drawableSize.width))
        self.fragmentHeight = Float(viewportHeight > 0 ? viewportHeight : Double(drawableSize.height))
    }

    func applyViewport(to encoder: MTLRenderCommandEncoder) {
        guard viewportWidth > 0, viewportHeight > 0 else { return }
        encoder.setViewport(MTLViewport(originX: originX, originY: originY, width: viewportWidth, height: viewportHeight, znear: 0, zfar: 1))
    }
}

func resolveSurfaceBackgroundAlpha(
    blurEnabled: Bool,
    decoratedSurface: Bool
) -> Float {
    if decoratedSurface && blurEnabled {
        return 0.0
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

/// Extract packed RGB from an MTLClearColor.
func extractRGBFromClearColor(_ color: MTLClearColor) -> UInt32 {
    let r = UInt32(color.red * 255.0) & 0xFF
    let g = UInt32(color.green * 255.0) & 0xFF
    let b = UInt32(color.blue * 255.0) & 0xFF
    return (r << 16) | (g << 8) | b
}

func makeSurfaceClearColor(
    red: Double,
    green: Double,
    blue: Double,
    blurEnabled: Bool,
    decoratedSurface: Bool
) -> MTLClearColor {
    let alpha = resolveSurfaceClearAlpha(blurEnabled: blurEnabled, decoratedSurface: decoratedSurface)
    return MTLClearColor(red: red, green: green, blue: blue, alpha: alpha)
}

func makeSurfaceClearColor(
    bgRGB: UInt32,
    blurEnabled: Bool,
    decoratedSurface: Bool = false
) -> MTLClearColor {
    let red = Double((bgRGB >> 16) & 0xFF) / 255.0
    let green = Double((bgRGB >> 8) & 0xFF) / 255.0
    let blue = Double(bgRGB & 0xFF) / 255.0
    return makeSurfaceClearColor(
        red: red,
        green: green,
        blue: blue,
        blurEnabled: blurEnabled,
        decoratedSurface: decoratedSurface
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

/// Independent buffer set owning row vertex data for one frame.
/// Used by both MetalTerminalRenderer (triple-buffered) and ExternalGridView (write/committed pair).
/// Class (reference type) to allow sharing buffer references across sets (COW pattern).
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

    // Main vertex buffer (used by MetalTerminalRenderer, not by ExternalGridView)
    var mainVertexBuffer: MTLBuffer? = nil
    var mainVertexBufferCap: Int = 0
    var mainVertexCount: Int = 0

    // Shared atlas texture reference frozen at commit time, alongside this
    // set's vertex data (used by ExternalGridView only — MetalTerminalRenderer
    // owns the atlas directly and reads committedAtlasTexture under its own
    // `lock` in the same scope as its committed-index snapshot, so it has no
    // analogous cross-object generation-mismatch risk). Without this,
    // ExternalGridView.draw(in:) fetching the atlas from the main renderer
    // at a LATER, independent point in the same draw call could race a
    // core-thread atlas commit landing in between, combining THIS commit's
    // vertices/UVs with a DIFFERENT (newer or older) atlas layout for one
    // frame. Populated in ExternalGridView.commitFlush() right where
    // committedSetIndex is published, under the same tripleBufferLock.
    var atlasTextureSnapshot: MTLTexture? = nil
    // Cursor vertex buffer (used by both MetalTerminalRenderer and ExternalGridView,
    // each keeping its own per-set copy so a GPU-in-flight read never races a CPU write)
    var cursorVertexBuffer: MTLBuffer? = nil
    var cursorVertexBufferCap: Int = 0
    var cursorVertexCount: Int = 0

    // Scroll-offset scratch buffers for bindSurfaceScrollOffsets' fallback
    // path (only used when offsets exceed the 4096-byte setVertexBytes
    // limit — rare). Kept per-set, one for the main pass and one for the
    // cursor pass, for the same reason as cursorVertexBuffer above: this
    // set's gpuInFlightCount protection guarantees the previous frame's GPU
    // read of this slot has completed before it's reused, so overwriting
    // these buffers here never races an in-flight read. Two separate
    // buffers because the main and cursor passes can bind different
    // offsets content within the same frame.
    var scrollOffsetBuffer: MTLBuffer? = nil
    var scrollOffsetBufferCap: Int = 0
    var cursorScrollOffsetBuffer: MTLBuffer? = nil
    var cursorScrollOffsetBufferCap: Int = 0

    // Detach pool: buffers saved from this set before beginFlush overwrites them.
    // On COW detach, reuse a pool buffer instead of calling device.makeBuffer().
    var detachPoolRowBuffers: [MTLBuffer?] = []
    var detachPoolRowCapacities: [Int] = []
    var detachPoolMainBuffer: MTLBuffer? = nil
    var detachPoolMainCap: Int = 0

    // Private per-row buffer pool, owned exclusively by this set.
    //
    // Two slots per row to handle the COW shallow-copy chain. Single slot is
    // unsafe: after rotation, src.rowState[R] may alias this set's only private
    // buffer (via shallow-copy chain through 3 sets), so writing to private
    // would corrupt the in-flight committed frame. Two slots guarantee at
    // least one is not aliased after warm-up.
    //
    // Used as the safe write target when detach pool cannot be reused —
    // specifically when sharesSource && gpuInFlight && pool buffer aliases src.
    //
    // Without this, ensureSurfaceRowBuffer would call device.makeBuffer() in
    // that alias-fallback path. Each fresh MTLBuffer creates a new IOAccelerator
    // region; macOS Metal allocator pools released regions internally rather
    // than returning them to the kernel, causing phys_footprint to grow
    // monotonically across scroll bursts.
    //
    // After warm-up, no new MTLBuffer allocations are needed for this path.
    // Total bound: 3 sets x N rows x 2 slots x peak cap.
    var privateRowBuffers0: [MTLBuffer?] = []
    var privateRowCapacities0: [Int] = []
    var privateRowBuffers1: [MTLBuffer?] = []
    var privateRowCapacities1: [Int] = []
    /// 0 or 1: which slot to try first on next detach for this row.
    /// Toggles after each successful reuse so slots alternate naturally.
    var privateRowNextSlot: [Int] = []

}

/// Pick a free buffer set index for writing during a flush.
/// Returns the index of a set that is neither `committedIndex` nor GPU in-flight,
/// or -1 if no set is available.
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

/// Maximum vertex buffer capacity (256 MB). Bounds a single row's vertex
/// data — normal content stays in the low single-digit MB range even under
/// extreme display setups (multi-monitor, tiny font); this ceiling mainly
/// guards against pathological per-cell decoration counts (e.g. heavily
/// stacked combining-character content). Hitting it terminates the redraw
/// session (see failHardRender in nvim_core.zig), so this is deliberately
/// generous headroom, not a tight budget.
///
/// Kept equal to MAX_VERTEX_BYTES_PER_CALLBACK in src/core/flush.zig so the
/// core never hands over a row this buffer would reject on size alone. It is
/// not the binding per-row ceiling: surfaceMaxProvisionedRowBytes below is
/// lower once spread across three sets with two private slots each (~42 MiB
/// per row), and it is the limit the provisioning path actually enforces.
private let surfaceMaxVertexBufferCapacity: Int = 256 * 1024 * 1024
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

/// Compute needed bytes for a vertex count, with overflow protection.
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

/// Return true only when a row submission can complete without growing Swift
/// arrays or creating an MTLBuffer. Both private slots are required because a
/// COW chain can make either one alias the committed or an in-flight set.
func surfaceRowCapacityIsPrepared(
    bufferSets: [SurfaceBufferSet],
    row: Int,
    vertexCount: Int,
    totalRows: Int,
    maxRowBuffers: Int
) -> Bool {
    guard row >= 0, row < maxRowBuffers,
          totalRows >= 0, totalRows <= maxRowBuffers,
          let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)),
          neededBytes <= surfaceMaxVertexBufferCapacity
    else { return false }

    let requiredRows = max(totalRows, row + 1)
    var copiedActiveCapacity = 0
    for set in bufferSets where row < set.rowState.capacities.count {
        copiedActiveCapacity = max(copiedActiveCapacity, set.rowState.capacities[row])
    }
    copiedActiveCapacity = surfaceCapacityBasisForDemand(
        copiedActiveCapacity,
        neededBytes: neededBytes
    )
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
                current: copiedActiveCapacity,
                needed: max(1, neededBytes)
            ),
            set.privateRowBuffers0[row] != nil,
            set.privateRowCapacities0[row] >= requiredCapacity,
            !surfaceCapacityIsOversized(
                set.privateRowCapacities0[row],
                neededBytes: neededBytes
            ),
            set.privateRowBuffers1[row] != nil,
            set.privateRowCapacities1[row] >= requiredCapacity,
            !surfaceCapacityIsOversized(
                set.privateRowCapacities1[row],
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
        guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)),
              neededBytes <= surfaceMaxVertexBufferCapacity
        else { return .overBudget }
        guard neededBytes > 0 else { continue }

        var copiedActiveCapacity = 0
        for set in bufferSets where row < set.rowState.capacities.count {
            copiedActiveCapacity = max(copiedActiveCapacity, set.rowState.capacities[row])
        }
        copiedActiveCapacity = surfaceCapacityBasisForDemand(
            copiedActiveCapacity,
            neededBytes: neededBytes
        )
        guard let requiredCapacity = surfaceGrowCapacity(
            current: copiedActiveCapacity,
            needed: max(1, neededBytes)
        ) else { return .overBudget }

        for set in bufferSets {
            let slot0Ready = row < set.privateRowBuffers0.count
                && set.privateRowBuffers0[row] != nil
                && set.privateRowCapacities0[row] >= requiredCapacity
                && !surfaceCapacityIsOversized(
                    set.privateRowCapacities0[row],
                    neededBytes: neededBytes
                )
            let slot1Ready = row < set.privateRowBuffers1.count
                && set.privateRowBuffers1[row] != nil
                && set.privateRowCapacities1[row] >= requiredCapacity
                && !surfaceCapacityIsOversized(
                    set.privateRowCapacities1[row],
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
        guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)),
              neededBytes <= surfaceMaxVertexBufferCapacity
        else { return .overBudget }
        guard neededBytes > 0 else { continue }

        var copiedActiveCapacity = 0
        for set in bufferSets where row < set.rowState.capacities.count {
            copiedActiveCapacity = max(copiedActiveCapacity, set.rowState.capacities[row])
        }
        copiedActiveCapacity = surfaceCapacityBasisForDemand(
            copiedActiveCapacity,
            neededBytes: neededBytes
        )

        for (setIndex, set) in bufferSets.enumerated() {
            guard let requiredCapacity = surfaceGrowCapacity(
                current: copiedActiveCapacity,
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
            if existingSlot0 == nil ||
                existingSlot0Capacity < requiredCapacity ||
                surfaceCapacityIsOversized(existingSlot0Capacity, neededBytes: neededBytes) {
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
            if existingSlot1 == nil ||
                existingSlot1Capacity < requiredCapacity ||
                surfaceCapacityIsOversized(existingSlot1Capacity, neededBytes: neededBytes) {
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

/// Prepare row-mode set for write (ensure identity mapping, trim if oversize).
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
        //   memcpy (check-then-write race), so "no draw in flight right now"
        //   does not make writing into a committed-set alias safe.
        // - inflightRowBuffers covers OLDER sets the GPU is still reading
        //   (up to two with ExternalGridView's semaphore=2): the COW chain
        //   can leave the same buffer object shared into a set that is
        //   in-flight while src already holds a detached replacement, so
        //   comparing against src alone misses it (torn row mid-scroll).
        //
        // Reuse deliberately accepts storage larger than this row needs. An
        // oversize rejection here belongs to 91bb4ad's async provisioning
        // design, which reached this function with allowAllocation: false, so
        // the rejection returned nil and the provisioner refilled the slot off
        // the redraw callback. de6c402 restored synchronous allocation at the
        // hot sites, so the same rejection now lands as device.makeBuffer()
        // inside the redraw callback instead. The provisioner still exists as
        // the allocation-failure fallback.
        //
        // Whether it fires depends on how the row widths a slot sees line up
        // with the pool-and-ring cycle, not on any single width ratio: four
        // rotating widths measured 45 allocations per flush where two or three
        // measured none. Worst case is a flush that re-submits every row
        // (base grid, multi-row or batched scroll, a split overlapping the
        // scroll region), where a slot warmed to its widest demand then misses
        // on every narrower row: 26.7 makeBuffer per flush against 0.02, and
        // resident growth unbounded against flat. When the scroll fast path is
        // available only the vacated rows are resubmitted and the same effect
        // is 0.77 against 0.06.
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
            // Use this set's per-row private slots (2-deep ring) instead of
            // device.makeBuffer() — fresh MTLBuffer allocations here create
            // IOAccelerator regions that the macOS Metal allocator pools
            // internally rather than returning to the kernel, causing
            // phys_footprint to grow under scroll bursts.
            //
            // Why 2 slots: the COW shallow-copy chain spreads a buffer across
            // all 3 sets within 2 rotations. With only 1 private slot, after
            // those rotations src would alias this set's single private slot
            // (since src inherited it via COW). 2 slots break the cycle.
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

/// Remap row slot indices on scroll (shift logical->slot mapping).
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

/// Submit vertices for a single row into a SurfaceBufferSet.
/// Shared between MetalTerminalRenderer and ExternalGridView.
///
/// - Parameters:
///   - target: The buffer set to write into (write set during flush, or committed set)
///   - device: Metal device for buffer allocation
///   - rowStart: Logical row index
///   - ptr: Raw pointer to vertex data (nil clears the row). Must point to
///          memory laid out as `Vertex` (same layout as `zonvie_vertex`).
///   - count: Number of vertices
///   - maxRowBuffers: Maximum number of row buffers supported
///   - totalRows: Total rows in the grid (used for prepareSurfaceRowModeSetForWrite)
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

/// Compute a scissor rect for a single row in back-buffer pixel coordinates.
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
    rects: [MetalTerminalRenderer.FixedFloatRect],
    bands: inout [MetalTerminalRenderer.FixedFloatBand],
    intervals: inout [MetalTerminalRenderer.FixedFloatInterval],
    yEdgesScratch: inout [Float],
    xEdgesScratch: inout [Float],
    coveringScratch: inout [MetalTerminalRenderer.FixedFloatRect]
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
        var pending: MetalTerminalRenderer.FixedFloatInterval?
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
                pending = MetalTerminalRenderer.FixedFloatInterval(x0: x0, x1: x1, z: zf)
            }
        }
        if let flushed = pending { intervals.append(flushed) }
        guard intervals.count > start else { continue }
        bands.append(MetalTerminalRenderer.FixedFloatBand(
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

/// Bind scroll offset data to a render encoder.
/// Handles both single-entry and multi-entry scroll offset arrays,
/// falling back to a dummy entry when the array is empty.
func bindSurfaceScrollOffsets(
    encoder: MTLRenderCommandEncoder,
    offsets: [MetalTerminalRenderer.ScrollOffset],
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
                    var dummy = MetalTerminalRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                    encoder.setVertexBytes(&dummy, length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride, index: 1)
                    effectiveCount = 0
                }
            }
        }
    } else {
        var dummy = MetalTerminalRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
        encoder.setVertexBytes(&dummy, length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride, index: 1)
    }
    encoder.setVertexBytes(&effectiveCount, length: MemoryLayout<UInt32>.size, index: 2)
}

/// Bind the zero-or-one scroll offset used by an external grid without
/// constructing a temporary Swift Array in the per-frame draw path.
func bindSingleSurfaceScrollOffset(
    encoder: MTLRenderCommandEncoder,
    offset: MetalTerminalRenderer.ScrollOffset?
) {
    var effectiveCount: UInt32 = 0
    if var value = offset {
        encoder.setVertexBytes(
            &value,
            length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride,
            index: 1
        )
        effectiveCount = 1
    } else {
        var dummy = MetalTerminalRenderer.ScrollOffset(
            grid_id: 0,
            offset_y: 0,
            content_top_y: 0,
            content_bottom_y: 0
        )
        encoder.setVertexBytes(
            &dummy,
            length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride,
            index: 1
        )
    }
    encoder.setVertexBytes(&effectiveCount, length: MemoryLayout<UInt32>.size, index: 2)
}

/// Bind fragment-side state shared by all surface draw passes:
/// drawable size, background alpha buffer, and cursor blink buffer.
func bindSurfaceFragmentState(
    encoder: MTLRenderCommandEncoder,
    viewportMetrics: SurfaceViewportMetrics,
    backgroundAlphaBuffer: MTLBuffer?,
    cursorBlinkBuffer: MTLBuffer?,
    cursorBlinkVisible: Bool,
    fixedFloatBands: [MetalTerminalRenderer.FixedFloatBand] = [],
    fixedFloatIntervals: [MetalTerminalRenderer.FixedFloatInterval] = []
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
    let bandStride = MemoryLayout<MetalTerminalRenderer.FixedFloatBand>.stride
    let intervalStride = MemoryLayout<MetalTerminalRenderer.FixedFloatInterval>.stride
    var fixedBandCount = UInt32(fixedFloatBands.count)
    if fixedFloatBands.isEmpty {
        var dummyBand = MetalTerminalRenderer.FixedFloatBand(top: 0, bottom: 0, intervalStart: 0, intervalCount: 0)
        encoder.setFragmentBytes(&dummyBand, length: bandStride, index: 3)
    } else {
        fixedFloatBands.withUnsafeBytes { ptr in
            encoder.setFragmentBytes(ptr.baseAddress!, length: fixedFloatBands.count * bandStride, index: 3)
        }
    }
    encoder.setFragmentBytes(&fixedBandCount, length: MemoryLayout<UInt32>.size, index: 4)
    if fixedFloatIntervals.isEmpty {
        var dummyInterval = MetalTerminalRenderer.FixedFloatInterval(x0: 0, x1: 0)
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

/// Shared glow texture state managed per-view (sizes differ per window).
final class SurfaceGlowTextures {
    var extractTex: MTLTexture?
    var mipTextures: [MTLTexture?] = [nil, nil, nil]
    var texSize: CGSize = .zero
    var intensityBuffer: MTLBuffer?

    /// Ensure glow textures exist at correct sizes.
    /// `drawableSize` is used to size the textures (provides room for blur bleed
    /// beyond the grid viewport into margin areas).
    @discardableResult
    func ensure(device: MTLDevice, drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> Bool {
        let halfSize = CGSize(width: max(1, drawableSize.width / 2.0),
                              height: max(1, drawableSize.height / 2.0))
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
        var mw = max(1, desc.width / 2)
        var mh = max(1, desc.height / 2)
        for i in 0..<3 {
            desc.width = mw
            desc.height = mh
            guard let mip = device.makeTexture(descriptor: desc) else { return false }
            newMips[i] = mip
            mw = max(1, mw / 2)
            mh = max(1, mh / 2)
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
///   Used for the extract viewport and fragment DrawableSize so NDC ↔ pixel mapping aligns.
/// - `drawableSize`: raw drawable pixel dimensions. Used for extract texture sizing so that
///   blur can bleed beyond the grid viewport into surrounding margin areas.
///
/// Returns true if bloom was applied.
@discardableResult
func encodeSurfaceBloomPasses(
    cmd: MTLCommandBuffer,
    backTex: MTLTexture,
    viewportSize: CGSize,
    drawableSize: CGSize,
    viewportOrigin: CGPoint = .zero,
    glowTextures: SurfaceGlowTextures,
    extractPipeline: MTLRenderPipelineState,
    kawaseDownPipeline: MTLRenderPipelineState,
    kawaseUpPipeline: MTLRenderPipelineState,
    compositePipeline: MTLRenderPipelineState,
    copyVertexBuffer: MTLBuffer,
    bilinearSampler: MTLSamplerState,
    intensity: Float,
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
    encodeExtractVertices(extractEnc)
    extractEnc.endEncoding()

    // Dual Kawase downsample chain: extract → mip[0] → mip[1] → mip[2]
    for level in 0..<3 {
        let srcTex = (level == 0) ? extractTex : glowTextures.mipTextures[level - 1]!
        let dstTex = glowTextures.mipTextures[level]!

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dstTex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(kawaseDownPipeline)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                     width: Double(dstTex.width), height: Double(dstTex.height),
                                     znear: 0, zfar: 1))
        enc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.setFragmentSamplerState(bilinearSampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
    }

    // Dual Kawase upsample chain: mip[2] → mip[1] → mip[0] → extractTex
    for level in stride(from: 2, through: 0, by: -1) {
        let srcTex = (level == 2) ? glowTextures.mipTextures[2]! : glowTextures.mipTextures[level]!
        let dstTex: MTLTexture
        if level == 0 {
            dstTex = extractTex
        } else {
            dstTex = glowTextures.mipTextures[level - 1]!
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dstTex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(kawaseUpPipeline)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                     width: Double(dstTex.width), height: Double(dstTex.height),
                                     znear: 0, zfar: 1))
        enc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.setFragmentSamplerState(bilinearSampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
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
