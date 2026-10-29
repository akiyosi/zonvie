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
//! The shared uniform layout (160 bytes, std140) matches
//! `include/zonvie_frontend.h`'s `zonvie_shader_uniforms`, which both
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
    /// GLSL 330 core (OpenGL 3.3 on Linux). GL 3.3 has no binding
    /// qualifiers, so the frontend binds the samplers and the uniform block
    /// by name: zonvie_iChannel0Tex, zonvie_iPrevFrameTex, iCellAge and
    /// ZonvieShaderUniforms.
    glsl = 2,
};

pub const CompileError = error{
    EmptySource,
    ParseFailed,
    LinkFailed,
    SpirvGenFailed,
    CrossCompileFailed,
    OutOfMemory,
};

// glslang_initialize_process() is a one-shot global. It is safe to call
// multiple times in the same process but wasteful. Zig 0.16 removed std.once,
// so use a manual 3-state gate (0=uninit, 1=running, 2=done) that makes
// concurrent callers block until initialization has fully completed.
var glslang_init_state: std.atomic.Value(u8) = .init(0);

fn ensureGlslangInit() void {
    if (glslang_init_state.load(.acquire) == 2) return;
    if (glslang_init_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        _ = glslang.glslang_initialize_process();
        glslang_init_state.store(2, .release);
        return;
    }
    while (glslang_init_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

/// Shadertoy-compatible wrapper prepended to Shadertoy-style user sources.
/// Member order and sizes match `zonvie_shader_uniforms` in
/// `include/zonvie_frontend.h` (160 bytes, std140).
///
/// Screen-space unification: `iResolution` is the main window's drawable
/// size for every view, and `iWindowOffset` / `iWindowSize` describe the
/// current view's rectangle within that space. fragCoord is screen-space
/// (absolute on the main window), so effects that depend on it — stars,
/// gradients, spotlights — line up seamlessly across ext-cmdline,
/// ext-popupmenu, and extra OS windows.
///
/// `iChannel0` is tricky: users expect `texture(iChannel0, fragCoord /
/// iResolution)` to return the terminal pixel under the fragment, but
/// each view's iChannel0 backTex only contains that view's own content
/// (sized iWindowSize, not iResolution). To bridge that gap we shadow
/// `iChannel0` with a wrapper type and provide a `texture()` overload
/// that remaps screen-space UV back into the local backTex UV before
/// sampling. Shadertoy code is unchanged.
const shadertoy_preamble =
    \\#version 450
    \\
    \\// Sampler name deliberately does not start with an underscore —
    \\// SPIRV-Cross's HLSL backend appends `_sampler` when it splits the
    \\// combined sampler, and a leading `_` on the texture would yield a
    \\// `__..._sampler` identifier that some d3dcompiler versions mishandle.
    \\layout(binding = 0) uniform sampler2D zonvie_iChannel0Tex;
    \\// Zonvie edit-effect inputs. Bindings 2 and 3 are Zonvie-specific:
    \\// Ghostty reserves iChannel1..3 (bindings it may claim later), so
    \\// naming these separately keeps both shader ecosystems compatible.
    \\// iPrevFrame is the PREVIOUS frame's final shader output, which is
    \\// what makes a decaying ghost possible; iCellAge holds, per grid cell,
    \\// the iTime at which that cell was last edited (0 = never).
    \\layout(binding = 2) uniform sampler2D zonvie_iPrevFrameTex;
    \\layout(binding = 3) uniform sampler2D iCellAge;
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
    \\    vec2 iWindowOffset;
    \\    vec2 iWindowSize;
    \\    // Ghostty 1.1+ cursor uniforms
    \\    vec4 iCurrentCursor;
    \\    vec4 iPreviousCursor;
    \\    vec4 iCurrentCursorColor;
    \\    vec4 iPreviousCursorColor;
    \\    float iTimeCursorChange;
    \\    // Three separate floats, NOT a vec2+float: std140 aligns a vec2 to
    \\    // 8 bytes, which would push it to offset 152 and shift every field
    \\    // below it out of step with zonvie_shader_uniforms.
    \\    float _zonvie_pad_cursor0;
    \\    float _zonvie_pad_cursor1;
    \\    float _zonvie_pad_cursor2;
    \\    // Zonvie edit-effect extensions (see zonvie_shader_uniforms).
    \\    vec2 iCellSize;
    \\    vec2 iGridOrigin;
    \\    float iTimeLastEdit;
    \\    int iCursorVisible;
    \\    int iCurrentCursorStyle;
    \\    int iPreviousCursorStyle;
    \\};
    \\
    \\layout(location = 0) in vec2 vUV;
    \\layout(location = 0) out vec4 zonvie_fragColor;
    \\
    \\// Wrapper type + `texture()` overload: user code keeps writing
    \\// `texture(iChannel0, uv)` with a screen-space `uv`, and we
    \\// translate that to this window's local backTex UV under the hood.
    \\// The wrappers sample LOD 0 explicitly: the textures have no mips, and
    \\// an implicit-gradient sample inside a loop with divergent control
    \\// flow forces D3DCompile to unroll it, which can hang for minutes.
    \\struct zonvie_iChannel0_t { int _d; };
    \\const zonvie_iChannel0_t iChannel0 = zonvie_iChannel0_t(0);
    \\vec4 texture(zonvie_iChannel0_t _ch, vec2 screen_uv) {
    \\    vec2 local_px = screen_uv * iResolution.xy - iWindowOffset;
    \\    vec2 local_uv = local_px / iWindowSize;
    \\    return textureLod(zonvie_iChannel0Tex, local_uv, 0.0);
    \\}
    \\vec4 textureLod(zonvie_iChannel0_t _ch, vec2 screen_uv, float lod) {
    \\    vec2 local_px = screen_uv * iResolution.xy - iWindowOffset;
    \\    vec2 local_uv = local_px / iWindowSize;
    \\    return textureLod(zonvie_iChannel0Tex, local_uv, lod);
    \\}
    \\
    \\// iPrevFrame gets the same screen-space wrapper as iChannel0 so a
    \\// shader can sample both with one UV.
    \\struct zonvie_iPrevFrame_t { int _d; };
    \\const zonvie_iPrevFrame_t iPrevFrame = zonvie_iPrevFrame_t(0);
    \\vec4 texture(zonvie_iPrevFrame_t _ch, vec2 screen_uv) {
    \\    vec2 local_px = screen_uv * iResolution.xy - iWindowOffset;
    \\    vec2 local_uv = local_px / iWindowSize;
    \\    return textureLod(zonvie_iPrevFrameTex, local_uv, 0.0);
    \\}
    \\
    \\// Age of the cell under a screen-space pixel, in seconds, or a large
    \\// value when that cell has never been edited. Wraps the texel fetch so
    \\// shaders never have to know the cell-grid dimensions.
    \\float zonvieCellAge(vec2 frag_px) {
    \\    if (iCellSize.x <= 0.0 || iCellSize.y <= 0.0) return 1e9;
    \\    vec2 cell = floor((frag_px - iGridOrigin) / iCellSize);
    \\    ivec2 idx = ivec2(cell);
    \\    ivec2 dim = textureSize(iCellAge, 0);
    \\    if (idx.x < 0 || idx.y < 0 || idx.x >= dim.x || idx.y >= dim.y) return 1e9;
    \\    float stamp = texelFetch(iCellAge, idx, 0).r;
    \\    if (stamp <= 0.0) return 1e9;
    \\    return max(0.0, iTime - stamp);
    \\}
    \\
    \\// ----- user source (mainImage) follows -----
    \\
;

const shadertoy_epilogue =
    \\
    \\// ----- bridge from Shadertoy mainImage to the pipeline output -----
    \\// `vUV` comes from our vertex stage in top-left origin (UV.y=0 at
    \\// the top of the window); both `vs_custom_post` (Metal) and
    \\// `VSFullscreen` (D3D11) emit UVs matching the top-left texture
    \\// layout. fragCoord is screen-space — the absolute position of the
    \\// fragment on the main window's drawable — so the same shader
    \\// universe shows through every view.
    \\//
    \\// By DEFAULT the final alpha is forced to 1 (the #else branch below).
    \\// Decorated surfaces (ext-cmdline, popupmenu, msg windows) paint their
    \\// backTex with a pre-multiplied alpha of 0 so the system blur shows
    \\// through underneath; a shader preserving that alpha would vanish there,
    \\// so forcing alpha=1 makes the shader always win. Opt in to
    \\// [shaders] preserve_alpha (the #ifdef branch) to instead keep the
    \\// terminal's alpha so window transparency/blur shows through the shader.
    \\void main() {
    \\    vec2 fragCoord = iWindowOffset + vUV * iWindowSize;
    \\    vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
    \\    mainImage(color, fragCoord);
    \\#if defined(ZONVIE_PRESERVE_ALPHA) && defined(ZONVIE_SHADER_ALPHA)
    \\    // A shader that `#define`s ZONVIE_SHADER_ALPHA owns the alpha: it
    \\    // returns premultiplied rgba, normally the terminal's alpha, raised
    \\    // where it paints something that must not let the blur through.
    \\    zonvie_fragColor = color;
    \\#elif defined(ZONVIE_PRESERVE_ALPHA)
    \\    // Preserve the terminal's alpha so window transparency/blur shows
    \\    // through the shader. backTex is premultiplied, so this matches the
    \\    // non-shader copy path for passthrough/tint shaders. Caveats: alpha is
    \\    // sampled at the unwarped vUV, so warped (CRT) shaders can mismatch at
    \\    // the edge; where backTex alpha is 0 (decorated surfaces) shaders whose
    \\    // rgb tracks alpha vanish, while additive/emissive output still leaks.
    \\    zonvie_fragColor = vec4(color.rgb, texture(zonvie_iChannel0Tex, vUV).a);
    \\#else
    \\    zonvie_fragColor = vec4(color.rgb, 1.0);
    \\#endif
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
/// Print glslang's diagnostics for a failed stage to stderr. The C ABI only
/// carries a fixed "GLSL parse failed" string, which leaves a shader author
/// guessing; the actual line/column message lives in the shader's info log.
fn logGlslangShaderInfo(shader: *glslang.glslang_shader_t, stage: []const u8) void {
    const info = glslang.glslang_shader_get_info_log(shader);
    if (info != null) {
        std.debug.print("[shader_compiler] glslang {s} failed:\n{s}\n", .{ stage, std.mem.span(info) });
    }
}

pub fn compileGlslToTarget(
    alloc: std.mem.Allocator,
    glsl_source: []const u8,
    target: Target,
) CompileError![]u8 {
    if (glsl_source.len == 0) return CompileError.EmptySource;

    ensureGlslangInit();

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
        logGlslangShaderInfo(shader, "preprocess");
        return CompileError.ParseFailed;
    }
    if (glslang.glslang_shader_parse(shader, &input) == 0) {
        logGlslangShaderInfo(shader, "parse");
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
        .glsl => spvc.SPVC_BACKEND_GLSL,
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

    // Desktop GLSL 330 without the 420pack extension: no layout(binding)
    // and no layout(location) on the varying, so a GL 3.3 driver takes it and
    // the frontend's vertex stage matches `vUV` by name.
    if (target == .glsl) {
        var options: spvc.spvc_compiler_options = undefined;
        if (spvc.spvc_compiler_create_compiler_options(compiler, &options) == spvc.SPVC_SUCCESS) {
            _ = spvc.spvc_compiler_options_set_uint(options, spvc.SPVC_COMPILER_OPTION_GLSL_VERSION, 330);
            _ = spvc.spvc_compiler_options_set_bool(options, spvc.SPVC_COMPILER_OPTION_GLSL_ES, spvc.SPVC_FALSE);
            _ = spvc.spvc_compiler_options_set_bool(options, spvc.SPVC_COMPILER_OPTION_GLSL_ENABLE_420PACK_EXTENSION, spvc.SPVC_FALSE);
            _ = spvc.spvc_compiler_options_set_bool(options, spvc.SPVC_COMPILER_OPTION_GLSL_SEPARATE_SHADER_OBJECTS, spvc.SPVC_FALSE);
            _ = spvc.spvc_compiler_install_compiler_options(compiler, options);
        }
    }

    // For MSL, SPIRV-Cross auto-remaps Vulkan bindings into compact MSL
    // slots — the UBO at Vulkan `binding = 1` typically ends up at
    // `[[buffer(0)]]` because `[[buffer]]`, `[[texture]]`, and
    // `[[sampler]]` are independent namespaces. That breaks the Swift /
    // Zig frontends which expect consistent slot numbers regardless of
    // which resources a given shader happens to use. Force an explicit
    // mapping that matches what the HLSL side emits naturally:
    //   iChannel0  → texture(0) + sampler(0)
    //   UBO        → buffer(1)
    //   iPrevFrame → texture(2) + sampler(2)
    //   iCellAge   → texture(3) + sampler(3)
    if (target == .msl) {
        var bind_ubo: spvc.spvc_msl_resource_binding = undefined;
        spvc.spvc_msl_resource_binding_init(&bind_ubo);
        bind_ubo.stage = spvc.SpvExecutionModelFragment;
        bind_ubo.desc_set = 0;
        bind_ubo.binding = 1;
        bind_ubo.msl_buffer = 1;
        _ = spvc.spvc_compiler_msl_add_resource_binding(compiler, &bind_ubo);

        var bind_tex: spvc.spvc_msl_resource_binding = undefined;
        spvc.spvc_msl_resource_binding_init(&bind_tex);
        bind_tex.stage = spvc.SpvExecutionModelFragment;
        bind_tex.desc_set = 0;
        bind_tex.binding = 0;
        bind_tex.msl_texture = 0;
        bind_tex.msl_sampler = 0;
        _ = spvc.spvc_compiler_msl_add_resource_binding(compiler, &bind_tex);

        // Zonvie edit-effect samplers. Registered unconditionally: a shader
        // that never references them produces no binding at all, and an
        // unused mapping is ignored.
        for ([_]u32{ 2, 3 }) |slot| {
            var bind_edit: spvc.spvc_msl_resource_binding = undefined;
            spvc.spvc_msl_resource_binding_init(&bind_edit);
            bind_edit.stage = spvc.SpvExecutionModelFragment;
            bind_edit.desc_set = 0;
            bind_edit.binding = slot;
            bind_edit.msl_texture = slot;
            bind_edit.msl_sampler = slot;
            _ = spvc.spvc_compiler_msl_add_resource_binding(compiler, &bind_edit);
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

/// The reference Thymer shader, compiled for real by the tests below. Kept
/// in the source rather than read from disk so the test is hermetic; it is
/// the same shape as tmp/shaders/thymer.glsl and exercises every new input.
const thymer_reference_glsl =
    \\const float EDIT_DURATION_S = 0.15;
    \\const float GHOST_TAU_S = 0.05;
    \\float sdRoundBox(vec2 p, vec2 h, float r) {
    \\    vec2 q = abs(p) - h + r;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    \\}
    \\bool insideCursorRect(vec2 p, vec4 rect) {
    \\    return p.x >= rect.x && p.x <= rect.x + rect.z &&
    \\           p.y >= rect.y - rect.w && p.y <= rect.y;
    \\}
    \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    \\    vec2 uv = fragCoord / iResolution.xy;
    \\    vec4 base = texture(iChannel0, uv);
    \\    if ((iTime - iTimeLastEdit) <= EDIT_DURATION_S) {
    \\        float t = clamp(zonvieCellAge(fragCoord) / EDIT_DURATION_S, 0.0, 1.0);
    \\        if (t < 1.0) {
    \\            float scale = max(iCellSize.y, 1.0) / 20.0;
    \\            vec4 cur = texture(iChannel0, uv) * scale;
    \\            vec4 prev = cur;
    \\            if (!insideCursorRect(fragCoord, iCurrentCursor) &&
    \\                !insideCursorRect(fragCoord, iPreviousCursor)) {
    \\                prev = texture(iPrevFrame, uv);
    \\            }
    \\            base = mix(cur, prev, exp(-iTimeDelta / GHOST_TAU_S));
    \\        }
    \\    }
    \\    if ((iCurrentCursorStyle == 2 || iCurrentCursorStyle == 3) && iCursorVisible != 0) {
    \\        vec2 p = fragCoord - vec2(iCurrentCursor.x, iCurrentCursor.y);
    \\        float sd = sdRoundBox(p, iCurrentCursor.zw * 0.5, 1.5);
    \\        float a = 1.0 - smoothstep(-0.5, 0.5, sd);
    \\        base.rgb = mix(base.rgb, iCurrentCursorColor.rgb, a);
    \\    }
    \\    fragColor = base;
    \\}
;

test "preamble uniform block matches zonvie_shader_uniforms offsets" {
    // std140 alignment silently shifts every field below a misaligned one,
    // which compiles fine and then reads the wrong bytes at runtime — that is
    // exactly how the cursor style ended up reading past the end of the
    // buffer. Compile a shader that reads the LAST field and check the
    // generated MSL addresses the struct we actually upload.
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    float a = iCellSize.x + iGridOrigin.y + iTimeLastEdit;
        \\    float b = float(iCursorVisible + iCurrentCursorStyle + iPreviousCursorStyle);
        \\    fragColor = vec4(a, b, 0.0, 1.0);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .msl);
    defer std.testing.allocator.free(out);

    // Walk the emitted MSL struct and confirm the field order survived the
    // round trip; a std140 shift reorders or inserts padding members here.
    const decl = std.mem.indexOf(u8, out, "iTimeCursorChange") orelse return error.NoUniformBlock;
    const tail = out[decl..];
    const i_cell = std.mem.indexOf(u8, tail, "iCellSize") orelse return error.NoCellSize;
    const i_orig = std.mem.indexOf(u8, tail, "iGridOrigin") orelse return error.NoGridOrigin;
    const i_last = std.mem.indexOf(u8, tail, "iTimeLastEdit") orelse return error.NoLastEdit;
    const i_vis = std.mem.indexOf(u8, tail, "iCursorVisible") orelse return error.NoCursorVisible;
    const i_cur = std.mem.indexOf(u8, tail, "iCurrentCursorStyle") orelse return error.NoCurStyle;
    const i_prev = std.mem.indexOf(u8, tail, "iPreviousCursorStyle") orelse return error.NoPrevStyle;
    try std.testing.expect(i_cell < i_orig);
    try std.testing.expect(i_orig < i_last);
    try std.testing.expect(i_last < i_vis);
    try std.testing.expect(i_vis < i_cur);
    try std.testing.expect(i_cur < i_prev);

    // The padding between iTimeCursorChange and iCellSize must be three
    // scalars. A vec2 there is the bug this test exists for: it aligns to 8
    // and pushes iCellSize from offset 160 to 168.
    const pad_region = tail[0..i_cell];
    try std.testing.expect(std.mem.indexOf(u8, pad_region, "float2 _zonvie_pad") == null);
    try std.testing.expect(std.mem.indexOf(u8, pad_region, "_zonvie_pad_cursor2") != null);
}

test "a Shadertoy shader compiles to GL 3.3 GLSL with name-bound resources" {
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec2 uv = fragCoord / iResolution.xy;
        \\    fragColor = texture(iChannel0, uv) * (0.5 + 0.5 * sin(iTime));
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .glsl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "#version 330"));
    try std.testing.expect(std.mem.indexOf(u8, out, "binding") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zonvie_iChannel0Tex") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ZonvieShaderUniforms") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "in vec2 vUV;") != null);
}

