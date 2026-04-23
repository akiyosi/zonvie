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
    /// cross-compilation. Aggregated by `MetalTerminalRenderer` to decide
    /// whether to run the continuous vsync-driven draw loop; without this
    /// flag the shader would execute only when Neovim flushes, producing
    /// a static image for shaders whose output depends on `iTime`.
    let needsAnimation: Bool

    private init(sourcePath: String, pipelineState: MTLRenderPipelineState, needsAnimation: Bool) {
        self.sourcePath = sourcePath
        self.pipelineState = pipelineState
        self.needsAnimation = needsAnimation
    }

    /// Whole-word regex scan for animation-bearing Shadertoy uniforms.
    /// Matches inside comments get treated as animated too — cheaper than
    /// missing a real reference and leaving the shader frozen. iResolution
    /// / iSampleRate / iChannel0 are excluded because they do not drive
    /// per-frame change unless the window size or input texture does.
    static func detectNeedsAnimation(in source: String) -> Bool {
        let pattern = #"\b(iTime|iTimeDelta|iFrame|iFrameRate|iMouse|iDate)\b"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// Errors surfaced to the renderer while building a custom pipeline.
    enum LoadError: Error {
        case fileRead(String, Error)
        case emptySource(String)
        case glslCompile(String, String)       // path, error message from glslang/SPIRV-Cross
        case mslLibraryCompile(String, Error)
        case missingFragmentFunction(String)
        case pipelineStateCompile(String, Error)
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
        pixelFormat: MTLPixelFormat
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

        guard let mslSource = compileGlslToMsl(glsl: glslSource, label: sourcePath) else {
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
        ZonvieCore.appLog("[CustomShader] loaded \(sourcePath) (needsAnimation=\(needsAnimation))")
        return CustomShaderPipeline(
            sourcePath: sourcePath,
            pipelineState: pipelineState,
            needsAnimation: needsAnimation
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
    /// existing `vs_copy` bloom passes. `uniforms` is the 64-byte
    /// `zonvie_shader_uniforms` block bound as buffer(1) to match the
    /// Shadertoy preamble's `layout(std140, binding = 1)`. Pass nil only
    /// when the shader is in the raw form and does not reference any
    /// Shadertoy uniforms (the GPU still reads unbound buffers as zero).
    func encode(
        cmd: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        copyVertexBuffer: MTLBuffer,
        sampler: MTLSamplerState,
        uniforms: MTLBuffer?
    ) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = output
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.label = "CustomShader.encode"
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(copyVertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(input, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        if let ubo = uniforms {
            enc.setFragmentBuffer(ubo, offset: 0, index: 1)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
    }
}
