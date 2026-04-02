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

struct SurfaceRowDrawItem {
    var vertexBuffer: MTLBuffer
    var vertexCount: Int
    var translationY: Float = 0
    var scissorRect: MTLScissorRect? = nil
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

@discardableResult
func encodeSurfaceRowDraws(
    encoder: MTLRenderCommandEncoder,
    items: [SurfaceRowDrawItem],
    pipeline: MTLRenderPipelineState,
    backgroundPipeline: MTLRenderPipelineState?,
    glyphPipeline: MTLRenderPipelineState?,
    useTwoPass: Bool
) -> Int {
    var drawnRows = 0

    func encodePass(with pipelineState: MTLRenderPipelineState, countDrawnRows: Bool) {
        encoder.setRenderPipelineState(pipelineState)
        for item in items {
            guard item.vertexCount > 0 else { continue }
            if let scissor = item.scissorRect {
                encoder.setScissorRect(scissor)
            }
            var translation = item.translationY
            encoder.setVertexBytes(&translation, length: MemoryLayout<Float>.size, index: 3)
            encoder.setVertexBuffer(item.vertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: item.vertexCount)
            if countDrawnRows {
                drawnRows += 1
            }
        }
    }

    if useTwoPass, let backgroundPipeline, let glyphPipeline {
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
    var pendingScroll: SurfaceRowScroll? = nil

    // Main / cursor vertex buffers (used by MetalTerminalRenderer, not by ExternalGridView)
    var mainVertexBuffer: MTLBuffer? = nil
    var mainVertexBufferCap: Int = 0
    var mainVertexCount: Int = 0
    var cursorVertexBuffer: MTLBuffer? = nil
    var cursorVertexBufferCap: Int = 0
    var cursorVertexCount: Int = 0

    // Detach pool: buffers saved from this set before beginFlush overwrites them.
    // On COW detach, reuse a pool buffer instead of calling device.makeBuffer().
    var detachPoolRowBuffers: [MTLBuffer?] = []
    var detachPoolRowCapacities: [Int] = []
    var detachPoolMainBuffer: MTLBuffer? = nil
    var detachPoolMainCap: Int = 0
    var detachPoolCursorBuffer: MTLBuffer? = nil
    var detachPoolCursorCap: Int = 0

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

/// Prepare row-mode set for write (ensure identity mapping, trim if oversize).
func prepareSurfaceRowModeSetForWrite(bufferSet: SurfaceBufferSet, totalRows: Int) {
    if totalRows > 0 {
        bufferSet.knownTotalRows = totalRows
    }
    bufferSet.rowState.usingRowBuffers = true

    if totalRows > 0 && totalRows < bufferSet.rowLogicalToSlot.count {
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
    maxRowBuffers: Int
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
        // Guard: the pool buffer must not alias the source buffer, otherwise
        // we'd write into the committed frame.
        var reused = false
        if row < bufferSet.detachPoolRowBuffers.count,
           let poolBuf = bufferSet.detachPoolRowBuffers[row],
           row < bufferSet.detachPoolRowCapacities.count,
           bufferSet.detachPoolRowCapacities[row] >= nextCap,
           poolBuf !== srcRowBuffer
        {
            bufferSet.rowState.buffers[row] = poolBuf
            bufferSet.rowState.capacities[row] = bufferSet.detachPoolRowCapacities[row]
            bufferSet.detachPoolRowBuffers[row] = nil  // consumed
            reused = true
        }

        if !reused {
            bufferSet.rowState.capacities[row] = nextCap
            bufferSet.rowState.buffers[row] = device.makeBuffer(length: nextCap, options: .storageModeShared)
            if bufferSet.rowState.buffers[row] == nil {
                bufferSet.rowState.capacities[row] = 0
                return nil
            }
        }
    }
    return bufferSet.rowState.buffers[row]
}

/// Remap row slot indices on scroll (shift logical->slot mapping).
func remapSurfaceRowSlots(
    bufferSet: SurfaceBufferSet,
    rowStart: Int,
    rowEnd: Int,
    rowsDelta: Int,
    totalRows: Int,
    maxRowBuffers: Int
) {
    prepareSurfaceRowModeSetForWrite(bufferSet: bufferSet, totalRows: totalRows)
    let regionHeight = rowEnd - rowStart
    let shift = abs(rowsDelta)
    guard shift > 0, shift < regionHeight else { return }
    ensureSurfaceRowStorage(bufferSet: bufferSet, rowEnd - 1, maxRowBuffers: maxRowBuffers)
    guard rowEnd <= bufferSet.rowLogicalToSlot.count else { return }

    if rowsDelta > 0 {
        let savedSlots = Array(bufferSet.rowLogicalToSlot[rowStart..<(rowStart + shift)])
        for dstRow in rowStart..<(rowEnd - shift) {
            bufferSet.rowLogicalToSlot[dstRow] = bufferSet.rowLogicalToSlot[dstRow + shift]
        }
        for (idx, slot) in savedSlots.enumerated() {
            let logicalRow = rowEnd - shift + idx
            bufferSet.rowLogicalToSlot[logicalRow] = slot
            bufferSet.rowState.counts[slot] = 0
            bufferSet.rowSlotSourceRows[slot] = logicalRow
        }
    } else {
        let savedSlots = Array(bufferSet.rowLogicalToSlot[(rowEnd - shift)..<rowEnd])
        for dstRow in stride(from: rowEnd - 1, through: rowStart + shift, by: -1) {
            bufferSet.rowLogicalToSlot[dstRow] = bufferSet.rowLogicalToSlot[dstRow - shift]
        }
        for (idx, slot) in savedSlots.enumerated() {
            let logicalRow = rowStart + idx
            bufferSet.rowLogicalToSlot[logicalRow] = slot
            bufferSet.rowState.counts[slot] = 0
            bufferSet.rowSlotSourceRows[slot] = logicalRow
        }
    }
}

/// Copy buffer set state from source to destination for the start of a new flush.
/// Before overwriting dst's buffer references with src's (shallow copy), dst's
/// own buffers are saved into the detach pool.  On COW detach, pool buffers
/// are reused instead of calling device.makeBuffer(), keeping the total
/// MTLBuffer count bounded at 3 sets × rows.
func copySurfaceBufferSetRowState(from src: SurfaceBufferSet, to dst: SurfaceBufferSet) {
    // Save dst's own row buffers into the detach pool before overwriting.
    dst.detachPoolRowBuffers = dst.rowState.buffers
    dst.detachPoolRowCapacities = dst.rowState.capacities

    dst.knownTotalRows = src.knownTotalRows
    dst.rowState.buffers = src.rowState.buffers
    dst.rowState.capacities = src.rowState.capacities
    dst.rowState.counts = src.rowState.counts
    dst.rowState.usingRowBuffers = src.rowState.usingRowBuffers
    dst.rowLogicalToSlot = src.rowLogicalToSlot
    dst.rowSlotSourceRows = src.rowSlotSourceRows
    dst.pendingScroll = nil
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
func submitSurfaceRowVertices(
    target: SurfaceBufferSet,
    sourceSet: SurfaceBufferSet?,
    device: MTLDevice,
    rowStart: Int,
    ptr: UnsafeRawPointer?,
    count: Int,
    maxRowBuffers: Int,
    totalRows: Int
) {
    prepareSurfaceRowModeSetForWrite(bufferSet: target, totalRows: totalRows)

    guard rowStart >= 0, rowStart < maxRowBuffers else { return }
    let row = rowStart

    ensureSurfaceRowStorage(bufferSet: target, row, maxRowBuffers: maxRowBuffers)
    guard row < target.rowLogicalToSlot.count else { return }
    let slot = target.rowLogicalToSlot[row]
    guard slot >= 0 && slot < target.rowState.buffers.count else { return }

    guard count > 0, let validPtr = ptr else {
        target.rowState.counts[slot] = 0
        if slot < target.rowSlotSourceRows.count {
            target.rowSlotSourceRows[slot] = row
        }
        return
    }

    guard surfaceSafeNeededBytes(vertexCount: count) != nil else {
        target.rowState.counts[slot] = 0
        return
    }

    guard let dstBuffer = ensureSurfaceRowBuffer(
        bufferSet: target,
        sourceSet: sourceSet,
        device: device,
        row: slot,
        vertexCount: count,
        maxRowBuffers: maxRowBuffers
    ) else {
        target.rowState.counts[slot] = 0
        return
    }

    memcpy(dstBuffer.contents(), validPtr, count * MemoryLayout<Vertex>.stride)
    target.rowState.counts[slot] = count
    if slot < target.rowSlotSourceRows.count {
        target.rowSlotSourceRows[slot] = row
    }
}

/// Compute a scissor rect for a single row in back-buffer pixel coordinates.
func makeRowScissorRect(
    row: Int,
    cellHeight_px: Int,
    drawableWidth_px: Int
) -> MTLScissorRect? {
    let y = max(0, row * cellHeight_px)
    guard drawableWidth_px > 0, cellHeight_px > 0 else { return nil }
    return MTLScissorRect(x: 0, y: y, width: drawableWidth_px, height: cellHeight_px)
}

func buildSurfaceRowDrawItems(
    safeRowCount: Int,
    resolve: (Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)?
) -> [SurfaceRowDrawItem] {
    return (0..<safeRowCount).compactMap { row in
        guard let resolved = resolve(row) else { return nil }
        return SurfaceRowDrawItem(
            vertexBuffer: resolved.vb,
            vertexCount: resolved.vc,
            translationY: resolved.translationY
        )
    }
}

func buildSurfaceRowDrawItems(
    rows: [Int],
    resolve: (Int) -> (vc: Int, vb: MTLBuffer, translationY: Float)?,
    scissor: (Int) -> MTLScissorRect?
) -> [SurfaceRowDrawItem] {
    return rows.compactMap { row in
        guard let resolved = resolve(row) else { return nil }
        return SurfaceRowDrawItem(
            vertexBuffer: resolved.vb,
            vertexCount: resolved.vc,
            translationY: resolved.translationY,
            scissorRect: scissor(row)
        )
    }
}

// MARK: - Surface Encoder Binding Helpers

/// Bind scroll offset data to a render encoder.
/// Handles both single-entry and multi-entry scroll offset arrays,
/// falling back to a dummy entry when the array is empty.
func bindSurfaceScrollOffsets(
    encoder: MTLRenderCommandEncoder,
    offsets: [MetalTerminalRenderer.ScrollOffset],
    device: MTLDevice
) {
    let maxSetVertexBytesSize = 4096
    var effectiveCount = UInt32(offsets.count)
    if !offsets.isEmpty {
        offsets.withUnsafeBytes { ptr in
            if ptr.count <= maxSetVertexBytesSize {
                encoder.setVertexBytes(ptr.baseAddress!, length: ptr.count, index: 1)
            } else if let buf = device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count, options: .storageModeShared) {
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
            } else {
                var dummy = MetalTerminalRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
                encoder.setVertexBytes(&dummy, length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride, index: 1)
                effectiveCount = 0
            }
        }
    } else {
        var dummy = MetalTerminalRenderer.ScrollOffset(grid_id: 0, offset_y: 0, content_top_y: 0, content_bottom_y: 0)
        encoder.setVertexBytes(&dummy, length: MemoryLayout<MetalTerminalRenderer.ScrollOffset>.stride, index: 1)
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
    cursorBlinkVisible: Bool
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
    scissorRect: MTLScissorRect? = nil
) {
    guard vertexCount > 0, let vb = vertexBuffer else { return }

    var zeroTranslation: Float = 0
    encoder.setVertexBytes(&zeroTranslation, length: MemoryLayout<Float>.size, index: 3)

    if useTwoPass, let bgPipe = backgroundPipeline, let glyphPipe = glyphPipeline {
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
    func ensure(device: MTLDevice, drawableSize: CGSize, pixelFormat: MTLPixelFormat) {
        let halfSize = CGSize(width: max(1, drawableSize.width / 2.0),
                              height: max(1, drawableSize.height / 2.0))
        if extractTex != nil, texSize == halfSize { return }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.pixelFormat = pixelFormat
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        desc.mipmapLevelCount = 1

        desc.width = max(1, Int(halfSize.width))
        desc.height = max(1, Int(halfSize.height))
        extractTex = device.makeTexture(descriptor: desc)

        var mw = max(1, desc.width / 2)
        var mh = max(1, desc.height / 2)
        for i in 0..<3 {
            desc.width = mw
            desc.height = mh
            mipTextures[i] = device.makeTexture(descriptor: desc)
            mw = max(1, mw / 2)
            mh = max(1, mh / 2)
        }
        texSize = halfSize
    }

    func ensureIntensityBuffer(device: MTLDevice) {
        if intensityBuffer == nil {
            intensityBuffer = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared)
        }
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

    if let enc = cmd.makeRenderCommandEncoder(descriptor: extractRPD) {
        enc.setRenderPipelineState(extractPipeline)
        enc.setViewport(extractViewport)

        encodeExtractVertices(enc)
        enc.endEncoding()
    }

    // Dual Kawase downsample chain: extract → mip[0] → mip[1] → mip[2]
    for level in 0..<3 {
        let srcTex = (level == 0) ? extractTex : glowTextures.mipTextures[level - 1]!
        let dstTex = glowTextures.mipTextures[level]!

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dstTex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store

        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
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

        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
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
    }

    // Composite → backBuffer (additive blend)
    let compositeRPD = MTLRenderPassDescriptor()
    compositeRPD.colorAttachments[0].texture = backTex
    compositeRPD.colorAttachments[0].loadAction = .load
    compositeRPD.colorAttachments[0].storeAction = .store

    if let enc = cmd.makeRenderCommandEncoder(descriptor: compositeRPD) {
        enc.setRenderPipelineState(compositePipeline)
        // No explicit viewport: default = full backBuffer so blur bleed
        // extends naturally into margin areas beyond the grid viewport.
        enc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(extractTex, index: 0)
        enc.setFragmentSamplerState(bilinearSampler, index: 0)
        enc.setFragmentBuffer(intensityBuf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
    }

    return true
}