test "Thymer reference shader compiles to MSL with the Zonvie edit inputs" {
    const out = try compileGlslToTarget(std.testing.allocator, thymer_reference_glsl, .msl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "metal_stdlib") != null);
    // The slots CustomShaderPipeline.swift binds: iPrevFrame at 2, iCellAge at 3.
    try expectDeclaredAt(out, "iPrevFrame", "[[texture(2)]]");
    try expectDeclaredAt(out, "iCellAge", "[[texture(3)]]");
}

test "Thymer reference shader compiles to HLSL with the Zonvie edit inputs" {
    const out = try compileGlslToTarget(std.testing.allocator, thymer_reference_glsl, .hlsl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    // The slots d3d11_renderer.zig binds with PSSetShaderResources(2|3).
    try expectDeclaredAt(out, "iPrevFrame", "register(t2)");
    try expectDeclaredAt(out, "iCellAge", "register(t3)");
}

/// Fails unless some line of `out` declares `name` with `binding`.
fn expectDeclaredAt(out: []const u8, name: []const u8, binding: []const u8) !void {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, name) != null and std.mem.indexOf(u8, line, binding) != null) return;
    }
    std.debug.print("no line declares {s} at {s}\n", .{ name, binding });
    return error.TestExpectedBinding;
}

test "Ghostty cursor_blaze shape still compiles against the extended preamble" {
    // The uniform additions are appended, so a shader written for the
    // 160-byte Ghostty-compatible block must keep compiling untouched.
    const glsl =
        \\float ease(float x) { return pow(1.0 - x, 10.0); }
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
        \\    vec4 cc = iCurrentCursor;
        \\    vec4 pc = iPreviousCursor;
        \\    float progress = clamp((iTime - iTimeCursorChange) / 0.5, 0.0, 1.0);
        \\    float d = distance(cc.xy, pc.xy) * ease(progress);
        \\    fragColor = mix(fragColor, iCurrentCursorColor, clamp(d, 0.0, 1.0) * 0.2);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .msl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
}

