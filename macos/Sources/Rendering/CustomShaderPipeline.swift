import Foundation
import Metal

/// Owns a single user-supplied custom post-process fragment shader plus its
/// MTLRenderPipelineState. Accepts Shadertoy/Ghostty style GLSL (with a
/// `void mainImage(out vec4 fragColor, in vec2 fragCoord)` entry point) or
/// a raw GLSL source with its own `void main()`; the core's
/// `zonvie_shader_compile_glsl` C ABI auto-wraps the Shadertoy form with
/// the Zonvie uniform block and a bridge main().
///
/// Must be paired at pipeline creation with the `vs_custom_post` vertex
/// function from the default Metal library (outputs `vUV [[user(locn0)]]`
/// to match SPIRV-Cross's fragment input convention).
final class CustomShaderPipeline {
    let sourcePath: String
    let pipelineState: MTLRenderPipelineState
    /// True when the user GLSL references any time-varying Shadertoy
    /// uniform. Set by `load()` from a token scan of the source before
    /// cross-compilation. Aggregated by `GridSurfaceRenderer` to decide
    /// whether to run the continuous vsync-driven draw loop; without this
    /// flag the shader would execute only when Neovim flushes, producing
    /// a static image for shaders whose output depends on `iTime`.
    let needsAnimation: Bool
    /// True when the source reads the cell-age inputs. Aggregated by
    /// SharedRenderResources so the cell-age texture and the core's stamp
    /// lists exist only when something reads them.
    let usesEditInputs: Bool
    /// True when the source reads the cell-text texture. Gates the
    /// cell-text stores and texture.
    let usesCellText: Bool
    /// True when the source reads `iPrevFrame`. Gates the feedback pair.
    let usesPrevFrame: Bool
    /// True when the source reads `iBelowFloats`. Gates the below-floats
    /// texture and its pass.
    let usesBelowFloats: Bool
    /// True when the source declared `@zonvie-owns-cursor`.
    let ownsCursor: Bool
    /// The GLSL text, for the core's `@zonvie-hl-groups:` declaration.
    let glslSource: String

    private init(
        sourcePath: String,
        pipelineState: MTLRenderPipelineState,
        needsAnimation: Bool,
        usesEditInputs: Bool,
        usesCellText: Bool,
        usesPrevFrame: Bool,
        usesBelowFloats: Bool,
        ownsCursor: Bool,
        glslSource: String
    ) {
        self.glslSource = glslSource
        self.sourcePath = sourcePath
        self.pipelineState = pipelineState
        self.needsAnimation = needsAnimation
        self.usesEditInputs = usesEditInputs
        self.usesCellText = usesCellText
        self.usesPrevFrame = usesPrevFrame
        self.usesBelowFloats = usesBelowFloats
        self.ownsCursor = ownsCursor
    }

    /// Whether the shader reads a per-frame uniform: the core's rule, shared
    /// with Windows.
    static func detectNeedsAnimation(in source: String) -> Bool {
        var source = source
        return source.withUTF8 { zonvie_core_shader_needs_animation($0.baseAddress, $0.count) }
    }

    /// Whether the shader reads a Zonvie edit-effect input: the core's rule,
    /// shared with Windows.
    static func detectUsesEditInputs(in source: String) -> Bool {
        var source = source
        return source.withUTF8 { zonvie_core_shader_uses_edit_inputs($0.baseAddress, $0.count) }
    }

    /// Whether the shader reads the cell text: the core's rule, shared with
    /// Windows.
    static func detectUsesCellText(in source: String) -> Bool {
        var source = source
        return source.withUTF8 { zonvie_core_shader_uses_cell_text($0.baseAddress, $0.count) }
    }

    /// Whether the shader reads iPrevFrame: the core's rule, shared with
    /// Windows.
    static func detectUsesPrevFrame(in source: String) -> Bool {
        var source = source
        return source.withUTF8 { zonvie_core_shader_uses_prev_frame($0.baseAddress, $0.count) }
    }

    /// Whether the shader reads iBelowFloats: the core's rule, shared with
    /// Windows.
    static func detectUsesBelowFloats(in source: String) -> Bool {
        var source = source
        return source.withUTF8 { zonvie_core_shader_uses_below_floats($0.baseAddress, $0.count) }
    }

