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
    /// True when the user GLSL references a time-varying Shadertoy
    /// uniform (iTime / iTimeDelta / iFrame / iFrameRate / iMouse /
    /// iDate). Populated by the renderer after reading the source so the
    /// renderer knows to run a ~60Hz WM_TIMER loop instead of relying
    /// purely on flush-driven WM_PAINT.
    needs_animation: bool = false,

    pub fn deinit(self: *CustomShaderPipeline) void {
        if (self.pixel_shader) |ps| {
            const vtbl = ps.*.lpVtbl;
            if (vtbl.*.Release) |rel| _ = rel(ps);
            self.pixel_shader = null;
        }
        self.alloc.free(self.source_path);
    }

    /// Whole-word scan for animation-driving Shadertoy uniforms. Only
    /// list uniforms whose values actually change per frame in this
    /// build — iResolution / iSampleRate / iChannel0 are constant, and
    /// iMouse is unimplemented (stays zero) so referencing it must not
    /// arm the 60 Hz ticker.
    pub fn detectNeedsAnimation(source: []const u8) bool {
        const tokens = [_][]const u8{
            "iTime",
            "iTimeDelta",
            "iFrame",
            "iFrameRate",
            "iDate",
        };
        for (tokens) |tok| {
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, source, search, tok)) |pos| {
                const before_ok = pos == 0 or !isWordPart(source[pos - 1]);
                const after_idx = pos + tok.len;
                const after_ok = after_idx >= source.len or !isWordPart(source[after_idx]);
                if (before_ok and after_ok) return true;
                search = after_idx;
            }
        }
        return false;
    }

    fn isWordPart(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_';
    }
};