test "shaders referencing Ghostty's reserved iChannel1 still fail" {
    // Zonvie deliberately does NOT claim iChannel1..3; leaving them
    // undeclared is what keeps the slot free for a future Ghostty release.
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    fragColor = texture(iChannel1, fragCoord.xy / iResolution.xy);
        \\}
    ;
    try std.testing.expectError(
        CompileError.ParseFailed,
        compileGlslToTarget(std.testing.allocator, glsl, .msl),
    );
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
    // Real Ghostty/Shadertoy shape: samples iChannel0 AND references iTime.
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec2 uv = fragCoord / iResolution.xy;
        \\    vec4 color = texture(iChannel0, uv);
        \\    fragColor = vec4(1.0 - color.x, 1.0 - color.y, 1.0 - color.z + 0.001 * sin(iTime), color.w);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .msl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "metal_stdlib") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "iResolution") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "iTime") != null);
    // Pin the MSL resource mapping Swift relies on. Without the explicit
    // spvc_compiler_msl_add_resource_binding calls in crossCompileSpirv,
    // SPIRV-Cross auto-remaps the UBO to [[buffer(0)]] and the texture
    // sample falls over with garbage uniforms (observed as a pure-white
    // screen when negative.glsl was first tested on macOS).
    try std.testing.expect(std.mem.indexOf(u8, out, "[[buffer(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[[texture(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[[sampler(0)]]") != null);
}

