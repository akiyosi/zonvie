//! GLSL -> MSL / HLSL cross-compilation wrapper.
//!
//! Accepts Shadertoy/Ghostty-style GLSL fragment shaders and emits source
//! code for the target graphics API via:
//!   glslang (GLSL -> SPIR-V)  ->  SPIRV-Cross (SPIR-V -> target)
//!
//! Input forms (auto-detected by content):
//!
//!   1. **Shadertoy / Ghostty form** — the source defines
//!      `void mainImage(out vec4 fragColor, in vec2 fragCoord)` and is
//!      automatically wrapped with a preamble that declares the standard
//!      Shadertoy uniforms (`iResolution`, `iTime`, `iChannel0`, …) and a
//!      bridge `void main()`. Ghostty's shader zoo drops in verbatim.
//!
//!   2. **Raw form** — the source defines `void main()` directly. It is
//!      passed to glslang as-is and must declare its own `iChannel0`
//!      sampler (`layout(binding=0)`) and `vUV` input
//!      (`layout(location=0) in vec2 vUV`).
//!
//! The shared uniform layout (64 bytes, std140) matches
//! `include/zonvie_core.h`'s `zonvie_shader_uniforms`, which both
//! frontends populate and upload per frame as a UBO at binding=1.

const std = @import("std");

const glslang = @cImport({
    @cInclude("glslang/Include/glslang_c_interface.h");
    @cInclude("glslang/Public/resource_limits_c.h");
});

const spvc = @cImport({
    @cInclude("spirv_cross_c.h");
});

/// Target shading language for cross-compilation output.
pub const Target = enum(u8) {
    msl = 0, // Metal Shading Language (macOS)
    hlsl = 1, // High-Level Shading Language (D3D11 on Windows)
};

pub const CompileError = error{
    NotImplemented,
    EmptySource,
    ParseFailed,
    LinkFailed,
    SpirvGenFailed,
    CrossCompileFailed,
    OutOfMemory,
};

// glslang_initialize_process() is a one-shot global. It is safe to call
// multiple times in the same process but wasteful; wrap in std.once.
var glslang_init_once = std.once(initGlslangProcess);

fn initGlslangProcess() void {
    _ = glslang.glslang_initialize_process();
}

/// Shadertoy-compatible wrapper prepended to Shadertoy-style user sources.
/// Member order and sizes are kept in lock-step with
/// `zonvie_shader_uniforms` in `include/zonvie_core.h` (64 bytes, std140).
const shadertoy_preamble =
    \\#version 450
    \\
    \\layout(binding = 0) uniform sampler2D iChannel0;
    \\
    \\layout(std140, binding = 1) uniform ZonvieShaderUniforms {
    \\    vec3 iResolution;
    \\    float iTime;
    \\    vec4 iMouse;
    \\    vec4 iDate;
    \\    float iTimeDelta;
    \\    int iFrame;
    \\    float iSampleRate;
    \\    float iFrameRate;
    \\};
    \\
    \\layout(location = 0) in vec2 vUV;
    \\layout(location = 0) out vec4 zonvie_fragColor;
    \\
    \\// ----- user source (mainImage) follows -----
    \\
;

const shadertoy_epilogue =
    \\
    \\// ----- bridge from Shadertoy mainImage to the pipeline output -----
    \\void main() {
    \\    // Shadertoy: fragCoord is in pixels, origin bottom-left.
    \\    vec2 fragCoord = vUV * iResolution.xy;
    \\    fragCoord.y = iResolution.y - fragCoord.y;
    \\    vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
    \\    mainImage(color, fragCoord);
    \\    zonvie_fragColor = color;
    \\}
    \\
;

/// Decide whether user source looks like a Shadertoy-style shader
/// (defines `void mainImage(...)`) and therefore needs the preamble +
/// bridge main(), or like a raw form that already has its own main()
/// and uniforms declared. Detection is purely textual — we avoid
/// pre-tokenizing since both forms have to survive preprocessing in
/// glslang anyway.
fn isShadertoyStyle(src: []const u8) bool {
    return std.mem.indexOf(u8, src, "mainImage") != null;
}

