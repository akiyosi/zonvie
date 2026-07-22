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

    func resetCounts() {
        for i in 0..<counts.count {
            counts[i] = 0
        }
    }

    func ensureRows(_ totalRows: Int) {
        guard totalRows > 0 else { return }
        while buffers.count < totalRows {
            buffers.append(nil)
            capacities.append(0)
            counts.append(0)
        }
    }

    func clearBeyond(_ totalRows: Int) {
        guard totalRows >= 0 else { return }
        if totalRows < counts.count {
            for i in totalRows..<counts.count {
                counts[i] = 0
            }
        }
    }
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
    var detachPoolCursorBuffer: MTLBuffer? = nil
    var detachPoolCursorCap: Int = 0

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

/// Maximum vertex buffer capacity (64 MB).
private let surfaceMaxVertexBufferCapacity: Int = 64 * 1024 * 1024

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

/// Ensure row storage arrays cover at least `row + 1` entries.
func ensureSurfaceRowStorage(bufferSet: SurfaceBufferSet, _ row: Int, maxRowBuffers: Int) {
    if row < 0 { return }
    if row >= maxRowBuffers { return }
    if row < bufferSet.rowState.buffers.count { return }
    let oldCount = bufferSet.rowState.buffers.count
    let newCount = row + 1
    let grow = newCount - oldCount
    bufferSet.rowState.buffers.append(contentsOf: Array(repeating: nil, count: grow))
    bufferSet.rowState.capacities.append(contentsOf: Array(repeating: 0, count: grow))
    bufferSet.rowState.counts.append(contentsOf: Array(repeating: 0, count: grow))
    bufferSet.rowLogicalToSlot.append(contentsOf: Array(oldCount..<newCount))
    bufferSet.rowSlotSourceRows.append(contentsOf: Array(oldCount..<newCount))
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
    if totalRows > 0 {
        bufferSet.knownTotalRows = totalRows
    }
    if totalCols > 0 {
        bufferSet.knownTotalCols = totalCols
    }
    bufferSet.rowState.usingRowBuffers = true

    // submitSurfaceRowVertices calls this once per dirty row. Clearing the
    // complete historical tail on every call made a D-row update after shrink
    // O(D * (peakRows - totalRows)). The tail only changes when dimensions do;
    // copied buffer sets already inherit the source set's cleared counts.
    if totalRows > 0,
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

/// Drop oversized row backing only while replacing that row in a non-in-flight
/// write set after a column contraction. Other COW sets retain any aliased
/// MTLBuffer until their own GPU reads complete.
private func retireOversizedSurfaceRowStorage(
    bufferSet: SurfaceBufferSet,
    row: Int,
    neededBytes: Int
) {
    guard row >= 0, row < bufferSet.rowState.buffers.count else { return }

    func isOversized(_ capacity: Int) -> Bool {
        guard capacity > 0 else { return false }
        if neededBytes == 0 { return true }
        return capacity > neededBytes * 2
    }

    if isOversized(bufferSet.rowState.capacities[row]) {
        bufferSet.rowState.buffers[row] = nil
        bufferSet.rowState.capacities[row] = 0
    }
    if row < bufferSet.detachPoolRowCapacities.count,
       isOversized(bufferSet.detachPoolRowCapacities[row]) {
        bufferSet.detachPoolRowBuffers[row] = nil
        bufferSet.detachPoolRowCapacities[row] = 0
    }
    if row < bufferSet.privateRowCapacities0.count,
       isOversized(bufferSet.privateRowCapacities0[row]) {
        bufferSet.privateRowBuffers0[row] = nil
        bufferSet.privateRowCapacities0[row] = 0
    }
    if row < bufferSet.privateRowCapacities1.count,
       isOversized(bufferSet.privateRowCapacities1[row]) {
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
    inflightRowBuffers: (MTLBuffer?, MTLBuffer?) = (nil, nil)
) -> MTLBuffer? {
    guard row >= 0 && row < maxRowBuffers else { return nil }
    ensureSurfaceRowStorage(bufferSet: bufferSet, row, maxRowBuffers: maxRowBuffers)
    guard row < bufferSet.rowState.buffers.count else { return nil }
    guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, vertexCount)) else { return nil }

    // Check if we share this buffer with the source (committed) set.
    let srcRowBuffer = sourceSet.flatMap { src in
        row < src.rowState.buffers.count ? src.rowState.buffers[row] : nil
    }
    let sharesSource = sourceSet != nil && srcRowBuffer != nil
        && bufferSet.rowState.buffers[row] === srcRowBuffer

    let needsNewBuffer = sharesSource
        || bufferSet.rowState.buffers[row] == nil
        || neededBytes > bufferSet.rowState.capacities[row]

    if needsNewBuffer {
        guard let nextCap = surfaceGrowCapacity(
            current: bufferSet.rowState.capacities[row],
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
    if src.knownTotalRows > 0, src.knownTotalRows < destinationRowsBeforeCopy {
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
    inflightRowBuffers: (Int) -> (MTLBuffer?, MTLBuffer?) = { _ in (nil, nil) }
) -> Bool {
    let columnsContracted = totalCols > 0 &&
        ((sourceSet?.knownTotalCols ?? 0) > totalCols || target.knownTotalCols > totalCols)
    prepareSurfaceRowModeSetForWrite(bufferSet: target, totalRows: totalRows, totalCols: totalCols)

    guard rowStart >= 0, rowStart < maxRowBuffers else { return false }
    let row = rowStart

    ensureSurfaceRowStorage(bufferSet: target, row, maxRowBuffers: maxRowBuffers)
    guard row < target.rowLogicalToSlot.count else { return false }
    let slot = target.rowLogicalToSlot[row]
    guard slot >= 0 && slot < target.rowState.buffers.count else { return false }

    guard let neededBytes = surfaceSafeNeededBytes(vertexCount: max(0, count)),
          neededBytes <= surfaceMaxVertexBufferCapacity
    else {
        target.rowState.counts[slot] = 0
        return false
    }
    if columnsContracted {
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