    /// Whether the shader opts into drawing the cursor: the core's rule,
    /// shared with Windows.
    static func detectOwnsCursor(in source: String) -> Bool {
        var source = source
        return source.withUTF8 { zonvie_core_shader_owns_cursor($0.baseAddress, $0.count) }
    }


    /// Load a single custom shader from disk, compile it, and build a
    /// render pipeline state. Returns nil on any failure after logging —
    /// callers should treat missing custom shaders as "fall back to the
    /// normal blit" rather than a hard error.
    static func load(
        device: MTLDevice,
        library: MTLLibrary,
        vsCustomPost: MTLFunction,
        copyVertexDescriptor: MTLVertexDescriptor,
        sourcePath: String,
        pixelFormat: MTLPixelFormat,
        preserveAlpha: Bool = false
    ) -> CustomShaderPipeline? {
        let glslSource: String
        do {
            glslSource = try String(contentsOfFile: sourcePath, encoding: .utf8)
        } catch {
            ZonvieCore.appLog("[CustomShader] ERROR: cannot read \(sourcePath): \(error)")
            return nil
        }
        if glslSource.isEmpty {
            ZonvieCore.appLog("[CustomShader] ERROR: \(sourcePath) is empty")
            return nil
        }

        // Opt-in alpha preservation: define a macro the core's Shadertoy bridge
        // (#ifdef ZONVIE_PRESERVE_ALPHA) reads to keep the terminal's alpha.
        // Only for Shadertoy-style sources (the bridge is appended only then);
        // raw shaders manage their own output and require #version first.
        var sourceForCompile = glslSource
        if preserveAlpha && glslSource.contains("mainImage") {
            sourceForCompile = "#define ZONVIE_PRESERVE_ALPHA 1\n" + glslSource
        }
        guard let mslSource = compileGlslToMsl(glsl: sourceForCompile, label: sourcePath) else {
            return nil
        }

        let mslLibrary: MTLLibrary
        do {
            mslLibrary = try device.makeLibrary(source: mslSource, options: nil)
        } catch {
            ZonvieCore.appLog("[CustomShader] ERROR: MSL library compile for \(sourcePath): \(error)")
            return nil
        }

        // SPIRV-Cross emits fragment entry as `main0` by default.
        guard let fragmentFn = mslLibrary.makeFunction(name: "main0") else {
            ZonvieCore.appLog("[CustomShader] ERROR: \(sourcePath) MSL has no `main0` entry")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "CustomShader:\(URL(fileURLWithPath: sourcePath).lastPathComponent)"
        desc.vertexFunction = vsCustomPost
        desc.fragmentFunction = fragmentFn
        desc.vertexDescriptor = copyVertexDescriptor
        desc.colorAttachments[0].pixelFormat = pixelFormat
        if let a = desc.colorAttachments[0] {
            a.isBlendingEnabled = false
        }

        let pipelineState: MTLRenderPipelineState
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            ZonvieCore.appLog("[CustomShader] ERROR: pipeline state for \(sourcePath): \(error)")
            return nil
        }

        let needsAnimation = detectNeedsAnimation(in: glslSource)
        let usesEditInputs = detectUsesEditInputs(in: glslSource)
        let usesCellText = detectUsesCellText(in: glslSource)
        let usesPrevFrame = detectUsesPrevFrame(in: glslSource)
        let usesBelowFloats = detectUsesBelowFloats(in: glslSource)
        let ownsCursor = detectOwnsCursor(in: glslSource)
        ZonvieCore.appLog("[CustomShader] loaded \(sourcePath) (needsAnimation=\(needsAnimation) editInputs=\(usesEditInputs) cellText=\(usesCellText) prevFrame=\(usesPrevFrame) belowFloats=\(usesBelowFloats) ownsCursor=\(ownsCursor))")
        return CustomShaderPipeline(
            sourcePath: sourcePath,
            pipelineState: pipelineState,
            needsAnimation: needsAnimation,
            usesEditInputs: usesEditInputs,
            usesCellText: usesCellText,
            usesPrevFrame: usesPrevFrame,
            usesBelowFloats: usesBelowFloats,
            ownsCursor: ownsCursor,
            glslSource: glslSource
        )
    }

