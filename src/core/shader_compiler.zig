//! GLSL -> MSL / HLSL cross-compilation wrapper.
//!
//! Accepts Shadertoy-compatible GLSL fragment shader source (with a
//! `mainImage(out vec4 fragColor, in vec2 fragCoord)` entry point and the
//! usual `iResolution` / `iTime` / `iChannel0` uniforms) and emits source
//! code for the target graphics API via:
//!   glslang (GLSL -> SPIR-V)  ->  SPIRV-Cross (SPIR-V -> target)
//!
//! Phase 1c wires the real pipeline; upstream uniform wrapping (Shadertoy
//! mainImage entry) is Phase 4's job. For now we accept any GLSL 450
//! fragment shader that defines `void main()`.

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

/// Compile a GLSL fragment shader to the target shading language.
/// Returned slice is allocated with `alloc` and owned by the caller.
pub fn compileGlslToTarget(
    alloc: std.mem.Allocator,
    glsl_source: []const u8,
    target: Target,
) CompileError![]u8 {
    if (glsl_source.len == 0) return CompileError.EmptySource;

    glslang_init_once.call();

    // glslang wants a null-terminated C string.
    const glsl_z = alloc.dupeZ(u8, glsl_source) catch return CompileError.OutOfMemory;
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