fn wrapShadertoy(alloc: std.mem.Allocator, user_src: []const u8) ![]u8 {
    const total_len = shadertoy_preamble.len + user_src.len + shadertoy_epilogue.len;
    var buf = try alloc.alloc(u8, total_len);
    @memcpy(buf[0..shadertoy_preamble.len], shadertoy_preamble);
    @memcpy(buf[shadertoy_preamble.len..][0..user_src.len], user_src);
    @memcpy(buf[shadertoy_preamble.len + user_src.len ..][0..shadertoy_epilogue.len], shadertoy_epilogue);
    return buf;
}

/// Compile a GLSL fragment shader to the target shading language.
/// Returned slice is allocated with `alloc` and owned by the caller.
/// Shadertoy-style sources (those containing `mainImage`) are
/// auto-wrapped with the preamble defined above before being handed to
/// glslang.
pub fn compileGlslToTarget(
    alloc: std.mem.Allocator,
    glsl_source: []const u8,
    target: Target,
) CompileError![]u8 {
    if (glsl_source.len == 0) return CompileError.EmptySource;

    glslang_init_once.call();

    // Auto-wrap Shadertoy-style sources.
    const wrapped: []u8 = if (isShadertoyStyle(glsl_source))
        wrapShadertoy(alloc, glsl_source) catch return CompileError.OutOfMemory
    else
        alloc.dupe(u8, glsl_source) catch return CompileError.OutOfMemory;
    defer alloc.free(wrapped);

    // glslang wants a null-terminated C string.
    const glsl_z = alloc.dupeZ(u8, wrapped) catch return CompileError.OutOfMemory;
    defer alloc.free(glsl_z);

    // Build the glslang input descriptor. Vulkan 1.0 + SPIR-V 1.0 is the
    // most compatible baseline for SPIRV-Cross downstream consumption.
    var input: glslang.glslang_input_t = std.mem.zeroes(glslang.glslang_input_t);
    input.language = glslang.GLSLANG_SOURCE_GLSL;
    input.stage = glslang.GLSLANG_STAGE_FRAGMENT;
    input.client = glslang.GLSLANG_CLIENT_VULKAN;
    input.client_version = glslang.GLSLANG_TARGET_VULKAN_1_0;
    input.target_language = glslang.GLSLANG_TARGET_SPV;
    input.target_language_version = glslang.GLSLANG_TARGET_SPV_1_0;
    input.code = glsl_z.ptr;
    input.default_version = 450;
    input.default_profile = glslang.GLSLANG_NO_PROFILE;
    input.force_default_version_and_profile = 0;
    input.forward_compatible = 0;
    input.messages = glslang.GLSLANG_MSG_DEFAULT_BIT;
    input.resource = glslang.glslang_default_resource();

    const shader = glslang.glslang_shader_create(&input) orelse
        return CompileError.ParseFailed;
    defer glslang.glslang_shader_delete(shader);

    if (glslang.glslang_shader_preprocess(shader, &input) == 0) {
        return CompileError.ParseFailed;
    }
    if (glslang.glslang_shader_parse(shader, &input) == 0) {
        return CompileError.ParseFailed;
    }

    const program = glslang.glslang_program_create() orelse
        return CompileError.LinkFailed;
    defer glslang.glslang_program_delete(program);

    glslang.glslang_program_add_shader(program, shader);
    if (glslang.glslang_program_link(program, glslang.GLSLANG_MSG_DEFAULT_BIT) == 0) {
        return CompileError.LinkFailed;
    }

    glslang.glslang_program_SPIRV_generate(program, glslang.GLSLANG_STAGE_FRAGMENT);
    const spirv_word_count: usize = glslang.glslang_program_SPIRV_get_size(program);
    if (spirv_word_count == 0) return CompileError.SpirvGenFailed;

    // SPIR-V is a stream of 32-bit words. Copy into our own buffer so we
    // can destroy the glslang program before handing the bytes off to
    // SPIRV-Cross.
    const spirv_words = alloc.alloc(u32, spirv_word_count) catch
        return CompileError.OutOfMemory;
    defer alloc.free(spirv_words);
    // glslang's C API takes unsigned int* (c_uint). On all the targets we
    // care about, c_uint == u32.
    glslang.glslang_program_SPIRV_get(program, @ptrCast(spirv_words.ptr));

    return crossCompileSpirv(alloc, spirv_words, target);
}

