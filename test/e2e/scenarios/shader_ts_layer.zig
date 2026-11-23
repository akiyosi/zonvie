// shader_ts_layer — the markers of the Tree-sitter layer reach the cells'
// shader group masks through a real Neovim.
//
// A shader that declares `ZonvieTs*` names gets src/core/shader_ts_layer.lua
// run in Neovim; it places those groups from the buffer's tree, and each
// cell's attribute id then resolves to the declared bits. This covers the
// whole chain: the layer is sent, the marker groups get attribute ids of
// their own, ext_hlstate names them, and the mask table follows.
// Exercises: sendShaderHlUnlink, hl_attr_define info, rebuildShaderHlMasks.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const declaration =
    "// @zonvie-hl-groups: ZonvieTsFnCursor ZonvieTsDepthB0 ZonvieTsDepthB1 ZonvieTsArg1 ZonvieTsParam ZonvieTsSignFn ZonvieTsFnOther\n";
const fn_cursor: u32 = 1 << 0;
const depth_b0: u32 = 1 << 1;
const depth_b1: u32 = 1 << 2;
const arg1: u32 = 1 << 3;
const param: u32 = 1 << 4;
const sign_fn: u32 = 1 << 5;
const fn_other: u32 = 1 << 6;

/// 'signcolumn=yes': buffer column c is grid column c + sign_cols.
const sign_cols: u32 = 2;

fn maskAt(h: *Harness, grid: i64, row: u32, col: u32) u32 {
    const cell = h.cellAt(grid, row, col);
    h.core.grid_mu.lockUncancelable(zc.clock.io());
    defer h.core.grid_mu.unlock(zc.clock.io());
    const masks = h.core.shader_hl_masks.items;
    return if (cell.hl < masks.len) masks[cell.hl] else 0;
}

