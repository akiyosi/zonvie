//! Windows D3D11 custom post-process shader descriptor.
//!
//! Mirror of `macos/Sources/Rendering/CustomShaderPipeline.swift`.
//! The struct is intentionally thin: it owns a single compiled
//! `ID3D11PixelShader` and the source path it was compiled from. All the
//! machinery for loading a GLSL file, cross-compiling it to HLSL via the
//! core C ABI, and invoking `D3DCompile` lives on `d3d11_renderer.zig`'s
//! `Renderer` (so it can reuse the existing `ID3DBlob` helpers and
//! d3dcompiler_47 linkage already set up there).

const std = @import("std");
const c = @import("../win32.zig").c;

pub const CustomShaderPipeline = struct {
    alloc: std.mem.Allocator,
    /// Original source path, duped into `alloc` — used for error logging
    /// and eventual hot-reload support in Phase 8.
    source_path: []u8,
    /// Compiled pixel shader. Released in `deinit`.
    pixel_shader: ?*c.ID3D11PixelShader,

    pub fn deinit(self: *CustomShaderPipeline) void {
        if (self.pixel_shader) |ps| {
            const vtbl = ps.*.lpVtbl;
            if (vtbl.*.Release) |rel| _ = rel(ps);
            self.pixel_shader = null;
        }
        self.alloc.free(self.source_path);
    }
};