test "compile Shadertoy-style mainImage source to HLSL with auto-wrap" {
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec2 uv = fragCoord / iResolution.xy;
        \\    vec4 color = texture(iChannel0, uv);
        \\    fragColor = vec4(1.0 - color.x, 1.0 - color.y, 1.0 - color.z + 0.001 * sin(iTime), color.w);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .hlsl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "iTime") != null);
    // HLSL preserves Vulkan binding indices by default.
    try std.testing.expect(std.mem.indexOf(u8, out, "register(b1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "register(t0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "register(s0)") != null);
}

test "screen-space texture wrappers never emit an implicit-gradient Sample" {
    // A gradient sample under divergent control flow makes D3DCompile try
    // to unroll the enclosing loop; with a variable trip count it hangs.
    const glsl =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec3 acc = vec3(0.0);
        \\    int n = int(iTime) & 7;
        \\    for (int i = 0; i < n; i++) {
        \\        vec2 uv = (fragCoord + vec2(float(i), 0.0)) / iResolution.xy;
        \\        vec3 c = texture(iChannel0, uv).rgb;
        \\        if (c.r < 0.5) continue;
        \\        acc += c + texture(iPrevFrame, uv).rgb;
        \\    }
        \\    fragColor = vec4(acc, 1.0);
        \\}
    ;
    const out = try compileGlslToTarget(std.testing.allocator, glsl, .hlsl);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ".Sample(") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zonvie_iChannel0Tex.SampleLevel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zonvie_iPrevFrameTex.SampleLevel(") != null);
}

test "ZONVIE_SHADER_ALPHA hands the alpha to the shader under preserve_alpha" {
    // The colour the shader writes, alpha included, reaches the output only
    // when the shader opted in; plain preserve_alpha replaces the alpha with
    // the terminal's.
    const body =
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    fragColor = vec4(texture(iChannel0, fragCoord / iResolution.xy).rgb, 0.375);
        \\}
    ;
    const owned = try compileGlslToTarget(std.testing.allocator, "#define ZONVIE_PRESERVE_ALPHA 1\n#define ZONVIE_SHADER_ALPHA 1\n" ++ body, .msl);
    defer std.testing.allocator.free(owned);
    try std.testing.expect(std.mem.indexOf(u8, owned, "out.zonvie_fragColor = color;") != null);

    const pinned = try compileGlslToTarget(std.testing.allocator, "#define ZONVIE_PRESERVE_ALPHA 1\n" ++ body, .msl);
    defer std.testing.allocator.free(pinned);
    try std.testing.expect(std.mem.indexOf(u8, pinned, "out.zonvie_fragColor = color;") == null);
}