fn crossCompileSpirv(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    target: Target,
) CompileError![]u8 {
    var ctx: spvc.spvc_context = undefined;
    if (spvc.spvc_context_create(&ctx) != spvc.SPVC_SUCCESS) {
        return CompileError.OutOfMemory;
    }
    defer spvc.spvc_context_destroy(ctx);

    var parsed_ir: spvc.spvc_parsed_ir = undefined;
    if (spvc.spvc_context_parse_spirv(
        ctx,
        @ptrCast(spirv_words.ptr),
        spirv_words.len,
        &parsed_ir,
    ) != spvc.SPVC_SUCCESS) {
        return CompileError.CrossCompileFailed;
    }

    const backend: spvc.spvc_backend = switch (target) {
        .msl => spvc.SPVC_BACKEND_MSL,
        .hlsl => spvc.SPVC_BACKEND_HLSL,
    };

    var compiler: spvc.spvc_compiler = undefined;
    if (spvc.spvc_context_create_compiler(
        ctx,
        backend,
        parsed_ir,
        spvc.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
        &compiler,
    ) != spvc.SPVC_SUCCESS) {
        return CompileError.CrossCompileFailed;
    }

    // HLSL defaults to shader model 3.0 which predates SPIR-V features we
    // rely on. Bump to SM 5.0 (D3D11) for D3D11-era features.
    if (target == .hlsl) {
        var options: spvc.spvc_compiler_options = undefined;
        if (spvc.spvc_compiler_create_compiler_options(compiler, &options) == spvc.SPVC_SUCCESS) {
            _ = spvc.spvc_compiler_options_set_uint(
                options,
                spvc.SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL,
                50,
            );
            _ = spvc.spvc_compiler_install_compiler_options(compiler, options);
        }
    }

    var compiled_src: [*c]const u8 = undefined;
    if (spvc.spvc_compiler_compile(compiler, &compiled_src) != spvc.SPVC_SUCCESS) {
        return CompileError.CrossCompileFailed;
    }

    // The returned string is owned by the context (freed on destroy) —
    // dupe it into caller-owned memory before the defer cleans up.
    const src_slice = std.mem.span(compiled_src);
    return alloc.dupe(u8, src_slice) catch CompileError.OutOfMemory;
}

test "compile trivial GLSL fragment shader to MSL" {
    const glsl =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = vec4(1.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .msl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    // MSL output should mention Metal's stdlib header.
    try std.testing.expect(std.mem.indexOf(u8, out, "metal_stdlib") != null);
}

test "compile trivial GLSL fragment shader to HLSL" {
    const glsl =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = vec4(0.0, 1.0, 0.0, 1.0);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .hlsl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    // HLSL output should include a float4 main() declaration.
    try std.testing.expect(std.mem.indexOf(u8, out, "float4") != null);
}

test "compile Shadertoy-style mainImage source to MSL with auto-wrap" {
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec2 uv = fragCoord / iResolution.xy;
        \\    fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .msl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    // Metal stdlib must be present; the Shadertoy uniforms must be visible
    // somewhere in the emitted MSL to prove the wrapper took effect.
    try std.testing.expect(std.mem.indexOf(u8, out, "metal_stdlib") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "iResolution") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "iTime") != null);
}

test "compile Shadertoy-style mainImage source to HLSL with auto-wrap" {
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    fragColor = vec4(1.0, 0.5, 0.25, 1.0) * (0.5 + 0.5 * sin(iTime));
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .hlsl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "iTime") != null);
}
