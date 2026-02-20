const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // TOML parser dependency
    const zig_toml = b.dependency("zig-toml", .{
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/core/c_api.zig"),
        .imports = &.{
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });

    const core_lib = b.addLibrary(.{
        .name = "zonvie_core",
        .linkage = .static,
        .root_module = core_mod,
    });
    b.installArtifact(core_lib);

    // Core-only step for macOS
    const core_step = b.step("core", "Build core library only");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);

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
    }

    const install_win = b.addInstallArtifact(win_exe, .{});
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
}
