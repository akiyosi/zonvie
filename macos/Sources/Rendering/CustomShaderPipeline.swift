import Foundation
import Metal

/// Owns a single user-supplied custom post-process fragment shader plus its
/// MTLRenderPipelineState. Accepts Zonvie-format GLSL (which will later get
/// wrapped into full Shadertoy compat in Phase 4) and cross-compiles it to
/// MSL at load time via the core's `zonvie_shader_compile_glsl` C ABI.
///
/// Expected GLSL shape (Phase 2 intermediate format, not final Shadertoy):
/// ```glsl
/// #version 450
/// layout(binding = 0) uniform sampler2D iChannel0;
/// layout(location = 0) in vec2 vUV;
/// layout(location = 0) out vec4 fragColor;
/// void main() { fragColor = texture(iChannel0, vUV); }
/// ```
/// Must be paired at pipeline creation with the matching `vs_custom_post`
/// vertex function from the default Metal library (which outputs
/// `vUV [[user(locn0)]]`).
final class CustomShaderPipeline {
    let sourcePath: String
    let pipelineState: MTLRenderPipelineState

    private init(sourcePath: String, pipelineState: MTLRenderPipelineState) {
        self.sourcePath = sourcePath
        self.pipelineState = pipelineState
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

        ZonvieCore.appLog("[CustomShader] loaded \(sourcePath)")
        return CustomShaderPipeline(sourcePath: sourcePath, pipelineState: pipelineState)
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
    /// existing `vs_copy` bloom passes.
    func encode(
        cmd: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        copyVertexBuffer: MTLBuffer,
        sampler: MTLSamplerState
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
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
    }
}
