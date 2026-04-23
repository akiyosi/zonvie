//! Thin Zig build wrapper around KhronosGroup/SPIRV-Cross.
//!
//! Produces a static library named `spirv_cross` exposing SPIRV-Cross's
//! C API (spirv_cross_c.h). Only the GLSL / HLSL / MSL backends are
//! enabled — Zonvie does not need the C++ or reflection backends.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("upstream", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const lib = b.addLibrary(.{
        .name = "spirv_cross",
        .linkage = .static,
        .root_module = mod,
    });

    const cpp_sources = [_][]const u8{
        "spirv_cross.cpp",
        "spirv_parser.cpp",
        "spirv_cross_parsed_ir.cpp",
        "spirv_cfg.cpp",
        "spirv_cross_util.cpp",
        "spirv_glsl.cpp",
        "spirv_hlsl.cpp",
        "spirv_msl.cpp",
        "spirv_cross_c.cpp",
    };

    // SPIRV-Cross C API uses C++ exceptions to signal errors. Keep RTTI
    // and exceptions enabled.
    const cpp_flags = [_][]const u8{
        "-std=c++17",
        "-fvisibility=hidden",
        "-DSPIRV_CROSS_C_API_GLSL=1",
        "-DSPIRV_CROSS_C_API_HLSL=1",
        "-DSPIRV_CROSS_C_API_MSL=1",
        "-DSPIRV_CROSS_C_API_CPP=0",
        "-DSPIRV_CROSS_C_API_REFLECT=0",
    };

    lib.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &cpp_sources,
        .flags = &cpp_flags,
    });

    // Let consumers include <spirv_cross_c.h>. The C header pulls in
    // <spirv.h> (SPIR-V core header) so we install that too.
    lib.addIncludePath(upstream.path("."));
    lib.installHeader(upstream.path("spirv_cross_c.h"), "spirv_cross_c.h");
    lib.installHeader(upstream.path("spirv.h"), "spirv.h");

    b.installArtifact(lib);
}
