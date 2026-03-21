// compiled_shaders.zig — Embedded GLSL shader sources for Linux OpenGL renderer.
//
// Shaders are stored as compile-time string literals with #define prepended
// to select shader stages from the unified main.glsl file.

const std = @import("std");

// The raw GLSL source from main.glsl (embedded at compile time)
const main_glsl = @embedFile("main.glsl");

// GLSL version header (OpenGL 4.5 core profile)
const version_header = "#version 450 core\n";

// =========================================================================
// Vertex Shaders
// =========================================================================

/// Main vertex shader (used by all geometry passes: background, glyph, glow extract)
pub const vs_main = version_header ++ "#define VERTEX_SHADER\n" ++ main_glsl;

/// Fullscreen triangle vertex shader (used by glow downsample, upsample, composite)
pub const vs_fullscreen = version_header ++ "#define VERTEX_SHADER_FULLSCREEN\n" ++ main_glsl;

// =========================================================================
// Fragment Shaders
// =========================================================================

/// Main fragment shader (background + glyph + decoration rendering)
pub const fs_main = version_header ++ "#define FRAGMENT_SHADER_MAIN\n" ++ main_glsl;

/// Glow extract fragment shader (extracts DECO_GLOW vertices for bloom)
pub const fs_glow_extract = version_header ++ "#define FRAGMENT_SHADER_GLOW_EXTRACT\n" ++ main_glsl;

/// Dual Kawase downsample fragment shader (bloom blur pass)
pub const fs_kawase_down = version_header ++ "#define FRAGMENT_SHADER_KAWASE_DOWN\n" ++ main_glsl;

/// Dual Kawase upsample fragment shader (bloom blur pass)
pub const fs_kawase_up = version_header ++ "#define FRAGMENT_SHADER_KAWASE_UP\n" ++ main_glsl;

/// Glow composite fragment shader (additive blend of blurred glow)
pub const fs_glow_composite = version_header ++ "#define FRAGMENT_SHADER_GLOW_COMPOSITE\n" ++ main_glsl;
