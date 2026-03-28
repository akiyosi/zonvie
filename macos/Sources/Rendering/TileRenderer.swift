import Metal
import MetalKit

/// Lightweight off-screen renderer for workspace tile thumbnails.
/// Each inactive core gets one of these so it can continue rendering
/// to an off-screen texture while not connected to the main MTKView.
///
/// Shares pipeline states with the main MetalTerminalRenderer.
/// Owns its own GlyphAtlas, back buffer texture, and vertex storage.
final class TileRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // Shared pipeline states (from main renderer)
    var pipeline: MTLRenderPipelineState?
    var backgroundPipeline: MTLRenderPipelineState?
    var glyphPipeline: MTLRenderPipelineState?

    // Shared glyph atlas (same as main renderer — all cores use same UV space)
    let glyphAtlas: GlyphAtlas

    // Off-screen render target (the tile thumbnail texture)
    private(set) var texture: MTLTexture?
    private(set) var textureWidth: Int = 0
    private(set) var textureHeight: Int = 0

    // Vertex storage (written by core callbacks, read during render)
    private var mainVertices: [Vertex] = []
    private var cursorVertices: [Vertex] = []
    private var rowVertexMap: [Int: [Vertex]] = [:]  // row index → vertices
    private var totalRows: Int = 0
    private var useRowMode: Bool = true
    private var hasPendingFlush: Bool = false
    private let lock = NSLock()

    // Cell metrics for layout
    var cellWidthPx: Float { glyphAtlas.cellWidthPx }
    var cellHeightPx: Float { glyphAtlas.cellHeightPx + Float(linespacePx) }
    var linespacePx: Int = 0

    init(device: MTLDevice, mainRenderer: MetalTerminalRenderer) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        // Each TileRenderer has its OWN GlyphAtlas with independent textures.
        // This prevents shelf packer position conflicts between cores.
        self.glyphAtlas = GlyphAtlas(device: device)

        // Share pipeline states
        self.pipeline = mainRenderer.sharedPipeline
        self.backgroundPipeline = mainRenderer.sharedBackgroundPipeline
        self.glyphPipeline = mainRenderer.sharedGlyphPipeline
    }

    // MARK: - Texture management

    func ensureTexture(width: Int, height: Int) {
        guard width > 0 && height > 0 else { return }
        if textureWidth == width && textureHeight == height && texture != nil { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        texture = device.makeTexture(descriptor: desc)
        textureWidth = width
        textureHeight = height
    }

    // MARK: - Vertex submission (called from core thread callbacks)

    func beginFlush() {
        lock.lock()
        // Don't clear — accumulate until render
        lock.unlock()
    }

    func submitVerticesFlat(mainPtr: UnsafeRawPointer?, mainCount: Int,
                            cursorPtr: UnsafeRawPointer?, cursorCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        if let ptr = mainPtr, mainCount > 0 {
            let typed = ptr.bindMemory(to: Vertex.self, capacity: mainCount)
            mainVertices = Array(UnsafeBufferPointer(start: typed, count: mainCount))
        }
        if let ptr = cursorPtr, cursorCount > 0 {
            let typed = ptr.bindMemory(to: Vertex.self, capacity: cursorCount)
            cursorVertices = Array(UnsafeBufferPointer(start: typed, count: cursorCount))
        }
        useRowMode = false
    }

    func submitVerticesRow(rowStart: Int, rowCount: Int,
                           ptr: UnsafeRawPointer?, count: Int,
                           totalRows: Int) {
        lock.lock()
        defer { lock.unlock() }

        if let ptr = ptr, count > 0 {
            let typed = ptr.bindMemory(to: Vertex.self, capacity: count)
            let verts = Array(UnsafeBufferPointer(start: typed, count: count))
            for r in rowStart..<(rowStart + rowCount) {
                rowVertexMap[r] = verts
            }
        }
        self.totalRows = totalRows
        useRowMode = true
    }

    func submitCursorVertices(ptr: UnsafeRawPointer?, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        if let ptr = ptr, count > 0 {
            let typed = ptr.bindMemory(to: Vertex.self, capacity: count)
            cursorVertices = Array(UnsafeBufferPointer(start: typed, count: count))
        }
    }

    func commitFlush(drawableW: Int, drawableH: Int) {
        // Commit own atlas (independent from main renderer's atlas)
        let atlasTex = glyphAtlas.commitAndSnapshotFrontTexture()

        lock.lock()
        hasPendingFlush = true
        lock.unlock()

        ensureTexture(width: drawableW, height: drawableH)
        render(atlasTexture: atlasTex)
    }

    // MARK: - Rendering

    private func render(atlasTexture: MTLTexture?) {
        guard let tex = texture, let pipeline = pipeline else { return }
        guard let cmd = commandQueue.makeCommandBuffer() else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = tex
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        let vpW = Float(textureWidth)
        let vpH = Float(textureHeight)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                         width: Double(vpW), height: Double(vpH),
                                         znear: 0, zfar: 1))

        // Bind atlas texture
        if let atlasTex = atlasTexture {
            encoder.setFragmentTexture(atlasTex, index: 0)
        }

        // Bind drawable size uniform
        var drawableSize = DrawableSize(width: vpW, height: vpH)
        encoder.setVertexBytes(&drawableSize, length: MemoryLayout<DrawableSize>.size, index: 1)
        encoder.setFragmentBytes(&drawableSize, length: MemoryLayout<DrawableSize>.size, index: 0)

        lock.lock()
        let verts: [Vertex]
        if useRowMode {
            // Flatten row vertices into single array
            var all: [Vertex] = []
            for r in 0..<totalRows {
                if let rowVerts = rowVertexMap[r] {
                    all.append(contentsOf: rowVerts)
                }
            }
            all.append(contentsOf: cursorVertices)
            verts = all
        } else {
            verts = mainVertices + cursorVertices
        }
        hasPendingFlush = false
        lock.unlock()

        if !verts.isEmpty {
            // Draw all vertices with main pipeline
            encoder.setRenderPipelineState(pipeline)
            verts.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        }

        encoder.endEncoding()

        // Synchronize for CPU read (managed storage)
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: tex)
            blit.endEncoding()
        }

        cmd.commit()
        // Don't waitUntilCompleted — async is fine for thumbnails
    }
}