    /// Call the core's `zonvie_shader_compile_glsl` C ABI and dupe the
    /// returned MSL into a Swift `String`. Releases the C-side result
    /// before returning.
    private static func compileGlslToMsl(glsl: String, label: String) -> String? {
        var result = zonvie_shader_result()
        let ok = glsl.withCString { (cStr: UnsafePointer<CChar>) -> Bool in
            let bytes = strlen(cStr)
            result = zonvie_shader_compile_glsl(cStr, bytes, ZONVIE_SHADER_TARGET_MSL)
            return true
        }
        _ = ok
        defer { zonvie_shader_result_destroy(&result) }

        if let errPtr = result.error_msg {
            let msg = String(cString: errPtr)
            ZonvieCore.appLog("[CustomShader] GLSL compile failed for \(label): \(msg)")
            return nil
        }
        guard let dataPtr = result.data else {
            ZonvieCore.appLog("[CustomShader] GLSL compile returned no data for \(label)")
            return nil
        }
        // dataPtr is null-terminated per the C ABI contract.
        return String(cString: dataPtr)
    }

    /// Encode a single fullscreen pass: sample `input`, draw to `output`.
    /// `copyVertexBuffer` is the same 6-vertex fullscreen quad used by the
    /// existing `vs_copy` bloom passes. `uniforms` is the 160-byte
    /// `zonvie_shader_uniforms` block passed inline via
    /// `setFragmentBytes(_:length:index:)` at index 1 — matches the
    /// Shadertoy preamble's `layout(std140, binding = 1)`. Inlining
    /// avoids write races when several MTKViews animate simultaneously
    /// (each gets its own copy in the command buffer).
    /// `prevFrame`, `cellAge`, `cellText` and `rowOffset` back the Zonvie
    /// edit-effect inputs (`iPrevFrame` at texture 2, `iCellAge` at 3,
    /// `iCellText` at 4, `iRowOffset` at 5, `iBelowFloats` at 6). Each is nil for shaders that do
    /// not reference it; the fragment function then simply never samples
    /// that slot.
    func encode(
        cmd: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        /// The logical region rendered; `output` may be larger.
        viewportSize: CGSize,
        /// Maps the quad onto the inputs' defined region (surfaceUVScale).
        uvScale: SIMD2<Float>,
        copyVertexBuffer: MTLBuffer,
        sampler: MTLSamplerState,
        uniforms: zonvie_shader_uniforms,
        prevFrame: MTLTexture? = nil,
        cellAge: MTLTexture? = nil,
        cellText: MTLTexture? = nil,
        rowOffset: MTLTexture? = nil,
        belowFloats: MTLTexture? = nil
    ) -> Bool {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = output
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.label = "CustomShader.encode"
        enc.setRenderPipelineState(pipelineState)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                    width: viewportSize.width, height: viewportSize.height,
                                    znear: 0, zfar: 1))
        enc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
        var scale = uvScale
        enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        enc.setFragmentTexture(input, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        if let prevFrame {
            enc.setFragmentTexture(prevFrame, index: 2)
            enc.setFragmentSamplerState(sampler, index: 2)
        }
        if let cellAge {
            enc.setFragmentTexture(cellAge, index: 3)
            enc.setFragmentSamplerState(sampler, index: 3)
        }
        if let cellText {
            enc.setFragmentTexture(cellText, index: 4)
            enc.setFragmentSamplerState(sampler, index: 4)
        }
        if let rowOffset {
            enc.setFragmentTexture(rowOffset, index: 5)
            enc.setFragmentSamplerState(sampler, index: 5)
        }
        if let below = belowFloats ?? (usesBelowFloats ? blackFallback(device: cmd.device) : nil) {
            enc.setFragmentTexture(below, index: 6)
            enc.setFragmentSamplerState(sampler, index: 6)
        }
        var u = uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<zonvie_shader_uniforms>.size, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        return true
    }

    /// Bound at slot 6 when the below pass produced nothing, so a shader
    /// reading iBelowFloats never samples an unbound slot (black, matching
    /// Linux and Windows). Created once per pipeline and reused.
    private var blackTexture: MTLTexture?

    private func blackFallback(device: MTLDevice) -> MTLTexture? {
        if let blackTexture { return blackTexture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var px: UInt32 = 0
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        blackTexture = tex
        return tex
    }
}
