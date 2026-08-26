const std = @import("std");

// Resolve the build-time version string from git. Returns the output of
// `git describe --tags --always --dirty` (e.g. "v0.3.21", "v0.3.21-9-g4eb0177",
// or "v0.3.21-dirty"). Falls back to "0.0.0-unknown" when git is unavailable
// (e.g. a shallow CI checkout with no tags, or a source tarball without .git).
fn gitVersion(b: *std.Build) []const u8 {
    // Zig 0.16: process spawning in build scripts goes through the build
    // graph's Io. `runAllowFail` returns captured stdout or an error we map to
    // the unknown-version fallback.
    var code: u8 = undefined;
    const stdout = b.runAllowFail(
        &.{ "git", "describe", "--tags", "--always", "--dirty" },
        &code,
        .ignore,
    ) catch return "0.0.0-unknown";
    return std.mem.trim(u8, stdout, " \t\r\n");
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const host_os = @import("builtin").os.tag;

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
    // Zig 0.16: link* methods live on the Module, not the Compile step.
    const glslang_lib = glslang_dep.artifact("glslang");
    core_mod.linkLibrary(glslang_lib);

    // Link SPIRV-Cross static library.
    const spirv_cross_lib = spirv_cross_dep.artifact("spirv_cross");
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
    // Zig 0.16: link* and resource files live on the Module, not Compile.
    win_mod.linkLibrary(core_lib);

    // Add Windows application icon
    win_mod.addWin32ResourceFile(.{
        .file = b.path("windows/resources/zonvie.rc"),
    });

    // Win32 GUI basics (GDI).
    if (target.result.os.tag == .windows) {
        win_mod.linkSystemLibrary("user32", .{});
        win_mod.linkSystemLibrary("gdi32", .{});
        win_mod.linkSystemLibrary("kernel32", .{});
        win_mod.linkSystemLibrary("imm32", .{}); // IME support

        // --- Add: DirectWrite/Direct2D + COM ---
        win_mod.linkSystemLibrary("dwrite", .{});
        win_mod.linkSystemLibrary("d2d1", .{});
        win_mod.linkSystemLibrary("ole32", .{});

        // --- Add: D3D11 + DXGI (+ D3DCompiler for runtime shader compile) ---
        win_mod.linkSystemLibrary("d3d11", .{});
        win_mod.linkSystemLibrary("dxgi", .{});
        win_mod.linkSystemLibrary("d3dcompiler_47", .{});

        // --- Add: DirectComposition + DWM for transparency ---
        win_mod.linkSystemLibrary("dcomp", .{});
        win_mod.linkSystemLibrary("dwmapi", .{});

        // --- Add: CredUI for password dialogs ---
        win_mod.linkSystemLibrary("credui", .{});

        // --- Add: Registry + Shell for file associations ---
        win_mod.linkSystemLibrary("advapi32", .{});
        win_mod.linkSystemLibrary("shell32", .{});

        // --- Timer resolution for reducing scheduler quantum ---
        win_mod.linkSystemLibrary("winmm", .{});

        // --- AlphaBlend (color-emoji tab indicator composite) ---
        win_mod.linkSystemLibrary("msimg32", .{});

        // --- ChooseFontW (`:set guifont=*` font picker) ---
        win_mod.linkSystemLibrary("comdlg32", .{});
    }

    const install_win = b.addInstallArtifact(win_exe, .{
        .dest_dir = .{ .override = .{ .custom = "../windows/zig-out" } },
    });
    const windows_step = b.step("windows", "Build Windows frontend");
    windows_step.dependOn(&install_win.step);

    // Win32 contract test for the top-level HWND wake cookie storage. Compile
    // it with every Windows frontend build; execute it when the build host can
    // create a real Win32 window.
    const wake_state_test_mod = b.createModule(.{
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("test/windows/wake_state_integration.zig"),
    });
    wake_state_test_mod.linkSystemLibrary("user32", .{});
    wake_state_test_mod.linkSystemLibrary("kernel32", .{});
    const wake_state_tests = b.addTest(.{
        .name = "zonvie-wake-state-test",
        .root_module = wake_state_test_mod,
    });
    windows_step.dependOn(&wake_state_tests.step);
    const wake_state_test_step = b.step("windows-wake-state-test", "Build the top-level HWND wake-state integration test");
    wake_state_test_step.dependOn(&b.addInstallArtifact(wake_state_tests, .{}).step);

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    if (host_os == .windows and target.result.os.tag == .windows) {
        test_step.dependOn(&b.addRunArtifact(wake_state_tests).step);
    }

    // macOS external-grid font reset intersection test. It uses barriers to
    // force the notification/commit ordering that previously erased freshly
    // committed row counts.
    if (target.result.os.tag == .macos) {
        const compile_font_reset_test = b.addSystemCommand(&.{ "xcrun", "swiftc" });
        compile_font_reset_test.addArgs(&.{
            "-sanitize=thread",
            "-module-cache-path",
            "/tmp/zonvie-swift-module-cache",
        });
        compile_font_reset_test.addFileArg(b.path("macos/Sources/Rendering/ExternalFontResetState.swift"));
        compile_font_reset_test.addFileArg(b.path("macos/Sources/Core/FlushRetryBackoff.swift"));
        compile_font_reset_test.addFileArg(b.path("macos/Tests/ExternalFontResetStateTests.swift"));
        compile_font_reset_test.addArg("-o");
        const font_reset_test_exe = compile_font_reset_test.addOutputFileArg("external-font-reset-tests");
        const run_font_reset_test = b.addSystemCommand(&.{"/usr/bin/env"});
        run_font_reset_test.addFileArg(font_reset_test_exe);
        test_step.dependOn(&run_font_reset_test.step);

        // Metal row provisioning must retain each successful private-buffer
        // prefix across retries while committed row content remains untouched.
        const compile_row_provision_test = b.addSystemCommand(&.{ "xcrun", "swiftc" });
        compile_row_provision_test.addArgs(&.{
            "-module-cache-path",
            "/tmp/zonvie-swift-module-cache",
        });
        compile_row_provision_test.addFileArg(b.path("macos/Sources/Rendering/MetalTypes.swift"));
        compile_row_provision_test.addFileArg(b.path("macos/Tests/SurfaceRowProvisionTests.swift"));
        compile_row_provision_test.addArg("-o");
        const row_provision_test_exe = compile_row_provision_test.addOutputFileArg("surface-row-provision-tests");
        const run_row_provision_test = b.addSystemCommand(&.{"/usr/bin/env"});
        run_row_provision_test.addFileArg(row_provision_test_exe);
        test_step.dependOn(&run_row_provision_test.step);

        // Baseline placement inside a cell: FreeType's grid-fitted metrics
        // overflow the line height it reports, and anchoring on them clips the
        // glyph at the cell edge where rows join.
        const compile_font_cell_fit_test = b.addSystemCommand(&.{ "xcrun", "swiftc" });
        compile_font_cell_fit_test.addArgs(&.{
            "-module-cache-path",
            "/tmp/zonvie-swift-module-cache",
        });
        compile_font_cell_fit_test.addFileArg(b.path("macos/Sources/Font/FontCellFit.swift"));
        compile_font_cell_fit_test.addFileArg(b.path("macos/Tests/FontCellFitTests.swift"));
        compile_font_cell_fit_test.addArg("-o");
        const font_cell_fit_test_exe = compile_font_cell_fit_test.addOutputFileArg("font-cell-fit-tests");
        const run_font_cell_fit_test = b.addSystemCommand(&.{"/usr/bin/env"});
        run_font_cell_fit_test.addFileArg(font_cell_fit_test_exe);
        test_step.dependOn(&run_font_cell_fit_test.step);

        // Smooth-scroll retained rows: which rows a scroll pushes off the edge,
        // where they must be drawn, and that staged rows reach the screen only
        // through their own bracket's commit.
        const compile_scroll_retention_test = b.addSystemCommand(&.{ "xcrun", "swiftc" });
        compile_scroll_retention_test.addArgs(&.{
            "-module-cache-path",
            "/tmp/zonvie-swift-module-cache",
        });
        compile_scroll_retention_test.addFileArg(b.path("macos/Sources/Rendering/MetalTypes.swift"));
        compile_scroll_retention_test.addFileArg(b.path("macos/Tests/ScrollRetentionTests.swift"));
        compile_scroll_retention_test.addArg("-o");
        const scroll_retention_test_exe = compile_scroll_retention_test.addOutputFileArg("scroll-retention-tests");
        const run_scroll_retention_test = b.addSystemCommand(&.{"/usr/bin/env"});
        run_scroll_retention_test.addFileArg(scroll_retention_test_exe);
        test_step.dependOn(&run_scroll_retention_test.step);
    }

    // Core inline tests (c_api.zig and its relative imports, including the
    // redraw/flush/atlas transaction tests). Test files that import the core
    // as a separate module do not execute the dependency module's own tests.
    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

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

    // Cursor style tests: mode_info_set must re-resolve the current mode.
    const cursor_style_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/cursor_style_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const cursor_style_tests = b.addTest(.{
        .root_module = cursor_style_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(cursor_style_tests).step);

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

    // Message routing tests. msg_route.zig is std-only, so it is exposed as a
    // standalone module rather than pulled in through zonvie_core.
    const msg_route_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/msg_route.zig"),
    });
    const msg_route_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/msg_route_test.zig"),
        .imports = &.{
            .{ .name = "msg_route", .module = msg_route_mod },
        },
    });
    const msg_route_tests = b.addTest(.{
        .root_module = msg_route_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(msg_route_tests).step);

    // Message view lifecycle tests. msg_view.zig depends only on msg_route.zig.
    const msg_view_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/core/msg_view.zig"),
    });
    const msg_view_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/msg_view_test.zig"),
        .imports = &.{
            .{ .name = "msg_view", .module = msg_view_mod },
        },
    });
    const msg_view_tests = b.addTest(.{
        .root_module = msg_view_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(msg_view_tests).step);

    // Split-view Lua generation. Needs the core module for Core.buildSplitLua.
    const msg_split_lua_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("test/msg_split_lua_test.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const msg_split_lua_tests = b.addTest(.{
        .root_module = msg_split_lua_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(msg_split_lua_tests).step);

    // Platform-independent Windows damage compaction regression tests.
    const windows_render_helpers_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("windows/render_pipeline_helpers_test.zig"),
    });
    const windows_render_helpers_tests = b.addTest(.{
        .root_module = windows_render_helpers_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(windows_render_helpers_tests).step);

    // Platform-independent placement tests for the ext_messages floats.
    const windows_msg_float_layout_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("windows/ui/msg_float_layout_test.zig"),
    });
    const windows_msg_float_layout_tests = b.addTest(.{
        .root_module = windows_msg_float_layout_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(windows_msg_float_layout_tests).step);

    // Platform-independent coverage for the Windows frontend's lossy,
    // non-blocking logging queue.
    const windows_app_log_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("windows/app_log.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
        },
    });
    const windows_app_log_tests = b.addTest(.{
        .root_module = windows_app_log_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(windows_app_log_tests).step);

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

    // E2E harness: drives a REAL headless nvim through the core pipeline
    // (rpc_session → redraw_handler → grid → flush) and asserts on logical
    // grid state. Separate `zig build e2e` step (not part of `zig build
    // test`) because it needs an nvim binary at runtime.
    const e2e_step = b.step("e2e", "Run headless E2E tests against a real nvim");
    const e2e_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("test/e2e/runner.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });
    const e2e_tests = b.addTest(.{
        .root_module = e2e_mod,
    });
    const e2e_run = b.addRunArtifact(e2e_tests);
    // Force rerun — results depend on the external nvim binary.
    e2e_run.has_side_effects = true;
    e2e_step.dependOn(&e2e_run.step);

    // GUI test driver (macOS and Windows hosts): launches the REAL zonvie
    // app against a shared `nvim --listen` server and observes OS windows
    // (CGWindowList / EnumWindows). Local-only (real windows appear);
    // `zig build gui-test` on the respective host.
    if (host_os == .macos or host_os == .windows) {
        const gui_step = b.step("gui-test", "Run GUI tests against the real zonvie app (local only)");
        const gui_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .root_source_file = b.path("test/gui/runner.zig"),
        });
        if (host_os == .macos) {
            gui_mod.linkFramework("CoreGraphics", .{});
            gui_mod.linkFramework("CoreFoundation", .{});
            gui_mod.linkFramework("ImageIO", .{}); // CGImageDestination/Source (PNG)
            gui_mod.linkFramework("ApplicationServices", .{}); // AXUIElement (drag-resize emulation)
        } else {
            gui_mod.linkSystemLibrary("user32", .{});
            gui_mod.linkSystemLibrary("gdi32", .{}); // DIB capture
        }
        const gui_tests = b.addTest(.{
            .root_module = gui_mod,
        });
        const gui_run = b.addRunArtifact(gui_tests);
        // Force rerun — results depend on the external app and nvim.
        gui_run.has_side_effects = true;
        gui_step.dependOn(&gui_run.step);
    }

    // Cross-compile check for the Windows GUI test binary (no run). Lets a
    // macOS host verify the Windows driver compiles; the artifact installs
    // to zig-out/bin/zonvie-gui-test.exe and can be run on a Windows box
    // (a Windows host should normally just use `zig build gui-test`).
    const gui_win_step = b.step("gui-test-windows", "Build the Windows GUI test binary (compile only)");
    const gui_win_mod = b.createModule(.{
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("test/gui/runner.zig"),
    });
    gui_win_mod.linkSystemLibrary("user32", .{});
    gui_win_mod.linkSystemLibrary("gdi32", .{});
    const gui_win_tests = b.addTest(.{
        .name = "zonvie-gui-test",
        .root_module = gui_win_mod,
    });
    gui_win_step.dependOn(&b.addInstallArtifact(gui_win_tests, .{}).step);

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
