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
    core_lib.bundle_compiler_rt = true;
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

        // --- Timer resolution for reducing scheduler quantum ---
        win_exe.linkSystemLibrary("winmm");
    }

    const install_win = b.addInstallArtifact(win_exe, .{
        .dest_dir = .{ .override = .{ .custom = "../windows/zig-out" } },
    });
    const windows_step = b.step("windows", "Build Windows frontend");
    windows_step.dependOn(&install_win.step);

    // Linux frontend
    //
    // All GTK4/GLib/GDK/OpenGL/fontconfig/hbft functions use hand-written
    // extern "c" declarations (no @cImport, no zig-gobject). This enables
    // cross-compilation from macOS without system headers.
    const linux_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("linux/main.zig"),
        .imports = &.{
            .{ .name = "zonvie_core", .module = core_mod },
            .{ .name = "toml", .module = zig_toml.module("toml") },
        },
    });

    const is_cross = !target.query.isNative();

    const linux_exe = b.addExecutable(.{
        .name = "zonvie",
        .root_module = linux_mod,
    });
    linux_exe.linkLibrary(core_lib);

    // HarfBuzz/FreeType bridge (shared C implementation used by all frontends).
    linux_exe.addCSourceFile(.{
        .file = b.path("macos/Sources/Font/HBFTBridge.c"),
        .flags = &.{},
    });

    // System libraries (linked at link time only, no C header processing).
    if (target.result.os.tag == .linux and !is_cross) {
        linux_exe.linkSystemLibrary("gtk-4");
        linux_exe.linkSystemLibrary("epoxy");
        linux_exe.linkSystemLibrary("GL");
        linux_exe.linkSystemLibrary("freetype2");
        linux_exe.linkSystemLibrary("harfbuzz");
        linux_exe.linkSystemLibrary("fontconfig");
        // GLib/GObject/GIO (needed explicitly when pkg-config transitive deps
        // are not propagated by the Zig build system linker).
        linux_exe.linkSystemLibrary("glib-2.0");
        linux_exe.linkSystemLibrary("gobject-2.0");
        linux_exe.linkSystemLibrary("gio-2.0");
    }

    const linux_step = b.step("linux", "Build Linux frontend");

    if (is_cross) {
        // Cross-compilation (e.g. from macOS): system .so files are not
        // available. Produce a compiled object to verify Zig compilation
        // succeeds. The full executable must be built natively on Linux.
        const linux_obj = b.addObject(.{
            .name = "zonvie",
            .root_module = linux_mod,
        });
        linux_obj.linkLibrary(core_lib);
        linux_step.dependOn(&linux_obj.step);
    } else {
        const install_linux = b.addInstallArtifact(linux_exe, .{
            .dest_dir = .{ .override = .{ .custom = "../linux/zig-out" } },
        });
        linux_step.dependOn(&install_linux.step);
    }

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
}
