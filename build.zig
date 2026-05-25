const std = @import("std");

// Resolve the build-time version string from git. Returns the output of
// `git describe --tags --always --dirty` (e.g. "v0.3.21", "v0.3.21-9-g4eb0177",
// or "v0.3.21-dirty"). Falls back to "0.0.0-unknown" when git is unavailable
// (e.g. a shallow CI checkout with no tags, or a source tarball without .git).
fn gitVersion(b: *std.Build) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "describe", "--tags", "--always", "--dirty" },
        .cwd = b.build_root.path,
    }) catch return "0.0.0-unknown";
    switch (result.term) {
        .Exited => |code| if (code != 0) return "0.0.0-unknown",
        else => return "0.0.0-unknown",
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // TOML parser dependency
    const zig_toml = b.dependency("zig-toml", .{
        .target = target,
        .optimize = optimize,
    });

    // Shader-compile dependency: glslang (GLSL -> SPIR-V).
    // Games-by-Mason's Zig-0.15-compatible port. Pulls upstream
    // KhronosGroup/glslang + SPIRV-Tools + SPIRV-Headers as transitive deps.
    //
    // We always build the shader-compile deps with ReleaseFast regardless
    // of the parent optimize mode. Rationale: Zig's Debug mode enables
    // UBSan for C/C++ code and references __ubsan_* runtime symbols. Those
    // do not cascade through static-lib-to-static-lib linkage, so Xcode
    // (which links the merged archive without a UBSan runtime) cannot
    // resolve them. Shader compilation is a startup-time operation where
    // Debug/ReleaseFast tradeoff is irrelevant.
    const shader_dep_optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const glslang_dep = b.dependency("glslang", .{
        .target = target,
        .optimize = shader_dep_optimize,
    });

    // Shader-compile dependency: SPIRV-Cross (SPIR-V -> MSL / HLSL).
    // Locally vendored wrapper under pkg/spirv_cross/. Fetches upstream
    // KhronosGroup/SPIRV-Cross via the Zig package manager.
    const spirv_cross_dep = b.dependency("spirv_cross", .{
        .target = target,
        .optimize = shader_dep_optimize,
    });

    // Build-time options module. Carries the git-derived version string,
    // consumed by c_api.zig to back zonvie_version(). createModule() is called
    // per consumer so each gets its own import of the same option set.
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", gitVersion(b));

    const core_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/core/c_api.zig"),
        .imports = &.{
            .{ .name = "toml", .module = zig_toml.module("toml") },
            .{ .name = "build_options", .module = build_opts.createModule() },
        },
    });

    const core_lib = b.addLibrary(.{
        .name = "zonvie_core",
        .linkage = .static,
        .root_module = core_mod,
    });
    core_lib.bundle_compiler_rt = true;

    // Link glslang static library into core_lib so its symbols are
    // available to zonvie_shader_compile_glsl. Headers installed by the
    // upstream package become visible to the core module's C translation.
    const glslang_lib = glslang_dep.artifact("glslang");
    core_lib.linkLibrary(glslang_lib);
    core_mod.linkLibrary(glslang_lib);

    // Link SPIRV-Cross static library.
    const spirv_cross_lib = spirv_cross_dep.artifact("spirv_cross");
    core_lib.linkLibrary(spirv_cross_lib);
    core_mod.linkLibrary(spirv_cross_lib);

    b.installArtifact(core_lib);

    // glslang has many transitive static libraries (MachineIndependent,
    // OSDependent, GenericCodeGen, SPIRV, SPIRV-Tools + its family). They
    // are automatically propagated for Zig-built consumers (zonvie.exe on
    // Windows) but NOT for the Xcode-linked macOS app. Install each one so
    // the macOS Xcode build script can merge them into a single archive.
    const shader_dep_lib_names = [_][]const u8{
        "glslang",
        "MachineIndependent",
        "OSDependent",
        "GenericCodeGen",
        "SPIRV",
        "SPVRemapper",
        "glslang-default-resource-limits",
        "SPIRV-Tools",
        "SPIRV-Tools-opt",
        "SPIRV-Tools-link",
        "SPIRV-Tools-reduce",
    };

    // Core-only step for macOS. Installs zonvie_core plus every shader
    // dep library into zig-out/lib so the Xcode script can libtool them
    // into one merged libzonvie_core.a.
    const core_step = b.step("core", "Build core library only");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);
    for (shader_dep_lib_names) |name| {
        const lib = glslang_dep.artifact(name);
        const install_step = b.addInstallArtifact(lib, .{});
        b.getInstallStep().dependOn(&install_step.step);
        core_step.dependOn(&install_step.step);
    }
    {
        const install_step = b.addInstallArtifact(spirv_cross_lib, .{});
        b.getInstallStep().dependOn(&install_step.step);
        core_step.dependOn(&install_step.step);
    }

    const win_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("windows/main.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
        .omit_frame_pointer = false,
    });

    const win_exe = b.addExecutable(.{
        .name = "zonvie",
        .root_module = win_mod,
    });
    win_exe.subsystem = .Windows;
    win_exe.linkLibrary(core_lib);

    // Add Windows application icon
    win_exe.addWin32ResourceFile(.{
        .file = b.path("windows/resources/zonvie.rc"),
    });

    // Win32 GUI basics (GDI).
    if (target.result.os.tag == .windows) {
        win_exe.linkSystemLibrary("user32");
        win_exe.linkSystemLibrary("gdi32");
        win_exe.linkSystemLibrary("kernel32");
        win_exe.linkSystemLibrary("imm32"); // IME support

        // --- Add: DirectWrite/Direct2D + COM ---
        win_exe.linkSystemLibrary("dwrite");
        win_exe.linkSystemLibrary("d2d1");
        win_exe.linkSystemLibrary("ole32");

        // --- Add: D3D11 + DXGI (+ D3DCompiler for runtime shader compile) ---
        win_exe.linkSystemLibrary("d3d11");
        win_exe.linkSystemLibrary("dxgi");
        win_exe.linkSystemLibrary("d3dcompiler_47");

        // --- Add: DirectComposition + DWM for transparency ---
        win_exe.linkSystemLibrary("dcomp");
        win_exe.linkSystemLibrary("dwmapi");

        // --- Add: CredUI for password dialogs ---
        win_exe.linkSystemLibrary("credui");

        // --- Add: Registry + Shell for file associations ---
        win_exe.linkSystemLibrary("advapi32");
        win_exe.linkSystemLibrary("shell32");

        // --- Timer resolution for reducing scheduler quantum ---
        win_exe.linkSystemLibrary("winmm");
    }

    const install_win = b.addInstallArtifact(win_exe, .{
        .dest_dir = .{ .override = .{ .custom = "../windows/zig-out" } },
    });
    const windows_step = b.step("windows", "Build Windows frontend");
    windows_step.dependOn(&install_win.step);

    // Unit tests
    const test_step = b.step("test", "Run unit tests");

    // Key input tests
    const key_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/key_input_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const key_tests = b.addTest(.{
        .root_module = key_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(key_tests).step);

    // MessagePack tests
    const msgpack_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/msgpack_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const msgpack_tests = b.addTest(.{
        .root_module = msgpack_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(msgpack_tests).step);

    // Streaming MessagePack decoder tests (inline tests in src/core/mpack_stream.zig)
    const mpack_stream_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/mpack_stream.zig"),
    });
    const mpack_stream_tests = b.addTest(.{
        .root_module = mpack_stream_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(mpack_stream_tests).step);

    // RPC transport address-parser tests (inline tests in src/core/rpc_transport.zig).
    const rpc_transport_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/rpc_transport.zig"),
    });
    const rpc_transport_tests = b.addTest(.{
        .root_module = rpc_transport_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(rpc_transport_tests).step);

    // Shader cross-compile tests (inline tests in src/core/shader_compiler.zig).
    // Requires glslang + SPIRV-Cross linked.
    const shader_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .root_source_file = b.path("src/core/shader_compiler.zig"),
    });
    shader_test_mod.linkLibrary(glslang_lib);
    shader_test_mod.linkLibrary(spirv_cross_lib);
    const shader_tests = b.addTest(.{
        .root_module = shader_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(shader_tests).step);

    // Redraw parity tests: identical byte streams through mp.decode+handleRedraw
    // vs handleRedrawStream must produce bit-identical grid/hl/callback state.
    const redraw_parity_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/redraw_parity_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const redraw_parity_tests = b.addTest(.{
        .root_module = redraw_parity_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(redraw_parity_tests).step);

    // Scroll fast path tests
    const scroll_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/scroll_fast_path_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const scroll_tests = b.addTest(.{
        .root_module = scroll_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(scroll_tests).step);

    // Cell overflow map tests
    const overflow_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/cell_overflow_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const overflow_tests = b.addTest(.{
        .root_module = overflow_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(overflow_tests).step);

    // Font feature / variable axis parsing tests
    const font_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/font_feature_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const font_tests = b.addTest(.{
        .root_module = font_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(font_tests).step);

    // [font] family candidate-list formatter tests
    const font_family_list_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/font_family_list_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const font_family_list_tests = b.addTest(.{
        .root_module = font_family_list_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(font_family_list_tests).step);

    // Ligature vertex tests
    const lig_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/ligature_vertex_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const lig_tests = b.addTest(.{
        .root_module = lig_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(lig_tests).step);

    // mpack decode-path micro benchmark. Built in ReleaseFast regardless
    // of the top-level optimize option so numbers reflect release perf.
    // Run: `zig build bench`.
    const bench_step = b.step("bench", "Run mpack decode-path benchmarks (ReleaseFast)");
    const bench_core_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .root_source_file = b.path("src/core/c_api.zig"),
        .imports = &.{
            .{ .name = "toml", .module = zig_toml.module("toml") },
            .{ .name = "build_options", .module = build_opts.createModule() },
        },
    });
    const bench_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("test/mpack_bench.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = bench_core_mod },
        },
    });
    const bench_tests = b.addTest(.{
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_tests);
    // Force rerun — benchmarks are not cached.
    bench_run.has_side_effects = true;
    bench_step.dependOn(&bench_run.step);
}
