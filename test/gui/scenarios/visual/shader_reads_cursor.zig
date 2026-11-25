// visual/shader_reads_cursor — the native cursor is part of the frame a
// custom shader reads (iChannel0), on every frontend.
//
// A shader that repaints or moves the frame has to meet the cursor the same
// way everywhere: in the frame, as Ghostty hands it over. A frontend that
// composites the cursor after the chain instead shows it undeformed over a
// shader that bends the page, and lets a shader that repaints a cell paint
// nothing over the cursor there, while the same shader hides the cursor on
// the frontends that draw it first.
//
// The probe swaps red and blue. The cursor is made pure red on a black
// page: read by the shader it shows blue, drawn after the shader it stays
// red.

const std = @import("std");
const fixture = @import("fixture.zig");
const driver = @import("../../driver.zig");

const log_path = "tmp/gui_shader_reads_cursor.log";

/// A block cursor at 13pt covers some hundreds of pixels at 1x and four
/// times that at 2x; the floor only has to tell a cursor from stray pixels.
const min_cursor_px: usize = 60;

const Counts = struct { red: usize, blue: usize };

/// Red and blue pixels below the top eighth of the capture: the title bar's
/// close button is red too, and no shader reaches it.
fn countCursorColours(img: driver.capture.Image) Counts {
    var c: Counts = .{ .red = 0, .blue = 0 };
    var i: usize = (img.h / 8) * img.w * 4;
    while (i + 3 < img.rgba.len) : (i += 4) {
        const r = img.rgba[i];
        const g = img.rgba[i + 1];
        const b = img.rgba[i + 2];
        if (r > 200 and g < 60 and b < 60) c.red += 1;
        if (b > 200 and g < 60 and r < 60) c.blue += 1;
    }
    return c;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.openWithLogAndConfig(alloc, log_path, "test/gui/fixtures/config_cursor_in_frame");
    defer g.deinit();

    // Nothing on the page is red or blue but the cursor.
    try g.exec("execute('set laststatus=0 noruler noshowcmd')");
    try g.exec("execute('hi Normal guibg=#000000 guifg=#808080')");
    try g.exec("execute('hi Cursor guibg=#ff0000 guifg=#000000')");
    try g.exec("execute('set guicursor=a:block-Cursor,a:blinkon0')");
    // The cursor on the last of enough lines to stand clear of the title bar.
    try g.exec("setline(1, map(range(1, 12), {_, i -> 'line ' .. i}))");
    try g.exec("execute('normal! G0')");

    var img = try g.captureStable(null, 8000);
    defer img.deinit(alloc);

    const c = countCursorColours(img);
    std.debug.print("[gui] cursor pixels through the red/blue swap: blue={d} red={d}\n", .{ c.blue, c.red });
    if (c.red != 0) {
        std.debug.print("[gui] the cursor was drawn after the shader, not into the frame it reads\n", .{});
        return error.CursorDrawnAfterShader;
    }
    if (c.blue < min_cursor_px) return error.CursorNotRendered;
}