fn expectMask(h: *Harness, grid: i64, row: u32, buf_col: u32, want: u32) !void {
    const got = maskAt(h, grid, row, buf_col + sign_cols);
    if (got != want) {
        std.debug.print("[e2e] row {d} col {d}: mask {b}, want {b}\n", .{ row, buf_col, got, want });
        return error.MaskMismatch;
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("set signcolumn=yes");
    //  0  if true then
    //  1    local function add(first, second)
    //  2      if first then
    //  3        return first + second
    //  4  (blank)
    //  5      end
    //  6    end
    //  7  end
    //  8  (blank)
    //  9  local x = 1
    try h.command(
        \\lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'if true then', '  local function add(first, second)', '    if first then', '      return first + second', '', '    end', '  end', 'end', '', 'local x = 1' }) vim.bo.filetype = 'lua'
    );
    try h.command("normal! 4G");

    h.core.grid_mu.lockUncancelable(zc.clock.io());
    h.core.setShaderHlGroupsLocked(declaration);
    h.core.grid_mu.unlock(zc.clock.io());
    h.core.sendShaderHlUnlink();

    const g = h.winGrid();
    // `return` sits three scopes deep (if > function > if) in the cursor's function.
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 3, 6 + sign_cols) == (fn_cursor | depth_b0 | depth_b1);
        }
    }.check, h.opts.timeout_ms);

    // Depth is per cell: each scope covers the cells from its header's
    // indent rightward, and so does the box of the cursor's function.
    try expectMask(h, g, 3, 0, depth_b0);
    try expectMask(h, g, 3, 2, fn_cursor | depth_b1);
    try expectMask(h, g, 3, 4, fn_cursor | depth_b0 | depth_b1);
    // A blank line keeps the same steps, in its cells past the line's end.
    try expectMask(h, g, 4, 0, depth_b0);
    try expectMask(h, g, 4, 2, fn_cursor | depth_b1);
    try expectMask(h, g, 4, 4, fn_cursor | depth_b0 | depth_b1);
    try expectMask(h, g, 4, 40, fn_cursor | depth_b0 | depth_b1);
    // A scope's first and closing rows belong to the scope around it.
    try expectMask(h, g, 0, 0, 0);
    try expectMask(h, g, 1, 0, depth_b0);
    try expectMask(h, g, 1, 2, fn_cursor | depth_b0);
    try expectMask(h, g, 6, 2, fn_cursor | depth_b0);
    try expectMask(h, g, 7, 0, 0);
    // The first parameter: at its definition and at each use.
    try expectMask(h, g, 1, 21, fn_cursor | depth_b0 | param | arg1);
    try expectMask(h, g, 1, 28, fn_cursor | depth_b0 | param);
    try expectMask(h, g, 2, 7, fn_cursor | depth_b1 | arg1);
    try expectMask(h, g, 3, 13, fn_cursor | depth_b0 | depth_b1 | arg1);
    try expectMask(h, g, 3, 21, fn_cursor | depth_b0 | depth_b1);
    // The function's first row carries its sign (placed a moment after the
    // text settles); nothing marks top-level code.
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 1, 0) == sign_fn;
        }
    }.check, h.opts.timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), maskAt(h, g, 2, 0));
    try expectMask(h, g, 9, 0, 0);

    // The cursor leaves the function: its markers go, the structural ones stay.
    try h.command("normal! 10G");
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 3, 6 + sign_cols) == (depth_b0 | depth_b1);
        }
    }.check, h.opts.timeout_ms);
    try expectMask(h, g, 1, 21, depth_b0 | param);
    try expectMask(h, g, 4, 2, depth_b1);

    // A second grammar, and a buffer no Tree-sitter highlighter runs on:
    // C names its nodes differently (parameters hang off a declarator, the
    // braces are rows of their own) and gets the same markers.
    //  0  int sum(const int *items, int count)
    //  1  {
    //  2      int total = 0;
    //  3      for (int i = 0; i < count; i++) {
    //  4          total += items[i];
    //  5      }
    //  6      return total;
    //  7  }
    try h.command(
        \\lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'int sum(const int *items, int count)', '{', '    int total = 0;', '    for (int i = 0; i < count; i++) {', '        total += items[i];', '    }', '    return total;', '}' }) vim.bo.filetype = 'c'
    );
    try h.command("normal! 5G");
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 4, 8 + sign_cols) == (fn_cursor | depth_b1);
        }
    }.check, h.opts.timeout_ms);
    try expectMask(h, g, 4, 0, fn_cursor | depth_b0);
    try expectMask(h, g, 4, 17, fn_cursor | depth_b1 | arg1);
    try expectMask(h, g, 0, 19, fn_cursor | param | arg1);
    try expectMask(h, g, 0, 30, fn_cursor | param);
    try expectMask(h, g, 1, 0, fn_cursor | depth_b0);
    try expectMask(h, g, 7, 0, fn_cursor);
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 0, 0) == sign_fn;
        }
    }.check, h.opts.timeout_ms);

    // Two functions: while the cursor is in one, the other is marked as
    // "other"; with the cursor in neither, neither is.
    //  0  local function a()
    //  1    return 1
    //  2  end
    //  3  (blank)
    //  4  local function b()
    //  5    return 2
    //  6  end
    try h.command(
        \\lua vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local function a()', '  return 1', 'end', '', 'local function b()', '  return 2', 'end' }) vim.bo.filetype = 'lua'
    );
    try h.command("normal! 2G");
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 5, 2 + sign_cols) == (fn_other | depth_b0);
        }
    }.check, h.opts.timeout_ms);
    try expectMask(h, g, 1, 2, fn_cursor | depth_b0);
    try expectMask(h, g, 4, 0, fn_other);
    try expectMask(h, g, 3, 0, 0);
    try h.command("normal! 6G");
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 1, 2 + sign_cols) == (fn_other | depth_b0);
        }
    }.check, h.opts.timeout_ms);
    try expectMask(h, g, 5, 2, fn_cursor | depth_b0);
    try h.command("normal! 4G");
    try h.waitUntil(g, struct {
        fn check(grid: i64, hh: *Harness) bool {
            return maskAt(hh, grid, 1, 2 + sign_cols) == depth_b0;
        }
    }.check, h.opts.timeout_ms);
    try expectMask(h, g, 5, 2, depth_b0);
}
